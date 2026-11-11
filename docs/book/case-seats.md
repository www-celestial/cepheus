# A case: never sell the same seat twice

A concert hall sells its seats online. Many people buy at the same moment, and the machine that runs the sale may
crash at any instant. This chapter takes that problem from its statement to the proof that it is solved, step by
step, with the methods researchers use: state the property one can check, measure before changing anything, form a
hypothesis that an experiment could prove wrong, look for the result that already solves this kind of problem, write
the smallest solution, then prove it on every side that applies (a test that fails before and passes after,
generated inputs, a formal model checked by a machine, real crashes, a checker of the whole history, and the speed
beside the established databases), and say what could make the proof wrong and what is left. Every block of OCaml
below is a whole program that the documentation's test runs; the output shown under one is what it prints. The words
are explained where they first appear, and in the [glossary](glossary.md); the works cited are in
[references](references.md).

## 1. The problem, stated precisely

Pólya's first rule for solving a problem is to understand it: what is the unknown, what are the data, what is the
condition ([Pólya 1945]). DARPA's Heilmeier catechism asks the same of a research project in plain words: what are you
trying to do, how is it done today, what is new, and how will you know you succeeded (\[Heilmeier]). Here:

- **Who has it**: anyone who sells a limited stock to many people at once: seats, tickets, rooms, appointments.
- **What is done today, and what goes wrong**: a buyer's screen shows the free seats; the buyer clicks one; the
  program checks that the seat is free and records the sale. Two buyers who see the same free seat and click it at the
  same moment can both be told "sold".
- **What "solved" means**, as properties a program can check on any state and any history of the database:
  1. *no double sale*: each seat has at most one sale (one charge);
  2. *no charge without the seat*: every buyer charged for a seat owns that seat;
  3. *durable*: a sale the buyer was told about (confirmed) is never lost, whatever crashes come after;
  4. and the sale must still go fast with many buyers at once (measured in section 6).
