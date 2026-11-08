# API

The library is `cepheus` (dune). Its interface is `src/cepheus.mli`; every function below is there. The modules listed
at the end of the interface (`Cepheus.Store`, `Cepheus.Journal`, ...) are internals for the tests and tools: they may
change.

## Types

```ocaml
type value = Int of int | Float of float | Bool of bool | Text of string | Date of int | Money of int | Link of int
type typ = Tint | Tfloat | Tbool | Ttext | Tdate | Tmoney of int (* digits *) | Tlink
type error =
  | Conflict of string     (* an Expect did not hold *)
  | Invalid of string      (* a type, an unknown thing or property, a schema rule, a malformed question *)
  | Not_unique of string   (* a unique value is taken *)
  | Damaged of string      (* the files lost or changed durable data: the database does not open *)
  | Io of string           (* the disk failed: the database stopped; reopen it *)
  | Busy of string         (* open in another process *)
  | Closed
val message : error -> string
```

## Databases and views

| function | what it does |
|---|---|
| `open_ : string -> (db, error) result` | opens a database directory, creating it if missing; recovers (newest valid snapshot, then the journal). `Busy` if another process holds it. |
| `close : db -> unit` | waits for writes in flight, closes; nothing for a fork |
| `view : db -> view` | the newest durable state (a fork: its newest state); free |
| `group : view -> int` | the number of the last group in a view |
| `fork : view -> db` | a temporary state from a view: same reads, same writes, same checks, no disk (G8) |
| `empty : view` | the empty state with the system properties; `fork empty` is a database for a unit test |

## Writing

```ocaml
type op =
  | Add of int * int * value                (* thing, property, value; replaces the old value if one-valued *)
  | Retract of int * int * value
  | Expect of int * int * value option      (* Some v: the fact holds before the group; None: no value *)
type receipt = { group : int; things : (int * int) list }   (* new things: (-k, id) *)
val write : db -> ?by:int -> ?why:string -> op list -> (receipt, error) result
val thing : receipt -> int -> int
```

`write` applies a group all or nothing. On a database it returns once the group is durable (G1); on a fork at once.
Thing numbers below zero are new things of the group: `-1`, `-2`... in a thing position or in a `Link`.

Errors: `Conflict` (an `Expect`), `Invalid` (a value of the wrong type, a thing that does not exist, a link to
nothing, a system property on an ordinary thing, a schema rule), `Not_unique`, and, for a database, `Io` and `Closed`.

## The schema

```ocaml
type prop = { name : string; typ : typ; many : bool; unique : bool }
val prop : ?many:bool -> ?unique:bool -> string -> typ -> prop
val declare : db -> prop list -> (int list, error) result
val property : view -> string -> int option
val describe : view -> int -> prop option
```

`declare` returns the property numbers for the names, declaring the missing ones in one group; declaring a name again
with the same description returns its number; with another description, `Invalid`.

## Reading

```ocaml
val get : view -> int -> (int * value) list           (* every fact of a thing, by property *)
val values : view -> int -> int -> value list          (* values v thing property *)
val things : view -> int -> value -> int list          (* the things with this value *)

type term = Var of int | Thing of int | Val of value
type pattern = { e : term; p : int; v : term }
type query = { vars : int; where : pattern list; ranges : (int * value * value) list }
val find : view -> query -> (value array list, error) result
val fold : view -> query -> init:(unit -> 'a) -> step:('a -> int array -> 'a) -> merge:('a -> 'a -> 'a) -> ('a, error) result
```

A view's base is read through the cache of pages (see Operations, Memory): when a page cannot be read from the disk,
or does not check against its CRC, it is never served: `find` and `fold` return `Damaged`, and `get`, `values` and
`things` raise `Unreadable of string` (they return plain values). A write that needed the page fails with `Damaged`.

`find` returns every binding of `vars` variables (numbered 0 to vars − 1) that makes every pattern a fact, each once
(G11). A variable's type comes from where it appears (a thing position is a link); a variable used with two types, or
in no pattern, is `Invalid`. `ranges` keeps `lo <= x <= hi` for int, date and money variables. `fold` gives index words
(thing numbers for links, the value for ints, dates, money and booleans as 0/1, dictionary numbers for texts and
floats) in a buffer it reuses; use it for aggregates. A question with at least `Query.parallel_min` (20,000)
candidates for its first variable runs on up to `Query.domains` domains (default: the machine's, at most 8), each
with its own accumulator from `init ()`, joined by `merge`; `step` must touch only its accumulator.

Example: the sum of unpaid invoices per city.

```ocaml
let q = { vars = 4; ranges = [];
          where = [ { e = Var 0; p = status; v = Val (Text "unpaid") }; { e = Var 0; p = client; v = Var 1 };
                    { e = Var 1; p = city; v = Var 2 }; { e = Var 0; p = total; v = Var 3 } ] } in
Cepheus.fold v q ~init:(fun () -> Hashtbl.create 100)
  ~step:(fun t w -> Hashtbl.replace t w.(2) (w.(3) + Option.value (Hashtbl.find_opt t w.(2)) ~default:0); t)
  ~merge:(fun a b -> Hashtbl.iter (fun c x -> Hashtbl.replace a c (x + Option.value (Hashtbl.find_opt a c) ~default:0)) b; a)
```

## Operations

| function | what it does |
|---|---|
| `snapshot : db -> (unit, error) result` | merges now (the delta into a new base and its snapshot file), so the next open replays only what follows; nothing to do if no group came since the last merge |
| `verify : string -> (int, error) result` | reads a closed database's whole journal and checks every frame and trailer; the number of groups |
| `notes : db -> string list` | what recovery set aside (a damaged snapshot) |
| `set_cache : int -> unit` | the bytes of base pages kept in memory, for every database of the process (1 GiB by default) |
| `open_on : Disk.t -> string -> (db, error) result` | `open_` on another disk, such as `Sim_disk` |

## Threads and domains

A view can be read from any thread or domain at the same time, without locks. `write` can be called from any thread;
the writer runs in a domain of its own (a writer thread and a syncer thread). A fork's `write` takes the fork's mutex.
