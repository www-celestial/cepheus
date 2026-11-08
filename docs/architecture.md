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

readers: view db ─► a view = the runs (pages of run files, through the cache), newest first + the delta (persistent maps)

a merge domain: the delta and the newest runs, merged in order ─► DIR/snapshots/<lo>-<hi>.run.tmp ─ fsync, rename ─►
                one run, at the first level that holds them all; the runs it replaced are removed
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
The header, the body and every page of a run file carry one.

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

**Recovery** is what an open does after a crash: it rebuilds the state from the runs on disk and the journal after
the newest of them. It reads the frames in order and checks each one's CRCs; everything up to the first frame that does not
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
page cache: the next process reads it, but a later power loss would take it back. So recovery first writes the newest
frame of the journal again and forces the newest segment and the journal's directory, and an open forces the
database's directory, before anything rests on what they hold; except after a **clean close**, which leaves a marker
file (`DIR/closed`) once everything is durable, so that the next open can skip those fsyncs (PostgreSQL keeps the same
"shut down" state in `pg_control`).

**A failed fsync.** When an fsync fails, Linux marks the pages it could not write as clean although they never reached
the disk: ext4 and XFS keep their new bytes in memory, so a later fsync succeeds without writing them and every read
until a reboot sees a frame the disk does not hold (Rebello et al., USENIX ATC 2020). Two rules keep the disk the
truth (G13). The writer stops at the first failure and cuts the journal back to the end of its last durable frame (it
truncates the file there and forces it), so the failed write is gone from memory and disk alike. And the rewrite
above: the newest frame is written again at every recovery after anything but a clean close, which makes its pages
dirty again, so that the fsync that follows really writes them; it is the only frame that can be off the disk, since
the writer forces each frame before the next and stops at the first failure. The rewrite costs one `pwrite` of the
newest frame (at most 8 MiB) at an open after a crash, nothing on the write path.

**Reading through a window.** Recovery reads each segment through a window of 4 MiB: a frame that fits is checked and
decoded where it lies; a longer one (a large group's frame passes 100 MB) is checked by its CRC piece by piece, and read
whole only when its groups must be replayed. A frame whose groups the runs already hold is checked and not decoded. So
an open holds the window and the largest frame it must replay, whatever the size of the segment: the database a 10 M
load leaves (its newest segment 94 MB) opens in 165 to 207 ms with 54 to 56 MB resident, under a 128 MB cap.

## Indexes: the runs and the delta

A view is two things:

- the **runs**: the facts as of the last merges, sorted and stored in columns (one array per field, rather than one
  record per fact), in files on disk read through the cache, newest first. A run holds the changes of a range of
  groups on top of the runs below it, in two **parts**: the facts it adds (part a), and the facts of the runs below it
  that it retracts (part t, empty in the bottom run). In each part, by thing, a **rank table** says which things the
  part holds: one 64-bit word for 32 thing numbers, with a presence bit for each and the count of things held before
  them, so thing e's slot is that count plus the bits set below e's (one word read and one population count); the
  slot's two offsets give where its rows (property, value) are, sorted. A part that holds every thing from some number
  to its end (a load, a full merge) reads no rank there. By property, `poff[p]` to `poff[p+1]` are p's rows (value,
  thing) sorted by value then thing: "the things whose city is Lyon", "the invoices that link to client c" (the rows of
  value c), and ranges of values are binary searches. Texts and floats are numbered by a **dictionary** (each distinct
  text stored once, the rows hold its number); every other value is its own 64-bit word. A run is about 25 bytes a
  fact;
- the **delta**: the changes since the last merge, in **persistent maps** (balanced trees that are never changed in
  place: a change makes a new version that shares every untouched node with the old one, at a cost of O(log d) for d
  changes). The delta is keyed like a run (by thing, then property and value; by property, then value and thing) and
  keeps exact counts beside each map. It costs about 170 bytes a change.

A fact is in a view when its newest entry (the delta's, or the newest run's that has one) adds it. Each run is
**net**: it adds only facts absent below it and retracts only facts present below it, so a count is a sum of exact
counts (each run's additions minus its retractions, plus the delta's). A read looks in the delta and in each run that
may hold the key, by binary search, never by a walk of a list; a row of an older run is shown only if no newer run has
an entry for the same fact, which the rank tables answer with a few bit tests unless a newer run holds the same thing.
Because the delta is persistent and runs never change, a view is a value: keeping one costs nothing, and a fork is a
view with its own delta. Reading the facts of an invoice by its number takes 0.38 µs at 10 M facts on one run; on the
two runs a load leaves, the joins that read both cost 40 % more (Q3, Q4), and `snapshot` makes one run again.

