(** The file vault: the bytes of files cut into content-defined chunks ({!Chunker}, FastCDC), each named by its
    BLAKE2b-256 keyed by its domain and stored once there, compressed (LZ4 warm, Zstandard cold), sealed by AEGIS-256
    under the domain's key, in packs that are only appended to; a file is a tree of nodes over its chunks, named by
    its root. Every read checks what it gives. The whole design, the formats and the guarantees (G22 to G24):
    [docs/book/vault.md]. *)

type t

type error =
  | Missing of string  (** a chunk or node that the vault does not hold *)
  | Damaged of string  (** a record that does not check *)
  | Erased of int  (** a domain whose key was erased *)
  | Io of string
  | Invalid of string
  | Busy of string

val message : error -> string

val open_ : ?cache:int -> Cepheus.Disk.t -> string -> master:string -> (t, error) result
(** [open_ disk dir ~master]: the vault in [dir], made if missing (0700), its domains' keys opened by [master] (32
    bytes, kept apart from the data). [cache]: the bytes of decoded nodes kept (32 MiB). One process at a time
    ({!Busy}). *)

val close : t -> unit

(** {1 Writing a file} *)

type writer

val writer : t -> domain:int -> cold:bool -> (writer, error) result
(** A file of a domain (>= 0: the thing whose key seals it); the domain's key is made at its first file; {!Erased}
    for an erased one. [cold]: Zstandard, for a file read seldom. *)

val feed : writer -> Bytes.t -> int -> int -> (unit, error) result
(** [feed w b off len]: the next bytes of the file, in pieces of any size. *)

val finish : writer -> (string * int, error) result
(** The file's root (32 bytes) and size, once every record it needs is forced to the disk (G22). *)

(** {1 Reading} *)

val size : t -> string -> (int, error) result

val load : t -> string -> from:int -> len:int -> (Bytes.t -> int -> int -> unit) -> (unit, error) result
(** [load t root ~from ~len f]: the bytes [from, from + len) in order, in pieces [f b off n] valid during the call;
    only the chunks under the range are read, each checked before a byte of it is given (G23). *)

(** {1 Erasing} *)

val erase : t -> int -> (unit, error) result
(** The domain's key destroyed: its files are unreadable wherever their records went (G24); the domain is never made
    again. *)

(** {1 Copies: what replication needs} *)

val names : t -> string list
(** Every record's name. *)

val raw : t -> string -> (Bytes.t, error) result
(** A record as it is on the disk (sealed), checked by its CRCs. *)

val add_raw : t -> Bytes.t -> (unit, error) result
(** A record of another copy appended as it is, once it checks; nothing if this vault holds it. *)

val sync : t -> (unit, error) result
(** What [add_raw] appended, forced. *)

val key_entries : t -> string list
(** The domains' keys sealed by the master key, and the domains erased. *)

val take_keys : t -> string list -> (unit, error) result
(** Another copy's entries: the keys this vault lacks (sealed by the same master key), the erasures. *)

(** {1 Roots in facts} *)

val hex : string -> string
val of_hex : string -> string option

(** {1 Settings, counts, and internals for the tests} *)

val workers : int ref
(** The domains that name and seal a put's chunks beside its thread (up to 3; 0: one after the other). *)

val pack_limit : int ref
(** A pack is closed when its next record would pass this (64 MiB). *)

val zstd_level : int ref
(** The cold codec's level (9). *)

val fanout : int
(** A node's children, at most (1,024). *)

val records : t -> int
val written : t -> int
val stored : t -> int
val reused : t -> int

exception Fail of error

type node = { level : int; names : string; ends : int array }

val parse_node : string -> Bytes.t -> node
(** A node's plain text, checked whole; raises [Fail (Damaged _)]. *)

val decode : t -> Bytes.t -> int -> int -> kind:int -> name:string -> int * Bytes.t
(** [decode t r o n ~kind ~name]: the domain and the raw bytes of the record at [o] (with [n] bytes from there),
    checked whole; raises [Fail _]. *)
