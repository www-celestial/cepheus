# Benchmarks : Cepheus, PostgreSQL et SQLite

Cepheus face à PostgreSQL 18.6 et SQLite 3.54 sur la même machine, avec les mêmes données, les mêmes questions et les
mêmes réponses, vérifiées de chaque côté. Un benchmark est une mesure de vitesse faite selon une méthode fixe, que l'on
peut refaire. Les chiffres les plus récents viennent en premier ; ceux du jalon 1 sont à la fin, pour l'historique.

## Méthode

La méthode suit Raasveldt et al. [Raasveldt 2018] pour l'équité, et Hoefler et Belli [Hoefler 2015], Le Boudec
[Le Boudec 2010] et Tene [Tene 2015] pour les statistiques :

- **Machine** : Intel i7-4720HQ (4 cœurs, 8 threads, 2015), 11 GB de RAM, pas de swap, btrfs sur un SSD SATA grand
  public (environ 340 fsync par seconde ; fsync est l'appel système qui attend que les octets écrits soient vraiment sur
  le disque). D'autres travaux partagent la machine : chaque mesure tourne sous un lock commun (ce qui réserve la
  machine à un seul travail lourd à la fois et fait attendre les autres), dans un scope systemd (un groupe de processus
  auquel systemd fixe des limites) plafonné en mémoire (3 GB sauf mention contraire ; le page cache, la copie des
  fichiers que le noyau garde en mémoire, compte dans ce plafond).
- **Builds** (les binaires compilés) : Cepheus dans le profil release de dune (le profil dev passe `-opaque`, qui
  empêche l'inlining d'un module à l'autre, c'est-à-dire de recopier le corps d'une petite fonction là où on l'appelle :
  le binaire est plus lent). Un changement est mesuré contre le binaire du commit d'avant, compilé de la même façon, les
  deux en alternance dans la même session.
