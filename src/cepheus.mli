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

    The guarantees and their proofs: [docs/book/guarantees.md]. *)

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
  | Timeout of string  (** a question passed the time it was given ([?timeout]), or the server's [question_timeout] *)

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
  | Incr of int * int * int * (int * int) option
      (** [Incr (thing, property, by, into)]: the thing's value of a one-valued int property (none counts 0) grows by
          [by], read at this point of the group, at the writer: groups that increment one counter never conflict
          and never skip a value, and a refused group leaves the counter as it was. A value past the ints refuses
          the group ({!Invalid}). [into = Some (thing', property')] also adds the new value as [(thing', property')],
          an int property ([thing'] may be a new thing): an invoice gets its number in the group that makes it. The
          journal keeps what it did, as an [Add]'s retraction and addition. *)
  | Delete of int * string
      (** [Delete (thing, kind)]: every fact of the thing of a property of that kind (its name before ['/']: the
          kind of [client/name] is client) that a write asserted, retracted at this point of the group, at the
          writer; then, as for any group that leaves a thing with no such fact, the links that name the kind and link
          to it follow their {!on_delete} ({!link_to}). A thing with no fact of the kind: nothing to retract. A kind
          with no property is {!Invalid}. *)
(** A negative thing id, in a thing position, in a [Link] or in [Incr]'s [into], is a new thing of this group: [-1],
    [-2]... *)

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

(** {2 Links that name a kind: foreign keys}

    A thing is of a kind while it has a fact of one of the kind's properties that a write asserted (a fact only
    derived makes no thing of a kind). A link property that names a kind takes only things of that kind as values,
    checked on the state after each group (a thing made in the same group counts); and when a group leaves a thing
    with no fact of the kind (a {!Delete}, or retractions), each fact that links to it does what its property says:
    [Refuse] refuses the group, naming the kind, the thing, one thing that links to it and the property ({!Invalid});
    [Cascade] deletes the linking thing too, in the kind of its property (as a {!Delete}, and so on: a thing reached
    twice is followed once, so cycles end); [Clear] retracts the link. The facts these read and retract are at most
    {!work_budget} x {!rule_budget}'s budget of the group ({!Invalid} past it: nothing is done), and a group stays
    within the frame limit. No rule gives a link that names a kind. *)

type on_delete = Schema.on_delete = Refuse | Cascade | Clear

val link : view -> int -> (string * on_delete) option
(** The kind a link property names, and what its facts do when such a thing stops being of it; [None]: any thing. *)

val link_to : db -> (int * string * on_delete) list -> (unit, error) result
(** [link_to db [ (invoice_client, "client", Refuse) ]]: these link properties name these kinds, in one group (those
    that name them already are left). The writer checks every value they hold already; a property that names another
    kind, or the same with another [on_delete], is {!Invalid}. *)

(** {1 Rules}

    A rule derives facts from facts: for every answer of its body (a question's patterns and ranges), the fact of its
    head, or, for [Never], a refusal of the group. The writer keeps the derived facts up to date at each group, as
    facts like any other (G17): questions read them at the speed of any fact. A rule is a schema thing, defined and
    versioned in the journal like a property; [docs/book/rules.md] tells the whole of it. *)

type term = Query.term = Var of int | Thing of int | Val of value
type pattern = Query.pattern = { e : term; p : int; v : term }

type head = Rules.head = Give of pattern | Never

val every : int -> int
(** [every l]: in a rule's pattern [[c, every l, m]], "for every value m of c's l": the patterns that name m are
    written once for each of c's values of [l] (the variables only they hold fresh in each copy). A template, as the
    W3C writes OWL 2 RL's rules over lists: [[c, every intersection_of, m]; [y, type, m]] gives [[y, type, c]] when y
    has every member's type. The engine unfolds it on [l]'s facts, so a write of [l] changes the rules (it is computed
    as a rule change); no rule may give [l]. One such pattern a rule, with no Not and no aggregate. *)

val prop_var : int -> int
(** [prop_var k]: in a rule's pattern, the property as the variable [?k] (a negative number, where a property id
    goes): the W3C's form of OWL 2 RL's rules, [[c, domain, p]; [x, p, y]] gives [[x, type, c]]. Another pattern of
    the body, whose property is a constant, binds [?k] as its thing or its value; a value read under a variable
    property has that property's type, and a fact a head gives must fit its property, or the group is refused. The
    engine runs such a rule unfolded on that pattern's facts when they are few (one rule a fact, the property in
    place), and as written while a group changes them. Questions keep constant properties. *)

val absent : int -> int -> int
(** [absent k p]: in a rule's pattern, the property [p] of the rule's [k]-th Not (0 to 15). The rule's answers are
    those for which no binding of the Not's own variables (those in no pattern outside Nots) makes all of its patterns
    facts: the body [{ e = Var 0; p = ty; v = Thing invoice }; { e = Var 0; p = absent 0 paid_on; v = Var 1 }] reads
    "?0 is an invoice and has no paid_on" (?1 is the Not's own). A Not
    takes 1 to 4 patterns, their properties constants; the head's variables are outside Nots. A rule set where a
    property depends on its own absence is refused at {!define}, naming the cycle. *)

val aggregate : [ `Sum | `Count | `Min | `Max ] -> int -> int
(** [aggregate f p]: in a rule's head, the property [p] (one-valued) given, for each thing of the head, the sum, the
    count, the smallest or the largest value over the rule's answers; a thing without answers has no fact. Sum takes
    ints or money, Min and Max ints, dates or money, Count's value is [Val (Int 0)]; a sum past the ints refuses its
    group. The property is that rule's alone: no write asserts it and no other rule gives it. *)

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

(** {2 OWL 2 RL}

    The rules of the W3C's OWL 2 RL (OWL 2 Profiles, section 4.3) as a library: a vocabulary of properties
    ([owl/Type], [owl/SubClassOf], ...) and the rules over it, which a database defines as any rules. An ontology is
    then data: [Add (invoice, o.sub_class_of, Link document)]; the engine runs the rules unfolded on it. [docs/book/rules.md]
    tells the whole of it, rule by rule. *)

module Owl : sig
  type t = Owl.t = {
    type_ : int;
    same_as : int;
    different_from : int;
    sub_class_of : int;
    equivalent_class : int;
    disjoint_with : int;
    complement_of : int;
    intersection_of : int;  (** a member: [C, intersection_of, A]; C's members are its values *)
    union_of : int;
    one_of : int;
    has_key : int;
    on_property : int;  (** a restriction's property: a link to the property thing *)
    some_values_from : int;
    all_values_from : int;
    has_value : int;  (** a thing (an individual) *)
    max_cardinality : int;  (** an int: 0 or 1 in OWL 2 RL *)
    max_qualified_cardinality : int;
    on_class : int;
    property : int;  (** a description thing's property: [d, property, Link p]; d's other facts describe p *)
    domain : int;
    range : int;
    sub_property_of : int;
    equivalent_property : int;
    inverse_of : int;
    property_disjoint_with : int;
    functional : int;  (** bool, on a description *)
    inverse_functional : int;
    transitive : int;
    symmetric : int;
    asymmetric : int;
    irreflexive : int;
    chain_of : int;  (** a chain thing: [ch, chain_of, p], [ch, first, p1], [ch, second, p2]: p1 then p2 gives p *)
    first : int;
    second : int;
    source_individual : int;  (** a negative assertion: no [source assertion_property target] *)
    assertion_property : int;
    target_individual : int;
    target_value : int;  (** a text *)
    builtin : int;
    thing : int;  (** owl:Thing *)
    nothing : int;  (** owl:Nothing *)
  }

  val vocabulary : (string * typ * bool * bool) list
  (** The properties: name ([owl/Type] ...), type, many, unique. *)

  val setup : db -> (t, error) result
  (** Declares the vocabulary and makes the things owl:Thing and owl:Nothing, once (a database that has them keeps
      them): their ids. *)

  val rl : t -> rule list
  (** The rules, named [owl/<W3C name>] ([owl/cax-sco]): define them with {!define}. *)

  val description : t -> view -> int -> int option
  (** The description thing of a property ([owl/Property] links to it), if one. *)

  val all_different : t -> int list -> op list
  (** AllDifferent, written as its pairs ([owl/DifferentFrom]). *)

  val disjoint_classes : t -> int list -> op list
  (** AllDisjointClasses, as its pairs ([owl/DisjointWith]). *)

  val disjoint_properties : t -> (int * int) list -> op list
  (** AllDisjointProperties of (description thing, property) pairs, as its pairs ([owl/PropertyDisjointWith]). *)
end

type proof = Reason.proof =
  | Given of { e : int; p : int; v : value }  (** an asserted fact *)
  | By of { rule : string; e : int; p : int; v : value; from : proof list }
      (** a fact derived by [rule] from the facts of [from], each proved before it *)

val why : view -> int -> int -> value -> proof option
(** [why v thing property value]: a well-founded proof of a fact of the view, its leaves asserted facts of the view
    (G20); [None] when the triple is not a fact of the view. Computed when asked: nothing is stored at write time. A
    thing (and a thing as the value) is read as its class's representative, as {!get} reads it. *)

val sources : view -> int -> int list option
(** [sources v p]: the properties whose facts the derived facts of property [p] can come from through the rules,
    transitively; [None] when a rule reads a property that is a variable, so any. A reader allowed some kinds only
    learns nothing it may not read from [p]'s derived facts when it reads every kind of these. *)

val rule_budget : int ref * int ref
(** The budget of a write: its derived changes may not pass [fst + snd * its asserted changes] (100,000 + 100 x); a
    group past it is refused, naming the rule that derived the most. *)

val change_budget : int ref
(** A change of the rules or the ontology may derive this many times the facts of the database before it, beyond
    [rule_budget] (4): a change past it is refused, naming the rule that derived the most. *)

val work_budget : int ref
(** The candidates a group's rules may read (each fact a pattern of a body, of a Not or of a constraint enumerates),
    as this many times its budget of derived facts (10): a group or a change past it is refused, naming the rule whose
    pattern read the last one. *)

(** {1 Reading} *)

val same : view -> int -> int list
(** The class of a thing: the things the rules made the same as it (a rule whose head gives [cepheus/same], as
    OWL 2 RL's [owl/SameAs] and functional properties do), itself included, by id. Their facts are kept on one of
    them, the representative; {!get}, {!values}, {!things} and the questions read a thing they name as its class's
    representative. *)

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

val find : ?timeout:float -> view -> query -> (value array list, error) result
(** Every binding of the variables that makes all patterns facts of the view, each once (G11). [timeout]: the
    seconds it may take (none by default), past which it ends with [Error (Timeout _)]; looked at every 1,024
    candidates of each domain. Raises [Invalid_argument] for a timeout of 0 or less. *)

(** {2 Questions with operators, an order and pages} *)

(** The question of {!ask}: its own names, apart, so that [open Cepheus] adds only [Question] and [ask]. *)
module Question = Question

val ask : ?timeout:float -> view -> Question.t -> (value array list, error) result
(** The rows of the question, each a binding of its variables once (G11), in the order asked. [timeout]: as
    {!find}'s. *)

val fold :
  ?timeout:float -> view -> query -> init:(unit -> 'a) -> step:('a -> int array -> 'a) -> merge:('a -> 'a -> 'a) -> ('a, error) result
(** The bindings folded into an accumulator, without building values: [step] gets index words (thing ids for links,
    the value for ints, dates, money, 0/1 for booleans, dictionary numbers for texts and floats) in a buffer it may not
    keep; {!decode} turns a word back into its value. A large question runs on several domains, each with its own
    accumulator from [init ()], joined by [merge]; [step] must therefore only touch its accumulator. [timeout]: as
    {!find}'s. *)

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
module Pack = Pack
module Pages = Pages
module Histogram = Histogram
module Journal = Journal
module Pool = Pool
module Writers = Writers
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
module Wal = Wal
module Zone = Zone
