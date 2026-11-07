(* Questions: patterns [thing, property, value] whose thing and value are constants or variables, answered by Generic
   Join (Ngo, Re, Rudra 2013): one variable at a time, in an order chosen from the index counts; for each variable,
   the pattern that offers the fewest candidates (exact counts, read from the indexes for the bindings so far) gives
   them, and every other pattern on that variable keeps or drops each one with an index lookup. The work stays within
   the AGM bound of the question (Atserias, Grohe, Marx 2008) up to the cost of a lookup; on a chain of patterns it
   is the plain nested index lookup. Each binding comes out once (G11; proof in docs/theory.md). *)

type term = Var of int | Thing of int | Val of Value.t

type pattern = { e : term; p : int; v : term }

type t = { vars : int; where : pattern list; ranges : (int * Value.t * Value.t) list }
(** [ranges]: [(x, lo, hi)] keeps the bindings with lo <= x <= hi (an int, a date or money). *)

exception No_answer
exception Bad of string

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

let compile (v : Store.view) q =
  let ty = types v q in
  let side = function
    | Var x -> V x
    | Thing e -> W e
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

(* The order of the variables. [est x bound]: the candidates per binding that the best pattern offers x given the
   variables already bound. The cost of an order is the sum of the estimated partial bindings after each step (each
   step multiplies by its candidates); every order is tried for up to 7 variables (with pruning), greedily beyond. *)
let order (v : Store.view) nvars pats ranges =
  let iv = intervals nvars ranges in
  let est x bound =
    let known = function W _ -> true | V y -> bound land (1 lsl y) <> 0 in
    List.fold_left
      (fun best pt ->
        let c =
          if has x pt.pe && has x pt.pv then Store.count_prop v pt.pp
          else if has x pt.pe then
            match pt.pv with
            | W w -> Store.count_things v pt.pp w
            | V y when known (V y) -> max 1 (Store.count_prop v pt.pp / Store.distinct v pt.pp)
            | V _ -> Store.count_prop v pt.pp
          else if has x pt.pv then
            if known pt.pe then (match pt.pe with W e -> Store.count_values v e pt.pp | V _ -> if pt.many then 4 else 1)
            else
              match iv.(x) with
              | None -> Store.distinct v pt.pp
              | Some (lo, hi) ->
                let all = max 1 (Store.count_prop v pt.pp) in
                max 1 (Store.count_range v pt.pp lo hi * Store.distinct v pt.pp / all)
          else max_int
        in
        min best c)
      max_int pats
  in
  let best = ref [||] and best_cost = ref infinity in
  if nvars <= 7 then begin
    let cur = Array.make nvars 0 in
    let rec go k bound size cost =
      if cost < !best_cost then
        if k = nvars then (best_cost := cost; best := Array.copy cur)
        else
          for x = 0 to nvars - 1 do
            if bound land (1 lsl x) = 0 then begin
              let size = size *. float_of_int (max 1 (est x bound)) in
              cur.(k) <- x;
              go (k + 1) (bound lor (1 lsl x)) size (cost +. size)
            end
          done
    in
    go 0 0 1. 0.
  end;
  if !best = [||] then begin
    let out = Array.make nvars 0 and bound = ref 0 in
    for k = 0 to nvars - 1 do
      let b = ref (-1) and bc = ref max_int in
      for x = 0 to nvars - 1 do
        if !bound land (1 lsl x) = 0 then begin
          let c = est x !bound in
          if !b < 0 || c < !bc then (b := x; bc := c)
        end
      done;
      out.(k) <- !b;
      bound := !bound lor (1 lsl !b)
    done;
    best := out
  end;
  !best

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
type plan = { pats : pat list; limits : (int * int * int) list; ord : int array }

let plan (v : Store.view) q =
  match compile v q with
  | exception No_answer -> None
  | _ty, pats, limits ->
    let ground, pats =
      List.partition (fun pt -> (match pt.pe with W _ -> true | _ -> false) && match pt.pv with W _ -> true | _ -> false) pats
    in
    if not (List.for_all (fun pt -> match pt.pe, pt.pv with W e, W w -> Store.mem v e pt.pp w | _ -> true) ground) then None
    else Some { pats; limits; ord = order v q.vars pats limits }

(* Generic Join: at each level, the pattern with the fewest candidates (exact counts) gives them, and every other
   pattern on the variable keeps or drops each one with a lookup; nothing is enumerated beyond the smallest set. *)
