# How Cepheus works

The engine, part by part: what each part is, why it is built this way, and what it costs. The model it serves is in
[concepts](concepts.md); the promises in [guarantees](guarantees.md); the proofs and the mathematics in
[theory](theory.md); the bytes in [formats](formats.md). Numbers come from [benchmarks](benchmarks.md) (one laptop,
Intel i7-4720HQ, a consumer SATA SSD, btrfs; 10 million facts).

```text
client threads              the writer's domain                                  the disk
write db ops ─► queue ─► writer: resolves a batch on the working view
                         (types, new ids, one value, unique, Expect)
                                │ the batch's groups, encoded
                                ▼
                         syncer: one frame, pwrite, fsync ─────────────────► DIR/journal/<n>.seg
                                │
                                ▼
                         publishes the new view (one atomic store), wakes the clients of that frame

readers: view db ─► a view = the base (pages of a snapshot file, through the cache) + the delta (persistent maps)

a merge domain: the base and the delta, merged in order ─► DIR/snapshots/<g>.snap.tmp ─ fsync, rename ─► the new base
```

## The journal: a write-ahead log

A **write-ahead log** (WAL) is a file where every change is written, and made durable, before it counts: after a
crash the database replays it and loses nothing that was confirmed. Cepheus' log is the **journal**: one per
database, in **segment** files of up to 64 MiB (`DIR/journal/<first group>.seg`), only ever appended to. It is a
redo log of resolved changes: each group is written once, already checked and resolved (an `Add` that replaced a
value is written as a retraction and an addition), and nothing is ever undone, so recovery only applies the groups in
order.

