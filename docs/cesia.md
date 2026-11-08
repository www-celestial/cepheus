# Cepheus from Cesia

This chapter is for programmers who write in [Cesia](https://github.com/www-celestial/cesia): how a Cesia program
reaches a Cepheus database, writes to it, reads it and asks it questions, what each call gives, what it costs, and
what it guarantees. The examples below run as written, against a real server, each time the tests run
(`test/cesia.sh`): what follows each one is what it printed.

A Cesia program reaches a database the way a program reaches PostgreSQL: through a server, `cepheus serve`
([server](server.md)). There is one way: `cepheus.Connect`. On the server's machine the same call reads in the
program's own memory; elsewhere it goes to the server over TLS. The program's code is the same in both places.

## The package

The client is a **native package** of Cesia: Cesia code (`cesia/cepheus/cepheus.ce`, the functions documented below)
over an **engine**, OCaml compiled to machine code (`cesia/native/`): Cepheus's own reader, its question engine
(Generic Join) and its protocol client, in one file that Cesia loads at the first call of the package. A native
package is the way Cesia runs OCaml that comes from another project: the engine is compiled once against Cesia's
native interface, `Cesia_v1`, whose definition never changes once released, so the same file loads in every later
Cesia built with the same OCaml (Cesia's book, chapter "Native packages").

A program takes the package as a dependency and names it in its `use`:

```toml
# cesia.toml of the program
[deps.cepheus]
from = "github.com/www-celestial/cepheus"
version = "v0.1.0"
take = ["cesia/cepheus"]
```

```text
use deps/www-celestial/cepheus/cesia/cepheus
```

The engine is the file `native/cepheus-TAG.cmxs` of the package, where `TAG` is what `cesia.Native()` gives, as
`1-ocaml5.5.0-linux-x86_64`: the version of the native interface, the OCaml that built this Cesia, and the system.
Like every file of `deps/`, it loads only as `cesia.lock` says it was installed (its BLAKE2 fingerprint).

**The permission.** An engine is machine code that runs with the program's rights: Cesia's permissions stop at its
door, so running it needs the trust `native=cepheus` (the label of the dependency), as a C library needs `ffi=`:

```text
cesia run --allow native=cepheus,env shop.ce
```

`env` is for `sys.Env`, which the examples use to read the address and the token. The package asks Cesia for the
permission to read the certificate file it is given (`ca`); it cannot ask for `net=`, which Cesia's native interface
does not offer: with `native=cepheus` the program may reach any server.

**Start-up.** Nothing of the engine loads before the package's first call: a program that uses the package pays at
its start only the reading of the package's Cesia code, as for any package, and Cesia's own start-up does not change
([measured](#what-it-costs)). The first call loads the engine: the check of its fingerprint, the dynamic linking of the
engine and of OpenSSL's libraries, once a process.

## Connect

```cesia
use deps/www-celestial/cepheus/cesia/cepheus
use std/io
use std/result
use std/sys

Client = cepheus.Kind("client", {Name: cepheus.Text(), City: cepheus.Text(), Email: cepheus.Text(unique = true)})
Invoice = cepheus.Kind("invoice", {Client: cepheus.Link(), Total: cepheus.Money(2), Status: cepheus.Text()})

db = result.Unwrap(cepheus.Connect(sys.Env("CEPHEUS_URL"), [Client, Invoice], token = sys.Env("CEPHEUS_TOKEN")))
io.Print(cepheus.Get(Client, 1, db))
```

```text
Ok(missing)
```

`cepheus.Connect(url, kinds, token = missing, ca = missing)` gives an `Ok` of the database, to pass to every other
call, or an `Err`. Here the program reads the address from `CEPHEUS_URL`, as a program configured by its environment
does; written out, it is:

```text
cepheus://srv1:7400/shop                     the database shop of the server srv1, port 7400 (the default)
cepheus://localhost:7400/shop?socket=DIR     the Unix socket in DIR instead of /run/cepheus
```

What `Connect` does, in order:

1. **Local or remote.** A **Unix-domain socket** is a channel between two programs of one machine, named by a path:
   it cannot cross machines, so a program that reaches the server through one is on the server's machine. If the URL
   names a socket folder (`?socket=`), the package connects through `DIR/.s.cepheus.PORT`; otherwise, if
   `/run/cepheus/.s.cepheus.PORT` exists and the host is an address of this machine (the package checks by binding
   a UDP socket to it, which only a local address allows), through that one; otherwise over TCP with **TLS 1.3**,
   the encryption of the connection, which needs `ca`, the file of the cluster's certificate authority, to check that
   the server is the cluster's (`cepheus cluster init` makes it).
2. **The token.** The program shows its token, a secret made by `cepheus token add NAME --database shop=write`; the
   server answers with the rights of that token on each database: `read` or `write` (G16).
3. **The kinds.** The properties of the kinds the program gives that the database lacks are declared in one group;
   a property declared already with another type is an `Err` with Code `"invalid"`.
4. **Local reads.** On the server's machine the package then **follows** the database: the server passes it the
   database's files, already open, and then every group it writes, which a domain of the package (an OCaml unit of
   parallelism, a system thread of its own) applies to a state in the program's memory. From then on `Get` and `Find`
   read that state, with no round trip to the server ([local reads](#local-reads)).

`Connect` waits in its own fiber: its work at the server (the handshake, the declarations, which are a write, and the
Opens) runs on a domain of the package while the program's other fibers run. A peer that takes the connection and
does not answer (a hung server, another program on the port) is given up after 5 s for the handshake (connect, TLS,
Hello), with an `Err` of Code `"unreachable"` ([limits](limits.md#the-server)).

One connection serves every fiber of the program (a **fiber** is one of Cesia's light threads: many run on one core,
each waiting without holding the others): see [many fibers, one connection](#many-fibers-one-connection).
`cepheus.Close(db)` ends it; any call on it after gives an `Err` with Code `"closed"`.

## Kinds, and the values they hold

Cepheus keeps **facts**: a fact is a triple *(thing, property, value)*, "invoice 70021 has the status unpaid". A
**thing** is a number, its id; a **property** has a name, a type, and says whether a thing may have several values of
it (`many`) and whether two things may share a value (`unique`). This is the entity–attribute–value model
([concepts](concepts.md)).

A **kind** groups the properties of a sort of thing under field names. `cepheus.Kind(name, fields)` declares one: a
name of small letters, digits, `_` and `-`, and a map of fields, each a type. Its property in the database is the
kind's name, a slash and the field's: `client/City`. The value it gives is a map of its fields, each a property to
name in questions and in `Write` (`Client.City`), and the field `kind`, which the package keeps for itself:

| Type | The property's values | In Cesia | Example |
|---|---|---|---|
| `cepheus.Text()` | a UTF-8 text | a Text | `"Lyon"` |
| `cepheus.Int()` | a whole number of 63 bits | an Int | `42` |
| `cepheus.Float()` | a 64-bit float (IEEE 754) | a Float (an Int is taken too) | `2.5` |
| `cepheus.Bool()` | true or false | a Bool | `true` |
| `cepheus.Date()` | an instant in UTC, kept in milliseconds since 1970 | a number of seconds since 1970, as `sys.Now()` gives; read back as a Float | `1794268800.25` |
| `cepheus.Money(scale)` | an exact decimal of `scale` digits after the point (0 to 18), kept in minor units | a number (Int or Float), rounded to the scale; read back as a Float | `1200.5` |
| `cepheus.Link()` | another thing of the database | its id, an Int | `65536` |

Each takes `unique = false` and `many = false`. Money is exact in the database (an integer of minor units, so sums are
exact there, `Sum` included) and a Float in Cesia: an amount of up to 15 significant digits, as 1,234,567,890,123.45,
written and read back gives the same minor units (a 64-bit float is within half a unit of it); beyond, its last digits
round.

## Insert, Get, Update

```cesia
ada = result.Unwrap(cepheus.Insert(Client, {Name: "Ada Martin", City: "Lyon", Email: "ada@example.com"}, db, by = 7, why = "signup"))
io.Print(ada)
io.Print(cepheus.Get(Client, ada, db))
```

```text
65536
Ok({Name: "Ada Martin", City: "Lyon", Email: "ada@example.com"})
```

- `cepheus.Insert(kind, fields, db, by = 0, why = "")`: a new thing with these fields, in one **group** (a write of
  several facts, all or nothing, kept for ever in the history with `by`, the id of who wrote, and `why`): an `Ok` of
  its id. A field left out has no fact; a field of `many` values takes a list.
- `cepheus.Get(kind, id, db)`: an `Ok` of the map of the thing's fields of this kind, `missing` for a field it has no
  value of, a list for a field of `many` values (empty when it has none); an `Ok` of `missing` when the thing has none
  of the kind's facts (as the first example showed).
- `cepheus.Update(kind, id, fields, db, by = 0, why = "")`: new values of these fields, in one group, each replacing
  the field's value (a property of one value keeps one): an `Ok` of the group's number. A field of `many` values
  changes with `Write` (`Add` and `Retract`), so that what it adds and removes is written out.

As everywhere in Cesia, the database comes last: `db then cepheus.Get(Client, ada)` reads the same.

```cesia
for total in [1200, 80.5]
  result.Unwrap(cepheus.Insert(Invoice, {Client: ada, Total: total, Status: "unpaid"}, db))
end
bo = result.Unwrap(cepheus.Insert(Client, {Name: "Bo Lind", City: "Paris", Email: "bo@example.com"}, db))
result.Unwrap(cepheus.Insert(Invoice, {Client: bo, Total: 10, Status: "paid"}, db))
io.Print(cepheus.Update(Client, bo, {City: "Lyon"}, db))
io.Print(cepheus.Get(Client, bo, db))
io.Print(cepheus.Insert(Client, {Name: "Eve", Email: "ada@example.com"}, db))
```

```text
Ok(8)
Ok({Name: "Bo Lind", City: "Lyon", Email: "bo@example.com"})
Err({Kind: "cepheus", Code: "unique", Message: "client/Email \"ada@example.com\" is taken"})
```

## Write: groups of facts, all or nothing

`cepheus.Write(ops, db, by = 0, why = "")` writes a group of operations, all or nothing: an `Ok` of `{Group, Things}`,
the group's number and the ids of the things it made, or an `Err` and nothing written.

- `cepheus.Add(thing, property, value)`: the fact added; on a property of one value, it replaces the old one.
- `cepheus.Retract(thing, property, value)`: the fact removed.
- `cepheus.Expect(thing, property, value)`: the group is refused with Code `"conflict"` unless the fact holds before
  it; `cepheus.Expect(thing, property)`, unless the thing has no value of the property. This is how a program writes
  "only if nobody changed it since I read it", an **optimistic** check: nothing is locked; the group that comes second
  is refused, and the program reads again.
- `cepheus.New(k)`: the k-th new thing of the group, in any place a thing goes: `New(1)`, `New(2)`... `Things[k]` is
  its id.

```cesia
first = cepheus.Find(1, (i) -> {Where: [[i, Invoice.Total, 1200]], Give: {Invoice: i}}, db)
inv = result.Unwrap(first)[1].Invoice
pay = [cepheus.Expect(inv, Invoice.Status, "unpaid"), cepheus.Add(inv, Invoice.Status, "paid")]
io.Print(cepheus.Write(pay, db, by = 7, why = "paid by card"))
io.Print(cepheus.Write(pay, db, by = 7, why = "paid by card"))
io.Print(cepheus.Write([cepheus.Add(cepheus.New(1), Client.Name, "Cy"), cepheus.Add(cepheus.New(2), Invoice.Client, cepheus.New(1))], db))
```

```text
Ok({Group: 9, Things: []})
Err({Kind: "cepheus", Code: "conflict", Message: "#65537 does not have \"unpaid\" for invoice/Status (property 21)"})
Ok({Group: 10, Things: [65541, 65542]})
```

The second payment is refused: the first made the invoice paid. Each group is a **transaction** that sees the
database as it was after the group before it, and the groups of a database are applied one after the other: they
are **serializable**, and more, **strictly serializable**: a group that starts after another one was confirmed comes
after it ([guarantees](guarantees.md#g4-strict-serializability)).

A write over the network is answered once its group is on the server's disk (an fsync, G1); the writes that arrive
while the disk works share the next one (**group commit**). If the connection breaks before the answer, the package
connects again and sends the write again with its number in the program's **session**: the server answers a write it
applied already with its first answer, so it is applied **once** (G14). After 30 seconds without a server, every
waiting call gives an `Err` with Code `"unreachable"`, and a write then was applied once or not at all, the honest
answer of any networked database.

## Find: questions

A question is a Cesia function: its parameters are the **variables**, and it gives `{Where, Give}`. `Where` is a list
of **patterns** `[thing, property, value]`, each a fact that must hold, where the thing and the value may be variables
or constants (the property is always a kind's field); `Give` is a map of what to give, each a variable or an
aggregate. `cepheus.Find(n, question, db)` gives an `Ok` of a list of maps, one an answer.

```cesia
unpaid = cepheus.Find(3, (c, i, total) -> {
  Where: [[c, Client.City, "Lyon"], [i, Invoice.Client, c], [i, Invoice.Status, "unpaid"], [i, Invoice.Total, total]],
  Give: {Invoice: i, Total: total},
}, db)
io.Print(unpaid)
```

```text
Ok([{Invoice: 65538, Total: 80.5}])
```

`n` is the number of the question's variables (here 3: `c`, `i` and `total`). Cesia does not let a package ask a
function how many parameters it has, so the program says it; when Cesia does, `n` goes (see choice 1 of this step,
in the progress of the server's plan).

**How it is answered.** The question is joined variable by variable, not pattern by pattern (**Generic Join**, Ngo,
Ré and Rudra 2013): for each variable, the pattern that gives it the fewest candidates (exact counts read in the
indexes) gives them, and every other pattern of that variable checks each one by one lookup. Its work never exceeds
the largest answer the patterns could have (the **AGM bound**), where a plan of joins two by two, as a SQL database
makes, can do much more on a graph ([theory](theory.md#4-generic-join)). Each answer comes once: answers are a set
(G11).

**Conditions.** `cepheus.Above(x, v)` (x > v), `cepheus.Below(x, v)` (x < v) and `cepheus.Between(x, lo, hi)`
(lo ≤ x ≤ hi), for a variable of an Int, a Date or Money, read the sorted index: they are ranges of the question, not
filters after it. Any other condition is Cesia's, on the rows it gives (`list.Filter`).

**Aggregates.** In `Give`, `cepheus.Sum(x)`, `cepheus.Min(x)`, `cepheus.Max(x)` and `cepheus.Count()` group the answers
by the other fields of `Give`, as SQL's `GROUP BY` does; `Count()` counts the answers of a group. They are computed
where the question runs (in the program on the server's machine, else at the server), so a total over 400,000
invoices crosses the network as one row.

```cesia
byCity = cepheus.Find(4, (c, i, city, total) -> {
  Where: [[i, Invoice.Client, c], [c, Client.City, city], [i, Invoice.Total, total], cepheus.Above(total, 50)],
  Give: {City: city, Total: cepheus.Sum(total), Invoices: cepheus.Count()},
}, db)
io.Print(byCity)
```

```text
Ok([{City: "Lyon", Total: 1280.5, Invoices: 2}])
```

The invoice of 10 is below 50: Bo's city is Lyon now, and his only invoice is not counted.

## Forks

A **fork** is a database in the program's memory that starts as another one: it reads and writes as a database, with
every check (types, `unique`, `Expect`, the schema), and nothing it writes goes anywhere: the database it started from
does not change, and neither does its history (G8). Making one copies nothing: the fork shares the state it starts
from (a **persistent** structure: a change makes new nodes and keeps the old ones, so both states stay readable).

`cepheus.Fork(from, kinds = [])` gives an `Ok` of a fork of `cepheus.Empty` (an empty database, for a test that needs
no server), of another fork, or of a database read on the server's machine (its local state now), with these kinds
declared in it:

```cesia
what = result.Unwrap(cepheus.Fork(db))
result.Unwrap(cepheus.Update(Client, ada, {City: "Nice"}, what))
io.Print(cepheus.Get(Client, ada, what))
io.Print(cepheus.Get(Client, ada, db))
```

```text
Ok({Name: "Ada Martin", City: "Nice", Email: "ada@example.com"})
Ok({Name: "Ada Martin", City: "Lyon", Email: "ada@example.com"})
```

A fork of a database read at the server (a program on another machine) is not built yet: it gives an `Err` with Code
`"invalid"` (the design puts such forks in the server, a later step).

### Tests

A test of `cesia test` needs no server: it forks `cepheus.Empty` with the kinds it uses. A test file sits beside the
code it tests (`shop.test.ce` beside `shop.ce`), and its functions are named `is` and a capital:

```cesia test
use deps/www-celestial/cepheus/cesia/cepheus
use std/result

Invoice = cepheus.Kind("invoice", {Total: cepheus.Money(2), Status: cepheus.Text()})

defn isPaidOnce()
  t = cepheus.Fork(cepheus.Empty, [Invoice])?
  inv = cepheus.Insert(Invoice, {Total: 12, Status: "unpaid"}, t)?
  pay = [cepheus.Expect(inv, Invoice.Status, "unpaid"), cepheus.Add(inv, Invoice.Status, "paid")]
  cepheus.Write(pay, t)?
  cepheus.Write(pay, t).Error.Code == "conflict" and cepheus.Get(Invoice, inv, t)?.Status == "paid"
end
```

```text
cesia test --allow native=cepheus
```

The package's own tests are such tests, every function on forks of `Empty` (`cesia/tests/cepheus.test.ce`).

## Local reads

On the server's machine a program reads its own copy of the database: `Get` and `Find` cost no round trip to the
server. What it reads is never stale: a read that starts after a write was confirmed, to this program or to any
other, sees that write. Reads are **linearizable** (Herlihy and Wing 1990: each read and write appears to take effect
at one instant between its call and its answer, in an order that keeps real time), and with the groups, strictly
serializable (G15).

How, in short ([server](server.md#local-reads-g15) tells it whole):

- The server passes the program the database's run files, already open (`SCM_RIGHTS`: a Unix socket can carry open
  files from one program to another), so the program needs no right on the server's files, and its token decides what
  it may read (G16).
- Then the server sends each group's bytes on the follow stream before it forces them to its disk, and the package
  applies them to a new state while the disk works.
- One number in shared memory, a page of the server's that every local reader maps read-only, says which state is
  visible: the server stores it after each fsync and before it answers the writers. A read loads it and serves the
  state held under it, or waits the microseconds until that state is applied. No write waits for a reader.
- Each page read from a run file is checked by its CRC as it arrives (G7).

The follow stream is open when `Connect` returns; the first local read may wait for the follower to apply the groups
written since the database's newest run (its catch-up), and later ones only, now and then, the microseconds of a
frame on its way. What it costs: a domain of the program applies every group the server writes, by any program (1.7 µs
a change alone, about 4 µs under 18,000 groups a second, measured in the server's step 3), and the program holds a
cache of the database's pages (256 MB at most) and the changes since the last merge ([server](server.md#what-it-costs)).

If the follow stream ends (the server restarted), the package reads at the server meanwhile and follows again, at most
every 100 ms, without the program noticing.

## Many fibers, one connection

Every fiber of the program shares the database's one connection. A request goes out at once, with its number; the
fiber that sent it waits, the others run; a domain of the package reads the replies, which come in any order, matched
by their number, and wakes each fiber when its reply came. So:

- 200 fibers that each insert a thing send 200 writes at once, which the server groups into a few fsyncs: they end
  together, in about the time of a few writes, not of 200 ([measured](#what-it-costs)).
- A long `Find` at the server holds no `Get` of another fiber.
- A fiber's own calls keep its order: it waits for each answer before its next call, so it reads what it wrote
  ("read your writes"), and its writes reach the database in the order it made them ("monotonic writes", Terry et al.
  1994).

## Errors

Every call gives a value: `result.Ok` of its result, or `result.Err` of `{Kind: "cepheus", Code, Message}`, which `?`
takes in a function. A mistake of the program in the shape of a call (a database that is not one, a question that is
not `{Where, Give}`) is a bug: it stops the fiber, as `bug.Panic`, and names what was expected.

| Code | When | What to do |
|---|---|---|
| `conflict` | an `Expect` of the group did not hold | read again and decide again |
| `unique` | a value of a `unique` property is taken | another value, or the thing that has it |
| `invalid` | a value of the wrong type, a field the kind does not have, a kind not declared in this database, a question the engine refuses, an address without `ca` over the network | correct the call |
| `damaged` | a page of a run file did not check against its CRC | the server's operations: [operations](operations.md) |
| `io`, `busy` | the server's disk failed, or another process holds the database | the server's operations |
| `closed` | the database was closed by `Close` | connect again |
| `auth`, `denied` | the token is unknown, or lacks the right on this database (G16) | the token's rights: `cepheus token add` |
| `unreachable` | no server answered (at `Connect`), or none for 30 s (a call after) | start the server; a write was applied once or not at all |
| `unknown_database` | the server has no database of this name | add it to `cluster.toml` |
| `too_large`, `stopping`, `too_many_connections`, `version` | the server's limits and state ([errors](errors.md)) | as the message says |

## What it costs

Measured on one machine (Intel Core i7-4720HQ, 4 cores and 8 threads, SATA SSD, Linux), release builds, every process
capped at 3 GB, each round under a lock that keeps the machine's other benchmarks out, the sides alternated in each
round; each number is a median with its distribution-free 95 % interval (order statistics). The database is the
benchmarks' (`bench.exe load`, 1 M facts, [benchmarks](benchmarks.md)); a read is `cepheus.Get` of an invoice, a kind of
4 fields (`client`, `total`, `status`, `date`), over the invoices of the server benchmark's sample in the same order
(`bench/cesia/get.ce`, `sbench.exe ids`); the OCaml client is `sbench.exe`, PostgreSQL 18.6 is driven by `pgbench -M
prepared` (C, libpq) reading `SELECT * FROM invoice WHERE id = $1`, the same rows.

**A point read**, µs (n = 11 rounds):

| | Cesia client | OCaml client | PostgreSQL 18.6 |
|---|---:|---:|---:|
| on the server's machine: a local read | **0.77** [0.76, 0.82] | 0.24 [0.22, 0.36] | 26.4 [23.9, 32.3] through its Unix socket |
| over TCP and TLS 1.3 (loopback) | 51.6 [44.1, 63.4] | 37.1 [31.3, 46.8] | 49.6 in the server's step 2 ([server](server.md#speed-beside-postgresql)) |
| at the server through its Unix socket | (not a path of the Cesia client: it reads locally there) | 8.9 [8.0, 9.6] | |

- The local read is 34 times PostgreSQL's through its socket, and 3.2 times the OCaml client's: the 0.53 µs between
  them are Cesia's side of the call, measured apart on a fork: the call of a package's native (a Cesia function, the
  native's stub, its 3 arguments converted) about 0.10 µs; finding the database and the kind, 0.05; making the map of
  4 fields and its `Ok` through Cesia's native interface, about 0.17; the loop of the benchmark itself, 0.08 (in the
  number above: a loop that calls a Cesia function of the same arguments). The design's bound was 1 µs: met.
- Over TLS a read pays the round trip, the encryption (about 11 µs a round trip in C with OpenSSL here) and the
  server's work. The Cesia client reads its reply itself when nothing else is in flight (the window of three round
  trips, [many fibers](#many-fibers-one-connection)): without it, a reply crossed from the package's reader domain to
  Cesia's through a pipe, and a read cost 74.1 µs [51.2, 101.7] in the same rounds (the fast path: 0.67 times that, the
  median of the rounds' ratios). The 14 µs left over the OCaml client is the wake-up of Cesia's scheduler and the
  values made for Cesia; the design's bound, 11 µs at the server through its Unix socket, is the OCaml client's path,
  which a Cesia program on the server's machine does not take (it reads locally).

**Durable writes**, n = 7 rounds of 3 s (each write an invoice of 4 facts, its group forced to the disk):

| | Cesia client, one connection | OCaml client |
|---|---:|---:|
| one writer | 189 a second [94, 296], 3.45 ms [3.01, 7.81] the median latency | 229 [155, 286], one connection |
| 64 writers | 7,021 a second [1,799, 8,604]: 64 fibers on one connection | 4,828 [335, 7,288]: 64 connections |

The intervals are wide: the disk's fsync takes 2 to 3 times as long from one run to the next (the server's
[benchmarks](server.md#speed-beside-postgresql) saw the same). What they show: 64 fibers on one connection write as fast as 64
connections, since their writes leave pipelined and share the server's fsyncs.

**Start-up and the first call**, ms a whole process (`cesia run`, n = 101 runs of each, alternated): `io.Print(1)`
alone 3.09 [3.04, 3.13]; the same with the package used but not called 3.51 [3.49, 3.54]; with one call 18.7 [18.6,
18.8].

- Nothing of the engine loads before the first call: the 0.42 ms of a program that uses the package are its Cesia code
  read and compiled, as for any package (`std/csv`, 40 lines, about 0.2 ms; `std/sql` about 3 ms, measured the same
  way but without the lock).
- The first call costs 13 ms more (the engine stripped of its symbol table, as built now: 17.8 ms [17.6, 18.0] against
  20.3 [20.2, 20.5] before, n = 55; that run's process with the package unused: 4.5): checking the engine's
  fingerprint (BLAKE2 of 2.3 MB, 3.9 ms), loading the system's OpenSSL (1.3 ms), and linking 1.4 MB of machine code
  into the process. Once a process: a program connects once, at its start.

**The rest of the program.** The package's reader and, on the server's machine, its follower are domains of the
program's process, and OCaml 5 stops every domain at each minor collection, while the follower's state lives in the
program's heap. A loop that makes 2 million maps (`bench/cesia/gc.ce`, the best of three, n = 7): 125.8 ms [124.8,
131.7] alone, 126.9 [125.1, 129.0] with a local connection open; over TLS 124.9 and 128.2 with it; while 64 writers
write and the follower applies their groups, 140.7 ms alone and 149.4 with it (the intervals overlap; the writers'
server and the benchmark share the machine's cores). Idle, a connection costs the program nothing measurable.

**Beside the giants.** No Cesia client of PostgreSQL exists (Cesia's `std/sql` speaks SQLite), so PostgreSQL is
measured through its C library, the fastest client it has: a Cesia program on the server's machine reads a row 34
times faster than any client of PostgreSQL can, since it makes no round trip, and over the network the Cesia client is
within the giant's own cost (51.6 against 49.6 µs, PostgreSQL measured in an earlier session). Where PostgreSQL wins:
its client connects in 2 ms (Unix socket) or 4.3 ms (TLS), where the Cesia client's first call alone costs 13 ms;
and a program that holds no copy of the data uses less memory than a local reader (31 MB of a database of 1 M facts,
[server](server.md#what-it-costs)). Datomic's peers read in their own process too ("application processes
have their own copy of the query engine and database in local memory"), but see writes asynchronously unless they
call `sync`, a round trip ([server](server.md#beside-the-giants-by-their-documentation)); a local read of Cepheus is
linearizable without it.

## What is not built yet

- `cepheus.Watch`, a question whose changes come as they happen, in a channel: the server pushes them in step 5 of
  the server's plan.
- Forks of a database read at the server: in the server, a later step.
- `Not`, `Or`, `Prefix` and `In` in questions: not in the engine.
- A program reaches one database a connection: `Connect` again for another.

## References

- **[Ngo 2013]** H. Q. Ngo, C. Ré, A. Rudra. Skew Strikes Back: New Developments in the Theory of Join Algorithms.
  *SIGMOD Record* 42(4), 2013. https://doi.org/10.1145/2590989.2590991 — Generic Join, which `Find` runs.
- **[Herlihy 1990]** M. P. Herlihy, J. M. Wing. Linearizability: A Correctness Condition for Concurrent Objects.
  *ACM TOPLAS* 12(3), 463–492, 1990. https://doi.org/10.1145/78969.78972 — what a local read guarantees.
- **[Terry 1994]** D. B. Terry et al. Session Guarantees for Weakly Consistent Replicated Data. *PDIS* 1994.
  https://doi.org/10.1109/PDIS.1994.331722 — read your writes and monotonic writes, which one fiber's calls keep.
- **[Ongaro 2014b]** D. Ongaro. Consensus: Bridging Theory and Practice. PhD dissertation, Stanford, 2014, §6.3 —
  the session numbers that apply a resent write once.
- The other works the server rests on: [references](references.md#the-server).
