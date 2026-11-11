---------------------------------- MODULE Watch ----------------------------------
(* A watch over the wire, and how it resumes (server/live.ml, server/core.ml, cesia/native/conn.ml).

   The server writes groups 1, 2, ...; A[k] is the question's answer at group k, any set of rows, chosen when group k
   is written; Touched[k] says that group k changed a fact of the question's patterns, which every group that changes
   the answer does (a group may touch and leave the answer as it was). The server's ring of recent changes covers the
   groups after RingFrom, and forgets old ones at any moment.

   The program watches over one connection at a time: each Watch takes a new id, and carries From, the group of the
   last message it applied (0 for none). The server answers Same(g) when it can tell that nothing the question reads
   changed since From (From is covered by the ring and no group after it touches the question), else Answer(g, A[g]);
   then a Change after each group that changes the answer: the rows added and removed. A watch may fall behind: the
   server ends it (Lagging) and the program watches again from its group, on the same connection. The connection may
   break at any moment: what was in flight is lost, and the program watches again on a new one. The program may also
   stop a watch and start it again at once (Unwatch then Watch, without waiting): the old watch's messages still in
   flight then come after the new Watch was sent, and are dropped by their id.

   Checked (tools/tlc.sh): the program's rows are always the answer at the group of its last message (no gap, no
   duplicate), and the groups of the messages it applies never go back. Each variant drops one part of the rule and
   must break: Same without the touches (NoTouch), Same for a From the ring does not cover (NoRing). (Taking the old
   watch's messages too is harmless here: one connection keeps their order, and they all come before the new watch's
   first message, so the id is a convenience of the package, not a part of the rule.) *)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Rows, MaxGroup, MaxIds, Variant

VARIABLES
  g,        \* the newest group
  A,        \* the answer at each group
  Touched,  \* each group touches the question
  RingFrom, \* the ring holds the changes after this group
  net,      \* the current connection, server to program: messages in order
  req,      \* the current connection, program to server: the Watch not yet read, or <<>>
  sub,      \* the server's watch on the current connection: its id, 0 for none
  ids,      \* ids given so far
  cur,      \* the id of the program's watch
  R,        \* the program's rows
  G,        \* the group of its last message
  started,  \* it has applied an answer
  back      \* a message went back in time: must stay FALSE

vars == <<g, A, Touched, RingFrom, net, req, sub, ids, cur, R, G, started, back>>

Msg(id, kind, grp, rows, add, rem) == [id |-> id, kind |-> kind, grp |-> grp, rows |-> rows, add |-> add, rem |-> rem]

Init ==
  /\ g = 0
  /\ A = [k \in 0..MaxGroup |-> {}]
  /\ Touched = [k \in 0..MaxGroup |-> FALSE]
  /\ RingFrom = 0
  /\ net = <<>>
  /\ ids = 1
  /\ cur = 1
  /\ req = <<[id |-> 1, from |-> 0]>>
  /\ sub = 0
  /\ R = {}
  /\ G = 0
  /\ started = FALSE
  /\ back = FALSE

(* a group: its answer, and whether it touches the question (it must when the answer changes); the server's watch
   sends the change, if any *)
Write ==
  /\ g < MaxGroup
  /\ \E a \in SUBSET Rows, t \in BOOLEAN :
       /\ (a # A[g]) => t
       /\ A' = [A EXCEPT ![g + 1] = a]
       /\ Touched' = [Touched EXCEPT ![g + 1] = t]
       /\ net' = IF sub # 0 /\ a # A[g] THEN Append(net, Msg(sub, "change", g + 1, {}, a \ A[g], A[g] \ a)) ELSE net
  /\ g' = g + 1
  /\ UNCHANGED <<RingFrom, req, sub, ids, cur, R, G, started, back>>

(* the ring forgets old changes *)
Forget ==
  /\ RingFrom < g
  /\ RingFrom' = RingFrom + 1
  /\ UNCHANGED <<g, A, Touched, net, req, sub, ids, cur, R, G, started, back>>

(* the rule of Live.subscribe *)
CanSame(n) ==
  /\ n > 0
  /\ n <= g
  /\ (Variant = "NoRing" \/ n >= RingFrom)
  /\ (Variant = "NoTouch" \/ \A k \in (n + 1)..g : (Variant = "NoRing" /\ k <= RingFrom) \/ ~Touched[k])

(* the server reads the Watch: its first message *)
Subscribe ==
  /\ req # <<>>
  /\ LET w == Head(req) IN
       /\ sub' = w.id
       /\ net' = Append(net, IF CanSame(w.from) THEN Msg(w.id, "same", g, {}, {}, {}) ELSE Msg(w.id, "answer", g, A[g], {}, {}))
  /\ req' = Tail(req)
  /\ UNCHANGED <<g, A, Touched, RingFrom, ids, cur, R, G, started, back>>

(* the watch falls behind: its queue is dropped, the server ends it *)
Lag ==
  /\ sub # 0
  /\ net' = Append(net, Msg(sub, "lagging", 0, {}, {}, {}))
  /\ sub' = 0
  /\ UNCHANGED <<g, A, Touched, RingFrom, req, ids, cur, R, G, started, back>>

NewWatch == /\ ids < MaxIds
            /\ ids' = ids + 1
            /\ cur' = ids + 1

(* the connection breaks: everything in flight is lost; the program watches again on a new one *)
Break ==
  /\ NewWatch
  /\ net' = <<>>
  /\ sub' = 0
  /\ req' = <<[id |-> ids + 1, from |-> IF started THEN G ELSE 0]>>
  /\ UNCHANGED <<g, A, Touched, RingFrom, R, G, started, back>>

(* the program stops its watch and starts it again at once: Unwatch then Watch, without waiting *)
Rewatch ==
  /\ NewWatch
  /\ req' = Append(req, [id |-> ids + 1, from |-> IF started THEN G ELSE 0])
  /\ sub' = 0
  /\ UNCHANGED <<g, A, Touched, RingFrom, net, R, G, started, back>>

(* the program applies the next message (conn.ml's deliver) *)
Receive ==
  /\ net # <<>>
  /\ LET m == Head(net) IN
       IF m.id # cur THEN UNCHANGED <<ids, cur, req, R, G, started, back>>
       ELSE IF m.kind = "lagging" THEN
         /\ NewWatch
         /\ req' = Append(req, [id |-> ids + 1, from |-> IF started THEN G ELSE 0])
         /\ UNCHANGED <<R, G, started, back>>
       ELSE
         /\ back' = (back \/ m.grp < G \/ (m.kind = "change" /\ m.grp = G))
         /\ R' = CASE m.kind = "answer" -> m.rows
                   [] m.kind = "same" -> R
                   [] m.kind = "change" -> (R \ m.rem) \cup m.add
         /\ G' = m.grp
         /\ started' = (started \/ m.kind = "answer")
         /\ UNCHANGED <<ids, cur, req>>
  /\ net' = Tail(net)
  /\ UNCHANGED <<g, A, Touched, RingFrom, sub>>

Next == Write \/ Forget \/ Subscribe \/ Lag \/ Break \/ Rewatch \/ Receive

Spec == Init /\ [][Next]_vars

(* the program's rows are the answer at its group, and its groups never go back *)
RowsRight == started => R = A[G]
NoBack == ~back
==================================================================================
