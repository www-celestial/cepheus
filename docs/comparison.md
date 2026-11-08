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
statements, fsync and `synchronous_commit` on, 1 GB of `shared_buffers`); Cepheus with a 1 GiB cache.

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
| bulk load of 10 M facts | 135 to 153 s | **about 1 min** (`COPY`, indexes, `VACUUM ANALYZE`) | **PostgreSQL** (below) |

**Where PostgreSQL wins, and why.**
- *Q5 larger than memory.* Cepheus orders a base's rows by thing, so a client's follow links lie among the rows of its
  20 invoices; the triangle question reads random pages of 120 MB of rows for a few bytes each (18.8 million pages read
  in 6 runs with a 48 MB cache). PostgreSQL keeps `follows` in a table of its own, 23 MB with its index, which fits in
  its 32 MB of buffers. A third order of Cepheus' rows (property, then thing) would make one property of many things
  local, at 10 bytes a fact more; it waits for real workloads to decide ([theory](theory.md#7-pages-and-the-cache)).
- *Bulk load.* `COPY` writes rows straight into table pages and builds each index once at the end. Cepheus loads
  through its writer like any write (groups of 83 facts, each frame forced), and its one level on disk makes each of
  the 33 merges of a 10 M load rewrite the whole base: about 3.3 GB, beside the journal's fsyncs that every client
  waits for ([architecture](architecture.md#the-merge-a-log-structured-merge-tree-of-two-components)).
- *What it has that Cepheus has not built*: SQL, many concurrent writers (row locks), replication and failover, a
  planner for any SQL, decades of tools. And through its socket, any language and any machine can reach it; Cepheus is
  a library inside one process.

**Isolation, by design** ([PostgreSQL 18: transaction isolation](https://www.postgresql.org/docs/18/transaction-iso.html)):
"Read Committed is the default isolation level in PostgreSQL"; Repeatable Read "is implemented using a technique
known [...] as Snapshot Isolation" and allows serialization anomalies; Serializable "is implemented using [...]
Serializable Snapshot Isolation", and "applications using this level must be prepared to retry transactions due to
serialization failures". Cepheus has one level: groups strictly serializable, read-then-writes validated by `Expect`
([concepts](concepts.md#isolation-exactly-what-a-reader-and-a-writer-see)). Group commit: PostgreSQL groups commits
on its own ("When commit_delay is set to zero (the default), it is still possible for a form of group commit to
occur", [WAL configuration](https://www.postgresql.org/docs/18/wal-configuration.html)), as Cepheus does. Parallel
query: `max_parallel_workers_per_gather` defaults to 2
([resource settings](https://www.postgresql.org/docs/18/runtime-config-resource.html)), hence "3 processes" above.

## By design

| | data model | writes | isolation | storage | questions |
|---|---|---|---|---|---|
| **Cepheus** | facts (thing, property, value) | one writer per database, group commit | groups strictly serializable; read-then-write validated by `Expect` | a journal + a two-component LSM-tree (delta in memory, one sorted base on disk), own page cache | conjunctive queries, Generic Join (worst-case optimal) |
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
- *Where Oracle wins*: everything a mature server has: many writers, clustering, replication, partitioning, SQL.

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
  query the past yet. Datomic's queries are Datalog; Cepheus' are conjunctive queries answered by a worst-case optimal
  join.
- *Where Datomic wins*: time travel, rules in Datalog, a peer cache model over distributed storage.

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
  amplification of leveled compaction [...] is often larger than 10"
  ([tuning guide](https://github.com/facebook/rocksdb/wiki/RocksDB-Tuning-Guide),
  [leveled compaction](https://github.com/facebook/rocksdb/wiki/Leveled-Compaction)). Cepheus' one level costs up to
  17 facts of merge writes per change, but each merge rewrites the whole base at once and needs up to three bases of
  disk while it runs; RocksDB's levels compact small files, a few at a time.
- *Where RocksDB wins*: levels (merges proportional to the change, not to the base), compression, column families,
  years of production; transactions of both kinds ("Optimistic Transactions do not take any locks [...] they rely on
  doing conflict-detection at commit time", [transactions](https://github.com/facebook/rocksdb/wiki/Transactions)).
  RocksDB has no query language: Cepheus' joins would be written by hand on top of it.

### Neo4j

- "Neo4j is a native graph database, which means that it implements a true graph model all the way down to the storage
  level" ([what is Neo4j](https://neo4j.com/docs/getting-started/whats-neo4j/)). Its blog calls the principle
  "index-free adjacency": "Link every data element directly to its incoming and outgoing relationships"
  ([15 rules](https://neo4j.com/blog/cypher-and-gql/15-rules-native-graph-database/)). Cepheus finds "who links to t"
  with a binary search in the by-property rows, not by following a pointer.
- Isolation: read-committed is the default, and "Explicit locking of nodes and relationships [...] allows for
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
- *Where FoundationDB wins*: many machines, replication, isolation of interactive transactions over ranges.

### CockroachDB

- "By default, CockroachDB executes all transactions at SERIALIZABLE isolation", and it also offers READ COMMITTED
  ([transactions](https://docs.cockroachlabs.com/docs/stable/transactions)). The key space "is divided into contiguous
  chunks called ranges", each "replicated to at least 3 nodes by default", each a Raft group
  ([overview](https://docs.cockroachlabs.com/docs/stable/architecture/overview),
  [replication layer](https://docs.cockroachlabs.com/docs/stable/architecture/replication-layer)). "CockroachDB uses
  the Pebble storage engine", which "uses a Log-structured Merge-tree (LSM)", and "multi-version concurrency control
  (MVCC)" with "hybrid logical clock (HLC) timestamps"
  ([storage layer](https://docs.cockroachlabs.com/docs/stable/architecture/storage-layer)).
- *Where CockroachDB wins*: it runs on many machines and survives the loss of one; SQL. Cepheus runs on one.

## Further reading

Berenson et al. 1995 and Fekete et al. 2005 for snapshot isolation and write skew; Kung and Robinson 1981 for
optimistic validation; Raasveldt et al. 2018 for fair benchmarks; Zhou et al. 2021 for FoundationDB; Luo and Carey
2020 for LSM-trees. Full entries: [references](references.md).
