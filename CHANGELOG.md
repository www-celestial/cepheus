# Changelog

## 0.1.0

The first version. From it on, nothing that works may break: the names of the OCaml library above its internals and
of the Cesia packages `cepheus` and `owl`, the wire protocol, the files on the disk, the commands and `cluster.toml`
stay as they are, or a later version reads and speaks both the old and the new.

### The database

- A database of **facts**, `(thing, property, value)`: the entity–attribute–value model, Datomic's datoms. A
  property is declared once with its type (`Int`, `Float`, `Bool`, `Text`, `Date`, `Money` with 0 to 18 decimal
  digits, `Link`), and whether it takes many values or a unique one ([concepts](docs/book/concepts.md)).
- A write is a **group**: a transaction of `Add`, `Retract`, `Expect` (a value the group needs, checked against the
  state just before it: a read-then-write that another write changed meanwhile is refused) and `Incr` (a counter
  raised in the group itself, and with `into` its new value written into another fact: invoice numbers with no gap),
  applied all or nothing, with who wrote it and why. The journal keeps every group for ever
  ([groups](docs/book/concepts.md#groups-a-write-is-a-transaction)).
- One writer a database, many readers: the writes are strictly serializable, and a reader takes a **view**, the
  exact state after one group, which never changes and is read with no lock
  ([isolation](docs/book/concepts.md#isolation-exactly-what-a-reader-and-a-writer-see)).
- **Questions** of patterns joined by Generic Join, a worst-case optimal join (its time is bounded by the largest
  answer the data could give, the AGM bound, not by the sizes of the steps between); `Not`, `Or`, `In`, `Prefix` and
  ranges; `Sum`, `Count`, `Min` and `Max`; pages with `Sort`, `Limit` and `After`
  ([questions](docs/book/concepts.md#questions)).
- A **fork** is a database in the program's memory that starts as a view: written to with every check, never to the
  disk, made without a copy; the base of an application's tests and of what-if questions
  ([forks](docs/book/concepts.md#forks)).
- On the disk: a journal (a write-ahead log: every group is written and forced there before it is confirmed), and
  runs, the sorted files of a log-structured merge tree in levels, each page checked by its CRC-32C at every read
  ([how it works](docs/book/architecture.md), [file formats](docs/book/formats.md)).

### What it promises

- 24 guarantees, each with its exact conditions, its proof and the test that checks it
  ([guarantees](docs/book/guarantees.md)): a confirmed group survives a crash of the process and a power loss (G1); a
  group is all or nothing (G2); after a recovery the groups are a prefix of the history (G3); damage to durable bytes
  is found and never dropped in silence (G6); a merge leaves the old runs or the new one, whole (G12); after a failed
  fsync no view shows a group a power loss could take back (G13); a write sent again after a lost reply is applied
  once (G14); a program's reads in its own memory are linearizable (G15); a token reads and writes only what its
  rights allow (G16); the rules' facts are exactly what the rules derive (G17), constraints hold (G18), a rule change
  takes effect at one group (G19), `why` gives a true proof (G20); after each message of a live question, the rows a
  program holds are exactly the question's answer at a durable group (G21); a file is durable before the facts that
  name it (G22), no wrong byte of a file is ever served (G23), and an erased owner's files are unreadable wherever
  their bytes went (G24).
- Checked by unit and property tests, a deterministic simulation of the disk's faults (power losses, torn and lost
  writes, failed fsyncs, crashes inside any disk call), an exhaustive enumeration of the crash states of small
  journals and merges, real `kill -9` rounds, and 13 TLA+ models whose 38 variants that each drop one part of a rule
  must all break ([testing](docs/book/testing.md)).

### Rules

- Datalog **rules** kept by the writer: their derived facts are facts of every view, kept up to date at each group
  by semi-naive evaluation, and taken back by Backward/Forward when their proofs go; `Never` makes a rule a
  constraint, which refuses the group that would give it an answer; `why` gives the proof of a derived fact
  ([rules](docs/book/rules.md)).
- **OWL 2 RL**, the W3C's ontology rules, as a library of rules (`Cepheus.Owl`; from Cesia, the package `owl`),
  `owl:sameAs` included, kept by classes of equal things.
- A change of the rules (but one that makes new things) is computed in the background while the writer goes on, and
  takes effect at one group.

### The server

- `cepheus serve --config cluster.toml` holds the databases, as PostgreSQL's server does: programs connect through a
  Unix socket or TCP with TLS 1.3, each with a **token** whose rights are given database by database, and down to
  kinds of things ([the server](docs/book/server.md)).
- Many databases share one fsync a round through the commit buffer; a program on the server's machine reads in its
  own memory, linearizably, with no round trip (0.22 µs a point read); live questions (`Watch`) send each change of an
  answer once its group is durable, and with `Sort` and `Limit` keep the first rows of an order as they change (the
  ten latest payments: ten rows held, a row that leaves them replaced by one page read after the last), the rule
  model-checked ([Sort and Limit in a watch](docs/book/cesia.md#sort-and-limit-in-a-watch)). The wire protocol is at
  version 5 (a Watch's Sort and Limit); a program speaks 1 to 5 with a server of any of them.
- A **replica** on another machine keeps a copy of every database over mutual TLS, promoted by hand with `cepheus
  promote`; three servers or more form a **Raft** cluster, which confirms a write once a majority holds it and elects
  a new leader by itself.
- Commands: `cepheus serve`, `stop`, `status`, `token add|list|remove`, `cluster init|cert`, `replicate`, `promote`
  ([commands](docs/book/server.md#commands)), and a systemd service with backups, a restore drill and what to watch
  ([production](docs/book/production.md)).

### From Cesia

- The package `cesia/cepheus`: `Connect`, kinds with `Kind`, `Insert`, `Get`, `Update`, `Write` with `Expect` and
  `Incr`, `Find`, `Watch`, rules with `Rule` and `Define`, `Fork` for tests, files with `Put`, `Read`, `List`,
  `Delete` and `Erase` ([Cepheus from Cesia](docs/book/cesia.md)). Nothing loads before the package's first call.
- A real app built step by step on it, invoices and clients, from `cesia new` to production, with its tests in
  Firefox and the time of every page ([a real app](docs/book/app.md)): its list a page of one sorted question, whose
  links keep working from one version of the app to the next, and a dashboard of live totals and of the ten latest
  payments.

### Files

- The **vault**: files kept in the database, cut into chunks by their content (FastCDC), each stored once,
  compressed (LZ4, or Zstandard for cold files), sealed with AEGIS-256 under its owner's key, read whole or by ranges
  and checked at every read; erasing an owner destroys the key ([the vault](docs/book/vault.md)).

### Speed, beside PostgreSQL 18.6

Measured on one laptop (Intel i7-4720HQ, 4 cores, 11 GB, a SATA SSD), every side under a lock that keeps the
machine's other heavy jobs away, the same data and the same answers on each side
([benchmarks](docs/book/benchmarks.md)).

The invoices app's questions (2026-11-19), one client, µs, the median of 101 rounds alternated with its 95 % interval
(order statistics), the ratio paired by round ([a real app](docs/book/app.md#14-what-it-costs)):

| question | Cepheus | PostgreSQL 18.6 | Cepheus / PostgreSQL |
|---|---:|---:|---:|
| a page of 20 invoices, sorted | 115 [114, 116] | **42 [42, 42]** | 2.71 [2.69, 2.76] |
| the same page, 50,000 deep | 115 [115, 116] | **45 [44, 45]** | 2.58 [2.55, 2.59] |
| invoices by a prefix of the bill-to name | 540 [537, 545] | **161 [160, 161]** | 3.35 [3.34, 3.38] |
| clients by name | 88 [87, 88] | **36 [36, 37]** | 2.41 [2.39, 2.44] |
| clients by a prefix of the name or of the e-mail (`Or`) | **485 [483, 488]** | 1,320 [1,312, 1,323] | 0.37 [0.36, 0.37] |
| the total not paid (`Not`, `Sum`, `Count`) | **8,363 [8,291, 8,517]** | 10,435 [10,410, 10,466] | 0.81 [0.80, 0.82] |
| an invoice and its lines | **23.1 [22.9, 23.1]** | 49 [49, 50] | 0.47 [0.46, 0.47] |
| a durable update of one invoice | **3,040 [2,989, 3,074]** | 3,088 [3,012, 3,219] | 0.95 [0.92, 0.99] |

- Since this table, a page of invoices is one question (2026-11-20): in the app's own memory 62 µs against the 113 of
  the page of keys then rows, 0.550 [0.535, 0.564] paired by round, and the prefix 1.053 [1.041, 1.063]; the table is
  measured again for the release ([a real app](docs/book/app.md#14-what-it-costs)).
- Where PostgreSQL still wins: a sorted page 2.7 times, a page deep in the list 2.6 times, a prefix the order does not
  follow 3.4 times, a sort on a text 2.4 times. Its B-tree gives a row's fields in one read, where Cepheus keeps a fact
  a property and reads each field from its index ([why](docs/book/app.md#14-what-it-costs)).
- Server against server, 1 M facts (2026-11-19, 101 rounds; PostgreSQL's time over Cepheus', paired by round): a point
  read through the Unix socket 9.68 µs against 24.91 (2.62 times), with TLS 1.3 41.3 against 52.3 (1.27), 16 reads in
  flight on one connection 1.30 µs a read against PostgreSQL's pipeline of 16 at 9.05 (6.95), 8 clients at once 3.71 µs
  a read against 6.27 (1.71) ([the server](docs/book/server.md#speed-beside-postgresql)).
- 10 million facts in the process (2026-11-11, 21 runs): every fact of an invoice by its id 0.39 µs (PostgreSQL 4.73
  in its server, 26 through its socket), the triangles of a follow graph on 3 cores 100 ms against 602, the load of
  the 10 M facts 5.13 s against `COPY`'s 30.87; durable writes on par with PostgreSQL, both bound by the disk's fsync
  ([comparison](docs/book/comparison.md)).

### Fixes

- A newest journal segment whose header does not check while it holds bytes past it, or where the newest run
  resumes, is refused at open as damage (G6). Recovery took it for a segment torn at its creation and removed it, so
  one flipped bit in its 40 bytes opened the database without that segment's groups, with no error.
- A run a merge replaced is closed, and its disk space freed, once no view reads it. The cache's queues kept an
  entry for each of its pages, which held the run and its open file until the cache was full: with the data inside
  the cache (1 GiB by default), every replaced run stayed open, its space held while `du` showed it gone.
- From Cesia, `Above`, `Below` and `Between` keep exactly the values inside their bounds. A bound between two cents
  or two milliseconds was rounded to the nearest before the strict step, so `Above(price, 10.005)` left out 10.01
  and `Between(price, 10.004, 10.016)` gave 10.00 and 10.02; now it is rounded toward the inside of the range. And
  `Above(n, v)` with the largest Int, or `Below` with the least, wrapped around and gave every row: now none.
- A database written through the server's commit buffer has the removal of its clean-close marker forced at open,
  before its journal is written. A power loss soon after could bring the marker back, and the database then opened
  alone, without the frames the buffer alone held: confirmed groups missing, instead of the refusal (`Busy`).
- The work of the rules is bounded, not only their derived facts: the candidates their patterns read may be 10 times
  the budget of derived facts (`work_budget`), else the group or the change is refused, naming the rule. A body of
  three things that share a tag read $n^3$ candidates for $n$ heads, under the budget: one write of 400 facts held the
  writer 13 s, 1,600 about 15 minutes; refused now in 0.06 s.
- From Cesia, a date of $4.6 \times 10^{15}$ s or more either way, whose milliseconds pass the Ints, and money of the
  least Int are refused (`invalid`): they were stored wrapped around (5e15 s read back as -4.2e15 s, the least Int's
  cents as 0).
