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
| by thing | `eoff[0..e]`, rows `(p, w)` sorted | facts of a thing: O(1) to find, O(k) to read; one property or one fact: O(log k) |
| by property | `poff[0..p]`, rows `(w, thing)` sorted | things with (p, w), or linking to w by p: O(log n_p) + O(answer); a range of values: the same |

Dense thing numbers turn "by thing" into an array indexed by the number (compressed sparse rows), so a thing's facts
cost two array reads to locate: 0.35 µs at 10 M facts, measured. Hexastore [11] and RDF-3X [12] keep six orders of
the triples; Cepheus keeps two because a dense id makes "by thing" direct, and "by property then value" serves "all
things with this property", "the things that link to t by p" (the rows of value t) and ranges of values. Memory: 22
bytes a fact, plus the dictionary.

The delta is a set of persistent maps (Driscoll et al. [30], Okasaki [31]): each change copies one path, O(log d), and
an old version stays valid for free. That is what makes views and forks free. It is keyed like the base (by thing
then (property, value); by property then value then thing), so every lookup is a binary search in the base plus a
search in a map, never a walk of a list, and it keeps the net count of facts beside each map, so that every count the
planner reads is exact, base and delta together. It costs about 170 bytes a change, so
it is bounded: when it passes max(200,000, n/16) changes, a merge starts **in another domain**: it builds a new
base from the working view of that moment (O(n)), then replays the groups written meanwhile (the writer logs them),
until it is fewer than 256 groups behind; the writer then waits for the syncer to be idle (at most one fsync),
replays the rest and switches its views to the new base. Writes never wait for the O(n) part. This is the first
two levels of an LSM tree (O'Neil et al. [1]): the delta is level 0, the base level 1; the on-disk levels, each
merged at its own pace so that a merge rewrites only a small level, come with the segments on disk (design,
section 15).

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
atom on x_i accepts it (one index lookup each). Recurse. A variable with a range, on the value side of an atom whose
thing is free, is enumerated from that property's sorted index over the range only. With lookups in O(log n), the running time is
O(m · |atoms| · AGM(Q) · log n) (the argument of [17], theorem 4.2: the candidates at each level are bounded by the
intersection's smallest member, and the sum over levels telescopes to the bound). The bound needs two things of the
engine: the counts must be exact (an estimate below the truth makes a large set look small) and an atom that is not
the source must cost a lookup, not a walk of its own candidates. A version of milestone 2 broke the second: it
materialized and sorted the candidates of every bound atom to intersect them, so at each binding it paid for the
largest set (a status shared by 450,000 invoices, sorted once per client of a city: the 10 M benchmark never finished
its third question). Sorted intersection (Leapfrog Triejoin [16]) keeps the bound only with iterators that seek
inside the indexes; with a by-thing index, a membership test costs O(log k) and is the simpler way.

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

## 7. Pages and the cache

The base is read in pages of 16 KiB through one cache for the process (`Pages`; design, section 15, choice 8: own
cache rather than mmap [10], as LeanStore [7], Umbra [8] and vmcache [9] do).

**A read.** A base keeps a table `hot` with one slot a page: the page's bytes, or a constant "absent". Reading 8 bytes
at offset o is `hot.(o lsr 14)`, one comparison, then the read in the page: no lock, no hash table, from any domain.
A page not in `hot` goes the slow way: if it is in memory, one read is counted for the policy and the page goes back
into `hot`; if not, the cache's lock is taken, room is made, the page is read from its file and checked against its
CRC-32C before anyone can see it (G7). The slow way is a call, and OCaml saves every live value on the stack around a
call even when it is not taken; so the lookups that call nothing else (binary searches, counts, membership) use
readers that raise an exception on a page not hot, and run again from their start once the page is in (they change
nothing before they return); the loops that call a function per row, which save their values around that call
anyway, use readers that call. Evicted pages are never reused in place: a reader that raced with the eviction still
holds the old bytes, which are right, and the GC frees them; a full collection after each quarter of the cache
evicted keeps the pages in memory under 1.25 times the cache.

**Cost when everything is in memory**, 10 M facts, release build, 11 runs x 2 rounds alternated, against milestone
2's mapped base (c67e52d): Q1 0.37 to 0.39 µs (+5 %), Q2 1.73 to 1.66 µs (-4 %), Q3 3.67 to 3.98 ms (+8 %), Q4 199 to
226 ms (+13 %), Q5 0.93-0.95 to 0.97-1.02 s (+3 to +8 %). The rest is the price of the table: one more dependent load
per read and an exception handler per lookup. 64 KiB pages (a table four times smaller) gave the same times; garbage
collection is not the cause (18 major collections against 2 over a run, but a space overhead of 400 changes nothing).

**The policy.** S3-FIFO [56]: a page enters a small FIFO (10 % of the room); when it leaves it, it goes to the main FIFO
if it was read again meanwhile, else out (its key goes to a ghost FIFO, and a page found there on a miss goes straight
to the main FIFO); a page at the end of the main FIFO is kept if read since the policy last looked at it (its 2-bit
counter lowered), else out. Its counters need no list to reorder on a hit: here, a read of a hot page tells the
policy nothing, and the policy takes a page out of `hot` when it looks at it, so the next read counts. That is what a
cache read by several domains with no lock needs; LRU, 2Q [54] and ARC [55] move a page in a list on every hit, which
needs a lock or buffers of hits (as Caffeine does for W-TinyLFU [57]).

**Checked on recorded traces**, against Belady's optimum [53] (evict the page read again the farthest in the future;
with admission, a page read again later than every resident one is not kept: no online policy does better). A trace
is the sequence of pages read by a day of questions on the 10 M database, one entry a page and lookup
(`bench.exe trace`, then `bench.exe cachesim`); hit ratios, cache sizes as a share of the 8,612 pages read:

| a day: 30,000 point questions on clients drawn by a Zipf law (0.99), a Q4, a Q5; 91.5 M reads | LRU | CLOCK | 2Q | ARC | SIEVE | S3-FIFO | W-TinyLFU | OPT |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 2 % (172 pages) | 94.02 | 94.02 | 93.81 | 94.01 | 93.94 | 94.02 | 85.43 | 95.21 |
| 5 % | 94.43 | 94.45 | 94.65 | 94.46 | 94.48 | 94.47 | 92.85 | 96.06 |
| 10 % | 94.98 | 95.00 | 95.34 | 95.06 | 95.08 | 95.17 | 94.72 | 96.92 |
| 25 % | 96.31 | 96.32 | 96.68 | 96.39 | 96.57 | 96.53 | 96.89 | 98.43 |

| point questions only (Zipf), 19.5 M reads, 7,873 pages | LRU | CLOCK | 2Q | ARC | SIEVE | S3-FIFO | W-TinyLFU | OPT |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 2 % | 97.77 | 97.76 | 97.71 | 97.76 | 97.69 | 97.77 | 91.64 | 98.01 |
| 5 % | 97.85 | 97.84 | 97.96 | 97.85 | 97.82 | 97.85 | 95.82 | 98.22 |
| 10 % | 97.91 | 97.91 | 98.13 | 97.91 | 97.90 | 97.93 | 98.15 | 98.43 |
| 25 % | 98.04 | 98.04 | 98.44 | 98.04 | 98.04 | 98.23 | 98.48 | 99.03 |

| the same with a Q4 scan in the middle, 31.7 M reads, 8,195 pages | LRU | CLOCK | 2Q | ARC | SIEVE | S3-FIFO | W-TinyLFU | OPT |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 2 % | 98.61 | 98.61 | 98.57 | 98.61 | 98.57 | 98.62 | 94.85 | 98.76 |
| 5 % | 98.66 | 98.66 | 98.74 | 98.66 | 98.64 | 98.66 | 98.20 | 98.89 |
| 10 % | 98.70 | 98.70 | 98.84 | 98.70 | 98.70 | 98.71 | 98.85 | 99.03 |
| 25 % | 98.78 | 98.78 | 99.04 | 98.78 | 98.78 | 98.90 | 99.06 | 99.42 |

(The uniform law gives the same table as the Zipf law for the day, to 0.02 points: Q4 and Q5 make 90 % of its reads.)

What it says. The pages a lookup reads first (the top of a binary search, the offset tables) are read so often that
2 % of the pages already serve 94 to 98 % of the reads, and the policies differ by less than one point of hit ratio
but W-TinyLFU at small sizes (its window of 1 % is one or two pages there). In misses the gaps are larger: at 25 %,
LRU misses 1.96 % of the point reads, S3-FIFO 1.77 %, 2Q 1.56 %, W-TinyLFU 1.52 %, Belady 0.97 %: the best online
policies miss 12 to 14 % less than S3-FIFO, and the optimum about half as much as any of them. S3-FIFO is as good as
LRU and CLOCK everywhere and better at 25 %, with no lock on a hit; 2Q and W-TinyLFU reorder a list on every hit. The
gap that matters more is the layout (below). Picked: S3-FIFO; 2Q's gain would be worth a lock only if hits stayed
under one domain, which parallel questions break.

**Larger than memory**, 10 M facts (snapshot 245 MB), cache 32 MB, the process capped at 128 MB (benchmarks): open
67 ms (64 MB resident), Q1 41 µs, Q2 1.8 µs, Q3 89 ms, Q4 385 ms on one core and 247 ms on three (the same answers;
PostgreSQL with 32 MB of buffers under the same cap: 176 µs, 5.5 µs, 446 ms through its socket, 697 and 658 ms), peak
79 to 105 MB. Q5 takes 102 s (PostgreSQL 1.05 s): a client's follow links lie among its invoices' rows (the base
orders rows by thing), so the triangle question reads random pages of all 120 MB of by-thing rows for a few bytes
each. A third order of the rows, by property then thing (as Hexastore [11] and RDF-3X [12] keep), would make one
property of many things local; it costs 10 bytes a fact more. To decide on measurements of real workloads.

**What a merge still costs.** A merge builds the new base in memory (arrays for its sort, then its pages) beside the
old one, and the pages of both live on the OCaml heap, where the collector lets free space reach 120 % of the live
data: write runs with merges peaked at 1.8 to 3.3 GB at 10 M facts, against 1.7 to 2.5 GB with milestone 1's mapped
base (six runs of 10 s at 256 clients each). The base a merge replaces leaves the cache at once (`Pages.drop`); the
remaining cure is a merge written straight to a file, page by page, as a sorted run of an LSM tree [1]: then a merge
needs no more memory than the cache.

## 8. What comes next, and why

- **Larger than memory, the rest** (design, section 15): merges written straight to a file as sorted runs (LSM [1],
  with per-level Bloom filters as in Monkey [5]), so that a merge needs no more memory than the cache; a third order
  of the rows (property, thing) for workloads that read one property of many things under memory pressure.
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
53. L. A. Belady. A Study of Replacement Algorithms for a Virtual-Storage Computer. IBM Systems Journal 5(2), 1966.
54. T. Johnson, D. Shasha. 2Q: A Low Overhead High Performance Buffer Management Replacement Algorithm. VLDB 1994.
55. N. Megiddo, D. S. Modha. ARC: A Self-Tuning, Low Overhead Replacement Cache. FAST 2003.
56. J. Yang, Y. Zhang, Z. Qiu, Y. Yue, R. Vinayak. FIFO Queues are All You Need for Cache Eviction. SOSP 2023.
57. G. Einziger, R. Friedman, B. Manes. TinyLFU: A Highly Efficient Cache Admission Policy. ACM Transactions on
    Storage 13(4), 2017.
58. Y. Zhang, J. Yang, Y. Yue, Y. Vigfusson, K. V. Rashmi. SIEVE is Simpler than LRU: an Efficient Turn-Key Eviction
    Algorithm for Web Caches. NSDI 2024.
59. F. J. Corbató. A Paging Experiment with the Multics System. MIT Project MAC Report MAC-M-384, 1968.
60. G. Castagnoli, S. Bräuer, M. Herrmann. Optimization of Cyclic Redundancy-Check Codes with 24 and 32 Parity Bits.
    IEEE Transactions on Communications 41(6), 1993.
