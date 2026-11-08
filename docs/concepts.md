# Concepts

What Cepheus stores, how a program writes and reads it, and what a reader can and cannot see. Every example on this
page is a whole program: `dune test` compiles and runs each one and checks the output shown under it. How the engine
does it (the journal, the recovery, the merge, the cache) is in [architecture](architecture.md); the exact promises
are in [guarantees](guarantees.md); every term is also in the [glossary](glossary.md).

## Facts: the entity–attribute–value model

Everything Cepheus stores is a **fact**, a triple `(thing, property, value)`: "invoice 65537 has the total 1,200.00".
This is the **entity–attribute–value model** (EAV): instead of tables with fixed columns, a database is a set of
small statements, each naming one thing, one property of it and one value. The same model is the **triple** of RDF
(subject, predicate, object) and the **datom** of Datomic (entity, attribute, value, transaction, added); in Cepheus
the transaction and the added-or-retracted flag of a datom live in the journal's groups (below), and a view holds the
facts that are true at its group.

- A **thing** (the entity) is a number and nothing else: it has no table and no columns, only the facts about it.
  The database gives thing numbers densely, from 65,536 up, in the order things are made. Dense numbers make "every
  fact of a thing" an array access, not a search ([architecture](architecture.md#indexes-the-base-and-the-delta)).
- A **property** (the attribute) is itself a thing, numbered from 16 to 65,535, with a name such as `client/city`, a
  type, and two flags (below). Numbers 1 to 4 are the four system properties that describe properties.
- A **value** is atomic and typed: `Int` (a 63-bit signed integer), `Float`, `Bool`, `Text` (bytes; UTF-8 by
  convention, Cepheus does not look inside), `Date` (milliseconds since 1970-01-01 UTC), `Money` (an exact decimal
  kept as an integer of minor units, the number of decimal digits being the property's, 0 to 18) and `Link` (another
  thing: a reference). There is no list and no structure inside a value: a list is several facts of a many-valued
  property, a structure is a thing with its own facts.

```ocaml
open Cepheus

let () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ name; client; total ]) =
    declare db [ prop "client/name" Ttext; prop "invoice/client" Tlink; prop "invoice/total" (Tmoney 2) ]
  in
  let r = Result.get_ok (write db [ Add (-1, name, Text "Ada Martin"); Add (-2, client, Link (-1)); Add (-2, total, Money 120000) ]) in
  let ada = thing r (-1) and invoice = thing r (-2) in
  let v = view db in
  let show e = List.iter (fun (p, x) -> Printf.printf "(%d, %d, %s)\n" e p (Value.to_string x)) (get v e) in
  show invoice;
  show ada;
  show name (* a property is a thing too: its name, its type code, its two flags *)
```

```output
(65537, 17, #65536)
(65537, 18, money 120000)
(65536, 16, "Ada Martin")
(16, 1, "client/name")
(16, 2, 3)
(16, 3, false)
(16, 4, false)
```

`Money 120000` with two digits is 1,200.00. A link is printed `#65536`.

## Properties and the schema

