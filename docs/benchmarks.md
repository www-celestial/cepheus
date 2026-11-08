# Benchmarks: Cepheus, PostgreSQL and SQLite

Cepheus against PostgreSQL 18.6 and SQLite 3.54 on the same machine, with the same data, the same questions and the
same answers checked on every side. The newest numbers first; milestone 1's at the end, for the history.

## Method

Following Raasveldt et al. [Raasveldt 2018] for fairness, and Hoefler and Belli [Hoefler 2015], Le Boudec
[Le Boudec 2010] and Tene [Tene 2015] for the statistics:

- **Machine**: Intel i7-4720HQ (4 cores, 8 threads, 2015), 11 GB RAM, no swap, btrfs on a consumer SATA SSD (about 340
  fsync a second). Other jobs share the machine: every measure runs under a shared lock that keeps heavy jobs apart,
  in a systemd scope capped in memory (3 GB unless said; the page cache counts in the cap).
- **Builds**: Cepheus in dune's release profile (the dev profile passes `-opaque`, which turns off inlining across
  modules: a slower binary). A change is measured against the binary of the commit before it, built the same way,
  alternated in the same session.
- **Data**: one seeded generator (`bench/bench.ml`): 113,636 clients (name, city among 100, unique e-mail, about 5
  follow links to other clients) and 20 invoices each (client link, total in cents, status: 70 % paid, 20 % unpaid,
  10 % late, a date): 10,000,000 facts; 113,636 client rows, 2,272,720 invoice rows, 568,163 follow rows. Cepheus is
  loaded through its writer; PostgreSQL by `COPY` from CSV files written by the same generator.
