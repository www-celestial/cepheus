# Theory

The mathematics behind each part of Cepheus, and the research it builds on. References are at the end, by number.

## 1. The journal and recovery

**Model.** The journal is a sequence of frames F1, F2, ... appended to segment files. Each frame holds groups with
consecutive numbers. Let D be the durable prefix of the file (the bytes covered by a finished `fsync`). A crash (F1,
F2) replaces the file by D followed by some bytes R from the unsynced writes (any subset of their sectors, possibly
torn). Recovery reads frames from the start and stops at the first index j where the bytes do not form a valid frame.

**Invariant I1** (append discipline): a frame is written only after the previous frame's `fsync` returned, so at any
time at most one frame is partly unsynced, and every frame before it lies inside D.

**Invariant I2** (acknowledgement): a group is confirmed only after the `fsync` of its frame returned, so a confirmed
group lies in D.

**Theorem (G1-G3).** Under F1 and F2, recovery yields groups 1..k with k ≥ every confirmed group, each intact.
*Proof.* By I1 and I2, the frames of confirmed groups are in D; D is unchanged by the crash; each such frame checks
(header and body CRC), so the scan passes them. The scan stops at the first frame that does not check, which lies
past D's confirmed frames, and everything after it is cut; frames are in group order, so the result is a prefix. ∎

**Damage versus tearing.** At the first bad frame at offset p, recovery must decide whether bytes were torn (never
confirmed: cut) or durable bytes were damaged (F3: refuse). Two signs prove that the frame was written whole and so
was once durable-shaped: a frame header that checks after p (I1: a frame after p was written after the one at p was
forced), or a
trailer at offset t whose length field equals t − p − 28 and whose body CRC matches the bytes between. A torn write
leaves neither, except if it lost exactly the sector of the header and kept every later sector of the frame (possible
only on a device that reorders sector writes); then recovery refuses to open: a false alarm, never a loss. The
exhaustive test enumerates every crash state of small journals and finds no false alarm in practice, because the
header shares its sector with the start of the body.

**Detection power** (Koopman 2002 [36], Castagnoli et al. 1993 [35]). CRC-32C has Hamming distance 4 for messages up to
about 2³¹ bits and 6 up to 5,243 bits: every error of at most 3 bits in a frame (5 bits in a frame of up to 655 bytes)
is detected, every burst of at most 32 bits is detected, and other random errors escape with probability 2⁻³².

## 2. Group commit

With one writer and an `fsync` of duration f, a closed system of N clients each writing one group at a time reaches a
steady state where each frame holds the groups that arrived during the previous `fsync`. By Little's law
(L = λW [43]), with N clients in the system and a response time W, the throughput is λ = N / W. If every group waits
for at most the rest of the current `fsync` and its own, f/2 ≤ W − f ≤ f on average, so
λ ≈ N / (1.5 f) up to the writer's CPU limit C (groups a second the writer can resolve): λ ≈ min(N / (1.5 f), C).
On the test machine f ≈ 3 ms (about 340 fsync/s) and C ≈ 146,000 groups/s for 5-fact groups (measured): 8 clients
give at most ~1,800 groups/s, 256 clients ~57,000; the measured numbers are in [benchmarks](benchmarks.md).
The writer resolves the next frame while the syncer forces the previous one (two stages), and groups that arrive
during an `fsync` are merged into the waiting frame, so a frame holds everything that arrived meanwhile (DeWitt et
al. 1984 [44], Helland et al. 1987 [45]).

## 3. Indexes

A view is a base B (sorted columns) plus a delta Δ (persistent maps). With n facts, e things, p properties:

| order | layout | lookup |
|---|---|---|
| by thing | `eoff[0..e]`, rows `(p, w)` sorted | facts of a thing: O(1) to find, O(k) to read; one property: O(k) |
| by property | `poff[0..p]`, rows `(w, thing)` sorted | things with (p, w): O(log n_p) + O(answer) |
| by link target | `roff[0..e]`, rows `(p, thing)` | things that link to t: O(1) + O(k) |

Dense thing numbers turn two orders into arrays indexed by the number (compressed sparse rows), so a thing's facts
cost two array reads to locate: 0.35 µs at 10 M facts, measured. Hexastore [11] and RDF-3X [12] keep six orders of
the triples; Cepheus keeps three because a dense id makes "by thing" and "by target" direct, and "by property then
value" serves "all things with this property" too. Memory: 22 bytes a fact plus 6 a link, plus the dictionary.

