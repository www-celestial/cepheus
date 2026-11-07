(** The schema: a persistent table of properties, derived from the facts about property things. *)

type prop = { name : string; typ : Value.typ; many : bool; unique : bool }

val p_name : int  (** [cepheus/name], 1 *)
val p_type : int  (** [cepheus/type], 2: [Value.code] of the type *)
val p_many : int  (** [cepheus/many], 3 *)
val p_unique : int  (** [cepheus/unique], 4 *)

val first_prop : int
(** 16: the first id of a property of the application; property ids are below {!first_thing}. *)

val first_thing : int
(** 65536: the first id of an ordinary thing. *)

type t

val initial : t
(** The four system properties. *)

val find : t -> int -> prop option
val by_name : t -> string -> int option
val is_system : int -> bool
val is_prop_space : int -> bool
val count : t -> int
(** One more than the largest property id the table can hold. *)

val set : t -> int -> prop option -> t
val facts : int -> prop -> (int * int * Value.t) list
(** The facts that declare a property. *)

val system : prop option array
