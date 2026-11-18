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
| `reasoning.exe` | the rules: named cases (closures of both shapes and their budget, a variable property, `sources`; a change's sinks, the facts no rule reads: their sort against a stable sort of 300 random buffers, a sink over siblings on a fork, with morsels, deduplicated after every head, and on the disk with a run of its own, reopened; a sink past the budget refused, naming its rule), then G17, G18 and G20 on random sequences (random rules defined, changed and removed, transitive closures and rules over a variable property among them; random additions and retractions) against the least model from scratch, plain and over merged runs, and the plain ones again with rounds on several domains (from 4 facts a round) and with the rules always as written, every group's view equal to the first run's; and half the seeds on databases on the disk, where every change of the rules takes the background path, with the model's decisions and the database reopened the same; and again with a change's sink heads deduplicated every 3 heads, on forks and on the disk; then groups of additions from 2 facts on databases on the disk, so that the path of loads reasons on its sorted prefix (rules without `Not` or aggregates, constraints and one-valued heads among them; facts derived already asserted again; new things), against the model, and again with rounds on several domains | `RULES_SEEDS` (60), `RULES_SEED` (one seed, printed group by group), `RULES_PROGRESS` (a line a seed) |
| `owl.exe` | OWL 2 RL (`Cepheus.Owl`): each of the W3C's 78 rules by a case where it fires or its constraint refuses, on five paths (a fork group by group; the rules always as written; the data before the ontology, so that the ontology's group is a change of the rules and of the templates' lists; a load on the disk, on the path of large groups; a database on the disk, the ontology after the data, by the background path), each view compared with the meaning of the rules computed from scratch (`Check.least`, templates by their meaning; with equality `Check.least_eq`: a union-find, the facts rewritten each pass, the view read through its classes), then the data retracted and written again, the ontology retracted; the datatypes; random ontologies and data (also with the rules as written); random equalities (sameAs, functional, inverse functional, keys, max cardinality 1, differentFrom; a refusal must be the meaning's contradiction, an acceptance its absence); an equality storm (3,000 things made one: 2,999 facts of `cepheus/same`, past a small budget refused whole); every database on the disk closed and opened again, the same facts; the facts written stay asserted, where they were written | `OWL_SEEDS` (200, in `tools/test.sh`), `OWL_SEED` (one random equality seed, printed step by step) |
| `rulechange.exe` | the background path of rule changes on databases on the disk: groups written while a change is held after its build (`Engine.change_pause`), caught up exactly; a group that writes the change's fact, breaks its new constraint or takes its rule's number ends it with `Conflict`; 6 writers, 24 changes and 2 readers checking every view against the least model under its own rules, then the database reopened; the change budget (a cross product refused while a writer goes on) and an ontology change past a data budget accepted the same on the disk and on a fork; close during a change; a change with an `Incr` in its group, computed in its group beside groups that count with the same counter; a Raft member (its frames proposed to a function that records them or refuses one): the change's frame proposed, a frame taken back or another leader's frame answering the change `not_leader`, the journal reopened the same; kill -9 during changes, each recovered view exact | `CHANGE_KILLS` (10, in `tools/test.sh`) |
| `exhaustive.exe` | every crash state of small journals, inside merges, and of two databases sharing a commit buffer | none |
| `sim.exe` | the deterministic simulation | `--seeds N` (seeds 1 to N; 100 by default), `--seed S` (one seed), `--steps N` (steps a seed, 150) |
| `wal_sim.exe` | the deterministic simulation of the server's commit buffer: three databases sharing it ([below](#the-commit-buffer)) | `--seeds N` (100 by default), `--seed S`, `--steps N` (200); `WAL_SIM_TRACE` set: each event of a seed on the standard error |
| `crash.exe DIR ROUNDS [SEED]` | real `kill -9` rounds on a database in DIR | SEED 42 by default |
| `bank.exe DIR SECONDS` | the bank test for SECONDS | |
| `seats.exe DIR ROUNDS [SEED] [naive\|expect] [SEATS]` | the sale of seats with kill -9 and a checker of the history ([case](case-seats.md#real-crashes-and-a-checker-of-the-whole-history)); `ROUNDS` 0: no kill, the time to sell out | `BUYERS` (16), SEED 42, SEATS 2,000 |
| `examples.exe` | every ```` ```ocaml ```` block of `README.md` and `docs/book/*.md` (`test/extract.ml` makes the program), each in its own directory under `CEPHEUS_TMP`, its output compared with the ```` ```output ```` block under it | `CEPHEUS_TMP` |
| `tools/test.sh` | `dune build --profile release`, then unit, reasoning, exhaustive, sim, wal_sim, crash, bank, seats and examples, the server's tests, and the Cesia client's when a Cesia with its native interface is here | `CEPHEUS_TMP` (a short path: a Unix socket's holds 107 bytes), `SEEDS` (300), `BUFFER_SEEDS` (300), `KILLS` (20), `BANK_SECONDS` (2), `SEAT_KILLS` (20), `CESIA_NATIVE` (the folder of Cesia's `cesia_v1.cmi`; found from the `cesia` command when unset) |
| `tools/tlc.sh` | TLC on every model of `spec/` (the journal, merges, the sale of seats, local reads, watches, the commit buffer, a rule change's background path), and every variant that must break an invariant ([model checking](#model-checking)) | `TLA2TOOLS`: the path of `tla2tools.jar` |

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
   that overflows too); codecs round trip on extreme values; bit packing: 300 rounds of fields of every width from 0 to
   63 at every position, written and read back against a bit-by-bit reference, with and without room after the last
   field (the byte-by-byte path); 300 columns of up to 400 ints of every shape (random, steady, the ends of the
   integers, constant, decreasing) read back; 400 random groups (every kind and constructor, extreme ints, floats nan
   and -0, empty and binary texts, up to 600 changes, a fact twice) read back in format 2, and in format 1 by its
   reader, and a group cut at every byte never decodes; a journal of format 1 (written by the test's own coder in two
   segments, with or without a torn tail, a leftover `.seg.tmp`) converted at open to the same facts, a second
   conversion finding nothing, a damaged frame of format 1 in the older segment refused (30 seeds); an open after a
   snapshot reading 80 bytes of a journal of more than 60 KB (the two looks at its header) through a disk that counts; a snapshot
   with merges turned off (`compact_min` at `max_int`) that ends; 300 random sequences of writes against a reference semantics written
   independently (a set of facts); `Incr` (groups that number invoices from one counter, some refused: the accepted
   ones numbered 1 to n, no gap, no number twice, the same after a power loss; two in one group; to the largest int
   and past it, past the smallest; every wrong type, kind and thing refused, the counter left as it was); 300 random databases × 15 random questions against a naive evaluator, each within
   the Generic Join bound computed from the facts alone (`Check.gj_bound`, against `Query.work`; the leapfrog's slices
   counted where it may read them); costs: questions
   where one list is far larger than the answer, and lookups on a thing with 40,000 values, base and delta; a merge
   keeps every fact and every answer, and a merge of a run 8 times the cache (its pages in the file, 120,000 things)
   holds at most a few pages open (19 measured, bound 24: the 18 streams of the pass by property, and the column order's) and never more
   resident pages than the cache; a run many times the 16-page cache (6,000 things with names of 60 random letters:
   compressed, it must still pass the cache) read by questions on 3 domains, a bit flipped in a page of the file (any
   page, or an interior page of the rows by property found through the page table): refused at open or failing every
   read of that page, never a wrong answer; views of up to 4 runs that add and retract give the facts and answers of their
   full merge; a large group's sorts by thing and by property equal a reference sort (300 seeds, chunks of 1 to 50,
   values at the ends of the integers); a large group's faster path gives the same coding (byte for byte: its arrays
   coded by the same function as the group `Resolve` makes), thing numbers and facts as `Resolve`, or leaves the group to it, with chunks of 1 to 9 operations,
   temporary ids far below the group's length, and groups in no order and in thing order, each kind taken at least
   once; runs round trip, refuse another database's, set aside a damaged one and one of format 7; a run of 600 pages
   and more on the real disk, checked at open by several domains, round trips, and is set aside with one byte of a
   page flipped; forks
   change nothing (files compared byte for byte) and accept what the database accepts; a second open is `Busy`; named
   cases (write skew refused, unique, one value, triangles).
2. **Exhaustive enumeration** (`test/exhaustive.ml`): for journals of a few frames, every crash state of the frame in
   flight (each subset of its sectors kept, each cut length, a tear inside the highest kept sector) must recover to
   exactly the right groups (the frame counts when its header and body reached the disk and the file reaches its end:
   a torn trailer alone is rebuilt, G6; format 2's shorter frames put a sector boundary between a body and its
   trailer, a case the oracle missed before); every single bit of two journals flipped must be detected by a full read and handled by
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
   merging every 50 changes, while a ninth thread loads large groups (150 new things, 450 additions, taking the path of
   large groups from 200 operations here, in chunks of 64, their frames written by pieces beside their merges on two
   domains and forced every 2 KB; a rule derives a fact from each loaded thing's, so that the path of loads reasons
   on its sorted prefix); the parent kills it with SIGKILL at a random moment (it counts the kills that land inside a
   merge, and those before the child's declare is durable: then no group may be confirmed, and the properties come
   back all together or not at all), reopens, and checks every confirmed group's content (a large group's first and
   last things), every load there whole with each thing's derived fact or not there at all, that no run was set aside
   and no merge's file is left.
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

`src/crc32c_stubs.c` is the engine's only C (the server's is `server/tls_stubs.c`, below). Besides the property test above, which runs it through OCaml, it is
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

### The server

- `server_unit`: TOML, every rule of `cluster.toml`, tokens (base64url against RFC 4648's vectors, the hash, the
  constant-time comparison, `tokens.toml` written and read back), the wire (5,000 random requests coded and decoded,
  every cut of their bodies refused; every reply; a count larger than its bytes refused before anything is
  allocated; `Incr` round trips, and Writes with it fuzzed: every byte changed, cuts, bytes inserted, huge numbers,
  read or refused, never more), origins, the session table and its checkpoint (a damaged one refused), and the rights of every token
  against every request on every database through the server's core (G16, `Follow` with them), a token removed or
  narrowed, a forged origin, a frame over the limit; and what local readers need from the system: descriptors passed
  over a socket (400 random messages of 1 to 6,000 bytes with up to 8 descriptors, read in random pieces: the bytes
  and the files come out in order, each a new descriptor of the same open file, none left open; more than 64
  refused) and the visibility page (a store seen at once through the read-only mapping, one mapping a file, a
  second server of the same database refused); and a follower of a database with a rule, from its run and its
  journal, holds exactly the engine's facts and which of them are asserted, at its start and after it rests on a new
  base (the derived facts come with their kind, in the run's flag and the frames' kinds, and are applied as replay
  applies them, never evaluated).
- `server_sim`: the deterministic simulation of the server over a simulated network, on the simulated disk: clients
  of every right, pipelined, their bytes cut at any byte and delivered late, connections broken (the unanswered
  writes sent again with their serials), the writer's batches, merges, checkpoints, server deaths and power losses
  at any disk call, failed fsyncs, clean stops, damaged checkpoints. Checked: G1 to G5, G10, G11 through the protocol,
  G14 (each session and serial in one group at most, every receipt naming it and its new things), G16. Two bugs it
  found are in the server's history: a test that did not force a directory's name, and a refused write applied after
  a later one when sent again (now answered with its first error). Local readers (G15) follow the database through
  the real fan-out and follower code (`Follow`, `Follower`), their events taken by the server's sender and applied
  by the reader at moments the seed draws (a reader paused, slow, killed and started again), their streams cut when
  the server dies (what was sent stays readable), the visibility page kept by a server's death and reset by a power
  loss; in some seeds every group of two to four operations is a large group (a run of its own, passed before its
  frame is durable). Every read, local or remote, is checked when it returns: it holds every group answered to any
  client before it started (Fresh), every group any read returned before it started (Ordered), and it is the model's
  state at its group, durable (Durable): G15, with G5 and G13 for readers. The first runs found one bug of the test
  (a large group's body, written by pieces, decoded from the empty batch buffer).
- `server_crash`: a real `cepheus serve` of two databases (their journals forced through its commit buffer, rounds
  of both), killed 20 times (kill -9) under four clients writing through the Unix socket, half to each database; at
  the end every acknowledged write is in its database once and no write twice (G1, G14); meanwhile two
  readers read in their own memory, and every read, local or at the server while a follower is made again, holds
  every write answered and every state returned before it started (G15 with the real clock: millions of reads); a
  second server on the same data is refused (G9), `cepheus status`, a token removed while its program is connected
  (refused within the reload, its local reads too: the stream ends), `cepheus stop`.
- `server_tls`: a real server with TLS: a client of the cluster's CA reads; another cluster's CA, a certificate that
  does not name the host, another cluster id, a TCP client without a CA and a plain client on the TLS port are all
  refused, and the server goes on; TCP without `[tls]` is refused at start.
- `server_limits`: a real server with `max_connections = 3` and `idle_timeout = 1`: with three connections open, a
  fourth over the Unix socket gets `too_many_connections` and one over TCP is closed before any byte; a silent
  connection, one that trickles a byte at a time without a request, and one that stops in its TLS handshake are
  closed within twice the limit (the first two after `idle`); a client that pings more often stays; a client idle
  past the limit reads again, its library connecting again by itself.
- `server_guard`: connections served by the server's own code over real sockets, on a database whose reads raise
  when the test says (a bug of a request): a request that raises on a connection with a watch and a write in flight
  (the write answered, the request `internal`, the connection closed), 200 such connections in a row, and a failure
  in another thread of a connection while it waits in a read, over a Unix socket and over TCP (`internal` on id 0, no
  request answered after it); after each, the process's descriptors and threads are what they were, no connection or
  watch is left, and a new connection is served.
- Every server these tests start runs in a session of its own (`setsid`) with its output in a `serve.log` beside its
  `cluster.toml`, and is stopped when its test ends, even when the test fails (`test/serve.ml`); the tests ignore
  SIGPIPE, so that a write to a connection the server closed is an error, not the death of the test.

### The commit buffer

- `wal_sim`: three databases on one simulated disk share one commit buffer (`src/wal.ml`), whose files alternate
  after 300 to 3,300 bytes, their journals' segments 600 to 4,600 bytes long. One seed decides every event: the
  writes of each database (some of them large groups, forced in their own journal; some frames longer than the
  buffer takes, forced there too), when each frame reaches its journal and the buffer, the rounds, the cleanings of
  the file that is not active, merges, process deaths (the page cache kept, lost at a later power loss), power losses,
  crashes inside any disk call, recovery's too, and failed fsyncs, of the buffer's file or of a journal, as the
  simulation's disk does them (G13). After every recovery: every confirmed group of every database is there (G1),
  each journal holds exactly the groups written, in order (G2, G3), what a recovery published survives the next crash
  (G5), no open refuses but at a frame or a round no fsync confirmed whose header's sector alone was lost (G6), no
  write is confirmed after a failed fsync (G10). A database opened alone after a crash must be refused, and opened
  after a clean stop; and now and then a version without the buffer opens a database after a crash and writes to it:
  the server's next start must refuse that database, never write over its frames. Half the seeds force a frame that comes when the buffer is idle in its own journal
  (`Wal.alone`). In `tools/test.sh` (300 seeds, 2026-11-12): 29,771 groups confirmed, 12,968 rounds (950 of several
  databases), 1,726 power losses, 1,044 process deaths, 1,476 crashes inside a disk call and 607 inside a recovery,
  6,838 `Io` errors, 4,598 opens alone refused and 601 allowed after a clean stop, 155 databases written by a version
  without the buffer (12 of them refused at the next start, the others had lost nothing); one false alarm of G6 (a
  round no fsync confirmed, its header's sector lost alone); no failure.
- `exhaustive.exe`, part 6: two databases share a buffer whose files alternate after 500 bytes, their segments 1,500
  bytes long, in a fixed run, every frame through the buffer (rounds of one database and of both, long frames forced in their own journal, a segment
  left, switches of file, a cleaning, a switch over the cleaned file). At each of its 50 mutating disk calls: a
  process death (then a power loss after the recovery), and power losses keeping each prefix of each directory's name
  changes, with the unforced bytes lost, kept, torn, or kept one sector in two; then each of its 13 fsyncs failing in
  turn, followed by a process death, a clean stop or neither, a reopen in the same boot or none, and a power loss
  keeping all or none: 556 crash states and 156 states after a failed fsync, every confirmed group there, no false
  alarm.
- Mutation checks (a part of the rule removed, to see the tests fail; failed checks in 300 seeds of `wal_sim`, every
  frame through the buffer then, and in the exhaustive part 6): recovery trusting each journal's own rule (no frame written again), 1,914 in 298 seeds,
  and 185; the cleaning without its checkpoint, 11 in 11 seeds, and 34; a run named without forcing its journal
  first, 316 in 80 seeds, and none; a segment left without forcing it, 584 in 104 seeds, and none; a frame skipped
  when the page cache already shows it, 1 (seed 113), and 2. The first version of
  the recovery skipped a frame whose bytes the page cache already showed: after a failed fsync (pages marked clean)
  and a reopen in the same boot, the buffer was emptied while the disk lacked the frame, and a power loss lost it.
  `wal_sim` found it (seed 113 of 300); the exhaustive part did not, because it always lost power before the reopen;
  it now reopens in the same boot too, and with the skip put back fails twice. A clean close after a checkpoint
  failed in the buffer's thread left the `closed` marker; it no longer does (`Journal.forced`), though no test tells
  the two apart: the frames are written again at the start all the same.

### The Cesia client

- `cesia test cesia/tests`, on both of Cesia's paths (`--no-spec` too): every function of the package on forks of
  `cepheus.Empty`, with no server ([Cesia](cesia.md#tests)): types of values, joins, aggregates, ranges, many
  values, `Expect`, new things of a group, `Incr` (30 fibers numbered 1 to 30; a refused group, a negative `by`, past
  the ints, the wrong types), `unique`, `Update`, the mistakes that are errors, a fork that never changes its origin,
  `Close`.
- `test/cesia.sh`: a project of its own holds the package in `deps/` as `cesia pkg` puts it (its engine, its
  `cesia.lock`); a real server; then every example of [Cepheus from Cesia](cesia.md) runs, block by block with the
  blocks before it, on a database of its own, and what it prints must be the text under it (`test/cesia-docs.ce`);
  `test/cesia-live.ce` over TLS and through the Unix socket (200 writes by one connection each read at once by another,
  local: G15 through the package; 100 and 200 fibers on one connection; 50 fibers numbered by one `Incr` counter, 1 to
  50 once each; a fork; `Close`), its output against
  `test/cesia-live.expected`; and the server killed with `kill -9` and started again while 10 fibers write 1,500
  invoices: every write answered `Ok`, each in the database once (G14 through the package).

### The server's C, fuzzed

`server/tls_stubs.c` is in two parts: a core of plain C on OpenSSL, with no OCaml value (contexts, a connection on
memory buffers, its handshake steps, the bytes fed in and taken out, plain reads and writes, the peer's name, the
cluster's certificates), and thin wrappers that convert OCaml's values and raise its errors (`server/tls.ml` checks
every offset and length, and refuses a string with a NUL byte, before any call). The core is **fuzzed** on its own
(`test/fuzz_tls.c`, not part of dune's build) under libFuzzer, AddressSanitizer and UndefinedBehaviorSanitizer; at
start the harness makes a CA, a server's certificate for 127.0.0.1 and a client's with the core's own
`cph_tls_make_cert`, and the first byte of each input chooses what the rest drives:

- a server's connection fed the input as a client's bytes, in pieces whose sizes the input gives;
- a client's connection (the CA and the host checked) fed the input as a server's bytes;
- a client and a server talking through memory: the input says, step by step, which side takes a handshake step,
  moves a piece of its output to the other (with at most one byte of the conversation changed on the way), writes
  plain bytes, or reads them in pieces of a given size. Checked at every read: what a side reads is a prefix of what
  the other wrote (TLS authenticates every record, so a changed byte is never read as data); at the end, when nothing
  was changed, both handshakes have ended, each side has read everything the other wrote, each side names the
  other's certificate, and a close_notify ends the other side's stream;
- a certificate signed by the CA for a common name and a subjectAltName taken from the input, which must verify.

The seeds are a ClientHello captured from `openssl s_client`, a server's first flight from `openssl s_server` with
the test certificates, and whole conversations. Run it with clang:

```
clang -g -O1 -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=all -DCEPHEUS_TLS_CORE_ONLY \
  test/fuzz_tls.c server/tls_stubs.c -lssl -lcrypto -o fuzz_tls && ./fuzz_tls -max_len=16384 -max_total_time=300
```

On the test machine (2026-11-08, clang 23.1.4, OpenSSL 3.6.5): 62,439 inputs in 301 s from the seeds and the corpus,
then 17,445 in 121 s with inputs kept long (`-reduce_inputs=0 -shrink=0 -len_control=0`), about 200 a second (most
inputs make a handshake: milliseconds of key exchange and signatures): no failure. A first run stopped on a bug of the
harness itself (its last loop gave up after 64 rounds of 16 KiB, while an input can write 40 MB); fixed, it ends when
a round moves nothing. Two broken copies of the core were caught in under a minute each: one that says it read one
byte more than it gave (a read past what the peer wrote), one that gives OpenSSL one byte less than it received (a
handshake that never ends).

`server/fdpass_stubs.c` (descriptors passed for local reads, and the read-only mapping of the visibility page) is
property-tested through OCaml in `server_unit`: 400 random messages of 1 to 6,000 bytes with 0 to 8 descriptors,
read in random pieces: the bytes and the files come out in order, each a new descriptor of the same open file, none
left open; more than 64 descriptors are refused; the page shows the server's store at once.

### The file vault

`test/vault_unit.exe` checks the vault ([the vault](vault.md)):

- its C: LZ4 and Zstandard blocks of 0 to 256 KiB round trip (300 seeds, text and random bytes), refuse an output one
  byte short or long and a cut block; keyed BLAKE2b-256 and the key derivation against Python's `hashlib` (an
  implementation of its own); AEGIS-256 refuses any changed bit, key, nonce, associated byte or cut (200 seeds);
- the chunker: every chunk within 16 and 256 KiB, a mean within 10 % of the formula's 73 KiB, 97 % of an edited
  copy's bytes found again (fixed chunks: under 30 %);
- the store: files of 0 bytes to 9 MB at the chunker's bounds, warm and cold, written in random pieces, read whole and
  in 25 random ranges each; the same file twice writes nothing; an edited copy writes only the chunks near the edit;
  another domain shares nothing; reopened from the indexes and, every index removed, from the packs;
- **power losses** on the simulated disk: 120 seeds, three crashes each at a random call of puts of up to 3 MB (some
  sharing chunks, some cold, an erasure), with sectors lost, kept or torn as a power loss leaves them: the vault opens
  every time, and every file finished before a crash reads back exact (G22);
- **group commit**: four threads put files at once on the simulated disk (one call at a time, the threads
  interleaved at each, an fsync lasting while the others run, packs closed while another thread forces them), cut
  by a power loss at a random moment, 40 seeds: every file confirmed before it reads back, with fewer fsyncs than
  puts;
- **a kill, then a power loss**: a process killed in the middle of a put of 6 MB (its chunks in the page cache, not
  forced), the vault opened again, the file put again (its chunks found stored), then a power loss: it reads back,
  30 seeds;
- **damage**: a byte changed in a chunk gives `damaged` for the ranges over it and only those, the same file put
  again repairs it; a record moved over another is refused (G23);
- **erasure**: an erased domain's files give `erased` (one read twice before, the second time from the caches, too),
  after a reopen too, its sealed key is gone from the keys' file, no new file names it (G24);
- **copies**: the records one vault lacks by Merkle comparison are exactly the set difference, found with fewer
  digests than records; copied, the copy reads every file and has the same root; an erasure follows the keys;
- a **fuzzed reader**: 20,000 records changed at random (bytes, cuts, fields with their CRCs made again, headers)
  give the right bytes or an error, nothing else; 20,000 nodes changed at random parse within their rules or are
  refused.

`test/vault_crash.exe DIR 20` kills, 20 times, a process that puts files of up to 40 MB and writes their facts, then
checks that every file the facts cite reads back exact and that every confirmed one is there.

The C core is fuzzed alone by `test/fuzz_vault.c` (libFuzzer, AddressSanitizer, UndefinedBehaviorSanitizer; the
command is in [the vault](vault.md#security)): LZ4 blocks and Zstandard frames of arbitrary bytes decoded into
buffers of no slack, round trips, and sealed texts forged or changed. 1.1 million runs in 181 s: no failure.

`server_unit` puts and loads files through the core: in pieces, whole and in 20 ranges, sent again with its serial
(one file), with each kind of token (rights per kind), a right to write gone in the middle of a put, the bounds (an
undeclared kind, an owner that is no thing, a name too long, a load by another property, four puts at once), and an
erasure; 3,000 random file requests read back as written and 24,000 changed ones read or refused.

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

`spec/LocalReads.tla` models local reads (G15, [the server](server.md#local-reads-g15)): a server that writes frames
one at a time, sends each to its readers before its fsync and answers its writers after; readers that apply frames
from a channel that keeps its bytes past the server's death, and notice the death later; programs' reads in each
reader and at the server, each an interval (it starts, takes a state, returns it). The invariant `Linearizable`
checks three conditions on every read when it returns, Fresh, Ordered and Durable, with write ids so that a group a
death lost and a later group of the same number are told apart. The constant `Rule` picks how a group becomes
visible:

| configuration | rule | bounds | result |
|---|---|---|---|
| `LocalReads.cfg` | the one built (the visibility number) | 2 readers (symmetric), remote reads, 3 writes | holds: 3,436,820 distinct states |
| `LocalReadsCrash.cfg` | the one built | 1 reader, remote reads, 3 writes, a server death (its frame in flight kept or lost) | holds: 210,716 |
| `LocalReadsLive.cfg` | the one built | 1 reader, 2 writes | `NeverReadsAll` breaks, as it must: reads do return the newest group |
| `LocalReadsNoSkip.cfg` | no 2 added at a start | 1 reader, 3 writes, a death | breaks Fresh (8 states) |
| `LocalReadsEarly.cfg` | the number stored before the fsync | 1 reader, 2 writes, a death | breaks Durable (6 states) |
| `LocalReadsRemoteFirst.cfg` | remote reads moved at the fsync, before the number | 1 reader, 2 writes | breaks Ordered (8 states) |
| `LocalReadsDesign.cfg` | the design's lease | 1 reader, 2 writes, 4 ticks, leases of 2 | breaks Ordered (7 states) |
| `LocalReadsDesignFresh.cfg` | the design's lease | the same | `NoStale` (Fresh and Durable) holds: 289,765 |
| `LocalReadsDraft.cfg` | the design's first draft | the same | breaks `NoStale`: Fresh (12 states) |

`spec/CommitBuffer.tla` models the server's commit buffer ([the server](server.md#many-databases-one-fsync-the-commit-buffer)):
databases whose syncers write each frame to their journal without an fsync and give it to the buffer, one frame in
flight a database; rounds of every frame that came meanwhile, appended and forced once, one round in flight; frames
forced in their own journal (long ones, and one that comes when the buffer is idle); checkpoints forcing a journal; the oldest round dropped once each of its
frames is checkpointed; F1 (a process death, the page cache kept), F2 (a power loss: each unforced frame of a journal
lost, kept or torn on its own; the buffer's rounds after the forced ones kept up to some round), F4 (a failed fsync,
of the buffer or of a journal at a checkpoint, marks its pages clean and stops the buffer); and recovery with the
rule as built (the buffer's torn newest round cut, each frame it kept written again at its place, every other frame
before the last of them must check, the journal's own rule after). Invariants: `Durable` (G1: whenever the server
runs, every confirmed frame is in its journal), `Prefix` (G3), `NeverRefused` (no damage is modelled, so no open may
refuse: G6), `CheckpointOnDisk` (a checkpoint covers only frames the disk holds). Bounds in `spec/CommitBuffer.cfg`, 2
databases of 2 frames each: 11,313 distinct states; with 3 frames each (`MaxFrames = 3`, not in `tools/tlc.sh`):
206,395 distinct states, depth 25, 9 minutes on 4 workers. Each variant that drops a part of the rule breaks:

| configuration | the rule without | breaks |
|---|---|---|
| `CommitBufferTrust.cfg` | the buffer's frames at recovery: each journal by its own rule | `Durable` |
| `CommitBufferEarly.cfg` | the checkpoint: a round dropped once its frames are in their journals' page cache | `Durable` |
| `CommitBufferCkpt.cfg` | the stop after a failed fsync: a checkpoint after one | `CheckpointOnDisk` |
| `CommitBufferMany.cfg` | one frame in flight: a database writes its next frame before the last one is confirmed (1 database, 3 frames) | `NeverRefused` |

The model takes recovery's writes as forced, as the code must make them: the code's first version skipped a frame
whose bytes the page cache already showed, which the model cannot see and the simulation found
([above](#the-commit-buffer)).

`spec/RuleChange.tla` models a change of the rules on the background path ([rules](rules.md#changes-of-the-rules-in-the-background),
G19): three asserted facts and two derived ones, old rules and new rules (the new ones with a constraint), a writer
committing groups under its rules as frames of facts with their states after, a change C that also asserts a fact and
expects another; the build from the working view, the catch-up by batches of any size, the switch by the writer,
crashes that keep any prefix of the frames from the durable ones on, and a Raft member's take-back (the frames not
committed taken back, the working view back to the published one, a new lineage: a change started on an older one is
answered, never installed); the views as the engine keeps them, layers of runs and a delta, with the change's derived
facts in a run of their own R under its view's delta, the table of differences fact by fact, and a merge that names
the working view's state on the disk. Invariants: `ViewsExact` (the working and the
published views, and the state at every frame of the journal, are the least model of their asserted facts under their
rules: no view mixes the old rules' facts with the new ones'), `JournalIsWork` (replay gives the working view: C's
frame is exactly the difference the adopted view holds), `OneSwitch` (the rules change at C's frame), `ConstraintsHold`
(G18), `Serial` (C's `Expect` held just before it, its asserted fact at it), `NoLostWrite` (C's frame changes no
asserted fact but its own), `AckedDurable`, `ChangeViewExact` (the change's view, read through its layers, is the
least model under the new rules), `TableExact` (the table and R are the difference between the writer's state where
the background stands and the change's view), `RunsExact` (the runs named on the disk hold the journal's state at
their group); and the liveness property `Ends` (under fairness the change is installed,
answered or lost to a crash). Bounds in `spec/RuleChange.cfg` (4 data groups, 2 crashes, ready 2 groups behind, 1
take-back, 1 merge): 1,200,400 distinct states, 4 min 12 s on 4 workers, everything holds. Each part of the rule is needed (the variants without a
take-back but `RuleChangeTakeBack.cfg`):

| configuration | the rule without | breaks |
|---|---|---|
| `RuleChangeCopy.cfg` | the derived facts found again: a logged group's frame copied | `ChangeViewExact` |
| `RuleChangeLate.cfg` | the writer's last catch-up | `JournalIsWork` |
| `RuleChangeEarlyExpect.cfg` | the `Expect` checked at the install: at the build | `Serial` |
| `RuleChangeNoCheck.cfg` | the new rules' check of the caught-up state | `ConstraintsHold` |
| `RuleChangeOverlap.cfg` | the `Conflict` of a group that touches C's fact | `Serial` |
| `RuleChangeStale.cfg` | the difference at the install: the build's own changes written | `ViewsExact` |
| `RuleChangePublished.cfg` | the build from the working view: from the published one | `TableExact` |
| `RuleChangeTakeBack.cfg` | the install on the change's own lineage (Raft): installed after a take-back | `ViewsExact` |
| `RuleChangeShadowed.cfg` | R takes only the facts the forked view's delta has no entry for: it takes them all | `ChangeViewExact` |
| `RuleChangeUntracked.cfg` | a fact of R enters the table as (absent, derived): as its state before the step | `TableExact` |
| `RuleChangeNoTombstone.cfg` | a fact of R whose two states agree stays in the table: removed | `TableExact` |
| `RuleChangeNamed.cfg` | R never named: named with the runs below it once C's frame is durable | `RunsExact` |
| `RuleChangeMergeSkipsRun.cfg` | every merge takes R: a merge leaves it below | `RunsExact` |

`tools/tlc.sh` runs them all and fails unless each that must break does: 1 min 57 s on the test machine (2026-11-12),
every model included.

## Further reading

Zhou et al., FoundationDB (SIGMOD 2021); Pillai et al., ALICE (OSDI 2014); Bornholt et al., lightweight formal methods
in Amazon S3 (SOSP 2021); Claessen and Hughes, QuickCheck (ICFP 2000); Lamport, Specifying Systems (2002); Yu,
Manolios, Lamport, TLC (CHARME 1999); Newcombe et al. (CACM 2015); Kingsbury and Alvaro, Elle (PVLDB 2020); Steele,
Lea, Flood, SplitMix (OOPSLA 2014). Entries: [references](references.md#testing-and-verification).
