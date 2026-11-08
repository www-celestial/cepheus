----------------------------- MODULE Merge -----------------------------
(* The protocol by which a merge's file becomes the base (docs/theory.md, section 8; G12 in docs/guarantees.md), with
   the journal abstracted to the groups written (in the page cache) and the groups durable. Faults: F1 a process
   death (the page cache stays, to be lost at a later power loss), F2 a power loss (unforced bytes lost, a prefix of a
   directory's name changes since its last fsync kept), F4 a failed fsync of the journal (the database stops, and the
   frames it covered are marked clean in the page cache without reaching the disk: a later fsync does not write
   them).

   A merge writes the file of the working view's group under a temporary name (in the page cache), forces it, renames
   it to its name only when its group is durable and nothing failed, forces the directory, and then removes the
   snapshots beyond the newest Keep. A clean close leaves a marker (not forced) once everything is durable, and only
   if no fsync failed (MarkerOnlyIfClean). Recovery removes the marker if it is there; if it is not, it forces the
   journal first (what a killed process wrote and did not force: ForceAtRecovery), writing its newest frame again so
   that the fsync writes what a failed fsync marked clean (RewriteAtRecovery); then it loads the newest snapshot and
   replays the journal after it. After a failed fsync the writer also cuts the journal back to its durable frames
   (CutJournal; its own failures are in spec/Journal.tla).

   Checked by tools/tlc.sh (bounds in Merge.cfg). With any one of ForceAtRecovery, InstallWhenDurable,
   ForceBeforeRename, MarkerOnlyIfClean, RewriteAtRecovery set to FALSE, TLC finds a counterexample: each of the five
   rules is needed. *)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS MaxGroups, Keep, ForceAtRecovery, InstallWhenDurable, ForceBeforeRename, MarkerOnlyIfClean, RewriteAtRecovery

VARIABLES
  work,       \* the working view's group (prepared, runs ahead of the journal)
  jw,         \* groups written to the journal (durable or in the page cache)
  jd,         \* groups durable in the journal
  acked,      \* the newest group confirmed to a client
  published,  \* the newest group readers may see
  stopped,    \* a journal fsync failed (G10)
  limbo,      \* the journal's frames jd+1..jw were marked clean by a failed fsync: an fsync alone does not write them
  up,         \* the process runs
  tmp,        \* the group of the merge being written, 0 for none
  cont,       \* a snapshot file's content, by group: "none", "cache" (written, not forced), "durable", "garbage"
  names,      \* the snapshot names a reader of the directory sees
  dnames,     \* the snapshot names that survive a power loss
  pending,    \* the directory's name changes since its last fsync: <<"link" or "unlink", a set of groups>>
  pc,         \* where the install is: "idle", "renamed", "pruning"
  base,       \* the group of the snapshot the process reads (0: the empty base)
  setaside,   \* recovery met a snapshot name whose content is not whole (a mix): G12 is broken
  refused,    \* recovery found a snapshot newer than the journal: G12 is broken
  mk,         \* the clean-close marker, as a reader sees the directory
  dmk         \* the marker as a power loss would leave it

markers == <<mk, dmk>>
vars == <<work, jw, jd, acked, published, stopped, limbo, up, tmp, cont, names, dnames, pending, pc, base, setaside, refused,
          mk, dmk>>

Groups == 1..MaxGroups

RECURSIVE Apply(_, _)
Apply(S, ops) == IF ops = << >> THEN S
                 ELSE LET op == Head(ops) IN
                      Apply(IF op[1] = "link" THEN S \cup op[2] ELSE S \ op[2], Tail(ops))

Max(S) == IF S = {} THEN 0 ELSE CHOOSE g \in S : \A h \in S : h <= g

Init == /\ work = 0 /\ jw = 0 /\ jd = 0 /\ acked = 0 /\ published = 0 /\ stopped = FALSE /\ limbo = FALSE /\ up = TRUE
        /\ tmp = 0 /\ cont = [g \in Groups |-> "none"] /\ names = {} /\ dnames = {} /\ pending = << >>
        /\ pc = "idle" /\ base = 0 /\ setaside = FALSE /\ refused = FALSE /\ mk = FALSE /\ dmk = FALSE