- **PostgreSQL as an expert would set it up** (`bench/pg/pg.sh`): its own cluster (initdb, never the system's), fsync,
  synchronous_commit and full_page_writes on, shared_buffers 1 GB, work_mem 64 MB, the natural tables with primary
  keys, a unique e-mail, indexes on every searched column (`client(city)`, `invoice(client)`, `invoice(status)`,
  `follows(b, a)`), `VACUUM ANALYZE`, a warm cache, prepared statements. The rows its write runs insert are deleted
  before any read (so that the answers stay the same).
- **Answers checked**: Q3 city-7: 4,299 rows both sides; Q4: 453,866 unpaid invoices summing to 22,677,088,830 both
  sides; Q5: 114 triangle rotations both sides.
- **Equal cores**: a question on 1 core (Cepheus `CEPHEUS_DOMAINS=1`, PostgreSQL `max_parallel_workers_per_gather=0`)
  and on 3 (3 domains; PostgreSQL 2 workers and its leader: `WORKERS=2`). PostgreSQL decides itself how many workers
  it launches; the number is printed (it launched only 1 for Q5: 2 processes).
- **A time is a median with its 95 % interval.** 21 runs a question (`RUNS`), each run timing many calls for the fast
  questions (200,000 for Q1 and Q2, 100 for Q3) and one call for Q4 and Q5. Times are skewed and often bimodal, so
  no mean and no normal interval: the median, with the interval between two order statistics, x(j) and x(n+1-j),
  which covers the true median with probability 1 − 2 P(B ≤ j − 1), B ~ Binomial(n, 1/2), whatever the distribution
  ([Le Boudec 2010], theorem 2.1; [Hoefler 2015], rule 5). For 21 runs, j = 6: [x(6), x(16)], 97.3 %. The number of
  runs and the exact coverage are printed with every interval (`bench/stats.ml`, used for both sides: PostgreSQL's
  times go through `bench.exe stats`).
- **Latencies from a histogram of every value**, not a sample: log-linear buckets as HdrHistogram does (exact below
  256 µs, then 128 buckets per power of two: every percentile within 0.8 %). p50, p90, p99, p99.9 and max; the p99
  with its 95 % interval (the same order statistics, with Binomial(n, 0.99) in its normal approximation, from 1,000
  values). PostgreSQL's latencies come from pgbench's log of every transaction, into the same histogram.
- **Two kinds of write loads.** Closed loop: each client writes as soon as its last write was confirmed; it gives the
  highest throughput, but its latencies are wrong under stalls: a client stalled by a 400 ms fsync sends nothing
  during the stall, so the writes that would have waited are never measured ("coordinated omission", [Tene 2015]).
  Open loop: writes are due at a fixed rate (client c's k-th write at t0 + (k C + c) / rate), and a write's latency
  counts from the time it was due, as wrk2 does; PostgreSQL's side is `pgbench -R`, whose latencies count from the
  scheduled start (the schedule lag is added). The open loop gives the latencies; the closed loop, the throughput.
- **Where a write's time goes**: the journal's pwrite and fsync of each frame, the writer's resolution of each batch,
  and its wait at a merge switch, each in its own histogram (`Journal.write_us`, `Journal.fsync_us`,
  `Engine.prepare_us`, `Engine.switch_us`); GC collections counted over the run.
- **Larger than memory**: Cepheus with a cache of 32 MB (`CACHE_MB`) and PostgreSQL with shared_buffers 32 MB
  (`SHARED`), each process capped at 128 MB, against a database of 245 MB (Cepheus' snapshot) and 284 MB (PostgreSQL's
  data directory): the same answers, the pages read from the disk, the peak resident memory.

### Commands

| command | what it measures |
|---|---|
| `bench.exe load DIR CSVDIR FACTS` | loads FACTS facts through the writer: `GROUP` clients a group (1 by default: a client and its 20 invoices a group, then a client's follow links a group, by `THREADS` threads, 64 by default; `GROUP=113636` at 10 M facts: two large groups, by 1 thread), times until the last group is confirmed, then merges once (`snapshot`; `SNAPSHOT=0`: not, the runs left as the load made them), and writes the same data as CSV files for the other sides (`NOCSV=1`: no CSV). It prints the writer's histograms (a batch resolved; a large group resolved, encoded, merged; a merge switch; a background merge; the journal's pwrite and fsync) |
| `bench.exe read DIR FACTS [Q1,Q4,..]` | the open (restart from the snapshot), then Q1 to Q5 or the ones named: median and 95 % interval over `RUNS` runs |
| `bench.exe write DIR CLIENTS SECS [RATE]` | durable writes of a new invoice (4 facts) by CLIENTS threads: as fast as they go, or RATE groups a second in all (open loop) |
| `bench.exe merge DIR GROUPS` | GROUPS invoices with no background merge, then one merge (`snapshot`): its time and the peak memory of the merge alone |
| `bench.exe fsync DIR SECS append\|overwrite` | the file system alone: a 9,000-byte frame and its fsync in a loop, appended or written over zeros forced beforehand |
| `bench.exe trace DIR FACTS OUT uniform\|zipf day\|points\|scan` | records the page reads of a day of questions, for the cache study |
| `bench.exe cachesim TRACE` | LRU, CLOCK, 2Q, ARC, SIEVE, S3-FIFO, W-TinyLFU and Belady's optimum on a recorded trace |
| `bench.exe stats NAME [us]` | the summary of numbers read on stdin, one a line, in ms (with `us`: latencies in µs, into a histogram): how the other sides' times go through the same statistics |
| `bench.exe cpu DIR N` | the writer's work alone: N 5-fact groups into a fork of the database (no disk) |
| `bench/pg/pg.sh init\|start\|load\|read\|write\|stop ROOT ...` | PostgreSQL's side on a cluster of its own (`ROOT/data`, port 5544): `start ROOT MEM` caps the server's memory (`SHARED=32MB` sets `shared_buffers`), `read ROOT NCLIENTS` (`WORKERS=k` parallel workers a query, `QS`, `RUNS`), `write ROOT NCLIENTS CLIENTS SECS` (`RATE=r`: open loop) |
| `bench/sqlite/sqlite.sh load\|read ROOT ...` | SQLite's side, one file `ROOT/bench.db`: `load ROOT CSVDIR`, `read ROOT NCLIENTS` (`QS`, `RUNS`, `CACHE_MB`) |

Environment of `bench.exe`: `RUNS` (21), `CEPHEUS_DOMAINS` (the domains of a question), `CACHE_MB` (the cache),
`SYNC_MB` (how often a merge forces its file while clients write, 8), `GROUP`, `THREADS`, `SNAPSHOT` and `NOCSV` (the
load). The statistics are `bench/stats.ml`,
the cache policies `bench/cachesim.ml`.

References: [Raasveldt 2018] M. Raasveldt, P. Holanda, T. Gubner, H. Mühleisen, "Fair Benchmarking Considered
Difficult: Common Pitfalls in Database Performance Testing", DBTest 2018. [Hoefler 2015] T. Hoefler, R. Belli,
"Scientific Benchmarking of Parallel Computing Systems: Twelve Ways to Tell the Masses when Reporting Performance
Results", SC 2015. [Le Boudec 2010] J.-Y. Le Boudec, "Performance Evaluation of Computer and Communication Systems",
EPFL Press, 2010. [Tene 2015] G. Tene, "How NOT to Measure Latency", talk, Strange Loop 2015, and the HdrHistogram and
wrk2 tools.

## The engine fixes (2026-11-08), against the commit before them

Five fixes ([guarantees](guarantees.md#g9-one-writer), [limits](limits.md)): the in-process lock keyed by the lock
file's device and inode, thing numbers refused past 2³¹ − 1, a second `close` that does nothing, `decode` for `fold`'s
words, and frames that stay within 256 MiB however many groups arrive. The writer's path changed (a batch may stop
before a group that would pass the limit, and a large group starts a frame of its own), so the loads and the reads
were measured against the commit before the fixes (2f37b23), both built in release, alternated in one session under
the heavy lock, every process in a 3 GB scope.

| | before the fixes (2f37b23) | after | |
|---|---:|---:|---|
| 10 M facts in 4 large groups (`GROUP=56818`), 6 runs a side | 10.78 s [9.03, 17.00] | 13.12 s [9.72, 14.16] | the intervals overlap; the CPU part is the same (below) |
| 1 M facts, a group a client, 64 threads, 6 runs a side | 9.38 s [8.70, 14.20] | 9.55 s [8.66, 15.10] | the same |
| Q1 an invoice by id, 1 domain | 0.38; 0.38; 0.38 µs | 0.38; 0.37; 0.37 µs | the same |
| Q2 a client by e-mail | 1.57; 1.58; 1.59 µs | 1.56; 1.57; 1.54 µs | the same |
| Q3 unpaid of a city | 3.73; 3.77; 3.74 ms | 3.76; 3.70; 3.73 ms | the same |
| Q4 unpaid sum per city | 233; 233; 231 ms | 232; 230; 234 ms | the same |
| Q5 triangles | 0.99; 1.02; 0.95 s | 0.96; 0.96; 0.97 s | the same |
| open (one run, 10 M facts) | 704; 385; 385 ms | 602; 379; 379 ms | the same |

The loads give the median and its 95 % interval over 6 runs (the smallest and the largest, coverage 96.9 %); each read
cell gives the medians of the 3 rounds (21 runs a question in each process, every interval within 2 % of its median;
the raw outputs keep them). The reads ran on one database, the one the last load before the fixes made (one run after
its `snapshot`), copied for each side, so that both read the same bytes. The large-group load was slower after the
fixes in 5 rounds of 6, by 0.6 to 5.1 s, and faster in the sixth by 6.6 s (a sign test: p = 0.22, two-sided, no
difference shown); the writer's own histograms say where the time went: the
CPU part, a large group resolved and sorted, is the same on both sides (its longest 0.93 to 1.00 s before, 0.93 to
1.10 s after), and the differences are in the merges of the groups into runs (their longest 2.3 to 5.1 s before, 2.6 to
6.5 s after) and the journal's fsyncs, the disk's time on a machine other jobs were using. The load in 2 large groups
of the section below needs 2.7 to 3.2 GB: under the 3 GB cap 6 of its 10 runs were killed, so this comparison used 4
groups (1.7 to 2.5 GB).

## Levels on disk and large groups (2026-11-08), at 10 million facts

Two changes since the merge written to a file (theory, section 9): the runs on disk are the levels of an LSM tree
(leveling, ratio 4), and a large group (20,000 additions and more) is sorted into a run as it is written, with no
per-fact index update. Measured against 148ff09 (one level written to a file) and c7f25c0 (one level merged in
memory), all three built in release and alternated, each on its own database loaded by its own binary; and against
SQLite 3.54 and PostgreSQL 18.6 loading the same facts from the CSV files the benchmark writes. Every side is durable
at the end:
Cepheus confirms a group after the fsync of its frame; SQLite commits in WAL mode with `synchronous = FULL` and
checkpoints; PostgreSQL commits with fsync on and checkpoints.

### Loading

Two ways to write the same facts. *Large groups*: the 113,636 clients with their invoices in one group (9.4 M
additions), then their follow links in a second (568,163): what SQLite's `.import` (one transaction a table) and
PostgreSQL's `COPY` do. *A group a client*: 227,272 groups (a client and its 20 invoices; a client's follows), written
by 64 threads, each confirmed on its own: what an application does when every client is a transaction. The time runs
until the last group is confirmed (`bench.exe load`, `GROUP` clients a group; Cepheus' snapshot after it, one run made
of all, is apart: 1.3 to 6.5 s, depending on the disk).

| 10 M facts | time, median [95 % interval], runs | peak memory | on disk |
|---|---:|---:|---:|
| Cepheus, 2 large groups | 7.04 s [6.52, 7.41], 10 | 2.5 to 3.2 GB | 335 MB (journal 96, runs 237); 553 after `snapshot` |
| SQLite 3.54 as the docs set it up (`.import`, indexes after, `ANALYZE`) | 6.97 s [6.38, 8.00], 10 | 11 MB | 131 MB |
| PostgreSQL 18.6 `COPY`, indexes, `VACUUM ANALYZE` | 32.3 s [29.6, 34.2], 6 | shared_buffers 1 GB | 284 MB (the cluster with its WAL: 675) |
| Cepheus, a group a client | 111.8 s [103.1, 124.4], 4 | 1.6 to 1.8 GB | 487 MB |
| 148ff09, a group a client | 157.5 s [122.0, 179.2], 4 | 1.3 to 2.0 GB | 532 to 550 MB |
| c7f25c0, a group a client | 74.7 s [70.2, 83.2], 4 | 2.7 to 2.9 GB | 100 MB, then 335 after its snapshot |

**Cepheus and SQLite alternated** (`duel.txt`: 10 rounds, a Cepheus load then a SQLite load, so that both meet the
same disk): a tie. Cepheus was faster in 4 rounds of 10 (a sign test sees no difference), and the median of the paired
differences is 0.16 s in SQLite's favour. Both are under the 8.6 s SQLite took when it was first measured (the reads' section below) on a
busier disk; the series before these, not alternated, gave 8.46 s [6.07, 10.98] (7 runs) for Cepheus and 8.84 s [7.85,
9.75] (6 runs) for SQLite. The durability is the same: a Cepheus group is durable when it is confirmed (its frame
forced), a SQLite `.import` is one transaction committed with `synchronous = FULL` in WAL mode, and both end forced
(Cepheus' runs, SQLite's checkpoint). Cepheus makes its facts in the process (the benchmark's client side, 1.3 s on 4
domains); SQLite parses them from the CSV files. SQLite keeps the load in 11 MB and 131 MB of disk, Cepheus needs 2.5
to 3.2 GB and 335 MB.

At the durability of a group a client, SQLite has no group commit: one writer, one fsync a commit. At 1 M facts
(11,363 clients, 22,726 transactions, each a client and its invoices, or a client's follows; a Python `sqlite3` script
kept with the raw outputs, the indexes made first, as Cepheus keeps its own): SQLite 166.7 s [138.6, 169.3] (3 runs; 6 to 7 ms a commit, file 13 MB, peak 111 MB);
Cepheus, a group a client by 64 threads, 10.6 s [9.9, 10.9] (3 runs; 283 to 322 MB, 42 MB on disk), 16 times less:
its writer puts the groups that arrive during an fsync into the next frame (group commit), where SQLite's single
writer forces each commit alone; Cepheus in two large groups 0.94 s [0.86, 1.28] (3 runs; 277 to 306 MB, 33 MB). At
10 M facts, the same 227,272 commits of SQLite would take about 28 minutes at this rate (not measured).

**The journal's fsync while loading a group a client** (p99 of each load): Cepheus 56 to 102 ms, c7f25c0 40 to 102 ms,
148ff09 148 to 287 ms: the cure of the regression of the merge written to a file (its merges of the whole base made each fsync wait).
The time of that load is another story: 112 s against c7f25c0's 75 s. With a group a client, the load is bound by its
frames (9,500 to 11,000 fsyncs of 3.7 to 4.5 ms at the median, a frame every 11 ms) and by the merges of the levels,
whose writes (a fact about 6 times, 1.3 GB at 10 M facts, forced every 8 MiB while the journal writes) share the disk
with the journal; c7f25c0 kept its merges in memory (2.7 to 2.9 GB at its peak, against 1.6 to 1.8) and wrote nothing
but the journal until its snapshot.

**Where a large load's time goes** (the writer's histograms, on a quiet disk): the client side makes its 9.4 M
operations in 1.3 s (4 domains); the writer resolves and sorts them in 1.9 to 2.3 s (one pass over the operations
1.1 s, the sorts 0.8 s, the radix sorts on 4 domains), encodes the frame (0.4 s, beside the merge, in another domain),
and merges them into a run in 1.8 s on a quiet disk (by thing 0.5 s, by property 0.7 s, the dictionary 0.2 s, the
fsync of its 220 MB 0.4 s; 3 to 5.6 s when the disk is busy); the journal's frame of 113 MB takes 0.2 to 0.4 s to
force; the follows group 0.4 to 1.5 s. The spread of the runs (6.1 to 11 s) is the disk's: the same binary, the same
data, the merge's fsync from 0.4 to 4 s. What would go further, without bending a guarantee: the three passes of the
merge in parallel (they write apart in the file: about -0.7 s); the run's fsync and the journal's at once rather than
one after the other (-0.3 s; the run must still be forced before its name, G12); fewer bytes (a run of 23 bytes a
fact and a frame of 12, against SQLite's 14 for its table and indexes: delta and varint coding of the sorted columns).
Memory: the operations of one 9.4 M group, its arrays and its frame are in memory at once (2.5 to 3.2 GB); smaller
groups need less (1 M facts in one group: 277 MB) but each merges with the runs before it.

### Reads, all in memory

21 runs a question, 2 rounds alternated (each cell: the medians of the 2 rounds; intervals in the raw outputs (`read-final.txt`), all within a few percent of their median). *new* is the database after its snapshot (one run); *new, 2
runs* holds the same facts as the load left them: the clients' run and the follows' run (which holds every client).

| 1 domain | Q1 | Q2 | Q3 | Q4 | Q5 | open |
|---|---:|---:|---:|---:|---:|---:|
| new, one run | 0.38; 0.38 µs | 1.57; 1.58 µs | 3.82; 3.74 ms | 237; 231 ms | 1.00; 0.95 s | 384; 383 ms |
| new, 2 runs | 0.38; 0.38 µs | 1.70; 1.76 µs | 5.35; 5.41 ms | 332; 331 ms | 1.01; 1.02 s | 495; 587 ms |
| 148ff09 | 0.35; 0.34 µs | 1.58; 1.54 µs | 4.10; 4.06 ms | 226; 227 ms | 1.00; 0.94 s | 414; 396 ms |
| c7f25c0 (the first series) | 0.38; 0.37 µs | 1.58; 1.64 µs | 3.98; 3.94 ms | 229; 227 ms | 0.95; 0.97 s | 397; 421 ms |

| 3 domains | Q1 | Q2 | Q3 | Q4 | Q5 |
|---|---:|---:|---:|---:|---:|
| new, one run | 0.37; 0.38 µs | 1.55; 1.57 µs | 3.75; 3.76 ms | 107; 107 ms | 362; 360 ms |
| new, 2 runs | 0.39; 0.39 µs | 1.75; 1.76 µs | 5.38; 5.42 ms | 143; 144 ms | 370; 368 ms |
| 148ff09 | 0.36; 0.35 µs | 1.57; 1.59 µs | 4.13; 4.12 ms | 106; 104 ms | 360; 369 ms |

The last binary against 148ff09 once more, 3 rounds alternated, one domain (`read-last.txt`), the medians of each
round: Q1 0.37, 0.38, 0.38 µs against 0.37, 0.37, 0.36; Q2 1.61, 1.57, 1.64 against 1.62, 1.61, 1.57 µs; Q3 3.79,
3.78, 3.79 against 4.19, 4.12, 4.13 ms; Q4 234, 239, 231 against 230, 226, 227 ms; Q5 1.02, 1.01, 0.97 against 1.01,
0.95, 0.97 s; open 381, 383, 440 against 386, 399, 386 ms.

On one run, the questions run as on the one-level base: Q2 and Q5 the same; Q1 0.01 to 0.04 µs slower (3 to 10 %, and
the difference moves as much between rounds); Q4 2 to 5 % slower; Q3 8 % faster. A lookup reads one word more, a rank,
except in a part that holds every thing up to its end (a load, a full merge), where the slot is an addition. The first
measure of the levels was 17 to 23 % slower (Q1 0.42 µs, Q4 286 ms: `read-before-store-fixes.txt`): closures allocated
per lookup, a rank read for every thing, lists for one run; fixed before these numbers. On two runs, a row of the
older run is shown only if the newer run has no entry for the same fact: a few bits of the rank tables when the newer
run does not hold the thing, a lookup when it does (here it holds every client): Q3 +43 %, Q4 +40 % on one domain; a
run with no row of the property is skipped at once (Q5, the follows, the same as one run). A `snapshot` merges
everything into one run.

### Larger than memory

Cache 32 MB, the process capped at 128 MB; 5 runs (Q5: 1 run); the first series for 148ff09 and c7f25c0:

| | Q1 | Q2 | Q3 | Q4 | Q5 | Q4, 3 domains |
|---|---:|---:|---:|---:|---:|---:|
| new, one run | 39.7 µs | 1.54 µs | 85.8 ms | 383 ms | 96.8 s | 229 ms |
| 148ff09 | 40.6 µs | 1.65 µs | 89.8 ms | 378 ms | 99.9 s | 278 ms |
| c7f25c0 | 39.5 µs | 1.50 µs | 85.8 ms | 381 ms | 99.5 s | 243 ms |

The database as the load leaves it (2 runs), the same set-up, alternated with the one-run database, 2 rounds
(`big-runs.txt`; each cell: round 1; round 2):

| 1 domain | Q1 | Q2 | Q3 | Q4 | open | peak |
|---|---:|---:|---:|---:|---:|---:|
| new, 2 runs | 41.9; 40.9 µs | 2.03; 1.83 µs | 91.2; 89.4 ms | 482; 486 ms | 165; 197 ms (54-56 MB) | 58 MB |
| new, one run | 42.3; 41.6 µs | 1.69; 1.72 µs | 92.8; 90.9 ms | 394; 393 ms | 70; 80 ms (32 MB) | 51 MB |

Before db91dac, the 2-run database did not open under the cap: the open read its journal segment of 94 MB whole,
although its runs held every frame of it (the segment of the clients' group). The journal is now read through a
window of 4 MiB, a frame the runs hold checked by its CRC piece by piece. A first measure after the fix gave Q3 613 ms
on one domain; it did not repeat (89 to 91 ms in both rounds above; 89.5 ms on 3 domains).

### Writes at 256 clients, with their merges

Closed loop, 10 s, 6 runs a side on a fresh copy of each database (alternated); the peak is the process's VmHWM, the
merge memory of the method of milestone 2:

| | durable groups/s, median [interval] | peak memory, median [interval] | journal fsync p99, the 6 runs |
|---|---:|---:|---:|
| new | 18,252 [13,574, 24,383] | 762 MB [723, 1,300] | 16.5 to 131 ms (median 27) |
| 148ff09 | 18,168 [14,613, 22,488] | 1,040 MB [842, 1,161] | 29 to 50 ms (median 35) |
| c7f25c0 | 18,546 [17,000, 20,889] | 2,095 MB [1,778, 3,024] | 20 to 39 ms (median 22.5) |

The throughput is the disk's, on every side. A merge now writes a level of a few hundred thousand facts (0.3 s) where
148ff09 rewrote the base (3.7 s), so the peak falls by a quarter against 148ff09 and by two thirds against c7f25c0.

**Method.** As above: every process under the heavy lock and a memory cap, the sides alternated in one session,
medians with their distribution-free 95 % intervals (order statistics; with 6 runs the interval is the smallest and
the largest, coverage 96.9 %; with 4, 87.5 %; with 7, 98.4 %; with 10, the second smallest and the second largest,
97.9 %), latencies from histograms, the same answers on every side (Q4 453,866 invoices summing to 22,677,088,830; Q5
114 rotations). Between two processes of the same binary, the medians differ more than their intervals say (Q1 from
0.34 to 0.47 µs for 148ff09 in one session): the rounds are alternated and each cell shows both. Scripts:
`bench/bench.ml` (`GROUP`, `THREADS` and `SNAPSHOT` are new), `bench/pg/pg.sh`, the SQLite set-up of the docs
(`.import`, the indexes after, `ANALYZE`, a checkpoint).

## SQLite 3.54 at 10 million facts: the reads (2026-11-08)

SQLite is, like Cepheus, a library inside the application's process, so this is the fairest comparison of the two
engines: no socket on either side. Same data (the CSV files of `bench.exe load`), same questions, same answers (Q3
city-7: 4,299 rows; Q4: 453,866 invoices, 22,677,088,830; Q5: 114 rotations). SQLite set up as an expert would
(`bench/sqlite/sqlite.sh`): `INTEGER PRIMARY KEY` tables (the key is the row's address in its B-tree), `follows` as a
`WITHOUT ROWID` table keyed by (a, b), a unique index on the e-mail, indexes on `client(city)`, `invoice(client)`,
`invoice(status)`, `follows(b, a)`, `ANALYZE`; a page cache of 1 GiB (`PRAGMA cache_size`, as Cepheus' cache; the
default is 2 MB), `temp_store = MEMORY`, warmed by one pass of every question. Its plans, from `EXPLAIN QUERY PLAN`:
Q3 the city index then `invoice(client)`; Q4 the status index, then each invoice's client by its key, and a temporary
B-tree for the GROUP BY; Q5 nested loops over the two covering indexes of `follows`. The questions are timed in the
process by Python's `sqlite3` module (`bench/sqlite/read.py`): Q1 and Q2 run 100,000 lookups inside one statement,
driven by a recursive CTE (the "engine only" measure, as PostgreSQL's PL/pgSQL loop), Q3 one statement per city (100
a run), Q4 and Q5 one statement a run. 21 runs a question, two rounds alternated with Cepheus (release build of
`docs-full`, the engine of 148ff09, one domain, `CEPHEUS_DOMAINS=1`), each process under the heavy lock and a 3 GB cap.
Raw output: the median and its 95 % interval of each round.

| question | Cepheus, 1 domain, rounds 1 and 2 | SQLite, rounds 1 and 2 | |
|---|---|---|---|
| Q1 every fact of an invoice, by id | 0.36 µs [0.36, 0.36]; 0.38 µs [0.37, 0.40] | 0.67 µs [0.67, 0.68]; 0.68 µs [0.68, 0.70] (about 0.45 µs without the CTE's 0.23 µs a row) | Cepheus, 1.2 times |
| Q2 a client by e-mail | 1.67 µs [1.64, 1.71]; 1.66 µs [1.62, 1.83] | 1.52 µs [1.50, 1.57]; 1.52 µs [1.51, 1.58] (about 1.22 µs without the CTE and the e-mail's concatenation, 0.30 µs a row) | **SQLite**, 1.1 to 1.4 times |
| Q3 unpaid invoices of a city's clients | 4.17 ms [4.15, 4.22]; 4.19 ms [4.12, 4.33] | 4.13 ms [4.10, 4.16]; 4.19 ms [4.15, 4.23] | even |
| Q4 unpaid sum per city | 230 ms [229, 232]; 230 ms [226, 232] | 355 ms [352, 364]; 366 ms [359, 369] | Cepheus, 1.55 times |
| Q5 triangles | 979 ms [957, 986]; 969 ms [967, 1,020] | 1.04 s [1.03, 1.08]; 1.04 s [1.04, 1.05] | Cepheus, 1.07 times |
| load 10 M facts (measured again after the levels, [above](#loading)) | 7.04 s [6.52, 7.41] in 2 large groups; 111.8 s a group a client | 6.97 s [6.38, 8.00] (`.import`, indexes, `ANALYZE`), alternated with Cepheus' large groups | even in large groups; at a transaction a client, Cepheus 16 times (1 M facts) |
| size on disk | 335 MB after the load (journal 96 MB, runs 237 MB) | **131 MB**, one file | **SQLite**, 2.6 times |

The CTE's own cost was measured alone (`WITH RECURSIVE` over 100,000 rows, the same arithmetic, no lookup): 0.227 µs a
row [0.224, 0.234], 0.295 µs [0.293, 0.297] with the e-mail's concatenation; the "without" figures subtract those
medians, so they are estimates. Q2 reads the client's row on SQLite's side (as on PostgreSQL's) and only the client's
number on Cepheus' side, and SQLite is still faster: Cepheus finds a text by a binary search of its dictionary's sorted
list (about 18 steps for 227,387 texts, each step a text compared in another part of memory), then the rows of that
text by a second binary search, where SQLite's B-tree reaches the e-mail in 3 or 4 pages. With 3 domains, Cepheus'
Q4 and Q5 take 107 ms and 371 ms; SQLite runs a statement on one thread. When this table was first
measured (on the one-level engine of 148ff09), a load through the writer took 107 s against SQLite's 8.6 s: Cepheus
rewrote its whole base at each of its 31 merges. With the levels and the large groups, a load written as two large
groups ties SQLite's `.import` (the section above). SQLite's records (variable-length integers in B-tree pages) stay
about half the size of Cepheus' 8-byte words, and SQLite loads in 11 MB where a large group needs 2.5 to 3.2 GB. Not
measured on SQLite's side: concurrent durable writes (SQLite has one writer at a time), and reads larger than memory.
The reads above were measured on the engine of 148ff09; on one run, the levels read at the same speed (the next
section), so the comparison holds.

## The merge written to a file (2026-11-08), at 10 million facts

A merge now streams the new base into its snapshot file, page by page, instead of building it in memory (theory,
section 8; G12). Measured against the commit before it (c7f25c0, merges in memory), both built in release, with the
method above; each side on its own database loaded by its own binary (same facts; format 3 against format 4, the same
245,824,096-byte snapshot). `bench.exe merge DIR GROUPS` is new: GROUPS invoices written with no merge in the
background, then one merge of the whole base and the delta (`snapshot`), its time and the process's peak during the
merge (the peak reset just before it, through `/proc/self/clear_refs`).

**Memory of write runs with their merges** (the method of milestone 2: six runs of 10 s at 256 clients on a fresh
copy, the peak resident memory of the process sampled every 0.2 s; two rounds a side, alternated: 12 runs a side):

| | peak, median [95 % interval] | min to max | durable groups/s, median [95 % interval] |
|---|---:|---:|---:|
| merges in memory (c7f25c0) | 2,589 MB [1,785, 2,796] | 673 to 2,954 MB | 19,126 [15,751, 20,436] |
| merges to a file | 1,126 MB [993, 1,188] | 948 to 1,307 MB | 19,388 [17,413, 20,966] |

The peak falls by 57 %; the write rate does not change (the intervals overlap widely; one old run fell to 1,749
groups/s in a disk stall). A later round of six runs on the new side (the merge's own histogram): each background
merge of the 245 MB base took 3.6 to 4.2 s beside the writes (5 merges), and the writer's switch to it 44 to 210 ms.

**One merge** (`bench.exe merge DIR 100000`: 100,000 invoices, 400,000 facts, written with no merge in the background,
then one merge of the whole base and the delta into a new file; six rounds a side, alternated; with 6 runs the 95 %
interval is [min, max], 96.9 %):

| | merge time, median [95 % interval] | peak during the merge, median [95 % interval] |
|---|---:|---:|
| merges in memory (c7f25c0) | 3.21 s [2.49, 9.88] | 1,342 MB [1,221, 1,452] |
| merges to a file, forced once | 2.29 s [2.17, 2.84] | 659 MB [656, 660] |
| merges to a file, forced every 8 MiB | 9.07 s [4.88, 15.86] | 655 MB [651, 656] |

The process held 409 to 418 MB before the merge on both sides. The streaming merge is faster than the merge in memory
when forced once (no sort, no arrays), and holds half the memory: the new base's 245 MB of pages, beside the old base
in the cache. Forced every 8 MiB, each fsync costs on this disk: so a merge forces in steps only while clients write
beside it (below), and a merge nobody waits beside (`snapshot`, recovery) forces once.

**A merge in a process capped at 128 MB**, cache 32 MB, the same 245 MB base and a delta of 20,000 invoices: the merge
to a file takes 7.6 s, with 63 MB resident before it and a peak of 99 MB (the cache's 32 MB, a few pages, the tables);
the merge in memory is killed by the cap (exit 137) once it starts (it had written the 20,000 groups with 64 MB
resident). That is the bound of theory, section 8: a merge needs the cache,
not the base.

**Reads, everything in the cache** (21 runs a question, two rounds a side, alternated; the medians with their 95 %
intervals; the same answers): the read path did not change, and no difference stands out of the noise.

| question | domains | merges in memory (c7f25c0), rounds 1 and 2 | merges to a file, rounds 1 and 2 |
|---|---:|---|---|
| Q1 | 1 | 0.40 µs [0.38, 0.51]; 0.39 µs [0.37, 0.44] | 0.39 µs [0.35, 0.66]; 0.36 µs [0.36, 0.37] |
| Q1 | 3 | 0.37 µs [0.36, 0.38]; 0.38 µs [0.37, 0.39] | 0.39 µs [0.36, 0.67]; 0.38 µs [0.36, 0.41] |
| Q2 | 1 | 1.68 µs [1.61, 1.74]; 1.62 µs [1.60, 1.65] | 1.63 µs [1.59, 2.00]; 1.63 µs [1.61, 1.80] |
| Q2 | 3 | 1.64 µs [1.60, 1.81]; 1.64 µs [1.58, 1.98] | 1.91 µs [1.80, 2.21]; 1.63 µs [1.62, 1.68] |
| Q3 | 1 | 4.13 ms [4.09, 4.28]; 4.09 ms [3.98, 4.30] | 4.11 ms [4.06, 4.42]; 4.10 ms [4.01, 4.48] |
| Q3 | 3 | 4.09 ms [3.97, 4.24]; 4.09 ms [4.03, 4.44] | 4.34 ms [4.01, 4.79]; 4.02 ms [4.00, 4.26] |
| Q4 | 1 | 233 ms [230, 237]; 231 ms [230, 235] | 230 ms [229, 248]; 233 ms [230, 245] |
| Q4 | 3 | 105 ms [103, 119]; 104 ms [102, 108] | 107 ms [102, 112]; 105 ms [102, 113] |
| Q5 | 1 | 1.02 s [1.01, 1.07]; 1.03 s [1.01, 1.13] | 1.03 s [1.01, 1.10]; 1.02 s [0.97, 1.05] |
| Q5 | 3 | 370 ms [359, 406]; 382 ms [376, 402] | 373 ms [360, 393]; 377 ms [365, 447] |

Open (restart from the snapshot, 15,000 pages read and checked), four runs a side: 408 to 497 ms against 410 to
503 ms. After a crash, open now forces the newest segment and two directories (G5); after a clean close it skips them
(the marker). Seven alternated opens a side, once the marker was in: the 10 M database with a 32 MB cache (1,313 pages
read) 65 to 72 ms against 65 to 67 ms; a database of 10,000 facts 2.8 to 2.9 ms against 2.8 to 3.0 ms. On this disk an
fsync of a file or directory that did not change costs under 0.01 ms; while the file system commits other work, it can
cost tens of ms (one open measured 117 ms against 66 before the marker).

**Reads larger than memory** (cache 32 MB, the process capped at 128 MB, 5 runs a question, 8 domains, the same
answers): Q1 43.1 µs [41.2, 44.6] against 41.2 µs [39.6, 41.8]; Q2 1.68 µs [1.53, 1.99] against 1.61 µs [1.48, 1.66];
Q3 91.8 ms [88.7, 94.6] against 88.7 ms [86.4, 90.9]; Q4 678 ms [650, 795] against 678 ms [664, 744]; 3.92 million
pages read from the disk on both sides; peak 122 MB against 120 MB. (With 5 runs the interval is [min, max], 93.8 %.)

**Loading 10 M facts, and what a merge's writes cost the journal** (`bench.exe load`: 64 clients, groups of 83 facts,
about 33 merges as the base grows; one run a line, alternated):

| | load | peak | journal fsync p99 | max | merge switch p99 |
|---|---:|---:|---:|---:|---:|
| merges in memory (c7f25c0) | 62.5 s; 79.3 s; 70.8 s | 2,841; 2,962; 2,874 MB | 72; 46 ms | 0.84; 0.72 s | 459; 114 ms |
| merges to a file, forced once | 124.2 s | 1,844 MB | | | |
| merges to a file, forced every 8 MiB while clients write | 134.7 s; 153.4 s | 1,813; 1,500 MB | 187; 203 ms | 2.96; 3.92 s | 802; 529 ms |

Here the merge to a file loses: a load is all writes, and each of its merges rewrites the whole base, about 3.3 GB in
all over the load, beside the journal, whose fsyncs every client waits for (a merge in memory writes nothing). At
3 M facts (one run each): merges in memory 16.4 and 19.5 s; to a file forced once 32.6 s (a journal fsync up to
4.7 s), forced every 8 MiB 23.5 s, forced every 8 MiB only while the journal writes 20.3 s; pacing the merge's writes
(a token bucket, as RocksDB's rate limiter) at 32 and 64 MB/s gave 23.8 and 23.3 s, no gain, and was left out. Writes
at 256 clients with a merge every 10 s or so (above) do not see the difference; a sustained bulk load does, and more
as the base grows. The remedy is fewer bytes a change: more than one level on disk (theory, section 9), or a higher
merge threshold (n/8 halves the bytes and doubles the delta's memory).

## Milestone 2 at 10 million facts

Release build of 804656f (pages and cache), whole base in the cache (1 GiB), 21 runs a question, 2 rounds
alternated with PostgreSQL; a cell is the median of the round with the higher median, and its 95 % interval.

| question | Cepheus, 1 core | PostgreSQL, 1 process | Cepheus, 3 domains | PostgreSQL, 3 processes |
|---|---:|---:|---:|---:|
| Q1 every fact of an invoice, by id | **0.39 µs** [0.38, 0.41] | 4.73 µs [4.69, 4.77] (engine); 26 µs (socket) | 0.39 µs | |
| Q2 a client by e-mail (unique) | **1.68 µs** [1.66, 1.72] | 5.68 µs [5.65, 5.72] (engine); 26 µs (socket) | 1.66 µs | |
| Q3 unpaid invoices of a city's clients (4,299 rows) | **4.07 ms** [4.05, 4.10] | 10.55 ms [10.49, 10.79] | 4.06 ms | 14.58 ms [14.43, 14.78] |
| Q4 unpaid sum per city (453,866 invoices) | **230.7 ms** [228.7, 233.7] | 236.5 ms [235.2, 237.5] | **107.3 ms** [102.5, 112.4] | 109.1 ms [108.3, 109.2] |
| Q5 triangles of the follow graph (114 rotations) | 1.03 s [1.02, 1.03] | 1.03 s [1.02, 1.04] | **371 ms** [367, 373] | 603 ms [599, 605] (2 processes: 1 worker launched) |

PostgreSQL's Q1 to Q3 through its socket (pgbench, prepared, one client): 26 µs, 26 µs, 14.6 ms (with 2 workers allowed;
7.4 ms with none: its parallel plan is slower for Q3).

Milestone 2 changed (each measured against the commit before it, alternated):
- **Parallel questions** (89ec951, c67e52d): Q4 on 3 domains 198 -> 103-107 ms, Q5 955 -> 360-371 ms. The first
  version gained only 1.7x on Q4: the first level's 453,866 candidates were checked against the other patterns on
  one domain (42-45 ms of 124, measured; Amdahl's law fitted on 1, 3 and 4 domains gave 78 ms of serial work). Now
  each slice checks its own, and the domains take slices in turn from a shared counter.
- **Pages and cache** (804656f): when everything is in memory, Q1 +5 %, Q2 -4 %, Q3 +8 %, Q4 +13 %, Q5 +3 to +8 %
  against the mapped base (theory, section 7, for why and what was tried).
- **A bug fixed** (b96dec5): the sorted intersection had sorted every candidate list of a level, so a question could
  take O(N log N) per binding instead of O(smallest); every question is now checked against the Generic Join bound.

### Durable writes

08e8f98, 3 rounds alternated with PostgreSQL, each round on a fresh copy of the 10 M database (7 runs of 10 s: 1, 8,
64 and 256 clients as fast as they go, then 256 clients at fixed rates); a Cepheus group makes a new invoice (4 facts),
PostgreSQL inserts the same invoice row; both durable (fsync). Throughput: the median of the rounds, and each round;
latencies (from a histogram of every write): the range over the rounds of each percentile.

| durable writes, 3 rounds of 10 s | Cepheus groups/s (median; rounds) | PostgreSQL inserts/s | Cepheus p50 / p99 / p99.9 ms | PostgreSQL p50 / p99 / p99.9 ms |
|---|---:|---:|---:|---:|
| 1 client, as fast as they go | 181 (208, 181, 175) | 185 (188, 185, 135) | 3.29-3.65 / 15.8-21.5 / 75.8-268 | 3.18-3.62 / 19.2-53.2 / 130-459 |
| 8 clients, as fast as they go | 646 (917, 284, 646) | 990 (1,077, 990, 591) | 5.70-6.85 / 32.1-627 / 163-1,998 | 6.08-6.72 / 21.0-153 / 34.3-390 |
| 64 clients, as fast as they go | 7,147 (7,147, 7,765, 4,185) | 4,625 (7,779, 4,625, 2,439) | 6.14-10.2 / 28.0-135 / 59.6-524 | 6.43-6.56 / 23.0-416 / 307-1,991 |
| 256 clients, as fast as they go | 14,182 (14,182, 17,192, 14,141) | 19,559 (19,559, 12,742, 20,863) | 9.79-10.9 / 66.0-264 / 326-598 | 9.54-12.6 / 35.8-102 / 309-1,917 |
| 256 clients at 2,000 a second (open loop) | 1,999 (1,998, 1,999, 1,999) | 1,994 (1,994, 1,999, 1,940) | 5.12-15.6 / 98.8-1,655 / 179-1,745 | 8.89-20.6 / 586-6,128 / 762-6,357 |
| 256 clients at 5,000 a second (open loop) | 4,997 (4,997, 4,766, 4,997) | 4,957 (5,010, 4,957, 4,747) | 6.24-10.5 / 146-717 / 483-791 | 8.03-68.6 / 442-3,654 / 586-3,785 |
| 256 clients at 10,000 a second (open loop) | 9,993 (9,993, 9,995, 9,982) | 9,879 (9,879, 9,847, 9,888) | 9.54-24.3 / 202-1,032 / 233-1,044 | 6.66-219 / 774-1,311 / 885-1,352 |

What it says. Throughput is on par, and bound by the disk's fsync rate times the frame size on both sides (theory,
section 2); this disk was noisy in these rounds (a frame's fsync: p99.9 up to 450 ms, max up to 2.6 s), so a side's
rounds differ by up to a factor of 3, more than the two sides differ. The latencies that count are the open loop's:
with writes due at a fixed rate, every write delayed by a stall is measured. There, Cepheus' p99 is lower than
PostgreSQL's at every rate (at 2,000 a second: 0.1 to 1.7 s against 0.6 to 6.1 s), and its median too (5 to 24 ms
against 7 to 219 ms). The closed loop's latencies look better than they are: a client stalled by a long fsync sends
nothing meanwhile, so the writes that would have waited are never counted (coordinated omission).
Cepheus ran capped at 4 GB here: its merges still build the base in memory (peaks of 0.3 to 2.4 GB in these runs).

### Larger than memory

Cepheus with a cache of 32 MB (`CACHE_MB=32`), PostgreSQL with shared_buffers 32 MB (`SHARED=32MB`, work_mem 64 MB
as above), each process capped at 128 MB with no swap; the database is 245 MB (Cepheus' snapshot) and 284 MB
(PostgreSQL's data directory). 5 runs a question (Q5: 1, after one to warm up); the same answers on both sides.

| question | Cepheus, 1 core | PostgreSQL, 1 process | Cepheus, 3 domains | PostgreSQL, 3 processes |
|---|---:|---:|---:|---:|
| open | 67 ms, 64 MB resident (1,313 pages read: the offset tables) | | | |
| Q1 an invoice by id | **41 µs** [41, 42] | 176 µs (engine); 1.18 ms (socket) | 41 µs | 177 µs; 1.23 ms |
| Q2 a client by e-mail | **1.8 µs** | 5.5 µs; 25 µs | 1.7 µs | 5.4 µs; 27 µs |
| Q3 unpaid of a city (a different city each call) | **89 ms** [88, 91] | 446 ms (socket, random city) | 88 ms | 326 ms |
| Q4 unpaid sum per city | **385 ms** [384, 386] | 697 ms [695, 707] | **247 ms** [223, 251] | 658 ms [620, 790] |
| Q5 triangles | 102 s | **1.05 s** [1.04, 1.13] | 198 s | the server was killed by the cap |
| peak resident memory | 79 MB | | 105 MB | |

Q1 to Q4 read 3.9 M pages from the disk (each checked against its CRC). PostgreSQL's Q3 "engine only" repeats one city
(7.8 ms once its pages are in its buffers), so its socket time, with a random city as Cepheus', is the one compared.
With 2 parallel workers, PostgreSQL's server was killed by the 128 MB cap during Q5 (each worker may take work_mem,
64 MB, for its hash joins). Q5 is where Cepheus loses, by a factor of 100: its rows are ordered by thing, so a client's
follow links lie among the rows of its 20 invoices, and the triangle question reads random pages of 120 MB of by-thing
rows for a few bytes each (18.8 M pages read in 6 runs with a 48 MB cache); PostgreSQL keeps `follows` in a table of
its own (23 MB with its index), which fits in its 32 MB. A third order of Cepheus' rows (property, thing) would make
that local (theory, section 7). On 3 domains Q5 is slower than on 1: the misses are read one at a time under the
cache's lock.

### Where a write's time goes (256 clients, step 4)

5 rounds of 10 s (c67e52d): 15,775 to 19,009 groups a second (median 18,553; PostgreSQL 13,092 to 19,627, median
18,048). A client's p99 (40 to 62 ms) is about twice the journal's fsync p99 (19 to 30 ms): a frame waits for the one
being forced, then for its own fsync. The writer's work is small (p99 3.2 to 4.0 ms a batch); GC: about 1,500 minor
and 10 to 22 major collections in 10 s. The p99.9 (305 to 930 ms) follows the disk's fsync stalls (p99.9 188 to 434
ms, max 287 to 529 ms), which a loop of fsyncs alone shows too (operations, Disks). The rounds of milestone 1 with
p99 of 170 to 460 ms were these stalls.

## Milestone 1 at 10 million facts (old method: min and median of 5 rounds, best of 3 for writes)

| question | Cepheus | PostgreSQL, engine only | PostgreSQL, through its socket |
|---|---:|---:|---:|
| Q1 every fact of an invoice, by id | **0.35 µs** | 4.7 µs | 25 µs |
| Q2 a client by e-mail (unique) | **1.6 µs** | 5.6 µs | 25 µs |
| Q3 unpaid invoices of a city's clients (3 patterns, 4,299 rows) | **3.1 ms** | 14.5 ms | 15 ms |
| Q4 unpaid sum per city (4 patterns, 453,866 invoices, grouped) | 198 ms | **110 ms** (3 processes); 236 ms on one core | |
| Q5 triangles of the follow graph (cyclic, 568 k links) | 968 ms | **600 ms** (3 processes); 1,000 ms on one core | |

At 1 million facts: Q1 0.25 µs against 4.5 µs; Q2 0.96 µs against 4.9 µs; Q3 0.27 ms against 1.0 ms; Q4 18 ms
against 22 ms; Q5 63 ms against 50 ms.

| durable writes, groups a second | 1 client | 8 | 64 | 256 |
|---|---:|---:|---:|---:|
| Cepheus, best of 3 | 308 | 1,177 | 9,657 | 16,277 |
| PostgreSQL, best of 3 | 237 | 1,059 | 7,078 | 21,348 |
| Cepheus, median of 3 | 225 | 671 | 5,916 | 4,746 |
| PostgreSQL, median of 3 | 218 | 988 | 6,527 | 19,638 |
| Cepheus groups a frame | 1 | 4 | 32 | 119 |

| other | Cepheus | PostgreSQL |
|---|---:|---:|
| load 10 M facts | 89.5 s through the writer (112,000 facts/s), snapshot 4.7 s | `COPY`, indexes, `VACUUM ANALYZE`: about 1 min |
| open after a restart (snapshot verified) | 472 ms | (server start not compared) |
| memory after open / size on disk | 312 MB resident; journal and 2 snapshots on disk | 740 MB data directory |
| recovery after kill -9 (40 kills, small database) | median 6 ms, max 13.5 ms | |

### What the numbers said then

- **Point lookups and selective joins: Cepheus is 3 to 70 times faster.** A thing's facts are two array reads away
  (dense ids); a question runs in the application's process with no round trip and no plan cache to consult. Through
  the socket, which is what an application of PostgreSQL pays, the gap is 15 to 70 times.
- **Large scans and aggregates (Q4) and the triangle query (Q5): PostgreSQL is faster, because it uses three processes
  for one query.** On one core it is 1.2 times slower than Cepheus on Q4 and even on Q5. Cepheus answers a question on
  one core today; parallel questions (OCaml domains over a view, which needs no lock) are the next step. Q5's graph is
  uniform (5 links a client), where joins two at a time stay small; Generic Join's advantage shows on skewed graphs,
  not measured yet. Sorted intersection of the candidate lists (Leapfrog style) would also cut Q5's lookups.
- **Durable writes: on par.** Both are bounded by the disk's fsync rate times the frame size, as the group commit
  formula says (theory, section 2). Cepheus is ahead from 1 to 64 clients in the best rounds; PostgreSQL is ahead at
  256. Two causes on the Cepheus side: compaction is synchronous (a pause of up to 0.6 s every few seconds under heavy
  writes: the p99 latencies of 300 to 600 ms), and the 256 client threads share one OCaml domain. Background merges in
  levels (the LSM plan) remove the first. The medians show how noisy the shared disk was during these runs.
- **Recovery** is fast because the journal after the newest snapshot is short; a snapshot at 10 M facts takes 4.7 s
  to write and 0.47 s to verify and map at open.

## Not measured yet

Several databases writing at once, a server-class disk, skewed graphs, replication; SQLite's reads larger than memory
(its durable writes: one transaction a client at 1 M facts, [loading](#loading)); Oracle, Datomic, RocksDB, Neo4j, FoundationDB and CockroachDB, which are not installed on the
test machine (compared by design on the [comparison](comparison.md) page).
