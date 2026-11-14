(* The rule language: Datalog over facts. A rule is a question's patterns (Query.pattern: thing, property, value, the
   property a constant) and ranges, and a head: one pattern, the fact the rule gives for each answer of its body, or
   [Never], a constraint (an answer refuses the group). Its variables are typed as a question's are; every variable of
   the head appears in the body (range restriction, or safety); the head names no new thing, so the least model is
   finite and its evaluation always ends (Abiteboul, Hull, Vianu 1995, ch. 12-13). A rule is a schema thing: its
   cepheus/name and its cepheus/rule, the canonical text below, written in a group like any fact, so the journal keeps
   every version of it.

   A pattern's property is a property id, or a variable: [prop_var k] (a negative number) for ?k. A variable property
   is bound by another pattern of the body, whose property is a constant, that has it as its thing or its value
   ([[c, domain, p], [x, p, y]]: the W3C's form of OWL 2 RL's rules); the engine specialises such rules on the facts
   of that pattern when they are few (Reason). A variable that appears only as the value of patterns whose property
   is a variable has no type of its own: it takes the type of the property it is read from, checked when a fact is
   derived.

   Negation and aggregates (the reasoner design, section 5.9), written into a pattern's property so that the record
   keeps its fields (as [prop_var]): a pattern whose property is [absent k p] is a pattern of the rule's k-th Not
   ("there is no value of the Not's own variables that makes all of its patterns facts"); a head whose property is
   [aggregate f p] gives p the sum, the count, the smallest or the largest value over the answers of the body, one
   fact a value of its thing (the group). Their meaning is the perfect model of the stratified rules (Apt, Blair,
   Walker 1988; Przymusinski 1988), aggregates stratified as Mumick, Pirahesh, Ramakrishnan (1990) and Soufflé have
   them: a rule set where a property depends on its own absence, or on its own aggregate, is refused ([strata]).

   The canonical text, one line:
     vars N; where [E P V] [E P V] ...; range ?X LO HI; ...; not [E P V] ...; ...; give [E P V]
   or give never, or give F [E P V] with F one of sum, count, min, max (count's value is i0); a term is ?k (a
   variable), #n (a thing), or a value: iN (int), fH (float, hexadecimal, exact), b0 / b1, t"..." (text, OCaml's
   escapes), dN (date, ms), mN (money, minor units), lN (link); a property is its id or ?k. A text without "not" and
   aggregates is the text of the rules before them, unchanged. *)

type head = Give of Query.pattern | Never

type t = { name : string; vars : int; where : Query.pattern list; ranges : (int * Value.t * Value.t) list; head : head }

(* the property of a pattern as the variable ?k, and back (-1: a constant property) *)
let prop_var k = -1 - k
let[@inline] pvar p = if p < 0 then -1 - p else -1

(* a pattern of the k-th Not (0 to 15) of a rule, property p; an aggregate head of property p. Property ids are
   below 65,536 (Schema.first_thing): the encodings are above them, and a code that does not decode them reads no
   property *)
let absent_base = 0x4000_0000
let agg_base = 0x8000_0000
let max_nots = 16
let absent k p = absent_base + (k lsl 16) + p
let[@inline] is_absent p = p >= absent_base && p < agg_base
let absent_of p = (p - absent_base) lsr 16, (p - absent_base) land 0xffff

