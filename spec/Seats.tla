------------------------------- MODULE Seats -------------------------------
(* Selling concert seats with many buyers at once, as docs/case-seats.md tells it.

   Each buyer reads a view (the owners of the seats as of one group), picks a seat that is free in it, and writes the
   sale: the seat's owner and the buyer's charge, in one group (atomic, G2). The single writer applies the groups one
   at a time, each on the newest state (G4). In the naive sale the group is unconditional; in the sale with Expect,
   the group carries Expect(seat has no owner), which the writer checks on the newest state: if another buyer took the
   seat since the view, the group is refused (Conflict) and the buyer reads again. A crash may come at any moment: a
   group is durable once confirmed (G1), so a crash only loses the buyers' reads, never a confirmed sale. *)
EXTENDS Naturals, FiniteSets

CONSTANTS Buyers, Seats, Naive, None  \* None: a model value, no buyer and no seat

VARIABLES
  owner,  \* the database: Seats -> Buyers \cup {None}, the owner of each seat
  sales,  \* the database: the charges, a set of <<buyer, seat>>
  pc,     \* each buyer: "looking", "read" (a view taken, a seat picked) or "served"
  pick    \* each buyer: the seat it picked in its view

vars == <<owner, sales, pc, pick>>

Init ==
  /\ owner = [s \in Seats |-> None]
  /\ sales = {}
  /\ pc = [b \in Buyers |-> "looking"]
  /\ pick = [b \in Buyers |-> None]

(* A view taken, and a seat free in it picked (the view is the state at this step). *)
Read(b) ==
  /\ pc[b] = "looking"
  /\ \E s \in Seats :
       /\ owner[s] = None
       /\ pick' = [pick EXCEPT ![b] = s]
  /\ pc' = [pc EXCEPT ![b] = "read"]
  /\ UNCHANGED <<owner, sales>>

(* The group, applied by the writer on the newest state: the owner and the charge together; with Expect, only if the
   seat is still free, else a Conflict and the buyer looks again. *)
Write(b) ==
  /\ pc[b] = "read"
  /\ LET s == pick[b] IN
       IF Naive \/ owner[s] = None
       THEN /\ owner' = [owner EXCEPT ![s] = b]
            /\ sales' = sales \cup {<<b, s>>}
            /\ pc' = [pc EXCEPT ![b] = "served"]
       ELSE /\ pc' = [pc EXCEPT ![b] = "looking"]
            /\ UNCHANGED <<owner, sales>>
  /\ UNCHANGED pick

(* The process dies and recovers: confirmed groups stay (G1), the buyers' views are lost. *)
Crash ==
  /\ pc' = [b \in Buyers |-> IF pc[b] = "served" THEN "served" ELSE "looking"]
  /\ UNCHANGED <<owner, sales, pick>>

Next == Crash \/ \E b \in Buyers : Read(b) \/ Write(b)

Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ owner \in [Seats -> Buyers \cup {None}]
  /\ sales \subseteq Buyers \X Seats
  /\ pc \in [Buyers -> {"looking", "read", "served"}]
  /\ pick \in [Buyers -> Seats \cup {None}]

(* Never sell the same seat twice: at most one charge a seat. *)
NoDoubleSale == \A s \in Seats : Cardinality({b \in Buyers : <<b, s>> \in sales}) <= 1

(* No buyer charged for a seat they do not get. *)
NoChargeWithoutSeat == \A b \in Buyers, s \in Seats : <<b, s>> \in sales => owner[s] = b

=============================================================================
