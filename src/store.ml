(* The facts in memory. A view is a base, sorted and columnar, in one byte array off the OCaml heap (never scanned by
   the GC, the same bytes as a snapshot's body, so a snapshot maps straight into a base), plus a delta of the recent
   changes in persistent maps, so that a view is a value: taking one is free, keeping one costs nothing, and a fork is
   a view with its own delta. Thing ids are dense: "by thing" and "by link target" are arrays indexed by the id
   (offsets, then rows); "by property" is one range per property, sorted by value then thing.

     by thing     eoff[e] .. eoff[e+1]   rows (eap, eav), sorted by property then value
     by property  poff[p] .. poff[p+1]   rows (avv, ave), sorted by value then thing
     by link      roff[t] .. roff[t+1]   rows (rp, re) of the link facts that point at t, by thing
     dictionary   soff[i] .. soff[i+1]   the bytes of text i in sblob; ssort: the ids sorted by text *)

open Bigarray

type bigstring = Disk.bigstring

external g64 : bigstring -> int -> int64 = "%caml_bigstring_get64"
external s64 : bigstring -> int -> int64 -> unit = "%caml_bigstring_set64"
external g32 : bigstring -> int -> int32 = "%caml_bigstring_get32"
external s32 : bigstring -> int -> int32 -> unit = "%caml_bigstring_set32"
external g16 : bigstring -> int -> int = "%caml_bigstring_get16"
external s16 : bigstring -> int -> int -> unit = "%caml_bigstring_set16"

type base = {
  buf : bigstring;
  n : int;  (* facts *)
  ne : int;  (* thing ids 0 .. ne-1 *)
  np : int;  (* property ids 0 .. np-1 *)
  nr : int;  (* link facts *)
  ns : int;  (* texts *)
  sblob : int;  (* bytes of all texts *)
  o_eoff : int;
  o_eap : int;
  o_eav : int;
  o_poff : int;
  o_avv : int;
  o_ave : int;
  o_pdist : int;
  o_roff : int;
  o_rp : int;
  o_re : int;
  o_soff : int;
  o_sblob : int;
  o_ssort : int;
  len : int;
}

let al x = (x + 7) land lnot 7

let layout ?(buf = Array1.create char c_layout 0) ~n ~ne ~np ~nr ~ns ~sblob () =
  let off = ref 0 in
  let sec bytes = let o = !off in off := al (!off + bytes); o in
  let o_eoff = sec (8 * (ne + 1)) in
  let o_eap = sec (2 * n) in
  let o_eav = sec (8 * n) in
  let o_poff = sec (8 * (np + 1)) in
  let o_avv = sec (8 * n) in
  let o_ave = sec (4 * n) in
  let o_pdist = sec (8 * np) in
  let o_roff = sec (8 * (ne + 1)) in
  let o_rp = sec (2 * nr) in
  let o_re = sec (4 * nr) in
  let o_soff = sec (8 * (ns + 1)) in
  let o_sblob = sec sblob in
  let o_ssort = sec (4 * ns) in
  { buf; n; ne; np; nr; ns; sblob; o_eoff; o_eap; o_eav; o_poff; o_avv; o_ave; o_pdist; o_roff; o_rp; o_re; o_soff;
    o_sblob; o_ssort; len = !off }

let[@inline] i64 b o = Int64.to_int (g64 b.buf o)
let[@inline] u32 b o = Int32.to_int (g32 b.buf o) land 0xFFFFFFFF
let[@inline] eoff b e = i64 b (b.o_eoff + (8 * e))
let[@inline] eap b i = g16 b.buf (b.o_eap + (2 * i))
let[@inline] eav b i = i64 b (b.o_eav + (8 * i))
let[@inline] poff b p = i64 b (b.o_poff + (8 * p))
let[@inline] avv b i = i64 b (b.o_avv + (8 * i))
let[@inline] ave b i = u32 b (b.o_ave + (4 * i))
let[@inline] pdist b p = i64 b (b.o_pdist + (8 * p))
let[@inline] roff b t = i64 b (b.o_roff + (8 * t))
let[@inline] rp b i = g16 b.buf (b.o_rp + (2 * i))
let[@inline] re b i = u32 b (b.o_re + (4 * i))
let[@inline] soff b i = i64 b (b.o_soff + (8 * i))
let[@inline] ssort b i = u32 b (b.o_ssort + (4 * i))

let empty_base = let b = layout ~n:0 ~ne:0 ~np:0 ~nr:0 ~ns:0 ~sblob:0 () in
  let buf = Array1.create char c_layout b.len in
  Array1.fill buf '\000';
  { b with buf }

(* ---- The base alone ---- *)

let base_iter_ea b e p f =
  if e >= 0 && e < b.ne then begin
    let i = ref (eoff b e) and hi = eoff b (e + 1) in
    while !i < hi && eap b !i <= p do
      if eap b !i = p then f (eav b !i);
      incr i
    done
  end

let base_iter_e b e f =
  if e >= 0 && e < b.ne then
    for i = eoff b e to eoff b (e + 1) - 1 do
      f (eap b i) (eav b i)
    done

let base_mem b e p w =
  let found = ref false in
  base_iter_ea b e p (fun w' -> if w' = w then found := true);
  !found

let base_lower b p w =
  let lo = ref (poff b p) and hi = ref (poff b (p + 1)) in
  while !lo < !hi do
    let mid = (!lo + !hi) lsr 1 in
    if avv b mid < w then lo := mid + 1 else hi := mid
  done;
  !lo

let base_iter_av b p w f =
  if p >= 0 && p < b.np then begin
    let hi = poff b (p + 1) in
    let i = ref (base_lower b p w) in
    while !i < hi && avv b !i = w do
      f (ave b !i);
      incr i
    done
  end

let base_count_av b p w =
  if p < 0 || p >= b.np then 0
  else begin
    (* two binary searches: the rows of value w are [lower w, lower (w+1)) *)
    let lo = base_lower b p w in
    let hi = if w = max_int then poff b (p + 1) else base_lower b p (w + 1) in
    hi - lo
  end

let base_iter_range b p lo hi f =
  if p >= 0 && p < b.np then begin
    let stop = poff b (p + 1) in
    let i = ref (base_lower b p lo) in
    while !i < stop && avv b !i <= hi do
      f (ave b !i) (avv b !i);
      incr i
    done
  end

let base_iter_ref b t p f =
  if t >= 0 && t < b.ne then
    for i = roff b t to roff b (t + 1) - 1 do
      if rp b i = p then f (re b i)
    done

let base_count_p b p = if p >= 0 && p < b.np then poff b (p + 1) - poff b p else 0
let base_text b i = let lo = soff b i and hi = soff b (i + 1) in
  String.init (hi - lo) (fun k -> Array1.get b.buf (b.o_sblob + lo + k))

(* compares s with base text i *)
let base_cmp b s i =
  let lo = b.o_sblob + soff b i and len = soff b (i + 1) - soff b i in
  let n = String.length s in
  let rec go k =
    if k = n || k = len then compare n len
    else
      let c = compare (Char.code (String.unsafe_get s k)) (Char.code (Array1.get b.buf (lo + k))) in
      if c <> 0 then c else go (k + 1)
  in
  go 0

let base_find_text b s =
  let lo = ref 0 and hi = ref b.ns in
  while !lo < !hi do
    let mid = (!lo + !hi) lsr 1 in
    if base_cmp b s (ssort b mid) > 0 then lo := mid + 1 else hi := mid
  done;
  if !lo < b.ns && base_cmp b s (ssort b !lo) = 0 then Some (ssort b !lo) else None

(* ---- Dictionary, delta, views ---- *)

module IM = Map.Make (Int)
module SM = Map.Make (String)

type chunks = { c0 : int; mutable arr : string array array; mutable count : int }

let chunk_bits = 12

type dict = { chunks : chunks; dcount : int; smap : int SM.t; extra : string IM.t; dnext : int }

type delta = {
  de : (int * int * bool) list IM.t;  (* e -> (p, w, added): a difference from the base *)
  dav : bool IM.t IM.t IM.t;  (* p -> w -> e -> added *)
  dr : (int * bool) list IM.t IM.t;  (* target -> e -> (p, added) *)
  dn : int;
}

let empty_delta = { de = IM.empty; dav = IM.empty; dr = IM.empty; dn = 0 }

type touched = { mutable bits : Bytes.t }

type view = {
  base : base;
  delta : delta;
  touched : touched;  (* the writer's: things that may have a delta entry; bits are only ever set *)
  ftouched : Bytes.t;  (* a fork's own, or empty *)
  dict : dict;
  schema : Schema.t;
  group : int;  (* the last group applied *)
  next_e : int;  (* the next thing id *)
  writer : bool;  (* only the writer's views append to the shared dictionary *)
}

let new_chunks c0 = { c0; arr = [||]; count = c0 }

let of_base ?(schema = Schema.initial) ~group ~next_e base =
  { base; delta = empty_delta; touched = { bits = Bytes.make 64 '\000' }; ftouched = Bytes.empty;
    dict = { chunks = new_chunks base.ns; dcount = base.ns; smap = SM.empty; extra = IM.empty; dnext = base.ns };
    schema; group; next_e; writer = true }

let empty () = of_base ~group:0 ~next_e:Schema.first_thing empty_base

let[@inline] bit (b : Bytes.t) e =
  let i = e lsr 3 in
  i < Bytes.length b && Char.code (Bytes.unsafe_get b i) land (1 lsl (e land 7)) <> 0

let set_bit (b : Bytes.t) e =
  let i = e lsr 3 in
  Bytes.unsafe_set b i (Char.unsafe_chr (Char.code (Bytes.unsafe_get b i) lor (1 lsl (e land 7))))

let grown (b : Bytes.t) e =
  let need = (e lsr 3) + 1 in
  if need <= Bytes.length b then b
  else begin
    let nb = Bytes.make (max need (2 * Bytes.length b)) '\000' in
    Bytes.blit b 0 nb 0 (Bytes.length b);
    nb
  end

let[@inline] is_touched v e = bit v.touched.bits e || (Bytes.length v.ftouched > 0 && bit v.ftouched e)

let touch v e =
  if v.writer then begin
    let b = grown v.touched.bits e in
    if b != v.touched.bits then v.touched.bits <- b;
    set_bit b e;
    v
  end
  else begin
    let b = grown v.ftouched e in
    set_bit b e;
    if b == v.ftouched then v else { v with ftouched = b }
  end

let text v i =
  if i < v.base.ns then base_text v.base i
  else if i < v.dict.dcount then
    let k = i - v.dict.chunks.c0 in
    v.dict.chunks.arr.(k lsr chunk_bits).(k land ((1 lsl chunk_bits) - 1))
  else IM.find i v.dict.extra

let find_text v s = match SM.find_opt s v.dict.smap with Some i -> Some i | None -> base_find_text v.base s

let intern v s =
  match find_text v s with
  | Some i -> v, i
  | None ->
    let d = v.dict in
    if v.writer then begin
      let c = d.chunks in
      (* texts past this view's count were interned by a group that failed: nobody holds their ids *)
      if c.count > d.dcount then c.count <- d.dcount;
      let k = c.count - c.c0 in
      let ci = k lsr chunk_bits in
      if ci >= Array.length c.arr then begin
        let a = Array.make (max 4 (2 * Array.length c.arr)) [||] in
        Array.blit c.arr 0 a 0 (Array.length c.arr);
        c.arr <- a
      end;
      if Array.length c.arr.(ci) = 0 then c.arr.(ci) <- Array.make (1 lsl chunk_bits) "";
      c.arr.(ci).(k land ((1 lsl chunk_bits) - 1)) <- s;
      let i = c.count in
      c.count <- i + 1;
      { v with dict = { d with dcount = i + 1; smap = SM.add s i d.smap; dnext = i + 1 } }, i
    end
    else
      let i = d.dnext in
      { v with dict = { d with smap = SM.add s i d.smap; extra = IM.add i s d.extra; dnext = i + 1 } }, i

let float_key f = let b = Bytes.create 8 in Bytes.set_int64_le b 0 (Int64.bits_of_float f); Bytes.unsafe_to_string b

(* A value as an index word, for reading: None when it cannot be in the view (an unknown text). *)
let word v (x : Value.t) =
  match x with
  | Int n | Date n | Money n | Link n -> Some n
  | Bool b -> Some (if b then 1 else 0)
  | Text s -> find_text v s
  | Float f -> find_text v (float_key f)

let word_intern v (x : Value.t) =
  match x with
  | Int n | Date n | Money n | Link n -> v, n
  | Bool b -> v, if b then 1 else 0
  | Text s -> intern v s
  | Float f -> intern v (float_key f)

let value v (ty : Value.typ) w : Value.t =
  match ty with
  | Tint -> Int w
  | Tdate -> Date w
  | Tmoney _ -> Money w
  | Tlink -> Link w
  | Tbool -> Bool (w <> 0)
  | Ttext -> Text (text v w)
  | Tfloat -> Float (Int64.float_of_bits (String.get_int64_le (text v w) 0))

let is_link v p = match Schema.find v.schema p with Some { typ = Tlink; _ } -> true | _ -> false

(* ---- Base and delta: what a reader sees ---- *)

let retracted l p w = List.exists (fun (p', w', add) -> (not add) && p' = p && w' = w) l

let iter_values v e p f =
  if not (is_touched v e) then base_iter_ea v.base e p f
  else
    match IM.find_opt e v.delta.de with
    | None -> base_iter_ea v.base e p f
    | Some l ->
      base_iter_ea v.base e p (fun w -> if not (retracted l p w) then f w);
      List.iter (fun (p', w, add) -> if add && p' = p then f w) l

let iter_facts v e f =
  if not (is_touched v e) then base_iter_e v.base e f
  else
    match IM.find_opt e v.delta.de with
    | None -> base_iter_e v.base e f
    | Some l ->
      base_iter_e v.base e (fun p w -> if not (retracted l p w) then f p w);
      List.iter (fun (p, w, add) -> if add then f p w) (List.rev l)

let delta_av v p w = match IM.find_opt p v.delta.dav with None -> None | Some m -> IM.find_opt w m

let iter_things v p w f =
  if is_link v p then begin
    match IM.find_opt w v.delta.dr with
    | None -> base_iter_ref v.base w p f
    | Some m ->
      base_iter_ref v.base w p (fun e ->
          match IM.find_opt e m with
          | Some l when List.exists (fun (p', add) -> p' = p && not add) l -> ()
          | _ -> f e);
      IM.iter (fun e l -> List.iter (fun (p', add) -> if add && p' = p then f e) l) m
  end
  else
    match delta_av v p w with
    | None -> base_iter_av v.base p w f
    | Some m ->
      base_iter_av v.base p w (fun e -> match IM.find_opt e m with Some false -> () | _ -> f e);
      IM.iter (fun e add -> if add then f e) m

let iter_prop v p f =
  match IM.find_opt p v.delta.dav with
  | None -> if p >= 0 && p < v.base.np then for i = poff v.base p to poff v.base (p + 1) - 1 do f (ave v.base i) (avv v.base i) done
  | Some m ->
    if p >= 0 && p < v.base.np then
      for i = poff v.base p to poff v.base (p + 1) - 1 do
        let e = ave v.base i and w = avv v.base i in
        match IM.find_opt w m with
        | Some ev -> (match IM.find_opt e ev with Some false -> () | _ -> f e w)
        | None -> f e w
      done;
    IM.iter (fun w ev -> IM.iter (fun e add -> if add then f e w) ev) m

(* the facts of p with lo <= value <= hi (by word: meaningful for inline types) *)
let iter_range v p lo hi f =
  match IM.find_opt p v.delta.dav with
  | None -> base_iter_range v.base p lo hi f
  | Some m ->
    base_iter_range v.base p lo hi (fun e w ->
        match IM.find_opt w m with
        | Some ev -> (match IM.find_opt e ev with Some false -> () | _ -> f e w)
        | None -> f e w);
    IM.iter (fun w ev -> if w >= lo && w <= hi then IM.iter (fun e add -> if add then f e w) ev) m

let mem v e p w =
  let found = ref false in
  iter_values v e p (fun w' -> if w' = w then found := true);
  !found

let has_value v e p =
  let found = ref false in
  iter_values v e p (fun _ -> found := true);
  !found

(* estimates for the planner; exact on the base *)
let count_values v e p =
  if e < 0 || e >= v.base.ne then (if is_touched v e then 1 else 0)
  else
    let n = ref 0 in
    base_iter_ea v.base e p (fun _ -> incr n);
    if is_touched v e then !n + 1 else !n

(* the delta's part of an estimate: its size, but never a long walk *)
let small_card m = let n = ref 0 in (try IM.iter (fun _ _ -> incr n; if !n >= 64 then raise Exit) m with Exit -> ()); !n

let count_things v p w =
  base_count_av v.base p w + match delta_av v p w with None -> 0 | Some m -> small_card m

let count_prop v p =
  base_count_p v.base p + match IM.find_opt p v.delta.dav with None -> 0 | Some m -> small_card m

let distinct v p = if p >= 0 && p < v.base.np then max 1 (pdist v.base p) else 1

(* ---- Changing a view ---- *)

(* st: Some true, (e p w) is added (not in the base); Some false, removed (in the base); None, as in the base *)
let change v e p w st link =
  let d = v.delta in
  let de =
    IM.update e
      (fun o ->
        let l = List.filter (fun (p', w', _) -> not (p' = p && w' = w)) (Option.value o ~default:[]) in
        let l = match st with None -> l | Some add -> (p, w, add) :: l in
        if l = [] then None else Some l)
      d.de
  in
  let dav =
    IM.update p
      (fun o ->
        let m = Option.value o ~default:IM.empty in
        let m =
          IM.update w
            (fun o2 ->
              let ev = Option.value o2 ~default:IM.empty in
              let ev = match st with None -> IM.remove e ev | Some add -> IM.add e add ev in
              if IM.is_empty ev then None else Some ev)
            m
        in
        if IM.is_empty m then None else Some m)
      d.dav
  in
  let dr =
    if not link then d.dr
    else
      IM.update w
        (fun o ->
          let m = Option.value o ~default:IM.empty in
          let m =
            IM.update e
              (fun o2 ->
                let l = List.filter (fun (p', _) -> p' <> p) (Option.value o2 ~default:[]) in
                let l = match st with None -> l | Some add -> (p, add) :: l in
                if l = [] then None else Some l)
              m
          in
          if IM.is_empty m then None else Some m)
        d.dr
  in
  { v with delta = { de; dav; dr; dn = d.dn + 1 } }

(* Adds or retracts (e p w); the view itself when nothing changes. *)
let apply v add e p w =
  if mem v e p w = add then v
  else
    let v = touch v e in
    let inbase = base_mem v.base e p w in
    let st = if add then (if inbase then None else Some true) else if inbase then Some false else None in
    change v e p w st (is_link v p)

(* ---- Building a base: compaction, bulk replay ---- *)

type ia = (int, int_elt, c_layout) Array1.t

let ia n : ia = Array1.create int c_layout (max n 1)

(* Stable LSD radix sort of keys.(lo..hi) with vals, 11 bits a pass; falls back to a comparison sort on a huge span. *)
let sort_pairs (keys : ia) (vals : ia) lo hi =
  let n = hi - lo in
  if n > 1 then begin
    let mx = ref min_int and mn = ref max_int in
    for i = lo to hi - 1 do
      let k = Array1.unsafe_get keys i in
      if k > !mx then mx := k;
      if k < !mn then mn := k
    done;
    let span = !mx - !mn in
    if span < 0 then begin
      let a = Array.init n (fun i -> Array1.get keys (lo + i), Array1.get vals (lo + i)) in
      Array.stable_sort compare a;
      Array.iteri (fun i (k, x) -> Array1.set keys (lo + i) k; Array1.set vals (lo + i) x) a
    end
    else if span > 0 then begin
      let base = !mn in
      let sk = ref (Array.init n (fun i -> Array1.unsafe_get keys (lo + i))) in
      let sv = ref (Array.init n (fun i -> Array1.unsafe_get vals (lo + i))) in
      let dk = ref (Array.make n 0) and dv = ref (Array.make n 0) in
      let count = Array.make 2049 0 in
      let shift = ref 0 in
      while span lsr !shift > 0 do
        Array.fill count 0 2049 0;
        let a = !sk and av = !sv and b = !dk and bv = !dv and sh = !shift in
        for i = 0 to n - 1 do
          let d = ((Array.unsafe_get a i - base) lsr sh) land 2047 in
          Array.unsafe_set count (d + 1) (Array.unsafe_get count (d + 1) + 1)
        done;
        for d = 1 to 2048 do
          Array.unsafe_set count d (Array.unsafe_get count d + Array.unsafe_get count (d - 1))
        done;
        for i = 0 to n - 1 do
          let k = Array.unsafe_get a i in
          let d = ((k - base) lsr sh) land 2047 in
          let p = Array.unsafe_get count d in
          Array.unsafe_set b p k;
          Array.unsafe_set bv p (Array.unsafe_get av i);
          Array.unsafe_set count d (p + 1)
        done;
        sk := b; sv := bv; dk := a; dv := av;
        shift := sh + 11
      done;
      for i = 0 to n - 1 do
        Array1.unsafe_set keys (lo + i) (Array.unsafe_get !sk i);
        Array1.unsafe_set vals (lo + i) (Array.unsafe_get !sv i)
      done
    end
  end

(* The facts fe/fp/fw (n of them, sorted by thing) into a base; [texts] gives the ns texts of the dictionary. *)
let build ~ne ~np ~(is_link : int -> bool) ~ns ~(texts : int -> string) (fe : ia) (fp : ia) (fw : ia) n =
  let sblob = ref 0 in
  for i = 0 to ns - 1 do sblob := !sblob + String.length (texts i) done;
  let nr = ref 0 in
  for i = 0 to n - 1 do if is_link (Array1.unsafe_get fp i) then incr nr done;
  let b = layout ~n ~ne ~np ~nr:!nr ~ns ~sblob:!sblob () in
  let buf = Array1.create char c_layout (max 1 b.len) in
  Array1.fill buf '\000';
  let b = { b with buf } in
  let set64 o x = s64 buf o (Int64.of_int x) in
  (* by thing: rows sorted by (p, w) inside each thing *)
  let cnt = ia (ne + 1) in
  Array1.fill cnt 0;
  for i = 0 to n - 1 do
    let e = Array1.unsafe_get fe i in
    Array1.unsafe_set cnt (e + 1) (Array1.unsafe_get cnt (e + 1) + 1)
  done;
  for e = 1 to ne do Array1.unsafe_set cnt e (Array1.unsafe_get cnt e + Array1.unsafe_get cnt (e - 1)) done;
  for e = 0 to ne do set64 (b.o_eoff + (8 * e)) (Array1.unsafe_get cnt e) done;
  let tp = ia n and tw = ia n in
  for i = 0 to n - 1 do
    Array1.unsafe_set tp i (Array1.unsafe_get fp i);
    Array1.unsafe_set tw i (Array1.unsafe_get fw i)
  done;
  for e = 0 to ne - 1 do
    let lo = Array1.unsafe_get cnt e and hi = Array1.unsafe_get cnt (e + 1) in
    for i = lo + 1 to hi - 1 do
      let p = Array1.unsafe_get tp i and w = Array1.unsafe_get tw i in
      let j = ref (i - 1) in
      while !j >= lo && (let p' = Array1.unsafe_get tp !j in p' > p || (p' = p && Array1.unsafe_get tw !j > w)) do
        Array1.unsafe_set tp (!j + 1) (Array1.unsafe_get tp !j);
        Array1.unsafe_set tw (!j + 1) (Array1.unsafe_get tw !j);
        decr j
      done;
      Array1.unsafe_set tp (!j + 1) p;
      Array1.unsafe_set tw (!j + 1) w
    done
  done;
  for i = 0 to n - 1 do
    s16 buf (b.o_eap + (2 * i)) (Array1.unsafe_get tp i);
    set64 (b.o_eav + (8 * i)) (Array1.unsafe_get tw i)
  done;
  (* by property: rows (w, e) sorted by w then e *)
  let pc = Array.make (np + 1) 0 in
  for i = 0 to n - 1 do let p = Array1.unsafe_get tp i in pc.(p + 1) <- pc.(p + 1) + 1 done;
  for p = 1 to np do pc.(p) <- pc.(p) + pc.(p - 1) done;
  for p = 0 to np do set64 (b.o_poff + (8 * p)) pc.(p) done;
  let cur = Array.sub pc 0 (max 1 np) in
  let kw = ia n and ke = ia n in
  for e = 0 to ne - 1 do
    for i = Array1.unsafe_get cnt e to Array1.unsafe_get cnt (e + 1) - 1 do
      let p = Array1.unsafe_get tp i in
      let q = cur.(p) in
      Array1.unsafe_set kw q (Array1.unsafe_get tw i);
      Array1.unsafe_set ke q e;
      cur.(p) <- q + 1
    done
  done;
  for p = 0 to np - 1 do
    let lo = pc.(p) and hi = pc.(p + 1) in
    sort_pairs kw ke lo hi;
    let d = ref 0 in
    for i = lo to hi - 1 do
      if i = lo || Array1.unsafe_get kw i <> Array1.unsafe_get kw (i - 1) then incr d;
      set64 (b.o_avv + (8 * i)) (Array1.unsafe_get kw i);
      s32 buf (b.o_ave + (4 * i)) (Int32.of_int (Array1.unsafe_get ke i))
    done;
    set64 (b.o_pdist + (8 * p)) !d
  done;
  (* by link target *)
  let rc = ia (ne + 1) in
  Array1.fill rc 0;
  for i = 0 to n - 1 do
    if is_link (Array1.unsafe_get tp i) then begin
      let t = Array1.unsafe_get tw i in
      if t >= 0 && t < ne then Array1.unsafe_set rc (t + 1) (Array1.unsafe_get rc (t + 1) + 1)
    end
  done;
  for t = 1 to ne do Array1.unsafe_set rc t (Array1.unsafe_get rc t + Array1.unsafe_get rc (t - 1)) done;
  for t = 0 to ne do set64 (b.o_roff + (8 * t)) (Array1.unsafe_get rc t) done;
  for e = 0 to ne - 1 do
    for i = Array1.unsafe_get cnt e to Array1.unsafe_get cnt (e + 1) - 1 do
      let p = Array1.unsafe_get tp i in
      if is_link p then begin
        let t = Array1.unsafe_get tw i in
        if t >= 0 && t < ne then begin
          let q = Array1.unsafe_get rc t in
          s16 buf (b.o_rp + (2 * q)) p;
          s32 buf (b.o_re + (4 * q)) (Int32.of_int e);
          Array1.unsafe_set rc t (q + 1)
        end
      end
    done
  done;
  (* the dictionary: texts by id, and the ids sorted by text *)
  let p = ref 0 in
  for i = 0 to ns - 1 do
    set64 (b.o_soff + (8 * i)) !p;
    let s = texts i in
    String.iteri (fun k c -> Array1.unsafe_set buf (b.o_sblob + !p + k) c) s;
    p := !p + String.length s
  done;
  set64 (b.o_soff + (8 * ns)) !p;
  let order = Array.init ns Fun.id in
  Array.stable_sort (fun i j -> compare (texts i) (texts j)) order;
  Array.iteri (fun k i -> s32 buf (b.o_ssort + (4 * k)) (Int32.of_int i)) order;
  b

(* Facts of a view in thing order, as arrays. *)
type grow = { mutable ge : ia; mutable gp : ia; mutable gw : ia; mutable gn : int }

let grow () = { ge = ia 1024; gp = ia 1024; gw = ia 1024; gn = 0 }

let push g e p w =
  if g.gn = Array1.dim g.ge then begin
    let cap = 2 * g.gn in
    let cp a = let a' = ia cap in Array1.blit a (Array1.sub a' 0 g.gn); a' in
    g.ge <- cp g.ge; g.gp <- cp g.gp; g.gw <- cp g.gw
  end;
  Array1.unsafe_set g.ge g.gn e;
  Array1.unsafe_set g.gp g.gn p;
  Array1.unsafe_set g.gw g.gn w;
  g.gn <- g.gn + 1

let max_thing v = max (v.next_e - 1) (v.base.ne - 1)

(* Compaction: the visible facts of a view into a new base; a fresh writer lineage. *)
let compact v =
  let g = grow () in
  for e = 0 to max_thing v do
    iter_facts v e (fun p w -> push g e p w)
  done;
  let ns = v.dict.dnext in
  let b =
    build ~ne:(max_thing v + 1) ~np:(Schema.count v.schema) ~is_link:(is_link v) ~ns ~texts:(text v) g.ge g.gp g.gw g.gn
  in
  of_base ~schema:v.schema ~group:v.group ~next_e:v.next_e b

let fork v =
  { v with writer = false; ftouched = (if Bytes.length v.ftouched = 0 then Bytes.empty else Bytes.copy v.ftouched) }

let facts v = v.base.n + v.delta.dn
let base_bytes b = b.len
