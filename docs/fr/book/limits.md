# Limites et valeurs par défaut

Chaque borne et chaque valeur par défaut du moteur, avec l'endroit du code où elle est fixée. Les réglages nommés
`Module.x` sont des références internes (`Cepheus.Engine.compact_min := ...`), pour les tests et les benchmarks ; une
application utilise les valeurs par défaut, et la taille du cache (`set_cache`).

## Choses, propriétés, valeurs

| quoi | limite ou valeur par défaut | où |
|---|---|---|
| numéros de chose | à partir de 65 536, denses, dans l'ordre où les choses sont créées | `Schema.first_thing` |
| numéros de chose | au plus 2 147 483 647 ($2^{31} - 1$) : un run range la plus petite chose d'un row block sur 4 octets, un grand groupe une chose sur 4 octets, et une partie compte les choses qu'elle contient dans les 32 bits hauts du mot de 64 bits d'une rank table, relu dans l'`int` de 63 bits d'OCaml (31 bits). Un groupe qui ferait un numéro plus grand est refusé avec `Invalid "thing numbers end at 2147483647: this group would make #N"` ; rien ne repart à zéro | `Schema.last_thing`, `Resolve.resolve` |
| numéros de propriété | de 16 à 65 535 (l'entrée d'un thing block range sa propriété sur 2 octets) : 65 520 propriétés par base ; `declare` prend le plus petit numéro libre | `Schema.first_prop`, `Snapshot.tblock_flush` |
| propriétés système | 1 `cepheus/name`, 2 `cepheus/type`, 3 `cepheus/many`, 4 `cepheus/unique`, 5 `cepheus/rule` ; 0 et 6 à 15 réservés | `Schema.system` |
| `Int`, `Date`, `Money` | des entiers signés de 63 bits : de $-2^{62}$ à $2^{62} - 1$ | l'`int` d'OCaml |
| chiffres de `Money` | de 0 à 18 (`Tmoney 19` est refusé : code de type inconnu) | `Value.of_code` |
| `Float` | n'importe quel double IEEE ; chaque valeur distincte prend une entrée de dictionnaire de 8 octets | `Store.float_key` |
| `Text` | n'importe quels octets, de n'importe quelle longueur que peut contenir un groupe (plus bas) | |
| textes et floats distincts | moins de $2^{32}$ par run (la table de hachage d'un run range la place d'un texte sur 4 octets) | `Snapshot.merge` |
| valeurs d'une chose pour une propriété | moins de $2^{32}$ dans un run (l'entrée d'un thing block compte sur 4 octets) ; un merge qui dépasserait cette limite échoue avec `Invalid_argument` | `Snapshot.tblock_flush` |
| `by` | n'importe quel `int` (0 par défaut) | `Cepheus.write` |
| `why` | n'importe quel texte (`""` par défaut) | `Cepheus.write` |

## Les écritures

| quoi | limite ou valeur par défaut | où |
|---|---|---|
| un groupe | son codage doit rester dans 256 MiB (268 435 456 octets, le plus grand corps de frame) : un groupe plus grand est refusé avec `Invalid "a group of N bytes is over the frame limit of 268435456"`, et le writer continue | `Journal.max_body`, `Engine.too_large` |
| plusieurs groupes à la fois | les groupes résolus ensemble vont dans une même frame seulement tant que son corps reste dans 256 MiB : un groupe qui dépasserait attend la frame suivante, et un grand groupe commence une frame à lui, donc une frame ne dépasse jamais la limite | `Engine.frame_limit`, `Engine.prepare`, `Engine.writer` |
| un grand groupe | 20 000 opérations ou plus, toutes des `Add` : le chemin rapide (des tableaux, des tris, un run fusionné d'un coup ; avec des règles, ses faits dérivés ajoutés à la suite) ; en dessous, ou au moindre doute (une contrainte, la tête d'une règle sur une propriété à une valeur ou unique, un fait déjà dérivé maintenant affirmé), le chemin ordinaire | `Resolve.large_min`, `Reason.bulk` |
| changements dérivés d'un groupe | au plus $100\,000 + 100 \times \text{ses changements affirmés}$, sinon refusé, en nommant la règle qui a dérivé le plus | `rule_budget` (`Reason.budget_base`, `Reason.budget_per`) |
| une règle | 1 pattern ou plus, au plus 64 variables ; la propriété d'un pattern est une constante | `Rules.check` |
| opérations dans un groupe | aucune autre limite ; chaque `Expect` est vérifié sur l'état d'avant le groupe | |
| un batch | jusqu'à 4 096 écritures en attente résolues d'un coup | `Engine.max_batch` |
| une frame | les batches résolus pendant un fsync rejoignent la frame en attente jusqu'à ce que son corps dépasse 8 MiB ; ensuite le writer attend le fsync | `Engine.max_frame` |
| un segment | un nouveau segment commence quand la frame suivante ferait dépasser 64 MiB au segment courant | `Journal.segment_limit` |
| surcoût d'une frame | 44 octets (un en-tête de 28 octets et un trailer de 16 octets) | `Journal.fh`, `Journal.ft` |
| en-tête de segment | 40 octets | `Journal.seg_header` |
| writers | un par base (le thread writer de son domain) | `Engine.start` |

