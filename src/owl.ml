(* OWL 2 RL as a library of rules (the reasoner design, section 5.16): the rules of the W3C's OWL 2 Profiles, section
   4.3 (Tables 4 to 9), written over a vocabulary of properties of their own (owl/Type, owl/SubClassOf, ...), in the
   W3C's form: generic rules over the ontology's facts, which the engine unfolds on them (Reason). A database gets OWL
   2 RL by defining these rules, as any rules.

   Cepheus has no RDF lists and keeps on a property thing only cepheus/ facts, so:
   - an axiom about a property is a fact of a *description* thing: [d, owl/Property, p] names the property, and d's
     other facts are its axioms ([d, owl/Domain, c], [d, owl/SubPropertyOf, q], [d, owl/Transitive, true]); one
     description a property, which the library's rules also give derived axioms to;
   - a list is the values of a many-valued property: an intersection's members ([C, owl/IntersectionOf, A]), a union's,
     a key's properties; cls-int1 and prp-key read every member at once, as templates (Rules.every);
   - a property chain is a chain thing of two links: [c, owl/ChainOf, p], [c, owl/First, p1], [c, owl/Second, p2];
   - the n-ary axioms AllDifferent, AllDisjointClasses and AllDisjointProperties are written as their pairs
     ([all_different] and the others below): what they mean, pairwise.
   owl:Thing and owl:Nothing are two things of the database, named by owl/Builtin. *)

