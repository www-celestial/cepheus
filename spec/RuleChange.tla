---------------------------- MODULE RuleChange ----------------------------
(* The background path of a change of the rules (docs/book/rules.md, "Changes of the rules"; G19 in
   docs/book/guarantees.md): the change's consequences computed beside the writer, caught up with the groups the
   writer commits meanwhile, and installed as one group. As spec/Merge.tla models a merge.
   The catch-up takes the logged groups by batches of any size (the code takes all it finds): only the state at the
   end of a batch is judged by the new rules, since the states between are ordered before the change.

   The facts are abstracted to three asserted facts (1, 2, 3) and two derived ones (11, 12). The old rules give 11
   from 1; the new rules give 11 from 1 or 2 and 12 from 2, and hold a constraint: 1 and 2 never both asserted. A
   view maps each fact to its state: 0 absent, 1 asserted, 2 derived only. Mat(r, S) is the materialisation of the
   asserted facts S under the rules r (unique: the least model, Abiteboul, Hull, Vianu 1995, ch. 12); every group the
   writer resolves inline reaches it (G17, tested by the engine's property tests), so here a group's view is Mat
   itself. The change C changes the rules from old to new, asserts fact 3 (an ontology fact, its asserted part), and
   expects fact 1 asserted (an Expect, checked when C is ordered).

   The writer commits data groups (each toggles one asserted fact) under its rules, as frames: a frame is the set of
   the facts it changes with their state after (replay applies states, never a rule). Sync makes every frame written
   durable and publishes the working view. Start begins C: the background builds V = Mat(new, S_k + 3) from the
   working view of the moment; CatchUp applies a batch of logged groups to V: their net asserted changes, the derived
   facts found again under the new rules, and marks C bad if the state at the end breaks the new constraint or a group
   touches fact 3 (C's asserted part must commute with the log); Ready when fewer than Behind groups are left; Install
   (the writer, in one step) applies the rest as one batch, checks the Expect against its own state, and either answers Conflict (C ends,
   nothing written) or writes C's frame, the difference between its working view and V, and adopts V. Crash keeps a
   prefix of the frames from the durable ones on (a kill or a power loss); Recover replays it.

   Views are layers, as the engine keeps them: the runs (a base, the state at the group of the newest merge), the
   change's run R (below), and the delta, an entry for each fact whose state differs from the runs below it; a fact's
   state is its delta entry, else R's, else the base's. The runs named on the disk (the chain) are the state at one
   group, sg; a merge (when every frame is durable and no change runs) writes the working view's state there, and
   recovery starts from it and replays the frames after it.

   The change's run (job "rulefile"): the build writes the derived facts it adds (absent before, derived only after)
   into a run of their own, R, below the change's view's delta, instead of the delta: only those the delta of the view
   it forked holds no entry for (DeltaFirst: an entry there would hide R's), the others go to the delta as before.
   Either way (useR) is allowed: the code takes R only for large changes. The difference with the writer's lineage is
   kept fact by fact in a table (tab: the writer's state and the change's) for the facts the build put in the delta and
   those the catch-up touched; R's facts are in it only when touched, and their state before a first touch is (absent,
   derived) (TrackRun); one whose two states agree stays in the table (KeepTombstones), since its absence there means
   "as R says". R is provisional: never named on its own (NeverNamed: its state is no group's), the working view
   holds it once C is installed, and the next merge takes it (MergeTakesRun: a run that rests on R and is named lacks
   R's facts); a crash loses it, and recovery replays C's frame, which holds every derived fact.

   In a Raft cluster (server/cluster.ml, Engine's propose) a durable frame is a committed one, and a server that stops
   leading takes back the frames it wrote and that were not committed (TakeBack: the working view goes back to the
   published one); each take-back starts a new lineage of the writer. A change started on an older lineage is never
   installed: Install answers it (not_leader), nothing written. Its view may hold a group taken back, which no
   journal holds.

   Checked by tools/tlc.sh (bounds in RuleChange.cfg), the invariants and the liveness property Ends. Each of the
   rules of the design is needed: with any one of Rederive, CatchUpAll, ExpectAtInstall, CheckAtCatchUp, CheckOverlap,
   TrackDiff, BuildFromWorking, SameLineage, DeltaFirst, TrackRun, KeepTombstones, NeverNamed, MergeTakesRun set to
   FALSE (RuleChangeCopy.cfg, ..., RuleChangeMergeSkipsRun.cfg), TLC finds a counterexample. *)
EXTENDS Naturals, Integers, Sequences, FiniteSets

CONSTANTS MaxGroups, MaxCrashes, Behind,
          Rederive,          \* a logged group's derived facts found again under the new rules, not copied
          CatchUpAll,        \* the writer applies every group logged since the background was ready
          ExpectAtInstall,   \* C's Expect checked against the writer's state at the install, not at the build
          CheckAtCatchUp,    \* each caught-up state checked against the new rules' constraint
          CheckOverlap,      \* a logged group that touches a fact C asserts ends C (Conflict)
          TrackDiff,         \* C's frame is the difference at the install, not the build's own changes
          BuildFromWorking,  \* the build starts from the working view (every prepared group), not the published one
          MaxTakeBacks,      \* Raft: frames not committed taken back, at most this many times (0: a single server)
          SameLineage,       \* Raft: a change is installed only on the lineage it started from
          MaxMerges,         \* merges, at most this many
          DeltaFirst,        \* R takes only the derived facts the forked view's delta holds no entry for
          TrackRun,          \* a fact of R not in the table: (writer absent, change derived)
          KeepTombstones,    \* a fact of R whose two states agree stays in the table
          NeverNamed,        \* R is never named as a run of the chain
          MergeTakesRun      \* a merge takes R

VARIABLES
  wb, wd, wrr,  \* the working view: its base (the runs merged), its delta, whether it holds R
  wr,           \* its rules ("old", "new")
  jn,           \* the journal: a sequence of frames [fr: set of <<fact, state after>>, r: the rules after it]
  jd,           \* frames durable
  pub, pr, prr, \* the published view (its state), its rules, whether it holds R
  ng,           \* data groups written so far (bounded)
  crashes, up,
  cs,           \* C: "none" (not running: never started, answered, or lost), "run", "ready", "done"
  rr,           \* R: the derived facts the build wrote into a run of their own (an entry, or -1)
  cd,           \* the change's view: its delta over the base and R
  bpos,         \* the frames the background has applied: the log is jn[bpos+1..]
  bad,          \* a caught-up state broke the new constraint, or the log touched fact 3
  eb,           \* the Expect at the build (for the variant that checks it there)
  dk,           \* the build's own changes (for the variant that writes them as C's frame)
  tab,          \* the difference, fact by fact: 4 x the writer's state + the change's, or -1
  cpos,         \* C's frame in the journal (0: none)
  acked,        \* C was confirmed to its client
  tb, lin,      \* Raft: take-backs so far; the writer's lineage (one more at each take-back)
  born,         \* the lineage C started on
  sg, sst,      \* the runs named on the disk: their group and their state
  merges

vars == <<wb, wd, wrr, wr, jn, jd, pub, pr, prr, ng, crashes, up, cs, rr, cd, bpos, bad, eb, dk, tab, cpos, acked,
          tb, lin, born, sg, sst, merges>>

Asserted == {1, 2, 3}
DerivedU == {11, 12}
U == Asserted \cup DerivedU
Own == 3
Gives(r) == IF r = "old" THEN {<<1, 11>>} ELSE {<<1, 11>>, <<2, 11>>, <<2, 12>>}
Mat(r, S) == [f \in U |-> IF f \in Asserted THEN (IF f \in S THEN 1 ELSE 0)
                          ELSE IF \E g \in Gives(r) : g[2] = f /\ g[1] \in S THEN 2 ELSE 0]
AssertedOf(v) == {f \in Asserted : v[f] = 1}
Broken(r, S) == r = "new" /\ {1, 2} \subseteq S
ExpectOK(S) == 1 \in S
Exact(v, r) == v = Mat(r, AssertedOf(v))
Empty == Mat("old", {})

(* layers: no entry is -1; a fact's state is the delta's entry, else R's, else the base's *)
NoE == [f \in U |-> -1]
Lay(b, r, d) == [f \in U |-> IF d[f] >= 0 THEN d[f] ELSE IF r[f] >= 0 THEN r[f] ELSE b[f]]
Ent(s, below) == IF s = below THEN -1 ELSE s
DeltaOf(below, st) == [f \in U |-> Ent(st[f], below[f])]
WRuns == Lay(wb, IF wrr THEN rr ELSE NoE, NoE)
Work == Lay(wb, IF wrr THEN rr ELSE NoE, wd)
CRuns == Lay(wb, rr, NoE)
BV == Lay(wb, rr, cd)

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
(* the facts a batch of frames touches *)
WTouched(fs) == {f \in U : \E i \in 1..Len(fs) : \E s \in {0, 1, 2} : <<f, s>> \in fs[i].fr}

(* the table: a fact's states in the writer's lineage and in the change's view, 4 w + c *)
EW(x) == x \div 4
EC(x) == x % 4
InR(f) == rr[f] >= 0
(* a step: [wt] the facts the writer's frames touched, from [w0] to [w1]; the change's view from [c0] to [c1] *)
Track(t, wt, w0, w1, c0, c1) ==
  LET ct == {f \in U : c0[f] /= c1[f]}
  IN [f \in U |->
        IF f \notin wt \cup ct THEN t[f]
        ELSE LET bw == IF t[f] >= 0 THEN EW(t[f]) ELSE IF TrackRun /\ InR(f) THEN 0 ELSE IF f \in wt THEN w0[f] ELSE c0[f]
                 bc == IF t[f] >= 0 THEN EC(t[f]) ELSE IF TrackRun /\ InR(f) THEN 2 ELSE IF f \in wt THEN w0[f] ELSE c0[f]
                 aw == IF f \in wt THEN w1[f] ELSE bw
                 ac == IF f \in ct THEN c1[f] ELSE bc
             IN IF aw = ac /\ ~(KeepTombstones /\ InR(f)) THEN -1 ELSE 4 * aw + ac]
(* the frame the table and R give: each fact whose states differ, then R's facts the table does not hold *)
TabDiff(t) == {<<f, EC(t[f])>> : f \in {g \in U : t[g] >= 0 /\ EW(t[g]) /= EC(t[g])}}
              \cup {<<f, 2>> : f \in {g \in U : InR(g) /\ t[g] < 0}}
(* the change's view after a batch: the entries of the facts whose state changed, over the base and R *)
Step(target) == [f \in U |-> IF target[f] = BV[f] THEN cd[f] ELSE Ent(target[f], CRuns[f])]

Init == /\ wb = Empty /\ wd = NoE /\ wrr = FALSE /\ wr = "old" /\ jn = << >> /\ jd = 0 /\ pub = Empty /\ pr = "old"
        /\ prr = FALSE /\ ng = 0 /\ crashes = 0 /\ up = TRUE /\ cs = "none" /\ rr = NoE /\ cd = NoE /\ bpos = 0
        /\ bad = FALSE /\ eb = FALSE /\ dk = {} /\ tab = NoE /\ cpos = 0 /\ acked = FALSE /\ tb = 0
        /\ lin = 0 /\ born = 0 /\ sg = 0 /\ sst = Empty /\ merges = 0

(* a data group under the writer's rules; a group that would break the rules' constraint is refused (no frame) *)
Write(x) == /\ up /\ ng < MaxGroups
            /\ LET S == AssertedOf(Work)
                   S2 == IF x \in S THEN S \ {x} ELSE S \cup {x}
               IN /\ ~Broken(wr, S2)
                  /\ wd' = DeltaOf(WRuns, Mat(wr, S2)) /\ jn' = Append(jn, [fr |-> Diff(Work, Mat(wr, S2)), r |-> wr])
            /\ ng' = ng + 1
            /\ UNCHANGED <<wb, wrr, wr, jd, pub, pr, prr, crashes, up, cs, rr, cd, bpos, bad, eb, dk, tab, cpos, acked,
                           tb, lin, born, sg, sst, merges>>

(* every frame written made durable; the working view published; C confirmed if its frame is among them (the
   variant names R then, as a large group's run is named once its frame is durable: the runs below it, then R, as the
   state at C's group) *)
Sync == /\ up /\ jd < Len(jn) /\ jd' = Len(jn) /\ pub' = Work /\ pr' = wr /\ prr' = wrr /\ acked' = (acked \/ cpos > 0)
        /\ IF ~NeverNamed /\ wrr /\ cpos > jd THEN sg' = cpos /\ sst' = CRuns ELSE UNCHANGED <<sg, sst>>
        /\ UNCHANGED <<wb, wd, wrr, wr, jn, ng, crashes, up, cs, rr, cd, bpos, bad, eb, dk, tab, cpos, tb, lin, born,
                       merges>>

(* the build: V = Mat(new, S + 3) on a fork; the derived facts it adds into R when it takes one (useR) and the fork's
   delta has no entry for them, everything else of its changes into the change's delta *)
Start == /\ up /\ cs = "none" /\ wr = "old" /\ cpos = 0 /\ ~wrr
         /\ LET from == IF BuildFromWorking THEN Work ELSE pub
                fd == DeltaOf(wb, from)
                S == AssertedOf(from) \cup {Own}
                V == Mat("new", S)
            IN \E useR \in BOOLEAN :
                 LET toR == IF useR THEN {f \in DerivedU : V[f] = 2 /\ from[f] = 0 /\ (DeltaFirst => fd[f] < 0)} ELSE {}
                     r == [f \in U |-> IF f \in toR THEN 2 ELSE -1]
                     below == Lay(wb, r, NoE)
                 IN /\ rr' = r
                    /\ cd' = [f \in U |-> IF V[f] /= from[f] /\ f \notin toR THEN Ent(V[f], below[f]) ELSE fd[f]]
                    /\ tab' = [f \in U |-> IF V[f] /= from[f] /\ f \notin toR THEN 4 * from[f] + V[f] ELSE -1]
                    /\ bad' = Broken("new", S) /\ eb' = ExpectOK(AssertedOf(from)) /\ dk' = Diff(from, V)
         /\ bpos' = Len(jn) /\ cs' = "run" /\ born' = lin
         /\ UNCHANGED <<wb, wd, wrr, wr, jn, jd, pub, pr, prr, ng, crashes, up, cpos, acked, tb, lin, sg, sst, merges>>

CatchUp == /\ up /\ cs = "run" /\ bpos < Len(jn)
           /\ \E k \in 1..(Len(jn) - bpos) :
                LET fs == SubSeq(jn, bpos + 1, bpos + k)
                    r == Batch(BV, fs)
                IN /\ cd' = Step(r[1]) /\ bad' = (bad \/ r[2]) /\ bpos' = bpos + k
                   /\ tab' = Track(tab, WTouched(fs), Replay(bpos), Replay(bpos + k), BV, r[1])
           /\ UNCHANGED <<wb, wd, wrr, wr, jn, jd, pub, pr, prr, ng, crashes, up, cs, rr, eb, dk, cpos, acked, tb, lin,
                          born, sg, sst, merges>>

Ready == /\ up /\ cs = "run" /\ Len(jn) - bpos < Behind /\ cs' = "ready"
         /\ UNCHANGED <<wb, wd, wrr, wr, jn, jd, pub, pr, prr, ng, crashes, up, rr, cd, bpos, bad, eb, dk, tab, cpos,
                        acked, tb, lin, born, sg, sst, merges>>

(* the writer: the rest as one batch, the Expect, the frame from the table and R; it adopts the change's view, R
   with it (provisional: named only by the merge that takes it) *)
Install == /\ up /\ cs = "ready"
           /\ LET fs == IF CatchUpAll THEN SubSeq(jn, bpos + 1, Len(jn)) ELSE << >>
                  r == Batch(BV, fs)
                  t2 == Track(tab, WTouched(fs), IF bpos <= Len(jn) THEN Replay(bpos) ELSE Work, Work, BV, r[1])
                  ok == ~(bad \/ r[2]) /\ (IF ExpectAtInstall THEN ExpectOK(AssertedOf(Work)) ELSE eb)
                        /\ (SameLineage => born = lin)
                  fr == IF TrackDiff THEN TabDiff(t2) ELSE dk
              IN IF ok
                 THEN /\ cd' = Step(r[1]) /\ wd' = Step(r[1]) /\ wrr' = TRUE /\ wr' = "new"
                      /\ jn' = Append(jn, [fr |-> fr, r |-> "new"])
                      /\ cpos' = Len(jn) + 1 /\ cs' = "done" /\ tab' = t2
                 ELSE /\ cs' = "none" /\ UNCHANGED <<wd, wrr, wr, jn, cpos, cd, tab>>
           /\ UNCHANGED <<wb, jd, pub, pr, prr, ng, crashes, up, rr, bpos, bad, eb, dk, acked, tb, lin, born, sg, sst,
                          merges>>

(* a merge, once every frame is durable and no change runs: the working view's state named at its group, R taken
   (the variant: a run of the base and the delta named, resting on R, which the chain does not hold) *)
Merge == /\ up /\ merges < MaxMerges /\ jd = Len(jn) /\ cs \in {"none", "done"}
         /\ merges' = merges + 1 /\ sg' = Len(jn)
         /\ IF MergeTakesRun \/ ~wrr
            THEN /\ sst' = Work /\ wb' = Work /\ wd' = NoE /\ wrr' = FALSE /\ prr' = FALSE
            ELSE /\ sst' = Lay(wb, NoE, wd) /\ UNCHANGED <<wb, wd, wrr, prr>>
         /\ UNCHANGED <<wr, jn, jd, pub, pr, ng, crashes, up, cs, rr, cd, bpos, bad, eb, dk, tab, cpos, acked, tb, lin,
                        born>>

(* a kill or a power loss: the frames kept are a prefix that holds the durable ones; the background is lost, R too *)
Crash == /\ up /\ crashes < MaxCrashes
         /\ \E kept \in jd..Len(jn) :
              /\ jn' = SubSeq(jn, 1, kept)
              /\ cpos' = IF cpos > kept THEN 0 ELSE cpos
              /\ cs' = IF cpos > 0 /\ cpos <= kept THEN "done" ELSE "none"
         /\ up' = FALSE /\ crashes' = crashes + 1
         /\ UNCHANGED <<wb, wd, wrr, wr, jd, pub, pr, prr, ng, rr, cd, bpos, bad, eb, dk, tab, acked, tb, lin, born,
                        sg, sst, merges>>

(* the named runs, then the frames after them; no R *)
Recover == /\ ~up /\ up' = TRUE
           /\ wb' = sst /\ wd' = DeltaOf(sst, ReplayFrom(sst, sg + 1, Len(jn))) /\ wrr' = FALSE /\ prr' = FALSE
           /\ wr' = RulesAt(Len(jn)) /\ pub' = ReplayFrom(sst, sg + 1, Len(jn)) /\ pr' = RulesAt(Len(jn))
           /\ jd' = Len(jn)
           /\ UNCHANGED <<jn, ng, crashes, cs, rr, cd, bpos, bad, eb, dk, tab, cpos, acked, tb, lin, born, sg, sst,
                          merges>>

(* Raft: this server stops leading; the frames it wrote and that were not committed are taken back, its working view
   goes back to the published one, a new lineage starts. C, if its frame was among them, is answered (not_leader);
   C in the background goes on, and its install checks its lineage *)
TakeBack == /\ up /\ tb < MaxTakeBacks /\ jd < Len(jn)
            /\ jn' = SubSeq(jn, 1, jd) /\ wr' = pr /\ wrr' = prr
            /\ wd' = DeltaOf(Lay(wb, IF prr THEN rr ELSE NoE, NoE), pub)
            /\ cpos' = IF cpos > jd THEN 0 ELSE cpos
            /\ cs' = IF cpos > jd THEN "none" ELSE cs
            /\ tb' = tb + 1 /\ lin' = lin + 1
            /\ UNCHANGED <<wb, jd, pub, pr, prr, ng, crashes, up, rr, cd, bpos, bad, eb, dk, tab, acked, born, sg, sst,
                           merges>>

Next == \/ \E x \in Asserted : Write(x)
        \/ Sync \/ Start \/ CatchUp \/ Ready \/ Install \/ Merge \/ Crash \/ Recover \/ TakeBack

Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(CatchUp) /\ WF_vars(Ready) /\ WF_vars(Install) /\ WF_vars(Recover)

TypeOK == /\ wr \in {"old", "new"} /\ pr \in {"old", "new"} /\ cs \in {"none", "run", "ready", "done"}
          /\ jd <= Len(jn) /\ cpos <= Len(jn) /\ (cs \in {"run", "ready"} /\ born = lin => bpos <= Len(jn))
          /\ sg <= jd

(* G17 for every view: the working and the published views, and the state at every frame of the journal (what a
   recovery, a replica, a local reader or the past reads) are the materialisation of their asserted facts under their
   rules; no view mixes the old rules' facts with the new ones' *)
ViewsExact == /\ up => (Exact(Work, wr) /\ Exact(pub, pr))
              /\ \A k \in 0..Len(jn) : Exact(Replay(k), RulesAt(k))

(* the change's view, its layers read as the engine reads them, is the materialisation under the new rules of its
   asserted facts (what the catch-up's reasoning rests on) *)
ChangeViewExact == cs \in {"run", "ready"} => Exact(BV, "new")

(* the table and R are the difference between the writer's state where the background stands and the change's view *)
TableExact == (up /\ cs \in {"run", "ready"} /\ born = lin /\ bpos <= Len(jn)) => TabDiff(tab) = Diff(Replay(bpos), BV)

(* the runs named on the disk hold the journal's state at their group (G12): R is never among them on its own *)
RunsExact == sst = Replay(sg)

(* the journal replays to the working view: C's frame is exactly the difference the adopted view holds *)
JournalIsWork == up => (Replay(Len(jn)) = Work /\ RulesAt(Len(jn)) = wr)

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
