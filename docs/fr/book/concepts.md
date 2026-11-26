# Concepts

Ce que Cepheus stocke, comment un programme l'écrit et le lit, et ce qu'un lecteur peut voir et ne peut pas voir.
Chaque exemple de cette page est un programme entier : `dune test` compile et exécute chacun d'eux et vérifie la sortie
montrée en dessous. Comment le moteur s'y prend (le journal, la recovery, c'est-à-dire la remise en état à l'ouverture,
le merge des fichiers triés, le cache) est dans [architecture](architecture.md) ; les promesses exactes sont dans
[garanties](guarantees.md) ; chaque terme est aussi dans le [glossaire](glossary.md).

## Les faits : le modèle entity–attribute–value

Tout ce que Cepheus stocke est un **fait**, un triplet `(thing, property, value)` (chose, propriété, valeur) : « la
facture 65537 a le total 1 200,00 ». C'est le **modèle entity–attribute–value** (EAV, entité–attribut–valeur) : au lieu
de tables aux colonnes fixes, une base de données est un ensemble de petits énoncés, qui nomment chacun une chose, une
de ses propriétés et une valeur. Le même modèle est le **triplet** de RDF (sujet, prédicat, objet) et le **datom** de
Datomic (entité, attribut, valeur, transaction, ajouté) ; dans Cepheus, la transaction et l'indicateur « ajouté ou
retiré » d'un datom vivent dans les groupes du journal (plus bas), et une vue contient les faits qui sont vrais à son
groupe.

