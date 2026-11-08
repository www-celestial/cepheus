# Testing

How to test an application with forks, and how Cepheus itself is tested: what each test does, its options, and what
it proves.

## Testing your application with forks

A fork is a temporary database: the same reads, the same writes, the same checks as a real one, and nothing on disk.

```ocaml
open Cepheus

(* a fixture made once: a schema and one client *)
let fixture =
  let db = fork empty in
  let[@warning "-8"] (Ok [ name; status ]) = declare db [ prop "client/name" Ttext; prop "invoice/status" Ttext ] in
  ignore (write db [ Add (-1, name, Text "Ada") ]);
  view db, name, status

let () =
  let v, name, _ = fixture in
  (* each test forks the fixture: writes stay in the fork *)
  let t1 = fork v and t2 = fork v in
  ignore (write t1 [ Add (65536, name, Text "Ada Durand") ]);
  let show t = Value.to_string (List.hd (values (view t) 65536 name)) in
  Printf.printf "test 1 sees %s, test 2 sees %s\n" (show t1) (show t2)
```

```output
test 1 sees "Ada Durand", test 2 sees "Ada"
```

Forks are free to make, so make one per test. A fork of a fork works, so a fixture can be prepared once and forked by
each test. A what-if question is the same thing: fork, write the hypothesis, ask, drop the fork.

## How Cepheus is tested

`dune test` runs the unit and property tests, the exhaustive enumeration, 200 seeds of the simulation, and the
documentation's examples; `tools/test.sh` runs everything in the release build, the slow tests too. Every randomized
test draws from a seeded generator (`Rng`, SplitMix64), so a failure prints its seed and replays exactly.

