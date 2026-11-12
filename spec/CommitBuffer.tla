---------------------------- MODULE CommitBuffer ----------------------------
(* The commit buffer of a server that holds several databases (src/wal.ml): one forced log for the server, and each
   database's journal written without an fsync and forced only at checkpoints.

   A database's syncer writes its frame to its journal (no fsync) and gives it to the buffer; it writes its next frame
   only once this one is confirmed (one frame in flight a database). A round is one frame of the buffer holding the
   frames of every database that came meanwhile, appended and forced once (group commit across databases); every
   frame of a round is confirmed after the round's fsync. One round is in flight at a time. A checkpoint of a database
   forces its journal; a round whose frames are all checkpointed may go (the two files of the buffer alternate: a
   file is replaced once each journal with frames in it was forced after them). A frame may also be forced in its own
   journal (a large group's, or a long one), outside the buffer, and is confirmed by that fsync.

   Faults, as in Journal.tla: F1 a process death (what was written stays in the page cache), F2 a power loss (each
   byte not forced may be lost, kept or torn, each frame its own: a journal's unforced frames may survive with holes
   between them), F4 a failed fsync marks the pages clean without writing them (Rebello et al., ATC 2020); a failed
   fsync of the buffer, or of a journal at a checkpoint, stops the buffer until a restart (G10).

   Recovery keeps no record of the checkpoints: from what survived, the buffer's newest round, torn, is cut (the one in
   flight, never confirmed); for each database, every frame the buffer kept is written again at its place in the
   journal, every other frame before the last of them must check (it was forced: else damage, refuse), and the
   journal's own rule (Journal.tla) takes what follows: a torn tail is cut, a frame that checks after one that does not
   is damage.

   Variants that must break: TrustJournal recovers a journal by its own rule alone (a hole followed by a frame that
   checks reads as damage: G6's false alarm, or a torn tail cut that held confirmed frames); EarlyRecycle drops a
   round once its frames are in the journals' page cache, before their checkpoint (a power loss loses confirmed
   frames); CkptAfterFailure lets a checkpoint follow a failed fsync of the journal (the pages it marked clean are
   never written, and the checkpoint covers them); ManyInFlight lets a database write a frame before its previous one
   is confirmed (two unforced frames after the buffer's: a hole then a frame that checks, read as damage). *)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS DB, MaxFrames, TrustJournal, EarlyRecycle, CkptAfterFailure, ManyInFlight

VARIABLES
  jfile,    \* jfile[d]: the frames of d's journal a reader of the page cache sees: <<"ok", n>>
  jdisk,    \* jdisk[d]: the positions of jfile[d] the disk holds for sure
  jlimbo,   \* jlimbo[d]: the positions a failed fsync of d's journal marked clean: no later fsync writes them
  ckpt,     \* ckpt[d]: d's journal forced up to frame ckpt[d] (the buffer's memory: lost at a crash)
  jstop,    \* jstop[d]: an fsync of d's journal failed: no checkpoint of d until the restart
  inflight, \* inflight[d]: d's newest frame is not confirmed yet
  buf,      \* the buffer's rounds in the page cache, each a set of <<d, n>>, oldest first
  bdur,     \* the rounds 1..bdur are on the disk
  pending,  \* frames written to their journals, waiting for the next round
  inround,  \* a round is written, its fsync not finished
  next,     \* next[d]: the number of d's next frame
  acked,    \* the frames confirmed: <<d, n>>
  stopped,  \* an fsync of the buffer or of a journal's checkpoint failed: nothing more is confirmed until a restart
  up,       \* the process runs
  refused   \* a recovery refused to open a database

vars == <<jfile, jdisk, jlimbo, ckpt, jstop, inflight, buf, bdur, pending, inround, next, acked, stopped, up, refused>>

Init == /\ jfile = [d \in DB |-> << >>] /\ jdisk = [d \in DB |-> {}] /\ jlimbo = [d \in DB |-> {}]
        /\ ckpt = [d \in DB |-> 0] /\ jstop = [d \in DB |-> FALSE] /\ inflight = [d \in DB |-> FALSE]
        /\ buf = << >> /\ bdur = 0 /\ pending = {} /\ inround = FALSE /\ next = [d \in DB |-> 1]
        /\ acked = {} /\ stopped = FALSE /\ up = TRUE /\ refused = FALSE

CanWrite(d) == up /\ ~stopped /\ ~refused /\ ~jstop[d] /\ next[d] <= MaxFrames /\ (~inflight[d] \/ ManyInFlight)

(* a database's syncer: its frame written to its journal, without fsync, and given to the buffer *)
WriteFrame(d) == /\ CanWrite(d)
                 /\ jfile' = [jfile EXCEPT ![d] = Append(@, <<"ok", next[d]>>)]
                 /\ pending' = pending \cup {<<d, next[d]>>}
                 /\ next' = [next EXCEPT ![d] = @ + 1]
                 /\ inflight' = [inflight EXCEPT ![d] = TRUE]
                 /\ UNCHANGED <<jdisk, jlimbo, ckpt, jstop, buf, bdur, inround, acked, stopped, up, refused>>

(* a frame forced in its own journal (a large group's, a long one): the fsync forces every frame of the journal but
   the ones a failed fsync marked clean, and confirms it; nothing of it goes to the buffer *)
WriteOwn(d) == /\ CanWrite(d) /\ ~inflight[d]
               /\ jfile' = [jfile EXCEPT ![d] = Append(@, <<"ok", next[d]>>)]
               /\ jdisk' = [jdisk EXCEPT ![d] = (1..Len(jfile'[d])) \ jlimbo[d]]
               /\ ckpt' = [ckpt EXCEPT ![d] = Len(jfile'[d])]
               /\ acked' = acked \cup {<<d, next[d]>>}
               /\ next' = [next EXCEPT ![d] = @ + 1]
               /\ UNCHANGED <<jlimbo, jstop, inflight, buf, bdur, pending, inround, stopped, up, refused>>

