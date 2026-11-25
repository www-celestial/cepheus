# Tutorials: business problems solved step by step, PostgreSQL beside

Each tutorial takes one problem that business software meets every day, and solves it with Cepheus step by step: the
problem, the Cepheus solution, what PostgreSQL writes for the same thing, and the difference, measured or guaranteed.
The words are explained where they first appear, and in the [glossary](glossary.md); every call is described exactly
in [Cepheus from Cesia](cesia.md).

**How to read the code.** The Cesia blocks run as written, against a real server, each time the tests run
(`test/cesia.sh`): each block runs with every block before it, as one program, and what follows it is what it printed.
So the tutorials share one database, as the parts of one application do. The SQL is PostgreSQL 18.6, run with `psql`
on the same tables; what follows it is what PostgreSQL answered.

## The tutorials' database

Clients and their invoices, the data every tutorial uses. A **kind** groups the properties of a sort of thing; a
**thing** is a number, its id; a property of `many` values holds a list (a client's phones); `Closed` is a flag that a
closed account has.

```cesia norun
use deps/www-celestial/cepheus/cesia/cepheus
use std/fiber
use std/io
use std/list
use std/math
use std/result
use std/sys
use std/value

Client = cepheus.Kind("client", {Name: cepheus.Text(), City: cepheus.Text(), Phone: cepheus.Text(many = true), Closed: cepheus.Bool()})
Invoice = cepheus.Kind("invoice", {
  Client: cepheus.Link(), Number: cepheus.Int(unique = true), Total: cepheus.Money(2), Status: cepheus.Text(),
  Date: cepheus.Date(), Due: cepheus.Date(), PaidAt: cepheus.Date(),
})

defn connect(kinds)
  (** The tutorials' database, with these kinds declared in it: its address and its token from the environment. *)
  result.Unwrap(cepheus.Connect(sys.Env("CEPHEUS_URL"), kinds, token = sys.Env("CEPHEUS_TOKEN")))
end

db = connect([Client, Invoice])
ada = result.Unwrap(cepheus.Insert(Client, {Name: "Ada Martin", City: "Lyon", Phone: ["04 00 00 00 01", "06 00 00 00 01"]}, db))
bo = result.Unwrap(cepheus.Insert(Client, {Name: "Bo Lind", City: "Paris", Phone: ["01 00 00 00 02"]}, db))
cy = result.Unwrap(cepheus.Insert(Client, {Name: "Cy Moreau", City: "Nice"}, db))
di = result.Unwrap(cepheus.Insert(Client, {Name: "Di Weber", City: "Lyon", Closed: true}, db))
io.Print(ada, bo, cy, di)
```

```text
65536 65537 65538 65539
```

The same tables in PostgreSQL, as a PostgreSQL user writes them (a client's phones in a table of their own, since a
client may have several):

```sql
CREATE TABLE client (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, name text NOT NULL, city text NOT NULL,
                     closed bool NOT NULL DEFAULT false);
CREATE TABLE phone (client bigint NOT NULL REFERENCES client, number text NOT NULL);
CREATE TABLE invoice (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, client bigint NOT NULL REFERENCES client,
                      number bigint UNIQUE, total numeric(12,2) NOT NULL, status text NOT NULL,
                      date timestamptz NOT NULL, due timestamptz, paid_at timestamptz);
```

## 1. Invoice numbers with no gap

**The problem.** An invoice carries "a sequential number, based on one or more series, which uniquely identifies the
invoice" (the European VAT directive, 2006/112/EC, article 226), and the tax offices of several countries, France
among them, read it as a sequence with no gap: a missing number must be explained. Many clerks and programs bill at
the same time, and some invoices are refused on the way (a closed account, a check that fails): a refused invoice must
take no number.

**The Cepheus solution.** A **counter**, a thing with an `Int` property, that the group making the invoice increments
with `cepheus.Incr`: the database reads the counter when it applies the group, and `into` writes the new value as the
invoice's number, in the same group. A **group** is a write of several facts, all or nothing: refused, it writes
nothing, so it takes no number.

```cesia norun
Counter = cepheus.Kind("counter", {Last: cepheus.Int()})
db = connect([Client, Invoice, Counter])
numbers = result.Unwrap(cepheus.Insert(Counter, {Last: 0}, db))

defn bill(client, total, date, db)
  (** An invoice of this client, numbered in the group that makes it: refused whole, taking no number, when the
      client's account is closed. *)
  cepheus.Write([
    cepheus.Expect(client, Client.Closed),
    cepheus.Incr(numbers, Counter.Last, into = [cepheus.New(1), Invoice.Number]),
    cepheus.Add(cepheus.New(1), Invoice.Client, client),
    cepheus.Add(cepheus.New(1), Invoice.Total, total),
    cepheus.Add(cepheus.New(1), Invoice.Date, date),
    cepheus.Add(cepheus.New(1), Invoice.Status, "unpaid")
  ], db)
end
```

Step by step: `Expect(client, Client.Closed)` holds only if the client has no `Closed` fact (Di has one); `Incr`
counts one more; `New(1)` is the thing the group makes, the invoice, which gets the number. Now 30 invoices at the
same time, one **fiber** each (one of Cesia's light threads), a third of them for Di:

```cesia norun
who = [ada, bo, di]
when = [1772409600, 1748822400, 1772409600]
tasks = [fiber.Spawn(() -> bill(who[1 + math.Mod(k, 3)], 10 * k, when[1 + math.Mod(k, 3)], db)) for k in 1..30]
outcomes = [result.Unwrap(fiber.Wait(t)) for t in tasks]
io.Print("written:", list.Count(result.IsOk, outcomes), "refused:", list.Count(result.IsErr, outcomes))
got = result.Unwrap(cepheus.Find(2, (i, n) -> {Where: [[i, Invoice.Number, n]], Give: {Number: n}, Sort: [n]}, db))
io.Print([r.Number for r in got])
io.Print(cepheus.Get(Counter, numbers, db))
```

```text
written: 20 refused: 10
[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]
Ok({Last: 20})
```

(Ada's invoices are dated 2 March 2026, Bo's 2 June 2025: `when` gives seconds since 1970, as `sys.Now()` does.) The
20 invoices written hold the numbers 1 to 20, whatever order the fibers ran in, and the 10 refused took none.

**PostgreSQL** gives numbers with a **sequence**, `nextval`, which never goes back: a transaction that takes a number
and is then rolled back leaves a gap.

```sql
CREATE SEQUENCE invoice_number;
BEGIN;
INSERT INTO invoice (client, number, total, status, date) VALUES (1, nextval('invoice_number'), 10, 'unpaid', now());
ROLLBACK;
INSERT INTO invoice (client, number, total, status, date)
  VALUES (1, nextval('invoice_number'), 20, 'unpaid', now()) RETURNING number;
```

```text
 number
--------
      2
```

Its documentation says so: "the value obtained by nextval is not reclaimed for re-use if the calling transaction
later aborts", so "transaction aborts or database crashes can result in gaps" ([PostgreSQL, Sequence Manipulation
Functions](https://www.postgresql.org/docs/18/functions-sequence.html)). The way without a gap in PostgreSQL is a
counter row that each invoice's transaction updates:

```sql
BEGIN;
UPDATE counter SET last = last + 1 WHERE id = 1 RETURNING last;   -- the row is locked until COMMIT
INSERT INTO invoice (client, number, total, status, date) VALUES (1, 3, 30, 'unpaid', now());
COMMIT;
```

**The difference.** Both give no gap that way; the cost differs. PostgreSQL's `UPDATE` locks the counter row until
the transaction ends, and a transaction ends after its commit is on the disk (an fsync): every invoice waits for the
one before it to be written, so invoices are made one fsync at a time, whatever the number of clerks. Cepheus takes no
lock: its one writer applies the groups in order, reading the counter at each, and the groups that arrive while the
disk works share the next fsync (group commit), so 30 clerks wait for about one fsync together, not 30 one after the
other (measured in [a stock that never goes below zero](#7-a-stock-that-never-goes-below-zero), the same counter).

## 2. A job queue where each job is taken once

**The problem.** Work to do later is put in a queue: send a reminder, make a PDF, call a bank. Several workers take the
jobs, at the same time; each job must be done once, never by two workers, and a worker that stops in the middle of a
job (a crash, a deployment) must not lose it.

**The Cepheus solution.** A job is a thing with a `State`. A worker takes a job by a group that holds only if the job
is still queued (`Expect`), and marks it taken in the same group: of two workers that try the same job, the second's
group is refused with Code `"conflict"`, and that worker takes another. Nothing is locked: the refusal is the answer
of the same round trip.

```cesia norun
Job = cepheus.Kind("job", {Task: cepheus.Text(), State: cepheus.Text(), Worker: cepheus.Int(), Since: cepheus.Date()})
db = connect([Client, Invoice, Counter, Job])
for k in 1..40
  result.Unwrap(cepheus.Insert(Job, {Task: "send reminder $k", State: "queued"}, db))
end

defn take(w, db)
  (** Worker w takes one of the four oldest queued jobs (each worker aims at another one): an Ok of its id, an Ok of
      missing when none is queued, or the write's Err; a job another worker took first is a conflict, and w looks
      again. *)
  while true
    next = cepheus.Find(1, (j) -> {Where: [[j, Job.State, "queued"]], Give: {Job: j}, Sort: [j], Limit: 4}, db)?
    return result.Ok(missing) if value.Len(next) == 0
    j = next[1 + math.Mod(w, value.Len(next))].Job
    taken = cepheus.Write([
      cepheus.Expect(j, Job.State, "queued"),
      cepheus.Add(j, Job.State, "taken"), cepheus.Add(j, Job.Worker, w), cepheus.Add(j, Job.Since, sys.Now())
    ], db)
    return result.Ok(j) if result.IsOk(taken)
    return taken if taken.Error.Code != "conflict"
  end
end

defn worker(w, db)
  (** Takes jobs until none is queued, does each, and marks it done: an Ok of the number of jobs it did. *)
  did = 0
  while true
    j = take(w, db)?
    break if value.IsMissing(j)
    (* the work itself: here, send the reminder *)
    cepheus.Update(Job, j, {State: "done"}, db)?
    did += 1
  end
  result.Ok(did)
end
```

Four workers, at the same time:

```cesia norun
crew = [fiber.Spawn(() -> worker(w, db)) for w in 1..4]
did = [result.Unwrap(result.Unwrap(fiber.Wait(c))) for c in crew]
done = result.Unwrap(cepheus.Find(1, (j) -> {Where: [[j, Job.State, "done"]], Give: {Done: cepheus.Count()}}, db))
io.Print("jobs done by the workers:", list.Reduce((a, b) -> a + b, 0, did), "jobs done in the database:", done[1].Done)
```

```text
jobs done by the workers: 40 jobs done in the database: 40
```

The workers did 40 jobs between them and the database holds 40 jobs done: had two workers taken one job, they would
have counted 41. **A worker that stops** leaves its job taken; a sweep puts back the jobs taken more than 5 minutes
ago, each only if nobody took it again since (the same state and the same time, two `Expect`s):

```cesia norun
lost = result.Unwrap(cepheus.Insert(Job, {Task: "send reminder 41", State: "taken", Worker: 9, Since: sys.Now() - 3600}, db))
stale = result.Unwrap(cepheus.Find(2, (j, s) -> {
  Where: [[j, Job.State, "taken"], [j, Job.Since, s], cepheus.Below(s, sys.Now() - 300)],
  Give: {Job: j, Since: s},
}, db))
for r in stale
  back = [cepheus.Expect(r.Job, Job.State, "taken"), cepheus.Expect(r.Job, Job.Since, r.Since), cepheus.Add(r.Job, Job.State, "queued")]
  io.Print(result.IsOk(cepheus.Write(back, db)))
end
io.Print(result.Unwrap(cepheus.Get(Job, lost, db)).State)
```

```text
true
queued
```

**PostgreSQL** takes a job with a row lock, `FOR UPDATE`, and `SKIP LOCKED` lets a worker pass over the rows other
workers have locked instead of waiting for them:

```sql
CREATE TABLE job (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, task text NOT NULL, state text NOT NULL,
                  worker int, since timestamptz);
UPDATE job SET state = 'taken', worker = 1, since = now()
 WHERE id = (SELECT id FROM job WHERE state = 'queued' ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED)
 RETURNING id;
UPDATE job SET state = 'queued' WHERE state = 'taken' AND since < now() - interval '5 minutes';
```

**The difference.** Both take each job once: PostgreSQL by the row lock (the second worker skips the row, or, without
`SKIP LOCKED`, waits and finds it taken), Cepheus by `Expect` in a strictly serializable order
([G4](guarantees.md#g4-strict-serializability)). PostgreSQL's documentation warns that "skipping locked rows provides
an inconsistent view of the data", fit for a queue and nothing else ([SELECT, the locking
clause](https://www.postgresql.org/docs/18/sql-select.html#SQL-FOR-UPDATE-SHARE)); a job kept locked for the whole of
its work holds a connection and an open transaction for that time, which holds back `VACUUM`'s cleaning of the table.
Cepheus holds nothing during the work: a job's state is a fact, its history kept (who took it, when, why it went
back). What PostgreSQL does that Cepheus does not: a lock held by a worker that dies goes with its connection, so its
job comes back by itself; with Cepheus the sweep above does it.

## 3. Test data that leaves nothing

**The problem.** A test, or a "what if" (the totals if prices rose by 5 %), writes real data through the real code,
checks the result, and must leave nothing behind: not in the database, not in its counters, not in its history.

**The Cepheus solution.** A **fork**: a database in the program's memory that starts as another one, with every
check (types, `unique`, `Expect`, rules), and whose writes go nowhere. Making one copies nothing (the fork shares the
state it starts from) ([forks](cesia.md#forks)).

```cesia norun
what = result.Unwrap(cepheus.Fork(db))
for k in 1..3
  result.Unwrap(bill(bo, 1000 * k, 1772409600, what))
end
io.Print(cepheus.Get(Counter, numbers, what), cepheus.Get(Counter, numbers, db))
io.Print(bill(di, 50, 1772409600, what).Error.Code)
```

```text
Ok({Last: 23}) Ok({Last: 20})
conflict
```

The fork numbered three invoices, 21 to 23, with the code of [tutorial 1](#1-invoice-numbers-with-no-gap); the
database's counter is still at 20, and Di's invoice is refused in the fork as it would be in the database. A test of
`cesia test` needs no server at all: it forks `cepheus.Empty`, an empty database, with the kinds it uses.

```cesia norun
use deps/www-celestial/cepheus/cesia/cepheus
use std/list
use std/result

Counter = cepheus.Kind("counter", {Last: cepheus.Int()})
Invoice = cepheus.Kind("invoice", {Number: cepheus.Int(unique = true), Total: cepheus.Money(2)})

defn isNumberedWithoutGap()
  t = cepheus.Fork(cepheus.Empty, [Counter, Invoice])?
  c = cepheus.Insert(Counter, {Last: 0}, t)?
  bill = [cepheus.Incr(c, Counter.Last, into = [cepheus.New(1), Invoice.Number]), cepheus.Add(cepheus.New(1), Invoice.Total, 10)]
  first = cepheus.Write(bill, t)?.Things[1]
  refused = cepheus.Write(list.Prepend(cepheus.Expect(c, Counter.Last, 99), bill), t)
  second = cepheus.Write(bill, t)?.Things[1]
  refused.Error.Code == "conflict" and cepheus.Get(Invoice, first, t)?.Number == 1 and cepheus.Get(Invoice, second, t)?.Number == 2
end
```

```text
cesia test --allow native=cepheus
```

**PostgreSQL** runs a test inside a transaction that it rolls back:

```sql
BEGIN;
INSERT INTO invoice (client, number, total, status, date) VALUES (2, nextval('invoice_number'), 1000, 'unpaid', now());
ROLLBACK;
SELECT last_value FROM invoice_number;
```

```text
 last_value
------------
          3
```

**The difference.** The rolled-back transaction left its sequence moved on (`last_value` 3: tutorial 1's gap again),
and while it was open it held its rows' locks against every other writer of them; code under test that commits by
itself ends the test's transaction, and its data stays. A fork leaves nothing anywhere, guaranteed: the database it
starts from and its history do not change ([G8](guarantees.md#g8-forks)), no lock is taken, and any number of forks of one
database live at once, each its own. What PostgreSQL does that a fork does not: a transaction's writes go to its disk,
where a fork's stay in the program's memory, so a test that writes gigabytes needs that memory; and a fork of a
database read at the server (a program on another machine) is not built yet ([cesia](cesia.md#what-is-not-built-yet)).

## 4. Pages that never skip a row

**The problem.** A list of invoices is read a page at a time, the largest first. Between two pages, others write:
a new invoice must not make the next page show a row twice or hide one, and page 400 must cost what page 1 costs.

**The Cepheus solution.** `Sort`, `Limit` and `After`: the next page is the rows that come after the last row shown,
in the order ([pages](cesia.md#sort-limit-and-after-pages)).

```cesia norun
page = (after) -> ((i, t, c, n) -> {
  Where: [[i, Invoice.Total, t], [i, Invoice.Client, c], [c, Client.Name, n]],
  Give: {Total: t, Client: n},
  Sort: [cepheus.Desc(t)],
  Limit: 3,
  After: after,
})
first = result.Unwrap(cepheus.Find(4, page(missing), db))
io.Print(first)
(* meanwhile, another clerk writes an invoice larger than all of them *)
result.Unwrap(bill(ada, 1000, 1772409600, db))
io.Print(cepheus.Find(4, page(first[3]), db))
```

```text
[{Total: 300.0, Client: "Ada Martin"}, {Total: 280.0, Client: "Bo Lind"}, {Total: 270.0, Client: "Ada Martin"}]
Ok([{Total: 250.0, Client: "Bo Lind"}, {Total: 240.0, Client: "Ada Martin"}, {Total: 220.0, Client: "Bo Lind"}])
```

The second page goes on after 270, whatever came before it meanwhile; the new invoice is on the first page, for whoever
reads it next.

**PostgreSQL** pages with `OFFSET`, the rows to skip:

```sql
SELECT total FROM invoice ORDER BY total DESC LIMIT 3;            -- 300.00, 280.00, 270.00
INSERT INTO invoice (client, number, total, status, date) VALUES (1, 21, 1000, 'unpaid', now());
SELECT total FROM invoice ORDER BY total DESC LIMIT 3 OFFSET 3;
```

```text
 total
--------
 270.00
 250.00
 240.00
```

**The difference.** With `OFFSET` the invoice written between the pages pushed every row down by one: 270 shows twice,
and a row deleted between pages would hide one. `OFFSET 12000` also reads and drops 12,000 rows before the page, so a
deep page costs what all the pages before it cost. PostgreSQL's answer to both is **keyset pagination**, `WHERE
(total, id) < (270.00, 27) ORDER BY total DESC, id DESC`, with an index on `(total, id)` and the tie-breaking column
written by hand. `After` is that, built in: it breaks ties by the other fields of the row itself, so two rows are equal
in the order only when they are the same row, and needs no index chosen for it; the page after a row costs the same at
any depth ([how it is answered](cesia.md#sort-limit-and-after-pages)).

## 5. Clients with no invoice this year

**The problem.** Marketing wants the clients who bought nothing this year, to call them. The answer is about what is
*not* in the database.

**The Cepheus solution.** `cepheus.Not`: the client is kept when no invoice of theirs is dated this year. The
variables `i` and `d` are the `Not`'s own (they appear nowhere else in the question): "there is no `i` and `d` such
that...".

```cesia norun
y2026 = 1767225600
y2027 = 1798761600
idle = (c, n, i, d) -> {
  Where: [[c, Client.Name, n], cepheus.Not([i, Invoice.Client, c], [i, Invoice.Date, d], cepheus.Between(d, y2026, y2027 - 0.001))],
  Give: {Name: n},
  Sort: [n],
}
io.Print(cepheus.Find(4, idle, db))
```

```text
Ok([{Name: "Bo Lind"}, {Name: "Cy Moreau"}, {Name: "Di Weber"}])
```

Bo's invoices are of 2025, Cy has none, and Di's were refused. The list can stay live on the marketing screen: a
`Watch` of the same question sends the rows it loses and gains. Bo buys:

```cesia norun
w = result.Unwrap(cepheus.Watch(4, idle, db))
fiber.Receive(w.Changes)
result.Unwrap(bill(bo, 75, 1772409600, db))
io.Print(result.Unwrap(fiber.Receive(w.Changes)).Removed)
cepheus.Close(w)
```

```text
[{Name: "Bo Lind"}]
```

**PostgreSQL** writes `NOT EXISTS`:

```sql
SELECT name FROM client c
 WHERE NOT EXISTS (SELECT 1 FROM invoice i WHERE i.client = c.id
                   AND i.date >= '2026-01-01' AND i.date < '2027-01-01')
 ORDER BY name;
```

**The difference.** Both run an **anti-join**: for each client, one lookup that must find nothing (PostgreSQL's plan
says `Hash Anti Join` or `Nested Loop Anti Join`). Two differences remain. SQL's `NOT IN`, the form many people write
first, gives no row at all as soon as its subquery gives one `NULL` (`x NOT IN (1, NULL)` is unknown, never true);
Cepheus has no `NULL`, and `Not` has one meaning. And a `Watch` keeps the answer live, each change computed from the
facts that changed ([Not, Or and In](cesia.md#not-or-and-in)), where PostgreSQL's screen asks again.

## 6. Invoices of Lyon or Paris, unpaid or disputed

**The problem.** The collections desk wants the invoices of two cities that are unpaid or disputed, counted by city
and state; then a list of what is urgent: the unpaid invoices of Paris over 200, and every disputed one, wherever.

**The Cepheus solution.** `cepheus.In` for "one of these values", `cepheus.Or` for "one of these conditions". First,
some invoices are paid and some disputed (`byTotal` finds an invoice by its total, which is unique here):

```cesia norun
defn byTotal(t)
  (** The invoice of this total. *)
  result.Unwrap(cepheus.Find(1, (i) -> {Where: [[i, Invoice.Total, t]], Give: {Invoice: i}}, db))[1].Invoice
end
for t in [30, 60, 10]
  result.Unwrap(cepheus.Update(Invoice, byTotal(t), {Status: "paid"}, db))
end
result.Unwrap(bill(cy, 55, 1772409600, db))
for t in [90, 40, 55]
  result.Unwrap(cepheus.Update(Invoice, byTotal(t), {Status: "disputed"}, db))
end
open = cepheus.Find(4, (i, c, city, s) -> {
  Where: [[i, Invoice.Client, c], [c, Client.City, city], cepheus.In(city, ["Lyon", "Paris"]),
    [i, Invoice.Status, s], cepheus.In(s, ["unpaid", "disputed"])],
  Give: {City: city, Status: s, Invoices: cepheus.Count()},
  Sort: [city, s],
}, db)
io.Print(open)
urgent = cepheus.Find(5, (i, c, n, t, s) -> {
  Where: [[i, Invoice.Client, c], [c, Client.Name, n], [i, Invoice.Total, t], [i, Invoice.Status, s],
    cepheus.Or(cepheus.And([c, Client.City, "Paris"], [i, Invoice.Status, "unpaid"], cepheus.Above(t, 200)), [i, Invoice.Status, "disputed"])],
  Give: {Name: n, Total: t, Status: s},
  Sort: [n, t],
}, db)
io.Print(urgent)
```

```text
Ok([{City: "Lyon", Status: "disputed", Invoices: 1}, {City: "Lyon", Status: "unpaid", Invoices: 8}, {City: "Paris", Status: "disputed", Invoices: 1}, {City: "Paris", Status: "unpaid", Invoices: 9}])
Ok([{Name: "Ada Martin", Total: 90.0, Status: "disputed"}, {Name: "Bo Lind", Total: 40.0, Status: "disputed"}, {Name: "Bo Lind", Total: 220.0, Status: "unpaid"}, {Name: "Bo Lind", Total: 250.0, Status: "unpaid"}, {Name: "Bo Lind", Total: 280.0, Status: "unpaid"}, {Name: "Cy Moreau", Total: 55.0, Status: "disputed"}])
```

Cy's disputed invoice is in Nice: out of the first question, in the second.

**PostgreSQL** writes `IN` and `OR`, the same words:

```sql
SELECT c.city, i.status, count(*) FROM invoice i JOIN client c ON c.id = i.client
 WHERE c.city IN ('Lyon', 'Paris') AND i.status IN ('unpaid', 'disputed')
 GROUP BY c.city, i.status ORDER BY c.city, i.status;
SELECT c.name, i.total, i.status FROM invoice i JOIN client c ON c.id = i.client
 WHERE (c.city = 'Paris' AND i.status = 'unpaid' AND i.total > 200) OR i.status = 'disputed'
 ORDER BY c.name, i.total;
```

**The difference.** The words are the same; the way differs. Each alternative of Cepheus's `Or` is asked as a question
of its own, from the index that gives it the fewest candidates (here the disputed invoices, read from the index of
`Status`), with the alternatives before it as `Not`s, so their answers never overlap and none is kept to remove
copies; each answer comes once, guaranteed ([G11](guarantees.md#g11-exact-answers)). PostgreSQL reads an `OR` over two tables of a
join as a filter on the joined rows, unless it rewrites it (a `BitmapOr` works within one table); the rewrite by hand
is a `UNION`, which sorts or hashes every row to remove copies. `In` is a list of values in both.

## 7. A stock that never goes below zero

**The problem.** A shop sells its last lamps to many buyers at once. The stock must never go below zero: no lamp sold
that is not there, whatever the number of buyers clicking at the same moment.

**The Cepheus solution.** The stock is a counter that each order counts down with `Incr`, in the order's group, and a
**constraint**, a rule whose head is `cepheus.Never`, refuses every group after which a stock would be negative
([rules](cesia.md#rules), [G18](guarantees.md#g18-constraints-hold)). The rule is defined once, at the program's start:

```cesia norun
Item = cepheus.Kind("item", {Name: cepheus.Text(), Stock: cepheus.Int()})
db = connect([Client, Invoice, Counter, Job, Item])
never = cepheus.Rule("stock-never-negative", 2, (x, q) -> {Where: [[x, Item.Stock, q], cepheus.Below(q, 0)], Then: cepheus.Never})
io.Print(cepheus.Define([never], db))
lamp = result.Unwrap(cepheus.Insert(Item, {Name: "desk lamp", Stock: 10}, db))
orders = [fiber.Spawn(() -> cepheus.Write([cepheus.Incr(lamp, Item.Stock, by = -1)], db)) for k in 1..12]
outcomes = [result.Unwrap(fiber.Wait(o)) for o in orders]
io.Print("sold:", list.Count(result.IsOk, outcomes), "refused:", [r.Error.Code for r in list.Filter(result.IsErr, outcomes)])
io.Print(cepheus.Get(Item, lamp, db))
```

```text
Ok(missing)
sold: 10 refused: ["invalid", "invalid"]
Ok({Name: "desk lamp", Stock: 0})
```

Twelve buyers, ten lamps: ten orders written, two refused, the stock at 0. An order's other facts (its lines, its
client) go in the same group as the `Incr`, so a refused order leaves none of them.

**PostgreSQL** writes a `CHECK` and an `UPDATE` that counts down:

```sql
CREATE TABLE item (id int PRIMARY KEY, name text NOT NULL, stock int NOT NULL CHECK (stock >= 0));
INSERT INTO item VALUES (1, 'desk lamp', 0);
UPDATE item SET stock = stock - 1 WHERE id = 1;
```

```text
ERROR:  new row for relation "item" violates check constraint "item_stock_check"
DETAIL:  Failing row contains (1, desk lamp, -1).
```

**The difference.** Both keep the stock at zero or more, guaranteed. A `CHECK` sees one row; a constraint of Cepheus is
a question over any facts ("the lamps reserved never exceed the lamps in stock", over the order lines), where
PostgreSQL needs a trigger, and a trigger sees other rows only under `SERIALIZABLE` or with locks it takes. And the
cost, as for tutorial 1's counter: each `UPDATE` of the lamp's row waits for the one before it to commit.

## 8. Invoices paid late, loans between 2.5 and 3 %

**The problem.** Finance wants the invoices paid after their due date (two dates of one invoice compared with each
other), and the loans whose rate is between 2.5 and 3 % (a range of floats).

**The Cepheus solution.** `cepheus.Less(x, y)` keeps $x < y$, two variables of one type; `Between` takes a `Float`
variable ([Less, LessOrEqual and Optional](cesia.md#less-lessorequal-and-optional)). First, three of Ada's invoices are
paid, with their due dates:

```cesia norun
for x in [[120, 1774915200, 1776211200], [150, 1774915200, 1774915200], [180, 1777507200, 1779235200]]
  result.Unwrap(cepheus.Update(Invoice, byTotal(x[1]), {Due: x[2], PaidAt: x[3], Status: "paid"}, db))
end
late = result.Unwrap(cepheus.Find(6, (i, c, n, t, d, p) -> {
  Where: [[i, Invoice.Client, c], [c, Client.Name, n], [i, Invoice.Total, t], [i, Invoice.Due, d], [i, Invoice.PaidAt, p], cepheus.Less(d, p)],
  Give: {Client: n, Total: t, Due: d, Paid: p},
  Sort: [t],
}, db))
io.Print([{Client: r.Client, Total: r.Total, DaysLate: (r.Paid - r.Due) / 86400} for r in late])

Loan = cepheus.Kind("loan", {Client: cepheus.Link(), Rate: cepheus.Float()})
db = connect([Client, Invoice, Counter, Job, Item, Loan])
for x in [[ada, 2.4], [bo, 2.5], [cy, 2.75], [ada, 3.0], [bo, 3.1]]
  result.Unwrap(cepheus.Insert(Loan, {Client: x[1], Rate: x[2]}, db))
end
io.Print(cepheus.Find(4, (l, c, n, r) -> {
  Where: [[l, Loan.Rate, r], cepheus.Between(r, 2.5, 3.0), [l, Loan.Client, c], [c, Client.Name, n]],
  Give: {Client: n, Rate: r},
  Sort: [r],
}, db))
```

```text
[{Client: "Ada Martin", Total: 120.0, DaysLate: 15.0}, {Client: "Ada Martin", Total: 180.0, DaysLate: 20.0}]
Ok([{Client: "Bo Lind", Rate: 2.5}, {Client: "Cy Moreau", Rate: 2.75}, {Client: "Ada Martin", Rate: 3.0}])
```

The invoice of 150 was paid on its due date: `Less` is strict, so it is not late (`LessOrEqual` would keep it).

**PostgreSQL** writes the comparison and the range in `WHERE`:

```sql
SELECT c.name, i.total, i.due, i.paid_at FROM invoice i JOIN client c ON c.id = i.client
 WHERE i.due < i.paid_at ORDER BY i.total;
SELECT c.name, l.rate FROM loan l JOIN client c ON c.id = l.client
 WHERE l.rate BETWEEN 2.5 AND 3.0 ORDER BY l.rate;
```

**The difference.** The same answers. Two dates of one invoice are compared row by row in both. Between two things
(the invoices dated after a client's last payment, say), Cepheus reads the second side as a range of its sorted index
once the first is bound, the inequality join of [Khayyat 2015](references.md#joins). On floats, Cepheus orders as its
`Sort` does, IEEE 754's totalOrder: $-0$ comes before $0$, so `Below(r, 0)` keeps a $-0$; PostgreSQL's `float8`
holds $-0 = 0$, so `r < 0` leaves it out. Both put NaN after every number. Measured on the benchmarks' data:
[below](#what-the-new-conditions-cost).

## 9. Clients with their phone, if they have one

**The problem.** The list of clients for the call center: every client, with each of their phones, and the clients
without a phone too, last, so that they get one.

**The Cepheus solution.** `cepheus.Optional([c, Client.Phone, p])`: for each client, a row for each phone, or one row
where `p` is `missing` when the client has none. This is SQL's `LEFT JOIN`.

```cesia norun
calls = (c, n, p) -> {Where: [[c, Client.Name, n], cepheus.Optional([c, Client.Phone, p])], Give: {Name: n, Phone: p}, Sort: [n]}
io.Print(cepheus.Find(3, calls, db))
byPhone = (c, n, p) -> {Where: [[c, Client.Name, n], cepheus.Optional([c, Client.Phone, p])], Give: {Name: n, Phone: p}, Sort: [cepheus.Desc(p)]}
io.Print(cepheus.Find(3, byPhone, db))
```

```text
Ok([{Name: "Ada Martin", Phone: "04 00 00 00 01"}, {Name: "Ada Martin", Phone: "06 00 00 00 01"}, {Name: "Bo Lind", Phone: "01 00 00 00 02"}, {Name: "Cy Moreau", Phone: missing}, {Name: "Di Weber", Phone: missing}])
Ok([{Name: "Ada Martin", Phone: "06 00 00 00 01"}, {Name: "Ada Martin", Phone: "04 00 00 00 01"}, {Name: "Bo Lind", Phone: "01 00 00 00 02"}, {Name: "Cy Moreau", Phone: missing}, {Name: "Di Weber", Phone: missing}])
```

Ada has two phones, so two rows; the clients without one come last, in both orders. On the call center's screen the
list is live: Cy gives a phone, and the change takes away Cy's row without one and gives the row with it.

```cesia norun
w = result.Unwrap(cepheus.Watch(3, calls, db))
fiber.Receive(w.Changes)
result.Unwrap(cepheus.Write([cepheus.Add(cy, Client.Phone, "04 00 00 00 03")], db))
change = result.Unwrap(fiber.Receive(w.Changes))
io.Print(change.Added, change.Removed)
cepheus.Close(w)
```

```text
[{Name: "Cy Moreau", Phone: "04 00 00 00 03"}] [{Name: "Cy Moreau", Phone: missing}]
```

**PostgreSQL** writes a `LEFT JOIN`:

```sql
SELECT c.name, p.number FROM client c LEFT JOIN phone p ON p.client = c.id ORDER BY p.number DESC;
```

```text
    name    |     number
------------+----------------
 Cy Moreau  |
 Di Weber   |
 Ada Martin | 06 00 00 00 01
 Ada Martin | 04 00 00 00 01
 Bo Lind    | 01 00 00 00 02
```

**The difference.** PostgreSQL puts its `NULL`s last ascending and *first* descending, so the call center's list by
phone, largest first, starts with the clients who have none, unless the query says `NULLS LAST`; Cepheus puts a
missing value last in both directions. The meaning is SQL's `LEFT JOIN`, and SPARQL's `OPTIONAL`, for one pattern
([Pérez, Arenas and Gutierrez 2009](references.md#joins)), with one rule PostgreSQL does not need: the optional
variable is in no other part of the question, so the question has one meaning whatever the order of its parts. Measured:
[below](#what-the-new-conditions-cost).

## What the new conditions cost

(Measured in the next step.)

## Each tutorial in one line

| Problem | Cepheus | PostgreSQL | The difference |
|---|---|---|---|
| [invoice numbers with no gap](#1-invoice-numbers-with-no-gap) | `Incr` into the number, in the invoice's group | `SEQUENCE` (gaps) or a counter row (a lock until commit) | no gap and no lock: groups share the fsync |
| [a job taken once](#2-a-job-queue-where-each-job-is-taken-once) | `Expect` the job queued | `FOR UPDATE SKIP LOCKED` | nothing locked during the work; a sweep for stopped workers |
| [test data that leaves nothing](#3-test-data-that-leaves-nothing) | `Fork` | `BEGIN` … `ROLLBACK` | nothing moves, not even a counter; no lock |
| [pages that never skip a row](#4-pages-that-never-skip-a-row) | `Sort`, `Limit`, `After` | `OFFSET`, or keyset by hand | keyset built in, ties broken by the row |
| [clients with no invoice this year](#5-clients-with-no-invoice-this-year) | `Not` | `NOT EXISTS` | one meaning (no `NULL`), live with `Watch` |
| [Lyon or Paris, unpaid or disputed](#6-invoices-of-lyon-or-paris-unpaid-or-disputed) | `In`, `Or` | `IN`, `OR`, `UNION` | each alternative from its own index, no copies to remove |
| [a stock never below zero](#7-a-stock-that-never-goes-below-zero) | `Incr` and a `Never` rule | `CHECK` and `UPDATE` | a constraint over any facts, not one row |
| [paid late, loans in a range](#8-invoices-paid-late-loans-between-25-and-3-) | `Less`, `Between` on a float | `a < b`, `BETWEEN` | totalOrder on floats |
| [clients with their phone](#9-clients-with-their-phone-if-they-have-one) | `Optional` | `LEFT JOIN` | missing last in both directions, live with `Watch` |
