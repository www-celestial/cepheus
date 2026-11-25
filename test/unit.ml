(* Unit and property tests. Properties run on random inputs from fixed seeds; each failure names its seed. *)

open Cepheus
module C = Check

let section name = Printf.printf "- %s\n%!" name

(* ---- checksums and codecs ---- *)

(* The oracle: CRC-32C by tables in OCaml (slicing by 8, the engine's code before the processor's instruction),
   written from the polynomial alone. *)
module Crc_oracle = struct
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

  let step8 c lo hi =
    let lo = lo lxor c in
    t.((7 * 256) + (lo land 0xff))
    lxor t.((6 * 256) + ((lo lsr 8) land 0xff))
    lxor t.((5 * 256) + ((lo lsr 16) land 0xff))
    lxor t.((4 * 256) + ((lo lsr 24) land 0xff))
    lxor t.((3 * 256) + (hi land 0xff))
    lxor t.((2 * 256) + ((hi lsr 8) land 0xff))
    lxor t.(256 + ((hi lsr 16) land 0xff))
    lxor t.((hi lsr 24) land 0xff)

  let extend crc (b : Bytes.t) off len =
    let c = ref (crc lxor 0xFFFFFFFF) and i = ref off in
    let stop = off + len in
    while !i + 8 <= stop do
      let lo = Int32.to_int (Bytes.get_int32_le b !i) land 0xFFFFFFFF in
      let hi = Int32.to_int (Bytes.get_int32_le b (!i + 4)) land 0xFFFFFFFF in
      c := step8 !c lo hi;
      i := !i + 8
    done;
    while !i < stop do
      c := t.((!c lxor Char.code (Bytes.get b !i)) land 0xff) lxor (!c lsr 8);
      incr i
    done;
    !c lxor 0xFFFFFFFF
end

let () =
  section "crc32c";
  C.check (Crc32c.string "123456789" = 0xE3069283) "crc32c of 123456789";
  C.check (Crc32c.string "" = 0) "crc32c of nothing";
  (* RFC 3720 (iSCSI), appendix B.4, which prints each CRC as four bytes: read little-endian, they are these numbers *)
  let vector name b crc = C.check (Crc32c.bytes b 0 (Bytes.length b) = crc) "RFC 3720 B.4, %s" name in
  vector "32 bytes of zeros" (Bytes.make 32 '\x00') 0x8A9136AA;
  vector "32 bytes of 0xff" (Bytes.make 32 '\xff') 0x62A8AB43;
  vector "32 bytes rising" (Bytes.init 32 Char.chr) 0x46DD794E;
  vector "32 bytes falling" (Bytes.init 32 (fun i -> Char.chr (31 - i))) 0x113FDB5C;
  vector "a SCSI Read (10) command PDU"
    (Bytes.of_string
       "\x01\xc0\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x14\x00\x00\x00\x00\x00\x04\x00\
        \x00\x00\x00\x14\x00\x00\x00\x18\x28\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00")
    0xD9963A56;
  (* the processor's CRC against the oracle: every length up to 72 at every offset up to 15 (the 8-byte steps and
     the tail), then random lengths up to 1 MiB, the pieces of 1 MiB around their edges, random offsets, and [extend]
     over random cuts in two and three *)
  let r = Rng.make 11 in
  let piece = 1 lsl 20 in
  let size = (3 * piece) + 64 in
  let buf = Bytes.init size (fun _ -> Char.chr (Rng.int r 256)) in
  let same off len =
    let want = Crc_oracle.extend 0 buf off len in
    C.check (Crc32c.bytes buf off len = want) "crc32c of %d bytes at %d" len off;
    let k = Rng.int r (len + 1) in
    let m = k + Rng.int r (len - k + 1) in
    let two = Crc32c.extend (Crc32c.bytes buf off k) buf (off + k) (len - k) in
    let three = Crc32c.extend (Crc32c.extend (Crc32c.bytes buf off k) buf (off + k) (m - k)) buf (off + m) (len - m) in
    C.check (two = want && three = want) "crc32c of %d bytes at %d cut at %d and %d" len off k m
  in
  for len = 0 to 72 do
    for off = 0 to 15 do same off len done
  done;
  List.iter (fun len -> same (Rng.int r (size - len + 1)) len)
    [ piece - 1; piece; piece + 1; (2 * piece) - 7; 2 * piece; (2 * piece) + 13; 3 * piece; size ];
  for _ = 1 to 5000 do
    let len =
      match Rng.int r 4 with
      | 0 -> Rng.int r 65
      | 1 -> Rng.int r 4097
      | _ -> min piece (int_of_float (2. ** (20. *. float (Rng.int r 1_000_001) /. 1e6)))
    in
    same (Rng.int r (size - len + 1)) len
  done;
  (* the bounds, checked before the processor reads anything *)
  let refused off len = match Crc32c.bytes buf off len with _ -> false | exception Invalid_argument _ -> true in
  List.iter
    (fun (off, len) -> C.check (refused off len) "crc32c refuses %d bytes at %d" len off)
    [ (-1, 1); (0, -1); (0, size + 1); (size, 1); (1, max_int); (max_int, 1); (min_int, 0) ];
  C.check (Crc32c.bytes buf size 0 = 0) "crc32c of nothing at the end"

let () =
  section "codec and values";
  let r = Rng.make 2 in
  let ints = [ 0; 1; -1; 63; 64; -64; -65; max_int; min_int; 1 lsl 40; -(1 lsl 40) ] @ List.init 500 (fun _ -> Rng.next r) in
  List.iter
    (fun n ->
      let b = Buffer.create 16 in
      Codec.put_int b n;
      let rd = Codec.reader (Buffer.to_bytes b) 0 (Buffer.length b) in
      C.check (Codec.get_int rd = n && Codec.at_end rd) "zigzag round trip %d" n)
    ints;
  let values =
    [ Value.Int min_int; Int max_int; Float nan; Float (-0.0); Float 1e300; Bool true; Bool false; Text ""; Text "Ada";
      Date (-5); Money 12345; Link 70000 ]
  in
  let g = { Group.n = 7; time = 1700000000000; by = -3; why = "test"; first_new = 65536; count_new = 2;
            changes = Array.of_list (List.mapi (fun i v -> { Group.kind = (match i mod 6 with 0 -> Retracted | 1 -> Added | 2 -> Derived | 3 -> Underived | 4 -> Now_asserted | _ -> Now_derived); e = 65536 + i; p = 16 + i; v }) values) } in
  let b = Buffer.create 64 in
  Group.encode b g;
  let rd = Codec.reader (Buffer.to_bytes b) 0 (Buffer.length b) in
  C.check (Group.equal (Group.decode rd) g && Codec.at_end rd) "group round trip";
  (* a cut group never decodes as another one *)
  let bytes = Buffer.to_bytes b in
  for cut = 0 to Bytes.length bytes - 1 do
    match Group.decode (Codec.reader bytes 0 cut) with
    | _ -> C.fail "a group cut at %d decoded" cut
    | exception Codec.Short -> incr C.checks
  done

let () =
  section "latency histograms: counters made at the first value, by one of two domains at once";
  let h = Histogram.create () and e = Histogram.create () in
  C.check (Histogram.percentile h 0.5 = 0 && Histogram.total h = 0) "an empty histogram";
  Histogram.merge_into h e;
  C.check (Histogram.percentile h 1.0 = 0 && Histogram.total h = 0) "an empty one merged into an empty one";
  List.iter (Histogram.record e) [ 5; 300; 70000 ];
  Histogram.merge_into h e;
  C.check (Histogram.total h = 3 && Histogram.percentile h 0.0 = 5 && Histogram.percentile h 0.5 = 301
           && Histogram.percentile h 1.0 = 70000) "a full one merged into an empty one";
  (* a lost array would leave a value counted in the total and in no counter: the walk would run past the end *)
  for _ = 1 to 100 do
    let h = Histogram.create () and go = Atomic.make false in
    let d = Domain.spawn (fun () -> while not (Atomic.get go) do Domain.cpu_relax () done; Histogram.record h 7) in
    Atomic.set go true;
    Histogram.record h 9;
    Domain.join d;
    match Histogram.percentile h 1.0 with
    | p -> C.check (p = 7 || p = 9) "two first values at once: the top one %d" p
    | exception Invalid_argument _ -> C.fail "two first values at once: a value counted in no counter"
  done

(* ---- bit packing, and the journal's coding of groups in columns ---- *)

let () =
  section "bit packing: fields of every width, against a bit-by-bit reference";
  let r = Rng.make 21 in
  for round = 1 to 300 do
    let n = 1 + Rng.int r 300 in
    let ws = Array.init n (fun _ -> Rng.int r 64) in
    let xs = Array.init n (fun i -> let w = ws.(i) in if w = 0 then 0 else Rng.next r land Pack.mask w) in
    let bits = Array.fold_left ( + ) 0 ws in
    (* sometimes no room after the last field: the reads and writes near the end take the byte-by-byte path *)
    let b = Bytes.make (((bits + 7) / 8) + (if round mod 2 = 0 then 0 else 8)) '\000' in
    let at = ref 0 in
    Array.iteri (fun i w -> Pack.put b !at xs.(i) w; at := !at + w) ws;
    let bit k = (Char.code (Bytes.get b (k / 8)) lsr (k mod 8)) land 1 in
    let at = ref 0 and ok = ref true in
    Array.iteri
      (fun i w ->
        let x = ref 0 in
        for k = w - 1 downto 0 do x := (!x lsl 1) lor bit (!at + k) done;
        if !x <> xs.(i) || Pack.get b !at w <> xs.(i) then ok := false;
        at := !at + w)
      ws;
    C.check !ok "round %d: a packed field reads back otherwise" round
  done;
  List.iter (fun (x, w) -> C.check (Pack.width x = w) "width %d" x) [ 0, 0; 1, 1; 2, 2; 255, 8; 256, 9; max_int, 62; -1, 63; min_int, 63 ];
  (* the coder as the format describes it, plainly (three passes, a field at a time): Pack.put_ints writes its bytes *)
  let put_ints_ref out n f =
    let s = Bytes.create ((Pack.block * 8) + 8) and v = Array.make Pack.block 0 and i = ref 0 in
    while !i < n do
      let len = min Pack.block (n - !i) in
      for k = 0 to len - 1 do v.(k) <- f (!i + k) done;
      let lo = ref v.(0) and hi = ref v.(0) in
      for k = 1 to len - 1 do lo := min !lo v.(k); hi := max !hi v.(k) done;
      let wr = Pack.width (!hi - !lo) in
      let dlo = ref 0 and dhi = ref 0 in
      if len > 1 then begin
        dlo := v.(1) - v.(0); dhi := !dlo;
        for k = 2 to len - 1 do let d = v.(k) - v.(k - 1) in dlo := min !dlo d; dhi := max !dhi d done
      end;
      let wd = Pack.width (!dhi - !dlo) in
      let raw = Pack.zlen !lo + Pack.bytes len wr and delta = Pack.zlen v.(0) + Pack.zlen !dlo + Pack.bytes (len - 1) wd in
      if len > 1 && delta < raw then begin
        Buffer.add_char out (Char.chr (0x80 lor wd)); Codec.put_int out v.(0); Codec.put_int out !dlo;
        let nb = Pack.bytes (len - 1) wd in
        Bytes.fill s 0 (nb + 8) '\000';
        for k = 1 to len - 1 do Pack.put s ((k - 1) * wd) (v.(k) - v.(k - 1) - !dlo) wd done;
        Buffer.add_subbytes out s 0 nb
      end
      else begin
        Buffer.add_char out (Char.chr wr); Codec.put_int out !lo;
        let nb = Pack.bytes len wr in
        Bytes.fill s 0 (nb + 8) '\000';
        for k = 0 to len - 1 do Pack.put s (k * wr) (v.(k) - !lo) wr done;
        Buffer.add_subbytes out s 0 nb
      end;
      i := !i + len
    done
  in
  (* columns: every block mode, extreme values, lengths around 128, widths of 0 to 63 bits *)
  for round = 1 to 600 do
    let n = Rng.int r 400 in
    let gen = match round mod 6 with
      | 0 -> (fun _ -> Rng.next r)
      | 1 -> (let b = Rng.next r in fun i -> b + (3 * i) + Rng.int r 3)
      | 2 -> (fun i -> if i mod 7 = 0 then max_int else if i mod 7 = 1 then min_int else Rng.int r 10)
      | 3 -> (let c = Rng.next r in fun _ -> c)
      | 4 -> (fun i -> -i * 1000)
      | _ -> (let w = Rng.int r 64 in let b = Rng.next r in fun _ -> b + (Rng.next r land Pack.mask w))
    in
    let gen = if round mod 2 = 0 then gen else (fun i -> if round mod 4 = 1 then gen i else (gen i) asr (Rng.int r 63)) in
    let a = Array.init n gen in
    let refb = Buffer.create 64 in
    put_ints_ref refb n (Array.get a);
    let buf = Buffer.create 64 in
    Pack.put_ints buf n (Array.get a);
    C.check (Buffer.contents buf = Buffer.contents refb) "round %d: the coder writes the format's bytes (%d ints)" round n;
    Buffer.add_string buf "tail";
    let bytes = Buffer.to_bytes buf in
    let rd = Codec.reader bytes 0 (Bytes.length bytes) in
    let out = Array.make n 0 in
    Pack.get_ints rd n out 0;
    C.check (out = a && Codec.get_byte rd = Char.code 't') "round %d: a column of %d ints reads back otherwise" round n
  done

(* the coding of journal format 1, as the engine wrote it before format 2: what Journal.convert reads *)
let encode_v1 b (g : Group.t) =
  Codec.put_varint b g.n;
  Codec.put_int b g.time;
  Codec.put_int b g.by;
  Codec.put_string b g.why;
  Codec.put_varint b g.first_new;
  Codec.put_varint b g.count_new;
  Codec.put_varint b (Array.length g.changes);
  Array.iter
    (fun (f : Group.change) ->
      Buffer.add_char b (Char.unsafe_chr (Group.code f.kind));
      Codec.put_varint b f.e;
      Codec.put_varint b f.p;
      Value.encode b f.v)
    g.changes

let random_group r n =
  let kinds = [| Group.Retracted; Added; Derived; Underived; Now_asserted; Now_derived |] in
  let props = Array.init (1 + Rng.int r 6) (fun _ -> 16 + Rng.int r 40) in
  let texts = Array.init (1 + Rng.int r 5) (fun i -> if i = 0 then "" else String.init (Rng.int r 30) (fun _ -> Char.chr (Rng.int r 256))) in
  let value p : Value.t =
    match (p + Rng.int r 2) mod 8 with
    | 0 -> Int (if Rng.int r 4 = 0 then Rng.next r else Rng.int r 100)
    | 1 -> Float (match Rng.int r 4 with 0 -> nan | 1 -> -0.0 | 2 -> infinity | _ -> Int64.float_of_bits (Int64.of_int (Rng.next r)))
    | 2 -> Bool (Rng.int r 2 = 0)
    | 3 -> Text texts.(Rng.int r (Array.length texts))
    | 4 -> Date (Rng.int r 3650 - 100)
    | 5 -> Money (if Rng.int r 8 = 0 then min_int else Rng.int r 1_000_000)
    | _ -> Link (65536 + Rng.int r 1_000_000)
  in
  let e0 = 65536 + Rng.int r 100_000 in
  let changes =
    Array.init (match Rng.int r 4 with 0 -> 0 | 1 -> 1 + Rng.int r 3 | 2 -> 120 + Rng.int r 20 | _ -> Rng.int r 600)
      (fun i ->
        let p = props.(Rng.int r (Array.length props)) in
        { Group.kind = kinds.(Rng.int r 6); e = (if Rng.int r 3 = 0 then Rng.int r 1_000_000 else e0 + (i / 4)); p; v = value p })
  in
  (* a fact twice, as a group that adds then retracts it holds *)
  let changes = if Array.length changes > 2 then Array.append changes [| changes.(0) |] else changes in
  { Group.n; time = Rng.next r; by = Rng.int r 1000 - 500; why = String.make (Rng.int r 3) 'w'; first_new = 65536 + Rng.int r 1000;
    count_new = Rng.int r 50; changes }

let () =
  section "groups in columns: random groups read back, cut ones never read";
  let r = Rng.make 22 in
  for seed = 1 to 400 do
    let g = random_group r seed in
    let b = Buffer.create 64 in
    Group.encode b g;
    let bytes = Buffer.to_bytes b in
    let rd = Codec.reader bytes 0 (Bytes.length bytes) in
    C.check (match Group.decode rd with g' -> Group.equal g g' && Codec.at_end rd | exception Codec.Short -> false)
      "seed %d: a group of %d changes reads back otherwise" seed (Array.length g.changes);
    (* the same group in format 1 *)
    let b1 = Buffer.create 64 in
    encode_v1 b1 g;
    let rd1 = Codec.reader (Buffer.to_bytes b1) 0 (Buffer.length b1) in
    C.check (Group.equal g (Group.decode_v1 rd1)) "seed %d: format 1 reads back otherwise" seed;
    if seed mod 20 = 0 then
      for cut = 0 to Bytes.length bytes - 1 do
        match Group.decode (Codec.reader bytes 0 cut) with
        | _ -> C.fail "seed %d: a group cut at %d decoded" seed cut
        | exception Codec.Short -> incr C.checks
      done
  done

(* encode_parts: a group's records then changes read by index (a change's derived facts in its run of their own),
   each Derived, of every type, the texts and floats by word; on one domain and, past 65,536 changes, on several:
   the bytes of Group.encode of the group with all of them as records *)
