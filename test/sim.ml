(* Deterministic simulation. One seed decides everything: the writes, the order of prepare and commit (the writer
   runs one batch ahead of the disk, as the threaded writer does), snapshots, compactions, forks, power losses,
   crashes in the middle of any disk call, failing fsyncs, and bits flipped in durable files. After every recovery
   the state is compared with the reference model (the recorded groups applied to a set of facts). A failure prints
   its seed; [sim.exe --seed N] replays it exactly.

   Checked: G1 durable, G2 all or nothing, G3 prefix, G5 published views are durable, G6 damage detected, G7
   snapshots, G8 forks, G10 stop after a failed fsync, G11 questions (their answers, and their work within the Generic
   Join bound, on views with a delta and after recoveries). *)

open Cepheus
module C = Check

let dir = "/db"
let jdir = "/db/journal"
let sdir = "/db/snapshots"

let props =
  [ prop "name" Ttext; prop ~many:true "tag" Ttext; prop "score" Tint; prop ~unique:true "mail" Ttext;
    prop ~many:true "friend" Tlink; prop "at" Tdate; prop "w" Tfloat; prop "price" (Tmoney 2); prop "ok" Tbool ]

type w = {
  seed : int;
  sim : Sim_disk.t;
  disk : Disk.t;
  r : Rng.t;
  mutable e : Engine.t option;
  groups : (int, Group.t) Hashtbl.t;
  mutable acked : int;
  mutable prepared : int;
  mutable pending : Engine.batch option;
  mutable flipped_journal : bool;
  mutable in_newest_frame : bool;  (* the flip hit the newest frame: the known residual (docs/guarantees.md, G6) *)
  mutable stopped : bool;  (* a failed fsync: the engine must refuse everything until restart *)
}

let stats = Hashtbl.create 16
let count k = Hashtbl.replace stats k (1 + Option.value (Hashtbl.find_opt stats k) ~default:0)
let fail w fmt = Printf.ksprintf (fun s -> C.fail "seed %d: %s" w.seed s) fmt

exception Over

let model w k =
  let s = ref C.F.empty in
  for n = 1 to k do
    match Hashtbl.find_opt w.groups n with
    | Some g -> s := C.apply_group !s g
    | None -> fail w "group %d was never recorded" n; raise Over
  done;
  !s

let pid (v : Store.view) name = Schema.by_name v.schema name

let declare_ops (v : Store.view) =
  let next = ref Schema.first_prop and ops = ref [] in
  List.iter
    (fun (d : prop) ->
      if pid v d.name = None then begin
        while Schema.find v.schema !next <> None do incr next done;
        let p = !next in
        incr next;
        ops := !ops @ List.map (fun (e, q, x) -> Add (e, q, x)) (Schema.facts p d)
      end)
    props;
  !ops

let gen_ops w (v : Store.view) =
  match declare_ops v with
  | _ :: _ as ops -> ops
  | [] ->
    let p n = Option.get (pid v n) in
    let r = w.r in
    let things = v.next_e - Schema.first_thing in
    let some () = if things = 0 then -1 else Schema.first_thing + Rng.int r things in
    let small = [| "a"; "b"; "c"; "d" |] in
    let one () =
      match Rng.int r 14 with
      | 0 | 1 -> [ Add (-1, p "name", Text ("n" ^ Rng.pick r small)); Add (-1, p "score", Int (Rng.int r 5)) ]
      | 2 -> [ Add (some (), p "score", Int (Rng.int r 5)) ]
      | 3 -> [ Add (some (), p "tag", Text (Rng.pick r small)) ]
      | 4 -> [ Retract (some (), p "tag", Text (Rng.pick r small)) ]
      | 5 -> [ Add (some (), p "mail", Text (Rng.pick r small ^ "@x")) ]
      | 6 -> [ Add (some (), p "friend", Link (some ())) ]
      | 7 -> [ Expect (some (), p "score", Some (Int (Rng.int r 5))); Add (some (), p "score", Int 9) ]
      | 8 -> [ Expect (some (), p "mail", None); Add (some (), p "ok", Bool (Rng.bool r)) ]
      | 9 -> [ Add (some (), p "w", Float (float_of_int (Rng.int r 7) /. 3.)); Add (some (), p "at", Date (Rng.int r 1000)) ]
      | 10 -> [ Add (some (), p "price", Money (Rng.int r 100000)) ]
      | 11 -> [ Add (some (), p "score", Text "wrong type") ]
      | 12 ->
        (* a long text, so that frames cross sectors *)
        [ Add (-1, p "name", Text (String.make (Rng.int r 900) 'x')) ]
      | _ -> [ Retract (some (), p "friend", Link (some ())) ]
    in
    List.concat (List.init (1 + Rng.int r 3) (fun _ -> one ()))

let engine w = match w.e with Some e -> e | None -> raise Over

