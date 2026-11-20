------------------------------- MODULE WatchWindow -------------------------------
(* A watch with Sort and Limit: the rows it holds after each frame (server/live.ml, its window).

   The rows of the question are 1..N in the watch's order (Sort's keys, then every other column: two rows equal in the
   order are copies of one row). The answer is a bag: each row with its copies (a projecting Give), at most MaxCopies.
   K is the Limit (0: none). Find with Limit K gives the first K rows and every copy of the K-th: Top(B, K).

   The watch holds Held and Complete (Held is the whole answer). At each frame the delta queries give the rows added
   and the rows removed (any rows of the answer may go, any may come), and the window's rule moves them in:
     L, the last row held; a row is inside when it comes at or before L, or when Held is the whole answer;
     C = Held less the removed rows inside, plus the added rows inside;
     with K or more rows in C, Held' = Top(C, K); with fewer, and Held not the whole answer, the rows after L are
     asked of the new answer (Find After L, Limit the rows missing) and added: a refill that finds fewer than asked
     found them all.

   Checked (tools/tlc.sh): after every frame Held is Find's rows (Top of the answer), Complete says the truth, and every
   removed row inside the window was held. Each variant drops a part of the rule and must break: no refill (NoRefill),
   a cut that splits the copies of the K-th row (NoTies), inside meaning strictly before L (Strict). *)
EXTENDS Naturals, FiniteSets

CONSTANTS N, MaxCopies, MaxK, Variant

Rows == 1..N
Bags == [Rows -> 0..MaxCopies]

RECURSIVE SumOver(_, _)
SumOver(B, S) == IF S = {} THEN 0 ELSE LET x == CHOOSE x \in S : TRUE IN B[x] + SumOver(B, S \ {x})

Size(B) == SumOver(B, Rows)
UpTo(B, r) == SumOver(B, {s \in Rows : s <= r})

\* the first k rows of B and every copy of the k-th (k = 0: all of them)
Top(B, k) ==
  IF k = 0 \/ Size(B) <= k THEN B
  ELSE LET kth == CHOOSE r \in Rows : UpTo(B, r) >= k /\ \A s \in Rows : s < r => UpTo(B, s) < k
       IN [r \in Rows |-> IF r < kth THEN B[r]
                          ELSE IF r = kth THEN (IF Variant = "NoTies" THEN k - UpTo(B, r - 1) ELSE B[r])
                          ELSE 0]

\* Find's rows, with ties: what the watch must hold
Find(B, k) ==
  IF k = 0 \/ Size(B) <= k THEN B
  ELSE LET kth == CHOOSE r \in Rows : UpTo(B, r) >= k /\ \A s \in Rows : s < r => UpTo(B, s) < k
       IN [r \in Rows |-> IF r <= kth THEN B[r] ELSE 0]

After(B, l) == [r \in Rows |-> IF r > l THEN B[r] ELSE 0]

VARIABLES
  k,        \* the Limit
  A,        \* the answer
  Held,     \* the rows the watch holds
  Complete, \* Held is the whole answer
  lost      \* a removed row inside the window that was not held: must stay FALSE

vars == <<k, A, Held, Complete, lost>>

Init ==
  /\ k \in 0..MaxK
  /\ A \in Bags
  /\ Held = Find(A, k)
  /\ Complete = (k = 0 \/ Size(A) < k)
  /\ lost = FALSE

Frame ==
  \E rem \in Bags, add \in Bags :
    /\ \A r \in Rows : rem[r] <= A[r] /\ A[r] - rem[r] + add[r] <= MaxCopies
    /\ LET A2 == [r \in Rows |-> A[r] - rem[r] + add[r]]
           L == IF \E r \in Rows : Held[r] > 0 THEN CHOOSE r \in Rows : Held[r] > 0 /\ \A s \in Rows : s > r => Held[s] = 0 ELSE 0
           Inside(r) == Complete \/ (IF Variant = "Strict" THEN r < L ELSE r <= L)
           C == [r \in Rows |-> IF Inside(r) THEN Held[r] - rem[r] + add[r] ELSE Held[r]]
           Cut == Top(C, k)
           cut == Cut # C
           Need == k - Size(C)
           More == Find(After(A2, L), Need)
           Refill == k > 0 /\ Size(C) < k /\ ~Complete /\ Variant # "NoRefill"
       IN /\ A' = A2
          /\ lost' = (lost \/ \E r \in Rows : Inside(r) /\ rem[r] > Held[r])
          /\ IF Refill
               THEN /\ Held' = [r \in Rows |-> C[r] + More[r]]
                    /\ Complete' = (Size(More) < Need)
               ELSE /\ Held' = Cut
                    /\ Complete' = (Complete /\ ~cut)
    /\ UNCHANGED k

Spec == Init /\ [][Frame]_vars

\* after every frame the watch holds Find's rows, and Complete says the truth
RowsRight == Held = Find(A, k)
CompleteRight == Complete => Held = A
NothingLost == ~lost
=================================================================================
