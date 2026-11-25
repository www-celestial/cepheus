# Cepheus from Cesia

This chapter is for programmers who write in [Cesia](https://github.com/www-celestial/cesia-lang): how a Cesia program
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

```cesia norun
use deps/www-celestial/cepheus/cesia/cepheus
use std/fiber
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
| `cepheus.Date()` | an instant in UTC, kept in milliseconds since 1970 | a number of seconds since 1970, as `sys.Now()` gives, below $4.6 \times 10^{15}$ either way (146 million years: its milliseconds an Int); read back as a Float | `1794268800.25` |
| `cepheus.Money(scale)` | an exact decimal of `scale` digits after the point (0 to 18), kept in minor units | a number (Int or Float), rounded to the scale, whose minor units are an Int; read back as a Float | `1200.5` |
| `cepheus.Link()` | another thing of the database | its id, an Int | `65536` |

Each takes `unique = false` and `many = false`. Money is exact in the database (an integer of minor units, so sums are
exact there, `Sum` included) and a Float in Cesia: an amount of up to 15 significant digits, as 1,234,567,890,123.45,
written and read back gives the same minor units (a 64-bit float is within half a unit of it); beyond, its last digits
round.

## Insert, Get, Update

```cesia norun
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

```cesia norun
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
- `cepheus.Incr(thing, property, by = 1, into = missing)`: a **counter** that the group increments. The thing's value
  of an `Int()` property of one value (none counts 0) grows by `by` (a negative `by` counts down), read by the
  database at this point of the group. `into = [thing, property]` also adds the new value there, an `Int()` property:
  an invoice gets its number in the group that makes it. A value past the 63 bits of an Int refuses the group, Code
  `"invalid"`.
- `cepheus.New(k)`: the k-th new thing of the group, in any place a thing goes: `New(1)`, `New(2)`... `Things[k]` is
  its id.

```cesia norun
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

Numbers that follow each other without a gap, as the law of many countries asks of invoices, are a counter that the
group itself increments. Reading the largest number and writing it plus one would not do: two programs that read at
the same time take the same number, and one of them must try again. With `Incr`, the database reads the counter
when it applies the group, so groups that count at the same time never conflict and never skip a number, and a
refused group takes none:

```cesia norun
Counter = cepheus.Kind("counter", {Last: cepheus.Int()})
Bill = cepheus.Kind("bill", {Number: cepheus.Int(unique = true), Client: cepheus.Link()})
db = result.Unwrap(cepheus.Connect(sys.Env("CEPHEUS_URL"), [Client, Invoice, Counter, Bill], token = sys.Env("CEPHEUS_TOKEN")))
counter = result.Unwrap(cepheus.Insert(Counter, {Last: 0}, db))
bill = [cepheus.Incr(counter, Counter.Last, into = [cepheus.New(1), Bill.Number]), cepheus.Add(cepheus.New(1), Bill.Client, bo)]
first = result.Unwrap(cepheus.Write(bill, db)).Things[1]
second = result.Unwrap(cepheus.Write(bill, db)).Things[1]
io.Print(cepheus.Get(Bill, first, db), cepheus.Get(Bill, second, db))
refused = cepheus.Write([cepheus.Expect(bo, Client.City, "Rome"), cepheus.Incr(counter, Counter.Last, into = [cepheus.New(1), Bill.Number])], db)
io.Print(refused.Error.Code, cepheus.Get(Counter, counter, db))
```

```text
Ok({Number: 1, Client: 65539}) Ok({Number: 2, Client: 65539})
conflict Ok({Last: 2})
```

`Incr` is one operation of the group, as `Add` is: the bill's other facts, its lines, are in the same group, all or
nothing.

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

```cesia norun
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
function how many parameters it has, so the program says it.

**How it is answered.** The question is joined variable by variable, not pattern by pattern (**Generic Join**, Ngo,
Ré and Rudra 2013): for each variable, the pattern that gives it the fewest candidates (exact counts read in the
indexes) gives them, and every other pattern of that variable checks each one by one lookup. Its work never exceeds
the largest answer the patterns could have (the **AGM bound**), where a plan of joins two by two, as a SQL database
makes, can do much more on a graph ([theory](theory.md#4-generic-join)). Each answer comes once: answers are a set
(G11).

**Conditions.** `cepheus.Above(x, v)` ($x > v$), `cepheus.Below(x, v)` ($x < v$) and `cepheus.Between(x, lo, hi)`
($\mathit{lo} \le x \le \mathit{hi}$), for a variable of an Int, a Date or Money, read the sorted index: they are ranges of the question, not
filters after it. On a Float they keep the values on their side in the order `Sort` gives (IEEE 754's totalOrder:
$-0$ before $0$, NaN after infinity), each candidate checked ([below](#less-lessorequal-and-optional)). Two variables
compare with `cepheus.Less` and `cepheus.LessOrEqual` (same section). Any other condition is Cesia's, on the rows it
gives (`list.Filter`). A Date is kept to the
millisecond and Money to its digits, so a bound between two of them (`Above(price, 10.005)` for cents, a time of
`sys.Now()`) keeps exactly the values on its side: it is rounded toward the inside of the range, 10.005 to 10.01 for
Above and to 10.00 for Below. A bound of floats within $2^{-50}$ (relative) of a unit is that unit, as a decimal
written to the cent is (10.01 times 100 is 1000.9999999999999 in floats): `Above(price, 10.01)` leaves 10.01 out.
`Above(n, v)` with the largest Int, or `Below(n, v)` with the least, keeps nothing.

**Aggregates.** In `Give`, `cepheus.Sum(x)`, `cepheus.Min(x)`, `cepheus.Max(x)` and `cepheus.Count()` group the answers
by the other fields of `Give`, as SQL's `GROUP BY` does; `Count()` counts the answers of a group. They are computed
where the question runs (in the program on the server's machine, else at the server), so a total over 400,000
invoices crosses the network as one row.

```cesia norun
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

**Its time.** `timeout = seconds` bounds a question: past it, `Find` is an `Err` of Code `"timeout"`, whose message
names the time, and the work stops (within milliseconds: it is looked at every 1,024 candidates). At the server, the
server's `question_timeout` (30 s by default, [the server](server.md#clustertoml)) is the most a question takes: a
shorter `timeout` is the question's, a longer one counts only for an admin token. In the program's memory (on the
server's machine) only the program's own `timeout` bounds it. A question the program stops waiting for (its
connection closed) stops at the server too.

```cesia norun
names = result.Unwrap(cepheus.Fork(cepheus.Empty, [Client]))
result.Unwrap(cepheus.Write([cepheus.Add(cepheus.New(k), Client.Name, "c$k") for k in 1..300], names))
rows = cepheus.Find(6, (a, x, b, y, c, z) -> {
  Where: [[a, Client.Name, x], [b, Client.Name, y], [c, Client.Name, z]],
  Give: {Count: cepheus.Count()},
}, names, timeout = 0.1)
io.Print(rows.Error.Code)
```

```text
timeout
```

Three patterns that share no variable are every triple of names (a cross product): 300 names make 27 million
answers, a million $10^{18}$; the question ends at its time instead of holding the cores (here the program's, on a
fork of its own: [forks](#forks)). `cepheus.Watch` takes the same `timeout`, for its first answer.

## Not, Or and In

Three conditions of `Where` say what must not hold, what may hold in several ways, and which values a variable may
take:

```cesia norun
clear = cepheus.Find(2, (c, i) -> {
  Where: [[c, Client.City, "Lyon"], cepheus.Not([i, Invoice.Client, c], [i, Invoice.Status, "unpaid"])],
  Give: {Client: c},
}, db)
io.Print(clear)
either = cepheus.Find(1, (c) -> {Where: [cepheus.Or([c, Client.Name, "Cy"], [c, Client.Email, "bo@example.com"])], Give: {Client: c}}, db)
io.Print(either)
some = cepheus.Find(2, (i, s) -> {Where: [[i, Invoice.Status, s], cepheus.In(s, ["paid", "late"])], Give: {Invoice: i}}, db)
io.Print(some)
```

```text
Ok([{Client: 65539}])
Ok([{Client: 65541}, {Client: 65539}])
Ok([{Invoice: 65537}, {Invoice: 65540}])
```

- `cepheus.Not(a, b, c, d)`: 1 to 4 patterns and conditions; the binding is kept when no value of the Not's own
  variables makes them all hold. A variable is the Not's own when it appears in no other place of the question: here
  `i`, so the first question reads "the clients of Lyon with no invoice that is theirs and unpaid". Its other
  variables must be bound by a pattern of the question.
- `cepheus.Or(a, b, c, d)`: 2 to 4 alternatives, each a pattern, a condition, or `cepheus.And(...)` of 1 to 4 of them;
  at least one holds. A variable in every alternative is bound by the Or (`c` above); one in some of them only is
  each alternative's own ("there is a value of it"), and may not be given. Each answer comes once, even when several
  alternatives hold for it. `And` is for an alternative only: `Where` is already all of its items. An `Or` of one
  pattern whose alternatives differ only in their value is refused: that is `In`.
- `cepheus.In(x, values)`: x is one of the values, of its type (ids for a link: the invoices of these clients). A
  value the database does not hold is no candidate; an empty list has no answer. It takes up to 100,000 values, as
  many as a page has rows: a page's ids go back in one question ([limits](limits.md#questions)).

**Exact meaning.** Each operator reads the facts of the view the question is answered at, the facts the rules derive
included: they are in every view, exactly (G17), so a `Not` reads a complete set of facts. (A `Not` in a *rule*'s
body is the same function, [rules](#rules).) `Not` and `Or` may not hold a
`Not` or an `Or`: name a deeper condition with a rule, as a derived fact.

**How it is answered.** `In` is a relation of one column for Generic Join: its values are the candidates of x when
they are fewer than every pattern's, else each candidate is checked against them. `Not` is an **anti-join**: a
binding passes when a lookup finds nothing (one pattern: is the fact there, does the thing have a value, does the
value have a thing), or, for several items, when the Not's own question, its other variables fixed, has no answer
(asked up to its first). `Or` is asked once for each alternative, with the alternatives before it as `Not`s, so the
answers of the alternatives are disjoint and none needs to be kept to remove copies (but those of an alternative with
variables of its own, which may give a binding once for each of their values).

A `Watch` keeps `Not`, `Or`, `In`, `Prefix`, `Less` and `Optional`, and a change sends only the rows it adds or
removes. A frame's fact can change only the answers that agree with it at one of the question's patterns, wherever the
pattern is: for a pattern that holds variables of the question, the answers with those values; for one inside a `Not`
or an alternative whose variables are all its own, the answers its other items reach from the fact (an invoice paid:
its client). For each such set of values, the question is answered again with them fixed, before and after the frame,
and the difference is the change. So a fact added under a `Not` removes the rows it now excludes, a fact removed may
give rows back, an alternative is read with the ones before it, `In`, `Prefix` and `Less` filter the values the fact
gives, and a value added under an `Optional` takes away the row where it was missing and gives its own (a value
removed, the other way). The cost of a frame is that of the answers it touches, not of the whole question (a fact that
no variable of the question reaches, as a `Not` over a whole property, is the whole question again).

## Prefix: the start of a text

`cepheus.Prefix(x, text)`: the text x starts with these bytes. With Sort and Limit, it is a search as one types:

```cesia norun
found = cepheus.Find(2, (c, n) -> {Where: [[c, Client.Name, n], cepheus.Prefix(n, "B")], Give: {Client: c, Name: n}, Sort: [n], Limit: 10}, db)
io.Print(found)
```

```text
Ok([{Client: 65539, Name: "Bo Lind"}])
```

- The comparison is of bytes: `"Ad"` matches "Ada", not "ada" nor "Ädam". A search without case keeps a field of its
  own in the form it searches (the name in lower case, written with the name).
- x is a text variable that a pattern gives as its value; the prefix has 1 to 1,024 bytes.

**How it is answered.** Each run holds, for each text property, its distinct texts in the order of their bytes (run
format 9, [formats](formats.md#run-dirsnapshotslo-20-digits-hi-20-digitsrun)): the texts that start with the prefix
are one stretch of it, found by two binary searches; with the few texts written since the last merge, they are the
candidates of x, as an `In` of them. The work is that of the matching texts and their things, not of every text of
the database; and it reads the texts of x's property only.

## Sort, Limit and After: pages

Three more keys of the question sort its rows, cut them, and give the page after a row:

```cesia norun
page = (after) -> ((i, t) -> {
  Where: [[i, Invoice.Total, t]],
  Give: {Invoice: i, Total: t},
  Sort: [cepheus.Desc(t)],
  Limit: 2,
  After: after,
})
first = result.Unwrap(cepheus.Find(2, page(missing), db))
io.Print(first)
io.Print(cepheus.Find(2, page(first[2]), db))
```

```text
[{Invoice: 65537, Total: 1200.0}, {Invoice: 65538, Total: 80.5}]
Ok([{Invoice: 65540, Total: 10.0}])
```

- `Sort: [key, ...]`: each key is a field of `Give`, its variable or its aggregate (`cepheus.Desc(cepheus.Sum(t))`
  when `Give` holds `cepheus.Sum(t)`), ascending, or `cepheus.Desc(key)` for the largest first. Rows equal in the keys
  are ordered by the other fields of `Give`, by name, so two rows are equal in the order only when they are the same
  row. Values compare within their type: numbers, dates and money as numbers; `false` before `true`; links by their
  id, the order the things were made in; texts by their bytes (UTF-8: the order of their code points, so "Z" comes
  before "a" and "é" after "z", not a language's order); floats by IEEE 754's totalOrder. A field an `Optional`
  left `missing` comes after every value, in both directions ([below](#less-lessorequal-and-optional)).
- `Limit: k`: the first k rows, and the copies of the k-th when `Give` leaves out a variable (a page never splits
  identical rows). Without `Sort`, k rows of the answer, in the engine's order.
- `After: row`: the rows that come after this row in the order: the next page. It needs `Sort`, and a value for
  every field of `Give` (or `missing` for an `Optional`'s); the row need not be in the database any more.

**The previous page** is the same question with each key reversed (`Desc` added or taken away) and `After` the first
row of the current page; reverse its rows (`list.Reverse`). There is no offset ("skip the first 4,000"): a page after
a row costs the same at any depth, where an offset counts every row it skips, and a row written between two pages
moves them by one. A row that is unchanged at both pages' groups comes once; one written between them shows at its
place, if that place is after the cursor.

**How it is answered.** Two ways give the same rows ([theory](theory.md#4-generic-join)):

- by a **heap**: every answer of the question, kept in a buffer of about twice k rows, sorted and cut back to its
  first k each time it fills: the work of the question itself plus $O(N \log k)$ comparisons, with $k$ rows held,
  and k rows sent instead of $N$;
- **in the index's order**, when the first key is an int, a date, money, a link or a text that a pattern gives as its
  value: the question is asked again on windows of that variable's values read from the property's index, from the
  cursor on, the first window holding k facts (a list without a filter reads its page and no more), each next one at
  least twice the one before, until k rows are found: the work of the rows the page needs. A text's window is the next
  texts in the order of their bytes, which each run on disk keeps for its property (the order `Prefix` reads too),
  merged over the runs and the changes not yet merged. Its budget is half the planner's estimate of the heap's work,
  in facts read, since a fact read this way costs about twice a step of the heap; past it, the heap answers, so this
  way never costs more than about twice the other (the rule of the ski-rental problem: rent until the rent reaches the
  price, then buy). It gives up sooner when the rows found so far say the page cannot be filled within the budget:
  even at the most hopeful yield they allow (the upper bound at 99 % of the mean of a Poisson count,
  [Garwood 1936](references.md#joins), by the approximation of [Wilson 1931](references.md#joins)), the missing rows
  would need more facts than the budget has left; a next window holds at least the facts the missing rows need at that
  yield. It loses when the rows the page wants lie far in the order: the clients whose name starts with "ma", sorted
  by name, sit after every "A" to "L"; the walk then gives up after 2 windows instead of 5 (in OCaml, 396 µs against
  657 when it walked to its budget, and 322 for the heap alone, on the app's data of
  [the guide](app.md#14-what-it-costs)).

`Watch` takes `Sort` and `Limit` too, and keeps the first rows of the order as they change
([below](#sort-and-limit-in-a-watch)); it refuses `After`. A question that holds `Sort`, `Limit` or `After` is refused if it holds another key than `Where`,
`Give`, `Sort`, `Limit` and `After`: a misspelt `After` would otherwise give the first page again and again (a
question without them is read as before, its other keys left aside).

## Less, LessOrEqual and Optional

Two variables compared with each other, ranges of floats, and a value that a thing may not have:

```cesia norun
Loan = cepheus.Kind("loan", {Client: cepheus.Link(), Rate: cepheus.Float(), Due: cepheus.Date(), PaidAt: cepheus.Date()})
(* a fork, so that what this example writes stays out of db *)
loans = result.Unwrap(cepheus.Fork(db, [Loan]))
for l in [{Client: ada, Rate: 2.5, Due: 1794268800, PaidAt: 1794268800}, {Client: bo, Rate: 3.1, Due: 1794268800, PaidAt: 1794441600}, {Client: ada, Rate: 2.99, Due: 1794355200}]
  result.Unwrap(cepheus.Insert(Loan, l, loans))
end
late = cepheus.Find(5, (l, c, n, d, p) -> {
  Where: [[l, Loan.Client, c], [c, Client.Name, n], [l, Loan.Due, d], [l, Loan.PaidAt, p], cepheus.Less(d, p)],
  Give: {Name: n, Due: d, Paid: p},
}, loans)
io.Print(late)
io.Print(cepheus.Find(2, (l, r) -> {Where: [[l, Loan.Rate, r], cepheus.Between(r, 2.5, 3.0)], Give: {Rate: r}, Sort: [r]}, loans))
emails = cepheus.Find(3, (c, n, e) -> {
  Where: [[c, Client.Name, n], cepheus.Optional([c, Client.Email, e])],
  Give: {Name: n, Email: e},
  Sort: [e],
}, db)
io.Print(emails)
```

```text
Ok([{Name: "Bo Lind", Due: 1794268800.0, Paid: 1794441600.0}])
Ok([{Rate: 2.5}, {Rate: 2.99}])
Ok([{Name: "Ada Martin", Email: "ada@example.com"}, {Name: "Bo Lind", Email: "bo@example.com"}, {Name: "Cy", Email: missing}])
```

The first question is "the loans paid after their due date": Ada's first loan was paid on its day, her second is not
paid yet (it has no `PaidAt`, so no row). The last is SQL's `LEFT JOIN`: every client, with an email or without.

- `cepheus.Less(x, y)` keeps $x < y$, `cepheus.LessOrEqual(x, y)` $x \le y$: two variables of one type, each given by
  a pattern of the question (or the `Not`'s own, inside a `Not`). Ints, floats, dates, money, texts and links compare
  as `Sort` orders them: texts by their bytes, floats in IEEE 754's totalOrder, links by their id (the order the
  things were made in); a bool, or two types, is refused (`invalid`). It goes at the top of `Where`, in a `Not` and in
  an alternative of `Or`. A variable against a constant is `Above` or `Below`; `Less(x, x)` keeps nothing and
  `LessOrEqual(x, x)` everything.
- `Above`, `Below` and `Between` take a Float variable too: its values in totalOrder, the order of `Sort` ($-0$ before
  $0$, so `Below(r, 0)` keeps $-0$; NaN after $+\infty$). `Above` and `Below` are strict: the bound itself is out.
- `cepheus.Optional([thing, property, v])`: for each answer of the rest of `Where`, a row for each value the thing has
  of the property, or one row where v is `missing` when it has none. The thing is a variable that a pattern of
  `Where` binds (or a thing's id); v is a variable in no other item of the question; `Optional` goes at the top of
  `Where`, not in a `Not` or an `Or`. A property of `many` values gives a row a value, as a `LEFT JOIN` does; two
  `Optional`s give each other's rows. The map of a row holds `missing` for v, as `Get` does for a field with no value.
- **missing in an order.** `Sort` puts a missing value after every value, ascending and descending (PostgreSQL's
  default puts its NULLs last ascending and first descending: here a page of the largest first never starts with the
  rows that lack the value). `After` takes a row whose field is missing: the next page goes on among those rows.
- **missing in a group.** `Count()` counts the rows, those with v missing too, and v as a key of `Give` makes a group
  of the missing rows. `Sum`, `Min` and `Max` of v are refused (`invalid`): give its values, or count the rows.
- The opposite question, "the clients with no email", is `cepheus.Not([c, Client.Email, e])` ([Not, Or and
  In](#not-or-and-in)); the clients of an invoice that may have none is a question from the invoices (the link goes
  from the invoice to its client): `Optional` reads a property of a thing, not the things that point to it.

**How it is answered.** `Less` binds the variable that the join reaches second from the value of the first: for ints,
dates, money and links, whose index keeps their values in order, the second variable's candidates are then a range of
the sorted index, a seek to the first value past the other and a read from there, not a scan of every value (the
inequality join of [Khayyat 2015](references.md#joins)); a text's or a float's index word is a number of the
dictionary, in no order of values, so each candidate is checked (its bytes, its totalOrder). The planner counts a
third of the property's distinct values for the bounded side, the share Selinger's planner gives an open range
([Selinger 1979](references.md#joins)), so a bound pattern comes first and the other side is sought. Two large sets
that nothing else joins are a cross product: $n^2/2$ pairs kept from $n$ values on each side; such a question ends at
its time and, at the server, at its work budget ([limits](limits.md#questions)), as any cross product does.
`Optional` is bound last, after the join and its `Not`s: each row of the rest looks up the thing's values of the
property, one search of the index, as `Get` reads a field. This is SPARQL's `OPTIONAL` for one pattern, whose
meaning [Pérez, Arenas and Gutierrez (2009)](references.md#joins) set. Its variable is in no other item because, with
a variable that another part C also has, "A, then B if it can, then C" and "A and C, then B if it can" give different
rows (a row where B gave the variable a value that C then refuses is lost in one and kept with B missing in the
other); their *well-designed* patterns are those where the two agree. The items of `Where` have no order, so such a
question would have no one meaning: it is refused.

What they cost beside PostgreSQL, on the benchmarks' data: [benchmarks](benchmarks.md#less-optional-and-one-shared-counter-2026-11-25-at-1-million-facts)
(`Optional` costs what the join costs; `Less` what filtering the rows in the program costs).

## Watch: live questions

A **live question** is a `Find` that stays open. `cepheus.Watch(n, question, db, size = 64, until = missing)` takes the same question as
`Find` and gives an `Ok` of `{Changes, Watch}`: `Changes` is a Cesia **channel** (a queue between fibers, read with
`fiber.Receive` or `for`; Cesia's book, chapter "Fibers") that holds `size` messages at most. Its first message is the
**answer**, `{Group, Rows}`: the rows `Find` gives at group `Group`. Each next one is a **change**,
`{Group, Added, Removed}`: the rows that came and the rows that went with group `Group`, so that the rows held, with
`Added` added and `Removed` taken away, are then `Find`'s rows at that group. Every message has the four fields; the two
it does not use are `missing`.

```cesia norun
unpaidOf(c) = (i, total) -> {
  Where: [[i, Invoice.Client, c], [i, Invoice.Status, "unpaid"], [i, Invoice.Total, total]],
  Give: {Invoice: i, Total: total},
}
w = result.Unwrap(cepheus.Watch(2, unpaidOf(ada), db))
io.Print(fiber.Receive(w.Changes))
small = result.Unwrap(cepheus.Insert(Invoice, {Client: ada, Total: 45, Status: "unpaid"}, db))
result.Unwrap(cepheus.Update(Invoice, small, {Status: "paid"}, db))
io.Print(fiber.Receive(w.Changes))
io.Print(fiber.Receive(w.Changes))
cepheus.Close(w)
```

```text
Ok({Group: 14, Rows: [{Invoice: 65538, Total: 80.5}], Added: missing, Removed: missing})
Ok({Group: 15, Rows: missing, Added: [{Invoice: 65546, Total: 45.0}], Removed: []})
Ok({Group: 16, Rows: missing, Added: [], Removed: [{Invoice: 65546, Total: 45.0}]})
```

- A change comes only when the rows change, and only once its group is on the server's disk (G1): a screen never
  shows a write that a crash could undo.
- The rows are `Find`'s, with their repeats: a `Give` that leaves out a variable gives a row for each binding, as
  `Find` does. Aggregates (`Sum`, `Count`, `Min`, `Max`) are watched too: a change then removes a group's old row and
  adds its new one.
- **No gap, no repeat.** When the connection breaks or the server restarts, the watch goes on by itself from the group
  of its last message: the server answers that nothing the question reads changed since (and nothing comes), or with
  the answer at its newest group, which the package turns into the change from the rows it holds. The program sees no
  gap and no message twice.
- **A slow fiber holds nobody.** Each fiber that watches keeps its own queue of 256 messages in the package; one that
  falls further behind loses that queue and gets the whole answer again, `{Group, Rows}`, when it reads next, rather
  than every change it missed. At the server, a connection holding more than 8 MiB of messages it has not taken yet
  ends its watches with `"lagging"`, and the package watches again from its last group. The writers never wait for a
  watch.
- **One watch a question.** Every fiber of the program that watches the same question (the same patterns, constants
  and `Give`) shares one watch: the server computes its changes once, and the package gives each fiber its copy.
- **Where it is computed**, as for `Find`: on the server's machine, in the program, from the groups it follows for its
  local reads (it computes each frame's changes while the server forces it, and gives them once it is durable);
  elsewhere at the server, which pushes them. A fork's watches are computed in the fork, at each of its writes.
- `cepheus.Close(w)` ends the watch: its channel closes once its last message is taken. A watch ends by itself only
  when its database is closed or its token may no longer read the database: the channel closes, and the next
  `cepheus.Watch` of that question says why.
- `until`, a channel, ends the watch once it closes, as `cepheus.Close(w)` does. A live screen of Cesia's `std/live`
  gives one, `s.Ended`, which closes when its page leaves: its show is then
  `live.Show("unpaid", cepheus.Watch(1, unpaidOf(c), db, until = s.Ended)?.Changes)`, and the watch ends with the page.

**How a change is computed.** A question is a join of patterns (a conjunctive query). When a group adds facts, the new
rows are the bindings that use an added fact in at least one pattern; each is found once, at the first pattern that
matches an added fact (the patterns before it read the database without the group's facts, those after it with
them), each part one search of the indexes with that fact fixed: the **delta query** of Ammar, McSherry, Salihoglu and
Joglekar (2018), run by the same Generic Join as `Find`. Removed facts give the removed rows the same way, over the
database before the group. `Sum` and `Count` follow by difference; `Min` and `Max` are asked again for the key whose
extremum went. Questions that differ only by their constants (the unpaid invoices of each client) share one
**template**: a fact's change is computed once and its rows sent to the watches whose constants they match, so a
group costs the same with 10 watches or 10,000 ([what it costs](#what-it-costs)).

### Sort and Limit in a watch

`Watch` takes `Sort` and `Limit` as `Find` does: at each message its rows are `Find`'s with the same `Sort` and
`Limit` at the message's group (the first k rows in the order, and the copies of the k-th), and each message gives its
rows in the order: an answer's `Rows`, a change's `Added` and its `Removed`, each sorted. The messages keep their two
forms, so a reader of a watch reads one with `Sort` as any other; the rows held stay a set to which `Added` is added
and from which `Removed` is taken, so a page that shows them in order merges `Added` at its place or sorts the k rows
again (`std/live` keeps a show's rows as a set).

```cesia norun
top2 = (i, total) -> {
  Where: [[i, Invoice.Total, total]],
  Give: {Invoice: i, Total: total},
  Sort: [cepheus.Desc(total)],
  Limit: 2,
}
w = result.Unwrap(cepheus.Watch(2, top2, db))
io.Print(fiber.Receive(w.Changes))
big = result.Unwrap(cepheus.Insert(Invoice, {Client: bo, Total: 500, Status: "paid"}, db))
io.Print(fiber.Receive(w.Changes))
result.Unwrap(cepheus.Update(Invoice, big, {Total: 5}, db))
io.Print(fiber.Receive(w.Changes))
cepheus.Close(w)
```

```text
Ok({Group: 16, Rows: [{Invoice: 65537, Total: 1200.0}, {Invoice: 65538, Total: 80.5}], Added: missing, Removed: missing})
Ok({Group: 17, Rows: missing, Added: [{Invoice: 65547, Total: 500.0}], Removed: [{Invoice: 65538, Total: 80.5}]})
Ok({Group: 18, Rows: missing, Added: [{Invoice: 65538, Total: 80.5}], Removed: [{Invoice: 65547, Total: 500.0}]})
```

- A row that comes before the window's last row comes in, and pushes out the rows past the k-th; a row of the window
  that goes is replaced by the next one of the order, which the watch reads by one `Find` of the rows after its last
  row (`After` it, `Limit` the rows missing) at the group of the change. The watch holds k rows, never the whole
  answer, and its first answer costs a page.
- A row of the window whose fields change goes and comes back with its new fields in the same change, at its new place
  (or not at all, when its new place is past the k-th). A write that changes nothing in the window (a row past the
  k-th, a fact no row of the question reads) gives no message.
- `Sort` without `Limit` keeps every row of the answer, in the order.
- Refused, `invalid`: `After` (a watch's rows are the first of its order, as they change), `Limit` without `Sort` (the
  engine's order is no order a watch can keep), `Sort` or `Limit` with aggregates, a `Limit` over 100,000 rows (as for
  `Find`). Against a server of an earlier release (protocol 4 or older) such a watch is refused in the program, never
  sent: "this server speaks protocol 4: a watch with Sort and Limit needs a server of protocol 5". A watch without
  them goes as before.
- **What it costs.** A change costs the delta queries below, as for any watch, plus the comparison of each row they
  add or remove with the window's last row, $O(d \log k)$ for $d$ rows, plus one page `Find` when a row leaves the
  window. On the app of [the guide](app.md#9-the-live-dashboard), its dashboard's ten latest payments: the first answer
  97 µs against 6,299 µs for the payments of the last day that the page sorted (3,410 rows held instead of 10), and a
  group at the hub 11.9 µs at the median against 10.0, 18.7 on the mean against 13.5 (a payment taken back refills the
  window: one page `Find`) ([what it costs](app.md#14-what-it-costs)).

**How the window is kept.** The watch holds its window W (the rows of `Find` with `Limit` k) and L, its last row. A
row of the answer is in W exactly when it comes at or before L in the order (every row before the k-th, and every copy
of the k-th), unless W is the whole answer (fewer than k rows: then every row is). So after a group, the rows of the
new answer at or before L are those of W, less the removed rows at or before L, plus the added rows at or before L:
the delta queries' rows, each compared with L. If they are k or more, the new W is their first k and the copies of
the k-th; if fewer, every row the new W still needs comes after L, and one `Find` with `After` L and `Limit` the rows
missing gives them (a refill that finds fewer than it asked has found every row, and W is then the whole answer).
`spec/WatchWindow.tla` checks the rule: after every group W is `Find`'s rows, and TLC breaks it when the refill is left
out, when the cut splits the copies of the k-th row, or when "at or before L" becomes "before L"; `test/live_sim.ml`
checks it against `Find` and an oracle of its own at every message.

## Rules

A **rule** derives facts from facts, and the database keeps them up to date at every write: "a client with a late
invoice is overdue" ([rules](rules.md) tells how, and what it costs). `cepheus.Rule(name, n, rule)` writes one as a
question: a function of `n` variables that gives `{Where, Then}`, `Where` its patterns (and `Above`, `Below`,
`Between`), `Then` the fact it gives for each answer. `cepheus.Define(rules, db)` defines them, in one group:

```cesia norun
Standing = cepheus.Kind("standing", {Overdue: cepheus.Bool()})
db = result.Unwrap(cepheus.Connect(sys.Env("CEPHEUS_URL"), [Client, Invoice, Standing], token = sys.Env("CEPHEUS_TOKEN")))
overdue = cepheus.Rule("overdue", 2, (c, i) -> {Where: [[i, Invoice.Client, c], [i, Invoice.Status, "late"]], Then: [c, Standing.Overdue, true]})
io.Print(cepheus.Define([overdue], db))
late = result.Unwrap(cepheus.Insert(Invoice, {Client: bo, Total: 30, Status: "late"}, db))
io.Print(cepheus.Get(Standing, bo, db))
result.Unwrap(cepheus.Update(Invoice, late, {Status: "paid"}, db))
io.Print(cepheus.Get(Standing, bo, db))
```

```text
Ok(missing)
Ok({Overdue: true})
Ok(missing)
```

- The derived fact is written in the same group as the invoice that gives it, and goes in the group that pays the
  invoice, since it has no other proof: a question reads it as any fact (here `Get`), and a `Watch` of it changes
  with it.
- `Define` finds each rule by its name: a rule already defined as given writes nothing, one whose definition changed
  is replaced, so a program defines its rules at each start, after `Connect`. The first definition derives what the
  rule gives over the facts already there.
- `Then: cepheus.Never` makes a **constraint**: a group that would give its `Where` an answer is refused whole, with
  Code `"invalid"` and the rule's name (G18).
- `Where` takes patterns, `Above`, `Below`, `Between` and `Not`; `Or`, `In` and `Prefix` are for questions. A variable
  of `Then` must be in a pattern of `Where` outside `Not`, and a rule cannot take the name of a property: both are
  refused with Code `"invalid"`.
- Rules are for tokens that write the whole database ([rights](server.md#rights-g16)): a rule reads every kind.

A rule's `Where` may hold `cepheus.Not(...)`: an answer holds when no fact matches its patterns, its variables in no
other pattern being its own ("there is no invoice `j` of `c` that is unpaid"). The value of `Then` may be
`cepheus.Sum(x)`, `Min(x)`, `Max(x)` or `Count()`: the rule gives its thing one fact, the sum, the smallest, the largest
value of `x` or the number of answers, kept up to date by difference at each write ([rules](rules.md#negation-and-aggregates-strata)):

```cesia norun
Books = cepheus.Kind("books", {Due: cepheus.Money(2), Clear: cepheus.Bool()})
db = result.Unwrap(cepheus.Connect(sys.Env("CEPHEUS_URL"), [Client, Invoice, Books], token = sys.Env("CEPHEUS_TOKEN")))
dueOf = cepheus.Rule("due-of", 3, (c, i, t) -> {Where: [[i, Invoice.Client, c], [i, Invoice.Status, "unpaid"], [i, Invoice.Total, t]], Then: [c, Books.Due, cepheus.Sum(t)]})
clear = cepheus.Rule("clear", 3, (c, i, j) -> {Where: [[i, Invoice.Client, c], cepheus.Not([j, Invoice.Client, c], [j, Invoice.Status, "unpaid"])], Then: [c, Books.Clear, true]})
io.Print(cepheus.Define([dueOf, clear], db))
io.Print(cepheus.Get(Books, ada, db))
io.Print(cepheus.Get(Books, bo, db))
owed = result.Unwrap(cepheus.Find(1, (i) -> {Where: [[i, Invoice.Client, ada], [i, Invoice.Status, "unpaid"]], Give: {Invoice: i}}, db))
result.Unwrap(cepheus.Update(Invoice, owed[1].Invoice, {Status: "paid"}, db))
io.Print(cepheus.Get(Books, ada, db))
```

```text
Ok(missing)
Ok({Due: 80.5, Clear: missing})
Ok({Due: missing, Clear: true})
Ok({Due: missing, Clear: true})
```

- A rule set where a property depends on its own absence (`Not`) or its own aggregate is refused with Code
  `"invalid"`, naming the cycle: such a rule would make its own premise false.
- The property of an aggregate takes one value, and only that rule gives it: a write of it is refused. A thing
  without answers has no fact (Ada's `Due` went with her last unpaid invoice). A sum past the largest int refuses the
  group; it never wraps.

## OWL 2 RL

**OWL 2** is the W3C's language of **ontologies**: an ontology says what the words of a domain mean, its **classes**
("a professor is a person") and its properties ("an advisor is a professor", "an e-mail is one person's"). **OWL 2
RL** is the part of it that rules compute completely: the W3C gives it as 78 rules ([rules](rules.md#owl-2-rl-a-library-of-rules)
tells how Cepheus holds each). From Cesia it is the package `owl`, beside `cepheus`, which the program takes too:

```toml
take = ["cesia/cepheus", "cesia/cepheus/owl"]
```

```cesia norun
use deps/www-celestial/cepheus/cesia/cepheus/owl
use std/list

Person = cepheus.Kind("person", {Name: cepheus.Text(), Email: cepheus.Text(many = true), Advisor: cepheus.Link(many = true)})
Label = cepheus.Kind("label", {Name: cepheus.Text(unique = true)})
onto = result.Unwrap(cepheus.Fork(cepheus.Empty, [owl.Vocabulary, Person, Label]))
io.Print(cepheus.Define(owl.Rl(), onto))
(* the ontology: a professor is a person; an advisor is a professor; an e-mail is one person's *)
c = result.Unwrap(cepheus.Write([
  cepheus.Add(cepheus.New(1), Label.Name, "Person"), cepheus.Add(cepheus.New(2), Label.Name, "Professor"),
  cepheus.Add(cepheus.New(2), owl.SubClassOf, cepheus.New(1)),
  cepheus.Add(cepheus.New(3), owl.Property, Person.Advisor), cepheus.Add(cepheus.New(3), owl.Range, cepheus.New(2)),
  cepheus.Add(cepheus.New(4), owl.Property, Person.Email), cepheus.Add(cepheus.New(4), owl.InverseFunctional, true)], onto)).Things
(* two records of one professor, the same e-mail in both, and a student whose advisor is the first *)
r = result.Unwrap(cepheus.Write([
  cepheus.Add(cepheus.New(1), Person.Email, "ada@uni.org"), cepheus.Add(cepheus.New(2), Person.Email, "ada@uni.org"),
  cepheus.Add(cepheus.New(2), Person.Name, "Ada"), cepheus.Add(cepheus.New(3), Person.Advisor, cepheus.New(1))], onto)).Things
io.Print(cepheus.Same(r[1], onto))
io.Print(cepheus.Get(Person, r[1], onto))
io.Print(list.Sort(result.Unwrap(cepheus.Get(owl.Vocabulary, r[2], onto)).Type), "are", c[1], "and", c[2])
(* a class disjoint from Person: Ada in it is refused *)
io.Print(cepheus.Write([cepheus.Add(cepheus.New(1), owl.DisjointWith, c[1]), cepheus.Add(r[1], owl.Type, cepheus.New(1))], onto))
result.Unwrap(cepheus.Write([cepheus.Retract(r[2], Person.Email, "ada@uni.org")], onto))
io.Print(cepheus.Same(r[1], onto), cepheus.Get(Person, r[1], onto))
```

```text
Ok(missing)
Ok([65542, 65543])
Ok({Name: "Ada", Email: ["ada@uni.org"], Advisor: []})
[65538, 65539] are 65538 and 65539
Err({Kind: "cepheus", Code: "invalid", Message: "constraint owl/cax-dw: [#65545 owl/DisjointWith #65538] [#65542 owl/Type #65545] [#65542 owl/Type #65538]"})
Ok([65542]) Ok({Name: missing, Email: ["ada@uni.org"], Advisor: []})
```

- **The vocabulary** is a kind like any, named `owl`: `owl.Vocabulary`, given to `Connect` (or `Fork`) with the
  program's own kinds, declares its properties `owl/Type`, `owl/SubClassOf` and the others (the same as the engine's
  library declares: [the vocabulary](rules.md#the-vocabulary)), and each is a name of the package: `owl.SubClassOf`.
  A class is a thing of the database, as any; an ontology is facts, written with `Write`, versioned like any.
- **An axiom about a property** is a fact of its **description**, a thing of its own whose `owl.Property` is the
  property: `[d, owl.Property, Person.Advisor]`, then `[d, owl.Range, professor]`. A property of a kind, written where
  a link goes, is its id in the database (read back, it is that Int).
- **`owl.Rl()` is data**: a list of 63 maps `{Rule, Library}`, one a rule, named `owl/` and the W3C's name
  (`owl/cax-sco`). `Define` takes each rule's definition from the engine's library, for this database, makes the
  things owl:Thing and owl:Nothing once (their `owl.Builtin` is `"Thing"` and `"Nothing"`), and defines the rules in
  one group, as any rules: a program defines them at each start, and the second time writes nothing. A list like any:
  `list.Filter` keeps a part of it.
- **Things made one.** `owl/prp-ifp` made the two records one thing: `cepheus.Same(x, db)` gives the **class** of x,
  the things the rules made the same as it. The facts of a class are kept on one of them, and `Get`, `Find` and
  `Watch` read any thing of a class as that one: the name written on the second record is read on the first. The
  e-mail retracted, they are two things again.
- **Refusals.** A constraint of OWL 2 RL (`owl/cax-dw` here: no thing in two disjoint classes) refuses its group whole,
  with Code `"invalid"` and the rule's name. A rule of the program that gives the list of one of the library's
  templates (`owl.IntersectionOf`, `owl.HasKey`: rules over every member at once) is refused by `Define`: only a
  write changes such a list.
  No rule beside OWL 2 RL's may hold a `Not` or an aggregate: its rules over a property that is a variable may give
  any property, so such a rule could read its own absence. That is why this example runs on a [fork](#forks): the
  chapter's database holds the rules with `Not` and `Sum` above. `owl.Rl()` without the vocabulary, or a name that is
  no rule of it, is an `Err` of Code `"invalid"`.
- **Rights.** The rules of OWL 2 RL read properties that are variables, so what they give may come from any kind: a
  token reads it, and `Same`, only when it reads every kind ([rights](server.md#rights-g16)); `Define` needs a token
  that writes the whole database. A token of some kinds gets `denied` for `Same`, a question and `Define`, and from
  `Get` none of the facts the rules may give: it learns no equality.
- **Security.** Nothing new is decoded: the maps of `owl.Rl()` only name rules, which `Define` takes from the engine's
  library (a name it lacks is an `Err`), and the writer checks them as any rule, under the rules' budgets (an equality
  storm costs n − 1 facts, never n², [rules](rules.md#equality-classes-of-equal-things)). `Same` over the network
  asks the server at most two questions, each under its budget of a question.

## Files

A **file kind** keeps files in the database: `Scans = cepheus.Files("scan")` is a kind with the fields `Name`,
`Size`, `Type`, `Owner` and `Content`, given to `Connect` as any other. `cepheus.Put(Scans, name, bytes, db, type,
owner, cold)` stores a file and gives its id once its bytes and its facts are on the server's disk; `cepheus.Read(Scans,
id, db, from, len)` gives its bytes, all of them or a range (only the chunks under it are read); `cepheus.List(Scans,
db)` its files (a `Find`); `cepheus.Delete(Scans, id, db)` retracts its facts; `cepheus.Erase(owner, db)` destroys an
owner's key, after which every file it owned is unreadable, everywhere its bytes went. The rights of a token on the kind
are its rights on the files. How the bytes are kept (chunks stored once, compressed, sealed, checked at every read):
[the vault](vault.md).

```text
Scans = cepheus.Files("scan")
db = cepheus.Connect("cepheus://srv1:7400/shop", [Client, Scans], token = sys.Env("CEPHEUS_TOKEN"), ca = "/etc/cepheus/ca.pem")?
f = cepheus.Put(Scans, "2026-11.pdf", sys.Read("2026-11.pdf")?, db, type = "application/pdf", owner = ada)?
head = cepheus.Read(Scans, f, db, from = 0, len = 1024)?
```

## Forks

A **fork** is a database in the program's memory that starts as another one: it reads and writes as a database, with
every check (types, `unique`, `Expect`, the schema), and nothing it writes goes anywhere: the database it started from
does not change, and neither does its history (G8). Making one copies nothing: the fork shares the state it starts
from (a **persistent** structure: a change makes new nodes and keeps the old ones, so both states stay readable).

`cepheus.Fork(from, kinds = [])` gives an `Ok` of a fork of `cepheus.Empty` (an empty database, for a test that needs
no server), of another fork, or of a database read on the server's machine (its local state now), with these kinds
declared in it:

```cesia norun
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
`"invalid"`: see [What is not built yet](#what-is-not-built-yet).

### Tests

A test of `cesia test` needs no server: it forks `cepheus.Empty` with the kinds it uses. A test file sits beside the
code it tests (`shop.test.ce` beside `shop.ce`), and its functions are named `is` and a capital:

```cesia norun
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
  it may read (G16). A token with [rights per kind](server.md#rights-g16) may not read the whole database: its reads go
  to the server, which gives it only the kinds it reads.
- Then the server sends each group's bytes on the follow stream before it forces them to its disk, and the package
  applies them to a new state while the disk works.
- One number in shared memory, a page of the server's that every local reader maps read-only, says which state is
  visible: the server stores it after each fsync and before it answers the writers. A read loads it and serves the
  state held under it, or waits the microseconds until that state is applied. No write waits for a reader.
- Each page read from a run file is checked by its CRC as it arrives (G7).

The follow stream is open when `Connect` returns; the first local read may wait for the follower to apply the groups
written since the database's newest run (its catch-up), and later ones only, now and then, the microseconds of a
frame on its way. What it costs: a domain of the program applies every group the server writes, by any program (1.7 µs
a change alone, about 4.5 µs under 18,000 groups a second, measured at the server), and the program holds a
cache of the pages of the database's newest runs (256 MB at most: the runs a merge replaced leave it at once) and the
changes since the last merge ([server](server.md#what-it-costs)).

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
| `auth`, `denied` | the token is unknown, or lacks the right on this database or on a kind the call reads or adds to (G16) | the token's rights: `cepheus token add` |
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

**A point read**, µs ($n = 11$ rounds):

| | Cesia client | OCaml client | PostgreSQL 18.6 |
|---|---:|---:|---:|
| on the server's machine: a local read | **0.77** [0.76, 0.82] | 0.24 [0.22, 0.36] | 26.4 [23.9, 32.3] through its Unix socket |
| over TCP and TLS 1.3 (loopback) | 51.6 [44.1, 63.4] | 37.1 [31.3, 46.8] | 52.3, in other rounds ([server](server.md#speed-beside-postgresql)) |
| at the server through its Unix socket | (not a path of the Cesia client: it reads locally there) | 8.9 [8.0, 9.6] | |

- The local read is 34 times faster than PostgreSQL's through its socket, and 3.2 times slower than the OCaml
  client's: the 0.53 µs between
  them are Cesia's side of the call, measured apart on a fork: the call of a package's native (a Cesia function, the
  native's stub, its 3 arguments converted) about 0.10 µs; finding the database and the kind, 0.05; making the map of
  4 fields and its `Ok` through Cesia's native interface, about 0.17; the loop of the benchmark itself, 0.08 (in the
  number above: a loop that calls a Cesia function of the same arguments). The target set before it was built, 1 µs, is met.
- Over TLS a read pays the round trip, the encryption (about 11 µs a round trip in C with OpenSSL here) and the
  server's work. The Cesia client reads its reply itself when nothing else is in flight (the window of three round
  trips, [many fibers](#many-fibers-one-connection)): without it, a reply crossed from the package's reader domain to
  Cesia's through a pipe, and a read cost 74.1 µs [51.2, 101.7] in the same rounds (the fast path: 0.67 times that, the
  median of the rounds' ratios). The 14 µs left over the OCaml client is the wake-up of Cesia's scheduler and the
  values made for Cesia; the target of 11 µs at the server through its Unix socket is for the OCaml client's path,
  which a Cesia program on the server's machine does not take (it reads locally).

**Durable writes**, $n = 7$ rounds of 3 s (each write an invoice of 4 facts, its group forced to the disk):

| | Cesia client, one connection | OCaml client |
|---|---:|---:|
| one writer | 189 a second [94, 296], 3.45 ms [3.01, 7.81] the median latency | 229 [155, 286], one connection |
| 64 writers | 7,021 a second [1,799, 8,604]: 64 fibers on one connection | 4,828 [335, 7,288]: 64 connections |

The intervals are wide: the disk's fsync takes 2 to 3 times as long from one run to the next (the server's
[benchmarks](server.md#speed-beside-postgresql) saw the same). What they show: 64 fibers on one connection write as fast as 64
connections, since their writes leave pipelined and share the server's fsyncs.

**Start-up and the first call**, ms a whole process (`cesia run`, $n = 101$ runs of each, alternated): `io.Print(1)`
alone 3.09 [3.04, 3.13]; the same with the package used but not called 3.51 [3.49, 3.54]; with one call 18.7 [18.6,
18.8].

- Nothing of the engine loads before the first call: the 0.42 ms of a program that uses the package are its Cesia code
  read and compiled, as for any package (`std/csv`, 40 lines, about 0.2 ms; `std/sql` about 3 ms, measured the same
  way but without the lock). `Watch` made the package's code 41 lines longer: 0.13 ms more (3.66 ms [3.60, 3.75]
  against 3.53 [3.48, 3.59] before it, $n = 51$ alternated).
- The first call costs 13 ms more (the engine stripped of its symbol table, as built now: 17.8 ms [17.6, 18.0] against
  20.3 [20.2, 20.5] before, $n = 55$; that run's process with the package unused: 4.5): checking the engine's
  fingerprint (BLAKE2 of 2.3 MB, 3.9 ms), loading the system's OpenSSL (1.3 ms), and linking 1.4 MB of machine code
  into the process. Once a process: a program connects once, at its start.

**OWL 2 RL** (`bench/reason.ml owlprep 1`: LUBM-1, 150,477 facts with the univ-bench ontology in OWL 2 RL's
vocabulary and no rule, a copy for each run; `Define(owl.Rl())` timed in the program, `reason.exe owldefine` for
OCaml's `define db (Owl.rl o)`; $n = 21$ rounds alternated, each the same 75,560 facts of `owl/Type` after): at the
server through its Unix socket 1.26 s [1.20, 1.44] against 0.93 [0.90, 1.01] for OCaml on the database in its own
process, 1.32× [1.22, 1.53] by the rounds' ratios; in a fork 0.82 s [0.81, 0.84] against 0.78 [0.76, 0.81], 1.06×
[0.99, 1.10].

- The server reasons as OCaml does: over TLS, where the program keeps no copy, `Define` takes 0.84 to 0.94 s (5
  rounds). The 0.3 s more through the socket are the program's local copy applying the change's 75,560 derived
  facts, so that its reads see them (a `Define` again, which writes nothing, waits that long for it there, 2 ms over
  TLS): the price of local reads for a write that large, paid once.
- In a fork the engine is the same code in the program's process: the 6 % are Cesia's process around it.
- Start-up does not grow: the package `owl` is read only by a program that uses it. `io.Print(1)` with the package
  `cepheus` used, not called, 3.64 ms against 3.62 before OWL (1.005 [0.98, 1.04], $n = 21$ rounds of 30 runs,
  alternated); the first call, which loads the engine, 18.87 ms against 18.78 (1.007 [0.98, 1.02]); `io.Print(1)`
  alone, the same program in both folders, 1.013 [1.00, 1.05]: the noise. The engine holds OWL 2 RL's rules, 58 KB
  more to check at its load (4.58 MB); the binding's own code is 14 KB smaller than before.

**The rest of the program.** The package's reader and, on the server's machine, its follower are domains of the
program's process, and OCaml 5 stops every domain at each minor collection, while the follower's state lives in the
program's heap. A loop that makes 2 million maps (`bench/cesia/gc.ce`, the best of three, $n = 7$): 125.8 ms [124.8,
131.7] alone, 126.9 [125.1, 129.0] with a local connection open; over TLS 124.9 and 128.2 with it; while 64 writers
write and the follower applies their groups, 140.7 ms alone and 149.4 with it (the intervals overlap; the writers'
server and the benchmark share the machine's cores). Idle, a connection costs the program nothing measurable.

**A live question's fan-out**, µs from a write's receipt to a fiber's change (`bench/cesia/watch.ce`: N fibers watch
the unpaid invoices of one client, one shared watch, while the program writes 50 invoices of that client one after the
other, each its own group; the program on the server's machine, so its follower computes the changes; $n = 5$ rounds,
a server started from the same database for each):

| fibers watching | a delivery, p50 | the last fiber of each group, p50 | its p99 |
|---:|---:|---:|---:|
| 1 | 19 [7, 21] | 19 | 68 |
| 100 | 359 [300, 556] | 475 [390, 790] | 2,505 |
| 1,000 | 3,756 [3,262, 4,325] | 5,420 [4,206, 7,141] | 15,204 |
| 2,500 | 12,901 [11,846, 16,575] | 17,597 [16,626, 21,970] | 35,810 |
| 10,000 | 66,073 [63,702, 71,294] | 90,119 [86,154, 101,859] | 129,904 |

- One fiber gets its change 19 µs after the write's receipt: the follower computed it during the fsync. The changes of
  one group cost the same for 1 or 10,000 watches of a question (one evaluation, [server](server.md#what-a-watch-costs));
  what grows is the delivery to each fiber, about 9 µs a fiber at 10,000: a wake from the follower's domain, the
  package's fiber that feeds the channel, and the channel to the watching fiber. Cesia's own channels alone (one
  sender, 10,000 fibers each reading its channel) take 57 ms to reach the last fiber: the package's path costs about
  twice that.
- Beside PostgreSQL's `LISTEN`/`NOTIFY` with a Go server (measured on the same machine on 2026-11-11 with PostgreSQL 18.6 and Go 1.26.3, a harness outside this repository; from the commit to the
  screen, its WebSocket included): 137 µs at 1 screen, 538 at 100, 2,822 at 1,000. At 1 and 100 the Cesia program has
  its change sooner, before any WebSocket; at 1,000 Go is ahead, its fan-out on 4 cores against one Cesia domain.
- 10,000 screens of one program: 90 ms to the last fiber, before their WebSockets. A server program with
  `cesia run --workers 4` holds 2,500 screens a process, each process its own connection and watch: 17.6 ms to the
  last fiber.

**Under sustained writes.** TechEmpower's updates (a request: 20 local reads, then one write of 20 facts; 32
connections; the database merges its delta every few seconds), on 2026-11-25, the machine shared with other work
(load 3.6 to 11.8), each side a process of its own on the same database, served in turn, beside a Go server on
PostgreSQL 18.6 as the control (`net/http` and `pgx`, the same tests):

| | plaintext, the first third of the rounds, then the last | RSS after about 20 minutes of writes: a program that only follows; one that reads and writes |
|---|---:|---:|
| Cesia before 1.3 and the client before these fixes | 29,950 then **14,852** a second | **322 MB**; **196 MB** |
| Cesia 1.3 and this version | 29,075 then 35,690 | 51 MB; 64 MB |
| Go and PostgreSQL | 42,247 then 65,086 | its process 25 to 28 MB; PostgreSQL 109 to 199 |

- The throughput (12 rounds of 15 s of updates and 5 s of plaintext, 19 minutes): before, a program halved after a few
  minutes and never came back, plaintext included, while Go rose as the machine grew freer. The cause was Cesia's: once
  a quarter of its memory limit had been reserved, it checked the limit at every large allocation, each time asking
  OCaml for the size of its heap; a `std/http` program with no database fell the same (29,294 then 14,918). Cesia 1.3
  looks once a quarter. (These rounds ran with the first of the two fixes below, which change only the pages kept.)
- The memory (20 minutes, two writers in turn, 10 of writes each, a program that only follows beside them): the local
  copy kept the pages of every run that a merge had replaced until its cache, 256 MB, was full, a base's worth at
  each merge; and the reads made while the copy moved its states onto the new base read the old one back, for good
  (with the first fix alone, the writer still grew to 119 MB). Now the replaced runs leave once the new states are
  published, and the pages read back leave at the next merge. The writer's rate stayed level: 1,430 then 1,384 a
  second.
- Where Go wins: plaintext, 1.8 times; and its process holds less than half the memory (28 against 64 MB), its pool
  holding no copy of the data, though with its database the two sides weigh about the same (PostgreSQL 109 to 199 MB,
  the Cepheus server 115 to 130). Cesia's updates are ahead here: 1,870 against 1,662 a second in the last third.

**Beside the giants.** No Cesia client of PostgreSQL exists (Cesia's `std/sql` speaks SQLite), so PostgreSQL is
measured through its C library, the fastest client it has: a Cesia program on the server's machine reads a row 34
times faster than any client of PostgreSQL can, since it makes no round trip, and over the network the Cesia client is
within the giant's own cost (51.6 against 52.3 µs, PostgreSQL's figure from other rounds, [server](server.md#speed-beside-postgresql)). Where PostgreSQL wins:
its client connects in 2 ms (Unix socket) or 4.3 ms (TLS), where the Cesia client's first call alone costs 13 ms;
and a program that holds no copy of the data uses less memory than a local reader (31 MB of a database of 1 M facts,
[server](server.md#what-it-costs)). Datomic's peers read in their own process too ("application processes
have their own copy of the query engine and database in local memory"), but see writes asynchronously unless they
call `sync`, a round trip ([server](server.md#beside-the-giants-by-their-documentation)); a local read of Cepheus is
linearizable without it.

## What is not built yet

- Forks of a database read at the server, which the server will make.
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
