(* OWL 2 RL, the library of rules (Cepheus.Owl): each rule of the W3C's tables 4 to 9 (OWL 2 Profiles, section 4.3)
   by a case where it fires (its fact is there) or where its constraint refuses the write, on four paths:
     fork      the ontology in a group, then the data in another (insertion, semi-naive, the rules unfolded);
     as-written  the same with the rules never unfolded (Reason.specialise false);
     late      the data first, then the ontology (a change of the ontology, and of the templates' lists);
     load      on the disk, the ontology then the data as a large group (the path of loads);
     change    on the disk, the data first, then the ontology (the threaded writer: a change of the rules in the
               background when a template's list changes).
   On every path, after each group, the view must be exactly the least model of its asserted facts under the rules,
   computed from scratch by the checker (Check.least, templates by their meaning), and stay so when the data is
   retracted and written again. Then random ontologies and data, against the same checker. *)

open Cepheus
module C = Check
module F = C.F

let ok = function Ok x -> x | Error e -> failwith (message e)
let section name = Printf.printf "- %s\n%!" name

type env = { db : db; o : Owl.t; k : int; l : int; j : int; tx : int; age : int; label : int; th : int array }

let props = [ prop ~many:true "t/k" Tlink; prop ~many:true "t/l" Tlink; prop ~many:true "t/j" Tlink; prop ~many:true "t/text" Ttext;
              prop ~many:true "t/age" Tint; prop ~many:true "t/label" Ttext ]

let setup db =
  let o = ok (Owl.setup db) in
  let[@warning "-8"] [ k; l; j; tx; age; label ] = ok (declare db props) in
  ignore (ok (define db (Owl.rl o)));
  let r = ok (write db (List.init 30 (fun i -> Add (-(i + 1), label, Text (Printf.sprintf "x%d" i))))) in
  { db; o; k; l; j; tx; age; label; th = Array.init 30 (fun i -> thing r (-(i + 1))) }

(* classes c 0..5, restrictions r 0..2, descriptions d 0..3, individuals i 0..16 *)
let c e n = e.th.(n)
let r e n = e.th.(6 + n)
let d e n = e.th.(9 + n)
let i e n = e.th.(13 + n)
let lk x = Link x

type expect = Has of (int * int * value) list | Lacks of (int * int * value) list | Refused of string | Nothing_more | Same of int list | Apart of int * int

type case = { name : string; onto : env -> op list; data : env -> op list; expect : env -> expect list }

let ptyp (v : view) p = Option.map (fun (d : prop) -> d.typ) (describe v p)

(* the view against the least model of its asserted facts; with rules that make things the same, against the meaning
   of the equality (Check.eq_diff: the same classes, the same facts read through them) *)
let exact what (v : view) =
  if List.exists C.same_head (C.rules_of v) then begin
    let _, errs = C.eq_diff ~ptyp:(ptyp v) v in
    match errs with [] -> incr C.checks | l -> C.fail "%s: the view is not the meaning of its rules\n  %s" what (String.concat "\n  " l)
  end
  else
  let bad = ref false in
  let want = C.least ~ptyp:(ptyp v) ~bad (C.rules_of v) (C.asserted_facts v) in
  let got = C.user_facts v in
  if not (F.equal got want) then begin
    let show s = String.concat " " (List.map (fun (e, p, x) -> Printf.sprintf "[%d %d %s]" e p (Value.to_string x)) (F.elements s)) in
    C.fail "%s: the view is not the least model\n  missing %s\n  extra %s" what (show (F.diff want got)) (show (F.diff got want))
  end
  else incr C.checks

(* a fact, read as a program reads it: its things as their classes' representatives *)
let has (v : view) (e, p, x) =
  let x = match x with Link t -> Link (Query.rep v t) | x -> x in
  List.exists (Value.equal x) (values v e p)

let expect_after what env (res : (receipt, error) result) (ex : expect list) =
  let v = view env.db in
  List.iter
    (function
      | Has fs -> (match res with Ok _ -> List.iter (fun f -> let e, p, x = f in C.check (has v f) "%s: [%d %d %s] derived" what e p (Value.to_string x)) fs | Error e -> C.fail "%s: refused: %s" what (message e))
      | Lacks fs -> List.iter (fun f -> let e, p, x = f in C.check (not (has v f)) "%s: no [%d %d %s]" what e p (Value.to_string x)) fs
      | Refused rule -> (
        match res with
        | Error e ->
          let m = message e in
          let has_sub s sub = let n = String.length sub in let rec f k = k + n <= String.length s && (String.sub s k n = sub || f (k + 1)) in f 0 in
          C.check (has_sub m rule) "%s: refused by %s (%s)" what rule m
        | Ok _ -> C.fail "%s: accepted, %s expected to refuse it" what rule)
      | Same l -> (match res with Ok _ -> List.iter (fun x -> C.check (same v x = List.sort compare l) "%s: the class of #%d is %s, not %s" what x (String.concat "," (List.map string_of_int l)) (String.concat "," (List.map string_of_int (same v x)))) l | Error e -> C.fail "%s: refused: %s" what (message e))
      | Apart (a, b) -> C.check (not (List.mem b (same v a))) "%s: #%d and #%d apart" what a b
      | Nothing_more -> ())
    ex;
  exact what v

let retract_all ops = List.filter_map (function Add (e, p, x) -> Some (Retract (e, p, x)) | _ -> None) ops

(* one case on one path *)
let run_case path (cs : case) env =
  let what = cs.name ^ " (" ^ path ^ ")" in
  let onto = cs.onto env and data = cs.data env and ex = cs.expect env in
  let refused = List.exists (function Refused _ -> true | _ -> false) ex in
  let late = (path = "late" || path = "change") && onto <> [] in
  let w ops = if ops = [] then Ok { group = group (view env.db); things = [] } else write env.db ops in
  let first, second = if late then data, onto else onto, data in
  let r1 = w first in
  if late && refused then (match r1 with Ok _ -> () | Error e -> C.fail "%s: the data alone refused: %s" what (message e))
  else if not late then ignore (ok r1);
  exact (what ^ ", first group") (view env.db);
  let large = path = "load" in
  let saved = !Resolve.large_min in
  if large then Resolve.large_min := 1;
  let r2 = Fun.protect ~finally:(fun () -> Resolve.large_min := saved) (fun () -> w second) in
  expect_after what env r2 ex;
  if not refused then begin
    (* the data retracted, then written again: retraction, B/F *)
    ignore (ok (w (retract_all data)));
    exact (what ^ ", data retracted") (view env.db);
    ignore (ok (w data));
    exact (what ^ ", data written again") (view env.db);
    (* and the ontology retracted: a change of the rules' unfolding *)
    ignore (ok (w (retract_all onto)));
    exact (what ^ ", ontology retracted") (view env.db)
  end

let tru = Bool true

let cases : case list =
  let ty e = e.o.type_ in
  let nodata _ = [] in
  [ { name = "prp-ap: a property no rule reads"; onto = (fun _ -> []); data = (fun e -> [ Add (i e 0, e.tx, Text "note") ]); expect = (fun _ -> [ Nothing_more ]) };
    { name = "prp-dom"; onto = (fun e -> [ Add (d e 0, e.o.property, lk e.k); Add (d e 0, e.o.domain, lk (c e 0)) ]);
      data = (fun e -> [ Add (i e 0, e.k, lk (i e 1)) ]); expect = (fun e -> [ Has [ i e 0, ty e, lk (c e 0) ]; Lacks [ i e 1, ty e, lk (c e 0) ] ]) };
    { name = "prp-rng"; onto = (fun e -> [ Add (d e 0, e.o.property, lk e.k); Add (d e 0, e.o.range, lk (c e 0)) ]);
      data = (fun e -> [ Add (i e 0, e.k, lk (i e 1)) ]); expect = (fun e -> [ Has [ i e 1, ty e, lk (c e 0) ] ]) };
    { name = "prp-irp"; onto = (fun e -> [ Add (d e 0, e.o.property, lk e.k); Add (d e 0, e.o.irreflexive, tru) ]);
      data = (fun e -> [ Add (i e 0, e.k, lk (i e 0)) ]); expect = (fun _ -> [ Refused "owl/prp-irp" ]) };
    { name = "prp-symp"; onto = (fun e -> [ Add (d e 0, e.o.property, lk e.k); Add (d e 0, e.o.symmetric, tru) ]);
      data = (fun e -> [ Add (i e 0, e.k, lk (i e 1)) ]); expect = (fun e -> [ Has [ i e 1, e.k, lk (i e 0) ] ]) };
    { name = "prp-asyp"; onto = (fun e -> [ Add (d e 0, e.o.property, lk e.k); Add (d e 0, e.o.asymmetric, tru) ]);
      data = (fun e -> [ Add (i e 0, e.k, lk (i e 1)); Add (i e 1, e.k, lk (i e 0)) ]); expect = (fun _ -> [ Refused "owl/prp-asyp" ]) };
    { name = "prp-trp"; onto = (fun e -> [ Add (d e 0, e.o.property, lk e.k); Add (d e 0, e.o.transitive, tru) ]);
      data = (fun e -> [ Add (i e 0, e.k, lk (i e 1)); Add (i e 1, e.k, lk (i e 2)); Add (i e 2, e.k, lk (i e 3)) ]);
      expect = (fun e -> [ Has [ i e 0, e.k, lk (i e 2); i e 0, e.k, lk (i e 3); i e 1, e.k, lk (i e 3) ] ]) };
    { name = "prp-spo1"; onto = (fun e -> [ Add (d e 0, e.o.property, lk e.k); Add (d e 0, e.o.sub_property_of, lk e.l) ]);
      data = (fun e -> [ Add (i e 0, e.k, lk (i e 1)) ]); expect = (fun e -> [ Has [ i e 0, e.l, lk (i e 1) ] ]) };
    { name = "prp-spo2"; onto = (fun e -> [ Add (r e 0, e.o.chain_of, lk e.j); Add (r e 0, e.o.first, lk e.k); Add (r e 0, e.o.second, lk e.l) ]);
      data = (fun e -> [ Add (i e 0, e.k, lk (i e 1)); Add (i e 1, e.l, lk (i e 2)) ]); expect = (fun e -> [ Has [ i e 0, e.j, lk (i e 2) ]; Lacks [ i e 1, e.j, lk (i e 2) ] ]) };
    { name = "prp-eqp1"; onto = (fun e -> [ Add (d e 0, e.o.property, lk e.k); Add (d e 0, e.o.equivalent_property, lk e.l) ]);
      data = (fun e -> [ Add (i e 0, e.k, lk (i e 1)) ]); expect = (fun e -> [ Has [ i e 0, e.l, lk (i e 1) ] ]) };
    { name = "prp-eqp2"; onto = (fun e -> [ Add (d e 0, e.o.property, lk e.k); Add (d e 0, e.o.equivalent_property, lk e.l) ]);
      data = (fun e -> [ Add (i e 0, e.l, lk (i e 1)) ]); expect = (fun e -> [ Has [ i e 0, e.k, lk (i e 1) ] ]) };
    { name = "prp-pdw"; onto = (fun e -> [ Add (d e 0, e.o.property, lk e.k); Add (d e 0, e.o.property_disjoint_with, lk e.l) ]);
      data = (fun e -> [ Add (i e 0, e.k, lk (i e 1)); Add (i e 0, e.l, lk (i e 1)) ]); expect = (fun _ -> [ Refused "owl/prp-pdw" ]) };
    { name = "prp-adp: AllDisjointProperties as its pairs";
      onto = (fun e -> [ Add (d e 0, e.o.property, lk e.k); Add (d e 1, e.o.property, lk e.l); Add (d e 2, e.o.property, lk e.j) ] @ Owl.disjoint_properties e.o [ d e 0, e.k; d e 1, e.l; d e 2, e.j ]);
      data = (fun e -> [ Add (i e 0, e.l, lk (i e 1)); Add (i e 0, e.j, lk (i e 1)) ]); expect = (fun _ -> [ Refused "owl/prp-pdw" ]) };
    { name = "prp-inv1"; onto = (fun e -> [ Add (d e 0, e.o.property, lk e.k); Add (d e 0, e.o.inverse_of, lk e.l) ]);
      data = (fun e -> [ Add (i e 0, e.k, lk (i e 1)) ]); expect = (fun e -> [ Has [ i e 1, e.l, lk (i e 0) ] ]) };
    { name = "prp-inv2"; onto = (fun e -> [ Add (d e 0, e.o.property, lk e.k); Add (d e 0, e.o.inverse_of, lk e.l) ]);
      data = (fun e -> [ Add (i e 0, e.l, lk (i e 1)) ]); expect = (fun e -> [ Has [ i e 1, e.k, lk (i e 0) ] ]) };
    { name = "prp-npa1";
      onto = (fun e -> [ Add (r e 0, e.o.source_individual, lk (i e 0)); Add (r e 0, e.o.assertion_property, lk e.k); Add (r e 0, e.o.target_individual, lk (i e 1)) ]);
      data = (fun e -> [ Add (i e 0, e.k, lk (i e 1)) ]); expect = (fun _ -> [ Refused "owl/prp-npa1" ]) };
    { name = "prp-npa2";
      onto = (fun e -> [ Add (r e 0, e.o.source_individual, lk (i e 0)); Add (r e 0, e.o.assertion_property, lk e.tx); Add (r e 0, e.o.target_value, Text "no") ]);
      data = (fun e -> [ Add (i e 0, e.tx, Text "no") ]); expect = (fun _ -> [ Refused "owl/prp-npa2" ]) };
    { name = "cls-thing, cls-nothing1: the two built-in classes"; onto = (fun _ -> []); data = nodata;
      expect = (fun e -> [ Has [ e.o.thing, e.o.builtin, Text "Thing"; e.o.nothing, e.o.builtin, Text "Nothing" ] ]) };
    { name = "cls-nothing2"; onto = (fun _ -> []); data = (fun e -> [ Add (i e 0, ty e, lk e.o.nothing) ]); expect = (fun _ -> [ Refused "owl/cls-nothing2" ]) };
    { name = "cls-int1"; onto = (fun e -> [ Add (c e 0, e.o.intersection_of, lk (c e 1)); Add (c e 0, e.o.intersection_of, lk (c e 2)); Add (c e 0, e.o.intersection_of, lk (c e 3)) ]);
      data = (fun e -> [ Add (i e 0, ty e, lk (c e 1)); Add (i e 0, ty e, lk (c e 2)); Add (i e 0, ty e, lk (c e 3)); Add (i e 1, ty e, lk (c e 1)); Add (i e 1, ty e, lk (c e 2)) ]);
      expect = (fun e -> [ Has [ i e 0, ty e, lk (c e 0) ]; Lacks [ i e 1, ty e, lk (c e 0) ] ]) };
    { name = "cls-int2"; onto = (fun e -> [ Add (c e 0, e.o.intersection_of, lk (c e 1)); Add (c e 0, e.o.intersection_of, lk (c e 2)) ]);
      data = (fun e -> [ Add (i e 0, ty e, lk (c e 0)) ]); expect = (fun e -> [ Has [ i e 0, ty e, lk (c e 1); i e 0, ty e, lk (c e 2) ] ]) };
    { name = "cls-uni"; onto = (fun e -> [ Add (c e 0, e.o.union_of, lk (c e 1)); Add (c e 0, e.o.union_of, lk (c e 2)) ]);
      data = (fun e -> [ Add (i e 0, ty e, lk (c e 2)) ]); expect = (fun e -> [ Has [ i e 0, ty e, lk (c e 0) ] ]) };
    { name = "cls-com"; onto = (fun e -> [ Add (c e 0, e.o.complement_of, lk (c e 1)) ]);
      data = (fun e -> [ Add (i e 0, ty e, lk (c e 0)); Add (i e 0, ty e, lk (c e 1)) ]); expect = (fun _ -> [ Refused "owl/cls-com" ]) };
    { name = "cls-svf1"; onto = (fun e -> [ Add (r e 0, e.o.some_values_from, lk (c e 1)); Add (r e 0, e.o.on_property, lk e.k) ]);
      data = (fun e -> [ Add (i e 0, e.k, lk (i e 1)); Add (i e 1, ty e, lk (c e 1)); Add (i e 2, e.k, lk (i e 3)) ]);
      expect = (fun e -> [ Has [ i e 0, ty e, lk (r e 0) ]; Lacks [ i e 2, ty e, lk (r e 0) ] ]) };
    { name = "cls-svf2"; onto = (fun e -> [ Add (r e 0, e.o.some_values_from, lk e.o.thing); Add (r e 0, e.o.on_property, lk e.k) ]);
      data = (fun e -> [ Add (i e 0, e.k, lk (i e 1)) ]); expect = (fun e -> [ Has [ i e 0, ty e, lk (r e 0) ] ]) };
    { name = "cls-avf"; onto = (fun e -> [ Add (r e 0, e.o.all_values_from, lk (c e 1)); Add (r e 0, e.o.on_property, lk e.k) ]);
      data = (fun e -> [ Add (i e 0, ty e, lk (r e 0)); Add (i e 0, e.k, lk (i e 1)) ]); expect = (fun e -> [ Has [ i e 1, ty e, lk (c e 1) ] ]) };
    { name = "cls-hv1"; onto = (fun e -> [ Add (r e 0, e.o.has_value, lk (i e 5)); Add (r e 0, e.o.on_property, lk e.k) ]);
      data = (fun e -> [ Add (i e 0, ty e, lk (r e 0)) ]); expect = (fun e -> [ Has [ i e 0, e.k, lk (i e 5) ] ]) };
    { name = "cls-hv2"; onto = (fun e -> [ Add (r e 0, e.o.has_value, lk (i e 5)); Add (r e 0, e.o.on_property, lk e.k) ]);
      data = (fun e -> [ Add (i e 0, e.k, lk (i e 5)) ]); expect = (fun e -> [ Has [ i e 0, ty e, lk (r e 0) ] ]) };
    { name = "cls-maxc1"; onto = (fun e -> [ Add (r e 0, e.o.max_cardinality, Int 0); Add (r e 0, e.o.on_property, lk e.k) ]);
      data = (fun e -> [ Add (i e 0, ty e, lk (r e 0)); Add (i e 0, e.k, lk (i e 1)) ]); expect = (fun _ -> [ Refused "owl/cls-maxc1" ]) };
    { name = "cls-maxqc1";
      onto = (fun e -> [ Add (r e 0, e.o.max_qualified_cardinality, Int 0); Add (r e 0, e.o.on_property, lk e.k); Add (r e 0, e.o.on_class, lk (c e 1)) ]);
      data = (fun e -> [ Add (i e 0, ty e, lk (r e 0)); Add (i e 0, e.k, lk (i e 1)); Add (i e 1, ty e, lk (c e 1)) ]); expect = (fun _ -> [ Refused "owl/cls-maxqc1" ]) };
    { name = "cls-maxqc2";
      onto = (fun e -> [ Add (r e 0, e.o.max_qualified_cardinality, Int 0); Add (r e 0, e.o.on_property, lk e.k); Add (r e 0, e.o.on_class, lk e.o.thing) ]);
      data = (fun e -> [ Add (i e 0, ty e, lk (r e 0)); Add (i e 0, e.k, lk (i e 1)) ]); expect = (fun _ -> [ Refused "owl/cls-maxqc2" ]) };
    { name = "cls-oo"; onto = (fun e -> [ Add (c e 0, e.o.one_of, lk (i e 0)); Add (c e 0, e.o.one_of, lk (i e 1)) ]);
      data = (fun e -> [ Add (i e 2, e.tx, Text "z") ]); expect = (fun e -> [ Has [ i e 0, ty e, lk (c e 0); i e 1, ty e, lk (c e 0) ] ]) };
    { name = "cax-sco"; onto = (fun e -> [ Add (c e 0, e.o.sub_class_of, lk (c e 1)); Add (c e 1, e.o.sub_class_of, lk (c e 2)) ]);
      data = (fun e -> [ Add (i e 0, ty e, lk (c e 0)) ]); expect = (fun e -> [ Has [ i e 0, ty e, lk (c e 1); i e 0, ty e, lk (c e 2) ] ]) };
    { name = "cax-eqc1"; onto = (fun e -> [ Add (c e 0, e.o.equivalent_class, lk (c e 1)) ]);
      data = (fun e -> [ Add (i e 0, ty e, lk (c e 0)) ]); expect = (fun e -> [ Has [ i e 0, ty e, lk (c e 1) ] ]) };
    { name = "cax-eqc2"; onto = (fun e -> [ Add (c e 0, e.o.equivalent_class, lk (c e 1)) ]);
      data = (fun e -> [ Add (i e 0, ty e, lk (c e 1)) ]); expect = (fun e -> [ Has [ i e 0, ty e, lk (c e 0) ] ]) };
    { name = "cax-dw"; onto = (fun e -> [ Add (c e 0, e.o.disjoint_with, lk (c e 1)) ]);
      data = (fun e -> [ Add (i e 0, ty e, lk (c e 0)); Add (i e 0, ty e, lk (c e 1)) ]); expect = (fun _ -> [ Refused "owl/cax-dw" ]) };
    { name = "cax-adc: AllDisjointClasses as its pairs"; onto = (fun e -> Owl.disjoint_classes e.o [ c e 0; c e 1; c e 2 ]);
      data = (fun e -> [ Add (i e 0, ty e, lk (c e 2)); Add (i e 0, ty e, lk (c e 1)) ]); expect = (fun _ -> [ Refused "owl/cax-dw" ]) };
    { name = "scm-cls, scm-op, scm-dp: nothing reflexive stored"; onto = (fun e -> [ Add (c e 0, e.o.sub_class_of, lk (c e 1)); Add (d e 0, e.o.property, lk e.k) ]); data = nodata;
      expect = (fun e -> [ Lacks [ c e 0, e.o.sub_class_of, lk (c e 0); c e 0, e.o.equivalent_class, lk (c e 0); d e 0, e.o.sub_property_of, lk e.k ] ]) };
    { name = "scm-sco"; onto = (fun e -> [ Add (c e 0, e.o.sub_class_of, lk (c e 1)); Add (c e 1, e.o.sub_class_of, lk (c e 2)) ]); data = nodata;
      expect = (fun e -> [ Has [ c e 0, e.o.sub_class_of, lk (c e 2) ] ]) };
    { name = "scm-eqc1"; onto = (fun e -> [ Add (c e 0, e.o.equivalent_class, lk (c e 1)) ]); data = nodata;
      expect = (fun e -> [ Has [ c e 0, e.o.sub_class_of, lk (c e 1); c e 1, e.o.sub_class_of, lk (c e 0) ] ]) };
    { name = "scm-eqc2"; onto = (fun e -> [ Add (c e 0, e.o.sub_class_of, lk (c e 1)); Add (c e 1, e.o.sub_class_of, lk (c e 0)) ]); data = nodata;
      expect = (fun e -> [ Has [ c e 0, e.o.equivalent_class, lk (c e 1) ] ]) };
    { name = "scm-spo";
      onto = (fun e -> [ Add (d e 0, e.o.property, lk e.k); Add (d e 0, e.o.sub_property_of, lk e.l); Add (d e 1, e.o.property, lk e.l); Add (d e 1, e.o.sub_property_of, lk e.j) ]);
      data = nodata; expect = (fun e -> [ Has [ d e 0, e.o.sub_property_of, lk e.j ] ]) };
    { name = "scm-eqp1"; onto = (fun e -> [ Add (d e 0, e.o.property, lk e.k); Add (d e 0, e.o.equivalent_property, lk e.l); Add (d e 1, e.o.property, lk e.l) ]);
      data = nodata; expect = (fun e -> [ Has [ d e 0, e.o.sub_property_of, lk e.l; d e 1, e.o.sub_property_of, lk e.k ] ]) };
    { name = "scm-eqp2";
      onto = (fun e -> [ Add (d e 0, e.o.property, lk e.k); Add (d e 0, e.o.sub_property_of, lk e.l); Add (d e 1, e.o.property, lk e.l); Add (d e 1, e.o.sub_property_of, lk e.k) ]);
      data = nodata; expect = (fun e -> [ Has [ d e 0, e.o.equivalent_property, lk e.l ] ]) };
    { name = "scm-dom1"; onto = (fun e -> [ Add (d e 0, e.o.property, lk e.k); Add (d e 0, e.o.domain, lk (c e 0)); Add (c e 0, e.o.sub_class_of, lk (c e 1)) ]);
      data = nodata; expect = (fun e -> [ Has [ d e 0, e.o.domain, lk (c e 1) ] ]) };
    { name = "scm-dom2";
      onto = (fun e -> [ Add (d e 1, e.o.property, lk e.l); Add (d e 1, e.o.domain, lk (c e 0)); Add (d e 0, e.o.property, lk e.k); Add (d e 0, e.o.sub_property_of, lk e.l) ]);
      data = nodata; expect = (fun e -> [ Has [ d e 0, e.o.domain, lk (c e 0) ] ]) };
    { name = "scm-rng1"; onto = (fun e -> [ Add (d e 0, e.o.property, lk e.k); Add (d e 0, e.o.range, lk (c e 0)); Add (c e 0, e.o.sub_class_of, lk (c e 1)) ]);
      data = nodata; expect = (fun e -> [ Has [ d e 0, e.o.range, lk (c e 1) ] ]) };
    { name = "scm-rng2";
      onto = (fun e -> [ Add (d e 1, e.o.property, lk e.l); Add (d e 1, e.o.range, lk (c e 0)); Add (d e 0, e.o.property, lk e.k); Add (d e 0, e.o.sub_property_of, lk e.l) ]);
      data = nodata; expect = (fun e -> [ Has [ d e 0, e.o.range, lk (c e 0) ] ]) };
    { name = "scm-hv";
      onto = (fun e -> [ Add (r e 0, e.o.has_value, lk (i e 5)); Add (r e 0, e.o.on_property, lk e.k); Add (r e 1, e.o.has_value, lk (i e 5)); Add (r e 1, e.o.on_property, lk e.l);
                         Add (d e 0, e.o.property, lk e.k); Add (d e 0, e.o.sub_property_of, lk e.l) ]);
      data = nodata; expect = (fun e -> [ Has [ r e 0, e.o.sub_class_of, lk (r e 1) ]; Lacks [ r e 1, e.o.sub_class_of, lk (r e 0) ] ]) };
    { name = "scm-svf1";
      onto = (fun e -> [ Add (r e 0, e.o.some_values_from, lk (c e 0)); Add (r e 0, e.o.on_property, lk e.k); Add (r e 1, e.o.some_values_from, lk (c e 1)); Add (r e 1, e.o.on_property, lk e.k);
                         Add (c e 0, e.o.sub_class_of, lk (c e 1)) ]);
      data = nodata; expect = (fun e -> [ Has [ r e 0, e.o.sub_class_of, lk (r e 1) ]; Lacks [ r e 1, e.o.sub_class_of, lk (r e 0) ] ]) };
    { name = "scm-svf2";
      onto = (fun e -> [ Add (r e 0, e.o.some_values_from, lk (c e 0)); Add (r e 0, e.o.on_property, lk e.k); Add (r e 1, e.o.some_values_from, lk (c e 0)); Add (r e 1, e.o.on_property, lk e.l);
                         Add (d e 0, e.o.property, lk e.k); Add (d e 0, e.o.sub_property_of, lk e.l) ]);
      data = nodata; expect = (fun e -> [ Has [ r e 0, e.o.sub_class_of, lk (r e 1) ]; Lacks [ r e 1, e.o.sub_class_of, lk (r e 0) ] ]) };
    { name = "scm-avf1";
      onto = (fun e -> [ Add (r e 0, e.o.all_values_from, lk (c e 0)); Add (r e 0, e.o.on_property, lk e.k); Add (r e 1, e.o.all_values_from, lk (c e 1)); Add (r e 1, e.o.on_property, lk e.k);
                         Add (c e 0, e.o.sub_class_of, lk (c e 1)) ]);
      data = nodata; expect = (fun e -> [ Has [ r e 0, e.o.sub_class_of, lk (r e 1) ] ]) };
    { name = "scm-avf2";
      onto = (fun e -> [ Add (r e 0, e.o.all_values_from, lk (c e 0)); Add (r e 0, e.o.on_property, lk e.k); Add (r e 1, e.o.all_values_from, lk (c e 0)); Add (r e 1, e.o.on_property, lk e.l);
                         Add (d e 0, e.o.property, lk e.k); Add (d e 0, e.o.sub_property_of, lk e.l) ]);
      data = nodata; expect = (fun e -> [ Has [ r e 1, e.o.sub_class_of, lk (r e 0) ]; Lacks [ r e 0, e.o.sub_class_of, lk (r e 1) ] ]) };
    { name = "scm-int"; onto = (fun e -> [ Add (c e 0, e.o.intersection_of, lk (c e 1)); Add (c e 0, e.o.intersection_of, lk (c e 2)) ]); data = nodata;
      expect = (fun e -> [ Has [ c e 0, e.o.sub_class_of, lk (c e 1); c e 0, e.o.sub_class_of, lk (c e 2) ] ]) };
    { name = "scm-uni"; onto = (fun e -> [ Add (c e 0, e.o.union_of, lk (c e 1)) ]); data = nodata; expect = (fun e -> [ Has [ c e 1, e.o.sub_class_of, lk (c e 0) ] ]) };
    (* table 4: equality, by the classes and the rewriting *)
    { name = "eq-ref, eq-sym, eq-trans"; onto = (fun _ -> []);
      data = (fun e -> [ Add (i e 0, e.o.same_as, lk (i e 1)); Add (i e 2, e.o.same_as, lk (i e 1)) ]); expect = (fun e -> [ Same [ i e 0; i e 1; i e 2 ]; Apart (i e 0, i e 3) ]) };
    { name = "eq-rep-s"; onto = (fun _ -> []); data = (fun e -> [ Add (i e 0, e.o.same_as, lk (i e 1)); Add (i e 0, e.k, lk (i e 5)) ]);
      expect = (fun e -> [ Has [ i e 1, e.k, lk (i e 5) ] ]) };
    { name = "eq-rep-o"; onto = (fun _ -> []); data = (fun e -> [ Add (i e 0, e.o.same_as, lk (i e 1)); Add (i e 5, e.k, lk (i e 0)) ]);
      expect = (fun e -> [ Has [ i e 5, e.k, lk (i e 1) ] ]) };
    { name = "eq-rep-p: a property is the same as no other";
      onto = (fun e -> [ Add (d e 0, e.o.property, lk e.k); Add (d e 0, e.o.functional, tru) ]);
      data = (fun e -> [ Add (i e 0, e.k, lk e.l); Add (i e 0, e.k, lk e.j) ]); expect = (fun _ -> [ Refused "a property is the same as no other" ]) };
    { name = "eq-diff1"; onto = (fun _ -> []); data = (fun e -> [ Add (i e 0, e.o.same_as, lk (i e 1)); Add (i e 0, e.o.different_from, lk (i e 1)) ]);
      expect = (fun _ -> [ Refused "owl/eq-diff1" ]) };
    { name = "eq-diff2, eq-diff3: AllDifferent as its pairs"; onto = (fun e -> Owl.all_different e.o [ i e 0; i e 1; i e 2 ]);
      data = (fun e -> [ Add (i e 3, e.o.same_as, lk (i e 0)); Add (i e 3, e.o.same_as, lk (i e 2)) ]); expect = (fun _ -> [ Refused "owl/eq-diff1" ]) };
    { name = "prp-fp"; onto = (fun e -> [ Add (d e 0, e.o.property, lk e.k); Add (d e 0, e.o.functional, tru) ]);
      data = (fun e -> [ Add (i e 0, e.k, lk (i e 1)); Add (i e 0, e.k, lk (i e 2)); Add (i e 2, e.l, lk (i e 6)) ]);
      expect = (fun e -> [ Same [ i e 1; i e 2 ]; Has [ i e 1, e.l, lk (i e 6) ] ]) };
    { name = "prp-fp over values: two different values are never the same";
      onto = (fun e -> [ Add (d e 0, e.o.property, lk e.age); Add (d e 0, e.o.functional, tru) ]);
      data = (fun e -> [ Add (i e 0, e.age, Int 5); Add (i e 0, e.age, Int 6) ]); expect = (fun _ -> [ Refused "owl/prp-fp" ]) };
    { name = "prp-ifp"; onto = (fun e -> [ Add (d e 0, e.o.property, lk e.k); Add (d e 0, e.o.inverse_functional, tru) ]);
      data = (fun e -> [ Add (i e 1, e.k, lk (i e 0)); Add (i e 2, e.k, lk (i e 0)); Add (i e 3, e.k, lk (i e 4)) ]);
      expect = (fun e -> [ Same [ i e 1; i e 2 ]; Apart (i e 1, i e 3) ]) };
    { name = "prp-key"; onto = (fun e -> [ Add (c e 0, e.o.has_key, lk e.k); Add (c e 0, e.o.has_key, lk e.l) ]);
      data = (fun e -> [ Add (i e 0, ty e, lk (c e 0)); Add (i e 1, ty e, lk (c e 0)); Add (i e 2, ty e, lk (c e 0));
                         Add (i e 0, e.k, lk (i e 5)); Add (i e 1, e.k, lk (i e 5)); Add (i e 2, e.k, lk (i e 5));
                         Add (i e 0, e.l, lk (i e 6)); Add (i e 1, e.l, lk (i e 6)); Add (i e 2, e.l, lk (i e 7)) ]);
      expect = (fun e -> [ Same [ i e 0; i e 1 ]; Apart (i e 0, i e 2) ]) };
    { name = "cls-maxc2"; onto = (fun e -> [ Add (r e 0, e.o.max_cardinality, Int 1); Add (r e 0, e.o.on_property, lk e.k) ]);
      data = (fun e -> [ Add (i e 0, ty e, lk (r e 0)); Add (i e 0, e.k, lk (i e 1)); Add (i e 0, e.k, lk (i e 2)) ]); expect = (fun e -> [ Same [ i e 1; i e 2 ] ]) };
    { name = "cls-maxqc3";
      onto = (fun e -> [ Add (r e 0, e.o.max_qualified_cardinality, Int 1); Add (r e 0, e.o.on_property, lk e.k); Add (r e 0, e.o.on_class, lk (c e 1)) ]);
      data = (fun e -> [ Add (i e 0, ty e, lk (r e 0)); Add (i e 0, e.k, lk (i e 1)); Add (i e 1, ty e, lk (c e 1)); Add (i e 0, e.k, lk (i e 2));
                         Add (i e 2, ty e, lk (c e 1)); Add (i e 0, e.k, lk (i e 3)) ]);
      expect = (fun e -> [ Same [ i e 1; i e 2 ]; Apart (i e 1, i e 3) ]) };
    { name = "cls-maxqc4";
      onto = (fun e -> [ Add (r e 0, e.o.max_qualified_cardinality, Int 1); Add (r e 0, e.o.on_property, lk e.k); Add (r e 0, e.o.on_class, lk e.o.thing) ]);
      data = (fun e -> [ Add (i e 0, ty e, lk (r e 0)); Add (i e 0, e.k, lk (i e 1)); Add (i e 0, e.k, lk (i e 2)) ]); expect = (fun e -> [ Same [ i e 1; i e 2 ] ]) } ]

let tmp = match Sys.getenv_opt "CEPHEUS_TMP" with Some d -> d | None -> Filename.get_temp_dir_name ()
let counter = ref 0

(* a database on the disk for a case; at its end closed and opened again: the frames replayed (derived facts,
   cepheus/same's among them) give the same facts, the same ones asserted *)
let on_disk f =
  incr counter;
  let dir = Filename.concat tmp (Printf.sprintf "owl-test-%d-%d" (Unix.getpid ()) !counter) in
  Fun.protect ~finally:(fun () -> C.rmrf dir) (fun () ->
      let db = ok (open_ dir) in
      (try f db with e -> close db; raise e);
      let all = C.user_facts (view db) and asserted = C.asserted_facts (view db) in
      close db;
      let db = ok (open_ dir) in
      C.check (F.equal (C.user_facts (view db)) all && F.equal (C.asserted_facts (view db)) asserted) "reopened: the same facts, the same asserted";
      close db)

let paths () =
  List.iter
    (fun (cs : case) ->
      run_case "fork" cs (setup (fork empty));
      Reason.specialise := false;
      Fun.protect ~finally:(fun () -> Reason.specialise := true) (fun () -> run_case "as written" cs (setup (fork empty)));
      run_case "late" cs (setup (fork empty));
      on_disk (fun db -> run_case "load" cs (setup db));
      on_disk (fun db -> run_case "change" cs (setup db)))
    cases

(* ---- the datatypes (table 8): held by the typed values ---- *)

let datatypes () =
  let e = setup (fork empty) in
  (* dt-type1, dt-type2: a value has its type; dt-not-type: a value of another type never enters *)
  (match write e.db [ Add (i e 0, e.age, Text "five") ] with
   | Error (Invalid _) -> incr C.checks
   | _ -> C.fail "dt-not-type: a text accepted as an int");
  (* dt-eq: equal data values are one fact; dt-diff: different ones are two *)
  ignore (ok (write e.db [ Add (i e 0, e.age, Int 5) ]));
  ignore (ok (write e.db [ Add (i e 0, e.age, Int 5); Add (i e 0, e.age, Int 6) ]));
  C.check (List.length (values (view e.db) (i e 0) e.age) = 2) "dt-eq, dt-diff: 5 once, 6 apart"

(* ---- random ontologies and data, against the checker ---- *)

let random_sequences seeds =
  for seed = 1 to seeds do
    let g = Rng.make seed in
    let pick a = a.(Rng.int g (Array.length a)) in
    let e = setup (fork empty) in
    let o = e.o in
    let cls = Array.init 6 (c e) and ind = Array.init 8 (i e) and rs = Array.init 3 (r e) and ds = Array.init 3 (d e) in
    let lp = [| e.k; e.l; e.j |] in
    let onto () =
      match Rng.int g 22 with
      | 0 -> Add (pick cls, o.sub_class_of, lk (pick cls))
      | 1 -> Add (pick cls, o.equivalent_class, lk (pick cls))
      | 2 -> Add (pick cls, o.intersection_of, lk (pick cls))
      | 3 -> Add (pick cls, o.union_of, lk (pick cls))
      | 4 -> Add (pick cls, o.one_of, lk (pick ind))
      | 5 -> Add (pick rs, o.on_property, lk (pick lp))
      | 6 -> Add (pick rs, o.some_values_from, lk (if Rng.int g 4 = 0 then o.thing else pick cls))
      | 7 -> Add (pick rs, o.all_values_from, lk (pick cls))
      | 8 -> Add (pick rs, o.has_value, lk (pick ind))
      | 9 -> Add (pick ds, o.property, lk (pick lp))
      | 10 -> Add (pick ds, o.domain, lk (pick cls))
      | 11 -> Add (pick ds, o.range, lk (pick cls))
      | 12 -> Add (pick ds, o.sub_property_of, lk (pick lp))
      | 13 -> Add (pick ds, o.equivalent_property, lk (pick lp))
      | 14 -> Add (pick ds, o.inverse_of, lk (pick lp))
      | 15 -> Add (pick ds, o.transitive, tru)
      | 16 -> Add (pick ds, o.symmetric, tru)
      | 17 -> Add (pick rs, o.chain_of, lk (pick lp))
      | 18 -> Add (pick rs, o.first, lk (pick lp))
      | 19 -> Add (pick rs, o.second, lk (pick lp))
      | 20 -> Add (pick cls, o.sub_class_of, lk (pick rs))
      | _ -> Add (pick rs, o.sub_class_of, lk (pick cls))
    in
    let data () = if Rng.int g 2 = 0 then Add (pick ind, o.type_, lk (pick (Array.append cls rs))) else Add (pick ind, pick lp, lk (pick ind)) in
    let asserted = ref [] in
    for step = 1 to 14 do
      let ops =
        if step <= 3 || Rng.int g 5 = 0 then List.init (1 + Rng.int g 4) (fun _ -> onto ())
        else if Rng.int g 3 = 0 && !asserted <> [] then
          List.filteri (fun _ _ -> Rng.int g 2 = 0) !asserted |> List.map (function Add (a, b, x) -> Retract (a, b, x) | x -> x)
        else List.init (1 + Rng.int g 5) (fun _ -> data ())
      in
      (match write e.db ops with
       | Ok _ ->
         List.iter (function Add _ as a -> asserted := a :: !asserted | Retract (a, b, x) -> asserted := List.filter (fun y -> y <> Add (a, b, x)) !asserted | _ -> ()) ops
       | Error err -> C.fail "seed %d step %d: refused: %s" seed step (message err));
      exact (Printf.sprintf "seed %d step %d" seed step) (view e.db)
    done
  done

(* ---- random equalities: sameAs, functional and inverse functional properties, keys, max cardinality 1, with
   retractions; a refusal must be the meaning's (two values made one, or a constraint broken), and an acceptance too ---- *)

let random_equality seeds =
  let only = Option.map int_of_string (Sys.getenv_opt "OWL_SEED") in
  for seed = 1 to seeds do
    if only = None || only = Some seed then begin
    let g = Rng.make (1000 + seed) in
    let pick a = a.(Rng.int g (Array.length a)) in
    let e = setup (fork empty) in
    let o = e.o in
    let cls = Array.init 4 (c e) and ind = Array.init 10 (i e) and rs = Array.init 2 (r e) and ds = Array.init 3 (d e) in
    let lp = [| e.k; e.l; e.j |] in
    let onto () =
      match Rng.int g 12 with
      | 0 -> Add (pick ds, o.property, lk (pick lp))
      | 1 -> Add (pick ds, o.functional, tru)
      | 2 -> Add (pick ds, o.inverse_functional, tru)
      | 3 -> Add (pick rs, o.max_cardinality, Int 1)
      | 4 -> Add (pick rs, o.on_property, lk (pick lp))
      | 5 -> Add (pick cls, o.has_key, lk (pick lp))
      | 6 -> Add (pick cls, o.sub_class_of, lk (pick cls))
      | 7 -> Add (pick ds, o.symmetric, tru)
      | 8 -> Add (pick ds, o.sub_property_of, lk (pick lp))
      | 9 -> Add (pick rs, o.max_qualified_cardinality, Int 1)
      | 10 -> Add (pick rs, o.on_class, lk (pick cls))
      | _ -> Add (pick ds, o.domain, lk (pick cls))
    in
    let data () =
      match Rng.int g 10 with
      | 0 | 1 -> Add (pick ind, o.same_as, lk (pick ind))
      | 2 -> Add (pick ind, o.different_from, lk (pick ind))
      | 3 | 4 -> Add (pick ind, o.type_, lk (pick (Array.append cls rs)))
      | _ -> Add (pick ind, pick lp, lk (pick ind))
    in
    let asserted = ref [] in
    for step = 1 to 16 do
      let ops =
        if step <= 3 || Rng.int g 6 = 0 then List.init (1 + Rng.int g 3) (fun _ -> onto ())
        else if Rng.int g 3 = 0 && !asserted <> [] then
          List.filteri (fun _ _ -> Rng.int g 2 = 0) !asserted |> List.map (function Add (a, b, x) -> Retract (a, b, x) | x -> x)
        else List.init (1 + Rng.int g 4) (fun _ -> data ())
      in
      let v0 = view e.db in
      (match write e.db ops with
       | Ok _ ->
         List.iter (function Add _ as a -> asserted := a :: !asserted | Retract (a, b, x) -> asserted := List.filter (fun y -> y <> Add (a, b, x)) !asserted | _ -> ()) ops
       | Error err ->
         (* the meaning of the state the write would make: refused there too *)
         let f = ref (C.asserted_facts v0) in
         List.iter (function Add (a, b, x) -> f := F.add (a, b, x) !f | Retract (a, b, x) -> f := F.remove (a, b, x) !f | _ -> ()) ops;
         let bad = ref false in
         let m, _ = C.least_eq ~ptyp:(ptyp v0) ~bad (C.rules_of v0) !f in
         C.check (!bad || C.violated (C.rules_of v0) m) "seed %d step %d: refused (%s), but the meaning holds no contradiction" seed step (message err));
      if only <> None then
        Printf.printf "step %d: %s -> %s\n%!" step
          (String.concat " " (List.map (function Add (a, b, x) -> Printf.sprintf "+[%d %d %s]" a b (Value.to_string x) | Retract (a, b, x) -> Printf.sprintf "-[%d %d %s]" a b (Value.to_string x) | _ -> "") ops))
          (match view e.db with v -> Printf.sprintf "group %d" (group v));
      exact (Printf.sprintf "equality seed %d step %d" seed step) (view e.db);
      (* and exactly the facts written are asserted (the rewriting leaves them where they were written) *)
      let mine = List.fold_left (fun s -> function Add (a, b, x) -> F.add (a, b, x) s | _ -> s) F.empty !asserted in
      let theirs = F.filter (fun (_, p, _) -> p >= Schema.first_prop && List.mem p (List.map (fun (n, _, _, _) -> Option.get (property (view e.db) n)) Owl.vocabulary @ [ e.k; e.l; e.j ]) && p <> o.builtin) (C.asserted_facts (view e.db)) in
      C.check (F.equal mine (F.filter (fun (_, p, _) -> p <> o.builtin) theirs)) "equality seed %d step %d: the facts written are asserted (%d written, %d asserted)" seed step (F.cardinal mine) (F.cardinal theirs)
    done
    end
  done

(* ---- an equality storm: a functional property that makes n things one ---- *)

let storm () =
  let e = setup (fork empty) in
  let o = e.o in
  ignore (ok (write e.db [ Add (d e 0, o.property, lk e.k); Add (d e 0, o.functional, tru) ]));
  let n = 3000 in
  let r = ok (write e.db (List.init n (fun k -> Add (-(k + 1), e.tx, Text (Printf.sprintf "y%d" k))))) in
  let ys = List.map snd (List.sort compare (List.map (fun (t, id) -> -t, id) r.things)) in
  let t0 = Unix.gettimeofday () in
  ignore (ok (write e.db (List.map (fun y -> Add (i e 0, e.k, Link y)) ys)));
  let dt = Unix.gettimeofday () -. t0 in
  let v = view e.db in
  C.check (List.length (same v (List.hd ys)) = n) "storm: one class of %d things" n;
  C.check (Store.count_prop v Schema.p_same = n - 1) "storm: %d facts of cepheus/same, not n^2 (%d)" (n - 1) (Store.count_prop v Schema.p_same);
  C.check (Store.count_prop v e.tx = (2 * n) - 1) "storm: every thing's own text stays, rewritten once onto the representative (%d)" (Store.count_prop v e.tx);
  Printf.printf "  %d things made one in %.3f s\n%!" n dt;
  (* past the budget: refused whole, the view unchanged *)
  let b0 = !Reason.budget_base and b1 = !Reason.budget_per in
  Reason.budget_base := 100;
  Reason.budget_per := 0;
  let e2 = setup (fork empty) in
  Reason.budget_base := b0;
  Reason.budget_per := b1;
  ignore (ok (write e2.db [ Add (d e2 0, e2.o.property, lk e2.k); Add (d e2 0, e2.o.functional, tru) ]));
  let r = ok (write e2.db (List.init 500 (fun k -> Add (-(k + 1), e2.tx, Text (Printf.sprintf "y%d" k))))) in
  let before = view e2.db in
  Reason.budget_base := 100;
  Reason.budget_per := 0;
  let res = write e2.db (List.init 500 (fun k -> Add (i e2 0, e2.k, Link (thing r (-(k + 1)))))) in
  Reason.budget_base := b0;
  Reason.budget_per := b1;
  (match res with
   | Error (Invalid m) -> C.check true "storm past the budget refused: %s" m; Printf.printf "  past the budget: %s\n%!" m
   | _ -> C.fail "storm past the budget: not refused");
  C.check (group (view e2.db) = group before && Store.count_prop (view e2.db) Schema.p_same = 0) "storm past the budget: nothing applied"

(* owl.Rl() of the Cesia package (cesia/cepheus/owl/owl.ce, read from the repository's root, where tools/test.sh runs)
   names each rule of Owl.rl once, and no other: its Define takes them from this library by name *)
let cesia_names () =
  let file = "cesia/cepheus/owl/owl.ce" in
  match In_channel.with_open_bin file In_channel.input_all with
  | exception Sys_error m -> C.fail "the Cesia package of OWL 2 RL is not readable here: %s" m
  | src ->
    (* the texts between quotes after "names = [", up to its "]" *)
    let rec find i = if i + 9 > String.length src then String.length src else if String.sub src i 9 = "names = [" then i + 9 else find (i + 1) in
    let stop = match String.index_from_opt src (find 0) ']' with Some j -> j | None -> String.length src in
    let rec scan i acc =
      match String.index_from_opt src i '"' with
      | Some a when a < stop -> (
        match String.index_from_opt src (a + 1) '"' with Some b -> scan (b + 1) (String.sub src (a + 1) (b - a - 1) :: acc) | None -> List.rev acc)
      | _ -> List.rev acc
    in
    let cesia = scan (find 0) [] in
    let o = ok (Owl.setup (fork empty)) in
    let lib = List.map (fun (r : rule) -> r.name) (Owl.rl o) in
    C.check (List.sort compare cesia = List.sort compare lib) "owl.Rl() of Cesia names the %d rules of Owl.rl (it names %d)" (List.length lib) (List.length cesia);
    C.check (List.length (List.sort_uniq compare cesia) = List.length cesia) "owl.Rl() of Cesia names each rule once"

let () =
  section "owl: each rule, on the five paths";
  paths ();
  (* the paths were taken: loads on their sorted prefix, changes of the templates' lists in the background *)
  C.check (!Reason.bulk_groups > 0) "loads reasoned on the path of large groups (%d)" !Reason.bulk_groups;
  C.check (Atomic.get Engine.changes_done > 0) "changes installed by the background path (%d)" (Atomic.get Engine.changes_done);
  Printf.printf "  %d loads on the path of large groups, %d changes in the background\n%!" !Reason.bulk_groups (Atomic.get Engine.changes_done);
  section "owl: the datatypes";
  datatypes ();
  let seeds = try int_of_string Sys.argv.(1) with _ -> 200 in
  section (Printf.sprintf "owl: random ontologies and data, %d seeds" seeds);
  random_sequences seeds;
  Reason.specialise := false;
  random_sequences (seeds / 4);
  Reason.specialise := true;
  section (Printf.sprintf "owl: random equalities, %d seeds" seeds);
  random_equality seeds;
  section "owl: an equality storm";
  storm ();
  section "owl: the Cesia package names the library's rules";
  cesia_names ();
  C.finish "owl"
