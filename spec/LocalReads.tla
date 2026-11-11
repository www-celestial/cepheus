----------------------------- MODULE LocalReads -----------------------------
(* Reads in a program's own memory on the server's machine (docs/book/server.md, "Local reads"), and the rules that were
   considered for them. The server writes groups one frame at a time; it sends each frame to every local reader as
   soon as the frame is written, and the frame becomes durable at its fsync. Readers apply frames in their own
   process; programs read there, and remote programs read at the server. A read is an interval: it starts, it takes a
   state, it returns it. Linearizable reads of this database (Herlihy and Wing 1990), whose writes take one total
   order of groups, are exactly three conditions on every read, checked when it returns its state s:
     Fresh:    s holds every group whose writer was answered before the read started;
     Ordered:  s holds every group that a read returned before this read started (no "new-old inversion": Lamport's
               atomic register, against his regular one, 1986);
     Durable:  s is a prefix of the journal's durable groups, exactly as they are (G5; with a crash, a group that was
               lost and a later group of the same number are different writes: ids tell them apart).
   Rule says how a group becomes visible and when its writer is answered:
     "word"         the rule built: the server stores a sequence number in a page of shared memory (a tmpfs page)
                    after each fsync, then answers the writers; each frame tells readers the number it will be
                    visible under; a read loads the number and serves the state tagged with it, or waits; a server
                    that starts adds 2 to the number;
     "word_noskip"  the same, without the 2 at a start: a group the restart made durable is answered while a reader
                    still serves the state before it under the same number (Fresh breaks; with a lost frame, its
                    state can be served too);
     "word_early"   the number stored before the fsync: a group a crash takes back is served (Durable);
     "remote_first" remote reads see a group at its fsync, before the number moves (Ordered breaks);
     "design"       the design's lease (2026-11-08 §5.3): the server sends Durable(n, until T = now + L) after the
                    fsync, a reader serves its newest durable state while its clock is before T, the server answers
                    group n's writers once every reader whose T is ahead acked n; remote reads see n at its fsync
                    (Fresh holds; Ordered breaks: two readers, or a remote read and a local one);
     "draft"        the first draft: a reader renews its own lease at the time it acks (Fresh breaks too).
   Bounds: Readers, MaxWrites writes, MaxCrashes server deaths (word rules), time up to MaxTime with leases of L;
   readers are symmetric. *)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS Readers, MaxWrites, MaxCrashes, MaxTime, L, Rule

WordRule == Rule \in {"word", "word_noskip", "word_early", "remote_first"}
LeaseRule == Rule \in {"design", "draft"}

VARIABLES
  log,       \* the journal: a sequence of write ids (its durable prefix, then at most one frame being forced)
  durable,   \* the length of its durable prefix
  answered,  \* writers of groups 1..answered have their receipts
  nextId,    \* the next write's id
  up,        \* the server runs
  crashes,
  word,      \* word rules: the number in shared memory (it survives a server's death: the page is a file's)
  vis,       \* word rules: how many groups are visible under that number
  shown,     \* the state remote reads see
  conn,      \* each reader: "on" (connected), "broken" (the server died; not noticed yet), "off" (noticed)
  chan,      \* each reader: the messages the server sent it, not yet read (a socket keeps them past a death)
  states,    \* word rules, each reader: the states it holds, [vs |-> number, st |-> state]
  pend,      \* lease rules, each reader: its newest state applied from a frame, not yet durable
  pub,       \* lease rules, each reader: the state it serves
  lease,     \* lease rules, each reader: the end of its lease, on its clock
  acks,      \* lease rules, each reader: its acks in flight to the server, <<group, time sent>>
  acked,     \* lease rules, the server: the newest group each reader acked
  grant,     \* lease rules, the server: the end of the lease it counts for each reader
  now,       \* the machine's monotonic clock (one kernel: the same for every process)
  rd,        \* each reader: its program's read in progress
  rr,        \* a remote program's read in progress
  done,      \* the newest group a finished read returned
  bad        \* the condition a read broke, or ""

vars == <<log, durable, answered, nextId, up, crashes, word, vis, shown, conn, chan, states, pend, pub, lease, acks, acked,
          grant, now, rd, rr, done, bad>>

Idle == [pc |-> "idle", lo |-> 0, floor |-> 0, w |-> 0]

