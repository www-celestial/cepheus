(* CRC-32C, reflected, polynomial 0x82F63B78, slicing by 8: eight table lookups a word of eight bytes. Pure OCaml,
   about 1.1 GB/s on the test machine (Castagnoli, Braeuer, Herrmann 1993; tables as in Intel's slicing-by-8). *)

let poly = 0x82F63B78
let t = Array.make (8 * 256) 0

let () =
  for i = 0 to 255 do
    let c = ref i in
    for _ = 0 to 7 do
      c := if !c land 1 = 1 then (!c lsr 1) lxor poly else !c lsr 1
    done;
    t.(i) <- !c
  done;
  for i = 0 to 255 do
    for k = 1 to 7 do
      let prev = t.(((k - 1) * 256) + i) in
      t.((k * 256) + i) <- (prev lsr 8) lxor t.(prev land 0xff)
    done
  done

let[@inline] step8 c lo hi =
  let lo = lo lxor c in
  Array.unsafe_get t ((7 * 256) + (lo land 0xff))
  lxor Array.unsafe_get t ((6 * 256) + ((lo lsr 8) land 0xff))
  lxor Array.unsafe_get t ((5 * 256) + ((lo lsr 16) land 0xff))
  lxor Array.unsafe_get t ((4 * 256) + ((lo lsr 24) land 0xff))
  lxor Array.unsafe_get t ((3 * 256) + (hi land 0xff))
  lxor Array.unsafe_get t ((2 * 256) + ((hi lsr 8) land 0xff))
  lxor Array.unsafe_get t (256 + ((hi lsr 16) land 0xff))
  lxor Array.unsafe_get t ((hi lsr 24) land 0xff)

let extend crc (b : Bytes.t) off len =
  if off < 0 || len < 0 || off + len > Bytes.length b then invalid_arg "Crc32c.extend";
  let c = ref (crc lxor 0xFFFFFFFF) and i = ref off in
  let stop = off + len in
  while !i + 8 <= stop do
    let lo = Int32.to_int (Bytes.get_int32_le b !i) land 0xFFFFFFFF in
    let hi = Int32.to_int (Bytes.get_int32_le b (!i + 4)) land 0xFFFFFFFF in
    c := step8 !c lo hi;
    i := !i + 8
  done;
  while !i < stop do
    c := Array.unsafe_get t ((!c lxor Char.code (Bytes.unsafe_get b !i)) land 0xff) lxor (!c lsr 8);
    incr i
  done;
  !c lxor 0xFFFFFFFF

let bytes b off len = extend 0 b off len

let string s = bytes (Bytes.unsafe_of_string s) 0 (String.length s)

