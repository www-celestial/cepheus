(* The rule language: Datalog over facts. A rule is a question's patterns (Query.pattern: thing, property, value, the
   property a constant) and ranges, and a head: one pattern, the fact the rule gives for each answer of its body, or
   [Never], a constraint (an answer refuses the group). Its variables are typed as a question's are; every variable of
   the head appears in the body (range restriction, or safety); the head names no new thing, so the least model is
   finite and its evaluation always ends (Abiteboul, Hull, Vianu 1995, ch. 12-13). A rule is a schema thing: its
   cepheus/name and its cepheus/rule, the canonical text below, written in a group like any fact, so the journal keeps
   every version of it.

   The canonical text, one line:
     vars N; where [E P V] [E P V] ...; range ?X LO HI; ...; give [E P V]     (or: give never)
   a term is ?k (a variable), #n (a thing), or a value: iN (int), fH (float, hexadecimal, exact), b0 / b1, t"..."
   (text, OCaml's escapes), dN (date, ms), mN (money, minor units), lN (link). *)

type head = Give of Query.pattern | Never

type t = { name : string; vars : int; where : Query.pattern list; ranges : (int * Value.t * Value.t) list; head : head }

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
let pattern_text (q : Query.pattern) = Printf.sprintf "[%s %d %s]" (term_text q.e) q.p (term_text q.v)

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
    | 't' -> (
      (* an OCaml string literal: read with Scanf from here *)
      match Scanf.sscanf (String.sub text !i (n - !i)) "%S%n" (fun s k -> s, k) with
      | s, k -> i := !i + k; Text s
      | exception _ -> fail ())
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
    let p = int () in
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

let pattern_vars (q : Query.pattern) = List.filter_map (function Query.Var k -> Some k | _ -> None) [ q.e; q.v ]

(* the variables' types, by the questions' rule (a variable has one type, from the patterns it appears in) *)
let types (v : Store.view) r =
  Query.types v { Query.vars = r.vars; where = r.where; ranges = r.ranges }

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
        if Schema.find v.schema q.p = None then bad "no property %d" q.p)
      r.where;
    Array.iteri (fun k s -> if not s then bad "variable ?%d appears in no pattern of the body" k) seen;
    let ty = match types v r with t -> t | exception Query.Bad m -> bad "%s" m in
    List.iter
      (fun (x, lo, hi) ->
        if x < 0 || x >= r.vars || not (Value.inline ty.(x)) then bad "a range needs an int, date or money variable";
        if not (Value.has_type ty.(x) lo && Value.has_type ty.(x) hi) then bad "the bounds of ?%d are not of its type" x)
      r.ranges;
    List.iter
      (fun (q : Query.pattern) ->
        match q.v, Schema.find v.schema q.p with
        | Val x, Some d when not (Value.has_type d.typ x) -> bad "%s is not a %s" (Value.to_string x) (Value.typ_name d.typ)
        | _ -> ())
      r.where;
    (match r.head with
     | Never -> ()
     | Give q ->
       let d = match Schema.find v.schema q.p with Some d -> d | None -> bad "no property %d in its head" q.p in
       if Schema.is_system q.p then bad "its head gives a cepheus/ property";
       (match q.e with
        | Query.Var k -> if k < 0 || k >= r.vars then bad "variable ?%d out of range" k else if ty.(k) <> Value.Tlink then bad "?%d is not a thing" k
        | Thing t -> if t < Schema.first_thing then bad "its head's thing #%d is not an ordinary thing" t
        | Val _ -> bad "the thing of its head is a variable or a thing");
       (match q.v with
        | Query.Var k ->
          if k < 0 || k >= r.vars then bad "variable ?%d out of range" k
          else if ty.(k) <> d.typ then bad "?%d is a %s, %s takes a %s" k (Value.typ_name ty.(k)) d.name (Value.typ_name d.typ)
        | Thing t -> if d.typ <> Value.Tlink then bad "%s takes a %s, not a thing" d.name (Value.typ_name d.typ) else ignore t
        | Val x -> if not (Value.has_type d.typ x) then bad "%s is not a %s" (Value.to_string x) (Value.typ_name d.typ)));
    Ok ()
  with Parse m -> Error m
