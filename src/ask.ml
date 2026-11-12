(* Questions with Not, Or (of And) and In, beside a question's patterns and ranges, answered by Generic Join
   (Query.fold). Exact meaning: docs/book/cesia.md, "Not, Or and In".

   - Variables. A variable is bound by a pattern of the question (outside Not and Or), or by an Or when it is in a
     pattern of every one of its alternatives; those are the question's. A variable that is in one Not and nowhere
     else is that Not's own ("there is no value of it"); one that is in some alternatives of one Or and nowhere else
     is its own in each ("there is a value of it"). Bindings are of the question's variables, each once (G11).
   - Or is a disjoint union: the question is asked once for each choice of an alternative in each Or, the
     alternative's items added to it, and the alternatives before it in that Or as Nots, so that a binding that holds
     for several alternatives comes from the first one only; no table of answers is kept for that. An alternative with
     variables of its own may give a binding once for each value of them: those questions keep the bindings they gave
     (on one domain).
   - Not is an anti-join: a binding is kept when the Not's items, its outer variables fixed, have no answer. One
     pattern and no variable of its own: is the fact there (a lookup); one pattern whose other side is its own: does
     the thing have a value of it, or does the value have a thing (a count); otherwise the Not's own question, asked
     until its first answer.
   - In x [values]: x is one of the values, a set of index words that the join takes as a source of x's candidates
     when it is the smallest, else as a check of each (Query.fold ~sets). *)

type item =
  | Pattern of Query.pattern
  | Range of int * Value.t * Value.t
  | In of int * Value.t list
  | Not of item list  (** patterns and conditions *)
  | Or of item list list  (** alternatives, each its patterns and conditions (And) *)

let bad = Query.bad

let vars_of_item = function
  | Pattern pt -> (match pt.e with Var x -> [ x ] | _ -> []) @ (match pt.v with Var x -> [ x ] | _ -> [])
  | Range (x, _, _) | In (x, _) -> [ x ]
  | Not _ | Or _ -> []

let flat_vars items = List.sort_uniq compare (List.concat_map vars_of_item items)

let pattern_vars items = List.sort_uniq compare (List.concat_map (function Pattern _ as i -> vars_of_item i | _ -> []) items)

let simple = function Pattern _ | Range _ | In _ -> true | Not _ | Or _ -> false

(* ---- what the question is: its variables, its types, and its conjunctions ---- *)

type not_ = { items : item list; own : int list }

