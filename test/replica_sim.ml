(* Deterministic simulation of a replica (Replica, Engine.prepare_apply, Journal.cursor): a primary and its replica,
   each its own machine (its own simulated disk), one seed deciding everything: the primary's writes (some in
   sessions, some large groups), its commits one batch behind, merges on both sides, the sender reading the primary's
   journal up to its newest durable group a frame at a time into a link of bounded bytes (the primary holds nothing
   else for its replica), the link cut at any point (what was on it lost; the replica connects again from its newest
   durable group, after the frames it gave its writer are durable), frames damaged on the way (a bit flipped, cut
   short: the CRC refuses them) or well formed and wrong (a frame of other groups, its CRC good: decoding refuses
   them, and nothing changes), the replica's frames applied ahead of its commits, power losses and process deaths on
   both machines at any disk call, failed fsyncs on the primary (it stops and starts again), a replica left far
   behind (its link down for a long time while the primary writes across segments).

   Checked at every recovery of the replica and at the end: its journal holds exactly a prefix of the primary's
   durable groups, group for group (never a group the primary did not make durable, which a crash there could lose).
   Then a promotion:
   - after the primary's clean stop (its last frames and Stopped sent, the replica holding them: the handover), no
     group the primary confirmed is missing on the replica, and every write confirmed in a session gets its first
     receipt from the replica's session table (G14 across the promotion);
   - after the primary's power loss, forced: the replica's groups are still a prefix of the primary's (the confirmed
     groups it lacks are counted);
   then the promoted replica writes in its new epoch, the old primary sometimes writes on too (a split brain), and
   the old primary asks to follow the new one: the epochs' rule (Replica.follows) must accept it only if its journal
   is truly a prefix of the new primary's, and accept it whenever it holds no group past the promotion; accepted, it
   catches up and both journals end identical. A failure prints its seed; [replica_sim.exe --seed N] replays it. *)

open Cepheus
open Cepheus_server
module C = Check

let dir = "/db"
let jdir = "/db/journal"
let id = "0123456789abcdef"

let props =
  [ prop "name" Ttext; prop ~many:true "tag" Ttext; prop "score" Tint; prop ~unique:true "mail" Ttext;
    prop ~many:true "friend" Tlink ]

let stats = Hashtbl.create 32
let count k = Hashtbl.replace stats k (1 + Option.value (Hashtbl.find_opt stats k) ~default:0)

exception Over

(* one machine *)
type side = {
  sim : Sim_disk.t;
  disk : Disk.t;
  mutable e : Engine.t option;
  mutable pending : Engine.batch list;  (* prepared, not yet committed, oldest first *)
  mutable epochs : Replica.epochs;
  mutable stopped : bool;
}

type msg = Frame of { first : int; count : int; crc : int; body : Bytes.t } | Stopped of int