## Runs on disk

A **run file** holds one run: `DIR/snapshots/<lo>-<hi>.run` (20 digits each) holds the changes of groups lo+1 to hi
on top of the state at lo; a run with lo = 0 is a **bottom run**, the whole state at hi. A file is a 4 KiB header
(the groups, the level, the journal position where replay must resume), the two parts' sections in 16 KiB pages, and
a table of one CRC-32C per page. The runs of a database form a **chain** from 0: each rests on the group the one below
it ends at. Runs are caches of the journal: they spare a restart the replay of everything before them, and they can
always be rebuilt from the journal. A run is the in-memory format, read with no decoding (it is only for 64-bit
little-endian machines; the journal is the portable format). At open, Cepheus takes the chain of named runs from 0
that reaches the newest group with the fewest runs, and checks each run: the header, the CRC table, the rank tables,
the order and bounds of every offset table; a run that fits in the cache is read and checked whole before the first
question, a larger one page by page. A run that does not check is set aside (noted, skipped) and the chain is chosen
again without it, down to the journal alone. Besides the chain, the newest bottom run outside it is kept as a
fallback. The snapshot of earlier versions (format 4, `<group>.snap`, the whole base in one file) is set aside at the
first open and the journal replayed once ([formats](formats.md)).

## Merges: a leveled log-structured merge-tree

