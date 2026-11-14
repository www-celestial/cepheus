(* Deterministic simulation of a Raft cluster (server/raft.ml, server/raftlog.ml): 3 or 5 servers, each its own
   machine with its own simulated disk (Sim_disk) and clock, the same Raft core and log the server runs, one seed
   deciding everything. Its state machine is a small register store (a write sets a key to a value of its own),
   checkpointed now and then (as each database's journal is forced each second), the log's start cut behind it.

   Faults, from the seed: messages lost, duplicated, delayed (so reordered); partitions (a server alone, a minority,
   links cut one way); process deaths (the page cache kept), power losses (unforced writes lost or torn, Sim_disk),
   deaths in the middle of a disk call, a forced byte of the log flipped before a restart (the 2018 rule's damage),
   slow disks (an fsync of up to 300 ms), servers paused (up to 400 ms: a garbage collection, a stopped VM), clocks
   running up to 3 % apart. Clients write and read through whichever server they believe leads, as the library does
   (not_leader sends them to the leader; no_leader, a pause).

   Checked: at most one leader a term; every server's applied entries are the committed log's (no two different
   entries applied at one index anywhere); every write a client was told is committed is in the final log at its
   index; reads linearizable: a read served at index r returns the committed log's state at r, sees every write
   answered before it began, nothing written after it ended, and no read that ended before it began saw a later
   index; after the faults stop and the network heals, every server reaches the same commit and the same log. A
   failure prints its seed; [raft_sim.exe --seed N] replays it (TRACE=1 prints its elections, starts, crashes and
   truncations), [--servers 5] runs five. Counted, not failures: a cluster that settles on no leader because a
   majority's logs are damaged (the 2018 rule's cost: repair by any peer is a next step), and a follower behind the
   leader's log start (a catch-up from the journals is a next step). *)

open Cepheus
open Cepheus_server
module C = Check

exception Down  (* the server's process died during a call of its disk *)

let election = 150
let heartbeat = 15
let tick = 5

type op = Put of { gen : int; first : int; entries : (int * Bytes.t) list; commit : int } | Trunc of { gen : int; at : int; prev_term : int }

type kind = W of string * string | R of string

type hist = {
  hkind : kind;
  hs : int;  (* start, global ms *)
  mutable he : int;  (* end; -1 while open *)
  mutable index : int;  (* write: its log index once committed; read: the index it was served at *)
  value : string;  (* a read's answer *)
  mutable known : bool;  (* a write: told committed *)
}

type server = {
  id : int;
  sim : Sim_disk.t;
  disk : Disk.t;
  mutable core : Raft.t option;  (* None: down *)
  mutable rlog : Raftlog.t option;
  mutable dq : (int * op) list;  (* (ready at, op), oldest first *)
  mutable pend : (int * (int * Bytes.t)) list;  (* entries given to the disk, not yet in the log *)
  rate : float;
  mutable kv : (string * string) list;  (* the state machine *)
  mutable applied : int;
  mutable ckpt : int * (string * string) list;  (* forced: what a journal forced holds *)
  mutable paused_until : int;
  mutable up_at : int;  (* restarts at this time once down *)
  mutable waiting : (int * int * int * hist) list;  (* (index, term, client, its write) of writes proposed here *)
}

type msg = { src : int; dst : int; at : int; m : Raft.msg; data : Bytes.t array }

type client = { cid : int; mutable target : int; mutable cur : hist option; mutable sent_at : int; mutable next_at : int }

type w = {
  seed : int;
  r : Rng.t;
  n : int;
  servers : server array;
  mutable net : msg list;
  cut : bool array array;
  mutable now : int;
  leaders : (int, int) Hashtbl.t;  (* term -> leader *)
  applied_at : (int, int * Bytes.t) Hashtbl.t;  (* index -> the entry applied there, anywhere *)
  mutable hist : hist list;
  clients : client array;
  (* fault rates *)
  loss : float;
  dup : float;
  maxdelay : int;
  mutable faults : bool;
  mutable serial : int;
}

let stats = Hashtbl.create 16
let count k = Hashtbl.replace stats k (1 + Option.value (Hashtbl.find_opt stats k) ~default:0)

exception Over

let fail w fmt = Printf.ksprintf (fun s -> C.fail "seed %d: %s" w.seed s; raise Over) fmt

let clock w s = int_of_float (float w.now *. s.rate)

let encode_kv k v = Bytes.of_string (k ^ "\000" ^ v)
let decode_kv d = match String.index_opt (Bytes.to_string d) '\000' with Some i -> let s = Bytes.to_string d in Some (String.sub s 0 i, String.sub s (i + 1) (String.length s - i - 1)) | None -> None

let entry s i =
  match List.assoc_opt i s.pend with
  | Some x -> Some x
  | None -> (match s.rlog with Some l -> Raftlog.read l i | None -> None)

(* ---- the state machine ---- *)

(* TRACE=1: elections, starts, crashes and truncations, with the simulated time (to read a failing seed) *)
let tr w fmt = Printf.ksprintf (fun m -> if Sys.getenv_opt "TRACE" <> None then Printf.printf "%6d %s\n" w.now m) fmt

let apply_one w s i (term, d) =
  (match Hashtbl.find_opt w.applied_at i with
   | Some (t', d') when t' <> term || not (Bytes.equal d d') ->
     fail w "server %d applies entry %d of term %d, another server applied one of term %d there" s.id i term t'
   | Some _ -> ()
   | None -> Hashtbl.replace w.applied_at i (term, d));
  (match decode_kv d with Some (k, v) -> s.kv <- (k, v) :: List.remove_assoc k s.kv | None -> ());
  s.applied <- i

let apply w s upto =
  while s.applied < upto do
    let i = s.applied + 1 in
    match entry s i with
    | Some x -> apply_one w s i x
    | None -> fail w "server %d lacks committed entry %d (its log starts at %d)" s.id i (match s.rlog with Some l -> Raftlog.first l | None -> 0)
  done

(* ---- effects ---- *)

let core s = match s.core with Some c -> c | None -> raise Down

let save s c =
  match s.rlog with
  | Some l -> Raftlog.save_state l { Raftlog.term = c.Raft.term; vote = (if c.vote >= 0 then string_of_int c.vote else ""); repair = c.repair }
  | None -> raise Down

let disk_delay w = if w.faults && Rng.chance w.r 0.02 then 50 + Rng.int w.r 250 else Rng.int w.r 3

let send w s k (m : Raft.msg) =
  let data =
    match m with
    | Append x -> (
      try Some (Array.mapi (fun j tm -> match entry s (x.prev_index + 1 + j) with Some (tm', d) when tm' = tm -> d | _ -> raise Exit) x.terms)
      with Exit -> None)
    | _ -> Some [||]
  in
  match data with
  | None -> count "append dropped: entries gone"
  | Some data ->
    let one () = w.net <- { src = s.id; dst = k; at = w.now + 1 + Rng.int w.r w.maxdelay; m; data } :: w.net in
    if w.faults && Rng.chance w.r w.loss then count "lost"
    else begin
      one ();
      if w.faults && Rng.chance w.r w.dup then (count "duplicated"; one ())
    end

let rec run ?(msg = ([||], [||])) w s =
  let c = core s in
  List.iter
    (fun (e : Raft.action) ->
      match e with
      | Save -> save s c
      | Truncate i ->
        tr w "server %d truncates from %d (commit %d, term %d)" s.id i c.commit c.term;
        s.pend <- List.filter (fun (j, _) -> j < i) s.pend;
        s.dq <- s.dq @ [ w.now + disk_delay w, Trunc { gen = c.gen; at = i; prev_term = Raft.term_at c (i - 1) } ]
      | Store { first; skip; count = n } ->
        let terms, data = msg in
        let es = List.init n (fun k -> terms.(skip + k), data.(skip + k)) in
        s.pend <- List.mapi (fun k x -> first + k, x) es @ List.filter (fun (j, _) -> j < first) s.pend;
        s.dq <- s.dq @ [ w.now + disk_delay w, Put { gen = c.gen; first; entries = es; commit = c.commit } ]
      | Send (k, m) -> send w s k m
      | Commit i ->
        apply w s i;
        resolve w s c i
      | Lead -> (
        let x = c.term, Bytes.empty in
        s.pend <- (c.noop, x) :: s.pend;
        s.dq <- s.dq @ [ w.now + disk_delay w, Put { gen = c.gen; first = c.noop; entries = [ x ]; commit = c.commit } ];
        tr w "server %d leads term %d (noop %d, last %d, commit %d)" s.id c.term c.noop (Raft.last_index c) c.commit;
        match Hashtbl.find_opt w.leaders c.term with
        | Some l when l <> s.id -> fail w "two leaders in term %d: %d and %d" c.term l s.id
        | _ -> Hashtbl.replace w.leaders c.term s.id; count "elections")
      | Unlead ->
        tr w "server %d unleads (term %d commit %d, %d waiting)" s.id c.term c.commit (List.length s.waiting);
        resolve w s c max_int)
    (Raft.drain c)

(* the writes proposed here up to [upto]: committed if the committed entry at their index is theirs (their term) *)
and resolve w s c upto =
  let done_, rest = List.partition (fun (j, _, _, _) -> j <= upto) s.waiting in
  s.waiting <- rest;
  List.iter (fun (j, tm, cl, h) -> if j <= c.Raft.commit && Raft.term_at c j = tm then answer_write w cl h j else unknown w cl h) done_

(* a write told committed: its index (unless its client gave up on it before) *)
and answer_write w cl h j =
  if h.he < 0 then begin
    h.he <- w.now;
    h.index <- j;
    h.known <- true;
    let c = w.clients.(cl) in
    if (match c.cur with Some x -> x == h | None -> false) then (c.cur <- None; c.next_at <- w.now + Rng.int w.r 20)
  end

(* applied once or not at all: the client moves on *)
and unknown w cl h =
  if h.he < 0 then begin
    h.he <- w.now;
    let c = w.clients.(cl) in
    if (match c.cur with Some x -> x == h | None -> false) then (c.cur <- None; c.next_at <- w.now + Rng.int w.r 20)
  end

(* ---- a server's life ---- *)

let crash w s ~power =
  count (if power then "power losses" else "deaths");
  s.core <- None;
  (match s.rlog with Some l -> (try Raftlog.close l with _ -> ()) | None -> ());
  s.rlog <- None;
  s.dq <- [];
  s.pend <- [];
  List.iter (fun (_, _, cl, h) -> unknown w cl h) s.waiting;
  s.waiting <- [];
  tr w "server %d %s" s.id (if power then "power loss" else "dies");
  if power then Sim_disk.crash s.sim else Sim_disk.kill s.sim;
  (* the 2018 rule's damage: a forced byte of the log flipped before the restart *)
  if power && Rng.chance w.r 0.05 then begin
    let segs = List.filter (fun n -> String.length n = 24 && String.sub n 0 4 = "log.") (try s.disk.readdir "/raft" with _ -> []) in
    match segs with
    | [] -> ()
    | l -> (match Sim_disk.flip_durable s.sim ("/raft/" ^ List.nth l (Rng.int w.r (List.length l))) 52 max_int with Some _ -> count "bytes flipped" | None -> ())
  end;
  s.up_at <- w.now + 20 + Rng.int w.r 400

let start w s =
  match Raftlog.open_ s.disk "/raft" ~cluster:"cph-c-0123456789abcdef" with
  | exception Raftlog.Damaged m -> count "refused to start"; ignore m; s.up_at <- max_int
  | exception Sim_disk.Crash -> Sim_disk.crash s.sim; s.up_at <- w.now + 50
  | l, r ->
    if r.damage <> None then count "damage found";
    tr w "server %d starts: term %d vote %s repair %d log %d..%d commit hint %d damage %s" s.id r.st.term r.st.vote r.st.repair r.start (r.start + Array.length r.terms - 1) r.commit (Option.value r.damage ~default:"-");
    let vote = match int_of_string_opt r.st.vote with Some k -> k | None -> -1 in
    let c =
      Raft.make ~me:s.id ~n:w.n ~election_ms:election ~heartbeat_ms:heartbeat ~rng:(Rng.split w.r) ~now:(clock w s) ~term:r.st.term
        ~vote ~repair:r.st.repair ~start:r.start ~prev_term:r.prev_term ~terms:r.terms ~sizes:r.sizes ~commit:r.commit
    in
    s.core <- Some c;
    s.rlog <- Some l;
    (* the state machine: its checkpoint, then what the log holds committed *)
    let ci, kv = s.ckpt in
    s.kv <- kv;
    s.applied <- ci;
    (try apply w s (max ci c.commit) with Over -> raise Over);
    if s.applied < c.commit then fail w "server %d cannot replay to its commit hint %d" s.id c.commit;
    count "starts"

(* a call into the server that may die in a disk call *)
let guard w s f =
  match f () with
  | () -> ()
  | exception (Down | Sim_disk.Crash) -> crash w s ~power:true
  | exception Disk.Io m -> fail w "server %d: disk error %s" s.id m

let disk_step w s =
  match s.dq with
  | (at, op) :: rest when at <= w.now && s.core <> None ->
    s.dq <- rest;
    guard w s (fun () ->
        let l = match s.rlog with Some l -> l | None -> raise Down in
        if w.faults && Rng.chance w.r 0.01 then Sim_disk.crash_after s.sim (Rng.int w.r 4);
        (match op with
         | Put { gen; first; entries; commit } ->
           Raftlog.append l ~first ~commit entries;
           s.pend <- List.filter (fun (j, (_, d)) -> not (j >= first && j < first + List.length entries && List.exists (fun (_, d') -> d == d') entries)) s.pend;
           Raft.persisted (core s) ~gen (first + List.length entries - 1)
         | Trunc { at; prev_term; _ } -> Raftlog.truncate l at ~prev_term);
        Sim_disk.crash_after s.sim (-1);
        run w s)
  | _ -> ()

(* a checkpoint: the state machine forced, the log cut behind it (whole segments) *)
let checkpoint w s =
  guard w s (fun () ->
      let c = core s and l = Option.get s.rlog in
      s.ckpt <- s.applied, s.kv;
      let u = min (s.applied + 1) (min (c.commit + 1) (min (c.persisted + 1) (Raft.floor c + 1))) in
      Raftlog.cut_before l u;
      Raft.compact c (min (Raftlog.first l) u))

(* ---- clients ---- *)

let leads w s =
  match s.core with
  | Some c -> Raft.ready c && s.applied >= c.noop && clock w s < Raft.lease_until c (clock w s)
  | None -> false

let client_step w cl =
  match cl.cur with
  | Some h when h.he < 0 && w.now - cl.sent_at > 4 * election -> unknown w cl.cid h  (* no answer: applied once or not at all *)
  | Some _ -> ()
  | None when w.now >= cl.next_at && w.faults -> (
    let s = w.servers.(cl.target) in
    let redirect () =
      match s.core with
      | Some c when c.leader >= 0 && c.leader <> s.id -> cl.target <- c.leader
      | _ -> cl.target <- Rng.int w.r w.n; cl.next_at <- w.now + 10
    in
    if s.core = None || s.paused_until > w.now then redirect ()
    else if not (leads w s) then redirect ()
    else
      let key = Printf.sprintf "k%d" (Rng.int w.r 3) in
      if Rng.bool w.r then begin
        let h = { hkind = R key; hs = w.now; he = w.now; index = s.applied; value = Option.value (List.assoc_opt key s.kv) ~default:""; known = true } in
        w.hist <- h :: w.hist;
        cl.next_at <- w.now + Rng.int w.r 10
      end
      else begin
        w.serial <- w.serial + 1;
        let v = Printf.sprintf "v%d" w.serial in
        let d = encode_kv key v in
        let c = core s in
        match Raft.propose c (clock w s) (Bytes.length d) with
        | None -> redirect ()
        | Some i ->
          let h = { hkind = W (key, v); hs = w.now; he = -1; index = -1; value = v; known = false } in
          w.hist <- h :: w.hist;
          cl.cur <- Some h;
          cl.sent_at <- w.now;
          s.waiting <- (i, c.term, cl.cid, h) :: s.waiting;
          s.pend <- (i, (c.term, d)) :: s.pend;
          s.dq <- s.dq @ [ w.now + disk_delay w, Put { gen = c.gen; first = i; entries = [ c.term, d ]; commit = c.commit } ];
          guard w s (fun () -> run w s)
      end)
  | None -> ()

(* ---- faults ---- *)

let faults w =
  if Rng.chance w.r 0.004 then begin
    (* a partition: one server alone, or a link cut one way, healed later *)
    Array.iter (fun row -> Array.fill row 0 w.n false) w.cut;
    (match Rng.int w.r 3 with
     | 0 -> let a = Rng.int w.r w.n in for b = 0 to w.n - 1 do if b <> a then (w.cut.(a).(b) <- true; w.cut.(b).(a) <- true) done; count "partitions"
     | 1 -> let a = Rng.int w.r w.n and b = Rng.int w.r w.n in if a <> b then (w.cut.(a).(b) <- true; count "one-way cuts")
     | _ ->
       (* a minority apart (5 servers: two) *)
       let side = Array.init w.n (fun _ -> Rng.bool w.r) in
       for a = 0 to w.n - 1 do for b = 0 to w.n - 1 do if side.(a) <> side.(b) then w.cut.(a).(b) <- true done done;
       count "splits")
  end;
  if Rng.chance w.r 0.003 then Array.iter (fun row -> Array.fill row 0 w.n false) w.cut;
  Array.iter
    (fun s ->
      if s.core <> None && Rng.chance w.r 0.0008 then crash w s ~power:(Rng.bool w.r);
      if s.core <> None && Rng.chance w.r 0.001 then (count "pauses"; s.paused_until <- w.now + 50 + Rng.int w.r 350))
    w.servers

(* ---- the run ---- *)

let deliver w =
  let due, later = List.partition (fun m -> m.at <= w.now) w.net in
  w.net <- later;
  (* the same instant: in an order drawn from the seed *)
  let due = List.map (fun m -> Rng.next w.r, m) due |> List.sort compare |> List.map snd in
  List.iter
    (fun m ->
      let s = w.servers.(m.dst) in
      if w.cut.(m.src).(m.dst) then count "cut off"
      else if s.paused_until > w.now then w.net <- { m with at = s.paused_until } :: w.net
      else
        match s.core with
        | None -> ()
        | Some c ->
          let terms = match m.m with Append x -> x.terms | _ -> [||] in
          guard w s (fun () -> Raft.receive c (clock w s) m.src m.m; run ~msg:(terms, m.data) w s))
    due

let step w =
  w.now <- w.now + 1;
  if w.now mod 1000 = 0 && Sys.getenv_opt "RAFT_SIM_DEBUG" <> None then
    Printf.eprintf "t=%d messages in flight %d\n%!" w.now (List.length w.net);
  deliver w;
  Array.iter
    (fun s ->
      if s.core = None && w.now >= s.up_at then start w s;
      if s.core <> None && s.paused_until <= w.now then begin
        disk_step w s;
        if s.core <> None && (w.now + s.id) mod tick = 0 then guard w s (fun () -> Raft.tick (core s) (clock w s); run w s);
        if s.core <> None && (w.now + 7 * s.id) mod 300 = 0 then checkpoint w s
      end)
    w.servers;
  if w.faults then faults w;
  Array.iter (client_step w) w.clients

(* ---- the checks ---- *)

let final_log w =
  (* the committed prefix: the greatest commit, and the entries every server applied *)
  let top = Hashtbl.fold (fun i _ m -> max i m) w.applied_at 0 in
  Array.init top (fun i -> match Hashtbl.find_opt w.applied_at (i + 1) with Some x -> Some x | None -> None)

let check_history w =
  let log = final_log w in
  let state_at key r =
    let v = ref "" in
    for i = 1 to min r (Array.length log) do
      match log.(i - 1) with Some (_, d) -> (match decode_kv d with Some (k, x) when k = key -> v := x | _ -> ()) | None -> ()
    done;
    !v
  in
  let pos = Hashtbl.create 64 in
  Array.iteri (fun i e -> match e with Some (_, d) -> (match decode_kv d with Some (_, v) -> Hashtbl.replace pos v (i + 1) | None -> ()) | None -> ()) log;
  let writes = List.filter (fun h -> match h.hkind with W _ -> true | R _ -> false) w.hist in
  let reads = List.filter (fun h -> match h.hkind with R _ -> true | W _ -> false) w.hist in
  List.iter
    (fun h ->
      if h.known then
        match Hashtbl.find_opt pos h.value with
        | Some i when i = h.index -> C.check true ""
        | Some i -> fail w "write %s told committed at %d is at %d" h.value h.index i
        | None -> fail w "write %s told committed at %d is not in the committed log (a committed write lost)" h.value h.index)
    writes;
  List.iter
    (fun r ->
      let key = match r.hkind with R k -> k | W _ -> "" in
      if r.index > Array.length log then fail w "a read at index %d, past the committed log's %d" r.index (Array.length log);
      let v = state_at key r.index in
      if v <> r.value then fail w "a read of %s at index %d gave %S, the committed log has %S there" key r.index r.value v;
      List.iter
        (fun h ->
          if h.known && h.he < r.hs && h.index > r.index then
            fail w "a read of index %d began after write %s was answered at index %d (a stale read)" r.index h.value h.index;
          if h.hs > r.he && (match Hashtbl.find_opt pos h.value with Some i -> i <= r.index | None -> false) then
            fail w "a read at index %d saw write %s, which began after it ended" r.index h.value)
        writes;
      List.iter (fun r2 -> if r2.he < r.hs && r2.index > r.index then fail w "a read at %d after a read at %d had ended" r.index r2.index) reads)
    reads;
  C.check true "history"

let converge w =
  (* faults stop, the network heals, every server up: they reach one commit and one log *)
  w.faults <- false;
  Array.iter (fun row -> Array.fill row 0 w.n false) w.cut;
  Array.iter (fun s -> if s.up_at = max_int then () else if s.core = None then s.up_at <- w.now) w.servers;
  let settled () =
    let ups = List.filter (fun s -> s.core <> None) (Array.to_list w.servers) in
    match ups with
    | [] -> false
    | s0 :: _ ->
      let c0 = core s0 in
      List.length ups = Array.length (Array.of_list (List.filter (fun s -> s.up_at <> max_int) (Array.to_list w.servers)))
      && List.exists (fun s -> (core s).role = Raft.Leader) ups
      && List.for_all (fun s -> let c = core s in c.commit = c0.commit && s.applied = c.commit && Raft.last_index c = c.commit && c.persisted = Raft.last_index c) ups
  in
  let t0 = w.now in
  while (not (settled ())) && w.now - t0 < 20_000 do step w done;
  if not (settled ()) then begin
    (* a follower behind the leader's log start needs the journals' catch-up (a next step): counted, not a failure *)
    let lead = Array.to_list w.servers |> List.find_map (fun s -> match s.core with Some c when c.role = Raft.Leader -> Some c | _ -> None) in
    let behind =
      match lead with
      | Some l -> Array.exists (fun s -> match s.core with Some c -> c.role <> Raft.Leader && Raft.last_index c < l.start - 1 | None -> false) w.servers
      | None -> false
    in
    if Sys.getenv_opt "RAFT_SIM_DEBUG" <> None then
      Array.iter
        (fun s ->
          match s.core with
          | Some c ->
            Printf.printf "server %d: role %s term %d leader %d commit %d applied %d last %d persisted %d start %d repair %d dq %d\n" s.id
              (match c.role with Raft.Leader -> "L" | Follower -> "F" | Pre_candidate -> "P" | Candidate -> "C") c.term c.leader c.commit
              s.applied (Raft.last_index c) c.persisted c.start c.repair (List.length s.dq);
            if c.role = Raft.Leader then Array.iteri (fun k (p : Raft.peer) -> Printf.printf "  peer %d next %d matched %d probing %b\n" k p.next p.matched p.probing) c.peers
          | None -> Printf.printf "server %d: down (up at %d)\n" s.id s.up_at)
        w.servers;
    (* the 2018 rule's cost: a majority damaged elects no leader until repaired (repair from any peer: a next step) *)
    let abstain = Array.fold_left (fun a s -> match s.core with Some c when c.repair > 0 -> a + 1 | None -> a + 1 | _ -> a) 0 w.servers in
    if abstain >= w.n / 2 + 1 then count "blocked: a majority damaged"
    else if behind then count "behind the leader's log start (catch-up from the journals: a next step)" else fail w "the cluster did not settle within 20 s after the faults stopped"
  end
  else begin
    count "converged";
    (* the same log everywhere *)
    let ups = List.filter (fun s -> s.core <> None) (Array.to_list w.servers) in
    let l0 = List.hd ups in
    let c0 = core l0 in
    List.iter
      (fun s ->
        let c = core s in
        for i = max c.start c0.start to Raft.last_index c do
          if Raft.term_at c i <> Raft.term_at c0 i then
            fail w "servers %d and %d differ at index %d after settling (terms %d and %d; starts %d and %d, commits %d and %d, last %d and %d)" l0.id s.id i
              (Raft.term_at c0 i) (Raft.term_at c i) c0.start c.start c0.commit c.commit (Raft.last_index c0) (Raft.last_index c)
        done)
      ups
  end

let run_seed ~n seed =
  let r = Rng.make (seed * 7919 + n) in
  let servers =
    Array.init n (fun id ->
        let sim = Sim_disk.create (Rng.split r) in
        { id; sim; disk = Sim_disk.disk sim; core = None; rlog = None; dq = []; pend = []; rate = 0.97 +. (0.06 *. float (Rng.int r 1000) /. 1000.);
          kv = []; applied = 0; ckpt = 0, []; paused_until = 0; up_at = 0; waiting = [] })
  in
  let w =
    { seed; r; n; servers; net = []; cut = Array.make_matrix n n false; now = 0; leaders = Hashtbl.create 16; applied_at = Hashtbl.create 256;
      hist = []; clients = Array.init 3 (fun cid -> { cid; target = Rng.int r n; cur = None; sent_at = 0; next_at = 0 });
      loss = float (Rng.int r 20) /. 100.; dup = float (Rng.int r 10) /. 100.; maxdelay = 1 + Rng.int r 20; faults = true; serial = 0 }
  in
  Raftlog.segment_limit := 2048 + Rng.int r 4096;
  (try
     for _ = 1 to 8000 do step w done;
     converge w;
     check_history w
   with Over -> ());
  count "seeds"

let () =
  let seeds = ref 300 and only = ref None and n = ref 3 in
  Arg.parse
    [ "--seeds", Arg.Set_int seeds, "N"; "--seed", Arg.Int (fun s -> only := Some s), "N"; "--servers", Arg.Set_int n, "3 or 5" ]
    ignore "raft_sim.exe [--seeds N | --seed N] [--servers N]";
  (match !only with Some s -> run_seed ~n:!n s | None -> for s = 1 to !seeds do run_seed ~n:!n s done);
  let keys = List.sort compare (Hashtbl.fold (fun k _ l -> k :: l) stats []) in
  Printf.printf "%s\n" (String.concat ", " (List.map (fun k -> Printf.sprintf "%s %d" k (Hashtbl.find stats k)) keys));
  C.finish (Printf.sprintf "raft sim (%d servers)" !n)
