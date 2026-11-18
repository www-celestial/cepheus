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

(* A Raft cluster's server stopped leading before a write's frame was committed: the write was applied once or not
   at all (Busy with this very string, which the server tells apart by its address, so that the public type does not
   change) *)
let lost_leadership = "not leader: this server stopped leading before the write was committed; it was applied once or not at all (send it again in its session)"
let not_leader = Busy lost_leadership
let is_not_leader = function Busy m -> m == lost_leadership | _ -> false

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
  pm : Mutex.t;
  mutable provisional : (Store.run * string) list;
      (* the provisional runs of the working view (changes of the rules' derived facts, level 0) and their files, under
         [pm]: removed once a merge that took them is installed, at a Raft take-back that drops them, at close *)
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
  own : bool;  (* resolved here (writes), not a frame taken from elsewhere (Apply): in a Raft cluster, proposed *)
  change : Store.view option;  (* the request after the prefix is a change for the background path (Reason.Background):
                                  the view after its asserted changes, to find the texts it names *)
}

(* The levels (Store, Snapshot): the delta is merged once it holds [compact_min] changes; level l holds at most
   compact_min * ratio^l rows. A merge takes the delta and the newest runs, down to the first level that can hold
   them all, and writes one run there (leveling: Luo, Carey 2020; the theory and the choice of the ratio:
   docs/book/theory.md, section 9). *)
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

