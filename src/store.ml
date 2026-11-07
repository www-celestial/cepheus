(* The facts. A view is a base, sorted and columnar, in pages (Pages: the same bytes as a snapshot's body, read from
   the file through the cache, or built in memory), plus a delta of the recent changes in persistent maps, so that a
   view is a value: taking one is free, keeping one costs nothing, and a fork is a view with its own delta. Thing ids
   are dense: "by thing" is an array indexed by the id (offsets, then rows); "by property" is one range per property,
   sorted by value then thing, which also answers "the things that link to t by p" (the rows of value t).

     by thing     eoff[e] .. eoff[e+1]   rows (eap, eav), sorted by property then value
     by property  poff[p] .. poff[p+1]   rows (avv, ave), sorted by value then thing
     dictionary   soff[i] .. soff[i+1]   the bytes of text i in sblob; ssort: the ids sorted by text

   Every lookup is a binary search plus the answer, on the base and on the delta, and every count is exact: the
   delta keeps its net counts beside its maps. *)

open Bigarray

type base = {
  pg : Pages.t;
  hot : Bytes.t array;  (* pg's hot table, here so that a read is one load less *)
  n : int;  (* facts *)
  ne : int;  (* thing ids 0 .. ne-1 *)
  np : int;  (* property ids 0 .. np-1 *)
  ns : int;  (* texts *)
  sblob : int;  (* bytes of all texts *)
  o_eoff : int;
  o_eap : int;
  o_eav : int;
  o_poff : int;
  o_avv : int;
  o_ave : int;
  o_pdist : int;
  o_soff : int;
  o_sblob : int;
  o_ssort : int;
  len : int;
}

let al x = (x + 7) land lnot 7

let layout ?(pg = Pages.create 0) ~n ~ne ~np ~ns ~sblob () =
  let off = ref 0 in
  let sec bytes = let o = !off in off := al (!off + bytes); o in
  let o_eoff = sec (8 * (ne + 1)) in
  let o_eap = sec (2 * n) in
  let o_eav = sec (8 * n) in
  let o_poff = sec (8 * (np + 1)) in
  let o_avv = sec (8 * n) in
  let o_ave = sec (4 * n) in
  let o_pdist = sec (8 * np) in
  let o_soff = sec (8 * (ns + 1)) in
  let o_sblob = sec sblob in
  let o_ssort = sec (4 * ns) in
  { pg; hot = pg.Pages.hot; n; ne; np; ns; sblob; o_eoff; o_eap; o_eav; o_poff; o_avv; o_ave; o_pdist; o_soff; o_sblob;
    o_ssort;
    len = !off }

external get64u : Bytes.t -> int -> int64 = "%caml_bytes_get64u"
external get32u : Bytes.t -> int -> int32 = "%caml_bytes_get32u"
external get16u : Bytes.t -> int -> int = "%caml_bytes_get16u"

(* Two kinds of readers of the base's pages. A read of a hot page is one load and one comparison either way; they
   differ in what happens otherwise:
   - the raising readers (eoff, eap, ...) raise [Miss k]: a lookup that calls nothing (a binary search, a count, a
     membership test) is run by [pure] or its own wrapper again from its start once page k is in. With no call on
     its path, OCaml keeps the loop's values in registers (a call would make it save them all on the stack);
   - the calling readers (ceoff, ceap, ...) bring the page in themselves (Pages.touch), for the loops that call a
     function per row, which save their registers around that call anyway.
   A [Miss] never leaves the functions of this section. *)
exception Miss of int

let fault b k = Pages.fault b.pg k

(* a lookup's end: in trace mode, its pages leave the hot table *)
let[@inline] ended r = if !Pages.tracing then Pages.cool (); r

let[@inline] frame b o =
  let k = o lsr Pages.bits in
  let f = Array.get b.hot k in
  if f != Pages.absent then f else raise_notrace (Miss k)

let[@inline] framec b o =
  let k = o lsr Pages.bits in
  let f = Array.get b.hot k in
  if f != Pages.absent then f else Pages.touch b.pg k

let[@inline] i64 b o = Int64.to_int (get64u (frame b o) (o land Pages.mask))
let[@inline] u32 b o = Int32.to_int (get32u (frame b o) (o land Pages.mask)) land 0xFFFFFFFF
let[@inline] eoff b e = i64 b (b.o_eoff + (8 * e))
let[@inline] eap b i = let o = b.o_eap + (2 * i) in get16u (frame b o) (o land Pages.mask)
let[@inline] eav b i = i64 b (b.o_eav + (8 * i))
let[@inline] poff b p = i64 b (b.o_poff + (8 * p))
let[@inline] avv b i = i64 b (b.o_avv + (8 * i))
let[@inline] ave b i = u32 b (b.o_ave + (4 * i))
let[@inline] pdist b p = i64 b (b.o_pdist + (8 * p))
let[@inline] soff b i = i64 b (b.o_soff + (8 * i))
let[@inline] ssort b i = u32 b (b.o_ssort + (4 * i))

let[@inline] ci64 b o = Int64.to_int (get64u (framec b o) (o land Pages.mask))
let[@inline] cu32 b o = Int32.to_int (get32u (framec b o) (o land Pages.mask)) land 0xFFFFFFFF
let[@inline] ceoff b e = ci64 b (b.o_eoff + (8 * e))
let[@inline] ceap b i = let o = b.o_eap + (2 * i) in get16u (framec b o) (o land Pages.mask)
let[@inline] ceav b i = ci64 b (b.o_eav + (8 * i))
let[@inline] cpoff b p = ci64 b (b.o_poff + (8 * p))
let[@inline] cavv b i = ci64 b (b.o_avv + (8 * i))
let[@inline] cave b i = cu32 b (b.o_ave + (4 * i))

(* [f b x] again until it misses no page; for a raising reader, or a lookup made of them *)
let rec safe f b x = match f b x with r -> ended r | exception Miss k -> fault b k; safe f b x

let empty_base = let b = layout ~n:0 ~ne:0 ~np:0 ~ns:0 ~sblob:0 () in
  let pg = Pages.create b.len in { b with pg; hot = pg.Pages.hot }

(* ---- The base alone ---- *)

(* the first row of thing e at or after (p, w); e must be a thing of the base. A binary search down to a window of
   8 rows, then a scan: most things have a handful of facts, where the scan is the faster *)
let lower_e b e p w =
  let lo = ref (eoff b e) and hi = ref (eoff b (e + 1)) in
  while !hi - !lo > 8 do
    let mid = (!lo + !hi) lsr 1 in
    let p' = eap b mid in
    if p' < p || (p' = p && eav b mid < w) then lo := mid + 1 else hi := mid
  done;
  while !lo < !hi && (let p' = eap b !lo in p' < p || (p' = p && eav b !lo < w)) do incr lo done;
  !lo

let rec base_lower_e b e p w =
  match lower_e b e p w with r -> ended r | exception Miss k -> fault b k; base_lower_e b e p w

let base_iter_ea b e p f =
  if e >= 0 && e < b.ne then begin
    let i = ref (base_lower_e b e p min_int) and hi = ceoff b (e + 1) in
    while !i < hi && ceap b !i = p do
      f (ceav b !i);
      incr i
    done
  end

(* the rows of e for p: a scan of up to 8 rows after the first, a second search beyond *)
let count_ea b e p =
  if e < 0 || e >= b.ne then 0
  else begin
    let i = lower_e b e p min_int and hi = eoff b (e + 1) in
    let j = ref i in
    while !j < hi && !j - i < 8 && eap b !j = p do incr j done;
    if !j < hi && eap b !j = p then lower_e b e (p + 1) min_int - i else !j - i
  end

let rec base_count_ea b e p =
  match count_ea b e p with r -> ended r | exception Miss k -> fault b k; base_count_ea b e p

let base_iter_e b e f =
  if e >= 0 && e < b.ne then
    for i = ceoff b e to ceoff b (e + 1) - 1 do
      f (ceap b i) (ceav b i)
    done

let mem_e b e p w =
  e >= 0 && e < b.ne
  && let i = lower_e b e p w in
     i < eoff b (e + 1) && eap b i = p && eav b i = w

let rec base_mem b e p w = match mem_e b e p w with r -> ended r | exception Miss k -> fault b k; base_mem b e p w

let lower b p w =
  let lo = ref (poff b p) and hi = ref (poff b (p + 1)) in
  while !lo < !hi do
    let mid = (!lo + !hi) lsr 1 in
    if avv b mid < w then lo := mid + 1 else hi := mid
  done;
  !lo

let rec base_lower b p w = match lower b p w with r -> ended r | exception Miss k -> fault b k; base_lower b p w

let base_iter_av b p w f =
  if p >= 0 && p < b.np then begin
    let hi = cpoff b (p + 1) in
    let i = ref (base_lower b p w) in
    while !i < hi && cavv b !i = w do
      f (cave b !i);
      incr i
    done
  end

let count_av b p w =
  if p < 0 || p >= b.np then 0
  else begin
    (* two binary searches: the rows of value w are [lower w, lower (w+1)) *)
    let lo = lower b p w in
    let hi = if w = max_int then poff b (p + 1) else lower b p (w + 1) in
    hi - lo
  end

let rec base_count_av b p w =
  match count_av b p w with r -> ended r | exception Miss k -> fault b k; base_count_av b p w

let base_iter_range b p lo hi f =
  if p >= 0 && p < b.np then begin
    let stop = cpoff b (p + 1) in
    let i = ref (base_lower b p lo) in
    while !i < stop && cavv b !i <= hi do
      f (cave b !i) (cavv b !i);
      incr i
    done
  end

let count_range b p lo hi =
  if p < 0 || p >= b.np || lo > hi then 0
  else (if hi = max_int then poff b (p + 1) else lower b p (hi + 1)) - lower b p lo

let rec base_count_range b p lo hi =
  match count_range b p lo hi with r -> ended r | exception Miss k -> fault b k; base_count_range b p lo hi

let base_count_p b p = if p >= 0 && p < b.np then cpoff b (p + 1) - cpoff b p else 0

let[@inline] byte b o = Char.code (Bytes.unsafe_get (frame b o) (o land Pages.mask))

let text_r b i =
  let lo = b.o_sblob + soff b i in
  let n = (b.o_sblob + soff b (i + 1)) - lo in
  if (lo land Pages.mask) + n <= Pages.size then Bytes.sub_string (frame b lo) (lo land Pages.mask) n
  else String.init n (fun k -> Char.unsafe_chr (byte b (lo + k)))

let rec base_text b i = match text_r b i with r -> ended r | exception Miss k -> fault b k; base_text b i

(* compares s with base text i *)
let cmp_r b s i =
  let lo = b.o_sblob + soff b i in
  let len = (b.o_sblob + soff b (i + 1)) - lo in
  let n = String.length s in
  if (lo land Pages.mask) + len <= Pages.size then begin
    (* the text in one page: compared in place *)
    let p = frame b lo and at = lo land Pages.mask in
    let k = ref 0 in
    while !k < n && !k < len && String.unsafe_get s !k = Bytes.unsafe_get p (at + !k) do incr k done;
    if !k = n || !k = len then compare n len
    else compare (Char.code (String.unsafe_get s !k)) (Char.code (Bytes.unsafe_get p (at + !k)))
  end
  else begin
    let k = ref 0 in
    while !k < n && !k < len && Char.code (String.unsafe_get s !k) = byte b (lo + !k) do incr k done;
    if !k = n || !k = len then compare n len else compare (Char.code (String.unsafe_get s !k)) (byte b (lo + !k))
  end

let find_text_r b s =
  let lo = ref 0 and hi = ref b.ns in
  while !lo < !hi do
    let mid = (!lo + !hi) lsr 1 in
    if cmp_r b s (ssort b mid) > 0 then lo := mid + 1 else hi := mid
  done;
  if !lo < b.ns && cmp_r b s (ssort b !lo) = 0 then Some (ssort b !lo) else None

let rec base_find_text b s = match find_text_r b s with r -> ended r | exception Miss k -> fault b k; base_find_text b s

(* ---- Dictionary, delta, views ---- *)

module IM = Map.Make (Int)
module SM = Map.Make (String)

module PW = Map.Make (struct
  type t = int * int

  let compare ((p : int), (w : int)) (p', w') = if p <> p' then compare p p' else compare w w'
end)

type chunks = { c0 : int; mutable arr : string array array; mutable count : int }

let chunk_bits = 12

type dict = { chunks : chunks; dcount : int; smap : int SM.t; extra : string IM.t; dnext : int }

(* A change is a difference from the base: [true], a fact the base lacks; [false], a fact of the base retracted.
   Beside each map, its net count (facts added minus facts retracted), so that every count is exact. *)
type tdelta = { tf : bool PW.t;  (* (property, value) -> added *) tn : int IM.t  (* property -> net count *) }
type vdelta = { vn : int; vm : bool IM.t  (* thing -> added *) }
type pdelta = { pn : int; pk : int  (* values in pm *); pm : vdelta IM.t  (* value -> its things *) }

type delta = {
  de : tdelta IM.t;  (* by thing *)
  dav : pdelta IM.t;  (* by property, then value *)
  dn : int;  (* changes made: what a merge folds in *)
  dnet : int;  (* net count of facts *)
}

let empty_delta = { de = IM.empty; dav = IM.empty; dn = 0; dnet = 0 }

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

(* ---- Base and delta: what a reader sees ---- *)

let thing_delta v e = if is_touched v e then IM.find_opt e v.delta.de else None

(* the delta's facts of thing e for property p, in value order *)
let iter_delta_ep (td : tdelta) p f =
  let rec go s = match s () with Seq.Cons (((p', w), add), s') when p' = p -> f w add; go s' | _ -> () in
  go (PW.to_seq_from (p, min_int) td.tf)

let iter_values v e p f =
  match thing_delta v e with
  | None -> base_iter_ea v.base e p f
  | Some td ->
    base_iter_ea v.base e p (fun w -> if PW.find_opt (p, w) td.tf = None then f w);
    iter_delta_ep td p (fun w add -> if add then f w)

(* every fact of e, in (property, value) order: the base rows and the delta merged *)
let iter_facts v e f =
  match thing_delta v e with
  | None -> base_iter_e v.base e f
  | Some td ->
    let b = v.base in
    let i = ref (if e < b.ne then ceoff b e else 0) and hi = if e < b.ne then ceoff b (e + 1) else 0 in
    PW.iter
      (fun (p, w) add ->
        while !i < hi && (let p' = ceap b !i in p' < p || (p' = p && ceav b !i < w)) do
          f (ceap b !i) (ceav b !i);
          incr i
        done;
        (* a retraction names a row of the base, which is skipped; an addition is a fact the base lacks *)
        if add then f p w else if !i < hi && ceap b !i = p && ceav b !i = w then incr i)
      td.tf;
    while !i < hi do
      f (ceap b !i) (ceav b !i);
      incr i
    done

let delta_av v p w = match IM.find_opt p v.delta.dav with None -> None | Some pd -> IM.find_opt w pd.pm

let iter_things v p w f =
  match delta_av v p w with
  | None -> base_iter_av v.base p w f
  | Some vd ->
    base_iter_av v.base p w (fun e -> if IM.find_opt e vd.vm = None then f e);
    IM.iter (fun e add -> if add then f e) vd.vm

let iter_prop v p f =
  let b = v.base in
  match IM.find_opt p v.delta.dav with
  | None -> if p >= 0 && p < b.np then for i = cpoff b p to cpoff b (p + 1) - 1 do f (cave b i) (cavv b i) done
  | Some pd ->
    if p >= 0 && p < b.np then
      for i = cpoff b p to cpoff b (p + 1) - 1 do
        let e = cave b i and w = cavv b i in
        match IM.find_opt w pd.pm with
        | Some vd when IM.mem e vd.vm -> ()
        | _ -> f e w
      done;
    IM.iter (fun w vd -> IM.iter (fun e add -> if add then f e w) vd.vm) pd.pm

(* the facts of p with lo <= value word <= hi (an order on values for the inline types) *)
let iter_range v p lo hi f =
  match IM.find_opt p v.delta.dav with
  | None -> base_iter_range v.base p lo hi f
  | Some pd ->
    base_iter_range v.base p lo hi (fun e w ->
        match IM.find_opt w pd.pm with
        | Some vd when IM.mem e vd.vm -> ()
        | _ -> f e w);
    let rec go s =
      match s () with
      | Seq.Cons ((w, vd), s') when w <= hi -> IM.iter (fun e add -> if add then f e w) vd.vm; go s'
      | _ -> ()
    in
    if lo <= hi then go (IM.to_seq_from lo pd.pm)

let mem v e p w =
  match thing_delta v e with
  | Some td -> (match PW.find_opt (p, w) td.tf with Some add -> add | None -> base_mem v.base e p w)
  | None -> base_mem v.base e p w

(* exact counts, from the base's offsets and the delta's net counts *)
let count_values v e p =
  base_count_ea v.base e p + match thing_delta v e with Some td -> Option.value (IM.find_opt p td.tn) ~default:0 | None -> 0

let has_value v e p = count_values v e p > 0

let count_things v p w = base_count_av v.base p w + match delta_av v p w with Some vd -> vd.vn | None -> 0

let count_prop v p = base_count_p v.base p + match IM.find_opt p v.delta.dav with Some pd -> pd.pn | None -> 0

(* the facts of p in a range: exact on the base, and the delta's part walked over the range only *)
let count_range v p lo hi =
  let n = ref (base_count_range v.base p lo hi) in
  (match IM.find_opt p v.delta.dav with
   | None -> ()
   | Some pd ->
     let rec go s = match s () with Seq.Cons ((w, vd), s') when w <= hi -> n := !n + vd.vn; go s' | _ -> () in
     if lo <= hi then go (IM.to_seq_from lo pd.pm));
  !n

(* an estimate for the planner: the distinct values of p, the base's and the delta's (an upper bound) *)
let distinct v p =
  max 1 ((if p >= 0 && p < v.base.np then safe pdist v.base p else 0)
         + match IM.find_opt p v.delta.dav with Some pd -> pd.pk | None -> 0)

(* ---- Changing a view ---- *)

let net = function Some true -> 1 | Some false -> -1 | None -> 0

(* st: Some true, (e p w) is added (not in the base); Some false, removed (in the base); None, as in the base *)
let change v e p w st =
  let d = v.delta in
  let td = Option.value (IM.find_opt e d.de) ~default:{ tf = PW.empty; tn = IM.empty } in
  let diff = net st - net (PW.find_opt (p, w) td.tf) in
  let tf = match st with None -> PW.remove (p, w) td.tf | Some add -> PW.add (p, w) add td.tf in
  let tn =
    if diff = 0 then td.tn
    else
      let k = Option.value (IM.find_opt p td.tn) ~default:0 + diff in
      if k = 0 then IM.remove p td.tn else IM.add p k td.tn
  in
  let de = if PW.is_empty tf then IM.remove e d.de else IM.add e { tf; tn } d.de in
  let pd = Option.value (IM.find_opt p d.dav) ~default:{ pn = 0; pk = 0; pm = IM.empty } in
  let old = IM.find_opt w pd.pm in
  let vd = Option.value old ~default:{ vn = 0; vm = IM.empty } in
  let vm = match st with None -> IM.remove e vd.vm | Some add -> IM.add e add vd.vm in
  let pm, pk =
    if IM.is_empty vm then IM.remove w pd.pm, (if old = None then pd.pk else pd.pk - 1)
    else IM.add w { vn = vd.vn + diff; vm } pd.pm, if old = None then pd.pk + 1 else pd.pk
  in
  let dav = if IM.is_empty pm then IM.remove p d.dav else IM.add p { pn = pd.pn + diff; pk; pm } d.dav in
  { v with delta = { de; dav; dn = d.dn + 1; dnet = d.dnet + diff } }

(* Adds or retracts (e p w); the view itself when nothing changes. *)
let apply v add e p w =
  if mem v e p w = add then v
  else
    let v = touch v e in
    let inbase = base_mem v.base e p w in
    let st = if add then (if inbase then None else Some true) else if inbase then Some false else None in
    change v e p w st

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
let build ~ne ~np ~ns ~(texts : int -> string) (fe : ia) (fp : ia) (fw : ia) n =
  let sblob = ref 0 in
  for i = 0 to ns - 1 do sblob := !sblob + String.length (texts i) done;
  let b = layout ~n ~ne ~np ~ns ~sblob:!sblob () in
  let pg = Pages.create (max 1 b.len) in
  let b = { b with pg; hot = pg.Pages.hot } in
  let set64 o x = Pages.set64 pg o x in
  (* by thing: rows sorted by (p, w) inside each thing; they come sorted from [iter_facts], so the insertion sort
     below only checks, in one pass *)
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
    Pages.set16 pg (b.o_eap + (2 * i)) (Array1.unsafe_get tp i);
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
      Pages.set32 pg (b.o_ave + (4 * i)) (Array1.unsafe_get ke i)
    done;
    set64 (b.o_pdist + (8 * p)) !d
  done;
  (* the dictionary: texts by id, and the ids sorted by text *)
  let p = ref 0 in
  for i = 0 to ns - 1 do
    set64 (b.o_soff + (8 * i)) !p;
    let s = texts i in
    String.iteri (fun k c -> Pages.set8 pg (b.o_sblob + !p + k) c) s;
    p := !p + String.length s
  done;
  set64 (b.o_soff + (8 * ns)) !p;
  let order = Array.init ns Fun.id in
  Array.stable_sort (fun i j -> compare (texts i) (texts j)) order;
  Array.iteri (fun k i -> Pages.set32 pg (b.o_ssort + (4 * k)) i) order;
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
    build ~ne:(max_thing v + 1) ~np:(Schema.count v.schema) ~ns ~texts:(text v) g.ge g.gp g.gw g.gn
  in
  of_base ~schema:v.schema ~group:v.group ~next_e:v.next_e b

let fork v =
  { v with writer = false; ftouched = (if Bytes.length v.ftouched = 0 then Bytes.empty else Bytes.copy v.ftouched) }

let facts v = v.base.n + v.delta.dnet
let base_bytes b = b.len
