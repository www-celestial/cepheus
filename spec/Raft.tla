-------------------------------- MODULE Raft --------------------------------
(* Raft as a Cepheus cluster runs it (server/raft.ml, docs/book/server.md "A cluster of three"): Ongaro and
   Ousterhout's algorithm (USENIX ATC 2014, Figure 2; Ongaro's thesis, Stanford 2014, whose raft.tla this model follows
   in its shape), with what Cepheus adds or chooses:
   - Pre-Vote (thesis 9.6) only restrains who stands for election: the model lets any server whose timeout passed
     stand (a superset of what pre-votes allow), so that safety proved here holds with or without them;
   - leader stickiness (thesis 4.2.3): a server that heard from a leader within the minimum election timeout grants no
     vote, pre or real, and does not even take the request's term; a server that starts waits that long too (it may
     have heard from a leader just before it stopped);
   - the no-op: a new leader's first entry is an entry of its term (Raft 8), and a leader commits by counting only
     entries of its own term (Raft 5.4.2);
   - durable term and vote; an entry acknowledged only once it is forced (plog: the forced prefix of the log; a
     restart keeps it and loses the rest);
   - reads on the leader under a lease (thesis 6.4.1): a majority promised (by answering its heartbeat) to vote for no
     one else for the minimum election timeout; the leader's lease ends before any of those promises, clocks drifting
     within a bound (the order of ExpireLease and ExpirePromise); a leader reads only once its no-op is committed
     (Ready);
   - the 2018 rule (Alagappan et al., FAST 2018; design 8.5): a server whose forced log is found damaged at a restart
     keeps the part before the damage, records repair = the newest index it may have acknowledged, and neither votes
     nor stands for election until it holds, from a leader whose commit index reaches repair, every entry up to it;
     it acknowledges what it stores meanwhile;
   - the log's start (base: the entries before it are in the databases, their terms no longer read, but that of the
     last) moves behind what a server knows committed and holds forced, with no floor (any server, any time: a
     superset of what the floor allows); a leader never sends from before its start: a peer it would need to is
     probed at its start, and one whose log does not hold that entry takes a copy of the databases (the role of
     InstallSnapshot, Ongaro's thesis ch. 5): any server gives its state at an index X it knows committed and holds,
     and the receiver keeps its log when it holds entry X of the same term (Raft's rule: the copy dropped), else its
     log becomes the copy's, forced, its start X, and the 2018 rule's repair ends once X reaches it;
   - a server whose whole state is lost (Wipe: its disk replaced) starts fresh: it answers no vote request and no
     Append, takes no term, stands for nothing, and asks the others their state (Ask); it ends its freshness with the
     answers of floor(n/2) + 1 other servers neither fresh nor damaged (its term their newest, its vote in it its own, its
     repair mark their newest last index), or, a new cluster, with a majority, itself included, of fresh servers,
     or with every other server's answer showing no history (fresh, or of term 0 and an empty log). A wipe comes only while the damaged and the wiped stay a minority (a majority that lost what it
     acknowledged may have lost a committed entry);
   - leadership handed over (thesis 3.10; cepheus stop on the leader): a leader whose peer holds its whole log gives
     up its lease and takes no more requests, and sends it TimeoutNow; that peer stands at once, its vote requests
     marked (mnow), which a voter grants despite its promise (thesis 4.2.3), on the other rules unchanged;
   - the 2018 rule's repair by any peer: a sound server gives a damaged one the entries of its log after some index,
     up to its own commit index, saying that index; the damaged one takes them as from a leader (a conflicting entry
     of its own cut), raises its commit index to what they cover, and its repair ends once they reach its mark and
     the giver's commit index does too.
   Messages are a set: a message is taken off when it is handled; it may be handled late, in any order, or never (a
   loss); a duplicate does what a resend does (a leader sends an Append as often as it likes, a candidate is answered
   once a term). Time is abstracted: a timeout may pass whenever its server holds no promise.
   CheckQuorum (a leader steps down when it lost its majority) is StepDown, allowed at any time.

   Ghosts: elected (term, server) and committed (index, term of the entry, term of the leader that counted it).

   Checked by parts, so that each part is checked exhaustively within its bounds (RaftCore.cfg: elections, the log,
   restarts; RaftDamage.cfg: the 2018 rule; RaftLease.cfg: reads under the lease), each with at most MaxMsgs messages
   in flight (the bound Ongaro's raft.tla runs use too).

   Variants that must break (each a rule removed alone): CommitOldTerm counts entries of older terms (Figure 8);
   VolatileVote forgets the vote at a restart (two leaders in a term); AckUnforced acknowledges entries before they
   are forced (a restart loses a committed entry); NoUpToDate grants votes without comparing logs; NoAbstain lets a
   damaged server vote as if its log were shorter (the bug Alagappan et al. found); NoStickiness grants
   votes despite a promise; PromiseFirst lets a promise end before the lease it supports; RestartForgets lets a
   server that starts vote at once; ReadEarly reads before the no-op is committed; CopyDiscards installs a copy
   over a log that holds its last entry (the entries after it, acknowledged, dropped); CopyUncommitted gives a copy
   past what the giver knows committed; FreshHearOne ends a fresh server's freshness on one answer; FreshNoRepair
   ends it without the repair mark; TransferKeepsLease lets a leader that hands over keep its lease;
   RepairUncommitted lets a peer give a damaged server entries past its commit index.
   RepairEarly (a damaged server votes again once it holds entries up to repair from a leader whose commit index
   does not reach it) is not one of them: kept as a margin, not shown needed. TLC finds no trace within its bounds
   (RaftRepairEarly.cfg: terms up to 3, logs of 3, one damage; stopped past 19 M distinct states), and a leader
   elected while the damaged server abstains holds every entry that can be committed, so its entries up to repair are
   safe to take before they are committed. *)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS Server, MaxTerm, MaxLog, MaxRestart, MaxDamage, MaxMsgs, Leases, Eager, MaxCopy, MaxWipe, MaxTransfer, MaxGive,
          CommitOldTerm, VolatileVote, AckUnforced, NoUpToDate, NoAbstain, RepairEarly,
          NoStickiness, PromiseFirst, RestartForgets, ReadEarly, CopyDiscards, CopyUncommitted,
          FreshHearOne, FreshNoRepair, TransferKeepsLease, RepairUncommitted

Nil == "nil"
NoPromise == << >>
NoAnswer == << >>

VARIABLES
  currentTerm, votedFor, log, plog, repair,           \* durable (log: the terms of the entries; plog: forced prefix)
  base,                                               \* durable: the entries up to base are in the databases
  fresh, told,                                        \* a wiped server, and the answers it was given
  state, commitIndex, votes, nextIndex, matchIndex,   \* lost at a restart
  promise,                                            \* promise[s]: <<leader, term>> it heard from, or << >>
  lease,                                              \* lease[s]: the leader may read
  handing,                                            \* handing[s]: the leader hands over (no lease, no request)
  msgs,
  elected, committed,                                 \* ghosts
  restarts, damages, copies, wipes, transfers, gives  \* bounds

durable == <<currentTerm, votedFor, log, plog, repair, base, fresh, told>>
volatile == <<state, commitIndex, votes, nextIndex, matchIndex>>
vars == <<durable, volatile, promise, lease, handing, msgs, elected, committed, restarts, damages, copies, wipes, transfers, gives>>

Majority(Q) == Cardinality(Q) * 2 > Cardinality(Server)
Min(a, b) == IF a < b THEN a ELSE b
Max(a, b) == IF a > b THEN a ELSE b
LastTerm(l) == IF l = << >> THEN 0 ELSE l[Len(l)]
UpToDate(t, n, l) == t > LastTerm(l) \/ (t = LastTerm(l) /\ n >= Len(l))
Abstains(s) == repair[s] > 0 /\ ~NoAbstain
Unpromised(s) == promise[s] = NoPromise \/ NoStickiness
(* with no crash in a part's bounds, what is written is as good as forced: Persist is taken at once (fewer steps,
   the same behaviours up to forcing, which only a crash could tell); Eager takes it at once with crashes too, for the
   parts whose properties do not depend on when an entry is forced (leases, damage: RaftCore checks forcing) *)