A property is described by four facts about its thing: `cepheus/name` (1, a text, unique), `cepheus/type` (2, the
type's code), `cepheus/many` (3) and `cepheus/unique` (4). So the **schema** (the list of properties and their types)
is data like any other: declaring a property is writing these four facts, a change of schema is a group kept in the
journal like every write, and the schema can be read and queried like the rest. `declare` returns the numbers of the
properties it is given, declaring in one group those that do not exist yet; `property v name` and `describe v p`
read the schema of a view.

- **one-valued** (the default; the **cardinality** is one): adding a value retracts the old one in the same group;
- **many-valued** (`~many:true`): the property holds a set of values;
- **unique** (`~unique:true`): no two things have the same value, checked on the state after each group.

The writer enforces these rules on property things: a property needs both a name and a type; its type and its
cardinality never change (declare another property instead); it can become unique only if no two things share a
value; it can be removed (its name and type retracted) only once nothing has a value for it.

## Groups: a write is a transaction

A **transaction** is a unit of work that a database applies entirely or not at all. In Cepheus a write is a **group**:
a list of operations applied **atomically** (all or nothing), with who wrote it (`~by`, a number the application
chooses, 0 by default) and why (`~why`, a text, empty by default). The writer gives each group the next number (1, 2,
3, ... with no gap) and the database's clock, and resolves it into **changes**: additions and retractions of exact
facts. The **journal**, a file the database only ever appends to, keeps those changes; replaying the journal applies
them again and never recomputes anything.

- `Add (thing, property, value)`: on a one-valued property, it also retracts the value the thing had;
- `Retract (thing, property, value)`;
- `Expect (thing, property, Some value)`: the group fails with `Conflict` unless the fact holds before the group;
  `Expect (thing, property, None)`: unless the thing has no value for the property. Every `Expect` of a group is
  checked against the state just before the group, wherever it sits in the list.

A negative number in a thing position or inside a `Link` is a **new thing** of this group: `-1`, `-2`, ... are given
the next thing numbers in the order they first appear, and the receipt says which (`thing receipt (-1)`). An `Add` of
a fact that already holds, or a `Retract` of one that does not, changes nothing; a group whose operations change
nothing still takes a number.

Nothing is erased: a retraction is a change of a later group, and the journal keeps every group. Here the journal of
a closed database, read with the internal `Journal.read`, shows a rename as the writer resolved it:

```ocaml
open Cepheus

let () =
  let db = Result.get_ok (open_ "shop") in
  let[@warning "-8"] (Ok [ name ]) = declare db [ prop "client/name" Ttext ] in
  let ada = thing (Result.get_ok (write db ~by:7 ~why:"signup" [ Add (-1, name, Text "Ada Martin") ])) (-1) in
  ignore (write db ~by:7 ~why:"rename" [ Add (ada, name, Text "Ada Durand") ]);
  close db;
  let id = Engine.read_meta Disk.real "shop" in
  Journal.read Disk.real "shop/journal" id (fun (g : Group.t) ->
      if g.n >= 3 then begin
        Printf.printf "group %d, by %d, %S:" g.n g.by g.why;
        Array.iter
          (fun (c : Group.change) -> Printf.printf " %s(#%d %d %s)" (if c.add then "+" else "-") c.e c.p (Value.to_string c.v))
          g.changes;
        print_newline ()
      end)
```

```output
group 3, by 7, "signup": +(#65536 16 "Ada Martin")
group 4, by 7, "rename": -(#65536 16 "Ada Martin") +(#65536 16 "Ada Durand")
```

Who, when and why are kept with each group in the journal; they are not facts of the views (a question cannot ask
"what did 7 change yesterday" yet).

## Views

A **view** is the exact state after one group: every fact that the groups 1 to n left true, and nothing of the groups
after n. It never changes once taken, taking one is free (one atomic read), and reading it needs no lock, from any
thread or domain (an OCaml 5 domain is a thread of execution that runs in parallel with the others on its own core).
`view db` is the newest **durable** state: it holds only groups whose journal frame is on the disk. A view stays valid
as long as it is held, however many groups come after it; the memory it keeps is only what differs from the newer
views (a persistent data structure, [architecture](architecture.md#indexes-the-base-and-the-delta)).

## Isolation: exactly what a reader and a writer see

**Isolation** says what one transaction can see of the others running at the same time. The standard levels, from
weak to strong: read committed (each read sees the data committed when it runs), **snapshot isolation** (every read
of a transaction sees the snapshot taken at its start, and a transaction fails if another one wrote the same item
after that start: "first committer wins"), **serializable** (the result equals some execution of the transactions one
at a time), and **strict serializability** (serializable in an order that also respects real time: a transaction
that finished before another started comes first). Cepheus gives these, exactly:

1. **Groups are strictly serializable** (G4). One writer per database applies the groups one at a time, each on the
   state the previous one left, in the order of their numbers, and a number is given when the writer takes the group,
   after the client submitted it. A group's only reads are its `Expect`s, checked against the newest state at the
   moment it is applied.
2. **A view is a snapshot of a committed prefix** (G5). Every read of one view sees the state after group n, all of
   it: no read sees half a group, two reads of the same view never disagree (no non-repeatable read, no phantom inside
   a view), and a read never waits for a write nor makes one wait. A thread's successive `view db` never go back; after
   `write` returned `Ok` for group n, every view taken afterwards holds n (read your writes).
3. **A read-then-write (read a view, then write a group) is validated only by its `Expect`s.** This is optimistic
   concurrency control: read without locks, and let the writer check at the end that what was read still holds. If
   the group states with `Expect` every fact it relied on (`Some v`) and every absence it relied on (`None`), the whole
   read-then-write is serializable. What is not stated is not checked:
   - a **lost update**: two clients read a balance of 100 and each writes 100 + x with no `Expect`; both groups
     succeed and one addition is lost. Snapshot isolation would refuse the second (first committer wins); Cepheus does
     not, because a one-valued `Add` replaces whatever value is there;
   - a **phantom**: a question's answer is a set (the invoices of a client), and an `Expect` names one fact, so a new
     matching fact written meanwhile is not seen. To protect a set, keep a fact that every writer of the set expects
     and changes, such as a version number on the client (the "materialize the conflict" technique of Fekete et al.
     2005).

The classic case that snapshot isolation lets through, **write skew**: two doctors are on call, and each goes off call
if the other stays. Under snapshot isolation (Oracle's SERIALIZABLE, PostgreSQL's REPEATABLE READ) both transactions
see two doctors on call, write different rows, and both commit: nobody is on call. In Cepheus each writes its change
with an `Expect` on the other's fact; the writer applies one, and the other's `Expect` no longer holds:

```ocaml
open Cepheus

let () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ on_call ]) = declare db [ prop "doctor/on-call" Tbool ] in
  let r = Result.get_ok (write db [ Add (-1, on_call, Bool true); Add (-2, on_call, Bool true) ]) in
  let alice = thing r (-1) and bob = thing r (-2) in
  let off me other = write db ~by:me [ Expect (other, on_call, Some (Bool true)); Add (me, on_call, Bool false) ] in
  let show = function Ok r -> Printf.printf "group %d\n" r.group | Error e -> print_endline (message e) in
  show (off alice bob);
  show (off bob alice)
```

```output
group 4
conflict: #65536 does not have true for property 16
```

## Questions

A **question** is a **conjunctive query**: a list of **patterns** `(thing, property, value)` in which the thing and
the value are either constants or **variables**, numbered from 0. The answer is every **binding** (a value for each
variable) that makes every pattern a fact of the view, each binding once (G11). A variable in a thing position is a
link; a variable's type comes from the properties it appears with. `ranges` keep `lo <= x <= hi` for a variable whose
values are numbers (an int, a date, money, a bool as 0 and 1, a link as its thing number).

Answering such a question means **joining** the patterns: matching their shared variables. Cepheus uses one join
algorithm, **Generic Join**, which binds one variable at a time and, for each, enumerates only the smallest set of
candidates a pattern offers and checks each against the other patterns. It is **worst-case optimal**: its work is
bounded by the largest answer the question could have on data of that size (the AGM bound), even for cyclic patterns
such as triangles, where a plan of joins two at a time can build far more intermediate rows than the answer
([architecture](architecture.md#questions), [theory](theory.md#4-generic-join)).

```ocaml
open Cepheus

let () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ city; client; status; total ]) =
    declare db [ prop "client/city" Ttext; prop "invoice/client" Tlink; prop "invoice/status" Ttext; prop "invoice/total" (Tmoney 2) ]
  in
  let r = Result.get_ok (write db [ Add (-1, city, Text "Lyon"); Add (-2, city, Text "Paris") ]) in
  let lyon = thing r (-1) and paris = thing r (-2) in
  List.iter
    (fun (c, s, t) -> ignore (write db [ Add (-1, client, Link c); Add (-1, status, Text s); Add (-1, total, Money t) ]))
    [ lyon, "unpaid", 12000; lyon, "paid", 5000; paris, "unpaid", 7000; lyon, "unpaid", 3000 ];
  (* the unpaid invoices of the clients of Lyon, and their totals: variables 0 client, 1 invoice, 2 total *)
  let q =
    { vars = 3; ranges = [];
      where = [ { e = Var 0; p = city; v = Val (Text "Lyon") }; { e = Var 1; p = client; v = Var 0 };
                { e = Var 1; p = status; v = Val (Text "unpaid") }; { e = Var 1; p = total; v = Var 2 } ] }
  in
  let v = view db in
  (match find v q with
   | Ok rows -> List.iter (fun r -> Printf.printf "%s %s\n" (Value.to_string r.(1)) (Value.to_string r.(2))) (List.sort compare rows)
   | Error e -> print_endline (message e));
  (* the same question folded into a sum, with no value built: a money word is the amount itself *)
  match fold v q ~init:(fun () -> 0) ~step:(fun s w -> s + w.(2)) ~merge:( + ) with
  | Ok s -> Printf.printf "sum %d\n" s
  | Error e -> print_endline (message e)
```

```output
#65538 money 12000
#65541 money 3000
sum 15000
```

## Forks

A **fork** is a temporary state that starts at a view: it is written to with the same `write`, under the same checks
(the same function resolves its groups), and nothing it does reaches the journal or any file (G8). Making one copies
nothing: a view is a persistent value, and the fork's writes make new versions beside it (structural sharing: the new
version shares every part it did not change with the old one). `fork empty` is an empty database for a unit test; a
fork of a fork works; a fork is never merged back (to keep what was tried, write the same operations to the
database: one way to write).

```ocaml
open Cepheus

let () =
  let db = Result.get_ok (open_ "shop") in
  let[@warning "-8"] (Ok [ status ]) = declare db [ prop "invoice/status" Ttext ] in
  let inv = thing (Result.get_ok (write db [ Add (-1, status, Text "unpaid") ])) (-1) in
  let t = fork (view db) in
  ignore (write t [ Add (inv, status, Text "paid") ]);
  let show v = Value.to_string (List.hd (values v inv status)) in
  Printf.printf "fork: %s, database: %s\n" (show (view t)) (show (view db));
  close db
```

```output
fork: "paid", database: "unpaid"
```

## Databases

A database is a directory: its journal, its snapshots (copies of the state that spare a restart most of the journal),
and a lock. One process at a time opens it (G9); another open gets `Busy`. A server may hold many databases; what a
database is for (an application, a customer, a data set) is the application's choice. A question reads one database.

```ocaml
open Cepheus

let () =
  let db = Result.get_ok (open_ "shop") in
  (match open_ "shop" with Ok _ -> print_endline "opened twice" | Error e -> print_endline (message e));
  close db
```

```output
busy: shop is open in another process
```

## Further reading

- The model: Weiss, Karras, Bernstein, Hexastore (PVLDB 2008) and Neumann, Weikum, RDF-3X (PVLDB 2008) for triples
  and their indexes; Datomic's documentation for datoms and database values.
- Isolation: Berenson et al., "A Critique of ANSI SQL Isolation Levels" (SIGMOD 1995); Adya's thesis (MIT 1999);
  Fekete et al., "Making Snapshot Isolation Serializable" (TODS 2005); Kung and Robinson, "On Optimistic Methods for
  Concurrency Control" (TODS 1981); Herlihy and Wing, "Linearizability" (TOPLAS 1990).
- Joins: Ngo, Ré, Rudra, "Skew Strikes Back" (SIGMOD Record 2013); Atserias, Grohe, Marx (FOCS 2008).
- Forks: Driscoll et al., "Making Data Structures Persistent" (JCSS 1989); Okasaki, "Purely Functional Data
  Structures" (1998).

Full entries, with links: [references](references.md).
