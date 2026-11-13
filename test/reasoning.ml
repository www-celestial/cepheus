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
      let d = C.decode r in
      match d.dhead, d.dagg with
      | Never, _ -> false
      | Give _, Some _ ->
        (* an aggregate's fact: its value is the aggregate of its group's answers over the view, and its children are
           the facts of those answers, each proved *)
        let facts = user_facts v in
        let rows = C.answers d facts in
        let want = List.filter (fun (e', p', _) -> e' = e && p' = p) (C.agg_facts d rows) in
        let leaf = function Given g -> g.e, g.p, g.v | By b -> b.e, b.p, b.v in
        let kids = List.sort_uniq compare (List.map leaf from) in
        let need = ref [] in
        (match d.dhead with
         | Give h ->
           let term (row : value option array) = function Var k -> row.(k) | Thing t -> Some (Link t) | Val z -> Some z in
           List.iter
             (fun row ->
               if term row h.e = Some (Link e) then
                 List.iter
                   (fun (a : pattern) ->
                     match term row a.e, (if a.p >= 0 then a.p else match row.(-1 - a.p) with Some (Link q) -> q | _ -> -1), term row a.v with
                     | Some (Link fe), fp, Some fv -> need := (fe, fp, fv) :: !need
                     | _ -> ())
                   d.pos)
             rows
         | Never -> ());
        (match want with [ (_, _, y) ] -> Value.equal y x | _ -> false)
        && kids = List.sort_uniq compare !need
        && List.for_all (check_proof v rules) from
        && Store.state v e p (Option.get (Store.word v x)) = 2
      | Give h, None ->
        let r = { r with where = d.pos; head = d.dhead } in
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
             (* the ranges of the Nots' own variables are the Nots' *)
             (let outer = C.outer_vars d in List.filter (fun (k, _, _) -> outer.(k)) r.ranges)
        && prop h.p p && unify h.e (Link e) && unify h.v x
        (* its Nots hold over the view *)
        && C.nots_hold d (user_facts v) env
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

