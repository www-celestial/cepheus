# Glossary

Every term the documentation uses, in plain words, with the page that explains it. Where Cepheus' name differs from
the usual one, both are given.

- **AGM bound** — the largest answer a conjunctive query can have, computed from the sizes of its inputs by a
  fractional edge cover (Atserias, Grohe, Marx 2008): N^1.5 for the triangles of N links. A worst-case optimal join
  never works much beyond it. [theory](theory.md#4-generic-join)
- **anti-dependency** (rw edge) — in a history, an edge from a transaction that read a version of an item to the
  transaction that wrote the next version: the reader saw the state before the writer. A cycle through one is Adya's
  G2 anomaly. [case](case-seats.md#real-crashes-and-a-checker-of-the-whole-history)
- **append-only** — a file that is only ever extended, never rewritten in place: the journal's segments.
  [architecture](architecture.md#the-journal-a-write-ahead-log)
- **atomic** (all or nothing) — applied entirely or not at all: a group (G2); a rename; the switch to a new view (one
  atomic store). [guarantees](guarantees.md#g2-all-or-nothing)
- **base** — the runs of a view taken together: the facts as of the last merges, sorted, in columns, in run files read
  through the cache. [architecture](architecture.md#indexes-the-runs-and-the-delta)
- **baseline** — what is measured before anything changes, so that the change has a number to be compared with.
  [case](case-seats.md#2-measure-before-changing-anything)
- **batch** — the writes the writer resolves at once (up to 4,096); several batches can make one frame. [limits](limits.md#writes)
- **Belady's optimum** (OPT) — the eviction policy that removes the page needed the farthest in the future; no real
  policy can know the future, so it is the yardstick. [theory](theory.md#7-pages-and-the-cache)
- **binary join** — a join of two inputs at a time; a plan of them can build more intermediate rows than the answer on
  cyclic questions. [architecture](architecture.md#questions)
- **binding** — a value for each variable of a question; an answer is a binding that makes every pattern a fact.
  [concepts](concepts.md#questions)
- **birthday problem** — the chance that among m people two share a birthday, far higher than intuition says; here,
  the chance that two of m buyers pick the same seat among ten. [case](case-seats.md#a-bound)
- **bottom run** — a run that rests on nothing (its name starts with 20 zeros): it holds the whole state at its last
  group and no retraction. The newest bottom run outside the chain is kept as a fallback.
  [architecture](architecture.md#runs-on-disk)
- **buffer pool** (the cache) — memory where a database keeps pages of its files, deciding itself what stays; Cepheus'
  holds the runs' 16 KiB pages, 1 GiB by default. [architecture](architecture.md#pages-and-the-cache)
- **cardinality** — how many values a thing may have for a property: one (the default) or many (`~many:true`).
  [concepts](concepts.md#properties-and-the-schema)
- **chain** (of runs) — runs that rest on one another from 0: each holds the groups after the last group of the one
  below it. An open takes the chain that reaches the newest group with the fewest runs. [architecture](architecture.md#runs-on-disk)
- **checksum**, **CRC**, **CRC-32C** — a short number computed from bytes, which changes if they change; CRC-32C (the
  Castagnoli polynomial) detects every burst of up to 32 bits and lets random damage through with probability 2⁻³².
  [architecture](architecture.md#the-journal-a-write-ahead-log)
- **clean close**, **marker** — `close` leaves `DIR/closed` once everything is durable, and the next open can skip the
  fsyncs a recovery needs. [operations](operations.md#opening-and-recovery)
- **CLOCK** — an eviction policy that approximates LRU with one bit a page and a moving hand (Corbató 1968).
- **closed loop**, **open loop** — a load where each client waits for its last write before the next, against one where
  writes are due at a fixed rate whatever happens; only the open loop measures latency under stalls.
  [benchmarks](benchmarks.md#method)
- **compaction** — another name for a merge in an LSM-tree. [architecture](architecture.md#merges-a-leveled-log-structured-merge-tree)
- **component** — one of the structures of an LSM-tree: the delta in memory (C0), the runs on disk.
- **confirmed** — a group whose `write` returned `Ok`: it is durable. [guarantees](guarantees.md#the-faults)
- **conjunctive query** — a question made of patterns that must all hold at once (an AND of facts), over shared
  variables. [concepts](concepts.md#questions)
- **coordinated omission** — the error of a closed-loop measure: a client stalled by a slow write sends nothing
  meanwhile, so the writes that would have waited are never counted (Tene 2015). [benchmarks](benchmarks.md#method)
- **counterexample** — a sequence of steps that leads from an initial state to one where an invariant is false; what
  a model checker prints. [case](case-seats.md#a-formal-model-checked-by-a-machine)
- **counting sort** — a sort that counts how many items fall on each key, then places each item at its key's place
  in one pass: O(n + keys), no comparison. A large group's facts are sorted by thing and by property this way.
  [theory](theory.md#9-levels-on-disk-and-large-groups)
- **cut** (of the journal) — after a failed write or fsync, the writer truncates the journal back to the end of its
  last durable frame and forces it, so that the failed write is gone from memory and disk (G13).
  [guarantees](guarantees.md#g13-a-failed-fsync-is-never-trusted)
- **damage** — durable bytes that changed (fault F3); recovery refuses to open rather than drop them, unlike a torn
  write. [architecture](architecture.md#recovery-torn-writes-and-damage)
- **datom** — Datomic's fact: entity, attribute, value, transaction, added. Cepheus' fact is the first three; the group
  and the add-or-retract flag live in the journal. [concepts](concepts.md#facts-the-entityattributevalue-model)
- **delta** — the changes since the last merge, in persistent maps; level 0 of the LSM-tree (C0), about 170 bytes a
  change. [architecture](architecture.md#indexes-the-runs-and-the-delta)
- **delta debugging** — shrinking a failing case by removing parts while it still fails, until every part left is
  needed (Zeller and Hildebrandt 2002). [case](case-seats.md#3-a-hypothesis-one-can-prove-wrong-and-its-cause)
- **dependency graph** (of a history) — the transactions as nodes, and an edge for each way one must come before
  another: ww (it wrote the version the other replaced), wr (the other read what it wrote), rw (an anti-dependency).
  The history is serializable when the graph has no cycle (Adya 1999).
  [case](case-seats.md#real-crashes-and-a-checker-of-the-whole-history)
- **deterministic simulation testing** — running the engine on a simulated disk where one seed decides every event, so
  that any failure replays exactly. [testing](testing.md)
- **dictionary** — the table that numbers each distinct text (and float) once; the rows hold the number.
- **domain** — OCaml 5's unit of parallelism: a thread of execution on its own core, with its own young heap and
  runtime lock; the threads of one domain take turns. [architecture](architecture.md#one-writer-threads-and-domains)
- **durable** — on the disk itself, not only in the kernel's memory: covered by a finished fsync.
- **Elle** — the checker Jepsen uses to find isolation anomalies in a database's recorded history, by inferring its
  dependency graph and looking for cycles (Kingsbury and Alvaro 2020).
- **entity–attribute–value** (EAV) — a model where data is a set of (entity, attribute, value) statements instead of
  tables; Cepheus' (thing, property, value). [concepts](concepts.md#facts-the-entityattributevalue-model)
- **eviction policy** — the rule that picks which page leaves a full cache; Cepheus' is S3-FIFO.
- **`Expect`** — a precondition of a group: a fact that must hold (or a value that must be absent) just before it; the
  writer checks it, and the group fails with `Conflict` otherwise. [concepts](concepts.md#groups-a-write-is-a-transaction)
- **F1, F2, F3, F4** — the faults covered: a process crash, a power loss, silent damage of durable bytes, a failed
  write or fsync. [guarantees](guarantees.md#the-faults)
- **fact** — a triple (thing, property, value). [concepts](concepts.md#facts-the-entityattributevalue-model)
- **failed fsync**, **marked clean** — when an fsync fails, Linux marks the pages it could not write as clean although
  they never reached the disk: ext4 and XFS keep their new bytes in memory, readable until a reboot, and a later fsync
  succeeds without writing them (Rebello et al. 2020). Cepheus never trusts them (G13).
  [guarantees](guarantees.md#the-faults)
- **falsifiable hypothesis** — a claim stated so that an experiment could show it wrong; one that no result could
  contradict says nothing. [case](case-seats.md#3-a-hypothesis-one-can-prove-wrong-and-its-cause)
- **fork** — a temporary database started from a view: the same writes and checks, nothing on disk, free to make.
  [concepts](concepts.md#forks)
- **frame** — the unit of one write and one fsync in the journal: a header, the groups, a trailer.
  [formats](formats.md#journal-segment-dirjournalfirst-group-20-digitsseg)
- **fsync** — the system call that returns once a file's bytes are on the disk.
- **galloping search** (exponential search) — a search that tries 1, 2, 4, 8... places ahead before halving, so that
  finding a place k steps away costs O(log k) (Bentley and Yao 1976); a merge places texts this way.
  [theory](theory.md#8-merges-written-to-a-file)
- **Generic Join** — the worst-case optimal join Cepheus uses: one variable at a time, the smallest candidate set,
  each candidate checked against the other patterns (Ngo, Ré, Rudra 2013). [architecture](architecture.md#questions)
- **ghost queue** — S3-FIFO's memory of pages lately evicted from its small queue; a page asked again soon goes
  straight to the main queue.
- **group** — Cepheus' transaction: a list of operations applied all or nothing, with a number, who, when and why.
  [concepts](concepts.md#groups-a-write-is-a-transaction)
- **group commit** — the writes that arrive while one fsync runs share the next one.
  [architecture](architecture.md#the-journal-a-write-ahead-log)
- **history** — the sequence of every transaction a database applied, with what each read and wrote; Cepheus'
  journal is one, in group order.
- **index word** — the 64-bit form of a value in the indexes: the value itself, or a dictionary number for texts and
  floats; what `fold` gives, and `decode` turns back into the value. [api](api.md#questions)
- **isolation** — what one transaction can see of the others running at the same time.
  [concepts](concepts.md#isolation-exactly-what-a-reader-and-a-writer-see)
- **journal** — Cepheus' write-ahead log: segments of frames of groups. [architecture](architecture.md#the-journal-a-write-ahead-log)
- **journal window** — the 4 MiB of a segment recovery holds at once: a frame that fits is decoded where it lies, a
  longer one checked by pieces and read whole only to replay it. [architecture](architecture.md#recovery-torn-writes-and-damage)
- **large group** — a group of 20,000 operations or more, all additions: it takes a faster path to the same result
  (arrays, a counting sort and a radix sort, a run merged at once). [architecture](architecture.md#large-groups)
- **lazy leveling** — tiering at every level but the last, which is leveled (Dayan and Idreos 2018).
  [theory](theory.md#9-levels-on-disk-and-large-groups)
- **level**, **size ratio** — a place for runs with a capacity in an LSM-tree; each level is T times larger than the
  one above (T, the size ratio, is 4 here): level l holds at most 200,000 × 4^l rows. [architecture](architecture.md#merges-a-leveled-log-structured-merge-tree)
- **leveling**, **tiering** — the two ways an LSM-tree of several levels merges: under leveling each level holds one
  run, and a run coming down is merged with it (Cepheus); under tiering a level holds up to T runs, merged together
  into the next level when full. Leveling writes more and reads fewer runs. [theory](theory.md#9-levels-on-disk-and-large-groups)
- **linearizability** — each operation appears to take effect at one instant between its call and its return
  (Herlihy and Wing 1990); a group, as a write to one object, is linearizable.
- **lost update** — two read-then-writes read the same value and both write, so one change is lost; Cepheus stops it
  only when the read is stated with `Expect`.
- **LSM-tree** (log-structured merge-tree) — recent writes in a small structure in memory, merged in bulk into sorted
  structures on disk (O'Neil et al. 1996). [architecture](architecture.md#merges-a-leveled-log-structured-merge-tree)
- **materialize the conflict** — protect a set against phantoms by keeping one fact that every writer of the set
  expects and changes (Fekete et al. 2005).
- **merge** — the folding of the delta and the newest runs into one new run file; it runs in the background and is
  atomic (G12); `snapshot` is the full merge, of every run. [architecture](architecture.md#merges-a-leveled-log-structured-merge-tree)
- **model checking** — visiting every reachable state of a bounded model and checking invariants in each; TLC does it
  for TLA+. [testing](testing.md#model-checking)
- **net** (run) — a run adds only facts absent below it and retracts only facts present below it, so every count of a
  view is a sum of exact counts. [architecture](architecture.md#indexes-the-runs-and-the-delta)
- **optimistic concurrency control** — read without locks, and check at the end that what was read still holds
  (Kung and Robinson 1981): `Expect`.
- **page** — 16 KiB of a run file, the unit of the cache, checked by its CRC each time it is read from the disk.
- **page cache** (the kernel's) — the operating system's memory copy of files; what a process crash keeps and a power
  loss loses.
- **part** (of a run) — a run has two: the facts it adds (part a) and the facts of the runs below it that it retracts
  (part t). [architecture](architecture.md#indexes-the-runs-and-the-delta)
- **persistent data structure** — one that is never changed in place: a change makes a new version and the old one
  stays valid. [architecture](architecture.md#indexes-the-runs-and-the-delta)
- **phantom** — a new member of a set read earlier (the facts that match a pattern), unseen by a check of single facts.
- **population count** (popcount) — the number of bits set in a word; a rank table's lookup is one.
- **property** — the attribute of a fact; itself a thing (16 to 65,535) with a name, a type and two flags.
- **question** — Cepheus' query: patterns over variables. [concepts](concepts.md#questions)
- **radix sort** (least significant digit first) — a sort that sorts by the lowest digit, then the next, each pass a
  stable counting sort, so that the order of the lower digits is kept: O(n × digits). A large group's values inside a
  property are sorted with 11-bit digits (Knuth, vol. 3, 5.2.5). [theory](theory.md#9-levels-on-disk-and-large-groups)
- **rank table** (rank directory) — a bit for each thing number and, every 32 bits, how many bits are set before
  them: "is thing e here, and at which slot?" is one word and one popcount (Jacobson 1989). Each part of a run has one.
  [theory](theory.md#3-indexes)
- **read amplification** — how many runs a read must visit: one a level under leveling, at most 3 at 10 M facts.
  [architecture](architecture.md#merges-a-leveled-log-structured-merge-tree)
- **read-then-write** — a client transaction that reads a view, then writes a group; validated by its `Expect`s.
- **recovery** — what an open does after a crash: the newest chain of runs that checks, then the journal after it,
  whose newest frame it writes again first. [operations](operations.md#opening-and-recovery)
- **redo log** — a log of changes to apply again after a crash, never to undo; the journal is one.
- **replay** — applying the journal's groups in order to rebuild a state.
- **retry** — running a transaction again after the database refused it (a `Conflict` in Cepheus, a serialization
  failure in PostgreSQL), from a new read.
- **rewrite of the newest frame** — at a recovery after anything but a clean close, the journal's newest frame is
  written again before it is forced, so that pages a failed fsync marked clean are dirty again and really written
  (G13). [guarantees](guarantees.md#g13-a-failed-fsync-is-never-trusted)
- **run**, **run file** — one sorted structure of the LSM-tree on disk: the changes of a range of groups on top of the
  runs below it, in a file `DIR/snapshots/<lo>-<hi>.run`. [architecture](architecture.md#runs-on-disk)
- **S3-FIFO** — the eviction policy of the cache: three FIFO queues (small, main, ghost), nothing moved on a hit (Yang
  et al. 2023). [architecture](architecture.md#pages-and-the-cache)
- **schedule** — one order in which the steps of concurrent transactions interleave.
  [case](case-seats.md#correctness-on-generated-inputs)
- **schema** — the properties and their types; in Cepheus, facts like the rest. [concepts](concepts.md#properties-and-the-schema)
- **segment** — one file of the journal, up to 64 MiB, named by its first group.
- **serializable** — the result equals some execution of the transactions one at a time.
- **serializable snapshot isolation** (SSI) — PostgreSQL's SERIALIZABLE: snapshot isolation plus a check of the
  read-write conflicts between transactions, aborting one when two of them follow each other (Cahill, Röhm and Fekete
  2008; Ports and Grittner 2012).
- **single writer** — one writer thread applies every group of a database, in order. [architecture](architecture.md#one-writer-threads-and-domains)
- **snapshot** (the operation) — `Cepheus.snapshot`, the full merge: the delta and every run into one run, so that the
  next open replays nothing. The file of earlier versions (format 4 and before, `<group>.snap`) held the whole base;
  a run file has replaced it. [api](api.md#operations)
- **snapshot** (the state), **view** — the exact state after one group. [concepts](concepts.md#views)
- **snapshot isolation** — each transaction reads the state at its start, and fails if another wrote the same item
  meanwhile (first committer wins); it lets write skew through.
- **space amplification** — disk space used over the size of the data: the chain, the fallback bottom run, and during
  a full merge a new copy of the base, about three times the base. [architecture](architecture.md#merges-a-leveled-log-structured-merge-tree)
- **strict serializability** — serializable in an order that respects real time. [guarantees](guarantees.md#g4-strict-serializability)
- **structural sharing** — a new version of a persistent structure shares every untouched part with the old one.
- **syncer** — the thread that writes and forces the frames, beside the writer.
- **system property** — `cepheus/name`, `cepheus/type`, `cepheus/many`, `cepheus/unique` (1 to 4).
- **thing** — the entity of a fact: a number, from 65,536 up. [concepts](concepts.md#facts-the-entityattributevalue-model)
- **threat to validity** — a way the proof or the measure could be wrong, to be named and ruled out.
  [case](case-seats.md#threats-to-validity)
- **TLA+**, **TLC** — a language that describes a system's steps as mathematics (Lamport), and its model checker.
  [testing](testing.md#model-checking)
- **torn write** — a write the disk was doing when the power went, of which only part arrived; recovery cuts it.
- **trailer** — the last 16 bytes of a frame, repeating its length and CRCs: a sign that the frame was written whole.
- **transaction** — a unit of work applied entirely or not at all; Cepheus' group.
- **unique** — a property no two things share a value of, checked after each group.
- **value** — the third part of a fact, atomic and typed.
- **variable** — an unknown of a question, numbered from 0.
- **varint** (LEB128), **zigzag** — a whole number in 7-bit pieces, small ones short; zigzag maps signed to unsigned
  (0, -1, 1, -2 → 0, 1, 2, 3). [formats](formats.md#a-group)
- **working view** — the writer's state with every resolved group, durable or not; readers never see it.
- **worst-case optimal join** — a join whose work never exceeds, up to small factors, the largest answer the question
  could have (the AGM bound) (Ngo et al. 2012).
- **write amplification** — how many times a fact is written to the disk by merges for one write by a client: about
  (T + 1)/2 a level under leveling, 5.8 for the 10 M load (14.5 with the one level of earlier versions).
  [architecture](architecture.md#merges-a-leveled-log-structured-merge-tree)
- **write skew** — two transactions read the same facts and each writes a different one, together breaking a rule
  (two doctors each go off call); snapshot isolation allows it, `Expect` refuses it.
  [concepts](concepts.md#isolation-exactly-what-a-reader-and-a-writer-see)
- **write-ahead log** (WAL) — a file where every change is made durable before it counts, so that a crash loses
  nothing confirmed. [architecture](architecture.md#the-journal-a-write-ahead-log)
- **writer** — the thread that resolves groups on the working view, the one writer of a database.
