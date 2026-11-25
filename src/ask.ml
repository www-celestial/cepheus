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
     when it is the smallest, else as a check of each (Query.fold ~sets).
   - Prefix x p: the text x starts with the bytes of p: the words of the texts of x's property that do, found by two
     binary searches in each run's text order (run format 9, Store.prefix_words), and then a set as In's.
   - Less x y: x < y (Less_or_equal: x <= y), two variables of one type (an int, a float, a date, money, a text, a
     link), each bound by a pattern; at the top, in a Not or in an alternative. The variable the join binds later is
     bounded by the other's value at its level: a range of the sorted index for the types whose words keep their
     order, a check of each candidate for a text (its bytes) and a float (totalOrder): Query.fold ~less.
   - Optional [e p y]: the values of the thing e's property p, or none: SPARQL's OPTIONAL (Perez, Arenas, Gutierrez,
     TODS 2009) for one pattern, the LEFT JOIN. e is a variable that a pattern of the question binds (or a thing's
     id); y is a variable in no other item; at the top only. Bound last, after the join and its Nots: each binding
     of the other variables gives a row for each value of e's p, or one row where y is missing (bit y of the mask
     after the variables, below). So the rows are those of the question without it, each once a value, or once.
   - Trunc (y, x, unit, zone): y is the start of the unit (a day, a month...) of the date x in the zone's local time
     (Zone.trunc): a variable computed from x, as SPARQL's BIND, numbered after the question's variables (vars, vars
     + 1, ... in the order of the Truncs), for Give, Group and Sort only; at the top only. The join never sees it: a
     question's answer and a watch compute y from x's word as they give a row (Answer, Live), so a report of months
     is the question of its dates. *)

