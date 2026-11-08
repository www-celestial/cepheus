# Cepheus

A database of facts, in OCaml. Everything it stores is a **fact** `(thing, property, value)`, the
entity–attribute–value model that Datomic calls a datom. A write is a **group** of facts: a transaction, applied all
or nothing, with who and why; the group is the event, and the journal keeps every group for ever. A reader takes a
**view**, the exact state after one group, and reads it with no lock. A **fork** is a temporary state started from a
view: written to like the database, with the same checks, and never written to disk; it is the base of unit tests and
what-if questions.

```ocaml
open Cepheus

let () =
  let db = Result.get_ok (open_ "shop") in
  let[@warning "-8"] (Ok [ name; city ]) = declare db [ prop "client/name" Ttext; prop "client/city" Ttext ] in
  let r = Result.get_ok (write db ~by:7 ~why:"signup" [ Add (-1, name, Text "Ada Martin"); Add (-1, city, Text "Lyon") ]) in
  Printf.printf "group %d made thing %d\n" r.group (thing r (-1));
  (* a question: the things whose city is Lyon *)
  let q = { vars = 1; ranges = []; where = [ { e = Var 0; p = city; v = Val (Text "Lyon") } ] } in
  (match find (view db) q with
   | Ok rows -> List.iter (fun row -> print_endline (Value.to_string row.(0))) rows
   | Error e -> print_endline (message e));
  close db
```

```output
group 3 made thing 65536
#65536
```

(Group 1 described the system properties when the database was made, group 2 declared the two properties.)

## What it promises

When `write` returns `Ok`, the group is on the disk: it survives a crash of the process or a power loss (G1). A group
is all or nothing (G2); the groups after a recovery are a prefix 1..k of the history (G3); the writes are strictly
serializable, one writer applying them one at a time (G4); a view never changes and shows only durable groups (G5);
damage to durable bytes is detected, never dropped in silence (G6). Each guarantee, its exact conditions, its proof
and the test that checks it: [guarantees](docs/guarantees.md).

## Against the established databases

Measured on one laptop (Intel i7-4720HQ, SATA SSD) against PostgreSQL 18.6 set up as an expert would, 10 million
facts, the same answers on both sides, medians of 21 runs ([benchmarks](docs/benchmarks.md)):

| | Cepheus | PostgreSQL |
|---|---:|---:|
| every fact of an invoice, by id | 0.39 µs | 4.73 µs in the server; 26 µs through its socket |
| the unpaid invoices of a city's clients (4,299 rows) | 4.07 ms | 10.55 ms |
| the unpaid sum per city (453,866 invoices), 3 cores | 107 ms | 109 ms |
| triangles of a follow graph (568,163 links), 3 cores | 371 ms | 603 ms (2 processes) |
| durable writes, 256 clients | on par (both bound by the disk's fsync) | |
| triangles, base of 245 MB read through a 32 MB cache, process capped at 128 MB | 102 s | **1.05 s** (32 MB of buffers) |
| bulk load of 10 M facts | 135 to 153 s | **about 1 min** (`COPY`) |

SQLite 3.54, a library in the process as Cepheus is, measured the same way on one core: Cepheus is faster on an
invoice by id (0.37 µs against 0.68) and on the unpaid sum per city (230 ms against 360), even on the city's unpaid
invoices and the triangles, slower on a client by e-mail (1.67 µs against 1.52); SQLite loads the 10 M facts 12 times
faster (8.6 s) into a file half the size (131 MB). Where each one wins, and why, and how Cepheus compares by design
with Oracle, Datomic, RocksDB, Neo4j, FoundationDB and CockroachDB: [comparison](docs/comparison.md).

## Build and test

- `dune build`; `dune test` runs the unit and property tests, the exhaustive crash enumeration, the deterministic
  simulation (200 seeds) and every example of this documentation;
- `tools/test.sh` runs everything, the slow tests too (real `kill -9`, the bank test), in the release build;
- `TLA2TOOLS=/path/to/tla2tools.jar tools/tlc.sh` model-checks the TLA+ specifications.

No dependency but OCaml 5 (`unix`, `threads`), and no C.

## Documentation

Start with [concepts](docs/concepts.md), then [how it works](docs/architecture.md). The whole map:
[docs/](docs/README.md).
