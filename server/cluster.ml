(* A Raft cluster's server (design 8.2; docs/book/server.md, "A cluster of three"): the threads and the wire around
   the pure Raft of server/raft.ml, its log on the disk (server/raftlog.ml), and the databases as its state machine.

   One log for the cluster (design choice 9): an entry is the no-op of a new term, or a frame of a database's journal,
   whole, marked with the database's id. A leader's database proposes each frame it writes (Engine.propose: the
   syncer waits for the commit) and writes it into its journal once committed, without an fsync (the Raft log holds
   it forced); every other committed frame is applied (Engine.Apply) by one thread, in the log's order, on every
   server. So a journal holds committed frames only, and nothing is ever taken back from a journal, a run or a view.

   Threads: a ticker (timeouts, heartbeats, every 10 ms), a disk thread (rounds of entries: one write and one fsync
   for every entry that came meanwhile; truncations), an apply thread, a sender a peer (one connection to it, mutual
   TLS, Raft's messages one way), a reader a connection from a peer. The core runs under one lock; effects are carried
   out in the order Raft gives them: the term and vote forced before any message after them leaves.

   A database's checkpoint each second forces its journal; the log's whole segments before what every journal holds
   forced and every peer holds (the floor: Raft) are removed. A peer the leader can no longer send entries to (they
   are before its log's start) takes a copy of the databases (server/catchup.ml), then starts again on it. *)

open Cepheus

let log fmt = Printf.ksprintf (fun s -> prerr_endline ("cepheus: " ^ s)) fmt

(* a cluster of 3 or more [[peer]] runs Raft; 1 is a single server, 2 a primary and its replica *)
let is_raft (cfg : Config.t) = List.length cfg.peers >= 3

(* times, in ms (tests make them small) *)
let election_ms = ref 500
let heartbeat_ms = ref 50
let tick_ms = 10

(* a peer silent this long no longer holds the log's start back: it takes a copy of the databases when it comes back
   (5 minutes: a restart, a reboot, an upgrade fit; a dead machine does not make the log grow without end) *)
let floor_ms = ref 300_000

(* set once a copy of the databases is committed here: the server stops, and bin/main.ml starts it again (exec) *)
let restart = Atomic.make false

(* a frame of a Raft cluster is at most this long: one wire frame carries it *)
let frame_limit = 8 lsl 20

let now () = Fdpass.monotonic_ms ()

(* a database's id in a Raft cluster: the same on every server, from the cluster's id and the database's name *)
let database_id cluster name = String.sub (Digest.BLAKE128.to_hex (Digest.BLAKE128.string (cluster ^ "\000" ^ name))) 0 16

(* ---- entries ---- *)

type entry = Noop | Frame of string * Bytes.t  (* a database's id, its journal's frame whole *)

let encode_frame id frame =
  let b = Bytes.create (17 + Bytes.length frame) in
  Bytes.set b 0 '\001';
  Bytes.blit_string id 0 b 1 16;
  Bytes.blit frame 0 b 17 (Bytes.length frame);
  b

let decode_entry d =
  let n = Bytes.length d in
  if n = 0 then Some Noop else if n > 17 && Bytes.get d 0 = '\001' then Some (Frame (Bytes.sub_string d 1 16, Bytes.sub d 17 (n - 17))) else None

(* ---- messages ---- *)

let put_msg b (m : Raft.msg) data =
  let v = Codec.put_varint b and bool x = Codec.put_varint b (if x then 1 else 0) in
  match m with
  | Pre_vote x -> Buffer.add_uint8 b 1; v x.term; v x.last_index; v x.last_term
  | Pre_vote_reply x -> Buffer.add_uint8 b 2; v x.term; bool x.granted
  | Vote x -> Buffer.add_uint8 b 3; v x.term; v x.last_index; v x.last_term
  | Vote_reply x -> Buffer.add_uint8 b 4; v x.term; bool x.granted
  | Append x ->
    Buffer.add_uint8 b 5; v x.term; v x.seq; v x.prev_index; v x.prev_term; v x.commit; v x.floor;
    v (Array.length x.terms);
    Array.iteri (fun k tm -> v tm; v (Bytes.length data.(k)); Buffer.add_bytes b data.(k)) x.terms
  | Append_reply x -> Buffer.add_uint8 b 6; v x.term; v x.seq; bool x.ok; v x.index
  | Snap x -> Buffer.add_uint8 b 7; v x.term; v x.seq; v x.index; v x.index_term; v x.commit; v x.floor
  | Ask -> Buffer.add_uint8 b 8
  | State x -> Buffer.add_uint8 b 9; v x.term; v x.last_index; bool x.fresh

let max_entries = 1 lsl 20

(* a message from a peer, checked as it is decoded (Codec.Short when it does not decode) *)
let get_msg (r : Codec.reader) : Raft.msg * Bytes.t array =
  let v () = Codec.get_varint r in
  let bool () = match v () with 0 -> false | 1 -> true | _ -> raise Codec.Short in
  if r.pos >= r.stop then raise Codec.Short;
  let tag = Bytes.get_uint8 r.buf r.pos in
  r.pos <- r.pos + 1;
  match tag with
  | 1 -> let term = v () in let last_index = v () in let last_term = v () in Pre_vote { term; last_index; last_term }, [||]
  | 2 -> let term = v () in let granted = bool () in Pre_vote_reply { term; granted }, [||]
  | 3 -> let term = v () in let last_index = v () in let last_term = v () in Vote { term; last_index; last_term }, [||]
  | 4 -> let term = v () in let granted = bool () in Vote_reply { term; granted }, [||]
  | 5 ->
    let term = v () in
    let seq = v () in
    let prev_index = v () in
    let prev_term = v () in
    let commit = v () in
    let floor = v () in
    let n = v () in
    if n > max_entries || n > r.stop - r.pos then raise Codec.Short;
    let terms = Array.make n 0 and data = Array.make n Bytes.empty in
    for k = 0 to n - 1 do
      terms.(k) <- v ();
      let len = v () in
      if len > r.stop - r.pos then raise Codec.Short;
      data.(k) <- Bytes.sub r.buf r.pos len;
      r.pos <- r.pos + len
    done;
    Append { term; seq; prev_index; prev_term; terms; sizes = Array.map Bytes.length data; commit; floor }, data
  | 6 -> let term = v () in let seq = v () in let ok = bool () in let index = v () in Append_reply { term; seq; ok; index }, [||]
  | 7 ->
    let term = v () in
    let seq = v () in
    let index = v () in
    let index_term = v () in
    let commit = v () in
    let floor = v () in
    Snap { term; seq; index; index_term; commit; floor }, [||]
  | 8 -> Ask, [||]
  | 9 -> let term = v () in let last_index = v () in let fresh = bool () in State { term; last_index; fresh }, [||]
  | _ -> raise Codec.Short

(* ---- the node ---- *)

type db = { name : string; id : string; live : Engine.live }

type op =
  | Put of { gen : int; first : int; entries : (int * Bytes.t) list; commit : int }
      (* [commit]: the commit index when the entries were given, the round's hint: it covers only entries that no
         truncation can remove (the commit index of a later moment may name entries that replaced these) *)
  | Trunc of { gen : int; at : int; prev_term : int }

type out = {
  peer : Config.peer;
  oq : (Raft.msg * float) Queue.t;
  om : Mutex.t;
  oc : Condition.t;
  mutable link : Replica.link option;
  mutable thread : Thread.t option;
}

type t = {
  cfg : Config.t;
  names : string array;  (* the peers, by Raft's index *)
  me : int;
  m : Mutex.t;  (* the core *)
  core : Raft.t;
  rlog : Raftlog.t;
  dbs : (string, db) Hashtbl.t;  (* by id *)
  mutable db_list : db list;
  (* proposals waiting for their commit: by index, with the term they were proposed in *)
  waiters : (int, int * (unit, Engine.error) result option ref) Hashtbl.t;
  wc : Condition.t;
  (* the disk *)
  dq : op Queue.t;
  dm : Mutex.t;
  dc : Condition.t;
  pend : (int, int * Bytes.t) Hashtbl.t;  (* entries given to the disk, not yet in the log: for the senders *)
  pm : Mutex.t;
  (* the state machine *)
  applied : int Atomic.t;
  ac : Condition.t;  (* the apply thread waits under m *)
  serve_until : int Atomic.t;  (* reads and writes served here until this time (ms): the lease of a ready leader *)
  outs : out array;
  stopping : bool Atomic.t;
  mutable threads : Thread.t list;
  mutable failed : string option;  (* the disk failed, or a frame did not apply: the server stops *)
  streams : (string, Replica.link list) Hashtbl.t;  (* the peers' connections to this server, by name *)
  sm : Mutex.t;
  mutable damage : string option;
  fetching : bool Atomic.t;  (* a copy of the databases is being taken from a peer *)
  mutable fetch_after : float;  (* the next try after a refused or broken one (under sm) *)
  mutable fetch_wait : float;
  mutable fetch_note : string;  (* what the last try did, for cepheus status *)
}

let fail t m =
  Mutex.protect t.sm (fun () -> if t.failed = None then (t.failed <- Some m; log "%s" m))

let state t =
  let c = t.core in
  { Raftlog.term = c.term; vote = (if c.vote >= 0 then t.names.(c.vote) else ""); repair = c.repair }

let disk_push t op = Mutex.protect t.dm (fun () -> Queue.push op t.dq; Condition.signal t.dc)

(* the proposals up to index [upto] resolved: committed if the committed entry there is theirs (the same term: two
   leaders never share a term), else replaced by another leader's (Error: applied once or not at all) *)
let resolve_waiters t upto =
  let hit = ref false in
  Hashtbl.filter_map_inplace
    (fun i (tm, r) ->
      if i <= upto then begin
        r := Some (if i <= t.core.commit && Raft.term_at t.core i = tm then Ok () else Error Engine.not_leader);
        hit := true;
        None
      end
      else Some (tm, r))
    t.waiters;
  if !hit then Condition.broadcast t.wc

let ready_locked t = Raft.ready t.core && Atomic.get t.applied >= t.core.noop

(* under [t.m]: until when this server serves (a ready leader's lease), for [lead]'s fast path *)
let refresh t = Atomic.set t.serve_until (if ready_locked t then Raft.lease_until t.core (now ()) else 0)

(* carries out Raft's effects, in order, under [t.m]; [msg]: the terms and bytes of the Append just received *)
let rec run ?(msg = ([||], [||])) t =
  run_effects ~msg t;
  refresh t

and run_effects ~msg t =
  List.iter
    (fun (e : Raft.action) ->
      match e with
      | Save -> (
        match Raftlog.save_state t.rlog (state t) with
        | () -> ()
        | exception Disk.Io m -> fail t ("the Raft state could not be written: " ^ m))
      | Truncate i ->
        Mutex.protect t.pm (fun () -> Hashtbl.filter_map_inplace (fun j x -> if j >= i then None else Some x) t.pend);
        disk_push t (Trunc { gen = t.core.gen; at = i; prev_term = Raft.term_at t.core (i - 1) })
      | Store { first; skip; count } ->
        let terms, data = msg in
        let entries = List.init count (fun k -> terms.(skip + k), data.(skip + k)) in
        Mutex.protect t.pm (fun () -> List.iteri (fun k x -> Hashtbl.replace t.pend (first + k) x) entries);
        disk_push t (Put { gen = t.core.gen; first; entries; commit = t.core.commit })
      | Send (k, m) ->
        let o = t.outs.(k) in
        Mutex.protect o.om (fun () ->
            (* a peer that does not take its messages: the oldest go (Raft sends again what matters) *)
            if Queue.length o.oq >= 4096 then Queue.clear o.oq;
            Queue.push (m, Unix.gettimeofday ()) o.oq;
            Condition.signal o.oc)
      | Commit i ->
        resolve_waiters t i;
        Condition.broadcast t.ac
      | Lead ->
        (* the no-op of this term: stored (and read by the senders) as any entry *)
        let x = t.core.term, Bytes.empty in
        Mutex.protect t.pm (fun () -> Hashtbl.replace t.pend t.core.noop x);
        disk_push t (Put { gen = t.core.gen; first = t.core.noop; entries = [ x ]; commit = t.core.commit });
        log "leader of term %d (its first entry is %d)" t.core.term t.core.noop
      | Unlead ->
        (* every proposal resolved: those committed with their own entry, the others not *)
        resolve_waiters t max_int;
        log "no longer the leader (term %d)" t.core.term
      | Fetch k -> start_fetch t k)
    (Raft.drain t.core)

(* a copy of the databases from peer k (it leads), unless one is under way or the last one failed lately; on its
   commit the server stops and starts again on it *)
and start_fetch t k =
  let go = Mutex.protect t.sm (fun () -> Unix.gettimeofday () >= t.fetch_after) && Atomic.compare_and_set t.fetching false true in
  if go then begin
    let peer = List.nth t.cfg.peers k in
    log "Raft: this server's log ends before %s's log start: it takes a copy of the databases from it" peer.pname;
    ignore
      (Thread.create
         (fun () ->
           let outcome =
             match Replica.connect t.cfg peer with
             | Error m -> Catchup.Refused (Printf.sprintf "the copy from %s: %s" peer.pname m)
             | Ok l when l.pv < 3 -> Replica.close_link l; Catchup.Refused (peer.pname ^ " speaks peer protocol 2, which has no copy: upgrade it")
             | Ok l ->
               Fun.protect ~finally:(fun () -> Replica.close_link l) (fun () ->
                   Replica.timeouts l.fd 30.0;
                   let id_of name = database_id t.cfg.id name in
                   let published name =
                     match List.find_opt (fun d -> d.name = name) t.db_list with Some d -> (Atomic.get d.live.e.published).group | None -> 0
                   in
                   let decide x term = Mutex.protect t.m (fun () -> let r = Raft.install t.core ~index:x ~term in run t; r) in
                   Catchup.fetch t.cfg ~source:peer.pname ~id_of ~published ~decide ~send:(Replica.send l ~kind:Replica.k_copy)
                     ~next:(fun () -> Replica.next_frame l))
           in
           let note m = Mutex.protect t.sm (fun () -> t.fetch_note <- m) in
           (match outcome with
            | Catchup.Installed x ->
              note (Printf.sprintf "a copy at index %d from %s, installed at the restart" x peer.pname);
              log "Raft: the copy of %s's databases at index %d is whole and checked: this server starts again on it" peer.pname x;
              Atomic.set restart true;
              Unix.kill (Unix.getpid ()) Sys.sigterm
            | Catchup.Dropped x ->
              note (Printf.sprintf "a copy at index %d from %s, not needed (this log holds its entry)" x peer.pname);
              log "Raft: the copy of %s's databases at index %d is not needed: this log holds its entry" peer.pname x
            | Catchup.Refused m ->
              note m;
              log "Raft: %s" m;
              Mutex.protect t.sm (fun () ->
                  t.fetch_wait <- min 30. (max 1. (2. *. t.fetch_wait));
                  t.fetch_after <- Unix.gettimeofday () +. t.fetch_wait));
           (match outcome with Catchup.Refused _ -> () | _ -> Mutex.protect t.sm (fun () -> t.fetch_wait <- 0.));
           Atomic.set t.fetching false)
         ())
  end

let entry t i =
  match Mutex.protect t.pm (fun () -> Hashtbl.find_opt t.pend i) with
  | Some x -> Some x
  | None -> Raftlog.read t.rlog i

(* ---- the disk thread ---- *)

let disk_loop t () =
  let go = ref true in
  while !go do
    let ops =
      Mutex.protect t.dm (fun () ->
          while Queue.is_empty t.dq && not (Atomic.get t.stopping) do Condition.wait t.dc t.dm done;
          let l = List.of_seq (Queue.to_seq t.dq) in
          Queue.clear t.dq;
          l)
    in
    if ops = [] then go := false
    else
      (* consecutive puts of one generation: one round *)
      let rec merge acc = function
        | Put a :: Put b :: rest when a.gen = b.gen && b.first = a.first + List.length a.entries ->
          merge acc (Put { a with entries = a.entries @ b.entries; commit = max a.commit b.commit } :: rest)
        | x :: rest -> merge (x :: acc) rest
        | [] -> List.rev acc
      in
      List.iter
        (fun op ->
          if t.failed = None then
            match op with
            | Put { gen; first; entries; commit } -> (
              match Raftlog.append t.rlog ~first ~commit entries with
              | () ->
                let last = first + List.length entries - 1 in
                Mutex.protect t.pm (fun () ->
                    List.iteri
                      (fun k (_, d) -> match Hashtbl.find_opt t.pend (first + k) with Some (_, d') when d' == d -> Hashtbl.remove t.pend (first + k) | _ -> ())
                      entries);
                Mutex.protect t.m (fun () -> Raft.persisted t.core ~gen last; run t)
              | exception Disk.Io m -> fail t ("the Raft log could not be written: " ^ m)
              | exception Invalid_argument m -> fail t ("the Raft log: " ^ m))
            | Trunc { at; prev_term; _ } -> (
              match Raftlog.truncate t.rlog at ~prev_term with
              | () -> ()
              | exception (Disk.Io m | Raftlog.Damaged m) -> fail t ("the Raft log could not be cut: " ^ m)))
        (merge [] ops)
  done

(* ---- the senders ---- *)

let close_out o = Option.iter Replica.close_link o.link; o.link <- None

let open_out t k o =
  match Replica.connect t.cfg o.peer with
  | Error m -> Error m
  | Ok l -> (
    match Replica.send l ~kind:Replica.k_raft (Buffer.create 1); Replica.expect l Replica.k_raft with
    | Ok _ -> Replica.timeouts l.fd 5.0; Ok l
    | Error (c, m) -> Replica.close_link l; Error (c ^ ": " ^ m)
    | exception (Replica.Broken m) -> Replica.close_link l; Error m
    | exception Codec.Short -> Replica.close_link l; Error "a bad reply"
    | exception e -> Replica.close_link l; ignore k; Error (Printexc.to_string e))

(* an Append's entries' bytes, if the log still holds them as the message says (a follower's log may have been cut) *)
let append_data t (m : Raft.msg) =
  match m with
  | Append x -> (
    match
      Array.mapi
        (fun j tm ->
          match entry t (x.prev_index + 1 + j) with
          | Some (tm', d) when tm' = tm -> d
          | _ -> raise Exit)
        x.terms
    with
    | d -> Some d
    | exception Exit -> None
    | exception Raftlog.Damaged m -> fail t m; None)
  | _ -> Some [||]

let send_loop t k o () =
  let said = ref "" and pause = ref 0.05 in
  while not (Atomic.get t.stopping) do
    let next =
      Mutex.protect o.om (fun () ->
          while Queue.is_empty o.oq && not (Atomic.get t.stopping) do Condition.wait o.oc o.om done;
          Queue.take_opt o.oq)
    in
    match next with
    | None -> ()
    | Some (m, at) ->
      (* a message older than an election timeout is stale: dropped *)
      if Unix.gettimeofday () -. at < float !election_ms /. 1000. then begin
        (match o.link with
         | Some _ -> ()
         | None -> (
           match open_out t k o with
           | Ok l -> o.link <- Some l; pause := 0.05; if !said <> "" then (log "Raft: %s reached again" o.peer.pname; said := "")
           | Error e ->
             if e <> !said then (said := e; log "Raft: %s unreachable: %s" o.peer.pname e);
             Mutex.protect t.m (fun () -> Raft.unreachable t.core k);
             Mutex.protect o.om (fun () -> Queue.clear o.oq);
             Thread.delay !pause;
             pause := min 1.0 (!pause *. 2.)));
        match o.link, append_data t m with
        | Some l, _ when l.pv < 3 && (match m with Raft.Ask | State _ -> true | _ -> false) -> ()  (* protocol 2 has neither *)
        | Some l, Some data -> (
          let b = Buffer.create 256 in
          (* a peer of protocol 2 has no Snap: the probe at the leader's start is an Append there *)
          let m =
            match m with
            | Raft.Snap x when l.pv < 3 ->
              Raft.Append { term = x.term; seq = x.seq; prev_index = x.index; prev_term = x.index_term; terms = [||]; sizes = [||]; commit = x.commit; floor = x.floor }
            | m -> m
          in
          put_msg b m data;
          match Replica.send l ~kind:Replica.k_msg b with
          | () -> ()
          | exception Replica.Broken e ->
            close_out o;
            if e <> !said then (said := e; log "Raft: the connection to %s broke: %s" o.peer.pname e);
            Mutex.protect t.m (fun () -> Raft.unreachable t.core k))
        | _ -> ()
      end
  done;
  close_out o

(* ---- a peer's stream to this server ---- *)

let serve_stream t name (l : Replica.link) =
  match Array.find_index (( = ) name) t.names with
  | None -> Replica.send_err l "denied" "not a peer of this cluster"
  | Some k ->
    (* a peer keeps two streams at most: an older one goes (a reconnection) *)
    Mutex.protect t.sm (fun () ->
        let old = Option.value (Hashtbl.find_opt t.streams name) ~default:[] in
        (match old with _ :: _ :: _ -> List.iter Replica.shut (List.tl old) | _ -> ());
        Hashtbl.replace t.streams name (l :: (match old with x :: _ -> [ x ] | [] -> [])));
    Replica.send l ~kind:Replica.k_raft (Buffer.create 1);
    (* the stream lives as long as the peer: no read timeout, TCP's keepalive for a vanished peer *)
    Unix.setsockopt_float l.fd Unix.SO_RCVTIMEO 0.;
    Unix.setsockopt l.fd Unix.SO_KEEPALIVE true;
    (try
       while not (Atomic.get t.stopping) do
         match Replica.next_frame l with
         | kind, _, r when kind = Replica.k_msg ->
           let m, data = get_msg r in
           if r.pos <> r.stop then raise Codec.Short;
           let terms = match m with Append x -> x.terms | _ -> [||] in
           Mutex.protect t.m (fun () -> Raft.receive t.core (now ()) k m; run ~msg:(terms, data) t)
         | _ -> raise (Replica.Broken "a frame that is not a Raft message")
       done
     with
     | Replica.Broken _ -> ()
     | Codec.Short -> log "Raft: %s sent a message that does not decode: its stream is closed" name);
    Mutex.protect t.sm (fun () ->
        Hashtbl.replace t.streams name (List.filter (fun x -> x != l) (Option.value (Hashtbl.find_opt t.streams name) ~default:[])))

(* ---- a peer's copy of the databases (server/catchup.ml) ---- *)

(* the databases at this server's applied index, for the peer [name]; that index pinned in the core meanwhile, so
   that the entries after it stay for the peer *)
let serve_copy t name (l : Replica.link) =
  match Array.find_index (( = ) name) t.names with
  | None -> Replica.send_err l "denied" "not a peer of this cluster"
  | Some _ ->
    let x = ref 0 in
    let pin () = Raft.pin t.core ~index:!x ~until:(now () + !Catchup.pin_ms) in
    let start () =
      Mutex.protect t.m (fun () ->
          x := Atomic.get t.applied;
          pin ();
          !x, Raft.term_at t.core !x)
    in
    Replica.timeouts l.fd 30.0;
    log "Raft: %s takes a copy of the databases" name;
    (try
       Catchup.serve ~dbs:(List.map (fun d -> d.name, d.live.e.dir) t.db_list) ~start ~renew:(fun () -> Mutex.protect t.m pin)
         ~send:(Replica.send l ~kind:Replica.k_copy) ~error:(Replica.send_err l)
     with Replica.Broken m -> log "Raft: the copy for %s stopped: %s" name m)

(* ---- the ticker ---- *)

let tick_loop t () =
  while not (Atomic.get t.stopping) do
    Thread.delay (float tick_ms /. 1000.);
    Mutex.protect t.m (fun () -> Raft.tick t.core (now ()); run t)
  done

(* ---- the state machine ---- *)

(* the frame of a committed entry into its database (another leader's, or this one's of an earlier term) *)
let apply_frame t id frame =
  match Hashtbl.find_opt t.dbs id with
  | None -> Error (Printf.sprintf "a committed frame of database id %s, which this server's cluster.toml does not hold" id)
  | Some d -> (
    match Journal.frame_parts frame with
    | None -> Error (Printf.sprintf "database %s: a committed frame that does not check" d.name)
    | Some (first, count, body) -> (
      let r = { Engine.w = ([], 0, ""); res = None; rm = Mutex.create (); rc = Condition.create () } in
      if not (Engine.submit d.live (Engine.Apply (r, { first; count; body; len = Bytes.length body }))) then Error "the database is closed"
      else begin
        Mutex.lock r.rm;
        while r.res = None do Condition.wait r.rc r.rm done;
        Mutex.unlock r.rm;
        match Option.get r.res with Ok _ -> Ok () | Error e -> Error (Printf.sprintf "database %s: a committed frame did not apply: %s" d.name (Engine.message e))
      end))

(* a frame this leader proposed in its term: its syncer writes it; the log may be cut past it only once it is in the
   journal *)
let await_own t id frame =
  match Hashtbl.find_opt t.dbs id, Journal.frame_parts frame with
  | Some d, Some (first, count, _) ->
    while (Atomic.get d.live.e.published).group < first + count - 1 && d.live.e.stopped = None && not (Atomic.get t.stopping) do
      Thread.delay 0.0005
    done
  | _ -> ()

let apply_loop t () =
  while not (Atomic.get t.stopping) && t.failed = None do
    let upto =
      Mutex.protect t.m (fun () ->
          while t.core.commit <= Atomic.get t.applied && not (Atomic.get t.stopping) do Condition.wait t.ac t.m done;
          t.core.commit)
    in
    let i = ref (Atomic.get t.applied + 1) in
    while !i <= upto && t.failed = None && not (Atomic.get t.stopping) do
      (match entry t !i with
       | None -> fail t (Printf.sprintf "the Raft log lacks committed entry %d" !i)
       | Some (term, d) -> (
         match decode_entry d with
         | None -> fail t (Printf.sprintf "committed entry %d is of an unknown kind" !i)
         | Some Noop -> ()
         | Some (Frame (id, frame)) ->
           let own = Mutex.protect t.m (fun () -> t.core.role = Raft.Leader && term = t.core.term) in
           if own then await_own t id frame
           else match apply_frame t id frame with Ok () -> () | Error m -> fail t m)
         | exception Raftlog.Damaged m -> fail t m);
      if t.failed = None then Atomic.set t.applied !i;
      incr i
    done;
    Mutex.protect t.m (fun () -> refresh t; Condition.broadcast t.wc)
  done

(* ---- what the server asks ---- *)

(* None: this server serves reads and writes now (the leader, ready, under its lease); else the code, why, and the
   leader's address for programs ("" if none is known) *)
let lead t () =
  if now () < Atomic.get t.serve_until then None
  else
  Mutex.protect t.m (fun () ->
      let c = t.core in
      if c.role = Raft.Leader then
        if ready_locked t && now () < Raft.lease_until c (now ()) then None
        else Some ("no_leader", "the leader is not ready yet (its first entry is being committed, or a majority did not answer lately): try again", "")
      else if c.leader >= 0 then begin
        let p = List.find (fun (p : Config.peer) -> p.pname = t.names.(c.leader)) t.cfg.peers in
        let a = Config.client_address t.cfg p in
        Some ("not_leader", Printf.sprintf "this server follows the leader %s, at %s: ask it" p.pname a, a)
      end
      else Some ("no_leader", "no leader now (an election is under way): try again", ""))

(* a database's frame, proposed: Ok once committed (the syncer then writes and publishes it) *)
let propose t id _first _count frame =
  let data = encode_frame id frame in
  Mutex.protect t.m (fun () ->
      if t.failed <> None || not (ready_locked t) then Error Engine.not_leader
      else
        match Raft.propose t.core (now ()) (Bytes.length data) with
        | None -> Error Engine.not_leader
        | Some i ->
          let r = ref None in
          Hashtbl.replace t.waiters i (t.core.term, r);
          Mutex.protect t.pm (fun () -> Hashtbl.replace t.pend i (t.core.term, data));
          disk_push t (Put { gen = t.core.gen; first = i; entries = [ t.core.term, data ]; commit = t.core.commit });
          run t;
          while !r = None do Condition.wait t.wc t.m done;
          Option.get !r)

(* ---- start, recovery, stop ---- *)

(* a database's frames the log holds for recovery (Engine.open_ ~raft): those known committed (up to the log's commit
   hint, or within the newest run's groups) written again, and the journal cut where the others begin *)
let frames_for rlog ~hint id ~snapshot =
  let copy = ref [] and cut = ref None in
  Raftlog.iter rlog ~from:1 (fun i _ d ->
      match decode_entry d with
      | Some (Frame (x, frame)) when x = id && !cut = None -> (
        match Journal.frame_parts frame with
        | Some (first, count, _) -> if i <= hint || first + count - 1 <= snapshot then copy := frame :: !copy else cut := Some first
        | None -> raise (Raftlog.Damaged (Printf.sprintf "entry %d holds a frame that does not check" i)))
      | _ -> ());
  List.rev !copy, !cut

type opened = { rlog : Raftlog.t; rec_ : Raftlog.recovered }

(* the Raft log and state of a data directory, recovered (before the databases open) *)
let recover (cfg : Config.t) =
  let dir = Filename.concat cfg.data "raft" in
  let secure p = try Unix.chmod p (if Sys.is_directory p then 0o700 else 0o600) with Unix.Unix_error _ | Sys_error _ -> () in
  match
    (* a copy of the databases taken from a peer: installed before anything reads the log or the databases *)
    if Sys.file_exists dir then Catchup.at_start cfg else Ok ()
  with
  | Error m -> Error m
  | Ok () ->
  match Raftlog.open_ ~secure Disk.real dir ~cluster:cfg.id with
  | rlog, rec_ ->
    Option.iter (fun m -> log "%s" m) rec_.damage;
    Ok { rlog; rec_ }
  | exception Raftlog.Damaged m -> Error m
  | exception Disk.Io m -> Error m

let create (cfg : Config.t) (o : opened) (dbs : db list) =
  let names = Array.of_list (List.map (fun (p : Config.peer) -> p.pname) cfg.peers) in
  let me = Option.get (Array.find_index (( = ) cfg.me) names) in
  let r = o.rec_ in
  let vote = match Array.find_index (( = ) r.st.vote) names with Some k -> k | None -> -1 in
  let rng = Rng.make (Int64.to_int (String.get_int64_le (Tokens.random 8) 0)) in
  let core =
    Raft.make ~me ~n:(Array.length names) ~election_ms:!election_ms ~heartbeat_ms:!heartbeat_ms ~floor_ms:!floor_ms ~rng ~now:(now ())
      ~term:r.st.term ~vote ~repair:r.st.repair ~fresh:r.fresh ~start:r.start ~prev_term:r.prev_term ~terms:r.terms ~sizes:r.sizes ~commit:r.commit
  in
  let t =
    { cfg; names; me; m = Mutex.create (); core; rlog = o.rlog; dbs = Hashtbl.create 8; db_list = dbs; waiters = Hashtbl.create 64;
      wc = Condition.create (); dq = Queue.create (); dm = Mutex.create (); dc = Condition.create (); pend = Hashtbl.create 64;
      pm = Mutex.create (); applied = Atomic.make (core.start - 1); ac = Condition.create ();
      serve_until = Atomic.make 0;
      outs = Array.mapi (fun _ p -> { peer = p; oq = Queue.create (); om = Mutex.create (); oc = Condition.create (); link = None; thread = None }) (Array.of_list cfg.peers);
      stopping = Atomic.make false; threads = []; failed = None; streams = Hashtbl.create 4; sm = Mutex.create (); damage = r.damage;
      fetching = Atomic.make false; fetch_after = 0.; fetch_wait = 0.; fetch_note = "" }
  in
  List.iter (fun d -> Hashtbl.replace t.dbs d.id d; d.live.propose <- propose t d.id) dbs;
  (* entries the recovery copied into the journals (up to the hint) are applied; the rest waits for the commit *)
  Atomic.set t.applied (max (core.start - 1) (min core.commit (Raftlog.next o.rlog - 1)));
  t

let start t =
  let th f = Thread.create f () in
  t.threads <- [ th (disk_loop t); th (apply_loop t); th (tick_loop t) ];
  Array.iteri (fun k o -> if k <> t.me then o.thread <- Some (th (send_loop t k o))) t.outs

(* every second: each journal forced, then the log's segments that every journal holds forced (and every peer
   holds, on a leader) removed *)
let checkpoint t =
  if t.failed = None then begin
    let a = Atomic.get t.applied in
    match List.iter (fun d -> Journal.checkpoint d.live.e.journal) t.db_list with
    | exception Disk.Io m -> fail t ("a journal could not be forced: " ^ m)
    | () ->
      let upto =
        Mutex.protect t.m (fun () ->
            let c = t.core in
            min (a + 1) (min (c.commit + 1) (min (c.persisted + 1) (Raft.floor c (now ()) + 1))))
      in
      match Raftlog.cut_before t.rlog upto with
      | () -> Mutex.protect t.m (fun () -> Raft.compact t.core (min upto (Raftlog.first t.rlog)))
      | exception Disk.Io m -> fail t ("the Raft log's start could not be cut: " ^ m)
  end

let failed t = Mutex.protect t.sm (fun () -> t.failed)

let stop t =
  Atomic.set t.stopping true;
  Mutex.protect t.m (fun () ->
      Hashtbl.iter (fun _ (_, r) -> if !r = None then r := Some (Error Engine.not_leader)) t.waiters;
      Hashtbl.reset t.waiters;
      Condition.broadcast t.wc;
      Condition.broadcast t.ac);
  Mutex.protect t.dm (fun () -> Condition.broadcast t.dc);
  Array.iter (fun o -> Mutex.protect o.om (fun () -> Condition.broadcast o.oc); Option.iter Replica.shut o.link) t.outs;
  Mutex.protect t.sm (fun () -> Hashtbl.iter (fun _ ls -> List.iter Replica.shut ls) t.streams);
  List.iter Thread.join t.threads;
  Array.iter (fun o -> Option.iter Thread.join o.thread) t.outs;
  Raftlog.close t.rlog

(* what cepheus status says *)
let status t =
  Mutex.protect t.m (fun () ->
      let c = t.core in
      let role = match c.role with Raft.Leader -> "leader" | Follower -> "follower" | Pre_candidate -> "pre-candidate" | Candidate -> "candidate" in
      [ "raft.role", role; "raft.term", string_of_int c.term; "raft.leader", (if c.leader >= 0 then t.names.(c.leader) else "none");
        "raft.ready", string_of_bool (ready_locked t);
        "raft.commit", string_of_int c.commit; "raft.applied", string_of_int (Atomic.get t.applied);
        "raft.log", Printf.sprintf "%d to %d" c.start (Raft.last_index c); "raft.forced", string_of_int c.persisted ]
      @ (if c.repair > 0 then [ "raft.repair", Printf.sprintf "damaged log: no vote until entries up to %d come from a leader" c.repair ] else [])
      @ (if Atomic.get t.fetching then [ "raft.copy", Printf.sprintf "taking a copy of the databases (%d bytes so far)" (Atomic.get Catchup.received) ]
         else match Mutex.protect t.sm (fun () -> t.fetch_note) with "" -> [] | m -> [ "raft.copy", m ])
      @ (match t.failed with Some m -> [ "raft.failed", m ] | None -> [])
      @
      if c.role = Raft.Leader then
        List.concat
          (List.mapi
             (fun k (p : Raft.peer) ->
               if k = t.me then [] else [ "raft.peer." ^ t.names.(k), Printf.sprintf "match %d, next %d%s" p.matched p.next (if p.probing then ", probing" else "") ])
             (Array.to_list c.peers))
      else [])
