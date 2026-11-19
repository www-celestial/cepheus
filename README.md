# Cepheus

A database of facts, in OCaml. Everything it stores is a **fact** `(thing, property, value)`, the
entity–attribute–value model that Datomic calls a datom. A write is a **group** of facts: a transaction, applied all
or nothing, with who and why; the group is the event, and the journal keeps every group for ever. A reader takes a
**view**, the exact state after one group, and reads it with no lock. A **fork** is a temporary state started from a
view: written to like the database, with the same checks, and never written to disk; it is the base of unit tests and
what-if questions. **Rules** (Datalog) derive facts from facts: the writer keeps the derived facts in every view, as
facts, at each group, and `why` gives the proof of one ([rules](docs/book/rules.md)). OWL 2 RL, the W3C's ontology
rules, is a library of such rules (`Cepheus.Owl`; from Cesia, the package `owl`), equality (owl:sameAs) included,
kept by classes of equal things whose facts live on one representative
([OWL 2 RL](docs/book/rules.md#owl-2-rl-a-library-of-rules)).

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
damage to durable bytes is detected, never dropped in silence (G6); a merge leaves the old runs or the new ones,
whole (G12); after a failed fsync, no view shows a group a power loss could take back (G13). With rules, every view holds exactly
what its rules derive from its asserted facts (G17), constraints hold (G18), a rule change takes effect at one group
(G19), and `why` returns a true proof (G20). Each guarantee, its exact conditions, its proof
and the test that checks it: [guarantees](docs/book/guarantees.md).

## As a server

`cepheus serve --config cluster.toml` runs Cepheus as PostgreSQL runs: one process holds the databases, programs
connect through a Unix socket or TCP with TLS 1.3, each with a token that grants it read or write, database by
database (G16); a write sent again after a lost reply is applied once (G14). Server against server on the same
machine and data (1 M facts), a point read costs 10.8 µs over the Unix socket (PostgreSQL 18.6: 26.4), 39.2 µs with
TLS (49.6); 8 clients at once, 3.22 µs a read in all (6.54); 16 requests in flight on one connection, 1.46 µs a read
(PostgreSQL's pipeline of 16: 9.11). A program on the server's machine reads in its own memory, linearizably
(G15): 0.22 µs a point read, no round trip, and no write waits for it. A replica on another machine keeps a copy of
every database over mutual TLS, group for group in its own journal: backups are taken from it, and `cepheus promote`
makes it the primary, by hand ([a replica](docs/book/server.md#a-replica)). Three servers or more form a Raft
cluster: a write is confirmed once a majority holds it forced, and when the leader is lost the others elect a new one
by themselves, losing no confirmed write ([a cluster of three](docs/book/server.md#a-cluster-of-three-raft)).
Everything, from `cluster.toml` to the
wire protocol byte by byte: [the server](docs/book/server.md).

## From Cesia

A [Cesia](https://github.com/www-celestial/cesia) program reaches a database through the server, with the package
`cesia/cepheus` of this repository: one function to connect, and on the server's machine its reads are served from its
own memory, as linearizable as the server's ([Cepheus from Cesia](docs/book/cesia.md)):

```text
use deps/www-celestial/cepheus/cesia/cepheus
use std/result
use std/sys

Client = cepheus.Kind("client", {Name: cepheus.Text(), City: cepheus.Text(), Email: cepheus.Text(unique = true)})
db = result.Unwrap(cepheus.Connect("cepheus://srv1:7400/shop", [Client], token = sys.Env("CEPHEUS_TOKEN"), ca = "/etc/cepheus/ca.pem"))
ada = result.Unwrap(cepheus.Insert(Client, {Name: "Ada Martin", City: "Lyon", Email: "ada@example.com"}, db, by = 7, why = "signup"))
result.Unwrap(cepheus.Get(Client, ada, db))   (* {Name: "Ada Martin", City: "Lyon", Email: "ada@example.com"} *)
lyon = result.Unwrap(cepheus.Find(1, (c) -> {Where: [[c, Client.City, "Lyon"]], Give: {Client: c}}, db))
```

On the server's machine a `cepheus.Get` of 4 fields costs 0.77 µs from Cesia (PostgreSQL 18.6 through its socket,
from C: 26.4 µs); over TLS 51.6 µs (PostgreSQL's 49.6); 64 fibers on one connection write as fast as 64 connections.
Nothing loads before the package's first call, which costs 13 ms once a process.

## Files

A database keeps files too: `cepheus.Put(Scans, "2026-11.pdf", bytes, db, owner = ada)` stores one, `cepheus.Read`
reads it whole or by a range. Its bytes are cut into chunks by their content (FastCDC) and each is stored once,
compressed (LZ4, or Zstandard for cold files), sealed with AEGIS-256 under its owner's key and checked at every read;
`cepheus.Erase(ada, db)` destroys the key, and every file she owned is unreadable wherever its bytes went
([the vault](docs/book/vault.md)).

## Against the established databases

Measured on one laptop (Intel i7-4720HQ, SATA SSD) against PostgreSQL 18.6 set up as an expert would, 10 million
facts, the same answers on both sides, medians of 21 runs ([benchmarks](docs/book/benchmarks.md)):

| | Cepheus | PostgreSQL |
|---|---:|---:|
| every fact of an invoice, by id | 0.39 µs | 4.73 µs in the server; 26 µs through its socket |
| the unpaid invoices of a city's clients (4,299 rows) | 2.87 ms | 13.9 ms |
| the unpaid sum per city (453,866 invoices), 3 cores | 57.8 ms | 107 ms (3 processes) |
| triangles of a follow graph (568,163 links), 3 cores | 100 ms | 602 ms (2 processes: its most) |
| durable writes, 256 clients | on par (both bound by the disk's fsync) | |
| triangles, read through a 32 MB cache, process capped at 128 MB, cold, 1 core | **263 ms** (114 ms on 3 cores; 260 ms capped at 48 MB) | 1.05 s (32 MB of buffers) |
| load of 10 M facts | **5.13 s**, in two large groups, alternated with it | 30.87 s (`COPY`, indexes, `VACUUM ANALYZE`) |

SQLite 3.54, a library in the process as Cepheus is, measured the same way on one core (before run format 7): Cepheus
is faster on an invoice by id (0.37 µs against 0.68), on the unpaid sum per city (230 ms against 360) and on the triangles
(0.97 s against 1.04), tied on the city's unpaid invoices, slower on a client by e-mail (1.67 µs against 1.52). Loading the 10 M facts, alternated
seven times, Cepheus is faster in every round (5.61 s against 9.37 s at the median: SQLite takes 1.7 times as long),
but SQLite does it in 11 MB of memory against 1.46 GB (0.88 of it the client's own list of operations). Since run
format 7 and journal format 2 (2026-11-09), the 10 M facts take 76.0 MB on disk with their whole history, against
SQLite's 136 MB file, which keeps none, and load in 3.45 s against 7.22 s; on one core a client by e-mail takes
0.66 µs against 1.37, a city's unpaid invoices 3.97 ms against 4.11, the triangles 1.08 s against 1.03; cold, each
process capped at 48 MB so that neither file fits, Cepheus answers the first four questions 1.7 to 5.4 times faster
and loses the triangles by more than 100 times (more than 2.5 minutes a run against 1.02 s: SQLite's follow links fit
in its cache in a table of their own)
([benchmarks](docs/book/benchmarks.md#compressed-runs-and-journal-2026-11-09-at-10-million-facts)). With run format 8
(2026-11-11: each property's rows also apart, in thing order, and sorted lists intersected by leapfrogging) Cepheus
wins all five on one core: 0.39 µs against 0.69, 0.64 µs against 1.42, 2.87 ms against 4.18, 130 ms against 369 and
the triangles in 256 ms against 1.05 s, and at a 48 MB cap the triangles in 260 ms
([benchmarks](docs/book/benchmarks.md#the-column-order-and-leapfrog-intersections-2026-11-11-at-10-million-facts)); at a transaction a client, Cepheus' group commit loads 1 M facts 13 to 16 times faster (13.2 s
against 174.0 s; 10.6 against 166.7 in an earlier series). Where each one wins, and why, and how Cepheus compares by design
with Oracle, Datomic, RocksDB, Neo4j, FoundationDB and CockroachDB: [comparison](docs/book/comparison.md).

## Build and test

- `dune build`; `dune test` runs the unit and property tests, the exhaustive crash enumeration, the deterministic
  simulation (200 seeds) and every example of this documentation;
- `tools/test.sh` runs everything, the slow tests too (real `kill -9`, the bank test), in the release build;
- `TLA2TOOLS=/path/to/tla2tools.jar tools/tlc.sh` model-checks the TLA+ specifications.

No dependency but OCaml 5 (`unix`, `threads`) and its C compiler for one small file, `src/crc32c_stubs.c`: the
checksum by the processor's own instruction (SSE4.2 on x86-64, CRC32 on arm64), 8 times the speed of the table code
in OCaml it replaced; a processor without it is refused when the program starts. The server also links the system's
OpenSSL 3 (`libssl`, `libcrypto`) through `server/tls_stubs.c`, for TLS.

## Documentation

Start with [concepts](docs/book/concepts.md), then [how it works](docs/book/architecture.md). The whole map:
[docs/book/](docs/book/index.md).
