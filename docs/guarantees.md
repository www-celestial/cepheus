# Guarantees

Each guarantee states what is promised, under which faults, its exact conditions, why it holds (a proof sketch), and
the test that checks it. The tests are in `test/`; `tools/test.sh` runs them all. The words are explained in
[concepts](concepts.md), [architecture](architecture.md) and the [glossary](glossary.md); the mathematics is in
[theory](theory.md). Everything here is as of this version: one machine, runs on disk in levels (leveling, ratio 4), no replication.

| | promise, in one line | under |
|---|---|---|
| G1 | a confirmed group survives every crash and recovery | F1, F2 |
| G2 | a group is all or nothing | F1, F2 |
| G3 | after recovery, the groups are a prefix 1..k of the history, k ≥ the last confirmed | F1, F2 |
| G4 | the groups are strictly serializable | always |
| G5 | a view never changes and holds only durable groups; views never go back | F1, F2, F4 (with G13) |
| G6 | damage to durable journal bytes is detected, never dropped in silence | F3 (one residual) |
| G7 | an open from the runs on disk equals a replay of the journal; a damaged page is never served | F1 to F3 |
| G8 | a fork changes nothing of its database | always |
| G9 | one process at a time opens a database | always (two conditions) |
| G10 | after a failed write or fsync, nothing more is confirmed | F4 (one residual) |
| G11 | a question returns exactly its answers, each once, within the Generic Join bound | always |
| G12 | a crash during a merge leaves the runs before it or the runs after it, whole | F1, F2, F4 |
| G13 | after a failed fsync, no view shows a group a power loss could take back; a write answered `Io` is absent (one residual) | F4 with F1, F2 |

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
CRC except with probability 2⁻³² (for random damage).

*Tested by* the simulation (groups on disk compared one by one with the written ones) and the exhaustive enumeration.

## G3 Prefix

*Promise.* After recovery the groups present are exactly 1..k for some k ≥ the last confirmed group, and the state
is the application of groups 1..k in order.

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

*Proof.* There is one writer per database (G9), and it resolves group n on the working state S(n-1), producing S(n):
the execution is serial by construction (Papadimitriou 1979). A number is given when the writer takes a group, which
is after it was submitted; if a returned, its number was given before b was submitted. Reads of a group's `Expect`
are evaluated against S(n-1) inside the writer, so a read-modify-write that states what it read with `Expect` is
serializable (optimistic validation, Kung and Robinson 1981); one that does not is not protected against a lost update.

*Tested by* `test/bank.ml` (transfers with `Expect` from 16 threads; the total is constant in every view and at the
end) and the named write-skew case in `test/unit.ml`.

## G5 Stable, durable views

*Promise.* A view is the exact state after one group; it never changes; the database's view shows only durable groups;
after `write` returned group n, every view taken afterwards has a number ≥ n; the views one thread takes never go back.

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
simulation (the published view equals the model at its number, which is ≥ the last confirmed; after a recovery, the
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
realistic size; other random damage escapes with probability 2⁻³² (Koopman 2002). A full read is strict: on a journal
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
CRC of the checksum table, the rank tables (each word's count follows from the bits before it, the last equals the
things) and the order and bounds of every offset table (`Snapshot.check_and_build`). Every page goes through
`Pages.fill`, which checks its CRC-32C before it enters the frame table: no other path puts a page there. Every access
to a run is bounds-checked (the frame table, then the page), so a read never leaves the run's bytes. For random damage
of a page, CRC-32C misses it with probability 2⁻³²; it detects every burst of up to 32 bits (Castagnoli, Bräuer,
Herrmann 1993).

*Several runs read as one state.* A fact is in a view iff the newest entry for it (the delta's, or the newest run's
that has one) adds it; a count is the sum of each run's rows minus its retractions, plus the delta's net count (the
runs are net, so nothing is counted twice); an iteration shows a row of a run only if no newer run has an entry for the
same fact (docs/theory.md, section 9). *Tested by* `test/unit.ml` ("several runs": 120 random views of up to 4 runs that
add and retract, against their full merge and a naive evaluator; "large groups").

*Tested by* the simulation (merges at random moments, crashes inside their writing, flips in run files) and
`test/unit.ml` (round trip; a run of another database is refused; a flipped run is set aside; a run three times larger
than the cache, read by three domains, with a bit flipped after the open: the questions answer right or return
`Damaged`, and exactly the damaged page fails).

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

*Promise.* Two processes cannot open a database at the same time, and one process cannot open it twice.

*Conditions.* The lock is advisory: it stops another Cepheus, not a program that writes the files without taking it
(a copy, an editor, a second program on another machine through a network file system whose locks do not reach
here). Inside one process, the table of held locks is keyed by the path as it was written: open a directory under one
spelling only (`shop` and `./shop` are two keys, and the kernel's `lockf` lets the same process lock twice).

*Proof.* Opening takes an exclusive `lockf` lock on `DIR/lock`, held until close; the kernel releases it when the
process dies. Within one process, a table of held locks refuses a second open.

*Tested by* `test/unit.ml` (a second open returns `Busy`).

## G10 Stop on a disk error

*Promise.* Under F4, after a failed write or `fsync` of the journal, no further group is confirmed: every later
write returns the same `Io` error, until the database is closed and opened again; recovery starts from the journal.
The `fsync` is never retried.

*Conditions.* The stop is for the journal, the truth. A disk error while a merge writes a run file (a background
merge, a large group's run, `snapshot`) does not stop the database: no group rests on that file (it takes its name
only once its groups are durable, G12), so the file is removed, the error goes to stderr or to the caller of
`snapshot`, and the writer goes on with the runs it had; a large group whose run fails returns `Io` for that group
only. A failure to give a large group's run its name, after its frame is durable, stops the database (the next open
replays the group from the journal).

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
(exact counts, on the base and on the delta alike); every other pattern only looks each one up, in O(log n). The
total is the instance bound of Generic Join (Ngo, Ré, Rudra 2013), within the AGM bound of the question.

*Tested by* the property tests and the simulation: every random question, on views with a delta and after recoveries,
must give the naive evaluator's answers and enumerate at most the bound that `test/check.ml` computes from the facts
alone (`Query.work` counts the candidates); and named cases where one list is far larger than the answer (a status
shared by 20,000 invoices, a hot tag in the delta, a range of 10 scores among 20,000, a thing with 40,000 values).

*Tested by* `test/unit.ml`: 300 random databases and 15 random questions each (up to 3 patterns, constants, links,
ranges) compared with a naive evaluator over all facts, on a base with a delta and on a compacted base.

## G12 Merges are atomic

*Promise.* After a crash at any point of a merge (F1, F2, F4), the database opens on the runs before it or on the
runs after it, each whole, never a mix; its state is the replay of the journal to the recovered group (G7); no run has
to be set aside and no merge's file is left. A merge needs no more memory than the cache, a few page buffers and 21
bytes a page of the new run (see [theory](theory.md), section 8).

*Proof.* (a) A merge writes its file under a temporary name and forces it before the rename: a name, durable or not,
never points at bytes that are not on the disk. (b) The rename is atomic; under F2 a prefix of the directory's name
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
the disk. Cost: one `pwrite` of the newest frame (a few KB, at most 8 MB) at an open after a crash; nothing at an open
after a clean close, nothing on the write path.

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