(* the facts of the published view must be those of the durable groups (G5) *)
let check_published w =
  let e = engine w in
  let v = Atomic.get e.published in
  if v.group < w.acked then fail w "published group %d is before the acknowledged %d" v.group w.acked;
  let got = C.facts_of_view v and want = model w v.group in
  if not (C.F.equal got want) then fail w "published view at %d differs from the model: %s" v.group (C.show_diff got want);
  (* questions on the view: the answers of the naive evaluator on the model, within the Generic Join bound (G11) *)
  for _ = 1 to 3 do
    match C.random_query w.r v want (List.map (fun (d : prop) -> d.name) props) with
    | None -> ()
    | Some q -> (
      count "questions";
      match C.work_and_bound v want q (fun () -> find v q) with
      | Ok rows, work, bound ->
        let n = List.length rows and m = List.length (C.naive want q) in
        if C.sorted_rows rows <> C.naive want q then fail w "a question gives %d rows, the naive evaluator %d" n m;
        if work > bound then fail w "a question enumerated %d candidates, its Generic Join bound is %d" work bound
      | Error e, _, _ -> fail w "a question failed: %s" (message e))
  done

let snapshot_files w = List.filter (fun f -> Filename.dirname f = sdir) (Sim_disk.files w.sim)

let rec recover w =
  count "recoveries";
  w.e <- None;
  w.pending <- None;
  w.stopped <- false;
  Sim_disk.crash w.sim;
  if Rng.chance w.r 0.15 then Sim_disk.crash_after w.sim (Rng.int w.r 12);
  match Engine.open_ ~id_source:(fun _ -> "0123456789abcdef") w.disk dir with
  | exception Sim_disk.Crash -> count "crash during recovery"; recover w
  | Error (Damaged m) ->
    if w.flipped_journal then (count "damage refused at open"; raise Over)
    else (fail w "recovery says damaged: %s" m; raise Over)
  | Error e -> fail w "recovery failed: %s" (Engine.message e); raise Over
  | Ok e ->
    Sim_disk.crash_after w.sim (-1);
    let k = e.working.group in
    if Journal.next_group e.journal <> k + 1 then
      fail w "journal next %d after recovery to %d; files %s" (Journal.next_group e.journal) k
        (String.concat " " (List.map (fun f -> Printf.sprintf "%s:%d" f (Sim_disk.durable_size w.sim f)) (Sim_disk.files w.sim)));
    if k < w.acked && w.flipped_journal && w.in_newest_frame then (count "residual: newest frame damaged, cut as torn"; raise Over);
    if k < w.acked then fail w "lost acknowledged groups: recovered %d, acknowledged %d" k w.acked;
    if k > w.prepared && w.prepared > 0 then fail w "recovered %d groups, only %d were prepared" k w.prepared;
    (* the groups on disk are exactly the recorded ones (G2, G3) *)
    if not w.flipped_journal then
    (try
       Journal.read w.disk jdir e.id (fun g ->
           match Hashtbl.find_opt w.groups g.n with
           | Some g' -> if not (Group.equal g g') then fail w "group %d differs from what was written" g.n
           | None -> if g.n > 1 then fail w "group %d was never written" g.n)
     with Journal.Damaged m -> fail w "journal unreadable after recovery: %s" m);
    (* group 1 of a fresh database is the bootstrap, recorded now *)
    if k >= 1 && not (Hashtbl.mem w.groups 1) then fail w "no record of group 1";
    Hashtbl.filter_map_inplace (fun n g -> if n <= k then Some g else None) w.groups;
    w.prepared <- k;
    w.e <- Some e;
    let got = C.facts_of_view e.working and want = model w k in
    if not (C.F.equal got want) then fail w "recovered state at %d differs from the model: %s" k (C.show_diff got want);
    if w.flipped_journal then (count "damage before the snapshot, not needed"; raise Over)

let record_batch w (b : Engine.batch) =
  let r = Codec.reader (Buffer.to_bytes b.body) 0 (Buffer.length b.body) in
  for _ = 1 to b.count do
    let g = Group.decode r in
    Hashtbl.replace w.groups g.n g;
    w.prepared <- max w.prepared g.n
  done

let commit_pending w =
  match w.pending with
  | None -> ()
  | Some b ->
    w.pending <- None;
    let jn = Journal.next_group (engine w).journal in
    if b.count > 0 && b.first <> jn && not w.stopped then fail w "batch starts at %d, journal at %d (stopped %b)" b.first jn ((engine w).stopped <> None);
    let res = Engine.commit (engine w) b in
    Array.iter
      (function
        | Ok (r : Engine.receipt) ->
          if w.stopped then fail w "a write was confirmed after a failed fsync";
          w.acked <- max w.acked r.group;
          count "acked"
        | Error (Io _) -> w.stopped <- true; count "io error"
        | Error _ -> count "refused")
      res

