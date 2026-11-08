(** Cepheus: a database of facts. Everything is a fact [(thing, property, value)]; a write is a group of facts, all
    or nothing, with who and why: the group is the event, kept for ever in the journal. A {!view} is the exact state
    after some group: it never changes, reads need no lock, and taking one is free. A fork is a temporary state
    started from a view: written to with the same functions and the same checks, never written to disk.

    {[
      let db = Result.get_ok (Cepheus.open_ "data/shop") in
      let[@warning "-8"] Ok [ name; city ] =
        Cepheus.declare db [ Cepheus.prop "client/name" Ttext; Cepheus.prop "client/city" Ttext ] in
      let r = Cepheus.write db ~by:7 ~why:"signup" [ Add (-1, name, Text "Ada Martin"); Add (-1, city, Text "Lyon") ] in
      ...
    ]}

    The guarantees and their proofs: [docs/guarantees.md]. *)

(** {1 Values and errors} *)

type value = Value.t =
  | Int of int
  | Float of float
  | Bool of bool
  | Text of string
  | Date of int
  | Money of int
  | Link of int

type typ = Value.typ = Tint | Tfloat | Tbool | Ttext | Tdate | Tmoney of int | Tlink

type error = Engine.error =
  | Conflict of string  (** an [Expect] did not hold *)
  | Invalid of string  (** a wrong type, an unknown thing or property, a schema rule *)
  | Not_unique of string  (** a value of a unique property is taken *)
  | Damaged of string  (** the files lost or changed durable data: the database does not open *)
  | Io of string  (** the disk failed: the database stops, reopen it to recover *)
  | Busy of string  (** the database is open in another process *)
  | Closed

val message : error -> string

(** {1 Databases} *)

type db
(** A database on disk, or a fork. *)

type view = Store.view
(** The state after one group. *)

val open_ : string -> (db, error) result
(** Opens the database in a directory, creating it if needed; recovers after a crash (the newest chain of runs that
    checks, then the journal). One process at a time ({!Busy} otherwise). *)

val close : db -> unit
(** Waits for the writes in flight (and a merge under way), then closes; the runs' pages leave the cache. A fork has
    nothing to close. *)

val view : db -> view
(** The newest durable state (for a fork, its newest state). *)

val group : view -> int
(** The number of the last group in a view. *)

val fork : view -> db
(** A temporary state starting at a view: reads and writes like a database, with the same checks; nothing reaches
    the journal, nothing changes for the database or its views (G8). Free to make; a fork of a fork works. *)

val empty : view
(** The empty state with only the system properties: [fork empty] is a database for a unit test. *)

(** {1 Writing} *)

type op = Resolve.op =
  | Add of int * int * value  (** [Add (thing, property, value)]; on a one-valued property, replaces the old value *)
  | Retract of int * int * value
  | Expect of int * int * value option
      (** [Expect (thing, property, Some v)]: the write fails with {!Conflict} unless the fact holds before the
          group; [None]: unless the thing has no value for the property *)
(** A negative thing id, in a thing position or in a [Link], is a new thing of this group: [-1], [-2]... *)

