(* Questions: patterns [thing, property, value] whose thing and value are constants or variables, answered by Generic
   Join (Ngo, Re, Rudra 2013): one variable at a time, in an order chosen from the index counts; for each variable,
   the pattern that offers the fewest candidates (exact counts, read from the indexes for the bindings so far) gives
   them, and every other pattern on that variable keeps or drops each one with an index lookup. The work stays within
   the AGM bound of the question (Atserias, Grohe, Marx 2008) up to the cost of a lookup; on a chain of patterns it
   is the plain nested index lookup. Each binding comes out once (G11; proof in docs/book/theory.md). *)

(* min and max of ints: Stdlib's are polymorphic, a call to the C comparison each time *)
let[@inline] min (a : int) b = if a <= b then a else b
let[@inline] max (a : int) b = if a >= b then a else b

type term = Var of int | Thing of int | Val of Value.t

type pattern = { e : term; p : int; v : term }

type t = { vars : int; where : pattern list; ranges : (int * Value.t * Value.t) list }
(** [ranges]: [(x, lo, hi)] keeps the bindings with lo <= x <= hi (an int, a date or money). *)

exception No_answer
exception Bad of string

(* a question that passed its budget of candidates (a server's bound: Core.question_budget) *)
exception Over_budget of int

let bad fmt = Printf.ksprintf (fun s -> raise (Bad s)) fmt

(* internal form: each side a variable or a word *)
type side = V of int | W of int
type pat = { pe : side; pp : int; pv : side; many : bool }

let typ_of (v : Store.view) p = match Schema.find v.schema p with Some d -> d | None -> bad "no property %d" p

(* the type of each variable, from where it appears *)
let types (v : Store.view) q =
  let ty = Array.make q.vars None in
  let set x t =
    if x < 0 || x >= q.vars then bad "variable %d out of range" x;
    match ty.(x) with
    | None -> ty.(x) <- Some t
    | Some t' -> if t' <> t then bad "variable %d is both a %s and a %s" x (Value.typ_name t') (Value.typ_name t)
  in
  List.iter
    (fun pt ->
      let d = typ_of v pt.p in
      (match pt.e with Var x -> set x Value.Tlink | _ -> ());
      match pt.v with Var x -> set x d.typ | _ -> ())
    q.where;
  Array.mapi (fun i -> function Some t -> t | None -> bad "variable %d appears in no pattern" i) ty

(* A thing named by a question is read as its class's representative (the reasoner design, section 5.10): facts are
   kept on the representative, [x cepheus/same r] holds when x is not one *)
(* does the view hold any fact of cepheus/same: known for the newest view asked (its runs and the delta's entry of the
   property), so that a read of a database without equality pays a pointer comparison, not a count over the runs *)
let same_slot : (Store.run array * Store.stamp * bool) option Atomic.t = Atomic.make None

let any_same (v : Store.view) =
  let st = Store.stamp v Schema.p_same (-1) in
  match Atomic.get same_slot with
  | Some (runs, st', b) when runs == v.runs && Store.same_stamp st st' -> b
  | _ -> let b = Store.count_prop v Schema.p_same > 0 in Atomic.set same_slot (Some (v.runs, st, b)); b

let rep (v : Store.view) x =
  if x < Schema.first_thing || not (any_same v) then x
  else (let r = ref x in Store.iter_values v x Schema.p_same (fun w -> r := w); !r)

let compile (v : Store.view) q =
  let ty = types v q in
  let side = function
    | Var x -> V x
    | Thing e -> W (rep v e)
    | Val (Value.Link l) -> W (rep v l)
    | Val x -> (match Store.word v x with Some w -> W w | None -> raise No_answer)
  in
  let pats =
    List.map
      (fun pt ->
        let d = typ_of v pt.p in
        (match pt.v with Val x when not (Value.has_type d.typ x) -> bad "%s is not a %s" (Value.to_string x) (Value.typ_name d.typ) | _ -> ());
        { pe = side pt.e; pp = pt.p; pv = side pt.v; many = d.many })
      q.where
  in
  let ranges =
    List.map
      (fun (x, lo, hi) ->
        if x < 0 || x >= q.vars || not (Value.inline ty.(x)) then bad "a range needs an int, date or money variable";
        match Store.word v lo, Store.word v hi with
        | Some a, Some b -> x, a, b
        | _ -> raise No_answer)
      q.ranges
  in
  ty, pats, ranges

let has x = function V y -> x = y | W _ -> false

(* The interval of each variable: its ranges together, or None. *)
let intervals nvars ranges =
  let r = Array.make nvars None in
  List.iter
    (fun (x, lo, hi) -> r.(x) <- Some (match r.(x) with None -> lo, hi | Some (a, b) -> max a lo, min b hi))
    ranges;
  r

(* The order of the variables, and its cost: the candidates its levels are estimated to enumerate. At each level,
   the partial bindings so far times the next variable's candidates per binding, [est x bound]: the least count that
   x's patterns offer it given the variables bound (the bits of [bound]): a word on the other side, or a bound
   variable, gives the exact count or the average per value, an unbound one the property's whole count. The partial
   bindings of a set of variables are the same whatever order bound them, so they are estimated once a set: the
   smallest product of candidates per binding over the orders of the set (each product bounds them from above). The
   cost of the best order of a set is then that of the best order of the set less one variable, plus that variable's
   step: a dynamic program over the subsets, as Selinger et al. 1979 choose an order of joins, exact for this cost.

   Two kinds of variables have a place known before the program, and are left out of it: a variable whose only
   pattern has no other variable and offers it at most one candidate (a value of a thing given by its id) comes first,
   where it costs 1 and multiplies nothing; a variable whose only pattern gives it as the one value of a thing's
   one-valued property, of 2 or more values in all (an invoice's status, its total), comes right after that thing: it
   multiplies nothing then (1 candidate); exact when the thing's count does not depend on it, within a factor 2
   otherwise (docs/book/theory.md, section 4). So a star of fields (a row's columns) is a program of one variable.
   The program runs over the others, at most [dp_max] of them ([dp_max] 2^([dp_max] - 1) steps); beyond, the
   variable of fewest candidates next (greedy). The counts are read once a question, at most one entry a pair of variables however many
   patterns the question has. *)
let dp_max = 12

let order ?(sets = []) (v : Store.view) nvars pats ranges =
  let iv = intervals nvars ranges in
  let base = Array.make nvars max_int and has_set = Array.make nvars false in
  List.iter (fun (x, a) -> base.(x) <- min base.(x) (Array.length a); has_set.(x) <- true) sets;
  (* each pattern's offers: to x, (y, kn, un) the count when the variable y on its other side is bound, and when it
     is not; a word on the other side (or x itself) gives its count to [base] *)
  let offers = Array.make nvars [] and npat = Array.make nvars 0 and parent = Array.make nvars (-1) in
  let offer x y k u = if y < 0 then (if k < base.(x) then base.(x) <- k) else offers.(x) <- (y, k, u) :: offers.(x) in
  List.iter
    (fun pt ->
      match pt.pe, pt.pv with
      | V x, V y when x = y -> npat.(x) <- npat.(x) + 1; offer x (-1) (Store.count_prop v pt.pp) 0
      | pe, pv ->
        (match pe, pv with
         | V x, W w -> npat.(x) <- npat.(x) + 1; offer x (-1) (Store.count_things v pt.pp w) 0
         | V x, V y -> let all = Store.count_prop v pt.pp in npat.(x) <- npat.(x) + 1; offer x y (max 1 (all / Store.distinct v pt.pp)) all
         | W _, _ -> ());
        (match pe, pv with
         | W e, V y -> npat.(y) <- npat.(y) + 1; offer y (-1) (Store.count_values v e pt.pp) 0
         | V x, V y ->
           let un =
             match iv.(y) with
             | None -> Store.distinct v pt.pp
             | Some (lo, hi) ->
               let all = max 1 (Store.count_prop v pt.pp) in
               max 1 (Store.count_range v pt.pp lo hi * Store.distinct v pt.pp / all)
           in
           npat.(y) <- npat.(y) + 1;
           if not pt.many then parent.(y) <- x;
           offer y x (if pt.many then 4 else 1) un
         | _, W _ -> ()))
    pats;
  (* one entry a variable on the other side, its least counts *)
  let oth = Array.make nvars [||] and kn = Array.make nvars [||] and un = Array.make nvars [||] in
  for x = 0 to nvars - 1 do
    let l = List.sort compare offers.(x) in
    let rec merge = function
      | (y, k, u) :: (y', k', u') :: t when y = y' -> merge ((y, min k k', min u u') :: t)
      | e :: t -> e :: merge t
      | [] -> []
    in
    let l = Array.of_list (merge l) in
    oth.(x) <- Array.map (fun (y, _, _) -> y) l;
    kn.(x) <- Array.map (fun (_, k, _) -> k) l;
    un.(x) <- Array.map (fun (_, _, u) -> u) l
  done;
  let est x bound =
    let o = oth.(x) and k = kn.(x) and u = un.(x) and best = ref base.(x) in
    for j = 0 to Array.length o - 1 do
      let c = if bound land (1 lsl Array.unsafe_get o j) <> 0 then Array.unsafe_get k j else Array.unsafe_get u j in
      if c < !best then best := c
    done;
    if !best < 1 then 1 else !best
  in
  (* the variables of known place: first, after their thing, or in the program *)
  let first = Array.init nvars (fun x -> npat.(x) = 1 && Array.length oth.(x) = 0 && est x 0 <= 1) in
  let leaf =
    Array.init nvars (fun x ->
        npat.(x) = 1 && parent.(x) >= 0 && (not has_set.(x)) && iv.(x) = None && base.(x) = max_int && Array.length oth.(x) = 1
        && un.(x).(0) >= 2)
  in
  let core = Array.of_list (List.filter (fun x -> not (first.(x) || leaf.(x))) (List.init nvars Fun.id)) in
  let c = Array.length core in
  (* the core's order, and the partial bindings after each of its steps *)
  let cord = Array.make c 0 and csize = Array.make c 1. and ccost = ref 0. in
  if c <= dp_max then begin
    let m = 1 lsl c in
    (* the variables' bits of each subset of the core *)
    let vm = Array.make m 0 in
    for s = 1 to m - 1 do
      let low = s land (-s) in
      let k = ref 0 in
      while 1 lsl !k <> low do incr k done;
      vm.(s) <- vm.(s lxor low) lor (1 lsl core.(!k))
    done;
    let size = Array.make m 1. and cost = Array.make m 0. and last = Array.make m 0 in
    for s = 1 to m - 1 do
      let sz = ref infinity and cs = ref infinity and l = ref 0 in
      for k = 0 to c - 1 do
        if s land (1 lsl k) <> 0 then begin
          let r = s lxor (1 lsl k) in
          let step = Array.unsafe_get size r *. float_of_int (est core.(k) (Array.unsafe_get vm r)) in
          if step < !sz then sz := step;
          (* ties: the largest last, so that the order of equal costs is the variables' own *)
          let cx = Array.unsafe_get cost r +. step in
          if cx <= !cs then (cs := cx; l := k)
        end
      done;
      size.(s) <- !sz;
      cost.(s) <- !cs;
      last.(s) <- !l
    done;
    let s = ref (m - 1) in
    for i = c - 1 downto 0 do
      let k = last.(!s) in
      cord.(i) <- core.(k);
      csize.(i) <- size.(!s);
      s := !s lxor (1 lsl k)
    done;
    ccost := cost.(m - 1)
  end
  else begin
    (* placed: a flag a variable, not a bit (the wire's 64th variable has none in an int: its bit, 1 lsl 63, is 0,
       and [est] only takes it for unbound) *)
    let bound = ref 0 and size = ref 1. and placed = Array.make nvars false in
    for i = 0 to c - 1 do
      let b = ref (-1) and bc = ref max_int in
      Array.iter
        (fun x ->
          if not placed.(x) then begin
            let e = est x !bound in
            if !b < 0 || e < !bc then (b := x; bc := e)
          end)
        core;
      cord.(i) <- !b;
      placed.(!b) <- true;
      bound := !bound lor (1 lsl !b);
      ccost := !ccost +. (!size *. float_of_int !bc);
      size := !size *. float_of_int !bc;
      csize.(i) <- !size
    done
  end;
  (* the whole order: the first, then the core, each variable followed by its leaves; a variable placed first costs 1,
     a leaf the partial bindings of its thing's step *)
  let ord = Array.make nvars 0 and n = ref 0 and cost = ref !ccost in
  for x = 0 to nvars - 1 do
    if first.(x) then (ord.(!n) <- x; incr n; cost := !cost +. 1.)
  done;
  Array.iteri
    (fun i x ->
      ord.(!n) <- x;
      incr n;
      for y = 0 to nvars - 1 do
        if leaf.(y) && parent.(y) = x then (ord.(!n) <- y; incr n; cost := !cost +. csize.(i))
      done)
    cord;
  assert (!n = nvars);
  ord, !cost

(* the planner of every question: the tests put main's former one in its place, to compare the answers of both *)
let planner = ref (fun ~sets v nvars pats ranges -> order ~sets v nvars pats ranges)

(* Questions run as a fold: [init ()] makes an accumulator, [step acc env] adds a binding (the buffer [env] is reused),
   [merge] joins two accumulators. Above [parallel_min] candidates for the first variable, the candidates are split
   into slices run by [domains] domains, each slice with its own accumulator: a view needs no lock to be read. *)
let parallel_min = ref 20_000
let domains = ref (max 1 (min 8 (Domain.recommended_domain_count ())))

(* the candidates enumerated by every question so far (each runner adds its count when it ends): for the tests,
   which hold the work of a question to the Generic Join bound, and for the benchmarks *)
let work = Atomic.make 0

(* What a question will do: its patterns with a variable, its ranges, and the order of its variables; None when it
   has no answer (a constant the view has never seen, or a pattern without variables that is not a fact). *)
type plan = { pats : pat list; limits : (int * int * int) list; ord : int array; cost : float }

(* [sets]: for some variables, the index words they may take, sorted and distinct (In and Prefix) *)
let plan ?(sets = []) (v : Store.view) q =
  match compile v q with
  | exception No_answer -> None
  | _ty, pats, limits ->
    let ground, pats =
      List.partition (fun pt -> (match pt.pe with W _ -> true | _ -> false) && match pt.pv with W _ -> true | _ -> false) pats
    in
    if not (List.for_all (fun pt -> match pt.pe, pt.pv with W e, W w -> Store.mem v e pt.pp w | _ -> true) ground) then None
    else if List.exists (fun (_, a) -> Array.length a = 0) sets then None
    else (let ord, cost = !planner ~sets v q.vars pats limits in Some { pats; limits; ord; cost })

(* the first place from [from] in a.(0 .. n-1), sorted, whose value is >= t: steps of 1, 2, 4, ... then a binary search
   (galloping: Bentley, Yao 1976), O(log d) for a place d further *)
let gallop (a : int array) n from t =
  if from >= n || Array.unsafe_get a from >= t then from
  else begin
    let lo = ref from and step = ref 1 in
    while !lo + !step < n && Array.unsafe_get a (!lo + !step) < t do lo := !lo + !step; step := 2 * !step done;
    let lo = ref (!lo + 1) and hi = ref (min n (!lo + !step)) in
    while !lo < !hi do
      let mid = (!lo + !hi) lsr 1 in
      if Array.unsafe_get a mid < t then lo := mid + 1 else hi := mid
    done;
    !lo
  end

(* The planner's estimate of a question's work, in candidates (the cost of its order); 0 when it has no answer *)
let estimate ?sets (v : Store.view) q = match plan ?sets v q with None -> 0. | Some p -> p.cost

(* is c in the sorted array a *)
let in_sorted (a : int array) c =
  let lo = ref 0 and hi = ref (Array.length a) in
  while !lo < !hi do
    let mid = (!lo + !hi) lsr 1 in
    if Array.unsafe_get a mid < c then lo := mid + 1 else hi := mid
  done;
  !lo < Array.length a && Array.unsafe_get a !lo = c

(* Generic Join: at each level, the pattern with the fewest candidates (exact counts) gives them, and every other
   pattern on the variable keeps or drops each one with a lookup; nothing is enumerated beyond the smallest set.
   [seq]: on this domain alone, the bindings in the engine's order, so that [step] may stop the fold by an exception.
   [sets]: the words some variables may take (In, Prefix): a set is a source of its variable's candidates when it is
   the smallest (a relation of one column, which the AGM bound counts as one), else a check of each candidate. *)
let fold ?(seq = false) ?(sets = []) ?(budget = max_int) ?account (v : Store.view) q ~init ~step ~merge =
  match plan ~sets v q with
  | None -> init ()
  | Some { pats; limits; ord; cost = _ } ->
    let n = q.vars in
    let by_var = Array.init n (fun x -> List.filter (fun pt -> has x pt.pe || has x pt.pv) pats) in
    let iv = intervals n limits in
    let sv = Array.make n [||] and has_set = Array.make n false in
    List.iter (fun (x, a) -> if has_set.(x) then sv.(x) <- Array.of_list (List.filter (in_sorted a) (Array.to_list sv.(x))) else (sv.(x) <- a; has_set.(x) <- true)) sets;
    let any_set = sets <> [] in
    (* a variable with a set has an interval, whole if it had none: its set is checked in the interval's branch, so a
       question without sets runs the test it always ran (small enough to be inlined at every candidate) *)
    let ivs = if any_set then Array.mapi (fun x r -> if has_set.(x) && r = None then Some (min_int, max_int) else r) iv else iv in
    let in_range x c = match ivs.(x) with None -> true | Some (lo, hi) -> c >= lo && c <= hi && ((not any_set) || (not has_set.(x)) || in_sorted sv.(x) c) in
    let by_var = Array.map Array.of_list by_var in
    (* how many candidates a pattern offers x, given [get] for the sides that are bound, doubled: 2 c for an exact
       count c, and 1, without a lookup, for a one-valued property of a bound thing, which offers at most one. So such
       a pattern is taken before any other offering one or more, and after one offering none: it is a smallest
       source either way (if it has none itself, the level has none), and the work stays within the bound *)
    let count_with get x pt =
      2
      *
      if has x pt.pe && has x pt.pv then Store.count_prop v pt.pp
      else if has x pt.pe then match get pt.pv with Some w -> Store.count_things v pt.pp w | None -> Store.count_prop v pt.pp
      else
        match get pt.pe, iv.(x) with
        | Some e, _ -> if pt.many then Store.count_values v e pt.pp else -1
        | None, Some (lo, hi) -> Store.count_range v pt.pp lo hi
        | None, None -> Store.count_prop v pt.pp
    in
    let count_with get x pt = let c = count_with get x pt in if c < 0 then 1 else c in
    (* the counts that no binding changes, once a question: at level i, a pattern whose other side is a constant or a
       variable bound only later (Q3's "status = unpaid", the same for each of a city's clients); -1 for the others *)
    let fixed =
      Array.init n (fun i ->
          let x = ord.(i) in
          let before y = let k = ref 0 in while !k < i && ord.(!k) <> y do incr k done; !k < i in
          let other pt = if has x pt.pe then pt.pv else pt.pe in
          Array.map
            (fun pt ->
              match other pt with
              | V y when y <> x && before y -> -1
              | _ -> count_with (function W w -> Some w | V _ -> None) x pt)
            by_var.(x))
    in
    (* the plan of each level, beside its counts. [func]: the pattern that gives a one-valued property's value of a thing
       bound before (count 1, without a lookup), when every other pattern of the level has a fixed count of 1 or more
       and none before it can tie: [choose] takes it for every binding, so the level reads that value alone, with no
       count and no iterator. [skip]: a pattern whose other side is the next level's variable is not looked up here: at
       the next level it offers nothing for a binding it does not hold, and is then the source (no candidate, no work).
       [slice]: a pattern whose other side is known here gives its candidates in order (a thing's values, or the things
       of a value): two of them on a level are intersected by leapfrogging *)
    let level_of y = let k = ref 0 in while ord.(!k) <> y do incr k done; !k in
    let other x pt = if has x pt.pe then pt.pv else pt.pe in
    let known_at i = function W _ -> true | V y -> level_of y < i in
    let single x pt = not (has x pt.pe && has x pt.pv) in
    let func =
      Array.init n (fun i ->
          let x = ord.(i) and ps = by_var.(ord.(i)) and fx = fixed.(i) in
          let one j = let pt = ps.(j) in has x pt.pv && single x pt && (not pt.many) && known_at i pt.pe in
          let first = ref (-1) in
          Array.iteri (fun j _ -> if !first < 0 && one j then first := j) ps;
          let f = !first in
          if f < 0 then -1
          else if
            Array.for_all Fun.id (Array.mapi (fun j _ -> j = f || (j > f && one j) || (j < f && fx.(j) >= 2) || (j > f && fx.(j) >= 1)) ps)
          then f
          else -1)
    in
    let skip =
      Array.init n (fun i ->
          Array.map (fun pt -> i + 1 < n && single ord.(i) pt && other ord.(i) pt = V ord.(i + 1)) by_var.(ord.(i)))
    in
    let slice = Array.init n (fun i -> Array.map (fun pt -> single ord.(i) pt && known_at i (other ord.(i) pt)) by_var.(ord.(i))) in
    let leap = Array.map (fun s -> Array.fold_left (fun k b -> if b then k + 1 else k) 0 s >= 2) slice in
    (* one runner per domain: its own bindings and its own count of candidates; no allocation per binding but the
       iterators' own *)
    let runner () =
      let env = Array.make n 0 and bound = Array.make n false and w = ref 0 and cell = [| 0 |] in
      let get = function W w -> Some w | V y -> if bound.(y) then Some env.(y) else None in
      let accepts x c pt =
        if has x pt.pe && has x pt.pv then Store.mem v c pt.pp c
        else if has x pt.pe then
          match pt.pv with
          | W w -> Store.mem v c pt.pp w
          | V y -> if bound.(y) then Store.mem v c pt.pp env.(y) else Store.has_value v c pt.pp
        else
          match pt.pe with
          | W e -> Store.mem v e pt.pp c
          | V y -> if bound.(y) then Store.mem v env.(y) pt.pp c else Store.count_things v pt.pp c > 0
      in
      let count x pt = count_with get x pt in
      (* the candidates themselves *)
      let iterate x pt f =
        if has x pt.pe && has x pt.pv then Store.iter_prop v pt.pp (fun e w -> if e = w then f e)
        else if has x pt.pe then
          match get pt.pv with
          | Some w -> Store.iter_things v pt.pp w f
          | None -> if pt.many then Store.iter_holders v pt.pp f else Store.iter_prop v pt.pp (fun e _ -> f e)
        else
          match get pt.pe, iv.(x) with
          | Some e, _ -> Store.iter_values v e pt.pp f
          | None, Some (lo, hi) ->
            (* a variable with a range, read off the property's index in value order: only the range *)
            let seen = Hashtbl.create 256 in
            Store.iter_range v pt.pp lo hi (fun _ w -> if not (Hashtbl.mem seen w) then (Hashtbl.replace seen w (); f w))
          | None, None -> Store.iter_taken v pt.pp f
      in
      (* level i: the smallest source, and its size; each pattern's count kept for the leapfrog *)
      let counts = Array.map (fun ps -> Array.make (Array.length ps) 0) by_var in
      (* a slice's count, kept for the known side it was counted for (Q5's "who follows a", the same for each b) *)
      let ckeys = Array.map (fun ps -> Array.make (Array.length ps) 0) by_var
      and cvals = Array.map (fun ps -> Array.make (Array.length ps) (-1)) by_var
      and clos = Array.map (fun ps -> Array.make (Array.length ps) (-1)) by_var
      and cell2 = [| 0; 0 |] in
      (* a slice's exact count, and where its rows start when they can be read straight (Store.slice_values) *)
      let slice_count x pt =
        if has x pt.pe then begin
          match get pt.pv with
          | Some w -> let c = Store.slice_things v pt.pp w cell2 in if c >= 0 then (cell2.(1), 2 * c) else (-1, count x pt)
          | None -> -1, count x pt
        end
        else if pt.many then begin
          match get pt.pe with
          | Some e -> let c = Store.slice_values v e pt.pp cell2 in if c >= 0 then (cell2.(1), 2 * c) else (-1, count x pt)
          | None -> -1, count x pt
        end
        else -1, count x pt
      in
      let choose i =
        let x = ord.(i) in
        let ps = by_var.(x) and fx = fixed.(i) and cs = counts.(x) and sl = slice.(i) in
        let best = ref (-1) and bc = ref max_int in
        for j = 0 to Array.length ps - 1 do
          let c =
            if fx.(j) >= 0 then fx.(j)
            else if sl.(j) then begin
              let key = match other x ps.(j) with W w -> w | V y -> env.(y) in
              if cvals.(x).(j) >= 0 && ckeys.(x).(j) = key then cvals.(x).(j)
              else (let lo, c = slice_count x ps.(j) in cvals.(x).(j) <- c; ckeys.(x).(j) <- key; clos.(x).(j) <- lo; c)
            end
            else count x ps.(j)
          in
          cs.(j) <- c;
          if c < !bc then (bc := c; best := j)
        done;
        if any_set && has_set.(x) && 2 * Array.length sv.(x) < !bc then (bc := 2 * Array.length sv.(x); best := -2);
        !best, !bc
      in
      (* does every pattern of level i but [src] (and those the leapfrog intersected: [lf] marks them) hold c *)
      let others i src lf c =
        let x = ord.(i) and ps = by_var.(ord.(i)) and sk = skip.(i) in
        let ok = ref true and j = ref 0 in
        while !ok && !j < Array.length ps do
          if !j <> src && (not sk.(!j)) && (lf = 0 || !j > 61 || (lf lsr !j) land 1 = 0) && not (accepts x c ps.(!j)) then ok := false;
          incr j
        done;
        !ok
      in
      (* a candidate of level i from source src: in its range, and a fact of every other pattern of the level *)
      let admits i src c = in_range ord.(i) c && others i src 0 c in
      (* the same test as [admits], written out: a call per candidate costs 4 to 7 % of Q4 (no flambda) *)
      let candidates i src (f : int -> unit) =
        let x = ord.(i) and ps = by_var.(ord.(i)) and sk = skip.(i) in
        if src = -2 then
          Array.iter
            (fun c ->
              incr w;
              if !w > budget then raise (Over_budget budget);
              if in_range x c then begin
                let ok = ref true and j = ref 0 in
                while !ok && !j < Array.length ps do
                  if (not sk.(!j)) && not (accepts x c ps.(!j)) then ok := false;
                  incr j
                done;
                if !ok then f c
              end)
            sv.(x)
        else if src >= 0 then
          iterate x ps.(src) (fun c ->
              incr w;
              if !w > budget then raise (Over_budget budget);
              if in_range x c then begin
                let ok = ref true and j = ref 0 in
                while !ok && !j < Array.length ps do
                  if !j <> src && (not sk.(!j)) && not (accepts x c ps.(!j)) then ok := false;
                  incr j
                done;
                if !ok then f c
              end)
      in
      (* the leapfrog's buffers, a level's pattern each: its candidates, how many, and the known side they were read for *)
      let bufs = Array.map (fun ps -> Array.map (fun _ -> ref [||]) ps) by_var
      and lens = Array.map (fun ps -> Array.make (Array.length ps) (-1)) by_var
      and keys = Array.map (fun ps -> Array.make (Array.length ps) 0) by_var in
      let partss = Array.init n (fun _ -> Array.make 64 0) and poss = Array.init n (fun _ -> Array.make 64 0) in
      (* pattern j of level i read into its buffer, sorted, unless it holds it already for the same known side *)
      let fill i j =
        let x = ord.(i) and pt = by_var.(ord.(i)).(j) in
        let key = match other x pt with W w -> w | V y -> env.(y) in
        let xi = ord.(i) in
        if lens.(xi).(j) < 0 || keys.(xi).(j) <> key then begin
          let b = bufs.(xi).(j) and m = ref 0 and sorted = ref true in
          if clos.(xi).(j) >= 0 && ckeys.(xi).(j) = key && cvals.(xi).(j) >= 0 then begin
            (* its rows, straight from the run: sorted *)
            let n = cvals.(xi).(j) / 2 in
            if Array.length !b < n then b := Array.make (max 16 (2 * n)) 0;
            if has x pt.pe then Store.read_things v pt.pp clos.(xi).(j) n !b
            else Store.read_values v (match pt.pe with W e -> e | V y -> env.(y)) pt.pp clos.(xi).(j) n !b;
            m := n
          end
          else
          iterate x pt (fun c ->
              if !m = Array.length !b then (let nb = Array.make (max 16 (2 * !m)) 0 in Array.blit !b 0 nb 0 !m; b := nb);
              if !m > 0 && Array.unsafe_get !b (!m - 1) >= c then sorted := false;
              Array.unsafe_set !b !m c;
              incr m);
          w := !w + !m;
          if !w > budget then raise (Over_budget budget);
          if not !sorted then (let s = Array.sub !b 0 !m in Array.sort compare s; Array.blit s 0 !b 0 !m);
          lens.(xi).(j) <- !m;
          keys.(xi).(j) <- key
        end
      in
      let rec level i acc =
        if i = n then acc := step !acc env
        else begin
          let x = ord.(i) in
          let f = func.(i) in
          if f >= 0 then begin
            (* the one value of a bound thing's one-valued property *)
            let pt = by_var.(x).(f) in
            let e = match pt.pe with W e -> e | V y -> env.(y) in
            match Store.value1 v e pt.pp cell with
            | 0 -> ()
            | 1 ->
              incr w;
              let c = cell.(0) in
              if in_range x c && others i f 0 c then begin
                bound.(x) <- true;
                env.(x) <- c;
                level (i + 1) acc;
                bound.(x) <- false
              end
            | _ -> general i acc
          end
          else general i acc
        end
      and general i acc =
        let x = ord.(i) in
        let src, size = choose i in
        bound.(x) <- true;
        (if leap.(i) && src >= 0 && slice.(i).(src) && size >= 4 then leapfrog i src size acc
         else candidates i src (fun c -> env.(x) <- c; level (i + 1) acc));
        bound.(x) <- false
      (* Leapfrog Triejoin's intersection (Veldhuizen 2014): the source and every other slice whose count is at most 8
         times the source's are read into their buffers, then the iterators, in the order of their keys, each seek the
         largest key in turn by galloping (Bentley, Yao 1976): a key all reach is a candidate, checked against the
         level's other patterns. Read: at most 1 + 8 (k - 1) times the source's count; compared: O(m log (n / m)) *)
      and leapfrog i src size acc =
        let x = ord.(i) and ps = by_var.(ord.(i)) and cs = counts.(ord.(i)) and xi = ord.(i) in
        let parts = partss.(i) and pos = poss.(i) in
        (* [lf]: the intersected patterns but the source (which [others] skips by its place), as bits: only patterns
           0 to 61 are intersected, a bit each (a shift by 64 or more wraps on x86: pattern 64 would read pattern 0's) *)
        let k = ref 1 and lf = ref 0 in
        parts.(0) <- src;
        for j = 0 to Array.length ps - 1 do
          if j <> src && j < 62 && slice.(i).(j) && cs.(j) <= 8 * size && !k < 62 then (parts.(!k) <- j; incr k; lf := !lf lor (1 lsl j))
        done;
        let k = !k and lf = !lf in
        if k < 2 then candidates i src (fun c -> env.(x) <- c; level (i + 1) acc)
        else begin
          let empty = ref false in
          for q = 0 to k - 1 do
            fill i parts.(q);
            pos.(q) <- 0;
            if lens.(xi).(parts.(q)) = 0 then empty := true
          done;
          if not !empty && k = 2 then begin
            (* two slices: leapfrogging is a merge whose steps gallop *)
            let a = !(bufs.(xi).(parts.(0))) and na = lens.(xi).(parts.(0))
            and b = !(bufs.(xi).(parts.(1))) and nb = lens.(xi).(parts.(1)) in
            let ia = ref 0 and jb = ref 0 in
            while !ia < na && !jb < nb do
              let u = Array.unsafe_get a !ia and t = Array.unsafe_get b !jb in
              if u = t then begin
                if in_range x u && others i src lf u then (env.(x) <- u; level (i + 1) acc);
                incr ia;
                incr jb
              end
              else if u < t then ia := (if !ia + 1 < na && Array.unsafe_get a (!ia + 1) >= t then !ia + 1 else gallop a na (!ia + 1) t)
              else jb := (if !jb + 1 < nb && Array.unsafe_get b (!jb + 1) >= u then !jb + 1 else gallop b nb (!jb + 1) u)
            done
          end
          else if not !empty then begin
            let key q = Array.unsafe_get !(bufs.(xi).(parts.(q))) pos.(q) in
            (* the iterators in the order of their first keys (insertion sort: a few) *)
            for a = 1 to k - 1 do
              let b = ref a in
              while !b > 0 && key (!b - 1) > key !b do
                let t = parts.(!b) in parts.(!b) <- parts.(!b - 1); parts.(!b - 1) <- t;
                decr b
              done
            done;
            let p = ref 0 and stop = ref false in
            let hi = ref (key (k - 1)) in
            while not !stop do
              let xk = key !p in
              if xk = !hi then begin
                (* every iterator is at the key *)
                if in_range x xk && others i src lf xk then (env.(x) <- xk; level (i + 1) acc);
                pos.(!p) <- pos.(!p) + 1;
                if pos.(!p) >= lens.(xi).(parts.(!p)) then stop := true
                else (hi := key !p; p := if !p + 1 = k then 0 else !p + 1)
              end
              else begin
                let a = !(bufs.(xi).(parts.(!p))) and len = lens.(xi).(parts.(!p)) in
                pos.(!p) <- gallop a len pos.(!p) !hi;
                if pos.(!p) >= len then stop := true else (hi := key !p; p := if !p + 1 = k then 0 else !p + 1)
              end
            done
          end
        end
      in
      env, bound, choose, iterate, admits, level, w
    in
    if n = 0 then step (init ()) [||]
    else begin
      let env, bound, choose, iterate, admits, level, w0 = runner () in
      let flush w = ignore (Atomic.fetch_and_add work !w); w := 0 in
      let x0 = ord.(0) in
      let src, size = choose 0 in
      let d = if (not seq) && size / 2 >= !parallel_min then !domains else 1 in
      if d <= 1 then begin
        let acc = ref (init ()) in
        level 0 acc;
        (match account with Some r -> r := !r + !w0 | None -> ());
        flush w0;
        !acc
      end
      else begin
        (* the first level's source, as it comes (exactly [size] / 2 candidates, at most 1 for a one-valued
           property); each slice checks its own against the level's other patterns, so that no domain does the
           first level alone *)
        let firsts = Array.make ((size + 1) / 2) 0 and count = ref 0 in
        bound.(x0) <- true;
        if src = -2 then Array.iter (fun c -> firsts.(!count) <- c; incr count; incr w0) sv.(x0)
        else iterate x0 by_var.(x0).(src) (fun c -> firsts.(!count) <- c; incr count; incr w0);
        (* slices of the candidates, taken in turn by the domains from a shared counter (a domain that meets the
           expensive candidates takes fewer slices), each with its own accumulator, merged in slice order: the answer
           does not depend on the number of domains nor on which domain ran which slice *)
        let slices = max 1 (min !count (16 * d)) in
        let accs = Array.make slices None and next = Atomic.make 0 in
        let run (env, bound, admits, level, w) =
          bound.(x0) <- true;
          let go = ref true in
          while !go do
            let s = Atomic.fetch_and_add next 1 in
            if s >= slices then go := false
            else begin
              let acc = ref (init ()) in
              for k = s * !count / slices to ((s + 1) * !count / slices) - 1 do
                let c = firsts.(k) in
                if admits 0 src c then begin
                  env.(x0) <- c;
                  level 1 acc
                end
              done;
              accs.(s) <- Some !acc
            end
          done;
          flush w
        in
        let others =
          List.init (d - 1) (fun _ -> Domain.spawn (fun () -> let e, b, _, _, a, l, w = runner () in run (e, b, a, l, w)))
        in
        (match run (env, bound, admits, level, w0) with
         | () -> List.iter Domain.join others
         | exception e -> List.iter (fun dm -> try Domain.join dm with _ -> ()) others; raise e);
        let acc = ref (Option.get accs.(0)) in
        for s = 1 to slices - 1 do acc := merge !acc (Option.get accs.(s)) done;
        !acc
      end
    end

let rows (v : Store.view) q =
  match compile v q with
  | exception No_answer -> []
  | ty, _, _ ->
    let rows =
      fold v q ~init:(fun () -> []) ~merge:(fun a b -> b @ a)
        ~step:(fun acc env -> Array.mapi (fun i w -> Store.value v ty.(i) w) env :: acc)
    in
    List.rev rows

let count (v : Store.view) q = fold v q ~init:(fun () -> 0) ~step:(fun n _ -> n + 1) ~merge:( + )

let var_types = types
