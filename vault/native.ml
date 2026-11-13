(* The vault's C, behind this one module (vault_stubs.c). Each function checks its offsets and lengths, then calls a
   stub that cannot raise and does not allocate: the bytes stay where they are during the call. *)

external lz4_bound_ : int -> int = "cph_ml_lz4_bound" [@@noalloc]
external lz4_compress_ : Bytes.t -> int -> int -> Bytes.t -> int -> int -> int = "cph_ml_lz4_compress_byte" "cph_ml_lz4_compress" [@@noalloc]
external lz4_decompress_ : Bytes.t -> int -> int -> Bytes.t -> int -> int -> bool = "cph_ml_lz4_decompress_byte" "cph_ml_lz4_decompress" [@@noalloc]

type cctx
type dctx

external cctx_ : int -> cctx = "cph_ml_zstd_cctx"
external dctx_ : unit -> dctx = "cph_ml_zstd_dctx"
external zstd_bound_ : int -> int = "cph_ml_zstd_bound" [@@noalloc]
external zstd_compress_ : cctx -> Bytes.t -> int -> int -> Bytes.t -> int -> int -> int = "cph_ml_zstd_compress_byte" "cph_ml_zstd_compress" [@@noalloc]
external zstd_decompress_ : dctx -> Bytes.t -> int -> int -> Bytes.t -> int -> int -> bool = "cph_ml_zstd_decompress_byte" "cph_ml_zstd_decompress" [@@noalloc]

external sodium_init : unit -> int = "cph_ml_sodium_init"
external hash_ : string -> Bytes.t -> int -> int -> Bytes.t -> unit = "cph_ml_hash" [@@noalloc]
external derive_ : string -> int -> Bytes.t -> unit = "cph_ml_derive" [@@noalloc]
external seal_ : string -> string -> string -> Bytes.t -> int -> int -> Bytes.t -> int -> unit = "cph_ml_seal_byte" "cph_ml_seal" [@@noalloc]
external open__ : string -> string -> string -> Bytes.t -> int -> int -> Bytes.t -> int -> bool = "cph_ml_open_byte" "cph_ml_open" [@@noalloc]
external random_ : Bytes.t -> int -> int -> unit = "cph_ml_random" [@@noalloc]

let () = if sodium_init () < 0 then failwith "Cepheus: libsodium could not start"

let key_bytes = 32
let tag_bytes = 32

(* the largest input a stub takes: lengths stay far from the limits of C's int *)
let max_input = 1 lsl 30

let range name b off len = if off < 0 || len < 0 || len > max_input || off > Bytes.length b - len then invalid_arg name

let lz4_bound n = if n < 0 || n > max_input then invalid_arg "Native.lz4_bound" else lz4_bound_ n

let lz4_compress src off len dst doff cap =
  range "Native.lz4_compress" src off len;
  range "Native.lz4_compress" dst doff cap;
  lz4_compress_ src off len dst doff cap

let lz4_decompress src off len dst doff raw =
  range "Native.lz4_decompress" src off len;
  range "Native.lz4_decompress" dst doff raw;
  lz4_decompress_ src off len dst doff raw

let cctx level = if level < 1 || level > 22 then invalid_arg "Native.cctx" else cctx_ level
let dctx () = dctx_ ()
let zstd_bound n = if n < 0 || n > max_input then invalid_arg "Native.zstd_bound" else zstd_bound_ n

let zstd_compress c src off len dst doff cap =
  range "Native.zstd_compress" src off len;
  range "Native.zstd_compress" dst doff cap;
  max 0 (zstd_compress_ c src off len dst doff cap)

let zstd_decompress d src off len dst doff raw =
  range "Native.zstd_decompress" src off len;
  range "Native.zstd_decompress" dst doff raw;
  zstd_decompress_ d src off len dst doff raw

let key name k = if String.length k <> key_bytes then invalid_arg name

let hash ~key:k src off len =
  key "Native.hash" k;
  range "Native.hash" src off len;
  let out = Bytes.create 32 in
  hash_ k src off len out;
  Bytes.unsafe_to_string out

let derive k id =
  key "Native.derive" k;
  if id < 0 then invalid_arg "Native.derive";
  let out = Bytes.create 32 in
  derive_ k id out;
  Bytes.unsafe_to_string out

let seal ~key:k ~nonce ~ad src off len dst doff =
  key "Native.seal" k;
  key "Native.seal" nonce;
  range "Native.seal" src off len;
  range "Native.seal" dst doff (len + tag_bytes);
  seal_ k nonce ad src off len dst doff

let open_ ~key:k ~nonce ~ad src off len dst doff =
  key "Native.open_" k;
  key "Native.open_" nonce;
  range "Native.open_" src off len;
  len >= tag_bytes
  && begin
    range "Native.open_" dst doff (len - tag_bytes);
    open__ k nonce ad src off len dst doff
  end

let random n =
  let b = Bytes.create n in
  random_ b 0 n;
  Bytes.unsafe_to_string b

let equal a b =
  String.length a = String.length b
  && (let d = ref 0 in
      String.iteri (fun i c -> d := !d lor (Char.code c lxor Char.code (String.unsafe_get b i))) a;
      !d = 0)
