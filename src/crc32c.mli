(** CRC-32C (Castagnoli), the checksum of every journal frame and snapshot section. *)

val bytes : Bytes.t -> int -> int -> int
(** [bytes b off len] is the CRC-32C of [len] bytes of [b] from [off], as an unsigned 32-bit int. *)

val string : string -> int
(** The CRC-32C of a whole string. *)