Prepare == /\ up /\ ~stopped /\ work < MaxGroups /\ work' = work + 1
           /\ UNCHANGED <<limbo, jw, jd, acked, published, stopped, up, tmp, cont, names, dnames, pending, pc, base, setaside, refused>>
           /\ UNCHANGED markers

(* a frame of every prepared group, written; forced by Sync *)
WriteFrame == /\ up /\ ~stopped /\ jw = jd /\ jw < work /\ jw' = work
          /\ UNCHANGED <<limbo, work, jd, acked, published, stopped, up, tmp, cont, names, dnames, pending, pc, base, setaside, refused>>
           /\ UNCHANGED markers

Sync == /\ up /\ ~stopped /\ jd < jw /\ jd' = jw /\ acked' = jw /\ published' = jw
        /\ UNCHANGED <<limbo, work, jw, stopped, up, tmp, cont, names, dnames, pending, pc, base, setaside, refused>>
           /\ UNCHANGED markers

SyncFails == /\ up /\ ~stopped /\ jd < jw /\ stopped' = TRUE /\ limbo' = TRUE
             /\ UNCHANGED <<work, jw, jd, acked, published, up, tmp, cont, names, dnames, pending, pc, base, setaside, refused>>
           /\ UNCHANGED markers

(* after a failed fsync, the writer cuts the journal back to its durable frames (the cut forced) *)
CutJournal == /\ up /\ stopped /\ jd < jw /\ jw' = jd /\ limbo' = FALSE
              /\ UNCHANGED <<work, jd, acked, published, stopped, up, tmp, cont, names, dnames, pending, pc, base, setaside,
                             refused>>
              /\ UNCHANGED markers

(* a merge from the working view, which may hold groups not yet durable; one file per group *)
Begin == /\ up /\ tmp = 0 /\ pc = "idle" /\ work > base /\ work \notin names \cup dnames
         /\ tmp' = work /\ cont' = [cont EXCEPT ![work] = "cache"]
         /\ UNCHANGED <<limbo, work, jw, jd, acked, published, stopped, up, names, dnames, pending, pc, base, setaside, refused>>
           /\ UNCHANGED markers

Force == /\ up /\ tmp /= 0 /\ cont[tmp] = "cache" /\ cont' = [cont EXCEPT ![tmp] = "durable"]
         /\ UNCHANGED <<limbo, work, jw, jd, acked, published, stopped, up, tmp, names, dnames, pending, pc, base, setaside, refused>>
           /\ UNCHANGED markers

