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
   over [domains] domains, each with its own accumulator: a view needs no lock to be read. *)
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
    (* one runner per domain: its own bindings and its own count of candidates *)
    let runner () =
      let env = Array.make n 0 and bound = Array.make n false and w = ref 0 in
      let get = function W w -> Some w | V y -> if bound.(y) then Some env.(y) else None in
      let accepts x c pt =
        if has x pt.pe && has x pt.pv then Store.mem v c pt.pp c
        else if has x pt.pe then
          match get pt.pv with Some w -> Store.mem v c pt.pp w | None -> Store.has_value v c pt.pp
        else match get pt.pe with Some e -> Store.mem v e pt.pp c | None -> Store.count_things v pt.pp c > 0
      in
      let distinct it f =
        let seen = Hashtbl.create 256 in
        it (fun c -> if not (Hashtbl.mem seen c) then (Hashtbl.replace seen c (); f c))
      in
      (* the candidates a pattern offers x, and how many *)
      let source x pt =
        if has x pt.pe && has x pt.pv then Store.count_prop v pt.pp, fun f -> Store.iter_prop v pt.pp (fun e w -> if e = w then f e)
        else if has x pt.pe then
          match get pt.pv with
          | Some w -> Store.count_things v pt.pp w, fun f -> Store.iter_things v pt.pp w f
          | None ->
            ( Store.count_prop v pt.pp,
              if pt.many then distinct (fun f -> Store.iter_prop v pt.pp (fun e _ -> f e))
              else fun f -> Store.iter_prop v pt.pp (fun e _ -> f e) )
        else
          match get pt.pe, iv.(x) with
          | Some e, _ -> Store.count_values v e pt.pp, fun f -> Store.iter_values v e pt.pp f
          | None, Some (lo, hi) ->
            (* a variable with a range, read off the property's index in value order: only the range *)
            Store.count_range v pt.pp lo hi, distinct (fun f -> Store.iter_range v pt.pp lo hi (fun _ w -> f w))
          | None, None -> Store.count_prop v pt.pp, distinct (fun f -> Store.iter_prop v pt.pp (fun _ w -> f w))
      in
      let candidates i (f : int -> unit) =
        let x = ord.(i) and ps = by_var.(ord.(i)) in
        let best = ref None in
        List.iter
          (fun pt -> let c, it = source x pt in match !best with Some (c', _, _) when c' <= c -> () | _ -> best := Some (c, it, pt))
          ps;
        match !best with
        | None -> ()
        | Some (_, it, src) ->
          let others = List.filter (fun pt -> pt != src) ps in
          it (fun c -> incr w; if in_range x c && List.for_all (accepts x c) others then f c)
      in
      let rec level i acc =
        if i = n then acc := step !acc env
        else begin
          let x = ord.(i) in
          bound.(x) <- true;
          candidates i (fun c -> env.(x) <- c; level (i + 1) acc);
          bound.(x) <- false
        end
      in
      env, bound, candidates, level, w
    in
    if n = 0 then step (init ()) [||]
    else begin
      let env, bound, candidates, level, w0 = runner () in
      let first = ref [] and count = ref 0 in
      candidates 0 (fun c -> first := c :: !first; incr count);
      let firsts = Array.of_list (List.rev !first) in
      let x0 = ord.(0) in
      let run_slice (env, bound, level, w) lo hi =
        let acc = ref (init ()) in
        bound.(x0) <- true;
        for k = lo to hi - 1 do
          env.(x0) <- firsts.(k);
          level 1 acc
        done;
        ignore (Atomic.fetch_and_add work !w);
        w := 0;
        !acc
      in
      let d = if !count >= !parallel_min then !domains else 1 in
      if d <= 1 then run_slice (env, bound, level, w0) 0 !count
      else begin
        let chunk = (!count + d - 1) / d in
        let others =
          List.init (d - 1) (fun k ->
              let lo = (k + 1) * chunk and hi = min !count ((k + 2) * chunk) in
              Domain.spawn (fun () -> let e, b, _, l, w = runner () in run_slice (e, b, l, w) lo (max lo hi)))
        in
        let mine = run_slice (env, bound, level, w0) 0 (min chunk !count) in
        List.fold_left (fun acc dm -> merge acc (Domain.join dm)) mine others
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