Sync == Eager \/ (MaxRestart = 0 /\ MaxDamage = 0)
Forced(s) == IF Sync THEN Len(log[s]) ELSE plog[s]
Acked(s) == IF AckUnforced \/ Sync THEN Len(log[s]) ELSE plog[s]   \* how far a server's own log counts
Ready(i) == \E n \in 1..commitIndex[i] : log[i][n] = currentTerm[i]

Init ==
  /\ currentTerm = [s \in Server |-> 0] /\ votedFor = [s \in Server |-> Nil] /\ log = [s \in Server |-> << >>]
  /\ plog = [s \in Server |-> 0] /\ repair = [s \in Server |-> 0] /\ base = [s \in Server |-> 0]
  /\ fresh = [s \in Server |-> FALSE] /\ told = [s \in Server |-> [t \in Server |-> NoAnswer]]
  /\ state = [s \in Server |-> "Follower"] /\ commitIndex = [s \in Server |-> 0] /\ votes = [s \in Server |-> {}]
  /\ nextIndex = [s \in Server |-> [t \in Server |-> 1]] /\ matchIndex = [s \in Server |-> [t \in Server |-> 0]]
  /\ promise = [s \in Server |-> NoPromise] /\ lease = [s \in Server |-> FALSE] /\ handing = [s \in Server |-> FALSE]
  /\ msgs = {} /\ elected = {} /\ committed = {} /\ restarts = 0 /\ damages = 0 /\ copies = 0 /\ wipes = 0 /\ transfers = 0 /\ gives = 0

(* ---- elections ---- *)

(* the election timeout passed: the term goes up, the vote for itself is durable, votes are asked for *)
Timeout(i) ==
  /\ state[i] /= "Leader" /\ promise[i] = NoPromise /\ ~Abstains(i) /\ ~fresh[i] /\ currentTerm[i] < MaxTerm
  /\ currentTerm' = [currentTerm EXCEPT ![i] = currentTerm[i] + 1]
  /\ votedFor' = [votedFor EXCEPT ![i] = i]
  /\ state' = [state EXCEPT ![i] = "Candidate"]
  /\ votes' = [votes EXCEPT ![i] = {i}]
  /\ msgs' = msgs \cup {[mtype |-> "VoteReq", mterm |-> currentTerm[i] + 1, mlastTerm |-> LastTerm(log[i]),
                         mlastIndex |-> Len(log[i]), mnow |-> FALSE, msource |-> i, mdest |-> j] : j \in Server \ {i}}
  /\ UNCHANGED <<log, plog, repair, base, fresh, told, commitIndex, nextIndex, matchIndex, promise, lease, elected, committed, restarts, damages, copies, wipes, transfers, handing, gives>>

