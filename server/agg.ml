(* The aggregates of a report beyond Count, Sum, Min and Max (protocol 9): Avg, Count of the different values of a
   variable, Values, Quantile, Variance and Stddev; the same code at the server (Answer, Live) and in a program that
   reads locally.

   Exact sums (Avg, Variance, Stddev). A group's sum of its values and the sum of their squares are kept exactly, as
   integers of 30-bit limbs (an int, a date or money is its own integer; a float m 2^e, its mantissa m and exponent
   e, is the integer m at the binary place e: every float is a dyadic rational, so a sum of floats is one exactly,
   with no rounding at all), so that they add in any order, merge from several domains and subtract (a watch's row
   that goes) to the same integers, and the result, computed once from them, is the same bit for bit whatever the
   order of the rows or the number of domains: a watch's row is Find's. PostgreSQL does the same for its integer and
   numeric types (numeric_accum: N, sum(X) and sum(X^2) in numeric), and runs Youngs and Cramer's algorithm in
   floats for double precision, whose last digits depend on the order. Welford's update (1962) is not used: its
   result depends on the order of its inputs. The variance is (n sum(x^2) - sum(x)^2) / (n (n - 1)) (n^2 for the
   population's), its numerator exact, so it never cancels (the textbook one-pass formula in floats does, for values
   far from 0, as dates are), and divided once, rounded to the nearest float; Stddev its square root (IEEE 754's
   sqrt, correctly rounded). Limbs are added lazily: each of 63 bits holds 2^32 additions of 30-bit parts, carried
   every 2^30 additions.

   Bags (Count(x), Values, Quantile). A group's values, each different index word once with its count, in a table of
   open addressing (linear probing, the counts in a second array: no allocation an entry), so that a group of a
   million rows with a hundred different values holds a hundred entries; a watch's row that goes decrements its count
   (an entry at 0 stays until the table grows). Quantile: the k-th value counted with its copies, by selection
   (Hoare's FIND, CACM 1961, on the different values weighted by their counts: a three-way partition about the
   median of three, O(d) expected for d different values), a sort of the rest past 2 log2 d rounds (Musser's
   introselect, 1997), so that no input makes it quadratic. Values: the different values sorted, in Sort's order. *)

open Cepheus

(* ---- exact sums ---- *)

module Exact = struct
  let bits = 30
  let mask = (1 lsl bits) - 1

  (* sum of l.(i) 2^(30 (base + i)), each limb any int (carried lazily) *)
  type t = { mutable base : int; mutable l : int array; mutable pending : int }

  let create () = { base = 0; l = [||]; pending = 0 }

  (* limbs lo..hi (absolute) present *)
  let cover a lo hi =
    let n = Array.length a.l in
    if n = 0 then (a.base <- lo; a.l <- Array.make (hi - lo + 1) 0)
    else begin
      let top = a.base + n - 1 in
      if lo < a.base || hi > top then begin
        let nlo = min lo a.base and nhi = max hi top in
        let l = Array.make (nhi - nlo + 1) 0 in
        Array.blit a.l 0 l (a.base - nlo) n;
        a.base <- nlo;
        a.l <- l
      end
    end

  (* the limbs carried: each in [0, 2^30) but the last, 0 or -1 (its sign) *)
  let carry a =
    let n = Array.length a.l in
    if n > 0 then begin
      let r = Array.make (n + 3) 0 in
      let c = ref 0 in
      for i = 0 to n - 1 do
        let x = a.l.(i) + !c in
        r.(i) <- x land mask;
        c := x asr bits
      done;
      let x = !c in
      r.(n) <- x land mask;
      let x = x asr bits in
      r.(n + 1) <- x land mask;
      r.(n + 2) <- x asr bits;
      a.l <- r
    end;
    a.pending <- 0

  (* sign v 2^(30 pos), |v| < 2^62: its three parts *)
  let add_at a pos sign v =
    cover a pos (pos + 2);
    let i = pos - a.base in
    a.l.(i) <- a.l.(i) + (sign * (v land mask));
    a.l.(i + 1) <- a.l.(i + 1) + (sign * ((v asr bits) land mask));
    a.l.(i + 2) <- a.l.(i + 2) + (sign * (v asr (2 * bits)));
    a.pending <- a.pending + 1;
    if a.pending >= 1 lsl 30 then carry a

  (* sign v 2^(30 pos + r), |v| < 2^62, 0 <= r < 30 *)
  let add_shift a pos r sign v =
    if r = 0 then add_at a pos sign v
    else begin
      add_at a pos sign ((v land mask) lsl r);
      add_at a (pos + 1) sign ((v asr bits) lsl r)
    end

  (* an int as three limbs: d0, d1 in [0, 2^30), d2 in [-4, 3] *)
  let limbs x = [| x land mask; (x asr bits) land mask; x asr (2 * bits) |]

  let add_int a sign x = add_at a 0 sign x

  let add_square_int a sign x =
    let d = limbs x in
    for i = 0 to 2 do for j = 0 to 2 do add_at a (i + j) sign (d.(i) * d.(j)) done done

  (* a finite float as m 2^e, m an int of at most 53 bits *)
  let split f =
    let fr, ex = Float.frexp f in
    let m = Float.to_int (Float.ldexp fr 53) in
    m, ex - 53

  let fdiv a b = if a >= 0 then a / b else -(((-a) + b - 1) / b)

  let add_float a sign f =
    if f <> 0. then begin
      let m, e = split f in
      let q = fdiv e bits in
      add_shift a q (e - (bits * q)) sign m
    end

  let add_square_float a sign f =
    if f <> 0. then begin
      let m, e = split f in
      let d = limbs m in
      let p = 2 * e in
      let q = fdiv p bits in
      let r = p - (bits * q) in
      for i = 0 to 2 do for j = 0 to 2 do add_shift a (q + i + j) r sign (d.(i) * d.(j)) done done
    end

  let merge a b =
    let n = Array.length b.l in
    if n > 0 then begin
      cover a b.base (b.base + n - 1);
      let o = b.base - a.base in
      for i = 0 to n - 1 do a.l.(o + i) <- a.l.(o + i) + b.l.(i) done;
      a.pending <- a.pending + b.pending + 1;
      if a.pending >= 1 lsl 30 then carry a
    end

  (* ---- magnitudes: limbs in [0, 2^30), least first, no zero on top ---- *)

  let trim (m : int array) = let n = ref (Array.length m) in while !n > 0 && m.(!n - 1) = 0 do decr n done; Array.sub m 0 !n

  (* the value: negative, its magnitude, its base *)
  let value a =
    carry a;
    let r = a.l in
    let n = Array.length r in
    if n = 0 then false, [||], 0
    else if r.(n - 1) >= 0 then false, trim (Array.sub r 0 (n - 1)), a.base
    else begin
      (* V = S - B^(n-1), S the lower limbs: -V = B^(n-1) - S *)
      let m = Array.make n 0 in
      let c = ref 0 in
      for i = 0 to n - 2 do
        let x = - r.(i) + !c in
        m.(i) <- x land mask;
        c := x asr bits
      done;
      m.(n - 1) <- !c + 1;
      true, trim m, a.base
    end

  let mul (x : int array) (y : int array) =
    if Array.length x = 0 || Array.length y = 0 then [||]
    else begin
      let r = Array.make (Array.length x + Array.length y + 1) 0 in
      Array.iteri
        (fun i a ->
          let c = ref 0 in
          Array.iteri
            (fun j b ->
              let t = r.(i + j) + (a * b) + !c in
              r.(i + j) <- t land mask;
              c := t asr bits)
            y;
          let k = ref (i + Array.length y) in
          while !c <> 0 do
            let t = r.(!k) + !c in
            r.(!k) <- t land mask;
            c := t asr bits;
            incr k
          done)
        x;
      trim r
    end

  let of_int n = trim (limbs n)

  (* x B^k *)
  let shift_limbs x k = if Array.length x = 0 then x else Array.append (Array.make k 0) x

  let compare_mag x y =
    let a = Array.length x and b = Array.length y in
    if a <> b then compare a b
    else begin
      let i = ref (a - 1) in
      while !i >= 0 && x.(!i) = y.(!i) do decr i done;
      if !i < 0 then 0 else compare x.(!i) y.(!i)
    end

  (* x - y, x >= y *)
  let sub x y =
    let r = Array.copy x in
    let c = ref 0 in
    for i = 0 to Array.length r - 1 do
      let t = r.(i) - (if i < Array.length y then y.(i) else 0) + !c in
      r.(i) <- t land mask;
      c := t asr bits
    done;
    trim r

  let bitlen x =
    let n = Array.length x in
    if n = 0 then 0
    else begin
      let t = x.(n - 1) and b = ref 0 in
      while t lsr !b > 0 do incr b done;
      (bits * (n - 1)) + !b
    end

  (* x 2^k *)
  let shift_left x k =
    let q = k / bits and r = k mod bits in
    let x = shift_limbs x q in
    if r = 0 then x
    else begin
      let n = Array.length x in
      let y = Array.make (n + 1) 0 in
      for i = 0 to n - 1 do
        let t = x.(i) lsl r in
        y.(i) <- y.(i) lor (t land mask);
        y.(i + 1) <- t lsr bits
      done;
      trim y
    end

  (* x / d and its remainder, d in [1, 2^61): bit by bit from the top (only at the end of a group) *)
  let div_small x d =
    let n = Array.length x in
    let q = Array.make n 0 and r = ref 0 in
    for i = n - 1 downto 0 do
      let w = ref 0 in
      for b = bits - 1 downto 0 do
        r := (2 * !r) lor ((x.(i) lsr b) land 1);
        w := 2 * !w;
        if !r >= d then (r := !r - d; w := !w lor 1)
      done;
      q.(i) <- !w
    done;
    trim q, !r

  (* the nearest float to x 2^e / (d1 d2 ...), each divisor in [1, 2^61): the quotient taken to 55 bits at least
     and a sticky bit, rounded to 53 bits, ties to even *)
  let to_float ~neg x e divs =
    if Array.length x = 0 then 0.
    else begin
      let dbits = List.fold_left (fun s d -> s + bitlen (of_int d)) 0 divs in
      let k = max 0 (56 + dbits - bitlen x) in
      let q, sticky = List.fold_left (fun (q, s) d -> let q, r = div_small q d in q, s || r <> 0) (shift_left x k, false) divs in
      let lq = bitlen q in
      (* its top 55 bits, and whether any bit below them is set *)
      let drop = lq - 55 in
      let top = ref 0 and low = ref sticky in
      for b = lq - 1 downto 0 do
        let bit = (q.(b / bits) lsr (b mod bits)) land 1 in
        if b >= drop then top := (2 * !top) lor bit else if bit = 1 then low := true
      done;
      let m = !top lsr 2 and g = (!top lsr 1) land 1 and r = !top land 1 in
      let m = if g = 1 && (r = 1 || !low || m land 1 = 1) then m + 1 else m in
      let f = Float.ldexp (float_of_int m) (drop + 2 - k + (bits * e)) in
      if neg then -.f else f
    end

  (* x / d rounded to an int, half away from zero (x an int's sum: the quotient fits) *)
  let div_round ~neg x d =
    let q, r = div_small x d in
    let q = Array.fold_right (fun l acc -> (acc lsl bits) lor l) q 0 in
    let q = if 2 * r >= d then q + 1 else q in
    if neg then -q else q
end

(* ---- bags: a group's different index words, each with its count ---- *)

module Bag = struct
  type t = { mutable keys : int array; mutable cnt : int array; (* -1: an empty slot *) mutable used : int; mutable live : int; mutable total : int }

  let create () = { keys = Array.make 8 0; cnt = Array.make 8 (-1); used = 0; live = 0; total = 0 }

  let slot keys cnt w =
    let m = Array.length keys - 1 in
    let i = ref (((w * 0x2545F4914F6CDD1D) lsr 17) land m) in
    while cnt.(!i) >= 0 && keys.(!i) <> w do i := (!i + 1) land m done;
    !i

  let grow b =
    let size = if 2 * b.live >= Array.length b.keys / 2 then 2 * Array.length b.keys else Array.length b.keys in
    let keys = Array.make size 0 and cnt = Array.make size (-1) in
    for i = 0 to Array.length b.keys - 1 do
      if b.cnt.(i) > 0 then (let j = slot keys cnt b.keys.(i) in keys.(j) <- b.keys.(i); cnt.(j) <- b.cnt.(i))
    done;
    b.keys <- keys;
    b.cnt <- cnt;
    b.used <- b.live

  (* [d] more copies of w (d < 0: fewer); true when w was in no entry: a new one *)
  let add b w d =
    let i = slot b.keys b.cnt w in
    if b.cnt.(i) >= 0 || d > 0 then b.total <- b.total + d;
    if b.cnt.(i) >= 0 then begin
      let c = b.cnt.(i) in
      (* never below 0: -1 marks an empty slot, which would cut the probes of the words after it *)
      b.cnt.(i) <- max 0 (c + d);
      if c = 0 && c + d > 0 then b.live <- b.live + 1 else if c > 0 && c + d <= 0 then b.live <- b.live - 1;
      false
    end
    else if d <= 0 then false
    else begin
      b.keys.(i) <- w;
      b.cnt.(i) <- d;
      b.used <- b.used + 1;
      b.live <- b.live + 1;
      if 2 * b.used > Array.length b.keys then grow b;
      true
    end

  let merge a b = for i = 0 to Array.length b.keys - 1 do if b.cnt.(i) > 0 then ignore (add a b.keys.(i) b.cnt.(i)) done

  (* the entries of count above 0: words and counts *)
  let entries b =
    let ks = Array.make b.live 0 and cs = Array.make b.live 0 and k = ref 0 in
    for i = 0 to Array.length b.keys - 1 do
      if b.cnt.(i) > 0 then (ks.(!k) <- b.keys.(i); cs.(!k) <- b.cnt.(i); incr k)
    done;
    ks, cs
end

(* ---- selection: the value of rank k (from 0, copies counted) of words weighted by their counts ---- *)

let bitlen_int n = let b = ref 0 in while n lsr !b > 0 do incr b done; !b

let swap (a : int array) i j = let t = a.(i) in a.(i) <- a.(j); a.(j) <- t

(* sort ks.(lo..hi) with cs beside, by cmp *)
let sort_part cmp ks cs lo hi =
  let n = hi - lo + 1 in
  let idx = Array.init n (fun i -> lo + i) in
  Array.stable_sort (fun i j -> cmp ks.(i) ks.(j)) idx;
  let k2 = Array.map (fun i -> ks.(i)) idx and c2 = Array.map (fun i -> cs.(i)) idx in
  Array.blit k2 0 ks lo n;
  Array.blit c2 0 cs lo n

let select cmp (ks : int array) (cs : int array) k =
  let ks = Array.copy ks and cs = Array.copy cs in
  let lo = ref 0 and hi = ref (Array.length ks - 1) and k = ref k and rounds = ref (2 * (1 + bitlen_int (Array.length ks))) and found = ref None in
  while !found = None do
    if !hi - !lo < 16 || !rounds <= 0 then begin
      sort_part cmp ks cs !lo !hi;
      let i = ref !lo in
      while !k >= cs.(!i) do k := !k - cs.(!i); incr i done;
      found := Some ks.(!i)
    end
    else begin
      decr rounds;
      let mid = (!lo + !hi) / 2 in
      let a = ks.(!lo) and b = ks.(mid) and c = ks.(!hi) in
      let p = if cmp a b < 0 then (if cmp b c < 0 then b else if cmp a c < 0 then c else a) else if cmp a c < 0 then a else if cmp b c < 0 then c else b in
      (* three ways: [lo, lt) below p, [lt, i) equal, (gt, hi] above *)
      let lt = ref !lo and i = ref !lo and gt = ref !hi in
      while !i <= !gt do
        let x = cmp ks.(!i) p in
        if x < 0 then (swap ks !lt !i; swap cs !lt !i; incr lt; incr i)
        else if x > 0 then (swap ks !i !gt; swap cs !i !gt; decr gt)
        else incr i
      done;
      let below = ref 0 and equal = ref 0 in
      for j = !lo to !lt - 1 do below := !below + cs.(j) done;
      for j = !lt to !gt do equal := !equal + cs.(j) done;
      if !k < !below then hi := !lt - 1
      else if !k < !below + !equal then found := Some p
      else (k := !k - !below - !equal; lo := !gt + 1)
    end
  done;
  Option.get !found

(* ---- an aggregate of protocol 9 in a group ---- *)

type sums = { s1 : Exact.t; s2 : Exact.t option; mutable n : int; mutable nan : int; mutable pinf : int; mutable ninf : int }

type state = Sums of sums | Bag of Bag.t

let is_new = function Wire.Count | Sum _ | Min _ | Max _ -> false | _ -> true

(* the variable an aggregate reads *)
let var_of = function
  | Wire.Count -> None
  | Sum x | Min x | Max x | Avg x | Distinct x | Values x | Quantile (x, _, _) | Variance (x, _) | Stddev (x, _) -> Some x

let name = function
  | Wire.Count -> "Count" | Sum _ -> "Sum" | Min _ -> "Min" | Max _ -> "Max" | Avg _ -> "Avg" | Distinct _ -> "Count"
  | Values _ -> "Values" | Quantile _ -> "Quantile" | Variance _ -> "Variance" | Stddev _ -> "Stddev"

let sums square = Sums { s1 = Exact.create (); s2 = (if square then Some (Exact.create ()) else None); n = 0; nan = 0; pinf = 0; ninf = 0 }

let fresh = function
  | Wire.Avg _ -> sums false
  | Variance _ | Stddev _ -> sums true
  | Distinct _ | Values _ | Quantile _ -> Bag (Bag.create ())
  | Count | Sum _ | Min _ | Max _ -> invalid_arg "Agg.fresh"

(* the type of its result, from its variable's *)
let typ (a : Wire.agg) (tx : Value.typ) : Value.typ =
  match a with
  | Count | Distinct _ -> Tint
  | Sum _ | Min _ | Max _ | Values _ | Quantile (_, _, true) -> tx
  | Avg _ | Quantile (_, _, false) -> (match tx with Tint -> Tfloat | t -> t)
  | Variance _ | Stddev _ -> Tfloat

(* an aggregate of protocol 9 checked against its variable's type; [optional]: the variable is an Optional's, which
   may be missing (Count(x) and Values skip it; the others refuse it, as Sum does). Raises Query.Bad. *)
let check (a : Wire.agg) (tx : Value.typ) ~optional =
  let refuse_optional () =
    if optional then
      Query.bad "%s takes a variable of a pattern, not an Optional's, which may be missing: give its values, or Count(x) the different ones" (name a)
  in
  match a with
  | Wire.Count | Sum _ | Min _ | Max _ | Distinct _ | Values _ -> ()
  | Avg _ -> (
    refuse_optional ();
    match tx with Tint | Tfloat | Tmoney _ | Tdate -> () | t -> Query.bad "Avg is for ints, floats, money and dates, not a %s" (Value.typ_name t))
  | Variance _ | Stddev _ -> (
    refuse_optional ();
    match tx with
    | Tint | Tfloat | Tmoney _ -> ()
    | t -> Query.bad "%s is for ints, floats and money, not a %s" (name a) (Value.typ_name t))
  | Quantile (_, p, discrete) -> (
    refuse_optional ();
    if not (p >= 0. && p <= 1.) then Query.bad "Quantile's fraction is from 0 to 1, not %g" p;
    if not discrete then
      match tx with
      | Tint | Tfloat | Tmoney _ | Tdate -> ()
      | t -> Query.bad "Quantile between two values is for ints, floats, money and dates, not a %s: Quantile(x, p, discrete = true) takes one of the values" (Value.typ_name t))

(* a binding's word of the variable, [sign] 1 (a row that comes) or -1 (one that goes); true when a bag gained an
   entry (a new value: its cells) *)
let add (v : Store.view) (tx : Value.typ) st sign w =
  match st with
  | Bag b -> Bag.add b w sign
  | Sums s ->
    s.n <- s.n + sign;
    (match tx with
     | Tfloat ->
       let f = Query.float_of_word v w in
       if Float.is_nan f then s.nan <- s.nan + sign
       else if f = Float.infinity then s.pinf <- s.pinf + sign
       else if f = Float.neg_infinity then s.ninf <- s.ninf + sign
       else begin
         Exact.add_float s.s1 sign f;
         match s.s2 with Some s2 -> Exact.add_square_float s2 sign f | None -> ()
       end
     | _ -> (
       Exact.add_int s.s1 sign w;
       match s.s2 with Some s2 -> Exact.add_square_int s2 sign w | None -> ()));
    false

let merge a b =
  match a, b with
  | Bag x, Bag y -> Bag.merge x y
  | Sums x, Sums y ->
    Exact.merge x.s1 y.s1;
    (match x.s2, y.s2 with Some p, Some q -> Exact.merge p q | _ -> ());
    x.n <- x.n + y.n;
    x.nan <- x.nan + y.nan;
    x.pinf <- x.pinf + y.pinf;
    x.ninf <- x.ninf + y.ninf
  | _ -> invalid_arg "Agg.merge"

let pow10 = Array.init 19 (fun i -> let r = ref 1 in for _ = 1 to i do r := !r * 10 done; !r)

(* the order of a type's words, as Sort's: an inline value by its word, a float in totalOrder, a text by its bytes
   (each read once a call) *)
let order (v : Store.view) (tx : Value.typ) : int -> int -> int =
  match tx with
  | Tfloat -> fun a b -> if a = b then 0 else Value.total_order (Query.float_of_word v a) (Query.float_of_word v b)
  | Ttext ->
    let memo = Hashtbl.create 64 in
    let text w = match Hashtbl.find_opt memo w with Some s -> s | None -> let s = Store.text v w in Hashtbl.add memo w s; s in
    fun a b -> if a = b then 0 else String.compare (text a) (text b)
  | _ -> compare

(* a + (b - a) f rounded half away from zero, a <= b, as an int *)
let lerp_int a b f =
  if f = 0. then a
  else
    let d = b - a in
    if d >= 0 then a + Float.to_int (Float.round (float_of_int d *. f))
    else Float.to_int (Float.round (float_of_int a +. ((float_of_int b -. float_of_int a) *. f)))

(* a group's different values, in Sort's order *)
let sorted_values (v : Store.view) (tx : Value.typ) st =
  match st with
  | Bag b -> let ks, _ = Bag.entries b in Array.stable_sort (order v tx) ks; ks
  | Sums _ -> invalid_arg "Agg.sorted_values"

(* the result of a group; Value.missing when it has none (a sample variance of one value) *)
let result (v : Store.view) (a : Wire.agg) (tx : Value.typ) st : Value.t =
  match a, st with
  | Wire.Avg _, Sums s ->
    if s.n <= 0 then Value.missing
    else begin
      match tx with
      | Tfloat when s.nan > 0 || (s.pinf > 0 && s.ninf > 0) -> Float Float.nan
      | Tfloat when s.pinf > 0 -> Float Float.infinity
      | Tfloat when s.ninf > 0 -> Float Float.neg_infinity
      | Tfloat | Tint -> let neg, m, e = Exact.value s.s1 in Float (Exact.to_float ~neg m e [ s.n ])
      | Tmoney _ | Tdate ->
        let neg, m, e = Exact.value s.s1 in
        let q = Exact.div_round ~neg (Exact.shift_limbs m e) s.n in
        if tx = Tdate then Date q else Money q
      | _ -> Value.missing
    end
  | (Variance (_, pop) | Stddev (_, pop)), Sums s ->
    let n = s.n in
    if n <= 0 || ((not pop) && n < 2) then Value.missing
    else if s.nan > 0 || s.pinf > 0 || s.ninf > 0 then Float Float.nan
    else begin
      let _, m1, b1 = Exact.value s.s1 in
      let _, m2, b2 = Exact.value (match s.s2 with Some x -> x | None -> s.s1) in
      (* n sum(x^2) - sum(x)^2, at the limb base min(b2, 2 b1) *)
      let b = min b2 (2 * b1) in
      let sq = Exact.shift_limbs (Exact.mul m1 m1) ((2 * b1) - b) and ns2 = Exact.shift_limbs (Exact.mul (Exact.of_int n) m2) (b2 - b) in
      let num = if Exact.compare_mag ns2 sq > 0 then Exact.sub ns2 sq else [||] in
      let divs = (if pop then [ n; n ] else [ n; n - 1 ]) @ (match tx with Tmoney sc when sc > 0 -> [ pow10.(sc); pow10.(sc) ] | _ -> []) in
      let var = Exact.to_float ~neg:false num b divs in
      Float (match a with Stddev _ -> Float.sqrt var | _ -> var)
    end
  | Distinct _, Bag b -> Int b.live
  | Quantile (_, p, discrete), Bag b ->
    let n = b.total in
    if n <= 0 then Value.missing
    else begin
      let ks, cs = Bag.entries b in
      let cmp = order v tx in
      let at k = select cmp ks cs k in
      if discrete then (let k = max 1 (Float.to_int (Float.ceil (p *. float_of_int n))) in Store.value v tx (at (min n k - 1)))
      else begin
        (* Hyndman and Fan's definition 7, PostgreSQL's percentile_cont: h = p (n - 1), between the values of ranks
           floor h and ceil h *)
        let h = p *. float_of_int (n - 1) in
        let lo = Float.to_int (Float.floor h) and hi = Float.to_int (Float.ceil h) in
        let f = h -. Float.floor h in
        let x = at lo in
        let y = if hi = lo then x else at hi in
        match tx with
        | Tint -> if hi = lo then Float (float_of_int x) else (let a = float_of_int x and b = float_of_int y in Float (a +. ((b -. a) *. f)))
        | Tfloat ->
          let a = Query.float_of_word v x and b = Query.float_of_word v y in
          Float (if hi = lo then a else a +. ((b -. a) *. f))
        | Tmoney _ -> Money (if hi = lo then x else lerp_int x y f)
        | Tdate -> Date (if hi = lo then x else lerp_int x y f)
        | _ -> Value.missing
      end
    end
  | _ -> invalid_arg "Agg.result"

(* the cells a bag's new value takes (its two words, the table at most half full) *)
let entry_cells = 4

(* ---- a group's row with its lists: one row a value (Values), the other cells repeated ---- *)

type cell = One of Value.t | Many of Value.t array

(* the rows of a group: as many as its longest list (one at least), a list's cell missing past its end *)
let flatten (cells : cell array) : Value.t array list =
  let n = Array.fold_left (fun m -> function Many a -> max m (Array.length a) | One _ -> m) 1 cells in
  List.init n (fun i -> Array.map (function One x -> x | Many a -> if i < Array.length a then a.(i) else Value.missing) cells)
