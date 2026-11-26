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
(** [ranges]: [(x, lo, hi)] keeps the bindings with lo <= x <= hi (an int, a date, money, or a float in IEEE 754's
    totalOrder). *)

exception No_answer
exception Bad of string

(* a question that passed its budget of candidates (a server's bound: Core.question_budget) *)
exception Over_budget of int

(* ---- what stops a question before its answer ----
   Its deadline (the server's question_timeout, or the time a program gives a call), or its asker gone (the program's
   connection closed). Both are looked at where the budget is counted, every [every] candidates of each domain: a
   read of the monotonic clock, about 20 ns a check, so that a question pays nothing it can measure for them; the
   asker at most once every [look_ms]. As SQLite's progress handler (sqlite3_progress_handler: a callback every N
   instructions of its machine, which may interrupt the statement), PostgreSQL's statement_timeout ("Abort any
   statement that takes more than the specified amount of time") and client_connection_check_interval. *)

(* the monotonic clock, in milliseconds (src/clock_stubs.c) *)
external now_ms : unit -> int = "cepheus_monotonic_ms" [@@noalloc]

(* the question passed its deadline: the seconds it was given *)
exception Timeout of float

(* the question's asker is gone *)
exception Cancelled

type stop = {
  ms : int;  (* the milliseconds it is given; max_int: no deadline *)
  seconds : float;  (* the same, for the message *)
  mutable until : int;  (* the monotonic clock's ms past which it ends; 0: not looked at yet *)
  gone : unit -> bool;  (* its asker is gone (the server: its connection closed) *)
  mutable look : int;  (* the clock's ms from which [gone] is called again *)
  mutable own : int;
  work : int Atomic.t;
      (* the candidates its folds took (each fold's domains, its Nots', its windows'), added at each check and at each
         fold's end: what the server's log of slow questions says (server/timings.ml). [own]: those of the asking
         thread's own runners (one thread: no atomic), [work] those of the helping domains *)
}

let every = 1024
let look_ms = 10

(* a stop of [seconds] (0 or less: no deadline). The clock is first read at the question's first check (within its
   first [every] candidates, microseconds after its start): a question that ends before never reads it, so that a
   point question pays for its time a record and nothing more *)
let stop ?(gone = fun () -> false) seconds =
  let ms =
    if seconds <= 0. || seconds >= 1e9 then max_int
    else (let x = seconds *. 1000. in let i = int_of_float x in if float_of_int i < x then i + 1 else max 1 i)
  in
  { ms; seconds; until = 0; gone; look = 0; own = 0; work = Atomic.make 0 }

(* the candidates the question took so far *)
let work_of (s : stop) = s.own + Atomic.get s.work

(* the message of a deadline passed *)
let timeout_message seconds = Printf.sprintf "the question took more than %g s, its time: ask a narrower one, or give it more time" seconds

let check (s : stop) =
  let now = now_ms () in
  if s.until = 0 then s.until <- (if s.ms = max_int then max_int else now + s.ms)
  else if now > s.until then raise (Timeout s.seconds);
  if now >= s.look then begin
    s.look <- now + look_ms;
    if s.gone () then raise Cancelled
  end

(* a domain of the question failed: its other domains stop (the first failure is the question's) *)
exception Stopped

let bad fmt = Printf.ksprintf (fun s -> raise (Bad s)) fmt

(* internal form: each side a variable or a word *)
type side = V of int | W of int
type pat = { pe : side; pp : int; pv : side; many : bool }

(* Less: [lx < ly], or [lx <= ly] when not [strict], two variables of one type, or a variable and a word (a Not's
   own question, its other variables fixed) *)
type less = { lx : side; ly : side; strict : bool }

(* a float of the dictionary: its 8 bytes, little-endian (Store.float_key) *)
let float_of_word (v : Store.view) w = Int64.float_of_bits (String.get_int64_le (Store.text v w) 0)

(* two words of a type in its order: an int, a date, money, a link or a bool by its word, a text by its bytes, a float
   in totalOrder *)
let compare_words (v : Store.view) (ty : Value.typ) (a : int) b =
  if a = b then 0
  else match ty with Ttext -> String.compare (Store.text v a) (Store.text v b) | Tfloat -> Value.total_order (float_of_word v a) (float_of_word v b) | _ -> compare a b

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
let same_slot = Atomic.make None

let any_same (v : Store.view) =
  match Atomic.get same_slot with
  | Some (runs, d, b) when runs == v.runs && d == v.delta -> b
  | _ -> let b = Store.count_prop v Schema.p_same > 0 in Atomic.set same_slot (Some (v.runs, v.delta, b)); b

let rep (v : Store.view) x =
  if x < Schema.first_thing || not (any_same v) then x
  else (let r = ref x in Store.iter_values v x Schema.p_same (fun w -> r := w); !r)

(* the class of x: its representative and the things whose cepheus/same is it, by id (Cepheus.same) *)
let same (v : Store.view) x =
  if not (any_same v) then [ x ]
  else (let r = rep v x in let l = ref [ r ] in Store.iter_things v Schema.p_same r (fun y -> l := y :: !l); List.sort compare !l)

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
  (* a range of an int, a date or money is one of words, read from the sorted index; one of a float, whose words are
     the dictionary's, is a check of each candidate, in totalOrder *)
  let floats =
    List.filter_map
      (fun (x, lo, hi) ->
        if x < 0 || x >= q.vars then bad "a range needs an int, float, date or money variable";
        match ty.(x), lo, hi with
        | Tfloat, Value.Float a, Value.Float b -> Some (x, a, b)
        | Tfloat, _, _ -> bad "a range of a float variable has float bounds, not %s and %s" (Value.to_string lo) (Value.to_string hi)
        | t, _, _ when Value.inline t -> None
        | _ -> bad "a range needs an int, float, date or money variable")
      q.ranges
  in
  let ranges =
    List.filter_map
      (fun (x, lo, hi) ->
        if ty.(x) = Tfloat then None
        else
          match Store.word v lo, Store.word v hi with
          | Some a, Some b -> Some (x, a, b)
          | _ -> raise No_answer)
      q.ranges
  in
  ty, pats, ranges, floats

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

(* [less]: the pairs of variables of ints, dates, money or links that Less compares, each both ways: a variable whose
   other side is bound before it takes, from a property's values, those past the other's (a range of the sorted index),
   estimated as a third of them (Selinger et al. 1979's share of an open range) *)
let order ?(sets = []) ?(less = []) (v : Store.view) nvars pats ranges =
  let iv = intervals nvars ranges in
  let base = Array.make nvars max_int and has_set = Array.make nvars false in
  List.iter (fun (x, a) -> base.(x) <- min base.(x) (Array.length a); has_set.(x) <- true) sets;
  (* each pattern's offers: to x, (y, kn, un) the count when the variable y on its other side is bound, and when it
     is not; a word on the other side (or x itself) gives its count to [base] *)
  let offers = Array.make nvars [] and npat = Array.make nvars 0 and parent = Array.make nvars (-1) in
  (* a variable given as the one value of a thing: its property's distinct values, and the share of its facts in its
     range (1. without one), for the placement of the leaves below *)
  let ldist = Array.make nvars 1 and lrange = Array.make nvars 1. in
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
           let d = Store.distinct v pt.pp in
           let un, r =
             match iv.(y) with
             | None -> d, 1.
             | Some (lo, hi) ->
               let all = max 1 (Store.count_prop v pt.pp) and n = Store.count_range v pt.pp lo hi in
               max 1 (n * d / all), Float.min 1. (float_of_int (max 0 n) /. float_of_int all)
           in
           npat.(y) <- npat.(y) + 1;
           if not pt.many then (parent.(y) <- x; ldist.(y) <- max 1 d; lrange.(y) <- r);
           offer y x (if pt.many then 4 else 1) un
         | _, W _ -> ()))
    pats;
  (* Less: y is a value of a property whose thing is a variable: once x is bound, a third of its distinct values *)
  List.iter
    (fun (x, y) ->
      let d =
        List.fold_left
          (fun m pt -> match pt.pe, pt.pv with V e, V w when w = y && e <> y -> min m (Store.distinct v pt.pp) | _ -> m)
          max_int pats
      in
      if d < max_int then offers.(y) <- (x, max 1 (d / 3), max_int) :: offers.(y))
    less;
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
  (* the variables placed first are bound before the core: their bits are bound in its estimates (only a Less offers
     a variable a count from one of them: no pattern of a first variable has another) *)
  let fmask = ref 0 in
  Array.iteri (fun x f -> if f then fmask := !fmask lor (1 lsl x)) first;
  let fmask = !fmask in
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
          let step = Array.unsafe_get size r *. float_of_int (est core.(k) (Array.unsafe_get vm r lor fmask)) in
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
    let bound = ref fmask and size = ref 1. and placed = Array.make nvars false in
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
  (* Where a leaf goes: after its thing's step, or later, after a filter that keeps fewer bindings (the leaf's lookup
     is then made for fewer of them): Hellerstein and Stonebraker 1993's placement of predicates, a cheap selective
     test before a projection that filters nothing. A filter here is a core variable whose only pattern gives it as
     the one value of a thing bound before it, with an In, a Prefix or a range: the share of the property's facts it
     keeps is estimated as Selinger et al. 1979 do, the set's words over the property's distinct values, the range's
     facts over all. After each step of the core, the bindings kept: its partial bindings times the shares of the
     filters so far; a leaf goes after the step of its thing, or the first later step that keeps the fewest (the
     same step when no filter follows: the order of a question without filters is unchanged). The estimate [cost]
     stays that of the join without the filters' shares, as before. *)
  let at = Array.make nvars (-1) in
  Array.iteri (fun i x -> at.(x) <- i) cord;
  let kept = Array.make c 1. in
  let share = ref 1. in
  Array.iteri
    (fun i y ->
      if npat.(y) = 1 && parent.(y) >= 0 && at.(parent.(y)) >= 0 && at.(parent.(y)) < i && (has_set.(y) || iv.(y) <> None) then begin
        let s = if has_set.(y) && base.(y) < max_int then Float.min 1. (float_of_int base.(y) /. float_of_int ldist.(y)) else 1. in
        share := !share *. s *. lrange.(y)
      end;
      kept.(i) <- csize.(i) *. !share)
    cord;
  let place = Array.make nvars (-1) in
  for y = 0 to nvars - 1 do
    if leaf.(y) then begin
      let i0 = at.(parent.(y)) in
      let b = ref i0 in
      for i = i0 + 1 to c - 1 do if kept.(i) < kept.(!b) then b := i done;
      place.(y) <- !b
    end
  done;
  (* the whole order: the first, then the core, each step followed by the leaves placed there; a variable placed first
     costs 1, a leaf the partial bindings of its thing's step *)
  let ord = Array.make nvars 0 and n = ref 0 and cost = ref !ccost in
  for x = 0 to nvars - 1 do
    if first.(x) then (ord.(!n) <- x; incr n; cost := !cost +. 1.)
  done;
  Array.iteri
    (fun i x ->
      ord.(!n) <- x;
      incr n;
      for y = 0 to nvars - 1 do
        if leaf.(y) && place.(y) = i then (ord.(!n) <- y; incr n; cost := !cost +. csize.(at.(parent.(y))))
      done)
    cord;
  assert (!n = nvars);
  ord, !cost

(* the planner of every question: the tests put main's former one in its place, to compare the answers of both *)
let planner = ref (fun ~sets ~less v nvars pats ranges -> order ~sets ~less v nvars pats ranges)

(* Questions run as a fold: [init ()] makes an accumulator, [step acc env] adds a binding (the buffer [env] is reused),
   [merge] joins two accumulators. A level of [parallel_min] candidates or more, wherever it is in the order, has its
   candidates split into slices run by [domains] domains, each slice with its own accumulator: a view needs no lock to
   be read. The first level of two candidates or more past the levels of one, when the planner expects
   [probe_more] times [parallel_min] candidates of work or more, is probed: its candidates run on one domain until their work, measured,
   says that the rest is worth splitting (the fold's own section below). *)
let parallel_min = ref 20_000
let domains = ref (max 1 (min 8 (Domain.recommended_domain_count ())))

(* the work a probed level's candidates take, measured, before the rest may be split: [every] (the tests make it
   small) *)
let probe_min = ref every

(* a probe splits only where the planner expects, and the measure then says, [probe_more] times [parallel_min]
   candidates of work: its numbers are an estimate and an extrapolation, a level's count an exact one. Below it, the
   rows a question gives cost more than its candidates (a find of 11,363 texts, of 22,726 candidates, took 3.6 ms on
   one domain and 4.2 split); the tests make it 1 *)
let probe_more = ref 4

(* A runner: one a domain of a question, its own binding, counts and caches, the view shared (Query.fold) *)
type 'a runner = {
  env : int array;  (* the words of the variables bound so far *)
  bound : bool array;
  kthing : int array;  (* a leaf's value read at its thing's level: the thing, and the value ([kept]) *)
  kword : int array;
  w : int ref;  (* its candidates *)
  iterate : int -> pat -> (int -> unit) -> unit;
  admits : int -> int -> int -> bool;
  level : int -> 'a ref -> unit;
  general : int -> 'a ref -> unit;
  bounds : int -> bool;
  over : unit -> unit;  (* the budget, the stop and the other domains looked at, and the next count to look at them *)
  settle : unit -> unit;  (* its candidates added to the question's shared count *)
  flush : unit -> unit;  (* its candidates added to [work] and to the stop's work, at its end *)
  ctl : 'a ctl;
}

(* what a runner does besides its levels: one record, made once a runner *)
and 'a ctl = {
  mutable ticks : bool;  (* looks at them every [every] candidates (else at the budget only) *)
  mutable shared : bool;  (* other domains work for the question: its budget is their count and its own *)
  mutable cut : int;  (* the level past which the bindings are collected ([collecting]), not stepped *)
  mutable collecting : bool;
  mutable collect : unit -> unit;
  mutable splitting : bool;  (* may [split] a level: the asking domain's runner, outside a split *)
  mutable split : int -> int -> int -> 'a ref -> bool;  (* level, source, doubled count: true when it ran the level *)
  mutable top : bool;  (* no level of two candidates or more met yet (the asking domain's runner) *)
  mutable cap : int;  (* the question's budget over every domain (the fold's [spent]) *)
  mutable spent : int Atomic.t;  (* the candidates of every domain, from the first split ([unshared] before) *)
  mutable nsplit : int;  (* the splits the asking domain made *)
}

let no_split _ _ _ _ = false

(* the count of a runner that shares none: never added to (a question that splits gets its own at its first split) *)
let unshared = Atomic.make 0

(* the leaves whose value a level reads and keeps ([kept]), each once: what a collected candidate carries *)
let kept_leaves (ks : int array) = Array.of_list (List.sort_uniq compare (List.filter (fun y -> y >= 0) (Array.to_list ks)))

(* the candidates enumerated by every question so far (each runner adds its count when it ends): for the tests,
   which hold the work of a question to the Generic Join bound, and for the benchmarks *)
let work = Atomic.make 0

(* the levels split across domains so far, and those of them that a probe split (its candidates' work measured first):
   for the tests and the benchmarks *)
let splits = Atomic.make 0
let probed_splits = Atomic.make 0

(* What a question will do: its patterns with a variable, its ranges, and the order of its variables; None when it
   has no answer (a constant the view has never seen, or a pattern without variables that is not a fact). *)
type plan = {
  pats : pat list;
  limits : (int * int * int) list;
  floats : (int * float * float) list;  (* the ranges of float variables, checked on each candidate *)
  ty : Value.typ array;
  ord : int array;
  cost : float;
}

(* [sets]: for some variables, the index words they may take, sorted and distinct (In and Prefix); [less]: the
   variables of ints, dates, money or links that Less compares, as pairs, each both ways *)
let plan ?(sets = []) ?(less = []) (v : Store.view) q =
  match compile v q with
  | exception No_answer -> None
  | ty, pats, limits, floats ->
    let ground, pats =
      List.partition (fun pt -> (match pt.pe with W _ -> true | _ -> false) && match pt.pv with W _ -> true | _ -> false) pats
    in
    if not (List.for_all (fun pt -> match pt.pe, pt.pv with W e, W w -> Store.mem v e pt.pp w | _ -> true) ground) then None
    else if List.exists (fun (_, a) -> Array.length a = 0) sets then None
    else (let ord, cost = !planner ~sets ~less v q.vars pats limits in Some { pats; limits; floats; ty; ord; cost })

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
(* the pairs of variables of a Less that the planner takes, each both ways: two variables of a type whose words keep
   their order *)
let less_pairs (v : Store.view) q (less : less list) =
  if less = [] then []
  else
    match types v q with
    | exception Bad _ -> []
    | ty ->
      List.concat_map
        (fun l -> match l.lx, l.ly with V x, V y when x <> y && x < q.vars && y < q.vars && Value.inline ty.(x) && ty.(x) = ty.(y) -> [ (x, y); (y, x) ] | _ -> [])
        less

let fold ?(seq = false) ?(any_order = false) ?(sets = []) ?(less = []) ?(budget = max_int) ?account ?stop (v : Store.view) q ~init ~step ~merge =
  match plan ~sets ~less:(less_pairs v q less) v q with
  | None -> init ()
  | Some { pats; limits; floats; ty; ord; cost } ->
    let n = q.vars in
    let by_var = Array.init n (fun x -> List.filter (fun pt -> has x pt.pe || has x pt.pv) pats) in
    let lvl = Array.make n 0 in
    Array.iteri (fun i x -> lvl.(x) <- i) ord;
    (* Less: the side bound later (in the order) is bounded at its level by the other's word. For an int, a date,
       money or a link, whose words keep their order, a range of words ([dyn]: the other variable, the later side the
       greater, strict): the later variable's candidates read from the property's sorted index when they come from
       its values, so that the join seeks instead of scanning once one side is bound (the inequality join of Khayyat
       et al., VLDB 2015); for a text (its bytes) or a float (totalOrder), a check of each candidate ([dchk]). Against
       a word (a Not's own question), the same with the word. Floats' ranges are checks too ([fchk]). *)
    let empty = ref false and more = ref [] in
    let dyn = Array.make n [] and dchk = Array.make n [] and fchk = Array.make n [] in
    let decoded x = match ty.(x) with Value.Ttext | Tfloat -> true | _ -> false in
    let var x = if x < 0 || x >= n then bad "variable %d out of range" x in
    List.iter
      (fun { lx; ly; strict } ->
        match lx, ly with
        | V x, V y when x = y -> var x; if strict then empty := true
        | V x, V y ->
          var x;
          var y;
          if ty.(x) <> ty.(y) then bad "Less compares two variables of one type, not a %s and a %s" (Value.typ_name ty.(x)) (Value.typ_name ty.(y));
          let later, other, greater = if lvl.(y) > lvl.(x) then y, x, true else x, y, false in
          if decoded later then dchk.(later) <- (V other, greater, strict) :: dchk.(later)
          else dyn.(later) <- (other, greater, strict) :: dyn.(later)
        | V x, W w ->
          var x;
          if decoded x then dchk.(x) <- (W w, false, strict) :: dchk.(x)
          else if strict && w = min_int then empty := true
          else more := (x, min_int, if strict then w - 1 else w) :: !more
        | W w, V y ->
          var y;
          if decoded y then dchk.(y) <- (W w, true, strict) :: dchk.(y)
          else if strict && w = max_int then empty := true
          else more := (y, (if strict then w + 1 else w), max_int) :: !more
        | W _, W _ -> bad "Less compares a variable")
      less;
    List.iter (fun (x, lo, hi) -> fchk.(x) <- (lo, hi) :: fchk.(x)) floats;
    let has_chk = Array.init n (fun x -> dchk.(x) <> [] || fchk.(x) <> []) in
    let any_chk = Array.exists Fun.id has_chk and any_dyn = Array.exists (fun l -> l <> []) dyn in
    let iv = intervals n (limits @ !more) in
    let sv = Array.make n [||] and has_set = Array.make n false in
    List.iter (fun (x, a) -> if has_set.(x) then sv.(x) <- Array.of_list (List.filter (in_sorted a) (Array.to_list sv.(x))) else (sv.(x) <- a; has_set.(x) <- true)) sets;
    let any_set = sets <> [] in
    (* a variable with a set or a check has an interval, whole if it had none: its set and its checks are looked at in
       the interval's branch, so a question without them runs the test it always ran (small enough to be inlined at
       every candidate) *)
    let ivs = if any_set || any_chk then Array.mapi (fun x r -> if (has_set.(x) || has_chk.(x)) && r = None then Some (min_int, max_int) else r) iv else iv in
    if !empty then init ()
    else
    let by_var = Array.map Array.of_list by_var in
    (* how many candidates a pattern offers x, given [get] for the sides that are bound, doubled: 2 c for an exact
       count c, and 1, without a lookup, for a one-valued property of a bound thing, which offers at most one. So such
       a pattern is taken before any other offering one or more, and after one offering none: it is a smallest
       source either way (if it has none itself, the level has none), and the work stays within the bound *)
    let count_in (iv : (int * int) option array) get x pt =
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
    let count_in iv get x pt = let c = count_in iv get x pt in if c < 0 then 1 else c in
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
              (* a variable bounded by Less: its counts change with the bindings before it *)
              | _ when dyn.(x) <> [] -> -1
              | _ -> count_in iv (function W w -> Some w | V _ -> None) x pt)
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
    (* [kept]: a pattern of level i that gives a later variable y as the one value of this level's thing, y in no other
       pattern (a leaf: a field of a row), not skipped: its test here (has the thing a value) reads the value itself
       (Store.value1) and keeps it for y's level, which then reads nothing (the same lookup made once, not twice); the
       bindings it drops are dropped here as before, so the work and its bound are unchanged. y, or -1 *)
    let kept =
      Array.init n (fun i ->
          Array.mapi
            (fun j pt ->
              match pt.pe, pt.pv with
              | V x, V y when x = ord.(i) && y <> x && (not pt.many) && (not skip.(i).(j)) && Array.length by_var.(y) = 1 && level_of y > i -> y
              | _ -> -1)
            by_var.(ord.(i)))
    in
    let slice = Array.init n (fun i -> Array.map (fun pt -> single ord.(i) pt && known_at i (other ord.(i) pt)) by_var.(ord.(i))) in
    let leap = Array.map (fun s -> Array.fold_left (fun k b -> if b then k + 1 else k) 0 s >= 2) slice in
    (* one runner per domain: its own bindings and its own count of candidates; no allocation per binding but the
       iterators' own *)
    (* a domain of this question failed: set before its exception goes up, so that the others stop at their next check *)
    let abort = Atomic.make false in
    (* the candidates of every domain of the question, added by each at its looks (every [every] candidates) and at its
       end while others work beside it, against [cap]: [budget] a domain its first level is split into ([budget] times
       [domains] when it has [parallel_min] candidates or more, the split there was before splits of deeper levels;
       [budget] otherwise). So the budget never refuses what it took before, and does not depend on the number of
       domains that take part nor on which one ran what: the question's work is the same on one domain *)
    let runner ~helper ~cap ~spent ticks0 =
      let ctl = { ticks = ticks0; shared = helper; cut = n; collecting = false; collect = ignore; splitting = false; split = no_split; top = true; cap; spent; nsplit = 0 } in
      let env = Array.make n 0 and bound = Array.make n false and w = ref 0 and cell = [| 0 |] in
      (* the intervals, a runner's own when Less bounds a variable by the bindings before it *)
      let iv0 = iv in
      let iv = if any_dyn then Array.copy iv else iv and ivs = if any_dyn then Array.copy ivs else ivs in
      (* the checks of a text or float variable: its ranges (floats), and Less against the other side's word *)
      let checks x c =
        (match fchk.(x) with
         | [] -> true
         | l -> let f = float_of_word v c in List.for_all (fun (lo, hi) -> Value.total_order lo f <= 0 && Value.total_order f hi <= 0) l)
        && List.for_all
             (fun (s, greater, strict) ->
               let o = match s with W w -> w | V y -> env.(y) in
               let c' =
                 if c = o then 0
                 else match ty.(x) with Ttext -> String.compare (Store.text v c) (Store.text v o) | _ -> Value.total_order (float_of_word v c) (float_of_word v o)
               in
               if greater then (if strict then c' > 0 else c' >= 0) else if strict then c' < 0 else c' <= 0)
             dchk.(x)
      in
      let in_range x c = match ivs.(x) with None -> true | Some (lo, hi) -> c >= lo && c <= hi && ((not any_set) || (not has_set.(x)) || in_sorted sv.(x) c) && ((not any_chk) || (not has_chk.(x)) || checks x c) in
      (* a variable bounded by Less, at its level: its interval from its own and the other sides' words; false when
         it is empty *)
      let bounds x =
        let lo, hi = match iv0.(x) with None -> min_int, max_int | Some (a, b) -> a, b in
        let lo = ref lo and hi = ref hi and ok = ref true in
        List.iter
          (fun (y, greater, strict) ->
            let o = env.(y) in
            if greater then (if not strict then lo := max !lo o else if o = max_int then ok := false else lo := max !lo (o + 1))
            else if not strict then hi := min !hi o
            else if o = min_int then ok := false
            else hi := min !hi (o - 1))
          dyn.(x);
        !ok && !lo <= !hi && (let r = Some (!lo, !hi) in iv.(x) <- r; ivs.(x) <- r; true)
      in
      (* the next count of candidates at which the budget, the stop and the other domains are looked at: the budget
         itself when there is nothing else to look at ([ticks] false: one comparison a candidate, as before them) *)
      let lim = ref (if ticks0 then min cap every else cap) in
      (* the candidates already added to the stop's work, and to the question's shared count *)
      let told = ref 0 and told_s = ref 0 in
      let tell () =
        match stop with
        | Some s -> (if helper then ignore (Atomic.fetch_and_add s.work (!w - !told)) else s.own <- s.own + (!w - !told)); told := !w
        | None -> ()
      in
      let settle () = let d = !w - !told_s in if d <> 0 then (told_s := !w; ignore (Atomic.fetch_and_add ctl.spent d)) in
      let[@inline never] over () =
        tell ();
        (* the question's candidates: this runner's alone, or every domain's while others work beside it *)
        let total = if ctl.shared then (settle (); Atomic.get ctl.spent) else !w in
        if total > ctl.cap then raise (Over_budget budget);
        if Atomic.get abort then raise Stopped;
        (match stop with Some s -> check s | None -> ());
        let left = ctl.cap - total in
        lim := !w + if ctl.ticks && left > every then every else left
      in
      (* a leaf's value read at its thing's level ([kept]): the thing, and the value *)
      let kthing = Array.make n (-1) and kword = Array.make n 0 and kcell = [| 0 |] in
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
      (* the test of pattern j of level i on candidate c: [accepts], or, for a pattern of a leaf ([kept]), its value
         read and kept for the leaf's level *)
      let[@inline never] keep y c pt =
        match Store.value1 v c pt.pp kcell with
        | 0 -> false
        | 1 -> Array.unsafe_set kthing y c; Array.unsafe_set kword y (Array.unsafe_get kcell 0); true
        | _ -> Store.has_value v c pt.pp
      in
      let test i j x c pt =
        let y = Array.unsafe_get (Array.unsafe_get kept i) j in
        if y < 0 then accepts x c pt else keep y c pt
      in
      let count x pt = count_in iv get x pt in
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
            Store.iter_range_values v pt.pp lo hi f
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
          if !j <> src && (not sk.(!j)) && (lf = 0 || !j > 61 || (lf lsr !j) land 1 = 0) && not (test i !j x c ps.(!j)) then ok := false;
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
              if !w > !lim then over ();
              if in_range x c then begin
                let ok = ref true and j = ref 0 in
                while !ok && !j < Array.length ps do
                  if (not sk.(!j)) && not (test i !j x c ps.(!j)) then ok := false;
                  incr j
                done;
                if !ok then f c
              end)
            sv.(x)
        else if src >= 0 then
          iterate x ps.(src) (fun c ->
              incr w;
              if !w > !lim then over ();
              if in_range x c then begin
                let ok = ref true and j = ref 0 in
                while !ok && !j < Array.length ps do
                  if !j <> src && (not sk.(!j)) && not (test i !j x c ps.(!j)) then ok := false;
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
          if !w > !lim then over ();
          if not !sorted then (let s = Array.sub !b 0 !m in Array.sort compare s; Array.blit s 0 !b 0 !m);
          lens.(xi).(j) <- !m;
          keys.(xi).(j) <- key
        end
      in
      (* [cut] is n but while the asking domain collects a level's candidates (the fold's [collect_level]) *)
      let rec level i acc =
        if i = ctl.cut then (if ctl.collecting then ctl.collect () else acc := step !acc env)
        else begin
          let x = ord.(i) in
          let f = func.(i) in
          if any_dyn && dyn.(x) <> [] && not (bounds x) then ()
          else if f >= 0 then begin
            (* the one value of a bound thing's one-valued property *)
            let pt = by_var.(x).(f) in
            let e = match pt.pe with W e -> e | V y -> env.(y) in
            (* read at its thing's level already ([kept]), or now *)
            match if Array.unsafe_get kthing x = e then (cell.(0) <- Array.unsafe_get kword x; 1) else Store.value1 v e pt.pp cell with
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
        (* two candidates or more on the asking domain: the fold may split them ([split]) *)
        if ctl.splitting && size >= 4 && ctl.split i src size acc then ()
        else begin
          bound.(x) <- true;
          (if leap.(i) && src >= 0 && slice.(i).(src) && size >= 4 then leapfrog i src size acc
           else candidates i src (fun c -> env.(x) <- c; level (i + 1) acc));
          bound.(x) <- false
        end
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
      let flush () = ignore (Atomic.fetch_and_add work !w); tell (); w := 0 in
      { env; bound; kthing; kword; w; iterate; admits; level; general; bounds; over; settle; flush; ctl }
    in
    if n = 0 then step (init ()) [||]
    else begin
      let m = runner ~helper:false ~cap:budget ~spent:unshared (match stop with Some _ -> true | None -> false) in
      let d = if seq then 1 else !domains in
      if d > 1 then begin
        (* the split's machinery, made at the first level of two candidates or more: a question that has none
           pays for none of it *)
        let made () =
          (* ---- a level split across the domains ----
             [region i src pre buf from len stride acc]: the candidates buf.(from .. len - 1) of level i (the levels before
             it bound in the asking domain's runner [m]), cut into slices taken in turn by the domains from a shared
             counter (a domain that meets the expensive candidates takes fewer slices), each slice with its own
             accumulator, merged into [acc] in slice order: the answer does not depend on the number of domains nor on
             which domain ran which slice. [pre]: the candidates passed the level's checks already, each with the values
             its checks kept for the leaves ([stride] words a candidate); otherwise they are the source's, as it gives
             them, and each slice checks its own against the level's other patterns, so that no domain does the level
             alone. [any_order]: the merge does not depend on the order of the bindings (a report's groups), so a
             domain folds every slice it takes into one accumulator: one table a domain, not one a slice. *)
          let region i src pre (buf : int array) from len stride acc =
            let x = ord.(i) and cnt = len - from in
            if cnt > 0 then begin
              (* the count every domain adds to, from this first split on *)
              if m.ctl.nsplit = 0 then m.ctl.spent <- Atomic.make 0;
              m.ctl.nsplit <- m.ctl.nsplit + 1;
              Atomic.incr splits;
              if pre && src = -1 then Atomic.incr probed_splits;
              let ys = kept_leaves kept.(i) in
              let slices = max 1 (min cnt (16 * d)) in
              let accs = if any_order then [||] else Array.make slices None and next = Atomic.make 0 in
              (* the asking domain's binding of the levels before i, its leaves' values, for the helpers *)
              let penv = Array.copy m.env and pkt = Array.copy m.kthing and pkw = Array.copy m.kword in
              let run (r : _ runner) (own : _ ref option) =
                r.bound.(x) <- true;
                let go = ref true in
                while !go do
                  let s = Atomic.fetch_and_add next 1 in
                  if s >= slices then go := false
                  else begin
                    let a = match own with Some a -> a | None -> ref (init ()) in
                    for k = from + (s * cnt / slices) to from + ((s + 1) * cnt / slices) - 1 do
                      if pre then begin
                        let o = k * stride in
                        r.env.(x) <- buf.(o);
                        for q = 0 to Array.length ys - 1 do
                          r.kthing.(ys.(q)) <- buf.(o + 1 + (2 * q));
                          r.kword.(ys.(q)) <- buf.(o + 2 + (2 * q))
                        done;
                        r.level (i + 1) a
                      end
                      else begin
                        let c = buf.(k) in
                        if r.admits i src c then (r.env.(x) <- c; r.level (i + 1) a)
                      end
                    done;
                    if not any_order then accs.(s) <- Some !a
                  end
                done;
                r.bound.(x) <- false;
                r.settle ()
              in
              (* the first failure of a domain is the question's; it stops the others at their next check (Stopped) *)
              let failed = Atomic.make None in
              let guarded f =
                match f () with
                | () -> ()
                | exception e ->
                  (match e with Stopped -> () | e -> ignore (Atomic.compare_and_set failed None (Some e)));
                  Atomic.set abort true
              in
              (* this domain looks at the others every [every] candidates while they work, its count shared from now *)
              let ticks0 = m.ctl.ticks in
              m.ctl.shared <- true;
              m.ctl.ticks <- true;
              m.over ();
              m.ctl.splitting <- false;
              (* the other domains from the pool (Pool: as many as it has free, maybe none), each with its own runner and
                 the binding of the levels before i *)
              let hacc = Array.make (max 0 (d - 1)) None and hn = Atomic.make 0 in
              let wait, _ =
                Pool.help (d - 1) (fun () ->
                    guarded (fun () ->
                        let r = runner ~helper:true ~cap:m.ctl.cap ~spent:m.ctl.spent true in
                        Array.blit penv 0 r.env 0 n;
                        Array.blit pkt 0 r.kthing 0 n;
                        Array.blit pkw 0 r.kword 0 n;
                        for k = 0 to i - 1 do r.bound.(ord.(k)) <- true done;
                        if any_dyn && dyn.(x) <> [] then ignore (r.bounds x);
                        let own = if any_order then Some (ref (init ())) else None in
                        Fun.protect ~finally:r.flush (fun () -> run r own);
                        match own with Some a -> hacc.(Atomic.fetch_and_add hn 1) <- Some !a | None -> ()))
              in
              guarded (fun () -> run m (if any_order then Some acc else None));
              wait ();
              m.ctl.splitting <- true;
              m.ctl.ticks <- ticks0;
              (match Atomic.get failed with Some e -> raise e | None -> ());
              (* the budget with the helpers' candidates, and the next look *)
              m.over ();
              Array.iter (function Some a -> acc := merge !acc a | None -> ()) (if any_order then hacc else accs)
            end
          in
          (* the candidates of level i that pass its checks, collected by the asking domain in the level's own order (a
             leapfrog's too), each with the values its checks kept for the leaves: the words, their number, the stride *)
          let collect_level i acc =
            let x = ord.(i) and ys = kept_leaves kept.(i) in
            let stride = 1 + (2 * Array.length ys) in
            let buf = ref (Array.make (16 * stride) 0) and len = ref 0 in
            m.ctl.collect <-
              (fun () ->
                let o = !len * stride in
                if o + stride > Array.length !buf then (let nb = Array.make (2 * Array.length !buf) 0 in Array.blit !buf 0 nb 0 o; buf := nb);
                let b = !buf in
                b.(o) <- m.env.(x);
                for q = 0 to Array.length ys - 1 do
                  b.(o + 1 + (2 * q)) <- m.kthing.(ys.(q));
                  b.(o + 2 + (2 * q)) <- m.kword.(ys.(q))
                done;
                incr len);
            m.ctl.splitting <- false;
            m.ctl.cut <- i + 1;
            m.ctl.collecting <- true;
            Fun.protect ~finally:(fun () -> m.ctl.splitting <- true; m.ctl.cut <- n; m.ctl.collecting <- false) (fun () -> m.general i acc);
            !buf, !len, stride
          in
          (* a level of [parallel_min] candidates or more (exact counts): split. Its source's candidates as they come (a
             leapfrog's level collected, in its order); then, the first level of two candidates or more past those of one
             ([top]), when the planner expects [probe_more] times [parallel_min] candidates of work or more: probed. Its candidates run here,
             one after the other, until the work they took, measured (every candidate counted below them), says that
             the rest would take [probe_more] times [parallel_min] or more, at the same rate: the rest is split, if there are 2 a domain
             left at least. So a question is split only where a level offers that much (counted), or where its work was
             seen (measured): a small question never pays for the split, nor for the probe unless the planner expected a
             large one. *)
          let wide i src c acc =
            let x = ord.(i) in
            if leap.(i) && src >= 0 && slice.(i).(src) then begin
              let buf, len, stride = collect_level i acc in
              region i src true buf 0 len stride acc
            end
            else begin
              (* the source's candidates: [c] at most (its count is exact, or more for a property's values and
                 holders), each counted *)
              let firsts = Array.make (max 1 c) 0 and k = ref 0 in
              let add cand = firsts.(!k) <- cand; incr k in
              m.bound.(x) <- true;
              if src = -2 then Array.iter add sv.(x) else m.iterate x by_var.(x).(src) add;
              m.bound.(x) <- false;
              m.w := !(m.w) + !k;
              region i src false firsts 0 !k 1 acc
            end
          in
          let probed i acc =
            let x = ord.(i) and ys = kept_leaves kept.(i) in
            let buf, len, stride = collect_level i acc in
            if len >= 2 then m.ctl.top <- false;
            let w0 = !(m.w) and j = ref 0 and go = ref true in
            m.bound.(x) <- true;
            while !go && !j < len do
              let o = !j * stride in
              m.env.(x) <- buf.(o);
              for q = 0 to Array.length ys - 1 do
                m.kthing.(ys.(q)) <- buf.(o + 1 + (2 * q));
                m.kword.(ys.(q)) <- buf.(o + 2 + (2 * q))
              done;
              m.level (i + 1) acc;
              incr j;
              let rest = len - !j and took = !(m.w) - w0 in
              if rest >= 2 * d && took >= !probe_min && float_of_int took *. float_of_int rest >= float_of_int (!probe_more * !parallel_min) *. float_of_int !j then begin
                go := false;
                m.bound.(x) <- false;
                region i (-1) true buf !j len stride acc
              end
            done;
            m.bound.(x) <- false
          in
          fun i src size acc ->
            let c = size / 2 in
            if c >= !parallel_min then begin
              if i = 0 then m.ctl.cap <- (if budget > max_int / d then max_int else budget * d);
              m.ctl.top <- false;
              wide i src c acc;
              true
            end
            else (probed i acc; true)
        in
        let hook = ref None in
        m.ctl.splitting <- true;
        m.ctl.split <-
          (fun i src size acc ->
            (* a level to split, or the first of two candidates or more when the planner expects much work: the
               machinery; otherwise no split, nothing made *)
            if size / 2 >= !parallel_min || (m.ctl.top && cost >= float_of_int (!probe_more * !parallel_min)) then begin
              let f = match !hook with Some f -> f | None -> let f = made () in hook := Some f; f in
              f i src size acc
            end
            else (m.ctl.top <- false; false))
      end;
      let acc = ref (init ()) in
      m.level 0 acc;
      (match account with Some r -> r := !r + (if m.ctl.nsplit = 0 then !(m.w) else (m.settle (); Atomic.get m.ctl.spent)) | None -> ());
      m.flush ();
      !acc
    end

let rows ?stop (v : Store.view) q =
  match compile v q with
  | exception No_answer -> []
  | ty, _, _, _ ->
    let rows =
      fold ?stop v q ~init:(fun () -> []) ~merge:(fun a b -> b @ a)
        ~step:(fun acc env -> Array.mapi (fun i w -> Store.value v ty.(i) w) env :: acc)
    in
    List.rev rows

let count (v : Store.view) q = fold v q ~init:(fun () -> 0) ~step:(fun n _ -> n + 1) ~merge:( + )

let var_types = types