(* a vote: a promised server ignores the request, its term included (stickiness); else the newer term is taken
   (a leader steps down) and the vote granted at most once a term, to a log at least as up to date *)
HandleVoteReq(j, m) ==
  /\ m.mtype = "VoteReq" /\ m.mdest = j /\ (Unpromised(j) \/ m.mnow) /\ ~fresh[j]
  /\ LET newer == m.mterm > currentTerm[j]
         term == IF newer THEN m.mterm ELSE currentTerm[j]
         had == IF newer THEN Nil ELSE votedFor[j]
         grant == /\ m.mterm = term /\ had \in {Nil, m.msource} /\ ~Abstains(j)
                  /\ (NoUpToDate \/ UpToDate(m.mlastTerm, m.mlastIndex, log[j]))
     IN /\ currentTerm' = [currentTerm EXCEPT ![j] = term]
        /\ votedFor' = [votedFor EXCEPT ![j] = IF grant THEN m.msource ELSE had]
        /\ state' = [state EXCEPT ![j] = IF newer THEN "Follower" ELSE state[j]]
        /\ lease' = [lease EXCEPT ![j] = IF newer THEN FALSE ELSE lease[j]]
        /\ msgs' = (msgs \ {m}) \cup {[mtype |-> "VoteResp", mterm |-> term, mgranted |-> grant, msource |-> j, mdest |-> m.msource]}
  /\ UNCHANGED <<log, plog, repair, base, fresh, told, commitIndex, votes, nextIndex, matchIndex, promise, elected, committed, restarts, damages, copies, wipes, transfers, handing, gives>>

HandleVoteResp(i, m) ==
  /\ m.mtype = "VoteResp" /\ m.mdest = i /\ m.mterm = currentTerm[i]
  /\ votes' = [votes EXCEPT ![i] = IF state[i] = "Candidate" /\ m.mgranted THEN votes[i] \cup {m.msource} ELSE votes[i]]
  /\ msgs' = msgs \ {m}
  /\ UNCHANGED <<durable, state, commitIndex, nextIndex, matchIndex, promise, lease, elected, committed, restarts, damages, copies, wipes, transfers, handing, gives>>

(* a majority of votes: leader, and its first entry is the no-op of its term *)
BecomeLeader(i) ==
  /\ state[i] = "Candidate" /\ Majority(votes[i])
  /\ state' = [state EXCEPT ![i] = "Leader"]
  /\ log' = [log EXCEPT ![i] = Append(log[i], currentTerm[i])]
  /\ nextIndex' = [nextIndex EXCEPT ![i] = [t \in Server |-> Len(log[i]) + 1]]
  /\ matchIndex' = [matchIndex EXCEPT ![i] = [t \in Server |-> 0]]
  /\ elected' = elected \cup {<<currentTerm[i], i>>}
  /\ handing' = [handing EXCEPT ![i] = FALSE]
  /\ UNCHANGED <<currentTerm, votedFor, plog, repair, base, fresh, told, commitIndex, votes, promise, lease, msgs, committed, restarts, damages, copies, wipes, transfers, gives>>

(* a reply of an older term is dropped *)
DropStale(j, m) ==
  /\ m.mtype \in {"VoteResp", "AppendResp"} /\ m.mdest = j /\ m.mterm < currentTerm[j]
  /\ msgs' = msgs \ {m}
  /\ UNCHANGED <<durable, volatile, promise, lease, elected, committed, restarts, damages, copies, wipes, transfers, handing, gives>>

(* any message of a newer term but a vote request: the term is taken, the server follows *)
UpdateTerm(j, m) ==
  /\ m.mtype \in {"VoteResp", "AppendReq", "AppendResp"} /\ m.mdest = j /\ m.mterm > currentTerm[j] /\ ~fresh[j]
  /\ currentTerm' = [currentTerm EXCEPT ![j] = m.mterm]
  /\ votedFor' = [votedFor EXCEPT ![j] = Nil]
  /\ state' = [state EXCEPT ![j] = "Follower"]
  /\ lease' = [lease EXCEPT ![j] = FALSE]
  /\ UNCHANGED <<log, plog, repair, base, fresh, told, commitIndex, votes, nextIndex, matchIndex, promise, msgs, elected, committed, restarts, damages, copies, wipes, transfers, handing, gives>>

(* CheckQuorum, or any other reason *)
StepDown(i) ==
  /\ state[i] = "Leader"
  /\ state' = [state EXCEPT ![i] = "Follower"]
  /\ lease' = [lease EXCEPT ![i] = FALSE]
  /\ UNCHANGED <<durable, commitIndex, votes, nextIndex, matchIndex, promise, msgs, elected, committed, restarts, damages, copies, wipes, transfers, handing, gives>>

