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
  fold : 'a. ?seq:bool -> ?window:Top.window -> init:(unit -> 'a) -> step:('a -> int array -> 'a) -> merge:('a -> 'a -> 'a) -> unit -> 'a;
}

let prepare ~extra ~budget ?stop (v : Store.view) (q : Query.t) =
  let truncs, extra = Ask.truncs extra in
  let ask = if extra = [] then None else Some (Ask.compile v q extra) in
  let ty = match ask with None -> Query.types v q | Some a -> Ask.typs_of a in
  let derived = Ask.derived ~vars:q.vars ~outer:(fun x -> match ask with Some a -> a.outer.(x) | None -> true) ty truncs in
  let ty = if derived = [||] then ty else Array.append ty (Array.make (Array.length derived) Value.Tdate) in
  let var x =
    if x < 0 || x >= q.vars + Array.length derived then Query.bad "variable %d out of range" x;
    match ask with
    | Some a when x < q.vars && not a.outer.(x) -> Query.bad "variable %d is a Not's or an Or's own: Give and Sort take the question's variables" x
    | _ -> ()
  in
  let fold ?seq ?window ~init ~step ~merge () =
    match ask, window with
    | None, None -> Query.fold ?seq ~budget ?stop v q ~init ~step ~merge
    | None, Some (Top.Range (x, lo, hi)) -> Query.fold ?seq ~budget ?stop v { q with ranges = (x, lo, hi) :: q.ranges } ~init ~step ~merge
    | None, Some (Top.Words (x, ws)) -> Query.fold ?seq ~sets:[ (x, ws) ] ~budget ?stop v q ~init ~step ~merge
    | Some a, None -> Ask.fold ?seq ~budget ?stop v a ~init ~step ~merge
    | Some a, Some (Top.Range (x, lo, hi)) -> Ask.fold ?seq ~budget ?stop ~range:(x, lo, hi) v a ~init ~step ~merge
    | Some a, Some (Top.Words (x, ws)) -> Ask.fold ?seq ~budget ?stop ~words:(x, ws) v a ~init ~step ~merge
  in
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

(* ---- a report: Group with Truncs or aggregates of protocol 9 ----
   Each group holds its key's words, the words of its Count, Sum, Min and Max (as the plain path does), and the state
   of each other aggregate (Agg: exact sums, a bag); a table a domain, joined at the end. Its rows are then values:
   the groups in the order of their keys' words (as the plain path), or sorted and cut by Sort, Limit and After as
   groups (a Values column takes no part in the order: no two groups have one key), and each group then a row a value
   of its Values (Agg.flatten). The cells of the keys, of the bags' new values and of the rows are charged to the
   ticket. *)
type group = { w : int array; st : Agg.state option array }

let agg_word (ty : Value.typ array) (a : Wire.agg) w : Value.t =
  match Agg.var_of a with
  | None -> Int w
  | Some x -> (match ty.(x) with Tmoney _ -> Money w | Tdate -> Date w | _ -> Int w)

(* a per-domain table and the cells it has not charged yet *)
type tally = { tbl : (int array, group) Hashtbl.t; mutable cells : int }

