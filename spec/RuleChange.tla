---------------------------- MODULE RuleChange ----------------------------
(* The background path of a change of the rules (docs/book/rules.md, "Changes of the rules"; G19 in
   docs/book/guarantees.md): the change's consequences computed beside the writer, caught up with the groups the
   writer commits meanwhile, and installed as one group. As spec/Merge.tla models a merge.
   The catch-up takes the logged groups by batches of any size (the code takes all it finds): only the state at the
   end of a batch is judged by the new rules, since the states between are ordered before the change.

   The facts are abstracted to three asserted facts (1, 2, 3) and two derived ones (11, 12). The old rules give 11
   from 1; the new rules give 12 from 2, and hold a constraint: 1 and 2 never both asserted. A view maps each fact to
   its state: 0 absent, 1 asserted, 2 derived only. Mat(r, S) is the materialisation of the asserted facts S under the
   rules r (unique: the least model, Abiteboul, Hull, Vianu 1995, ch. 12); every group the writer resolves inline
   reaches it (G17, tested by the engine's property tests), so here a group's view is Mat itself. The change C changes
   the rules from old to new, asserts fact 3 (an ontology fact, its asserted part), and expects fact 1 asserted (an
   Expect, checked when C is ordered).

   The writer commits data groups (each toggles one asserted fact) under its rules, as frames: a frame is the set of
   the facts it changes with their state after (replay applies states, never a rule). Sync makes every frame written
   durable and publishes the working view. Start begins C: the background builds V = Mat(new, S_k + 3) from the
   working view of the moment; CatchUp applies a batch of logged groups to V: their net asserted changes, the derived
   facts found again under the new rules, and marks C bad if the state at the end breaks the new constraint or a group
   touches fact 3 (C's asserted part must commute with the log); Ready when fewer than Behind groups are left; Install
   (the writer, in one step) applies the rest as one batch, checks the Expect against its own state, and either answers Conflict (C ends,
   nothing written) or writes C's frame, the difference between its working view and V, and adopts V. Crash keeps a
   prefix of the frames from the durable ones on (a kill or a power loss); Recover replays it.

   In a Raft cluster (server/cluster.ml, Engine's propose) a durable frame is a committed one, and a server that stops
   leading takes back the frames it wrote and that were not committed (TakeBack: the working view goes back to the
   published one); each take-back starts a new lineage of the writer. A change started on an older lineage is never
   installed: Install answers it (not_leader), nothing written. Its view may hold a group taken back, which no
   journal holds.

   Checked by tools/tlc.sh (bounds in RuleChange.cfg), the invariants and the liveness property Ends. Each of the
   rules of the design is needed: with any one of Rederive, CatchUpAll, ExpectAtInstall, CheckAtCatchUp, CheckOverlap,
   TrackDiff, BuildFromWorking, SameLineage set to FALSE (RuleChangeCopy.cfg, ..., RuleChangeTakeBack.cfg), TLC finds
   a counterexample. *)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS MaxGroups, MaxCrashes, Behind,
          Rederive,          \* a logged group's derived facts found again under the new rules, not copied
          CatchUpAll,        \* the writer applies every group logged since the background was ready
          ExpectAtInstall,   \* C's Expect checked against the writer's state at the install, not at the build
          CheckAtCatchUp,    \* each caught-up state checked against the new rules' constraint
          CheckOverlap,      \* a logged group that touches a fact C asserts ends C (Conflict)
          TrackDiff,         \* C's frame is the difference at the install, not the build's own changes
          BuildFromWorking,  \* the build starts from the working view (every prepared group), not the published one
          MaxTakeBacks,      \* Raft: frames not committed taken back, at most this many times (0: a single server)
          SameLineage        \* Raft: a change is installed only on the lineage it started from

VARIABLES
  work, wr,   \* the working view and its rules ("old", "new")
  jn,         \* the journal: a sequence of frames [fr: set of <<fact, state after>>, r: the rules after it]
  jd,         \* frames durable
  pub, pr,    \* the published view and its rules
  ng,         \* data groups written so far (bounded)
  crashes, up,
  cs,         \* C: "none" (not running: never started, answered, or lost), "run", "ready", "done"
  bv,         \* the background's view
  bpos,       \* the frames the background has applied: the log is jn[bpos+1..]
  bad,        \* a caught-up state broke the new constraint, or the log touched fact 3
  eb,         \* the Expect at the build (for the variant that checks it there)
  dk,         \* the build's own changes (for the variant that writes them as C's frame)
  cpos,       \* C's frame in the journal (0: none)
  acked,      \* C was confirmed to its client
  tb, lin,    \* Raft: take-backs so far; the writer's lineage (one more at each take-back)
  born        \* the lineage C started on

vars == <<work, wr, jn, jd, pub, pr, ng, crashes, up, cs, bv, bpos, bad, eb, dk, cpos, acked, tb, lin, born>>

Asserted == {1, 2, 3}
U == Asserted \cup {11, 12}
Own == 3
Gives(r) == IF r = "old" THEN {<<1, 11>>} ELSE {<<2, 12>>}
Mat(r, S) == [f \in U |-> IF f \in Asserted THEN (IF f \in S THEN 1 ELSE 0)
                          ELSE IF \E g \in Gives(r) : g[2] = f /\ g[1] \in S THEN 2 ELSE 0]
AssertedOf(v) == {f \in Asserted : v[f] = 1}
Broken(r, S) == r = "new" /\ {1, 2} \subseteq S
ExpectOK(S) == 1 \in S
Exact(v, r) == v = Mat(r, AssertedOf(v))
Empty == Mat("old", {})

Diff(a, b) == {<<f, b[f]>> : f \in {g \in U : a[g] /= b[g]}}
Apply(v, fr) == [f \in U |-> IF \E p \in fr : p[1] = f THEN (CHOOSE p \in fr : p[1] = f)[2] ELSE v[f]]

RECURSIVE ReplayFrom(_, _, _)
ReplayFrom(v, j, k) == IF j > k THEN v ELSE ReplayFrom(Apply(v, jn[j].fr), j + 1, k)
Replay(k) == ReplayFrom(Empty, 1, k)
RulesAt(k) == IF k = 0 THEN "old" ELSE jn[k].r

(* logged groups applied to the background's view at once (a batch): their net asserted changes, the derived facts
   found again under the new rules; the state at the end of the batch judged by the new rules *)
NewA(S, fr) == (S \ {f \in Asserted : <<f, 0>> \in fr}) \cup {f \in Asserted : <<f, 1>> \in fr}
RECURSIVE Net(_, _)
Net(S, fs) == IF fs = << >> THEN S ELSE Net(NewA(S, Head(fs).fr), Tail(fs))
RECURSIVE Copy(_, _)
Copy(v, fs) == IF fs = << >> THEN v ELSE Copy(Apply(v, Head(fs).fr), Tail(fs))
Touches(fs) == \E i \in 1..Len(fs) : \E s \in {0, 1, 2} : <<Own, s>> \in fs[i].fr
Batch(v, fs) == LET S == Net(AssertedOf(v), fs)
                IN << IF Rederive THEN Mat("new", S) ELSE Copy(v, fs),
                      \/ CheckAtCatchUp /\ fs /= << >> /\ Broken("new", S)
                      \/ CheckOverlap /\ Touches(fs) >>

Init == /\ work = Empty /\ wr = "old" /\ jn = << >> /\ jd = 0 /\ pub = Empty /\ pr = "old" /\ ng = 0
        /\ crashes = 0 /\ up = TRUE /\ cs = "none" /\ bv = Empty /\ bpos = 0 /\ bad = FALSE /\ eb = FALSE /\ dk = {}
        /\ cpos = 0 /\ acked = FALSE /\ tb = 0 /\ lin = 0 /\ born = 0

(* a data group under the writer's rules; a group that would break the rules' constraint is refused (no frame) *)
Write(x) == /\ up /\ ng < MaxGroups
            /\ LET S == AssertedOf(work)
                   S2 == IF x \in S THEN S \ {x} ELSE S \cup {x}
               IN /\ ~Broken(wr, S2)
                  /\ work' = Mat(wr, S2) /\ jn' = Append(jn, [fr |-> Diff(work, Mat(wr, S2)), r |-> wr])
            /\ ng' = ng + 1
            /\ UNCHANGED <<wr, jd, pub, pr, crashes, up, cs, bv, bpos, bad, eb, dk, cpos, acked, tb, lin, born>>

(* every frame written made durable; the working view published; C confirmed if its frame is among them *)
Sync == /\ up /\ jd < Len(jn) /\ jd' = Len(jn) /\ pub' = work /\ pr' = wr /\ acked' = (acked \/ cpos > 0)
        /\ UNCHANGED <<work, wr, jn, ng, crashes, up, cs, bv, bpos, bad, eb, dk, cpos, tb, lin, born>>

Start == /\ up /\ cs = "none" /\ wr = "old" /\ cpos = 0
         /\ LET from == IF BuildFromWorking THEN work ELSE pub
                S == AssertedOf(from) \cup {Own}
            IN /\ bv' = Mat("new", S) /\ bad' = Broken("new", S) /\ eb' = ExpectOK(AssertedOf(from))
               /\ dk' = Diff(from, Mat("new", S))
         /\ bpos' = Len(jn) /\ cs' = "run" /\ born' = lin
         /\ UNCHANGED <<work, wr, jn, jd, pub, pr, ng, crashes, up, cpos, acked, tb, lin>>

CatchUp == /\ up /\ cs = "run" /\ bpos < Len(jn)
           /\ \E k \in 1..(Len(jn) - bpos) :
                LET r == Batch(bv, SubSeq(jn, bpos + 1, bpos + k))
                IN bv' = r[1] /\ bad' = (bad \/ r[2]) /\ bpos' = bpos + k
           /\ UNCHANGED <<work, wr, jn, jd, pub, pr, ng, crashes, up, cs, eb, dk, cpos, acked, tb, lin, born>>

Ready == /\ up /\ cs = "run" /\ Len(jn) - bpos < Behind /\ cs' = "ready"
         /\ UNCHANGED <<work, wr, jn, jd, pub, pr, ng, crashes, up, bv, bpos, bad, eb, dk, cpos, acked, tb, lin, born>>

Install == /\ up /\ cs = "ready"
           /\ LET r == Batch(bv, IF CatchUpAll THEN SubSeq(jn, bpos + 1, Len(jn)) ELSE << >>)
                  ok == ~(bad \/ r[2]) /\ (IF ExpectAtInstall THEN ExpectOK(AssertedOf(work)) ELSE eb)
                        /\ (SameLineage => born = lin)
                  fr == IF TrackDiff THEN Diff(work, r[1]) ELSE dk
              IN IF ok
                 THEN /\ work' = r[1] /\ wr' = "new" /\ jn' = Append(jn, [fr |-> fr, r |-> "new"])
                      /\ cpos' = Len(jn) + 1 /\ cs' = "done"
                 ELSE /\ cs' = "none" /\ UNCHANGED <<work, wr, jn, cpos>>
           /\ UNCHANGED <<jd, pub, pr, ng, crashes, up, bv, bpos, bad, eb, dk, acked, tb, lin, born>>

(* a kill or a power loss: the frames kept are a prefix that holds the durable ones; the background is lost *)
Crash == /\ up /\ crashes < MaxCrashes
         /\ \E kept \in jd..Len(jn) :
              /\ jn' = SubSeq(jn, 1, kept)
              /\ cpos' = IF cpos > kept THEN 0 ELSE cpos
              /\ cs' = IF cpos > 0 /\ cpos <= kept THEN "done" ELSE "none"
         /\ up' = FALSE /\ crashes' = crashes + 1
         /\ UNCHANGED <<work, wr, jd, pub, pr, ng, bv, bpos, bad, eb, dk, acked, tb, lin, born>>

Recover == /\ ~up /\ up' = TRUE
           /\ work' = Replay(Len(jn)) /\ wr' = RulesAt(Len(jn)) /\ pub' = Replay(Len(jn)) /\ pr' = RulesAt(Len(jn))
           /\ jd' = Len(jn)
           /\ UNCHANGED <<jn, ng, crashes, cs, bv, bpos, bad, eb, dk, cpos, acked, tb, lin, born>>

(* Raft: this server stops leading; the frames it wrote and that were not committed are taken back, its working view
   goes back to the published one, a new lineage starts. C, if its frame was among them, is answered (not_leader);
   C in the background goes on, and its install checks its lineage *)
TakeBack == /\ up /\ tb < MaxTakeBacks /\ jd < Len(jn)
            /\ jn' = SubSeq(jn, 1, jd) /\ work' = pub /\ wr' = pr
            /\ cpos' = IF cpos > jd THEN 0 ELSE cpos
            /\ cs' = IF cpos > jd THEN "none" ELSE cs
            /\ tb' = tb + 1 /\ lin' = lin + 1
            /\ UNCHANGED <<jd, pub, pr, ng, crashes, up, bv, bpos, bad, eb, dk, acked, born>>

Next == \/ \E x \in Asserted : Write(x)
        \/ Sync \/ Start \/ CatchUp \/ Ready \/ Install \/ Crash \/ Recover \/ TakeBack

Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(CatchUp) /\ WF_vars(Ready) /\ WF_vars(Install) /\ WF_vars(Recover)

TypeOK == /\ wr \in {"old", "new"} /\ pr \in {"old", "new"} /\ cs \in {"none", "run", "ready", "done"}
          /\ jd <= Len(jn) /\ cpos <= Len(jn) /\ (cs \in {"run", "ready"} /\ born = lin => bpos <= Len(jn))

(* G17 for every view: the working and the published views, and the state at every frame of the journal (what a
   recovery, a replica, a local reader or the past reads) are the materialisation of their asserted facts under their
   rules; no view mixes the old rules' facts with the new ones' *)
ViewsExact == /\ up => (Exact(work, wr) /\ Exact(pub, pr))
              /\ \A k \in 0..Len(jn) : Exact(Replay(k), RulesAt(k))

(* the journal replays to the working view: C's frame is exactly the difference the adopted view holds *)
JournalIsWork == up => (Replay(Len(jn)) = work /\ RulesAt(Len(jn)) = wr)

(* G19: the rules change at one frame, C's *)
OneSwitch == \A k \in 1..Len(jn) : jn[k].r = IF cpos > 0 /\ k >= cpos THEN "new" ELSE "old"

(* G18: no state of the journal breaks its rules' constraint *)
ConstraintsHold == \A k \in 0..Len(jn) : ~Broken(RulesAt(k), AssertedOf(Replay(k)))

(* G4: C is ordered at its frame: its Expect held just before it, and its asserted part holds at it *)
Serial == cpos > 0 => (ExpectOK(AssertedOf(Replay(cpos - 1))) /\ Own \in AssertedOf(Replay(cpos)))

(* no write is lost: C's frame changes no asserted fact but its own (the groups before it keep theirs) *)
NoLostWrite == cpos > 0 => \A p \in jn[cpos].fr : p[1] \in {Own, 11, 12}

(* G1: a confirmed change is durable *)
AckedDurable == acked => (cpos > 0 /\ cpos <= jd)

(* the change ends: installed, answered, or lost to a crash *)
Ends == (cs = "run") ~> (cs \in {"none", "done"})
=============================================================================