## Les merges et les runs

| quoi | limite ou valeur par défaut | où |
|---|---|---|
| quand un merge démarre | quand les changements depuis le dernier merge dépassent 200 000 | `Engine.compact_min` (200 000), `Engine.needs_compaction` |
| niveaux | le niveau $l$ (1, 2, 3, ...) contient au plus $200\,000 \times 4^l$ lignes : 800 000, 3,2 M, 12,8 M, 51,2 M, ... ; les lignes d'un run sont ses ajouts et ses retraits | `Engine.ratio` (4), `Engine.cap` |
| ce que prend un merge | le delta et les runs les plus récents, jusqu'au premier niveau dont la capacité les contient tous ; un seul run y est écrit | `Engine.plan` |
| `snapshot` | le delta et tous les runs en un seul run, au niveau le plus profond parmi les runs, ou plus profond s'ils n'y tiennent pas ; rien s'il n'y a qu'un run et aucun groupe depuis le dernier merge | `Engine.plan_all`, `Engine.snapshot` |
| ce qui compte comme un changement | chaque ajout ou retrait appliqué depuis le dernier merge (un changement défait plus tard compte deux fois) | `Store.change` (`dn`) |
| rattrapage | le merge rejoue les groupes écrits entre-temps jusqu'à avoir moins de 256 groupes de retard ; ensuite le writer rejoue le reste et bascule | `Engine.catch_up` |
| les fsyncs d'un merge | tous les 8 MiB pendant que le journal écrit, sinon une fois à la fin | `Snapshot.sync_every` |
| après un merge qui a échoué | le suivant attend que le delta ait grandi d'un seuil de plus | `Engine.finish_merge` |
| fichiers de runs gardés | la chaîne depuis 0 jusqu'au groupe le plus récent (aucun secours hors d'elle : le journal reconstruit n'importe quel run) ; le fichier d'un merge en fait un de plus pendant qu'il est écrit | `Snapshot.install` |
| en-tête de run | 4 096 octets | `Snapshot.header` |
| page | 16 KiB (16 384 octets) | `Pages.bits` (14) |
| table des pages | 8 octets par page de la disposition du run (la page du fichier qui la contient, son CRC) | `Snapshot.merge` |
| thing block, row block, bloc d'offsets | 128 choses, 128 lignes d'une propriété, 128 offsets | `Store.tb` |
| format des runs | 8 ; les runs des formats 5, 6 et 7 et les snapshots des formats 1 à 4 (`<group>.snap`) sont mis de côté à l'ouverture, le journal rejoué, et le premier merge les supprime | `Snapshot.format` |
| format du journal | 2 ; un journal de format 1 est converti une fois à l'ouverture | `Journal.format`, `Journal.convert` |

## La mémoire et le cache