Init ==
  /\ log = <<>> /\ durable = 0 /\ answered = 0 /\ nextId = 1 /\ up = TRUE /\ crashes = 0
  /\ word = 2 /\ vis = 0 /\ shown = <<>>
  /\ conn = [r \in Readers |-> "on"]
  /\ chan = [r \in Readers |-> <<>>]
  /\ states = [r \in Readers |-> {[vs |-> 2, st |-> <<>>]}]
  /\ pend = [r \in Readers |-> <<>>] /\ pub = [r \in Readers |-> <<>>]
  /\ lease = [r \in Readers |-> L] /\ grant = [r \in Readers |-> L]
  /\ acks = [r \in Readers |-> <<>>] /\ acked = [r \in Readers |-> 0]
  /\ now = 0
  /\ rd = [r \in Readers |-> Idle] /\ rr = Idle
  /\ done = 0 /\ bad = ""

Max(a, b) == IF a > b THEN a ELSE b
Min(a, b) == IF a < b THEN a ELSE b

(* the conditions of a read that started with [x] and returns [s] *)
Check(x, s) ==
  IF Len(s) < x.lo THEN "Fresh"
  ELSE IF Len(s) < x.floor THEN "Ordered"
  ELSE IF Len(s) > durable \/ s # SubSeq(log, 1, Len(s)) THEN "Durable"
  ELSE ""

Finish(s, x) ==
  /\ done' = Max(done, Len(s))
  /\ bad' = IF bad # "" THEN bad ELSE Check(x, s)

(* ---- the server ---- *)

(* a write's group is resolved and its frame written; the frame goes to every connected reader at once *)
Write ==
  /\ up /\ Len(log) = durable /\ nextId <= MaxWrites /\ (WordRule => vis = durable)
  /\ log' = Append(log, nextId)
  /\ nextId' = nextId + 1
  /\ chan' = [r \in Readers |->
               IF conn[r] = "on"
               THEN Append(chan[r], IF WordRule THEN [k |-> "frame", vs |-> word + 1, st |-> log', n |-> 0, t |-> 0]
                                                 ELSE [k |-> "frame", vs |-> 0, st |-> log', n |-> 0, t |-> 0])
               ELSE chan[r]]
  /\ word' = IF Rule = "word_early" THEN word + 1 ELSE word
  /\ vis' = IF Rule = "word_early" THEN Len(log') ELSE vis
  /\ UNCHANGED <<durable, answered, up, crashes, shown, conn, states, pend, pub, lease, acks, acked, grant, now, rd, rr,
                 done, bad>>

(* the fsync returns: the frame is durable. Word rules: the number moves (but in "remote_first", where only the
   remote view moves now: Publish moves the number later). Lease rules: remote reads see it, and each connected
   reader gets Durable, with a lease if it acked the newest answered group. *)
Fsync ==
  /\ up /\ Len(log) > durable
  /\ durable' = Len(log)
  /\ shown' = log
  /\ IF WordRule
     THEN /\ word' = IF Rule \in {"word", "word_noskip"} THEN word + 1 ELSE word
          /\ vis' = IF Rule \in {"word", "word_noskip"} THEN Len(log) ELSE vis
          /\ UNCHANGED <<chan, grant>>
     ELSE /\ chan' = [r \in Readers |->
                       IF conn[r] = "on"
                       THEN Append(chan[r], [k |-> "durable", vs |-> 0, st |-> <<>>, n |-> Len(log),
                                             t |-> IF Rule = "design" /\ acked[r] >= answered THEN now + L ELSE 0])
                       ELSE chan[r]]
          /\ grant' = [r \in Readers |->
                        IF Rule = "design" /\ conn[r] = "on" /\ acked[r] >= answered THEN now + L ELSE grant[r]]
          /\ UNCHANGED <<word, vis>>
  /\ UNCHANGED <<log, answered, nextId, up, crashes, conn, states, pend, pub, lease, acks, acked, now, rd, rr, done, bad>>

(* remote_first: the number moves after the remote view did *)
Publish ==
  /\ Rule = "remote_first" /\ up /\ durable > vis
  /\ word' = word + 1
  /\ vis' = durable
  /\ UNCHANGED <<log, durable, answered, nextId, up, crashes, shown, conn, chan, states, pend, pub, lease, acks, acked,
                 grant, now, rd, rr, done, bad>>

(* the writers of the durable groups are answered: word rules, those visible under the number; lease rules, once
   every reader whose lease is ahead acked them *)
Answer ==
  /\ up
  /\ LET a == IF WordRule THEN Min(vis, durable) ELSE durable IN
       /\ a > answered
       /\ LeaseRule => \A r \in Readers : conn[r] = "on" => (acked[r] >= durable \/ grant[r] <= now)
       /\ answered' = a
  /\ UNCHANGED <<log, durable, nextId, up, crashes, word, vis, shown, conn, chan, states, pend, pub, lease, acks, acked,
                 grant, now, rd, rr, done, bad>>

