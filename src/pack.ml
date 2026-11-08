(* Bit packing: integers of w bits one after the other, little-endian, as a frame of reference codes them (Goldstein,
   Ramakrishnan, Shaft, ICDE 1998; Zukowski, Héman, Nes, Boncz, ICDE 2006): a block of values is stored as its base
   and, for each value, its difference from the base in as many bits as the largest difference needs. Field i of
   width w holds bits i*w .. i*w + w - 1 of the stream, bit k of the stream being bit (k mod 8) of byte k / 8.

   A field is read with one unaligned 8-byte load, a shift and a mask when it fits in the load (w <= 55), as Lemire
   and Boytsov's scalar unpacking does (Software: Practice and Experience 45(1), 2015), and byte by byte otherwise. The
   journal codes its columns with it (Group), the runs their blocks (Store, Snapshot). Every width is at most 63: an
   OCaml int, read as an unsigned 63-bit number. *)

external get64u : Bytes.t -> int -> int64 = "%caml_bytes_get64u"
external set64u : Bytes.t -> int -> int64 -> unit = "%caml_bytes_set64u"

(* the bits of x read as an unsigned 63-bit number: 0 for 0, 63 for a negative int *)
let width x =
  if x < 0 then 63
  else begin
    let n = ref 0 and y = ref x in
    if !y lsr 32 <> 0 then (n := 32; y := !y lsr 32);
    if !y lsr 16 <> 0 then (n := !n + 16; y := !y lsr 16);
    if !y lsr 8 <> 0 then (n := !n + 8; y := !y lsr 8);
    if !y lsr 4 <> 0 then (n := !n + 4; y := !y lsr 4);
    if !y lsr 2 <> 0 then (n := !n + 2; y := !y lsr 2);
    if !y lsr 1 <> 0 then (n := !n + 1; y := !y lsr 1);
    !n + !y
  end

let[@inline] mask w = (1 lsl w) - 1

(* bytes for n fields of w bits *)
let[@inline] bytes n w = ((n * w) + 7) lsr 3

let[@inline never] get_slow (b : Bytes.t) bit w =
  let o = bit lsr 3 and sh = bit land 7 in
  let last = (sh + w - 1) lsr 3 in
  let x = ref (Char.code (Bytes.get b o) lsr sh) in
  for k = 1 to last do
    x := !x lor (Char.code (Bytes.get b (o + k)) lsl ((8 * k) - sh))
  done;
  !x land mask w

(* the field of w bits at bit [bit] of b *)
let[@inline] get (b : Bytes.t) bit w =
  if w = 0 then 0
  else
    let o = bit lsr 3 in
    if w <= 55 && o + 8 <= Bytes.length b then (Int64.to_int (get64u b o) lsr (bit land 7)) land mask w
    else get_slow b bit w

let[@inline never] put_slow (b : Bytes.t) bit x w =
  let o = bit lsr 3 and sh = bit land 7 in
  let x = x land mask w in
  let last = (sh + w - 1) lsr 3 in
  Bytes.set b o (Char.unsafe_chr (Char.code (Bytes.get b o) lor ((x lsl sh) land 0xFF)));
  for k = 1 to last do
    Bytes.set b (o + k) (Char.unsafe_chr (Char.code (Bytes.get b (o + k)) lor ((x lsr ((8 * k) - sh)) land 0xFF)))
  done

(* x into the field of w bits at bit [bit] of b, whose bits there are zeros *)
let[@inline] put (b : Bytes.t) bit x w =
  if w > 0 then begin
    let o = bit lsr 3 in
    if w <= 55 && o + 8 <= Bytes.length b then
      set64u b o (Int64.logor (get64u b o) (Int64.of_int ((x land mask w) lsl (bit land 7))))
    else put_slow b bit x w
  end

