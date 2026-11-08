(* One database: its directory, its journal, its single writer. The core is deterministic and has no threads:
   [prepare] resolves a batch of writes on the working view (which runs ahead of the disk), [commit] writes the batch
   as one frame and makes it durable, [publish] makes it visible. The simulation test drives these steps itself,
   in an order drawn from a seed; [Live] drives them with two threads, so that the next batch is resolved while the
   previous one is being forced to disk, and only the clients of a forced frame are woken.

   Files:  DIR/cepheus     the database's id and format (written once, atomically)
           DIR/lock        held while the database is open (one writer, G9)
           DIR/journal/    the segments
           DIR/snapshots/  the newest snapshots *)

type error =
  | Conflict of string
  | Invalid of string
  | Not_unique of string
  | Damaged of string
  | Io of string
  | Busy of string
  | Closed

let message = function
  | Conflict m -> "conflict: " ^ m
  | Invalid m -> "invalid: " ^ m
  | Not_unique m -> "not unique: " ^ m
  | Damaged m -> "damaged: " ^ m
  | Io m -> "input/output error: " ^ m
  | Busy m -> "busy: " ^ m
  | Closed -> "the database is closed"

let of_resolve = function
  | Resolve.Conflict m -> Conflict m
  | Resolve.Invalid m -> Invalid m
  | Resolve.Not_unique m -> Not_unique m

type receipt = { group : int; things : (int * int) list }