| command | what it runs | options |
|---|---|---|
| `_build/default/test/unit.exe` | the unit and property tests | `CEPHEUS_TMP`: where its databases on the real disk go (the system's temp directory by default) |
| `exhaustive.exe` | every crash state of small journals and inside merges | none |
| `sim.exe` | the deterministic simulation | `--seeds N` (seeds 1 to N; 100 by default), `--seed S` (one seed), `--steps N` (steps a seed, 150) |
| `crash.exe DIR ROUNDS [SEED]` | real `kill -9` rounds on a database in DIR | SEED 42 by default |
| `bank.exe DIR SECONDS` | the bank test for SECONDS | |
| `examples.exe` | every ```` ```ocaml ```` block of `README.md` and `docs/*.md` (`test/extract.ml` makes the program), each in its own directory under `CEPHEUS_TMP`, its output compared with the ```` ```output ```` block under it | `CEPHEUS_TMP` |
| `tools/test.sh` | `dune build --profile release`, then unit, exhaustive, sim, crash, bank and examples | `CEPHEUS_TMP`, `SEEDS` (300), `KILLS` (20), `BANK_SECONDS` (2) |
| `tools/tlc.sh` | TLC on `spec/Journal.tla` and `spec/Merge.tla` | `TLA2TOOLS`: the path of `tla2tools.jar` |

**Deterministic simulation testing** runs the real engine on a simulated disk where one seed decides every event (the
writes, the order of the writer's steps, crashes, damage), so that a failure is not a rare accident but a seed that
replays it exactly; FoundationDB is tested this way (Zhou et al. 2021). **Exhaustive enumeration** goes further on
small cases: it lists every state the disk can be in after a crash and recovers each one, the method of the ALICE
study (Pillai et al. 2014) pushed to every case. **Property-based testing** (QuickCheck, Claessen and Hughes 2000)
checks a property on many random inputs against a reference model written independently.

1. **Unit and property tests** (`test/unit.ml`): CRC-32C against known values; codecs round trip on extreme values;
   a group cut at every byte never decodes; 300 random sequences of writes against a reference semantics written
   independently (a set of facts); 300 random databases × 15 random questions against a naive evaluator, each within
   the Generic Join bound computed from the facts alone (`Check.gj_bound`, against `Query.work`); costs: questions
   where one list is far larger than the answer, and lookups on a thing with 40,000 values, base and delta; a merge
   keeps every fact and every answer, and a merge of a base 8 times the cache holds at most a few pages open and never
   more resident pages than the cache; snapshots round trip, refuse another database's, set aside a damaged one; forks
   change nothing (files compared byte for byte) and accept what the database accepts; a second open is `Busy`; named
   cases (write skew refused, unique, one value, triangles).
2. **Exhaustive enumeration** (`test/exhaustive.ml`): for journals of a few frames, every crash state of the frame in
   flight (each subset of its sectors kept, each cut length, a tear inside the highest kept sector) must recover to
   exactly the right groups; every single bit of two journals flipped must be detected by a full read and handled by
   recovery as G6 says; a segment torn at its creation at any byte is dropped; and inside a merge (G12), at every
   mutating disk call of three kinds of merge (now; begun ahead of the disk and installed two frames later; those of a
   recovery replaying a long tail), every crash state: a process death then a power loss, and power losses keeping
   each prefix of each directory's name changes, with the unforced bytes lost, kept, torn or kept one sector in two
   (`Sim_disk.crash ~choose` makes the choices a power loss would draw): 393 crash points, 3,918 states.
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
death closes the files and keeps everything as it is. A failed fsync marks the pages clean without making them
durable.

## Not yet

Jepsen-style tests under network faults come with replication.

## Model checking

**TLA+** is a language for describing a system as a set of states and the steps between them, in mathematics
(Lamport 2002); a **model checker** visits every state a bounded model can reach and checks the invariants (the
properties that must hold) in each one. **TLC** is TLA+'s model checker (Yu, Manolios, Lamport 1999). Tests try the
cases someone thought of or a seed drew; TLC tries all of them, within its bounds, and prints the shortest sequence of
steps that breaks an invariant.

`spec/Journal.tla` models the journal protocol with the faults F1-F4: frames written one at a time and forced, a
crash that loses, keeps or tears the frame in flight, silent damage of a durable frame (in its body, or in its
header), a failed fsync; recovery with Cepheus' rules. Invariants: `Durable` (G1: an acknowledged frame survives,
unless recovery refused to open or it was itself damaged), `Prefix` (G3), `NoTornData` (G2: a torn frame is never
kept), `StopSafe` (G10), `ResidualBound` (G6: a cut loses only damaged frames). Run it with
`TLA2TOOLS=/path/to/tla2tools.jar tools/tlc.sh`; the jar is the official release (v1.7.4) from
https://github.com/tlaplus/tlaplus/releases, run by Java 11 or later. Bounds in `spec/Journal.cfg`: 7 frames, 3
damages: 1,084,801 distinct states, depth 27, 6.5 s on the test machine. TLC found one real trace (two damaged frames
at the end were both cut), fixed in `Journal.written_after`.

`spec/Merge.tla` models how a merge's file becomes the base (G12), with the journal abstracted to the groups written
and the groups durable, a process death (the page cache kept), a power loss (unforced bytes lost, a prefix of the
directory's name changes kept), a failed fsync, and the clean-close marker. Invariants: `NoMix` (no snapshot name points at content not whole
and forced), `SnapshotInJournal` (a snapshot name only for a durable group; recovery never meets one ahead of the
journal), `PublishedDurable` (G5, after a recovery too), `AckedDurable` (G1), `BaseNamed`. Bounds in `spec/Merge.cfg`
(5 groups, 2 snapshots kept): 3,808,506 distinct states, depth 43. Its four rules are constants: set any of
`ForceBeforeRename`, `InstallWhenDurable`, `ForceAtRecovery`, `MarkerOnlyIfClean` to FALSE and TLC prints a
counterexample of 7 steps.

## Further reading

Zhou et al., FoundationDB (SIGMOD 2021); Pillai et al., ALICE (OSDI 2014); Bornholt et al., lightweight formal methods
in Amazon S3 (SOSP 2021); Claessen and Hughes, QuickCheck (ICFP 2000); Lamport, Specifying Systems (2002); Yu,
Manolios, Lamport, TLC (CHARME 1999); Newcombe et al. (CACM 2015); Kingsbury and Alvaro, Elle (PVLDB 2020); Steele,
Lea, Flood, SplitMix (OOPSLA 2014). Entries: [references](references.md#testing-and-verification).