(* the buffer's round: every frame that came meanwhile, in one frame of the buffer *)
Round == /\ up /\ ~stopped /\ ~inround /\ pending /= {}
         /\ buf' = Append(buf, pending) /\ pending' = {} /\ inround' = TRUE
         /\ UNCHANGED <<jfile, jdisk, jlimbo, ckpt, jstop, inflight, bdur, next, acked, stopped, up, refused>>

(* its fsync: every frame of the round confirmed *)
Force == /\ up /\ inround /\ ~stopped
         /\ bdur' = Len(buf) /\ inround' = FALSE /\ acked' = acked \cup buf[Len(buf)]
         /\ inflight' = [d \in DB |-> inflight[d] /\ ~\E f \in buf[Len(buf)] : f[1] = d]
         /\ UNCHANGED <<jfile, jdisk, jlimbo, ckpt, jstop, buf, pending, next, stopped, up, refused>>

(* F4 on the buffer: its fsync fails; nothing of the round is confirmed, nothing more until a restart; the round may
   stay in the page cache, marked clean, and a power loss may still lose it *)
ForceFails == /\ up /\ inround /\ ~stopped
              /\ stopped' = TRUE /\ inround' = FALSE
              /\ UNCHANGED <<jfile, jdisk, jlimbo, ckpt, jstop, inflight, buf, bdur, pending, next, acked, up, refused>>

(* a checkpoint of d: its journal forced (what a failed fsync marked clean is not written) *)
Checkpoint(d) == /\ up /\ (~jstop[d] \/ CkptAfterFailure) /\ Len(jfile[d]) > ckpt[d]
                 /\ jdisk' = [jdisk EXCEPT ![d] = (1..Len(jfile[d])) \ jlimbo[d]]
                 /\ ckpt' = [ckpt EXCEPT ![d] = Len(jfile[d])]
                 /\ UNCHANGED <<jfile, jlimbo, jstop, inflight, buf, bdur, pending, inround, next, acked, stopped, up, refused>>

(* F4 on a journal: its fsync fails, its unforced pages marked clean; the buffer stops *)
CheckpointFails(d) == /\ up /\ ~jstop[d] /\ Len(jfile[d]) > ckpt[d]
                      /\ jlimbo' = [jlimbo EXCEPT ![d] = (1..Len(jfile[d])) \ jdisk[d]]
                      /\ jstop' = [jstop EXCEPT ![d] = TRUE]
                      /\ stopped' = TRUE
                      /\ UNCHANGED <<jfile, jdisk, ckpt, inflight, buf, bdur, pending, inround, next, acked, up, refused>>

(* the oldest round goes once every frame in it is checkpointed (EarlyRecycle: once each is in its journal's page
   cache) *)
Recycle == /\ up /\ bdur >= 1
           /\ \A f \in buf[1] : IF EarlyRecycle THEN f[2] <= Len(jfile[f[1]]) ELSE f[2] <= ckpt[f[1]]
           /\ buf' = Tail(buf) /\ bdur' = bdur - 1
           /\ UNCHANGED <<jfile, jdisk, jlimbo, ckpt, jstop, inflight, pending, inround, next, acked, stopped, up, refused>>

(* F1: the process dies; the page cache keeps what was written *)
Kill == /\ up /\ up' = FALSE /\ inround' = FALSE
        /\ UNCHANGED <<jfile, jdisk, jlimbo, ckpt, jstop, inflight, buf, bdur, pending, next, acked, stopped, refused>>

FirstBad(f) == CHOOSE i \in 1..(Len(f) + 1) : (i > Len(f) \/ f[i][1] /= "ok") /\ \A j \in 1..(i - 1) : f[j][1] = "ok"

(* the journal's own rule (Journal.tla): a frame that checks after a bad one is damage: refuse *)
OwnRefuses(f) == \E j \in (FirstBad(f) + 1)..Len(f) : f[j][1] = "ok"

Max(s) == CHOOSE x \in s : \A y \in s : y <= x

(* the numbers of d's frames in the rounds kept *)
Kept(d, rounds) == {f[2] : f \in {g \in UNION {rounds[r] : r \in 1..Len(rounds)} : g[1] = d}}

(* the last frame the buffer kept of d (0 if none) *)
Hi(d, rounds) == IF Kept(d, rounds) = {} THEN 0 ELSE Max(Kept(d, rounds))

(* what follows it in d's journal, read by the journal's own rule *)
After(js, d, rounds) == IF Hi(d, rounds) >= Len(js[d]) THEN << >> ELSE SubSeq(js[d], Hi(d, rounds) + 1, Len(js[d]))

(* recovery refuses d: a frame before the buffer's last one that the buffer does not hold does not check (it was
   forced: damage), or the journal's own rule refuses what follows *)
Refuses(js, d, rounds) ==
  IF TrustJournal THEN OwnRefuses(js[d])
  ELSE \/ \E i \in 1..Hi(d, rounds) : i \notin Kept(d, rounds) /\ (i > Len(js[d]) \/ js[d][i][1] /= "ok")
       \/ OwnRefuses(After(js, d, rounds))

Recovered(js, d, rounds) ==
  IF TrustJournal THEN SubSeq(js[d], 1, FirstBad(js[d]) - 1)
  ELSE [i \in 1..Hi(d, rounds) |-> <<"ok", i>>] \o SubSeq(After(js, d, rounds), 1, FirstBad(After(js, d, rounds)) - 1)

(* recovery from what survived: the buffer's rounds kept, each journal as read; everything it writes is forced, and
   the buffer emptied *)
Recovery(js, rounds) ==
  IF \E d \in DB : Refuses(js, d, rounds)
  THEN /\ refused' = TRUE /\ up' = FALSE
       /\ UNCHANGED <<jfile, jdisk, jlimbo, ckpt, jstop, inflight, buf, bdur, pending, inround, next, acked, stopped>>
  ELSE /\ jfile' = [d \in DB |-> Recovered(js, d, rounds)]
       /\ jdisk' = [d \in DB |-> 1..Len(jfile'[d])]
       /\ jlimbo' = [d \in DB |-> {}]
       /\ ckpt' = [d \in DB |-> Len(jfile'[d])]
       /\ jstop' = [d \in DB |-> FALSE]
       /\ inflight' = [d \in DB |-> FALSE]
       /\ buf' = << >> /\ bdur' = 0 /\ pending' = {} /\ inround' = FALSE
       /\ next' = [d \in DB |-> Len(jfile'[d]) + 1]
       /\ stopped' = FALSE /\ up' = TRUE /\ refused' = FALSE
       /\ UNCHANGED acked