let () =
  section "rules: a closure past the budget is refused, whole and early, on every path of the module";
  let b0 = !(fst rule_budget) and b1 = !(snd rule_budget) in
  fst rule_budget := 1000;
  snd rule_budget := 1;
  let x = Var 0 and y = Var 1 and z = Var 2 in
  let refused name f =
    match f () with
    | Error (Invalid m) -> C.check (String.length m > 5 && String.sub m 0 5 = "rule ") "%s: refused (%s)" name m
    | Ok _ -> C.fail "%s: must be refused by the budget" name
    | Error e -> C.fail "%s: %s" name (message e)
  in
  List.iter
    (fun (form, older) ->
      let db = fork empty in
      let ty, parent, member, _, _, _ = schema db in
      ignore ty;
      let rules =
        if form = "trp" then [ { name = "trp"; vars = 3; where = [ { e = x; p = parent; v = y }; { e = y; p = parent; v = z } ]; ranges = []; head = Give { e = x; p = parent; v = z } } ]
        else
          [ { name = "base"; vars = 2; where = [ { e = x; p = member; v = y } ]; ranges = []; head = Give { e = x; p = parent; v = y } };
            { name = "step"; vars = 3; where = [ { e = x; p = member; v = y }; { e = y; p = parent; v = z } ]; ranges = []; head = Give { e = x; p = parent; v = z } } ]
      in
      ignore (ok (define db rules));
      let edge = if form = "trp" then parent else member in
      let r = ok (write db (List.init 200 (fun i -> Add (-(i + 1), member, Link (-(i + 1)))))) in
      let n = Array.init 200 (fun i -> thing r (-(i + 1))) in
      ignore (ok (write db (List.init 200 (fun i -> Retract (n.(i), member, Link n.(i))))));
      let before = user_facts (view db) in
      (* a chain of 200 in one group: 19,701 facts of the closure *)
      refused (Printf.sprintf "%s, a chain of 200 from scratch (%s)" form (if older then "each edge to an older thing" else "to a newer one"))
        (fun () -> write db (List.init 199 (fun i -> if older then Add (n.(i + 1), edge, Link n.(i)) else Add (n.(i), edge, Link n.(i + 1)))));
      C.check (F.equal before (user_facts (view db))) "%s: all or nothing" form;
      (* two chains of 40 under the budget, then the edge that joins them: 1,600 facts at once *)
      let chain a = List.init 39 (fun i -> Add (n.(a + i), edge, Link n.(a + i + 1))) in
      ignore (ok (write db (chain 0)));
      ignore (ok (write db (chain 100)));
      refused (Printf.sprintf "%s, the edge that joins two chains of 40" form) (fun () -> write db [ Add (n.(39), edge, Link n.(100)) ]);
      C.check (F.equal (user_facts (view db)) (least (rules_of (view db)) (asserted_facts (view db)))) "%s: the least model after" form)
    [ "trp", true; "trp", false; "linear", true; "linear", false ];
  (* the W3C's form, unfolded: a dense result refused the same way *)
  let db = fork empty in
  let ty, parent, member, member_of, _, _ = schema db in
  let meta = List.hd (ok (declare db [ prop ~many:true "meta" Tlink ])) in
  let r = ok (write db (Add (-1, meta, Link parent) :: List.init 60 (fun i -> Add (-(i + 2), member, Link (-(i + 2)))))) in
  let a = thing r (-1) and n = Array.init 60 (fun i -> thing r (-(i + 2))) in
  ignore (ok (write db (List.init 60 (fun i -> Retract (n.(i), member, Link n.(i))))));
  let w3c = { name = "w3c-trp"; vars = 4; where = [ { e = Thing a; p = meta; v = Var 3 }; { e = x; p = prop_var 3; v = y }; { e = y; p = prop_var 3; v = z } ]; ranges = [];
              head = Give { e = x; p = prop_var 3; v = z } } in
  ignore (ok (define db [ w3c ]));
  (* a chain of 60: 59 edges, 1,711 facts derived *)
  ignore (ty, member_of);
  refused "the W3C's form of prp-trp, unfolded, over a chain" (fun () -> write db (List.init 59 (fun i -> Add (n.(i), parent, Link n.(i + 1)))));
  fst rule_budget := b0;
  snd rule_budget := b1

let () =
  section "rules: where a property's derived facts come from (for rights per kind)";
  let db = fork empty in
  let ty, parent, member, member_of, status, _ = schema db in
  let x = Var 0 and y = Var 1 and z = Var 2 in
  let r1 = { name = "s1"; vars = 2; where = [ { e = x; p = member; v = y } ]; ranges = []; head = Give { e = y; p = member_of; v = x } } in
  let r2 = { name = "s2"; vars = 3; where = [ { e = x; p = member_of; v = y }; { e = y; p = parent; v = z } ]; ranges = []; head = Give { e = x; p = ty; v = z } } in
  ignore (ok (define db [ r1; r2 ]));
  C.check (sources (view db) ty = Some (List.sort compare [ member; member_of; parent ])) "type comes from member, memberOf and parent";
  C.check (sources (view db) member = Some []) "member is asserted only";
  let meta = List.hd (ok (declare db [ prop ~many:true "meta" Tlink ])) in
  let r3 = { name = "s3"; vars = 3; where = [ { e = Var 2; p = meta; v = Var 1 }; { e = x; p = prop_var 1; v = Var 2 } ]; ranges = []; head = Give { e = x; p = status; v = Val (Text "x") } } in
  ignore (ok (define db [ r3 ]));
  C.check (sources (view db) status = None) "a rule over a variable property: status may come from any property";
  ignore meta

let () =
  section "rules: a closure's retractions decided by walks, against the least model and against B/F";
  let x = Var 0 and y = Var 1 and z = Var 2 in
  let run walk =
    Reason.walk_retract := walk;
    let db = fork empty in
    let _, parent, member, member_of, status, _ = schema db in
    let trp = { name = "trp"; vars = 3; where = [ { e = x; p = parent; v = y }; { e = y; p = parent; v = z } ]; ranges = []; head = Give { e = x; p = parent; v = z } } in
    let base = { name = "base"; vars = 2; where = [ { e = x; p = member; v = y } ]; ranges = []; head = Give { e = x; p = member_of; v = y } } in
    let step = { name = "step"; vars = 3; where = [ { e = x; p = member; v = y }; { e = y; p = member_of; v = z } ]; ranges = []; head = Give { e = x; p = member_of; v = z } } in
    (* another rule reads both closures: its facts follow their losses *)
    let flag = { name = "flag"; vars = 2; where = [ { e = x; p = parent; v = y }; { e = x; p = member_of; v = y } ]; ranges = []; head = Give { e = x; p = status; v = Val (Text "both") } } in
    ignore (ok (define db [ trp; base; step; flag ]));
    let r = ok (write db (List.init 40 (fun i -> Add (-(i + 1), status, Text "s")))) in
    let n = Array.init 40 (fun i -> thing r (-(i + 1))) in
    let rng = Rng.make 5 in
    let views = ref [] in
    for g = 1 to 120 do
      let a = n.(Rng.int rng 40) and b = n.(Rng.int rng 40) in
      let p = if Rng.bool rng then parent else member in
      let v = view db in
      let ops =
        match Rng.int rng 3 with
        | 0 -> (match List.filter (fun (q, w) -> q = p && Store.state v a q (Option.get (Store.word v w)) = 1) (get v a) with
                | (q, w) :: _ -> [ Retract (a, q, w) ] | [] -> [ Add (a, p, Link b) ])
        | 1 -> [ Add (a, member_of, Link b) ]
        | _ -> [ Add (a, p, Link b) ]
      in
      ignore (write db ops);
      let v = view db in
      if walk then C.check (F.equal (user_facts v) (least (rules_of v) (asserted_facts v))) "walks: group %d: the least model" g;
      views := user_facts v :: !views
    done;
    check_proofs (view db);
    List.rev !views
  in
  let a = run true and b = run false in
  Reason.walk_retract := true;
  C.check (List.for_all2 F.equal a b) "walks and B/F: the same view after every group";
  (* a retraction whose losses pass the budget is refused, whole, by walks as by B/F *)
  List.iter
    (fun walk ->
      Reason.walk_retract := walk;
      let db = fork empty in
      let _, parent, _, _, status, _ = schema db in
      ignore (ok (define db [ { name = "trp"; vars = 3; where = [ { e = x; p = parent; v = y }; { e = y; p = parent; v = z } ]; ranges = []; head = Give { e = x; p = parent; v = z } } ]));
      let r = ok (write db (List.init 100 (fun i -> Add (-(i + 1), status, Text "s")))) in
      let n = Array.init 100 (fun i -> thing r (-(i + 1))) in
      ignore (ok (write db (List.init 99 (fun i -> Add (n.(i + 1), parent, Link n.(i))))));
      let before = user_facts (view db) in
      let b0 = !(fst rule_budget) and b1 = !(snd rule_budget) in
      fst rule_budget := 1000;
      snd rule_budget := 1;
      (* the middle edge: 2,500 facts lost *)
      (match write db [ Retract (n.(50), parent, Link n.(49)) ] with
       | Error (Invalid m) -> C.check (String.length m > 5 && String.sub m 0 5 = "rule ") "%s: a retraction past the budget refused (%s)" (if walk then "walks" else "B/F") m
       | _ -> C.fail "%s: a retraction of 2,500 facts must pass a budget of 1,001" (if walk then "walks" else "B/F"));
      fst rule_budget := b0;
      snd rule_budget := b1;
      C.check (F.equal before (user_facts (view db))) "%s: all or nothing" (if walk then "walks" else "B/F"))
    [ true; false ];
  Reason.walk_retract := true

let has_sub m sub =
  let n = String.length sub in
  let rec f i = i + n <= String.length m && (String.sub m i n = sub || f (i + 1)) in
  f 0

let refused_with what sub = function
  | Error (Invalid m) -> C.check (has_sub m sub) "%s: refused with %S: %s" what sub m
  | Ok _ -> C.fail "%s: must be refused" what
  | Error e -> C.fail "%s: %s" what (message e)

let () =
  section "rules: Not, kept up to date both ways, over facts asserted and derived; cycles through it refused";
  let db = fork empty in
  let ty, parent, member, member_of, _, label = schema db in
  let paid = List.hd (ok (declare db [ prop ~many:true "paid" Tdate ])) in
  let r = ok (write db [ Add (-1, ty, Link (-1)) ]) in
  let invoice = thing r (-1) in
  let x = Var 0 and y = Var 1 in
  let unpaid = { name = "unpaid"; vars = 2; where = [ { e = x; p = ty; v = Thing invoice }; { e = x; p = absent 0 paid; v = y } ]; ranges = [];
                 head = Give { e = x; p = label; v = Val (Text "unpaid") } } in
  C.check (Rules.to_text unpaid = Printf.sprintf "vars 2; where [?0 %d #%d]; not [?0 %d ?1]; give [?0 %d t\"unpaid\"]" ty invoice paid label)
    "the text of a Not: %s" (Rules.to_text unpaid);
  C.check (Rules.of_text unpaid.name (Rules.to_text unpaid) = Ok unpaid) "a Not read back as written";
  ignore (ok (define db [ unpaid ]));
  let r = ok (write db [ Add (-1, ty, Link invoice); Add (-2, ty, Link invoice); Add (-2, paid, Date 5) ]) in
  let i1 = thing r (-1) and i2 = thing r (-2) in
  let labels i = values (view db) i label in
  C.check (labels i1 = [ Text "unpaid" ] && labels i2 = []) "the invoice without a payment is unpaid, the other not";
  ignore (ok (write db [ Add (i1, paid, Date 7) ]));
  C.check (labels i1 = []) "a payment added: no longer unpaid";
  ignore (ok (write db [ Retract (i1, paid, Date 7) ]));
  C.check (labels i1 = [ Text "unpaid" ]) "the payment retracted: unpaid again";
  ignore (ok (write db [ Retract (i2, paid, Date 5); Add (i2, paid, Date 6) ]));
  C.check (labels i2 = []) "a payment changed in one group: still paid";
  ignore (ok (write db [ Retract (i2, paid, Date 6) ]));
  C.check (labels i2 = [ Text "unpaid" ]) "its last payment retracted: unpaid";
  check_proofs (view db);
  (* a Not over facts a rule derives: the strata in order *)
  let member_rule = { name = "inverse"; vars = 2; where = [ { e = x; p = member; v = y } ]; ranges = []; head = Give { e = y; p = member_of; v = x } } in
  let alone = { name = "alone"; vars = 2; where = [ { e = x; p = ty; v = Thing invoice }; { e = x; p = absent 0 member_of; v = y } ]; ranges = [];
                head = Give { e = x; p = label; v = Val (Text "alone") } } in
  ignore (ok (define db [ member_rule; alone ]));
  C.check (List.mem (Text "alone") (labels i1)) "alone: no member_of derived";
  let r = ok (write db [ Add (-1, member, Link i1) ]) in
  let g = thing r (-1) in
  C.check (not (List.mem (Text "alone") (labels i1))) "a member added: member_of derived, no longer alone";
  ignore (ok (write db [ Retract (g, member, Link i1) ]));
  C.check (List.mem (Text "alone") (labels i1)) "the member retracted: member_of gone, alone again";
  C.check (F.equal (user_facts (view db)) (C.perfect (rules_of (view db)) (asserted_facts (view db)))) "the perfect model";
  check_proofs (view db);
  (* cycles through a Not refused, naming the cycle; the rules before are kept *)
  let a = { name = "ca"; vars = 2; where = [ { e = x; p = parent; v = y }; { e = x; p = absent 0 member; v = y } ]; ranges = []; head = Give { e = x; p = member_of; v = y } } in
  let b = { name = "cb"; vars = 2; where = [ { e = x; p = member_of; v = y } ]; ranges = []; head = Give { e = x; p = member; v = y } } in
  refused_with "a property that depends on its own absence" "depends on its own absence" (define db [ a; b ]);
  refused_with "a rule that reads its own head under Not" "depends on its own absence"
    (define db [ { name = "self"; vars = 2; where = [ { e = x; p = parent; v = y }; { e = x; p = absent 0 parent; v = y } ]; ranges = []; head = Give { e = y; p = parent; v = x } } ]);
  C.check (List.length (rules_of (view db)) = 3) "the refused rules left the others as they were";
  (* rights per kind: an absence tells of the properties its Not reads *)
  C.check (sources (view db) label = Some (List.sort compare [ ty; paid; member; member_of ])) "label comes from type, paid, member and member_of";
  (* refused shapes *)
  refused_with "a head variable under Not only" "in no pattern outside Not"
    (define db [ { name = "bad1"; vars = 2; where = [ { e = x; p = ty; v = Thing invoice }; { e = x; p = absent 0 member; v = y } ]; ranges = []; head = Give { e = y; p = member_of; v = x } } ]);
  refused_with "a body with Nots only" "no pattern outside Not"
    (define db [ { name = "bad2"; vars = 2; where = [ { e = x; p = absent 0 member; v = y } ]; ranges = []; head = Never } ]);
  refused_with "an own variable of two Nots" "the own of one Not only"
    (define db [ { name = "bad3"; vars = 2; where = [ { e = x; p = ty; v = Thing invoice }; { e = x; p = absent 0 member; v = y }; { e = x; p = absent 1 parent; v = y } ]; ranges = []; head = Never } ]);
  refused_with "an aggregate's code that aggregate does not make" "no property"
    (define db [ { name = "bad4"; vars = 2; where = [ { e = x; p = member; v = y } ]; ranges = []; head = Give { e = x; p = aggregate `Max member_of + (4 lsl 16); v = y } } ]);
  (* a constraint with a Not: refuses the group that takes away what it needs *)
  let paid_or_open = { name = "invoice-needs-member"; vars = 3; where = [ { e = x; p = ty; v = Thing invoice }; { e = x; p = paid; v = Var 2 }; { e = x; p = absent 0 member_of; v = y } ]; ranges = []; head = Never } in
  ignore (ok (define db [ paid_or_open ]));
  let r = ok (write db [ Add (-1, member, Link i2) ]) in
  let g2 = thing r (-1) in
  ignore (ok (write db [ Add (i2, paid, Date 9) ]));
  refused_with "a retraction that makes a constraint's Not true" "constraint invoice-needs-member" (write db [ Retract (g2, member, Link i2) ]);
  refused_with "a payment of an invoice without a member" "constraint invoice-needs-member" (write db [ Add (i1, paid, Date 1) ]);
  C.check (values (view db) i1 paid = [] && values (view db) i2 member_of = [ Link g2 ]) "all or nothing";
  check_proofs (view db)

let () =
  section "rules: Sum, Count, Min, Max, kept up to date by difference; exact sums; their property theirs alone";
  let db = fork empty in
  let line, amount, day, total, count, first, last =
    match declare db [ prop ~many:true "line" Tlink; prop "amount" Tint; prop "day" Tdate; prop "total" Tint; prop "count" Tint;
                       prop "first" Tdate; prop "last" Tdate ] with
    | Ok [ a; b; c; d; e; f; g ] -> a, b, c, d, e, f, g
    | _ -> assert false
  in
  let i = Var 0 and l = Var 1 and a = Var 2 in
  let body2 p = [ { e = i; p = line; v = l }; { e = l; p; v = a } ] in
  let rules =
    [ { name = "total-of"; vars = 3; where = body2 amount; ranges = []; head = Give { e = i; p = aggregate `Sum total; v = a } };
      { name = "count-of"; vars = 2; where = [ { e = i; p = line; v = l } ]; ranges = []; head = Give { e = i; p = aggregate `Count count; v = Val (Int 0) } };
      { name = "first-of"; vars = 3; where = body2 day; ranges = []; head = Give { e = i; p = aggregate `Min first; v = a } };
      { name = "last-of"; vars = 3; where = body2 day; ranges = []; head = Give { e = i; p = aggregate `Max last; v = a } } ]
  in
  C.check (Rules.to_text (List.hd rules) = Printf.sprintf "vars 3; where [?0 %d ?1] [?1 %d ?2]; give sum [?0 %d ?2]" line amount total) "the text of a sum";
  List.iter (fun (r : rule) -> C.check (Rules.of_text r.name (Rules.to_text r) = Ok r) "%s read back as written" r.name) rules;
  ignore (ok (define db rules));
  let r = ok (write db [ Add (-1, amount, Int 0); Add (-2, amount, Int 10); Add (-2, day, Date 3); Add (-3, amount, Int 5); Add (-3, day, Date 1);
                          Add (-1, line, Link (-2)); Add (-1, line, Link (-3)) ]) in
  let inv = thing r (-1) and l1 = thing r (-2) and l2 = thing r (-3) in
  let one p = match values (view db) inv p with [ x ] -> Some x | [] -> None | _ -> Some (Text "several") in
  let state () = one total, one count, one first, one last in
  C.check (state () = (Some (Int 15), Some (Int 2), Some (Date 1), Some (Date 3))) "two lines: the invoice's own amount is no line's";
  ignore (ok (write db [ Retract (inv, amount, Int 0) ]));
  C.check (state () = (Some (Int 15), Some (Int 2), Some (Date 1), Some (Date 3))) "sum 15, count 2, first day 1, last day 3";
  let r = ok (write db [ Add (-1, amount, Int 10); Add (-1, day, Date 9); Add (inv, line, Link (-1)) ]) in
  let l3 = thing r (-1) in
  C.check (state () = (Some (Int 25), Some (Int 3), Some (Date 1), Some (Date 9))) "a third line of the same amount counts again";
  check_proofs (view db);
  ignore (ok (write db [ Retract (inv, line, Link l2) ]));
  C.check (state () = (Some (Int 20), Some (Int 2), Some (Date 3), Some (Date 9))) "the line of the first day gone: Min read again";
  ignore (ok (write db [ Retract (l1, amount, Int 10); Add (l1, amount, Int 4) ]));
  C.check (state () = (Some (Int 14), Some (Int 2), Some (Date 3), Some (Date 9))) "an amount changed: the sum by difference";
  (match why (view db) inv total (Int 14) with
   | Some (By { rule = "total-of"; from; _ }) -> C.check (List.length from = 4) "Why of a sum: the facts of its answers (%d)" (List.length from)
   | _ -> C.fail "Why of a sum");
  ignore (ok (write db [ Retract (inv, line, Link l1); Retract (inv, line, Link l3) ]));
  C.check (state () = (None, None, None, None)) "no line: no fact";
  (* the extremes of the ints: a Min of max_int alone, a Max of the smallest alone, are values (min_int is no word a
     write stores) *)
  List.iter
    (fun d ->
      let r = ok (write db [ Add (-1, day, Date d); Add (inv, line, Link (-1)) ]) in
      C.check (state () = (None, Some (Int 1), Some (Date d), Some (Date d))) "one line of day %d: first and last are it" d;
      ignore (ok (write db [ Retract (inv, line, Link (thing r (-1))) ])))
    [ max_int; min_int + 1 ];
  C.check (state () = (None, None, None, None)) "no line again: no fact";
  C.check (F.equal (user_facts (view db)) (C.perfect (rules_of (view db)) (asserted_facts (view db)))) "the perfect model";
  (* exact sums: past the ints refused; back within them in the same group, accepted *)
  refused_with "a sum past the largest int" "past the largest int"
    (write db [ Add (-1, amount, Int max_int); Add (-2, amount, Int 1); Add (inv, line, Link (-1)); Add (inv, line, Link (-2)) ]);
  C.check (state () = (None, None, None, None)) "all or nothing";
  ignore (ok (write db [ Add (-1, amount, Int max_int); Add (-2, amount, Int 1); Add (-3, amount, Int (-1)); Add (inv, line, Link (-1)); Add (inv, line, Link (-2)); Add (inv, line, Link (-3)) ]));
  C.check (one total = Some (Int max_int)) "max_int + 1 - 1, exactly";
  (* the aggregate's property: no write asserts it, no other rule gives it *)
  refused_with "a write of an aggregate's property" "given by an aggregate rule" (write db [ Add (inv, total, Int 3) ]);
  refused_with "a retraction of an aggregate's fact" "given by an aggregate rule" (write db [ Retract (inv, total, Int max_int) ]);
  refused_with "a write of it where the aggregate gives none" "given by an aggregate rule" (write db [ Add (l1, total, Int 3) ]);
  refused_with "a write of the value the aggregate gives" "given by an aggregate rule" (write db [ Add (inv, total, Int max_int) ]);
  ignore (ok (write db [ Retract (inv, total, Int 7) ]));
  C.check (one total = Some (Int max_int) && values (view db) l1 total = []) "a retraction of a value it does not hold: nothing";
  (* a property with asserted facts: an aggregate over it refused, unless the same group retracts them; the group
     that removes an aggregate may write its property *)
  let owed = match declare db [ prop "owed" Tint ] with Ok [ o ] -> o | _ -> assert false in
  let owed_of = { name = "owed-of"; vars = 3; where = body2 amount; ranges = []; head = Give { e = i; p = aggregate `Sum owed; v = a } } in
  ignore (ok (write db [ Add (inv, owed, Int 1) ]));
  refused_with "an aggregate over asserted facts" "holds facts a write asserted" (define db [ owed_of ]);
  let rule_thing () =
    let v = view db and id = ref Schema.first_prop in
    while Schema.find v.schema !id <> None || Store.has_value v !id Schema.p_name do incr id done;
    !id
  in
  let rid = rule_thing () in
  ignore (ok (write db [ Retract (inv, owed, Int 1); Add (rid, Schema.p_rule, Text (Rules.to_text owed_of)); Add (rid, Schema.p_name, Text "owed-of") ]));
  C.check (values (view db) inv owed = [ Int max_int ]) "its facts retracted and the aggregate defined in one group";
  ignore (ok (write db [ Retract (rid, Schema.p_rule, Text (Rules.to_text owed_of)); Retract (rid, Schema.p_name, Text "owed-of"); Add (l1, owed, Int 2) ]));
  C.check (values (view db) inv owed = [] && values (view db) l1 owed = [ Int 2 ]) "the aggregate removed and its property written in one group";
  C.check (F.equal (user_facts (view db)) (C.perfect (rules_of (view db)) (asserted_facts (view db)))) "the perfect model, owed asserted";
  refused_with "another rule giving it" "which the aggregate total-of gives"
    (define db [ { name = "also"; vars = 3; where = body2 amount; ranges = []; head = Give { e = i; p = total; v = a } } ]);
  refused_with "a sum of dates" "sum is for ints and money"
    (define db [ { name = "bad"; vars = 3; where = body2 day; ranges = []; head = Give { e = i; p = aggregate `Sum last; v = a } } ]);
  refused_with "an aggregate of a many-valued property" "takes many values"
    (define db [ { name = "bad"; vars = 2; where = [ { e = i; p = line; v = l } ]; ranges = []; head = Give { e = i; p = aggregate `Count line; v = Val (Int 0) } } ]);
  refused_with "a property that depends on its own aggregate" "depends on its own aggregate"
    (define db [ { name = "loop"; vars = 2; where = [ { e = i; p = total; v = l } ]; ranges = []; head = Give { e = i; p = amount; v = l } } ]);
  check_proofs (view db);
  C.check (sources (view db) total = Some (List.sort compare [ line; amount ])) "a sum comes from the facts it adds up";
  (* the rule changed: its facts given again; removed: gone *)
  ignore (ok (define db [ { (List.hd rules) with where = body2 amount @ [ { e = l; p = day; v = Var 3 } ]; vars = 4 } ]));
  C.check (one total = None) "the sum over lines with a day: none has one";
  ignore (ok (undefine db [ "total-of"; "count-of" ]));
  C.check (one total = None && one count = None) "the aggregates removed: their facts gone";
  C.check (F.equal (user_facts (view db)) (C.perfect (rules_of (view db)) (asserted_facts (view db)))) "the perfect model after";
  (* the budget: the answers an aggregate's group changes count *)
  let pairs = { name = "pairs"; vars = 3; where = [ { e = i; p = line; v = l }; { e = i; p = line; v = a } ]; ranges = []; head = Give { e = i; p = aggregate `Count count; v = Val (Int 0) } } in
  ignore (ok (define db [ pairs ]));
  let b0 = !(fst rule_budget) and b1 = !(snd rule_budget) in
  fst rule_budget := 50;
  snd rule_budget := 1;
  refused_with "400 answers changed by 20 lines" "rule pairs" (write db (List.init 20 (fun k -> Add (inv, line, Link (-(k + 1)))) @ List.init 20 (fun k -> Add (-(k + 1), day, Date k))));
  fst rule_budget := b0;
  snd rule_budget := b1

let () =
  section "rules: the text of Not and aggregates, mutated: read or refused, never more, and what is read writes back the same";
  let r = Rng.make 11 in
  let texts =
    [ "vars 3; where [?0 16 ?1] [?1 17 ?2]; range ?2 i0 i5; not [?0 18 ?2]; not [?1 19 #65537] [?1 20 t\"a\"]; give sum [?0 21 ?2]";
      "vars 2; where [?0 16 ?1]; not [?1 17 i1]; give count [?0 21 i0]";
      "vars 4; where [?0 16 ?1] [?1 17 ?2]; not [?0 18 ?3] [?3 19 m5]; give never";
      "vars 3; where [?0 16 ?1] [?1 17 ?2]; give min [?0 21 ?2]"; "vars 3; where [?0 16 ?1] [?1 17 ?2]; give max [?0 21 ?2]" ]
  in
  let alphabet = "vars;wherngiv[]?#0123456789 tmidbsuncoxa\"-" in
  let n = ref 0 and read = ref 0 in
  List.iter
    (fun t ->
      C.check (match Rules.of_text "t" t with Ok rl -> Rules.to_text rl = t | Error _ -> false) "read back: %s" t;
      for _ = 1 to 4000 do
        let b = Bytes.of_string t in
        for _ = 1 to 1 + Rng.int r 3 do
          let k = Rng.int r (Bytes.length b) in
          Bytes.set b k alphabet.[Rng.int r (String.length alphabet)]
        done;
        let s = Bytes.to_string b in
        let s = if Rng.int r 4 = 0 then String.sub s 0 (Rng.int r (String.length s)) else s in
        incr n;
        match Rules.of_text "t" s with
        | Ok rl -> incr read; if Rules.to_text rl <> s then C.fail "a mutated text read but not written back: %S" s
        | Error _ -> ()
        | exception e -> C.fail "a mutated text raised %s: %S" (Printexc.to_string e) s
      done)
    texts;
  C.check (!n = 20000) "%d mutated texts, %d of them read" !n !read

(* ---- G17, G18, G20: random sequences against the least model from scratch ---- *)

let debug = match Sys.getenv_opt "RULES_SEED" with Some s -> int_of_string s | None -> 0

let show_op = function
  | Add (e, p, x) -> Printf.sprintf "+[%d %d %s]" e p (Value.to_string x)
  | Retract (e, p, x) -> Printf.sprintf "-[%d %d %s]" e p (Value.to_string x)
  | Expect _ -> "expect"

(* each group's outcome and view, by (seed, group, merges): a run with the rules always as written must give the
   unfolded run's, exactly (Reason.specialise) *)
let outcomes : (int * int * bool, bool * F.t) Hashtbl.t = Hashtbl.create 4096
let compare_paths = ref false

(* [durable]: the sequences on a database on the disk, written through its threaded writer: each change of the rules
   takes the background path (Engine), and must decide and leave exactly what the model says, as a fork does (G8) *)
let random_sequences ?(durable = false) ~seeds ~groups ~merges () =
  let progress = Sys.getenv_opt "RULES_PROGRESS" <> None in
  for seed = (if debug > 0 then debug else 1) to (if debug > 0 then debug else seeds) do
    if progress then begin
      let st = if seed mod 10 = 0 then Gc.stat () else Gc.quick_stat () in
      if seed mod 10 = 0 then Printf.printf "  live %d MB\n" (st.live_words * 8 / 1048576);
      let rss = try let ic = open_in "/proc/self/statm" in let l = input_line ic in close_in ic; Scanf.sscanf l "%d %d" (fun _ r -> r * 4 / 1024) with _ -> -1 in
      Printf.printf "seed %d %.1f s heap %d MB rss %d MB\n%!" seed (Unix.gettimeofday ()) (st.heap_words * 8 / 1048576) rss
    end;
    let r = Rng.make seed in
    let dir = Filename.concat (Option.value (Sys.getenv_opt "CEPHEUS_TMP") ~default:(Filename.get_temp_dir_name ())) (Printf.sprintf "cepheus-rules-%d-%d" (Unix.getpid ()) seed) in
    if durable then C.rmrf dir;
    let db = ref (if durable then (match open_ dir with Ok db -> db | Error e -> failwith (message e)) else fork empty) in
    let a, b, c, ty, n, tag, meta, total, cnt, lo, hi =
      match declare !db [ prop ~many:true "a" Tlink; prop ~many:true "b" Tlink; prop ~many:true "c" Tlink;
                          prop ~many:true "type" Tlink; prop ~many:true "n" Tint; prop ~many:true "tag" Ttext;
                          prop ~many:true "meta" Tlink; prop "total" Tint; prop "cnt" Tint; prop "lo" Tint; prop "hi" Tint ] with
      | Ok [ a; b; c; ty; n; tag; meta; total; cnt; lo; hi ] -> a, b, c, ty, n, tag, meta, total, cnt, lo, hi
      | _ -> assert false
    in
    (* the aggregates' properties, one-valued ints no write asserts: read by bodies, given by aggregates only *)
    let aggp = [| total; cnt; lo; hi |] in
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
      let kind = Rng.int r 10 in
      match kind with
      | 0 -> closure_rule k
      | 1 -> var_prop_rule k
      | _ ->
      let atom () =
        match Rng.int r 9 with
        | 0 -> { e = Var (Rng.int r 3); p = n; v = (if Rng.bool r then Var 4 else Val (Int (Rng.int r 3))) }
        | 8 -> { e = Var (Rng.int r 3); p = aggp.(Rng.int r 4); v = (if Rng.bool r then Var 4 else Val (Int (Rng.int r 3))) }
        | 1 -> { e = Var (Rng.int r 3); p = tag; v = (if Rng.bool r then Var 5 else Val (Text texts.(Rng.int r 3))) }
        | _ ->
          let p = links.(Rng.int r 4) in
          let e = if Rng.int r 6 = 0 then Thing (some_thing ()) else Var (Rng.int r 3) in
          let v = if Rng.int r 5 = 0 then Thing (some_thing ()) else Var (Rng.int r 3) in
          { e; p; v }
      in
      let body = List.init (1 + Rng.int r 3) (fun _ -> atom ()) in
      let used = Array.make 12 false in
      let use (q : pattern) = List.iter (function Var x -> used.(x) <- true | _ -> ()) [ q.e; q.v ] in
      List.iter use body;
      (* an atom with no variable is allowed; a rule needs a link variable for its head *)
      let link_vars = List.filter (fun x -> used.(x)) [ 0; 1; 2; 3 ] in
      if link_vars = [] then None
      else begin
        let pick l = List.nth l (Rng.int r (List.length l)) in
        (* kinds 2 and 3: an aggregate (its value an int variable of the body, bound by an n atom if need be) *)
        let agg = if kind <= 3 then Some (Rng.int r 4) else None in
        let body =
          match agg with
          | Some f when f <> 1 && not used.(4) -> let q = { e = Var (pick link_vars); p = n; v = Var 4 } in use q; body @ [ q ]
          | _ -> body
        in
        let head =
          match agg with
          | Some f -> Give { e = Var (pick link_vars); p = aggregate (match f with 0 -> `Sum | 1 -> `Count | 2 -> `Min | _ -> `Max) aggp.(f);
                             v = (if f = 1 then Val (Int 0) else Var 4) }
          | None ->
          if Rng.int r 10 = 0 then Never
          else
            match Rng.int r 6 with
            | 0 when used.(4) -> Give { e = Var (pick link_vars); p = n; v = Var 4 }
            | 1 when used.(5) -> Give { e = Var (pick link_vars); p = tag; v = Var 5 }
            | 2 -> Give { e = Var (pick link_vars); p = tag; v = Val (Text "derived") }
            | _ -> Give { e = Var (pick link_vars); p = links.(Rng.int r 4); v = (if Rng.int r 4 = 0 then Thing (some_thing ()) else Var (pick link_vars)) }
        in
        let ranges = if used.(4) && Rng.int r 4 = 0 then [ (4, Int 0, Int 1) ] else [] in
        (* kinds 2 to 5 (and an aggregate, one time in two): one or two Nots of one or two patterns each, over the body's
           variables and their own (Not g's: links 6 + 3g and 7 + 3g, an int 8 + 3g), a range on its own int now and then *)
        let outer = List.filter (fun x -> used.(x)) [ 0; 1; 2; 3 ] and outer_int = used.(4) and outer_text = used.(5) in
        let nots, ranges =
          if kind > 5 || (agg <> None && Rng.bool r) then [], ranges
          else begin
            let ranges = ref ranges in
            let not_pats g =
              let own_l = [ 6 + (3 * g); 7 + (3 * g) ] and own_i = 8 + (3 * g) in
              let lv () = Var (if Rng.int r 3 = 0 then pick own_l else pick outer) in
              let pat () =
                match Rng.int r 6 with
                | 0 -> { e = lv (); p = n; v = (match Rng.int r 3 with 0 when outer_int -> Var 4 | 1 -> Var own_i | _ -> Val (Int (Rng.int r 3))) }
                | 1 -> { e = lv (); p = aggp.(Rng.int r 4); v = (match Rng.int r 3 with 0 when outer_int -> Var 4 | 1 -> Var own_i | _ -> Val (Int (Rng.int r 3))) }
                | 2 -> { e = lv (); p = tag; v = (if outer_text && Rng.bool r then Var 5 else Val (Text texts.(Rng.int r 3))) }
                | _ -> { e = lv (); p = links.(Rng.int r 4); v = (if Rng.int r 5 = 0 then Thing (some_thing ()) else lv ()) }
              in
              let ps = List.init (1 + Rng.int r 2) (fun _ -> pat ()) in
              if List.exists (fun (q : pattern) -> q.v = Var own_i) ps && Rng.int r 3 = 0 then ranges := (own_i, Int 1, Int 2) :: !ranges;
              List.map (fun (q : pattern) -> { q with p = absent g q.p }) ps
            in
            let nots = List.concat (List.init (1 + Rng.int r 2) not_pats) in
            List.iter use nots;
            nots, !ranges
          end
        in
        (* dense numbering *)
        let map = Array.make 12 (-1) and next = ref 0 in
        Array.iteri (fun x u -> if u then (map.(x) <- !next; incr next)) used;
        let t = function Var x -> Var map.(x) | t -> t in
        let pat (q : pattern) = { q with e = t q.e; v = t q.v } in
        Some { name = Printf.sprintf "r%d" k; vars = !next; where = List.map pat (body @ nots);
               ranges = List.map (fun (x, lo, hi) -> (map.(x), lo, hi)) ranges;
               head = (match head with Never -> Never | Give h -> Give (pat h)) }
      end
    in
    (* the properties the rules' aggregates give: no write asserts them, no other rule gives them *)
    let agg_props (rules : rule list) =
      List.filter_map (fun (rl : rule) -> let d = C.decode rl in match d.dhead, d.dagg with Give h, Some _ -> Some h.p | _ -> None) rules
    in
    let agg_conflict (rules : rule list) =
      List.exists
        (fun (rl : rule) ->
          let d = C.decode rl in
          match d.dhead, d.dagg with
          | Give h, Some _ ->
            List.exists (fun (o : rule) -> o.name <> rl.name && match (C.decode o).dhead with Give g -> g.p = h.p || g.p < 0 | Never -> false) rules
          | _ -> false)
        rules
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
           (* a cycle through a Not or an aggregate, or an aggregate's property given by another rule: refused *)
           let cyc = not (C.stratified rules') and conflict = agg_conflict rules' in
           let m' = if cyc || conflict then e_old else C.perfect ~ptyp ~bad rules' e_old in
           if seed = debug then Printf.printf "g%d define %s: %s\n" g rl.name (Rules.to_text rl);
           match define !db [ rl ] with
           | Ok _ ->
             C.check (not (cyc || conflict)) "seed %d group %d: a rule accepted that is not stratified (%b) or gives an aggregate's property (%b)" seed g cyc conflict;
             C.check (not (violated rules' m' || !bad)) "seed %d group %d: a rule accepted over a state that breaks a constraint or derives a fact of the wrong type" seed g
           | Error (Invalid msg) ->
             (* refused: a cycle, a conflict, a constraint broken, or the budget; never silently; a rule with a Not or an
                aggregate the generator made well is refused for one of those only *)
             if has_sub msg "depends on its own" then C.check cyc "seed %d group %d: refused for a cycle the strata do not find: %s" seed g msg
             else if has_sub msg "which the aggregate" then C.check conflict "seed %d group %d: refused for a conflict: %s" seed g msg
             else
               C.check (cyc || conflict || violated rules' m' || !bad || (Rules.is_plain rl && String.length msg > 0)) "seed %d group %d: rule refused: %s" seed g msg
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
         let given = agg_props rules in
         List.iter
           (function
             | Add (_, p, _) | Retract (_, p, _) when List.mem p given -> refused := true
             | Add (e, p, x) -> m := F.add (e, p, x) !m; ea := F.add (e, p, x) !ea
             | Retract (e, p, x) ->
               if F.mem (e, p, x) !ea then (m := F.remove (e, p, x) !m; ea := F.remove (e, p, x) !ea)
               else if F.mem (e, p, x) !m then refused := true
             | Expect _ -> ())
           ops;
         let bad = ref false in
         let m' = C.perfect ~ptyp ~bad rules !ea in
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
      (let key = (seed, g, merges) and here = (v.group, got) in
       if !compare_paths then
         match Hashtbl.find_opt outcomes key with
         | Some (_, f) -> C.check (F.equal f got) "seed %d group %d: the rules as written give the unfolded run's view: %s" seed g (C.show_diff f got)
         | None -> ()
       else Hashtbl.replace outcomes key (true, snd here));
      let want = C.perfect ~ptyp rules asserted in
      C.check (F.equal got want) "seed %d group %d: G17, the view is the perfect model: %s" seed g (if F.equal got want then "" else C.show_diff got want);
      C.check (not (violated rules got)) "seed %d group %d: G18, no constraint broken" seed g;
      if g mod 5 = 0 then check_proofs ~where:(Printf.sprintf "seed %d group %d" seed g) v;
      (* the facts into runs now and then: the next groups write over a run (flags in it, flags changed over it) *)
      if seed = debug then
        Printf.printf "   view: %s\n%!" (String.concat " " (List.map (fun (e, p, x) -> Printf.sprintf "%d.%d.%s%s" e p (Value.to_string x) (if F.mem (e, p, x) asserted then "" else "*")) (F.elements got)));
      if merges && Rng.int r 4 = 0 then db := fork (if Rng.bool r then C.compact v else C.push v)
    done;
    if durable then begin
      (* and the journal replays to the same view: the changes' frames hold their derived facts *)
      let last = user_facts (view !db) in
      close !db;
      (match open_ dir with
       | Ok db2 -> C.check (F.equal (user_facts (view db2)) last) "seed %d: the database reopened holds the same facts" seed; close db2
       | Error e -> C.fail "seed %d: reopen: %s" seed (message e));
      C.rmrf dir
    end
  done

let () =
  (* the runs' pages of the merged views in a small cache, as the other tests have them *)
  Pages.set_capacity (32 lsl 20);
  section "G17, G18, G20: random rules and writes on forks, against the least model from scratch";
  let seeds = match Sys.getenv_opt "RULES_SEEDS" with Some s -> int_of_string s | None -> 60 in
  random_sequences ~seeds ~groups:60 ~merges:false ();
  section "G17, G18, G20: the same with the facts merged into runs between groups";
  random_sequences ~seeds ~groups:60 ~merges:true ();
  section "G8, G17, G19: the same on databases on the disk: every change of the rules on the background path";
  random_sequences ~durable:true ~seeds:(max 1 (seeds / 2)) ~groups:60 ~merges:false ();
  C.check (Atomic.get Engine.changes_done > 0) "the background path installed changes";
  section "the rules always as written (no unfolding) and closures retracted by B/F: every group's view the same as above";
  Reason.specialise := false;
  Reason.walk_retract := false;
  compare_paths := true;
  random_sequences ~seeds ~groups:60 ~merges:false ();
  Reason.specialise := true;
  Reason.walk_retract := true;
  compare_paths := false

let () =
  Printf.printf "(groups reasoned unfolded %d, as written %d, again as written %d; closures from scratch %d)\n" !Reason.spec_groups
    !Reason.gen_groups !Reason.respecs !Reason.batches;
  C.finish "reasoning"
