(* The answer of a question with its select on a view, the same at the server (Core) and in a program that reads
   locally (Client): the rows as index words, no value built, so that the server codes them straight onto the wire. *)

open Cepheus
module Ask = Question.Ask
module Top = Question.Top

(* rows as index words, a flat array a domain *)
type acc = { mutable a : int array; mutable n : int }

let push acc w =
  if acc.n = Array.length acc.a then begin
    let a = Array.make (max 64 (2 * acc.n)) 0 in
    Array.blit acc.a 0 a 0 acc.n;
    acc.a <- a
  end;
  acc.a.(acc.n) <- w;
  acc.n <- acc.n + 1

let append a b = for i = 0 to b.n - 1 do push a b.a.(i) done; a

(* The answer of a question with its select on [v], the same at the server and in a local reader: its columns, its
   rows, the type of each column, the index word of each cell (no value built), and whether a cell is missing (an
   Optional's variable with no value: its word is then 0). A report's aggregates of protocol 9 (an average, a
   quantile: values no index holds) are [computed]: their cells are values, [cell]. Raises Query.Bad. *)
type answer = {
  cols : int;
  n : int;
  typ : int -> Value.typ;
  word : int -> int -> int;
  missing : int -> int -> bool;
  computed : int -> bool;
  cell : int -> int -> Value.t;
}

let none_missing _ _ = false
let none_computed _ = false
let no_cell _ _ = Value.missing

(* the answer from rows held whole (sorted, cut); [masked]: each row has the mask of its missing cells after its
   columns (Top) *)
let of_rows ?(masked = false) cols (typs : Value.typ array) (rows : int array array) =
  { cols; n = Array.length rows; typ = (fun j -> typs.(j)); word = (fun i j -> rows.(i).(j));
    missing = (if masked then fun i j -> Top.missing cols rows.(i) j else none_missing); computed = none_computed; cell = no_cell }

(* the answer of rows of values (a report's) *)
let of_values cols (typs : Value.typ array) (rows : Value.t array array) =
  { cols; n = Array.length rows; typ = (fun j -> typs.(j)); word = (fun _ _ -> 0); missing = (fun i j -> Value.is_missing rows.(i).(j));
    computed = (fun _ -> true); cell = (fun i j -> rows.(i).(j)) }

(* the value of a cell *)
let value (v : Store.view) (a : answer) i j =
  if a.missing i j then Value.missing else if a.computed j then a.cell i j else Store.value v (a.typ j) (a.word i j)

let lead = Top.lead

(* the work a question may take at the server, in lookups of its join (each domain's, and its Nots' together): past
   it, Query.Over_budget, and the program is told to ask a narrower question; a program reading in its own memory has
   no budget but its own *)
let question_budget = ref 1_000_000_000

(* Query.fold counts candidates, and each candidate of a variable is looked up in every other pattern of that
   variable: a question that repeats one pattern a thousand times does a thousand lookups a candidate within the same
   count. So the candidates a question may take are its budget of lookups over the most patterns one variable has, its
   Nots' and alternatives' included: the lookups stay within [question_budget] whatever the question's shape. *)
let work_budget (q : Query.t) extra =
  let per = Hashtbl.create 8 in
  let note = function Query.Var x -> Hashtbl.replace per x (1 + Option.value (Hashtbl.find_opt per x) ~default:0) | _ -> () in
  List.iter (fun (pt : Query.pattern) -> note pt.e; if pt.v <> pt.e then note pt.v) (Ask.patterns q extra);
  !question_budget / max 1 (Hashtbl.fold (fun _ n m -> max n m) per 0)

(* ---- the memory of an answer at the server ----
   An answer the server holds while it builds it (sorted, grouped, or a watch's) takes memory in proportion to its
   cells, its rows times its columns; and a question's rows are not bounded by its size: patterns that share no
   variable are a cross product, |R| x |S| rows for two of them (the AGM bound, Atserias, Grohe, Marx, FOCS 2008, is
   the product of the relations' sizes when no variable is shared), so a 16-byte Find of two patterns over 12,000
   facts is 144 million rows. Each such answer carries a ticket: its cells are charged to it as its accumulators grow,
   against [max_cells], its own bound, and against [pool_cells], the bound of every ticket at once (the connections
   run their questions at the same time); past either, Too_large, and the program is told too_large. A cell is a word
   (8 bytes) in a flat accumulator, (cols + 2) / cols words in a sorted one's rows, more while an array doubles and its
   old copies wait for the collector; a watch's answer, whose rows become values, counts four cells a cell (Live).
   Measured at [max_cells], the peak above a server's base: 128 MiB sorted, 167 MiB grouped, 57 MiB a watch's, so the
   pool's four questions take about 0.7 GiB at most, under a tenth of the documented unit's MemoryMax of 8 GiB. A Find
   of a Give without Sort past them is asked again, and its rows coded as they come, none held ([stream]); a program
   reading in its own memory has no ticket. *)
let max_cells = ref (1 lsl 23)
let pool_cells = ref (1 lsl 25)

(* the cells charged now by every ticket *)
let pool = Atomic.make 0

exception Too_large of string

type ticket = { used : int Atomic.t }

let charge t n =
  let p = Atomic.fetch_and_add pool n + n in
  let u = Atomic.fetch_and_add t.used n + n in
  if u > !max_cells then
    raise (Too_large (Printf.sprintf "the answer passed the server's budget of %d cells (rows times columns): ask a narrower question, or pages with Sort, Limit and After" !max_cells));
  if p > !pool_cells then
    raise (Too_large (Printf.sprintf "the answers the server is building hold its budget of %d cells: ask again in a moment, or a narrower question" !pool_cells))

let release t = let u = Atomic.exchange t.used 0 in ignore (Atomic.fetch_and_add pool (-u))

(* [f] with a ticket, given back whatever [f] does *)
let with_ticket f = let t = { used = Atomic.make 0 } in Fun.protect ~finally:(fun () -> release t) (fun () -> f t)

(* cells are charged by grains of 4,096 (a flat accumulator's words): one atomic addition a grain *)
let grain = 4096

(* A source's fold whose accumulators charge their rows of [cols] cells, [bound] rows an accumulator at most (a heap
   cuts itself back once it holds max(64, 2 Limit): Top.push). Top keeps at most [bound] rows of a fold that has
   returned (the windows of the index path, one after another): the charge above [base] (the ticket's when the Give
   began) and those rows is then given back. *)
type 'a counted = { mutable acc : 'a; mutable rows : int; mutable left : int }

let counted t ~base ~cols ~bound fold ~init ~step ~merge =
  let cols = max 1 cols in
  let every = max 1 (grain / cols) in
  let r =
    fold ~init:(fun () -> { acc = init (); rows = 0; left = every })
      ~step:(fun c env ->
        let a = step c.acc env in
        if a != c.acc then c.acc <- a;
        if c.rows < bound then begin
          c.rows <- c.rows + 1;
          c.left <- c.left - 1;
          if c.left = 0 then (c.left <- every; charge t (every * cols))
        end;
        c)
      ~merge:(fun a b -> a.acc <- merge a.acc b.acc; a.rows <- min bound (a.rows + b.rows); a)
  in
  if bound < max_int then begin
    let keep = base + (bound * cols) and now = Atomic.get t.used in
    if now > keep then (ignore (Atomic.fetch_and_add t.used (keep - now)); ignore (Atomic.fetch_and_add pool (keep - now)))
  end;
  r.acc

(* the question's types and checks, and its fold (Not, Or and In beside the patterns and ranges: through Ask);
   [masked]: it has Optionals, its bindings a mask after their variables; [derived]: its Truncs, variables nv, nv + 1,
   ... computed from a date's word as a row is given (the join never sees them) *)
type prepared = {
  ask : Ask.t option;
  ty : Value.typ array;  (* every variable's, the Truncs' after the question's *)
  masked : bool;
  nv : int;
  derived : (int * (int -> int)) array;
  var : int -> unit;
  fold :
    'a. ?seq:bool -> ?any_order:bool -> ?window:Top.window -> init:(unit -> 'a) -> step:('a -> int array -> 'a) -> merge:('a -> 'a -> 'a) -> unit -> 'a;
}

let prepare ~extra ~budget ?stop (v : Store.view) (q : Query.t) =
  let truncs, extra = Ask.truncs extra in
  let ask = if extra = [] then None else Some (Ask.compile v q extra) in
  let ty = match ask with None -> Query.types v q | Some a -> Ask.typs_of a in
  let derived = Ask.derived ~name:(fun x -> Ask.var_name v (Ask.patterns q extra) x) ~vars:q.vars ~outer:(fun x -> match ask with Some a -> a.outer.(x) | None -> true) ty truncs in
  let ty = if derived = [||] then ty else Array.append ty (Array.make (Array.length derived) Value.Tdate) in
  let var x =
    if x < 0 || x >= q.vars + Array.length derived then Query.bad "variable %d out of range" x;
    match ask with
    | Some a when x < q.vars && not a.outer.(x) -> Query.bad "variable %d is a Not's or an Or's own: Give and Sort take the question's variables" x
    | _ -> ()
  in
  let fold ?seq ?any_order ?window ~init ~step ~merge () =
    match ask, window with
    | None, None -> Query.fold ?seq ?any_order ~budget ?stop v q ~init ~step ~merge
    | None, Some (Top.Range (x, lo, hi)) -> Query.fold ?seq ?any_order ~budget ?stop v { q with ranges = (x, lo, hi) :: q.ranges } ~init ~step ~merge
    | None, Some (Top.Words (x, ws)) -> Query.fold ?seq ?any_order ~sets:[ (x, ws) ] ~budget ?stop v q ~init ~step ~merge
    | Some a, None -> Ask.fold ?seq ?any_order ~shared:true ~budget ?stop v a ~init ~step ~merge
    | Some a, Some (Top.Range (x, lo, hi)) -> Ask.fold ?seq ?any_order ~shared:true ~budget ?stop ~range:(x, lo, hi) v a ~init ~step ~merge
    | Some a, Some (Top.Words (x, ws)) -> Ask.fold ?seq ?any_order ~shared:true ~budget ?stop ~words:(x, ws) v a ~init ~step ~merge
  in
  (* every step of the answers reads its binding and keeps none: an Ask's bindings in one buffer a domain *)
  let masked = match ask with Some a -> Array.length a.opts > 0 | None -> false in
  { ask; ty; masked; nv = q.vars; derived; var; fold }

(* the row of [give] of a binding: with the mask of its missing columns after them when the question has Optionals;
   a Trunc's column computed from its date's *)
let projector (p : prepared) give =
  if p.derived <> [||] then Ask.derived_projector ~vars:p.nv ~mask:p.masked p.derived give
  else match p.ask with Some a -> Ask.projector a give | None -> fun env -> Array.map (fun x -> env.(x)) give

(* the word of variable x in a binding (a Trunc's computed), and whether it is missing (an Optional's, or a Trunc of
   one) *)
let getter (p : prepared) x = if x < p.nv then fun (env : int array) -> env.(x) else let s, f = p.derived.(x - p.nv) in fun env -> f env.(s)

let misser (p : prepared) x =
  if not p.masked then fun _ -> false
  else let s = if x < p.nv then x else fst p.derived.(x - p.nv) in let m = p.nv in fun (env : int array) -> (env.(m) lsr s) land 1 = 1

(* A Give without Sort that holds none of its rows: its columns' types, and [rows f], which gives [f] the words of
   each row's columns as the fold finds it (on one domain, in the engine's order: Query.fold's seq; the same rows in
   the same order as [answer]'s), [f] reading them before it returns. None when the question cannot be streamed: an
   Or whose alternatives have variables of their own keeps every binding to give each once (Ask.fold), so it is held
   and counted as an answer. Raises Query.Bad. *)
let stream ?(extra = []) ?(budget = max_int) ?stop (v : Store.view) (q : Query.t) give =
  let ({ ask; ty; masked; var; fold; _ } as p) = prepare ~extra ~budget ?stop v q in
  match ask with
  | Some a when List.exists (fun (c : Ask.conj) -> c.free <> []) a.conjs -> None
  | _ ->
    let give = if Array.length give = 0 then Array.init q.vars Fun.id else give in
    Array.iter var give;
    let k = Array.length give in
    let rows f =
      if masked || p.derived <> [||] then (let project = projector p give in fold ~seq:true ~init:ignore ~merge:(fun () () -> ()) ~step:(fun () env -> f (project env)) ())
      else begin
        let row = Array.make k 0 in
        fold ~seq:true ~init:ignore ~merge:(fun () () -> ())
          ~step:(fun () env -> for i = 0 to k - 1 do row.(i) <- env.(give.(i)) done; f row) ()
      end
    in
    Some (Array.map (fun x -> ty.(x)) give, rows)

(* ---- the groups of a Group: one table of open addressing over the key words, in flat arrays ----
   A group is a number: its key's words at that place in one array (with Optionals, the mask of its missing columns
   after them), its Count, Sum, Min and Max in another, the states of its other aggregates in their columns (Agg.col:
   four ints of exact sums, or its entries in the column's one bag), found by its key's hash (linear probing, the
   table at most half full): a binding costs a hash and no allocation, a new group a few words. A table a domain (the
   fold's [any_order]: these aggregates do not depend on the order of the bindings), merged at the end; the groups
   then in the order of their keys' words, whatever the number of domains. *)
type table = {
  kw : int;  (* a key's words *)
  na : int;
  start : int array;  (* a new group's Count, Sum, Min and Max: 0, 0, max_int, min_int *)
  cols : Agg.col option array;  (* the aggregates of protocol 9 *)
  mutable keys : int array;  (* group g's key at g kw *)
  mutable vals : int array;  (* group g's Count, Sum, Min and Max at g na *)
  mutable slots : int array;  (* 1 + a group, 0 an empty slot; a power of 2 *)
  mutable n : int;
  buf : int array;  (* a binding's key, made here: the table's domain's own *)
  mutable cells : int;  (* the cells the table has not charged yet *)
  mutable carry : int array;  (* a Sum's carry at g na + i (Agg.wrapped), [||] until one wraps *)
}

let table ~kw ~na ~start ~(cols : (unit -> Agg.col) option array) () =
  { kw; na; start; cols = Array.map (Option.map (fun mk -> mk ())) cols; keys = Array.make (16 * max 1 kw) 0;
    vals = Array.make (16 * max 1 na) 0; slots = Array.make 32 0; n = 0; buf = Array.make (max 1 kw) 0; cells = 0; carry = [||] }

(* the Sum at [k] (g na + i) wrapped [d] times more: its carry, the table's made at the first *)
let[@inline never] carry_add t k d =
  if Array.length t.carry <= k then t.carry <- Agg.grow_ints t.carry (max (k + 1) (t.n * t.na));
  t.carry.(k) <- t.carry.(k) + d

let carry_of t k = if k < Array.length t.carry then t.carry.(k) else 0

let key_hash (k : int array) o kw =
  let h = ref kw in
  for j = o to o + kw - 1 do h := (!h + Array.unsafe_get k j) * 0x2545F4914F6CDD1D done;
  !h lxor (!h lsr 29)

let rehash t =
  let size = 2 * Array.length t.slots in
  let sl = Array.make size 0 and m = size - 1 in
  for g = 0 to t.n - 1 do
    let i = ref (key_hash t.keys (g * t.kw) t.kw land m) in
    while sl.(!i) <> 0 do i := (!i + 1) land m done;
    sl.(!i) <- g + 1
  done;
  t.slots <- sl

(* the group of the key in [t.buf]; a new one is made the last, [t.n] one more *)
let group t =
  let kw = t.kw and buf = t.buf and keys = t.keys in
  let m = Array.length t.slots - 1 in
  let i = ref (key_hash buf 0 kw land m) and g = ref (-1) in
  while !g < 0 do
    let s = Array.unsafe_get t.slots !i in
    if s = 0 then begin
      let ng = t.n in
      t.keys <- Agg.grow_ints t.keys ((ng + 1) * kw);
      t.vals <- Agg.grow_ints t.vals ((ng + 1) * t.na);
      Array.blit buf 0 t.keys (ng * kw) kw;
      Array.blit t.start 0 t.vals (ng * t.na) t.na;
      Array.iter (function Some c -> Agg.col_room c (ng + 1) | None -> ()) t.cols;
      t.slots.(!i) <- ng + 1;
      t.n <- ng + 1;
      g := ng;
      if 2 * t.n > Array.length t.slots then rehash t
    end
    else begin
      let o = (s - 1) * kw in
      let j = ref 0 in
      while !j < kw && Array.unsafe_get keys (o + !j) = Array.unsafe_get buf !j do incr j done;
      if !j = kw then g := s - 1 else i := (!i + 1) land m
    end
  done;
  !g

(* the groups of b into a: their keys found or made, their aggregates joined *)
let merge_tables (aggs : Wire.agg array) a b =
  let na = a.na and map = Array.make (max 1 b.n) 0 in
  for gb = 0 to b.n - 1 do
    Array.blit b.keys (gb * b.kw) a.buf 0 a.kw;
    let ga = group a in
    map.(gb) <- ga;
    let va = a.vals and oa = ga * na and ob = gb * na in
    for i = 0 to na - 1 do
      let y = b.vals.(ob + i) in
      match aggs.(i) with
      | Wire.Count -> va.(oa + i) <- va.(oa + i) + y
      | Sum _ ->
        let s = va.(oa + i) in
        let r = s + y in
        va.(oa + i) <- r;
        if Agg.wrapped s y r then carry_add a (oa + i) (if y >= 0 then 1 else -1);
        let c = carry_of b (ob + i) in
        if c <> 0 then carry_add a (oa + i) c
      | Min _ -> if y < va.(oa + i) then va.(oa + i) <- y
      | Max _ -> if y > va.(oa + i) then va.(oa + i) <- y
      | _ -> ()
    done
  done;
  Array.iteri (fun i c -> match c, b.cols.(i) with Some ca, Some cb -> Agg.col_merge ca cb map b.n | _ -> ()) a.cols;
  a

(* the groups in the order of their keys' words *)
let sorted t =
  let ord = Array.init t.n Fun.id and kw = t.kw and keys = t.keys in
  Array.sort
    (fun a b ->
      let oa = a * kw and ob = b * kw in
      let j = ref 0 in
      while !j < kw && Array.unsafe_get keys (oa + !j) = Array.unsafe_get keys (ob + !j) do incr j done;
      if !j = kw then 0 else compare (Array.unsafe_get keys (oa + !j) : int) (Array.unsafe_get keys (ob + !j)))
    ord;
  ord

(* an aggregate for a message: Sum(invoice/total), Count() *)
let agg_text name (a : Wire.agg) = match Agg.var_of a with Some x -> Printf.sprintf "%s(%s)" (Agg.name a) (name x) | None -> Agg.name a ^ "()"

(* A Sum past the 63 bits of an Int in a group (its carry not 0): the question refused, naming the Sum's variable by
   its property ([name]) and the first such group in [groups]' order by its keys' values ([key j g]), so that the
   same question gives the same message whatever the domains. A group cut by Limit or After is no less refused: Sort
   may order by that sum, and a report is its groups' sums. *)
let check_sums ~(name : int -> string) ~(key : int -> int -> Value.t) nk (aggs : Wire.agg array) (t : table) groups =
  if Array.length t.carry > 0 then
    Array.iter
      (fun g ->
        Array.iteri
          (fun i a ->
            match a with
            | Wire.Sum x when carry_of t ((g * t.na) + i) <> 0 -> Agg.past_sum (name x) (List.init nk (fun j -> Agg.short (key j g)))
            | _ -> ())
          aggs)
      groups

(* group g's key j as a value (a message's) *)
let key_value (v : Store.view) (ty : Value.typ array) keys ~masked (t : table) j g =
  let nk = Array.length keys in
  if masked && (t.keys.((g * t.kw) + nk) lsr j) land 1 = 1 then Value.missing else Store.value v ty.(keys.(j)) t.keys.((g * t.kw) + j)

(* a binding's key into [buf]: the words of [keys] (a Trunc's computed), and with Optionals the mask of the missing
   ones after them, as [projector] gives them *)
let key_into (p : prepared) keys : int array -> int array -> unit =
  let nk = Array.length keys in
  if (not p.masked) && p.derived = [||] then fun env buf -> for j = 0 to nk - 1 do Array.unsafe_set buf j env.(keys.(j)) done
  else begin
    let words = Array.map (getter p) keys and miss = Array.map (misser p) keys in
    if not p.masked then fun env buf -> for j = 0 to nk - 1 do buf.(j) <- words.(j) env done
    else
      fun env buf ->
        let m = ref 0 in
        for j = 0 to nk - 1 do
          if miss.(j) env then (buf.(j) <- 0; m := !m lor (1 lsl j)) else buf.(j) <- words.(j) env
        done;
        buf.(nk) <- !m
  end

let start_of aggs = Array.map (function Wire.Min _ -> max_int | Wire.Max _ -> min_int | _ -> 0) aggs

(* ---- a report: Group with Truncs or aggregates of protocol 9 ----
   Its groups in a table (above): the words of its Count, Sum, Min and Max as the plain path's, the state of each
   other aggregate in its column (Agg: exact sums, a bag). Its rows are then values: the groups in the order of their
   keys' words (as the plain path), or sorted and cut by Sort, Limit and After as groups (a Values column takes no
   part in the order: no two groups have one key), and each group then a row a value of its Values (Agg.flatten). The
   cells of the keys, of the bags' new values and of the rows are charged to the ticket. *)
let agg_word (ty : Value.typ array) (a : Wire.agg) w : Value.t =
  match Agg.var_of a with
  | None -> Int w
  | Some x -> (match ty.(x) with Tmoney _ -> Money w | Tdate -> Date w | _ -> Int w)

let report ~(order : Top.order) ?ticket ~weight ~name (v : Store.view) (p : prepared) ~optional keys aggs =
  let ty = p.ty in
  Array.iter p.var keys;
  Array.iter
    (fun a ->
      match a, Agg.var_of a with
      | _, None -> ()
      | (Wire.Sum _ | Min _ | Max _), Some x ->
        p.var x;
        if optional x then Query.bad "Sum, Min and Max take a variable of a pattern, not an Optional's, which may be missing: give its values, or Count the rows";
        (match a, ty.(x) with
         | Wire.Sum _, (Tint | Tmoney _) | (Min _ | Max _), (Tint | Tmoney _ | Tdate) -> ()
         | Wire.Sum _, t -> Query.bad "a sum of a %s variable" (Value.typ_name t)
         | _, t -> Query.bad "a min or max of a %s variable" (Value.typ_name t))
      | a, Some x -> p.var x; Agg.check a ty.(x) ~optional:(optional x))
    aggs;
  let nk = Array.length keys and na = Array.length aggs in
  let kw = if p.masked then nk + 1 else nk in
  let key = key_into p keys in
  let gets = Array.map (fun a -> match Agg.var_of a with Some x -> getter p x | None -> fun _ -> 0) aggs in
  let misses = Array.map (fun a -> match Agg.var_of a with Some x -> misser p x | None -> fun _ -> false) aggs in
  let txs = Array.map (fun a -> match Agg.var_of a with Some x -> ty.(x) | None -> Value.Tint) aggs in
  let width = weight * max 1 (nk + na) in
  let charge_cells (t : table) n =
    match ticket with
    | None -> ()
    | Some tk -> t.cells <- t.cells + n; if t.cells >= grain then (charge tk t.cells; t.cells <- 0)
  in
  let cols = Array.mapi (fun i a -> if Agg.is_new a then Some (fun () -> Agg.col a txs.(i)) else None) aggs in
  let tl =
    p.fold ~any_order:true ~init:(table ~kw ~na ~start:(start_of aggs) ~cols)
      ~merge:(fun a b ->
        let a = merge_tables aggs a b in
        (* each table counts its own cells: what one has not charged yet goes on to the other *)
        charge_cells a b.cells;
        a)
      ~step:(fun t env ->
        key env t.buf;
        let n0 = t.n in
        let g = group t in
        if t.n > n0 then charge_cells t width;
        let o = g * na and vals = t.vals in
        for i = 0 to na - 1 do
          match aggs.(i) with
          | Wire.Count -> vals.(o + i) <- vals.(o + i) + 1
          | Sum _ ->
            let s = vals.(o + i) and x = gets.(i) env in
            let r = s + x in
            vals.(o + i) <- r;
            if Agg.wrapped s x r then carry_add t (o + i) (if x >= 0 then 1 else -1)
          | Min _ -> let x = gets.(i) env in if x < vals.(o + i) then vals.(o + i) <- x
          | Max _ -> let x = gets.(i) env in if x > vals.(o + i) then vals.(o + i) <- x
          | _ -> (
            match t.cols.(i) with
            | Some c when not (misses.(i) env) -> if Agg.col_add v txs.(i) c g (gets.(i) env) then charge_cells t (weight * Agg.entry_cells)
            | _ -> ())
        done;
        t) ()
  in
  (* and the last ones, under a grain *)
  (match ticket with Some tk when tl.cells > 0 -> charge tk tl.cells; tl.cells <- 0 | _ -> ());
  let groups = sorted tl in
  check_sums ~name ~key:(key_value v ty keys ~masked:p.masked tl) nk aggs tl groups;
  let by = Array.map (function Some c -> Agg.by_group c tl.n | None -> [||], [||], [||]) tl.cols in
  (* the order of a bag column's words, once a column (a text's read once) *)
  let cmps = Array.mapi (fun i a -> match a with Wire.Values _ | Quantile _ -> Agg.order v txs.(i) | _ -> Agg.int_order) aggs in
  let typs = Array.init (nk + na) (fun j -> if j < nk then ty.(keys.(j)) else Agg.typ aggs.(j - nk) txs.(j - nk)) in
  let cells g =
    let ok = g * kw in
    Array.init (nk + na) (fun j ->
        if j < nk then Agg.One (if p.masked && (tl.keys.(ok + nk) lsr j) land 1 = 1 then Value.missing else Store.value v ty.(keys.(j)) tl.keys.(ok + j))
        else begin
          let i = j - nk in
          match aggs.(i), tl.cols.(i) with
          | Wire.Values _, Some _ -> Agg.Many (Array.map (Store.value v txs.(i)) (Agg.col_values cmps.(i) g by.(i)))
          | a, Some c -> Agg.One (Agg.col_result ~cmp:cmps.(i) v a txs.(i) c g by.(i))
          | a, None -> Agg.One (agg_word ty a tl.vals.((g * na) + i))
        end)
  in
  let gs = Array.map cells groups in
  let gs =
    if order = Top.none then gs
    else begin
      let cols = nk + na in
      Top.check cols typs order;
      List.iter (fun (k : Top.key) -> match k.col >= nk, (if k.col >= nk then aggs.(k.col - nk) else Wire.Count) with true, Wire.Values _ -> Query.bad "Sort's keys are not a Values column: it is a list" | _ -> ()) order.keys;
      (* a Values column a constant: it takes no part in the order *)
      let plain c = Array.map (function Agg.One x -> x | Agg.Many _ -> Value.Int 0) c in
      let ord = Top.full cols order.keys in
      let cmp a b = Top.compare_value_rows ord (plain a) (plain b) in
      let gs =
        match order.after with
        | None -> gs
        | Some a ->
          let cur =
            Array.mapi
              (fun j x ->
                if j >= nk && (match aggs.(j - nk) with Wire.Values _ -> true | _ -> false) then Value.Int 0
                else begin
                  if not (Value.is_missing x || Value.has_type typs.(j) x) then Query.bad "After's column %d needs a %s, not %s" j (Value.typ_name typs.(j)) (Value.to_string x);
                  x
                end)
              a
          in
          Array.of_list (List.filter (fun g -> Top.compare_value_rows ord (plain g) cur > 0) (Array.to_list gs))
      in
      let gs = Array.copy gs in
      Array.stable_sort cmp gs;
      if order.limit > 0 && Array.length gs > order.limit then Array.sub gs 0 order.limit else gs
    end
  in
  let rows = Array.of_list (List.concat_map Agg.flatten (Array.to_list gs)) in
  Option.iter (fun t -> charge t (Array.length rows * width)) ticket;
  of_values (nk + na) typs rows

(* ---- windows and Each (protocol 10): Over ----
   The rows of a Give or a report in Sort's order, then each window's column computed over them (Window), each group
   of Each apart; then After and Limit. So a window reads every row before the page's: a page's running total counts
   the rows of the pages before it, its Rank and Prev see them. The rows a window needs, by case:
   - no After: Limit k alone, the first k rows and their copies (Top.give: the heap or the index path, a sorted
     page's seek kept), whose windows read only rows before them; with Each, the first k of each group, a buffer of at
     most 2 k rows a group, cut back to its first k as Top's heap is (O(n log k) comparisons, O(groups k) rows held);
     no Limit, every row sorted;
   - After (no Each): every row sorted, the windows computed, then the rows after the cursor and the first k of them.
   Their cells, the groups' keys and the windows' values are charged to the ticket. *)

(* rows into groups by a key: 0, 1, ... in the order of their first rows *)
let partition n (key : int -> string) =
  let t = Hashtbl.create 64 and part = Array.make n 0 in
  for i = 0 to n - 1 do
    let k = key i in
    match Hashtbl.find_opt t k with
    | Some g -> part.(i) <- g
    | None -> let g = Hashtbl.length t in Hashtbl.add t k g; part.(i) <- g
  done;
  part, Hashtbl.length t

(* the rows to keep of [n] rows in Sort's order: those after the cursor [after] (if any), then the first [limit] of
   each group (the whole answer's without Each) and the copies of its [limit]-th, which follow it; [same i j]: rows i
   and j are the same row *)
let keep_rows n ~after ~limit ~part ~same =
  let groups = Array.fold_left (fun m g -> max m (g + 1)) 1 part in
  let cnt = Array.make groups 0 and last = Array.make groups (-1) in
  let out = ref [] in
  for i = 0 to n - 1 do
    if after i then begin
      let g = part.(i) in
      if limit = 0 || cnt.(g) < limit then (cnt.(g) <- cnt.(g) + 1; last.(g) <- i; out := i :: !out)
      else if same last.(g) i then out := i :: !out
    end
  done;
  Array.of_list (List.rev !out)

(* the pages of windows after a cursor, and those of them whose rows before it were read from a range of the first key:
   for the tests *)
let paged = Atomic.make 0
let ranged = Atomic.make 0

(* the state of Each's first k rows of each group, a domain's: its groups' keys in a table (Answer's), each group's
   buffer, the rows each has held at most (charged), and its k-th row at its last cut ([||]: none yet), past which a
   row cannot be one of its first k: one comparison, where most rows of a large group would be pushed and sorted *)
(* Each's Limit k up to which a group's buffer is kept in the order, a row at its place (the tests make it 0 or large) *)
let small_each = ref 32

type firsts = { gt : table; mutable bufs : Top.acc array; mutable held : int array; mutable kth : int array array; cmp : int array -> int array -> int }

(* what the rows at or before a page's cursor give its windows, a domain's: their count, each window's exact sums or
   best value (a frame from the first row), the rows tied with the cursor and the different places (Rank), and the
   last of them (in the reverse order) *)
type prefix = {
  mutable count : int;
  sums : Agg.sums option array;
  best : Value.t array;
  ties : int array;
  places : (string, unit) Hashtbl.t option array;
  tail : Top.acc;
  mutable cells : int;  (* the places' cells not charged yet *)
}

let rec answer ?(order = Top.none) ?(extra = []) ?(budget = max_int) ?stop ?ticket ?(weight = 1) (v : Store.view) (q : Query.t) (sel : Wire.select) =
  let ({ ask; ty; masked; var; fold; _ } as p) = prepare ~extra ~budget ?stop v q in
  (* a variable named for a message (a Sum past 63 bits): its property *)
  let name x = Ask.var_name v (Ask.patterns q extra) x in
  (* an Optional's variable may be missing: no Sum, Min or Max of it (nor of a Trunc of it) *)
  let optional x =
    let x = if x < q.vars then x else fst p.derived.(x - q.vars) in
    match ask with Some a -> Array.exists (fun (o : Ask.opt) -> o.ov = x) a.opts | None -> false
  in
  (* the rows of a Give in an order, as Top reads them: [limit] the rows each fold's accumulator holds at most *)
  let source give limit =
    let bound = if limit > 0 then max 64 (2 * limit) else max_int in
    let base = match ticket with Some t -> Atomic.get t.used | None -> 0 in
    { Top.fold =
        (fun window ~seq ~init ~step ~merge ->
          match ticket with
          | None -> fold ~seq ?window ~init ~step ~merge ()
          | Some t -> counted t ~base ~cols:(weight * max 1 (Array.length give)) ~bound (fun ~init ~step ~merge -> fold ~seq ?window ~init ~step ~merge ()) ~init ~step ~merge);
      project = projector p give;
      (* a Trunc's column has no index of its own: the heap path sorts it *)
      var = (fun c -> if give.(c) < q.vars then Some give.(c) else None);
      lead = lead v q;
      estimate = (fun () -> match ask with None -> Query.estimate v q | Some a -> Ask.estimate v a) }
  in
  let charge_opt n = match ticket with Some t -> charge t (weight * n) | None -> () in
  match sel with
  | Wire.Give give when order <> Top.none ->
    let give = if Array.length give = 0 then Array.init q.vars Fun.id else give in
    Array.iter var give;
    let typs = Array.map (fun x -> ty.(x)) give in
    of_rows ~masked (Array.length give) typs (Top.give ~masked v ~typs (source give order.limit) order)
  | Wire.Over (Wire.Over _, _, _) -> Query.bad "windows over windows: Over takes a Give or a Group"
  | Wire.Over ((Wire.Give give), each, windows) ->
    let give = if Array.length give = 0 then Array.init q.vars Fun.id else give in
    Array.iter var give;
    let cols = Array.length give in
    let typs = Array.map (fun x -> ty.(x)) give in
    Top.check cols typs order;
    Window.check ~cols ~typs:(fun c -> typs.(c)) ~key:(fun _ -> true) ~list:(fun _ -> false) each windows order;
    let ord = Top.full cols order.keys in
    let mk = Top.sorter ~masked v typs ord in
    let ne = Array.length each in
    (* a row's group: its Each columns' words, and with Optionals whether each is missing *)
    let kw = if masked then ne + 1 else ne in
    let key_of (row : int array) (buf : int array) =
      for j = 0 to ne - 1 do buf.(j) <- row.(each.(j)) done;
      if masked then begin
        let m = ref 0 in
        for j = 0 to ne - 1 do if Top.missing cols row each.(j) then m := !m lor (1 lsl j) done;
        buf.(ne) <- !m
      end
    in
    (* the rows the windows read, where a page's start (with After), and the first of them to give *)
    let rows, start, first =
      if ne > 0 && order.limit > 0 then begin
        (* the first k rows of each group: a buffer a group. A binding is compared with its group's k-th row before
           it is made a row (a binding past it is no row of the answer, and costs no allocation); for k of at most
           [small_each], the buffer is kept in the order, each row put at its place (k comparisons at most) and the
           rows past the k-th but its copies dropped at once; for a larger k, cut back to its first k at 2 k rows, as
           Top's heap is (O(n log k) comparisons, O(groups k) rows held) *)
        let k = order.limit in
        let small = k <= !small_each in
        let width = weight * max 1 cols in
        let cells (st : firsts) n = st.gt.cells <- st.gt.cells + n; match ticket with Some tk when st.gt.cells >= grain -> charge tk st.gt.cells; st.gt.cells <- 0 | _ -> () in
        (* the group of the key in st.gt.buf, its buffer made when it is new *)
        let group_of st =
          let n0 = st.gt.n in
          let g = group st.gt in
          if st.gt.n > n0 then begin
            if g >= Array.length st.bufs then begin
              let m = max 16 (2 * Array.length st.bufs) in
              let old = Array.length st.bufs in
              let b = Array.init m (fun i -> if i < old then st.bufs.(i) else Top.fresh ()) in
              let h = Array.make m 0 and kt = Array.make m [||] in
              Array.blit st.held 0 h 0 old;
              Array.blit st.kth 0 kt 0 old;
              st.bufs <- b;
              st.held <- h;
              st.kth <- kt
            end;
            cells st (weight * (kw + 4))
          end;
          g
        in
        (* the k-th row of a group's buffer, past which a row cannot be one of its first k: [||] while it has none *)
        let kth st g = if small then (let b = st.bufs.(g) in if b.n >= k then b.a.(k - 1) else [||]) else Array.unsafe_get st.kth g in
        let insert st g row =
          let b = st.bufs.(g) in
          if b.n = Array.length b.a then (let a = Array.make (max 4 (2 * b.n)) [||] in Array.blit b.a 0 a 0 b.n; b.a <- a);
          if small then begin
            (* at its place: after the rows that come before it or equal it *)
            let i = ref b.n in
            while !i > 0 && st.cmp b.a.(!i - 1) row > 0 do b.a.(!i) <- b.a.(!i - 1); decr i done;
            b.a.(!i) <- row;
            b.n <- b.n + 1;
            if b.n > st.held.(g) then (st.held.(g) <- b.n; cells st width);
            if b.n > k then begin
              let kt = b.a.(k - 1) in
              while b.n > k && st.cmp b.a.(b.n - 1) kt <> 0 do b.n <- b.n - 1; b.a.(b.n) <- [||] done
            end
          end
          else begin
            b.a.(b.n) <- row;
            b.n <- b.n + 1;
            if b.n > st.held.(g) then (st.held.(g) <- b.n; cells st width);
            (* cut back to its first k and their copies at 2 k rows, as Top's heap is *)
            if b.n >= max 2 (2 * k) then (Top.sort_cut mk k b; st.kth.(g) <- b.a.(k - 1))
          end
        in
        (* a row (of another domain's buffers) *)
        let into st row =
          key_of row st.gt.buf;
          let g = group_of st in
          let kt = kth st g in
          if Array.length kt = 0 || st.cmp row kt <= 0 then insert st g row
        in
        (* a binding: its key and its comparison with the k-th row read from it, its row made only when it is one *)
        let key_env = key_into p (Array.map (fun c -> give.(c)) each) in
        let words = Array.map (getter p) give and miss = Array.map (misser p) give in
        let cmp_env (env : int array) (row : int array) =
          let c = ref 0 and i = ref 0 in
          while !c = 0 && !i < Array.length ord do
            let o = ord.(!i) in
            let col = o.Top.col in
            let ma = masked && miss.(col) env and mb = masked && Top.missing cols row col in
            if ma || mb then c := (if ma = mb then 0 else if ma then 1 else -1)
            else (let x = Top.compare_words v typs.(col) (words.(col) env) row.(col) in c := if o.desc then -x else x);
            incr i
          done;
          !c
        in
        let project = projector p give in
        let step st env =
          key_env env st.gt.buf;
          let g = group_of st in
          let kt = kth st g in
          if Array.length kt = 0 || cmp_env env kt <= 0 then insert st g (project env);
          st
        in
        let init () = { gt = table ~kw ~na:0 ~start:[||] ~cols:[||] (); bufs = [||]; held = [||]; kth = [||]; cmp = mk () } in
        let merge a b =
          for gb = 0 to b.gt.n - 1 do
            let buf = b.bufs.(gb) in
            for i = 0 to buf.n - 1 do into a buf.a.(i) done
          done;
          cells a b.gt.cells;
          a
        in
        (* the buffers do not depend on the order of the rows: any domain, any order *)
        let st = fold ~any_order:true ~init ~merge ~step () in
        (match ticket with Some tk when st.gt.cells > 0 -> charge tk st.gt.cells; st.gt.cells <- 0 | _ -> ());
        let firsts = List.init st.gt.n (fun g -> let b = st.bufs.(g) in if not small then Top.sort_cut mk k b; Array.sub b.a 0 b.n) in
        let all = { Top.a = Array.concat firsts; n = 0 } in
        all.n <- Array.length all.a;
        Top.sort_cut ?fast:(if masked then None else Some (typs, ord)) mk 0 all;
        all.a, None, 0
      end
      else
        match order.after with
        | None ->
          (* the first k rows and their copies (or every row): their windows read only rows before them *)
          Top.give ~masked v ~typs (source give order.limit) order, None, 0
        | Some a ->
          (* a page after a cursor: its rows as without windows (the index path's seek kept), and what the rows at or
             before the cursor give its windows, from one fold of them, none sorted: their count, the sums and the
             best value of a frame from the first row, the rows tied with the cursor and the different places (Rank),
             and the last m of them, as many as a frame or a Prev reaches back (a buffer of 2 m at most: Top's heap,
             in the reverse order) *)
          let page = Top.give ~masked v ~typs (source give order.limit) order in
          let project = projector p give in
          let cur = Array.mapi (fun i x -> Top.cell v typs.(i) (string_of_int i) x) a in
          let m =
            Array.fold_left
              (fun m -> function
                | Wire.Running (_, last) when last > 0 -> max m (last - 1)
                | Running _ -> m
                | Rank _ -> max m 1
                | Prev (_, back) -> max m back)
              0 windows
          in
          let rev = fun () -> let c = mk () in fun x y -> c y x in
          let value_of (row : int array) c = if masked && Top.missing cols row c then Value.missing else Store.value v typs.(c) row.(c) in
          let ranks = Array.map (function Wire.Rank (k, _) -> Some (Array.sub ord 0 k) | _ -> None) windows in
          let place (row : int array) (o : Top.key array) = let b = Buffer.create 16 in Array.iter (fun (k : Top.key) -> Value.encode b (value_of row k.col)) o; Buffer.contents b in
          let fresh () =
            { count = 0;
              sums = Array.map (function Wire.Running ((Sum _ | Avg _), 0) -> Some (Agg.value_sums ()) | _ -> None) windows;
              best = Array.make (Array.length windows) Value.missing; ties = Array.make (Array.length windows) 0;
              places = Array.map (function Wire.Rank (_, true) -> Some (Hashtbl.create 64) | _ -> None) windows; tail = Top.fresh ();
              cells = 0 }
          in
          let step st env =
            let row = project env in
            if Top.compare_cursor ~masked v typs ord row cur <= 0 then begin
              st.count <- st.count + 1;
              Array.iteri
                (fun i w ->
                  match w, st.sums.(i) with
                  | Wire.Running ((Sum c | Avg c), 0), Some s -> let x = value_of row c in if not (Value.is_missing x) then Agg.add_value s 1 x
                  | Running (((Min c | Max c) as g), 0), _ ->
                    let x = value_of row c and b = st.best.(i) in
                    if not (Value.is_missing x) && (Value.is_missing b || (match g with Min _ -> -1 | _ -> 1) * Top.compare_values x b > 0) then st.best.(i) <- x
                  | Rank _, _ -> (
                    let o = Option.get ranks.(i) in
                    if Top.compare_cursor ~masked v typs o row cur = 0 then st.ties.(i) <- st.ties.(i) + 1;
                    match st.places.(i) with
                    | Some h ->
                      let k = place row o in
                      if not (Hashtbl.mem h k) then begin
                        Hashtbl.add h k ();
                        (* a place's cells charged as they come, by grains: a dense rank of many places is bounded *)
                        st.cells <- st.cells + (weight * 4);
                        match ticket with Some tk when st.cells >= grain -> charge tk st.cells; st.cells <- 0 | _ -> ()
                      end
                    | None -> ())
                  | _ -> ())
                windows;
              if m > 0 then Top.push rev m st.tail row
            end;
            st
          in
          let merge x y =
            x.count <- x.count + y.count;
            Array.iteri (fun i s -> match s, y.sums.(i) with Some s, Some t -> Agg.merge (Agg.Sums s) (Agg.Sums t) | _ -> ()) x.sums;
            Array.iteri
              (fun i w ->
                match w with
                | Wire.Running (((Min _ | Max _) as g), 0) ->
                  let b = y.best.(i) in
                  if not (Value.is_missing b) && (Value.is_missing x.best.(i) || (match g with Min _ -> -1 | _ -> 1) * Top.compare_values b x.best.(i) > 0) then x.best.(i) <- b
                | _ -> ())
              windows;
            Array.iteri (fun i t -> x.ties.(i) <- x.ties.(i) + t) y.ties;
            Array.iteri (fun i h -> match h, y.places.(i) with Some h, Some g -> Hashtbl.iter (fun k () -> Hashtbl.replace h k ()) g | _ -> ()) x.places;
            ignore (Top.append rev m x.tail y.tail);
            x.cells <- x.cells + y.cells;
            x
          in
          (* the rows before the cursor's first key, when it is a value of an index: a range of it, so that an early
             page reads few rows *)
          let window =
            let k = List.hd order.keys in
            match (source give 0).var k.col, cur.(k.col) with
            | Some x, Top.W w when (not masked) && Value.inline typs.(k.col) && typs.(k.col) <> Tbool ->
              Some (if k.desc then Top.Range (x, Top.word_value typs.(k.col) w, Top.word_value typs.(k.col) max_int)
                    else Top.Range (x, Top.word_value typs.(k.col) min_int, Top.word_value typs.(k.col) w))
            | _ -> None
          in
          Atomic.incr paged;
          if window <> None then Atomic.incr ranged;
          let st = fold ~any_order:true ?window ~init:fresh ~merge ~step () in
          if m > 0 then Top.sort_cut rev m st.tail;
          let tail = Array.sub st.tail.a 0 st.tail.n in
          let t = Array.length tail in
          let tail = Array.init t (fun i -> tail.(t - 1 - i)) in
          (match ticket with Some tk when st.cells > 0 -> charge tk st.cells | _ -> ());
          charge_opt (t * cols);
          let init =
            Array.mapi
              (fun i w ->
                match w with
                | Wire.Running ((Sum _ | Avg _), 0) -> Window.I_sums (Option.get st.sums.(i))
                | Running ((Min _ | Max _), 0) -> I_best st.best.(i)
                | Rank (k, _) when Array.length page > 0 ->
                  let d = match st.places.(i) with Some h -> Hashtbl.length h | None -> 0 in
                  let o = Array.sub ord 0 k in
                  let tied = t > 0 && (if masked then Top.compare_masked else Top.compare_rows) v typs o tail.(t - 1) page.(0) = 0 in
                  if tied then I_rank (st.count - st.ties.(i) + 1, d) else I_rank (st.count + 1, d + 1)
                | _ -> I_none)
              windows
          in
          Array.append tail page, Some { Window.skip = t; offset = st.count - t; init }, t
    in
    let n = Array.length rows in
    let part, groups =
      if ne = 0 then Array.make n 0, min n 1
      else begin
        (* a group a key of words, in a table of open addressing: no allocation a row *)
        let t = table ~kw ~na:0 ~start:[||] ~cols:[||] () in
        let part = Array.init n (fun i -> key_of rows.(i) t.buf; group t) in
        part, t.n
      end
    in
    let nw = Array.length windows in
    charge_opt (n * (2 + nw));
    let get i c = if masked && Top.missing cols rows.(i) c then Value.missing else Store.value v typs.(c) rows.(i).(c) in
    let cmp_k k = let o = Array.sub ord 0 k in if masked then Top.compare_masked v typs o else Top.compare_rows v typs o in
    let ties = Hashtbl.create 2 in
    let tie k = match Hashtbl.find_opt ties k with Some f -> f | None -> let c = cmp_k k in let f i j = c rows.(i) rows.(j) = 0 in Hashtbl.add ties k f; f in
    let out = Window.compute ?start ~view:v ~n ~groups ~part:(fun i -> part.(i)) ~get ~tie:(fun k -> tie k) ~typs:(fun c -> typs.(c)) windows in
    let idx = Array.init (n - first) (fun i -> first + i) in
    Window.check_past ~col:(fun c -> name give.(c)) windows out idx;
    let wt = Array.map (Window.typ (fun c -> typs.(c))) windows in
    { cols = cols + nw; n = Array.length idx; typ = (fun j -> if j < cols then typs.(j) else wt.(j - cols));
      word = (fun i j -> if j < cols then rows.(idx.(i)).(j) else 0);
      missing = (fun i j -> if j < cols then masked && Top.missing cols rows.(idx.(i)) j else Window.missing out.(j - cols) idx.(i));
      computed = (fun j -> j >= cols); cell = (fun i j -> Window.cell out.(j - cols) idx.(i)) }
  | Wire.Over ((Wire.Group (keys, aggs) as base), each, windows) ->
    Array.iter var keys;
    Array.iter (fun a -> Option.iter var (Agg.var_of a)) aggs;
    if Array.exists (function Wire.Values _ -> true | _ -> false) aggs then
      Query.bad "windows and Each are not for a report with Values: a group is then several rows, one a value";
    let nk = Array.length keys in
    let cols = nk + Array.length aggs in
    let typs = Array.init cols (fun j -> if j < nk then ty.(keys.(j)) else let a = aggs.(j - nk) in Agg.typ a (match Agg.var_of a with Some x -> ty.(x) | None -> Value.Tint)) in
    Top.check cols typs order;
    Window.check ~cols ~typs:(fun c -> typs.(c)) ~key:(fun c -> c < nk) ~list:(fun _ -> false) each windows order;
    (* every group, in the order: the windows read them all *)
    let a = answer ~order:{ order with limit = 0; after = None } ~extra ~budget ?stop ?ticket ~weight v q base in
    let rows = Array.init a.n (fun i -> Array.init cols (fun j -> value v a i j)) in
    let n = a.n in
    let ord = Top.full cols order.keys in
    let part, groups =
      if each = [||] then Array.make n 0, min n 1
      else partition n (fun i -> let b = Buffer.create 16 in Array.iter (fun c -> Value.encode b rows.(i).(c)) each; Buffer.contents b)
    in
    let nw = Array.length windows in
    charge_opt (n * (2 + nw));
    let cmp_k k = let o = Array.sub ord 0 k in fun i j -> Top.compare_value_rows o rows.(i) rows.(j) in
    let out =
      Window.compute ~view:v ~n ~groups ~part:(fun i -> part.(i)) ~get:(fun i c -> rows.(i).(c)) ~tie:(fun k -> let c = cmp_k k in fun i j -> c i j = 0)
        ~typs:(fun c -> typs.(c)) windows
    in
    let after =
      match order.after with
      | None -> fun _ -> true
      | Some cur ->
        Array.iteri (fun j x -> if not (Value.is_missing x || Value.has_type typs.(j) x) then Query.bad "After's column %d needs a %s, not %s" j (Value.typ_name typs.(j)) (Value.to_string x)) cur;
        fun i -> Top.compare_value_rows ord rows.(i) cur > 0
    in
    let full = cmp_k (Array.length ord) in
    let idx = keep_rows n ~after ~limit:order.limit ~part ~same:(fun i j -> full i j = 0) in
    Window.check_past ~col:(fun c -> if c < nk then name keys.(c) else agg_text name aggs.(c - nk)) windows out idx;
    let wt = Array.map (Window.typ (fun c -> typs.(c))) windows in
    of_values (cols + nw) (Array.append typs wt) (Array.map (fun i -> Array.init (cols + nw) (fun j -> if j < cols then rows.(i).(j) else Window.cell out.(j - cols) i)) idx)
  | Wire.Give give ->
    let give = if Array.length give = 0 then Array.init q.vars Fun.id else give in
    Array.iter var give;
    let k = Array.length give in
    (* a row's words, and with Optionals the mask of its missing cells after them (Ask.projector's) *)
    let row =
      if not masked && p.derived = [||] then fun acc env -> for i = 0 to k - 1 do push acc env.(give.(i)) done
      else begin
        let project = projector p give in
        let w = if masked then k + 1 else k in
        fun acc env -> let r = project env in for i = 0 to w - 1 do push acc r.(i) done
      end
    in
    let stride = if masked then k + 1 else k in
    let step =
      match ticket with
      | None -> fun acc env -> row acc env; acc
      | Some t ->
        fun acc env ->
          let n0 = acc.n in
          row acc env;
          if n0 / grain <> acc.n / grain then charge t (weight * grain);
          acc
    in
    let acc = fold ~init:(fun () -> { a = [||]; n = 0 }) ~merge:append ~step () in
    { cols = k; n = acc.n / max 1 stride; typ = (fun j -> ty.(give.(j))); word = (fun i j -> acc.a.((i * stride) + j));
      missing = (if masked then fun i j -> (acc.a.((i * stride) + k) lsr j) land 1 = 1 else none_missing); computed = none_computed; cell = no_cell }
  | Wire.Group (keys, aggs) when p.derived <> [||] || Array.exists Agg.is_new aggs -> report ~order ?ticket ~weight ~name v p ~optional keys aggs
  | Wire.Group (keys, aggs) ->
    Array.iter var keys;
    Array.iter
      (function
        | Wire.Count -> ()
        | Wire.Sum x ->
          var x;
          if optional x then Query.bad "Sum, Min and Max take a variable of a pattern, not an Optional's, which may be missing: give its values, or Count the rows";
          (match ty.(x) with Tint | Tmoney _ -> () | t -> Query.bad "a sum of a %s variable" (Value.typ_name t))
        | Wire.Min x | Wire.Max x ->
          var x;
          if optional x then Query.bad "Sum, Min and Max take a variable of a pattern, not an Optional's, which may be missing: give its values, or Count the rows";
          (match ty.(x) with Tint | Tmoney _ | Tdate -> () | t -> Query.bad "a min or max of a %s variable" (Value.typ_name t))
        | _ -> () (* the report's (above) *))
      aggs;
    let nk = Array.length keys and na = Array.length aggs in
    (* a group's key: its words, and with Optionals the mask of its missing ones after them *)
    let kw = if masked then nk + 1 else nk in
    let key = key_into p keys in
    (* a key's cells, charged by grains of keys *)
    let width = weight * max 1 (nk + na) in
    let every = max 1 (grain / width) in
    (* key words -> aggregate words, a table a domain, joined at the end *)
    let tl =
      fold ~any_order:true ~init:(table ~kw ~na ~start:(start_of aggs) ~cols:(Array.make na None)) ~merge:(merge_tables aggs)
        ~step:(fun t env ->
          key env t.buf;
          let n0 = t.n in
          let g = group t in
          (match ticket with Some tk when t.n > n0 && t.n mod every = 0 -> charge tk (every * width) | _ -> ());
          let o = g * na and vals = t.vals in
          for i = 0 to na - 1 do
            match aggs.(i) with
            | Wire.Count -> vals.(o + i) <- vals.(o + i) + 1
            | Wire.Sum x ->
              let s = vals.(o + i) and w = env.(x) in
              let r = s + w in
              vals.(o + i) <- r;
              if Agg.wrapped s w r then carry_add t (o + i) (if w >= 0 then 1 else -1)
            | Wire.Min x -> if env.(x) < vals.(o + i) then vals.(o + i) <- env.(x)
            | Wire.Max x -> if env.(x) > vals.(o + i) then vals.(o + i) <- env.(x)
            | _ -> ()
          done;
          t) ()
    in
    (* in the order of the keys' words: an answer that does not depend on the number of domains *)
    let groups = sorted tl in
    check_sums ~name ~key:(key_value v ty keys ~masked tl) nk aggs tl groups;
    let typ j =
      if j < nk then ty.(keys.(j))
      else match aggs.(j - nk) with Wire.Sum y | Wire.Min y | Wire.Max y -> ty.(y) | _ -> Value.Tint
    in
    let keys = tl.keys and vals = tl.vals in
    if order = Top.none then begin
      let word i j = let g = groups.(i) in if j < nk then keys.((g * kw) + j) else vals.((g * na) + j - nk) in
      let missing = if masked then fun i j -> j < nk && (keys.((groups.(i) * kw) + nk) lsr j) land 1 = 1 else none_missing in
      { cols = nk + na; n = Array.length groups; typ; word; missing; computed = none_computed; cell = no_cell }
    end
    else begin
      (* the rows of the sort, a copy of the groups (and the mask of their keys after them) *)
      Option.iter (fun t -> charge t (Array.length groups * width)) ticket;
      let typs = Array.init (nk + na) typ in
      let rows =
        Array.map
          (fun g ->
            let r = Array.make (if masked then nk + na + 1 else nk + na) 0 in
            Array.blit keys (g * kw) r 0 nk;
            Array.blit vals (g * na) r nk na;
            if masked then r.(nk + na) <- keys.((g * kw) + nk);
            r)
          groups
      in
      of_rows ~masked (nk + na) typs (Top.sort_rows ~masked v ~typs order rows)
    end