(* recovery after a process death, in the same boot: the page cache, whole *)
Recover == /\ ~up /\ ~refused /\ Recovery(jfile, buf)

(* F2: a power loss, then recovery from the disk: each journal frame the disk may not hold is kept or not (lost or
   torn: it does not check), each its own; the rounds after the forced ones are kept up to some round, and not after *)
Crash ==
  /\ ~refused
  /\ \E keep \in [{<<d, i>> : d \in DB, i \in 1..MaxFrames} -> BOOLEAN], kb \in 0..(Len(buf) - bdur) :
       LET js == [d \in DB |-> [i \in 1..Len(jfile[d]) |->
                    IF i \in jdisk[d] \/ keep[<<d, i>>] THEN jfile[d][i] ELSE <<"torn", jfile[d][i][2]>>]]
       IN Recovery(js, SubSeq(buf, 1, bdur + kb))

Next == \/ \E d \in DB : WriteFrame(d) \/ WriteOwn(d) \/ Checkpoint(d) \/ CheckpointFails(d)
        \/ Round \/ Force \/ ForceFails \/ Recycle \/ Kill \/ Recover \/ Crash

Spec == Init /\ [][Next]_vars

(* G1: every confirmed frame is in its journal, at its place, whenever the server runs *)
Durable == up => \A f \in acked : f[2] <= Len(jfile[f[1]]) /\ jfile[f[1]][f[2]] = <<"ok", f[2]>>

(* G3: each journal holds frames 1..k in order, none twice, none torn *)
Prefix == \A d \in DB : \A i \in 1..Len(jfile[d]) : jfile[d][i] = <<"ok", i>>

(* G6: no damage happens here, so no database may refuse to open *)
NeverRefused == ~refused

(* a checkpoint covers only frames the disk holds *)
CheckpointOnDisk == \A d \in DB : 1..ckpt[d] \subseteq jdisk[d]

TypeOK == /\ \A d \in DB : Len(jfile[d]) <= MaxFrames /\ ckpt[d] <= Len(jfile[d]) /\ jlimbo[d] \subseteq 1..MaxFrames
          /\ bdur <= Len(buf) /\ acked \subseteq DB \X (1..MaxFrames)
=============================================================================
