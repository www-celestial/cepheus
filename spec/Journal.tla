---------------------------- MODULE Journal ----------------------------
(* The journal protocol of one database (docs/theory.md, section 1), under the faults of docs/guarantees.md:
   F1 a process death (what it wrote stays in the page cache, readable by the next process, lost at a later power
   loss), F2 a power loss (what the disk may not hold is lost, kept, or torn), F3 a durable frame damaged in silence,
   F4 a failed fsync as Linux file systems do it (Rebello et al., ATC 2020): the pages are marked clean without
   reaching the disk; ext4 and XFS keep their bytes in memory, so a later fsync succeeds without writing them, and
   Btrfs undoes the write in memory too.

   Frames are appended one at a time, each forced before the next, acknowledged after its fsync. After a failed fsync
   the writer stops (G10) and cuts the file back to its durable end (CutInWriter); the cut itself may fail. Recovery
   reads what a reader of the file sees (the page cache after a process death, the disk after a power loss), keeps the
   frames before the first one that does not check, refuses to open when a valid frame follows a bad one, cuts a bad
   newest frame (the residual of G6), and, after a process death, writes its newest frame again before forcing it
   (RewriteAtRecovery), so that the fsync really writes it.

   Checked by tools/tlc.sh (bounds in Journal.cfg). With RewriteAtRecovery FALSE, TLC finds a counterexample to
   PublishedOnDisk (G13) even with the writer's cut: the process dies between the failed fsync and the cut. *)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS MaxFrames, MaxDamage, RewriteAtRecovery, CutInWriter

VARIABLES
  file,      \* the frames a reader of the file sees: <<"ok", n>>, <<"torn", n>> (does not check), or damaged after it
             \* was durable: <<"badbody", n>> (its header still checks) or <<"badhead", n>>
  offdisk,   \* the positions of file whose bytes the disk may not hold: written and not forced, or a failed fsync's
  limbo,     \* the positions of offdisk that a failed fsync marked clean: a later fsync does not write them
  ghost,     \* frames cut from the page cache by a truncation whose fsync failed: the disk may still hold them
  wdur,      \* the writer's durable end: the frames up to its last successful fsync
  acked,     \* the frames acknowledged to clients
  published, \* readers may see the frames 1..published
  next,      \* the number of the next frame
  writing,   \* a frame is written, its fsync not finished
  stopped,   \* an fsync failed: nothing more is acknowledged until a restart (G10)
  cutting,   \* the writer still has to cut the file back to wdur
  up,        \* the process runs
  refused,   \* recovery found damage and refused to open (G6)
  residual,  \* acknowledged frames cut because the damage hit the newest frame (the residual of G6)
  damage     \* how many F3 faults happened

vars == <<file, offdisk, limbo, ghost, wdur, acked, published, next, writing, stopped, cutting, up, refused, residual,
          damage>>

Init == /\ file = << >> /\ offdisk = {} /\ limbo = {} /\ ghost = << >> /\ wdur = 0 /\ acked = {} /\ published = 0
        /\ next = 1 /\ writing = FALSE /\ stopped = FALSE /\ cutting = FALSE /\ up = TRUE /\ refused = FALSE
        /\ residual = {} /\ damage = 0

Write == /\ up /\ ~refused /\ ~stopped /\ ~writing /\ next <= MaxFrames
         /\ file' = Append(file, <<"ok", next>>) /\ offdisk' = offdisk \cup {Len(file) + 1}
         /\ next' = next + 1 /\ writing' = TRUE
         /\ UNCHANGED <<limbo, ghost, wdur, acked, published, stopped, cutting, up, refused, residual, damage>>

(* the fsync writes what is dirty, not what a failed fsync marked clean *)
Sync == /\ up /\ writing /\ ~stopped
        /\ offdisk' = limbo /\ wdur' = Len(file) /\ writing' = FALSE
        /\ acked' = acked \cup {file[Len(file)][2]} /\ published' = Len(file)
        /\ UNCHANGED <<file, limbo, ghost, next, stopped, cutting, up, refused, residual, damage>>

(* F4: the fsync fails; its pages are marked clean, their bytes kept in memory (ext4, XFS) or undone (Btrfs) *)
SyncFails == /\ up /\ writing /\ ~stopped
             /\ \E revert \in BOOLEAN :
                  IF revert THEN /\ file' = SubSeq(file, 1, Len(file) - 1)
                                 /\ offdisk' = offdisk \ {Len(file)} /\ limbo' = limbo \ {Len(file)}
                  ELSE /\ file' = file /\ offdisk' = offdisk /\ limbo' = offdisk
             /\ stopped' = TRUE /\ writing' = FALSE /\ cutting' = CutInWriter
             /\ UNCHANGED <<ghost, wdur, acked, published, next, up, refused, residual, damage>>

(* the writer's cut after a failed fsync: truncated to its durable end and forced; or the truncation failed; or its
   fsync failed (the page cache is cut, the disk may still hold the tail) *)
Cut == /\ up /\ cutting
       /\ \E how \in {"durable", "notrunc", "nofsync"} :
            IF how = "notrunc" THEN UNCHANGED <<file, offdisk, limbo, ghost>>
            ELSE /\ file' = SubSeq(file, 1, wdur) /\ offdisk' = offdisk \cap 1..wdur /\ limbo' = limbo \cap 1..wdur
                 /\ ghost' = IF how = "durable" THEN << >> ELSE SubSeq(file, wdur + 1, Len(file))
       /\ cutting' = FALSE
       /\ UNCHANGED <<wdur, acked, published, next, writing, stopped, up, refused, residual, damage>>

(* F3: a durable frame changes in silence *)
Damage == /\ ~refused /\ damage < MaxDamage
          /\ \E i \in 1..Len(file) :
               /\ i \notin offdisk /\ file[i][1] = "ok"
               /\ \E kind \in {"badbody", "badhead"} : file' = [file EXCEPT ![i] = <<kind, file[i][2]>>]
          /\ damage' = damage + 1
          /\ UNCHANGED <<offdisk, limbo, ghost, wdur, acked, published, next, writing, stopped, cutting, up, refused,
                         residual>>

FirstBad(f) == IF \E i \in 1..Len(f) : f[i][1] /= "ok"
               THEN CHOOSE i \in 1..Len(f) : f[i][1] /= "ok" /\ \A j \in 1..(i-1) : f[j][1] = "ok"
               ELSE Len(f) + 1

(* a frame header that checks after the first bad frame proves it was written whole: damage, refuse *)
Refuses(f) == LET b == FirstBad(f) IN b <= Len(f) /\ \E j \in (b+1)..Len(f) : f[j][1] \in {"ok", "badbody"}

CutBad(f) == SubSeq(f, 1, FirstBad(f) - 1)

DamagedCut(f) == {f[j][2] : j \in {k \in FirstBad(f)..Len(f) : f[k][1] \in {"badbody", "badhead"}}}

(* F1: the process dies; what it wrote stays in the page cache *)
Kill == /\ up /\ up' = FALSE /\ writing' = FALSE /\ cutting' = FALSE
        /\ UNCHANGED <<file, offdisk, limbo, ghost, wdur, acked, published, next, stopped, refused, residual, damage>>

(* recovery after a process death, in the same boot: it reads the page cache; its newest frame written again
   (RewriteAtRecovery) and the file forced; the force may fail (the open fails, its pages are marked clean) *)
Recover ==
  /\ ~up /\ ~refused
  /\ IF Refuses(file)
     THEN /\ refused' = TRUE
          /\ UNCHANGED <<file, offdisk, limbo, ghost, wdur, acked, published, next, writing, stopped, cutting, up,
                         residual, damage>>
     ELSE \E fails \in BOOLEAN :
          IF fails
          THEN /\ limbo' = offdisk
               /\ UNCHANGED <<file, offdisk, ghost, wdur, acked, published, next, writing, stopped, cutting, up, refused,
                              residual, damage>>
          ELSE LET c == CutBad(file)
                   still == IF RewriteAtRecovery THEN limbo \cap 1..(Len(c) - 1) ELSE limbo \cap 1..Len(c)
               IN /\ file' = c /\ offdisk' = still /\ limbo' = still /\ ghost' = << >>
                  /\ published' = Len(c) /\ wdur' = Len(c) /\ next' = Len(c) + 1
                  /\ up' = TRUE /\ stopped' = FALSE /\ writing' = FALSE /\ cutting' = FALSE
                  /\ residual' = residual \cup DamagedCut(file)
                  /\ UNCHANGED <<acked, refused, damage>>

(* F2: a power loss, then recovery after the reboot, which reads the disk: each frame the disk may not hold is kept
   or not (a frame not kept reads as one that does not check: zeros, or a torn write) *)
Crash ==
  /\ ~refused
  /\ \E keep \in [offdisk \cup ((Len(file) + 1)..(Len(file) + Len(ghost))) -> BOOLEAN] :
       LET onfile == [i \in 1..Len(file) |-> IF i \in offdisk /\ ~keep[i] THEN <<"torn", file[i][2]>> ELSE file[i]]
           ontail == [i \in 1..Len(ghost) |-> IF keep[Len(file) + i] THEN ghost[i] ELSE <<"torn", ghost[i][2]>>]
           survived == onfile \o ontail
       IN IF Refuses(survived)
          THEN /\ refused' = TRUE
               /\ UNCHANGED <<file, offdisk, limbo, ghost, wdur, acked, published, next, writing, stopped, cutting, up,
                              residual, damage>>
          ELSE LET c == CutBad(survived) IN
               /\ file' = c /\ offdisk' = {} /\ limbo' = {} /\ ghost' = << >>
               /\ published' = Len(c) /\ wdur' = Len(c) /\ next' = Len(c) + 1
               /\ up' = TRUE /\ stopped' = FALSE /\ writing' = FALSE /\ cutting' = FALSE
               /\ residual' = residual \cup DamagedCut(survived)
               /\ UNCHANGED <<acked, refused, damage>>

Next == Write \/ Sync \/ SyncFails \/ Cut \/ Damage \/ Kill \/ Recover \/ Crash

Spec == Init /\ [][Next]_vars

(* G1: an acknowledged frame is in the file and on the disk, unless the database refused to open (G6) or it is the
   residual (damage of the newest frame) *)
Durable == refused \/ \A a \in acked \ residual : a <= Len(file) /\ file[a][2] = a /\ a \notin offdisk

(* G1, G6: a refusal to open comes from damage only, never from a hole the protocol left *)
RefuseOnlyOnDamage == refused => damage > 0

(* G13 (G5 under F4): every frame readers may see is on the disk, so no later power loss takes it back *)
PublishedOnDisk == up => \A i \in 1..published : i <= Len(file) /\ i \notin offdisk

(* G3: the file holds frames 1..n in order, and a running writer's next frame follows them *)
Prefix == /\ \A i \in 1..Len(file) : file[i][2] = i
          /\ (up /\ ~stopped) => next = Len(file) + 1

(* G2: a torn frame is never kept as data: after recovery none is left *)
NoTornData == \A i \in 1..Len(file) : file[i][1] /= "torn"

(* G10: after a failed fsync nothing beyond the durable frames is acknowledged *)
StopSafe == stopped => \A a \in acked \ residual : a <= wdur

(* G6: what a cut loses was damaged itself: at most one frame per damage *)
ResidualBound == Cardinality(residual) <= damage

TypeOK == /\ Len(file) <= MaxFrames /\ acked \subseteq 1..MaxFrames /\ limbo \subseteq offdisk
          /\ offdisk \subseteq 1..Len(file) /\ wdur <= Len(file)
=============================================================================
