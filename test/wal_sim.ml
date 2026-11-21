(* Deterministic simulation of the commit buffer (src/wal.ml, spec/CommitBuffer.tla). Three databases on one simulated
   disk share one buffer, whose files are small (they alternate often). One seed decides everything: the writes of
   each database, when each frame reaches its journal and the buffer, when the rounds are written and forced, when
   the file that is not active is cleaned, merges (whose run is named only once its journal is forced), large groups
   (a frame forced in its own journal, between the buffer's), long frames (forced in their journal too), process
   deaths that leave the page cache to a later power loss, power losses, crashes in the middle of any disk call
   (recovery's too), and failing fsyncs, of the buffer's file or of a journal. A commit performs [Wal.Wait]: the
   simulation holds it until a round.

   After every recovery (both files read, each database opened with the frames they hold, then the files emptied):
   G1 every confirmed group of every database is there, G2 G3 each journal holds exactly the groups written, in order,
   G5 what a recovery published survives the next crash, G6 no open refuses but at a frame or a round no fsync
   confirmed whose header's sector alone was lost (the residual of docs/book/guarantees.md, G6), G10 no write is
   confirmed after a failed fsync of its database's journal or of the buffer. After a crash a database opened alone
   is refused; after a clean stop it opens alone. Whether it was closed cleanly is the simulation's own record, not the
   marker found on the disk: a power loss that brings back a marker the open had removed must not let it open alone.
   A failure prints its seed; [wal_sim.exe --seed N] replays it. *)

open Cepheus
module C = Check

let data = "/data"
let names = [| "a"; "b"; "c" |]

let props = [ prop "name" Ttext; prop ~many:true "tag" Ttext; prop "score" Tint ]

type db = {
  name : string;
  dir : string;
  mutable e : Engine.t option;
  groups : (int, Group.t) Hashtbl.t;
  mutable acked : int;
  mutable prepared : int;
  mutable waiting : (unit, unit) Effect.Deep.continuation option;
  mutable stopped : bool;  (* an Io error came: nothing more may be confirmed until a restart (G10) *)
  mutable unsure : Journal.position option;  (* a frame written that no fsync confirmed *)
  mutable clean : bool;  (* closed cleanly since its last open with the buffer *)
}

type w = {
  seed : int;
  sim : Sim_disk.t;
  disk : Disk.t;
  r : Rng.t;
  dbs : db array;
  mutable wal : Wal.t option;
  mutable round_unsure : bool;  (* a round written that no fsync confirmed *)
  mutable older : (db * bool) option;
      (* a database an older version wrote after a crash (and whether it may have cut confirmed groups), until a
         recovery opens every database: a crash may interrupt the recovery after it *)
}

let stats = Hashtbl.create 16
let trace = Sys.getenv_opt "WAL_SIM_TRACE" <> None
let count k = if trace then prerr_endline ("  " ^ k); Hashtbl.replace stats k (1 + Option.value (Hashtbl.find_opt stats k) ~default:0)
let fail w fmt = Printf.ksprintf (fun s -> C.fail "seed %d: %s" w.seed s) fmt

exception Over

let id_of i = Printf.sprintf "000000000000000%d" i

let model w d k =
  let s = ref C.F.empty in
  for n = 1 to k do
    match Hashtbl.find_opt d.groups n with
    | Some g -> s := C.apply_group !s g
    | None -> fail w "%s: group %d was never recorded" d.name n; raise Over
  done;
  !s

let pid (v : Store.view) name = Schema.by_name v.schema name

let gen_ops w (v : Store.view) =
  let next = ref Schema.first_prop and decl = ref [] in
  List.iter
    (fun (p : prop) ->
      if pid v p.name = None then begin
        while Schema.find v.schema !next <> None do incr next done;
        decl := !decl @ List.map (fun (e, q, x) -> Add (e, q, x)) (Schema.facts !next p);
        incr next
      end)
    props;
  if !decl <> [] then !decl
  else
    let p n = Option.get (pid v n) in
    let r = w.r in
    let things = v.next_e - Schema.first_thing in
    let some () = if things = 0 then -1 else Schema.first_thing + Rng.int r things in
    let small = [| "a"; "b"; "c" |] in
    let one () =
      match Rng.int r 8 with
      | 0 | 1 -> [ Add (-1, p "name", Text ("n" ^ Rng.pick r small)) ]
      | 2 -> [ Add (some (), p "score", Int (Rng.int r 5)) ]
      | 3 -> [ Add (some (), p "tag", Text (Rng.pick r small)) ]
      | 4 -> [ Retract (some (), p "tag", Text (Rng.pick r small)) ]
      | 5 -> [ Add (-1, p "name", Text (String.make (Rng.int r 900) 'x')) ]  (* frames across sectors *)
      | 6 -> [ Add (-1, p "name", Text (String.make (Rng.int r 3000) 'y')) ]  (* a frame over shared_max *)
      | _ -> [ Expect (some (), p "score", Some (Int (Rng.int r 5))); Add (some (), p "score", Int 9) ]
    in
    List.concat (List.init (1 + Rng.int r 3) (fun _ -> one ()))

let engine d = match d.e with Some e -> e | None -> raise Over
let wal w = match w.wal with Some x -> x | None -> raise Over

let results w d res =
  if Array.for_all (function Error (Engine.Io _) -> false | _ -> true) res then d.unsure <- None;
  Array.iter
    (function
      | Ok (r : Engine.receipt) ->
        if d.stopped then fail w "%s: a write was confirmed after a failed fsync" d.name;
        d.acked <- max d.acked r.group;
        count "acked"
      | Error (Engine.Io _) -> d.stopped <- true; count "io errors"
      | Error _ -> count "refused")
    res

(* a commit, held at its wait for a round *)
let commit w d b =
  match Engine.commit (engine d) b with
  | res -> results w d res
  | effect Wal.Wait, k -> d.waiting <- Some k

let record d (b : Engine.batch) =
  let body = match b.pending with Some p -> Journal.written_body p | None -> Buffer.to_bytes b.body in
  let r = Codec.reader body 0 (Bytes.length body) in
  for _ = 1 to b.count do
    let g = Group.decode r in
    Hashtbl.replace d.groups g.n g;
    d.prepared <- max d.prepared g.n
  done

let write w d =
  let e = engine d in
  let reqs = Array.init (1 + Rng.int w.r 4) (fun _ -> gen_ops w e.working, Rng.int w.r 9, "w") in
  let b = Engine.prepare e reqs in
  if b.runs <> [] then count "large groups";
  record d b;
  if b.count > 0 && not d.stopped then d.unsure <- Some (Journal.position e.journal);
  commit w d b

(* a round, then each commit it confirmed (or failed) goes on, in an order the seed draws *)
let round w =
  let x = wal w in
  w.round_unsure <- true;
  Wal.round x;
  if Wal.stopped x = None then w.round_unsure <- false;
  count "rounds";
  let ds = List.filter (fun d -> d.waiting <> None) (Array.to_list w.dbs) in
  if List.length ds > 1 then count "rounds of several databases";
  let ds = List.map snd (List.sort compare (List.map (fun d -> Rng.int w.r 1000, d) ds)) in
  List.iter
    (fun d ->
      match d.waiting with
      | Some k ->
        d.waiting <- None;
        (* the commit's handler is still around it: its results are taken there *)
        Effect.Deep.continue k ()
      | None -> ())
    ds

let has m sub =
  let n = String.length sub and k = String.length m in
  let rec go i = i + n <= k && (String.sub m i n = sub || go (i + 1)) in
  go 0

let rec recover ?(kill = false) ?(close = false) w =
  count "recoveries";
  Array.iter (fun d -> d.e <- None; d.waiting <- None; d.stopped <- false) w.dbs;
  w.wal <- None;
  if close then ()
  else if kill then (count "process deaths"; Sim_disk.kill w.sim)
  else Sim_disk.crash w.sim;
  (* a database opened alone, before its server: refused unless it was closed cleanly *)
  (let d = w.dbs.(Rng.int w.r (Array.length w.dbs)) in
   if w.disk.exists (d.dir ^ "/cepheus") then
   let shared = w.disk.exists (d.dir ^ "/shared") and clean = w.disk.exists (d.dir ^ "/closed") in
   match Engine.open_ ~id_source:(fun _ -> "none") w.disk d.dir with
   | Error (Busy _) when shared && not clean -> count "opens alone refused"
   | Error (Busy m) -> fail w "%s: refused alone: %s" d.name m
   | Ok e when shared && not clean -> fail w "%s: opened alone, its newest frames maybe in the buffer" d.name; Engine.close e
   | Ok e when shared && not d.clean ->
     fail w "%s: opened alone after a crash that brought back its closed marker: its newest frames maybe in the buffer" d.name;
     Engine.close e
   | Ok e ->
     (* closed cleanly: everything is in its journal; a clean close again leaves it as it was *)
     count "opens alone after a clean close";
     Engine.close e
   | Error _ -> ());
  (* sometimes a version that does not read the buffer opens a database after the crash (its `shared` marker
     unknown to it), writes a group and closes: the buffer then holds frames the journal may hold others of; the
     server's recovery must refuse to write over them (an operator's decision), or open with that group *)
  (let i = Rng.int w.r (Array.length w.dbs) in
   let d = w.dbs.(i) in
   if w.older = None && Rng.chance w.r 0.04 && w.disk.exists (d.dir ^ "/shared") && not (w.disk.exists (d.dir ^ "/closed")) then begin
     w.disk.remove (d.dir ^ "/shared");
     w.disk.sync_dir d.dir;
     match Engine.open_ ~id_source:(fun _ -> "none") w.disk d.dir with
     | Ok e ->
       let k1 = e.working.group in
       let b = Engine.prepare e [| gen_ops w e.working, 1, "older" |] in
       record d b;
       let wrote = Array.exists Result.is_ok (Engine.commit e b) in
       Engine.close e;
       if wrote then begin
         count "databases written by an older version after a crash";
         (* it may have cut confirmed groups the buffer holds, and written over them *)
         w.older <- Some (d, k1 < d.acked);
         if k1 >= d.acked then d.acked <- k1 + 1
       end
     | Error _ -> ()
   end);
  if Rng.chance w.r 0.15 then Sim_disk.crash_after w.sim (Rng.int w.r 30);
  match
    let x = Wal.recover ~manual:true w.disk data in
    let opened =
      Array.mapi
        (fun i d ->
          let frames id = let l = Wal.frames x id in if l <> [] then count "databases given frames at recovery"; l in
          Engine.open_ ~id_source:(fun _ -> id_of i) ~buffer:frames w.disk d.dir)
        w.dbs
    in
    x, opened
  with
  | exception Sim_disk.Crash -> count "crashes during recovery"; recover w
  | exception Journal.Damaged m ->
    if w.round_unsure && has m "(written whole)" then (count "false alarms: an unconfirmed round without its header's sector"; raise Over)
    else (fail w "the buffer is damaged: %s" m; raise Over)
  | x, opened -> (
    (* [clean] before the close: a close interrupted before its marker leaves none *)
    let close_all () = Array.iteri (fun i -> function Ok e -> w.dbs.(i).clean <- true; Engine.close e | Error _ -> ()) opened in
    let bad = ref None in
    Array.iteri
      (fun i r ->
        match r with
        | Ok _ -> ()
        | Error e -> if !bad = None then bad := Some (w.dbs.(i), e))
      opened;
    match !bad with
    | Some (_, Engine.Io _) -> close_all (); count "io errors at open"; recover ~kill:(Rng.bool w.r) w
    | Some (d, Engine.Damaged m) ->
      close_all ();
      let at_unsure =
        match d.unsure with
        | Some p -> has m (Journal.segment_name p.segment) && has m (Printf.sprintf "at offset %d (written whole)" p.offset)
        | None -> false
      in
      if at_unsure then (count "false alarms: an unconfirmed frame without its header's sector"; raise Over)
      else if (match w.older with Some (d', _) -> d' == d | None -> false) then
        (count "frames of an older version's open refused"; raise Over)
      else (fail w "%s: recovery says damaged: %s" d.name m; raise Over)
    | Some (d, e) -> close_all (); fail w "%s: recovery failed: %s" d.name (Engine.message e); raise Over
    | None -> (
      (match w.older with Some (d, true) -> fail w "%s: an older version cut confirmed groups and wrote over them, and the recovery opened" d.name | _ -> ());
      match Wal.start x with
      | exception Sim_disk.Crash -> close_all (); count "crashes during recovery"; recover w
      | exception Disk.Io _ -> close_all (); count "io errors at open"; recover ~kill:(Rng.bool w.r) w
      | exception Journal.Damaged m -> close_all (); fail w "the buffer refuses to start: %s" m; raise Over
      | () ->
        Sim_disk.crash_after w.sim (-1);
        w.round_unsure <- false;
        w.older <- None;
        Array.iteri
          (fun i d ->
            let e = match opened.(i) with Ok e -> e | Error _ -> assert false in
            d.unsure <- None;
            let k = e.working.group in
            if Journal.next_group e.journal <> k + 1 then fail w "%s: journal next %d after recovery to %d" d.name (Journal.next_group e.journal) k;
            if k < d.acked then fail w "%s: lost confirmed groups: recovered %d, confirmed %d" d.name k d.acked;
            if k > d.prepared && d.prepared > 0 then fail w "%s: recovered %d groups, only %d were prepared" d.name k d.prepared;
            (try
               Journal.read w.disk (d.dir ^ "/journal") e.id (fun g ->
                   match Hashtbl.find_opt d.groups g.n with
                   | Some g' -> if not (Group.equal g g') then fail w "%s: group %d differs from what was written" d.name g.n
                   | None -> if g.n > 1 then fail w "%s: group %d was never written" d.name g.n)
             with Journal.Damaged m -> fail w "%s: journal unreadable after recovery: %s" d.name m);
            if k >= 1 && not (Hashtbl.mem d.groups 1) then
              Journal.read w.disk (d.dir ^ "/journal") e.id (fun g -> if g.n = 1 then Hashtbl.replace d.groups 1 g);
            Hashtbl.filter_map_inplace (fun n g -> if n <= k then Some g else None) d.groups;
            d.prepared <- k;
            d.acked <- k;
            let got = C.facts_of_view e.working and want = model w d k in
            if not (C.F.equal got want) then fail w "%s: recovered state at %d differs from the model: %s" d.name k (C.show_diff got want);
            Wal.attach x e.id e.journal;
            d.clean <- false;
            d.e <- Some e)
          w.dbs;
        w.wal <- Some x))

let quiet w = while Array.exists (fun d -> d.waiting <> None) w.dbs do round w done

let step w =
  let d = w.dbs.(Rng.int w.r (Array.length w.dbs)) in
  match Rng.int w.r 100 with
  | n when n < 40 -> if d.waiting = None then write w d
  | n when n < 62 -> round w
  | n when n < 66 -> Wal.clean (wal w); count "cleanings"
  | n when n < 69 ->
    if d.waiting = None && not d.stopped then begin
      match Engine.snapshot (engine d) with Ok () -> count "merges" | Error _ -> count "failed merges"
    end
  | n when n < 72 -> count "power losses"; recover w
  | n when n < 73 -> recover ~kill:true w
  | n when n < 74 ->
    (* a clean stop: every commit answered, each database closed (its journal forced), the buffer emptied *)
    quiet w;
    Array.iter (fun d -> d.clean <- true; Engine.close (engine d)) w.dbs;
    Wal.stop (wal w);
    count "clean stops";
    recover ~close:true w
  | n when n < 78 -> Sim_disk.crash_after w.sim (Rng.int w.r 25)
  | n when n < 81 -> if Rng.chance w.r 0.3 then Sim_disk.fail_fsync_at ~crash_after:(Rng.int w.r 4) w.sim 0 else Sim_disk.fail_next_fsync w.sim
  | _ -> if d.waiting = None then begin
      (* the published view holds exactly the durable groups (G5) *)
      let v = Atomic.get (engine d).published in
      if v.group < d.acked then fail w "%s: published %d before the confirmed %d" d.name v.group d.acked;
      let got = C.facts_of_view v and want = model w d v.group in
      if not (C.F.equal got want) then fail w "%s: published view at %d differs from the model" d.name v.group
    end

let run seed steps =
  let r = Rng.make seed in
  let reverts = Rng.chance r 0.3 in
  let sim = Sim_disk.create ~reverts (Rng.split r) in
  let mk name = { name; dir = data ^ "/" ^ name; e = None; groups = Hashtbl.create 64; acked = 0; prepared = 0; waiting = None;
                  stopped = false; unsure = None; clean = true } in
  let w = { seed; sim; disk = Sim_disk.disk sim; r; dbs = Array.map mk names; wal = None; round_unsure = false;
            older = None } in
  Journal.segment_limit := 600 + Rng.int r 4000;
  Journal.window := if Rng.chance r 0.5 then 40 + Rng.int r 200 else 4 * 1024 * 1024;
  Journal.shared_max := 400 + Rng.int r 3000;
  (* half the seeds force a frame that comes when the buffer is idle in its own journal (from the seed's number: the
     other draws unchanged) *)
  Wal.alone := seed mod 2 = 0;
  Wal.limit := 300 + Rng.int r 3000;
  Engine.compact_min := 5 + Rng.int r 60;
  Resolve.large_min := if Rng.chance r 0.5 then 4 else 1_000_000;
  Engine.tier := 2 + (seed mod 5);
  w.disk.mkdir data;
  w.disk.sync_dir "/";
  (try
     recover ~close:true w;
     Array.iter (fun d -> d.acked <- (engine d).working.group) w.dbs;
     for _ = 1 to steps do
       try step w with Sim_disk.Crash -> count "crash points"; recover ~kill:(Rng.chance w.r 0.3) w
     done;
     (try quiet w with Sim_disk.Crash -> ());
     recover w
   with Over | Sim_disk.Crash -> ());
  incr C.checks

let () =
  let seeds = ref 100 and one = ref None and steps = ref 200 in
  Arg.parse
    [ "--seeds", Arg.Set_int seeds, "N  run seeds 1..N"; "--seed", Arg.Int (fun s -> one := Some s), "S  run one seed";
      "--steps", Arg.Set_int steps, "N  steps a seed" ]
    (fun _ -> ()) "wal_sim.exe [--seeds N | --seed S] [--steps N]";
  Pages.set_capacity (32 lsl 20);
  Snapshot.sync_every := 8 * Pages.size;
  (match !one with Some s -> run s !steps | None -> for s = 1 to !seeds do run s !steps done);
  let l = List.sort compare (Hashtbl.fold (fun k v acc -> (k, v) :: acc) stats []) in
  Printf.printf "buffer simulation: %s\n" (String.concat ", " (List.map (fun (k, v) -> Printf.sprintf "%d %s" v k) l));
  C.finish "buffer sim"