(* ---- the log ---- *)

ClientRequest(i) ==
  /\ state[i] = "Leader" /\ ~handing[i]
  /\ log' = [log EXCEPT ![i] = Append(log[i], currentTerm[i])]
  /\ UNCHANGED <<currentTerm, votedFor, plog, repair, base, fresh, told, volatile, promise, lease, msgs, elected, committed, restarts, damages, copies, wipes, transfers, handing, gives>>

(* the disk forces what was appended *)
Persist(i) ==
  /\ ~Sync /\ plog[i] < Len(log[i])
  /\ plog' = [plog EXCEPT ![i] = Len(log[i])]
  /\ UNCHANGED <<currentTerm, votedFor, log, repair, base, fresh, told, volatile, promise, lease, msgs, elected, committed, restarts, damages, copies, wipes, transfers, handing, gives>>

(* at most one entry a request; a heartbeat carries none. Never from before the log's start: a peer whose next entry
   is there is probed at the start (Snap: the entry before the start, whose term the leader keeps) *)
AppendEntries(i, j) ==
  /\ i /= j /\ state[i] = "Leader"
  /\ LET next == Max(nextIndex[i][j], base[i] + 1)
         prev == next - 1
         entries == IF next <= Len(log[i]) THEN << log[i][next] >> ELSE << >>
     IN msgs' = msgs \cup {[mtype |-> "AppendReq", mterm |-> currentTerm[i], mprevIndex |-> prev,
                            mprevTerm |-> IF prev = 0 THEN 0 ELSE log[i][prev], mentries |-> entries,
                            mcommit |-> Min(commitIndex[i], prev + Len(entries)), msource |-> i, mdest |-> j]}
  /\ UNCHANGED <<durable, volatile, promise, lease, elected, committed, restarts, damages, copies, wipes, transfers, handing, gives>>

Reply(j, m, ok, match) ==
  [mtype |-> "AppendResp", mterm |-> currentTerm[j], msuccess |-> ok, mmatch |-> match, msource |-> j, mdest |-> m.msource]