type item =
  | Pattern of Query.pattern
  | Range of int * Value.t * Value.t
  | In of int * Value.t list
  | Prefix of int * string  (** the text starts with these bytes *)
  | Not of item list  (** patterns and conditions *)
  | Or of item list list  (** alternatives, each its patterns and conditions (And) *)
  | Less of int * int  (** x < y *)
  | Less_or_equal of int * int  (** x <= y *)
  | Optional of Query.pattern  (** the pattern's value, or missing *)
  | Trunc of int * int * string * string  (** y = the start of x's unit in the zone *)

let bad = Query.bad

let pattern_terms (pt : Query.pattern) = (match pt.e with Var x -> [ x ] | _ -> []) @ (match pt.v with Var x -> [ x ] | _ -> [])

let vars_of_item = function
  | Pattern pt | Optional pt -> pattern_terms pt
  | Range (x, _, _) | In (x, _) | Prefix (x, _) -> [ x ]
  | Less (x, y) | Less_or_equal (x, y) -> [ x; y ]
  | Not _ | Or _ | Trunc _ -> []

(* every pattern of a question, those inside Not and Or too *)
let patterns (q : Query.t) extra =
  let rec of_item = function
    | Pattern p | Optional p -> [ p ]
    | Range _ | In _ | Prefix _ | Less _ | Less_or_equal _ | Trunc _ -> []
    | Not l -> List.concat_map of_item l
    | Or alts -> List.concat_map (List.concat_map of_item) alts
  in
  q.where @ List.concat_map of_item extra

let flat_vars items = List.sort_uniq compare (List.concat_map vars_of_item items)

let pattern_vars items = List.sort_uniq compare (List.concat_map (function Pattern _ as i -> vars_of_item i | _ -> []) items)

let simple = function Pattern _ | Range _ | In _ | Prefix _ | Less _ | Less_or_equal _ -> true | Not _ | Or _ | Optional _ | Trunc _ -> false

(* ---- what the question is: its variables, its types, and its conjunctions ---- *)

type not_ = { items : item list; own : int list }

(* one question of the disjoint union *)
type conj = {
  pats : Query.pattern list;
  ranges : (int * Value.t * Value.t) list;
  ins : (int * Value.t list) list;
  prefixes : (int * string) list;
  less : (int * int * bool) list;  (* x < y (strict) or x <= y *)
  nots : not_ list;
  free : int list;  (* the variables of its alternatives' own: its bindings are kept, to give each binding once *)
}

(* an Optional: its thing (a variable of the question or a thing), its property, its value's variable *)
type opt = { oe : Query.term; op : int; ov : int }

type t = {
  vars : int;
  outer : bool array;  (* the question's variables *)
  typs : Value.typ option array;
  conjs : conj list;
  opts : opt array;
      (* its Optionals, bound last: a binding is then [vars + 1] words, the last the mask of its missing variables
         (bit x: x is missing, its word 0) *)
  words : (Store.view * (int * Value.t list * int array) list) option Atomic.t;
      (* the words of its Ins' values in the view last asked, found once for all its conjunctions, Nots and windows *)
}

let max_prefix = 1024

(* the bit of a missing variable in the mask: OCaml's ints have 63 *)
let max_optional_var = Sys.int_size - 1

let less_of = function Less (x, y) -> Some (x, y, true) | Less_or_equal (x, y) -> Some (x, y, false) | _ -> None

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
    | Pattern (pt : Query.pattern) | Optional pt ->
      let d = typ_of v pt.p in
      (match pt.e with Var x -> set x Value.Tlink | _ -> ());
      (match pt.v with Var x -> set x d.typ | Val x when not (Value.has_type d.typ x) -> bad "%s is not a %s" (Value.to_string x) (Value.typ_name d.typ) | _ -> ())
    | Range (x, _, _) | In (x, _) | Prefix (x, _) -> if x < 0 || x >= nvars then bad "variable %d out of range" x
    | Less (x, y) | Less_or_equal (x, y) -> List.iter (fun x -> if x < 0 || x >= nvars then bad "variable %d out of range" x) [ x; y ]
    | Not l -> List.iter go l
    | Or alts -> List.iter (List.iter go) alts
    | Trunc _ -> ()
  in
  List.iter go items;
  (* a range is for an int, a float, a date or money (and links and bools, inside the engine); Less for two
     variables of one type, not bools *)
  let rec ranges = function
    | Range (x, _, _) -> (match ty.(x) with Some t when Value.inline t || t = Tfloat -> () | _ -> bad "a range needs an int, float, date or money variable")
    | Prefix (x, p) ->
      (match ty.(x) with Some Ttext | None -> () | Some t -> bad "Prefix is for a text, not a %s" (Value.typ_name t));
      if String.length p < 1 || String.length p > max_prefix then bad "Prefix takes 1 to %d bytes, not %d" max_prefix (String.length p)
    | Less (x, y) | Less_or_equal (x, y) -> (
      match ty.(x), ty.(y) with
      | Some Tbool, _ | _, Some Tbool -> bad "Less compares ints, floats, dates, money, texts and links, not bools"
      | Some a, Some b when a <> b -> bad "Less compares two variables of one type, not a %s and a %s" (Value.typ_name a) (Value.typ_name b)
      | _ -> ())
    | Not l -> List.iter ranges l
    | Or alts -> List.iter (List.iter ranges) alts
    | Pattern _ | In _ | Optional _ | Trunc _ -> ()
  in
  List.iter ranges items;
  ty

(* bounds against a question that would cost the server more than its answer is worth; In takes as many values as a
   page has rows at most (Top.max_limit), so that a page's ids go back in one question *)
let max_in = 100_000
let max_operators = 64
let max_conjunctions = 64

let compile (v : Store.view) (q : Query.t) (extra : item list) : t =
  let n = q.vars in
  let rec size = function Not l -> 1 + List.fold_left (fun s i -> s + size i) 0 l | Or alts -> 1 + List.fold_left (fun s a -> s + List.fold_left (fun s i -> s + size i) 0 a) 0 alts | _ -> 1 in
  let ops = List.fold_left (fun s i -> s + size i) 0 extra in
  if ops > max_operators then bad "a question takes at most %d operators and their items, not %d" max_operators ops;
  (* a Trunc is no condition of the join: Answer and Live take it out before (Ask.truncs) *)
  List.iter (function Trunc _ -> bad "Trunc is for Give: its variable is computed as a row is given" | _ -> ()) extra;
  let rec ins = function In (_, l) -> if List.length l > max_in then bad "In takes at most %d values, not %d" max_in (List.length l) | Not l -> List.iter ins l | Or alts -> List.iter (List.iter ins) alts | _ -> () in
  List.iter ins extra;
  let conj = List.fold_left (fun c -> function Or alts -> c * max 1 (List.length alts) | _ -> c) 1 extra in
  if conj > max_conjunctions then bad "a question's Ors make %d questions to ask (the product of their alternatives): at most %d" conj max_conjunctions;
  let top = List.map (fun pt -> Pattern pt) q.where @ List.map (fun (x, lo, hi) -> Range (x, lo, hi)) q.ranges @ extra in
  let typs = types v n top in
  List.iter
    (function
      | Not l ->
        if l = [] || List.length l > 4 then bad "Not takes 1 to 4 patterns or conditions, not %d" (List.length l);
        if not (List.for_all simple l) then bad "Not takes patterns and conditions: no Not, Or or Optional inside it"
      | Or alts ->
        if List.length alts < 2 || List.length alts > 4 then bad "Or takes 2 to 4 alternatives, not %d" (List.length alts);
        List.iter
          (fun a ->
            if a = [] || List.length a > 4 then bad "And takes 1 to 4 patterns or conditions, not %d" (List.length a);
            if not (List.for_all simple a) then bad "an alternative of Or takes patterns and conditions: no Not, Or or Optional inside it")
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
  (* an Optional: its thing a variable of the question (or a thing), its value a variable in no other item; then a
     variable of the question *)
  let opts =
    List.filter_map
      (function
        | Optional (pt : Query.pattern) ->
          (match pt.e with
           | Var x when outer.(x) -> ()
           | Thing _ -> ()
           | _ -> bad "the thing of Optional is a variable that a pattern of the question binds, or a thing's id");
          let y = match pt.v with Var y -> y | _ -> bad "the value of Optional is a variable" in
          if y >= max_optional_var then bad "the value of Optional is one of the question's first %d variables, not %d" max_optional_var y;
          let uses = List.length (List.filter (( = ) y) (List.concat_map (fun it ->
            let rec all = function Not l -> List.concat_map all l | Or alts -> List.concat_map (List.concat_map all) alts | i -> vars_of_item i in
            all it) top)) in
          if uses <> 1 then bad "the value of Optional is a variable in no other item of the question: variable %d is in %d" y (uses - 1);
          Some { oe = pt.e; op = pt.p; ov = y }
        | _ -> None)
      extra
  in
  List.iter (fun o -> outer.(o.ov) <- true) opts;
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
      | Range (x, _, _) | In (x, _) | Prefix (x, _) -> if not outer.(x) then bad "variable %d of a condition appears in no pattern" x
      | Less (x, y) | Less_or_equal (x, y) -> List.iter (fun x -> if not outer.(x) then bad "variable %d of a condition appears in no pattern" x) [ x; y ]
      | Pattern _ | Optional _ | Trunc _ -> ())
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
      prefixes = List.filter_map (function Prefix (x, p) -> Some (x, p) | _ -> None) extra;
      less = List.filter_map less_of extra;
      nots = List.filter_map (function Not l -> Some (not_of l) | _ -> None) extra; free = [] }
  in
  if q.where = [] && not (List.exists (function Or _ -> true | _ -> false) extra) then bad "a question needs a pattern outside Not";
  let add c (a : item list) =
    List.fold_left
      (fun c -> function
        | Pattern pt -> { c with pats = c.pats @ [ pt ] }
        | Range (x, lo, hi) -> { c with ranges = c.ranges @ [ (x, lo, hi) ] }
        | In (x, l) -> { c with ins = c.ins @ [ (x, l) ] }
        | Prefix (x, p) -> { c with prefixes = c.prefixes @ [ (x, p) ] }
        | (Less _ | Less_or_equal _) as it -> { c with less = c.less @ Option.to_list (less_of it) }
        | Not _ | Or _ | Optional _ | Trunc _ -> c)
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
  { vars = n; outer; typs; conjs; opts = Array.of_list opts; words = Atomic.make None }

let typs_of (t : t) = Array.map (function Some ty -> ty | None -> Value.Tint) t.typs

(* the words of In's values: sorted, distinct; a value the view does not hold is no candidate. O(n log n) for n
   values, once a question (not once a conjunction, a Not's binding or a window): [words_of] *)
let sorted_words (v : Store.view) (ty : Value.typ) l =
  List.iter (fun x -> if not (Value.has_type ty x) then bad "In needs values of the variable's type (a %s), not %s" (Value.typ_name ty) (Value.to_string x)) l;
  let a = Array.of_list (List.filter_map (function Value.Link t -> Some (Query.rep v t) | x -> Store.word v x) l) in
  Array.sort (fun (x : int) y -> compare x y) a;
  let n = ref 0 in
  Array.iteri (fun i w -> if i = 0 || w <> a.(!n - 1) then (a.(!n) <- w; incr n)) a;
  Array.sub a 0 !n

(* the words of the In (x, l) of question t in view v, found once: the cache holds one view's (a race between two
   readers of t at most finds them twice) *)
let words_of (t : t) (v : Store.view) x l =
  let known = match Atomic.get t.words with Some (v', k) when v' == v -> k | _ -> [] in
  match List.find_opt (fun (y, l', _) -> y = x && l' == l) known with
  | Some (_, _, ws) -> ws
  | None ->
    let ws = sorted_words v (match t.typs.(x) with Some ty -> ty | None -> Value.Tint) l in
    Atomic.set t.words (Some (v, (x, l, ws) :: known));
    ws

exception Found

(* the words a Prefix lets x take: those of the texts of the property of a pattern that gives x as its value *)
let prefix_set (v : Store.view) items x pre =
  match List.find_map (function Pattern (pt : Query.pattern) when pt.v = Query.Var x -> Some pt.p | _ -> None) items with
  | Some p -> Store.prefix_words v p pre
  | None -> bad "variable %d of Prefix is the value of no pattern" x

(* a Not compiled: [holds env] on the conjunction's words (renumbered by [at]) is true when the Not's items have an
   answer, the binding then dropped *)
let not_check ~budget ?stop ~(spent : int Atomic.t) (v : Store.view) (t : t) at (nt : not_) : int array -> bool =
  let typs = typs_of t in
  match nt.items, nt.own with
  | [ Pattern { e; p; v = pv } ], [] ->
    let side = function Query.Var x -> `B (at x) | Thing c -> `W (Some (Query.rep v c)) | Val (Value.Link l) -> `W (Some (Query.rep v l)) | Val x -> `W (Store.word v x) in
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
    (* the words of each In and of each Prefix on an own variable: the same for every binding, found once, at the
       first binding (as when they were found at each: a question that never reaches the Not is not refused for
       them); a race of two domains finds them twice at most *)
    let known = Atomic.make None in
    let sets_of () =
      match Atomic.get known with
      | Some s -> s
      | None ->
        let s =
          List.map
            (function
              | In (x, l) -> words_of t v x l
              | Prefix (x, pre) when local x >= 0 -> prefix_set v items x pre
              | _ -> [||])
            items
        in
        Atomic.set known (Some s);
        s
    in
    fun env ->
      let fixed x = Store.value v typs.(x) env.(at x) in
      let term = function
        | Query.Var x when local x >= 0 -> Query.Var (local x)
        | Var x -> (match typs.(x) with Tlink -> Query.Thing env.(at x) | _ -> Query.Val (fixed x))
        | t -> t
      in
      let term_e = function Query.Var x when local x < 0 -> Query.Thing env.(at x) | t -> term t in
      let ok = ref true in
      let pats = ref [] and ranges = ref [] and sets = ref [] and less = ref [] in
      List.iter2
        (fun it ws ->
          match it with
          | Pattern pt -> pats := { pt with Query.e = term_e pt.e; v = term pt.v } :: !pats
          | Range (x, lo, hi) ->
            if local x >= 0 then ranges := (local x, lo, hi) :: !ranges
            else begin
              let w = env.(at x) in
              match typs.(x), lo, hi with
              | Tfloat, Float a, Float b ->
                let f = Query.float_of_word v w in
                if Value.total_order a f > 0 || Value.total_order f b > 0 then ok := false
              | Tfloat, _, _ -> ok := false
              | _ -> (
                match Store.word v lo, Store.word v hi with
                | Some a, Some b -> if w < a || w > b then ok := false
                | _ -> ok := false)
            end
          | Less (x, y) | Less_or_equal (x, y) -> (
            let strict = (match it with Less _ -> true | _ -> false) in
            let side x = if local x >= 0 then Query.V (local x) else Query.W env.(at x) in
            match side x, side y with
            | W a, W b ->
              let c = Query.compare_words v typs.(x) a b in
              if (strict && c >= 0) || c > 0 then ok := false
            | lx, ly -> less := { Query.lx; ly; strict } :: !less)
          | In (x, _) -> if local x >= 0 then sets := (local x, ws) :: !sets else if not (Query.in_sorted ws env.(at x)) then ok := false
          | Prefix (x, pre) ->
            if local x >= 0 then sets := (local x, ws) :: !sets
            else (let t = Store.text v env.(at x) in if not (String.length t >= String.length pre && String.sub t 0 (String.length pre) = pre) then ok := false)
          | Not _ | Or _ | Optional _ | Trunc _ -> ())
        items (sets_of ());
      !ok
      &&
      let q = { Query.vars = Array.length own; where = List.rev !pats; ranges = List.rev !ranges } in
      (* the Nots' own questions share the question's budget: their work adds up *)
      let left = budget - Atomic.get spent in
      if left <= 0 then raise (Query.Over_budget budget);
      let wk = ref 1 in
      let found =
        match Query.fold ~seq:true ~sets:!sets ~less:!less ~budget:left ~account:wk ?stop v q ~init:(fun () -> ()) ~merge:(fun () () -> ()) ~step:(fun () _ -> raise Found) with
        | () -> false
        | exception Found -> true
      in
      ignore (Atomic.fetch_and_add spent !wk);
      found

(* [fold v t ?range ?words]: every binding of the question's variables, as an array of words a variable (the others'
   cells are 0), each once; [range]: one more range on a variable of the question; [words]: the words a variable of
   the question may take, sorted and distinct (a window of the index path, Top) *)
(* a conjunction as a question of its own variables, numbered from 0: the question, the number of each variable in
   it (-1: not in it), the variable of each of its numbers, and its sets *)
let dense ?range ?words (v : Store.view) (t : t) (c : conj) =
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
  let pats = List.map (fun pt -> Pattern pt) c.pats in
  (* a Prefix on a variable an In fixes already (a watch's key): the In's texts that start with it, no search *)
  let prefix x p =
    match List.find_opt (fun (y, _) -> y = x) c.ins with
    | Some (_, l) ->
      let n = String.length p in
      Array.of_list (List.filter (fun w -> let t = Store.text v w in String.length t >= n && String.sub t 0 n = p) (Array.to_list (words_of t v x l)))
    | None -> prefix_set v pats x p
  in
  let window = match words with Some (x, ws) -> [ (dense.(x), ws) ] | None -> [] in
  let less = List.map (fun (x, y, strict) -> { Query.lx = V dense.(x); ly = V dense.(y); strict }) c.less in
  q, dense, back, window @ List.map (fun (x, l) -> dense.(x), words_of t v x l) c.ins @ List.map (fun (x, p) -> dense.(x), prefix x p) c.prefixes, less

(* the rows of a binding [b] (of [vars + 1] words, its mask 0) with its Optionals bound, each given to [step]: a row
   a value of each Optional's property, or one with the variable missing (its word 0, its bit in the mask). A row
   given is [b] itself or a copy: [step] may keep it *)
let expand (v : Store.view) (t : t) step =
  let n = Array.length t.opts and m = t.vars in
  let rec go k acc (b : int array) =
    if k = n then step acc b
    else begin
      let o = t.opts.(k) in
      let e = match o.oe with Query.Var x -> b.(x) | Thing c -> Query.rep v c | Val _ -> -1 in
      let ws = ref [] in
      if e >= 0 then Store.iter_values v e o.op (fun w -> ws := w :: !ws);
      match !ws with
      | [] -> b.(m) <- b.(m) lor (1 lsl o.ov); go (k + 1) acc b
      | [ w ] -> b.(o.ov) <- w; go (k + 1) acc b
      | ws -> List.fold_left (fun acc w -> let b' = Array.copy b in b'.(o.ov) <- w; go (k + 1) acc b') acc (List.rev ws)
    end
  in
  go 0

let fold ?(seq = false) ?(any_order = false) ?(budget = max_int) ?stop ?range ?words (v : Store.view) (t : t) ~init ~step ~merge =
  let spent = Atomic.make 0 in
  let width = if Array.length t.opts = 0 then t.vars else t.vars + 1 in
  let emit = if Array.length t.opts = 0 then step else expand v t step in
  let run (c : conj) =
    let q, dense, back, sets, less = dense ?range ?words v t c in
    let checks = List.map (not_check ~budget ?stop ~spent v t (fun x -> dense.(x))) c.nots in
    let outer = Array.to_list (Array.mapi (fun d x -> d, x) back) |> List.filter (fun (_, x) -> t.outer.(x)) in
    let full env = let b = Array.make width 0 in List.iter (fun (d, x) -> b.(x) <- env.(d)) outer; b in
    let keep env = List.for_all (fun h -> not (h env)) checks in
    if c.free = [] then
      Query.fold ~seq ~any_order ~sets ~less ~budget ?stop v q ~init ~merge ~step:(fun acc env -> if keep env then emit acc (full env) else acc)
    else begin
      (* bindings once each, though the alternative's own variables give one for each of their values *)
      let seen = Hashtbl.create 64 in
      Query.fold ~seq:true ~sets ~less ~budget ?stop v q ~init ~merge
        ~step:(fun acc env ->
          if keep env then begin
            let b = full env in
            if Hashtbl.mem seen b then acc else (Hashtbl.replace seen b (); emit acc (if width > t.vars then Array.copy b else b))
          end
          else acc)
    end
  in
  match t.conjs with
  | [] -> init ()
  | c :: rest -> List.fold_left (fun acc c -> merge acc (run c)) (run c) rest

(* the row of [give]'s variables of a binding; with Optionals, the mask of its missing columns after them (bit c:
   column c is missing, its word 0), as Top's rows hold it *)
let projector (t : t) (give : int array) =
  let k = Array.length give in
  if Array.length t.opts = 0 then fun env -> Array.map (fun x -> env.(x)) give
  else begin
    if k > max_optional_var then bad "a question with Optional gives at most %d columns, not %d" max_optional_var k;
    let m = t.vars in
    fun env ->
      let r = Array.make (k + 1) 0 and mask = env.(m) in
      for c = 0 to k - 1 do
        let x = give.(c) in
        if (mask lsr x) land 1 = 1 then r.(k) <- r.(k) lor (1 lsl c) else r.(c) <- env.(x)
      done;
      r
  end

(* is variable x missing in a binding *)
let missing (t : t) (env : int array) x = Array.length t.opts > 0 && (env.(t.vars) lsr x) land 1 = 1

(* the planner's estimate of the work, all its questions *)
let estimate (v : Store.view) (t : t) =
  List.fold_left (fun s (c : conj) -> let q, _, _, sets, _ = dense v t c in s +. Query.estimate ~sets v q) 0. t.conjs

(* ---- Trunc: variables computed from a date ---- *)

(* a question's Truncs apart from its other operators *)
let truncs extra = List.partition (function Trunc _ -> true | _ -> false) extra

(* The Truncs of a question of [vars] variables of types [ty] (a variable of the question when [outer]), checked:
   each (x, its function of x's word); the i-th gives variable vars + i. Raises Query.Bad. *)
let derived ~vars ~(outer : int -> bool) (ty : Value.typ array) (ts : item list) =
  Array.of_list
    (List.mapi
       (fun i -> function
         | Trunc (y, x, unit, zone) ->
           if y <> vars + i then bad "Trunc gives variable %d, not %d: its variables come after the question's (%d to %d), in the order of the Truncs" (vars + i) y vars (vars + i);
           if vars + i >= max_optional_var then bad "a question with Trunc has at most %d variables and Truncs" max_optional_var;
           if x < 0 || x >= vars || not (outer x) then bad "Trunc takes a date variable of a pattern of the question, not variable %d" x;
           if ty.(x) <> Value.Tdate then bad "Trunc takes a date, not a %s" (Value.typ_name ty.(x));
           let f = try Zone.truncator ~unit ~zone with Zone.Bad m -> bad "%s" m in
           x, f
         | _ -> bad "a Trunc")
       ts)

(* the words of [give]'s columns of a binding, a Trunc's computed from its date's; with [mask] (the question has
   Optionals: a binding's mask at index [vars]), the mask of the missing columns after them, as [projector] *)
let derived_projector ~vars ~mask (d : (int * (int -> int)) array) (give : int array) =
  let k = Array.length give in
  if mask && k > max_optional_var then bad "a question with Optional gives at most %d columns, not %d" max_optional_var k;
  let src x = if x < vars then x else fst d.(x - vars) in
  let word x = if x < vars then (fun (env : int array) -> env.(x)) else (let s, f = d.(x - vars) in fun env -> f env.(s)) in
  let words = Array.map word give and srcs = Array.map src give in
  if not mask then fun env -> Array.map (fun w -> w env) words
  else fun env ->
    let r = Array.make (k + 1) 0 and m = env.(vars) in
    for c = 0 to k - 1 do
      if (m lsr srcs.(c)) land 1 = 1 then r.(k) <- r.(k) lor (1 lsl c) else r.(c) <- words.(c) env
    done;
    r
