# Règles

Une **règle** dérive des faits à partir de faits : « si x est une facture, et qu'une facture est une sorte de document,
alors x est un document ». Cepheus garde les faits que dérivent ses règles, les **faits dérivés**, comme des faits
comme les autres, à jour à chaque écriture : une question les lit à la vitesse de n'importe quel fait, et ne sait rien
des règles. Cette page dit ce qu'est une règle, comment le writer (le seul thread qui applique les groupes, un à la
fois) garde ses conséquences exactes (les algorithmes, et pourquoi ceux-là), ce que coûte une écriture avec des
règles, et ce qu'elle promet. Les promesses exactes sont G17 à G20 dans les [garanties](guarantees.md) ; les chiffres
sont dans les [benchmarks](benchmarks.md#règles-2026-11-08) ; chaque terme est aussi dans le [glossaire](glossary.md).

## Une règle est une question avec une conclusion

Une règle s'écrit comme une question ([concepts](concepts.md#les-questions)) : des **patterns** `[thing, property,
value]` dont la chose et la valeur sont des constantes ou des variables, et des intervalles facultatifs sur des
variables int, date et money ; et une **tête**, un pattern de plus, le fait que la règle donne pour chaque réponse de
son corps. C'est du **Datalog**, le langage de règles des bases de données déductives : une règle `H ← B1, …, Bn` dit
que chaque fois que B1 à Bn sont des faits pour certaines valeurs des variables, H est un fait pour les mêmes valeurs
(Abiteboul, Hull, Vianu, *Foundations of Databases*, 1995, chapitres 12-13 [Abiteboul 1995]).

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

- La règle est **récursive** : la propriété de sa tête, `thing/type`, est aussi dans son corps, donc un fait dérivé
  (x est un document) peut relancer la règle (x est un enregistrement). La récursion est ce
  qu'une question seule ne sait pas faire : « chaque sorte de document », à n'importe quelle profondeur.
Les classes sont des choses (65536 la classe facture, 65537 la classe document, 65538 la classe enregistrement) ; x est 65539 ;
la propriété 16 est `thing/type`, 17 `class/parent`.

- Le writer a dérivé les deux types de x **dans le propre groupe de x**, avant que l'écriture revienne : la frame du
  groupe sur le disque les tient (G1, G2), et chaque vue à partir de ce groupe les montre.
- **Why** a donné une preuve : x est un enregistrement par `is-a`, d'après « x est un document » (lui-même par `is-a`, d'après
  deux faits affirmés) et « un document est un enregistrement » (affirmé).
- Retirer « x est un document » est refusé : une règle le dérive, et le dériverait à nouveau ; le message nomme la
  règle et les faits affirmés à retirer à la place. Retirer la prémisse « x est une facture » enlève les deux types
  qu'elle seule donnait, dans le même groupe.

Les règles d'une règle, vérifiées quand elle est écrite (une erreur est `Invalid`, qui nomme la règle) :
- **Range restriction** (qu'on appelle aussi *safety*) : chaque variable de la tête apparaît dans un pattern du corps.
  Une règle ne donne donc des faits que sur des choses et des valeurs que la base tient déjà, et l'ensemble des faits
  dérivés est fini.
- **Types** : une variable a un seul type, tiré des patterns où elle apparaît, comme dans une question ; la propriété
  de la tête doit exister, ne doit pas être une propriété `cepheus/`, et doit prendre le type de la valeur de la tête.
- **Aucune nouvelle chose** : une tête nomme des variables du corps ou des choses existantes. (Le Datalog avec de
  nouvelles choses dans les têtes, les *existential rules*, peut dériver sans fin ; le Datalog sans elles finit
  toujours : son *least model* ci-dessous est fini.)
- La propriété d'un pattern est une constante, comme dans une question, ou une variable liée par un autre pattern
  ([plus bas](#une-propriété-comme-variable--la-forme-des-règles-dowl-du-w3c)) ; un corps peut tenir des `Not` et une tête un
  agrégat (`Sum`, `Count`, `Min`, `Max`), avec leurs propres règles ([plus bas](#la-négation-et-les-agrégats--les-strata)).

## Ce que tient la base : le least model

Les faits qu'écrit un programme sont les faits **affirmés** (l'extensional database, EDB, dans le vocabulaire de
Datalog) ; les règles ajoutent les faits **dérivés** (l'intensional database, IDB). Cepheus tient exactement le
**least model** (le plus petit modèle) : le plus petit ensemble de faits qui contient les faits affirmés et qui est
fermé par les règles (on ne peut plus rien en dériver). Il existe et il est unique pour le Datalog sans négation :
c'est le least fixpoint (le plus petit point fixe) de l'opérateur « ajouter chaque tête que donnent les règles sur
les faits courants », atteint en appliquant l'opérateur jusqu'à ce que rien ne change ([Abiteboul
1995], chapitre 12). C'est **G17** : chaque vue —
n'importe quel groupe, n'importe quel processus, un fork, après un crash — tient le least model de ses faits affirmés
sous les règles définies à son groupe, et un fait dérivé est dans la vue si et seulement s'il a une preuve.

Chaque fait se souvient s'il est affirmé. Un fait peut être les deux (un programme l'a affirmé, et une règle le
dérive) :

| le programme écrit | le fait était | il devient | la sorte dans la frame |
|---|---|---|---|
| `Add` | absent | affirmé | 1 `Added` |
| `Add` | seulement dérivé | affirmé (et toujours dérivé) | 4 `Now_asserted` |
| `Retract` | affirmé, et aucune règle ne le dérive | absent | 0 `Retracted` |
| `Retract` | affirmé, et une règle le dérive encore | seulement dérivé : il reste | 5 `Now_derived` |
| `Retract` | seulement dérivé | refusé : `Invalid "[#x p v] is derived by rule R from …: retract one of those"` | — |

La dernière ligne est un choix ([les choix](#les-choix-derrière-cette-conception)) : un fait dérivé ne peut pas être
retiré, puisque ses prémisses le dériveraient à nouveau ; le message nomme la règle et les faits d'où il vient, qui
sont ce qu'un programme peut retirer.

## Comment le writer la tient à jour : la semi-naive evaluation

Recalculer le least model après chaque écriture coûterait toute la base à chaque écriture. Le writer travaille plutôt
sur ce que change chaque groupe, le **delta** ($\Delta$) du groupe, et ne dérive que ce que le changement rend dérivable.

**L'insertion, par semi-naive evaluation** (Bancilhon et Ramakrishnan 1986 [Bancilhon 1986], §3.2.2 : évaluer « the
differential … instead of the entire » set à chaque étape, la différence au lieu de l'ensemble entier). Les additions
affirmées du groupe sont le tour 0. Au tour $r$, chaque fait du tour $r$ est mis en correspondance avec chaque atome du
corps de chaque règle où il convient ; les autres atomes sont joints sur les faits : ceux d'avant l'atome mis en
correspondance sur les faits des tours d'avant $r$, ceux d'après sur les faits jusqu'à $r$. Chaque instance de règle (une
règle avec un fait pour chacun de ses atomes) est ainsi énumérée exactement une fois, à son fait le plus récent — la
*propriété semi-naive* (Ramakrishnan, Srivastava, Sudarshan 1990 [Ramakrishnan 1990]) — et les têtes qui ne sont pas
encore des faits forment le tour $r + 1$. Quand un tour ne produit rien de nouveau, les faits dérivés du groupe sont
complets.

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

Le travail est le nombre d'instances de règles trouvées, chacune payée une fois : $\Theta(D)$ pour $D$ dérivations. Le modèle de
coût d'un groupe est alors
$D \times (\text{le coût d'une dérivation : ses joins et le test de sa tête}) + \text{les nouveaux faits} \times (\text{mettre un fait dans la vue})$ ;
les [benchmarks](benchmarks.md#règles-2026-11-08) mesurent les deux.

**Comment joint un plan.** Chaque règle est compilée une fois, quand les règles changent, en une closure (une fonction
avec son environnement) par atome du corps (un *plan* : l'atome mis en correspondance avec un fait donné, les autres
joints dans un ordre fixe), comme Feeley et Lapalme compilent du code en closures [Feeley 1987] ; rien n'est
interprété par fait. L'ordre des autres atomes est choisi d'après les comptes exacts du store : l'atome qui a le moins
de candidats d'abord. Une constante n'est pas sélective (`[x, type, Person]` a des dizaines de milliers de lignes) ; une
variable liée par un atome précédent l'est en général (`[x, takesCourse, c]` avec x lié : une poignée). Les plans sont
répartis par propriété, et par (propriété, valeur) pour un atome dont la valeur est une constante : un fait de `type` ne
lance que les plans de sa classe.

## Les transitive closures : le closure module

Une propriété **transitive** relie une chose à tout ce qu'elle atteint : « un groupe de recherche fait partie d'un
département, un département d'une université, donc le groupe fait partie de l'université ». Deux formes de règles le
disent, et le writer reconnaît les deux ; ce qu'elles donnent est la **transitive closure** de la propriété (la
« fermeture transitive » des mathématiques : chaque couple de choses reliées par un chemin) :

```text
prp-trp (OWL 2 RL's rule):      [x T y] [y T z] -> [x T z]           the edges and the closure in one property
the linear pair:                [x E y] -> [x T y]
                                [x E y] [y T z] -> [x T z]           the edges E apart from the closure T
```

Exécutées comme des règles, elles dérivent chaque fait de la closure de nombreuses fois : prp-trp dérive $(x, z)$ une
fois pour chaque $y$ entre eux, donc une chaîne de $n$ choses coûte environ $n^3/6$ dérivations pour $n^2/2$ faits (166
par fait à $n = 500$, la mesure de la conception) ; la règle linéaire, une fois pour chaque arête qui part de $x$ sur un
chemin vers $z$. Un **closure module** (un module qui calcule une closure à part des règles ; Hu, Motik, Horrocks
[Hu 2019], [Hu 2022]) trouve au contraire chaque nouveau fait de la closure une seule fois, par des parcours :

- **De zéro**, au premier travail du module dans un groupe dont l'état d'avant ne tenait aucun fait de T, ou quand ses
  règles sont nouvelles : les **strong components** du graphe (les composantes fortement connexes : les ensembles de
  choses qui s'atteignent toutes les unes les autres ; Tarjan [Tarjan 1972]), dans un ordre où une composante vient
  après chaque composante qu'elle atteint, et les cibles de chaque composante sont l'union de celles de ses successeurs
  et de ces successeurs (ce qu'atteint une composante est partagé par ses membres : Nuutila [Nuutila 1995]). Chaque
  cible est essayée une fois par successeur, chaque nouveau fait est créé une fois par source, sans test de hachage :
  les faits déjà présents sont exactement les entrées, sautées grâce à une marque.
- **De façon incrémentale**, pour une nouvelle arête $(a, b)$ sur une closure déjà dans la base : les nouveaux faits
  sont les choses qui atteignent $a$ (et $a$) croisées avec $b$ et ce que $b$ atteint, moins ceux qui sont présents.
  Avec prp-trp, la closure est close, donc « ce qui atteint $a$ » est une seule recherche des faits de $T$ vers $a$ ;
  avec la paire linéaire, c'est un parcours à rebours sur $E$, et un nouveau fait de $T$ donné d'une autre façon
  (affirmé, ou par une autre règle) remonte le long de $E$ de la même façon.
- Les faits du module rejoignent le tour suivant de la semi-naive evaluation comme n'importe quel fait dérivé, donc les
  autres règles les voient ; quand rien d'autre ne lit $T$ ni ne donne $T$ ou $E$, la closure d'un chargement va droit
  à la sortie du groupe.
- **Le retrait par parcours**, quand aucune autre règle ne donne $T$ ni $E$ (les arêtes sont alors exactement les faits
  que le groupe laisse affirmés : le $T$ de prp-trp, ou $E$) : les sources dont les cibles peuvent rétrécir sont les
  débuts des arêtes retirées et ce qui les atteint ; leurs nouvelles cibles sont calculées comme de zéro, sur leurs
  strong components, leurs successeurs d'abord, une chose qui n'atteint aucune arête retirée gardant ses cibles
  entières (elles ne peuvent pas changer) ; ce qu'une source tenait au-delà de ses nouvelles cibles part, soit
  exactement les faits laissés sans chemin (Hu, Motik, Horrocks [Hu 2022] : de petites suppressions en 1 s avec des
  modules contre 585 s par B/F). Les pertes atteignent les autres règles comme celles de B/F, et chaque perte compte
  contre le budget. Sinon (une autre règle donne $T$ ou $E$), B/F décide, par les plans des deux règles : exact pour
  n'importe quel programme Datalog, plus lent sur les closures profondes.

Une propriété est close par le module quand ses règles ont exactement une de ces formes (des variables distinctes,
aucune constante, aucun intervalle), qu'elle relie des choses à des choses, prend plusieurs valeurs et qu'aucune n'est
unique. Une autre règle sur la même propriété tourne comme une règle à côté de lui.

## Une propriété comme variable : la forme des règles d'OWL du W3C

Les règles d'OWL 2 RL (la partie d'OWL, le langage d'ontologies du W3C, que des règles calculent entièrement, plus
bas) s'écrivent sur les faits de l'ontologie (les faits qui décrivent les classes
et les propriétés, comme « un professeur est une personne »), avec la propriété en variable : `prp-dom` dit « si le
domaine de $p$ est $c$ et que $x$ a une valeur de $p$, $x$ est un $c$ » ([W3C 2012], §4.3). La propriété d'un pattern
peut être une variable, `prop_var k` pour `?k` :

```text
[c, domainOf, ?p] [x, ?p, y] -> [x, type, c]          prp-dom
[a, transitive, ?p] [x, ?p, y] [y, ?p, z] -> [x, ?p, z]   prp-trp over the ontology
```

- **Liée par une constante** : un autre pattern du corps, dont la propriété est une constante, a `?k` pour chose ou
  pour valeur, donc aucun pattern ne parcourt tous les faits (vérifié quand la règle est écrite).
- **Les types à l'instance** : une valeur lue sous une propriété variable a le type de cette propriété ; une variable
  qui n'apparaît que là le prend, et chaque autre pattern où elle apparaît doit être d'accord, sinon l'instance
  n'existe pas. Un fait que donne une tête doit convenir à sa propriété (une propriété de l'application, du type de la
  valeur, sur une chose), sinon le groupe est refusé, avec le nom de la règle :
  `rule prp-spo1 gives worksFor a value of another type`.
- Dans une chose de propriété (les numéros 16 à 65 535), seuls les faits `cepheus/` sont gardés, donc un axiome (un fait
  de l'ontologie) sur une propriété la nomme comme valeur : « le domaine de `advisor` est `Person` » s'écrit
  `[Person, domainOf, advisor]`, et « `headOf` est une sous-propriété de `worksFor` » est une chose à elle,
  `[a, subProperty, headOf] [a, superProperty, worksFor]`.

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

## La spécialisation par petites relations

Exécutée telle qu'écrite, une telle règle est lente : chaque fait lance chaque plan dont la propriété est une variable,
et chacun cherche dans l'ontologie avant de trouver quoi que ce soit (la conception a mesuré 2,2× sur LUBM, le Lehigh
University Benchmark : des données d'universités, un test classique des moteurs de raisonnement). Le writer l'exécute
plutôt **dépliée** (unfolded) : un atome sur une relation (les faits d'une propriété) qui a peu de faits (au plus
10 000, d'après les comptes exacts du store), dont les variables sont celles sur lesquelles un autre atome de la règle
répartit les faits (sa propriété, ou sa valeur sous une propriété constante : une classe), est remplacé par chacun de
ses faits, la règle devenant une règle par fait, avec les constantes en place. C'est de la **partial evaluation**
(l'évaluation partielle : exécuter d'avance un programme sur la partie connue de ses entrées ; Jones, Gomard, Sestoft
[Jones 1993]) des règles sur l'ontologie, ce que font à la main les utilisateurs de RDFox (un moteur de raisonnement
Datalog en mémoire) quand ils traduisent chaque axiome en sa propre règle [Motik 2014] :

```text
[c, domainOf, ?p] [x, ?p, y] -> [x, type, c]      over  [Person, domainOf, advisor]
                                                  gives [x, advisor, y] -> [x, type, Person]
```

Des atomes sur de petites relations qui partagent une variable sont dépliés ensemble
(`[a, subProperty, ?p] [a, superProperty, ?q]` donne une règle par chose d'axiome), un intervalle sur une variable
dépliée ne garde que les faits qui sont dedans, et une règle dépliée qui ne peut avoir aucune instance (une propriété
qui ne prend pas la valeur) est abandonnée. Un `prp-trp` déplié est une simple règle transitive sur une seule
propriété, que le closure module exécute ensuite.

Les règles dépliées donnent exactement les mêmes faits que les règles génériques tant que les relations gardent les
faits sur lesquels elles ont été dépliées ; ces relations sont donc **figées** (frozen) :
- À chaque groupe, le writer vérifie que la vue tient ces faits : par identité d'abord (les runs — les copies triées de
  l'état, dans des fichiers — et les entrées du delta de chaque relation — les changements récents gardés en mémoire —
  sont les mêmes objets que lors de sa dernière vérification : quelques comparaisons de pointeurs), sinon par les faits
  eux-mêmes.
- Un groupe qui affirme, retire, dérive ou supprime un fait d'une relation figée est raisonné avec les règles telles
  qu'écrites (commencé déplié, il recommence), et le groupe suivant déplie à nouveau sur les nouveaux faits. Une
  relation qu'un groupe a changée est une relation des données, pas de l'ontologie (la relation `type` d'une base vide
  est petite au début) : on ne déplie plus sur elle tant que les règles et la taille de la base ne changent pas.
- On ne déplie sur une relation que si elle ne dépend pas de ce que donnent les règles dépliées : aucune chaîne de
  règles ne mène de leurs têtes à elle. Sinon un fait de cette relation pourrait perdre sa preuve par les règles où il
  a été déplié, ce que seules les règles telles qu'écrites vérifient (le writer garde une telle règle telle qu'écrite).
  Ainsi, un fait d'une relation figée ne change que par un groupe qui l'affirme, ou qui le dérive ou le supprime, ce
  que le writer voit.
- `why` utilise les règles telles qu'écrites : une preuve nomme la règle générique, et ses feuilles comprennent les
  faits de l'ontologie.

## Le retrait : Backward/Forward

Quand un fait part, les faits dérivés de lui peuvent partir, sauf s'ils ont une autre preuve. Trois algorithmes sont
connus :

- Le **counting** (le comptage) garde, pour chaque fait dérivé, le nombre de ses dérivations, et supprime un fait
  quand son compte atteint zéro (Gupta, Mumick, Subrahmanian 1993 [Gupta 1993], pour des vues non récursives). Il est
  rapide et **faux pour les règles récursives** : avec `member` et `memberOf` inverses l'un de l'autre, chacun des deux
  faits est une dérivation de l'autre ; une fois le fait affirmé parti, chacun garde un compte de un venu de l'autre,
  et ils ne partent jamais. Le test `rules: inverse properties support each other` vérifie que Cepheus retire les deux.
- **DRed** (delete and rederive, supprimer puis redériver, [Gupta 1993]) supprime d'abord chaque conséquence des faits
  supprimés, puis dérive à nouveau ceux qui ont encore une preuve : il explore les *conséquences*, souvent bien au-delà
  de ce qui part vraiment.
- **Backward/Forward** (B/F, Motik, Nenov, Piro, Horrocks 2015 [Motik 2015]) explore le *support* : un fait qui a perdu
  une dérivation est vérifié par backward chaining (le chaînage arrière) — est-il affirmé, ou y a-t-il une instance de
  règle dont les faits du corps sont prouvés ? — sur les faits courants moins ceux déjà réfutés. Chaque fait est
  vérifié une fois, donc les cycles finissent ; un fait prouvé se propage vers l'avant parmi les faits vérifiés ; un
  fait laissé sans preuve est supprimé, et les faits que donnaient ses instances sont vérifiés à leur tour. Cepheus
  utilise B/F.

Trois détails le rendent exact ici, chacun trouvé par le test de propriété de G17 avant d'être juste (le test compare
chaque vue au least model calculé de zéro) :
1. Les instances que perd un fait supprimé sont énumérées sur les faits *d'avant* son départ (il peut remplir deux
   atomes d'une même instance : `[y, a, x], [x, a, y]` avec $x = y$).
2. Un fait que le groupe retire n'est plus affirmé dès ce moment, mais reste parmi les faits jusqu'à ce que B/F
   tranche à son sujet : deux faits retirés peuvent être les deux prémisses d'un même fait dérivé.
3. Un fait retiré puis affirmé à nouveau dans un même groupe est affirmé, et n'est jamais un candidat.

Mesuré dans le prototype de la conception (des données en forme de LUBM, un étudiant) : B/F 19,1 µs, DRed 216 µs,
counting 3,1 µs mais faux. Dans le moteur : [benchmarks](benchmarks.md#règles-2026-11-08).

À l'intérieur d'un groupe, les retraits sont tranchés d'abord (B/F sur l'état sans eux), puis les additions
(semi-naive) : un fait que B/F supprime et que les additions dérivent à nouveau revient, et la frame du groupe ne tient
aucun changement pour lui.

## Les contraintes : `Never`

Une règle dont la tête est `Never` est une **contrainte** : une réponse de son corps refuse le groupe, en entier (G18).

```text
{ name = "invoice-is-not-client"; vars = 1;
  where = [ { e = Var 0; p = ty; v = Thing invoice }; { e = Var 0; p = ty; v = Thing client } ];
  ranges = []; head = Never }
write db [ Add (x, ty, Link client) ]   (* x is an invoice *)
→ Error (Invalid "constraint invoice-is-not-client: [#65541 thing/type #65536] [#65541 thing/type #65537]")
```

Après le point fixe du groupe, les plans des contraintes tournent sur chaque fait que le groupe a rendu présent : sans
négation, une instance d'une contrainte ne peut apparaître que par un nouveau fait (de telles règles sont monotones).
Une contrainte avec un `Not` gagne aussi des instances par un fait parti (une facture d'un client dont le nom a été
retiré) : ses plans tournent aussi sur ceux-là, comme les bascules des Not plus bas. Cela trouve chaque violation que
ferait le groupe. Définir une contrainte la vérifie sur toute la base.

Les propres règles du schéma s'appliquent aussi aux faits dérivés : une règle qui donnerait une seconde valeur à une
propriété à une seule valeur, ou une valeur d'une propriété unique qu'une autre chose tient, refuse le groupe et nomme
la règle.

## La négation et les agrégats : les strata

Un pattern d'un corps peut être dans un **`Not`** : la réponse de la règle ne tient que si aucune valeur des variables
**propres** au Not (celles qui ne sont dans aucun pattern hors de lui) ne fait de tous ses patterns des faits. En
termes de bases de données, c'est un *anti-join* (un join qui ne garde que les réponses auxquelles rien ne
correspond). Une tête peut donner un **agrégat** des réponses du corps : pour chaque chose de la tête, un fait dont la
valeur est la somme, le nombre, la plus petite ou la plus grande valeur d'une variable sur les réponses de cette
chose. En OCaml, les deux s'écrivent dans la propriété d'un pattern, pour qu'une règle garde ses champs : `absent k p`
est la propriété `p` dans le `k`-ième Not de la règle, `aggregate f p` la propriété `p` donnée par l'agrégat `f`.

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

Leur texte canonique ajoute `; not [E P V] ...` avant la tête et `give sum [E P V]` (ou `count`, `min`, `max`) ; une
règle sans eux a le texte qu'elle avait avant. En Cesia : `cepheus.Not(...)` dans `Where`, et `cepheus.Sum(x)`,
`Min(x)`, `Max(x)` ou `Count()` comme valeur de `Then` ([les règles depuis Cesia](cesia.md#règles)).

**Ce qu'ils veulent dire.** Une règle qui lit une propriété sous `Not` a besoin que cette propriété soit d'abord
complète, et un agrégat aussi. Les règles sont rangées en **strata** (un stratum : une couche de règles) : une règle ne
lit sous `Not` ou n'agrège que ce que donnent des strata plus bas, et les strata sont calculés l'un après l'autre. Les
faits tenus sont alors le **perfect model** (le « modèle parfait ») des règles, l'unique modèle d'un programme
stratifié qui ne dépend pas de l'ordre de ses règles ([Apt 1988], [Przymusinski 1988]) ; les agrégats sont stratifiés
de la même façon ([Mumick 1990]). Un ensemble de règles où une propriété dépend de sa propre absence, ou de son propre
agrégat, n'a pas un tel ordre : `define` le refuse et nomme le cycle ; une règle `R` qui donne `status` et le lit sous
`Not` est refusée avec `Invalid "rule R: status depends on its own absence (R -> not R)"`. Les strata viennent du
graphe des règles (une arête d'une règle vers chaque règle qui lit sa tête ; négative quand elle la lit sous `Not` ou
l'agrège), dont les strong components sont trouvées par [Tarjan 1972] : une arête négative à l'intérieur d'une
composante est un cycle à travers `Not` ; le stratum d'une règle est le plus grand nombre d'arêtes négatives sur un
chemin qui mène à elle. Un nœud est une propriété précisée par une valeur constante, pour que `[?x type Invoice]` et
`[?x type Client]` soient séparés, et qu'un `Not` sur une classe puisse dépendre d'une autre.

**Leurs règles**, vérifiées à `define` :
- Un `Not` tient de 1 à 4 patterns dont les propriétés sont des constantes ; une règle en a au plus 16. Une variable
  qui n'est dans aucun pattern hors d'un `Not` est la variable propre d'un seul `Not`, et les variables de la tête sont
  hors de chaque `Not` (range restriction).
- `Sum` est pour les ints et money, `Min` et `Max` pour les ints, les dates et money ; la valeur de `Count` est
  `Val (Int 0)`, sa propriété un int. Les réponses sont comptées une fois chacune, sur les variables du corps : deux
  lignes d'un même montant sont deux réponses, puisque leur ligne diffère.
- Une somme est exacte : gardée sur deux mots, elle refuse le groupe quand le résultat dépasse le plus grand int
  (`Invalid "rule R: the sum of #x is past the largest int"`), et ne fait jamais de wrap (un entier qui déborde et
  repart des négatifs).
- La propriété d'un agrégat prend une seule valeur, n'est donnée que par cette règle, et aucune écriture ne l'ajoute
  ni ne la retire : une écriture d'elle est refusée, et définir un agrégat sur une propriété qui tient des faits
  affirmés l'est aussi, à moins que le même groupe ne les retire. Le groupe qui enlève l'agrégat peut écrire sa
  propriété.
- Une chose sans réponses n'a pas de fait (pas de compte à zéro, pas de somme de rien).

**Comment le writer les tient à jour.** Chaque stratum dans l'ordre, ceux d'en dessous complets ([Motik 2019], B/F
pour les règles stratifiées) :
1. ses agrégats, par différence : les réponses que le groupe a données et enlevées sont trouvées à partir des faits
   qu'il a changés plus bas (sur l'état d'après le groupe pour un fait rendu présent, d'avant lui pour un fait parti),
   chaque réponse une fois, par ses faits. `Sum` et `Count` sont linéaires : le changement de la somme est la somme
   des changements ([Budiu 2023]). `Min` et `Max` ne relisent les réponses de leur chose que quand son extrême est
   parti, donc au plus leur nombre ;
2. les bascules de ses `Not` : un fait rendu présent qui correspond à un `Not` enlève les réponses que ce `Not`
   permettait (les candidats de B/F) ; un fait parti donne les réponses que son absence permet désormais (ceux de
   l'insertion) ;
3. B/F sur ses candidats, puis l'insertion semi-naive à partir de chaque fait rendu présent jusque-là.

Un `Not` dont les patterns ont leurs deux côtés connus est une seule recherche par candidat. Un ensemble de règles avec
`Not` ou des agrégats tourne tel qu'écrit (sans [spécialisation](#la-spécialisation-par-petites-relations)), et un
chargement dans une base qui a ces règles prend le chemin ordinaire, pas celui des grands groupes. `why` du fait d'un
agrégat donne les faits de chaque réponse de sa chose.

## Le budget

Une règle peut dériver énormément à partir d'une petite écriture (chaque paire de membres d'un club). Le writer refuse
un groupe dont les changements dérivés dépassent **$100\,000 + 100 \times \text{ses changements affirmés}$** : `Invalid "rule NAME derived more than N facts
from a group of K facts"`, qui nomme la règle qui a le plus dérivé. La partie proportionnelle laisse un chargement
dériver en proportion ; la partie fixe borne ce qu'une petite écriture peut coûter aux autres writers, qui l'attendent
(environ 0,1 s de raisonnement au niveau du budget). `rule_budget` tient les deux nombres. Chaque chemin compte contre
lui : le nouveau fait de chaque instance de règle, chaque fait que crée un closure module, les cibles d'une closure à
mesure qu'elles grandissent (pour que les $n^2$ faits d'un graphe dense soient refusés avant d'être faits, en mémoire
en proportion du budget), et les faits que supprime B/F.

