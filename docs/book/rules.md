# Rules

A **rule** derives facts from facts: "if x is an invoice, and an invoice is a kind of document, then x is a document".
Cepheus keeps the facts its rules derive, the **derived facts**, as facts like any other, up to date at every write:
a question reads them at the speed of any fact, and knows nothing of rules. This page tells what a rule is, how the
writer keeps its consequences exact (the algorithms, and why these ones), what a write with rules costs, and what it
promises. The exact promises are G17 to G20 in [guarantees](guarantees.md); the numbers are in
[benchmarks](benchmarks.md#rules-2026-11-08); every term is also in the [glossary](glossary.md).

## A rule is a question with a conclusion

A rule is written as a question is ([concepts](concepts.md#questions)): **patterns** `[thing, property, value]` whose
thing and value are constants or variables, and optional ranges on int, date and money variables; and a **head**, one
more pattern, the fact the rule gives for each answer of its body. This is **Datalog**, the rule language of deductive
databases: a rule `H ← B1, …, Bn` says that whenever B1 to Bn are facts for some values of the variables, H is a fact
for the same values (Abiteboul, Hull, Vianu, *Foundations of Databases*, 1995, chapters 12-13 [Abiteboul 1995]).

```ocaml
open Cepheus

let () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ ty; parent ]) = declare db [ prop ~many:true "thing/type" Tlink; prop ~many:true "class/parent" Tlink ] in
  (* three classes, each a thing: an invoice is a kind of document, a document a kind of record *)
  let r = Result.get_ok (write db [ Add (-1, parent, Link (-2)); Add (-2, parent, Link (-3)) ]) in
  let invoice = thing r (-1) and document = thing r (-2) and record = thing r (-3) in
  (* x has type c, c is a kind of d: x has type d *)
  let is_a =
    { name = "is-a"; vars = 3; where = [ { e = Var 0; p = ty; v = Var 1 }; { e = Var 1; p = parent; v = Var 2 } ];
      ranges = []; head = Give { e = Var 0; p = ty; v = Var 2 } }
  in
  ignore (Result.get_ok (define db [ is_a ]));
  let r = Result.get_ok (write db [ Add (-1, ty, Link invoice) ]) in
  let x = thing r (-1) in
  let v = view db in
  List.iter (fun t -> Printf.printf "x has type %s\n" (Value.to_string t)) (values v x ty);
  let rec show indent = function
    | Given g -> Printf.printf "%sgiven [#%d %d %s]\n" indent g.e g.p (Value.to_string g.v)
    | By b ->
      Printf.printf "%s[#%d %d %s] by %s, from\n" indent b.e b.p (Value.to_string b.v) b.rule;
      List.iter (show (indent ^ "  ")) b.from
  in
  Option.iter (show "") (why v x ty (Link record));
  (* a fact only derived cannot be retracted: its premises would derive it again *)
  (match write db [ Retract (x, ty, Link document) ] with
   | Error e -> print_endline (message e)
   | Ok _ -> ());
  (* retract the premise: what it alone gave goes *)
  ignore (Result.get_ok (write db [ Retract (x, ty, Link invoice) ]));
  Printf.printf "x has %d types\n" (List.length (values (view db) x ty))
```

```output
x has type #65536
x has type #65537
x has type #65538
[#65539 16 #65538] by is-a, from
  [#65539 16 #65537] by is-a, from
    given [#65539 16 #65536]
    given [#65536 17 #65537]
  given [#65537 17 #65538]
invalid: [#65539 thing/type #65537] is derived by rule is-a from [#65539 thing/type #65536] and [#65536 class/parent #65537]: retract one of those
x has 0 types
```

- The rule is **recursive**: its head's property, `thing/type`, is also in its body, so a derived fact (x is a
  document) can start the rule again (x is a record). Recursion is what a question alone cannot do: "every kind of
  document", at any depth.
The classes are things (65536 the invoice class, 65537 the document class, 65538 the record class); x is 65539;
property 16 is `thing/type`, 17 `class/parent`.

- The writer derived x's two types **in x's own group**, before the write returned: the group's frame on disk holds
  them (G1, G2), and every view from that group on shows them.
- **Why** gave a proof: x is a record by `is-a`, from "x is a document" (itself by `is-a`, from two asserted facts)
  and "a document is a record" (asserted).
- Retracting "x is a document" is refused: a rule derives it, and would derive it again; the message names the rule
  and the asserted facts to retract instead. Retracting the premise "x is an invoice" takes away the two types it
  alone gave, in the same group.

The rules of a rule, checked when it is written (an error is `Invalid`, naming the rule):
- **Range restriction** (also called *safety*): every variable of the head appears in a pattern of the body. So a rule
  gives facts only about things and values the database already holds, and the set of derived facts is finite.
- **Types**: a variable has one type, from the patterns it appears in, as in a question; the head's property must exist,
  must not be a `cepheus/` property, and must take the head value's type.
- **No new thing**: a head names variables of the body or existing things. (Datalog with new things in heads,
  *existential rules*, can derive without end; Datalog without them always ends: its *least model* below is finite.)
- A pattern's property is a constant, as in a question, or a variable bound by another pattern
  ([below](#a-property-as-a-variable-the-w3cs-form-of-owls-rules)); a body may hold `Not`s and a head an aggregate
  (`Sum`, `Count`, `Min`, `Max`), with rules of their own ([below](#negation-and-aggregates-strata)).

## What the database holds: the least model

The facts a program writes are the **asserted** facts (the extensional database, EDB, of Datalog's vocabulary); the
rules add the **derived** facts (the intensional database, IDB). Cepheus holds exactly the **least model**: the
smallest set of facts that contains the asserted ones and is closed under the rules (nothing more can be derived from
it). It exists and is unique for Datalog without negation: it is the least fixpoint of the operator "add every head
the rules give over the current facts", reached by applying the operator until nothing changes ([Abiteboul
1995], chapter 12). This is **G17**: every view —
any group, any process, a fork, after a crash — holds the least model of its asserted facts under the rules defined
at its group, and a derived fact is in the view if and only if it has a proof.

Each fact remembers whether it is asserted. A fact can be both (a program asserted it, and a rule derives it):

| the program writes | the fact was | it becomes | the frame's kind |
|---|---|---|---|
| `Add` | absent | asserted | 1 `Added` |
| `Add` | derived only | asserted (and still derived) | 4 `Now_asserted` |
| `Retract` | asserted, and no rule derives it | absent | 0 `Retracted` |
| `Retract` | asserted, and a rule still derives it | derived only: it stays | 5 `Now_derived` |
| `Retract` | derived only | refused: `Invalid "[#x p v] is derived by rule R from …: retract one of those"` | — |

The last line is a choice ([choices](#the-choices-behind-this-design)): a derived fact cannot be retracted, since
its premises would derive it again; the message names the rule and the facts it came from, which is what a program
can retract.

## How the writer keeps it: semi-naive evaluation

Recomputing the least model after each write would cost the whole database at each write. The writer instead works
on what each group changes, the **delta** ($\Delta$) of the group, and derives only what the change makes derivable.

**Insertion, by semi-naive evaluation** (Bancilhon and Ramakrishnan 1986 [Bancilhon 1986], §3.2.2: evaluate "the
differential … instead of the entire" set at each step). The group's asserted additions are round 0. In round $r$, each
fact of round $r$ is matched to each body atom of each rule where it fits; the other atoms are joined over the facts:
those before the matched atom over facts of rounds before $r$, those after it over facts up to $r$. Every rule instance
(a rule with a fact for each of its atoms) is so enumerated exactly once, at its newest fact — the *semi-naive
property* (Ramakrishnan, Srivastava, Sudarshan 1990 [Ramakrishnan 1990]) — and the heads that are not facts yet make
round $r + 1$. When a round makes nothing new, the group's derived facts are complete.

```text
round 0   x type GraduateStudent              (asserted)
          x memberOf dept, x advisor p, ...   (asserted)
round 1   x type Person                       GraduateStudent ⊑ Person
          dept member x                       member is the inverse of memberOf
          x degreeFrom u                      undergraduateDegreeFrom ⊑ degreeFrom
round 2   u hasAlumnus x                      hasAlumnus is the inverse of degreeFrom
          x type Student                      Student ≡ Person ⊓ ∃takesCourse.Course
          ...
```

The work is the number of rule instances found, each paid once: $\Theta(D)$ for $D$ derivations. The cost model of a group is
then $D \times (\text{the cost of a derivation: its joins and the test of its head}) + \text{the new facts} \times (\text{putting a fact into the view})$;
[benchmarks](benchmarks.md#rules-2026-11-08) measures both.

**How a plan joins.** Each rule is compiled once, when the rules change, into one closure per body atom (a *plan*:
the atom matched to a given fact, the others joined in a fixed order), as Feeley and Lapalme compile code to closures
[Feeley 1987]; nothing is interpreted per fact. The order of the other atoms is chosen from the store's exact counts:
the atom with the fewest candidates first. A constant is not selective (`[x, type, Person]` has tens of thousands of
rows); a variable bound by an earlier atom usually is (`[x, takesCourse, c]` with x bound: a handful). Plans are
dispatched by property, and by (property, value) for an atom whose value is a constant: a fact of `type` starts only
the plans of its class.

## Transitive closures: the closure module

A **transitive** property relates a thing to everything it reaches: "a research group is part of a department, a
department part of a university, so the group is part of the university". Two rule shapes say it, and the writer
recognises both:

```text
prp-trp (OWL 2 RL's rule):      [x T y] [y T z] -> [x T z]           the edges and the closure in one property
the linear pair:                [x E y] -> [x T y]
                                [x E y] [y T z] -> [x T z]           the edges E apart from the closure T
```

Run as rules, they derive each closure fact many times: prp-trp derives $(x, z)$ once for every $y$ between them, so
a chain of $n$ things costs about $n^3/6$ derivations for $n^2/2$ facts (166 a fact at $n = 500$, the design's
measure); the linear rule once for every edge out of $x$ on a path to $z$. A **closure module** (Hu, Motik, Horrocks
[Hu 2019], [Hu 2022]) finds each new fact of the closure once instead, by walks:

- **From scratch**, at the module's first work in a group whose state before held no fact of T, or when its rules
  are new: the graph's strong components (Tarjan [Tarjan 1972]), in an order where a component comes after every
  component it reaches, and each component's targets the union of its successors' with them (the reach of a
  component is shared by its members: Nuutila [Nuutila 1995]). Each target is tried once for each successor, each
  new fact made once for each source, with no hash test: the facts present already are exactly the inputs, skipped by
  a mark.
- **Incrementally**, for a new edge $(a, b)$ over a closure already in the database: the new facts are the things
  that reach $a$ (and $a$) times $b$ and what $b$ reaches, minus those present. With prp-trp the closure is closed, so
  "what reaches $a$" is one lookup of $T$'s facts into $a$; with the linear pair it is a walk back over $E$, and a new
  fact of $T$ given another way (asserted, or by another rule) reaches back along $E$ the same way.
- The module's facts join the next round of semi-naive evaluation like any derived fact, so the other rules see them;
  when nothing else reads $T$ or gives $T$ or $E$, a load's closure goes straight to the group's output.
- **Retraction by walks**, when no other rule gives $T$ or $E$ (so the edges are exactly the facts the group leaves
  asserted: prp-trp's $T$, or $E$): the sources whose targets may shrink are the retracted edges' starts and what
  reaches them; their new targets are computed as from scratch, over their strong components, their successors first,
  a thing that reaches no retracted edge keeping its targets whole (they cannot change); what a source held beyond its
  new targets goes, exactly the facts left without a path (Hu, Motik, Horrocks [Hu 2022]: small deletions in 1 s with
  modules against 585 s by B/F). The losses reach the other rules as B/F's do, and every loss counts against the
  budget. Otherwise (another rule gives $T$ or $E$) B/F decides, through the two rules' plans: exact for any Datalog
  program, slower on deep closures.

A property is closed by the module when its rules have exactly one of these shapes (distinct variables, no
constant, no range), it links things to things, takes many values and none is unique. Another rule on the same
property runs as a rule beside it.

## A property as a variable: the W3C's form of OWL's rules

OWL 2 RL's rules are written over the ontology's facts, with the property a variable: `prp-dom` says
"if $p$'s domain is $c$ and $x$ has a value of $p$, $x$ is a $c$" ([W3C 2012], §4.3). A pattern's property may be a
variable, `prop_var k` for `?k`:

```text
[c, domainOf, ?p] [x, ?p, y] -> [x, type, c]          prp-dom
[a, transitive, ?p] [x, ?p, y] [y, ?p, z] -> [x, ?p, z]   prp-trp over the ontology
```

- **Bound by a constant**: another pattern of the body, whose property is a constant, has `?k` as its thing or its
  value, so no pattern scans every fact (checked when the rule is written).
- **Types at the instance**: a value read under a variable property has that property's type; a variable that
  appears only there takes it, and every other pattern it appears in must agree, or the instance does not exist. A
  fact a head gives must fit its property (a property of the application, of the value's type, about a thing), or
  the group is refused, naming the rule: `rule prp-spo1 gives worksFor a value of another type`.
- In a property thing (ids 16 to 65535) only `cepheus/` facts are kept, so an axiom about a property names it as a
  value: "the domain of `advisor` is `Person`" is `[Person, domainOf, advisor]`, and "`headOf` is a subproperty of
  `worksFor`" is a thing of its own, `[a, subProperty, headOf] [a, superProperty, worksFor]`.

```ocaml
open Cepheus

let () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ ty; domain_of; advisor; part_of ]) =
    declare db [ prop ~many:true "thing/type" Tlink; prop ~many:true "onto/domainOf" Tlink;
                 prop ~many:true "person/advisor" Tlink; prop ~many:true "org/partOf" Tlink ]
  in
  let x = Var 0 and y = Var 1 and z = Var 2 in
  (* prp-dom over the ontology's facts: c is the domain of ?2, x has a value of ?2: x is a c *)
  let prp_dom =
    { name = "prp-dom"; vars = 4; where = [ { e = Var 3; p = domain_of; v = Var 2 }; { e = x; p = prop_var 2; v = y } ];
      ranges = []; head = Give { e = x; p = ty; v = Var 3 } }
  in
  (* a transitive property: the closure module keeps it *)
  let part = { name = "part-of"; vars = 3; where = [ { e = x; p = part_of; v = y }; { e = y; p = part_of; v = z } ];
               ranges = []; head = Give { e = x; p = part_of; v = z } } in
  ignore (Result.get_ok (define db [ prp_dom; part ]));
  (* the class Person, and an axiom about a property: its domain *)
  let person = thing (Result.get_ok (write db [ Add (-1, domain_of, Link advisor) ])) (-1) in
  let r = Result.get_ok (write db [ Add (-1, advisor, Link (-2)) ]) in
  let ada = thing r (-1) in
  let r = Result.get_ok (write db [ Add (-1, part_of, Link (-2)); Add (-2, part_of, Link (-3)) ]) in
  let group = thing r (-1) in
  let v = view db in
  let show l = String.concat ", " (List.map Value.to_string l) in
  Printf.printf "ada's types: %s (Person is %d)\n" (show (values v ada ty)) person;
  Printf.printf "the group is part of: %s\n" (show (List.sort compare (values v group part_of)));
  match why v ada ty (Link person) with
  | Some (By { rule; from; _ }) ->
    let leaf = function Given g -> Printf.sprintf "[#%d %d %s]" g.e g.p (Value.to_string g.v) | By b -> b.rule in
    Printf.printf "by %s, from %s\n" rule (String.concat " and " (List.map leaf from))
  | _ -> ()
```

```output
ada's types: #65536 (Person is 65536)
the group is part of: #65540, #65541
by prp-dom, from [#65536 17 #18] and [#65537 18 #65538]
```

## Specialisation by small relations

Run as written, such a rule is slow: every fact starts every plan whose property is a variable, and each looks the
ontology up before anything is found (the design measured 2.2× on LUBM). The writer runs it **unfolded** instead: an
atom over a relation with few facts (at most 10,000, by the store's exact counts), whose variables another atom of
the rule dispatches on (its property, or its value under a constant property: a class), is replaced by each of its
facts, the rule becoming one rule a fact, with the constants in place. This is partial evaluation (Jones, Gomard,
Sestoft [Jones 1993]) of the rules on the ontology, which RDFox's users do by hand when they translate each axiom
into its own rule [Motik 2014]:

```text
[c, domainOf, ?p] [x, ?p, y] -> [x, type, c]      over  [Person, domainOf, advisor]
                                                  gives [x, advisor, y] -> [x, type, Person]
```

Atoms over small relations that share a variable are unfolded together (`[a, subProperty, ?p] [a, superProperty, ?q]`
gives one rule an axiom thing), a range on an unfolded variable keeps only the facts inside it, and an unfolded rule
that can have no instance (a property that does not take the value) is dropped. An unfolded `prp-trp` is a plain
transitive rule on one property, which the closure module then runs.

The unfolded rules give the same facts as the generic ones exactly while the relations keep the facts they were
unfolded on, so those relations are **frozen**:
- At each group, the writer checks that the view holds those facts: by identity first (the runs, and the delta's
  entries of each relation, are the same objects as when it checked last: a few pointer comparisons), else by the
  facts themselves.
- A group that asserts, retracts, derives or deletes a fact of a frozen relation is reasoned with the rules as
  written (begun unfolded, it starts again), and the next group unfolds again on the new facts. A relation a group
  changed is a relation of the data, not of the ontology (an empty database's `type` relation is small at first): it
  is not unfolded on again while the rules and the database's size stay.
- A relation is unfolded on only if it does not depend on what the unfolded rules give: no chain of rules leads from
  their heads to it. Otherwise a fact of it could lose its proof through the rules it was unfolded into, which only
  the rules as written check (the writer keeps such a rule as written). With that, a fact of a frozen relation
  changes only through a group that asserts it or derives or deletes it, which the writer sees.
- `why` uses the rules as written: a proof names the generic rule, and its leaves include the ontology's facts.
- The programs (the rules compiled, and unfolded) are kept by rule set, under a lock that every group with rules
  takes for a moment. A new rule set's are made outside it (a change's 95 rules take 15 to 22 ms to compile and
  unfold), so that the writer's groups, which take the old rules' program meanwhile, never wait for a change's. An
  unfolded rule's variables keep the types the rule gives them (checked once a rule, not once a binding), unless a
  property variable became a constant.

## Retraction: Backward/Forward

When a fact goes, the facts derived from it may go, unless they have another proof. Three algorithms are known:

- **Counting** keeps, for each derived fact, the number of its derivations, and deletes a fact when its count reaches
  zero (Gupta, Mumick, Subrahmanian 1993 [Gupta 1993], for nonrecursive views). It is fast and **wrong for recursive
  rules**: with `member` and `memberOf` inverse of each other, each of the two facts is a derivation of the other; once
  the asserted one goes, each keeps a count of one from the other, and they never go. The test
  `rules: inverse properties support each other` checks that Cepheus removes both.
- **DRed** (delete and rederive, [Gupta 1993]) first deletes every consequence of the deleted facts, then derives
  again those that still have a proof: it explores the *consequences*, often far beyond what really goes.
- **Backward/Forward** (B/F, Motik, Nenov, Piro, Horrocks 2015 [Motik 2015]) explores the *support*: a fact that lost
  a derivation is checked by backward chaining — is it asserted, or is there a rule instance whose body facts are
  proved? — over the current facts minus those already disproved. Each fact is checked once, so cycles end; a fact
  proved propagates forward among the facts checked; a fact left without proof is deleted, and the facts its instances
  gave are checked in turn. Cepheus uses B/F.

Three details make it exact here, each found by the property test of G17 before it was right (the test compares
every view with the least model computed from scratch):
1. The instances a deleted fact loses are enumerated over the facts *before* it goes (it may fill two atoms of one
   instance: `[y, a, x], [x, a, y]` with $x = y$).
2. A fact the group retracts is no longer asserted at once, but stays among the facts until B/F decides about it: two
   retracted facts may be the two premises of one derived fact.
3. A fact retracted and asserted again in one group is asserted, and never a candidate.

Measured in the prototype of the design (LUBM-shaped data, one student): B/F 19.1 µs, DRed 216 µs, counting 3.1 µs
but wrong. In the engine: [benchmarks](benchmarks.md#rules-2026-11-08).

Within a group, the retractions are decided first (B/F over the state without them), then the additions (semi-naive):
a fact B/F deletes that the additions derive again comes back, and the group's frame holds no change for it.

## Constraints: `Never`

A rule whose head is `Never` is a **constraint**: an answer of its body refuses the group, whole (G18).

```text
{ name = "invoice-is-not-client"; vars = 1;
  where = [ { e = Var 0; p = ty; v = Thing invoice }; { e = Var 0; p = ty; v = Thing client } ];
  ranges = []; head = Never }
write db [ Add (x, ty, Link client) ]   (* x is an invoice *)
→ Error (Invalid "constraint invoice-is-not-client: [#65541 thing/type #65536] [#65541 thing/type #65537]")
```

After the group's fixpoint, the constraints' plans run on every fact the group made present: without negation, an
instance of a constraint can only appear through a new fact (such rules are monotone). A constraint with a `Not` also
gains instances through a fact gone (an invoice of a client whose name was retracted): its plans run on those too, as
the Nots' flips below. This finds every violation the group would make. Defining a constraint checks it over the
whole database.

The schema's own rules apply to derived facts too: a rule that would give a second value of a one-valued property,
or a value of a unique property another thing holds, refuses the group and names the rule.

## Negation and aggregates: strata

A pattern of a body may be in a **`Not`**: the rule's answer holds only when no value of the Not's **own** variables
(those in no pattern outside it) makes all of its patterns facts. In database terms it is an *anti-join*. A head may
give an **aggregate** of the body's answers: for each thing of the head, one fact whose value is the sum, the number,
the smallest or the largest value of a variable over that thing's answers. In OCaml both are written into a pattern's
property, so a rule keeps its fields: `absent k p` is the property `p` in the rule's `k`-th Not, `aggregate f p` the
property `p` given by the aggregate `f`.

```text
(* an invoice without any payment is unpaid: ?1 is the Not's own, "there is no ?1 such that [?0 paid_on ?1]" *)
{ name = "unpaid"; vars = 2;
  where = [ { e = Var 0; p = ty; v = Thing invoice }; { e = Var 0; p = absent 0 paid_on; v = Var 1 } ];
  ranges = []; head = Give { e = Var 0; p = status; v = Val (Text "unpaid") } }

(* an invoice's total: the sum of its lines' amounts, one answer a line *)
{ name = "total"; vars = 3;
  where = [ { e = Var 1; p = line_of; v = Var 0 }; { e = Var 1; p = amount; v = Var 2 } ];
  ranges = []; head = Give { e = Var 0; p = aggregate `Sum total; v = Var 2 } }
```

Their canonical text adds `; not [E P V] ...` before the head and `give sum [E P V]` (or `count`, `min`, `max`); a rule
without them has the text it had before. In Cesia: `cepheus.Not(...)` in `Where`, and `cepheus.Sum(x)`, `Min(x)`,
`Max(x)` or `Count()` as the value of `Then` ([rules from Cesia](cesia.md#rules)).

**What they mean.** A rule that reads a property under `Not` needs that property complete first, and so does an
aggregate. The rules are ordered in **strata**: a rule reads under `Not` or aggregates only what lower strata give,
and the strata are computed one after the other. The facts held are then the **perfect model** of the rules, the one
model of a stratified program that does not depend on how its rules are ordered ([Apt 1988], [Przymusinski 1988]);
aggregates are stratified the same way ([Mumick 1990]). A rule set where a property depends on its own absence, or
on its own aggregate, has no such order: `define` refuses it and names the cycle; a rule `R` that gives `status`
and reads it under `Not` is refused with `Invalid "rule R: status depends on its own absence (R -> not R)"`. The strata come from the rules'
graph (an edge from a rule to each rule that reads its head; negative when it reads it under `Not` or aggregates it),
its strong components found by [Tarjan 1972]: a negative edge inside a component is a cycle through `Not`; a rule's
stratum is the largest number of negative edges on a path to it. A node is a property refined by a constant value,
so that `[?x type Invoice]` and `[?x type Client]` are apart, and a `Not` over one class may depend on another.

**Their rules**, checked at `define`:
- A `Not` holds 1 to 4 patterns whose properties are constants; a rule has at most 16. A variable in no pattern
  outside `Not` is the own of one `Not` only, and the head's variables are outside every `Not` (range restriction).
- `Sum` is for ints and money, `Min` and `Max` for ints, dates and money; `Count`'s value is `Val (Int 0)`, the
  property an int. The answers are counted once each, over the body's variables: two lines of the same amount are two
  answers, since their line differs.
- A sum is exact: kept in two words, it refuses the group when the result is past the largest int
  (`Invalid "rule R: the sum of #x is past the largest int"`), never wraps.
- An aggregate's property takes one value, is given by that rule alone, and no write adds or retracts it: a write of
  it is refused, and so is defining an aggregate over a property that holds asserted facts, unless the same group
  retracts them. The group that removes the aggregate may write its property.
- A thing without answers has no fact (no zero count, no sum of nothing).

**How the writer keeps them.** Each stratum in order, the lower ones complete ([Motik 2019], B/F for stratified
rules):
1. its aggregates, by difference: the answers the group gave and took away are found from the facts it changed below
   (over the state after the group for a fact made present, before it for a fact gone), each answer once by its facts.
   `Sum` and `Count` are linear: the change of the sum is the sum of the changes ([Budiu 2023]). `Min` and `Max` read
   their group again only when its extreme went, so at most the group's size;
2. the flips of its `Not`s: a fact made present that matches a `Not` takes away the answers that `Not` allowed (B/F's
   candidates); a fact gone gives the answers its absence now allows (the insertion's);
3. B/F on its candidates, then semi-naive insertion from every fact made present so far.

A `Not` whose patterns have both sides known is one lookup a candidate. A rule set with `Not` or aggregates runs as
written (no [specialisation](#specialisation-by-small-relations)), and a load into it takes the ordinary path, not
the large groups' one. `why` of an aggregate's fact gives the facts of every answer of its group.

## The budget

A rule can derive a great deal from a small write (every pair of members of a club). The writer refuses a group
whose derived changes pass **$100{,}000 + 100 \times \text{its asserted changes}$**: `Invalid "rule NAME derived more than N facts
from a group of K facts"`, naming the rule that derived the most. The scaled part lets a load derive in proportion;
the fixed part bounds what a small write can cost the other writers, who wait for it (about 0.1 s of reasoning at
the budget). `rule_budget` holds the two numbers. Every path counts against it: each rule instance's new fact, each
fact a closure module makes, a closure's targets as they grow (so that a dense graph's $n^2$ facts are refused before
they are made, in memory in proportion to the budget), and the facts B/F deletes.

The facts derived do not bound the **work** alone: a body whose patterns share a value reads their product,
`[a tag t] [b tag t] [c tag t]` $n^3$ candidates for $n$ heads (one write of 400 such facts held the writer 13 s).
So the candidates the rules read (each fact a pattern of a body, of a Not or of a constraint enumerates, as a
question's are counted, `Query.fold ~budget`) may be at most `work_budget` (10) times the budget of derived facts:
`Invalid "rule NAME read more than N candidates of its patterns for a group of K facts"`, NAME the rule whose pattern
read the last one, or `for a change of the rules or the ontology`. A candidate is a read in an index, a derived fact
one interned, indexed and kept: the 1.2 M candidates of the refusal above take 60 ms, the budget's 100,000 derived
facts about 0.1 s, so the work is bounded in time as the derived facts are. A rule that walks many candidates for
few heads joins on a more selective pattern first.

A **change** — a group that changes the rules, or the ontology ([below](#changes-of-the-rules-in-the-background)) —
applies to the whole database, so its budget grows with it: **$100{,}000 + 100 \times \text{its asserted changes} +
4 \times \text{the facts of the database before it}$** (`change_budget`, the 4): a change may make the database at
most five times as large, and a rule whose consequences grow faster (every pair of things, a dense closure) is still
refused, named: `Invalid "rule NAME derived more than N facts from a change of the rules or the ontology"`. The
same budget on a fork, in the threaded writer and in the deterministic core, so a fork accepts and refuses exactly
what the database does (G8).

## Why

`why view thing property value` returns a **proof**: a tree whose leaves are asserted facts and whose nodes are rule
instances, each node's children the facts of its body (G20). It is computed when asked, by B/F's backward check on the
view (nothing deleted), keeping the instance that proved each fact; nothing is stored at write time. The proof is
**well-founded**: every body fact was proved before its head, so no node rests on itself. It is a proof, not the
shortest one, and it is the same for a given view. A past view (`AsOf`, a kept view) gives the proof that held then:
the past holds its derived facts already.

Soufflé's provenance (Zhao, Subotić, Scholz 2020 [Zhao 2020]) stores, for each derived fact, its rule and the height
of a minimal proof, for minimal-height proofs at a published 1.31× run time on average; Cepheus stores nothing, and
pays a few microseconds when asked ([benchmarks](benchmarks.md#rules-2026-11-08)).

## Derived facts are in the journal

A group's frame holds its asserted changes, then its derived changes, each with its kind byte (the table above, and
2 `Derived`, 3 `Underived`). Replay applies the kinds and **never evaluates a rule**: recovery, a replica, a local
reader, the past need no reasoner, and a later change of the reasoner's code never changes what the journal says the
database was. A derived fact costs its bytes in the frame: its kind in the kinds column (a few bits a change, or none
in a block of one kind), its thing and its value in their columns ([formats](formats.md#a-group)).

In a run (formats 7 and 8, [formats](formats.md#run-dirsnapshotslo-20-digits-hi-20-digitsrun)), the flag "only derived" is
the lowest bit of the value's field, in both orders, in the blocks that hold a derived fact (a thing block's entry, a
row block); a block without one spends no bit on it, so a database without rules pays nothing. Format 6 kept it in
bit 63 of each 8-byte value word. A run that changes the flag of a fact held by a run below it holds a retraction (the
old flag) and an addition (the new one), so that every count stays exact.

## Rules are data

A rule is a **schema thing**, as a property is: a thing in [16, 65536) with two facts, `cepheus/name` (unique among
the schema's names, properties' included) and `cepheus/rule` (system property 5), a text in a canonical form:

```text
vars 3; where [?0 16 ?1] [?1 17 ?2]; give [?0 16 ?2]
vars 3; where [?0 18 ?1] [?2 ?1 ?3]; give [?2 19 ?0]        (a variable property: ?1 in the property's place)
```

So a rule is written in a group like any fact, the journal keeps every version of it, and a fork gets it with the
rest. `define db rules` finds each rule by name and writes, in one group, the new rules and the changed ones;
`undefine db names` removes rules. A group that defines a rule derives what the rule gives over the whole database;
one that removes a rule retracts what only it derived (by B/F: each fact the rule gave is checked for another proof),
both under a change's budget, in that group: a rule change takes effect at one group number, every view before it the
materialisation under the old rules, every view from it under the new (G19). In a database on the disk the change is
computed beside the writer and installed as that group ([next section](#changes-of-the-rules-in-the-background)).

## Changes of the rules in the background

Defining the univ-bench ontology's 94 rules over 10 LUBM-shaped universities derives 532,205 facts; computed in the
writer, inside the group, it would stop every other writer for seconds. The threaded writer of a database on the disk
(a server, `open_`) computes a **change** beside it instead, and installs it as one group:

1. **Which groups.** A group that changes the rules (a rule defined, changed or removed), or the **ontology**: a group
   past a data write's budget that asserts or retracts a fact of a relation the rules are unfolded on in the state
   before it ([specialisation](#specialisation-by-small-relations); found from the rules and that state alone, never
   from what earlier groups did, so a fork finds the same). The writer first resolves the group's asserted part as
   always (types, `Expect`, the rules' own checks: safety, types, strata): an error is answered at once. A change with
   new things (temporary ids) is computed in the group, as on a fork: its things' numbers are the writer's to give,
   in order. One change at a time; the next waits for it.
2. **The build.** A domain of its own resolves the group on a fork of the writer's view of the moment, under the
   change's budget: the materialisation of that state plus the change, under the new rules, on that domain alone.
3. **The catch-up.** Meanwhile the writer commits the groups that keep coming, under the old rules, and logs them.
   The background applies them to its view by batches, all it finds at once: their net asserted changes (a fact's
   state before the first and after the last), and what the **new** rules make of them; the derived changes they had
   under the old rules are dropped. Only the state at the end of a batch matters: the derived facts are a function of
   the asserted ones (the least model is unique, [Abiteboul 1995]), and the states between are ordered before the
   change, under the old rules. It keeps, fact by fact, the difference between the writer's states and its own.
4. **The switch.** When the background finds fewer than 64 groups to apply, the writer applies the rest itself,
   resolves the group's asserted part again against its own view (its `Expect`s are checked then), writes one group:
   the asserted changes, then the difference as derived changes, and makes the background's view its working view. The
   write returns once that group is durable, like any write.

What can end a change instead, and what it answers:

| a group written meanwhile | the change answers |
|---|---|
| asserts or retracts a fact the change asserts or retracts (they would not commute) | `Conflict` |
| makes the change's `Expect` false (another writer took the rule's number: `define` tries again) | `Conflict` |
| changes the rules itself (a change that makes new things, computed in its group) | `Conflict` |
| breaks, under the new rules, a constraint, a one-valued or a unique property, or the change's budget | `Conflict` |
| removes a property the new rules read | `Invalid` (the rules' check at the switch) |

`Conflict` means a group ordered before the change interfered: `define` reads the schema again and tries again, and
the retry decides on the newer state, where a lasting problem gives its `Invalid` at the build (a constraint the
data breaks: `Invalid "constraint NAME: …"`). A change past its budget is `Invalid` at the build. A close cancels a
change in flight: it is answered `Closed`, and nothing of it is in the journal.

In a Raft cluster ([server](server.md#one-log-for-the-cluster)) the change runs on the leader, and its group is
proposed as any write's frame, alone. If the leader stops leading while the change runs (a frame it wrote is taken
back, or it applies another leader's frame), the change is answered `not_leader` and nothing of it is written: its view
could hold a group that was never committed, or miss one the new leader wrote. The program sends it again (the OCaml
client does, to the new leader). In a cluster a group is at most 8 MiB, one entry of the log: a change whose group,
its derived facts included, passes it is refused (`invalid`, over the frame limit).

**Why this keeps the guarantees.** The change is ordered when it is installed: every group it caught up with is
before it, and its `Expect`s are checked against that state (G4). Its view is the least model of the state at the
switch under the new rules, because each batch keeps it so (G17 holds for incremental groups) and the change's
asserted part commutes with the groups logged (no fact in common, checked). The frame of its group is exactly the
difference between the writer's view and that one, so replay — recovery, a replica, a local reader — gets exactly
the view the writer adopted. No view before the group holds a fact of the new rules (the background's view is
published only with the group), every view from it holds all of them (G19). A crash before the group is durable leaves
nothing: the change was never confirmed. The protocol is checked by TLC (`spec/RuleChange.tla`: the build, batches of
catch-up, the switch, crashes, a Raft leader's frames taken back, a change's run of its own, merges; every view exact
under its rules, one switch, constraints, `Expect` at the switch, no write lost, the runs on the disk exact, and the
change ends), and each of its thirteen parts is needed:
without any one, TLC finds a counterexample
([testing](testing.md#model-checking)).

**What the writer does meanwhile.** It never waits for the build or the catch-up; no background merge starts while a
change runs, and a change waits for a merge in flight, so that both views share their runs. Its part at the switch is
the last groups and the frame. If the background falls more than 65,536 groups behind, the writer waits for it, so
that the log and the deltas stay bounded.

**A large change's derived facts: a run of their own.** The **delta** is the part of a view kept in memory as maps
(a fact at a time, over the runs on the disk); a **run** is a sorted file of facts. Putting 150,000 derived facts in
the delta one by one took half of a change's build. So when the build adds 20,000 derived facts or more of the
properties that take many values, none of them unique (no check reads those facts after the rounds), and whose fact
the delta holds no entry for, it sets them apart, sorts them and writes them, by the one way a run is written (a merge,
of them alone), as a run of their own: **R**, on top of the runs and under the change's delta. The catch-up reads R as
any run. The table of differences (where the catch-up keeps, fact by fact, each fact whose state differs between the
writer's view and the change's, and from which the change's frame is written) holds a fact of R only once a group
written meanwhile touches it (before that, its
states are known: absent for the writer, derived for the change), and keeps it once there, even when its two states
agree, since a fact of R missing from the table means "derived, as R says". The change's frame does not change: its
asserted changes, the table's differences, then R's facts that the table does not hold, as derived. The journal holds
every derived fact, as before, and its format is the same. The writer codes R's part of the frame straight from R's
columns (`Group.encode_parts`), its columns and texts numbered as the coding of the whole group numbers them: the same
bytes, with no record and no value made for each of R's facts, which took the writer about 25 ms for 135,000 of them.
The watches, which need the frame's changes one by one, make R's records on their own domain (`Engine.whole`).

R is **provisional**: its state is no group's (one change's derived facts, without the groups around them), so it is
never named in the chain of runs, never forced to the disk, and its file (`<lo>-<hi>.run.change.tmp`, level 0 in its
header, which an open refuses in a named run) goes when the merge that takes it is installed, when the change ends
without its install, or at close. A crash loses it (a `.tmp` file, removed at open), and recovery replays the change's
frame. The writer adopts R with the change's view, and every merge takes it (a merge takes the newest runs, and R is
always among the newest). From 4 such runs a merge starts; at 8, a change puts its derived facts in the delta, as a
small change does. Replicas, Raft followers and local readers never see R: they apply the change's frame, as before.
TLC checks the protocol with R ([testing](testing.md#model-checking)), and each of R's five rules is needed: R takes
only the facts the delta has no entry for, a fact of R starts in the table as (absent, derived), it stays there once
touched, R is never named, every merge takes it; without any one, TLC finds a counterexample.

**Facts no rule reads: made facts by one sort.** Most of a change's derived facts often start nothing: they are the
facts of a **sink**, a rule whose head no pattern of any rule can match (in the example below, `[x type Schedule]`, a
class no rule reads). The working set (the reasoning's own table of the facts a group touches, with the indexes the
rules' plans search) needs them only to know a fact is not found twice; a relation no plan searches needs no index (the
choice of indexes from the plans' searches, [Subotic 2018]), only its duplicates removed, which one sort does. So a
change keeps a sink's heads in a buffer as its instances find them (outside the collector's heap, a thing, a property, a
value and the rule each), and at the end of its reasoning sorts them once by (thing, property, value): they come as a
few ascending runs (an atom's facts read from the view's runs one after the other), merged by pairs as a natural merge
sort does, and past 64 runs a least-significant-digit radix sort by thing, 11-bit digits, then by property and value
inside each thing [Knuth 1998]; both stable. It keeps the first of each fact (stable: its first instance names its
rule), sets aside those the view or the working set holds, and counts the others against the budget, as every derived
fact; they go to the change's output in that order, so that its run of its own is written with no other sort. Taken one
by one in the working set, each head cost a probe, its slot, three indexes and their share of the tables' growth: about
0.8 µs a head beside 256 writers, six times the cost of finding it. Past half the budget's room (65,536 heads at least),
the heads are deduplicated before the end, and a change whose facts kept pass its budget is refused there, naming the
rule that derived the most, as before. Only in a change (a group that changes the rules or the ontology), only for rules
whose property takes many values, none unique, not the system's, and not with equality (a rule that makes things the
same reads every fact), and on one domain: a round on several domains (below) makes its heads facts by regions of the
working set, a sink's too, in parallel.

**What it costs** ([benchmarks](benchmarks.md#rules-step-5s-targets-again-a-changes-install-without-a-record-a-fact-2026-11-19)).
On 10 LUBM-shaped universities with the 94 rules, while 256 clients write durably, adding one axiom (every person is
also of a class the data leaves empty: about 135,000 derived facts, all of them a sink's) is installed in 0.22 s
(median of 21; its build 0.048 s, its run of its own 0.025 s: 2.9 M derived facts a second for the build, 1.8 M with
the run's write), and the writer's own part at the install is 10 ms (33 before its frame was coded from R's
columns). The writers lose about 40 ms of their work in the change's window on the disk, whose fsync stalls of up to
half a second still decide a pair's ratio; in a tmpfs folder, with no stall, 49 ms in a window of 0.58 s: 0.83 of
their throughput without the change, paired, and 0.92 against the median window of a run without it. Over the run
from its start, the change's own loss is under 1 %; the axiom itself makes every later student write derive one more
fact, about 8 % more of the writer's work, which the disk hides behind its fsyncs. The background shares the machine's four cores, its caches and its collector with the writer, and the delta grows meanwhile, since no
merge runs beside a change. Defining all 94
rules over the same data without rules is the worst case: every group written meanwhile costs the new rules several
times what it costs the old ones, the background cannot keep up at full load (about 110 µs a group against the
writer's 10 to 25), and the writer waits for it at 65,536 groups behind (seconds).

**Rounds on several domains.** In a group the writer reasons itself (a load, a change on a fork or in the
deterministic core), a round of 20,000 facts or more, and the first round of a change's added rules, is cut into
morsels (Leis et al. [Leis 2014]) taken in turn by up to four domains, each deriving with plans of its own and keeping
the heads that are not facts yet; then one domain makes them facts, morsel after morsel, in order, as it would have
found them alone: the result, the budget and the refusals do not depend on the domains. Rules with `Not` or
aggregates, and rules whose text constants a group would intern, run on one domain. When the added rules are fewer
than the threads, each rule's instances are cut by blocks of its plan's first items, one block a morsel. A change in
the background derives on its own domain only: measured on several domains there, the clients' throughput during the
change fell (0.84 to 0.78 in step 5; with a rule's instances in morsels, 0.83 to 0.50), and the build was no faster
([benchmarks](benchmarks.md#rules-step-5s-targets-a-changes-derived-facts-in-a-run-of-their-own-2026-11-18)). Measured on a load of 10 universities with the 94 rules: the rounds at 1.44 M derived facts/s on four
domains, 0.90 on one.

The rules are compiled at the first write that needs them, never at open: an open replays frames, which hold the
derived facts already, so start-up does not grow.

## Large groups

A group of 20,000 additions and more (a load) takes the path of large groups ([architecture](architecture.md#large-groups)):
its facts are mapped into compact arrays, sorted in both orders of a run, and merged into a run at once. With rules,
its facts are the round 0 of the same semi-naive evaluation, held as the design's sorted path has them (after VLog's
sorted columns [Urbani 2016]) rather than hashed one by one:

- **A sorted prefix, not hash chains.** The group's facts of the properties some rule reads or gives (no rule can
  match the others) are the working set's first facts, in the order by thing: a thing's facts are a range of them (an
  offset a new thing), a (property, value)'s things a range of the group's order by property, which its run needs
  anyway. Only the membership table holds each of them, filled by several domains, each owning a region of the table.
- **Only the chains a plan reads.** A derived fact joins the chain by (property, thing) only if some plan reads its
  property with the thing known and the value not, and the chain by (property, value) only the other way round, as the
  plans' compiled order says (an index selection, in the manner of [Subotic 2018]). A load's derived types, read only
  with both sides known, join none.
- **Rounds on several domains.** A round of 20,000 facts or more is derived by morsels; its heads are made facts by
  regions of the membership table, one domain a region, with the ids, rules and order the one-domain loop gives: the
  result does not depend on the number of domains.
- **The derived facts merged into the group's orders**, sorted alone, not sorted again with the group's.
- **A new thing's facts are not looked up in the view** (it has none); a fact derived already that the group asserts
  changes its flag in the delta (kind 4 in the frame, before the group's facts) instead of sending the group to the
  ordinary path, so that a load in chunks (a university a group) stays on this path.
- **Constraints and one-valued heads are checked after the fixpoint**: the constraints' plans (with their Nots) run
  from every fact the group made present, and each derived fact of a one-valued or unique property is counted with
  the group's and the view's. A group that breaks one goes to the ordinary path, which refuses it with its message.

A group whose rules derive with a `Not` or an aggregate takes the ordinary path. A rule's text that the group itself
adds is found among the group's new texts, which the dictionary's map does not hold yet.

## OWL 2 RL, a library of rules

**OWL 2** is the W3C's language of *ontologies*: classes ("a professor is a person"), properties and what they mean
("an advisor is a professor", "an e-mail identifies one person"). **OWL 2 RL** is the part of it that rules can compute
completely: the W3C gives it as 78 rules, in six tables (OWL 2 Profiles, section 4.3 [W3C 2012]). Cepheus has no switch
for it: `Cepheus.Owl` is a library of rules over a vocabulary of properties of its own, and a database gets OWL 2 RL by
defining those rules, as it defines any rules. The ontology is then data: facts written in groups, versioned in the
journal, and the rules are unfolded on them ([specialisation](#specialisation-by-small-relations)).

```ocaml
open Cepheus

let () =
  let db = fork empty in
  let o = Result.get_ok (Owl.setup db) in
  ignore (Result.get_ok (define db (Owl.rl o)));
  let[@warning "-8"] (Ok [ name; email; advisor ]) =
    declare db [ prop "person/name" Ttext; prop ~many:true "person/email" Ttext; prop ~many:true "person/advisor" Tlink ]
  in
  (* the ontology: a professor is a person; an advisor is a professor; an e-mail is one person's *)
  let r =
    Result.get_ok
      (write db
         [ Add (-1, name, Text "Person"); Add (-2, name, Text "Professor"); Add (-2, o.sub_class_of, Link (-1));
           Add (-3, o.property, Link advisor); Add (-3, o.range, Link (-2));
           Add (-4, o.property, Link email); Add (-4, o.inverse_functional, Bool true) ])
  in
  let person = thing r (-1) and professor = thing r (-2) in
  (* two records of one professor, the same e-mail in both, and a student whose advisor is the first *)
  let r =
    Result.get_ok
      (write db
         [ Add (-1, email, Text "ada@uni.org"); Add (-2, email, Text "ada@uni.org"); Add (-2, name, Text "Ada");
           Add (-3, advisor, Link (-1)) ])
  in
  let a1 = thing r (-1) and a2 = thing r (-2) in
  let v = view db in
  let ids l = String.concat ", " (List.map string_of_int l) and show l = String.concat ", " (List.map Value.to_string l) in
  Printf.printf "the records %d and %d are one thing: %s\n" a1 a2 (ids (same v a1));
  Printf.printf "its types: %s (Professor is %d, Person %d); its name: %s\n" (show (values v a1 o.type_)) professor person
    (show (values v a1 name));
  (match why v a2 o.type_ (Link person) with
   | Some (By b) -> Printf.printf "a person by %s, from %d facts\n" b.rule (List.length b.from)
   | _ -> ());
  (* one record's e-mail retracted: two things again *)
  ignore (Result.get_ok (write db [ Retract (a2, email, Text "ada@uni.org") ]));
  Printf.printf "after: %s; %s\n" (ids (same (view db) a1)) (ids (same (view db) a2))
```

```output
the records 65542 and 65543 are one thing: 65542, 65543
its types: #65538, #65539 (Professor is 65539, Person 65538); its name: "Ada"
a person by owl/prp-rng, from 3 facts
after: 65542; 65543
```

From Cesia, the same through a server ([Cepheus from Cesia](cesia.md#owl-2-rl)): the vocabulary is the kind
`owl.Vocabulary`, given to `Connect`, and `owl.Rl()` the rules as data, which `cepheus.Define` takes from this library
(`Owl.setup`'s work included); a property of a kind, where a link goes, is its id (`[d, owl.Property, Person.Advisor]`):

```cesia norun
use deps/www-celestial/cepheus/cesia/cepheus
use deps/www-celestial/cepheus/cesia/cepheus/owl
use std/io
use std/list
use std/result
use std/sys

Person = cepheus.Kind("person", {Name: cepheus.Text(), Email: cepheus.Text(many = true), Advisor: cepheus.Link(many = true)})
db = result.Unwrap(cepheus.Connect(sys.Env("CEPHEUS_URL"), [owl.Vocabulary, Person], token = sys.Env("CEPHEUS_TOKEN")))
result.Unwrap(cepheus.Define(owl.Rl(), db))
(* the ontology: a professor is a person; an advisor is a professor; an e-mail is one person's *)
c = result.Unwrap(cepheus.Write([
  cepheus.Add(cepheus.New(1), Person.Name, "Person"), cepheus.Add(cepheus.New(2), Person.Name, "Professor"),
  cepheus.Add(cepheus.New(2), owl.SubClassOf, cepheus.New(1)),
  cepheus.Add(cepheus.New(3), owl.Property, Person.Advisor), cepheus.Add(cepheus.New(3), owl.Range, cepheus.New(2)),
  cepheus.Add(cepheus.New(4), owl.Property, Person.Email), cepheus.Add(cepheus.New(4), owl.InverseFunctional, true)], db)).Things
(* two records of one professor, the same e-mail in both, and a student whose advisor is the first *)
r = result.Unwrap(cepheus.Write([
  cepheus.Add(cepheus.New(1), Person.Email, "ada@uni.org"), cepheus.Add(cepheus.New(2), Person.Email, "ada@uni.org"),
  cepheus.Add(cepheus.New(2), Person.Name, "Ada"), cepheus.Add(cepheus.New(3), Person.Advisor, cepheus.New(1))], db)).Things
io.Print("the records", r[1], "and", r[2], "are one thing:", result.Unwrap(cepheus.Same(r[1], db)))
types = list.Sort(result.Unwrap(cepheus.Get(owl.Vocabulary, r[1], db)).Type)
name = result.Unwrap(cepheus.Get(Person, r[2], db)).Name
io.Print("its types: $types (Professor is $(c[2]), Person $(c[1])); its name: $name")
(* one record's e-mail retracted: two things again *)
result.Unwrap(cepheus.Write([cepheus.Retract(r[2], Person.Email, "ada@uni.org")], db))
io.Print("after:", result.Unwrap(cepheus.Same(r[1], db)), result.Unwrap(cepheus.Same(r[2], db)))
```

```text
the records 65542 and 65543 are one thing: [65542, 65543]
its types: [65538, 65539] (Professor is 65539, Person 65538); its name: Ada
after: [65542] [65543]
```

The same things, the same ids: the engine's library, defined from either language. `why` is OCaml's alone for now.

- The name written on the second record is read on the first, 65542, the class's representative: reads name a thing
  as its representative, and `why` of the second record's type proves the representative's. It gives a proof, not
  the shortest: Person by prp-rng, over the range that scm-rng1 derived (the advisor's range is Professor, and a
  Professor is a Person).
- The rules are the W3C's, written in its form: generic rules over the ontology's facts, with the property a variable
  ([above](#a-property-as-a-variable-the-w3cs-form-of-owls-rules)). The writer runs them unfolded on the ontology, one
  rule an axiom ("an advisor is a professor" becomes `[x advisor y] -> [y type Professor]`); a write of the ontology
  is a change of the rules, computed as one ([in the background](#changes-of-the-rules-in-the-background) on a database
  on the disk).
- The two records were made **one thing** by `owl/prp-ifp` (an inverse functional property: one value, one thing):
  their facts are kept on one of them, the **representative**, and `same` lists the class; reads name a thing as its
  class's representative ([equality](#equality-classes-of-equal-things) below).
- Retracting the e-mail that made them one splits them again: the class is taken apart and derived again.

### The vocabulary

A property thing keeps only `cepheus/` facts ([a property as a variable](#a-property-as-a-variable-the-w3cs-form-of-owls-rules)),
and Cepheus has no RDF lists; so the vocabulary differs from OWL's RDF form in four ways, each the smallest that keeps
the W3C's rules as they are:

- An axiom about a property is a fact of its **description**, a thing of its own: `[d, owl/Property, advisor]` names
  the property, and d's other facts are its axioms: `[d, owl/Range, Professor]`, `[d, owl/Transitive, true]`. One
  description a property: the schema rules give derived axioms to it (scm-dom2: a subproperty's description gets the
  domain of its superproperty's).
- A **list** (an intersection's classes, a union's, a key's properties, an enumeration's things) is the values of a
  property that takes many: `[Student, owl/IntersectionOf, Person]`, `[Student, owl/IntersectionOf, r]`. The rules that
  need every member at once (cls-int1, prp-key) are **templates** ([below](#templates-rules-over-lists)).
- A **property chain** (p1 then p2 gives p, prp-spo2) is a thing with two links: `[ch, owl/ChainOf, p]`,
  `[ch, owl/First, p1]`, `[ch, owl/Second, p2]`; a chain of three or more is written as chains of two, through a
  property of the program's own for each middle step (p1, p2, p3 gives p: p1, p2 gives q; q, p3 gives p).
- AllDifferent, AllDisjointClasses and AllDisjointProperties are written as their pairs (`Owl.all_different`,
  `Owl.disjoint_classes`, `Owl.disjoint_properties` make them): what the W3C's n-ary forms mean, pairwise.

| property | on | value | OWL |
|---|---|---|---|
| `owl/Type` | a thing | a class | rdf:type |
| `owl/SameAs`, `owl/DifferentFrom` | a thing | a thing | owl:sameAs, owl:differentFrom |
| `owl/SubClassOf`, `owl/EquivalentClass`, `owl/DisjointWith`, `owl/ComplementOf` | a class | a class | rdfs:subClassOf, owl:equivalentClass, owl:disjointWith, owl:complementOf |
| `owl/IntersectionOf`, `owl/UnionOf` | a class | each member class | owl:intersectionOf, owl:unionOf (a list) |
| `owl/OneOf` | a class | each member thing | owl:oneOf |
| `owl/HasKey` | a class | each key property | owl:hasKey |
| `owl/OnProperty` | a restriction | a property | owl:onProperty |
| `owl/SomeValuesFrom`, `owl/AllValuesFrom`, `owl/OnClass` | a restriction | a class | owl:someValuesFrom, owl:allValuesFrom, owl:onClass |
| `owl/HasValue` | a restriction | a thing | owl:hasValue (a thing; a value of a text or a number is a rule of the program's) |
| `owl/MaxCardinality`, `owl/MaxQualifiedCardinality` | a restriction | an int, 0 or 1 | owl:maxCardinality, owl:maxQualifiedCardinality |
| `owl/Property` | a description | the property | the subject of the property's axioms |
| `owl/Domain`, `owl/Range` | a description | a class | rdfs:domain, rdfs:range |
| `owl/SubPropertyOf`, `owl/EquivalentProperty`, `owl/InverseOf`, `owl/PropertyDisjointWith` | a description | a property | rdfs:subPropertyOf, owl:equivalentProperty, owl:inverseOf, owl:propertyDisjointWith |
| `owl/Functional`, `owl/InverseFunctional`, `owl/Transitive`, `owl/Symmetric`, `owl/Asymmetric`, `owl/Irreflexive` | a description | `true` | the property's characteristics |
| `owl/ChainOf`, `owl/First`, `owl/Second` | a chain | a property | owl:propertyChainAxiom (two links) |
| `owl/SourceIndividual`, `owl/AssertionProperty`, `owl/TargetIndividual`, `owl/TargetValue` | a negative assertion | a thing, a property, a thing, a text | owl:NegativePropertyAssertion |
| `owl/Builtin` | owl:Thing, owl:Nothing | "Thing", "Nothing" | the two classes every ontology has |

`Owl.setup db` declares these properties and makes the things owl:Thing and owl:Nothing, once (a database that has them
keeps them); `Owl.rl` gives the rules, named `owl/` and the W3C's name (`owl/cax-sco`; a W3C rule with two heads is two
rules, the second named with a `b`: `owl/scm-eqc1b`).

### Each of the 78 rules

| W3C table | rules | in Cepheus |
|---|---|---|
| 4, equality (9) | eq-ref, eq-sym, eq-trans, eq-rep-s, eq-rep-p, eq-rep-o | the classes of equal things and their rewriting ([below](#equality-classes-of-equal-things)); `owl/eq` makes `owl/SameAs` an equality; eq-rep-p: a property is the same as no other (a rule that would make it so refuses its group) |
| | eq-diff1, eq-diff2, eq-diff3 | the constraint `owl/eq-diff1` (`[x, owl/DifferentFrom, x]`, which a rewritten difference between two equal things becomes); AllDifferent as its pairs |
| 5, properties (20) | prp-dom, prp-rng, prp-symp, prp-trp, prp-spo1, prp-eqp1, prp-eqp2, prp-inv1, prp-inv2 | rules (a transitive property's closure by the closure module) |
| | prp-spo2 | a rule over chains of two links |
| | prp-fp, prp-ifp, prp-key | rules that make things the same; prp-key a template over the key's properties |
| | prp-irp, prp-asyp, prp-pdw, prp-npa1, prp-npa2 | constraints; prp-adp: AllDisjointProperties as pairs of prp-pdw |
| | prp-ap | nothing to do: an annotation property is a property like any other |
| 6, classes (19) | cls-int2, cls-uni, cls-svf1, cls-svf2, cls-avf, cls-hv1, cls-hv2, cls-oo | rules |
| | cls-int1 | a template over the intersection's members |
| | cls-maxc2, cls-maxqc3, cls-maxqc4 | rules that make things the same |
| | cls-nothing2, cls-com, cls-maxc1, cls-maxqc1, cls-maxqc2 | constraints |
| | cls-thing, cls-nothing1 | the two things `Owl.setup` makes |
| 7, class axioms (5) | cax-sco, cax-eqc1, cax-eqc2 | rules |
| | cax-dw | a constraint; cax-adc: AllDisjointClasses as pairs of cax-dw |
| 8, datatypes (5) | dt-type1, dt-type2, dt-eq, dt-diff, dt-not-type | held by the typed values: a value has one type and one word ([concepts](concepts.md)), an ill-typed value never enters, equal values are one fact |
| 9, schema (20) | scm-sco, scm-eqc1, scm-eqc2, scm-spo, scm-eqp1, scm-eqp2, scm-dom1, scm-dom2, scm-rng1, scm-rng2, scm-hv, scm-svf1, scm-svf2, scm-avf1, scm-avf2, scm-int, scm-uni | rules over the ontology's facts (scm-sco by the closure module); scm-hv, scm-svf1 and scm-avf1 have a second rule for the case a reflexive fact would give |
| | scm-cls, scm-op, scm-dp | held without facts: a class is its own subclass and owl:Thing's, a property its own subproperty; nothing reflexive is stored, and `x owl/Type owl:Thing` is not stored for every thing (Cepheus declares no classes) |

Every rule has a test that it fires, or that its constraint refuses, on five paths (a fork group by group, the rules
as written, the ontology after the data, a load on the disk, a change in the background), each view compared with
the meaning of the rules computed from scratch ([testing](testing.md)).

### Templates: rules over lists

`cls-int1` says: when y has the type of every member of C's intersection, y is a C. Its body has as many patterns as
the intersection has members: the W3C writes it over a list, `LIST[?x, ?c1, …, ?cn]`. In Cepheus a pattern
`[c, every L, m]` (OCaml `Cepheus.every L`; in the canonical text `[?0 *40 ?1]`) reads "for every value m of c's L":
the patterns that name m are written once for each member, and the variables only they hold are fresh in each copy.

```text
cls-int1:  [c, every owl/IntersectionOf, m] [y, owl/Type, m] -> [y, owl/Type, c]
over [Student, owl/IntersectionOf, Person] [Student, owl/IntersectionOf, r]:
           [y, owl/Type, Person] [y, owl/Type, r] -> [y, owl/Type, Student]
prp-key:   [c, every owl/HasKey, p] [x, owl/Type, c] [y, owl/Type, c] [x, ?p, z] [y, ?p, z] -> [x, cepheus/same, y]
over a key {email, birth}:
           [x type C] [y type C] [x email z1] [y email z1] [x birth z2] [y birth z2] -> [x cepheus/same y]
```

The writer unfolds a template on the list's facts in the rules as written (a list of no member gives no rule), and the
unfolded rules run as any rule. A template's rules change when its list does, so **a write of a list is a change of
the rules**: the rules removed (the old unfolding) lose their consequences by B/F, the rules added derive theirs, in
the group, under a change's budget, and in the background on a database on the disk. No rule may give a list's
property (refused when the rules are defined, and a fact of it derived refuses the group): a list changes by writes
only. One template pattern a rule, at most 64 members a list, no `Not` or aggregate beside it.

### Equality: classes of equal things

A rule whose head gives `cepheus/same` (system property 6) makes its two things **the same thing**: OWL's owl:sameAs,
which the W3C's rules axiomatise (eq-ref, eq-sym, eq-trans: an equivalence; eq-rep-s, eq-rep-p, eq-rep-o: a fact of one
is a fact of the other). Written as rules, n equal things hold n² sameAs facts derived 2n³ + n² + n times, and every
fact of each is copied onto all n (Motik, Nenov, Piro, Horrocks [Motik 2015b], section 3). Cepheus keeps them by
**rewriting** instead, as RDFox does [Motik 2015b]:

- **Classes.** The things made equal form a class, held in a union-find (Tarjan [Tarjan 1975]) merged smaller into
  larger: one member is the class's **representative**, and each other member x holds one derived fact
  `[x, cepheus/same, r]`, journaled like any derived fact (replicas, replay and the past need nothing more). A thing
  changes class O(log n) times over any sequence of merges.
- **Rewriting.** The facts of a class are kept on its representative: a merge moves the facts only derived of the
  smaller side's representative onto the larger's, and a fact a program asserted stays where it was written, its
  rewriting beside it. The rules read the facts of representatives only; their heads name representatives. So a
  class of n things costs n − 1 facts of `cepheus/same`, and each fact is derived once for the class, not once for
  each member.
- **One fact at a time.** The equalities a fact gives are applied before the round's next fact runs, as RDFox's
  fact-at-a-time evaluation does: the facts they make outdated start nothing. A functional property with n values on
  one thing costs O(n) rule instances, not the n² pairs a round would enumerate (measured: 3,000 things made one in
  0.05 s; 3.95 s before).
- **Reads.** A question, `get`, `values` and `things` read a thing they name as its class's representative (one
  lookup); `same v x` lists the class. An answer binds the representative for derived facts; a fact a program asserted
  about another member is also there, as written.
- **Retraction.** A retraction that may undo an equality takes the class apart and derives it again (Delete-Rederive
  for the class, [Gupta 1993]): when a rule instance that gave an equality loses a fact, when B/F meets a fact only
  derived that names a class of several things, or when a write retracts a fact of a member, each member becomes its
  own representative again, every fact only derived that names the representative is deleted (its consequences
  checked by B/F), and the asserted facts of the members are derived again from scratch, equalities included. It is
  exact; B/F on equalities (Motik, Nenov, Piro, Horrocks, IJCAI 2015) would re-derive less, and is left for later.
- **Limits.** Two different values are never the same thing: a rule that would make them so refuses the group
  (prp-fp over a property with two values). A property is the same as no other. A thing the rules name as a constant
  (owl:Thing, a class an unfolded rule names) keeps its own identity: a merge of it refuses the group. A rule set that
  makes things the same takes no `Not` and no aggregate yet. With equality, the closure modules, the path of loads and
  the parallel rounds are off; equality rules over a relation with no fact are left out of the unfolded program, so a
  database whose ontology makes nothing the same keeps them.
- **Why.** A fact of a representative that rewrites a member's asserted fact is proved by a node `cepheus/same` whose
  children are that fact and the facts of the classes; the proof of an equality itself is not given yet (G20).

## What it costs, and against the giants

Measured on this laptop (Intel i7-4720HQ, 2.6 GHz, 4 cores; OCaml 5.5 without flambda), on LUBM-shaped data
(universities, departments, people, courses, generated from the published ranges of the LUBM generator [Guo 2005],
not its official output) with the univ-bench ontology as 94 rules, one an axiom. Seven rounds, alternated, each
process capped at 3 GB; the median and the interval $[x(1), x(7)]$ of the rounds (98.4 % coverage). The method and
every number: [benchmarks](benchmarks.md#rules-2026-11-08), and for loads
[the path of loads](benchmarks.md#rules-step-3-the-path-of-loads-sorted-and-parallel-2026-11-14).

| what | with the rules | without | |
|---|---|---|---|
| write a graduate student (10 facts; 6 derived) | **23.1 µs** [21.9, 24.1] | 9.1 µs | 2.5× |
| retract it (B/F: the 6 derived facts go) | **34.1 µs** [33.1, 54.8] | 6.9 µs | 4.9× |
| `why` of a derived type (a proof of 2 to 8 facts) | **1.2 to 3.1 µs** | | |
| load 10 universities in one group (1.35 M facts, 532,205 derived, 2,021,310 derivations), durable | **1.78 s** [1.66, 2.27] | 1.06 s | |
| its reasoning: the rounds alone (saturation), on 8 threads | **1.92 M derived facts/s** [1.58, 2.04] | | |
| its reasoning whole (the group's facts made ready for the joins, 0.13 s, included) | **1.29 M derived facts/s** (0.41 s) | | |
| the same load as ten groups, a university each: peak resident memory | **133 MB** | | |
| a derived fact put into the view (a delta of 200,000 changes) | **0.83 µs** in sorted batches; 1.12 µs one by one | | |
| OWL 2 RL whole (`Cepheus.Owl`) against step 2's ten W3C rules, LUBM-10 in one load: reasoning | **0.512 s** against 0.543 s | | 0.92 |
| the same, LUBM-1 a group a department: reasoning | **0.277 s** against 0.247 s | | 1.15 |
| equality by rewriting against axiomatised, UOBM-like (one university, 6,558 duplicate records) | **1.066 s** against 1.957 s | | 1.84× faster, 3.27× fewer derivations |
| a class of 100,000 things (a functional property's storm) | **1.42 s**, 99,999 facts of `cepheus/same` | | axiomatised: past the budget from 400 things |

The OWL 2 RL and equality numbers: [benchmarks](benchmarks.md#rules-step-6-owl-2-rl-and-equality-by-rewriting-2026-11-14).
The write path without rules is unchanged: the same student groups on main's binary and this one, 9.06 µs and
9.06 µs to write, 7.15 and 6.20 µs to retract; start-up, 2 % more for the reasoner's code
([benchmarks](benchmarks.md#rules-2026-11-08)).

Beside the published numbers of the systems that materialise Datalog (their machines and data, not ours; numbers
marked *computed* are ours from their tables):

| system, source | test | published |
|---|---|---|
| RDFox, Motik et al., AAAI 2014 [Motik 2014] | LUBM-L 1K, 133.6 M → 182.4 M facts | 73 s on one thread: **0.67 M derived/s** (computed); 7.0 M/s on 32 threads; 2 × Xeon E5-2650 (2.0 GHz) |
| VLog, Urbani et al., AAAI 2016 [Urbani 2016] | LUBM-L 1K | 38 s on one thread: about **1.28 M derived/s** (computed); a 2.2 GHz laptop |
| RDFox B/F, Motik et al., AAAI 2015 [Motik 2015] | LUBM-1k-L, delete 100 facts | "0.0 s" in its table (below its rounding) |
| Soufflé, Scholz et al., CC 2016 [Scholz 2016] | a points-to analysis of OpenJDK 7, about 840 M tuples | 75 s sequential, 35 s parallel (4 cores): another workload, given for the order of magnitude |

- **One core, saturation**: 1.04 M derived facts/s here (step 1), 0.67 M/s for RDFox 2014, about 1.28 M/s for VLog:
  the same order; VLog's published rate stays ahead by 1.2×, on another machine and a hundred times more data.
- **In parallel, a load's facts sorted** (step 3): the rounds 1.92 M/s on this laptop's 4 cores (8 threads), the
  reasoning whole 1.3 to 1.6 M/s, 0.33 to 0.40 M/s a core: close to RDFox 2014's 0.44 M/s a core at 32 threads; RDFox
  reaches 7.0 M/s in all on its 16 cores.
- **Small writes**: microseconds, in the process. No giant publishes a per-group latency to compare with.
- **Where the reasoner costs the most**: a retraction, 4.9 times the same group without rules. B/F checks each fact
  that lost a derivation against every rule that can give it, each check a lookup in the store's persistent maps or
  runs (34 lookups for one student); the prototype of the design, over hash tables of its own, took 19.1 µs.

**Closures and the W3C's form** (the design's step 2; [benchmarks](benchmarks.md#rules-step-2-closures-and-the-w3cs-form-2026-11-12)):
the closure module computes the 100,000-node hierarchy's 683,496 new facts in **22.5 ms** (prp-trp as a rule: 0.92 s
of reasoning) and the random DAG's 1,344,791 in **47.3 ms** (17.6 s), each new fact made once; LUBM-shaped data with
the ontology as facts and the 10 W3C rules, unfolded, reasons in **1.10×** the time of the 94 rules written one an
axiom for a load and 1.05× group by group, for the same derived facts of the data (the design's prototype, running
the W3C rules as written: 2.2×).

## The choices behind this design

Each was weighed against the others in the design; the measurements are the design's prototype's unless said.

- **Materialise at the write, not reason at the question.** Questions read derived facts at the speed of any fact;
  the price is the memory of the derived facts (+40 % on LUBM-shaped data) and the writes' reasoning. Systems that
  reason at the question (Stardog by query rewriting, TypeDB 3 by functions evaluated on demand, Datomic's rules as
  query inputs) pay the derivations at every question instead.
- **Backward/Forward, not counting or DRed** (above): counting is wrong on recursive rules; DRed explores the
  consequences, B/F the support (one student: 19.1 µs against 216 µs).
- **Derived facts in the journal, not recomputed**: replay, replicas and the past need no reasoner, and a change of
  the reasoner's code never changes the past; the frame carries the derived facts (+40 % bytes on LUBM).
- **`why` computed when asked, not stored**: nothing paid at write time; a proof, not the shortest one.
- **A derived fact cannot be retracted**: no silent no-op; the message names the rule and the facts to retract.
- **The flag in the value's field** (bit 63 of the value word in format 6, the lowest bit of the field in the
  blocks of formats 7 and 8 that hold a derived fact): no byte more without rules; a run of a newer format is not read by an older
  binary, which replays the journal instead.
- **Closures by a module, not by their rules**: each closure fact found once instead of once a path (Hu et al.
  [Hu 2019]); the two shapes recognised are the only ways the engine closes a property, any other way of writing a
  closure runs as rules.
- **Generic rules unfolded by the engine, not written one an axiom by hand**: one way to write rules (the ontology is
  data), at the unfolded rules' speed; a write to the ontology runs the rules as written for that group.
- **The budget scaled by the group** ($100{,}000 + 100 \times \text{its asserted changes}$): a load derives in proportion, a runaway
  rule is stopped and named.

## What is not here yet

The design's plan has six steps; this version has the six.

- **Step 3's rest**: the joins of a change's rounds in the background probe the store fact by fact, on the change's
  one domain.
- **Step 5's rest**: a change with new things is computed in the group; only the derived facts of properties of many
  values, none unique, go into a change's run of its own (the others enter the delta); step 5's two targets are not
  both reached: 2 M derived facts a second for the build (2.9 M), not with its run's write (1.8 M: the run's write is a
  third of it); the writers in a change's window, 0.83 of their throughput without it, paired, with no disk stall
  (0.92 against the median window), the install's coding and its last catch-up the writer's part of it
  ([benchmarks](benchmarks.md#rules-step-5s-targets-again-a-changes-install-without-a-record-a-fact-2026-11-19)).
- **Step 6's rest**: B/F on equalities (Motik et al., IJCAI 2015 [Motik 2015c]) instead of taking a class apart; the
  proof of an equality in `why`; equality beside `Not` and aggregates, the closure modules, the path of loads and the
  parallel rounds.
- The budget as a database setting rather than a number of the process; the group that asserted each leaf of a proof.

## References

Every work cited here is in [references](references.md#rules-datalog-materialisation-and-its-maintenance), with what
Cepheus took from it: [Abiteboul 1995], [Bancilhon 1986], [Ramakrishnan 1990], [Feeley 1987], [Gupta 1993],
[Motik 2015], [Motik 2019], [Apt 1988], [Przymusinski 1988], [Mumick 1990], [Motik 2014], [Urbani 2016], [Scholz 2016],
[Subotic 2018], [Zhao 2020], [Guo 2005], [Hu 2019],
[Hu 2022], [Tarjan 1972], [Nuutila 1995], [Jones 1993], [W3C 2012], [Motik 2015b], [Motik 2015c], [Tarjan 1975],
[Ma 2006], [Leis 2014], [Budiu 2023].
