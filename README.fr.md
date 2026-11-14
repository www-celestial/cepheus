# Cepheus

Une base de données de faits, en OCaml. Tout ce qu'elle stocke est un **fait** `(thing, property, value)` (chose,
propriété, valeur), le modèle entity–attribute–value que Datomic appelle un datom. Une écriture est un **groupe** de
faits : une transaction, appliquée tout entière ou pas du tout, avec qui et pourquoi ; le groupe est l'événement, et le
journal garde chaque groupe pour toujours. Un lecteur prend une **vue**, l'état exact après un groupe, et la lit sans
aucun lock (ce qui réserve une donnée à un seul utilisateur et fait attendre les autres). Un **fork** est un état
temporaire qui part d'une vue : on y écrit comme dans la base, avec les mêmes vérifications, et rien n'en est jamais
écrit sur le disque ; c'est la base des tests unitaires et des questions « et si ». Les **règles** (Datalog) dérivent
des faits à partir de faits : le writer (le seul thread qui applique les écritures d'une base) tient les faits dérivés
dans chaque vue, comme des faits, à chaque groupe, et `why` donne la preuve de l'un d'eux
([règles](docs/fr/book/rules.md)). OWL 2 RL, les règles d'ontologie du W3C (une ontologie : les classes et les
propriétés d'un domaine, et leurs axiomes), est une bibliothèque de telles règles (`Cepheus.Owl` ; depuis Cesia, le
package `owl`), égalité (owl:sameAs) comprise, tenue par des classes de choses égales dont les faits vivent sur un seul
représentant ([OWL 2 RL](docs/fr/book/rules.md#owl-2-rl-une-bibliothèque-de-règles)).

```ocaml
open Cepheus

let () =
  let db = Result.get_ok (open_ "shop") in
  let[@warning "-8"] (Ok [ name; city ]) = declare db [ prop "client/name" Ttext; prop "client/city" Ttext ] in
  let r = Result.get_ok (write db ~by:7 ~why:"signup" [ Add (-1, name, Text "Ada Martin"); Add (-1, city, Text "Lyon") ]) in
  Printf.printf "group %d made thing %d\n" r.group (thing r (-1));
  (* a question: the things whose city is Lyon *)
  let q = { vars = 1; ranges = []; where = [ { e = Var 0; p = city; v = Val (Text "Lyon") } ] } in
  (match find (view db) q with
   | Ok rows -> List.iter (fun row -> print_endline (Value.to_string row.(0))) rows
   | Error e -> print_endline (message e));
  close db
```

```output
group 3 made thing 65536
#65536
```

(Le groupe 1 a décrit les propriétés système quand la base a été créée, le groupe 2 a déclaré les deux propriétés.)

## Ce qu'elle promet

Quand `write` renvoie `Ok`, le groupe est sur le disque : il survit à un crash du processus ou à une coupure de courant
(G1). Un groupe est tout ou rien (G2) ; après une recovery (la remise en état à l'ouverture), les groupes sont un
préfixe 1..k de l'historique (G3) ; les écritures sont strictly serializable (équivalentes à une exécution une par une
dans un ordre qui respecte le temps réel), un seul writer les appliquant une à la fois (G4) ; une vue ne change jamais
et ne montre que des groupes durables (G5) ; un dommage aux octets durables est détecté, jamais écarté en silence
(G6) ; un merge (la fusion de fichiers triés) laisse les anciens runs ou les nouveaux, entiers (G12) ; après un fsync
(l'appel système qui attend que les octets soient sur le disque) qui a échoué, aucune vue ne montre un groupe qu'une
coupure de courant pourrait reprendre (G13). Avec des règles, chaque vue contient exactement ce que ses règles dérivent
de ses faits affirmés (G17), les contraintes tiennent (G18), un changement de règle prend effet à un seul groupe (G19),
et `why` renvoie une preuve vraie (G20). Chaque garantie, ses conditions exactes, sa preuve et le test qui la vérifie :
[garanties](docs/fr/book/guarantees.md).

## En serveur

`cepheus serve --config cluster.toml` fait tourner Cepheus comme tourne PostgreSQL : un seul processus tient les bases,
les programmes se connectent par un socket Unix ou par TCP avec TLS 1.3, chacun avec un token (un secret) qui lui donne
la lecture ou l'écriture, base par base (G16) ; une écriture renvoyée après une réponse perdue est appliquée une seule
fois (G14). Serveur contre serveur sur la même machine et les mêmes données (1 M de faits), une lecture ponctuelle
coûte 10,8 µs par le socket Unix (PostgreSQL 18.6 : 26,4), 39,2 µs avec TLS (49,6) ; 8 clients à la fois, 3,22 µs par
lecture en tout (6,54) ; 16 requêtes en cours sur une seule connexion, 1,46 µs par lecture (le pipeline de 16 de
PostgreSQL : 9,11). Un programme sur la machine du serveur lit dans sa propre mémoire, de façon linearizable (chaque
lecture voit tout ce qui a été confirmé avant elle ; G15) : 0,22 µs par lecture ponctuelle, aucun round trip
(l'aller-retour d'une requête et de sa réponse), et aucune écriture ne l'attend. Une replica (une copie tenue à jour)
sur une autre machine garde une copie de chaque base par mutual TLS (où les deux côtés montrent un certificat), groupe
pour groupe dans son propre journal : les sauvegardes se prennent sur elle, et `cepheus promote` en fait le primary (le
serveur qui prend les écritures), à la main ([une replica](docs/fr/book/server.md#une-replica)). Trois serveurs ou plus
forment un cluster Raft (Raft : un algorithme par lequel plusieurs serveurs s'accordent sur une même suite
d'écritures) : une écriture est confirmée dès qu'une majorité la tient forcée sur son disque, et quand le leader (le
serveur qui prend les écritures) est perdu, les autres en élisent un nouveau d'eux-mêmes, sans perdre aucune écriture
confirmée ([un cluster de trois](docs/fr/book/server.md#un-cluster-de-trois-raft)). Tout, de `cluster.toml` au wire
protocol octet par octet : [le serveur](docs/fr/book/server.md).

## Depuis Cesia

Un programme [Cesia](https://github.com/www-celestial/cesia) atteint une base à travers le serveur, avec le package
`cesia/cepheus` de ce dépôt : une seule fonction pour se connecter, et sur la machine du serveur ses lectures sont
servies depuis sa propre mémoire, aussi linearizable que celles du serveur
([Cepheus depuis Cesia](docs/fr/book/cesia.md)) :

```text
use deps/www-celestial/cepheus/cesia/cepheus

Client = cepheus.Kind("client", {Name: cepheus.Text(), City: cepheus.Text(), Email: cepheus.Text(unique = true)})
db = cepheus.Connect("cepheus://srv1:7400/shop", [Client], token = sys.Env("CEPHEUS_TOKEN"), ca = "/etc/cepheus/ca.pem")?
ada = cepheus.Insert(Client, {Name: "Ada Martin", City: "Lyon", Email: "ada@example.com"}, db, by = 7, why = "signup")?
cepheus.Get(Client, ada, db)?               (* {Name: "Ada Martin", City: "Lyon", Email: "ada@example.com"} *)
lyon = cepheus.Find(1, (c) -> {Where: [[c, Client.City, "Lyon"]], Give: {Client: c}}, db)?
```

Sur la machine du serveur, un `cepheus.Get` de 4 champs coûte 0,77 µs depuis Cesia (PostgreSQL 18.6 par son socket,
depuis le C : 26,4 µs) ; par TLS, 51,6 µs (49,6 pour PostgreSQL) ; 64 fibers (les threads légers de Cesia) sur une
seule connexion écrivent aussi vite que 64 connexions. Rien ne se charge avant le premier appel du package, qui coûte
13 ms une fois par processus.

## Fichiers

Une base garde aussi des fichiers : `cepheus.Put(Scans, "2026-11.pdf", bytes, db, owner = ada)` en stocke un,
`cepheus.Read` le lit en entier ou par une plage. Ses octets sont coupés en chunks (des morceaux) selon leur contenu
(FastCDC) et chacun est stocké une seule fois, compressé (LZ4, ou Zstandard pour les fichiers froids, rarement lus),
scellé avec AEGIS-256 (chiffré et protégé contre toute modification) sous la clé de son propriétaire et vérifié à
chaque lecture ; `cepheus.Erase(ada, db)` détruit la clé, et chaque fichier qu'elle possédait devient illisible, où que
soient allés ses octets ([le vault](docs/fr/book/vault.md)).

## Face aux bases de données établies

Mesuré sur un ordinateur portable (Intel i7-4720HQ, SSD SATA) contre PostgreSQL 18.6 réglé comme le ferait un expert,
10 millions de faits, les mêmes réponses des deux côtés, médianes de 21 exécutions
([benchmarks](docs/fr/book/benchmarks.md)) :

| | Cepheus | PostgreSQL |
|---|---:|---:|
| chaque fait d'une facture, par id | 0,39 µs | 4,73 µs dans le serveur ; 26 µs par son socket |
| les factures impayées des clients d'une ville (4 299 lignes) | 2,87 ms | 13,9 ms |
| la somme impayée par ville (453 866 factures), 3 cœurs | 57,8 ms | 107 ms (3 processus) |
| les triangles d'un graphe de follows (568 163 liens), 3 cœurs | 100 ms | 602 ms (2 processus : son maximum) |
| écritures durables, 256 clients | à égalité (les deux limités par le fsync du disque) | |
| les triangles, lus à travers un cache de 32 MB, processus limité à 128 MB, à froid, 1 cœur | **263 ms** (114 ms sur 3 cœurs ; 260 ms limité à 48 MB) | 1,05 s (32 MB de buffers) |
| chargement de 10 M de faits | **5,13 s**, en deux grands groupes, en alternance avec lui | 30,87 s (`COPY`, index, `VACUUM ANALYZE`) |

SQLite 3.54, une bibliothèque dans le processus comme l'est Cepheus, mesuré de la même façon sur un cœur (avant le run
format 7) : Cepheus est plus rapide sur une facture par id (0,37 µs contre 0,68), sur la somme impayée par ville
(230 ms contre 360) et sur les triangles (0,97 s contre 1,04), à égalité sur les factures impayées d'une ville, plus lent
sur un client par e-mail (1,67 µs contre 1,52). Pour charger les 10 M de faits, en alternance sept fois, Cepheus est plus rapide à chaque
tour (5,61 s contre 9,37 s à la médiane : SQLite met 1,7 fois plus de temps), mais SQLite le fait en 11 MB de mémoire
contre 1,46 GB (dont 0,88 pour la liste d'opérations du client lui-même). Depuis le run format 7 et le journal format 2
(2026-11-09), les 10 M de faits prennent 76,0 MB sur le disque avec tout leur historique, contre un fichier de 136 MB
pour SQLite, qui n'en garde aucun, et se chargent en 3,45 s contre 7,22 s ; sur un cœur, un client par e-mail prend
0,66 µs contre 1,37, les factures impayées d'une ville 3,97 ms contre 4,11, les triangles 1,08 s contre 1,03 ; à froid,
chaque processus limité à 48 MB pour qu'aucun des deux fichiers ne tienne en mémoire, Cepheus répond aux quatre
premières questions de 1,7 à 5,4 fois plus vite et perd les triangles de plus de 100 fois (plus de 2,5 minutes par
exécution contre 1,02 s : les liens de follow de SQLite tiennent dans son cache, dans une table à eux)
([benchmarks](docs/fr/book/benchmarks.md#runs-et-journal-compressés-2026-11-09-à-10-millions-de-faits)). Avec le run
format 8 (2026-11-11 : les lignes de chaque propriété aussi à part, dans l'ordre des choses, et les listes triées
intersectées par leapfrog, des sauts de liste en liste) Cepheus gagne les cinq sur un cœur : 0,39 µs contre 0,69,
0,64 µs contre 1,42, 2,87 ms contre 4,18, 130 ms contre 369 et les triangles en 256 ms contre 1,05 s, et avec une
limite de 48 MB les triangles en 260 ms
([benchmarks](docs/fr/book/benchmarks.md#le-column-order-et-les-intersections-en-leapfrog-2026-11-11-à-10-millions-de-faits)) ;
à une transaction par client, le group commit de Cepheus (plusieurs groupes confirmés par un seul fsync) charge 1 M de
faits de 13 à 16 fois plus vite (13,2 s contre 174,0 s ; 10,6 contre 166,7 dans une série antérieure). Où chacun gagne,
et pourquoi, et comment Cepheus se compare par sa conception à Oracle, Datomic, RocksDB, Neo4j, FoundationDB et
CockroachDB : [comparaison](docs/fr/book/comparison.md).

## Compiler et tester

- `dune build` ; `dune test` lance les tests unitaires et les tests de propriétés, l'énumération exhaustive des crashs,
  la simulation déterministe (200 seeds, les valeurs de départ du générateur aléatoire) et chaque exemple de cette
  documentation ;
- `tools/test.sh` lance tout, les tests lents aussi (de vrais `kill -9`, le test bank), dans la build de release ;
- `TLA2TOOLS=/path/to/tla2tools.jar tools/tlc.sh` vérifie par model checking (l'exploration par une machine de tous
  les états d'un modèle) les spécifications TLA+.

Aucune dépendance sauf OCaml 5 (`unix`, `threads`) et son compilateur C pour un seul petit fichier,
`src/crc32c_stubs.c` : le checksum (un petit nombre calculé sur des octets, qui change quand ils changent) par
l'instruction même du processeur (SSE4.2 sur x86-64, CRC32 sur arm64), 8 fois la vitesse du code par table en OCaml
qu'il a remplacé ; un processeur qui ne l'a pas est refusé au démarrage du programme. Le serveur lie aussi l'OpenSSL 3
du système (`libssl`, `libcrypto`) à travers `server/tls_stubs.c`, pour TLS.

## Documentation

Commencez par [concepts](docs/fr/book/concepts.md), puis [comment ça marche](docs/fr/book/architecture.md). La carte
complète : [docs/fr/book/](docs/fr/book/index.md).
