(** The C the vault calls, behind one interface: the block codecs of LZ4 1.10.0 and Zstandard 1.5.7 (vendored at those
    versions, fuzzed by OSS-Fuzz upstream), and libsodium for the keyed hash, the keys and the authenticated
    encryption. Every offset and length is checked here before the call ([Invalid_argument] otherwise); a call never
    allocates on the OCaml heap, raises, or releases the runtime. *)

(** {1 LZ4: the warm codec} *)

val lz4_bound : int -> int
(** The largest block of [n] bytes. *)

val lz4_compress : Bytes.t -> int -> int -> Bytes.t -> int -> int -> int
(** [lz4_compress src off len dst doff cap]: the block's length in [dst] from [doff], or 0 when it needs more than
    [cap] bytes. *)

val lz4_decompress : Bytes.t -> int -> int -> Bytes.t -> int -> int -> bool
(** [lz4_decompress src off len dst doff raw]: whether the block decodes to exactly [raw] bytes, written into [dst]
    from [doff]. *)

(** {1 Zstandard: the cold codec} *)

type cctx
type dctx

val cctx : int -> cctx
(** A compression context at a level (1 to 22): one caller at a time. *)

val dctx : unit -> dctx
(** A decompression context, whose window is 1 MiB at most: one caller at a time. *)

val zstd_bound : int -> int

val zstd_compress : cctx -> Bytes.t -> int -> int -> Bytes.t -> int -> int -> int
(** [zstd_compress c src off len dst doff cap]: the frame's length, or 0 when it needs more than [cap] bytes. *)

val zstd_decompress : dctx -> Bytes.t -> int -> int -> Bytes.t -> int -> int -> bool
(** [zstd_decompress d src off len dst doff raw]: whether the frame decodes to exactly [raw] bytes. *)

(** {1 libsodium} *)

val key_bytes : int
(** 32: keys, names and nonces. *)

val tag_bytes : int
(** 32: the tag that {!seal} adds. *)

val hash : key:string -> Bytes.t -> int -> int -> string
(** BLAKE2b-256 keyed by a 32-byte key (RFC 7693): 32 bytes. *)

val derive : string -> int -> string
(** [derive key id]: the subkey number [id] (>= 0) of a 32-byte key (libsodium's crypto_kdf, BLAKE2b). *)

val seal : key:string -> nonce:string -> ad:string -> Bytes.t -> int -> int -> Bytes.t -> int -> unit
(** [seal ~key ~nonce ~ad src off len dst doff]: AEGIS-256 (Wu and Preneel, SAC 2013; draft-irtf-cfrg-aegis-aead) of
    [len] bytes, [ad] authenticated with them: [len + tag_bytes] bytes into [dst] from [doff]. *)

val open_ : key:string -> nonce:string -> ad:string -> Bytes.t -> int -> int -> Bytes.t -> int -> bool
(** [open_ ~key ~nonce ~ad src off len dst doff]: whether the tag of the [len] bytes (ciphertext then tag) checks, in
    constant time; then [len - tag_bytes] bytes of plain text in [dst] from [doff]. *)

val random : int -> string
(** Bytes from the system's generator. *)

val equal : string -> string -> bool
(** Two strings compared in a time that depends on their lengths only. *)
