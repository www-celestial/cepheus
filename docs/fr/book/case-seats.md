# Un cas : ne jamais vendre deux fois la même place

Une salle de concert vend ses places en ligne. Beaucoup de gens achètent au même moment, et la machine qui fait
tourner la vente peut tomber en panne à tout instant. Ce chapitre prend ce problème depuis son énoncé jusqu'à la
preuve qu'il est résolu, pas à pas, avec les méthodes qu'emploient les chercheurs : énoncer la propriété qu'on peut
vérifier, mesurer avant de rien changer, formuler une hypothèse qu'une expérience pourrait réfuter, chercher le
résultat qui résout déjà ce genre de problème, écrire la plus petite solution, puis la prouver sur chaque côté qui
s'applique (un test qui échoue avant et passe après, des entrées générées, un modèle formel vérifié par une machine, de
vrais crashs, un vérificateur de tout l'historique, et la vitesse à côté des bases de données établies), et dire ce
qui pourrait rendre la preuve fausse et ce qui reste à faire. Chaque bloc d'OCaml ci-dessous est un programme entier
que lance le test de la documentation ; la sortie montrée sous un bloc est ce qu'il affiche. Les mots sont expliqués là
où ils apparaissent pour la première fois, et dans le [glossaire](glossary.md) ; les travaux cités sont dans les
[références](references.md).

## 1. Le problème, énoncé avec précision

La première règle de Pólya pour résoudre un problème est de le comprendre : quelle est l'inconnue, quelles sont les
données, quelle est la condition ([Pólya 1945]). Le catéchisme de Heilmeier, à la DARPA, demande la même chose d'un
projet de recherche, en mots simples : qu'essayez-vous de faire, comment le fait-on aujourd'hui, qu'est-ce qui est
nouveau, et comment saurez-vous que vous avez réussi (\[Heilmeier]). Ici :

- **Qui a ce problème** : quiconque vend un stock limité à beaucoup de gens à la fois : des places, des billets, des
  chambres, des rendez-vous.
- **Ce qu'on fait aujourd'hui, et ce qui ne va pas** : l'écran d'un acheteur montre les places libres ; l'acheteur en
  clique une ; le programme vérifie que la place est libre et enregistre la vente. Deux acheteurs qui voient la même
  place libre et la cliquent au même moment peuvent tous les deux s'entendre dire « vendu ».
- **Ce que « résolu » veut dire**, sous forme de propriétés qu'un programme peut vérifier sur tout état et toute
  history (l'historique de la base) :
  1. *pas de double vente* : chaque place a au plus une vente (un débit) ;
  2. *pas de débit sans la place* : chaque acheteur débité pour une place possède cette place ;
  3. *durable* : une vente annoncée à l'acheteur (confirmée) n'est jamais perdue, quels que soient les crashs qui
     suivent ;
  4. et la vente doit rester rapide avec beaucoup d'acheteurs à la fois (mesuré à la section 6).
- **Hors du sujet** : le paiement lui-même (le côté de la banque), les acheteurs qui changent d'avis (un remboursement
  est un autre groupe), plusieurs machines (ici, un seul serveur prend les écritures).

