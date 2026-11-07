---------------------------- MODULE Journal ----------------------------
(* The journal protocol of one database (docs/theory.md, section 1), under the faults of docs/guarantees.md:
   F1/F2 a crash at any moment (the frame being written is lost, kept, or torn), F3 a durable frame damaged in
   silence, F4 a failed fsync. Frames are appended one at a time, each forced before the next, acknowledged after its
   fsync; recovery keeps the frames before the first one that does not check, refuses to open when a valid frame
   follows a bad one, and cuts a bad newest frame (the documented residual of G6).
   Checked by tools/tlc.sh (bounds in Journal.cfg). *)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS MaxFrames, MaxDamage

VARIABLES
  file,      \* the frames a reader sees: <<"ok", n>>, <<"torn", n>>, or damaged after it was durable: <<"badbody", n>>
             \* (its header still checks) or <<"badhead", n>>
  durable,   \* how many frames a finished fsync covers
  acked,     \* the frames acknowledged to clients
  next,      \* the number of the next frame
  writing,   \* a frame is written, its fsync not finished
  stopped,   \* an fsync failed: nothing more is acknowledged until a restart (G10)
  refused,   \* recovery found damage and refused to open (G6)
  residual,  \* acknowledged frames cut because the damage hit the newest frame (the residual of G6)
  damage     \* how many F3 faults happened

vars == <<file, durable, acked, next, writing, stopped, refused, residual, damage>>

Init == /\ file = << >> /\ durable = 0 /\ acked = {} /\ next = 1 /\ writing = FALSE
        /\ stopped = FALSE /\ refused = FALSE /\ residual = {} /\ damage = 0

Write == /\ ~refused /\ ~stopped /\ ~writing /\ next <= MaxFrames /\ durable = Len(file)
          /\ file' = Append(file, <<"ok", next>>) /\ next' = next + 1 /\ writing' = TRUE
          /\ UNCHANGED <<durable, acked, stopped, refused, residual, damage>>

Sync == /\ writing /\ ~stopped /\ ~refused
        /\ durable' = Len(file) /\ writing' = FALSE /\ acked' = acked \cup {file[Len(file)][2]}
        /\ UNCHANGED <<file, next, stopped, refused, residual, damage>>

(* F4: the fsync fails; the frame is not durable, the database stops and never retries *)
SyncFails == /\ writing /\ ~stopped /\ ~refused
             /\ stopped' = TRUE
             /\ UNCHANGED <<file, durable, acked, next, writing, refused, residual, damage>>

(* F3: a durable frame changes in silence *)
Damage == /\ ~refused /\ damage < MaxDamage
          /\ \E i \in 1..durable, kind \in {"badbody", "badhead"} :
               file[i][1] = "ok" /\ file' = [file EXCEPT ![i] = <<kind, i>>]
          /\ damage' = damage + 1
          /\ UNCHANGED <<durable, acked, next, writing, stopped, refused, residual>>

FirstBad(f) == IF \E i \in 1..Len(f) : f[i][1] /= "ok"
               THEN CHOOSE i \in 1..Len(f) : f[i][1] /= "ok" /\ \A j \in 1..(i-1) : f[j][1] = "ok"
               ELSE Len(f) + 1

(* F1/F2: a crash, then recovery *)
Crash ==
  /\ ~refused
  /\ \E keep \in {"lost", "kept", "torn"} :
       LET last == file[Len(file)]
           survived == IF ~writing \/ keep = "kept" THEN file
                       ELSE IF keep = "lost" THEN SubSeq(file, 1, durable)
                       ELSE Append(SubSeq(file, 1, durable), <<"torn", last[2]>>)
           b == FirstBad(survived)
           \* a frame header that checks after b proves b was written whole: frames are written one after the other
           validAfter == \E j \in (b+1)..Len(survived) : survived[j][1] \in {"ok", "badbody"}
           cut == SubSeq(survived, 1, b - 1)
       IN IF b <= Len(survived) /\ validAfter
          THEN /\ refused' = TRUE
               /\ UNCHANGED <<file, durable, acked, next, writing, stopped, residual, damage>>
          ELSE /\ file' = cut /\ durable' = Len(cut) /\ next' = Len(cut) + 1
               /\ writing' = FALSE /\ stopped' = FALSE /\ refused' = FALSE
               /\ residual' = residual \cup {survived[j][2] : j \in {k \in b..Len(survived) : survived[k][1] \in {"badbody", "badhead"}}}
               /\ UNCHANGED <<acked, damage>>

Next == Write \/ Sync \/ SyncFails \/ Damage \/ Crash

Spec == Init /\ [][Next]_vars

(* G1: an acknowledged frame survives every crash and recovery, unless the database refused to open (G6) or it is
   the residual (damage of the newest frame) *)
Durable == refused \/ \A a \in acked \ residual : a <= Len(file) /\ file[a][2] = a

(* G3: the file holds frames 1..n in order, and the next frame follows them *)
Prefix == /\ \A i \in 1..Len(file) : file[i][2] = i
          /\ next = Len(file) + 1

(* G2: a torn frame is never kept as data: after recovery none is left *)
NoTornData == \A i \in 1..Len(file) : file[i][1] /= "torn"

(* G10: after a failed fsync nothing beyond the durable frames is acknowledged *)
StopSafe == stopped => \A a \in acked \ residual : a <= durable

(* G6: what a cut loses was damaged itself: at most one frame per damage *)
ResidualBound == Cardinality(residual) <= damage

TypeOK == durable <= Len(file) /\ Len(file) <= MaxFrames /\ acked \subseteq 1..MaxFrames
=============================================================================
