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
| un grand groupe | 20 000 opérations ou plus, toutes des `Add` : le chemin rapide (des tableaux, des tris, un run fusionné d'un coup ; avec des règles, ses faits forment un préfixe trié du working set, l'ensemble des faits sur lequel le raisonnement travaille, et ses faits dérivés sont fusionnés dans ses ordres) ; en dessous, ou au moindre doute (une règle qui dérive avec un `Not` ou un agrégat, une contrainte enfreinte, une seconde valeur d'une propriété à une valeur), le chemin ordinaire | `Resolve.large_min`, `Reason.bulk` |
| changements dérivés d'un groupe | au plus $100\,000 + 100 \times \text{ses changements affirmés}$, sinon refusé, en nommant la règle qui a dérivé le plus | `rule_budget` (`Reason.budget_base`, `Reason.budget_per`) |
| changements dérivés d'un changement des règles ou de l'ontologie | au plus $100\,000 + 100 \times \text{ses changements affirmés} + 4 \times \text{les faits de la base}$ | `change_budget` (`Reason.change_per`) |
| les changements en arrière-plan | un à la fois (le suivant attend) ; aucun à côté d'un merge en arrière-plan ; le writer attend celui qui a plus de 65 536 groupes de retard ; un changement qui crée de nouvelles choses est calculé dans son groupe | `Engine.change_backlog` |
| les tours sur plusieurs domains | à partir de 20 000 faits par tour (une étape du raisonnement), jusqu'à 4 domains (des fils d'exécution d'OCaml qui tournent en parallèle, chacun sur son cœur ; `Bulk.domains`), des règles sans `Not` ni agrégats, dans un groupe que le writer raisonne lui-même (pas un changement en arrière-plan) | `Reason.par_min` |
| une règle | 1 pattern ou plus, au plus 64 variables ; la propriété d'un pattern est une constante, ou une variable liée par un pattern dont la propriété est une constante | `Rules.check` |
| une petite relation (sur laquelle on déplie) | au plus 10 000 faits, d'après les comptes exacts ; au plus 10 000 règles dépliées (réécrites en une règle par fait de la relation) à partir d'une même règle | `Reason.small_limit`, `Reason.unfold_limit` |
| un template | un seul pattern `every` par règle (un template est une règle dont un pattern se répète pour chaque membre d'une liste), sans `Not` ni agrégat à côté ; une liste d'au plus 64 membres (un groupe qui en fait une plus longue est refusé, en nommant la règle) ; aucune règle ne donne la propriété d'une liste | `Reason.template_limit`, `Rules.check` |
| l'égalité (`cepheus/same`) | deux valeurs ne sont jamais la même chose, ni deux propriétés, ni une chose que nomme une règle ; pas de `Not` ni d'agrégat dans un ensemble de règles qui rend des choses égales ; avec l'égalité, les modules de closure (qui calculent une transitive closure, toutes les paires reliées par un chemin), le chemin des chargements et les tours sur plusieurs domains sont coupés | `Reason.apply_merges`, `Resolve` |
| OWL 2 RL (`Cepheus.Owl`) | le profil de règles du langage d'ontologies OWL du W3C : des chaînes de propriétés de deux liens (une plus longue par des propriétés du programme) ; `owl/HasValue` une chose et `owl/TargetValue` un texte (d'autres valeurs : une règle du programme) ; AllDifferent, AllDisjointClasses, AllDisjointProperties comme leurs paires ; `Why` donne la réécriture d'une égalité, pas la preuve propre de l'égalité ; depuis Cesia (`cesia/cepheus/owl`), pas de `Why`, et les axiomes n-aires écrits comme leurs paires par le programme | `src/owl.ml` |
| un module de closure | prp-trp (la règle d'OWL 2 RL d'une propriété transitive), ou la paire linéaire (chaque arête donne un fait de la closure, et une arête suivie d'un fait de la closure en donne un) sur une autre propriété, avec des variables distinctes, sans constante, sans intervalle ; sur une propriété de liens qui prend plusieurs valeurs, pas unique ; un module par propriété | `Reason.find_modules` |
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
| le merge d'un grand groupe | le delta et les runs les plus récents des niveaux en dessous de celui qui le contient ; son run reste à côté des runs de ce niveau tant qu'il n'y en aurait pas 16 côte à côte ; alors tous sont fusionnés | `Engine.tier` (16), `Engine.plan_large` |
| les runs que prend un merge | au plus 31 (le passage par chose garde les sources d'une chose dans les bits d'un entier, deux par run) ; une base a au plus 16 runs, plus un par niveau | `Snapshot.max_take` |
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
| format des runs | 9 ; les runs des formats 5 à 8 et les snapshots des formats 1 à 4 (`<group>.snap`) sont mis de côté à l'ouverture, le journal rejoué, et le premier merge les supprime | `Snapshot.format` |
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
| les tables d'un run plus grand, lues à l'ouverture | quand leurs pages tiennent dans la place qui reste au cache ; lues dans l'ordre du fichier, jusqu'à 64 pages du fichier (1 MiB) par lecture, par jusqu'à 4 domains à partir de 64 pages | `Snapshot.check_and_build` |
| un merge | le cache, au plus 2 buffers de page pour chacun des 18 flux de la passe par propriété (11 mesurés), 25 octets par page de la disposition du nouveau run, le bloc en cours de codage, et la table de hachage des textes du nouveau run (8 octets par texte) | [théorie](theory.md#8-merges-écrits-dans-un-fichier) |
| un grand groupe | la liste d'opérations de l'appelant (72 octets par `Add` et sa valeur : 883 MB pour 9,4 M), 14 octets par fait dans l'ordre du groupe et 12 par propriété (des Bigarrays), la place du radix sort pour sa plus grande propriété sur chacun de 2 domains, et le reçu (une paire par nouvelle chose), le codage du groupe pour le journal (21,6 MB à 9,4 M de faits, construit en mémoire, puis écrit par morceaux de 1 MiB) : environ 1,5 GB au pic d'un chargement de 10 M de faits en deux groupes, dont 0,88 GB pour la liste de l'appelant | mesuré ([benchmarks](benchmarks.md#le-chargement-en-parallèle-et-sans-copies-2026-11-08-à-10-millions-de-faits)) |
| le delta | environ 170 octets par changement, jusqu'au merge suivant | mesuré |
| les runs | environ 5,4 octets par fait à 10 M de faits (les données du benchmark), lus à travers le cache ; 17 octets par page de la disposition d'un run pour les tables du cache | mesuré |
| recovery | chaque segment à travers une fenêtre de 4 MiB ; une frame plus longue que la fenêtre est vérifiée par morceaux et lue en entier seulement pour rejouer ses groupes ; une frame qui ne passe pas la vérification est lue en entier depuis son offset jusqu'à la fin du segment, pour décider entre torn write et dommage | `Journal.window`, `Journal.scan` |
| `verify` | la même fenêtre ; chaque frame décodée, une plus longue lue en entier | `Journal.read` |

## Les questions

| quoi | limite ou valeur par défaut | où |
|---|---|---|
| variables | au plus 64, la borne du wire protocol, le format des messages sur une connexion (plus bas) ; les estimations du planner (la partie qui choisit l'ordre d'évaluation d'une question) gardent les variables liées dans les bits d'un `int`, de 0 à 62 : la 64e est placée par un indicateur à elle et estimée comme non liée | `Query.order` |
| l'ordre des variables | le meilleur ordre pour son travail estimé, par une programmation dynamique sur les sous-ensembles des variables qui ne sont ni un champ d'une chose ni celui d'une constante (celles-là ont une place connue), jusqu'à 12 d'entre elles ($n 2^{n-1}$ étapes) ; un choix glouton au-delà | `Query.order`, `Query.dp_max` |
| questions en parallèle | quand la première variable a 20 000 candidats ou plus | `Query.parallel_min` |
| domains d'une question | le nombre recommandé pour la machine, au plus 8 | `Query.domains` |
| slices | $\min(\text{candidats}, 16 \times \text{domains})$, prises à tour de rôle sur un compteur partagé | `Query.fold` |
| le leapfrog d'un niveau (l'intersection où chaque liste triée saute à son tour jusqu'à la plus grande clé) | les slices (les tranches de listes triées) parmi les 62 premiers patterns d'une variable dont le compte est au plus 8 fois celui de la source ; ses autres patterns sont vérifiés un par un | `Query.fold` |
| la propriété d'un pattern | une constante : pas de variable à la place de la propriété | `Query.pattern` |
| Sort, Limit, After | les clés : des colonnes du select (ce que la question renvoie), une clé par colonne au plus ; Limit de 1 à 100 000 lignes par page (0 sur le wire : aucune limite), plus les copies de sa dernière ligne, pour `Find` comme pour `Watch` (un watch tient autant de lignes) ; After a besoin de Sort et d'une valeur de son type pour chaque colonne, sinon `invalid` ; un watch ne prend ni After, ni Limit sans Sort, ni l'un ou l'autre avec des agrégats | `Top.check`, `Top.max_limit`, `Live.subscribe` |
| Prefix | de 1 à 1 024 octets ; une variable texte qu'un pattern donne comme sa valeur | `Ask.max_prefix` |
| Not, Or, And, In | Not et And : de 1 à 4 patterns et conditions ; Or : de 2 à 4 alternatives ; In : au plus 100 000 valeurs (au plus les lignes d'une page : les ids d'une page reviennent en une seule question) ; au plus 64 opérateurs et leurs éléments dans une question, et ses Or au plus 64 questions à poser (le produit de leurs alternatives) ; pas de Not ni de Or dans Not et Or | `Ask.compile`, `Ask.max_in`, `Ask.max_operators`, `Ask.max_conjunctions` |
| le travail d'une question au serveur | 1 000 000 000 de candidats de son join (la jointure de ses patterns) par domain, les questions propres à ses Not comptées avec : au-delà, `too_large` ("the question passed the server's budget") ; un watch (une question vivante, tenue à jour) qui le dépasse à une frame se termine par `too_large` ; un programme qui lit dans sa propre mémoire n'en a pas | `Answer.question_budget`, `Query.Over_budget` |
| le chemin du heap | un buffer (une zone de mémoire de travail) d'au plus $\max(64, 2k)$ lignes par domain avant d'être trié et ramené à $k$ | `Top.push` |
| le chemin de l'index | la première clé est un int, une date, money, un lien ou un texte qu'un pattern donne comme sa valeur ; des fenêtres de $2k$, $4k$, ... faits (celles d'un texte : les textes suivants dans l'ordre des octets, fusionnés sur les runs et le delta ; le heap répond quand le delta contient plus de valeurs de la propriété que l'estimation) ; un budget égal à l'estimation de la question par le planner (`Query.estimate`), au-delà duquel le chemin du heap répond ; pris quand l'estimation dépasse $4k$ | `Top.give` |

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
| descripteurs par message | 64 (une base avec plus de runs que cela ne peut pas être suivie ; une base en a au plus 16, plus un par niveau) | `Fdpass.max_fds` |
| la page de visibilité | 4 KiB par base (`/dev/shm/cepheus-ID.visible`), le numéro dans ses 8 premiers octets | `Fdpass.page_size`, `Follow.page_path` |
| le page cache d'un lecteur local | 256 MiB, fixé pour le processus quand il suit sa première base (`Client.local_cache`) | `Client.follow` |
| les frames d'un follow stream | la frame du writer, en frames réseau d'au plus 1 MiB de groupes (l'indicateur `more`) | `Net.piece` |
| connexions | `[clients] max_connections`, de 1 à 65 536 ; 512 par défaut ; au-delà, une nouvelle connexion est fermée dès son accept (`too_many_connections` sur le socket Unix) | `Config.default_max_connections`, `Net.serve` |
| une connexion inactive | `[clients] idle_timeout` secondes, de 0 à 604 800 (0 : aucune limite) ; 600 par défaut : une requête entière dans ce délai depuis l'accept (le handshake TLS compris) et depuis la requête précédente, et ce que le serveur envoie, pris dans ce délai | `Config.default_idle_timeout`, `Net.timeouts` |
| le handshake d'un client | 5 s pour la connexion, TLS et Hello (et le Follow et le Start d'un follow stream), ensuite le socket attend aussi longtemps qu'il le faut ; au-delà, la tentative est abandonnée comme coupée et retentée dans le budget de nouvelles tentatives | `Client.handshake_timeout` |
| le budget de nouvelles tentatives d'un client | 30 s d'essais pour se reconnecter après une connexion coupée ; ensuite `unreachable` (une écriture en cours a été appliquée une fois ou pas du tout) | `Client.retry_budget` |

## Le vault de fichiers

| quoi | limite ou valeur par défaut | où |
|---|---|---|
| un chunk | un morceau d'un fichier, que le vault (là où Cepheus garde les octets des fichiers) coupe selon son contenu : de 16 KiB à 256 KiB, environ 73 KiB en moyenne (FastCDC, taille normale 64 KiB) ; le dernier d'un fichier plus court | `Chunker.min_size`, `normal`, `max_size` |
| un nœud (une entrée de l'arbre qui relie les chunks d'un fichier) | 1 024 enfants au plus (environ 42 KB) | `Vault.fanout` |
| un pack (un fichier où le vault ajoute ses records, ses entrées écrites) | fermé quand son record suivant dépasserait 64 MiB | `Vault.pack_limit` |
| les packs ouverts en lecture | 64 à la fois ; au-delà, ceux qu'on ne lit pas sont fermés | `Vault.max_open` |
| les nœuds et chunks décodés gardés | 96 MiB en tout, dont un tiers pour les nœuds (CLOCK pour chacun, l'éviction qui donne une seconde chance à ce qui a servi) | `Vault.open_ ?cache` |
| la compression | gardée quand elle économise au moins 1/32 d'un chunk ; à chaud (le défaut, pour un fichier lu souvent) LZ4 (accélération 1), à froid (un fichier lu rarement) Zstandard niveau 9 | `Vault.encode`, `Vault.zstd_level` |
| la fenêtre d'une frame Zstandard | 1 MiB au plus (une frame qui en demande plus est refusée) | `vault_stubs.c` |
| un fichier | 1 TiB (2^40 octets) à travers le serveur | `Files.max_size` |
| les fichiers mis en même temps | 4 par connexion | `Files.max_puts` |
| le nom d'un fichier, son type | 4 096 octets, 255 octets | `Files.max_name`, `Files.max_type` |
| les morceaux d'un Put, les frames d'un Load | 1 MiB chacun (ceux du client) ; une frame de 16 MiB au plus | `Client.piece`, `Core.chunk`, `Wire.max_frame` |
| l'index en mémoire | environ 100 octets par record | `Vault.index` |
| la clé maîtresse | 32 octets dans `vault.key`, mode 0600 (refusée si d'autres peuvent la lire, ou si c'est un lien) | `Files.master_file` |

## Les outils de mesure

| quoi | valeur | où |
|---|---|---|
| `Histogram` | exact sous 256 µs, ensuite 128 cases par puissance de deux : chaque percentile à 1/128 près (0,8 %) ; 3 584 compteurs | `src/histogram.ml` |
| le secteur du disque simulé | 512 octets, l'unité de perte et de déchirure | `Sim_disk.sector` |
| exécutions d'un benchmark | 21 (`RUNS`), la médiane et son intervalle à 95 % $[x(6), x(16)]$, une couverture de 97,3 % | `bench/stats.ml` |