type t = {
  disk : Disk.t;
  dir : string;
  id : string;
  journal : Journal.t;
  mutable working : Store.view;  (* every prepared group, durable or not *)
  published : Store.view Atomic.t;  (* durable groups only (G5) *)
  mutable stopped : error option;  (* after a failed write or fsync: nothing more is confirmed (G10) *)
  mutable notes : string list;  (* what recovery found and did *)
  at : Journal.position Atomic.t;  (* the journal's end after the last durable frame: where a merge's replay starts *)
  mutable merged : int;  (* the group of the newest snapshot, the base's file *)
}

type batch = {
  results : (receipt, error) result array;
  groups : Group.t list;  (* newest first *)
  body : Buffer.t;
  first : int;
  count : int;
  after : Store.view;
}

let compact_min = ref 200_000
let frames = Atomic.make 0 (* frames written by this process: for the benchmarks *)

(* for the benchmarks, in microseconds: the writer's resolution of a batch, its wait at a merge switch *)
let prepare_us = Histogram.create ()
let switch_us = Histogram.create ()

let needs_compaction (v : Store.view) = v.delta.dn > max !compact_min (v.base.n / 16)

let prepare t (reqs : (Resolve.op list * int * string) array) =
  let body = Buffer.create 1024 in
  let first = t.working.group + 1 in
  let count = ref 0 and groups = ref [] in
  let results =
    Array.map
      (fun (ops, by, why) ->
        match t.stopped with
        | Some e -> Error e
        | None -> (
          let n = t.working.group + 1 in
          match Resolve.resolve t.working ~n ~time:(t.disk.now ()) ~by ~why ops with
          | Ok (v, g, temps) ->
            t.working <- v;
            Group.encode body g;
            groups := g :: !groups;
            incr count;
            Ok { group = n; things = temps }
          | Error e -> Error (of_resolve e)
          | exception Pages.Unreadable m -> Error (Damaged m)))
      reqs
  in
  { results; groups = !groups; body; first; count = !count; after = t.working }

(* Writes and forces the frame; on failure the database stops, and the batch's writes fail. *)
let commit t b =
  match t.stopped with
  | Some e -> Array.map (function Ok _ -> Error e | r -> r) b.results
  | None -> (
    match if b.count > 0 then (Journal.append t.journal b.body b.first b.count; Atomic.incr frames) with
    | () ->
      if b.count > 0 then Atomic.set t.at (Journal.position t.journal);
      Atomic.set t.published b.after;
      b.results
    | exception Disk.Io m ->
      let e = Io m in
      t.stopped <- Some e;
      Array.map (function Ok _ -> Error e | r -> r) b.results)

(* ---- Merges: the one way to make a base ----
   A merge writes the view's base and delta into a new snapshot file (Snapshot.merge), which becomes the base. It may
   start from a view that runs ahead of the disk (a background merge); its file takes its name only when its group
   is durable, so that a snapshot never holds a group the journal could lose (G12). *)

let sdir t = Filename.concat t.dir "snapshots"

(* the merge of [v] into a file, not yet installed; [Atomic.get t.at] taken with [v]: its first group is <= v.group + 1 *)
let merge_begin t (v : Store.view) pos = Snapshot.merge t.disk (sdir t) t.id v pos

(* The switch, with nothing in flight: [w]'s file takes its name, and [v] (w's view with the groups written since)
   becomes the working and the published view; the base it replaces leaves the cache. *)
let install t (w : Snapshot.written) (v : Store.view) =
  if t.stopped <> None || (Atomic.get t.published).group < w.group then invalid_arg "Engine.install: not durable";
  Snapshot.install t.disk (sdir t) w;
  t.merged <- w.group;
  let old = t.working.base in
  t.working <- v;
  Atomic.set t.published v;
  if v.base != old then Pages.drop old.pg

(* A merge now, with nothing in flight (working = published). *)
let compact t =
  let w = merge_begin t t.working (Atomic.get t.at) in
  match install t w w.view with () -> () | exception (Disk.Io _ as e) -> Snapshot.abandon t.disk w; raise e

let snapshot t =
  match t.stopped with
  | Some e -> Error e
  | None -> (
    (* a page of the base that cannot be read, or a failed disk: no snapshot, an error, and the writer goes on *)
    match if t.working.group > t.merged then compact t with
    | () -> Ok ()
    | exception Disk.Io m -> Error (Io m)
    | exception Pages.Unreadable m -> Error (Damaged m))

let bootstrap_ops =
  List.concat_map
    (fun p ->
      match Schema.system.(p) with
      | Some d -> List.map (fun (e, q, x) -> Resolve.Add (e, q, x)) (Schema.facts p d)
      | None -> [])
    [ 1; 2; 3; 4 ]

let random_id disk =
  (* 16 bytes from the kernel; on a simulated disk, from its clock (a test's databases differ by directory) *)
  try
    let ic = open_in_bin "/dev/urandom" in
    Fun.protect ~finally:(fun () -> close_in ic) (fun () -> really_input_string ic 16)
  with Sys_error _ -> Printf.sprintf "%016d" (disk.Disk.now () mod 10_000_000_000_000_000)

let meta_magic = "cepheus database\n"

let rec mkdirs disk d =
  if not (disk.Disk.exists d) then begin
    mkdirs disk (Filename.dirname d);
    disk.mkdir d;
    disk.sync_dir (Filename.dirname d)
  end

let read_meta disk dir =
  let b = Disk.read_all disk (Filename.concat dir "cepheus") in
  let n = String.length meta_magic in
  if Bytes.length b <> n + 16 + 4 || Bytes.sub_string b 0 n <> meta_magic
     || Int32.to_int (Bytes.get_int32_le b (n + 16)) land 0xFFFFFFFF <> Crc32c.bytes b 0 (n + 16)
  then raise (Journal.Damaged (dir ^ "/cepheus is not a Cepheus database file"))
  else Bytes.sub_string b n 16

(* Opens or creates the database in [dir]: recovery = newest snapshot that checks, then the journal after it. *)
let open_ ?(id_source = random_id) disk dir =
  try
    mkdirs disk dir;
    let lock = Filename.concat dir "lock" in
    if not (disk.lock lock) then Error (Busy (dir ^ " is open in another process"))
    else
      let release () = disk.unlock lock in
      try
        let meta = Filename.concat dir "cepheus" in
        let jdir = Filename.concat dir "journal" and sdir = Filename.concat dir "snapshots" in
        let fresh = not (disk.exists meta) in
        if fresh then begin
          let id = id_source disk in
          let b = Buffer.create 64 in
          Buffer.add_string b meta_magic;
          Buffer.add_string b id;
          let crc = Crc32c.string (Buffer.contents b) in
          Buffer.add_int32_le b (Int32.of_int crc);
          Disk.write_file disk meta (Buffer.to_bytes b)
        end;
        let id = read_meta disk dir in
        (* the database's own names forced, as the journal's are at recovery: a killed process may have left them
           in the page cache *)
        disk.sync_dir dir;
        if not (disk.exists jdir) then (disk.mkdir jdir; disk.sync_dir dir);
        if not (disk.exists sdir) then (disk.mkdir sdir; disk.sync_dir dir);
        Snapshot.clean disk sdir;
        let loaded, notes = Snapshot.load disk sdir id in
        let start, from = match loaded with Some (v, pos) -> v, Some pos | None -> Store.empty (), None in
        let v = ref start and merged = ref start.group in
        (* a long tail is merged as it is replayed, into files, as the writer would have: the newest segment is
           forced before the replay (Journal.recover), so each group replayed is durable *)
        let at = ref None in
        let frame pos = at := Some pos in
        let replay (g : Group.t) =
          if g.n > !v.group then begin
            v := Resolve.replay !v g;
            if needs_compaction !v then begin
              let old = !v in
              let w = Snapshot.merge disk sdir id old (Option.get !at) in
              Snapshot.install disk sdir w;
              v := w.view;
              merged := w.group;
              Pages.drop old.base.pg
            end
          end
        in
        let journal = Journal.recover ~frame disk jdir id from replay in
        (* a snapshot is installed only once the journal holds its groups durably (G12): a journal that ends before
           it lost durable frames (a damaged newest frame, which would otherwise be cut as torn) *)
        if Journal.next_group journal <= start.group then
          raise (Journal.Damaged (Printf.sprintf "the journal ends at group %d, before the snapshot of group %d"
                                    (Journal.next_group journal - 1) start.group));
        let t =
          { disk; dir; id; journal; working = !v; published = Atomic.make !v; stopped = None; notes;
            at = Atomic.make (Journal.position journal); merged = !merged }
        in
        if !v.group = 0 then begin
          (* a new database: the first group describes the system properties *)
          let n = 1 in
          match Resolve.resolve ~bootstrap:true !v ~n ~time:(disk.now ()) ~by:0 ~why:"cepheus: create" bootstrap_ops with
          | Ok (v', g, _) ->
            let body = Buffer.create 256 in
            Group.encode body g;
            Journal.append journal body 1 1;
            Atomic.set t.at (Journal.position journal);
            t.working <- v';
            Atomic.set t.published v'
          | Error e -> failwith ("bootstrap: " ^ Resolve.error_message e)
        end;
        Ok t
      with
      | Journal.Damaged m | Pages.Unreadable m -> release (); Error (Damaged m)
      | Disk.Io m -> release (); Error (Io m)
  with
  | Disk.Io m -> Error (Io m)
  | Journal.Damaged m -> Error (Damaged m)

(* the base's pages leave the cache: a view kept after the close reads them again from its file *)
let close t =
  Journal.close t.journal;
  Pages.drop t.working.base.pg;
  t.disk.unlock (Filename.concat t.dir "lock")

(* ---- The threaded driver ---- *)

type req = {
  w : Resolve.op list * int * string;
  mutable res : (receipt, error) result option;
  rm : Mutex.t;
  rc : Condition.t;
}

type control = Write of req | Snapshot of req | Stop

(* ---- Merging in the background ----
   The writer never stops for a merge: another domain writes the new base's file from the working view of the
   moment (Snapshot.merge), then replays the groups written since onto the new base (the writer keeps them in a
   log), until it is a few hundred behind; the writer then waits for the syncer to be idle (at most one fsync), replays
   the rest, installs the file (its group is durable now) and switches both views to the new base. Levels: the delta
   (level 0, persistent maps) is merged into the base (level 1, the snapshot file). *)
type ready = Done of Snapshot.written * Store.view * int | Failed

type merger = {
  lm : Mutex.t;
  mutable log : Group.t list;  (* groups prepared since the merge started, newest first *)
  mutable logn : int;
  ready : ready option Atomic.t;  (* the file and the new lineage, and how many logged groups it holds *)
  mutable dom : unit Domain.t option;
}

let merges = Atomic.make 0 (* finished background merges, for the tests and benchmarks *)
let on_merge : (Store.view -> Store.view -> unit) ref = ref (fun _ _ -> ())
let catch_up = 256

(* the [n] logged groups after the first [applied], oldest first *)
let after_applied m applied =
  Mutex.lock m.lm;
  let k = m.logn - applied in
  let rec take i l acc = if i = 0 then acc else match l with g :: r -> take (i - 1) r (g :: acc) | [] -> acc in
  let gs = take k m.log [] in
  Mutex.unlock m.lm;
  gs, k

let start_merge t (from : Store.view) =
  let pos = Atomic.get t.at in
  let m = { lm = Mutex.create (); log = []; logn = 0; ready = Atomic.make None; dom = None } in
  m.dom <-
    Some
      (Domain.spawn (fun () ->
           try
             let w = merge_begin t from pos in
             let v = ref w.view and applied = ref 0 in
             let go = ref true in
             while !go do
               let gs, k = after_applied m !applied in
               List.iter (fun g -> v := Resolve.replay !v g) gs;
               applied := !applied + k;
               if k < catch_up then begin
                 Atomic.set m.ready (Some (Done (w, !v, !applied)));
                 go := false
               end
             done
           with e ->
             prerr_endline ("cepheus: background merge failed: " ^ Printexc.to_string e);
             Atomic.set m.ready (Some Failed)));
  m

type live = {
  e : t;
  m : Mutex.t;
  c_req : Condition.t;
  mutable queue : control list;  (* newest first *)
  sm : Mutex.t;
  c_sync : Condition.t;
  mutable to_sync : (batch * req array) option;
  mutable syncing : bool;
  mutable domain : unit Domain.t option;
  mutable closed : bool;
  mutable merging : merger option;
  mutable retry : int;  (* after a failed merge, the next waits until the delta has this many changes *)
}

let deliver r res =
  Mutex.lock r.rm;
  r.res <- Some res;
  Condition.signal r.rc;
  Mutex.unlock r.rm

let wait_idle l =
  Mutex.lock l.sm;
  while l.to_sync <> None || l.syncing do Condition.wait l.c_sync l.sm done;
  Mutex.unlock l.sm

let syncer l () =
  let go = ref true in
  while !go do
    Mutex.lock l.sm;
    while l.to_sync = None && not l.closed do Condition.wait l.c_sync l.sm done;
    match l.to_sync with
    | None -> Mutex.unlock l.sm; go := false
    | Some (b, reqs) ->
      l.to_sync <- None;
      l.syncing <- true;
      Mutex.unlock l.sm;
      let results = commit l.e b in
      Array.iteri (fun i r -> deliver r results.(i)) reqs;
      Mutex.lock l.sm;
      l.syncing <- false;
      Condition.broadcast l.c_sync;
      Mutex.unlock l.sm
  done

(* Waits for the merger, then switches to the new base when nothing is in flight. *)
let finish_merge l =
  match l.merging with
  | None -> ()
  | Some m ->
    let t0 = Journal.clock () in
    Option.iter Domain.join m.dom;
    l.merging <- None;
    wait_idle l;
    let failed () = l.retry <- l.e.working.delta.dn + max !compact_min (l.e.working.base.n / 16) in
    (match Atomic.get m.ready with
     | Some (Done (w, v, applied)) when l.e.stopped = None -> (
       let gs, _ = after_applied m applied in
       match
         let v = List.fold_left Resolve.replay v gs in
         !on_merge l.e.working v;
         install l.e w v
       with
       | () -> l.retry <- 0; Atomic.incr merges
       | exception Disk.Io msg ->
         prerr_endline ("cepheus: a merge could not be installed: " ^ msg);
         Snapshot.abandon l.e.disk w;
         failed ()
       | exception Pages.Unreadable msg ->
         prerr_endline ("cepheus: a merge could not catch up: " ^ msg);
         Snapshot.abandon l.e.disk w;
         failed ())
     | Some (Done (w, _, _)) -> Snapshot.abandon l.e.disk w
     | Some Failed -> failed ()
     | None -> ());
    Histogram.record switch_us (Journal.clock () - t0)

let max_batch = 4096
let max_frame = 8 lsl 20

(* two batches prepared one after the other, as one frame *)
let merge a b =
  let body = Buffer.create (Buffer.length a.body + Buffer.length b.body) in
  Buffer.add_buffer body a.body;
  Buffer.add_buffer body b.body;
  { results = Array.append a.results b.results; groups = b.groups @ a.groups; body; first = a.first;
    count = a.count + b.count; after = b.after }

let writer l () =
  let go = ref true in
  while !go do
    Mutex.lock l.m;
    while l.queue = [] do Condition.wait l.c_req l.m done;
    let items = List.rev l.queue in
    l.queue <- [];
    Mutex.unlock l.m;
    (* writes up to the first control, in order *)
    let rec split acc = function
      | Write r :: rest when List.length acc < max_batch -> split (r :: acc) rest
      | rest -> List.rev acc, rest
    in
    let rec handle items =
      match items with
      | [] -> ()
      | Write _ :: _ ->
        let ws, rest = split [] items in
        let reqs = Array.of_list ws in
        let t0 = Journal.clock () in
        let b = prepare l.e (Array.map (fun r -> r.w) reqs) in
        Histogram.record prepare_us (Journal.clock () - t0);
        Mutex.lock l.sm;
        (* while the syncer forces the previous frame, the next one grows: everything that arrived meanwhile goes
           into one frame and one fsync (group commit) *)
        while (match l.to_sync with Some (b0, _) -> Buffer.length b0.body > max_frame | None -> false) do
          Condition.wait l.c_sync l.sm
        done;
        (match l.to_sync with
         | None -> l.to_sync <- Some (b, reqs)
         | Some (b0, r0) -> l.to_sync <- Some (merge b0 b, Array.append r0 reqs));
        Condition.broadcast l.c_sync;
        Mutex.unlock l.sm;
        (match l.merging with
         | Some m ->
           Mutex.lock m.lm;
           m.log <- b.groups @ m.log;
           m.logn <- m.logn + b.count;
           Mutex.unlock m.lm;
           if Atomic.get m.ready <> None then finish_merge l
         | None ->
           if needs_compaction l.e.working && l.e.working.delta.dn > l.retry && l.e.stopped = None then
             l.merging <- Some (start_merge l.e l.e.working));
        handle rest
      | Snapshot r :: rest ->
        finish_merge l;
        wait_idle l;
        deliver r (Result.map (fun () -> { group = l.e.working.group; things = [] }) (snapshot l.e));
        handle rest
      | Stop :: rest ->
        finish_merge l;
        wait_idle l;
        List.iter (function Write r | Snapshot r -> deliver r (Error Closed) | Stop -> ()) rest;
        go := false
    in
    handle items
  done;
  Mutex.lock l.sm;
  l.closed <- true;
  Condition.broadcast l.c_sync;
  Mutex.unlock l.sm

let start e =
  let l =
    { e; m = Mutex.create (); c_req = Condition.create (); queue = []; sm = Mutex.create (); c_sync = Condition.create ();
      to_sync = None; syncing = false; domain = None; closed = false; merging = None; retry = 0 }
  in
  (* the writer and the syncer in a domain of their own: they never wait for the runtime lock of the clients *)
  l.domain <- Some (Domain.spawn (fun () ->
      let a = Thread.create (writer l) () and b = Thread.create (syncer l) () in
      Thread.join a;
      Thread.join b));
  l

let submit l c =
  Mutex.lock l.m;
  if l.closed then (Mutex.unlock l.m; false)
  else begin
    l.queue <- c :: l.queue;
    Condition.signal l.c_req;
    Mutex.unlock l.m;
    true
  end

let call l make =
  let r = { w = ([], 0, ""); res = None; rm = Mutex.create (); rc = Condition.create () } in
  let r = make r in
  match r with
  | Write q | Snapshot q ->
    if not (submit l r) then Error Closed
    else begin
      Mutex.lock q.rm;
      while q.res = None do Condition.wait q.rc q.rm done;
      Mutex.unlock q.rm;
      Option.get q.res
    end
  | Stop -> Ok { group = 0; things = [] }

let write l ops by why = call l (fun r -> Write { r with w = (ops, by, why) })
let snapshot_live l = call l (fun r -> Snapshot r)

let stop l =
  if submit l Stop then Option.iter Domain.join l.domain;
  close l.e