let fold (v : Store.view) q ~init ~step ~merge =
  match plan v q with
  | None -> init ()
  | Some { pats; limits; ord } ->
    let n = q.vars in
    let by_var = Array.init n (fun x -> List.filter (fun pt -> has x pt.pe || has x pt.pv) pats) in
    let iv = intervals n limits in
    let in_range x c = match iv.(x) with None -> true | Some (lo, hi) -> c >= lo && c <= hi in
    let by_var = Array.map Array.of_list by_var in
    (* one runner per domain: its own bindings and its own count of candidates; no allocation per binding but the
       iterators' own *)
    let runner () =
      let env = Array.make n 0 and bound = Array.make n false and w = ref 0 in
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
      (* how many candidates a pattern offers x, exactly *)
      let count x pt =
        if has x pt.pe && has x pt.pv then Store.count_prop v pt.pp
        else if has x pt.pe then match get pt.pv with Some w -> Store.count_things v pt.pp w | None -> Store.count_prop v pt.pp
        else
          match get pt.pe, iv.(x) with
          | Some e, _ -> Store.count_values v e pt.pp
          | None, Some (lo, hi) -> Store.count_range v pt.pp lo hi
          | None, None -> Store.count_prop v pt.pp
      in
      let distinct it f =
        let seen = Hashtbl.create 256 in
        it (fun c -> if not (Hashtbl.mem seen c) then (Hashtbl.replace seen c (); f c))
      in
      (* the candidates themselves *)
      let iterate x pt f =
        if has x pt.pe && has x pt.pv then Store.iter_prop v pt.pp (fun e w -> if e = w then f e)
        else if has x pt.pe then
          match get pt.pv with
          | Some w -> Store.iter_things v pt.pp w f
          | None ->
            if pt.many then distinct (fun f -> Store.iter_prop v pt.pp (fun e _ -> f e)) f
            else Store.iter_prop v pt.pp (fun e _ -> f e)
        else
          match get pt.pe, iv.(x) with
          | Some e, _ -> Store.iter_values v e pt.pp f
          | None, Some (lo, hi) ->
            (* a variable with a range, read off the property's index in value order: only the range *)
            distinct (fun f -> Store.iter_range v pt.pp lo hi (fun _ w -> f w)) f
          | None, None -> distinct (fun f -> Store.iter_prop v pt.pp (fun _ w -> f w)) f
      in
      (* level i: the smallest source, and its size *)
      let choose i =
        let ps = by_var.(ord.(i)) in
        let best = ref (-1) and bc = ref max_int in
        for j = 0 to Array.length ps - 1 do
          let c = count ord.(i) ps.(j) in
          if c < !bc then (bc := c; best := j)
        done;
        !best, !bc
      in
      (* a candidate of level i from source src: in its range, and a fact of every other pattern of the level *)
      let admits i src c =
        let x = ord.(i) and ps = by_var.(ord.(i)) in
        in_range x c
        &&
        let ok = ref true and j = ref 0 in
        while !ok && !j < Array.length ps do
          if !j <> src && not (accepts x c ps.(!j)) then ok := false;
          incr j
        done;
        !ok
      in
      (* the same test as [admits], written out: a call per candidate costs 4 to 7 % of Q4 (no flambda) *)
      let candidates i src (f : int -> unit) =
        let x = ord.(i) and ps = by_var.(ord.(i)) in
        if src >= 0 then
          iterate x ps.(src) (fun c ->
              incr w;
              if in_range x c then begin
                let ok = ref true and j = ref 0 in
                while !ok && !j < Array.length ps do
                  if !j <> src && not (accepts x c ps.(!j)) then ok := false;
                  incr j
                done;
                if !ok then f c
              end)
      in
      let rec level i acc =
        if i = n then acc := step !acc env
        else begin
          let x = ord.(i) in
          let src, _ = choose i in
          bound.(x) <- true;
          candidates i src (fun c -> env.(x) <- c; level (i + 1) acc);
          bound.(x) <- false
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
      let d = if size >= !parallel_min then !domains else 1 in
      if d <= 1 then begin
        let acc = ref (init ()) in
        level 0 acc;
        flush w0;
        !acc
      end
      else begin
        (* the first level's source, as it comes (exactly [size] candidates); each slice checks its own against the
           level's other patterns, so that no domain does the first level alone *)
        let firsts = Array.make size 0 and count = ref 0 in
        bound.(x0) <- true;
        iterate x0 by_var.(x0).(src) (fun c -> firsts.(!count) <- c; incr count; incr w0);
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
