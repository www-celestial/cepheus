# Benchmarks: Cepheus and PostgreSQL

First numbers of the in-memory core (milestone 1), against PostgreSQL 18.6 on the same machine, with the same data
and the same questions, and the same answers checked on both sides.

## Method

Following Raasveldt et al., "Fair Benchmarking Considered Difficult" (DBTest 2018):

- **Machine**: Intel i7-4720HQ (4 cores, 8 threads, 2015), 11 GB RAM, no swap, btrfs on a consumer SATA SSD (about 340
  fsync a second). Other jobs share the machine: every measure runs under a shared lock that keeps heavy jobs apart,
  and both sides run in a systemd scope capped at 3 GB (the page cache counts in the cap).
- **Data**: one seeded generator (`bench/bench.ml`): 113,636 clients (name, city among 100, unique e-mail, about 5
  follow links to other clients) and 20 invoices each (client link, total in cents, status: 70 % paid, 20 % unpaid,
  10 % late, a date): 10,000,000 facts; 113,636 client rows, 2,272,720 invoice rows, 567,795 follow rows. Cepheus is
  loaded through its writer; PostgreSQL by `COPY` from CSV files written from the same generator.
- **PostgreSQL as an expert would set it up** (`bench/pg/pg.sh`): its own cluster (initdb, never the system's), fsync,
  synchronous_commit and full_page_writes on, shared_buffers 1 GB, work_mem 64 MB, the natural tables with primary
  keys, a unique e-mail, indexes on every searched column (`client(city)`, `invoice(client)`, `invoice(status)`,
  `follows(b, a)`), `VACUUM ANALYZE`, a warm cache, prepared statements.
- **Two read measures**: what an application sees (Cepheus in its process; PostgreSQL through its Unix socket with
  pgbench) and the engine alone (PostgreSQL inside the server: a PL/pgSQL loop for point lookups, `EXPLAIN (ANALYZE,
  TIMING OFF)` execution time for joins). Cepheus: min and median of 5 rounds; PostgreSQL: 3 to 5 runs.
- **Answers checked**: Q3 city-7: 4,299 rows both sides; Q4: 453,866 unpaid invoices summing to 22,677,088,830 both
  sides; Q5: 114 triangle rotations both sides.
- **Writes**: a group making a new invoice (4 facts: client, total, status, date) against an `INSERT` of an invoice
  row (its id and the same 4 columns), with 1, 8, 64 and 256
  clients for 5 s, both durable (fsync), alternated, 3 rounds.

Commands: `bench.exe load DIR CSVDIR 10000000`, `bench.exe read DIR 10000000`, `bench.exe write DIR CLIENTS 5`;
`pg.sh init|start|load|read|write|stop ROOT ...`.

## Results at 10 million facts

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

## What the numbers say

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

Data larger than memory (both sides under a small cap), several databases writing at once, a server-class disk,
skewed graphs, parallel questions, replication.
