# Guarantees

Each guarantee states what is promised, under which faults, its exact conditions, why it holds (a proof sketch), and
the test that checks it. The tests are in `test/`; `tools/test.sh` runs them all. The words are explained in
[concepts](concepts.md), [architecture](architecture.md) and the [glossary](glossary.md); the mathematics is in
[theory](theory.md). Everything here is as of this version: one machine, runs on disk in levels (leveling, ratio 4), no replication; rules as [rules](rules.md) tells.
G14, G15 and G16 belong to the server: their statements, proofs and tests are in [the server's page](server.md#writes-applied-once-sessions-g14)
([G15](server.md#local-reads-g15): reads in a program's own memory on the server's machine). Through the server, G1 to G13 keep
their statements: a group is confirmed when its receipt is sent, after its fsync, and every read names the durable group
it was answered from; `server_sim` checks them over a simulated network with the server's crashes.

| | promise, in one line | under |
|---|---|---|
| G1 | a confirmed group survives every crash and recovery | F1, F2 |
| G2 | a group is all or nothing | F1, F2 |
| G3 | after recovery, the groups are a prefix $1, \dots, k$ of the history, $k \ge$ the last confirmed | F1, F2 |
| G4 | the groups are strictly serializable | always |
| G5 | a view never changes and holds only durable groups; views never go back | F1, F2, F4 (with G13) |
| G6 | damage to durable journal bytes is detected, never dropped in silence | F3 (one residual) |
| G7 | an open from the runs on disk equals a replay of the journal; a damaged page is never served | F1 to F3 |
| G8 | a fork changes nothing of its database | always |
| G9 | one engine at a time opens a database, whatever the path that names it | always (the lock is advisory) |
| G10 | after a failed write or fsync, nothing more is confirmed | F4 (one residual) |
| G11 | a question returns exactly its answers, each once, within the Generic Join bound | always |
| G12 | a crash during a merge leaves the runs before it or the runs after it, whole | F1, F2, F4 |
| G13 | after a failed fsync, no view shows a group a power loss could take back; a write answered `Io` is absent (one residual) | F4 with F1, F2 |
| G14 | through the server, a write sent with its session and serial is applied at most once; sent again until answered, exactly once, every answer naming the same group | F1, F2, broken connections |
| G15 | every read, in a local reader or at the server, holds every group answered and every state read before it started, and is the exact state after a durable group: reads are linearizable | F1, readers slow, paused or killed, broken streams |
| G16 | through the server, a connection does exactly what its token's rights permit | always |
| G17 | every view holds exactly the least model of its asserted facts under its rules, and marks exactly those asserted | always (with G1-G3 under F1, F2) |
| G18 | no confirmed group leaves an instance of a constraint (`Never`) | always |
| G19 | a rule change takes effect at one group | always |
| G20 | `why` returns a well-founded proof of a fact of the view, or nothing for a non-fact | always |
| G21 | every message of a live question (`Watch`) leaves the program with exactly `Find`'s rows at its group, a durable one; its groups only grow, none skipped that changed the rows | F1, F2, broken connections, slow programs |

## The faults

- **F1 process crash**: the process stops at any instruction (`kill -9`, a bug, the OOM killer). What it wrote and
  did not force stays in the page cache: readable by the next process, and lost at a later power loss.
- **F2 power loss**: the machine stops at any moment. Data not covered by a finished `fsync` may be lost, kept, kept
  in any order sector by sector (512 bytes), or torn inside a sector; a file created, renamed or removed without an
  `fsync` of its directory may lose that change. Changes of names in one directory survive as a prefix, in order.
- **F3 silent corruption**: bytes already durable change (flipped bits, a replaced sector).
- **F4 I/O error**: a write or an `fsync` fails. Linux file systems then mark the pages that `fsync` covered clean,
  although they never reached the disk; ext4 and XFS keep their new bytes in memory, readable until the pages leave
  the page cache (a reboot, memory pressure), and a later `fsync` succeeds without writing them; ext4 may make the new
  file size durable over blocks never written; Btrfs undoes the failed writes in memory too (Rebello, Patel,
  Alagappan, Arpaci-Dusseau, Arpaci-Dusseau, "Can Applications Recover from fsync Failures?", USENIX ATC 2020,
  section 3.3). In short: after a failed `fsync`, what a process reads back may be bytes the disk does not hold.

Out of reach of one machine (replication will cover them): a disk that acknowledges an `fsync` without writing (and
ext4 mounted with `data=journal`, which reports a failed write at the next `fsync` rather than the one that covered it:
the paper's section 3.3.1); the loss of a whole durable frame at the end of the journal with nothing written after it;
someone who rewrites the journal and its checksums; corrupted RAM (use ECC).

A group is **confirmed** when `write` returned `Ok`.

## G1 Durability

*Promise.* Under F1 and F2, a confirmed group is present after any sequence of crashes and recoveries, with exactly
its changes.

*Conditions.* The disk keeps what an `fsync` reported done (consumer disks with a volatile write cache may not:
[operations](operations.md#disks)); the confirmed group's own frame is not damaged afterwards (that is F3, G6). The
promise is for groups whose `write` returned `Ok`: a group whose `write` returned an error, or that was still in flight,
may be present or absent.

*Proof.* `write` returns after the syncer's `fsync` of the frame that holds the group returned (the writer publishes
and answers in `Engine.commit`, after `Journal.append`, whose last call is `fsync`). A new segment is used only after
its header was written, its file forced and its directory forced (`write_segment_header`). So every byte of every
frame up to the group's is durable; F2 does not touch durable bytes. Recovery (`Journal.scan`) reads frames in order
and stops only at the first frame that does not check; all frames before a durable frame are durable, hence intact,
hence read. The runs used at recovery are consistent with the journal (G7).

*Tested by* `test/sim.ml` (every recovery: "lost acknowledged groups"), `test/exhaustive.ml` (every crash state of
small journals), `test/crash.ml` (real `kill -9`, every confirmation checked for content).

## G2 All or nothing

*Promise.* After recovery, each group is entirely present or absent.

*Proof.* A group is encoded inside one frame; a frame is taken only if its header CRC and its body CRC check and its
groups decode to the end of the body; otherwise recovery stops before it. A frame torn in the middle fails its body
CRC except with probability $2^{-32}$ (for random damage). A large group's frame, which holds it alone, is written by pieces
as it is encoded: its whole body first, then its header, then its trailer, then one fsync; until the header is
written the pieces make no frame (recovery cuts them as a torn tail), and the group is confirmed only after the fsync.

*Tested by* the simulation (groups on disk compared one by one with the written ones) and the exhaustive enumeration.

## G3 Prefix

*Promise.* After recovery the groups present are exactly $1, \dots, k$ for some $k \ge$ the last confirmed group, and the state
is the application of groups $1, \dots, k$ in order.

*Proof.* Frames are appended in group order (`Journal.append` refuses another order); recovery checks that each frame
starts at the expected group and each group has the expected number, across segments ("a segment is missing"
otherwise), and cuts everything after the first frame that does not check. Replay applies the recorded changes in
order (`Resolve.replay`). If the newest run says group S, a journal that ends before S is damage, not a shorter
history.

*Tested by* the simulation: after every recovery the state is compared with the reference model (the recorded groups
1..k applied to a set of facts), and k is checked to lie between the last confirmed and the last prepared group.

## G4 Strict serializability

*Promise.* The history of groups is equivalent to their execution one at a time in the order of their numbers, and
that order respects real time: if `write a` returned before `write b` started, a's number is smaller.

*Exactly what it covers.* The groups, each with its `Expect`s as its only reads. A read-then-write (a view read,
then a group) is serializable only for the facts and absences its group states with `Expect`: a fact read and not
stated can be overwritten by another group meanwhile (a lost update), and a set read through a question can gain a
member meanwhile (a phantom), unless a fact standing for the set is expected and changed by every writer of it
([concepts](concepts.md#isolation-exactly-what-a-reader-and-a-writer-see), [theory](theory.md#5-serializability-and-isolation)).

*Proof.* There is one writer per database (G9), and it resolves group $n$ on the working state $S(n-1)$, producing $S(n)$:
the execution is serial by construction (Papadimitriou 1979). A number is given when the writer takes a group, which
is after it was submitted; if $a$ returned, its number was given before $b$ was submitted. Reads of a group's `Expect`
are evaluated against $S(n-1)$ inside the writer, so a read-modify-write that states what it read with `Expect` is
serializable (optimistic validation, Kung and Robinson 1981); one that does not is not protected against a lost update.

*Tested by* `test/bank.ml` (transfers with `Expect` from 16 threads; the total is constant in every view and at the
end) and the named write-skew case in `test/unit.ml`.

## G5 Stable, durable views

*Promise.* A view is the exact state after one group; it never changes; the database's view shows only durable groups;
after `write` returned group $n$, every view taken afterwards has a number $\ge n$; the views one thread takes never go back.

*Conditions.* On a database, not on a fork (a fork has no disk: its view holds its writes at once). "Never go back"
holds for the views one thread takes in turn with `view db`; two threads may hold views of different groups. After an
fsync failure and a reopen without a reboot, see the residual of G10.

*Proof.* A view is a persistent value (immutable runs and persistent maps); the writer builds new views and never
changes old ones. The published view is replaced by one atomic store after the frame's `fsync`, before the clients
are answered (`Engine.commit`), and OCaml's atomics order the store before the answer.

*After a recovery too.* The state a recovery opens on is published at once, so it must be durable: but a process killed
between the `pwrite` and the `fsync` of a frame, or between the creation of a segment and the `fsync` of its directory,
leaves them in the page cache, where recovery reads them and a later power loss takes them back. Recovery therefore
writes the newest frame again (G13: after a failed fsync, forcing alone writes nothing) and forces the newest segment
and the journal's directory before it replays any group of that segment (`Journal.recover`), and open forces the
database's directory, unless the last process closed cleanly: `close` leaves a marker (`DIR/closed`) once every
frame and name is durable, and only if no fsync failed; an open removes it before it writes anything. So a marker
seen means that no process wrote since a clean close, or that a power loss came after the writes, and a power loss
leaves nothing in the page cache; the marker's own creation and removal need no fsync (lost, they only make the next
open force). PostgreSQL keeps the same state in `pg_control` (shut down, or in production). (Found by the simulation once it could kill a process without a power loss; mutation check:
without the segment's fsync, 9 of 300 seeds fail, without the directory's, 5.)

*Tested by* the bank test (reader domains check every view they take: constant total, numbers never go back) and the
simulation (the published view equals the model at its number, which is $\ge$ the last confirmed; after a recovery, the
recovered number counts as confirmed, and process deaths are followed by power losses).

*Background merges* keep G5: a merge writes a new run from a view and replays the logged groups after it, and the
writer switches to it only when nothing is in flight and the new view holds exactly the same groups; the published
view is replaced by one atomic store. *Tested by* the bank test, which merges every few dozen changes (156 merges in
4 s) and compares the facts of the old and the new view at every switch, and by the kill -9 rounds with frequent
merges.

## G6 Nothing dropped in silence

*Promise.* Under F3, a change of durable journal bytes is detected by the first read that covers it: a full read
(`Cepheus.verify`, `Journal.read`) reports it; recovery refuses to open (`Damaged`, naming the file and offset) rather
than drop a durable frame. One residual case: damage to the newest frame of the journal, with nothing written after
it, looks like a torn write and is cut at recovery (a full read before recovery reports it).

*Proof.* Every byte of a segment is covered: its header by the header CRC, each frame's header by its header CRC, its
body by the body CRC (repeated in the trailer), the trailer by comparison with the header. At recovery, the first frame
that does not check is damage when a frame header that checks follows it (frames are written one after the other, each
forced before the next, so a later header proves this frame was written whole), or when
a trailer at the right distance carries the body's CRC (the frame was written whole, only its header changed);
otherwise it is a torn tail. A torn write cannot produce either sign unless it lost exactly the header's sector and
kept the rest (after a failed fsync this is likelier, the sectors of the failed write reaching the disk or not one by
one: the writer's cut, G13, removes the frame before a power loss can leave it so). CRC-32C detects every burst of at most 32 bits and every error of at most 3 bits in frames of
realistic size; other random damage escapes with probability $2^{-32}$ (Koopman 2002). A full read is strict: on a journal
that recovery has cut and repaired, any frame or trailer that does not check is damage.

*Model-checked* by `tools/tlc.sh` (`spec/Journal.tla`): with up to 7 frames and 3 silent damages, process deaths and
failed fsyncs (G13), the invariants Durable, RefuseOnlyOnDamage, PublishedOnDisk, Prefix, NoTornData, StopSafe and
ResidualBound hold in all 3,856,315 reachable states. TLC first found a trace where
two damaged frames at the end were both cut; the rule above (a later header that checks) closed it.

*Tested by* `test/exhaustive.ml` (every bit of two journals flipped: always seen by a full read; recovery refuses, or
keeps every group when the flip hit a trailer, which it rebuilds, or, for a flip in the newest frame, cuts it: counted
as the residual) and the simulation (random flips in durable segments).

## G7 Runs on disk

*Promise.* Opening from the runs on disk and the journal after them gives the same state as replaying the whole
journal. A damaged page of a run is never served: a run that fits in the cache is checked whole before the first
question, and the database falls back on other runs or on the journal; a page of a larger one is checked each time it
is read from the disk (also when it was damaged after the open), and the read fails: `find` and `fold` return
`Damaged`, `get`, `values` and `things` raise `Unreadable`, a write that needed the page fails. Never a wrong answer.

*Proof.* A run is the file of a merge (G12): the changes of groups lo+1..hi on top of the state at lo, net (it adds
only facts absent below it, retracts only facts present below it), with the journal position of the last durable frame
before its group. Open takes a chain of runs from 0, each resting on the end of the one below (any such chain is the
state at its top, since a run holds the changes of its groups on top of the state at its lo, whatever runs make that
state); replay starts at the newest run's position and skips the groups it holds. Loading checks the header CRC, the
CRC of the page table and that it maps each page of the file at most once, the order of the sections, the rank tables
(each word's count follows from the bits before it, the last equals the things) and the order and bounds of every
offset table and directory, the columns' among them (each column within its sections, its rank table's counts, its
row offsets each larger than the one before up to its rows, its blocks in order: `Snapshot.check_and_build`). A run
that fits in the cache is read and checked whole, by up to 4 domains for a run of 512 pages or more, each with its
own descriptor, before it is taken. Every page goes through `Pages.fill`, which reads the file
page the page table names and checks the CRC-32C the table gives before it enters the frame table: no other path puts
a page there. Every access to a run is bounds-checked (the frame table, then the page's bytes or a block's copy), so
a read never leaves the run's bytes. The coding of formats 7 and 8 (blocks by a frame of reference, a page table, the
column order) changes what a page holds, not this argument: a value is decoded only from a page that checked. For random damage
of a page, CRC-32C misses it with probability $2^{-32}$; it detects every burst of up to 32 bits (Castagnoli, Bräuer,
Herrmann 1993).

*Several runs read as one state.* A fact is in a view iff the newest entry for it (the delta's, or the newest run's
that has one) adds it; a count is the sum of each run's rows minus its retractions, plus the delta's net count (the
runs are net, so nothing is counted twice); an iteration shows a row of a run only if no newer run has an entry for the
same fact ([theory](theory.md#9-levels-on-disk-and-large-groups), section 9).

*Tested by* the simulation (merges at random moments, crashes inside their writing, flips in run files) and
`test/unit.ml` (round trip; a run of another database is refused; a flipped run is set aside; a run three times larger
than the cache, read by three domains, with a bit flipped after the open: the questions answer right or return
`Damaged`, and exactly the damaged page fails; "several runs": 120 random views of up to 4 runs that add and retract,
against their full merge and a naive evaluator; "large groups").

## G8 Forks

*Promise.* Writing to a fork changes neither the database, nor any of its views, nor a byte of its files; a fork
accepts and refuses exactly what the database would on the same state.

*Proof.* A fork holds a view and a mutex, and no disk; its writes go through `Resolve.resolve`, the function the writer
uses, into the fork's own persistent delta, and its new texts into its own dictionary layer (a fork never appends to
the database's shared dictionary). Persistent structures are never changed in place, except a bitset of touched
things, which a fork copies.

*Tested by* the simulation (forks of the published view written to at random; the view's facts and every file's bytes
compared before and after) and `test/unit.ml` (two forks given the same writes agree; a database and a fork given the
same writes accept and refuse the same ones and end equal; the journal files are unchanged by forks).

## G9 One writer

*Promise.* Two processes cannot open a database at the same time, and one process cannot open it twice, under any
path that names its directory: `shop`, `shop/`, `shop/.`, `./shop`, `x/../shop` and a symbolic link to it are one
database (and so is a bind mount of it, which shows the same device and inode; not tested here).

*Conditions.* The lock is advisory: it stops another Cepheus, not a program that writes the files without taking it
(a copy, an editor, a second program on another machine through a network file system whose locks do not reach
here).

*Proof.* Opening takes an exclusive `lockf` lock on `DIR/lock`, held until close; the kernel releases it when the
process dies. A POSIX lock belongs to a process and a file, so the kernel lets the same process lock a file twice:
within one process, a table of the held locks refuses a second open. It is keyed by the identity of the lock file,
its device and inode numbers (`st_dev`, `st_ino`), which every path to the file shares, rather than by the path as
written or by its canonical form (`realpath` resolves symbolic links, but a bind mount still gives a second name). Whether the lock
is held is decided by a `stat` of the path, before any descriptor is opened: closing a second descriptor of a file the
process has locked would release the lock. A second `close` of a database does nothing: it neither releases the lock
again (another engine may hold it by then) nor leaves the clean-close marker in a directory another engine has open.

*Tested by* `test/unit.ml` (a second open returns `Busy` under seven spellings of the path and through a symbolic
link; opened through the link, the directory is busy under its own name; a second close of an old handle leaves the
lock and the marker of the engine that holds the database).

## G10 Stop on a disk error

*Promise.* Under F4, after a failed write or `fsync` of the journal, no further group is confirmed: every later
write returns the same `Io` error, until the database is closed and opened again; recovery starts from the journal.
The `fsync` is never retried.

*Conditions.* The stop is for the journal, the truth. A disk error while a merge writes a run file (a background
merge, a large group's run, `snapshot`) does not stop the database: no group rests on that file (it takes its name
only once its groups are durable, G12), so the file is removed, the error goes to stderr or to the caller of
`snapshot`, and the writer goes on with the runs it had; a large group whose run fails returns `Io` for that group
only, and its frame's pieces are taken back off the journal (`Journal.drop`, forced; if that fails, the database
stops). A failure of the journal's own file while a large group's body is written by pieces stops the database as a
failed `append` does: the journal is cut back to its last durable frame. A failure to force a large group's run or to
give it its name, after its frame is durable, stops the database, the group confirmed (the next open replays it from
the journal).

*Residual at this version.* What happened to the writes answered `Io` is certain only when the writer's cut back to
the last durable frame succeeded (G13): then they are absent from every later state. If the process died before the
cut, or the cut failed too (stderr: `cepheus: the journal could not be cut back after a failed write`), the failed
frame may be on the disk or not, and a reopen may show its groups, whole (G2), though no writer was told `Ok`; once a
view shows them, they stay (G13). So after an `Io`, an application that must know reads the state after the reopen
rather than assume the write absent. No reboot is needed (before G13, a reopen in the same boot could publish a frame
that a later power loss took back).

*Proof.* `Engine.commit` catches the error, marks the engine stopped, fails the batch; `prepare` fails every later
request while stopped. Retrying an `fsync` after a failure could confirm data the kernel dropped (Rebello et al. 2020).

*Tested by* the simulation (failed fsyncs injected; a confirmation after one is a failure; the simulated disk marks
the pages clean without writing them, as Linux does, and a later fsync does not write them either: see G13).

## G11 Exact answers

*Promise.* A question returns exactly the bindings that make all its patterns facts of the view, each once.

*Proof.* See [theory](theory.md), Generic Join: every binding is built variable by variable from candidates that
satisfy every pattern on the variables bound so far, so every output is an answer; every answer's values are
candidates at each level (they satisfy the pattern used as a source and are accepted by the others), so every answer
is output; candidates at one level are distinct, so no answer comes twice.

*And its cost.* At each level, the candidates enumerated for one partial binding are the smallest set a pattern offers
(exact counts, on the base and on the delta alike); every other pattern only looks each one up, in $O(\log n)$. The
total is the instance bound of Generic Join (Ngo, Ré, Rudra 2013), within the AGM bound of the question. A pattern of
a one-valued property whose thing is bound offers at most one candidate; its count is not looked up: it is taken
before every pattern that offers one or more and after one that offers none (`Query.count_with` compares $2c$ for an
exact count $c$ against 1 for it). Either way the level enumerates at most the smallest exact count: if the pattern has
no value, it gives nothing, and if another offers none, that one is taken. So the bound is unchanged, and the unit
tests' exact bound still holds. A check left to the next level (a pattern whose other side is the next variable)
changes no count: a binding that fails it reaches the next level, where that pattern offers nothing and is the
source. The leapfrog (run format 8, [theory](theory.md#4-generic-join)) reads, at a level whose source is a slice
of $m \ge 2$, every other slice of at most $8m$: the tested bound adds those slices' sizes, at most $1 + 8 (k - 1)$ times
Generic Join's for $k$ slices.

*Tested by* the property tests and the simulation: every random question, on views with a delta and after recoveries,
must give the naive evaluator's answers and enumerate at most the bound that `test/check.ml` computes from the facts
alone (`Query.work` counts the candidates); and named cases where one list is far larger than the answer (a status
shared by 20,000 invoices, a hot tag in the delta, a range of 10 scores among 20,000, a thing with 40,000 values).
And by `test/unit.ml`: 300 random databases and 15 random questions each (up to 3 patterns, constants, links,
ranges) compared with a naive evaluator over all facts, on a base with a delta and on a compacted base.

## G12 Merges are atomic

*Promise.* After a crash at any point of a merge (F1, F2, F4), the database opens on the runs before it or on the
runs after it, each whole, never a mix; its state is the replay of the journal to the recovered group (G7); no run has
to be set aside and no merge's file is left. A merge needs no more memory than the cache, a few page buffers and 21
bytes a page of the new run (see [theory](theory.md), section 8).

*Proof.* (a) A merge writes its file under a temporary name and forces it before the rename: a name, durable or not,
never points at bytes that are not on the disk (a large group's run is forced in its commit, at the same time as its
frame's fsync, on the other file; `Snapshot.install` forces any run not yet forced before it renames it). (b) The rename is atomic; under F2 a prefix of the directory's name
changes survives: the new name, or not. (c) A file gets its name only once its group is durable in the journal: the
install runs with nothing in flight (the writer waited for the syncer), or, for a large group's run, in the commit
after the group's frame was forced; and only if no fsync failed (G10); the merges a recovery makes while it replays a
long tail come after it wrote the newest frame again and forced the journal (G5, G13). The journal is never cut below a
run: a journal that ends before the newest run's group lost durable frames, and the database refuses to open (G6).
(d) The runs a merge replaced are removed only after the fsync of the directory that made the new name durable, so a
chain to the newest group is always named. (e) Open removes the `.tmp` files of interrupted merges, and takes the
chain of named runs from 0 that reaches the newest group with the fewest runs (G7). A failed merge (a disk error while
writing) removes its file and the writer goes on with the old runs; the next merge waits until the delta has grown by
another threshold.

*Tested by*
- the exhaustive enumeration (`test/exhaustive.ml`, part 4): at every mutating disk call of a merge (a merge now of
  every run; one begun from a view ahead of the disk and installed two frames later; a large group's, merged as it is
  prepared and named once its frame is durable; the merges of a recovery replaying a long tail), every crash state: a
  process death (then a power loss), and power losses keeping each prefix of each directory's name changes, with the
  unforced bytes lost, kept, torn, or kept one sector in two: 194 crash points, 1,944 states, each recovered and
  checked (state of the reference, every confirmed group, old or new runs, nothing set aside, no `.tmp` left);
- the simulation (merges of the newest runs at random levels, begun ahead of the disk and installed steps later,
  abandoned after a failed fsync; large groups; process deaths; crashes inside any disk call of a merge; a merge's
  file forced every 8 pages);
- the kill -9 rounds (merges every 50 changes; the rounds that kill inside a merge are counted);
- `spec/Merge.tla`, checked by TLC (`tools/tlc.sh`): chains of runs named by their groups, merges of any number of
  the newest runs, recovery taking the chain that reaches the newest group; the invariants NoMix, SnapshotInJournal,
  ChainNamed (the runs a process reads are named and form a chain from 0), PublishedDurable, AckedDurable over 983,080
  states (3 groups); each of its five rules (force before the rename, install only when durable, force the journal at
  recovery without a marker, a marker only if no fsync failed, the newest frame written again at recovery) removed in
  turn gives a counterexample in 4 or 5 steps;
- `test/unit.ml`: a merge of a run 8 times the cache keeps every fact, holds at most 7 pages open, and never more
  pages resident than the cache.

## G13 A failed fsync is never trusted

*Promise.* Under F4 as Linux implements it, mixed with F1 and F2 in any order: no view ever shows a group that a later
power loss can take away, whether in the process where the `fsync` failed, after a reopen in the same boot (which reads
the page cache), or after a reboot; every confirmed group stays (G1); a refusal to open never comes from the failure
itself. And a write answered with an `Io` error is absent from every later state, unless the process died before the
journal was cut back or the cut failed too: then it may be present after a reopen, and once a view shows it, it stays.

*Why it was needed.* Before this guarantee, the next open in the same boot forced the journal, which wrote nothing (the
pages were clean), read the failed frame from the page cache, published it, and appended after it. A power loss then
took the frame back: readers had seen a group that vanished, and the confirmed frames after the hole made the
database refuse to open. The paper finds the same "false failure" in LevelDB, SQLite's write-ahead log and
PostgreSQL, whose recovery reads the log through the page cache (section 4.3). The simulation found it as soon as its
disk modelled F4 this way (8 of 300 seeds failed); before, its `fsync` copied every byte in memory to the disk,
including the bytes a failed `fsync` had marked clean.

*Proof.* (a) In the running process, a view is published only after the `fsync` of its frame returned (G5). That frame
was written whole after the last successful `fsync`, so every page it touches is dirty, and a successful `fsync` writes
them. After a failure the writer stops (G10) and publishes nothing more. (b) The writer then cuts the journal back to
the end of its last durable frame (`Journal.cut`): the file truncated there, a segment that a failed switch began
removed, the file and the directory forced. When this succeeds, the failed frame is neither in the page cache nor on
the disk, so its write is absent for good, and no power loss can leave a part of it that recovery would take for
damage (G6's false alarm, a frame whose header's sector alone was lost). (c) The process may die before the cut, or
the cut may fail. So a recovery after anything but a clean close writes the newest frame of the journal again before
it replays any group of the newest segment (`Journal.rewrite_newest`; the segment's header when it holds no frame),
then forces the segment and the directory. Only that frame can be off the disk: frames are written one at a time,
each forced before the next; the writer stops at the first failure; a segment is begun only once every frame of the
previous one is durable. The pages written again are dirty, so a successful `fsync` writes them: on ext4 and XFS the
bytes in memory are the frame, which becomes durable; on Btrfs they are already the disk's, and writing them again
changes nothing. If that `fsync` fails, the open fails and publishes nothing; the next one writes again. This is the
paper's own advice: re-dirty the pages by writing them back (section 5, #7), and let recovery rest on what the disk
holds (#8). Nothing is retried blindly (G10): an `fsync` that follows a fresh write of the same bytes is a new write.
(d) After a clean close no `fsync` had failed: `close` leaves its marker only then. (e) After a power loss, reads show
the disk. Cost: one `pwrite` of the newest frame at an open after a crash (a few KB, at most 8 MiB for the frames of
small groups; a large group's whole frame, up to 256 MiB, when it is the newest, rewritten through the 4 MiB window);
nothing at an open after a clean close, nothing on the write path.

*Model-checked* by `tools/tlc.sh`: `spec/Journal.tla` models the page cache and the disk apart (written and not
forced, marked clean by a failed `fsync`, kept or undone in memory, a truncation forced or not), process deaths with
recoveries that read the page cache, and power losses; its invariants PublishedOnDisk (every frame readers may see is
on the disk), RefuseOnlyOnDamage, Durable, StopSafe hold in all 3,856,315 states (7 frames, 3 damages). With the
recovery's rewrite removed, TLC finds a counterexample in 4 steps even with the writer's cut: write, the `fsync` fails,
the process dies before the cut, the recovery publishes the frame. With the writer's cut removed, the invariants still
hold (the cut is what keeps the outcome of a failed write certain, which the model does not state). `spec/Merge.tla`
has the same rule (RewriteAtRecovery); without it, a published group is not durable in 5 steps.

*Tested by*
- the simulation, whose disk now does what the paper measured: a failed `fsync` marks the written sectors clean, keeps
  their bytes in memory (ext4, XFS; the new size made durable at random) or undoes them (Btrfs, a third of the seeds),
  and a later `fsync` writes only the sectors written since; a power loss resolves the sectors marked clean as lost,
  kept, or torn. Failed fsyncs are injected, sometimes with a process death a few calls later (inside the cut).
  Mutation check, 1,000 seeds: with the rewrite removed (the cut kept), 1 seed fails; with the cut removed (the
  rewrite kept), none fails but 2 end on the false alarm of G6 (a refusal to open after a power loss that kept the
  failed frame without its header's sector);
- the exhaustive enumeration (`test/exhaustive.ml`, part 5): each `fsync` of a small run (frames, segment switches,
  a merge) fails in turn, on both kinds of file system; the process dies at each of the next four disk calls or goes
  on; a reopen in the same boot or none; a power loss keeping all or none of the name changes, the unforced bytes
  lost, kept, torn or kept one sector in two; every reopen must give a state of the reference with every confirmed
  group, and what the first reopen published must survive: 13 fsyncs, 2,880 reopens, no failure. With the rewrite
  removed, 44 of them fail (the deaths between the failed fsync and the cut).

## G17 Exact materialisation

*Promise.* Every view — of any group, in any process, after any crash and recovery, of a fork — holds exactly the
**least model** of its asserted facts under the rules defined at its group: a fact is in the view if and only if it is
asserted or it has a proof (a finite tree of rule instances whose leaves are asserted facts). And a fact is marked
asserted in the view if and only if it is asserted.

*Conditions.* Rules as this version has them: Datalog without negation, aggregates or new things in heads, each
rule range-restricted and typed (checked when it is written). A group refused (by its budget, a constraint, a schema
rule) leaves nothing.

*Proof.* (1) *Insertion.* Semi-naive evaluation from the group's asserted additions reaches the least fixpoint of the
rules over the state after the retractions: every rule instance with a fact of round r is enumerated in round r
(the atoms before the matched one over rounds below r, those after over rounds up to r), so every instance that
involves a new fact is found, each once ([Bancilhon 1986], [Ramakrishnan 1990]); instances over older facts only were
found by the groups before (induction on groups). (2) *Retraction.* Backward/Forward removes exactly the facts left
without a proof ([Motik 2015]), under three conditions this implementation keeps and the tests
check: a deleted fact's lost instances are enumerated over the state before it goes; the group's retracted facts
leave the asserted set at once and the state only when disproved; a fact retracted then asserted again is asserted.
(3) *Rule changes.* A rule added is evaluated over the whole state (its instances over older facts), then with the
others by semi-naive; a rule removed gives B/F its heads as candidates. (4) *Durability.* The derived changes are in
the group's own frame, written and forced with it (G1, G2); replay applies them by kind and evaluates nothing, so a
recovered view, a replica's or the past's is the writer's, byte for byte of facts. (5) *Runs.* A merge keeps each
fact's flag: for each fact, the newest entry gives its state in the new view and the oldest its state below the merged
runs; a flag changed is a retraction and an addition in the new run.

*Tested by* `test/reasoning.ml` (after every group of random sequences of 60 groups, 60 seeds plain and 60 with the
facts merged into runs between groups in `tools/test.sh`, `RULES_SEEDS` for more: random safe typed rules defined, changed and removed, random additions and
retractions of asserted, derived and both, the view equal to the least model of its asserted facts computed from
scratch by naive evaluation with the checker's own evaluator, `Check.least`, and its asserted facts equal to the
model's); the simulation (three rules from each seed's third group: the published,
recovered and fork views equal to the least model, after crashes in every disk call, power losses, damaged files,
merges begun ahead); `test/crash.ml` (a rule marks each client's thing; after each `kill -9`, every confirmed thing
has its mark, the loader's none).

## G18 Constraints hold

*Promise.* No confirmed group leaves an instance of a constraint (a rule whose head is `Never`); a group that would is
refused whole, `Invalid "constraint NAME: …"`; a constraint is defined only over a state without an instance of it.

*Proof.* Rules without negation are monotone: a new instance of a constraint's body needs a fact the group made
present. After the fixpoint, the constraint's plans run on each such fact (each body atom matched to it, the others
over the final state); a constraint added runs over the whole state. A group that finds an instance raises before
its frame is made.

*Tested by* `test/reasoning.ml` (random constraints among the random rules: a group is refused exactly when the least model
after it has an instance of one, checked from scratch; the named case: the refused group changes nothing).

## G19 A rule change takes effect at one group

*Promise.* Defining, changing or removing rules takes effect at the group that writes it: every view before it holds
the least model under the old rules, every view from it the least model under the new.

*Conditions.* This version reasons inline, in the group that changes the rules, under the budget; the design's
background path for very large changes comes later and keeps the same promise.

*Proof.* The rule's facts and the derived changes they cause are one group: G2 makes them all visible at once or not.

*Tested by* `test/reasoning.ml` (rules defined, changed and removed at random among the writes; G17 checked on the view
of every group).

## G20 `why` returns a proof

*Promise.* `why v e p x` on a fact of v returns a well-founded proof: its leaves are asserted facts of v, its nodes
instances of rules defined at v whose body facts are its children, every child proved before its parent; on a triple
that is not a fact of v it returns `None`.

*Proof.* The proof is built by B/F's backward check on v, nothing deleted: a fact is proved when it is asserted, or when
an instance whose body facts are all proved has it as head; the instance that proved each fact is kept at that moment,
so each node's children were proved before it, and the tree has no cycle. By G17 every derived fact of v has a
proof, which the check finds: it explores every instance of every rule that gives the fact, until one is proved.

*Tested by* `test/reasoning.ml` (every fifth group of each random sequence: every derived fact's proof checked node by
node — each node's rule exists, its body atoms bind consistently to the children's facts in order, its head is the
node's fact, its ranges hold, every leaf is asserted in the view — and the named case of a two-step proof).

## G21 Live questions

*Promise.* A watch's first message is `Find`'s answer at a durable group; after each next message (a change, or the
answer again), the rows the program holds, the change applied, are exactly `Find`'s answer at that message's group, a
durable group (G1: no crash can take it back). The groups of a watch's messages only grow, and every group that
changed the rows between two messages is in the second one's change: no change is lost, none comes twice, whatever
breaks in between (the connection, the server by `kill -9`, the program's reading).

*Conditions.* The question is a conjunctive query (`Find`'s patterns and ranges), with `Give` or aggregates. A program
that reads slower than the changes come gets the answer again rather than every change (it then holds `Find`'s rows at
the answer's group). A watch ends for good on `Close`, a closed database or a token that may no longer read it (G16).

*Proof.* (1) *A frame's change.* Let $S$ be the facts before a frame and $S'$ after; a binding of the patterns over $S'$
that is not one over $S$ uses a fact of $S' - S$ in some pattern. Taking for each such binding the first pattern that
matches an added fact, the patterns before it over $S'$ without the frame's added facts and those after it over $S'$,
gives each new binding exactly once (the parts are disjoint and cover them); the removed bindings are the same over
$S$ with the removed facts ([Ammar 2018]'s delta query; the rule of semi-naive evaluation, G17 (1)). Rows are `Find`'s rows with
their repeats, so the multiset of rows after the frame is the one before, plus the new bindings' rows, minus the
removed ones'; `Sum` and `Count` follow by difference, and a `Min` or `Max` whose value went is asked again for its key.
(2) *Durable.* A change is held until its frame's group is durable (the server's syncer, a reader's `durable` event),
so its group is one G1 keeps. (3) *Order and resume.* Messages go out in group order on one queue; after a broken
connection or a `lagging` end the package watches again `from` the group of its last message, and the server answers
`same` only when its ring of recent changes covers every group since and none touches the question's patterns
(a property and its constants), else the answer at its newest group, which the package turns into the change from its
rows: `spec/Watch.tla` checks that the rows are always the answer at their group and never go back, with lagging,
broken connections, and a watch stopped and started again (1,015,657 states); without the touch test, or without the
ring's bound, TLC finds a counterexample (`tools/tlc.sh` checks both).

*Tested by* `test/live_sim.ml` (100 seeds in `tools/test.sh`, `LIVE_SEEDS` for more: random groups of adds, removals,
derived facts and merges into runs, large groups; every message of every watch, plain, projecting and aggregating,
equal to the naive evaluator's answer at its group; resume by `same` or the answer, lagging); `test/server_sim.ml`
(watches over the simulated network: pushes cut at any byte, connections broken at any message and watches resumed,
the hub late or at once, lagging, unwatch with pushes in flight, large groups, the server's crashes: every message's
rows are the naive answer at a durable group, never older than the last); `test/server_limits.ml` (a watch that never
reads beside one that reads: the reader gets every change in order, the silent one ends `lagging`); the package's
tests on forks (`cesia/tests/cepheus.test.ce`); `test/cesia.sh` (a watch over TLS, a local one, and one that goes on
through a `kill -9` of the server while 1,500 rows are written: its groups only grow and it ends with the 1,500).