- **Out of scope**: the payment itself (a bank's side), buyers who change their mind (a refund is another group),
  several machines (Cepheus runs on one).

The data model, in Cepheus' facts (thing, property, value): a seat is a thing with a `seat/number`; its owner is a
one-valued property `seat/owner` (the buyer's number); a charge is a thing with `charge/seat` (a link to the seat) and
`charge/buyer`. A sale is one group (a transaction, [concepts](concepts.md#groups-a-write-is-a-transaction)): the
seat's owner and the charge together, all or nothing (G2), so property 2 cannot break by half a sale.

## 2. Measure before changing anything

Before changing anything, measure what happens now: a **baseline**, the number the solution will be compared with.
Jain's rules for an experiment ([Jain 1991]) ask for the workload, the metric and the factors to be written down
first; Georges, Buytaert and Eeckhout ([Georges 2007]) and Kalibera and Jones ([Kalibera 2013]) ask for several runs
and a confidence interval rather than one number, because a single run of a concurrent program is one draw among many.

The naive sale, as section 1 describes it: a buyer takes a view (the state after one group, read with no lock), picks
one of the ten best free seats in it at random, and writes the owner and the charge. `test/seats.exe DIR 0 SEED naive
2000`, with `BUYERS` threads, runs it: the buyers, threads of one process, sell a hall of 2,000 seats on the real disk
until the hall is sold out, every sale durable when confirmed; then a checker reads the whole history and counts what
went wrong (section 6 describes it). The method of the [benchmarks](benchmarks.md#method): under the shared lock that
keeps other heavy jobs off the machine, each process in a 3 GB memory scope, 5 runs a configuration, the median and the
interval between the smallest and the largest run (with 5 runs, it covers the true median with probability 93.8 %:
an interval of order statistics, which assumes nothing about the distribution).

| buyers | seats sold more than once | sales too many (charges beyond one a seat) | buyers charged without the seat | time to sell out |
|---:|---:|---:|---:|---:|
| 2 | 199 [191, 227] | 199 [191, 227] | 199 [191, 227] | 9.8 s [6.6, 17.3] |
| 4 | 426 [413, 440] | 463 [455, 471] | 463 [455, 471] | 6.8 s [4.2, 13.8] |
| 16 | 1,334 [1,301, 1,346] | 2,199 [2,132, 2,209] | 2,199 [2,132, 2,209] | 1.9 s [1.7, 9.3] |

So the naive sale sells seats twice in every run, and the more buyers there are, the more: with 16 buyers two seats in
three go to several buyers, and every sale too many is a buyer charged for a seat someone else owns. No crash is
needed for it. The times vary by a factor of 2 to 5 between runs: they are the disk's (a sale waits for its fsync), on a
machine other jobs were using.

## 3. A hypothesis one can prove wrong, and its cause

A hypothesis is useful when an experiment could refute it (a **falsifiable** one). Ours: *the double sales come from
the gap between the read and the write, not from the disk, the threads, the crashes or the engine's merges*. The
experiment that could refute it: make the failing case as small as possible, as delta debugging does for a failing
input ([Zeller 2002]), removing buyers, seats, threads and the disk as long as the failure stays. If the hypothesis
were wrong, the failure would go away with the disk or the threads. What remains is two buyers, one seat, one view, no
thread and no disk (a fork, [concepts](concepts.md#forks)), and it still fails:

```ocaml
open Cepheus

let () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ number; owner; seat_of; buyer_of ]) =
    declare db [ prop "seat/number" Tint; prop "seat/owner" Tint; prop "charge/seat" Tlink; prop "charge/buyer" Tint ]
  in
  let seat = thing (Result.get_ok (write db [ Add (-1, number, Int 1) ])) (-1) in
  (* the naive sale: if the seat is free in the view the buyer read, write the owner and the charge *)
  let buy buyer v =
    if values v seat owner <> [] then Printf.printf "buyer %d: taken\n" buyer
    else
      match write db [ Add (seat, owner, Int buyer); Add (-1, seat_of, Link seat); Add (-1, buyer_of, Int buyer) ] with
      | Ok r -> Printf.printf "buyer %d: sold, group %d\n" buyer r.group
      | Error e -> Printf.printf "buyer %d: %s\n" buyer (message e)
  in
  let v = view db in
  (* both buyers read the same view, in which the seat is free *)
  buy 1 v;
  buy 2 v;
  let now = view db in
  Printf.printf "owner of seat 1: %s; charges for it: %d\n"
    (String.concat ", " (List.map Value.to_string (values now seat owner)))
    (List.length (things now seat_of (Link seat)))
```

```output
buyer 1: sold, group 4
buyer 2: sold, group 5
owner of seat 1: 2; charges for it: 2
```

The hypothesis survives the test: two buyers and one shared view suffice, and buyer 1 is charged for a seat that buyer
2 owns. Its name in the literature is the **lost update** ([Berenson 1995], phenomenon P4): two transactions read the
same item, and each writes a value computed from what it read; the second write replaces the first, which is lost.
Here the item is the seat's owner, and the second `Add` of the one-valued property replaced the first owner (the
journal records the retraction). Its cousin is **write skew** (Berenson's A5B): two transactions read the same items
and each writes a different one, together breaking a rule that each kept alone (two doctors each going off call
because the other is on call, [concepts](concepts.md#isolation-exactly-what-a-reader-and-a-writer-see)). A rule over
several seats, such as four seats at most a buyer, would be broken by write skew; section 7 comes back to it.

The cause, precisely: each group is applied alone and in order (G4), but the buyer's read happened outside the group,
in a view taken earlier. Nothing told the writer what the buyer had read, so nothing checked it.

## 4. Research: what solves this kind of problem

- **Serializability** (Papadimitriou, [Papadimitriou 1979]): a set of transactions run at the same time is correct if
  its result equals the result of running them one at a time in some order. A read-then-write is one transaction:
  the read and the write together. The naive sale is not serializable: in any order of the two sales one at a time,
  the second buyer would have seen the seat taken.
- **Strict serializability**, and **linearizability** for a single object (Herlihy and Wing, [Herlihy 1990]): the
  order must also respect real time (a sale confirmed before another began comes first). Cepheus' groups are strictly
  serializable (G4): what is missing is to put the read inside the group.
- **Isolation levels and their anomalies** (Berenson et al., [Berenson 1995]; Adya, [Adya 1999]): under *read
  committed*, the default of PostgreSQL and Oracle, the lost update happens as above; *snapshot isolation* stops it
  when both transactions write the same item ("first committer wins") but lets write skew through; *serializable*
  stops both. Adya defines the anomalies on a graph of the transactions' dependencies, which section 6 checks.
- **How PostgreSQL does it** (Cahill, Röhm and Fekete, [Cahill 2008]; Ports and Grittner, [Ports 2012]): its
  SERIALIZABLE level is *serializable snapshot isolation*: each transaction reads a snapshot, and the server tracks
  which transactions read what others wrote; a pattern of two such read-write conflicts in a row aborts one of them,
  and the application must try it again ("serialization failure").
- **How SQLite does it** ([SQLite isolation](https://www.sqlite.org/isolation.html)): one writer at a time for the
  whole database; `BEGIN IMMEDIATE` takes the write lock at the start of the transaction, so the read and the write of
  a sale happen with no other writer between them; "transactions in SQLite are SERIALIZABLE".
- **Optimistic concurrency control** (Kung and Robinson, [Kung 1981]): read without locks, and at the end validate that
  what was read still holds; if not, abort and retry. No lock is held while a buyer looks at the seat map.

What applies here: Cepheus already applies groups one at a time on the newest state; an `Expect` in the group states
what the buyer read, and the writer validates it on that newest state (optimistic validation, Kung and Robinson). With
the read inside the group, the sale is a single strictly serializable transaction.

## 5. The smallest solution

One line: the group says that the seat has no owner, `Expect (seat, owner, None)`. The writer checks it on the newest
state, after every group before it; if another buyer took the seat since the view, the group is refused with
`Conflict`, nothing is written, and the buyer reads a new view and picks again.

```ocaml
open Cepheus

let () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ number; owner; seat_of; buyer_of ]) =
    declare db [ prop "seat/number" Tint; prop "seat/owner" Tint; prop "charge/seat" Tlink; prop "charge/buyer" Tint ]
  in
  let seat = thing (Result.get_ok (write db [ Add (-1, number, Int 1) ])) (-1) in
  (* the sale states what the buyer read: the seat has no owner *)
  let buy buyer v =
    if values v seat owner <> [] then Printf.printf "buyer %d: taken\n" buyer
    else
      match
        write db
          [ Expect (seat, owner, None); Add (seat, owner, Int buyer); Add (-1, seat_of, Link seat); Add (-1, buyer_of, Int buyer) ]
      with
      | Ok r -> Printf.printf "buyer %d: sold, group %d\n" buyer r.group
      | Error e -> Printf.printf "buyer %d: %s\n" buyer (message e)
  in
  let v = view db in
  buy 1 v;
  buy 2 v;
  let now = view db in
  Printf.printf "owner of seat 1: %s; charges for it: %d\n"
    (String.concat ", " (List.map Value.to_string (values now seat owner)))
    (List.length (things now seat_of (Link seat)))
```

```output
buyer 1: sold, group 4
buyer 2: conflict: #65536 has a value for seat/owner (property 17)
owner of seat 1: 1; charges for it: 1
```

This is the failing case of section 3 with one more operation: before, buyer 2 was sold a seat that was gone; now it
is told so, and nothing of its sale was written. A real buyer loop takes a new view on `Conflict` and picks again
(`test/seats.ml`, function `child`).

## 6. The proof that it is solved

### Correctness, on generated inputs

The two programs above are the test that fails before and passes after. One case proves little, so the same check runs
on many generated cases, as QuickCheck does ([Claessen 2000]): a random number of buyers (2 to 6) and of seats (1 to
4), and a random **schedule**, the order in which the buyers' steps (read a view, then write) interleave. For each
schedule, the naive sale and the sale with `Expect` run on forks, and the two properties are checked on the end state.

```ocaml
open Cepheus

let () =
  let r = Rng.make 2026 in
  let broken = [| 0; 0 |] in
  for _ = 1 to 1000 do
    let nb = 2 + Rng.int r 5 and ns = 1 + Rng.int r 4 in
    (* a schedule: each buyer appears twice, shuffled; its first step reads a view, its second writes *)
    let steps = Array.init (2 * nb) (fun i -> i / 2) in
    for i = Array.length steps - 1 downto 1 do
      let j = Rng.int r (i + 1) in
      let x = steps.(i) in
      steps.(i) <- steps.(j);
      steps.(j) <- x
    done;
    (* the same schedule, run with the naive sale and with the Expect *)
    List.iteri
      (fun mode expect ->
        let db = fork empty in
        let[@warning "-8"] (Ok [ number; owner; seat_of; buyer_of ]) =
          declare db [ prop "seat/number" Tint; prop "seat/owner" Tint; prop "charge/seat" Tlink; prop "charge/buyer" Tint ]
        in
        let made = Result.get_ok (write db (List.init ns (fun k -> Add (-(k + 1), number, Int (k + 1))))) in
        let seats = List.init ns (fun k -> thing made (-(k + 1))) in
        let read = Array.make nb false and picked = Array.make nb None in
        Array.iter
          (fun b ->
            if not read.(b) then begin
              (* the best free seat in the view *)
              let v = view db in
              read.(b) <- true;
              picked.(b) <- List.find_opt (fun s -> values v s owner = []) seats
            end
            else
              match picked.(b) with
              | Some s ->
                let check = if expect then [ Expect (s, owner, None) ] else [] in
                ignore (write db (check @ [ Add (s, owner, Int b); Add (-1, seat_of, Link s); Add (-1, buyer_of, Int b) ]))
              | None -> ())
          steps;
        let v = view db in
        let bad s =
          let charges = things v seat_of (Link s) in
          List.length charges > 1 || List.exists (fun c -> values v c buyer_of <> values v s owner) charges
        in
        if List.exists bad seats then broken.(mode) <- broken.(mode) + 1)
      [ false; true ]
  done;
  Printf.printf "naive: %d of 1000 schedules sell a seat twice or charge without the seat\n" broken.(0);
  Printf.printf "with Expect: %d of 1000\n" broken.(1)
```

```output
naive: 881 of 1000 schedules sell a seat twice or charge without the seat
with Expect: 0 of 1000
```

### A formal model, checked by a machine

Tests try the schedules a generator draws; a **model checker** tries every one, within bounds. `spec/Seats.tla` is a
model of the sale in TLA+ ([Lamport 2002]), the language Amazon's engineers have used to find subtle design bugs that
their tests had missed ([Newcombe 2015]): buyers that take a view and pick a free seat in it (`Read`), groups the
writer applies one at a time on the newest state (`Write`, with or without the `Expect`), and crashes that lose the
buyers' views but no confirmed group (`Crash`, as G1 says). Its invariants are the properties of section 1:
`NoDoubleSale` and `NoChargeWithoutSeat`. TLC, TLA+'s model checker, explores every reachable state (`tools/tlc.sh`).

With the naive sale (`spec/SeatsNaive.cfg`, `Naive = TRUE`, 3 buyers and 2 seats), TLC stops at the first state that
breaks an invariant, after 116 distinct states, and prints the shortest path to it, which is the case of section 3
found by the machine (two buyers read the same free seat, both write):

```text
Error: Invariant NoDoubleSale is violated.
State 1: <Initial predicate>
/\ owner = (s1 :> None @@ s2 :> None)
/\ sales = {}
/\ pc = (b1 :> "looking" @@ b2 :> "looking" @@ b3 :> "looking")
/\ pick = (b1 :> None @@ b2 :> None @@ b3 :> None)
State 2: <Read line 30, col 3 to line 35, col 31 of module Seats>
/\ owner = (s1 :> None @@ s2 :> None)
/\ sales = {}
/\ pc = (b1 :> "read" @@ b2 :> "looking" @@ b3 :> "looking")
/\ pick = (b1 :> s1 @@ b2 :> None @@ b3 :> None)
State 3: <Read line 30, col 3 to line 35, col 31 of module Seats>
/\ owner = (s1 :> None @@ s2 :> None)
/\ sales = {}
/\ pc = (b1 :> "read" @@ b2 :> "read" @@ b3 :> "looking")
/\ pick = (b1 :> s1 @@ b2 :> s1 @@ b3 :> None)
State 4: <Write line 40, col 3 to line 48, col 19 of module Seats>
/\ owner = (s1 :> b1 @@ s2 :> None)
/\ sales = {<<b1, s1>>}
/\ pc = (b1 :> "served" @@ b2 :> "read" @@ b3 :> "looking")
/\ pick = (b1 :> s1 @@ b2 :> s1 @@ b3 :> None)
State 5: <Write line 40, col 3 to line 48, col 19 of module Seats>
/\ owner = (s1 :> b2 @@ s2 :> None)
/\ sales = {<<b1, s1>>, <<b2, s1>>}
/\ pc = (b1 :> "served" @@ b2 :> "served" @@ b3 :> "looking")
/\ pick = (b1 :> s1 @@ b2 :> s1 @@ b3 :> None)
```

With the `Expect` (`spec/Seats.cfg`, 4 buyers and 3 seats, crashes at any step): every one of the 8,449 reachable
states satisfies `TypeOK`, `NoDoubleSale` and `NoChargeWithoutSeat` (52,034 states generated, depth 9, under a
second). `tools/tlc.sh` checks both: the model with `Expect` must hold, and the naive one must fail (TLC's exit code
for a broken invariant, 12), so that the model is shown able to see the bug. A model is only as good as its
abstraction: it assumes that groups are applied one at a time and are durable once confirmed, which
`spec/Journal.tla` and `spec/Merge.tla` model and the [guarantees](guarantees.md) prove (G1, G4); the code is tested
against it by the next two proofs.

### Real crashes, and a checker of the whole history

`test/seats.exe DIR ROUNDS` sells a hall of 2,000 seats to 16 buyer threads in a child process and kills it with
`SIGKILL` (`kill -9`) at a random moment, ROUNDS times, reopening the database after each kill and starting a new
child on what is left, until the hall is sold out. The child prints every confirmation. Then the checker reads the
journal, the database's complete history (every group, in order, with its `why`, where each sale wrote its buyer, its
seat and the group of the view it read):

- *durable*: every confirmed sale is in the journal, exactly as written, and its buyer owns its seat in the end;
- *the properties*: at most one charge a seat, and every charge's buyer owns the seat;
- *serializable*, in the spirit of Elle ([Kingsbury 2020]), the checker that Jepsen uses on real databases: it builds
  the **dependency graph** of the sales (Adya, [Adya 1999]) and looks for a cycle. Each seat is a register whose
  versions are its owners, in group order; there is an edge *ww* from a sale to the next sale that wrote the same
  seat, *wr* from the sale whose owner another sale read to that sale, and *rw* (an anti-dependency) from a sale to
  the sale that replaced the version it read. Every *ww* and *wr* edge goes forward in group order, so a cycle needs an
  *rw* edge going back: a sale that read a version older than the one it replaced. Such a cycle is an anomaly no
  serial order explains (Adya's G2); here, a lost update. A history with no cycle is serializable.

Three runs of each, 20 kills at most (the naive sale makes about twice as many sales, so it runs longer and meets
all 20; with the `Expect` the hall sells out after 8 to 16):

| | kills | sales in the journal (confirmed before a kill) | seats sold more than once | charged without the seat | seats with a cycle |
|---|---:|---:|---:|---:|---:|
| with `Expect` | 16; 8; 11 | 2,000 (1,930); 2,000 (1,967); 2,000 (1,938) | 0 | 0 | 0 |
| naive | 20; 20; 20 | 4,129 (3,930); 4,138 (3,930); 4,235 (4,079) | 1,291; 1,287; 1,329 | 2,129; 2,138; 2,235 | 1,291; 1,287; 1,329 |

With the `Expect`: every seat sold once, to the buyer who was told so; every confirmed sale in the journal and in the
end state, through every kill (a sale that is in the journal but was not confirmed is one the child wrote and forced
but was killed before it printed: durable, and correct); no cycle. Without it, the checker finds a cycle on exactly the
seats sold more than once.

The naive run is the test of the test: the checker must see the anomalies when they are there, or its silence on the
sale with `Expect` would prove nothing. `tools/test.sh` runs the sale with `Expect` and fails on any anomaly.

### A bound

How often should the naive sale fail? A back-of-the-envelope model gives a number to compare with section 2: when $m$
buyers read the same view and each picks one of the ten best free seats at random, the chance that two pick the same
one is the birthday problem's, $1 - (10 \times 9 \times \dots \times (10 - m + 1)) / 10^m$: 10 % for 2 buyers, 50 % for 4, and certain
for 16 (more buyers than seats to choose from). The $m$ picks then cover $10 (1 - 0.9^m)$ distinct seats on average (each
seat is missed by all $m$ with probability $0.9^m$), so the share of sales too many is $1 - (10/m) (1 - 0.9^m)$: 5 % for 2
buyers, 14 % for 4, 49 % for 16. Measured (the table of section 2): 199 of 2,199 sales, 9.0 %; 463 of 2,463, 18.8 %;
2,199 of 4,199, 52.4 %. The model predicts the growth and, for 16 buyers, the rate; it is below for 2 and 4 buyers
because a buyer also collides with sales still in flight, written but not yet in any view (a frame being forced),
which the model leaves out.

With the `Expect`, the bound is exact: no double sale, ever, under the conditions of G4 and G1 (one writer applies the
groups in order, each `Expect` checked on the state just before its group, and a confirmed group is durable).

### Speed, beside the giants

A solution that is correct but slow does not solve a sale. The same sale, sold out on the same machine with 16
buyers, by Cepheus with `Expect`, SQLite 3.54 with `BEGIN IMMEDIATE` (WAL, `synchronous = FULL`: a sale is durable when
it commits, as Cepheus'), and PostgreSQL 18.6 at SERIALIZABLE, retrying each serialization failure (pgbench
`--max-tries`), and at its default READ COMMITTED with the naive read-then-write, for comparison:

| 2,000 seats, 16 buyers, 5 runs | time to sell out | sales a second | seats sold more than once | what the database did |
|---|---:|---:|---:|---|
| Cepheus, `Expect` | **2.30 s [2.01, 3.02]** | 871 | 0 | 2,211 [2,128, 2,270] sales refused (`Conflict`), tried again |
| SQLite 3.54, `BEGIN IMMEDIATE` | 9.84 s [9.44, 16.15] | 203 | 0 | one writer at a time |
| PostgreSQL 18.6, SERIALIZABLE | 10.14 s [9.11, 13.40] | 197 | 0 | 1,693 [1,669, 1,725] transactions retried |
| SQLite, naive (the read outside the transaction) | 9.72 s [9.05, 11.77] | | 27 sales too many [24, 60] | |
| PostgreSQL, naive (READ COMMITTED) | 3.24 s [3.20, 4.86] | | 1,387 sales too many [1,379, 1,443] | |

Cepheus sells out 4.3 times faster than both: its writer puts every sale that arrives during an fsync into the next
frame (group commit), so the 16 buyers share each fsync, where SQLite forces each commit alone (one writer, one fsync
a commit) and PostgreSQL runs 1,693 transactions again beside its commits. Where the giants win: the correctness of
SQLite's `BEGIN IMMEDIATE` and of PostgreSQL's SERIALIZABLE does not depend on the program. PostgreSQL finds the
conflict by itself, from what each transaction read (serializable snapshot isolation); SQLite never lets another
writer in between. Cepheus validates only what the group states: a program that forgets the `Expect` sells seats
twice, as PostgreSQL does at its default level (1,387 sales too many above) and as Cepheus' own naive sale does.
SQLite's naive sale fails rarely (27 sales too many) because its single writer makes the gap between the read and
the write short; it still fails. And SQLite does all this in one file with no server, PostgreSQL for any language
through its socket and SQL; Cepheus is a library inside one OCaml process.

How each side was run: Cepheus by `test/seats.exe` (the buyers' threads in one process, the time from the first look
to the last sale); SQLite by `bench/sqlite/seats.py` (Python's `sqlite3`, one connection a thread, WAL,
`synchronous = FULL`, the same choice among the ten best free seats, through a partial index of the free seats);
PostgreSQL by `bench/pg/pg.sh seats` (pgbench, 16 clients, the scripts `bench/pg/seat-serializable.sql` and
`seat-naive.sql`, `--max-tries=1000`; its own cluster, fsync on, `shared_buffers` 1 GB, the time from pgbench's start
to the last charge's commit). Each side alternated with the others within a round, 5 rounds.

### Threats to validity

What could make this proof wrong, and how each was ruled out (Mytkowicz et al. show how an innocent change of the set-up
can change a measured result, [Mytkowicz 2009]):

- *The checker could be blind.* The naive sale runs through the same checker and the anomalies are found (above).
- *The model could abstract the bug away.* The model's naive variant fails in TLC, so the model can see the bug; and
  its assumptions (one writer, durable confirmed groups) are those the engine's own models and tests cover.
- *The crashes could all fall in harmless places.* The kills come at random moments over hundreds of milliseconds of
  selling: 8 to 20 kills a run, 95 in all; every run with the `Expect` ended with 33 to 70 sales in the journal that
  no buyer had been told about, so kills landed while sales were in flight. The engine's own exhaustive enumeration of
  crash states (`test/exhaustive.ml`) covers every point of the journal's protocol.
- *The history could lie.* The checker takes the view a sale read from the sale's own `why`, written by the buyer:
  a buyer that misreported its view would fool the serializability check (not the counts of sales and charges, which
  come from the facts). The test's buyers write the group of the view they read, and nothing else.
- *The measures could be noise.* Every process ran under the lock that keeps other heavy jobs away, the sides
  alternated, with medians and intervals over several runs; the disk is a consumer SSD whose fsync time varies (one
  fsync takes 3 ms at the median and stalls of 100 ms and more come a few times a minute,
  [operations](operations.md#disks)).
- *The comparison could be unfair.* Each side does the same sale, durable at commit, from the same client policy (one
  of the ten best free seats); PostgreSQL and SQLite run through their usual client (pgbench, Python's `sqlite3`), which
  adds a cost per statement that Cepheus, a library in the process, does not pay. The sale is bound by the fsyncs (a
  few ms each) far more than by a statement's cost (µs), so the order of the three does not rest on it.
- *One machine, one workload.* A hall of 2,000 seats and 2 to 16 buyers choosing among the ten best seats; other
  mixes (thousands of buyers, one hot seat, buyers spread over the whole hall) are not measured.

## 7. What is left

- The `Expect` protects what it names: the seat's owner. A rule over a set (no more than four seats per buyer) needs a
  fact that every sale of the buyer expects and changes, such as a count of the buyer's seats: the "materialize the
  conflict" technique ([Fekete 2005], [concepts](concepts.md#isolation-exactly-what-a-reader-and-a-writer-see)).
- A buyer who conflicts reads a new view and tries again: under heavy contention for a few seats, many tries are
  wasted (2,211 conflicts for 2,000 sales above). A seat held for a minute while the buyer pays (a reservation
  with an expiry) is the usual answer; it is another group with its own `Expect`.
- One machine: if it is lost, the sale stops until it is back (replication is planned, [comparison](comparison.md)).
- The payment is outside the database: a sale confirmed by Cepheus and a payment refused by the bank must be undone by
  another group (a compensation), which this chapter does not cover.

## Further reading

[Pólya 1945]; \[Heilmeier]; [Jain 1991]; [Georges 2007]; [Kalibera 2013]; [Zeller 2002]; [Berenson 1995];
[Papadimitriou 1979]; [Herlihy 1990]; [Adya 1999]; [Cahill 2008]; [Ports 2012]; [Kung 1981]; [Fekete 2005];
[Claessen 2000]; [Lamport 2002]; [Newcombe 2015]; [Kingsbury 2020]; [Mytkowicz 2009]. Entries, with links and what this
chapter took from each: [references](references.md).
