(* The facts. A view is a stack of runs, sorted and columnar, in pages (Pages: the bytes of a run's file, read
   through the cache), plus a delta of the recent changes in persistent maps, so that a view is a value: taking one
   is free, keeping one costs nothing, and a fork is a view with its own delta. The runs are the levels of an LSM tree
   (O'Neil et al. 1996), newest first: each holds the changes of a range of groups on top of the state of the runs
   below it, as facts it adds (part a) and facts of the runs below it retracts (part t, empty at the bottom); a fact
   is in a view when the newest entry for it (the delta's, or the newest run's that has one) adds it. A run's counts
   are net: a run adds only facts absent below it and retracts only facts present below it, so every count is a sum of
   exact counts.

   A part has three sections:
     by thing     the things it holds: a rank table (one 64-bit word for 32 thing ids: their presence bits, and how
                  many things come before), eoff[slot] .. eoff[slot+1] the rows (eap, eav) of the thing in that slot,
                  sorted by property then value
     by property  poff[p] .. poff[p+1]   rows (avv, ave), sorted by value then thing
     dictionary   soff[i] .. soff[i+1]   the bytes of text s0+i in sblob; ssort: the ids sorted by text (part a only:
                  a run holds the texts interned between the run below it and itself)

   Every lookup is a rank, a binary search and the answer, on each run that holds the thing (the rank table says so
   with one bit) and on the delta; every count is exact. *)

type base = {
  pg : Pages.t;
  hot : Bytes.t array;  (* pg's hot table, here so that a read is one load less *)
  n : int;  (* rows *)
  ne : int;  (* thing ids 0 .. ne-1 in the rank table *)
  k : int;  (* things with rows *)
  np : int;  (* property ids 0 .. np-1 *)
  ns : int;  (* texts *)
  sblob : int;  (* bytes of all texts *)
  o_erank : int;
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
  len : int;  (* the end of the part's sections *)
  d0 : int;  (* every thing from d0 to ne - 1 is held: its slot is r0 + (e - d0), with no rank to read *)
  r0 : int;
}

type run = {
  a : base;  (* the facts it adds, and its texts *)
  t : base;  (* the facts of the runs below that it retracts *)
  lo : int;  (* the state it rests on: the runs below it hold groups 1..lo *)
  hi : int;  (* its last group *)
  level : int;  (* 1, 2, ...: level l holds at most compact_min * ratio^l rows *)
  s0 : int;  (* the id of its first text *)
}

let al x = (x + 7) land lnot 7
let blocks ne = (ne + 31) lsr 5

(* The sections of a part from offset [at], room for [n_cap] rows and [k_cap] things: a merge knows the counts only
   once it is done, so it lays a part out by upper bounds, and the bytes past the counts are never written (holes). *)
let layout ?(pg = Pages.empty) ~at ~n ~n_cap ~ne ~k ~k_cap ~np ~ns ~sblob () =
  let off = ref at in
  let sec bytes = let o = !off in off := al (!off + bytes); o in
  let o_erank = sec (8 * (blocks ne + 1)) in
  let o_eoff = sec (8 * (k_cap + 1)) in
  let o_eap = sec (2 * n_cap) in
  let o_eav = sec (8 * n_cap) in
  let o_poff = sec (8 * (np + 1)) in
  let o_avv = sec (8 * n_cap) in
  let o_ave = sec (4 * n_cap) in
  let o_pdist = sec (8 * np) in
  let o_soff = sec (8 * (ns + 1)) in
  let o_sblob = sec sblob in
  let o_ssort = sec (4 * ns) in
  { pg; hot = pg.Pages.hot; n; ne; k; np; ns; sblob; o_erank; o_eoff; o_eap; o_eav; o_poff; o_avv; o_ave; o_pdist; o_soff;
    o_sblob; o_ssort; len = !off; d0 = ne; r0 = k }

(* a part with nothing: every lookup answers at once, without a page *)
let nothing = layout ~at:0 ~n:0 ~n_cap:0 ~ne:0 ~k:0 ~k_cap:0 ~np:0 ~ns:0 ~sblob:0 ()

external get64u : Bytes.t -> int -> int64 = "%caml_bytes_get64u"
external get32u : Bytes.t -> int -> int32 = "%caml_bytes_get32u"
external get16u : Bytes.t -> int -> int = "%caml_bytes_get16u"

(* Two kinds of readers of the base's pages. A read of a hot page is one load and one comparison either way; they
   differ in what happens otherwise:
   - the raising readers (eoff, eap, ...) raise [Miss k]: a lookup that calls nothing (a binary search, a count, a
     membership test) is run by [safe] or its own wrapper again from its start once page k is in. With no call on
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
let[@inline] ci64 b o = Int64.to_int (get64u (framec b o) (o land Pages.mask))
let[@inline] cu32 b o = Int32.to_int (get32u (framec b o) (o land Pages.mask)) land 0xFFFFFFFF

(* the bits set in a 32-bit word (Warren, Hacker's Delight, 5-1) *)
let[@inline] popcount x =
  let x = x - ((x lsr 1) land 0x55555555) in
  let x = (x land 0x33333333) + ((x lsr 2) land 0x33333333) in
  let x = (x + (x lsr 4)) land 0x0F0F0F0F in
  ((x * 0x01010101) lsr 24) land 0xFF

(* the slot of thing e in the part, or -1: one word of the rank table; a block whose 32 things are all there needs no
   count *)
let[@inline] rank w e =
  let bits = w land 0xFFFFFFFF and i = e land 31 in
  if (bits lsr i) land 1 = 0 then -1
  else (w lsr 32) + if bits = 0xFFFFFFFF then i else popcount (bits land ((1 lsl i) - 1))

let[@inline] slot b e =
  if e >= b.d0 then (if e < b.ne then b.r0 + (e - b.d0) else -1)
  else if e < 0 then -1
  else rank (i64 b (b.o_erank + ((e lsr 5) lsl 3))) e

let[@inline] cslot b e =
  if e >= b.d0 then (if e < b.ne then b.r0 + (e - b.d0) else -1)
  else if e < 0 then -1
  else rank (ci64 b (b.o_erank + ((e lsr 5) lsl 3))) e
(* d0 and r0 of a part, from its rank table: the longest run of things held up to the end (a part made by a load or a
   full merge holds every thing above the property things: their lookups read no rank) *)
let dense b =
  if b.ne = 0 then b
  else begin
    let word j = ci64 b (b.o_erank + (j lsl 3)) in
    let d0 = ref b.ne and go = ref true and j = ref ((b.ne - 1) lsr 5) in
    while !go && !j >= 0 do
      let lo = !j lsl 5 in
      let hi = min b.ne (lo + 32) in
      let mask = (1 lsl (hi - lo)) - 1 in
      let bits = word !j land mask in
      if bits = mask then (d0 := lo; decr j)
      else begin
        (* the highest thing not held, in this block *)
        let x = ref (hi - lo - 1) in
        while (bits lsr !x) land 1 = 1 do decr x done;
        d0 := lo + !x + 1;
        go := false
      end
    done;
    let r0 = if !d0 >= b.ne then b.k else rank (word (!d0 lsr 5)) !d0 in
    { b with d0 = !d0; r0 }
  end

let[@inline] eoff b s = i64 b (b.o_eoff + (8 * s))
let[@inline] eap b i = let o = b.o_eap + (2 * i) in get16u (frame b o) (o land Pages.mask)
let[@inline] eav b i = i64 b (b.o_eav + (8 * i))
let[@inline] poff b p = i64 b (b.o_poff + (8 * p))
let[@inline] avv b i = i64 b (b.o_avv + (8 * i))
let[@inline] ave b i = u32 b (b.o_ave + (4 * i))
let[@inline] pdist b p = i64 b (b.o_pdist + (8 * p))
let[@inline] soff b i = i64 b (b.o_soff + (8 * i))
let[@inline] ssort b i = u32 b (b.o_ssort + (4 * i))
let[@inline] ceoff b s = ci64 b (b.o_eoff + (8 * s))
let[@inline] ceap b i = let o = b.o_eap + (2 * i) in get16u (framec b o) (o land Pages.mask)
let[@inline] ceav b i = ci64 b (b.o_eav + (8 * i))
let[@inline] cpoff b p = ci64 b (b.o_poff + (8 * p))
let[@inline] cavv b i = ci64 b (b.o_avv + (8 * i))
let[@inline] cave b i = cu32 b (b.o_ave + (4 * i))

(* [f b x] again until it misses no page; for a raising reader, or a lookup made of them *)
let rec safe f b x = match f b x with r -> ended r | exception Miss k -> fault b k; safe f b x

(* ---- One part alone ---- *)

(* the first row of the thing in slot s at or after (p, w). A binary search down to a window of 8 rows, then a
   scan: most things have a handful of facts, where the scan is the faster *)
let lower_e b s p w =
  let lo = ref (eoff b s) and hi = ref (eoff b (s + 1)) in
  while !hi - !lo > 8 do
    let mid = (!lo + !hi) lsr 1 in
    let p' = eap b mid in
    if p' < p || (p' = p && eav b mid < w) then lo := mid + 1 else hi := mid
  done;
  while !lo < !hi && (let p' = eap b !lo in p' < p || (p' = p && eav b !lo < w)) do incr lo done;
  !lo

let rec base_lower_e b s p w =
  match lower_e b s p w with r -> ended r | exception Miss k -> fault b k; base_lower_e b s p w

let base_iter_ea b e p f =
  let s = cslot b e in
  if s >= 0 then begin
    let i = ref (base_lower_e b s p min_int) and hi = ceoff b (s + 1) in
    while !i < hi && ceap b !i = p do
      f (ceav b !i);
      incr i
    done
  end

(* the rows of e for p: a scan of up to 8 rows after the first, a second search beyond *)
let count_ea b e p =
  let s = slot b e in
  if s < 0 then 0
  else begin
    let i = lower_e b s p min_int and hi = eoff b (s + 1) in
    let j = ref i in
    while !j < hi && !j - i < 8 && eap b !j = p do incr j done;
    if !j < hi && eap b !j = p then lower_e b s (p + 1) min_int - i else !j - i
  end

let rec base_count_ea b e p =
  if b.k = 0 then 0 else match count_ea b e p with r -> ended r | exception Miss k -> fault b k; base_count_ea b e p

let base_iter_e b e f =
  let s = cslot b e in
  if s >= 0 then
    for i = ceoff b s to ceoff b (s + 1) - 1 do
      f (ceap b i) (ceav b i)
    done

let mem_e b e p w =
  let s = slot b e in
  s >= 0
  && let i = lower_e b s p w in
     i < eoff b (s + 1) && eap b i = p && eav b i = w

let rec base_mem b e p w =
  b.k > 0 && match mem_e b e p w with r -> ended r | exception Miss k -> fault b k; base_mem b e p w

let rec base_has b e = b.k > 0 && match slot b e with s -> ended (s >= 0) | exception Miss k -> fault b k; base_has b e

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
  if b.n = 0 then 0 else match count_av b p w with r -> ended r | exception Miss k -> fault b k; base_count_av b p w

let base_iter_range b p lo hi f =
  if p >= 0 && p < b.np then begin
    let stop = cpoff b (p + 1) in
    let i = ref (base_lower b p lo) in
    while !i < stop && cavv b !i <= hi do
      f (cave b !i) (cavv b !i);
      incr i
    done
  end

let base_iter_p b p f =
  if p >= 0 && p < b.np then for i = cpoff b p to cpoff b (p + 1) - 1 do f (cave b i) (cavv b i) done

let count_range b p lo hi =
  if p < 0 || p >= b.np || lo > hi then 0
  else (if hi = max_int then poff b (p + 1) else lower b p (hi + 1)) - lower b p lo

let rec base_count_range b p lo hi =
  if b.n = 0 then 0
  else match count_range b p lo hi with r -> ended r | exception Miss k -> fault b k; base_count_range b p lo hi

let base_count_p b p = if p >= 0 && p < b.np && b.n > 0 then cpoff b (p + 1) - cpoff b p else 0
let base_pdist b p = if p >= 0 && p < b.np && b.n > 0 then safe pdist b p else 0

let[@inline] byte b o = Char.code (Bytes.unsafe_get (frame b o) (o land Pages.mask))

let text_r b i =
  let lo = b.o_sblob + soff b i in
  let n = (b.o_sblob + soff b (i + 1)) - lo in
  if (lo land Pages.mask) + n <= Pages.size then Bytes.sub_string (frame b lo) (lo land Pages.mask) n
  else String.init n (fun k -> Char.unsafe_chr (byte b (lo + k)))

let rec base_text b i = match text_r b i with r -> ended r | exception Miss k -> fault b k; base_text b i

(* compares s with the part's text i *)
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

let rec base_find_text b s =
  if b.ns = 0 then None else match find_text_r b s with r -> ended r | exception Miss k -> fault b k; base_find_text b s

let rec base_cmp b s i = match cmp_r b s i with r -> ended r | exception Miss k -> fault b k; base_cmp b s i

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

(* A change is a difference from the runs' state: [true], a fact they lack; [false], a fact of theirs retracted.
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
  runs : run array;  (* newest first *)
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

(* the id after the newest run's texts *)
let texts_end runs = if Array.length runs = 0 then 0 else runs.(0).s0 + runs.(0).a.ns

let of_runs ?(schema = Schema.initial) ~group ~next_e runs =
  let c0 = texts_end runs in
  { runs; delta = empty_delta; touched = { bits = Bytes.make 64 '\000' }; ftouched = Bytes.empty;
    dict = { chunks = new_chunks c0; dcount = c0; smap = SM.empty; extra = IM.empty; dnext = c0 };
    schema; group; next_e; writer = true }

let empty () = of_runs ~group:0 ~next_e:Schema.first_thing [||]

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
  if i >= v.dict.chunks.c0 then
    if i < v.dict.dcount then
      let k = i - v.dict.chunks.c0 in
      v.dict.chunks.arr.(k lsr chunk_bits).(k land ((1 lsl chunk_bits) - 1))
    else IM.find i v.dict.extra
  else begin
    (* the run whose texts start at or before i: runs are newest first, their texts in decreasing ranges *)
    let j = ref 0 in
    while v.runs.(!j).s0 > i do incr j done;
    let r = v.runs.(!j) in
    base_text r.a (i - r.s0)
  end

let find_text v s =
  match SM.find_opt s v.dict.smap with
  | Some i -> Some i
  | None ->
    let rs = v.runs in
    let r = ref None and j = ref 0 in
    while Option.is_none !r && !j < Array.length rs do
      (match base_find_text rs.(!j).a s with Some l -> r := Some (rs.(!j).s0 + l) | None -> ());
      incr j
    done;
    !r

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

(* The texts a large group adds: their ids, consecutive from the first returned, as [intern] would give them one
   after the other, but without their entries in the sorted map (the merge of the group, which follows at once, sorts
   the group's texts itself: Bulk.t.texts), and one new view for all. The view is for that merge. *)
let add_texts v (ss : string array) =
  let d = v.dict and n = Array.length ss in
  if v.writer then begin
    let c = d.chunks in
    if c.count > d.dcount then c.count <- d.dcount;
    let first = c.count in
    Array.iter
      (fun s ->
        let k = c.count - c.c0 in
        let ci = k lsr chunk_bits in
        if ci >= Array.length c.arr then begin
          let a = Array.make (max 4 (2 * Array.length c.arr)) [||] in
          Array.blit c.arr 0 a 0 (Array.length c.arr);
          c.arr <- a
        end;
        if Array.length c.arr.(ci) = 0 then c.arr.(ci) <- Array.make (1 lsl chunk_bits) "";
        c.arr.(ci).(k land ((1 lsl chunk_bits) - 1)) <- s;
        c.count <- c.count + 1)
      ss;
    { v with dict = { d with dcount = first + n; dnext = first + n } }, first
  end
  else begin
    let first = d.dnext and extra = ref d.extra in
    Array.iteri (fun k s -> extra := IM.add (first + k) s !extra) ss;
    { v with dict = { d with extra = !extra; dnext = first + n } }, first
  end

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

(* ---- The runs and the delta: what a reader sees ----
   One run alone (a base just merged, or every database that is not being written) reads as before, with no check.
   With several, a row of an older run is shown only if no newer run has an entry for the same fact (an entry there
   decides: it added it, and that run shows it, or it retracted it); the rank tables tell in one bit which runs hold
   a thing at all, so the check costs a few bit tests unless a newer run holds the same thing. *)

let thing_delta v e = if is_touched v e then IM.find_opt e v.delta.de else None

(* does a part hold rows of property p at all (two offsets, on a page every lookup of p reads) *)
let[@inline] has_p (b : base) p = b.n > 0 && p >= 0 && p < b.np && cpoff b (p + 1) > cpoff b p

(* the runs holding facts of thing e for property p, as bits: run j is bit j *)
let holders_p v e p =
  let rs = v.runs and m = ref 0 in
  for j = 0 to Array.length rs - 1 do
    let r = rs.(j) in
    if (has_p r.a p && base_has r.a e) || (has_p r.t p && base_has r.t e) then m := !m lor (1 lsl j)
  done;
  !m

(* the runs holding thing e, as bits: run j is bit j *)
let holders v e =
  let rs = v.runs and m = ref 0 in
  for j = 0 to Array.length rs - 1 do
    let r = rs.(j) in
    if base_has r.a e || base_has r.t e then m := !m lor (1 lsl j)
  done;
  !m

(* an entry for (e p w) in a run newer than j (h: the holders of e); loops, not closures: these run per row *)
let newer v h j e p w =
  h land ((1 lsl j) - 1) <> 0
  && begin
    let found = ref false and i = ref 0 in
    while (not !found) && !i < j do
      let r = v.runs.(!i) in
      (* a run with no row of p at all says no without a lookup by thing *)
      if (h lsr !i) land 1 = 1
         && ((base_count_p r.a p > 0 && base_mem r.a e p w) || (base_count_p r.t p > 0 && base_mem r.t e p w))
      then found := true;
      incr i
    done;
    !found
  end

(* is (e p w) in the state of the runs (the delta aside): the newest run with an entry decides *)
let runs_mem v e p w =
  let rs = v.runs in
  let n = Array.length rs in
  if n = 1 then base_mem rs.(0).a e p w
  else begin
    let r = ref 0 and j = ref 0 in
    while !r = 0 && !j < n do
      let x = rs.(!j) in
      if has_p x.a p && base_mem x.a e p w then r := 1 else if has_p x.t p && base_mem x.t e p w then r := 2;
      incr j
    done;
    !r = 1
  end

(* the delta's facts of thing e for property p, in value order *)
let iter_delta_ep (td : tdelta) p f =
  let rec go s = match s () with Seq.Cons (((p', w), add), s') when p' = p -> f w add; go s' | _ -> () in
  go (PW.to_seq_from (p, min_int) td.tf)

(* the one run of h when it has one bit, else -1 *)
let single h = if h <> 0 && h land (h - 1) = 0 then (let j = ref 0 in while (h lsr !j) land 1 = 0 do incr j done; !j) else -1

let iter_values v e p f =
  let rs = v.runs and td = thing_delta v e in
  if Option.is_none td && Array.length rs = 1 then base_iter_ea rs.(0).a e p f
  else begin
    (* only the runs with facts of p for e matter: a newer run with other facts of e shadows none of these *)
    let h = holders_p v e p in
    let one = single h in
    if Option.is_none td && one >= 0 then base_iter_ea rs.(one).a e p f
    else begin
      for j = 0 to Array.length rs - 1 do
        if (h lsr j) land 1 = 1 then
          base_iter_ea rs.(j).a e p (fun w ->
              if (match td with Some td -> not (PW.mem (p, w) td.tf) | None -> true) && not (newer v h j e p w) then f w)
      done;
      Option.iter (fun td -> iter_delta_ep td p (fun w add -> if add then f w)) td
    end
  end

(* every fact of e, in (property, value) order *)
let iter_facts v e f =
  let rs = v.runs and td = thing_delta v e in
  if Option.is_none td && Array.length rs = 1 then base_iter_e rs.(0).a e f
  else begin
    let h = holders v e in
    let one = single h in
    if Option.is_none td && one >= 0 then base_iter_e rs.(one).a e f
    else if Option.is_some td || h <> 0 then begin
      let l = ref [] in
      for j = 0 to Array.length rs - 1 do
        if (h lsr j) land 1 = 1 then
          base_iter_e rs.(j).a e (fun p w ->
              if (match td with Some td -> not (PW.mem (p, w) td.tf) | None -> true) && not (newer v h j e p w) then
                l := (p, w) :: !l)
      done;
      Option.iter (fun td -> PW.iter (fun pw add -> if add then l := pw :: !l) td.tf) td;
      List.iter (fun (p, w) -> f p w) (List.sort compare !l)
    end
  end

let delta_av v p w = match IM.find_opt p v.delta.dav with None -> None | Some pd -> IM.find_opt w pd.pm

(* a row (e p w) of run j, older runs and the delta aside: shown? *)
let[@inline] shown v j e p w = j = 0 || not (newer v (holders v e) j e p w)

let iter_things v p w f =
  let rs = v.runs in
  match delta_av v p w with
  | None when Array.length rs = 1 -> base_iter_av rs.(0).a p w f
  | vd ->
    for j = 0 to Array.length rs - 1 do
      base_iter_av rs.(j).a p w (fun e ->
          if (match vd with Some vd -> not (IM.mem e vd.vm) | None -> true) && shown v j e p w then f e)
    done;
    Option.iter (fun vd -> IM.iter (fun e add -> if add then f e) vd.vm) vd

let iter_prop v p f =
  let rs = v.runs in
  match IM.find_opt p v.delta.dav with
  | None when Array.length rs = 1 -> base_iter_p rs.(0).a p f
  | pd ->
    for j = 0 to Array.length rs - 1 do
      base_iter_p rs.(j).a p (fun e w ->
          let in_delta = match pd with
            | Some pd -> (match IM.find_opt w pd.pm with Some vd -> IM.mem e vd.vm | None -> false)
            | None -> false
          in
          if (not in_delta) && shown v j e p w then f e w)
    done;
    Option.iter (fun pd -> IM.iter (fun w vd -> IM.iter (fun e add -> if add then f e w) vd.vm) pd.pm) pd

(* the facts of p with lo <= value word <= hi (an order on values for the inline types) *)
let iter_range v p lo hi f =
  let rs = v.runs in
  match IM.find_opt p v.delta.dav with
  | None when Array.length rs = 1 -> base_iter_range rs.(0).a p lo hi f
  | pd ->
    for j = 0 to Array.length rs - 1 do
      base_iter_range rs.(j).a p lo hi (fun e w ->
          let in_delta = match pd with
            | Some pd -> (match IM.find_opt w pd.pm with Some vd -> IM.mem e vd.vm | None -> false)
            | None -> false
          in
          if (not in_delta) && shown v j e p w then f e w)
    done;
    match pd with
    | None -> ()
    | Some pd ->
      let rec go s =
        match s () with
        | Seq.Cons ((w, vd), s') when w <= hi -> IM.iter (fun e add -> if add then f e w) vd.vm; go s'
        | _ -> ()
      in
      if lo <= hi then go (IM.to_seq_from lo pd.pm)

let mem v e p w =
  match thing_delta v e with
  | Some td -> (match PW.find_opt (p, w) td.tf with Some add -> add | None -> runs_mem v e p w)
  | None -> runs_mem v e p w

(* exact counts: each run's rows minus its retractions, and the delta's net counts *)
let count_values v e p =
  let rs = v.runs in
  let n =
    if Array.length rs = 1 then base_count_ea rs.(0).a e p
    else begin
      let n = ref 0 in
      for j = 0 to Array.length rs - 1 do
        let r = rs.(j) in
        if has_p r.a p then n := !n + base_count_ea r.a e p;
        if has_p r.t p then n := !n - base_count_ea r.t e p
      done;
      !n
    end
  in
  n + match thing_delta v e with Some td -> Option.value (IM.find_opt p td.tn) ~default:0 | None -> 0

let has_value v e p = count_values v e p > 0

let count_things v p w =
  let rs = v.runs in
  let n =
    if Array.length rs = 1 then base_count_av rs.(0).a p w
    else begin
      let n = ref 0 in
      for j = 0 to Array.length rs - 1 do
        n := !n + base_count_av rs.(j).a p w - base_count_av rs.(j).t p w
      done;
      !n
    end
  in
  n + match delta_av v p w with Some vd -> vd.vn | None -> 0

let count_prop v p =
  let rs = v.runs and n = ref 0 in
  for j = 0 to Array.length rs - 1 do
    n := !n + base_count_p rs.(j).a p - base_count_p rs.(j).t p
  done;
  !n + match IM.find_opt p v.delta.dav with Some pd -> pd.pn | None -> 0

(* the facts of p in a range: exact on the runs, and the delta's part walked over the range only *)
let count_range v p lo hi =
  let rs = v.runs and n = ref 0 in
  for j = 0 to Array.length rs - 1 do
    n := !n + base_count_range rs.(j).a p lo hi - base_count_range rs.(j).t p lo hi
  done;
  (match IM.find_opt p v.delta.dav with
   | None -> ()
   | Some pd ->
     let rec go s = match s () with Seq.Cons ((w, vd), s') when w <= hi -> n := !n + vd.vn; go s' | _ -> () in
     if lo <= hi then go (IM.to_seq_from lo pd.pm));
  !n

(* an estimate for the planner: the distinct values of p, the runs' and the delta's (an upper bound) *)
let distinct v p =
  let rs = v.runs and n = ref 0 in
  for j = 0 to Array.length rs - 1 do n := !n + base_pdist rs.(j).a p done;
  max 1 (!n + match IM.find_opt p v.delta.dav with Some pd -> pd.pk | None -> 0)

(* ---- Changing a view ---- *)

let net = function Some true -> 1 | Some false -> -1 | None -> 0

(* st: Some true, (e p w) is added (not in the runs); Some false, removed (in the runs); None, as in the runs *)
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
    let inruns = runs_mem v e p w in
    let st = if add then (if inruns then None else Some true) else if inruns then Some false else None in
    change v e p w st

let max_thing v =
  Array.fold_left (fun m r -> max m (max r.a.ne r.t.ne - 1)) (v.next_e - 1) v.runs

let fork v =
  { v with writer = false; ftouched = (if Bytes.length v.ftouched = 0 then Bytes.empty else Bytes.copy v.ftouched) }

let facts v = Array.fold_left (fun n r -> n + r.a.n - r.t.n) v.delta.dnet v.runs

(* rows of a run: what the merge policy weighs *)
let run_rows r = r.a.n + r.t.n
