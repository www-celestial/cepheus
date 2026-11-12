----------------------------- MODULE Merge -----------------------------
(* The protocol by which a merge's file replaces runs (docs/book/theory.md, sections 8 and 9; G12 in docs/book/guarantees.md),
   with the journal abstracted to the groups written (in the page cache) and the groups durable. The state on disk
   is a chain of runs, each the changes of groups lo+1..hi on top of the state at lo, named by its (lo, hi). Faults: F1
   a process death (the page cache stays, to be lost at a later power loss), F2 a power loss (unforced bytes lost, a
   prefix of a directory's name changes since its last fsync kept), F4 a failed fsync of the journal (the database
   stops, and the frames it covered are marked clean in the page cache without reaching the disk: a later fsync does
   not write them).

   A merge takes the newest k runs of the process's chain (k = 0: the delta alone) and writes the run (lo, work), lo
   the end of the run below them (0 when it takes them all), under a temporary name (in the page cache); it forces
   it, renames it to its name only when its group is durable and nothing failed, forces the directory, then removes
   the runs it replaced. A clean close leaves a marker (not forced) once everything is durable, and only if no fsync
   failed (MarkerOnlyIfClean). Recovery removes the marker if it is there; if it is not, it forces the journal first
   (what a killed process wrote and did not force: ForceAtRecovery), writing its newest frame again so that the fsync
   writes what a failed fsync marked clean (RewriteAtRecovery); then it takes the chain of named runs from 0 that
   reaches the newest group, and replays the journal after it. After a failed fsync the writer also cuts the journal
   back to its durable frames (CutJournal; its own failures are in spec/Journal.tla).

   Checked by tools/tlc.sh (bounds in Merge.cfg). With any one of ForceAtRecovery, InstallWhenDurable,
   ForceBeforeRename, MarkerOnlyIfClean, RewriteAtRecovery set to FALSE, TLC finds a counterexample: each of the five
   rules is needed. *)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS MaxGroups, ForceAtRecovery, InstallWhenDurable, ForceBeforeRename, MarkerOnlyIfClean, RewriteAtRecovery

VARIABLES
  work,       \* the working view's group (prepared, runs ahead of the journal)
  jw,         \* groups written to the journal (durable or in the page cache)
  jd,         \* groups durable in the journal
  acked,      \* the newest group confirmed to a client
  published,  \* the newest group readers may see
  stopped,    \* a journal fsync failed (G10)
  limbo,      \* the journal's frames jd+1..jw were marked clean by a failed fsync: an fsync alone does not write them
  up,         \* the process runs
  chain,      \* the runs the process reads, bottom first: a sequence of <<lo, hi>>
  tmp,        \* the run a merge is writing, <<0, 0>> for none
  took,       \* how many of the chain's newest runs it replaces
  cont,       \* a run file's content: "none", "cache" (written, not forced), "durable", "garbage"
  names,      \* the run names a reader of the directory sees
  dnames,     \* the run names that survive a power loss
  pending,    \* the directory's name changes since its last fsync: <<"link" or "unlink", a set of runs>>
  pc,         \* where the install is: "idle", "renamed", "pruning"
  gone,       \* the runs the install replaced, removed once the new name is durable
  setaside,   \* recovery met a named run whose content is not whole (a mix): G12 is broken
  refused,    \* recovery met a run newer than the journal: G12 is broken
  mk,         \* the clean-close marker, as a reader sees the directory
  dmk         \* the marker as a power loss would leave it

markers == <<mk, dmk>>
vars == <<work, jw, jd, acked, published, stopped, limbo, up, chain, tmp, took, cont, names, dnames, pending, pc, gone,
          setaside, refused, mk, dmk>>

Runs == {r \in (0..MaxGroups) \X (1..MaxGroups) : r[1] < r[2]}
None == <<0, 0>>

RECURSIVE Apply(_, _)
Apply(S, ops) == IF ops = << >> THEN S
                 ELSE LET op == Head(ops) IN
                      Apply(IF op[1] = "link" THEN S \cup op[2] ELSE S \ op[2], Tail(ops))

Top(c) == IF c = << >> THEN 0 ELSE c[Len(c)][2]
Range(c) == {c[i] : i \in 1..Len(c)}

(* the chains of named runs from 0 (each run resting on the end of the one below), as sequences bottom first *)
RECURSIVE ChainsFrom(_, _, _)
ChainsFrom(S, lo, n) == {<< >>} \cup
  (IF n = 0 THEN {} ELSE UNION {{<<r>> \o c : c \in ChainsFrom(S, r[2], n - 1)} : r \in {x \in S : x[1] = lo}})
