# Concepts

## Facts

Everything Cepheus stores is a **fact**: a triple `(thing, property, value)`.

```
(70001, invoice/total,  Money 120000)     invoice 70001 has a total of 1200.00
(70001, invoice/client, Link 70000)       a link: its value is another thing
(70000, client/name,    Text "Ada Martin")
```

A **thing** has no table and no columns: it is a number with facts. Things are numbered by the database, densely, from
65,536 on; the numbers below are the properties (16 to 65,535) and the four system properties (1 to 4). Dense numbers
make "every fact of a thing" and "every thing that links here" direct array accesses.

A **value** is atomic and typed: `Int` (63 bits), `Float`, `Bool`, `Text`, `Date` (milliseconds since 1970, UTC),
`Money` (an exact decimal in minor units; the property fixes the number of digits), `Link` (another thing). A list
is several facts of a many-valued property; a structure is a thing.

## Properties are things too

A property is the thing `p` with the facts `(p, cepheus/name, Text "client/city")`, `(p, cepheus/type, Int code)`,
`(p, cepheus/many, Bool)` and `(p, cepheus/unique, Bool)`. Declaring a property is writing these facts, so a schema
change is a group like any other, kept in the journal, and the schema can be queried like any data. Rules the writer
enforces: a property needs a name and a type; its type and its cardinality never change (declare another property);
it can become unique only if no two things share a value.

- **one-valued** (the default): adding a value retracts the old one in the same group;
- **many-valued** (`many`): a set of values;
- **unique**: no two things have the same value (checked on the state after each group).

## Groups: a write is an event

A write is a **group**: a list of operations, applied all or nothing, with who (`by`, a number the application
chooses) and why (`why`, a text). The writer gives each group the next number (1, 2, 3, ... without gaps), the
database's time, and resolves it into **changes**: additions and retractions of exact facts. The journal keeps the
changes, so replaying never recomputes anything.

```ocaml
Cepheus.write db ~by:7 ~why:"rename" [ Add (ada, name, Text "Ada Durand") ]
(* in the journal, group 1042: - (ada name "Ada Martin")  + (ada name "Ada Durand") *)
```

Operations:

- `Add (thing, property, value)`; on a one-valued property it replaces the old value;
- `Retract (thing, property, value)`;
- `Expect (thing, property, Some value)`: the group fails with `Conflict` unless the fact holds before the group;
  `Expect (thing, property, None)`: unless the thing has no value for the property. This is optimistic concurrency:
  read a view, write with `Expect` on what you read.

A negative number in a thing position or in a `Link` is a **new thing** of this group: `-1`, `-2`, ... The receipt
gives their numbers (`Cepheus.thing receipt (-1)`).

Nothing is ever erased: a retraction is a new event, and the journal keeps every group.

## Views

A **view** is the exact state after one group. It never changes; taking one is free (an atomic read); reading needs
no lock, from any thread or domain. The database's view (`Cepheus.view db`) shows only durable groups. Old views stay
valid as long as they are held.

## Questions

A question is a list of **patterns** over numbered variables:

```ocaml
(* the unpaid invoices of the clients of Lyon, and their totals *)
{ vars = 3; ranges = [];
  where = [ { e = Var 0; p = city; v = Val (Text "Lyon") };
            { e = Var 1; p = client; v = Var 0 };
            { e = Var 1; p = status; v = Val (Text "unpaid") };
            { e = Var 1; p = total; v = Var 2 } ] }
```

The answer is every binding of the variables that makes every pattern a fact of the view, each binding once. `ranges`
keeps `lo <= x <= hi` for int, date and money variables. Cepheus answers with Generic Join, one variable at a time
(see [theory](theory.md)); the work is bounded by the largest possible answer, even on cyclic patterns (triangles).
In Cesia, a question will be a function whose parameters are the variables and which returns its patterns as data;
it compiles to this form.

## Forks

A **fork** is a temporary state that starts at a view:

```ocaml
let t = Cepheus.fork (Cepheus.view db) in
ignore (Cepheus.write t [ Add (inv, status, Text "paid") ]);
Cepheus.values (Cepheus.view t) inv status    (* [Text "paid"] *)
Cepheus.values (Cepheus.view db) inv status   (* [Text "unpaid"]: the database did not change *)
```

A fork is written to with the same function and the same checks as the database; nothing reaches the journal or any
file. `Cepheus.fork Cepheus.empty` is an empty database for a unit test. A fork of a fork works. Forks are never merged
back: to keep what was tried, write the same operations to the database.

## Databases

A database is a directory with its journal, its snapshots and a lock; one writer at a time (a second process gets
`Busy`). A server may hold many databases; what a database is for (an application, a customer, a data set) is the
application's choice. Questions live in one database.
