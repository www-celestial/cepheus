# Tests

Comment tester une application avec des forks, et comment Cepheus lui-même est testé : ce que fait chaque test, ses
options, et ce qu'il prouve.

## Tester votre application avec des forks

Un fork est une base de données temporaire : les mêmes lectures, les mêmes écritures, les mêmes vérifications qu'une
vraie, et rien sur le disque.

```ocaml
open Cepheus

(* a fixture made once: a schema and one client *)
let fixture =
  let db = fork empty in
  let[@warning "-8"] (Ok [ name; status ]) = declare db [ prop "client/name" Ttext; prop "invoice/status" Ttext ] in
  ignore (write db [ Add (-1, name, Text "Ada") ]);
  view db, name, status

let () =
  let v, name, _ = fixture in
  (* each test forks the fixture: writes stay in the fork *)
  let t1 = fork v and t2 = fork v in
  ignore (write t1 [ Add (65536, name, Text "Ada Durand") ]);
  let show t = Value.to_string (List.hd (values (view t) 65536 name)) in
  Printf.printf "test 1 sees %s, test 2 sees %s\n" (show t1) (show t2)
```

```output
test 1 sees "Ada Durand", test 2 sees "Ada"
```

Les forks ne coûtent rien à créer : faites-en un par test. Un fork d'un fork marche ; une fixture (l'état de départ
commun des tests) peut donc être préparée une fois et forkée par chaque test. Une question « et si ? » est la même
chose : un fork, on écrit l'hypothèse, on pose la question, on jette le fork.

## Comment Cepheus est testé

`dune test` lance les tests unitaires et les tests de propriété, l'énumération exhaustive, 200 seeds de la simulation,
et les exemples de la documentation ; `tools/test.sh` lance tout dans le build de release, les tests lents aussi.
Chaque test aléatoire tire d'un générateur avec seed (`Rng`, SplitMix64 ; une seed est la valeur de départ du
générateur, et une seed donne toujours la même suite) : un échec affiche donc sa seed et se rejoue exactement.