(* the design's renewal while nothing is written: the last Durable again, with a new lease *)
Renew ==
  /\ Rule = "design" /\ up /\ Len(log) = durable /\ durable = answered
  /\ \E r \in Readers :
       /\ conn[r] = "on" /\ acked[r] >= answered /\ grant[r] < now + L
       /\ chan' = [chan EXCEPT ![r] = Append(chan[r], [k |-> "durable", vs |-> 0, st |-> <<>>, n |-> durable, t |-> now + L])]
       /\ grant' = [grant EXCEPT ![r] = now + L]
  /\ UNCHANGED <<log, durable, answered, nextId, up, crashes, word, vis, shown, conn, states, pend, pub, lease, acks, acked,
                 now, rd, rr, done, bad>>

(* an ack arrives; the draft renews the lease the server counts from the time the reader sent it *)
RecvAck(r) ==
  /\ up /\ acks[r] # <<>>
  /\ acked' = [acked EXCEPT ![r] = Max(acked[r], Head(acks[r])[1])]
  /\ grant' = IF Rule = "draft" THEN [grant EXCEPT ![r] = Max(grant[r], Head(acks[r])[2] + L)] ELSE grant
  /\ acks' = [acks EXCEPT ![r] = Tail(acks[r])]
  /\ UNCHANGED <<log, durable, answered, nextId, up, crashes, word, vis, shown, conn, chan, states, pend, pub, lease, now,
                 rd, rr, done, bad>>

(* word rules: the server dies (kill -9); the frame being forced is kept (written: recovery forces it) or lost (not
   written yet); readers' connections break, the bytes already sent stay readable *)
Crash ==
  /\ WordRule /\ up /\ crashes < MaxCrashes
  /\ up' = FALSE
  /\ crashes' = crashes + 1
  /\ \E keep \in {TRUE, FALSE} : log' = IF keep THEN log ELSE SubSeq(log, 1, durable)
  /\ conn' = [r \in Readers |-> IF conn[r] = "on" THEN "broken" ELSE conn[r]]
  /\ rr' = Idle
  /\ UNCHANGED <<durable, answered, nextId, word, vis, shown, chan, states, pend, pub, lease, acks, acked, grant, now, rd,
                 done, bad>>

(* the server starts again: recovery makes every frame in the journal durable; the number moves by 2 (the rule), or
   not at all (word_noskip) *)
Restart ==
  /\ ~up
  /\ up' = TRUE
  /\ durable' = Len(log)
  /\ shown' = log
  /\ word' = IF Rule = "word_noskip" THEN word ELSE word + 2
  /\ vis' = Len(log)
  /\ UNCHANGED <<log, answered, nextId, crashes, conn, chan, states, pend, pub, lease, acks, acked, grant, now, rd, rr,
                 done, bad>>

Tick ==
  /\ LeaseRule /\ now < MaxTime
  /\ now' = now + 1
  /\ UNCHANGED <<log, durable, answered, nextId, up, crashes, word, vis, shown, conn, chan, states, pend, pub, lease, acks,
                 acked, grant, rd, rr, done, bad>>

(* ---- a reader ---- *)

(* the next message: a frame (word: a new state, tagged with its number; states the number has passed are dropped);
   Durable (lease rules: the pending state served, the lease from the server or, in the draft, from now; an ack) *)
Deliver(r) ==
  /\ chan[r] # <<>>
  /\ LET m == Head(chan[r]) IN
       IF WordRule
       THEN /\ states' = [states EXCEPT ![r] = {x \in states[r] \cup {[vs |-> m.vs, st |-> m.st]} : x.vs >= word}]
            /\ UNCHANGED <<pend, pub, lease, acks>>
       ELSE IF m.k = "frame"
       THEN /\ pend' = [pend EXCEPT ![r] = m.st]
            /\ UNCHANGED <<states, pub, lease, acks>>
       ELSE /\ pub' = [pub EXCEPT ![r] = SubSeq(pend[r], 1, m.n)]
            /\ lease' = [lease EXCEPT ![r] = IF Rule = "draft" THEN now + L ELSE IF m.t > 0 THEN m.t ELSE lease[r]]
            /\ acks' = [acks EXCEPT ![r] = Append(acks[r], <<m.n, now>>)]
            /\ UNCHANGED <<states, pend>>
  /\ chan' = [chan EXCEPT ![r] = Tail(chan[r])]
  /\ UNCHANGED <<log, durable, answered, nextId, up, crashes, word, vis, shown, conn, acked, grant, now, rd, rr, done, bad>>

(* the end of a dead server's connection, once its bytes are read: the reader drops its states *)
Notice(r) ==
  /\ conn[r] = "broken" /\ chan[r] = <<>>
  /\ conn' = [conn EXCEPT ![r] = "off"]
  /\ states' = [states EXCEPT ![r] = {}]
  /\ UNCHANGED <<log, durable, answered, nextId, up, crashes, word, vis, shown, chan, pend, pub, lease, acks, acked, grant,
                 now, rd, rr, done, bad>>

(* a new connection: the state visible under the number, and the frame being forced *)
Reconnect(r) ==
  /\ conn[r] = "off" /\ up /\ Len(log) = durable
  /\ conn' = [conn EXCEPT ![r] = "on"]
  /\ states' = [states EXCEPT ![r] = {[vs |-> word, st |-> SubSeq(log, 1, vis)]}]
  /\ UNCHANGED <<log, durable, answered, nextId, up, crashes, word, vis, shown, chan, pend, pub, lease, acks, acked, grant,
                 now, rd, rr, done, bad>>

(* a program's read in the reader: it starts; it loads the number (word rules); it returns the state tagged with
   that number, or loads the number again; lease rules: it returns the served state while the lease lasts *)
StartRead(r) ==
  /\ rd[r].pc = "idle"
  /\ rd' = [rd EXCEPT ![r] = [pc |-> "start", lo |-> answered, floor |-> done, w |-> 0]]
  /\ UNCHANGED <<log, durable, answered, nextId, up, crashes, word, vis, shown, conn, chan, states, pend, pub, lease, acks,
                 acked, grant, now, rr, done, bad>>

LoadWord(r) ==
  /\ WordRule /\ rd[r].pc = "start"
  /\ rd' = [rd EXCEPT ![r].pc = "word", ![r].w = word]
  /\ UNCHANGED <<log, durable, answered, nextId, up, crashes, word, vis, shown, conn, chan, states, pend, pub, lease, acks,
                 acked, grant, now, rr, done, bad>>

EndRead(r) ==
  /\ IF WordRule
     THEN /\ rd[r].pc = "word"
          /\ IF \E x \in states[r] : x.vs = rd[r].w
             THEN \E x \in states[r] :
                    /\ x.vs = rd[r].w
                    /\ Finish(x.st, rd[r])
                    /\ rd' = [rd EXCEPT ![r] = Idle]
             ELSE /\ rd' = [rd EXCEPT ![r].pc = "start"]
                  /\ UNCHANGED <<done, bad>>
     ELSE /\ rd[r].pc = "start" /\ conn[r] = "on" /\ now < lease[r]
          /\ Finish(pub[r], rd[r])
          /\ rd' = [rd EXCEPT ![r] = Idle]
  /\ UNCHANGED <<log, durable, answered, nextId, up, crashes, word, vis, shown, conn, chan, states, pend, pub, lease, acks,
                 acked, grant, now, rr>>

(* a remote program's read at the server *)
StartRemote ==
  /\ rr.pc = "idle" /\ up
  /\ rr' = [pc |-> "start", lo |-> answered, floor |-> done, w |-> 0]
  /\ UNCHANGED <<log, durable, answered, nextId, up, crashes, word, vis, shown, conn, chan, states, pend, pub, lease, acks,
                 acked, grant, now, rd, done, bad>>

EndRemote ==
  /\ rr.pc = "start" /\ up
  /\ Finish(shown, rr)
  /\ rr' = Idle
  /\ UNCHANGED <<log, durable, answered, nextId, up, crashes, word, vis, shown, conn, chan, states, pend, pub, lease, acks,
                 acked, grant, now, rd>>

Next ==
  \/ Write \/ Fsync \/ Publish \/ Answer \/ Renew \/ Crash \/ Restart \/ Tick \/ StartRemote \/ EndRemote
  \/ \E r \in Readers : RecvAck(r) \/ Deliver(r) \/ Notice(r) \/ Reconnect(r) \/ StartRead(r) \/ LoadWord(r) \/ EndRead(r)

Spec == Init /\ [][Next]_vars

(* readers are interchangeable: TLC checks one of each set of states that differ only by their names *)
ReaderSymmetry == Permutations(Readers)

(* every read returned a linearizable state *)
Linearizable == bad = ""

(* no writer is answered before its group is durable (G1) *)
AnsweredDurable == answered <= durable

(* no read misses a write that was answered, or shows one that is not durable: what the design's lease keeps *)
NoStale == bad \notin {"Fresh", "Durable"}

(* for tools/tlc.sh: under the rule built, reads do return the newest group (the model is not empty) *)
NeverReadsAll == done < MaxWrites

=============================================================================
