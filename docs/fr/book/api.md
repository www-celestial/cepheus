# API

La bibliothèque est `cepheus` (dune) ; son interface est `src/cepheus.mli`, et chaque nom ci-dessous s'y trouve. Les
modules qu'elle exporte aussi (`Cepheus.Journal`, `Cepheus.Store`, ...) sont des internals pour les tests, les outils et
les benchmarks ; ils peuvent changer : [internals](internals.md). Chaque message d'erreur, d'où il vient et que faire :
[erreurs](errors.md). Chaque limite et chaque valeur par défaut : [limites](limits.md). Les exemples sont des programmes
entiers ; `dune test` lance chacun et vérifie la sortie montrée sous lui.

## Valeurs et erreurs

```ocaml signature
type value = Int of int | Float of float | Bool of bool | Text of string | Date of int | Money of int | Link of int
type typ = Tint | Tfloat | Tbool | Ttext | Tdate | Tmoney of int | Tlink
type error =
  | Conflict of string     (* an Expect did not hold *)
  | Invalid of string      (* a wrong type, an unknown thing or property, a schema rule, a malformed question *)
  | Not_unique of string   (* a value of a unique property is taken *)
  | Damaged of string      (* the files lost or changed durable data, or a page of a run does not check *)
  | Io of string           (* the disk failed: the database stopped; close it and open it again *)
  | Busy of string         (* the database is open in another process *)
  | Closed                 (* the database was closed *)
val message : error -> string
```

| valeur | sens | son mot d'index (voir `fold`) |
|---|---|---|
| `Int n` | un entier signé de 63 bits (le `int` d'OCaml) | n |
| `Float f` | un double IEEE 754 ; égal veut dire les mêmes 64 bits (donc `nan` est égal à lui-même, `0.0` diffère de `-0.0`) | un numéro du dictionnaire |
| `Bool b` | | 0 ou 1 |
| `Text s` | n'importe quels octets (UTF-8 par convention ; jamais regardés de l'intérieur) | un numéro du dictionnaire |
| `Date ms` | un instant, en millisecondes depuis le 1970-01-01 UTC | ms |
| `Money m` | un décimal exact : m unités mineures, le nombre de chiffres étant celui de la propriété (`Tmoney 2` : `Money 120000` vaut 1 200,00) | m |
| `Link e` | une autre chose de la même base (un e négatif est une nouvelle chose du même groupe) | e |

Le type d'une propriété est un `typ` ; `Tmoney d` prend 0 à 18 chiffres. `message e` est le texte d'une erreur, sa sorte
d'abord : `"conflict: "`, `"invalid: "`, `"not unique: "`, `"damaged: "`, `"input/output error: "`, `"busy: "`, et
`"the database is closed"`.

## Bases et vues

