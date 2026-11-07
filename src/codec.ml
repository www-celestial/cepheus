let put_varint (b : Buffer.t) n =
  if n < 0 then invalid_arg "Codec.put_varint";
  let n = ref n in
  while !n >= 0x80 do
    Buffer.add_char b (Char.unsafe_chr (!n land 0x7f lor 0x80));
    n := !n lsr 7
  done;
  Buffer.add_char b (Char.unsafe_chr !n)

(* zigzag: 0 -> 0, -1 -> 1, 1 -> 2, ...; covers the whole 63-bit range *)
let put_int b n =
  let z = (n lsl 1) lxor (n asr 62) in
  let n = ref z in
  while !n land lnot 0x7f <> 0 do
    Buffer.add_char b (Char.unsafe_chr (!n land 0x7f lor 0x80));
    n := !n lsr 7
  done;
  Buffer.add_char b (Char.unsafe_chr !n)

let put_string b s =
  put_varint b (String.length s);
  Buffer.add_string b s

let put_u64 b x = Buffer.add_int64_le b x

type reader = { buf : Bytes.t; mutable pos : int; stop : int }

exception Short

let reader buf pos len =
  if pos < 0 || len < 0 || pos + len > Bytes.length buf then invalid_arg "Codec.reader";
  { buf; pos; stop = pos + len }

let get_byte r =
  if r.pos >= r.stop then raise Short;
  let c = Char.code (Bytes.unsafe_get r.buf r.pos) in
  r.pos <- r.pos + 1;
  c

let get_raw r =
  let rec go acc shift =
    if shift > 63 then raise Short;
    let c = get_byte r in
    let acc = acc lor ((c land 0x7f) lsl shift) in
    if c land 0x80 = 0 then acc else go acc (shift + 7)
  in
  go 0 0

let get_varint r =
  let n = get_raw r in
  if n < 0 then raise Short;
  n

let get_int r =
  let z = get_raw r in
  (z lsr 1) lxor (-(z land 1))

let get_string r =
  let n = get_varint r in
  if n > r.stop - r.pos then raise Short;
  let s = Bytes.sub_string r.buf r.pos n in
  r.pos <- r.pos + n;
  s

let get_u64 r =
  if r.stop - r.pos < 8 then raise Short;
  let x = Bytes.get_int64_le r.buf r.pos in
  r.pos <- r.pos + 8;
  x

let at_end r = r.pos >= r.stop
