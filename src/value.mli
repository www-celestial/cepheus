(** Values and the types of properties. A value is atomic and typed: a list is several facts, a structure is a
    thing. In the indexes every value is one 64-bit word; texts and floats go through the dictionary. *)

type t =
  | Int of int  (** 63 bits, signed *)
  | Float of float
  | Bool of bool
  | Text of string
  | Date of int  (** an instant, UTC, in milliseconds since 1970 *)
  | Money of int  (** an exact decimal in minor units; the scale is the property's *)
  | Link of int  (** another thing of the same database; a negative id is a new thing of the same group *)

type typ = Tint | Tfloat | Tbool | Ttext | Tdate | Tmoney of int  (** decimal digits *) | Tlink

val has_type : typ -> t -> bool
val code : typ -> int
(** The number that stores a type as a fact ([cepheus/type]). *)

val of_code : int -> typ option
val typ_name : typ -> string
val to_string : t -> string
val equal : t -> t -> bool
val compare : t -> t -> int

val encode : Buffer.t -> t -> unit
(** The journal form: a tag byte, then the payload. *)

val decode : Codec.reader -> t
(** Raises [Codec.Short] on a bad tag or a short payload. *)

val inline : typ -> bool
(** Whether the index word is the value itself (ints, dates, money, booleans, links); texts and floats are
    dictionary numbers. *)
