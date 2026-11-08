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
  mutable merged : int;  (* the group of the newest run *)
  closed : bool Atomic.t;  (* close ran: a second one does nothing *)
}

type batch = {
  results : (receipt, error) result array;  (* one for each request it took: a prefix of those given to [prepare] *)
  groups : Group.t list;  (* newest first *)
  body : Buffer.t;
  first : int;
  count : int;
  after : Store.view;
  runs : Snapshot.written list;  (* the runs of its large groups, to install once its frame is durable; newest first *)
  pending : Journal.pending option;  (* a large group's frame, its body written beside its merge: [body] is empty *)
}

(* The levels (Store, Snapshot): the delta is merged once it holds [compact_min] changes; level l holds at most
   compact_min * ratio^l rows. A merge takes the delta and the newest runs, down to the first level that can hold
   them all, and writes one run there (leveling: Luo, Carey 2020; the theory and the choice of the ratio:
   docs/theory.md, section 9). *)
let compact_min = ref 200_000
let ratio = ref 4
let frames = Atomic.make 0 (* frames written by this process: for the benchmarks, and a merge's fsyncs *)

(* for the benchmarks, in microseconds: the writer's resolution of a batch, its wait at a merge switch, a background
   merge from its start to its catch-up *)
let prepare_us = Histogram.create ()

(* a large group's time in the writer, in microseconds: resolved (with its facts sorted), encoded for the journal,
   merged into a run file *)
let large_resolve_us = Histogram.create ()
let large_encode_us = Histogram.create ()
let large_merge_us = Histogram.create ()
let switch_us = Histogram.create ()
let merge_us = Histogram.create ()

let needs_compaction (v : Store.view) = v.delta.dn > !compact_min

let cap l = let c = ref !compact_min in for _ = 1 to l do c := !c * !ratio done; !c

(* which runs a merge of [v] takes (the newest [take]), and the level of the run it writes; [extra]: rows a large
   group adds *)
let plan ?(extra = 0) (v : Store.view) =
  let rs = v.runs in
  let rec go l j size =
    let j = ref j and size = ref size in
    while !j < Array.length rs && rs.(!j).level <= l do size := !size + Store.run_rows rs.(!j); incr j done;
    if !size <= cap l then !j, l else go (l + 1) !j !size
  in
  go 1 0 (v.delta.dn + extra)

(* every run and the delta into one, at a level that holds them *)
let plan_all (v : Store.view) =
  let rs = v.runs in
  let size = Array.fold_left (fun n r -> n + Store.run_rows r) v.delta.dn rs in
  let l = ref (Array.fold_left (fun l (r : Store.run) -> max l r.level) 1 rs) in
  while cap !l < size do incr l done;
  Array.length rs, !l

(* The largest frame body the writer makes: the journal's limit (Journal.max_body); tests make it small. *)
let frame_limit = ref Journal.max_body

(* A group whose frame would pass the limit is refused. *)
let too_large size = Invalid (Printf.sprintf "a group of %d bytes is over the frame limit of %d" size !frame_limit)

(* [a ()] beside [b ()]: on two domains where the disk takes calls from several at once, else one after the other (on
   the simulated disk, whose order of calls a seed replays); the first exception of either, once both have returned *)
let beside (disk : Disk.t) a b =
  if disk.parallel then begin
    let d = Domain.spawn a in
    let y = match b () with y -> Ok y | exception e -> Error e in
    let x = match Domain.join d with x -> Ok x | exception e -> Error e in
    match x, y with Error e, _ | _, Error e -> raise e | Ok x, Ok y -> x, y
  end
  else
    let x = a () in
    x, b ()

(* The groups of a prefix of the requests, resolved on the working view, in order, as one frame: the prefix stops at
   the first group that would take the frame past [frame_limit] (it waits for the next frame, the working view not
   advanced by it), and at a large group, which has a frame of its own; the batch's [results] say how many requests
   it took. A large group (Resolve.resolve_large) is merged at once with the delta and the newest runs into a run
   file, not yet named, while another domain writes its frame's body to the journal (Journal.begin_frame): the batch
   carries both, and the commit finishes the frame, then names the run once the frame is durable, as a background
   merge's (G12). The writer runs no background merge then, and nothing else appends to the journal meanwhile. *)
let prepare ?(release = fun (_ : int) -> ()) t (reqs : (Resolve.op list * int * string) array) =
  let body = Buffer.create 1024 in
  let first = t.working.group + 1 in
  let count = ref 0 and groups = ref [] and runs = ref [] and pending = ref None in
  let one = Buffer.create 256 in
  let results = ref [] and full = ref false and i = ref 0 in
  while (not !full) && !i < Array.length reqs do
    let ops, by, why = reqs.(!i) in
    let large_ops = List.compare_length_with ops !Resolve.large_min >= 0 in
    (* the result of request i, or None: it waits for the next frame *)
    let r =
      match t.stopped with
      | Some e -> Some (Error e)
      | None when large_ops && !count > 0 -> None
      | None -> (
        let n = t.working.group + 1 and time = t.disk.now () in
        let t0 = Journal.clock () in
        (* a page of the base that cannot be read fails the group, as on the ordinary path *)
        let large =
          if large_ops then (match Resolve.resolve_large t.working ~n ~time ~by ~why ops with l -> Ok l | exception Pages.Unreadable m -> Error m)
          else Ok None
        in
        (match large with Ok (Some _) -> Histogram.record large_resolve_us (Journal.clock () - t0) | _ -> ());
        match large with
        | Error m -> Some (Error (Damaged m))
        | Ok (Some l) when l.len > !frame_limit -> Some (Error (too_large l.len))
        | Ok (Some l) -> (
          (* the operations are mapped: let them go, so that the collector may reuse their memory (millions of
             blocks) while the group is merged, unless the caller keeps them *)
          reqs.(!i) <- ([], by, why);
          release !i;
          match Journal.begin_frame t.journal l.len n 1 with
          | exception Disk.Io m -> t.stopped <- Some (Io m); Some (Error (Io m))
          | p -> (
            (* the frame's body written by another domain while this one merges; a failure of the journal stops the
               database (G10), one of the run's file fails the group only *)
            let failed = ref None and things = ref [] in
            let encode () =
              let t1 = Journal.clock () in
              (try Resolve.encode_large l (Journal.body p) with Disk.Io m -> failed := Some m);
              Histogram.record large_encode_us (Journal.clock () - t1);
              (* the receipt, a pair a new thing, made here beside the merge *)
              if Option.is_none !failed then things := Resolve.receipt l
            and merge () =
              let t1 = Journal.clock () in
              let take, level = plan ~extra:l.facts.n l.view in
              (* not forced here: the commit forces it beside the frame's fsync *)
              let w =
                Snapshot.merge ~bulk:l.facts ~sync:false t.disk (Filename.concat t.dir "snapshots") t.id l.view ~take ~level
                  (Atomic.get t.at)
              in
              Histogram.record large_merge_us (Journal.clock () - t1);
              w
            in
            let stop m = t.stopped <- Some (Io m); Some (Error (Io m)) in
            let lost e = match Journal.drop p with () -> Some (Error e) | exception Disk.Io m -> stop m in
            match beside t.disk encode merge with
            | (), w -> (
              match !failed with
              | Some m -> Snapshot.abandon t.disk w; stop m
              | None ->
                t.working <- w.view;
                runs := w :: !runs;
                pending := Some p;
                incr count;
                full := true;
                Some (Ok { group = n; things = !things }))
            | exception Disk.Io m -> (match !failed with Some m -> stop m | None -> lost (Io m))
            | exception Pages.Unreadable m -> (match !failed with Some m -> stop m | None -> lost (Damaged m))))
        | Ok None -> (
          match Resolve.resolve t.working ~n ~time ~by ~why ops with
          | Ok (v, g, temps) ->
            Buffer.clear one;
            Group.encode one g;
            if Buffer.length one > !frame_limit then Some (Error (too_large (Buffer.length one)))
            else if Buffer.length body + Buffer.length one > !frame_limit then None
            else begin
              t.working <- v;
              Buffer.add_buffer body one;
              groups := g :: !groups;
              incr count;
              Some (Ok { group = n; things = temps })
            end
          | Error e -> Some (Error (of_resolve e))
          | exception Pages.Unreadable m -> Some (Error (Damaged m))))
    in
    match r with
    | Some r -> results := r :: !results; incr i
    | None -> full := true
  done;
  { results = Array.of_list (List.rev !results); groups = !groups; body; first; count = !count; after = t.working;
    runs = !runs; pending = !pending }

(* Writes and forces the frame; on failure the database stops, and the batch's writes fail. A large group's run is
   forced beside its frame (two fsyncs at once, on two files), and named once both are done (G12); if only the run's
   fsync fails, the group is durable and confirmed, and the database stops (the next open replays it). *)
let commit t b =
  match t.stopped with
  | Some e ->
    Option.iter (fun p -> try Journal.drop p with Disk.Io _ -> ()) b.pending;
    Array.map (function Ok _ -> Error e | r -> r) b.results
  | None -> (
    let runs_failed = ref None in
    let journal () = match b.pending with Some p -> Journal.finish p | None -> Journal.append t.journal b.body b.first b.count in
    let force () = try List.iter Snapshot.force b.runs with Disk.Io m -> runs_failed := Some m in
    match
      if b.count > 0 then begin
        (match b.runs with [] -> journal () | _ -> ignore (beside t.disk force journal));
        Atomic.incr frames
      end
    with
    | () ->
      if b.count > 0 then Atomic.set t.at (Journal.position t.journal);
      (* the runs of its large groups take their names: their groups are durable now. A failure stops the database
         (the groups are durable; the next open replays them from the journal) *)
      Option.iter (fun m -> prerr_endline ("cepheus: the run of a large group could not be forced: " ^ m); t.stopped <- Some (Io m)) !runs_failed;
      List.iter
        (fun (w : Snapshot.written) ->
          if t.stopped = None then
            match Snapshot.install t.disk (Filename.concat t.dir "snapshots") w with
            | () -> t.merged <- w.group; List.iter (fun (r : Store.run) -> Pages.drop r.a.pg) w.replaced
            | exception Disk.Io m ->
              prerr_endline ("cepheus: the run of a large group could not be named: " ^ m);
              t.stopped <- Some (Io m))
        (List.rev b.runs);
      Atomic.set t.published b.after;
      b.results
    | exception Disk.Io m ->
      let e = Io m in
      t.stopped <- Some e;
      List.iter (Snapshot.abandon t.disk) b.runs;
      Array.map (function Ok _ -> Error e | r -> r) b.results)

(* ---- Merges: the one way to make a run ----
   A merge writes the view's delta and its newest runs into a new run file (Snapshot.merge), which replaces them. It
   may start from a view that runs ahead of the disk (a background merge); its file takes its name only when its
   group is durable, so that a run never holds a group the journal could lose (G12). *)

let sdir t = Filename.concat t.dir "snapshots"

(* the merge of [v] into a file, not yet installed: the runs [plan] says, or all of them; [Atomic.get t.at] taken with
   [v]: its first group is <= v.group + 1; [busy]: clients may be writing beside it (a background merge) *)
let merge_begin ?busy ?(all = false) t (v : Store.view) pos =
  let take, level = if all then plan_all v else plan v in
  Snapshot.merge ?busy t.disk (sdir t) t.id v ~take ~level pos

(* a frame was written since the last call: the journal is busy, its fsyncs are waited for *)
let journal_busy () =
  let last = ref (Atomic.get frames) in
  fun () ->
    let f = Atomic.get frames in
    let b = f <> !last in
    last := f;
    b

let drop_runs rs = List.iter (fun (r : Store.run) -> Pages.drop r.a.pg) rs

(* The switch, with nothing in flight: [w]'s file takes its name, and [v] (w's view with the groups written since)
   becomes the working and the published view; the runs it replaces leave the cache. *)
let install t (w : Snapshot.written) (v : Store.view) =
  if t.stopped <> None || (Atomic.get t.published).group < w.group then invalid_arg "Engine.install: not durable";
  Snapshot.install t.disk (sdir t) w;
  t.merged <- w.group;
  t.working <- v;
  Atomic.set t.published v;
  drop_runs w.replaced

(* A merge now of every run and the delta, with nothing in flight (working = published). *)
let compact t =
  let w = merge_begin ~all:true t t.working (Atomic.get t.at) in
  match install t w w.view with () -> () | exception (Disk.Io _ as e) -> Snapshot.abandon t.disk w; raise e

let snapshot t =
  match t.stopped with
  | Some e -> Error e
  | None -> (
    (* a page of the base that cannot be read, or a failed disk: no snapshot, an error, and the writer goes on *)
    match if t.working.group > t.merged || Array.length t.working.runs > 1 then compact t with
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
        (* After a crash, what the dead process wrote and did not force may sit in the page cache: the database's
           names, the journal's newest frames and names. They are forced before anything rests on them (G5, G12),
           unless the last process closed cleanly: [close] leaves a marker once everything is durable, and an open
           removes it before it writes anything, so a marker seen means that no process wrote since a clean close,
           or that a power loss came after, which leaves nothing in the page cache (PostgreSQL keeps the same state in
           pg_control: shut down, or in production). The marker's own changes need no fsync: lost, they only make
           the next open force. *)
        let marker = Filename.concat dir "closed" in
        let clean = disk.exists marker in
        if clean then disk.remove marker else disk.sync_dir dir;
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
          if g.n > !v.group then
            match Resolve.replay_large !v g with
            | Some (v', facts) ->
              (* a large group: merged at once, as the writer did *)
              let take, level = plan ~extra:facts.n v' in
              let w = Snapshot.merge ~bulk:facts disk sdir id v' ~take ~level (Option.get !at) in
              Snapshot.install disk sdir w;
              v := w.view;
              merged := w.group;
              drop_runs w.replaced
            | None ->
            v := Resolve.replay !v g;
            if needs_compaction !v then begin
              let take, level = plan !v in
              let w = Snapshot.merge disk sdir id !v ~take ~level (Option.get !at) in
              Snapshot.install disk sdir w;
              v := w.view;
              merged := w.group;
              drop_runs w.replaced
            end
        in
        let journal = Journal.recover ~frame ~after:start.group ~force:(not clean) disk jdir id from replay in
        (* a snapshot is installed only once the journal holds its groups durably (G12): a journal that ends before
           it lost durable frames (a damaged newest frame, which would otherwise be cut as torn) *)
        if Journal.next_group journal <= start.group then
          raise (Journal.Damaged (Printf.sprintf "the journal ends at group %d, before the snapshot of group %d"
                                    (Journal.next_group journal - 1) start.group));
        let t =
          { disk; dir; id; journal; working = !v; published = Atomic.make !v; stopped = None; notes;
            at = Atomic.make (Journal.position journal); merged = !merged; closed = Atomic.make false }
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

(* Every frame and every name is durable now (frames are forced as they are written, names as they change), unless
   an fsync failed: then no marker, and the next open forces what the page cache holds. The runs' pages leave the
   cache: a view kept after the close reads them again from its file. Once: a second close does nothing, for the
   database may be open in another engine by then, whose files a marker or an unlock would betray. *)
let close t =
  if Atomic.compare_and_set t.closed false true then begin
    Journal.close t.journal;
    if t.stopped = None then t.disk.close (t.disk.openf (Filename.concat t.dir "closed") true);
    drop_runs (Array.to_list t.working.runs);
    t.disk.unlock (Filename.concat t.dir "lock")
  end

(* ---- The threaded driver ---- *)

type req = {
  mutable w : Resolve.op list * int * string;  (* emptied once a large group is mapped: see [prepare] *)
  mutable res : (receipt, error) result option;
  rm : Mutex.t;
  rc : Condition.t;
}

type control = Write of req | Snapshot of req | Stop

(* ---- Merging in the background ----
   The writer never stops for a merge: another domain writes the new base's file from the working view of the
   moment (Snapshot.merge), then replays the groups written since onto the new base (the writer keeps them in a
   log), until it is a few hundred behind; the writer then waits for the syncer to be idle (at most one fsync), replays
   the rest, installs the file (its group is durable now) and switches both views to the new runs. Levels: the delta
   (level 0, persistent maps) is merged with the newest runs into one run (levels 1, 2, ...: run files). *)
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
             let t0 = Journal.clock () in
             let w = merge_begin ~busy:(journal_busy ()) t from pos in
             let v = ref w.view and applied = ref 0 in
             let go = ref true in
             while !go do
               let gs, k = after_applied m !applied in
               List.iter (fun g -> v := Resolve.replay !v g) gs;
               applied := !applied + k;
               if k < catch_up then begin
                 Histogram.record merge_us (Journal.clock () - t0);
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
    let failed () = l.retry <- l.e.working.delta.dn + !compact_min in
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

(* two batches prepared one after the other, as one frame (never a large group's, which has its own) *)
let merge a b =
  if Option.is_some a.pending || Option.is_some b.pending then invalid_arg "Engine.merge: a frame of its own";
  let body = Buffer.create (Buffer.length a.body + Buffer.length b.body) in
  Buffer.add_buffer body a.body;
  Buffer.add_buffer body b.body;
  { results = Array.append a.results b.results; groups = b.groups @ a.groups; body; first = a.first;
    count = a.count + b.count; after = b.after; runs = b.runs @ a.runs; pending = None }

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
        (* a large group merges at once with the newest runs: no merge may run beside it; and it writes its frame as it
           goes: the frame before it must be durable first *)
        if Array.exists (fun r -> let ops, _, _ = r.w in List.compare_length_with ops !Resolve.large_min >= 0) reqs then begin
          finish_merge l;
          wait_idle l
        end;
        let t0 = Journal.clock () in
        let b = prepare ~release:(fun i -> reqs.(i).w <- ([], 0, "")) l.e (Array.map (fun r -> r.w) reqs) in
        Histogram.record prepare_us (Journal.clock () - t0);
        (* the requests the frame did not take go first in the next one *)
        let taken = Array.length b.results in
        let left = List.filteri (fun i _ -> i >= taken) ws in
        let reqs = Array.sub reqs 0 taken in
        Mutex.lock l.sm;
        (* while the syncer forces the previous frame, the next one grows: everything that arrived meanwhile goes
           into one frame and one fsync (group commit), within the frame limit *)
        while
          match l.to_sync with
          | Some (b0, _) ->
            Option.is_some b0.pending || Option.is_some b.pending || Buffer.length b0.body > max_frame
            || Buffer.length b0.body + Buffer.length b.body > !frame_limit
          | None -> false
        do
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
        handle (List.map (fun r -> Write r) left @ rest)
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
