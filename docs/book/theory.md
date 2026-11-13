# Theory

The mathematics behind each part of Cepheus, and the research it builds on. A citation in brackets, [O'Neil 1996], is
an entry of [references](references.md), with its link and what Cepheus took from it. The plain-language account of
the same parts is [architecture](architecture.md).

## 1. The journal and recovery

**Model.** The journal is a sequence of frames $f_1, f_2, \dots$ appended to segment files. Each frame holds groups with
consecutive numbers. Let $D$ be the durable prefix of the file (the bytes covered by a finished `fsync`). A crash (F1,
F2) replaces the file by $D$ followed by some bytes $R$ from the unsynced writes (any subset of their sectors, possibly
torn). Recovery reads frames from the start and stops at the first index $j$ where the bytes do not form a valid frame.

**Invariant I1** (append discipline): a frame is written only after the previous frame's `fsync` returned, so at any
time at most one frame is partly unsynced, and every frame before it lies inside $D$.

**Invariant I2** (acknowledgement): a group is confirmed only after the `fsync` of its frame returned, so a confirmed
group lies in $D$.

**Theorem (G1-G3).** Under F1 and F2, recovery yields groups $1, \dots, k$ with $k \ge$ every confirmed group, each intact.
*Proof.* By I1 and I2, the frames of confirmed groups are in $D$; $D$ is unchanged by the crash; each such frame checks
(header and body CRC), so the scan passes them. The scan stops at the first frame that does not check, which lies
past $D$'s confirmed frames, and everything after it is cut; frames are in group order, so the result is a prefix. ∎

**Damage versus tearing.** At the first bad frame at offset $p$, recovery must decide whether bytes were torn (never
confirmed: cut) or durable bytes were damaged (F3: refuse). Two signs prove that the frame was written whole and so
was once durable-shaped: a frame header that checks after $p$ (I1: a frame after $p$ was written after the one at $p$ was
forced), or a
trailer at offset $t$ whose length field equals $t - p - 28$ and whose body CRC matches the bytes between. A torn write
leaves neither, except if it lost exactly the sector of the header and kept every later sector of the frame (possible
only on a device that reorders sector writes); then recovery refuses to open: a false alarm, never a loss. The
exhaustive test enumerates every crash state of small journals and finds no false alarm in practice, because the
header shares its sector with the start of the body.

**A failed fsync (F4).** I1 rests on a premise Linux breaks: that bytes not covered by a finished `fsync` are at least
not mistaken for durable ones. After a failed `fsync`, ext4 and XFS mark the pages clean while keeping their new bytes
in memory; a later `fsync` returns success without writing them, and every read until a reboot sees them ([Rebello 2020], section 3.3). So the next process, reading the page cache, would see a frame outside $D$ that looks
whole. Two rules keep $D$ the truth. (W) After a failed `fsync` the writer stops and truncates the file to the end of its
last durable frame, then forces it (`Journal.cut`): the frame leaves both the page cache and the disk. (R) A recovery
after anything but a clean close writes its newest frame again before forcing it (`Journal.rewrite_newest`): those
pages are dirty again, so a successful `fsync` writes them and the frame joins $D$; if it fails, the open fails. By I1
and the stop at the first failure, the newest frame is the only one that can lie outside $D$, so (R) alone suffices for
safety (no view outside $D$, G13); (W) makes a failed write's absence certain and spares a later power loss the
false alarm above. The model `spec/Journal.tla` keeps the page cache and the disk apart and checks both rules: without
(R), TLC finds the trace write, failed `fsync`, process death before (W), recovery publishing the frame.

**Detection power** ([Koopman 2002], [Castagnoli 1993]). CRC-32C has Hamming distance 4 for messages up to
about $2^{31}$ bits and 6 up to 5,243 bits: every error of at most 3 bits in a frame (5 bits in a frame of up to 655 bytes)
is detected, every burst of at most 32 bits is detected, and other random errors escape with probability $2^{-32}$.

## 2. Group commit

With one writer and an `fsync` of duration $f$, a closed system of $N$ clients each writing one group at a time reaches a
steady state where each frame holds the groups that arrived during the previous `fsync`. By Little's law
($L = \lambda W$ [Little 1961]), with $N$ clients in the system and a response time $W$, the throughput is $\lambda = N / W$. If every group waits
for at most the rest of the current `fsync` and its own, $f/2 \le W - f \le f$ on average, so
$\lambda \approx N / (1.5 f)$ up to the writer's CPU limit $C$ (groups a second the writer can resolve): $\lambda \approx \min(N / (1.5 f), C)$.
On the test machine $f \approx 3$ ms (about 340 fsync/s) and $C \approx 146{,}000$ groups/s for 5-fact groups (measured): 8 clients
give at most ~1,800 groups/s, 256 clients ~57,000; the measured numbers are in [benchmarks](benchmarks.md).
The writer resolves the next frame while the syncer forces the previous one (two stages), and groups that arrive
during an `fsync` are merged into the waiting frame, so a frame holds everything that arrived meanwhile ([DeWitt 1984],
[Helland 1987]).

## 3. Indexes

A view is a stack of runs $R_1$ (newest) .. $R_k$ (sorted columns in pages, section 9) plus a delta $\Delta$ (persistent maps).
Each run has two parts: the facts it adds (a) and the facts of the runs below it that it retracts (t). Each part keeps
three orders of its rows (run format 8). With $n$ rows in a part, $e$ thing ids and $p$ properties:

| order | layout | lookup |
|---|---|---|
| by thing | a rank table (one 64-bit word for 32 thing ids: their presence bits and the number of things held before them), the slots in blocks of 128, a record a slot with its values by property, sorted | facts of a thing: a rank (one word read, one popcount), the block's header and the record, $O(1)$ a part, $O(k)$ to read; one property: $O(m)$ for the block's $m$ properties; one fact: $O(m + \log k)$ |
| by property | `poff[0..p]`, rows `(w, thing)` sorted, in blocks of 128; a value index (rank words over p's values, the first row of each) for most properties | things with $(p, w)$, or linking to $w$ by $p$: $O(1)$ with a value index, else $O(\log n_p)$, $+ O(\text{answer})$; a range of values: the same |
| column order | each property's rows `(thing, w)` apart, in thing order, in blocks of 128; a rank table over its things (shared by the properties held by the same things); offsets only from its first thing of several values | one property of a thing: a rank, $O(1)$, then $O(1)$ for a one-valued property, $O(\log k)$ for one fact among $k$ values; a thing's values of $p$ as a sorted slice; the things of $p$ in order, each once |

A **rank table** (Jacobson's rank directory [Jacobson 1989]) answers "is thing $e$ in this part, and if so at which
slot?" with one word: bit $e \bmod 32$ of word $\lfloor e / 32 \rfloor$ says whether $e$ is held, and its slot is the count stored in the word
plus the bits set below bit $e$. It costs a quarter of a byte a thing id, where a dense table of offsets (one entry a
thing id, held or not: the one-level base before levels) cost 8; a part that holds every thing from some id to its end
(a load, a full merge) reads no rank there, its slot being an addition. So a thing's facts cost a rank, a block's
header and its record a run to locate: about 0.4 µs at 10 M facts on one run
([benchmarks](benchmarks.md#compressed-runs-and-journal-2026-11-09-at-10-million-facts)). Hexastore
[Weiss 2008] and RDF-3X [Neumann 2008] keep six orders of the triples; Cepheus keeps two because a dense id makes "by
thing" direct, and "by property then value" serves "all things with this property", "the things that link to t by p"
(the rows of value t) and ranges of values; format 8 adds the **column order** (vertical partitioning, Abadi et al.
[Abadi 2007]): a lookup of one property of a thing reads that property's bytes alone (a rank word, a directory entry,
a field: 20 to 40 ns on consecutive invoices against 46 to 61 in a thing's block), and a question over a few
properties reads only theirs (the triangles read `follows`: 2.2 MB of a 70 MB run). It costs 13.9 MB at 10 M facts,
1.4 bytes a fact. Size of a part (format 7, section 11, before the column order): each value in as many bits as its
block of 128 needs from its least, a quarter of a byte a thing id for the rank table, 8 bytes a block of 128 things
and 16 a block of 128 rows, the value indexes, and the dictionary (its texts' bytes, their offsets in a few bits each,
a hash table of two 4-byte slots a text): 5.4 bytes a fact at 10 M facts, against 24.6 in format 6 (22 bytes a row in
fixed words, 8 bytes a thing, 12 bytes a text).

The delta is a set of persistent maps (Driscoll et al. [Driscoll 1989], Okasaki [Okasaki 1998]): each change copies
one path, $O(\log d)$, and an old version stays valid for free. That is what makes views and forks free. It is keyed like
a run (by thing then (property, value); by property then value then thing), so every lookup is a binary search in each
run that may hold the key plus a search in a map, never a walk of a list, and it keeps the net count of facts beside
each map, so that every count the planner reads is exact, runs and delta together (section 9). It costs about 170
bytes a change, so it is bounded: when it passes 200,000 changes (`Engine.compact_min`), a merge starts **in another
domain**: it streams the delta and the newest runs, merged in order, into a new run file ($O(n + d)$, section 8), then
replays the groups written meanwhile (the writer logs them), until it is fewer than 256 groups behind; the writer then
waits for the syncer to be idle (at most one fsync), replays the rest and switches its views to the new runs. Writes
never wait for the $O(n)$ part. This is an LSM-tree [O'Neil 1996]: the delta is the component in memory (C0, level 0),
the runs the components on disk, in levels (section 9).

## 4. Generic Join

A question is a conjunctive query $Q$ over variables $x_1, \dots, x_m$ and atoms $R_j$ (each pattern is a relation of two columns,
the thing and the value, restricted to one property and to its constants).

**AGM bound** (Atserias, Grohe, Marx [Atserias 2008]). For any fractional edge cover $u$ of the variables by the atoms
($\sum_{j \ni x} u_j \ge 1$ for every variable $x$), $|Q| \le \prod_j |R_j|^{u_j}$. For the triangle $R(a, b)$, $S(b, c)$, $T(c, a)$ with $N$ facts
each, $u = (\frac{1}{2}, \frac{1}{2}, \frac{1}{2})$ gives $|Q| \le N^{3/2}$, and some instances reach it. Any plan of joins two at a time can build $\Theta(N^2)$
intermediate rows on some instance (Ngo et al. [Ngo 2012]).

**Algorithm** (Ngo, Ré, Rudra [Ngo 2013]; Veldhuizen [Veldhuizen 2014] for the iterator form). Fix an order of the variables. To bind
$x_i$ given $x_1, \dots, x_{i-1}$: among the atoms containing $x_i$, take the one with the fewest candidates for $x_i$ under the
current bindings (exact counts read from the indexes), enumerate them, and keep a candidate $c$ only if every other
atom on $x_i$ accepts it (one index lookup each). Recurse. A variable with a range, on the value side of an atom whose
thing is free, is enumerated from that property's sorted index over the range only. With lookups in $O(\log n)$, the running time is
$O(m \cdot |\text{atoms}| \cdot \text{AGM}(Q) \cdot \log n)$ (the argument of [Ngo 2013], theorem 4.2: the candidates at each level are bounded by the
intersection's smallest member, and the sum over levels telescopes to the bound). The bound needs two things of the
engine: the counts must be exact (an estimate below the truth makes a large set look small) and an atom that is not
the source must cost a lookup, not a walk of its own candidates. A version of milestone 2 broke the second: it
materialized and sorted the candidates of every bound atom to intersect them, so at each binding it paid for the
largest set (a status shared by 450,000 invoices, sorted once per client of a city: the 10 M benchmark never finished
its third question). Sorted intersection (Leapfrog Triejoin [Veldhuizen 2014]) keeps the bound only with iterators that seek
inside the indexes, or with sets of comparable sizes.

**Leapfrog (run format 8).** A pattern whose other side is known at its level is a **slice**: a thing's values of a
property (the column order) or the things of a value (the order by property), contiguous and sorted in a run. When the
source of a level is a slice of at least 2 candidates, every other slice of the level whose count is at most 8 times
the source's is read too, into a buffer (sorted again only if the view's runs or delta gave it out of order), and the
buffers are intersected by **leapfrogging** [Veldhuizen 2014]: the iterators in the order of their keys, each in turn
seeks the largest key by galloping [Bentley 1976] ($O(\log d)$ for $d$ places), a key all of them reach is a candidate,
checked against the level's other patterns. The level reads $m + \sum n_j \le (1 + 8 (k - 1))\, m$ rows for a source of $m$ and
$k$ slices, and compares $O(m \log(n/m))$: within a constant of Generic Join's work, so within the AGM bound up to that
constant and the log factor. A slice's count and its first row come from one rank and one offset header and are kept
for the known side they were read for (the triangles' "who follows $a$" is read once for every $b$ that $a$ follows). On
the triangles this replaces five membership lookups an edge, each a random place in the column of `follows`, by two
reads of a few contiguous rows: 1.16 s → 0.26 s on one core (benchmarks).

**One value, and checks left to the next level.** A pattern $(y, p, x)$ of a one-valued property $p$ with $y$ bound offers $x$
at most one candidate; its count is not looked up (1 against $2c$ for an exact count $c$, see G11). When it is the first
such pattern of its level and every other pattern there has a fixed count of 1 or more (a constant other side, or one
bound only later), `choose` would take it for every binding: the level reads that one value (`Store.value1`) and
skips the counting. A pattern whose other side is the next level's variable is not checked at its own level (a thing
without that property): at the next level it offers that binding no candidate and is then its source, so the
bindings, the answers and the candidates counted are the same. Q4 reads an invoice's client, the client's city and the
invoice's total as three single values: 247 → 127 ms on one core.

**The tested bound.** `Check.gj_bound` sums, over the levels and the partial bindings that reach each, the smallest
offer $m$ and, where $m \ge 2$, the size of every slice offer of at most $8m$ (the rows the leapfrog may read); every random
question of the tests and the simulation enumerates at most that (`Query.work` counts the candidates of a source and
the rows read into the buffers).

**Correctness (G11).** *Soundness:* a full binding passed every atom at the level of its last variable, with all
other variables of the atom bound, so every atom is a fact. *Completeness:* for an answer $a$, at each level $a_i$
satisfies the source atom (so it is enumerated) and every other atom (so it is kept). *No duplicates:* the candidates
of one level are distinct (each index yields a set: a part of a run holds each fact once, a row of an older run is
shown only if no newer run and not the delta have an entry for the same fact, and the delta adds only facts absent
below it); distinct prefixes give distinct bindings.

**Order.** Cepheus keeps the order of the variables with the smallest estimated work: the candidates its levels
enumerate, each level's partial bindings times the next variable's candidates per binding (the best pattern's count,
given the variables bound before). The partial bindings of a set of variables are the same whatever order bound
them, so they are estimated once a set: the smallest product of candidates per binding over the orders of the set,
since each such product bounds them from above. The best order of a set is then the best order of the set less one
variable, followed by that variable: a dynamic program over the subsets, as Selinger et al. [Selinger 1979] choose
an order of joins, in $n 2^{n-1}$ steps for $n$ variables and exact for this cost.

Two kinds of variables have a known place and stay out of the program. A variable whose only pattern has no other
variable and offers it at most one candidate (a field of a thing given by its id) comes first: it costs 1 there and
multiplies nothing, and it costs at least 1 anywhere. A *leaf*, a variable $y$ whose only pattern gives it as the
value of a one-valued property of a variable $x$, with $d \ge 2$ values in all, comes right after $x$. Proof by
exchange: the partial bindings never shrink along an order (each step multiplies by at least 1). After $x$, $y$ has
one candidate a binding: it multiplies nothing, and costs the partial bindings $S$ of that step, the least it can cost
after $x$. Before $x$, it costs at least 1 and multiplies every later step by $d$: $x$'s own step then costs $d S$
instead of $S$, so moving $y$ right after $x$ changes the cost by at most $S + S - d S \le 0$, and every step between
the two places gets cheaper. So the fields of a row (an invoice's number, status, total, dates) are leaves of the
row's thing, and a page of 7 fields is a program of one or two variables. The program runs over the remaining
variables, up to 12 of them (24,576 steps, each over at most one entry per other variable: the counts are read once a
question, merged by the variable on the other side however many patterns there are); beyond 12, the variable of
fewest candidates next (greedy). The planner before it tried every order for up to 7 variables and went greedy at 8,
which for a sorted page of an invoice's 7 fields (8 variables) began with the status, of 3 values, and read every
invoice in each window of the index path: 8.4 ms against 0.17 ms now (`probe`, 100,000 invoices).
Freitag et al. [Freitag 2020], Mhedhbi and Salihoglu [Mhedhbi 2019] and Wang et al. [Wang 2023] show the order and the mix with ordinary joins
matter most in practice; the measured cost of each question is in [benchmarks](benchmarks.md).

## 5. Serializability and isolation

Define a history $H$ as the sequence of confirmed groups with their reads (`Expect`) and writes. The writer executes
groups one at a time, each on the state left by the previous, so $H$ is serial (Papadimitriou [Papadimitriou 1979]); hence it is
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

A fork is a pair $(\text{view}, \text{delta}')$ where $\text{delta}'$ starts equal to the view's delta. Writes produce new persistent versions
(path copying), so the original view is unchanged by construction; a fork is $O(1)$ to make and costs $O(\log d)$ per change.
Datomic's `with` ([comparison](comparison.md#datomic)) is the same idea on a database value; HyPer [Kemper 2011] forks the process for OLAP snapshots; Rodeh [Rodeh 2008]
does copy-on-write for B-trees.

## 7. Pages and the cache

The runs are read in pages of 16 KiB through one cache for the process (`Pages`: Cepheus' own
cache rather than mmap [Crotty 2022], as LeanStore [Leis 2018], Umbra [Neumann 2020] and vmcache [Leis 2023] do).

**A read.** Each part of a run keeps a table `hot` with one slot a page: the page's bytes, or a constant "absent". Reading 8 bytes
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

**Larger than memory**, 10 M facts (one base of 245 MB at milestone 2), cache 32 MB, the process capped at 128 MB
(benchmarks): open 67 ms (64 MB resident), Q1 41 µs, Q2 1.8 µs, Q3 89 ms, Q4 385 ms on one core and 247 ms on three
(the same answers; PostgreSQL with 32 MB of buffers under the same cap: 176 µs, 5.5 µs, 446 ms through its socket, 697
and 658 ms), peak 79 to 105 MB; on one run of the levels since then, Q1 39.7 µs, Q2 1.54 µs, Q3 85.8 ms, Q4 383 ms,
Q5 96.8 s. Q5 takes 97 to 102 s (PostgreSQL 1.05 s): a client's follow links lie among its invoices' rows (the base
orders rows by thing), so the triangle question reads random pages of all 120 MB of by-thing rows for a few bytes
each. A third order of the rows, by property then thing (as Hexastore [Weiss 2008] and RDF-3X [Neumann 2008] keep), would make one
property of many things local; it costs 10 bytes a fact more. To decide on measurements of real workloads.

**What a merge cost, until it was written to a file.** A merge built the new base in memory (arrays for its sort,
then its pages) beside the old one, and the pages of both lived on the OCaml heap: write runs with merges peaked at
1.8 to 3.3 GB at 10 M facts. Section 8 is the cure.

## 8. Merges written to a file

A merge folds the delta (level 0: persistent maps in memory) and the newest runs on disk into one run (section 9):
the rolling merge of an LSM-tree [O'Neil 1996], several components into the next. Every input is already sorted in the order of
every section of a run (by thing: thing, property, value; by property: property, value, thing; the texts by id), so
each section of the new run is a merge of sorted inputs, made in one pass with one cursor in each: $O(n + d)$ steps for
$n$ rows in the runs and $d$ changes, and no sort. The sources are read a block at a time (a thing's record, a row block
of 128 decoded into a small array), and the new run's blocks are coded as they fill: 128 things, or 128 rows of a
property (section 11).

**Streaming.** The new run is written in three passes, each for both its parts: by thing (rank tables, the thing
blocks and their directory), by property (offsets, row blocks and their directory, the value indexes, distinct
counts), the dictionary (offsets, bytes, the hash table, built in memory: 4 bytes a slot; part a only). A part is laid
out by upper bounds of its counts (a merge knows them only once it is done): the room its streams do not reach counts
as written zeros, and a page wholly inside that room is never written: the file holds only the pages written, in the
order they complete, and a page table at its end maps each page of the layout to its page of the file (a page of the
layout that none holds reads as zeros). In a pass, the streams of its sections advance side by side, each in its own
region of the layout. A 16 KiB page is complete once all its bytes are written (two sections may share one) and goes
out at once: its CRC-32C, a `pwrite` as the next page of the file, and the cache, which admits it cold (in S3-FIFO's
small queue, not hot: a merge's output is a scan, kept only if it is read before the queue reaches it). Then the page
table, the header, an fsync, and the install (G12).

**The memory bound.** Let $C$ be the cache's capacity and $P$ the pages of the new run. During a merge the process holds,
beyond what it held before (the delta, the log of the groups written meanwhile):
- the pages of the runs it reads and of the new run it writes, all counted by the cache: at most $C$, by construction (a
  page enters only through `Pages.fill` or `Pages.admit`, which make room first);
- the pages being filled: the page under each stream's head, and the first page of a section while it waits for the
  section before it to end there: at most 2 for each stream of the pass, $2s$ for $s$ streams: 18 in the pass by
  property; in the pass by thing, run format 8 adds 4 for each property's column, so $s$ grows with the properties of
  the schema (19 pages measured in the unit test, whose bound is 24);
- the tables of the new run: 4 bytes of CRC, 4 of its place in the file, two 8-byte slots (frame and hot) and one
  count a page of its layout, 25 bytes for 16 KiB of layout (the layout of a coded run is loose: 1,118 MB for the
  10 M bottom run's 54.4 MB, so 1.7 MB of tables, 3.1 % of the run);
- the blocks being coded (128 things or 128 rows, with their scratch buffer: a few KiB, more only for a thing with
  very many values) and the text hash table (4 bytes a slot, two slots a text of the new run).

So $M_{\text{merge}} \le C + 2s \times 16\ \text{KiB} + 25 P + 8\, \mathit{ns}$ ($s$ the streams of the larger pass,
$\mathit{ns}$ the texts of the new run), independent of the runs' size but for the tables. The merge in memory it replaced
held 7 words a fact for its sort (560 MB at 10 M facts) and the whole new base outside the cache. Measured on the one
level (benchmarks, the merge written to a file): with the whole base in a 1 GiB cache, a merge of the 10 M base and a delta of 400,000 facts takes the
process from 412 MB to a peak of 651 to 656 MB (the new base's 245 MB of pages), against 1,222 to 1,450 MB for the
merge in memory; with a 32 MB cache, from 63 MB to a peak of 99 MB, under a 128 MB cap that kills the merge in
memory.

**What it costs in writes.** With one level (before section 9), a merge wrote the whole base each time the delta
passed $\max(200{,}000, n/16)$ changes: up to 17 facts of writes per change (the size ratio $r = 16$ of a two-component
LSM-tree, amortized cost $r + 1$ [O'Neil 1996]), 245 MB a merge at 10 M facts, about 400 bytes a change. Those writes compete with
the journal's fsyncs, which every client waits for. Forced once at the end, a merge's 100 to 245 MB of dirty pages made
a journal fsync wait seconds (a load of 3 M facts: the journal's fsync p99.9 1.6 s, max 4.7 s); forced every 8 MiB as
it is written (what RocksDB's `bytes_per_sync` does [Dong 2017]), the tail fell to p99.9 0.43 s, max 1.0 s. Each fsync costs
a merge time, though, so a merge forces in steps only while the journal is writing, and once otherwise. A sustained
load still paid for the bytes: 10 M facts loaded in 135 to 153 s against 63 to 79 s with merges in memory; pacing the
merge's writes (a token bucket, as RocksDB's rate limiter) did not help on this disk. Section 9 is the cure: levels,
and large groups merged at once.

**Crash safety.** See G12 in [guarantees](guarantees.md): the file is forced before its rename, it is named only
once its group is durable in the journal, the runs it replaced go only after the new name is durable, and recovery
writes the newest frame again and forces what a killed process left in the page cache before it replays. `spec/Merge.tla` models the protocol with the
journal abstracted to its written and durable groups, chains of runs (section 9), F1, F2, F4 and the clean-close
marker that spares an open its fsyncs; TLC checks five invariants over 983,080 states, and each of the five rules,
removed alone, gives a counterexample in 4 or 5 steps. This is the protocol ALICE [Pillai 2014]
found many applications get wrong (a rename before the fsync of the data, a file trusted before its directory is
forced).

## 9. Levels on disk, and large groups

**The words.** A **run** is one sorted file of the LSM-tree; a **level** is a place for runs with a capacity, each level
$T$ times larger than the one above ($T$ is the **size ratio**). **Write amplification** $W$ is how many times a fact is
written to the disk by merges over its life, for one write by a client; **read amplification** $R$ is how many runs a
read must visit. Under **leveling**, each level holds one run, and a run that comes down is merged with the one already
there; under **tiering**, a level holds up to $T$ runs, merged together into the next level when it is full. One trades
against the other: fewer runs to read for more rewriting.

**Leveling or tiering.** Let $N$ be the facts, $B$ the changes the delta holds before it is merged (`compact_min`,
200,000), $T$ the size ratio between levels, $L = \lceil \log_T(N/B) \rceil$ the levels on disk. Under leveling [O'Neil 1996], [Luo 2020], each level
is one sorted run, at most $T$ times the one above it; a run enters a level by a merge with the run already there. A
level fills in about $T$ merges from the level above; a fact that comes down at the $k$-th of them is written then and
again at each of the $T - k$ later ones, $T - k + 1$ times, and the average over $k = 1, \dots, T$ is $(T + 1)/2$. So a fact is
written about $(T + 1)/2$ times per level: write amplification $W \approx L (T + 1)/2$. A read visits one run per level:
$R = L$. Under tiering [Luo 2020], a level holds up to $T$ runs, merged into one run of the next level when full: a fact is
written once per level, $W \approx L$, but a read visits up to $T$ runs per level, $R \approx T L$. Lazy leveling (Dostoevsky [Dayan 2018])
tiers every level but the last: $W \approx L - 1 + (T + 1)/2$, $R \approx T (L - 1) + 1$. Bloom filters make a point read of a key
cost about one run's probe whatever $R$ (Monkey [Dayan 2017]), but they help only lookups of a whole key; Cepheus' reads are short
ranges (the facts of a thing, the things of a value) and exact counts, which visit every run that may hold the key.
So $R$ weighs as much as $W$ here, and leveling is the pick.

The numbers, from a model of the 10 M load of the benchmarks (a short script kept with the raw outputs, outside the
repository: the groups of the load in order, small groups of a client each, the merges each policy makes; the facts
each merge writes counted, and the runs a read would visit after each group):

```
policy (B = 200,000)        facts written   amplification   runs at most   runs on average
one level (before)          145 M           14.5            1              1
leveling, T = 4              58 M            5.8            3              2.1
leveling, T = 10             75 M            7.5            2              1.8
tiering, T = 4               39 M            3.9            8              4.4
tiering, T = 8               29 M            2.9           12              7.0
```

$T = 4$ writes 23 % less than $T = 10$ (58 M facts against 75 M) for one run more at most at 10 M facts (3 against 2).
The formula agrees: at $N/B = 50$ it gives $L (T + 1)/2 = 8$, 7.5 and 9 writes a fact for $T = 3$, 4 and 5 ($L = 4$, 3, 3),
and 11 for $T = 10$ ($L = 2$); the model writes less than the formula because the last level is far from full. RocksDB's
default ratio, 10 (its `max_bytes_for_level_multiplier`), suits a reader that has Bloom filters. Picked:
leveling, $T = 4$ (`Engine.ratio`): level $l$ holds at most $B \cdot 4^l$ rows. A merge takes the delta and the newest runs down to
the first level that can hold them all, and writes one run there (`Engine.plan`): the levels it skips are merged in
the same pass, so a fact crosses them with one write.

**Several runs read as one.** A run holds the changes of a range of groups on top of the runs below it: the facts it
adds (part a), and the facts of the runs below it that it retracts (part t, empty at the bottom). Its counts are net:
it adds only facts absent below it and retracts only facts present below it. Then a fact is in a view iff the newest
entry for it adds it, and every count is the sum, over the runs, of the rows of part a minus those of part t, plus the
delta's: exact counts stay $O(R \log n)$. A merge of sources (the delta, the newest runs) decides each fact from its
newest and its oldest entry alone: the newest says whether it is in the new state, the oldest whether it was in the
state below the merged runs (an addition there means it was not); the new run adds it if it is in and was not, retracts
it if it is not and was, and holds nothing otherwise. A merge into the bottom holds no retraction.

A row of an older run is shown only if no newer run holds an entry for the same fact. Each part has a rank table by
thing (Jacobson's rank directory [Jacobson 1989]: per 32 thing ids, their presence bits and the count before them): one bit says
whether a part holds a thing at all, so the check costs a few bit tests unless a newer run holds the same thing; and a
part costs a quarter of a byte a thing id, where the dense table of offsets of the one-level base cost 8 (the 65,536
ids below the first thing included: 512 KiB a base, even a tiny one). A lookup in a part is its rank (one 8-byte word,
a popcount, none when the block's 32 things are all there), then the offsets of its slot, as before.

**Large groups.** A group of many additions (`Resolve.large_min`, 20,000) takes a faster path to the same result
(`Resolve.resolve_large`): its additions go into compact arrays (Bigarrays: 14 bytes a fact, outside the collector's
heap), mapped by several domains in chunks taken in turn [Leis 2014]; the new things and texts are numbered by one pass
in the group's order; the facts are sorted by thing (nothing to do for a group in thing order, else a stable LSD
radix sort of the indexes) and by property (a counting sort), then by a stable LSD radix sort by value inside each
property (11-bit digits, Knuth [Knuth 1998], 5.2.5), and a merge reads them as one more source, the newest, beside the
delta and the runs; no persistent map is built for them. The faster path decides only what it can alone (additions to
new or ordinary things, one value per new thing for a one-valued property, many-valued additions to existing things,
no unique value already taken); on any doubt, the group goes through `Resolve.resolve`, which decides as always
(errors included). Its result is the same: the same changes in the same order, the same thing numbers, the same texts'
numbers (each text is numbered at its first addition, as `Resolve` interns it), so a fork, which always takes
`Resolve`, answers as the database (G8).

*Why the numbering is Resolve's, though chunks are mapped in any order.* `Resolve` gives the $k$-th distinct temporary
id met in the group's order the number $\mathit{next}_e + k - 1$ (a link's target after its operation's thing), and the $j$-th new
text the next text id. The chunks partition the group's order into consecutive slices; a chunk records, in its own
order, what it meets, and the numbering pass reads the chunks in their order, each in its own: it meets every first
use in the group's order, so it assigns the same numbers. The unit tests compare both paths on random large groups
(chunks of 1 to 9 operations, temporary ids near -1 and far below the group's length, groups in no order and in thing
order): the encoding byte for byte, the receipt, the facts after the merge and after a replay.

*Cost.* For $n$ facts of a group in thing order, with $k$ domains: the mapping and the rewriting $O(n / k)$ each, the
numbering $O(n)$ on one domain (an array read a fact), the counting sort by property $O(n / k)$, the radix sort
$O(d n / 2)$ with $d$ passes (2 at 10 M facts: values below $2^{22}$), the merge $O(n)$ on one domain beside the encoding on
another. Memory: 14 bytes a fact in the group's order and 12 by property, a radix pass's room for the largest
property on each of its 2 domains, and the receipt the caller gets (a pair a new thing).

The merge of a large group runs in the writer, when the group is prepared, and writes a run file that is named only
once the group's frame is durable and the run itself forced (the commit forces both at once, on two files, then
installs the run, as a background merge's: G12). No background merge runs beside it, and its frame, written by pieces
beside the merge, is the only frame being written.

## 10. Rules

The rules are Datalog; what a database with rules holds is the least model of its asserted facts ([Abiteboul 1995]).
Four facts make the writer's maintenance exact and its cost what it is ([rules](rules.md) tells the algorithms):

- **The work of a group** is $\Theta(D)$ for $D$ rule instances that involve a fact the group changed: semi-naive evaluation
  enumerates each instance once, at its newest fact, the atoms before the matched one over older rounds and those after
  over rounds up to its own (the semi-naive property, [Ramakrishnan 1990]). The cost model of a group is
  $D \times c_d + N \times c_i$: $c_d$ a derivation (the joins of its body and the test of its head), $c_i$ a new fact put into the
  view, for $N$ new facts. Every fact has at least one derivation, so $D \ge N$; LUBM-shaped data has $D \approx 3.7 N$.
- **Insertion is complete**: an instance of a rule over the state after the group either involves a fact the group
  made present, and semi-naive finds it in that fact's round, or involves only older facts, and the group before found
  it (induction on groups; a rule added is evaluated once over the whole state).
- **Retraction removes exactly the facts without a proof** (Backward/Forward, [Motik 2015]): a fact is kept only if
  the backward check proves it from facts not disproved; a fact is disproved only after its check, which explores every
  instance of every rule that gives it. The check runs over the state before the disproved facts go (a deleted fact may
  fill several atoms of one instance), and the group's retracted facts stay in the state, no longer asserted, until
  they are decided: the conditions under which the algorithm is exact.
- **No maintenance algorithm is cheap in the worst case**: a materialised transitive relation answers reachability,
  and decremental transitive closure has no algorithm much better than recomputing under the OMv conjecture
  ([Henzinger 2015]); B/F's worst case is a recomputation of the facts it reaches. Measured on LUBM-shaped
  data, small retractions stay in microseconds ([benchmarks](benchmarks.md#rules-2026-11-08)).
- **A closure's derivations against its facts.** For prp-trp, $T(x, z) \leftarrow T(x, y), T(y, z)$, the closure fact
  $(x, z)$ is derived once for every $y$ with $(x, y)$ and $(y, z)$ in the closure: $D = \sum_{(x,z) \in T^+}
  |\{y : (x,y), (y,z) \in T^+\}|$, about $n^3/6$ for $n^2/2$ facts on a chain of $n$ (166 a fact at $n = 500$). The
  linear rule derives $(x, z)$ once for each edge out of $x$ on a path to $z$. The closure module makes each new fact
  once: from scratch, over the strong components in reverse topological order, a component's targets are the union
  of its successors' and their own, so the work is $O(V + E + \sum_{u \to w} |\mathrm{targets}(w)| + |T^+|)$, which
  is $O(|T^+|)$ on a forest (each thing's targets its parent's and its parent: walked up, no union at all); an edge
  added to a closure present costs its new facts and the facts met: $(\{a\} \cup \mathrm{pred}(a)) \times
  (\{b\} \cup \mathrm{succ}(b))$ tested once each (Hu, Motik, Horrocks [Hu 2019], [Hu 2022]; Nuutila
  [Nuutila 1995]; Tarjan's components [Tarjan 1972]).
- **Unfolding is exact while its relations hold still.** For a rule $\rho$ with atoms $A$ over relations $R$ and the
  rest $B$, $\rho$'s instances over a state $S$ are the union, over the joint bindings $\theta$ of $A$ in $S$, of the
  instances of $B\theta \to H\theta$: partial evaluation of $\rho$ on $R$ ([Jones 1993]). So the unfolded program and
  $\rho$ have the same least model over any state whose $R$ is the one unfolded on. B/F with the unfolded program
  assumes $R$'s facts proved; that is sound when no fact of $R$ can lose its proof unseen: $R$ must not depend on
  what the unfolded rules give (else a cycle through $R$ could keep two facts alive that only support each other, as
  inverse properties did for counting), and a group that deletes or derives a fact of $R$ is reasoned with $\rho$ as
  written. Of the cost: a rule over a variable property, as written, starts at every fact; unfolded, at the facts of
  its properties only, each plan with its constants in place.

## 11. Compressed runs and journal: the coding and its bound

**Frame of reference.** A block of $n$ integers $x_1, \dots, x_n$ is stored as its least value $b$ and, for each, $x_i - b$ in
$w = \lceil \log_2(\max - b + 1) \rceil$ bits, packed one after the other (Goldstein, Ramakrishnan, Shaft [Goldstein 1998] for pages of
tuples; Zukowski et al. [Zukowski 2006] for columns, there with the outliers patched apart). Field $i$ is at bit $i \cdot w$:
it is read with one unaligned 8-byte load, a shift and a mask (the scalar unpacking of Lemire and Boytsov
[Lemire 2015]; no SIMD in OCaml), so any value of a block costs $O(1)$ and decodes nothing else. A block of sorted
values costs $w \approx \log_2(\text{range of the block})$ bits a value; the coder of the journal also tries **deltas** (the first
value, the least difference $d$, then each difference minus $d$), which wins when values grow steadily (the things of a
load: differences 0 and 1, 1 bit each), and takes whichever block is shorter, a choice made per block as BtrBlocks
does [Kuschewski 2023]. Differences are modulo $2^{63}$ (OCaml's 63-bit integers), so every value comes back exactly.

**What the format holds, against what the data holds.** At 10 M facts (the bench's 113,636 clients and 2.27 M
invoices), the information the data holds is 13-18 MB (totals uniform over 100,000 values, 16.6 bits; dates over
3,650, 11.8 bits; statuses 70/20/10 %, 1.16 bits of entropy; a city one of 100, 6.6 bits; a follow one of 113,636
clients, 15.4 bits a link for 5 distinct ones; names and e-mails 3.4 MB of bytes), and the lists of things by value
add about 18 MB at the Elias-Fano bound of $2 + \lceil \log_2(u/n) \rceil$ bits an element [Vigna 2013]: a store that indexes every
property both ways has a floor near 31-36 MB. The run of format 7 takes 54.4 MB, 1.5 to 1.8 times that floor, against
24.6 bytes a fact (246 MB) in format 6 (sizes in MB of $10^6$ bytes, each section the file pages that hold it):

| section | bytes | a fact | where the bits go |
|---|---:|---:|---|
| by thing: blocks | 23.5 MB | 2.35 B | an invoice's record of fields (client 7 bits, date 12, status 2, total 17, each after a bit "present" in blocks that mix clients and invoices); the clients' properties and follows as small columns |
| by thing: rank table and directory | 0.8 MB | 0.08 B | 32 thing ids a word; 8 bytes a block of 128 things |
| by property: row blocks | 20.3 MB | 2.0 B | things in 7-22 bits (random things over 2.27 M ids take 21-22: the order by value is a permutation), values in 0-10 bits (sorted); things by gaps where a value repeats (status 3.6 bits a row instead of 8.7, date 16.2 instead of 19.8) |
| by property: directory and value indexes | 3.4 MB | 0.34 B | 16 bytes a block of 128 rows; a rank word for 32 values of each property's range and the first row of each value |
| dictionary | 5.9 MB | 0.59 B | the texts' bytes (3.4 MB), their offsets (0.4 MB), the hash table (2.1 MB, two slots a text) |
| page table | 0.5 MB | 0.05 B | 8 bytes a page of the layout (68,231 pages) |

The two largest terms are inherent to the design: every fact is held twice (by thing and by property, each order
answering its own lookups in $O(1)$ or $O(\log n)$), and the order by property of a random property is a permutation of its
things, at the information bound $\log_2(n!)/n \approx \log_2 n - 1.44$ bits a row for $n$ rows (Stirling), which the gaps reach
only where a value repeats. The rest is within a factor 1.5 of the bound.

**Fields and columns by thing.** Three layouts of a thing block were measured on the same 10 M facts (one domain):
a column a property (PAX, Ailamaki et al. [Ailamaki 2001]): a lookup of an invoice touched about 16 cache lines in
blocks that mix clients and invoices (8 properties, each its own column and offsets), Q1 0.79 µs; a record a thing
with every value and a count a property (a row store, as NSM pages): Q1 0.43 µs, but a lookup of one property skipped
the values of the properties before it, 65 to 120 ns on consecutive invoices against format 6's 37 to 41 (Q3 5.8 ms,
Q4 316 ms); and the kept one, a record of **fields** for the properties every thing of the block has at most once,
when that takes no more bits than a column, and columns for the others: a lookup of an invoice's status is the
entry's search among the block's 8 and one field (46 to 61 ns), Q1 0.39 µs, Q3 3.9 ms, Q4 241 ms, for 1.9 MB more
than the records at 10 M facts (absent fields and their "present" bits in blocks that mix clients and invoices).
Scans by property read the row blocks, which are columns already.

**Lookups.** A thing's slot: one rank word. Its block: the directory word, the header (the entries of its
properties, 16 bytes each: a search among the block's $m$). A field: one load at $k R$ plus the field's bit. A column: two
offsets ($c k + \text{residual}_k$) and a binary search among the thing's values of that property (sorted, of one width). By property with a value
index: $O(1)$ (a rank word, two offsets); without: $O(\log b)$ over the property's $b$ blocks, then $O(\log 128)$ in a block.

**Pages and holes.** A merge lays a run out by bounds (it knows its counts at the end), which for coded sections are
loose (the 10 M bottom run: a layout of 1,118 MB for 54.4 MB of bytes). A page table maps each page of the layout to
the page of the file that holds it, so the file holds only written pages, and a page never written reads as zeros;
the cost is 8 bytes a page of the layout in the file (0.5 MB here) and 17 bytes a page in memory for the cache's
tables of an open run (1.2 MB). A block no larger than a page starts on the next page when it would cross one, so a lookup reads its
fields from one page's bytes (the skipped ends cost about 3 % of the blocks' bytes).

**Texts.** Each run's texts are found by an open-addressing hash table with linear probing, at most half full: an
expected 1.5 probes for a text that is there and 2.5 for one that is not (Knuth [Knuth 1998], 6.4), each probe a slot
and a comparison of the text in its page. The hash mixes 7 bytes at a time by multiplication with the multiplier of
xorshift64* [Vigna 2016]. Q2 (a client by e-mail) goes from a binary search of 18 steps (1.6 µs) to one probe and
the value index of the e-mail property (0.65 µs).

**The journal's columns.** A group is coded change by change in its order (replay applies changes in order: a fact
added then retracted in one group, an undeclared property's facts before its declaration), but by columns: the
kinds, the things, the column of each change (its property and constructor), then each column's values, each in
blocks of 128 coded as above, the group's texts once each. The load's group of 9.4 M changes: kinds 0 bits (one
value), things 1-2 bits (deltas 0 and 1), columns 3 bits, values by property (client by deltas, date 12 bits, status
2, total 17), texts 3.4 MB once: 21.6 MB, 2.3 bytes a change, where format 1's varints took 10. The zstd command at
level 19 makes 29.4 MB of the same 94 MB frame (measured here, 2026-11-08; LZ4 at level 1, 56.6 MB): a coding that
knows the structure beats the general compressors, with no C.

## 12. What comes next, and why

- **Larger than memory, the rest** (design, section 15): filters per run for the lookups by value (Bloom filters
  sized per level as in Monkey [Dayan 2017]) if reads across runs need them; scheduling merges around the clients as
  SILK [Balmau 2019] does. The column order (run format 8) took the triangles at a 48 MB cap from more than 2.5 minutes
  a run (format 7) to 0.26 s on one core, against SQLite's 1.02 s ([benchmarks](benchmarks.md)).
- **Questions closer to the kernels** (the prototype's 5 ms for Q4 and 90 ms for Q5, against 129 and 259 ms on one
  core): a level's candidates looked up a batch at a time (vectorized execution) where the per-binding
  calls now cost more than the reads; slices galloped inside the run rather than read into buffers (a gap-coded block
  can only be entered at a value's first row). The merge's coding (about 100 ns a fact) on two domains, one a pass,
  once a helper domain no longer slows the GC's cycles (measured: a domain beside the pass by thing, idle or busy,
  kept 300 MB more of heap at the 4-group load's peak). An order-preserving dictionary rebuilt at each merge (Binnig
  et al. [Binnig 2009]) for ranges over texts.
- **Rules, the next steps** ([rules](rules.md#what-is-not-here-yet)): the closure module for transitive properties
  (Hu, Motik and Horrocks' modular materialisation, [Hu 2019]), rules specialised by the ontology, sorted parallel derivations,
  stratified negation and aggregates (aggregates kept by DBSP's rule for linear operators, Budiu et al. [Budiu 2023]),
  equality by rewriting; subscriptions by the delta rules of DBSP.
- **Replication**: Raft [Ongaro 2014] with protocol-aware recovery [Alagappan 2018]; the journal is the only replicated thing (Aurora [Verbitski 2017]).
- **Many machines**: databases spread over machines, then storage on object stores (Socrates [Antonopoulos 2019]), then a database
  partitioned by thing with a deterministic order of cross-partition groups (Calvin [Thomson 2012]) and distributed Generic Join
  (BiGJoin [Ammar 2018]).

## Further reading

Each section names its sources; the entries, with links and what Cepheus took from each, are in
[references](references.md), by subject: storage and LSM-trees, logging and recovery, buffer management, indexes,
joins, transactions and isolation, persistent structures, testing and verification, benchmarking and statistics.
