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


(* ---- the chunker ---- *)

(* the chunks of a whole buffer, as lengths *)
let cuts (b : Bytes.t) =
  let n = Bytes.length b in
  let rec go o acc = if o >= n then List.rev acc else let c = Chunker.cut b o (n - o) in go (o + c) (c :: acc) in
  go 0 []

let () =
  section "chunker: every chunk within its bounds, the sizes as the formula says, cuts that come back after an insertion";
  let r = Rng.make 11 in
  let b = random r (24 lsl 20) in
  let cs = cuts b in
  let n = List.length cs in
  C.check (List.fold_left ( + ) 0 cs = Bytes.length b) "the chunks cover the bytes";
  C.check (List.for_all (fun c -> c >= Chunker.min_size && c <= Chunker.max_size) (List.filteri (fun i _ -> i < n - 1) cs)) "16 KiB <= a chunk <= 256 KiB";
  let mean = float (Bytes.length b) /. float n in
  (* the formula: 0.17 x 40 KiB + 0.83 x 80 KiB, about 73 KiB; 340 chunks: the mean within 10 % *)
  C.check (mean > 66_000. && mean < 82_000.) "mean %.0f bytes on random bytes (about 73 KiB expected)" mean;
  (* 100 bytes inserted at 5 MB and at 12 MB: the chunks of the copy, all but those around the insertions, are the
     original's *)
  let ins = random r 100 in
  let at k = 5 lsl 20 + (k * 7 lsl 20) in
  let b' = Bytes.concat Bytes.empty [ Bytes.sub b 0 (at 0); ins; Bytes.sub b (at 0) (at 1 - at 0); ins; Bytes.sub b (at 1) (Bytes.length b - at 1) ] in
  let set bs = let h = Hashtbl.create 512 in let o = ref 0 in List.iter (fun c -> Hashtbl.replace h (Bytes.sub_string bs !o c) (); o := !o + c) (cuts bs); h in
  let old = set b in
  let o = ref 0 and found = ref 0 in
  List.iter (fun c -> if Hashtbl.mem old (Bytes.sub_string b' !o c) then found := !found + c; o := !o + c) (cuts b');
  let share = float !found /. float (Bytes.length b') in
  C.check (share > 0.97) "%.1f %% of the copy's bytes in chunks found again" (100. *. share);
  (* fixed chunks would find almost nothing after the first insertion *)
  let fixed bs = let h = Hashtbl.create 512 in for i = 0 to (Bytes.length bs / 65536) - 1 do Hashtbl.replace h (Bytes.sub_string bs (i * 65536) 65536) () done; h in
  let fo = fixed b and ff = ref 0 in
  for i = 0 to (Bytes.length b' / 65536) - 1 do if Hashtbl.mem fo (Bytes.sub_string b' (i * 65536) 65536) then ff := !ff + 65536 done;
  C.check (float !ff /. float (Bytes.length b') < 0.3) "fixed 64 KiB chunks: %.1f %%" (100. *. float !ff /. float (Bytes.length b'));
  C.check (cuts (Bytes.create 0) = [] && cuts (Bytes.make 100 'a') = [ 100 ]) "short inputs: one chunk or none";
  (* bytes of one value: no cut before the largest size *)
  C.check (List.hd (cuts (Bytes.make (1 lsl 20) 'a')) = Chunker.max_size) "constant bytes cut at the largest size"

(* ---- the store ---- *)

let tmp = match Sys.getenv_opt "CEPHEUS_TMP" with Some d -> d | None -> Filename.get_temp_dir_name ()
let fresh name = let d = Filename.concat tmp (Printf.sprintf "vault-%s-%d" name (Unix.getpid ())) in ignore (Sys.command ("rm -rf " ^ Filename.quote d)); d
let master = String.make 32 'm'
let ok what = function Ok x -> x | Error e -> failwith (what ^ ": " ^ Vault.message e)

(* a file written in pieces of random sizes *)
let put ?(r = Rng.make 1) ?(cold = false) v domain (b : Bytes.t) =
  let w = ok "writer" (Vault.writer v ~domain ~cold) in
  let o = ref 0 in
  while !o < Bytes.length b do
    let k = min (Bytes.length b - !o) (1 + Rng.int r (if Rng.int r 2 = 0 then 1000 else 3_000_000)) in
    ok "feed" (Vault.feed w b !o k);
    o := !o + k
  done;
  ok "finish" (Vault.finish w)

let get v root ~from ~len =
  let out = Buffer.create len in
  Result.map (fun () -> Buffer.to_bytes out) (Vault.load v root ~from ~len (fun b o n -> Buffer.add_subbytes out b o n))

let whole v root = match Vault.size v root with Error e -> Error e | Ok n -> get v root ~from:0 ~len:n

let () =
  section "store: files of every size round trip, warm and cold, in pieces of any size; ranges equal slices";
  let dir = fresh "store" in
  let v = ok "open" (Vault.open_ Disk.real dir ~master) in
  let r = Rng.make 21 in
  let sizes = [ 0; 1; 1000; Chunker.min_size - 1; Chunker.min_size; Chunker.min_size + 1; Chunker.max_size - 1; Chunker.max_size;
                Chunker.max_size + 1; 3 lsl 20; 9 lsl 20 ] in
  List.iteri
    (fun i n ->
      List.iter
        (fun cold ->
          let b = if i mod 2 = 0 then text r n else random r n in
          let root, size = put ~r ~cold v 1 b in
          C.check (size = n) "size %d" n;
          C.check (Vault.size v root = Ok n) "size of the root, %d" n;
          C.check (whole v root = Ok b) "%d bytes (%s) round trip" n (if cold then "cold" else "warm");
          for _ = 1 to 25 do
            let from = if n = 0 then 0 else Rng.int r (n + 1) in
            let len = Rng.int r (min (n - from + 1) (if Rng.int r 2 = 0 then 5000 else 1_000_000)) in
            C.check (get v root ~from ~len = Ok (Bytes.sub b from len)) "%d bytes: range %d+%d" n from len
          done;
          C.check (match get v root ~from:n ~len:1 with Error (Vault.Invalid _) -> true | _ -> false) "a range past the end refused";
          C.check (match get v root ~from:(-1) ~len:1 with Error (Vault.Invalid _) -> true | _ -> false) "a negative offset refused")
        [ false; true ])
    sizes;
  (* chunks sealed one after the other, then on the workers: the same names (the second put finds every record) *)
  let b = text r (5 lsl 20) in
  let w0 = !Vault.workers in
  Vault.workers := 0;
  let ra, _ = put ~r v 4 b in
  Vault.workers := max 2 w0;
  let before = Vault.written v in
  let rb, _ = put ~r v 4 b in
  let same = Vault.written v = before in
  let rc, _ = put ~r ~cold:true v 4 (Bytes.cat b (Bytes.of_string "!")) in
  Vault.workers := w0;
  C.check (ra = rb && same && whole v rb = Ok b) "one core or the workers: the same records";
  C.check (whole v rc = Ok (Bytes.cat b (Bytes.of_string "!"))) "the workers seal cold chunks too";
  (* text compresses: the cold codec keeps less than the warm one, both far less than the raw bytes *)
  let t8 = text r (8 lsl 20) in
  let s0 = Vault.stored v in
  ignore (put v 2 t8);
  let warm = Vault.stored v - s0 in
  let s1 = Vault.stored v in
  ignore (put ~cold:true v 3 t8);
  let cold = Vault.stored v - s1 in
  C.check (warm < Bytes.length t8 / 2 && cold < warm) "8 MB of text: warm %d bytes, cold %d" warm cold;
  Vault.close v;
  section "store: a file written twice is stored once; an edited copy stores only its new chunks; domains never share";
  let v = ok "open" (Vault.open_ Disk.real dir ~master) in
  let b = random r (6 lsl 20) in
  let w0 = Vault.written v in
  let root1, _ = put v 5 b in
  let w1 = Vault.written v in
  let root2, _ = put ~r:(Rng.make 99) v 5 b in
  C.check (root1 = root2 && Vault.written v = w1) "the same file again: the same root, no record written (%d before)" (w1 - w0);
  let b' = Bytes.cat (Bytes.sub b 0 (3 lsl 20)) (Bytes.cat (Bytes.of_string "an insertion") (Bytes.sub b (3 lsl 20) (3 lsl 20))) in
  let root3, _ = put v 5 b' in
  let fresh = Vault.written v - w1 in
  C.check (root3 <> root1 && fresh <= 4 && whole v root3 = Ok b') "an edited copy: %d records written (the chunk around the edit and the nodes)" fresh;
  let root4, _ = put v 6 b in
  C.check (root4 <> root1 && Vault.written v - w1 - fresh > 60 && whole v root4 = Ok b) "another domain: another root, every chunk written again";
  Vault.close v;
  section "store: reopened, from the packs' indexes or, without them, from the packs";
  Vault.pack_limit := 1 lsl 20;
  let v = ok "open" (Vault.open_ Disk.real dir ~master) in
  let files = List.init 6 (fun i -> let b = (if i mod 2 = 0 then text else random) r (300_000 + Rng.int r 2_000_000) in b, fst (put ~r v 7 b)) in
  Vault.close v;
  let v = ok "reopen" (Vault.open_ Disk.real dir ~master) in
  C.check (List.for_all (fun (b, root) -> whole v root = Ok b) files) "after a reopen";
  Vault.close v;
  let idx = List.filter (fun f -> Filename.check_suffix f ".idx") (Array.to_list (Sys.readdir (Filename.concat dir "packs"))) in
  C.check (List.length idx > 5) "%d packs closed" (List.length idx);
  List.iter (fun f -> Sys.remove (Filename.concat (Filename.concat dir "packs") f)) idx;
  let v = ok "reopen" (Vault.open_ Disk.real dir ~master) in
  C.check (List.for_all (fun (b, root) -> whole v root = Ok b) files) "every index removed: the packs read again";
  C.check (match Vault.open_ Disk.real dir ~master with Error (Vault.Busy _) -> true | _ -> false) "a second open of the same vault: busy";
  Vault.close v;
  C.check (match Vault.open_ Disk.real dir ~master:(String.make 32 'x') with Error (Vault.Invalid _) -> true | _ -> false) "another master key: refused";
  Vault.pack_limit := 64 lsl 20;
  ignore (Sys.command ("rm -rf " ^ Filename.quote dir))


let () =
  section "store: a power loss at any point: every file finished before it reads back whole; the vault always opens";
  let total = ref 0 in
  for seed = 1 to 120 do
    let r = Rng.make seed in
    let sim = Sim_disk.create (Rng.make (1000 + seed)) in
    let disk = Sim_disk.disk sim in
    Vault.pack_limit := 300_000 + Rng.int r 600_000;
    let done_ = ref [] and erased = ref false in
    (* rounds: a crash at a random call, then a reopen that checks every file finished so far *)
    for round = 1 to 3 do
      (match Vault.open_ disk "/v" ~master with
       | Error e -> C.fail "seed %d round %d: the vault does not open after a crash: %s" seed round (Vault.message e)
       | Ok v ->
         List.iter
           (fun (b, root, _) -> if whole v root <> Ok b then C.fail "seed %d round %d: a file finished before the crash does not read back" seed round)
           !done_;
         total := !total + List.length !done_;
         Sim_disk.crash_after sim (Rng.int r 400);
         (try
            for _ = 1 to 6 do
              let n = match Rng.int r 3 with 0 -> Rng.int r 2000 | 1 -> Rng.int r 300_000 | _ -> Rng.int r 1_500_000 in
              let b = if Rng.int r 2 = 0 then text r n else random r n in
              (* half of the files share chunks with an earlier one *)
              let b = match !done_ with (p, _, _) :: _ when Rng.int r 2 = 0 -> Bytes.cat p b | _ -> b in
              let domain = Rng.int r (if !erased then 2 else 3) in
              let root, _ = put ~r ~cold:(Rng.int r 4 = 0) v domain b in
              done_ := (b, root, domain) :: !done_
            done;
            if Rng.int r 3 = 0 && not !erased then begin
              (* domain 2's files are not checked from now on: erased, or maybe (a crash in the middle) *)
              erased := true;
              done_ := List.filter (fun (_, _, d) -> d <> 2) !done_;
              ignore (Vault.erase v 2)
            end;
            Vault.close v
          with Sim_disk.Crash | Failure _ -> ()));
      Sim_disk.crash sim
    done
  done;
  Vault.pack_limit := 64 lsl 20;
  C.check (!total > 300) "%d files read back after crashes" !total

let () =
  section "store: puts from four threads at once share their fsyncs (group commit); a power loss at any moment: every file confirmed before it reads back";
  let total = ref 0 and finished = ref 0 and fsyncs = ref 0 in
  for seed = 1 to 40 do
    let r = Rng.make (500 + seed) in
    let sim = Sim_disk.create (Rng.make (2000 + seed)) in
    let base = Sim_disk.disk sim in
    (* the simulated disk shared by threads: one call at a time, a yield before each (the threads interleave); an
       fsync makes durable what was written before it, then lasts a while (others run meanwhile); after the power
       loss every call fails *)
    let m = Mutex.create () and dead = ref false in
    let g f = Thread.yield (); Mutex.protect m (fun () -> if !dead then raise Sim_disk.Crash; f ()) in
    let disk : Disk.t =
      { base with
        exists = (fun p -> g (fun () -> base.exists p));
        mkdir = (fun p -> g (fun () -> base.mkdir p));
        readdir = (fun p -> g (fun () -> base.readdir p));
        openf = (fun p c -> g (fun () -> base.openf p c));
        size = (fun fd -> g (fun () -> base.size fd));
        pread = (fun fd o b p n -> g (fun () -> base.pread fd o b p n));
        pwrite = (fun fd o b p n -> g (fun () -> base.pwrite fd o b p n));
        truncate = (fun fd n -> g (fun () -> base.truncate fd n));
        fsync = (fun fd -> g (fun () -> incr fsyncs; base.fsync fd); for _ = 1 to 3 do Thread.yield () done);
        close = (fun fd -> g (fun () -> base.close fd));
        rename = (fun a b -> g (fun () -> base.rename a b));
        remove = (fun p -> g (fun () -> base.remove p));
        sync_dir = (fun p -> g (fun () -> base.sync_dir p));
        lock = (fun p -> g (fun () -> base.lock p));
        unlock = (fun p -> g (fun () -> base.unlock p)) }
    in
    (* small packs: a pack is closed while another thread forces it *)
    Vault.pack_limit := 100_000 + Rng.int r 300_000;
    let v = ok "open" (Vault.open_ disk "/v" ~master) in
    let cm = Mutex.create () and cut = ref false and confirmed = ref [] in
    let threads =
      List.init 4 (fun k ->
          let tr = Rng.make ((seed * 10) + k) in
          Thread.create
            (fun () ->
              try
                for _ = 1 to 12 do
                  let n = match Rng.int tr 4 with 0 -> Rng.int tr 200_000 | _ -> Rng.int tr 20_000 in
                  let b = if Rng.int tr 2 = 0 then text tr n else random tr n in
                  let root, _ = put ~r:tr v (k mod 2) b in
                  Mutex.protect cm (fun () -> incr finished; if not !cut then confirmed := (b, root) :: !confirmed)
                done
              with _ -> ())
            ())
    in
    for _ = 1 to Rng.int r 400 do Thread.yield () done;
    (* the power loss: after it, no file is confirmed, and the disk takes no call *)
    Mutex.protect cm (fun () -> cut := true; Mutex.protect m (fun () -> dead := true; Sim_disk.crash sim));
    List.iter Thread.join threads;
    (match Vault.open_ base "/v" ~master with
     | Error e -> C.fail "seed %d: the vault does not open after the power loss: %s" seed (Vault.message e)
     | Ok v ->
       List.iter (fun (b, root) -> if whole v root <> Ok b then C.fail "seed %d: a file confirmed before the power loss does not read back" seed) !confirmed;
       total := !total + List.length !confirmed;
       Vault.close v)
  done;
  Vault.pack_limit := 64 lsl 20;
  C.check (!total > 100) "%d files confirmed before a power loss read back" !total;
  C.check (!fsyncs < !finished) "%d puts finished with %d fsyncs (shared)" !finished !fsyncs

let () =
  section "store: a process killed in the middle of a put, the vault opened again, the file put again, then a power loss: it reads back";
  for seed = 1 to 30 do
    let r = Rng.make (700 + seed) in
    let sim = Sim_disk.create (Rng.make (3000 + seed)) in
    let disk = Sim_disk.disk sim in
    let b = random r (6 lsl 20) in
    let v = ok "open" (Vault.open_ disk "/v" ~master) in
    let w = ok "writer" (Vault.writer v ~domain:1 ~cold:false) in
    (* the first 4 MiB of chunks appended, not forced; then the process dies, its pages kept *)
    ok "feed" (Vault.feed w b 0 (Bytes.length b));
    Sim_disk.kill sim;
    let v = ok "reopen" (Vault.open_ disk "/v" ~master) in
    let root, _ = put ~r v 1 b in
    let found = Vault.reused v in
    Vault.close v;
    Sim_disk.crash sim;
    let v = ok "open after the power loss" (Vault.open_ disk "/v" ~master) in
    if found = 0 || whole v root <> Ok b then C.fail "seed %d: a file put again after a kill does not read back after a power loss (%d chunks found)" seed found;
    Vault.close v
  done;
  C.check true "30 seeds: a file whose chunks were found in a pack scanned after a kill reads back after a power loss"

let pack_files dir = List.sort compare (List.filter (fun f -> Filename.check_suffix f ".pack") (Array.to_list (Sys.readdir (Filename.concat dir "packs"))))

let flip path off =
  let fd = Unix.openfile path [ Unix.O_RDWR ] 0 in
  let b = Bytes.create 1 in
  ignore (Unix.lseek fd off Unix.SEEK_SET);
  ignore (Unix.read fd b 0 1);
  Bytes.set b 0 (Char.chr (Char.code (Bytes.get b 0) lxor 0x10));
  ignore (Unix.lseek fd off Unix.SEEK_SET);
  ignore (Unix.write fd b 0 1);
  Unix.close fd

let () =
  section "damage: a changed byte, a record moved: an error, never a wrong byte; the same file put again repairs it";
  let dir = fresh "damage" in
  let r = Rng.make 31 in
  let v = ok "open" (Vault.open_ Disk.real dir ~master) in
  let b = random r (3 lsl 20) in
  let root, _ = put v 1 b in
  let first = Chunker.cut b 0 (Bytes.length b) in
  Vault.close v;
  let pack = Filename.concat (Filename.concat dir "packs") (List.hd (pack_files dir)) in
  (* the first record of the pack is the file's first chunk: a byte of its payload changed *)
  flip pack (16 + 64 + 1000);
  let v = ok "open" (Vault.open_ Disk.real dir ~master) in
  C.check (match whole v root with Error (Vault.Damaged _) -> true | _ -> false) "a changed byte of a chunk: damaged";
  C.check (get v root ~from:first ~len:(Bytes.length b - first) = Ok (Bytes.sub b first (Bytes.length b - first))) "the other chunks still read";
  C.check (match get v root ~from:10 ~len:10 with Error (Vault.Damaged _) -> true | _ -> false) "a range inside the damaged chunk: damaged";
  let w = Vault.written v in
  let root', _ = put v 1 b in
  C.check (root' = root && Vault.written v = w + 1 && whole v root = Ok b) "put again: the damaged chunk written anew, the file reads";
  Vault.close v;
  let v = ok "open" (Vault.open_ Disk.real dir ~master) in
  C.check (whole v root = Ok b) "repaired, after a reopen";
  Vault.close v;
  (* a header changed *)
  flip pack (16 + 20);
  let v = ok "open" (Vault.open_ Disk.real dir ~master) in
  C.check (whole v root = Ok b) "the old copy's header changed: the new copy is the one read";
  Vault.close v;
  ignore (Sys.command ("rm -rf " ^ Filename.quote dir));
  (* a record put where another was: the name it carries is not the one asked *)
  let dir = fresh "moved" in
  let v = ok "open" (Vault.open_ Disk.real dir ~master) in
  let b1 = random r 10_000 and b2 = random r 10_000 in
  let _r1, _ = put v 1 b1 in
  let r2, _ = put v 1 b2 in
  Vault.close v;
  let pack = Filename.concat (Filename.concat dir "packs") (List.hd (pack_files dir)) in
  let data = In_channel.with_open_bin pack In_channel.input_all in
  let len o = 64 + (Int32.to_int (String.get_int32_le data (o + 20)) land 0xFFFFFFFF) in
  (* chunk of b1, node of b1, chunk of b2 (raw, as long as b1's), node of b2 *)
  let c1 = 16 in
  let c2 = c1 + len c1 + len (c1 + len c1) in
  C.check (len c1 = len c2) "two chunks of the same length";
  let out = Bytes.of_string data in
  Bytes.blit_string data c1 out c2 (len c1);
  Out_channel.with_open_bin pack (fun oc -> Out_channel.output_bytes oc out);
  let v = ok "open" (Vault.open_ Disk.real dir ~master) in
  C.check (match whole v r2 with Error (Vault.Damaged m) -> String.length m > 0 | _ -> false) "a record moved over another: damaged";
  Vault.close v;
  ignore (Sys.command ("rm -rf " ^ Filename.quote dir))

let () =
  section "erase: a domain's key destroyed: its files unreadable, after a reopen too, its key gone from the file";
  let dir = fresh "erase" in
  let r = Rng.make 41 in
  let v = ok "open" (Vault.open_ Disk.real dir ~master) in
  let x = text r 500_000 and y = text r 500_000 in
  let rx, _ = put v 9 x in
  let ry, _ = put v 10 y in
  let entry9 = List.find (fun e -> Int64.to_int (String.get_int64_le e 8) = 9) (Vault.key_entries v) in
  (* read first: its chunks and nodes are in the caches, which the erasure must not serve *)
  C.check (whole v rx = Ok x && whole v rx = Ok x) "read twice (the second from the caches)";
  C.check (ok "erase" (Vault.erase v 9) = ()) "erased";
  C.check (Vault.load v rx ~from:0 ~len:10 (fun _ _ _ -> ()) = Error (Vault.Erased 9)) "its file: erased";
  C.check (whole v ry = Ok y) "another domain's file reads";
  C.check (match Vault.writer v ~domain:9 ~cold:false with Error (Vault.Erased 9) -> true | _ -> false) "no new file in an erased domain";
  Vault.close v;
  let v = ok "open" (Vault.open_ Disk.real dir ~master) in
  C.check (Vault.load v rx ~from:0 ~len:10 (fun _ _ _ -> ()) = Error (Vault.Erased 9)) "after a reopen: erased";
  C.check (whole v ry = Ok y) "after a reopen: the other reads";
  Vault.close v;
  let keys = In_channel.with_open_bin (Filename.concat dir "keys") In_channel.input_all in
  let contains s sub = let n = String.length sub in let rec go i = i + n <= String.length s && (String.sub s i n = sub || go (i + 1)) in go 0 in
  C.check (not (contains keys (String.sub entry9 16 96))) "the sealed key is not in the keys' file any more";
  ignore (Sys.command ("rm -rf " ^ Filename.quote dir))

let () =
  section "copies: the records a copy lacks, by Merkle comparison; copied as they are, the copy reads the files";
  let da = fresh "a" and db = fresh "b" in
  let r = Rng.make 51 in
  let a = ok "open a" (Vault.open_ Disk.real da ~master) and b = ok "open b" (Vault.open_ Disk.real db ~master) in
  let files = List.init 12 (fun i -> let x = (if i mod 2 = 0 then text else random) r (Rng.int r 3_000_000) in x, fst (put ~r a (i mod 3) x)) in
  let copy ~from ~into names =
    ok "keys" (Vault.take_keys into (Vault.key_entries from));
    List.iter (fun n -> ok "add" (Vault.add_raw into (ok "raw" (Vault.raw from n)))) names;
    ok "sync" (Vault.sync into)
  in
  let tree v = Merkle.of_names (List.to_seq (Vault.names v)) in
  let lacks ~from ~into = let ta = tree from and tb = tree into in Merkle.missing tb (Merkle.peer ta) ~peer_root:(Merkle.root ta) in
  let all, asked0 = lacks ~from:a ~into:b in
  C.check (List.length all = Vault.records a) "an empty copy lacks every record (%d), %d asked" (List.length all) asked0;
  copy ~from:a ~into:b all;
  C.check (Merkle.root (tree a) = Merkle.root (tree b)) "copied: the same root";
  C.check (List.for_all (fun (x, root) -> whole b root = Ok x) files) "the copy reads every file";
  (* more files on a: the copy lacks exactly their new records *)
  let before = Vault.names a in
  let more = List.init 3 (fun i -> let x = random r (Rng.int r 2_000_000) in x, fst (put ~r a i x)) in
  let fresh_names = List.filter (fun n -> not (List.mem n before)) (Vault.names a) in
  let got, asked = lacks ~from:a ~into:b in
  C.check (List.sort compare got = List.sort compare fresh_names) "it lacks exactly the %d new records" (List.length fresh_names);
  (* at most the 16 digests of 4 levels a record it lacks, and the names of their leaves *)
  C.check (asked <= 1 + (List.length fresh_names * (64 + 4))) "found by asking %d digests and names for %d records lacked, of %d" asked
    (List.length fresh_names) (Vault.records a);
  let none, _ = lacks ~from:b ~into:a in
  C.check (none = []) "the other way, nothing";
  copy ~from:a ~into:b got;
  C.check (List.for_all (fun (x, root) -> whole b root = Ok x) more && Merkle.root (tree a) = Merkle.root (tree b)) "copied: the same again";
  (* an erasure reaches the copy with the keys *)
  ok "erase" (Vault.erase a 1);
  ok "keys" (Vault.take_keys b (Vault.key_entries a));
  C.check (List.for_all (fun (_, root) -> match whole b root with Error (Vault.Erased 1) -> true | Ok _ -> true | _ -> false) files
           && List.exists (fun (_, root) -> whole b root = Error (Vault.Erased 1)) files) "erased on a, then on the copy";
  (* a damaged record is never copied *)
  C.check (match Vault.add_raw b (Bytes.make 200 'x') with Error (Vault.Damaged _) -> true | _ -> false) "a record that does not check is refused";
  Vault.close a;
  Vault.close b;
  ignore (Sys.command ("rm -rf " ^ Filename.quote da ^ " " ^ Filename.quote db))

let () =
  section "fuzz: records and nodes changed at random: the right bytes or an error, nothing else";
  let dir = fresh "fuzz" in
  let r = Rng.make 61 in
  let v = ok "open" (Vault.open_ Disk.real dir ~master) in
  let files = List.init 6 (fun i -> let x = (if i mod 2 = 0 then text else random) r (Rng.int r 1_500_000) in x, fst (put ~r ~cold:(i mod 3 = 0) v 1 x)) in
  ignore files;
  let names = Array.of_list (Vault.names v) in
  let cases = ref 0 and same = ref 0 in
  for i = 1 to 20_000 do
    let name = names.(Rng.int r (Array.length names)) in
    let rec0 = ok "raw" (Vault.raw v name) in
    let kind = Bytes.get_uint8 rec0 5 in
    let _, want = Vault.decode v rec0 0 (Bytes.length rec0) ~kind ~name in
    let m = Bytes.copy rec0 in
    let n =
      match Rng.int r 5 with
      | 0 -> let j = Rng.int r (Bytes.length m) in Bytes.set m j (Char.chr (Rng.int r 256)); Bytes.length m
      | 1 -> Rng.int r (Bytes.length m)
      | 2 ->
        (* a field changed, its CRCs made again: the tag must refuse it *)
        let j = 4 + Rng.int r 60 in
        Bytes.set m j (Char.chr (Rng.int r 256));
        Bytes.set_int32_le m 24 (Int32.of_int (Crc32c.bytes m 64 (max 0 (min (Bytes.length m - 64) (Int32.to_int (Bytes.get_int32_le m 20) land 0xFFFFF)))));
        Bytes.set_int32_le m 0 (Int32.of_int (Crc32c.bytes m 4 60));
        Bytes.length m
      | 3 -> let j = 64 + Rng.int r (Bytes.length m - 64) in Bytes.set m j (Char.chr (Char.code (Bytes.get m j) lxor (1 lsl Rng.int r 8))); Bytes.length m
      | _ -> Bytes.blit (random r 64) 0 m 0 64; Bytes.length m
    in
    incr cases;
    match Vault.decode v m 0 n ~kind ~name with
    | _, got -> if Bytes.equal got want then incr same else C.fail "case %d: a changed record decoded to other bytes" i
    | exception Vault.Fail _ -> ()
    | exception e -> C.fail "case %d: %s" i (Printexc.to_string e)
  done;
  C.check true "%d records changed: %d read the same (an unused byte changed), the others refused" !cases !same;
  (* the node parser alone, on nodes changed at random (their tag is checked before it: this is for our own mistakes) *)
  let nodes = List.filter (fun n -> match Vault.raw v n with Ok r -> Bytes.get_uint8 r 5 = 2 | _ -> false) (Array.to_list names) in
  let plains = List.map (fun n -> let rc = ok "raw" (Vault.raw v n) in snd (Vault.decode v rc 0 (Bytes.length rc) ~kind:2 ~name:n)) nodes in
  let pa = Array.of_list plains in
  for i = 1 to 20_000 do
    let p = Bytes.copy pa.(Rng.int r (Array.length pa)) in
    let p =
      match Rng.int r 3 with
      | 0 -> let j = Rng.int r (Bytes.length p) in Bytes.set p j (Char.chr (Rng.int r 256)); p
      | 1 -> Bytes.sub p 0 (Rng.int r (Bytes.length p))
      | _ -> random r (Rng.int r 200)
    in
    match Vault.parse_node (String.make 32 'n') p with
    | (n : Vault.node) ->
      let c = Array.length n.ends in
      let rec inc k = k >= c || (n.ends.(k) > (if k = 0 then 0 else n.ends.(k - 1)) && inc (k + 1)) in
      if not (c <= Vault.fanout && String.length n.names = 32 * c && inc 0) then C.fail "node case %d: a node that breaks its rules" i
    | exception Vault.Fail (Vault.Damaged _) -> ()
    | exception e -> C.fail "node case %d: %s" i (Printexc.to_string e)
  done;
  C.check true "20,000 nodes changed: parsed within their rules or refused";
  Vault.close v;
  ignore (Sys.command ("rm -rf " ^ Filename.quote dir))

let () = C.finish "vault"
