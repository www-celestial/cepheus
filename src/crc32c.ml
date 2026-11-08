(* CRC-32C, reflected polynomial 0x82F63B78 (Castagnoli, Braeuer, Herrmann 1993), by the processor's instruction: crc32
   of SSE4.2 on x86-64, the CRC32 instructions of ARMv8 on arm64 (crc32c_stubs.c). About 9 GB/s on the test machine,
   eight times the table code in OCaml it replaced, which the tests keep as their oracle (test/unit.ml). A processor
   without the instruction is refused when the program starts: there is one way to compute the checksum. *)

external supported : unit -> bool = "cepheus_crc32c_supported" [@@noalloc]
external run : int -> Bytes.t -> int -> int -> int = "cepheus_crc32c_extend" [@@noalloc]

let () =
  if not (supported ()) then
    failwith
      "Cepheus needs the processor's CRC-32C instruction (SSE4.2 on x86-64, CRC32 on arm64), and this processor has \
       none"

(* a call never stops for the GC: a large frame goes by pieces of 1 MiB (about 0.1 ms), so that another domain asking
   for a collection waits at most that long *)
let piece = 1 lsl 20

let extend crc (b : Bytes.t) off len =
  if off < 0 || len < 0 || off > Bytes.length b - len then invalid_arg "Crc32c.extend";
  let c = ref crc and o = ref off and n = ref len in
  while !n > piece do
    c := run !c b !o piece;
    o := !o + piece;
    n := !n - piece
  done;
  run !c b !o !n

let bytes b off len = extend 0 b off len

let string s = bytes (Bytes.unsafe_of_string s) 0 (String.length s)
