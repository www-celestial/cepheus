# API

The library is `cepheus` (dune); its interface is `src/cepheus.mli`, and every name below is there. The modules it
also exports (`Cepheus.Journal`, `Cepheus.Store`, ...) are internals for the tests, the tools and the benchmarks; they
may change: [internals](internals.md). Every error message, where it comes from and what to do:
[errors](errors.md). Every limit and default: [limits](limits.md). The examples are whole programs; `dune test` runs
each one and checks the output shown under it.

## Values and errors

```ocaml signature
type value = Int of int | Float of float | Bool of bool | Text of string | Date of int | Money of int | Link of int
type typ = Tint | Tfloat | Tbool | Ttext | Tdate | Tmoney of int | Tlink
type error =
  | Conflict of string     (* an Expect did not hold *)
  | Invalid of string      (* a wrong type, an unknown thing or property, a schema rule, a malformed question *)
  | Not_unique of string   (* a value of a unique property is taken *)
  | Damaged of string      (* the files lost or changed durable data, or a page of a run does not check *)
  | Io of string           (* the disk failed: the database stopped; close it and open it again *)
  | Busy of string         (* the database is open in another process *)
  | Closed                 (* the database was closed *)
val message : error -> string
```

| value | meaning | its index word (see `fold`) |
|---|---|---|
| `Int n` | a 63-bit signed integer (OCaml's `int`) | n |
| `Float f` | an IEEE 754 double; equal means the same 64 bits (so `nan` equals itself, `0.0` differs from `-0.0`) | a dictionary number |
| `Bool b` | | 0 or 1 |
| `Text s` | any bytes (UTF-8 by convention; never looked inside) | a dictionary number |
| `Date ms` | an instant, milliseconds since 1970-01-01 UTC | ms |
| `Money m` | an exact decimal: m minor units, the number of digits being the property's (`Tmoney 2`: `Money 120000` is 1,200.00) | m |
| `Link e` | another thing of the same database (a negative e is a new thing of the same group) | e |

A property's type is a `typ`; `Tmoney d` takes 0 to 18 digits. `message e` is the text of an error, its kind first:
`"conflict: "`, `"invalid: "`, `"not unique: "`, `"damaged: "`, `"input/output error: "`, `"busy: "`, and `"the
database is closed"`.

## Databases and views

| function | what it does |
|---|---|
| `open_ : string -> (db, error) result` | opens the database in a directory, creating the directory (and its parents) and the database if missing; after a crash, recovers: the newest chain of runs that checks, then the journal after it ([operations](operations.md#opening-and-recovery)). Errors: `Busy` (another process holds it, or this process under any path that names the same directory: a symbolic link, `DIR/.`, `x/../DIR`), `Damaged` (durable data lost or changed: it does not open), `Io` |
| `close : db -> unit` | waits for the writes in flight and for a merge under way (it is installed), closes the journal, leaves the clean-close marker if no fsync failed, takes the runs' pages out of the cache, releases the lock. Views taken before stay readable (their pages are read again from the files). A second `close` does nothing (it neither leaves the marker nor releases the lock again: another engine may have the database open by then). A fork has nothing to close |
| `view : db -> view` | the newest durable state (for a fork, its newest state). Free: one atomic read |
| `group : view -> int` | the number of the last group in a view |
| `fork : view -> db` | a temporary state starting at a view: the same reads and writes, the same checks, nothing on any file (G8). Free; a fork of a fork works |
| `empty : view` | the state of a new database: group 1, the five system properties. `fork empty` is a database for a unit test |
| `open_on : Disk.t -> string -> (db, error) result` | `open_` on another implementation of the disk, such as the simulated one (`Sim_disk.disk`) |

```ocaml
open Cepheus

let () =
  let db = Result.get_ok (open_ "data/shop") in
  let[@warning "-8"] (Ok [ name ]) = declare db [ prop "client/name" Ttext ] in
  let r = Result.get_ok (write db ~by:7 ~why:"signup" [ Add (-1, name, Text "Ada") ]) in
  Printf.printf "receipt: group %d, new things %s\n" r.group
    (String.concat ", " (List.map (fun (k, id) -> Printf.sprintf "%d -> %d" k id) r.things));
  Printf.printf "view at group %d\n" (group (view db));
  (match snapshot db with Ok () -> print_endline "merged into a snapshot" | Error e -> print_endline (message e));
  Printf.printf "notes: %d\n" (List.length (notes db));
  close db;
  (match write db [ Add (thing r (-1), name, Text "Ada M.") ] with
   | Ok _ -> ()
   | Error e -> Printf.printf "after close: %s\n" (message e));
  (match verify "data/shop" with Ok n -> Printf.printf "verify: %d groups\n" n | Error e -> print_endline (message e));
  let db = Result.get_ok (open_ "data/shop") in
  Printf.printf "reopened at group %d\n" (group (view db));
  close db
```

```output
receipt: group 3, new things -1 -> 65536
view at group 3
merged into a snapshot
notes: 0
after close: the database is closed
verify: 3 groups
reopened at group 3
```

## Writing

```ocaml signature
type op =
  | Add of int * int * value               (* thing, property, value; on a one-valued property, retracts the old value *)
  | Retract of int * int * value
  | Expect of int * int * value option     (* Some v: the fact holds before the group; None: the thing has no value *)
type receipt = { group : int; things : (int * int) list }   (* the group's number; its new things, (-k, id) *)
val write : db -> ?by:int -> ?why:string -> op list -> (receipt, error) result
val thing : receipt -> int -> int
```

`write db ~by ~why ops` applies the operations as one group, all or nothing (G2). `by` (0 by default) and `why` (`""`
by default) are kept with the group in the journal. On a database, `write` blocks the calling thread until the group
is durable: `Ok` means the group survives any crash (G1), and every view taken afterwards holds it. On a fork, it
returns at once. The group's number is given when the writer takes it; groups are applied one at a time in that order
(G4).

- **New things**: a negative number in a thing position, or inside a `Link`, is a new thing of this group; each
  distinct negative number gets the next thing number, in the order of first appearance. `thing r (-k)` is the number
  `-k` was given (`Not_found` if `-k` was not in the group); it walks the receipt's list `r.things`, so for a large
  group read the list once into a table.
- **One-valued properties**: an `Add` retracts the thing's other values for the property in the same group (the
  journal records the retraction).
- **No-ops**: an `Add` of a fact that holds, or a `Retract` of one that does not, records nothing; a group of no-ops
  still takes a number.
- **`Expect`** is checked against the state before the group (wherever it sits in the list), by the writer, on the
  newest state: it is how a read-then-write states what it read ([concepts](concepts.md#isolation-exactly-what-a-reader-and-a-writer-see)).
- **Unique** values are checked on the state after the whole group, so a group may move a unique value from one thing
  to another.

Errors: `Conflict` (an `Expect`); `Invalid` (a value of the wrong type, a thing that was never made, a link to
nothing, an `Expect` on a new thing, a property that does not exist, a system property on an ordinary thing, an
ordinary property on a property thing, a schema rule, a group whose journal frame would pass 256 MiB); `Not_unique`;
`Damaged` (a page of a run that the group needed could not be read or does not check: the group is not written, the
writer goes on); for a database also `Io` (the disk failed: this group and every later one fail, until the database
is closed and opened again; for a large group, a disk error while its run file is written fails that group only, and
the writer goes on) and `Closed`. On a fork, a page that cannot be read raises `Unreadable` instead of returning
`Damaged`. The messages: [errors](errors.md).

**Loading.** A load is the same `write`, of large groups. A group of 20,000 operations and more, all of them `Add`,
none of a system property, takes a faster path inside the writer: its facts are sorted in arrays (a counting sort and a
stable radix sort) and merged at once with the delta and the newest runs into a run file, without a persistent map per
fact ([architecture](architecture.md#large-groups)). The result and the errors are those of any group: on any doubt
(an error, an `Add` of a one-valued property to a thing that exists, two values of a one-valued property for one new
thing, a unique value taken or given twice) the group goes the ordinary way, which decides as always. Write a load as a
few large groups (each confirmed once, with one fsync), not as millions of small ones: 10 million facts in two groups
load in 4.1 to 5.6 s (the median of a series, depending on the disk), in 113,636 groups of one client each in 112 s
([benchmarks](benchmarks.md#the-load-in-parallel-and-without-copies-2026-11-08-at-10-million-facts)). A large group
holds the writer while it is merged (about a second at 10 million facts, most of it the disk), and needs its
operations and 26 bytes a fact of compact arrays in memory at once (1.46 GB at the peak for 9.4 million additions, 0.88
of it the caller's list, which `write` lets go once the group is mapped); its frame is written by pieces.
To bound the memory, write a load as groups of a few hundred thousand facts, from two threads so that one builds its
next group while the writer takes the other's: each group is atomic (G2 holds a group, not the load), the runs of the
groups stay side by side until 16 of them merge in one pass ([architecture](architecture.md#merges-a-leveled-log-structured-merge-tree)),
and `snapshot` at the end leaves one run. At 10 million facts in groups of 5,000 clients (about 415,000 facts) by two
threads: 9.8 s to confirm every group, 3.2 s for the snapshot, a peak of 292 MB with a 64 MB cache ([benchmarks](benchmarks.md#chunked-loads-2026-11-12-at-10-million-facts));
until the snapshot a read visits each run (at 1 million facts, a client by e-mail on 8 runs 1.40 µs, on 2 runs 0.73).

## The schema

```ocaml signature
type prop = { name : string; typ : typ; many : bool; unique : bool }
val prop : ?many:bool -> ?unique:bool -> string -> typ -> prop      (* many and unique: false by default *)
val declare : db -> prop list -> (int list, error) result
val property : view -> string -> int option
val describe : view -> int -> prop option
```

`declare db props` returns the property numbers of the names, in the order given, and declares the missing ones in
one group (`~why:"cepheus: declare"`), each at the lowest free number from 16 up. A name that exists with the same
description returns its number and writes nothing; with another type, cardinality or unique flag, the result is
`Invalid` and nothing is written. If another writer took a number meanwhile, `declare` reads the schema again and
tries again. `property v name` is the number of a name in a view; `describe v p`, the description of a property.

```ocaml
open Cepheus

let () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ email; tag ]) = declare db [ prop ~unique:true "client/email" Ttext; prop ~many:true "client/tag" Ttext ] in
  let v = view db in
  Printf.printf "client/email is %d, client/tag is %d\n" email tag;
  (match describe v tag with
   | Some d -> Printf.printf "%s: %s, many %b, unique %b\n" d.name (Value.typ_name d.typ) d.many d.unique
   | None -> ());
  Printf.printf "client/phone: %s\n" (match property v "client/phone" with Some p -> string_of_int p | None -> "none");
  (match declare db [ prop ~unique:true "client/email" Ttext ] with Ok [ p ] -> Printf.printf "again: %d\n" p | _ -> ());
  match declare db [ prop "client/email" Tint ] with Ok _ -> () | Error e -> print_endline (message e)
```

```output
client/email is 16, client/tag is 17
client/tag: text, many true, unique false
client/phone: none
again: 16
invalid: client/email is declared already as another kind of property
```

## Rules

```ocaml signature
type term = Var of int | Thing of int | Val of value          (* as in questions *)
type pattern = { e : term; p : int; v : term }
type head = Give of pattern | Never
val prop_var : int -> int                                     (* a pattern's property as the variable ?k *)
type rule = { name : string; vars : int; where : pattern list; ranges : (int * value * value) list; head : head }
val define : db -> rule list -> (int list, error) result
val undefine : db -> string list -> (unit, error) result
type proof =
  | Given of { e : int; p : int; v : value }
  | By of { rule : string; e : int; p : int; v : value; from : proof list }
val why : view -> int -> int -> value -> proof option
val sources : view -> int -> int list option
val rule_budget : int ref * int ref
val change_budget : int ref
```

A rule is a question's patterns and ranges (`where`, `ranges`, variables 0 to `vars - 1`) and a head: `Give pattern`,
the fact it gives for each answer, or `Never`, a constraint ([rules](rules.md)). `define db rules` returns the rule
things (in 16 to 65,535, as properties) of the rules, in the order given, and writes in one group
(`~why:"cepheus: rules"`) the new ones (at the lowest free number) and those whose definition changed (found by
name); a rule defined already with the same definition writes nothing. The writer checks each rule (range
restriction, types, the head's property; errors `Invalid "rule NAME: …"`, [errors](errors.md#invalid-the-request-is-wrong))
and derives in that group what it gives over the whole database, under a change's budget; a constraint is checked over
the whole database. A name that is a property's is `Invalid`. If another writer took a number meanwhile, or a group
written meanwhile interfered with the change, `define` reads the schema again and tries again (`Conflict`). In a
database on the disk the change is computed beside the writer and returns once installed
([rules](rules.md#changes-of-the-rules-in-the-background)): a `write` sent meanwhile may be ordered before it.

A pattern's property `p` is a property id, or `prop_var k` (a negative number) for the variable `?k`: another pattern of
the body whose property is a constant has `?k` as its thing or its value. A value read under a variable property has
that property's type; a head that gives a fact its property cannot take refuses the group (errors `Invalid "rule R
gives …"`). Such rules run unfolded on the facts of their small relations ([rules](rules.md#specialisation-by-small-relations));
questions keep constant properties.

`undefine db names` removes the rules of these names in one group: their definitions retracted, and the facts only
they derived with them (a name that is no rule is ignored).

`why v e p x` is a proof of the fact `(e, p, x)` of view v: `Given` for an asserted fact, `By` for a derived one, with
the rule's name and the proofs of the facts of its body, in the order of the rule's patterns; `None` when the triple
is not a fact of v. Computed when called, on the view: nothing is stored at write time (G20).

`sources v p` lists the properties whose facts the derived facts of property `p` can come from through the rules,
transitively (`Some []` for a property no rule gives), or `None` when a rule on the way reads a variable property:
what a reader allowed some kinds only must read to read `p`'s derived facts without learning facts it may not read.

`rule_budget` is (base, per): a group whose derived changes pass $\mathit{base} + \mathit{per} \times \text{its asserted changes}$ is refused,
`Invalid "rule NAME derived more than N facts from a group of K facts"`; (100,000, 100) by default, for every database
of the process. A change of the rules or the ontology may also derive `change_budget` (4) times the facts of the
database before it: `Invalid "rule NAME derived more than N facts from a change of the rules or the ontology"`.

```ocaml
open Cepheus

let () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ member; member_of ]) =
    declare db [ prop ~many:true "org/member" Tlink; prop ~many:true "person/memberOf" Tlink ]
  in
  (* each of two properties the inverse of the other *)
  let inverse name a b =
    { name; vars = 2; where = [ { e = Var 0; p = a; v = Var 1 } ]; ranges = []; head = Give { e = Var 1; p = b; v = Var 0 } }
  in
  let ids = Result.get_ok (define db [ inverse "member-inverse" member member_of; inverse "memberOf-inverse" member_of member ]) in
  Printf.printf "rules %s\n" (String.concat ", " (List.map string_of_int ids));
  let r = Result.get_ok (write db [ Add (-1, member, Link (-2)) ]) in
  let club = thing r (-1) and ada = thing r (-2) in
  Printf.printf "ada is a member of %s\n" (String.concat ", " (List.map Value.to_string (values (view db) ada member_of)));
  (match why (view db) ada member_of (Link club) with
   | Some (By { rule; from = [ Given g ]; _ }) -> Printf.printf "by %s, from [#%d %d %s]\n" rule g.e g.p (Value.to_string g.v)
   | _ -> ());
  (* the two facts derive each other; with the asserted one gone, both go *)
  ignore (Result.get_ok (write db [ Retract (club, member, Link ada) ]));
  Printf.printf "after: %d and %d\n" (List.length (values (view db) club member)) (List.length (values (view db) ada member_of));
  ignore (Result.get_ok (undefine db [ "member-inverse"; "memberOf-inverse" ]))
```

```output
rules 18, 19
ada is a member of #65536
by member-inverse, from [#65536 16 #65537]
after: 0 and 0
```

## Reading

```ocaml signature
val get : view -> int -> (int * value) list       (* every fact of a thing: (property, value), sorted *)
val values : view -> int -> int -> value list      (* values v thing property *)
val things : view -> int -> value -> int list      (* things v property value: the things with this value, sorted *)
exception Unreadable of string
```

`get v e` is every fact of thing e, sorted by property then value; `[]` for a number that is no thing. `values v e p`
is the values of e for p (the order is not specified); `[]` if p is no property. `things v p x` is the things that
have the value x for p, in increasing order; for a link property, `things v p (Link t)` is the things that link to t
by p. All three read the runs through the cache: when a page cannot be read from the disk or does not check against
its CRC, it is never served, and they raise `Unreadable` with the file and the page.

```ocaml
open Cepheus

let () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ name; tag; follows ]) =
    declare db [ prop "client/name" Ttext; prop ~many:true "client/tag" Ttext; prop ~many:true "client/follows" Tlink ]
  in
  let r =
    Result.get_ok
      (write db [ Add (-1, name, Text "Ada"); Add (-1, tag, Text "vip"); Add (-1, tag, Text "lyon"); Add (-2, name, Text "Bob");
                  Add (-2, follows, Link (-1)); Add (-2, tag, Text "vip") ])
  in
  let ada = thing r (-1) and bob = thing r (-2) in
  let v = view db in
  let ints l = String.concat " " (List.map string_of_int l) in
  Printf.printf "tags of Ada: %s\n" (String.concat " " (List.map Value.to_string (List.sort compare (values v ada tag))));
  Printf.printf "things tagged vip: %s\n" (ints (things v tag (Text "vip")));
  Printf.printf "who follows Ada: %s\n" (ints (things v follows (Link ada)));
  Printf.printf "facts of Bob: %d\n" (List.length (get v bob))
```

```output
tags of Ada: "lyon" "vip"
things tagged vip: 65536 65537
who follows Ada: 65537
facts of Bob: 3
```

## Questions

```ocaml signature
type term = Var of int | Thing of int | Val of value
type pattern = { e : term; p : int; v : term }      (* thing, property, value *)
type query = { vars : int; where : pattern list; ranges : (int * value * value) list }
val find : view -> query -> (value array list, error) result
val fold : view -> query -> init:(unit -> 'a) -> step:('a -> int array -> 'a) -> merge:('a -> 'a -> 'a) -> ('a, error) result
val decode : view -> query -> int -> int -> value
```

A question has `vars` variables, numbered 0 to `vars - 1`, and patterns whose thing (`e`) and value (`v`) are a
variable, a thing (`Thing n`) or a value (`Val x`); the property is always a constant. A variable in a thing position
is a link; a variable's type is the type of the properties it appears with, and must be one type. `ranges` keep
`lo <= x <= hi` for a variable of a type whose index word is the value (int, date, money, bool, link); several ranges
on one variable intersect.

`find v q` returns every binding that makes every pattern a fact of the view, each once (G11), as arrays indexed by
variable; their order is not specified. A constant the view has never seen (a text never written), or a pattern with
no variable that is not a fact, makes the answer empty. With `vars = 0`, a question is a yes-or-no test: `[ [||] ]` if
its patterns are facts, `[]` if not.

`fold v q ~init ~step ~merge` folds the bindings without building values: `step acc w` gets the index words of a
binding in `w` (thing numbers for links, the value for ints, dates and money, 0 or 1 for booleans, dictionary numbers
for texts and floats), in a buffer it reuses, so `step` must not keep `w`. When the first variable has 20,000
candidates or more (`Query.parallel_min`), the question runs on up to `Query.domains` domains (the machine's
recommended count, at most 8): the candidates are cut into slices, each slice folded from its own `init ()`, and the
slices' results joined by `merge` in slice order, so the result does not depend on the number of domains; `step` may
run on several domains at once and must touch only its accumulator. Below the threshold, `init` is called once and
`merge` never.

`decode v q x w` is the value of variable `x` of `q` whose index word is `w`: the value `find` would give, a `Text`
for the dictionary number of a text variable, a `Float` for a float's, a `Link` for a thing, `Int`, `Date`, `Money`
or `Bool` for the others; the type comes from the question, as for `find`. A fold keyed by words gives its keys their
texts once each, at the end (or in `step`, at a cost per binding: a dictionary read and a string). It reads the view
the fold read; it raises `Invalid_argument` for a variable out of the question or a question `fold` refuses, and
`Unreadable` when the text's page cannot be read.

Errors of both: `Invalid` (an unknown property, a variable out of range or in no pattern or of two types, a constant
of the wrong type, a range on a text or float variable) and `Damaged` (a page that cannot be read or does not check).

```ocaml
open Cepheus

let () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ score ]) = declare db [ prop "player/score" Tint ] in
  ignore (write db (List.mapi (fun i s -> Add (-(i + 1), score, Int s)) [ 12; 40; 7; 33; 40 ]));
  let v = view db in
  (* the players with a score between 10 and 35 *)
  let q = { vars = 2; where = [ { e = Var 0; p = score; v = Var 1 } ]; ranges = [ (1, Int 10, Int 35) ] } in
  (match find v q with
   | Ok rows -> List.iter (fun r -> Printf.printf "%s %s\n" (Value.to_string r.(0)) (Value.to_string r.(1))) (List.sort compare rows)
   | Error e -> print_endline (message e));
  let yes = { vars = 0; where = [ { e = Thing 65537; p = score; v = Val (Int 40) } ]; ranges = [] } in
  Printf.printf "65537 has 40: %b\n" (find v yes = Ok [ [||] ]);
  match find v { vars = 1; where = []; ranges = [] } with Ok _ -> () | Error e -> print_endline (message e)
```

```output
#65536 12
#65539 33
65537 has 40: true
invalid: variable 0 appears in no pattern
```

A sum per city with `fold`, keyed by the city's index word, and the cities' texts given by `decode` once each:

```ocaml
open Cepheus

let () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ city; total ]) = declare db [ prop "invoice/city" Ttext; prop "invoice/total" (Tmoney 2) ] in
  ignore
    (write db
       (List.concat
          (List.mapi (fun i (c, m) -> [ Add (-(i + 1), city, Text c); Add (-(i + 1), total, Money m) ])
             [ "Lyon", 1200; "Nice", 500; "Lyon", 300; "Brest", 250; "Nice", 50 ])));
  let v = view db in
  let q = { vars = 3; ranges = []; where = [ { e = Var 0; p = city; v = Var 1 }; { e = Var 0; p = total; v = Var 2 } ] } in
  let add t k x = Hashtbl.replace t k (x + Option.value (Hashtbl.find_opt t k) ~default:0) in
  match
    fold v q ~init:(fun () -> Hashtbl.create 8)
      ~step:(fun t w -> add t w.(1) w.(2); t)
      ~merge:(fun a b -> Hashtbl.iter (add a) b; a)
  with
  | Ok sums ->
    Hashtbl.fold (fun w m acc -> (Value.to_string (decode v q 1 w), m) :: acc) sums []
    |> List.sort compare
    |> List.iter (fun (c, m) -> Printf.printf "%s %d.%02d\n" c (m / 100) (m mod 100))
  | Error e -> print_endline (message e)
```

```output
"Brest" 2.50
"Lyon" 15.00
"Nice" 5.50
```

How a question is answered, and what it costs: [architecture](architecture.md#questions), [theory](theory.md#4-generic-join).

## Questions with operators, an order and pages

```ocaml signature
module Question : sig
  type item = Pattern of pattern | Range of int * value * value | In of int * value list | Prefix of int * string
            | Not of item list | Or of item list list
  type key = { col : int; desc : bool }
  type t = { vars : int; items : item list; give : int array; sort : key list; limit : int; after : value array option }
end
val ask : view -> Question.t -> (value array list, error) result
```

Its names are in the module `Question`, so that `open Cepheus` brings only `Question` and `ask` beside the names it
always brought (a program's own `Not` or `Pattern` stays its own); `Question.[ ... ]` opens it for a list of items.
`ask v q` answers a question with `Not`, `Or`, `In` and `Prefix` beside its patterns and ranges, and gives its rows
sorted, cut and paged: the same meaning and the same bounds as from Cesia ([Not, Or and In](cesia.md#not-or-and-in),
[Prefix](cesia.md#prefix-the-start-of-a-text), [pages](cesia.md#sort-limit-and-after-pages)). `give` names the
variables of each row (empty: every variable of the question); a key's `col` is a column of `give`; `limit` 0 gives
every row; `after` is a row of `give`'s columns. `find` and `query` are unchanged: a question of patterns and ranges,
given every variable, has the rows `find` gives.

```ocaml
open Cepheus

let () =
  let db = Result.get_ok (open_ "asks") in
  let[@warning "-8"] (Ok [ name; city ]) = declare db [ prop "client/name" Ttext; prop "client/city" Ttext ] in
  List.iter (fun (n, c) -> ignore (write db [ Add (-1, name, Text n); Add (-1, city, Text c) ]))
    [ "Ada", "Lyon"; "Bo", "Paris"; "Abel", "Lyon"; "Ali", "Paris"; "Cy", "Nice" ];
  (* the names that start with A, of clients not in Paris, the largest first *)
  let q =
    { Question.vars = 2;
      items = Question.[ Pattern { e = Var 0; p = name; v = Var 1 }; Prefix (1, "A"); Not [ Pattern { e = Var 0; p = city; v = Val (Text "Paris") } ] ];
      give = [| 1 |]; sort = [ { Question.col = 0; desc = true } ]; limit = 10; after = None }
  in
  (match ask (view db) q with
   | Ok rows -> List.iter (fun r -> print_endline (Value.to_string r.(0))) rows
   | Error e -> print_endline (message e));
  close db
```

```output
"Ada"
"Abel"
```

## The cache

`set_cache bytes` sets how many bytes of run pages the process keeps in memory, for all its databases at once (1 GiB
by default; at least 16 pages of 16 KiB). It takes effect as pages come in (a smaller cache evicts as the next pages
are read) and at the next open (a run that fits in the cache is read and checked whole at open; a larger one, its
tables at open and its other pages as questions need them). [operations](operations.md#memory).

## Operations

| function | what it does |
|---|---|
| `snapshot : db -> (unit, error) result` | merges now: the delta (the changes since the last merge) and every run into one run, one base, the fastest to read, so that the next open replays nothing; it first waits for a merge under way. Nothing to do if there is one run and no group came since the last merge. Errors: `Io`, `Damaged` (a page of a run), the error that stopped the database, `Closed`; on a fork, `Invalid "a fork has no files"` |
| `verify : string -> (int, error) result` | reads the whole journal of a closed database from its first segment and checks every frame, trailer and group number: the number of groups, or `Damaged` naming the first fault, or `Io`. It does not take the lock: never run it on an open database. Run files are not read (they are checked at each open, and are caches of the journal) |
| `notes : db -> string list` | what the last open set aside: `"snapshot <name> set aside: <reason>"` for each run file that did not check, or that has an earlier format (`<name>.snap`: the journal is replayed); `[]` for a fork |

## Threads and domains

A view can be read from any thread and any domain at the same time, with no lock. `write` can be called from any
thread of any domain: the writer and the syncer run in a domain of their own, the caller waits on its own condition
variable. A fork's `write` takes the fork's mutex, so one fork can be written to from several threads. `fold`'s `step`
and `init` may run on other domains.