(* an append of the server's term: it follows that leader and promises it; an older one is refused *)
HandleAppendReq(j, m) ==
  /\ m.mtype = "AppendReq" /\ m.mdest = j /\ m.mterm <= currentTerm[j] /\ ~fresh[j]
  /\ IF m.mterm < currentTerm[j]
     THEN /\ msgs' = (msgs \ {m}) \cup {Reply(j, m, FALSE, 0)}
          /\ UNCHANGED <<durable, volatile, promise, lease, elected, committed, restarts, damages, copies, wipes, transfers, handing, gives>>
     ELSE
       LET ok == m.mprevIndex = 0 \/ (m.mprevIndex <= Len(log[j]) /\ log[j][m.mprevIndex] = m.mprevTerm)
           at == m.mprevIndex + 1
           keep == \/ m.mentries = << >>
                   \/ (at <= Len(log[j]) /\ log[j][at] = m.mentries[1])
           new == IF keep THEN log[j] ELSE SubSeq(log[j], 1, m.mprevIndex) \o m.mentries
           forced == IF keep THEN plog[j] ELSE Min(plog[j], m.mprevIndex)
           upto == m.mprevIndex + Len(m.mentries)
           match == IF AckUnforced \/ Sync THEN upto ELSE Min(upto, forced)
           repaired == /\ repair[j] > 0 /\ match >= repair[j]
                       /\ (RepairEarly \/ m.mcommit >= repair[j])
       IN /\ state' = [state EXCEPT ![j] = "Follower"]
          /\ promise' = [promise EXCEPT ![j] = IF Leases THEN <<m.msource, m.mterm>> ELSE promise[j]]
          /\ IF ~ok
             THEN /\ msgs' = (msgs \ {m}) \cup {Reply(j, m, FALSE, 0)}
                  /\ UNCHANGED <<durable, commitIndex>>
             ELSE /\ log' = [log EXCEPT ![j] = new]
                  /\ plog' = [plog EXCEPT ![j] = forced]
                  /\ repair' = [repair EXCEPT ![j] = IF repaired THEN 0 ELSE repair[j]]
                  /\ commitIndex' = [commitIndex EXCEPT ![j] = Max(commitIndex[j], m.mcommit)]
                  /\ msgs' = (msgs \ {m}) \cup {Reply(j, m, TRUE, match)}
                  /\ UNCHANGED <<currentTerm, votedFor, base, fresh, told>>
          /\ UNCHANGED <<votes, nextIndex, matchIndex, lease, elected, committed, restarts, damages, copies, wipes, transfers, handing, gives>>

HandleAppendResp(i, m) ==
  /\ m.mtype = "AppendResp" /\ m.mdest = i /\ m.mterm = currentTerm[i]
  /\ msgs' = msgs \ {m}
  /\ LET j == m.msource IN
     IF state[i] /= "Leader" THEN UNCHANGED <<nextIndex, matchIndex>>
     ELSE IF m.msuccess
     THEN /\ matchIndex' = [matchIndex EXCEPT ![i][j] = Max(matchIndex[i][j], m.mmatch)]
          /\ nextIndex' = [nextIndex EXCEPT ![i][j] = Max(matchIndex[i][j], m.mmatch) + 1]
     ELSE /\ nextIndex' = [nextIndex EXCEPT ![i][j] = Max(nextIndex[i][j] - 1, 1)]
          /\ UNCHANGED matchIndex
  /\ UNCHANGED <<durable, state, commitIndex, votes, promise, lease, elected, committed, restarts, damages, copies, wipes, transfers, handing, gives>>

(* the newest index a majority holds forced, if its entry is of the leader's term (or any, in CommitOldTerm) *)
AdvanceCommitIndex(i) ==
  /\ state[i] = "Leader"
  /\ LET agree(n) == {k \in Server \ {i} : matchIndex[i][k] >= n} \cup (IF Acked(i) >= n THEN {i} ELSE {})
         ns == {n \in 1..Len(log[i]) : Majority(agree(n))}
         top == IF ns = {} THEN 0 ELSE CHOOSE n \in ns : \A k \in ns : k <= n
     IN /\ top > commitIndex[i]
        /\ CommitOldTerm \/ log[i][top] = currentTerm[i]
        /\ commitIndex' = [commitIndex EXCEPT ![i] = top]
        /\ committed' = committed \cup {<<n, log[i][n], currentTerm[i]>> : n \in 1..top}
  /\ UNCHANGED <<durable, state, votes, nextIndex, matchIndex, promise, lease, msgs, elected, restarts, damages, copies, wipes, transfers, handing, gives>>

(* ---- leases ---- *)

GetLease(i) ==
  /\ Leases /\ state[i] = "Leader" /\ ~lease[i] /\ (~handing[i] \/ TransferKeepsLease)
  /\ Majority({i} \cup {j \in Server : promise[j] = <<i, currentTerm[i]>>})
  /\ lease' = [lease EXCEPT ![i] = TRUE]
  /\ UNCHANGED <<durable, volatile, promise, msgs, elected, committed, restarts, damages, copies, wipes, transfers, handing, gives>>

ExpireLease(i) ==
  /\ lease[i]
  /\ lease' = [lease EXCEPT ![i] = FALSE]
  /\ UNCHANGED <<durable, volatile, promise, msgs, elected, committed, restarts, damages, copies, wipes, transfers, handing, gives>>

(* a promise ends only after the lease it may support (clocks within their bound) *)
ExpirePromise(j) ==
  /\ promise[j] /= NoPromise
  /\ LET l == promise[j][1] IN
       PromiseFirst \/ ~(state[l] = "Leader" /\ lease[l] /\ currentTerm[l] = promise[j][2])
  /\ promise' = [promise EXCEPT ![j] = NoPromise]
  /\ UNCHANGED <<durable, volatile, lease, msgs, elected, committed, restarts, damages, copies, wipes, transfers, handing, gives>>

(* ---- faults ---- *)

Reset(i) ==
  /\ state' = [state EXCEPT ![i] = "Follower"]
  /\ commitIndex' = [commitIndex EXCEPT ![i] = base[i]]
  /\ votes' = [votes EXCEPT ![i] = {}]
  /\ nextIndex' = [nextIndex EXCEPT ![i] = [t \in Server |-> 1]]
  /\ matchIndex' = [matchIndex EXCEPT ![i] = [t \in Server |-> 0]]
  /\ lease' = [lease EXCEPT ![i] = FALSE]
  /\ votedFor' = [votedFor EXCEPT ![i] = IF VolatileVote THEN Nil ELSE votedFor[i]]
  /\ promise' = [promise EXCEPT ![i] = IF RestartForgets THEN NoPromise ELSE promise[i]]

(* a crash and a restart: what was not forced is lost *)
Restart(i) ==
  /\ restarts < MaxRestart
  /\ Reset(i)
  /\ log' = [log EXCEPT ![i] = SubSeq(log[i], 1, Forced(i))]
  /\ restarts' = restarts + 1
  /\ UNCHANGED <<currentTerm, plog, repair, base, fresh, told, msgs, elected, committed, damages, copies, wipes, transfers, handing, gives>>

(* a restart whose recovery finds forced entry d damaged: the log before it is kept; the server records the newest
   index it may have acknowledged (NoAbstain: it goes on as if its log were shorter) *)
Damage(i) ==
  /\ damages < MaxDamage /\ Forced(i) > base[i]
  /\ \E d \in (base[i] + 1)..Forced(i) :
       /\ log' = [log EXCEPT ![i] = SubSeq(log[i], 1, d - 1)]
       /\ plog' = [plog EXCEPT ![i] = d - 1]
  /\ repair' = [repair EXCEPT ![i] = Max(repair[i], Len(log[i]))]
  /\ Reset(i)
  /\ damages' = damages + 1
  /\ UNCHANGED <<currentTerm, base, fresh, told, msgs, elected, committed, restarts, copies, wipes, transfers, handing, gives>>

(* ---- the log's start and copies ---- *)

(* the databases hold every entry up to x: the log's start moves there, behind what this server knows committed and
   holds forced (no floor: any server, any time) *)
Compact(i) ==
  /\ MaxCopy > 0
  /\ \E x \in (base[i] + 1)..Min(commitIndex[i], Forced(i)) : base' = [base EXCEPT ![i] = x]
  /\ UNCHANGED <<currentTerm, votedFor, log, plog, repair, fresh, told, volatile, promise, lease, msgs, elected, committed, restarts, damages, copies, wipes, transfers, handing, gives>>

(* a server gives another its databases at x (copied as cepheus backup copies them): its state at or after its log's
   start, within what it knows committed (CopyUncommitted: anything its log holds) *)
SendCopy(i, j) ==
  /\ i /= j /\ copies < MaxCopy
  /\ \E x \in Max(base[i], 1)..(IF CopyUncommitted THEN Len(log[i]) ELSE commitIndex[i]) :
       msgs' = msgs \cup {[mtype |-> "Copy", mindex |-> x, mentries |-> SubSeq(log[i], 1, x), msource |-> i, mdest |-> j]}
  /\ copies' = copies + 1
  /\ UNCHANGED <<durable, volatile, promise, lease, elected, committed, restarts, damages, wipes, transfers, handing, gives>>

(* a copy installed, forced: unless the databases are at x already, or the log holds entry x of the same term (its
   entries after x kept, the copy dropped: Raft's rule; CopyDiscards installs it anyway), the log becomes the copy's,
   its start x, the commit index at least x, and the 2018 rule's repair ends once x reaches it *)
HandleCopy(j, m) ==
  /\ m.mtype = "Copy" /\ m.mdest = j /\ ~fresh[j]
  /\ msgs' = msgs \ {m}
  /\ LET x == m.mindex
         holds == x <= Len(log[j]) /\ log[j][x] = m.mentries[x]
     IN IF x <= base[j] \/ (holds /\ ~CopyDiscards)
        THEN UNCHANGED <<durable, volatile>>
        ELSE /\ log' = [log EXCEPT ![j] = m.mentries]
             /\ plog' = [plog EXCEPT ![j] = x]
             /\ base' = [base EXCEPT ![j] = x]
             /\ commitIndex' = [commitIndex EXCEPT ![j] = Max(commitIndex[j], x)]
             /\ repair' = [repair EXCEPT ![j] = IF repair[j] <= x THEN 0 ELSE repair[j]]
             /\ UNCHANGED <<currentTerm, votedFor, fresh, told, state, votes, nextIndex, matchIndex>>
  /\ UNCHANGED <<promise, lease, elected, committed, restarts, damages, copies, wipes, transfers, handing, gives>>

(* ---- a lost disk ---- *)

Sound(s) == ~fresh[s] /\ repair[s] = 0

(* the whole state lost, while the damaged and the wiped stay a minority *)
Wipe(i) ==
  /\ wipes < MaxWipe
  /\ Cardinality({s \in Server : s = i \/ ~Sound(s)}) * 2 < Cardinality(Server)
  /\ currentTerm' = [currentTerm EXCEPT ![i] = 0]
  /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
  /\ log' = [log EXCEPT ![i] = << >>]
  /\ plog' = [plog EXCEPT ![i] = 0]
  /\ repair' = [repair EXCEPT ![i] = 0]
  /\ base' = [base EXCEPT ![i] = 0]
  /\ fresh' = [fresh EXCEPT ![i] = TRUE]
  /\ told' = [told EXCEPT ![i] = [t \in Server |-> NoAnswer]]
  /\ state' = [state EXCEPT ![i] = "Follower"]
  /\ commitIndex' = [commitIndex EXCEPT ![i] = 0]
  /\ votes' = [votes EXCEPT ![i] = {}]
  /\ nextIndex' = [nextIndex EXCEPT ![i] = [t \in Server |-> 1]]
  /\ matchIndex' = [matchIndex EXCEPT ![i] = [t \in Server |-> 0]]
  /\ lease' = [lease EXCEPT ![i] = FALSE]
  /\ wipes' = wipes + 1
  /\ handing' = [handing EXCEPT ![i] = FALSE]
  /\ UNCHANGED <<promise, msgs, elected, committed, restarts, damages, copies, transfers, gives>>

(* a fresh server asks another *)
Ask(i, j) ==
  /\ fresh[i] /\ i /= j
  /\ msgs' = msgs \cup {[mtype |-> "Ask", msource |-> i, mdest |-> j]}
  /\ UNCHANGED <<durable, volatile, promise, lease, elected, committed, restarts, damages, copies, wipes, transfers, handing, gives>>

(* a damaged server answers nothing (its log may lack what it acknowledged, and it has a history) *)
HandleAsk(j, m) ==
  /\ m.mtype = "Ask" /\ m.mdest = j /\ repair[j] = 0
  /\ msgs' = (msgs \ {m}) \cup {[mtype |-> "State", mterm |-> currentTerm[j], mlast |-> Len(log[j]), mfresh |-> fresh[j],
                                  msource |-> j, mdest |-> m.msource]}
  /\ UNCHANGED <<durable, volatile, promise, lease, elected, committed, restarts, damages, copies, wipes, transfers, handing, gives>>

HandleState(i, m) ==
  /\ m.mtype = "State" /\ m.mdest = i
  /\ msgs' = msgs \ {m}
  /\ told' = IF fresh[i] THEN [told EXCEPT ![i][m.msource] = <<m.mterm, m.mlast, m.mfresh>>] ELSE told
  /\ UNCHANGED <<currentTerm, votedFor, log, plog, repair, base, fresh, volatile, promise, lease, elected, committed, restarts, damages, copies, wipes, transfers, handing, gives>>

(* a fresh server's freshness ends: with the answers of floor(n/2) + 1 others that are not fresh, or with a majority
   of fresh servers or every other one answering with no history (a new cluster) *)
EndFresh(i) ==
  /\ fresh[i]
  /\ LET answered == {t \in Server : told[i][t] /= NoAnswer}
         sound == {t \in answered : ~told[i][t][3]}
         none == \A t \in answered : told[i][t][3] \/ (told[i][t][1] = 0 /\ told[i][t][2] = 0)
         need == IF FreshHearOne THEN 1 ELSE Cardinality(Server) \div 2 + 1
         Top(S, k) == IF S = {} THEN 0 ELSE CHOOSE x \in {told[i][t][k] : t \in S} : \A t \in S : told[i][t][k] <= x
     IN /\ \/ Cardinality(sound) >= need
           \/ sound = {} /\ Majority(answered \cup {i})
           \/ none /\ answered = Server \ {i}
        /\ currentTerm' = [currentTerm EXCEPT ![i] = Max(currentTerm[i], Top(answered, 1))]
        /\ votedFor' = [votedFor EXCEPT ![i] = i]
        /\ repair' = [repair EXCEPT ![i] = IF FreshNoRepair THEN repair[i] ELSE Max(repair[i], Top(sound, 2))]
        /\ fresh' = [fresh EXCEPT ![i] = FALSE]
  /\ UNCHANGED <<log, plog, base, told, volatile, promise, lease, msgs, elected, committed, restarts, damages, copies, wipes, transfers, handing, gives>>

(* what a fresh server takes no part in, and the answers it is too late for *)
DropFresh(j, m) ==
  /\ m.mdest = j
  /\ \/ fresh[j] /\ m.mtype \in {"VoteReq", "VoteResp", "AppendReq", "AppendResp", "Copy", "TimeoutNow"}
     \/ ~fresh[j] /\ m.mtype = "State"
     \/ repair[j] > 0 /\ m.mtype = "Ask"
  /\ msgs' = msgs \ {m}
  /\ UNCHANGED <<durable, volatile, promise, lease, elected, committed, restarts, damages, copies, wipes, transfers, handing, gives>>

(* ---- leadership handed over ---- *)

(* a leader whose peer holds its whole log hands over to it: its lease given up first (TransferKeepsLease: kept),
   no request taken from then on *)
TransferLeader(i, j) ==
  /\ transfers < MaxTransfer /\ i /= j /\ state[i] = "Leader" /\ matchIndex[i][j] = Len(log[i])
  /\ handing' = [handing EXCEPT ![i] = TRUE]
  /\ lease' = [lease EXCEPT ![i] = IF TransferKeepsLease THEN lease[i] ELSE FALSE]
  /\ msgs' = msgs \cup {[mtype |-> "TimeoutNow", mterm |-> currentTerm[i], msource |-> i, mdest |-> j]}
  /\ transfers' = transfers + 1
  /\ UNCHANGED <<durable, volatile, promise, elected, committed, restarts, damages, copies, wipes, gives>>

(* the peer stands at once, whatever its promise, its vote requests marked; a late or stale one is dropped *)
HandleTimeoutNow(j, m) ==
  /\ m.mtype = "TimeoutNow" /\ m.mdest = j /\ ~fresh[j]
  /\ IF m.mterm = currentTerm[j] /\ state[j] = "Follower" /\ ~Abstains(j) /\ currentTerm[j] < MaxTerm
     THEN /\ currentTerm' = [currentTerm EXCEPT ![j] = currentTerm[j] + 1]
          /\ votedFor' = [votedFor EXCEPT ![j] = j]
          /\ state' = [state EXCEPT ![j] = "Candidate"]
          /\ votes' = [votes EXCEPT ![j] = {j}]
          /\ msgs' = (msgs \ {m}) \cup {[mtype |-> "VoteReq", mterm |-> currentTerm[j] + 1, mlastTerm |-> LastTerm(log[j]),
                                          mlastIndex |-> Len(log[j]), mnow |-> TRUE, msource |-> j, mdest |-> k] : k \in Server \ {j}}
          /\ UNCHANGED <<log, plog, repair, base, fresh, told, commitIndex, nextIndex, matchIndex>>
     ELSE /\ msgs' = msgs \ {m}
          /\ UNCHANGED <<durable, volatile>>
  /\ UNCHANGED <<promise, lease, handing, elected, committed, restarts, damages, copies, wipes, transfers, gives>>

(* ---- a damaged server repaired by any peer ---- *)

(* a sound server gives a damaged one the entries after prev, up to its commit index (RepairUncommitted: its log) *)
GiveEntries(i, j) ==
  /\ gives < MaxGive /\ i /= j /\ repair[j] > 0 /\ repair[i] = 0 /\ ~fresh[i]
  /\ LET top == IF RepairUncommitted THEN Len(log[i]) ELSE Min(commitIndex[i], Len(log[i])) IN
     \E prev \in base[i]..top :
       msgs' = msgs \cup {[mtype |-> "Entries", mprevIndex |-> prev, mprevTerm |-> IF prev = 0 THEN 0 ELSE log[i][prev],
                            mentries |-> SubSeq(log[i], prev + 1, top), mcommit |-> top, msource |-> i, mdest |-> j]}
  /\ gives' = gives + 1
  /\ UNCHANGED <<durable, volatile, promise, lease, handing, elected, committed, restarts, damages, copies, wipes, transfers>>