(* the install: with nothing in flight and nothing failed, so that the merge's group is durable *)
Rename == /\ up /\ tmp /= 0 /\ pc = "idle"
          /\ (cont[tmp] = "durable" \/ (~ForceBeforeRename /\ cont[tmp] = "cache"))
          /\ (~InstallWhenDurable \/ (~stopped /\ published >= tmp))
          /\ names' = names \cup {tmp} /\ pending' = Append(pending, <<"link", {tmp}>>)
          /\ base' = tmp /\ tmp' = 0 /\ pc' = "renamed"
          /\ UNCHANGED <<limbo, work, jw, jd, acked, published, stopped, up, cont, dnames, setaside, refused>>
           /\ UNCHANGED markers

(* the database stopped: the merge is abandoned (its file removed) *)
Abandon == /\ up /\ tmp /= 0 /\ stopped /\ tmp' = 0
           /\ UNCHANGED <<limbo, work, jw, jd, acked, published, stopped, up, cont, names, dnames, pending, pc, base, setaside, refused>>
           /\ UNCHANGED markers

(* the directory forced; after the rename, the snapshots beyond the newest Keep are removed (their removal made
   durable by the next fsync of the directory): only once the new name is durable *)
SyncDir == /\ up /\ pc \in {"renamed", "pruning"}
           /\ dnames' = Apply(dnames, pending)
           /\ LET old == {g \in names : Cardinality({h \in names : h > g}) >= Keep} IN
              IF pc = "renamed" /\ old /= {}
              THEN /\ names' = names \ old /\ pending' = <<<<"unlink", old>>>> /\ pc' = "pruning"
              ELSE /\ names' = names /\ pending' = << >> /\ pc' = "idle"
           /\ UNCHANGED <<limbo, work, jw, jd, acked, published, stopped, up, tmp, cont, base, setaside, refused>>
           /\ UNCHANGED markers

(* F1: the process dies; written bytes and name changes stay in the page cache *)
Kill == /\ up /\ up' = FALSE /\ tmp' = 0 /\ pc' = "idle"
        /\ UNCHANGED <<limbo, work, jw, jd, acked, published, stopped, cont, names, dnames, pending, base, setaside, refused>>
           /\ UNCHANGED markers

(* a close, once the syncer is idle and no merge is under way: every frame written is forced, unless an fsync failed
   (stopped: its frame stays unforced); the marker only then if not MarkerOnlyIfClean; its creation is not forced *)
Close == /\ up /\ (jd = jw \/ stopped) /\ tmp = 0 /\ pc = "idle"
         /\ mk' = (~stopped \/ ~MarkerOnlyIfClean) /\ up' = FALSE
         /\ UNCHANGED <<limbo, work, jw, jd, acked, published, stopped, tmp, cont, names, dnames, pending, pc, base, setaside, refused, dmk>>

(* F2: a power loss; frames written and not forced may or may not reach the disk; a prefix of the name changes; the
   marker's last change kept or not *)
PowerLoss == /\ \E m \in {mk, dmk} : mk' = m /\ dmk' = m
             /\ \E kept \in jd..jw, k \in 0..Len(pending) :
                  /\ jw' = kept /\ jd' = kept
                  /\ dnames' = Apply(dnames, SubSeq(pending, 1, k)) /\ names' = Apply(dnames, SubSeq(pending, 1, k))
             /\ cont' = [g \in Groups |-> IF cont[g] = "cache" THEN "garbage" ELSE cont[g]]
             /\ pending' = << >> /\ up' = FALSE /\ tmp' = 0 /\ pc' = "idle" /\ limbo' = FALSE
             /\ UNCHANGED <<work, acked, published, stopped, base, setaside, refused>>

(* recovery: the marker removed if there (its removal not forced), else the journal forced, its newest frame written
   again first (without that, the frames a failed fsync marked clean stay off the disk); the newest snapshot loaded,
   the journal replayed after it *)
Recover == /\ ~up
           /\ mk' = FALSE /\ UNCHANGED dmk
           /\ LET forced == ForceAtRecovery /\ ~mk /\ (RewriteAtRecovery \/ ~limbo)
                  jd2 == IF forced THEN jw ELSE jd
                  s == Max(names)
              IN /\ jd' = jd2
                 /\ setaside' = (setaside \/ (s /= 0 /\ cont[s] /= "durable"))
                 /\ refused' = (refused \/ s > jw)
                 /\ base' = s /\ work' = jw /\ published' = jw /\ limbo' = (limbo /\ ~forced)
           /\ up' = TRUE /\ stopped' = FALSE /\ tmp' = 0 /\ pc' = "idle"
           /\ UNCHANGED <<jw, acked, cont, names, dnames, pending>>

Next == Prepare \/ WriteFrame \/ Sync \/ SyncFails \/ CutJournal \/ Begin \/ Force \/ Rename \/ Abandon \/ SyncDir
        \/ Kill \/ Close \/ PowerLoss \/ Recover

Spec == Init /\ [][Next]_vars

(* G12: a snapshot name, durable or not, never points at content that is not whole and forced *)
NoMix == ~setaside /\ \A g \in names \cup dnames : cont[g] = "durable"

(* G12: a snapshot name exists only for a group the journal holds durably; recovery never meets one ahead of it *)
SnapshotInJournal == ~refused /\ \A g \in names \cup dnames : g <= jd

(* G5: what readers see is durable, after a recovery too *)
PublishedDurable == up => published <= jd

(* G1: a confirmed group is durable *)
AckedDurable == acked <= jd

(* the base read is one of the snapshots, or the empty one *)
BaseNamed == up => base \in names \cup {0}

TypeOK == /\ work \in 0..MaxGroups /\ jd <= jw /\ (jw <= work \/ ~up)
          /\ cont \in [Groups -> {"none", "cache", "durable", "garbage"}]
=============================================================================
