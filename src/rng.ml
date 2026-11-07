(* SplitMix64 (Steele, Lea, Flood, "Fast Splittable Pseudorandom Number Generators", OOPSLA 2014), on OCaml's 63-bit
   ints: the same seed gives the same numbers on every machine and every OCaml, which Stdlib.Random does not promise
   across versions. Not for cryptography. *)

type t = { mutable s : int }

let make seed = { s = seed }
let copy r = { s = r.s }

let next r =
  r.s <- r.s + 0x1E3779B97F4A7C15;
  let z = r.s in
  let z = (z lxor (z lsr 30)) * 0x3F58476D1CE4E5B9 in
  let z = (z lxor (z lsr 27)) * 0x14D049BB133111EB in
  z lxor (z lsr 31)

let int r n =
  if n <= 0 then invalid_arg "Rng.int";
  (next r land max_int) mod n

let bool r = next r land 1 = 1
let chance r p = float_of_int (int r 1_000_000) < p *. 1e6
let pick r a = a.(int r (Array.length a))
let split r = make (next r)
