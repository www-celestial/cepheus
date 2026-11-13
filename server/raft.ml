(* Raft, as a pure state machine: no thread, no clock, no file, no socket of its own. The server (Cluster) and the
   simulation (test/raft_sim.ml) feed it the same inputs (a tick with the time, a message from a peer, a proposal,
   the disk's word that entries are forced) and carry out the same effects it asks for, in order: the term and vote
   made durable before any message after it leaves, entries stored, messages sent, the commit index announced. So the
   code the simulation checks under faults is the server's.

   The algorithm is Ongaro and Ousterhout's (USENIX ATC 2014, Figure 2), with what spec/Raft.tla models and checks:
   - Pre-Vote (Ongaro's thesis, 9.6): a server whose election timeout passed asks for pre-votes for its next term, its
     own term unchanged, and stands for election only with a majority of them;
   - stickiness (thesis 4.2.3): a server that heard from a leader within the minimum election timeout, or started
     less than that ago, grants no vote, pre or real, and takes no term from a vote request; a leader grants none;
   - CheckQuorum (thesis 6.2): a leader that heard from no majority within an election timeout steps down;
   - the no-op of a new term (Raft 8), and a commit counted only on an entry of the leader's term (Raft 5.4.2);
   - entries acknowledged only once forced ([persisted], apart from the last index);
   - a lease for reads on the leader (thesis 6.4.1): from the time the newest round of heartbeats a majority answered
     was sent, for 9/10 of the minimum election timeout;
   - the 2018 rule (Alagappan et al., FAST 2018; design 8.5): a server with [repair] > 0 found its log damaged; it
     stores and acknowledges what a leader sends, but neither votes nor stands for election until it holds every
     entry up to [repair] from a leader whose commit index reaches it.

   Indexes start at 1. The log in memory is the terms (and sizes) of the entries from [start]; the entries' bytes are
   the transport's and the disk's (Raftlog). *)

open Cepheus

type role = Follower | Pre_candidate | Candidate | Leader

type msg =
  | Pre_vote of { term : int; last_index : int; last_term : int }  (** [term]: the candidate's next term *)
  | Pre_vote_reply of { term : int; granted : bool }
      (** granted: [term] is the one asked about; refused: the voter's own term, which a candidate behind takes *)
  | Vote of { term : int; last_index : int; last_term : int }
  | Vote_reply of { term : int; granted : bool }
  | Append of { term : int; seq : int; prev_index : int; prev_term : int; terms : int array; sizes : int array; commit : int; floor : int }
      (** entries prev_index + 1 ...: their terms and sizes here, their bytes beside (the transport's); [floor]: every
          server holds the leader's entries up to it, as far as the leader knows (no server cuts its log past it) *)
  | Append_reply of { term : int; seq : int; ok : bool; index : int }
      (** ok: the sender holds the leader's entries up to [index], forced; refused: retry after [index] *)

type action =
  | Save  (** the term, the vote or the repair mark changed: durable before any later effect *)
  | Truncate of int  (** the log's entries from this index on are dropped (never a committed one) *)
  | Store of { first : int; skip : int; count : int }
      (** the received Append's entries [skip, skip + count) are entries [first, first + count): to store *)
  | Send of int * msg
  | Commit of int  (** the commit index grew to this *)
  | Lead  (** this server became the leader: its no-op, at [noop], empty, is to store before any later effect *)
  | Unlead  (** it stopped being the leader *)

type peer = {
  mutable next : int;
  mutable matched : int;
  mutable probing : bool;  (* one Append at a time, until the follower's log is found *)
  mutable last_send : int;  (* ms *)
  mutable last_seq : int;  (* the newest Append sent: only its refusal makes a new probe (a stale or duplicated one
                              would multiply them) *)
  sent : (int * int) Queue.t;  (* (seq, ms) of the Appends sent in this term, not yet answered *)
  mutable acked_at : int;  (* when the newest answered Append was sent: the lease *)
  mutable contact : int;  (* when this peer last answered (the election, at first): CheckQuorum *)
}

type t = {
  me : int;
  n : int;
  election_ms : int;
  heartbeat_ms : int;
  rng : Rng.t;
  (* durable *)
  mutable term : int;
  mutable vote : int;  (* -1: none in this term *)
  mutable repair : int;
  (* the log *)
  mutable start : int;  (* the first index held (entries before it are committed and applied) *)
  mutable prev_term : int;  (* the term of entry start - 1 *)
  mutable terms : int array;
  mutable sizes : int array;
  mutable len : int;
  mutable persisted : int;  (* forced up to this index *)
  mutable gen : int;  (* grows at each truncation: the disk's word about an older generation is ignored *)
  mutable commit : int;
  mutable floor : int;  (* a follower: the newest leader's floor *)
  (* volatile *)
  mutable role : role;
  mutable leader : int;  (* -1: unknown *)
  votes : bool array;
  mutable deadline : int;
  mutable heard : int;  (* when the current leader was last heard *)
  started : int;
  mutable verified : int;  (* follower: its log is the leader's up to this index *)
  peers : peer array;
  mutable noop : int;
  mutable seq : int;
  mutable fx : action list;  (* newest first *)
}

(* how much an Append carries at most (the bytes of its entries, at least one), and how far a follower may lag in
   flight *)
let max_append_bytes = 1 lsl 20
let max_inflight = 1024
let max_inflight_bytes = 8 lsl 20

let emit t e = match e, t.fx with Save, Save :: _ -> () | _ -> t.fx <- e :: t.fx
let drain t = let l = List.rev t.fx in t.fx <- []; l

let last_index t = t.start + t.len - 1

let term_at t i =
  if i = t.start - 1 then t.prev_term
  else if i >= t.start && i <= last_index t then t.terms.(i - t.start)
  else -1

let last_term t = term_at t (last_index t)
let size_at t i = if i >= t.start && i <= last_index t then t.sizes.(i - t.start) else 0
let majority t = t.n / 2 + 1
let random_timeout t now = now + t.election_ms + Rng.int t.rng t.election_ms

let make ~me ~n ~election_ms ~heartbeat_ms ~rng ~now ~term ~vote ~repair ~start ~prev_term ~terms ~sizes ~commit =
  let len = Array.length terms in
  let cap = max 64 (2 * len) in
  let a = Array.make cap 0 and s = Array.make cap 0 in
  Array.blit terms 0 a 0 len;
  Array.blit sizes 0 s 0 len;
  let t =
    { me; n; election_ms; heartbeat_ms; rng; term; vote; repair; start; prev_term; terms = a; sizes = s; len;
      persisted = start + len - 1; gen = 0; commit = 0; floor = 0; role = Follower; leader = -1; votes = Array.make n false;
      deadline = 0; heard = min_int / 2; started = now; verified = 0;
      peers = Array.init n (fun _ -> { next = 1; matched = 0; probing = true; last_send = 0; last_seq = 0; sent = Queue.create (); acked_at = min_int / 2; contact = 0 });
      noop = 0; seq = 0; fx = [] }
  in
  t.commit <- min (last_index t) (max commit (start - 1));
  t.deadline <- random_timeout t now;
  t

(* ---- the log in memory ---- *)

let grow t need =
  if need > Array.length t.terms then begin
    let cap = max need (2 * Array.length t.terms) in
    let a = Array.make cap 0 and s = Array.make cap 0 in
    Array.blit t.terms 0 a 0 t.len;
    Array.blit t.sizes 0 s 0 t.len;
    t.terms <- a;
    t.sizes <- s
  end

let push t term size =
  grow t (t.len + 1);
  t.terms.(t.len) <- term;
  t.sizes.(t.len) <- size;
  t.len <- t.len + 1

(* entries from [i] on dropped *)
let cut t i =
  t.len <- max 0 (i - t.start);
  t.gen <- t.gen + 1;
  if t.persisted >= i then t.persisted <- i - 1;
  if t.verified >= i then t.verified <- i - 1

(* the log's start moved to [i] (its entries before i are in the databases' journals) *)
let compact t i =
  if i > t.start && i - 1 <= t.commit && i - 1 <= t.persisted then begin
    let k = i - t.start in
    t.prev_term <- term_at t (i - 1);
    Array.blit t.terms k t.terms 0 (t.len - k);
    Array.blit t.sizes k t.sizes 0 (t.len - k);
    t.len <- t.len - k;
    t.start <- i
  end

(* ---- roles ---- *)

let up_to_date t ~last_index:li ~last_term:lt = lt > last_term t || (lt = last_term t && li >= last_index t)

let set_term t term =
  if term > t.term then begin
    t.term <- term;
    t.vote <- -1;
    emit t Save
  end

let become_follower t now ~term ~leader =
  let was = t.role = Leader in
  set_term t term;
  t.role <- Follower;
  (* its committed entries are any leader's: known to match the new one *)
  if leader <> t.leader then t.verified <- t.commit;
  t.leader <- leader;
  t.deadline <- random_timeout t now;
  if was then emit t Unlead

(* a leader's sticky time: it, or a follower that heard from a leader within the minimum timeout, or a server that
   started less than that ago, takes no vote request *)
let sticky t now =
  t.role = Leader || (t.leader >= 0 && now - t.heard < t.election_ms) || now - t.started < t.election_ms

(* ---- the leader's sending ---- *)

let commit_to t i =
  if i > t.commit then begin
    t.commit <- i;
    emit t (Commit i)
  end

(* the newest index a majority holds forced, if its entry is of this term *)
let advance t =
  if t.role = Leader then begin
    let m = Array.init t.n (fun k -> if k = t.me then t.persisted else t.peers.(k).matched) in
    Array.sort (fun a b -> compare b a) m;
    let i = m.(majority t - 1) in
    if i > t.commit && term_at t i = t.term then commit_to t i
  end

(* every server holds the leader's log up to this index (as far as the leader knows; a follower: what its leader said)
   *)
let floor t =
  if t.role = Leader then Array.fold_left min max_int (Array.mapi (fun k p -> if k = t.me then t.persisted else p.matched) t.peers)
  else t.floor

let send_append t now k =
  let p = t.peers.(k) in
  let prev = p.next - 1 in
  let prev_term = term_at t prev in
  if prev_term >= 0 then begin
    (* the entries from next, up to max_append_bytes (at least one) *)
    let last = last_index t in
    let stop = ref p.next and bytes = ref 0 in
    while !stop <= last && (!stop = p.next || !bytes + size_at t !stop <= max_append_bytes) do
      bytes := !bytes + size_at t !stop;
      incr stop
    done;
    let count = !stop - p.next in
    let terms = Array.init count (fun j -> term_at t (p.next + j)) in
    let sizes = Array.init count (fun j -> size_at t (p.next + j)) in
    t.seq <- t.seq + 1;
    if Queue.length p.sent >= 4096 then ignore (Queue.take p.sent);
    Queue.push (t.seq, now) p.sent;
    p.last_send <- now;
    p.last_seq <- t.seq;
    if not p.probing then p.next <- p.next + count;
    emit t (Send (k, Append { term = t.term; seq = t.seq; prev_index = prev; prev_term; terms; sizes; commit = t.commit; floor = floor t }))
  end
  else begin
    (* the peer needs entries before this log's start: they are in the journals only (next step: a catch-up from
       them); a heartbeat keeps it following *)
    p.probing <- true;
    t.seq <- t.seq + 1;
    Queue.push (t.seq, now) p.sent;
    p.last_send <- now;
    p.last_seq <- t.seq;
    emit t (Send (k, Append { term = t.term; seq = t.seq; prev_index = last_index t; prev_term = last_term t; terms = [||]; sizes = [||]; commit = t.commit; floor = floor t }))
  end

let in_flight t p =
  let b = ref 0 in
  for i = p.matched + 1 to min (p.next - 1) (last_index t) do b := !b + size_at t i done;
  !b

(* sends what each follower lacks: a probe at most every heartbeat, entries as they come once its log is found,
   within a window *)
let pump t now =
  if t.role = Leader then
    Array.iteri
      (fun k p ->
        if k <> t.me then
          if p.probing then (if now - p.last_send >= t.heartbeat_ms then send_append t now k)
          else begin
            let sent = ref false in
            while (not p.probing) && p.next <= last_index t && p.next - 1 - p.matched < max_inflight && in_flight t p < max_inflight_bytes do
              send_append t now k;
              sent := true
            done;
            if (not !sent) && now - p.last_send >= t.heartbeat_ms then send_append t now k
          end)
      t.peers

let become_leader t now =
  t.role <- Leader;
  t.leader <- t.me;
  Array.iter
    (fun p ->
      p.next <- last_index t + 1;
      p.matched <- 0;
      p.probing <- true;
      p.last_send <- min_int / 2;
      Queue.clear p.sent;
      p.acked_at <- min_int / 2;
      p.contact <- now)
    t.peers;
  (* the no-op of this term: its commit commits every entry before it *)
  push t t.term 0;
  t.noop <- last_index t;
  emit t Lead;
  pump t now

(* the time from which a majority answered: the newest time such that a majority's answered Appends were sent at or
   after it (the leader itself: now) *)
let quorum_time t now f =
  let m = Array.init t.n (fun k -> if k = t.me then now else f t.peers.(k)) in
  Array.sort (fun a b -> compare b a) m;
  m.(majority t - 1)

let lease_ms t = t.election_ms * 9 / 10

(* reads on this server are linearizable until this time (ms), if it leads *)
let lease_until t now = if t.role = Leader then quorum_time t now (fun p -> p.acked_at) + lease_ms t else min_int

(* ---- inputs ---- *)

let start_pre_vote t now =
  t.role <- Pre_candidate;
  Array.fill t.votes 0 t.n false;
  t.votes.(t.me) <- true;
  t.deadline <- random_timeout t now;
  for k = 0 to t.n - 1 do
    if k <> t.me then emit t (Send (k, Pre_vote { term = t.term + 1; last_index = last_index t; last_term = last_term t }))
  done

let count t = Array.fold_left (fun c v -> if v then c + 1 else c) 0 t.votes

let tick t now =
  match t.role with
  | Leader ->
    if now - quorum_time t now (fun p -> p.contact) >= t.election_ms then begin
      (* CheckQuorum: no majority heard within an election timeout *)
      t.role <- Follower;
      t.leader <- -1;
      t.deadline <- random_timeout t now;
      emit t Unlead
    end
    else pump t now
  | Follower | Pre_candidate | Candidate ->
    if now >= t.deadline then
      if t.repair > 0 then t.deadline <- random_timeout t now  (* damaged: stands for no election *)
      else start_pre_vote t now

let reply_append t k ~seq ~ok ~index = emit t (Send (k, Append_reply { term = t.term; seq; ok; index }))

(* a follower's acknowledgement, once forced: the leader's entries it holds forced, and the end of the 2018 repair *)
let acked t = min t.verified t.persisted

let check_repair t ~leader_commit =
  if t.repair > 0 && acked t >= t.repair && leader_commit >= t.repair then begin
    t.repair <- 0;
    emit t Save
  end

(* the first index of the term of entry [i] in this log, minus one: a refused Append's hint (never below commit) *)
let hint t i =
  let tm = term_at t i in
  let j = ref i in
  while !j - 1 >= t.start && !j - 1 > t.commit && term_at t (!j - 1) = tm do decr j done;
  max t.commit (!j - 1)

let receive t now k msg =
  match msg with
  | Pre_vote { term; last_index; last_term } ->
    let granted = term > t.term && (not (sticky t now)) && t.repair = 0 && up_to_date t ~last_index ~last_term in
    emit t (Send (k, Pre_vote_reply { term = (if granted then term else t.term); granted }))
  | Pre_vote_reply { term; granted } ->
    (* a refusal from a server of a newer term: that term is taken (as etcd's pre-vote does), so that a candidate
       whose term fell behind can be elected at all *)
    if (not granted) && term > t.term then become_follower t now ~term ~leader:(-1)
    else if t.role = Pre_candidate && term = t.term + 1 && granted then begin
      t.votes.(k) <- true;
      if count t >= majority t then begin
        t.term <- t.term + 1;
        t.vote <- t.me;
        emit t Save;
        t.role <- Candidate;
        t.leader <- -1;
        Array.fill t.votes 0 t.n false;
        t.votes.(t.me) <- true;
        t.deadline <- random_timeout t now;
        for j = 0 to t.n - 1 do
          if j <> t.me then emit t (Send (j, Vote { term = t.term; last_index = last_index t; last_term = last_term t }))
        done
      end
    end
  | Vote { term; last_index; last_term } ->
    if sticky t now then emit t (Send (k, Vote_reply { term = t.term; granted = false }))
    else begin
      if term > t.term then become_follower t now ~term ~leader:(-1);
      let granted = term = t.term && (t.vote = -1 || t.vote = k) && t.repair = 0 && up_to_date t ~last_index ~last_term in
      if granted then begin
        if t.vote <> k then (t.vote <- k; emit t Save);
        t.deadline <- random_timeout t now
      end;
      emit t (Send (k, Vote_reply { term = t.term; granted }))
    end
  | Vote_reply { term; granted } ->
    if term > t.term then become_follower t now ~term ~leader:(-1)
    else if t.role = Candidate && term = t.term && granted then begin
      t.votes.(k) <- true;
      if count t >= majority t then become_leader t now
    end
  | Append { term; seq; prev_index; prev_term; terms; sizes; commit; floor } ->
    if term < t.term then reply_append t k ~seq ~ok:false ~index:(last_index t)
    else begin
      if term > t.term || t.role <> Follower || t.leader <> k then become_follower t now ~term ~leader:k;
      t.heard <- now;
      t.floor <- floor;
      t.deadline <- random_timeout t now;
      let count = Array.length terms in
      (* entries up to this log's start are committed here, so the leader's: the Append is taken from there *)
      let base = t.start - 1 in
      let skip = max 0 (base - prev_index) in
      let prev = prev_index + skip and prev_t = if skip > 0 then t.prev_term else prev_term in
      if skip >= count && skip > 0 then begin
        t.verified <- max t.verified (prev_index + count);
        reply_append t k ~seq ~ok:true ~index:(acked t)
      end
      else if prev > last_index t then reply_append t k ~seq ~ok:false ~index:(last_index t)
      else if skip = 0 && term_at t prev <> prev_t then reply_append t k ~seq ~ok:false ~index:(hint t prev)
      else begin
        (* the entries it lacks, after those it holds of the same term; a conflict cuts the log there *)
        let j = ref skip and stop = ref false and bad = ref false in
        while (not !stop) && !j < count do
          let i = prev_index + 1 + !j in
          if i > last_index t then stop := true
          else if term_at t i = terms.(!j) then incr j
          else if i <= t.commit then (bad := true; stop := true)
          else begin
            cut t i;
            emit t (Truncate i);
            stop := true
          end
        done;
        if !bad then
          (* a leader's entry against a committed one: never taken (a bug, or a peer that is not what it says) *)
          reply_append t k ~seq ~ok:false ~index:t.commit
        else begin
          let first = prev_index + 1 + !j in
          if !j < count then begin
            for x = !j to count - 1 do push t terms.(x) sizes.(x) done;
            emit t (Store { first; skip = !j; count = count - !j })
          end;
          t.verified <- max t.verified (prev_index + count);
          commit_to t (min commit t.verified);
          check_repair t ~leader_commit:commit;
          reply_append t k ~seq ~ok:true ~index:(acked t)
        end
      end
    end
  | Append_reply { term; seq; ok; index } ->
    if term > t.term then become_follower t now ~term ~leader:(-1)
    else if t.role = Leader && term = t.term then begin
      let p = t.peers.(k) in
      p.contact <- now;
      (* the time its newest answered Append was sent: the lease's *)
      while (match Queue.peek_opt p.sent with Some (s, _) -> s < seq | None -> false) do ignore (Queue.take p.sent) done;
      (match Queue.peek_opt p.sent with
       | Some (s, at) when s = seq -> ignore (Queue.take p.sent); if at > p.acked_at then p.acked_at <- at
       | _ -> ());
      if ok then begin
        if index > p.matched then p.matched <- index;
        if p.probing then (p.probing <- false; p.next <- max p.next (p.matched + 1));
        if p.next <= p.matched then p.next <- p.matched + 1;
        advance t
      end
      else if seq = p.last_seq then begin
        (* its log differs or is shorter: probe again at once, after its hint. Shorter than what it acknowledged: the
           2018 rule set damaged entries aside there; they no longer count (a commit already made stays) *)
        if index < p.matched then p.matched <- index;
        p.probing <- true;
        p.next <- max (p.matched + 1) (min p.next (index + 1));
        p.last_send <- min_int / 2
      end;
      pump t now
    end

(* the disk forced the log up to [i] (in generation [gen]) *)
let persisted t ~gen i =
  if gen = t.gen && i > t.persisted then begin
    t.persisted <- min i (last_index t);
    match t.role with
    | Leader -> advance t
    | Follower when t.leader >= 0 && t.verified > 0 ->
      (* the acknowledgement the Append's reply could not give before the fsync *)
      check_repair t ~leader_commit:t.commit;
      reply_append t t.leader ~seq:0 ~ok:true ~index:(acked t)
    | _ -> ()
  end

(* a leader's new entry: its index, or None if this server does not lead *)
let propose t now size =
  if t.role <> Leader then None
  else begin
    push t t.term size;
    pump t now;
    Some (last_index t)
  end

let ready t = t.role = Leader && t.commit >= t.noop

(* the connection to peer k broke: what was in flight may be lost, so its log is probed again *)
let unreachable t k =
  if t.role = Leader then begin
    let p = t.peers.(k) in
    p.probing <- true;
    p.next <- p.matched + 1;
    p.last_send <- min_int / 2
  end