(* A template's list pattern (the reasoner design, section 5.16): [c, every L, m] reads "for every value m of c's L";
   the patterns that name m are written once for each member, the variables only they hold fresh in each copy (the
   W3C's LIST[...] of OWL 2 RL: cls-int1 over an intersection's members, prp-key over a key's properties). The engine
   unfolds a template on L's facts (Reason), so a write of L is a change of the rules. *)
let every_base = 0x2000_0000
let every p = every_base + p
let[@inline] is_every p = p >= every_base && p < every_base + 0x1_0000
let every_of p = p - every_base

(* the property a pattern reads: its own, decoded from a Not's or a template's *)
let base_prop p = if is_every p then every_of p else if p >= absent_base && p < absent_base + (max_nots lsl 16) then (p - absent_base) land 0xffff else p

type agg = [ `Sum | `Count | `Min | `Max ]

let agg_code : agg -> int = function `Sum -> 0 | `Count -> 1 | `Min -> 2 | `Max -> 3
let agg_name : agg -> string = function `Sum -> "sum" | `Count -> "count" | `Min -> "min" | `Max -> "max"
let aggregate (f : agg) p = agg_base + (agg_code f lsl 16) + p
(* the four codes [aggregate] makes, no other: a larger number is no property, refused as such *)
let[@inline] is_agg p = p >= agg_base && p < agg_base + (4 lsl 16)

let agg_of p : agg * int =
  (match (p - agg_base) lsr 16 with 0 -> `Sum | 1 -> `Count | 2 -> `Min | _ -> `Max), (p - agg_base) land 0xffff

(* A rule as the engine runs it: its positive patterns (its where without the Nots' patterns), each Not's patterns and
   own variables (those in no positive pattern), and its aggregate: [pos]'s head has the plain property. *)
type shape = { pos : t; nots : Query.pattern array array; own : int list array; agg : agg option }

let[@inline never] split r =
  let positive = List.filter (fun (q : Query.pattern) -> not (is_absent q.p)) r.where in
  let ks = List.sort_uniq compare (List.filter_map (fun (q : Query.pattern) -> if is_absent q.p then Some (fst (absent_of q.p)) else None) r.where) in
  let plain (q : Query.pattern) = { q with p = snd (absent_of q.p) } in
  let nots =
    Array.of_list
      (List.map
         (fun k -> Array.of_list (List.filter_map (fun (q : Query.pattern) -> if is_absent q.p && fst (absent_of q.p) = k then Some (plain q) else None) r.where))
         ks)
  in
  let outer = Array.make (max 1 r.vars) false in
  let mark = function Query.Var x when x >= 0 && x < r.vars -> outer.(x) <- true | _ -> () in
  List.iter (fun (q : Query.pattern) -> mark q.e; mark q.v; if q.p < 0 && pvar q.p < r.vars then outer.(pvar q.p) <- true) positive;
  let own =
    Array.map
      (fun ps ->
        List.sort_uniq compare
          (List.concat_map (fun (q : Query.pattern) -> List.filter_map (function Query.Var x when x >= 0 && x < r.vars && not outer.(x) -> Some x | _ -> None) [ q.e; q.v ]) (Array.to_list ps)))
      nots
  in
  let head, agg =
    match r.head with
    | Give h when is_agg h.p -> let f, p = agg_of h.p in Give { h with p }, Some f
    | h -> h, None
  in
  { pos = { r with where = positive; head }; nots; own; agg }

let is_plain r = List.for_all (fun (q : Query.pattern) -> not (is_absent q.p)) r.where && match r.head with Give h -> not (is_agg h.p) | Never -> true

(* ---- the canonical text ---- *)

let value_text (x : Value.t) =
  match x with
  | Int n -> Printf.sprintf "i%d" n
  | Float f -> Printf.sprintf "f%h" f
  | Bool b -> if b then "b1" else "b0"
  | Text s -> Printf.sprintf "t%S" s
  | Date n -> Printf.sprintf "d%d" n
  | Money n -> Printf.sprintf "m%d" n
  | Link n -> Printf.sprintf "l%d" n

let term_text = function Query.Var k -> Printf.sprintf "?%d" k | Thing n -> Printf.sprintf "#%d" n | Val x -> value_text x
let prop_text p = if p < 0 then Printf.sprintf "?%d" (-1 - p) else if is_every p then Printf.sprintf "*%d" (every_of p) else string_of_int p
let pattern_text (q : Query.pattern) = Printf.sprintf "[%s %s %s]" (term_text q.e) (prop_text q.p) (term_text q.v)

let[@inline never] to_text r =
  let s = split r in
  let b = Buffer.create 64 in
  Printf.bprintf b "vars %d; where" r.vars;
  List.iter (fun q -> Printf.bprintf b " %s" (pattern_text q)) s.pos.where;
  List.iter (fun (x, lo, hi) -> Printf.bprintf b "; range ?%d %s %s" x (value_text lo) (value_text hi)) r.ranges;
  Array.iter (fun ps -> Buffer.add_string b "; not"; Array.iter (fun q -> Printf.bprintf b " %s" (pattern_text q)) ps) s.nots;
  (match s.pos.head, s.agg with
   | Give q, None -> Printf.bprintf b "; give %s" (pattern_text q)
   | Give q, Some f -> Printf.bprintf b "; give %s %s" (agg_name f) (pattern_text q)
   | Never, _ -> Buffer.add_string b "; give never");
  Buffer.contents b

exception Parse of string

let[@inline never] of_text name text =
  let n = String.length text and i = ref 0 in
  let fail () = raise (Parse (Printf.sprintf "rule %s: cannot read its definition at character %d" name !i)) in
  let peek () = if !i < n then text.[!i] else '\000' in
  let skip () = while !i < n && text.[!i] = ' ' do incr i done in
  let word w = skip (); let l = String.length w in if !i + l <= n && String.sub text !i l = w then i := !i + l else fail () in
  let int () =
    let j = !i in
    if peek () = '-' then incr i;
    while !i < n && text.[!i] >= '0' && text.[!i] <= '9' do incr i done;
    match int_of_string_opt (String.sub text j (!i - j)) with Some k -> k | None -> fail ()
  in
  (* a text as Printf's %S writes it (String.escaped between quotes), read without Scanf, which the Cesia client's
     engine file cannot hold: a definition that is not exactly that fails here or at the canonical check *)
  let literal () =
    if peek () <> '"' then fail ();
    incr i;
    let b = Buffer.create 16 in
    let digit k = if k < n && text.[k] >= '0' && text.[k] <= '9' then Char.code text.[k] - 48 else fail () in
    let rec go () =
      if !i >= n then fail ();
      let c = text.[!i] in
      incr i;
      if c = '"' then Buffer.contents b
      else if c <> '\\' then (Buffer.add_char b c; go ())
      else begin
        let e = peek () in
        incr i;
        (match e with
         | '"' | '\\' -> Buffer.add_char b e
         | 'n' -> Buffer.add_char b '\n'
         | 't' -> Buffer.add_char b '\t'
         | 'r' -> Buffer.add_char b '\r'
         | 'b' -> Buffer.add_char b '\b'
         | '0' .. '9' ->
           let x = (100 * (Char.code e - 48)) + (10 * digit !i) + digit (!i + 1) in
           if x > 255 then fail ();
           Buffer.add_char b (Char.chr x);
           i := !i + 2
         | _ -> fail ());
        go ()
      end
    in
    go ()
  in
  let value () =
    let c = peek () in
    incr i;
    match c with
    | 'i' -> Value.Int (int ())
    | 'd' -> Date (int ())
    | 'm' -> Money (int ())
    | 'l' -> Link (int ())
    | 'b' -> (match peek () with '0' -> incr i; Bool false | '1' -> incr i; Bool true | _ -> fail ())
    | 'f' ->
      let j = !i in
      while !i < n && text.[!i] <> ' ' && text.[!i] <> ']' && text.[!i] <> ';' do incr i done;
      (match float_of_string_opt (String.sub text j (!i - j)) with Some f -> Float f | None -> fail ())
    | 't' -> Text (literal ())
    | _ -> fail ()
  in
  let term () =
    skip ();
    match peek () with
    | '?' -> incr i; Query.Var (int ())
    | '#' -> incr i; Thing (int ())
    | _ -> Val (value ())
  in
  let pattern () =
    word "[";
    let e = term () in
    skip ();
    let p =
      if peek () = '?' then (incr i; prop_var (int ()))
      else if peek () = '*' then (incr i; let q = int () in if q < 0 || q >= Schema.first_thing then fail (); every q)
      else int ()
    in
    let v = term () in
    word "]";
    { Query.e; p; v }
  in
  try
    word "vars";
    skip ();
    let vars = int () in
    word ";";
    word "where";
    let where = ref [] in
    skip ();
    while peek () = '[' do where := pattern () :: !where; skip () done;
    let ranges = ref [] and head = ref None and nots = ref 0 in
    let at w = !i + String.length w <= n && String.sub text !i (String.length w) = w in
    while !head = None do
      word ";";
      skip ();
      if at "range" then begin
        word "range";
        word "?";
        let x = int () in
        skip ();
        let lo = value () in
        skip ();
        let hi = value () in
        ranges := (x, lo, hi) :: !ranges
      end
      else if at "not " then begin
        (* a Not's patterns: constant properties *)
        word "not";
        let k = !nots in
        if k >= max_nots then fail ();
        incr nots;
        skip ();
        if peek () <> '[' then fail ();
        while peek () = '[' do
          let q = pattern () in
          if q.p < 0 || q.p >= Schema.first_thing then fail ();
          where := { q with p = absent k q.p } :: !where;
          skip ()
        done
      end
      else begin
        word "give";
        skip ();
        if at "never" then (word "never"; head := Some Never)
        else
          let f = List.find_opt (fun f -> at (agg_name f ^ " ")) [ `Sum; `Count; `Min; `Max ] in
          match f with
          | Some f ->
            word (agg_name f);
            let q = pattern () in
            if q.p < 0 || q.p >= Schema.first_thing then fail ();
            head := Some (Give { q with p = aggregate f q.p })
          | None -> head := Some (Give (pattern ()))
      end
    done;
    skip ();
    if !i <> n then fail ();
    let r = { name; vars; where = List.rev !where; ranges = List.rev !ranges; head = Option.get !head } in
    (* one text for one rule: what is read is what is written *)
    if to_text r <> text then raise (Parse (Printf.sprintf "rule %s: its definition is not in canonical form" name));
    Ok r
  with Parse m -> Error m

(* ---- checks, when a rule is written ---- *)

let pattern_vars (q : Query.pattern) =
  List.filter_map (function Query.Var k -> Some k | _ -> None) [ q.e; q.v ] @ (if q.p < 0 then [ pvar q.p ] else [])

let has_var_prop r =
  List.exists (fun (q : Query.pattern) -> q.p < 0) r.where || match r.head with Give h -> h.p < 0 | Never -> false

exception Bad of string

(* the variables' types, by the questions' rule (a variable has one type, from the patterns it appears in), a
   property variable a link; None for a variable that appears only as the value of patterns with a variable property
   (its type is the property's, at each instance) *)
let static_types (v : Store.view) r =
  let ty = Array.make (max 1 r.vars) None in
  let set x t =
    if x < 0 || x >= r.vars then raise (Bad (Printf.sprintf "variable %d out of range" x));
    match ty.(x) with
    | None -> ty.(x) <- Some t
    | Some t' -> if t' <> t then raise (Bad (Printf.sprintf "variable %d is both a %s and a %s" x (Value.typ_name t') (Value.typ_name t)))
  in
  List.iter
    (fun (q : Query.pattern) ->
      (match q.e with Query.Var x -> set x Value.Tlink | _ -> ());
      if q.p < 0 then set (pvar q.p) Value.Tlink
      else
        let p = base_prop q.p in
        match q.v, Schema.find v.schema p with
        | Query.Var x, Some d -> set x d.typ
        | Query.Var _, None -> raise (Bad (Printf.sprintf "no property %d" p))
        | _ -> ())
    r.where;
  ty

let[@inline never] check (v : Store.view) r =
  let bad fmt = Printf.ksprintf (fun s -> raise (Parse (Printf.sprintf "rule %s: %s" r.name s))) fmt in
  try
    if r.vars < 0 || r.vars > 64 then bad "%d variables (at most 64)" r.vars;
    List.iter
      (fun (q : Query.pattern) ->
        if is_absent q.p then (if fst (absent_of q.p) >= max_nots then bad "at most %d Nots" max_nots)
        else if is_agg q.p then bad "an aggregate is for its head, not for a pattern of its body")
      r.where;
    let sh = split r in
    let pos = sh.pos in
    if pos.where = [] then bad "its body has no pattern outside Not";
    let all = pos.where @ List.concat_map Array.to_list (Array.to_list sh.nots) in
    let seen = Array.make r.vars false in
    List.iter
      (fun (q : Query.pattern) ->
        List.iter (fun k -> if k < 0 || k >= r.vars then bad "variable ?%d out of range" k else seen.(k) <- true) (pattern_vars q);
        (match q.e with Query.Val _ -> bad "the thing of a pattern is a variable or a thing" | _ -> ());
        if q.p >= 0 && Schema.find v.schema (base_prop q.p) = None then bad "no property %d" (base_prop q.p))
      all;
    (* a template: one list pattern, its value the member variable, which other patterns name and the head does not *)
    (match List.filter (fun (q : Query.pattern) -> is_every q.p) pos.where with
     | [] -> ()
     | [ t ] -> (
       if sh.nots <> [||] || sh.agg <> None then bad "a template (every) takes no Not and no aggregate";
       match t.v with
       | Query.Var m ->
         let names (q : Query.pattern) = q.e = Query.Var m || q.v = Query.Var m || q.p = prop_var m in
         if not (List.exists (fun (q : Query.pattern) -> q != t && names q) pos.where) then
           bad "the member ?%d of every [..] is in no other pattern" m;
         (match pos.head with
          | Give h -> if names h then bad "the member ?%d of every [..] is in its head: each member is a copy of the patterns" m
          | Never -> ());
         if t.e = Query.Var m then bad "every [..] lists the values of a thing, not of itself"
       | _ -> bad "the value of every [..] is a variable: the member")
     | _ -> bad "one every [..] a rule");
    Array.iteri (fun k s -> if not s then bad "variable ?%d appears in no pattern of the body" k) seen;
    if List.exists (fun (q : Query.pattern) -> base_prop q.p = Schema.p_same) all then
      bad "cepheus/same is read through the classes of equal things, not by a rule's pattern";
    (* a Not: 1 to 4 patterns; a variable in no positive pattern is the own of one Not *)
    Array.iter (fun ps -> if Array.length ps > 4 then bad "a Not takes 1 to 4 patterns, not %d" (Array.length ps)) sh.nots;
    let owner = Array.make r.vars (-1) in
    Array.iteri
      (fun k own ->
        List.iter (fun x -> if owner.(x) >= 0 && owner.(x) <> k then bad "?%d is in no pattern outside Not: it may be the own of one Not only" x else owner.(x) <- k) own)
      sh.own;
    let outer x = x >= 0 && x < r.vars && owner.(x) < 0 in
    (* a variable property is bound by a positive pattern whose property is a constant: no pattern scans every fact *)
    let bound_by_const k =
      List.exists (fun (q : Query.pattern) -> q.p >= 0 && (q.e = Query.Var k || q.v = Query.Var k)) pos.where
    in
    List.iter
      (fun (q : Query.pattern) ->
        if q.p < 0 && not (bound_by_const (pvar q.p)) then
          bad "the property ?%d is bound by no pattern whose property is a constant" (pvar q.p))
      pos.where;
    let sty = match static_types v r with t -> t | exception Bad m -> bad "%s" m in
    List.iter
      (fun (x, lo, hi) ->
        match if x < 0 || x >= r.vars then None else sty.(x) with
        | Some t when Value.inline t ->
          if not (Value.has_type t lo && Value.has_type t hi) then bad "the bounds of ?%d are not of its type" x
        | _ -> bad "a range needs an int, date or money variable")
      r.ranges;
    List.iter
      (fun (q : Query.pattern) ->
        match q.v, (if q.p >= 0 then Schema.find v.schema q.p else None) with
        | Val x, Some d when not (Value.has_type d.typ x) -> bad "%s is not a %s" (Value.to_string x) (Value.typ_name d.typ)
        | _ -> ())
      all;
    (match pos.head with
     | Never -> ()
     | Give q ->
       (* a variable head property: its type, and that it is no cepheus/ property, are checked at each fact derived *)
       let d =
         if q.p < 0 then begin
           if not (bound_by_const (pvar q.p)) then
             bad "the property ?%d of its head is bound by no pattern whose property is a constant" (pvar q.p);
           None
         end
         else match Schema.find v.schema q.p with Some d -> Some d | None -> bad "no property %d in its head" q.p
       in
       if q.p >= 0 && Schema.is_system q.p && q.p <> Schema.p_same then bad "its head gives a cepheus/ property";
       (* an equality: [x cepheus/same y] makes x and y one thing (the engine's classes of equal things, Reason) *)
       if q.p = Schema.p_same && (sh.nots <> [||] || sh.agg <> None) then bad "a rule that makes things the same takes no Not and no aggregate";
       (* the head's variables are bound by the body's positive patterns (range restriction) *)
       List.iter (fun k -> if k >= 0 && k < r.vars && not (outer k) then bad "?%d of its head is in no pattern outside Not" k) (pattern_vars q);
       (match q.e with
        | Query.Var k ->
          (* a variable without a type of its own is checked a thing at each fact derived *)
          if k < 0 || k >= r.vars then bad "variable ?%d out of range" k
          else (match sty.(k) with Some Value.Tlink | None -> () | Some _ -> bad "?%d is not a thing" k)
        | Thing t -> if t < Schema.first_thing then bad "its head's thing #%d is not an ordinary thing" t
        | Val _ -> bad "the thing of its head is a variable or a thing");
       match sh.agg, d with
       | Some f, Some d -> (
         (* an aggregate: one value a thing, of the aggregated variable's type (count: an int) *)
         if d.many then bad "%s takes many values: an aggregate gives a property that takes one" d.name;
         match f, q.v with
         | `Count, Query.Val (Value.Int 0) -> if d.typ <> Value.Tint then bad "count gives an int, and %s takes a %s" d.name (Value.typ_name d.typ)
         | `Count, _ -> bad "count counts the answers: its value is i0"
         | (`Sum | `Min | `Max), Query.Var k when k >= 0 && k < r.vars -> (
           match sty.(k), f with
           | Some ((Value.Tint | Value.Tmoney _) as t), `Sum | Some ((Value.Tint | Value.Tdate | Value.Tmoney _) as t), (`Min | `Max) ->
             if t <> d.typ then bad "?%d is a %s, %s takes a %s" k (Value.typ_name t) d.name (Value.typ_name d.typ)
           | Some t, _ -> bad "%s of a %s: sum is for ints and money, min and max for ints, dates and money" (agg_name f) (Value.typ_name t)
           | None, _ -> bad "%s of ?%d, which has no type of its own" (agg_name f) k)
         | _, _ -> bad "%s takes a variable of the body" (agg_name f))
       | Some _, None -> bad "an aggregate gives a constant property"
       | None, None -> (match q.v with Query.Var k when k < 0 || k >= r.vars -> bad "variable ?%d out of range" k | _ -> ())
       | None, Some d -> (
         match q.v with
         | Query.Var k ->
           if k < 0 || k >= r.vars then bad "variable ?%d out of range" k
           else (
             match sty.(k) with
             | Some t when t <> d.typ -> bad "?%d is a %s, %s takes a %s" k (Value.typ_name t) d.name (Value.typ_name d.typ)
             | _ -> ())
         | Thing t -> if d.typ <> Value.Tlink then bad "%s takes a %s, not a thing" d.name (Value.typ_name d.typ) else ignore t
         | Val x -> if not (Value.has_type d.typ x) then bad "%s is not a %s" (Value.to_string x) (Value.typ_name d.typ)));
    Ok ()
  with Parse m -> Error m

(* ---- strata (Apt, Blair, Walker 1988), at the level of a property refined by a constant value ----
   A node is (property, value word), -1 for any: a pattern [x, Type, Invoice] is the node (Type, Invoice), so that a
   Not over one class may depend on another class without a false cycle. Rule j depends on rule i when i's head
   matches a pattern of j: positively, or negatively when the pattern is in a Not of j or j is an aggregate (its value
   needs its body complete). Rules whose heads match each other give one property: they are one predicate, in one
   stratum. Constraints read the state after every stratum and are in none. The rule set is stratified when no cycle
   of these dependencies holds a negative one (Tarjan's strong components, 1972); a rule's stratum is the largest
   number of negative dependencies on a path to it, so that rules without Not and aggregates are all in stratum 0. *)

let node_word (t : Query.term) =
  match t with
  | Query.Val (Value.Int n | Date n | Money n | Link n) -> n
  | Val (Bool b) -> if b then 1 else 0
  | Thing c -> c
  | Val (Text _ | Float _) | Var _ -> -1

let node (q : Query.pattern) = (if q.p < 0 then -1 else q.p), node_word q.v

let node_match (p, w) (p', w') = (p < 0 || p' < 0 || p = p') && (w < 0 || w' < 0 || w = w')

let[@inline never] strata (v : Store.view) (rules : t array) =
  let n = Array.length rules in
  let sh = Array.map split rules in
  (* a head whose property is a variable may give any fact: it matches every head, and they are one stratum *)
  let head_node i = match sh.(i).pos.head with Give h -> Some (if sh.(i).agg <> None || h.p < 0 then (h.p, -1) else node h) | Never -> None in
  let heads = Array.init n head_node in
  (* edges i -> j, negative or not *)
  let adj = Array.make n [] in
  let edge i j neg = adj.(i) <- (j, neg) :: adj.(i) in
  for i = 0 to n - 1 do
    match heads.(i) with
    | None -> ()
    | Some hi ->
      for j = 0 to n - 1 do
        match heads.(j) with
        | None -> ()
        | Some hj ->
          let agg = sh.(j).agg <> None in
          let pos = List.exists (fun q -> node_match hi (node q)) sh.(j).pos.where in
          let neg = Array.exists (Array.exists (fun q -> node_match hi (node q))) sh.(j).nots in
          if neg || (pos && agg) then edge i j true else if pos then edge i j false;
          if i <> j && node_match hi hj then edge i j false
      done
  done;
  (* Tarjan's strong components *)
  let index = Array.make n (-1) and low = Array.make n 0 and on = Array.make n false and comp = Array.make n (-1) in
  let stack = ref [] and next = ref 0 and ncomp = ref 0 in
  let rec visit i =
    index.(i) <- !next;
    low.(i) <- !next;
    incr next;
    stack := i :: !stack;
    on.(i) <- true;
    List.iter
      (fun (j, _) ->
        if index.(j) < 0 then (visit j; low.(i) <- min low.(i) low.(j)) else if on.(j) then low.(i) <- min low.(i) index.(j))
      adj.(i);
    if low.(i) = index.(i) then begin
      let rec pop () =
        match !stack with
        | j :: rest -> stack := rest; on.(j) <- false; comp.(j) <- !ncomp; if j <> i then pop ()
        | [] -> ()
      in
      pop ();
      incr ncomp
    end
  in
  for i = 0 to n - 1 do if heads.(i) <> None && index.(i) < 0 then visit i done;
  (* a negative edge inside a component: the cycle named, from the rule that reads under Not back to it *)
  let cycle = ref None in
  (* a rule that reads its own head under Not first: the shortest cycle *)
  for i = 0 to n - 1 do
    List.iter (fun (j, neg) -> if neg && !cycle = None && i = j then cycle := Some (i, j)) adj.(i)
  done;
  for i = 0 to n - 1 do
    List.iter (fun (j, neg) -> if neg && !cycle = None && comp.(i) = comp.(j) then cycle := Some (i, j)) adj.(i)
  done;
  match !cycle with
  | Some (i, j) ->
    (* a path j ->* i inside the component, by breadth *)
    let from = Array.make n (-1) in
    let q = Queue.create () in
    Queue.add j q;
    from.(j) <- j;
    while from.(i) < 0 && not (Queue.is_empty q) do
      let x = Queue.pop q in
      List.iter (fun (y, _) -> if comp.(y) = comp.(i) && from.(y) < 0 then (from.(y) <- x; Queue.add y q)) adj.(x)
    done;
    let rec path x acc = if x = j then j :: acc else path from.(x) (x :: acc) in
    let names = List.map (fun k -> rules.(k).name) (if i = j then [ j ] else path i []) in
    let pname = match heads.(i) with Some (p, _) when p >= 0 -> (match Schema.find v.schema p with Some d -> d.name | None -> string_of_int p) | _ -> "a property" in
    let what, word = if sh.(j).agg <> None && not (Array.exists (Array.exists (fun q -> node_match (Option.get heads.(i)) (node q))) sh.(j).nots) then "aggregate", agg_name (Option.get sh.(j).agg) else "absence", "not" in
    Error
      (Printf.sprintf "rule %s: %s depends on its own %s (%s -> %s %s)" rules.(j).name pname what (String.concat " -> " names) word
         rules.(j).name)
  | None ->
    (* the components in topological order: Tarjan numbers a component after every component it reaches *)
    let cs = Array.make !ncomp 0 in
    let members = Array.make !ncomp [] in
    Array.iteri (fun i c -> if c >= 0 then members.(c) <- i :: members.(c)) comp;
    for c = !ncomp - 1 downto 0 do
      List.iter
        (fun i -> List.iter (fun (j, neg) -> if comp.(j) <> c then cs.(comp.(j)) <- max cs.(comp.(j)) (cs.(c) + if neg then 1 else 0)) adj.(i))
        members.(c)
    done;
    Ok (Array.init n (fun i -> if comp.(i) < 0 then 0 else cs.(comp.(i))))
