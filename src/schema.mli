(** The schema: a persistent table of properties and rules, derived from the facts about schema things. A schema
    thing, in [16, 65536), is a property (its name and type) or a rule (its name and definition). *)

type prop = { name : string; typ : Value.typ; many : bool; unique : bool }

val p_name : int  (** [cepheus/name], 1 *)
val p_type : int  (** [cepheus/type], 2: [Value.code] of the type *)
val p_many : int  (** [cepheus/many], 3 *)
val p_unique : int  (** [cepheus/unique], 4 *)
val p_rule : int  (** [cepheus/rule], 5: a rule's definition, its canonical text (Rules) *)

val p_same : int
(** [cepheus/same], 6: [x cepheus/same r], derived only, says that the thing x is the same as r, the representative of
    its class of equal things (the reasoner design, section 5.10); a rule whose head gives it makes two things one. No
    write asserts it, and no group 1 declares it: a database made before it knows it all the same. *)

val p_to : int
(** [cepheus/to], 7: on a link property, the kind its values are things of (Link(to = "client")): a text, the kind's
    name. Known to every database, as [cepheus/same]; no group 1 declares it. *)

val p_delete : int
(** [cepheus/delete], 8: on a link property that names a kind, what its facts do when the thing they link to stops
    being of that kind: "refuse" (the default), "cascade" or "clear". *)

val first_prop : int
(** 16: the first id of a property of the application; property ids are below {!first_thing}. *)

val first_thing : int
(** 65536: the first id of an ordinary thing. *)

val last_thing : int
(** 2,147,483,647 (2{^31} - 1): the largest thing id. A run counts the things it holds in 31 bits (the high half of
    a 64-bit word of its rank table, read back into OCaml's 63-bit int) and stores a thing in 4 bytes; a group that
    would give a larger id is refused. *)

type t

val initial : t
(** The five system properties. *)

val find : t -> int -> prop option
val by_name : t -> string -> int option
val is_system : int -> bool
val is_prop_space : int -> bool
val count : t -> int
(** One more than the largest property id the table can hold. *)

val set : t -> int -> prop option -> t
val facts : int -> prop -> (int * int * Value.t) list
(** The facts that declare a property. *)

val rules : t -> (int * (string * string)) list
(** The rules: (rule thing, (name, definition)), by thing. *)

val has_rules : t -> bool
val rule : t -> int -> (string * string) option
val rule_by_name : t -> string -> int option

val set_rule : t -> int -> (string * string) option -> t

val rules_key : t -> int
(** A number that changes whenever the rules change (0: no rule ever): what a compiled rule set is cached by. *)

val system : prop option array

(** {1 Links that name a kind}

    A property's kind is its name before its first '/' ([client/City] is of the kind client). A thing is of a kind
    while it has a fact of one of the kind's properties that a write asserted. *)

type on_delete = Refuse | Cascade | Clear

type link = { kind : string; on_delete : on_delete }

val on_delete_name : on_delete -> string
val on_delete_of : string -> on_delete option
val kind_of : string -> string

val link : t -> int -> link option
(** The kind a link property names, if one. *)

val has_links : t -> bool
val links : t -> (int * link) list
val set_link : t -> int -> link option -> t

type index = private {
  pkind : int array;  (** by property id: its kind's number, -1 for no property *)
  named : Bytes.t;  (** by property id: 1 when some link names its kind *)
  pto : int array;  (** by property id: the number of the kind its link names, -1 none *)
  kinds : string array;  (** by kind number: its name *)
  kind_ids : (string, int) Hashtbl.t;
  members : int array array;  (** by kind number: its properties *)
  linkers : (int * on_delete) array array;  (** by kind number: the link properties that name it *)
}

val index : t -> index
(** Made once a schema value, at its first use. *)

val kind_id : index -> string -> int
(** -1 for a kind with no property and no link naming it. *)

val named : index -> int -> bool
