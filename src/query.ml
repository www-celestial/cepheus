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

(* The order of the variables. [est x bound]: the candidates per binding that the best pattern offers x given the
   variables already bound. The cost of an order is the sum of the estimated partial bindings after each step (each
   step multiplies by its candidates); every order is tried for up to 7 variables (with pruning), greedily beyond. *)
let order (v : Store.view) nvars pats =
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
            else Store.distinct v pt.pp
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

let exists_thing (v : Store.view) p w =
  let r = ref false in
  (try Store.iter_things v p w (fun _ -> r := true; raise Exit) with Exit -> ());
  !r

let run (v : Store.view) q (k : int array -> unit) =
  match compile v q with
  | exception No_answer -> ()
  | _ty, pats, ranges ->
    let env = Array.make q.vars 0 and bound = Array.make q.vars false in
    let get = function W w -> Some w | V y -> if bound.(y) then Some env.(y) else None in
    (* patterns without variables: checked once *)
    let ground, pats = List.partition (fun pt -> (match pt.pe with W _ -> true | _ -> false) && match pt.pv with W _ -> true | _ -> false) pats in
    let ok_ground = List.for_all (fun pt -> match pt.pe, pt.pv with W e, W w -> Store.mem v e pt.pp w | _ -> true) ground in
    if ok_ground then begin
      let ord = order v q.vars pats in
      let by_var = Array.init q.vars (fun x -> List.filter (fun pt -> has x pt.pe || has x pt.pv) pats) in
      let rng = Array.make q.vars [] in
      List.iter (fun (x, lo, hi) -> rng.(x) <- (lo, hi) :: rng.(x)) ranges;
      (* does pattern pt accept x = c, given the bindings so far? *)
      let accepts x c pt =
        if has x pt.pe && has x pt.pv then Store.mem v c pt.pp c
        else if has x pt.pe then
          match get pt.pv with Some w -> Store.mem v c pt.pp w | None -> Store.has_value v c pt.pp
        else
          match get pt.pe with Some e -> Store.mem v e pt.pp c | None -> exists_thing v pt.pp c
      in
      (* the candidates pt offers for x: a count and an iterator *)
      let source x pt =
        if has x pt.pe && has x pt.pv then
          Store.count_prop v pt.pp, fun f -> Store.iter_prop v pt.pp (fun e w -> if e = w then f e)
        else if has x pt.pe then
          match get pt.pv with
          | Some w -> Store.count_things v pt.pp w, fun f -> Store.iter_things v pt.pp w f
          | None ->
            ( Store.count_prop v pt.pp,
              fun f ->
                if pt.many then begin
                  let seen = Hashtbl.create 256 in
                  Store.iter_prop v pt.pp (fun e _ -> if not (Hashtbl.mem seen e) then (Hashtbl.replace seen e (); f e))
                end
                else Store.iter_prop v pt.pp (fun e _ -> f e) )
        else
          match get pt.pe with
          | Some e -> Store.count_values v e pt.pp, fun f -> Store.iter_values v e pt.pp f
          | None ->
            ( Store.count_prop v pt.pp,
              fun f ->
                let seen = Hashtbl.create 256 in
                Store.iter_prop v pt.pp (fun _ w -> if not (Hashtbl.mem seen w) then (Hashtbl.replace seen w (); f w)) )
      in
      let in_ranges x c = List.for_all (fun (lo, hi) -> c >= lo && c <= hi) rng.(x) in
      let rec level i =
        if i = q.vars then k env
        else begin
          let x = ord.(i) in
          let ps = by_var.(x) in
          let best = ref None in
          List.iter
            (fun pt ->
              let c, it = source x pt in
              match !best with Some (c', _, _) when c' <= c -> () | _ -> best := Some (c, it, pt))
            ps;
          match !best with
          | None -> ()
          | Some (_, it, src) ->
            let others = List.filter (fun pt -> pt != src) ps in
            bound.(x) <- true;
            it (fun c ->
                if in_ranges x c && List.for_all (accepts x c) others then begin
                  env.(x) <- c;
                  level (i + 1)
                end);
            bound.(x) <- false
        end
      in
      level 0
    end

let rows (v : Store.view) q =
  match compile v q with
  | exception No_answer -> []
  | ty, _, _ ->
    let out = ref [] in
    run v q (fun env -> out := Array.mapi (fun i w -> Store.value v ty.(i) w) env :: !out);
    List.rev !out

let count (v : Store.view) q =
  let n = ref 0 in
  run v q (fun _ -> incr n);
  !n

let var_types = types