let () =
  section "groups in columns: records then changes read by index, on one domain or several, the bytes of the whole group";
  let r = Rng.make 23 in
  let typs = [| Value.Tint; Tfloat; Tbool; Ttext; Tdate; Tmoney 2; Tlink |] in
  for seed = 1 to 40 do
    let g = random_group r seed in
    let n = match seed mod 4 with 0 -> 0 | 1 -> 1 + Rng.int r 300 | 2 -> 70_000 + Rng.int r 3_000 | _ -> Rng.int r 2_000 in
    (* the extra changes' properties, a type each (some the records' properties too), their texts by word *)
    let props = Array.init (1 + Rng.int r 5) (fun _ -> 16 + Rng.int r 50) in
    let ptyp = Hashtbl.create 8 in
    Array.iter (fun p -> if not (Hashtbl.mem ptyp p) then Hashtbl.replace ptyp p typs.(Rng.int r (Array.length typs))) props;
    let words = Array.init 50 (fun i -> if i mod 2 = 0 then String.init (Rng.int r 12) (fun _ -> Char.chr (Rng.int r 256)) else (let b = Bytes.create 8 in Bytes.set_int64_le b 0 (Int64.of_int (Rng.next r)); Bytes.to_string b)) in
    let ep = Array.init n (fun _ -> props.(Rng.int r (Array.length props))) in
    let ee = let e = ref (65536 + Rng.int r 1000) in Array.init n (fun _ -> e := !e + Rng.int r 3; !e) in
    let ew = Array.init n (fun i -> match Hashtbl.find ptyp ep.(i) with
      | Value.Tbool -> Rng.int r 2 | Ttext -> 2 * Rng.int r 25 | Tfloat -> 1 + (2 * Rng.int r 25) | _ -> Rng.int r 1_000_000) in
    let value p w : Value.t =
      match Hashtbl.find ptyp p with
      | Value.Tint -> Int w | Tdate -> Date w | Tmoney _ -> Money w | Tlink -> Link w | Tbool -> Bool (w <> 0)
      | Ttext -> Text words.(w) | Tfloat -> Float (Int64.float_of_bits (String.get_int64_le words.(w) 0))
    in
    let whole = { g with changes = Array.append g.changes (Array.init n (fun i -> { Group.kind = Derived; e = ee.(i); p = ep.(i); v = value ep.(i) ew.(i) })) } in
    let want = Buffer.create 64 in
    Group.encode want whole;
    let parts ?parallel () =
      let b = Buffer.create 64 in
      Group.encode_parts ?parallel b g ~n ~thing:(Array.get ee) ~prop:(Array.get ep) ~tag:(fun p -> Group.tag_of_typ (Hashtbl.find ptyp p))
        ~word:(Array.get ew) ~text:(Array.get words);
      Buffer.contents b
    in
    C.check (parts () = Buffer.contents want) "seed %d: %d records and %d changes by index, one domain: the whole group's bytes" seed (Array.length g.changes) n;
    C.check (parts ~parallel:(fun k f -> Bulk.parallel k f) () = Buffer.contents want) "seed %d: on several domains: the same bytes" seed;
    let rd = Codec.reader (Buffer.to_bytes want) 0 (Buffer.length want) in
    C.check (Group.equal (Group.decode rd) whole) "seed %d: they decode to the whole group" seed
  done

(* ---- the reference semantics of a write, written independently of Resolve ---- *)

type model = { mutable facts : C.F.t; mutable next : int }

