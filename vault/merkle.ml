(* What a copy of a vault lacks, without listing every record: a Merkle tree (Merkle, "A Digital Signature Based on a
   Conventional Encryption Function", CRYPTO 1987) over the set of the records' names, compared from the root, as the
   anti-entropy of Dynamo (DeCandia et al., SOSP 2007) and Cassandra compare their key ranges.

   The names are 256-bit keyed hashes: uniform. Their first 16 bits put each in one of 65,536 leaves; a leaf's digest
   is BLAKE2b-256 of its names, sorted; a node's, BLAKE2b-256 of its 16 children's digests (four levels of 16 under the
   root). Two trees are walked from the root down, and only where their digests differ: for d names in one set and
   not the other, among n, at most 4 x 16 digests a difference are asked, and the names of at most d leaves (about
   n / 65,536 each), rather than all n names. A digest that matches by chance where the sets differ is a collision of
   BLAKE2b-256: 2^-128 by the birthday bound for an adversary, 2^-256 by chance. *)

let fan = 16
let depth = 4
let leaves = 1 lsl 16

type t = { names : string array array;  (* each leaf's names, sorted *) levels : string array array  (* [0] the leaves' digests ... [depth] the root *) }

let digest s = Digest.BLAKE256.string s

let leaf_of name = (Char.code name.[0] lsl 8) lor Char.code name.[1]

let of_names (names : string Seq.t) =
  let buckets = Array.make leaves [] in
  Seq.iter (fun n -> if String.length n <> 32 then invalid_arg "Merkle.of_names"; let l = leaf_of n in buckets.(l) <- n :: buckets.(l)) names;
  let names = Array.map (fun l -> Array.of_list (List.sort_uniq compare l)) buckets in
  let level0 = Array.map (fun ns -> digest (String.concat "" (Array.to_list ns))) names in
  let levels = Array.make (depth + 1) [||] in
  levels.(0) <- level0;
  for k = 1 to depth do
    let below = levels.(k - 1) in
    levels.(k) <- Array.init (Array.length below / fan) (fun i -> digest (String.concat "" (Array.to_list (Array.sub below (i * fan) fan))))
  done;
  { names; levels }

let root t = t.levels.(depth).(0)

(* what a peer answers: the digests of the children of node [i] of level [k] (k >= 1), and the names of a leaf *)
type peer = { children : int -> int -> string array; leaf : int -> string array }

let children t k i = Array.sub t.levels.(k - 1) (i * fan) fan
let leaf t l = t.names.(l)
let peer t = { children = children t; leaf = leaf t }

(* the names the peer has and [t] lacks, and how many digests and names were asked of the peer *)
let missing t (p : peer) ~peer_root =
  let asked = ref 1 and got = ref [] in
  let rec walk k i =
    let theirs = p.children k i in
    asked := !asked + fan;
    let mine = children t k i in
    for j = 0 to fan - 1 do
      if not (String.equal theirs.(j) mine.(j)) then begin
        let c = (i * fan) + j in
        if k = 1 then begin
          let ns = p.leaf c in
          asked := !asked + Array.length ns;
          let have = t.names.(c) in
          let rec mem a b n = a < b && (let m = (a + b) / 2 in let x = compare have.(m) n in x = 0 || if x < 0 then mem (m + 1) b n else mem a m n) in
          Array.iter (fun n -> if not (mem 0 (Array.length have) n) then got := n :: !got) ns
        end
        else walk (k - 1) c
      end
    done
  in
  if not (String.equal peer_root (root t)) then walk depth 0;
  List.rev !got, !asked
