# Changelog

## 0.1.0

The first version. From it on, nothing that works may break: the names of the OCaml library above its internals and
of the Cesia packages `cepheus` and `owl`, the wire protocol, the files on the disk, the commands and `cluster.toml`
stay as they are, or a later version reads and speaks both the old and the new.

### The database

- **An index of two properties**: `cepheus/within` (property 9), `Cepheus.within db [ (date, client) ]`, Cesia's
  `Date(within = "Client")` (and `Int`, `Bool`, `Money`, `Link`): the things of each value of a one-valued property in
  the order of another's of their kind, kept in every run (run format 10, a section `pairs` a part; format 9 read as
  it is, the first merge writing 10) and in the recent changes, as PostgreSQL's index on `(client, date)`. "The 3
  latest invoices of each client" (`Each`, `Limit: 3`) reads 3 rows a client, a page of one client's invoices by date
  reads its page; the same rows as without it, which the questions read until every run holds the pair. At 245,000
  invoices: the 3 latest of each client 30.8 ms (131 before, PostgreSQL's `LATERAL` 52.3), the last of each 12.4 ms
  (`DISTINCT ON` 115), a client's page 13.1 µs (an index scan 100); a write of either property 0.5 to 0.9 µs more a
  fact, of any other nothing; the run 1.9 MB larger (7.8 bytes a row), its open 7.3 to 8.6 ms, a merge about 30 ms
  longer (12 %). A
  database of format 9 opens and answers as before; a version before this one opens a database of format 10 by
  replaying its journal, and stops at a declared pair (it knows no property 9), nothing lost
  ([formats](docs/book/formats.md#run-dirsnapshotslo-20-digits-hi-20-digitsrun), [tutorial
  15](docs/book/tutorials.md#15-the-latest-invoices-of-each-client-read-off-an-index-of-two-fields),
  [benchmarks](docs/book/benchmarks.md#an-index-of-two-properties-2026-11-26-at-1-million-facts)).
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
  ranges (of ints, dates, money, things by their ids, and floats in IEEE 754's totalOrder); `Less` and `LessOrEqual` between two variables
  (the later one sought in the sorted index from the other's value, the inequality join of Khayyat et al. 2015);
  `Optional`, SQL's `LEFT JOIN` of one property (SPARQL's `OPTIONAL`, Pérez et al. 2009: a missing cell sorts last
  both ways); `Sum`, `Count`, `Min` and `Max`; pages with `Sort`, `Limit` and `After`; **reports**: `Avg`, `Count(x)`
  (SQL's `COUNT(DISTINCT x)`), `Values` (the different values of a group, a list: `array_agg`), `Quantile` (Hyndman
  and Fan's definition 7, `percentile_cont`; definition 1 with `discrete = true`, `percentile_disc`) and its sugar
  `Median`, `Variance` and `Stddev` (of the sample, or of the population), the means and spreads from exact sums (the
  same bits whatever the order of the rows and the number of cores, a watch's too), and `Trunc` (a date's second to
  millennium in an IANA time zone, read from the system's TZif files with their POSIX rules: PostgreSQL's
  `date_trunc(unit, d, zone)`) as a key of the rows ([reports](docs/book/cesia.md#reports-avg-countx-values-quantile-variance-stddev-trunc),
  tutorials [11](docs/book/tutorials.md#11-a-monthly-report-of-sales-by-client-in-the-companys-time-zone) and
  [12](docs/book/tutorials.md#12-the-median-and-spread-of-payment-delays-the-list-of-products-of-each-invoice));
  **windows**: `Running` (a running total, a moving mean of the last n rows, a running `Min`, `Max` or `Count()`, the
  row's number), `Rank` (`rank()`, `dense_rank()`) and `Prev` (`lag`), fields of `Give` computed over the answer's rows
  in `Sort`'s order (a report's groups too: `Running(Sum(Sum(t)))`, SQL's `sum(sum(t)) OVER`), before `After` and
  `Limit` (a page's running total goes on from the page before, read by one pass over the rows before it, none
  sorted), from exact sums taken out as a frame slides and a monotone queue for `Min` and `Max` (Leis et al. 2015,
  Lemire 2006), and **`Each`** (`PARTITION BY`; `Limit` each group's: the 3 latest invoices of each client, SQL's
  `LATERAL ... LIMIT 3`, and `Limit: 1`, `DISTINCT ON`), protocol 10 (`Wire.Over`); a watch refuses them
  ([windows](docs/book/cesia.md#windows-running-rank-prev-each), tutorials
  [13](docs/book/tutorials.md#13-a-monthly-balance-with-a-running-total-the-change-from-last-month-and-a-3-month-moving-average)
  and [14](docs/book/tutorials.md#14-the-3-latest-invoices-of-each-client-the-last-one-of-each-a-leaderboard-of-clients-by-revenue))
  ([questions](docs/book/concepts.md#questions), [Less and Optional](docs/book/cesia.md#less-lessorequal-and-optional)). `find`, `ask` and `fold` take a `?timeout`, past which they give
  `Error (Timeout _)`, a constructor added to `Cepheus.error` before the first release.
- **Links that name a kind**, SQL's foreign keys: a link property names a kind (`Link(to = "client")` in Cesia,
  `link_to` in OCaml, the facts `cepheus/to` and `cepheus/delete` of its property thing), and each value it takes is a
  thing of that kind, checked by the writer on the state after each group. When a group leaves a thing with no fact of
  the kind, the links to it follow their `on_delete`: `refuse` (the default) refuses the group, naming the kind, the
  thing, one linking thing and the property; `cascade` deletes the linking thing too (cycles end); `clear` retracts the
  link. The operation **`Delete (thing, kind)`** deletes a thing of a kind, its facts of the kind retracted at the
  writer, SQL's `DELETE`; a deletion and its links stay within the group's work budget, or nothing is done
  ([deleting a thing](docs/book/cesia.md#deleting-a-thing), [tutorial 10](docs/book/tutorials.md#10-a-client-with-invoices-cannot-be-deleted-an-invoices-lines-go-with-it)).
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
  version 10 (the windows and Each; 9: the aggregates of reports and Trunc; 8: the operation Delete and the links that
  name a kind); a program speaks 1 to 10 with a server of any of them. A token with rights per kind deletes a thing only if it may add to every kind the deletion can reach and read
  every kind whose links refuse it.
- A **replica** on another machine keeps a copy of every database over mutual TLS, promoted by hand with `cepheus
  promote`; three servers or more form a **Raft** cluster, which confirms a write once a majority holds it and elects
  a new leader by itself.
- In a Raft cluster ([the server](docs/book/server.md#a-cluster-of-three-raft)): a follower behind the leader's log
  start, or started on an empty data directory, takes a **copy of the databases** from the leader (runs, journal,
  session tables, vault), checked as `cepheus verify` checks one, then starts again on it (the role of
  InstallSnapshot); a server with no Raft state takes no part until a majority of the others said their terms and
  logs, so that a lost disk neither votes twice in a term nor elects a leader that lacks what it acknowledged; the log
  no longer grows without end for a dead server (five minutes, then a copy); groups past 8 MiB go through the log in
  pieces, applied whole or not at all, up to 256 MiB; the **vault's files** are replicated (`Put`, `Load`, `Erase`
  through the leader, one `vault.key` shared by the servers); `cepheus stop` on the leader **hands its leadership
  over** first (Timeout_now), the writes paused for one vote round; a damaged server takes the committed entries it
  lacks from any sound peer, so that a damaged majority elects a leader again. The peer protocol is at version 3; a
  peer of version 2 is still taken (a rolling upgrade).
- Commands: `cepheus serve`, `stop`, `status`, `token add|list|remove`, `cluster init|cert`, `replicate`, `promote`,
  `verify`, `backup`, `restore` ([commands](docs/book/server.md#commands)), and a systemd service with backups, a
  restore drill and what to watch ([production](docs/book/production.md)).
- **Operations as commands.** `cepheus verify DIR` checks a database's files and changes nothing: every frame of the
  journal, every page of the runs, the runs against the journal, the vault's records, each damage named (exit status
  1), a live database up to the frame being written (a frame that does not check while every byte of it is there is
  read again for a second, then damage: never cut in silence). `cepheus backup --config FILE DEST` copies every
  database of a running server, a replica's too, with no stop and no token, into `DEST/DATE`, named only once every
  copy is checked, cut after its last whole frame and forced; DEST is the user's own (one that others may write is
  refused), and a backup removes there only the `DATE.partial` folders a backup left, never through a link.
  `cepheus restore SRC DIR` restores one, opened and checked before it takes its name; `--to-group N` or `--to-time T`
  (exactly its digits and a day of the calendar) stops before a bad write, as PostgreSQL's point-in-time recovery,
  and the restored database writes in a new epoch, so that a replica holding the old history's later groups is
  refused rather than followed; `--replace` moves the database there aside under a name no folder has, never removes it, even one that crashed
  through a server's commit buffer (refused only while that buffer holds frames of it)
  ([backups](docs/book/production.md#backups), [verification](docs/book/operations.md#verification-scrubbing)). The
  backup script the production guide gave before still works, and its copies restore with `cepheus restore`.
- An answer the server holds while it builds it (a Find with Sort or aggregates, a watch's first answer) is bounded
  by its cells, rows times columns (8,388,608 a question, 33,554,432 for every connection's at once), past which it is
  `too_large`; a Find without Sort past them is asked again and sends its rows as the join finds them, holding none
  (the same rows in the same order), so that a cross product of patterns that share no variable can no longer exhaust the server's memory
  ([limits](docs/book/limits.md#questions)).
- A question's work at the server is counted in lookups (its candidates over the most patterns one variable has), and
  a question has at most 64 patterns, refused before they are decoded: repeating a pattern no longer multiplies the
  work a question may take.
- A connection keeps 1,024 watches at most and the server 65,536, and what their windows and groups keep counts
  against a connection's cells; past either, the Watch is `too_large`.
- Before Hello a frame is 4 KiB at most, and the reading buffers grown for long frames hold 64 MiB more at most,
  server-wide, a connection past it waiting for room: a peer that shows no token can no longer make the server hold
  16 MiB, nor many connections 16 MiB each.
- A connection has 10 s from its accept for its TLS handshake and its Hello, and the clock (that one, then
  `idle_timeout`) is checked inside the TLS handshake and inside a TLS record, so that a peer that sends a byte at a
  time is closed (Slowloris); on the peer port, 5 s the same way. At `max_connections` a new connection takes the slot
  of the oldest one that has shown no token, so that peers that connect and send nothing no longer keep programs out.
- No reply passes the frame limit, which every client refuses: a Get or an Open that would is sent in frames of the
  flag `more`, which the OCaml and Cesia clients join (one that fits is one frame, as before, and a reply of an
  earlier server is read as before); a name is 255 bytes at most and a text 16,773,120 through the server, and a group
  whose receipt would pass a frame is refused before it is applied, where before it was applied and its receipt
  could not be read. A token that may add to one kind can no longer make a database unopenable.
- A database's files are 0600 and its folders 0700, and a data directory that lets its group or others in is made the
  server's alone at its start (the log says so), so that its facts, in the clear on the disk, are no longer readable
  by every user of the machine.
- The Unix socket is 0660 once bound, so that the group of the socket's directory may connect, as the production page
  says (it got EACCES under the usual umask).
- A second Hello on a connection is `invalid`: a connection's token, rights and session stay those of its first.
- An error of the server's own files reaches a program as its code and a fixed message, its paths in the log only.
- A connection whose replies not yet sent pass 1 MiB has no more of its requests decoded until they are sent, so that
  many small requests for large replies, never read, no longer pile their replies up in the server's memory.
- **Import and export.** `cepheus import DB FILE --kind KIND` loads the things of a kind from CSV (RFC 4180, a header
  row; PostgreSQL's rule for an empty field and "") or JSON lines, through the server with a token that writes:
  each column a field (`--map` when the names differ), each value checked against its type (money read exactly from
  its digits, dates as RFC 3339, texts UTF-8 without NUL), links found by the key of the thing linked (`--link`),
  unique values checked against the database and the file. The file is checked whole first: a bad row stops the
  import with its line and nothing is written (`--skip-bad` writes the good rows and lists the bad ones;
  `--upsert` changes the thing a unique value finds); then it is written in large groups of up to a million
  operations, parsed by several domains while the server writes; a failure there, the connection lost included,
  names the groups written. A quote opens a quoted field only at a field's start, so that a stray one makes its line
  alone bad (PostgreSQL's COPY reads it as opening a quoted part, and loads the lines up to the next one as one row);
  blank lines are read through, never held; a record's fields are made up to the header's count, its JSON holds at
  most 100,000 values. `cepheus export DB --kind KIND [--format csv]` writes
  every thing of the kind at one group, named on stderr, its asserted facts and its links as their keys, read from one
  view on the server's machine. At 10 M facts (120,482 clients, 2.4 M invoices linked by e-mail), medians of seven rounds: 28.5 s, beside PostgreSQL's COPY and join 43.7 s and SQLite's .import 9.71 s; a file of 10 GiB checked whole in 244 MB ([import and export](docs/book/operations.md#import-and-export)).
- A question has a **time**: `[clients] question_timeout` in `cluster.toml` (seconds, 30 by default, 0 for none), and a
  program's shorter `timeout` (from Cesia `Find(..., timeout = 2)` and `Watch`; from OCaml `?timeout` on `Client.find`
  and `watch`, protocol 6), a longer one only from an admin token; past it the question ends with the code `timeout`,
  its message naming the time. It is looked at every 1,024 candidates of each domain (a read of the monotonic clock:
  under 1 % of a question, measured), as SQLite's progress handler and PostgreSQL's `statement_timeout`. Before it a
  question's only bound was a budget of 1,000,000,000 lookups. A question that took more than 30 s now ends `timeout`: give
  `question_timeout = 0`, or the program's own time from an admin token, to keep it. Writes have no time.
- A question whose program closed its connection **stops**, its domains given back at once (the socket looked at with
  `POLLRDHUP` at most every 10 ms, as PostgreSQL's `client_connection_check_interval`); before, it ran to its end.
- **What is slow shows.** `[log] slow_ms` in `cluster.toml` (200 ms by default, 0 for none): a question or a write
  that takes that long or more at the server gets a line in its log, with its database, its token's name, its time,
  its outcome, a question's candidates, rows and shape, a write's operations, properties and group, each constant
  written `?`: no value of the data and no token (a test searches the log for each of its values), 10 lines a second
  at most ([slow questions and writes](docs/book/production.md#slow-questions-and-writes)). The log of a server that
  had none of these lines gets them from 200 ms on: give `slow_ms = 0` to keep it as it was. `cepheus status` keeps
  each of its lines and their order, and adds among them each database's questions and writes (counts since the
  start, p50, p99 and maximum over the last minute, a write's to its group durable, within 3.1 %), merges (count,
  time, bytes), journal and runs bytes, the page cache's room, hits and misses, and the disk's free bytes;
  `cepheus status --format prometheus` prints them in Prometheus's text format, for node_exporter's textfile
  collector, rather than a port of the server. Timing every question and write: a point question answered before the
  next is asked costs the server 215 instructions more (+0.85 %), the clock read as often as before (the idle limit's
  read is its start, its end the idle limit's last request, now on the monotonic clock); with 32 in flight, +4.1 % of
  the server's cycles (a clock read at each question's end); a write's fsync hides it
  ([what timing costs](docs/book/production.md#what-timing-costs)). `Cepheus.Histogram.create` takes `?bits`.
- **Domains**: the databases' writers and syncers share the writers' domains (as many as the cores), not a domain each,
  so a server of 200 databases holds 21 domains, where before about 120 databases took every domain OCaml allows (128
  a process) and the next failed; large questions take their helping domains from one pool of the process (the cores
  less one, parked between questions and gone after a second idle), where each spawned up to 7 domains of its own: 30
  large questions at once all answer (before, about 18 took every domain, and the next failed `internal`), and one
  takes 20 % less time at the server (10.5 ms against 13.4 ms, Q4 at 2 M facts), its domains no longer spawned. A merge,
  a change of the rules or a part of a snapshot's reads past the process's domains runs on a thread, or on fewer
  domains. The server's status says `domains`, `domains.cap`, `questions.helpers`, `questions.timed_out` and
  `questions.cancelled`.
- A Unix socket's path longer than Linux's 107 bytes is refused by the server at its start and by a program's
  connection, each naming the path and its length; before, the server's log said only `PATH: File name too long`.

### From Cesia

- The package `cesia/cepheus`: `Connect`, kinds with `Kind`, `Insert`, `Get`, `Update`, `Delete` (of a thing of any
  kind, its links followed), `Write` with `Expect` and `Incr`, `Find`, `Watch`, rules with `Rule` and `Define`, `Fork`
  for tests, files with `Put`, `Read`, `List`, `Delete` and `Erase` ([Cepheus from Cesia](docs/book/cesia.md)); a
  `Link(to = "client", onDelete = "cascade")` names the kind it links to. Nothing loads before the package's first
  call.
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

- **A question splits across the cores past a narrow first level, and reports keep their groups in flat tables**
  (2026-11-26, 1 M facts, 8 domains on 4 cores, 5 rounds alternated with main's binaries): a level of 20,000
  candidates or more is split wherever it comes in the order; the first level of two candidates or more past those of
  one, when the planner expects 80,000 candidates of work, runs until its candidates' measured work says the rest is
  worth splitting; the candidates of every domain count together against the question's budget, which never refuses
  what it took before. A Group's groups sit in one table of open addressing a domain (a row costs a hash and no
  allocation; a mean's exact sums in four ints a group; the bags of small groups in one table a column, of large ones
  a table a group). The invoices below
  one invoice's total 28.0 ms against 57.5 (PostgreSQL 19.0); a report by city 2 to 5 times faster (`Sum` 9.7 ms
  against 46.5, PostgreSQL 57.8), by client 3 to 4 times (the mean invoice 36.5 ms against 151, PostgreSQL 65.5), Cepheus
  now ahead of PostgreSQL at every number of groups; the questions of before as fast as they were (Q1 to Q5 0.97 to
  1.04, small questions in loops 0.96 to 1.03)
  ([benchmarks](docs/book/benchmarks.md#questions-split-past-a-narrow-first-level-and-lighter-groups-2026-11-26-at-1-million-facts)).
- **A page sorted by a thing reads its page** (2026-11-26, 5 rounds alternated with main's binaries): a list of a kind
  by its things' ids (`Sort` on the thing, `After` its last row), or the things of one value of a field (a tenant's),
  reads the next things of the pattern's property from the cursor, in the order of their ids that each run's column
  keeps, where the heap walked the whole kind at every page. A page of 51 of 10,000, 100,000 and 1,000,000 things
  24 to 27 µs against 2.1 to 2.8, 8.5 to 11 and 81 to 99 ms, PostgreSQL 18.6's keyset query on its primary key 36 to
  62 µs; in a program's own memory (every fact in the delta) 45 to 50 µs against 23 to 26 ms at 100,000; Centauri's
  admin lists its 100,005 clients, every page of 50 in turn, in 40.6 s where it took 94.4. A range of a thing reads its
  things from its first, and `Above`, `Below` and `Between` take a thing's id, where they refused a link
  ([pages](docs/book/cesia.md#sort-limit-and-after-pages),
  [benchmarks](docs/book/benchmarks.md#pages-of-a-kind-by-its-things-ids-2026-11-26-at-10000-to-1000000-things)).
- **The cases PostgreSQL still won, caught up** (2026-11-26, 1 M facts, 5 rounds alternated with main's binaries and
  PostgreSQL 18.6): a whole sort of 4,096 rows or more whose first keys are inline words is a radix sort of 11 bits a
  pass on one 62-bit key of those words (Knuth's 5.2.5, Herf 2001), ties sorted again by the comparisons when the key
  is cut; `Each` with `Limit` compares a binding with its group's k-th row before making it a row, and keeps each
  group's buffer in order up to `Limit: 32`; `Ask`'s bindings in one buffer a domain and `Cepheus.ask`'s rows made
  from them; a cascade's or a clear's retractions gathered and made by one `Store.set_sorted`, itself sorting 256
  changes or more by radix sorts. A rank of one group 213 to 96.1 ms (PostgreSQL 181: Cepheus now 1.9 times faster,
  where PostgreSQL was 1.2), of 100 and 10,000 groups 2 times faster; the last invoice of each client 102 to 88.8 ms
  (`DISTINCT ON` 113); the 3 latest of each 137 to 106 (`LATERAL` with its index 53.8: PostgreSQL still 2.0 times
  faster, its B-tree on `(client, date)` reading 3 rows a client, Cepheus every invoice); `Less` 10.8 to 8.50 and 31.4
  to 21.9 ms, `Optional` 16.8 to 15.1 with every value made (PostgreSQL 3.64, 20.0 and 12.1; as the server answers them
  3.70, 10.5 and 10.0); a cascade of 10,000 lines 30.0 to 21.8 ms (PostgreSQL still 4.2 times faster: it marks a row
  deleted and touches its indexes at `VACUUM`) ([benchmarks](docs/book/benchmarks.md#the-cases-postgresql-still-won-2026-11-26-at-1-million-facts)).
- **Rows with every value made, and cascades** (2026-11-26, 1 M facts, rounds alternated with main's binaries and
  PostgreSQL 18.6, each side in the same scope): `Optional`'s rows written into the fold's shared buffer,
  `Cepheus.ask`'s rows gathered in chunks and listed once (a row of up to 4 columns made in place), the server's
  `Optional` rows pushed as words, `Less`'s bounds with no closure and a counted slice read straight from its run, the
  values a property takes read from its value index's rank words; a cascade's maps of ints built in one pass
  (`Store.IM.of_sorted`, O(n), where unions of halves made some 65 words a binding) and its changes gathered in arrays.
  With every value made, beside a program that receives PostgreSQL's rows through libpq: the `Less` check 7.58 to
  4.47 ms (PostgreSQL 6.69), the `Less` range 21.9 to 18.2 (28.7), `Optional` over every client 15.7 to 8.82 (17.5); the
  engine alone, beside `EXPLAIN ANALYZE`: 3.62 to 2.24 (3.68), 10.1 to 8.19 (19.4), 9.52 to 5.67 (12.1); a cascade of
  10,000 lines 19.9 to 16.7 ms (PostgreSQL 4.92, still 3.4 times faster: it marks its rows and leaves its indexes to
  `VACUUM`), a `clear` of 10,000 notes 9.50 to 6.21 ms; Cepheus on 8 domains, PostgreSQL in one process (on one core
  PostgreSQL's sequential scan still answers the `Less` check 1.3 times faster). The same answers, of the same types, in
  the same order; the same bytes on the disk
  ([benchmarks](docs/book/benchmarks.md#rows-with-every-value-made-and-cascades-2026-11-26-at-1-million-facts)).

### Fixes

- A `Sum` of ints or money past the 63 bits of an Int is refused, never given wrapped around. A report's sum (and a
  watch's, kept by difference) wrapped silently: four times the largest Int summed to -4, three times to the largest
  less 2, a total that looked right. Each group's Sum now keeps, beside its word, the times it wrapped (one test of
  signs an addition, a carry made at the first wrap), so a question is refused (`invalid`, `Sum of invoice/total
  passed the 63 bits of an Int in the group "Lyon": ...`) exactly when its exact total is no Int, whatever the order
  of the rows and the number of cores: a total that passes the largest Int and comes back is given; a watch of it ends
  with that error at the write that takes it past, the other watches go on. PostgreSQL gives such a total as a `numeric`;
  SQLite 3.54.1 refuses a sum as soon as a partial sum overflows, even when its total fits
  ([comparison](docs/book/comparison.md#sums-past-63-bits), [limits](docs/book/limits.md#questions)). The cost,
  measured ([benchmarks](docs/book/benchmarks.md#sums-checked-past-63-bits-2026-11-26-at-1-million-facts)): about 7
  instructions a row, no slowdown beyond the noise of the rounds (a `Sum` of 245,000 rows moved by 1 to 5 %, as the
  aggregates it does not touch did).
- `Trunc` of a date of the least ones (146 million years before 1970) to a year, a decade, a century or a millennium
  that starts before the least date is refused (`invalid`, naming its field): its start, 1000 times its seconds,
  wrapped to a date 146 million years after 1970. The least date's own second wrapped the same way (the floor of its
  milliseconds by 1000 negated the least int): now its floor is taken without it, and refused too.
- A running `Sum` past 63 bits names the field it sums (`Running's Sum of invoice/total passed ...`); a `Quantile`
  between two values of money or dates is kept between them when their difference passes the ints.

- `test/server_raft.ml` waits for the two damaged servers' line of the damage set aside, with a deadline of 30 s,
  where it read their logs once after their sockets answered: 1 run in 70 failed under load.
- `tools/test.sh` names the checks that failed: each step's output goes to a log of its own, and a step that fails
  shows its `FAIL` lines, the end of its log and the log's path, which stays, where only its count showed (`vault_unit`
  1 failure of 4,913, `rulechange` 6 of 192, under load, with no name). A step that passes shows its count, as before.
  `bench/transfer.sh` and `bench/ops.sh` serve on a port the system gives free, where one derived from the process id,
  or 7400, could be another server's.
- A local reader's runs that a merge replaced leave the program's page cache once its states on the new base are
  published, as the server's do, and the pages that reads begun before take back leave at the next merge. Their pages
  stayed until the cache, 256 MiB, was full, a base's worth at each merge, and the reads made while the states moved
  to the new base read the old one back for good: under TechEmpower's updates (20 local reads and a write of 20 facts
  a request, merges every few seconds), a Cesia program that only followed the database grew from 76 to 322 MB in 20
  minutes, one that read and wrote to 119 MB with the first half of the fix; now 51 and 64 MB, level from the 13th
  minute (measured side by side, 2026-11-25; [Cesia](docs/book/cesia.md#what-it-costs)).
- `cepheus verify` (and the check of a backup) named as damage a run whose journal position is the end of a segment
  that the next one follows (the frame after the run's groups began a new segment): a whole database was taken for a
  damaged one. Such a position is now the start of the next segment's first frame, as the engine reads it.
- `cepheus restore --replace` twice over one folder within a second failed (`ENOTEMPTY`): the folder moved aside took
  the name of the one moved aside before. It now takes a name no entry has (`-2`, `-3`, ...), never renamed over
  another folder.
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