type receipt = Engine.receipt = { group : int;  (** the group's number *) things : (int * int) list  (** new ids: (-k, id) *) }

val write : db -> ?by:int -> ?why:string -> op list -> (receipt, error) result
(** Writes a group, all or nothing. On a database, returns once the group is durable ({!Ok} means it survives any
    crash, G1); on a fork, at once. *)

val thing : receipt -> int -> int
(** [thing r (-1)]: the id the group gave to its new thing [-1]; a walk of [r.things] (for a large group, read the list
    once into a table). *)

(** {1 The schema} *)

type prop = Schema.prop = { name : string; typ : typ; many : bool; unique : bool }

val prop : ?many:bool -> ?unique:bool -> string -> typ -> prop

val declare : db -> prop list -> (int list, error) result
(** The property ids for these names, declaring the missing ones in one group. A name declared already with
    another type, cardinality or unique flag is {!Invalid}. *)

val property : view -> string -> int option
val describe : view -> int -> prop option

(** {1 Rules}

    A rule derives facts from facts: for every answer of its body (a question's patterns and ranges), the fact of its
    head, or, for [Never], a refusal of the group. The writer keeps the derived facts up to date at each group, as
    facts like any other (G17): questions read them at the speed of any fact. A rule is a schema thing, defined and
    versioned in the journal like a property; [docs/rules.md] tells the whole of it. *)

type term = Query.term = Var of int | Thing of int | Val of value
type pattern = Query.pattern = { e : term; p : int; v : term }

type head = Rules.head = Give of pattern | Never

type rule = Rules.t = {
  name : string;  (** unique among the schema's names, properties' included *)
  vars : int;
  where : pattern list;
  ranges : (int * value * value) list;
  head : head;
}

val define : db -> rule list -> (int list, error) result
(** The rule things for these rules, found by name, writing in one group the new ones and those whose definition
    changed. The writer checks each one (types, range restriction, its head's property) and derives at once what it
    gives over the whole database, under the budget. *)

val undefine : db -> string list -> (unit, error) result
(** Removes these rules (by name) in one group: the facts that only they derived go with them. *)

type proof = Reason.proof =
  | Given of { e : int; p : int; v : value }  (** an asserted fact *)
  | By of { rule : string; e : int; p : int; v : value; from : proof list }
      (** a fact derived by [rule] from the facts of [from], each proved before it *)

val why : view -> int -> int -> value -> proof option
(** [why v thing property value]: a well-founded proof of a fact of the view, its leaves asserted facts of the view
    (G20); [None] when the triple is not a fact of the view. Computed when asked: nothing is stored at write time. *)

val rule_budget : int ref * int ref
(** The budget of a write: its derived changes may not pass [fst + snd * its asserted changes] (100,000 + 100 x); a
    group past it is refused, naming the rule that derived the most. *)

(** {1 Reading} *)

val get : view -> int -> (int * value) list
(** Every fact of a thing: (property, value), by property. *)

val values : view -> int -> int -> value list
(** [values v thing property]. *)

val things : view -> int -> value -> int list
(** [things v property value]: the things that have this value (by link for a link property). *)

type query = Query.t = { vars : int; where : pattern list; ranges : (int * value * value) list }
(** Variables are numbered from 0 to [vars - 1]; [ranges] keep [lo <= x <= hi] for int, date or money variables. *)

exception Unreadable of string
(** Raised by {!get}, {!values} and {!things} when a page of one of the view's runs cannot be read from the disk, or
    does not check against its CRC (it is never served); {!find} and {!fold} return [Error (Damaged _)] instead. *)

val set_cache : int -> unit
(** The bytes of run pages kept in memory, for every database of the process (1 GiB by default). A run larger
    than the cache is read page by page as the questions need it. *)

val find : view -> query -> (value array list, error) result
(** Every binding of the variables that makes all patterns facts of the view, each once (G11). *)

val fold :
  view -> query -> init:(unit -> 'a) -> step:('a -> int array -> 'a) -> merge:('a -> 'a -> 'a) -> ('a, error) result
(** The bindings folded into an accumulator, without building values: [step] gets index words (thing ids for links,
    the value for ints, dates, money, 0/1 for booleans, dictionary numbers for texts and floats) in a buffer it may not
    keep; {!decode} turns a word back into its value. A large question runs on several domains, each with its own
    accumulator from [init ()], joined by [merge]; [step] must therefore only touch its accumulator. *)

val decode : view -> query -> int -> int -> value
(** [decode v q x w]: the value of variable [x] of [q] whose index word, as {!fold} gives it, is [w], the value {!find}
    would give: a [Text] for a dictionary number of a text variable, a [Float] for a float's, a [Link] for a thing.
    Call it in [step] or on the keys of the result, on the view the fold read. Raises [Invalid_argument] for a
    variable out of the question or a question {!fold} refuses, and {!Unreadable} when the text's page cannot be
    read. *)

(** {1 Operations} *)

val snapshot : db -> (unit, error) result
(** Merges now: the changes since the last merge and every run into one run, one base (merges also run on their own,
    in the background, as changes accumulate, into the levels), so that the next open replays nothing and the base is
    the fastest to read. *)

val verify : string -> (int, error) result
(** Reads the whole journal of a closed database and checks every frame: the number of groups. *)

val notes : db -> string list
(** What the last open set aside: one note for each run file that did not check or has an earlier format (a torn
    tail cut is not noted). *)

(** {1 Internals, for the tests and tools} *)

val open_on : Disk.t -> string -> (db, error) result
(** [open_] on another disk (the simulated one). *)

module Bulk = Bulk
module Codec = Codec
module Crc32c = Crc32c
module Disk = Disk
module Engine = Engine
module Group = Group
module Pages = Pages
module Histogram = Histogram
module Journal = Journal
module Query = Query
module Reason = Reason
module Resolve = Resolve
module Rules = Rules
module Rng = Rng
module Schema = Schema
module Sim_disk = Sim_disk
module Snapshot = Snapshot
module Store = Store
module Value = Value
