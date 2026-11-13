(* The vault's tests: its C interface (codecs, keyed hash, sealing), from fixed seeds; each failure names its seed. *)

open Cepheus
open Cepheus_vault
module C = Check

let section name = Printf.printf "- %s\n%!" name

let hex s = String.concat "" (List.init (String.length s) (fun i -> Printf.sprintf "%02x" (Char.code s.[i])))

(* bytes that compress: words from a small dictionary, with numbers *)
let text r n =
  let words = [| "the "; "vault "; "keeps "; "files "; "chunk "; "of "; "a "; "fact "; "\n"; "Cepheus "; "1234 "; "x=" |] in
  let b = Buffer.create n in
  while Buffer.length b < n do Buffer.add_string b words.(Rng.int r (Array.length words)) done;
  Bytes.sub (Buffer.to_bytes b) 0 n

let random r n = Bytes.init n (fun _ -> Char.chr (Rng.int r 256))

(* ---- the C interface ---- *)

let () =
  section "native: LZ4 and Zstandard blocks round trip, and refuse a wrong length or a damaged block";
  let cctx = Native.cctx 3 and dctx = Native.dctx () in
  for seed = 1 to 300 do
    let r = Rng.make seed in
    let n = match Rng.int r 4 with 0 -> Rng.int r 16 | 1 -> Rng.int r 4096 | _ -> Rng.int r (256 * 1024) in
    let src = if Rng.int r 2 = 0 then text r n else random r n in
    let off = Rng.int r 8 in
    let s = Bytes.make (off + n + 8) '\255' in
    Bytes.blit src 0 s off n;
    List.iter
      (fun (name, bound, comp, dec) ->
        let cap = bound n in
        let dst = Bytes.make (cap + 5) '\000' in
        let k = comp s off n dst 5 cap in
        C.check (k > 0) "seed %d %s: %d bytes compressed" seed name n;
        let out = Bytes.make (n + 3) '\170' in
        C.check (dec dst 5 k out 3 n && Bytes.sub out 3 n = src) "seed %d %s: %d bytes round trip" seed name n;
        if n > 0 then C.check (not (dec dst 5 k out 3 (n - 1))) "seed %d %s: one byte too few refused" seed name;
        C.check (not (dec dst 5 k (Bytes.create (n + 4)) 3 (n + 1))) "seed %d %s: one byte too many refused" seed name;
        (* a damaged block: the right bytes, or a refusal; never a write outside the output (checked by the fuzzer) *)
        if k > 1 then begin
          let d = Bytes.copy dst in
          let i = 5 + Rng.int r k in
          Bytes.set d i (Char.chr (Char.code (Bytes.get d i) lxor (1 lsl Rng.int r 8)));
          ignore (dec d 5 k (Bytes.create n) 0 n)
        end;
        if k > 1 then C.check (not (dec dst 5 (k - 1) out 3 n)) "seed %d %s: a cut block refused" seed name)
      [ "lz4", Native.lz4_bound, Native.lz4_compress, Native.lz4_decompress;
        "zstd", Native.zstd_bound, Native.zstd_compress cctx, Native.zstd_decompress dctx ]
  done;
  (* a block that does not fit is 0, not a short write *)
  let src = random (Rng.make 7) 4096 in
  C.check (Native.lz4_compress src 0 4096 (Bytes.create 100) 0 100 = 0) "lz4: no room is 0";
  C.check (Native.zstd_compress cctx src 0 4096 (Bytes.create 100) 0 100 = 0) "zstd: no room is 0";
  List.iter
    (fun (name, f) -> C.check (match f () with _ -> false | exception Invalid_argument _ -> true) "bounds: %s refused" name)
    [ "lz4 past the end", (fun () -> ignore (Native.lz4_compress src 4000 200 (Bytes.create 9000) 0 9000));
      "lz4 a negative offset", (fun () -> ignore (Native.lz4_decompress src (-1) 10 (Bytes.create 10) 0 10));
      "lz4 output too small", (fun () -> ignore (Native.lz4_decompress src 0 10 (Bytes.create 10) 1 10));
      "zstd output too small", (fun () -> ignore (Native.zstd_decompress dctx src 0 10 (Bytes.create 10) 5 6));
      "zstd level 0", (fun () -> ignore (Native.cctx 0));
      "hash short key", (fun () -> ignore (Native.hash ~key:"k" src 0 1));
      "seal short nonce", (fun () -> Native.seal ~key:(String.make 32 'k') ~nonce:"n" ~ad:"" src 0 1 (Bytes.create 64) 0);
      "seal output too small", (fun () -> Native.seal ~key:(String.make 32 'k') ~nonce:(String.make 32 'n') ~ad:"" src 0 10 (Bytes.create 41) 0) ]

let () =
  section "native: keyed BLAKE2b-256 and the key derivation, against Python's hashlib";
  let key = String.init 32 Char.chr in
  List.iter
    (fun (n, want) ->
      let m = Bytes.init n (fun i -> Char.chr (((i * 7) + 3) mod 256)) in
      let b = Bytes.make (n + 4) 'z' in
      Bytes.blit m 0 b 2 n;
      C.check (hex (Native.hash ~key b 2 n) = want) "blake2b keyed, %d bytes" n)
    [ 0, "4e51e7a913fc80137da52880fecca175bf81e117d5c68126dc2774033517ea0d";
      1, "5500a8ed696e45255a024afc49a57aa45ea21a254c30dcdea61da13552c6c0b1";
      3, "2f28ee247d3e95ec9bcd4c3a548a3b462c0c6984103ab363e6ce01fe746046d6";
      64, "3d06a36e883b81698a5a35101181be548af80cd22150c48475b8ef46bb313a29";
      65, "5c266b67ca82b3e7c6655422904682f8a0c669158ce552529b982b857b632b91";
      1000, "eb07b428f1674f6598aaecf9b898c520824910d6f4c531e6f62f81b9d5946387" ];
  List.iter
    (fun (i, want) -> C.check (hex (Native.derive key i) = want) "kdf subkey %d" i)
    [ 0, "6ff52ee72a81f6b66ea122977838f7f4732e91fc47d12e6162d6679db982f9f2";
      1, "c6fca487a05c74fefcd953f2e6b1509298bda424dcf00cd110497d8901bd4798";
      2, "bd6d6fcab1b5ff6baf976859711e1911e65af65d3724ef4c19aaf794b667c06f";
      7, "f16cc3e720d21afe5189484fce5a78e7072315ffdc30970d2b0be606b7ea0aa3" ]

let () =
  section "native: AEGIS-256 seals and opens; any changed bit, key, nonce or associated byte is refused";
  for seed = 1 to 200 do
    let r = Rng.make seed in
    let key = Native.random 32 and nonce = Native.random 32 in
    let ad = Bytes.to_string (random r (Rng.int r 80)) in
    let n = Rng.int r 70000 in
    let m = random r n in
    let c = Bytes.create (n + Native.tag_bytes + 1) in
    Native.seal ~key ~nonce ~ad m 0 n c 1;
    let len = n + Native.tag_bytes in
    let o = Bytes.create (n + 2) in
    C.check (Native.open_ ~key ~nonce ~ad c 1 len o 2 && Bytes.sub o 2 n = m) "seed %d: %d bytes open" seed n;
    let flip = Bytes.copy c in
    let i = 1 + Rng.int r len in
    Bytes.set flip i (Char.chr (Char.code (Bytes.get flip i) lxor (1 lsl Rng.int r 8)));
    C.check (not (Native.open_ ~key ~nonce ~ad flip 1 len o 2)) "seed %d: a flipped bit refused" seed;
    let other s = let b = Bytes.of_string s in let i = Rng.int r 32 in Bytes.set b i (Char.chr (Char.code s.[i] lxor 1)); Bytes.to_string b in
    C.check (not (Native.open_ ~key:(other key) ~nonce ~ad c 1 len o 2)) "seed %d: another key refused" seed;
    C.check (not (Native.open_ ~key ~nonce:(other nonce) ~ad c 1 len o 2)) "seed %d: another nonce refused" seed;
    C.check (not (Native.open_ ~key ~nonce ~ad:(ad ^ "x") c 1 len o 2)) "seed %d: another associated text refused" seed;
    if len > 1 then C.check (not (Native.open_ ~key ~nonce ~ad c 1 (len - 1) o 2)) "seed %d: a cut text refused" seed
  done;
  C.check (not (Native.open_ ~key:(String.make 32 'k') ~nonce:(String.make 32 'n') ~ad:"" (Bytes.create 31) 0 31 (Bytes.create 0) 0))
    "a text shorter than its tag refused";
  C.check (Native.equal "abc" "abc" && not (Native.equal "abc" "abd") && not (Native.equal "abc" "ab")) "equal"

let () = C.finish "vault"
