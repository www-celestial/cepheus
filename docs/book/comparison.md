# Cepheus and the established databases

Two kinds of comparison, never mixed. **Measured**: PostgreSQL 18.6 and SQLite 3.54, installed on the test machine,
run under the method of [benchmarks](benchmarks.md) (the same data, the same questions, the same answers checked on
both sides, medians of 21 runs with their 95 % intervals, under a shared lock that keeps other heavy jobs off the
machine). **By design**: Oracle, Datomic, RocksDB, Neo4j, FoundationDB and CockroachDB, which are not installed here,
compared only on what their own documentation says, quoted with its link; no number is given for them.

## Measured: PostgreSQL 18.6

The test machine: Intel i7-4720HQ (4 cores, 8 threads), 11 GB of memory, a consumer SATA SSD (about 340 fsync a
second), btrfs. 10 million facts: 113,636 clients, 2,272,720 invoices, 568,163 follow links. PostgreSQL in its own
cluster, set up as an expert would (primary keys, an index on every searched column, `VACUUM ANALYZE`, prepared
statements, fsync and `synchronous_commit` on, 1 GB of `shared_buffers`); Cepheus with a 1 GiB cache. The reads and
writes were measured side by side at milestone 2 (the one-level base); the loads after the levels and large groups.
Cepheus' reads on one run measured since then are within a few percent of those below (Q1 0.38 µs, Q2 1.57 µs, Q3
3.74 to 3.82 ms, Q4 231 to 237 ms, Q5 0.95 to 1.00 s: [benchmarks](benchmarks.md#reads-all-in-memory)).

| | Cepheus | PostgreSQL | who wins, and why |
|---|---:|---:|---|
| Q1 every fact of an invoice, by id | **0.39 µs** | 4.73 µs in the server; 26 µs through its socket | Cepheus: dense ids make it two array reads, in the application's process; PostgreSQL walks a B-tree and, for an application, crosses a socket |
| Q2 a client by e-mail (unique) | **1.68 µs** | 5.68 µs; 26 µs through its socket | Cepheus, for the same reasons |
| Q3 the unpaid invoices of a city's clients (4,299 rows) | **4.07 ms** | 10.55 ms (one process) | Cepheus: index lookups with exact counts, no plan to build |
| Q4 the unpaid sum per city (453,866 invoices), 1 core | 231 ms | 236 ms | even |
| Q4, 3 cores | 107 ms | 109 ms | even |
| Q5 triangles of the follow graph, 1 core | 1.03 s | 1.03 s | even |
| Q5, 3 cores | **371 ms** | 603 ms (2 processes: PostgreSQL launched 1 worker) | Cepheus: Generic Join splits over domains |
| durable writes, 256 clients, as fast as they go | 14,182 groups/s (rounds 14,141 to 17,192) | 19,559 inserts/s (12,742 to 20,863) | even: both bound by the disk's fsync rate; a side's rounds differ more than the two sides |
| durable writes at a fixed rate of 2,000 a second, p99 | **0.1 to 1.7 s** | 0.6 to 6.1 s | Cepheus, on this noisy disk |
| larger than memory: Q4, base 245 MB, 32 MB of cache, process capped at 128 MB | **385 ms** | 697 ms | Cepheus |
| larger than memory: Q5 | 102 s | **1.05 s** | **PostgreSQL**, by 100 times (below) |
| with run format 8 (2026-11-11): Q4 at 1, 2, 3, 4 cores | **128, 81.6, 57.8, 47.8 ms** | 233, 141, 107, 87.7 ms (1 to 4 processes) | Cepheus, 1.8 times at every count: three single values an invoice read from the columns of client, city and total |
| with run format 8: Q5 at 1, 2, 3, 4 cores | **250, 149, 100, 77.3 ms** | 1,010, 604, 602, 616 ms (it launches 1 worker at most) | Cepheus, 4 to 8 times: the column of `follows` and leapfrog intersections |
| with run format 8: Q5 larger than memory, 128 MB cap, 32 MB cache, cold | **263 ms** (114 ms on 3 cores; 260 ms at a 48 MB cap) | 1.05 s (2026-11-08) | Cepheus, 4 times: `follows` is now a column of its own, 1.6 MB |
| load of 10 M facts, alternated (7 rounds) | **5.13 s [4.65, 8.08]**, in 2 large groups | 30.87 s [28.08, 37.13] (`COPY`, indexes, `VACUUM ANALYZE`) | Cepheus, 6 times (faster in 7 rounds of 7): a large group is mapped and sorted in compact arrays by several domains and merged into a run at once, its frame written beside (below) |
| load of 10 M facts, a group a client (227,272 confirmed groups) | 111.8 s [103.1, 124.4] (4 runs) | not measured (`COPY` is one transaction) | |

**Where PostgreSQL wins, and why.**
- *Q5 larger than memory, until run format 8 (2026-11-11), which keeps each property's rows apart in a third order
  and takes the triangles at a 48 MB cap to 0.26 s (rows above).* Cepheus orders a base's rows by thing, so a client's follow links lie among the rows of its
  20 invoices; the triangle question reads random pages of 120 MB of rows for a few bytes each (18.8 million pages read
  in 6 runs with a 48 MB cache). PostgreSQL keeps `follows` in a table of its own, 23 MB with its index, which fits in
  its 32 MB of buffers. A third order of Cepheus' rows (property, then thing) would make one property of many things
  local, at 10 bytes a fact more; it waits for real workloads to decide ([theory](theory.md#7-pages-and-the-cache)).
  Measured again on run format 7 (2026-11-09), cold (the files' pages dropped before each side, which the series
  above did not do), beside SQLite 3.54, PostgreSQL not run again: under a 128 MB cap the run of 54.4 MB fits beside
  the process and the triangles take 1.10 s (SQLite 1.04 s; format 6 did not end in 10 minutes); under 48 MB, where
  neither file fits, more than 2.5 minutes a run against SQLite's 1.02 s, whose follow links fit in its cache
  ([benchmarks](benchmarks.md#compressed-runs-and-journal-2026-11-09-at-10-million-facts)).
- *Bulk load, until the levels.* `COPY` writes rows straight into table pages and builds each index once at the end.
  Cepheus loaded through its writer like any write (groups of 83 facts, each frame forced), and its one level on disk
  made each of the 33 merges of a 10 M load rewrite the whole base: 135 to 153 s against PostgreSQL's minute. With the
  levels and large groups, and the load in parallel and without copies, Cepheus loads the same facts in 5.13 s and
  `COPY` takes 30.87 s ([architecture](architecture.md#large-groups)); Cepheus pays in memory (1.46 GB at the peak of
  one 9.4 M group, 0.88 of it the client's list, where PostgreSQL works in its 1 GB of buffers).
- *What it has that Cepheus has not built*: SQL, many concurrent writers (row locks), a planner for any SQL, decades
  of tools. (Replication is built: a replica promoted by hand, and a Raft cluster that elects its leader by itself,
  [the server](server.md#a-replica).)

**Server against server** (1 M facts, the same rows, both through their own sockets; the first four rows 2026-11-19 in
101 rounds, the others 2026-11-08 in 11; the full table and its method: [the
server](server.md#speed-beside-postgresql)):

| | Cepheus server | PostgreSQL 18.6 | who wins, and why |
|---|---:|---:|---|
| a point read, 1 client, Unix socket | **9.68 µs** | 24.91 µs | Cepheus: 0.65 µs of work over the kernel's round trip (8.86 µs); PostgreSQL's `SELECT 1` alone takes 15.24 µs |
| the same, TCP + TLS 1.3 | **41.33 µs** | 52.31 µs | Cepheus, by less: OpenSSL works on memory buffers here (18 µs of TLS where OpenSSL alone needs 11) |
| 16 reads in flight on one connection, a read | **1.30 µs** | 9.05 µs (pipeline of 16) | Cepheus: replies by id, a batch answered in one system call |
| 8 clients at once, a read | **3.71 µs** | 6.27 µs | Cepheus: 4 I/O domains of threads (one domain: 9.6 µs); PostgreSQL forks a process a connection |
| 256 clients at once, a read | **2.88 µs** | 12.83 µs | Cepheus: threads stay cheap; PostgreSQL's 256 processes cost more |
| Q3, Q4 through the socket | **0.487 ms, 12.37 ms** | 0.662 ms, 18.47 ms | Cepheus |
| a new TLS connection | **2.60 ms** | 4.28 ms | Cepheus: no process to fork |
| durable writes, 1 to 256 clients | even | even | both wait for the disk's fsync |

**Isolation, by design** ([PostgreSQL 18: transaction isolation](https://www.postgresql.org/docs/18/transaction-iso.html)):
"Read Committed is the default isolation level in PostgreSQL"; Repeatable Read "is implemented using a technique
known \[...] as Snapshot Isolation" and allows serialization anomalies; Serializable "is implemented using \[...]
Serializable Snapshot Isolation", and "applications using this level must be prepared to retry transactions due to
serialization failures". Cepheus has one level: groups strictly serializable, read-then-writes validated by `Expect`
([concepts](concepts.md#isolation-exactly-what-a-reader-and-a-writer-see)). Group commit: PostgreSQL groups commits
on its own ("When commit_delay is set to zero (the default), it is still possible for a form of group commit to
occur", [WAL configuration](https://www.postgresql.org/docs/18/wal-configuration.html)), as Cepheus does. Parallel
query: `max_parallel_workers_per_gather` defaults to 2
([resource settings](https://www.postgresql.org/docs/18/runtime-config-resource.html)), hence the rows on 3 cores above:
the leader and its 2 workers, 3 processes (on Q5 it launched 1 worker, so 2 processes).

## Measured: SQLite 3.54

SQLite is a library in the application's process, as Cepheus is: the fairest engine-to-engine comparison. The same
10 million facts and answers, SQLite set up as an expert would (`INTEGER PRIMARY KEY`, a `WITHOUT ROWID` table for the
links, an index on every searched column, `ANALYZE`, a 1 GiB page cache), both on one core, two rounds alternated
([benchmarks](benchmarks.md#sqlite-354-at-10-million-facts-the-reads-2026-11-08)):

| | Cepheus | SQLite | who wins, and why |
|---|---:|---:|---|
| Q1 an invoice by id | **0.36 to 0.38 µs** | 0.67 to 0.68 µs (about 0.45 µs without the loop that drives the lookups) | Cepheus: an array access by dense id, where SQLite descends its table's B-tree |
| Q2 a client by e-mail | 1.66 to 1.67 µs | **1.52 µs** (about 1.22 µs without the driving loop), reading the whole row | **SQLite**: its B-tree reaches the e-mail in 3 or 4 pages; Cepheus binary-searches its sorted dictionary (about 18 steps), then the rows |
| Q3 unpaid invoices of a city's clients | 4.17 to 4.19 ms | 4.13 to 4.19 ms | even |
| Q4 unpaid sum per city | **230 ms** | 355 to 366 ms | Cepheus: Generic Join over sorted columns, where SQLite looks each unpaid invoice up by key and groups in a temporary B-tree |
| Q5 triangles | **969 to 979 ms** | 1.04 s | Cepheus, slightly; on this uniform graph a nested loop is as good as a worst-case optimal join |
| Q4 and Q5 on 3 cores | **107 ms, 371 ms** | one thread a statement | Cepheus |
| load 10 M facts, alternated (7 rounds) | **5.61 s [4.21, 11.67]**, 2 large groups | 9.37 s [7.90, 13.67] (`.import`, indexes after, `ANALYZE`) | Cepheus, 1.7 times (faster in 7 rounds of 7; even before 2026-11-08: 7.04 against 6.97 s); **SQLite** in memory: 11 MB against 1.46 GB |
| load 1 M facts, a transaction a client (22,726 commits) | **10.6 s [9.9, 10.9]**, 64 threads | 166.7 s [138.6, 169.3], one writer | Cepheus, 16 times: group commit puts the groups that arrive during an fsync into the next frame; SQLite forces each commit alone |
| size on disk after the 10 M load (2026-11-09, run format 7, journal format 2) | **74.7 MB** (journal 21.6, runs 53.1); 76.0 MB after `snapshot`, the whole history included | 136.4 MB, one file, no history | Cepheus, 1.8 times: every value coded in the bits its block needs; before format 7, 335 MB (8-byte words) |
| load 10 M facts with format 7, alternated (7 rounds, 2026-11-09) | **3.45 s** [3.37, 3.75] | 7.22 s [6.83, 7.82] | Cepheus, 2.1 times |
| Q1, Q2, Q3, Q4, Q5 with run format 7, one core (2026-11-09) | **0.38 µs**, **0.66 µs**, **3.97 ms**, **240 ms**, 1.08 s | 0.68 µs, 1.37 µs, 4.11 ms, 356 ms, **1.03 s** | Cepheus on Q1 to Q4 (a hash of the texts and a value index make Q2 2.1 times faster); **SQLite** on Q5 by 5 % ([benchmarks](benchmarks.md#compressed-runs-and-journal-2026-11-09-at-10-million-facts)) |
| larger than memory, cold, 128 MB cap, 32 MB caches, Q1 to Q5 (2026-11-09) | **0.38 µs**, **0.65 µs**, **4.02 ms**, **240 ms**, 1.10 s | 0.87 µs, 1.40 µs, 97.5 ms, 496 ms, **1.04 s** | Cepheus on Q1 to Q4: its run of 54.4 MB fits under the cap, SQLite's file of 136.4 MB does not; **SQLite** on Q5 by 6 % |
| Q1, Q2, Q3, Q4, Q5 with run format 8, one core (2026-11-11) | **0.39 µs**, **0.64 µs**, **2.87 ms**, **130 ms**, **256 ms** | 0.69 µs, 1.42 µs, 4.18 ms, 369 ms, 1.05 s | Cepheus on all five, Q5 by 4.1 times: the column order and leapfrog intersections ([benchmarks](benchmarks.md#the-column-order-and-leapfrog-intersections-2026-11-11-at-10-million-facts)) |
| larger than memory with run format 8, cold, 128 MB cap, 32 MB caches, Q1 to Q5 | **0.44 µs**, **0.69 µs**, **3.13 ms**, **129 ms**, **263 ms** | 2.89 µs, 1.48 µs, 112 ms, 552 ms, 1.14 s | Cepheus on all five; at a 48 MB cap its triangles take 260 ms against SQLite's 1.02 s |
| the same at a 48 MB cap, 16 MB caches, where neither file fits | **23.3 µs**, **0.66 µs**, **82.5 ms**, **300 ms**, more than 2.5 min | 40.7 µs, 1.37 µs, 444 ms, 1.22 s, **1.02 s** | Cepheus on Q1 to Q4 (1.7 to 5.4 times); **SQLite** on Q5 by more than 100 times: its follow links fit in its cache in a table and an index of their own, where Cepheus reads them from its thing blocks, among the invoices |

## By design

| | data model | writes | isolation | storage | questions |
|---|---|---|---|---|---|
| **Cepheus** | facts (thing, property, value) | one writer per database, group commit | groups strictly serializable; read-then-write validated by `Expect` | a journal + an LSM-tree, leveled with ratio 4 (delta in memory, sorted runs on disk), own page cache | conjunctive queries, Generic Join (worst-case optimal) |
| **SQLite** | tables | one writer at a time | serializable | B-trees in one file; a rollback journal or a WAL | SQL |
| **PostgreSQL** | tables | many writers, row locks | read committed by default; SI; SSI | heap + B-trees; WAL | SQL, binary joins, parallel |
| **Oracle** | tables | many writers, row locks | read committed by default; serializable is transaction-level read consistency | undo + redo logs | SQL |
| **Datomic** | datoms (e, a, v, tx, added) | one transactor (Pro) | writes fully serialized | four covering indexes | Datalog |
| **RocksDB** | keys and values (bytes) | a library; write groups | optimistic or pessimistic transactions | LSM-tree, leveled by default | gets, scans |
| **Neo4j** | property graph | many writers, locks | read committed by default | native graph storage | Cypher |
| **FoundationDB** | ordered keys and values | optimistic, conflict checks at commit | strictly serializable | distributed | gets, ranges |
| **CockroachDB** | tables | distributed | serializable by default; read committed | Pebble (LSM-tree), Raft per range | SQL |

### SQLite

- *Same as Cepheus*: an embedded library, one writer at a time, readers that do not block it. "Transactions in SQLite
  are SERIALIZABLE" ([isolation](https://www.sqlite.org/isolation.html)); "WAL provides more concurrency as readers do
  not block writers and a writer does not block readers", and "there can only be one writer at a time"
  ([WAL](https://www.sqlite.org/wal.html)).
- *Different*: durability is a setting: "With synchronous=FULL in WAL mode, an additional sync operation of the WAL
  file happens after each transaction commit", while "A transaction committed in WAL mode with synchronous=NORMAL
  might roll back following a power loss" ([pragma synchronous](https://www.sqlite.org/pragma.html#pragma_synchronous)).
  Cepheus has one way: `Ok` means durable. SQLite's page cache is small by default ("The default suggested cache size
  is -2000, which means the cache size is limited to 2048000 bytes",
  [cache_size](https://www.sqlite.org/pragma.html#pragma_cache_size)); its tables are B-trees ("rowid tables are
  implemented as B*-Trees", [WITHOUT ROWID](https://www.sqlite.org/withoutrowid.html)), updated in place.
- *Where SQLite wins*: SQL, one portable file, decades of use and testing, every platform.

### Oracle Database

- "Oracle Database offers the read committed (default) and serializable isolation levels"; "In serializable
  isolation, the read consistency normally obtained at the statement level extends to the entire transaction", and a
  serializable transaction that updates data changed by a transaction committed after it began fails with
  "ORA-08177: Cannot serialize access for this transaction"
  ([data concurrency and consistency, 19c](https://docs.oracle.com/en/database/oracle/oracle-database/19/cncpt/data-concurrency-and-consistency.html)).
  That is snapshot isolation (Berenson et al. 1995), which lets write skew through (Fekete et al. 2005); Cepheus'
  `Expect` refuses it ([concepts](concepts.md#isolation-exactly-what-a-reader-and-a-writer-see)).
- Group commit: "When activity is high, LGWR can use group commits", writing the redo of waiting transactions "in one
  operation" ([process architecture, 19c](https://docs.oracle.com/en/database/oracle/oracle-database/19/cncpt/process-architecture.html)).
- *Where Oracle wins*: everything a mature server has: many writers, clustering, partitioning, SQL.

### Datomic

The nearest relative. "An atomic fact in a database, composed of entity/attribute/value/transaction/added"
([glossary](https://docs.datomic.com/glossary.html)): Cepheus' fact is the same triple, its group the transaction, its
journal the added and retracted flags.
- *Same*: one writer. "At any moment in time, a running database has exactly one transactor" (Datomic Pro), and
  "Writes are strong serializable because they are fully serialized" ([ACID](https://docs.datomic.com/transactions/acid.html)).
  Database values that do not change: "because databases are immutable, any number of processes can have copies of
  the data to serve read loads". A temporary state: "The result of calling 'with' is a database value as-if the data
  was applied in a transaction, but the durable database is unaffected"
  ([client API](https://docs.datomic.com/client-api/datomic.client.api.html)): Cepheus' `fork`. A conditional write:
  `:db/cas` "takes four arguments: an entity id, an attribute, an expected current value, and a new value"
  ([transaction functions](https://docs.datomic.com/transactions/transaction-functions.html)): Cepheus' `Expect`, which
  also states an absence (`None`) and may appear many times in one group.
- *Different*: "Datomic maintains four indexes", covering ([index model](https://docs.datomic.com/indexes/index-model.html)):
  EAVT, AEVT, AVET, VAET. Cepheus keeps two orders: by thing (EAVT) and by property then value (AVET, which also gives
  VAET for links); dense thing numbers make the first an array. Datomic queries the past ("as-of", "since", "history",
  [filters](https://docs.datomic.com/cloud/time/filters.html)); Cepheus keeps every group in its journal but cannot
  query the past yet. Datomic's queries are Datalog, its rules sets of clauses passed to a query and evaluated with
  it; Cepheus' questions are conjunctive queries answered by a worst-case optimal join, and its rules
  ([rules](rules.md)) are Datalog kept materialised by the writer: a question reads derived facts as facts, a write
  pays their derivation.
- *Where Datomic wins*: time travel, recursive rules evaluated at the question (no memory for derived facts, no cost
  at the write), a peer cache model over distributed storage.

### RocksDB

- "It is a C++ library to store keys and values" ([overview](https://github.com/facebook/rocksdb/wiki/RocksDB-Overview)),
  "embeddable": an LSM-tree, "new writes are inserted into the memtable and are optionally written to the logfile",
  and "When the memtable fills up, it is flushed to a sstfile". "Level Style Compaction (default)"; tiered compaction
  is "termed Universal in the code" ([compaction](https://github.com/facebook/rocksdb/wiki/Compaction)).
- *Same*: group commit ("The thread gets to the head of the queue becomes write batch group leader and responsible
  for writing to WAL and memtable for the batch group", [pipelined write](https://github.com/facebook/rocksdb/wiki/Pipelined-Write));
  `bytes_per_sync`, which Cepheus' merge copies ([IO](https://github.com/facebook/rocksdb/wiki/IO)).
- *Write amplification*: "Write amplification is the ratio of bytes written to storage versus bytes written to the
  database"; the tuning guide's worked example gives "approximately 1 + 2 + 10 + 10 + 10 = 33", and "the usual write
  amplification of leveled compaction \[...] is often larger than 10"
  ([tuning guide](https://github.com/facebook/rocksdb/wiki/RocksDB-Tuning-Guide),
  [leveled compaction](https://github.com/facebook/rocksdb/wiki/Leveled-Compaction)). Cepheus levels too, with a
  ratio of 4 rather than RocksDB's default of 10 (`max_bytes_for_level_multiplier`): 5.8 writes a fact for its 10 M
  load, by its own count ([theory](theory.md#9-levels-on-disk-and-large-groups)). A Cepheus merge writes a whole run
  of the target level at once; RocksDB splits each level into files of a few tens of MB and compacts a few at a time,
  so a compaction is short whatever the level's size.
- *Where RocksDB wins*: compaction by files (short merges at every level), Bloom filters, compression, column
  families, years of production; transactions of both kinds ("Optimistic Transactions do not take any locks \[...] they rely on
  doing conflict-detection at commit time", [transactions](https://github.com/facebook/rocksdb/wiki/Transactions)).
  RocksDB has no query language: Cepheus' joins would be written by hand on top of it.

### Neo4j

- "Neo4j is a native graph database, which means that it implements a true graph model all the way down to the storage
  level" ([what is Neo4j](https://neo4j.com/docs/getting-started/whats-neo4j/)). Its blog calls the principle
  "index-free adjacency": "Link every data element directly to its incoming and outgoing relationships"
  ([15 rules](https://neo4j.com/blog/cypher-and-gql/15-rules-native-graph-database/)). Cepheus finds "who links to t"
  with a binary search in the by-property rows, not by following a pointer.
- Isolation: read-committed is the default, and "Explicit locking of nodes and relationships \[...] allows for
  simulating the effects of higher levels of isolation"
  ([concurrent data access](https://neo4j.com/docs/operations-manual/5/database-internals/concurrent-data-access/)).
  Cepheus' groups are strictly serializable with no lock.
- Clusters: "The servers in a cluster use the Raft protocol to ensure consistency and safety"
  ([routing](https://neo4j.com/docs/operations-manual/5/clustering/setup/routing/)); Cepheus plans Raft for replication.
- *Where Neo4j wins*: Cypher, graph algorithms, clustering, tooling.

### FoundationDB

- "FoundationDB provides global, ACID transactions with strict serializability using optimistic concurrency"
  ([developer guide](https://apple.github.io/foundationdb/developer-guide.html)); "To detect conflicts, FoundationDB
  tracks the ranges of keys each transaction reads and writes", and the resolvers check them at commit
  ([architecture](https://apple.github.io/foundationdb/architecture.html)).
- *Same*: strict serializability, optimistic validation; and testing: "Simulation is able to conduct a deterministic
  simulation of an entire FoundationDB cluster within a single-threaded process"
  ([simulation and testing](https://apple.github.io/foundationdb/testing.html)), the method of Cepheus' `test/sim.ml`.
- *Different*: FoundationDB validates every key and range a transaction read, so phantoms are caught; Cepheus
  validates only what `Expect` states. FoundationDB "does not support transactions running for over five seconds", a
  transaction may not exceed "10,000,000 bytes of affected data", keys 10,000 bytes, values 100,000 bytes
  ([known limitations](https://apple.github.io/foundationdb/known-limitations.html)); a Cepheus view can be read for
  as long as it is held.
- *Where FoundationDB wins*: many machines, each holding a part of the data, and isolation of interactive
  transactions over ranges.

### CockroachDB

- "By default, CockroachDB executes all transactions at SERIALIZABLE isolation", and it also offers READ COMMITTED
  ([transactions](https://docs.cockroachlabs.com/docs/stable/transactions)). The key space "is divided into contiguous
  chunks called ranges", each "replicated to at least 3 nodes by default", each a Raft group
  ([overview](https://docs.cockroachlabs.com/docs/stable/architecture/overview),
  [replication layer](https://docs.cockroachlabs.com/docs/stable/architecture/replication-layer)). "CockroachDB uses
  the Pebble storage engine", which "uses a Log-structured Merge-tree (LSM)", and "multi-version concurrency control
  (MVCC)" with "hybrid logical clock (HLC) timestamps"
  ([storage layer](https://docs.cockroachlabs.com/docs/stable/architecture/storage-layer)).
- *Where CockroachDB wins*: it spreads one database over many machines, each range a Raft group of its own, so its
  data and its writes grow with the machines; SQL. A Cepheus cluster also survives the loss of a minority of its
  servers ([Raft](server.md#a-cluster-of-three-raft)), but each server holds every database whole and one leader takes
  every write.

## Further reading

Berenson et al. 1995 and Fekete et al. 2005 for snapshot isolation and write skew; Kung and Robinson 1981 for
optimistic validation; Raasveldt et al. 2018 for fair benchmarks; Zhou et al. 2021 for FoundationDB; Luo and Carey
2020 for LSM-trees. Full entries: [references](references.md).
