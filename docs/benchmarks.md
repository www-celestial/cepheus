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
| `bench.exe crc` | CRC-32C alone on 24 bytes, 4 KiB, 16 KiB, 1 MiB and 96 MiB from an odd offset: the time of a call and MB/s, median and 95 % interval over `RUNS` runs |
| `bench/pg/pg.sh init\|start\|load\|read\|write\|stop ROOT ...` | PostgreSQL's side on a cluster of its own (`ROOT/data`, port 5544): `start ROOT MEM` caps the server's memory (`SHARED=32MB` sets `shared_buffers`), `read ROOT NCLIENTS` (`WORKERS=k` parallel workers a query, `QS`, `RUNS`), `write ROOT NCLIENTS CLIENTS SECS` (`RATE=r`: open loop) |
| `bench/sqlite/sqlite.sh load\|read ROOT ...` | SQLite's side, one file `ROOT/bench.db`: `load ROOT CSVDIR`, `read ROOT NCLIENTS` (`QS`, `RUNS`, `CACHE_MB`) |
| `test/seats.exe DIR 0 SEED naive\|expect SEATS` | the sale of seats of the [case](case-seats.md): `BUYERS` threads sell out a hall of SEATS seats, the time and what went wrong |
| `bench/sqlite/seats.py FILE immediate\|naive SEATS BUYERS` | the same sale on SQLite (Python's `sqlite3`, WAL, `synchronous = FULL`) |
| `bench/pg/pg.sh seats ROOT serializable\|naive SEATS BUYERS` | the same sale on PostgreSQL (pgbench, `--max-tries=1000`, the scripts `bench/pg/seat-*.sql`) |

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

## Live questions (2026-11-11), at 1 million facts

`cepheus.Watch` and `Watch` on the wire, against main before them (the commit of the column order), on the server's
database of 1 M facts, each side on a server started from the same copy of it, n = 7 rounds alternated (method above).
The whole tables are in [server](server.md#what-a-watch-costs) and [Cesia](cesia.md#what-it-costs).

| | before | after | the ratio within each round, after / before |
|---|---:|---:|---:|
| the server's start (ready), ms | 174 [122, 847] | 143 [126, 178] | 0.91 [0.15, 1.09] |
| an empty round trip (Ping), µs | 8.86 [7.55, 11.13] | 9.40 [7.93, 11.47] | 0.93 [0.76, 1.50] |
| a point read at the server (Get), µs | 8.79 [7.64, 12.27] | 8.85 [7.70, 9.49] | 1.00 [0.64, 1.16] |

A program that uses the package without calling it (`cesia run` of `io.Print(1)` with the package's `use`, n = 51
alternated): 3.53 ms [3.48, 3.59] before, 3.66 [3.60, 3.75] after: the package's Cesia code is 41 lines longer (`Watch`
and `Close` of a watch), which Cesia reads and compiles at the start, 0.13 ms more. The engine still loads only at the
first call.

Nothing that was there before costs more. What is new: a change reaches a program 16 µs after its write's receipt at
the server, and before the receipt in the program's follower; a group costs the hub 12.2 µs at 10,000 watching screens
and a dashboard; a connection that never reads holds nobody; 100 watches cost 16 writers nothing measurable, where
PostgreSQL's `NOTIFY` divides them by 8.6; one Cesia program gives a change to 10,000 fibers in 90 ms (the last one).

## The column order and leapfrog intersections (2026-11-11), at 10 million facts

Step 3 of the plan to beat the giants: run format 8 adds a third order to each part of a run, the **column order**
(each property's rows apart, in thing order: vertical partitioning, Abadi et al. 2007), read by every lookup of a
thing's property; questions intersect two sorted slices of a level by **leapfrogging** (Veldhuizen 2014) instead of a
lookup per candidate, read a one-valued property of a bound thing as its one value, and leave to the next level the
checks it makes ([formats](formats.md#run-dirsnapshotslo-20-digits-hi-20-digitsrun),
[theory](theory.md#4-generic-join)). The journal's format is unchanged; a database of format 7 replays its journal
once at its first open (5.2 s at 10 M facts) and gives the same answers (checked on a database written by main's
binary: Q3 4,299 rows, Q4 453,866 invoices summing 22,677,088,830, Q5 114 rotations).

**Method.** main d747635 against the branch (its final state: 43afeac with the columns' domain of that commit
taken out again, below), both built in release, the same benchmark client, alternated (A then B, then B then A) in one
hold of the heavy lock, 7 rounds, every process in a 3 GB scope; a cell is the median of 7 rounds with its 95 %
interval by order statistics (for 7 runs, the smallest and the largest: coverage 98.4 %); the last column pairs the
rounds (the median of the ratios, how many rounds the branch was the larger, a two-sided sign test). Questions: 11
runs each in each process, on up to 8 domains and on 1. Load average 1.8 to 2.7 (the machine was shared).

| 10 M facts | main d747635 | branch | branch / main, by round |
|---|---:|---:|---|
| load in 2 large groups, to confirm every group | 3.86 s [3.33, 5.80] | 3.93 s [3.71, 4.33] | 1.005 (p = 1.0: no difference shown) |
| load in 4 large groups (`GROUP=56818`) | 5.62 s [4.83, 6.16] | 5.75 s [5.04, 7.14] | 0.967 (p = 1.0) |
| a large group merged into a run (the longest) | 1.13 s [1.10, 1.39] | 1.33 s [1.31, 1.48] | 1.173, slower 6 of 7 (p = 0.13) |
| peak resident memory, 2 groups | 1,599 MB | 1,590 MB | 0.994 |
| peak resident memory, 4 groups | 953 MB [860, 1,130] | 911 MB [872, 994] | 0.956 (p = 0.45) |
| the runs after `snapshot` (one run) | 54.4 MB | 69.6 MB | 1.280: +15.2 MB (the column order 13.9 MB) |
| the journal | 21.8 MB | 21.8 MB | the same |
| `snapshot` (a full merge) | 1.65 s [1.53, 1.83] | 2.00 s [1.90, 2.46] | 1.242, slower 7 of 7 (p = 0.016) |
| open of the database it leaves | 54.0 ms [51.5, 58.3] | **46.1 ms** [38.7, 52.1] | 0.795, faster 6 of 7 (p = 0.13) |
| Q1 an invoice by id | 0.44 µs [0.40, 0.46] | 0.46 µs [0.39, 0.61] | 1.095 (p = 1.0) |
| Q2 a client by e-mail | 0.74 µs [0.67, 0.80] | 0.69 µs [0.63, 0.80] | 0.940 (p = 0.45) |
| Q3 unpaid invoices of a city | 4.28 ms [4.13, 4.44] | **2.92 ms** [2.84, 3.24] | 0.688, faster 7 of 7 (p = 0.016) |
| Q4 unpaid sum by city, 8 domains | 88.7 ms [84.9, 104] | **44.0 ms** [42.6, 44.5] | 0.500, faster 7 of 7 |
| Q5 triangles, 8 domains | 294 ms [266, 325] | **68.5 ms** [64.2, 87.9] | 0.233, faster 7 of 7 |
| Q4, 1 domain | 253 ms [248, 285] | **131 ms** [129, 133] | 0.518, faster 7 of 7 |
| Q5, 1 domain | 1.18 s [1.15, 1.28] | **0.271 s** [0.256, 0.297] | 0.224, faster 7 of 7 |
| 1 M facts, a group a client, 64 threads | 8.01 s [7.64, 9.24] | 8.06 s [7.27, 9.92] | 1.006 (p = 1.0) |
| its peak | 200 MB [175, 222] | 212 MB [194, 224] | 1.053, larger 6 of 7 (p = 0.13) |

**The columns' domain, tried and taken out.** The columns are written by the merge's pass by thing; they cost about
20 ns a row (the large group's merge +0.2 s, a full merge +0.35 s). Filling them on a domain of their own beside the
pass (its rows handed in chunks) brought the large group's merge back to main's 1.11 s, but the 4-group load's peak
rose from 906 to 1,190 MB in 6 rounds of 7: OCaml 5 completed fewer major collections (9 against 14, the heap's top
45 M words higher) whenever a helper domain lived beside the pass, idle on a condition, spinning, or doing major
slices of its own (measured each way). So the pass fills them itself; the load's time shows no difference.

**Where the reads' time went.** A lookup of one property of a thing reads its column: a rank word, a directory
entry and a field (20 ns for a count, 42 ns for a value, on sorted invoices; 46 to 61 ns in a thing's block before).
Q5 was five membership lookups an edge at random places of the 200 MB of thing blocks (step 2's profile: 35 % of its
time); it is now two reads of a few contiguous rows (an out-list of the 1.6 MB column of `follows`, an in-list of the
rows by value, read once for every b that a follows) and a merge of two lists of about five: 0.26 s on one domain.
Q4 reads an invoice's client, the client's city and the invoice's total as three single values, and leaves the check
"has a client" to the next level. Of Q4's 129 ms, 29 ms are the benchmark's own fold (an OCaml `Hashtbl` updated with
a fresh tuple for each of the 453,866 invoices, measured alone): the plan's target of 40 ms on one core is out of
reach while the question is written so; the engine's part is about 100 ms (220 ns an invoice). The open checks a
run's pages on up to 4 domains: 20 % faster than main although the run has 28 % more pages.

**What got worse.** The run grows by 15.2 MB (13.9 MB of column order: values 11.4, rank tables 1.2, directories
1.25), 1.2 MB above the plan's budget of 14. A full merge takes 24 % longer (the third order is written in the pass
by thing). A merge holds one bit a thing a property until its pass ends (2.4 MB at 10 M facts). A cold open of a run
larger than the cache reads the column order's tables (below).

**Beside SQLite 3.54.** The same CSV files; a Cepheus load (two large groups) and a SQLite load (`.import`, indexes,
ANALYZE, WAL, synchronous FULL) in turn, 7 rounds, then Q1-Q5 resident, 11 runs each, a process of each in turn,
7 rounds (Cepheus on one domain, on its snapshot's one run). This series and the two below ran 43afeac (the columns'
domain in, which changes neither the reads nor the load's time).

| 10 M facts, one core | Cepheus, format 8 | SQLite 3.54 | who wins |
|---|---:|---:|---|
| load, to durable | **3.96 s** [3.59, 5.85] | 7.98 s [6.48, 8.86] | Cepheus, 2.0 times |
| on disk after the load (journal and runs) | **90.5 MB** | 136.4 MB | Cepheus, 1.5 times smaller (with its whole history) |
| peak memory of the load | 1,591 MB | **11 MB** | SQLite, 145 times (one group of 9.4 M facts in memory) |
| Q1 an invoice by id | **0.39 µs** [0.38, 0.42] | 0.69 µs [0.68, 0.73] | Cepheus, 1.8 times |
| Q2 a client by e-mail | **0.64 µs** [0.61, 0.71] | 1.42 µs [1.36, 1.55] | Cepheus, 2.2 times |
| Q3 unpaid of a city | **2.87 ms** [2.76, 3.12] | 4.18 ms [4.05, 4.43] | Cepheus, 1.5 times |
| Q4 unpaid sum by city | **130 ms** [125, 136] | 369 ms [353, 387] | Cepheus, 2.8 times |
| Q5 triangles | **256 ms** [244, 331] | 1.05 s [1.03, 1.10] | Cepheus, 4.1 times |

**Beside PostgreSQL 18.6, on several cores.** Q4 and Q5 at 1, 2, 3, 4 and 8 domains (Cepheus, 11 runs each, 5
rounds) and PostgreSQL with 0 to 3 parallel workers (1 to 4 processes, `max_parallel_workers_per_gather`), inside
the server (`EXPLAIN ANALYZE`'s execution time: no socket), 11 runs each, 5 rounds, on a cluster of the job's own
(COPY, indexes, ANALYZE, fsync on: 707 MB of data), deleted at the end. A cell: the median of the rounds' medians
[the smallest, the largest] (93.8 %).

| | 1 core | 2 | 3 | 4 | 8 |
|---|---:|---:|---:|---:|---:|
| Q4, Cepheus format 8 | **128 ms** [124, 130] | **81.6** [75.2, 83.0] | **57.8** [57.0, 60.1] | **47.8** [44.4, 51.0] | **42.4** [42.4, 45.1] |
| Q4, Cepheus main | 244 [242, 250] | 156 [154, 159] | 109 [106, 121] | 92.4 [86.0, 102] | 85.3 [84.1, 181] |
| Q4, PostgreSQL (processes) | 233 [230, 254] | 141 [140, 146] | 107 [106, 111] | 87.7 [87.2, 92.5] | |
| Q5, Cepheus format 8 | **250 ms** [248, 253] | **149** [146, 154] | **100** [98.9, 108] | **77.3** [74.8, 83.2] | **66.3** [63.9, 75.5] |
| Q5, Cepheus main | 1,140 [1,120, 1,170] | 592 [572, 597] | 409 [406, 447] | 354 [322, 412] | 280 [262, 310] |
| Q5, PostgreSQL (processes) | 1,010 [996, 1,070] | 604 [600, 625] | 602 [599, 629] | 616 [600, 635] | |

PostgreSQL launches one worker at most for Q5 (its plan has one parallel scan), so its Q5 stops at 2 processes;
its Q4 scales to 4 (87.7 ms) where Cepheus takes 47.8 ms on 4 domains. Main lost to PostgreSQL on Q4 at 2 to 4
processes; format 8 wins at every count, by 1.8 times on Q4 and 4 to 8 times on Q5.

**Larger than memory.** Each process capped at 128 MB, 32 MB caches, the files' pages dropped from the kernel's page
cache before each side (all start cold), sides in turn, 5 rounds, 5 runs a question (a cell: the median of the
rounds' medians [the smallest, the largest], 93.8 %). Main's Q5 is from the series of 2026-11-09 (the same format 7).

| 128 MB cap, cold | format 8, 1 domain | format 8, 3 domains | main, 1 domain | SQLite 3.54 |
|---|---:|---:|---:|---:|
| open | 138 ms [117, 161] | 161 ms [124, 170] | **88.2 ms** [75.8, 91.3] | (a file) |
| Q1 an invoice by id | 0.44 µs [0.42, 0.61] | **0.42 µs** [0.38, 0.44] | 0.47 µs [0.39, 0.67] | 2.89 µs [0.87, 6.40] |
| Q2 a client by e-mail | 0.69 µs [0.69, 0.78] | **0.66 µs** [0.61, 0.70] | 0.70 µs [0.70, 0.75] | 1.48 µs [1.41, 1.63] |
| Q3 unpaid of a city | 3.13 ms [2.96, 3.50] | **2.97 ms** [2.88, 3.19] | 4.29 ms [4.10, 4.36] | 112 ms [105, 136] |
| Q4 unpaid sum by city | 129 ms [126, 133] | **58.9 ms** [56.7, 64.6] | 249 ms [244, 266] | 552 ms [469, 592] |
| Q5 triangles | 263 ms [241, 279] | **114 ms** [113, 127] | 1.10 s | 1.14 s [1.10, 1.21] |

At 48 MB (16 MB caches), where neither file fits, format 8's triangles take **260 ms** [249, 274] on 1 domain and
**113 ms** [105, 119] on 3 (5 runs, cold), against more than 2.5 minutes a run for format 7 and 1.02 s for SQLite
(2026-11-09): the question reads the column of `follows` (1.6 MB) and its rows by value, not the thing blocks where
its rows sat among the invoices. The run of 69.6 MB still fits under 128 MB beside the cache, so the questions read
as resident there. The cold open is slower than main's (138 ms against 88): a run larger than the cache is not read
whole, and the open's checks of the column order (rank tables, directories: 2.5 MB) read pages that main's open did
not (the first questions would read them anyway).

**Where the giants still win.** SQLite loads in 11 MB of memory against 1.6 GB (chunked loads are step 4). Its cold
open is a file open. PostgreSQL does not win a question here any more; it is a server with its own processes, which
Cepheus' numbers above do not include (Cepheus' server is measured in [server](server.md)).

## Compressed runs and journal (2026-11-09), at 10 million facts

Step 2 of the plan to beat the giants: run format 7 (every section coded by a frame of reference in blocks of 128; in
the thing blocks a record a thing for its one-valued properties and columns for the others; rows by property with
their things by gaps where shorter; a value index for links, texts, dates and small ints; a hash table of the texts;
only the written pages in the file, with a page table) and journal format 2 (each group in columns)
([formats](formats.md), [theory](theory.md#11-compressed-runs-and-journal-the-coding-and-its-bound)).

**Method.** main 0ecc09e against the branch (b96c7e0, main d23a222 merged in), both built in release, the same
benchmark client, alternated (A then B, then B then A) in one hold of the heavy lock, 7 rounds, every process in a
3 GB scope; a cell is the median of 7 rounds with its 95 % interval by order statistics
(for 7 runs, the smallest and the largest: coverage 98.4 %); the last column pairs the rounds (the median of the
ratios, how many rounds the branch was the larger, a two-sided sign test). Questions: 11 runs each in each process,
on up to 8 domains and on 1; a cell is the median of the 7 rounds' medians. Sizes are bytes of the files (`du -b`).
The machine was shared with other jobs (load average 1.2 to 2.2).

| 10 M facts | main 0ecc09e | branch | branch / main, by round |
|---|---:|---:|---|
| load in 2 large groups, to confirm every group | 4.26 s [3.82, 4.62] | **3.44 s** [3.32, 4.48] | 0.855, faster 7 of 7 (p = 0.016) |
| load in 4 large groups (`GROUP=56818`) | 5.74 s [5.22, 8.70] | **4.64 s** [4.42, 6.32] | 0.803, faster 6 of 7 (p = 0.13) |
| peak resident memory, 2 groups | 1,460 MB | 1,600 MB | 1.096 (the frame coded in memory, 21.6 MB, and the coder's buffers) |
| peak resident memory, 4 groups | 1,196 MB [860, 1,389] | **984 MB** [878, 1,080] | 0.804 |
| the journal | 99.6 MB | **21.8 MB** | 0.219 |
| the runs after `snapshot` (one run) | 246.4 MB | **54.4 MB** | 0.221 |
| journal and runs after `snapshot` | 346.1 MB | **76.2 MB** | 0.220 |
| `snapshot` (a full merge) | 1.99 s [1.51, 2.70] | 1.62 s [1.54, 2.64] | 0.811 (p = 0.45) |
| open of the database it leaves | 197 ms [194, 240] | **53.5 ms** [52.8, 54.3] | 0.271, faster 7 of 7 |
| Q1 an invoice by id | 0.36 µs [0.34, 0.40] | 0.38 µs [0.36, 0.39] | 1.056 (p = 0.45: no difference shown) |
| Q2 a client by e-mail | 1.58 µs [1.53, 1.64] | **0.65 µs** [0.64, 0.66] | 0.411, faster 7 of 7 |
| Q3 unpaid invoices of a city | **3.59 ms** [3.56, 3.78] | 3.97 ms [3.92, 4.01] | 1.095, slower 7 of 7 |
| Q4 unpaid sum by city, 8 domains | **79.9 ms** [78.8, 80.6] | 82.4 ms [81.9, 83.0] | 1.031, slower 7 of 7 |
| Q5 triangles, 8 domains | **248 ms** [243, 257] | 264 ms [262, 266] | 1.072, slower 7 of 7 |
| Q4, 1 domain | **231 ms** [230, 236] | 241 ms [239, 243] | 1.038, slower 7 of 7 |
| Q5, 1 domain | **1.02 s** [0.98, 1.05] | 1.10 s [1.07, 1.14] | 1.098, slower 7 of 7 |
| 1 M facts, a group a client, 64 threads | 8.25 s [7.94, 9.10] | 7.93 s [7.23, 9.05] | 0.962 (p = 0.45: the same) |
| its peak | 235 MB | 204 MB | 0.834 |

**Where the load's time goes now.** The large group's coding for the journal takes 0.64 s on its domain (0.89 s
before, the change-by-change coding written by pieces) and its merge 1.07 s (0.35 s before: the blocks are coded as
they fill, about 100 ns a fact), side by side; then fsyncs of 21.6 MB of frame and 54 MB of run instead of 94 and
234 MB. The disk work that dominated step 1 shrank about 4.5 times; the merge's coding is now the longest part, a
single domain's work (its two passes, by thing and by property, could go to two domains: the next lever).

**The reads.** The order by property became faster where a value index replaces a binary search (Q2: 2.4 times),
and an open reads 4.6 times fewer bytes. A lookup by thing costs a little more than format 6's: on consecutive
invoices (the joins' pattern) 46 to 61 ns against 37 to 41 (`count_values` 49, `mem` 61, `iter_values` 58 ns; the
block's header is read and the property's entry found among the block's before its field), so Q3, Q4 and Q5, made of
such lookups, stay a little slower; the planner no longer counts a one-valued property of a bound thing (one lookup
of two saved). Two layouts were measured before this one on the same data, one round each, one domain: a column a
property in each block (PAX: Q1 0.79 µs, Q3 4.8 ms, Q4 357 ms) and a record a thing holding every value with a
count a property (Q1 0.43 µs, Q3 5.8 ms, Q4 316 ms, Q5 1.22 s; its 7-round series and the giants' are kept with the
job's raw outputs); the kept one, fields for the one-valued properties and columns for the others, read Q1 in
0.39 µs, Q3 in 3.9 ms, Q4 in 241 ms ([theory](theory.md#11-compressed-runs-and-journal-the-coding-and-its-bound)).

**Beside SQLite 3.54 and PostgreSQL 18.6.** The same CSV files; a Cepheus load and a SQLite load in turn, 7 rounds,
then Q1-Q5 resident, 11 runs each, a process of each in turn, 7 rounds, all under one hold of the lock (Cepheus on one
domain, on its snapshot's one run; SQLite in WAL mode with synchronous FULL, its indexes on every searched column).
PostgreSQL ran in the same way an hour before, alternated with the variant of format 7 measured first (records with
counts), on a cluster of the job's own, fsync on, deleted at the end.

| 10 M facts | Cepheus (branch) | SQLite 3.54 | PostgreSQL 18.6 |
|---|---:|---:|---:|
| load to durable | **3.45 s** [3.37, 3.75] | 7.22 s [6.83, 7.82] | 31.7 s [30.5, 34.4] |
| its peak resident memory | 1,600 MB (883 the client's list) | **11 MB** | |
| on disk after it | **74.7 MB** (journal 21.6, two runs 53.1) | 136.4 MB | 707 MB (284 tables and indexes, the rest WAL) |
| on disk with `snapshot` (one run) | **76.0 MB** (journal 21.6, run 54.4), the whole history included | 136.4 MB, no history | |
| Q1 an invoice by id | **0.38 µs** [0.37, 0.39] | 0.68 µs [0.68, 0.70] (engine) | 4.85 µs (in the server); 26 µs through its socket |
| Q2 a client by e-mail | **0.66 µs** [0.64, 0.68] | 1.37 µs [1.33, 1.42] | 5.69 µs; 26 µs |
| Q3 unpaid of a city | **3.97 ms** [3.91, 4.05] | 4.11 ms [4.06, 4.17] | 13.8 ms; 14.7 ms |
| Q4 unpaid sum by city | 240 ms [240, 245] | 356 ms [347, 362] | **108 ms** (3 processes) |
| Q5 triangles | 1.08 s [1.04, 1.12] | **1.03 s** [1.02, 1.05] | 596 ms (2 processes) |

Cepheus loads 2.1 times faster than SQLite and 9 times faster than PostgreSQL, and its state with the whole history
takes 0.56 times SQLite's file (which keeps no history); SQLite still loads in 11 MB of memory. On one core Cepheus
is faster on Q1 (1.8 times), Q2 (2.1), Q4 (1.5) and Q3 (1.04); SQLite on Q5 (1.05 times: nested loops over two
covering indexes do on this uniform graph the work of Generic Join, and its B-tree pages are read without decoding).
PostgreSQL's parallel plans (3 and 2 processes) win Q4 and Q5 against one domain; Cepheus on 8 domains takes 82 and
264 ms.

**Larger than memory.** Each process in a scope capped at 128 MB, a cache of 32 MB on each side (Cepheus' pages,
SQLite's `cache_size`), one domain; before each side the files' pages are dropped from the kernel's page cache
(`posix_fadvise(DONTNEED)`), so every side starts cold; the three sides in turn, their order turned each round,
7 rounds of 5 runs (Q5: once a side at the end, 3 runs, stopped after 10 minutes); a cell is the median of the 7
rounds with the smallest and the largest round.

| 10 M facts, 128 MB | Cepheus b96c7e0 | main 0ecc09e | SQLite 3.54 |
|---|---:|---:|---:|
| what is read | run 54.4 MB | run 246.4 MB | file 136.4 MB |
| open, cold | 109 ms [93, 115] | **86 ms** [86, 120] | |
| Q1 an invoice by id | **0.38 µs** [0.37, 0.40] | 70.8 µs [65.7, 79.3] | 0.87 µs [0.85, 5.38] |
| Q2 a client by e-mail | **0.65 µs** [0.65, 0.67] | 1.50 µs [1.43, 1.53] | 1.40 µs [1.33, 1.42] |
| Q3 unpaid of a city | **4.02 ms** [4.00, 4.06] | 542 ms [528, 550] | 97.5 ms [72.5, 110] |
| Q4 unpaid sum by city | **240 ms** [239, 243] | 483 ms [454, 501] | 496 ms [462, 577] |
| Q5 triangles | 1.10 s (one series) | more than 600 s (stopped) | **1.04 s** [1.02, 1.06] |

At 10 M facts the compressed run fits under the cap beside the process (16 MB after the open, the 32 MB cache): its
pages, read once from the disk, stay in the kernel's page cache within the scope, and the reads run as if resident.
Format 6's run, 4.5 times larger, does not fit: each miss of the cache goes to the SSD (Q3 135 times slower, Q5
stopped). SQLite's file does not fit either.

**The open, cold.** In the table above (b96c7e0) a cold open of the compressed run took 22 ms more than format 6's.
The cause: to see whether a segment was of format 1, the open read it through the recovery's window of 4 MiB, and the
scan read the window again at the start of the newest segment, which here holds the whole history (21.6 MB; format
6's newest segment held 5.5 MB). Both now read the segment's 40-byte header alone. Measured apart (the open only, 32 MB
caches, 128 MB scopes, 7 rounds, the three builds in turn, the files' pages dropped before each cold open):

| open of the 10 M-fact database | main 0ecc09e | b96c7e0 | 676676a |
|---|---:|---:|---:|
| cold | 85.5 ms [84.9, 86.8], 45.8 MB read | 104.2 ms [93.2, 139.2], 27.6 MB | **80.8 ms** [67.0, 84.0], 16.1 MB |
| warm (the files in the kernel's page cache) | 40.6 ms [40.4, 41.4] | 16.4 ms [15.1, 18.4] | **12.4 ms** [12.1, 13.4] |

676676a opens faster than main in each of the 7 rounds, cold and warm. With the default cache of 1 GiB an open of
main reads 205.6 MB from the disk where the branch reads 38.3 MB (438 ms against 126 ms, in fresh scopes).

**Smaller than both files.** The same set-up with each process capped at 48 MB and caches of 16 MB, Cepheus and
SQLite in turn, 7 rounds (Q5 for Cepheus once at the end, stopped after 10 minutes): neither the run (54.4 MB) nor
SQLite's file (136.4 MB) fits.

| 10 M facts, 48 MB | Cepheus b96c7e0 | SQLite 3.54 |
|---|---:|---:|
| open, cold | 103 ms [97, 109] | |
| Q1 an invoice by id | **23.3 µs** [20.8, 25.5] | 40.7 µs [38.4, 43.6] |
| Q2 a client by e-mail | **0.66 µs** [0.62, 0.70] | 1.37 µs [1.31, 1.57] |
| Q3 unpaid of a city | **82.5 ms** [79.0, 84.2] | 444 ms [434, 480] |
| Q4 unpaid sum by city | **300 ms** [283, 305] | 1.22 s [1.14, 1.27] |
| Q5 triangles | 4 runs not done in 10 minutes (more than 2.5 minutes a run) | **1.02 s** [1.02, 1.05] |

Cepheus is faster on Q1 to Q4 (1.7 to 5.4 times): its run is 2.5 times smaller than SQLite's file, so more of what a
question needs stays in the cache. SQLite wins Q5 by more than 100 times: it keeps the follow links in a table and a
covering index of their own (7.4 and 6.5 MB, `dbstat`), which fit in its 16 MB of cache, while Cepheus finds a client's
links in its thing block, among the records of the invoices numbered after it (a block of 128 things holds about 6
clients and 122 invoices), so the triangles touch the 23.5 MB of thing blocks at random. Reading Q5 from the rows
by property, where the 568,163 follow links lie together, is step 3 of the plan (the column order and a join that
walks them, [theory](theory.md#12-what-comes-next-and-why)).

The series before this one (milestone 2 and the levels, below) did not drop the files' pages, and their numbers are
not comparable with these. The kernel charges a page of its page cache to the control group that read it first, and
leaves it there ("A memory area is charged to the cgroup which instantiated it and stays charged to the cgroup until
the area is released", [Linux cgroup v2](references.md#buffer-management-and-caching)), so pages read before a
measure, by the load or an earlier run, could stay in memory outside the 128 MB of the scope that measured: the most
likely reason why the one-run database of the levels' series read Q3 in 85.8 ms and Q5 in 96.8 s, and main here in
542 ms and more than 10 minutes.

**Local readers and writes through the server** (1 M facts, the server of each build in turn, started and stopped
for each round, each round from a copy of the database as its load left it, 7 rounds; [server](server.md)):

| 1 M facts | main 0ecc09e | branch | |
|---|---:|---:|---|
| 8 local readers, each having read every invoice of the sample once: Pss in all | 252.4 MB [251.5, 253.0] | **106.5 MB** [105.6, 107.1] | 0.42: each reader's copy of the run pages shrank with the runs (24.7 MB against 5.7 MB) |
| their RSS in all | 290.8 MB [290.2, 291.1] | **144.3 MB** [144.0, 144.6] | |
| one local reader while 256 clients write: CPU | 34.9 % of a core [29.2, 38.5] | 35.9 % [22.8, 43.9] | no difference shown |
| its Pss meanwhile | 180.7 MB [167.6, 195.5] | **108.8 MB** [101.0, 119.8] | |
| 256 clients writing durable groups of 4 facts through the socket, no reader | 18,992 groups/s [15,989, 24,534] | 19,330 [8,290, 22,152] | the same at the median; two rounds of the branch fell to 8,290 and 8,858 with a p99 of 375 and 836 ms |
| the same in the process (`bench write`, 9 s, 3 merges each) | 19,047 [16,283, 22,389] | 20,119 [16,664, 22,136] | 1.02 by round, slower in 3 of 7: the same; a background merge 169 ms at the median on both |
| its peak resident memory | 205 MB | **143 MB** | |

The two slow rounds through the socket did not repeat in the process, where the merges and the writer's waits are
timed: the longest wait for a merge switch was 413 ms on main and 447 ms on the branch, once each in 7 rounds, on a
disk whose fsyncs vary that much from round to round.

## Rules (2026-11-08)

The first step of the reasoner ([rules](rules.md)): Datalog rules kept by the writer, semi-naive evaluation for
additions, Backward/Forward for retractions, `why` on demand.

**Method.** `bench/reason.exe` (release build): LUBM-shaped data (Guo, Pan, Heflin [Guo 2005]: universities,
departments, people, courses, publications, generated from the published ranges of the UBA generator; not its
official output) with the univ-bench ontology as 94 rules, one an axiom (39 subclass, 21 domain, 18 range, 5
subproperty, 4 inverse, 1 transitive, 6 for the defined classes). Ten universities: 1,354,654 asserted facts, 532,205
derived, 2,024,788 derivations (3.8 a derived fact): the derived facts and the derivations of the design's prototype, exactly. A student: a graduate
student's 10 facts in one group, 6 facts derived (3 types, the department's member, a degree, the university's
alumnus), then the same 10 retracted in one group; 2,000 of each, on a fork of the view of a database of one
university merged into one run (a fork never merges: written to with the whole load, its persistent maps would hold
every fact). The same groups without rules on main 85e72ac's binary and on this one (the same benchmark source), for
the write path without rules. Seven rounds, alternated, in one hold of the heavy lock, every process in a 3 GB scope;
a cell is the median of the rounds with the interval [x(1), x(7)] (98.4 %). Commands:
`reason.exe student 1 2000 DIR`, `reason.exe why 1 2000 DIR`, `reason.exe mat 10 rules|none bulk DIR`,
`reason.exe apply 200000`.

| | rules | no rules | |
|---|---:|---:|---|
| write a student (median of 2,000 groups) | **23.1 µs** [21.9, 24.1] | 9.1 µs [9.1, 13.8] | 2.5× |
| retract it | **34.1 µs** [33.1, 54.8] | 6.9 µs [6.0, 9.1] | 4.9× |
| `why`: a type Person (a proof of 5 facts) / Employee (8) / Student (2) / Organization (2) / Faculty (7) | 1.9 / 2.1 / 1.2 / 3.1 / 2.1 µs | | |
| load 10 universities in one group, durable | 2.48 s [2.27, 5.13] | 1.20 s [1.04, 2.26] | |
| its reasoning | 1.030 s [1.003, 1.088]: 0.52 M derived/s | | |
| of which the working set's build (1.35 M facts indexed; another 7 rounds) | 0.581 s [0.550, 0.644] | | |
| the saturation alone (the same 7 rounds) | **1.036 M derived/s** [0.977, 1.053] | | |
| the same at one university (150,343 facts, 60,526 derived) | reasoning 0.100 s [0.099, 0.106]: 0.60 M derived/s | | |
| a department a group, in memory (the ordinary path), one university | reasoning 0.238 s [0.228, 0.276]: 0.25 M derived/s | | |
| a derived fact into a view whose delta holds 200,000 changes, 6 a thing | **0.83 µs** [0.82, 1.33] in sorted batches; 1.12 µs one by one | | |

| without rules, the same groups | main 85e72ac | this branch |
|---|---:|---:|
| write a student | 9.06 µs [9.06, 10.01] | 9.06 µs [9.06, 10.97] |
| retract it | 7.15 µs [6.20, 9.06] | 6.20 µs [5.96, 8.82] |
| load one university, a group a department, durable | 1.23 s [1.05, 1.98] | 1.25 s [0.86, 4.38] |
| `Store.apply` of a fact (main's function, the same test) | 1.16 µs [1.12, 1.37] | 1.14 µs [1.13, 1.21] |

**Start-up.** A program that links Cepheus and exits at once (`bench.exe` without arguments: every module initialised,
nothing else), main 85e72ac against this branch, 1,000 runs each, alternated, under the lock: 2.294 ms [2.279, 2.306]
against 2.313 ms [2.296, 2.330], the paired ratio 1.022 (95 % intervals by order statistics). The reasoner adds about
225 KB of code, and the OCaml runtime reads a binary's frame descriptors and the loader its relocations at start-up
(frame tables 821 KB → 942 KB, relocations 23,141 → 26,212): 2 % more. A first version, which let the compiler
(`-inline 200`) copy the store's lookups into every step of every plan, took 2.353 ms against 2.222 (+6 %); the
reasoner calls the store through functions it does not inline since.

The design's prototype (over hash tables of its own, the same data and rules) gave 0.96 M derived facts/s on one core
for the saturation of ten universities, 7.9 µs of reasoning for a student's write and 19.1 µs for its retraction:
the engine's saturation passes it (1.04 M/s); a student's write costs 23.1 µs in all (the store's work for its 10
asserted and 6 derived facts included), its retraction 34.1 µs, of which B/F's checks over the store's maps and runs
are the largest part. The design measured 3.9 to 5.1 µs for a derived fact put into the view, with a delta of 600,000
changes; at the database's merge threshold (200,000 changes) main's `Store.apply` takes 1.16 µs, and the sorted batch
0.83 µs.

**Beside the giants** (their papers; their machines and data; *computed*: ours, from their tables). RDFox (Motik et al.
[Motik 2014], LUBM-L 1K, 133.6 M → 182.4 M facts): 73 s on one thread of a 2.0 GHz Xeon E5-2650, 0.67 M derived/s
(computed), 7.0 M/s on 32 threads. VLog (Urbani et al. [Urbani 2016], the same data): 38 s on one thread of a 2.2 GHz
laptop, about 1.28 M derived/s (computed). Soufflé (Scholz et al. [Scholz 2016]): a points-to analysis of OpenJDK 7,
about 840 M tuples, 75 s sequential, 35 s on 4 cores (another workload). RDFox's B/F (Motik et al. [Motik 2015]):
100 deletions on LUBM-1k-L in "0.0 s". Read plainly: at one core, Cepheus' saturation is at RDFox 2014's rate and
behind VLog's by 1.2×; with the indexing of a load's facts counted, behind VLog by 2.5×; in parallel, not measured
yet (RDFox scales to 32 threads); small writes cost microseconds, which no giant publishes.

## The load in parallel and without copies (2026-11-08), at 10 million facts

Step 1 of the plan to beat the giants at loading: a large group is mapped by four domains into compact arrays, numbered
in one pass, sorted there (not at all when it comes in thing order), and merged into its run while another domain
writes its frame's body to the journal, forced as it goes; the run is forced beside the frame's last fsync and is not
copied into the cache; the receipt is made beside the merge ([architecture](architecture.md#large-groups)). With it: no
run kept outside the chain after a merge, and a question counts once the patterns that no binding changes.

**Method.** main eb120a4's engine against the branch, both built in release, with the same benchmark client, alternated
(A then B, then B then A) in one hold of the heavy lock, 7 rounds, every process in a 3 GB scope; the load average
before each side is kept with the raw outputs. The client reads its new ids off the receipt by arithmetic now, not
through a hash table of its 2.4 M pairs, so both sides do the same, smaller client work (0.7 s less between the two
groups; with the old client, main measured 7.04 s in the section below). A cell is the median of 7 rounds with its 95 %
interval by order statistics (for 7 runs, the smallest and the largest: coverage 98.4 %); the last column pairs the
rounds (the median of the ratios, how many rounds the branch was faster, a two-sided sign test). The questions ran on
up to 8 domains (the default), 21 runs each in each process: a cell is the median of the 7 rounds' medians.

| 10 M facts | main eb120a4 | branch | branch / main, by round |
|---|---:|---:|---|
| load in 2 large groups (9.4 M additions, then 568,163), to confirm every group | 6.18 s [5.65, 7.41] | **4.14 s** [3.67, 4.86] | 0.656 [0.645, 0.686], faster 7 of 7 (p = 0.016) |
| the same, a second series after the run's fsync went beside the frame's | 6.59 s [6.18, 9.31] | 4.65 s [3.96, 5.43] | 0.677 [0.566, 0.812], 7 of 7 |
| peak resident memory of that load | 2,595 MB [2,527, 2,620] | **1,461 MB** [1,461, 1,462] | 0.563 |
| of which the client's own list of operations, once built | 883 MB | 883 MB | |
| a large group resolved and sorted (the longest of the two) | 1.94 s | 0.64 s (0.59 in the second series) | 0.328 |
| a large group merged into its run (the second series: without its fsync, now beside the frame's) | 1.57 s (1.76) | 1.59 s (0.32) | |
| load in 4 large groups (`GROUP=56818`) | 7.62 s [7.14, 11.17] | 5.74 s [5.20, 6.50] | 0.706 [0.540, 0.849], 7 of 7 |
| its peak | 2,167 MB | 1,184 MB | 0.616 |
| then `snapshot` | 1.45 s [1.28, 2.25] | 2.06 s [1.44, 2.55] | 1.258 [0.871, 1.747], slower 4 of 7 (p = 1.0: no difference shown) |
| on disk after it | 553 MB | **330 MB** | 0.597 |
| open of the database it leaves (one run) | 199 ms [197, 299] | 196 ms [194, 199] | 0.985 [0.648, 1.007] |
| Q1 an invoice by id | 0.37 µs | 0.36 µs | 1.000 |
| Q2 a client by e-mail | 1.56 µs | 1.56 µs | 1.013 |
| Q3 unpaid invoices of a city | 3.80 ms | 3.58 ms | 0.955 [0.939, 0.966], 7 of 7 |
| Q4 unpaid sum by city | 82.3 ms | 80.5 ms | 0.976, 7 of 7 |
| Q5 triangles | 252 ms | 245 ms | 0.970 |
| 1 M facts, a group a client, 64 threads | 8.40 s [7.19, 9.27] | 8.48 s [7.65, 10.84] | 0.947 [0.911, 1.258] (p = 1.0: the same) |
| its peak | 269 MB | 224 MB | 0.898 |

**Where a load's time goes now** (the writer's phases, one load on a quiet machine): the client builds its 9.4 M
operations in 1.3 s on 4 domains, its own work; the writer maps and sorts them in 0.59 to 0.64 s (one walk of the list
0.10 s, the mapping on 4 domains 0.10, the numbering of new things 0.06, of new texts 0.15, the rewrite with the final
numbers 0.02, the order by thing and the facts twice 0.02, by property 0.16 of which the radix sort on 2 domains with the
texts sorted beside 0.11, the encoded length 0.03); the merge writes the run in 0.32 s (by thing 0.19, by property 0.11,
the dictionary 0.02) while another domain encodes the frame and writes its 94 MB (0.7 to 0.8 s, forced every 32 MiB);
then the run's fsync (234 MB: 0.5 s on a quiet disk, 2.3 s on a busy one) beside the frame's last one (60 to 90 ms, where
main's was 270 ms); the follows' group 0.45 to 0.9 s. The disk is now the largest part: in the second series both sides
slowed round after round on a quiet machine (the branch 3.96 to 5.27 s, main 6.18 to 9.31 s). The plan's next steps
attack it: a coded run (step 2) writes about a fifth of the bytes.

**Where its memory goes** (resident memory at each phase, one load): the client's list 883 MB; mapped +141 MB (14 bytes
a fact); by property +108 MB (12 bytes a fact); the radix sort's room +53 MB; the receipt +127 MB (2.4 M pairs of a
list, the API's) to 1,354 MB; the follows' group starts before the collector has freed the first group's arrays: 1,455
MB at the peak. The engine's own share fell from about 1.7 GB to 0.57 GB. The `snapshot` after a load now reads the
runs of its large groups from their files, since they no longer enter the cache as they are written: 2.06 s against
1.45 s at the median, a difference the 7 rounds do not show (slower in 4 of 7).

**Against the targets of step 1.** The load in at most 4 s: met by the quietest runs (3.72 s and 3.96 s), not by the
medians (4.14 s and 4.65 s) of a disk that varies by half between rounds. A peak of at most 1.1 GB: not met, 1.46 GB, as
the client's own list measures 0.88 GB where the plan counted 0.7, and the receipt 0.12; loads in chunks (step 4) bound
both. On disk after `snapshot`: 330 MB (the plan said 319). Q3 at most 3 ms: not met, 3.58 ms: counting the city's
constant pattern once a question saved 5.8 %; most of the rest is a lookup per client and per invoice, which step 2's
offsets for links remove. The open, Q1 to Q5 and the load a group a client: no slower.

**Tried and left out, measured.** A full collection right after a large group's operations are let go, so that its
receipt would reuse their memory: 0.11 s a group, the peak unchanged (1,438 against 1,455 MB), and a pause of the whole
process that a server would feel. Starting the run's writeback during the merge with Linux's `sync_file_range` (a system
call OCaml's `Unix` lacks: a C stub in a test program, not in Cepheus): durable after 1.23 s against 1.84 s at the
median of 7 alternated rounds, 1.5 times, under the 2 times a C file must earn here, and step 2's coded runs shrink the
same wait. The three passes of the merge on three domains: they take 0.32 s of one core now, so at most 0.2 s to win,
for a page assembly shared between domains; not done.

**Beside SQLite 3.54 and PostgreSQL 18.6.** The same 10 M facts (the CSV files the benchmark writes), the same
durability as in the section below: a Cepheus group is confirmed after its frame's fsync; SQLite's `.import` is one
transaction a table in WAL mode with `synchronous = FULL`, then a checkpoint; PostgreSQL's `COPY` runs with fsync on,
then `VACUUM ANALYZE` and `CHECKPOINT`. Each giant alternated with the branch round by round, 7 rounds, 3 GB scopes
(PostgreSQL's server in its own scope), the medians with their 95 % intervals as above. The machine's load average was
1.4 to 3.5 during the SQLite series and 13.9 falling to 1.7 during the PostgreSQL one (other jobs ending), the same
for both sides of a round:

| 10 M facts | Cepheus (branch) | SQLite 3.54 | PostgreSQL 18.6 |
|---|---:|---:|---:|
| load, until durable | 5.61 s [4.21, 11.67] (beside SQLite); 5.13 s [4.65, 8.08] (beside PostgreSQL) | 9.37 s [7.90, 13.67] | 30.87 s [28.08, 37.13] |
| Cepheus / the giant, by round | | 0.600 [0.429, 0.923], Cepheus faster 7 of 7 (p = 0.016): SQLite takes 1.7 times as long | 0.168 [0.144, 0.288], 7 of 7: PostgreSQL takes 6 times as long |
| peak memory | 1.46 GB (0.88 of it the client's list) | **11 MB** | shared_buffers 1 GB and the backend |
| on disk after the load, after `snapshot` | 335 MB, 330 MB | **131 MB** | 284 MB (675 MB with its WAL) |
| 1 M facts, a transaction a client (3 rounds) | **13.2 s** [10.2, 15.2] (64 threads) | 174.0 s [170.0, 196.9] (one writer) | not measured (`COPY` is one transaction) |

In this series both Cepheus and SQLite took longer than in the A/B above (the disk was writing the giants' files
between Cepheus' rounds; one Cepheus round stalled 5.9 s in its follows' group, SQLite's own runs spread from 7.9 to
13.7 s), which is why each comparison pairs its rounds. At a transaction a client, group commit keeps Cepheus 13 times
ahead here (16 times in the section below: 10.6 against 166.7 s, on a quieter disk); the A/B shows that this path did
not change (8.40 against 8.48 s). **Where SQLite wins, and why**: memory, 11 MB against 1.46 GB, because `.import`
streams rows from the file into B-tree pages and sorts each index in about 2 MB, where a Cepheus group is one
transaction held whole (the caller's list, 26 bytes a fact of arrays, the receipt); loads in chunks (step 4 of the plan)
bound it. And disk, 131 against 330 MB: SQLite's records are variable-length, Cepheus' runs 8-byte words; the coded
run of step 2 aims at 50 MB.

## CRC-32C by the processor (2026-11-08)

The checksum of every frame and every page was computed by tables in OCaml (slicing by 8); it is now computed by the
processor's own instruction, `crc32` of SSE4.2 on x86-64 ([architecture](architecture.md#the-journal-a-write-ahead-log)),
through one C file. Measured against 51cf32d, the commit before it, both built in release, alternated in one session
under the heavy lock, every process in a 3 GB scope.

**The checksum alone.** `bench.exe crc` times the new code; the old one was timed by the same loop in one program
linking both, alternated with the new run by run: 21 runs a size, each long enough to last 20 ms, from an odd offset
(3) so that no length is aligned for free.

| bytes | tables in OCaml (51cf32d) | the instruction | ratio, median [95 % interval] |
|---:|---:|---:|---:|
| 24 (a frame's header) | 918 MB/s (0.026 µs) | 2,945 MB/s (0.008 µs) | 3.21 [3.18, 3.26] |
| 4,096 | 1,166 MB/s (3.51 µs) | 9,585 MB/s (0.43 µs) | 8.19 [8.12, 8.25] |
| 16,384 (a page) | 1,174 MB/s (13.96 µs) | 9,419 MB/s (1.74 µs) | 8.01 [8.00, 8.11] |
| 1 MiB | 1,171 MB/s (895 µs) | 9,353 MB/s (112 µs) | 7.98 [7.92, 8.00] |
| 96 MiB (a large group's frame) | 1,133 MB/s (88.8 ms) | 8,561 MB/s (11.8 ms) | 7.59 [7.49, 7.63] |

**Beside the giants**, the same polynomial on the same buffers and machine, the same method (median of 21 runs after
warm-up):

| bytes | Cepheus | Java 21 `java.util.zip.CRC32C` | Go 1.26 `hash/crc32`, Castagnoli table |
|---:|---:|---:|---:|
| 24 | 2,945 MB/s | 3,890 MB/s | 2,436 MB/s |
| 4,096 | 9,585 MB/s | 21,993 MB/s | 25,003 MB/s |
| 16,384 | 9,419 MB/s | 23,357 MB/s | 25,832 MB/s |
| 1 MiB | 9,353 MB/s | 26,359 MB/s | 23,155 MB/s |
| 96 MiB | 8,561 MB/s | 12,745 MB/s | 12,015 MB/s |

Java and Go are 2.3 to 2.8 times faster from 4 KiB to 1 MiB, and 1.4 to 1.5 times at 96 MiB, where all three come
near the speed of memory. Go splits the buffer in three, runs the instruction on the three parts at once and
combines the three CRCs at the end (`castagnoliSSE42Triple`, `src/hash/crc32/crc32_amd64.go`); Java's is compiled by
HotSpot into machine code of its own (the `UseCRC32CIntrinsics` flag, on by default). Cepheus' code is one chain of
8-byte steps, each waiting for the result of the one before, so its speed is the instruction's latency, not its
throughput: the processor could start a step every cycle, but a step's result comes three cycles later (Go's source
says the same, after Intel's paper on the instruction). Three chains would gain about 1 µs a page read from the disk
(a cold read costs 41 to 91 µs) and about 25 ms a load: not done, the smallest code first. On a frame's 24-byte
header Cepheus is faster than Go and slower than Java. PostgreSQL 18 computes its CRC-32C with the same
instruction in one chain on this processor (`pg_comp_crc32c_sse42` in `src/port/pg_crc32c_sse42.c`), and by AVX-512
(VPCLMULQDQ) on processors that have it, which this one does not. Python's and Node's standard libraries have no
CRC-32C (their `zlib.crc32` is zlib's CRC-32, another polynomial).

**End to end**, 9 rounds alternated (the order swapped each round): the 10 M load in 4 large groups (`GROUP=56818`)
and its snapshot, then the open of the database it leaves (`bench.exe read DIR 10000000 none`: one run of 246 MB, which
fits the cache, so every one of its 15,038 pages is read and checked at open); the 1 M load a group a client (64
threads, `SNAPSHOT=0`) and the open of what it leaves (its runs and the journal's tail, 1,214 pages). Median [95 %
interval, order statistics, 96.1 %]; the ratio is paired by round; the tests are two-sided.

| | 51cf32d | the instruction | ratio | faster in | sign test |
|---|---:|---:|---:|---:|---:|
| 10 M facts, 4 large groups, until confirmed | 9.09 s [7.88, 11.68] | 9.43 s [8.18, 10.37] | 1.04 [0.79, 1.18] | 4 of 9 | p = 1 |
| its snapshot | 1.98 s [1.33, 2.27] | 2.04 s [1.52, 2.65] | 1.07 [0.67, 1.52] | 4 of 9 | p = 1 |
| **the open of that database** | 432 ms [389, 539] | **202 ms [197, 255]** | **0.49 [0.37, 0.60]** | 9 of 9 | p = 0.004 |
| 1 M facts, a group a client, until confirmed | 10.24 s [9.37, 11.18] | 10.95 s [9.39, 12.70] | 1.05 [0.85, 1.24] | 4 of 9 | p = 1 |
| the open of that database | 365 ms [356, 419] | 346 ms [339, 359] | 0.94 [0.82, 1.00] | 8 of 9 | p = 0.039 |

The open of the 10 M database takes half the time: 15,038 pages × 12.2 µs saved a page is 0.18 s of the 0.23 s
measured. The loads checksum about 330 MB, 0.29 s in OCaml and 0.04 s now; that 0.25 s is inside the disk's spread (the
old binary alone took 7.44 to 13.19 s for the same load), and 9 rounds do not resolve it: no load got measurably faster
or slower. A page read from the disk while answering (larger than memory) pays 1.74 µs for its check instead of
13.96.

**Start-up** of a program linking Cepheus (`bench.exe` without arguments: every module initialised, then exit), the
spawn and wait timed 2,000 times a side, alternated: 2,039 µs for 51cf32d, +1.0 µs [−7.7, 7.7] with the new library
alone, +9.9 µs [0.2, 18.4] (0.5 %) for the whole binary with its new `crc` command. The check of the processor is one
C call; the table of 2,048 numbers the old code built at start is gone. A fresh copy of the same binary started
17.8 µs [9.4, 28.3] slower than the file the build left, so these compare binaries where the build left them.

**The engine fixes measured again** (the section below), on a quiet machine: 2f37b23 against 51cf32d, the same loads
and opens, 9 rounds alternated. 10 M in 4 large groups: 9.68 s [8.42, 11.47] against 8.73 s [8.09, 9.61] (ratio 0.97
[0.77, 1.12], slower in 4 of 9, p = 1); its open 396 against 403 ms (1.02 [0.94, 1.26], p = 0.51); 1 M a group a
client 9.21 against 9.87 s (1.01 [0.85, 1.16], p = 1); its open 364 against 368 ms (1.00 [0.97, 1.14], p = 0.51). The
fixes cost nothing measurable: the 13.12 s below was the disk.

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
