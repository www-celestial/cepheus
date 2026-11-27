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
  coordonnée, [Tene 2015]). En open loop (boucle ouverte), les écritures sont dues à une cadence fixe, tous les clients
  ensemble (avec $C$ clients, la $k$-ième écriture du client $c$ à $t_0 + (k C + c) / \text{cadence}$), et la latence d'une écriture compte depuis l'instant où
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
| `bench.exe pages DIR FACTS` | les questions avec des opérateurs et un ordre : une page de 20 des factures impayées, les plus gros totaux d'abord, par le chemin de l'index (qui lit l'index des totaux du plus grand vers le bas) et par le chemin du heap (qui répond à toute la question et garde les 20 meilleures lignes dans un heap, un tas), la première page et la 101e, contre la réponse entière triée par le programme ; `Not` et `Prefix`, chacun contre ce que faisait un programme avant eux ; `Less` (une vérification de chaque lien de suivi, et un range de l'index des totaux sous le total d'une facture) et `Optional` (les clients d'une ville, et chaque client, avec les clients que chacun suit), chacun à côté de la question simple |
| `bench.exe snapshot DIR` | un merge complet d'une base (`snapshot`), chronométré : tous ses runs en un seul |
| `bench.exe write DIR CLIENTS SECS [RATE]` | des écritures durables (sur le disque même, couvertes par un fsync terminé) d'une nouvelle facture (4 faits) par CLIENTS threads : aussi vite qu'elles vont, ou RATE groupes par seconde en tout (open loop) |
| `bench.exe merge DIR GROUPS` | GROUPS factures sans merge en arrière-plan, puis un seul merge (`snapshot`) : son temps et le pic de mémoire du merge seul |
| `bench.exe fsync DIR SECS append\|overwrite` | le système de fichiers seul : une frame de 9 000 octets et son fsync en boucle, ajoutée en fin de fichier ou écrite par-dessus des zéros forcés sur le disque avant |
| `bench.exe trace DIR FACTS OUT uniform\|zipf day\|points\|scan` | enregistre les lectures de pages d'une journée de questions, pour l'étude du cache |
| `bench.exe cachesim TRACE` | LRU, CLOCK, 2Q, ARC, SIEVE, S3-FIFO, W-TinyLFU et l'optimum de Belady sur une trace enregistrée |
| `bench.exe stats NAME [us]` | le résumé des nombres lus sur stdin, un par ligne, en ms (avec `us` : des latences en µs, versées dans un histogramme) : c'est ainsi que les temps des autres côtés passent par les mêmes statistiques |
| `bench.exe cpu DIR N` | le travail du writer seul : N groupes de 5 faits dans un fork de la base (une copie temporaire de la base, où l'on écrit sans rien écrire sur le disque) |
| `bench.exe crc` | CRC-32C seul (un checksum : un court nombre calculé à partir d'octets, qui change s'ils changent) sur 24 octets, 4 KiB, 16 KiB, 1 MiB et 96 MiB, depuis un décalage impair : le temps d'un appel et les MB/s, médiane et intervalle à 95 % sur `RUNS` exécutions |
| `sbench.exe watches DIR` | un changement sous un watch (une question vivante, que le serveur tient à jour) de `Not`, `Or`, `In` et `Prefix` (un hub chacun, le hub étant le thread qui calcule les questions vivantes d'une base ; les changements faits en mémoire), contre la question à laquelle on répond de nouveau en entier : 21 changements chacun |
| `rbench.exe load DIR CSVDIR`, `rbench.exe run DIR` | les rapports : les données (10 000 clients, 245 000 factures) et leur CSV pour PostgreSQL ; chaque agrégat sur 1, 100 et 10 000 groupes et les totaux par mois (`Trunc`), tels que le serveur y répond (`Answer.answer`) |
| `abench.exe DIR [PAGES]`, `mbench.exe DIR` | les questions d'avant, pour un A/B de deux builds sur une même base, chaque fichier compilant contre le build d'avant le changement : `abench` un Give d'un join, des groupes, une page triée, `Not`, un range, `Optional` (les données de rbench), et avec `PAGES` (les données de bench.exe load) les questions de `bench.exe pages` auxquelles `Less` et `Optional` répondent, comme le serveur y répond (`Answer` : des mots de l'index, aucune valeur faite), comme `Cepheus.ask` les donne (les valeurs de chaque ligne) et le join seul (un compte) ; `mbench` de petites questions en boucle, le coût fixe d'un fold (un fold d'un seul fait, `Prefix`, Q3 compté, `Not`, `Optional`, une page triée, un find de chaque e-mail, le fold de Q4 ; les données de bench.exe) |
| `kbench.exe load DIR N`, `run DIR`, `fork N`, `mixed DIR N`, `csv DIR OUT` | des pages d'un kind par les ids de ses choses : N items (un nom, un tenant, un int) dans un seul run ; une page de 51 par id croissant et décroissant, la première et celle après l'item du milieu, celles d'un tenant de même, chacune vérifiée contre les ids qu'elle doit donner ; sur un fork rempli en mémoire ; sur un fork dont le delta tient N choses d'un autre kind et un item renommé ; les items en CSV pour `pg.sh keyset` |
| `wbench.exe run DIR` | les fenêtres (le protocole 10) sur les données de rbench : un total cumulé, une moyenne mobile de 3, un rang par total et la ligne d'avant, sur les 245 000 factures en un seul groupe, celui de chaque ville (100) et de chaque client (10 000) ; les 3 dernières factures de chaque client et la dernière (`Each` et `Limit`) ; les totaux mensuels à Paris avec leurs fenêtres (un rapport) ; une page de 51 avec son total cumulé, la première et celle après la 200 000e ligne, à côté des mêmes pages sans fenêtres ; `pg.sh windows ROOT index\|run` demande la même chose à PostgreSQL (`OVER`, `LATERAL`, `DISTINCT ON`), avec les index qu'un utilisateur fait pour elles |
| `bench/pg/pg.sh init\|start\|load\|read\|write\|stop ROOT ...` | le côté PostgreSQL, sur un cluster à lui (`ROOT/data`, port 5544) : `start ROOT MEM` plafonne la mémoire du serveur (`SHARED=32MB` fixe `shared_buffers`), `read ROOT NCLIENTS` (`WORKERS=k` workers parallèles par requête, `QS`, `RUNS`), `write ROOT NCLIENTS CLIENTS SECS` (`RATE=r` : open loop ; `COUNTER=1` : chaque transaction incrémente une même ligne de compteur partagée), `ops ROOT` (les questions de `bench.exe pages` auxquelles répondent `Less` et `Optional`, avec un index sur `invoice (total)`, dans trois périmètres : le moteur seul, chaque valeur sérialisée au serveur par le `SERIALIZE TEXT` d'`EXPLAIN`, chaque valeur reçue par un programme par libpq, la latence moyenne de pgbench), `keyset ROOT load\|run DIR` (les pages de kbench : `WHERE id > $1 ORDER BY id LIMIT 51` sur la clé primaire, celles d'un tenant sur `(tenant, id)`) |
| `bench/sqlite/sqlite.sh load\|read ROOT ...` | le côté SQLite, un seul fichier `ROOT/bench.db` : `load ROOT CSVDIR`, `read ROOT NCLIENTS` (`QS`, `RUNS`, `CACHE_MB`) |
| `bench/ops.sh cepheus\|cepheus-replay\|pg\|pg-replay\|sqlite ROOT CSVDIR ...` | la sauvegarde et la restauration des trois côtés : `cepheus backup`, `verify`, `restore` jusqu'à la fin et jusqu'à un groupe ; `pg_basebackup`, `pg_verifybackup`, une restauration et une restauration à un instant donné ; `.backup`, `integrity_check` et `.restore` de SQLite ; tout l'historique rejoué (`-replay`) |
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

## Les lignes avec chaque valeur faite, et les cascades (2026-11-26), à 1 million de faits