type t = {
  type_ : int;  (* rdf:type: [x, owl/Type, C] *)
  same_as : int;
  different_from : int;
  sub_class_of : int;
  equivalent_class : int;
  disjoint_with : int;
  complement_of : int;
  intersection_of : int;
  union_of : int;
  one_of : int;
  has_key : int;
  on_property : int;
  some_values_from : int;
  all_values_from : int;
  has_value : int;
  max_cardinality : int;
  max_qualified_cardinality : int;
  on_class : int;
  property : int;  (* a description thing's property *)
  domain : int;
  range : int;
  sub_property_of : int;
  equivalent_property : int;
  inverse_of : int;
  property_disjoint_with : int;
  functional : int;
  inverse_functional : int;
  transitive : int;
  symmetric : int;
  asymmetric : int;
  irreflexive : int;
  chain_of : int;
  first : int;
  second : int;
  source_individual : int;
  assertion_property : int;
  target_individual : int;
  target_value : int;
  builtin : int;
  thing : int;  (* owl:Thing *)
  nothing : int;  (* owl:Nothing *)
}

(* the vocabulary, in the order of [t]'s properties: name, type, many, unique *)
let vocabulary : (string * Value.typ * bool * bool) list =
  let l n = "owl/" ^ n, Value.Tlink, true, false in
  let b n = "owl/" ^ n, Value.Tbool, false, false in
  [ l "Type"; l "SameAs"; l "DifferentFrom"; l "SubClassOf"; l "EquivalentClass"; l "DisjointWith"; l "ComplementOf";
    l "IntersectionOf"; l "UnionOf"; l "OneOf"; l "HasKey"; l "OnProperty"; l "SomeValuesFrom"; l "AllValuesFrom";
    l "HasValue"; ("owl/MaxCardinality", Value.Tint, true, false); ("owl/MaxQualifiedCardinality", Value.Tint, true, false);
    l "OnClass"; l "Property"; l "Domain"; l "Range"; l "SubPropertyOf"; l "EquivalentProperty"; l "InverseOf";
    l "PropertyDisjointWith"; b "Functional"; b "InverseFunctional"; b "Transitive"; b "Symmetric"; b "Asymmetric";
    b "Irreflexive"; l "ChainOf"; l "First"; l "Second"; l "SourceIndividual"; l "AssertionProperty";
    l "TargetIndividual"; ("owl/TargetValue", Value.Ttext, true, false); ("owl/Builtin", Value.Ttext, false, true) ]

(* the record of the vocabulary's ids, in [vocabulary]'s order, and the two built-in things *)
let make (ids : int list) ~thing ~nothing =
  match Array.of_list ids with
  | [| type_; same_as; different_from; sub_class_of; equivalent_class; disjoint_with; complement_of; intersection_of;
       union_of; one_of; has_key; on_property; some_values_from; all_values_from; has_value; max_cardinality;
       max_qualified_cardinality; on_class; property; domain; range; sub_property_of; equivalent_property; inverse_of;
       property_disjoint_with; functional; inverse_functional; transitive; symmetric; asymmetric; irreflexive; chain_of;
       first; second; source_individual; assertion_property; target_individual; target_value; builtin |] ->
    { type_; same_as; different_from; sub_class_of; equivalent_class; disjoint_with; complement_of; intersection_of;
      union_of; one_of; has_key; on_property; some_values_from; all_values_from; has_value; max_cardinality;
      max_qualified_cardinality; on_class; property; domain; range; sub_property_of; equivalent_property; inverse_of;
      property_disjoint_with; functional; inverse_functional; transitive; symmetric; asymmetric; irreflexive; chain_of;
      first; second; source_individual; assertion_property; target_individual; target_value; builtin; thing; nothing }
  | _ -> invalid_arg "Owl.make: the ids of the vocabulary"

(* ---- the rules ---- *)

let pat e p v : Query.pattern = { e; p; v }

(* a rule, its variables numbered densely in the order they appear (a property variable is prop_var of its number) *)
let rule name (where : Query.pattern list) (head : Rules.head) : Rules.t =
  let map = Hashtbl.create 8 and n = ref 0 in
  let var k = match Hashtbl.find_opt map k with Some j -> j | None -> let j = !n in Hashtbl.replace map k j; incr n; j in
  let term : Query.term -> Query.term = function Var k -> Var (var k) | t -> t in
  let prop p = if p < 0 then Rules.prop_var (var (Rules.pvar p)) else p in
  let pat (a : Query.pattern) =
    let e = term a.e in
    let p = prop a.p in
    { Query.e; p; v = term a.v }
  in
  let where = List.map pat where in
  let head = match head with Rules.Give h -> Rules.Give (pat h) | Never -> Never in
  { name = "owl/" ^ name; vars = !n; where; ranges = []; head }

(* the rules without equality (step 6, part 1): tables 5, 6, 7 and 9 of the W3C, but for the rules that give
   owl:sameAs (prp-fp, prp-ifp, prp-key, cls-maxc2, cls-maxqc3, cls-maxqc4) and table 4 (equality) *)
let rules_without_equality (t : t) : Rules.t list =
  let v k = Query.Var k and pv k = Rules.prop_var k in
  let tru = Query.Val (Value.Bool true) in
  let give e p x = Rules.Give (pat e p x) in
  let ty = t.type_ in
  (* variable names: a b c d (things of the ontology), p q r (property variables), x y z u w (data) *)
  let a = v 0 and b = v 1 and c = v 2 and d = v 3 and x = v 4 and y = v 5 and z = v 6 and u = v 7 and w = v 8 in
  let p = 9 and q = 10 and r = 11 in
  let c1 = v 12 and c2 = v 13 and c3 = v 14 and m = v 15 in
  let thing = Query.Thing t.thing and nothing = Query.Thing t.nothing in
  [ (* table 5: properties *)
    rule "prp-dom" [ pat a t.property (v p); pat a t.domain c; pat x (pv p) y ] (give x ty c);
    rule "prp-rng" [ pat a t.property (v p); pat a t.range c; pat x (pv p) y ] (give y ty c);
    rule "prp-irp" [ pat a t.property (v p); pat a t.irreflexive tru; pat x (pv p) x ] Never;
    rule "prp-symp" [ pat a t.property (v p); pat a t.symmetric tru; pat x (pv p) y ] (give y (pv p) x);
    rule "prp-asyp" [ pat a t.property (v p); pat a t.asymmetric tru; pat x (pv p) y; pat y (pv p) x ] Never;
    rule "prp-trp" [ pat a t.property (v p); pat a t.transitive tru; pat x (pv p) y; pat y (pv p) z ] (give x (pv p) z);
    rule "prp-spo1" [ pat a t.property (v p); pat a t.sub_property_of (v q); pat x (pv p) y ] (give x (pv q) y);
    rule "prp-spo2" [ pat a t.chain_of (v r); pat a t.first (v p); pat a t.second (v q); pat u (pv p) w; pat w (pv q) z ] (give u (pv r) z);
    rule "prp-eqp1" [ pat a t.property (v p); pat a t.equivalent_property (v q); pat x (pv p) y ] (give x (pv q) y);
    rule "prp-eqp2" [ pat a t.property (v p); pat a t.equivalent_property (v q); pat x (pv q) y ] (give x (pv p) y);
    rule "prp-pdw" [ pat a t.property (v p); pat a t.property_disjoint_with (v q); pat x (pv p) y; pat x (pv q) y ] Never;
    rule "prp-inv1" [ pat a t.property (v p); pat a t.inverse_of (v q); pat x (pv p) y ] (give y (pv q) x);
    rule "prp-inv2" [ pat a t.property (v p); pat a t.inverse_of (v q); pat x (pv q) y ] (give y (pv p) x);
    rule "prp-npa1" [ pat a t.source_individual x; pat a t.assertion_property (v p); pat a t.target_individual y; pat x (pv p) y ] Never;
    rule "prp-npa2" [ pat a t.source_individual x; pat a t.assertion_property (v p); pat a t.target_value z; pat x (pv p) z ] Never;
    (* table 6: classes *)
    rule "cls-nothing2" [ pat x ty nothing ] Never;
    rule "cls-int1" [ pat c (Rules.every t.intersection_of) m; pat y ty m ] (give y ty c);
    rule "cls-int2" [ pat c t.intersection_of m; pat y ty c ] (give y ty m);
    rule "cls-uni" [ pat c t.union_of m; pat y ty m ] (give y ty c);
    rule "cls-com" [ pat c1 t.complement_of c2; pat x ty c1; pat x ty c2 ] Never;
    rule "cls-svf1" [ pat a t.some_values_from c; pat a t.on_property (v p); pat u (pv p) w; pat w ty c ] (give u ty a);
    rule "cls-svf2" [ pat a t.some_values_from thing; pat a t.on_property (v p); pat u (pv p) w ] (give u ty a);
    rule "cls-avf" [ pat a t.all_values_from c; pat a t.on_property (v p); pat u ty a; pat u (pv p) w ] (give w ty c);
    rule "cls-hv1" [ pat a t.has_value y; pat a t.on_property (v p); pat u ty a ] (give u (pv p) y);
    rule "cls-hv2" [ pat a t.has_value y; pat a t.on_property (v p); pat u (pv p) y ] (give u ty a);
    rule "cls-maxc1" [ pat a t.max_cardinality (Val (Value.Int 0)); pat a t.on_property (v p); pat u ty a; pat u (pv p) y ] Never;
    rule "cls-maxqc1"
      [ pat a t.max_qualified_cardinality (Val (Value.Int 0)); pat a t.on_property (v p); pat a t.on_class c; pat u ty a; pat u (pv p) y; pat y ty c ] Never;
    rule "cls-maxqc2" [ pat a t.max_qualified_cardinality (Val (Value.Int 0)); pat a t.on_property (v p); pat a t.on_class thing; pat u ty a; pat u (pv p) y ] Never;
    rule "cls-oo" [ pat c t.one_of y ] (give y ty c);
    (* table 7: class axioms *)
    rule "cax-sco" [ pat c1 t.sub_class_of c2; pat x ty c1 ] (give x ty c2);
    rule "cax-eqc1" [ pat c1 t.equivalent_class c2; pat x ty c1 ] (give x ty c2);
    rule "cax-eqc2" [ pat c1 t.equivalent_class c2; pat x ty c2 ] (give x ty c1);
    rule "cax-dw" [ pat c1 t.disjoint_with c2; pat x ty c1; pat x ty c2 ] Never;
    (* table 9: the schema *)
    rule "scm-sco" [ pat c1 t.sub_class_of c2; pat c2 t.sub_class_of c3 ] (give c1 t.sub_class_of c3);
    rule "scm-eqc1" [ pat c1 t.equivalent_class c2 ] (give c1 t.sub_class_of c2);
    rule "scm-eqc1b" [ pat c1 t.equivalent_class c2 ] (give c2 t.sub_class_of c1);
    rule "scm-eqc2" [ pat c1 t.sub_class_of c2; pat c2 t.sub_class_of c1 ] (give c1 t.equivalent_class c2);
    rule "scm-spo" [ pat a t.sub_property_of x; pat b t.property x; pat b t.sub_property_of y ] (give a t.sub_property_of y);
    rule "scm-eqp1" [ pat a t.equivalent_property x ] (give a t.sub_property_of x);
    rule "scm-eqp1b" [ pat a t.property x; pat a t.equivalent_property y; pat b t.property y ] (give b t.sub_property_of x);
    rule "scm-eqp2" [ pat a t.property x; pat a t.sub_property_of y; pat b t.property y; pat b t.sub_property_of x ] (give a t.equivalent_property y);
    rule "scm-dom1" [ pat a t.domain c1; pat c1 t.sub_class_of c2 ] (give a t.domain c2);
    rule "scm-dom2" [ pat b t.property x; pat b t.domain c; pat a t.sub_property_of x ] (give a t.domain c);
    rule "scm-rng1" [ pat a t.range c1; pat c1 t.sub_class_of c2 ] (give a t.range c2);
    rule "scm-rng2" [ pat b t.property x; pat b t.range c; pat a t.sub_property_of x ] (give a t.range c);
    rule "scm-hv" [ pat c1 t.has_value z; pat c1 t.on_property x; pat c2 t.has_value z; pat c2 t.on_property y; pat a t.property x; pat a t.sub_property_of y ] (give c1 t.sub_class_of c2);
    rule "scm-hvb" [ pat c1 t.has_value z; pat c1 t.on_property x; pat c2 t.has_value z; pat c2 t.on_property x ] (give c1 t.sub_class_of c2);
    rule "scm-svf1" [ pat c1 t.some_values_from d; pat c1 t.on_property x; pat c2 t.some_values_from c3; pat c2 t.on_property x; pat d t.sub_class_of c3 ] (give c1 t.sub_class_of c2);
    rule "scm-svf1b" [ pat c1 t.some_values_from d; pat c1 t.on_property x; pat c2 t.some_values_from d; pat c2 t.on_property x ] (give c1 t.sub_class_of c2);
    rule "scm-svf2" [ pat c1 t.some_values_from d; pat c1 t.on_property x; pat c2 t.some_values_from d; pat c2 t.on_property y; pat a t.property x; pat a t.sub_property_of y ] (give c1 t.sub_class_of c2);
    rule "scm-avf1" [ pat c1 t.all_values_from d; pat c1 t.on_property x; pat c2 t.all_values_from c3; pat c2 t.on_property x; pat d t.sub_class_of c3 ] (give c1 t.sub_class_of c2);
    rule "scm-avf1b" [ pat c1 t.all_values_from d; pat c1 t.on_property x; pat c2 t.all_values_from d; pat c2 t.on_property x ] (give c1 t.sub_class_of c2);
    rule "scm-avf2" [ pat c1 t.all_values_from d; pat c1 t.on_property x; pat c2 t.all_values_from d; pat c2 t.on_property y; pat a t.property x; pat a t.sub_property_of y ] (give c2 t.sub_class_of c1);
    rule "scm-int" [ pat c t.intersection_of m ] (give c t.sub_class_of m);
    rule "scm-uni" [ pat c t.union_of m ] (give m t.sub_class_of c) ]

(* equality (step 6, part 2): table 4 and the rules that give owl:sameAs. A rule whose head is [x cepheus/same y] makes
   x and y one thing: the engine keeps the classes of equal things and rewrites their facts onto one representative
   (Motik, Nenov, Piro, Horrocks, AAAI 2015), so eq-ref, eq-sym, eq-trans and eq-rep-s, eq-rep-p, eq-rep-o are its
   own: no rule of theirs is written. owl/eq makes owl/SameAs such a rule's premise. *)
let equality (t : t) : Rules.t list =
  let v k = Query.Var k and pv k = Rules.prop_var k in
  let tru = Query.Val (Value.Bool true) in
  let same a b = Rules.Give (pat a Schema.p_same b) in
  let ty = t.type_ in
  let a = v 0 and c = v 2 and x = v 4 and y = v 5 and z = v 6 and u = v 7 in
  let p = 9 in
  let y1 = v 16 and y2 = v 17 and x1 = v 18 and x2 = v 19 and m = v 20 in
  let one = Query.Val (Value.Int 1) and thing = Query.Thing t.thing in
  [ rule "eq" [ pat x t.same_as y ] (same x y);
    rule "eq-diff1" [ pat x t.different_from x ] Never;
    rule "prp-fp" [ pat a t.property (v p); pat a t.functional tru; pat x (pv p) y1; pat x (pv p) y2 ] (same y1 y2);
    rule "prp-ifp" [ pat a t.property (v p); pat a t.inverse_functional tru; pat x1 (pv p) y; pat x2 (pv p) y ] (same x1 x2);
    rule "prp-key" [ pat c (Rules.every t.has_key) m; pat x ty c; pat y ty c; pat x (pv 20) z; pat y (pv 20) z ] (same x y);
    rule "cls-maxc2" [ pat a t.max_cardinality one; pat a t.on_property (v p); pat u ty a; pat u (pv p) y1; pat u (pv p) y2 ] (same y1 y2);
    rule "cls-maxqc3"
      [ pat a t.max_qualified_cardinality one; pat a t.on_property (v p); pat a t.on_class c; pat u ty a; pat u (pv p) y1; pat y1 ty c; pat u (pv p) y2; pat y2 ty c ]
      (same y1 y2);
    rule "cls-maxqc4" [ pat a t.max_qualified_cardinality one; pat a t.on_property (v p); pat a t.on_class thing; pat u ty a; pat u (pv p) y1; pat u (pv p) y2 ] (same y1 y2) ]

let rl (t : t) = rules_without_equality t @ equality t

(* ---- the n-ary axioms, as their pairs ---- *)

let rec pairs = function [] -> [] | x :: rest -> List.map (fun y -> x, y) rest @ pairs rest

(* AllDifferent(x1 ... xn): [xi, owl/DifferentFrom, xj] for i < j (eq-diff2, eq-diff3) *)
let all_different (t : t) xs = List.map (fun (a, b) -> Resolve.Add (a, t.different_from, Value.Link b)) (pairs (List.sort_uniq compare xs))

(* AllDisjointClasses(c1 ... cn): [ci, owl/DisjointWith, cj] for i < j (cax-adc) *)
let disjoint_classes (t : t) cs = List.map (fun (a, b) -> Resolve.Add (a, t.disjoint_with, Value.Link b)) (pairs (List.sort_uniq compare cs))

(* AllDisjointProperties(p1 ... pn), each pi with its description thing di: [di, owl/PropertyDisjointWith, pj] for i < j
   (prp-adp) *)
let disjoint_properties (t : t) (dps : (int * int) list) =
  List.map (fun ((d, _), (_, p)) -> Resolve.Add (d, t.property_disjoint_with, Value.Link p)) (pairs (List.sort_uniq compare dps))
