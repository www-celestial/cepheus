(** Varints (LEB128), zigzag signed ints and length-prefixed strings: the encoding of groups in the journal. *)

val put_varint : Buffer.t -> int -> unit
(** An int >= 0 in 1 to 9 bytes. *)

val put_int : Buffer.t -> int -> unit
(** Any int, zigzag-encoded so small negatives stay short. *)

val put_string : Buffer.t -> string -> unit

val put_u64 : Buffer.t -> int64 -> unit
(** Eight bytes, little-endian (a float's bits). *)

(** A reader over a part of some bytes. Every read checks the bounds and raises {!Short} past the end. *)
type reader = { buf : Bytes.t; mutable pos : int; stop : int }

exception Short

val reader : Bytes.t -> int -> int -> reader
val get_varint : reader -> int
val get_int : reader -> int
val get_byte : reader -> int
val get_string : reader -> string
val get_u64 : reader -> int64
val at_end : reader -> bool
