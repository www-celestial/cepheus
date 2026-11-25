# Glossary

Every term the documentation uses, in plain words, with the page that explains it. Where Cepheus' name differs from
the usual one, both are given.

- **AEGIS-256** — an authenticated encryption (Wu and Preneel, 2013) with a 256-bit key, nonce and tag, fast on the
  processor's AES instructions: it seals every chunk of the vault. [vault](vault.md#sealed-aegis-256-under-the-owners-key)
- **AGM bound** — the largest answer a conjunctive query can have, computed from the sizes of its inputs by a
  fractional edge cover (Atserias, Grohe, Marx 2008): $N^{1.5}$ for the triangles of $N$ links. A worst-case optimal join
  never works much beyond it. [theory](theory.md#4-generic-join)
- **anti-dependency** (rw edge) — in a history, an edge from a transaction that read a version of an item to the
  transaction that wrote the next version: the reader saw the state before the writer. A cycle through one is Adya's
  G2 anomaly. [case](case-seats.md#real-crashes-and-a-checker-of-the-whole-history)
- **append-only** — a file that is only ever extended, never rewritten in place: the journal's segments.
  [architecture](architecture.md#the-journal-a-write-ahead-log)
- **asserted fact** — a fact a program wrote (`Add`), as opposed to one a rule derived; the extensional database (EDB)
  of Datalog. A fact can be both asserted and derived. [rules](rules.md#what-the-database-holds-the-least-model)
- **atomic** (all or nothing) — applied entirely or not at all: a group (G2); a rename; the switch to a new view (one
  atomic store). [guarantees](guarantees.md#g2-all-or-nothing)
- **atomic register**, **regular register**, **new-old inversion** — Lamport's classes of shared registers (On
  Interprocess Communication, 1986): a read of a *regular* register returns the last value written before it or one
  being written meanwhile, so two reads one after the other may see a new value and then the old one (a **new-old
  inversion**); an *atomic* register forbids it, every read and write appearing at one instant. Linearizable reads
  are atomic: G15 forbids the inversion; the lease the design first proposed allowed it. [server](server.md#local-reads-g15)
- **Avg** — the mean of a variable in each group of a report, from its exact sum: of ints and floats a Float, of money
  money rounded to its scale, of dates a date; SQL's `avg`. [Cesia](cesia.md#reports-avg-countx-values-quantile-variance-stddev-trunc)
- **back-pressure** — a slow side slowing the fast one down instead of being flooded: at its limit of writes in flight
  a connection is no longer read, the kernel's buffers fill, and the program's writes wait. Nothing is dropped.
  [server](server.md#order-pipelining-and-back-pressure)
- **Backward/Forward** (B/F) — the algorithm that keeps derived facts right when facts go (Motik et al. 2015): a fact
  that lost a derivation is checked backward (is it asserted, or proved by a rule instance whose body facts are
  proved?), each fact once; proofs propagate forward among the facts checked; a fact without proof goes, and the facts
  it gave are checked in turn. [rules](rules.md#retraction-backwardforward)
- **base** — the runs of a view taken together: the facts as of the last merges, sorted, in columns, in run files read
  through the cache. [architecture](architecture.md#indexes-the-runs-and-the-delta)
- **baseline** — what is measured before anything changes, so that the change has a number to be compared with.
  [case](case-seats.md#2-measure-before-changing-anything)
- **batch** — the writes the writer resolves at once (up to 4,096); several batches can make one frame. [limits](limits.md#writes)
- **Belady's optimum** (OPT) — the eviction policy that removes the page needed the farthest in the future; no real
  policy can know the future, so it is the yardstick. [theory](theory.md#7-pages-and-the-cache)
- **Bigarray** — an OCaml array whose elements lie outside the heap the garbage collector manages, in one plain block
  of memory (`Stdlib.Bigarray`), each element of a fixed kind and size (an int32 in 4 bytes, an unsigned 16-bit int in
  2): the collector never scans, copies or moves its contents. A large group's facts live in Bigarrays: 14 bytes a fact
  where an OCaml array of records would take 8 a field and be scanned by every major collection.
  [architecture](architecture.md#large-groups)
- **binary join** — a join of two inputs at a time; a plan of them can build more intermediate rows than the answer on
  cyclic questions. [architecture](architecture.md#questions)
- **binding** — a value for each variable of a question; an answer is a binding that makes every pattern a fact.
  [concepts](concepts.md#questions)
- **birthday problem** — the chance that among m people two share a birthday, far higher than intuition says; here,
  the chance that two of m buyers pick the same seat among ten. [case](case-seats.md#a-bound)
- **bit packing** — numbers of $w$ bits stored one after the other with no byte between them: field $i$ is bits $i \cdot w$ to
  $i \cdot w + w - 1$, read with one 8-byte load, a shift and a mask. With a frame of reference, how runs and the journal
  store numbers. [formats](formats.md#a-group)
- **BLAKE2b** — a cryptographic hash function (RFC 7693): from any bytes, 32 bytes (BLAKE2b-256) from which the input
  cannot be found again. The server keeps tokens only as their BLAKE2b-256 hash. [server](server.md#tokens)
- **block** (thing block, row block) — the unit a run's values are coded in: 128 things (by thing: a header with a
  base and a width for each property, then a record a thing with its one-valued properties, and columns for the
  others) or 128 rows of a property (by property: values and
  things); any value of a block is read without decoding the others.
  [formats](formats.md#run-dirsnapshotslo-20-digits-hi-20-digitsrun)
- **body** (of a rule) — its patterns and ranges: the question whose answers give the head. [rules](rules.md#a-rule-is-a-question-with-a-conclusion)
- **bottom run** — a run that rests on nothing (its name starts with 20 zeros): it holds the whole state at its last
  group and no retraction.
  [architecture](architecture.md#runs-on-disk)
- **buffer pool** (the cache) — memory where a database keeps pages of its files, deciding itself what stays; Cepheus'
  holds the runs' 16 KiB pages, 1 GiB by default. [architecture](architecture.md#pages-and-the-cache)
- **cascade**, **clear**, **refuse** (on delete) — what a link that names a kind does when the thing it links to
  stops being of the kind (`onDelete`): `cascade` deletes the linking thing too, `clear` retracts the link, `refuse`
  (the default) refuses the group; SQL's `ON DELETE CASCADE`, `SET NULL` and `RESTRICT` (or `NO ACTION`).
  [Cesia](cesia.md#deleting-a-thing)
- **cardinality** — how many values a thing may have for a property: one (the default) or many (`~many:true`).
  [concepts](concepts.md#properties-and-the-schema)
- **certificate** — a public key and a name, signed by a certificate authority: what a server shows in a TLS handshake
  to prove it is the one the client meant. [server](server.md#tls)
- **certificate authority** (CA) — the key whose signatures a client trusts; each cluster has its own, made by
  `cepheus cluster init` (ECDSA, P-256), whose private key belongs offline. [server](server.md#tls)
- **Cesia client** — the package `cesia/cepheus` of this repository: the Cesia functions `Connect`, `Kind`, `Insert`,
  `Get`, `Update`, `Write`, `Find`, `Fork`, `Close`, over an engine in OCaml (`cesia/native/`) that speaks the
  protocol and reads locally on the server's machine. [Cesia](cesia.md)
- **chain** (of runs) — runs that rest on one another from 0: each holds the groups after the last group of the one
  below it. An open takes the chain that reaches the newest group with the fewest runs. [architecture](architecture.md#runs-on-disk)
- **checkpoint** (of a journal, with the commit buffer) — an fsync of a database's journal, which makes durable in it
  the frames the commit buffer forced; a file of the buffer is emptied only once each journal with frames in it had
  one. PostgreSQL's checkpoint writes its data pages so that its WAL can be recycled: the same role.
  [the server](server.md#many-databases-one-fsync-the-commit-buffer)
- **checksum**, **CRC**, **CRC-32C** — a short number computed from bytes, which changes if they change; CRC-32C (the
  Castagnoli polynomial, the checksum of iSCSI, RFC 3720) detects every burst of up to 32 bits and lets random damage
  through with probability $2^{-32}$. Cepheus computes it by the processor's own instruction (SSE4.2 on x86-64, CRC32 on
  arm64). [architecture](architecture.md#the-journal-a-write-ahead-log)
- **chunk** (of a large group) — 65,536 operations of a large group (`Bulk.chunk`), the unit of work that the domains
  take in turn while the group is mapped, checked and sorted (morsel-driven scheduling, [Leis 2014]).
  [architecture](architecture.md#large-groups)
- **clean close**, **marker** — `close` leaves `DIR/closed` once everything is durable, and the next open can skip the
  fsyncs a recovery needs. [operations](operations.md#opening-and-recovery)
- **client** — a program connected to the server: it proves who it is with a token and sends requests.
  [server](server.md#what-it-is-and-why)
- **CLOCK** — an eviction policy that approximates LRU with one bit a page and a moving hand (Corbató 1968).
- **closed loop**, **open loop** — a load where each client waits for its last write before the next, against one where
  writes are due at a fixed rate whatever happens; only the open loop measures latency under stalls.
  [benchmarks](benchmarks.md#method)
- **closure module** — the writer's way of keeping a transitive property's facts (Hu, Motik, Horrocks 2019): each new
  fact of the closure found once by walks, instead of once a path by the rule; recognised in two shapes, prp-trp and
  the linear pair. [rules](rules.md#transitive-closures-the-closure-module)
- **class of equal things** — the things the rules made the same (OWL's owl:sameAs): one of them, the representative,
  holds the class's facts, and each other member x holds `[x cepheus/same r]`. [rules](rules.md#equality-classes-of-equal-things)
- **cluster** — the servers that hold the same databases; one machine is a cluster of one peer. Its id (`cph-c-` and
  16 hex digits) is in `cluster.toml` and in every Welcome. [server](server.md#clustertoml)
- **column order** (vertical partitioning) — the third order of a run (format 8): each property's rows (thing, value)
  apart from the others', in thing order, a thing's values sorted (Abadi et al. 2007). A lookup of a thing's property
  reads one rank word, one directory entry and one field of that property's bytes alone; a question over a few
  properties reads only theirs. [formats](formats.md#run-dirsnapshotslo-20-digits-hi-20-digitsrun)
- **columns** (columnar coding) — storing the values of one field together rather than record by record, so that
  alike values sit side by side and code in few bits: the journal codes a group's kinds, things and each property's
  values as columns; a run's order by property is a column of each property. [formats](formats.md#a-group)
- **commit buffer** — the server's own forced log (`DATA/server.wal.1` and `.2`): the frames of all its databases go
  into it by rounds, one fsync a round for the whole server, as PostgreSQL's databases share its WAL; each database's
  journal is written at once but forced only at its checkpoints. [the server](server.md#many-databases-one-fsync-the-commit-buffer)
- **committed** (Raft) — an entry of a cluster's log that a majority of the servers holds forced, counted by a leader
  for an entry of its own term; never lost after that. [server](server.md#one-log-for-the-cluster)
- **compaction** — another name for a merge in an LSM-tree. [architecture](architecture.md#merges-a-leveled-log-structured-merge-tree)
- **component** — one of the structures of an LSM-tree: the delta in memory (C0), the runs on disk.
- **confirmed** — a group whose `write` returned `Ok`: it is durable. [guarantees](guarantees.md#the-faults)
- **conjunctive query** — a question made of patterns that must all hold at once (an AND of facts), over shared
  variables. [concepts](concepts.md#questions)
- **connection limit** — the most connections the server keeps open at once (`max_connections`, 512 by default); a
  new one over it takes the slot of the oldest connection that has shown no token, or is closed at its accept.
  [server](server.md#clustertoml)
- **constant-time comparison** — comparing two secrets byte by byte to the end, whatever the first difference, so that
  the time taken tells an attacker nothing about how much of a guess was right. [server](server.md#tokens)
- **constraint** — a rule whose head is `Never`: an answer of its body refuses the group (G18).
  [rules](rules.md#constraints-never)
- **coordinated omission** — the error of a closed-loop measure: a client stalled by a slow write sends nothing
  meanwhile, so the writes that would have waited are never counted (Tene 2015). [benchmarks](benchmarks.md#method)
- **copy of the databases** (catch-up) — in a Raft cluster, what a follower takes when the leader can no longer send it
  entries (they are before the leader's log start): each database's files, as `cepheus backup` copies them, checked as
  `cepheus verify` checks them, installed at the follower's next start; the role of Raft's InstallSnapshot.
  [server](server.md#a-server-behind-the-logs-start-a-copy-of-the-databases)
- **counterexample** — a sequence of steps that leads from an initial state to one where an invariant is false; what
  a model checker prints. [case](case-seats.md#a-formal-model-checked-by-a-machine)
- **counting** (view maintenance) — keeping for each derived fact the number of its derivations, deleting it at zero
  (Gupta et al. 1993); exact for nonrecursive rules only: two facts that derive each other keep each other's count
  above zero. [rules](rules.md#retraction-backwardforward)
- **counting sort** — a sort that counts how many items fall on each key, then places each item at its key's place
  in one pass: $O(n + \text{keys})$, no comparison. A large group's facts are sorted by property this way, in chunks counted
  and spread at once by several domains.
  [theory](theory.md#9-levels-on-disk-and-large-groups)
- **Count(x)**, **COUNT(DISTINCT x)** — the number of different values of a variable in a group, an Optional's
  missing value not counted; `Count()` counts the answers. [Cesia](cesia.md#reports-avg-countx-values-quantile-variance-stddev-trunc)
- **cut** (of the journal) — after a failed write or fsync, the writer truncates the journal back to the end of its
  last durable frame and forces it, so that the failed write is gone from memory and disk (G13).
  [guarantees](guarantees.md#g13-a-failed-fsync-is-never-trusted)
- **damage** — durable bytes that changed (fault F3); recovery refuses to open rather than drop them, unlike a torn
  write. [architecture](architecture.md#recovery-torn-writes-and-damage)
- **Datalog** — the rule language of deductive databases: rules `H ← B1, …, Bn` over relations, without function
  symbols; its programs always end and have a least model. Cepheus' rules are Datalog over facts.
  [rules](rules.md#a-rule-is-a-question-with-a-conclusion)
- **datom** — Datomic's fact: entity, attribute, value, transaction, added. Cepheus' fact is the first three; the group
  and the add-or-retract flag live in the journal. [concepts](concepts.md#facts-the-entityattributevalue-model)
- **daylight saving time**, **summer time** — the hours a zone moves its clocks forward for part of the year (Paris:
  UTC+2 from the last Sunday of March to the last of October, UTC+1 the rest): a day of 23 hours in spring, of 25 in
  autumn, which `Trunc` follows. [Cesia](cesia.md#reports-avg-countx-values-quantile-variance-stddev-trunc)
- **Delete** (of a thing) — the operation that deletes a thing of a kind, SQL's `DELETE`: the thing's facts of the
  kind retracted at the writer, and the links to it followed, in one group; the thing stays in the history.
  [Cesia](cesia.md#deleting-a-thing)
- **delta** — the changes since the last merge, in persistent maps; level 0 of the LSM-tree (C0), about 170 bytes a
  change. [architecture](architecture.md#indexes-the-runs-and-the-delta) In the reasoner, $\Delta$ is another thing: the
  facts a group changes, from which semi-naive evaluation derives (round 0 is the group's asserted additions).
  [rules](rules.md#how-the-writer-keeps-it-semi-naive-evaluation)
- **delta debugging** — shrinking a failing case by removing parts while it still fails, until every part left is
  needed (Zeller and Hildebrandt 2002). [case](case-seats.md#3-a-hypothesis-one-can-prove-wrong-and-its-cause)
- **delta query** — the change of a join's answer when facts are added or removed, computed from those facts alone: each
  new binding found once, at the first pattern that matches an added fact (Ammar et al. 2018).
  [Cepheus from Cesia](cesia.md#watch-live-questions)
- **deltas** (delta coding) — numbers stored as their differences from the number before: a growing sequence (the
  things of a load: 0 and 1) takes a bit or two a number. The journal's columns take it block by block when it is
  shorter than the frame of reference. [formats](formats.md#a-group)
- **dependency graph** (of a history) — the transactions as nodes, and an edge for each way one must come before
  another: ww (it wrote the version the other replaced), wr (the other read what it wrote), rw (an anti-dependency).
  The history is serializable when the graph has no cycle (Adya 1999).
  [case](case-seats.md#real-crashes-and-a-checker-of-the-whole-history)
- **derivation** (rule instance) — a rule with one fact for each body atom, making its body true; it derives its head.
  A fact can have many derivations. [rules](rules.md#how-the-writer-keeps-it-semi-naive-evaluation)
- **derived fact** — a fact a rule gives; held in the view like any fact, marked "only derived" when no program
  asserted it (bit 63 of its value word in a run). [rules](rules.md)
- **deterministic simulation testing** — running the engine on a simulated disk where one seed decides every event, so
  that any failure replays exactly. [testing](testing.md)
- **description** — in OWL 2 RL's vocabulary, the thing that holds a property's axioms: `[d, owl/Property, p]`, then
  `[d, owl/Domain, c]`, `[d, owl/Transitive, true]` (a property thing takes no fact of its own). [rules](rules.md#the-vocabulary)
- **dictionary** — the table that numbers each distinct text (and float) once; the rows hold the number. A run keeps
  its texts' bytes, their offsets and a hash table of them.
- **dirty page**, **writeback** — a page of the kernel's page cache that a program wrote and the disk does not hold yet
  is dirty; writeback is the kernel writing it to the disk, at an fsync or in the background. A large group's frame
  is forced by pieces while its run is made, so that its writeback overlaps the merge. [architecture](architecture.md#large-groups)
- **domain** — OCaml 5's unit of parallelism: a thread of execution on its own core, with its own young heap and
  runtime lock; the threads of one domain take turns. [architecture](architecture.md#one-writer-threads-and-domains)
- **DRed** (delete and rederive) — the maintenance algorithm that deletes every consequence of the deleted facts, then
  derives again those that still have a proof (Gupta et al. 1993). [rules](rules.md#retraction-backwardforward)
- **durable** — on the disk itself, not only in the kernel's memory: covered by a finished fsync.
- **EDB, IDB** — extensional and intensional database: the asserted facts, and the derived ones.
  [rules](rules.md#what-the-database-holds-the-least-model)
- **Elle** — the checker Jepsen uses to find isolation anomalies in a database's recorded history, by inferring its
  dependency graph and looking for cycles (Kingsbury and Alvaro 2020).
- **engine** (of a native package) — the OCaml of a Cesia native package, compiled to machine code in one file
  (`native/cepheus-TAG.cmxs`, an OCaml plugin: a shared library the running program links to itself) that Cesia loads
  at the package's first call, and that reaches the program only through Cesia's frozen native interface, `Cesia_v1`.
  [Cesia](cesia.md#the-package)
- **entity–attribute–value** (EAV) — a model where data is a set of (entity, attribute, value) statements instead of
  tables; Cepheus' (thing, property, value). [concepts](concepts.md#facts-the-entityattributevalue-model)
- **epoch** — a numbered part of a database's history between two promotions: `DIR/epochs` lists each epoch and its
  first group (PostgreSQL calls it a timeline). A copy may follow a primary only if its history is a prefix of the
  primary's. [server](server.md#promotion-by-hand)
- **eviction policy** — the rule that picks which page leaves a full cache; Cepheus' is S3-FIFO.
- **exact sum** — a sum kept as an integer of as many 30-bit parts as it needs (a float at its binary place), so that it
  rounds nothing until the end: the same result whatever the order of the terms, which is what makes a report's mean
  and spread the same on any number of cores and in a watch. [Cesia](cesia.md#reports-avg-countx-values-quantile-variance-stddev-trunc)
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
- **fiber** — one of Cesia's light threads (a green thread, as Go's goroutines): many take turns on one core, each with
  its own stack, and one that waits (for a reply of the server) lets the others run. Every fiber of a program shares
  its database's one connection. [Cesia](cesia.md#many-fibers-one-connection)
- **file descriptor**, **descriptor passing** (`SCM_RIGHTS`) — a descriptor is a process's number for an open file;
  a Unix-domain socket can carry descriptors to another process, which receives its own descriptors of the same open
  files (unix(7)). The server passes a local reader its run files and its visibility page this way: the reader needs
  no permission on the data directory. [server](server.md#local-reads-g15)
- **fixpoint** (least) — a set of facts that applying the rules does not change; the least one containing the asserted
  facts is the least model. [rules](rules.md#what-the-database-holds-the-least-model)
- **floor** — the lowest serial of a session still waiting for its reply, sent with each write: the receipts below it
  are forgotten. [server](server.md#writes-applied-once-sessions-g14)
- **follow stream**, **follower** — a follow stream is the second connection of a local reader, on which the server
  sends every frame the writer makes, before its fsync, and the database's runs; the follower is the copy of the
  database the reader keeps from it, applying each frame as the server did. [server](server.md#local-reads-g15)
- **foreign key** — in SQL, a column whose values must be the keys of another table's rows (`REFERENCES client`);
  in Cepheus, a link that names a kind (`Link(to = "client")`): each thing it links to is of that kind, checked at each
  write. [Cesia](cesia.md#kinds-and-the-values-they-hold)
- **fork** — a temporary database started from a view: the same writes and checks, nothing on disk, free to make.
  [concepts](concepts.md#forks)
- **frame** — the unit of one write and one fsync in the journal: a header, the groups, a trailer.
  [formats](formats.md#journal-segment-dirjournalfirst-group-20-digitsseg)
- **frame of reference** (FOR) — a block of numbers stored as their least value (the base) and, for each, its
  difference from the base in as many bits as the largest difference needs: values between 20,000 and 23,650 take
  12 bits each, not 64 (Goldstein et al. 1998; PFOR, its patched form, Zukowski et al. 2006).
  [theory](theory.md#11-compressed-runs-and-journal-the-coding-and-its-bound)
- **fresh server** — in a Raft cluster, a server that started with no Raft state (a new cluster's, or one whose data
  directory was lost): it takes no part until ⌊n/2⌋ + 1 other servers told it their terms and logs.
  [server](server.md#a-server-started-on-an-empty-data-directory)
- **frozen relation** — a small relation the rules were unfolded on: while its facts stay those, the unfolded rules
  run; a group that changes one of them runs the rules as written. [rules](rules.md#specialisation-by-small-relations)
- **fsync** — the system call that returns once a file's bytes are on the disk.
- **fuzzing**, **libFuzzer**, **sanitizer** — fuzzing runs a function on millions of inputs that a program mutates
  to reach new paths in the code, and stops at the first that fails; libFuzzer is LLVM's fuzzer. A sanitizer is a
  check the compiler adds to every memory access (AddressSanitizer: a read or write outside its block) or to every
  operation C leaves undefined (UndefinedBehaviorSanitizer). The C files of the CRC and of TLS are fuzzed with both.
  [testing](testing.md#the-c-file-fuzzed)
- **galloping search** (exponential search) — a search that tries 1, 2, 4, 8... places ahead before halving, so that
  finding a place $k$ steps away costs $O(\log k)$ (Bentley and Yao 1976); the leapfrog seeks so.
  [theory](theory.md#8-merges-written-to-a-file)
- **gaps** — in a row block, the things of a value stored as the difference from the thing before (minus one):
  "the invoices that are unpaid", close together, take 3-4 bits each instead of 9-10.
  [formats](formats.md#run-dirsnapshotslo-20-digits-hi-20-digitsrun)
- **Generic Join** — the worst-case optimal join Cepheus uses: one variable at a time, the smallest candidate set,
  each candidate checked against the other patterns (Ngo, Ré, Rudra 2013). [architecture](architecture.md#questions)
- **ghost queue** — S3-FIFO's memory of pages lately evicted from its small queue; a page asked again soon goes
  straight to the main queue.
- **group** — Cepheus' transaction: a list of operations applied all or nothing, with a number, who, when and why.
  [concepts](concepts.md#groups-a-write-is-a-transaction)
- **group commit** — the writes that arrive while one fsync runs share the next one.
  [architecture](architecture.md#the-journal-a-write-ahead-log)
- **handover** — a primary's clean stop sending its last groups to its replica and waiting for it to hold them: after
  it, no confirmed group is missing on the replica. [server](server.md#promotion-by-hand)
- **handshake** — the first round trips of a TLS connection, where the two sides agree on keys and the server shows
  its certificate: about 4.8 ms of computation here, which is why connections live long. [server](server.md#tls)
- **hash table** (open addressing, linear probing) — a table of slots where a key goes at the slot its hash names, or
  the next free one after it; a lookup probes from that slot until it finds the key or an empty slot. At most half
  full, about 1.5 probes for a key that is there (Knuth, 6.4). Each run's texts are found by one.
  [formats](formats.md#run-dirsnapshotslo-20-digits-hi-20-digitsrun)
- **head** (of a rule) — the pattern it gives for each answer of its body, or `Never`.
  [rules](rules.md#a-rule-is-a-question-with-a-conclusion)
- **history** — the sequence of every transaction a database applied, with what each read and wrote; Cepheus'
  journal is one, in group order.
- **IANA time zone database** (tz, zoneinfo) — the rules of every zone's local time since 1970 and before (offsets,
  summer times), kept by the IANA and shipped by every system (`tzdata`); zones are named `Area/City`, as
  `Europe/Paris`. [Cesia](cesia.md#reports-avg-countx-values-quantile-variance-stddev-trunc)
- **idle timeout** — the time a connection may go without a whole request before the server closes it
  (`idle_timeout`, 600 s by default); before its Hello, 10 s at most, its TLS handshake included.
  [server](server.md#clustertoml)
- **inequality join** — a join on $<$ or $\le$ between two variables rather than on equality: the invoices paid
  after their due date. Read from sorted values rather than as a cross product and a filter (Khayyat et al. 2015):
  `Less`. [Cesia](cesia.md#less-lessorequal-and-optional)
- **index word** — the 64-bit form of a value in the indexes: the value itself, or a dictionary number for texts and
  floats; what `fold` gives, and `decode` turns back into the value. [api](api.md#questions)
- **information bound** (entropy) — the fewest bits any coding needs for some data, from how many different values it
  could have taken: a status that is "paid" 70 % of the time, "unpaid" 20 % and "late" 10 % needs 1.16 bits on
  average, not 2. [theory](theory.md#11-compressed-runs-and-journal-the-coding-and-its-bound)
- **instruction** (of the processor), **intrinsic** — one operation the processor executes; an intrinsic is a C
  function that the compiler turns into one given instruction (`_mm_crc32_u64` into `crc32` on x86-64, `__crc32cd`
  into `crc32cx` on arm64). OCaml's compiler has none for these, hence the C file. [architecture](architecture.md#the-journal-a-write-ahead-log)
- **I/O domain** — one of the k OCaml domains over which the server spreads its connections, each with its own runtime
  lock, so that k requests run at once. [server](server.md#what-it-is-and-why)
- **isolation** — what one transaction can see of the others running at the same time.
  [concepts](concepts.md#isolation-exactly-what-a-reader-and-a-writer-see)
- **journal** — Cepheus' write-ahead log: segments of frames of groups. [architecture](architecture.md#the-journal-a-write-ahead-log)
- **journal window** — the 4 MiB of a segment recovery holds at once: a frame that fits is decoded where it lies, a
  longer one checked by pieces and read whole only to replay it. [architecture](architecture.md#recovery-torn-writes-and-damage)
- **kind** (Cesia client) — a sort of thing in a Cesia program: a name and fields, each a property of a type
  (`client/City` for the field `City` of the kind `client`); `Insert` and `Get` read and write a thing's fields of a
  kind as a map. [Cesia](cesia.md#kinds-and-the-values-they-hold)
- **link that names a kind**, **of a kind** — a link property with a kind (`cepheus/to`): its values are things of
  that kind. A thing is of a kind while it has a fact of one of the kind's properties that a write asserted.
  [API](api.md#links-that-name-a-kind-foreign-keys)
- **LEFT JOIN** (left outer join) — SQL's join that keeps each row of its left side even when the right side has
  nothing for it, the right side's columns then NULL; Cepheus's `Optional`, whose cell is then `missing`.
  [Cesia](cesia.md#less-lessorequal-and-optional)
- **leader**, **follower** — in a Raft cluster, the one server of a term that takes writes and serves reads, and the
  others, which store its entries and vote. [server](server.md#a-cluster-of-three-raft)
- **lagging** — the end of a watch whose program fell too far behind (8 MiB of pushes it has not taken, at the server):
  the package watches again from its last group. [server](server.md#live-questions-watch)
- **large group** — a group of 20,000 operations or more, all additions: it takes a faster path to the same result
  (its facts in Bigarrays, mapped and sorted by several domains, merged at once into a run while its frame is written
  beside, by pieces). [architecture](architecture.md#large-groups)
- **lazy leveling** — tiering at every level but the last, which is leveled (Dayan and Idreos 2018).
  [theory](theory.md#9-levels-on-disk-and-large-groups)
- **leadership transfer** — the clean stop of a Raft cluster's leader: it gives up its lease, waits until the most
  up-to-date follower holds its whole log, and tells it to stand for election at once (`Timeout_now`).
  [server](server.md#a-clean-stop-of-the-leader-leadership-handed-over)
- **leapfrog** (leapfrog intersection) — the intersection of sorted lists by seeks: the lists in the order of their
  current keys, each in turn jumps to the first key at least the largest (by galloping), and a key all reach is in
  every list (Veldhuizen 2014). A question's level intersects its slices so instead of looking each candidate up.
  [theory](theory.md)
- **lease** — a permission that ends by itself after a time, unless renewed (Gray and Cheriton 1989). The design
  proposed one for local reads; it was left for the visibility number, which needs no clock (between machines, a Raft
  leader serves its reads under a lease). [server](server.md#the-rules-the-design-first-had-and-why-they-were-left)
- **least model** — the smallest set of facts containing the asserted ones and closed under the rules: what a
  database with rules holds (G17). [rules](rules.md#what-the-database-holds-the-least-model)
- **level**, **size ratio** — a place for runs with a capacity in an LSM-tree; each level is $T$ times larger than the
  one above ($T$, the size ratio, is 4 here): level $l$ holds at most $200{,}000 \times 4^l$ rows. [architecture](architecture.md#merges-a-leveled-log-structured-merge-tree)
- **leveling**, **tiering** — the two ways an LSM-tree of several levels merges: under leveling each level holds one
  run, and a run coming down is merged with it (Cepheus); under tiering a level holds up to T runs, merged together
  into the next level when full. Leveling writes more and reads fewer runs. [theory](theory.md#9-levels-on-disk-and-large-groups)
- **linearizability** — each operation appears to take effect at one instant between its call and its return
  (Herlihy and Wing 1990); a group, as a write to one object, is linearizable.
- **live question**, **watch** — a question kept answered: its answer, then the change of its rows at each durable group
  that changes them (`cepheus.Watch`). [Cepheus from Cesia](cesia.md#watch-live-questions),
  [G21](guarantees.md#g21-live-questions)
- **local read** — a read a program makes in its own memory, on the server's machine, from the database it follows:
  no round trip, linearizable (G15). [server](server.md#local-reads-g15)
- **loopback** — the network address of the machine itself (127.0.0.1, ::1): TCP that never leaves the machine.
  [server](server.md#what-it-is-and-why)
- **lost update** — two read-then-writes read the same value and both write, so one change is lost; Cepheus stops it
  only when the read is stated with `Expect`.
- **LSM-tree** (log-structured merge-tree) — recent writes in a small structure in memory, merged in bulk into sorted
  structures on disk (O'Neil et al. 1996). [architecture](architecture.md#merges-a-leveled-log-structured-merge-tree)
- **materialisation** — keeping the derived facts stored and up to date, so that questions read them as facts; the
  other way is to reason at question time (query rewriting, magic sets). [rules](rules.md)
- **materialize the conflict** — protect a set against phantoms by keeping one fact that every writer of the set
  expects and changes (Fekete et al. 2005).
- **median** — the middle value of a group in order (between the two middle ones for an even count): `Median(x)`, the
  quantile 0.5. [Cesia](cesia.md#reports-avg-countx-values-quantile-variance-stddev-trunc)
- **memory BIO** — an OpenSSL buffer in memory standing for the network: OpenSSL reads the bytes it is given and
  writes the bytes to send there, never touching the socket, so it never waits. [server](server.md#tls)
- **merge** — the folding of the delta and the newest runs into one new run file; it runs in the background and is
  atomic (G12); `snapshot` is the full merge, of every run. [architecture](architecture.md#merges-a-leveled-log-structured-merge-tree)
- **model checking** — visiting every reachable state of a bounded model and checking invariants in each; TLC does it
  for TLA+. [testing](testing.md#model-checking)
- **missing** (cell) — the cell of a row where an `Optional` found no value: `missing` in Cesia, `Value.missing` in
  OCaml, sorted after every value in both directions. [Cesia](cesia.md#less-lessorequal-and-optional)
- **monotone sequence** — numbers that never decrease (offsets), stored in blocks of 128 as a frame of reference with
  each block's header apart, so that entry q is one header and one field.
  [formats](formats.md#run-dirsnapshotslo-20-digits-hi-20-digitsrun)
- **monotonic writes** — a session guarantee (Terry et al. 1994): a program's writes are applied in the order it sent
  them. [server](server.md#order-pipelining-and-back-pressure)
- **mutual TLS** — TLS where both sides show a certificate of the same CA; between Cepheus servers (a primary and its
  replicas, on the peer port), not for programs, which show a token. [server](server.md#tls)
- **native package** — a Cesia package whose functions are, under their Cesia code, an engine in OCaml compiled once:
  the way Cesia runs OCaml that comes from another project; running one needs the permission `native=LABEL`, total
  trust, as `ffi=` for C. [Cesia](cesia.md#the-package)
- **net** (run) — a run adds only facts absent below it and retracts only facts present below it, so every count of a
  view is a sum of exact counts. [architecture](architecture.md#indexes-the-runs-and-the-delta)
- **no-op** (Raft) — a new leader's first entry, empty, of its own term: its commit commits every entry before it.
  [server](server.md#elections)
- **optimistic concurrency control** — read without locks, and check at the end that what was read still holds
  (Kung and Robinson 1981): `Expect`.
- **Optional** — a pattern of a question that may have no fact: SPARQL's `OPTIONAL` and SQL's `LEFT JOIN` of one
  property. [Cesia](cesia.md#less-lessorequal-and-optional)
- **OWL 2 RL** — the part of the W3C's ontology language OWL 2 that rules compute completely: 78 rules in six tables
  (OWL 2 Profiles, section 4.3); in Cepheus a library of rules, `Cepheus.Owl`. [rules](rules.md#owl-2-rl-a-library-of-rules)
- **origin** — the token's name, session, serial and floor that a group written through the server carries in its
  `why`: which program wrote it, and how a resent write is recognized.
  [server](server.md#writes-applied-once-sessions-g14)
- **page** — 16 KiB of a run file, the unit of the cache, checked by its CRC each time it is read from the disk.
- **page cache** (the kernel's) — the operating system's memory copy of files; what a process crash keeps and a power
  loss loses.
- **page table** (of a run) — at the end of a run's file, for each page of the run's layout, the page of the file that
  holds it and its CRC: a run is laid out by upper bounds, and only the pages that hold bytes are written.
  [formats](formats.md#run-dirsnapshotslo-20-digits-hi-20-digitsrun)
- **part** (of a run) — a run has two: the facts it adds (part a) and the facts of the runs below it that it retracts
  (part t). [architecture](architecture.md#indexes-the-runs-and-the-delta)
- **PAX** (Partition Attributes Across) — a page layout that keeps, inside each page, the values of each attribute
  together (Ailamaki et al. 2001): columns inside a page. Measured for the thing blocks and set aside: a lookup of a
  thing touched one cache line a property; a block keeps a record a thing for its one-valued properties.
  [theory](theory.md#11-compressed-runs-and-journal-the-coding-and-its-bound)
- **persistent data structure** — one that is never changed in place: a change makes a new version and the old one
  stays valid. [architecture](architecture.md#indexes-the-runs-and-the-delta)
- **phantom** — a new member of a set read earlier (the facts that match a pattern), unseen by a check of single facts.
- **piece** (of a frame) — in a Raft cluster, an entry that carries a MiB of a frame longer than that; the frame is
  applied whole at its last piece, on every server, or never. [server](server.md#one-log-for-the-cluster)
- **pipelining** — sending requests without waiting for the replies of the earlier ones: the round trips overlap, and
  many replies come back in one system call. [server](server.md#order-pipelining-and-back-pressure)
- **plan** (of a rule) — the rule compiled to closures with one atom matched to a given fact, the others joined in an
  order chosen from the store's counts. [rules](rules.md#how-the-writer-keeps-it-semi-naive-evaluation)
- **population count** (popcount) — the number of bits set in a word; a rank table's lookup is one.
- **pre-vote** — a Raft server's question to the others before it stands for election: would you vote for me? It
  raises its term only with a majority of yeses, so a server cut off and back does not disrupt the cluster (Ongaro's
  thesis 9.6). [server](server.md#elections)
- **primary** — the server that takes the writes of a database; its replicas copy its groups. [server](server.md#a-replica)
- **promotion** — a replica made a primary (`cepheus promote`): a new epoch, and writes taken. [server](server.md#promotion-by-hand)
- **proof** — a tree whose leaves are asserted facts and whose nodes are rule instances, each node's children the
  facts of its body; *well-founded*: every child proved before its parent. `why` returns one (G20).
  [rules](rules.md#why)
- **property** — the attribute of a fact; itself a thing (16 to 65,535) with a name, a type and two flags.
- **provenance** — where a fact comes from: here, a proof of it. [rules](rules.md#why)
- **quantile**, **percentile** — the value below which a fraction p of a group's values lie: `Quantile(x, p)`, between
  its two nearest values (Hyndman and Fan's definition 7, PostgreSQL's `percentile_cont`), or one of them with
  `discrete = true` (definition 1, `percentile_disc`). [Cesia](cesia.md#reports-avg-countx-values-quantile-variance-stddev-trunc)
- **question** — Cepheus' query: patterns over variables. [concepts](concepts.md#questions)
- **question timeout** — the time a question may take before it ends with the code `timeout`: the server's
  `question_timeout` (30 s by default), or a program's shorter `timeout`. [server](server.md#clustertoml)
- **radix sort** (least significant digit first) — a sort that sorts by the lowest digit, then the next, each pass a
  stable counting sort, so that the order of the lower digits is kept: $O(n \times \text{digits})$. A large group's values inside a
  property are sorted with 11-bit digits (Knuth, vol. 3, 5.2.5), each pass from one buffer to the other, and so are
  its indexes by thing when it does not come in thing order. [theory](theory.md#9-levels-on-disk-and-large-groups)
- **range restriction** (safety) — every variable of a rule's head appears in its body: a rule gives facts only about
  what the database holds, and the least model is finite. [rules](rules.md#a-rule-is-a-question-with-a-conclusion)
- **rank table** (rank directory) — a bit for each thing number and, every 32 bits, how many bits are set before
  them: "is thing e here, and at which slot?" is one word and one popcount (Jacobson 1989). Each part of a run has one.
  [theory](theory.md#3-indexes)
- **read amplification** — how many runs a read must visit: one a level under leveling, at most 3 at 10 M facts.
  [architecture](architecture.md#merges-a-leveled-log-structured-merge-tree)
- **read your writes** — a session guarantee (Terry et al. 1994): a read sent after a write's receipt arrived sees
  that write. [server](server.md#order-pipelining-and-back-pressure)
- **read-then-write** — a client transaction that reads a view, then writes a group; validated by its `Expect`s.
- **recovery** — what an open does after a crash: the newest chain of runs that checks, then the journal after it,
  whose newest frame it writes again first. [operations](operations.md#opening-and-recovery)
- **recursive rule** — a rule whose head's property is read by its own body, directly or through other rules:
  "every ancestor", at any depth. [rules](rules.md#a-rule-is-a-question-with-a-conclusion)
- **redo log** — a log of changes to apply again after a crash, never to undo; the journal is one.
- **replay** — applying the journal's groups in order to rebuild a state.
- **Raft** — the consensus algorithm a cluster of three or more servers runs (Ongaro and Ousterhout 2014): one
  leader a term, elected by a majority; a write confirmed once a majority holds it forced. [server](server.md#a-cluster-of-three-raft)
- **Raft log** — a cluster's one log: each entry a database's journal frame, whole, or a leader's no-op, with its
  index and term; `DATA/raft/`. [formats](formats.md#the-servers-files)
- **replica** — a server on another machine that keeps a copy of every database of its primary, group for group, in
  its own journal; asynchronous: behind by its lag, the primary never waits for it. [server](server.md#a-replica)
- **replica lag** — the time from a group durable on the primary to the replica's word that it holds it durably.
  [server](server.md#what-a-replica-costs)
- **report** — a question whose `Give` groups its answers and aggregates them: totals, means, medians, spreads, lists,
  by month. [Cesia](cesia.md#reports-avg-countx-values-quantile-variance-stddev-trunc)
- **representative** — the member of a class of equal things that holds the class's facts; reads and questions name a
  thing as its representative. [rules](rules.md#equality-classes-of-equal-things)
- **retry** — running a transaction again after the database refused it (a `Conflict` in Cepheus, a serialization
  failure in PostgreSQL), from a new read.
- **rewriting** (of equality) — keeping the facts of a class of equal things on its representative, instead of copying
  every fact onto every member as the rules of OWL's equality would (Motik et al., AAAI 2015).
  [rules](rules.md#equality-classes-of-equal-things)
- **rewrite of the newest frame** — at a recovery after anything but a clean close, the journal's newest frame is
  written again before it is forced, so that pages a failed fsync marked clean are dirty again and really written
  (G13). [guarantees](guarantees.md#g13-a-failed-fsync-is-never-trusted)
- **right** — what a token may do on a database: `read` (Open, Get, Find) or `write` (and Write); `admin`: the
  server's operations. [server](server.md#rights-g16)
- **right per kind** — a token's right on a database that names kinds: to read only the facts of some kinds, and to add
  only to some (`{ read = ["client", "invoice"], add = ["invoice"] }`); a property's kind is its name up to its first
  `/`. Such a token reads at the server, never in its own memory. [server](server.md#rights-g16)
- **round** (of the commit buffer) — the frames of every database that came while the previous round was forced,
  written as one record of the buffer and forced by one fsync; each frame is confirmed after it. One round is in
  flight at a time. [the server](server.md#many-databases-one-fsync-the-commit-buffer)
- **round trip** — a request and its reply: the time between sending one and receiving the other, most of it the
  kernel's work (system calls, waking the other process). [server](server.md#speed-beside-postgresql)
- **row store**, **column store** — a row store keeps each record's fields together (a lookup of a record reads one
  place), a column store each field's values together (a scan of a field reads one place). A run is both: by thing a
  record a thing for its one-valued properties (with small columns for the others), by property a column of each
  property.
  [theory](theory.md#11-compressed-runs-and-journal-the-coding-and-its-bound)
- **rule** — a question's patterns and a head: whenever the patterns are facts for some values, the head is a fact for
  the same values. A schema thing (`cepheus/name`, `cepheus/rule`). [rules](rules.md)
- **run**, **run file** — one sorted structure of the LSM-tree on disk: the changes of a range of groups on top of the
  runs below it, in a file `DIR/snapshots/<lo>-<hi>.run`. [architecture](architecture.md#runs-on-disk)
- **S3-FIFO** — the eviction policy of the cache: three FIFO queues (small, main, ghost), nothing moved on a hit (Yang
  et al. 2023). [architecture](architecture.md#pages-and-the-cache)
- **same** — the server's answer to a watch resumed `from` a group when nothing the question reads changed since: the
  program's rows are still right, and nothing is sent.
- **schedule** — one order in which the steps of concurrent transactions interleave.
  [case](case-seats.md#correctness-on-generated-inputs)
- **schema** — the properties and their types; in Cepheus, facts like the rest. [concepts](concepts.md#properties-and-the-schema)
- **segment** — one file of the journal, up to 64 MiB, named by its first group.
- **selection** (algorithm) — finding the k-th value of n in order without sorting them all: Hoare's FIND, a partition
  about a pivot repeated on one side, linear on average. [Cesia](cesia.md#reports-avg-countx-values-quantile-variance-stddev-trunc)
- **semi-naive evaluation** — evaluating rules on what changed only: each round matches the facts new in the round
  before, so every rule instance is found once (Bancilhon, Ramakrishnan 1986). [rules](rules.md#how-the-writer-keeps-it-semi-naive-evaluation)
- **serial** — the number a program's library gives each write of its session: 1, 2, 3... A serial sent twice is
  applied once (G14). [server](server.md#writes-applied-once-sessions-g14)
- **serializable** — the result equals some execution of the transactions one at a time.
- **serializable snapshot isolation** (SSI) — PostgreSQL's SERIALIZABLE: snapshot isolation plus a check of the
  read-write conflicts between transactions, aborting one when two of them follow each other (Cahill, Röhm and Fekete
  2008; Ports and Grittner 2012).
- **server** — the process that owns the databases' files and answers the requests of programs over sockets: `cepheus
  serve`. [server](server.md)
- **session** — a number the server gives a connection (Welcome) and that the program's library keeps across
  reconnections; its writes are numbered in it. [server](server.md#writes-applied-once-sessions-g14)
- **session table** — for each database and session, the receipts of the serials at or above the floor; saved in
  `DATA/NAME/sessions` and rebuilt from it and the journal at start.
  [server](server.md#writes-applied-once-sessions-g14)
- **shared mapping** (`mmap`, `MAP_SHARED`) — a file's pages placed in a process's memory so that every process that
  maps them sees one physical copy: a store by one is seen at once by the others. The visibility page is mapped so,
  read-write by the server and read-only by the readers. [server](server.md#local-reads-g15)
- **single writer** — one writer thread applies every group of a database, in order. [architecture](architecture.md#one-writer-threads-and-domains)
- **sink** — a rule whose facts no rule reads: no pattern of any rule can match its head. Its facts start nothing, so a
  change makes them facts by one sort at the end of its reasoning rather than one by one in its working set.
  [rules](rules.md#changes-of-the-rules-in-the-background)
- **slice** — the candidates a pattern offers a variable when its other side is known: a thing's values of a
  property, or the things that hold one value. In a run it is a stretch of rows, sorted: two of them on one level are
  intersected by leapfrogging. [theory](theory.md)
- **snapshot** (the operation) — `Cepheus.snapshot`, the full merge: the delta and every run into one run, so that the
  next open replays nothing. The file of earlier versions (format 4 and before, `<group>.snap`) held the whole base;
  a run file has replaced it. [api](api.md#operations)
- **snapshot** (the state), **view** — the exact state after one group. [concepts](concepts.md#views)
- **snapshot isolation** — each transaction reads the state at its start, and fails if another wrote the same item
  meanwhile (first committer wins); it lets write skew through.
- **SNI** (Server Name Indication) — the server's name, sent by the client at the start of a TLS handshake.
  [server](server.md#tls)
- **socket** — a channel of the kernel between two processes, written and read like a file.
  [server](server.md#what-it-is-and-why)
- **space amplification** — disk space used over the size of the data: the chain alone after a merge (1, as the runs
  are net), and during a full merge a new copy of the base beside the old one (2). [architecture](architecture.md#merges-a-leveled-log-structured-merge-tree)
- **split brain** — two servers taking writes for one database at once, each unaware of the other's; what a promotion
  by hand can and cannot prevent: [server](server.md#promotion-by-hand)
- **SSE4.2**, **x86-64-v2** — SSE4.2 is a set of instructions of x86-64 processors (Intel since Nehalem, 2008; AMD
  since Bulldozer, 2011), among them `crc32`, which computes CRC-32C 8 bytes at a time; a program sees whether the
  processor has it in bit 20 of a register the `cpuid` instruction fills. x86-64-v2 is the level of x86-64 that
  includes it, with CMPXCHG16B, LAHF-SAHF, POPCNT, SSE3, SSSE3 and SSE4.1 (the table "Micro-Architecture Levels" of
  the x86-64 psABI). Cepheus requires SSE4.2 only. [limits](limits.md#files-and-the-platform)
- **stable sort** — a sort that keeps equal keys in the order they came: sorting a large group's facts by value, from
  an order by thing, leaves the facts of one value in thing order, which is the order (property, value, thing) a run
  needs. [architecture](architecture.md#large-groups)
- **standard deviation**, **variance** — how far a group's values spread around their mean: the variance is the mean
  of the squared distances (divided by n - 1 for a sample, by n for a whole population), the standard deviation its
  square root, in the values' unit: `Variance(x)`, `Stddev(x)`. [Cesia](cesia.md#reports-avg-countx-values-quantile-variance-stddev-trunc)
- **strict serializability** — serializable in an order that respects real time. [guarantees](guarantees.md#g4-strict-serializability)
- **strong component** — a largest set of things that all reach one another through a graph's edges; every member
  of one reaches the same things. Found by Tarjan's algorithm (1972). [rules](rules.md#transitive-closures-the-closure-module)
- **structural sharing** — a new version of a persistent structure shares every untouched part with the old one.
- **subjectAltName** — the field of a certificate that lists the names (DNS) and addresses (IP) it is valid for; a
  client checks the host it connected to against it. [server](server.md#tls)
- **syncer** — the thread that writes and forces the frames, beside the writer.
- **system property** — `cepheus/name`, `cepheus/type`, `cepheus/many`, `cepheus/unique` (1 to 4).
- **template** — (1) the questions that differ only by their constants (the unpaid invoices of each client), kept as one
  with the constants as parameters: a fact's change is computed once and its rows routed by the parameters' values.
  (2) A rule with a list pattern `[c, every L, m]`, written once for each member of c's L when it is unfolded (OWL 2
  RL's cls-int1 over an intersection). [rules](rules.md#templates-rules-over-lists)
- **term** (Raft) — the number of an election; it grows at each one, and a term has at most one leader. A server
  forces its term and its vote before it answers. [server](server.md#elections)
- **thing** — the entity of a fact: a number, from 65,536 up. [concepts](concepts.md#facts-the-entityattributevalue-model)
- **threat to validity** — a way the proof or the measure could be wrong, to be named and ruled out.
  [case](case-seats.md#threats-to-validity)
- **TLA+**, **TLC** — a language that describes a system's steps as mathematics (Lamport), and its model checker.
  [testing](testing.md#model-checking)
- **TLS** (Transport Layer Security) — the protocol that encrypts a TCP connection and proves the server's identity by
  its certificate; version 1.3 (RFC 8446) only. [server](server.md#tls)
- **token** — the secret a program shows the server to prove who it is: `cph_` and 43 characters, made by `cepheus
  token add`, shown once. [server](server.md#tokens)
- **torn write** — a write the disk was doing when the power went, of which only part arrived; recovery cuts it.
- **totalOrder** — the order IEEE 754 (2019, section 5.10) gives every float, $-0$ before $+0$ and NaN after
  $+\infty$: the order of `Sort`, of the ranges and of `Less` on floats. [Cesia](cesia.md#sort-limit-and-after-pages)
- **trailer** — the last 16 bytes of a frame, repeating its length and CRCs: a sign that the frame was written whole.
- **transaction** — a unit of work applied entirely or not at all; Cepheus' group.
- **transitive property** — a property that relates a thing to everything it reaches: a part of a part is a part.
  Kept by the closure module. [rules](rules.md#transitive-closures-the-closure-module)
- **Trunc** — the instant a date's unit (its day, week, month, year...) starts in a zone's local time, a key of a
  report's rows: SQL's `date_trunc`. [Cesia](cesia.md#reports-avg-countx-values-quantile-variance-stddev-trunc)
- **TZif** — the binary format of the zone database's compiled files (RFC 8536): a zone's transitions, and after the
  last one its rule as a POSIX TZ string. [Cesia](cesia.md#reports-avg-countx-values-quantile-variance-stddev-trunc)
- **unfolding** (specialisation by small relations, partial evaluation) — a rule rewritten as one rule a fact of a
  small relation of its body, that fact's words in place of its variables: what the engine runs for rules written over
  the ontology. [rules](rules.md#specialisation-by-small-relations)
- **unique** — a property no two things share a value of, checked after each group.
- **Unix-domain socket** — a socket between two processes of one machine, named by a path in the file system
  (`.s.cepheus.7400`); it cannot cross machines. [server](server.md#what-it-is-and-why)
- **value** — the third part of a fact, atomic and typed.
- **value index** — in a run's order by property, a rank table over the values a property takes and the first row
  of each: the rows of "city = Lyon" or "client = #c" in one rank and two offsets, however many rows. Kept for a
  property when it takes at most 2 bytes a row (links, texts, dates, small ints).
  [formats](formats.md#run-dirsnapshotslo-20-digits-hi-20-digitsrun)
- **Values** — the different values of a variable in a group, a list in `Sort`'s order: SQL's `array_agg(DISTINCT x)`;
  joined in Cesia, its `string_agg`. [Cesia](cesia.md#reports-avg-countx-values-quantile-variance-stddev-trunc)
- **variable** — an unknown of a question, numbered from 0.
- **variable property** — a rule pattern whose property is a variable (`prop_var k`), bound by another pattern of the
  body: the W3C's form of OWL 2 RL's rules. [rules](rules.md#a-property-as-a-variable-the-w3cs-form-of-owls-rules)
- **varint** (LEB128), **zigzag** — a whole number in 7-bit pieces, small ones short; zigzag maps signed to unsigned
  (0, -1, 1, -2 → 0, 1, 2, 3). [formats](formats.md#a-group)
- **visibility number**, **visibility page** — the number, in the first 8 bytes of a page of memory
  (`/dev/shm/cepheus-ID.visible`), under which the newest durable state is visible: the server stores it after each
  fsync, before it answers the writers; a local read loads it and serves the state held under it. One store makes a
  group visible to every reader at one instant. [server](server.md#local-reads-g15)
- **window** (of a watch) — the rows a watch with `Sort` and `Limit` holds: `Find`'s first k rows in its order and
  the copies of the k-th, kept by each frame's rows compared with its last row, and refilled by one page `Find` after
  that row when a row leaves it ([Sort and Limit in a watch](cesia.md#sort-and-limit-in-a-watch)).
- **working set** — the reasoner's arrays for one group: the facts it touched, their states, rounds and marks, in
  open-addressing tables with chains by (property, thing) and (property, value), out of the collector's sight.
  [rules](rules.md#large-groups)
- **working view** — the writer's state with every resolved group, durable or not; readers never see it.
- **worst-case optimal join** — a join whose work never exceeds, up to small factors, the largest answer the question
  could have (the AGM bound) (Ngo et al. 2012).
- **write amplification** — how many times a fact is written to the disk by merges for one write by a client: about
  $(T + 1)/2$ a level under leveling, 5.8 for the 10 M load (14.5 with the one level of earlier versions).
  [architecture](architecture.md#merges-a-leveled-log-structured-merge-tree)
- **write skew** — two transactions read the same facts and each writes a different one, together breaking a rule
  (two doctors each go off call); snapshot isolation allows it, `Expect` refuses it.
  [concepts](concepts.md#isolation-exactly-what-a-reader-and-a-writer-see)
- **write-ahead log** (WAL) — a file where every change is made durable before it counts, so that a crash loses
  nothing confirmed. [architecture](architecture.md#the-journal-a-write-ahead-log)
- **writer** — the thread that resolves groups on the working view, the one writer of a database.
- **zigzag** — a coding of signed integers as unsigned ones (0, -1, 1, -2... to 0, 1, 2, 3...), so that small
  negatives stay short as varints. [server](server.md#framing)