**Durable** means on the disk itself, not in the operating system's memory. A `write` system call only copies bytes
into the **page cache** (the kernel's memory copy of files); **fsync** asks the kernel to put a file's bytes on the
disk and returns when they are there. A process crash keeps what the page cache holds; a power loss does not. On the
test machine one fsync takes about 3 ms: about 340 fsync a second.

**Frames.** The journal is a sequence of **frames**. A frame is the unit of one write and one fsync: a 28-byte
header (a magic number, the body's length, its first group, the number of groups, the CRC of the body, the CRC of the
header), the body (the encoded groups), and a 16-byte trailer that repeats the length and both CRCs. A frame holds
whole groups only, so a group is in one frame or in none.

**CRC.** A **cyclic redundancy check** is a short checksum computed from a block of bytes: if any byte of the block
changes, the CRC computed again differs, except with a tiny probability. Cepheus uses CRC-32C (the Castagnoli
polynomial, written in OCaml, about 1.1 GB/s here): it detects every burst of errors of up to 32 bits, every error of
up to 3 bits in frames of realistic size, and lets other random damage through with probability 2⁻³² (Koopman 2002).
The header, the body and every snapshot page carry one.

**Group commit.** An fsync costs the same for one group as for a thousand, so the groups that arrive while one fsync
runs wait together and share the next one: that is **group commit**. The writer works in two stages, in a domain of its
own: a *writer* thread resolves the waiting writes (up to 4,096 at a time) on the **working view**, the state with
every resolved group whether durable or not; a *syncer* thread writes the batch as one frame (`pwrite`), forces it
(`fsync`), then publishes the new view and wakes the clients of that frame only. While the syncer forces a frame, the
writer resolves the next batches and merges them into the frame that waits, until it holds 8 MiB. With N clients
writing one group at a time and an fsync of f, the rate approaches N / (1.5 f) groups a second, up to what the writer
can resolve ([theory](theory.md#2-group-commit)). Measured: 181 groups a second for 1 client, 7,147 for 64, 14,141 to
17,192 for 256 (the disk is the limit; PostgreSQL's inserts are on par).

## Recovery: torn writes and damage

**Recovery** is what an open does after a crash: it rebuilds the state from the newest snapshot and the journal
after it. It reads the frames in order and checks each one's CRCs; everything up to the first frame that does not
check is applied. The question is what that bad frame is:

- a **torn write**: the frame was being written when the power went, and only part of it reached the disk. It was
  never confirmed (a client is answered after the fsync), so recovery cuts it off (truncates the file at its start,
  and forces the cut);
- **damage**: bytes that were once durable changed (a failing disk, a bad copy). Dropping them would lose confirmed
  groups in silence, so recovery refuses to open, with `Damaged` naming the file and the offset.

The two are told apart by two signs that the frame was written whole: a valid frame header after it (a frame is
written only after the previous one was forced, so a later frame proves this one was complete), or a trailer at the
right distance whose CRC matches the body (only the header changed). Either sign means damage; neither means a torn
tail. A torn write can fake a sign only if the disk lost the header's sector alone and kept the rest, which needs a
disk that reorders its sector writes: then the database refuses to open although nothing confirmed was lost (a false
alarm, never a loss). The exhaustive test of every crash state of small journals finds no false alarm in practice.
One case looks like a torn tail and is not: damage in the newest frame, with nothing after it, is cut as torn; a full
read (`Cepheus.verify`) reports it.

**What a killed process left.** A process killed between the `pwrite` of a frame and its fsync leaves the frame in the
page cache: the next process reads it, but a later power loss would take it back. So recovery first forces the newest
segment and the journal's directory, and an open forces the database's directory, before anything rests on what they
hold; except after a **clean close**, which leaves a marker file (`DIR/closed`) once everything is durable, so that
the next open can skip those fsyncs (PostgreSQL keeps the same "shut down" state in `pg_control`).

## Indexes: the base and the delta

A view is two things:

- the **base**: every fact as of the last merge, sorted and stored in columns (one array per field, rather than one
  record per fact). By thing, an offset array `eoff` gives where each thing's rows start: thing e's rows (property,
  value) are `eoff[e]` to `eoff[e+1]`, sorted. Thing numbers are dense, so finding a thing's facts is two array reads,
  not a search (the layout of a compressed sparse row matrix). By property, `poff[p]` to `poff[p+1]` are p's rows
  (value, thing) sorted by value then thing: "the things whose city is Lyon", "the invoices that link to client c"
  (the rows of value c), and ranges of values are binary searches. Texts and floats are numbered by a
  **dictionary** (each distinct text stored once, the rows hold its number); every other value is its own 64-bit word.
  The base is about 25 bytes a fact (245,824,096 bytes at 10 M facts);
- the **delta**: the changes since that merge, in **persistent maps** (balanced trees that are never changed in
  place: a change makes a new version that shares every untouched node with the old one, at a cost of O(log d) for d
  changes). The delta is keyed like the base (by thing, then property and value; by property, then value and thing)
  and keeps exact counts beside each map. It costs about 170 bytes a change.

A read looks in both: a binary search in the base and a search in the delta's map, never a walk of a list. Because
the delta is persistent and the base never changes, a view is a value: keeping one costs nothing, and a fork is a
view with its own delta. Reading the facts of an invoice by its number takes 0.39 µs at 10 M facts.

## Snapshots

A **snapshot** is a file that holds a base: `DIR/snapshots/<group>.snap`, a 4 KiB header (with the group it holds and
the journal position where replay must resume), the base's sections in 16 KiB pages, and a table of one CRC-32C per
page. It is a cache of the journal: it spares a restart the replay of everything before it, and it can always be
rebuilt from the journal. A snapshot is the in-memory format of the base, so it is read with no decoding (it is only
for 64-bit little-endian machines; the journal is the portable format). At open, the header, the CRC table and the
order and bounds of every offset table are checked; a snapshot that fits in the cache is read and checked whole before
the first question, a larger one page by page. A snapshot that does not check is set aside (noted, skipped) and the
older one, or the journal, is used. The newest two are kept.

## The merge: a log-structured merge-tree of two components

A **log-structured merge-tree** (LSM-tree, O'Neil et al. 1996) keeps recent writes in a small structure in memory and
moves them in bulk into large sorted structures on disk, by merging sorted runs instead of updating pages in place.
Its **components** (also called levels) are the memory part and the parts on disk; moving data from one to the next
is a **merge**, also called **compaction**. Cepheus is a two-component LSM-tree: the delta in memory (C0) and the base
in its snapshot file (C1). It has one level on disk.

**When.** A merge starts when the delta holds more than max(200,000, n/16) changes, n being the facts of the base
(`Engine.compact_min` and the ratio 16). It runs in a domain of its own, beside the writes: it reads the old base
through the cache and the delta, both already sorted in the order of every section, so each section of the new base
is one pass with one cursor in each (O(n + d) comparisons, no sort), and it streams the result into
`<group>.snap.tmp`, page by page: a 16 KiB page goes out (its CRC, a `pwrite` at its place, the cache) as soon as its
bytes are written. Then the CRC table, the header, an fsync. Meanwhile the writer logs the groups it resolves; the
merge replays them onto the new base until it is fewer than 256 groups behind; then the writer waits for the syncer
to be idle (at most one fsync), replays the rest, renames the file to its name, forces the directory, removes the
snapshots beyond the newest two, and switches both views to the new base in one atomic store. A crash at any point
leaves the old base or the new one, whole (G12).

**Memory.** A merge needs the cache, a few page buffers (at most 8, 5 measured) and 21 bytes a page of the new base
(0.13 % of it): with a 32 MB cache, a merge of the 245 MB base ran in a process capped at 128 MB (peak 99 MB). The
merge it replaced, built in memory, was killed by that cap.

**Write amplification** is the number of bytes a database writes to the disk for each byte of data it is asked to
write. A merge rewrites the whole base: n + d facts for d changes, so each change costs up to n/d + 1 = 17 facts of
merge writes once n/16 passes 200,000 (the size ratio 16 of a two-component tree, whose amortized merge cost is the
ratio plus one). At 10 M facts a merge rewrites 245 MB every 625,000 changes: about 400 bytes a change, beside about
10 bytes a fact in the journal. **Space amplification** (disk space over data size): during a merge the directory holds
three bases (the current one, the one kept before it, the new one), so budget about four times the base for
`snapshots/`.

**What it costs the writes.** A merge's writes compete with the journal's fsyncs, which every client waits for. While
clients write, a merge forces its file every 8 MiB (as RocksDB's `bytes_per_sync` does), so that no journal fsync
queues behind hundreds of megabytes of a merge's dirty pages; a merge nobody waits beside (`snapshot`, recovery)
forces once. Writes at 256 clients do not see the merges (19,388 groups a second against 19,126 with merges in memory);
a bulk load does: 10 M facts load in 135 to 153 s, against 63 to 79 s when merges were built in memory, because each
merge rewrites the whole base (about 3.3 GB over the load). Several levels on disk, each merged at its own pace, would
lower the bytes a change; they are not built at this version.

## Pages and the cache

The base is read in **pages** of 16 KiB through one cache for the process, Cepheus' own (a **buffer pool**: the
database, not the kernel, decides which pages stay in memory). Its size is `set_cache` (1 GiB by default). Why not let
the kernel do it with `mmap`: a mapped file turns a disk error into a signal that kills the process, gives the
database no say in what is evicted, and stalls unpredictably beyond memory (Crotty, Leis, Pavlo, CIDR 2022). With its
own cache Cepheus checks every page against its CRC when it arrives from the disk (a damaged page is never served, even
one damaged after the open), returns a disk error as an error, and works on data larger than memory.

**A read** of a page in memory is one array read and one comparison, with no lock, from any domain: each base has a
table of its pages that are "hot". A page not hot goes the slow way: if it is in memory, one read is counted for the
eviction policy and the page is hot again; if not, the cache's lock is taken, room is made, the page is read from its
file, checked, and published.

**Eviction policy: S3-FIFO** (Yang et al., SOSP 2023). When the cache is full, a page must leave; the policy decides
which. S3-FIFO uses three first-in-first-out queues: a new page enters a *small* queue (a tenth of the room); when it
reaches the end, it goes to the *main* queue if it was read again meanwhile, and out otherwise (its key then goes to a
*ghost* queue, so that a page asked again soon goes straight to the main queue); at the end of the main queue a page
read since the policy last looked at it is kept (its 2-bit counter lowered), else out. A scan's pages therefore leave
from the small queue without pushing out the pages read again and again. Unlike LRU, 2Q or ARC, it moves nothing on a
hit, so the hits of several domains need no lock. On recorded traces of this database, every online policy tried
(LRU, CLOCK, 2Q, ARC, SIEVE, S3-FIFO, W-TinyLFU) is within one point of hit ratio of the others, and Belady's optimum
(evict the page needed the farthest in the future, which no real policy can know) misses about half as much
([theory](theory.md#7-pages-and-the-cache)).

**Cost and bound.** When everything is in memory, the page table costs 3 to 13 % on joins against the mapped base of
an earlier version (one more dependent load per read). Pages in memory stay under 1.25 times the cache: evicted pages
are freed by the garbage collector, and a full collection runs after each quarter of the cache evicted. With a 32 MB
cache and the 245 MB base, an open takes 67 ms and 64 MB, an invoice by number 41 µs (PostgreSQL 176 µs with 32 MB of
buffers).

## One writer, threads and domains

Each database has exactly one writer (G9: a lock file, `DIR/lock`, held by one process). One writer means no locks
between writers, no deadlock, and a total order of the groups with no gap, which is what makes the journal a history
that can be replayed and, later, replicated. Its cost: a database cannot resolve groups faster than one core (the
writer resolves a 5-fact group in about 7 µs, so the disk's fsync is the limit long before), and a slow group delays
the next ones. Separate databases write in parallel.

OCaml 5 runs code in parallel through **domains**: each domain is a thread of execution with its own core, heap for
young values and runtime lock; the **threads** (systhreads) of one domain share that lock and take turns. Cepheus puts
the writer and the syncer in a domain of their own, so that they never wait for the runtime lock of the client
threads; each merge runs in its own domain; and a large question (20,000 candidates or more for its first variable)
splits them into slices that up to `Query.domains` domains take in turn (the machine's recommended count, at most 8),
each with its own accumulator, merged in slice order so that the answer does not depend on the number of domains. A
view needs no lock to be read, which is what makes this split free. The unpaid sum per city over 453,866 invoices takes
231 ms on one domain and 107 ms on three (PostgreSQL 236 ms on one process, 109 ms on three).

## Questions

A question is a conjunctive query: patterns joined on their variables ([concepts](concepts.md#questions)). The usual
way to answer one is a plan of **binary joins** (two inputs at a time, the result joined with the next input). On a
cyclic question such as the triangles of a graph (a follows b, b follows c, c follows a), any such plan can build far
more intermediate rows than the answer: for N links, Θ(N²) pairs a → b → c before checking c → a, while at most N^1.5
triangles exist. That N^1.5 is the **AGM bound** (Atserias, Grohe, Marx 2008): the largest answer a question can have,
computed from the sizes of its inputs. A **worst-case optimal join** never does more work than that bound, up to
small factors (Ngo, Porat, Ré, Rudra 2012).

Cepheus answers with **Generic Join** (Ngo, Ré, Rudra 2013), the simplest worst-case optimal join: fix an order of the
variables; to bind the next variable, take the pattern that offers the fewest candidates for it given the variables
bound so far (exact counts, read from the indexes), enumerate those, and keep each candidate only if every other
pattern on the variable accepts it (one index lookup each, O(log n)). On a chain of patterns it does what nested index
lookups would; on a cycle it stays within the bound. The order of the variables is chosen from the counts: every order
for up to 7 variables (with pruning), greedily beyond. Each answer comes out once (G11). On the follow graph (568,163
links), the triangles take 1.03 s on one domain and 371 ms on three (PostgreSQL 1.03 s and 603 ms).

## How it is tested

- **Deterministic simulation testing**: the engine never touches the disk directly; it goes through an interface
  (`Disk.t`) with two implementations, the real file system and a simulated disk that loses what was not forced,
  tears sectors, reorders them, flips bits and fails fsyncs on demand. One seed decides everything (writes, the order
  of the writer's steps, crashes, damage), so a failure replays exactly from its seed. FoundationDB is tested this way.
- **Exhaustive enumeration**: for small journals and inside merges, every state a crash can leave on the disk, each
  recovered and checked (the method of the ALICE study, pushed to every case).
- **Real crashes** (`kill -9` at random moments) and the **bank test** (transfers guarded by `Expect`, readers on other
  cores checking that the total never changes).
- **TLA+ and TLC**: TLA+ is a language for describing a system's steps as mathematics (Lamport); TLC is its model
  checker, which visits every reachable state of a bounded model and checks invariants in each. The journal protocol
  and the merge's install are modelled (`spec/`): 1,084,801 and 3,808,506 states, no violation, and each safety rule of
  the merge, removed alone, gives a counterexample.

Details: [testing](testing.md).

## Further reading

- Write-ahead logging and group commit: Mohan et al., ARIES (TODS 1992); DeWitt et al. (SIGMOD 1984); Helland et al.
  (HPTS 1987).
- Crash consistency: Pillai et al., ALICE (OSDI 2014); Rebello et al., fsync failures (USENIX ATC 2020); Koopman,
  CRC-32 (DSN 2002).
- LSM-trees: O'Neil et al. (Acta Informatica 1996); Luo and Carey, survey (VLDB Journal 2020); Dong et al., RocksDB
  (CIDR 2017); Balmau et al., SILK (USENIX ATC 2019).
- Buffer management: Crotty, Leis, Pavlo, mmap (CIDR 2022); Leis et al., LeanStore (ICDE 2018); Yang et al., S3-FIFO
  (SOSP 2023); Belady (IBM Systems Journal 1966).
- Joins: Atserias, Grohe, Marx (FOCS 2008); Ngo, Porat, Ré, Rudra (PODS 2012); Veldhuizen, Leapfrog Triejoin (ICDT
  2014); Ngo, Ré, Rudra (SIGMOD Record 2013).
- Testing: Zhou et al., FoundationDB (SIGMOD 2021); Lamport, Specifying Systems (2002); Newcombe et al., AWS (CACM 2015).

Full entries, with links: [references](references.md).
