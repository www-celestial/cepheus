(* A local reader: the database followed in the program's own memory (Follow says what the server sends and why reads
   here are linearizable). The follower rests on the runs the server passed, applies every frame as the server did
   (Resolve.replay), and keeps each state it gives under the visibility number it was sent with; a read loads the
   number from the shared page and serves the state held under it. Its pages go through this process's page cache
   (Pages), each checked by its CRC as it arrives (G7).

   One thread applies the stream (the transport's: Client, or the simulation), in order; reads come from any thread
   or domain: the states are values, published with one atomic store. *)

open Cepheus

(* a run's file as the follower holds it: a descriptor the server passed, or its bytes (the simulation) *)
type file = Fd of Unix.file_descr | Mem of Bytes.t

type state = { vs : int; view : Store.view }

type t = {
  id : string;  (* the database's id *)
  word : unit -> int;  (* the visibility number *)
  mutable built : ((int * int) * (Store.run * int)) list;  (* the runs of the newest base, by their groups, and their next thing *)
  mutable building : Store.view;  (* every frame applied: the newest state *)
  mutable log : (int * int * Bytes.t) list;  (* the frames applied since the base's newest run, newest first: for a new base *)
  states : state list Atomic.t;  (* newest first *)
  sm : Mutex.t;
  sc : Condition.t;  (* a state published, or the follower stopped *)
  mutable dead : bool;
  mutable applied : int;  (* frames applied, for the tests and benchmarks *)
  hl : Mutex.t;  (* the newest state and the live questions' hub, between the stream and a new watch *)
  mutable hub : Live.hub option;  (* the live questions of this program on this database, evaluated here *)
  mutable last_vseq : int;  (* the number of the newest frame applied *)
}

exception Stream of string

let stream fmt = Printf.ksprintf (fun m -> raise (Stream m)) fmt

(* ---- runs from the files passed ---- *)

(* the disk a run is checked and read through: its one file, under its name; reads of a descriptor are positioned
   with lseek, which no other process shares (the server opens a fresh description for each reader) and which the
   page cache's lock serializes in this one *)
let files_disk name file : Disk.t * (unit -> unit) =
  let opened = Hashtbl.create 2 and next = ref 1 in
  let io m = raise (Disk.Io m) in
  let bytes_of fd = match Hashtbl.find_opt opened fd with Some f -> f | None -> io "a closed run file" in
  let close_all () = match file with Fd ufd -> (try Unix.close ufd with Unix.Unix_error _ -> ()) | Mem _ -> () in
  let rec read_exact ufd b pos len = if len > 0 then (let n = Unix.read ufd b pos len in if n = 0 then io "a short run file" else read_exact ufd b (pos + n) (len - n)) in
  ( { exists = (fun p -> Filename.basename p = name);
      mkdir = (fun _ -> io "read-only");
      readdir = (fun _ -> [ name ]);
      openf = (fun p _ -> if Filename.basename p <> name then io ("no file " ^ p) else (let k = !next in incr next; Hashtbl.replace opened k file; k));
      size = (fun fd -> match bytes_of fd with Fd u -> (Unix.fstat u).st_size | Mem b -> Bytes.length b);
      pread =
        (fun fd off b pos len ->
          match bytes_of fd with
          | Mem m -> if off < 0 || off + len > Bytes.length m then io "a read past a run's end" else Bytes.blit m off b pos len
          | Fd u -> (
            try ignore (Unix.lseek u off Unix.SEEK_SET); read_exact u b pos len
            with Unix.Unix_error (e, _, _) -> io (Unix.error_message e)));
      pwrite = (fun _ _ _ _ _ -> io "read-only");
      truncate = (fun _ _ -> io "read-only");
      fsync = (fun _ -> io "read-only");
      close = (fun fd -> Hashtbl.remove opened fd);
      rename = (fun _ _ -> io "read-only");
      remove = (fun _ -> io "read-only");
      sync_dir = (fun _ -> io "read-only");
      lock = (fun _ -> false);
      unlock = ignore;
      now = (fun () -> int_of_float (Unix.gettimeofday () *. 1000.));
      parallel = false },
    close_all )

(* one run, checked (its header, its CRC table, its rank and offset tables: Snapshot.check_and_build); its file is
   closed once the run is garbage *)
let build_run id (lo, hi) file =
  let name = Snapshot.name lo hi in
  let disk, close = files_disk name file in
  match Snapshot.check_and_build disk "passed" (lo, hi, name) id with
  | run, next_e, _ ->
    Gc.finalise (fun _ -> close ()) run.Store.a.pg;
    run, next_e
  | exception Snapshot.Bad m -> close (); stream "run %s: %s" name m
  | exception (Disk.Io m | Pages.Unreadable m) -> close (); stream "run %s: %s" name m

(* the view of a chain of runs (newest first), its schema read from them *)
let base_of (chain : (Store.run * int) list) =
  match chain with
  | [] -> Store.empty ()
  | (top, next_e) :: _ ->
    let runs = Array.of_list (List.map fst chain) in
    let v = Store.of_runs ~group:top.hi ~next_e runs in
    (match Snapshot.schema_of v with schema -> { v with schema } | exception Snapshot.Bad m -> stream "the runs' schema: %s" m)

(* the runs named, newest first, each built from its file or reused; files given for runs already held are closed *)
let close_file = function Fd u -> (try Unix.close u with Unix.Unix_error _ -> ()) | Mem _ -> ()

let chain t names files =
  if List.length names <> List.length files then begin
    List.iter close_file files;
    stream "%d runs and %d files" (List.length names) (List.length files)
  end;
  (* in order; a run that does not check closes the files not yet used *)
  let rec go acc = function
    | [] -> List.rev acc
    | (k, file) :: rest -> (
      match List.assoc_opt k t.built with
      | Some r -> close_file file; go ((k, r) :: acc) rest
      | None -> (
        match build_run t.id k file with
        | r -> go ((k, r) :: acc) rest
        | exception e -> List.iter (fun (_, f) -> close_file f) rest; raise e))
  in
  let built = go [] (List.combine names files) in
  (* each run rests on the next one's groups, down to 0 *)
  let rec rests = function
    | ((lo, _), _) :: (((_, hi'), _) :: _ as rest) -> lo = hi' && rests rest
    | [ ((lo, _), _) ] -> lo = 0
    | [] -> true
  in
  if not (rests built) then stream "the runs do not rest on one another";
  (* the runs a merge replaced leave the page cache now, as the server's do (Engine): else their pages stayed resident
     until the cache was full, a base's worth at each merge. A state still on them reads them again from their file *)
  List.iter (fun (k, ((r : Store.run), _)) -> if not (List.mem_assoc k built) then Pages.drop r.a.pg) t.built;
  t.built <- built;
  base_of (List.map snd built)

(* ---- the stream ---- *)

let create ~id ~word ~names ~files =
  let t =
    { id; word; built = []; building = Store.empty (); log = []; states = Atomic.make []; sm = Mutex.create (); sc = Condition.create ();
      dead = false; applied = 0; hl = Mutex.create (); hub = None; last_vseq = 0 }
  in
  t.building <- chain t names files;
  t

(* publish under the lock, so that a read that found nothing and waits is woken; the states the number has passed
   are dropped (a read loads the number before it looks) *)
let publish t states =
  Mutex.lock t.sm;
  let w = t.word () in
  Atomic.set t.states (List.filter (fun s -> s.vs >= w) states);
  Condition.broadcast t.sc;
  Mutex.unlock t.sm

(* the groups of a frame, replayed onto [v]: those it holds already are skipped; a gap is an error. [applied]: each
   group replayed *)
let apply ?(applied = ignore) v (first, count, body) ~upto =
  let r = Codec.reader body 0 (Bytes.length body) in
  let v = ref (v : Store.view) in
  for k = 0 to count - 1 do
    let g = try Group.decode r with Codec.Short -> stream "a frame from group %d does not decode" first in
    if g.n <> first + k then stream "group %d where %d was expected" g.n (first + k);
    if g.n > !v.group && g.n <= upto then begin
      if g.n <> !v.group + 1 then stream "group %d after %d: a gap" g.n !v.group;
      v := (try Resolve.replay !v g with Journal.Damaged m -> stream "%s" m);
      applied g
    end
  done;
  !v

(* Groups first .. first + count - 1 ([body]: the journal's coding); the newest state is then visible under [vseq]
   (0: not on its own) *)
let frame t ~vseq ~first ~count body =
  let f = first, count, body in
  Mutex.protect t.hl (fun () ->
      (match t.hub with
       | None -> t.building <- apply t.building f ~upto:max_int
       | Some h ->
         (* the live questions' changes of the frame, computed now, while the server forces it; given once it is
            durable (Durable) *)
         let gs = ref [] in
         t.building <- apply ~applied:(fun g -> gs := g :: !gs) t.building f ~upto:max_int;
         Live.frame h ~tag:vseq (List.rev !gs) t.building);
      if vseq > 0 then t.last_vseq <- vseq);
  if count > 0 then t.log <- f :: t.log;
  t.applied <- t.applied + 1;
  if vseq > 0 then publish t ({ vs = vseq; view = t.building } :: Atomic.get t.states)

(* the frames sent under [vseq] and below are durable *)
let durable t vseq = Option.iter (fun h -> Live.durable h vseq) (Mutex.protect t.hl (fun () -> t.hub))

(* New runs (newest first): the states under [vseq] or later rest on them, if they hold the runs' groups (a merge
   gives the same states on fewer runs); a state before them stays on the runs it has (a large group's run comes
   before the state it makes). The frames the new runs hold are dropped from the log. *)
let runs t ~vseq ~names ~files =
  let base = chain t names files in
  let h = base.group in
  (* the log's frames, oldest first, onto the base: up to each target group in turn *)
  let frames = List.rev t.log in
  let rebuild targets =
    let cur = ref (base : Store.view) and rest = ref frames in
    List.map
      (fun g ->
        let rec go () =
          match !rest with
          | ((f0, n, _) as f) :: tl when f0 <= g ->
            cur := apply !cur f ~upto:g;
            if f0 + n - 1 <= g then (rest := tl; go ())
          | _ -> ()
        in
        go ();
        if !cur.group <> g then stream "a rebuild reached group %d, not %d" !cur.group g;
        g, !cur)
      targets
  in
  let keep = List.filter (fun s -> s.vs >= vseq) (Atomic.get t.states) in
  let targets = List.sort_uniq compare (List.filter (fun g -> g >= h) (t.building.group :: List.map (fun s -> s.view.group) keep)) in
  let rebuilt = rebuild targets in
  let at g = if g < h then None else Some (List.assoc g rebuilt) in
  Mutex.protect t.hl (fun () ->
      let before = t.building.group in
      t.building <- (match at t.building.group with Some v -> v | None -> base);
      match t.hub with
      | Some hub when t.building.group <> before ->
        (* a large group: its run is the state, its changes are not sent; every live question is asked again, under
           the number of the frame that follows *)
        Live.reset hub t.building ~tag:(vseq + 1)
      | Some hub -> Live.rebase hub t.building
      | None -> ());
  let states = List.map (fun s -> match at s.view.group with Some v -> { s with view = v } | None -> s) keep in
  t.log <- List.filter (fun (f0, n, _) -> f0 + n - 1 > h) t.log;
  publish t states

(* the stream ended (the server closed it, died, or cut it off): nothing more is served *)
let stop t =
  Mutex.lock t.sm;
  t.dead <- true;
  Atomic.set t.states [];
  Condition.broadcast t.sc;
  Mutex.unlock t.sm;
  Option.iter (fun h -> Live.stop h "unreachable" "the local reader's stream ended") (Mutex.protect t.hl (fun () -> t.hub))

(* ---- reads ---- *)

let find_state w = function
  | s :: _ when s.vs = w -> Some s.view
  | _ :: s :: _ when s.vs = w -> Some s.view
  | l -> List.find_map (fun s -> if s.vs = w then Some s.view else None) l

(* The state visible now: the one held under the number loaded first; if the follower does not hold it yet (its
   frame is still on the way), the read waits for it. None once the follower stopped. *)
let view t =
  let w = t.word () in
  match find_state w (Atomic.get t.states) with
  | Some v -> Some v
  | None ->
    Mutex.lock t.sm;
    let rec wait () =
      if t.dead then None
      else
        match find_state (t.word ()) (Atomic.get t.states) with
        | Some v -> Some v
        | None -> Condition.wait t.sc t.sm; wait ()
    in
    let r = wait () in
    Mutex.unlock t.sm;
    r

let dead t = t.dead

(* The hub of this program's live questions on the database, made at the first: at the newest state applied, once the
   follower holds the state visible now (a watch never starts from a state older than a read could see) *)
let hub t =
  match view t with
  | None -> None
  | Some _ ->
    Mutex.protect t.hl (fun () ->
        match t.hub with
        | Some h -> Some h
        | None ->
          let h = Live.create t.building ~tag:t.last_vseq ~durable:(t.word ()) in
          t.hub <- Some h;
          Some h)

(* the state visible now, without waiting: None if the follower does not hold it yet (the simulation) *)
let try_view t = if t.dead then None else find_state (t.word ()) (Atomic.get t.states)
