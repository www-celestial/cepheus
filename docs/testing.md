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
   independently (a set of facts); 300 random databases × 15 random questions against a naive evaluator; compaction
   keeps every fact and every answer; snapshots round trip, refuse another database's, set aside a damaged one; forks
   change nothing (files compared byte for byte) and accept what the database accepts; a second open is `Busy`; named
   cases (write skew refused, unique, one value, triangles).
2. **Exhaustive enumeration** (`test/exhaustive.ml`): for journals of a few frames, every crash state of the frame in
   flight (each subset of its sectors kept, each cut length, a tear inside the highest kept sector) must recover to
   exactly the right groups; every single bit of two journals flipped must be detected by a full read and handled by
   recovery as G6 says; a segment torn at its creation at any byte is dropped.
3. **Deterministic simulation** (`test/sim.ml --seeds N`): the engine runs on `Sim_disk`; the seed decides the writes,
   the interleaving of prepare and commit, snapshots, compactions, forks, power losses, crashes inside any disk call
   (`Sim_disk.crash_after`), failed fsyncs, and bit flips in durable files. After every recovery the state is compared
   with the reference model, and the journal's groups with the written ones. `sim.exe --seed S` replays one seed.
4. **Real crashes** (`test/crash.exe DIR ROUNDS`): a child process writes with 8 threads and prints each confirmation;
   the parent kills it with SIGKILL at a random moment, reopens, and checks every confirmed group's content.
5. **Concurrency** (`test/bank.exe DIR SECONDS`): transfers with `Expect` from 16 threads, two reader domains checking
   that every view keeps the total and that views never go back.

What the simulated disk does (`src/sim_disk.ml`): it keeps, per file, the current and the durable content and the
sectors written since the last fsync; per directory, the name changes since its last sync. A power loss resolves each
unsynced sector at random (lost, kept, torn inside), picks a length between the durable and the current size, and keeps
a random prefix of each directory's name changes. A failed fsync marks the pages clean without making them durable.

## Not yet

A model of the journal protocol in TLA+ is in `spec/Journal.tla`, ready for the TLC model checker (not run yet: the
tools are not installed). Jepsen-style tests under network faults come with replication.
