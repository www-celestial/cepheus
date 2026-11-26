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

(* An int's exact sums go first into plain ints, f1 and f2, while they cannot overflow (a value of at most 26 bits:
   its square of 52, a thousand of them before f2 moves into the limbs; f1 moves when an addition would overflow), so
   that most groups never touch the limbs and their result is a division of ints: [spilled] says whether the limbs
   hold anything *)
type sums = {
  mutable e1 : Exact.t option;  (* the limbs, made at the first spill: most groups never need them *)
  mutable e2 : Exact.t option;
  square : bool;  (* a variance's: the sum of the squares too *)
  mutable n : int;
  mutable nan : int;
  mutable pinf : int;
  mutable ninf : int;
  mutable f1 : int;
  mutable f2 : int;
  mutable k : int;  (* the squares in f2 *)
  mutable spilled : bool;
}

type state = Sums of sums | Bag of Bag.t

let is_new = function Wire.Count | Sum _ | Min _ | Max _ -> false | _ -> true

(* the variable an aggregate reads *)
let var_of = function
  | Wire.Count -> None
  | Sum x | Min x | Max x | Avg x | Distinct x | Values x | Quantile (x, _, _) | Variance (x, _) | Stddev (x, _) -> Some x

let name = function
  | Wire.Count -> "Count" | Sum _ -> "Sum" | Min _ -> "Min" | Max _ -> "Max" | Avg _ -> "Avg" | Distinct _ -> "Count"
  | Values _ -> "Values" | Quantile _ -> "Quantile" | Variance _ -> "Variance" | Stddev _ -> "Stddev"

let sums square =
  Sums { e1 = None; e2 = None; square; n = 0; nan = 0; pinf = 0; ninf = 0; f1 = 0; f2 = 0; k = 0; spilled = false }

let x1 s = match s.e1 with Some e -> e | None -> let e = Exact.create () in s.e1 <- Some e; e
let x2 s = match s.e2 with Some e -> e | None -> let e = Exact.create () in s.e2 <- Some e; e

let small = 1 lsl 26
let squares_max = 1000

(* f1 + b, or f1 into the limbs when that would overflow *)
let add_f1 s b =
  let r = s.f1 + b in
  if (s.f1 lxor r) land (b lxor r) < 0 then (Exact.add_int (x1 s) 1 s.f1; s.f1 <- b; s.spilled <- true) else s.f1 <- r

let add_int_sums s sign w =
  if w = min_int then (Exact.add_int (x1 s) sign w; s.spilled <- true) else add_f1 s (if sign > 0 then w else -w);
  if s.square then begin
    if w > -small && w < small then begin
      s.f2 <- s.f2 + (sign * (w * w));
      s.k <- s.k + 1;
      if s.k >= squares_max then (Exact.add_int (x2 s) 1 s.f2; s.f2 <- 0; s.k <- 0; s.spilled <- true)
    end
    else (Exact.add_square_int (x2 s) sign w; s.spilled <- true)
  end

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
let add_float_sums s sign f =
  if Float.is_nan f then s.nan <- s.nan + sign
  else if f = Float.infinity then s.pinf <- s.pinf + sign
  else if f = Float.neg_infinity then s.ninf <- s.ninf + sign
  else begin
    s.spilled <- true;
    Exact.add_float (x1 s) sign f;
    if s.square then Exact.add_square_float (x2 s) sign f
  end

let add (v : Store.view) (tx : Value.typ) st sign w =
  match st with
  | Bag b -> Bag.add b w sign
  | Sums s ->
    s.n <- s.n + sign;
    (match tx with
     | Tfloat -> add_float_sums s sign (Query.float_of_word v w)
     | _ -> add_int_sums s sign w);
    false

(* a value into exact sums, [add]'s of its word from the value itself (a report's computed cell, a window's row): an
   int, a date or money its int, a float its float; [sign] 1 (a row that comes) or -1 (one that goes) *)
let add_value s sign (x : Value.t) =
  s.n <- s.n + sign;
  match x with
  | Int w | Money w | Date w -> add_int_sums s sign w
  | Float f -> add_float_sums s sign f
  | _ -> invalid_arg "Agg.add_value"

(* fresh exact sums of the values themselves (no squares): a window's *)
let value_sums () = { e1 = None; e2 = None; square = false; n = 0; nan = 0; pinf = 0; ninf = 0; f1 = 0; f2 = 0; k = 0; spilled = false }

let merge a b =
  match a, b with
  | Bag x, Bag y -> Bag.merge x y
  | Sums x, Sums y ->
    (match y.e1 with Some e -> Exact.merge (x1 x) e | None -> ());
    (match y.e2 with Some e -> Exact.merge (x2 x) e | None -> ());
    add_f1 x y.f1;
    if x.k + y.k >= squares_max then (Exact.add_int (x2 x) 1 y.f2; x.spilled <- true) else (x.f2 <- x.f2 + y.f2; x.k <- x.k + y.k);
    if y.spilled then x.spilled <- true;
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
  | _ -> fun (a : int) b -> if a < b then -1 else if a > b then 1 else 0

(* a + (b - a) f rounded half away from zero, a <= b, as an int: b - a in floats when it passes the ints (a below 0,
   b above), whose rounding then keeps it within [a, b], clamped there so that no rounding gives a value outside the
   two (a float of 2^62 is no int) *)
let lerp_int a b f =
  if f = 0. then a
  else
    let d = b - a in
    if d >= 0 then a + Float.to_int (Float.round (float_of_int d *. f))
    else begin
      let x = Float.round (float_of_int a +. ((float_of_int b -. float_of_int a) *. f)) in
      if x <= float_of_int a then a else if x >= float_of_int b then b else Float.to_int x
    end

(* a group's different values, in Sort's order *)
let sorted_values (v : Store.view) (tx : Value.typ) st =
  match st with
  | Bag b -> let ks, _ = Bag.entries b in Array.stable_sort (order v tx) ks; ks
  | Sums _ -> invalid_arg "Agg.sorted_values"

(* the result of a group; Value.missing when it has none (a sample variance of one value) *)
(* the plain ints into the limbs: the exact path then reads only them *)
let settle s =
  if s.f1 <> 0 then (Exact.add_int (x1 s) 1 s.f1; s.f1 <- 0);
  if s.f2 <> 0 then Exact.add_int (x2 s) 1 s.f2;
  s.f2 <- 0;
  s.k <- 0;
  s.spilled <- true

let exact_float x = Float.abs x < 9007199254740992.

(* the quantile p of a group's values: its different words [ks] and their counts [cs], [n] values in all *)
let quantile ?cmp (v : Store.view) (tx : Value.typ) p discrete ks cs n : Value.t =
  if n <= 0 then Value.missing
  else begin
    let cmp = match cmp with Some c -> c | None -> order v tx in
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

let result (v : Store.view) (a : Wire.agg) (tx : Value.typ) st : Value.t =
  (* an int's group whose sums are plain ints: a division of exact operands, correctly rounded by IEEE 754 *)
  let fast =
    match a, st with
    | Wire.Avg _, Sums s when (not s.spilled) && s.n > 0 && tx <> Tfloat -> (
      let n = s.n in
      match tx with
      | Tint when exact_float (float_of_int s.f1) && Float.abs (float_of_int s.f1) < 9007199254740992. && abs s.f1 < 1 lsl 53 -> Some (Value.Float (float_of_int s.f1 /. float_of_int n))
      | Tmoney _ | Tdate ->
        let q = s.f1 / n and r = s.f1 mod n in
        let q = if 2 * abs r >= n then (if s.f1 < 0 then q - 1 else q + 1) else q in
        Some (if tx = Tdate then Value.Date q else Money q)
      | _ -> None)
    | (Wire.Variance (_, pop) | Stddev (_, pop)), Sums s when (not s.spilled) && tx <> Tfloat && s.n > 0 && (pop || s.n >= 2) ->
      let n = s.n in
      if abs s.f1 < 1 lsl 30 && n < 1 lsl 20 && s.f2 >= 0 && s.f2 < 1 lsl 41 then begin
        let num = (n * s.f2) - (s.f1 * s.f1) in
        let scale = match tx with Tmoney sc -> pow10.(sc) | _ -> 1 in
        let den = float_of_int (if pop then n * n else n * (n - 1)) *. float_of_int scale *. float_of_int scale in
        if num >= 0 && num < 1 lsl 53 && exact_float den then (let var = float_of_int num /. den in Some (Value.Float (match a with Stddev _ -> Float.sqrt var | _ -> var)))
        else None
      end
      else None
    | _ -> None
  in
  match fast with
  | Some x -> x
  | None ->
  (match st with Sums s -> settle s | Bag _ -> ());
  match a, st with
  | Wire.Avg _, Sums s ->
    if s.n <= 0 then Value.missing
    else begin
      match tx with
      | Tfloat when s.nan > 0 || (s.pinf > 0 && s.ninf > 0) -> Float Float.nan
      | Tfloat when s.pinf > 0 -> Float Float.infinity
      | Tfloat when s.ninf > 0 -> Float Float.neg_infinity
      | Tfloat | Tint -> let neg, m, e = Exact.value (x1 s) in Float (Exact.to_float ~neg m e [ s.n ])
      | Tmoney _ | Tdate ->
        let neg, m, e = Exact.value (x1 s) in
        let q = Exact.div_round ~neg (Exact.shift_limbs m e) s.n in
        if tx = Tdate then Date q else Money q
      | _ -> Value.missing
    end
  | (Variance (_, pop) | Stddev (_, pop)), Sums s ->
    let n = s.n in
    if n <= 0 || ((not pop) && n < 2) then Value.missing
    else if s.nan > 0 || s.pinf > 0 || s.ninf > 0 then Float Float.nan
    else begin
      let _, m1, b1 = Exact.value (x1 s) in
      let _, m2, b2 = Exact.value (x2 s) in
      (* n sum(x^2) - sum(x)^2, at the limb base min(b2, 2 b1) *)
      let b = min b2 (2 * b1) in
      let sq = Exact.shift_limbs (Exact.mul m1 m1) ((2 * b1) - b) and ns2 = Exact.shift_limbs (Exact.mul (Exact.of_int n) m2) (b2 - b) in
      let num = if Exact.compare_mag ns2 sq > 0 then Exact.sub ns2 sq else [||] in
      let divs = (if pop then [ n; n ] else [ n; n - 1 ]) @ (match tx with Tmoney sc when sc > 0 -> [ pow10.(sc); pow10.(sc) ] | _ -> []) in
      let var = Exact.to_float ~neg:false num b divs in
      Float (match a with Stddev _ -> Float.sqrt var | _ -> var)
    end
  | Distinct _, Bag b -> Int b.live
  | Quantile (_, p, discrete), Bag b -> let ks, cs = Bag.entries b in quantile v tx p discrete ks cs b.total
  | _ -> invalid_arg "Agg.result"

(* the exact sum of ints (money, dates) when it is an int of 63 bits, else None (a sum past them) *)
let sum_int s =
  if not s.spilled then Some s.f1
  else begin
    settle s;
    let neg, m, e = Exact.value (x1 s) in
    let m = Exact.shift_limbs m e in
    let b = Exact.bitlen m in
    (* min_int, -2^62, the one int whose magnitude has 63 bits *)
    if b = 63 && neg && Exact.compare_mag m (Exact.shift_left (Exact.of_int 1) 62) = 0 then Some min_int
    else if b > 62 then None
    else (let x = Array.fold_right (fun l acc -> (acc lsl Exact.bits) lor l) m 0 in Some (if neg then -x else x))
  end

(* ---- a plain Sum's word, checked (Count, Sum, Min and Max: Answer's tables of groups, Live's keys) ----
   A group's Sum of ints (money) is kept as OCaml adds ints, modulo 2^63, in its word, and the times it wrapped
   beside it: its carry, +1 an addition that passed the largest int, -1 one that passed the least, made only at the
   first (most reports never wrap). The exact sum is the word + carry 2^63: an Int exactly when the carry is 0, so a
   sum that passes 2^62 on the way and comes back is right, and one that ends past it is refused whatever the order
   of its rows and the domains that added them. An addition s + x wrapped when s and x have one sign and the result
   the other (Warren, Hacker's Delight, 2-13): [wrapped s x (s + x)], upward when x >= 0; a subtraction s - x when s
   and x have different signs and the result is not s's: [wrapped_sub s x (s - x)], upward when x < 0. *)
let[@inline] wrapped s x r = (s lxor r) land (x lxor r) < 0
let[@inline] wrapped_sub s x r = (s lxor x) land (s lxor r) < 0

(* a value of a key for a message: a long text cut *)
let short (x : Value.t) = let s = Value.to_string x in if String.length s > 64 then String.sub s 0 60 ^ "..." else s

(* a Sum past 63 bits refused: its variable's property, the values of its group's keys (none: the report's one
   group) *)
let past_sum name (keys : string list) =
  match keys with
  | [] -> Query.bad "Sum of %s passed the 63 bits of an Int: group by a key, or ask its Avg and Count (exact)" name
  | _ -> Query.bad "Sum of %s passed the 63 bits of an Int in the group %s: group by a finer key, or ask its Avg and Count (exact)" name (String.concat ", " keys)

(* the cells a bag's new value takes (its two words, the table at most half full) *)
let entry_cells = 4

(* ---- a group's row with its lists: one row a value (Values), the other cells repeated ---- *)

type cell = One of Value.t | Many of Value.t array

(* the rows of a group: as many as its longest list (one at least), a list's cell missing past its end *)
let flatten (cells : cell array) : Value.t array list =
  let n = Array.fold_left (fun m -> function Many a -> max m (Array.length a) | One _ -> m) 1 cells in
  List.init n (fun i -> Array.map (function One x -> x | Many a -> if i < Array.length a then a.(i) else Value.missing) cells)

(* ---- columns: one aggregate's state for every group of a table, in flat arrays (Answer's groups) ----
   A report's table of groups (Answer) holds an aggregate of protocol 9 as a column, a group's state at its number,
   so that a group costs no object of its own: the exact sums of an int, a date or money in four ints a group (n,
   f1, f2, k, as [sums] holds them while they are plain ints), a group's [state] made only when its sums would move
   into the limbs (an overflow, a thousand squares, a value of more than 26 bits) or for a float's (its exact sums from
   its first value); the bags of every group in one table of open addressing (linear probing), (group, word) ->
   count, with each group's different values and its values counted beside. Tables merge by groups, one table's
   numbers mapped onto the other's; a group's result is [result] of the same exact sums or of the same bag, so the
   same bit for bit. *)

type col = Csums of csums | Cbag of cbag

and csums = {
  csquare : bool;
  cfloat : bool;  (* a float's: a group's state from its first value *)
  mutable q : int array;  (* group g's n, f1, f2, k at 4 g *)
  mutable full : state option array;  (* group g's state once made *)
}

and cbag = {
  mutable be : int array;
      (* the entries, three words each, side by side (one cache line a probe): the group (-1: an empty slot), the word,
         its count *)
  mutable bused : int;
  mutable blive : int array;  (* group g's different values, in this table *)
  mutable btotal : int array;  (* group g's values, copies counted, its parts' too *)
  mutable parts : (cbag * int array) list;
      (* the tables merged into this one, each with its groups' numbers here: their entries are read with this one's
         at the end ([by_group]), not put again into this table one by one *)
  mutable own : Bag.t option array;
      (* a table a group, once the groups hold more than [!own_min] different values each on average (a city's
         thousands of totals): a group's next rows then probe a table of its own, in the cache, not one of the
         column's every value; [||] before *)
  mutable groups : int;  (* the groups the column has room for *)
}

(* the different values a group holds on average past which each group gets a table of its own, looked at when the
   column's table, of [own_from] entries or more, grows; the tests make them small *)
let own_min = ref 64
let own_from = ref 4096

(* the bag columns moved to a table a group so far: for the tests *)
let owned = Atomic.make 0

(* n empty entries of a bag column *)
let empty_entries n = let a = Array.make (3 * n) 0 in for i = 0 to n - 1 do a.(3 * i) <- -1 done; a

let col (a : Wire.agg) (tx : Value.typ) =
  match a with
  | Avg _ -> Csums { csquare = false; cfloat = tx = Tfloat; q = [||]; full = [||] }
  | Variance _ | Stddev _ -> Csums { csquare = true; cfloat = tx = Tfloat; q = [||]; full = [||] }
  | Distinct _ | Values _ | Quantile _ -> Cbag { be = empty_entries 16; bused = 0; blive = [||]; btotal = [||]; parts = []; own = [||]; groups = 0 }
  | Count | Sum _ | Min _ | Max _ -> invalid_arg "Agg.col"

let grow_ints (a : int array) n = if Array.length a >= n then a else (let b = Array.make (max n (2 * Array.length a)) 0 in Array.blit a 0 b 0 (Array.length a); b)

(* room for groups 0 to n - 1, a new one's state empty *)
let col_room c n =
  match c with
  | Csums s ->
    s.q <- grow_ints s.q (4 * n);
    if Array.length s.full < n then (let f = Array.make (max n (2 * Array.length s.full)) None in Array.blit s.full 0 f 0 (Array.length s.full); s.full <- f)
  | Cbag b ->
    b.blive <- grow_ints b.blive n;
    b.btotal <- grow_ints b.btotal n;
    if n > b.groups then b.groups <- n;
    if Array.length b.own > 0 && Array.length b.own < n then (let o = Array.make (max n (2 * Array.length b.own)) None in Array.blit b.own 0 o 0 (Array.length b.own); b.own <- o)

(* group g's state, made from its plain ints the first time *)
let full_of s g =
  match s.full.(g) with
  | Some st -> st
  | None ->
    let o = 4 * g in
    let st = Sums { e1 = None; e2 = None; square = s.csquare; n = s.q.(o); nan = 0; pinf = 0; ninf = 0; f1 = s.q.(o + 1); f2 = s.q.(o + 2); k = s.q.(o + 3); spilled = false } in
    s.full.(g) <- Some st;
    st

let bag_hash g w = let h = ((g * 0x2545F4914F6CDD1D) lxor w) * 0x2545F4914F6CDD1D in h lsr 17

let bag_grow b =
  let n = Array.length b.be / 3 in
  let size = 2 * n in
  let be = empty_entries size and m = size - 1 in
  for i = 0 to n - 1 do
    let g = b.be.(3 * i) in
    if g >= 0 then begin
      let w = b.be.((3 * i) + 1) in
      let j = ref (bag_hash g w land m) in
      while be.(3 * !j) >= 0 do j := (!j + 1) land m done;
      be.(3 * !j) <- g;
      be.((3 * !j) + 1) <- w;
      be.((3 * !j) + 2) <- b.be.((3 * i) + 2)
    end
  done;
  b.be <- be

(* the column's entries moved into a table a group ([own]) *)
let to_own b =
  let own = Array.make (max 1 (Array.length b.btotal)) None in
  let be = b.be in
  for i = 0 to (Array.length be / 3) - 1 do
    let g = be.(3 * i) in
    if g >= 0 then begin
      let t = match own.(g) with Some t -> t | None -> let t = Bag.create () in own.(g) <- Some t; t in
      ignore (Bag.add t be.((3 * i) + 1) be.((3 * i) + 2))
    end
  done;
  b.own <- own;
  b.be <- empty_entries 1;
  b.bused <- 0;
  Atomic.incr owned

(* [d] more copies (d > 0) of w in group g; true when it is a new entry: its cells *)
let rec bag_add b g w d =
  if Array.length b.own > 0 then begin
    let t = match b.own.(g) with Some t -> t | None -> let t = Bag.create () in b.own.(g) <- Some t; t in
    b.btotal.(g) <- b.btotal.(g) + d;
    let fresh = Bag.add t w d in
    if fresh then b.blive.(g) <- b.blive.(g) + 1;
    fresh
  end
  else begin
    let be = b.be in
    let m = (Array.length be / 3) - 1 in
    let i = ref (bag_hash g w land m) in
    while Array.unsafe_get be (3 * !i) >= 0 && (Array.unsafe_get be (3 * !i) <> g || Array.unsafe_get be ((3 * !i) + 1) <> w) do i := (!i + 1) land m done;
    let o = 3 * !i in
    if be.(o) >= 0 then (b.btotal.(g) <- b.btotal.(g) + d; be.(o + 2) <- be.(o + 2) + d; false)
    else if 2 * (b.bused + 1) > Array.length be / 3 && b.bused >= !own_from && b.bused > !own_min * max 1 b.groups then begin
      (* large groups: a table each, then this value *)
      to_own b;
      bag_add b g w d
    end
    else begin
      b.btotal.(g) <- b.btotal.(g) + d;
      be.(o) <- g;
      be.(o + 1) <- w;
      be.(o + 2) <- d;
      b.bused <- b.bused + 1;
      b.blive.(g) <- b.blive.(g) + 1;
      if 2 * b.bused > Array.length be / 3 then bag_grow b;
      true
    end
  end

(* a binding's word w of group g (a row that comes: Answer's); true when a bag gained an entry (its cells). An int's
   sums stay in the group's four ints while [add] would keep them plain; otherwise the group's state takes them *)
let has_state s g = match Array.unsafe_get s.full g with Some _ -> true | None -> false

let col_add (v : Store.view) (tx : Value.typ) c g w =
  match c with
  | Cbag b -> bag_add b g w 1
  | Csums s ->
    if s.cfloat || has_state s g then ignore (add v tx (full_of s g) 1 w)
    else begin
      let o = 4 * g and q = s.q in
      let f1 = q.(o + 1) in
      let r = f1 + w in
      if w = min_int || (f1 lxor r) land (w lxor r) < 0 || (s.csquare && (w <= - small || w >= small || q.(o + 3) + 1 >= squares_max)) then
        ignore (add v tx (full_of s g) 1 w)
      else begin
        q.(o) <- q.(o) + 1;
        q.(o + 1) <- r;
        if s.csquare then (q.(o + 2) <- q.(o + 2) + (w * w); q.(o + 3) <- q.(o + 3) + 1)
      end
    end;
    false

(* the groups of column [cb] into [ca]'s: group gb of b is group map.(gb) of a (room made for them) *)
let col_merge ca cb (map : int array) nb =
  match ca, cb with
  | Cbag a, Cbag b ->
    let map = Array.sub map 0 nb in
    for gb = 0 to nb - 1 do a.btotal.(map.(gb)) <- a.btotal.(map.(gb)) + b.btotal.(gb) done;
    a.parts <- ((b, map) :: List.map (fun (t, m) -> (t, Array.map (fun g -> map.(g)) m)) b.parts) @ a.parts
  | Csums a, Csums b ->
    for gb = 0 to nb - 1 do
      let ga = map.(gb) in
      if a.cfloat || has_state a ga || has_state b gb then merge (full_of a ga) (full_of b gb)
      else begin
        let oa = 4 * ga and ob = 4 * gb in
        let f1 = a.q.(oa + 1) and f1' = b.q.(ob + 1) in
        let r = f1 + f1' in
        if (f1 lxor r) land (f1' lxor r) < 0 || a.q.(oa + 3) + b.q.(ob + 3) >= squares_max then merge (full_of a ga) (full_of b gb)
        else begin
          a.q.(oa) <- a.q.(oa) + b.q.(ob);
          a.q.(oa + 1) <- r;
          a.q.(oa + 2) <- a.q.(oa + 2) + b.q.(ob + 2);
          a.q.(oa + 3) <- a.q.(oa + 3) + b.q.(ob + 3)
        end
      end
    done
  | _ -> invalid_arg "Agg.col_merge"

(* the entries of a bag column by group, for groups 0 to n - 1, this table's and its parts' (a word may then come
   once a part): group g's words and counts at off.(g) to off.(g + 1) - 1; by a count of each group's entries, then
   one pass a table, in the order of the tables' slots *)
let by_group c n =
  match c with
  | Cbag b ->
    let tables = (b, None) :: List.map (fun (t, m) -> (t, Some m)) b.parts in
    (* each entry of a table, its group here: [f g word count] *)
    let each f =
      List.iter
        (fun (t, m) ->
          let here g = match m with Some m -> m.(g) | None -> g in
          let be = t.be in
          for i = 0 to (Array.length be / 3) - 1 do
            let g = be.(3 * i) in
            if g >= 0 then f (here g) be.((3 * i) + 1) be.((3 * i) + 2)
          done;
          Array.iteri
            (fun g -> function
              | Some (bag : Bag.t) ->
                let g = here g in
                for i = 0 to Array.length bag.keys - 1 do if bag.cnt.(i) > 0 then f g bag.keys.(i) bag.cnt.(i) done
              | None -> ())
            t.own)
        tables
    in
    let off = Array.make (n + 1) 0 in
    each (fun g _ _ -> off.(g + 1) <- off.(g + 1) + 1);
    for g = 1 to n do off.(g) <- off.(g) + off.(g - 1) done;
    let at = Array.sub off 0 (max 1 n) and ks = Array.make off.(n) 0 and cs = Array.make off.(n) 0 in
    each (fun g w c -> ks.(at.(g)) <- w; cs.(at.(g)) <- c; at.(g) <- at.(g) + 1);
    off, ks, cs
  | Csums _ -> [||], [||], [||]

(* the different words of a group's entries (several parts may hold one), in [cmp]'s order *)
let distinct_sorted cmp (a : int array) =
  Array.stable_sort cmp a;
  let k = ref 0 in
  Array.iteri (fun i w -> if i = 0 || w <> a.(!k - 1) then (a.(!k) <- w; incr k)) a;
  if !k = Array.length a then a else Array.sub a 0 !k

let int_order (a : int) b = if a < b then -1 else if a > b then 1 else 0

(* group g's result ([by]: the column's [by_group]; [cmp]: the order of its type's words) *)
let col_result ?cmp (v : Store.view) (a : Wire.agg) (tx : Value.typ) c g (off, ks, cs) : Value.t =
  match c, a with
  | Csums s, _ -> result v a tx (full_of s g)
  | Cbag b, Wire.Distinct _ ->
    (match b.parts with
     | [] -> Int b.blive.(g)
     | _ -> let lo = off.(g) in Int (Array.length (distinct_sorted int_order (Array.sub ks lo (off.(g + 1) - lo)))))
  | Cbag b, Quantile (_, p, discrete) ->
    let lo = off.(g) in
    let n = off.(g + 1) - lo in
    quantile ?cmp v tx p discrete (Array.sub ks lo n) (Array.sub cs lo n) b.btotal.(g)
  | Cbag _, _ -> invalid_arg "Agg.col_result"

(* group g's different values, in Sort's order *)
let col_values cmp g (off, ks, _) = let lo = off.(g) in distinct_sorted cmp (Array.sub ks lo (off.(g + 1) - lo))
