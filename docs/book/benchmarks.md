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
  no mean and no normal interval: the median, with the interval between two order statistics, $x(j)$ and $x(n+1-j)$,
  which covers the true median with probability $1 - 2 P(B \le j - 1)$, $B \sim \text{Binomial}(n, 1/2)$, whatever the distribution
  ([Le Boudec 2010], theorem 2.1; [Hoefler 2015], rule 5). For 21 runs, $j = 6$: $[x(6), x(16)]$, 97.3 %. The number of
  runs and the exact coverage are printed with every interval (`bench/stats.ml`, used for both sides: PostgreSQL's
  times go through `bench.exe stats`).
- **Latencies from a histogram of every value**, not a sample: log-linear buckets as HdrHistogram does (exact below
  256 µs, then 128 buckets per power of two: every percentile within 0.8 %). p50, p90, p99, p99.9 and max; the p99
  with its 95 % interval (the same order statistics, with Binomial(n, 0.99) in its normal approximation, from 1,000
  values). PostgreSQL's latencies come from pgbench's log of every transaction, into the same histogram.
- **Two kinds of write loads.** Closed loop: each client writes as soon as its last write was confirmed; it gives the
  highest throughput, but its latencies are wrong under stalls: a client stalled by a 400 ms fsync sends nothing
  during the stall, so the writes that would have waited are never measured ("coordinated omission", [Tene 2015]).
  Open loop: writes are due at a fixed rate, all clients together (with $C$ clients, client $c$'s $k$-th write at
  $t_0 + (k C + c) / \text{rate}$), and a write's latency counts from the time it was due, as wrk2 does; PostgreSQL's
  side is `pgbench -R`, whose latencies count from the scheduled start (the schedule lag is added). The open loop gives
  the latencies; the closed loop, the throughput.
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
| `bench.exe pages DIR FACTS` | the questions with operators and an order: a page of 20 of the unpaid invoices, the largest totals first, by the index path and by the heap path, the first page and the 101st, against the whole answer sorted by the program; `Not` and `Prefix`, each against what a program did before them; `Less` (a check of each follow link, and a range of the totals' index below one invoice's total) and `Optional` (the clients of a city, and every client, with the clients each follows), each beside the plain question |
| `bench.exe snapshot DIR` | a full merge of a database (`snapshot`), timed: every run of it in one |
| `bench.exe write DIR CLIENTS SECS [RATE]` | durable writes of a new invoice (4 facts) by CLIENTS threads: as fast as they go, or RATE groups a second in all (open loop) |
| `bench.exe merge DIR GROUPS` | GROUPS invoices with no background merge, then one merge (`snapshot`): its time and the peak memory of the merge alone |
| `bench.exe fsync DIR SECS append\|overwrite` | the file system alone: a 9,000-byte frame and its fsync in a loop, appended or written over zeros forced beforehand |
| `bench.exe trace DIR FACTS OUT uniform\|zipf day\|points\|scan` | records the page reads of a day of questions, for the cache study |
| `bench.exe cachesim TRACE` | LRU, CLOCK, 2Q, ARC, SIEVE, S3-FIFO, W-TinyLFU and Belady's optimum on a recorded trace |
| `bench.exe stats NAME [us]` | the summary of numbers read on stdin, one a line, in ms (with `us`: latencies in µs, into a histogram): how the other sides' times go through the same statistics |
| `bench.exe cpu DIR N` | the writer's work alone: N 5-fact groups into a fork of the database (no disk) |
| `bench.exe crc` | CRC-32C alone on 24 bytes, 4 KiB, 16 KiB, 1 MiB and 96 MiB from an odd offset: the time of a call and MB/s, median and 95 % interval over `RUNS` runs |
| `sbench.exe watches DIR` | a change under a watch of `Not`, `Or`, `In` and `Prefix` (one hub each, the changes made in memory), against the question answered again in full: 21 changes each |
| `rbench.exe load DIR CSVDIR`, `rbench.exe run DIR` | reports: the data (10,000 clients, 245,000 invoices) and its CSV for PostgreSQL; each aggregate over 1, 100 and 10,000 groups and the totals by month (`Trunc`), as the server answers them (`Answer.answer`) |
| `abench.exe DIR`, `mbench.exe DIR` | the questions of before, for an A/B of two builds on one database, each file compiling against the build before the change: `abench` a Give of a join, groups, a sorted page, `Not`, a range, `Optional` (rbench's data); `mbench` small questions in loops, the fixed cost of a fold (a fold of one fact, `Prefix`, Q3 counted, `Not`, `Optional`, a sorted page, a find of every e-mail, Q4's fold; bench.exe's data) |
| `kbench.exe load DIR N`, `run DIR`, `fork N`, `mixed DIR N`, `csv DIR OUT` | pages of a kind by its things' ids: N items (a name, a tenant, an int) in one run; a page of 51 by id ascending and descending, the first and the one after the middle item, a tenant's likewise, each checked against the ids it must give; on a fork filled in memory; on a fork whose delta holds N things of another kind and one item renamed; the items as CSV for `pg.sh keyset` |
| `wbench.exe run DIR` | windows (protocol 10) on rbench's data: a running total, a moving mean of 3, a rank by total and the row before, over the 245,000 invoices in one group, each city's (100) and each client's (10,000); the 3 latest invoices of each client and the last one (`Each` and `Limit`); the monthly totals in Paris with their windows (a report); a page of 51 with its running total, the first and the one after the 200,000th row, beside the same pages without windows; `pg.sh windows ROOT index\|run` asks PostgreSQL the same (`OVER`, `LATERAL`, `DISTINCT ON`), with the indexes a user makes for them |
| `bench/pg/pg.sh init\|start\|load\|read\|write\|stop ROOT ...` | PostgreSQL's side on a cluster of its own (`ROOT/data`, port 5544): `start ROOT MEM` caps the server's memory (`SHARED=32MB` sets `shared_buffers`), `read ROOT NCLIENTS` (`WORKERS=k` parallel workers a query, `QS`, `RUNS`), `write ROOT NCLIENTS CLIENTS SECS` (`RATE=r`: open loop; `COUNTER=1`: each transaction increments one shared counter row), `ops ROOT` (the questions of `bench.exe pages` that `Less` and `Optional` answer, with an index on `invoice (total)`), `keyset ROOT load\|run DIR` (kbench's pages: `WHERE id > $1 ORDER BY id LIMIT 51` on the primary key, a tenant's on `(tenant, id)`) |
| `bench/sqlite/sqlite.sh load\|read ROOT ...` | SQLite's side, one file `ROOT/bench.db`: `load ROOT CSVDIR`, `read ROOT NCLIENTS` (`QS`, `RUNS`, `CACHE_MB`) |
| `bench/ops.sh cepheus\|cepheus-replay\|pg\|pg-replay\|sqlite ROOT CSVDIR ...` | backup and restore on the three sides: `cepheus backup`, `verify`, `restore` to the end and to a group; `pg_basebackup`, `pg_verifybackup`, a restore and a point-in-time recovery; SQLite's `.backup`, `integrity_check`, `.restore`; the whole history replayed (`-replay`) |
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

## Pages of a kind by its things' ids (2026-11-26), at 10,000 to 1,000,000 things

**What was slow.** Centauri's admin lists a kind page by page: `Find` of `[[t, Kind.Field, v]]`, `Give: {Id: t}`,
`Sort: [t]`, `Limit: 51` (the page and the next one's cursor), `After` the last row. On a kind of 100,005 clients a page
took 35 to 46 ms, and all its pages about 2 minutes. The index path read a property's values in their order: the first
key had to be a pattern's value. A thing is its patterns' thing, so the heap answered: every binding of the kind, two
candidates a thing, each compared to the cursor: the whole kind at every page, whatever its depth. `Above` on a thing
was refused by the Cesia package, and in the engine a range on a thing variable was a check of every thing of its
property.

**What changed.** A sort whose first key is the thing of a pattern reads windows of the next things that hold the
pattern's property (that hold its value, when it is a constant: a tenant's things), from the cursor, in the order of
their ids: each run's column of a property keeps its things in that order behind a rank table (a word for 32 things),
the things of a value are its rows by value, in thing order (a binary search finds the cursor), and the delta's are
read by thing or by value, merged; the first window holds k things, k + 1 after a cursor
([pages](cesia.md#sort-limit-and-after-pages)). A range on a thing variable reads its things from the range's first,
and the planner counts them there from the rank tables and offsets; `Above`, `Below` and `Between` take a thing's id.

**Method.** `kbench.exe load` (a kind of N items: a name, a link to one of 10 tenants, an int; one run, merged), the
same rows in PostgreSQL 18.6 (`pg.sh keyset`: a table of the items, `id` its primary key, an index on `(tenant, id)`,
the ids Cepheus gave), on the SATA SSD. A page of 51, by id ascending and descending, the first and the one after the
middle item; then the things of tenant 3 (one item in 10) likewise. Main's binaries (12a5a24, *old*) beside this
version's (*new*), alternated in each round: 5 rounds, each side a median of 11 runs; given: the median of the 5
rounds and in brackets their least and largest; *new/old*: the median of the rounds' ratios. Cepheus: `ask` in the
process, the rows made as values, on up to 8 domains; PostgreSQL: its engine's time (`EXPLAIN (ANALYZE, TIMING OFF)`).
Then the same pages on a fork of 100,000 items filled in memory (`kbench.exe fork`: every fact in its delta, as a
program's database in memory), and Centauri's admin pages in a browser (`bench.mjs shell` of Centauri's admin, its
invoices app in memory with 100,005 clients: the data browser's kind `client` filled with All, every page of 50 asked
in turn). The machine was shared: a load average (1 minute) of 4.6 to 13 on its 8 threads.

**Pages of 51**, one run (*PostgreSQL / new*: PostgreSQL's median over Cepheus's):

| things | page | old | new | new/old | PostgreSQL 18.6 | PostgreSQL / new |
|---|---|---:|---:|---:|---:|---:|
| 10,000 | by id, the first page | 2.63 ms [2.60 ms, 2.67 ms] | **23.6 µs [23.3 µs, 23.8 µs]** | 0.0089 | 44.0 µs [40.0 µs, 52.0 µs] | 1.89 |
| 10,000 | by id, after the middle | 2.10 ms [2.08 ms, 2.54 ms] | **24.1 µs [23.8 µs, 24.8 µs]** | 0.0114 | 52.0 µs [49.0 µs, 54.0 µs] | 2.14 |
| 10,000 | by id descending, the first page | 2.80 ms [2.74 ms, 3.38 ms] | **23.8 µs [23.4 µs, 24.4 µs]** | 0.0085 | 41.0 µs [41.0 µs, 45.0 µs] | 1.75 |
| 10,000 | by id descending, after the middle | 2.16 ms [2.14 ms, 2.65 ms] | **24.7 µs [24.3 µs, 25.3 µs]** | 0.0115 | 54.0 µs [51.0 µs, 57.0 µs] | 2.18 |
| 10,000 | tenant 3's by id, the first page | 206 µs [200 µs, 263 µs] | **24.8 µs [24.6 µs, 25.1 µs]** | 0.1190 | 53.0 µs [50.0 µs, 56.0 µs] | 2.11 |
| 10,000 | tenant 3's by id, after its middle | 155 µs [149 µs, 205 µs] | **28.5 µs [28.1 µs, 28.8 µs]** | 0.1812 | 54.0 µs [53.0 µs, 59.0 µs] | 1.89 |
| 10,000 | tenant 3's by id descending, the first page | 218 µs [213 µs, 270 µs] | **24.4 µs [23.8 µs, 24.6 µs]** | 0.1127 | 50.0 µs [46.0 µs, 53.0 µs] | 2.10 |
| 10,000 | tenant 3's by id descending, after its middle | 161 µs [155 µs, 202 µs] | **30.3 µs [29.6 µs, 34.8 µs]** | 0.1892 | 53.0 µs [50.0 µs, 59.0 µs] | 1.75 |
| 100,000 | by id, the first page | 10.4 ms [10.2 ms, 11.3 ms] | **24.8 µs [24.5 µs, 26.1 µs]** | 0.0024 | 43.0 µs [42.0 µs, 72.0 µs] | 1.76 |
| 100,000 | by id, after the middle | 8.49 ms [8.36 ms, 9.34 ms] | **25.7 µs [25.4 µs, 26.2 µs]** | 0.0031 | 51.0 µs [49.0 µs, 58.0 µs] | 1.97 |
| 100,000 | by id descending, the first page | 11.0 ms [10.9 ms, 14.1 ms] | **25.4 µs [25.1 µs, 25.8 µs]** | 0.0023 | 36.0 µs [35.0 µs, 45.0 µs] | 1.43 |
| 100,000 | by id descending, after the middle | 8.85 ms [8.70 ms, 11.1 ms] | **26.8 µs [26.4 µs, 27.3 µs]** | 0.0030 | 53.0 µs [51.0 µs, 58.0 µs] | 1.99 |
| 100,000 | tenant 3's by id, the first page | 2.05 ms [2.02 ms, 2.56 ms] | **28.5 µs [28.2 µs, 28.6 µs]** | 0.0139 | 62.0 µs [59.0 µs, 64.0 µs] | 2.17 |
| 100,000 | tenant 3's by id, after its middle | 1.52 ms [1.49 ms, 1.89 ms] | **32.9 µs [32.6 µs, 33.0 µs]** | 0.0214 | 64.0 µs [63.0 µs, 65.0 µs] | 1.96 |
| 100,000 | tenant 3's by id descending, the first page | 2.17 ms [2.13 ms, 2.72 ms] | **24.9 µs [24.3 µs, 24.9 µs]** | 0.0113 | 52.0 µs [51.0 µs, 55.0 µs] | 2.14 |
| 100,000 | tenant 3's by id descending, after its middle | 1.59 ms [1.55 ms, 2.04 ms] | **33.6 µs [33.0 µs, 33.8 µs]** | 0.0210 | 63.0 µs [61.0 µs, 67.0 µs] | 1.88 |
| 1,000,000 | by id, the first page | 93.2 ms [90.8 ms, 111 ms] | **24.7 µs [24.5 µs, 46.4 µs]** | 0.0003 | 42.0 µs [41.0 µs, 46.0 µs] | 1.67 |
| 1,000,000 | by id, after the middle | 81.4 ms [77.3 ms, 104 ms] | **25.2 µs [24.9 µs, 29.2 µs]** | 0.0003 | 60.0 µs [58.0 µs, 64.0 µs] | 2.36 |
| 1,000,000 | by id descending, the first page | 99.2 ms [96.1 ms, 117 ms] | **24.6 µs [24.0 µs, 25.1 µs]** | 0.0003 | 41.0 µs [40.0 µs, 44.0 µs] | 1.70 |
| 1,000,000 | by id descending, after the middle | 82.4 ms [80.7 ms, 98.2 ms] | **25.3 µs [24.9 µs, 27.3 µs]** | 0.0003 | 62.0 µs [60.0 µs, 70.0 µs] | 2.45 |
| 1,000,000 | tenant 3's by id, the first page | 9.51 ms [8.54 ms, 10.9 ms] | **29.1 µs [28.7 µs, 29.9 µs]** | 0.0031 | 57.0 µs [57.0 µs, 59.0 µs] | 1.96 |
| 1,000,000 | tenant 3's by id, after its middle | 7.10 ms [6.66 ms, 7.66 ms] | **32.0 µs [31.6 µs, 32.2 µs]** | 0.0044 | 60.0 µs [58.0 µs, 64.0 µs] | 1.90 |
| 1,000,000 | tenant 3's by id descending, the first page | 9.96 ms [9.35 ms, 11.7 ms] | **24.4 µs [24.1 µs, 24.6 µs]** | 0.0025 | 56.0 µs [55.0 µs, 61.0 µs] | 2.32 |
| 1,000,000 | tenant 3's by id descending, after its middle | 7.23 ms [7.02 ms, 8.42 ms] | **34.0 µs [33.8 µs, 34.5 µs]** | 0.0048 | 66.0 µs [63.0 µs, 69.0 µs] | 1.92 |

**On a fork of 100,000 items** (every fact in its delta, the database of a program in memory):

| page | old | new | new/old |
|---|---:|---:|---:|
| by id, the first page | 25.4 ms [25.1 ms, 31.3 ms] | **44.8 µs [44.6 µs, 45.0 µs]** | 0.0018 |
| by id, after the middle | 23.4 ms [23.1 ms, 24.2 ms] | **45.5 µs [45.0 µs, 45.8 µs]** | 0.0019 |
| by id descending, the first page | 25.8 ms [25.2 ms, 27.1 ms] | **47.5 µs [47.1 µs, 47.6 µs]** | 0.0018 |
| by id descending, after the middle | 23.7 ms [23.2 ms, 24.2 ms] | **49.8 µs [48.6 µs, 51.2 µs]** | 0.0021 |
| tenant 3's by id, the first page | 2.11 ms [2.06 ms, 3.04 ms] | **33.9 µs [33.3 µs, 34.2 µs]** | 0.0162 |
| tenant 3's by id, after its middle | 1.57 ms [1.56 ms, 2.42 ms] | **35.1 µs [34.4 µs, 35.3 µs]** | 0.0224 |
| tenant 3's by id descending, the first page | 2.19 ms [2.15 ms, 3.32 ms] | **36.5 µs [36.2 µs, 37.2 µs]** | 0.0166 |
| tenant 3's by id descending, after its middle | 1.68 ms [1.61 ms, 2.40 ms] | **38.9 µs [38.1 µs, 64.0 µs]** | 0.0236 |


**Beside a delta of another kind** (`kbench.exe mixed`: the run of 1,000,000 items, on a fork whose delta holds 100,000
things of another kind, made after them, and one item renamed; 3 rounds alternated, this version against its first
commit, ed44295, whose delta was read from its map by thing up to the next thing of the property): the delta's things
of the property read from its map by value (two entries) take a page of 51 by id to 25 to 27 µs, where reading every
newer thing of the delta took 8.7 ms ascending and 11.8 ms descending; the pages of the tables above the same, 0.99 to
1.04 times.

**Centauri's admin** (Chrome's headless shell, 5 rounds, the median and [least, largest]): the data browser filled with
the 100,005 clients, every page of 50 asked in turn (All), 94.4 s [92.1, 109.6] with main's engine, **40.6 s** [38.4,
46.5] with this one: 47 ms a page before, 20 ms now, of which the page's `Find` takes about 0.05 ms; the rest is the
admin's own work around it (each row's fields read by a `Get`, its JSON, the page sent and its table filled).

- A page costs its rows: 24 to 34 µs at every size and depth, where the heap's cost grew with the kind (2.1 to 2.8 ms
  at 10,000 things, 8.5 to 11 ms at 100,000, 81 to 99 ms at 1,000,000), 87 to 4,000 times less; a tenant's things
  (one in 10), 5 to 410 times less. In the delta, a page is 45 to 50 µs (each thing checked against the delta's
  changes), 480 to 570 times less than the heap's 23 to 26 ms; a tenant's 34 to 39 µs, 43 to 62 times less.