let report ~(order : Top.order) ?ticket ~weight (v : Store.view) (p : prepared) ~optional keys aggs =
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
  let key = if p.masked || p.derived <> [||] then projector p keys else fun env -> Array.init nk (fun i -> env.(keys.(i))) in
  let gets = Array.map (fun a -> match Agg.var_of a with Some x -> getter p x | None -> fun _ -> 0) aggs in
  let misses = Array.map (fun a -> match Agg.var_of a with Some x -> misser p x | None -> fun _ -> false) aggs in
  let txs = Array.map (fun a -> match Agg.var_of a with Some x -> ty.(x) | None -> Value.Tint) aggs in
  let width = weight * max 1 (nk + na) in
  let charge_cells (t : tally) n =
    match ticket with
    | None -> ()
    | Some tk -> t.cells <- t.cells + n; if t.cells >= grain then (charge tk t.cells; t.cells <- 0)
  in
  let fresh () =
    { w = Array.map (function Wire.Min _ -> max_int | Wire.Max _ -> min_int | _ -> 0) aggs;
      st = Array.map (fun a -> if Agg.is_new a then Some (Agg.fresh a) else None) aggs }
  in
  let add (t : tally) (g : group) env =
    for i = 0 to na - 1 do
      match aggs.(i) with
      | Wire.Count -> g.w.(i) <- g.w.(i) + 1
      | Sum _ -> g.w.(i) <- g.w.(i) + gets.(i) env
      | Min _ -> let x = gets.(i) env in if x < g.w.(i) then g.w.(i) <- x
      | Max _ -> let x = gets.(i) env in if x > g.w.(i) then g.w.(i) <- x
      | _ -> (
        match g.st.(i) with
        | Some st when not (misses.(i) env) -> if Agg.add v txs.(i) st 1 (gets.(i) env) then charge_cells t (weight * Agg.entry_cells)
        | _ -> ())
    done
  in
  let join (a : group) (b : group) =
    for i = 0 to na - 1 do
      match aggs.(i), a.st.(i), b.st.(i) with
      | (Wire.Count | Sum _), _, _ -> a.w.(i) <- a.w.(i) + b.w.(i)
      | Min _, _, _ -> a.w.(i) <- min a.w.(i) b.w.(i)
      | Max _, _, _ -> a.w.(i) <- max a.w.(i) b.w.(i)
      | _, Some x, Some y -> Agg.merge x y
      | _ -> ()
    done
  in
  let tl =
    p.fold ~init:(fun () -> { tbl = Hashtbl.create 64; cells = 0 })
      ~merge:(fun a b ->
        Hashtbl.iter (fun k g -> match Hashtbl.find_opt a.tbl k with Some g' -> join g' g | None -> Hashtbl.replace a.tbl k g) b.tbl;
        a)
      ~step:(fun t env ->
        let k = key env in
        (match Hashtbl.find_opt t.tbl k with
         | Some g -> add t g env
         | None -> let g = fresh () in add t g env; Hashtbl.replace t.tbl k g; charge_cells t width);
        t) ()
  in
  let groups = Array.of_seq (Hashtbl.to_seq tl.tbl) in
  Array.sort (fun (a, _) (b, _) -> compare a b) groups;
  let typs = Array.init (nk + na) (fun j -> if j < nk then ty.(keys.(j)) else Agg.typ aggs.(j - nk) txs.(j - nk)) in
  let cells (k, g) =
    Array.init (nk + na) (fun j ->
        if j < nk then Agg.One (if p.masked && (k.(nk) lsr j) land 1 = 1 then Value.missing else Store.value v ty.(keys.(j)) k.(j))
        else begin
          let i = j - nk in
          match aggs.(i), g.st.(i) with
          | Wire.Values _, Some st -> Agg.Many (Array.map (Store.value v txs.(i)) (Agg.sorted_values v txs.(i) st))
          | a, Some st -> Agg.One (Agg.result v a txs.(i) st)
          | a, None -> Agg.One (agg_word ty a g.w.(i))
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

let answer ?(order = Top.none) ?(extra = []) ?(budget = max_int) ?stop ?ticket ?(weight = 1) (v : Store.view) (q : Query.t) (sel : Wire.select) =
  let ({ ask; ty; masked; var; fold; _ } as p) = prepare ~extra ~budget ?stop v q in
  (* an Optional's variable may be missing: no Sum, Min or Max of it (nor of a Trunc of it) *)
  let optional x =
    let x = if x < q.vars then x else fst p.derived.(x - q.vars) in
    match ask with Some a -> Array.exists (fun (o : Ask.opt) -> o.ov = x) a.opts | None -> false
  in
  match sel with
  | Wire.Give give when order <> Top.none ->
    let give = if Array.length give = 0 then Array.init q.vars Fun.id else give in
    Array.iter var give;
    let typs = Array.map (fun x -> ty.(x)) give in
    let bound = if order.limit > 0 then max 64 (2 * order.limit) else max_int in
    let base = match ticket with Some t -> Atomic.get t.used | None -> 0 in
    let src =
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
    of_rows ~masked (Array.length give) typs (Top.give ~masked v ~typs src order)
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
  | Wire.Group (keys, aggs) when p.derived <> [||] || Array.exists Agg.is_new aggs -> report ~order ?ticket ~weight v p ~optional keys aggs
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
    let key = if masked then projector p keys else fun env -> Array.init nk (fun i -> env.(keys.(i))) in
    (* a key's cells, charged by grains of keys *)
    let width = weight * max 1 (nk + na) in
    let every = max 1 (grain / width) in
    let added = match ticket with None -> ignore | Some t -> fun n -> if n mod every = 0 then charge t (every * width) in
    (* key words -> aggregate words, a table a domain, joined at the end *)
    let fresh () = Array.init na (fun i -> match aggs.(i) with Wire.Min _ -> max_int | Wire.Max _ -> min_int | _ -> 0) in
    let add (st : int array) env =
      for i = 0 to na - 1 do
        match aggs.(i) with
        | Wire.Count -> st.(i) <- st.(i) + 1
        | Wire.Sum x -> st.(i) <- st.(i) + env.(x)
        | Wire.Min x -> if env.(x) < st.(i) then st.(i) <- env.(x)
        | Wire.Max x -> if env.(x) > st.(i) then st.(i) <- env.(x)
        | _ -> ()
      done
    in
    let join (a : int array) (b : int array) =
      for i = 0 to na - 1 do
        match aggs.(i) with
        | Wire.Count | Wire.Sum _ -> a.(i) <- a.(i) + b.(i)
        | Wire.Min _ -> a.(i) <- min a.(i) b.(i)
        | Wire.Max _ -> a.(i) <- max a.(i) b.(i)
        | _ -> ()
      done
    in
    let tbl =
      fold ~init:(fun () -> Hashtbl.create 64)
        ~merge:(fun a b ->
          Hashtbl.iter (fun k s -> match Hashtbl.find_opt a k with Some s' -> join s' s | None -> Hashtbl.replace a k s) b;
          a)
        ~step:(fun t env ->
          let k = key env in
          (match Hashtbl.find_opt t k with
           | Some s -> add s env
           | None -> let s = fresh () in add s env; Hashtbl.replace t k s; added (Hashtbl.length t));
          t) ()
    in
    let groups = Array.of_seq (Hashtbl.to_seq tbl) in
    (* in the order of the keys' words: an answer that does not depend on the number of domains *)
    Array.sort compare groups;
    let typ j =
      if j < nk then ty.(keys.(j))
      else match aggs.(j - nk) with Wire.Sum y | Wire.Min y | Wire.Max y -> ty.(y) | _ -> Value.Tint
    in
    if order = Top.none then begin
      let word i j = let k, s = groups.(i) in if j < nk then k.(j) else s.(j - nk) in
      let missing = if masked then fun i j -> j < nk && (fst groups.(i)).(nk) lsr j land 1 = 1 else none_missing in
      { cols = nk + na; n = Array.length groups; typ; word; missing; computed = none_computed; cell = no_cell }
    end
    else begin
      (* the rows of the sort, a copy of the groups (and the mask of their keys after them) *)
      Option.iter (fun t -> charge t (Array.length groups * width)) ticket;
      let typs = Array.init (nk + na) typ in
      let rows = Array.map (fun (k, s) -> if masked then Array.concat [ Array.sub k 0 nk; s; [| k.(nk) |] ] else Array.append k s) groups in
      of_rows ~masked (nk + na) typs (Top.sort_rows ~masked v ~typs order rows)
    end
