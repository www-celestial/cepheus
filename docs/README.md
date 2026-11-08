# Cepheus documentation

Read in this order to learn Cepheus; jump to the reference pages when you need an exact answer.

**Learn**
1. [Concepts](concepts.md): facts and the entity–attribute–value model, the schema, groups (transactions), views,
   isolation exactly, questions, forks, databases.
2. [How it works](architecture.md): the journal (a write-ahead log), group commit, recovery, the LSM-tree of runs in
   levels and its merges, large groups, the page cache and S3-FIFO, one writer and the domains, Generic Join, how it
   is tested.
3. [Testing](testing.md): forks for an application's tests, and how Cepheus itself is tested.

**Reference**
- [API](api.md): every public function and type, with its parameters, result, errors and an example.
- [Errors](errors.md): every message, where it comes from, what it means, what to do.
- [Limits and defaults](limits.md): every bound and default value, and where it is set.
- [Guarantees](guarantees.md): G1 to G13, under which faults, their exact conditions, proofs and tests.
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