- PostgreSQL's keyset query reads its primary key's B-tree from the cursor and the page's rows: 36 to 66 µs of its
  engine alone, 1.4 to 2.5 times Cepheus's, which reads the property's column in the order of the ids (a rank word for
  32 things) and makes the rows' values in the same time. A page after the middle costs PostgreSQL 1 to 21 µs more than
  the first (the descent of its B-tree to the cursor), Cepheus 0.5 to 1.4 µs by id (a rank word) and 3 to 10 µs for a
  tenant's (two binary searches among the rows of the tenant's value).

## Questions split past a narrow first level, and lighter groups (2026-11-26), at 1 million facts

**What was slow.** Each part of the questions was timed apart on the data below (one domain against eight, the join
alone against the join and its groups), under the lock:

- The engine split a question across its domains at its first level only, and only when that level had 20,000
  candidates or more. The invoices whose total is below one invoice's start from that one total (the order: the total,
  the totals below it, their invoices): the 122,962 invoices ran on one domain, 37 to 39 ms on 1 and 2 domains and no
  less on 8. A report by city starts from the 10,000 clients, fewer candidates than the 245,000 invoices, so the
  planner's first: on one domain too, 45 ms on 8 domains as on 1.
- A report of 10,000 groups starts from the invoices and was split, but each of its 128 slices built its own hash
  table, a key array made and hashed by OCaml's polymorphic hash for every row and an object a group a slice; the 128
  tables were then merged on one domain (32 ms of a `Sum`'s 85), the groups sorted by the polymorphic comparison
  (5.6 ms), and a median's bags merged by putting each value again into one table (25 to 95 ms).
- `Cepheus.ask` made its rows' values on one domain after the fold (122,962 rows for the range above).

**What changed.** A level of 20,000 candidates or more is split wherever it comes in the order; the first level of two
candidates or more past those of one, when the planner expects 80,000 candidates of work or more, runs on the asking
domain until its candidates' measured work says the rest takes that much, and the rest is split
([architecture](architecture.md#one-writer-threads-and-domains)). A Group's groups are numbers in one table of open
addressing over their keys' words (a row costs a hash and no allocation), their Count, Sum, Min and Max in one flat
array, a mean's exact sums in four ints a group, every group's bag in one table a column (a table a group once the
groups hold more than 64 different values each: a city's thousands of totals); a table a domain (these
aggregates do not depend on the rows' order), merged at the end, the domains' bags read together then rather than put
again, the groups sorted by an int comparison. `ask` makes each row's values in its step, on the domain that found it.

**Method.** The data of the two sections below (`bench.exe load`, 1 M facts; `rbench.exe load`, 990,000), each merged
into one run, on the SATA SSD; PostgreSQL 18.6 the same rows. Main's binaries (8a97c5d, *old*) beside this version's
(*new*), built the same way and alternated in each round: 5 rounds, each side a median of 11 runs (5 for `bench.exe
pages`); given: the median of the 5 rounds and in brackets their least and largest; *new/old*: the median of the
rounds' ratios, in brackets their least and largest. `CEPHEUS_DOMAINS` 8 (the default here: 4 cores, 8 threads), 4, 2
and 1 for `rbench.exe` and `bench.exe read` (`bench.exe pages` runs on 8). PostgreSQL: its engine's time (`EXPLAIN
(ANALYZE, TIMING OFF)`), 2 workers allowed. The machine was shared: a load average (1 minute) of 1.7 to 3.3 on its 8
threads.

**Reports**, 8 domains (beside PostgreSQL: [the next section](#reports-avg-countx-values-quantile-stddev-trunc-2026-11-26-at-1-million-facts)):

| question | old | new | new/old |
|---|---:|---:|---:|
| Sum 1 group | 13.5 ms [13.3, 17.6] | 12.0 ms [10.5, 15.3] | 0.81 [0.70, 1.15] |
| Avg 1 group | 13.5 ms [13.3, 15.4] | 11.6 ms [11.4, 13.5] | 0.87 [0.85, 0.98] |
| Count(status) 1 group | 18.2 ms [18.0, 30.1] | 17.0 ms [15.6, 18.1] | 0.87 [0.60, 0.95] |
| Values(status) 1 group | 18.2 ms [18.0, 19.1] | 17.9 ms [14.9, 23.3] | 0.94 [0.82, 1.28] |
| Median 1 group | 28.1 ms [27.5, 28.2] | 28.8 ms [26.8, 30.6] | 1.02 [0.95, 1.09] |
| Stddev 1 group | 13.7 ms [13.3, 13.9] | 12.0 ms [11.7, 14.0] | 0.87 [0.87, 1.01] |
| Sum 100 groups (city) | 46.5 ms [45.9, 52.1] | 9.68 ms [9.25, 11.3] | 0.21 [0.19, 0.23] |
| Avg 100 groups (city) | 52.0 ms [50.5, 56.5] | 11.0 ms [10.3, 12.5] | 0.22 [0.20, 0.23] |
| Count(status) 100 groups (city) | 72.4 ms [71.4, 81.7] | 15.2 ms [14.7, 17.8] | 0.21 [0.19, 0.25] |
| Values(status) 100 groups (city) | 73.2 ms [72.6, 94.0] | 15.2 ms [15.0, 17.6] | 0.21 [0.16, 0.24] |
| Median 100 groups (city) | 93.1 ms [88.3, 93.7] | 39.6 ms [38.4, 45.8] | 0.45 [0.42, 0.49] |
| Stddev 100 groups (city) | 51.3 ms [50.4, 53.6] | 11.4 ms [10.9, 14.1] | 0.23 [0.21, 0.26] |
| Sum 10,000 groups (client) | 83.4 ms [80.9, 91.9] | 26.1 ms [25.0, 33.3] | 0.31 [0.30, 0.41] |
| Avg 10,000 groups (client) | 151 ms [142, 163] | 36.5 ms [35.1, 46.4] | 0.24 [0.23, 0.31] |
| Count(status) 10,000 groups (client) | 200 ms [195, 225] | 57.7 ms [55.1, 76.9] | 0.29 [0.28, 0.38] |
| Values(status) 10,000 groups (client) | 227 ms [221, 251] | 73.6 ms [70.5, 95.1] | 0.33 [0.31, 0.41] |
| Median 10,000 groups (client) | 285 ms [279, 306] | 82.3 ms [79.3, 106] | 0.29 [0.28, 0.35] |
| Stddev 10,000 groups (client) | 160 ms [142, 164] | 38.0 ms [35.5, 47.2] | 0.27 [0.22, 0.29] |
| Sum by month in Paris (Trunc) | 31.7 ms [28.7, 36.8] | 20.9 ms [20.4, 24.7] | 0.69 [0.66, 0.75] |
| Sum by month in UTC (Trunc) | 26.6 ms [26.4, 39.7] | 19.0 ms [18.2, 24.3] | 0.70 [0.61, 0.73] |

**On 1, 2, 4 and 8 domains** (`CEPHEUS_DOMAINS`), new (old):

| question | 1 | 2 | 4 | 8 |
|---|---:|---:|---:|---:|
| Sum 1 group | 26.6 (32.8) | 23.4 (22.8) | 14.1 (16.8) | 12.0 (13.5) |
| Sum 100 groups (city) | 36.0 (45.4) | 19.6 (45.7) | 10.7 (44.9) | 9.68 (46.5) |
| Median 100 groups (city) | 87.3 (91.5) | 61.1 (90.1) | 44.2 (92.7) | 39.6 (93.1) |
| Avg 10,000 groups (client) | 71.0 (121) | 49.2 (191) | 38.4 (158) | 36.5 (151) |
| Median 10,000 groups (client) | 141 (229) | 102 (318) | 88.0 (292) | 82.3 (285) |

**Less and Optional** (`bench.exe pages`, 8 domains), beside PostgreSQL's engine (`pg.sh ops`):

| question | old | new | new/old | PostgreSQL 18.6 |
|---|---:|---:|---:|---:|
| the follow links to a newer client, `Less(a, b)` | 11.0 ms [10.6, 11.4] | 8.76 ms [8.41, 9.31] | 0.79 [0.77, 0.84] | 3.82 ms [3.60, 4.14] |
| the invoices below one invoice's total, `Less(t, tx)` | 57.5 ms [54.3, 59.4] | 28.0 ms [27.3, 30.7] | 0.51 [0.46, 0.53] | 19.0 ms [18.9, 19.6] |
| &nbsp;&nbsp;the same range, its bound read first | 39.3 ms [38.0, 39.9] | 26.7 ms [25.8, 27.8] | 0.69 [0.66, 0.70] |  |
| every client with the clients each follows, `Optional` | 21.9 ms [21.4, 22.9] | 16.7 ms [15.7, 17.7] | 0.76 [0.72, 0.81] | 12.5 ms [12.2, 13.2] |
| &nbsp;&nbsp;the same as a join | 24.6 ms [23.7, 27.8] | 18.8 ms [18.2, 19.2] | 0.76 [0.69, 0.78] |  |

**The questions of before**: Q1 to Q5 (`bench.exe read`) and small questions in loops (`mbench.ml`: the fixed cost of
a fold), new/old:

| question | 1 domain | 8 domains |
|---|---:|---:|
| Q1, an invoice by its id | 1.00 [0.97, 1.03] | 1.00 [0.92, 1.08] |
| Q2, a client by e-mail | 1.00 [0.98, 1.04] | 1.00 [0.97, 1.02] |
| Q3, the unpaid invoices of a city (396 rows) | 1.02 [1.01, 1.06] | 1.01 [0.98, 1.03] |
| Q4, the unpaid sum by city (45,064 invoices) | 1.03 [0.98, 1.04] | 1.00 [0.92, 1.13] |
| Q5, the triangles of the follow links | 1.00 [0.97, 1.00] | 1.01 [0.98, 1.03] |
| a fold of one fact (a thing's name) | 0.99 [0.99, 1.09] | 1.00 [0.82, 1.08] |
| `Prefix`, one e-mail (`ask`) | 0.99 [0.98, 1.04] | 1.00 [0.95, 1.15] |
| Q3 counted (`fold`) | 1.01 [1.00, 1.05] | 0.99 [0.98, 1.00] |
| `Not`, a city's clients with no unpaid invoice (`ask`) | 1.03 [0.99, 1.04] | 1.00 [0.93, 1.24] |
| `Optional`, a city's clients and their follows (`ask`) | 0.99 [0.97, 1.04] | 0.97 [0.89, 0.99] |
| a page of 20, the largest totals first (`ask`) | 0.99 [0.97, 1.06] | 1.01 [0.94, 1.01] |
| every e-mail (`find`, 11,363 texts) | 1.01 [0.94, 1.06] | 0.96 [0.95, 1.04] |
| Q4's fold alone | 1.00 [0.99, 1.10] | 1.01 [0.84, 1.08] |

- **Reports**: 3 to 5 times faster at 100 and 10,000 groups on 8 domains (a median of 100 groups 2.2 times); on one
  domain 1.1 to 1.8 times, the flat tables. PostgreSQL is now behind at every number of groups ([the next section](#reports-avg-countx-values-quantile-stddev-trunc-2026-11-26-at-1-million-facts)).
- **The range below one invoice's total** splits at its second level now; its time is then the values it makes: the
  same range with its bound read first takes as long.
- **What still loses**: a check of each follow link, `Less(a, b)` (8.76 ms against PostgreSQL's 3.82 ms: its scan of a
  table of two columns reads a row in 70 ns, where Cepheus reads the links' index fact by fact and makes each row's
  values); the range below one invoice's total (28.0 ms against 19.0 ms: the 122,962 rows made as OCaml values, a
  program's reader's work, where PostgreSQL's engine sends none); every client with the clients each follows (16.7 ms
  against 12.5 ms: PostgreSQL's hash join of two whole tables).
- **Nothing before slower**: Q1 to Q5 on 1, 2, 4 and 8 domains 0.97 to 1.04 (the medians of the rounds' ratios; Q4
  on one domain 1.03, and its fold alone in a loop 1.00), the small questions in loops 0.96 to 1.03: the split's
  machinery is made only for a level to split or to probe, so a fold that has none allocates what it did.

## Reports: Avg, Count(x), Values, Quantile, Stddev, Trunc (2026-11-26), at 1 million facts

**Method.** `bench/rbench.ml load`: 10,000 clients (a city among 100) and 245,000 invoices (a client, a total of 0.01
to 1,000.00 in cents, a status: 70 % paid, 20 % unpaid, 10 % late, a date over 2017 to 2026): 990,000 facts merged into
one run, on the SATA SSD; PostgreSQL 18.6 the same rows (`pg.sh reports load`: `rclient`, `rinvoice`, the total a
`bigint` of cents, the date a `timestamptz`, `rinvoice(client)` indexed, `VACUUM ANALYZE`). Each aggregate over every
invoice (1 group), by its client's city (100 groups: a join of the invoices and the clients), by its client (10,000
groups), each side reading only what the aggregate needs: Cepheus the engine's answer (`rbench.exe run`:
`Answer.answer`, what the server computes, no socket), PostgreSQL the execution time of `EXPLAIN (ANALYZE, TIMING OFF)`
(`pg.sh reports run`: inside the server, no socket, its default of 2 parallel workers). 5 alternated rounds, each side a
median of 11 runs; given: the median of the 5 rounds, and in brackets their least and largest. The same answers both
sides (rows counted; a `Values` group is one row a status at Cepheus, one array at PostgreSQL). Measured again the same
day after the split past a narrow first level and the flat tables of groups ([the section
above](#questions-split-past-a-narrow-first-level-and-lighter-groups-2026-11-26-at-1-million-facts), which gives the
numbers before them); the machine was shared: a load average (1 minute) of 1.9 to 2.5 on its 8 threads.

| aggregate | groups | Cepheus | PostgreSQL 18.6 | |
|---|---:|---:|---:|---|
| `Sum` (the aggregate of before; `sum`) | 1 | **12.0 ms** [10.5, 15.3] | 13.4 ms [13.3, 15.7] | Cepheus, 1.1 times |
| | 100 | **9.68 ms** [9.25, 11.3] | 57.8 ms [50.6, 72.6] | Cepheus, 6.0 times |
| | 10,000 | **26.1 ms** [25.0, 33.3] | 63.7 ms [63.2, 93.4] | Cepheus, 2.4 times |
| `Avg` (`avg`) | 1 | **11.6 ms** [11.4, 13.5] | 13.6 ms [13.4, 15.7] | Cepheus, 1.2 times |
| | 100 | **11.0 ms** [10.3, 12.5] | 53.1 ms [50.5, 68.8] | Cepheus, 4.8 times |
| | 10,000 | **36.5 ms** [35.1, 46.4] | 65.5 ms [64.6, 68.2] | Cepheus, 1.8 times |
| `Count(status)` (`count(DISTINCT status)`) | 1 | **17.0 ms** [15.6, 18.1] | 54.2 ms [53.7, 64.8] | Cepheus, 3.2 times |
| | 100 | **15.2 ms** [14.7, 17.8] | 190 ms [188, 253] | Cepheus, 13 times |
| | 10,000 | **57.7 ms** [55.1, 76.9] | 169 ms [166, 178] | Cepheus, 2.9 times |
| `Values(status)` (`array_agg(DISTINCT status)`) | 1 | **17.9 ms** [14.9, 23.3] | 53.6 ms [53.3, 67.7] | Cepheus, 3.0 times |
| | 100 | **15.2 ms** [15.0, 17.6] | 201 ms [197, 262] | Cepheus, 13 times |
| | 10,000 | **73.6 ms** [70.5, 95.1] | 171 ms [170, 181] | Cepheus, 2.3 times |
| `Median(total)` (`percentile_cont(0.5) WITHIN GROUP (ORDER BY total)`) | 1 | **28.8 ms** [26.8, 30.6] | 56.9 ms [56.6, 66.4] | Cepheus, 2.0 times |
| | 100 | **39.6 ms** [38.4, 45.8] | 200 ms [192, 254] | Cepheus, 5.0 times |
| | 10,000 | **82.3 ms** [79.3, 106] | 135 ms [133, 141] | Cepheus, 1.6 times |
| `Stddev(total)` (`stddev`) | 1 | **12.0 ms** [11.7, 14.0] | 25.0 ms [24.9, 29.2] | Cepheus, 2.1 times |
| | 100 | **11.4 ms** [10.9, 14.1] | 66.6 ms [64.3, 87.4] | Cepheus, 5.9 times |
| | 10,000 | **38.0 ms** [35.5, 47.2] | 112 ms [107, 128] | Cepheus, 2.9 times |
| `Sum` by `Trunc(date, "month", zone = "Europe/Paris")` (`date_trunc('month', date, 'Europe/Paris')`) | 121 | **20.9 ms** [20.4, 24.7] | 141 ms [138, 174] | Cepheus, 6.7 times |
| `Sum` by `Trunc(date, "month")` (UTC) | 120 | **19.0 ms** [18.2, 24.3] | 132 ms [129, 163] | Cepheus, 7.0 times |

- **Cepheus at every number of groups.** PostgreSQL's `count(DISTINCT)`, `array_agg(DISTINCT)` and `percentile_cont`
  sort each group's rows (a sort of 245,000 rows for one group), where Cepheus keeps each group's different values with
  their counts (3 statuses, about 92,000 totals) and selects the median's rank. The questions of 100 and 10,000 groups
  run on Cepheus's 8 domains now: the first starts from the 10,000 clients, a level too small to split by its count,
  whose candidates' measured work (about 50 candidates a client) splits the rest; the second from the 245,000 invoices,
  as before, its groups now in one flat table a domain (a mean's exact sums in four ints a group, a group's different
  values in its column's one table) where each of 128 slices built a hash table of objects. PostgreSQL ran its 2
  workers and its leader. One group is closest for `Sum` and `Avg` (1.1 to 1.2 times): a single scan of 245,000 rows,
  both sides on their cores.
- **Exact costs little.** A mean or a spread from exact sums costs what a sum costs, within a sixth at 1 and 100
  groups, two fifths more at 10,000 (each group's result computed from its sums): an int's sums stay in plain ints while
  they cannot overflow (a value of at most 26 bits, a thousand squares), and the limbs are made only past that.
- **Trunc** reads the zone's offset by a binary search of its transitions and remembers the start of the last 1,024
  months it found: 0.01 µs a row more than UTC's here. PostgreSQL's whole question costs 0.6 µs a row, its `date_trunc`
  converting each row's instant to a local time and back.
- **No slowdown of the questions of before**, when reports came: `abench.exe`, the same file built on main
  (d9431f6) and on that branch, alternated in each round on the same database: a Give of a join, `Sum` and `Count` by
  city, `Min` and `Max` by client, a sorted group, a page, `Not`, a range and `Optional`: new/old 0.93 to 1.01 (median
  of the rounds' ratios; their least and largest 0.65 and 1.31, the noise of a shared machine on sub-millisecond
  questions). The split's own A/B: [the section above](#questions-split-past-a-narrow-first-level-and-lighter-groups-2026-11-26-at-1-million-facts).

## Deletes and links that name a kind (2026-11-25)

**Method.** `bench/dbench.ml load`: 10,000 clients, 100,000 invoices (`invoice/client` names the kind client,
`refuse`), 200,000 lines over them (`line/invoice`: `cascade`), and the measured things: clients of 0, 100 and 10,000
invoices, invoices of 0, 100 and 10,000 lines, and of 0, 100 and 10,000 notes (`note/about`: `clear`), 680,681 facts
merged into one run, on the SATA SSD. PostgreSQL 18.6 the same rows (`pg.sh fk load`, `bench/pg/fk.sql`), the
referencing columns indexed, as a PostgreSQL user writes them, `REFERENCES client` with no action (`NO ACTION`, which
refuses), `ON DELETE CASCADE` and `ON DELETE SET NULL`. Each side measures its engine's work and throws it away, so that
every run deletes the same: Cepheus `dbench.exe delete`, the group of one `Delete` written to a fork of the database
(the writer's resolve, nothing on the disk); PostgreSQL `pg.sh fk run`, the `DELETE` timed inside the server by a
PL/pgSQL function in a subtransaction rolled back (a refusal by a foreign key caught), its plan kept by the session.
5 rounds, each side a median of 21 runs; given: the median of the 5 rounds, and in brackets their least and largest.
The machine was shared with other jobs: a load average (1 minute) of 2.7 to 3.1 on its 8 threads.

| a Delete of | linking things | Cepheus | PostgreSQL 18.6 | |
|---|---:|---:|---:|---|
| a client, `refuse` (refused but for 0) | 0 | **5 µs** [5, 6] | 92 µs [74, 107] | Cepheus, 18 times |
| | 100 | **6 µs** [5, 6.9] | 78 µs [78, 90] | Cepheus, 13 times |
| | 10,000 | **6 µs** [6, 10] | 89 µs [81, 98] | Cepheus, 15 times |
| an invoice, its lines `cascade` | 0 | **11.9 µs** [11, 16] | 120 µs [114, 133] | Cepheus, 10 times |
| | 100 | **176 µs** [167, 186] | 193 µs [174, 200] | about the same |
| | 10,000 | 27.3 ms [26.3, 30.3] | **5.16 ms** [5.06, 5.34] | PostgreSQL, 5.3 times |
| an invoice, its notes' link `clear` | 0 | **11 µs** [4.1, 12.9] | 109 µs [106, 114] | Cepheus, 10 times |
| | 100 | **93 µs** [85, 109] | 723 µs [667, 754] | Cepheus, 7.8 times |
| | 10,000 | **11.1 ms** [10.8, 11.4] | 46.5 ms [45.3, 47.7] | Cepheus, 4.2 times |
| &nbsp;&nbsp;beside: a group of `Retract` of the 20,000 facts of the 10,000 lines | | 21.6 ms [20.7, 22.4] | | |

- **Finding the things that link to a thing** is one lookup in the index by value a link property that names the
  kind, whatever their number: a refusal costs the same at 0, 100 or 10,000 invoices, since it needs one of them.
  PostgreSQL's refusal runs the foreign key's query (`SELECT 1 FROM invoice WHERE client = $1 FOR KEY SHARE`) through
  its trigger machinery, about 80 µs whatever the count.
- **A cascade costs what retracting its facts costs**, plus a quarter for following the links (27.3 against 21.6 ms
  at 10,000 lines): each retraction goes into the writer's persistent maps, about 1 µs a fact. PostgreSQL deletes a row
  by marking it (its `xmax`), with no index touched until `VACUUM`: 0.5 µs a line, 5.3 times faster at 10,000. Making
  Cepheus's large retractions cheaper, as its large additions are (the path of loads), is not built yet.
- **A clear** retracts one fact a note: 1.1 µs a note against PostgreSQL's 4.6 µs, whose `SET NULL` updates each row:
  a new version of it, and of its index entries.
- PostgreSQL's times include the subtransaction that catches a refusal: 11 µs, measured by the same function around a
  read of one row by its key (21 runs); Cepheus's fork costs nothing to make.

**A link that names a kind costs a write almost nothing.** `dbench.exe write`: 200,000 groups of one invoice each
(its link to a client and its total) on a fork, in 5 passes, the median pass; 5 rounds alternated with main before this
work (105735c), built the same way, each on its own copy of the data; PostgreSQL: 10,000 `INSERT`s of a bill row in a
PL/pgSQL loop, rolled back, into a table without a foreign key and one with (`REFERENCES account`), 5 passes.

| one write of an invoice | Cepheus | PostgreSQL 18.6 |
|---|---:|---:|
| a link to any thing (no foreign key) | 3.90 µs [3.80, 4.21] (main), 3.96 µs [3.90, 4.11] (this) | 5.46 µs [5.33, 5.65] |
| a link that names a kind (a foreign key) | **4.17 µs** [4.04, 4.31] | 15.1 µs [14.8, 16.1] |
| the check's cost | 0.2 µs | 9.6 µs |

- The check is one lookup: the linked thing has a fact of one of the kind's properties (the first one it tries, for a
  client). PostgreSQL runs the foreign key's query through a trigger at each row, which triples an insert's cost.
- **Writes are not slower.** Against main, on a database whose schema has no link that names a kind, 11 rounds
  alternated (a load of 2.2 to 2.4): 1.02 times main's time [0.83, 1.16], within the machine's noise; on a schema with
  links, a write of another property: 1.00 [0.94, 1.04], 5 rounds.

## Less, Optional and one shared counter (2026-11-25), at 1 million facts

**Method.** The data of the other sections at 1 M facts (11,363 clients, 227,260 invoices, 56,797 follow links), loaded
by `bench.exe load` and merged into one run; PostgreSQL 18.6 the same rows (`pg.sh load`), with an index on
`invoice (total)` that `pg.sh ops` adds for the range below. The questions: Cepheus `bench.exe pages` in its process
(the engine, up to 8 domains, the rows made as OCaml values); PostgreSQL the execution time of `EXPLAIN (ANALYZE,
TIMING OFF)` (its engine, no row sent; it chose one process for each). 5 rounds, the two sides one after the other in
each, each side a median of 5 calls; given: the median of the 5 rounds, and in brackets their least and largest. The
machine was shared with other jobs' work this time: a load average (1 minute) of 6.2 to 6.5 on its 8 threads during
these rounds, so the numbers are of a busy machine, both sides alike. The data on the SATA SSD (btrfs) of the other sections.
The table of `Less` and `Optional` was measured again on 2026-11-26, after the split past a narrow first level ([the
section above](#questions-split-past-a-narrow-first-level-and-lighter-groups-2026-11-26-at-1-million-facts)), on the same generator's data loaded again, at a load of 2.2 to 3.3; the counter's numbers are of
the 25th.

| question | rows | Cepheus | PostgreSQL 18.6 | |
|---|---:|---:|---:|---|
| the follow links from a client to a newer one, `Less(a, b)`: a check of each link | 28,250 | 8.76 ms [8.41, 9.31] | **3.82 ms** [3.60, 4.14], a `Seq Scan` with its `Filter` | PostgreSQL, 2.3 times |
| &nbsp;&nbsp;the same, every link given and filtered by the program | | 14.2 ms [12.4, 15.4] | | |
| the invoices whose total is below one invoice's, `Less(t, tx)`: a range of the totals' index | 122,962 | 28.0 ms [27.3, 30.7] | **19.0 ms** [18.9, 19.6], a `Bitmap Index Scan` on `total` | PostgreSQL, 1.5 times |
| &nbsp;&nbsp;the same range, its bound read first (`Below` of that total) | | 26.7 ms [25.8, 27.8] | | |
| the 490 clients of city-7 with the clients each follows, `Optional` | 490 | **0.077 ms** [0.069, 0.087] | 0.441 ms [0.428, 0.444], a `Nested Loop Left Join` | Cepheus, 5.7 times |
| &nbsp;&nbsp;the same as a join | | 0.091 ms [0.083, 0.115] | | |
| every client with the clients each follows, `Optional` | 56,797 | 16.7 ms [15.7, 17.7] | **12.5 ms** [12.2, 13.2], a `Hash Right Join` | PostgreSQL, 1.3 times |
| &nbsp;&nbsp;the same as a join | | 18.8 ms [18.2, 19.2] | | |

- **The answers** are the same on both sides (122,962, 490 and 56,797 rows) but for the first: "a < b" compares
  ids, and Cepheus numbers its things in the order the 64 threads of the load wrote them, PostgreSQL by the client's
  number, so the pairs kept differ a little (28,250 against 28,265 of the 56,797 links).
- **`Optional` costs what the join costs** (0.077 against 0.091 ms, 16.7 against 18.8): looking up the thing's
  values after the join is the work the join does at that pattern. Every client here follows at least 4 others, so no
  row is missing: the measure is of the left join's way, not of missing rows. On a city's clients Cepheus is 5.7 times
  faster (its indexes give the 490 clients and their links directly); over every client PostgreSQL's hash join of the
  two tables, read whole in their order, is faster, 1.3 times now (1.8 before the split).
- **`Less` costs less than the program's own filter** (8.8 against 14.2 ms), but PostgreSQL's scan of a table of two
  columns, in one process, reads a row in 70 ns where Cepheus reads the links' index fact by fact and makes each row's
  values.
- **`Less`'s range** reads the 122,962 totals below the bound from the sorted index, as the same range with its bound
  read first does (28.0 against 26.7 ms): split at its second level now, where it ran on one domain before, the
  question being split at its first level only, there the one total of the bound (55 to 57 ms: [the section
  above](#questions-split-past-a-narrow-first-level-and-lighter-groups-2026-11-26-at-1-million-facts)). What is left is making its rows' values, which PostgreSQL's engine does not.

**One counter that 64 writers increment** (tutorials [1](tutorials.md#1-invoice-numbers-with-no-gap) and
[7](tutorials.md#7-a-stock-that-never-goes-below-zero)): each write its own group, forced to the disk, for 5 s; 5
rounds; the load average 5.2 to 6.2. Cepheus: `bench/cesia/write.ce 64 5 counter`, 64 fibers of a Cesia program on
one connection, each group an `Incr` of one counter, against a server of its own on the SSD; beside it the same program
inserting an invoice of 4 facts a group. PostgreSQL: `COUNTER=1 pg.sh write`, pgbench with 64 connections, each
transaction `UPDATE counter SET last = last + 1 WHERE id = 1`; beside it the same pgbench inserting an invoice row.

| 64 writers | Cepheus | PostgreSQL 18.6 |
|---|---:|---:|
| one counter that every write increments | **5,890 a second** [4,578, 7,939], median latency 9.3 ms | 154 a second [8, 214], 231 ms |
| a new row or thing each write, nothing shared | 6,636 a second [5,114, 8,670], 6.9 ms (\*) | 5,387 a second [4,392, 6,557], 9.5 ms |

- PostgreSQL's row lock holds the counter until the transaction's commit is on the disk, so its 64 writers go one
  fsync at a time: 35 times fewer writes than when they share nothing (one round fell to 8 a second, its latency 8.2 s:
  a stall of the disk under the others' load, kept in the range). Cepheus's writer reads the counter as it applies
  each group, and the groups that arrive while the disk works share its next fsync: the counter goes as fast as writes
  that share nothing.
- (\*) In other rounds (5, at a load of 3.1 to 3.4), alternated with the counter, which made 8,632 a second there
  [6,298, 8,801]: a group of the counter is one fact, an insert four.

**Q1 to Q5 are not slower.** Against main before this work (6707b9e), built the same way, on the same data, the two
binaries alternated in each round (`bench.exe read`, 21 runs a question in each), new / old by the median of the
rounds' ratios: in 5 rounds at a load of 7 to 11, Q1 0.92 [0.62, 1.07], Q2 0.95 [0.76, 1.16], Q3 1.17 [0.93, 1.68], Q4
1.04 [0.84, 1.28], Q5 0.98 [0.87, 1.17]; Q3, the widest, again alone in 11 rounds at a load of 2.1 to 2.7: 1.02 [0.98,
1.06] on 8 domains (the least of its runs 274 µs against 277), 1.05 [0.90, 1.33] on one. A question without the new
conditions runs the test of a candidate it ran before them: their checks sit behind a flag that is false for it.

## Backup and restore (2026-11-24), at 10 million facts

**Method.** `bench/ops.sh`, on the machine of the other sections (i7-4720HQ, 4 cores and 8 threads, 11 GB, a SATA
SSD under btrfs, 97 % full that day), under the lock that keeps the machine's other heavy jobs away (other sessions ran
light work beside: a load average of 3); every file in the page cache (warm: the copies read memory, not the disk);
21 rounds, each time the median and its distribution-free 95 % interval. The same data on the three sides: the 10 M
facts of the other sections (113,636 clients, 2,272,720 invoices, the follow links), loaded on Cepheus as an
application writes them (`bench.exe load`, a group a client and its invoices, 64 threads: 227,274 groups in 107 s; the
runs left as the load made them: one run of groups 1 to 223,108 and 4,166 groups in the journal after it), and on
PostgreSQL 18.6 and SQLite 3.54 from the same CSV files.

- **Cepheus**: `cepheus backup` of the running server (no program writing), `cepheus verify` of the copy,
  `cepheus restore` of the copy to its end, and to the group in the middle of its history (`--to-group 113637`: no run
  ends before it, so the open replays groups 1 to 113,637 from the journal, the clients and their invoices, 9.43 M
  facts, merging them into runs as the writer would).
- **PostgreSQL**: its WAL archived (`archive_command = 'cp %p ...'`), a base backup taken before the load (48 MB);
  then `pg_basebackup -X stream -c fast` (plain format, the WAL streamed, a fast checkpoint), `pg_verifybackup` of it
  (each file's CRC-32C against the backup's manifest, and the WAL it needs), its restore (a copy, a start, ready for
  connections), and a point-in-time recovery to the middle of the load's WAL from the base backup taken before the load
  (`recovery_target_lsn`, then promoted): the same work as Cepheus' restore to the middle group, half of the history
  replayed ([continuous archiving and point-in-time recovery](https://www.postgresql.org/docs/current/continuous-archiving.html),
  [pg_basebackup](https://www.postgresql.org/docs/current/app-pgbasebackup.html),
  [pg_verifybackup](https://www.postgresql.org/docs/current/app-pgverifybackup.html)).
- **SQLite**: `.backup` into a new file (the online backup API: "The online backup API allows the contents of one
  database to be copied into another", [sqlite.org/backup.html](https://www.sqlite.org/backup.html)),
  `PRAGMA integrity_check` of the copy ([pragma.html](https://www.sqlite.org/pragma.html#pragma_integrity_check)),
  `.restore` into a new file. SQLite keeps no history: it cannot restore to a point.

| 10 M facts | Cepheus | PostgreSQL 18.6 | SQLite 3.54 | who wins |
|---|---|---|---|---|
| the database | 104.7 MB (journal 33.9, runs 70.8) | 284 MB | 136.4 MB | Cepheus |
| a backup, while it serves | **1.16 s** [0.995, 1.45], 104.7 MB | 22.53 s [15.83, 32.68], 337.9 MB | 1.46 s [1.14, 2.10], 136.4 MB | Cepheus |
| the backup checked | 565 ms [562, 579] | **95 ms** [92, 734] | 2.83 s [2.81, 2.83] | PostgreSQL |
| a restore to the end | **1.61 s** [1.48, 1.93] | 6.45 s [5.93, 7.70] | 2.65 s [2.08, 3.50] | Cepheus |
| the whole history replayed (11 rounds) | 34.87 s [33.67, 36.19], from the journal alone (33.9 MB) | **21.42 s** [12.89, 46.57], from a base backup taken empty (48 MB) and 403 MB of WAL | none | PostgreSQL |
| to the middle of the history (not the same work) | 32.62 s [31.48, 35.56], 9.43 M facts replayed | 21.71 s [16.92, 35.40], half of the load's WAL replayed | none | |

The whole history replayed is the same work on both sides: Cepheus restores a copy whose runs were taken out (the
journal alone, every group replayed: `bench/ops.sh cepheus-replay`), PostgreSQL recovers from the base backup taken
before the load to the end of the WAL archived (`bench/ops.sh pg-replay`; the 2,272,720 invoices there). "The middle"
is not: Cepheus' middle group comes after every client and invoice (9.43 M facts, the follow links after it), where
PostgreSQL's middle LSN is halfway through the bytes of its WAL.

- **Where Cepheus wins.** Its backup is a copy of the files as they are (the journal and the runs are written once and
  never changed), checked: 19 times faster than `pg_basebackup`, whose time is its checkpoint and the copy of 338 MB of
  pages, and a copy 3.2 times smaller (the runs' columns coded in blocks, the journal compressed). Its restore to the
  end opens the newest run and replays the 4,166 groups after it: 4 times faster than PostgreSQL's start on a base
  backup, which redoes its WAL from the checkpoint and forces every page. And a backup needs no archive of logs: the
  journal in the copy holds every group, so a restore to any group needs the copy alone, where PostgreSQL's
  point-in-time recovery needs a base backup older than the target and every WAL file since (1.1 GB archived during
  the 21 rounds).
- **Where PostgreSQL wins.** `pg_verifybackup` checks each file's CRC against the manifest, 6 times faster than
  `cepheus verify`, which also decodes and numbers each of the 227,274 groups and checks every run's tables as an open
  does; the journal is one segment here, checked by one domain (segments are checked in parallel). And its recovery
  replays WAL, physical redo of pages, 1.6 times faster than Cepheus' replay of the whole history (median against
  median; PostgreSQL's interval is wide, [12.89, 46.57] s, its end-of-recovery checkpoint forcing every page on this
  disk): Cepheus replays 227,274 groups one after the other, about 287,000 facts a second, merging them into runs and
  forcing those as the writer would. The histories differ too: PostgreSQL's is a bulk `COPY` (a few transactions),
  Cepheus' 227,274 groups of an application's writes. The next step for Cepheus: replay consecutive small groups as
  one batch, by the path of large groups (sorted arrays, no index update a fact).
- **SQLite** copies its file about as fast as Cepheus (1.46 s against 1.16 s), but checks it 5 times slower
  (`integrity_check` walks every b-tree page) and keeps no history to restore a point of.
- Not measured: the backups taken cold (the copies read from the disk, not the page cache), a backup under writes,
  and a database larger than memory.

## The invoices app's reads after a load, and the first call (2026-11-19)

**Method.** The invoices app's seed (100,000 invoices, 10,000 clients, 2.4 million rows;
[the guide](app.md#14-what-it-costs)), its questions asked as the app asks them, in OCaml alone on the app's local view
(the Cesia side and PostgreSQL are in the guide's table, 21 rounds); the engine before this step against this step's,
alternated, 21 rounds of 1,000 calls each: the median of the rounds' p50 in µs, with its 95 % interval, on the seed
merged into one run.

| question | before | after | what changed |
|---|---:|---:|---|
| a sorted page's keys (5 patterns, 21 rows) | 38.9 [38.1, 38.9] | **23.8** [23.1, 24.1] | its first window holds 21 facts, not 42 |
| the page with its rows' fields | 63.2 [63.2, 64.1] | **47.0** [47.0, 47.9] | the same |
| invoices by a prefix of the bill-to name | 498 [497, 501] | **433** [431, 435] | a row's fields read after the prefix, once: 3,920 candidates → 2,288 |
| clients by name, with their e-mails | 55.1 [55.1, 56.0] | **36.0** [36.0, 36.0] | each name read once a sort, not at each comparison |
| clients by a prefix of the name or of the e-mail | 657 [654, 659] | **396** [395, 397] | the walk gives up after 2 windows instead of 5, then the heap (322 alone) |
| an invoice, its lines | 8.1 | 8.1 | |

**The runs a load leaves.** The seed as its load leaves it holds 5 runs side by side (lazy leveling,
[merges](architecture.md#merges-a-leveled-log-structured-merge-tree)), and every lookup visits each: on the engine
before, one series of 1,000 calls on each, a page took 120 µs against 64 on the same facts in one run, the prefix 1,088
against 515, the total not paid 13.6 ms against 8.4. The server now merges them once its writer has been idle a second
(the 2.4 million rows in about 0.65 s here); the guide's table measures the whole (a page 180 → 115 µs through Cesia).

**A day of sessions in the delta.** 10,000 sign-ins, each its own end: a range on their ends (the visitor's question) is
counted from the sums of the delta's tree in $O(\log n)$ instead of a step a session. A process that connects still
replays them (its first view: 57.7 ms against 55.6, 6 rounds alternated, within their spread): a merge of an idle
writer's delta would remove that replay, and is not built.

**The first call.** The Cesia package's first call (the engine's file fingerprinted, mapped and relocated): 22.30 ms
against 22.48, the ratio 0.990 [0.984, 0.994] (21 rounds of 100 processes, alternated); its file holds 24 KB of code
more for the reads above and 48 KB less since its Cesia glue is compiled with the compiler's default inlining. The
`cepheus` command with no argument: 4.58 ms against 4.55, the ratio 1.004 [1.000, 1.013].

## Questions with operators, an order and pages (2026-11-12), at 10 million facts

**Method.** The data of the other benchmarks (10 M facts: 113,636 clients and their 2,272,720 invoices, of which
453,866 unpaid), one run (a full merge); this branch's release build; `bench.exe pages`, `RUNS` = 21, each a call;
medians, and the least of the 21. The "before" of each is what a program had to do without the operator, in the same
process (no network), so the gain shown is the engine's alone; through the server, the whole answer would also cross
the socket.

| question | with the operator | before it | |
|---|---:|---:|---|
| a page of 20 of the 453,866 unpaid invoices, the largest totals first: index path | 47.0 µs (min 44.1) | 698.6 ms (min 541.1): the whole answer, sorted by the program | 14,900 times |
| the same page by the heap path | 55.8 ms (min 48.4) | | |
| page 101 (after the 2,000th row): index path / heap path | 51.0 µs / 72.3 ms | | |
| the page, the path chosen | 51.0 µs (the index path) | | |
| the 13 clients of city-7 with no unpaid invoice (`Not` of two patterns) | 2.84 ms (min 2.70) | 3.10 ms (min 2.62): two questions and their difference | the same |
| the 11 clients whose e-mail starts with c1234 (`Prefix`) | 10.0 µs (min 8.8) | 30.6 ms (min 26.7): every e-mail, filtered | 3,050 times |

- **The page.** The index path reads the totals' index from the largest down, in windows of 40, 80, ... facts, and
  answers each window's question; the heap path answers the whole question (453,866 bindings) and keeps 20. A page
  deeper costs the same by either: the 101st, 51.0 µs against 47.0. The heap path still saves the sort and the copy of
  the whole answer (55.8 ms against 698.6).
- **Not** reads one lookup a client of the city (about 1,140): a city's clients are few, and the two questions before it
  cost about the same; its gain is one question instead of two, and no answer held to subtract.
- **Prefix** reads the 11 matching e-mails off the text order, two binary searches in the run, against every one of
  the 113,636 e-mails.
- **The questions of before** are not slower: Q1 to Q5 of e333a31's build against this one's, on the same data
  (each a run of its own format), alternated, 3 rounds of 21 runs (Q1 and Q2, 6 more): the least of each, old /
  new: Q1 0.38 / 0.36 µs, Q2 0.61 / 0.60 µs, Q3 2.93 / 3.04 ms, Q4 44.97 / 43.20 ms, Q5 63.3 / 63.7 ms; the medians
  of the rounds go both ways (Q5 115.4 / 85.5 ms, Q4 58.3 / 59.1 ms), on a machine that other work shared. A first
  build made the test of a candidate's range larger and Q5 10 % slower in two rounds of three: the test of a variable
  with no range is again the one it was (an `In` or a `Prefix` gives its variable a range of its own).
- **Watches.** A change under a watch of each operator, against the question answered again in full (`sbench.exe
  watches`: one hub a watch, 21 changes made in memory, each of which changes the watch's rows; medians): `Not` (the
  clients of city-7 with no unpaid invoice; an invoice of one of them unpaid, then paid again) 46 µs against 3.45 ms;
  `Or` (city-7 or one e-mail; a client moved to city-7) 14.1 µs against 104 µs; `In` (city-7 or city-8) 20.0 µs
  against 223 µs; `Prefix` (e-mails starting with c1234; one changed to such an e-mail) 13.1 µs against 17.9 µs, its
  whole answer being 11 rows. A change costs the answers it touches: the frame finds the clients the fact reaches,
  answers the question for them before and after, and sends the difference.
- **Its cost.** The text order adds 4 bytes a distinct text to a run: the 10 M-fact run 68 MB against 67 MB in
  format 8. A full merge of the base: 2.3 s. The first open of data of format 8 sets its runs aside and replays the
  journal: 5.9 s, once.

## The open's reads in the file's order (2026-11-12), at 10 million facts

The database of 10 million facts loaded in 4 large groups (`GROUP=56818`, one thread), then `snapshot`: one run of
69.6 MB (4,212 file pages). With a 32 MB cache the run does not fit, and the open checks its tables: 327 pages (5.4
MB) in 229 stretches of the file. Before, the checks read them one at a time as they came to them; now they are read
first, in the file's order, the file pages that follow one another in one read, by 4 domains. A run that fits in the
cache (the default 1 GiB) is read whole the same way. The open of `bench.exe read` (`CEPHEUS_DOMAINS=1`, a 128 MB
scope for the 32 MB cache, 3 GB for 1 GiB), cold: the files' pages dropped from the system's cache first; 21 rounds,
the two binaries in turn; medians with their 95 % interval, and the median of the per-round ratios:

| open | before (3f8d8e8) | after | after / before | after faster |
|---|---|---|---|---|
| 32 MB cache, cold | 126.1 ms [120.5, 129.6] | **70.0 ms** [69.3, 71.0] | 0.570 [0.544, 0.593] | 21/21 |
| 32 MB cache, warm | 18.6 ms [17.8, 20.0] | **17.4 ms** [16.9, 17.7] | 0.933 [0.914, 0.994] | 16/21 |
| 1 GiB cache, the run read whole (50 to 53 MB from the disk) | 199.5 ms [190.4, 208.2] | **169.4 ms** [167.9, 171.5] | 0.858 [0.806, 0.895] | 21/21 |

The disk reads 16.7 to 19.7 MB for the 5.4 MB the cold open needs: the system's read-ahead. Damage is found where it
was: every page the open reads is checked by its CRC before it enters the cache, and the checks are the same; a
damaged page among the tables now sets the run aside even where the checks would not have looked at its bytes (the
unit tests' 12 flipped bits: 1 refused at open and 11 found at a read, against 0 and 12).

## Chunked loads (2026-11-12), at 10 million facts

A load written as groups of 5,000 clients (about 415,000 facts a group, 23 groups of clients and 23 of their follows)
by two threads (`bench.exe load` with `GROUP=5000 THREADS=2 CACHE_MB=64`), then `snapshot`, against main before the
change (leveling for large groups, and a merge that looked at every source's head for each row), $n = 7$ rounds
alternated, each run on a quiet machine (IO and CPU pressure under 5 and 10 %), in a 3 GB scope; the median and its
interval, here the least and the greatest run (98.4 %):

| | before | after |
|---|---:|---:|
| every group confirmed, s | 18.17 [15.26, 27.21] | 9.81 [8.09, 11.37] |
| of which the clients' groups, s | 10.37 [9.39, 11.78] | 6.44 [5.69, 8.62] |
| of which their follows, s | 6.40 [5.87, 16.02] | 2.82 [2.27, 4.24] |
| a large group merged into its run, p50, ms | 122 [119, 142] | 62 [62, 64] |
| the largest of them, ms | 2,111 [2,061, 9,599] | 1,601 [1,541, 1,775] |
| runs before the snapshot | 2 | 15 |
| `snapshot`, s | 2.38 [1.98, 5.09] | 3.18 [2.81, 3.59] |
| load and snapshot, s | 21.87 [17.24, 29.38] | 12.99 [11.29, 14.40] |
| peak resident memory, MB | 270 [252, 281] | 292 [258, 306] |

The groups are confirmed 1.9 times faster: each group's run is written once, beside the others, instead of being
merged again with the runs before it level after level; the 16th group merges the tier in one pass (the largest
merge, 1.6 s). The snapshot then merges 15 runs instead of 2 and takes 0.8 s more, which the heap of cursors keeps
small (before it, the first rounds' snapshot of 15 runs took 6.2 s). The peak grows by 22 MB (the 15 runs' tables
held in memory, most likely; not measured apart). Reads between the load and its snapshot visit every run: at 1 million facts loaded the same way (8 runs
against 2, $n = 3$), a client by e-mail 1.40 µs against 0.73, the unpaid invoices of a city 763 µs against 425; the
same answers on both sides, and each binary opens and reads the other's database.

Not reached, of the plan's step 4: a peak of 150 MB whatever the load's size (292 MB here: the two groups' lists of
operations in flight, about 70 MB each, the 64 MB cache, and the compact arrays of a group), and 10 million facts in 3
s (each group of 415,000 facts pays its own resolution, merge and fsync: 46 frames; the same 10 million facts in two
groups load in 4.1 to 5.6 s, at a peak of 1.46 GB: [api](api.md#writing)).

The same 10 million facts in 4 large groups (`GROUP=56818`, one thread), then `snapshot`, $n = 5$ alternated: every
group confirmed in 5.12 s [4.28, 6.95] against 5.93 [5.58, 6.98], a peak of 862 MB [808, 967] against 987 [929, 1,006];
the snapshot merges the 4 groups' runs instead of 2 and takes 2.52 s [2.30, 2.71] against 2.14 [2.01, 2.29]. An open
of the database it leaves, its pages dropped from the system's cache, with a 32 MB cache ($n = 7$): 124 ms [113, 133]
against 129 [110, 166], reading 16.7 MB both; 19.7 and 19.3 ms when the system's cache holds them, so most of a cold
open is the disk's latency on the tables' pages, read one at a time. Neither the snapshot's cost of the third order
nor the cold open changed with this work.

## Live questions (2026-11-11), at 1 million facts

`cepheus.Watch` and `Watch` on the wire, against main before them (the commit of the column order), on the server's
database of 1 M facts, each side on a server started from the same copy of it, $n = 7$ rounds alternated (method above).
The whole tables are in [server](server.md#what-a-watch-costs) and [Cesia](cesia.md#what-it-costs).

| | before | after | the ratio within each round, after / before |
|---|---:|---:|---:|
| the server's start (ready), ms | 174 [122, 847] | 143 [126, 178] | 0.91 [0.15, 1.09] |
| an empty round trip (Ping), µs | 8.86 [7.55, 11.13] | 9.40 [7.93, 11.47] | 0.93 [0.76, 1.50] |
| a point read at the server (Get), µs | 8.79 [7.64, 12.27] | 8.85 [7.70, 9.49] | 1.00 [0.64, 1.16] |

A program that uses the package without calling it (`cesia run` of `io.Print(1)` with the package's `use`, $n = 51$
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
| load in 2 large groups, to confirm every group | 3.86 s [3.33, 5.80] | 3.93 s [3.71, 4.33] | 1.005 ($p = 1.0$: no difference shown) |
| load in 4 large groups (`GROUP=56818`) | 5.62 s [4.83, 6.16] | 5.75 s [5.04, 7.14] | 0.967 ($p = 1.0$) |
| a large group merged into a run (the longest) | 1.13 s [1.10, 1.39] | 1.33 s [1.31, 1.48] | 1.173, slower 6 of 7 ($p = 0.13$) |
| peak resident memory, 2 groups | 1,599 MB | 1,590 MB | 0.994 |
| peak resident memory, 4 groups | 953 MB [860, 1,130] | 911 MB [872, 994] | 0.956 ($p = 0.45$) |
| the runs after `snapshot` (one run) | 54.4 MB | 69.6 MB | 1.280: +15.2 MB (the column order 13.9 MB) |
| the journal | 21.8 MB | 21.8 MB | the same |
| `snapshot` (a full merge) | 1.65 s [1.53, 1.83] | 2.00 s [1.90, 2.46] | 1.242, slower 7 of 7 ($p = 0.016$) |
| open of the database it leaves | 54.0 ms [51.5, 58.3] | **46.1 ms** [38.7, 52.1] | 0.795, faster 6 of 7 ($p = 0.13$) |
| Q1 an invoice by id | 0.44 µs [0.40, 0.46] | 0.46 µs [0.39, 0.61] | 1.095 ($p = 1.0$) |
| Q2 a client by e-mail | 0.74 µs [0.67, 0.80] | 0.69 µs [0.63, 0.80] | 0.940 ($p = 0.45$) |
| Q3 unpaid invoices of a city | 4.28 ms [4.13, 4.44] | **2.92 ms** [2.84, 3.24] | 0.688, faster 7 of 7 ($p = 0.016$) |
| Q4 unpaid sum by city, 8 domains | 88.7 ms [84.9, 104] | **44.0 ms** [42.6, 44.5] | 0.500, faster 7 of 7 |
| Q5 triangles, 8 domains | 294 ms [266, 325] | **68.5 ms** [64.2, 87.9] | 0.233, faster 7 of 7 |
| Q4, 1 domain | 253 ms [248, 285] | **131 ms** [129, 133] | 0.518, faster 7 of 7 |
| Q5, 1 domain | 1.18 s [1.15, 1.28] | **0.271 s** [0.256, 0.297] | 0.224, faster 7 of 7 |
| 1 M facts, a group a client, 64 threads | 8.01 s [7.64, 9.24] | 8.06 s [7.27, 9.92] | 1.006 ($p = 1.0$) |
| its peak | 200 MB [175, 222] | 212 MB [194, 224] | 1.053, larger 6 of 7 ($p = 0.13$) |

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

**Where the giants still win.** SQLite loads in 11 MB of memory against 1.6 GB (chunked loads came the next day:
[above](#chunked-loads-2026-11-12-at-10-million-facts)). Its cold open is a file open. PostgreSQL does not win a
question here any more; it is a server with its own processes, which Cepheus' numbers above do not include (Cepheus'
server is measured in [server](server.md)).

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
| load in 2 large groups, to confirm every group | 4.26 s [3.82, 4.62] | **3.44 s** [3.32, 4.48] | 0.855, faster 7 of 7 ($p = 0.016$) |
| load in 4 large groups (`GROUP=56818`) | 5.74 s [5.22, 8.70] | **4.64 s** [4.42, 6.32] | 0.803, faster 6 of 7 ($p = 0.13$) |
| peak resident memory, 2 groups | 1,460 MB | 1,600 MB | 1.096 (the frame coded in memory, 21.6 MB, and the coder's buffers) |
| peak resident memory, 4 groups | 1,196 MB [860, 1,389] | **984 MB** [878, 1,080] | 0.804 |
| the journal | 99.6 MB | **21.8 MB** | 0.219 |
| the runs after `snapshot` (one run) | 246.4 MB | **54.4 MB** | 0.221 |
| journal and runs after `snapshot` | 346.1 MB | **76.2 MB** | 0.220 |
| `snapshot` (a full merge) | 1.99 s [1.51, 2.70] | 1.62 s [1.54, 2.64] | 0.811 ($p = 0.45$) |
| open of the database it leaves | 197 ms [194, 240] | **53.5 ms** [52.8, 54.3] | 0.271, faster 7 of 7 |
| Q1 an invoice by id | 0.36 µs [0.34, 0.40] | 0.38 µs [0.36, 0.39] | 1.056 ($p = 0.45$: no difference shown) |
| Q2 a client by e-mail | 1.58 µs [1.53, 1.64] | **0.65 µs** [0.64, 0.66] | 0.411, faster 7 of 7 |
| Q3 unpaid invoices of a city | **3.59 ms** [3.56, 3.78] | 3.97 ms [3.92, 4.01] | 1.095, slower 7 of 7 |
| Q4 unpaid sum by city, 8 domains | **79.9 ms** [78.8, 80.6] | 82.4 ms [81.9, 83.0] | 1.031, slower 7 of 7 |
| Q5 triangles, 8 domains | **248 ms** [243, 257] | 264 ms [262, 266] | 1.072, slower 7 of 7 |
| Q4, 1 domain | **231 ms** [230, 236] | 241 ms [239, 243] | 1.038, slower 7 of 7 |
| Q5, 1 domain | **1.02 s** [0.98, 1.05] | 1.10 s [1.07, 1.14] | 1.098, slower 7 of 7 |
| 1 M facts, a group a client, 64 threads | 8.25 s [7.94, 9.10] | 7.93 s [7.23, 9.05] | 0.962 ($p = 0.45$: the same) |
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
clients and 122 invoices), so the triangles touch the 23.5 MB of thing blocks at random. Reading Q5 from the rows by
property, where the 568,163 follow links lie together, came two days later with the column order and a join that walks
them ([above](#the-column-order-and-leapfrog-intersections-2026-11-11-at-10-million-facts)).

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

## Rules, step 5's targets again: a change's install without a record a fact (2026-11-19)

The lever the measures below pointed at ([rules](rules.md#changes-of-the-rules-in-the-background)): at the install,
each of the run's derived facts became a change record and a value, made by the writer, then coded for the frame
(`Group.encode`: a hash lookup a change for its column), while no group was confirmed. Now the writer codes the frame
straight from the run's columns (`Group.encode_parts`: the group's records, then the run's facts read by index), the
same bytes, its four columns (kinds, things, columns, values) on several domains past 65,536 changes; the watches,
which need the changes one by one, make the run's records on their own domain (`Engine.whole`). And what the profile
showed next: the writer installs a ready change before its next batch (the batch stops at it, so that the install's
last catch-up holds the groups of the background's last pass, not up to 256 more), and joins the change's domain
after the install; the reasoner's programs of a new rule set are made outside the lock that every writer group takes
for a moment (a change's 95 rules took 15 to 22 ms to compile and unfold under it, which the writer waited through);
and the journal's column coder fills a block and finds its two ranges in one pass and packs fields of up to 31 bits by
a running word (135,000 values: 0.92 to 0.69 ms constant, 1.28 to 1.03 ascending, 1.45 to 1.25 random; the same bytes,
which a test checks against the format's plain coder).

**Where the install went** (main a61dd80, one run each with timers, 5 runs on the disk): the groups logged since the
change was ready caught up, 6 to 10 ms (102 to 224 groups); the run's facts made records, 9 to 11 ms; gathered into one
array, 1.5 to 3; coded, 15 to 27: 35 to 48 ms, 2.0 to 2.8 M words allocated, 9 to 13 minor collections. **Where it goes
now** (8 runs): the catch-up 0 groups in four runs and 90 to 188 (5 to 11 ms) in the four others, the groups that came
during the background's last pass (its thresholds, 64 groups or 5 ms, unchanged: a tighter one could keep a loaded
background from ever being ready); the records of the asserted part and the table, 0.3 to 1 ms; the coding, 6 to 14 ms
(once 26) beside 256 writers (alone on a quiet machine, the install's shape: 4.3 ms on four domains, 5.8 ms on one; most of what
is left is numbering the columns and texts in order of first use and sorting the values by column, on one domain);
from the change ready to its install, 0 to 2 ms (up to 17 before). The frame itself is small (35 to 41 KB for 131,000
to 144,000 facts: thing deltas, one column, one value), so its write and fsync are an ordinary frame's.

**Method.** The same change as below, `CHANGE=one reason.exe change 10 256 8 2 with|without DIR`, 21 pairs (with,
without) for main a61dd80 and this branch, alternated, in one hold of the heavy lock, each run in a 3 GB scope, twice:
on the disk, and in a tmpfs folder (`/dev/shm`), where an fsync waits for nothing, so that no stall of the disk enters
the measure and the writers are bound by the processor (about 13,000 groups a second against 9,000 to 11,000 on the
disk). On the disk, the journal's fsync stalls for 0.1 to 0.5 s once or twice a run (btrfs at 99 % full, shared with
other jobs' writes; the profiled runs logged every fsync over 100 ms), in runs with and without the change alike, which
swung a pair's window ratio from 0.03 to 18 in the series below. So beside the paired ratio (the change's window with /
the same window without), each window is set against the **median** of every window of the same length in the run
without the change (from 1 s to 7.5 s, sliding by 10 ms), which a stall cannot move; the writer time lost is that
median's groups less the window's, at its rate; the whole run is the median 250 ms window from the change's start, with
/ without, and $1 - \text{lost} / \text{time}$, the window's loss over the 6 s that follow its start. A cell is the
median over the pairs with its distribution-free 95 % interval ($[x(6), x(16)]$ of 21).

| what (21 pairs) | main, disk | this branch, disk | main, tmpfs | this branch, tmpfs |
|---|---:|---:|---:|---:|
| the writer's part at the install | 33 ms [28, 38] | **10 ms** [8, 15] | 41 ms [37, 43] | **21 ms** [17, 24] |
| the change, from `define` to its answer | 0.213 s [0.174, 0.246] | 0.221 s [0.160, 0.288] | 0.545 s [0.499, 0.649] | 0.581 s [0.527, 0.646] |
| its build (about 135,000 derived facts) | 0.050 s [0.045, 0.056] | 0.048 s [0.043, 0.054] | 0.055 s [0.051, 0.059] | 0.056 s [0.050, 0.060] |
| its run of its own | 0.026 s [0.023, 0.029] | 0.025 s [0.024, 0.027] | 0.031 s [0.029, 0.035] | 0.030 s [0.029, 0.033] |
| derived facts a second, the build and the run | 1.82 M [1.64, 1.89] | 1.84 M [1.72, 1.90] | 1.77 M [1.72, 1.86] | 1.78 M [1.71, 1.88] |
| the writers in the window, paired | 0.72 [0.49, 0.93] | 0.65 [0.25, 1.46] | 0.77 [0.75, 0.80] | **0.83** [0.81, 0.87] |
| the writers in the window, against the median window | 0.67 [0.49, 0.83] | 0.75 [0.31, 1.05] | 0.84 [0.81, 0.87] | **0.92** [0.88, 0.94] |
| the writer time lost in the window | 83 ms [37, 102] | 40 ms [-14, 109] | 97 ms [68, 119] | **49 ms** [35, 78] |
| the whole run, paired | 0.89 [0.71, 1.15] | 0.87 [0.74, 1.02] | 0.92 [0.91, 0.93] | 0.91 [0.90, 0.93] |
| the whole run, against the median window | 0.93 [0.72, 1.09] | 0.95 [0.82, 1.02] | 0.92 [0.91, 0.97] | 0.92 [0.91, 0.95] |
| the whole run, $1 - \text{lost} / \text{time}$ | 0.986 [0.983, 0.994] | 0.993 [0.982, 1.002] | 0.984 [0.980, 0.989] | **0.992** [0.987, 0.994] |

- **Reading it.** In tmpfs, with no stall (none of 250 ms in any window, against 3 to 5 on the disk), the intervals
  are narrow: the writers lose half as much in the change's window as on main (49 ms against 97), its window ratio goes
  from 0.77 to 0.83 paired. The ratio against the median window reads higher (0.92) because a run's throughput falls over
  its 8 s as its delta grows (14,000 groups a second at first, 12,000 by the end), so the median of [1, 7.5] s is below
  the rate at 2 s; with no stall, the paired ratio is the fair one. On the disk the stalls still decide a pair, but the
  medians agree: 40 ms lost against 83. Over the whole run the two binaries are alike in tmpfs, 0.91 to 0.92: after the
  change every student written derives one fact more under 95 rules instead of 94, about 8 % more of the writer's work
  for every later group, which the disk's fsyncs hide (0.95 there); the change's own cost, the window's lost time over
  the run, is under 1 % (0.992).
- **Against the step's targets**: the writers in the change's window at 0.90 of a run without it: **0.92 against the
  median window in tmpfs**, 0.83 paired (missed; main 0.84 and 0.77); over the whole run at 0.96: 0.992 for the change's
  own loss, 0.91 to 0.95 with the work the new rule adds to every later write (missed: that part is the rule's, not
  the install's); 2 M derived facts a second with the run's write: 1.84 M (missed: the build is 2.87 M a second, the
  run's write of 135,000 facts takes 25 ms of the 73).
- **The second lead** (the unfolding of the new rules, which checked the static types again for each binding): the
  build moves by 2 ms at most (0.050 and 0.048 s, within the intervals): the types were not most of the unfolding
  here; what is left of the programs' 15 to 22 ms is the unfolding's other work and its reachability checks.
- **The same derived facts** (no writer, so that both runs are the same; each database then read whole by one
  binary): the axiom over LUBM-10, 2,006,283 facts of which 651,629 derived, digest `3d3ea1921e042` on both sides; the
  94 rules defined over LUBM-1 without rules, 210,869 facts of which 60,526 derived, `67123592f6fa` on both. With no
  writer, the axiom's build is 0.022 s and its run 0.018 to 0.019 s on both sides (119,424 derived facts: 2.9 M a
  second with the run's write), its install 21 ms on main and 6 ms here; the 94 rules' install 14 and 6 ms; `define 1`
  (the 94 rules inline on a fork) 0.199 and 0.197 s.
- **Start-up** (21 rounds of 100 runs, alternated, each binary in 7 copies taken in turn): `bench.exe` 2.575 ms on
  main, 2.564 ms here (paired 1.001 [0.970, 1.005]); `cepheus` (`bin/main.exe`) 4.577 ms and 4.604 ms (paired 1.005
  [0.993, 1.012]): no change measured (both intervals hold 1).

## Rules, step 5's targets again: a change's facts no rule reads, made facts by one sort (2026-11-18)

The lever the measures below pointed at ([rules](rules.md#changes-of-the-rules-in-the-background)): a change keeps
the heads of its **sinks** (rules whose facts no rule reads) in a buffer, sorts them once at the end of its reasoning
(a natural merge of the few ascending runs they come in, a radix sort past 64), keeps the first of each fact, sets
aside those the view or the working set holds, and writes the others to its output in thing order, never into the
working set.

**Where main's build went** (main 5de6b66, one run each with timers, the same change as below, 3 runs): 0.13 to 0.20 s
= the programs 0.015 to 0.020, the added rule's instances 0.096 to 0.149 (of which reading the view's facts alone
0.016: the rest, about 0.8 µs a head, is putting each head into the working set: a probe, its slot, three chains, the
tables' growth by doubling), the derived facts set apart 0.008 to 0.014 (a search of the delta a fact), the rest
under 0.01; its run of its own 0.023 to 0.036 (a sort when the heads did not come in thing order, 0.001 to 0.012).
**Where it goes now** (the same timers): the instances read 0.014 to 0.017, their heads kept 0.005 to 0.010, sorted
0.0003 to 0.0024 (one run at 0.008), made facts 0.0015 to 0.0023, set apart 0.0012 to 0.0020 (one search of the
delta a (property, value)); the programs 0.014 to 0.024, almost all of it the rules unfolded on small relations
for the writer's next groups (the unfolding 0.008 to 0.013, its checks 0.004 to 0.009); the run of its own
0.020 to 0.029 (no sort: the facts come sorted; the merge's write 0.017 to 0.025).

**Method.** As below: `CHANGE=one reason.exe change 10 256 8 2 with|without DIR`, the rule `[x type Person] -> [x
type Schedule]` defined over LUBM-10 with the 94 rules on the disk while 256 clients write graduate students
durably; 21 pairs (with, without) for main 5de6b66 and for this branch, alternated, in one hold of the heavy lock,
each run in a 3 GB scope. A cell is the median with $[x(1), x(n)]$.

| what (21 pairs) | main 5de6b66 | this branch |
|---|---:|---:|
| the change, from `define` to its answer | 0.543 s [0.315, 0.905] | **0.311 s** [0.164, 2.83] |
| its build (about 135,000 derived facts) | 0.168 s [0.093, 0.209] | **0.053 s** [0.032, 0.070] |
| its run of its own: written, not forced | 0.033 s [0.021, 0.044] | **0.025 s** [0.020, 0.032] |
| derived facts a second, the build | 0.80 M [0.67, 1.30] | **2.57 M** [1.97, 3.77] |
| derived facts a second, the build and the run | 0.67 M [0.58, 1.06] | **1.73 M** [1.44, 2.32] |
| the writer's part at the install | 32 ms [21, 61] | 36 ms [23, 51] |
| the clients' throughput in the change's window, with / without | 0.93 [0.06, 18.7] | 0.50 [0.03, 1.00] |
| the same over the whole run from the change's start | 0.96 [0.77, 2.34] | 0.93 [0.11, 5.43] |

- **The same derived facts** (no writer, so that both runs are the same; each database then read whole by one
  binary): the axiom over LUBM-10, 2,006,283 facts of which 651,629 derived, digest `3d3ea1921e042` on both sides;
  the 94 rules defined over LUBM-1 without rules, 210,869 facts of which 60,526 derived, `67123592f6fa` on both.
  With no writer, the axiom's build is 0.086 s on main and 0.024 s here (119,424 derived facts: 1.4 M and 5.0 M a
  second; 1.1 M and 2.8 M with the run's write).
- **Changes with few sinks** (11 pairs, alternated): the 94 rules defined inline on a fork of LUBM-1 (`reason.exe
  define 1`, its rounds on several domains), 0.230 s on main and 0.210 s here (paired 0.97 [0.69, 1.22]); the same
  rules on the background path with no writer (`CHANGE=all ... change 1 0 2 1`), build 0.105 and 0.104 s: no change.
  A round on several domains makes a sink's heads facts by regions of the working set, as before: pushed and sorted on
  one domain, the inline define was no faster (paired 1.03 [0.86, 1.94]).
- **Against the step's targets**: 2 M derived facts a second: **2.57 M for the build** (1.97 at its least), 1.73 M
  with its run's write (missed; 2.32 at best); the writers within 10 % of their throughput without the change: missed,
  0.50 in the change's window and 0.93 over the run from its start (main 0.93 and 0.96 in this series). The window is
  0.2 to 0.3 s now, and it holds the install: the writer's own part (36 ms) and the change's frame of 135,000 derived
  facts written and forced, about 40 to 60 ms with no group confirmed (the bins of 10 ms show it). Main's window
  ratio is the median of pairs as far apart as 0.06 and 18.7: in five of its 21 pairs the run without the change
  stalled inside the window (ratios 4.7 to 18.7), as a merge's switch does (no merge runs beside a change), which a
  window of 0.5 to 0.7 s holds more often. The next levers: the install's frame (each of R's facts becomes a change record and a value for the frame,
  allocated by the writer, then encoded), and, in the build, the unfolding of the new rules on small relations.
- **Start-up** (21 rounds of 100 runs, alternated, each binary in 7 copies taken in turn): `bench.exe` 2.664 ms on
  main, 2.688 ms here (paired 0.999 [0.983, 1.020]); `cepheus` (`bin/main.exe`) 4.779 ms and 4.711 ms (paired 0.986
  [0.981, 0.993]): it does not grow.
- **Beside the giants** (their papers; step 3's table): RDFox 2014 [Motik 2014] derives 0.67 M facts a second on one
  thread and 6.1 to 7.0 M on 16 to 32 threads of two 8-core Xeons; this change's build, 2.6 M a second on one domain beside 256
  durable writers, is about four times RDFox's one-thread rate and below its parallel one; with the run's write, 1.7 M.

## Rules, step 5's targets: a change's derived facts in a run of their own (2026-11-18)

The rest of step 5 ([rules](rules.md#changes-of-the-rules-in-the-background)): a large change of the rules writes the
derived facts it adds as a run of their own, provisional, under its view's delta, instead of putting them into the delta
one by one; the catch-up holds them in its table of differences only once a group written meanwhile touches them.

**Method.** Step 5's ([below](#rules-step-5-changes-of-the-rules-in-the-background-2026-11-13)): `CHANGE=one reason.exe
change 10 256 8 2 with|without DIR` (release build), the rule `[x type Person] -> [x type Schedule]` defined over
LUBM-10 with the 94 rules on the disk (1.89 M facts) while 256 clients write graduate students durably; 21 pairs (with,
without) for main 8445b4a and for this branch, alternated, in one hold of the heavy lock, each run in a 3 GB scope. A
cell is the median with $[x(1), x(n)]$; a rate is the change's derived facts over its build (and over its build and its
run's write); a throughput ratio is a pair's.

| what (21 pairs) | main 8445b4a | this branch |
|---|---:|---:|
| the change, from `define` to its answer | 1.54 s [0.66, 12.5] | **0.60 s** [0.34, 1.45] |
| its build (about 140,000 derived facts) | 0.308 s [0.233, 0.433] | **0.159 s** [0.088, 0.206] |
| its run of its own: sorted and written, not forced | | 0.033 s [0.020, 0.042] |
| derived facts a second, the build | 0.45 M [0.35, 0.52] | **0.86 M** [0.69, 1.38] |
| derived facts a second, the build and the run | 0.45 M [0.35, 0.52] | **0.72 M** [0.58, 1.12] |
| the writer's part at the install | 53 ms [37, 74] | **34 ms** [20, 42] |
| the clients' throughput in the change's window, with / without | 0.61 [0.001, 1.09] | **0.87** [0.05, 5042] |
| the same over the whole run from the change's start | 0.76 [0.001, 3.18] | **0.78** [0.44, 2.17] |

Where main's build goes (one run with timers): 0.32 s = the programs 0.015, the added rule's instances 0.096, the list
of derived facts 0.029, putting them into the delta 0.149, the checks 0.020. The run of its own replaces the delta's
part by its sort and write (0.03 s), and the checks after the rounds now read only the facts of one-valued or unique
properties.

**A variant: the background on several domains** (the added rule's instances in morsels on every thread, as in the
writer's own groups; 21 pairs against this branch, the same method): the same build (0.168 s on both sides), and the
clients' throughput lower beside it (0.50 in the change's window and 0.84 over the run, against 0.83 and 0.86). A rule
of one atom has little join work to share, and its heads are made facts by one domain either way: the background stays
on its own domain, as step 5 found.

- **Against the step's targets**: 2 M derived facts a second on 8 threads: 0.72 M with the run's write, 0.86 M for the
  build alone (missed: the change reasons on its own domain, and its rounds read the view fact by fact); the writers
  within 10 % of their throughput without the change: 0.87 in the change's window (missed; 0.61 on main), 0.78 over the
  run from its start (missed; 0.76 on main; another series of 21 pairs of the same code, the same day, gave 0.83 and
  0.86). The window is short now (0.34 to 1.45 s), and one stall on either side of a pair moves its ratio a lot.
- **Start-up** (21 rounds of 100 runs, alternated, each binary in 7 copies taken in turn): `bench.exe` 2.996 ms on main,
  2.998 ms here (paired 1.000 [0.984, 1.008]); `cepheus` (`bin/main.exe`) 4.899 ms and 4.922 ms (paired 1.007 [0.992,
  1.021]): no change measured (both intervals hold 1).
- **Beside the giants** (their papers; step 3's table): RDFox 2014 [Motik 2014] derives 0.67 M facts a second on one
  thread and 6.1 to 7.0 M on 16 to 32 threads of two 8-core Xeons; this change's 0.72 M a second, on one domain beside
  256 durable writers, is about RDFox's one-thread rate, far below its parallel one.

## Rules, step 6: OWL 2 RL, and equality by rewriting (2026-11-14)

The sixth step of the reasoner ([rules](rules.md#owl-2-rl-a-library-of-rules)): OWL 2 RL as a library of rules
(`Cepheus.Owl`: its vocabulary, every rule of the W3C's tables, templates over lists), and equality (owl:sameAs) by
classes of equal things and the rewriting of their facts.

**Method.** `bench/reason.exe` (release build) of the step 3 branch eb264f0 (`bulk`, where this step started) and of
this branch, each built from its own source. 21 rounds alternated (the order turned each round), a round in one hold of
the heavy lock, every process in a 3 GB scope; a cell is the median with $[x(1), x(21)]$; a ratio is the median of the
paired ratios with their range. The machine was shared with other jobs' processes outside the lock. Commands:
`reason.exe w3c|owl 1 groups -` (LUBM-shaped, one university, a group a department, in memory),
`reason.exe w3c|owl 10 bulk DIR` (ten universities, one load, durable), `reason.exe uobm 1 rew|ax|plain`,
`reason.exe storm N`, `reason.exe reads`, `bench.exe` (start-up).

**OWL 2 RL whole against step 2's W3C rules** (the target: as fast). `owl`: the univ-bench ontology written in the
library's vocabulary, the library's rules (63 rules as written, the equality ones among them); `w3c`: the same ontology
as facts with the ten W3C rules step 2 measured (cax-sco, scm-sco, prp-dom, prp-rng, prp-spo1, prp-inv1, prp-inv2,
prp-trp, cls-svf1, cls-int1 over two members). The same 532,205 derived facts of the data on both sides.

| LUBM-shaped | step 3 eb264f0, w3c | this branch, w3c | this branch, owl | owl / w3c |
|---|---:|---:|---:|---:|
| one university, a group a department (in memory): reasoning | 0.246 s [0.224, 0.279] | 0.247 s [0.226, 0.272] | **0.277 s** [0.262, 0.359] | 1.15 [1.01, 1.34] |
| the same, the whole run (data made, written, reasoned) | 0.617 s | 0.615 s | 0.638 s | 1.06 [0.92, 1.26] |
| derivations / derived facts | 237,731 / 74,710 | 237,731 / 74,710 | 252,120 / 74,768 | |
| ten universities, one load, durable: the load | 1.795 s [1.709, 2.790] | 1.816 s [1.686, 2.776] | **1.750 s** [1.691, 3.277] | 0.98 [0.61, 1.68] |
| its reasoning | 0.533 s [0.481, 0.920] | 0.543 s [0.484, 0.607] | **0.512 s** [0.442, 0.532] | 0.92 [0.79, 1.09] |
| derivations / derived facts | 2,147,932 / 658,865 | 2,147,932 / 658,865 | 2,274,854 / 658,923 | |

The groups' row is the second series (21 rounds, after the last change to the unfolding: prp-npa2, whose value is a
text, is no longer run on every fact while the ontology has no negative assertion: owl / w3c was 1.20 before); the
loads' rows the first series (21 rounds). On a load OWL 2 RL whole reasons faster than the ten rules (its unfolded
program holds fewer rules: the reductions below); group by group it costs 15 % more reasoning, 6 % more of the whole
run: the 6 % more derivations, and the constraints (cls-nothing2, eq-diff1), whose plans the group's facts are run
through after the fixpoint.

The library derives a few more facts and makes 6 % more derivations: cls-int2 gives each member of a defined class the
type of its restriction (`Student ⊓ ∃takesCourse.Course`), which cls-svf1 gave already; the W3C rules step 2 measured
leave cls-int2 out. On the way, three kinds of unfolded rule are now left out, for both forms: a rule whose head is one
of its patterns (cax-sco over the reflexive `[r subClassOf r]` that scm-svf1 gives each restriction), two rules that are
the same edge (cax-sco over scm-int's facts and cls-int2), and a rule whose class follows from a sibling's by the
subclass edges (prp-dom over the domains scm-dom1 adds up the hierarchy): 3.35 M derivations before, 2.27 M after (step
2's rules: 2.15 M).

**Equality, UOBM-like.** LUBM-shaped data (one university) where a quarter of the people are recorded 2 to 4 times
(6,558 records more: the same e-mail, half the person's facts each), the e-mail inverse functional (prp-ifp); UOBM
(Ma et al. [Ma 2006]) adds such equalities to LUBM, and Motik et al. [Motik 2015b] measured rewriting against the
axiomatised equality on it. `rew`: OWL 2 RL whole, equality by the classes; `ax`: the same rules, their equalities
written as `owl/SameAs` facts, with eq-sym, eq-trans, and eq-rep-s and eq-rep-o once for each property (eq-ref left
out: it would only make `ax` larger). Read through their classes (each fact's things as their class's least member),
the two give the same 217,232 facts (the digest of their values is equal): an independent check of the rewriting at
scale. `plain`: the same data with no inverse functional property, nothing made the same.

| one university, 6,558 records more | rew (rewriting) | ax (axiomatised) | rew / ax | plain (no equality) |
|---|---:|---:|---:|---:|
| reasoning | **1.066 s** [1.040, 1.126] | 1.957 s [1.902, 2.117] | **0.54** [0.51, 0.59] | 0.364 s [0.357, 0.452] |
| the 24 groups written | **1.523 s** [1.484, 1.622] | 2.405 s [2.341, 2.622] | 0.63 [0.59, 0.68] | 0.822 s |
| of which the merges (classes made, facts rewritten) | 0.261 s [0.256, 0.270] | | | |
| derivations | 402,815 | 1,316,744 | 1 / 3.27 | 310,241 |
| facts (derived; of equality) | 255,826 (78,394; 6,558) | 358,071 (180,639; 41,220) | 1 / 1.40 (2.30; 6.29) | 274,665 (97,235; 0) |

Against the published gains: Motik et al. measured rewriting 2.3× faster than the axiomatised equality on UOBM (one
thread, 2696.7 s → 1152.7 s; 3.8× fewer derivations, 3.2× fewer facts), and 31.1× on Claros, whose classes are large
(85.5× fewer derivations). Here 1.84× on the UOBM-like data, with 3.27× fewer derivations: the same order as their
UOBM, whose classes are small too (2 to 4 records here). The gain grows with the classes, as the storm below shows:
axiomatised, a class of n things holds n² sameAs facts; with n = 100, rewriting takes 0.001 s and the axiomatised
equality 0.139 s (1,030,001 derivations, 20,423 facts), with n = 200, 0.002 s against 0.343 s (8,120,001
derivations, 80,523 facts): 139× and 172×; with n = 400 the axiomatised equality passes the budget and its group is
refused, naming prp-fp. Rewriting costs more than the same data without equality (`plain`, 0.364 s): each record's
facts are derived once before its merge and moved after it, and the merges themselves (0.26 s) look up every
property that could name the merged thing.

**An equality storm** (a functional property with n values on one thing: n things become one; one group, in memory):

| n | reasoning | of which merges | facts of `cepheus/same` |
|---:|---:|---:|---:|
| 1,000 | 0.011 s | 0.004 s | 999 |
| 10,000 | 0.164 s | 0.074 s | 9,999 |
| 100,000 | 1.42 s | 0.84 s | 99,999 |

(single runs; `reason.exe storm N`)

Linear: n − 1 facts of `cepheus/same`, where the axiomatised equality holds n² sameAs facts derived 2n³ + n² + n times
[Motik 2015b]. Before the equalities were applied fact by fact (at the end of a round), 3,000 things took 3.95 s (the
n² pairs of the functional property's rule); now 0.05 s.

**Reads and start-up.** A read by id names a thing as its class's representative: one pointer comparison when the
view holds no equality (21 rounds, LUBM-1 in memory, 2,000,000 reads each): `get` 2,662 ns on step 3, 2,647 ns here
(paired 1.02 [0.93, 1.11]); `values` 780 and 767 ns (1.00 [0.85, 1.23]). Start-up (`bench.exe`, 21 rounds of 50
runs): 3.226 ms [3.131, 3.357] on step 3, **3.217 ms** [3.058, 3.371] here, paired 1.00 [0.94, 1.06]: the library and
the equality add nothing to start-up (the rules are compiled at the first write that needs them, never at open).

**Old databases.** A database written by main 9761e4a and one written by step 3 (LUBM-1 with the 94 rules, a group a
department) are read whole by step 3's binary and by this one: the same 432,123 facts (131,437 derived), the same
digest of every fact and its flag.

## Rules, step 3: the path of loads, sorted and parallel (2026-11-14)

The third step of the reasoner ([rules](rules.md#large-groups)): a large group's facts reasoned as a sorted prefix of
the working set instead of hash chains, chains kept only where a plan reads them, large rounds made facts on every
hardware thread, the derived facts merged into the group's two orders; constraints, one-valued heads and facts
derived already stay on that path; a large batch of derived facts enters the view's delta by maps built in linear
time.

**Method.** `bench/reason.exe` (release build) of main 9761e4a, of the step 5 branch 0b8c847 (where this step
started) and of this branch, each built from its own source. Rounds alternated (the order of the binaries turned each
round), a series in one hold of the heavy lock, every process in a 3 GB scope; a cell is the median with
$[x(1), x(n)]$; a ratio is the median of the paired ratios (round by round) with their range. The peak resident
memory is the process's (`getrusage`), the data generated in the process and its list of operations included. The
machine was shared with other jobs' processes outside the lock (a load average of 5 on 8 threads): the medians are
above the quietest runs. The same answers: 532,205 derived facts and 2,021,310 derivations on every side, and on this
branch the digest of every fact and its flag equal for one group, a university a group, and a department a group.
Commands: `reason.exe mat 10 rules|none bulk|chunks DIR`, `reason.exe student 1 2000 DIR`, `reason.exe define 10`.

**LUBM-shaped data, ten universities with the 94 rules, one group, durable** (1,354,654 asserted facts; 7 rounds):

| | main 9761e4a | step 5 0b8c847 | this branch | this / main |
|---|---:|---:|---:|---:|
| the load, every fact durable | 2.90 s [2.72, 3.90] | 2.76 s [2.68, 3.19] | **1.78 s** [1.66, 2.27] | 0.62 [0.42, 0.81] |
| its reasoning | 1.217 s [1.047, 1.285] | 1.015 s [0.870, 1.054] | **0.411 s** [0.334, 0.465] | 0.33 [0.27, 0.44] |
| of which the facts made ready for the joins | 0.627 s [0.489, 0.693] | 0.603 s [0.478, 0.672] | **0.128 s** [0.065, 0.142] | 0.21 [0.10, 0.26] |
| the rounds alone (saturation), derived facts a second | 0.92 M [0.85, 0.98] | 1.36 M [1.27, 1.44] | **1.92 M** [1.58, 2.04] | 2.04 [1.66, 2.17] |
| the reasoning whole, derived facts a second | 0.44 M | 0.52 M | **1.29 M** (best run 1.59 M) | |
| peak resident memory | 680 MB [659, 753] | 832 MB [804, 836] | **557 MB** [494, 570] | 0.81 [0.69, 0.86] |

**The same without rules** (5 rounds): 1.374 s [1.299, 1.717] on main, **1.059 s** [1.042, 1.783] here (0.82
[0.74, 1.04]: the sort by thing on several domains, the new texts numbered through an open table), 340 MB and 308 MB.

**A university a group** (ten large groups of about 135,000 facts, durable; this branch only, the others have no such
mode; 5 rounds): the ten writes **2.45 s** [2.21, 3.04], their reasoning 0.61 s, **peak resident memory 133 MB**
[131, 134]. Before this step, from the second university on, each group went to the ordinary path (a university's
type, derived from the degrees of earlier universities, asserted again): 8.6 s in one run.

**On the disk**: the run of the load with its consequences 23.1 MB (12.3 bytes a fact, the dictionary of its 600,000
texts included), without rules 19.9 MB (14.7 a fact): the 532,205 derived facts take 3.3 MB, **6.2 bytes each**; in
the journal 2.8 bytes each (7.2 MB against 5.7).

**What did not change: a small group's path** (`student 1 2000`: a graduate student written then retracted, 2,000 of
each, on a fork over one university; 7 rounds; medians of the rounds' medians, paired ratios against main):

| | main 9761e4a | step 5 0b8c847 | this branch | this / main |
|---|---:|---:|---:|---:|
| without rules: write / retract | 10.0 / 6.9 µs | 10.0 / 7.2 µs | 10.0 / 7.2 µs | 1.00 [0.50, 1.44] / 1.04 [0.72, 1.15] |
| with the 94 rules: write / retract | 27.9 / 41.0 µs | 28.1 / 42.9 µs | 29.1 / 42.2 µs | 1.03 [0.90, 1.17] / 1.00 [0.93, 1.76] |

The microsecond clock of these medians and the shared machine make the rounds' spread wider than any difference.
Start-up (`bench.exe` without arguments, 21 rounds of 100 runs, alternated, each binary in 7 copies taken in turn: a
copy's place in memory moves a start-up by up to 2 %): 3.023 ms on 0b8c847, 2.987 ms here (paired 0.989 [0.975, 0.992],
faster in 21 rounds of 21). The code of this step adds 507 frame descriptors, which the runtime puts in a table at every
start-up: 0.7 % more (1.007 [1.003, 1.011]); the latency histograms, which made their counters when the modules loaded
(8 here, 230 KB), now make them at their first value, which gives back more. Databases written by main's and
by 0b8c847's binaries open here and read the same facts and flags (the digest of one university loaded by each).

**A change of the rules** (step 5's two targets, measured again with this step; [step 5](#rules-step-5-changes-of-the-rules-in-the-background-2026-11-13)'s
method: `CHANGE=one reason.exe change 10 256 8 2 with|without DIR`, the change one rule over LUBM-10 while 256
clients write; 7 pairs for each binary, in one hold; and `reason.exe define 10`, the 94 rules defined in memory over
the load, 5 rounds):

| | step 5 0b8c847 | this branch |
|---|---:|---:|
| the change's build beside 256 writers (119,000 to 150,000 derived facts) | 0.531 s [0.388, 0.562]: 0.33 M/s | **0.332 s** [0.282, 0.391]: **0.45 M/s** |
| the writers' throughput in the change's window, with / without | 0.88 [0.52, 1.51] | 0.86 [0.48, 5.47] |
| the same over the run from the change's start | 1.08 [0.77, 1.39] | 0.87 [0.54, 1.46] |
| the 94 rules defined in memory (532,205 derived) | 3.35 s [2.64, 23.9] | **2.10 s** [1.96, 2.62]: 0.25 M/s |

The change's build is faster by its delta: a large batch of derived facts now enters the view's delta by maps built
in linear time (0.6 µs a fact instead of 1.2). Its rounds still read the view fact by fact on the change's own domain
(more domains there cost the writers' throughput: step 5's finding), and its facts still go into the delta, not a run
of their own: the step's target, 2 M derived facts a second, is not reached (0.45 M/s), nor 0.90 for the writers
(0.86 median, within the pairs' spread of step 5's 0.88).

- **Against the step's targets**: the load with its consequences in at most 1.5 s: 1.78 s median, 1.66 s at best
  (missed: the load without rules takes 1.06 s here, and the run's merge of the 532,205 derived facts adds about 0.1
  s); its reasoning in at most 0.25 s (2.5 M derived facts a second on 8 threads): 0.41 s median, 0.33 s at best,
  1.3-1.6 M a second (missed; the rounds alone reach 1.9-2.0 M a second); a load's memory in at most 150 MB in chunks:
  133 MB (met); at most 5 bytes a fact: 6.2 bytes a derived fact in the run, 12.3 a fact with the dictionary (missed:
  the run's format is unchanged in this step).
- **Where the reasoning's time goes now** (this branch, one run with timers): the working set allocated 0.03-0.05 s,
  the prefix filled 0.015 s, its membership table 0.03 s, the derive phases 0.09-0.14 s (2,021,310 derivations, each a
  lookup in a table of tens of MB), the heads made facts 0.08-0.11 s (of which the regions' probes 0.055-0.08). Every
  step left is memory latency; 8 threads against 4 gave 13 % (0.350/0.305 s against 0.407/0.353 s).
- **Beside the giants** (their papers, their machines and data; *computed*: ours from their tables): RDFox 2014
  [Motik 2014] 0.67 M derived facts a second on one thread, 6.1-7.0 M on 16-32 threads of two 8-core Xeons (0.44 M a
  core at 32 threads); VLog [Urbani 2016] about 1.28 M on one thread. Here 1.9 M a second for the rounds and 1.3-1.6 M
  for the whole reasoning on one 4-core laptop (8 threads): 0.33-0.40 M a core, close to RDFox 2014's 0.44 M a core in
  parallel and above its one-thread rate; below RDFox's absolute parallel numbers, which need its 16 cores. GraphDB's documented OWL2-RL
  load, 9.1 k asserted statements a second on 8 cores, persisted (other data, another machine): here 1.35 M asserted
  facts with their consequences durable in 1.78 s, about 0.76 M a second.

## Rules, step 5: changes of the rules in the background (2026-11-13)

The fifth step of the reasoner ([rules](rules.md#changes-of-the-rules-in-the-background)): a change of the rules or the
ontology computed beside the writer, caught up with the groups written meanwhile, installed as one group; rounds of
20,000 facts and more derived on several domains in the groups the writer reasons itself.

**Method.** `CHANGE=one reason.exe change 10 256 8 2 with|without DIR` (release build): LUBM-shaped data of 10
universities on the disk with the 94 univ-bench rules (1.89 M facts), merged into one run, copied before each run; 256
client threads write graduate students (10 facts, a group each, durable) in a closed loop for 8 s; at 2 s, with `with`,
the change is written (`define` of `[x type Person] -> [x type Schedule]`, a class the data leaves empty: the design's
Person ⊑ Agent of its choice 10.6); each run records the confirmed groups by 10 ms. 21 pairs (with, without),
alternated (the side that goes first swaps each pair), each run in the heavy lock and a 3 GB scope; a ratio is a
pair's: the groups confirmed in the change's window with it, over those confirmed in the same window without it.

| what (21 pairs) | median | min | max |
|---|---|---|---|
| the change, from `define` to its answer | 3.09 s | 0.72 s | 6.90 s |
| its build (its consequences on the state it started from: about 150,000 derived facts) | 0.49 s | 0.35 s | 0.76 s |
| the build's rate | 0.30 M derived facts/s | 0.20 | 0.40 |
| the writer's own part at the install (the last groups, the frame) | 54 ms | 42 ms | 103 ms |
| the clients' throughput in the change's window, with / without | **0.84** | 0.005 | 36 |
| the same over the whole run from the change's start | **0.89** | 0.10 | 3.8 |

The extremes of the ratios are short windows (under a second) where one side met a stall the other did not (a
merge's switch, the machine): the medians are the measure. Without the change the clients confirm 8,069 groups a
second in that window (median); with it, 6,468. Where the difference goes, from the 10 ms bins of the 21 pairs with four domains in the
background: 0.70 during the build, 0.74 during the catch-up, and still 0.79 in the two seconds after the install,
when the background is gone: part of the cost is the state the change leaves (one more rule deriving for every person
written, a delta that grew with no merge beside the change, then that merge), not the background alone.

Variants measured on the way, the same method: the background deriving on four domains (morsels, as the writer's own
large groups do): 0.78 in the window and 0.79 over the run (21 pairs), so it derives on its own domain only; a minor
heap of 64 MiB for its domain: 0.735 (7 pairs); a minor heap of 32 MiB for every domain (`OCAMLRUNPARAM=s=4M`): 0.57
(7 pairs).

**The worst case**, `CHANGE=all`: the base holds no rule and the change defines all 94 (683,000 derived facts with the
students written before it). Single runs, not 21: build 3.0 s (0.23 M derived facts/s; 1.6 s of it putting the facts
into the view's delta), then catch-up passes of 35,000 to 66,000 groups taking 3.8 to 7.4 s each (about 110 µs a
group: every group written meanwhile is reasoned under 94 rules it was not reasoned under, against 10 µs for the
writer), until the writer waits for the background at 65,536 groups behind; the change took 18 to 25 s, its install
1.2 to 1.9 s; one run was stopped at the 3 GB cap after the install (both deltas and a frame of 1.6 M changes). The
catch-up's first version applied the logged groups one at a time: here it never caught up, and the run was stopped at
the 3 GB cap after 39 s.

**The derivation alone**, `reason.exe define 10` (in memory, the 94 rules defined over the same data loaded without
them, one change computed in its group on a fork): 3.0 s for 532,205 derived facts, of which the first round of the
added rules 0.48 s on four domains (1.31 s on one), the later rounds 0.56 s (0.72 s), and putting them into a fork's
delta, which holds the whole load in persistent maps, 1.2 s.

**Rounds on several domains in a load** (`reason.exe mat 10 rules bulk DIR`: the 10 universities with the 94 rules
in one group on the disk, the path of large groups; 21 rounds alternated with main 9761e4a): the saturation (the
rounds alone, the working set built) 0.90 M derived facts/s on main, **1.44 M/s** here (four domains; paired ratio
1.54); the whole reasoning 1.18 s and 1.02 s; the load, 2.85 s and 2.93 s (the disk's spread, 2.3 to 4.6 s, covers
it).

**What did not change.** The same student groups in a fork over one university (`reason.exe student 1 2000 DIR`, 21
rounds alternated with main 9761e4a): without rules, write 9.1 µs and 9.1 µs, retract 6.9 and 6.9; with the rules,
write 26.0 and 26.0, retract 37.0 and 37.0 (medians; paired ratios 0.96 to 1.00). Start-up (`bench.exe` without
arguments, 21 rounds of 50 runs): 3.195 ms on main, 3.211 ms here (paired ratio 1.03, within the rounds' spread of
2.9 to 4.5 ms).

**Against the step's targets.** The clients' durable throughput while a change at LUBM-10 scale runs: 0.84 of its value
without it in the change's window, 0.89 over the run, against a target of 0.90: missed, narrowly over the run. The
change's consequences at 2 M derived facts/s on 8 threads: 0.30 M/s measured on the background's one domain: missed by
far; what remains costs per fact are the view's delta (persistent maps, about 1.5 µs a fact put in) and joins that
probe the store fact by fact, which the design's step 3 (sorted joins, a change's facts in a run of their own)
addresses. `spec/RuleChange.tla` checked by TLC: met ([testing](testing.md#model-checking)).

## Rules, step 2: closures and the W3C's form (2026-11-12)

The second step of the reasoner ([rules](rules.md#transitive-closures-the-closure-module)): transitive properties kept
by a closure module, and rules over a variable property unfolded on the ontology's facts.

**Method.** `bench/reason.exe` (release build), measured against the binary of 23ac670 (the reasoner's first step,
where prp-trp runs as a rule), both built from the same benchmark source (the modes the older binary has).
Seven rounds, alternated (the side that goes first swaps each round), in one hold of the heavy lock, every process in
a 3 GB scope; a cell is the median of the rounds with $[x(1), x(n)]$; a ratio is the median of the paired ratios
(new/old, round by round). The same answers on both sides: the closures' facts and the derived facts are equal. The
graphs are the design's (section 6.4, drawn as its prototype drew them): a hierarchy of 100,000 nodes, 4 children
each (depth 8); a deep one of 20,000 nodes, 2 each (depth 14); a random DAG of 5,000 nodes, 3 edges down each (OCaml's
`Random`, seed 1: 14,973 edges); a chain of 500. Every edge in one group, on disk (`closure KIND trp|linear DIR`): the
hierarchy's 99,999 edges take the path of large groups, the others (under 20,000 operations) the ordinary path.
"The module" is the closure module's own time (its facts found and laid out for the group), as the prototype measured
its module; "reasoning" is the whole of it in the group (with, for a large group, the working set's build of its
facts). LUBM-shaped data as in [Rules (2026-11-08)](#rules-2026-11-08): `mat 10 rules …` the 94 rules written one an
axiom, `w3c 10 …` the ontology as facts and the 10 W3C rules it needs (cax-sco, scm-sco, prp-dom, prp-rng,
prp-spo1, prp-inv1, prp-inv2, prp-trp, cls-svf1, cls-int1 over two members), which the engine unfolds.
Commands: `reason.exe closure hierarchy|deep|dag|chain trp|linear DIR`, `reason.exe mat 10 rules bulk|groups DIR|-`,
`reason.exe w3c 10 bulk|groups DIR|-`, `reason.exe student 1 2000 DIR`.

**Transitive closures** (median [x(1), x(7)] of 7 rounds; the closures equal on both sides):

| graph (closure facts, derived) | form | the module | reasoning: 23ac670 → this | the write, durable: 23ac670 → this | derivations: 23ac670 |
|---|---|---:|---:|---:|---:|
| hierarchy, 100,000 nodes (783,495; 683,496) | prp-trp | **22.5 ms** [21.2, 24.4] | 0.918 s → **0.084 s** (0.091×) | 1.27 s → 0.42 s (0.33×) | 2,706,780 |
| | linear | 26.3 ms [12.0, 40.9] | 0.606 s → 0.146 s (0.23×) | 1.05 s → 0.61 s (0.58×) | 783,495 |
| deep, 20,000 nodes (247,248; 227,249) | prp-trp | 9.8 ms [9.4, 15.0] | 1.07 s → 0.58 s (0.54×) | 1.14 s → 0.64 s (0.57×) | 1,438,678 |
| random DAG, 5,000 nodes (1,359,764; 1,344,791) | prp-trp | **47.3 ms** [41.9, 57.5] | 17.6 s → 3.85 s (0.22×) | 17.8 s → 4.06 s (0.23×) | 77,224,523 |
| | linear | 44.1 ms [39.7, 48.6] | 6.37 s → 3.88 s (0.61×) | 6.63 s → 4.09 s (0.62×) | 2,449,704 |
| chain, 500 nodes (124,750; 124,251) | prp-trp | 1.2 ms [1.2, 1.5] | 2.44 s → 0.26 s (0.10×) | 2.46 s → 0.29 s (0.11×) | 20,708,998 |
| | linear | 1.3 ms [1.2, 1.4] | 0.35 s → 0.26 s (0.75×) | 0.38 s → 0.28 s (0.77×) | 124,750 |

- **The design's targets**: the hierarchy's closure in at most 30 ms (22.5 ms: met; the prototype 11-16 ms, prp-trp as
  a rule 665 ms there, 918 ms here), the random DAG's in at most 60 ms (47.3 ms: met; the prototype 14-46 ms, prp-trp
  7.82 s there, 17.6 s here). The module makes each new fact once: 0 derivations, against 3.5 to 166 a fact by the rule.
- **Where the rest goes**: the hierarchy's 99,999 edges are a large group, whose reasoning also builds the working set
  of its facts (54 ms of the 84). The DAG's, the deep tree's and the chain's edges are under 20,000 operations: the
  ordinary path, whose facts go into the view's delta one by one in sorted batches (about 2.8 µs a fact with the
  group's change records): 3.8 s of the DAG's 3.9. Large derivations from small groups take the large groups' path in
  the design's step 3.
- **Measured and set aside**: the module's arrays are Bigarrays, which pace OCaml's major collector by their size
  (`custom_major_ratio`, 44 % by default): with it at 1,000 the hierarchy's module took 19.5 ms instead of 48.6 ms
  before the arrays were cut down; the engine does not change the collector's settings of the program it is in.
- **Beside the giants** (their papers, their machines and data): Hu, Motik and Horrocks [Hu 2022] report LUBM-LE
  materialised in 339 s with modules against 1,268 s without (3.7×); here the module's own time is 23 to 2,000 times
  below the rule's reasoning on these graphs (the design's prototype: 60 to over 1,000), and a group's reasoning 1.3 to
  11 times faster. RDFox has had such modules since 2019 [Hu 2019]: a tie in method. Soufflé, which evaluates the
  rule, "runs out of memory when evaluating TC on G80K" in Fan et al.'s tests [Fan 2019].

**One edge retracted** (the same binary, by walks against B/F through the rules' plans, `Reason.walk_retract`; 21
rounds alternated in one hold of the lock, the closure loaded first in each process; medians, $[x(1), x(21)]$, the
paired ratio's median with its 95 % interval by order statistics $[x(6), x(16)]$; the same closure after on both sides):

| prp-trp | facts lost | by walks | by B/F | walks / B/F |
|---|---:|---:|---:|---:|
| hierarchy, the edge of a node of depth 2 (its subtree 6,250 things) | 36,160 | **0.102 s** [0.095, 0.187] | 0.161 s [0.146, 0.255] | 0.64 [0.59, 0.73] |
| random DAG, the edge 300 → 134 | 102 | **0.090 s** [0.078, 0.357] | 1.766 s [1.448, 2.410] | 0.050 [0.045, 0.055] |
| chain of 500, the middle edge | 62,500 | **0.163 s** [0.151, 0.254] | 16.11 s [15.03, 20.29] | 0.0099 [0.0096, 0.0105] |

The walks' time is mostly the facts lost put into the view (about 2.5 µs a fact in the hierarchy's case); B/F checks
each lost fact through the rule's instances (on the chain, every middle point of every pair), which is where 100× go.
An edge with another way (most edges of the DAG) changes nothing and costs a lookup per edge out of its start.

**LUBM-shaped data, the W3C's form against rules written one an axiom** (ten universities; both on this binary; the
same 532,205 derived facts of the data):

| | 94 rules, one an axiom | the 10 W3C rules, unfolded | W3C / axiom, paired |
|---|---:|---:|---:|
| one group (a load, durable): reasoning | 1.296 s [1.143, 1.625] | 1.367 s [1.297, 1.646] | **1.10** [0.80, 1.27] |
| a department a group, in memory: reasoning | 2.383 s [2.240, 2.659] | 2.498 s [2.446, 3.459] | **1.05** [0.93, 1.54] |
| derived facts / derivations | 532,205 / 2,021,310 | 658,865 / 2,147,932 | |

- **The design's target**: within 1.1× of the rules written by hand (the prototype, running the W3C rules as written:
  2.2×). Met at the median: 1.10 for the load, 1.05 group by group. The W3C form derives more, by its own meaning:
  126,660 facts more, the types of the six restriction classes (`x` is a member of "some `takesCourse` a `Course`"
  before it is a `Student`) and the closure of `subClassOf`; the unfolded subclass rules that a chain of the others
  gives are dropped, so a type is derived once a step, as by hand.
- Every group ran unfolded but the first that wrote a fact of a relation the rules had been unfolded on while the
  database was empty (`type`): it unfolded again without it, at once.

**The rules written one an axiom, and the write path, against 23ac670** (the same groups, 7 rounds):

| | 23ac670 | this | paired |
|---|---:|---:|---:|
| LUBM-10 in one group: reasoning | 1.283 s [1.130, 1.531] | 1.296 s [1.143, 1.625] | 1.00 [0.90, 1.33] |
| a department a group, in memory: reasoning | 2.216 s [2.160, 2.387] | 2.383 s [2.240, 2.659] | 1.04 [0.98, 1.22] |
| write a student, with rules / without | 24.8 / 8.8 µs | 26.0 / 8.8 µs | 1.05 [0.85, 1.20] / 1.00 |
| retract it, with rules / without | 36.0 / 6.2 µs | 36.0 / 6.9 µs | 1.00 / 1.00 |
| start-up (`bench.exe`, 21 rounds of 50 runs, medians), against main ca74bbe | 2.913 ms [2.692, 3.062] | 2.938 ms [2.575, 3.368] | 1.00 (0.997, 95 % [0.951, 1.035]) |

The reasoner's code doubled (the closure module and its retraction, unfolding, variable properties: its frame tables
62 KB to 125 KB, which the runtime reads at start-up): within the noise at 21 rounds, faster in 11 of them; the big and
cold functions are kept out of line (an earlier build, before that, measured 1.044 against 23ac670). The subOrganizationOf
closure of the hand rules is the module's too: 3,478 fewer derivations.

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
a cell is the median of the rounds with the interval $[x(1), x(7)]$ (98.4 %). Commands:
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
| load in 2 large groups (9.4 M additions, then 568,163), to confirm every group | 6.18 s [5.65, 7.41] | **4.14 s** [3.67, 4.86] | 0.656 [0.645, 0.686], faster 7 of 7 ($p = 0.016$) |
| the same, a second series after the run's fsync went beside the frame's | 6.59 s [6.18, 9.31] | 4.65 s [3.96, 5.43] | 0.677 [0.566, 0.812], 7 of 7 |
| peak resident memory of that load | 2,595 MB [2,527, 2,620] | **1,461 MB** [1,461, 1,462] | 0.563 |
| of which the client's own list of operations, once built | 883 MB | 883 MB | |
| a large group resolved and sorted (the longest of the two) | 1.94 s | 0.64 s (0.59 in the second series) | 0.328 |
| a large group merged into its run (the second series: without its fsync, now beside the frame's) | 1.57 s (1.76) | 1.59 s (0.32) | |
| load in 4 large groups (`GROUP=56818`) | 7.62 s [7.14, 11.17] | 5.74 s [5.20, 6.50] | 0.706 [0.540, 0.849], 7 of 7 |
| its peak | 2,167 MB | 1,184 MB | 0.616 |
| then `snapshot` | 1.45 s [1.28, 2.25] | 2.06 s [1.44, 2.55] | 1.258 [0.871, 1.747], slower 4 of 7 ($p = 1.0$: no difference shown) |
| on disk after it | 553 MB | **330 MB** | 0.597 |
| open of the database it leaves (one run) | 199 ms [197, 299] | 196 ms [194, 199] | 0.985 [0.648, 1.007] |
| Q1 an invoice by id | 0.37 µs | 0.36 µs | 1.000 |
| Q2 a client by e-mail | 1.56 µs | 1.56 µs | 1.013 |
| Q3 unpaid invoices of a city | 3.80 ms | 3.58 ms | 0.955 [0.939, 0.966], 7 of 7 |
| Q4 unpaid sum by city | 82.3 ms | 80.5 ms | 0.976, 7 of 7 |
| Q5 triangles | 252 ms | 245 ms | 0.970 |
| 1 M facts, a group a client, 64 threads | 8.40 s [7.19, 9.27] | 8.48 s [7.65, 10.84] | 0.947 [0.911, 1.258] ($p = 1.0$: the same) |
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
| Cepheus / the giant, by round | | 0.600 [0.429, 0.923], Cepheus faster 7 of 7 ($p = 0.016$): SQLite takes 1.7 times as long | 0.168 [0.144, 0.288], 7 of 7: PostgreSQL takes 6 times as long |
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
| 10 M facts, 4 large groups, until confirmed | 9.09 s [7.88, 11.68] | 9.43 s [8.18, 10.37] | 1.04 [0.79, 1.18] | 4 of 9 | $p = 1$ |
| its snapshot | 1.98 s [1.33, 2.27] | 2.04 s [1.52, 2.65] | 1.07 [0.67, 1.52] | 4 of 9 | $p = 1$ |
| **the open of that database** | 432 ms [389, 539] | **202 ms [197, 255]** | **0.49 [0.37, 0.60]** | 9 of 9 | $p = 0.004$ |
| 1 M facts, a group a client, until confirmed | 10.24 s [9.37, 11.18] | 10.95 s [9.39, 12.70] | 1.05 [0.85, 1.24] | 4 of 9 | $p = 1$ |
| the open of that database | 365 ms [356, 419] | 346 ms [339, 359] | 0.94 [0.82, 1.00] | 8 of 9 | $p = 0.039$ |

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

**The engine fixes measured again** (the section below), on a quiet machine: 2f37b23 (before the fixes) against
51cf32d (after), the same loads and opens, 9 rounds alternated. Each ratio is after over before, the median of the 9
rounds' ratios and its interval, which need not equal the ratio of the two medians. 10 M in 4 large groups: 9.68 s
[8.42, 11.47] against 8.73 s [8.09, 9.61] (ratio 0.97 [0.77, 1.12], after slower in 4 of 9, $p = 1$); its open 396 against 403 ms (1.02 [0.94, 1.26], $p = 0.51$); 1 M a group a
client 9.21 against 9.87 s (1.01 [0.85, 1.16], $p = 1$); its open 364 against 368 ms (1.00 [0.97, 1.14], $p = 0.51$). The
fixes cost nothing measurable: the 13.12 s below was the disk.

## The engine fixes (2026-11-08), against the commit before them

Five fixes ([guarantees](guarantees.md#g9-one-writer), [limits](limits.md)): the in-process lock keyed by the lock
file's device and inode, thing numbers refused past $2^{31} - 1$, a second `close` that does nothing, `decode` for `fold`'s
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
fixes in 5 rounds of 6, by 0.6 to 5.1 s, and faster in the sixth by 6.6 s (a sign test: $p = 0.22$, two-sided, no
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
The reads above were measured on the engine of 148ff09; on one run, the levels read at the same speed
([Reads, all in memory](#reads-all-in-memory), above), so the comparison holds.

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
about 33 merges as the base grows; each cell gives every run, separated by semicolons, the runs alternated):

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
merge threshold ($n/8$ halves the bytes and doubles the delta's memory).

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
  take $O(N \log N)$ per binding instead of $O(\text{smallest})$; every question is now checked against the Generic Join bound.

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
  for one query.** On one core it is 1.2 times slower than Cepheus on Q4 and tied on Q5 (1,000 ms against 968). Cepheus answers a question on
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