Le modèle de données, en faits de Cepheus (chose, propriété, valeur) : une place est une chose avec un `seat/number` ;
son propriétaire est une propriété à une seule valeur, `seat/owner` (le numéro de l'acheteur) ; un débit est une chose
avec `charge/seat` (un lien vers la place) et `charge/buyer`. Une vente est un seul groupe (une transaction,
[concepts](concepts.md#les-groupes--une-écriture-est-une-transaction)) : le propriétaire de la place et le débit ensemble,
tout ou rien (G2) ; la propriété 2 ne peut donc pas casser par une moitié de vente.

## 2. Mesurer avant de rien changer

Avant de rien changer, mesurer ce qui se passe aujourd'hui : une **baseline** (la mesure de référence), le chiffre
auquel la solution sera comparée. Les règles de Jain pour une expérience ([Jain 1991]) demandent d'écrire d'abord la
charge, la métrique et les facteurs ; Georges, Buytaert et Eeckhout ([Georges 2007]) et Kalibera et Jones
([Kalibera 2013]) demandent plusieurs exécutions et un intervalle de confiance plutôt qu'un seul chiffre, parce qu'une
seule exécution d'un programme concurrent est un tirage parmi beaucoup d'autres.

La vente naïve, telle que la décrit la section 1 : un acheteur prend une vue (l'état après un groupe, lu sans lock),
choisit au hasard l'une des dix meilleures places libres qu'elle montre, et écrit le propriétaire et le débit.
`test/seats.exe DIR 0 SEED naive 2000`, avec `BUYERS` threads, la fait tourner : les acheteurs, des threads d'un même
processus, vendent une salle de 2 000 places sur le vrai disque jusqu'à ce que la salle soit pleine, chaque vente étant
durable quand elle est confirmée ; puis un vérificateur lit tout l'historique et compte ce qui s'est mal passé (la
section 6 le décrit). La méthode des [benchmarks](benchmarks.md#méthode) : sous le lock partagé qui tient les autres
travaux lourds à l'écart de la machine, chaque processus dans une limite de mémoire de 3 GB, 5 exécutions par
configuration, la médiane et l'intervalle entre la plus petite et la plus grande exécution (avec 5 exécutions, il
couvre la vraie médiane avec une probabilité de 93,8 % : un intervalle de statistiques d'ordre, qui ne suppose rien de
la distribution).

| acheteurs | places vendues plus d'une fois | ventes en trop (débits au-delà d'un par place) | acheteurs débités sans la place | temps pour tout vendre |
|---:|---:|---:|---:|---:|
| 2 | 199 [191 ; 227] | 199 [191 ; 227] | 199 [191 ; 227] | 9,8 s [6,6 ; 17,3] |
| 4 | 426 [413 ; 440] | 463 [455 ; 471] | 463 [455 ; 471] | 6,8 s [4,2 ; 13,8] |
| 16 | 1 334 [1 301 ; 1 346] | 2 199 [2 132 ; 2 209] | 2 199 [2 132 ; 2 209] | 1,9 s [1,7 ; 9,3] |

La vente naïve vend donc des places deux fois à chaque exécution, et d'autant plus qu'il y a d'acheteurs : avec 16
acheteurs, deux places sur trois vont à plusieurs acheteurs, et chaque vente en trop est un acheteur débité pour une
place qu'un autre possède. Aucun crash n'est nécessaire pour cela. Les temps varient d'un facteur 2 à 5 entre les
exécutions : ce sont ceux du disque (une vente attend son fsync, l'appel système qui attend que les octets écrits
soient vraiment sur le disque), sur une machine que d'autres travaux utilisaient.

## 3. Une hypothèse qu'on peut réfuter, et sa cause

Une hypothèse est utile quand une expérience pourrait la réfuter (une hypothèse **falsifiable**). La nôtre : *les
doubles ventes viennent de l'écart entre la lecture et l'écriture, pas du disque, des threads, des crashs ni des merges
du moteur*. L'expérience qui pourrait la réfuter : rendre le cas qui échoue aussi petit que possible, comme le fait le
delta debugging pour une entrée qui fait échouer un programme ([Zeller 2002]), en retirant acheteurs, places, threads
et disque tant que l'échec reste. Si l'hypothèse était fausse, l'échec disparaîtrait avec le disque ou les threads. Ce
qui reste, c'est deux acheteurs, une place, une vue, aucun thread et aucun disque (un fork, un état temporaire où l'on
écrit sans rien écrire sur le disque, [concepts](concepts.md#les-forks)), et cela échoue encore :

```ocaml
open Cepheus

let () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ number; owner; seat_of; buyer_of ]) =
    declare db [ prop "seat/number" Tint; prop "seat/owner" Tint; prop "charge/seat" Tlink; prop "charge/buyer" Tint ]
  in
  let seat = thing (Result.get_ok (write db [ Add (-1, number, Int 1) ])) (-1) in
  (* the naive sale: if the seat is free in the view the buyer read, write the owner and the charge *)
  let buy buyer v =
    if values v seat owner <> [] then Printf.printf "buyer %d: taken\n" buyer
    else
      match write db [ Add (seat, owner, Int buyer); Add (-1, seat_of, Link seat); Add (-1, buyer_of, Int buyer) ] with
      | Ok r -> Printf.printf "buyer %d: sold, group %d\n" buyer r.group
      | Error e -> Printf.printf "buyer %d: %s\n" buyer (message e)
  in
  let v = view db in
  (* both buyers read the same view, in which the seat is free *)
  buy 1 v;
  buy 2 v;
  let now = view db in
  Printf.printf "owner of seat 1: %s; charges for it: %d\n"
    (String.concat ", " (List.map Value.to_string (values now seat owner)))
    (List.length (things now seat_of (Link seat)))
```

```output
buyer 1: sold, group 4
buyer 2: sold, group 5
owner of seat 1: 2; charges for it: 2
```

L'hypothèse résiste au test : deux acheteurs et une vue partagée suffisent, et l'acheteur 1 est débité pour une place
que possède l'acheteur 2. Son nom dans la littérature est le **lost update** (la mise à jour perdue, [Berenson 1995],
phénomène P4) : deux transactions lisent le même élément, et chacune écrit une valeur calculée d'après ce qu'elle a
lu ; la seconde écriture remplace la première, qui est perdue. Ici, l'élément est le propriétaire de la place, et le
second `Add` de la propriété à une seule valeur a remplacé le premier propriétaire (le journal enregistre le retrait).
Son cousin est le **write skew** (le A5B de Berenson) : deux transactions lisent les mêmes éléments et chacune en écrit
un différent, cassant ensemble une règle que chacune respectait seule (deux médecins qui quittent chacun leur garde
parce que l'autre est de garde,
[concepts](concepts.md#lisolation--exactement-ce-que-voient-un-lecteur-et-un-writer)). Une règle sur plusieurs places,
comme quatre places au plus par acheteur, serait cassée par le write skew ; la section 7 y revient.

La cause, précisément : chaque groupe est appliqué seul et dans l'ordre (G4), mais la lecture de l'acheteur a eu lieu
hors du groupe, dans une vue prise plus tôt. Rien n'a dit au writer (le seul thread qui applique les groupes, un à la
fois) ce que l'acheteur avait lu ; rien ne l'a donc vérifié.

## 4. La recherche : ce qui résout ce genre de problème

- **Serializability** (Papadimitriou, [Papadimitriou 1979]) : un ensemble de transactions exécutées en même temps est
  correct si son résultat est égal au résultat de leur exécution une à une dans un certain ordre. Un read-then-write
  (lire, puis écrire selon ce qu'on a lu) est une seule transaction : la lecture et l'écriture ensemble. La vente naïve
  n'est pas serializable : dans n'importe quel ordre des deux ventes une à une, le second acheteur aurait vu la place
  prise.
- **Strict serializability**, et **linearizability** pour un seul objet (Herlihy et Wing, [Herlihy 1990]) : l'ordre
  doit aussi respecter le temps réel (une vente confirmée avant qu'une autre commence passe en premier). Les groupes de
  Cepheus sont strictly serializable (G4) : ce qui manque, c'est de mettre la lecture dans le groupe.
- **Les niveaux d'isolation et leurs anomalies** (Berenson et al., [Berenson 1995] ; Adya, [Adya 1999]) : sous *read
  committed*, le défaut de PostgreSQL et d'Oracle, le lost update se produit comme ci-dessus ; *snapshot isolation*
  (chaque transaction lit l'état figé de son début) l'arrête quand les deux transactions écrivent le même élément
  (« first committer wins », le premier qui confirme gagne) mais laisse passer le write skew ; *serializable* arrête
  les deux. Adya définit les anomalies sur un graphe des dépendances entre transactions, que la section 6 vérifie.
- **Comment fait PostgreSQL** (Cahill, Röhm et Fekete, [Cahill 2008] ; Ports et Grittner, [Ports 2012]) : son niveau
  SERIALIZABLE est la *serializable snapshot isolation* : chaque transaction lit un snapshot, et le serveur suit
  quelles transactions ont lu ce que d'autres ont écrit ; un motif de deux tels conflits lecture-écriture à la suite
  fait avorter l'une d'elles, et l'application doit la retenter (« serialization failure »).
- **Comment fait SQLite** ([SQLite isolation](https://www.sqlite.org/isolation.html)) : un seul writer à la fois pour
  toute la base ; `BEGIN IMMEDIATE` prend le lock d'écriture au début de la transaction, donc la lecture et l'écriture
  d'une vente ont lieu sans autre writer entre elles ; « transactions in SQLite are SERIALIZABLE ».
- **Optimistic concurrency control** (le contrôle de concurrence optimiste, Kung et Robinson, [Kung 1981]) : lire sans
  locks, et à la fin valider que ce qui a été lu tient toujours ; sinon, avorter et réessayer. Aucun lock n'est tenu
  pendant qu'un acheteur regarde le plan de la salle.

Ce qui s'applique ici : Cepheus applique déjà les groupes un à la fois sur l'état le plus récent ; un `Expect` dans le
groupe déclare ce que l'acheteur a lu, et le writer le valide sur cet état le plus récent (validation optimiste, Kung
et Robinson). Avec la lecture dans le groupe, la vente est une seule transaction strictly serializable.

## 5. La plus petite solution

Une ligne : le groupe dit que la place n'a pas de propriétaire, `Expect (seat, owner, None)`. Le writer le vérifie sur
l'état le plus récent, après chaque groupe d'avant ; si un autre acheteur a pris la place depuis la vue, le groupe est
refusé avec `Conflict`, rien n'est écrit, et l'acheteur lit une nouvelle vue et choisit à nouveau.

```ocaml
open Cepheus

let () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ number; owner; seat_of; buyer_of ]) =
    declare db [ prop "seat/number" Tint; prop "seat/owner" Tint; prop "charge/seat" Tlink; prop "charge/buyer" Tint ]
  in
  let seat = thing (Result.get_ok (write db [ Add (-1, number, Int 1) ])) (-1) in
  (* the sale states what the buyer read: the seat has no owner *)
  let buy buyer v =
    if values v seat owner <> [] then Printf.printf "buyer %d: taken\n" buyer
    else
      match
        write db
          [ Expect (seat, owner, None); Add (seat, owner, Int buyer); Add (-1, seat_of, Link seat); Add (-1, buyer_of, Int buyer) ]
      with
      | Ok r -> Printf.printf "buyer %d: sold, group %d\n" buyer r.group
      | Error e -> Printf.printf "buyer %d: %s\n" buyer (message e)
  in
  let v = view db in
  buy 1 v;
  buy 2 v;
  let now = view db in
  Printf.printf "owner of seat 1: %s; charges for it: %d\n"
    (String.concat ", " (List.map Value.to_string (values now seat owner)))
    (List.length (things now seat_of (Link seat)))
```

```output
buyer 1: sold, group 4
buyer 2: conflict: #65536 has a value for seat/owner (property 17)
owner of seat 1: 1; charges for it: 1
```

C'est le cas qui échouait à la section 3, avec une opération de plus : avant, l'acheteur 2 se voyait vendre une place
qui n'était plus là ; maintenant, on le lui dit, et rien de sa vente n'est écrit. Une vraie boucle d'acheteur prend une
nouvelle vue sur `Conflict` et choisit à nouveau (`test/seats.ml`, fonction `child`).

## 6. La preuve que c'est résolu

### Correction, sur des entrées générées

Les deux programmes ci-dessus sont le test qui échoue avant et passe après. Un seul cas prouve peu ; la même
vérification tourne donc sur beaucoup de cas générés, comme le fait QuickCheck ([Claessen 2000]) : un nombre
d'acheteurs au hasard (2 à 6) et de places (1 à 4), et un **schedule** au hasard (un ordonnancement : l'ordre dans
lequel s'entrelacent les étapes des acheteurs, lire une vue puis écrire). Pour chaque schedule, la vente naïve et la
vente avec `Expect` tournent sur des forks, et les deux propriétés sont vérifiées sur l'état final.

```ocaml
open Cepheus

let () =
  let r = Rng.make 2026 in
  let broken = [| 0; 0 |] in
  for _ = 1 to 1000 do
    let nb = 2 + Rng.int r 5 and ns = 1 + Rng.int r 4 in
    (* a schedule: each buyer appears twice, shuffled; its first step reads a view, its second writes *)
    let steps = Array.init (2 * nb) (fun i -> i / 2) in
    for i = Array.length steps - 1 downto 1 do
      let j = Rng.int r (i + 1) in
      let x = steps.(i) in
      steps.(i) <- steps.(j);
      steps.(j) <- x
    done;
    (* the same schedule, run with the naive sale and with the Expect *)
    List.iteri
      (fun mode expect ->
        let db = fork empty in
        let[@warning "-8"] (Ok [ number; owner; seat_of; buyer_of ]) =
          declare db [ prop "seat/number" Tint; prop "seat/owner" Tint; prop "charge/seat" Tlink; prop "charge/buyer" Tint ]
        in
        let made = Result.get_ok (write db (List.init ns (fun k -> Add (-(k + 1), number, Int (k + 1))))) in
        let seats = List.init ns (fun k -> thing made (-(k + 1))) in
        let read = Array.make nb false and picked = Array.make nb None in
        Array.iter
          (fun b ->
            if not read.(b) then begin
              (* the best free seat in the view *)
              let v = view db in
              read.(b) <- true;
              picked.(b) <- List.find_opt (fun s -> values v s owner = []) seats
            end
            else
              match picked.(b) with
              | Some s ->
                let check = if expect then [ Expect (s, owner, None) ] else [] in
                ignore (write db (check @ [ Add (s, owner, Int b); Add (-1, seat_of, Link s); Add (-1, buyer_of, Int b) ]))
              | None -> ())
          steps;
        let v = view db in
        let bad s =
          let charges = things v seat_of (Link s) in
          List.length charges > 1 || List.exists (fun c -> values v c buyer_of <> values v s owner) charges
        in
        if List.exists bad seats then broken.(mode) <- broken.(mode) + 1)
      [ false; true ]
  done;
  Printf.printf "naive: %d of 1000 schedules sell a seat twice or charge without the seat\n" broken.(0);
  Printf.printf "with Expect: %d of 1000\n" broken.(1)
```

```output
naive: 881 of 1000 schedules sell a seat twice or charge without the seat
with Expect: 0 of 1000
```

### Un modèle formel, vérifié par une machine

Les tests essaient les schedules que tire un générateur ; un **model checker** les essaie tous, dans des bornes.
`spec/Seats.tla` est un modèle de la vente en TLA+ ([Lamport 2002]), un langage pour décrire un système et ses états,
celui que les ingénieurs d'Amazon ont utilisé pour trouver des bugs de conception subtils que leurs tests avaient
manqués ([Newcombe 2015]) : des acheteurs qui prennent une vue et y choisissent une place libre (`Read`), des groupes
que le writer applique un à la fois sur l'état le plus récent (`Write`, avec ou sans l'`Expect`), et des crashs qui
perdent les vues des acheteurs mais aucun groupe confirmé (`Crash`, comme le dit G1). Ses invariants sont les
propriétés de la section 1 : `NoDoubleSale` et `NoChargeWithoutSeat`. TLC, le model checker de TLA+, explore chaque
état atteignable (`tools/tlc.sh`).

Avec la vente naïve (`spec/SeatsNaive.cfg`, `Naive = TRUE`, 3 acheteurs et 2 places), TLC s'arrête au premier état
qui casse un invariant, après 116 états distincts, et affiche le plus court chemin qui y mène, qui est le cas de la
section 3 trouvé par la machine (deux acheteurs lisent la même place libre, les deux écrivent) :

```text
Error: Invariant NoDoubleSale is violated.
State 1: <Initial predicate>
/\ owner = (s1 :> None @@ s2 :> None)
/\ sales = {}
/\ pc = (b1 :> "looking" @@ b2 :> "looking" @@ b3 :> "looking")
/\ pick = (b1 :> None @@ b2 :> None @@ b3 :> None)
State 2: <Read line 30, col 3 to line 35, col 31 of module Seats>
/\ owner = (s1 :> None @@ s2 :> None)
/\ sales = {}
/\ pc = (b1 :> "read" @@ b2 :> "looking" @@ b3 :> "looking")
/\ pick = (b1 :> s1 @@ b2 :> None @@ b3 :> None)
State 3: <Read line 30, col 3 to line 35, col 31 of module Seats>
/\ owner = (s1 :> None @@ s2 :> None)
/\ sales = {}
/\ pc = (b1 :> "read" @@ b2 :> "read" @@ b3 :> "looking")
/\ pick = (b1 :> s1 @@ b2 :> s1 @@ b3 :> None)
State 4: <Write line 40, col 3 to line 48, col 19 of module Seats>
/\ owner = (s1 :> b1 @@ s2 :> None)
/\ sales = {<<b1, s1>>}
/\ pc = (b1 :> "served" @@ b2 :> "read" @@ b3 :> "looking")
/\ pick = (b1 :> s1 @@ b2 :> s1 @@ b3 :> None)
State 5: <Write line 40, col 3 to line 48, col 19 of module Seats>
/\ owner = (s1 :> b2 @@ s2 :> None)
/\ sales = {<<b1, s1>>, <<b2, s1>>}
/\ pc = (b1 :> "served" @@ b2 :> "served" @@ b3 :> "looking")
/\ pick = (b1 :> s1 @@ b2 :> s1 @@ b3 :> None)
```

Avec l'`Expect` (`spec/Seats.cfg`, 4 acheteurs et 3 places, des crashs à toute étape) : chacun des 8 449 états
atteignables satisfait `TypeOK`, `NoDoubleSale` et `NoChargeWithoutSeat` (52 034 états générés, profondeur 9, en moins
d'une seconde). `tools/tlc.sh` vérifie les deux : le modèle avec `Expect` doit tenir, et le naïf doit échouer (le code
de sortie de TLC pour un invariant cassé, 12), pour montrer que le modèle est capable de voir le bug. Un modèle ne vaut
que son abstraction : il suppose que les groupes sont appliqués un à la fois et sont durables une fois confirmés, ce
que modélisent `spec/Journal.tla` et `spec/Merge.tla` et que prouvent les [garanties](guarantees.md) (G1, G4) ; le
code est testé contre lui par les deux preuves suivantes.

### De vrais crashs, et un vérificateur de tout l'historique

`test/seats.exe DIR ROUNDS` vend une salle de 2 000 places à 16 threads acheteurs dans un processus enfant et le tue
avec `SIGKILL` (`kill -9`) à un moment au hasard, ROUNDS fois, en rouvrant la base après chaque mise à mort et en
lançant un nouvel enfant sur ce qui reste, jusqu'à ce que la salle soit pleine. L'enfant affiche chaque confirmation.
Puis le vérificateur lit le journal, l'historique complet de la base (chaque groupe, dans l'ordre, avec son `why`, où
chaque vente a écrit son acheteur, sa place et le groupe de la vue qu'elle a lue) :

- *durable* : chaque vente confirmée est dans le journal, exactement comme elle a été écrite, et son acheteur possède
  sa place à la fin ;
- *les propriétés* : au plus un débit par place, et l'acheteur de chaque débit possède la place ;
- *serializable*, dans l'esprit d'Elle ([Kingsbury 2020]), le vérificateur que Jepsen emploie sur de vraies bases de
  données : il construit le **dependency graph** (le graphe des dépendances) des ventes (Adya, [Adya 1999]) et y
  cherche un cycle. Chaque place est un registre dont les versions sont ses propriétaires, dans l'ordre des groupes ;
  il y a une arête *ww* d'une vente à la vente suivante qui a écrit la même place, *wr* de la vente dont une autre vente
  a lu le propriétaire vers cette vente, et *rw* (une anti-dependency, une anti-dépendance) d'une vente à la vente qui a
  remplacé la version qu'elle a lue. Chaque arête *ww* et *wr* va vers l'avant dans l'ordre des groupes ; un cycle
  demande donc une arête *rw* qui revient en arrière : une vente qui a lu une version plus ancienne que celle qu'elle a
  remplacée. Un tel cycle est une anomalie qu'aucun ordre en série n'explique (le G2 d'Adya) ; ici, un lost update. Un
  historique sans cycle est serializable.

Trois exécutions de chaque, 20 mises à mort au plus (la vente naïve fait environ deux fois plus de ventes, elle tourne
donc plus longtemps et les subit toutes les 20 ; avec l'`Expect`, la salle est pleine après 8 à 16) :

| | mises à mort | ventes dans le journal (confirmées avant une mise à mort) | places vendues plus d'une fois | débités sans la place | places avec un cycle |
|---|---:|---:|---:|---:|---:|
| avec `Expect` | 16; 8; 11 | 2 000 (1 930); 2 000 (1 967); 2 000 (1 938) | 0 | 0 | 0 |
| naïve | 20; 20; 20 | 4 129 (3 930); 4 138 (3 930); 4 235 (4 079) | 1 291; 1 287; 1 329 | 2 129; 2 138; 2 235 | 1 291; 1 287; 1 329 |

Avec l'`Expect` : chaque place vendue une fois, à l'acheteur à qui on l'a dit ; chaque vente confirmée dans le journal
et dans l'état final, à travers chaque mise à mort (une vente qui est dans le journal mais n'a pas été confirmée est une
vente que l'enfant a écrite et forcée sur le disque, mais il a été tué avant de l'afficher : durable, et correcte) ;
aucun cycle. Sans lui, le vérificateur trouve un cycle exactement sur les places vendues plus d'une fois.

L'exécution naïve est le test du test : le vérificateur doit voir les anomalies quand elles sont là, sinon son silence
sur la vente avec `Expect` ne prouverait rien. `tools/test.sh` fait tourner la vente avec `Expect` et échoue à la
moindre anomalie.

### Une borne

À quelle fréquence la vente naïve devrait-elle échouer ? Un modèle sur un coin de table donne un chiffre à comparer
avec la section 2 : quand $m$ acheteurs lisent la même vue et que chacun choisit au hasard l'une des dix meilleures
places libres, la probabilité que deux choisissent la même est celle du birthday problem (le paradoxe des
anniversaires), $1 - (10 \times 9 \times \dots \times (10 - m + 1)) / 10^m$ : 10 % pour 2 acheteurs, 50 % pour 4, et la certitude pour 16 (plus
d'acheteurs que de places au choix). Les $m$ choix couvrent alors en moyenne $10 (1 - 0{,}9^m)$ places distinctes (chaque place est
manquée par les $m$ avec une probabilité $0{,}9^m$), donc la part de ventes en trop est $1 - (10/m) (1 - 0{,}9^m)$ : 5 % pour 2 acheteurs,
14 % pour 4, 49 % pour 16. Mesuré (le tableau de la section 2) : 199 ventes sur 2 199, 9,0 % ; 463 sur 2 463, 18,8 % ;
2 199 sur 4 199, 52,4 %. Le modèle prédit la croissance et, pour 16 acheteurs, le taux ; il est en dessous pour 2 et 4
acheteurs parce qu'un acheteur entre aussi en collision avec des ventes encore en vol, écrites mais pas encore dans une
vue (une frame en train d'être forcée sur le disque), que le modèle laisse de côté.

Avec l'`Expect`, la borne est exacte : aucune double vente, jamais, sous les conditions de G4 et G1 (un seul writer
applique les groupes dans l'ordre, chaque `Expect` est vérifié sur l'état juste avant son groupe, et un groupe confirmé
est durable).

### La vitesse, à côté des géants

Une solution correcte mais lente ne règle pas une vente. La même vente, jusqu'à la salle pleine, sur la même machine
avec 16 acheteurs, par Cepheus avec `Expect`, SQLite 3.54 avec `BEGIN IMMEDIATE` (WAL, `synchronous = FULL` : une vente
est durable quand elle est confirmée, comme celles de Cepheus), et PostgreSQL 18.6 en SERIALIZABLE, qui retente chaque
serialization failure (pgbench `--max-tries`), et à son défaut READ COMMITTED avec le read-then-write naïf, pour
comparer :

| 2 000 places, 16 acheteurs, 5 exécutions | temps pour tout vendre | ventes par seconde | places vendues plus d'une fois | ce qu'a fait la base |
|---|---:|---:|---:|---|
| Cepheus, `Expect` | **2,30 s [2,01 ; 3,02]** | 871 | 0 | 2 211 [2 128 ; 2 270] ventes refusées (`Conflict`), retentées |
| SQLite 3.54, `BEGIN IMMEDIATE` | 9,84 s [9,44 ; 16,15] | 203 | 0 | un seul writer à la fois |
| PostgreSQL 18.6, SERIALIZABLE | 10,14 s [9,11 ; 13,40] | 197 | 0 | 1 693 [1 669 ; 1 725] transactions retentées |
| SQLite, naïve (la lecture hors de la transaction) | 9,72 s [9,05 ; 11,77] | | 27 ventes en trop [24 ; 60] | |
| PostgreSQL, naïve (READ COMMITTED) | 3,24 s [3,20 ; 4,86] | | 1 387 ventes en trop [1 379 ; 1 443] | |

Cepheus vend tout 4,3 fois plus vite que les deux : son writer met chaque vente qui arrive pendant un fsync dans la
frame suivante (le group commit, plusieurs groupes confirmés par un seul fsync), si bien que les 16 acheteurs se
partagent chaque fsync, là où SQLite force chaque commit seul (un seul writer, un fsync par commit) et où PostgreSQL
refait tourner 1 693 transactions à côté de ses commits. Là où les géants gagnent : la correction du `BEGIN IMMEDIATE`
de SQLite et du SERIALIZABLE de PostgreSQL ne dépend pas du programme. PostgreSQL trouve le conflit tout seul, d'après
ce que chaque transaction a lu (serializable snapshot isolation) ; SQLite ne laisse jamais un autre writer passer
entre les deux. Cepheus ne valide que ce que le groupe déclare : un programme qui oublie l'`Expect` vend des places
deux fois, comme le fait PostgreSQL à son niveau par défaut (1 387 ventes en trop ci-dessus) et comme le fait la propre
vente naïve de Cepheus. La vente naïve de SQLite échoue rarement (27 ventes en trop) parce que son writer unique rend
court l'écart entre la lecture et l'écriture ; elle échoue quand même. Et SQLite fait tout cela dans un seul fichier
sans serveur, PostgreSQL pour n'importe quel langage par son socket et SQL ; Cepheus est une bibliothèque dans un seul
processus OCaml.

Comment chaque côté a tourné : Cepheus par `test/seats.exe` (les threads des acheteurs dans un seul processus, le
temps du premier coup d'œil à la dernière vente) ; SQLite par `bench/sqlite/seats.py` (le `sqlite3` de Python, une
connexion par thread, WAL, `synchronous = FULL`, le même choix parmi les dix meilleures places libres, par un index
partiel des places libres) ; PostgreSQL par `bench/pg/pg.sh seats` (pgbench, 16 clients, les scripts
`bench/pg/seat-serializable.sql` et `seat-naive.sql`, `--max-tries=1000` ; son propre cluster, fsync activé,
`shared_buffers` 1 GB, le temps du départ de pgbench au commit du dernier débit). Chaque côté a alterné avec les
autres au sein d'un tour, 5 tours.

### Menaces sur la validité

Ce qui pourrait rendre cette preuve fausse, et comment chaque point a été écarté (Mytkowicz et al. montrent comment un
changement innocent de l'installation peut changer un résultat mesuré, [Mytkowicz 2009]) :

- *Le vérificateur pourrait être aveugle.* La vente naïve passe par le même vérificateur et les anomalies sont
  trouvées (ci-dessus).
- *Le modèle pourrait faire disparaître le bug par abstraction.* La variante naïve du modèle échoue dans TLC, donc le
  modèle peut voir le bug ; et ses hypothèses (un seul writer, des groupes confirmés durables) sont celles que couvrent
  les propres modèles et tests du moteur.
- *Les crashs pourraient tous tomber à des endroits sans danger.* Les mises à mort tombent à des moments au hasard sur
  des centaines de millisecondes de vente : 8 à 20 mises à mort par exécution, 95 en tout ; chaque exécution avec
  l'`Expect` a fini avec 33 à 70 ventes dans le journal dont aucun acheteur n'avait été informé : des mises à mort sont
  donc tombées pendant que des ventes étaient en vol. La propre énumération exhaustive des états de crash du moteur
  (`test/exhaustive.ml`) couvre chaque point du protocole du journal.
- *L'historique pourrait mentir.* Le vérificateur prend la vue qu'une vente a lue dans le propre `why` de la vente,
  écrit par l'acheteur : un acheteur qui déclarerait mal sa vue tromperait la vérification de serializability (pas les
  comptes de ventes et de débits, qui viennent des faits). Les acheteurs du test écrivent le groupe de la vue qu'ils ont
  lue, et rien d'autre.
- *Les mesures pourraient être du bruit.* Chaque processus a tourné sous le lock qui tient les autres travaux lourds à
  l'écart, les côtés ont alterné, avec des médianes et des intervalles sur plusieurs exécutions ; le disque est un SSD
  grand public dont le temps de fsync varie (un fsync prend 3 ms en médiane, et des blocages de 100 ms et plus arrivent
  quelques fois par minute, [opérations](operations.md#les-disques)).
- *La comparaison pourrait être injuste.* Chaque côté fait la même vente, durable au commit, avec la même politique
  côté client (l'une des dix meilleures places libres) ; PostgreSQL et SQLite passent par leur client habituel (pgbench,
  le `sqlite3` de Python), qui ajoute un coût par instruction que Cepheus, une bibliothèque dans le processus, ne paie
  pas. La vente est bornée par les fsyncs (quelques ms chacun) bien plus que par le coût d'une instruction (des µs),
  donc l'ordre des trois n'en dépend pas.
- *Une machine, une charge.* Une salle de 2 000 places et 2 à 16 acheteurs qui choisissent parmi les dix meilleures
  places ; d'autres mélanges (des milliers d'acheteurs, une seule place très demandée, des acheteurs répartis sur toute
  la salle) ne sont pas mesurés.

## 7. Ce qui reste

- L'`Expect` protège ce qu'il nomme : le propriétaire de la place. Une règle sur un ensemble (pas plus de quatre places
  par acheteur) demande un fait que chaque vente de l'acheteur attend et change, comme un compte des places de
  l'acheteur : la technique « materialize the conflict » (matérialiser le conflit, [Fekete 2005],
  [concepts](concepts.md#lisolation--exactement-ce-que-voient-un-lecteur-et-un-writer)).
- Un acheteur en conflit lit une nouvelle vue et réessaie : sous une forte concurrence pour quelques places, beaucoup
  d'essais sont perdus (2 211 conflits pour 2 000 ventes ci-dessus). Une place tenue une minute pendant que l'acheteur
  paie (une réservation avec une expiration) est la réponse habituelle ; c'est un autre groupe, avec son propre
  `Expect`.
- Une seule machine prend les écritures : si elle est perdue, la vente s'arrête jusqu'à son retour, ou jusqu'à ce
  qu'une [replica](server.md#une-replica) (une copie de la base qui suit le journal du serveur) soit promue à la main
  (les ventes confirmées pendant son retard sont alors perdues) ; un [cluster Raft](server.md#un-cluster-de-trois-raft)
  de trois (un protocole où un groupe n'est confirmé qu'une fois copié sur une majorité de serveurs) ne confirme une
  vente qu'une fois que deux serveurs la tiennent, et élit un autre leader de lui-même.
- Le paiement est hors de la base : une vente confirmée par Cepheus et un paiement refusé par la banque doivent être
  défaits par un autre groupe (une compensation), ce que ce chapitre ne couvre pas.

## Pour aller plus loin

[Pólya 1945] ; \[Heilmeier] ; [Jain 1991] ; [Georges 2007] ; [Kalibera 2013] ; [Zeller 2002] ; [Berenson 1995] ;
[Papadimitriou 1979] ; [Herlihy 1990] ; [Adya 1999] ; [Cahill 2008] ; [Ports 2012] ; [Kung 1981] ; [Fekete 2005] ;
[Claessen 2000] ; [Lamport 2002] ; [Newcombe 2015] ; [Kingsbury 2020] ; [Mytkowicz 2009]. Les entrées, avec leurs liens
et ce que ce chapitre a pris de chacune : [références](references.md).
