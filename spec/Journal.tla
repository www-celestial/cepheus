---------------------------- MODULE Journal ----------------------------
(* The journal protocol of one database, abstracted: frames are appended to a file, forced by fsync, acknowledged
   after their fsync; a crash keeps the durable frames and any prefix of the unsynced ones, the first lost one
   possibly torn; recovery keeps the frames up to the first one that does not check.
   Invariants: Durable (G1), Prefix (G3). Check with TLC, for example MaxFrames = 4:
     java -cp tla2tools.jar tlc2.TLC -config Journal.cfg Journal.tla *)
EXTENDS Naturals, Sequences

CONSTANT MaxFrames

VARIABLES
  file,      \* the frames as a reader of the file sees them: <<"ok", i>> or <<"torn", i>>
  durable,   \* how many frames of file are covered by a finished fsync
  acked,     \* the frames acknowledged to clients
  next,      \* the number of the next frame to write
  writing    \* a write is in progress (the writer appends one frame, then forces it)

vars == <<file, durable, acked, next, writing>>

Init == file = << >> /\ durable = 0 /\ acked = {} /\ next = 1 /\ writing = FALSE

(* append one frame; only after the previous one was forced (invariant I1 of docs/theory.md) *)
Append ==
  /\ ~writing /\ next <= MaxFrames /\ durable = Len(file)
  /\ file' = Append(file, <<"ok", next>>)
  /\ next' = next + 1 /\ writing' = TRUE
  /\ UNCHANGED <<durable, acked>>

(* the fsync of the frame returns: it is durable, then acknowledged *)
Sync ==
  /\ writing
  /\ durable' = Len(file) /\ writing' = FALSE
  /\ acked' = acked \cup {file[Len(file)][2]}
  /\ UNCHANGED <<file, next>>

(* a power loss: the unsynced frame is lost, kept, or torn; then recovery cuts at the first frame that does not
   check, and the writer goes on from there *)
Recover(f) ==
  LET firstBad == IF \E i \in 1..Len(f) : f[i][1] = "torn"
                  THEN CHOOSE i \in 1..Len(f) : f[i][1] = "torn" /\ \A j \in 1..(i-1) : f[j][1] = "ok"
                  ELSE Len(f) + 1
  IN SubSeq(f, 1, firstBad - 1)

Crash ==
  \E keep \in {"lost", "kept", "torn"} :
    LET survived == IF ~writing \/ keep = "kept" THEN file
                    ELSE IF keep = "lost" THEN SubSeq(file, 1, durable)
                    ELSE Append(SubSeq(file, 1, durable), <<"torn", file[Len(file)][2]>>)
        r == Recover(survived)
    IN /\ file' = r /\ durable' = Len(r) /\ next' = Len(r) + 1 /\ writing' = FALSE
       /\ UNCHANGED acked

Next == Append \/ Sync \/ Crash

Spec == Init /\ [][Next]_vars

(* G1: every acknowledged frame is in the file, intact, after any crash and recovery *)
Durable == \A a \in acked : a <= durable /\ file[a] = <<"ok", a>>

(* G3: the file holds frames 1..n in order *)
Prefix == \A i \in 1..Len(file) : file[i][2] = i

TypeOK == durable <= Len(file) /\ next = Len(file) + 1
=============================================================================