A **log-structured merge-tree** (LSM-tree, O'Neil et al. 1996) keeps recent writes in a small structure in memory and
moves them in bulk into large sorted structures on disk, by merging sorted runs instead of updating pages in place.
Its **components** are the memory part and the runs on disk; moving data from one to the next is a **merge**, also
called **compaction**. A **level** is a place in the tree with a capacity; the **size ratio** T is how many times larger
each level is than the one above. Cepheus' delta is level 0; its runs are at levels 1, 2, 3, ...; level l holds at most
200,000 × 4^l rows (800,000, 3.2 M, 12.8 M, ...).

**Leveling.** Under **leveling**, each level holds one run; under **tiering**, up to T runs, merged together when the
level is full. Leveling writes more (a fact is merged again each time the level above spills into its level) and reads
less (one run per level); tiering the opposite (Luo and Carey, VLDB Journal 2020; Dayan and Idreos, Dostoevsky, SIGMOD
2018). Cepheus' reads are short ranges (the facts of a thing, the things of a value) and exact counts, which visit every
run that may hold the key, so the number of runs weighs as much as the writes: leveling, with T = 4
([theory](theory.md#9-levels-on-disk-and-large-groups)).

**When.** A merge starts when the delta holds more than 200,000 changes (`Engine.compact_min`). It takes the delta and
the newest runs, down to the first level that can hold them all, and writes one run there (`Engine.plan`). It runs in
a domain of its own, beside the writes: its inputs are already sorted in the order of every section, so each section of
the new run is one pass with one cursor in each (O(n + d) steps, no sort), and it streams the result into
`<lo>-<hi>.run.tmp`, page by page: a 16 KiB page goes out (its CRC, a `pwrite` at its place, the cache) as soon as its
bytes are written. Then the CRC table, the header, an fsync. Meanwhile the writer logs the groups it resolves; the
merge replays them onto the new runs until it is fewer than 256 groups behind; then the writer waits for the syncer to
be idle (at most one fsync), replays the rest, renames the file to its name, forces the directory, removes the runs it
replaced, and switches both views to the new runs in one atomic store. A crash at any point leaves the runs before it
or the runs after it, whole (G12). `snapshot` is the one full merge: the delta and every run into one run.

**Memory.** A merge needs the cache, a few page buffers (at most 2 for each of the 8 streams of a pass, 7 measured)
and 21 bytes a page of the new run (0.13 % of it): with a 32 MB cache, a merge of the whole 245 MB base ran in a
process capped at 128 MB (peak 99 MB).

**Write amplification** is the number of times a fact is written to the disk for each time a client writes it. Under
leveling with ratio T, a fact is written about (T + 1)/2 = 2.5 times per level it enters (it enters a level at one of
the T merges that fill it, and is written again at each later one), and the levels a merge skips cost no extra write:
for the 10 M load of the benchmarks, 5.8 writes a fact, against 14.5 with the one level of earlier versions (whose
merges rewrote the whole base each time: up to 17 facts a change). **Read amplification** is the number of runs a read
visits: at most 3 at 10 M facts (2.1 on average over that load). **Space amplification** (disk space over data size):
the chain, the fallback bottom run, and during a full merge a new copy of the base: budget about three times the base
for `snapshots/`.

**What it costs the writes.** A merge's writes compete with the journal's fsyncs, which every client waits for. While
clients write, a merge forces its file every 8 MiB (as RocksDB's `bytes_per_sync` does), so that no journal fsync
queues behind hundreds of megabytes of a merge's dirty pages; a merge nobody waits beside (`snapshot`, recovery)
forces once. At 256 clients a merge writes a level of a few hundred thousand facts (0.3 s) where the one level rewrote
the base (3.7 s): the same throughput (the disk's, 18,252 groups a second), a peak of 762 MB against 1,040. Loading 10
M facts a group a client takes 112 s against 157 s with one level, bound by the journal's fsyncs and the merges'
writes sharing the disk.

## Large groups

A load is the same `write`, in a few large groups. A group of 20,000 operations or more, all of them `Add`, takes a
faster path to the same result inside the writer (`Resolve.resolve_large`): its facts go into arrays, sorted by
counting (by thing, by property) and by a stable radix sort of the values inside each property (Knuth, vol. 3,
section 5.2.5), and they are merged at once with the delta and the newest runs into a run file, as one more sorted
input; no persistent map is built for them. The path decides only what it can decide alone (additions to new or
ordinary things, one value per new thing for a one-valued property, many-valued additions to existing things, no
unique value already taken); on any doubt the group goes the ordinary way, which decides as always, errors included,
so a fork, which always goes the ordinary way, answers as the database does (G8). The run file takes its name only
once the group's frame is durable (G12); no background merge runs beside a large group. A group whose frame would pass
256 MiB is refused (`Invalid`), and a large group starts a frame of its own, so that the groups resolved together
never make a frame over that limit. Measured: 10 M facts in two large groups load in 7.04 s [6.52, 7.41] (10 runs),
SQLite 3.54 in 6.97 s [6.38, 8.00] alternated with it (a tie); the large group needs 2.5 to 3.2 GB at its peak, where
SQLite needs 11 MB ([benchmarks](benchmarks.md#loading)).

## Pages and the cache

The runs are read in **pages** of 16 KiB through one cache for the process, Cepheus' own (a **buffer pool**: the
database, not the kernel, decides which pages stay in memory). Its size is `set_cache` (1 GiB by default). Why not let
the kernel do it with `mmap`: a mapped file turns a disk error into a signal that kills the process, gives the
database no say in what is evicted, and stalls unpredictably beyond memory (Crotty, Leis, Pavlo, CIDR 2022). With its
own cache Cepheus checks every page against its CRC when it arrives from the disk (a damaged page is never served, even
one damaged after the open), returns a disk error as an error, and works on data larger than memory.

**A read** of a page in memory is one array read and one comparison, with no lock, from any domain: each base has a
table of its pages that are "hot" (each part of a run has its own). A page not hot goes the slow way: if it is in memory, one read is counted for the
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
  and the merge's install are modelled (`spec/`): 3,856,315 and 983,080 states, no violation, and each safety rule,
  removed alone, gives a counterexample (the recovery's rewrite after a failed fsync in 4 steps).

Details: [testing](testing.md).

## Further reading

- Write-ahead logging and group commit: Mohan et al., ARIES (TODS 1992); DeWitt et al. (SIGMOD 1984); Helland et al.
  (HPTS 1987).
- Crash consistency: Pillai et al., ALICE (OSDI 2014); Rebello et al., fsync failures (USENIX ATC 2020); Koopman,
  CRC-32 (DSN 2002).
- LSM-trees: O'Neil et al. (Acta Informatica 1996); Luo and Carey, survey (VLDB Journal 2020); Dayan, Athanassoulis,
  Idreos, Monkey (SIGMOD 2017); Dayan and Idreos, Dostoevsky (SIGMOD 2018); Dong et al., RocksDB (CIDR 2017); Balmau
  et al., SILK (USENIX ATC 2019).
- Rank tables and sorting: Jacobson, succinct trees (FOCS 1989); Knuth, The Art of Computer Programming, vol. 3
  (1998); Bentley and Yao, unbounded searching (IPL 1976).
- Buffer management: Crotty, Leis, Pavlo, mmap (CIDR 2022); Leis et al., LeanStore (ICDE 2018); Yang et al., S3-FIFO
  (SOSP 2023); Belady (IBM Systems Journal 1966).
- Joins: Atserias, Grohe, Marx (FOCS 2008); Ngo, Porat, Ré, Rudra (PODS 2012); Veldhuizen, Leapfrog Triejoin (ICDT
  2014); Ngo, Ré, Rudra (SIGMOD Record 2013).
- Testing: Zhou et al., FoundationDB (SIGMOD 2021); Lamport, Specifying Systems (2002); Newcombe et al., AWS (CACM 2015).

Full entries, with links: [references](references.md).