| fonction | ce qu'elle fait |
|---|---|
| `open_ : string -> (db, error) result` | ouvre la base dans un répertoire, en créant le répertoire (et ses parents) et la base s'ils manquent ; après un crash, fait la recovery (la remise en état en relisant le journal) : la chaîne de runs la plus récente qui se vérifie, puis le journal après elle ([opérations](operations.md#louverture-et-la-recovery)). Erreurs : `Busy` (un autre processus la tient, ou ce processus sous n'importe quel chemin qui nomme le même répertoire : un lien symbolique, `DIR/.`, `x/../DIR`), `Damaged` (des données durables perdues ou changées : elle ne s'ouvre pas), `Io` |
| `close : db -> unit` | attend les écritures en vol et un merge en cours (il est installé), ferme le journal, laisse le marqueur de fermeture propre si aucun fsync n'a échoué, retire du cache les pages des runs, libère le lock. Les vues prises avant restent lisibles (leurs pages sont relues dans les fichiers). Un second `close` ne fait rien (il ne laisse pas le marqueur et ne libère pas le lock une seconde fois : un autre moteur peut avoir ouvert la base entre-temps). Un fork n'a rien à fermer |
| `view : db -> view` | l'état durable le plus récent (pour un fork, son état le plus récent). Gratuit : une seule lecture atomique |
| `group : view -> int` | le numéro du dernier groupe d'une vue |
| `fork : view -> db` | un état temporaire qui part d'une vue : les mêmes lectures et écritures, les mêmes vérifications, rien dans aucun fichier (G8). Gratuit ; un fork d'un fork marche |
| `empty : view` | l'état d'une nouvelle base : groupe 1, les cinq propriétés système. `fork empty` est une base pour un test unitaire |
| `open_on : Disk.t -> string -> (db, error) result` | `open_` sur une autre implémentation du disque, comme le disque simulé (`Sim_disk.disk`) |

```ocaml
open Cepheus

let () =
  let db = Result.get_ok (open_ "data/shop") in
  let[@warning "-8"] (Ok [ name ]) = declare db [ prop "client/name" Ttext ] in
  let r = Result.get_ok (write db ~by:7 ~why:"signup" [ Add (-1, name, Text "Ada") ]) in
  Printf.printf "receipt: group %d, new things %s\n" r.group
    (String.concat ", " (List.map (fun (k, id) -> Printf.sprintf "%d -> %d" k id) r.things));
  Printf.printf "view at group %d\n" (group (view db));
  (match snapshot db with Ok () -> print_endline "merged into a snapshot" | Error e -> print_endline (message e));
  Printf.printf "notes: %d\n" (List.length (notes db));
  close db;
  (match write db [ Add (thing r (-1), name, Text "Ada M.") ] with
   | Ok _ -> ()
   | Error e -> Printf.printf "after close: %s\n" (message e));
  (match verify "data/shop" with Ok n -> Printf.printf "verify: %d groups\n" n | Error e -> print_endline (message e));
  let db = Result.get_ok (open_ "data/shop") in
  Printf.printf "reopened at group %d\n" (group (view db));
  close db
```

```output
receipt: group 3, new things -1 -> 65536
view at group 3
merged into a snapshot
notes: 0
after close: the database is closed
verify: 3 groups
reopened at group 3
```

## Écrire

```ocaml signature
type op =
  | Add of int * int * value               (* thing, property, value; on a one-valued property, retracts the old value *)
  | Retract of int * int * value
  | Expect of int * int * value option     (* Some v: the fact holds before the group; None: the thing has no value *)
  | Incr of int * int * int * (int * int) option   (* thing, property, by, into: a counter the group increments *)
type receipt = { group : int; things : (int * int) list }   (* the group's number; its new things, (-k, id) *)
val write : db -> ?by:int -> ?why:string -> op list -> (receipt, error) result
val thing : receipt -> int -> int
```

`write db ~by ~why ops` applique les opérations comme un seul groupe, tout ou rien (G2). `by` (0 par défaut) et `why`
(`""` par défaut) sont gardés avec le groupe dans le journal. Sur une base, `write` bloque le thread appelant jusqu'à
ce que le groupe soit durable : `Ok` veut dire que le groupe survit à n'importe quel crash (G1), et chaque vue prise
ensuite le tient. Sur un fork, il revient aussitôt. Le numéro du groupe est donné quand le writer (le seul thread qui
applique les groupes, un à la fois) le prend ; les groupes sont appliqués un à la fois dans cet ordre (G4).

- **Nouvelles choses** : un nombre négatif à la place d'une chose, ou dans un `Link`, est une nouvelle chose de ce
  groupe ; chaque nombre négatif distinct reçoit le numéro de chose suivant, dans l'ordre de première apparition.
  `thing r (-k)` est le numéro qu'a reçu `-k` (`Not_found` si `-k` n'était pas dans le groupe) ; il parcourt la liste du
  reçu `r.things` ; pour un grand groupe, lisez donc la liste une fois dans une table.
- **Propriétés à une seule valeur** : un `Add` retire les autres valeurs de la chose pour la propriété dans le même
  groupe (le journal enregistre le retrait).
- **Opérations sans effet** : un `Add` d'un fait qui tient, ou un `Retract` d'un fait qui ne tient pas, n'enregistre
  rien ; un groupe d'opérations sans effet prend quand même un numéro.