(* one question of the disjoint union *)
type conj = {
  pats : Query.pattern list;
  ranges : (int * Value.t * Value.t) list;
  ins : (int * Value.t list) list;
  nots : not_ list;
  free : int list;  (* the variables of its alternatives' own: its bindings are kept, to give each binding once *)
}

type t = {
  vars : int;
  outer : bool array;  (* the question's variables *)
  typs : Value.typ option array;
  conjs : conj list;
}

let typ_of (v : Store.view) p = match Schema.find v.schema p with Some d -> d | None -> bad "no property %d" p

(* the type of every variable, from every pattern where it is *)
let types (v : Store.view) nvars items =
  let ty = Array.make nvars None in
  let set x t =
    if x < 0 || x >= nvars then bad "variable %d out of range" x;
    match ty.(x) with
    | None -> ty.(x) <- Some t
    | Some t' -> if t' <> t then bad "variable %d is both a %s and a %s" x (Value.typ_name t') (Value.typ_name t)
  in
  let rec go = function
    | Pattern (pt : Query.pattern) ->
      let d = typ_of v pt.p in
      (match pt.e with Var x -> set x Value.Tlink | _ -> ());
      (match pt.v with Var x -> set x d.typ | Val x when not (Value.has_type d.typ x) -> bad "%s is not a %s" (Value.to_string x) (Value.typ_name d.typ) | _ -> ())
    | Range (x, _, _) | In (x, _) -> if x < 0 || x >= nvars then bad "variable %d out of range" x
    | Not l -> List.iter go l
    | Or alts -> List.iter (List.iter go) alts
  in
  List.iter go items;
  (* a range is for an int, a date or money (and links and bools, inside the engine) *)
  let rec ranges = function
    | Range (x, _, _) -> (match ty.(x) with Some t when Value.inline t -> () | _ -> bad "a range needs an int, date or money variable")
    | Not l -> List.iter ranges l
    | Or alts -> List.iter (List.iter ranges) alts
    | Pattern _ | In _ -> ()
  in
  List.iter ranges items;
  ty

let compile (v : Store.view) (q : Query.t) (extra : item list) : t =
  let n = q.vars in
  let top = List.map (fun pt -> Pattern pt) q.where @ List.map (fun (x, lo, hi) -> Range (x, lo, hi)) q.ranges @ extra in
  let typs = types v n top in
  List.iter
    (function
      | Not l ->
        if l = [] || List.length l > 4 then bad "Not takes 1 to 4 patterns or conditions, not %d" (List.length l);
        if not (List.for_all simple l) then bad "Not takes patterns and conditions: no Not or Or inside it"
      | Or alts ->
        if List.length alts < 2 || List.length alts > 4 then bad "Or takes 2 to 4 alternatives, not %d" (List.length alts);
        List.iter
          (fun a ->
            if a = [] || List.length a > 4 then bad "And takes 1 to 4 patterns or conditions, not %d" (List.length a);
            if not (List.for_all simple a) then bad "an alternative of Or takes patterns and conditions: no Not or Or inside it")
          alts;
        (* an Or of single patterns that differ only in their constant value is In's case *)
        (match alts with
         | [ Pattern p0 ] :: rest
           when List.for_all (function [ Pattern p ] -> p.e = p0.e && p.p = p0.p && (match p.v, p0.v with Query.Val _, Query.Val _ -> true | _ -> false) | _ -> false) rest ->
           bad "an Or of one pattern that differs only in its value is In's case: write In(x, [...]) on the pattern's variable"
         | _ -> ())
      | _ -> ())
    extra;
  (* the question's variables: its patterns', and those an Or binds in every alternative *)
  let outer = Array.make n false in
  List.iter (fun x -> outer.(x) <- true) (pattern_vars top);
  List.iter
    (function
      | Or alts ->
        let each = List.map pattern_vars alts in
        List.iter (fun x -> if List.for_all (List.mem x) each then outer.(x) <- true) (List.concat each)
      | _ -> ())
    extra;
  (* every other variable is the own of one Not, or of one Or's alternatives *)
  let owner = Array.make n `None in
  let claim x who =
    if not outer.(x) then
      match owner.(x) with
      | `None -> owner.(x) <- who
      | w when w = who -> ()
      | _ -> bad "variable %d is in no pattern of the question: it may be the own of one Not or one Or only" x
  in
  List.iteri
    (fun k it ->
      match it with
      | Not l -> List.iter (fun x -> claim x (`Not k)) (flat_vars l)
      | Or alts -> List.iter (fun a -> List.iter (fun x -> claim x (`Or k)) (flat_vars a)) alts
      | Range (x, _, _) | In (x, _) -> if not outer.(x) then bad "variable %d of a condition appears in no pattern" x
      | Pattern _ -> ())
    extra;
  List.iter (fun (x, _, _) -> if not outer.(x) then bad "variable %d of a condition appears in no pattern" x) q.ranges;
  Array.iteri (fun x t -> if t = None then bad "variable %d appears in no pattern" x) typs;
  (* a Not's own variables need a pattern of the Not *)
  List.iter
    (function
      | Not l -> List.iter (fun x -> if (not outer.(x)) && not (List.mem x (pattern_vars l)) then bad "variable %d of a condition appears in no pattern" x) (flat_vars l)
      | Or alts -> List.iter (fun a -> List.iter (fun x -> if (not outer.(x)) && not (List.mem x (pattern_vars a)) then bad "variable %d of a condition appears in no pattern" x) (flat_vars a)) alts
      | _ -> ())
    extra;
  let not_of l = { items = l; own = List.filter (fun x -> not outer.(x)) (flat_vars l) } in
  let base =
    { pats = q.where; ranges = q.ranges; ins = List.filter_map (function In (x, l) -> Some (x, l) | _ -> None) extra;
      nots = List.filter_map (function Not l -> Some (not_of l) | _ -> None) extra; free = [] }
  in
  if q.where = [] && not (List.exists (function Or _ -> true | _ -> false) extra) then bad "a question needs a pattern outside Not";
  let add c (a : item list) =
    List.fold_left
      (fun c -> function
        | Pattern pt -> { c with pats = c.pats @ [ pt ] }
        | Range (x, lo, hi) -> { c with ranges = c.ranges @ [ (x, lo, hi) ] }
        | In (x, l) -> { c with ins = c.ins @ [ (x, l) ] }
        | Not _ | Or _ -> c)
      c a
  in
  let conjs =
    List.fold_left
      (fun cs it ->
        match it with
        | Or alts ->
          List.concat_map
            (fun c ->
              List.mapi
                (fun j a ->
                  let before = List.filteri (fun i _ -> i < j) alts in
                  let c = add c a in
                  { c with nots = c.nots @ List.map not_of before; free = c.free @ List.filter (fun x -> not outer.(x)) (flat_vars a) })
                alts)
            cs
        | _ -> cs)
      [ base ] extra
  in
  { vars = n; outer; typs; conjs }

let typs_of (t : t) = Array.map (function Some ty -> ty | None -> Value.Tint) t.typs

(* the words of In's values: sorted, distinct; a value the view does not hold is no candidate *)
let words_of (v : Store.view) (ty : Value.typ) l =
  List.iter (fun x -> if not (Value.has_type ty x) then bad "In needs values of the variable's type (a %s), not %s" (Value.typ_name ty) (Value.to_string x)) l;
  Array.of_list (List.sort_uniq compare (List.filter_map (Store.word v) l))

exception Found

(* a Not compiled: [holds env] on the conjunction's words (renumbered by [at]) is true when the Not's items have an
   answer, the binding then dropped *)
let not_check (v : Store.view) (t : t) at (nt : not_) : int array -> bool =
  let typs = typs_of t in
  match nt.items, nt.own with
  | [ Pattern { e; p; v = pv } ], [] ->
    let side = function Query.Var x -> `B (at x) | Thing c -> `W (Some c) | Val x -> `W (Store.word v x) in
    (match side e, side pv with
     | `W None, _ | _, `W None -> fun _ -> false
     | se, sv ->
       let get s env = match s with `B i -> env.(i) | `W (Some w) -> w | `W None -> -1 in
       fun env -> Store.mem v (get se env) p (get sv env))
  | [ Pattern { e = Var x; p; v = Var y } ], [ o ] when x <> y && o = y && t.outer.(x) -> let i = at x in fun env -> Store.has_value v env.(i) p
  | [ Pattern { e = Var x; p; v = Var y } ], [ o ] when x <> y && o = x && t.outer.(y) -> let i = at y in fun env -> Store.count_things v p env.(i) > 0
  | items, own ->
    (* the Not's own question: its own variables numbered from 0, the others fixed to the binding's values *)
    let own = Array.of_list own in
    let local x = let r = ref (-1) in Array.iteri (fun i y -> if y = x then r := i) own; !r in
    fun env ->
      let fixed x = Store.value v typs.(x) env.(at x) in
      let term = function
        | Query.Var x when local x >= 0 -> Query.Var (local x)
        | Var x -> (match typs.(x) with Tlink -> Query.Thing env.(at x) | _ -> Query.Val (fixed x))
        | t -> t
      in
      let term_e = function Query.Var x when local x < 0 -> Query.Thing env.(at x) | t -> term t in
      let ok = ref true in
      let pats = ref [] and ranges = ref [] and sets = ref [] in
      List.iter
        (function
          | Pattern pt -> pats := { pt with Query.e = term_e pt.e; v = term pt.v } :: !pats
          | Range (x, lo, hi) ->
            if local x >= 0 then ranges := (local x, lo, hi) :: !ranges
            else begin
              let w = env.(at x) in
              match Store.word v lo, Store.word v hi with
              | Some a, Some b -> if w < a || w > b then ok := false
              | _ -> ok := false
            end
          | In (x, l) ->
            let ws = words_of v typs.(x) l in
            if local x >= 0 then sets := (local x, ws) :: !sets else if not (Query.in_sorted ws env.(at x)) then ok := false
          | Not _ | Or _ -> ())
        items;
      !ok
      &&
      let q = { Query.vars = Array.length own; where = List.rev !pats; ranges = List.rev !ranges } in
      match Query.fold ~seq:true ~sets:!sets v q ~init:(fun () -> ()) ~merge:(fun () () -> ()) ~step:(fun () _ -> raise Found) with
      | () -> false
      | exception Found -> true

(* [fold v t ?range]: every binding of the question's variables, as an array of words a variable (the others' cells
   are 0), each once; [range]: one more range on a variable of the question *)
(* a conjunction as a question of its own variables, numbered from 0: the question, the number of each variable in
   it (-1: not in it), the variable of each of its numbers, and its sets *)
let dense ?range (v : Store.view) (t : t) (c : conj) =
  let typs = typs_of t in
  let used = Array.make t.vars false in
  List.iter (fun (pt : Query.pattern) -> (match pt.e with Var x -> used.(x) <- true | _ -> ()); match pt.v with Var x -> used.(x) <- true | _ -> ()) c.pats;
  let dense = Array.make t.vars (-1) and k = ref 0 in
  Array.iteri (fun x u -> if u then (dense.(x) <- !k; incr k)) used;
  let back = Array.make !k 0 in
  Array.iteri (fun x d -> if d >= 0 then back.(d) <- x) dense;
  let ren = function Query.Var x -> Query.Var dense.(x) | t -> t in
  let ranges = c.ranges @ (match range with Some r -> [ r ] | None -> []) in
  let q =
    { Query.vars = !k; where = List.map (fun (pt : Query.pattern) -> { pt with Query.e = ren pt.e; v = ren pt.v }) c.pats;
      ranges = List.map (fun (x, lo, hi) -> dense.(x), lo, hi) ranges }
  in
  q, dense, back, List.map (fun (x, l) -> dense.(x), words_of v typs.(x) l) c.ins

let fold ?(seq = false) ?range (v : Store.view) (t : t) ~init ~step ~merge =
  let run (c : conj) =
    let q, dense, back, sets = dense ?range v t c in
    let checks = List.map (not_check v t (fun x -> dense.(x))) c.nots in
    let outer = Array.to_list (Array.mapi (fun d x -> d, x) back) |> List.filter (fun (_, x) -> t.outer.(x)) in
    let full env = let b = Array.make t.vars 0 in List.iter (fun (d, x) -> b.(x) <- env.(d)) outer; b in
    let keep env = List.for_all (fun h -> not (h env)) checks in
    if c.free = [] then
      Query.fold ~seq ~sets v q ~init ~merge ~step:(fun acc env -> if keep env then step acc (full env) else acc)
    else begin
      (* bindings once each, though the alternative's own variables give one for each of their values *)
      let seen = Hashtbl.create 64 in
      Query.fold ~seq:true ~sets v q ~init ~merge
        ~step:(fun acc env ->
          if keep env then begin
            let b = full env in
            if Hashtbl.mem seen b then acc else (Hashtbl.replace seen b (); step acc b)
          end
          else acc)
    end
  in
  match t.conjs with
  | [] -> init ()
  | c :: rest -> List.fold_left (fun acc c -> merge acc (run c)) (run c) rest

(* the planner's estimate of the work, all its questions *)
let estimate (v : Store.view) (t : t) =
  List.fold_left (fun s (c : conj) -> let q, _, _, sets = dense v t c in s +. Query.estimate ~sets v q) 0. t.conjs
