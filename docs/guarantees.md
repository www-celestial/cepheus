# Guarantees

Each guarantee states what is promised, under which faults, why it holds (a proof sketch), and the test that checks
it. The tests are in `test/`; `tools/test.sh` runs them all.

## The faults

- **F1 process crash**: the process stops at any instruction (`kill -9`, a bug, the OOM killer).
- **F2 power loss**: the machine stops at any moment. Data not covered by a finished `fsync` may be lost, kept, kept
  in any order sector by sector (512 bytes), or torn inside a sector; a file created, renamed or removed without an
  `fsync` of its directory may lose that change. Changes of names in one directory survive as a prefix, in order.
- **F3 silent corruption**: bytes already durable change (flipped bits, a replaced sector).
- **F4 I/O error**: a write or an `fsync` fails. As Linux does, the failed pages may be marked clean without reaching
  the disk (Rebello et al., ATC 2020).

Out of reach of one machine (replication will cover them): a disk that acknowledges an `fsync` without writing; the
loss of a whole durable frame at the end of the journal with nothing written after it; someone who rewrites the
journal and its checksums; corrupted RAM (use ECC).

A group is **confirmed** when `write` returned `Ok`.

## G1 Durability

*Promise.* Under F1 and F2, a confirmed group is present after any sequence of crashes and recoveries, with exactly
its changes.

*Proof.* `write` returns after the syncer's `fsync` of the frame that holds the group returned (the writer publishes
and answers in `Engine.commit`, after `Journal.append`, whose last call is `fsync`). A new segment is used only after
its header was written, its file forced and its directory forced (`write_segment_header`). So every byte of every
frame up to the group's is durable; F2 does not touch durable bytes. Recovery (`Journal.scan`) reads frames in order
and stops only at the first frame that does not check; all frames before a durable frame are durable, hence intact,
hence read. The snapshot used at recovery is consistent with the journal (G7).

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
order (`Resolve.replay`). If the newest snapshot says group S, a journal that ends before S is damage, not a shorter
history.

*Tested by* the simulation: after every recovery the state is compared with the reference model (the recorded groups
1..k applied to a set of facts), and k is checked to lie between the last confirmed and the last prepared group.

## G4 Strict serializability

*Promise.* The history of groups is equivalent to their execution one at a time in the order of their numbers, and
that order respects real time: if `write a` returned before `write b` started, a's number is smaller.

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

*Proof.* A view is a persistent value (an immutable base and persistent maps); the writer builds new views and never
changes old ones. The published view is replaced by one atomic store after the frame's `fsync`, before the clients
are answered (`Engine.commit`), and OCaml's atomics order the store before the answer.

*Tested by* the bank test (reader domains check every view they take: constant total, numbers never go back) and the
simulation (the published view equals the model at its number, which is ≥ the last confirmed).

*Background merges* keep G5: a merge builds a new base from a view and replays the logged groups after it, and the
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
kept the rest. CRC-32C detects every burst of at most 32 bits and every error of at most 3 bits in frames of
realistic size; other random damage escapes with probability 2⁻³² (Koopman 2002). A full read is strict: on a journal
that recovery has cut and repaired, any frame or trailer that does not check is damage.

*Model-checked* by `tools/tlc.sh` (`spec/Journal.tla`): with up to 7 frames and 3 silent damages, the invariants Durable,
Prefix, NoTornData, StopSafe and ResidualBound hold in all 1,084,801 reachable states. TLC first found a trace where
two damaged frames at the end were both cut; the rule above (a later header that checks) closed it.

*Tested by* `test/exhaustive.ml` (every bit of two journals flipped: always seen by a full read; recovery refuses, or
keeps every group when the flip hit a trailer, which it rebuilds, or, for a flip in the newest frame, cuts it: counted
as the residual) and the simulation (random flips in durable segments).

## G7 Snapshots

*Promise.* Opening from a snapshot and the journal after it gives the same state as replaying the whole journal. A
damaged snapshot is detected before the first question and never served; the database falls back on an older
snapshot or on the journal.

*Proof.* A snapshot is written only from a compacted view with nothing in flight, with the journal position of its
last group; it is written beside, forced, renamed, and its directory forced. Loading checks the header CRC, the CRC of
the checksum table, the CRC of every MiB, then the order and bounds of every offset table and every id
(`Snapshot.check_and_build`); only then is it used. Every access to a base is bounds-checked as well.

*Tested by* the simulation (snapshots at random moments, crashes inside their writing, flips in snapshot files) and
`test/unit.ml` (round trip; a snapshot of another database is refused; a flipped snapshot is set aside).

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

*Promise.* Two processes cannot open a database at the same time.

*Proof.* Opening takes an exclusive `lockf` lock on `DIR/lock`, held until close; the kernel releases it when the
process dies. Within one process, a table of held locks refuses a second open.

*Tested by* `test/unit.ml` (a second open returns `Busy`).

## G10 Stop on a disk error

*Promise.* Under F4, after a failed write or `fsync`, no further group is confirmed; the database must be reopened,
and recovery starts from the journal. The `fsync` is never retried.

*Proof.* `Engine.commit` catches the error, marks the engine stopped, fails the batch; `prepare` fails every later
request while stopped. Retrying an `fsync` after a failure could confirm data the kernel dropped (Rebello et al. 2020).

*Tested by* the simulation (failed fsyncs injected; a confirmation after one is a failure; the simulated disk drops
the dirty pages as Linux does).

## G11 Exact answers

*Promise.* A question returns exactly the bindings that make all its patterns facts of the view, each once.

*Proof.* See [theory](theory.md), Generic Join: every binding is built variable by variable from candidates that
satisfy every pattern on the variables bound so far, so every output is an answer; every answer's values are
candidates at each level (they satisfy the pattern used as a source and are accepted by the others), so every answer
is output; candidates at one level are distinct, so no answer comes twice.

*Tested by* `test/unit.ml`: 300 random databases and 15 random questions each (up to 3 patterns, constants, links,
ranges) compared with a naive evaluator over all facts, on a base with a delta and on a compacted base.
