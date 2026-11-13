(* Content-defined chunks: FastCDC (Xia, Zhou, Jiang, Feng, Hua, Hu, Liu, Zhang, "FastCDC: a Fast and Efficient Content-Defined
   Chunking Approach for Data Deduplication", USENIX ATC 2016).

   A Gear hash rolls over the bytes, h = 2h + G[byte] (a 256-entry table of random words): a bit k of h depends on the
   last k + 1 bytes only, since a doubling pushes older bytes out at the top. A chunk ends after a byte where the bits
   of h under a mask are all zero: with a mask of k bits, a chance of 2^-k at each byte, so where the cuts fall
   depends on the bytes around them and nowhere else. An insertion moves the cuts near it only; the chunks after it
   are found again, and stored once (fixed-size chunks would all shift).

   Normalized chunking (the paper's section 3.3, level 2): no cut in the first 16 KiB of a chunk; then, up to the
   normal size of 64 KiB, a mask of 18 bits (2^-18 a byte: a cut is rare); after it, 14 bits (2^-14: soon); at
   256 KiB, a cut. The chance of a cut between 16 and 64 KiB is 1 - (1 - 2^-18)^49152, about 17 %; after 64 KiB a
   geometric tail of mean 2^14 = 16 KiB: a mean of about 73 KiB, the sizes close around 64 KiB.

   The mask's bits are 44 to 61 of h (OCaml's int has 63): they depend on the last 45 to 62 bytes, the window. The
   table is fixed for ever (a xorshift from a constant): another table would cut the same files elsewhere, and their
   chunks would not be found again. *)

let min_size = 16 * 1024
let normal = 64 * 1024
let max_size = 256 * 1024

let gear =
  let r = ref 0x1E3779B97F4A7C15 in
  Array.init 256 (fun _ ->
      r := !r lxor (!r lsl 13);
      r := !r lxor (!r lsr 7);
      r := !r lxor (!r lsl 17);
      !r)

let mask_s = ((1 lsl 18) - 1) lsl 44
let mask_l = ((1 lsl 14) - 1) lsl 44

(* the end of the chunk: the first i after which h has the mask's bits zero, the 18-bit mask before [normal] and the
   14-bit one after it, or [stop]; h and i are arguments of the loops: they stay in registers *)
let rec small (b : Bytes.t) h i normal stop =
  if i >= normal then large b h i stop
  else
    let h = (h lsl 1) + Array.unsafe_get gear (Char.code (Bytes.unsafe_get b i)) in
    if h land mask_s = 0 then i + 1 else small b h (i + 1) normal stop

and large (b : Bytes.t) h i stop =
  if i >= stop then stop
  else
    let h = (h lsl 1) + Array.unsafe_get gear (Char.code (Bytes.unsafe_get b i)) in
    if h land mask_l = 0 then i + 1 else large b h (i + 1) stop

(* [cut b off n]: the length of the chunk that starts at [off], given the [n] bytes from there; [n] is all that is
   left of the file, or at least [max_size] *)
let cut (b : Bytes.t) off n =
  if off < 0 || n < 0 || off > Bytes.length b - n then invalid_arg "Chunker.cut";
  if n <= min_size then n
  else
    let n = min n max_size in
    small b 0 (off + min_size) (off + min normal n) (off + n) - off