- **`Expect`** est vérifié contre l'état d'avant le groupe (quelle que soit sa place dans la liste), par le writer, sur
  l'état le plus récent : c'est ainsi qu'un read-then-write (lire, puis écrire selon ce qu'on a lu) déclare ce qu'il a
  lu ([concepts](concepts.md#lisolation--exactement-ce-que-voient-un-lecteur-et-un-writer)).
- Les valeurs **unique** sont vérifiées sur l'état après tout le groupe ; un groupe peut donc déplacer une valeur unique
  d'une chose à une autre.
- **`Incr (thing, property, by, into)`** est un compteur que le groupe incrémente : la valeur de la chose pour une
  propriété `Int` à une seule valeur (pas de valeur compte pour 0) augmente de `by` (négatif, il compte à rebours),
  lue par le writer à ce point du groupe ; un second `Incr` du même compteur dans le groupe lit donc la valeur du
  premier. `into = Some (thing', property')` ajoute aussi la nouvelle valeur comme `(thing', property')`, une propriété
  `Int`, à une seule valeur ou non ; `thing'` peut être une nouvelle chose du groupe. Des groupes qui incrémentent un
  même compteur en même temps ne sont jamais en conflit et ne sautent jamais une valeur : chacun lit la valeur que le
  groupe d'avant a laissée, et un groupe refusé laisse le compteur tel qu'il était. Dans le journal, il est ce qu'il a
  fait : l'ancienne valeur retirée et la nouvelle ajoutée, comme le ferait un `Add`.

Une facture prend le numéro suivant dans le groupe qui la crée, et un groupe refusé n'en prend aucun :

```ocaml
open Cepheus

let () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ last; number; status ]) =
    declare db [ prop "counter/last" Tint; prop ~unique:true "invoice/number" Tint; prop "invoice/status" Ttext ] in
  let counter = thing (Result.get_ok (write db [ Add (-1, last, Int 0) ])) (-1) in
  let invoice ops = write db (Incr (counter, last, 1, Some (-1, number)) :: Add (-1, status, Text "unpaid") :: ops) in
  let a = thing (Result.get_ok (invoice [])) (-1) in
  (match invoice [ Expect (counter, status, Some (Text "closed")) ] with Error e -> print_endline (message e) | Ok _ -> ());
  let b = thing (Result.get_ok (invoice [])) (-1) in
  let v = view db in
  Printf.printf "numbers %s and %s, the counter at %s\n" (Value.to_string (List.hd (values v a number)))
    (Value.to_string (List.hd (values v b number))) (Value.to_string (List.hd (values v counter last)));
  match write db [ Incr (counter, status, 1, None) ] with Error e -> print_endline (message e) | Ok _ -> ()
```

```output
conflict: #65536 does not have "closed" for invoice/status (property 18)
numbers 1 and 2, the counter at 2
invalid: Incr counts on a one-valued int property of the program's: invoice/status is a text
```

Erreurs : `Conflict` (un `Expect`) ; `Invalid` (une valeur du mauvais type, une chose qui n'a jamais été créée, un lien
vers rien, un `Expect` sur une nouvelle chose, un `Incr` d'une propriété qui n'est pas une propriété `Int` du programme
(à une seule valeur pour le compteur) ou dont la somme dépasse les 63 bits d'un int, une propriété qui n'existe pas, une propriété système sur une chose
ordinaire, une propriété ordinaire sur une chose propriété, une règle du schéma, un groupe dont la frame du journal
dépasserait 256 MiB) ; `Not_unique` ; `Damaged` (une page d'un run dont le groupe avait besoin n'a pas pu être lue ou ne
se vérifie pas : le groupe n'est pas écrit, le writer continue) ; pour une base, aussi `Io` (le disque a lâché : ce
groupe et chaque groupe suivant échouent, jusqu'à ce que la base soit fermée et ouverte à nouveau ; pour un grand
groupe, une erreur de disque pendant l'écriture de son fichier de run fait échouer ce seul groupe, et le writer
continue) et `Closed`. Sur un fork, une page qui ne peut pas être lue lève `Unreadable` au lieu de rendre `Damaged`. Les
messages : [erreurs](errors.md).

**Chargement.** Un chargement est le même `write`, de grands groupes. Un groupe de 20 000 opérations et plus, toutes des
`Add`, aucune sur une propriété système, prend un chemin plus rapide à l'intérieur du writer : ses faits sont triés dans
des tableaux (un counting sort, le tri par comptage, et un radix sort stable, le tri chiffre par chiffre) et fusionnés
d'un coup avec le delta et les runs les plus récents dans un fichier de run, sans persistent map par fait
([architecture](architecture.md#grands-groupes)). Le résultat et les erreurs sont ceux de n'importe quel groupe : au
moindre doute (une erreur, un `Add` d'une propriété à une seule valeur sur une chose qui existe, deux valeurs d'une
propriété à une seule valeur pour une même nouvelle chose, une valeur unique prise ou donnée deux fois), le groupe prend
le chemin ordinaire, qui décide comme toujours. Écrivez un chargement en quelques grands groupes (chacun confirmé une
fois, avec un seul fsync), pas en millions de petits : 10 millions de faits en deux groupes se chargent en 4,1 à 5,6 s
(la médiane d'une série, selon le disque), en 113 636 groupes d'un client chacun en 112 s
([benchmarks](benchmarks.md#le-chargement-en-parallèle-et-sans-copies-2026-11-08-à-10-millions-de-faits)). Un grand
groupe tient le writer pendant son merge (environ une seconde à 10 millions de faits, surtout le disque), et a besoin à
la fois de ses opérations et de 26 octets par fait de tableaux compacts en mémoire (1,46 GB au pic pour 9,4 millions
d'additions, dont 0,88 pour la liste de l'appelant, que `write` relâche une fois le groupe traité) ; sa frame est écrite
par morceaux.
Pour borner la mémoire, écrivez un chargement en groupes de quelques centaines de milliers de faits, depuis deux
threads, pour que l'un construise son groupe suivant pendant que le writer prend celui de l'autre : chaque groupe est
atomique (G2 tient pour un groupe, pas pour le chargement), les runs des groupes restent côte à côte jusqu'à ce que 16
d'entre eux fusionnent en une seule passe ([architecture](architecture.md#merges-a-leveled-log-structured-merge-tree)),
et `snapshot` à la fin laisse un seul run. À 10 millions de faits en groupes de 5 000 clients (environ 415 000 faits)
par deux threads : 9,8 s pour confirmer tous les groupes, 3,2 s pour le snapshot (le merge de toute la base en un seul
run), un pic de 292 MB avec un cache de 64 MB ([benchmarks](benchmarks.md#chunked-loads-2026-11-12-at-10-million-facts)) ;
jusqu'au snapshot, une lecture visite chaque run (à 1 million de faits, un client par e-mail sur 8 runs 1,40 µs, sur
2 runs 0,73).

## Le schéma

```ocaml signature
type prop = { name : string; typ : typ; many : bool; unique : bool }
val prop : ?many:bool -> ?unique:bool -> string -> typ -> prop      (* many and unique: false by default *)
val declare : db -> prop list -> (int list, error) result
val property : view -> string -> int option
val describe : view -> int -> prop option
```

`declare db props` rend les numéros de propriété des noms, dans l'ordre donné, et déclare ceux qui manquent en un seul
groupe (`~why:"cepheus: declare"`), chacun au plus petit numéro libre à partir de 16. Un nom qui existe avec la même
description rend son numéro et n'écrit rien ; avec un autre type, une autre cardinalité ou un autre drapeau unique, le
résultat est `Invalid` et rien n'est écrit. Si un autre writer a pris un numéro entre-temps, `declare` relit le schéma
et réessaie. `property v name` est le numéro d'un nom dans une vue ; `describe v p`, la description d'une propriété.

```ocaml
open Cepheus

let () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ email; tag ]) = declare db [ prop ~unique:true "client/email" Ttext; prop ~many:true "client/tag" Ttext ] in
  let v = view db in
  Printf.printf "client/email is %d, client/tag is %d\n" email tag;
  (match describe v tag with
   | Some d -> Printf.printf "%s: %s, many %b, unique %b\n" d.name (Value.typ_name d.typ) d.many d.unique
   | None -> ());
  Printf.printf "client/phone: %s\n" (match property v "client/phone" with Some p -> string_of_int p | None -> "none");
  (match declare db [ prop ~unique:true "client/email" Ttext ] with Ok [ p ] -> Printf.printf "again: %d\n" p | _ -> ());
  match declare db [ prop "client/email" Tint ] with Ok _ -> () | Error e -> print_endline (message e)
```

```output
client/email is 16, client/tag is 17
client/tag: text, many true, unique false
client/phone: none
again: 16
invalid: client/email is declared already as another kind of property
```

## Règles

```ocaml signature
type term = Var of int | Thing of int | Val of value          (* as in questions *)
type pattern = { e : term; p : int; v : term }
type head = Give of pattern | Never
val prop_var : int -> int                                     (* a pattern's property as the variable ?k *)
val every : int -> int                                        (* a template's list: [c, every l, m] *)
type rule = { name : string; vars : int; where : pattern list; ranges : (int * value * value) list; head : head }
val define : db -> rule list -> (int list, error) result
val undefine : db -> string list -> (unit, error) result
type proof =
  | Given of { e : int; p : int; v : value }
  | By of { rule : string; e : int; p : int; v : value; from : proof list }
val why : view -> int -> int -> value -> proof option
val sources : view -> int -> int list option
val rule_budget : int ref * int ref
val change_budget : int ref
```

Une règle est faite des patterns et des intervalles d'une question (`where`, `ranges`, les variables 0 à `vars - 1`) et
d'une tête : `Give pattern`, le fait qu'elle donne pour chaque réponse, ou `Never`, une contrainte ([règles](rules.md)).
`define db rules` rend les choses règles (entre 16 et 65 535, comme les propriétés) des règles, dans l'ordre donné, et
écrit en un seul groupe (`~why:"cepheus: rules"`) les nouvelles (au plus petit numéro libre) et celles dont la
définition a changé (trouvées par leur nom) ; une règle déjà définie avec la même définition n'écrit rien. Le writer
vérifie chaque règle (la range restriction : chaque variable de la tête apparaît dans le corps ; les types ; la
propriété de la tête ; erreurs `Invalid "rule NAME: …"`, [erreurs](errors.md#invalid--la-requête-est-fausse)) et dérive
dans ce groupe ce qu'elle donne sur toute la base, dans les limites du budget d'un changement ; une contrainte est
vérifiée sur toute la base. Un nom qui est celui d'une propriété est `Invalid`. Si un autre writer a pris un numéro
entre-temps, ou si un groupe écrit entre-temps a gêné le changement, `define` relit le schéma et réessaie
(`Conflict`). Dans une base sur le disque, le changement est calculé à côté du writer et revient une fois installé
([règles](rules.md#changes-of-the-rules-in-the-background)) : un `write` envoyé entre-temps peut être placé avant lui.

La propriété `p` d'un pattern est l'id d'une propriété, ou `prop_var k` (un nombre négatif) pour la variable `?k` : un
autre pattern du corps, dont la propriété est une constante, a `?k` pour chose ou pour valeur. Une valeur lue sous une
propriété variable a le type de cette propriété ; une tête qui donne un fait que sa propriété ne peut pas prendre
refuse le groupe (erreurs `Invalid "rule R gives …"`). Ces règles tournent dépliées sur les faits de leurs petites
relations ([règles](rules.md#specialisation-by-small-relations)) ; les questions gardent des propriétés constantes.

Un pattern `[c, every l, m]` est la liste d'un **template** (une règle écrite une fois pour tous les membres d'une
liste) : « pour chaque valeur m de la propriété l de c », les patterns qui nomment m écrits une fois pour chaque
membre, les variables qu'eux seuls tiennent nouvelles dans chaque copie (cls-int1 et prp-key d'OWL 2 RL, les règles du
W3C pour raisonner sur des ontologies, des descriptions de classes, de propriétés et de leurs liens) ; le writer le déplie sur les faits de l, donc une écriture de l est un
changement des règles, et aucune règle ne peut donner l ([templates](rules.md#templates-rules-over-lists)). Une tête
`[x, cepheus/same, y]` (`Schema.p_same`, la propriété système 6) fait de x et y une seule chose
([égalité](rules.md#equality-classes-of-equal-things)).

`undefine db names` retire en un seul groupe les règles de ces noms : leurs définitions retirées, et les faits qu'elles
seules dérivaient avec elles (un nom qui n'est pas une règle est ignoré).

`why v e p x` est une preuve du fait `(e, p, x)` de la vue v : `Given` pour un fait affirmé, `By` pour un fait dérivé,
avec le nom de la règle et les preuves des faits de son corps, dans l'ordre des patterns de la règle ; `None` quand le
triplet n'est pas un fait de v. Calculée à l'appel, sur la vue : rien n'est rangé au moment de l'écriture (G20).

`sources v p` liste les propriétés dont les faits peuvent donner, par les règles et de proche en proche, les faits
dérivés de la propriété `p` (`Some []` pour une propriété qu'aucune règle ne donne), ou `None` quand une règle sur le
chemin lit une propriété variable : ce qu'un lecteur qui n'a droit qu'à certains kinds (un kind regroupe sous un nom
les propriétés d'une sorte de chose) doit lire pour lire les faits dérivés de `p` sans apprendre des faits qu'il n'a
pas le droit de lire.

`rule_budget` est (base, per) : un groupe dont les changements dérivés dépassent $\mathit{base} + \mathit{per} \times \text{ses changements affirmés}$ est refusé,
`Invalid "rule NAME derived more than N facts from a group of K facts"` ; (100 000, 100) par défaut, pour chaque base du
processus. Un changement des règles ou de l'ontologie peut aussi dériver jusqu'à `change_budget` (4) fois les faits de
la base d'avant lui : au-delà, `Invalid "rule NAME derived more than N facts from a change of the rules or the ontology"`.

```ocaml
open Cepheus

let () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ member; member_of ]) =
    declare db [ prop ~many:true "org/member" Tlink; prop ~many:true "person/memberOf" Tlink ]
  in
  (* each of two properties the inverse of the other *)
  let inverse name a b =
    { name; vars = 2; where = [ { e = Var 0; p = a; v = Var 1 } ]; ranges = []; head = Give { e = Var 1; p = b; v = Var 0 } }
  in
  let ids = Result.get_ok (define db [ inverse "member-inverse" member member_of; inverse "memberOf-inverse" member_of member ]) in
  Printf.printf "rules %s\n" (String.concat ", " (List.map string_of_int ids));
  let r = Result.get_ok (write db [ Add (-1, member, Link (-2)) ]) in
  let club = thing r (-1) and ada = thing r (-2) in
  Printf.printf "ada is a member of %s\n" (String.concat ", " (List.map Value.to_string (values (view db) ada member_of)));
  (match why (view db) ada member_of (Link club) with
   | Some (By { rule; from = [ Given g ]; _ }) -> Printf.printf "by %s, from [#%d %d %s]\n" rule g.e g.p (Value.to_string g.v)
   | _ -> ());
  (* the two facts derive each other; with the asserted one gone, both go *)
  ignore (Result.get_ok (write db [ Retract (club, member, Link ada) ]));
  Printf.printf "after: %d and %d\n" (List.length (values (view db) club member)) (List.length (values (view db) ada member_of));
  ignore (Result.get_ok (undefine db [ "member-inverse"; "memberOf-inverse" ]))
```

```output
rules 18, 19
ada is a member of #65536
by member-inverse, from [#65536 16 #65537]
after: 0 and 0
```

## OWL 2 RL

```ocaml signature
module Owl : sig
  type t = { type_ : int; same_as : int; sub_class_of : int; (* ... a field a property of the vocabulary *) thing : int; nothing : int }
  val vocabulary : (string * typ * bool * bool) list           (* name, type, many, unique *)
  val setup : db -> (t, error) result
  val rl : t -> rule list
  val description : t -> view -> int -> int option
  val all_different : t -> int list -> op list
  val disjoint_classes : t -> int list -> op list
  val disjoint_properties : t -> (int * int) list -> op list
end
val same : view -> int -> int list
```

`Owl.setup db` déclare le vocabulaire (`owl/Type`, `owl/SubClassOf`, …, en un seul groupe) et crée owl:Thing et
owl:Nothing (`[t, owl/Builtin, "Thing"]`), une seule fois : une base qui les a les garde, et les ids sont dans le
record (la valeur de type t qu'il rend). `Owl.rl o` est la liste des règles (`owl/cax-sco`, …) : définissez-les avec
`define`. `Owl.description o v p` est la chose qui décrit la propriété p (`[d, owl/Property, Link p]`), s'il y en a
une. `all_different`, `disjoint_classes` et `disjoint_properties` donnent les opérations qui écrivent ces axiomes
n-aires (qui portent sur n choses à la fois) sous forme de leurs paires. `same v x` est la classe des choses égales à
x, par id, x compris ([x] quand aucune autre chose ne lui est égale) ; `get`, `values`, `things` et les questions
lisent une chose qu'ils nomment comme le représentant de sa classe. Le tout : [OWL 2 RL](rules.md#owl-2-rl-a-library-of-rules).

## Lire

```ocaml signature
val get : view -> int -> (int * value) list       (* every fact of a thing: (property, value), sorted *)
val values : view -> int -> int -> value list      (* values v thing property *)
val things : view -> int -> value -> int list      (* things v property value: the things with this value, sorted *)
exception Unreadable of string
```

`get v e` est chaque fait de la chose e, trié par propriété puis par valeur ; `[]` pour un numéro qui n'est pas une
chose. `values v e p` est les valeurs de e pour p (l'ordre n'est pas spécifié) ; `[]` si p n'est pas une propriété.
`things v p x` est les choses qui ont la valeur x pour p, dans l'ordre croissant ; pour une propriété de lien,
`things v p (Link t)` est les choses qui pointent vers t par p. Les trois lisent les runs à travers le cache : quand une
page ne peut pas être lue sur le disque ou ne se vérifie pas contre son CRC (son checksum, un nombre calculé sur ses octets), elle n'est jamais
servie, et ils lèvent `Unreadable` avec le fichier et la page.

```ocaml
open Cepheus

let () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ name; tag; follows ]) =
    declare db [ prop "client/name" Ttext; prop ~many:true "client/tag" Ttext; prop ~many:true "client/follows" Tlink ]
  in
  let r =
    Result.get_ok
      (write db [ Add (-1, name, Text "Ada"); Add (-1, tag, Text "vip"); Add (-1, tag, Text "lyon"); Add (-2, name, Text "Bob");
                  Add (-2, follows, Link (-1)); Add (-2, tag, Text "vip") ])
  in
  let ada = thing r (-1) and bob = thing r (-2) in
  let v = view db in
  let ints l = String.concat " " (List.map string_of_int l) in
  Printf.printf "tags of Ada: %s\n" (String.concat " " (List.map Value.to_string (List.sort compare (values v ada tag))));
  Printf.printf "things tagged vip: %s\n" (ints (things v tag (Text "vip")));
  Printf.printf "who follows Ada: %s\n" (ints (things v follows (Link ada)));
  Printf.printf "facts of Bob: %d\n" (List.length (get v bob))
```

```output
tags of Ada: "lyon" "vip"
things tagged vip: 65536 65537
who follows Ada: 65537
facts of Bob: 3
```

## Questions

```ocaml signature
type term = Var of int | Thing of int | Val of value
type pattern = { e : term; p : int; v : term }      (* thing, property, value *)
type query = { vars : int; where : pattern list; ranges : (int * value * value) list }
val find : view -> query -> (value array list, error) result
val fold : view -> query -> init:(unit -> 'a) -> step:('a -> int array -> 'a) -> merge:('a -> 'a -> 'a) -> ('a, error) result
val decode : view -> query -> int -> int -> value
```

Une question a `vars` variables, numérotées de 0 à `vars - 1`, et des patterns dont la chose (`e`) et la valeur (`v`)
sont une variable, une chose (`Thing n`) ou une valeur (`Val x`) ; la propriété est toujours une constante. Une
variable à la place d'une chose est un lien ; le type d'une variable est le type des propriétés avec lesquelles elle
apparaît, et doit être un seul type. Les `ranges` gardent `lo <= x <= hi` pour une variable d'un type dont le mot
d'index est la valeur (int, date, money, bool, link) ; plusieurs intervalles sur une même variable s'intersectent.

`find v q` rend chaque binding (une valeur pour chaque variable) qui fait de chaque pattern un fait de la vue, chacun une
fois (G11), comme des tableaux indexés par variable ; leur ordre n'est pas spécifié. Une constante que la vue n'a jamais
vue (un texte jamais écrit), ou un pattern sans variable qui n'est pas un fait, rend la réponse vide. Avec `vars = 0`,
une question est un test par oui ou non : `[ [||] ]` si ses patterns sont des faits, `[]` sinon.

`fold v q ~init ~step ~merge` replie les bindings sans construire de valeurs : `step acc w` reçoit dans `w` les mots
d'index d'un binding (les numéros de chose pour les liens, la valeur pour les entiers, les dates et money, 0 ou 1 pour
les booléens, les numéros du dictionnaire pour les textes et les flottants), dans un buffer qu'il réutilise, donc `step`
ne doit pas garder `w`. Quand la première variable a 20 000 candidats ou plus (`Query.parallel_min`), la question
tourne sur jusqu'à `Query.domains` domains (des fils d'exécution d'OCaml en parallèle ; le nombre recommandé pour la
machine, au plus 8) : les candidats sont coupés en slices (des tranches), chaque slice repliée à partir de son propre
`init ()`, et les résultats des slices joints par `merge` dans l'ordre des slices, si bien que le résultat ne dépend pas
du nombre de domains ; `step` peut tourner sur plusieurs domains à la fois et ne doit toucher que son accumulateur. Sous
le seuil, `init` est appelé une fois et `merge` jamais.

`decode v q x w` est la valeur de la variable `x` de `q` dont le mot d'index est `w` : la valeur que donnerait `find`,
un `Text` pour le numéro du dictionnaire d'une variable texte, un `Float` pour celui d'un flottant, un `Link` pour une
chose, `Int`, `Date`, `Money` ou `Bool` pour les autres ; le type vient de la question, comme pour `find`. Un fold dont
les clés sont des mots donne leurs textes à ses clés une fois chacune, à la fin (ou dans `step`, avec un coût par
binding : une lecture du dictionnaire et une chaîne). Il lit la vue que le fold a lue ; il lève `Invalid_argument` pour
une variable hors de la question ou une question que `fold` refuse, et `Unreadable` quand la page du texte ne peut pas
être lue.

Erreurs des deux : `Invalid` (une propriété inconnue, une variable hors des bornes, dans aucun pattern ou de deux types,
une constante du mauvais type, un intervalle sur une variable texte ou flottante) et `Damaged` (une page qui ne peut pas
être lue ou ne se vérifie pas).

```ocaml
open Cepheus

let () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ score ]) = declare db [ prop "player/score" Tint ] in
  ignore (write db (List.mapi (fun i s -> Add (-(i + 1), score, Int s)) [ 12; 40; 7; 33; 40 ]));
  let v = view db in
  (* the players with a score between 10 and 35 *)
  let q = { vars = 2; where = [ { e = Var 0; p = score; v = Var 1 } ]; ranges = [ (1, Int 10, Int 35) ] } in
  (match find v q with
   | Ok rows -> List.iter (fun r -> Printf.printf "%s %s\n" (Value.to_string r.(0)) (Value.to_string r.(1))) (List.sort compare rows)
   | Error e -> print_endline (message e));
  let yes = { vars = 0; where = [ { e = Thing 65537; p = score; v = Val (Int 40) } ]; ranges = [] } in
  Printf.printf "65537 has 40: %b\n" (find v yes = Ok [ [||] ]);
  match find v { vars = 1; where = []; ranges = [] } with Ok _ -> () | Error e -> print_endline (message e)
```

```output
#65536 12
#65539 33
65537 has 40: true
invalid: variable 0 appears in no pattern
```

Une somme par ville avec `fold`, dont la clé est le mot d'index de la ville, et les textes des villes donnés par
`decode` une fois chacun :

```ocaml
open Cepheus

let () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ city; total ]) = declare db [ prop "invoice/city" Ttext; prop "invoice/total" (Tmoney 2) ] in
  ignore
    (write db
       (List.concat
          (List.mapi (fun i (c, m) -> [ Add (-(i + 1), city, Text c); Add (-(i + 1), total, Money m) ])
             [ "Lyon", 1200; "Nice", 500; "Lyon", 300; "Brest", 250; "Nice", 50 ])));
  let v = view db in
  let q = { vars = 3; ranges = []; where = [ { e = Var 0; p = city; v = Var 1 }; { e = Var 0; p = total; v = Var 2 } ] } in
  let add t k x = Hashtbl.replace t k (x + Option.value (Hashtbl.find_opt t k) ~default:0) in
  match
    fold v q ~init:(fun () -> Hashtbl.create 8)
      ~step:(fun t w -> add t w.(1) w.(2); t)
      ~merge:(fun a b -> Hashtbl.iter (add a) b; a)
  with
  | Ok sums ->
    Hashtbl.fold (fun w m acc -> (Value.to_string (decode v q 1 w), m) :: acc) sums []
    |> List.sort compare
    |> List.iter (fun (c, m) -> Printf.printf "%s %d.%02d\n" c (m / 100) (m mod 100))
  | Error e -> print_endline (message e)
```

```output
"Brest" 2.50
"Lyon" 15.00
"Nice" 5.50
```

Comment on répond à une question, et ce que cela coûte : [architecture](architecture.md#questions),
[théorie](theory.md#4-generic-join).

## Des questions avec des opérateurs, un ordre et des pages

```ocaml signature
module Question : sig
  type item = Pattern of pattern | Range of int * value * value | In of int * value list | Prefix of int * string
            | Not of item list | Or of item list list
  type key = { col : int; desc : bool }
  type t = { vars : int; items : item list; give : int array; sort : key list; limit : int; after : value array option }
end
val ask : view -> Question.t -> (value array list, error) result
```

Ses noms sont dans le module `Question`, pour que `open Cepheus` n'apporte que `Question` et `ask` à côté des noms
qu'il apportait déjà (le `Not` ou le `Pattern` propre d'un programme reste le sien) ; `Question.[ ... ]` l'ouvre pour
une liste d'items. `ask v q` répond à une question qui a `Not`, `Or`, `In` et `Prefix` à côté de ses patterns et de ses
intervalles, et rend ses lignes triées, coupées et découpées en pages : le même sens et les mêmes bornes que depuis
Cesia ([Not, Or et In](cesia.md#not-or-and-in), [Prefix](cesia.md#prefix-the-start-of-a-text),
[pages](cesia.md#sort-limit-and-after-pages)). `give` nomme les variables de chaque ligne (vide : chaque variable de la
question) ; le `col` d'une clé est une colonne de `give` ; `limit` 0 rend toutes les lignes ; `after` est une ligne des
colonnes de `give`. `find` et `query` ne changent pas : une question de patterns et d'intervalles, avec chaque
variable donnée, a les lignes que rend `find`.

```ocaml
open Cepheus

let () =
  let db = Result.get_ok (open_ "asks") in
  let[@warning "-8"] (Ok [ name; city ]) = declare db [ prop "client/name" Ttext; prop "client/city" Ttext ] in
  List.iter (fun (n, c) -> ignore (write db [ Add (-1, name, Text n); Add (-1, city, Text c) ]))
    [ "Ada", "Lyon"; "Bo", "Paris"; "Abel", "Lyon"; "Ali", "Paris"; "Cy", "Nice" ];
  (* the names that start with A, of clients not in Paris, the largest first *)
  let q =
    { Question.vars = 2;
      items = Question.[ Pattern { e = Var 0; p = name; v = Var 1 }; Prefix (1, "A"); Not [ Pattern { e = Var 0; p = city; v = Val (Text "Paris") } ] ];
      give = [| 1 |]; sort = [ { Question.col = 0; desc = true } ]; limit = 10; after = None }
  in
  (match ask (view db) q with
   | Ok rows -> List.iter (fun r -> print_endline (Value.to_string r.(0))) rows
   | Error e -> print_endline (message e));
  close db
```

```output
"Ada"
"Abel"
```

## Le cache

`set_cache bytes` fixe combien d'octets de pages de runs le processus garde en mémoire, pour toutes ses bases à la fois
(1 GiB par défaut ; au moins 16 pages de 16 KiB). Il prend effet à mesure que les pages arrivent (un cache plus petit
évince à mesure que les pages suivantes sont lues) et à l'ouverture suivante (un run qui tient dans le cache est lu et
vérifié en entier à l'ouverture ; un plus grand, ses tables à l'ouverture et ses autres pages selon les besoins des
questions).
[opérations](operations.md#la-mémoire).

## Opérations

| fonction | ce qu'elle fait |
|---|---|
| `snapshot : db -> (unit, error) result` | fait un merge maintenant : le delta (les changements depuis le dernier merge) et chaque run en un seul run, une seule base, la plus rapide à lire, pour que l'ouverture suivante ne rejoue rien ; il attend d'abord un merge en cours. Rien à faire s'il y a un seul run et qu'aucun groupe n'est venu depuis le dernier merge. Erreurs : `Io`, `Damaged` (une page d'un run), l'erreur qui a arrêté la base, `Closed` ; sur un fork, `Invalid "a fork has no files"` |
| `verify : string -> (int, error) result` | lit tout le journal d'une base fermée depuis son premier segment et vérifie chaque frame, chaque trailer et chaque numéro de groupe : le nombre de groupes, ou `Damaged` qui nomme le premier défaut, ou `Io`. Il ne prend pas le lock : ne le lancez jamais sur une base ouverte. Les fichiers de run ne sont pas lus (ils sont vérifiés à chaque ouverture, et sont des caches du journal) |
| `notes : db -> string list` | ce que la dernière ouverture a mis de côté : `"snapshot <name> set aside: <reason>"` pour chaque fichier de run qui ne s'est pas vérifié, ou qui est d'un format plus ancien (`<name>.snap` : le journal est rejoué) ; `[]` pour un fork |

## Threads et domains

Une vue peut être lue depuis n'importe quel thread et n'importe quel domain en même temps, sans lock. `write` peut être
appelé depuis n'importe quel thread de n'importe quel domain : le writer et le syncer (le thread qui fait les fsyncs du
journal) tournent dans un domain à eux, l'appelant attend sur sa propre condition variable. Le `write` d'un fork prend le
mutex du fork, donc on peut écrire dans un même fork depuis plusieurs threads. Le `step` et l'`init` de `fold` peuvent
tourner sur d'autres domains.
