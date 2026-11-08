(** The schema: a persistent table of properties and rules, derived from the facts about schema things. A schema
    thing, in [16, 65536), is a property (its name and type) or a rule (its name and definition). *)

type prop = { name : string; typ : Value.typ; many : bool; unique : bool }

val p_name : int  (** [cepheus/name], 1 *)
val p_type : int  (** [cepheus/type], 2: [Value.code] of the type *)
val p_many : int  (** [cepheus/many], 3 *)
val p_unique : int  (** [cepheus/unique], 4 *)
val p_rule : int  (** [cepheus/rule], 5: a rule's definition, its canonical text (Rules) *)

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
