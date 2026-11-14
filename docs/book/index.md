# Cepheus documentation

Read in this order to learn Cepheus; jump to the reference pages when you need an exact answer.

**Start**
- [Quick start](quickstart.md): build Cepheus, start a server, and run a first Cesia program that writes and asks, in
  about ten minutes.
- [Production](production.md): a systemd service, nightly backups and a restore drill, what to watch in the status
  and the log, upgrades, and what to do after a crash or a power loss.
- [A real app](app.md): invoices and clients in Cesia, step by step from `cesia new` to production: lists in pages,
  search as one types, a live dashboard, users with an accountant's token that reads invoices only, a rule and a
  constraint, CSV export, tests in Firefox, and the speed of every page.

**Learn**
1. [Concepts](concepts.md): facts and the entity–attribute–value model, the schema, groups (transactions), views,
   isolation exactly, questions, forks, databases.
2. [How it works](architecture.md): the journal (a write-ahead log), group commit, recovery, the LSM-tree of runs in
   levels and its merges, large groups, the page cache and S3-FIFO, one writer and the domains, Generic Join, how it
   is tested.
3. [The server](server.md): `cepheus serve`, cluster.toml, tokens and rights, the wire protocol byte by byte, sessions
   (writes applied once, G14), local reads in a program's own memory (linearizable, G15), rights (G16), its speed
   beside PostgreSQL, server against server.
4. [Cepheus from Cesia](cesia.md): the Cesia client, a native package: `Connect`, kinds and their values, `Insert`,
   `Get`, `Update`, `Write` with `Expect` and `Incr`, questions with `Find`, forks for tests, local reads, many fibers
   on one connection, its errors and its speed beside the OCaml client and PostgreSQL.
5. [Testing](testing.md): forks for an application's tests, and how Cepheus itself is tested.
6. [Rules](rules.md): Datalog rules kept by the writer — derived facts, semi-naive evaluation, Backward/Forward for
   retractions, constraints, the budget, `why`, and what a write with rules costs.
7. [The file vault](vault.md): files kept in the database: chunks cut by their content (FastCDC), named by a keyed
   BLAKE2b and stored once, compressed (LZ4 warm, Zstandard cold), sealed (AEGIS-256) under their owner's key, read by
   ranges and checked at every read; erasing an owner; what a copy lacks, by Merkle trees.
8. [A case: never sell the same seat twice](case-seats.md): a real problem solved step by step, from its statement
   to the proof that it is solved (a test, generated schedules, a TLA+ model, kill -9 with a checker of the history,
   the speed beside SQLite and PostgreSQL).

**Reference**
- [API](api.md): every public function and type, with its parameters, result, errors and an example.
- [Errors](errors.md): every message, where it comes from, what it means, what to do.
- [Limits and defaults](limits.md): every bound and default value, and where it is set.
- [Guarantees](guarantees.md): G1 to G24 (G14 to G16 the server's, G17 to G20 the rules', G21 live questions', G22 to
  G24 the vault's), under which faults, their
  exact conditions, proofs and tests.
- [Operations](operations.md): files, opening and recovery, damage and disk errors, backup, verification, memory, disk
  space, tools.
- [File formats](formats.md): the journal and run files, byte by byte.
- [Internals](internals.md): the engine's modules, for tests and tools.

**Research and measures**
- [Theory](theory.md): the mathematics (recovery, group commit, indexes, Generic Join, isolation, the cache, merges)
  and the research behind it.
- [Benchmarks](benchmarks.md): the method, and Cepheus against PostgreSQL 18.6 and SQLite 3.54 on one machine.
- [Comparison](comparison.md): the measured numbers beside the giants' published designs (Oracle, Datomic, RocksDB,
  Neo4j, FoundationDB, CockroachDB), and where each one wins.
- [References](references.md): every work cited, checked, with what Cepheus took from it.
- [Glossary](glossary.md): every term, in plain words, with its page.

Every OCaml example in these pages is a whole program that `dune test` compiles and runs, checking the output shown
under it.