type w = {
  seed : int;
  r : Rng.t;
  p : side;  (* the primary *)
  q : side;  (* the replica *)
  hist : (int, Group.t) Hashtbl.t;  (* the primary's groups as its journal holds them *)
  mutable confirmed : int;  (* the newest group the primary confirmed *)
  mutable receipts : (int * int * int) list;  (* (session, serial, group) confirmed *)
  mutable serial : int;
  link : msg Queue.t;
  mutable link_bytes : int;
  mutable cur : Journal.cursor option;  (* the sender's: Some while connected *)
  mutable down : int;  (* steps the link stays down *)
  mutable handover : int option;
  mutable armed : [ `P | `Q | `None ];  (* the machine whose disk will crash at a call *)
  mutable unsure : Journal.position option;
      (* where the primary wrote a frame no fsync confirmed: a power loss may leave its body and trailer without its
         header's sector, the false alarm G6 accepts (docs/book/guarantees.md, test/sim.ml) *)
}

let fail w fmt = Printf.ksprintf (fun s -> C.fail "seed %d: %s" w.seed s; raise Over) fmt
let eng s = match s.e with Some e -> e | None -> raise Over
let published s = (Atomic.get (eng s).published).group
let link_cap = 4096

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

let gen_ops r (v : Store.view) =
  match declare_ops v with
  | _ :: _ as ops -> ops
  | [] ->
    let p n = Option.get (pid v n) in
    let things = v.next_e - Schema.first_thing in
    let some () = if things = 0 then -1 else Schema.first_thing + Rng.int r things in
    let small = [| "a"; "b"; "c"; "d" |] in
    let one () =
      match Rng.int r 9 with
      | 0 | 1 -> [ Add (-1, p "name", Text ("n" ^ Rng.pick r small)); Add (-1, p "score", Int (Rng.int r 5)) ]
      | 2 -> [ Add (some (), p "score", Int (Rng.int r 5)) ]
      | 3 -> [ Add (some (), p "tag", Text (Rng.pick r small)) ]
      | 4 -> [ Retract (some (), p "tag", Text (Rng.pick r small)) ]
      | 5 -> [ Add (some (), p "mail", Text (Rng.pick r small ^ "@x")) ]
      | 6 -> [ Add (some (), p "friend", Link (some ())) ]
      | 7 -> [ Add (-1, p "name", Text (String.make (Rng.int r 700) 'x')) ]
      | _ -> List.init (4 + Rng.int r 8) (fun k -> Add (-1, p "tag", Text (Printf.sprintf "t%d" k)))
    in
    List.concat (List.init (1 + Rng.int r 3) (fun _ -> one ()))

(* ---- the primary ---- *)

let p_open w =
  match Engine.open_ ~id_source:(fun _ -> id) w.p.disk dir with
  | Ok e ->
    w.p.e <- Some e;
    w.p.pending <- [];
    w.p.stopped <- false;
    w.unsure <- None;
    (* its history is what its journal holds now: a lost tail was never confirmed *)
    let k = e.working.group in
    Hashtbl.filter_map_inplace (fun n g -> if n <= k then Some g else None) w.hist;
    (* the first group, which the open wrote *)
    if not (Hashtbl.mem w.hist 1) then Journal.read w.p.disk jdir id (fun g -> if not (Hashtbl.mem w.hist g.n) then Hashtbl.replace w.hist g.n g);
    if k < w.confirmed then fail w "the primary recovered at %d, below its confirmed %d (G1)" k w.confirmed
  | Error (Engine.Damaged m)
    when (match w.unsure with
        | Some p ->
          let has sub = let n = String.length sub and k = String.length m in
            let rec go i = i + n <= k && (String.sub m i n = sub || go (i + 1)) in go 0 in
          has (Journal.segment_name p.segment) && has (Printf.sprintf "at offset %d (written whole)" p.offset)
        | None -> false) ->
    count "false alarm: an unconfirmed frame without its header's sector"; raise Over
  | Error (Engine.Io _) -> raise Exit
  | Error m -> fail w "the primary's recovery: %s" (Engine.message m)

let disconnect w =
  Queue.clear w.link;
  w.link_bytes <- 0;
  Option.iter Journal.cursor_close w.cur;
  w.cur <- None

(* a power loss or a death of the primary: the replica's link and the sender go with it *)
let rec p_recover ?(kill = false) w =
  disconnect w;
  w.p.e <- None;
  w.p.pending <- [];
  if kill then Sim_disk.kill w.p.sim else Sim_disk.crash w.p.sim;
  if Rng.chance w.r 0.15 then Sim_disk.crash_after w.p.sim (Rng.int w.r 12);
  match p_open w with
  | () -> Sim_disk.crash_after w.p.sim (-1); if w.armed = `P then w.armed <- `None; w.unsure <- None
  | exception Sim_disk.Crash -> count "primary crashes during recovery"; p_recover w
  | exception Exit -> count "io errors at open"; p_recover ~kill:true w

let record w (b : Engine.batch) =
  let body = match b.pending with Some p -> Journal.written_body p | None -> Buffer.to_bytes b.body in
  let r = Codec.reader body 0 (Bytes.length body) in
  for _ = 1 to b.count do
    let g = Group.decode r in
    Hashtbl.replace w.hist g.n g
  done

let p_commit w =
  match w.p.pending with
  | [] -> ()
  | b :: rest ->
    w.p.pending <- rest;
    if b.count > 0 && not w.p.stopped then w.unsure <- Some (Journal.position (eng w.p).journal);
    let res = Engine.commit (eng w.p) b in
    if Array.for_all (function Error (Engine.Io _) -> false | _ -> true) res then w.unsure <- None;
    Array.iter
      (function
        | Ok (r : Engine.receipt) ->
          if w.p.stopped then fail w "a write confirmed after a failed fsync";
          w.confirmed <- max w.confirmed r.group
        | Error (Engine.Io _) -> w.p.stopped <- true
        | Error _ -> ())
      res;
    (* the writes of sessions, confirmed: their receipts *)
    if Array.exists (function Ok _ -> true | Error _ -> false) res then
      List.iter
        (fun (g : Group.t) ->
          match Origin.parse g.why with
          | Some (o, _) when o.serial > 0 -> w.receipts <- (o.session, o.serial, g.n) :: w.receipts
          | _ -> ())
        b.groups

let p_write w =
  let e = eng w.p in
  if w.p.pending = [] && not w.p.stopped then begin
    let n = 1 + Rng.int w.r 4 in
    let reqs =
      Array.init n (fun _ ->
          let ops = gen_ops w.r e.working in
          let why =
            if Rng.chance w.r 0.5 then begin
              w.serial <- w.serial + 1;
              Origin.wrap { Origin.token = "app"; session = 7; serial = w.serial; floor = 1 } "w"
            end
            else "w"
          in
          ops, Rng.int w.r 9, why)
    in
    let b = Engine.prepare e reqs in
    if b.runs <> [] then count "large groups";
    record w b;
    w.p.pending <- [ b ]
  end
  else p_commit w

(* ---- the replica ---- *)

let q_open w =
  match Engine.open_ ~id_source:(fun _ -> id) ~bootstrap:false w.q.disk dir with
  | Ok e -> w.q.e <- Some e; w.q.pending <- []
  | Error m -> fail w "the replica's recovery: %s" (Engine.message m)

(* the replica's journal: a prefix of the primary's groups *)
let check_prefix w what =
  let n = ref 0 in
  (try
     Journal.read w.q.disk jdir id (fun g ->
         incr n;
         match Hashtbl.find_opt w.hist g.n with
         | Some h when Group.equal h g -> ()
         | Some _ -> fail w "%s: the replica's group %d is not the primary's" what g.n
         | None -> fail w "%s: the replica holds group %d, which the primary does not" what g.n)
   with Journal.Damaged m -> fail w "%s: the replica's journal: %s" what m);
  count "prefix checks"

let rec q_recover ?(kill = false) w =
  disconnect w;
  w.q.e <- None;
  w.q.pending <- [];
  if kill then Sim_disk.kill w.q.sim else Sim_disk.crash w.q.sim;
  if Rng.chance w.r 0.15 then Sim_disk.crash_after w.q.sim (Rng.int w.r 12);
  match q_open w with
  | () ->
    Sim_disk.crash_after w.q.sim (-1);
    if w.armed = `Q then w.armed <- `None;
    check_prefix w "after the replica's recovery"
  | exception Sim_disk.Crash -> count "replica crashes during recovery"; q_recover w

let q_commit w =
  match w.q.pending with
  | [] -> ()
  | b :: rest ->
    w.q.pending <- rest;
    Array.iter
      (function Ok _ -> count "frames durable on the replica" | Error e -> fail w "the replica's commit: %s" (Engine.message e))
      (Engine.commit (eng w.q) b)

(* a frame from the link, as Replica.receive takes it: its CRC, then decoded and replayed ahead of the commits *)
let q_frame w ~first ~count:n ~crc body =
  let len = Bytes.length body in
  if Crc32c.bytes body 0 len <> crc then (count "damaged frames refused (CRC)"; disconnect w)
  else
    let e = eng w.q in
    let f = { Engine.first; count = n; body; len } in
    match Engine.decode_frame f with
    | Error _ -> count "wrong frames refused (decoding)"; disconnect w
    | Ok gs -> (
      (* a large group: nothing in flight, as the writer does *)
      if Engine.maybe_large gs then while w.q.pending <> [] do q_commit w done;
      let before = e.working.group in
      match Engine.prepare_apply e f gs with
      | Ok b -> if b.runs <> [] then count "large groups applied"; w.q.pending <- w.q.pending @ [ b ]
      | Error _ ->
        if e.working.group <> before then fail w "a refused frame changed the replica's state";
        count "wrong frames refused (replay)";
        disconnect w)

let deliver w =
  match Queue.take_opt w.link with
  | None -> ()
  | Some m -> (
    match m with
    | Frame f ->
      w.link_bytes <- w.link_bytes - Bytes.length f.body;
      q_frame w ~first:f.first ~count:f.count ~crc:f.crc f.body
    | Stopped g ->
      while w.q.pending <> [] do q_commit w done;
      if published w.q = g then w.handover <- Some g)

(* the replica connects: its frames in flight durable first, then the primary's check, then a cursor from its next
   group *)
let connect w =
  while w.q.pending <> [] do q_commit w done;
  let last = published w.q in
  match Replica.follows ~primary:w.p.epochs ~group:(published w.p) ~replica:w.q.epochs ~last with
  | Error (c, m) -> fail w "the replica refused while it follows: %s: %s" c m
  | Ok () ->
    w.cur <- Some (Journal.cursor w.p.disk jdir id ~next:(last + 1));
    count "connections"

(* one frame of the primary's journal onto the link, if it has room *)
let send w =
  match w.cur with
  | None -> ()
  | Some c ->
    let upto = published w.p in
    if Journal.cursor_next c <= upto && w.link_bytes < link_cap then
      Journal.frames ~limit:1 c ~upto (fun ~first ~count:n ~crc body len ->
          let body = Bytes.sub body 0 len in
          let m =
            match Rng.int w.r 100 with
            | 0 ->
              (* a bit flipped on the way *)
              let b = Bytes.copy body in
              let i = Rng.int w.r len in
              Bytes.set_uint8 b i (Bytes.get_uint8 b i lxor (1 lsl Rng.int w.r 8));
              Frame { first; count = n; crc; body = b }
            | 1 -> Frame { first; count = n; crc; body = Bytes.sub body 0 (Rng.int w.r len) }
            | 2 ->
              (* well formed, its CRC good, and wrong: the groups of another place *)
              let b = Bytes.of_string (String.init (1 + Rng.int w.r 64) (fun _ -> Char.chr (Rng.int w.r 256))) in
              Frame { first; count = n; crc = Crc32c.bytes b 0 (Bytes.length b); body = b }
            | 3 when first > 1 ->
              (* a frame of earlier groups under these numbers *)
              let g = Hashtbl.find w.hist (first - 1) in
              let b = Buffer.create 64 in
              Group.encode b g;
              let b = Buffer.to_bytes b in
              Frame { first; count = 1; crc = Crc32c.bytes b 0 (Bytes.length b); body = b }
            | _ -> Frame { first; count = n; crc; body }
          in
          (match m with Frame f -> w.link_bytes <- w.link_bytes + Bytes.length f.body | Stopped _ -> ());
          Queue.push m w.link)

let step w =
  match Rng.int w.r 100 with
  | n when n < 30 -> p_write w
  | n when n < 50 -> send w
  | n when n < 70 -> deliver w
  | n when n < 80 -> q_commit w
  | n when n < 83 -> if w.cur <> None then (count "links cut"; disconnect w; if Rng.chance w.r 0.2 then w.down <- 30 + Rng.int w.r 80)
  | n when n < 86 ->
    (* a merge of everything, with nothing in flight (as the writer's Snapshot) *)
    if Rng.chance w.r 0.5 then (while w.p.pending <> [] do p_commit w done; ignore (Engine.snapshot (eng w.p)))
    else (while w.q.pending <> [] do q_commit w done; ignore (Engine.snapshot (eng w.q)))
  | n when n < 88 -> count "primary crashes"; disconnect w; p_recover ~kill:(Rng.bool w.r) w
  | n when n < 90 -> if w.armed = `None then (w.armed <- `P; Sim_disk.crash_after w.p.sim (Rng.int w.r 20))
  | n when n < 91 -> Sim_disk.fail_next_fsync w.p.sim
  | n when n < 94 -> count "replica crashes"; q_recover ~kill:(Rng.bool w.r) w
  | n when n < 96 -> if w.armed = `None then (w.armed <- `Q; Sim_disk.crash_after w.q.sim (Rng.int w.r 20))
  | _ ->
    if w.p.stopped then begin
      (* after a failed fsync the primary stops and starts again *)
      count "primary restarts after a failed fsync";
      disconnect w;
      Engine.close (eng w.p);
      p_recover ~kill:true w
    end

(* every step but the faults until the replica holds every durable group of the primary *)
let drain w =
  let guard = ref 0 in
  while (published w.q < published w.p || not (Queue.is_empty w.link) || w.q.pending <> []) && !guard < 100_000 do
    incr guard;
    if w.cur = None then connect w;
    send w;
    deliver w;
    q_commit w
  done;
  if published w.q < published w.p then fail w "the replica did not catch up: %d of %d" (published w.q) (published w.p)

(* the groups of a journal, by number *)
let groups_of disk =
  let h = Hashtbl.create 64 in
  Journal.read disk jdir id (fun g -> Hashtbl.replace h g.n g);
  h

let run seed =
  let r = Rng.make seed in
  let mk () = let sim = Sim_disk.create (Rng.split r) in { sim; disk = Sim_disk.disk sim; e = None; pending = []; epochs = Replica.first_epochs; stopped = false } in
  let w =
    { seed; r; p = mk (); q = mk (); hist = Hashtbl.create 64; confirmed = 0; receipts = []; serial = 0; link = Queue.create ();
      link_bytes = 0; cur = None; down = 0; handover = None; armed = `None; unsure = None }
  in
  Engine.compact_min := 5 + Rng.int r 60;
  Journal.segment_limit := 600 + Rng.int r 4000;
  Resolve.large_min := if Rng.chance r 0.4 then 6 + Rng.int r 6 else 20_000;
  (try
     p_open w;
     q_open w;
     (* phase 1: writing, following, faults *)
     for _ = 1 to 250 + Rng.int r 250 do
       (try
          if w.cur = None && w.down = 0 && Rng.chance w.r 0.3 then connect w;
          if w.down > 0 then w.down <- w.down - 1;
          step w
        with
        | Sim_disk.Crash ->
          let side = w.armed in
          w.armed <- `None;
          if side = `P then (count "primary crash points"; disconnect w; p_recover ~kill:(Rng.chance w.r 0.3) w)
          else (count "replica crash points"; q_recover ~kill:(Rng.chance w.r 0.3) w));
       if published w.q > published w.p then fail w "the replica is ahead of the primary"
     done;
     (* phase 2 has no fault of its own: none left armed (a crash point, a failed fsync not reached yet) *)
     Sim_disk.crash_after w.p.sim (-1);
     Sim_disk.crash_after w.q.sim (-1);
     Sim_disk.fail_fsync_at w.p.sim (-1);
     if w.p.stopped then (Engine.close (eng w.p); p_recover ~kill:true w);
     (* phase 2: the promotion *)
     let clean = Rng.chance r 0.6 in
     if clean then begin
       (* the clean stop: the writes in flight confirmed, the database closed, its last frames and Stopped sent *)
       while w.p.pending <> [] do p_commit w done;
       Engine.close (eng w.p);
       drain w;
       if w.cur = None then connect w;
       Queue.push (Stopped (published w.p)) w.link;
       while not (Queue.is_empty w.link) do deliver w done;
       if w.handover <> Some (published w.p) then fail w "no handover at the clean stop";
       count "clean handovers"
     end
     else begin
       (* the primary loses its power; the replica holds what it holds *)
       let more = Rng.int r 6 in
       for _ = 1 to more do (try p_write w; send w; deliver w with Sim_disk.Crash -> ()) done;
       disconnect w;
       while w.q.pending <> [] do q_commit w done;
       Sim_disk.crash w.p.sim;
       w.p.e <- None;
       count "forced promotions"
     end;
     check_prefix w "at the promotion";
     let at = published w.q in
     (* no confirmed group missing after a handover; after a power loss, counted *)
     if clean && at < w.confirmed then fail w "the primary confirmed group %d, the promoted replica holds %d" w.confirmed at;
     if (not clean) && at < w.confirmed then Hashtbl.replace stats "confirmed groups missing after a forced promotion"
         (w.confirmed - at + Option.value (Hashtbl.find_opt stats "confirmed groups missing after a forced promotion") ~default:0);
     (* G14: every write of a session confirmed and held here gets its first receipt from the table rebuilt here *)
     let sessions = Sessions.load w.q.disk dir id in
     List.iter
       (fun (sid, serial, g) ->
         if g <= at then
           match Sessions.start sessions ~sid ~token:"app" ~serial ~floor:1 ~published:at ~now:0 [] ignore with
           | Sessions.Replay rc when rc.group = g -> count "receipts found again after the promotion"
           | Sessions.Replay rc -> fail w "G14: serial %d answered with group %d, not %d" serial rc.group g
           | _ -> fail w "G14: serial %d (group %d) is not in the promoted replica's table" serial g)
       w.receipts;
     (* the promotion: a new epoch from the next group; the replica's engine takes writes *)
     w.q.epochs <- w.q.epochs @ [ Replica.last_epoch w.q.epochs + 1, at + 1 ];
     let qe = eng w.q in
     for _ = 1 to Rng.int r 5 do
       let b = Engine.prepare qe [| gen_ops r qe.working, 0, "after" |] in
       Array.iter (function Ok _ -> count "writes after the promotion" | Error _ -> ()) (Engine.commit qe b)
     done;
     (* the old primary starts again; sometimes it writes on, as if no one had told it (a split brain) *)
     (try p_open w with Exit -> count "io errors at open"; p_recover ~kill:true w);
     if Rng.chance r 0.4 then begin
       for _ = 1 to 1 + Rng.int r 4 do p_write w; p_commit w done;
       count "split brains"
     end;
     (* the old primary asks to follow the promoted one: accepted only if its journal is a prefix of the new one's *)
     let mine = groups_of w.p.disk and theirs = groups_of w.q.disk in
     let last = published w.p in
     let prefix = Hashtbl.fold (fun n g ok -> ok && match Hashtbl.find_opt theirs n with Some h -> Group.equal g h | None -> false) mine true in
     (match Replica.follows ~primary:w.q.epochs ~group:(published w.q) ~replica:w.p.epochs ~last with
      | Ok () ->
        if not prefix then fail w "the epochs let an old primary whose journal is not a prefix follow the new one";
        count "old primaries accepted as replicas";
        (* it catches up, and both journals end the same *)
        Engine.close (eng w.p);
        w.p.e <- None;
        (match Engine.open_ ~id_source:(fun _ -> id) ~bootstrap:false w.p.disk dir with
         | Ok e -> w.p.e <- Some e
         | Error m -> fail w "the old primary as a replica: %s" (Engine.message m));
        let c = Journal.cursor w.q.disk jdir id ~next:(last + 1) in
        Journal.frames c ~upto:(published w.q) (fun ~first ~count:n ~crc:_ body len ->
            let f = { Engine.first; count = n; body = Bytes.sub body 0 len; len } in
            match Result.bind (Engine.decode_frame f) (Engine.prepare_apply (eng w.p) f) with
            | Ok b -> Array.iter (function Ok _ -> () | Error e -> fail w "catching up: %s" (Engine.message e)) (Engine.commit (eng w.p) b)
            | Error e -> fail w "catching up: %s" (Engine.message e));
        Journal.cursor_close c;
        let mine = groups_of w.p.disk in
        if Hashtbl.length mine <> Hashtbl.length theirs || not (Hashtbl.fold (fun n g ok -> ok && Group.equal g (Hashtbl.find theirs n)) mine true) then
          fail w "the old primary's journal differs from the new primary's after catching up";
        count "journals identical after the rejoin"
      | Error (code, _) ->
        if last <= at then fail w "the epochs refused (%s) an old primary that holds nothing past the promotion (%d <= %d)" code last at;
        count (if prefix then "true prefixes refused (an identical group past the promotion)" else "diverged old primaries refused"));
     Option.iter Engine.close w.p.e;
     Option.iter Engine.close w.q.e
   with Over -> ());
  incr C.checks

let () =
  let seeds = ref 200 and only = ref None in
  Arg.parse [ "--seeds", Arg.Set_int seeds, "N"; "--seed", Arg.Int (fun s -> only := Some s), "N" ] ignore "replica_sim.exe [--seeds N | --seed N]";
  (match !only with Some s -> run s | None -> for s = 1 to !seeds do run s done);
  Hashtbl.fold (fun k v acc -> (k, v) :: acc) stats [] |> List.sort compare |> List.iter (fun (k, v) -> Printf.printf "  %s: %d\n" k v);
  C.finish "replica sim"
