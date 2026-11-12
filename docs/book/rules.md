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
  ([below](#a-property-as-a-variable-the-w3cs-form-of-owls-rules)); negation (`Not`) and aggregates (`Sum`, `Count`)
  are the next steps of the design.

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
- **Retraction** stays B/F's, with the two rules' ordinary plans: correct (B/F is correct for any Datalog program),
  not yet with the module's walks (the design's section 5.7; [what is not here yet](#what-is-not-here-yet)).

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

After the group's fixpoint, the constraints' plans run on every fact the group made present: an instance of a
constraint can only appear through a new fact (rules without negation are monotone), so this finds every violation
the group would make. Defining a constraint checks it over the whole database.

The schema's own rules apply to derived facts too: a rule that would give a second value of a one-valued property,
or a value of a unique property another thing holds, refuses the group and names the rule.

## The budget

A rule can derive a great deal from a small write (every pair of members of a club). The writer refuses a group
whose derived changes pass **$100{,}000 + 100 \times \text{its asserted changes}$**: `Invalid "rule NAME derived more than N facts
from a group of K facts"`, naming the rule that derived the most. The scaled part lets a load derive in proportion;
the fixed part bounds what a small write can cost the other writers, who wait for it (about 0.1 s of reasoning at
the budget). `rule_budget` holds the two numbers. Every path counts against it: each rule instance's new fact, each
fact a closure module makes, a closure's targets as they grow (so that a dense graph's $n^2$ facts are refused before
they are made, in memory in proportion to the budget), and the facts B/F deletes.

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
both under the budget, in that group: a rule change takes effect at one group number, every view before it the
materialisation under the old rules, every view from it under the new (G19).

The rules are compiled at the first write that needs them, never at open: an open replays frames, which hold the
derived facts already, so start-up does not grow.

## Large groups

A group of 20,000 additions and more (a load) takes the path of large groups ([architecture](architecture.md#large-groups)):
its facts are mapped into compact arrays and merged into a run at once. With rules, its facts are the round 0 of the
same semi-naive evaluation, in the working set, and the derived facts are appended to the group's arrays: they reach
the run with the asserted ones, in one merge. A group that the faster path cannot decide alone (a constraint, a head
on a one-valued or unique property, a fact derived already and now asserted) takes the ordinary path, which decides
as always. A rule's text that the group itself adds is found among the group's new texts, which the dictionary's map
does not hold yet (the simulation found that case: without it, a pattern on such a text matched nothing).

## What it costs, and against the giants

Measured on this laptop (Intel i7-4720HQ, 2.6 GHz, 4 cores; OCaml 5.5 without flambda), on LUBM-shaped data
(universities, departments, people, courses, generated from the published ranges of the LUBM generator [Guo 2005],
not its official output) with the univ-bench ontology as 94 rules, one an axiom. Seven rounds, alternated, each
process capped at 3 GB, nothing else running; the median and the interval $[x(1), x(7)]$ of the rounds (98.4 %
coverage). The method and every number: [benchmarks](benchmarks.md#rules-2026-11-08).

| what | with the rules | without | |
|---|---|---|---|
| write a graduate student (10 facts; 6 derived) | **23.1 µs** [21.9, 24.1] | 9.1 µs | 2.5× |
| retract it (B/F: the 6 derived facts go) | **34.1 µs** [33.1, 54.8] | 6.9 µs | 4.9× |
| `why` of a derived type (a proof of 2 to 8 facts) | **1.2 to 3.1 µs** | | |
| load 10 universities in one group (1.35 M facts, 532,205 derived, 2,024,788 derivations), durable | 2.48 s | 1.20 s | |
| its reasoning: the saturation alone | **1.04 M derived facts/s** [0.98, 1.05] on one core | | |
| its reasoning with the working set's build (1.35 M facts indexed, 0.58 s) | 0.52 M derived facts/s [0.49, 0.53] | | |
| a derived fact put into the view (a delta of 200,000 changes) | **0.83 µs** in sorted batches; 1.12 µs one by one | | |

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

- **One core, saturation**: 1.04 M derived facts/s here, 0.67 M/s for RDFox 2014, about 1.28 M/s for VLog: the same
  order; VLog's published rate stays ahead by 1.2×, on another machine and a hundred times more data.
- **Counting the working set's build** (a load's facts indexed for the joins, which the published rates count in
  their load), 0.52 M/s: RDFox 2014's level, behind VLog by 2.5×. The next step of the design sorts a load's facts
  instead of hashing them (VLog's own method).
- **In parallel**: not yet; RDFox reaches 7.0 M/s on 32 threads.
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

The design's plan has six steps; this version has the first two.

- **Retraction by the closure module's walks** (the design's section 5.7: the sources that reach a removed edge, each
  walked again; Hu et al. [Hu 2022]: small deletions in 1 s against 585 s): B/F does it now, exactly, at a cost in
  proportion to the facts it checks and their derivations.
- **Step 3**: large derivations sorted and parallel, on several domains. Until then a small group whose consequences
  are large (a graph of 15,000 edges whose closure has 1.3 million facts) puts them into the view's delta one by one
  in sorted batches, about a microsecond a fact; a group of 20,000 facts or more takes the large groups' path.
- **Step 4**: stratified negation (`Not`) and aggregates (`Sum`, `Count`, `Min`, `Max`).
- **Step 5**: rule changes with large consequences computed in the background and installed at one group.
- **Step 6**: OWL 2 RL as a library of rules, and equality (`owl:sameAs`) by rewriting.
- The budget as a database setting rather than a number of the process; the group that asserted each leaf of a proof.

## References

Every work cited here is in [references](references.md#rules-datalog-materialisation-and-its-maintenance), with what
Cepheus took from it: [Abiteboul 1995], [Bancilhon 1986], [Ramakrishnan 1990], [Feeley 1987], [Gupta 1993],
[Motik 2015], [Motik 2019], [Motik 2014], [Urbani 2016], [Scholz 2016], [Zhao 2020], [Guo 2005], [Hu 2019],
[Hu 2022], [Tarjan 1972], [Nuutila 1995], [Jones 1993], [W3C 2012].