| quoi | limite ou valeur par défaut | où |
|---|---|---|
| le cache | 1 GiB (65 536 pages) pour tout le processus | `Pages.capacity`, `set_cache` |
| plus petit cache | 16 pages (256 KiB) : `set_cache` arrondit vers le haut ce qui est en dessous | `Pages.set_capacity` |
| la petite file de S3-FIFO | un dixième du cache | `Pages.make_room` |
| ghost queue | autant de clés que le cache a de pages | `Pages.make_room` |
| le compteur d'une page | 2 bits (de 0 à 3) | `Pages.touch` |
| pages en mémoire | sous 1,25 fois le cache : une collection complète après chaque quart du cache évincé (256 pages, 4 MiB, au moins) | `Pages.room` |
| un run lu en entier à l'ouverture | quand ses pages tiennent dans le cache | `Snapshot.check_and_build` |
| un merge | le cache, au plus 2 buffers de page pour chacun des 18 flux de la passe par propriété (11 mesurés), 25 octets par page de la disposition du nouveau run, le bloc en cours de codage, et la table de hachage des textes du nouveau run (8 octets par texte) | [théorie](theory.md#8-les-merges-écrits-dans-un-fichier) |
| un grand groupe | la liste d'opérations de l'appelant (72 octets par `Add` et sa valeur : 883 MB pour 9,4 M), 14 octets par fait dans l'ordre du groupe et 12 par propriété (des Bigarrays), la place du radix sort pour sa plus grande propriété sur chacun de 2 domains, et le reçu (une paire par nouvelle chose), le codage du groupe pour le journal (21,6 MB à 9,4 M de faits, construit en mémoire, puis écrit par morceaux de 1 MiB) : environ 1,5 GB au pic d'un chargement de 10 M de faits en deux groupes, dont 0,88 GB pour la liste de l'appelant | mesuré ([benchmarks](benchmarks.md#le-chargement-en-parallèle-et-sans-copies-2026-11-08-à-10-millions-de-faits)) |
| le delta | environ 170 octets par changement, jusqu'au merge suivant | mesuré |
| les runs | environ 5,4 octets par fait à 10 M de faits (les données du benchmark), lus à travers le cache ; 17 octets par page de la disposition d'un run pour les tables du cache | mesuré |
| recovery | chaque segment à travers une fenêtre de 4 MiB ; une frame plus longue que la fenêtre est vérifiée par morceaux et lue en entier seulement pour rejouer ses groupes ; une frame qui ne passe pas la vérification est lue en entier depuis son offset jusqu'à la fin du segment, pour décider entre torn write et dommage | `Journal.window`, `Journal.scan` |
| `verify` | la même fenêtre ; chaque frame décodée, une plus longue lue en entier | `Journal.read` |

## Les questions

| quoi | limite ou valeur par défaut | où |
|---|---|---|
| variables | au plus 63 (de 0 à 62 : le planner garde les variables liées dans les bits d'un `int`) | `Query.order` |
| ordres de variables essayés | chaque ordre jusqu'à 7 variables (avec élagage) ; un choix glouton au-delà | `Query.order` |
| questions en parallèle | quand la première variable a 20 000 candidats ou plus | `Query.parallel_min` |
| domains d'une question | le nombre recommandé pour la machine, au plus 8 | `Query.domains` |
| slices | $\min(\text{candidats}, 16 \times \text{domains})$, prises à tour de rôle sur un compteur partagé | `Query.fold` |
| la propriété d'un pattern | une constante : pas de variable à la place de la propriété | `Query.pattern` |

## Les fichiers et la plateforme

| quoi | limite ou valeur par défaut | où |
|---|---|---|
| processus | un moteur par base : un lock exclusif `lockf` sur `DIR/lock`, gardé jusqu'à la fermeture ou la mort du processus ; à l'intérieur d'un processus, une table des locks tenus indexée par le device et l'inode du fichier de lock, donc chaque chemin vers le répertoire est une seule base | `Disk.real.lock` |
| `DIR/cepheus` | 37 octets : 17 de nombre magique, 16 d'id, 4 de CRC | `Engine.read_meta` |
| descripteurs de fichier | un pour le segment courant du journal, un pour chaque fichier de run que tient une vue vivante (fermé quand plus aucune vue ne tient le run et que le garbage collector le libère) | `Snapshot.check_and_build` |
| fichiers de runs | machines 64 bits little-endian (la disposition en mémoire) ; le journal est portable | [formats](formats.md) |
| durabilité | repose sur le fait que `fsync` veut dire durable, pour les fichiers et pour les répertoires (Linux et ses systèmes de fichiers habituels) | [exploitation](operations.md#les-disques) |
| OCaml | 5 (les domains), avec `unix` et `threads`, et son compilateur C pour `src/crc32c_stubs.c` | `src/dune` |
| processeur | x86-64 avec SSE4.2 (qui fait partie du niveau x86-64-v2 ; Intel depuis Nehalem, 2008, AMD depuis Bulldozer, 2011), ou arm64 avec les instructions CRC32 (facultatives dans ARMv8.0, obligatoires à partir d'ARMv8.1), sous Linux ou macOS ; un autre processeur est refusé au démarrage du programme, une autre architecture ne compile pas | `src/crc32c_stubs.c` |

## Le serveur

| quoi | limite ou valeur par défaut | où |
|---|---|---|
| une frame | au plus 16 MiB de corps (une longueur au-delà reçoit la réponse `too_large` et la connexion se ferme avant que le corps soit lu) ; un en-tête de 10 octets | `Wire.max_frame`, `Wire.header` |
| écritures en cours par connexion | 1 024 (annoncé dans Welcome) ; à la limite, le serveur arrête de lire le socket | `Core.create ~max_inflight` |
| la réponse d'un Find | des frames d'environ 1 MiB de lignes (toutes sauf la dernière avec l'indicateur more) | `Core.chunk` |
| variables d'une question sur le réseau | 64 | `Wire.get_query` |
| les reçus d'une session | au plus 4 096 ; oubliés une heure après la dernière écriture de la session | `Sessions.max_receipts`, `Sessions.expiry_ms` |
| le checkpoint des sessions | écrit chaque seconde tant que des écritures arrivent, et à l'arrêt | `Net.checkpoint` |
| tokens.toml | relu moins d'une seconde après un changement | le ticker de `Net.serve` |
| un token | 32 octets aléatoires, `cph_` et 43 caractères de base64url ; au plus 256 caractères sont regardés | `Tokens.generate`, `Tokens.check` |
| I/O domains | `[clients] domains`, de 1 à 64 ; par défaut $\min(4, \text{cœurs} / 2)$ | `Config.default_domains` |
| le page cache | `[storage] cache`, 1 GiB par défaut | `Config.of_toml` |
| le socket Unix | `.s.cepheus.PORT`, PORT étant le port de `listen` ou 7400 | `Config.socket_name` |
| peers | exactement un dans cette version | `Config.of_toml` |
| TLS | 1.3 seulement ; certificats : ECDSA P-256, la CA valable 3 650 jours, les autres 825 | `server/tls_stubs.c`, `bin/main.ml` |
| les threads des connexions | un par connexion (et un de plus tant qu'elle a des écritures en cours) | `Net.connection` |
| la file d'un lecteur local | 64 MiB de frames pas encore envoyées ; au-delà, le lecteur est coupé et suit de nouveau | `Follow.max_behind` |
| descripteurs par message | 64 (une base avec plus de runs que cela ne peut pas être suivie ; une base en a quelques-uns, un par niveau) | `Fdpass.max_fds` |
| la page de visibilité | 4 KiB par base (`/dev/shm/cepheus-ID.visible`), le numéro dans ses 8 premiers octets | `Fdpass.page_size`, `Follow.page_path` |
| le page cache d'un lecteur local | 256 MiB, fixé pour le processus quand il suit sa première base (`Client.local_cache`) | `Client.follow` |
| les frames d'un follow stream | la frame du writer, en frames réseau d'au plus 1 MiB de groupes (l'indicateur `more`) | `Net.piece` |
| connexions | `[clients] max_connections`, de 1 à 65 536 ; 512 par défaut ; au-delà, une nouvelle connexion est fermée dès son accept (`too_many_connections` sur le socket Unix) | `Config.default_max_connections`, `Net.serve` |
| une connexion inactive | `[clients] idle_timeout` secondes, de 0 à 604 800 (0 : aucune limite) ; 600 par défaut : une requête entière dans ce délai depuis l'accept (le handshake TLS compris) et depuis la requête précédente, et ce que le serveur envoie, pris dans ce délai | `Config.default_idle_timeout`, `Net.timeouts` |
| le handshake d'un client | 5 s pour la connexion, TLS et Hello (et le Follow et le Start d'un follow stream), ensuite le socket attend aussi longtemps qu'il le faut ; au-delà, la tentative est abandonnée comme coupée et retentée dans le budget de nouvelles tentatives | `Client.handshake_timeout` |
| le budget de nouvelles tentatives d'un client | 30 s d'essais pour se reconnecter après une connexion coupée ; ensuite `unreachable` (une écriture en cours a été appliquée une fois ou pas du tout) | `Client.retry_budget` |

## Les outils de mesure

| quoi | valeur | où |
|---|---|---|
| `Histogram` | exact sous 256 µs, ensuite 128 cases par puissance de deux : chaque percentile à 1/128 près (0,8 %) ; 3 584 compteurs | `src/histogram.ml` |
| le secteur du disque simulé | 512 octets, l'unité de perte et de déchirure | `Sim_disk.sector` |
| exécutions d'un benchmark | 21 (`RUNS`), la médiane et son intervalle à 95 % $[x(6), x(16)]$, une couverture de 97,3 % | `bench/stats.ml` |