let model_write (m : model) (v : view) ops =
  let schema p = Option.get (describe v p) in
  let temps = Hashtbl.create 4 and next = ref m.next in
  let see x = if x < 0 && not (Hashtbl.mem temps x) then (Hashtbl.replace temps x !next; incr next) in
  List.iter
    (function
      | Add (e, _, x) | Retract (e, _, x) -> see e; (match x with Link t -> see t | _ -> ())
      | Expect _ | Delete _ -> ()
      | Incr (e, _, _, into) -> see e; Option.iter (fun (t, _) -> see t) into)
    ops;
  let id x = if x < 0 then Hashtbl.find temps x else x in
  let fix = function Link t -> Link (id t) | x -> x in
  let has f e p = C.F.exists (fun (e', p', _) -> e' = e && p' = p) f in
  try
    List.iter
      (function
        | Expect (e, _, _) when e < 0 -> raise Exit
        | Expect (e, p, None) -> if has m.facts e p then raise Exit
        | Expect (e, p, Some x) -> if not (C.F.mem (e, p, x) m.facts) then raise Exit
        | _ -> ())
      ops;
    let f = ref m.facts and added = ref [] in
    let add e p x =
      let d = schema p in
      if e < Schema.first_thing || e >= !next || not (Value.has_type d.typ x) then raise Exit;
      (match x with Link t -> if t < Schema.first_prop || t >= !next then raise Exit | _ -> ());
      if not d.many then f := C.F.filter (fun (e', p', _) -> not (e' = e && p' = p)) !f;
      f := C.F.add (e, p, x) !f;
      added := (e, p, x) :: !added
    in
    List.iter
      (function
        | Add (e, p, x) -> add (id e) p (fix x)
        | Incr (e, p, by, into) ->
          (* the counter's value now (none: 0) plus by, in the 63 bits; into an int property *)
          let e = id e and d = schema p in
          if d.many || d.typ <> Tint then raise Exit;
          let old = C.F.fold (fun (e', p', x) n -> match x with Int k when e' = e && p' = p -> k | _ -> n) !f 0 in
          let n = old + by in
          if (by > 0 && n < old) || (by < 0 && n > old) then raise Exit;
          add e p (Int n);
          Option.iter (fun (t, q) -> if (schema q).typ <> Tint then raise Exit; add (id t) q (Int n)) into
        | Retract (e, p, x) ->
          let e = id e and x = fix x in
          let d = schema p in
          if e < Schema.first_thing || e >= !next || not (Value.has_type d.typ x) then raise Exit;
          f := C.F.remove (e, p, x) !f
        | Expect _ -> ()
        | Delete _ -> invalid_arg "the model writes no Delete")
      ops;
    List.iter
      (fun (e, p, x) ->
        if (schema p).unique && C.F.mem (e, p, x) !f && C.F.exists (fun (e', p', x') -> e' <> e && p' = p && Value.equal x x') !f then raise Exit)
      !added;
    m.facts <- !f;
    m.next <- !next;
    true
  with Exit -> false

let props =
  [ prop "name" Ttext; prop ~many:true "tag" Ttext; prop "score" Tint; prop ~unique:true "mail" Ttext;
    prop ~many:true "friend" Tlink; prop "boss" Tlink; prop "w" Tfloat; prop ~unique:true "seq" Tint ]

let random_ops r (v : view) ids =
  let p n = Option.get (property v n) in
  let things = v.next_e - Schema.first_thing in
  let some () = if things = 0 || Rng.int r 10 = 0 then -1 - Rng.int r 2 else Schema.first_thing + Rng.int r (things + 1) in
  let small = [| "a"; "b"; "c" |] in
  ignore ids;
  List.init (1 + Rng.int r 4) (fun _ ->
      match Rng.int r 16 with
      | 12 -> Incr (some (), p "score", Rng.int r 5 - 2, None)
      | 13 -> Incr (some (), p "score", 1, Some (some (), p (if Rng.bool r then "seq" else "score")))
      (* refused: a many-valued counter, a text one, into a text *)
      | 14 -> (match Rng.int r 3 with 0 -> Incr (some (), p "tag", 1, None) | 1 -> Incr (some (), p "name", 1, None) | _ -> Incr (some (), p "score", 1, Some (some (), p "name")))
      (* near the ends of the ints *)
      | 15 -> Incr (some (), p "score", (if Rng.bool r then max_int - Rng.int r 3 else min_int + Rng.int r 3), None)
      | 0 -> Add (some (), p "name", Text (Rng.pick r small))
      | 1 -> Add (some (), p "tag", Text (Rng.pick r small))
      | 2 -> Retract (some (), p "tag", Text (Rng.pick r small))
      | 3 -> Add (some (), p "score", Int (Rng.int r 3))
      | 4 -> Add (some (), p "mail", Text (Rng.pick r small))
      | 5 -> Add (some (), p "friend", Link (some ()))
      | 6 -> Add (some (), p "boss", Link (some ()))
      | 7 -> Expect (some (), p "score", Some (Int (Rng.int r 3)))
      | 8 -> Expect (some (), p "mail", None)
      | 9 -> Add (some (), p "w", Float (float_of_int (Rng.int r 3)))
      | 10 -> Add (some (), p "score", Text "x")
      | _ -> Retract (some (), p "boss", Link (some ())))

let fresh () =
  let f = fork empty in
  ignore (Result.get_ok (declare f props));
  f

let () =
  section "writes against the reference semantics";
  for seed = 1 to 300 do
    let r = Rng.make (1000 + seed) in
    let f = fresh () in
    let m = { facts = C.facts_of_view (view f); next = (view f).next_e } in
    for _ = 1 to 40 do
      let v = view f in
      let ops = random_ops r v () in
      let want = model_write m v ops in
      let got = write f ops in
      C.check (Result.is_ok got = want) "seed %d: write accepted %b, the model says %b (%s)" seed (Result.is_ok got) want
        (match got with Error e -> message e | Ok _ -> "");
      if Result.is_ok got <> want then m.facts <- C.facts_of_view (view f);
      let facts = C.facts_of_view (view f) in
      if not (C.F.equal facts m.facts) then (C.fail "seed %d: facts differ: %s" seed (C.show_diff facts m.facts); m.facts <- facts);
      m.next <- (view f).next_e
    done
  done

(* ---- Incr: one counter, many groups at once (gap 33: invoice numbers without a gap) ----
   Batches of 50 groups resolved together by the writer, as 50 programs' writes at once are: each group takes the
   counter's value at its point and adds one, into its own new invoice; a group refused for another reason (an Expect,
   a wrong type) leaves the counter as it was. Then a power loss: the journal gives back the same numbers, and the
   counting goes on from there. *)
let () =
  try
  section "Incr: groups that count with one counter at once, a crash, the ends of the ints, what it refuses";
  let sim = Sim_disk.create (Rng.make 33) in
  let disk = Sim_disk.disk sim in
  let opened () = Result.get_ok (Engine.open_ ~id_source:(fun _ -> "0123456789abcdef") disk "/incr") in
  let e = ref (opened ()) in
  let batch reqs = let b = Engine.prepare !e (Array.of_list (List.map (fun ops -> ops, 0, "w") reqs)) in Engine.commit !e b in
  let one ops = (batch [ ops ]).(0) in
  let ids, ops = Result.get_ok (Resolve.declare !e.working
    [ prop "next" Tint; prop ~unique:true "number" Tint; prop "label" Ttext; prop ~many:true "tags" Tint; prop "f" Tfloat ]) in
  ignore (Result.get_ok (one ops));
  let[@warning "-8"] [ next; number; label; tags; f ] = ids in
  let c = List.assoc (-1) (Result.get_ok (one [ Add (-1, label, Text "invoices") ])).things in
  let counter () = values !e.working c next in
  (* 4 batches of 50; in each, every 7th group refused by an Expect, every 11th by a wrong type after its Incr *)
  let got = Hashtbl.create 256 and refused = ref 0 and total = ref 0 in
  for b = 0 to 3 do
    let reqs =
      List.init 50 (fun i ->
          let k = (b * 50) + i in
          [ Incr (c, next, 1, Some (-1, number)); Add (-1, label, Text (Printf.sprintf "invoice %d" k)) ]
          @ (if k mod 7 = 3 then [ Expect (c, label, Some (Text "no")) ] else [])
          @ if k mod 11 = 5 then [ Add (-1, f, Text "not a float") ] else [])
    in
    Array.iteri
      (fun i r ->
        let k = (b * 50) + i in
        match r with
        | Ok (rc : Engine.receipt) ->
          incr total;
          let inv = List.assoc (-1) rc.things in
          (match values !e.working inv number with
           | [ Int n ] -> Hashtbl.replace got inv n; C.check (n = !total) "incr: group %d took %d, the %d-th accepted" k n !total
           | _ -> C.fail "incr: invoice %d has no number" inv)
        | Error _ -> incr refused; C.check (k mod 7 = 3 || k mod 11 = 5) "incr: group %d refused" k)
      (batch reqs)
  done;
  let numbers = List.sort compare (Hashtbl.fold (fun _ n l -> n :: l) got []) in
  C.check (numbers = List.init !total (fun i -> i + 1)) "incr: %d groups accepted, numbered 1 to %d, no gap, no double (%d refused)" !total !total !refused;
  C.check (counter () = [ Int !total ]) "incr: the counter is %d" !total;
  (* two Incr in one group read each other: the second sees the first *)
  let rc = Result.get_ok (one [ Incr (c, next, 1, Some (-1, number)); Incr (c, next, 1, Some (-2, number)) ]) in
  let num t = values !e.working (List.assoc t rc.things) number in
  C.check (num (-1) = [ Int (!total + 1) ] && num (-2) = [ Int (!total + 2) ]) "incr: two in one group take %d and %d" (!total + 1) (!total + 2);
  total := !total + 2;
  (* the journal keeps what Incr did, an Add's retraction and addition: the replay after a power loss gives the same *)
  let before = C.facts_of_view !e.working in
  Sim_disk.crash sim;
  e := opened ();
  C.check (C.F.equal (C.facts_of_view !e.working) before) "incr: after a power loss, the same %d invoices and numbers" !total;
  let rc = Result.get_ok (one [ Incr (c, next, 1, Some (-1, number)) ]) in
  C.check (values !e.working (List.assoc (-1) rc.things) number = [ Int (!total + 1) ]) "incr: after the crash, the next is %d" (!total + 1);
  (* the ends of the ints: the last value is given, one more refuses the group, which leaves it *)
  let big = List.assoc (-1) (Result.get_ok (one [ Add (-1, next, Int (max_int - 1)) ])).things in
  C.check (Result.is_ok (one [ Incr (big, next, 1, None) ])) "incr: to the largest int";
  C.check (match one [ Incr (big, next, 1, None) ] with Error (Invalid _) -> true | _ -> false) "incr: past the largest int, refused";
  C.check (match one [ Incr (-1, next, min_int, None); Incr (-1, next, -1, None) ] with Error (Invalid _) -> true | _ -> false) "incr: past the smallest, refused";
  C.check (values !e.working big next = [ Int max_int ]) "incr: a refused group leaves the counter";
  (* what it refuses: a counter of many values, of another type, a system property; into another type or a system
     property; a thing that does not exist *)
  let refused ops = match one ops with Error (Invalid _) -> true | _ -> false in
  C.check (refused [ Incr (c, tags, 1, None) ]) "incr: a many-valued counter is refused";
  C.check (refused [ Incr (c, label, 1, None) ]) "incr: a text counter is refused";
  C.check (refused [ Incr (c, f, 1, None) ]) "incr: a float counter is refused";
  C.check (refused [ Incr (next, Schema.p_type, 1, None) ]) "incr: a system property is refused";
  C.check (refused [ Incr (c, next, 1, Some (-1, label)) ]) "incr: into a text is refused";
  C.check (refused [ Incr (c, next, 1, Some (next, Schema.p_type)) ]) "incr: into a system property is refused";
  C.check (refused [ Incr (!e.working.next_e + 5, next, 1, None) ]) "incr: a thing that does not exist is refused";
  C.check (refused [ Incr (c, 60_000, 1, None) ]) "incr: a property that does not exist is refused";
  C.check (counter () = [ Int (!total + 1) ]) "incr: the refusals left the counter at %d" (!total + 1);
  (* into a many-valued int property: added beside the others *)
  C.check (Result.is_ok (one [ Incr (c, next, 1, Some (c, tags)) ]) && values !e.working c tags = [ Int (!total + 2) ]) "incr: into a many-valued int";
  (* a fork answers as the database (G8) *)
  let fk = fork !e.working in
  let r = write fk [ Incr (c, next, 10, Some (-1, number)) ] in
  C.check (match r with Ok r -> values (view fk) (thing r (-1)) number = [ Int (!total + 12) ] | Error _ -> false) "incr: a fork counts as the database";
  C.check (values !e.working c next = [ Int (!total + 2) ]) "incr: and the database does not change";
  Engine.close !e
  with ex -> C.fail "incr: %s" (Printexc.to_string ex)


(* ---- questions against the naive evaluator ---- *)

let qnames = [ "name"; "tag"; "score"; "friend"; "boss"; "mail" ]

let () =
  section "questions against the naive evaluator (half of them split over 3 domains)";
  Query.domains := 3;
  for seed = 1 to 300 do
    Query.parallel_min := (if seed mod 2 = 0 then 1 else 20_000);
    let r = Rng.make (5000 + seed) in
    let f = fresh () in
    for _ = 1 to 30 do ignore (write f (random_ops r (view f) ())) done;
    if seed mod 3 = 0 then begin
      (* the same questions on a compacted base and on a base plus delta *)
      let v = C.compact (view f) in
      for _ = 1 to 10 do ignore (Store.facts v) done
    end;
    let v = view f in
    let facts = C.facts_of_view v in
    for _ = 1 to 15 do
      match C.random_query r v facts qnames with
      | None -> ()
      | Some q -> (
        match C.work_and_bound v facts q (fun () -> find v q) with
        | Error e, _, _ -> C.fail "seed %d: %s" seed (message e)
        | Ok rows, work, bound ->
          let want = C.naive facts q in
          let got = C.sorted_rows rows in
          C.check (List.length got = List.length (List.sort_uniq compare got)) "seed %d: a binding came twice" seed;
          C.check (got = want) "seed %d: %d rows, the naive evaluator gives %d" seed (List.length got) (List.length want);
          C.check (work <= bound) "seed %d: Generic Join enumerated %d candidates, its bound is %d" seed work bound)
    done
  done

let () =
  section "compaction keeps every fact";
  for seed = 1 to 100 do
    let r = Rng.make (9000 + seed) in
    let f = fresh () in
    for _ = 1 to 40 do ignore (write f (random_ops r (view f) ())) done;
    let v = view f in
    let c = C.compact v in
    C.check (C.F.equal (C.facts_of_view v) (C.facts_of_view c)) "seed %d: compaction changed the facts" seed;
    (* and the compacted base answers the same questions *)
    let facts = C.facts_of_view c in
    for _ = 1 to 5 do
      match C.random_query r c facts qnames with
      | Some q ->
        let rows, work, bound = C.work_and_bound c facts q (fun () -> Result.get_ok (find c q)) in
        C.check (C.sorted_rows rows = C.naive facts q) "seed %d: compacted questions" seed;
        C.check (work <= bound) "seed %d: compacted: %d candidates, bound %d" seed work bound
      | None -> ()
    done
  done

let () =
  section "several runs: a delta on runs that add and retract, the same facts and answers as one run";
  Query.domains := 3;
  let most = ref 0 in
  for seed = 1 to 120 do
    Query.parallel_min := (if seed mod 2 = 0 then 1 else 20_000);
    let r = Rng.make (9500 + seed) in
    let f = fresh () in
    (* rounds of writes, each ended by a merge of the delta alone, of the delta and the newest run, or of all *)
    let v = C.layered r (view f) (2 + Rng.int r 4) (fun g -> for _ = 1 to 15 do ignore (write g (random_ops r (view g) ())) done; view g) in
    most := max !most (Array.length v.runs);
    let facts = C.facts_of_view v in
    let one = C.compact v in
    C.check (C.F.equal facts (C.facts_of_view one)) "seed %d: the runs and their full merge differ" seed;
    C.check (Store.facts v = C.F.cardinal facts) "seed %d: the count of facts across runs" seed;
    for _ = 1 to 10 do
      match C.random_query r v facts qnames with
      | None -> ()
      | Some q -> (
        match C.work_and_bound v facts q (fun () -> find v q) with
        | Error e, _, _ -> C.fail "seed %d: %s" seed (message e)
        | Ok rows, work, bound ->
          C.check (C.sorted_rows rows = C.naive facts q) "seed %d: a question across runs" seed;
          C.check (work <= bound) "seed %d: across runs, %d candidates, bound %d" seed work bound)
    done
  done;
  Printf.printf "  up to %d runs\n" !most

(* ---- large groups ---- *)

let () =
  section "large groups: the orders by thing and by property, against a sort";
  let chunk = !Bulk.chunk in
  for seed = 1 to 300 do
    let r = Rng.make (10500 + seed) in
    Bulk.chunk := 1 + Rng.int r 50;
    let n = Rng.int r 400 and np = 1 + Rng.int r 6 in
    (* facts in thing order (as a loader writes them), or not *)
    let sorted_in = Rng.bool r in
    let facts = Array.init n (fun _ -> 65536 + Rng.int r (1 + Rng.int r 300), Rng.int r np,
                                    match Rng.int r 12 with 0 -> max_int - Rng.int r 3 | 1 -> min_int + Rng.int r 3 | 2 -> -Rng.int r (1 lsl 40) | _ -> Rng.int r 50) in
    if sorted_in then Array.sort compare facts;
    let e = Bulk.i32 n and p = Bulk.u16 n and w = Bulk.ints n in
    Array.iteri (fun i (a, b, c) -> e.{i} <- Int32.of_int a; p.{i} <- b; w.{i} <- c) facts;
    let by_thing = List.stable_sort (fun i j -> compare facts.(i) facts.(j)) (List.init n Fun.id) in
    let sorted = Bulk.in_order e p w n in
    C.check (sorted = (List.init n Fun.id = by_thing)) "seed %d: in order is %b" seed sorted;
    let order = if sorted then Bulk.i32 0 else Bulk.by_thing e p w n in
    let b = Bulk.make ~sorted ~order e p w n ~np in
    C.check (List.init n (Bulk.row b) = by_thing) "seed %d: the order by thing" seed;
    let want = List.stable_sort (fun i j -> let a, q, x = facts.(i) and a', q', x' = facts.(j) in compare (q, x, a) (q', x', a')) by_thing in
    let got = ref [] in
    for q = np - 1 downto 0 do
      for k = b.poff.(q + 1) - 1 downto b.poff.(q) do got := (Bulk.pthing b k, q, Bulk.pword b k) :: !got done
    done;
    C.check (!got = List.map (fun i -> let a, q, x = facts.(i) in a, q, x) want) "seed %d: the order by property" seed
  done;
  Bulk.chunk := chunk

let () =
  section "large groups: derived facts merged into a group's orders (Bulk.add_derived), against a sort";
  let chunk = !Bulk.chunk in
  for seed = 1 to 300 do
    let r = Rng.make (10800 + seed) in
    Bulk.chunk := 1 + Rng.int r 50;
    let np = 1 + Rng.int r 6 in
    (* distinct facts, split into the group's and the derived ones *)
    let all = Array.of_list (List.sort_uniq compare (List.init (Rng.int r 600) (fun _ -> 65536 + Rng.int r (1 + Rng.int r 300), Rng.int r np,
                                                                                   match Rng.int r 10 with 0 -> max_int - Rng.int r 3 | 1 -> -Rng.int r (1 lsl 40) | _ -> Rng.int r 50))) in
    for i = Array.length all - 1 downto 1 do let j = Rng.int r (i + 1) in let t = all.(i) in all.(i) <- all.(j); all.(j) <- t done;
    let n = Array.length all in
    let na = if n = 0 then 0 else Rng.int r (n + 1) in
    let nd = n - na in
    let arrays lo k = let e = Bulk.i32 k and p = Bulk.u16 k and w = Bulk.ints k in
      for i = 0 to k - 1 do let a, b, c = all.(lo + i) in e.{i} <- Int32.of_int a; p.{i} <- b; w.{i} <- c done; e, p, w in
    let e, p, w = arrays 0 na in
    if Rng.bool r then begin
      (* the group in thing order now and then *)
      let s = Array.sub all 0 na in
      Array.sort compare s;
      Array.blit s 0 all 0 na;
      Array.iteri (fun i (a, b, c) -> e.{i} <- Int32.of_int a; p.{i} <- b; w.{i} <- c) s
    end;
    let sorted = Bulk.in_order e p w na in
    let order = if sorted then Bulk.i32 0 else Bulk.by_thing e p w na in
    let b = Bulk.make ~sorted ~order e p w na ~np in
    let de, dp, dw = arrays na nd in
    let b = Bulk.add_derived b de dp dw nd ~np in
    C.check (b.n = n && b.d0 = (if nd = 0 then n else na)) "seed %d: counts" seed;
    C.check (List.init n (fun i -> Bulk.thing b i, Bulk.prop b i, Bulk.word b i) = Array.to_list all) "seed %d: the group's order, then the derived" seed;
    let want = List.sort compare (Array.to_list all) in
    C.check (List.init n (fun k -> let i = Bulk.row b k in Bulk.thing b i, Bulk.prop b i, Bulk.word b i) = want) "seed %d: the order by thing" seed;
    let derived = Hashtbl.create 16 in
    for i = na to n - 1 do Hashtbl.replace derived all.(i) () done;
    let got = ref [] in
    for q = np - 1 downto 0 do
      for k = b.poff.(q + 1) - 1 downto b.poff.(q) do
        let f = (Bulk.pthing b k, q, Bulk.pword b k) in
        C.check (Bulk.pderived b k = Hashtbl.mem derived f) "seed %d: the derived bit by property" seed;
        got := f :: !got
      done
    done;
    C.check (!got = List.sort (fun (a, q, x) (a', q', x') -> compare (q, x, a) (q', x', a')) want) "seed %d: the order by property" seed
  done;
  Bulk.chunk := chunk

let () =
  section "large groups: the faster path gives what Resolve gives, or leaves the group to it";
  let large = !Resolve.large_min and chunk = !Bulk.chunk in
  Resolve.large_min := 1;
  let fast = ref 0 and slow = ref 0 and unsorted = ref 0 and fars = ref 0 in
  for seed = 1 to 200 do
    let r = Rng.make (11000 + seed) in
    (* chunks of a few operations, so that a group spans many, mapped by several domains *)
    Bulk.chunk := 1 + Rng.int r 9;
    let f = fresh () in
    (* half the seeds: links that name a kind, which the faster path checks or leaves to Resolve *)
    if seed mod 2 = 0 then begin
      let q n = Option.get (property (view f) n) in
      ignore (Result.get_ok (link_to f [ q "boss", "name", Refuse; q "friend", "name", Cascade ]))
    end;
    let v = C.layered r (view f) (1 + Rng.int r 3) (fun g -> for _ = 1 to 10 do ignore (write g (random_ops r (view g) ())) done; view g) in
    let p n = Option.get (property v n) in
    let things = v.next_e - Schema.first_thing in
    let old () = Schema.first_thing + Rng.int r (max 1 things) in
    let small = [| "a"; "b"; "c"; "d" |] in
    (* new things by temporary ids near -1 and, now and then, far below the group's length *)
    let far = Rng.int r 3 = 0 in
    let tmp k = if far && k mod 3 = 1 then -(k + 1) - 1_000_000_000 else -(k + 1) in
    (* many new things with their facts, links between them and to old things, many-valued facts on old things,
       and now and then what the faster path must leave to Resolve: a second value, a taken mail, a bad type *)
    let ops =
      List.concat
        (List.init (5 + Rng.int r 40) (fun k ->
             let t = tmp k in
             [ Add (t, p "name", Text ("n" ^ Rng.pick r small)); Add (t, p "score", Int (Rng.int r 4)) ]
             @ (if Rng.int r 3 = 0 then [ Add (t, p "tag", Text (Rng.pick r small)); Add (t, p "tag", Text (Rng.pick r small)) ] else [])
             @ (if k > 0 && Rng.bool r then [ Add (t, p "friend", Link (tmp (Rng.int r k))) ] else [])
             @ (if things > 0 && Rng.int r 3 = 0 then [ Add (old (), p "tag", Text (Rng.pick r small)) ] else [])
             @ (if things > 0 && Rng.int r 4 = 0 then [ Add (t, p "boss", Link (old ())) ] else [])
             @ (if Rng.int r 30 = 0 then [ Add (t, p "score", Int 9) ] else [])
             @ (if Rng.int r 30 = 0 then [ Add (t, p "mail", Text (Rng.pick r small ^ "@x")) ] else [])
             @ (if Rng.int r 60 = 0 then [ Add (t, p "score", Text "x") ] else [])
             @ (if Rng.int r 60 = 0 && things > 0 then [ Add (old (), p "name", Text "z") ] else [])))
    in
    (* and now and then in no order at all, or in the order of the things and properties, as a loader writes *)
    let key = function
      | Add (e, q, _) | Retract (e, q, _) | Expect (e, q, _) | Incr (e, q, _, _) ->
        (if e >= 0 then e else if e < -1_000_000_000 then v.next_e - e - 1_000_000_001 else v.next_e - e - 1), q
      | Delete (e, _) -> e, 0
    in
    let ops = match Rng.int r 4 with
      | 0 -> List.map snd (List.sort compare (List.map (fun o -> Rng.int r 1_000_000, o) ops))
      | 1 -> List.stable_sort (fun a b -> compare (key a) (key b)) ops
      | _ -> ops
    in
    let n = v.group + 1 in
    let slow_r = Resolve.resolve v ~n ~time:5 ~by:1 ~why:"w" ops in
    match Resolve.resolve_large v ~n ~time:5 ~by:1 ~why:"w" ops, slow_r with
    | None, _ -> incr slow
    | Some _, Error e -> C.fail "seed %d: the faster path took a group Resolve refuses: %s" seed (Resolve.error_message e)
    | Some l, Ok (v', g, temps) ->
      incr fast;
      if not l.facts.sorted then incr unsorted;
      if List.exists (fun (t, _) -> t < -1_000_000) temps then incr fars;
      let b1 = Resolve.encode_large l and b2 = Buffer.create 64 in
      Group.encode b2 g;
      C.check (Buffer.contents b1 = Buffer.contents b2) "seed %d: the group is not encoded as Resolve's" seed;
      C.check (Resolve.receipt l = temps) "seed %d: the new things are numbered otherwise" seed;
      C.check (l.view.next_e = v'.next_e) "seed %d: the next thing differs" seed;
      let want = C.facts_of_view v' in
      (* the facts merged as a run, as the writer does; and replayed from the journal's form *)
      let d = Lazy.force C.merge_disk in
      let take = Rng.int r (Array.length v.runs + 1) in
      let w = Snapshot.merge ~bulk:l.facts d "/merge" "0123456789abcdef" l.view ~take ~level:(1 + take)
          { Journal.segment = 1; offset = 40; next = n } in
      C.check (C.F.equal want (C.facts_of_view w.view)) "seed %d: the merged large group differs from Resolve's state" seed;
      (match Resolve.replay_large v g with
       | Some (rv, facts) ->
         let w = Snapshot.merge ~bulk:facts d "/merge" "0123456789abcdef" rv ~take:(Array.length v.runs) ~level:1
             { Journal.segment = 1; offset = 40; next = n } in
         C.check (C.F.equal want (C.facts_of_view w.view)) "seed %d: the large group replayed differs" seed
       | None -> C.fail "seed %d: the group could not be replayed by the faster path" seed)
  done;
  Printf.printf "  %d large groups by the faster path (%d out of thing order, %d with far ids), %d left to Resolve\n" !fast
    !unsorted !fars !slow;
  C.check (!unsorted > 0 && !unsorted < !fast && !fars > 0) "the faster path never took a group in thing order, or out of it, or with far ids";
  Resolve.large_min := large;
  Bulk.chunk := chunk

(* ---- snapshots ---- *)

let () =
  section "snapshots: round trip, and damage set aside";
  for seed = 1 to 60 do
    let r = Rng.make (12000 + seed) in
    let sim = Sim_disk.create (Rng.split r) in
    let disk = Sim_disk.disk sim in
    disk.mkdir "/s";
    let f = fresh () in
    for _ = 1 to 30 do ignore (write f (random_ops r (view f) ())) done;
    let pos = { Journal.segment = 1; offset = 40; next = (view f).group + 1 } in
    let w = Snapshot.merge disk "/s" "0123456789abcdef" (view f) ~take:0 ~level:1 pos in
    Snapshot.install disk "/s" w;
    let v = w.view in
    (match Snapshot.load disk "/s" "0123456789abcdef" with
     | Some (v', _), [] ->
       C.check (C.F.equal (C.facts_of_view v) (C.facts_of_view v')) "seed %d: snapshot round trip" seed;
       C.check (v'.next_e = v.next_e && v'.group = v.group) "seed %d: snapshot counters" seed
     | _ -> C.fail "seed %d: snapshot did not load" seed);
    (match Snapshot.load disk "/s" "another database" with
     | None, [ _ ] -> incr C.checks
     | _ -> C.fail "seed %d: a snapshot of another database was taken" seed);
    let file = "/s/" ^ Snapshot.name 0 v.group in
    (* a run of an earlier format (7: no column order) is set aside, its groups to be replayed from the journal *)
    if seed = 1 then begin
      let fd = disk.openf file true in
      let b = Bytes.create 4 in
      disk.pread fd 4 b 0 4;
      let fmt = Bytes.get_int32_le b 0 in
      Bytes.set_int32_le b 0 7l;
      disk.pwrite fd 4 b 0 4;
      (match Snapshot.load disk "/s" "0123456789abcdef" with
       | None, [ note ] -> C.check (let k = String.length "an earlier format (7)" in let rec at i = i + k <= String.length note && (String.sub note i k = "an earlier format (7)" || at (i + 1)) in at 0) "a run of format 7: %s" note
       | _ -> C.fail "a run of format 7 was taken");
      Bytes.set_int32_le b 0 fmt;
      disk.pwrite fd 4 b 0 4;
      disk.close fd
    end;
    ignore (Sim_disk.flip_durable sim file 0 (Sim_disk.durable_size sim file));
    match Snapshot.load disk "/s" "0123456789abcdef" with
    | None, [ _ ] -> incr C.checks
    | Some (v', _), _ ->
      (* the flip can only go unseen if it hit padding no check covers: then the facts must be intact *)
      C.check (C.F.equal (C.facts_of_view v) (C.facts_of_view v')) "seed %d: a damaged snapshot was served" seed
    | _ -> C.fail "seed %d: unexpected snapshot load" seed
  done

(* a run of 600 pages and more on the real disk: its pages read and checked at open by several domains, each with
   its own descriptor; a damaged page sets it aside *)
let () =
  section "a large run on the disk: its pages checked at open by several domains, damage set aside";
  let dir = C.tmpdir "bigopen" in
  let disk = Disk.real in
  disk.mkdir dir;
  let f = fresh () in
  let p n = Option.get (property (view f) n) in
  let r = Rng.make 77 in
  for g = 0 to 39 do
    ignore
      (Result.get_ok
         (write f
            (List.init 2500 (fun k ->
                 Add (-1 - k, p "name", Text (Printf.sprintf "%d-%d-%s" g k (String.init 90 (fun _ -> Char.chr (97 + Rng.int r 26)))))))))
  done;
  let pos = { Journal.segment = 1; offset = 40; next = (view f).group + 1 } in
  let w = Snapshot.merge disk dir "0123456789abcdef" (view f) ~take:0 ~level:1 pos in
  Snapshot.install disk dir w;
  let file = Filename.concat dir (Snapshot.name 0 w.view.group) in
  let pages = Snapshot.file_pages disk file in
  C.check (pages >= 512) "a large run: %d pages (the parallel check starts at 512)" pages;
  (match Snapshot.load disk dir "0123456789abcdef" with
   | Some (v', _), [] -> C.check (C.F.equal (C.facts_of_view w.view) (C.facts_of_view v')) "a large run: its facts after an open"
   | _ -> C.fail "a large run did not load");
  (* one byte of a page in the second half flipped: the domain that reads it finds it *)
  let fd = disk.openf file true in
  let b = Bytes.create 1 in
  let at = Snapshot.header + ((pages * 3 / 4) * Pages.size) + 100 in
  disk.pread fd at b 0 1;
  Bytes.set b 0 (Char.chr (Char.code (Bytes.get b 0) lxor 0x10));
  disk.pwrite fd at b 0 1;
  disk.close fd;
  (match Snapshot.load disk dir "0123456789abcdef" with
   | None, [ _ ] -> incr C.checks
   | _ -> C.fail "a large run with a damaged page was taken");
  C.rmrf dir

(* ---- a base larger than the cache ---- *)

(* A random question on the paged base's 6,000 things may be a cross product (two parts that share no variable) or a
   join on a value of three (things that share a tag): tens of millions of rows, the memory of the machine; and the
   naive evaluator reads every fact again (24,000) for each binding of its patterns taken in their written order, so
   its partial bindings, not the answer's rows, make its time. The engine counts them: the question cut after its
   first k patterns, k = 1 .. all, has as many answers as the naive evaluator has bindings at its k-th pattern. A draw
   whose counts pass 20,000 candidates in all is left out (None, as a draw that does not type); a page that cannot be
   read is left to [find], which answers it. *)
let paged_query r v facts =
  match C.random_query r v facts qnames with
  | None -> None
  | Some (q : Query.t) as some -> (
    let left = ref 20_000 in
    let count where =
      let w = ref 0 in
      Query.fold ~seq:true ~budget:!left v { q with where; ranges = [] } ~init:(fun () -> ()) ~step:(fun () _ -> incr w) ~merge:(fun () () -> ());
      left := !left - max 1 !w
    in
    let prefixes = List.init (List.length q.where) (fun k -> List.filteri (fun i _ -> i <= k) q.where) in
    match List.iter count prefixes with
    | () -> if !left > 0 then some else None
    | exception Pages.Unreadable _ -> some
    | exception _ -> None)

let () =
  section "a base larger than the cache: pages read and checked as needed, by several domains; damage after open";
  let cap = !Pages.capacity in
  Query.domains := 3;
  let id = "0123456789abcdef" in
  let at_open = ref 0 and at_read = ref 0 and failed_questions = ref 0 in
  for seed = 1 to 12 do
    Pages.set_capacity (16 * Pages.size);
    Query.parallel_min := (if seed mod 2 = 0 then 1 else 20_000);
    let r = Rng.make (15000 + seed) in
    let sim = Sim_disk.create (Rng.split r) in
    let disk = Sim_disk.disk sim in
    disk.mkdir "/s";
    let f = fresh () in
    let p n = Option.get (property (view f) n) in
    let small = [| "a"; "b"; "c" |] in
    let made = Array.make 6000 0 in
    for k = 0 to 5999 do
      let friend = if k = 0 then [] else [ Add (-1, p "friend", Link made.(Rng.int r k)) ] in
      (* long names: the run is many times the cache (16 pages) although compressed, its texts read by questions *)
      let name = Text (Printf.sprintf "n%d-%d-%s" k (Rng.int r 1000) (String.init 60 (fun _ -> Char.chr (97 + Rng.int r 26)))) in
      let ops = Add (-1, p "name", name) :: Add (-1, p "score", Int (Rng.int r 5)) :: Add (-1, p "tag", Text small.(k mod 3)) :: friend in
      made.(k) <- thing (Result.get_ok (write f ops)) (-1)
    done;
    let w = Snapshot.merge disk "/s" id (view f) ~take:0 ~level:1 { Journal.segment = 1; offset = 40; next = (view f).group + 1 } in
    Snapshot.install disk "/s" w;
    let v = w.view in
    let b = v.runs.(0).a in
    let npages = Pages.count b.pg in
    let facts0 = C.facts_of_view v in
    let file = "/s/" ^ Snapshot.name 0 v.group in
    let fpages = Snapshot.file_pages disk file in
    let m0 = Atomic.get Pages.misses in
    (match Snapshot.load disk "/s" id with
     | Some (pv, _), [] ->
       C.check (fpages > 2 * !Pages.capacity) "seed %d: the base (%d pages) is not larger than the cache" seed fpages;
       C.check (C.F.equal (C.facts_of_view v) (C.facts_of_view pv)) "seed %d: the paged base lost facts" seed;
       (* a delta on top of the paged base, and questions split over domains while pages come and go *)
       let pf = fork pv in
       for _ = 1 to 30 do ignore (write pf (random_ops r (view pf) ())) done;
       let pv = view pf in
       let facts = C.facts_of_view pv in
       for _ = 1 to 15 do
         match paged_query r pv facts with
         | None -> ()
         | Some q -> (
           match find pv q with
           | Ok rows -> C.check (C.sorted_rows rows = C.naive facts q) "seed %d: a question on the paged base" seed
           | Error e -> C.fail "seed %d: %s" seed (message e))
       done;
       C.check (Atomic.get Pages.misses - m0 > fpages) "seed %d: no page was read twice (%d reads, %d pages)" seed
         (Atomic.get Pages.misses - m0) fpages;
       (* the base dropped from the cache (as a merge does to the base it replaced): read again from the file *)
       Pages.drop pv.runs.(0).a.pg;
       let q = paged_query r pv facts in
       Option.iter (fun q -> match find pv q with
           | Ok rows -> C.check (C.sorted_rows rows = C.naive facts q) "seed %d: a question after the drop" seed
           | Error e -> C.fail "seed %d: after the drop: %s" seed (message e)) q
     | _ -> C.fail "seed %d: the snapshot did not load" seed);
    (* a bit flipped on the disk; open again with the small cache: refused at open, or every read of the page fails,
       never a wrong answer *)
    (* even seeds: any page; odd seeds: a page of the by-property rows, which the open does not read *)
    let k =
      if seed mod 2 = 0 then Rng.int r (Snapshot.file_pages disk file)
      else begin
        (* interior pages of the rows by property only: the first shares bytes with their directory, read at open *)
        let ks = List.filter_map (fun k -> if k * Pages.size > b.o_vdata && (k + 1) * Pages.size <= b.o_vrank then Snapshot.file_page disk file k else None)
            (List.init npages Fun.id) in
        List.nth ks (Rng.int r (List.length ks))
      end
    in
    ignore (Sim_disk.flip_durable sim file (Snapshot.header + (k * Pages.size)) (Snapshot.header + ((k + 1) * Pages.size)));
    match Snapshot.load disk "/s" id with
    | None, [ _ ] -> C.check (seed mod 2 = 0) "seed %d: refused at open, for a page the open does not read" seed; incr at_open
    | Some (pv, _), _ ->
      let facts = facts0 in
      for _ = 1 to 15 do
        match paged_query r pv facts with
        | None -> ()
        | Some q -> (
          match find pv q with
          | Ok rows -> C.check (C.sorted_rows rows = C.naive facts q) "seed %d: a damaged base answered wrong" seed
          | Error (Damaged _) -> incr C.checks; incr failed_questions
          | Error e -> C.fail "seed %d: %s" seed (message e))
      done;
      let seen = ref 0 in
      for j = 0 to npages - 1 do try ignore (Pages.page pv.runs.(0).a.pg j) with Pages.Unreadable _ -> incr seen done;
      at_read := !at_read + !seen;
      (* the damaged page is seen unless it was read at the open (then refused there) or is the padding no read covers *)
      C.check (!seen = 1) "seed %d: %d pages fail, one was damaged" seed !seen
    | _ -> C.fail "seed %d: unexpected load" seed
  done;
  Printf.printf "  12 flipped bits: %d refused at open, %d found at a read (%d questions failed, none answered wrong)\n"
    !at_open !at_read !failed_questions;
  Pages.capacity := cap

(* ---- a merge holds the cache and a few pages ---- *)

let () =
  section "a merge of a base 8 times the cache: a few pages open, never more resident than the cache, every fact kept";
  let cap = !Pages.capacity in
  let id = "0123456789abcdef" in
  for seed = 1 to 4 do
    Pages.set_capacity (16 * Pages.size);
    let r = Rng.make (17000 + seed) in
    let disk = Sim_disk.disk (Sim_disk.create (Rng.split r)) in
    disk.mkdir "/s";
    let f = fresh () in
    let p n = Option.get (property (view f) n) in
    for k = 0 to 119_999 do
      ignore (write f [ Add (-1, p "name", Text (Printf.sprintf "n%d-%d" k (Rng.int r 100000))); Add (-1, p "score", Int (Rng.int r 50));
                        Add (-1, p "tag", Text (string_of_int (k mod 7))) ])
    done;
    let pos v = { Journal.segment = 1; offset = 40; next = (v : view).group + 1 } in
    let w1 = Snapshot.merge disk "/s" id (view f) ~take:0 ~level:1 (pos (view f)) in
    Snapshot.install disk "/s" w1;
    (* a delta on the paged base: changes, retractions, new things (written with a larger cache: each write reads a
       few pages, and with 16 the test would spend its time reading them again) *)
    let g = fork w1.view in
    Pages.set_capacity (4096 * Pages.size);
    for _ = 1 to 200 do ignore (write g (random_ops r (view g) ())) done;
    Pages.set_capacity (16 * Pages.size);
    let v = view g in
    Snapshot.open_max := 0;
    let w2 = Snapshot.merge disk "/s" id v ~take:1 ~level:1 (pos v) in
    Snapshot.install disk "/s" w2;
    let np = Snapshot.file_pages disk ("/s/" ^ Snapshot.name 0 w2.group) in
    C.check (np > 8 * !Pages.capacity) "seed %d: the base (%d pages) is not 8 times the cache" seed np;
    (* a page under each stream of the pass by property (9 sections a part, two parts) and the pages they share *)
    C.check (!Snapshot.open_max <= 24) "seed %d: %d pages open at once in a merge" seed !Snapshot.open_max;
    C.check (!Pages.resident <= !Pages.capacity) "seed %d: %d pages resident, the cache holds %d" seed !Pages.resident !Pages.capacity;
    C.check (C.F.equal (C.facts_of_view v) (C.facts_of_view w2.view)) "seed %d: the merge changed the facts" seed;
    (* and the file reads back as it was written *)
    match Snapshot.load disk "/s" id with
    | Some (lv, _), [] -> C.check (C.F.equal (C.facts_of_view v) (C.facts_of_view lv)) "seed %d: the merged file reads back" seed
    | _ -> C.fail "seed %d: the merged file did not load" seed
  done;
  Printf.printf "  at most %d pages open in a merge\n" !Snapshot.open_max;
  Pages.capacity := cap

(* ---- forks and databases on the real disk ---- *)

let () =
  section "forks change nothing, and accept what the database accepts";
  let dir = C.tmpdir "unit" in
  let db = Result.get_ok (open_ dir) in
  ignore (Result.get_ok (declare db props));
  let r = Rng.make 77 in
  for _ = 1 to 20 do ignore (write db (random_ops r (view db) ())) done;
  let v = view db in
  let journal () = List.map (fun f -> f, In_channel.with_open_bin (Filename.concat (dir ^ "/journal") f) In_channel.input_all) (Array.to_list (Sys.readdir (dir ^ "/journal"))) in
  let before = journal () and facts = C.facts_of_view v in
  let f = fork v in
  let r1 = Rng.make 78 and r2 = Rng.make 78 in
  let f2 = fork v in
  for _ = 1 to 30 do
    let a = write f (random_ops r1 (view f) ()) in
    let b = write f2 (random_ops r2 (view f2) ()) in
    C.check (Result.is_ok a = Result.is_ok b) "two forks given the same writes agree"
  done;
  C.check (C.F.equal (C.facts_of_view (view f)) (C.facts_of_view (view f2))) "two forks end equal";
  C.check (C.F.equal facts (C.facts_of_view (view db))) "the database is unchanged by its forks";
  C.check (before = journal ()) "the journal files are unchanged by forks";
  (* the database accepts and refuses what a fork of the same view does *)
  let f3 = fork (view db) in
  let r3 = Rng.make 79 and r4 = Rng.make 79 in
  for _ = 1 to 30 do
    let a = write f3 (random_ops r3 (view f3) ()) in
    let b = write db (random_ops r4 (view db) ()) in
    C.check (Result.is_ok a = Result.is_ok b) "database and fork agree on a write"
  done;
  C.check (C.F.equal (C.facts_of_view (view f3)) (C.facts_of_view (view db))) "database and fork end equal";
  (match open_ dir with
   | Error (Busy _) -> incr C.checks
   | Ok d -> close d; C.fail "a database opened twice (G9)"
   | Error e -> C.fail "second open: %s" (message e));
  close db;
  let db = Result.get_ok (open_ dir) in
  C.check (C.F.equal (C.facts_of_view (view db)) (C.facts_of_view (view f3))) "reopened database equals the fork that mirrored it";
  let last = (view db).group in
  close db;
  (* every group of the journal, as many as the writes accepted (the random writes refuse some) *)
  (match verify dir with Ok n -> C.check (n = last && n > 10) "verify reads %d groups, the journal's %d" n last | Error e -> C.fail "verify: %s" (message e));
  C.rmrf dir

(* A run a merge replaced is closed, and its disk space freed, once no view reads it. The cache's FIFOs held a base's
   entries after Pages.drop took its pages out, until the cache was full: each entry held the base, the base the
   function that reads its file, and the finaliser that closes the file never ran (39 removed runs open after 40
   merges, 60 MB of disk held). Here a view taken before each merge reads the replaced run after it, so its pages
   enter the FIFOs again, as a question that runs across a merge does. *)
let () =
  section "a run replaced by a merge is closed once no view reads it";
  let dir = C.tmpdir "replaced" in
  let removed_open () =
    let n = ref 0 in
    Array.iter
      (fun fd ->
        match Unix.readlink ("/proc/self/fd/" ^ fd) with
        | l when String.starts_with ~prefix:dir l && Filename.check_suffix l ".run (deleted)" -> incr n
        | _ -> ()
        | exception Unix.Unix_error _ -> ())
      (Sys.readdir "/proc/self/fd");
    !n
  in
  let db = Result.get_ok (open_ dir) in
  let[@warning "-8"] (Ok [ name; score ]) = declare db [ prop "name" Ttext; prop "score" Tint ] in
  let first = ref (-1) in
  let merges = 40 in
  for r = 1 to merges do
    let w = Result.get_ok (write db (List.concat (List.init 200 (fun i -> [ Add (-1 - i, name, Text (Printf.sprintf "c%d-%d" r i)); Add (-1 - i, score, Int i) ])))) in
    if r = 1 then first := thing w (-1);
    let old = view db in
    ignore (Result.get_ok (snapshot db));
    C.check (get old !first <> []) "merge %d: the view before it reads the replaced run" r
  done;
  (* the newest view asked holds its runs (Query.same_slot): the newest one now. A run's finaliser runs on the domain
     that made it, the writer's, at its next work after the collection that finds the run unreachable: a write *)
  ignore (get (view db) !first);
  Gc.full_major ();
  ignore (Result.get_ok (write db [ Add (-1, name, Text "x") ]));
  Gc.full_major ();
  ignore (Result.get_ok (write db [ Add (-1, name, Text "y") ]));
  let n = removed_open () in
  C.check (n = 0) "after %d merges, %d removed runs are still open" merges n;
  close db;
  C.rmrf dir

(* ---- named cases ---- *)

let () =
  section "named cases: write skew, unique, one value, triangles";
  let f = fork empty in
  let[@warning "-8"] (Ok [ oncall; mail; name; follows ]) =
    declare f [ prop "oncall" Tbool; prop ~unique:true "mail" Ttext; prop "name" Ttext; prop ~many:true "follows" Tlink ]
  in
  let r = Result.get_ok (write f [ Add (-1, oncall, Bool true); Add (-2, oncall, Bool true) ]) in
  let alice = thing r (-1) and bob = thing r (-2) in
  let v = view f in
  (* both read "two on call" in v, both try to leave; the second must fail *)
  let a = write f [ Expect (bob, oncall, Some (Bool true)); Add (alice, oncall, Bool false) ] in
  let b = write f [ Expect (alice, oncall, Some (Bool true)); Add (bob, oncall, Bool false) ] in
  C.check (Result.is_ok a && (match b with Error (Conflict _) -> true | _ -> false)) "write skew is refused";
  C.check (values v alice oncall = [ Bool true ]) "an old view does not change";
  ignore (write f [ Add (alice, mail, Text "a@x") ]);
  C.check (match write f [ Add (bob, mail, Text "a@x") ] with Error (Not_unique _) -> true | _ -> false) "unique";
  ignore (write f [ Add (alice, name, Text "Ada Martin") ]);
  ignore (write f [ Add (alice, name, Text "Ada Durand") ]);
  C.check (values (view f) alice name = [ Text "Ada Durand" ]) "one value: the old one is retracted";
  (* triangles: a -> b -> c -> a *)
  let r = Result.get_ok (write f (List.concat_map (fun i -> [ Add (-i, name, Text (string_of_int i)) ]) [ 1; 2; 3; 4 ])) in
  let t i = thing r (-i) in
  ignore (write f [ Add (t 1, follows, Link (t 2)); Add (t 2, follows, Link (t 3)); Add (t 3, follows, Link (t 1)); Add (t 3, follows, Link (t 4)) ]);
  let q = { vars = 3; where = [ { e = Var 0; p = follows; v = Var 1 }; { e = Var 1; p = follows; v = Var 2 }; { e = Var 2; p = follows; v = Var 0 } ]; ranges = [] } in
  C.check (List.length (Result.get_ok (find (view f) q)) = 3) "one triangle, three rotations";
  C.check (match find (view f) { q with vars = 4 } with Error (Invalid _) -> true | _ -> false) "an unused variable is invalid"

(* ---- the engine bugs the documentation found, each with its test ---- *)

(* a section that raises fails, and the others still run *)
let guarded name f = try f () with e -> C.fail "%s: %s" name (Printexc.to_string e)

let () =
  section "G9: one engine per directory, whatever the spelling of its path";
  guarded "spellings" @@ fun () ->
  let dir = C.tmpdir "spell" in
  let db = Result.get_ok (open_ dir) in
  let link = dir ^ "-link" in
  (try Sys.remove link with Sys_error _ -> ());
  Unix.symlink dir link;
  let base = Filename.basename dir and parent = Filename.dirname dir in
  List.iter
    (fun d ->
      match open_ d with
      | Error (Busy _) -> incr C.checks
      | Ok d2 -> close d2; C.fail "%s opened beside %s: two engines on one directory" d dir
      | Error e -> C.fail "open %s: %s" d (message e))
    [ dir; dir ^ "/"; dir ^ "/."; parent ^ "//" ^ base; dir ^ "/../" ^ base; link; link ^ "/" ];
  close db;
  (* closed, it opens under any spelling, and the lock follows the directory, not the spelling *)
  let db = Result.get_ok (open_ link) in
  C.check (match open_ dir with Error (Busy _) -> true | Ok d -> close d; false | Error _ -> false)
    "opened through a symlink, the directory is busy under its own name";
  close db;
  let db = Result.get_ok (open_ dir) in
  close db;
  Sys.remove link;
  C.rmrf dir

let () =
  section "thing numbers stop at 2^31 - 1, the largest the run format holds";
  guarded "thing numbers" @@ fun () ->
  let last = (1 lsl 31) - 1 in
  let f = fork empty in
  let[@warning "-8"] (Ok [ n; l ]) = declare f [ prop "c/n" Tint; prop "c/l" Tlink ] in
  let v = view f in
  let at k = { v with next_e = k } in
  let resolve v ops = Resolve.resolve v ~n:(v.group + 1) ~time:1 ~by:0 ~why:"" ops in
  let invalid = function Error (Resolve.Invalid _) -> true | _ -> false in
  C.check (invalid (resolve (at last) [ Add (-1, n, Int 1); Add (-2, n, Int 2) ])) "two new things from the last number: refused";
  C.check (invalid (resolve (at (last + 1)) [ Add (-1, n, Int 1) ])) "a new thing past the last number: refused";
  (* five new things from the last number but five, the fifth only the target of a link: the sixth is refused *)
  C.check (Result.is_ok (resolve (at (last - 4)) [ Add (-1, n, Int 1); Add (-2, n, Int 1); Add (-3, n, Int 1); Add (-4, l, Link (-5)) ]))
    "five new things up to the last number, one of them only a link's target: given";
  C.check
    (invalid (resolve (at (last - 4)) [ Add (-1, n, Int 1); Add (-2, n, Int 1); Add (-3, n, Int 1); Add (-4, l, Link (-5));
                                       Add (-6, n, Int 1) ]))
    "a sixth new thing past the last number: refused";
  (match resolve (at last) [ Add (-1, n, Int 1) ] with
   | Ok (v', _, [ (-1, e) ]) -> C.check (e = last && v'.next_e = last + 1) "the last number is given"
   | Ok _ -> C.fail "the last number: an unexpected result"
   | Error e -> C.fail "the last number refused: %s" (Resolve.error_message e));
  (* the faster path of a large group never decides it: it leaves the group to Resolve, which refuses *)
  let large = !Resolve.large_min in
  Resolve.large_min := 1;
  let ops = [ Add (-1, n, Int 1); Add (-2, n, Int 2); Add (-3, n, Int 3) ] in
  C.check (Resolve.resolve_large (at (last - 1)) ~n:(v.group + 1) ~time:1 ~by:0 ~why:"" ops = None)
    "a large group past the last number goes to Resolve";
  Resolve.large_min := large;
  (* through write, on a fork: the same refusal, nothing changed *)
  let g = fork (at last) in
  C.check (match write g [ Add (-1, n, Int 1); Add (-2, n, Int 1) ] with Error (Invalid _) -> true | _ -> false) "write refuses it";
  C.check ((view g).next_e = last && (view g).group = v.group) "the refused write changed nothing";
  (* a property whose name and type are retracted while its many and unique stay: refused, with what is left *)
  let half = [ Retract (n, Schema.p_name, Text "c/n"); Retract (n, Schema.p_type, Int (Value.code Tint)) ] in
  C.check
    (match resolve v half with
     | Error (Resolve.Invalid m) -> m = Printf.sprintf "property %d keeps cepheus/many or cepheus/unique without a name and a type" n
     | _ -> false)
    "a property left with many and unique alone: its message"

let () =
  section "a second close does nothing";
  guarded "close twice" @@ fun () ->
  let sim = Sim_disk.create (Rng.make 31) in
  let disk = Sim_disk.disk sim in
  let a = Result.get_ok (open_on disk "/db") in
  let[@warning "-8"] (Ok [ n ]) = declare a [ prop "c/n" Tint ] in
  ignore (write a [ Add (-1, n, Int 1) ]);
  close a;
  C.check (disk.exists "/db/closed") "a clean close leaves its marker";
  let b = Result.get_ok (open_on disk "/db") in
  C.check (not (disk.exists "/db/closed")) "an open removes the marker";
  close a;
  C.check (not (disk.exists "/db/closed")) "a second close of an old handle left the marker of a database open elsewhere";
  C.check (match open_on disk "/db" with Error (Busy _) -> true | Ok c -> close c; false | Error _ -> false)
    "a second close of an old handle released the lock of the engine that holds the database";
  C.check (match write a [ Add (-1, n, Int 2) ] with Error Closed -> true | _ -> false) "the old handle stays closed";
  ignore (Result.get_ok (write b [ Add (-1, n, Int 3) ]));
  close b;
  close b;
  C.check (disk.exists "/db/closed") "closed twice, the marker of the clean close stays";
  let c = Result.get_ok (open_on disk "/db") in
  C.check (group (view c) = 4) "every confirmed group is there";
  close c

let () =
  section "the smallest Int, Date and Money are values like any other: written, read, retracted, replayed";
  guarded "smallest numbers" @@ fun () ->
  let sim = Sim_disk.create (Rng.make 37) in
  let disk = Sim_disk.disk sim in
  let a = Result.get_ok (open_on disk "/db") in
  let[@warning "-8"] (Ok [ n; d; m ]) = declare a [ prop "c/n" Tint; prop "c/d" Tdate; prop "c/m" (Tmoney 2) ] in
  let r = Result.get_ok (write a [ Add (-1, n, Int min_int); Add (-1, d, Date min_int); Add (-1, m, Money min_int) ]) in
  let x = thing r (-1) in
  let all v = (values v x n, values v x d, values v x m) in
  C.check (all (view a) = ([ Int min_int ], [ Date min_int ], [ Money min_int ])) "written and read";
  close a;
  let b = Result.get_ok (open_on disk "/db") in
  C.check (all (view b) = ([ Int min_int ], [ Date min_int ], [ Money min_int ])) "replayed from the journal";
  ignore (Result.get_ok (write b [ Retract (x, n, Int min_int); Retract (x, d, Date min_int); Retract (x, m, Money min_int) ]));
  C.check (all (view b) = ([], [], [])) "retracted";
  close b;
  let c = Result.get_ok (open_on disk "/db") in
  C.check (all (view c) = ([], [], [])) "the retractions replayed";
  close c

let () =
  section "fold: the values of its words, texts included, as find gives them";
  guarded "fold and decode" @@ fun () ->
  let f = fork empty in
  let[@warning "-8"] (Ok [ city; total; ratio; boss ]) =
    declare f [ prop "c/city" Ttext; prop "c/total" (Tmoney 2); prop "c/ratio" Tfloat; prop "c/boss" Tlink ]
  in
  let r = Rng.make 41 in
  let cities = [| "Lyon"; "Nice"; "Brest"; "" |] in
  for _ = 1 to 30 do
    ignore
      (write f
         [ Add (-1, city, Text (Rng.pick r cities)); Add (-1, total, Money (Rng.int r 1000));
           Add (-1, ratio, Float (float (Rng.int r 5) /. 4.)); Add (-2, city, Text (Rng.pick r cities));
           Add (-1, boss, Link (-2)) ])
  done;
  let v = view f in
  let q = { vars = 5; ranges = [];
            where = [ { e = Var 0; p = city; v = Var 1 }; { e = Var 0; p = total; v = Var 2 }; { e = Var 0; p = ratio; v = Var 3 };
                      { e = Var 0; p = boss; v = Var 4 } ] } in
  let rows = List.sort compare (Result.get_ok (find v q)) in
  let folded =
    Result.get_ok (fold v q ~init:(fun () -> []) ~step:(fun acc w -> Array.init 5 (fun x -> decode v q x w.(x)) :: acc) ~merge:( @ ))
  in
  C.check (List.sort compare folded = rows) "fold's words decoded are find's values";
  (* the sum per city, keyed by word in the step, the texts given once per key *)
  let q2 = { vars = 3; ranges = []; where = [ { e = Var 0; p = city; v = Var 1 }; { e = Var 0; p = total; v = Var 2 } ] } in
  let sums =
    Result.get_ok
      (fold v q2 ~init:(fun () -> Hashtbl.create 8)
         ~step:(fun t w -> Hashtbl.replace t w.(1) (w.(2) + Option.value (Hashtbl.find_opt t w.(1)) ~default:0); t)
         ~merge:(fun a b -> Hashtbl.iter (fun k x -> Hashtbl.replace a k (x + Option.value (Hashtbl.find_opt a k) ~default:0)) b; a))
  in
  let by_text = List.sort compare (Hashtbl.fold (fun w s acc -> (decode v q2 1 w, s) :: acc) sums []) in
  let expect = Hashtbl.create 8 in
  List.iter (fun row -> match row.(1), row.(2) with
      | x, Money m -> Hashtbl.replace expect x (m + Option.value (Hashtbl.find_opt expect x) ~default:0)
      | _ -> ()) (Result.get_ok (find v q2));
  C.check (by_text = List.sort compare (Hashtbl.fold (fun x s acc -> (x, s) :: acc) expect [])) "the sums per city, by their texts";
  C.check (match decode v q2 7 0 with _ -> false | exception Invalid_argument _ -> true)
    "a variable out of the question: Invalid_argument"

(* a journal's frames, from its segment files: the body length of each *)
let frame_bodies disk dir =
  let jdir = Filename.concat dir "journal" in
  List.concat_map
    (fun f ->
      let b = Disk.read_all disk (Filename.concat jdir f) in
      let rec go p acc = if p + 28 > Bytes.length b then List.rev acc else
          let len = Int32.to_int (Bytes.get_int32_le b (p + 4)) land 0xFFFFFFFF in
          go (p + 28 + len + 16) (len :: acc) in
      go 40 [])
    (disk.Disk.readdir jdir)

let () =
  section "frames stay within the journal's limit, however many groups arrive at once";
  guarded "frames" @@ fun () ->
  let limit = !Engine.frame_limit in
  Engine.frame_limit := 16_384;
  let text k = Text (String.make 6_000 (Char.chr (97 + (k mod 26)))) in
  (* one batch of four groups of 6 KB: two frames, not one of 24 KB *)
  let sim = Sim_disk.create (Rng.make 51) in
  let disk = Sim_disk.disk sim in
  let db = Result.get_ok (open_on disk "/f") in
  let[@warning "-8"] (Ok [ n ]) = declare db [ prop "c/t" Ttext ] in
  close db;
  (match Engine.open_ disk "/f" with
   | Error e -> C.fail "open: %s" (message e)
   | Ok e ->
     let reqs = Array.init 4 (fun k -> [ Resolve.Add (-1, n, text k) ], 0, "") in
     let rec all i acc =
       if i >= Array.length reqs then List.rev acc
       else begin
         let b = Engine.prepare e (Array.sub reqs i (Array.length reqs - i)) in
         let res = Engine.commit e b in
         all (i + Array.length res) (List.rev_append (Array.to_list res) acc)
       end
     in
     let res = all 0 [] in
     C.check (List.length res = 4 && List.for_all Result.is_ok res) "every group of the batch is confirmed";
     (* a group alone over the limit: refused, the writer goes on *)
     let b = Engine.prepare e [| [ Resolve.Add (-1, n, Text (String.make 20_000 'z')) ], 0, "" |] in
     C.check (match Engine.commit e b with [| Error (Invalid _) |] -> true | _ -> false) "a group over the limit is refused";
     Engine.close e);
  C.check (List.for_all (fun l -> l <= 16_384) (frame_bodies disk "/f")) "a batch made a frame over the limit";
  (* the threaded writer: groups from 16 threads at once *)
  let db = Result.get_ok (open_on disk "/f") in
  let writes k () = for i = 1 to 10 do ignore (Result.get_ok (write db [ Add (-1, n, text (k + i)) ])) done in
  let ths = List.init 16 (fun k -> Thread.create (writes k) ()) in
  List.iter Thread.join ths;
  let g = group (view db) in
  close db;
  C.check (List.for_all (fun l -> l <= 16_384) (frame_bodies disk "/f")) "the writer made a frame over the limit";
  let db = Result.get_ok (open_on disk "/f") in
  C.check (group (view db) = g) "every group is there after a reopen";
  close db;
  Engine.frame_limit := limit

(* ---- a journal of format 1, converted once at open ---- *)

(* a segment of format 1 holding [frames] (lists of groups), coded a change after the other *)
let segment_v1 id first frames =
  let b = Buffer.create 4096 in
  let h = Bytes.make 40 '\000' in
  Bytes.set_int32_le h 0 0x4A485043l;
  Bytes.set_int32_le h 4 1l;
  Bytes.blit_string id 0 h 8 16;
  Bytes.set_int64_le h 24 (Int64.of_int first);
  Bytes.set_int32_le h 36 (Int32.of_int (Crc32c.bytes h 0 36));
  Buffer.add_bytes b h;
  List.iter
    (fun gs ->
      let body = Buffer.create 256 in
      List.iter (encode_v1 body) gs;
      let n = Buffer.length body and g0 = (List.hd gs).Group.n in
      let f = Bytes.make (28 + n + 16) '\000' in
      Bytes.set_int32_le f 0 0x46485043l;
      Bytes.set_int32_le f 4 (Int32.of_int n);
      Bytes.set_int64_le f 8 (Int64.of_int g0);
      Bytes.set_int32_le f 16 (Int32.of_int (List.length gs));
      Buffer.blit body 0 f 28 n;
      let bc = Crc32c.bytes f 28 n in
      Bytes.set_int32_le f 20 (Int32.of_int bc);
      let hc = Crc32c.bytes f 0 24 in
      Bytes.set_int32_le f 24 (Int32.of_int hc);
      Bytes.set_int32_le f (28 + n) (Int32.of_int n);
      Bytes.set_int32_le f (28 + n + 4) (Int32.of_int bc);
      Bytes.set_int32_le f (28 + n + 8) (Int32.of_int hc);
      Bytes.set_int32_le f (28 + n + 12) 0x54485043l;
      Buffer.add_bytes b f)
    frames;
  Buffer.to_bytes b

let () =
  section "journal format 1: converted at open, a torn tail cut, damage refused";
  guarded "convert" @@ fun () ->
  for seed = 1 to 30 do
    let r = Rng.make (13000 + seed) in
    let disk = Sim_disk.disk (Sim_disk.create (Rng.make seed)) in
    (* a database of format 2 written as usual, its groups read back, and its journal written again in format 1, in
       two segments; its runs removed (a database of format 1 has runs of formats 5 and 6, which open sets aside) *)
    let db = Result.get_ok (open_on disk "/v") in
    let[@warning "-8"] (Ok [ name; score; friend ]) = declare db [ prop "c/name" Ttext; prop ~many:true "c/score" Tint; prop ~many:true "c/friend" Tlink ] in
    let ids = ref [] in
    for _ = 1 to 5 + Rng.int r 20 do
      let ops = List.init (1 + Rng.int r 6) (fun k ->
          match Rng.int r 3, !ids with
          | 0, _ | _, [] -> Add (-1 - k, name, Text (Printf.sprintf "n%d" (Rng.int r 50)))
          | 1, l -> Add (List.nth l (Rng.int r (List.length l)), score, Int (Rng.int r 1000 - 500))
          | _, l -> Add (-1 - k, friend, Link (List.nth l (Rng.int r (List.length l))))) in
      match write db ops with Ok rc -> ids := List.map snd rc.things @ !ids | Error _ -> ()
    done;
    let want = C.facts_of_view (view db) and top = group (view db) in
    close db;
    let id = Engine.read_meta disk "/v" in
    let gs = ref [] in
    Journal.read disk "/v/journal" id (fun g -> gs := g :: !gs);
    let gs = List.rev !gs in
    List.iter (fun n -> disk.remove (Filename.concat "/v/journal" n)) (disk.readdir "/v/journal");
    List.iter (fun n -> disk.remove (Filename.concat "/v/snapshots" n)) (disk.readdir "/v/snapshots");
    let cut = 1 + Rng.int r (List.length gs - 1) in
    let a = List.filteri (fun i _ -> i < cut) gs and b = List.filteri (fun i _ -> i >= cut) gs in
    let frames l = List.map (fun g -> [ g ]) l in
    let s1 = segment_v1 id 1 (frames a) and s2 = segment_v1 id (cut + 1) (frames b) in
    (* the newest segment's tail: a frame torn by a crash (a header, part of a body), cut by the conversion *)
    let torn = Rng.bool r in
    let s2 = if torn then Bytes.cat s2 (Bytes.sub (segment_v1 id (top + 1) [ [ List.hd gs ] ]) 40 30) else s2 in
    Disk.write_file disk (Filename.concat "/v/journal" (Journal.segment_name 1)) s1;
    Disk.write_file disk (Filename.concat "/v/journal" (Journal.segment_name (cut + 1))) s2;
    (* a conversion a crash cut short left its file beside the segment: removed *)
    Disk.write_file disk (Filename.concat "/v/journal" (Journal.segment_name 1 ^ ".tmp")) (Bytes.of_string "half");
    (match open_on disk "/v" with
     | Error e -> C.fail "seed %d: a journal of format 1 does not open: %s" seed (message e)
     | Ok db ->
       C.check (group (view db) = top && C.F.equal want (C.facts_of_view (view db))) "seed %d: the converted journal holds other facts" seed;
       close db);
    C.check (List.for_all (fun n -> Filename.check_suffix n ".seg") (disk.readdir "/v/journal")) "seed %d: a file left beside the segments" seed;
    (* every segment is of format 2 now: a second open converts nothing *)
    C.check (Journal.convert disk "/v/journal" id = 0) "seed %d: a second conversion found segments of format 1" seed;
    (* damage in a segment that is not the newest: refused, before and after a conversion alike *)
    if seed mod 3 = 0 then begin
      List.iter (fun n -> disk.remove (Filename.concat "/v/journal" n)) (disk.readdir "/v/journal");
      List.iter (fun n -> disk.remove (Filename.concat "/v/snapshots" n)) (disk.readdir "/v/snapshots");
      let s1 = Bytes.copy s1 in
      let k = 40 + 28 + 1 in
      Bytes.set s1 k (Char.chr (Char.code (Bytes.get s1 k) lxor 1));
      Disk.write_file disk (Filename.concat "/v/journal" (Journal.segment_name 1)) s1;
      Disk.write_file disk (Filename.concat "/v/journal" (Journal.segment_name (cut + 1))) s2;
      C.check (match open_on disk "/v" with Error (Damaged _) -> true | Ok db -> close db; false | Error _ -> false)
        "seed %d: a damaged frame of format 1 is not refused" seed
    end
  done

let () =
  section "an open after a snapshot reads the journal's headers, not its frames";
  guarded "open reads" @@ fun () ->
  let disk = Sim_disk.disk (Sim_disk.create (Rng.make 41)) in
  let db = Result.get_ok (open_on disk "/o") in
  let[@warning "-8"] (Ok [ name ]) = declare db [ prop "c/name" Ttext ] in
  for i = 1 to 300 do ignore (write db [ Add (-1, name, Text (String.make 200 'x' ^ string_of_int i)) ]) done;
  ignore (Result.get_ok (snapshot db));
  let want = C.facts_of_view (view db) in
  close db;
  let size = List.fold_left (fun a n -> a + Bytes.length (Disk.read_all disk (Filename.concat "/o/journal" n))) 0 (disk.readdir "/o/journal") in
  (* the bytes read from the segments, counted by a disk wrapped around the simulated one *)
  let segment = Hashtbl.create 4 and read = ref 0 in
  let counting =
    { disk with
      openf = (fun p c -> let fd = disk.openf p c in (if Filename.check_suffix p ".seg" then Hashtbl.replace segment fd () else Hashtbl.remove segment fd); fd);
      pread = (fun fd o b bo n -> if Hashtbl.mem segment fd then read := !read + n; disk.pread fd o b bo n) }
  in
  let db = Result.get_ok (open_on counting "/o") in
  C.check (C.F.equal want (C.facts_of_view (view db))) "the reopened database holds other facts";
  close db;
  (* the conversion's look at the header and the scan's: 40 bytes each *)
  C.check (size > 60_000 && !read <= 2 * 40) "an open read %d bytes of a journal of %d bytes that the runs hold" !read size

let () =
  section "a snapshot with merges turned off (compact_min at max_int) ends";
  guarded "no merges" @@ fun () ->
  let saved = !Engine.compact_min in
  Fun.protect ~finally:(fun () -> Engine.compact_min := saved) @@ fun () ->
  Engine.compact_min := max_int;
  let disk = Sim_disk.disk (Sim_disk.create (Rng.make 43)) in
  let db = Result.get_ok (open_on disk "/m") in
  let[@warning "-8"] (Ok [ n ]) = declare db [ prop "c/n" Tint ] in
  for i = 1 to 50 do ignore (write db [ Add (-1, n, Int i) ]) done;
  C.check (Result.is_ok (snapshot db)) "the snapshot failed";
  C.check (Store.facts (view db) >= 50) "the snapshot lost facts";
  close db

(* ---- costs: the work of a question and of an index lookup stays within its bound ----
   Each case is built so that one list is far larger than the answer: an engine that walks it where a lookup or a
   smaller list would do fails the bound (counted candidates for questions; time, with a margin of 20 or more, for the
   index lookups, which have no counter in their inner loops). *)

let within secs what f =
  let best = ref infinity and tries = ref 0 in
  while !best >= secs && !tries < 3 do
    let t = Unix.gettimeofday () in
    f ();
    best := min !best (Unix.gettimeofday () -. t);
    incr tries
  done;
  C.check (!best < secs) "%s: %.3f s, the bound is %.2f s" what !best secs

let compacted f = fork (C.compact (view f))

let () =
  section "costs: questions stay within the Generic Join bound, lookups within O(log n)";
  let f = fork empty in
  let[@warning "-8"] (Ok [ city; client; status; total; _tag; member; score ]) =
    declare f [ prop "city" Ttext; prop "client" Tlink; prop "status" Ttext; prop "total" Tint; prop ~many:true "tag" Ttext;
                prop ~many:true "member" Tint; prop "score" Tint ]
  in
  (* 40 clients in c1 with 2 unpaid invoices each; one client in c2 with 20,000 unpaid invoices *)
  let ops = ref [ Add (-1000, city, Text "c2") ] in
  for k = 1 to 40 do
    ops := Add (-k, city, Text "c1") :: !ops;
    for j = 1 to 2 do
      let i = -((100 * k) + j) in
      ops := Add (i, client, Link (-k)) :: Add (i, status, Text "unpaid") :: Add (i, total, Int j) :: !ops
    done
  done;
  for j = 1 to 20_000 do
    let i = -(10_000 + j) in
    ops := Add (i, client, Link (-1000)) :: Add (i, status, Text "unpaid") :: Add (i, total, Int j) :: !ops
  done;
  ignore (Result.get_ok (write f (List.rev !ops)));
  let q3 = { vars = 3; ranges = [];
             where = [ { e = Var 0; p = city; v = Val (Text "c1") }; { e = Var 1; p = client; v = Var 0 };
                       { e = Var 1; p = status; v = Val (Text "unpaid") }; { e = Var 1; p = total; v = Var 2 } ] } in
  List.iter
    (fun (name, g) ->
      let v = view g in
      let facts = C.facts_of_view v in
      let rows, work, bound = C.work_and_bound v facts q3 (fun () -> Result.get_ok (find v q3)) in
      C.check (List.length rows = 80) "%s: the unpaid invoices of c1: %d rows" name (List.length rows);
      C.check (work <= bound && work <= 400) "%s: unpaid of a city: %d candidates, the bound is %d" name work bound)
    [ "base", compacted f; "delta", f ];
  (* exact counts with a delta: 100 things tagged rare in the base, 1,000 tagged hot in the delta, 50 of them rare *)
  let g = fork empty in
  let[@warning "-8"] (Ok [ tag ]) = declare g [ prop ~many:true "tag" Ttext ] in
  let r = Result.get_ok (write g (List.init 100 (fun k -> Add (-(k + 1), tag, Text "rare")))) in
  let rare = List.map snd r.things in
  let g = compacted g in
  ignore (Result.get_ok (write g (List.filteri (fun i _ -> i < 50) rare |> List.map (fun e -> Add (e, tag, Text "hot")))));
  ignore (Result.get_ok (write g (List.init 950 (fun k -> Add (-(k + 1), tag, Text "hot")))));
  let v = view g in
  let q = { vars = 1; ranges = []; where = [ { e = Var 0; p = tag; v = Val (Text "rare") }; { e = Var 0; p = tag; v = Val (Text "hot") } ] } in
  let rows, work, bound = C.work_and_bound v (C.facts_of_view v) q (fun () -> Result.get_ok (find v q)) in
  C.check (List.length rows = 50) "rare and hot: %d rows" (List.length rows);
  C.check (work <= bound && work <= 100) "rare and hot: %d candidates, the bound is %d (counts must be exact with a delta)" work bound;
  (* a range: 20,000 scores, the question asks for 10 of them *)
  let h = fork empty in
  let[@warning "-8"] (Ok [ score1 ]) = declare h [ prop "score" Tint ] in
  ignore (Result.get_ok (write h (List.init 20_000 (fun k -> Add (-(k + 1), score1, Int k)))));
  let qr = { vars = 2; where = [ { e = Var 0; p = score1; v = Var 1 } ]; ranges = [ 1, Int 100, Int 109 ] } in
  List.iter
    (fun (name, h) ->
      let v = view h in
      let rows, work, bound = C.work_and_bound v (C.facts_of_view v) qr (fun () -> Result.get_ok (find v qr)) in
      C.check (List.length rows = 10) "%s: a range of 10 scores: %d rows" name (List.length rows);
      C.check (work <= bound && work <= 40) "%s: a range of 10 scores: %d candidates, the bound is %d" name work bound)
    [ "delta", h; "base", compacted h ];
  (* one thing with 40,000 values, added one group at a time *)
  let hub = thing (Result.get_ok (write f [ Add (-1, city, Text "hub") ])) (-1) in
  let big = ref f in
  within 1.0 "40,000 values added one group at a time to one thing" (fun () ->
      let g = fork (view f) in
      for k = 1 to 40_000 do ignore (Result.get_ok (write g [ Add (hub, member, Int k) ])) done;
      big := g);
  ignore (Result.get_ok (write !big [ Add (hub, score, Int 7) ]));
  (* in the base: 40,000 values, then a property after them; in the delta: 500 more, 100 retracted *)
  let b = compacted !big in
  let vb = view b in
  within 0.3 "20,000 lookups past 40,000 values of a thing (base)" (fun () ->
      for k = 1 to 20_000 do if not (Store.mem vb hub score 7) || Store.mem vb hub score (k + 7) then C.fail "score lookup" done);
  for k = 1 to 500 do ignore (Result.get_ok (write b [ Add (hub, member, Int (40_000 + k)) ])) done;
  for k = 1 to 100 do ignore (Result.get_ok (write b [ Retract (hub, member, Int (k * 10)) ])) done;
  let vd = view b in
  within 0.3 "20,000 lookups on a thing with 40,000 values in the base and 600 changes in the delta" (fun () ->
      for k = 1 to 20_000 do
        let w = 1 + ((k * 7919) mod 41_000) in
        let want = w <= 40_500 && not (w <= 1000 && w mod 10 = 0) in
        if Store.mem vd hub member w <> want then C.fail "member %d: want %b" w want
      done);
  C.check (Store.count_values vd hub member = 40_400) "a thing's count with a delta is exact: %d" (Store.count_values vd hub member);
  C.check (List.length (values vd hub member) = 40_400) "a thing's values with a delta";
  (* links: 30,000 invoices point at one client by [client], one thing by [boss] *)
  let l = fork empty in
  let[@warning "-8"] (Ok [ client; boss ]) = declare l [ prop "client" Tlink; prop "boss" Tlink ] in
  let r = Result.get_ok (write l [ Add (-1, boss, Link (-1)) ]) in
  let c0 = thing r (-1) in
  ignore (Result.get_ok (write l (Add (-30_001, boss, Link c0) :: List.init 30_000 (fun k -> Add (-(k + 1), client, Link c0)))));
  let vl = view (compacted l) in
  within 0.3 "20,000 lookups of the one boss link among 30,000 links to a thing" (fun () ->
      for _ = 1 to 20_000 do if List.length (things vl boss (Link c0)) <> 2 then C.fail "boss links" done);
  (* compaction of a thing whose 30,000 values arrived out of order *)
  let o = fork empty in
  let[@warning "-8"] (Ok [ member ]) = declare o [ prop ~many:true "member" Tint ] in
  let t = thing (Result.get_ok (write o [ Add (-1, member, Int 0) ])) (-1) in
  ignore (Result.get_ok (write o (List.init 30_000 (fun k -> Add (t, member, Int (((k + 1) * 7919) mod 30_011))))));
  within 0.25 "compaction of a thing with 30,000 values out of order" (fun () ->
      let c = C.compact (view o) in
      if Store.count_values c t member <> 30_001 then C.fail "compacted count");
  ignore (city, client, status, total, member, score)

let () =
  section "large groups: their runs stay side by side until a tier of them, then merge once (lazy leveling)";
  let large = !Resolve.large_min and cmin = !Engine.compact_min and tier = !Engine.tier in
  Resolve.large_min := 50;
  Engine.compact_min := 1_000;
  Engine.tier := 4;
  let disk = Sim_disk.disk (Sim_disk.create (Rng.make 77)) in
  let db = Result.get_ok (open_on disk "/tier") in
  let[@warning "-8"] (Ok [ k ]) = declare db [ prop "k" Tint ] in
  (* nine groups of 100 new things each: level 1 holds them all, so leveling would keep one run; the tier keeps each
     group's run beside the others until the fourth, which merges the three before it with itself *)
  let counts =
    List.init 9 (fun g ->
        ignore (Result.get_ok (write db (List.init 100 (fun i -> Add (-(i + 1), k, Int ((g * 100) + i))))));
        Array.length (view db).runs)
  in
  C.check (counts = [ 1; 2; 3; 1; 2; 3; 1; 2; 3 ]) "runs after each large group: %s" (String.concat " " (List.map string_of_int counts));
  let all v = List.length (things v k (Int 0)) + List.length (things v k (Int 899)) in
  C.check (all (view db) = 2) "a value of the first group and of the last, read across the runs";
  C.check (Store.facts (view db) >= 900) "the nine groups' facts: %d" (Store.facts (view db));
  let before = Store.facts (view db) in
  ignore (Result.get_ok (snapshot db));
  C.check (Array.length (view db).runs = 1 && Store.facts (view db) = before) "snapshot: one run, the same facts";
  close db;
  (* reopened: the journal replays nothing the runs hold, and the facts are the same *)
  let db = Result.get_ok (open_on disk "/tier") in
  C.check (Store.facts (view db) = before) "reopened: %d facts, %d before" (Store.facts (view db)) before;
  close db;
  Resolve.large_min := large;
  Engine.compact_min := cmin;
  Engine.tier := tier

let () =
  section "the delta's map by value (Store.VM): its sums and the value where a count is reached, against a list";
  (* random adds and removes of values with net counts of -2 to 3, from fixed seeds; after each, every query on a
     few ranges and starts against the sorted list of bindings: the range's net count, the m-th addition from a value
     up and down, the bindings of a range, the order of a fold, and the tree's balance *)
  for seed = 1 to 40 do
    let r = Rng.make seed in
    let m = ref Store.VM.empty and model = ref [] in
    let rec height = function Store.VM.E -> 0 | N n -> 1 + max (height n.l) (height n.r) in
    let rec balanced = function Store.VM.E -> true | N n -> abs (height n.l - height n.r) <= 2 && balanced n.l && balanced n.r in
    for step = 1 to 300 do
      let k = Rng.int r 200 - 100 in
      if Rng.chance r 0.3 then (m := Store.VM.remove k !m; model := List.remove_assoc k !model)
      else begin
        let vn = Rng.int r 6 - 2 in
        let d = { Store.vn; vm = Store.IM.singleton step 1 } in
        m := Store.VM.add k d !m;
        model := (k, vn) :: List.remove_assoc k !model
      end;
      let sorted = List.sort compare !model in
      let lo = Rng.int r 240 - 120 and len = Rng.int r 120 in
      let hi = lo + len in
      let want = List.fold_left (fun n (k, vn) -> if k >= lo && k <= hi then n + vn else n) 0 sorted in
      C.check (Store.VM.sum_range lo hi !m = want) "seed %d step %d: sum of [%d, %d] %d, not %d" seed step lo hi (Store.VM.sum_range lo hi !m) want;
      let want_r = List.filter (fun (k, _) -> k >= lo && k <= hi) sorted in
      let got_r = ref [] in
      Store.VM.iter_range lo hi (fun k (d : Store.vdelta) -> got_r := (k, d.vn) :: !got_r) !m;
      C.check (List.rev !got_r = want_r) "seed %d step %d: the bindings of [%d, %d]" seed step lo hi;
      let cnt = 1 + Rng.int r 8 in
      let up = let rec go a = function [] -> None | (k, vn) :: t -> let a = a + max 0 vn in if k >= lo && a >= cnt then Some k else go (if k >= lo then a else 0) t in go 0 sorted in
      let down = let rec go a = function [] -> None | (k, vn) :: t -> let a = a + max 0 vn in if k <= lo && a >= cnt then Some k else go (if k <= lo then a else 0) t in go 0 (List.rev sorted) in
      C.check (Store.VM.nth lo cnt ~desc:false !m = up) "seed %d step %d: the %d-th addition from %d up" seed step cnt lo;
      C.check (Store.VM.nth lo cnt ~desc:true !m = down) "seed %d step %d: the %d-th addition from %d down" seed step cnt lo;
      C.check (List.rev (Store.VM.fold (fun k (d : Store.vdelta) acc -> (k, d.vn) :: acc) !m []) = sorted) "seed %d step %d: the fold's order" seed step;
      C.check (balanced !m && (match sorted with [] -> Store.VM.is_empty !m | _ -> fst (Store.VM.min_binding !m) = fst (List.hd sorted))) "seed %d step %d: balance and least key" seed step
    done
  done

let () =
  section "an idle writer merges the tier of runs a load left (Engine.tidy), and a busy one does not";
  let large = !Resolve.large_min and cmin = !Engine.compact_min and tier = !Engine.tier in
  Resolve.large_min := 50;
  Engine.compact_min := 1_000;
  Engine.tier := 16;
  let disk = Sim_disk.disk (Sim_disk.create (Rng.make 78)) in
  let db = Result.get_ok (open_on disk "/tidy") in
  let[@warning "-8"] (Ok [ k ]) = declare db [ prop "k" Tint ] in
  for g = 0 to 2 do ignore (Result.get_ok (write db (List.init 100 (fun i -> Add (-(i + 1), k, Int ((g * 100) + i)))))) done;
  let runs0 = Array.length (view db).runs and facts0 = Store.facts (view db) in
  close db;
  C.check (runs0 = 3) "three large groups: three runs side by side, not %d" runs0;
  let l = Engine.start (Result.get_ok (Engine.open_ disk "/tidy")) in
  let runs () = Array.length (Atomic.get l.e.published).runs in
  let merged0 = Atomic.get Engine.merges in
  (* a write after each tick (it answers once the writer took the tick): never idle, no merge *)
  Engine.tidy l;
  ignore (Result.get_ok (Engine.write l [ Add (-1, k, Int 1000) ] 0 ""));
  Engine.tidy l;
  ignore (Result.get_ok (Engine.write l [ Add (-1, k, Int 1001) ] 0 ""));
  C.check (l.merging = None && Atomic.get Engine.merges = merged0 && runs () = runs0) "busy between ticks: no merge, %d runs" (runs ());
  (* two ticks with no group between: the tier and the delta merged, in the background *)
  Engine.tidy l;
  Engine.tidy l;
  let t0 = Unix.gettimeofday () in
  while Atomic.get Engine.merges = merged0 && Unix.gettimeofday () -. t0 < 20. do Unix.sleepf 0.001 done;
  C.check (runs () = 1 && Store.facts (Atomic.get l.e.published) = facts0 + 2) "idle: one run, %d; %d facts, %d before and 2 more" (runs ()) (Store.facts (Atomic.get l.e.published)) facts0;
  (* one run a level: nothing to merge, however idle *)
  let merged1 = Atomic.get Engine.merges in
  Engine.tidy l;
  Engine.tidy l;
  ignore (Result.get_ok (Engine.write l [ Add (-1, k, Int 1002) ] 0 ""));
  C.check (l.merging = None && Atomic.get Engine.merges = merged1) "one run: no merge";
  Engine.stop l;
  let db = Result.get_ok (open_on disk "/tidy") in
  C.check (Store.facts (view db) = facts0 + 3) "reopened: the facts, %d" (Store.facts (view db));
  close db;
  Resolve.large_min := large;
  Engine.compact_min := cmin;
  Engine.tier := tier


(* ---- links that name a kind: Delete, to, on delete (refuse, cascade, clear) ---- *)

let contains s sub =
  let n = String.length sub in
  let rec go i = i + n <= String.length s && (String.sub s i n = sub || go (i + 1)) in
  go 0

let () =
  section "links: to, Delete, refuse, cascade, clear";
  let db = fork empty in
  let[@warning "-8"] (Ok [ cname; ccity; inum; iclient; lprice; linvoice; nbody; nabout; cat; parent; boss ]) =
    declare db
      [ prop "client/name" Ttext; prop "client/city" Ttext; prop "invoice/number" Tint; prop "invoice/client" Tlink;
        prop "line/price" (Tmoney 2); prop "line/invoice" Tlink; prop "note/body" Ttext;
        prop ~many:true "note/about" Tlink; prop "category/name" Ttext; prop "category/parent" Tlink; prop "employee/boss" Tlink ]
  in
  let refused ops = match write db ops with Error (Invalid m) -> Some m | _ -> None in
  let ok ops = match write db ops with Ok r -> r | Error e -> failwith ("links: a write failed: " ^ message e) in
  (* declarations: a link to a kind, read back; what is refused *)
  C.check (Result.is_ok (link_to db [ iclient, "client", Refuse; linvoice, "invoice", Cascade; nabout, "invoice", Clear ])) "links: declared";
  C.check (link (view db) iclient = Some ("client", Refuse) && link (view db) linvoice = Some ("invoice", Cascade) && link (view db) inum = None)
    "links: read back";
  C.check (Result.is_ok (link_to db [ iclient, "client", Refuse ])) "links: declared again, the same: nothing to do";
  C.check (match link_to db [ iclient, "client", Cascade ] with Error (Invalid m) -> contains m "links to client things" | _ -> false)
    "links: another on delete is refused";
  C.check (match link_to db [ inum, "client", Refuse ] with Error (Invalid m) -> contains m "cepheus/to is for a link" | _ -> false)
    "links: to on an int is refused";
  C.check (match link_to db [ boss, "nobody", Refuse ] with Error (Invalid m) -> contains m "no property" | _ -> false)
    "links: to a kind with no property is refused";
  C.check (refused [ Add (boss, Schema.p_delete, Text "cascade") ] <> None) "links: cepheus/delete without cepheus/to is refused";
  C.check (refused [ Add (boss, Schema.p_to, Text "category"); Add (boss, Schema.p_delete, Text "explode") ] <> None)
    "links: an unknown on delete is refused";
  C.check (Result.is_ok (link_to db [ parent, "category", Cascade ])) "links: a kind that links to itself";
  (* to: checked on the state after the group *)
  let r = ok [ Add (-1, cname, Text "Ada"); Add (-2, cname, Text "Bo"); Add (-3, nbody, Text "no client") ] in
  let ada = thing r (-1) and bo = thing r (-2) and stranger = thing r (-3) in
  C.check (match refused [ Add (-1, inum, Int 1); Add (-1, iclient, Link stranger) ] with Some m -> contains m "invoice/client links to client things only" | None -> false)
    "links: to a thing of another kind is refused";
  C.check (refused [ Add (-1, inum, Int 1); Add (-1, iclient, Link (-2)); Add (-2, nbody, Text "x") ] <> None)
    "links: to a new thing of another kind is refused";
  let r = ok [ Add (-1, inum, Int 1); Add (-1, iclient, Link (-2)); Add (-2, cname, Text "Cy") ] in
  let cy = thing r (-2) and i0 = thing r (-1) in
  C.check (link (view db) iclient <> None && values (view db) i0 iclient = [ Link cy ]) "links: to a client made in the same group";
  let r = ok [ Add (-1, inum, Int 2); Add (-1, iclient, Link ada); Add (-2, lprice, Money 1000); Add (-2, linvoice, Link (-1));
               Add (-3, lprice, Money 250); Add (-3, linvoice, Link (-1)); Add (-4, nbody, Text "call"); Add (-4, nabout, Link (-1)) ] in
  let i1 = thing r (-1) and l1 = thing r (-2) and l2 = thing r (-3) and n1 = thing r (-4) in
  (* refuse: a client with an invoice is not deleted, and the group leaves everything *)
  let before = C.facts_of_view (view db) in
  (match refused [ Delete (ada, "client") ] with
   | Some m ->
     C.check (contains m (Printf.sprintf "client #%d cannot be deleted while the invoice #%d links to it (invoice/client: refuse)" ada i1))
       "links: refuse names the kind, the thing and a linking thing: %s" m
   | None -> C.fail "links: a client with an invoice was deleted");
  C.check (C.F.equal (C.facts_of_view (view db)) before) "links: a refused Delete leaves every fact";
  C.check (refused [ Retract (ada, cname, Text "Ada") ] <> None) "links: retracting the last fact of a client with an invoice is refused too";
  C.check (Result.is_ok (write db [ Retract (ada, cname, Text "Ada"); Add (ada, ccity, Text "Lyon") ])) "links: a client that keeps another fact is still one";
  (* cascade and clear: an invoice's lines go with it, a note's link to it is retracted *)
  let g = ok [ Delete (i1, "invoice") ] in
  let v = view db in
  C.check (get v i1 = [] && get v l1 = [] && get v l2 = []) "links: Delete of an invoice, its two lines with it (cascade)";
  C.check (values v n1 nabout = [] && values v n1 nbody = [ Text "call" ]) "links: the note stays, its link retracted (clear)";
  C.check (g.group = v.group) "links: in one group";
  (* a Delete of a thing with no fact of the kind changes nothing; of a kind with no property, refused *)
  let n0 = Store.facts (view db) in
  C.check (Result.is_ok (write db [ Delete (stranger, "client") ]) && Store.facts (view db) = n0) "links: Delete of a thing of no such fact: nothing";
  C.check (match refused [ Delete (ada, "nothing") ] with Some m -> contains m "no property" | None -> false) "links: Delete of an unknown kind is refused";
  C.check (refused [ Delete (-1, "client") ] <> None) "links: Delete of a new thing is refused";
  C.check (refused [ Delete (1_000_000, "client") ] <> None) "links: Delete of no thing is refused";
  (* deleted and made again in one group: still a client, its invoice stays *)
  C.check (Result.is_ok (write db [ Delete (cy, "client"); Add (cy, cname, Text "Cy again") ]) && values (view db) i0 iclient = [ Link cy ])
    "links: deleted and given a fact again in one group: still a client";
  (* a link to a thing deleted in the same group: refused *)
  C.check (refused [ Delete (bo, "client"); Add (-1, inum, Int 9); Add (-1, iclient, Link bo) ] <> None) "links: a new link to a thing deleted in the group is refused";
  (* a tree that links to itself (cascade): the whole subtree goes, the rest stays *)
  let r = ok [ Add (-1, cat, Text "root"); Add (-2, cat, Text "a"); Add (-2, parent, Link (-1)); Add (-3, cat, Text "b"); Add (-3, parent, Link (-2));
               Add (-4, cat, Text "c"); Add (-4, parent, Link (-3)); Add (-5, cat, Text "other"); Add (-5, parent, Link (-1)) ] in
  ignore (ok [ Delete (thing r (-2), "category") ]);
  let v = view db in
  C.check (get v (thing r (-2)) = [] && get v (thing r (-3)) = [] && get v (thing r (-4)) = [] && values v (thing r (-1)) cat = [ Text "root" ]
           && values v (thing r (-5)) parent = [ Link (thing r (-1)) ]) "links: a subtree deleted by cascade, its siblings kept";
  (* a cycle: two things that link to each other, both cascade; and a thing that links to itself *)
  let r = ok [ Add (-1, cat, Text "x"); Add (-2, cat, Text "y"); Add (-1, parent, Link (-2)); Add (-2, parent, Link (-1)); Add (-3, cat, Text "self"); Add (-3, parent, Link (-3)) ] in
  ignore (ok [ Delete (thing r (-1), "category") ]);
  ignore (ok [ Delete (thing r (-3), "category") ]);
  let v = view db in
  C.check (get v (thing r (-1)) = [] && get v (thing r (-2)) = [] && get v (thing r (-3)) = []) "links: a cycle and a thing linking to itself end";
  (* the retraction of an invoice's last fact deletes its lines all the same: the same rule, whatever retracts *)
  let r = ok [ Add (-1, inum, Int 5); Add (-2, lprice, Money 1); Add (-2, linvoice, Link (-1)) ] in
  ignore (ok [ Retract (thing r (-1), inum, Int 5) ]);
  C.check (get (view db) (thing r (-2)) = []) "links: the invoice's last fact retracted: its line goes";
  (* the group's budget: a cascade past it is refused, nothing done *)
  let r = ok (Add (-1, inum, Int 6) :: List.concat (List.init 300 (fun k -> [ Add (-(k + 2), lprice, Money k); Add (-(k + 2), linvoice, Link (-1)) ]))) in
  let before = C.facts_of_view (view db) in
  let base = !(fst rule_budget) and per = !(snd rule_budget) in
  (fst rule_budget) := 50;
  (snd rule_budget) := 1;
  (match refused [ Delete (thing r (-1), "invoice") ] with
   | Some m -> C.check (contains m "work budget") "links: past the budget, refused: %s" m
   | None -> C.fail "links: a cascade past the budget was done");
  C.check (C.F.equal (C.facts_of_view (view db)) before) "links: past the budget, nothing done";
  (fst rule_budget) := base;
  (snd rule_budget) := per;
  C.check (Result.is_ok (write db [ Delete (thing r (-1), "invoice") ]) && get (view db) (thing r (-300)) = []) "links: within the budget, done";
  (* rules see the retractions: a count of lines, kept by the writer; no rule gives a link that names a kind *)
  let nlines = Result.get_ok (declare db [ prop "invoice/lines" Tint ]) |> List.hd in
  let rule = { name = "lines-of"; vars = 2; where = [ { e = Var 1; p = linvoice; v = Var 0 } ]; ranges = []; head = Give { e = Var 0; p = aggregate `Count nlines; v = Val (Int 0) } } in
  C.check (Result.is_ok (define db [ rule ])) "links: a rule over the lines";
  let r = ok [ Add (-1, inum, Int 7); Add (-2, lprice, Money 1); Add (-2, linvoice, Link (-1)); Add (-3, lprice, Money 2); Add (-3, linvoice, Link (-1)) ] in
  C.check (values (view db) (thing r (-1)) nlines = [ Int 2 ]) "links: two lines counted";
  ignore (ok [ Delete (thing r (-2), "line") ]);
  C.check (values (view db) (thing r (-1)) nlines = [ Int 1 ]) "links: a line deleted, the count follows";
  let bad = { name = "give-link"; vars = 2; where = [ { e = Var 0; p = linvoice; v = Var 1 } ]; ranges = []; head = Give { e = Var 0; p = iclient; v = Var 1 } } in
  C.check (match define db [ bad ] with Error (Invalid m) -> contains m "no rule gives one" | _ -> false) "links: a rule giving a link that names a kind is refused";
  let gives = { name = "gives-boss"; vars = 2; where = [ { e = Var 0; p = iclient; v = Var 1 } ]; ranges = []; head = Give { e = Var 0; p = boss; v = Var 1 } } in
  C.check (Result.is_ok (define db [ gives ])) "links: a rule giving a link of any thing";
  C.check (match link_to db [ boss, "client", Refuse ] with Error (Invalid m) -> contains m "no rule gives one" | _ -> false)
    "links: a link a rule gives cannot name a kind";
  (* Never sees what a clear retracts: a line may not lose its invoice *)
  let db = fork empty in
  let[@warning "-8"] (Ok [ inum; lprice; linvoice ]) = declare db [ prop "invoice/number" Tint; prop "line/price" Tint; prop "line/invoice" Tlink ] in
  ignore (link_to db [ linvoice, "invoice", Clear ]);
  let never = { name = "line-has-invoice"; vars = 2; where = [ { e = Var 0; p = lprice; v = Var 1 }; { e = Var 0; p = absent 0 linvoice; v = Var 1 } ]; ranges = []; head = Never } in
  ignore never;
  let never = { name = "line-has-invoice"; vars = 3; where = [ { e = Var 0; p = lprice; v = Var 1 }; { e = Var 0; p = absent 0 linvoice; v = Var 2 } ]; ranges = []; head = Never } in
  C.check (Result.is_ok (define db [ never ])) "links: a constraint over the lines";
  let r = Result.get_ok (write db [ Add (-1, inum, Int 1); Add (-2, lprice, Int 5); Add (-2, linvoice, Link (-1)) ]) in
  C.check (match write db [ Delete (thing r (-1), "invoice") ] with Error (Invalid m) -> contains m "line-has-invoice" | _ -> false)
    "links: Never sees the link a clear retracts"

let () =
  section "links: durable, after a power loss, and the large path";
  let sim = Sim_disk.create (Rng.make 91) in
  let disk = Sim_disk.disk sim in
  let large = !Resolve.large_min in
  Resolve.large_min := 50;
  let opened () = Result.get_ok (open_on disk "/links") in
  let db = ref (opened ()) in
  let[@warning "-8"] (Ok [ cname; iclient; inum; lprice; linvoice ]) =
    declare !db [ prop "client/name" Ttext; prop "invoice/client" Tlink; prop "invoice/number" Tint; prop "line/price" Tint; prop "line/invoice" Tlink ]
  in
  C.check (Result.is_ok (link_to !db [ iclient, "client", Refuse; linvoice, "invoice", Cascade ])) "links: declared on a database";
  (* a load: 40 clients, 40 invoices of them, by the large path *)
  let ops = List.concat (List.init 40 (fun k -> [ Add (-(k + 1), cname, Text (Printf.sprintf "c%d" k)); Add (-(k + 41), inum, Int k); Add (-(k + 41), iclient, Link (-(k + 1))) ])) in
  C.check (Resolve.resolve_large (view !db) ~n:((view !db).group + 1) ~time:0 ~by:0 ~why:"" ops <> None) "links: a load whose links hold takes the large path";
  let r = Result.get_ok (write !db ops) in
  let bad = List.concat (List.init 30 (fun k -> [ Add (-(k + 1), inum, Int (100 + k)); Add (-(k + 1), iclient, Link (thing r (-(41 + k)))) ])) in
  C.check (Resolve.resolve_large (view !db) ~n:((view !db).group + 1) ~time:0 ~by:0 ~why:"" bad = None) "links: a load with a link to an invoice leaves the large path";
  C.check (match write !db bad with Error (Invalid _) -> true | _ -> false) "links: and is refused";
  let inv = thing r (-41) in
  ignore (Result.get_ok (write !db [ Add (-1, lprice, Int 3); Add (-1, linvoice, Link inv); Add (-2, lprice, Int 4); Add (-2, linvoice, Link inv) ]));
  ignore (Result.get_ok (write !db [ Delete (inv, "invoice") ]));
  let before = C.facts_of_view (view !db) in
  Sim_disk.crash sim;
  db := opened ();
  C.check (C.F.equal (C.facts_of_view (view !db)) before) "links: after a power loss, the cascade's group replayed the same";
  C.check (link (view !db) linvoice = Some ("invoice", Cascade)) "links: and the links read back from the journal";
  ignore (Result.get_ok (snapshot !db));
  close !db;
  db := opened ();
  C.check (link (view !db) iclient = Some ("client", Refuse) && C.F.equal (C.facts_of_view (view !db)) before) "links: and from a merged run";
  C.check (match write !db [ Delete (thing r (-2), "client") ] with Error (Invalid _) -> true | _ -> false) "links: refuse, after the reopen";
  close !db;
  Resolve.large_min := large

let () = C.finish "unit"