(* the damaged server takes them if it holds the entry before them (a conflicting entry of its own cut) *)
HandleEntries(j, m) ==
  /\ m.mtype = "Entries" /\ m.mdest = j
  /\ msgs' = msgs \ {m}
  /\ LET prev == m.mprevIndex
         es == m.mentries
         upto == prev + Len(es)
         ok == repair[j] > 0 /\ ~fresh[j] /\ state[j] /= "Leader"
               /\ (prev = 0 \/ prev <= base[j] \/ (prev <= Len(log[j]) /\ log[j][prev] = m.mprevTerm))
         agree == \A n \in 1..Min(Len(es), Len(log[j]) - prev) : log[j][prev + n] = es[n]
         new == IF agree /\ Len(log[j]) >= upto THEN log[j] ELSE SubSeq(log[j], 1, prev) \o es
     IN IF ok
        THEN /\ log' = [log EXCEPT ![j] = new]
             /\ plog' = [plog EXCEPT ![j] = Len(new)]
             /\ commitIndex' = [commitIndex EXCEPT ![j] = Max(commitIndex[j], Min(m.mcommit, upto))]
             /\ repair' = [repair EXCEPT ![j] = IF upto >= repair[j] /\ m.mcommit >= repair[j] THEN 0 ELSE repair[j]]
             /\ UNCHANGED <<currentTerm, votedFor, base, fresh, told, state, votes, nextIndex, matchIndex>>
        ELSE UNCHANGED <<durable, volatile>>
  /\ UNCHANGED <<promise, lease, handing, elected, committed, restarts, damages, copies, wipes, transfers, gives>>

