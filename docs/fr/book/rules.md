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
- Dans cette version, la propriété d'un pattern est une constante, comme dans une question ; la négation (`Not`), les
  agrégats (`Sum`, `Count`) et les modules pour la fermeture transitive sont les étapes suivantes de la conception.

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

Après le point fixe du groupe, les plans des contraintes tournent sur chaque fait que le groupe a rendu présent : une
instance d'une contrainte ne peut apparaître que par un nouveau fait (les règles sans négation sont monotones), donc
cela trouve chaque violation que ferait le groupe. Définir une contrainte la vérifie sur toute la base.

Les propres règles du schéma s'appliquent aussi aux faits dérivés : une règle qui donnerait une seconde valeur à une
propriété à une seule valeur, ou une valeur d'une propriété unique qu'une autre chose tient, refuse le groupe et nomme
la règle.

## Le budget

Une règle peut dériver énormément à partir d'une petite écriture (chaque paire de membres d'un club). Le writer refuse
un groupe dont les changements dérivés dépassent **$100\,000 + 100 \times \text{ses changements affirmés}$** : `Invalid "rule NAME derived more than N facts
from a group of K facts"`, qui nomme la règle qui a le plus dérivé. La partie proportionnelle laisse un chargement
dériver en proportion ; la partie fixe borne ce qu'une petite écriture peut coûter aux autres writers, qui l'attendent
(environ 0,1 s de raisonnement au niveau du budget). `rule_budget` tient les deux nombres.

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
**n'évalue jamais une règle** : la recovery, une réplique, un lecteur local, le passé n'ont besoin d'aucun moteur de
raisonnement, et un changement ultérieur du code du moteur de raisonnement ne change jamais ce que le journal dit que
la base a été. Un fait dérivé coûte ses octets dans la frame : sa sorte dans la colonne des sortes (quelques bits par
changement, ou aucun dans un bloc d'une seule sorte), sa chose et sa valeur dans leurs colonnes
([formats](formats.md#un-groupe)).

Dans un run (format 7, [formats](formats.md#run-dirsnapshotslo-20-digits-hi-20-digitsrun)), le drapeau « seulement
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
```

Une règle s'écrit donc dans un groupe comme n'importe quel fait, le journal garde chacune de ses versions, et un fork la
reçoit avec le reste. `define db rules` trouve chaque règle par son nom et écrit, en un seul groupe, les nouvelles
règles et celles qui ont changé ; `undefine db names` retire des règles. Un groupe qui définit une règle dérive ce que
la règle donne sur toute la base ; un groupe qui retire une règle retire ce qu'elle seule dérivait (par B/F : chaque
fait que donnait la règle est vérifié pour une autre preuve), les deux dans les limites du budget, dans ce groupe : un
changement de règle prend effet à un seul numéro de groupe, chaque vue d'avant lui étant la materialisation sous les
anciennes règles, chaque vue à partir de lui sous les nouvelles (G19).

Les règles sont compilées à la première écriture qui en a besoin, jamais à l'ouverture : une ouverture rejoue des
frames, qui tiennent déjà les faits dérivés, donc le démarrage ne grandit pas.

## Grands groupes

Un groupe de 20 000 additions et plus (un chargement) prend le chemin des grands groupes
([architecture](architecture.md#grands-groupes)) : ses faits sont placés dans des tableaux compacts et fusionnés d'un
coup dans un run. Avec des règles, ses faits sont le tour 0 de la même semi-naive evaluation, dans le working set (un
ensemble de travail), et les faits dérivés sont ajoutés aux tableaux du groupe : ils atteignent le run avec les faits
affirmés, en un seul merge. Un groupe que le chemin rapide ne peut pas décider seul (une contrainte, une tête sur une
propriété à une seule valeur ou unique, un fait déjà dérivé et maintenant affirmé) prend le chemin ordinaire, qui
décide comme toujours. Le texte d'une règle que le groupe ajoute lui-même se trouve parmi les nouveaux textes du groupe,
que la map du dictionnaire ne tient pas encore (la simulation a trouvé ce cas : sans cela, un pattern sur un tel texte
ne correspondait à rien).

## Ce que cela coûte, et face aux géants

Mesuré sur ce portable (Intel i7-4720HQ, 2,6 GHz, 4 cœurs ; OCaml 5.5 sans flambda), sur des données en forme de LUBM
(des universités, des départements, des personnes, des cours, générés d'après les intervalles publiés du générateur
LUBM [Guo 2005], pas sa sortie officielle) avec l'ontologie univ-bench sous forme de 94 règles, une par axiome. Sept
tours, alternés, chaque processus limité à 3 GB, rien d'autre ne tournant ; la médiane et l'intervalle $[x(1), x(7)]$ des
tours (couverture de 98,4 %). La méthode et chaque chiffre : [benchmarks](benchmarks.md#règles-2026-11-08).

| quoi | avec les règles | sans | |
|---|---|---|---|
| écrire un étudiant de troisième cycle (10 faits ; 6 dérivés) | **23,1 µs** [21,9 ; 24,1] | 9,1 µs | 2,5× |
| le retirer (B/F : les 6 faits dérivés partent) | **34,1 µs** [33,1 ; 54,8] | 6,9 µs | 4,9× |
| `why` d'un type dérivé (une preuve de 2 à 8 faits) | **1,2 à 3,1 µs** | | |
| charger 10 universités en un seul groupe (1,35 M de faits, 532 205 dérivés, 2 024 788 dérivations), durable | 2,48 s | 1,20 s | |
| son raisonnement : la saturation seule | **1,04 M de faits dérivés/s** [0,98 ; 1,05] sur un cœur | | |
| son raisonnement avec la construction du working set (1,35 M de faits indexés, 0,58 s) | 0,52 M de faits dérivés/s [0,49 ; 0,53] | | |
| un fait dérivé mis dans la vue (un delta de 200 000 changements) | **0,83 µs** en lots triés ; 1,12 µs un par un | | |

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

- **Un cœur, la saturation** : 1,04 M de faits dérivés/s ici, 0,67 M/s pour RDFox 2014, environ 1,28 M/s pour VLog : le
  même ordre de grandeur ; le débit publié de VLog reste devant de 1,2×, sur une autre machine et avec cent fois plus de
  données.
- **En comptant la construction du working set** (les faits d'un chargement indexés pour les joins, ce que les débits
  publiés comptent dans leur chargement), 0,52 M/s : le niveau de RDFox 2014, derrière VLog de 2,5×. L'étape suivante
  de la conception trie les faits d'un chargement au lieu de les hacher (la propre méthode de VLog).
- **En parallèle** : pas encore ; RDFox atteint 7,0 M/s sur 32 threads.
- **Petites écritures** : des microsecondes, dans le processus. Aucun géant ne publie de latence par groupe à comparer.
- **Là où le moteur de raisonnement coûte le plus** : un retrait, 4,9 fois le même groupe sans règles. B/F vérifie
  chaque fait qui a perdu une dérivation contre chaque règle qui peut le donner, chaque vérification étant une recherche
  dans les persistent maps ou les runs du store (34 recherches pour un étudiant) ; le prototype de la conception, sur
  des hash tables à lui, prenait 19,1 µs.

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
- **Les faits dérivés dans le journal, pas recalculés** : le replay, les répliques et le passé n'ont besoin d'aucun
  moteur de raisonnement, et un changement du code du moteur ne change jamais le passé ; la frame porte les faits
  dérivés (+40 % d'octets sur LUBM).
- **`why` calculé à la demande, pas rangé** : rien de payé au moment de l'écriture ; une preuve, pas la plus courte.
- **Un fait dérivé ne peut pas être retiré** : pas d'opération sans effet silencieuse ; le message nomme la règle et les
  faits à retirer.
- **Le drapeau dans le champ de la valeur** (le bit 63 du mot de valeur au format 6, le bit le plus bas du champ dans
  les blocs du format 7 qui tiennent un fait dérivé) : pas un octet de plus sans règles ; un run d'un format plus
  récent n'est pas lu par un binaire plus ancien, qui rejoue le journal à la place.
- **Le budget proportionné au groupe** ($100\,000 + 100 \times \text{ses changements affirmés}$) : un chargement dérive en proportion, une règle qui
  s'emballe est arrêtée et nommée.

## Ce qui n'est pas encore là

Le plan de la conception a six étapes ; cette version est la première.

- **Étape 2** : le module de fermeture pour les propriétés transitives (60 à plus de 1 000 fois la règle dans le
  prototype), et des règles écrites de façon générique sur l'ontologie (une propriété variable, `[p, owl.Domain, c],
  [x, p, y]`), spécialisées par le moteur en une règle par axiome (2,2 fois plus rapide, mesuré). D'ici là, la propriété
  d'un pattern est une constante.
- **Étape 3** : les grandes dérivations triées et parallèles, sur plusieurs domains.
- **Étape 4** : la négation stratifiée (`Not`) et les agrégats (`Sum`, `Count`, `Min`, `Max`).
- **Étape 5** : les changements de règles aux grandes conséquences calculés en arrière-plan et installés à un seul
  groupe.
- **Étape 6** : OWL 2 RL comme bibliothèque de règles, et l'égalité (`owl:sameAs`) par réécriture.
- Le budget comme réglage de la base plutôt que comme nombre du processus ; le groupe qui a affirmé chaque feuille d'une
  preuve.

## Références

Chaque travail cité ici est dans les
[références](references.md#les-règles--datalog-la-matérialisation-et-sa-maintenance), avec ce que Cepheus en a pris :
[Abiteboul 1995], [Bancilhon 1986], [Ramakrishnan 1990], [Feeley 1987], [Gupta 1993], [Motik 2015], [Motik 2019],
[Motik 2014], [Urbani 2016], [Scholz 2016], [Zhao 2020], [Guo 2005].
