# Testing

## Testing your application with forks

A fork is a temporary database: the same reads, the same writes, the same checks as a real one, and nothing on disk.

```ocaml
(* a unit test with no files at all *)
let db = Cepheus.fork Cepheus.empty in
let[@warning "-8"] Ok [ name; status ] =
  Cepheus.declare db [ Cepheus.prop "client/name" Ttext; Cepheus.prop "invoice/status" Ttext ] in
let r = Result.get_ok (Cepheus.write db [ Add (-1, name, Text "Ada") ]) in
assert (Cepheus.values (Cepheus.view db) (Cepheus.thing r (-1)) name = [ Text "Ada" ])

(* a test against a copy of real data: fork it, write freely, the database never changes *)
let t = Cepheus.fork (Cepheus.view prod) in
...
```

Forks are free to make, so make one per test. A fork of a fork works, so a fixture can be prepared once and forked by
each test. A what-if question is the same thing: fork, write the hypothesis, ask, drop the fork.

## How Cepheus is tested

`dune test` runs the first three; `tools/test.sh` runs everything (release build); set `CEPHEUS_TMP` for the scratch
databases. Every randomized test draws from a seeded generator (`Rng`, SplitMix64), so a failure replays exactly.

1. **Unit and property tests** (`test/unit.ml`): CRC-32C against known values; codecs round trip on extreme values;
   a group cut at every byte never decodes; 300 random sequences of writes against a reference semantics written
   independently (a set of facts); 300 random databases × 15 random questions against a naive evaluator, each within
   the Generic Join bound computed from the facts alone (`Check.gj_bound`, against `Query.work`); costs: questions
   where one list is far larger than the answer, and lookups on a thing with 40,000 values, base and delta; a merge
   keeps every fact and every answer, and a merge of a base 8 times the cache holds at most a few pages open and never
   more resident pages than the cache; views of up to 4 runs that add and retract give the facts and answers of their
   full merge; a large group's faster path gives the same encoding, thing numbers and facts as `Resolve`, or leaves
   the group to it; runs round trip, refuse another database's, set aside a damaged one; forks
   change nothing (files compared byte for byte) and accept what the database accepts; a second open is `Busy`; named
   cases (write skew refused, unique, one value, triangles).
2. **Exhaustive enumeration** (`test/exhaustive.ml`): for journals of a few frames, every crash state of the frame in
   flight (each subset of its sectors kept, each cut length, a tear inside the highest kept sector) must recover to
   exactly the right groups; every single bit of two journals flipped must be detected by a full read and handled by
   recovery as G6 says; a segment torn at its creation at any byte is dropped; and inside a merge (G12), at every
   mutating disk call of four kinds of merge (now, of every run; begun ahead of the disk and installed two frames
   later; a large group's, merged as it is prepared and named once its frame is durable; those of a recovery
   replaying a long tail), every crash state: a process death then a power loss, and power losses keeping each prefix
   of each directory's name changes, with the unforced bytes lost, kept, torn or kept one sector in two
   (`Sim_disk.crash ~choose` makes the choices a power loss would draw): 194 crash points, 1,944 states (the runs are
   small now: a merge of a few facts writes a few pages); and each fsync
   of a small run failing in turn (G13), on a file system that keeps the failed bytes in memory and on one that undoes
   them, then a process death at each of the next four disk calls or none, a reopen in the same boot or none, a power
   loss with each pattern, and a reopen: 2,880 reopens checked.
3. **Deterministic simulation** (`test/sim.ml --seeds N`): the engine runs on `Sim_disk`; the seed decides the writes,
   the interleaving of prepare and commit, snapshots, merges (now, or begun from a view ahead of the disk and
   installed steps later), forks, clean closes and reopens, power losses, process deaths (`Sim_disk.kill`: the page cache stays, to be lost at
   a later power loss), crashes inside any disk call (`Sim_disk.crash_after`), failed fsyncs, and bit flips in durable
   files. After every recovery the state is compared with the reference model, and the journal's groups with the
   written ones; the recovered state counts as confirmed (a later power loss must keep it); no snapshot may be set
   aside but a damaged one, no merge's file left; random questions on the published views must give the naive
   evaluator's answers within the Generic Join bound. `sim.exe --seed S` replays one seed.