- **Données** : un seul générateur à graine fixe (`bench/bench.ml`, la même graine donne les mêmes données) : 113 636
  clients (nom, ville parmi 100, e-mail unique, environ 5 liens follow, qui disent qui suit qui, vers d'autres clients)
  et 20 factures chacun (lien vers le client, total en centimes, statut : 70 % payées, 20 % impayées, 10 % en retard,
  une date) : 10 000 000 de faits ; 113 636 lignes de clients, 2 272 720 lignes de factures, 568 163 lignes de liens
  follow. Cepheus est chargé par son writer (le seul thread qui applique les écritures d'une base, une à la fois) ;
  PostgreSQL par `COPY` depuis des fichiers CSV écrits par le même générateur.
- **PostgreSQL réglé comme le ferait un expert** (`bench/pg/pg.sh`) : son propre cluster (l'ensemble des bases que gère
  un serveur PostgreSQL ; créé par initdb, jamais celui du système), fsync, synchronous_commit et full_page_writes
  activés, shared_buffers à 1 GB, work_mem à 64 MB, les tables naturelles avec leurs primary keys (la colonne qui
  identifie chaque ligne), un e-mail unique, des index sur chaque colonne cherchée (`client(city)`, `invoice(client)`,
  `invoice(status)`, `follows(b, a)`), `VACUUM ANALYZE`, un cache chaud (déjà rempli par les lectures d'avant), des
  prepared statements (des requêtes analysées une seule fois, puis exécutées avec de nouvelles valeurs). Les lignes
  insérées par ses mesures d'écriture sont effacées avant toute lecture (pour que les réponses restent les mêmes).
- **Réponses vérifiées** : Q3 (la ville city-7) : 4 299 lignes des deux côtés ; Q4 : 453 866 factures impayées, de somme
  22 677 088 830, des deux côtés ; Q5 : 114 rotations de triangles des deux côtés.
- **Autant de cœurs de chaque côté** : une question sur 1 cœur (Cepheus `CEPHEUS_DOMAINS=1`, PostgreSQL
  `max_parallel_workers_per_gather=0`) et sur 3 (3 domains, les threads d'OCaml 5 qui tournent chacun sur un cœur ;
  PostgreSQL : 2 workers, des processus d'aide, et son leader, le processus qui mène la requête : `WORKERS=2`).
  PostgreSQL décide lui-même combien de workers il lance ; ce nombre est affiché (il n'en a lancé qu'un pour Q5 : 2
  processus).
- **Un temps est une médiane avec son intervalle à 95 %.** 21 exécutions par question (`RUNS`), chacune chronométrant de
  nombreux appels pour les questions rapides (200 000 pour Q1 et Q2, 100 pour Q3) et un seul appel pour Q4 et Q5. Les
  temps sont asymétriques et souvent bimodaux (leur répartition a deux bosses) : donc ni moyenne ni intervalle de loi
  normale, mais la médiane, avec l'intervalle entre deux statistiques d'ordre (deux valeurs prises à un rang fixe dans
  les temps triés), $x(j)$ et $x(n+1-j)$, qui contient la vraie médiane avec la probabilité $1 - 2 P(B \le j - 1)$,
  $B \sim \text{Binomiale}(n, 1/2)$, quelle que soit la loi des temps ([Le Boudec 2010], théorème 2.1 ; [Hoefler 2015],
  règle 5). Pour 21 exécutions, $j = 6$ : $[x(6), x(16)]$, 97,3 %. Le nombre d'exécutions et la couverture exacte sont
  affichés avec chaque intervalle (`bench/stats.ml`, utilisé des deux côtés : les temps de PostgreSQL passent par
  `bench.exe stats`).
- **Des latences tirées d'un histogramme de toutes les valeurs**, et non d'un échantillon : des buckets (des cases de
  comptage) log-linéaires, comme ceux de HdrHistogram (exacts sous 256 µs, puis 128 buckets par puissance de deux :
  chaque percentile à 0,8 % près). p50, p90, p99, p99.9 et max ; le p99 avec son intervalle à 95 % (les mêmes
  statistiques d'ordre, avec la loi binomiale de paramètres n et 0,99 prise dans son approximation normale, à partir de
  1 000 valeurs). Les latences de PostgreSQL viennent du fichier où pgbench note chaque transaction, versées dans le
  même histogramme.
- **Deux sortes de charges d'écriture.** En closed loop (boucle fermée), chaque client écrit dès que sa dernière
  écriture est confirmée : c'est ce qui donne le plus haut throughput (le nombre d'écritures par seconde), mais ses
  latences sont fausses quand tout s'arrête un moment : un client arrêté par un fsync de 400 ms n'envoie rien pendant ce
  temps, si bien que les écritures qui auraient attendu ne sont jamais mesurées (la « coordinated omission », l'omission
  coordonnée, [Tene 2015]). En open loop (boucle ouverte), les écritures sont dues à une cadence fixe (la $k$-ième
  écriture du client $c$ à $t_0 + (k C + c) / \text{cadence}$), et la latence d'une écriture compte depuis l'instant où
  elle était due, comme le fait wrk2 ; du côté de PostgreSQL, c'est `pgbench -R`, dont les latences comptent depuis le
  départ prévu (le retard sur ce calendrier est ajouté). L'open loop donne les latences ; la closed loop, le throughput.
- **Où va le temps d'une écriture** : le pwrite (l'appel système qui écrit des octets à une place d'un fichier) et le
  fsync de chaque frame du journal (le journal est le fichier où la base ne fait qu'ajouter ses écritures ; une frame,
  l'unité d'une écriture et d'un fsync dans ce journal), la résolution de chaque batch par le writer (un batch : les
  écritures que le writer résout d'un coup), et son attente au switch d'un merge (un merge fusionne des runs triés en un
  seul ; le switch est l'instant où la base passe au run qu'il vient d'écrire), chacun dans son propre histogramme
  (`Journal.write_us`, `Journal.fsync_us`, `Engine.prepare_us`, `Engine.switch_us`) ; les collections du GC (le garbage
  collector, la partie qui libère la mémoire que plus rien n'utilise) comptées sur toute l'exécution.
- **Plus grand que la mémoire** : Cepheus avec un cache de 32 MB (`CACHE_MB`) et PostgreSQL avec shared_buffers à 32 MB
  (`SHARED`), chaque processus plafonné à 128 MB, face à une base de 245 MB (le snapshot de Cepheus : le run unique
  qu'écrit un merge complet ; un run est une copie triée de l'état, dans un fichier) et de 284 MB (le data directory de
  PostgreSQL, le dossier de ses fichiers) : les mêmes réponses, les pages lues sur le disque, le pic de mémoire
  résidente (la mémoire vive réellement occupée).

### Commandes

| commande | ce qu'elle mesure |
|---|---|
| `bench.exe load DIR CSVDIR FACTS` | charge FACTS faits par le writer : `GROUP` clients par groupe (un groupe est une écriture appliquée tout entière ou pas du tout ; 1 client par défaut : un client et ses 20 factures forment un groupe, puis les liens follow d'un client un autre groupe, envoyés par `THREADS` threads, 64 par défaut ; `GROUP=113636` à 10 M de faits : deux grands groupes, par 1 thread), chronomètre jusqu'à la confirmation du dernier groupe, puis fait un seul merge (`snapshot` ; `SNAPSHOT=0` : aucun, les runs restent tels que le chargement les a faits), et écrit les mêmes données en fichiers CSV pour les autres côtés (`NOCSV=1` : pas de CSV). Elle affiche les histogrammes du writer (un batch résolu ; un grand groupe résolu, encodé, fusionné ; un switch de merge ; un merge en arrière-plan ; le pwrite et le fsync du journal) |
| `bench.exe read DIR FACTS [Q1,Q4,..]` | l'ouverture (le redémarrage depuis le snapshot), puis Q1 à Q5 ou celles qu'on nomme : médiane et intervalle à 95 % sur `RUNS` exécutions |
| `bench.exe write DIR CLIENTS SECS [RATE]` | des écritures durables (sur le disque même, couvertes par un fsync terminé) d'une nouvelle facture (4 faits) par CLIENTS threads : aussi vite qu'elles vont, ou RATE groupes par seconde en tout (open loop) |
| `bench.exe merge DIR GROUPS` | GROUPS factures sans merge en arrière-plan, puis un seul merge (`snapshot`) : son temps et le pic de mémoire du merge seul |
| `bench.exe fsync DIR SECS append\|overwrite` | le système de fichiers seul : une frame de 9 000 octets et son fsync en boucle, ajoutée en fin de fichier ou écrite par-dessus des zéros forcés sur le disque avant |
| `bench.exe trace DIR FACTS OUT uniform\|zipf day\|points\|scan` | enregistre les lectures de pages d'une journée de questions, pour l'étude du cache |
| `bench.exe cachesim TRACE` | LRU, CLOCK, 2Q, ARC, SIEVE, S3-FIFO, W-TinyLFU et l'optimum de Belady sur une trace enregistrée |
| `bench.exe stats NAME [us]` | le résumé des nombres lus sur stdin, un par ligne, en ms (avec `us` : des latences en µs, versées dans un histogramme) : c'est ainsi que les temps des autres côtés passent par les mêmes statistiques |
| `bench.exe cpu DIR N` | le travail du writer seul : N groupes de 5 faits dans un fork de la base (une copie temporaire de la base, où l'on écrit sans rien écrire sur le disque) |
| `bench.exe crc` | CRC-32C seul (un checksum : un court nombre calculé à partir d'octets, qui change s'ils changent) sur 24 octets, 4 KiB, 16 KiB, 1 MiB et 96 MiB, depuis un décalage impair : le temps d'un appel et les MB/s, médiane et intervalle à 95 % sur `RUNS` exécutions |
| `bench/pg/pg.sh init\|start\|load\|read\|write\|stop ROOT ...` | le côté PostgreSQL, sur un cluster à lui (`ROOT/data`, port 5544) : `start ROOT MEM` plafonne la mémoire du serveur (`SHARED=32MB` fixe `shared_buffers`), `read ROOT NCLIENTS` (`WORKERS=k` workers parallèles par requête, `QS`, `RUNS`), `write ROOT NCLIENTS CLIENTS SECS` (`RATE=r` : open loop) |
| `bench/sqlite/sqlite.sh load\|read ROOT ...` | le côté SQLite, un seul fichier `ROOT/bench.db` : `load ROOT CSVDIR`, `read ROOT NCLIENTS` (`QS`, `RUNS`, `CACHE_MB`) |
| `test/seats.exe DIR 0 SEED naive\|expect SEATS` | la vente de places du [cas](case-seats.md) : `BUYERS` threads vendent toutes les places d'une salle de SEATS places ; le temps, et ce qui a mal tourné |
| `bench/sqlite/seats.py FILE immediate\|naive SEATS BUYERS` | la même vente sur SQLite (le module `sqlite3` de Python, WAL, c'est-à-dire write-ahead log, le journal où SQLite écrit avant de toucher sa base, `synchronous = FULL`) |
| `bench/pg/pg.sh seats ROOT serializable\|naive SEATS BUYERS` | la même vente sur PostgreSQL (pgbench, `--max-tries=1000`, les scripts `bench/pg/seat-*.sql`) |

Environnement de `bench.exe` : `RUNS` (21), `CEPHEUS_DOMAINS` (les domains d'une question), `CACHE_MB` (le cache),
`SYNC_MB` (tous les combien de MB un merge force son fichier sur le disque pendant que des clients écrivent : 8),
`GROUP`, `THREADS`, `SNAPSHOT` et `NOCSV` (le chargement). Les statistiques sont dans `bench/stats.ml`, les politiques
de cache dans `bench/cachesim.ml`.

Références : [Raasveldt 2018] M. Raasveldt, P. Holanda, T. Gubner, H. Mühleisen, "Fair Benchmarking Considered
Difficult: Common Pitfalls in Database Performance Testing", DBTest 2018. [Hoefler 2015] T. Hoefler, R. Belli,
"Scientific Benchmarking of Parallel Computing Systems: Twelve Ways to Tell the Masses when Reporting Performance
Results", SC 2015. [Le Boudec 2010] J.-Y. Le Boudec, "Performance Evaluation of Computer and Communication Systems",
EPFL Press, 2010. [Tene 2015] G. Tene, "How NOT to Measure Latency", conférence, Strange Loop 2015, et les outils
HdrHistogram et wrk2.

## Le column order et les intersections en leapfrog (2026-11-11), à 10 millions de faits

Étape 3 du plan pour battre les géants : le format de run 8 ajoute un troisième ordre à chaque partie d'un run, le
**column order** (les lignes de chaque propriété à part, dans l'ordre des choses : le vertical partitioning, Abadi et
al. 2007), lu par chaque recherche d'une propriété d'une chose ; les questions croisent deux slices triées (des suites
contiguës et triées de lignes) d'un niveau par **leapfrogging** (Veldhuizen 2014 : chaque liste triée saute d'un coup à
la valeur où l'autre est arrivée) au lieu d'une recherche par candidat, lisent une propriété à une seule valeur d'une
chose déjà fixée comme cette seule valeur, et laissent au niveau suivant les vérifications que celui-ci fait
([formats](formats.md#run-dirsnapshotslo-20-digits-hi-20-digitsrun), [théorie](theory.md#4-generic-join)). Le format du
journal ne change pas ; une base au format 7 rejoue son journal une fois, à sa première ouverture (5,2 s à 10 M de
faits), et donne les mêmes réponses (vérifié sur une base écrite par le binaire de main : Q3 4 299 lignes, Q4 453 866
factures de somme 22 677 088 830, Q5 114 rotations).

**Méthode.** main d747635 contre la branche (son état final : 43afeac, avec le domain des colonnes de ce commit de
nouveau retiré, voir plus bas), compilés tous deux en release, le même client de benchmark, en alternance (A puis B,
puis B puis A) pendant une seule prise du lock des travaux lourds, 7 tours, chaque processus dans un scope de 3 GB ; une
case est la médiane des 7 tours avec son intervalle à 95 % par statistiques d'ordre (pour 7 exécutions, la plus petite
et la plus grande : couverture 98,4 %) ; la dernière colonne apparie les tours (la médiane des rapports, en combien de
tours la branche a donné le plus grand nombre, un test des signes bilatéral, qui dit si cet écart peut venir du hasard).
Questions : 11 exécutions chacune dans chaque processus, sur 8 domains au plus et sur 1. Load average (le nombre moyen
de processus prêts à tourner) de 1,8 à 2,7 (la machine était partagée).

| 10 M de faits | main d747635 | branche | branche / main, par tour |
|---|---:|---:|---|
| chargement en 2 grands groupes, jusqu'à la confirmation de chaque groupe | 3,86 s [3,33 ; 5,80] | 3,93 s [3,71 ; 4,33] | 1,005 ($p = 1{,}0$ : aucune différence montrée) |
| chargement en 4 grands groupes (`GROUP=56818`) | 5,62 s [4,83 ; 6,16] | 5,75 s [5,04 ; 7,14] | 0,967 ($p = 1{,}0$) |
| un grand groupe fusionné en un run (le plus long) | 1,13 s [1,10 ; 1,39] | 1,33 s [1,31 ; 1,48] | 1,173, plus lent 6 fois sur 7 ($p = 0{,}13$) |
| pic de mémoire résidente, 2 groupes | 1 599 MB | 1 590 MB | 0,994 |
| pic de mémoire résidente, 4 groupes | 953 MB [860 ; 1 130] | 911 MB [872 ; 994] | 0,956 ($p = 0{,}45$) |
| les runs après `snapshot` (un seul run) | 54,4 MB | 69,6 MB | 1,280 : +15,2 MB (dont le column order : 13,9 MB) |
| le journal | 21,8 MB | 21,8 MB | le même |
| `snapshot` (un merge complet) | 1,65 s [1,53 ; 1,83] | 2,00 s [1,90 ; 2,46] | 1,242, plus lent 7 fois sur 7 ($p = 0{,}016$) |
| ouverture de la base qu'il laisse | 54,0 ms [51,5 ; 58,3] | **46,1 ms** [38,7 ; 52,1] | 0,795, plus rapide 6 fois sur 7 ($p = 0{,}13$) |
| Q1 une facture par id | 0,44 µs [0,40 ; 0,46] | 0,46 µs [0,39 ; 0,61] | 1,095 ($p = 1{,}0$) |
| Q2 un client par e-mail | 0,74 µs [0,67 ; 0,80] | 0,69 µs [0,63 ; 0,80] | 0,940 ($p = 0{,}45$) |
| Q3 les factures impayées d'une ville | 4,28 ms [4,13 ; 4,44] | **2,92 ms** [2,84 ; 3,24] | 0,688, plus rapide 7 fois sur 7 ($p = 0{,}016$) |
| Q4 la somme des impayées par ville, 8 domains | 88,7 ms [84,9 ; 104] | **44,0 ms** [42,6 ; 44,5] | 0,500, plus rapide 7 fois sur 7 |
| Q5 les triangles, 8 domains | 294 ms [266 ; 325] | **68,5 ms** [64,2 ; 87,9] | 0,233, plus rapide 7 fois sur 7 |
| Q4, 1 domain | 253 ms [248 ; 285] | **131 ms** [129 ; 133] | 0,518, plus rapide 7 fois sur 7 |
| Q5, 1 domain | 1,18 s [1,15 ; 1,28] | **0,271 s** [0,256 ; 0,297] | 0,224, plus rapide 7 fois sur 7 |
| 1 M de faits, un groupe par client, 64 threads | 8,01 s [7,64 ; 9,24] | 8,06 s [7,27 ; 9,92] | 1,006 ($p = 1{,}0$) |
| son pic | 200 MB [175 ; 222] | 212 MB [194 ; 224] | 1,053, plus grand 6 fois sur 7 ($p = 0{,}13$) |

**Le domain des colonnes, essayé puis retiré.** Les colonnes sont écrites par la passe par chose du merge ; elles
coûtent environ 20 ns par ligne (le merge du grand groupe +0,2 s, un merge complet +0,35 s). Les remplir sur un domain à
elles, à côté de la passe (qui lui remettait ses lignes par morceaux), ramenait le merge du grand groupe au 1,11 s de
main, mais le pic du chargement en 4 groupes est monté de 906 à 1 190 MB dans 6 tours sur 7 : OCaml 5 terminait moins de
major collections (les passes complètes du GC sur le grand heap, la zone de mémoire qu'il gère) : 9 contre 14, et le
haut du heap 45 M de mots plus haut, chaque fois qu'un domain d'aide vivait à côté de la passe, qu'il dorme sur une
condition variable, qu'il fasse du spinning (qu'il tourne en boucle pour attendre) ou qu'il fasse ses propres major
slices (les tranches de travail du GC majeur) ; chaque cas a été mesuré. La passe les remplit donc elle-même ; le temps
du chargement ne montre aucune différence.

**Où passait le temps des lectures.** Une recherche d'une propriété d'une chose lit sa colonne : un mot de rank (le
compte des choses présentes avant ce point), une entrée du répertoire et un champ (20 ns pour un compte, 42 ns pour une
valeur, sur des factures triées ; 46 à 61 ns dans le bloc d'une chose, avant). Q5 faisait cinq recherches d'appartenance
par arête, à des places au hasard dans les 200 MB de blocs de choses (le profil de l'étape 2 : 35 % de son temps) ; ce
sont maintenant deux lectures de quelques lignes contiguës (une liste sortante dans la colonne de `follows`, qui fait
1,6 MB, et une liste entrante dans les lignes par valeur, lue une fois pour chaque b que a suit) et un merge de deux
listes d'environ cinq éléments : 0,26 s sur un domain. Q4 lit le client d'une facture, la ville du client et le total de
la facture comme trois valeurs uniques, et laisse au niveau suivant la vérification « a un client ». Sur les 129 ms de
Q4, 29 ms sont le fold du benchmark lui-même (la boucle qui accumule le résultat : une `Hashtbl` OCaml mise à jour avec
un tuple neuf pour chacune des 453 866 factures, mesurée seule) : la cible du plan, 40 ms sur un cœur, est hors de
portée tant que la question est écrite ainsi ; la part du moteur est d'environ 100 ms (220 ns par facture). L'ouverture
vérifie les pages d'un run sur 4 domains au plus : 20 % plus vite que main, bien que le run ait 28 % de pages en plus.

**Ce qui a empiré.** Le run grossit de 15,2 MB (13,9 MB de column order : valeurs 11,4, tables de rank 1,2, répertoires
1,25), 1,2 MB au-dessus du budget de 14 du plan. Un merge complet prend 24 % de temps en plus (le troisième ordre est
écrit dans la passe par chose). Un merge garde un bit par chose et par propriété jusqu'à la fin de sa passe (2,4 MB à 10
M de faits). Une ouverture à froid (rien n'est encore en mémoire) d'un run plus grand que le cache lit les tables du
column order (voir plus bas).

**À côté de SQLite 3.54.** Les mêmes fichiers CSV ; un chargement de Cepheus (deux grands groupes) et un chargement de
SQLite (`.import`, index, ANALYZE, WAL, synchronous FULL) tour à tour, 7 tours, puis Q1-Q5 avec tout en mémoire, 11
exécutions chacune, un processus de chaque côté tour à tour, 7 tours (Cepheus sur un domain, sur le run unique de son
snapshot). Cette série et les deux suivantes ont tourné sur 43afeac (avec le domain des colonnes, qui ne change ni les
lectures ni le temps du chargement).

| 10 M de faits, un cœur | Cepheus, format 8 | SQLite 3.54 | qui gagne |
|---|---:|---:|---|
| chargement, jusqu'à ce qu'il soit durable | **3,96 s** [3,59 ; 5,85] | 7,98 s [6,48 ; 8,86] | Cepheus, 2,0 fois |
| sur le disque après le chargement (journal et runs) | **90,5 MB** | 136,4 MB | Cepheus, 1,5 fois plus petit (avec tout son historique) |
| pic de mémoire du chargement | 1 591 MB | **11 MB** | SQLite, 145 fois (un groupe de 9,4 M de faits en mémoire) |
| Q1 une facture par id | **0,39 µs** [0,38 ; 0,42] | 0,69 µs [0,68 ; 0,73] | Cepheus, 1,8 fois |
| Q2 un client par e-mail | **0,64 µs** [0,61 ; 0,71] | 1,42 µs [1,36 ; 1,55] | Cepheus, 2,2 fois |
| Q3 les impayées d'une ville | **2,87 ms** [2,76 ; 3,12] | 4,18 ms [4,05 ; 4,43] | Cepheus, 1,5 fois |
| Q4 la somme des impayées par ville | **130 ms** [125 ; 136] | 369 ms [353 ; 387] | Cepheus, 2,8 fois |
| Q5 les triangles | **256 ms** [244 ; 331] | 1,05 s [1,03 ; 1,10] | Cepheus, 4,1 fois |

**À côté de PostgreSQL 18.6, sur plusieurs cœurs.** Q4 et Q5 sur 1, 2, 3, 4 et 8 domains (Cepheus, 11 exécutions
chacune, 5 tours), et PostgreSQL avec 0 à 3 workers parallèles (1 à 4 processus, `max_parallel_workers_per_gather`),
mesuré dans le serveur (le temps d'exécution que donne `EXPLAIN ANALYZE` : aucun passage par un socket), 11 exécutions
chacune, 5 tours, sur un cluster propre à cette mesure (COPY, index, ANALYZE, fsync activé : 707 MB de données), effacé
à la fin. Une case : la médiane des médianes des tours [la plus petite ; la plus grande] (93,8 %).

| | 1 cœur | 2 | 3 | 4 | 8 |
|---|---:|---:|---:|---:|---:|
| Q4, Cepheus format 8 | **128 ms** [124 ; 130] | **81,6** [75,2 ; 83,0] | **57,8** [57,0 ; 60,1] | **47,8** [44,4 ; 51,0] | **42,4** [42,4 ; 45,1] |
| Q4, Cepheus main | 244 [242 ; 250] | 156 [154 ; 159] | 109 [106 ; 121] | 92,4 [86,0 ; 102] | 85,3 [84,1 ; 181] |
| Q4, PostgreSQL (processus) | 233 [230 ; 254] | 141 [140 ; 146] | 107 [106 ; 111] | 87,7 [87,2 ; 92,5] | |
| Q5, Cepheus format 8 | **250 ms** [248 ; 253] | **149** [146 ; 154] | **100** [98,9 ; 108] | **77,3** [74,8 ; 83,2] | **66,3** [63,9 ; 75,5] |
| Q5, Cepheus main | 1 140 [1 120 ; 1 170] | 592 [572 ; 597] | 409 [406 ; 447] | 354 [322 ; 412] | 280 [262 ; 310] |
| Q5, PostgreSQL (processus) | 1 010 [996 ; 1 070] | 604 [600 ; 625] | 602 [599 ; 629] | 616 [600 ; 635] | |

PostgreSQL lance au plus un worker pour Q5 (son plan n'a qu'un parallel scan, un parcours partagé entre processus), si
bien que son Q5 s'arrête à 2 processus ; son Q4 gagne en vitesse jusqu'à 4 processus (87,7 ms), là où Cepheus prend 47,8
ms sur 4 domains. La branche main perdait face à PostgreSQL sur Q4 de 2 à 4 processus ; le format 8 gagne à chaque
nombre, de 1,8 fois sur Q4 et de 4 à 8 fois sur Q5.

**Plus grand que la mémoire.** Chaque processus plafonné à 128 MB, des caches de 32 MB, les pages des fichiers retirées
du page cache du noyau avant chaque côté (tous partent à froid), les côtés tour à tour, 5 tours, 5 exécutions par
question (une case : la médiane des médianes des tours [la plus petite ; la plus grande], 93,8 %). Le Q5 de main vient
de la série du 2026-11-09 (le même format 7).

| plafond de 128 MB, à froid | format 8, 1 domain | format 8, 3 domains | main, 1 domain | SQLite 3.54 |
|---|---:|---:|---:|---:|
| ouverture | 138 ms [117 ; 161] | 161 ms [124 ; 170] | **88,2 ms** [75,8 ; 91,3] | (un fichier) |
| Q1 une facture par id | 0,44 µs [0,42 ; 0,61] | **0,42 µs** [0,38 ; 0,44] | 0,47 µs [0,39 ; 0,67] | 2,89 µs [0,87 ; 6,40] |
| Q2 un client par e-mail | 0,69 µs [0,69 ; 0,78] | **0,66 µs** [0,61 ; 0,70] | 0,70 µs [0,70 ; 0,75] | 1,48 µs [1,41 ; 1,63] |
| Q3 les impayées d'une ville | 3,13 ms [2,96 ; 3,50] | **2,97 ms** [2,88 ; 3,19] | 4,29 ms [4,10 ; 4,36] | 112 ms [105 ; 136] |
| Q4 la somme des impayées par ville | 129 ms [126 ; 133] | **58,9 ms** [56,7 ; 64,6] | 249 ms [244 ; 266] | 552 ms [469 ; 592] |
| Q5 les triangles | 263 ms [241 ; 279] | **114 ms** [113 ; 127] | 1,10 s | 1,14 s [1,10 ; 1,21] |

À 48 MB (caches de 16 MB), où aucun des deux fichiers ne tient, les triangles du format 8 prennent **260 ms**
[249 ; 274] sur 1 domain et **113 ms** [105 ; 119] sur 3 (5 exécutions, à froid), contre plus de 2,5 minutes par
exécution pour le format 7 et 1,02 s pour SQLite (2026-11-09) : la question lit la colonne de `follows` (1,6 MB) et ses
lignes par valeur, et non les blocs de choses où ses lignes étaient mêlées aux factures. Le run de 69,6 MB tient encore
sous 128 MB à côté du cache, si bien que les questions y lisent comme avec tout en mémoire. L'ouverture à froid est plus
lente que celle de main (138 ms contre 88) : un run plus grand que le cache n'est pas lu en entier, et les vérifications
du column order que fait l'ouverture (tables de rank, répertoires : 2,5 MB) lisent des pages que l'ouverture de main ne
lisait pas (les premières questions les liraient de toute façon).

**Où les géants gagnent encore.** SQLite charge avec 11 MB de mémoire, contre 1,6 GB pour Cepheus (les chargements par
morceaux sont l'étape 4). Son ouverture à froid est l'ouverture d'un fichier. PostgreSQL ne gagne plus aucune question
ici ; c'est un serveur avec ses propres processus, ce que les chiffres de Cepheus ci-dessus ne comprennent pas (le
serveur de Cepheus est mesuré dans [le serveur](server.md)).

## Runs et journal compressés (2026-11-09), à 10 millions de faits

Étape 2 du plan pour battre les géants : le format de run 7 (chaque section codée par un frame of reference, chaque
nombre écrit comme son écart à la plus petite valeur de son bloc, par blocs de 128 ; dans les blocs de choses, un
enregistrement par chose pour ses propriétés à une seule valeur et des colonnes pour les autres ; des lignes par
propriété avec leurs choses codées par gaps, l'écart de chaque chose à la précédente, quand c'est plus court ; un index
de valeurs pour les liens, les textes, les dates et les petits entiers ; une hash table des textes, où chaque texte va à
la case que désigne son hash ; seulement les pages écrites dans le fichier, avec une table des pages) et le format de
journal 2 (chaque groupe en colonnes) ([formats](formats.md),
[théorie](theory.md#11-runs-et-journal-compressés--le-codage-et-sa-borne)).

**Méthode.** main 0ecc09e contre la branche (b96c7e0, avec main d23a222 fusionné dedans), compilés tous deux en release,
le même client de benchmark, en alternance (A puis B, puis B puis A) pendant une seule prise du lock des travaux lourds,
7 tours, chaque processus dans un scope de 3 GB ; une case est la médiane des 7 tours avec son intervalle à 95 % par
statistiques d'ordre (pour 7 exécutions, la plus petite et la plus grande : couverture 98,4 %) ; la dernière colonne
apparie les tours (la médiane des rapports, en combien de tours la branche a donné le plus grand nombre, un test des
signes bilatéral). Questions : 11 exécutions chacune dans chaque processus, sur 8 domains au plus et sur 1 ; une case
est la médiane des médianes des 7 tours. Les tailles sont les octets des fichiers (`du -b`). La machine était partagée
avec d'autres travaux (load average de 1,2 à 2,2).

| 10 M de faits | main 0ecc09e | branche | branche / main, par tour |
|---|---:|---:|---|
| chargement en 2 grands groupes, jusqu'à la confirmation de chaque groupe | 4,26 s [3,82 ; 4,62] | **3,44 s** [3,32 ; 4,48] | 0,855, plus rapide 7 fois sur 7 ($p = 0{,}016$) |
| chargement en 4 grands groupes (`GROUP=56818`) | 5,74 s [5,22 ; 8,70] | **4,64 s** [4,42 ; 6,32] | 0,803, plus rapide 6 fois sur 7 ($p = 0{,}13$) |
| pic de mémoire résidente, 2 groupes | 1 460 MB | 1 600 MB | 1,096 (la frame codée en mémoire, 21,6 MB, et les buffers du codeur, ses zones de mémoire de travail) |
| pic de mémoire résidente, 4 groupes | 1 196 MB [860 ; 1 389] | **984 MB** [878 ; 1 080] | 0,804 |
| le journal | 99,6 MB | **21,8 MB** | 0,219 |
| les runs après `snapshot` (un seul run) | 246,4 MB | **54,4 MB** | 0,221 |
| journal et runs après `snapshot` | 346,1 MB | **76,2 MB** | 0,220 |
| `snapshot` (un merge complet) | 1,99 s [1,51 ; 2,70] | 1,62 s [1,54 ; 2,64] | 0,811 ($p = 0{,}45$) |
| ouverture de la base qu'il laisse | 197 ms [194 ; 240] | **53,5 ms** [52,8 ; 54,3] | 0,271, plus rapide 7 fois sur 7 |
| Q1 une facture par id | 0,36 µs [0,34 ; 0,40] | 0,38 µs [0,36 ; 0,39] | 1,056 ($p = 0{,}45$ : aucune différence montrée) |
| Q2 un client par e-mail | 1,58 µs [1,53 ; 1,64] | **0,65 µs** [0,64 ; 0,66] | 0,411, plus rapide 7 fois sur 7 |
| Q3 les factures impayées d'une ville | **3,59 ms** [3,56 ; 3,78] | 3,97 ms [3,92 ; 4,01] | 1,095, plus lent 7 fois sur 7 |
| Q4 la somme des impayées par ville, 8 domains | **79,9 ms** [78,8 ; 80,6] | 82,4 ms [81,9 ; 83,0] | 1,031, plus lent 7 fois sur 7 |
| Q5 les triangles, 8 domains | **248 ms** [243 ; 257] | 264 ms [262 ; 266] | 1,072, plus lent 7 fois sur 7 |
| Q4, 1 domain | **231 ms** [230 ; 236] | 241 ms [239 ; 243] | 1,038, plus lent 7 fois sur 7 |
| Q5, 1 domain | **1,02 s** [0,98 ; 1,05] | 1,10 s [1,07 ; 1,14] | 1,098, plus lent 7 fois sur 7 |
| 1 M de faits, un groupe par client, 64 threads | 8,25 s [7,94 ; 9,10] | 7,93 s [7,23 ; 9,05] | 0,962 ($p = 0{,}45$ : le même) |
| son pic | 235 MB | 204 MB | 0,834 |

**Où va maintenant le temps du chargement.** Le codage du grand groupe pour le journal prend 0,64 s sur son domain (0,89
s avant, avec le codage changement par changement écrit par morceaux) et son merge 1,07 s (0,35 s avant : les blocs sont
codés à mesure qu'ils se remplissent, environ 100 ns par fait), côte à côte ; puis viennent les fsync de 21,6 MB de
frame et de 54 MB de run, au lieu de 94 et 234 MB. Le travail sur le disque, qui dominait à l'étape 1, est devenu
environ 4,5 fois plus petit ; le codage du merge est maintenant la partie la plus longue, le travail d'un seul domain
(ses deux passes, par chose et par propriété, pourraient aller sur deux domains : c'est le prochain levier).

**Les lectures.** L'ordre par propriété est devenu plus rapide là où un index de valeurs remplace une binary search, la
recherche par moitiés successives dans une liste triée (Q2 : 2,4 fois), et une ouverture lit 4,6 fois moins d'octets.
Une recherche par chose coûte un peu plus qu'au format 6 : sur des factures consécutives (l'accès que font les joins,
qui associent les lignes de deux entrées ou plus par leurs valeurs communes), 46 à 61 ns contre 37 à 41 (`count_values`
49, `mem` 61, `iter_values` 58 ns ; l'en-tête du bloc est lu, et l'entrée de la propriété trouvée parmi celles du bloc,
avant son champ), si bien que Q3, Q4 et Q5, faits de telles recherches, restent un peu plus lents ; le planner (la
partie qui choisit comment calculer une question) ne compte plus une propriété à une seule valeur d'une chose déjà fixée
(une recherche sur deux en moins). Deux dispositions ont été mesurées avant celle-ci, sur les mêmes données, un tour
chacune, un domain : une colonne par propriété dans chaque bloc (PAX : Q1 0,79 µs, Q3 4,8 ms, Q4 357 ms) et un
enregistrement par chose, qui contient toutes ses valeurs avec un compte par propriété (Q1 0,43 µs, Q3 5,8 ms, Q4 316
ms, Q5 1,22 s ; sa série de 7 tours et celle des géants sont gardées avec les sorties brutes de la mesure) ; celle qu'on
a gardée, des champs pour les propriétés à une seule valeur et des colonnes pour les autres, lisait Q1 en 0,39 µs, Q3 en
3,9 ms, Q4 en 241 ms ([théorie](theory.md#11-runs-et-journal-compressés--le-codage-et-sa-borne)).

**À côté de SQLite 3.54 et de PostgreSQL 18.6.** Les mêmes fichiers CSV ; un chargement de Cepheus et un chargement de
SQLite tour à tour, 7 tours, puis Q1-Q5 avec tout en mémoire, 11 exécutions chacune, un processus de chaque côté tour à
tour, 7 tours, le tout pendant une seule prise du lock (Cepheus sur un domain, sur le run unique de son snapshot ;
SQLite en mode WAL avec synchronous FULL, avec ses index sur chaque colonne cherchée). PostgreSQL a tourné de la même
façon une heure avant, en alternance avec la variante du format 7 mesurée en premier (des enregistrements avec des
comptes), sur un cluster propre à cette mesure, fsync activé, effacé à la fin.

| 10 M de faits | Cepheus (branche) | SQLite 3.54 | PostgreSQL 18.6 |
|---|---:|---:|---:|
| chargement, jusqu'à ce qu'il soit durable | **3,45 s** [3,37 ; 3,75] | 7,22 s [6,83 ; 7,82] | 31,7 s [30,5 ; 34,4] |
| son pic de mémoire résidente | 1 600 MB (dont 883 pour la liste du client) | **11 MB** | |
| sur le disque après lui | **74,7 MB** (journal 21,6, deux runs 53,1) | 136,4 MB | 707 MB (284 de tables et d'index, le reste en WAL) |
| sur le disque avec `snapshot` (un seul run) | **76,0 MB** (journal 21,6, run 54,4), tout l'historique compris | 136,4 MB, sans historique | |
| Q1 une facture par id | **0,38 µs** [0,37 ; 0,39] | 0,68 µs [0,68 ; 0,70] (le moteur) | 4,85 µs (dans le serveur) ; 26 µs par son socket |
| Q2 un client par e-mail | **0,66 µs** [0,64 ; 0,68] | 1,37 µs [1,33 ; 1,42] | 5,69 µs ; 26 µs |
| Q3 les impayées d'une ville | **3,97 ms** [3,91 ; 4,05] | 4,11 ms [4,06 ; 4,17] | 13,8 ms ; 14,7 ms |
| Q4 la somme des impayées par ville | 240 ms [240 ; 245] | 356 ms [347 ; 362] | **108 ms** (3 processus) |
| Q5 les triangles | 1,08 s [1,04 ; 1,12] | **1,03 s** [1,02 ; 1,05] | 596 ms (2 processus) |

Cepheus charge 2,1 fois plus vite que SQLite et 9 fois plus vite que PostgreSQL, et son état, avec tout l'historique,
prend 0,56 fois la place du fichier de SQLite (qui ne garde aucun historique) ; SQLite charge toujours avec 11 MB de
mémoire. Sur un cœur, Cepheus est plus rapide sur Q1 (1,8 fois), Q2 (2,1), Q4 (1,5) et Q3 (1,04) ; SQLite l'est sur Q5
(1,05 fois) : ses nested loops (des boucles imbriquées) sur deux covering indexes (des index qui contiennent toutes les
colonnes que lit la requête) font, sur ce graphe uniforme, le travail de Generic Join, et ses pages de B-tree (l'arbre
trié de pages où SQLite range ses tables et ses index) sont lues sans décodage. Les plans parallèles de PostgreSQL (3 et
2 processus) gagnent Q4 et Q5 face à un domain ; Cepheus sur 8 domains prend 82 et 264 ms.

**Plus grand que la mémoire.** Chaque processus dans un scope plafonné à 128 MB, un cache de 32 MB de chaque côté (les
pages de Cepheus, le `cache_size` de SQLite), un domain ; avant chaque côté, les pages des fichiers sont retirées du
page cache du noyau (`posix_fadvise(DONTNEED)`), si bien que chaque côté part à froid ; les trois côtés tour à tour,
leur ordre décalé à chaque tour, 7 tours de 5 exécutions (Q5 : une fois par côté à la fin, 3 exécutions, arrêté au bout
de 10 minutes) ; une case est la médiane des 7 tours, avec le plus petit et le plus grand tour.

| 10 M de faits, 128 MB | Cepheus b96c7e0 | main 0ecc09e | SQLite 3.54 |
|---|---:|---:|---:|
| ce qui est lu | run de 54,4 MB | run de 246,4 MB | fichier de 136,4 MB |
| ouverture, à froid | 109 ms [93 ; 115] | **86 ms** [86 ; 120] | |
| Q1 une facture par id | **0,38 µs** [0,37 ; 0,40] | 70,8 µs [65,7 ; 79,3] | 0,87 µs [0,85 ; 5,38] |
| Q2 un client par e-mail | **0,65 µs** [0,65 ; 0,67] | 1,50 µs [1,43 ; 1,53] | 1,40 µs [1,33 ; 1,42] |
| Q3 les impayées d'une ville | **4,02 ms** [4,00 ; 4,06] | 542 ms [528 ; 550] | 97,5 ms [72,5 ; 110] |
| Q4 la somme des impayées par ville | **240 ms** [239 ; 243] | 483 ms [454 ; 501] | 496 ms [462 ; 577] |
| Q5 les triangles | 1,10 s (une série) | plus de 600 s (arrêté) | **1,04 s** [1,02 ; 1,06] |

À 10 M de faits, le run compressé tient sous le plafond à côté du processus (16 MB après l'ouverture, le cache de 32
MB) : ses pages, lues une fois sur le disque, restent dans le page cache du noyau, à l'intérieur du scope, et les
lectures tournent comme avec tout en mémoire. Le run du format 6, 4,5 fois plus grand, ne tient pas : chaque miss du
cache (une page cherchée qui n'y est pas) va jusqu'au SSD (Q3 135 fois plus lent, Q5 arrêté). Le fichier de SQLite ne
tient pas non plus.

**L'ouverture, à froid.** Dans la table ci-dessus (b96c7e0), une ouverture à froid du run compressé prenait 22 ms de
plus que celle du format 6. La cause : pour voir si un segment était au format 1, l'ouverture le lisait par la fenêtre
de 4 MiB de la recovery (la relecture du journal à l'ouverture), et le scan (la lecture du journal d'un bout à l'autre)
relisait cette fenêtre au début du segment le plus récent, qui contient ici tout l'historique (21,6 MB ; le segment le
plus récent du format 6 en contenait 5,5 MB). Tous deux lisent maintenant l'en-tête de 40 octets du segment, et lui
seul. Mesuré à part (l'ouverture seule, des caches de 32 MB, des scopes de 128 MB, 7 tours, les trois builds tour à
tour, les pages des fichiers retirées avant chaque ouverture à froid) :

| ouverture de la base de 10 M de faits | main 0ecc09e | b96c7e0 | 676676a |
|---|---:|---:|---:|
| à froid | 85,5 ms [84,9 ; 86,8], 45,8 MB lus | 104,2 ms [93,2 ; 139,2], 27,6 MB | **80,8 ms** [67,0 ; 84,0], 16,1 MB |
| à chaud (les fichiers dans le page cache du noyau) | 40,6 ms [40,4 ; 41,4] | 16,4 ms [15,1 ; 18,4] | **12,4 ms** [12,1 ; 13,4] |

676676a ouvre plus vite que main à chacun des 7 tours, à froid comme à chaud. Avec le cache par défaut de 1 GiB, une
ouverture de main lit 205,6 MB sur le disque, là où la branche lit 38,3 MB (438 ms contre 126 ms, dans des scopes
neufs).

**Moins de mémoire que les deux fichiers.** La même installation, avec chaque processus plafonné à 48 MB et des caches
de 16 MB, Cepheus et SQLite tour à tour, 7 tours (Q5 pour Cepheus une fois à la fin, arrêté au bout de 10 minutes) : ni
le run (54,4 MB) ni le fichier de SQLite (136,4 MB) ne tient.

| 10 M de faits, 48 MB | Cepheus b96c7e0 | SQLite 3.54 |
|---|---:|---:|
| ouverture, à froid | 103 ms [97 ; 109] | |
| Q1 une facture par id | **23,3 µs** [20,8 ; 25,5] | 40,7 µs [38,4 ; 43,6] |
| Q2 un client par e-mail | **0,66 µs** [0,62 ; 0,70] | 1,37 µs [1,31 ; 1,57] |
| Q3 les impayées d'une ville | **82,5 ms** [79,0 ; 84,2] | 444 ms [434 ; 480] |
| Q4 la somme des impayées par ville | **300 ms** [283 ; 305] | 1,22 s [1,14 ; 1,27] |
| Q5 les triangles | 4 exécutions non terminées en 10 minutes (plus de 2,5 minutes par exécution) | **1,02 s** [1,02 ; 1,05] |

Cepheus est plus rapide sur Q1 à Q4 (1,7 à 5,4 fois) : son run est 2,5 fois plus petit que le fichier de SQLite, si bien
qu'une plus grande part de ce dont une question a besoin reste dans le cache. SQLite gagne Q5 de plus de 100 fois : il
garde les liens follow dans une table et un covering index à eux (7,4 et 6,5 MB, `dbstat`), qui tiennent dans ses 16 MB
de cache, alors que Cepheus trouve les liens d'un client dans son bloc de chose, parmi les enregistrements des factures
numérotées après lui (un bloc de 128 choses contient environ 6 clients et 122 factures), si bien que les triangles
touchent au hasard les 23,5 MB de blocs de choses. Lire Q5 dans les lignes par propriété, où les 568 163 liens follow
sont rangés ensemble, est l'étape 3 du plan (le column order et un join qui les parcourt,
[théorie](theory.md#12-ce-qui-vient-ensuite-et-pourquoi)).

Les séries d'avant celle-ci (le jalon 2 et les niveaux, plus bas) ne retiraient pas les pages des fichiers, et leurs
chiffres ne sont pas comparables avec ceux-ci. Le noyau compte une page de son page cache au control group (le cgroup,
le groupe de processus auquel s'applique un plafond) qui l'a lue le premier, et l'y laisse (« A memory area is charged
to the cgroup which instantiated it and stays charged to the cgroup until the area is released » : une zone de mémoire
est comptée au cgroup qui l'a créée, et le reste jusqu'à ce qu'elle soit libérée,
[Linux cgroup v2](references.md#la-gestion-des-buffers-et-le-cache)) ; des pages lues avant une mesure, par le
chargement ou une exécution d'avant, pouvaient donc rester en mémoire hors des 128 MB du scope qui mesurait : c'est la
raison la plus probable pour laquelle la base à un seul run de la série des niveaux lisait Q3 en 85,8 ms et Q5 en 96,8
s, et main ici en 542 ms et en plus de 10 minutes.

**Lecteurs locaux et écritures par le serveur** (1 M de faits, le serveur de chaque build tour à tour, démarré et arrêté
à chaque tour, chaque tour partant d'une copie de la base telle que son chargement l'avait laissée, 7 tours ;
[le serveur](server.md)). Un lecteur local est un programme de la même machine qui lit la base par la mémoire partagée :

| 1 M de faits | main 0ecc09e | branche | |
|---|---:|---:|---|
| 8 lecteurs locaux, chacun ayant lu une fois chaque facture de l'échantillon : Pss au total (la mémoire où chaque page partagée compte pour sa part) | 252,4 MB [251,5 ; 253,0] | **106,5 MB** [105,6 ; 107,1] | 0,42 : la copie des pages de runs de chaque lecteur a diminué avec les runs (24,7 MB contre 5,7 MB) |
| leur RSS au total (la mémoire résidente, chaque page partagée comptée en entier) | 290,8 MB [290,2 ; 291,1] | **144,3 MB** [144,0 ; 144,6] | |
| un lecteur local pendant que 256 clients écrivent : CPU | 34,9 % d'un cœur [29,2 ; 38,5] | 35,9 % [22,8 ; 43,9] | aucune différence montrée |
| son Pss pendant ce temps | 180,7 MB [167,6 ; 195,5] | **108,8 MB** [101,0 ; 119,8] | |
| 256 clients qui écrivent des groupes durables de 4 faits par le socket, sans lecteur | 18 992 groupes/s [15 989 ; 24 534] | 19 330 [8 290 ; 22 152] | le même à la médiane ; deux tours de la branche sont tombés à 8 290 et 8 858, avec un p99 de 375 et 836 ms |
| la même chose dans le processus (`bench write`, 9 s, 3 merges chacun) | 19 047 [16 283 ; 22 389] | 20 119 [16 664 ; 22 136] | 1,02 par tour, plus lent dans 3 tours sur 7 : le même ; un merge en arrière-plan de 169 ms à la médiane des deux côtés |
| son pic de mémoire résidente | 205 MB | **143 MB** | |

Les deux tours lents par le socket ne se sont pas répétés dans le processus, où les merges et les attentes du writer
sont chronométrés : la plus longue attente d'un switch de merge a été de 413 ms sur main et de 447 ms sur la branche,
une fois chacune en 7 tours, sur un disque dont les fsync varient autant d'un tour à l'autre.

## Règles (2026-11-08)

La première étape du reasoner (la partie qui déduit des faits nouveaux à partir des règles) ([règles](rules.md)) : des
règles Datalog gardées par le writer, la semi-naive evaluation (chaque tour n'essaie les règles qu'avec les faits
nouveaux du tour d'avant) pour les ajouts, Backward/Forward (l'algorithme qui garde justes les faits déduits quand des
faits partent) pour les retraits, `why` à la demande.

**Méthode.** `bench/reason.exe` (build release) : des données de la forme de LUBM (Guo, Pan, Heflin [Guo 2005] :
universités, départements, personnes, cours, publications, générés à partir des plages publiées du générateur UBA ; ce
n'est pas sa sortie officielle) avec l'ontologie univ-bench sous forme de 94 règles, dont une est un axiome (39 de
sous-classe, 21 de domain, 18 de range, les règles qui donnent le type du sujet et celui de l'objet d'une propriété, 5
de sous-propriété, 4 d'inverse, 1 de transitivité, 6 pour les classes définies). Dix universités : 1 354 654 faits
affirmés (écrits par un programme), 532 205 déduits (donnés par une règle), 2 024 788 dérivations (une dérivation est
une règle avec un fait pour chaque partie de son corps ; 3,8 par fait déduit) : exactement les faits déduits et les
dérivations du prototype de l'étude de conception. Un étudiant : les 10 faits d'un étudiant de type GraduateStudent dans
un groupe, 6 faits déduits (3 types, membre du département, un diplôme, ancien élève de l'université), puis les mêmes 10
retirés dans un groupe ; 2 000 de chaque, sur un fork de la vue (l'état exact de la base après un groupe) d'une base
d'une université fusionnée en un seul run (un fork ne fait jamais de merge : si on y écrivait tout le chargement, ses
persistent maps, des maps qu'une modification ne détruit pas mais dont elle fait une nouvelle version, contiendraient
tous les faits). Les mêmes groupes sans règles sur le binaire de main 85e72ac et sur celui-ci (la même source de
benchmark), pour le chemin d'écriture sans règles. Sept tours, en alternance, pendant une seule prise du lock des
travaux lourds, chaque processus dans un scope de 3 GB ; une case est la médiane des tours avec l'intervalle
$[x(1), x(7)]$ (98,4 %). Commandes : `reason.exe student 1 2000 DIR`, `reason.exe why 1 2000 DIR`,
`reason.exe mat 10 rules|none bulk DIR`, `reason.exe apply 200000`.

| | règles | sans règles | |
|---|---:|---:|---|
| écrire un étudiant (médiane de 2 000 groupes) | **23,1 µs** [21,9 ; 24,1] | 9,1 µs [9,1 ; 13,8] | 2,5× |
| le retirer | **34,1 µs** [33,1 ; 54,8] | 6,9 µs [6,0 ; 9,1] | 4,9× |
| `why` : un type Person (une preuve de 5 faits) / Employee (8) / Student (2) / Organization (2) / Faculty (7) | 1,9 / 2,1 / 1,2 / 3,1 / 2,1 µs | | |
| charger 10 universités en un groupe, durable | 2,48 s [2,27 ; 5,13] | 1,20 s [1,04 ; 2,26] | |
| son raisonnement | 1,030 s [1,003 ; 1,088] : 0,52 M faits déduits/s | | |
| dont la construction du working set (l'ensemble des faits sur lequel le raisonnement travaille : 1,35 M de faits indexés ; 7 autres tours) | 0,581 s [0,550 ; 0,644] | | |
| la saturation seule (le calcul jusqu'à ce que les règles ne donnent plus rien de nouveau ; les mêmes 7 tours) | **1,036 M faits déduits/s** [0,977 ; 1,053] | | |
| la même chose pour une université (150 343 faits, 60 526 déduits) | raisonnement 0,100 s [0,099 ; 0,106] : 0,60 M faits déduits/s | | |
| un département par groupe, en mémoire (le chemin ordinaire), une université | raisonnement 0,238 s [0,228 ; 0,276] : 0,25 M faits déduits/s | | |
| un fait déduit versé dans une vue dont le delta (les changements depuis le dernier merge, en mémoire) contient 200 000 changements, 6 par chose | **0,83 µs** [0,82 ; 1,33] par batches triés ; 1,12 µs un par un | | |

| sans règles, les mêmes groupes | main 85e72ac | cette branche |
|---|---:|---:|
| écrire un étudiant | 9,06 µs [9,06 ; 10,01] | 9,06 µs [9,06 ; 10,97] |
| le retirer | 7,15 µs [6,20 ; 9,06] | 6,20 µs [5,96 ; 8,82] |
| charger une université, un groupe par département, durable | 1,23 s [1,05 ; 1,98] | 1,25 s [0,86 ; 4,38] |
| `Store.apply` d'un fait (la fonction de main, le même test) | 1,16 µs [1,12 ; 1,37] | 1,14 µs [1,13 ; 1,21] |

**Démarrage.** Un programme qui lie Cepheus et s'arrête aussitôt (`bench.exe` sans arguments : chaque module initialisé,
rien d'autre), main 85e72ac contre cette branche, 1 000 exécutions chacun, en alternance, sous le lock : 2,294 ms
[2,279 ; 2,306] contre 2,313 ms [2,296 ; 2,330], le rapport apparié 1,022 (intervalles à 95 % par statistiques d'ordre).
Le reasoner ajoute environ 225 KB de code, et au démarrage le runtime d'OCaml lit les frame descriptors d'un binaire (ce
qui dit au GC où sont les valeurs dans la pile) et le loader (la partie du système qui charge le binaire) lit ses
relocations (les adresses à corriger au chargement) : frame tables 821 KB → 942 KB, relocations 23 141 → 26 212 : 2 % de
plus. Une première version, qui laissait le compilateur (`-inline 200`) recopier les recherches du store (la partie qui
garde les faits) dans chaque étape de chaque plan, prenait 2,353 ms contre 2,222 (+6 %) ; depuis, le reasoner appelle le
store par des fonctions que le compilateur ne recopie pas (pas d'inlining).

Le prototype de l'étude de conception (sur des hash tables à lui, les mêmes données et les mêmes règles) donnait 0,96 M
de faits déduits/s sur un cœur pour la saturation de dix universités, 7,9 µs de raisonnement pour l'écriture d'un
étudiant et 19,1 µs pour son retrait : la saturation du moteur le dépasse (1,04 M/s) ; l'écriture d'un étudiant coûte
23,1 µs en tout (le travail du store pour ses 10 faits affirmés et ses 6 faits déduits compris), son retrait 34,1 µs,
dont les vérifications de B/F sur les maps et les runs du store sont la plus grande part. L'étude de conception mesurait
3,9 à 5,1 µs pour un fait déduit versé dans la vue, avec un delta de 600 000 changements ; au seuil de merge de la base
(200 000 changements), `Store.apply` de main prend 1,16 µs, et le batch trié 0,83 µs.

**À côté des géants** (leurs articles ; leurs machines et leurs données ; *calculé* : par nous, à partir de leurs
tables). RDFox (Motik et al. [Motik 2014], LUBM-L 1K, 133,6 M → 182,4 M de faits) : 73 s sur un thread d'un Xeon E5-2650
à 2,0 GHz, 0,67 M de faits déduits/s (calculé), 7,0 M/s sur 32 threads. VLog (Urbani et al. [Urbani 2016], les mêmes
données) : 38 s sur un thread d'un portable à 2,2 GHz, environ 1,28 M de faits déduits/s (calculé). Soufflé (Scholz et
al. [Scholz 2016]) : une analyse points-to d'OpenJDK 7 (qui calcule vers quels objets chaque pointeur peut pointer),
environ 840 M de tuples, 75 s en séquentiel, 35 s sur 4 cœurs (une autre charge de travail). Le B/F de RDFox (Motik et
al. [Motik 2015]) : 100 suppressions sur LUBM-1k-L en « 0.0 s ». À lire simplement : sur un cœur, la saturation de
Cepheus va au rythme de RDFox en 2014, et reste derrière celle de VLog de 1,2× ; avec l'indexation des faits d'un
chargement comptée, derrière VLog de 2,5× ; en parallèle, elle n'est pas encore mesurée (RDFox monte jusqu'à 32
threads) ; les petites écritures coûtent des microsecondes, un chiffre qu'aucun géant ne publie.

## Le chargement en parallèle et sans copies (2026-11-08), à 10 millions de faits

Étape 1 du plan pour battre les géants au chargement : un grand groupe est converti par quatre domains en tableaux
compacts, numéroté en une passe, trié sur place (pas du tout quand il arrive dans l'ordre des choses), et fusionné dans
son run pendant qu'un autre domain écrit le corps de sa frame dans le journal, forcé sur le disque au fur et à mesure ;
le run est forcé à côté du dernier fsync de la frame et n'est pas copié dans le cache ; le reçu (la réponse qui donne
les numéros des nouvelles choses) est fait à côté du merge ([architecture](architecture.md#les-grands-groupes)). Avec
cela : aucun run gardé hors de la chaîne (les runs posés les uns sur les autres) après un merge, et une question compte
une seule fois les patterns (les triplets de la question) qu'aucun binding (une valeur pour chaque variable) ne change.

**Méthode.** Le moteur de main eb120a4 contre la branche, compilés tous deux en release, avec le même client de
benchmark, en alternance (A puis B, puis B puis A) pendant une seule prise du lock des travaux lourds, 7 tours, chaque
processus dans un scope de 3 GB ; le load average avant chaque côté est gardé avec les sorties brutes. Le client lit
maintenant ses nouveaux ids sur le reçu par un calcul, et non plus par une hash table de ses 2,4 M de paires, si bien
que les deux côtés font le même travail de client, plus petit (0,7 s de moins entre les deux groupes ; avec l'ancien
client, main mesurait 7,04 s dans la section plus bas). Une case est la médiane de 7 tours avec son intervalle à 95 %
par statistiques d'ordre (pour 7 exécutions, la plus petite et la plus grande : couverture 98,4 %) ; la dernière colonne
apparie les tours (la médiane des rapports, en combien de tours la branche a été la plus rapide, un test des signes
bilatéral). Les questions ont tourné sur 8 domains au plus (le défaut), 21 exécutions chacune dans chaque processus :
une case est la médiane des médianes des 7 tours.

| 10 M de faits | main eb120a4 | branche | branche / main, par tour |
|---|---:|---:|---|
| chargement en 2 grands groupes (9,4 M d'ajouts, puis 568 163), jusqu'à la confirmation de chaque groupe | 6,18 s [5,65 ; 7,41] | **4,14 s** [3,67 ; 4,86] | 0,656 [0,645 ; 0,686], plus rapide 7 fois sur 7 ($p = 0{,}016$) |
| la même chose, une seconde série après que le fsync du run est passé à côté de celui de la frame | 6,59 s [6,18 ; 9,31] | 4,65 s [3,96 ; 5,43] | 0,677 [0,566 ; 0,812], 7 fois sur 7 |
| pic de mémoire résidente de ce chargement | 2 595 MB [2 527 ; 2 620] | **1 461 MB** [1 461 ; 1 462] | 0,563 |
| dont la liste d'opérations du client lui-même, une fois construite | 883 MB | 883 MB | |
| un grand groupe résolu et trié (le plus long des deux) | 1,94 s | 0,64 s (0,59 dans la seconde série) | 0,328 |
| un grand groupe fusionné dans son run (la seconde série : sans son fsync, maintenant à côté de celui de la frame) | 1,57 s (1,76) | 1,59 s (0,32) | |
| chargement en 4 grands groupes (`GROUP=56818`) | 7,62 s [7,14 ; 11,17] | 5,74 s [5,20 ; 6,50] | 0,706 [0,540 ; 0,849], 7 fois sur 7 |
| son pic | 2 167 MB | 1 184 MB | 0,616 |
| puis `snapshot` | 1,45 s [1,28 ; 2,25] | 2,06 s [1,44 ; 2,55] | 1,258 [0,871 ; 1,747], plus lent 4 fois sur 7 ($p = 1{,}0$ : aucune différence montrée) |
| sur le disque après lui | 553 MB | **330 MB** | 0,597 |
| ouverture de la base qu'il laisse (un seul run) | 199 ms [197 ; 299] | 196 ms [194 ; 199] | 0,985 [0,648 ; 1,007] |
| Q1 une facture par id | 0,37 µs | 0,36 µs | 1,000 |
| Q2 un client par e-mail | 1,56 µs | 1,56 µs | 1,013 |
| Q3 les factures impayées d'une ville | 3,80 ms | 3,58 ms | 0,955 [0,939 ; 0,966], 7 fois sur 7 |
| Q4 la somme des impayées par ville | 82,3 ms | 80,5 ms | 0,976, 7 fois sur 7 |
| Q5 les triangles | 252 ms | 245 ms | 0,970 |
| 1 M de faits, un groupe par client, 64 threads | 8,40 s [7,19 ; 9,27] | 8,48 s [7,65 ; 10,84] | 0,947 [0,911 ; 1,258] ($p = 1{,}0$ : le même) |
| son pic | 269 MB | 224 MB | 0,898 |

**Où va maintenant le temps d'un chargement** (les phases du writer, un chargement sur une machine calme) : le client
construit ses 9,4 M d'opérations en 1,3 s sur 4 domains, son propre travail ; le writer les convertit et les trie en
0,59 à 0,64 s (un parcours de la liste 0,10 s, la conversion sur 4 domains 0,10, la numérotation des nouvelles choses
0,06, des nouveaux textes 0,15, la réécriture avec les numéros définitifs 0,02, l'ordre par chose et les faits deux fois
0,02, par propriété 0,16, dont le radix sort, un tri qui range les nombres chiffre par chiffre sans les comparer, sur 2
domains avec les textes triés à côté, 0,11, la longueur encodée 0,03) ; le merge écrit le run en 0,32 s (par chose 0,19,
par propriété 0,11, le dictionnaire, la table qui numérote une fois chaque texte distinct, 0,02) pendant qu'un autre
domain encode la frame et écrit ses 94 MB (0,7 à 0,8 s, forcée tous les 32 MiB) ; puis vient le fsync du run (234 MB :
0,5 s sur un disque calme, 2,3 s sur un disque occupé) à côté du dernier fsync de la frame (60 à 90 ms, là où celui de
main prenait 270 ms) ; le groupe des follows 0,45 à 0,9 s. Le disque est maintenant la plus grande part : dans la
seconde série, les deux côtés ont ralenti de tour en tour sur une machine calme (la branche de 3,96 à 5,27 s, main de
6,18 à 9,31 s). Les étapes suivantes du plan s'y attaquent : un run codé (étape 2) écrit environ un cinquième des
octets.

**Où va sa mémoire** (la mémoire résidente à chaque phase, un chargement) : la liste du client 883 MB ; la conversion
+141 MB (14 octets par fait) ; l'ordre par propriété +108 MB (12 octets par fait) ; la place du radix sort +53 MB ; le
reçu +127 MB (2,4 M de paires d'une liste, celle de l'API), jusqu'à 1 354 MB ; le groupe des follows commence avant que
le GC ait libéré les tableaux du premier groupe : 1 455 MB au pic. La part du moteur lui-même est tombée d'environ 1,7
GB à 0,57 GB. Le `snapshot` qui suit un chargement lit maintenant les runs de ses grands groupes dans leurs fichiers,
puisqu'ils n'entrent plus dans le cache quand ils sont écrits : 2,06 s contre 1,45 s à la médiane, une différence que
les 7 tours ne montrent pas (plus lent 4 fois sur 7).

**Face aux cibles de l'étape 1.** Le chargement en 4 s au plus : atteint par les exécutions les plus calmes (3,72 s et
3,96 s), pas par les médianes (4,14 s et 4,65 s) d'un disque qui varie de moitié d'un tour à l'autre. Un pic de 1,1 GB
au plus : pas atteint, 1,46 GB, car la liste du client lui-même mesure 0,88 GB là où le plan comptait 0,7, et le reçu
0,12 ; les chargements par morceaux (étape 4) bornent les deux. Sur le disque après `snapshot` : 330 MB (le plan disait
319). Q3 en 3 ms au plus : pas atteint, 3,58 ms : compter une seule fois par question le pattern constant de la ville a
fait gagner 5,8 % ; le reste est surtout une recherche par client et par facture, que suppriment les offsets des liens
(leurs positions directes) de l'étape 2. L'ouverture, Q1 à Q5 et le chargement d'un groupe par client : pas plus lents.

**Essayé, mesuré et laissé de côté.** Une collection complète du GC juste après que les opérations d'un grand groupe
sont relâchées, pour que son reçu réutilise leur mémoire : 0,11 s par groupe, le pic inchangé (1 438 contre 1 455 MB),
et une pause de tout le processus qu'un serveur sentirait. Lancer le writeback du run (l'envoi au disque des pages
modifiées) pendant le merge avec `sync_file_range` de Linux (un appel système qui manque au module `Unix` d'OCaml : un
stub C, une petite fonction C qu'OCaml appelle, dans un programme de test, pas dans Cepheus) : durable après 1,23 s
contre 1,84 s à la médiane de 7 tours alternés, 1,5 fois, sous les 2 fois qu'un fichier C doit gagner ici, et les runs
codés de l'étape 2 réduisent la même attente. Les trois passes du merge sur trois domains : elles prennent maintenant
0,32 s d'un cœur, donc au plus 0,2 s à gagner, pour un assemblage de pages partagé entre domains ; pas fait.

**À côté de SQLite 3.54 et de PostgreSQL 18.6.** Les mêmes 10 M de faits (les fichiers CSV qu'écrit le benchmark), la
même durabilité que dans la section plus bas : un groupe de Cepheus est confirmé après le fsync de sa frame ; le
`.import` de SQLite est une transaction par table en mode WAL avec `synchronous = FULL`, puis un checkpoint (le report
du WAL dans le fichier de la base) ; le `COPY` de PostgreSQL tourne avec fsync activé, puis `VACUUM ANALYZE` et
`CHECKPOINT`. Chaque géant alterne avec la branche tour après tour, 7 tours, des scopes de 3 GB (le serveur de
PostgreSQL dans son propre scope), les médianes avec leurs intervalles à 95 % comme plus haut. Le load average de la
machine était de 1,4 à 3,5 pendant la série de SQLite, et de 13,9, en baisse jusqu'à 1,7, pendant celle de PostgreSQL
(d'autres travaux se terminaient), le même pour les deux côtés d'un tour :

| 10 M de faits | Cepheus (branche) | SQLite 3.54 | PostgreSQL 18.6 |
|---|---:|---:|---:|
| chargement, jusqu'à ce qu'il soit durable | 5,61 s [4,21 ; 11,67] (à côté de SQLite) ; 5,13 s [4,65 ; 8,08] (à côté de PostgreSQL) | 9,37 s [7,90 ; 13,67] | 30,87 s [28,08 ; 37,13] |
| Cepheus / le géant, par tour | | 0,600 [0,429 ; 0,923], Cepheus plus rapide 7 fois sur 7 ($p = 0{,}016$) : SQLite prend 1,7 fois plus de temps | 0,168 [0,144 ; 0,288], 7 fois sur 7 : PostgreSQL prend 6 fois plus de temps |
| pic de mémoire | 1,46 GB (dont 0,88 pour la liste du client) | **11 MB** | shared_buffers de 1 GB et le backend (le processus que PostgreSQL lance pour chaque connexion) |
| sur le disque après le chargement, après `snapshot` | 335 MB, 330 MB | **131 MB** | 284 MB (675 MB avec son WAL) |
| 1 M de faits, une transaction par client (3 tours) | **13,2 s** [10,2 ; 15,2] (64 threads) | 174,0 s [170,0 ; 196,9] (un seul writer) | pas mesuré (`COPY` est une seule transaction) |

Dans cette série, Cepheus comme SQLite ont pris plus de temps que dans l'A/B plus haut (la comparaison en alternance ;
le disque écrivait les fichiers des géants entre les tours de Cepheus ; un tour de Cepheus s'est arrêté 5,9 s dans son
groupe des follows, et les exécutions de SQLite lui-même allaient de 7,9 à 13,7 s), et c'est pourquoi chaque comparaison
apparie ses tours. À une transaction par client, le group commit (les écritures qui arrivent pendant un fsync partagent
le suivant) garde ici Cepheus 13 fois devant (16 fois dans la section plus bas : 10,6 contre 166,7 s, sur un disque plus
calme) ; l'A/B montre que ce chemin n'a pas changé (8,40 contre 8,48 s). **Où SQLite gagne, et pourquoi** : la mémoire,
11 MB contre 1,46 GB, parce que `.import` fait passer les lignes du fichier dans les pages du B-tree au fil de la
lecture et trie chaque index dans environ 2 MB, là où un groupe de Cepheus est une transaction gardée en entier (la
liste de l'appelant, 26 octets de tableaux par fait, le reçu) ; les chargements par morceaux (étape 4 du plan) la
bornent. Et le disque, 131 contre 330 MB : les enregistrements de SQLite sont de longueur variable, les runs de Cepheus
des mots de 8 octets ; le run codé de l'étape 2 vise 50 MB.

## CRC-32C par le processeur (2026-11-08)

Le checksum de chaque frame et de chaque page était calculé par des tables en OCaml (slicing by 8 : huit octets traités
à chaque pas, avec huit tables) ; il est maintenant calculé par l'instruction du processeur lui-même, `crc32` de SSE4.2
sur x86-64 ([architecture](architecture.md#le-journal--un-write-ahead-log)), par un seul fichier C. Mesuré contre
51cf32d, le commit d'avant, compilés tous deux en release, en alternance dans une session sous le lock des travaux
lourds, chaque processus dans un scope de 3 GB.

**Le checksum seul.** `bench.exe crc` chronomètre le nouveau code ; l'ancien a été chronométré par la même boucle, dans
un programme qui lie les deux, en alternance avec le nouveau, exécution par exécution : 21 exécutions par taille,
chacune assez longue pour durer 20 ms, depuis un décalage impair (3), pour qu'aucune longueur ne profite d'un alignement
favorable.

| octets | tables en OCaml (51cf32d) | l'instruction | rapport, médiane [intervalle à 95 %] |
|---:|---:|---:|---:|
| 24 (l'en-tête d'une frame) | 918 MB/s (0,026 µs) | 2 945 MB/s (0,008 µs) | 3,21 [3,18 ; 3,26] |
| 4 096 | 1 166 MB/s (3,51 µs) | 9 585 MB/s (0,43 µs) | 8,19 [8,12 ; 8,25] |
| 16 384 (une page) | 1 174 MB/s (13,96 µs) | 9 419 MB/s (1,74 µs) | 8,01 [8,00 ; 8,11] |
| 1 MiB | 1 171 MB/s (895 µs) | 9 353 MB/s (112 µs) | 7,98 [7,92 ; 8,00] |
| 96 MiB (la frame d'un grand groupe) | 1 133 MB/s (88,8 ms) | 8 561 MB/s (11,8 ms) | 7,59 [7,49 ; 7,63] |

**À côté des géants**, le même polynôme sur les mêmes buffers et la même machine, la même méthode (médiane de 21
exécutions après un échauffement) :

| octets | Cepheus | Java 21 `java.util.zip.CRC32C` | Go 1.26 `hash/crc32`, table Castagnoli |
|---:|---:|---:|---:|
| 24 | 2 945 MB/s | 3 890 MB/s | 2 436 MB/s |
| 4 096 | 9 585 MB/s | 21 993 MB/s | 25 003 MB/s |
| 16 384 | 9 419 MB/s | 23 357 MB/s | 25 832 MB/s |
| 1 MiB | 9 353 MB/s | 26 359 MB/s | 23 155 MB/s |
| 96 MiB | 8 561 MB/s | 12 745 MB/s | 12 015 MB/s |

Java et Go sont 2,3 à 2,8 fois plus rapides de 4 KiB à 1 MiB, et 1,4 à 1,5 fois à 96 MiB, où les trois approchent la
vitesse de la mémoire. Go coupe le buffer en trois, lance l'instruction sur les trois parties à la fois et combine les
trois CRC à la fin (`castagnoliSSE42Triple`, `src/hash/crc32/crc32_amd64.go`) ; celui de Java est compilé par HotSpot en
un code machine à lui (le flag `UseCRC32CIntrinsics`, une option de la JVM, activée par défaut). Le code de Cepheus est
une seule chaîne de pas de 8 octets, chacun attendant le résultat du précédent, si bien que sa vitesse est la latence de
l'instruction et non son throughput : le processeur pourrait commencer un pas à chaque cycle, mais le résultat d'un pas
arrive trois cycles plus tard (la source de Go dit la même chose, d'après l'article d'Intel sur l'instruction). Trois
chaînes gagneraient environ 1 µs par page lue sur le disque (une lecture à froid coûte 41 à 91 µs) et environ 25 ms par
chargement : pas fait, le code le plus petit d'abord. Sur l'en-tête de 24 octets d'une frame, Cepheus est plus rapide
que Go et plus lent que Java. PostgreSQL 18 calcule son CRC-32C avec la même instruction, en une seule chaîne sur ce
processeur (`pg_comp_crc32c_sse42` dans `src/port/pg_crc32c_sse42.c`), et par AVX-512 (VPCLMULQDQ) sur les processeurs
qui l'ont, ce qui n'est pas le cas de celui-ci. Les bibliothèques standard de Python et de Node n'ont pas de CRC-32C
(leur `zlib.crc32` est le CRC-32 de zlib, un autre polynôme).

**De bout en bout**, 9 tours en alternance (l'ordre inversé à chaque tour) : le chargement de 10 M en 4 grands groupes
(`GROUP=56818`) et son snapshot, puis l'ouverture de la base qu'il laisse (`bench.exe read DIR 10000000 none` : un seul
run de 246 MB, qui tient dans le cache, si bien que chacune de ses 15 038 pages est lue et vérifiée à l'ouverture) ; le
chargement de 1 M à un groupe par client (64 threads, `SNAPSHOT=0`) et l'ouverture de ce qu'il laisse (ses runs et la
fin du journal, 1 214 pages). Médiane [intervalle à 95 %, statistiques d'ordre, 96,1 %] ; le rapport est apparié par
tour ; les tests sont bilatéraux.

| | 51cf32d | l'instruction | rapport | plus rapide dans | test des signes |
|---|---:|---:|---:|---:|---:|
| 10 M de faits, 4 grands groupes, jusqu'à la confirmation | 9,09 s [7,88 ; 11,68] | 9,43 s [8,18 ; 10,37] | 1,04 [0,79 ; 1,18] | 4 sur 9 | $p = 1$ |
| son snapshot | 1,98 s [1,33 ; 2,27] | 2,04 s [1,52 ; 2,65] | 1,07 [0,67 ; 1,52] | 4 sur 9 | $p = 1$ |
| **l'ouverture de cette base** | 432 ms [389 ; 539] | **202 ms [197 ; 255]** | **0,49 [0,37 ; 0,60]** | 9 sur 9 | $p = 0{,}004$ |
| 1 M de faits, un groupe par client, jusqu'à la confirmation | 10,24 s [9,37 ; 11,18] | 10,95 s [9,39 ; 12,70] | 1,05 [0,85 ; 1,24] | 4 sur 9 | $p = 1$ |
| l'ouverture de cette base | 365 ms [356 ; 419] | 346 ms [339 ; 359] | 0,94 [0,82 ; 1,00] | 8 sur 9 | $p = 0{,}039$ |

L'ouverture de la base de 10 M prend la moitié du temps : 15 038 pages × 12,2 µs gagnées par page font 0,18 s des 0,23 s
mesurées. Les chargements calculent le checksum d'environ 330 MB, 0,29 s en OCaml et 0,04 s maintenant ; ces 0,25 s sont
à l'intérieur des écarts du disque (l'ancien binaire seul a pris de 7,44 à 13,19 s pour le même chargement), et 9 tours
ne les distinguent pas : aucun chargement n'est devenu plus rapide ou plus lent de façon mesurable. Une page lue sur le
disque pendant une réponse (base plus grande que la mémoire) paie 1,74 µs pour sa vérification au lieu de 13,96.

**Démarrage** d'un programme qui lie Cepheus (`bench.exe` sans arguments : chaque module initialisé, puis la sortie), le
lancement du processus et son attente chronométrés 2 000 fois de chaque côté, en alternance : 2 039 µs pour 51cf32d,
+1,0 µs [−7,7 ; 7,7] avec la nouvelle bibliothèque seule, +9,9 µs [0,2 ; 18,4] (0,5 %) pour le binaire entier avec sa
nouvelle commande `crc`. La vérification que le processeur a l'instruction est un seul appel C ; la table de 2 048
nombres que l'ancien code construisait au démarrage a disparu. Une copie neuve du même binaire démarrait 17,8 µs
[9,4 ; 28,3] plus lentement que le fichier laissé par le build, si bien que ces mesures comparent des binaires à
l'endroit où le build les a laissés.

**Les corrections du moteur mesurées à nouveau** (la section plus bas), sur une machine calme : 2f37b23 contre 51cf32d,
les mêmes chargements et les mêmes ouvertures, 9 tours en alternance. 10 M en 4 grands groupes : 9,68 s [8,42 ; 11,47]
contre 8,73 s [8,09 ; 9,61] (rapport 0,97 [0,77 ; 1,12], plus lent dans 4 tours sur 9, $p = 1$) ; son ouverture 396
contre 403 ms (1,02 [0,94 ; 1,26], $p = 0{,}51$) ; 1 M à un groupe par client 9,21 contre 9,87 s (1,01 [0,85 ; 1,16],
$p = 1$) ; son ouverture 364 contre 368 ms (1,00 [0,97 ; 1,14], $p = 0{,}51$). Les corrections ne coûtent rien de
mesurable : les 13,12 s plus bas venaient du disque.

## Les corrections du moteur (2026-11-08), contre le commit d'avant elles

Cinq corrections ([garanties](guarantees.md#g9-un-seul-writer), [limites](limits.md)) : le lock interne au processus,
identifié par le device et l'inode du fichier de lock (les deux numéros qui désignent un fichier sur un disque), les
numéros de chose refusés au-delà de $2^{31} - 1$, un second `close` qui ne fait rien, `decode` pour les mots de `fold`,
et des frames qui restent dans les 256 MiB quel que soit le nombre de groupes qui arrivent. Le chemin du writer a changé
(un batch peut s'arrêter avant un groupe qui dépasserait la limite, et un grand groupe commence une frame à lui), donc
les chargements et les lectures ont été mesurés contre le commit d'avant les corrections (2f37b23), compilés tous deux
en release, en alternance dans une session sous le lock des travaux lourds, chaque processus dans un scope de 3 GB.

| | avant les corrections (2f37b23) | après | |
|---|---:|---:|---|
| 10 M de faits en 4 grands groupes (`GROUP=56818`), 6 exécutions de chaque côté | 10,78 s [9,03 ; 17,00] | 13,12 s [9,72 ; 14,16] | les intervalles se recouvrent ; la part CPU est la même (voir plus bas) |
| 1 M de faits, un groupe par client, 64 threads, 6 exécutions de chaque côté | 9,38 s [8,70 ; 14,20] | 9,55 s [8,66 ; 15,10] | identique |
| Q1 une facture par id, 1 domain | 0,38 ; 0,38 ; 0,38 µs | 0,38 ; 0,37 ; 0,37 µs | identique |
| Q2 un client par e-mail | 1,57 ; 1,58 ; 1,59 µs | 1,56 ; 1,57 ; 1,54 µs | identique |
| Q3 les impayées d'une ville | 3,73 ; 3,77 ; 3,74 ms | 3,76 ; 3,70 ; 3,73 ms | identique |
| Q4 la somme des impayées par ville | 233 ; 233 ; 231 ms | 232 ; 230 ; 234 ms | identique |
| Q5 les triangles | 0,99 ; 1,02 ; 0,95 s | 0,96 ; 0,96 ; 0,97 s | identique |
| ouverture (un seul run, 10 M de faits) | 704 ; 385 ; 385 ms | 602 ; 379 ; 379 ms | identique |

Les chargements donnent la médiane et son intervalle à 95 % sur 6 exécutions (la plus petite et la plus grande,
couverture 96,9 %) ; chaque case de lecture donne les médianes des 3 tours (21 exécutions par question dans chaque
processus, chaque intervalle à moins de 2 % de sa médiane ; les sorties brutes les gardent). Les lectures ont tourné sur
une seule base, celle qu'avait faite le dernier chargement d'avant les corrections (un seul run après son `snapshot`),
copiée pour chaque côté, pour que les deux lisent les mêmes octets. Le chargement en grands groupes était plus lent
après les corrections dans 5 tours sur 6, de 0,6 à 5,1 s, et plus rapide dans le sixième, de 6,6 s (un test des signes :
$p = 0{,}22$, bilatéral, aucune différence montrée) ; les histogrammes du writer lui-même disent où le temps est allé :
la part CPU, un grand groupe résolu et trié, est la même des deux côtés (son plus long 0,93 à 1,00 s avant, 0,93 à 1,10
s après), et les différences sont dans les merges des groupes en runs (leur plus long 2,3 à 5,1 s avant, 2,6 à 6,5 s
après) et dans les fsync du journal, le temps du disque sur une machine qu'utilisaient d'autres travaux. Le chargement
en 2 grands groupes de la section plus bas a besoin de 2,7 à 3,2 GB : sous le plafond de 3 GB, 6 de ses 10 exécutions
ont été tuées, donc cette comparaison a utilisé 4 groupes (1,7 à 2,5 GB).

## Les niveaux sur disque et les grands groupes (2026-11-08), à 10 millions de faits

Deux changements depuis le merge écrit dans un fichier (théorie, section 9) : les runs sur disque sont les niveaux d'un
LSM tree (les écritures récentes restent dans une petite structure en mémoire, puis sont fusionnées par paquets dans des
runs triés sur le disque, rangés en niveaux de plus en plus grands ; ici en leveling, un seul run par niveau, et avec un
rapport 4, chaque niveau 4 fois plus grand que le précédent), et un grand groupe (20 000 ajouts et plus) est trié dans
un run au moment où il est écrit, sans mise à jour d'index fait par fait. Mesuré contre 148ff09 (un seul niveau écrit
dans un fichier) et c7f25c0 (un seul niveau fusionné en mémoire), compilés tous trois en release et en alternance,
chacun sur sa propre base chargée par son propre binaire ; et contre SQLite 3.54 et PostgreSQL 18.6, qui chargent les
mêmes faits depuis les fichiers CSV qu'écrit le benchmark. Chaque côté est durable à la fin : Cepheus confirme un groupe
après le fsync de sa frame ; SQLite fait ses commits en mode WAL avec `synchronous = FULL` puis un checkpoint ;
PostgreSQL fait ses commits avec fsync activé, puis un checkpoint.

### Le chargement

Deux façons d'écrire les mêmes faits. *Grands groupes* : les 113 636 clients avec leurs factures dans un seul groupe
(9,4 M d'ajouts), puis leurs liens follow dans un second (568 163) : ce que font le `.import` de SQLite (une transaction
par table) et le `COPY` de PostgreSQL. *Un groupe par client* : 227 272 groupes (un client et ses 20 factures ; les
follows d'un client), écrits par 64 threads, chacun confirmé à part : ce que fait une application quand chaque client
est une transaction. Le temps court jusqu'à la confirmation du dernier groupe (`bench.exe load`, `GROUP` clients par
groupe ; le snapshot de Cepheus qui suit, un seul run fait de tout, est compté à part : 1,3 à 6,5 s, selon le disque).

| 10 M de faits | temps, médiane [intervalle à 95 %], exécutions | pic de mémoire | sur le disque |
|---|---:|---:|---:|
| Cepheus, 2 grands groupes | 7,04 s [6,52 ; 7,41], 10 | 2,5 à 3,2 GB | 335 MB (journal 96, runs 237) ; 553 après `snapshot` |
| SQLite 3.54 réglé comme le dit sa documentation (`.import`, les index après, `ANALYZE`) | 6,97 s [6,38 ; 8,00], 10 | 11 MB | 131 MB |
| PostgreSQL 18.6 `COPY`, index, `VACUUM ANALYZE` | 32,3 s [29,6 ; 34,2], 6 | shared_buffers 1 GB | 284 MB (le cluster avec son WAL : 675) |
| Cepheus, un groupe par client | 111,8 s [103,1 ; 124,4], 4 | 1,6 à 1,8 GB | 487 MB |
| 148ff09, un groupe par client | 157,5 s [122,0 ; 179,2], 4 | 1,3 à 2,0 GB | 532 à 550 MB |
| c7f25c0, un groupe par client | 74,7 s [70,2 ; 83,2], 4 | 2,7 à 2,9 GB | 100 MB, puis 335 après son snapshot |

**Cepheus et SQLite en alternance** (`duel.txt` : 10 tours, un chargement de Cepheus puis un chargement de SQLite, pour
que les deux trouvent le même disque) : égalité. Cepheus a été plus rapide dans 4 tours sur 10 (un test des signes ne
voit aucune différence), et la médiane des différences appariées est de 0,16 s en faveur de SQLite. Les deux sont sous
les 8,6 s qu'a pris SQLite quand il a été mesuré pour la première fois (la section des lectures, plus bas), sur un
disque plus occupé ; les séries d'avant celles-ci, sans alternance, donnaient 8,46 s [6,07 ; 10,98] (7 exécutions) pour
Cepheus et 8,84 s [7,85 ; 9,75] (6 exécutions) pour SQLite. La durabilité est la même : un groupe de Cepheus est durable
quand il est confirmé (sa frame forcée sur le disque), un `.import` de SQLite est une transaction dont le commit se fait
avec `synchronous = FULL` en mode WAL, et les deux finissent forcés sur le disque (les runs de Cepheus, le checkpoint de
SQLite). Cepheus fabrique ses faits dans le processus (le côté client du benchmark, 1,3 s sur 4 domains) ; SQLite les
décode depuis les fichiers CSV. SQLite fait le chargement avec 11 MB de mémoire et 131 MB de disque, Cepheus a besoin de
2,5 à 3,2 GB et de 335 MB.

À la durabilité d'un groupe par client, SQLite n'a pas de group commit : un seul writer, un fsync par commit. À 1 M de
faits (11 363 clients, 22 726 transactions, chacune un client et ses factures, ou les follows d'un client ; un script
Python `sqlite3` gardé avec les sorties brutes, les index faits d'abord, comme Cepheus garde les siens) : SQLite 166,7 s
[138,6 ; 169,3] (3 exécutions ; 6 à 7 ms par commit, fichier de 13 MB, pic de 111 MB) ; Cepheus, un groupe par client
par 64 threads, 10,6 s [9,9 ; 10,9] (3 exécutions ; 283 à 322 MB, 42 MB sur le disque), 16 fois moins : son writer met
les groupes qui arrivent pendant un fsync dans la frame suivante (le group commit), là où le writer unique de SQLite
force chaque commit seul ; Cepheus en deux grands groupes 0,94 s [0,86 ; 1,28] (3 exécutions ; 277 à 306 MB, 33 MB). À
10 M de faits, les mêmes 227 272 commits de SQLite prendraient environ 28 minutes à ce rythme (pas mesuré).

**Le fsync du journal pendant un chargement à un groupe par client** (p99 de chaque chargement) : Cepheus 56 à 102 ms,
c7f25c0 40 à 102 ms, 148ff09 148 à 287 ms : c'est le remède à la régression du merge écrit dans un fichier (ses merges
de tous les runs faisaient attendre chaque fsync). Le temps de ce chargement est une autre histoire : 112 s contre 75 s
pour c7f25c0. Avec un groupe par client, le chargement est limité par ses frames (9 500 à 11 000 fsync de 3,7 à 4,5 ms à
la médiane, une frame toutes les 11 ms) et par les merges des niveaux, dont les écritures (un fait environ 6 fois, 1,3
GB à 10 M de faits, forcées tous les 8 MiB pendant que le journal écrit) partagent le disque avec le journal ; c7f25c0
gardait ses merges en mémoire (2,7 à 2,9 GB à son pic, contre 1,6 à 1,8) et n'écrivait rien d'autre que le journal
jusqu'à son snapshot.

**Où va le temps d'un grand chargement** (les histogrammes du writer, sur un disque calme) : le côté client fabrique ses
9,4 M d'opérations en 1,3 s (4 domains) ; le writer les résout et les trie en 1,9 à 2,3 s (une passe sur les opérations
1,1 s, les tris 0,8 s, les radix sorts sur 4 domains), encode la frame (0,4 s, à côté du merge, dans un autre domain),
et les fusionne en un run en 1,8 s sur un disque calme (par chose 0,5 s, par propriété 0,7 s, le dictionnaire 0,2 s, le
fsync de ses 220 MB 0,4 s ; 3 à 5,6 s quand le disque est occupé) ; la frame du journal, de 113 MB, prend 0,2 à 0,4 s à
forcer ; le groupe des follows 0,4 à 1,5 s. L'écart entre les exécutions (6,1 à 11 s) vient du disque : le même binaire,
les mêmes données, le fsync du merge de 0,4 à 4 s. Ce qui irait plus loin, sans plier une garantie : les trois passes du
merge en parallèle (elles écrivent à des endroits séparés du fichier : environ -0,7 s) ; le fsync du run et celui du
journal en même temps plutôt que l'un après l'autre (-0,3 s ; le run doit toujours être forcé avant de porter son nom,
G12) ; moins d'octets (un run de 23 octets par fait et une frame de 12, contre 14 pour la table et les index de SQLite :
un codage par deltas, chaque nombre écrit comme sa différence avec le précédent, et en varint, chaque entier sur autant
d'octets qu'il lui en faut, des colonnes triées). Mémoire : les opérations d'un groupe de 9,4 M, ses tableaux et sa
frame sont en mémoire en même temps (2,5 à 3,2 GB) ; des groupes plus petits demandent moins (1 M de faits en un
groupe : 277 MB), mais chacun fait un merge avec les runs d'avant.

### Les lectures, tout en mémoire

21 exécutions par question, 2 tours en alternance (chaque case : les médianes des 2 tours ; les intervalles sont dans
les sorties brutes (`read-final.txt`), tous à quelques pour cent de leur médiane). *nouveau* est la base après son
snapshot (un seul run) ; *nouveau, 2 runs* contient les mêmes faits tels que le chargement les a laissés : le run des
clients et le run des follows (qui contient chaque client).

| 1 domain | Q1 | Q2 | Q3 | Q4 | Q5 | ouverture |
|---|---:|---:|---:|---:|---:|---:|
| nouveau, un seul run | 0,38 ; 0,38 µs | 1,57 ; 1,58 µs | 3,82 ; 3,74 ms | 237 ; 231 ms | 1,00 ; 0,95 s | 384 ; 383 ms |
| nouveau, 2 runs | 0,38 ; 0,38 µs | 1,70 ; 1,76 µs | 5,35 ; 5,41 ms | 332 ; 331 ms | 1,01 ; 1,02 s | 495 ; 587 ms |
| 148ff09 | 0,35 ; 0,34 µs | 1,58 ; 1,54 µs | 4,10 ; 4,06 ms | 226 ; 227 ms | 1,00 ; 0,94 s | 414 ; 396 ms |
| c7f25c0 (la première série) | 0,38 ; 0,37 µs | 1,58 ; 1,64 µs | 3,98 ; 3,94 ms | 229 ; 227 ms | 0,95 ; 0,97 s | 397 ; 421 ms |

| 3 domains | Q1 | Q2 | Q3 | Q4 | Q5 |
|---|---:|---:|---:|---:|---:|
| nouveau, un seul run | 0,37 ; 0,38 µs | 1,55 ; 1,57 µs | 3,75 ; 3,76 ms | 107 ; 107 ms | 362 ; 360 ms |
| nouveau, 2 runs | 0,39 ; 0,39 µs | 1,75 ; 1,76 µs | 5,38 ; 5,42 ms | 143 ; 144 ms | 370 ; 368 ms |
| 148ff09 | 0,36 ; 0,35 µs | 1,57 ; 1,59 µs | 4,13 ; 4,12 ms | 106 ; 104 ms | 360 ; 369 ms |

Le dernier binaire contre 148ff09 une fois de plus, 3 tours en alternance, un domain (`read-last.txt`), les médianes de
chaque tour. Q1 : 0,37 ; 0,38 ; 0,38 µs contre 0,37 ; 0,37 ; 0,36. Q2 : 1,61 ; 1,57 ; 1,64 contre 1,62 ; 1,61 ; 1,57 µs.
Q3 : 3,79 ; 3,78 ; 3,79 contre 4,19 ; 4,12 ; 4,13 ms. Q4 : 234 ; 239 ; 231 contre 230 ; 226 ; 227 ms. Q5 : 1,02 ; 1,01 ;
0,97 contre 1,01 ; 0,95 ; 0,97 s. Ouverture : 381 ; 383 ; 440 contre 386 ; 399 ; 386 ms.

Sur un seul run, les questions tournent comme sur la base à un seul niveau : Q2 et Q5 identiques ; Q1 plus lent de 0,01
à 0,04 µs (3 à 10 %, et la différence bouge autant d'un tour à l'autre) ; Q4 plus lent de 2 à 5 % ; Q3 plus rapide de 8
%. Une recherche lit un mot de plus, un rank, sauf dans une partie qui contient chaque chose jusqu'à sa fin (un
chargement, un merge complet), où la place se calcule par une addition. La première mesure des niveaux était plus lente
de 17 à 23 % (Q1 0,42 µs, Q4 286 ms : `read-before-store-fixes.txt`) : des closures (des fonctions qui gardent des
valeurs de leur contexte) allouées à chaque recherche, un rank lu pour chaque chose, des listes pour un seul run ;
corrigé avant ces chiffres. Sur deux runs, une ligne du run le plus ancien n'est montrée que si le run le plus récent
n'a pas d'entrée pour le même fait : quelques bits des tables de rank quand le run le plus récent ne contient pas la
chose, une recherche quand il la contient (ici il contient chaque client) : Q3 +43 %, Q4 +40 % sur un domain ; un run
sans aucune ligne de la propriété est sauté d'emblée (Q5, les follows, comme avec un seul run). Un `snapshot` fusionne
tout en un seul run.

### Plus grand que la mémoire

Cache de 32 MB, le processus plafonné à 128 MB ; 5 exécutions (Q5 : 1 exécution) ; la première série pour 148ff09 et
c7f25c0 :

| | Q1 | Q2 | Q3 | Q4 | Q5 | Q4, 3 domains |
|---|---:|---:|---:|---:|---:|---:|
| nouveau, un seul run | 39,7 µs | 1,54 µs | 85,8 ms | 383 ms | 96,8 s | 229 ms |
| 148ff09 | 40,6 µs | 1,65 µs | 89,8 ms | 378 ms | 99,9 s | 278 ms |
| c7f25c0 | 39,5 µs | 1,50 µs | 85,8 ms | 381 ms | 99,5 s | 243 ms |

La base telle que le chargement la laisse (2 runs), la même installation, en alternance avec la base à un seul run, 2
tours (`big-runs.txt` ; chaque case : tour 1 ; tour 2) :

| 1 domain | Q1 | Q2 | Q3 | Q4 | ouverture | pic |
|---|---:|---:|---:|---:|---:|---:|
| nouveau, 2 runs | 41,9 ; 40,9 µs | 2,03 ; 1,83 µs | 91,2 ; 89,4 ms | 482 ; 486 ms | 165 ; 197 ms (54-56 MB) | 58 MB |
| nouveau, un seul run | 42,3 ; 41,6 µs | 1,69 ; 1,72 µs | 92,8 ; 90,9 ms | 394 ; 393 ms | 70 ; 80 ms (32 MB) | 51 MB |

Avant db91dac, la base à 2 runs ne s'ouvrait pas sous le plafond : l'ouverture lisait en entier son segment de journal
de 94 MB, alors que ses runs contenaient chacune de ses frames (le segment du groupe des clients). Le journal est
maintenant lu par une fenêtre de 4 MiB, et une frame que les runs contiennent est vérifiée par son CRC morceau par
morceau. Une première mesure après la correction a donné Q3 en 613 ms sur un domain ; elle ne s'est pas répétée (89 à 91
ms dans les deux tours ci-dessus ; 89,5 ms sur 3 domains).

### Les écritures à 256 clients, avec leurs merges

Closed loop, 10 s, 6 exécutions de chaque côté sur une copie neuve de chaque base (en alternance) ; le pic est le VmHWM
du processus (le plus haut niveau atteint par sa mémoire résidente), la mémoire de merge de la méthode du jalon 2 :

| | groupes durables/s, médiane [intervalle] | pic de mémoire, médiane [intervalle] | p99 du fsync du journal, les 6 exécutions |
|---|---:|---:|---:|
| nouveau | 18 252 [13 574 ; 24 383] | 762 MB [723 ; 1 300] | 16,5 à 131 ms (médiane 27) |
| 148ff09 | 18 168 [14 613 ; 22 488] | 1 040 MB [842 ; 1 161] | 29 à 50 ms (médiane 35) |
| c7f25c0 | 18 546 [17 000 ; 20 889] | 2 095 MB [1 778 ; 3 024] | 20 à 39 ms (médiane 22,5) |

Le throughput est celui du disque, de chaque côté. Un merge écrit maintenant un niveau de quelques centaines de milliers
de faits (0,3 s), là où 148ff09 réécrivait tous les runs (3,7 s), si bien que le pic baisse d'un quart face à 148ff09 et
de deux tiers face à c7f25c0.

**Méthode.** Comme plus haut : chaque processus sous le lock des travaux lourds et un plafond de mémoire, les côtés en
alternance dans une session, des médianes avec leurs intervalles à 95 % valables quelle que soit la loi des temps
(statistiques d'ordre ; avec 6 exécutions, l'intervalle va de la plus petite à la plus grande, couverture 96,9 % ; avec
4, 87,5 % ; avec 7, 98,4 % ; avec 10, de la deuxième plus petite à la deuxième plus grande, 97,9 %), des latences tirées
d'histogrammes, les mêmes réponses de chaque côté (Q4 453 866 factures de somme 22 677 088 830 ; Q5 114 rotations).
Entre deux processus du même binaire, les médianes diffèrent plus que ne le disent leurs intervalles (Q1 de 0,34 à 0,47
µs pour 148ff09 dans une session) : les tours sont alternés et chaque case montre les deux. Scripts : `bench/bench.ml`
(`GROUP`, `THREADS` et `SNAPSHOT` sont nouveaux), `bench/pg/pg.sh`, l'installation de SQLite que donne sa documentation
(`.import`, les index après, `ANALYZE`, un checkpoint).

## SQLite 3.54 à 10 millions de faits : les lectures (2026-11-08)

SQLite est, comme Cepheus, une bibliothèque à l'intérieur du processus de l'application : c'est donc la comparaison la
plus équitable des deux moteurs, sans socket d'aucun côté. Les mêmes données (les fichiers CSV de `bench.exe load`), les
mêmes questions, les mêmes réponses (Q3 city-7 : 4 299 lignes ; Q4 : 453 866 factures, 22 677 088 830 ; Q5 : 114
rotations). SQLite réglé comme le ferait un expert (`bench/sqlite/sqlite.sh`) : des tables `INTEGER PRIMARY KEY` (la clé
est l'adresse de la ligne dans son B-tree), `follows` en table `WITHOUT ROWID` rangée par (a, b), un index unique sur
l'e-mail, des index sur `client(city)`, `invoice(client)`, `invoice(status)`, `follows(b, a)`, `ANALYZE` ; un page cache
à lui de 1 GiB (`PRAGMA cache_size`, comme le cache de Cepheus ; le défaut est 2 MB), `temp_store = MEMORY`, chauffé par
une passe de chaque question. Ses plans, d'après `EXPLAIN QUERY PLAN` : Q3 l'index des villes puis `invoice(client)` ;
Q4 l'index des statuts, puis le client de chaque facture par sa clé, et un B-tree temporaire pour le GROUP BY ; Q5 des
nested loops sur les deux covering indexes de `follows`. Les questions sont chronométrées dans le processus par le
module `sqlite3` de Python (`bench/sqlite/read.py`) : Q1 et Q2 font 100 000 recherches dans une seule requête, menées
par une CTE récursive (une table calculée ligne à ligne dans la requête elle-même ; c'est la mesure « moteur seul »,
comme la boucle PL/pgSQL de PostgreSQL), Q3 une requête par ville (100 par exécution), Q4 et Q5 une requête par
exécution. 21 exécutions par question, deux tours en alternance avec Cepheus (build release de `docs-full`, le moteur de
148ff09, un domain, `CEPHEUS_DOMAINS=1`), chaque processus sous le lock des travaux lourds et un plafond de 3 GB. Sortie
brute : la médiane et son intervalle à 95 % de chaque tour.

| question | Cepheus, 1 domain, tours 1 et 2 | SQLite, tours 1 et 2 | |
|---|---|---|---|
| Q1 chaque fait d'une facture, par id | 0,36 µs [0,36 ; 0,36] ; 0,38 µs [0,37 ; 0,40] | 0,67 µs [0,67 ; 0,68] ; 0,68 µs [0,68 ; 0,70] (environ 0,45 µs sans les 0,23 µs par ligne de la CTE) | Cepheus, 1,2 fois |
| Q2 un client par e-mail | 1,67 µs [1,64 ; 1,71] ; 1,66 µs [1,62 ; 1,83] | 1,52 µs [1,50 ; 1,57] ; 1,52 µs [1,51 ; 1,58] (environ 1,22 µs sans la CTE et la concaténation de l'e-mail, 0,30 µs par ligne) | **SQLite**, 1,1 à 1,4 fois |
| Q3 les factures impayées des clients d'une ville | 4,17 ms [4,15 ; 4,22] ; 4,19 ms [4,12 ; 4,33] | 4,13 ms [4,10 ; 4,16] ; 4,19 ms [4,15 ; 4,23] | à égalité |
| Q4 la somme des impayées par ville | 230 ms [229 ; 232] ; 230 ms [226 ; 232] | 355 ms [352 ; 364] ; 366 ms [359 ; 369] | Cepheus, 1,55 fois |
| Q5 les triangles | 979 ms [957 ; 986] ; 969 ms [967 ; 1 020] | 1,04 s [1,03 ; 1,08] ; 1,04 s [1,04 ; 1,05] | Cepheus, 1,07 fois |
| chargement de 10 M de faits (mesuré à nouveau après les niveaux, [plus haut](#le-chargement)) | 7,04 s [6,52 ; 7,41] en 2 grands groupes ; 111,8 s à un groupe par client | 6,97 s [6,38 ; 8,00] (`.import`, index, `ANALYZE`), en alternance avec les grands groupes de Cepheus | à égalité en grands groupes ; à une transaction par client, Cepheus 16 fois (1 M de faits) |
| taille sur le disque | 335 MB après le chargement (journal 96 MB, runs 237 MB) | **131 MB**, un seul fichier | **SQLite**, 2,6 fois |

Le coût propre de la CTE a été mesuré seul (`WITH RECURSIVE` sur 100 000 lignes, le même calcul, sans recherche) : 0,227
µs par ligne [0,224 ; 0,234], 0,295 µs [0,293 ; 0,297] avec la concaténation de l'e-mail ; les chiffres « sans »
retirent ces médianes : ce sont donc des estimations. Q2 lit la ligne du client du côté de SQLite (comme de celui de
PostgreSQL) et seulement le numéro du client du côté de Cepheus, et SQLite reste plus rapide : Cepheus trouve un texte
par une binary search dans la liste triée de son dictionnaire (environ 18 pas pour 227 387 textes, chaque pas comparant
un texte rangé dans une autre partie de la mémoire), puis les lignes de ce texte par une seconde binary search, là où le
B-tree de SQLite atteint l'e-mail en 3 ou 4 pages. Avec 3 domains, Q4 et Q5 de Cepheus prennent 107 ms et 371 ms ;
SQLite exécute une requête sur un seul thread. Quand cette table a été mesurée pour la première fois (sur le moteur à un
seul niveau de 148ff09), un chargement par le writer prenait 107 s contre 8,6 s pour SQLite : Cepheus réécrivait toute
sa base à chacun de ses 31 merges. Avec les niveaux et les grands groupes, un chargement écrit en deux grands groupes
fait jeu égal avec le `.import` de SQLite (la section plus haut). Les enregistrements de SQLite (des entiers de longueur
variable dans des pages de B-tree) restent environ deux fois plus petits que les mots de 8 octets de Cepheus, et SQLite
charge avec 11 MB là où un grand groupe demande 2,5 à 3,2 GB. Pas mesuré du côté de SQLite : les écritures durables
concurrentes (SQLite a un seul writer à la fois), et les lectures plus grandes que la mémoire. Les lectures ci-dessus
ont été mesurées sur le moteur de 148ff09 ; sur un seul run, les niveaux lisent à la même vitesse (la section suivante),
donc la comparaison tient.

## Le merge écrit dans un fichier (2026-11-08), à 10 millions de faits

Un merge écrit maintenant le nouveau run au fil de l'eau dans son fichier de snapshot, page par page, au lieu de le
construire en mémoire (théorie, section 8 ; G12). Mesuré contre le commit d'avant (c7f25c0, merges en mémoire), compilés
tous deux en release, avec la méthode ci-dessus ; chaque côté sur sa propre base chargée par son propre binaire (mêmes
faits ; format 3 contre format 4, le même snapshot de 245 824 096 octets). `bench.exe merge DIR GROUPS` est nouveau :
GROUPS factures écrites sans merge en arrière-plan, puis un merge de toute la base et du delta (`snapshot`), son temps
et le pic du processus pendant le merge (le pic remis à zéro juste avant, par `/proc/self/clear_refs`).

**La mémoire des exécutions d'écriture avec leurs merges** (la méthode du jalon 2 : six exécutions de 10 s à 256 clients
sur une copie neuve, le pic de mémoire résidente du processus relevé toutes les 0,2 s ; deux tours de chaque côté, en
alternance : 12 exécutions de chaque côté) :

| | pic, médiane [intervalle à 95 %] | du min au max | groupes durables/s, médiane [intervalle à 95 %] |
|---|---:|---:|---:|
| merges en mémoire (c7f25c0) | 2 589 MB [1 785 ; 2 796] | 673 à 2 954 MB | 19 126 [15 751 ; 20 436] |
| merges dans un fichier | 1 126 MB [993 ; 1 188] | 948 à 1 307 MB | 19 388 [17 413 ; 20 966] |

Le pic baisse de 57 % ; le rythme d'écriture ne change pas (les intervalles se recouvrent largement ; une ancienne
exécution est tombée à 1 749 groupes/s pendant un arrêt du disque). Un tour plus tardif de six exécutions du nouveau
côté (l'histogramme propre au merge) : chaque merge en arrière-plan de la base de 245 MB a pris 3,6 à 4,2 s à côté des
écritures (5 merges), et le switch du writer vers lui 44 à 210 ms.

**Un merge** (`bench.exe merge DIR 100000` : 100 000 factures, 400 000 faits, écrits sans merge en arrière-plan, puis un
merge de toute la base et du delta dans un nouveau fichier ; six tours de chaque côté, en alternance ; avec 6
exécutions, l'intervalle à 95 % est [min ; max], 96,9 %) :

| | temps du merge, médiane [intervalle à 95 %] | pic pendant le merge, médiane [intervalle à 95 %] |
|---|---:|---:|
| merges en mémoire (c7f25c0) | 3,21 s [2,49 ; 9,88] | 1 342 MB [1 221 ; 1 452] |
| merges dans un fichier, forcé une fois | 2,29 s [2,17 ; 2,84] | 659 MB [656 ; 660] |
| merges dans un fichier, forcé tous les 8 MiB | 9,07 s [4,88 ; 15,86] | 655 MB [651 ; 656] |

Le processus occupait 409 à 418 MB avant le merge, des deux côtés. Le merge au fil de l'eau est plus rapide que le merge
en mémoire quand il est forcé une seule fois (pas de tri, pas de tableaux), et il occupe moitié moins de mémoire : les
245 MB de pages de la nouvelle base, à côté de l'ancienne dans le cache. Forcé tous les 8 MiB, chaque fsync coûte sur ce
disque : un merge ne force donc par étapes que pendant que des clients écrivent à côté de lui (plus bas), et un merge
que personne n'attend à côté (`snapshot`, la recovery) force une seule fois.

**Un merge dans un processus plafonné à 128 MB**, cache de 32 MB, la même base de 245 MB et un delta de 20 000
factures : le merge dans un fichier prend 7,6 s, avec 63 MB de mémoire résidente avant lui et un pic de 99 MB (les 32 MB
du cache, quelques pages, les tables) ; le merge en mémoire est tué par le plafond (code de sortie 137) dès qu'il
commence (il avait écrit les 20 000 groupes avec 64 MB de mémoire résidente). C'est la borne de la théorie, section 8 :
un merge a besoin du cache, pas de toute la base.

**Les lectures, tout dans le cache** (21 exécutions par question, deux tours de chaque côté, en alternance ; les
médianes avec leurs intervalles à 95 % ; les mêmes réponses) : le chemin de lecture n'a pas changé, et aucune différence
ne sort du bruit.

| question | domains | merges en mémoire (c7f25c0), tours 1 et 2 | merges dans un fichier, tours 1 et 2 |
|---|---:|---|---|
| Q1 | 1 | 0,40 µs [0,38 ; 0,51] ; 0,39 µs [0,37 ; 0,44] | 0,39 µs [0,35 ; 0,66] ; 0,36 µs [0,36 ; 0,37] |
| Q1 | 3 | 0,37 µs [0,36 ; 0,38] ; 0,38 µs [0,37 ; 0,39] | 0,39 µs [0,36 ; 0,67] ; 0,38 µs [0,36 ; 0,41] |
| Q2 | 1 | 1,68 µs [1,61 ; 1,74] ; 1,62 µs [1,60 ; 1,65] | 1,63 µs [1,59 ; 2,00] ; 1,63 µs [1,61 ; 1,80] |
| Q2 | 3 | 1,64 µs [1,60 ; 1,81] ; 1,64 µs [1,58 ; 1,98] | 1,91 µs [1,80 ; 2,21] ; 1,63 µs [1,62 ; 1,68] |
| Q3 | 1 | 4,13 ms [4,09 ; 4,28] ; 4,09 ms [3,98 ; 4,30] | 4,11 ms [4,06 ; 4,42] ; 4,10 ms [4,01 ; 4,48] |
| Q3 | 3 | 4,09 ms [3,97 ; 4,24] ; 4,09 ms [4,03 ; 4,44] | 4,34 ms [4,01 ; 4,79] ; 4,02 ms [4,00 ; 4,26] |
| Q4 | 1 | 233 ms [230 ; 237] ; 231 ms [230 ; 235] | 230 ms [229 ; 248] ; 233 ms [230 ; 245] |
| Q4 | 3 | 105 ms [103 ; 119] ; 104 ms [102 ; 108] | 107 ms [102 ; 112] ; 105 ms [102 ; 113] |
| Q5 | 1 | 1,02 s [1,01 ; 1,07] ; 1,03 s [1,01 ; 1,13] | 1,03 s [1,01 ; 1,10] ; 1,02 s [0,97 ; 1,05] |
| Q5 | 3 | 370 ms [359 ; 406] ; 382 ms [376 ; 402] | 373 ms [360 ; 393] ; 377 ms [365 ; 447] |

Ouverture (redémarrage depuis le snapshot, 15 000 pages lues et vérifiées), quatre exécutions de chaque côté : 408 à 497
ms contre 410 à 503 ms. Après un crash, l'ouverture force maintenant le segment le plus récent et deux dossiers (G5) ;
après une fermeture propre, elle les saute (grâce au marqueur que laisse la fermeture). Sept ouvertures en alternance de
chaque côté, une fois le marqueur en place : la base de 10 M avec un cache de 32 MB (1 313 pages lues) 65 à 72 ms contre
65 à 67 ms ; une base de 10 000 faits 2,8 à 2,9 ms contre 2,8 à 3,0 ms. Sur ce disque, un fsync d'un fichier ou d'un
dossier qui n'a pas changé coûte moins de 0,01 ms ; pendant que le système de fichiers écrit d'autres travaux sur le
disque, il peut coûter des dizaines de ms (une ouverture mesurée à 117 ms contre 66 avant le marqueur).

**Les lectures plus grandes que la mémoire** (cache de 32 MB, le processus plafonné à 128 MB, 5 exécutions par question,
8 domains, les mêmes réponses) : Q1 43,1 µs [41,2 ; 44,6] contre 41,2 µs [39,6 ; 41,8] ; Q2 1,68 µs [1,53 ; 1,99] contre
1,61 µs [1,48 ; 1,66] ; Q3 91,8 ms [88,7 ; 94,6] contre 88,7 ms [86,4 ; 90,9] ; Q4 678 ms [650 ; 795] contre 678 ms
[664 ; 744] ; 3,92 millions de pages lues sur le disque des deux côtés ; pic de 122 MB contre 120 MB. (Avec 5
exécutions, l'intervalle est [min ; max], 93,8 %.)

**Le chargement de 10 M de faits, et ce que les écritures d'un merge coûtent au journal** (`bench.exe load` : 64
clients, des groupes de 83 faits, environ 33 merges à mesure que la base grandit ; une exécution par ligne, en
alternance) :

| | chargement | pic | p99 du fsync du journal | max | p99 du switch de merge |
|---|---:|---:|---:|---:|---:|
| merges en mémoire (c7f25c0) | 62,5 s ; 79,3 s ; 70,8 s | 2 841 ; 2 962 ; 2 874 MB | 72 ; 46 ms | 0,84 ; 0,72 s | 459 ; 114 ms |
| merges dans un fichier, forcé une fois | 124,2 s | 1 844 MB | | | |
| merges dans un fichier, forcé tous les 8 MiB pendant que des clients écrivent | 134,7 s ; 153,4 s | 1 813 ; 1 500 MB | 187 ; 203 ms | 2,96 ; 3,92 s | 802 ; 529 ms |

Ici, le merge dans un fichier perd : un chargement n'est fait que d'écritures, et chacun de ses merges réécrit toute la
base, environ 3,3 GB en tout sur le chargement, à côté du journal, dont chaque client attend les fsync (un merge en
mémoire n'écrit rien). À 3 M de faits (une exécution chacun) : merges en mémoire 16,4 et 19,5 s ; dans un fichier forcé
une fois 32,6 s (un fsync du journal jusqu'à 4,7 s), forcé tous les 8 MiB 23,5 s, forcé tous les 8 MiB seulement pendant
que le journal écrit 20,3 s ; régler le rythme des écritures du merge (un token bucket : chaque écriture prend des
jetons, qui reviennent à un rythme fixe, comme le rate limiter de RocksDB) à 32 et 64 MB/s a donné 23,8 et 23,3 s, aucun
gain, et a été laissé de côté. Les écritures à 256 clients avec un merge toutes les 10 s environ (plus haut) ne voient
pas la différence ; un chargement en masse soutenu la voit, et d'autant plus que la base grandit. Le remède est d'écrire
moins d'octets par changement : plus d'un niveau sur le disque (théorie, section 9), ou un seuil de merge plus haut
($n/8$ divise les octets par deux et double la mémoire du delta).

## Jalon 2 à 10 millions de faits

Build release de 804656f (pages et cache), toute la base dans le cache (1 GiB), 21 exécutions par question, 2 tours en
alternance avec PostgreSQL ; une case est la médiane du tour qui a la médiane la plus haute, avec son intervalle à 95 %.

| question | Cepheus, 1 cœur | PostgreSQL, 1 processus | Cepheus, 3 domains | PostgreSQL, 3 processus |
|---|---:|---:|---:|---:|
| Q1 chaque fait d'une facture, par id | **0,39 µs** [0,38 ; 0,41] | 4,73 µs [4,69 ; 4,77] (moteur) ; 26 µs (socket) | 0,39 µs | |
| Q2 un client par e-mail (unique) | **1,68 µs** [1,66 ; 1,72] | 5,68 µs [5,65 ; 5,72] (moteur) ; 26 µs (socket) | 1,66 µs | |
| Q3 les factures impayées des clients d'une ville (4 299 lignes) | **4,07 ms** [4,05 ; 4,10] | 10,55 ms [10,49 ; 10,79] | 4,06 ms | 14,58 ms [14,43 ; 14,78] |
| Q4 la somme des impayées par ville (453 866 factures) | **230,7 ms** [228,7 ; 233,7] | 236,5 ms [235,2 ; 237,5] | **107,3 ms** [102,5 ; 112,4] | 109,1 ms [108,3 ; 109,2] |
| Q5 les triangles du graphe des follows (114 rotations) | 1,03 s [1,02 ; 1,03] | 1,03 s [1,02 ; 1,04] | **371 ms** [367 ; 373] | 603 ms [599 ; 605] (2 processus : 1 worker lancé) |

Q1 à Q3 de PostgreSQL par son socket (pgbench, requêtes préparées, un client) : 26 µs, 26 µs, 14,6 ms (avec 2 workers
permis ; 7,4 ms sans aucun : son plan parallèle est plus lent pour Q3).

Ce que le jalon 2 a changé (chaque point mesuré contre le commit d'avant, en alternance) :
- **Questions en parallèle** (89ec951, c67e52d) : Q4 sur 3 domains 198 -> 103-107 ms, Q5 955 -> 360-371 ms. La première
  version ne gagnait que 1,7x sur Q4 : les 453 866 candidats du premier niveau étaient vérifiés contre les autres
  patterns sur un seul domain (42-45 ms sur 124, mesuré ; la loi d'Amdahl, selon laquelle la part séquentielle d'un
  calcul borne ce que le parallélisme peut gagner, ajustée sur 1, 3 et 4 domains, donnait 78 ms de travail séquentiel).
  Maintenant, chaque tranche vérifie ses propres candidats, et les domains prennent des tranches tour à tour à un
  compteur partagé.
- **Pages et cache** (804656f) : quand tout est en mémoire, Q1 +5 %, Q2 -4 %, Q3 +8 %, Q4 +13 %, Q5 +3 à +8 %, par
  rapport à la base mappée en mémoire (le fichier vu directement comme de la mémoire ; théorie, section 7, pour le
  pourquoi et ce qui a été essayé).
- **Un bug corrigé** (b96dec5) : l'intersection triée triait chaque liste de candidats d'un niveau, si bien qu'une
  question pouvait prendre $O(N \log N)$ par binding au lieu de $O(\text{plus petite liste})$ ; chaque question est
  maintenant vérifiée contre la borne de Generic Join.

### Les écritures durables

08e8f98, 3 tours en alternance avec PostgreSQL, chaque tour sur une copie neuve de la base de 10 M (7 exécutions de 10
s : 1, 8, 64 et 256 clients aussi vite qu'ils vont, puis 256 clients à des rythmes fixes) ; un groupe de Cepheus crée
une nouvelle facture (4 faits), PostgreSQL insère la même ligne de facture ; les deux sont durables (fsync).
Throughput : la médiane des tours, et chaque tour ; latences (tirées d'un histogramme de chaque écriture) : l'étendue de
chaque percentile sur les tours.

| écritures durables, 3 tours de 10 s | groupes/s de Cepheus (médiane ; tours) | insertions/s de PostgreSQL | Cepheus p50 / p99 / p99.9 ms | PostgreSQL p50 / p99 / p99.9 ms |
|---|---:|---:|---:|---:|
| 1 client, aussi vite qu'il va | 181 (208, 181, 175) | 185 (188, 185, 135) | 3,29-3,65 / 15,8-21,5 / 75,8-268 | 3,18-3,62 / 19,2-53,2 / 130-459 |
| 8 clients, aussi vite qu'ils vont | 646 (917, 284, 646) | 990 (1 077, 990, 591) | 5,70-6,85 / 32,1-627 / 163-1 998 | 6,08-6,72 / 21,0-153 / 34,3-390 |
| 64 clients, aussi vite qu'ils vont | 7 147 (7 147, 7 765, 4 185) | 4 625 (7 779, 4 625, 2 439) | 6,14-10,2 / 28,0-135 / 59,6-524 | 6,43-6,56 / 23,0-416 / 307-1 991 |
| 256 clients, aussi vite qu'ils vont | 14 182 (14 182, 17 192, 14 141) | 19 559 (19 559, 12 742, 20 863) | 9,79-10,9 / 66,0-264 / 326-598 | 9,54-12,6 / 35,8-102 / 309-1 917 |
| 256 clients à 2 000 par seconde (open loop) | 1 999 (1 998, 1 999, 1 999) | 1 994 (1 994, 1 999, 1 940) | 5,12-15,6 / 98,8-1 655 / 179-1 745 | 8,89-20,6 / 586-6 128 / 762-6 357 |
| 256 clients à 5 000 par seconde (open loop) | 4 997 (4 997, 4 766, 4 997) | 4 957 (5 010, 4 957, 4 747) | 6,24-10,5 / 146-717 / 483-791 | 8,03-68,6 / 442-3 654 / 586-3 785 |
| 256 clients à 10 000 par seconde (open loop) | 9 993 (9 993, 9 995, 9 982) | 9 879 (9 879, 9 847, 9 888) | 9,54-24,3 / 202-1 032 / 233-1 044 | 6,66-219 / 774-1 311 / 885-1 352 |

Ce que cela dit. Le throughput est à égalité, et borné des deux côtés par le nombre de fsync par seconde du disque
multiplié par la taille d'une frame (théorie, section 2) ; ce disque était bruyant pendant ces tours (le fsync d'une
frame : p99.9 jusqu'à 450 ms, max jusqu'à 2,6 s), si bien que les tours d'un même côté diffèrent jusqu'à un facteur 3,
plus que les deux côtés ne diffèrent entre eux. Les latences qui comptent sont celles de l'open loop : avec des
écritures dues à un rythme fixe, chaque écriture retardée par un arrêt est mesurée. Là, le p99 de Cepheus est plus bas
que celui de PostgreSQL à chaque rythme (à 2 000 par seconde : 0,1 à 1,7 s contre 0,6 à 6,1 s), et sa médiane aussi (5 à
24 ms contre 7 à 219 ms). Les latences de la closed loop paraissent meilleures qu'elles ne le sont : un client arrêté
par un long fsync n'envoie rien pendant ce temps, si bien que les écritures qui auraient attendu ne sont jamais comptées
(la coordinated omission). Cepheus tournait ici avec un plafond de 4 GB : ses merges construisaient encore la base en
mémoire (des pics de 0,3 à 2,4 GB dans ces exécutions).

### Plus grand que la mémoire

Cepheus avec un cache de 32 MB (`CACHE_MB=32`), PostgreSQL avec shared_buffers à 32 MB (`SHARED=32MB`, work_mem à 64 MB
comme plus haut), chaque processus plafonné à 128 MB, sans swap ; la base fait 245 MB (le snapshot de Cepheus) et 284 MB
(le data directory de PostgreSQL). 5 exécutions par question (Q5 : 1, après une pour chauffer) ; les mêmes réponses des
deux côtés.

| question | Cepheus, 1 cœur | PostgreSQL, 1 processus | Cepheus, 3 domains | PostgreSQL, 3 processus |
|---|---:|---:|---:|---:|
| ouverture | 67 ms, 64 MB résidents (1 313 pages lues : les tables d'offsets) | | | |
| Q1 une facture par id | **41 µs** [41 ; 42] | 176 µs (moteur) ; 1,18 ms (socket) | 41 µs | 177 µs ; 1,23 ms |
| Q2 un client par e-mail | **1,8 µs** | 5,5 µs ; 25 µs | 1,7 µs | 5,4 µs ; 27 µs |
| Q3 les impayées d'une ville (une ville différente à chaque appel) | **89 ms** [88 ; 91] | 446 ms (socket, ville au hasard) | 88 ms | 326 ms |
| Q4 la somme des impayées par ville | **385 ms** [384 ; 386] | 697 ms [695 ; 707] | **247 ms** [223 ; 251] | 658 ms [620 ; 790] |
| Q5 les triangles | 102 s | **1,05 s** [1,04 ; 1,13] | 198 s | le serveur a été tué par le plafond |
| pic de mémoire résidente | 79 MB | | 105 MB | |

Q1 à Q4 lisent 3,9 M de pages sur le disque (chacune vérifiée par son CRC). Le Q3 « moteur seul » de PostgreSQL répète
une seule ville (7,8 ms une fois ses pages dans ses buffers), donc c'est son temps par le socket, avec une ville au
hasard comme pour Cepheus, qui est comparé. Avec 2 workers parallèles, le serveur de PostgreSQL a été tué par le plafond
de 128 MB pendant Q5 (chaque worker peut prendre work_mem, 64 MB, pour ses hash joins, des joins qui construisent une
hash table avec l'une de leurs entrées). Q5 est là où Cepheus perd, d'un facteur 100 : ses lignes sont rangées par
chose, donc les liens follow d'un client sont mêlés aux lignes de ses 20 factures, et la question des triangles lit des
pages au hasard dans 120 MB de lignes par chose, pour quelques octets chacune (18,8 M de pages lues en 6 exécutions avec
un cache de 48 MB) ; PostgreSQL garde `follows` dans une table à lui (23 MB avec son index), qui tient dans ses 32 MB.
Un troisième ordre des lignes de Cepheus (propriété, chose) rendrait cette lecture locale (théorie, section 7). Sur 3
domains, Q5 est plus lent que sur 1 : les miss sont lus un par un sous le lock du cache.

### Où va le temps d'une écriture (256 clients, étape 4)

5 tours de 10 s (c67e52d) : 15 775 à 19 009 groupes par seconde (médiane 18 553 ; PostgreSQL 13 092 à 19 627, médiane
18 048). Le p99 d'un client (40 à 62 ms) vaut environ deux fois le p99 du fsync du journal (19 à 30 ms) : une frame
attend celle qui est en train d'être forcée, puis son propre fsync. Le travail du writer est petit (p99 de 3,2 à 4,0 ms
par batch) ; GC : environ 1 500 minor collections (sur le petit heap des objets jeunes) et 10 à 22 major collections en
10 s. Le p99.9 (305 à 930 ms) suit les arrêts des fsync du disque (p99.9 de 188 à 434 ms, max de 287 à 529 ms), qu'une
boucle de fsync seuls montre aussi (exploitation, Les disques). Les tours du jalon 1 avec un p99 de 170 à 460 ms étaient ces
arrêts.

## Jalon 1 à 10 millions de faits (ancienne méthode : min et médiane de 5 tours, meilleur de 3 pour les écritures)

| question | Cepheus | PostgreSQL, moteur seul | PostgreSQL, par son socket |
|---|---:|---:|---:|
| Q1 chaque fait d'une facture, par id | **0,35 µs** | 4,7 µs | 25 µs |
| Q2 un client par e-mail (unique) | **1,6 µs** | 5,6 µs | 25 µs |
| Q3 les factures impayées des clients d'une ville (3 patterns, 4 299 lignes) | **3,1 ms** | 14,5 ms | 15 ms |
| Q4 la somme des impayées par ville (4 patterns, 453 866 factures, groupées) | 198 ms | **110 ms** (3 processus) ; 236 ms sur un cœur | |
| Q5 les triangles du graphe des follows (cyclique, 568 k liens) | 968 ms | **600 ms** (3 processus) ; 1 000 ms sur un cœur | |

À 1 million de faits : Q1 0,25 µs contre 4,5 µs ; Q2 0,96 µs contre 4,9 µs ; Q3 0,27 ms contre 1,0 ms ; Q4 18 ms contre
22 ms ; Q5 63 ms contre 50 ms.

| écritures durables, groupes par seconde | 1 client | 8 | 64 | 256 |
|---|---:|---:|---:|---:|
| Cepheus, meilleur de 3 | 308 | 1 177 | 9 657 | 16 277 |
| PostgreSQL, meilleur de 3 | 237 | 1 059 | 7 078 | 21 348 |
| Cepheus, médiane de 3 | 225 | 671 | 5 916 | 4 746 |
| PostgreSQL, médiane de 3 | 218 | 988 | 6 527 | 19 638 |
| groupes par frame de Cepheus | 1 | 4 | 32 | 119 |

| autre | Cepheus | PostgreSQL |
|---|---:|---:|
| charger 10 M de faits | 89,5 s par le writer (112 000 faits/s), snapshot 4,7 s | `COPY`, index, `VACUUM ANALYZE` : environ 1 min |
| ouverture après un redémarrage (snapshot vérifié) | 472 ms | (démarrage du serveur non comparé) |
| mémoire après l'ouverture / taille sur le disque | 312 MB résidents ; journal et 2 snapshots sur le disque | data directory de 740 MB |
| recovery après kill -9 (40 processus tués, petite base) | médiane 6 ms, max 13,5 ms | |

### Ce que disaient alors les chiffres

- **Recherches ponctuelles et joins sélectifs : Cepheus est 3 à 70 fois plus rapide.** Les faits d'une chose sont à deux
  lectures de tableau (des ids denses) ; une question tourne dans le processus de l'application, sans round trip
  (l'aller-retour d'une requête et de sa réponse sur le réseau) ni plan cache (le cache des plans de requêtes déjà
  calculés) à consulter. Par le socket, ce que paie une application de PostgreSQL, l'écart est de 15 à 70 fois.
- **Grands parcours et agrégats (Q4), et la requête des triangles (Q5) : PostgreSQL est plus rapide, parce qu'il utilise
  trois processus pour une requête.** Sur un cœur, il est 1,2 fois plus lent que Cepheus sur Q4, et à égalité sur Q5.
  Cepheus répond aujourd'hui à une question sur un seul cœur ; les questions en parallèle (des domains OCaml sur une
  vue, qui n'a besoin d'aucun lock) sont l'étape suivante. Le graphe de Q5 est uniforme (5 liens par client), et les
  joins deux par deux y restent petits ; l'avantage de Generic Join se montre sur des graphes déséquilibrés (où quelques
  choses ont beaucoup de liens), pas encore mesurés. L'intersection triée des listes de candidats (à la manière de
  Leapfrog) réduirait aussi les recherches de Q5.
- **Écritures durables : à égalité.** Les deux sont bornés par le nombre de fsync par seconde du disque multiplié par la
  taille d'une frame, comme le dit la formule du group commit (théorie, section 2). Cepheus est devant de 1 à 64 clients
  dans les meilleurs tours ; PostgreSQL est devant à 256. Deux causes du côté de Cepheus : la compaction (un autre nom
  du merge) est synchrone (une pause allant jusqu'à 0,6 s toutes les quelques secondes sous de fortes écritures : les
  latences p99 de 300 à 600 ms), et les 256 threads clients partagent un seul domain OCaml. Des merges en arrière-plan,
  par niveaux (le plan LSM), suppriment la première. Les médianes montrent à quel point le disque partagé était bruyant
  pendant ces exécutions.
- **La recovery** est rapide parce que le journal après le snapshot le plus récent est court ; un snapshot à 10 M de
  faits prend 4,7 s à écrire et 0,47 s à vérifier et à mapper à l'ouverture.

## Pas encore mesuré

Plusieurs bases qui écrivent en même temps, un disque de classe serveur, des graphes déséquilibrés, la réplication ; les
lectures de SQLite plus grandes que la mémoire (ses écritures durables : une transaction par client à 1 M de faits,
[le chargement](#le-chargement)) ; Oracle, Datomic, RocksDB, Neo4j, FoundationDB et CockroachDB, qui ne sont pas
installés sur la machine de test (comparés sur leur conception à la page [comparaison](comparison.md)).