let step w =
  let e = engine w in
  match Rng.int w.r 100 with
  | n when n < 45 ->
    if w.pending = None then begin
      let reqs = Array.init (1 + Rng.int w.r 5) (fun _ -> gen_ops w e.working, Rng.int w.r 9, "w") in
      let b = Engine.prepare e reqs in
      record_batch w b;
      w.pending <- Some b
    end
    else commit_pending w
  | n when n < 60 -> commit_pending w
  | n when n < 66 ->
    commit_pending w;
    if not w.stopped then begin
      match Engine.snapshot e with Ok () -> count "snapshots" | Error _ -> ()
    end
  | n when n < 70 -> commit_pending w; if not w.stopped then Engine.compact e
  | n when n < 74 -> count "power losses"; recover w
  | n when n < 77 -> Sim_disk.crash_after w.sim (Rng.int w.r 20)
  | n when n < 79 -> Sim_disk.fail_next_fsync w.sim
  | n when n < 81 ->
    commit_pending w;
    (* a silent change of durable journal bytes, then a restart: must be detected (G6) *)
    if w.pending = None && not w.stopped then begin
      let segs = List.filter (fun f -> Filename.dirname f = jdir) (Sim_disk.files w.sim) in
      let f = List.nth segs (Rng.int w.r (List.length segs)) in
      let last_seg = List.nth segs (List.length segs - 1) in
      let b = Sim_disk.durable_bytes w.sim last_seg in
      (* the start of the newest frame of the newest segment *)
      let rec walk p last = if p + 28 > Bytes.length b then last else walk (p + 28 + (Int32.to_int (Bytes.get_int32_le b (p + 4)) land 0xFFFFFFFF) + 16) p in
      let newest = walk 40 40 in
      match Sim_disk.flip_durable w.sim f 40 (Sim_disk.durable_size w.sim f) with
      | None -> ()
      | Some off ->
        w.in_newest_frame <- f = last_seg && off >= newest;
        count "journal flips";
        (* a full read (verify, scrub) must see it *)
        (match Journal.read w.disk jdir e.id (fun _ -> ()) with
         | () -> fail w "a flipped bit in %s was not detected by a full read" f
         | exception Journal.Damaged _ -> count "damage detected");
        (* recovery must either refuse, or not need the damaged part (it lies before the snapshot) *)
        w.flipped_journal <- true;
        recover w
    end
  | n when n < 84 -> (
    (* a damaged snapshot is set aside, never served (G7) *)
    match snapshot_files w with
    | [] -> ()
    | fs ->
      let f = List.nth fs (Rng.int w.r (List.length fs)) in
      if Sim_disk.flip_durable w.sim f 0 (Sim_disk.durable_size w.sim f) <> None then count "snapshot flips";
      recover w)
  | n when n < 90 ->
    (* forks: written to at will, they change nothing for the database or its files (G8) *)
    let v = Atomic.get e.published in
    let before = List.map (fun f -> f, Sim_disk.durable_bytes w.sim f) (Sim_disk.files w.sim) in
    let facts = C.facts_of_view v in
    let f = fork v in
    for _ = 1 to 1 + Rng.int w.r 4 do ignore (write f (gen_ops w (view f))) done;
    let f2 = fork (view f) in
    ignore (write f2 (gen_ops w (view f2)));
    if not (C.F.equal facts (C.facts_of_view v)) then fail w "a fork changed the database's view";
    List.iter (fun (p, b) -> if not (Bytes.equal b (Sim_disk.durable_bytes w.sim p)) then fail w "a fork changed %s" p) before;
    count "forks"
  | _ -> if w.pending = None then check_published w

let run seed steps =
  let r = Rng.make seed in
  let sim = Sim_disk.create (Rng.split r) in
  let w =
    { seed; sim; disk = Sim_disk.disk sim; r; e = None; groups = Hashtbl.create 64; acked = 0; prepared = 0; pending = None;
      flipped_journal = false; in_newest_frame = false; stopped = false }
  in
  Journal.segment_limit := 600 + Rng.int r 4000;
  Engine.compact_min := 5 + Rng.int r 60;
  (match Engine.open_ ~id_source:(fun _ -> "0123456789abcdef") w.disk dir with
   | Ok e ->
     w.e <- Some e;
     (* the bootstrap group, as written *)
     Journal.read w.disk jdir e.id (fun g -> Hashtbl.replace w.groups g.n g; w.prepared <- g.n; w.acked <- g.n)
   | Error m -> fail w "create: %s" (Engine.message m));
  (try
     for _ = 1 to steps do
       try step w with Sim_disk.Crash -> count "crash points"; recover w
     done;
     commit_pending w;
     if not w.stopped then check_published w;
     recover w
   with Over | Sim_disk.Crash -> ());
  incr C.checks

let () =
  let seeds = ref 100 and one = ref None and steps = ref 150 in
  Arg.parse
    [ "--seeds", Arg.Set_int seeds, "N  run seeds 1..N"; "--seed", Arg.Int (fun s -> one := Some s), "S  run one seed";
      "--steps", Arg.Set_int steps, "N  steps a seed" ]
    (fun _ -> ()) "sim.exe [--seeds N | --seed S] [--steps N]";
  (match !one with Some s -> run s !steps | None -> for s = 1 to !seeds do run s !steps done);
  let l = List.sort compare (Hashtbl.fold (fun k v acc -> (k, v) :: acc) stats []) in
  Printf.printf "simulation: %s\n" (String.concat ", " (List.map (fun (k, v) -> Printf.sprintf "%d %s" v k) l));
  C.finish "sim"
