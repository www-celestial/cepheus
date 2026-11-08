(* The facts of one large group, all of them additions, sorted the two ways a run is: by (thing, property, value) and
   by (property, value, thing), so that a merge reads them as it reads a run (Snapshot.merge), with no persistent map
   in between. Sorting is linear: a counting sort by thing (new things are numbered in order, so the range is the
   group's), a counting sort by property, and a stable radix sort by value inside each property (LSD, 11-bit digits:
   Knuth, TAOCP vol. 3, 5.2.5), on arrays of indexes. *)

type t = {
  n : int;  (* facts *)
  e : int array;
  p : int array;
  w : int array;
  by_thing : int array;  (* indexes, by (e, p, w) *)
  poff : int array;  (* the rows of property p in pw, pe, pi: poff.(p) .. poff.(p + 1) - 1 *)
  pw : int array;  (* by (p, w, e): the values *)
  pe : int array;  (* the things *)
  pi : int array;  (* the indexes *)
  texts : (string * int) array;  (* the texts the group adds, with their ids, in text order *)
}

let digit = 11

(* a stable sort of the slice lo .. hi-1 of the arrays (w, e, i) by w, the room (tw, te, ti) at the same places *)
let radix3 (w : int array) (e : int array) (i : int array) lo hi (tw : int array) (te : int array) (ti : int array) =
  let n = hi - lo in
  if n > 1 then begin
    let mn = ref max_int and mx = ref min_int in
    for r = lo to hi - 1 do
      let x = w.(r) in
      if x < !mn then mn := x;
      if x > !mx then mx := x
    done;
    let range = !mx - !mn in
    if range < 0 || (range > 0 && n <= 32) then begin
      (* keys too far apart for one subtraction, or a few rows: a comparison sort, stable *)
      let ix = Array.init n (fun r -> lo + r) in
      Array.stable_sort (fun a b -> compare w.(a) w.(b)) ix;
      for r = 0 to n - 1 do tw.(lo + r) <- w.(ix.(r)); te.(lo + r) <- e.(ix.(r)); ti.(lo + r) <- i.(ix.(r)) done;
      Array.blit tw lo w lo n; Array.blit te lo e lo n; Array.blit ti lo i lo n
    end
    else if range > 0 then begin
      let mn = !mn and m = (1 lsl digit) - 1 in
      let cnt = Array.make ((1 lsl digit) + 1) 0 in
      let shift = ref 0 in
      while range lsr !shift > 0 do
        Array.fill cnt 0 (Array.length cnt) 0;
        let sh = !shift in
        for r = lo to hi - 1 do
          let d = ((w.(r) - mn) lsr sh) land m in
          cnt.(d + 1) <- cnt.(d + 1) + 1
        done;
        cnt.(0) <- lo;
        for d = 1 to 1 lsl digit do cnt.(d) <- cnt.(d) + cnt.(d - 1) done;
        for r = lo to hi - 1 do
          let x = w.(r) in
          let d = ((x - mn) lsr sh) land m in
          let a = cnt.(d) in
          tw.(a) <- x; te.(a) <- e.(r); ti.(a) <- i.(r);
          cnt.(d) <- a + 1
        done;
        Array.blit tw lo w lo n; Array.blit te lo e lo n; Array.blit ti lo i lo n;
        shift := !shift + digit
      done
    end
  end

(* [make e p w n np]: the first n facts (e.(i), p.(i), w.(i)) sorted both ways, properties below np; [texts]: the
   texts the group adds (sorted here) *)
let make ?(texts = [||]) e p w n ~np =
  let emin = ref max_int and emax = ref min_int in
  for i = 0 to n - 1 do
    if e.(i) < !emin then emin := e.(i);
    if e.(i) > !emax then emax := e.(i)
  done;
  let by_thing = Array.make n 0 and tmp = Array.make n 0 in
  if n > 0 then begin
    (* by thing: counting sort; then by (p, w) inside a thing, a handful of rows: insertion sort *)
    let lo = !emin in
    let cnt = Array.make (!emax - lo + 2) 0 in
    for i = 0 to n - 1 do cnt.(e.(i) - lo + 1) <- cnt.(e.(i) - lo + 1) + 1 done;
    for x = 1 to Array.length cnt - 1 do cnt.(x) <- cnt.(x) + cnt.(x - 1) done;
    for i = 0 to n - 1 do
      let x = e.(i) - lo in
      by_thing.(cnt.(x)) <- i;
      cnt.(x) <- cnt.(x) + 1
    done;
    let less i j = p.(i) < p.(j) || (p.(i) = p.(j) && w.(i) < w.(j)) in
    let s = ref 0 in
    while !s < n do
      let t = ref (!s + 1) in
      while !t < n && e.(by_thing.(!t)) = e.(by_thing.(!s)) do incr t done;
      for i = !s + 1 to !t - 1 do
        let x = by_thing.(i) in
        let j = ref (i - 1) in
        while !j >= !s && less x by_thing.(!j) do by_thing.(!j + 1) <- by_thing.(!j); decr j done;
        by_thing.(!j + 1) <- x
      done;
      s := !t
    done
  end;
  (* by property: a stable counting sort of the by-thing order by p, so that a value's things come in order, into
     arrays of the values, things and indexes themselves, so that the radix sort and the merge after it read them in
     order; then a stable radix sort by value inside each property, the properties shared among a few domains *)
  let poff = Array.make (np + 1) 0 in
  for i = 0 to n - 1 do poff.(p.(i) + 1) <- poff.(p.(i) + 1) + 1 done;
  for x = 1 to np do poff.(x) <- poff.(x) + poff.(x - 1) done;
  let pw = Array.make n 0 and pe = Array.make n 0 and pi = Array.make n 0 and at = Array.copy poff in
  for r = 0 to n - 1 do
    let x = by_thing.(r) in
    let q = p.(x) in
    let a = at.(q) in
    pw.(a) <- w.(x); pe.(a) <- e.(x); pi.(a) <- x;
    at.(q) <- a + 1
  done;
  let tw = tmp and te = Array.make n 0 and ti = Array.make n 0 in
  let sort q = radix3 pw pe pi poff.(q) poff.(q + 1) tw te ti in
  let order = List.sort (fun a b -> compare (poff.(b + 1) - poff.(b)) (poff.(a + 1) - poff.(a))) (List.init np Fun.id) in
  if n < 200_000 then List.iter sort order
  else begin
    (* the largest properties first, taken in turn: their slices are apart, so are the slices of the room *)
    let todo = Array.of_list order and next = Atomic.make 0 in
    let work () = let go = ref true in
      while !go do let k = Atomic.fetch_and_add next 1 in if k >= Array.length todo then go := false else sort todo.(k) done in
    let doms = List.init 3 (fun _ -> Domain.spawn work) in
    work ();
    List.iter Domain.join doms
  end;
  Array.sort (fun (a, _) (b, _) -> compare a b) texts;
  { n; e; p; w; by_thing; poff; pw; pe; pi; texts }