- Une **chose** (l'entité ; *thing* dans le code) est un numéro et rien d'autre : elle n'a ni table ni colonnes,
  seulement les faits qui la concernent. La base donne les numéros de chose de façon dense, à partir de 65 536, dans
  l'ordre où les choses sont créées. Des numéros denses font de « chaque fait d'une chose » un accès à un tableau, pas
  une recherche ([architecture](architecture.md#les-index--les-runs-et-le-delta)).
- Une **propriété** (l'attribut) est elle-même une chose, numérotée de 16 à 65 535, avec un nom comme `client/city`, un
  type et deux indicateurs (plus bas). Les numéros 1 à 5 sont les propriétés système, qui décrivent les propriétés et
  les règles, et le 6, `cepheus/same`, tient les classes de choses que les règles ont rendues identiques
  ([règles](rules.md#légalité--des-classes-de-choses-égales)).
- Une **valeur** est atomique et typée : `Int` (un entier signé de 63 bits), `Float`, `Bool`, `Text` (des octets ; de
  l'UTF-8 par convention, Cepheus ne regarde pas dedans), `Date` (des millisecondes depuis le 1970-01-01 UTC), `Money`
  (un décimal exact gardé comme un entier d'unités mineures, les centimes par exemple, le nombre de chiffres décimaux
  étant celui de la propriété, de 0 à 18) et `Link` (une autre chose : une référence). Il n'y a ni liste ni structure
  dans une valeur : une liste, ce sont plusieurs faits d'une propriété à plusieurs valeurs ; une structure, c'est une
  chose avec ses propres faits.

```ocaml
open Cepheus

let () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ name; client; total ]) =
    declare db [ prop "client/name" Ttext; prop "invoice/client" Tlink; prop "invoice/total" (Tmoney 2) ]
  in
  let r = Result.get_ok (write db [ Add (-1, name, Text "Ada Martin"); Add (-2, client, Link (-1)); Add (-2, total, Money 120000) ]) in
  let ada = thing r (-1) and invoice = thing r (-2) in
  let v = view db in
  let show e = List.iter (fun (p, x) -> Printf.printf "(%d, %d, %s)\n" e p (Value.to_string x)) (get v e) in
  show invoice;
  show ada;
  show name (* a property is a thing too: its name, its type code, its two flags *)
```

```output
(65537, 17, #65536)
(65537, 18, money 120000)
(65536, 16, "Ada Martin")
(16, 1, "client/name")
(16, 2, 3)
(16, 3, false)
(16, 4, false)
```

`Money 120000` avec deux chiffres décimaux vaut 1 200,00. Un lien s'affiche `#65536`.

## Les propriétés et le schéma

Une propriété est décrite par quatre faits sur sa chose : `cepheus/name` (1, un texte, unique), `cepheus/type` (2, le
code du type), `cepheus/many` (3) et `cepheus/unique` (4). Le **schéma** (la liste des propriétés et de leurs types)
est donc une donnée comme une autre : déclarer une propriété, c'est écrire ces quatre faits ; un changement de schéma
est un groupe gardé dans le journal comme toute écriture ; et le schéma se lit et s'interroge comme le reste.
`declare` renvoie les numéros des propriétés qu'on lui donne, et déclare en un seul groupe celles qui n'existent pas
encore ; `property v name` et `describe v p` lisent le schéma d'une vue.

- **à une valeur** (le défaut ; la **cardinalité** est un) : ajouter une valeur retire l'ancienne dans le même groupe ;
- **à plusieurs valeurs** (`~many:true`) : la propriété contient un ensemble de valeurs ;
- **unique** (`~unique:true`) : deux choses n'ont jamais la même valeur, ce qui est vérifié sur l'état après chaque
  groupe.

Le writer (le seul thread qui applique les écritures d'une base, un groupe à la fois) impose ces règles aux choses qui
sont des propriétés : une propriété a besoin d'un nom et d'un type ; son type et sa cardinalité ne changent jamais
(déclarez plutôt une autre propriété) ; elle ne peut devenir unique que si aucune valeur n'est partagée par deux
choses ; elle ne peut être supprimée (son nom et son type retirés) qu'une fois que plus rien n'a de valeur pour elle.

## Les groupes : une écriture est une transaction

Une **transaction** est une unité de travail qu'une base de données applique tout entière ou pas du tout. Dans Cepheus,
une écriture est un **groupe** : une liste d'opérations appliquées **atomiquement** (tout ou rien), avec qui l'a écrite
(`~by`, un nombre que l'application choisit, 0 par défaut) et pourquoi (`~why`, un texte, vide par défaut). Le writer
donne à chaque groupe le numéro suivant (1, 2, 3, ... sans trou) et l'heure de l'horloge de la base, et le résout en
**changements** : des ajouts et des retraits de faits exacts. Le **journal**, un fichier auquel la base ne fait jamais
qu'ajouter, garde ces changements ; rejouer le journal les applique de nouveau et ne recalcule jamais rien.

- `Add (thing, property, value)` : sur une propriété à une valeur, retire aussi la valeur qu'avait la chose ;
- `Retract (thing, property, value)` ;
- `Expect (thing, property, Some value)` : le groupe échoue avec `Conflict` sauf si le fait est vrai avant le groupe ;
  `Expect (thing, property, None)` : sauf si la chose n'a aucune valeur pour la propriété. Chaque `Expect` d'un groupe
  est vérifié sur l'état juste avant le groupe, où qu'il se trouve dans la liste.
- `Incr (thing, property, by, into)` : un compteur que le groupe incrémente. La valeur de la chose pour une propriété
  `Int` à une valeur (aucune valeur compte pour 0) grandit de `by`, lue par le writer à ce point du groupe, et `into = Some (thing',
  property')` ajoute aussi la nouvelle valeur à cet endroit ; il se résout dans les changements que ferait un `Add` de
  la nouvelle valeur. Des groupes qui incrémentent un même compteur au même moment ne sont jamais en conflit : chacun
  lit ce qu'a laissé le groupe d'avant lui.

Un nombre négatif à la place d'une chose ou dans un `Link` est une **nouvelle chose** de ce groupe : `-1`, `-2`, ...
reçoivent les numéros de chose suivants dans l'ordre de leur première apparition, et le reçu dit lesquels
(`thing receipt (-1)`). Un `Add` d'un fait déjà vrai, ou un `Retract` d'un fait qui ne l'est pas, ne change rien ; un
groupe dont les opérations ne changent rien prend quand même un numéro.

Rien n'est effacé : un retrait est un changement d'un groupe ultérieur, et le journal garde tous les groupes. Ici, le
journal d'une base fermée, lu avec la fonction interne `Journal.read`, montre un renommage tel que le writer l'a
résolu :

```ocaml
open Cepheus

let () =
  let db = Result.get_ok (open_ "shop") in
  let[@warning "-8"] (Ok [ name ]) = declare db [ prop "client/name" Ttext ] in
  let ada = thing (Result.get_ok (write db ~by:7 ~why:"signup" [ Add (-1, name, Text "Ada Martin") ])) (-1) in
  ignore (write db ~by:7 ~why:"rename" [ Add (ada, name, Text "Ada Durand") ]);
  close db;
  let id = Engine.read_meta Disk.real "shop" in
  Journal.read Disk.real "shop/journal" id (fun (g : Group.t) ->
      if g.n >= 3 then begin
        Printf.printf "group %d, by %d, %S:" g.n g.by g.why;
        Array.iter
          (fun (c : Group.change) -> Printf.printf " %s(#%d %d %s)" (if Group.present c then "+" else "-") c.e c.p (Value.to_string c.v))
          g.changes;
        print_newline ()
      end)
```

```output
group 3, by 7, "signup": +(#65536 16 "Ada Martin")
group 4, by 7, "rename": -(#65536 16 "Ada Martin") +(#65536 16 "Ada Durand")
```

Qui, quand et pourquoi sont gardés avec chaque groupe dans le journal ; ce ne sont pas des faits des vues (une question
ne peut pas encore demander « qu'a changé 7 hier »).

## Les vues

Une **vue** est l'état exact après un groupe : chaque fait que les groupes 1 à n ont laissé vrai, et rien des groupes
après n. Elle ne change jamais une fois prise, en prendre une ne coûte rien (une lecture atomique), et la lire ne
demande aucun lock (ce qui réserve une donnée à un seul utilisateur et fait attendre les autres), depuis n'importe quel
thread (un fil d'exécution d'un programme) ou domain (dans OCaml 5, un fil d'exécution qui tourne en parallèle des
autres, sur son propre cœur). `view db` est l'état **durable** le plus récent : il ne contient que des groupes dont la
frame du journal (le bloc d'octets qui porte le groupe) est sur le disque. Une vue reste valable tant qu'on la garde,
quel que soit le nombre de groupes qui viennent après elle ; la mémoire qu'elle retient n'est que ce qui diffère des
vues plus récentes (une persistent data structure, une structure dont les anciennes versions restent lisibles après un
changement, [architecture](architecture.md#les-index--les-runs-et-le-delta)).

![Trois groupes d'un client, #65536, côte à côte : le groupe 3 ajoute son nom Ada Martin et sa ville Lyon ; le groupe 4 retire Ada Martin et ajoute Ada Durand ; le groupe 5 retire Lyon et ajoute Paris. Sous chaque groupe, la vue après lui : Ada Martin à Lyon, puis Ada Durand à Lyon, puis Ada Durand à Paris. Un lecteur qui tient la vue au groupe 4 lit toujours Lyon pendant que le groupe 5 s'écrit.](images/groups-views.svg)

## L'isolation : exactement ce que voient un lecteur et un writer

L'**isolation** dit ce qu'une transaction peut voir des autres qui tournent en même temps. Les niveaux standard, du plus
faible au plus fort : read committed (chaque lecture voit les données validées, committed, au moment où elle
s'exécute), **snapshot isolation** (chaque lecture d'une transaction voit le snapshot, l'état figé pris à son début, et
une transaction échoue si une autre a écrit la même donnée après ce début : « first committer wins », le premier qui
valide gagne), **serializable** (le résultat est celui d'une exécution des transactions une par une, dans un certain
ordre), et **strict serializability** (serializable dans un ordre qui respecte aussi le temps réel : une transaction
finie avant qu'une autre commence passe en premier). Cepheus donne exactement ceci :

1. **Les groupes sont strictly serializable** (G4). Un seul writer par base applique les groupes un par un, chacun sur
   l'état laissé par le précédent, dans l'ordre de leurs numéros, et un numéro est donné quand le writer prend le
   groupe, après que le client l'a soumis. Les seules lectures d'un groupe sont ses `Expect`, vérifiés sur l'état le
   plus récent au moment où il est appliqué.
2. **Une vue est un snapshot d'un préfixe validé** (G5). Chaque lecture d'une vue voit l'état après le groupe n, tout
   entier : aucune lecture ne voit la moitié d'un groupe, deux lectures de la même vue ne se contredisent jamais (pas
   de non-repeatable read, une lecture répétée qui donne un autre résultat ; pas de phantom, une ligne qui apparaît
   entre deux lectures, dans une vue), et une lecture n'attend jamais une écriture ni ne la fait attendre. Les
   `view db` successifs d'un thread ne reculent jamais ; après que `write` a renvoyé `Ok` pour le groupe n, chaque vue
   prise ensuite contient n (read your writes : on lit ses propres écritures).
3. **Un read-then-write (lire une vue, puis écrire un groupe) n'est validé que par ses `Expect`.** C'est
   l'optimistic concurrency control (le contrôle optimiste de la concurrence) : lire sans locks, et laisser le writer
   vérifier à la fin que ce qui a été lu est toujours vrai. Si le groupe énonce avec `Expect` chaque fait sur lequel il
   s'est appuyé (`Some v`) et chaque absence sur laquelle il s'est appuyé (`None`), tout le read-then-write est
   serializable. Ce qui n'est pas énoncé n'est pas vérifié :
   - un **lost update** (une mise à jour perdue) : deux clients lisent un solde de 100 et chacun écrit 100 + x sans
     `Expect` ; les deux groupes réussissent et l'une des additions est perdue. La snapshot isolation refuserait le
     second (first committer wins) ; Cepheus ne le refuse pas, parce qu'un `Add` sur une propriété à une valeur
     remplace la valeur qui est là, quelle qu'elle soit ;
   - un **phantom** : la réponse d'une question est un ensemble (les factures d'un client), et un `Expect` nomme un
     seul fait, donc un nouveau fait qui correspond, écrit entre-temps, n'est pas vu. Pour protéger un ensemble, gardez
     un fait que chaque programme qui écrit dans l'ensemble attend et change, comme un numéro de version sur le client
     (la technique « materialize the conflict », matérialiser le conflit, de Fekete et al. 2005).

Le cas classique que la snapshot isolation laisse passer, le **write skew** (deux transactions lisent les mêmes données
et écrivent chacune une donnée différente) : deux médecins sont de garde, et chacun quitte la garde si l'autre reste.
Sous snapshot isolation (le SERIALIZABLE d'Oracle, le REPEATABLE READ de PostgreSQL), les deux transactions voient deux
médecins de garde, écrivent des lignes différentes, et valident toutes les deux : plus personne n'est de garde. Dans
Cepheus, chacun écrit son changement avec un `Expect` sur le fait de l'autre ; le writer en applique un, et l'`Expect`
de l'autre n'est plus vrai :

```ocaml
open Cepheus

let () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ on_call ]) = declare db [ prop "doctor/on-call" Tbool ] in
  let r = Result.get_ok (write db [ Add (-1, on_call, Bool true); Add (-2, on_call, Bool true) ]) in
  let alice = thing r (-1) and bob = thing r (-2) in
  let off me other = write db ~by:me [ Expect (other, on_call, Some (Bool true)); Add (me, on_call, Bool false) ] in
  let show = function Ok r -> Printf.printf "group %d\n" r.group | Error e -> print_endline (message e) in
  show (off alice bob);
  show (off bob alice)
```

```output
group 4
conflict: #65536 does not have true for doctor/on-call (property 16)
```

## Les questions

Une **question** est une **conjunctive query** (une requête faite de conditions qui doivent être vraies toutes à la
fois) : une liste de **patterns** `(thing, property, value)` où la chose et la valeur sont soit des constantes, soit
des **variables**, numérotées à partir de 0. La réponse est chaque **binding** (une valeur pour chaque variable) qui
fait de chaque pattern un fait de la vue, chaque binding une seule fois (G11). Une variable à la place d'une chose est
un lien ; le type d'une variable vient des propriétés avec lesquelles elle apparaît. `ranges` restreint à
`lo <= x <= hi` une variable dont les valeurs sont des nombres (un entier, une date, un montant, un booléen vu comme 0
et 1, un lien vu comme son numéro de chose, un float dans le totalOrder de IEEE 754). À côté de ses patterns, une
question peut tenir des conditions (`Not`, `Or`, `In`, `Prefix`, `Less` entre deux variables) et des patterns
`Optional`, dont la variable est **missing** (absente) dans une ligne où la chose n'a pas de valeur de la propriété,
comme le `LEFT JOIN` de SQL donne un NULL ([Cepheus depuis Cesia](cesia.md#less-lessorequal-et-optional)).

Répondre à une telle question, c'est faire le **join** des patterns (la jointure) : faire correspondre leurs variables
communes. Cepheus utilise un seul algorithme de join, **Generic Join**, qui lie une variable à la fois et, pour
chacune, n'énumère que le plus petit ensemble de candidats qu'offre un pattern, puis vérifie chacun d'eux contre les
autres patterns. Il est **worst-case optimal** (optimal dans le pire cas) : son travail est borné par la plus grande
réponse que la question pourrait avoir sur des données de cette taille (l'AGM bound), même pour des patterns cycliques
comme les triangles, où un plan de joins deux à deux peut construire bien plus de lignes intermédiaires que la réponse
([architecture](architecture.md#questions), [théorie](theory.md#4-generic-join)).

```ocaml
open Cepheus

let () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ city; client; status; total ]) =
    declare db [ prop "client/city" Ttext; prop "invoice/client" Tlink; prop "invoice/status" Ttext; prop "invoice/total" (Tmoney 2) ]
  in
  let r = Result.get_ok (write db [ Add (-1, city, Text "Lyon"); Add (-2, city, Text "Paris") ]) in
  let lyon = thing r (-1) and paris = thing r (-2) in
  List.iter
    (fun (c, s, t) -> ignore (write db [ Add (-1, client, Link c); Add (-1, status, Text s); Add (-1, total, Money t) ]))
    [ lyon, "unpaid", 12000; lyon, "paid", 5000; paris, "unpaid", 7000; lyon, "unpaid", 3000 ];
  (* the unpaid invoices of the clients of Lyon, and their totals: variables 0 client, 1 invoice, 2 total *)
  let q =
    { vars = 3; ranges = [];
      where = [ { e = Var 0; p = city; v = Val (Text "Lyon") }; { e = Var 1; p = client; v = Var 0 };
                { e = Var 1; p = status; v = Val (Text "unpaid") }; { e = Var 1; p = total; v = Var 2 } ] }
  in
  let v = view db in
  (match find v q with
   | Ok rows -> List.iter (fun r -> Printf.printf "%s %s\n" (Value.to_string r.(1)) (Value.to_string r.(2))) (List.sort compare rows)
   | Error e -> print_endline (message e));
  (* the same question folded into a sum, with no value built: a money word is the amount itself *)
  match fold v q ~init:(fun () -> 0) ~step:(fun s w -> s + w.(2)) ~merge:( + ) with
  | Ok s -> Printf.printf "sum %d\n" s
  | Error e -> print_endline (message e)
```

```output
#65538 money 12000
#65541 money 3000
sum 15000
```

![À gauche, les 14 faits de la vue, un par ligne (chose, propriété, valeur) ; à droite, les 4 motifs de la question avec le nombre de faits que chacun touche seul, et ses 2 réponses. Un numéro à côté d'un fait nomme les réponses qui l'utilisent : la ville de Lyon sert les deux, les 3 faits de la facture 65538 la réponse 1, ceux de la facture 65541 la réponse 2 ; la facture payée et celles de Paris touchent des motifs, pas tous.](images/facts-question.svg)

## Les forks

Un **fork** est un état temporaire qui part d'une vue : on y écrit avec le même `write`, sous les mêmes vérifications
(la même fonction résout ses groupes), et rien de ce qu'il fait n'atteint le journal ni aucun fichier (G8). En faire un
ne copie rien, sauf, pour un fork d'un fork, un bit par chose que le parent a touchée : une vue est une valeur
persistante, et les écritures du fork font de nouvelles versions à côté d'elle (structural sharing, le partage de
structure : la nouvelle version partage avec l'ancienne chaque partie qu'elle n'a pas changée). `fork empty` est une
base vide pour un test unitaire ; un fork d'un fork marche ; un fork n'est jamais fusionné en retour (pour garder ce qui
a été essayé, écrivez les mêmes opérations dans la base : une seule façon d'écrire).

```ocaml
open Cepheus

let () =
  let db = Result.get_ok (open_ "shop") in
  let[@warning "-8"] (Ok [ status ]) = declare db [ prop "invoice/status" Ttext ] in
  let inv = thing (Result.get_ok (write db [ Add (-1, status, Text "unpaid") ])) (-1) in
  let t = fork (view db) in
  ignore (write t [ Add (inv, status, Text "paid") ]);
  let show v = Value.to_string (List.hd (values v inv status)) in
  Printf.printf "fork: %s, database: %s\n" (show (view t)) (show (view db));
  close db
```

```output
fork: "paid", database: "unpaid"
```

## Les bases de données

Une base de données est un répertoire : son journal, ses runs (des copies triées de l'état, en niveaux, qui épargnent à
un redémarrage la plus grande partie du journal), et un lock. Un seul processus à la fois l'ouvre (G9) ; une autre
ouverture reçoit `Busy`. Un serveur peut tenir beaucoup de bases ; ce à quoi sert une base (une application, un client,
un jeu de données) est le choix de l'application. Une question lit une seule base.

```ocaml
open Cepheus

let () =
  let db = Result.get_ok (open_ "shop") in
  (match open_ "shop" with Ok _ -> print_endline "opened twice" | Error e -> print_endline (message e));
  close db
```

```output
busy: shop is open in another process
```

## Pour aller plus loin

- Le modèle : Weiss, Karras, Bernstein, Hexastore (PVLDB 2008) et Neumann, Weikum, RDF-3X (PVLDB 2008) pour les
  triplets et leurs index ; la documentation de Datomic pour les datoms et les valeurs de base de données (database
  values).
- L'isolation : Berenson et al., "A Critique of ANSI SQL Isolation Levels" (SIGMOD 1995) ; la thèse d'Adya (MIT
  1999) ; Fekete et al., "Making Snapshot Isolation Serializable" (TODS 2005) ; Kung et Robinson, "On Optimistic
  Methods for Concurrency Control" (TODS 1981) ; Herlihy et Wing, "Linearizability" (TOPLAS 1990).
- Les joins : Ngo, Ré, Rudra, "Skew Strikes Back" (SIGMOD Record 2013) ; Atserias, Grohe, Marx (FOCS 2008).
- Les forks : Driscoll et al., "Making Data Structures Persistent" (JCSS 1989) ; Okasaki, "Purely Functional Data
  Structures" (1998).

Les entrées complètes, avec leurs liens : [références](references.md).