(* ---- Columns of the journal ----
   n ints as blocks of 128 (the last one shorter): a byte (bits 0-6 the width w, bit 7 the mode), then
     mode 0, the frame of reference: base (zigzag varint), then the n values minus base in w bits each;
     mode 1, deltas: the first value (zigzag varint), the least difference d between a value and the one before it
          (zigzag varint), then for each later value its difference minus d in w bits.
   The writer takes the mode that makes the block shorter (BtrBlocks picks a scheme per block the same way: Kuschewski
   et al., SIGMOD 2023). Differences are taken modulo 2^63, as OCaml's ints wrap: any values come back exactly. *)

let block = 128

let scratch = Domain.DLS.new_key (fun () -> Bytes.create ((block * 8) + 8))

let zlen n = let z = (n lsl 1) lxor (n asr 62) in if z land lnot 0x7f = 0 then 1 else
    let k = ref 1 and x = ref (z lsr 7) in while !x > 0 do incr k; x := !x lsr 7 done; !k

let put_ints (out : Buffer.t) n (f : int -> int) =
  let s = Domain.DLS.get scratch in
  let v = Array.make block 0 in
  let i = ref 0 in
  while !i < n do
    let len = min block (n - !i) in
    for k = 0 to len - 1 do v.(k) <- f (!i + k) done;
    let lo = ref v.(0) and hi = ref v.(0) in
    for k = 1 to len - 1 do let x = v.(k) in if x < !lo then lo := x; if x > !hi then hi := x done;
    let wr = width (!hi - !lo) in
    let dlo = ref 0 and dhi = ref 0 in
    if len > 1 then begin
      dlo := v.(1) - v.(0); dhi := !dlo;
      for k = 2 to len - 1 do let d = v.(k) - v.(k - 1) in if d < !dlo then dlo := d; if d > !dhi then dhi := d done
    end;
    let wd = width (!dhi - !dlo) in
    let raw = zlen !lo + bytes len wr and delta = zlen v.(0) + zlen !dlo + bytes (len - 1) wd in
    if len > 1 && delta < raw then begin
      Buffer.add_char out (Char.unsafe_chr (0x80 lor wd));
      Codec.put_int out v.(0);
      Codec.put_int out !dlo;
      let nb = bytes (len - 1) wd in
      Bytes.fill s 0 (nb + 8) '\000';
      for k = 1 to len - 1 do put s ((k - 1) * wd) (v.(k) - v.(k - 1) - !dlo) wd done;
      Buffer.add_subbytes out s 0 nb
    end
    else begin
      Buffer.add_char out (Char.unsafe_chr wr);
      Codec.put_int out !lo;
      let nb = bytes len wr in
      Bytes.fill s 0 (nb + 8) '\000';
      for k = 0 to len - 1 do put s (k * wr) (v.(k) - !lo) wr done;
      Buffer.add_subbytes out s 0 nb
    end;
    i := !i + len
  done

(* n ints of a column, into a.(at) .. a.(at + n - 1); raises Codec.Short on bytes that are not a column *)
let get_ints (r : Codec.reader) n (a : int array) at =
  let i = ref 0 in
  while !i < n do
    let len = min block (n - !i) in
    let h = Codec.get_byte r in
    let w = h land 0x7F in
    if w > 63 then raise Codec.Short;
    let base = Codec.get_int r in
    let o = at + !i in
    if h land 0x80 = 0 then begin
      let nb = bytes len w in
      if nb > r.stop - r.pos then raise Codec.Short;
      let bit = r.pos * 8 in
      if w = 0 then Array.fill a o len base
      else for k = 0 to len - 1 do a.(o + k) <- base + get r.buf (bit + (k * w)) w done;
      r.pos <- r.pos + nb
    end
    else begin
      if len < 2 then raise Codec.Short;
      let d = Codec.get_int r in
      let nb = bytes (len - 1) w in
      if nb > r.stop - r.pos then raise Codec.Short;
      let bit = r.pos * 8 in
      a.(o) <- base;
      for k = 1 to len - 1 do a.(o + k) <- a.(o + k - 1) + d + get r.buf (bit + ((k - 1) * w)) w done;
      r.pos <- r.pos + nb
    end;
    i := !i + len
  done