Chains(S) == ChainsFrom(S, 0, MaxGroups)
(* recovery's pick: the chain reaching the newest group, with the fewest runs *)
Best(S) == CHOOSE c \in Chains(S) : \A d \in Chains(S) : Top(d) < Top(c) \/ (Top(d) = Top(c) /\ Len(c) <= Len(d))

Init == /\ work = 0 /\ jw = 0 /\ jd = 0 /\ acked = 0 /\ published = 0 /\ stopped = FALSE /\ limbo = FALSE /\ up = TRUE
        /\ chain = << >> /\ tmp = None /\ took = 0 /\ cont = [r \in Runs |-> "none"] /\ names = {} /\ dnames = {}
        /\ pending = << >> /\ pc = "idle" /\ gone = {} /\ setaside = FALSE /\ refused = FALSE /\ mk = FALSE /\ dmk = FALSE

Prepare == /\ up /\ ~stopped /\ work < MaxGroups /\ work' = work + 1
           /\ UNCHANGED <<jw, jd, acked, published, stopped, limbo, up, chain, tmp, took, cont, names, dnames, pending, pc,
                          gone, setaside, refused>> /\ UNCHANGED markers

(* a frame of every prepared group, written; forced by Sync *)
WriteFrame == /\ up /\ ~stopped /\ jw = jd /\ jw < work /\ jw' = work
              /\ UNCHANGED <<work, jd, acked, published, stopped, limbo, up, chain, tmp, took, cont, names, dnames,
                             pending, pc, gone, setaside, refused>> /\ UNCHANGED markers

Sync == /\ up /\ ~stopped /\ jd < jw /\ jd' = jw /\ acked' = jw /\ published' = jw
        /\ UNCHANGED <<work, jw, stopped, limbo, up, chain, tmp, took, cont, names, dnames, pending, pc, gone, setaside,
                       refused>> /\ UNCHANGED markers

SyncFails == /\ up /\ ~stopped /\ jd < jw /\ stopped' = TRUE /\ limbo' = TRUE
             /\ UNCHANGED <<work, jw, jd, acked, published, up, chain, tmp, took, cont, names, dnames, pending, pc, gone,
                            setaside, refused>> /\ UNCHANGED markers

(* after a failed fsync, the writer cuts the journal back to its durable frames (the cut forced) *)
CutJournal == /\ up /\ stopped /\ jd < jw /\ jw' = jd /\ limbo' = FALSE
              /\ UNCHANGED <<work, jd, acked, published, stopped, up, chain, tmp, took, cont, names, dnames, pending, pc,
                             gone, setaside, refused>> /\ UNCHANGED markers

(* a merge from the working view, which may hold groups not yet durable: the newest k runs and the delta *)
Begin == /\ up /\ tmp = None /\ pc = "idle" /\ work > Top(chain)
         /\ \E k \in 0..Len(chain) :
              LET lo == IF k = Len(chain) THEN 0 ELSE chain[Len(chain) - k][2] IN
              /\ <<lo, work>> \notin names \cup dnames
              /\ tmp' = <<lo, work>> /\ took' = k /\ cont' = [cont EXCEPT ![<<lo, work>>] = "cache"]
         /\ UNCHANGED <<work, jw, jd, acked, published, stopped, limbo, up, chain, names, dnames, pending, pc, gone,
                        setaside, refused>> /\ UNCHANGED markers

Force == /\ up /\ tmp /= None /\ cont[tmp] = "cache" /\ cont' = [cont EXCEPT ![tmp] = "durable"]
         /\ UNCHANGED <<work, jw, jd, acked, published, stopped, limbo, up, chain, tmp, took, names, dnames, pending, pc,
                        gone, setaside, refused>> /\ UNCHANGED markers

(* the install: with nothing in flight and nothing failed, so that the merge's group is durable *)
Rename == /\ up /\ tmp /= None /\ pc = "idle"
          /\ (cont[tmp] = "durable" \/ (~ForceBeforeRename /\ cont[tmp] = "cache"))
          /\ (~InstallWhenDurable \/ (~stopped /\ published >= tmp[2]))
          /\ names' = names \cup {tmp} /\ pending' = Append(pending, <<"link", {tmp}>>)
          /\ gone' = Range(SubSeq(chain, Len(chain) - took + 1, Len(chain)))
          /\ chain' = SubSeq(chain, 1, Len(chain) - took) \o <<tmp>> /\ tmp' = None /\ took' = 0 /\ pc' = "renamed"
          /\ UNCHANGED <<work, jw, jd, acked, published, stopped, limbo, up, cont, dnames, setaside, refused>>
          /\ UNCHANGED markers

(* the database stopped: the merge is abandoned (its file removed) *)
Abandon == /\ up /\ tmp /= None /\ stopped /\ tmp' = None /\ took' = 0
           /\ UNCHANGED <<work, jw, jd, acked, published, stopped, limbo, up, chain, cont, names, dnames, pending, pc,
                          gone, setaside, refused>> /\ UNCHANGED markers

(* the directory forced; after the rename, the replaced runs are removed (their removal made durable by the next
   fsync of the directory): only once the new name is durable *)
SyncDir == /\ up /\ pc \in {"renamed", "pruning"}
           /\ dnames' = Apply(dnames, pending)
           /\ IF pc = "renamed" /\ gone /= {}
              THEN /\ names' = names \ gone /\ pending' = <<<<"unlink", gone>>>> /\ pc' = "pruning"
              ELSE /\ names' = names /\ pending' = << >> /\ pc' = "idle"
           /\ gone' = {}
           /\ UNCHANGED <<work, jw, jd, acked, published, stopped, limbo, up, chain, tmp, took, cont, setaside, refused>>
           /\ UNCHANGED markers

(* F1: the process dies; written bytes and name changes stay in the page cache *)
Kill == /\ up /\ up' = FALSE /\ tmp' = None /\ took' = 0 /\ pc' = "idle" /\ gone' = {}
        /\ UNCHANGED <<work, jw, jd, acked, published, stopped, limbo, chain, cont, names, dnames, pending, setaside,
                       refused>> /\ UNCHANGED markers

(* a close, once the syncer is idle and no merge is under way: every frame written is forced, unless an fsync failed
   (stopped: its frame stays unforced); the marker only then if not MarkerOnlyIfClean; its creation is not forced *)
Close == /\ up /\ (jd = jw \/ stopped) /\ tmp = None /\ pc = "idle"
         /\ mk' = (~stopped \/ ~MarkerOnlyIfClean) /\ up' = FALSE
         /\ UNCHANGED <<work, jw, jd, acked, published, stopped, limbo, chain, tmp, took, cont, names, dnames, pending, pc,
                        gone, setaside, refused, dmk>>

(* F2: a power loss; frames written and not forced may or may not reach the disk; a prefix of the name changes; the
   marker's last change kept or not *)
PowerLoss == /\ \E m \in {mk, dmk} : mk' = m /\ dmk' = m
             /\ \E kept \in jd..jw, k \in 0..Len(pending) :
                  /\ jw' = kept /\ jd' = kept
                  /\ dnames' = Apply(dnames, SubSeq(pending, 1, k)) /\ names' = Apply(dnames, SubSeq(pending, 1, k))
             /\ cont' = [r \in Runs |-> IF cont[r] = "cache" THEN "garbage" ELSE cont[r]]
             /\ pending' = << >> /\ up' = FALSE /\ tmp' = None /\ took' = 0 /\ pc' = "idle" /\ gone' = {}
             /\ limbo' = FALSE
             /\ UNCHANGED <<work, acked, published, stopped, chain, setaside, refused>>

(* recovery: the marker removed if there (its removal not forced), else the journal forced, its newest frame written
   again first (without that, the frames a failed fsync marked clean stay off the disk); the chain of named runs that
   reaches the newest group taken, the journal replayed after it *)
Recover == /\ ~up
           /\ mk' = FALSE /\ UNCHANGED dmk
           /\ LET forced == ForceAtRecovery /\ ~mk /\ (RewriteAtRecovery \/ ~limbo)
                  c == Best(names)
              IN /\ jd' = IF forced THEN jw ELSE jd
                 /\ setaside' = (setaside \/ \E r \in Range(c) : cont[r] /= "durable")
                 /\ refused' = (refused \/ Top(c) > jw)
                 /\ chain' = c /\ work' = jw /\ published' = jw /\ limbo' = (limbo /\ ~forced)
           /\ up' = TRUE /\ stopped' = FALSE /\ tmp' = None /\ took' = 0 /\ pc' = "idle" /\ gone' = {}
           /\ UNCHANGED <<jw, acked, cont, names, dnames, pending>>

Next == Prepare \/ WriteFrame \/ Sync \/ SyncFails \/ CutJournal \/ Begin \/ Force \/ Rename \/ Abandon \/ SyncDir
        \/ Kill \/ Close \/ PowerLoss \/ Recover

Spec == Init /\ [][Next]_vars

(* G12: a run name, durable or not, never points at content that is not whole and forced *)
NoMix == ~setaside /\ \A r \in names \cup dnames : cont[r] = "durable"

(* G12: a run name exists only for groups the journal holds durably; recovery never meets one ahead of it *)
SnapshotInJournal == ~refused /\ \A r \in names \cup dnames : r[2] <= jd

(* G12 for several runs: the runs the process reads are named, and form a chain from 0 *)
ChainNamed == up => /\ Range(chain) \subseteq names
                    /\ \A i \in 1..Len(chain) : chain[i][1] = (IF i = 1 THEN 0 ELSE chain[i - 1][2])

(* G5: what readers see is durable, after a recovery too *)
PublishedDurable == up => published <= jd

(* G1: a confirmed group is durable *)
AckedDurable == acked <= jd

TypeOK == /\ work \in 0..MaxGroups /\ jd <= jw /\ (jw <= work \/ ~up)
          /\ cont \in [Runs -> {"none", "cache", "durable", "garbage"}]
=============================================================================