4. **Real crashes** (`test/crash.exe DIR ROUNDS`): a child process writes with 8 threads and prints each confirmation,
   merging every 50 changes; the parent kills it with SIGKILL at a random moment (it counts the kills that land inside
   a merge), reopens, and checks every confirmed group's content, that no snapshot was set aside and no merge's file
   is left.
5. **Concurrency** (`test/bank.exe DIR SECONDS`): transfers with `Expect` from 16 threads, two reader domains checking
   that every view keeps the total and that views never go back.

What the simulated disk does (`src/sim_disk.ml`): it keeps, per file, the current and the durable content and the
sectors written since the last fsync; per directory, the name changes since its last sync. A power loss resolves each
unsynced sector at random (lost, kept, torn inside), picks a length between the durable and the current size, and keeps
a random prefix of each directory's name changes; a test may make each of those choices itself (`~choose`). A process
death closes the files and keeps everything as it is. A failed fsync does what the paper measured (Rebello et al.,
ATC 2020): the written sectors are marked clean without reaching the disk, their bytes kept in memory (ext4, XFS; the
new size made durable at random, as ext4 may) or undone (Btrfs, `Sim_disk.create ~reverts`); a later fsync writes
only the sectors written since, so a sector marked clean stays off the disk until it is written again or a power loss
resolves it. Until this was modelled, the simulated fsync copied every byte in memory to the disk, and the hole G13
closes went unseen.

## Not yet

Jepsen-style tests under network faults come with replication.

## Model checking

`spec/Journal.tla` models the journal protocol with the faults F1-F4, the page cache and the disk kept apart: frames
written one at a time and forced; a process death (the page cache stays) and a recovery that reads it; a power loss
that loses, keeps or tears every frame the disk may not hold; silent damage of a durable frame (in its body, or in its
header); a failed fsync that marks the pages clean, their bytes kept or undone in memory, a later fsync not writing
them; the writer's cut after it (forced, failed, or truncated without its fsync); recovery with Cepheus' rules,
writing its newest frame again. Invariants: `Durable` (G1: an acknowledged frame is in the file and on the disk,
unless recovery refused to open or it was itself damaged), `RefuseOnlyOnDamage`, `PublishedOnDisk` (G13: what
readers may see is on the disk), `Prefix` (G3), `NoTornData` (G2: a torn frame is never kept), `StopSafe` (G10),
`ResidualBound` (G6: a cut loses only damaged frames). Run it with
`TLA2TOOLS=/path/to/tla2tools.jar tools/tlc.sh`; the jar is the official release (v1.7.4) from
https://github.com/tlaplus/tlaplus/releases, run by Java 11 or later. Bounds in `spec/Journal.cfg`: 7 frames, 3
damages: 3,856,315 distinct states, depth 29, 20 s on the test machine. TLC found one real trace (two damaged frames
at the end were both cut), fixed in `Journal.written_after`. With `RewriteAtRecovery` FALSE it prints the trace of
G13 in 4 steps (write, failed fsync, death before the cut, recovery publishing the frame).

`spec/Merge.tla` models how a merge's file replaces runs (G12), with the journal abstracted to the groups written and
the groups durable: chains of runs named by their groups, merges of any number of the newest runs, recovery taking the
chain of named runs that reaches the newest group with the fewest runs; a process death (the page cache kept), a power
loss (unforced bytes lost, a prefix of the directory's name changes kept), a failed fsync (its frames marked clean),
the writer's cut, and the clean-close marker. Invariants: `NoMix` (no run name points at content not whole and
forced), `SnapshotInJournal` (a run name only for durable groups; recovery never meets one ahead of the journal),
`ChainNamed` (the runs a process reads are named and form a chain from 0), `PublishedDurable` (G5, after a recovery
too), `AckedDurable` (G1). Bounds in `spec/Merge.cfg` (3 groups: 6 possible runs): 983,080 distinct states, depth 51,
13 s; 4 groups did not end in 12 minutes. Its five rules are constants: set any of `ForceBeforeRename`,
`InstallWhenDurable`, `ForceAtRecovery`, `MarkerOnlyIfClean`, `RewriteAtRecovery` to FALSE and TLC prints a
counterexample of 4 or 5 steps.
