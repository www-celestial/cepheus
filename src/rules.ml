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

   The canonical text, one line:
     vars N; where [E P V] [E P V] ...; range ?X LO HI; ...; give [E P V]     (or: give never)
   a term is ?k (a variable), #n (a thing), or a value: iN (int), fH (float, hexadecimal, exact), b0 / b1, t"..."
   (text, OCaml's escapes), dN (date, ms), mN (money, minor units), lN (link); a property is its id or ?k. *)

type head = Give of Query.pattern | Never

type t = { name : string; vars : int; where : Query.pattern list; ranges : (int * Value.t * Value.t) list; head : head }

(* the property of a pattern as the variable ?k, and back (-1: a constant property) *)
let prop_var k = -1 - k
let[@inline] pvar p = if p < 0 then -1 - p else -1

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
let prop_text p = if p < 0 then Printf.sprintf "?%d" (-1 - p) else string_of_int p
let pattern_text (q : Query.pattern) = Printf.sprintf "[%s %s %s]" (term_text q.e) (prop_text q.p) (term_text q.v)

let[@inline never] to_text r =
  let b = Buffer.create 64 in
  Printf.bprintf b "vars %d; where" r.vars;
  List.iter (fun q -> Printf.bprintf b " %s" (pattern_text q)) r.where;
  List.iter (fun (x, lo, hi) -> Printf.bprintf b "; range ?%d %s %s" x (value_text lo) (value_text hi)) r.ranges;
  (match r.head with Give q -> Printf.bprintf b "; give %s" (pattern_text q) | Never -> Buffer.add_string b "; give never");
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
    let p = if peek () = '?' then (incr i; prop_var (int ())) else int () in
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
    let ranges = ref [] and head = ref None in
    while !head = None do
      word ";";
      skip ();
      if !i + 5 <= n && String.sub text !i 5 = "range" then begin
        word "range";
        word "?";
        let x = int () in
        skip ();
        let lo = value () in
        skip ();
        let hi = value () in
        ranges := (x, lo, hi) :: !ranges
      end
      else begin
        word "give";
        skip ();
        if peek () = 'n' then (word "never"; head := Some Never) else head := Some (Give (pattern ()))
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
        match q.v, Schema.find v.schema q.p with
        | Query.Var x, Some d -> set x d.typ
        | Query.Var _, None -> raise (Bad (Printf.sprintf "no property %d" q.p))
        | _ -> ())
    r.where;
  ty

let[@inline never] check (v : Store.view) r =
  let bad fmt = Printf.ksprintf (fun s -> raise (Parse (Printf.sprintf "rule %s: %s" r.name s))) fmt in
  try
    if r.where = [] then bad "its body has no pattern";
    if r.vars < 0 || r.vars > 64 then bad "%d variables (at most 64)" r.vars;
    let seen = Array.make r.vars false in
    List.iter
      (fun (q : Query.pattern) ->
        List.iter (fun k -> if k < 0 || k >= r.vars then bad "variable ?%d out of range" k else seen.(k) <- true) (pattern_vars q);
        (match q.e with Query.Val _ -> bad "the thing of a pattern is a variable or a thing" | _ -> ());
        if q.p >= 0 && Schema.find v.schema q.p = None then bad "no property %d" q.p)
      r.where;
    Array.iteri (fun k s -> if not s then bad "variable ?%d appears in no pattern of the body" k) seen;
    (* a variable property is bound by a pattern whose property is a constant: no pattern scans every fact *)
    let bound_by_const k =
      List.exists (fun (q : Query.pattern) -> q.p >= 0 && (q.e = Query.Var k || q.v = Query.Var k)) r.where
    in
    List.iter
      (fun (q : Query.pattern) ->
        if q.p < 0 && not (bound_by_const (pvar q.p)) then
          bad "the property ?%d is bound by no pattern whose property is a constant" (pvar q.p))
      r.where;
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
      r.where;
    (match r.head with
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
       if q.p >= 0 && Schema.is_system q.p then bad "its head gives a cepheus/ property";
       (match q.e with
        | Query.Var k ->
          (* a variable without a type of its own is checked a thing at each fact derived *)
          if k < 0 || k >= r.vars then bad "variable ?%d out of range" k
          else (match sty.(k) with Some Value.Tlink | None -> () | Some _ -> bad "?%d is not a thing" k)
        | Thing t -> if t < Schema.first_thing then bad "its head's thing #%d is not an ordinary thing" t
        | Val _ -> bad "the thing of its head is a variable or a thing");
       match d with
       | None -> (match q.v with Query.Var k when k < 0 || k >= r.vars -> bad "variable ?%d out of range" k | _ -> ())
       | Some d -> (
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