Next ==
  \/ \E i \in Server : \/ Timeout(i) \/ BecomeLeader(i) \/ StepDown(i) \/ ClientRequest(i)
                       \/ Persist(i) \/ AdvanceCommitIndex(i) \/ GetLease(i) \/ ExpireLease(i) \/ ExpirePromise(i)
                       \/ Restart(i) \/ Damage(i) \/ Compact(i) \/ Wipe(i) \/ EndFresh(i)
  \/ \E i, j \in Server : AppendEntries(i, j) \/ SendCopy(i, j) \/ Ask(i, j) \/ TransferLeader(i, j) \/ GiveEntries(i, j)
  \/ \E m \in msgs : \E j \in Server :
       \/ HandleVoteReq(j, m) \/ HandleVoteResp(j, m)
       \/ UpdateTerm(j, m) \/ DropStale(j, m) \/ HandleAppendReq(j, m) \/ HandleAppendResp(j, m) \/ HandleCopy(j, m)
       \/ HandleAsk(j, m) \/ HandleState(j, m) \/ DropFresh(j, m) \/ HandleTimeoutNow(j, m) \/ HandleEntries(j, m)

Spec == Init /\ [][Next]_vars

Bounds == /\ \A s \in Server : Len(log[s]) <= MaxLog /\ currentTerm[s] <= MaxTerm
          /\ Cardinality(msgs) <= MaxMsgs

