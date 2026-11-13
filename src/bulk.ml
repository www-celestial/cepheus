(* The facts of one large group, all of them additions, in the two orders of a run: by (thing, property, value) and by
   (property, value, thing), so that a merge reads them as it reads a run (Snapshot.merge), with no persistent map in
   between. They live in Bigarrays, outside the OCaml heap, which never scans or copies them: 14 bytes a fact in the
   group's order (thing 4, property 2, value 8) and 12 by property (value 8, thing 4), where OCaml arrays take 8 bytes
   a field. Sorting is linear: when the group does not come in thing order, a stable radix sort of its indexes by
   thing (LSD, 11-bit digits: Knuth, TAOCP vol. 3, 5.2.5) and an insertion sort by (property, value) inside each thing;
   then a counting sort by property and a stable radix sort by value inside each property, the two buffers of each
   pass used in turn (no copy back). The work is cut into chunks taken in turn by a few domains. *)

open Bigarray

type ints = (int, int_elt, c_layout) Array1.t
type i32 = (int32, int32_elt, c_layout) Array1.t
type u16 = (int, int16_unsigned_elt, c_layout) Array1.t

let ints n : ints = Array1.create Int C_layout n
let i32 n : i32 = Array1.create Int32 C_layout n
let u16 n : u16 = Array1.create Int16_unsigned C_layout n

(* ---- several domains ---- *)

