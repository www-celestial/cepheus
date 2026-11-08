(** CRC-32C (Castagnoli), the checksum of every journal frame and snapshot section. *)

val bytes : Bytes.t -> int -> int -> int
(** [bytes b off len] is the CRC-32C of [len] bytes of [b] from [off], as an unsigned 32-bit int. *)

val extend : int -> Bytes.t -> int -> int -> int
(** [extend crc b off len] is the CRC-32C of the bytes whose CRC is [crc], followed by [len] bytes of [b] from [off]:
    [bytes b 0 (m + n)] is [extend (bytes b 0 m) b m n]. *)

val string : string -> int
(** The CRC-32C of a whole string. *)

