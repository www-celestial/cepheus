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
| `reasoning.exe` | the rules: named cases, then G17, G18 and G20 on random sequences (random rules defined, changed and removed; random additions and retractions) against the least model from scratch, plain and over merged runs | `RULES_SEEDS` (60), `RULES_SEED` (one seed, printed group by group) |
| `exhaustive.exe` | every crash state of small journals and inside merges | none |
| `sim.exe` | the deterministic simulation | `--seeds N` (seeds 1 to N; 100 by default), `--seed S` (one seed), `--steps N` (steps a seed, 150) |
| `crash.exe DIR ROUNDS [SEED]` | real `kill -9` rounds on a database in DIR | SEED 42 by default |
| `bank.exe DIR SECONDS` | the bank test for SECONDS | |
| `seats.exe DIR ROUNDS [SEED] [naive\|expect] [SEATS]` | the sale of seats with kill -9 and a checker of the history ([case](case-seats.md#real-crashes-and-a-checker-of-the-whole-history)); `ROUNDS` 0: no kill, the time to sell out | `BUYERS` (16), SEED 42, SEATS 2,000 |
| `examples.exe` | every ```` ```ocaml ```` block of `README.md` and `docs/*.md` (`test/extract.ml` makes the program), each in its own directory under `CEPHEUS_TMP`, its output compared with the ```` ```output ```` block under it | `CEPHEUS_TMP` |
| `tools/test.sh` | `dune build --profile release`, then unit, reasoning, exhaustive, sim, crash, bank, seats and examples | `CEPHEUS_TMP`, `SEEDS` (300), `KILLS` (20), `BANK_SECONDS` (2), `SEAT_KILLS` (20) |
| `tools/tlc.sh` | TLC on `spec/Journal.tla`, `spec/Merge.tla` and `spec/Seats.tla`, and the naive sale (`spec/SeatsNaive.cfg`), which must break an invariant | `TLA2TOOLS`: the path of `tla2tools.jar` |

**Deterministic simulation testing** runs the real engine on a simulated disk where one seed decides every event (the
writes, the order of the writer's steps, crashes, damage), so that a failure is not a rare accident but a seed that
replays it exactly; FoundationDB is tested this way (Zhou et al. 2021). **Exhaustive enumeration** goes further on
small cases: it lists every state the disk can be in after a crash and recovers each one, the method of the ALICE
study (Pillai et al. 2014) pushed to every case. **Property-based testing** (QuickCheck, Claessen and Hughes 2000)
checks a property on many random inputs against a reference model written independently.

1. **Unit and property tests** (`test/unit.ml`): CRC-32C against the check value and the five examples of RFC 3720
   (appendix B.4), and against an oracle, the table code in OCaml it replaced: every length up to 72 bytes at every
   offset up to 15, 5,000 random lengths up to 1 MiB at random offsets, the edges of its 1 MiB pieces up to 3 MiB,
   each one whole and `extend`ed over random cuts in two and three, and the bounds refused (an offset plus a length
   that overflows too); codecs round trip on extreme values;
   a group cut at every byte never decodes; 300 random sequences of writes against a reference semantics written
   independently (a set of facts); 300 random databases × 15 random questions against a naive evaluator, each within
   the Generic Join bound computed from the facts alone (`Check.gj_bound`, against `Query.work`); costs: questions
   where one list is far larger than the answer, and lookups on a thing with 40,000 values, base and delta; a merge
   keeps every fact and every answer, and a merge of a run 8 times the cache holds at most a few pages open (7 measured) and never
   more resident pages than the cache; views of up to 4 runs that add and retract give the facts and answers of their
   full merge; a large group's sorts by thing and by property equal a reference sort (300 seeds, chunks of 1 to 50,
   values at the ends of the integers); a large group's faster path gives the same encoding (byte for byte, and its
   computed length), thing numbers and facts as `Resolve`, or leaves the group to it, with chunks of 1 to 9 operations,
   temporary ids far below the group's length, and groups in no order and in thing order, each kind taken at least
   once; runs round trip, refuse another database's, set aside a damaged one; forks
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
   loss with each pattern, and a reopen: 2,880 reopens checked. The journal is read through a window of 48 bytes
   here (4 MiB in use): every frame is longer than it, checked by pieces or read whole, and every header and trailer
   can straddle its edge.
3. **Deterministic simulation** (`test/sim.ml --seeds N`): the engine runs on `Sim_disk`; the seed decides the writes,
   the interleaving of prepare and commit, snapshots, merges (now, or begun from a view ahead of the disk and
   installed steps later), forks, clean closes and reopens (half the seeds read the journal through a window of 40
   to 240 bytes), power losses, process deaths (`Sim_disk.kill`: the page cache stays, to be lost at
   a later power loss), crashes inside any disk call (`Sim_disk.crash_after`), failed fsyncs, and bit flips in durable
   files. After every recovery the state is compared with the reference model, and the journal's groups with the
   written ones; the recovered state counts as confirmed (a later power loss must keep it); no run may be set
   aside but a damaged one, no merge's file left; random questions on the published views must give the naive
   evaluator's answers within the Generic Join bound. `sim.exe --seed S` replays one seed.
4. **Real crashes** (`test/crash.exe DIR ROUNDS`): a child process writes with 8 threads and prints each confirmation,
   merging every 50 changes, while a ninth thread loads large groups (150 new things, 300 additions, taking the path of
   large groups from 200 operations here, in chunks of 64, their frames written by pieces beside their merges on two
   domains and forced every 2 KB); the parent kills it with SIGKILL at a random moment (it counts the kills that land
   inside a merge), reopens, and checks every confirmed group's content (a large group's first and last things), that
   no run was set aside and no merge's file is left.
5. **Concurrency** (`test/bank.exe DIR SECONDS`): transfers with `Expect` from 16 threads, two reader domains checking
   that every view keeps the total and that views never go back.
6. **A sale of seats under kill -9, with a checker of the history** (`test/seats.exe DIR ROUNDS`): 16 buyers sell 2,000
   seats with `Expect` in a child that is killed at random moments; the checker reads the journal and verifies every
   confirmed sale, at most one charge a seat, no charge without the seat, and no cycle in the dependency graph of the
   sales, in the spirit of Elle (Kingsbury and Alvaro 2020). The [case](case-seats.md) tells it.

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

### The C file, fuzzed

`src/crc32c_stubs.c` is the only C of Cepheus. Besides the property test above, which runs it through OCaml, it is
**fuzzed** on its own (`test/fuzz_crc32c.c`, not part of dune's build): libFuzzer (LLVM's fuzzer) feeds it inputs it
mutates to reach new paths, under AddressSanitizer (a read outside the bytes stops the run) and
UndefinedBehaviorSanitizer; each input is a CRC to extend from, an offset, a length, a cut and the bytes, kept within
the bytes as `Crc32c` checks before every call, and the result is compared with the definition computed bit by bit,
whole and cut in two. Run it with clang:

```
clang -g -O1 -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=all -I "$(ocamlfind ocamlc -where)" \
  test/fuzz_crc32c.c src/crc32c_stubs.c -o fuzz_crc32c && ./fuzz_crc32c -max_len=65536 -max_total_time=300
```

On the test machine (2026-11-08, clang 23.1.4): 90,126,874 inputs in 301 s, then 38,048,578 in 121 s with long
inputs from the start (`-len_control=0`), then 28,944,296 in 121 s from inputs of 1 to 64 KiB, then 632,422 in 61 s
kept at up to 64 KiB (`-reduce_inputs=0 -shrink=0`): no failure. Two broken copies of the file, one reading a byte
past the end and one wrong on a 3-byte tail, were caught in under a second each: the harness can fail. The tests and
the fuzzing ran on x86-64; the arm64 code (`crc32cx`, `crc32cb`, the check by `getauxval`) was compiled for arm64
(clang 23, `--target=aarch64-linux-gnu`) but has not yet run on an arm64 processor.

## Not yet

Jepsen-style tests under network faults come with replication.

## Model checking

**TLA+** is a language for describing a system as a set of states and the steps between them, in mathematics
(Lamport 2002); a **model checker** visits every state a bounded model can reach and checks the invariants (the
properties that must hold) in each one. **TLC** is TLA+'s model checker (Yu, Manolios, Lamport 1999). Tests try the
cases someone thought of or a seed drew; TLC tries all of them, within its bounds, and prints the shortest sequence of
steps that breaks an invariant.

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

`spec/Seats.tla` models the sale of seats of the [case](case-seats.md): buyers that read a view and pick a free seat,
groups applied one at a time with or without `Expect (seat, owner, None)`, crashes; invariants `NoDoubleSale` and
`NoChargeWithoutSeat`. With the `Expect` (`spec/Seats.cfg`, 4 buyers, 3 seats) they hold in all 8,449 states; without
it (`spec/SeatsNaive.cfg`, 3 buyers, 2 seats) TLC prints a counterexample of 4 steps, and `tools/tlc.sh` fails unless it
does.

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

## Further reading

Zhou et al., FoundationDB (SIGMOD 2021); Pillai et al., ALICE (OSDI 2014); Bornholt et al., lightweight formal methods
in Amazon S3 (SOSP 2021); Claessen and Hughes, QuickCheck (ICFP 2000); Lamport, Specifying Systems (2002); Yu,
Manolios, Lamport, TLC (CHARME 1999); Newcombe et al. (CACM 2015); Kingsbury and Alvaro, Elle (PVLDB 2020); Steele,
Lea, Flood, SplitMix (OOPSLA 2014). Entries: [references](references.md#testing-and-verification).
