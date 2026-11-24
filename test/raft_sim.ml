(* Deterministic simulation of a Raft cluster (server/raft.ml, server/raftlog.ml): 3 or 5 servers, each its own
   machine with its own simulated disk (Sim_disk) and clock, the same Raft core and log the server runs, one seed
   deciding everything. Its state machine is a small register store (a write sets a key to a value of its own),
   checkpointed now and then (as each database's journal is forced each second), the log's start cut behind it.

   Faults, from the seed: messages lost, duplicated, delayed (so reordered); partitions (a server alone, a minority,
   links cut one way); process deaths (the page cache kept), power losses (unforced writes lost or torn, Sim_disk),
   deaths in the middle of a disk call, a forced byte of the log flipped before a restart (the 2018 rule's damage),
   a server's whole disk lost (it starts again empty and fresh; while the damaged and the lost are a minority),
   slow disks (an fsync of up to 300 ms), servers paused (up to 400 ms: a garbage collection, a stopped VM), clocks
   running up to 3 % apart. Clients write and read through whichever server they believe leads, as the library does
   (not_leader sends them to the leader; no_leader, a pause).

   The catch-up (server/catchup.ml): a follower the leader can no longer send entries to (Snap, then Fetch) takes a
   copy of the leader's state machine at its applied index, which takes 20 to 420 ms and breaks if either side dies
   meanwhile; one in ten is damaged on its way (a peer that lies, or a bad disk), one behind the follower's own state
   is refused; Raft.install decides, the copy is committed (DATA/raft/copy, the sim's state machine beside it) and
   the server starts again on it, the install repeated by a start a crash cut. The leader's floor waits for a silent
   peer 200 to 2,200 ms (the server: 5 minutes), so that servers down longer take copies.

   Clean stops of the leader (cepheus stop): it hands its leadership over (Timeout_now to the most up-to-date peer,
   which stands at once and is voted for despite stickiness), then stops once it no longer leads or after two
   election timeouts; reads and writes are not served meanwhile.

   Entries are the server's (Cluster): a write is a frame, one in eight a large one, carried in pieces of 64 to 320
   bytes proposed at once (Cluster's rules: a sequence is applied whole at its last piece, read back from the log, and
   never once broken by a newer term; the log is not cut, nor a copy made, inside an open one).

   Checked: at most one leader a term; every server's applied entries are the committed log's (no two different
   entries applied at one index anywhere); a large write is applied whole or not at all (its value's bytes are
   checked); every write a client was told is committed is in the final log at its
   index; reads linearizable: a read served at index r returns the committed log's state at r, sees every write
   answered before it began, nothing written after it ended, and no read that ended before it began saw a later
   index; after the faults stop and the network heals, every server reaches the same commit and the same log. A
   failure prints its seed; [raft_sim.exe --seed N] replays it (TRACE=1 prints its elections, starts, crashes and
   truncations), [--servers 5] runs five. Counted, not a failure: a cluster that settles on no leader because a
   majority's logs are damaged (the 2018 rule's cost: repair by any peer is a next step). *)

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

(* a copy being taken from [src], at its applied index [x] (of term [xt]), whole at [until] *)
type copy = { src : int; x : int; xt : int; kv : (string * string) list; kv_at : int; until : int; damaged : bool; life : int }

type server = {
  id : int;
  mutable sim : Sim_disk.t;
  mutable disk : Disk.t;
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
  mutable copying : copy option;
  mutable fetch_after : int;
  mutable lives : int;  (* starts: a copy from a server that died meanwhile breaks *)
  mutable sound : bool;  (* neither damaged (the 2018 rule) nor lost (fresh) when last seen up *)
  seqs : (string, Cluster.seq) Hashtbl.t;  (* the sequences of pieces not whole, as the apply thread keeps them *)
  mutable stop_at : int;  (* a clean stop under way: the server stops then, or once it no longer leads *)
  mutable held_upto : int;
      (* the state machine holds the entries up to this one already (its checkpoint, or a copy, is ahead of the log a
         start found): applied again, tracked, and their writes skipped (the server: their groups skipped) *)
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
  floor_ms : int;
}

let stats = Hashtbl.create 16
let count k = Hashtbl.replace stats k (1 + Option.value (Hashtbl.find_opt stats k) ~default:0)

exception Over

let fail w fmt = Printf.ksprintf (fun s -> C.fail "seed %d: %s" w.seed s; raise Over) fmt

let clock w s = int_of_float (float w.now *. s.rate)

let encode_kv k v = Bytes.of_string (k ^ "\000" ^ v)
let decode_kv d = match String.index_opt (Bytes.to_string d) '\000' with Some i -> let s = Bytes.to_string d in Some (String.sub s 0 i, String.sub s (i + 1) (String.length s - i - 1)) | None -> None

(* the one database's id, and a write's entries: one frame, or a large value's pieces *)
let db = "sim-database-001"
let big_value serial n = Printf.sprintf "v%d:%s" serial (String.make n (Char.chr (97 + (serial mod 26))))

(* a large value is whole: its bytes after ':' all the letter of its serial *)
let whole v =
  match String.index_opt v ':' with
  | None -> true
  | Some i ->
    match int_of_string_opt (String.sub v 1 (i - 1)) with
    | None -> false
    | Some serial ->
      let c = Char.chr (97 + (serial mod 26)) in
      String.length v > i + 1 && String.for_all (( = ) c) (String.sub v (i + 1) (String.length v - i - 1))

let entries_of w k v =
  let f = encode_kv k v in
  let n = Bytes.length f in
  if n <= 64 then [ Cluster.encode_frame db f ]
  else
    let size = 64 + Rng.int w.r 256 in
    List.init ((n + size - 1) / size) (fun j -> Cluster.encode_piece db ~total:n ~off:(j * size) f (min size (n - (j * size))))

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
  let put f =
    if i > s.held_upto then
    match decode_kv f with
    | Some (k, v) ->
      if not (whole v) then fail w "server %d applies a value that is not whole at %d (%d bytes)" s.id i (String.length v);
      if String.contains v ':' then tr w "server %d applies %s=%s at %d" s.id k (String.sub v 0 (String.index v ':')) i;
      s.kv <- (k, v) :: List.remove_assoc k s.kv
    | None -> fail w "server %d applies a frame that does not decode at %d" s.id i
  in
  (match Cluster.decode_entry d with
   | Some e -> (
     match e, Cluster.track s.seqs i term e with
     | Frame (_, f), _ -> put f
     | Piece _, Some q -> (
       match s.rlog with
       | Some l -> put (Cluster.assemble l ~pend:(fun j -> List.assoc_opt j s.pend) ~get:(entry s) ~from:q.sfirst ~upto:i ~total:q.stotal)
       | None -> raise Down)
     | _ -> ())
   | None -> ());
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
        resolve w s c max_int
      | Fetch k -> fetch w s k)
    (Raft.drain c)

(* a copy of [k]'s state machine at its applied index, pinned there for a while *)
and fetch w s k =
  let src = w.servers.(k) in
  match s.copying, src.core with
  | None, Some sc when w.now >= s.fetch_after ->
    let x = min src.applied (Cluster.open_first src.seqs - 1) in
    let xt = Raft.term_at sc x in
    if x >= 1 && xt >= 0 then begin
      Raft.pin sc ~index:x ~until:(clock w src + 2000);
      count "copies begun";
      tr w "server %d takes a copy from %d at %d (term %d)" s.id k x xt;
      s.copying <- Some { src = k; x; xt; kv = src.kv; kv_at = max src.applied src.held_upto; until = w.now + 20 + Rng.int w.r 400; damaged = w.faults && Rng.chance w.r 0.1; life = src.lives }
    end
  | _ -> ()

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
  s.copying <- None;
  s.stop_at <- max_int;
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

let cluster = "cph-c-0123456789abcdef"

let encode_kv_list l = Bytes.of_string (String.concat "\001" (List.map (fun (k, v) -> k ^ "\000" ^ v) l))
let decode_kv_list b = if Bytes.length b = 0 then [] else List.filter_map (fun e -> decode_kv (Bytes.of_string e)) (String.split_on_char '\001' (Bytes.to_string b))

(* a copy committed (/raft/copy, its state machine in /raft/copy.kv beside) installed before anything else, as
   Catchup.at_start does: the state machine swapped, the log made to start after it, the index removed last *)
let install_copy s =
  let d = s.disk in
  if d.exists "/raft/copy" then begin
    match Raftlog.decode_copy (Disk.read_all d "/raft/copy") with
    | Some (x, term, _) ->
      (match decode_kv_list (Disk.read_all d "/raft/copy.kv") with
       | ("@", at) :: kv -> s.ckpt <- int_of_string at, kv
       | kv -> s.ckpt <- x, kv);
      Raftlog.install d "/raft" ~cluster ~first:(x + 1) ~prev_term:term;
      d.remove "/raft/copy.kv";
      d.remove "/raft/copy";
      d.sync_dir "/raft";
      count "copies installed"
    | None -> d.remove "/raft/copy"; d.sync_dir "/raft"
  end
  else if d.exists "/raft/copy.kv" then (d.remove "/raft/copy.kv"; d.sync_dir "/raft")

let start w s =
  match install_copy s; Raftlog.open_ s.disk "/raft" ~cluster with
  | exception Raftlog.Damaged m -> count "refused to start"; ignore m; s.up_at <- max_int
  | exception Sim_disk.Crash -> Sim_disk.crash s.sim; s.up_at <- w.now + 50
  | l, r ->
    if r.damage <> None then count "damage found";
    tr w "server %d starts: term %d vote %s repair %d log %d..%d commit hint %d damage %s" s.id r.st.term r.st.vote r.st.repair r.start (r.start + Array.length r.terms - 1) r.commit (Option.value r.damage ~default:"-");
    let vote = match int_of_string_opt r.st.vote with Some k -> k | None -> -1 in
    let c =
      Raft.make ~me:s.id ~n:w.n ~election_ms:election ~heartbeat_ms:heartbeat ~floor_ms:w.floor_ms ~rng:(Rng.split w.r) ~now:(clock w s)
        ~term:r.st.term ~vote ~repair:r.st.repair ~fresh:r.fresh ~start:r.start ~prev_term:r.prev_term ~terms:r.terms ~sizes:r.sizes ~commit:r.commit
    in
    s.core <- Some c;
    s.rlog <- Some l;
    s.lives <- s.lives + 1;
    (* the state machine: its checkpoint, the sequences of pieces open at it (Cluster.create), then what the log holds
       committed *)
    let ci, kv = s.ckpt in
    s.kv <- kv;
    (* as the server: applied from the log (Cluster.create), the state machine's own entries above it skipped *)
    let from = min ci (max (r.start - 1) (min c.commit (r.start + Array.length r.terms - 1))) in
    s.applied <- from;
    s.held_upto <- ci;
    Hashtbl.reset s.seqs;
    Raftlog.iter l ~from:r.start ~upto:from (fun i tm d -> match Cluster.decode_entry d with Some e -> ignore (Cluster.track s.seqs i tm e) | None -> ());
    (try apply w s c.commit with Over -> raise Over);
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
      s.ckpt <- max s.applied s.held_upto, s.kv;
      let u = min (min (s.applied + 1) (Cluster.open_first s.seqs)) (min (c.commit + 1) (min (c.persisted + 1) (Raft.floor c (clock w s) + 1))) in
      Raftlog.cut_before l u;
      Raft.compact c (min (Raftlog.first l) u))

(* a copy whole: refused if broken (either side died), damaged or behind this server; else Raft decides; committed,
   the server starts again on it *)
let copy_step w s =
  match s.copying, s.core with
  | Some cp, Some c when w.now >= cp.until ->
    s.copying <- None;
    let refused what = count what; tr w "server %d: %s" s.id what; s.fetch_after <- w.now + 50 + Rng.int w.r 200 in
    if w.servers.(cp.src).lives <> cp.life || w.servers.(cp.src).core = None then refused "copies broken (the source died)"
    else if cp.damaged then refused "copies refused: damaged"
    else if cp.x < s.applied then refused "copies refused: behind this server"
    else
      guard w s (fun () ->
          if Raft.install c ~index:cp.x ~term:cp.xt then begin
            run w s;
            Disk.write_file s.disk "/raft/copy.kv" (encode_kv_list (("@", string_of_int cp.kv_at) :: cp.kv));
            Disk.write_file s.disk "/raft/copy" (Raftlog.encode_copy ~index:cp.x ~term:cp.xt ~source:(string_of_int cp.src));
            count "copies committed";
            tr w "server %d commits a copy at %d: it starts again" s.id cp.x;
            (* the clean stop and the start again (exec): what is forced stays *)
            crash w s ~power:false;
            s.up_at <- w.now + 5
          end
          else (count "copies not needed"; tr w "server %d: the copy at %d is not needed" s.id cp.x))
  | _ -> ()

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
        let v = if Rng.int w.r 8 = 0 then big_value w.serial (100 + Rng.int w.r 2000) else Printf.sprintf "v%d" w.serial in
        let c = core s in
        (* the entries of one write, at once (Cluster.propose under its lock) *)
        let last =
          List.fold_left
            (fun last d ->
              match last with
              | None -> None
              | Some _ -> (
                match Raft.propose c (clock w s) (Bytes.length d) with
                | None -> None
                | Some i ->
                  s.pend <- (i, (c.term, d)) :: s.pend;
                  s.dq <- s.dq @ [ w.now + disk_delay w, Put { gen = c.gen; first = i; entries = [ c.term, d ]; commit = c.commit } ];
                  Some i))
            (Some 0) (entries_of w key v)
        in
        match last with
        | None | Some 0 -> redirect ()
        | Some i ->
          let h = { hkind = W (key, v); hs = w.now; he = -1; index = -1; value = v; known = false } in
          w.hist <- h :: w.hist;
          cl.cur <- Some h;
          cl.sent_at <- w.now;
          s.waiting <- (i, c.term, cl.cid, h) :: s.waiting;
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
  (* a lost disk: the server starts again empty, fresh, while the damaged and the lost stay a minority (a majority
     that lost what it acknowledged may have lost a committed entry: no rule can bring it back) *)
  Array.iter (fun s -> match s.core with Some c -> s.sound <- c.repair = 0 && not c.fresh | None -> ()) w.servers;
  let lost = Rng.int w.r w.n in
  let unsound = Array.fold_left (fun a s -> if s.id = lost || not s.sound then a + 1 else a) 0 w.servers in
  if Rng.chance w.r 0.0001 && unsound <= (w.n - 1) / 2 then begin
    let s = w.servers.(lost) in
    if s.core <> None then crash w s ~power:true;
    s.sim <- Sim_disk.create (Rng.split w.r);
    s.disk <- Sim_disk.disk s.sim;
    s.ckpt <- 0, [];
    s.sound <- false;
    count "disks lost";
    tr w "server %d loses its disk" s.id
  end;
  Array.iter
    (fun s ->
      if s.core <> None && Rng.chance w.r 0.0008 then crash w s ~power:(Rng.bool w.r);
      (* a clean stop of the leader: its leadership handed over first *)
      (match s.core with
       | Some c when c.role = Raft.Leader && s.stop_at = max_int && Rng.chance w.r 0.0006 ->
         if Raft.hand_over c (clock w s) then (count "handovers begun"; tr w "server %d hands over" s.id);
         s.stop_at <- w.now + (2 * election);
         guard w s (fun () -> run w s)
       | _ -> ());
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
        if s.core <> None && (w.now + 7 * s.id) mod 300 = 0 then checkpoint w s;
        if s.core <> None then copy_step w s;
        (* the clean stop's end: once this server no longer leads, or at its time *)
        match s.core with
        | Some c when s.stop_at <> max_int && (c.role <> Raft.Leader || w.now >= s.stop_at) ->
          count (if c.role <> Raft.Leader then "handovers done" else "handovers given up");
          tr w "server %d stops cleanly (%s)" s.id (if c.role <> Raft.Leader then "handed over" else "as the leader");
          crash w s ~power:false
        | _ -> ()
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
  (* the committed log's writes, at the entry that makes each whole *)
  let log =
    let raw = final_log w in
    let seqs = Hashtbl.create 2 in
    Array.mapi
      (fun i e ->
        match e with
        | Some (tm, d) -> (
          match Cluster.decode_entry d with
          | Some e -> (
            match e, Cluster.track seqs (i + 1) tm e with
            | Frame (_, f), _ -> Some (tm, f)
            | Piece _, Some q ->
              let b = Bytes.create q.stotal in
              for j = q.sfirst to i + 1 do
                match raw.(j - 1) with
                | Some (_, dj) -> (match Cluster.decode_entry dj with Some (Piece p) -> Bytes.blit p.data 0 b p.off (Bytes.length p.data) | _ -> ())
                | None -> ()
              done;
              Some (tm, b)
            | _ -> None)
          | None -> None)
        | None -> None)
      raw
  in
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
    let abstain = Array.fold_left (fun a s -> match s.core with Some c when c.repair > 0 || c.fresh -> a + 1 | None -> a + 1 | _ -> a) 0 w.servers in
    if abstain >= w.n / 2 + 1 then count "blocked: a majority damaged"
    else fail w "the cluster did not settle within 20 s after the faults stopped%s" (if behind then " (a follower behind the leader's log start)" else "")
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
          kv = []; applied = 0; ckpt = 0, []; paused_until = 0; up_at = 0; waiting = []; copying = None; fetch_after = 0; lives = 0; sound = true; seqs = Hashtbl.create 2; held_upto = 0; stop_at = max_int })
  in
  let w =
    { seed; r; n; servers; net = []; cut = Array.make_matrix n n false; now = 0; leaders = Hashtbl.create 16; applied_at = Hashtbl.create 256;
      hist = []; clients = Array.init 3 (fun cid -> { cid; target = Rng.int r n; cur = None; sent_at = 0; next_at = 0 });
      loss = float (Rng.int r 20) /. 100.; dup = float (Rng.int r 10) /. 100.; maxdelay = 1 + Rng.int r 20; faults = true; serial = 0;
      floor_ms = 200 + Rng.int r 2000 }
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
