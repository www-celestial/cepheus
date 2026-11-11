# Cepheus et les bases de données établies

Deux sortes de comparaison, jamais mélangées. **Mesuré** : PostgreSQL 18.6 et SQLite 3.54, installés sur la machine de
test, lancés selon la méthode des [benchmarks](benchmarks.md) (les mêmes données, les mêmes questions, les mêmes
réponses vérifiées des deux côtés, des médianes de 21 exécutions avec leurs intervalles à 95 %, sous un lock partagé qui
tient les autres travaux lourds à l'écart de la machine). **Par conception** : Oracle, Datomic, RocksDB, Neo4j,
FoundationDB et CockroachDB, qui ne sont pas installés ici, comparés seulement sur ce que dit leur propre
documentation, citée avec son lien (les citations restent en anglais, telles qu'elles sont écrites) ; aucun chiffre
n'est donné pour eux.

## Mesuré : PostgreSQL 18.6

La machine de test : Intel i7-4720HQ (4 cœurs, 8 threads), 11 GB de mémoire, un SSD SATA grand public (environ 340
fsync par seconde ; fsync : l'appel système qui attend que les octets écrits soient vraiment sur le disque), btrfs.
10 millions de faits : 113 636 clients, 2 272 720 factures, 568 163 liens follow. PostgreSQL dans son propre cluster,
réglé comme le ferait un expert (clés primaires, un index sur chaque colonne cherchée, `VACUUM ANALYZE`, des prepared
statements, fsync et `synchronous_commit` activés, 1 GB de `shared_buffers`) ; Cepheus avec un cache de 1 GiB. Les
lectures et les écritures ont été mesurées côte à côte au jalon 2 (la base à un seul niveau) ; les chargements
après les niveaux et les grands groupes. Les lectures de Cepheus sur un seul run mesurées depuis sont à quelques pour
cent de celles ci-dessous (Q1 0,38 µs, Q2 1,57 µs, Q3 3,74 à 3,82 ms, Q4 231 à 237 ms, Q5 0,95 à 1,00 s :
[benchmarks](benchmarks.md#les-lectures-tout-en-mémoire)).

| | Cepheus | PostgreSQL | qui gagne, et pourquoi |
|---|---:|---:|---|
| Q1 chaque fait d'une facture, par numéro | **0,39 µs** | 4,73 µs dans le serveur ; 26 µs par son socket | Cepheus : des numéros denses en font deux lectures de tableau, dans le processus de l'application ; PostgreSQL parcourt un B-tree et, pour une application, traverse un socket |
| Q2 un client par e-mail (unique) | **1,68 µs** | 5,68 µs ; 26 µs par son socket | Cepheus, pour les mêmes raisons |
| Q3 les factures impayées des clients d'une ville (4 299 lignes) | **4,07 ms** | 10,55 ms (un processus) | Cepheus : des recherches d'index avec des comptes exacts, aucun plan à construire |
| Q4 la somme des impayés par ville (453 866 factures), 1 cœur | 231 ms | 236 ms | égalité |
| Q4, 3 cœurs | 107 ms | 109 ms | égalité |
| Q5 les triangles du graphe des follows, 1 cœur | 1,03 s | 1,03 s | égalité |
| Q5, 3 cœurs | **371 ms** | 603 ms (2 processus : PostgreSQL a lancé 1 worker) | Cepheus : Generic Join se répartit sur des domains |
| écritures durables, 256 clients, aussi vite qu'ils peuvent | 14 182 groupes/s (tours de 14 141 à 17 192) | 19 559 insertions/s (12 742 à 20 863) | égalité : les deux bornés par le débit de fsync du disque ; les tours d'un même côté diffèrent plus que les deux côtés |
| écritures durables à un débit fixe de 2 000 par seconde, p99 | **0,1 à 1,7 s** | 0,6 à 6,1 s | Cepheus, sur ce disque bruyant |
| plus grand que la mémoire : Q4, base de 245 MB, 32 MB de cache, processus limité à 128 MB | **385 ms** | 697 ms | Cepheus |
| plus grand que la mémoire : Q5 | 102 s | **1,05 s** | **PostgreSQL**, de 100 fois (plus bas) |
| avec le format de run 8 (2026-11-11) : Q4 sur 1, 2, 3, 4 cœurs | **128, 81,6, 57,8, 47,8 ms** | 233, 141, 107, 87,7 ms (1 à 4 processus) | Cepheus, 1,8 fois à chaque nombre : trois valeurs seules par facture, lues dans les colonnes du client, de la ville et du total |
| avec le format de run 8 : Q5 sur 1, 2, 3, 4 cœurs | **250, 149, 100, 77,3 ms** | 1 010, 604, 602, 616 ms (il lance 1 worker au plus) | Cepheus, 4 à 8 fois : la colonne de `follows` et les intersections en leapfrog |
| avec le format de run 8 : Q5 plus grand que la mémoire, limite de 128 MB, cache de 32 MB, à froid | **263 ms** (114 ms sur 3 cœurs ; 260 ms sous une limite de 48 MB) | 1,05 s (2026-11-08) | Cepheus, 4 fois : `follows` est maintenant une colonne à lui, 1,6 MB |
| chargement de 10 M de faits, alterné (7 tours) | **5,13 s [4,65 ; 8,08]**, en 2 grands groupes | 30,87 s [28,08 ; 37,13] (`COPY`, index, `VACUUM ANALYZE`) | Cepheus, 6 fois (plus rapide dans 7 tours sur 7) : un grand groupe est placé et trié dans des tableaux compacts par plusieurs domains et fusionné d'un coup dans un run, sa frame écrite à côté (plus bas) |
| chargement de 10 M de faits, un groupe par client (227 272 groupes confirmés) | 111,8 s [103,1 ; 124,4] (4 exécutions) | non mesuré (`COPY` est une seule transaction) | |

**Là où PostgreSQL gagne, et pourquoi.**
- *Q5 plus grand que la mémoire, jusqu'au format de run 8 (2026-11-11), qui garde les lignes de chaque propriété à
  part dans un troisième ordre et fait passer les triangles sous une limite de 48 MB à 0,26 s (lignes ci-dessus).*
  Cepheus range les lignes d'une base par chose, donc les liens follow d'un client se trouvent parmi les lignes de ses
  20 factures ; la question des triangles lit des pages au hasard dans 120 MB de lignes, pour quelques octets chacune
  (18,8 millions de pages lues en 6 exécutions avec un cache de 48 MB). PostgreSQL garde `follows` dans une table à
  lui, 23 MB avec son index, qui tient dans ses 32 MB de buffers. Un troisième ordre des lignes de Cepheus (propriété,
  puis chose) rendrait locale une propriété de beaucoup de choses, pour 10 octets de plus par fait ; il attend des
  charges réelles pour décider ([théorie](theory.md#7-les-pages-et-le-cache)).
  Mesuré à nouveau sur le format de run 7 (2026-11-09), à froid (les pages des fichiers vidées avant chaque côté, ce
  que la série ci-dessus ne faisait pas), à côté de SQLite 3.54, PostgreSQL pas relancé : sous une limite de 128 MB, le
  run de 54,4 MB tient à côté du processus et les triangles prennent 1,10 s (SQLite 1,04 s ; le format 6 ne finissait
  pas en 10 minutes) ; sous 48 MB, où aucun des deux fichiers ne tient, plus de 2,5 minutes par exécution contre 1,02 s
  pour SQLite, dont les liens follow tiennent dans son cache
  ([benchmarks](benchmarks.md#runs-et-journal-compressés-2026-11-09-à-10-millions-de-faits)).
- *Le chargement en masse, jusqu'aux niveaux.* `COPY` écrit les lignes directement dans les pages des tables et
  construit chaque index une fois à la fin. Cepheus chargeait par son writer comme n'importe quelle écriture (des
  groupes de 83 faits, chaque frame forcée), et son niveau unique sur disque faisait réécrire toute la base à chacun des
  33 merges d'un chargement de 10 M : 135 à 153 s contre la minute de PostgreSQL. Avec les niveaux et les grands
  groupes, et le chargement en parallèle et sans copies, Cepheus charge les mêmes faits en 5,13 s et `COPY` prend
  30,87 s ([architecture](architecture.md#grands-groupes)) ; Cepheus paie en mémoire (1,46 GB au pic d'un groupe de
  9,4 M, dont 0,88 pour la liste du client, là où PostgreSQL travaille dans son 1 GB de buffers).
- *Ce qu'il a et que Cepheus n'a pas construit* : SQL, beaucoup de writers concurrents (des locks par ligne), la
  réplication et le failover (la bascule sur une autre machine), un query planner pour n'importe quel SQL, des
  décennies d'outils.

**Serveur contre serveur** (1 M de faits, les mêmes lignes, les deux par leurs propres sockets, 2026-11-08 ; le
tableau complet et sa méthode : [le serveur](server.md#la-vitesse-à-côté-de-postgresql)) :

| | serveur Cepheus | PostgreSQL 18.6 | qui gagne, et pourquoi |
|---|---:|---:|---|
| une lecture ponctuelle, 1 client, socket Unix | **10,81 µs** | 26,39 µs | Cepheus : 1,5 µs de travail au-dessus du round trip du noyau (9,32 µs) ; le seul `SELECT 1` de PostgreSQL prend 15,19 µs |
| la même, TCP + TLS 1.3 | **39,18 µs** | 49,64 µs | Cepheus, de moins : OpenSSL travaille ici sur des buffers en mémoire (16 µs de TLS là où OpenSSL seul en demande 11) |
| 16 lectures en vol sur une connexion, par lecture | **1,46 µs** | 9,11 µs (pipeline de 16) | Cepheus : des réponses par numéro, un lot répondu en un seul appel système |
| 8 clients à la fois, par lecture | **3,22 µs** | 6,54 µs | Cepheus : 4 I/O domains de threads (un seul domain : 9,6 µs) ; PostgreSQL fait un fork d'un processus par connexion |
| 256 clients à la fois, par lecture | **2,88 µs** | 12,83 µs | Cepheus : les threads restent bon marché ; les 256 processus de PostgreSQL coûtent plus |
| Q3, Q4 par le socket | **0,487 ms, 12,37 ms** | 0,662 ms, 18,47 ms | Cepheus |
| une nouvelle connexion TLS | **2,60 ms** | 4,28 ms | Cepheus : aucun processus à forker |
| écritures durables, 1 à 256 clients | égalité | égalité | les deux attendent le fsync du disque |

**L'isolation, par conception** ([PostgreSQL 18: transaction isolation](https://www.postgresql.org/docs/18/transaction-iso.html)) :
« Read Committed is the default isolation level in PostgreSQL » ; Repeatable Read « is implemented using a technique
known [...] as Snapshot Isolation » et permet des anomalies de sérialisation ; Serializable « is implemented using
[...] Serializable Snapshot Isolation », et « applications using this level must be prepared to retry transactions due
to serialization failures ». Cepheus a un seul niveau : des groupes strictly serializable, des read-then-writes (lire,
puis écrire selon ce qu'on a lu) validés par `Expect`
([concepts](concepts.md#lisolation--exactement-ce-que-voient-un-lecteur-et-un-writer)). Le group commit : PostgreSQL
groupe ses commits de lui-même (« When commit_delay is set to zero (the default), it is still possible for a form of
group commit to occur », [WAL configuration](https://www.postgresql.org/docs/18/wal-configuration.html)), comme le fait
Cepheus. Les requêtes parallèles : `max_parallel_workers_per_gather` vaut 2 par défaut
([resource settings](https://www.postgresql.org/docs/18/runtime-config-resource.html)), d'où les « 3 processus »
ci-dessus.

## Mesuré : SQLite 3.54

SQLite est une bibliothèque dans le processus de l'application, comme Cepheus : la comparaison de moteur à moteur la
plus juste. Les mêmes 10 millions de faits et les mêmes réponses, SQLite réglé comme le ferait un expert (`INTEGER
PRIMARY KEY`, une table `WITHOUT ROWID` pour les liens, un index sur chaque colonne cherchée, `ANALYZE`, un page cache
de 1 GiB), les deux sur un cœur, deux tours alternés
([benchmarks](benchmarks.md#sqlite-354-à-10-millions-de-faits--les-lectures-2026-11-08)) :

| | Cepheus | SQLite | qui gagne, et pourquoi |
|---|---:|---:|---|
| Q1 une facture par numéro | **0,36 à 0,38 µs** | 0,67 à 0,68 µs (environ 0,45 µs sans la boucle qui mène les recherches) | Cepheus : un accès à un tableau par numéro dense, là où SQLite descend le B-tree de sa table |
| Q2 un client par e-mail | 1,66 à 1,67 µs | **1,52 µs** (environ 1,22 µs sans la boucle qui les mène), en lisant toute la ligne | **SQLite** : son B-tree atteint l'e-mail en 3 ou 4 pages ; Cepheus fait une recherche dichotomique dans son dictionnaire trié (environ 18 étapes), puis dans les lignes |
| Q3 les factures impayées des clients d'une ville | 4,17 à 4,19 ms | 4,13 à 4,19 ms | égalité |
| Q4 la somme des impayés par ville | **230 ms** | 355 à 366 ms | Cepheus : Generic Join sur des colonnes triées, là où SQLite cherche chaque facture impayée par sa clé et groupe dans un B-tree temporaire |
| Q5 les triangles | **969 à 979 ms** | 1,04 s | Cepheus, de peu ; sur ce graphe uniforme, une boucle imbriquée vaut un worst-case optimal join |
| Q4 et Q5 sur 3 cœurs | **107 ms, 371 ms** | un thread par instruction | Cepheus |
| chargement de 10 M de faits, alterné (7 tours) | **5,61 s [4,21 ; 11,67]**, 2 grands groupes | 9,37 s [7,90 ; 13,67] (`.import`, index ensuite, `ANALYZE`) | Cepheus, 1,7 fois (plus rapide dans 7 tours sur 7 ; égalité avant le 2026-11-08 : 7,04 contre 6,97 s) ; **SQLite** en mémoire : 11 MB contre 1,46 GB |
| chargement de 1 M de faits, une transaction par client (22 726 commits) | **10,6 s [9,9 ; 10,9]**, 64 threads | 166,7 s [138,6 ; 169,3], un seul writer | Cepheus, 16 fois : le group commit met les groupes qui arrivent pendant un fsync dans la frame suivante ; SQLite force chaque commit seul |
| taille sur disque après le chargement de 10 M (2026-11-09, format de run 7, format de journal 2) | **74,7 MB** (journal 21,6, runs 53,1) ; 76,0 MB après `snapshot`, tout l'historique compris | 136,4 MB, un seul fichier, aucun historique | Cepheus, 1,8 fois : chaque valeur codée dans les bits dont son bloc a besoin ; avant le format 7, 335 MB (des mots de 8 octets) |
| chargement de 10 M de faits avec le format 7, alterné (7 tours, 2026-11-09) | **3,45 s** [3,37 ; 3,75] | 7,22 s [6,83 ; 7,82] | Cepheus, 2,1 fois |
| Q1, Q2, Q3, Q4, Q5 avec le format de run 7, un cœur (2026-11-09) | **0,38 µs**, **0,66 µs**, **3,97 ms**, **240 ms**, 1,08 s | 0,68 µs, 1,37 µs, 4,11 ms, 356 ms, **1,03 s** | Cepheus sur Q1 à Q4 (un hash des textes et un value index rendent Q2 2,1 fois plus rapide) ; **SQLite** sur Q5 de 5 % ([benchmarks](benchmarks.md#runs-et-journal-compressés-2026-11-09-à-10-millions-de-faits)) |
| plus grand que la mémoire, à froid, limite de 128 MB, caches de 32 MB, Q1 à Q5 (2026-11-09) | **0,38 µs**, **0,65 µs**, **4,02 ms**, **240 ms**, 1,10 s | 0,87 µs, 1,40 µs, 97,5 ms, 496 ms, **1,04 s** | Cepheus sur Q1 à Q4 : son run de 54,4 MB tient sous la limite, le fichier de 136,4 MB de SQLite non ; **SQLite** sur Q5 de 6 % |
| Q1, Q2, Q3, Q4, Q5 avec le format de run 8, un cœur (2026-11-11) | **0,39 µs**, **0,64 µs**, **2,87 ms**, **130 ms**, **256 ms** | 0,69 µs, 1,42 µs, 4,18 ms, 369 ms, 1,05 s | Cepheus sur les cinq, Q5 de 4,1 fois : le column order (les lignes de chaque propriété rangées à part) et les intersections en leapfrog ([benchmarks](benchmarks.md#le-column-order-et-les-intersections-en-leapfrog-2026-11-11-à-10-millions-de-faits)) |
| plus grand que la mémoire avec le format de run 8, à froid, limite de 128 MB, caches de 32 MB, Q1 à Q5 | **0,44 µs**, **0,69 µs**, **3,13 ms**, **129 ms**, **263 ms** | 2,89 µs, 1,48 µs, 112 ms, 552 ms, 1,14 s | Cepheus sur les cinq ; sous une limite de 48 MB, ses triangles prennent 260 ms contre 1,02 s pour SQLite |
| la même chose sous une limite de 48 MB, caches de 16 MB, où aucun des deux fichiers ne tient | **23,3 µs**, **0,66 µs**, **82,5 ms**, **300 ms**, plus de 2,5 min | 40,7 µs, 1,37 µs, 444 ms, 1,22 s, **1,02 s** | Cepheus sur Q1 à Q4 (1,7 à 5,4 fois) ; **SQLite** sur Q5 de plus de 100 fois : ses liens follow tiennent dans son cache, dans une table et un index à eux, là où Cepheus les lit dans ses thing blocks, parmi les factures |

## Par conception

| | modèle de données | écritures | isolation | stockage | questions |
|---|---|---|---|---|---|
| **Cepheus** | des faits (chose, propriété, valeur) | un seul writer par base, group commit | groupes strictly serializable ; read-then-write validé par `Expect` | un journal + un LSM-tree à leveling de ratio 4 (le delta en mémoire, des runs triés sur disque), son propre page cache | requêtes conjonctives, Generic Join (worst-case optimal) |
| **SQLite** | des tables | un seul writer à la fois | serializable | des B-trees dans un seul fichier ; un rollback journal ou un WAL | SQL |
| **PostgreSQL** | des tables | beaucoup de writers, des locks par ligne | read committed par défaut ; SI ; SSI | heap + B-trees ; WAL | SQL, binary joins, parallèle |
| **Oracle** | des tables | beaucoup de writers, des locks par ligne | read committed par défaut ; serializable est la cohérence de lecture au niveau de la transaction | des logs undo + redo | SQL |
| **Datomic** | des datoms (e, a, v, tx, added) | un seul transactor (Pro) | écritures entièrement sérialisées | quatre index couvrants | Datalog |
| **RocksDB** | des clés et des valeurs (des octets) | une bibliothèque ; des write groups | transactions optimistes ou pessimistes | LSM-tree, à leveling par défaut | gets, scans |
| **Neo4j** | property graph (graphe à propriétés) | beaucoup de writers, des locks | read committed par défaut | stockage de graphe natif | Cypher |
| **FoundationDB** | des clés et des valeurs ordonnées | optimiste, vérification des conflits au commit | strictly serializable | distribué | gets, intervalles |
| **CockroachDB** | des tables | distribué | serializable par défaut ; read committed | Pebble (LSM-tree), Raft par range | SQL |

### SQLite

- *Comme Cepheus* : une bibliothèque embarquée, un seul writer à la fois, des lecteurs qui ne le bloquent pas.
  « Transactions in SQLite are SERIALIZABLE » ([isolation](https://www.sqlite.org/isolation.html)) ; « WAL provides
  more concurrency as readers do not block writers and a writer does not block readers », et « there can only be one
  writer at a time » ([WAL](https://www.sqlite.org/wal.html)).
- *Différent* : la durabilité est un réglage : « With synchronous=FULL in WAL mode, an additional sync operation of the
  WAL file happens after each transaction commit », alors que « A transaction committed in WAL mode with
  synchronous=NORMAL might roll back following a power loss »
  ([pragma synchronous](https://www.sqlite.org/pragma.html#pragma_synchronous)). Cepheus a une seule façon : `Ok` veut
  dire durable. Le page cache de SQLite est petit par défaut (« The default suggested cache size is -2000, which means
  the cache size is limited to 2048000 bytes », [cache_size](https://www.sqlite.org/pragma.html#pragma_cache_size)) ;
  ses tables sont des B-trees (« rowid tables are implemented as B*-Trees »,
  [WITHOUT ROWID](https://www.sqlite.org/withoutrowid.html)), modifiés sur place.
- *Là où SQLite gagne* : SQL, un seul fichier portable, des décennies d'usage et de tests, toutes les plateformes.

### Oracle Database

- « Oracle Database offers the read committed (default) and serializable isolation levels » ; « In serializable
  isolation, the read consistency normally obtained at the statement level extends to the entire transaction », et une
  transaction serializable qui modifie des données changées par une transaction confirmée après son début échoue avec
  « ORA-08177: Cannot serialize access for this transaction »
  ([data concurrency and consistency, 19c](https://docs.oracle.com/en/database/oracle/oracle-database/19/cncpt/data-concurrency-and-consistency.html)).
  C'est la snapshot isolation (Berenson et al. 1995), qui laisse passer le write skew (Fekete et al. 2005) ; l'`Expect`
  de Cepheus le refuse ([concepts](concepts.md#lisolation--exactement-ce-que-voient-un-lecteur-et-un-writer)).
- Le group commit : « When activity is high, LGWR can use group commits », qui écrit le redo des transactions en
  attente « in one operation »
  ([process architecture, 19c](https://docs.oracle.com/en/database/oracle/oracle-database/19/cncpt/process-architecture.html)).
- *Là où Oracle gagne* : tout ce qu'a un serveur mûr : beaucoup de writers, le clustering, la réplication, le
  partitionnement, SQL.

### Datomic

Le parent le plus proche. « An atomic fact in a database, composed of entity/attribute/value/transaction/added »
([glossary](https://docs.datomic.com/glossary.html)) : le fait de Cepheus est le même triplet, son groupe la
transaction, son journal les drapeaux ajouté et retiré.
- *Pareil* : un seul writer. « At any moment in time, a running database has exactly one transactor » (Datomic Pro), et
  « Writes are strong serializable because they are fully serialized »
  ([ACID](https://docs.datomic.com/transactions/acid.html)). Des valeurs de base de données qui ne changent pas :
  « because databases are immutable, any number of processes can have copies of the data to serve read loads ». Un état
  temporaire : « The result of calling 'with' is a database value as-if the data was applied in a transaction, but the
  durable database is unaffected » ([client API](https://docs.datomic.com/client-api/datomic.client.api.html)) : le
  `fork` de Cepheus. Une écriture conditionnelle : `:db/cas` « takes four arguments: an entity id, an attribute, an
  expected current value, and a new value »
  ([transaction functions](https://docs.datomic.com/transactions/transaction-functions.html)) : l'`Expect` de Cepheus,
  qui déclare aussi une absence (`None`) et peut apparaître plusieurs fois dans un même groupe.
- *Différent* : « Datomic maintains four indexes », couvrants
  ([index model](https://docs.datomic.com/indexes/index-model.html)) : EAVT, AEVT, AVET, VAET. Cepheus garde deux
  ordres : par chose (EAVT) et par propriété puis valeur (AVET, qui donne aussi VAET pour les liens) ; des numéros de
  chose denses font du premier un tableau. Datomic interroge le passé (« as-of », « since », « history »,
  [filters](https://docs.datomic.com/cloud/time/filters.html)) ; Cepheus garde chaque groupe dans son journal mais ne
  peut pas encore interroger le passé. Les requêtes de Datomic sont en Datalog, ses règles des ensembles de clauses
  passés à une requête et évalués avec elle ; les questions de Cepheus sont des requêtes conjonctives auxquelles répond
  un worst-case optimal join, et ses règles ([règles](rules.md)) sont du Datalog tenu matérialisé par le writer : une
  question lit les faits dérivés comme des faits, une écriture paie leur dérivation.
- *Là où Datomic gagne* : le voyage dans le temps, des règles récursives évaluées à la question (aucune mémoire pour les
  faits dérivés, aucun coût à l'écriture), un modèle de cache par peer au-dessus d'un stockage distribué.

### RocksDB

- « It is a C++ library to store keys and values »
  ([overview](https://github.com/facebook/rocksdb/wiki/RocksDB-Overview)), « embeddable » : un LSM-tree, « new writes
  are inserted into the memtable and are optionally written to the logfile », et « When the memtable fills up, it is
  flushed to a sstfile ». « Level Style Compaction (default) » ; la compaction en tiers est « termed Universal in the
  code » ([compaction](https://github.com/facebook/rocksdb/wiki/Compaction)).
- *Pareil* : le group commit (« The thread gets to the head of the queue becomes write batch group leader and
  responsible for writing to WAL and memtable for the batch group »,
  [pipelined write](https://github.com/facebook/rocksdb/wiki/Pipelined-Write)) ; `bytes_per_sync`, que copie le merge de
  Cepheus ([IO](https://github.com/facebook/rocksdb/wiki/IO)).
- *Write amplification* (le nombre de fois qu'un octet est réécrit) : « Write amplification is the ratio of bytes
  written to storage versus bytes written to the database » ; l'exemple détaillé du guide de réglage donne
  « approximately 1 + 2 + 10 + 10 + 10 = 33 », et « the usual write amplification of leveled compaction [...] is often
  larger than 10 » ([tuning guide](https://github.com/facebook/rocksdb/wiki/RocksDB-Tuning-Guide),
  [leveled compaction](https://github.com/facebook/rocksdb/wiki/Leveled-Compaction)). Cepheus fait aussi du leveling,
  avec un ratio de 4 plutôt que le défaut de 10 de RocksDB (`max_bytes_for_level_multiplier`) : 5,8 écritures par fait
  pour son chargement de 10 M, d'après son propre compte ([théorie](theory.md#9-niveaux-sur-disque-et-grands-groupes)).
  Un merge de Cepheus écrit d'un coup tout un run du niveau cible ; RocksDB découpe chaque niveau en fichiers de
  quelques dizaines de MB et en compacte quelques-uns à la fois, si bien qu'une compaction est courte quelle que soit la
  taille du niveau.
- *Là où RocksDB gagne* : la compaction par fichiers (des merges courts à chaque niveau), les Bloom filters, la
  compression, les column families, des années de production ; des transactions des deux sortes (« Optimistic
  Transactions do not take any locks [...] they rely on doing conflict-detection at commit time »,
  [transactions](https://github.com/facebook/rocksdb/wiki/Transactions)). RocksDB n'a pas de langage de requête : les
  joins de Cepheus devraient être écrits à la main au-dessus.

### Neo4j

- « Neo4j is a native graph database, which means that it implements a true graph model all the way down to the
  storage level » ([what is Neo4j](https://neo4j.com/docs/getting-started/whats-neo4j/)). Son blog appelle le principe
  « index-free adjacency » : « Link every data element directly to its incoming and outgoing relationships »
  ([15 rules](https://neo4j.com/blog/cypher-and-gql/15-rules-native-graph-database/)). Cepheus trouve « qui pointe vers
  t » par une recherche dichotomique dans les lignes par propriété, pas en suivant un pointeur.
- L'isolation : read-committed est le défaut, et « Explicit locking of nodes and relationships [...] allows for
  simulating the effects of higher levels of isolation »
  ([concurrent data access](https://neo4j.com/docs/operations-manual/5/database-internals/concurrent-data-access/)).
  Les groupes de Cepheus sont strictly serializable sans aucun lock.
- Les clusters : « The servers in a cluster use the Raft protocol to ensure consistency and safety »
  ([routing](https://neo4j.com/docs/operations-manual/5/clustering/setup/routing/)) ; Cepheus prévoit Raft pour la
  réplication.
- *Là où Neo4j gagne* : Cypher, les algorithmes de graphe, le clustering, l'outillage.

### FoundationDB

- « FoundationDB provides global, ACID transactions with strict serializability using optimistic concurrency »
  ([developer guide](https://apple.github.io/foundationdb/developer-guide.html)) ; « To detect conflicts, FoundationDB
  tracks the ranges of keys each transaction reads and writes », et les resolvers les vérifient au commit
  ([architecture](https://apple.github.io/foundationdb/architecture.html)).
- *Pareil* : la strict serializability, la validation optimiste ; et les tests : « Simulation is able to conduct a
  deterministic simulation of an entire FoundationDB cluster within a single-threaded process »
  ([simulation and testing](https://apple.github.io/foundationdb/testing.html)), la méthode de `test/sim.ml` de Cepheus.
- *Différent* : FoundationDB valide chaque clé et chaque intervalle qu'une transaction a lus, donc les phantoms sont
  attrapés ; Cepheus ne valide que ce que déclare `Expect`. FoundationDB « does not support transactions running for
  over five seconds », une transaction ne peut pas dépasser « 10,000,000 bytes of affected data », les clés 10 000
  octets, les valeurs 100 000 octets ([known limitations](https://apple.github.io/foundationdb/known-limitations.html)) ;
  une vue de Cepheus peut être lue aussi longtemps qu'on la garde.
- *Là où FoundationDB gagne* : plusieurs machines, la réplication, l'isolation des transactions interactives sur des
  intervalles.

### CockroachDB

- « By default, CockroachDB executes all transactions at SERIALIZABLE isolation », et il offre aussi READ COMMITTED
  ([transactions](https://docs.cockroachlabs.com/docs/stable/transactions)). L'espace des clés « is divided into
  contiguous chunks called ranges », chacune « replicated to at least 3 nodes by default », chacune un groupe Raft
  ([overview](https://docs.cockroachlabs.com/docs/stable/architecture/overview),
  [replication layer](https://docs.cockroachlabs.com/docs/stable/architecture/replication-layer)). « CockroachDB uses
  the Pebble storage engine », qui « uses a Log-structured Merge-tree (LSM) », et « multi-version concurrency control
  (MVCC) » avec des « hybrid logical clock (HLC) timestamps »
  ([storage layer](https://docs.cockroachlabs.com/docs/stable/architecture/storage-layer)).
- *Là où CockroachDB gagne* : il tourne sur plusieurs machines et survit à la perte de l'une d'elles ; SQL. Cepheus
  tourne sur une seule.

## Pour aller plus loin

Berenson et al. 1995 et Fekete et al. 2005 pour la snapshot isolation et le write skew ; Kung et Robinson 1981 pour la
validation optimiste ; Raasveldt et al. 2018 pour des benchmarks équitables ; Zhou et al. 2021 pour FoundationDB ; Luo
et Carey 2020 pour les LSM-trees. Les entrées complètes : [références](references.md).
