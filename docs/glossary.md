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
- **asserted fact** — a fact a program wrote (`Add`), as opposed to one a rule derived; the extensional database (EDB)
  of Datalog. A fact can be both asserted and derived. [rules](rules.md#what-the-database-holds-the-least-model)
- **atomic register**, **regular register**, **new-old inversion** — Lamport's classes of shared registers (On
  Interprocess Communication, 1986): a read of a *regular* register returns the last value written before it or one
  being written meanwhile, so two reads one after the other may see a new value and then the old one (a **new-old
  inversion**); an *atomic* register forbids it, every read and write appearing at one instant. Linearizable reads
  are atomic: G15 forbids the inversion; the lease the design first proposed allowed it. [server](server.md#local-reads-g15)
- **atomic** (all or nothing) — applied entirely or not at all: a group (G2); a rename; the switch to a new view (one
  atomic store). [guarantees](guarantees.md#g2-all-or-nothing)
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
- **BLAKE2b** — a cryptographic hash function (RFC 7693): from any bytes, 32 bytes (BLAKE2b-256) from which the input
  cannot be found again. The server keeps tokens only as their BLAKE2b-256 hash. [server](server.md#tokens)
- **body** (of a rule) — its patterns and ranges: the question whose answers give the head. [rules](rules.md#a-rule-is-a-question-with-a-conclusion)
- **bottom run** — a run that rests on nothing (its name starts with 20 zeros): it holds the whole state at its last
  group and no retraction.
  [architecture](architecture.md#runs-on-disk)
- **buffer pool** (the cache) — memory where a database keeps pages of its files, deciding itself what stays; Cepheus'
  holds the runs' 16 KiB pages, 1 GiB by default. [architecture](architecture.md#pages-and-the-cache)
- **cardinality** — how many values a thing may have for a property: one (the default) or many (`~many:true`).
  [concepts](concepts.md#properties-and-the-schema)
- **Cesia client** — the package `cesia/cepheus` of this repository: the Cesia functions `Connect`, `Kind`, `Insert`,
  `Get`, `Update`, `Write`, `Find`, `Fork`, `Close`, over an engine in OCaml (`cesia/native/`) that speaks the
  protocol and reads locally on the server's machine. [Cesia](cesia.md)
- **certificate** — a public key and a name, signed by a certificate authority: what a server shows in a TLS handshake
  to prove it is the one the client meant. [server](server.md#tls)
- **certificate authority** (CA) — the key whose signatures a client trusts; each cluster has its own, made by
  `cepheus cluster init` (ECDSA, P-256), whose private key belongs offline. [server](server.md#tls)
- **chain** (of runs) — runs that rest on one another from 0: each holds the groups after the last group of the one
  below it. An open takes the chain that reaches the newest group with the fewest runs. [architecture](architecture.md#runs-on-disk)
- **checksum**, **CRC**, **CRC-32C** — a short number computed from bytes, which changes if they change; CRC-32C (the
  Castagnoli polynomial, the checksum of iSCSI, RFC 3720) detects every burst of up to 32 bits and lets random damage
  through with probability 2⁻³². Cepheus computes it by the processor's own instruction (SSE4.2 on x86-64, CRC32 on
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
- **cluster** — the servers that hold the same databases; one machine is a cluster of one peer. Its id (`cph-c-` and
  16 hex digits) is in `cluster.toml` and in every Welcome. [server](server.md#clustertoml)
- **compaction** — another name for a merge in an LSM-tree. [architecture](architecture.md#merges-a-leveled-log-structured-merge-tree)
- **component** — one of the structures of an LSM-tree: the delta in memory (C0), the runs on disk.
- **confirmed** — a group whose `write` returned `Ok`: it is durable. [guarantees](guarantees.md#the-faults)
- **conjunctive query** — a question made of patterns that must all hold at once (an AND of facts), over shared
  variables. [concepts](concepts.md#questions)
- **connection limit** — the most connections the server keeps open at once (`max_connections`, 512 by default); a
  new one over it is closed at its accept. [server](server.md#clustertoml)
- **constant-time comparison** — comparing two secrets byte by byte to the end, whatever the first difference, so that
  the time taken tells an attacker nothing about how much of a guess was right. [server](server.md#tokens)
- **constraint** — a rule whose head is `Never`: an answer of its body refuses the group (G18).
  [rules](rules.md#constraints-never)
- **coordinated omission** — the error of a closed-loop measure: a client stalled by a slow write sends nothing
  meanwhile, so the writes that would have waited are never counted (Tene 2015). [benchmarks](benchmarks.md#method)
- **counterexample** — a sequence of steps that leads from an initial state to one where an invariant is false; what
  a model checker prints. [case](case-seats.md#a-formal-model-checked-by-a-machine)
- **counting** (view maintenance) — keeping for each derived fact the number of its derivations, deleting it at zero
  (Gupta et al. 1993); exact for nonrecursive rules only: two facts that derive each other keep each other's count
  above zero. [rules](rules.md#retraction-backwardforward)
- **counting sort** — a sort that counts how many items fall on each key, then places each item at its key's place
  in one pass: O(n + keys), no comparison. A large group's facts are sorted by property this way, in chunks counted
  and spread at once by several domains.
  [theory](theory.md#9-levels-on-disk-and-large-groups)
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
- **delta** — the changes since the last merge, in persistent maps; level 0 of the LSM-tree (C0), about 170 bytes a
  change. [architecture](architecture.md#indexes-the-runs-and-the-delta) In the reasoner, Δ is another thing: the
  facts a group changes, from which semi-naive evaluation derives (round 0 is the group's asserted additions).
  [rules](rules.md#how-the-writer-keeps-it-semi-naive-evaluation)
- **delta debugging** — shrinking a failing case by removing parts while it still fails, until every part left is
  needed (Zeller and Hildebrandt 2002). [case](case-seats.md#3-a-hypothesis-one-can-prove-wrong-and-its-cause)
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
- **dictionary** — the table that numbers each distinct text (and float) once; the rows hold the number.
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
- **fork** — a temporary database started from a view: the same writes and checks, nothing on disk, free to make.
  [concepts](concepts.md#forks)
- **frame** — the unit of one write and one fsync in the journal: a header, the groups, a trailer.
  [formats](formats.md#journal-segment-dirjournalfirst-group-20-digitsseg)
- **fsync** — the system call that returns once a file's bytes are on the disk.
- **fuzzing**, **libFuzzer**, **sanitizer** — fuzzing runs a function on millions of inputs that a program mutates
  to reach new paths in the code, and stops at the first that fails; libFuzzer is LLVM's fuzzer. A sanitizer is a
  check the compiler adds to every memory access (AddressSanitizer: a read or write outside its block) or to every
  operation C leaves undefined (UndefinedBehaviorSanitizer). The C files of the CRC and of TLS are fuzzed with both.
  [testing](testing.md#the-c-file-fuzzed)
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
- **handshake** — the first round trips of a TLS connection, where the two sides agree on keys and the server shows
  its certificate: about 4.8 ms of computation here, which is why connections live long. [server](server.md#tls)
- **head** (of a rule) — the pattern it gives for each answer of its body, or `Never`.
  [rules](rules.md#a-rule-is-a-question-with-a-conclusion)
- **history** — the sequence of every transaction a database applied, with what each read and wrote; Cepheus'
  journal is one, in group order.
- **idle timeout** — the time a connection may go without a whole request before the server closes it
  (`idle_timeout`, 600 s by default), its TLS handshake included. [server](server.md#clustertoml)
- **index word** — the 64-bit form of a value in the indexes: the value itself, or a dictionary number for texts and
  floats; what `fold` gives, and `decode` turns back into the value. [api](api.md#questions)
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
- **large group** — a group of 20,000 operations or more, all additions: it takes a faster path to the same result
  (its facts in Bigarrays, mapped and sorted by several domains, merged at once into a run while its frame is written
  beside, by pieces). [architecture](architecture.md#large-groups)
- **lazy leveling** — tiering at every level but the last, which is leveled (Dayan and Idreos 2018).
  [theory](theory.md#9-levels-on-disk-and-large-groups)
- **lease** — a permission that ends by itself after a time, unless renewed (Gray and Cheriton 1989). The design
  proposed one for local reads; it was left for the visibility number, which needs no clock (leases come back between
  machines). [server](server.md#the-rules-the-design-first-had-and-why-they-were-left)
- **least model** — the smallest set of facts containing the asserted ones and closed under the rules: what a
  database with rules holds (G17). [rules](rules.md#what-the-database-holds-the-least-model)
- **level**, **size ratio** — a place for runs with a capacity in an LSM-tree; each level is T times larger than the
  one above (T, the size ratio, is 4 here): level l holds at most 200,000 × 4^l rows. [architecture](architecture.md#merges-a-leveled-log-structured-merge-tree)
- **leveling**, **tiering** — the two ways an LSM-tree of several levels merges: under leveling each level holds one
  run, and a run coming down is merged with it (Cepheus); under tiering a level holds up to T runs, merged together
  into the next level when full. Leveling writes more and reads fewer runs. [theory](theory.md#9-levels-on-disk-and-large-groups)
- **linearizability** — each operation appears to take effect at one instant between its call and its return
  (Herlihy and Wing 1990); a group, as a write to one object, is linearizable.
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
- **memory BIO** — an OpenSSL buffer in memory standing for the network: OpenSSL reads the bytes it is given and
  writes the bytes to send there, never touching the socket, so it never waits. [server](server.md#tls)
- **merge** — the folding of the delta and the newest runs into one new run file; it runs in the background and is
  atomic (G12); `snapshot` is the full merge, of every run. [architecture](architecture.md#merges-a-leveled-log-structured-merge-tree)
- **model checking** — visiting every reachable state of a bounded model and checking invariants in each; TLC does it
  for TLA+. [testing](testing.md#model-checking)
- **monotonic writes** — a session guarantee (Terry et al. 1994): a program's writes are applied in the order it sent
  them. [server](server.md#order-pipelining-and-back-pressure)
- **mutual TLS** — TLS where both sides show a certificate of the same CA; between Cepheus servers (with replication),
  not for programs, which show a token. [server](server.md#tls)
- **native package** — a Cesia package whose functions are, under their Cesia code, an engine in OCaml compiled once:
  the way Cesia runs OCaml that comes from another project; running one needs the permission `native=LABEL`, total
  trust, as `ffi=` for C. [Cesia](cesia.md#the-package)
- **net** (run) — a run adds only facts absent below it and retracts only facts present below it, so every count of a
  view is a sum of exact counts. [architecture](architecture.md#indexes-the-runs-and-the-delta)
- **optimistic concurrency control** — read without locks, and check at the end that what was read still holds
  (Kung and Robinson 1981): `Expect`.
- **origin** — the token's name, session, serial and floor that a group written through the server carries in its
  `why`: which program wrote it, and how a resent write is recognized.
  [server](server.md#writes-applied-once-sessions-g14)
- **page** — 16 KiB of a run file, the unit of the cache, checked by its CRC each time it is read from the disk.
- **page cache** (the kernel's) — the operating system's memory copy of files; what a process crash keeps and a power
  loss loses.
- **part** (of a run) — a run has two: the facts it adds (part a) and the facts of the runs below it that it retracts
  (part t). [architecture](architecture.md#indexes-the-runs-and-the-delta)
- **persistent data structure** — one that is never changed in place: a change makes a new version and the old one
  stays valid. [architecture](architecture.md#indexes-the-runs-and-the-delta)
- **phantom** — a new member of a set read earlier (the facts that match a pattern), unseen by a check of single facts.
- **pipelining** — sending requests without waiting for the replies of the earlier ones: the round trips overlap, and
  many replies come back in one system call. [server](server.md#order-pipelining-and-back-pressure)
- **plan** (of a rule) — the rule compiled to closures with one atom matched to a given fact, the others joined in an
  order chosen from the store's counts. [rules](rules.md#how-the-writer-keeps-it-semi-naive-evaluation)
- **population count** (popcount) — the number of bits set in a word; a rank table's lookup is one.
- **proof** — a tree whose leaves are asserted facts and whose nodes are rule instances, each node's children the
  facts of its body; *well-founded*: every child proved before its parent. `why` returns one (G20).
  [rules](rules.md#why)
- **property** — the attribute of a fact; itself a thing (16 to 65,535) with a name, a type and two flags.
- **provenance** — where a fact comes from: here, a proof of it. [rules](rules.md#why)
- **question** — Cepheus' query: patterns over variables. [concepts](concepts.md#questions)
- **radix sort** (least significant digit first) — a sort that sorts by the lowest digit, then the next, each pass a
  stable counting sort, so that the order of the lower digits is kept: O(n × digits). A large group's values inside a
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
- **retry** — running a transaction again after the database refused it (a `Conflict` in Cepheus, a serialization
  failure in PostgreSQL), from a new read.
- **rewrite of the newest frame** — at a recovery after anything but a clean close, the journal's newest frame is
  written again before it is forced, so that pages a failed fsync marked clean are dirty again and really written
  (G13). [guarantees](guarantees.md#g13-a-failed-fsync-is-never-trusted)
- **right** — what a token may do on a database: `read` (Open, Get, Find) or `write` (and Write); `admin`: the
  server's operations. [server](server.md#rights-g16)
- **round trip** — a request and its reply: the time between sending one and receiving the other, most of it the
  kernel's work (system calls, waking the other process). [server](server.md#speed-beside-postgresql)
- **rule** — a question's patterns and a head: whenever the patterns are facts for some values, the head is a fact for
  the same values. A schema thing (`cepheus/name`, `cepheus/rule`). [rules](rules.md)
- **run**, **run file** — one sorted structure of the LSM-tree on disk: the changes of a range of groups on top of the
  runs below it, in a file `DIR/snapshots/<lo>-<hi>.run`. [architecture](architecture.md#runs-on-disk)
- **S3-FIFO** — the eviction policy of the cache: three FIFO queues (small, main, ghost), nothing moved on a hit (Yang
  et al. 2023). [architecture](architecture.md#pages-and-the-cache)
- **schedule** — one order in which the steps of concurrent transactions interleave.
  [case](case-seats.md#correctness-on-generated-inputs)
- **schema** — the properties and their types; in Cepheus, facts like the rest. [concepts](concepts.md#properties-and-the-schema)
- **segment** — one file of the journal, up to 64 MiB, named by its first group.
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
- **SSE4.2**, **x86-64-v2** — SSE4.2 is a set of instructions of x86-64 processors (Intel since Nehalem, 2008; AMD
  since Bulldozer, 2011), among them `crc32`, which computes CRC-32C 8 bytes at a time; a program sees whether the
  processor has it in bit 20 of a register the `cpuid` instruction fills. x86-64-v2 is the level of x86-64 that
  includes it, with CMPXCHG16B, LAHF-SAHF, POPCNT, SSE3, SSSE3 and SSE4.1 (the table "Micro-Architecture Levels" of
  the x86-64 psABI). Cepheus requires SSE4.2 only. [limits](limits.md#files-and-the-platform)
- **stable sort** — a sort that keeps equal keys in the order they came: sorting a large group's facts by value, from
  an order by thing, leaves the facts of one value in thing order, which is the order (property, value, thing) a run
  needs. [architecture](architecture.md#large-groups)
- **strict serializability** — serializable in an order that respects real time. [guarantees](guarantees.md#g4-strict-serializability)
- **structural sharing** — a new version of a persistent structure shares every untouched part with the old one.
- **subjectAltName** — the field of a certificate that lists the names (DNS) and addresses (IP) it is valid for; a
  client checks the host it connected to against it. [server](server.md#tls)
- **syncer** — the thread that writes and forces the frames, beside the writer.
- **system property** — `cepheus/name`, `cepheus/type`, `cepheus/many`, `cepheus/unique` (1 to 4).
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
- **trailer** — the last 16 bytes of a frame, repeating its length and CRCs: a sign that the frame was written whole.
- **transaction** — a unit of work applied entirely or not at all; Cepheus' group.
- **unique** — a property no two things share a value of, checked after each group.
- **Unix-domain socket** — a socket between two processes of one machine, named by a path in the file system
  (`.s.cepheus.7400`); it cannot cross machines. [server](server.md#what-it-is-and-why)
- **value** — the third part of a fact, atomic and typed.
- **variable** — an unknown of a question, numbered from 0.
- **varint** (LEB128), **zigzag** — a whole number in 7-bit pieces, small ones short; zigzag maps signed to unsigned
  (0, -1, 1, -2 → 0, 1, 2, 3). [formats](formats.md#a-group)
- **visibility number**, **visibility page** — the number, in the first 8 bytes of a page of memory
  (`/dev/shm/cepheus-ID.visible`), under which the newest durable state is visible: the server stores it after each
  fsync, before it answers the writers; a local read loads it and serves the state held under it. One store makes a
  group visible to every reader at one instant. [server](server.md#local-reads-g15)
- **working set** — the reasoner's arrays for one group: the facts it touched, their states, rounds and marks, in
  open-addressing tables with chains by (property, thing) and (property, value), out of the collector's sight.
  [rules](rules.md#large-groups)
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
- **zigzag** — a coding of signed integers as unsigned ones (0, -1, 1, -2... to 0, 1, 2, 3...), so that small
  negatives stay short as varints. [server](server.md#framing)