(* the domains that share the work of a large group, the writer's own included: one a core (4 here), measured *)
let domains = ref (max 1 (min 4 (Domain.recommended_domain_count ())))

(* the operations of a chunk: a unit of work; tests make it small *)
let chunk = ref 65536

let chunks n = if n = 0 then 0 else ((n - 1) / !chunk) + 1

(* [parallel k f]: f 0 .. f (k-1), each once, taken in turn by up to [!domains] domains. The first exception stops
   the others at their next item and is raised once every domain has returned. *)
let parallel k f =
  let d = min !domains k in
  if d <= 1 then for i = 0 to k - 1 do f i done
  else begin
    let next = Atomic.make 0 and failed = Atomic.make None in
    let work () =
      let go = ref true in
      while !go do
        let i = Atomic.fetch_and_add next 1 in
        if i >= k || Option.is_some (Atomic.get failed) then go := false
        else
          match f i with
          | () -> ()
          | exception e -> ignore (Atomic.compare_and_set failed None (Some e)); go := false
      done
    in
    let ds = List.init (d - 1) (fun _ -> Domain.spawn work) in
    work ();
    List.iter Domain.join ds;
    match Atomic.get failed with Some e -> raise e | None -> ()
  end

(* ---- the facts ---- *)

type t = {
  n : int;  (* facts *)
  e : i32;  (* fact i: its thing, property and value word, in the group's order *)
  p : u16;
  w : ints;
  sorted : bool;  (* the group's order is by (thing, property, value) *)
  order : i32;  (* else: the fact indexes in that order *)
  poff : int array;  (* the rows of property p in pw, pe: poff.(p) .. poff.(p + 1) - 1 *)
  pw : ints;  (* by (p, w, e): the values *)
  pe : i32;  (* the things; bit 31 set: a fact only derived *)
  d0 : int;  (* facts d0 .. n-1 are only derived (a rule's, appended after the group's own) *)
}

(* fact index of row r in the order by thing *)
let[@inline] row b r = if b.sorted then r else Int32.to_int (Array1.unsafe_get b.order r)
let[@inline] thing b i = Int32.to_int (Array1.unsafe_get b.e i)
let[@inline] prop b i = Array1.unsafe_get b.p i
let[@inline] word b i = Array1.unsafe_get b.w i
let[@inline] pthing b r = Int32.to_int (Array1.unsafe_get b.pe r) land 0x7FFFFFFF
let[@inline] pword b r = Array1.unsafe_get b.pw r
let[@inline] derived b i = i >= b.d0
let[@inline] pderived b r = Int32.compare (Array1.unsafe_get b.pe r) 0l < 0

let empty =
  { n = 0; e = i32 0; p = u16 0; w = ints 0; sorted = true; order = i32 0; poff = [||]; pw = ints 0; pe = i32 0; d0 = 0 }

(* ---- by thing ---- *)

let[@inline] before (e : i32) (p : u16) (w : ints) j i =
  let a = Int32.to_int (Array1.unsafe_get e j) and b = Int32.to_int (Array1.unsafe_get e i) in
  a < b
  || a = b
     && (let x = Array1.unsafe_get p j and y = Array1.unsafe_get p i in
         x < y || (x = y && Array1.unsafe_get w j <= Array1.unsafe_get w i))

(* does the group come in (thing, property, value) order? (as a loader writes a thing's facts together) *)
let in_order e p w n =
  let ok = Atomic.make true in
  parallel (chunks n) (fun c ->
      let lo = max 1 (c * !chunk) and hi = min n ((c + 1) * !chunk) in
      let i = ref lo in
      while !i < hi && before e p w (!i - 1) !i do incr i done;
      if !i < hi then Atomic.set ok false);
  Atomic.get ok

let digit = 11

(* the fact indexes by (thing, property, value): a stable radix sort by thing, then an insertion sort inside each thing
   (a handful of rows). Each pass of the radix sort on several domains: every chunk counts its digits, the counts give
   each (digit, chunk) its first place in digit-then-chunk order, and every chunk scatters its rows from there: the
   same stable order as one domain's pass. *)
let by_thing (e : i32) (p : u16) (w : ints) n =
  let ord = i32 n and tmp = i32 n in
  if n > 0 then begin
    let nch = chunks n and ch = !chunk in
    let mins = Array.make nch max_int and maxs = Array.make nch min_int in
    parallel nch (fun c ->
        let mn = ref max_int and mx = ref min_int in
        for i = c * ch to min n ((c + 1) * ch) - 1 do
          Array1.unsafe_set ord i (Int32.of_int i);
          let x = Int32.to_int (Array1.unsafe_get e i) in
          if x < !mn then mn := x;
          if x > !mx then mx := x
        done;
        mins.(c) <- !mn;
        maxs.(c) <- !mx);
    let mn = Array.fold_left min max_int mins and mx = Array.fold_left max min_int maxs in
    let range = mx - mn and m = (1 lsl digit) - 1 in
    let cnt = Array.init nch (fun _ -> Array.make (1 lsl digit) 0) in
    let src = ref ord and dst = ref tmp and shift = ref 0 in
    while range lsr !shift > 0 do
      let s = !src and d = !dst and sh = !shift in
      parallel nch (fun c ->
          let k = cnt.(c) in
          Array.fill k 0 (Array.length k) 0;
          for r = c * ch to min n ((c + 1) * ch) - 1 do
            let x = ((Int32.to_int (Array1.unsafe_get e (Int32.to_int (Array1.unsafe_get s r))) - mn) lsr sh) land m in
            k.(x) <- k.(x) + 1
          done);
      (* digit by digit, chunk by chunk: each one's first place *)
      let at = ref 0 in
      for x = 0 to m do
        for c = 0 to nch - 1 do
          let k = cnt.(c).(x) in
          cnt.(c).(x) <- !at;
          at := !at + k
        done
      done;
      parallel nch (fun c ->
          let k = cnt.(c) in
          for r = c * ch to min n ((c + 1) * ch) - 1 do
            let i = Array1.unsafe_get s r in
            let x = ((Int32.to_int (Array1.unsafe_get e (Int32.to_int i)) - mn) lsr sh) land m in
            Array1.unsafe_set d k.(x) i;
            k.(x) <- k.(x) + 1
          done);
      src := d;
      dst := s;
      shift := !shift + digit
    done;
    let ord = !src in
    let th r = Int32.to_int (Array1.unsafe_get e (Int32.to_int (Array1.unsafe_get ord r))) in
    (* inside each thing, by (property, value): chunks of rows from the start of a thing to the start of another *)
    parallel nch (fun c ->
        let lo = c * ch and hi = min n ((c + 1) * ch) in
        (* this chunk's things: those that start in it *)
        let s = ref lo in
        while !s < hi && !s > 0 && th !s = th (!s - 1) do incr s done;
        while !s < hi do
          let t = ref (!s + 1) in
          while !t < n && th !t = th !s do incr t done;
          for r = !s + 1 to !t - 1 do
            let x = Array1.unsafe_get ord r in
            let j = ref (r - 1) in
            while !j >= !s && not (before e p w (Int32.to_int (Array1.unsafe_get ord !j)) (Int32.to_int x)) do
              Array1.unsafe_set ord (!j + 1) (Array1.unsafe_get ord !j);
              decr j
            done;
            Array1.unsafe_set ord (!j + 1) x
          done;
          s := !t
        done);
    ord
  end
  else ord

(* ---- by property ---- *)

(* a stable sort by value of the rows lo .. hi-1 of (pw, pe), with [tw], [te] (at least hi - lo rows) as room: LSD
   radix on the value minus the slice's smallest, each pass from one pair of buffers to the other *)
let radix (pw : ints) (pe : i32) lo hi (tw : ints) (te : i32) =
  let n = hi - lo in
  if n > 1 then begin
    let mn = ref max_int and mx = ref min_int in
    for r = lo to hi - 1 do
      let x = Array1.unsafe_get pw r in
      if x < !mn then mn := x;
      if x > !mx then mx := x
    done;
    let range = !mx - !mn in
    if range < 0 then begin
      (* values too far apart for one subtraction: a stable comparison sort *)
      let ix = Array.init n (fun r -> lo + r) in
      Array.stable_sort (fun a b -> compare (Array1.unsafe_get pw a) (Array1.unsafe_get pw b)) ix;
      for r = 0 to n - 1 do
        Array1.unsafe_set tw r (Array1.unsafe_get pw ix.(r));
        Array1.unsafe_set te r (Array1.unsafe_get pe ix.(r))
      done;
      Array1.blit (Array1.sub tw 0 n) (Array1.sub pw lo n);
      Array1.blit (Array1.sub te 0 n) (Array1.sub pe lo n)
    end
    else if range > 0 then begin
      let mn = !mn and m = (1 lsl digit) - 1 in
      let cnt = Array.make ((1 lsl digit) + 1) 0 in
      (* buffers as (values, things, first row) *)
      let a = ref (pw, pe, lo) and b = ref (tw, te, 0) and shift = ref 0 in
      while range lsr !shift > 0 do
        Array.fill cnt 0 (Array.length cnt) 0;
        let (sw, se, so), (dw, de, d0) = !a, !b in
        let sh = !shift in
        for r = so to so + n - 1 do
          let x = ((Array1.unsafe_get sw r - mn) lsr sh) land m in
          cnt.(x + 1) <- cnt.(x + 1) + 1
        done;
        cnt.(0) <- d0;
        for x = 1 to 1 lsl digit do cnt.(x) <- cnt.(x) + cnt.(x - 1) done;
        for r = so to so + n - 1 do
          let v = Array1.unsafe_get sw r in
          let x = ((v - mn) lsr sh) land m in
          let at = cnt.(x) in
          Array1.unsafe_set dw at v;
          Array1.unsafe_set de at (Array1.unsafe_get se r);
          cnt.(x) <- at + 1
        done;
        a := !b;
        b := (sw, se, so);
        shift := !shift + digit
      done;
      (* an odd number of passes leaves the rows in the room: back once *)
      let sw, se, so = !a in
      if sw != pw then begin
        Array1.blit (Array1.sub sw so n) (Array1.sub pw lo n);
        Array1.blit (Array1.sub se so n) (Array1.sub pe lo n)
      end
    end
  end

(* [make ~sorted ~order e p w n ~np]: the n facts sorted by property, value, thing (their order by thing given by
   [sorted] and [order], from [by_thing]); properties below np; facts [d0] .. n-1 only derived (none by default) *)
let make ?d0 ~sorted ~order e p w n ~np =
  let d0 = match d0 with Some d -> d | None -> n in
  let b0 = { n; e; p; w; sorted; order; poff = [||]; pw = ints 0; pe = i32 0; d0 } in
  (* the rows of each property in each chunk of the order by thing, so that the chunks are spread at once, each from
     its own place: a property's rows come in thing order *)
  let nch = max 1 (min (chunks n) (max 1 (n / (np + 1)))) in
  let size = if n = 0 then 1 else ((n - 1) / nch) + 1 in
  let cnt = Array.init nch (fun _ -> Array.make (np + 1) 0) in
  parallel nch (fun c ->
      let k = cnt.(c) in
      for r = c * size to min n ((c + 1) * size) - 1 do
        let q = prop b0 (row b0 r) in
        k.(q) <- k.(q) + 1
      done);
  let poff = Array.make (np + 1) 0 in
  for q = 0 to np - 1 do
    let t = ref 0 in
    for c = 0 to nch - 1 do t := !t + cnt.(c).(q) done;
    poff.(q + 1) <- poff.(q) + !t
  done;
  (* each chunk's first place for each property *)
  let at = Array.init nch (fun _ -> Array.make (np + 1) 0) in
  for q = 0 to np - 1 do
    let s = ref poff.(q) in
    for c = 0 to nch - 1 do
      at.(c).(q) <- !s;
      s := !s + cnt.(c).(q)
    done
  done;
  let pw = ints n and pe = i32 n in
  parallel nch (fun c ->
      let a = at.(c) in
      for r = c * size to min n ((c + 1) * size) - 1 do
        let i = row b0 r in
        let q = prop b0 i in
        let x = a.(q) in
        Array1.unsafe_set pw x (word b0 i);
        Array1.unsafe_set pe x (if i >= d0 then Int32.logor (Array1.unsafe_get e i) Int32.min_int else Array1.unsafe_get e i);
        a.(q) <- x + 1
      done);
  (* each property by value: the largest first, taken in turn; a domain's room is made for its first, the largest it
     will get *)
  let todo = Array.of_list (List.sort (fun a b -> compare (poff.(b + 1) - poff.(b)) (poff.(a + 1) - poff.(a))) (List.init np Fun.id)) in
  let next = Atomic.make 0 in
  let work () =
    let room = ref None and go = ref true in
    while !go do
      let k = Atomic.fetch_and_add next 1 in
      if k >= np then go := false
      else begin
        let q = todo.(k) in
        let len = poff.(q + 1) - poff.(q) in
        if len > 1 then begin
          let tw, te = match !room with
            | Some (tw, te) when Array1.dim tw >= len -> tw, te
            | _ -> let r = (ints len, i32 len) in room := Some r; r
          in
          radix pw pe poff.(q) poff.(q + 1) tw te
        end
      end
    done
  in
  (* two domains: the four largest properties of a load sort in about 40 ms, and each domain's room is the largest
     property's rows (27 MB at 2.27 M rows): more domains would save a few ms for that memory each *)
  let d = if n < 200_000 then 1 else min (min 2 !domains) np in
  let ds = List.init (d - 1) (fun _ -> Domain.spawn work) in
  work ();
  List.iter Domain.join ds;
  { b0 with poff; pw; pe }

(* [b] (a group's own facts) with the [nd] facts only derived from them appended (de, dp, dw): the facts in the
   group's order then the derived ones (the frame's order), and both orders made by merging the derived facts, sorted
   alone, into [b]'s, never by sorting all again. A derived fact is never one of [b]'s (the reasoner keeps only facts
   that are not there). *)
let add_derived (b : t) (de : i32) (dp : u16) (dw : ints) nd ~np =
  if nd = 0 then b
  else begin
    let n = b.n + nd in
    let e = i32 n and p = u16 n and w = ints n in
    let put a x = Array1.blit a (Array1.sub x 0 b.n) in
    put (Array1.sub b.e 0 b.n) e; put (Array1.sub b.p 0 b.n) p; put (Array1.sub b.w 0 b.n) w;
    Array1.blit de (Array1.sub e b.n nd);
    Array1.blit dp (Array1.sub p b.n nd);
    Array1.blit dw (Array1.sub w b.n nd);
    (* the derived facts alone, in both orders *)
    let dsorted = in_order de dp dw nd in
    let dorder = if dsorted then i32 0 else by_thing de dp dw nd in
    let d = make ~d0:0 ~sorted:dsorted ~order:dorder de dp dw nd ~np in
    (* by thing: the two orders merged, as indexes of the whole, in parts cut at the same things in both (each part's
       rows found by binary search), merged at once by several domains *)
    let order = i32 n in
    let ra r = row b r and rd r = b.n + (if dsorted then r else Int32.to_int (Array1.unsafe_get dorder r)) in
    let th i = Int32.to_int (Array1.unsafe_get e i) in
    (* the first row of each order whose thing is t or after *)
    let first_a t = let l = ref 0 and h = ref b.n in while !l < !h do let m = (!l + !h) lsr 1 in if th (ra m) < t then l := m + 1 else h := m done; !l in
    let first_d t = let l = ref 0 and h = ref nd in while !l < !h do let m = (!l + !h) lsr 1 in if th (rd m) < t then l := m + 1 else h := m done; !l in
    let parts = max 1 (min (4 * !domains) (n / !chunk)) in
    let cut_a = Array.make (parts + 1) b.n and cut_d = Array.make (parts + 1) nd in
    cut_a.(0) <- 0;
    cut_d.(0) <- 0;
    for q = 1 to parts - 1 do
      if b.n > 0 then begin
        let t = th (ra (q * b.n / parts)) in
        cut_a.(q) <- max cut_a.(q - 1) (first_a t);
        cut_d.(q) <- max cut_d.(q - 1) (first_d t)
      end
      else (cut_a.(q) <- 0; cut_d.(q) <- nd * q / parts)
    done;
    parallel parts (fun q ->
        let i = ref cut_a.(q) and j = ref cut_d.(q) in
        let ia = cut_a.(q + 1) and jd = cut_d.(q + 1) in
        for k = cut_a.(q) + cut_d.(q) to ia + jd - 1 do
          let take_a = !j >= jd || (!i < ia && before e p w (ra !i) (rd !j)) in
          if take_a then (Array1.unsafe_set order k (Int32.of_int (ra !i)); incr i)
          else (Array1.unsafe_set order k (Int32.of_int (rd !j)); incr j)
        done);
    (* by property: each property's rows of both, merged by (value, thing) *)
    let npb = Array.length b.poff - 1 and npd = Array.length d.poff - 1 in
    let np = max np (max npb npd) in
    let off (x : t) q = if q < Array.length x.poff then x.poff.(q) else x.n in
    let poff = Array.init (np + 1) (fun q -> off b q + off d q) in
    let pw = ints n and pe = i32 n in
    parallel np (fun q ->
        let a0 = off b q and a1 = off b (q + 1) and d0 = off d q and d1 = off d (q + 1) in
        let i = ref a0 and j = ref d0 in
        for k = poff.(q) to poff.(q + 1) - 1 do
          let take_a =
            !j >= d1
            || !i < a1
               && (let wa = pword b !i and wd = pword d !j in
                   wa < wd || (wa = wd && pthing b !i < pthing d !j))
          in
          if take_a then (Array1.unsafe_set pw k (pword b !i); Array1.unsafe_set pe k (Array1.unsafe_get b.pe !i); incr i)
          else (Array1.unsafe_set pw k (pword d !j); Array1.unsafe_set pe k (Array1.unsafe_get d.pe !j); incr j)
        done);
    { n; e; p; w; sorted = false; order; poff; pw; pe; d0 = b.n }
  end
