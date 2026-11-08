# Theory

The mathematics behind each part of Cepheus, and the research it builds on. A citation in brackets, [O'Neil 1996], is
an entry of [references](references.md), with its link and what Cepheus took from it. The plain-language account of
the same parts is [architecture](architecture.md).

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

**Detection power** ([Koopman 2002], [Castagnoli 1993]). CRC-32C has Hamming distance 4 for messages up to
about 2³¹ bits and 6 up to 5,243 bits: every error of at most 3 bits in a frame (5 bits in a frame of up to 655 bytes)
is detected, every burst of at most 32 bits is detected, and other random errors escape with probability 2⁻³².

## 2. Group commit

With one writer and an `fsync` of duration f, a closed system of N clients each writing one group at a time reaches a
steady state where each frame holds the groups that arrived during the previous `fsync`. By Little's law
(L = λW [Little 1961]), with N clients in the system and a response time W, the throughput is λ = N / W. If every group waits
for at most the rest of the current `fsync` and its own, f/2 ≤ W − f ≤ f on average, so
λ ≈ N / (1.5 f) up to the writer's CPU limit C (groups a second the writer can resolve): λ ≈ min(N / (1.5 f), C).
On the test machine f ≈ 3 ms (about 340 fsync/s) and C ≈ 146,000 groups/s for 5-fact groups (measured): 8 clients
give at most ~1,800 groups/s, 256 clients ~57,000; the measured numbers are in [benchmarks](benchmarks.md).
The writer resolves the next frame while the syncer forces the previous one (two stages), and groups that arrive
during an `fsync` are merged into the waiting frame, so a frame holds everything that arrived meanwhile ([DeWitt 1984],
[Helland 1987]).

## 3. Indexes

A view is a base B (sorted columns) plus a delta Δ (persistent maps). With n facts, e things, p properties:

| order | layout | lookup |
|---|---|---|
| by thing | `eoff[0..e]`, rows `(p, w)` sorted | facts of a thing: O(1) to find, O(k) to read; one property or one fact: O(log k) |
| by property | `poff[0..p]`, rows `(w, thing)` sorted | things with (p, w), or linking to w by p: O(log n_p) + O(answer); a range of values: the same |

Dense thing numbers turn "by thing" into an array indexed by the number (compressed sparse rows), so a thing's facts
cost two array reads to locate: 0.39 µs at 10 M facts ([benchmarks](benchmarks.md)). Hexastore [Weiss 2008] and RDF-3X [Neumann 2008] keep six orders of
the triples; Cepheus keeps two because a dense id makes "by thing" direct, and "by property then value" serves "all
things with this property", "the things that link to t by p" (the rows of value t) and ranges of values. Size: 22 bytes a fact of rows (2 + 8 by thing, 8 + 4 by property), 8 bytes a thing and a property of offsets, and
the dictionary: 245,824,096 bytes at 10 M facts, 24.6 bytes a fact.
bytes a fact, plus the dictionary.

The delta is a set of persistent maps (Driscoll et al. [Driscoll 1989], Okasaki [Okasaki 1998]): each change copies one path, O(log d), and
an old version stays valid for free. That is what makes views and forks free. It is keyed like the base (by thing
then (property, value); by property then value then thing), so every lookup is a binary search in the base plus a
search in a map, never a walk of a list, and it keeps the net count of facts beside each map, so that every count the
planner reads is exact, base and delta together. It costs about 170 bytes a change, so
it is bounded: when it passes max(200,000, n/16) changes, a merge starts **in another domain**: it streams the base and
the delta, merged in order, into a new snapshot file (O(n + d), section 8), then replays the groups written meanwhile
(the writer logs them), until it is fewer than 256 groups behind; the writer then waits for the syncer to be idle (at
most one fsync), replays the rest and switches its views to the new base. Writes never wait for the O(n) part. This is
a two-component LSM-tree [O'Neil 1996]: the delta is the component in memory (C0), the base the one on disk (C1); more
levels on disk are not built (section 9).

## 4. Generic Join

A question is a conjunctive query Q over variables x1..xm and atoms R_j (each pattern is a relation of two columns,
the thing and the value, restricted to one property and to its constants).

**AGM bound** (Atserias, Grohe, Marx [Atserias 2008]). For any fractional edge cover u of the variables by the atoms
(Σ_{j ∋ x} u_j ≥ 1 for every variable x), |Q| ≤ Π_j |R_j|^{u_j}. For the triangle R(a,b), S(b,c), T(c,a) with N facts
each, u = (½, ½, ½) gives |Q| ≤ N^{3/2}, and some instances reach it. Any plan of joins two at a time can build Θ(N²)
intermediate rows on some instance (Ngo et al. [Ngo 2012]).

**Algorithm** (Ngo, Ré, Rudra [Ngo 2013]; Veldhuizen [Veldhuizen 2014] for the iterator form). Fix an order of the variables. To bind
x_i given x_1..x_{i−1}: among the atoms containing x_i, take the one with the fewest candidates for x_i under the
current bindings (exact counts read from the indexes), enumerate them, and keep a candidate c only if every other
atom on x_i accepts it (one index lookup each). Recurse. A variable with a range, on the value side of an atom whose
thing is free, is enumerated from that property's sorted index over the range only. With lookups in O(log n), the running time is
O(m · |atoms| · AGM(Q) · log n) (the argument of [Ngo 2013], theorem 4.2: the candidates at each level are bounded by the
intersection's smallest member, and the sum over levels telescopes to the bound). The bound needs two things of the
engine: the counts must be exact (an estimate below the truth makes a large set look small) and an atom that is not
the source must cost a lookup, not a walk of its own candidates. A version of milestone 2 broke the second: it
materialized and sorted the candidates of every bound atom to intersect them, so at each binding it paid for the
largest set (a status shared by 450,000 invoices, sorted once per client of a city: the 10 M benchmark never finished
its third question). Sorted intersection (Leapfrog Triejoin [Veldhuizen 2014]) keeps the bound only with iterators that seek
inside the indexes; with a by-thing index, a membership test costs O(log k) and is the simpler way.

**Correctness (G11).** *Soundness:* a full binding passed every atom at the level of its last variable, with all
other variables of the atom bound, so every atom is a fact. *Completeness:* for an answer a, at each level a_i
satisfies the source atom (so it is enumerated) and every other atom (so it is kept). *No duplicates:* the candidates
of one level are distinct (each index yields a set: the base holds each fact once, and the delta adds only facts that
are not in the base); distinct prefixes give distinct bindings.

**Order.** For up to 7 variables Cepheus tries every order (with pruning) and keeps the one with the smallest
estimated sum of partial bindings, each step multiplying by its estimated candidates per binding; beyond, greedily.
Freitag et al. [Freitag 2020], Mhedhbi and Salihoglu [Mhedhbi 2019] and Wang et al. [Wang 2023] show the order and the mix with ordinary joins
matter most in practice; the measured cost of each question is in [benchmarks](benchmarks.md).

## 5. Serializability and isolation

Define a history H as the sequence of confirmed groups with their reads (`Expect`) and writes. The writer executes
groups one at a time, each on the state left by the previous, so H is serial (Papadimitriou [Papadimitriou 1979]); hence it is
conflict-serializable, and with numbers assigned after submission, strictly serializable (linearizable as a single
object, Herlihy and Wing [Herlihy 1990]). In Adya's terms [Adya 1999], no cycle G0, G1 or G2 can form among groups. A client
transaction that reads a view and then writes is a group with preconditions: if it states every fact it read as an
`Expect`, the writer validates them on the latest state (backward validation, Kung and Robinson [Kung 1981]), so the client
transaction is serializable. Two reads are not validated. A fact read and not stated: two read-then-writes of the
same value both succeed, a lost update, which snapshot isolation would refuse (first committer wins, [Berenson 1995]).
A predicate read, the set of facts that match a pattern: an `Expect` names one fact, so a fact added to the set
meanwhile (a phantom) is not seen, unless every writer of the set expects and changes one fact that stands for it (a
version number: materializing the conflict, [Fekete 2005]). Within those bounds, a read-then-write is serializable;
beyond them it is weaker than snapshot isolation.
PostgreSQL's default is Read Committed; its SERIALIZABLE is SSI (Cahill et al. [Cahill 2008], Ports and Grittner [Ports 2012]);
Oracle's "serializable" is snapshot isolation, which admits write skew (Fekete et al. [Fekete 2005]).

## 6. Forks

A fork is a pair (view, delta') where delta' starts equal to the view's delta. Writes produce new persistent versions
(path copying), so the original view is unchanged by construction; a fork is O(1) to make and costs O(log d) per change.
Datomic's `with` ([comparison](comparison.md#datomic)) is the same idea on a database value; HyPer [Kemper 2011] forks the process for OLAP snapshots; Rodeh [Rodeh 2008]
does copy-on-write for B-trees.

## 7. Pages and the cache

The base is read in pages of 16 KiB through one cache for the process (`Pages`: Cepheus' own
cache rather than mmap [Crotty 2022], as LeanStore [Leis 2018], Umbra [Neumann 2020] and vmcache [Leis 2023] do).

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

**The policy.** S3-FIFO [Yang 2023]: a page enters a small FIFO (10 % of the room); when it leaves it, it goes to the main FIFO
if it was read again meanwhile, else out (its key goes to a ghost FIFO, and a page found there on a miss goes straight
to the main FIFO); a page at the end of the main FIFO is kept if read since the policy last looked at it (its 2-bit
counter lowered), else out. Its counters need no list to reorder on a hit: here, a read of a hot page tells the
policy nothing, and the policy takes a page out of `hot` when it looks at it, so the next read counts. That is what a
cache read by several domains with no lock needs; LRU, 2Q [Johnson 1994] and ARC [Megiddo 2003] move a page in a list on every hit, which
needs a lock or buffers of hits (as Caffeine does for W-TinyLFU [Einziger 2017]).

**Checked on recorded traces**, against Belady's optimum [Belady 1966] (evict the page read again the farthest in the future;
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
each. A third order of the rows, by property then thing (as Hexastore [Weiss 2008] and RDF-3X [Neumann 2008] keep), would make one
property of many things local; it costs 10 bytes a fact more. To decide on measurements of real workloads.

**What a merge cost, until it was written to a file.** A merge built the new base in memory (arrays for its sort,
then its pages) beside the old one, and the pages of both lived on the OCaml heap: write runs with merges peaked at
1.8 to 3.3 GB at 10 M facts. Section 8 is the cure.

## 8. Merges written to a file

A merge folds the delta (level 0: persistent maps in memory) into the base (level 1: a snapshot file). It is the
rolling merge of a two-component LSM-tree [O'Neil 1996], C0 into C1. Both inputs are already sorted in the order of every
section of the base (by thing: thing, property, value; by property: property, value, thing; the texts by id and by
their bytes), so each section of the new base is the merge of two sorted runs, made in one pass with one cursor in
each (`Store.iter_facts`, `Store.iter_prop_sorted`, `Store.iter_texts_sorted`): O(n + d) comparisons for n facts in
the base and d changes in the delta, and no sort.

**Streaming.** The new base is written in three passes, in the order of the file: by thing (offsets, properties,
values), by property (offsets, values, things, distinct counts), the dictionary (offsets, bytes, sorted ids). In a
pass, the streams of its sections advance side by side, each in its own region of the file. A 16 KiB page is complete
once all its bytes are written (two sections may share one) and goes out at once: its CRC-32C, a `pwrite` at its
place, and the cache, which admits it cold (in S3-FIFO's small queue, not hot: a merge's output is a scan, kept only
if it is read before the queue reaches it). Then the checksum table, the header, an fsync, and the install (G12).

**The memory bound.** Let C be the cache's capacity and P the pages of the new base. During a merge the process holds,
beyond what it held before (the delta, the log of the groups written meanwhile):
- the pages of the old base it reads and of the new base it writes, all counted by the cache: at most C, by
  construction (a page enters only through `Pages.fill` or `Pages.admit`, which make room first);
- the pages being filled: one under each stream's head and the ones two sections share, at most 5 measured (the
  bound is 2 per stream of a pass, 8);
- the tables of the new base: 4 bytes of CRC, two 8-byte slots (frame and hot) and one count a page, 21 bytes for 16
  KiB, 0.13 % of the base.

So M_merge ≤ C + 8 × 16 KiB + 21 P, independent of the base's size but for the 0.13 %. The merge in memory it replaces
held 7 words a fact for its sort (560 MB at 10 M facts) and the whole new base outside the cache. Measured
(benchmarks): with the whole base in a 1 GiB cache, a merge of the 10 M base and a delta of 400,000 facts takes the
process from 412 MB to a peak of 651 to 656 MB (the new base's 245 MB of pages), against 1,222 to 1,450 MB for the
merge in memory; with a 32 MB cache, from 63 MB to a peak of 99 MB, under a 128 MB cap that kills the merge in
memory.

**What it costs in writes.** A merge starts when the delta holds d > max(c, n/16) changes (c = 200,000), and writes
the whole base: n + d facts for d changes, so each change costs n/d + 1 ≤ 17 facts of writes once n/16 > c (the size
ratio r = 16 of a two-component LSM-tree, whose amortized merge cost is r + 1 [O'Neil 1996]; a leveled tree of L levels of
ratio T pays O(T L), a tiered one O(L), with slower reads [Luo 2020]). At 10 M facts, a merge every 625,000 changes writes
the 245 MB of the base, about 400 bytes a change. Those writes compete with the journal's fsyncs, which every client
waits for. Forced once at the end, a merge's 100 to 245 MB of dirty pages made a journal fsync wait seconds (a load of
3 M facts: the journal's fsync p99.9 1.6 s, max 4.7 s; the load 32.6 s against 19.5 s with merges in memory). Forced
every 8 MiB as it is written (what RocksDB's `bytes_per_sync` does [Dong 2017]), the tail fell to p99.9 0.43 s, max 1.0 s,
and the load to 23.5 s. Each fsync costs a merge time, though (a merge of 10 M facts: 2.3 s forced once, 9 s forced
every 8 MiB), so a merge forces in steps only while the journal is writing, and once otherwise. A sustained load still
pays for the bytes: 10 M facts load in 135 to 153 s against 63 to 79 s with merges in memory (benchmarks); pacing the
merge's writes (a token bucket, as RocksDB's rate limiter) did not help on this disk. Writes at 256 clients with a
merge every 10 s or so show no difference (19,388 against 19,126 groups a second, medians of 12 runs).

**Crash safety.** See G12 in [guarantees](guarantees.md): the file is forced before its rename, it is named only
once its group is durable in the journal, the older snapshots go only after the new name is durable, and recovery
forces what a killed process left in the page cache before it replays. `spec/Merge.tla` models the protocol with the
journal abstracted to its written and durable groups, F1, F2, F4 and the clean-close marker that spares an open its
fsyncs; TLC checks four invariants over 3.8 million states, and each of the four rules, removed alone, gives a
counterexample in 7 steps. This is the protocol ALICE [Pillai 2014]
found many applications get wrong (a rename before the fsync of the data, a file trusted before its directory is
forced).

## 9. What comes next, and why

- **Larger than memory, the rest**: more than one level on disk, so that a change costs fewer
  bytes of merges than the 17 facts of one level (tiering or leveling [Luo 2020], per-level Bloom filters as in Monkey [Dayan 2017];
  scheduling merges around the clients as SILK [Balmau 2019] does, where a plain rate limit did not help here); a third order
  of the rows (property, thing) for workloads that read one property of many things under memory pressure.
- **Compression of runs**: delta and varint, then PFOR (Zukowski et al. [Zukowski 2006], Lemire and Boytsov [Lemire 2015]); an order-
  preserving dictionary rebuilt at each merge (Binnig et al. [Binnig 2009]) for ranges over texts.
- **Rules**: semi-naive evaluation at write time (Bancilhon and Ramakrishnan [Bancilhon 1986]) and Backward/Forward for
  retractions (Motik et al. [Motik 2015]); subscriptions by the delta rules of DBSP (Budiu et al. [Budiu 2023]).
- **Replication**: Raft [Ongaro 2014] with protocol-aware recovery [Alagappan 2018]; the journal is the only replicated thing (Aurora [Verbitski 2017]).
- **Many machines**: databases spread over machines, then storage on object stores (Socrates [Antonopoulos 2019]), then a database
  partitioned by thing with a deterministic order of cross-partition groups (Calvin [Thomson 2012]) and distributed Generic Join
  (BiGJoin [Ammar 2018]).

## Further reading

Each section names its sources; the entries, with links and what Cepheus took from each, are in
[references](references.md), by subject: storage and LSM-trees, logging and recovery, buffer management, indexes,
joins, transactions and isolation, persistent structures, testing and verification, benchmarking and statistics.