(* the provisional runs a view holds at most (changes of the rules' runs of their own, which no merge took yet): past
   [max_provisional / 2] a merge starts, at [max_provisional] a change writes its derived facts into the delta as a
   smaller one does, so that a merge never takes more runs than Snapshot.max_take *)
let max_provisional = 8

let needs_compaction (v : Store.view) = v.delta.dn > !compact_min || Store.provisionals v.runs >= max_provisional / 2

(* saturated: a [compact_min] near max_int (the merge benchmark turns merges off so) must not wrap around *)
let cap l = let c = ref !compact_min in for _ = 1 to l do c := if !c > max_int / !ratio then max_int else !c * !ratio done; !c

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

(* A large group's merge (lazy leveling: Dostoevsky, Dayan and Idreos 2018). Its run takes the delta and the newest
   runs of the levels below the one that holds them, and stays beside the runs of that level, the large groups' before
   it, rather than merging with them, until [tier] of them would lie side by side: then all are merged in this one pass
   ([plan]). So a load written as many large groups writes each fact about twice (its group's run, the tier's merge),
   not once a level; reads meanwhile visit up to [tier] runs of the level. A large group never leaves more than [tier]
   runs; the delta's merges add at most one a level: far below the 31 a merge may take (Snapshot.max_take). *)
let tier = ref 16

let plan_large ~extra (v : Store.view) =
  let rs = v.runs in
  let rec fit l j size =
    let j = ref j and size = ref size in
    while !j < Array.length rs && rs.(!j).level < l do size := !size + Store.run_rows rs.(!j); incr j done;
    if !size <= cap l then !j, l else fit (l + 1) !j !size
  in
  let j, l = fit 1 0 (v.delta.dn + extra) in
  let k = ref 0 in
  while j + !k < Array.length rs && rs.(j + !k).level = l do incr k done;
  if !k + 1 >= !tier || Array.length rs - j + 1 > !tier then plan ~extra v else j, l

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

exception Deferred

(* what only the writer may do in its order, so that a change with it is computed inline, in its group: new things
   (a temporary id in an operation: their numbers are the writer's to give) and an Incr (its counter is read at its
   point of the writer's order: groups that count with one counter never conflict) *)
let inline_only ops =
  List.exists
    (function
      | Resolve.Add (e, _, x) | Retract (e, _, x) -> e < 0 || (match x with Value.Link t -> t < 0 | _ -> false)
      | Expect (e, _, _) -> e < 0
      | Incr _ -> true)
    ops

(* The groups of a prefix of the requests, resolved on the working view, in order, as one frame: the prefix stops at
   the first group that would take the frame past [frame_limit] (it waits for the next frame, the working view not
   advanced by it), and at a large group, which has a frame of its own; the batch's [results] say how many requests
   it took. A large group (Resolve.resolve_large) is merged at once with the delta and the newest runs into a run
   file, not yet named, while another domain writes its frame's body to the journal (Journal.begin_frame): the batch
   carries both, and the commit finishes the frame, then names the run once the frame is durable, as a background
   merge's (G12). The writer runs no background merge then, and nothing else appends to the journal meanwhile. *)
let prepare ?(release = fun (_ : int) -> ()) ?(background = false) t (reqs : (Resolve.op list * int * string) array) =
  let body = Buffer.create 1024 in
  let first = t.working.group + 1 in
  let count = ref 0 and groups = ref [] and runs = ref [] and pending = ref None and change = ref None in
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
        | Ok (Some l) -> (
          (* the operations are mapped: let them go, so that the collector may reuse their memory (millions of
             blocks) while the group is merged, unless the caller keeps them *)
          reqs.(!i) <- ([], by, why);
          release !i;
          (* beside the merge, on another domain: the group coded (in memory: a few bytes a fact), its frame begun
             at the end of the journal and its body written by pieces, then the receipt. A failure of the journal
             stops the database (G10), one of the run's file fails the group only; a group whose coding passes the
             frame limit is refused, its run abandoned *)
          let failed = ref None and things = ref [] and big = ref None and pend = ref None in
          let encode () =
            let t1 = Journal.clock () in
            let body = Resolve.encode_large l in
            let len = Buffer.length body in
            if len > !frame_limit then big := Some len
            else begin
              (match Journal.begin_frame t.journal len n 1 with
               | p ->
                 pend := Some p;
                 let bytes = Buffer.to_bytes body and piece = 1 lsl 20 in
                 let o = ref 0 in
                 (try
                    while !o < len do
                      let k = min piece (len - !o) in
                      Journal.body p bytes !o k;
                      o := !o + k
                    done
                  with Disk.Io m -> failed := Some m)
               | exception Disk.Io m -> failed := Some m);
              Histogram.record large_encode_us (Journal.clock () - t1);
              (* the receipt, a pair a new thing, made here beside the merge *)
              if Option.is_none !failed then things := Resolve.receipt l
            end
          and merge () =
            let t1 = Journal.clock () in
            let take, level = plan_large ~extra:l.facts.n l.view in
            (* not forced here: the commit forces it beside the frame's fsync *)
            let w =
              Snapshot.merge ~bulk:l.facts ~sync:false t.disk (Filename.concat t.dir "snapshots") t.id l.view ~take ~level
                (Atomic.get t.at)
            in
            Histogram.record large_merge_us (Journal.clock () - t1);
            w
          in
          let stop m = t.stopped <- Some (Io m); Some (Error (Io m)) in
          let lost e =
            match !pend with
            | None -> Some (Error e)
            | Some p -> (match Journal.drop p with () -> Some (Error e) | exception Disk.Io m -> stop m)
          in
          match beside t.disk encode merge with
          | (), w -> (
            match !failed, !big, !pend with
            | Some m, _, _ -> Snapshot.abandon t.disk w; stop m
            | None, Some len, _ -> Snapshot.abandon t.disk w; Some (Error (too_large len))
            | None, None, p ->
              t.working <- w.view;
              runs := w :: !runs;
              pending := p;
              incr count;
              full := true;
              Some (Ok { group = n; things = !things }))
          | exception Disk.Io m -> (match !failed with Some m -> stop m | None -> lost (Io m))
          | exception Pages.Unreadable m -> (match !failed with Some m -> stop m | None -> lost (Damaged m)))
        | Ok None -> (
          (* a change of the rules or the ontology leaves the batch for the background path ([background]: the
             threaded writer), unless it makes new things (their numbers are the writer's to give, in order) *)
          let reason ~v0 v changes words =
            if not background then Reason.run ~v0 v changes words
            else
              try Reason.run ~background ~v0 v changes words
              with Reason.Background -> if inline_only ops then Reason.run ~v0 v changes words else (change := Some v; raise Deferred)
          in
          match Resolve.resolve t.working ~n ~time ~by ~why ~reason ops with
          | exception Deferred -> None
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
    runs = !runs; pending = !pending; own = true; change = !change }

(* ---- A replica's frames ----
   A replica takes its primary's groups as its primary's journal codes them, never resolves a write: [prepare_apply]
   decodes a frame (bounds checked: Group.decode), skips the groups the working view holds already (a frame sent again
   after a connection broke), replays the others in order, without a gap, as recovery does (a large group merged at
   once into a run, as the primary did), and makes the batch whose body the syncer appends to this journal: the
   frame's own bytes when it is applied whole. Nothing changes on an error. *)

type frame = { first : int; count : int; body : Bytes.t; len : int }

(* the groups of a frame, decoded; Error if it does not decode to exactly its groups *)
let decode_frame f =
  let r = Codec.reader f.body 0 f.len in
  match List.init f.count (fun k -> let g = Group.decode r in (if g.n <> f.first + k then raise Codec.Short); g) with
  | gs when Codec.at_end r -> Ok gs
  | _ -> Error (Damaged (Printf.sprintf "the frame of groups %d to %d has bytes after its groups" f.first (f.first + f.count - 1)))
  | exception (Codec.Short | Invalid_argument _) ->
    Error (Damaged (Printf.sprintf "the frame of groups %d to %d does not decode to its groups" f.first (f.first + f.count - 1)))

(* may hold a large group: the writer lets no merge run beside it *)
let maybe_large gs = List.exists (fun (g : Group.t) -> Array.length g.changes >= !Resolve.large_min) gs

let prepare_apply t (f : frame) gs =
  match t.stopped with
  | Some e -> Error e
  | None -> (
    let start = t.working in
    let fresh = List.filter (fun (g : Group.t) -> g.n > start.group) gs in
    let runs = ref [] in
    match
      List.fold_left
        (fun (v : Store.view) (g : Group.t) ->
          if g.n <> v.group + 1 then raise (Journal.Damaged (Printf.sprintf "group %d after group %d: a gap" g.n v.group));
          match Resolve.replay_large v g with
          | Some (v', facts) ->
            if !runs <> [] then raise (Journal.Damaged "two large groups in one frame");
            let take, level = plan_large ~extra:facts.n v' in
            let w = Snapshot.merge ~bulk:facts ~sync:false t.disk (Filename.concat t.dir "snapshots") t.id v' ~take ~level (Atomic.get t.at) in
            runs := [ w ];
            w.view
          | None -> Resolve.replay v g)
        start fresh
    with
    | after ->
      let body = Buffer.create (if List.length fresh = f.count then f.len else 256) in
      if List.length fresh = f.count then Buffer.add_subbytes body f.body 0 f.len
      else List.iter (Group.encode body) fresh;
      t.working <- after;
      let count = List.length fresh in
      Ok
        { results = [| Ok { group = after.group; things = [] } |]; groups = List.rev fresh; body;
          first = (match fresh with g :: _ -> g.n | [] -> start.group + 1); count; after; runs = !runs; pending = None; own = false; change = None }
    | exception Journal.Damaged m -> List.iter (Snapshot.abandon t.disk) !runs; Error (Damaged m)
    | exception Pages.Unreadable m -> List.iter (Snapshot.abandon t.disk) !runs; Error (Damaged m)
    | exception Disk.Io m -> List.iter (Snapshot.abandon t.disk) !runs; Error (Io m)
    | exception e ->
      (* groups that decode and do not replay (a peer's bug, or worse): refused, the writer goes on *)
      List.iter (Snapshot.abandon t.disk) !runs;
      Error (Damaged (Printf.sprintf "the frame of groups %d to %d does not replay: %s" f.first (f.first + f.count - 1) (Printexc.to_string e))))

let drop_runs rs = List.iter (fun (r : Store.run) -> Pages.drop r.a.pg) rs

(* The files of the provisional runs that left the working view (a merge that took them is installed, a Raft take-back
   dropped them): a view taken before still reads them, through the descriptor the file keeps open *)
let sweep t =
  let gone =
    Mutex.protect t.pm (fun () ->
        let live, gone = List.partition (fun (r, _) -> Array.exists (fun r' -> r' == r) t.working.runs) t.provisional in
        t.provisional <- live;
        gone)
  in
  List.iter (fun ((r : Store.run), f) -> Pages.drop r.a.pg; try t.disk.remove f with Disk.Io _ -> ()) gone

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
      if b.runs <> [] then sweep t;
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


(* The switch, with nothing in flight: [w]'s file takes its name, and [v] (w's view with the groups written since)
   becomes the working and the published view; the runs it replaces leave the cache. *)
let install t (w : Snapshot.written) (v : Store.view) =
  if t.stopped <> None || (Atomic.get t.published).group < w.group then invalid_arg "Engine.install: not durable";
  (* a run holds the groups up to its position in the journal, which the next open reads from: a shared journal is
     forced first, so that no run rests on frames the commit buffer alone holds *)
  Journal.checkpoint t.journal;
  Snapshot.install t.disk (sdir t) w;
  t.merged <- w.group;
  t.working <- v;
  Atomic.set t.published v;
  drop_runs w.replaced;
  sweep t

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

exception Refused of string

let read_meta disk dir =
  let b = Disk.read_all disk (Filename.concat dir "cepheus") in
  let n = String.length meta_magic in
  if Bytes.length b <> n + 16 + 4 || Bytes.sub_string b 0 n <> meta_magic
     || Int32.to_int (Bytes.get_int32_le b (n + 16)) land 0xFFFFFFFF <> Crc32c.bytes b 0 (n + 16)
  then raise (Journal.Damaged (dir ^ "/cepheus is not a Cepheus database file"))
  else Bytes.sub_string b n 16

(* Opens or creates the database in [dir]: recovery = newest snapshot that checks, then the journal after it.
   [buffer]: the database is opened by a server whose commit buffer (Wal) will force its journal; given the database's
   id, the frames the buffer holds for it, which recovery writes again into the journal. [bootstrap] false: a new
   database stays empty, at group 0 (a replica's copy, whose groups all come from its primary, the first included). *)
let open_ ?(id_source = random_id) ?buffer ?raft ?bootstrap_time ?(bootstrap = true) disk dir =
  (* a Raft cluster's database: its journal is shared with the Raft log as with a commit buffer (the marker), and
     [raft id g] gives, for the newest run's group g, the frames to write again and the group to cut the journal at *)
  let buffer = match raft with Some _ -> Some (fun _ -> []) | None -> buffer in
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
        (* [shared]: a server's commit buffer forces the journal (made durable before its first frame; removed by the
           next open without the buffer, after a clean close). Without a clean close, the newest confirmed frames may
           be in that buffer alone: an open without it would cut them as a torn tail, or take their holes for damage *)
        let shared = Filename.concat dir "shared" in
        let was_shared = disk.exists shared in
        if was_shared && (not clean) && buffer = None then
          raise (Refused (dir ^ " was written through a server's commit buffer and not closed cleanly: its newest "
                          ^ "writes may be in the server's DATA/server.wal.1 or .2 alone; start the server on its data "
                          ^ "directory, which writes them into the journal, and stop it"));
        if clean then disk.remove marker;
        let mark = buffer <> None && not was_shared and unmark = buffer = None && was_shared in
        if mark then disk.close (disk.openf shared true);
        if unmark then disk.remove shared;
        if (not clean) || mark || unmark then disk.sync_dir dir;
        if not (disk.exists jdir) then (disk.mkdir jdir; disk.sync_dir dir);
        if not (disk.exists sdir) then (disk.mkdir sdir; disk.sync_dir dir);
        (* a journal of format 1 coded in columns once, before anything reads it *)
        ignore (Journal.convert disk jdir id);
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
              let take, level = plan_large ~extra:facts.n v' in
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
        let copy, cut = match raft, buffer with Some f, _ -> f id start.group | None, Some f -> f id, None | None, None -> [], None in
        let journal = Journal.recover ~frame ~after:start.group ~copy ?cut ~force:(not clean) disk jdir id from replay in
        (* a snapshot is installed only once the journal holds its groups durably (G12): a journal that ends before
           it lost durable frames (a damaged newest frame, which would otherwise be cut as torn) *)
        if Journal.next_group journal <= start.group then
          raise (Journal.Damaged (Printf.sprintf "the journal ends at group %d, before the snapshot of group %d"
                                    (Journal.next_group journal - 1) start.group));
        let t =
          { disk; dir; id; journal; working = !v; published = Atomic.make !v; stopped = None; notes;
            at = Atomic.make (Journal.position journal); merged = !merged; closed = Atomic.make false; pm = Mutex.create ();
            provisional = [] }
        in
        if !v.group = 0 && bootstrap then begin
          (* a new database: the first group describes the system properties (a replica's copy takes its primary's) *)
          let n = 1 in
          let time = match bootstrap_time with Some x -> x | None -> disk.now () in
          match Resolve.resolve ~bootstrap:true !v ~n ~time ~by:0 ~why:"cepheus: create" Resolve.bootstrap_ops with
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
      | Refused m -> release (); Error (Busy m)
  with
  | Disk.Io m -> Error (Io m)
  | Journal.Damaged m -> Error (Damaged m)

(* Every frame and every name is durable now (frames are forced as they are written, or here when a server's commit
   buffer forced them; names as they change), unless an fsync failed: then no marker, and the next open forces what
   the page cache holds. The runs' pages leave the
   cache: a view kept after the close reads them again from its file. Once: a second close does nothing, for the
   database may be open in another engine by then, whose files a marker or an unlock would betray. *)
let close t =
  if Atomic.compare_and_set t.closed false true then begin
    (* a shared journal's checkpoint may have failed in the commit buffer's thread, unknown to the writer: no marker
       then either *)
    let forced =
      match Journal.close t.journal with
      | () -> Journal.forced t.journal
      | exception Disk.Io m -> prerr_endline ("cepheus: the journal could not be forced at close: " ^ m); false
    in
    if t.stopped = None && forced then t.disk.close (t.disk.openf (Filename.concat t.dir "closed") true);
    drop_runs (Array.to_list t.working.runs);
    List.iter (fun (_, f) -> try t.disk.remove f with Disk.Io _ -> ()) (Mutex.protect t.pm (fun () -> let l = t.provisional in t.provisional <- []; l));
    t.disk.unlock (Filename.concat t.dir "lock")
  end

(* ---- The threaded driver ---- *)

type req = {
  mutable w : Resolve.op list * int * string;  (* emptied once a large group is mapped: see [prepare] *)
  mutable res : (receipt, error) result option;
  rm : Mutex.t;
  rc : Condition.t;
}

(* Apply: a replica's frame from its primary, or a Raft cluster's frame of another leader: [req]'s result once it is
   durable here. Wake: a background domain is done (a merge, a change): the writer looks, even when no write comes *)
type control = Write of req | Snapshot of req | Apply of req * frame | Wake | Stop

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

let start_merge ?(wake = ignore) t (from : Store.view) =
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
             done;
             wake ()
           with e ->
             prerr_endline ("cepheus: background merge failed: " ^ Printexc.to_string e);
             Atomic.set m.ready (Some Failed);
             wake ()));
  m

(* ---- Changes of the rules or the ontology, in the background (the reasoner design, section 5.11; G19;
   spec/RuleChange.tla) ----
   A change (Reason: a group that changes the rules, or the ontology past a data write's budget) leaves the writer's
   batch ([prepare ~background:true]). A domain builds its consequences on a fork of the working view of the moment
   (Resolve.resolve with a change's budget: the materialisation of the state plus the change under the new rules),
   then catches up with the groups the writer prepares meanwhile, which the writer logs, by batches of all it finds
   (Resolve.catch_up: their net asserted changes, the new rules' consequences of them), keeping the difference
   between the writer's states (old rules) and its own (new rules) fact by fact. When a pass finds fewer than
   [change_behind] groups or takes less than [change_pass], the writer takes the rest, resolves the change's asserted part again against its own view (its Expects then: Conflict like any
   group's), and writes one group: the asserted changes, then the difference as derived changes, and makes the
   background's view its working view. No view before that group holds a fact of the new rules, every view from it
   holds all of them (G19). A change never runs beside a background merge (they would not share their runs): it waits
   for the merge in flight, and no merge starts while it runs.

   The texts: the writer interns the change's texts and its rules' constants into the working view before the fork,
   and each step of the catch-up takes the dictionary of the writer's view after the group, so the background never
   interns a text and its view's text numbers are the writer's: the view can be adopted. *)

let change_behind = 64
let change_pass = 0.005  (* seconds: a catch-up pass this short makes the background ready (the writer's last one is
                             shorter still) *)
let change_backlog = 65_536  (* groups logged and not yet taken by the background: past it the writer waits for it *)
let change_pause = ref 0.  (* seconds the background waits after its build, before its catch-up: the tests' interleavings *)
let changes_done = Atomic.make 0  (* installed changes, for the tests and benchmarks *)
let change_us = Histogram.create ()  (* a change in the background: from its start to the catch-up *)
let install_us = Histogram.create ()  (* the writer's part at its install: the last groups, the frame *)
let build_us = Histogram.create ()  (* a change's build alone: its consequences on the state it started from *)
let run_us = Histogram.create ()  (* the run of its own of a change's derived facts: sorted, written *)

(* a change whose derived facts set apart are at least this many writes them as a run of their own (as a group of
   [Resolve.large_min] operations takes the path of loads); tests make it small *)
let change_run_min = ref 20_000
let runs_installed = Atomic.make 0  (* changes installed with a run of their own, for the tests and benchmarks *)

(* a fact's states in the writer's lineage and in the change's view, where they differ: (thing, property, word) ->
   4 x writer's + change's (0 absent, 1 asserted, 2 only derived) *)
type diff = (int * int * int, int) Hashtbl.t

(* A large change's derived facts in a run of their own (the provisional run R, level 0), under the change's view's
   delta: the facts it adds that the view's delta holds no entry for (Reason.apart), sorted, written by a merge of
   them alone (no fsync: never named; recovery replays the change's frame). [rt]: a bit by row of R in its order by
   thing, set once the fact is in the table ([nt] of them): R's facts enter the table only when a step touches them,
   with the states (absent, derived) before, and stay there when their two states agree (the frame takes R's facts
   the table lacks as derived) *)
type run_of_its_own = { r : Store.run; file : string; facts : Bulk.t; things : Bytes.t; rt : Bytes.t; mutable nt : int }

type built = {
  bv : Store.view;  (* under the new rules: the state after [applied] logged groups, with the change *)
  diff : diff;
  own : Group.change array;  (* the change's asserted changes at the build *)
  own_keys : (int * int * int, unit) Hashtbl.t;  (* their facts *)
  limit : int;  (* its budget *)
  run : run_of_its_own option;
}

(* the row of R that holds (e p w) in its order by thing, or -1: a binary search *)
let run_row (f : Bulk.t) e p w =
  let cmp r =
    let i = Bulk.row f r in
    let e' = Bulk.thing f i in
    if e' <> e then compare (e' : int) e
    else
      let p' = Bulk.prop f i in
      if p' <> p then compare (p' : int) p else compare (Bulk.word f i : int) w
  in
  let lo = ref 0 and hi = ref f.n in
  while !lo < !hi do
    let m = (!lo + !hi) lsr 1 in
    if cmp m < 0 then lo := m + 1 else hi := m
  done;
  if !lo < f.n && cmp !lo = 0 then !lo else -1

let bit (b : Bytes.t) i = Char.code (Bytes.unsafe_get b (i lsr 3)) land (1 lsl (i land 7)) <> 0
let set_bit (b : Bytes.t) i = Bytes.unsafe_set b (i lsr 3) (Char.unsafe_chr (Char.code (Bytes.unsafe_get b (i lsr 3)) lor (1 lsl (i land 7))))

(* the run's file, when the change ends without its install *)
let drop_run t (b : built) = Option.iter (fun ro -> Pages.drop ro.r.a.pg; try t.disk.remove ro.file with Disk.Io _ -> ()) b.run

type outcome = Built of built | Ended of error

type change = {
  creq : req;
  cops : Resolve.op list * int * string;
  stop : bool Atomic.t;
  cm : Mutex.t;
  clog : (Group.t list * Store.view) Queue.t;  (* the batches prepared since the fork and not yet applied: their groups,
                                                   oldest first, and the writer's view after them *)
  mutable backlog : int;  (* the groups in [clog] *)
  out : outcome option Atomic.t;
  mutable cdom : unit Domain.t option;
  born : int;  (* the writer's lineage when it started (Raft) *)
}

exception Interfered of error

let before_of : Group.kind -> int = function Added | Derived -> 0 | Retracted | Now_derived -> 1 | Now_asserted | Underived -> 2

(* Facts with a small int each, by open addressing on (thing, property, word), in arrays: a step's states take no
   block a fact (a pass over thousands of groups found its facts in hash tables of tuples: a fifth of its time, and
   blocks the collector stops every domain for) *)
type facts = { mutable fn : int; mutable mask : int; mutable slot : int array; mutable xe : int array; mutable xp : int array;
               mutable xw : int array; mutable xs : int array }

let facts_create k =
  let size = ref 16 in
  while !size < 2 * k do size := 2 * !size done;
  let k = max 8 k in
  { fn = 0; mask = !size - 1; slot = Array.make !size 0; xe = Array.make k 0; xp = Array.make k 0; xw = Array.make k 0; xs = Array.make k 0 }

let[@inline] fhash e p w = let h = (e * 0x1E3779B97F4A7C15) lxor (p * 0x05EBCA77C2B2AE63) lxor (w * 0x165667B19E3779F9) in (h lxor (h lsr 29)) land max_int

(* the index of (e p w), or -1 *)
let facts_find f e p w =
  let i = ref (fhash e p w land f.mask) and r = ref (-2) in
  while !r = -2 do
    let x = Array.unsafe_get f.slot !i - 1 in
    if x < 0 then r := -1
    else if Array.unsafe_get f.xe x = e && Array.unsafe_get f.xp x = p && Array.unsafe_get f.xw x = w then r := x
    else i := (!i + 1) land f.mask
  done;
  !r

let facts_grow f =
  let n = Array.length f.xe * 2 in
  let ext a = let b = Array.make n 0 in Array.blit a 0 b 0 f.fn; b in
  f.xe <- ext f.xe; f.xp <- ext f.xp; f.xw <- ext f.xw; f.xs <- ext f.xs;
  let size = ref (Array.length f.slot) in
  while !size < 2 * n do size := 2 * !size done;
  f.slot <- Array.make !size 0;
  f.mask <- !size - 1;
  for x = 0 to f.fn - 1 do
    let i = ref (fhash f.xe.(x) f.xp.(x) f.xw.(x) land f.mask) in
    while f.slot.(!i) <> 0 do i := (!i + 1) land f.mask done;
    f.slot.(!i) <- x + 1
  done

(* (e p w) with [s] when it is new, else [upd] of its int *)
let facts_put f e p w s upd =
  let x = facts_find f e p w in
  if x >= 0 then f.xs.(x) <- upd f.xs.(x)
  else begin
    if f.fn = Array.length f.xe then facts_grow f;
    let x = f.fn in
    f.xe.(x) <- e; f.xp.(x) <- p; f.xw.(x) <- w; f.xs.(x) <- s;
    f.fn <- x + 1;
    let i = ref (fhash e p w land f.mask) in
    while f.slot.(!i) <> 0 do i := (!i + 1) land f.mask done;
    f.slot.(!i) <- x + 1
  end

(* a group's changes, each fact once: its state before the first change of it and after the last, as 4 b + a *)
let fact_states (v : Store.view) (cs : Group.change array) =
  let f = facts_create (Array.length cs) in
  Array.iter
    (fun (c : Group.change) ->
      match Store.word v c.v with
      | None -> ()
      | Some w ->
        let a = Group.after c.kind in
        facts_put f c.e c.p w ((before_of c.kind lsl 2) lor a) (fun st -> (st land lnot 3) lor a))
    cs;
  f

(* the difference after a step: [w] the writer's changes of facts, [c] the change's; a fact of R not in the table was
   absent in the writer's lineage and derived in the change's view, and stays in the table once there *)
let track (d : diff) (run : run_of_its_own option) (w : facts) (c : facts) =
  (* [ws], [cs]: the states 4 b + a of the fact on each side, -1 when that side did not touch it *)
  let one e p x ~ws ~cs =
    let ri = match run with Some ro when e lsr 3 < Bytes.length ro.things && bit ro.things e -> run_row ro.facts e p x | _ -> -1 in
    if ri < 0 && ws >= 0 && cs >= 0 && ws = cs && not (Hashtbl.mem d (e, p, x)) then ()  (* both sides alike, as before *)
    else begin
      let k = (e, p, x) in
      let w0, c0 =
        match Hashtbl.find_opt d k with
        | Some st -> st lsr 2, st land 3
        | None when ri >= 0 -> 0, 2
        | None -> let b = if ws >= 0 then ws lsr 2 else cs lsr 2 in b, b
      in
      let w1 = if ws >= 0 then ws land 3 else w0 and c1 = if cs >= 0 then cs land 3 else c0 in
      if w1 = c1 && ri < 0 then Hashtbl.remove d k
      else begin
        Hashtbl.replace d k ((w1 lsl 2) lor c1);
        match run with
        | Some ro when ri >= 0 && not (bit ro.rt ri) -> set_bit ro.rt ri; ro.nt <- ro.nt + 1
        | _ -> ()
      end
    end
  in
  for i = 0 to w.fn - 1 do
    let e = w.xe.(i) and p = w.xp.(i) and x = w.xw.(i) in
    let j = facts_find c e p x in
    one e p x ~ws:w.xs.(i) ~cs:(if j >= 0 then c.xs.(j) else -1)
  done;
  for j = 0 to c.fn - 1 do
    let e = c.xe.(j) and p = c.xp.(j) and x = c.xw.(j) in
    if facts_find w e p x < 0 then one e p x ~ws:(-1) ~cs:c.xs.(j)
  done

(* the logged batches not yet applied, oldest first, and how many groups they hold *)
let take_log ch =
  Mutex.protect ch.cm (fun () ->
      let l = List.of_seq (Queue.to_seq ch.clog) in
      Queue.clear ch.clog;
      let k = ch.backlog in
      ch.backlog <- 0;
      l, k)

(* the logged batches applied to the change's view at once (Resolve.catch_up); a group that touches a fact the change
   asserts, or a state the new rules refuse, ends the change with Conflict *)
let step ch b (bv : Store.view) (batches : (Group.t list * Store.view) list) =
  match List.rev batches with
  | [] -> bv
  | (_, dv) :: _ ->
    let gs = List.concat_map fst batches in
    List.iter
      (fun (g : Group.t) ->
        Array.iter
          (fun (c : Group.change) ->
            match c.kind with
            | Derived | Underived -> ()
            | _ when not (Array.exists (fun (o : Group.change) -> o.e = c.e && o.p = c.p) b.own) -> ()
            | _ -> (
              match Store.word dv c.v with
              | Some x when Hashtbl.mem b.own_keys (c.e, c.p, x) ->
                raise (Interfered (Conflict (Printf.sprintf "group %d, written meanwhile, changed [#%d %d %s], which the change writes" g.n c.e c.p (Value.to_string c.v))))
              | _ -> ()))
          g.changes)
      gs;
    let w = fact_states dv (Array.concat (List.map (fun (g : Group.t) -> g.changes) gs)) in
    match Resolve.catch_up ~limit:b.limit ~stop:ch.stop bv dv gs with
    | Error e -> raise (Interfered (of_resolve e))
    | Ok (bv', cs) ->
      track b.diff b.run w (fact_states bv' cs);
      let in_run = match b.run with Some ro -> ro.facts.n - ro.nt | None -> 0 in
      if Hashtbl.length b.diff + in_run > b.limit + Array.length b.own then
        raise (Interfered (Conflict (Printf.sprintf "the change derived more than %d facts with the groups written meanwhile" b.limit)));
      bv'

(* the change's derived facts set apart by the reasoner ([a]), sorted, as the run R on top of [bv]'s runs, under its
   delta (which holds no entry for them): written by a merge of them alone, at level 0, under a name of its own that
   ends in .tmp (an open removes it: Snapshot.clean), not forced. It holds no text: the texts interned since the
   newest run stay the dictionary's (its first text is the dictionary's first, so that a merge that takes R takes
   them from the dictionary, once) *)
let run_of_its_own t (bv : Store.view) (a : Reason.apart) =
  let t0 = Journal.clock () in
  let n = a.an in
  let e = Bigarray.Array1.sub a.ae 0 n and p = Bigarray.Array1.sub a.ap 0 n and w = Bigarray.Array1.sub a.aw 0 n in
  let sorted = Bulk.in_order e p w n in
  let order = if sorted then Bulk.i32 0 else Bulk.by_thing e p w n in
  let facts = Bulk.make ~d0:0 ~sorted ~order e p w n ~np:(Schema.count bv.schema) in
  let lo = if Array.length bv.runs = 0 then 0 else bv.runs.(0).hi in
  let file = Filename.concat (sdir t) (Snapshot.name lo bv.group ^ ".change" ^ Snapshot.tmp_suffix) in
  let alone = { bv with delta = Store.empty_delta; dict = { bv.dict with dnext = bv.dict.chunks.c0 } } in
  (* no journal position: R is never opened, nothing replays from it (the writer's, which moves on during the build,
     may be past the change's view) *)
  let none = { Journal.segment = 0; offset = 0; next = 0 } in
  let w = Snapshot.merge ~bulk:facts ~sync:false ~file t.disk (sdir t) t.id alone ~take:0 ~level:0 none in
  let r = w.view.runs.(0) in
  (* its things, a bit each: most facts a step touches are of other things, found so with one bit *)
  let top = ref 0 in
  for i = 0 to n - 1 do top := max !top (Int32.to_int (Bigarray.Array1.unsafe_get e i)) done;
  let things = Bytes.make ((!top / 8) + 1) '\000' in
  for i = 0 to n - 1 do set_bit things (Int32.to_int (Bigarray.Array1.unsafe_get e i)) done;
  Histogram.record run_us (Journal.clock () - t0);
  { bv with runs = Array.append [| r |] bv.runs }, { r; file; facts; things; rt = Bytes.make ((n + 7) / 8) '\000'; nt = 0 }

(* the background: the build, then the catch-up until fewer than [change_behind] groups are left *)
let change_run ~wake t ch (w0 : Store.view) =
  let t0 = Journal.clock () in
  let ops, by, why = ch.cops in
  let ended e = Atomic.set ch.out (Some (Ended e)) in
  let made = ref None in
  (match
     let limit = ref 0 in
     let apart = Reason.apart ~min:(if Store.provisionals w0.runs >= max_provisional then max_int else !change_run_min) in
     let reason ~v0 v changes words =
       limit := !Reason.budget_base + (!Reason.budget_per * Array.length changes) + (!Reason.change_per * Store.facts v0);
       Reason.run ~limit:!limit ~stop:ch.stop ~apart ~v0 v changes words
     in
     match Resolve.resolve (Store.fork w0) ~n:(w0.group + 1) ~time:0 ~by ~why ~reason ops with
     | Error e -> ended (of_resolve e)
     | Ok (bv, g, _) ->
       Histogram.record build_us (Journal.clock () - t0);
       let bv, run =
         if apart.an = 0 then bv, None
         else begin
           let bv, ro = run_of_its_own t bv apart in
           made := Some ro;
           bv, Some ro
         end
       in
       let diff : diff = Hashtbl.create (Array.length g.changes + 16) in
       track diff None (facts_create 0) (fact_states bv g.changes);
       let own = Array.of_list (List.filter (fun (c : Group.change) -> c.kind <> Derived && c.kind <> Underived) (Array.to_list g.changes)) in
       let own_keys = Hashtbl.create 8 in
       Array.iter (fun (c : Group.change) -> match Store.word bv c.v with Some x -> Hashtbl.replace own_keys (c.e, c.p, x) () | None -> ()) own;
       let b = ref { bv; diff; own; own_keys; limit = !limit; run } in
       if !change_pause > 0. then Unix.sleepf !change_pause;
       let go = ref true in
       while !go do
         if Atomic.get ch.stop then raise (Interfered Closed);
         let batches, k = take_log ch in
         let tq = Unix.gettimeofday () in
         b := { !b with bv = step ch !b !b.bv batches };
         let dt = Unix.gettimeofday () -. tq in
         (* ready: few groups left, or a pass short enough that the writer's last one stays short *)
         if k < change_behind || dt < change_pass then go := false
       done;
       Histogram.record change_us (Journal.clock () - t0);
       Atomic.set ch.out (Some (Built !b))
   with
   | () -> ()
   | exception e ->
     (* the run of a change that ends here goes with it *)
     Option.iter (fun ro -> Pages.drop ro.r.a.pg; try t.disk.remove ro.file with Disk.Io _ -> ()) !made;
     match e with
     | Interfered e -> ended e
     | Pages.Unreadable m -> ended (Damaged m)
     | Disk.Io m -> ended (Io m)
     | e ->
       prerr_endline ("cepheus: a change of the rules failed: " ^ Printexc.to_string e);
       ended (Invalid ("the change failed: " ^ Printexc.to_string e)));
  wake ()

(* The follow stream (the server's local readers, server/follow.ml): [before b] as the syncer takes the frame of [b],
   before it is written; [after ()] once it is durable and published, before its writers are answered. Both run in
   the syncer, one frame at a time. *)
type follow = { before : batch -> unit; after : unit -> unit }

let no_follow = { before = ignore; after = ignore }

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
  follow : follow;
  mutable replica : bool;  (* takes its primary's frames (Apply) and no write; a promotion ends it *)
  raft : bool;  (* a member of a Raft cluster: writes and Apply both, each write's frame proposed before it is written *)
  mutable propose : int -> int -> Bytes.t -> (unit, error) result;
      (* Raft: the frame of groups [first, first + count), whole, proposed; Ok once committed, Error if this server
         stopped leading before *)
  mutable rollback : bool;  (* a proposed frame was not committed: the working view goes back to the published one *)
  mutable lineage : int;
      (* Raft: one more each time the working view leaves this writer's own line (a proposed frame not committed and
         taken back, a frame of another leader applied): a change of the rules started on an older lineage is never
         installed, it is answered not_leader *)
  mutable change : change option;  (* the change in the background *)
  mutable waiting : (req * Store.view) list;  (* the changes that wait for it, or for the merge in flight, oldest first *)
}

let deliver r res =
  Mutex.lock r.rm;
  r.res <- Some res;
  Condition.signal r.rc;
  Mutex.unlock r.rm

let submit l c =
  Mutex.lock l.m;
  if l.closed then (Mutex.unlock l.m; false)
  else begin
    l.queue <- c :: l.queue;
    Condition.signal l.c_req;
    Mutex.unlock l.m;
    true
  end

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
      let results =
        if l.raft && b.own && b.count > 0 && l.e.stopped = None then
          (* proposed first; written, published and seen by the hooks only once committed *)
          match l.propose b.first b.count (Journal.frame_bytes b.body b.first b.count) with
          | Ok () -> l.follow.before b; let r = commit l.e b in l.follow.after (); r
          | Error e ->
            Mutex.protect l.sm (fun () -> l.rollback <- true);
            Array.map (function Ok _ -> Error e | r -> r) b.results
        else begin
          l.follow.before b;
          let r = commit l.e b in
          l.follow.after ();
          r
        end
      in
      Array.iteri (fun i r -> deliver r results.(i)) reqs;
      Mutex.lock l.sm;
      l.syncing <- false;
      Condition.broadcast l.c_sync;
      Mutex.unlock l.sm
  done

(* Raft: the working view leaves this writer's own line; a change of the rules in the background, which started from
   it or logged its groups, is stopped, and answered not_leader when the writer polls it *)
let break_lineage l =
  l.lineage <- l.lineage + 1;
  Option.iter (fun ch -> Atomic.set ch.stop true) l.change

(* Raft: the working view back to the published one, after a proposed frame that was not committed *)
let roll_back l =
  if l.rollback then begin
    l.e.working <- Atomic.get l.e.published;
    sweep l.e;
    break_lineage l;
    Mutex.protect l.sm (fun () -> l.rollback <- false)
  end

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
     | Some (Done (w, _, _)) when l.rollback ->
       (* it started from groups that were not committed: abandoned (the working view goes back below) *)
       Snapshot.abandon l.e.disk w
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
    roll_back l;
    Histogram.record switch_us (Journal.clock () - t0)

(* Raft: nothing in flight, and the working view back if the last proposed frame was not committed (a merge started
   from it abandoned) *)
let settle l =
  wait_idle l;
  if l.rollback then (match l.merging with Some _ -> finish_merge l | None -> roll_back l)

let max_batch = 4096
let max_frame = 8 lsl 20

(* two batches prepared one after the other, as one frame (never a large group's, which has its own) *)
let merge a b =
  if Option.is_some a.pending || Option.is_some b.pending then invalid_arg "Engine.merge: a frame of its own";
  let body = Buffer.create (Buffer.length a.body + Buffer.length b.body) in
  Buffer.add_buffer body a.body;
  Buffer.add_buffer body b.body;
  { results = Array.append a.results b.results; groups = b.groups @ a.groups; body; first = a.first;
    count = a.count + b.count; after = b.after; runs = b.runs @ a.runs; pending = None; own = a.own && b.own; change = None }

(* a batch to the syncer: while it forces the previous frame, the next one grows: everything that arrived meanwhile goes
   into one frame and one fsync (group commit), within the frame limit; a change in the background logs its groups *)
let hand l b reqs =
  Mutex.lock l.sm;
  while
    match l.to_sync with
    | Some (b0, _) ->
      Option.is_some b0.pending || Option.is_some b.pending || b0.runs <> [] || b.runs <> [] || Buffer.length b0.body > max_frame
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
  match l.change with
  | Some ch when b.count > 0 -> Mutex.protect ch.cm (fun () -> Queue.push (List.rev b.groups, b.after) ch.clog; ch.backlog <- ch.backlog + b.count)
  | _ -> ()

(* after a batch handed: its groups logged for the merge in flight, which is switched to when it is done; or a merge
   started, when the delta is large enough and no change of the rules runs or waits (they would not share their runs) *)
let to_merge l (b : batch) =
  match l.merging with
  | Some m ->
    Mutex.lock m.lm;
    m.log <- b.groups @ m.log;
    m.logn <- m.logn + b.count;
    Mutex.unlock m.lm;
    if Atomic.get m.ready <> None then finish_merge l
  | None ->
    if needs_compaction l.e.working && l.e.working.delta.dn > l.retry && l.e.stopped = None && l.change = None && l.waiting = [] then
      l.merging <- Some (start_merge ~wake:(fun () -> ignore (submit l Wake)) l.e l.e.working)

(* The change's install, by the writer: the groups logged since the background was ready, the asserted part again
   against the working view (its Expects; the same as the build's, or Conflict), the frame (the asserted changes in
   their order, then the difference as derived changes), handed to the syncer; the change's view adopted. In a Raft
   cluster, once nothing is in flight (its frame is proposed alone, as every write's), and only on the lineage it
   started from: its view holds no group that was not committed, and every group another leader wrote. *)
let install_change l ch (b : built) =
  let t = l.e in
  let t0 = Journal.clock () in
  if l.raft then settle l;
  match t.stopped with
  | Some e -> drop_run t b; deliver ch.creq (Error e)
  | None when ch.born <> l.lineage -> drop_run t b; deliver ch.creq (Error not_leader)
  | None -> (
    match
      let batches, _ = take_log ch in
      let bv = step ch b b.bv batches in
      let ops, by, why = ch.cops in
      let n = t.working.group + 1 in
      let reason ~v0:_ (v : Store.view) (asserted : Group.change array) _ =
        let same =
          Array.length asserted = Array.length b.own
          && Array.for_all2
               (fun (a : Group.change) (o : Group.change) -> a.e = o.e && a.p = o.p && Value.equal a.v o.v && Group.after a.kind = Group.after o.kind)
               asserted b.own
        in
        if not same then raise (Interfered (Conflict "the facts of the change were written meanwhile"));
        if not (Store.IM.is_empty bv.dict.extra) then raise (Interfered (Conflict "the change met a text the writer had not interned"));
        (* the view adopted: the writer's dictionary (the same numbers), its things marked touched *)
        let tb = v.touched in
        let f = bv.ftouched in
        let bits = Store.grown tb.bits ((8 * Bytes.length f) - 1) in
        for i = 0 to Bytes.length f - 1 do
          Bytes.unsafe_set bits i (Char.unsafe_chr (Char.code (Bytes.unsafe_get bits i) lor Char.code (Bytes.unsafe_get f i)))
        done;
        if bits != tb.bits then tb.bits <- bits;
        let va = { bv with writer = true; dict = v.dict; touched = tb; ftouched = Bytes.empty; schema = bv.schema } in
        (* the frame: each fact of the difference with its kind; the asserted ones first, in the group's order *)
        let kind st : Group.kind =
          match st lsr 2, st land 3 with
          | 0, 1 -> Added | 2, 1 -> Now_asserted | 1, 0 -> Retracted | 1, 2 -> Now_derived | 0, 2 -> Derived | _ -> Underived
        in
        let value p w = match Schema.find va.schema p with Some d -> Store.value va d.typ w | None -> Value.Int w in
        let first =
          List.filter_map
            (fun (o : Group.change) ->
              match Store.word va o.v with
              | Some w -> (match Hashtbl.find_opt b.diff (o.e, o.p, w) with Some st -> Some { o with kind = kind st } | None -> None)
              | None -> None)
            (Array.to_list b.own)
        in
        (* the table's facts whose two states differ (R's that agree stay there, and are none of the frame's) *)
        let differs st = st lsr 2 <> st land 3 in
        let derived st = differs st && st lsr 2 <> 1 && st land 3 <> 1 in
        let nt = Hashtbl.fold (fun _ st n -> if derived st then n + 1 else n) b.diff 0 in
        let nr = match b.run with Some ro -> ro.facts.n - ro.nt | None -> 0 in
        let nd = nt + nr in
        if nd > b.limit then raise (Interfered (Invalid (Printf.sprintf "a change of the rules or the ontology derived more than %d facts" b.limit)));
        let de = Array.make nt 0 and dp = Array.make nt 0 and dw = Array.make nt 0 and ds = Array.make nt 0 in
        let i = ref 0 in
        Hashtbl.iter
          (fun ((e, p, w) as k) st ->
            if derived st then (de.(!i) <- e; dp.(!i) <- p; dw.(!i) <- w; ds.(!i) <- st; incr i)
            else if differs st && not (Hashtbl.mem b.own_keys k) then
              raise (Interfered (Conflict (Printf.sprintf "the change's view differs on an asserted fact [#%d %d]" e p))))
          b.diff;
        (* in the table's order, then R's facts the table lacks, in thing order: replay applies states, and the order of
           facts of one group does not matter to it *)
        let frame = Array.init nt (fun j -> { Group.kind = kind ds.(j); e = de.(j); p = dp.(j); v = value dp.(j) dw.(j) }) in
        let from_run =
          match b.run with
          | None -> [||]
          | Some ro ->
            let f = ro.facts in
            let out = Array.make nr { Group.kind = Derived; e = 0; p = 0; v = Value.Int 0 } in
            let j = ref 0 in
            for r = 0 to f.n - 1 do
              if not (bit ro.rt r) then begin
                let x = Bulk.row f r in
                let p = Bulk.prop f x in
                out.(!j) <- { Group.kind = Derived; e = Bulk.thing f x; p; v = value p (Bulk.word f x) };
                incr j
              end
            done;
            out
        in
        va, Array.concat [ Array.of_list first; frame; from_run ]
      in
      match Resolve.resolve t.working ~n ~time:(t.disk.now ()) ~by ~why ~reason ops with
      | Error e -> Error (of_resolve e)
      | Ok (v, g, temps) ->
        let body = Buffer.create 4096 in
        Group.encode body g;
        if Buffer.length body > !frame_limit then Error (too_large (Buffer.length body))
        else begin
          t.working <- v;
          Option.iter (fun ro -> Mutex.protect t.pm (fun () -> t.provisional <- (ro.r, ro.file) :: t.provisional); Atomic.incr runs_installed) b.run;
          Atomic.incr changes_done;
          hand l { results = [| Ok { group = n; things = temps } |]; groups = [ g ]; body; first = n; count = 1; after = v; runs = [];
                   pending = None; own = true; change = None } [| ch.creq |];
          Ok ()
        end
    with
    | Ok () -> Histogram.record install_us (Journal.clock () - t0)
    | Error e -> drop_run t b; deliver ch.creq (Error e)
    | exception Interfered e -> drop_run t b; deliver ch.creq (Error e)
    | exception Pages.Unreadable m -> drop_run t b; deliver ch.creq (Error (Damaged m)))

(* the change in the background, if it is done: installed or answered; else the next waiting one started, when no
   merge is in flight. A start interns the change's texts into the working view, then forks it. *)
let rec poll_change l =
  match l.change with
  | Some ch -> (
    match Atomic.get ch.out with
    | None -> ()
    | Some o ->
      Option.iter Domain.join ch.cdom;
      l.change <- None;
      (match o with
       | Built b when ch.born <> l.lineage -> drop_run l.e b; deliver ch.creq (Error not_leader)
       | _ when ch.born <> l.lineage -> deliver ch.creq (Error not_leader)
       | Built b -> install_change l ch b
       | Ended e -> deliver ch.creq (Error e));
      poll_change l)
  | None -> (
    match l.waiting with
    | (r, va) :: rest when l.merging = None ->
      l.waiting <- rest;
      if l.e.stopped <> None then (deliver r (Error (Option.get l.e.stopped)); poll_change l)
      else begin
        let ops, _, _ = r.w in
        let texts =
          List.filter_map
            (function Resolve.Add (_, _, x) | Retract (_, _, x) | Expect (_, _, Some x) -> Some x | Expect (_, _, None) | Incr _ -> None)
            ops
          @ Reason.constants va
        in
        let w =
          List.fold_left (fun v (x : Value.t) -> match x with Text _ | Float _ -> fst (Store.word_intern v x) | _ -> v) l.e.working texts
        in
        l.e.working <- w;
        let ch =
          { creq = r; cops = r.w; stop = Atomic.make false; cm = Mutex.create (); clog = Queue.create (); backlog = 0; out = Atomic.make None;
            cdom = None; born = l.lineage }
        in
        (* a domain the runtime cannot give (its limit) answers the change, never stops the writer *)
        match Domain.spawn (fun () -> change_run ~wake:(fun () -> ignore (submit l Wake)) l.e ch w) with
        | d -> ch.cdom <- Some d; l.change <- Some ch
        | exception e -> deliver r (Error (Busy ("a change of the rules could not start: " ^ Printexc.to_string e))); poll_change l
      end
    | _ -> ())

(* waits for the change in the background and installs it (before a large group or a snapshot) *)
let finish_change l =
  match l.change with
  | Some ch -> Option.iter Domain.join ch.cdom; ch.cdom <- None; poll_change l
  | None -> ()

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
      | Write r :: rest when l.replica ->
        deliver r (Error (Busy "this database is a replica: it takes its primary's groups, and no write"));
        handle rest
      | Apply (r, _) :: rest when not (l.replica || l.raft) ->
        deliver r (Error (Busy "this database is not a replica: it takes no frame"));
        handle rest
      | Apply (r, f) :: rest ->
        (* Raft: another leader's frame; a change of the rules started here is not installed (its lineage is gone) *)
        if l.raft then (settle l; break_lineage l);
        (match decode_frame f with
         | Error e -> deliver r (Error e)
         | Ok gs -> (
           (* a large group merges at once with the newest runs: no merge beside it, nothing in flight *)
           if maybe_large gs then (finish_merge l; wait_idle l);
           match prepare_apply l.e f gs with
           | Error e -> deliver r (Error e)
           | Ok b -> hand l b [| r |]; to_merge l b));
        handle rest
      | Write _ :: _ ->
        (* Raft: nothing in flight, so that a frame that is not committed takes back nothing but itself *)
        if l.raft then settle l;
        let ws, rest = split [] items in
        let reqs = Array.of_list ws in
        (* a large group merges at once with the newest runs: no merge may run beside it; and it writes its frame as it
           goes: the frame before it must be durable first *)
        if Array.exists (fun r -> let ops, _, _ = r.w in List.compare_length_with ops !Resolve.large_min >= 0) reqs then begin
          finish_change l;
          finish_merge l;
          wait_idle l
        end;
        let t0 = Journal.clock () in
        let b = prepare ~release:(fun i -> reqs.(i).w <- ([], 0, "")) ~background:true l.e (Array.map (fun r -> r.w) reqs) in
        Histogram.record prepare_us (Journal.clock () - t0);
        (* the requests the frame did not take go first in the next one *)
        let taken = Array.length b.results in
        let left = List.filteri (fun i _ -> i >= taken) ws in
        let reqs = Array.sub reqs 0 taken in
        (* a change found at the end of the prefix: it waits its turn for the background path *)
        let left =
          match b.change, left with
          | Some va, r :: left -> l.waiting <- l.waiting @ [ (r, va) ]; left
          | _ -> left
        in
        if Array.length reqs > 0 then hand l b reqs;
        to_merge l b;
        (* a change far behind: the writer waits for it, so that its log and the deltas stay bounded *)
        (match l.change with Some ch when Mutex.protect ch.cm (fun () -> ch.backlog) > change_backlog -> finish_change l | _ -> ());
        poll_change l;
        handle (List.map (fun r -> Write r) left @ rest)
      | Snapshot r :: rest ->
        finish_change l;
        finish_merge l;
        wait_idle l;
        deliver r (Result.map (fun () -> { group = l.e.working.group; things = [] }) (snapshot l.e));
        poll_change l;
        handle rest
      | Wake :: rest ->
        (match l.merging with Some m when Atomic.get m.ready <> None -> finish_merge l | _ -> ());
        poll_change l;
        handle rest
      | Stop :: rest ->
        (* a change in the background is cancelled: nothing of it was written *)
        (match l.change with
         | Some ch ->
           Atomic.set ch.stop true;
           Option.iter Domain.join ch.cdom;
           l.change <- None;
           (match Atomic.get ch.out with Some (Built b) -> drop_run l.e b | _ -> ());
           deliver ch.creq (Error Closed)
         | None -> ());
        List.iter (fun (r, _) -> deliver r (Error Closed)) l.waiting;
        l.waiting <- [];
        finish_merge l;
        wait_idle l;
        List.iter (function Write r | Snapshot r | Apply (r, _) -> deliver r (Error Closed) | Wake | Stop -> ()) rest;
        go := false
    in
    handle items
  done;
  Mutex.lock l.sm;
  l.closed <- true;
  Condition.broadcast l.c_sync;
  Mutex.unlock l.sm

let start ?(follow = no_follow) ?(replica = false) ?(raft = false) e =
  let l =
    { e; m = Mutex.create (); c_req = Condition.create (); queue = []; sm = Mutex.create (); c_sync = Condition.create ();
      to_sync = None; syncing = false; domain = None; closed = false; merging = None; retry = 0; follow; replica; raft;
      propose = (fun _ _ _ -> Error (Busy "no Raft yet")); rollback = false; change = None; waiting = []; lineage = 0 }
  in
  (* the writer and the syncer in a domain of their own: they never wait for the runtime lock of the clients *)
  l.domain <- Some (Domain.spawn (fun () ->
      let a = Thread.create (writer l) () and b = Thread.create (syncer l) () in
      Thread.join a;
      Thread.join b));
  l

let call l make =
  let r = { w = ([], 0, ""); res = None; rm = Mutex.create (); rc = Condition.create () } in
  let r = make r in
  match r with
  | Write q | Snapshot q | Apply (q, _) ->
    if not (submit l r) then Error Closed
    else begin
      Mutex.lock q.rm;
      while q.res = None do Condition.wait q.rc q.rm done;
      Mutex.unlock q.rm;
      Option.get q.res
    end
  | Wake | Stop -> Ok { group = 0; things = [] }

let write l ops by why = call l (fun r -> Write { r with w = (ops, by, why) })

(* A replica's promotion: from the next control on, its writer takes writes and refuses frames. Called once every frame
   given is durable (the follower stopped and waited), so that no write resolves on a state the primary's frames
   would still change. *)
let promote l =
  Mutex.lock l.m;
  l.replica <- false;
  Mutex.unlock l.m
let snapshot_live l = call l (fun r -> Snapshot r)

let stop l =
  if submit l Stop then Option.iter Domain.join l.domain;
  close l.e