Un **changement** — un groupe qui change les règles, ou l'ontologie ([plus bas](#les-changements-des-règles-en-arrière-plan)) —
s'applique à toute la base, donc son budget grandit avec elle : **$100\,000 + 100 \times \text{ses changements affirmés} +
4 \times \text{les faits de la base avant lui}$** (`change_budget`, le 4) : un changement peut rendre la base au plus
cinq fois plus grande, et une règle dont les conséquences croissent plus vite (chaque paire de choses, une closure
dense) est quand même refusée, nommée : `Invalid "rule NAME derived more than N facts from a change of the rules or the ontology"`.
Le même budget sur un fork, dans le writer à threads (celui d'une base ouverte sur le disque) et dans le cœur
déterministe (les étapes du writer que pilote la simulation), pour qu'un fork accepte et refuse exactement ce que fait la base (G8).

## Why

`why view thing property value` rend une **preuve** : un arbre dont les feuilles sont des faits affirmés et dont les
nœuds sont des instances de règles, les enfants de chaque nœud étant les faits de son corps (G20). Elle est calculée à
la demande, par la vérification en arrière de B/F sur la vue (rien de supprimé), en gardant l'instance qui a prouvé
chaque fait ; rien n'est rangé au moment de l'écriture. La preuve est **bien fondée** : chaque fait du corps a été
prouvé avant sa tête, donc aucun nœud ne repose sur lui-même. C'est une preuve, pas la plus courte, et c'est la même
pour une vue donnée. Une vue passée (`AsOf`, une vue gardée) donne la preuve qui tenait alors : le passé tient déjà ses
faits dérivés.

La provenance de Soufflé (Zhao, Subotić, Scholz 2020 [Zhao 2020]) range, pour chaque fait dérivé, sa règle et la hauteur
d'une preuve minimale, pour des preuves de hauteur minimale à un temps d'exécution publié de 1,31× en moyenne ; Cepheus
ne range rien, et paie quelques microsecondes à la demande ([benchmarks](benchmarks.md#règles-2026-11-08)).

## Les faits dérivés sont dans le journal

La frame d'un groupe tient ses changements affirmés, puis ses changements dérivés, chacun avec son octet de sorte (le
tableau ci-dessus, plus 2 `Derived`, 3 `Underived`). Le replay (la relecture du journal) applique les sortes et
**n'évalue jamais une règle** : la recovery, une replica, un lecteur local, le passé n'ont besoin d'aucun moteur de
raisonnement, et un changement ultérieur du code du moteur de raisonnement ne change jamais ce que le journal dit que
la base a été. Un fait dérivé coûte ses octets dans la frame : sa sorte dans la colonne des sortes (quelques bits par
changement, ou aucun dans un bloc d'une seule sorte), sa chose et sa valeur dans leurs colonnes
([formats](formats.md#un-groupe)).

Dans un run (formats 7 et 8, [formats](formats.md#run-dirsnapshotslo-20-digits-hi-20-digitsrun)), le drapeau « seulement
dérivé » est le bit le plus bas du champ de la valeur, dans les deux ordres, dans les blocs qui tiennent un fait dérivé
(l'entrée d'un thing block, un row block) ; un bloc qui n'en a pas n'y dépense aucun bit, donc une base sans règles ne
paie rien. Le format 6 le gardait dans le bit 63 de chaque mot de valeur de 8 octets. Un run qui change le drapeau d'un
fait tenu par un run d'en dessous tient un retrait (l'ancien drapeau) et une addition (le nouveau), pour que chaque
compte reste exact.

## Les règles sont des données

Une règle est une **chose du schéma**, comme une propriété : une chose dans [16, 65536) avec deux faits, `cepheus/name`
(unique parmi les noms du schéma, ceux des propriétés compris) et `cepheus/rule` (la propriété système 5), un texte sous
une forme canonique :

```text
vars 3; where [?0 16 ?1] [?1 17 ?2]; give [?0 16 ?2]
vars 3; where [?0 18 ?1] [?2 ?1 ?3]; give [?2 19 ?0]        (a variable property: ?1 in the property's place)
```

Une règle s'écrit donc dans un groupe comme n'importe quel fait, le journal garde chacune de ses versions, et un fork la
reçoit avec le reste. `define db rules` trouve chaque règle par son nom et écrit, en un seul groupe, les nouvelles
règles et celles qui ont changé ; `undefine db names` retire des règles. Un groupe qui définit une règle dérive ce que
la règle donne sur toute la base ; un groupe qui retire une règle retire ce qu'elle seule dérivait (par B/F : chaque
fait que donnait la règle est vérifié pour une autre preuve), les deux dans les limites du budget d'un changement,
dans ce groupe : un changement de règle prend effet à un seul numéro de groupe, chaque vue d'avant lui étant la
materialisation (l'ensemble des faits dérivés tenus par la base) sous les anciennes règles, chaque vue à partir de lui
sous les nouvelles (G19). Dans une base sur le disque, le changement est calculé à côté du writer et installé comme ce
groupe ([section suivante](#les-changements-des-règles-en-arrière-plan)).

## Les changements des règles en arrière-plan

Définir les 94 règles de l'ontologie univ-bench sur 10 universités en forme de LUBM dérive 532 205 faits ; calculé dans
le writer, à l'intérieur du groupe, cela arrêterait chaque autre writer pendant des secondes. Le writer à threads d'une
base sur le disque (un serveur, `open_`) calcule plutôt un **changement** à côté de lui, et l'installe comme un seul
groupe :

1. **Quels groupes.** Un groupe qui change les règles (une règle définie, changée ou retirée), ou l'**ontologie** : un
   groupe au-delà du budget d'une écriture de données qui affirme ou retire un fait d'une relation sur laquelle les
   règles sont dépliées dans l'état d'avant lui ([spécialisation](#la-spécialisation-par-petites-relations) ; trouvé à partir
   des règles et de cet état seuls, jamais de ce qu'ont fait les groupes d'avant, pour qu'un fork trouve la même
   chose). Le writer résout d'abord la partie affirmée du groupe comme toujours (les types, `Expect`, les propres
   vérifications des règles : safety, types, strata) : une erreur reçoit sa réponse tout de suite. Un changement avec
   de nouvelles choses (des numéros temporaires) est calculé dans le groupe, comme sur un fork : c'est au writer de
   donner les numéros de ses choses, dans l'ordre. Un seul changement à la fois ; le suivant l'attend.
2. **La construction.** Un domain à lui (un fil d'exécution d'OCaml qui tourne en parallèle sur un autre cœur) résout
   le groupe sur un fork de la vue du writer à cet instant, sous le budget du changement : la materialisation de cet
   état plus le changement, sous les nouvelles règles, sur ce seul domain.
3. **Le rattrapage.** Pendant ce temps, le writer valide les groupes qui continuent d'arriver, sous les anciennes
   règles, et les consigne. L'arrière-plan les applique à sa vue par lots, tout ce qu'il trouve d'un coup : leurs
   changements affirmés nets (l'état d'un fait avant le premier et après le dernier), et ce que les **nouvelles**
   règles en font ; les changements dérivés qu'ils avaient sous les anciennes règles sont abandonnés. Seul compte
   l'état à la fin d'un lot : les faits dérivés sont une fonction des faits affirmés (le least model est unique,
   [Abiteboul 1995]), et les états intermédiaires sont ordonnés avant le changement, sous les anciennes règles. Il
   garde, fait par fait, la différence entre les états du writer et le sien.
4. **Le switch** (le passage d'une vue à l'autre). Quand l'arrière-plan trouve moins de 64 groupes à appliquer, le
   writer applique lui-même le reste, résout à nouveau la partie affirmée du groupe contre sa propre vue (ses `Expect`
   sont vérifiés à ce moment), écrit un seul groupe : les changements affirmés, puis la différence comme changements
   dérivés, et fait de la vue de l'arrière-plan sa vue de travail. L'écriture revient une fois ce groupe durable, comme
   n'importe quelle écriture.

Ce qui peut mettre fin à un changement à la place, et ce qu'il répond :

| un groupe écrit pendant ce temps | le changement répond |
|---|---|
| affirme ou retire un fait que le changement affirme ou retire (ils ne commuteraient pas : leur ordre changerait le résultat) | `Conflict` |
| rend fausse l'`Expect` du changement (un autre writer a pris le numéro de la règle : `define` réessaie) | `Conflict` |
| change lui-même les règles (un changement qui fait de nouvelles choses, calculé dans son groupe) | `Conflict` |
| casse, sous les nouvelles règles, une contrainte, une propriété à une valeur ou unique, ou le budget du changement | `Conflict` |
| enlève une propriété que lisent les nouvelles règles | `Invalid` (la vérification des règles au switch) |

`Conflict` veut dire qu'un groupe ordonné avant le changement a interféré : `define` relit le schéma et réessaie, et
le nouvel essai décide sur l'état plus récent, où un problème durable donne son `Invalid` à la construction (une
contrainte que les données cassent : `Invalid "constraint NAME: …"`). Un changement au-delà de son budget est
`Invalid` à la construction. Une fermeture de la base annule un changement en cours : il reçoit `Closed`, et rien de
lui n'est dans le journal.

Dans un cluster Raft ([serveur](server.md#un-seul-log-pour-le-cluster) ; Raft est un protocole où plusieurs serveurs
tiennent un même log, la suite répliquée des frames, qu'écrit l'un d'eux, le leader), le changement tourne sur le
leader, et son groupe est proposé comme la frame de n'importe quelle écriture, seul. Si le leader cesse de l'être
pendant que le changement tourne (une frame qu'il a écrite est reprise, ou il applique la frame d'un autre leader), le
changement reçoit `not_leader` et rien de lui n'est écrit : sa vue pourrait tenir un groupe qui n'a jamais été validé
(committed : confirmé par une majorité des serveurs), ou manquer un groupe qu'a écrit le nouveau leader. Le programme
l'envoie à nouveau (le client OCaml le fait, vers le nouveau leader). Dans un cluster, un groupe fait au plus 8 MiB,
une entrée du log : un changement dont le groupe, ses faits dérivés compris, dépasse cette taille est refusé
(`invalid`, au-delà de la limite d'une frame).

**Pourquoi cela garde les garanties.** Le changement est ordonné quand il est installé : chaque groupe qu'il a
rattrapé est avant lui, et ses `Expect` sont vérifiés contre cet état (G4). Sa vue est le least model de l'état au
switch sous les nouvelles règles, parce que chaque lot la garde ainsi (G17 tient pour les groupes incrémentaux) et
que la partie affirmée du changement commute avec les groupes consignés (aucun fait en commun, vérifié). La frame de
son groupe est exactement la différence entre la vue du writer et celle-là, donc le replay (la relecture du journal)
— la recovery après un crash, une replica (une copie de la base qui suit son journal), un lecteur local — obtient
exactement la vue que le writer a adoptée. Aucune vue d'avant le groupe ne tient un fait des nouvelles règles (la vue
de l'arrière-plan n'est publiée qu'avec le groupe), chaque vue à partir de lui les tient tous (G19). Un crash avant que
le groupe soit durable ne laisse rien : le changement n'a jamais été confirmé. Le protocole est vérifié par TLC (le
model checker de TLA+, qui parcourt tous les états d'un modèle ; `spec/RuleChange.tla` : la construction, des lots de
rattrapage, le switch, des crashs, les frames d'un leader Raft reprises ; chaque vue exacte sous ses règles, un seul
switch, les contraintes, `Expect` au switch, aucune écriture perdue, les runs sur le disque exacts, et le changement
se termine ; avec aussi le run à lui des faits dérivés d'un changement, et des merges), et chacune de ses treize parties
est nécessaire : sans n'importe laquelle d'entre elles, TLC trouve un contre-exemple
([tests](testing.md#model-checking)).

**Ce que fait le writer pendant ce temps.** Il n'attend jamais la construction ni le rattrapage ; aucun merge (la
fusion de runs triés en un seul) ne démarre en arrière-plan pendant qu'un changement tourne, et un changement attend
un merge en cours, pour que les deux vues partagent leurs runs. Sa part au switch, ce sont les derniers groupes et la
frame. Si l'arrière-plan prend plus de 65 536 groupes de retard, le writer l'attend, pour que les groupes consignés et
les deltas restent bornés.

**Les faits dérivés d'un grand changement : un run à eux.** Le **delta** est la partie d'une vue gardée en mémoire
sous forme de maps (des tables de correspondance, un fait à la fois, par-dessus les runs du disque) ; un **run** est
un fichier trié de faits. Mettre 150 000 faits dérivés dans le delta un par un prenait la moitié de la construction
d'un changement. Alors, quand la construction ajoute 20 000 faits dérivés ou plus des propriétés qui prennent
plusieurs valeurs, aucune unique (aucune vérification ne relit ces faits après les tours), et dont le delta ne tient
aucune entrée pour ce fait, elle les met de côté, les trie et les écrit, par la seule façon dont un run s'écrit (un
merge, d'eux seuls), comme un run à eux : **R**, au-dessus des runs et sous le delta de la vue du changement. Le
rattrapage lit R comme n'importe quel run. La table des différences (où le rattrapage garde, fait par fait, chaque
fait dont l'état diffère entre la vue du writer et celle du changement, et d'où la frame du changement est écrite) ne
tient un fait de R qu'une fois qu'un groupe écrit pendant ce temps le touche (avant cela, ses états sont connus :
absent pour le writer, dérivé pour le changement), et l'y garde ensuite, même quand ses deux états sont d'accord,
puisqu'un fait de R absent de la table veut dire « dérivé, comme R le dit ». La frame du changement ne change pas :
ses changements affirmés, les différences de la table, puis les faits de R que la table ne tient pas, comme dérivés.
Le journal tient chaque fait dérivé, comme avant, et son format est le même.

R est **provisoire** : son état n'est celui d'aucun groupe (les faits dérivés d'un changement, sans les groupes
autour), donc il n'est jamais nommé dans la chaîne des runs, jamais forcé sur le disque (fsync), et son fichier
(`<lo>-<hi>.run.change.tmp`, niveau 0 dans son en-tête, ce qu'une ouverture refuse dans un run nommé) s'en va quand le
merge qui le prend est installé, quand le changement se termine sans être installé, ou à la fermeture. Un crash le
perd (un fichier `.tmp`, supprimé à l'ouverture), et la recovery rejoue la frame du changement. Le writer adopte R
avec la vue du changement, et chaque merge le prend (un merge prend les runs les plus récents, et R est toujours parmi
eux). À partir de 4 tels runs, un merge démarre ; à 8, un changement met ses faits dérivés dans le delta, comme le
fait un petit changement. Les replicas, les followers Raft et les lecteurs locaux ne voient jamais R : ils appliquent
la frame du changement, comme avant. TLC vérifie le protocole avec R ([tests](testing.md#model-checking)), et chacune
des cinq règles de R est nécessaire : R ne prend que les faits pour lesquels le delta n'a pas d'entrée, un fait de R
entre dans la table comme (absent, dérivé), il y reste une fois touché, R n'est jamais nommé, chaque merge le prend ;
sans n'importe laquelle, TLC trouve un contre-exemple.

**Les faits qu'aucune règle ne lit : faits par un seul tri.** La plupart des faits dérivés d'un changement ne
déclenchent souvent rien : ce sont les faits d'un **sink** (un puits : une règle dont aucun pattern d'aucune règle ne
peut correspondre à la tête ; dans l'exemple ci-dessous, `[x type Schedule]`, une classe qu'aucune règle ne lit). Le
working set (la table propre au raisonnement, des faits qu'un groupe touche, avec les index que cherchent les plans des
règles) n'en a besoin que pour savoir qu'un fait n'est pas trouvé deux fois ; une relation qu'aucun plan ne cherche n'a
besoin d'aucun index (le choix des index d'après les recherches des plans, [Subotic 2018]), seulement que ses doublons
soient retirés, ce que fait un seul tri. Alors un changement garde les têtes d'un sink dans un buffer à mesure que ses
instances les trouvent (hors du tas du garbage collector : une chose, une propriété, une valeur et la règle chacune), et
à la fin de son raisonnement les trie une fois par (chose, propriété, valeur) : elles arrivent en quelques suites
croissantes (les faits d'un atome lus dans les runs de la vue l'un après l'autre), fusionnées deux à deux comme le fait
un natural merge sort (un tri par fusion qui part des suites déjà triées), et au-delà de 64 suites un radix sort,
chiffre le moins significatif d'abord, par chose, des chiffres de 11 bits, puis par propriété et valeur dans chaque
chose [Knuth 1998] ; les deux sont stables. Il garde le premier de chaque fait (stable : sa première instance nomme sa
règle), met de côté ceux que la vue ou le working set tiennent, et compte les autres dans le budget, comme chaque fait
dérivé ; ils vont dans la sortie du changement dans cet ordre, donc son run à lui s'écrit sans autre tri. Prise une par
une dans le working set, chaque tête coûtait une recherche, sa place, trois index et sa part de la croissance des tables
: environ 0,8 µs par tête à côté de 256 writers, six fois le coût de la trouver. Au-delà de la moitié de la place que
laisse le budget (65 536 têtes au moins), les têtes sont dédoublonnées avant la fin, et un changement dont les faits
gardés dépassent son budget y est refusé, en nommant la règle qui en a dérivé le plus, comme avant. Seulement dans un
changement (un groupe qui change les règles ou l'ontologie), seulement pour des règles dont la propriété prend plusieurs
valeurs, aucune unique, pas une propriété du système, et pas avec l'égalité (une règle qui rend des choses identiques
lit chaque fait), et sur un seul domain : un tour sur plusieurs domains (plus bas) fait de ses têtes des faits par
régions du working set, celles d'un sink aussi, en parallèle.

**Ce que cela coûte** ([benchmarks](benchmarks.md#règles-les-cibles-de-létape-5-encore--les-faits-quaucune-règle-ne-lit-faits-par-un-seul-tri-2026-11-18)).
Sur 10 universités en forme de LUBM avec les 94 règles, pendant que 256 clients écrivent de façon durable, ajouter un
axiome (chaque personne est aussi d'une classe que les données laissent vide : environ 135 000 faits dérivés, tous
d'un sink) s'installe en 0,31 s (médiane de 21 ; sa construction 0,053 s, son run à lui 0,025 s : 2,6 M de faits
dérivés par seconde pour la construction, 1,7 M avec l'écriture du run), et la part du writer lui-même à l'installation
est de 36 ms. Le débit des clients pendant qu'il tourne est 0,50 de ce qu'il est sans le changement, 0,93 sur toute la
mesure depuis son début : la fenêtre est courte maintenant (0,2 à 0,3 s) et contient l'installation, la part du writer
et la frame du changement écrite et forcée, 40 à 60 ms sans aucun groupe confirmé ; un seul arrêt dans une fenêtre de
moins d'une seconde déplace beaucoup le rapport d'une paire. L'arrière-plan partage avec le writer
les quatre cœurs de la machine, ses caches et le garbage collector, et le delta grandit pendant ce temps, puisqu'aucun
merge ne tourne à côté d'un changement. Définir les 94 règles sur les mêmes données sans règles est le pire cas : chaque
groupe écrit pendant ce temps coûte aux nouvelles règles plusieurs fois ce qu'il coûte aux anciennes, l'arrière-plan ne
peut pas suivre à pleine charge (environ 110 µs par groupe contre 10 à 25 pour le writer), et le writer l'attend à 65
536 groupes de retard (des secondes).

**Des tours sur plusieurs domains.** Dans un groupe que le writer raisonne lui-même (un chargement, un changement sur
un fork ou dans le cœur déterministe), un tour de 20 000 faits ou plus, et le premier tour des règles qu'ajoute un
changement, est découpé en morsels (des petits morceaux de travail, Leis et al. [Leis 2014]) pris à tour de rôle par
jusqu'à quatre domains, chacun dérivant avec ses propres plans et gardant les têtes qui ne sont pas encore des faits ;
puis un seul domain en fait des faits, morsel après morsel, dans l'ordre, comme il les aurait trouvées seul : le
résultat, le budget et les refus ne dépendent pas des domains. Les règles avec `Not` ou des agrégats, et les règles
dont un groupe ajouterait les constantes texte au dictionnaire (intern), tournent sur un seul domain. Quand les règles
ajoutées sont moins nombreuses que les threads, les instances de chaque règle sont découpées par blocs des premiers
éléments de son plan, un bloc par morsel. Un changement en arrière-plan ne dérive que sur son propre domain : mesuré sur
plusieurs domains à cet endroit, le débit des clients pendant le changement baissait (de 0,84 à 0,78 à l'étape 5 ;
avec les instances d'une règle en morsels, de 0,83 à 0,50), et la construction n'allait pas plus vite
([benchmarks](benchmarks.md#règles-les-cibles-de-létape-5--les-faits-dérivés-dun-changement-dans-un-run-à-eux-2026-11-18)). Mesuré sur un chargement de 10 universités avec
les 94 règles : les tours à 1,44 M de faits dérivés/s sur quatre domains, 0,90 sur un seul.

Les règles sont compilées à la première écriture qui en a besoin, jamais à l'ouverture : une ouverture rejoue des
frames, qui tiennent déjà les faits dérivés, donc le démarrage ne grandit pas.

## Grands groupes

Un groupe de 20 000 additions et plus (un chargement) prend le chemin des grands groupes
([architecture](architecture.md#grands-groupes)) : ses faits sont placés dans des tableaux compacts, triés dans les deux
ordres d'un run, et fusionnés d'un coup dans un run. Avec des règles, ses faits sont le tour 0 de la même semi-naive
evaluation, tenus comme les tient le chemin trié de la conception (d'après les colonnes triées de VLog, un moteur
Datalog [Urbani 2016]) plutôt que hachés un à un :

- **Un préfixe trié, pas des chaînes de hachage.** Les faits du groupe des propriétés qu'une règle lit ou donne (aucune
  règle ne peut correspondre aux autres) sont les premiers faits du working set (l'ensemble de travail du
  raisonnement), dans l'ordre par chose : les faits d'une chose en sont un intervalle (un offset, une position, par
  nouvelle chose), les choses d'une (propriété, valeur) un intervalle de l'ordre du groupe par propriété, dont son run
  a besoin de toute façon. Seule la table d'appartenance (la membership table, qui dit si un fait est déjà là) les
  tient chacun, remplie par plusieurs domains, chacun possédant une région de la table.
- **Seulement les chaînes que lit un plan.** Un fait dérivé rejoint la chaîne par (propriété, chose) seulement si un
  plan lit sa propriété avec la chose connue et la valeur non, et la chaîne par (propriété, valeur) seulement dans le
  cas inverse, comme le dit l'ordre compilé des plans (une index selection, le choix des index à tenir, à la manière de
  [Subotic 2018]). Les types dérivés d'un chargement, lus seulement avec les deux côtés connus, n'en rejoignent aucune.
- **Des tours sur plusieurs domains.** Un tour de 20 000 faits ou plus est dérivé par morsels ; ses têtes deviennent
  des faits par régions de la table d'appartenance, un domain par région, avec les numéros, les règles et l'ordre que
  donne la boucle sur un seul domain : le résultat ne dépend pas du nombre de domains.
- **Les faits dérivés fusionnés dans les ordres du groupe**, triés seuls, pas triés à nouveau avec ceux du groupe.
- **Les faits d'une nouvelle chose ne sont pas cherchés dans la vue** (elle n'en a aucun) ; un fait déjà dérivé que le
  groupe affirme change son drapeau dans le delta (la sorte 4 dans la frame, avant les faits du groupe) au lieu
  d'envoyer le groupe au chemin ordinaire, pour qu'un chargement par morceaux (une université par groupe) reste sur ce
  chemin.
- **Les contraintes et les têtes à une valeur sont vérifiées après le point fixe** : les plans des contraintes (avec
  leurs Not) tournent à partir de chaque fait que le groupe a rendu présent, et chaque fait dérivé d'une propriété à
  une valeur ou unique est compté avec ceux du groupe et de la vue. Un groupe qui en casse une va au chemin ordinaire,
  qui le refuse avec son message.

Un groupe dont les règles dérivent avec un `Not` ou un agrégat prend le chemin ordinaire. Le texte d'une règle que le
groupe ajoute lui-même se trouve parmi les nouveaux textes du groupe, que la map du dictionnaire ne tient pas encore.

## OWL 2 RL, une bibliothèque de règles

**OWL 2** est le langage d'*ontologies* du W3C (l'organisme qui normalise le web) : des classes (« un professeur est
une personne »), des propriétés et ce qu'elles veulent dire (« un directeur de thèse est un professeur », « un e-mail
identifie une seule personne »). **OWL 2 RL** est la partie de ce langage que des règles peuvent calculer
entièrement : le W3C la donne sous forme de 78 règles, en six tableaux (OWL 2 Profiles, section 4.3 [W3C 2012]).
Cepheus n'a pas d'interrupteur pour elle : `Cepheus.Owl` est une bibliothèque de règles sur un vocabulaire de
propriétés à elle, et une base obtient OWL 2 RL en définissant ces règles, comme elle définit n'importe quelles règles.
L'ontologie est alors des données : des faits écrits dans des groupes, versionnés dans le journal, et les règles sont
dépliées sur eux ([spécialisation](#la-spécialisation-par-petites-relations)).

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

Depuis Cesia, la même chose par un serveur ([Cepheus depuis Cesia](cesia.md#owl-2-rl)) : le vocabulaire est le kind
`owl.Vocabulary`, donné à `Connect`, et `owl.Rl()` les règles comme données, que `cepheus.Define` prend de cette
bibliothèque (le travail de `Owl.setup` compris) ; une propriété d'un kind, là où va un lien, est son numéro
(`[d, owl.Property, Person.Advisor]`) :

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

Les mêmes choses, les mêmes numéros : la bibliothèque du moteur, définie depuis l'un ou l'autre langage. `why` n'est
pour l'instant qu'en OCaml.

- Le nom écrit sur le second enregistrement est lu sur le premier, 65542, le représentant de la classe : les lectures
  nomment une chose par son représentant, et `why` du type du second enregistrement prouve celui du représentant. Il
  donne une preuve, pas la plus courte : Person par prp-rng, sur le range (la classe des valeurs d'une propriété) qu'a
  dérivé scm-rng1 (le range de advisor est Professor, et un Professor est une Person).
- Les règles sont celles du W3C, écrites sous sa forme : des règles génériques sur les faits de l'ontologie, avec la
  propriété en variable ([plus haut](#une-propriété-comme-variable--la-forme-des-règles-dowl-du-w3c)). Le writer les exécute
  dépliées sur l'ontologie, une règle par axiome (« un directeur de thèse est un professeur » devient
  `[x advisor y] -> [y type Professor]`) ; une écriture de l'ontologie est un changement des règles, calculé comme tel
  ([en arrière-plan](#les-changements-des-règles-en-arrière-plan) sur une base sur le disque).
- Les deux enregistrements ont été rendus **une seule chose** par `owl/prp-ifp` (une propriété inverse fonctionnelle :
  une valeur, une chose) : leurs faits sont gardés sur l'un d'eux, le **représentant**, et `same` liste la classe ; les
  lectures nomment une chose par le représentant de sa classe ([l'égalité](#légalité--des-classes-de-choses-égales) plus
  bas).
- Retirer l'e-mail qui les rendait une seule chose les sépare à nouveau : la classe est défaite et dérivée à nouveau.

### Le vocabulaire

Une chose de propriété ne garde que des faits `cepheus/` ([une propriété comme variable](#une-propriété-comme-variable--la-forme-des-règles-dowl-du-w3c)),
et Cepheus n'a pas de listes RDF (RDF : le modèle de données du web sémantique, en triplets) ; le vocabulaire diffère
donc de la forme RDF d'OWL de quatre façons, chacune la plus petite qui garde les règles du W3C telles qu'elles sont :

- Un axiome sur une propriété est un fait de sa **description**, une chose à elle : `[d, owl/Property, advisor]` nomme
  la propriété, et les autres faits de d sont ses axiomes : `[d, owl/Range, Professor]`, `[d, owl/Transitive, true]`.
  Une description par propriété : les règles du schéma lui donnent des axiomes dérivés (scm-dom2 : la description d'une
  sous-propriété reçoit le domaine de celle de sa super-propriété).
- Une **liste** (les classes d'une intersection, celles d'une union, les propriétés d'une clé, les choses d'une
  énumération) est les valeurs d'une propriété qui en prend plusieurs : `[Student, owl/IntersectionOf, Person]`,
  `[Student, owl/IntersectionOf, r]`. Les règles qui ont besoin de chaque membre à la fois (cls-int1, prp-key) sont des
  **templates** (des modèles de règles, dépliés sur la liste ; [plus bas](#templates--des-règles-sur-des-listes)).
- Une **chaîne de propriétés** (p1 puis p2 donne p, prp-spo2) est une chose avec deux liens : `[ch, owl/ChainOf, p]`,
  `[ch, owl/First, p1]`, `[ch, owl/Second, p2]` ; une chaîne de trois ou plus s'écrit comme des chaînes de deux, par
  une propriété propre au programme pour chaque étape du milieu (p1, p2, p3 donne p : p1, p2 donne q ; q, p3 donne p).
- AllDifferent, AllDisjointClasses et AllDisjointProperties s'écrivent comme leurs paires (`Owl.all_different`,
  `Owl.disjoint_classes`, `Owl.disjoint_properties` les font) : ce que veulent dire, deux à deux, les formes n-aires
  du W3C.

| propriété | sur | valeur | OWL |
|---|---|---|---|
| `owl/Type` | une chose | une classe | rdf:type |
| `owl/SameAs`, `owl/DifferentFrom` | une chose | une chose | owl:sameAs, owl:differentFrom |
| `owl/SubClassOf`, `owl/EquivalentClass`, `owl/DisjointWith`, `owl/ComplementOf` | une classe | une classe | rdfs:subClassOf, owl:equivalentClass, owl:disjointWith, owl:complementOf |
| `owl/IntersectionOf`, `owl/UnionOf` | une classe | chaque classe membre | owl:intersectionOf, owl:unionOf (une liste) |
| `owl/OneOf` | une classe | chaque chose membre | owl:oneOf |
| `owl/HasKey` | une classe | chaque propriété de la clé | owl:hasKey |
| `owl/OnProperty` | une restriction | une propriété | owl:onProperty |
| `owl/SomeValuesFrom`, `owl/AllValuesFrom`, `owl/OnClass` | une restriction | une classe | owl:someValuesFrom, owl:allValuesFrom, owl:onClass |
| `owl/HasValue` | une restriction | une chose | owl:hasValue (une chose ; une valeur texte ou nombre est une règle du programme) |
| `owl/MaxCardinality`, `owl/MaxQualifiedCardinality` | une restriction | un int, 0 ou 1 | owl:maxCardinality, owl:maxQualifiedCardinality |
| `owl/Property` | une description | la propriété | le sujet des axiomes de la propriété |
| `owl/Domain`, `owl/Range` | une description | une classe | rdfs:domain, rdfs:range |
| `owl/SubPropertyOf`, `owl/EquivalentProperty`, `owl/InverseOf`, `owl/PropertyDisjointWith` | une description | une propriété | rdfs:subPropertyOf, owl:equivalentProperty, owl:inverseOf, owl:propertyDisjointWith |
| `owl/Functional`, `owl/InverseFunctional`, `owl/Transitive`, `owl/Symmetric`, `owl/Asymmetric`, `owl/Irreflexive` | une description | `true` | les caractéristiques de la propriété |
| `owl/ChainOf`, `owl/First`, `owl/Second` | une chaîne | une propriété | owl:propertyChainAxiom (deux liens) |
| `owl/SourceIndividual`, `owl/AssertionProperty`, `owl/TargetIndividual`, `owl/TargetValue` | une assertion négative | une chose, une propriété, une chose, un texte | owl:NegativePropertyAssertion |
| `owl/Builtin` | owl:Thing, owl:Nothing | "Thing", "Nothing" | les deux classes qu'a toute ontologie |

`Owl.setup db` déclare ces propriétés et fait les choses owl:Thing et owl:Nothing, une seule fois (une base qui les a
les garde) ; `Owl.rl` donne les règles, nommées `owl/` et le nom du W3C (`owl/cax-sco` ; une règle du W3C à deux têtes
est deux règles, la seconde nommée avec un `b` : `owl/scm-eqc1b`).

### Chacune des 78 règles

| tableau du W3C | règles | dans Cepheus |
|---|---|---|
| 4, égalité (9) | eq-ref, eq-sym, eq-trans, eq-rep-s, eq-rep-p, eq-rep-o | les classes de choses égales et leur réécriture ([plus bas](#légalité--des-classes-de-choses-égales)) ; `owl/eq` fait de `owl/SameAs` une égalité ; eq-rep-p : une propriété n'est identique à aucune autre (une règle qui la rendrait telle refuse son groupe) |
| | eq-diff1, eq-diff2, eq-diff3 | la contrainte `owl/eq-diff1` (`[x, owl/DifferentFrom, x]`, ce que devient une différence réécrite entre deux choses égales) ; AllDifferent comme ses paires |
| 5, propriétés (20) | prp-dom, prp-rng, prp-symp, prp-trp, prp-spo1, prp-eqp1, prp-eqp2, prp-inv1, prp-inv2 | des règles (la closure d'une propriété transitive par le closure module) |
| | prp-spo2 | une règle sur des chaînes de deux liens |
| | prp-fp, prp-ifp, prp-key | des règles qui rendent des choses identiques ; prp-key un template sur les propriétés de la clé |
| | prp-irp, prp-asyp, prp-pdw, prp-npa1, prp-npa2 | des contraintes ; prp-adp : AllDisjointProperties comme des paires de prp-pdw |
| | prp-ap | rien à faire : une annotation property est une propriété comme une autre |
| 6, classes (19) | cls-int2, cls-uni, cls-svf1, cls-svf2, cls-avf, cls-hv1, cls-hv2, cls-oo | des règles |
| | cls-int1 | un template sur les membres de l'intersection |
| | cls-maxc2, cls-maxqc3, cls-maxqc4 | des règles qui rendent des choses identiques |
| | cls-nothing2, cls-com, cls-maxc1, cls-maxqc1, cls-maxqc2 | des contraintes |
| | cls-thing, cls-nothing1 | les deux choses que fait `Owl.setup` |
| 7, axiomes de classes (5) | cax-sco, cax-eqc1, cax-eqc2 | des règles |
| | cax-dw | une contrainte ; cax-adc : AllDisjointClasses comme des paires de cax-dw |
| 8, types de données (5) | dt-type1, dt-type2, dt-eq, dt-diff, dt-not-type | tenues par les valeurs typées : une valeur a un type et un mot ([concepts](concepts.md)), une valeur mal typée n'entre jamais, des valeurs égales sont un seul fait |
| 9, schéma (20) | scm-sco, scm-eqc1, scm-eqc2, scm-spo, scm-eqp1, scm-eqp2, scm-dom1, scm-dom2, scm-rng1, scm-rng2, scm-hv, scm-svf1, scm-svf2, scm-avf1, scm-avf2, scm-int, scm-uni | des règles sur les faits de l'ontologie (scm-sco par le closure module) ; scm-hv, scm-svf1 et scm-avf1 ont une seconde règle pour le cas que donnerait un fait réflexif |
| | scm-cls, scm-op, scm-dp | tenues sans faits : une classe est sa propre sous-classe et celle d'owl:Thing, une propriété sa propre sous-propriété ; rien de réflexif n'est rangé, et `x owl/Type owl:Thing` n'est pas rangé pour chaque chose (Cepheus ne déclare pas de classes) |

Chaque règle a un test qui vérifie qu'elle se déclenche, ou que sa contrainte refuse, sur cinq chemins (un fork groupe
par groupe, les règles telles qu'écrites, l'ontologie après les données, un chargement sur le disque, un changement en
arrière-plan), chaque vue comparée au sens des règles calculé de zéro ([tests](testing.md)).

### Templates : des règles sur des listes

`cls-int1` dit : quand y a le type de chaque membre de l'intersection de C, y est un C. Son corps a autant de patterns
que l'intersection a de membres : le W3C l'écrit sur une liste, `LIST[?x, ?c1, …, ?cn]`. Dans Cepheus, un pattern
`[c, every L, m]` (en OCaml `Cepheus.every L` ; dans le texte canonique `[?0 *40 ?1]`) se lit « pour chaque valeur m
du L de c » : les patterns qui nomment m sont écrits une fois pour chaque membre, et les variables qu'eux seuls tiennent
sont nouvelles dans chaque copie.

```text
cls-int1:  [c, every owl/IntersectionOf, m] [y, owl/Type, m] -> [y, owl/Type, c]
over [Student, owl/IntersectionOf, Person] [Student, owl/IntersectionOf, r]:
           [y, owl/Type, Person] [y, owl/Type, r] -> [y, owl/Type, Student]
prp-key:   [c, every owl/HasKey, p] [x, owl/Type, c] [y, owl/Type, c] [x, ?p, z] [y, ?p, z] -> [x, cepheus/same, y]
over a key {email, birth}:
           [x type C] [y type C] [x email z1] [y email z1] [x birth z2] [y birth z2] -> [x cepheus/same y]
```

Le writer déplie un template sur les faits de la liste dans les règles telles qu'écrites (une liste sans membre ne
donne aucune règle), et les règles dépliées tournent comme n'importe quelle règle. Les règles d'un template changent
quand sa liste change, donc **une écriture d'une liste est un changement des règles** : les règles enlevées (l'ancien
dépliage) perdent leurs conséquences par B/F, les règles ajoutées dérivent les leurs, dans le groupe, sous le budget
d'un changement, et en arrière-plan sur une base sur le disque. Aucune règle ne peut donner la propriété d'une liste
(refusé quand les règles sont définies, et un fait d'elle dérivé refuse le groupe) : une liste ne change que par des
écritures. Un pattern template par règle, au plus 64 membres par liste, aucun `Not` ni agrégat à côté.

### L'égalité : des classes de choses égales

Une règle dont la tête donne `cepheus/same` (la propriété système 6) fait de ses deux choses **la même chose** : le
owl:sameAs d'OWL, que les règles du W3C axiomatisent (eq-ref, eq-sym, eq-trans : une équivalence ; eq-rep-s, eq-rep-p,
eq-rep-o : un fait de l'une est un fait de l'autre). Écrites comme des règles, n choses égales tiennent n² faits
sameAs, dérivés 2n³ + n² + n fois, et chaque fait de chacune est copié sur les n (Motik, Nenov, Piro, Horrocks
[Motik 2015b], section 3). Cepheus les garde plutôt par **réécriture**, comme RDFox [Motik 2015b] :

- **Les classes.** Les choses rendues égales forment une classe, tenue dans un union-find (une structure qui range des
  éléments en classes et fusionne deux classes vite ; Tarjan [Tarjan 1975]), fusionnée de la plus petite dans la plus
  grande : un membre est le **représentant** de la classe, et chaque autre membre x tient un fait dérivé
  `[x, cepheus/same, r]`, écrit dans le journal comme n'importe quel fait dérivé (les replicas, le replay et le passé
  n'ont besoin de rien de plus). Une chose change de classe O(log n) fois sur n'importe quelle suite de fusions.
- **La réécriture.** Les faits d'une classe sont gardés sur son représentant : une fusion déplace les faits seulement
  dérivés du représentant du plus petit côté vers celui du plus grand, et un fait qu'un programme a affirmé reste là
  où il a été écrit, sa réécriture à côté. Les règles ne lisent que les faits des représentants ; leurs têtes nomment
  des représentants. Ainsi une classe de n choses coûte n − 1 faits de `cepheus/same`, et chaque fait est dérivé une
  fois pour la classe, pas une fois par membre.
- **Un fait à la fois.** Les égalités que donne un fait sont appliquées avant que le fait suivant du tour ne tourne,
  comme le fait l'évaluation fait par fait (fact-at-a-time) de RDFox : les faits qu'elles rendent périmés ne lancent
  rien. Une propriété fonctionnelle avec n valeurs sur une chose coûte O(n) instances de règle, pas les n² paires
  qu'énumérerait un tour (mesuré : 3 000 choses rendues une seule en 0,05 s ; 3,95 s avant).
- **Les lectures.** Une question, `get`, `values` et `things` lisent une chose qu'elles nomment comme le représentant
  de sa classe (une recherche) ; `same v x` liste la classe. Une réponse lie le représentant pour les faits dérivés ;
  un fait qu'un programme a affirmé sur un autre membre est aussi là, tel qu'écrit.
- **Le retrait.** Un retrait qui peut défaire une égalité défait la classe et la dérive à nouveau (Delete-Rederive pour
  la classe, [Gupta 1993]) : quand une instance de règle qui donnait une égalité perd un fait, quand B/F rencontre un
  fait seulement dérivé qui nomme une classe de plusieurs choses, ou quand une écriture retire un fait d'un membre,
  chaque membre redevient son propre représentant, chaque fait seulement dérivé qui nomme le représentant est supprimé
  (ses conséquences vérifiées par B/F), et les faits affirmés des membres sont dérivés à nouveau de zéro, égalités
  comprises. C'est exact ; B/F sur les égalités (Motik, Nenov, Piro, Horrocks, IJCAI 2015) redériverait moins, et est
  laissé pour plus tard.
- **Les limites.** Deux valeurs différentes ne sont jamais la même chose : une règle qui les rendrait telles refuse le
  groupe (prp-fp sur une propriété à deux valeurs). Une propriété n'est identique à aucune autre. Une chose que les
  règles nomment comme constante (owl:Thing, une classe que nomme une règle dépliée) garde sa propre identité : une
  fusion d'elle refuse le groupe. Un ensemble de règles qui rend des choses identiques ne prend pas encore de `Not` ni
  d'agrégat. Avec l'égalité, les closure modules, le chemin des chargements et les tours parallèles sont désactivés ;
  les règles d'égalité sur une relation sans aucun fait sont laissées hors du programme déplié, donc une base dont
  l'ontologie ne rend rien identique les garde.
- **Why.** Un fait d'un représentant qui réécrit le fait affirmé d'un membre est prouvé par un nœud `cepheus/same` dont
  les enfants sont ce fait et les faits des classes ; la preuve d'une égalité elle-même n'est pas encore donnée (G20).

## Ce que cela coûte, et face aux géants

Mesuré sur ce portable (Intel i7-4720HQ, 2,6 GHz, 4 cœurs ; OCaml 5.5 sans flambda), sur des données en forme de LUBM
(des universités, des départements, des personnes, des cours, générés d'après les intervalles publiés du générateur
LUBM [Guo 2005], pas sa sortie officielle) avec l'ontologie univ-bench sous forme de 94 règles, une par axiome. Sept
tours, alternés, chaque processus limité à 3 GB ; la médiane et l'intervalle $[x(1), x(7)]$ des tours (couverture de
98,4 %). La méthode et chaque chiffre : [benchmarks](benchmarks.md#règles-2026-11-08), et pour les chargements
[le chemin des chargements](benchmarks.md#règles-étape-3--le-chemin-des-chargements-trié-et-parallèle-2026-11-14).

| quoi | avec les règles | sans | |
|---|---|---|---|
| écrire un étudiant de troisième cycle (10 faits ; 6 dérivés) | **23,1 µs** [21,9 ; 24,1] | 9,1 µs | 2,5× |
| le retirer (B/F : les 6 faits dérivés partent) | **34,1 µs** [33,1 ; 54,8] | 6,9 µs | 4,9× |
| `why` d'un type dérivé (une preuve de 2 à 8 faits) | **1,2 à 3,1 µs** | | |
| charger 10 universités en un seul groupe (1,35 M de faits, 532 205 dérivés, 2 021 310 dérivations), durable | **1,78 s** [1,66 ; 2,27] | 1,06 s | |
| son raisonnement : les tours seuls (la saturation), sur 8 threads | **1,92 M de faits dérivés/s** [1,58 ; 2,04] | | |
| son raisonnement entier (les faits du groupe préparés pour les joins, 0,13 s, compris) | **1,29 M de faits dérivés/s** (0,41 s) | | |
| le même chargement en dix groupes, une université par groupe : mémoire résidente au pic | **133 MB** | | |
| un fait dérivé mis dans la vue (un delta de 200 000 changements) | **0,83 µs** en lots triés ; 1,12 µs un par un | | |
| OWL 2 RL entier (`Cepheus.Owl`) contre les dix règles du W3C de l'étape 2, LUBM-10 en un seul chargement : raisonnement | **0,512 s** contre 0,543 s | | 0,92 |
| le même, LUBM-1 un groupe par département : raisonnement | **0,277 s** contre 0,247 s | | 1,15 |
| l'égalité par réécriture contre axiomatisée, en forme d'UOBM (un benchmark d'universités plus riche en OWL que LUBM ; une université, 6 558 enregistrements en double) | **1,066 s** contre 1,957 s | | 1,84× plus rapide, 3,27× moins de dérivations |
| une classe de 100 000 choses (la tempête d'une propriété fonctionnelle) | **1,42 s**, 99 999 faits de `cepheus/same` | | axiomatisée : au-delà du budget dès 400 choses |

Les chiffres d'OWL 2 RL et de l'égalité : [benchmarks](benchmarks.md#règles-étape-6--owl-2-rl-et-légalité-par-réécriture-2026-11-14).
Le chemin des écritures sans règles est inchangé : les mêmes groupes d'étudiants sur le binaire de main et sur
celui-ci, 9,06 µs et 9,06 µs pour écrire, 7,15 et 6,20 µs pour retirer ; le démarrage, 2 % de plus pour le code du
moteur de raisonnement ([benchmarks](benchmarks.md#règles-2026-11-08)).

À côté des chiffres publiés des systèmes qui matérialisent du Datalog (leurs machines et leurs données, pas les nôtres ;
les chiffres marqués *calculé* sont les nôtres, tirés de leurs tableaux) :

| système, source | test | publié |
|---|---|---|
| RDFox, Motik et al., AAAI 2014 [Motik 2014] | LUBM-L 1K, 133,6 M → 182,4 M de faits | 73 s sur un thread : **0,67 M de dérivés/s** (calculé) ; 7,0 M/s sur 32 threads ; 2 × Xeon E5-2650 (2,0 GHz) |
| VLog, Urbani et al., AAAI 2016 [Urbani 2016] | LUBM-L 1K | 38 s sur un thread : environ **1,28 M de dérivés/s** (calculé) ; un portable à 2,2 GHz |
| RDFox B/F, Motik et al., AAAI 2015 [Motik 2015] | LUBM-1k-L, suppression de 100 faits | « 0.0 s » dans son tableau (sous son arrondi) |
| Soufflé, Scholz et al., CC 2016 [Scholz 2016] | une analyse points-to d'OpenJDK 7, environ 840 M de tuples | 75 s en séquentiel, 35 s en parallèle (4 cœurs) : une autre charge, donnée pour l'ordre de grandeur |

- **Un cœur, la saturation** : 1,04 M de faits dérivés/s ici (étape 1), 0,67 M/s pour RDFox 2014, environ 1,28 M/s pour
  VLog : le même ordre de grandeur ; le débit publié de VLog reste devant de 1,2×, sur une autre machine et avec cent
  fois plus de données.
- **En parallèle, les faits d'un chargement triés** (étape 3) : les tours à 1,92 M/s sur les 4 cœurs de ce portable
  (8 threads), le raisonnement entier de 1,3 à 1,6 M/s, 0,33 à 0,40 M/s par cœur : proche des 0,44 M/s par cœur de
  RDFox 2014 à 32 threads ; RDFox atteint 7,0 M/s en tout sur ses 16 cœurs.
- **Petites écritures** : des microsecondes, dans le processus. Aucun géant ne publie de latence par groupe à comparer.
- **Là où le moteur de raisonnement coûte le plus** : un retrait, 4,9 fois le même groupe sans règles. B/F vérifie
  chaque fait qui a perdu une dérivation contre chaque règle qui peut le donner, chaque vérification étant une recherche
  dans les persistent maps ou les runs du store (34 recherches pour un étudiant) ; le prototype de la conception, sur
  des hash tables à lui, prenait 19,1 µs.

**Les closures et la forme du W3C** (l'étape 2 de la conception ; [benchmarks](benchmarks.md#règles-étape-2--les-closures-et-la-forme-du-w3c-2026-11-12)) :
le closure module calcule les 683 496 nouveaux faits de la hiérarchie de 100 000 nœuds en **22,5 ms** (prp-trp comme
règle : 0,92 s de raisonnement) et les 1 344 791 du DAG aléatoire (un graphe orienté sans cycle) en **47,3 ms**
(17,6 s), chaque nouveau fait créé une seule fois ; les données en forme de LUBM avec l'ontologie en faits et les 10
règles du W3C, dépliées, raisonnent en **1,10×** le temps des 94 règles écrites une par axiome pour un chargement et
1,05× groupe par groupe, pour les mêmes faits dérivés des données (le prototype de la conception, qui exécutait les
règles du W3C telles qu'écrites : 2,2×).

## Les choix derrière cette conception

Chacun a été pesé contre les autres dans la conception ; les mesures sont celles du prototype de la conception, sauf
mention contraire.

- **Matérialiser à l'écriture, pas raisonner à la question.** Les questions lisent les faits dérivés à la vitesse de
  n'importe quel fait ; le prix est la mémoire des faits dérivés (+40 % sur des données en forme de LUBM) et le
  raisonnement des écritures. Les systèmes qui raisonnent à la question (Stardog par réécriture des requêtes, TypeDB 3
  par des fonctions évaluées à la demande, les règles de Datomic comme entrées des requêtes) paient à la place les
  dérivations à chaque question.
- **Backward/Forward, pas le counting ni DRed** (ci-dessus) : le counting est faux sur les règles récursives ; DRed
  explore les conséquences, B/F le support (un étudiant : 19,1 µs contre 216 µs).
- **Les faits dérivés dans le journal, pas recalculés** : le replay, les replicas et le passé n'ont besoin d'aucun
  moteur de raisonnement, et un changement du code du moteur ne change jamais le passé ; la frame porte les faits
  dérivés (+40 % d'octets sur LUBM).
- **`why` calculé à la demande, pas rangé** : rien de payé au moment de l'écriture ; une preuve, pas la plus courte.
- **Un fait dérivé ne peut pas être retiré** : pas d'opération sans effet silencieuse ; le message nomme la règle et les
  faits à retirer.
- **Le drapeau dans le champ de la valeur** (le bit 63 du mot de valeur au format 6, le bit le plus bas du champ dans
  les blocs des formats 7 et 8 qui tiennent un fait dérivé) : pas un octet de plus sans règles ; un run d'un format plus
  récent n'est pas lu par un binaire plus ancien, qui rejoue le journal à la place.
- **Les closures par un module, pas par leurs règles** : chaque fait d'une closure trouvé une fois au lieu d'une fois
  par chemin (Hu et al. [Hu 2019]) ; les deux formes reconnues sont les seules façons dont le moteur clôt une
  propriété, toute autre façon d'écrire une closure tourne comme des règles.
- **Des règles génériques dépliées par le moteur, pas écrites une par axiome à la main** : une seule façon d'écrire les
  règles (l'ontologie est des données), à la vitesse des règles dépliées ; une écriture de l'ontologie exécute les
  règles telles qu'écrites pour ce groupe.
- **Le budget proportionné au groupe** ($100\,000 + 100 \times \text{ses changements affirmés}$) : un chargement dérive en proportion, une règle qui
  s'emballe est arrêtée et nommée.

## Ce qui n'est pas encore là

Le plan de la conception a six étapes ; cette version a les six.

- **Le reste de l'étape 3** : les joins des tours d'un changement en arrière-plan interrogent le store fait par fait,
  sur le seul domain du changement.
- **Le reste de l'étape 5** : un changement avec de nouvelles choses est calculé dans le groupe ; seuls les faits
  dérivés des propriétés à plusieurs valeurs, aucune unique, vont dans le run à eux d'un changement (les autres entrent
  dans le delta) ; les deux cibles de l'étape 5 ne sont pas atteintes toutes les deux : 2 M de faits dérivés par seconde
  pour la construction, pas avec l'écriture de son run ; le débit des writers pendant un changement, dont la fenêtre
  contient surtout la frame de l'installation maintenant
  ([benchmarks](benchmarks.md#règles-les-cibles-de-létape-5-encore--les-faits-quaucune-règle-ne-lit-faits-par-un-seul-tri-2026-11-18)).
- **Le reste de l'étape 6** : B/F sur les égalités (Motik et al., IJCAI 2015 [Motik 2015c]) au lieu de défaire une
  classe ; la preuve d'une égalité dans `why` ; l'égalité à côté de `Not` et des agrégats, des closure modules, du
  chemin des chargements et des tours parallèles.
- Le budget comme réglage de la base plutôt que comme nombre du processus ; le groupe qui a affirmé chaque feuille d'une
  preuve.

## Références

Chaque travail cité ici est dans les
[références](references.md#les-règles--datalog-la-matérialisation-et-sa-maintenance), avec ce que Cepheus en a pris :
[Abiteboul 1995], [Bancilhon 1986], [Ramakrishnan 1990], [Feeley 1987], [Gupta 1993], [Motik 2015], [Motik 2019],
[Apt 1988], [Przymusinski 1988], [Mumick 1990], [Motik 2014], [Urbani 2016], [Scholz 2016], [Subotic 2018], [Zhao 2020],
[Guo 2005], [Hu 2019], [Hu 2022], [Tarjan 1972], [Nuutila 1995], [Jones 1993], [W3C 2012], [Motik 2015b], [Motik 2015c],
[Tarjan 1975], [Ma 2006], [Leis 2014], [Budiu 2023].
