(* The rules: named cases, then the guarantees by property tests against an evaluation from scratch.
   G17: after every group of a random sequence (random rules defined, changed and removed; random additions and
   retractions, of asserted facts, of facts the rules derive, of facts both asserted and derived), the view holds
   exactly the least model of its asserted facts under its rules, and exactly those facts are asserted; the rules are
   evaluated naively from scratch by the checker's own question evaluator (Check.naive), not by the engine. The
   sequences run on forks and on views whose facts were merged into runs between the groups (flags in the runs, flags
   changed over a run). G18: a group whose state would give an instance of a constraint is refused, and only such a
   group. G20: every derived fact's proof is checked node by node against the view and the rules. *)

open Cepheus
module C = Check

let section name = Printf.printf "- %s\n%!" name
let ok = function Ok x -> x | Error e -> failwith (message e)

module F = C.F
let least = C.least and violated = C.violated
let user_facts = C.user_facts and asserted_facts = C.asserted_facts and rules_of = C.rules_of

(* ---- G20: a proof checked node by node ---- *)

let rec check_proof (v : view) (rules : rule list) (pr : proof) =
  match pr with
  | Given { e; p; v = x } ->
    (match Store.word v x with Some w -> Store.state v e p w = 1 | None -> false)
  | By { rule; e; p; v = x; from } -> (
    match List.find_opt (fun (r : rule) -> r.name = rule) rules with
    | None -> false
    | Some r -> (
      match r.head with
      | Never -> false
      | Give h ->
        List.length from = List.length r.where
        && List.for_all (check_proof v rules) from
        &&
        (* the body atoms bound to the children's facts, in order, consistently; then the head is the node's fact *)
        let env = Array.make (max 1 r.vars) None in
        let unify t (y : value) =
          match t with
          | Var k -> (match env.(k) with None -> env.(k) <- Some y; true | Some z -> Value.equal y z)
          | Thing t -> Value.equal y (Link t)
          | Val z -> Value.equal y z
        in
        let leaf = function Given g -> g.e, g.p, g.v | By b -> b.e, b.p, b.v in
        (* a variable property is bound to the fact's *)
        let prop q fp = if q >= 0 then fp = q else unify (Var (-1 - q)) (Link fp) in
        List.for_all2
          (fun (a : pattern) f ->
            let fe, fp, fv = leaf f in
            prop a.p fp && unify a.e (Link fe) && unify a.v fv)
          r.where from
        && List.for_all
             (fun (k, lo, hi) ->
               match env.(k), lo, hi with
               | Some (Int y | Date y | Money y), (Int a | Date a | Money a), (Int b | Date b | Money b) -> y >= a && y <= b
               | _ -> false)
             r.ranges
        && prop h.p p && unify h.e (Link e) && unify h.v x
        && Store.state v e p (Option.get (Store.word v x)) = 2))

let check_proofs ?(where = "") (v : view) =
  let rules = rules_of v in
  F.iter
    (fun (e, p, x) ->
      match Store.word v x with
      | Some w when Store.state v e p w = 2 -> (
        match why v e p x with
        | Some pr -> C.check (check_proof v rules pr) "%s: G20: the proof of #%d %d %s checks" where e p (Value.to_string x)
        | None -> C.fail "%s: G20: a derived fact #%d %d %s has no proof" where e p (Value.to_string x)
        | exception Failure m -> C.fail "%s: G20: %s" where m)
      | _ -> ())
    (user_facts v)

(* ---- named cases ---- *)

let schema db =
  match declare db [ prop ~many:true "type" Tlink; prop ~many:true "parent" Tlink; prop ~many:true "member" Tlink;
                     prop ~many:true "memberOf" Tlink; prop "status" Ttext; prop ~many:true "label" Ttext ] with
  | Ok [ ty; parent; member; member_of; status; label ] -> ty, parent, member, member_of, status, label
  | Ok _ -> assert false
  | Error e -> failwith (message e)

let () =
  section "rules: is-a, derived at the write, retracted with its premise, Why";
  let db = fork empty in
  let ty, parent, _, _, _, _ = schema db in
  let r = ok (write db [ Add (-1, ty, Link (-1)); Add (-2, ty, Link (-2)); Add (-3, ty, Link (-3)) ]) in
  let invoice = thing r (-1) and document = thing r (-2) and thing_ = thing r (-3) in
  ignore (ok (write db [ Add (invoice, parent, Link document); Add (document, parent, Link thing_) ]));
  let is_a =
    { name = "is-a"; vars = 3; where = [ { e = Var 0; p = ty; v = Var 1 }; { e = Var 1; p = parent; v = Var 2 } ]; ranges = [];
      head = Give { e = Var 0; p = ty; v = Var 2 } }
  in
  ignore (ok (define db [ is_a ]));
  let r = ok (write db [ Add (-1, ty, Link invoice) ]) in
  let x = thing r (-1) in
  let types v = List.sort compare (values v x ty) in
  C.check (types (view db) = [ Link invoice; Link document; Link thing_ ]) "x is an invoice, a document and a thing";
  (match why (view db) x ty (Link thing_) with
   | Some (By { rule = "is-a"; from = [ By { rule = "is-a"; from = [ Given _; Given _ ]; _ }; Given _ ]; _ }) ->
     C.check true "Why: is-a twice, from the given facts"
   | _ -> C.fail "Why: the proof of x is a thing");
  C.check (why (view db) x ty (Link x) = None) "Why: not a fact, no proof";
  (* retracting a fact only derived is refused, naming the rule *)
  (match write db [ Retract (x, ty, Link document) ] with
   | Error (Invalid m) -> C.check (String.length m > 0 && String.sub m 0 1 = "[") "the refusal names the fact: %s" m
   | _ -> C.fail "retracting a fact only derived must be refused");
  (* asserted too, then retracted: it stays, derived *)
  ignore (ok (write db [ Add (x, ty, Link document) ]));
  let st v = Store.state v x ty document in
  C.check (st (view db) = 1) "x is a document, asserted now";
  ignore (ok (write db [ Retract (x, ty, Link document) ]));
  C.check (st (view db) = 2) "x is a document, derived again";
  ignore (ok (write db [ Retract (x, ty, Link invoice) ]));
  C.check (types (view db) = []) "the premise retracted: x is nothing";
  ignore (ok (undefine db [ "is-a" ]));
  let r = ok (write db [ Add (-1, ty, Link invoice) ]) in
  C.check (values (view db) (thing r (-1)) ty = [ Link invoice ]) "the rule removed: nothing derived";
  ignore (ok (define db [ is_a ]));
  C.check (List.length (values (view db) (thing r (-1)) ty) = 3) "the rule defined again: derived over the database";
  check_proofs (view db);
  (* a rule's text reads back as it was written, for a text constant holding every byte; a text that is not
     exactly what to_text writes is refused *)
  let all = String.init 256 Char.chr in
  let named = { is_a with where = [ { e = Var 0; p = ty; v = Var 1 }; { e = Var 1; p = parent; v = Val (Text all) } ]; vars = 2;
                head = Give { e = Var 0; p = ty; v = Val (Text ("\"\\" ^ all)) } } in
  C.check (Rules.of_text named.name (Rules.to_text named) = Ok named) "a text of every byte: read back as written";
  List.iter
    (fun bad -> C.check (Result.is_error (Rules.of_text "t" bad)) "refused: %S" bad)
    [ "vars 2; where [?0 1 t\"a]; give never"; "vars 2; where [?0 1 t\"\\q\"]; give never";
      "vars 2; where [?0 1 t\"\\256\"]; give never"; "vars 2; where [?0 1 t\"\\06\"]; give never";
      "vars 2; where [?0 1 t\"\\x41\"]; give never" ]

let () =
  section "rules: inverse properties support each other, and fall together (counting would keep them)";
  let db = fork empty in
  let _, _, member, member_of, _, _ = schema db in
  let inv1 = { name = "inv1"; vars = 2; where = [ { e = Var 0; p = member; v = Var 1 } ]; ranges = []; head = Give { e = Var 1; p = member_of; v = Var 0 } } in
  let inv2 = { name = "inv2"; vars = 2; where = [ { e = Var 0; p = member_of; v = Var 1 } ]; ranges = []; head = Give { e = Var 1; p = member; v = Var 0 } } in
  ignore (ok (define db [ inv1; inv2 ]));
  let r = ok (write db [ Add (-1, member, Link (-2)); Add (-2, member, Link (-3)) ]) in
  let a = thing r (-1) and b = thing r (-2) in
  C.check (values (view db) b member_of = [ Link a ]) "b is a member of a";
  ignore (ok (write db [ Retract (a, member, Link b) ]));
  C.check (values (view db) b member_of = [] && values (view db) a member = []) "both directions gone together"

let () =
  section "rules: a constraint refuses the group that breaks it, whole";
  let db = fork empty in
  let ty, _, _, _, status, _ = schema db in
  let r = ok (write db [ Add (-1, ty, Link (-1)); Add (-2, ty, Link (-2)) ]) in
  let invoice = thing r (-1) and client = thing r (-2) in
  let never = { name = "invoice-is-not-client"; vars = 1; where = [ { e = Var 0; p = ty; v = Thing invoice }; { e = Var 0; p = ty; v = Thing client } ]; ranges = []; head = Never } in
  ignore (ok (define db [ never ]));
  let r = ok (write db [ Add (-1, ty, Link invoice); Add (-1, status, Text "unpaid") ]) in
  let x = thing r (-1) in
  (match write db [ Add (x, status, Text "paid"); Add (x, ty, Link client) ] with
   | Error (Invalid m) -> C.check (String.length m > 10 && String.sub m 0 10 = "constraint") "refused: %s" m
   | _ -> C.fail "the constraint must refuse the group");
  C.check (values (view db) x status = [ Text "unpaid" ]) "all or nothing: the status is unchanged"

let () =
  section "rules: the budget refuses a group that derives too much, naming the rule";
  let db = fork empty in
  let _, _, member, member_of, _, _ = schema db in
  let all = { name = "everyone"; vars = 3; where = [ { e = Var 0; p = member; v = Var 1 }; { e = Var 2; p = member; v = Var 1 } ]; ranges = []; head = Give { e = Var 0; p = member_of; v = Var 2 } } in
  ignore (ok (define db [ all ]));
  let b0 = !(fst rule_budget) and b1 = !(snd rule_budget) in
  fst rule_budget := 50;
  snd rule_budget := 1;
  let ops = List.init 20 (fun k -> Add (-(k + 2), member, Link (-1))) in
  (match write db ops with
   | Error (Invalid m) -> C.check (String.length m > 14 && String.sub m 0 14 = "rule everyone ") "refused: %s" m
   | _ -> C.fail "20 members of one thing derive 400 facts: over the budget");
  fst rule_budget := b0;
  snd rule_budget := b1;
  C.check (match write db ops with Ok _ -> true | Error _ -> false) "within the default budget"

let () =
  section "rules: a derived second value of a one-valued property is refused";
  let db = fork empty in
  let ty, _, _, _, status, _ = schema db in
  let r = ok (write db [ Add (-1, ty, Link (-1)) ]) in
  let late = thing r (-1) in
  let rl = { name = "late"; vars = 1; where = [ { e = Var 0; p = ty; v = Thing late } ]; ranges = []; head = Give { e = Var 0; p = status; v = Val (Text "late") } } in
  ignore (ok (define db [ rl ]));
  let r = ok (write db [ Add (-1, ty, Link late) ]) in
  C.check (values (view db) (thing r (-1)) status = [ Text "late" ]) "a text a head gives";
  (match write db [ Add (-1, status, Text "paid"); Add (-1, ty, Link late) ] with
   | Error (Invalid _) -> C.check true "two values of status: refused"
   | Ok _ -> C.fail "a derived second value of a one-valued property must be refused"
   | Error e -> C.fail "%s" (message e))

let () =
  section "rules: refused definitions";
  let db = fork empty in
  let ty, _, _, _, status, _ = schema db in
  let bad name r = match define db [ r ] with Error (Invalid _) -> C.check true "%s: refused" name | _ -> C.fail "%s must be refused" name in
  bad "a head variable not in the body"
    { name = "unsafe"; vars = 2; where = [ { e = Var 0; p = ty; v = Var 0 } ]; ranges = []; head = Give { e = Var 0; p = ty; v = Var 1 } };
  bad "a variable of two types"
    { name = "typed"; vars = 2; where = [ { e = Var 0; p = ty; v = Var 1 }; { e = Var 0; p = status; v = Var 1 } ]; ranges = []; head = Give { e = Var 0; p = ty; v = Var 1 } };
  bad "a head of the wrong type"
    { name = "wrong"; vars = 2; where = [ { e = Var 0; p = ty; v = Var 1 } ]; ranges = []; head = Give { e = Var 0; p = status; v = Var 1 } };
  bad "a head on a system property"
    { name = "system"; vars = 2; where = [ { e = Var 0; p = ty; v = Var 1 } ]; ranges = []; head = Give { e = Var 0; p = Schema.p_name; v = Val (Text "x") } };
  (match define db [ { name = "type"; vars = 2; where = [ { e = Var 0; p = ty; v = Var 1 } ]; ranges = []; head = Give { e = Var 0; p = ty; v = Var 1 } } ] with
   | Error _ -> C.check true "a rule named like a property: refused"
   | Ok _ -> C.fail "a rule named like a property must be refused")

let () =
  section "rules: a transitive property by the closure module (prp-trp), then the linear pair";
  let db = fork empty in
  let ty, parent, member, member_of, _, _ = schema db in
  ignore ty;
  let x = Var 0 and y = Var 1 and z = Var 2 in
  let trp = { name = "parent-trp"; vars = 3; where = [ { e = x; p = parent; v = y }; { e = y; p = parent; v = z } ]; ranges = []; head = Give { e = x; p = parent; v = z } } in
  ignore (ok (define db [ trp ]));
  let r = ok (write db (List.init 5 (fun i -> Add (-(i + 1), member, Link (-(i + 1)))))) in
  let n = Array.init 5 (fun i -> thing r (-(i + 1))) in
  let ups v k = List.sort compare (values v n.(k) parent) in
  ignore (ok (write db [ Add (n.(0), parent, Link n.(1)); Add (n.(1), parent, Link n.(2)) ]));
  C.check (ups (view db) 0 = [ Link n.(1); Link n.(2) ]) "a chain of two: 0 has 1 and 2 (the first group: from scratch)";
  ignore (ok (write db [ Add (n.(2), parent, Link n.(3)) ]));
  C.check (ups (view db) 0 = [ Link n.(1); Link n.(2); Link n.(3) ]) "an edge added on top: 0 reaches 3";
  C.check (ups (view db) 1 = [ Link n.(2); Link n.(3) ]) "1 reaches 2 and 3";
  ignore (ok (write db [ Add (n.(4), parent, Link n.(0)) ]));
  C.check (ups (view db) 4 = [ Link n.(0); Link n.(1); Link n.(2); Link n.(3) ]) "a source added below: 4 reaches all";
  ignore (ok (write db [ Retract (n.(1), parent, Link n.(2)) ]));
  C.check (ups (view db) 0 = [ Link n.(1) ] && ups (view db) 4 = [ Link n.(0); Link n.(1) ]) "the middle edge retracted: B/F";
  check_proofs (view db);
  ignore (ok (write db [ Add (n.(3), parent, Link n.(0)) ]));
  C.check (ups (view db) 2 = [ Link n.(0); Link n.(1); Link n.(3) ]) "2 reaches 3, then 0 and 1";
  ignore (ok (write db [ Add (n.(1), parent, Link n.(2)) ]));
  C.check (ups (view db) 3 = [ Link n.(0); Link n.(1); Link n.(2); Link n.(3) ]) "a cycle: 3 reaches itself";
  C.check (F.equal (user_facts (view db)) (least (rules_of (view db)) (asserted_facts (view db)))) "the least model";
  (* the linear pair over member *)
  let base = { name = "within-base"; vars = 2; where = [ { e = x; p = member; v = y } ]; ranges = []; head = Give { e = x; p = member_of; v = y } } in
  let step = { name = "within"; vars = 3; where = [ { e = x; p = member; v = y }; { e = y; p = member_of; v = z } ]; ranges = []; head = Give { e = x; p = member_of; v = z } } in
  ignore (ok (define db [ base; step ]));
  C.check (F.equal (user_facts (view db)) (least (rules_of (view db)) (asserted_facts (view db)))) "the linear pair defined over the database: the least model";
  ignore (ok (write db [ Add (n.(0), member, Link n.(1)); Add (n.(1), member, Link n.(2)); Add (n.(2), member_of, Link n.(4)) ]));
  C.check (F.equal (user_facts (view db)) (least (rules_of (view db)) (asserted_facts (view db)))) "edges and a fact of the closure added: the least model";
  check_proofs (view db)

(* ---- G17, G18, G20: random sequences against the least model from scratch ---- *)

let debug = match Sys.getenv_opt "RULES_SEED" with Some s -> int_of_string s | None -> 0

let show_op = function
  | Add (e, p, x) -> Printf.sprintf "+[%d %d %s]" e p (Value.to_string x)
  | Retract (e, p, x) -> Printf.sprintf "-[%d %d %s]" e p (Value.to_string x)
  | Expect _ -> "expect"

let random_sequences ~seeds ~groups ~merges =
  for seed = (if debug > 0 then debug else 1) to (if debug > 0 then debug else seeds) do
    let r = Rng.make seed in
    let db = ref (fork empty) in
    let a, b, c, ty, n, tag, meta =
      match declare !db [ prop ~many:true "a" Tlink; prop ~many:true "b" Tlink; prop ~many:true "c" Tlink;
                          prop ~many:true "type" Tlink; prop ~many:true "n" Tint; prop ~many:true "tag" Ttext;
                          prop ~many:true "meta" Tlink ] with
      | Ok [ a; b; c; ty; n; tag; meta ] -> a, b, c, ty, n, tag, meta
      | _ -> assert false
    in
    let ptyp p = match Schema.find (view !db).schema p with Some d when p >= Schema.first_prop -> Some d.typ | _ -> None in
    let things = Array.of_list (List.map (fun k -> thing (ok (write !db [ Add (-1, n, Int k) ])) (-1)) (List.init 7 Fun.id)) in
    let some_thing () = things.(Rng.int r (Array.length things)) in
    let links = [| a; b; c; ty |] in
    let props = [| a; b; c; ty; n; tag |] in
    let texts = [| "x"; "y"; "derived" |] in
    (* a random safe, typed rule: link variables 0-3, an int variable 4, a text variable 5, renumbered densely *)
    (* the shapes the engine runs apart: a transitive closure (prp-trp), the linear pair over edges, and the W3C's
       form with a variable property bound by a relation (meta) the engine specialises on *)
    let closure_rule k =
      let x = Var 0 and y = Var 1 and z = Var 2 in
      let t = links.(Rng.int r 4) and e = links.(Rng.int r 4) in
      let name = Printf.sprintf "r%d" k in
      match Rng.int r 3 with
      | 0 -> Some { name; vars = 3; where = [ { e = x; p = t; v = y }; { e = y; p = t; v = z } ]; ranges = []; head = Give { e = x; p = t; v = z } }
      | 1 when e <> t -> Some { name; vars = 2; where = [ { e = x; p = e; v = y } ]; ranges = []; head = Give { e = x; p = t; v = y } }
      | _ when e <> t -> Some { name; vars = 3; where = [ { e = y; p = t; v = z }; { e = x; p = e; v = y } ]; ranges = []; head = Give { e = x; p = t; v = z } }
      | _ -> None
    in
    let var_prop_rule k =
      (* [k meta p] binds p; [x p y] reads it; the head gives p, or a constant property, from x and y *)
      let pv = prop_var 3 and kt = if Rng.bool r then Thing (some_thing ()) else Var 4 in
      let x = Var 0 and y = Var 1 in
      let body = [ { e = kt; p = meta; v = Var 3 }; { e = x; p = pv; v = (if Rng.bool r then y else Var 2) } ] in
      let body = if Rng.int r 3 = 0 then List.rev body else body in
      let body = if Rng.int r 3 = 0 then body @ [ { e = x; p = links.(Rng.int r 4); v = Var 5 } ] else body in
      let used = Array.make 6 false in
      List.iter (fun (q : pattern) -> List.iter (function Var v -> used.(v) <- true | _ -> ()) [ q.e; q.v ]; if q.p < 0 then used.(-1 - q.p) <- true) body;
      let value_var = if used.(1) then Var 1 else Var 2 in
      let head =
        match Rng.int r 4 with
        | 0 -> Give { e = x; p = pv; v = value_var }
        | 1 -> Give { e = x; p = links.(Rng.int r 4); v = value_var }
        | 2 when used.(1) -> Give { e = y; p = pv; v = x }
        | _ -> Give { e = x; p = ty; v = (if used.(5) then Var 5 else Thing (some_thing ())) }
      in
      let map = Array.make 6 (-1) and next = ref 0 in
      Array.iteri (fun v u -> if u then (map.(v) <- !next; incr next)) used;
      let t = function Var v -> Var map.(v) | t -> t in
      let pp q = if q < 0 then prop_var map.(-1 - q) else q in
      let pat (q : pattern) = { e = t q.e; p = pp q.p; v = t q.v } in
      Some { name = Printf.sprintf "r%d" k; vars = !next; where = List.map pat body; ranges = [];
             head = (match head with Never -> Never | Give h -> Give (pat h)) }
    in
    let gen_rule k =
      match Rng.int r 8 with
      | 0 -> closure_rule k
      | 1 -> var_prop_rule k
      | _ ->
      let atom () =
        match Rng.int r 8 with
        | 0 -> { e = Var (Rng.int r 3); p = n; v = (if Rng.bool r then Var 4 else Val (Int (Rng.int r 3))) }
        | 1 -> { e = Var (Rng.int r 3); p = tag; v = (if Rng.bool r then Var 5 else Val (Text texts.(Rng.int r 3))) }
        | _ ->
          let p = links.(Rng.int r 4) in
          let e = if Rng.int r 6 = 0 then Thing (some_thing ()) else Var (Rng.int r 3) in
          let v = if Rng.int r 5 = 0 then Thing (some_thing ()) else Var (Rng.int r 3) in
          { e; p; v }
      in
      let body = List.init (1 + Rng.int r 3) (fun _ -> atom ()) in
      let used = Array.make 6 false in
      List.iter (fun (q : pattern) -> List.iter (function Var x -> used.(x) <- true | _ -> ()) [ q.e; q.v ]) body;
      (* an atom with no variable is allowed; a rule needs a link variable for its head *)
      let link_vars = List.filter (fun x -> used.(x)) [ 0; 1; 2; 3 ] in
      if link_vars = [] then None
      else begin
        let pick l = List.nth l (Rng.int r (List.length l)) in
        let head =
          if Rng.int r 10 = 0 then Never
          else
            match Rng.int r 6 with
            | 0 when used.(4) -> Give { e = Var (pick link_vars); p = n; v = Var 4 }
            | 1 when used.(5) -> Give { e = Var (pick link_vars); p = tag; v = Var 5 }
            | 2 -> Give { e = Var (pick link_vars); p = tag; v = Val (Text "derived") }
            | _ -> Give { e = Var (pick link_vars); p = links.(Rng.int r 4); v = (if Rng.int r 4 = 0 then Thing (some_thing ()) else Var (pick link_vars)) }
        in
        let ranges = if used.(4) && Rng.int r 4 = 0 then [ (4, Int 0, Int 1) ] else [] in
        (* dense numbering *)
        let map = Array.make 6 (-1) and next = ref 0 in
        Array.iteri (fun x u -> if u then (map.(x) <- !next; incr next)) used;
        let t = function Var x -> Var map.(x) | t -> t in
        let pat (q : pattern) = { q with e = t q.e; v = t q.v } in
        Some { name = Printf.sprintf "r%d" k; vars = !next; where = List.map pat body;
               ranges = List.map (fun (x, lo, hi) -> (map.(x), lo, hi)) ranges;
               head = (match head with Never -> Never | Give h -> Give (pat h)) }
      end
    in
    let random_fact () =
      match Rng.int r 7 with
      | 0 -> (some_thing (), n, Int (Rng.int r 3))
      | 1 -> (some_thing (), tag, Text texts.(Rng.int r 3))
      | 2 -> (some_thing (), meta, Link props.(Rng.int r 6))
      | _ -> (some_thing (), links.(Rng.int r 4), Link (some_thing ()))
    in
    for g = 1 to groups do
      let v = view !db in
      let rules = rules_of v in
      let m_old = user_facts v and e_old = asserted_facts v in
      (match Rng.int r 12 with
       | 0 | 1 -> (
         (* a rule defined or changed *)
         match gen_rule (Rng.int r 5) with
         | None -> ()
         | Some rl -> (
           let rules' = rl :: List.filter (fun (x : rule) -> x.name <> rl.name) rules in
           let bad = ref false in
           let m' = least ~ptyp ~bad rules' e_old in
           if seed = debug then Printf.printf "g%d define %s: %s\n" g rl.name (Rules.to_text rl);
           match define !db [ rl ] with
           | Ok _ ->
             C.check (not (violated rules' m' || !bad)) "seed %d group %d: a rule accepted over a state that breaks a constraint or derives a fact of the wrong type" seed g
           | Error (Invalid msg) ->
             (* refused: a constraint broken, or the budget; never silently *)
             C.check (violated rules' m' || !bad || String.length msg > 0) "seed %d group %d: rule refused: %s" seed g msg
           | Error e -> C.fail "seed %d: %s" seed (message e)))
       | 2 -> (
         match rules with
         | [] -> ()
         | _ ->
           let rl = List.nth rules (Rng.int r (List.length rules)) in
           if seed = debug then Printf.printf "g%d undefine %s\n" g rl.name;
           ignore (ok (undefine !db [ rl.name ])))
       | _ -> (
         (* a group of additions and retractions, simulated on (facts, asserted) as Resolve applies them *)
         let ops =
           List.init (1 + Rng.int r 4) (fun _ ->
               let e, p, x = if Rng.int r 3 = 0 && not (F.is_empty m_old) then (let l = F.elements m_old in List.nth l (Rng.int r (List.length l))) else random_fact () in
               if Rng.int r 3 = 0 then Retract (e, p, x) else Add (e, p, x))
         in
         let refused = ref false and m = ref m_old and ea = ref e_old in
         List.iter
           (function
             | Add (e, p, x) -> m := F.add (e, p, x) !m; ea := F.add (e, p, x) !ea
             | Retract (e, p, x) ->
               if F.mem (e, p, x) !ea then (m := F.remove (e, p, x) !m; ea := F.remove (e, p, x) !ea)
               else if F.mem (e, p, x) !m then refused := true
             | Expect _ -> ())
           ops;
         let bad = ref false in
         let m' = least ~ptyp ~bad rules !ea in
         let want_refused = !refused || violated rules m' || !bad in
         if seed = debug then Printf.printf "g%d write %s\n" g (String.concat " " (List.map show_op ops));
         match write !db ops with
         | Ok _ -> C.check (not want_refused) "seed %d group %d: accepted, expected refused" seed g
         | Error (Invalid msg) -> C.check want_refused "seed %d group %d: refused, expected accepted: %s" seed g msg
         | Error e -> C.fail "seed %d: %s" seed (message e)));
      (* G17: the view is the least model of its asserted facts under its rules *)
      let v = view !db in
      let rules = rules_of v in
      let got = user_facts v and asserted = asserted_facts v in
      let want = least ~ptyp rules asserted in
      C.check (F.equal got want) "seed %d group %d: G17, the view is the least model: %s" seed g (if F.equal got want then "" else C.show_diff got want);
      C.check (not (violated rules got)) "seed %d group %d: G18, no constraint broken" seed g;
      if g mod 5 = 0 then check_proofs ~where:(Printf.sprintf "seed %d group %d" seed g) v;
      (* the facts into runs now and then: the next groups write over a run (flags in it, flags changed over it) *)
      if seed = debug then
        Printf.printf "   view: %s\n%!" (String.concat " " (List.map (fun (e, p, x) -> Printf.sprintf "%d.%d.%s%s" e p (Value.to_string x) (if F.mem (e, p, x) asserted then "" else "*")) (F.elements got)));
      if merges && Rng.int r 4 = 0 then db := fork (if Rng.bool r then C.compact v else C.push v)
    done
  done

let () =
  (* the runs' pages of the merged views in a small cache, as the other tests have them *)
  Pages.set_capacity (32 lsl 20);
  section "G17, G18, G20: random rules and writes on forks, against the least model from scratch";
  let seeds = match Sys.getenv_opt "RULES_SEEDS" with Some s -> int_of_string s | None -> 60 in
  random_sequences ~seeds ~groups:60 ~merges:false;
  section "G17, G18, G20: the same with the facts merged into runs between groups";
  random_sequences ~seeds ~groups:60 ~merges:true

let () =
  Printf.printf "(groups reasoned unfolded %d, as written %d, again as written %d; closures from scratch %d)\n" !Reason.spec_groups
    !Reason.gen_groups !Reason.respecs !Reason.batches;
  C.finish "reasoning"