The delta is a set of persistent maps (Driscoll et al. [30], Okasaki [31]): each change copies one path, O(log d), and
an old version stays valid for free. That is what makes views and forks free. It costs about 170 bytes a change, so
it is bounded: when it passes max(200,000, n/16) changes, the writer merges it into a new base (compaction, O(n));
the LSM tree (O'Neil et al. [1]) generalises this to levels, so that a merge rewrites only a small level (planned:
design, section 15).

## 4. Generic Join

A question is a conjunctive query Q over variables x1..xm and atoms R_j (each pattern is a relation of two columns,
the thing and the value, restricted to one property and to its constants).

**AGM bound** (Atserias, Grohe, Marx [14]). For any fractional edge cover u of the variables by the atoms
(Σ_{j ∋ x} u_j ≥ 1 for every variable x), |Q| ≤ Π_j |R_j|^{u_j}. For the triangle R(a,b), S(b,c), T(c,a) with N facts
each, u = (½, ½, ½) gives |Q| ≤ N^{3/2}, and some instances reach it. Any plan of joins two at a time can build Θ(N²)
intermediate rows on some instance (Ngo et al. [15]).

**Algorithm** (Ngo, Ré, Rudra [17]; Veldhuizen [16] for the iterator form). Fix an order of the variables. To bind
x_i given x_1..x_{i−1}: among the atoms containing x_i, take the one with the fewest candidates for x_i under the
current bindings (exact counts read from the indexes), enumerate them, and keep a candidate c only if every other
atom on x_i accepts it (one index lookup each). Recurse. With lookups in O(log n), the running time is
O(m · |atoms| · AGM(Q) · log n) (the argument of [17], theorem 4.2: the candidates at each level are bounded by the
intersection's smallest member, and the sum over levels telescopes to the bound).

**Correctness (G11).** *Soundness:* a full binding passed every atom at the level of its last variable, with all
other variables of the atom bound, so every atom is a fact. *Completeness:* for an answer a, at each level a_i
satisfies the source atom (so it is enumerated) and every other atom (so it is kept). *No duplicates:* the candidates
of one level are distinct (each index yields a set: the base holds each fact once, and the delta adds only facts that
are not in the base); distinct prefixes give distinct bindings.

**Order.** For up to 7 variables Cepheus tries every order (with pruning) and keeps the one with the smallest
estimated sum of partial bindings, each step multiplying by its estimated candidates per binding; beyond, greedily.
Freitag et al. [19], Mhedhbi and Salihoglu [20] and Wang et al. [21] show the order and the mix with ordinary joins
matter most in practice; the measured cost of each question is in [benchmarks](benchmarks.md).

## 5. Serializability and isolation

Define a history H as the sequence of confirmed groups with their reads (`Expect`) and writes. The writer executes
groups one at a time, each on the state left by the previous, so H is serial (Papadimitriou [24]); hence it is
conflict-serializable, and with numbers assigned after submission, strictly serializable (linearizable as a single
object, Herlihy and Wing [26]). In Adya's terms [28], no cycle G0, G1 or G2 can form among groups. A client
transaction that reads a view and then writes is a group with preconditions: if it states every fact it read as an
`Expect`, the writer validates them on the latest state (backward validation, Kung and Robinson [25]), so the client
transaction is serializable; otherwise it can suffer a lost update, as under snapshot isolation (Berenson et al. [27]).
PostgreSQL's default is Read Committed; its SERIALIZABLE is SSI (Cahill et al. [29], Ports and Grittner [29b]);
Oracle's "serializable" is snapshot isolation, which admits write skew (Fekete et al. [28b]).

## 6. Forks

A fork is a pair (view, delta') where delta' starts equal to the view's delta. Writes produce new persistent versions
(path copying), so the original view is unchanged by construction; a fork is O(1) to make and costs O(log d) per change.
Datomic's `with` [32] is the same idea on a database value; HyPer [33] forks the process for OLAP snapshots; Rodeh [34]
does copy-on-write for B-trees.

## 7. What comes next, and why

- **Larger than memory** (design, section 15): immutable sorted runs (LSM [1], with per-level Bloom filters as in
  Monkey [5]) read through Cepheus' own cache of verified blocks (LeanStore [7], Umbra [8], vmcache [9]); not mmap for
  cold data (Crotty et al. [10]).
- **Compression of runs**: delta and varint, then PFOR (Zukowski et al. [13], Lemire and Boytsov [13b]); an order-
  preserving dictionary rebuilt at each merge (Binnig et al. [13c]) for ranges over texts.
- **Rules**: semi-naive evaluation at write time (Bancilhon and Ramakrishnan [22]) and Backward/Forward for
  retractions (Motik et al. [23]); subscriptions by the delta rules of DBSP (Budiu et al. [23b]).
- **Replication**: Raft [37] with protocol-aware recovery [38]; the journal is the only replicated thing (Aurora [39]).
- **Many machines**: databases spread over machines, then storage on object stores (Socrates [40]), then a database
  partitioned by thing with a deterministic order of cross-partition groups (Calvin [41]) and distributed Generic Join
  (BiGJoin [42]).

## References

1. P. O'Neil, E. Cheng, D. Gawlick, E. O'Neil. The Log-Structured Merge-Tree (LSM-Tree). Acta Informatica 33(4), 1996.
2. G. S. Brodal, R. Fagerberg. Lower Bounds for External Memory Dictionaries. SODA 2003.
3. M. A. Bender, M. Farach-Colton, W. Jannen, R. Johnson, B. C. Kuszmaul, D. E. Porter, J. Yuan, Y. Zhan. An
   Introduction to Bε-trees and Write-Optimization. ;login: 40(5), 2015.
4. L. Lu, T. S. Pillai, A. C. Arpaci-Dusseau, R. H. Arpaci-Dusseau. WiscKey: Separating Keys from Values in
   SSD-Conscious Storage. FAST 2016.
5. N. Dayan, M. Athanassoulis, S. Idreos. Monkey: Optimal Navigable Key-Value Store. SIGMOD 2017.
6. S. Harizopoulos, D. J. Abadi, S. Madden, M. Stonebraker. OLTP Through the Looking Glass, and What We Found There.
   SIGMOD 2008.
7. V. Leis, M. Haubenschild, A. Kemper, T. Neumann. LeanStore: In-Memory Data Management beyond Main Memory. ICDE 2018.
8. T. Neumann, M. J. Freitag. Umbra: A Disk-Based System with In-Memory Performance. CIDR 2020.
9. V. Leis, A. Alhomssi, T. Ziegler, Y. Loeck, C. Dietrich. Virtual-Memory Assisted Buffer Management. SIGMOD 2023.
10. A. Crotty, V. Leis, A. Pavlo. Are You Sure You Want to Use MMAP in Your Database Management System? CIDR 2022.
11. C. Weiss, P. Karras, A. Bernstein. Hexastore: Sextuple Indexing for Semantic Web Data Management. PVLDB 1(1), 2008.
12. T. Neumann, G. Weikum. RDF-3X: a RISC-style Engine for RDF. PVLDB 1(1), 2008.
13. M. Zukowski, S. Héman, N. Nes, P. Boncz. Super-Scalar RAM-CPU Cache Compression. ICDE 2006.
13b. D. Lemire, L. Boytsov. Decoding Billions of Integers per Second through Vectorization. SPE 45(1), 2015.
13c. C. Binnig, S. Hildenbrand, F. Färber. Dictionary-based Order-preserving String Compression for Main Memory Column
   Stores. SIGMOD 2009.
14. A. Atserias, M. Grohe, D. Marx. Size Bounds and Query Plans for Relational Joins. FOCS 2008.
15. H. Q. Ngo, E. Porat, C. Ré, A. Rudra. Worst-case Optimal Join Algorithms. PODS 2012.
16. T. L. Veldhuizen. Leapfrog Triejoin: A Simple, Worst-Case Optimal Join Algorithm. ICDT 2014.
17. H. Q. Ngo, C. Ré, A. Rudra. Skew Strikes Back: New Developments in the Theory of Join Algorithms. SIGMOD Record
    42(4), 2013.
18. C. R. Aberger, S. Tu, K. Olukotun, C. Ré. EmptyHeaded: A Relational Engine for Graph Processing. SIGMOD 2016.
19. M. J. Freitag, M. Bandle, T. Schmidt, A. Kemper, T. Neumann. Adopting Worst-Case Optimal Joins in Relational
    Database Systems. PVLDB 13(11), 2020.
20. A. Mhedhbi, S. Salihoglu. Optimizing Subgraph Queries by Combining Binary and Worst-Case Optimal Joins. PVLDB
    12(11), 2019.
21. Y. R. Wang, M. Willsey, D. Suciu. Free Join: Unifying Worst-Case Optimal and Traditional Joins. SIGMOD 2023.
22. F. Bancilhon, R. Ramakrishnan. An Amateur's Introduction to Recursive Query Processing Strategies. SIGMOD 1986.
23. B. Motik, Y. Nenov, R. Piro, I. Horrocks. Incremental Update of Datalog Materialisation: the Backward/Forward
    Algorithm. AAAI 2015.
23b. M. Budiu, T. Chajed, F. McSherry, L. Ryzhyk, V. Tannen. DBSP: Automatic Incremental View Maintenance for Rich
    Query Languages. PVLDB 16(7), 2023.
24. C. H. Papadimitriou. The Serializability of Concurrent Database Updates. JACM 26(4), 1979.
25. H. T. Kung, J. T. Robinson. On Optimistic Methods for Concurrency Control. TODS 6(2), 1981.
26. M. Herlihy, J. Wing. Linearizability: A Correctness Condition for Concurrent Objects. TOPLAS 12(3), 1990.
27. H. Berenson, P. Bernstein, J. Gray, J. Melton, E. O'Neil, P. O'Neil. A Critique of ANSI SQL Isolation Levels.
    SIGMOD 1995.
28. A. Adya. Weak Consistency: A Generalized Theory and Optimistic Implementations for Distributed Transactions. PhD
    thesis, MIT, 1999.
28b. A. Fekete, D. Liarokapis, E. O'Neil, P. O'Neil, D. Shasha. Making Snapshot Isolation Serializable. TODS 30(2), 2005.
29. M. J. Cahill, U. Röhm, A. Fekete. Serializable Isolation for Snapshot Databases. SIGMOD 2008.
29b. D. R. K. Ports, K. Grittner. Serializable Snapshot Isolation in PostgreSQL. PVLDB 5(12), 2012.
30. J. R. Driscoll, N. Sarnak, D. D. Sleator, R. E. Tarjan. Making Data Structures Persistent. JCSS 38(1), 1989.
31. C. Okasaki. Purely Functional Data Structures. Cambridge University Press, 1998.
32. R. Hickey. Datomic (2012), the `with` function of its database values.
33. A. Kemper, T. Neumann. HyPer: A Hybrid OLTP&OLAP Main Memory Database System Based on Virtual Memory Snapshots.
    ICDE 2011.
34. O. Rodeh. B-trees, Shadowing, and Clones. ACM TOS 3(4), 2008.
35. G. Castagnoli, S. Bräuer, M. Herrmann. Optimization of Cyclic Redundancy-Check Codes with 24 and 32 Parity Bits.
    IEEE Trans. Communications 41(6), 1993.
36. P. Koopman. 32-Bit Cyclic Redundancy Codes for Internet Applications. DSN 2002.
37. D. Ongaro, J. Ousterhout. In Search of an Understandable Consensus Algorithm. USENIX ATC 2014.
38. R. Alagappan, A. Ganesan, E. Lee, A. Albarghouthi, V. Chidambaram, A. C. Arpaci-Dusseau, R. H. Arpaci-Dusseau.
    Protocol-Aware Recovery for Consensus-Based Storage. FAST 2018.
39. A. Verbitski et al. Amazon Aurora: Design Considerations for High Throughput Cloud-Native Relational Databases.
    SIGMOD 2017.
40. P. Antonopoulos et al. Socrates: The New SQL Server in the Cloud. SIGMOD 2019.
41. A. Thomson, T. Diamond, S.-C. Weng, K. Ren, P. Shao, D. J. Abadi. Calvin: Fast Distributed Transactions for
    Partitioned Database Systems. SIGMOD 2012.
42. K. Ammar, F. McSherry, S. Salihoglu, M. Joglekar. Distributed Evaluation of Subgraph Queries Using Worst-case
    Optimal Low-Memory Dataflows. PVLDB 11(6), 2018.
43. J. D. C. Little. A Proof for the Queuing Formula L = λW. Operations Research 9(3), 1961.
44. D. J. DeWitt, R. H. Katz, F. Olken, L. D. Shapiro, M. R. Stonebraker, D. Wood. Implementation Techniques for Main
    Memory Database Systems. SIGMOD 1984.
45. P. Helland, H. Sammer, J. Lyon, R. Carr, P. Garrett, A. Reuter. Group Commit Timers and High Volume Transaction
    Systems. HPTS 1987.
46. T. S. Pillai et al. All File Systems Are Not Created Equal: On the Complexity of Crafting Crash-Consistent
    Applications. OSDI 2014.
47. A. Rebello, Y. Patel, R. Alagappan, A. C. Arpaci-Dusseau, R. H. Arpaci-Dusseau. Can Applications Recover from fsync
    Failures? USENIX ATC 2020.
48. J. Zhou et al. FoundationDB: A Distributed Unbundled Transactional Key Value Store. SIGMOD 2021.
49. J. Bornholt et al. Using Lightweight Formal Methods to Validate a Key-Value Storage Node in Amazon S3. SOSP 2021.
50. K. Claessen, J. Hughes. QuickCheck: A Lightweight Tool for Random Testing of Haskell Programs. ICFP 2000.
51. M. Raasveldt, P. Holanda, T. Gubner, H. Mühleisen. Fair Benchmarking Considered Difficult: Common Pitfalls in
    Database Performance Testing. DBTest 2018.
52. L. Lamport. Specifying Systems. Addison-Wesley, 2002.