Perms == Permutations(Server)

(* ---- what must hold ---- *)

(* at most one leader a term *)
ElectionSafety == \A x, y \in elected : x[1] = y[1] => x[2] = y[2]

(* two logs that agree on an entry's term agree on everything before it *)
LogMatching ==
  \A i, j \in Server : \A n \in 1..Min(Len(log[i]), Len(log[j])) :
    log[i][n] = log[j][n] => SubSeq(log[i], 1, n) = SubSeq(log[j], 1, n)

(* every leader of a later term holds every committed entry *)
LeaderCompleteness ==
  \A e \in committed : \A i \in Server :
    (state[i] = "Leader" /\ currentTerm[i] > e[3]) => (e[1] <= Len(log[i]) /\ log[i][e[1]] = e[2])

(* no two different entries committed at one index (no committed write lost) *)
StateMachineSafety == \A x, y \in committed : x[1] = y[1] => x[2] = y[2]

(* a read on a leader under its lease sees every committed entry (G15 on the leader) *)
ReadFresh ==
  \A i \in Server : (state[i] = "Leader" /\ lease[i] /\ (ReadEarly \/ Ready(i))) =>
    \A e \in committed : e[1] <= commitIndex[i] /\ log[i][e[1]] = e[2]

(* a server's commit index never passes its log *)
CommitInLog == \A i \in Server : commitIndex[i] <= Len(log[i])

(* what a server takes for committed is (its databases, its commit index): never an entry that was not *)
CommittedPrefix ==
  \A i \in Server : base[i] <= commitIndex[i] /\ \A n \in 1..commitIndex[i] : \E e \in committed : e[1] = n /\ e[2] = log[i][n]
=============================================================================