| commande | ce qu'elle lance | options |
|---|---|---|
| `_build/default/test/unit.exe` | les tests unitaires et de propriété | `CEPHEUS_TMP` : où vont ses bases sur le vrai disque (le répertoire temporaire du système par défaut) |
| `reasoning.exe` | les règles : des cas nommés (des transitive closures des deux formes et leur budget — une transitive closure est la fermeture transitive des maths : tout ce qu'on atteint en suivant une relation de proche en proche —, une propriété variable, `sources` ; les sinks d'un changement, les faits qu'aucune règle ne lit : leur tri contre un tri stable de 300 buffers aléatoires, un sink sur des frères et sœurs sur un fork, avec des morsels, dédoublonné après chaque tête, et sur le disque avec un run à lui, rouvert ; un sink au-delà du budget refusé, en nommant sa règle), puis G17, G18 et G20 sur des suites aléatoires (des règles aléatoires définies, changées et retirées, parmi elles des transitive closures et des règles sur une propriété variable ; des additions et des retraits aléatoires) contre le least model (le plus petit modèle : les faits affirmés et tous ceux que les règles en dérivent) calculé de zéro, seul et sur des runs fusionnés, puis de nouveau les suites seules avec des tours calculés sur plusieurs domains (des fils d'exécution d'OCaml qui tournent en parallèle ; à partir de 4 faits par tour) et avec les règles toujours telles qu'écrites, la vue de chaque groupe égale à celle de la première exécution ; et la moitié des seeds sur des bases sur le disque, où chaque changement des règles prend le chemin en arrière-plan, avec les mêmes décisions que le modèle et la même base une fois rouverte ; et de nouveau avec les têtes des sinks d'un changement dédoublonnées toutes les 3 têtes, sur des forks et sur le disque ; puis des groupes d'additions à partir de 2 faits sur des bases sur le disque, pour que le chemin des chargements raisonne sur son préfixe trié (parmi eux des règles sans `Not` ni agrégats, des contraintes et des têtes à une seule valeur ; des faits déjà dérivés affirmés de nouveau ; des choses nouvelles), contre le modèle, et de nouveau avec des tours sur plusieurs domains | `RULES_SEEDS` (60), `RULES_SEED` (une seule seed, affichée groupe par groupe), `RULES_PROGRESS` (une ligne par seed) |
| `owl.exe` | OWL 2 RL (`Cepheus.Owl` ; OWL 2 RL est la partie du langage d'ontologies OWL 2 du W3C qui se calcule par des règles ; une ontologie décrit des classes, des propriétés et leurs liens) : chacune des 78 règles du W3C par un cas où elle se déclenche ou où sa contrainte refuse, sur cinq chemins (un fork groupe par groupe ; les règles toujours telles qu'écrites ; les données avant l'ontologie, pour que le groupe de l'ontologie soit un changement des règles et des listes des templates — un template est une règle sur une liste, ses patterns écrits une fois pour chaque membre de la liste ; un chargement sur le disque, par le chemin des grands groupes ; une base sur le disque, l'ontologie après les données, par le chemin en arrière-plan), chaque vue comparée au sens des règles calculé de zéro (`Check.least`, les templates par leur sens ; avec l'égalité, `Check.least_eq` : un union-find — une structure qui range les choses en classes de choses égales —, les faits réécrits à chaque passe, la vue lue à travers ses classes), puis les données retirées et écrites de nouveau, l'ontologie retirée ; les datatypes (les types de valeurs d'OWL) ; des ontologies et des données aléatoires (aussi avec les règles telles qu'écrites) ; des égalités aléatoires (sameAs, functional, inverse functional, keys, max cardinality 1, differentFrom ; un refus doit être la contradiction du sens, une acceptation son absence) ; une tempête d'égalités (3 000 choses rendues une seule : 2 999 faits de `cepheus/same`, refusés en entier au-delà d'un petit budget) ; chaque base sur le disque fermée et rouverte, les mêmes faits ; les faits écrits restent affirmés, là où ils ont été écrits | `OWL_SEEDS` (200, dans `tools/test.sh`), `OWL_SEED` (une seule seed d'égalités aléatoires, affichée étape par étape) |
| `rulechange.exe` | le chemin en arrière-plan des changements de règles sur des bases sur le disque : des groupes écrits pendant qu'un changement est retenu après sa construction (`Engine.change_pause`), rattrapés exactement ; un groupe qui écrit le fait du changement, casse sa nouvelle contrainte ou prend le numéro de sa règle y met fin par `Conflict` ; 6 threads qui écrivent, 24 changements et 2 lecteurs qui vérifient chaque vue contre le least model sous ses propres règles, puis la base rouverte ; le budget d'un changement (un produit cartésien refusé pendant qu'un writer continue) et un changement d'ontologie au-delà d'un budget de données, acceptés de la même façon sur le disque et sur un fork ; une fermeture pendant un changement ; un changement avec un `Incr` dans son groupe, calculé dans son groupe à côté de groupes qui comptent avec le même compteur ; un membre Raft (Raft : un algorithme de consensus où des serveurs s'accordent sur un même log, l'ordre des écritures, sous un leader élu ; ici ses frames sont proposées à une fonction qui les enregistre ou en refuse une) : la frame du changement proposée, une frame reprise par Raft ou la frame d'un autre leader qui répond au changement `not_leader`, le journal rouvert identique ; kill -9 pendant des changements, chaque vue rétablie exacte ; la frame d'installation d'un changement avec un run à lui, pour une règle de copie de chaque type de valeur avec un fait du run repris pendant ce temps : ses octets ceux du codage de ses groupes entiers (`Engine.whole`, comme les fait le watch), relus en eux, le journal rouvert identique | `CHANGE_KILLS` (10, dans `tools/test.sh`) |
| `exhaustive.exe` | chaque état de crash de petits journaux, à l'intérieur des merges, et de deux bases qui partagent un commit buffer (le fichier où le serveur force d'un seul fsync les frames de plusieurs bases) | aucune |
| `sim.exe` | la simulation déterministe | `--seeds N` (les seeds 1 à N ; 100 par défaut), `--seed S` (une seule seed), `--steps N` (étapes par seed, 150) |
| `wal_sim.exe` | la simulation déterministe du commit buffer du serveur : trois bases qui le partagent ([plus bas](#le-commit-buffer)) | `--seeds N` (100 par défaut), `--seed S`, `--steps N` (200) ; `WAL_SIM_TRACE` défini : chaque événement d'une seed sur la sortie d'erreur standard |
| `crash.exe DIR ROUNDS [SEED]` | de vrais tours de `kill -9` sur une base dans DIR | SEED 42 par défaut |
| `bank.exe DIR SECONDS` | le test de la banque pendant SECONDS | |
| `seats.exe DIR ROUNDS [SEED] [naive\|expect] [SEATS]` | la vente de places avec kill -9 et un vérificateur de l'historique ([cas](case-seats.md#de-vrais-crashs-et-un-vérificateur-de-tout-lhistorique)) ; `ROUNDS` 0 : pas de kill, le temps pour tout vendre | `BUYERS` (16), SEED 42, SEATS 2 000 |
| `examples.exe` | chaque bloc ```` ```ocaml ```` de `README.md` et de `docs/book/*.md` (`test/extract.ml` en fait le programme), chacun dans son propre répertoire sous `CEPHEUS_TMP`, sa sortie comparée au bloc ```` ```output ```` qui le suit | `CEPHEUS_TMP` |
| `tools/test.sh` | `dune build --profile release`, puis unit, reasoning, exhaustive, sim, wal_sim, crash, bank, seats et examples, les tests du serveur, et ceux du client Cesia quand un Cesia avec son interface native est là | `CEPHEUS_TMP` (un chemin court : celui d'un socket Unix tient en 107 octets), `SEEDS` (300), `BUFFER_SEEDS` (300), `KILLS` (20), `BANK_SECONDS` (2), `SEAT_KILLS` (20), `CESIA_NATIVE` (le dossier du `cesia_v1.cmi` de Cesia ; trouvé à partir de la commande `cesia` s'il n'est pas défini) |
| `tools/tlc.sh` | TLC sur chaque modèle de `spec/` (le journal, les merges, la vente de places, les lectures locales, les watches — les questions vivantes, tenues à jour — et leurs fenêtres, le commit buffer, le chemin en arrière-plan d'un changement de règles), et chaque variante qui doit casser un invariant ([model checking](#model-checking)) | `TLA2TOOLS` : le chemin de `tla2tools.jar` |

Le **deterministic simulation testing** (les tests par simulation déterministe) fait tourner le vrai moteur sur un disque
simulé où une seule seed décide de chaque événement (les écritures, l'ordre des étapes du writer, les crashs, les
dommages) : un échec n'est donc pas un accident rare mais une seed qui le rejoue exactement ; FoundationDB est testé de
cette façon (Zhou et al. 2021). L'**énumération exhaustive** va plus loin sur de petits cas : elle liste chaque état où
peut se trouver le disque après un crash et fait la recovery de chacun (la recovery : la remise en état à l'ouverture,
en relisant le journal), la méthode de l'étude ALICE (Pillai et al. 2014) poussée jusqu'à chaque cas. Le
**property-based testing** (les tests de propriété : QuickCheck, Claessen et Hughes 2000) vérifie une propriété sur
beaucoup d'entrées aléatoires contre un modèle de référence écrit indépendamment.

1. **Tests unitaires et de propriété** (`test/unit.ml`) : CRC-32C (un checksum : un nombre calculé sur les
   octets, qui change dès qu'un octet change) contre la valeur de contrôle et les cinq exemples de la RFC 3720
   (annexe B.4), et contre un oracle, le code à table en OCaml qu'il a remplacé : chaque longueur jusqu'à 72 octets à
   chaque offset (la position en octets) jusqu'à 15, 5 000 longueurs aléatoires jusqu'à 1 MiB à des offsets
   aléatoires, les bords de ses morceaux de 1 MiB jusqu'à 3 MiB, chacun en entier et prolongé par `extend` sur des
   coupes aléatoires en deux et en trois, et les bornes refusées (un offset plus une longueur qui déborde aussi) ; les
   codecs font l'aller-retour sur des valeurs extrêmes ; le bit packing (des champs serrés bit à bit) : 300 tours de
   champs de chaque largeur de 0 à 63 à chaque position, écrits et relus contre une référence bit par bit, avec et sans
   place après le dernier champ (le chemin octet par octet) ; 600 colonnes d'au plus 400 entiers de toutes les formes
   (aléatoires, réguliers, les extrémités des entiers, constants, décroissants, des champs de 0 à 63 bits) relues, leurs
   octets ceux du codeur simple du format (trois passes, un champ à la fois) ; 400 groupes aléatoires (chaque
   sorte et chaque constructeur, des entiers extrêmes, des flottants nan et -0, des textes vides et binaires, jusqu'à 600
   changements, un fait en double) relus au format 2, et au format 1 par son lecteur, et un groupe coupé à n'importe
   quel octet ne se décode jamais ; 40 groupes de records aléatoires puis de 0 à 73 000 changements lus par indice
   (`Group.encode_parts`, chaque type, les textes et les flottants par leur mot), sur un domain et sur plusieurs : les
   octets du codage du groupe entier, relus en lui ; un journal au format 1 (écrit par le propre codeur du test en deux segments, avec ou
   sans fin torn, c'est-à-dire écrite en partie seulement, un `.seg.tmp` resté là) converti à l'ouverture vers les mêmes
   faits, une seconde conversion ne trouvant rien, une frame endommagée au format 1 dans le segment le plus ancien
   refusée (30 seeds ; une frame : un bloc du journal écrit d'un seul tenant) ; une ouverture après un
   snapshot qui lit 80 octets d'un journal de plus de 60 KB (les deux coups d'œil à son en-tête) à travers un disque qui
   compte ; un snapshot
   avec les merges coupés (`compact_min` à `max_int`) qui se termine ; 300 suites aléatoires d'écritures contre une
   sémantique de référence écrite indépendamment (un ensemble de faits) ; `Incr` (des groupes qui numérotent des factures
   à partir d'un seul compteur, certains refusés : les acceptés numérotés de 1 à n, sans trou, aucun numéro deux fois,
   pareil après une coupure de courant ; deux dans un groupe ; jusqu'au plus grand entier et au-delà, au-delà du plus
   petit ; chaque mauvais type, chaque mauvaise sorte de propriété et chaque mauvaise chose refusés, le compteur laissé
   tel quel) ; 300 bases aléatoires × 15 questions aléatoires
   contre un évaluateur naïf, chacune dans la borne de Generic Join calculée à partir des seuls faits
   (`Check.gj_bound`, contre `Query.work` ; les slices du leapfrog comptées là où il peut les lire) ; les coûts : des
   questions où une liste est bien plus grande que la réponse, et des recherches sur une chose de 40 000 valeurs, en
   base et en delta ; un merge (la fusion de runs triés en un seul) garde chaque fait et chaque réponse, et un merge d'un
   run de 8 fois le cache (ses pages dans le fichier, 120 000 choses) tient au plus quelques pages ouvertes (19
   mesurées, borne 24 : les 18 flux de la passe par propriété, et ceux du column order) et jamais plus de pages
   résidentes que le cache ; un run de bien des fois le cache de 16 pages (6 000 choses avec des noms de 60 lettres
   aléatoires : compressé, il doit encore dépasser le cache) lu par des questions sur 3 domains (des fils d'exécution
   d'OCaml qui tournent en parallèle), un bit inversé dans une page du fichier (n'importe quelle page, ou une page
   intérieure des lignes par propriété trouvée par la page table) : refusé à l'ouverture ou faisant échouer chaque
   lecture de cette page, jamais une réponse fausse ; des vues d'au plus 4 runs qui ajoutent et retirent donnent les
   faits et les réponses de leur merge complet ; les tris par chose et par propriété d'un grand groupe égalent un tri de
   référence (300 seeds, des chunks de 1 à 50, des valeurs aux extrémités des entiers) ; le chemin rapide d'un grand
   groupe donne le même codage (octet pour octet : ses tableaux codés par la même fonction que le groupe que fait
   `Resolve`), les mêmes numéros de chose et les mêmes faits que `Resolve`, ou lui laisse le groupe, avec des chunks de
   1 à 9 opérations, des numéros temporaires bien en dessous de la longueur du groupe, et des groupes sans ordre et dans
   l'ordre des choses, chaque sorte prise au moins une fois ; les runs font l'aller-retour, refusent celui d'une autre
   base, mettent de côté un run endommagé et un run du format 7 ; un run de 600 pages et plus sur le vrai disque, vérifié
   à l'ouverture par plusieurs domains, fait l'aller-retour, et est mis de côté quand un octet d'une page est inversé ;
   les forks ne changent rien (fichiers comparés octet par octet) et acceptent ce qu'accepte la base ; une seconde
   ouverture est `Busy` ; des cas nommés (write skew refusé, unique, une seule valeur, triangles).
2. **Énumération exhaustive** (`test/exhaustive.ml`) : pour des journaux de quelques frames, chaque état de crash de la
   frame en vol (chaque sous-ensemble de ses secteurs gardé, chaque longueur de coupe, une déchirure à l'intérieur du
   plus haut secteur gardé) doit revenir, après la recovery, à exactement les bons groupes (la frame compte quand son
   en-tête et son corps ont atteint le disque et que le fichier atteint sa fin : un trailer torn seul est reconstruit,
   G6 ; les frames plus courtes du format 2 mettent une limite de secteur entre un corps et son trailer, un cas que
   l'oracle manquait avant) ; chaque bit de deux journaux, inversé seul, doit être détecté par une lecture complète et
   traité par la recovery comme le dit G6, les bits des en-têtes de leurs segments aussi ; un segment torn à sa
   création, à n'importe quel octet, est abandonné, et l'en-tête d'un segment le plus récent mis à zéro à partir de
   n'importe quel octet en gardant ses frames, ou coupé là où reprend un run, est refusé ; et
   à l'intérieur d'un merge (G12), à chaque appel disque qui modifie quelque chose, pour quatre sortes de merge
   (maintenant, de chaque run ; commencé en avance sur le disque et installé deux frames plus tard ; celui d'un grand
   groupe, fusionné pendant sa préparation et nommé une fois sa frame durable ; ceux d'une recovery qui rejoue une longue
   fin de journal), chaque état de crash : une mort du processus puis une coupure de courant, et des coupures de courant
   qui gardent chaque préfixe des changements de noms de chaque répertoire, avec les octets non forcés perdus, gardés,
   torn ou gardés un secteur sur deux (`Sim_disk.crash ~choose` fait les choix que tirerait une coupure de courant) :
   194 points de crash, 1 944 états (les runs sont petits maintenant : un merge de quelques faits écrit quelques
   pages) ; et chaque fsync
   d'un petit run qui échoue à son tour (G13 ; fsync : l'appel système qui attend que les octets écrits soient vraiment
   sur le disque), sur un système de fichiers qui garde en mémoire les octets qui ont échoué et sur un qui les défait,
   puis une mort du processus à chacun des quatre appels disque suivants ou aucun, une réouverture dans le même
   démarrage de la machine ou aucune, une coupure de courant avec chaque motif, et une réouverture : 2 880 réouvertures
   vérifiées. Le journal est lu ici à travers une fenêtre de 48 octets (4 MiB en usage) : chaque frame est plus longue
   qu'elle, vérifiée par morceaux ou lue en entier, et chaque en-tête et chaque trailer peut chevaucher son bord.
3. **Simulation déterministe** (`test/sim.ml --seeds N`) : le moteur tourne sur `Sim_disk` ; la seed décide des
   écritures, de l'entrelacement de la préparation et du commit, des snapshots, des merges (maintenant, ou commencés à
   partir d'une vue en avance sur le disque et installés des étapes plus tard), des forks, des fermetures propres et des
   réouvertures (la moitié des seeds lisent le journal à travers une fenêtre de 40 à 240 octets), des coupures de
   courant, des morts du processus (`Sim_disk.kill` : le page cache, la copie des fichiers que garde le noyau, reste, et
   sera perdu à une coupure de courant ultérieure), des crashs à l'intérieur de n'importe quel appel disque
   (`Sim_disk.crash_after`), des fsyncs qui échouent, et des bits inversés dans des fichiers durables. Après chaque
   recovery, l'état est comparé au modèle de référence, et les groupes du journal à ceux qui ont été écrits ; l'état
   remis en place compte comme confirmé (une coupure de courant ultérieure doit le garder) ; aucun run ne peut être mis
   de côté sauf un run endommagé, aucun fichier de merge ne doit rester ; des questions aléatoires sur les vues publiées
   doivent donner les réponses de l'évaluateur naïf dans la borne de Generic Join. `sim.exe --seed S` rejoue une seed.
4. **De vrais crashs** (`test/crash.exe DIR ROUNDS`) : un processus enfant écrit avec 8 threads et affiche chaque
   confirmation, en faisant un merge tous les 50 changements, pendant qu'un neuvième thread charge de grands groupes
   (150 nouvelles choses, 450 additions, qui prennent ici le chemin des grands groupes à partir de 200 opérations, en
   chunks de 64, leurs frames écrites par morceaux à côté de leurs merges sur deux domains et forcées tous les 2 KB ;
   une règle dérive un fait de celui de chaque chose chargée, pour que le chemin des chargements raisonne sur son
   préfixe trié) ; le parent le tue avec SIGKILL à un moment au hasard (il compte les mises à mort qui tombent à
   l'intérieur d'un merge, et celles qui tombent avant que le declare de l'enfant (la déclaration de ses propriétés) soit durable : alors aucun groupe ne
   peut être confirmé, et les propriétés reviennent toutes ensemble ou pas du tout), rouvre, et vérifie le contenu de
   chaque groupe confirmé (la première et la dernière chose d'un grand groupe), que chaque chargement présent l'est en
   entier avec le fait dérivé de chaque chose ou n'est pas là du tout, qu'aucun run n'a été mis de côté et qu'aucun
   fichier de merge ne reste.
5. **Concurrence** (`test/bank.exe DIR SECONDS`) : des virements avec `Expect` depuis 16 threads, deux domains lecteurs
   qui vérifient que chaque vue garde le total et que les vues ne reviennent jamais en arrière.
6. **Une vente de places sous kill -9, avec un vérificateur de l'historique** (`test/seats.exe DIR ROUNDS`) : 16
   acheteurs vendent 2 000 places avec `Expect` dans un enfant tué à des moments au hasard ; le vérificateur lit le
   journal et vérifie chaque vente confirmée, au plus un débit par place, aucun débit sans la place, et aucun cycle dans
   le dependency graph (le graphe des dépendances) des ventes, dans l'esprit d'Elle (Kingsbury et Alvaro 2020). Le
   [cas](case-seats.md) le raconte.

Ce que fait le disque simulé (`src/sim_disk.ml`) : il garde, par fichier, le contenu courant et le contenu durable, et
les secteurs écrits depuis le dernier fsync ; par répertoire, les changements de noms depuis sa dernière
synchronisation. Une coupure de courant tranche chaque secteur non synchronisé au hasard (perdu, gardé, déchiré à
l'intérieur), choisit une longueur entre la taille durable et la taille courante, et garde un préfixe aléatoire des
changements de noms de chaque répertoire ; un test peut faire lui-même chacun de ces choix (`~choose`). Une mort du
processus ferme les fichiers et garde tout tel quel. Un fsync qui échoue fait ce que l'article a mesuré (Rebello et al.,
ATC 2020) : les secteurs écrits sont marqués clean (identiques au disque, rien à écrire) sans atteindre le disque, leurs
octets gardés en mémoire (ext4, XFS ; la nouvelle taille rendue durable au hasard, comme peut le faire ext4) ou défaits
(Btrfs, `Sim_disk.create ~reverts`) ; un fsync ultérieur n'écrit que les secteurs écrits depuis, donc un secteur
marqué clean reste hors du disque jusqu'à ce qu'il soit écrit à nouveau ou qu'une coupure de courant le tranche. Tant
que cela n'était pas modélisé, le fsync simulé copiait chaque octet en mémoire sur le disque, et le trou que ferme G13
passait inaperçu.

### Le fichier C, fuzzé

`src/crc32c_stubs.c` est le seul C du moteur (celui du serveur est `server/tls_stubs.c`, plus bas). En plus du test de
propriété ci-dessus, qui le fait tourner à travers OCaml, il est
**fuzzé** seul (le fuzzing : nourrir un programme d'entrées générées et mutées pour trouver ses plantages ;
`test/fuzz_crc32c.c`, hors du build de dune) : libFuzzer (le fuzzer de LLVM) lui donne des entrées qu'il mute pour
atteindre de nouveaux chemins, sous AddressSanitizer (une lecture hors des octets arrête l'exécution) et
UndefinedBehaviorSanitizer ; chaque entrée est un CRC à prolonger, un offset, une longueur, une coupe et les octets,
gardés dans les octets comme le vérifie `Crc32c` avant chaque appel, et le résultat est comparé à la définition calculée
bit par bit, en entier et coupé en deux. Lancez-le avec clang :

```
clang -g -O1 -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=all -I "$(ocamlfind ocamlc -where)" \
  test/fuzz_crc32c.c src/crc32c_stubs.c -o fuzz_crc32c && ./fuzz_crc32c -max_len=65536 -max_total_time=300
```

Sur la machine de test (2026-11-08, clang 23.1.4) : 90 126 874 entrées en 301 s, puis 38 048 578 en 121 s avec des
entrées longues dès le départ (`-len_control=0`), puis 28 944 296 en 121 s à partir d'entrées de 1 à 64 KiB, puis
632 422 en 61 s gardées jusqu'à 64 KiB (`-reduce_inputs=0 -shrink=0`) : aucun échec. Deux copies cassées du fichier,
l'une qui lit un octet après la fin et l'autre fausse sur une fin de 3 octets, ont été prises en moins d'une seconde
chacune : le harness (le programme qui fait tourner le fuzzing) peut échouer. Les tests et le fuzzing ont tourné sur
x86-64 ; le code arm64 (`crc32cx`, `crc32cb`, la vérification par `getauxval`) a été compilé pour arm64 (clang 23,
`--target=aarch64-linux-gnu`) mais n'a pas encore tourné sur un processeur arm64.

### Le serveur

- `server_unit` : TOML, chaque règle de `cluster.toml`, les tokens (base64url contre les vecteurs de la RFC 4648, le
  hash, la comparaison en temps constant, `tokens.toml` écrit et relu ; un token est la suite d'octets secrète qu'un
  programme présente pour prouver ses droits), le wire (le format des octets sur la connexion : 5 000 requêtes
  aléatoires codées et décodées, chaque coupe de leurs corps refusée ; chaque réponse ; un compte plus grand que ses
  octets refusé avant toute allocation ; `Incr` aller-retour, et des Writes qui en portent fuzzés : chaque octet changé, des coupes, des octets insérés, des nombres énormes, lus ou refusés, jamais plus), les
  origines, la table des sessions et son checkpoint (un checkpoint endommagé
  refusé), et les droits de chaque token contre chaque requête sur chaque base à travers le cœur du serveur (G16,
  `Follow` avec eux), un token retiré ou restreint, une origine forgée, une frame au-delà de la limite ; les bornes d'une réponse (un produit cartésien de deux patterns
  qui ne partagent aucune variable, demandé avec Sort, avec des agrégats et comme un watch, chacun `too_large` au-delà
  de ses cellules, lignes fois colonnes, et les cellules rendues ; sans Sort, au-delà de ses cellules, chaque ligne
  envoyée en flux dans des frames, la sortie n'en tenant jamais plus d'une ; le pool, la réserve de cellules commune aux
  connexions, tenu par d'autres ; 64 patterns pris et 65 refusés ; un pattern répété dix fois au-delà d'un budget de
  lookups, des recherches dans un index ; trois watches par connexion et cinq par serveur sous des limites abaissées, et
  ce que gardent les fenêtres) ; des réponses dans la limite des frames (un Open de 17 MB de noms et un Get de 17 MB de
  faits en frames de l'indicateur more, rejointes ; des noms et des textes au-delà de leurs bornes ; un reçu au-delà
  d'une frame refusé avant d'être appliqué) ; un seul Hello par connexion ; aucun chemin du serveur dans une erreur ;
  et ce dont les
  lecteurs locaux ont besoin du système : des descripteurs passés sur un socket (400 messages aléatoires de 1 à 6 000
  octets avec jusqu'à 8 descripteurs, lus en morceaux aléatoires : les octets et les fichiers sortent dans l'ordre,
  chacun un nouveau descripteur du même fichier ouvert, aucun laissé ouvert ; plus de 64 refusés) et la page de
  visibilité (une écriture vue aussitôt à travers le mapping en lecture seule, un mapping par fichier, un second serveur
  de la même base refusé) ; et un follower (un lecteur qui suit la base) d'une base avec une règle, à partir de son run
  et de son journal, tient exactement les faits du moteur et ceux d'entre eux qui sont affirmés, à son départ et après
  qu'il repose sur une nouvelle base (les faits dérivés viennent avec leur sorte, dans le drapeau du run et les sortes
  des frames, et sont appliqués comme le replay les applique, jamais évalués) ; un watch avec Sort et Limit à travers le
  cœur du serveur : sa première réponse dans l'ordre, une ligne qui entre et la dernière qui part, une ligne de la
  fenêtre qui part et la fenêtre remplie à nouveau après sa dernière ligne, une ligne d'après la fenêtre qui ne donne
  aucun message, une ligne qui change dans la fenêtre, les listes de chaque changement dans l'ordre ; After, Limit sans
  Sort, des agrégats et un Limit de plus de 100 000 refusés ; sa première réponse et son remplissage dans le budget de
  questions (au-delà, ce watch se termine `too_large` et un watch sans Sort à côté continue) ; un token d'une seule
  sorte rempli avec sa propre question, un watch sur une sorte qu'il ne lit pas refusé ; et un programme du protocole 5
  qui refuse un tel watch à un serveur du protocole 4 avant de l'envoyer.
- `server_sim` : la simulation déterministe du serveur sur un réseau simulé, sur le disque simulé : des clients de
  chaque droit, en pipelining (plusieurs requêtes envoyées sans attendre les réponses), leurs octets coupés à n'importe
  quel octet et livrés en retard, des connexions cassées (les écritures sans réponse envoyées à nouveau avec leurs
  numéros de série), les lots du writer, les merges, les checkpoints, les morts du serveur et les coupures de courant à
  n'importe quel appel disque, les fsyncs qui échouent, les arrêts propres, les checkpoints endommagés. Vérifié : G1 à
  G5, G10, G11 à travers le protocole, G14 (chaque session et chaque numéro de série dans un groupe au plus, chaque reçu
  qui le nomme ainsi que ses nouvelles choses), G16. Deux bugs qu'elle a trouvés sont dans l'histoire du serveur : un
  test qui ne forçait pas le nom d'un répertoire, et une écriture refusée appliquée après une plus récente quand elle
  était envoyée à nouveau (maintenant répondue par sa première erreur). Les lecteurs locaux (G15) suivent la base à
  travers le vrai code de diffusion et de follower (`Follow`, `Follower`), leurs événements pris par l'expéditeur du
  serveur et appliqués par le lecteur à des moments que tire la seed (un lecteur en pause, lent, tué puis relancé),
  leurs flux coupés quand le serveur meurt (ce qui a été envoyé reste lisible), la page de visibilité gardée par la mort
  d'un serveur et remise à zéro par une coupure de courant ; dans certaines seeds, chaque groupe de deux à quatre
  opérations est un grand groupe (un run à lui, passé avant que sa frame soit durable). Chaque lecture, locale ou
  distante, est vérifiée quand elle revient : elle tient chaque groupe répondu à n'importe quel client avant qu'elle
  commence (Fresh), chaque groupe qu'une lecture a rendu avant qu'elle commence (Ordered), et elle est l'état du modèle à
  son groupe, durable (Durable) : G15, avec G5 et G13 pour les lecteurs. Les premières exécutions ont trouvé un bug du
  test (le corps d'un grand groupe, écrit par morceaux, décodé depuis le buffer de lot vide).
- `server_crash` : un vrai `cepheus serve` de deux bases (leurs journaux forcés par son commit buffer, en rounds qui
  portent les deux ; un round, une tournée du buffer : les frames arrivées ensemble, forcées par un seul fsync), tué 20 fois (kill -9) sous quatre clients qui écrivent par le socket Unix, la moitié vers chaque
  base ; à la fin, chaque écriture confirmée est dans sa base une fois et aucune écriture deux fois (G1, G14) ; pendant ce
  temps, deux lecteurs lisent dans leur propre mémoire, et chaque lecture, locale ou au serveur pendant qu'un follower
  est refait, tient chaque écriture répondue et chaque état rendu avant qu'elle commence (G15 avec l'horloge réelle :
  des millions de lectures) ; un second serveur sur les mêmes données est refusé (G9), `cepheus status`, un token retiré
  pendant que son programme est connecté (refusé dans le rechargement, ses lectures locales aussi : le flux se
  termine), `cepheus stop`.
- `server_tls` : un vrai serveur avec TLS : un client de la CA du cluster (l'autorité qui signe ses certificats) lit ;
  la CA d'un autre cluster, un certificat qui ne nomme pas l'hôte, un autre identifiant de cluster, un client TCP sans
  CA et un client en clair sur le port TLS sont tous refusés, et le serveur continue ; TCP sans `[tls]` est refusé au
  démarrage.
- `server_limits` : un vrai serveur avec `max_connections = 3` et `idle_timeout = 1` : avec trois programmes connectés,
  une quatrième connexion par le socket Unix reçoit `too_many_connections` et une par TCP est fermée avant tout octet ;
  avec trois connexions qui ne montrent aucun token et tiennent chaque place, un programme est servi (la plus ancienne
  d'entre elles lui laisse sa place) ; une connexion silencieuse, une qui envoie un octet à la fois sans requête, une
  qui s'arrête dans son handshake TLS (la poignée de main, l'échange qui ouvre la connexion chiffrée), une qui envoie
  son handshake TLS un octet à la fois, et une qui envoie un record TLS (un bloc chiffré du flux TLS) un octet à la fois
  après Hello sont fermées en moins de deux fois la limite (les silencieuses après `idle`) ; un client qui envoie des pings plus souvent reste ; un client inactif au-delà de la limite
  lit à nouveau, sa bibliothèque se reconnectant d'elle-même. Puis un serveur de 200 bases (chacune prend une
  écriture ; le processus tient 21 domains, sous le plafond de 128), 30 grandes questions envoyées à la fois (60 000
  choses, chacune répartie entre des domains : chaque réponse exacte, aucune `internal`, les helpers dans les bornes du
  pool), un produit cartésien qui a 0,1 s (`timeout` en moins de 0,3 s), et une question de plusieurs secondes dont le
  programme ferme son socket (le serveur la compte annulée en moins d'une seconde).
- Les temps des questions dans `server_unit` : un produit cartésien de trois patterns (216 millions de bindings) au
  0,1 s du serveur finit en `timeout` en moins de 0,2 s, tenu ou envoyé en flux ; le temps plus long d'un token est
  celui du serveur, celui d'un token admin le sien (0,3 s) ; le 0,1 s d'un programme sans temps au serveur ; la
  première réponse d'un watch ; une connexion partie finit sa question sans réponse ; `Cepheus.fold ~timeout`.
- `server_guard` : des connexions servies par le propre code du serveur sur de vrais sockets, sur une base dont les
  lectures lèvent une exception quand le test le dit (le bug d'une requête) : une requête qui lève une exception sur
  une connexion qui a un watch et une écriture en cours (l'écriture répondue, la requête `internal`, la connexion
  fermée), 200 connexions de ce genre à la suite, et un échec dans un autre thread d'une connexion pendant qu'elle
  attend dans une lecture, par un socket Unix et par TCP (`internal` sur l'id 0, aucune requête répondue après) ; une
  frame de 16 MiB avant Hello refusée avant que son corps soit lu, trois frames de 700 KB commencées à la fois tenues
  dans une borne de 1 MiB et répondues à tour de rôle, et 3 000 Finds envoyés à la fois par un client qui ne lit encore
  rien, dont le serveur ne décode plus aucun tant qu'il tient un MiB de réponses ; après
  chacun, les descripteurs et les threads du processus sont ce qu'ils étaient, aucune connexion ni aucun watch ne reste,
  et une nouvelle connexion est servie.
- Chaque serveur que lancent ces tests tourne dans une session à lui (`setsid`) avec sa sortie dans un `serve.log` à
  côté de son `cluster.toml`, et il est arrêté à la fin de son test, même quand le test échoue (`test/serve.ml`) ; les
  tests ignorent SIGPIPE, pour qu'une écriture sur une connexion que le serveur a fermée soit une erreur, pas la mort du
  test.

### Le commit buffer

- `wal_sim` : trois bases sur un même disque simulé partagent un commit buffer (`src/wal.ml`), dont les fichiers
  alternent après 300 à 3 300 octets, les segments de leurs journaux longs de 600 à 4 600 octets. Une seule seed décide
  de chaque événement : les écritures de chaque base (certaines de grands groupes, forcés dans leur propre journal ;
  certaines frames plus longues que ce que prend le buffer, forcées là aussi), le moment où chaque frame atteint son
  journal et le buffer, les rounds, les nettoyages du fichier qui n'est pas actif, les merges, les morts du processus
  (le page cache gardé, perdu à une coupure de courant plus tard), les coupures de courant, les crashs à l'intérieur de
  n'importe quel appel disque, ceux de la recovery aussi, et les fsyncs qui échouent, du fichier du buffer ou d'un
  journal, comme le disque de la simulation les fait (G13). Après chaque recovery : chaque groupe confirmé de chaque
  base est là (G1), chaque journal tient exactement les groupes écrits, dans l'ordre (G2, G3), ce qu'une recovery a
  publié survit au crash suivant (G5), aucune ouverture ne refuse, sauf à une frame ou à un round qu'aucun fsync n'a
  confirmé et dont seul le secteur de l'en-tête a été perdu (G6), aucune écriture n'est confirmée après un fsync qui a
  échoué (G10). Une base ouverte seule après un crash doit être refusée, et acceptée après un arrêt propre ; et de temps
  en temps une version sans le buffer ouvre une base après un crash et y écrit : le démarrage suivant du serveur doit
  refuser cette base, jamais écrire par-dessus ses frames. La moitié des seeds forcent dans son propre journal une frame
  qui arrive quand le buffer est au repos (`Wal.alone`). Dans `tools/test.sh` (300 seeds, 2026-11-12) : 29 771 groupes
  confirmés, 12 968 rounds (950 de plusieurs bases), 1 726 coupures de courant, 1 044 morts du processus, 1 476 crashs à
  l'intérieur d'un appel disque et 607 à l'intérieur d'une recovery, 6 838 erreurs `Io`, 4 598 ouvertures seules
  refusées et 601 acceptées après un arrêt propre, 155 bases écrites par une version sans le buffer (12 d'entre elles
  refusées au démarrage suivant, les autres n'avaient rien perdu) ; une fausse alarme de G6 (un round qu'aucun fsync n'a
  confirmé, seul le secteur de son en-tête perdu) ; aucun échec.
- `exhaustive.exe`, partie 6 : deux bases partagent un buffer dont les fichiers alternent après 500 octets, leurs
  segments longs de 1 500 octets, dans une exécution fixe, chaque frame passant par le buffer (des rounds d'une base et
  des deux, de longues frames forcées dans leur propre journal, un segment quitté, des changements de fichier, un
  nettoyage, un changement vers le fichier nettoyé). À chacun de ses 50 appels disque qui modifient quelque chose : une
  mort du processus (puis une coupure de courant après la recovery), et des coupures de courant qui gardent chaque
  préfixe des changements de noms de chaque répertoire, les octets non forcés perdus, gardés, torn, ou gardés un secteur
  sur deux ; puis chacun de ses 13 fsyncs qui échoue à son tour, suivi d'une mort du processus, d'un arrêt propre ou
  d'aucun des deux, d'une réouverture dans le même démarrage de la machine ou d'aucune, et d'une coupure de courant qui
  garde tout ou rien : 556 états de crash et 156 états après un fsync qui a échoué, chaque groupe confirmé là, aucune
  fausse alarme.
- Des mutation checks (une partie de la règle retirée, pour voir les tests échouer ; les vérifications échouées dans
  300 seeds de `wal_sim`, chaque frame passant alors par le buffer, et dans la partie 6 exhaustive) : la recovery qui se
  fie à la règle propre de chaque journal (aucune frame écrite de nouveau), 1 914 dans 298 seeds, et 185 ; le nettoyage
  sans son checkpoint (le fsync d'un journal, après lequel le buffer n'a plus besoin de ses frames), 11 dans 11 seeds,
  et 34 ; un run nommé sans forcer d'abord son journal, 316 dans 80 seeds, et aucune ; un segment quitté sans le
  forcer, 584 dans 104 seeds, et aucune ; une frame sautée quand le page cache la montre déjà, 1 (seed 113), et 2. La
  première version de la recovery sautait une frame dont le page cache montrait déjà les octets : après un fsync qui
  avait échoué (les pages marquées clean) et une réouverture dans le même démarrage, le buffer était vidé alors que le
  disque n'avait pas la frame, et une coupure de courant la perdait. `wal_sim` l'a trouvé (seed 113 sur 300) ; la
  partie exhaustive non, parce qu'elle coupait toujours le courant avant la réouverture ; elle rouvre maintenant aussi
  dans le même démarrage, et, le saut remis, échoue deux fois. Une fermeture propre après un checkpoint qui avait échoué
  dans le thread du buffer laissait le marqueur `closed` ; elle ne le fait plus (`Journal.forced`), même si aucun test
  ne distingue les deux : les frames sont de toute façon écrites de nouveau au démarrage.

### Le client Cesia

- `cesia test cesia/tests`, sur les deux chemins de Cesia (`--no-spec` aussi) : chaque fonction du package sur des
  forks de `cepheus.Empty`, sans serveur ([Cesia](cesia.md#tests)) : les types de valeurs, les joins, les agrégats, les
  intervalles, les valeurs multiples, `Expect`, les nouvelles choses d'un groupe, `Incr` (30 fibers numérotées de 1 à
  30 ; un groupe refusé, un `by` négatif, au-delà des entiers, les mauvais types), `unique`, `Update`, les erreurs de
  programmation qui sont des erreurs, un fork qui ne change jamais son origine, `Close`.
- `test/cesia.sh` : un projet à lui tient le package dans `deps/` comme le met `cesia pkg` (son moteur, son
  `cesia.lock`) ; un vrai serveur ; puis chaque exemple de [Cepheus depuis Cesia](cesia.md) tourne, bloc par bloc avec
  les blocs d'avant, sur une base à lui, et ce qu'il affiche doit être le texte qui le suit (`test/cesia-docs.ce`) ;
  `test/cesia-live.ce` par TLS et par le socket Unix (200 écritures par une connexion, chacune lue aussitôt par une
  autre, en local : G15 à travers le package ; 100 et 200 fibers sur une connexion ; 50 fibers numérotées par un même
  compteur `Incr`, de 1 à 50, chacune une fois ; un fork ; `Close`), sa sortie
  comparée à `test/cesia-live.expected` ; et le serveur tué avec `kill -9` et relancé pendant que 10 fibers écrivent
  1 500 factures : chaque écriture répondue `Ok`, chacune une fois dans la base (G14 à travers le package).

### Le C du serveur, fuzzé

`server/tls_stubs.c` est en deux parties : un cœur de C simple sur OpenSSL, sans valeur OCaml (les contextes, une
connexion sur des buffers en mémoire, les étapes de son handshake, les octets donnés et repris, les lectures et
écritures en clair, le nom du pair, les certificats du cluster), et de fines enveloppes qui convertissent les valeurs
d'OCaml et lèvent ses erreurs (`server/tls.ml` vérifie chaque offset et chaque longueur, et refuse une chaîne qui
contient un octet NUL, avant tout appel). Le cœur est **fuzzé** seul (`test/fuzz_tls.c`, hors du build de dune) sous
libFuzzer, AddressSanitizer et UndefinedBehaviorSanitizer ; au départ, le harness crée une CA, un certificat de serveur
pour 127.0.0.1 et un de client avec la propre fonction `cph_tls_make_cert` du cœur, et le premier octet de chaque
entrée choisit ce que pilote le reste :

- une connexion de serveur à qui l'on donne l'entrée comme les octets d'un client, en morceaux dont l'entrée donne les
  tailles ;
- une connexion de client (la CA et l'hôte vérifiés) à qui l'on donne l'entrée comme les octets d'un serveur ;
- un client et un serveur qui se parlent à travers la mémoire : l'entrée dit, étape par étape, quel côté fait une étape
  de handshake, déplace un morceau de sa sortie vers l'autre (avec au plus un octet de la conversation changé en
  route), écrit des octets en clair, ou les lit en morceaux d'une taille donnée. Vérifié à chaque lecture : ce qu'un
  côté lit est un préfixe de ce que l'autre a écrit (TLS authentifie chaque record, donc un octet changé n'est jamais
  lu comme une donnée) ; à la fin, quand rien n'a été changé, les deux handshakes sont finis, chaque côté a lu tout ce
  que l'autre a écrit, chaque côté nomme le certificat de l'autre, et un close_notify termine le flux de l'autre côté ;
- un certificat signé par la CA pour un common name et un subjectAltName pris dans l'entrée, qui doit se vérifier.

Les seeds sont un ClientHello capturé avec `openssl s_client`, un premier envoi de serveur avec `openssl s_server` et
les certificats de test, et des conversations entières. Lancez-le avec clang :

```
clang -g -O1 -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=all -DCEPHEUS_TLS_CORE_ONLY \
  test/fuzz_tls.c server/tls_stubs.c -lssl -lcrypto -o fuzz_tls && ./fuzz_tls -max_len=16384 -max_total_time=300
```

Sur la machine de test (2026-11-08, clang 23.1.4, OpenSSL 3.6.5) : 62 439 entrées en 301 s à partir des seeds et du
corpus, puis 17 445 en 121 s avec des entrées gardées longues (`-reduce_inputs=0 -shrink=0 -len_control=0`), environ
200 par seconde (la plupart des entrées font un handshake : des millisecondes d'échange de clés et de signatures) :
aucun échec. Une première exécution s'est arrêtée sur un bug du harness lui-même (sa dernière boucle abandonnait après
64 tours de 16 KiB, alors qu'une entrée peut écrire 40 MB) ; corrigé, il se termine quand un tour ne déplace rien. Deux
copies cassées du cœur ont été prises en moins d'une minute chacune : l'une qui dit avoir lu un octet de plus qu'elle
n'en a donné (une lecture au-delà de ce que le pair a écrit), l'autre qui donne à OpenSSL un octet de moins qu'elle
n'en a reçu (un handshake qui ne finit jamais).

`server/fdpass_stubs.c` (les descripteurs passés pour les lectures locales, et le mapping en lecture seule de la page
de visibilité) est testé par propriétés à travers OCaml dans `server_unit` : 400 messages aléatoires de 1 à 6 000
octets avec 0 à 8 descripteurs, lus en morceaux aléatoires : les octets et les fichiers sortent dans l'ordre, chacun un
nouveau descripteur du même fichier ouvert, aucun laissé ouvert ; plus de 64 descripteurs sont refusés ; la page montre
aussitôt l'écriture du serveur.

### Le vault de fichiers

`test/vault_unit.exe` vérifie le vault ([le vault](vault.md) ; le vault de fichiers est le magasin où Cepheus garde
les fichiers, découpés en chunks, des morceaux, puis compressés et scellés, c'est-à-dire chiffrés et authentifiés) :

- son C : des blocs LZ4 et Zstandard de 0 à 256 KiB font l'aller-retour (300 seeds, du texte et des octets
  aléatoires), refusent une sortie trop courte ou trop longue d'un octet et un bloc coupé ; BLAKE2b-256 avec clé (un
  hash dont le résultat dépend aussi d'une clé secrète) et la dérivation des clés contre le `hashlib` de Python (une
  implémentation à lui) ; AEGIS-256 (un cipher authentifié : il chiffre et détecte tout changement) refuse tout bit
  changé, toute clé, tout nonce (le nombre qui ne sert qu'à un seul chiffrement), tout octet des données associées
  (authentifiées sans être chiffrées) changés, et toute coupe (200 seeds) ;
- le chunker (qui découpe un fichier en chunks dont les bords sont tirés du contenu) : chaque chunk entre 16 et
  256 KiB, une moyenne à moins de 10 % des 73 KiB de la formule, 97 % des octets d'une copie modifiée retrouvés (avec
  des chunks de taille fixe : moins de 30 %) ;
- le magasin : des fichiers de 0 octet à 9 MB aux bornes du chunker, chauds et froids (LZ4 ou Zstandard), écrits en
  morceaux aléatoires, lus en entier et en 25 intervalles aléatoires chacun ; le même fichier deux fois n'écrit rien ;
  une copie modifiée n'écrit que les chunks proches de la modification ; un autre domain (la chose dont la clé scelle
  un fichier, son propriétaire ; sans rapport avec les domains d'OCaml) ne partage rien ; rouvert à partir des index
  et, tous les index retirés, à partir des packs (les fichiers où les chunks sont ajoutés à la suite) ;
- des **coupures de courant** sur le disque simulé : 120 seeds, trois crashs chacune à un appel au hasard de puts (un
  put : le dépôt d'un fichier) jusqu'à 3 MB (certains qui partagent des chunks, certains froids, un effacement), avec
  des secteurs perdus, gardés ou torn comme une coupure de courant les laisse : le vault s'ouvre à chaque fois, et
  chaque fichier fini avant un crash se relit exact (G22) ;
- **group commit** (confirmer plusieurs puts par un seul fsync) : quatre threads déposent des fichiers en même temps
  sur le disque simulé (un appel à la fois, les threads entrelacés à chacun, un fsync qui dure pendant que les autres
  tournent, des packs fermés pendant qu'un autre thread les force), coupés par une coupure de courant à un moment au
  hasard, 40 seeds : chaque fichier confirmé avant elle se relit, avec moins de fsyncs que de puts ;
- **un kill, puis une coupure de courant** : un processus tué au milieu d'un put de 6 MB (ses chunks dans le page
  cache, pas forcés), le vault rouvert, le fichier déposé de nouveau (ses chunks trouvés déjà stockés), puis une
  coupure de courant : il se relit, 30 seeds ;
- **dommages** : un octet changé dans un chunk donne `damaged` pour les intervalles qui le couvrent et seulement
  ceux-là, le même fichier déposé de nouveau le répare ; un record (l'entrée stockée d'un chunk ou d'un nœud) déplacé
  sur un autre est refusé (G23) ;
- **effacement** : les fichiers d'un domain effacé donnent `erased` (l'un lu deux fois avant, la seconde fois depuis
  les caches, aussi), après une réouverture aussi, sa clé scellée a disparu du fichier des clés, aucun nouveau fichier
  ne la nomme (G24) ;
- **copies** : les records qui manquent à un vault, trouvés en comparant des Merkle trees (des arbres de hashes où
  chaque nœud résume ses enfants), sont exactement la différence des ensembles, trouvée avec moins de digests (des
  empreintes) que de records ; une fois copiée, la copie lit chaque fichier et a la même racine ; un effacement suit
  les clés ;
- un **lecteur fuzzé** : 20 000 records changés au hasard (des octets, des coupes, des champs avec leurs CRC refaits,
  des en-têtes) donnent les bons octets ou une erreur, rien d'autre ; 20 000 nœuds changés au hasard se lisent dans
  leurs règles ou sont refusés.

`test/vault_crash.exe DIR 20` tue, 20 fois, un processus qui dépose des fichiers jusqu'à 40 MB et écrit leurs faits,
puis vérifie que chaque fichier que citent les faits se relit exact et que chaque fichier confirmé est là.

Le cœur en C est fuzzé seul par `test/fuzz_vault.c` (libFuzzer, AddressSanitizer, UndefinedBehaviorSanitizer ; la
commande est dans [le vault](vault.md#sécurité)) : des blocs LZ4 et des frames Zstandard d'octets arbitraires décodés
dans des buffers sans marge, des allers-retours, et des textes scellés forgés ou changés. 1,1 million d'exécutions en
181 s : aucun échec.

`server_unit` dépose et charge des fichiers à travers le cœur : en morceaux, en entier et en 20 intervalles, envoyé de
nouveau avec son numéro de série (un seul fichier), avec chaque sorte de token (des droits par kind ; un kind regroupe sous un nom les propriétés d'une sorte de
chose), un droit
d'écrire perdu au milieu d'un put, les bornes (un kind non déclaré, un propriétaire qui n'est pas une chose, un nom
trop long, un chargement par une autre propriété, quatre puts à la fois), et un effacement ; 3 000 requêtes de
fichiers aléatoires se relisent comme écrites et 24 000 requêtes changées sont lues ou refusées.

## Pas encore

Les tests à la Jepsen de vrais serveurs sous des pannes de réseau ne sont pas construits. La simulation d'un cluster
Raft perd, duplique et réordonne des messages et coupe le réseau ([comment c'est prouvé](server.md#comment-cest-prouvé)).

## Model checking

**TLA+** est un langage pour décrire un système comme un ensemble d'états et les étapes entre eux, en mathématiques
(Lamport 2002) ; un **model checker** visite chaque état qu'un modèle borné peut atteindre et vérifie les invariants
(les propriétés qui doivent tenir) dans chacun. **TLC** est le model checker de TLA+ (Yu, Manolios, Lamport 1999). Les
tests essaient les cas auxquels quelqu'un a pensé ou qu'une seed a tirés ; TLC les essaie tous, dans ses bornes, et
affiche la plus courte suite d'étapes qui casse un invariant.

`spec/Journal.tla` modélise le protocole du journal avec les pannes F1-F4, le page cache et le disque tenus à part : des
frames écrites une à la fois et forcées ; une mort du processus (le page cache reste) et une recovery qui le lit ; une
coupure de courant qui perd, garde ou déchire chaque frame que le disque peut ne pas tenir ; un dommage silencieux
d'une frame durable (dans son corps, ou dans son en-tête) ; un fsync qui échoue et marque les pages clean, leurs
octets gardés ou défaits en mémoire, un fsync ultérieur ne les écrivant pas ; la coupe du writer qui suit (forcée,
échouée, ou tronquée sans son fsync) ; la recovery avec les règles de Cepheus, qui écrit à nouveau sa frame la plus
récente. Invariants : `Durable` (G1 : une frame confirmée est dans le fichier et sur le disque, sauf si la recovery a
refusé d'ouvrir ou si elle a elle-même été endommagée), `RefuseOnlyOnDamage`, `PublishedOnDisk` (G13 : ce que les
lecteurs peuvent voir est sur le disque), `Prefix` (G3), `NoTornData` (G2 : une frame torn n'est jamais gardée),
`StopSafe` (G10), `ResidualBound` (G6 : une coupe ne perd que des frames endommagées). Lancez-le avec
`TLA2TOOLS=/path/to/tla2tools.jar tools/tlc.sh` ; le jar est la release officielle (v1.7.4) de
https://github.com/tlaplus/tlaplus/releases, lancée par Java 11 ou plus récent. Bornes dans `spec/Journal.cfg` : 7
frames, 3 dommages : 3 856 315 états distincts, profondeur 29, 20 s sur la machine de test. TLC a trouvé une vraie
trace (deux frames endommagées à la fin étaient toutes deux coupées), corrigée dans `Journal.written_after`. Avec
`RewriteAtRecovery` à FALSE, il affiche la trace de G13 en 4 étapes (écriture, fsync qui échoue, mort avant la coupe,
recovery qui publie la frame).

`spec/Seats.tla` modélise la vente de places du [cas](case-seats.md) : des acheteurs qui lisent une vue et choisissent
une place libre, des groupes appliqués un à la fois avec ou sans `Expect (seat, owner, None)`, des crashs ; invariants
`NoDoubleSale` et `NoChargeWithoutSeat`. Avec l'`Expect` (`spec/Seats.cfg`, 4 acheteurs, 3 places), ils tiennent dans
les 8 449 états ; sans lui (`spec/SeatsNaive.cfg`, 3 acheteurs, 2 places), TLC affiche un contre-exemple de 4 étapes,
et `tools/tlc.sh` échoue s'il ne le fait pas.

`spec/Merge.tla` modélise comment le fichier d'un merge remplace des runs (G12), avec le journal réduit aux groupes
écrits et aux groupes durables : des chaînes de runs nommés par leurs groupes, des merges de n'importe quel nombre des
runs les plus récents, une recovery qui prend la chaîne de runs nommés qui atteint le groupe le plus récent avec le
moins de runs ; une mort du processus (le page cache gardé), une coupure de courant (les octets non forcés perdus, un
préfixe des changements de noms du répertoire gardé), un fsync qui échoue (ses frames marquées clean), la coupe du
writer, et le marqueur de fermeture propre. Invariants : `NoMix` (aucun nom de run ne pointe vers un contenu qui n'est
pas entier et forcé), `SnapshotInJournal` (un nom de run seulement pour des groupes durables ; la recovery n'en rencontre
jamais un en avance sur le journal), `ChainNamed` (les runs que lit un processus sont nommés et forment une chaîne
depuis 0), `PublishedDurable` (G5, après une recovery aussi), `AckedDurable` (G1). Bornes dans `spec/Merge.cfg`
(3 groupes : 6 runs possibles) : 983 080 états distincts, profondeur 51, 13 s ; avec 4 groupes, pas de fin en 12
minutes. Ses cinq règles sont des constantes : mettez l'une de `ForceBeforeRename`, `InstallWhenDurable`,
`ForceAtRecovery`, `MarkerOnlyIfClean`, `RewriteAtRecovery` à FALSE et TLC affiche un contre-exemple de 4 ou 5 étapes.

`spec/LocalReads.tla` modélise les lectures locales (G15, [le serveur](server.md#lectures-locales-g15)) : un serveur
qui écrit des frames une à la fois, envoie chacune à ses lecteurs avant son fsync et répond à ses writers après ; des
lecteurs qui appliquent des frames depuis un canal qui garde ses octets au-delà de la mort du serveur, et remarquent
la mort plus tard ; les lectures des programmes dans chaque lecteur et au serveur, chacune un intervalle (elle
commence, prend un état, le rend). L'invariant `Linearizable` vérifie trois conditions sur chaque lecture quand elle
revient, Fresh, Ordered et Durable, avec des identifiants d'écriture pour distinguer un groupe qu'une mort a perdu et un
groupe plus tardif de même numéro. La constante `Rule` choisit comment un groupe devient visible :

| configuration | règle | bornes | résultat |
|---|---|---|---|
| `LocalReads.cfg` | celle qui est construite (le numéro de visibilité) | 2 lecteurs (symétriques), lectures distantes, 3 écritures | tient : 3 436 820 états distincts |
| `LocalReadsCrash.cfg` | celle qui est construite | 1 lecteur, lectures distantes, 3 écritures, une mort du serveur (sa frame en vol gardée ou perdue) | tient : 210 716 |
| `LocalReadsLive.cfg` | celle qui est construite | 1 lecteur, 2 écritures | `NeverReadsAll` casse, comme il le doit : les lectures rendent bien le groupe le plus récent |
| `LocalReadsNoSkip.cfg` | pas de 2 ajouté à un départ | 1 lecteur, 3 écritures, une mort | casse Fresh (8 états) |
| `LocalReadsEarly.cfg` | le numéro rangé avant le fsync | 1 lecteur, 2 écritures, une mort | casse Durable (6 états) |
| `LocalReadsRemoteFirst.cfg` | les lectures distantes déplacées au fsync, avant le numéro | 1 lecteur, 2 écritures | casse Ordered (8 états) |
| `LocalReadsDesign.cfg` | le lease de la conception (un droit limité dans le temps) | 1 lecteur, 2 écritures, 4 tics, des leases de 2 | casse Ordered (7 états) |
| `LocalReadsDesignFresh.cfg` | le lease de la conception | pareil | `NoStale` (Fresh et Durable) tient : 289 765 |
| `LocalReadsDraft.cfg` | le premier brouillon de la conception | pareil | casse `NoStale` : Fresh (12 états) |

`spec/WatchWindow.tla` modélise la fenêtre (window) d'un watch avec `Sort` et `Limit` ([Sort et Limit dans un
watch](cesia.md#sort-et-limit-dans-un-watch)) : la réponse un bag (un ensemble où une ligne peut revenir) de 4 lignes
dans leur ordre, chacune avec jusqu'à 2 copies, le Limit de 0 à 3, et chaque frame (n'importe quelles lignes retirées,
n'importe quelles lignes ajoutées) portée dans la fenêtre par sa règle. Invariants : `RowsRight` (la fenêtre est les
lignes de `Find`, les k premières et les copies de la k-ième), `CompleteRight` (quand elle dit tenir toute la réponse,
elle la tient), `NothingLost` (une ligne retirée à la dernière de la fenêtre ou avant était tenue). Ils tiennent dans
374 états distincts (167 278 transitions, 4 s) ; `WatchWindowNoRefill.cfg` (pas de remplissage),
`WatchWindowNoTies.cfg` (une coupe qui sépare les copies de la k-ième ligne) et `WatchWindowStrict.cfg` (« avant la
dernière » au lieu de « à la dernière ou avant ») cassent chacune `RowsRight`, et `tools/tlc.sh` échoue si elles ne le
font pas.

`spec/CommitBuffer.tla` modélise le commit buffer du serveur ([le serveur](server.md#plusieurs-bases-un-seul-fsync--le-commit-buffer)) :
des bases dont les syncers (le thread qui fait les fsync d'un journal) écrivent chaque frame dans leur journal sans
fsync et la donnent au buffer, une frame en cours par base ; des rounds (des tournées) de toutes les frames arrivées entre-temps,
ajoutées et forcées une seule fois, un round en cours ; des frames forcées dans leur propre journal (les longues, et
une qui arrive quand le buffer est au repos) ; des checkpoints qui forcent un journal ; le round le plus ancien
abandonné une fois que chacune de ses frames est couverte par un checkpoint ; F1 (une mort du processus, le page cache
gardé), F2 (une coupure de courant : chaque frame non forcée d'un journal perdue, gardée ou torn, chacune pour elle ;
les rounds du buffer après ceux qui sont forcés gardés jusqu'à un certain round), F4 (un fsync qui échoue, du buffer ou
d'un journal à un checkpoint, marque ses pages clean et arrête le buffer) ; et la recovery avec la règle telle qu'elle
est construite (le round le plus récent du buffer, s'il est torn, coupé ; chaque frame qu'il a gardée écrite de nouveau
à sa place ; chaque autre frame avant la dernière d'entre elles doit se vérifier ; la règle propre du journal après).
Invariants : `Durable` (G1 : chaque fois que le serveur tourne, chaque frame confirmée est dans son journal), `Prefix`
(G3), `NeverRefused` (aucun dommage n'est modélisé, donc aucune ouverture ne peut refuser : G6), `CheckpointOnDisk` (un
checkpoint ne couvre que des frames que le disque tient). Bornes dans `spec/CommitBuffer.cfg`, 2 bases de 2 frames
chacune : 11 313 états distincts ; avec 3 frames chacune (`MaxFrames = 3`, pas dans `tools/tlc.sh`) : 206 395 états
distincts, profondeur 25, 9 minutes sur 4 workers. Chaque variante qui retire une partie de la règle casse :

| configuration | la règle sans | casse |
|---|---|---|
| `CommitBufferTrust.cfg` | les frames du buffer à la recovery : chaque journal par sa propre règle | `Durable` |
| `CommitBufferEarly.cfg` | le checkpoint : un round abandonné dès que ses frames sont dans le page cache de leurs journaux | `Durable` |
| `CommitBufferCkpt.cfg` | l'arrêt après un fsync qui échoue : un checkpoint après lui | `CheckpointOnDisk` |
| `CommitBufferMany.cfg` | une seule frame en cours : une base écrit sa frame suivante avant que la précédente soit confirmée (1 base, 3 frames) | `NeverRefused` |

Le modèle prend les écritures de la recovery pour forcées, comme le code doit les rendre : la première version du code
sautait une frame dont le page cache montrait déjà les octets, ce que le modèle ne peut pas voir et que la simulation
a trouvé ([plus haut](#le-commit-buffer)).

`spec/RuleChange.tla` modélise un changement des règles par le chemin en arrière-plan ([règles](rules.md#les-changements-des-règles-en-arrière-plan),
G19) : trois faits affirmés et deux dérivés, d'anciennes règles et de nouvelles (les nouvelles avec une contrainte), un
writer qui valide des groupes sous ses règles, en frames de faits avec leurs états après, un changement C qui affirme
aussi un fait et en attend un autre ; la construction à partir de la vue de travail, le rattrapage par batches (des
lots) de n'importe quelle taille, le switch (le passage aux nouvelles règles) par le writer, des crashs qui gardent
n'importe quel préfixe des frames à partir des frames durables, et la reprise d'un membre Raft (les frames que Raft n'a
pas validées reprises, la vue de travail ramenée à la vue publiée, une nouvelle lignée : un changement commencé sur une
plus ancienne reçoit une réponse, il n'est jamais installé) ; les vues comme le moteur les garde, des couches de runs
et un delta, avec les faits dérivés du changement dans un run à eux, R, sous le delta de sa vue, la table des
différences fait par fait, et un merge qui nomme sur le disque l'état de la vue de travail. Invariants :
`ViewsExact` (la vue de travail et la vue publiée, et l'état à chaque frame du journal, sont le least model de leurs
faits affirmés sous leurs règles : aucune vue ne mêle les faits des anciennes règles à ceux des nouvelles),
`JournalIsWork` (le replay donne la vue de travail :
la frame de C est exactement la différence que tient la vue adoptée), `OneSwitch` (les règles changent à la frame de
C), `ConstraintsHold` (G18), `Serial` (l'`Expect` de C tenait juste avant C, son fait affirmé à C), `NoLostWrite` (la
frame de C ne change aucun fait affirmé sauf le sien), `AckedDurable`, `ChangeViewExact` (la vue du changement, lue à
travers ses couches, est le least model sous les nouvelles règles), `TableExact` (la table et R sont la différence
entre l'état du writer là où en est l'arrière-plan et la vue du changement), `RunsExact` (les runs nommés sur le disque
tiennent l'état du journal à leur groupe) ; et la propriété de liveness `Ends` (une
liveness dit qu'une chose finit par arriver : sous fairness, c'est-à-dire si chaque étape toujours possible finit par
être prise, le changement est installé, répondu ou perdu dans un crash). Bornes dans `spec/RuleChange.cfg` (4 groupes
de données, 2 crashs, la construction prête à 2 groupes de retard, 1 reprise, 1 merge) : 1 200 400 états distincts,
4 min 12 s sur 4 workers, tout tient. Chaque partie de la règle est nécessaire (les variantes sont sans reprise, sauf
`RuleChangeTakeBack.cfg`) :

| configuration | la règle sans | casse |
|---|---|---|
| `RuleChangeCopy.cfg` | les faits dérivés retrouvés : la frame d'un groupe du journal copiée | `ChangeViewExact` |
| `RuleChangeLate.cfg` | le dernier rattrapage du writer | `JournalIsWork` |
| `RuleChangeEarlyExpect.cfg` | l'`Expect` vérifié à l'installation : à la construction | `Serial` |
| `RuleChangeNoCheck.cfg` | la vérification de l'état rattrapé par les nouvelles règles | `ConstraintsHold` |
| `RuleChangeOverlap.cfg` | le `Conflict` d'un groupe qui touche le fait de C | `Serial` |
| `RuleChangeStale.cfg` | la différence à l'installation : les propres changements de la construction écrits | `ViewsExact` |
| `RuleChangePublished.cfg` | la construction à partir de la vue de travail : à partir de la vue publiée | `TableExact` |
| `RuleChangeTakeBack.cfg` | l'installation sur la propre lignée du changement (Raft) : installé après une reprise | `ViewsExact` |
| `RuleChangeShadowed.cfg` | R ne prend que les faits pour lesquels le delta de la vue forkée n'a pas d'entrée : il les prend tous | `ChangeViewExact` |
| `RuleChangeUntracked.cfg` | un fait de R entre dans la table comme (absent, dérivé) : comme son état avant l'étape | `TableExact` |
| `RuleChangeNoTombstone.cfg` | un fait de R dont les deux états sont d'accord reste dans la table : retiré | `TableExact` |
| `RuleChangeNamed.cfg` | R jamais nommé : nommé avec les runs en dessous une fois la frame de C durable | `RunsExact` |
| `RuleChangeMergeSkipsRun.cfg` | chaque merge prend R : un merge le laisse en dessous | `RunsExact` |

`tools/tlc.sh` les lance tous et échoue sauf si chacun de ceux qui doivent casser casse : 1 min 57 s sur la machine de
test (2026-11-12), tous les modèles compris.

## Pour aller plus loin

Zhou et al., FoundationDB (SIGMOD 2021) ; Pillai et al., ALICE (OSDI 2014) ; Bornholt et al., lightweight formal
methods in Amazon S3 (SOSP 2021) ; Claessen et Hughes, QuickCheck (ICFP 2000) ; Lamport, Specifying Systems (2002) ;
Yu, Manolios, Lamport, TLC (CHARME 1999) ; Newcombe et al. (CACM 2015) ; Kingsbury et Alvaro, Elle (PVLDB 2020) ;
Steele, Lea, Flood, SplitMix (OOPSLA 2014). Les entrées : [références](references.md#les-tests-et-la-vérification).