**Méthode.** Les trois questions que PostgreSQL 18.6 gagnait encore dans [la section plus
bas](#les-cas-que-postgresql-gagnait-encore-2026-11-26-à-1-million-de-faits) (un check `Less(a, b)` des liens de suivi
et `Optional` sur chaque client, chacun avec chaque valeur faite, et une cascade de 10 000 lignes), avec à côté
l'intervalle de `Less`, la cascade de 100 lignes et le `clear` de 10 000 notes, sur les mêmes données. Le temps de
PostgreSQL dans cette section, `EXPLAIN (ANALYZE, TIMING OFF)`, exécute le plan et ne fait aucune sortie : chaque côté
est donc maintenant mesuré dans les deux mêmes périmètres (le scope : ce que le temps compte). **Le moteur seul** : les
mots d'index de Cepheus comme son serveur répond (`Answer.answer`) à côté de cet `EXPLAIN`. **Chaque valeur faite** :
les lignes de valeurs de `Cepheus.ask` dans le programme qui demande, à côté d'un programme qui reçoit chacune des
lignes de PostgreSQL par libpq (la bibliothèque client de PostgreSQL ; pgbench, un client, des prepared statements sur
le socket Unix : libpq lit chaque ligne dans son résultat) ; entre les deux, `EXPLAIN` avec `SERIALIZE TEXT` (PostgreSQL
17 et après : chaque valeur faite dans sa forme texte au serveur, aucune envoyée). `abench.exe DIR PAGES` et
`dbench.exe delete` du côté de Cepheus, `pg.sh ops` et `pg.sh fk run` du côté de PostgreSQL. Cepheus sur 8 domains (son
défaut, un par thread), PostgreSQL comme il planifie (un seul process pour chacune de ces questions : aucun worker
parallèle). Trois côtés à chacun des 21 tours, leur ordre tourné à chaque tour : les binaires de main (ec4bb86), ceux du
changement, PostgreSQL ; chacun une médiane de 11 exécutions (les questions de PostgreSQL : 3 exécutions de chaque
périmètre ; les suppressions sur un fork jeté, celles de PostgreSQL dans une sous-transaction annulée). Donnés : la
médiane des tours, entre crochets leur plus petit et leur plus grand ; maintenant sur main, la médiane des rapports des
tours [plus petit, plus grand] et les tours où maintenant était plus rapide. Une charge moyenne de 2,0 à 4,0 sur les 8
threads (les tests d'autres jobs). Cepheus compte 28 262 liens de suivi vers un client plus récent et PostgreSQL
28 265 : les ids que le générateur donne à 3 clients ne sont pas dans l'ordre des ids de leurs choses. Où le temps
passait a été mesuré d'abord, phase par phase (un programme de travail qui chronomètre chaque phase et compte les mots
qu'elle alloue), par site d'allocation (le `Gc.Memprof` d'OCaml, qui échantillonne les allocations) et par des
échantillons de la pile d'un process sous gdb.

| question | main | maintenant | maintenant / main | PostgreSQL 18.6 | maintenant |
|---|---:|---:|---:|---:|---|
| les liens de suivi vers un client plus récent (`Less(a, b)`), 28 262 lignes, chaque valeur faite | 7,58 ms [6,36, 13,8] | **4,47 ms** [3,40, 7,22] | 0,60 [0,32, 0,94], 21/21 | 6,69 ms [6,15, 11,3] | Cepheus, 1,5 fois (PostgreSQL 1,1 avant) |
| la même, le moteur seul (des mots de l'index ; `EXPLAIN ANALYZE`) | 3,62 ms [3,37, 8,76] | **2,24 ms** [2,04, 3,93] | 0,61 [0,26, 0,80], 21/21 | 3,68 ms [3,53, 6,10] | Cepheus, 1,6 fois (à peu près pareil avant) |
| les factures sous le total d'une facture (`Less`), 122 962 lignes, chaque valeur faite | 21,9 ms [20,2, 36,3] | **18,2 ms** [17,1, 33,3] | 0,85 [0,56, 1,60], 20/21 | 28,7 ms [26,7, 36,5] | Cepheus, 1,6 fois (1,3 avant) |
| la même, le moteur seul | 10,1 ms [9,06, 17,5] | **8,19 ms** [7,67, 16,0] | 0,84 [0,49, 1,32], 18/21 | 19,4 ms [18,4, 24,3] | Cepheus, 2,4 fois (1,9 avant) |
| chaque client avec les clients qu'il suit (`Optional`), 56 797 lignes, chaque valeur faite | 15,7 ms [14,1, 31,6] | **8,82 ms** [8,02, 16,9] | 0,54 [0,26, 0,99], 21/21 | 17,5 ms [16,2, 20,5] | Cepheus, 2,0 fois (1,1 avant) |
| la même, le moteur seul | 9,52 ms [8,83, 37,1] | **5,67 ms** [5,05, 9,80] | 0,59 [0,18, 1,03], 20/21 | 12,1 ms [11,5, 13,1] | Cepheus, 2,1 fois (1,3 avant) |
| une facture et ses 10 000 lignes, `cascade` | 19,9 ms [19,2, 21,3] | 16,7 ms [15,6, 24,1] | 0,84 [0,78, 1,24], 18/21 | **4,92 ms** [4,57, 8,14] | PostgreSQL, 3,4 fois (4,0 avant) |
| une facture et ses 100 lignes | 140 µs [132, 222] | **129 µs** [117, 197] | 0,93 [0,58, 1,38], 15/21 | 171 µs [120, 317] | Cepheus, 1,3 fois (1,2 avant) |
| une facture et le lien de ses 10 000 notes, `clear` | 9,50 ms [8,65, 12,1] | **6,21 ms** [5,14, 7,84] | 0,64 [0,55, 0,81], 21/21 | 88,7 ms [74,0, 104] | Cepheus, 14 fois (9,3 avant) |

Le `clear` de PostgreSQL a ralenti au fil des tours, de 74 à 104 ms par tour : chaque `SET NULL` annulé laisse 10 000
versions mortes de lignes jusqu'à ce que l'autovacuum les prenne ; il prenait 46,5 ms dans [la section des
suppressions](#les-suppressions-et-les-liens-qui-nomment-un-kind-2026-11-25).

Les mêmes questions dans chaque périmètre, les médianes des tours ; Cepheus sur 8 domains, et entre crochets sur un seul
domain épinglé à un cœur (`taskset -c 2`, `CEPHEUS_DOMAINS=1`, 11 tours de plus de main et maintenant alternés).
PostgreSQL a exécuté chacune dans un seul process (ses plans : aucun worker parallèle).

| question | PostgreSQL : le moteur seul | chaque valeur sérialisée | chaque valeur reçue (libpq) | Cepheus : le join seul (un compte) | les mots d'index (`Answer`) | chaque valeur (`Cepheus.ask`) |
|---|---:|---:|---:|---:|---:|---:|
| les liens de suivi vers un client plus récent (`Less(a, b)`) | 3,68 ms | 6,33 ms | 6,69 ms | 1,61 ms [4,61 ms] | 2,24 ms [5,07 ms] | 4,47 ms [8,44 ms] |
| les factures sous le total d'une facture (`Less`) | 19,4 ms | 27,1 ms | 28,7 ms | 8,48 ms [18,1 ms] | 8,19 ms [19,1 ms] | 18,2 ms [33,9 ms] |
| chaque client avec les clients qu'il suit (`Optional`) | 12,1 ms | 18,0 ms | 17,5 ms | 5,25 ms [4,93 ms] | 5,67 ms [6,26 ms] | 8,82 ms [10,4 ms] |

![Une ligne par question, sur une échelle logarithmique de combien de fois un côté est plus rapide, un point gris pour les binaires de main et un point en couleur pour maintenant, une flèche du premier au second. Avec chaque valeur faite, le check de Less : Cepheus, 1,5 fois (PostgreSQL 1,1 avant) ; l'intervalle de Less : Cepheus, 1,6 fois (1,3 avant) ; Optional sur chaque client : Cepheus, 2,0 fois (1,1 avant). Le moteur seul : Cepheus, 1,6 fois (à peu près pareil avant), Cepheus, 2,4 fois (1,9 avant) et Cepheus, 2,1 fois (1,3 avant). Une cascade de 100 lignes : Cepheus, 1,3 fois (1,2 avant) ; un clear de 10 000 notes : Cepheus, 14 fois (9,3 avant) ; une cascade de 10 000 lignes : PostgreSQL, 3,4 fois (4,0 avant).](images/bench-rows.svg)

- **`Less` et `Optional` : où le temps passait.** Sur main, le check de `Less` prenait 2,6 à 3,0 ms pour son join, 3,5
  avec ses mots d'index et 6,8 à 7,8 avec chaque valeur, dont 1,2 dans les minor collections du domain qui demande (les
  collectes du jeune tas, le minor heap, où chaque domain alloue). Le join faisait environ un million de mots de déchets
  par appel : à chaque binding de son premier niveau, les bornes de `Less` en closures et en références (18 mots), les
  closures des candidats du niveau suivant (environ 30), le compte d'une slice rendu en tuple dans une option, et la
  closure d'`Ask` qui garde un binding (4 mots par binding) ; et chaque binding du premier niveau cherchait trois fois
  dans l'index des valeurs, pour compter sa slice, pour compter ses choses et pour les lire. Une ligne de valeurs
  coûtait deux cellules de liste, un `Array.make` (un appel au runtime en C) et une closure (une application partielle).
  `Optional` sur chaque client faisait une liste des valeurs de chaque client, la renversait, et copiait chaque ligne
  hors du buffer. Les minor collections d'OCaml 5 arrêtent chaque domain et copient chaque jeune bloc encore vivant dans
  le major heap ([Sivaramakrishnan 2020](references.md#la-gestion-des-buffers-et-le-cache)) : chaque ligne d'une réponse
  est vivante, donc chaque bloc d'une ligne est copié une fois.
- **Ce qui a changé, chaque point mesuré seul** (21 tours alternés avec le build d'avant lui ; la médiane des rapports
  des tours, et un sign test bilatéral sur les tours ; chacun gardé parce qu'il gagnait et ne coûtait rien ailleurs) :
  1. Les lignes d'`Optional` écrites l'une après l'autre dans le buffer partagé du fold, sans liste des valeurs d'une
     chose ni copie par ligne, et les `Not` vérifiés sans closure par binding : le join d'`Optional` 0,55, ses mots
     d'index 0,79, ses valeurs 0,81 (p < 0,001).
  2. Les lignes de `Cepheus.ask` rassemblées par chaque domain en morceaux d'au plus 256, un bloc du minor heap chacun,
     et mises en liste une seule fois à la fin depuis la dernière ligne (une cellule de liste par ligne) ; une ligne
     d'au plus 4 colonnes faite comme un littéral de tableau, dans le minor heap sans appel en C ; aucune application
     partielle : les valeurs du check 0,87 (p 0,027), celles d'`Optional` 0,70 (p 0,0002).
  3. Les lignes d'`Optional` du serveur poussées en mots, cellule par cellule, un mot ou 0 et le masque après eux,
     sans tableau par ligne : les mots d'index d'`Optional` 0,80 (p 0,0002).
  4. Les bornes de `Less` lues dans des tableaux faits une fois par question qui en a, sans closure à chaque binding ;
     le compte d'une slice sans tuple ni option ; les candidats d'un niveau lus directement dans les lignes du run que
     son compte a trouvées, sans deuxième ni troisième recherche : le join du check 0,83 (p 0,0015), ses valeurs 0,91
     (p 0,027).
  5. Les valeurs que prend une propriété lues dans les mots de rang de son index des valeurs, un bit par valeur et
     aucune ligne décodée, là où chaque ligne par valeur était lue et les doublons sautés (le premier niveau du check :
     les clients qui suivent quelqu'un) : le join 0,60, les mots d'index 0,72, les valeurs 0,81 (plus rapide dans 18 à
     21 des 21 tours).

  C'est la late materialization, la matérialisation tardive
  ([Abadi 2007b](references.md#la-gestion-des-buffers-et-le-cache)) : le join porte des mots d'index, le serveur les
  envoie ainsi, et les valeurs d'une ligne ne sont faites qu'une fois son binding devenu une réponse. `Cepheus.ask` et
  l'API de Cesia donnent les mêmes types et les mêmes valeurs dans le même ordre : un test compare les lignes de grandes
  réponses, avec des `Optional` nombreux et manquants, sur un seul domain et découpées sur quatre, avec les lignes
  d'avant.
- **Là où PostgreSQL gagne encore sur ces questions.** Sur un seul cœur, sans domain avec qui partager le travail : le
  check de `Less`, auquel PostgreSQL répond par un seul parcours séquentiel d'une table de deux colonnes avec un filtre,
  reste à PostgreSQL, 8,44 ms avec chaque valeur contre 6,69 par libpq (1,3 fois) et 5,07 ms pour les mots d'index
  contre 3,68 pour son moteur (1,4 fois) : le join de Cepheus parcourt les liens par valeur, un niveau par variable,
  environ 80 ns par lien (4,61 ms pour le join seul) contre 65 ns par ligne du parcours de PostgreSQL. L'intervalle de
  `Less` avec chaque valeur aussi, 33,9 ms contre 28,7 (1,2 fois ; son moteur seul pareil, 19,1 contre 19,4). `Optional`
  reste à Cepheus sur un seul cœur (10,4 ms contre 17,5, 6,26 contre 12,1). Les valeurs d'une ligne sont des blocs OCaml
  qu'une minor collection copie quand elle les trouve vivants (9 mots par ligne de deux colonnes) : une question de
  227 260 lignes (chaque facture et son statut) prend 62,7 ms avec chaque valeur contre 20,8 pour son join, 2,07
  millions de mots promus ; les lignes de PostgreSQL vont au socket en octets, jamais dans un tas que le GC parcourt. Et
  `Cepheus.ask` répond dans le programme qui demande, sans socket : un programme qui demande au serveur de Cepheus
  reçoit des mots d'index et paie ses propres valeurs.
- **Une cascade : les maps d'ints construites en une passe.** Sur un seul domain, la cascade de 10 000 lignes de main
  prenait 24 ms : la lecture des faits des lignes 1,6, `Store.set_sorted` 13 (2,2 millions de mots alloués, 0,6 million
  promus, 6 ms de collectes), le reste environ 10 (la liste des changements du groupe, les vérifications) ; les
  collectes faisaient la moitié du tout (3,3 millions de mots alloués, 1 million promus, 1,7 à 1,9 cycles majeurs par
  appel). Les maps d'ints du delta (par chose, les choses d'une valeur, les comptes d'une chose) étaient construites à
  partir de leurs liaisons triées par des unions de moitiés
  ([Blelloch 2016](references.md#les-structures-persistantes-et-les-forks) : chaque union en O(m log(n/m + 1)) pas, mais
  environ 65 mots par liaison en nœuds faits et jetés). Elles sont maintenant `Store.IM`, les arbres AVL (des arbres
  binaires équilibrés par la hauteur) du `Map` de la Stdlib
  ([Adelson-Velsky 1962](references.md#les-structures-persistantes-et-les-forks)) écrits en clair avec une fonction de
  plus, `of_sorted` : la liaison du milieu la racine des arbres des deux moitiés, en O(n), un nœud de 6 mots par
  liaison. Les changements d'un groupe et leurs mots vont dans deux tableaux qui grandissent, à partir de 4, là où deux
  listes étaient renversées à la fin. Une cascade de 10 000 lignes alloue 2,12 millions de mots là où elle en allouait
  3,27. Sur 21 tours alternés avec le build d'avant : une cascade de 10 000 lignes 0,83 (plus rapide dans 20 des 21
  tours, p < 0,0001), de 100 lignes 0,81, un `clear` de 100 notes 0,66 et de 10 000 0,68, un `Retract` des faits des
  10 000 lignes 0,92 ; un `Delete` refusé d'emblée, chronométré seul par `dbench` (une horloge de 1 µs, chaque appel
  après un print), de 6,0 à 6,9 µs dans les tours du tableau (plus lent dans 17 à 18 des 21) ; chronométré 20 000 fois
  de suite sur un seul cœur, le même travail : refusé sans ligne de 7,30 à 7,19 µs, avec 100 lignes de 7,88 à 7,96, une
  cascade et un clear de rien 0,99 et 1,00 fois ceux de main (8 tours). Un appel seul et à froid est plus lent d'environ
  0,5 µs ; sa cause n'a pas été trouvée.

  Rien ne change sur le disque : les octets du journal sont les mêmes, seule la construction des maps du delta en
  mémoire a changé. Chaque menace a un test : les maps contre le `Map` de la Stdlib (300 tours d'opérations au hasard,
  les arbres restés équilibrés) ; une cascade rejouée depuis ses changements comme un redémarrage, une réplique et un
  follower de Raft l'appliquent (`Resolve.replay`), avec les mêmes faits ; une coupure de courant à chaque appel disque
  du commit d'une cascade de 600 lignes, dans le journal et dans un run fusionné : la base s'ouvre comme avant ou comme
  après, rien entre les deux ; la cascade en course avec des écritures des mêmes choses dans un seul batch du writer,
  dans les 6 ordres : l'état des groupes l'un après l'autre, aucune ligne liée à une facture supprimée ; les watches
  qui voient des cascades dans la simulation live (les lignes de chaque watch contre la question répondue de nouveau).

  **Là où PostgreSQL gagne encore** : une cascade de 10 000 lignes, 3,4 fois plus rapide. Il marque la version de chaque
  ligne supprimée (`xmax`) et ne touche aucun index avant `VACUUM`, environ 0,5 µs par ligne ; Cepheus écrit chaque
  retrait dans les maps de son delta par chose et par valeur tout de suite, environ 0,8 µs par fait (2 faits par ligne),
  pour que la question suivante les lise sans vacuum et qu'aucun index ne garde une ligne morte : le compromis du
  design, gardé. Ce que PostgreSQL laisse pour plus tard, sur une copie neuve de son cluster (son cache froid, 5
  exécutions) : après le `DELETE` de la facture et de ses 10 000 lignes validé (26,6 ms là), le `VACUUM` de la table des
  lignes prend 30,2 ms et celui des factures 5,8 ; les retraits de Cepheus rejoignent ses runs au merge suivant, comme
  chaque écriture.

**Pas de ralentissement ailleurs** (les binaires de main et maintenant alternés à chaque tour sur les mêmes bases,
chaque process dans un scope de 3 Go ; la médiane des rapports des tours, maintenant sur main, et un sign test bilatéral
sur les tours). Sur 8 domains, 11 tours (une charge de 2,0 à 4,8) : la mémoire à son pic 1,01 et 1,02 fois celle de
main ; le démarrage 0,97 (plus rapide dans 11 des 11 tours) ; les pages de `kbench` 0,97 à 1,01 ; les rapports de
`rbench` 0,95 à 1,03, aucun plus lent dans plus de tours que le hasard n'en donne (p 0,23 ou plus) ; `bench.exe read`
0,92 à 1,01 ; une écriture de groupes simples 0,94 ; les fenêtres de `wbench` 0,98 à 1,05 (la dernière facture de chaque
client 1,05, plus lente dans 8 des 11 tours, p 0,23) et ses pages de 51 0,64 à 0,67 (plus rapides : leurs niveaux lisent
des slices comme les joins plus haut ; quel changement le donne n'a pas été mesuré seul) ; les autres questions
d'`abench`, dans les tours du tableau, 0,84 à 1,01 ; les petites questions de `mbench` 0,51 à 1,04 (`Optional` d'une
ville 0,51). Sur un seul domain épinglé à un cœur (`taskset -c 2`, `CEPHEUS_DOMAINS=1`), 11 tours (une charge de 1,2 à
4,5) : les rapports 0,95 à 1,04 (p 0,23 ou plus pour ceux au-dessus de 1), `bench.exe read` 0,95 à 1,00, `mbench` 0,46 à
1,04. Un cas a bougé dans le même sens dans les deux : le point fold de `mbench` (un fold qui lit un seul fait, le nom
d'un client, 1,9 µs), 1,04, plus lent dans 17 des 22 tours (p 0,017) : `Query.fold` faisait les tableaux des bornes de
`Less` pour chaque question, trois petits tableaux et leurs closures. Ils ne sont maintenant faits que pour une question
avec `Less`, la seule qui les lit : sur 21 tours de main, d'avant et de maintenant sur un seul cœur épinglé, sous une
charge de 1,4 à 6,1, les médianes du point fold étaient 1,96 µs, 2,03 et 1,97 ; maintenant sur avant 0,97 (plus rapide
dans 15 des 21 tours, p 0,041), maintenant sur main 1,00 (p 1,0).

## Les cas que PostgreSQL gagnait encore (2026-11-26), à 1 million de faits

**Méthode.** Les questions des sections plus bas où PostgreSQL 18.6 était plus rapide, sur leurs données : `Less` et
`Optional` sur celles de `bench.exe load` (11 363 clients, 227 260 factures, 56 797 liens de suivi ; `bench.exe pages`
à côté de `pg.sh ops`), les fenêtres et `Each` sur celles de rbench (245 000 factures ; `wbench.exe run` à côté de
`pg.sh windows run`, avec les index de [la section des fenêtres](#les-fenêtres-et-each-2026-11-26-à-1-million-de-faits)),
les cascades sur celles de dbench (`dbench.exe delete` à côté de `pg.sh fk run`, `ON DELETE CASCADE`). Trois côtés à
chacun des 5 tours, leur ordre tourné à chaque tour : les binaires de main (af9fb51), ceux du changement (d96aa73),
PostgreSQL ; chacun une médiane de 5 exécutions (`Less`, `Optional`), 11 (fenêtres) ou 21 (suppressions). Donnés : la
médiane des 5 tours, entre crochets leur plus petit et leur plus grand ; le changement sur main, la médiane des
rapports des tours [plus petit, plus grand]. Une charge moyenne de 2,5 à 5,9 sur les 8 threads (les builds et les tests
d'autres jobs). Où le temps passait a été mesuré d'abord, phase par phase (un programme de travail qui chronomètre
chaque étape et compte les mots qu'elle alloue) et par 200 échantillons de la pile d'un process sous gdb, toutes les
0,1 s.

| question | main | maintenant | maintenant / main | PostgreSQL 18.6 | maintenant |
|---|---:|---:|---:|---:|---|
| les liens de suivi vers un client plus récent (`Less(a, b)`), 28 250 lignes, chaque valeur faite | 10,8 ms [7,74, 18,5] | 8,50 ms [6,19, 9,37] | 0,78 [0,51, 1,10] | **3,64 ms** [3,55, 4,02] | PostgreSQL, 2,3 fois (3,0 avant) |
| la même, comme le serveur y répond (des mots de l'index, aucune valeur faite) | 3,96 ms [3,55, 5,04] | 3,70 ms [3,40, 4,28] | 0,93 | 3,64 ms | à peu près pareil |
| les factures sous le total d'une facture (`Less`), 122 962 lignes, chaque valeur faite | 31,4 ms [26,1, 36,1] | 21,9 ms [20,1, 26,4] | 0,82 [0,62, 0,82] | **20,0 ms** [18,9, 22,4] | à peu près pareil (PostgreSQL 1,1 fois ; 1,6 avant) |
| la même, comme le serveur y répond | 11,8 ms [10,8, 13,9] | **10,5 ms** [10,0, 11,2] | 0,93 | 20,0 ms | Cepheus, 1,9 fois |
| chaque client avec les clients qu'il suit (`Optional`), 56 797 lignes, chaque valeur faite | 16,8 ms [15,8, 17,4] | 15,1 ms [13,9, 17,2] | 0,93 [0,83, 1,00] | **12,1 ms** [11,8, 13,4] | PostgreSQL, 1,2 fois (1,4 avant) |
| la même, comme le serveur y répond | 9,59 ms [9,12, 11,8] | **10,0 ms** [9,41, 13,9] | 1,04 | 12,1 ms | Cepheus, 1,2 fois |
| un rang par total, `Rank()`, 1 groupe de 245 000 lignes | 213 ms [203, 249] | **96,1 ms** [95,7, 106] | 0,45 [0,38, 0,51] | 181 ms [174, 183] | Cepheus, 1,9 fois (PostgreSQL 1,2 avant) |
| le même, 100 groupes | 236 ms [229, 271] | **115 ms** [111, 119] | 0,48 [0,42, 0,52] | 361 ms [349, 430] | Cepheus, 3,1 fois (1,5 avant) |
| le même, 10 000 groupes | 261 ms [254, 312] | **134 ms** [129, 151] | 0,50 [0,42, 0,59] | 244 ms [240, 307] | Cepheus, 1,8 fois (à peu près pareil avant) |
| les 3 dernières factures de chaque client, `Each`, `Limit: 3`, 30 000 lignes | 137 ms [131, 157] | 106 ms [103, 139] | 0,81 [0,67, 0,98] | `LATERAL` : **53,8 ms** [52,0, 57,0] | PostgreSQL, 2,0 fois (2,5 avant) |
| la dernière facture de chaque client, `Limit: 1`, 10 000 lignes | 102 ms [101, 125] | **88,8 ms** [74,8, 97,0] | 0,83 [0,62, 0,96] | `DISTINCT ON` : 113 ms [110, 135] | Cepheus, 1,3 fois (1,1 avant) |
| une facture et ses 10 000 lignes, `cascade` | 30,0 ms [24,8, 32,3] | 21,8 ms [19,8, 24,0] | 0,74 [0,66, 0,89] | **5,18 ms** [5,00, 5,73] | PostgreSQL, 4,2 fois (5,8 avant) |
| une facture et ses 100 lignes | 215 µs [171, 321] | **148 µs** [128, 250] | 0,75 [0,40, 1,46] | 201 µs [177, 237] | Cepheus, 1,4 fois (à peu près pareil avant) |

Les lignes « comme le serveur y répond » sont `abench.exe DIR PAGES` dans les mêmes tours (`Answer.answer` : les mots
d'index de chaque ligne faits, pas ses valeurs, comme `EXPLAIN (ANALYZE, TIMING OFF)` de PostgreSQL fait ses lignes et
n'en envoie aucune).

![Une ligne par question, sur une échelle logarithmique de combien de fois un côté est plus rapide, un point gris pour les binaires de main et un point en couleur pour maintenant, une flèche du premier au second. Les flèches vont à droite, vers Cepheus, sauf une qui bouge dans le bruit (Optional comme le serveur y répond, de 9,59 à 10,0 ms). Un rang d'un seul groupe passe de PostgreSQL 1,2 fois plus rapide à Cepheus 1,9 fois, de 100 et 10 000 groupes à Cepheus 3,1 et 1,8 fois, la dernière facture de chaque client à Cepheus 1,3 fois, une cascade de 100 lignes à Cepheus 1,4 fois, l'intervalle de Less avec chaque valeur à moins de 10 % ; PostgreSQL reste plus rapide sur le check de Less avec chaque valeur (2,3 fois, contre 3,0), Optional avec chaque valeur (1,2, contre 1,4), les 3 dernières de chaque client par LATERAL (2,0, contre 2,5) et une cascade de 10 000 lignes (4,2, contre 5,8).](images/bench-pg-won.svg)

- **Un rang, et chaque tri entier : par les bits des clés.** Un rang d'un seul groupe passait 144 de ses 227 ms dans le
  tri par total, et les échantillons mettaient environ 60 % du tout dans les comparaisons de lignes du merge sort (le
  tri par fusion, `Array.stable_sort` : un appel du comparateur pour chacun des n log2 n pas, chaque déplacement une
  write barrier, la vérification que le GC fait à chaque écriture d'un pointeur). Un tri entier de 4 096 lignes ou plus
  dont les premières clés sont des mots inline (ints, dates, money, liens, booléens : des mots qui gardent l'ordre de
  leurs valeurs) fait maintenant un int d'au plus 62 bits par ligne, ces mots l'un après l'autre, chacun à partir du
  plus petit de sa colonne, et trie les lignes par lui avec un radix sort (un tri par les chiffres de la clé, sans
  comparaison) LSD, du chiffre le moins significatif d'abord, de 11 bits par passe ([Knuth 1998](references.md#les-index-et-la-compression),
  section 5.2.5 : n déplacements par passe et aucune comparaison ; [Herf 2001](references.md#les-index-et-la-compression) :
  les comptes de chaque passe en une seule lecture, une passe sautée quand chaque clé y a le même chiffre), stable ;
  les lignes d'une suite de clés égales sont triées de nouveau par les comparaisons quand la clé ne tenait pas tout
  l'ordre. Les places du rang et un compte cumulé sont maintenant un int par ligne, pas une valeur que le GC déplace.
  Le rang 2,2 fois plus rapide ; le tri par date de chaque fenêtre y gagne aussi (un total cumulé d'un seul groupe
  de 119 à 92,9 ms, par ville de 229 à 150).

  ![En haut, la clé d'une ligne : 1 100 moins son total en 17 bits, puis sa date depuis le 5 janvier en millisecondes en 34 bits, 51 bits dans un int, coupés en 5 chiffres de 11 bits, le chiffre 0 à droite trié d'abord. À gauche, les 11 factures de 2028 dans l'ordre lu, chacune avec ses 5 chiffres ; à droite, les mêmes factures triées, 1 100 d'abord, puis 1 000, 900, 700, 600, les quatre de 500 dans l'ordre de leurs dates, puis 400 et 300.](images/sort-radix.svg)

- **`Each` avec `Limit` : un binding comparé avant d'être une ligne.** Les 3 dernières de chaque client passaient
  environ 115 de leurs 153 ms dans les buffers des groupes : chaque facture faite ligne, comparée à la k-ième de son
  groupe, et chaque buffer trié et coupé chaque fois qu'il atteignait 2 k lignes. Maintenant un binding est comparé à la
  k-ième ligne de son groupe, lue dans les mots du binding, avant d'être fait ligne : au-delà, aucune allocation ;
  pour un `Limit` jusqu'à 32, le buffer de chaque groupe est gardé dans l'ordre, une ligne mise à sa place (k
  comparaisons au plus) et les lignes au-delà de la k-ième lâchées aussitôt, si bien qu'aucun groupe n'est trié à la
  fin. **Là où PostgreSQL gagne encore** : son `LATERAL` lit 3 lignes par client dans son B-tree sur
  `(client, date DESC, id)`, 30 000 lignes, là où Cepheus lit les 245 000 factures une fois (les échantillons : un
  quart du temps à lire la date de chaque facture, `Store.value1`). Seul un index de deux propriétés lirait aussi peu
  de lignes ; il est conçu, pas construit (il demande un nouveau format de run et une déclaration, des choix du
  propriétaire).
- **`Less` et `Optional` : des lignes faites depuis un seul buffer.** Un check de `Less` passait 58 % de son temps à
  faire les valeurs de ses lignes, la jointure 42 % ; les échantillons d'`Optional` sur chaque client, 44 % dans les
  minor collections (les collections du petit heap des valeurs jeunes), dont chacune arrête chaque domain du process.
  Les bindings d'`Ask` sont maintenant écrits dans un seul buffer par domain, là où chaque binding était un nouveau
  tableau, et `Cepheus.ask` fait les valeurs de chaque ligne depuis le binding, sans ligne de mots entre les deux, la
  valeur d'une colonne partagée avec la ligne d'avant tant que son mot se répète (les variables extérieures d'une
  jointure se répètent sur les intérieures). Comme le serveur y répond (des mots, aucune valeur), Cepheus est aussi
  rapide que PostgreSQL sur le check, et plus rapide sur l'intervalle et `Optional`. **Là où PostgreSQL gagne
  encore** : quand un programme demande chaque valeur, Cepheus fait 28 250 ou 56 797 lignes de valeurs OCaml, chacune
  une allocation que le GC parcourt ensuite ; l'executor de PostgreSQL passe des tuples qui pointent dans ses buffers,
  et son temps laisse de côté ce que son client paie pour les recevoir. Mesuré depuis dans le même périmètre des deux
  côtés, et rendu moins coûteux : [les lignes avec chaque valeur
  faite](#les-lignes-avec-chaque-valeur-faite-et-les-cascades-2026-11-26-à-1-million-de-faits).
- **Les retraits d'une cascade ensemble.** Les faits des 10 000 lignes étaient retirés un fait après l'autre, chacun un
  parcours des maps persistantes du writer par chose et par valeur. Ils sont maintenant rassemblés, lus dans la vue
  d'avant qu'aucun ne parte, et retirés ensemble par un seul `Store.set_sorted`, comme un groupe de `Retract` l'est
  (les liens d'un `clear` aussi : de 11,0 à 9,75 ms à 10 000 notes) : ordonnés par (propriété, valeur, chose) par des
  radix sorts stables de 11 bits quand ils sont 256 ou plus, et une propriété dont le delta ne tient aucune valeur
  reçoit son arbre de valeurs construit d'un coup à partir d'eux dans l'ordre, en O(n), là où une addition après
  l'autre copiait un chemin chacune. La cascade de 10 000 lignes coûte maintenant ce que coûte le retrait de ses
  20 000 faits (21,8 contre 20,4 ms). **Là où PostgreSQL gagne encore** : il supprime une ligne en marquant sa version
  (`xmax`), sans toucher aucun index avant `VACUUM`, 0,5 µs par ligne ; Cepheus écrit chaque retrait dans les maps de
  son delta par chose et par valeur à la fois, environ 1 µs par fait, si bien que la question suivante les lit sans
  vacuum. Ses maps construites depuis en une passe : [les
  cascades](#les-lignes-avec-chaque-valeur-faite-et-les-cascades-2026-11-26-à-1-million-de-faits).

**Pas de ralentissement ailleurs** (`abench`, `kbench`, `mbench`, `rbench`, `bench.exe read`, les écritures, la
mémoire, le démarrage ; les binaires de main et ceux du changement alternés à chaque tour sur les mêmes bases) : en 5
tours après la fusion de main (une charge de 3,0 à 11,7), la mémoire au plus haut 0,94 et 1,00 fois celle de main, le
démarrage 0,99, les pages de `kbench` 0,93 à 0,98, les petites questions de `mbench` 0,91 à 1,05 et celles d'`abench`
0,89 à 1,05 (la médiane des rapports des tours). Les rapports de `rbench`, `bench.exe read` et une écriture de groupes
simples sont sortis à 1,02 à 1,46 dans ces tours, dont deux pendant que des programmes se compilaient sur la machine :
en 11 tours de plus, l'ancien et le nouveau alternés (une charge de 4,3 à 9,2), ils ont donné 0,97 à 1,24, 0,98 à 1,17
et 0,98, aucun cas plus lent dans plus de tours que le hasard n'en donne (un sign test bilatéral, le test des signes :
p de 0,065 ou plus), et les questions soupçonnées d'abord (le rapport mensuel, la page après la 200 000e, la `Sum` par
ville, posées dans un autre programme) ont alloué les mêmes mots des deux côtés. En 11 derniers tours sur un seul
domain épinglé à un seul cœur (`taskset -c 2`, `CEPHEUS_DOMAINS=1`, une charge de 1,6 à 4,1), où les autres jobs et
les barrières des domains bougent le moins les temps, les rapports ont donné 0,94 à 1,03 (les trois cas les plus près
d'un signe, p 0,065, plus rapides avec le changement), `bench.exe read` 0,99 à 1,03, et les questions soupçonnées
d'abord 1,00 à 1,05 (p de 0,23 ou plus) : aucun ralentissement au-delà du bruit d'une machine partagée.

## Les sommes vérifiées au-delà de 63 bits (2026-11-26), à 1 million de faits

**Méthode.** La `Sum` d'un rapport teste maintenant les signes de chaque addition et garde une retenue (un « carry »)
quand elle « wrappe », c'est-à-dire repasse de l'autre côté des entiers ([une somme est exacte, ou
refusée](cesia.md#find--les-questions)) : environ 7 instructions de plus par ligne, l'appel du carry hors de la
boucle. Mesuré par `rbench.exe run` sur les données de [la section des
rapports](#les-rapports--avg-countx-values-quantile-stddev-trunc-2026-11-26-à-1-million-de-faits) (245 000 factures,
chacune une ligne de la somme), le même fichier compilé sur main (d19ff13) et sur le changement, alternés à chaque
tour (main d'abord aux tours impairs), chaque processus dans un scope de 3 Go, sur 1 domain (`CEPHEUS_DOMAINS=1`) :
(a) 21 tours de 11 exécutions, une charge moyenne de 6,6 au premier, 1,4 au dernier ; (b) fixé sur un cœur
(`taskset -c 2`), 15 tours de 21 exécutions, une charge de 6,0 à 1,4 ; (c) la vérification seule : le changement
contre lui-même avec ses deux boucles de `Sum` remises comme avant (le même code ailleurs, donc la même disposition du
reste), fixé sur un cœur, 15 tours de 21 exécutions, sous des charges d'autres jobs de 3,1 à 16. Donnés : la médiane
des médianes des tours, entre crochets la plus petite et la plus grande, et la médiane des rapports des tours (après
sur avant) avec le plus petit et le plus grand.

| question | avant (main) | avec la vérification | après/avant (a), 1 domain | (b), un cœur | (c), la vérification seule |
|---|---:|---:|---:|---:|---:|
| `Sum` de chaque facture, 1 groupe | 25,2 ms [24,6, 76,0] | 26,6 ms [25,7, 29,3] | 1,036 [0,17, 1,50] | 1,051 [0,36, 1,17] | 1,016 [0,41, 2,86] |
| par ville, 100 groupes | 33,5 ms [32,4, 111] | 34,4 ms [33,3, 49,9] | 0,986 [0,49, 3,01] | 1,030 [0,31, 1,50] | 0,948 [0,40, 2,20] |
| par client, 10 000 groupes | 56,2 ms [52,7, 138] | 58,2 ms [56,4, 65,6] | 0,993 [0,83, 1,98] | 1,013 [0,41, 1,12] | 0,889 [0,55, 1,34] |
| par mois à Paris (`Trunc`, un rapport) | 75,6 ms [70,6, 159] | 78,4 ms [75,2, 84,4] | 1,028 [0,89, 1,40] | 1,022 [0,49, 1,16] | 1,005 [0,33, 3,32] |
| par mois en UTC | 66,1 ms [59,6, 100] | 66,0 ms [62,6, 81,1] | 0,973 [0,68, 1,35] | 1,017 [0,68, 1,24] | 1,062 [0,35, 3,05] |
| (inchangé) `Avg`, 1 groupe | 27,6 ms [27,0, 40,2] | 28,2 ms [27,1, 29,3] | 1,013 [0,27, 1,65] | 1,020 [0,71, 1,06] | 1,182 [0,38, 4,06] |
| (inchangé) `Stddev`, 10 000 groupes | 69,4 ms [66,5, 140] | 70,5 ms [68,3, 129] | 1,064 [0,92, 1,76] | 1,029 [0,51, 1,85] | 1,000 [0,42, 3,02] |

Les temps sont ceux de (b). Aucun coût ne se voit au-delà du bruit : les sommes ont bougé des mêmes 1 à 5 % que les
agrégats que le changement ne touche pas, et la vérification seule, la seule différence entre ses deux côtés, a fait
bouger les sommes dans les deux sens (0,89 à 1,06). Une ligne de ces sommes coûte environ 100 ns (le candidat de la
jointure, le hash de son groupe) ; la vérification ajoute deux cycles machine environ, moins de 1 %, que ces tours ne
peuvent pas distinguer. La `Sum` d'un watch (Live) a le même test, à chaque binding qu'un frame ajoute ou retire.

## Les fenêtres et Each (2026-11-26), à 1 million de faits

**Méthode.** Les données de la section des rapports plus bas (`rbench.exe load` : 10 000 clients de 100 villes,
245 000 factures, 990 000 faits dans un seul run, sur le SSD SATA), et les mêmes lignes dans PostgreSQL 18.6 (`pg.sh
reports load`), avec les deux index qu'un utilisateur de PostgreSQL fait pour ces questions (`pg.sh windows index` :
`rinvoice (client, date DESC, id)` pour `LATERAL`, `rinvoice (date, id)` pour les pages). Chaque fenêtre sur les
245 000 factures avec leur date et leur total, en un seul groupe, celui de chaque ville (100 groupes : une jointure
avec les clients) et de chaque client (10 000), comme le serveur y répond (`wbench.exe run` : `Answer.answer`, sans
socket ; chaque ligne faite, comme un programme la demande) à côté du temps d'exécution de PostgreSQL
(`EXPLAIN (ANALYZE, TIMING OFF)`, `pg.sh windows run` : chaque ligne faite, aucune envoyée). 5 tours alternés, chaque
côté une médiane de 11 exécutions ; donnés : la médiane des 5 tours, et entre crochets leur plus petit et leur plus
grand. Le tableau est la mesure faite après [les cas que PostgreSQL gagnait encore](#les-cas-que-postgresql-gagnait-encore-2026-11-26-à-1-million-de-faits),
sur les mêmes données et le même PostgreSQL (une charge moyenne de 2,5 à 5,9 sur les 8 threads, les builds et les
tests d'autres jobs) ; la première mesure de ces questions, sous une charge de 21,9 à 4,2, donnait un rang d'un seul
groupe en 252 ms contre 216 pour PostgreSQL, les 3 dernières de chaque client en 131 ms contre 55,9 pour `LATERAL` et
la dernière en 151 ms contre 127 pour `DISTINCT ON`.

| question | Cepheus | PostgreSQL 18.6 | |
|---|---:|---:|---|
| un total cumulé, `Running(Sum(t))` (`sum(total) OVER (ORDER BY date, id ROWS UNBOUNDED PRECEDING)`), 1 groupe | **92,9 ms** [90,0, 121] | 228 ms [215, 256] | Cepheus, 2,5 fois |
| le même, 100 groupes (`PARTITION BY city`) | **150 ms** [142, 163] | 379 ms [361, 413] | Cepheus, 2,5 fois |
| le même, 10 000 groupes (`PARTITION BY client`) | **136 ms** [134, 147] | 261 ms [251, 307] | Cepheus, 1,9 fois |
| une moyenne mobile de 3, `Running(Avg(t), last = 3)` (`avg(total) OVER (... ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)`), 1 groupe | **103 ms** [98,2, 108] | 298 ms [288, 323] | Cepheus, 2,9 fois |
| la même, 100 groupes | **168 ms** [165, 181] | 444 ms [420, 560] | Cepheus, 2,6 fois |
| la même, 10 000 groupes | **157 ms** [152, 198] | 328 ms [315, 377] | Cepheus, 2,1 fois |
| un rang par total, `Rank()` (`rank() OVER (ORDER BY total DESC)`), 1 groupe | **96,1 ms** [95,7, 106] | 181 ms [174, 183] | Cepheus, 1,9 fois |
| le même, 100 groupes | **115 ms** [111, 119] | 361 ms [349, 430] | Cepheus, 3,1 fois |
| le même, 10 000 groupes | **134 ms** [129, 151] | 244 ms [240, 307] | Cepheus, 1,8 fois |
| la date d'avant, `Prev(d)` (`lag(date) OVER (ORDER BY date, id)`), 1 groupe | **84,5 ms** [82,5, 141] | 201 ms [193, 207] | Cepheus, 2,4 fois |
| la même, 100 groupes | **134 ms** [123, 154] | 369 ms [353, 432] | Cepheus, 2,8 fois |
| la même, 10 000 groupes | **111 ms** [108, 125] | 250 ms [241, 290] | Cepheus, 2,3 fois |
| les 3 dernières factures de chaque client, `Each` et `Limit: 3`, 30 000 lignes | 106 ms [103, 139] | `row_number() ... <= 3` : 125 ms [122, 147] ; `LATERAL (... LIMIT 3)` : **53,8 ms** [52,0, 57,0] | le `LATERAL` de PostgreSQL avec son index, 2,0 fois ; Cepheus, 1,2 fois sur `row_number()` |
| la dernière facture de chaque client, `Limit: 1`, 10 000 lignes | **88,8 ms** [74,8, 97,0] | `DISTINCT ON` : 113 ms [110, 135] | Cepheus, 1,3 fois |
| les totaux mensuels à Paris avec leur total cumulé, le mois d'avant et la moyenne sur 3 mois (un rapport de 121 lignes) | **24,0 ms** [23,7, 28,3] | 196 ms [182, 239] | Cepheus, 8,2 fois |
| une page de 51 après la 200 000e facture avec son total cumulé (`After` ; une sous-requête et une condition de keyset hors d'elle) | **79,6 ms** [63,5, 103] | 195 ms [180, 225] | Cepheus, 2,5 fois |
| la première page de 51 avec son total cumulé | **95,1 µs** [79,2, 160] | 201 µs [191, 291] | Cepheus, 2,1 fois |

![Une barre par question, sur une échelle logarithmique de combien de fois un côté est plus rapide : des barres bleues à droite où Cepheus est plus rapide, orange à gauche où c'est PostgreSQL. Cepheus est 1,8 à 3,1 fois plus rapide sur les totaux cumulés, les moyennes mobiles, les rangs, la ligne d'avant et les pages, 1,3 fois sur la dernière facture de chaque client contre DISTINCT ON, et 8,2 fois sur le rapport mensuel ; PostgreSQL est plus rapide sur les 3 dernières de chaque client par LATERAL avec son index (2,0 fois).](images/bench-windows.svg)

- **Une fenêtre est un seul passage.** Cepheus lit la question sur ses 8 domains, trie ses 245 000 lignes une fois
  (par un radix sort des mots de leurs clés, [plus bas](#les-cas-que-postgresql-gagnait-encore-2026-11-26-à-1-million-de-faits)), et
  chaque fenêtre est alors un passage sur chaque groupe (une somme cumulée, une moyenne mobile à partir de sommes
  exactes avec la ligne qui part retirée, la ligne d'avant). PostgreSQL lit les lignes par date dans son index sur
  `(date, id)`, sans tri, et les trie pour les autres ordres (par total, par ville ou client d'abord), dans un seul
  process, son `WindowAgg` au-dessus ; son `avg` mobile d'un `numeric` lui coûte plus qu'une somme.
- **Là où PostgreSQL gagne.** Les 3 dernières factures de chaque client : avec un index sur `(client, date)`, le
  `LATERAL` de PostgreSQL y lit 3 lignes par client, 30 000 lignes ; Cepheus n'a pas d'index de deux propriétés et lit
  les 245 000 factures une seule fois, chaque groupe gardant ses 3 plus récentes dans l'ordre, un binding au-delà mis de
  côté après une seule comparaison, avant d'en faire une ligne : 1,2 fois plus rapide que le `row_number()` de
  PostgreSQL sur les mêmes lignes, 2,0 fois le temps de `LATERAL`. La dernière facture de chaque client, contre
  `DISTINCT ON` (un tri par client), revient maintenant à Cepheus ; un rang d'un seul groupe aussi, un tri par total des
  deux côtés, depuis que le tri de Cepheus lit les bits des mots des totaux au lieu de comparer des lignes.
- **Les pages.** Une page avec son total cumulé après la 200 000e ligne : Cepheus lit la page dans l'index des dates
  comme une page sans fenêtres (0,26 ms ici) et les lignes avant le curseur en un seul passage, aucune triée, pour leur
  somme ; PostgreSQL calcule la fenêtre sur chaque ligne de sa sous-requête, puis garde la page. La première page lit
  51 lignes des deux côtés : la fenêtre de Cepheus ajoute 7 µs aux 88 µs de la page.
- **Pas de ralentissement des questions d'avant.** `abench.exe` (un Give d'une jointure, `Sum` et `Count` par ville,
  `Min` et `Max` par client, un groupe trié, une page, `Not`, un intervalle, `Optional`) et `kbench.exe run` (des pages
  de 51 sur 1 000 000 de choses par id, celles d'un tenant, croissantes et décroissantes), les mêmes fichiers construits
  sur main (9cb2274) et sur b3, alternés à chaque tour sur les mêmes bases : nouveau/ancien 0,37 à 1,00 (la médiane des
  rapports des tours ; leurs plus petit et plus grand 0,18 et 4,96, le bruit d'une machine chargée sur des questions de
  moins d'une milliseconde) ; une page de 51 par id en 24 à 41 µs (les 25 µs du seek gardés).

## Les pages d'un kind par les ids de ses choses (2026-11-26), de 10 000 à 1 000 000 de choses

**Ce qui était lent.** L'admin de Centauri liste un kind page par page : `Find` de `[[t, Kind.Field, v]]`,
`Give: {Id: t}`, `Sort: [t]`, `Limit: 51` (la page et le curseur de la suivante), `After` la dernière ligne. Sur un
kind de 100 005 clients, une page prenait 35 à 46 ms, et toutes ses pages environ 2 minutes. Le chemin de l'index
lisait les valeurs d'une propriété dans leur ordre : la première clé devait être la valeur d'un pattern. Une chose est
la chose de ses patterns, donc le heap répondait : chaque binding du kind, deux candidats par chose, chacun comparé au
curseur : tout le kind à chaque page, quelle que soit sa profondeur. `Above` sur une chose était refusé par le package
Cesia, et dans le moteur un range sur une variable de chose était une vérification de chaque chose de sa propriété.

**Ce qui a changé.** Un tri dont la première clé est la chose d'un pattern lit des fenêtres des choses suivantes qui
tiennent la propriété du pattern (qui tiennent sa valeur, quand c'est une constante : les choses d'un tenant), à partir
du curseur, dans l'ordre de leurs ids : la colonne d'une propriété dans chaque run garde ses choses dans cet ordre
derrière une rank table (un mot pour 32 choses, qui dit lesquelles tiennent la propriété), les choses d'une valeur sont
ses lignes par valeur, dans l'ordre des choses (une recherche binaire trouve le curseur), et celles du delta sont lues
par chose ou par valeur, fusionnées ; la première fenêtre tient k choses, k + 1 après un curseur
([pages](cesia.md#sort-limit-et-after--des-pages)). Un range sur une variable de chose lit ses choses à partir de la
première du range, et le planner les y compte à partir des rank tables et des offsets ; `Above`, `Below` et `Between`
prennent l'id d'une chose.

**Méthode.** `kbench.exe load` (un kind de N items : un nom, un lien vers l'un de 10 tenants, un int ; un seul run,
fusionné), les mêmes lignes dans PostgreSQL 18.6 (`pg.sh keyset` : une table des items, `id` sa clé primaire, un index
sur `(tenant, id)`, les ids que Cepheus a donnés), sur le SSD SATA. Une page de 51, par id croissant et décroissant, la
première et celle après l'item du milieu ; puis les choses du tenant 3 (un item sur 10) de même. Les binaires de main
(12a5a24, *ancien*) à côté de ceux de cette version (*nouveau*), alternés à chaque tour : 5 tours, chaque côté une médiane de
11 exécutions ; donnés : la médiane des 5 tours et entre crochets leur plus petit et leur plus grand ; *nouveau/ancien* : la
médiane des rapports des tours. Cepheus : `ask` dans le processus, les lignes faites en valeurs, sur 8 domains au plus ;
PostgreSQL : le temps de son moteur (`EXPLAIN (ANALYZE, TIMING OFF)`). Puis les mêmes pages sur un fork de 100 000
items rempli en mémoire (`kbench.exe fork` : chaque fait dans son delta, comme la base en mémoire d'un programme), et
les pages d'admin de Centauri dans un navigateur (`bench.mjs shell` de l'admin de Centauri, son application de
factures en mémoire avec 100 005 clients : le navigateur de données sur le kind `client` rempli par All, chaque page de
50 demandée à son tour). La machine était partagée : une charge moyenne (1 minute) de 4,6 à 13 sur ses 8 threads.

**Des pages de 51**, un seul run (*PostgreSQL / nouveau* : la médiane de PostgreSQL sur celle de Cepheus) :

| choses | page | ancien | nouveau | nouveau/ancien | PostgreSQL 18.6 | PostgreSQL / nouveau |
|---|---|---:|---:|---:|---:|---:|
| 10 000 | par id, la première page | 2,63 ms [2,60 ms, 2,67 ms] | **23,6 µs [23,3 µs, 23,8 µs]** | 0,0089 | 44,0 µs [40,0 µs, 52,0 µs] | 1,89 |
| 10 000 | par id, après celui du milieu | 2,10 ms [2,08 ms, 2,54 ms] | **24,1 µs [23,8 µs, 24,8 µs]** | 0,0114 | 52,0 µs [49,0 µs, 54,0 µs] | 2,14 |
| 10 000 | par id décroissant, la première page | 2,80 ms [2,74 ms, 3,38 ms] | **23,8 µs [23,4 µs, 24,4 µs]** | 0,0085 | 41,0 µs [41,0 µs, 45,0 µs] | 1,75 |
| 10 000 | par id décroissant, après celui du milieu | 2,16 ms [2,14 ms, 2,65 ms] | **24,7 µs [24,3 µs, 25,3 µs]** | 0,0115 | 54,0 µs [51,0 µs, 57,0 µs] | 2,18 |
| 10 000 | celles du tenant 3 par id, la première page | 206 µs [200 µs, 263 µs] | **24,8 µs [24,6 µs, 25,1 µs]** | 0,1190 | 53,0 µs [50,0 µs, 56,0 µs] | 2,11 |
| 10 000 | celles du tenant 3 par id, après celle du milieu | 155 µs [149 µs, 205 µs] | **28,5 µs [28,1 µs, 28,8 µs]** | 0,1812 | 54,0 µs [53,0 µs, 59,0 µs] | 1,89 |
| 10 000 | celles du tenant 3 par id décroissant, la première page | 218 µs [213 µs, 270 µs] | **24,4 µs [23,8 µs, 24,6 µs]** | 0,1127 | 50,0 µs [46,0 µs, 53,0 µs] | 2,10 |
| 10 000 | celles du tenant 3 par id décroissant, après celle du milieu | 161 µs [155 µs, 202 µs] | **30,3 µs [29,6 µs, 34,8 µs]** | 0,1892 | 53,0 µs [50,0 µs, 59,0 µs] | 1,75 |
| 100 000 | par id, la première page | 10,4 ms [10,2 ms, 11,3 ms] | **24,8 µs [24,5 µs, 26,1 µs]** | 0,0024 | 43,0 µs [42,0 µs, 72,0 µs] | 1,76 |
| 100 000 | par id, après celui du milieu | 8,49 ms [8,36 ms, 9,34 ms] | **25,7 µs [25,4 µs, 26,2 µs]** | 0,0031 | 51,0 µs [49,0 µs, 58,0 µs] | 1,97 |
| 100 000 | par id décroissant, la première page | 11,0 ms [10,9 ms, 14,1 ms] | **25,4 µs [25,1 µs, 25,8 µs]** | 0,0023 | 36,0 µs [35,0 µs, 45,0 µs] | 1,43 |
| 100 000 | par id décroissant, après celui du milieu | 8,85 ms [8,70 ms, 11,1 ms] | **26,8 µs [26,4 µs, 27,3 µs]** | 0,0030 | 53,0 µs [51,0 µs, 58,0 µs] | 1,99 |
| 100 000 | celles du tenant 3 par id, la première page | 2,05 ms [2,02 ms, 2,56 ms] | **28,5 µs [28,2 µs, 28,6 µs]** | 0,0139 | 62,0 µs [59,0 µs, 64,0 µs] | 2,17 |
| 100 000 | celles du tenant 3 par id, après celle du milieu | 1,52 ms [1,49 ms, 1,89 ms] | **32,9 µs [32,6 µs, 33,0 µs]** | 0,0214 | 64,0 µs [63,0 µs, 65,0 µs] | 1,96 |
| 100 000 | celles du tenant 3 par id décroissant, la première page | 2,17 ms [2,13 ms, 2,72 ms] | **24,9 µs [24,3 µs, 24,9 µs]** | 0,0113 | 52,0 µs [51,0 µs, 55,0 µs] | 2,14 |
| 100 000 | celles du tenant 3 par id décroissant, après celle du milieu | 1,59 ms [1,55 ms, 2,04 ms] | **33,6 µs [33,0 µs, 33,8 µs]** | 0,0210 | 63,0 µs [61,0 µs, 67,0 µs] | 1,88 |
| 1 000 000 | par id, la première page | 93,2 ms [90,8 ms, 111 ms] | **24,7 µs [24,5 µs, 46,4 µs]** | 0,0003 | 42,0 µs [41,0 µs, 46,0 µs] | 1,67 |
| 1 000 000 | par id, après celui du milieu | 81,4 ms [77,3 ms, 104 ms] | **25,2 µs [24,9 µs, 29,2 µs]** | 0,0003 | 60,0 µs [58,0 µs, 64,0 µs] | 2,36 |
| 1 000 000 | par id décroissant, la première page | 99,2 ms [96,1 ms, 117 ms] | **24,6 µs [24,0 µs, 25,1 µs]** | 0,0003 | 41,0 µs [40,0 µs, 44,0 µs] | 1,70 |
| 1 000 000 | par id décroissant, après celui du milieu | 82,4 ms [80,7 ms, 98,2 ms] | **25,3 µs [24,9 µs, 27,3 µs]** | 0,0003 | 62,0 µs [60,0 µs, 70,0 µs] | 2,45 |
| 1 000 000 | celles du tenant 3 par id, la première page | 9,51 ms [8,54 ms, 10,9 ms] | **29,1 µs [28,7 µs, 29,9 µs]** | 0,0031 | 57,0 µs [57,0 µs, 59,0 µs] | 1,96 |
| 1 000 000 | celles du tenant 3 par id, après celle du milieu | 7,10 ms [6,66 ms, 7,66 ms] | **32,0 µs [31,6 µs, 32,2 µs]** | 0,0044 | 60,0 µs [58,0 µs, 64,0 µs] | 1,90 |
| 1 000 000 | celles du tenant 3 par id décroissant, la première page | 9,96 ms [9,35 ms, 11,7 ms] | **24,4 µs [24,1 µs, 24,6 µs]** | 0,0025 | 56,0 µs [55,0 µs, 61,0 µs] | 2,32 |
| 1 000 000 | celles du tenant 3 par id décroissant, après celle du milieu | 7,23 ms [7,02 ms, 8,42 ms] | **34,0 µs [33,8 µs, 34,5 µs]** | 0,0048 | 66,0 µs [63,0 µs, 69,0 µs] | 1,92 |

![Un graphique log-log du temps d'une page de 51 par id, après le milieu du kind, à 10 000, 100 000 et 1 000 000 de choses. Le tas d'avant, en gris pointillé, croît de 2,10 ms à 81,4 ms ; PostgreSQL, en orange, reste entre 51 et 60 µs ; Cepheus, en bleu, entre 24,1 et 25,7 µs.](images/bench-pages.svg)

**Sur un fork de 100 000 items** (chaque fait dans son delta, la base d'un programme en mémoire) :

| page | ancien | nouveau | nouveau/ancien |
|---|---:|---:|---:|
| par id, la première page | 25,4 ms [25,1 ms, 31,3 ms] | **44,8 µs [44,6 µs, 45,0 µs]** | 0,0018 |
| par id, après celui du milieu | 23,4 ms [23,1 ms, 24,2 ms] | **45,5 µs [45,0 µs, 45,8 µs]** | 0,0019 |
| par id décroissant, la première page | 25,8 ms [25,2 ms, 27,1 ms] | **47,5 µs [47,1 µs, 47,6 µs]** | 0,0018 |
| par id décroissant, après celui du milieu | 23,7 ms [23,2 ms, 24,2 ms] | **49,8 µs [48,6 µs, 51,2 µs]** | 0,0021 |
| celles du tenant 3 par id, la première page | 2,11 ms [2,06 ms, 3,04 ms] | **33,9 µs [33,3 µs, 34,2 µs]** | 0,0162 |
| celles du tenant 3 par id, après celle du milieu | 1,57 ms [1,56 ms, 2,42 ms] | **35,1 µs [34,4 µs, 35,3 µs]** | 0,0224 |
| celles du tenant 3 par id décroissant, la première page | 2,19 ms [2,15 ms, 3,32 ms] | **36,5 µs [36,2 µs, 37,2 µs]** | 0,0166 |
| celles du tenant 3 par id décroissant, après celle du milieu | 1,68 ms [1,61 ms, 2,40 ms] | **38,9 µs [38,1 µs, 64,0 µs]** | 0,0236 |


**À côté d'un delta d'un autre kind** (`kbench.exe mixed` : le run de 1 000 000 d'items, sur un fork dont le delta
tient 100 000 choses d'un autre kind, faites après eux, et un item renommé ; 3 tours alternés, cette version contre son
premier commit, ed44295, qui lisait le delta dans sa map par chose jusqu'à la chose suivante de la propriété) : les
choses de la propriété dans le delta, lues dans sa map par valeur (deux entrées), mettent une page de 51 par id à 25 à
27 µs, là où lire chaque chose plus récente du delta prenait 8,7 ms en croissant et 11,8 ms en décroissant ; les pages
des tableaux plus haut les mêmes, 0,99 à 1,04 fois.

**L'admin de Centauri** (le headless shell de Chrome, 5 tours, la médiane et [le plus petit, le plus grand]) : le
navigateur de données rempli avec les 100 005 clients, chaque page de 50 demandée à son tour (All), 94,4 s [92,1, 109,6]
avec le moteur de main, **40,6 s** [38,4, 46,5] avec celui-ci : 47 ms par page avant, 20 ms maintenant, dont le `Find`
de la page prend environ 0,05 ms ; le reste est le travail de l'admin autour de lui (les champs de chaque ligne lus par
un `Get`, son JSON, la page envoyée et son tableau rempli).

- Une page coûte ses lignes : 24 à 34 µs à chaque taille et à chaque profondeur, là où le coût du heap grandissait
  avec le kind (2,1 à 2,8 ms à 10 000 choses, 8,5 à 11 ms à 100 000, 81 à 99 ms à 1 000 000), 87 à 4 000 fois moins ;
  les choses d'un tenant (une sur 10), 5 à 410 fois moins. Dans le delta, une page prend 45 à 50 µs (chaque chose
  vérifiée contre les changements du delta), 480 à 570 fois moins que les 23 à 26 ms du heap ; celles d'un tenant 34 à
  39 µs, 43 à 62 fois moins.
- La keyset query de PostgreSQL lit le B-tree de sa clé primaire à partir du curseur et les lignes de la page : 36 à
  66 µs de son moteur seul, 1,4 à 2,5 fois celui de Cepheus, qui lit la colonne de la propriété dans l'ordre des ids (un
  mot de la rank table pour 32 choses) et fait les valeurs des lignes dans le même temps. Une page après celle du
  milieu coûte à PostgreSQL 1 à 21 µs de plus que la première (la descente de son B-tree jusqu'au curseur), à Cepheus
  0,5 à 1,4 µs par id (un mot de la rank table) et 3 à 10 µs pour celles d'un tenant (deux recherches binaires parmi
  les lignes de la valeur du tenant).

## Les questions découpées après un premier niveau étroit, et des groupes plus légers (2026-11-26), à 1 million de faits

**Ce qui était lent.** Chaque partie des questions a été chronométrée à part sur les données plus bas (un domain contre
huit, le join seul contre le join et ses groupes), sous le verrou :

- Le moteur ne découpait une question entre ses domains qu'à son premier niveau, et seulement quand ce niveau avait
  20 000 candidats ou plus. Les factures dont le total est sous celui d'une facture partent de ce seul total (l'ordre :
  le total, les totaux en dessous, leurs factures) : les 122 962 factures tournaient sur un seul domain, 37 à 39 ms sur
  1 et 2 domains et pas moins sur 8. Un rapport par ville part des 10 000 clients, moins de candidats que les 245 000
  factures, donc le premier du planner : sur un seul domain aussi, 45 ms sur 8 domains comme sur 1.
- Un rapport de 10 000 groupes part des factures et était découpé, mais chacune de ses 128 slices construisait sa
  propre table de hachage, un tableau de clé fait et haché par le hash polymorphe d'OCaml pour chaque ligne et un objet
  par groupe et par slice ; les 128 tables étaient ensuite fusionnées sur un seul domain (32 ms des 85 d'un `Sum`), les
  groupes triés par la comparaison polymorphe (5,6 ms), et les sacs d'une médiane fusionnés en remettant chaque valeur
  dans une seule table (25 à 95 ms).
- `Cepheus.ask` faisait les valeurs de ses lignes sur un seul domain après le fold (122 962 lignes pour le range plus
  haut).

**Ce qui a changé.** Un niveau de 20 000 candidats ou plus est découpé où qu'il vienne dans l'ordre ; le premier niveau
de deux candidats ou plus après ceux d'un seul, quand le planner attend 80 000 candidats de travail ou plus, tourne sur
le domain qui pose la question jusqu'à ce que le travail mesuré de ses candidats dise que le reste en prend autant, et
le reste est découpé ([architecture](architecture.md#un-seul-writer-threads-et-domains)). Les groupes d'un
Group sont des numéros dans une seule table à adressage ouvert sur les mots de leurs clés (une ligne coûte un hash et
aucune allocation), leurs Count, Sum, Min et Max dans un seul tableau plat, les sommes exactes d'une moyenne dans quatre
entiers par groupe, le sac de tous les groupes dans une seule table par colonne (une table par groupe dès que les
groupes tiennent plus de 64 valeurs différentes chacun : les milliers de totaux d'une ville) ; une table par domain (ces agrégats
ne dépendent pas de l'ordre des lignes), fusionnées à la fin, les sacs des domains lus ensemble alors plutôt que remis,
les groupes triés par une comparaison d'entiers. `ask` fait les valeurs de chaque ligne dans son step, sur le domain
qui l'a trouvée.

**Méthode.** Les données des deux sections plus bas (`bench.exe load`, 1 M de faits ; `rbench.exe load`, 990 000),
chacune fusionnée en un seul run, sur le SSD SATA ; PostgreSQL 18.6 les mêmes lignes. Les binaires de main (8a97c5d,
*ancien*) à côté de ceux de cette version (*nouveau*), compilés de la même façon et alternés à chaque tour : 5 tours,
chaque côté une médiane de 11 passages (5 pour `bench.exe pages`) ; donné : la médiane des 5 tours et entre crochets
leur plus petit et leur plus grand ; *nouveau/ancien* : la médiane des rapports des tours, entre crochets leur plus
petit et leur plus grand. `CEPHEUS_DOMAINS` 8 (le défaut ici : 4 cœurs, 8 threads), 4, 2 et 1 pour `rbench.exe` et
`bench.exe read` (`bench.exe pages` tourne sur 8). PostgreSQL : le temps de son moteur (`EXPLAIN (ANALYZE, TIMING
OFF)`), 2 workers permis. La machine était partagée : une charge moyenne (sur 1 minute) de 1,7 à 3,3 sur ses 8 threads.

**Les rapports**, 8 domains (à côté de PostgreSQL : [la section suivante](#les-rapports--avg-countx-values-quantile-stddev-trunc-2026-11-26-à-1-million-de-faits)) :

| question | ancien | nouveau | nouveau/ancien |
|---|---:|---:|---:|
| Sum 1 groupe | 13,5 ms [13,3, 17,6] | 12,0 ms [10,5, 15,3] | 0,81 [0,70 ; 1,15] |
| Avg 1 groupe | 13,5 ms [13,3, 15,4] | 11,6 ms [11,4, 13,5] | 0,87 [0,85 ; 0,98] |
| Count(status) 1 groupe | 18,2 ms [18,0, 30,1] | 17,0 ms [15,6, 18,1] | 0,87 [0,60 ; 0,95] |
| Values(status) 1 groupe | 18,2 ms [18,0, 19,1] | 17,9 ms [14,9, 23,3] | 0,94 [0,82 ; 1,28] |
| Median 1 groupe | 28,1 ms [27,5, 28,2] | 28,8 ms [26,8, 30,6] | 1,02 [0,95 ; 1,09] |
| Stddev 1 groupe | 13,7 ms [13,3, 13,9] | 12,0 ms [11,7, 14,0] | 0,87 [0,87 ; 1,01] |
| Sum 100 groupes (ville) | 46,5 ms [45,9, 52,1] | 9,68 ms [9,25, 11,3] | 0,21 [0,19 ; 0,23] |
| Avg 100 groupes (ville) | 52,0 ms [50,5, 56,5] | 11,0 ms [10,3, 12,5] | 0,22 [0,20 ; 0,23] |
| Count(status) 100 groupes (ville) | 72,4 ms [71,4, 81,7] | 15,2 ms [14,7, 17,8] | 0,21 [0,19 ; 0,25] |
| Values(status) 100 groupes (ville) | 73,2 ms [72,6, 94,0] | 15,2 ms [15,0, 17,6] | 0,21 [0,16 ; 0,24] |
| Median 100 groupes (ville) | 93,1 ms [88,3, 93,7] | 39,6 ms [38,4, 45,8] | 0,45 [0,42 ; 0,49] |
| Stddev 100 groupes (ville) | 51,3 ms [50,4, 53,6] | 11,4 ms [10,9, 14,1] | 0,23 [0,21 ; 0,26] |
| Sum 10 000 groupes (client) | 83,4 ms [80,9, 91,9] | 26,1 ms [25,0, 33,3] | 0,31 [0,30 ; 0,41] |
| Avg 10 000 groupes (client) | 151 ms [142, 163] | 36,5 ms [35,1, 46,4] | 0,24 [0,23 ; 0,31] |
| Count(status) 10 000 groupes (client) | 200 ms [195, 225] | 57,7 ms [55,1, 76,9] | 0,29 [0,28 ; 0,38] |
| Values(status) 10 000 groupes (client) | 227 ms [221, 251] | 73,6 ms [70,5, 95,1] | 0,33 [0,31 ; 0,41] |
| Median 10 000 groupes (client) | 285 ms [279, 306] | 82,3 ms [79,3, 106] | 0,29 [0,28 ; 0,35] |
| Stddev 10 000 groupes (client) | 160 ms [142, 164] | 38,0 ms [35,5, 47,2] | 0,27 [0,22 ; 0,29] |
| Sum par mois à Paris (Trunc) | 31,7 ms [28,7, 36,8] | 20,9 ms [20,4, 24,7] | 0,69 [0,66 ; 0,75] |
| Sum par mois en UTC (Trunc) | 26,6 ms [26,4, 39,7] | 19,0 ms [18,2, 24,3] | 0,70 [0,61 ; 0,73] |

**Sur 1, 2, 4 et 8 domains** (`CEPHEUS_DOMAINS`), nouveau (ancien) :

| question | 1 | 2 | 4 | 8 |
|---|---:|---:|---:|---:|
| Sum 1 groupe | 26,6 (32,8) | 23,4 (22,8) | 14,1 (16,8) | 12,0 (13,5) |
| Sum 100 groupes (ville) | 36,0 (45,4) | 19,6 (45,7) | 10,7 (44,9) | 9,68 (46,5) |
| Median 100 groupes (ville) | 87,3 (91,5) | 61,1 (90,1) | 44,2 (92,7) | 39,6 (93,1) |
| Avg 10 000 groupes (client) | 71,0 (121) | 49,2 (191) | 38,4 (158) | 36,5 (151) |
| Median 10 000 groupes (client) | 141 (229) | 102 (318) | 88,0 (292) | 82,3 (285) |

**Less et Optional** (`bench.exe pages`, 8 domains), à côté du moteur de PostgreSQL (`pg.sh ops`) :

| question | ancien | nouveau | nouveau/ancien | PostgreSQL 18.6 |
|---|---:|---:|---:|---:|
| les liens de suivi vers un client plus récent, `Less(a, b)` | 11,0 ms [10,6, 11,4] | 8,76 ms [8,41, 9,31] | 0,79 [0,77 ; 0,84] | 3,82 ms [3,60, 4,14] |
| les factures sous le total d'une facture, `Less(t, tx)` | 57,5 ms [54,3, 59,4] | 28,0 ms [27,3, 30,7] | 0,51 [0,46 ; 0,53] | 19,0 ms [18,9, 19,6] |
| &nbsp;&nbsp;le même range, sa borne lue d'abord | 39,3 ms [38,0, 39,9] | 26,7 ms [25,8, 27,8] | 0,69 [0,66 ; 0,70] |  |
| chaque client avec les clients qu'il suit, `Optional` | 21,9 ms [21,4, 22,9] | 16,7 ms [15,7, 17,7] | 0,76 [0,72 ; 0,81] | 12,5 ms [12,2, 13,2] |
| &nbsp;&nbsp;la même chose en join | 24,6 ms [23,7, 27,8] | 18,8 ms [18,2, 19,2] | 0,76 [0,69 ; 0,78] |  |

**Les questions d'avant** : Q1 à Q5 (`bench.exe read`) et de petites questions en boucle (`mbench.ml` : le coût fixe
d'un fold), nouveau/ancien :

| question | 1 domain | 8 domains |
|---|---:|---:|
| Q1, une facture par son id | 1,00 [0,97 ; 1,03] | 1,00 [0,92 ; 1,08] |
| Q2, un client par son e-mail | 1,00 [0,98 ; 1,04] | 1,00 [0,97 ; 1,02] |
| Q3, les factures impayées d'une ville (396 lignes) | 1,02 [1,01 ; 1,06] | 1,01 [0,98 ; 1,03] |
| Q4, la somme des impayés par ville (45 064 factures) | 1,03 [0,98 ; 1,04] | 1,00 [0,92 ; 1,13] |
| Q5, les triangles des liens de suivi | 1,00 [0,97 ; 1,00] | 1,01 [0,98 ; 1,03] |
| un fold d'un seul fait (le nom d'une chose) | 0,99 [0,99 ; 1,09] | 1,00 [0,82 ; 1,08] |
| `Prefix`, un e-mail (`ask`) | 0,99 [0,98 ; 1,04] | 1,00 [0,95 ; 1,15] |
| Q3 compté (`fold`) | 1,01 [1,00 ; 1,05] | 0,99 [0,98 ; 1,00] |
| `Not`, les clients d'une ville sans facture impayée (`ask`) | 1,03 [0,99 ; 1,04] | 1,00 [0,93 ; 1,24] |
| `Optional`, les clients d'une ville et leurs suivis (`ask`) | 0,99 [0,97 ; 1,04] | 0,97 [0,89 ; 0,99] |
| une page de 20, les plus grands totaux d'abord (`ask`) | 0,99 [0,97 ; 1,06] | 1,01 [0,94 ; 1,01] |
| chaque e-mail (`find`, 11 363 textes) | 1,01 [0,94 ; 1,06] | 0,96 [0,95 ; 1,04] |
| le fold de Q4 seul | 1,00 [0,99 ; 1,10] | 1,01 [0,84 ; 1,08] |

- **Les rapports** : 3 à 5 fois plus rapides à 100 et 10 000 groupes sur 8 domains (une médiane de 100 groupes
  2,2 fois) ; sur un seul domain 1,1 à 1,8 fois, les tables plates. PostgreSQL est maintenant derrière à tous les
  nombres de groupes ([la section suivante](#les-rapports--avg-countx-values-quantile-stddev-trunc-2026-11-26-à-1-million-de-faits)).
- **Le range sous le total d'une facture** se découpe maintenant à son deuxième niveau ; son temps est alors celui des
  valeurs qu'il fait : le même range avec sa borne lue d'abord prend autant.
- **Ce qui perd encore** : la vérification de chaque lien de suivi, `Less(a, b)` (8,76 ms contre 3,82 ms pour
  PostgreSQL : son parcours d'une table de deux colonnes lit une ligne en 70 ns, là où Cepheus lit l'index des liens
  fait par fait et fait les valeurs de chaque ligne) ; le range sous le total d'une facture (28,0 ms contre 19,0 ms : les
  122 962 lignes faites en valeurs OCaml, le travail d'un programme qui lit, là où le moteur de PostgreSQL n'en envoie
  aucune) ; chaque client avec les clients qu'il suit (16,7 ms contre 12,5 ms : le hash join de PostgreSQL de deux tables
  entières).
- **Rien d'avant plus lent** : Q1 à Q5 sur 1, 2, 4 et 8 domains de 0,97 à 1,04 (les médianes des rapports des tours ;
  Q4 sur un seul domain 1,03, et son fold seul en boucle 1,00), les petites questions en boucle de 0,96 à 1,03 : la
  machinerie du découpage n'est faite que pour un niveau à découper ou à sonder, si bien qu'un fold qui n'en a pas
  alloue ce qu'il allouait.

## Les rapports : Avg, Count(x), Values, Quantile, Stddev, Trunc (2026-11-26), à 1 million de faits

**Méthode.** `bench/rbench.ml load` : 10 000 clients (une ville parmi 100) et 245 000 factures (un client, un total de
0,01 à 1 000,00 en centimes, un statut : 70 % payées, 20 % impayées, 10 % en retard, une date de 2017 à 2026) : 990 000
faits fusionnés en un seul run, sur le SSD SATA ; PostgreSQL 18.6 les mêmes lignes (`pg.sh reports load` : `rclient`,
`rinvoice`, le total un `bigint` de centimes, la date un `timestamptz`, `rinvoice(client)` indexé, `VACUUM ANALYZE`).
Chaque agrégat sur toutes les factures (1 groupe), par la ville de leur client (100 groupes : un join des factures et
des clients), par leur client (10 000 groupes), chaque côté ne lisant que ce dont l'agrégat a besoin : Cepheus la
réponse du moteur (`rbench.exe run` : `Answer.answer`, ce que calcule le serveur, sans socket), PostgreSQL le temps
d'exécution de `EXPLAIN (ANALYZE, TIMING OFF)` (`pg.sh reports run` : dans le serveur, sans socket, avec ses 2 workers
parallèles par défaut). 5 tours alternés, chaque côté une médiane de 11 passages ; donné : la médiane des 5 tours, et
entre crochets leur plus petit et leur plus grand. Les mêmes réponses des deux côtés (lignes comptées ; un groupe
`Values` est une ligne par statut chez Cepheus, un tableau chez PostgreSQL). Mesuré de nouveau le même jour après le
découpage après un premier niveau étroit et les tables plates de groupes ([la section
plus haut](#les-questions-découpées-après-un-premier-niveau-étroit-et-des-groupes-plus-légers-2026-11-26-à-1-million-de-faits),
qui donne les chiffres d'avant) ; la machine était partagée : une charge moyenne (sur 1 minute) de 1,9 à 2,5 sur ses
8 threads.

| agrégat | groupes | Cepheus | PostgreSQL 18.6 | |
|---|---:|---:|---:|---|
| `Sum` (l'agrégat d'avant ; `sum`) | 1 | **12,0 ms** [10,5, 15,3] | 13,4 ms [13,3, 15,7] | Cepheus, 1,1 fois |
| | 100 | **9,68 ms** [9,25, 11,3] | 57,8 ms [50,6, 72,6] | Cepheus, 6,0 fois |
| | 10 000 | **26,1 ms** [25,0, 33,3] | 63,7 ms [63,2, 93,4] | Cepheus, 2,4 fois |
| `Avg` (`avg`) | 1 | **11,6 ms** [11,4, 13,5] | 13,6 ms [13,4, 15,7] | Cepheus, 1,2 fois |
| | 100 | **11,0 ms** [10,3, 12,5] | 53,1 ms [50,5, 68,8] | Cepheus, 4,8 fois |
| | 10 000 | **36,5 ms** [35,1, 46,4] | 65,5 ms [64,6, 68,2] | Cepheus, 1,8 fois |
| `Count(status)` (`count(DISTINCT status)`) | 1 | **17,0 ms** [15,6, 18,1] | 54,2 ms [53,7, 64,8] | Cepheus, 3,2 fois |
| | 100 | **15,2 ms** [14,7, 17,8] | 190 ms [188, 253] | Cepheus, 13 fois |
| | 10 000 | **57,7 ms** [55,1, 76,9] | 169 ms [166, 178] | Cepheus, 2,9 fois |
| `Values(status)` (`array_agg(DISTINCT status)`) | 1 | **17,9 ms** [14,9, 23,3] | 53,6 ms [53,3, 67,7] | Cepheus, 3,0 fois |
| | 100 | **15,2 ms** [15,0, 17,6] | 201 ms [197, 262] | Cepheus, 13 fois |
| | 10 000 | **73,6 ms** [70,5, 95,1] | 171 ms [170, 181] | Cepheus, 2,3 fois |
| `Median(total)` (`percentile_cont(0.5) WITHIN GROUP (ORDER BY total)`) | 1 | **28,8 ms** [26,8, 30,6] | 56,9 ms [56,6, 66,4] | Cepheus, 2,0 fois |
| | 100 | **39,6 ms** [38,4, 45,8] | 200 ms [192, 254] | Cepheus, 5,0 fois |
| | 10 000 | **82,3 ms** [79,3, 106] | 135 ms [133, 141] | Cepheus, 1,6 fois |
| `Stddev(total)` (`stddev`) | 1 | **12,0 ms** [11,7, 14,0] | 25,0 ms [24,9, 29,2] | Cepheus, 2,1 fois |
| | 100 | **11,4 ms** [10,9, 14,1] | 66,6 ms [64,3, 87,4] | Cepheus, 5,9 fois |
| | 10 000 | **38,0 ms** [35,5, 47,2] | 112 ms [107, 128] | Cepheus, 2,9 fois |
| `Sum` par `Trunc(date, "month", zone = "Europe/Paris")` (`date_trunc('month', date, 'Europe/Paris')`) | 121 | **20,9 ms** [20,4, 24,7] | 141 ms [138, 174] | Cepheus, 6,7 fois |
| `Sum` par `Trunc(date, "month")` (UTC) | 120 | **19,0 ms** [18,2, 24,3] | 132 ms [129, 163] | Cepheus, 7,0 fois |

- **Cepheus à tous les nombres de groupes.** Le `count(DISTINCT)`, le `array_agg(DISTINCT)` et le `percentile_cont` de
  PostgreSQL trient les lignes de chaque groupe (un tri de 245 000 lignes pour un seul groupe), là où Cepheus garde les
  valeurs différentes de chaque groupe avec leurs comptes (3 statuts, environ 92 000 totaux) et sélectionne le rang de
  la médiane. Les questions de 100 et de 10 000 groupes tournent maintenant sur les 8 domains de Cepheus : la première
  part des 10 000 clients, un niveau trop petit pour être découpé par son compte, dont le travail mesuré des candidats
  (environ 50 candidats par client) découpe le reste ; la seconde des 245 000 factures, comme avant, ses groupes
  maintenant dans une table plate par domain (les sommes exactes d'une moyenne dans quatre entiers par groupe, les
  valeurs différentes d'un groupe dans la seule table de sa colonne) là où chacune de 128 slices construisait une table
  de hachage d'objets. PostgreSQL a lancé ses 2 workers et son leader. Un seul groupe est le plus proche pour `Sum` et
  `Avg` (1,1 à 1,2 fois) : un seul parcours de 245 000 lignes, chaque côté sur ses cœurs.
- **L'exact coûte peu.** Une moyenne ou une dispersion à partir de sommes exactes coûte ce que coûte une somme, à un
  sixième près à 1 et 100 groupes, deux cinquièmes de plus à 10 000 (le résultat de chaque groupe calculé à partir de
  ses sommes) : les sommes d'un int restent dans des ints simples tant qu'elles ne peuvent pas déborder (une valeur d'au
  plus 26 bits, un millier de carrés), et les morceaux ne sont faits qu'au-delà.
- **Trunc** lit le décalage du fuseau par une recherche dichotomique dans ses transitions et se souvient du début des
  1 024 derniers mois qu'il a trouvés : 0,01 µs par ligne de plus qu'en UTC ici. Toute la question de PostgreSQL coûte
  0,6 µs par ligne, son `date_trunc` convertissant l'instant de chaque ligne en heure locale et retour.
- **Pas de ralentissement des questions d'avant**, quand les rapports sont venus : `abench.exe`, le même fichier compilé
  sur main (d9431f6) et sur cette branche-là, alternés à chaque tour sur la même base : un Give d'un join, `Sum` et
  `Count` par ville, `Min` et `Max` par client, un groupe trié, une page, `Not`, un range et `Optional` : nouveau/ancien
  de 0,93 à 1,01 (la médiane des rapports des tours ; leurs plus petit et plus grand 0,65 et 1,31, le bruit d'une
  machine partagée sur des questions de moins d'une milliseconde). L'A/B du découpage lui-même : [la section plus
  haut](#les-questions-découpées-après-un-premier-niveau-étroit-et-des-groupes-plus-légers-2026-11-26-à-1-million-de-faits).

## Les suppressions et les liens qui nomment un kind (2026-11-25)

**Méthode.** `bench/dbench.ml load` : 10 000 clients, 100 000 factures (`invoice/client` nomme le kind client,
`refuse`), 200 000 lignes réparties sur elles (`line/invoice` : `cascade`), et les choses mesurées : des clients de 0,
100 et 10 000 factures, des factures de 0, 100 et 10 000 lignes, et de 0, 100 et 10 000 notes (`note/about` :
`clear`), 680 681 faits fusionnés en un seul run, sur le SSD SATA. PostgreSQL 18.6 les mêmes lignes (`pg.sh fk load`,
`bench/pg/fk.sql`), les colonnes qui pointent indexées, comme un utilisateur de PostgreSQL les écrit, `REFERENCES
client` sans action (`NO ACTION`, qui refuse), `ON DELETE CASCADE` et `ON DELETE SET NULL`. Chaque côté mesure le
travail de son moteur et le jette, pour que chaque passage supprime la même chose : Cepheus `dbench.exe delete`, le
groupe d'un seul `Delete` écrit dans un fork de la base (le resolve du writer, rien sur le disque) ; PostgreSQL
`pg.sh fk run`, le `DELETE` chronométré dans le serveur par une fonction PL/pgSQL dans une sous-transaction annulée (un
refus par une foreign key rattrapé), son plan gardé par la session. 5 tours, chaque côté une médiane de 21 passages ;
donnés : la médiane des 5 tours, et entre crochets le plus petit et le plus grand. La machine était partagée avec
d'autres jobs : une charge moyenne (sur 1 minute) de 2,7 à 3,1 sur ses 8 threads.

| un Delete de | choses qui pointent | Cepheus | PostgreSQL 18.6 | |
|---|---:|---:|---:|---|
| un client, `refuse` (refusé sauf pour 0) | 0 | **5 µs** [5, 6] | 92 µs [74, 107] | Cepheus, 18 fois |
| | 100 | **6 µs** [5, 6,9] | 78 µs [78, 90] | Cepheus, 13 fois |
| | 10 000 | **6 µs** [6, 10] | 89 µs [81, 98] | Cepheus, 15 fois |
| une facture, ses lignes `cascade` | 0 | **11,9 µs** [11, 16] | 120 µs [114, 133] | Cepheus, 10 fois |
| | 100 | **176 µs** [167, 186] | 193 µs [174, 200] | à peu près pareil |
| | 10 000 | 27,3 ms [26,3, 30,3] | **5,16 ms** [5,06, 5,34] | PostgreSQL, 5,3 fois |
| une facture, le lien de ses notes `clear` | 0 | **11 µs** [4,1, 12,9] | 109 µs [106, 114] | Cepheus, 10 fois |
| | 100 | **93 µs** [85, 109] | 723 µs [667, 754] | Cepheus, 7,8 fois |
| | 10 000 | **11,1 ms** [10,8, 11,4] | 46,5 ms [45,3, 47,7] | Cepheus, 4,2 fois |
| &nbsp;&nbsp;à côté : un groupe de `Retract` des 20 000 faits des 10 000 lignes | | 21,6 ms [20,7, 22,4] | | |

- **Trouver les choses qui pointent vers une chose** est une seule recherche dans l'index par valeur par propriété de
  lien qui nomme le kind, quel que soit leur nombre : un refus coûte la même chose à 0, 100 ou 10 000 factures,
  puisqu'il lui en faut une. Le refus de PostgreSQL fait passer la requête de la foreign key (`SELECT 1 FROM invoice
  WHERE client = $1 FOR KEY SHARE`) par sa machinerie de triggers, environ 80 µs quel que soit le nombre.
- **Une cascade coûte ce que coûte le retrait de ses faits**, plus un quart pour suivre les liens (27,3 contre 21,6 ms
  à 10 000 lignes) : chaque retrait va dans les maps persistantes du writer, environ 1 µs par fait. PostgreSQL
  supprime une ligne en la marquant (son `xmax`), sans toucher d'index avant `VACUUM` : 0,5 µs par ligne, 5,3 fois plus
  vite à 10 000. Rendre les grands retraits de Cepheus moins chers, comme le sont ses grands ajouts (le chemin des
  chargements), n'est pas encore construit.
- **Un clear** retire un fait par note : 1,1 µs par note contre 4,6 µs pour PostgreSQL, dont le `SET NULL` met à jour
  chaque ligne : une nouvelle version d'elle, et de ses entrées d'index.
- Les temps de PostgreSQL comprennent la sous-transaction qui rattrape un refus : 11 µs, mesurés par la même fonction
  autour d'une lecture d'une ligne par sa clé (21 passages) ; le fork de Cepheus ne coûte rien à faire.

**Un lien qui nomme un kind ne coûte presque rien à une écriture.** `dbench.exe write` : 200 000 groupes d'une facture
chacun (son lien vers un client et son total) sur un fork, en 5 passes, la passe médiane ; 5 tours alternés avec main
d'avant ce travail (105735c), construit de la même façon, chacun sur sa propre copie des données ; PostgreSQL : 10 000
`INSERT` d'une ligne de facture dans une boucle PL/pgSQL, annulés, dans une table sans foreign key et une avec
(`REFERENCES account`), 5 passes.

| une écriture d'une facture | Cepheus | PostgreSQL 18.6 |
|---|---:|---:|
| un lien vers n'importe quelle chose (pas de foreign key) | 3,90 µs [3,80, 4,21] (main), 3,96 µs [3,90, 4,11] (celui-ci) | 5,46 µs [5,33, 5,65] |
| un lien qui nomme un kind (une foreign key) | **4,17 µs** [4,04, 4,31] | 15,1 µs [14,8, 16,1] |
| le coût de la vérification | 0,2 µs | 9,6 µs |

- La vérification est une seule recherche : la chose liée a un fait d'une des propriétés du kind (la première qu'elle
  essaie, pour un client). PostgreSQL fait passer la requête de la foreign key par un trigger à chaque ligne, ce qui
  triple le coût d'une insertion.
- **Les écritures ne sont pas plus lentes.** Contre main, sur une base dont le schéma n'a aucun lien qui nomme un kind,
  11 tours alternés (une charge de 2,2 à 2,4) : 1,02 fois le temps de main [0,83, 1,16], dans le bruit de la machine ;
  sur un schéma avec des liens, une écriture d'une autre propriété : 1,00 [0,94, 1,04], 5 tours.

## Less, Optional et un compteur partagé (2026-11-25), à 1 million de faits

**Méthode.** Les données des autres sections à 1 M de faits (11 363 clients, 227 260 factures, 56 797 liens de suivi),
chargées par `bench.exe load` et fusionnées en un seul run ; PostgreSQL 18.6 les mêmes lignes (`pg.sh load`), avec un
index sur `invoice (total)` que `pg.sh ops` ajoute pour le range plus bas. Les questions : Cepheus `bench.exe pages`
dans son processus (le moteur, jusqu'à 8 domains, les lignes faites en valeurs OCaml) ; PostgreSQL le temps
d'exécution de `EXPLAIN (ANALYZE, TIMING OFF)` (son moteur, aucune ligne envoyée ; il a choisi un seul processus pour
chacune). 5 tours, les deux côtés l'un après l'autre dans chacun, chaque côté une médiane de 5 appels ; donnés : la
médiane des 5 tours, et entre crochets le plus petit et le plus grand. La machine était partagée avec le travail
d'autres jobs cette fois : une charge moyenne (load average, sur 1 minute) de 6,2 à 6,5 sur ses 8 threads pendant ces
tours, donc ce sont les chiffres d'une machine occupée, pour les deux côtés pareil. Les données sur le SSD SATA (btrfs)
des autres sections. La table de `Less` et `Optional` a été mesurée de nouveau le 2026-11-26, après le découpage après
un premier niveau étroit ([la section plus haut](#les-questions-découpées-après-un-premier-niveau-étroit-et-des-groupes-plus-légers-2026-11-26-à-1-million-de-faits)), sur les données du même générateur chargées de nouveau, à une
charge de 2,2 à 3,3 ; les chiffres du compteur sont du 25.

| question | lignes | Cepheus | PostgreSQL 18.6 | |
|---|---:|---:|---:|---|
| les liens de suivi d'un client vers un plus récent, `Less(a, b)` : une vérification de chaque lien | 28 250 | 8,76 ms [8,41, 9,31] | **3,82 ms** [3,60, 4,14], un `Seq Scan` avec son `Filter` | PostgreSQL, 2,3 fois |
| &nbsp;&nbsp;la même, chaque lien donné et filtré par le programme | | 14,2 ms [12,4, 15,4] | | |
| les factures dont le total est sous celui d'une facture, `Less(t, tx)` : un range de l'index des totaux | 122 962 | 28,0 ms [27,3, 30,7] | **19,0 ms** [18,9, 19,6], un `Bitmap Index Scan` sur `total` | PostgreSQL, 1,5 fois |
| &nbsp;&nbsp;le même range, sa borne lue d'abord (`Below` de ce total) | | 26,7 ms [25,8, 27,8] | | |
| les 490 clients de city-7 avec les clients que chacun suit, `Optional` | 490 | **0,077 ms** [0,069, 0,087] | 0,441 ms [0,428, 0,444], un `Nested Loop Left Join` | Cepheus, 5,7 fois |
| &nbsp;&nbsp;la même comme un join | | 0,091 ms [0,083, 0,115] | | |
| chaque client avec les clients qu'il suit, `Optional` | 56 797 | 16,7 ms [15,7, 17,7] | **12,5 ms** [12,2, 13,2], un `Hash Right Join` | PostgreSQL, 1,3 fois |
| &nbsp;&nbsp;la même comme un join | | 18,8 ms [18,2, 19,2] | | |

- **Les réponses** sont les mêmes des deux côtés (122 962, 490 et 56 797 lignes) sauf pour la première : « a < b »
  compare des ids, et Cepheus numérote ses choses dans l'ordre où les 64 threads du chargement les ont écrites,
  PostgreSQL par le numéro du client, donc les paires gardées diffèrent un peu (28 250 contre 28 265 des 56 797
  liens).
- **`Optional` coûte ce que coûte le join** (0,077 contre 0,091 ms, 16,7 contre 18,8) : chercher les valeurs de la
  chose après le join est le travail que le join fait à ce pattern. Ici chaque client suit au moins 4 autres, donc
  aucune ligne n'est absente : la mesure est celle de la façon du left join, pas des lignes absentes. Sur les clients
  d'une ville Cepheus est 5,7 fois plus rapide (ses index donnent directement les 490 clients et leurs liens) ; sur
  chaque client, le hash join de PostgreSQL sur les deux tables, lues entières dans leur ordre, est plus rapide,
  1,3 fois maintenant (1,8 avant le découpage).
- **`Less` coûte moins que le filtre du programme lui-même** (8,8 contre 14,2 ms), mais le parcours par PostgreSQL
  d'une table de deux colonnes, dans un seul processus, lit une ligne en 70 ns là où Cepheus lit l'index des liens fait
  par fait et fait les valeurs de chaque ligne.
- **Le range de `Less`** lit les 122 962 totaux sous la borne dans l'index trié, comme le fait le même range avec sa
  borne lue d'abord (28,0 contre 26,7 ms) : découpé à son deuxième niveau maintenant, là où il tournait avant sur un
  seul domain, la question n'étant découpée qu'à son premier niveau, ici le seul total de la borne (55 à 57 ms : [la
  section plus haut](#les-questions-découpées-après-un-premier-niveau-étroit-et-des-groupes-plus-légers-2026-11-26-à-1-million-de-faits)). Ce qui reste est de faire les valeurs de ses lignes, ce que le moteur de PostgreSQL ne fait
  pas.

**Un compteur que 64 écrivains incrémentent** (tutoriels [1](tutorials.md#1-des-numéros-de-facture-sans-trou) et
[7](tutorials.md#7-un-stock-qui-ne-descend-jamais-sous-zéro)) : chaque écriture son propre groupe, forcé sur le disque,
pendant 5 s ; 5 tours ; la charge moyenne de 5,2 à 6,2. Cepheus : `bench/cesia/write.ce 64 5 counter`, 64 fibers
d'un programme Cesia sur une seule connexion, chaque groupe un `Incr` d'un même compteur, contre un serveur à lui sur
le SSD ; à côté, le même programme qui insère une facture de 4 faits par groupe. PostgreSQL : `COUNTER=1 pg.sh write`,
pgbench avec 64 connexions, chaque transaction `UPDATE counter SET last = last + 1 WHERE id = 1` ; à côté, le même
pgbench qui insère une ligne de facture.

| 64 écrivains | Cepheus | PostgreSQL 18.6 |
|---|---:|---:|
| un compteur que chaque écriture incrémente | **5 890 par seconde** [4 578, 7 939], latence médiane 9,3 ms | 154 par seconde [8, 214], 231 ms |
| une nouvelle ligne ou chose à chaque écriture, rien de partagé | 6 636 par seconde [5 114, 8 670], 6,9 ms (\*) | 5 387 par seconde [4 392, 6 557], 9,5 ms |

- Le lock de ligne de PostgreSQL tient le compteur jusqu'à ce que le commit de la transaction soit sur le disque,
  donc ses 64 écrivains passent un fsync à la fois : 35 fois moins d'écritures que quand ils ne partagent rien (un
  tour est tombé à 8 par seconde, sa latence à 8,2 s : un arrêt du disque sous la charge des autres, gardé dans
  l'intervalle). Le writer de Cepheus lit le compteur à mesure qu'il applique chaque groupe, et les groupes qui
  arrivent pendant que le disque travaille partagent son fsync suivant : le compteur va aussi vite que des écritures
  qui ne partagent rien.
- (\*) Dans d'autres tours (5, à une charge de 3,1 à 3,4), alternés avec le compteur, qui y a fait 8 632 par seconde
  [6 298, 8 801] : un groupe du compteur est un fait, une insertion quatre.

**Q1 à Q5 ne sont pas plus lents.** Contre main avant ce travail (6707b9e), construit de la même façon, sur les mêmes
données, les deux binaires alternés dans chaque tour (`bench.exe read`, 21 passages par question dans chacun), nouveau
/ ancien par la médiane des rapports des tours : en 5 tours à une charge de 7 à 11, Q1 0,92 [0,62, 1,07], Q2 0,95
[0,76, 1,16], Q3 1,17 [0,93, 1,68], Q4 1,04 [0,84, 1,28], Q5 0,98 [0,87, 1,17] ; Q3, le plus large, de nouveau seul en
11 tours à une charge de 2,1 à 2,7 : 1,02 [0,98, 1,06] sur 8 domains (le plus petit de ses passages 274 µs contre
277), 1,05 [0,90, 1,33] sur un seul. Une question sans les nouvelles conditions fait le test d'un candidat qu'elle
faisait avant elles : leurs vérifications sont derrière un drapeau qui est faux pour elle.

## La sauvegarde et la restauration (2026-11-24), à 10 millions de faits

**Méthode.** `bench/ops.sh`, sur la machine des autres sections (i7-4720HQ, 4 cœurs et 8 threads, 11 Go, un SSD SATA
sous btrfs, plein à 97 % ce jour-là), sous le verrou qui tient à l'écart les autres gros travaux de la machine
(d'autres sessions faisaient à côté un travail léger : une charge moyenne de 3) ; chaque fichier dans le cache de pages
(à chaud : les copies lisent la mémoire, pas le disque) ; 21 tours, chaque temps donné par sa médiane et son
intervalle à 95 % qui ne suppose aucune loi. Les mêmes données des trois côtés : les 10 M de faits des autres sections
(113 636 clients, 2 272 720 factures, les liens de suivi), chargés dans Cepheus comme une application les écrit
(`bench.exe load`, un groupe par client et ses factures, 64 threads : 227 274 groupes en 107 s ; les runs laissés tels
que le chargement les a faits : un run des groupes 1 à 223 108, et 4 166 groupes dans le journal après lui), et dans
PostgreSQL 18.6 et SQLite 3.54 depuis les mêmes fichiers CSV.

- **Cepheus** : `cepheus backup` du serveur en marche (aucun programme n'écrit), `cepheus verify` de la copie,
  `cepheus restore` de la copie jusqu'à sa fin, et jusqu'au groupe du milieu de son historique
  (`--to-group 113637` : aucun run ne finit avant lui, donc l'ouverture rejoue depuis le journal les groupes 1 à
  113 637, les clients et leurs factures, 9,43 M de faits, en les fusionnant dans des runs comme le ferait
  l'écrivain).
- **PostgreSQL** : son WAL (son journal) archivé (`archive_command = 'cp %p ...'`), une sauvegarde de base prise avant
  le chargement (48 Mo) ; puis `pg_basebackup -X stream -c fast` (format plain, le WAL envoyé en flux, un checkpoint
  rapide), `pg_verifybackup` de la copie (le CRC-32C de chaque fichier contre le manifeste de la sauvegarde, et le WAL
  dont elle a besoin), sa restauration (une copie, un démarrage, prêt à recevoir des connexions), et une restauration à
  un instant donné (point-in-time recovery) jusqu'au milieu du WAL du chargement depuis la sauvegarde de base prise
  avant lui (`recovery_target_lsn`, puis promue)
  ([archivage continu et restauration à un instant donné](https://www.postgresql.org/docs/current/continuous-archiving.html),
  [pg_basebackup](https://www.postgresql.org/docs/current/app-pgbasebackup.html),
  [pg_verifybackup](https://www.postgresql.org/docs/current/app-pgverifybackup.html)).
- **SQLite** : `.backup` dans un nouveau fichier (l'API de sauvegarde en ligne : « The online backup API allows the
  contents of one database to be copied into another », [sqlite.org/backup.html](https://www.sqlite.org/backup.html)),
  `PRAGMA integrity_check` de la copie ([pragma.html](https://www.sqlite.org/pragma.html#pragma_integrity_check)),
  `.restore` dans un nouveau fichier. SQLite ne garde pas d'historique : il ne peut pas restaurer jusqu'à un point.

| 10 M de faits | Cepheus | PostgreSQL 18.6 | SQLite 3.54 | qui gagne |
|---|---|---|---|---|
| la base | 104,7 Mo (journal 33,9, runs 70,8) | 284 Mo | 136,4 Mo | Cepheus |
| une sauvegarde, pendant qu'elle sert | **1,16 s** [0,995, 1,45], 104,7 Mo | 22,53 s [15,83, 32,68], 337,9 Mo | 1,46 s [1,14, 2,10], 136,4 Mo | Cepheus |
| la sauvegarde vérifiée | 565 ms [562, 579] | **95 ms** [92, 734] | 2,83 s [2,81, 2,83] | PostgreSQL |
| une restauration jusqu'à la fin | **1,61 s** [1,48, 1,93] | 6,45 s [5,93, 7,70] | 2,65 s [2,08, 3,50] | Cepheus |
| tout l'historique rejoué (11 tours) | 34,87 s [33,67, 36,19], depuis le journal seul (33,9 Mo) | **21,42 s** [12,89, 46,57], depuis une sauvegarde de base prise vide (48 Mo) et 403 Mo de WAL | aucune | PostgreSQL |
| jusqu'au milieu de l'historique (pas le même travail) | 32,62 s [31,48, 35,56], 9,43 M de faits rejoués | 21,71 s [16,92, 35,40], la moitié du WAL du chargement rejouée | aucune | |

![Trois barres par ligne, Cepheus en bleu, PostgreSQL en orange, SQLite en vert, chaque ligne à sa propre échelle : la taille de la base, 104,7, 284 et 136,4 Mo ; une sauvegarde en service, 1,16, 22,53 et 1,46 s ; la sauvegarde vérifiée, 565 ms, 95 ms et 2,83 s ; une restauration jusqu'au bout, 1,61, 6,45 et 2,65 s ; tout l'historique rejoué, 34,87 et 21,42 s, SQLite ne gardant pas d'historique.](images/bench-backup.svg)

Tout l'historique rejoué est le même travail des deux côtés : Cepheus restaure une copie dont on a retiré les runs (le
journal seul, chaque groupe rejoué : `bench/ops.sh cepheus-replay`), PostgreSQL se restaure depuis la sauvegarde de
base prise avant le chargement jusqu'à la fin du WAL archivé (`bench/ops.sh pg-replay` ; les 2 272 720 factures y sont).
« Le milieu » ne l'est pas : le groupe du milieu de Cepheus vient après chaque client et chaque facture (9,43 M de
faits, les liens de suivi après lui), alors que le LSN (la position dans le WAL) du milieu de PostgreSQL est à la
moitié des octets de son WAL.

- **Là où Cepheus gagne.** Sa sauvegarde est une copie des fichiers tels qu'ils sont (le journal et les runs sont écrits
  une fois et jamais changés), vérifiée : 19 fois plus rapide que `pg_basebackup`, dont le temps est son checkpoint (le
  moment où il force toutes ses pages sur le disque) et la copie de 338 Mo de pages, et une copie 3,2 fois plus petite
  (les colonnes des runs codées par blocs, le journal compressé). Sa restauration jusqu'à la fin ouvre le run le plus
  récent et rejoue les 4 166 groupes d'après lui : 4 fois plus rapide que le démarrage de PostgreSQL sur une sauvegarde
  de base, qui refait son WAL depuis le checkpoint et force chaque page. Et une sauvegarde n'a besoin d'aucune archive
  de journaux : le journal de la copie tient chaque groupe, donc une restauration jusqu'à n'importe quel groupe n'a
  besoin que de la copie, alors que la restauration à un instant donné de PostgreSQL a besoin d'une sauvegarde de base
  plus ancienne que la cible et de chaque fichier de WAL depuis (1,1 Go archivés pendant les 21 tours).
- **Là où PostgreSQL gagne.** `pg_verifybackup` vérifie le CRC de chaque fichier contre le manifeste, 6 fois plus vite
  que `cepheus verify`, qui en plus décode et numérote chacun des 227 274 groupes et vérifie les tables de chaque run
  comme le fait une ouverture ; le journal tient ici en un seul segment, vérifié par un seul domain (les segments sont
  vérifiés en parallèle). Et sa restauration rejoue le WAL, un redo physique des pages, 1,6 fois plus vite que le rejeu
  de tout l'historique par Cepheus (médiane contre médiane ; l'intervalle de PostgreSQL est large, [12,89, 46,57] s,
  son checkpoint de fin de restauration forçant chaque page sur ce disque) : Cepheus rejoue 227 274 groupes l'un après
  l'autre, environ 287 000 faits par seconde, les fusionne dans des runs et les force comme le ferait l'écrivain. Les
  historiques diffèrent aussi : celui de PostgreSQL est un `COPY` en masse (quelques transactions), celui de Cepheus
  227 274 groupes des écritures d'une application. Le pas suivant pour Cepheus : rejouer des petits groupes consécutifs
  en un seul lot, par le chemin des grands groupes (des tableaux triés, sans mise à jour d'index par fait).
- **SQLite** copie son fichier à peu près aussi vite que Cepheus (1,46 s contre 1,16 s), mais le vérifie 5 fois plus
  lentement (`integrity_check` parcourt chaque page de ses b-trees) et ne garde pas d'historique pour en restaurer un
  point.
- Pas mesuré : les sauvegardes à froid (les copies lues depuis le disque, pas depuis le cache de pages), une sauvegarde
  sous des écritures, et une base plus grande que la mémoire.

## Les lectures de l'application de factures après un chargement, et le premier appel (2026-11-19)

**Méthode.** Le seed de l'application de factures (100 000 factures, 10 000 clients, 2,4 millions de lignes ;
[le guide](app.md#14-ce-que-cela-coûte)), ses questions posées comme l'application les pose, en OCaml seul sur la vue
locale de l'application (le côté Cesia et PostgreSQL sont dans le tableau du guide, 21 tours) ; le moteur d'avant cette
étape contre celui de cette étape, alternés, 21 tours de 1 000 appels chacun : la médiane des p50 des tours en µs, avec
son intervalle à 95 %, sur le seed fusionné en un seul run.

| question | avant | après | ce qui a changé |
|---|---:|---:|---|
| les clés d'une page triée (5 patterns, 21 lignes) | 38,9 [38,1 ; 38,9] | **23,8** [23,1 ; 24,1] | sa première fenêtre tient 21 faits, pas 42 |
| la page avec les champs de ses lignes | 63,2 [63,2 ; 64,1] | **47,0** [47,0 ; 47,9] | la même chose |
| les factures par un préfixe du nom du destinataire | 498 [497 ; 501] | **433** [431 ; 435] | les champs d'une ligne lus après le préfixe, une fois : 3 920 candidats → 2 288 |
| les clients par nom, avec leurs e-mails | 55,1 [55,1 ; 56,0] | **36,0** [36,0 ; 36,0] | chaque nom lu une fois par tri, pas à chaque comparaison |
| les clients par un préfixe du nom ou de l'e-mail | 657 [654 ; 659] | **396** [395 ; 397] | la marche abandonne après 2 fenêtres au lieu de 5, puis le heap (322 seul) |
| une facture, ses lignes | 8,1 | 8,1 | |

**Les runs qu'un chargement laisse.** Le seed tel que son chargement le laisse tient 5 runs côte à côte (le lazy
leveling, [merges](architecture.md#les-merges--un-log-structured-merge-tree-à-leveling)), et chaque recherche les
visite tous : sur le moteur d'avant, une série de 1 000 appels sur chacun, une page prenait 120 µs contre 64 sur les
mêmes faits en un seul run, le préfixe 1 088 contre 515, le total impayé 13,6 ms contre 8,4. Le serveur les fusionne
maintenant dès que son writer est au repos une seconde (les 2,4 millions de lignes en environ 0,65 s ici) ; le tableau
du guide mesure le tout (une page 180 → 115 µs par Cesia).

**Une journée de sessions dans le delta.** 10 000 connexions, chacune avec sa propre fin : un intervalle sur leurs fins
(la question du visiteur) est compté à partir des sommes de l'arbre du delta en $O(\log n)$ au lieu d'un pas par
session. Un processus qui se connecte les rejoue encore (sa première vue : 57,7 ms contre 55,6, 6 tours alternés, dans
leur dispersion) : un merge du delta d'un writer au repos retirerait ce rejeu, et n'est pas construit.

**Le premier appel.** Le premier appel du package Cesia (le fichier du moteur dont l'empreinte est vérifiée, puis
projeté en mémoire et relogé) : 22,30 ms contre 22,48, le rapport 0,990 [0,984 ; 0,994] (21 tours de 100 processus,
alternés) ; son fichier tient 24 KB de code de plus pour les lectures ci-dessus et 48 KB de moins depuis que sa colle
Cesia est compilée avec l'inlining par défaut du compilateur (l'inlining : le code d'une fonction recopié là où elle
est appelée). La commande `cepheus` sans argument : 4,58 ms contre 4,55, le rapport 1,004 [1,000 ; 1,013].

## Les questions avec des opérateurs, un ordre et des pages (2026-11-12), à 10 millions de faits

**Méthode.** Les données des autres benchmarks (10 M de faits : 113 636 clients et leurs 2 272 720 factures, dont
453 866 impayées), un seul run (un merge complet) ; le build release (compilé avec les optimisations) de cette
branche ; `bench.exe pages`, `RUNS` = 21, chacune un appel ; les médianes, et la plus petite des 21. L'« avant » de
chacune est ce qu'un programme devait faire sans l'opérateur, dans le même processus (sans réseau), si bien que le gain
montré est celui du moteur seul ; à travers le serveur, la réponse entière traverserait aussi le socket.

| question | avec l'opérateur | avant lui | |
|---|---:|---:|---|
| une page de 20 des 453 866 factures impayées, les plus gros totaux d'abord : chemin de l'index | 47,0 µs (min 44,1) | 698,6 ms (min 541,1) : la réponse entière, triée par le programme | 14 900 fois |
| la même page par le chemin du heap | 55,8 ms (min 48,4) | | |
| la page 101 (après la 2 000e ligne) : chemin de l'index / chemin du heap | 51,0 µs / 72,3 ms | | |
| la page, le chemin étant choisi | 51,0 µs (le chemin de l'index) | | |
| les 13 clients de city-7 sans facture impayée (`Not` de deux patterns) | 2,84 ms (min 2,70) | 3,10 ms (min 2,62) : deux questions et leur différence | le même |
| les 11 clients dont l'e-mail commence par c1234 (`Prefix`) | 10,0 µs (min 8,8) | 30,6 ms (min 26,7) : chaque e-mail, filtré | 3 050 fois |

- **La page.** Le chemin de l'index lit l'index des totaux du plus grand vers le bas, par fenêtres de 40, 80, ... faits,
  et répond à la question de chaque fenêtre ; le chemin du heap répond à la question entière (453 866 bindings) et en
  garde 20. Une page plus profonde coûte la même chose par l'un et par l'autre : la 101e, 51,0 µs contre 47,0. Le chemin
  du heap épargne tout de même le tri et la copie de la réponse entière (55,8 ms contre 698,6).
- **Not** fait une recherche par client de la ville (environ 1 140) : les clients d'une ville sont peu nombreux, et les
  deux questions d'avant coûtent à peu près autant ; son gain est une question au lieu de deux, et aucune réponse à
  garder pour la soustraction.
- **Prefix** lit les 11 e-mails qui correspondent dans l'ordre des textes, par deux recherches dichotomiques dans le
  run, au lieu de lire chacun des 113 636 e-mails.
- **Les questions d'avant** ne sont pas plus lentes : Q1 à Q5 du build de e333a31 contre celui-ci, sur les mêmes
  données (chacun avec un run de son propre format), en alternance, 3 tours de 21 exécutions (Q1 et Q2 : 6 de plus) :
  la plus petite de chacune, ancien / nouveau : Q1 0,38 / 0,36 µs, Q2 0,61 / 0,60 µs, Q3 2,93 / 3,04 ms, Q4 44,97 /
  43,20 ms, Q5 63,3 / 63,7 ms ; les médianes des tours vont dans les deux sens (Q5 115,4 / 85,5 ms, Q4 58,3 / 59,1 ms),
  sur une machine que d'autres travaux partageaient. Un premier build alourdissait le test de la plage d'un candidat et
  rendait Q5 10 % plus lente dans deux tours sur trois : le test d'une variable sans plage est redevenu celui qu'il
  était (un `In` ou un `Prefix` donne à sa variable une plage à elle).
- **Watches.** Un changement sous un watch de chaque opérateur, contre la question à laquelle on répond de nouveau en
  entier (`sbench.exe
  watches` : un hub par watch, 21 changements faits en mémoire, dont chacun change les lignes du watch ; médianes) :
  `Not` (les clients de city-7 sans facture impayée ; une facture de l'un d'eux rendue impayée, puis payée de nouveau)
  46 µs contre 3,45 ms ; `Or` (city-7 ou un e-mail ; un client qui déménage à city-7) 14,1 µs contre 104 µs ; `In`
  (city-7 ou city-8) 20,0 µs contre 223 µs ; `Prefix` (les e-mails qui commencent par c1234 ; l'un changé en un tel
  e-mail) 13,1 µs contre 17,9 µs, sa réponse entière étant de 11 lignes. Un changement coûte les réponses qu'il
  touche : la frame trouve les clients qu'atteint le fait, répond à la question pour eux avant et après, et envoie la
  différence.
- **Son coût.** L'ordre des textes ajoute 4 octets par texte distinct à un run : le run de 10 M de faits fait 68 MB
  contre 67 MB au format 8. Un merge complet de la base : 2,3 s. La première ouverture de données au format 8 met ses
  runs de côté et rejoue le journal : 5,9 s, une seule fois.

## Les lectures de l'ouverture dans l'ordre du fichier (2026-11-12), à 10 millions de faits

La base de 10 millions de faits chargée en 4 grands groupes (`GROUP=56818`, un thread), puis `snapshot` : un run de
69,6 MB (4 212 pages du fichier). Avec un cache de 32 MB, le run n'y tient pas, et l'ouverture vérifie ses tables :
327 pages (5,4 MB) en 229 plages contiguës du fichier. Avant, les vérifications les lisaient une par une, à mesure
qu'elles y arrivaient ; maintenant elles sont lues d'abord, dans l'ordre du fichier, les pages qui se suivent dans le
fichier en une seule lecture, par 4 domains. Un run qui tient dans le cache (1 GiB par défaut) est lu en entier de la
même façon. L'ouverture de `bench.exe read` (`CEPHEUS_DOMAINS=1`, un scope de 128 MB pour le cache de 32 MB, de 3 GB
pour 1 GiB), à froid : les pages des fichiers d'abord retirées du cache du système ; 21 tours, les deux binaires à tour
de rôle ; les médianes avec leur intervalle à 95 %, et la médiane des rapports de chaque tour :

| ouverture | avant (3f8d8e8) | après | après / avant | après plus rapide |
|---|---|---|---|---|
| cache de 32 MB, à froid | 126,1 ms [120,5 ; 129,6] | **70,0 ms** [69,3 ; 71,0] | 0,570 [0,544 ; 0,593] | 21/21 |
| cache de 32 MB, à chaud | 18,6 ms [17,8 ; 20,0] | **17,4 ms** [16,9 ; 17,7] | 0,933 [0,914 ; 0,994] | 16/21 |
| cache de 1 GiB, le run lu en entier (50 à 53 MB lus sur le disque) | 199,5 ms [190,4 ; 208,2] | **169,4 ms** [167,9 ; 171,5] | 0,858 [0,806 ; 0,895] | 21/21 |

Le disque lit 16,7 à 19,7 MB pour les 5,4 MB dont l'ouverture à froid a besoin : c'est le read-ahead du système (la
lecture anticipée des pages qui suivent). Les dommages sont trouvés là où ils l'étaient : chaque page que lit
l'ouverture est vérifiée par son CRC avant d'entrer dans le cache, et les vérifications sont les mêmes ; une page
endommagée parmi les tables met maintenant le run de côté même là où les vérifications n'auraient pas regardé ses
octets (les 12 bits inversés des tests unitaires : 1 refusé à l'ouverture et 11 trouvés à une lecture, contre 0 et 12).

## Les chargements par morceaux (2026-11-12), à 10 millions de faits

Un chargement écrit en groupes de 5 000 clients (environ 415 000 faits par groupe, 23 groupes de clients et 23 de
leurs follows) par deux threads (`bench.exe load` avec `GROUP=5000 THREADS=2 CACHE_MB=64`), puis `snapshot`, contre
main d'avant le changement (du leveling pour les grands groupes, c'est-à-dire chaque run fusionné avec le run unique de
son niveau, et un merge qui regardait la tête de chaque source pour chaque ligne), $n = 7$ tours alternés, chaque
exécution sur une machine calme (pression d'IO et de CPU sous 5 et 10 %), dans un scope de 3 GB ; la médiane et son
intervalle, ici la plus petite et la plus grande exécution (98,4 %) :

| | avant | après |
|---|---:|---:|
| chaque groupe confirmé, s | 18,17 [15,26 ; 27,21] | 9,81 [8,09 ; 11,37] |
| dont les groupes des clients, s | 10,37 [9,39 ; 11,78] | 6,44 [5,69 ; 8,62] |
| dont leurs follows, s | 6,40 [5,87 ; 16,02] | 2,82 [2,27 ; 4,24] |
| un grand groupe fusionné dans son run, p50, ms | 122 [119 ; 142] | 62 [62 ; 64] |
| le plus long d'entre eux, ms | 2 111 [2 061 ; 9 599] | 1 601 [1 541 ; 1 775] |
| runs avant le snapshot | 2 | 15 |
| `snapshot`, s | 2,38 [1,98 ; 5,09] | 3,18 [2,81 ; 3,59] |
| chargement et snapshot, s | 21,87 [17,24 ; 29,38] | 12,99 [11,29 ; 14,40] |
| pic de mémoire résidente, MB | 270 [252 ; 281] | 292 [258 ; 306] |

Les groupes sont confirmés 1,9 fois plus vite : le run de chaque groupe est écrit une seule fois, à côté des autres,
au lieu d'être fusionné de nouveau avec les runs d'avant lui, niveau après niveau ; le 16e groupe fusionne le tier (les
runs gardés côte à côte dans un niveau) en une seule passe (le plus grand merge, 1,6 s). Le snapshot fusionne alors
15 runs au lieu de 2 et prend 0,8 s de plus, ce que le heap de curseurs (un curseur par run, qui avance dans ses
lignes ; le heap donne à chaque pas la plus petite de leurs têtes) garde petit (avant lui, le snapshot de 15 runs des
premiers tours prenait 6,2 s). Le pic augmente de 22 MB (les tables des 15 runs gardées en mémoire, très probablement ;
pas mesuré à part). Les lectures entre le chargement et son snapshot visitent chaque run : à 1 million de faits chargés
de la même façon (8 runs contre 2, $n = 3$), un client par e-mail 1,40 µs contre 0,73, les factures impayées d'une
ville 763 µs contre 425 ; les mêmes réponses des deux côtés, et chaque binaire ouvre et lit la base de l'autre.

Pas atteint, de l'étape 4 du plan : un pic de 150 MB quelle que soit la taille du chargement (292 MB ici : les listes
d'opérations en vol des deux groupes, environ 70 MB chacune, le cache de 64 MB, et les tableaux compacts d'un groupe),
et 10 millions de faits en 3 s (chaque groupe de 415 000 faits paie sa propre résolution, son merge et son fsync :
46 frames ; les mêmes 10 millions de faits en deux groupes se chargent en 4,1 à 5,6 s, avec un pic de 1,46 GB :
[api](api.md#écrire)).

Les mêmes 10 millions de faits en 4 grands groupes (`GROUP=56818`, un thread), puis `snapshot`, $n = 5$ alternés :
chaque groupe confirmé en 5,12 s [4,28 ; 6,95] contre 5,93 [5,58 ; 6,98], un pic de 862 MB [808 ; 967] contre 987
[929 ; 1 006] ; le snapshot fusionne les runs des 4 groupes au lieu de 2 et prend 2,52 s [2,30 ; 2,71] contre 2,14
[2,01 ; 2,29]. Une ouverture de la base qu'il laisse, ses pages retirées du cache du système, avec un cache de 32 MB
($n = 7$) : 124 ms [113 ; 133] contre 129 [110 ; 166], en lisant 16,7 MB des deux côtés ; 19,7 et 19,3 ms quand le
cache du système les tient, si bien que la plus grande part d'une ouverture à froid est la latence du disque sur les
pages des tables, lues une à une. Ni le coût du troisième ordre dans le snapshot ni l'ouverture à froid n'ont changé
avec ce travail.

## Les questions vivantes (2026-11-11), à 1 million de faits

`cepheus.Watch` et `Watch` dans le protocole, contre main d'avant eux (le commit du column order), sur la base de 1 M de
faits du serveur, chaque côté sur un serveur démarré de la même copie de celle-ci, $n = 7$ tours alternés (la méthode
plus haut). Les tableaux entiers sont dans [serveur](server.md#ce-que-coûte-un-watch) et
[Cesia](cesia.md#ce-que-cela-coûte).

| | avant | après | le rapport dans chaque tour, après / avant |
|---|---:|---:|---:|
| le démarrage du serveur (prêt), ms | 174 [122 ; 847] | 143 [126 ; 178] | 0,91 [0,15 ; 1,09] |
| un round trip à vide (Ping), µs | 8,86 [7,55 ; 11,13] | 9,40 [7,93 ; 11,47] | 0,93 [0,76 ; 1,50] |
| une lecture d'un point au serveur (Get), µs | 8,79 [7,64 ; 12,27] | 8,85 [7,70 ; 9,49] | 1,00 [0,64 ; 1,16] |

Un programme qui utilise le package sans l'appeler (`cesia run` de `io.Print(1)` avec le `use` du package, $n = 51$
exécutions alternées) : 3,53 ms [3,48 ; 3,59] avant, 3,66 [3,60 ; 3,75] après : le code Cesia du package a 41 lignes de
plus (`Watch` et le `Close` d'un watch), que Cesia lit et compile au démarrage, 0,13 ms de plus. Le moteur ne se charge
toujours qu'au premier appel.

Rien de ce qui existait avant ne coûte plus. Ce qui est nouveau : un changement atteint un programme 16 µs après le
reçu de son écriture au serveur, et avant le reçu dans le follower du programme ; un groupe coûte au hub (le thread qui
calcule les questions vivantes d'une base) 12,2 µs à 10 000 écrans qui suivent une question et un tableau de bord ; une
connexion qui ne lit jamais ne retient personne ; 100 watches ne coûtent rien de mesurable à 16 writers, là où le
`NOTIFY` de PostgreSQL les divise par 8,6 ; un programme Cesia donne un changement à 10 000 fibers en 90 ms (la
dernière).

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

**Ce qui a empiré.** Le run grossit de 15,2 MB (13,9 MB de column order : valeurs 11,4, rank tables 1,2, répertoires
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
du column order que fait l'ouverture (rank tables, répertoires : 2,5 MB) lisent des pages que l'ouverture de main ne
lisait pas (les premières questions les liraient de toute façon).

**Où les géants gagnent encore.** SQLite charge avec 11 MB de mémoire, contre 1,6 GB pour Cepheus (les chargements par
morceaux sont venus le lendemain : [plus haut](#les-chargements-par-morceaux-2026-11-12-à-10-millions-de-faits)). Son
ouverture à froid est l'ouverture d'un fichier. PostgreSQL ne gagne plus aucune question ici ; c'est un serveur avec ses
propres processus, ce que les chiffres de Cepheus ci-dessus ne comprennent pas (le serveur de Cepheus est mesuré dans
[le serveur](server.md)).

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
touchent au hasard les 23,5 MB de blocs de choses. La lecture de Q5 dans les lignes par propriété, où les 568 163 liens
follow sont rangés ensemble, est venue deux jours plus tard avec le column order et un join qui les parcourt ([plus
haut](#le-column-order-et-les-intersections-en-leapfrog-2026-11-11-à-10-millions-de-faits)).

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

## Règles, les cibles de l'étape 5 encore : l'installation d'un changement sans un record par fait (2026-11-19)

Le levier que montraient les mesures plus bas ([règles](rules.md#les-changements-des-règles-en-arrière-plan)) : à
l'installation, chaque fait dérivé du run devenait un record de changement (l'enregistrement OCaml d'un changement) et
une valeur, faits par le writer, puis codés pour la frame (`Group.encode` : une recherche dans une table de hachage par
changement pour sa colonne), pendant qu'aucun groupe n'était confirmé. Maintenant le writer code la frame directement
depuis les colonnes du run (`Group.encode_parts` : les records du groupe, puis les faits du run lus par indice), les
mêmes octets, ses quatre colonnes (les sortes, les choses, les colonnes, les valeurs) sur plusieurs domains au-delà de
65 536 changements ; les watches (les questions suivies en direct), qui ont besoin des changements un par un, font les
records du run sur leur propre domain (`Engine.whole`). Et ce que le profil montrait ensuite : le writer installe un
changement prêt avant son batch suivant (le batch s'arrête à lui, pour que le dernier rattrapage de l'installation ne
tienne que les groupes du dernier passage de l'arrière-plan, pas jusqu'à 256 de plus), et attend la fin du domain du
changement (`Domain.join`) après l'installation ; les programmes du raisonneur pour un nouveau jeu de règles sont faits
hors du verrou que chaque groupe du writer prend un instant (les 95 règles d'un changement prenaient 15 à 22 ms à
compiler et à déplier sous ce verrou, que le writer attendait) ; et le codeur des colonnes du journal remplit un bloc et
trouve ses deux étendues en une seule passe, et serre les champs d'au plus 31 bits par un mot courant (135 000 valeurs :
0,92 à 0,69 ms constantes, 1,28 à 1,03 croissantes, 1,45 à 1,25 aléatoires ; les mêmes octets, ce qu'un test vérifie
contre le codeur simple du format).

**Où allait l'installation** (main a61dd80, avec des chronomètres, 5 exécutions sur le disque) : les groupes écrits
depuis que le changement était prêt, rattrapés, 6 à 10 ms (102 à 224 groupes) ; les faits du run faits records, 9 à
11 ms ; réunis en un seul tableau, 1,5 à 3 ; codés, 15 à 27 : 35 à 48 ms, 2,0 à 2,8 M de mots alloués, 9 à 13
collections mineures du garbage collector. **Où elle va maintenant** (8 exécutions) : le rattrapage, 0 groupe dans
quatre exécutions et 90 à 188 (5 à 11 ms) dans les quatre autres, les groupes venus pendant le dernier passage de
l'arrière-plan (ses seuils, 64 groupes ou 5 ms, inchangés : un seuil plus serré pourrait empêcher un arrière-plan chargé
d'être jamais prêt) ; les records de la part affirmée et de la table, 0,3 à 1 ms ; le codage, 6 à 14 ms (une fois 26) à
côté de 256 writers (seul, sur une machine calme, de la forme de l'installation : 4,3 ms sur quatre domains, 5,8 ms sur
un ; l'essentiel du reste est la numérotation des colonnes et des textes dans l'ordre de leur premier usage et le tri
des valeurs par colonne, sur un seul domain) ; du changement prêt à son installation, 0 à 2 ms (jusqu'à 17 avant). La
frame elle-même est petite (35 à 41 KB pour 131 000 à 144 000 faits : les écarts entre choses, une colonne, une valeur),
donc son écriture et son fsync (l'appel qui force les octets sur le disque) sont ceux d'une frame ordinaire.

**Méthode.** Le même changement que plus bas, `CHANGE=one reason.exe change 10 256 8 2 with|without DIR`, 21 paires
(avec, sans) pour main a61dd80 et cette branche, alternées, en une seule prise du lock des travaux lourds, chaque
exécution dans un scope de 3 GB, deux fois : sur le disque, et dans un dossier tmpfs (`/dev/shm`, un système de
fichiers en mémoire), où un fsync n'attend rien, pour qu'aucun arrêt du disque n'entre dans la mesure et que les writers
soient limités par le processeur (environ 13 000 groupes par seconde, contre 9 000 à 11 000 sur le disque). Sur le
disque, le fsync du journal s'arrête 0,1 à 0,5 s une ou deux fois par exécution (btrfs plein à 99 %, partagé avec les
écritures d'autres travaux ; les exécutions chronométrées ont noté chaque fsync de plus de 100 ms), dans les exécutions
avec et sans le changement de la même façon, ce qui faisait aller le rapport d'une paire dans la fenêtre de 0,03 à 18
dans la série plus bas. Alors, à côté du rapport par paire (la fenêtre du changement avec / la même fenêtre sans), chaque
fenêtre est mise face à la **médiane** de toutes les fenêtres de même longueur de l'exécution sans le changement (de 1 s
à 7,5 s, glissant de 10 ms), qu'un arrêt ne peut pas déplacer ; le temps de writer perdu est les groupes de cette
médiane moins ceux de la fenêtre, à son débit ; la mesure entière est la fenêtre médiane de 250 ms depuis le début du
changement, avec / sans, et $1 - \text{perdu} / \text{temps}$, la perte de la fenêtre sur les 6 s qui suivent son
début. Une case est la médiane sur les paires avec son intervalle à 95 % sans hypothèse de loi ($[x(6), x(16)]$ sur
21).

| ce qui est mesuré (21 paires) | main, disque | cette branche, disque | main, tmpfs | cette branche, tmpfs |
|---|---:|---:|---:|---:|
| la part du writer à l'installation | 33 ms [28, 38] | **10 ms** [8, 15] | 41 ms [37, 43] | **21 ms** [17, 24] |
| le changement, de `define` à sa réponse | 0,213 s [0,174, 0,246] | 0,221 s [0,160, 0,288] | 0,545 s [0,499, 0,649] | 0,581 s [0,527, 0,646] |
| sa construction (environ 135 000 faits dérivés) | 0,050 s [0,045, 0,056] | 0,048 s [0,043, 0,054] | 0,055 s [0,051, 0,059] | 0,056 s [0,050, 0,060] |
| son run à lui | 0,026 s [0,023, 0,029] | 0,025 s [0,024, 0,027] | 0,031 s [0,029, 0,035] | 0,030 s [0,029, 0,033] |
| faits dérivés par seconde, la construction et le run | 1,82 M [1,64, 1,89] | 1,84 M [1,72, 1,90] | 1,77 M [1,72, 1,86] | 1,78 M [1,71, 1,88] |
| les writers dans la fenêtre, par paire | 0,72 [0,49, 0,93] | 0,65 [0,25, 1,46] | 0,77 [0,75, 0,80] | **0,83** [0,81, 0,87] |
| les writers dans la fenêtre, face à la fenêtre médiane | 0,67 [0,49, 0,83] | 0,75 [0,31, 1,05] | 0,84 [0,81, 0,87] | **0,92** [0,88, 0,94] |
| le temps de writer perdu dans la fenêtre | 83 ms [37, 102] | 40 ms [-14, 109] | 97 ms [68, 119] | **49 ms** [35, 78] |
| toute la mesure, par paire | 0,89 [0,71, 1,15] | 0,87 [0,74, 1,02] | 0,92 [0,91, 0,93] | 0,91 [0,90, 0,93] |
| toute la mesure, face à la fenêtre médiane | 0,93 [0,72, 1,09] | 0,95 [0,82, 1,02] | 0,92 [0,91, 0,97] | 0,92 [0,91, 0,95] |
| toute la mesure, $1 - \text{perdu} / \text{temps}$ | 0,986 [0,983, 0,994] | 0,993 [0,982, 1,002] | 0,984 [0,980, 0,989] | **0,992** [0,987, 0,994] |

- **Comment le lire.** Dans tmpfs, sans arrêt (aucun de 250 ms dans aucune fenêtre, contre 3 à 5 sur le disque), les
  intervalles sont étroits : les writers perdent moitié moins dans la fenêtre du changement que sur main (49 ms contre
  97), son rapport par paire passe de 0,77 à 0,83. Le rapport face à la fenêtre médiane se lit plus haut (0,92) parce
  que le débit d'une exécution baisse au fil de ses 8 s à mesure que son delta grandit (14 000 groupes par seconde au
  début, 12 000 à la fin), donc la médiane de [1, 7,5] s est sous le débit à 2 s ; sans arrêt, le rapport par paire est
  le juste. Sur le disque les arrêts décident encore d'une paire, mais les médianes s'accordent : 40 ms perdues contre
  83. Sur toute la mesure, les deux binaires se ressemblent dans tmpfs, 0,91 à 0,92 : après le changement, chaque
  étudiant écrit dérive un fait de plus sous 95 règles au lieu de 94, environ 8 % de travail de plus pour le writer à
  chaque groupe suivant, ce que cachent les fsyncs du disque (0,95 là) ; le coût propre du changement, le temps perdu de
  la fenêtre sur la mesure, est sous 1 % (0,992).
- **Face aux cibles de l'étape** : les writers dans la fenêtre du changement à 0,90 d'une exécution sans lui : **0,92
  face à la fenêtre médiane dans tmpfs**, 0,83 par paire (manqué ; main 0,84 et 0,77) ; sur toute la mesure à 0,96 :
  0,992 pour la perte propre du changement, 0,91 à 0,95 avec le travail que la nouvelle règle ajoute à chaque écriture
  suivante (manqué : cette part est celle de la règle, pas de l'installation) ; 2 M de faits dérivés par seconde avec
  l'écriture du run : 1,84 M (manqué : la construction fait 2,87 M par seconde, l'écriture du run de 135 000 faits prend
  25 ms sur 73).
- **La deuxième piste** (le dépliage des nouvelles règles, qui revérifiait les types statiques pour chaque liaison) :
  la construction bouge de 2 ms au plus (0,050 et 0,048 s, dans les intervalles) : les types n'étaient pas l'essentiel
  du dépliage ici ; ce qui reste des 15 à 22 ms des programmes est le reste du travail du dépliage et ses vérifications
  d'atteignabilité.
- **Les mêmes faits dérivés** (sans writer, pour que les deux exécutions soient les mêmes ; chaque base ensuite lue en
  entier par un seul binaire) : l'axiome sur LUBM-10, 2 006 283 faits dont 651 629 dérivés, digest `3d3ea1921e042` des
  deux côtés ; les 94 règles définies sur LUBM-1 sans règles, 210 869 faits dont 60 526 dérivés, `67123592f6fa` des deux
  côtés. Sans writer, la construction de l'axiome prend 0,022 s et son run 0,018 à 0,019 s des deux côtés (119 424 faits
  dérivés : 2,9 M par seconde avec l'écriture du run), son installation 21 ms sur main et 6 ms ici ; l'installation des
  94 règles 14 et 6 ms ; `define 1` (les 94 règles sur un fork) 0,199 et 0,197 s.
- **Démarrage** (21 tours de 100 exécutions, alternés, chaque binaire en 7 copies prises à tour de rôle) :
  `bench.exe` 2,575 ms sur main, 2,564 ms ici (rapport par paire 1,001 [0,970, 1,005]) ; `cepheus` (`bin/main.exe`)
  4,577 ms et 4,604 ms (1,005 [0,993, 1,012]) : aucun changement mesuré (les deux intervalles contiennent 1).

## Règles, les cibles de l'étape 5 encore : les faits qu'aucune règle ne lit, faits par un seul tri (2026-11-18)

Le levier que montraient les mesures plus bas ([règles](rules.md#les-changements-des-règles-en-arrière-plan)) : un
changement garde les têtes de ses **sinks** (les règles dont aucune règle ne lit les faits) dans un buffer, les trie une
fois à la fin de son raisonnement (une fusion des quelques suites croissantes dans lesquelles elles arrivent, un radix
sort au-delà de 64), garde le premier de chaque fait, met de côté ceux que la vue ou le working set tiennent, et écrit
les autres dans sa sortie dans l'ordre des choses, jamais dans le working set.

**Où allait la construction de main** (main 5de6b66, avec des chronomètres, le même changement que ci-dessous, 3
exécutions) : 0,13 à 0,20 s = les programmes 0,015 à 0,020, les instances de la règle ajoutée 0,096 à 0,149 (dont la
seule lecture des faits de la vue 0,016 : le reste, environ 0,8 µs par tête, c'est mettre chaque tête dans le working
set : une recherche, sa place, trois chaînes, la croissance des tables par doublement), les faits dérivés mis de côté
0,008 à 0,014 (une recherche dans le delta par fait), le reste sous 0,01 ; son run à lui 0,023 à 0,036 (un tri quand
les têtes n'arrivaient pas dans l'ordre des choses, 0,001 à 0,012). **Où elle va maintenant** (les mêmes
chronomètres) : les instances lisent 0,014 à 0,017, leurs têtes gardées 0,005 à 0,010, triées 0,0003 à 0,0024 (une
exécution à 0,008), faites faits 0,0015 à 0,0023, mises de côté 0,0012 à 0,0020 (une recherche dans le delta par
(propriété, valeur)) ; les programmes 0,014 à 0,024, presque tout pour les règles dépliées sur les petites relations, pour les
groupes suivants du writer (le dépliage 0,008 à 0,013, ses vérifications 0,004 à 0,009) ; le run à lui 0,020 à 0,029
(aucun tri : les faits arrivent triés ; l'écriture du merge 0,017 à 0,025).

**Méthode.** Comme plus bas : `CHANGE=one reason.exe change 10 256 8 2 with|without DIR`, la règle `[x type Person]
-> [x type Schedule]` définie sur LUBM-10 avec les 94 règles sur le disque pendant que 256 clients écrivent des
étudiants de façon durable ; 21 paires (avec, sans) pour main 5de6b66 et pour cette branche, alternées, en une seule
prise du lock des travaux lourds, chaque exécution dans un scope de 3 GB. Une case est la médiane avec
$[x(1), x(n)]$.

| ce qui est mesuré (21 paires) | main 5de6b66 | cette branche |
|---|---:|---:|
| le changement, de `define` à sa réponse | 0,543 s [0,315, 0,905] | **0,311 s** [0,164, 2,83] |
| sa construction (environ 135 000 faits dérivés) | 0,168 s [0,093, 0,209] | **0,053 s** [0,032, 0,070] |
| son run à lui : écrit, non forcé | 0,033 s [0,021, 0,044] | **0,025 s** [0,020, 0,032] |
| faits dérivés par seconde, la construction | 0,80 M [0,67, 1,30] | **2,57 M** [1,97, 3,77] |
| faits dérivés par seconde, la construction et le run | 0,67 M [0,58, 1,06] | **1,73 M** [1,44, 2,32] |
| la part du writer à l'installation | 32 ms [21, 61] | 36 ms [23, 51] |
| le débit des clients dans la fenêtre du changement, avec / sans | 0,93 [0,06, 18,7] | 0,50 [0,03, 1,00] |
| la même chose sur toute la mesure depuis le début du changement | 0,96 [0,77, 2,34] | 0,93 [0,11, 5,43] |

- **Les mêmes faits dérivés** (sans writer, pour que les deux exécutions soient les mêmes ; chaque base ensuite lue en
  entier par un seul binaire) : l'axiome sur LUBM-10, 2 006 283 faits dont 651 629 dérivés, digest `3d3ea1921e042` des
  deux côtés ; les 94 règles définies sur LUBM-1 sans règles, 210 869 faits dont 60 526 dérivés, `67123592f6fa` des deux
  côtés. Sans writer, la construction de l'axiome prend 0,086 s sur main et 0,024 s ici (119 424 faits dérivés : 1,4 M
  et 5,0 M par seconde ; 1,1 M et 2,8 M avec l'écriture du run).
- **Des changements avec peu de sinks** (11 paires, alternées) : les 94 règles définies sur un fork de LUBM-1
  (`reason.exe define 1`, ses tours sur plusieurs domains), 0,230 s sur main et 0,210 s ici (rapport par paire 0,97
  [0,69, 1,22]) ; les mêmes règles par le chemin en arrière-plan sans writer (`CHANGE=all ... change 1 0 2 1`),
  construction 0,105 et 0,104 s : aucun changement. Un tour sur plusieurs domains fait des têtes d'un sink des faits
  par régions du working set, comme avant : poussées et triées sur un seul domain, la définition sur un fork n'allait
  pas plus vite (1,03 [0,86, 1,94]).
- **Face aux cibles de l'étape** : 2 M de faits dérivés par seconde : **2,57 M pour la construction** (1,97 au
  moins), 1,73 M avec l'écriture de son run (manqué ; 2,32 au mieux) ; les writers à moins de 10 % de leur débit sans
  le changement : manqué, 0,50 dans la fenêtre du changement et 0,93 sur toute la mesure depuis son début (main 0,93 et
  0,96 dans cette série). La fenêtre fait maintenant 0,2 à 0,3 s, et elle contient l'installation : la part du writer
  lui-même (36 ms) et la frame du changement, 135 000 faits dérivés écrits et forcés (fsync), environ 40 à 60 ms sans
  aucun groupe confirmé (les tranches de 10 ms le montrent). Le rapport de main dans la fenêtre est la médiane de paires
  aussi éloignées que 0,06 et 18,7 : dans cinq de ses 21 paires, l'exécution sans le changement s'est arrêtée dans la
  fenêtre (des rapports de 4,7 à 18,7), comme le fait le switch d'un merge (aucun merge ne tourne à côté d'un
  changement), ce qu'une fenêtre de 0,5 à 0,7 s contient plus souvent. Les leviers suivants : la frame de l'installation (chaque fait de R y devient un enregistrement de
  changement et une valeur, alloués par le writer, puis encodés), et, dans la construction, le dépliage des nouvelles
  règles sur les petites relations.
- **Démarrage** (21 tours de 100 exécutions, alternés, chaque binaire en 7 copies prises à tour de rôle) :
  `bench.exe` 2,664 ms sur main, 2,688 ms ici (rapport par paire 0,999 [0,983, 1,020]) ; `cepheus` (`bin/main.exe`)
  4,779 ms et 4,711 ms (0,986 [0,981, 0,993]) : il ne grandit pas.
- **Face aux géants** (leurs articles ; le tableau de l'étape 3) : RDFox 2014 [Motik 2014] dérive 0,67 M de faits par
  seconde sur un thread et 6,1 à 7,0 M sur 16 à 32 threads de deux Xeon à 8 cœurs ; la construction de ce changement, 2,6 M par seconde sur
  un seul domain à côté de 256 writers durables, fait environ quatre fois le débit de RDFox sur un thread, et moins que
  son débit parallèle ; avec l'écriture du run, 1,7 M.

## Règles, les cibles de l'étape 5 : les faits dérivés d'un changement dans un run à eux (2026-11-18)

Le reste de l'étape 5 ([règles](rules.md#les-changements-des-règles-en-arrière-plan)) : un grand changement des règles
écrit les faits dérivés qu'il ajoute comme un run à eux, provisoire, sous le delta de sa vue, au lieu de les mettre dans
le delta un par un ; le rattrapage ne les tient dans sa table des différences qu'une fois qu'un groupe écrit pendant ce
temps les touche.

**Méthode.** Celle de l'étape 5 ([plus bas](#règles-étape-5--les-changements-des-règles-en-arrière-plan-2026-11-13)) :
`CHANGE=one reason.exe change 10 256 8 2 with|without DIR` (build release), la règle `[x type Person] -> [x type
Schedule]` définie sur LUBM-10 avec les 94 règles sur le disque (1,89 M de faits) pendant que 256 clients écrivent des
étudiants (GraduateStudent) de façon durable ; 21 paires (avec, sans) pour main 8445b4a et pour cette branche,
alternées, en une seule prise du lock des travaux lourds, chaque exécution dans un scope de 3 GB. Une case est la
médiane avec $[x(1), x(n)]$ ; un débit est le nombre de faits dérivés du changement sur sa construction (et sur sa
construction et l'écriture de son run) ; un rapport de débit est celui d'une paire.

| ce qui est mesuré (21 paires) | main 8445b4a | cette branche |
|---|---:|---:|
| le changement, de `define` à sa réponse | 1,54 s [0,66 ; 12,5] | **0,60 s** [0,34 ; 1,45] |
| sa construction (environ 140 000 faits dérivés) | 0,308 s [0,233 ; 0,433] | **0,159 s** [0,088 ; 0,206] |
| son run à lui : trié et écrit, sans fsync | | 0,033 s [0,020 ; 0,042] |
| faits dérivés par seconde, la construction | 0,45 M [0,35 ; 0,52] | **0,86 M** [0,69 ; 1,38] |
| faits dérivés par seconde, la construction et le run | 0,45 M [0,35 ; 0,52] | **0,72 M** [0,58 ; 1,12] |
| la part du writer à l'installation | 53 ms [37 ; 74] | **34 ms** [20 ; 42] |
| le débit des clients dans la fenêtre du changement, avec / sans | 0,61 [0,001 ; 1,09] | **0,87** [0,05 ; 5042] |
| la même chose sur toute l'exécution depuis le début du changement | 0,76 [0,001 ; 3,18] | **0,78** [0,44 ; 2,17] |

Où va la construction de main (une exécution avec des chronomètres) : 0,32 s = les programmes 0,015, les instances de la
règle ajoutée 0,096, la liste des faits dérivés 0,029, leur entrée dans le delta 0,149, les vérifications 0,020. Le run
à eux remplace la part du delta par son tri et son écriture (0,03 s), et les vérifications après les tours ne relisent
plus que les faits des propriétés à une seule valeur ou uniques.

**Une variante : l'arrière-plan sur plusieurs domains** (les instances de la règle ajoutée en morsels sur chaque thread,
comme dans les propres groupes du writer ; 21 paires contre cette branche, la même méthode) : la même construction
(0,168 s des deux côtés), et le débit des clients plus bas à côté (0,50 dans la fenêtre du changement et 0,84 sur
l'exécution, contre 0,83 et 0,86). Une règle d'un seul atome a peu de travail de join à partager, et ses têtes
deviennent des faits par un seul domain dans les deux cas : l'arrière-plan reste sur son propre domain, comme l'étape 5
l'avait trouvé.

- **Contre les cibles de l'étape** : 2 M de faits dérivés par seconde sur 8 threads : 0,72 M avec l'écriture du run,
  0,86 M pour la construction seule (manqué : le changement raisonne sur son propre domain, et ses tours lisent la vue
  fait par fait) ; les clients à 10 % près de leur débit sans le changement : 0,87 dans la fenêtre du changement (manqué
  ; 0,61 sur main), 0,78 sur l'exécution depuis son début (manqué ; 0,76 sur main ; une autre série de 21 paires du même
  code, le même jour, a donné 0,83 et 0,86). La fenêtre est courte maintenant (0,34 à 1,45 s), et un seul arrêt d'un
  côté d'une paire déplace beaucoup son rapport.
- **Le démarrage** (21 tours de 100 exécutions, alternés, chaque binaire en 7 copies prises à tour de rôle) :
  `bench.exe` 2,996 ms sur main, 2,998 ms ici (apparié 1,000 [0,984 ; 1,008]) ; `cepheus` (`bin/main.exe`) 4,899 ms et
  4,922 ms (apparié 1,007 [0,992 ; 1,021]) : aucun changement mesuré (les deux intervalles contiennent 1).
- **À côté des géants** (leurs articles ; le tableau de l'étape 3) : RDFox 2014 [Motik 2014] dérive 0,67 M de faits par
  seconde sur un thread et 6,1 à 7,0 M sur 16 à 32 threads de deux Xeon à 8 cœurs ; les 0,72 M par seconde de ce
  changement, sur un seul domain à côté de 256 clients qui écrivent de façon durable, sont environ le débit de RDFox sur
  un thread, loin en dessous de son débit en parallèle.

## Règles, étape 6 : OWL 2 RL, et l'égalité par réécriture (2026-11-14)

La sixième étape du reasoner (la partie du writer qui déduit des faits nouveaux à partir des règles)
([règles](rules.md#owl-2-rl-une-bibliothèque-de-règles)) : OWL 2 RL (la partie d'OWL 2, le langage d'ontologies du W3C, que
des règles calculent entièrement) comme bibliothèque de règles (`Cepheus.Owl` : son vocabulaire, chaque règle des
tables du W3C, des templates sur des listes, c'est-à-dire des règles écrites une fois pour chaque membre d'une liste),
et l'égalité (owl:sameAs) par des classes de choses égales (les choses que les règles rendent identiques, dont un seul
membre, le représentant, tient les faits) et la réécriture de leurs faits.

**Méthode.** `bench/reason.exe` (build release, compilé avec les optimisations) de la branche de l'étape 3, eb264f0
(`bulk`, d'où cette étape est partie), et de cette branche, chacune compilée depuis sa propre source. 21 tours alternés
(l'ordre tourne à chaque tour), un tour pendant une seule prise du lock des travaux lourds, chaque processus dans un
scope de 3 GB ; une case est la médiane avec $[x(1), x(21)]$ ; un rapport est la médiane des rapports appariés, avec
leur étendue. La machine était partagée avec les processus d'autres travaux, hors du lock. Commandes :
`reason.exe w3c|owl 1 groups -` (des données de la forme de LUBM, un benchmark d'universités, de départements, de
personnes et de cours ; une université, un groupe par département, en mémoire), `reason.exe w3c|owl 10 bulk DIR` (dix
universités, un seul chargement, durable), `reason.exe uobm 1 rew|ax|plain`, `reason.exe storm N`,
`reason.exe reads`, `bench.exe` (le démarrage).

**OWL 2 RL entier contre les règles du W3C de l'étape 2** (la cible : aussi rapide). `owl` : l'ontologie univ-bench
(celle de LUBM) écrite dans le vocabulaire de la bibliothèque, avec les règles de la bibliothèque (63 règles telles
qu'écrites, dont celles de l'égalité) ; `w3c` : la même ontologie sous forme de faits, avec les dix règles du W3C que
l'étape 2 a mesurées (cax-sco, scm-sco, prp-dom, prp-rng, prp-spo1, prp-inv1, prp-inv2, prp-trp, cls-svf1, cls-int1
sur deux membres). Les mêmes 532 205 faits déduits des données des deux côtés.

| de la forme de LUBM | étape 3 eb264f0, w3c | cette branche, w3c | cette branche, owl | owl / w3c |
|---|---:|---:|---:|---:|
| une université, un groupe par département (en mémoire) : raisonnement | 0,246 s [0,224 ; 0,279] | 0,247 s [0,226 ; 0,272] | **0,277 s** [0,262 ; 0,359] | 1,15 [1,01 ; 1,34] |
| la même chose, l'exécution entière (données faites, écrites, raisonnées) | 0,617 s | 0,615 s | 0,638 s | 1,06 [0,92 ; 1,26] |
| dérivations (une dérivation : une règle avec un fait pour chaque partie de son corps) / faits déduits | 237 731 / 74 710 | 237 731 / 74 710 | 252 120 / 74 768 | |
| dix universités, un seul chargement, durable : le chargement | 1,795 s [1,709 ; 2,790] | 1,816 s [1,686 ; 2,776] | **1,750 s** [1,691 ; 3,277] | 0,98 [0,61 ; 1,68] |
| son raisonnement | 0,533 s [0,481 ; 0,920] | 0,543 s [0,484 ; 0,607] | **0,512 s** [0,442 ; 0,532] | 0,92 [0,79 ; 1,09] |
| dérivations / faits déduits | 2 147 932 / 658 865 | 2 147 932 / 658 865 | 2 274 854 / 658 923 | |

La ligne des groupes vient de la seconde série (21 tours, après le dernier changement du dépliage, la réécriture d'une
règle en une règle par fait de l'ontologie : prp-npa2, dont la valeur est un texte, ne tourne plus sur chaque fait tant
que l'ontologie n'a aucune assertion négative ; owl / w3c était à 1,20 avant) ; les lignes des chargements, de la
première série (21 tours). Sur un chargement, OWL 2 RL entier raisonne plus vite que les dix règles (son programme
déplié contient moins de règles : les réductions plus bas) ; groupe par groupe, il coûte 15 % de raisonnement de plus,
6 % de plus sur l'exécution entière : les 6 % de dérivations en plus, et les contraintes (cls-nothing2, eq-diff1), dans
les plans desquelles on fait passer les faits du groupe après le point fixe (le moment où les règles ne donnent plus
rien de nouveau).

La bibliothèque déduit quelques faits de plus et fait 6 % de dérivations de plus : cls-int2 donne à chaque membre d'une
classe définie le type de sa restriction (`Student ⊓ ∃takesCourse.Course`), que cls-svf1 donnait déjà ; les règles du
W3C que l'étape 2 a mesurées laissent cls-int2 de côté. En chemin, trois sortes de règles dépliées sont maintenant
écartées, pour les deux formes : une règle dont la tête est l'un de ses patterns (cax-sco sur le `[r subClassOf r]`
réflexif que scm-svf1 donne à chaque restriction), deux règles qui sont la même arête (cax-sco sur les faits de scm-int
et cls-int2), et une règle dont la classe découle de celle d'une règle sœur par les arêtes de sous-classe (prp-dom sur
les domaines de propriété que scm-dom1 ajoute en remontant la hiérarchie) : 3,35 M de dérivations avant, 2,27 M après
(les règles de l'étape 2 : 2,15 M).

**L'égalité, à la UOBM.** Des données de la forme de LUBM (une université) où un quart des personnes sont enregistrées
2 à 4 fois (6 558 enregistrements de plus : le même e-mail, la moitié des faits de la personne chacun), l'e-mail étant
inverse functional (prp-ifp : deux choses qui ont le même e-mail sont la même) ; UOBM (Ma et al. [Ma 2006]) ajoute de
telles égalités à LUBM, et Motik et al. [Motik 2015b] y ont mesuré la réécriture contre l'égalité axiomatisée (écrite
en règles qui copient chaque fait sur chaque membre). `rew` : OWL 2 RL entier, l'égalité par les classes ; `ax` : les
mêmes règles, leurs égalités écrites comme des faits `owl/SameAs`, avec eq-sym, eq-trans, et eq-rep-s et eq-rep-o une
fois pour chaque propriété (eq-ref laissée de côté : elle ne ferait que grossir `ax`). Lus à travers leurs classes (les
choses de chaque fait vues comme le plus petit membre de leur classe), les deux donnent les mêmes 217 232 faits (le
digest de leurs valeurs est égal) : une vérification indépendante de la réécriture, à grande échelle. `plain` : les
mêmes données sans propriété inverse functional, rien n'étant rendu identique.

| une université, 6 558 enregistrements de plus | rew (réécriture) | ax (axiomatisée) | rew / ax | plain (sans égalité) |
|---|---:|---:|---:|---:|
| raisonnement | **1,066 s** [1,040 ; 1,126] | 1,957 s [1,902 ; 2,117] | **0,54** [0,51 ; 0,59] | 0,364 s [0,357 ; 0,452] |
| les 24 groupes écrits | **1,523 s** [1,484 ; 1,622] | 2,405 s [2,341 ; 2,622] | 0,63 [0,59 ; 0,68] | 0,822 s |
| dont les fusions (classes faites, faits réécrits) | 0,261 s [0,256 ; 0,270] | | | |
| dérivations | 402 815 | 1 316 744 | 1 / 3,27 | 310 241 |
| faits (déduits ; d'égalité) | 255 826 (78 394 ; 6 558) | 358 071 (180 639 ; 41 220) | 1 / 1,40 (2,30 ; 6,29) | 274 665 (97 235 ; 0) |

Face aux gains publiés : Motik et al. ont mesuré la réécriture 2,3× plus rapide que l'égalité axiomatisée sur UOBM (un
thread, 2 696,7 s → 1 152,7 s ; 3,8× moins de dérivations, 3,2× moins de faits), et 31,1× sur Claros, dont les classes
sont grandes (85,5× moins de dérivations). Ici 1,84× sur les données à la UOBM, avec 3,27× moins de dérivations : le
même ordre que leur UOBM, dont les classes sont petites elles aussi (2 à 4 enregistrements ici). Le gain grandit avec
les classes, comme le montre la tempête plus bas : axiomatisée, une classe de n choses tient n² faits sameAs ; avec
n = 100, la réécriture prend 0,001 s et l'égalité axiomatisée 0,139 s (1 030 001 dérivations, 20 423 faits), avec
n = 200, 0,002 s contre 0,343 s (8 120 001 dérivations, 80 523 faits) : 139× et 172× ; avec n = 400, l'égalité
axiomatisée dépasse le budget (la limite de travail qu'un groupe peut demander aux règles) et son groupe est refusé, en
nommant prp-fp. La réécriture coûte plus que les mêmes données sans égalité (`plain`, 0,364 s) : les faits de chaque
enregistrement sont déduits une fois avant sa fusion et déplacés après elle, et les fusions elles-mêmes (0,26 s)
cherchent chaque propriété qui pourrait nommer la chose fusionnée.

**Une tempête d'égalités** (une propriété fonctionnelle avec n valeurs sur une seule chose : n choses n'en font plus
qu'une ; un seul groupe, en mémoire) :

| n | raisonnement | dont les fusions | faits de `cepheus/same` |
|---:|---:|---:|---:|
| 1 000 | 0,011 s | 0,004 s | 999 |
| 10 000 | 0,164 s | 0,074 s | 9 999 |
| 100 000 | 1,42 s | 0,84 s | 99 999 |

(des exécutions uniques ; `reason.exe storm N`)

Linéaire : n − 1 faits de `cepheus/same`, là où l'égalité axiomatisée tient n² faits sameAs déduits 2n³ + n² + n fois
[Motik 2015b]. Avant, quand les égalités étaient appliquées fait par fait (à la fin d'un tour), 3 000 choses prenaient
3,95 s (les n² paires de la règle de la propriété fonctionnelle) ; maintenant 0,05 s.

**Lectures et démarrage.** Une lecture par id désigne une chose par le représentant de sa classe : une seule
comparaison de pointeurs quand la vue ne contient aucune égalité (21 tours, LUBM-1 en mémoire, 2 000 000 de lectures
chacun) : `get` 2 662 ns sur l'étape 3, 2 647 ns ici (apparié 1,02 [0,93 ; 1,11]) ; `values` 780 et 767 ns (1,00
[0,85 ; 1,23]). Démarrage (`bench.exe`, 21 tours de 50 exécutions) : 3,226 ms [3,131 ; 3,357] sur l'étape 3,
**3,217 ms** [3,058 ; 3,371] ici, apparié 1,00 [0,94 ; 1,06] : la bibliothèque et l'égalité n'ajoutent rien au
démarrage (les règles sont compilées à la première écriture qui en a besoin, jamais à l'ouverture).

**Les anciennes bases.** Une base écrite par main 9761e4a et une écrite par l'étape 3 (LUBM-1 avec les 94 règles, un
groupe par département) sont lues en entier par le binaire de l'étape 3 et par celui-ci : les mêmes 432 123 faits
(131 437 déduits), le même digest de chaque fait et de son drapeau (affirmé ou seulement déduit).

## Règles, étape 3 : le chemin des chargements, trié et parallèle (2026-11-14)

La troisième étape du reasoner ([règles](rules.md#grands-groupes)) : les faits d'un grand groupe raisonnés comme un
préfixe trié du working set (l'ensemble des faits sur lequel travaille le raisonnement) au lieu de hash chains (des
chaînes de faits par valeur de hachage), des chaînes gardées seulement là où un plan les lit, les grands tours changés
en faits sur chaque thread matériel, les faits déduits fusionnés dans les deux ordres du groupe ; les contraintes, les
têtes à une seule valeur et les faits déjà déduits restent sur ce chemin ; un grand lot de faits déduits entre dans le
delta de la vue (les changements depuis le dernier merge, gardés en mémoire) par des maps construites en temps
linéaire.

**Méthode.** `bench/reason.exe` (build release) de main 9761e4a, de la branche de l'étape 5, 0b8c847 (d'où cette
étape est partie), et de cette branche, chacun compilé depuis sa propre source. Des tours alternés (l'ordre des
binaires tourne à chaque tour), une série pendant une seule prise du lock des travaux lourds, chaque processus dans un
scope de 3 GB ; une case est la médiane avec $[x(1), x(n)]$ ; un rapport est la médiane des rapports appariés (tour par
tour), avec leur étendue. Le pic de mémoire résidente est celui du processus (`getrusage`), les données générées dans
le processus et sa liste d'opérations comprises. La machine était partagée avec les processus d'autres travaux, hors
du lock (une charge moyenne de 5 sur 8 threads) : les médianes sont au-dessus des exécutions les plus calmes. Les mêmes
réponses : 532 205 faits déduits et 2 021 310 dérivations de chaque côté, et sur cette branche le digest de chaque fait
et de son drapeau égal pour un seul groupe, une université par groupe, et un département par groupe. Commandes :
`reason.exe mat 10 rules|none bulk|chunks DIR`, `reason.exe student 1 2000 DIR`, `reason.exe define 10`.

**Données de la forme de LUBM, dix universités avec les 94 règles, un seul groupe, durable** (1 354 654 faits
affirmés ; 7 tours) :

| | main 9761e4a | étape 5 0b8c847 | cette branche | celle-ci / main |
|---|---:|---:|---:|---:|
| le chargement, chaque fait durable | 2,90 s [2,72 ; 3,90] | 2,76 s [2,68 ; 3,19] | **1,78 s** [1,66 ; 2,27] | 0,62 [0,42 ; 0,81] |
| son raisonnement | 1,217 s [1,047 ; 1,285] | 1,015 s [0,870 ; 1,054] | **0,411 s** [0,334 ; 0,465] | 0,33 [0,27 ; 0,44] |
| dont les faits préparés pour les joins | 0,627 s [0,489 ; 0,693] | 0,603 s [0,478 ; 0,672] | **0,128 s** [0,065 ; 0,142] | 0,21 [0,10 ; 0,26] |
| les tours seuls (la saturation : le calcul jusqu'au point fixe), faits déduits par seconde | 0,92 M [0,85 ; 0,98] | 1,36 M [1,27 ; 1,44] | **1,92 M** [1,58 ; 2,04] | 2,04 [1,66 ; 2,17] |
| le raisonnement entier, faits déduits par seconde | 0,44 M | 0,52 M | **1,29 M** (meilleure exécution 1,59 M) | |
| pic de mémoire résidente | 680 MB [659 ; 753] | 832 MB [804 ; 836] | **557 MB** [494 ; 570] | 0,81 [0,69 ; 0,86] |

**La même chose sans règles** (5 tours) : 1,374 s [1,299 ; 1,717] sur main, **1,059 s** [1,042 ; 1,783] ici (0,82
[0,74 ; 1,04] : le tri par chose sur plusieurs domains, les nouveaux textes numérotés par une table à adressage
ouvert), 340 MB et 308 MB.

**Une université par groupe** (dix grands groupes d'environ 135 000 faits, durables ; cette branche seulement, les
autres n'ont pas ce mode ; 5 tours) : les dix écritures **2,45 s** [2,21 ; 3,04], leur raisonnement 0,61 s, **pic de
mémoire résidente 133 MB** [131 ; 134]. Avant cette étape, à partir de la deuxième université, chaque groupe allait au
chemin ordinaire (le type d'une université, déduit des diplômes des universités d'avant, était affirmé de nouveau) :
8,6 s en une exécution.

**Sur le disque** : le run du chargement avec ses conséquences fait 23,1 MB (12,3 octets par fait, le dictionnaire de
ses 600 000 textes compris), sans règles 19,9 MB (14,7 par fait) : les 532 205 faits déduits prennent 3,3 MB,
**6,2 octets chacun** ; dans le journal, 2,8 octets chacun (7,2 MB contre 5,7).

**Ce qui n'a pas changé : le chemin d'un petit groupe** (`student 1 2000` : un étudiant (GraduateStudent) écrit puis
retiré, 2 000 de chaque, sur un fork d'une université ; 7 tours ; médianes des médianes des tours, rapports appariés
contre main) :

| | main 9761e4a | étape 5 0b8c847 | cette branche | celle-ci / main |
|---|---:|---:|---:|---:|
| sans règles : écrire / retirer | 10,0 / 6,9 µs | 10,0 / 7,2 µs | 10,0 / 7,2 µs | 1,00 [0,50 ; 1,44] / 1,04 [0,72 ; 1,15] |
| avec les 94 règles : écrire / retirer | 27,9 / 41,0 µs | 28,1 / 42,9 µs | 29,1 / 42,2 µs | 1,03 [0,90 ; 1,17] / 1,00 [0,93 ; 1,76] |

L'horloge à la microseconde de ces médianes et la machine partagée rendent l'étalement des tours plus large que toute
différence. Démarrage (`bench.exe` sans arguments, 21 tours de 100 exécutions, alternés, chaque binaire en 7 copies
prises à tour de rôle : la place d'une copie en mémoire déplace un démarrage de 2 % au plus) : 3,023 ms sur 0b8c847,
2,987 ms ici (apparié 0,989 [0,975 ; 0,992], plus rapide dans 21 tours sur 21). Le code de cette étape ajoute 507
frame descriptors (ce qui dit au GC où sont les valeurs dans la pile), que le runtime range dans une table à chaque
démarrage : 0,7 % de plus (1,007 [1,003 ; 1,011]) ; les histogrammes de latence, qui créaient leurs compteurs au
chargement des modules (8 ici, 230 KB), les créent maintenant à leur première valeur, ce qui rend davantage. Les bases
écrites par les binaires de main et de 0b8c847 s'ouvrent ici et donnent les mêmes faits et drapeaux (le digest d'une
université chargée par chacun).

**Un changement des règles** (les deux cibles de l'étape 5, mesurées de nouveau avec cette étape ; la méthode de
l'[étape 5](#règles-étape-5--les-changements-des-règles-en-arrière-plan-2026-11-13) :
`CHANGE=one reason.exe change 10 256 8 2 with|without DIR`, le changement d'une règle sur LUBM-10 pendant que 256
clients écrivent ; 7 paires pour chaque binaire, en une seule prise du lock ; et `reason.exe define 10`, les 94 règles
définies en mémoire sur le chargement, 5 tours) :

| | étape 5 0b8c847 | cette branche |
|---|---:|---:|
| la construction du changement à côté de 256 clients qui écrivent (119 000 à 150 000 faits déduits) | 0,531 s [0,388 ; 0,562] : 0,33 M/s | **0,332 s** [0,282 ; 0,391] : **0,45 M/s** |
| le débit des clients dans la fenêtre du changement, avec / sans | 0,88 [0,52 ; 1,51] | 0,86 [0,48 ; 5,47] |
| la même chose sur l'exécution, depuis le début du changement | 1,08 [0,77 ; 1,39] | 0,87 [0,54 ; 1,46] |
| les 94 règles définies en mémoire (532 205 déduits) | 3,35 s [2,64 ; 23,9] | **2,10 s** [1,96 ; 2,62] : 0,25 M/s |

La construction du changement gagne par son delta : un grand lot de faits déduits entre maintenant dans le delta de la
vue par des maps construites en temps linéaire (0,6 µs par fait au lieu de 1,2). Ses tours lisent toujours la vue fait
par fait, sur le domain propre du changement (plus de domains y coûtent du débit aux clients qui écrivent : la
conclusion de l'étape 5), et ses faits vont toujours dans le delta, pas dans un run à eux : la cible de l'étape, 2 M de
faits déduits par seconde, n'est pas atteinte (0,45 M/s), ni 0,90 pour les clients qui écrivent (0,86 en médiane, dans
l'étalement des paires du 0,88 de l'étape 5).

- **Face aux cibles de l'étape** : le chargement avec ses conséquences en 1,5 s au plus : 1,78 s en médiane, 1,66 s au
  mieux (manqué : le chargement sans règles prend 1,06 s ici, et le merge des 532 205 faits déduits dans le run ajoute
  environ 0,1 s) ; son raisonnement en 0,25 s au plus (2,5 M de faits déduits par seconde sur 8 threads) : 0,41 s en
  médiane, 0,33 s au mieux, 1,3-1,6 M par seconde (manqué ; les tours seuls atteignent 1,9-2,0 M par seconde) ; la
  mémoire d'un chargement en 150 MB au plus, par morceaux : 133 MB (atteint) ; 5 octets par fait au plus : 6,2 octets
  par fait déduit dans le run, 12,3 par fait avec le dictionnaire (manqué : le format du run n'a pas changé dans cette
  étape).
- **Où va maintenant le temps du raisonnement** (cette branche, une exécution avec des chronomètres) : le working set
  alloué 0,03-0,05 s, le préfixe rempli 0,015 s, sa table d'appartenance 0,03 s, les phases de dérivation 0,09-0,14 s
  (2 021 310 dérivations, chacune une recherche dans une table de dizaines de MB), les têtes changées en faits
  0,08-0,11 s (dont les recherches dans les régions 0,055-0,08). Chaque pas qui reste est de la latence mémoire ;
  8 threads contre 4 ont donné 13 % (0,350/0,305 s contre 0,407/0,353 s).
- **À côté des géants** (leurs articles, leurs machines et leurs données ; *calculé* : par nous, à partir de leurs
  tables) : RDFox 2014 [Motik 2014] 0,67 M de faits déduits par seconde sur un thread, 6,1-7,0 M sur 16-32 threads de
  deux Xeon à 8 cœurs (0,44 M par cœur à 32 threads) ; VLog [Urbani 2016] environ 1,28 M sur un thread. Ici 1,9 M par
  seconde pour les tours et 1,3-1,6 M pour le raisonnement entier sur un seul portable à 4 cœurs (8 threads) :
  0,33-0,40 M par cœur, proche des 0,44 M par cœur de RDFox 2014 en parallèle et au-dessus de son débit sur un thread ;
  en dessous des nombres absolus de RDFox en parallèle, qui demandent ses 16 cœurs. Le chargement OWL2-RL documenté de
  GraphDB, 9,1 k énoncés affirmés par seconde sur 8 cœurs, persistés (d'autres données, une autre machine) : ici
  1,35 M de faits affirmés avec leurs conséquences rendus durables en 1,78 s, environ 0,76 M par seconde.

## Règles, étape 5 : les changements des règles en arrière-plan (2026-11-13)

La cinquième étape du reasoner ([règles](rules.md#les-changements-des-règles-en-arrière-plan)) : un changement des règles ou
de l'ontologie calculé à côté du writer, mis à jour des groupes écrits entre-temps, installé comme un seul groupe ; des
tours de 20 000 faits et plus déduits sur plusieurs domains dans les groupes que le writer raisonne lui-même.

**Méthode.** `CHANGE=one reason.exe change 10 256 8 2 with|without DIR` (build release) : des données de la forme de
LUBM, 10 universités sur le disque avec les 94 règles d'univ-bench (1,89 M de faits), fusionnées en un seul run,
copiées avant chaque exécution ; 256 threads clients écrivent des étudiants (GraduateStudent, 10 faits, un groupe
chacun, durable) en closed loop pendant 8 s ; à 2 s, avec `with`, le changement est écrit (`define` de
`[x type Person] -> [x type Schedule]`, une classe que les données laissent vide : le Person ⊑ Agent de l'étude de
conception, à son choix 10.6) ; chaque exécution enregistre les groupes confirmés par tranches de 10 ms. 21 paires
(avec, sans), alternées (le côté qui passe en premier change à chaque paire), chaque exécution sous le lock des travaux
lourds et dans un scope de 3 GB ; un rapport est celui d'une paire : les groupes confirmés dans la fenêtre du
changement avec lui, divisés par ceux confirmés dans la même fenêtre sans lui.

| quoi (21 paires) | médiane | min | max |
|---|---|---|---|
| le changement, du `define` à sa réponse | 3,09 s | 0,72 s | 6,90 s |
| sa construction (ses conséquences sur l'état d'où il est parti : environ 150 000 faits déduits) | 0,49 s | 0,35 s | 0,76 s |
| le débit de la construction | 0,30 M faits déduits/s | 0,20 | 0,40 |
| la part propre du writer à l'installation (les derniers groupes, la frame) | 54 ms | 42 ms | 103 ms |
| le débit des clients dans la fenêtre du changement, avec / sans | **0,84** | 0,005 | 36 |
| la même chose sur toute l'exécution depuis le début du changement | **0,89** | 0,10 | 3,8 |

Les extrêmes des rapports sont de courtes fenêtres (moins d'une seconde) où un côté a rencontré un blocage que l'autre
n'a pas eu (le switch d'un merge, la machine) : ce sont les médianes qui mesurent. Sans le changement, les clients
confirment 8 069 groupes par seconde dans cette fenêtre (médiane) ; avec lui, 6 468. Où va la différence, d'après les
tranches de 10 ms des 21 paires avec quatre domains en arrière-plan : 0,70 pendant la construction, 0,74 pendant la
mise à jour, et encore 0,79 dans les deux secondes après l'installation, quand l'arrière-plan n'est plus là : une part
du coût est l'état que laisse le changement (une règle de plus qui déduit pour chaque personne écrite, un delta qui a
grandi sans merge à côté du changement, puis ce merge), pas l'arrière-plan seul.

Des variantes mesurées en chemin, avec la même méthode : l'arrière-plan qui déduit sur quatre domains (par morsels, de
petits morceaux de travail, comme le font les grands groupes du writer lui-même) : 0,78 dans la fenêtre et 0,79 sur
l'exécution (21 paires), si bien qu'il déduit sur son seul domain ; un minor heap (la zone où OCaml alloue les valeurs
neuves) de 64 MiB pour son domain : 0,735 (7 paires) ; un minor heap de 32 MiB pour chaque domain
(`OCAMLRUNPARAM=s=4M`) : 0,57 (7 paires).

**Le pire cas**, `CHANGE=all` : la base ne contient aucune règle et le changement définit les 94 (683 000 faits déduits
avec les étudiants écrits avant lui). Des exécutions uniques, pas 21 : construction 3,0 s (0,23 M faits déduits/s ;
dont 1,6 s pour mettre les faits dans le delta de la vue), puis des passes de mise à jour de 35 000 à 66 000 groupes,
de 3,8 à 7,4 s chacune (environ 110 µs par groupe : chaque groupe écrit entre-temps est raisonné sous 94 règles sous
lesquelles il ne l'avait pas été, contre 10 µs pour le writer), jusqu'à ce que le writer attende l'arrière-plan, à
65 536 groupes de retard ; le changement a pris 18 à 25 s, son installation 1,2 à 1,9 s ; une exécution a été arrêtée
au plafond de 3 GB après l'installation (les deux deltas et une frame de 1,6 M de changements). La première version de
la mise à jour appliquait les groupes du journal un par un : là, elle ne rattrapait jamais le writer, et l'exécution a
été arrêtée au plafond de 3 GB après 39 s.

**La dérivation seule**, `reason.exe define 10` (en mémoire, les 94 règles définies sur les mêmes données chargées sans
elles, un seul changement calculé dans son groupe sur un fork) : 3,0 s pour 532 205 faits déduits, dont le premier tour
des règles ajoutées 0,48 s sur quatre domains (1,31 s sur un), les tours suivants 0,56 s (0,72 s), et leur mise dans
le delta d'un fork, qui contient tout le chargement dans des persistent maps (des maps dont chaque modification fait
une nouvelle version sans détruire l'ancienne), 1,2 s.

**Des tours sur plusieurs domains dans un chargement** (`reason.exe mat 10 rules bulk DIR` : les 10 universités avec
les 94 règles en un seul groupe sur le disque, le chemin des grands groupes ; 21 tours alternés avec main 9761e4a) : la
saturation (les tours seuls, le working set construit) 0,90 M faits déduits/s sur main, **1,44 M/s** ici (quatre
domains ; rapport apparié 1,54) ; le raisonnement entier 1,18 s et 1,02 s ; le chargement, 2,85 s et 2,93 s
(l'étalement du disque, de 2,3 à 4,6 s, couvre cet écart).

**Ce qui n'a pas changé.** Les mêmes groupes d'étudiants dans un fork sur une université
(`reason.exe student 1 2000 DIR`, 21 tours alternés avec main 9761e4a) : sans règles, écrire 9,1 µs et 9,1 µs, retirer
6,9 et 6,9 ; avec les règles, écrire 26,0 et 26,0, retirer 37,0 et 37,0 (médianes ; rapports appariés de 0,96 à 1,00).
Démarrage (`bench.exe` sans arguments, 21 tours de 50 exécutions) : 3,195 ms sur main, 3,211 ms ici (rapport apparié
1,03, dans l'étalement des tours, de 2,9 à 4,5 ms).

**Face aux cibles de l'étape.** Le débit durable des clients pendant qu'un changement tourne à l'échelle de LUBM-10 :
0,84 de sa valeur sans lui dans la fenêtre du changement, 0,89 sur l'exécution, contre une cible de 0,90 : manqué, de
peu sur l'exécution. Les conséquences du changement à 2 M de faits déduits/s sur 8 threads : 0,30 M/s mesurés sur le
seul domain de l'arrière-plan : manqué de loin ; ce qui coûte encore par fait, c'est le delta de la vue (des persistent
maps, environ 1,5 µs par fait mis) et des joins qui sondent le stockage fait par fait, ce que traite l'étape 3 de la
conception (des joins triés, les faits d'un changement dans un run à eux). `spec/RuleChange.tla` vérifié par TLC (le
model checker de TLA+, qui parcourt tous les états du modèle) : atteint ([tester](testing.md#model-checking)).

## Règles, étape 2 : les closures et la forme du W3C (2026-11-12)

La deuxième étape du reasoner ([règles](rules.md#les-transitive-closures--le-closure-module)) : les propriétés transitives
tenues par un closure module (un module qui calcule la transitive closure, tous les couples reliés par un chemin, sans
passer par la règle), et les règles sur une propriété variable dépliées sur les faits de l'ontologie.

**Méthode.** `bench/reason.exe` (build release), mesuré contre le binaire de 23ac670 (la première étape du reasoner, où
prp-trp tourne comme une règle), les deux compilés depuis la même source de benchmark (les modes qu'a le binaire plus
ancien). Sept tours, alternés (le côté qui passe en premier change à chaque tour), pendant une seule prise du lock des
travaux lourds, chaque processus dans un scope de 3 GB ; une case est la médiane des tours avec $[x(1), x(n)]$ ; un
rapport est la médiane des rapports appariés (nouveau/ancien, tour par tour). Les mêmes réponses des deux côtés : les
faits des closures et les faits déduits sont égaux. Les graphes sont ceux de l'étude de conception (section 6.4, tracés
comme son prototype les traçait) : une hiérarchie de 100 000 nœuds, 4 enfants chacun (profondeur 8) ; une profonde de
20 000 nœuds, 2 chacun (profondeur 14) ; un DAG aléatoire (un graphe orienté sans cycle) de 5 000 nœuds, 3 arêtes vers
le bas chacun (le `Random` d'OCaml, seed 1 : 14 973 arêtes) ; une chaîne de 500. Chaque arête dans un seul groupe, sur
le disque (`closure KIND trp|linear DIR`) : les 99 999 arêtes de la hiérarchie prennent le chemin des grands groupes,
les autres (moins de 20 000 opérations) le chemin ordinaire. « Le module » est le temps propre du closure module (ses
faits trouvés et rangés pour le groupe), comme le prototype mesurait son module ; « raisonnement » est le tout dans le
groupe (avec, pour un grand groupe, la construction du working set de ses faits). Des données de la forme de LUBM comme
dans [Règles (2026-11-08)](#règles-2026-11-08) : `mat 10 rules …` les 94 règles écrites une par axiome, `w3c 10 …`
l'ontologie sous forme de faits et les 10 règles du W3C dont elle a besoin (cax-sco, scm-sco, prp-dom, prp-rng,
prp-spo1, prp-inv1, prp-inv2, prp-trp, cls-svf1, cls-int1 sur deux membres), que le moteur déplie.
Commandes : `reason.exe closure hierarchy|deep|dag|chain trp|linear DIR`, `reason.exe mat 10 rules bulk|groups DIR|-`,
`reason.exe w3c 10 bulk|groups DIR|-`, `reason.exe student 1 2000 DIR`.

**Les transitive closures** (médiane [x(1) ; x(7)] de 7 tours ; les closures égales des deux côtés) :

| graphe (faits de la closure, déduits) | forme | le module | raisonnement : 23ac670 → ici | l'écriture, durable : 23ac670 → ici | dérivations : 23ac670 |
|---|---|---:|---:|---:|---:|
| hiérarchie, 100 000 nœuds (783 495 ; 683 496) | prp-trp | **22,5 ms** [21,2 ; 24,4] | 0,918 s → **0,084 s** (0,091×) | 1,27 s → 0,42 s (0,33×) | 2 706 780 |
| | linear | 26,3 ms [12,0 ; 40,9] | 0,606 s → 0,146 s (0,23×) | 1,05 s → 0,61 s (0,58×) | 783 495 |
| profonde, 20 000 nœuds (247 248 ; 227 249) | prp-trp | 9,8 ms [9,4 ; 15,0] | 1,07 s → 0,58 s (0,54×) | 1,14 s → 0,64 s (0,57×) | 1 438 678 |
| DAG aléatoire, 5 000 nœuds (1 359 764 ; 1 344 791) | prp-trp | **47,3 ms** [41,9 ; 57,5] | 17,6 s → 3,85 s (0,22×) | 17,8 s → 4,06 s (0,23×) | 77 224 523 |
| | linear | 44,1 ms [39,7 ; 48,6] | 6,37 s → 3,88 s (0,61×) | 6,63 s → 4,09 s (0,62×) | 2 449 704 |
| chaîne, 500 nœuds (124 750 ; 124 251) | prp-trp | 1,2 ms [1,2 ; 1,5] | 2,44 s → 0,26 s (0,10×) | 2,46 s → 0,29 s (0,11×) | 20 708 998 |
| | linear | 1,3 ms [1,2 ; 1,4] | 0,35 s → 0,26 s (0,75×) | 0,38 s → 0,28 s (0,77×) | 124 750 |

- **Les cibles de la conception** : la closure de la hiérarchie en 30 ms au plus (22,5 ms : atteint ; le prototype
  11-16 ms, prp-trp comme règle 665 ms là-bas, 918 ms ici), celle du DAG aléatoire en 60 ms au plus (47,3 ms : atteint ;
  le prototype 14-46 ms, prp-trp 7,82 s là-bas, 17,6 s ici). Le module fait chaque nouveau fait une seule fois :
  0 dérivation, contre 3,5 à 166 par fait avec la règle.
- **Où va le reste** : les 99 999 arêtes de la hiérarchie forment un grand groupe, dont le raisonnement construit aussi
  le working set de ses faits (54 ms sur les 84). Les arêtes du DAG, de l'arbre profond et de la chaîne sont sous les
  20 000 opérations : le chemin ordinaire, dont les faits vont dans le delta de la vue un par un, par lots triés
  (environ 2,8 µs par fait avec les enregistrements de changement du groupe) : 3,8 s sur les 3,9 du DAG. Les grandes
  dérivations venues de petits groupes prennent le chemin des grands groupes à l'étape 3 de la conception.
- **Mesuré et écarté** : les tableaux du module sont des Bigarrays (des tableaux hors du tas d'OCaml), qui règlent le
  rythme du major collector d'OCaml (le GC des valeurs anciennes) sur leur taille (`custom_major_ratio`, 44 % par
  défaut) : avec ce réglage à 1 000, le module de la hiérarchie prenait 19,5 ms au lieu de 48,6 ms, avant que les
  tableaux soient réduits ; le moteur ne change pas les réglages du collector du programme dans lequel il tourne.
- **À côté des géants** (leurs articles, leurs machines et leurs données) : Hu, Motik et Horrocks [Hu 2022] rapportent
  LUBM-LE matérialisé en 339 s avec les modules contre 1 268 s sans (3,7×) ; ici le temps propre du module est 23 à
  2 000 fois sous le raisonnement de la règle sur ces graphes (le prototype de la conception : 60 à plus de 1 000), et
  le raisonnement d'un groupe 1,3 à 11 fois plus rapide. RDFox a de tels modules depuis 2019 [Hu 2019] : égalité de
  méthode. Soufflé, qui évalue la règle, « runs out of memory when evaluating TC on G80K » (manque de mémoire pour
  calculer la transitive closure de G80K) dans les tests de Fan et al. [Fan 2019].

**Une arête retirée** (le même binaire, par parcours, contre B/F, l'algorithme Backward/Forward qui garde justes les
faits déduits quand des faits partent, à travers les plans des règles, `Reason.walk_retract` ; 21 tours alternés
pendant une seule prise du lock, la closure chargée d'abord dans chaque processus ; médianes, $[x(1), x(21)]$, la
médiane du rapport apparié avec son intervalle à 95 % par statistiques d'ordre $[x(6), x(16)]$ ; la même closure
après, des deux côtés) :

| prp-trp | faits perdus | par parcours | par B/F | parcours / B/F |
|---|---:|---:|---:|---:|
| hiérarchie, l'arête d'un nœud de profondeur 2 (son sous-arbre : 6 250 choses) | 36 160 | **0,102 s** [0,095 ; 0,187] | 0,161 s [0,146 ; 0,255] | 0,64 [0,59 ; 0,73] |
| DAG aléatoire, l'arête 300 → 134 | 102 | **0,090 s** [0,078 ; 0,357] | 1,766 s [1,448 ; 2,410] | 0,050 [0,045 ; 0,055] |
| chaîne de 500, l'arête du milieu | 62 500 | **0,163 s** [0,151 ; 0,254] | 16,11 s [15,03 ; 20,29] | 0,0099 [0,0096 ; 0,0105] |

Le temps des parcours est surtout celui des faits perdus mis dans la vue (environ 2,5 µs par fait dans le cas de la
hiérarchie) ; B/F vérifie chaque fait perdu à travers les instances de la règle (sur la chaîne, chaque point du milieu
de chaque paire), et c'est là que vont les 100×. Une arête qui a un autre chemin (la plupart des arêtes du DAG) ne
change rien et coûte une recherche par arête qui part de son début.

**Des données de la forme de LUBM, la forme du W3C contre des règles écrites une par axiome** (dix universités ; les
deux sur ce binaire ; les mêmes 532 205 faits déduits des données) :

| | 94 règles, une par axiome | les 10 règles du W3C, dépliées | W3C / axiome, apparié |
|---|---:|---:|---:|
| un seul groupe (un chargement, durable) : raisonnement | 1,296 s [1,143 ; 1,625] | 1,367 s [1,297 ; 1,646] | **1,10** [0,80 ; 1,27] |
| un département par groupe, en mémoire : raisonnement | 2,383 s [2,240 ; 2,659] | 2,498 s [2,446 ; 3,459] | **1,05** [0,93 ; 1,54] |
| faits déduits / dérivations | 532 205 / 2 021 310 | 658 865 / 2 147 932 | |

- **La cible de la conception** : 1,1× au plus des règles écrites à la main (le prototype, qui faisait tourner les
  règles du W3C telles qu'écrites : 2,2×). Atteinte en médiane : 1,10 pour le chargement, 1,05 groupe par groupe. La
  forme du W3C déduit davantage, par son propre sens : 126 660 faits de plus, les types des six classes de restriction
  (`x` est membre de « some `takesCourse` a `Course` » avant d'être un `Student`) et la closure de `subClassOf` ; les
  règles de sous-classe dépliées que donne une chaîne des autres sont écartées, si bien qu'un type est déduit une fois
  par pas, comme à la main.
- Chaque groupe a tourné déplié, sauf le premier qui a écrit un fait d'une relation sur laquelle les règles avaient été
  dépliées alors que la base était vide (`type`) : les règles ont été dépliées de nouveau sans elle, aussitôt.

**Les règles écrites une par axiome, et le chemin d'écriture, contre 23ac670** (les mêmes groupes, 7 tours) :

| | 23ac670 | ici | apparié |
|---|---:|---:|---:|
| LUBM-10 en un seul groupe : raisonnement | 1,283 s [1,130 ; 1,531] | 1,296 s [1,143 ; 1,625] | 1,00 [0,90 ; 1,33] |
| un département par groupe, en mémoire : raisonnement | 2,216 s [2,160 ; 2,387] | 2,383 s [2,240 ; 2,659] | 1,04 [0,98 ; 1,22] |
| écrire un étudiant, avec règles / sans | 24,8 / 8,8 µs | 26,0 / 8,8 µs | 1,05 [0,85 ; 1,20] / 1,00 |
| le retirer, avec règles / sans | 36,0 / 6,2 µs | 36,0 / 6,9 µs | 1,00 / 1,00 |
| démarrage (`bench.exe`, 21 tours de 50 exécutions, médianes), contre main ca74bbe | 2,913 ms [2,692 ; 3,062] | 2,938 ms [2,575 ; 3,368] | 1,00 (0,997, 95 % [0,951 ; 1,035]) |

Le code du reasoner a doublé (le closure module et son retrait, le dépliage, les propriétés variables : ses frame
tables de 62 KB à 125 KB, que le runtime lit au démarrage) : dans le bruit à 21 tours, plus rapide dans 11 d'entre eux ;
les fonctions grosses et froides sont gardées hors ligne (jamais recopiées dans leurs appelants ; un build plus ancien,
avant cela, mesurait 1,044 contre 23ac670). La closure de subOrganizationOf des règles écrites à la main est elle aussi
celle du module : 3 478 dérivations de moins.

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
les numéros des nouvelles choses) est fait à côté du merge ([architecture](architecture.md#grands-groupes)). Avec
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

**Les corrections du moteur mesurées à nouveau** (la section plus bas), sur une machine calme : 2f37b23 (avant les
corrections) contre 51cf32d (après), les mêmes chargements et les mêmes ouvertures, 9 tours en alternance. Chaque
rapport est après sur avant, la médiane des rapports des 9 tours et son intervalle, qui n'est pas forcément le rapport
des deux médianes. 10 M en 4 grands groupes : 9,68 s [8,42 ; 11,47] contre 8,73 s [8,09 ; 9,61] (rapport 0,97
[0,77 ; 1,12], après plus lent dans 4 tours sur 9, $p = 1$) ; son ouverture 396
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
n'a pas d'entrée pour le même fait : quelques bits des rank tables quand le run le plus récent ne contient pas la
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
ont été mesurées sur le moteur de 148ff09 ; sur un seul run, les niveaux lisent à la même vitesse
([Les lectures, tout en mémoire](#les-lectures-tout-en-mémoire), plus haut), donc la comparaison tient.

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
clients, des groupes de 83 faits, environ 33 merges à mesure que la base grandit ; chaque case donne toutes les exécutions,
séparées par des points-virgules, les exécutions en alternance) :

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
  trois processus pour une requête.** Sur un cœur, il est 1,2 fois plus lent que Cepheus sur Q4, et à égalité sur Q5 (1 000 ms contre 968).
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
