# Comment marche Cepheus

Le moteur, partie par partie : ce qu'est chaque partie, pourquoi elle est construite ainsi, et ce qu'elle coûte. Le
modèle qu'il sert est dans les [concepts](concepts.md) ; les promesses dans les [garanties](guarantees.md) ; les preuves
et les mathématiques dans la [théorie](theory.md) ; les octets dans les [formats](formats.md). Les chiffres viennent des
[benchmarks](benchmarks.md) (un portable, Intel i7-4720HQ, un SSD SATA grand public, btrfs ; 10 millions de faits).

```text
client threads              the writer's domain                                  the disk
write db ops ─► queue ─► writer: resolves a batch on the working view
                         (types, new ids, one value, unique, Expect)
                                │ the batch's groups, encoded
                                ▼
                         syncer: one frame, pwrite, fsync ─────────────────► DIR/journal/<n>.seg
                                │
                                ▼
                         publishes the new view (one atomic store), wakes the clients of that frame

readers: view db ─► a view = the runs (pages of run files, through the cache), newest first + the delta (persistent maps)

a merge domain: the delta and the newest runs, merged in order ─► DIR/snapshots/<lo>-<hi>.run.tmp ─ fsync, rename ─►
                one run, at the first level that holds them all; the runs it replaced are removed
```

## Le journal : un write-ahead log

Un **write-ahead log** (WAL) est un fichier où chaque changement est écrit, et rendu durable, avant de compter : après
un crash, la base le rejoue et ne perd rien de ce qui a été confirmé. Le log de Cepheus est le **journal** : un par
base, en fichiers de **segment** d'au plus 64 MiB (`DIR/journal/<first group>.seg`), auxquels on ne fait jamais
qu'ajouter. C'est un redo log (un log qu'on rejoue vers l'avant) de changements résolus : chaque groupe est écrit une
fois, déjà vérifié et résolu (un `Add` qui a remplacé une valeur est écrit comme un retrait et une addition), et rien
n'est jamais défait ; la recovery (la relecture du journal à l'ouverture, qui rebâtit l'état après un crash) ne fait
donc qu'appliquer les groupes dans l'ordre.

**Durable** veut dire sur le disque lui-même, pas dans la mémoire du système d'exploitation. Un appel système `write` ne
fait que copier des octets dans le **page cache** (la copie des fichiers que le noyau garde en mémoire) ; **fsync**
demande au noyau de mettre les octets d'un fichier sur le disque, et revient quand ils y sont. Un crash du processus
garde ce que tient le page cache ; une coupure de courant, non. Sur la machine de test, un fsync prend environ 3 ms :
environ 340 fsync par seconde.

**Frames.** Le journal est une suite de **frames**. Une frame est l'unité d'une écriture et d'un fsync : un en-tête de
28 octets (un nombre magique, la longueur du corps, son premier groupe, le nombre de groupes, le CRC du corps, le CRC de
l'en-tête), le corps (les groupes), et un trailer de 16 octets (une fin de frame) qui répète la longueur et les deux
CRC. Une frame ne tient que des groupes entiers : un groupe est donc dans une frame ou dans aucune. Un groupe est codé
en **colonnes** (format de journal 2) : ses textes une fois chacun, puis les sortes, les choses et les valeurs de ses
changements, chacune comme une colonne de nombres en blocs de 128, chaque bloc en frame of reference (une base et une
largeur en bits) ou en deltas (les différences d'une valeur à la suivante), selon ce qui est le plus court ; les
changements gardent leur ordre. Un chargement de 10 M de faits prend 21,6 MB de journal, là où le codage changement
par changement du format 1 prenait 94 MB ([formats](formats.md#un-groupe)).

**CRC.** Un **cyclic redundancy check** (CRC) est un court checksum calculé sur un bloc d'octets : si un
octet du bloc change, le CRC calculé à nouveau diffère, sauf avec une probabilité minuscule. Cepheus utilise CRC-32C (le
polynôme de Castagnoli, Castagnoli et al. 1993, celui d'iSCSI, RFC 3720) : il détecte toute erreur en rafale (burst :
des bits faux qui se suivent) d'au plus 32 bits, toute erreur d'au plus 3 bits dans des frames de taille réaliste, et
laisse passer les autres dommages aléatoires avec une probabilité $2^{-32}$
(Koopman 2002). L'en-tête, le corps et chaque page d'un fichier de run en portent un. Le processeur le calcule : x86-64
a une instruction pour ce polynôme précis (`crc32`, qui fait partie de SSE4.2), arm64 en a deux (`crc32cx` pour 8
octets, `crc32cb` pour un). OCaml ne sait pas les émettre ; un petit fichier C le fait donc (`src/crc32c_stubs.c`),
derrière le module OCaml `Crc32c`, à 9,4 GB/s sur une page de 16 KiB ici au lieu de 1,17 pour le code à table en OCaml
qu'il a remplacé, 8 fois plus vite ([benchmarks](benchmarks.md#crc-32c-par-le-processeur-2026-11-08)).

**Group commit.** Un fsync coûte autant pour un groupe que pour mille ; les groupes qui arrivent pendant qu'un fsync
tourne attendent donc ensemble et partagent le suivant : c'est le **group commit**. Le writer travaille en deux étages,
dans un domain à lui (un domain : un fil d'exécution d'OCaml qui tourne en parallèle sur son propre cœur) : un thread
*writer* résout les écritures en attente (jusqu'à 4 096 à la fois) sur la **working view** (la vue de travail : l'état
avec chaque groupe résolu, durable ou non) ; un thread *syncer* écrit le lot comme une seule frame (`pwrite`), la force
sur le disque (`fsync`), puis publie la nouvelle vue et ne réveille que les clients de cette frame. Pendant que le
syncer force une frame, le writer résout les lots suivants et les fusionne dans la frame qui attend, jusqu'à ce
qu'elle tienne 8 MiB. Avec $N$ clients qui écrivent un groupe à la fois et un fsync de $f$, le débit approche $N / (1{,}5 f)$ groupes par
seconde, jusqu'à ce que le writer peut résoudre ([théorie](theory.md#2-group-commit)). Mesuré : 181 groupes par
seconde pour 1 client, 7 147 pour 64, 14 141 à 17 192 pour 256 (le disque est la limite ; les insertions de PostgreSQL
sont au même niveau).

## La recovery : torn writes et dommages

La **recovery** est ce que fait une ouverture après un crash : elle rebâtit l'état à partir des runs sur disque et du
journal après le plus récent d'entre eux. Elle lit les frames dans l'ordre et vérifie les CRC de chacune ; tout ce qui
précède la première frame qui ne se vérifie pas est appliqué. La question est de savoir ce qu'est cette mauvaise frame :

- un **torn write** : la frame était en cours d'écriture quand le courant a coupé, et seule une partie a atteint le
  disque. Elle n'a jamais été confirmée (un client reçoit sa réponse après le fsync) ; la recovery la coupe donc
  (tronque le fichier à son début, et force la coupe) ;
- un **dommage** : des octets autrefois durables ont changé (un disque qui lâche, une mauvaise copie). Les laisser
  tomber perdrait des groupes confirmés en silence ; la recovery refuse donc d'ouvrir, avec `Damaged` qui nomme le
  fichier et l'offset (la position en octets dans le fichier).

On distingue les deux par deux signes que la frame a été écrite en entier : un en-tête de frame valide après elle (une
frame n'est écrite qu'une fois la précédente forcée, donc une frame plus tardive prouve que celle-ci était complète), ou
un trailer à la bonne distance dont le CRC correspond au corps (seul l'en-tête a changé). L'un ou l'autre signe veut
dire dommage ; aucun des deux veut dire une fin torn. Un torn write ne peut imiter un signe que si le disque a perdu le
seul secteur de l'en-tête et gardé le reste, ce qui demande un disque qui réordonne ses écritures de secteurs : la base
refuse alors d'ouvrir alors que rien de confirmé n'a été perdu (une fausse alarme, jamais une perte). Le test exhaustif
de tous les états de crash de petits journaux ne trouve aucune fausse alarme en pratique.
Un cas ressemble à une fin torn et n'en est pas une : un dommage dans la frame la plus récente, sans rien après elle,
est coupé comme torn ; une lecture complète (`Cepheus.verify`) le signale.

**Ce qu'a laissé un processus tué.** Un processus tué entre le `pwrite` d'une frame et son fsync laisse la frame dans le
page cache : le processus suivant la lit, mais une coupure de courant ultérieure la reprendrait. La recovery écrit donc
d'abord à nouveau la frame la plus récente du journal et force le segment le plus récent et le répertoire du journal,
et une ouverture force le répertoire de la base, avant que quoi que ce soit repose sur ce qu'ils tiennent ; sauf après
une **fermeture propre** (clean close), qui laisse un fichier marqueur (`DIR/closed`) une fois que tout est durable,
pour que l'ouverture suivante puisse sauter ces fsyncs (PostgreSQL garde le même état « shut down » dans `pg_control`).

**Un fsync qui échoue.** Quand un fsync échoue, Linux marque les pages qu'il n'a pas pu écrire comme clean (identiques
au disque) alors qu'elles ne l'ont jamais atteint : ext4 et XFS gardent leurs nouveaux octets en mémoire, si bien qu'un
fsync ultérieur réussit sans les écrire et que toutes les lectures jusqu'à un redémarrage voient une frame que le
disque ne tient pas (Rebello et al., USENIX ATC 2020). Deux règles font du disque la vérité (G13). Le writer s'arrête au
premier échec et ramène le journal à la fin de sa dernière frame durable (il tronque le fichier là et le force) :
l'écriture qui a échoué disparaît donc de la mémoire comme du disque. Et la réécriture ci-dessus : la frame la plus
récente est écrite à nouveau à chaque recovery après autre chose qu'une fermeture propre, ce qui rend ses pages dirty
(modifiées en mémoire, pas encore écrites) à nouveau, pour que le fsync qui suit les écrive vraiment ; c'est la seule
frame qui peut manquer au disque, puisque le writer force chaque frame avant la suivante et s'arrête au premier échec.
La réécriture coûte un `pwrite` de la frame la plus récente (au plus 8 MiB) à une ouverture après un crash, rien sur le
chemin des écritures.

**Lire à travers une fenêtre.** La recovery lit chaque segment à travers une fenêtre de 4 MiB : une frame qui y tient
est vérifiée et décodée là où elle se trouve ; une plus longue (la frame d'un grand groupe dépasse 100 MB) est vérifiée
par son CRC morceau par morceau, et lue en entier seulement quand ses groupes doivent être rejoués. Une frame dont les
runs tiennent déjà les groupes est vérifiée et pas décodée. L'en-tête de 40 octets du segment est lu à part, et la
fenêtre commence là où commence le parcours (après un snapshot, souvent la fin du segment). Ainsi,
une ouverture tient la fenêtre et la plus grande frame qu'elle doit rejouer, quelle que soit la taille du segment : la
base que laisse un chargement de 10 M (son segment le plus récent fait 94 MB) s'ouvre en 165 à 207 ms avec 54 à 56 MB
résidents, sous une limite de 128 MB.

## Les index : les runs et le delta

Une vue, c'est deux choses :

- les **runs** : les faits à la date des derniers merges, triés et **compressés**, dans des fichiers sur disque lus à
  travers le cache, les plus récents d'abord (un run : une copie triée de l'état, dans un fichier ; un merge : la fusion
  de runs triés en un seul). Un run tient les changements d'un intervalle de groupes par-dessus les runs en dessous de
  lui, en deux **parties** : les faits qu'il ajoute (partie a), et les faits des runs en dessous qu'il retire (partie t,
  vide dans le bottom run, le run du fond). Dans chaque partie, par chose, une **rank table** dit quelles choses la
  partie tient : un mot de 64 bits pour 32 numéros de chose, avec un bit de présence pour chacune et le compte des
  choses tenues avant elles ; le slot (la place) de la chose e est donc ce compte plus les bits à 1 sous celui de e (un
  mot lu et une population count, le compte des bits à 1, en une instruction). Les slots vont par 128 dans des **thing
  blocks** (des blocs de choses) : une propriété que chaque chose du bloc a au plus une fois est un champ du record de
  chaque chose (le record : les valeurs d'une chose ; pour une facture, son client, sa date, son statut et son total),
  toute autre est une petite colonne du bloc (les offsets et les valeurs de ses choses) ; chaque valeur est sa
  différence avec la plus petite valeur de la propriété dans le bloc, en aussi peu de bits que le bloc en demande (un
  **frame of reference** : une base et une largeur en bits, si bien que toute valeur se lit sans décoder ses voisines).
  Par propriété, les lignes (valeur, chose) de p sont triées par valeur puis par chose et coupées en
  blocs de 128 lignes codés de la même façon ; la plupart des propriétés ont aussi un **value index** (une rank table
  sur les valeurs que prend la propriété, et la première ligne de chacune) : « les choses dont la ville est Lyon »,
  « les factures qui pointent vers le client c » coûtent un rank et deux offsets, et les intervalles de valeurs sont
  une recherche dichotomique. Les textes et les flottants sont numérotés par un **dictionnaire** (chaque texte distinct
  rangé une fois, trouvé par une hash table ; les lignes tiennent son numéro) ; toute autre valeur est son propre
  numéro. Un troisième ordre, le **column order** (format de run 8), garde à part les lignes (chose, valeur) de chaque
  propriété, dans l'ordre des choses, avec une rank table sur ses choses (une pour les propriétés que tiennent les
  mêmes choses) et des offsets seulement à partir de sa première chose à plusieurs valeurs : toute recherche d'une
  propriété d'une chose lit là (un mot de rank, une entrée de répertoire, un champ) ; une question sur quelques
  propriétés ne lit donc que leurs octets, tandis que « tous les faits d'une chose » lit son bloc. Un run fait environ 7
  octets par fait à 10 M de faits, dictionnaire et column order compris
  (le format 6 en prenait 24,6 : [formats](formats.md#run-dirsnapshotslo-20-digits-hi-20-digitsrun)) ;
- le **delta** : les changements depuis le dernier merge, dans des **persistent maps** (des arbres équilibrés qui ne
  sont jamais modifiés sur place : un changement fait une nouvelle version qui partage avec l'ancienne chaque nœud non
  touché, pour un coût de $O(\log d)$ pour $d$ changements). Le delta est rangé comme un run (par chose, puis propriété et
  valeur ; par propriété, puis valeur et chose) et garde des comptes exacts à côté de chaque map. Il coûte environ 170
  octets par changement.

Un fait est dans une vue quand son entrée la plus récente (celle du delta, ou celle du run le plus récent qui en a une)
l'ajoute. Chaque run est **net** : il n'ajoute que des faits absents en dessous de lui et ne retire que des faits
présents en dessous de lui ; un compte est donc une somme de comptes exacts (les additions de chaque run moins ses
retraits, plus ceux du delta). Une lecture cherche dans le delta et dans chaque run qui peut tenir la clé, par
recherche dichotomique, jamais par le parcours d'une liste ; une ligne d'un run plus ancien n'est montrée que si aucun
run plus récent n'a d'entrée pour le même fait, ce à quoi les rank tables répondent par quelques tests de bits, sauf si
un run plus récent tient la même chose. Comme le delta est persistant et que les runs ne changent jamais, une vue est
une valeur : en garder une ne coûte rien, et un fork (un état temporaire qui part d'une vue, où l'on écrit sans rien
écrire sur le disque) est une vue avec son propre delta. Lire les faits d'une facture par son numéro prend environ
0,4 µs à 10 M de faits sur un seul run
([benchmarks](benchmarks.md#runs-et-journal-compressés-2026-11-09-à-10-millions-de-faits)) ; sur les deux runs que
laisse un chargement, les joins qui lisent les deux coûtent plus (Q3, Q4), et `snapshot` refait un seul run.

## Les runs sur disque

Un **fichier de run** tient un run : `DIR/snapshots/<lo>-<hi>.run` (20 chiffres chacun) tient les changements des
groupes lo+1 à hi par-dessus l'état à lo ; un run avec lo = 0 est un **bottom run**, tout l'état à hi. Un fichier est
un en-tête de 4 KiB (les groupes, le niveau, la position du journal où le replay doit reprendre, l'endroit où commence
chaque section), les pages de 16 KiB qui tiennent des octets, et une **page table** : pour chaque page de la
disposition du run, la page du fichier qui la tient et son CRC-32C. Un merge dispose un run selon des bornes
supérieures de ses sections (il ne connaît ses comptes qu'à la fin) ; la plus grande partie de la disposition est donc
de la place jamais écrite ; la page table permet au fichier de ne tenir que les pages écrites, dans l'ordre où le merge
les a finies (le bottom run de 10 M de faits : 54,4 MB de fichier pour 1 118 MB de disposition). Les runs d'une base
forment une **chaîne** depuis 0 : chacun repose sur le groupe où finit celui d'en dessous. Les runs sont des caches du
journal : ils épargnent à un redémarrage le replay (la relecture des groupes) de tout ce qui les précède, et on peut
toujours les reconstruire à partir du journal. Un run est le format en mémoire, lu sur place, une valeur décodée là où
on en a besoin (il ne vaut que pour les machines 64 bits little-endian ; le journal est le format portable). À
l'ouverture, Cepheus prend la chaîne de runs nommés depuis 0 qui atteint le groupe le plus récent avec le moins de runs,
et vérifie chaque run : l'en-tête, la page table, les rank tables, l'ordre et les bornes de chaque table d'offsets ; un
run qui tient dans le cache est lu et vérifié en entier avant la première question ; pour un plus grand, les pages de
ses tables sont lues et vérifiées à l'ouverture, celles de ses lignes à mesure que les questions en ont besoin. Un
run qui ne se vérifie pas est mis de côté (noté, sauté) et la chaîne est choisie à nouveau sans lui, jusqu'au journal
seul. Aucun run n'est gardé hors de la chaîne : le journal tient chaque groupe, donc un run endommagé coûte un replay,
jamais un fait. Les runs des formats plus anciens (format 4, `<group>.snap`, toute la base dans un fichier ; formats 5
et 6, des mots fixes de 8 octets) sont mis de côté à la première ouverture et le journal est rejoué une fois
([formats](formats.md)).

## Les merges : un log-structured merge-tree à leveling

Un **log-structured merge-tree** (LSM-tree, O'Neil et al. 1996) garde les écritures récentes dans une petite structure
en mémoire et les déplace en bloc dans de grandes structures triées sur disque, en fusionnant des runs triés au lieu
de modifier des pages sur place. Ses **composants** sont la partie en mémoire et les runs sur disque ; déplacer des
données de l'un au suivant est un **merge**, qu'on appelle aussi **compaction**. Un **level** (un niveau) est une place
dans l'arbre avec une capacité ; le **size ratio** $T$ dit combien de fois chaque niveau est plus grand que celui du
dessus. Le delta de Cepheus est le niveau 0 ; ses runs sont aux niveaux 1, 2, 3, ... ; le niveau $l$ tient au plus
$200\,000 \times 4^l$ lignes (800 000, 3,2 M, 12,8 M, ...).

**Leveling.** Sous **leveling**, chaque niveau tient un seul run ; sous **tiering**, jusqu'à T runs, fusionnés
ensemble quand le niveau est plein. Le leveling écrit plus (un fait est fusionné à nouveau chaque fois que le niveau du
dessus déborde dans le sien) et lit moins (un run par niveau) ; le tiering, l'inverse (Luo et Carey, VLDB Journal 2020 ;
Dayan et Idreos, Dostoevsky, SIGMOD 2018). Les lectures de Cepheus sont des intervalles courts (les faits d'une chose,
les choses d'une valeur) et des comptes exacts, qui visitent chaque run qui peut tenir la clé ; le nombre de runs pèse
donc autant que les écritures : leveling, avec $T = 4$
([théorie](theory.md#9-niveaux-sur-disque-et-grands-groupes)).

**Quand.** Un merge démarre quand le delta tient plus de 200 000 changements (`Engine.compact_min`). Il prend le delta
et les runs les plus récents, jusqu'au premier niveau qui peut tous les tenir, et y écrit un seul run (`Engine.plan`).
Il tourne dans un domain à lui, à côté des écritures : ses entrées sont déjà triées dans l'ordre de chaque section, donc
chaque section du nouveau run est une seule passe avec un curseur dans chacune, sans tri : la ligne suivante de l'ordre
par propriété vient d'un binary heap (un tas binaire, qui donne toujours son plus petit élément) des curseurs rangés
par leur tête (valeur, chose), $O((n + d) \log k)$ étapes pour $k$ runs fusionnés (Knuth 1998, 5.4.1 : un merge à
$k$ voies), et il déverse
le résultat dans `<lo>-<hi>.run.tmp`, page par page : une page de 16 KiB part (son CRC, un `pwrite` à sa place, le
cache) dès que ses octets sont écrits. Puis la table des CRC, l'en-tête, un fsync. Pendant ce temps, le writer note les
groupes qu'il résout ; le merge les rejoue sur les nouveaux runs jusqu'à n'avoir plus que moins de 256 groupes de
retard ; le writer attend alors que le syncer soit inactif (au plus un fsync), rejoue le reste, renomme le fichier à
son nom, force le répertoire, supprime les runs qu'il a remplacés, et bascule les deux vues sur les nouveaux runs en
une seule écriture atomique. Un crash à n'importe quel moment laisse les runs d'avant ou les runs d'après, entiers
(G12). `snapshot` est le seul merge complet : le delta et tous les runs en un seul run.

**Les grands groupes : en tiering à leur niveau (lazy leveling).** Un chargement écrit en beaucoup de grands groupes
(quelques centaines de milliers de faits chacun : plus bas) fusionnerait, sous le leveling, le run de chaque groupe avec
ceux d'avant lui, niveau après niveau : un fait est réécrit chaque fois que son niveau déborde, environ une fois par
niveau. Donc le run d'un grand groupe ne prend que le delta et les runs les plus récents des niveaux en dessous de
celui qui le contient, et reste à côté des runs de ce niveau, ceux des grands groupes d'avant lui (du tiering à ce
niveau : le lazy leveling de Dayan et Idreos, du tiering à un niveau et du leveling ailleurs, Dostoevsky 2018), tant
qu'il n'y en aurait pas 16 (`Engine.tier`) côte à côte : alors le merge de ce groupe les prend tous, comme le ferait
`Engine.plan`, en une seule passe à $k$ voies. Un chargement écrit alors chaque fait environ deux fois (le run de son
groupe, le merge des runs côte à côte, puis `snapshot`), et les lectures pendant qu'il tourne visitent jusqu'à 16 runs
de ce niveau ; une fois les écritures arrêtées, le writer les fusionne (plus bas), et un `snapshot` après un
chargement ramène tout à un. Les runs ne sont jamais plus de 16 plus un par
niveau, bien en dessous des 31 qu'un merge peut prendre (`Snapshot.max_take` : le passage par chose garde les sources
d'une chose dans les bits d'un entier, deux par run). À 10 millions de faits en groupes de 5 000 clients (environ
415 000 faits chacun) écrits par deux threads, chaque groupe est confirmé en 9,8 s au lieu de 18,2, et avec le
snapshot qui suit, le chargement prend 13,0 s au lieu de 21,9
([benchmarks](benchmarks.md#les-chargements-par-morceaux-2026-11-12-à-10-millions-de-faits)).

**Un writer au repos fusionne les runs côte à côte.** Le lazy leveling garde les écritures d'un chargement à environ
deux par fait, mais ses lectures paient chaque run côte à côte tant qu'il n'y en a pas 16, ce qu'un chargement de
quelques groupes n'atteint jamais : le seed de l'application de factures laissait 5 runs d'environ 480 000 lignes
chacun, et chaque recherche dans l'index les visitait tous (sa page triée de factures prenait 120 µs en OCaml, 64 sur
les mêmes faits en un seul run). Donc chaque seconde, l'horloge du serveur demande à chaque writer (`Engine.tidy`) :
quand aucun groupe n'est venu depuis la seconde d'avant, qu'aucun merge ni changement des règles ne tourne, et qu'un
niveau tient deux runs ou plus, le writer fusionne le delta et les runs les plus récents, jusqu'au dernier run de ce
niveau, dans le premier niveau qui les contient (`Engine.plan_tier`), en arrière-plan comme un merge du delta (les
2,4 millions de lignes du seed en environ 0,65 s ici). Un writer occupé ne le lance jamais (les runs côte à côte
attendent alors le prochain merge du delta, qui les prend) ; une base d'un run par niveau non plus : il tourne une fois
après un chargement. Après un merge qui a échoué (un disque plein), il attend les `compact_min` changements suivants du
delta, comme ces merges-là, pour qu'un disque plein ne voie pas un merge par seconde. Le leveling est le bout du
compromis le plus rapide pour les lectures (Dayan et Idreos, Dostoevsky, SIGMOD 2018), et un writer qui n'a rien à écrire n'a rien à échanger.

**Mémoire.** Un merge a besoin du cache, de quelques buffers de page (des zones de mémoire de travail : au plus 2 pour
chaque flux d'une passe ; 19 mesurés dans le test unitaire, dont la borne est 24) et de 25 octets pour chaque 16 KiB de
la disposition du nouveau run (3,1 % du run de 10 M, dont la disposition codée est lâche ;
[théorie](theory.md#8-merges-écrits-dans-un-fichier)) : avec un cache
de 32 MB, un merge de toute la base de 245 MB a tourné dans un processus limité à 128 MB (pic de 99 MB).

La **write amplification** est le nombre de fois qu'un fait est écrit sur le disque pour chaque fois qu'un client
l'écrit. Sous leveling avec le ratio $T$, un fait est écrit environ $(T + 1)/2 = 2{,}5$ fois par niveau où il entre (il entre dans
un niveau à l'un des $T$ merges qui le remplissent, et est écrit à nouveau à chacun des suivants), et les niveaux qu'un
merge saute ne coûtent aucune écriture de plus : pour le chargement de 10 M des benchmarks, 5,8 écritures par fait,
contre 14,5 avec le niveau unique des versions précédentes (dont les merges réécrivaient toute la base à chaque fois :
jusqu'à 17 faits par changement). La **read amplification** est le nombre de runs qu'une lecture visite : au plus 3 à
10 M de faits (2,1 en moyenne sur ce chargement). La **space amplification** (la place sur disque rapportée à la
taille des données) : la chaîne seule après un merge, et pendant un merge complet une nouvelle copie de la base à côté
de l'ancienne : prévoir environ deux fois la base pour `snapshots/` pendant qu'il tourne.

**Ce que cela coûte aux écritures.** Les écritures d'un merge font concurrence aux fsyncs du journal, que chaque client
attend. Pendant que des clients écrivent, un merge force son fichier tous les 8 MiB (comme le fait le `bytes_per_sync`
de RocksDB), pour qu'aucun fsync du journal ne fasse la queue derrière des centaines de mégaoctets de dirty pages d'un
merge ; un merge que personne n'attend (`snapshot`, recovery) force une seule fois. À 256 clients, un merge écrit un
niveau de quelques centaines de milliers de faits (0,3 s) là où le niveau unique réécrivait la base (3,7 s) : le même
débit (celui du disque, 18 252 groupes par seconde), un pic de 762 MB contre 1 040. Charger 10
M de faits à raison d'un groupe par client prend 112 s contre 157 s avec un seul niveau, une durée bornée par les
fsyncs du journal et les écritures des merges qui se partagent le disque.

## Grands groupes

Un chargement est le même `write`, en quelques grands groupes. Un groupe de 20 000 opérations ou plus, toutes des
`Add`, prend un chemin plus rapide vers le même résultat à l'intérieur du writer (`Resolve.resolve_large`). Ses faits ne
deviennent jamais des persistent maps : ils vont dans des tableaux compacts, y sont triés, et sont fusionnés d'un coup
avec le delta et les runs les plus récents dans un fichier de run, comme une entrée triée de plus. L'essentiel du
travail est partagé entre plusieurs **domains** (l'unité de parallélisme d'OCaml : un domain tourne sur son propre
cœur ; `Bulk.domains`, 4 ici, un par cœur), en **chunks** (morceaux) de 65 536 opérations (`Bulk.chunk`) que les
domains prennent à tour de rôle à un compteur partagé, pour qu'un domain qui tombe sur des chunks lents en prenne moins
(le morsel-driven scheduling de [Leis 2014]) :

1. **Traitement.** Un seul parcours de la liste trouve la première cellule de chaque chunk. Les faits de chaque chunk
   vont à leur propre place dans trois tableaux : la chose (4 octets), la propriété (2) et le mot d'index de la valeur
   (8), 14 octets par fait, dans des **Bigarrays** (de la mémoire hors du tas que gère le garbage collector, la partie
   qui libère la mémoire que plus rien n'utilise : il ne les parcourt, ne les copie et ne les déplace jamais, là où un
   tableau OCaml coûte 8 octets par champ et est parcouru par chaque collection majeure). Chaque chunk cherche ses
   textes dans la vue et liste ceux qui sont nouveaux, dans l'ordre où il les rencontre.
2. **Numérotation.** Une passe dans l'ordre du groupe donne leurs numéros aux nouvelles choses, et les leurs aux
   nouveaux textes, dans leur ordre de première utilisation, exactement comme `Resolve` les numérote (les premières
   utilisations d'un chunk viennent avant celles du chunk suivant) ; les chunks sont ensuite réécrits avec les numéros
   définitifs, là encore sur plusieurs domains.
3. **Tri.** Par chose : un groupe dans l'ordre (chose, propriété, valeur), comme un chargeur écrit ensemble les faits
   d'une chose, n'a besoin d'aucun tri (vérifié sur plusieurs domains) ; tout autre reçoit une permutation, par un radix
   sort stable (un tri chiffre par chiffre) de ses index par chose et un tri par insertion par (propriété, valeur) à
   l'intérieur de chaque chose. Un fait en double, ou déjà là, est écarté (aucun changement), dans l'ordre du groupe. Par
   propriété : un counting sort (un tri par comptage) en chunks répartis d'un coup, chacun depuis sa propre place, puis un
   radix sort stable par chiffre de poids faible d'abord (least significant digit), par valeur à l'intérieur de chaque
   propriété (des chiffres de 11 bits, [Knuth 1998], 5.2.5), les plus grandes propriétés d'abord sur 2 domains, chaque
   passe d'un buffer à l'autre (aucune recopie en retour).
4. **Écriture.** Le groupe reçoit une frame à lui. Sa place est prise à la fin du journal (`Journal.begin_frame`, avec
   sa longueur exacte, calculée à l'étape 3), et pendant que le writer fusionne les faits dans le fichier de run, un
   autre domain code le groupe et écrit le corps de la frame par morceaux de 1 MiB, en les forçant tous les 32
   MiB (`Journal.force_every`), pour que le disque écrive la frame pendant que le run se fait. Le commit écrit ensuite
   l'en-tête et le trailer de la frame et force la frame, pendant qu'un autre domain force le run (deux fsyncs à la
   fois, sur deux fichiers), et ne nomme le run qu'une fois les deux finis (G12). Les pages du run n'entrent pas dans
   le cache à mesure qu'elles sont écrites (la sortie d'un chargement est lue plus tard, depuis le fichier, page par page
   selon les besoins des questions) : le cache ne tient pas pour personne une seconde copie d'un run de centaines de MB.

Le chemin ne décide que ce qu'il peut décider seul (des additions à des choses nouvelles ou ordinaires, une valeur par
chose nouvelle pour une propriété à une seule valeur, des additions à plusieurs valeurs à des choses existantes, aucune
valeur unique déjà prise) ; au moindre doute, le groupe prend le chemin ordinaire, qui décide comme toujours, erreurs
comprises ; un fork, qui prend toujours le chemin ordinaire, répond donc comme la base (G8). Un groupe dont la frame
dépasserait 256 MiB est refusé (`Invalid`) avant tout merge. Aucun merge en arrière-plan ne tourne à côté d'un grand
groupe, et rien d'autre n'est ajouté au journal pendant que sa frame s'écrit (le writer attend la frame d'avant, et la
frame d'après attend son commit).

Ce que demande ici chaque garantie : la frame est une seule frame (G2 : tout ou rien) ; son en-tête est écrit après
chaque octet de son corps et avant son trailer, pour qu'un crash avant l'en-tête laisse des octets que la recovery coupe
comme une fin torn (G3), et un crash après une frame entière dont la recovery reconstruit le trailer, jamais un trailer
qui se vérifie derrière un en-tête manquant, que la recovery prendrait pour un dommage (G6) ; le groupe n'est confirmé
qu'après le fsync de la frame (G1) ; un échec du fichier du journal pendant l'écriture du corps arrête la base et ramène
le journal à sa dernière frame durable (G10, G13), un échec du fichier du run fait échouer le groupe seul et retire le
corps du journal (`Journal.drop`). Sur le disque simulé, le codage et le merge tournent l'un après l'autre, pour qu'une
seed (la graine qui décide de tout le hasard d'un test) rejoue les mêmes appels (`Disk.parallel`).

Mesuré : voir les [benchmarks](benchmarks.md#le-chargement-en-parallèle-et-sans-copies-2026-11-08-à-10-millions-de-faits).

## Les pages et le cache

Les runs sont lus par **pages** de 16 KiB à travers un seul cache pour le processus, celui de Cepheus (un **buffer
pool** : c'est la base, pas le noyau, qui décide quelles pages restent en mémoire). Sa taille est `set_cache` (1 GiB par
défaut). Pourquoi ne pas laisser le noyau le faire avec `mmap` : un fichier mappé change une erreur de disque en un
signal qui tue le processus, ne laisse à la base aucun mot à dire sur ce qui est évincé, et cale de façon imprévisible
au-delà de la mémoire (Crotty, Leis, Pavlo, CIDR 2022). Avec son propre cache, Cepheus vérifie chaque page contre son
CRC quand elle arrive du disque (une page endommagée n'est jamais servie, même une page endommagée après l'ouverture),
rend une erreur de disque comme une erreur, et travaille sur des données plus grandes que la mémoire.

**Une lecture** d'une page en mémoire est une lecture de tableau et une comparaison, sans lock (ce qui réserve une
donnée à un seul utilisateur à la fois), depuis n'importe quel domain : chaque base a une table de ses pages qui sont
« hot » (chaque partie d'un run a la sienne). Une page qui n'est pas hot prend le chemin lent : si elle est en mémoire,
une lecture est comptée pour la politique d'éviction et la page redevient hot ; sinon, on prend le lock du cache, on
fait de la place, la page est lue depuis son fichier, vérifiée, et publiée.

**Politique d'éviction : S3-FIFO** (Yang et al., SOSP 2023). Quand le cache est plein, une page doit partir ; la
politique décide laquelle. S3-FIFO utilise trois files first-in-first-out (FIFO : le premier entré sort le premier) :
une nouvelle page entre dans une *petite* file (un dixième de la place) ; quand elle arrive au bout, elle passe dans la
file *principale* si elle a été lue à nouveau entre-temps, et sort sinon (sa clé va alors dans une file *ghost*, pour
qu'une page redemandée bientôt aille directement dans la file principale) ; au bout de la file principale, une page lue
depuis la dernière fois que la politique l'a regardée est gardée (son compteur de 2 bits diminué), sinon elle sort. Les
pages d'un scan (un parcours complet) quittent donc la petite file sans chasser les pages lues encore et encore.
Contrairement à LRU, 2Q ou ARC, elle ne déplace rien sur un hit (un hit : la page demandée est déjà dans le cache) ; les
hits de plusieurs domains n'ont donc besoin d'aucun lock. Sur des traces enregistrées de cette base, chaque politique en
ligne essayée (LRU, CLOCK, 2Q, ARC, SIEVE, S3-FIFO, W-TinyLFU) est à moins d'un point de taux de hits des autres, et
l'optimum de Belady (évincer la page dont on aura besoin le plus loin dans le futur, ce qu'aucune politique réelle ne
peut savoir) manque environ moitié moins ([théorie](theory.md#7-les-pages-et-le-cache)).

**Coût et borne.** Quand tout est en mémoire, la page table coûte 3 à 13 % sur les joins contre la base mappée d'une
version précédente (un chargement dépendant de plus par lecture). Les pages en mémoire restent sous 1,25 fois le cache :
les pages évincées sont libérées par le garbage collector, et une collection complète tourne après chaque quart du
cache évincé. Avec un cache de 32 MB et la base de 245 MB, une ouverture prend 67 ms et 64 MB, une facture par son
numéro 41 µs (PostgreSQL 176 µs avec 32 MB de buffers).

## Un seul writer, threads et domains

Chaque base a exactement un writer (G9 : un fichier de lock, `DIR/lock`, tenu par un seul processus). Un seul writer
veut dire aucun lock entre writers, aucun deadlock (deux attentes qui se bloquent l'une l'autre), et un ordre total des
groupes sans trou, ce qui fait du journal une history (un historique) qu'on peut rejouer et répliquer
([une replica](server.md#une-replica), une copie de la base tenue à jour sur une autre machine, prend les frames de son
primary, le serveur qui reçoit les écritures, telles qu'elles sont). Son
coût : une base ne peut pas résoudre les groupes plus vite qu'un cœur (le writer résout un groupe de 5 faits en
environ 7 µs, si bien que le fsync du disque est la limite bien avant), et un groupe lent retarde les suivants. Des
bases distinctes écrivent en parallèle.

OCaml 5 exécute du code en parallèle par des **domains** : chaque domain est un fil d'exécution avec son propre cœur,
son tas pour les valeurs jeunes et son runtime lock (le lock du runtime d'OCaml) ; les **threads** (systhreads) d'un
même domain partagent ce lock et passent chacun leur tour. Cepheus met le writer et le syncer dans un domain des
writers, où ne tourne aucun thread client, pour qu'ils n'attendent jamais le runtime lock des threads clients (les bases
d'un processus partagent autant de domains des writers que la machine a de cœurs : un domain coûte cher en OCaml 5,
0,2 ms à lancer, et chacun en vie ralentit chaque collection mineure, qui les arrête tous) ; chaque merge tourne dans
son propre domain ; et une grande question (20 000 candidats ou plus pour sa première variable) les découpe en slices
(des tranches) que jusqu'à `Query.domains` domains prennent à tour de rôle (le nombre recommandé pour la machine, au plus
8 : celui de la question et les helpers du processus, garés entre deux questions, `Pool`), chacun avec son propre
accumulateur, fusionnés dans l'ordre des slices pour que la réponse ne dépende pas du nombre de domains. Un processus ne
tient jamais plus de domains que le plafond d'OCaml moins une marge : un merge ou un helper qu'il ne peut avoir tourne
sur un thread, ou la question sur moins de domains ([limites](limits.md#les-fichiers-et-la-plateforme)). Une vue n'a
besoin d'aucun lock pour être lue, ce qui rend ce découpage gratuit. La somme des impayés par ville sur 453 866 factures
prend 231 ms sur un domain et 107 ms sur trois (PostgreSQL 236 ms sur un processus, 109 ms sur trois).

## Questions

Une question est une requête conjonctive : des patterns joints sur leurs variables ([concepts](concepts.md#les-questions)).
La façon habituelle d'y répondre est un plan de **binary joins** (deux entrées à la fois, le résultat joint avec
l'entrée suivante ; un join associe les lignes de ses entrées par leurs valeurs communes). Sur une question cyclique
comme les triangles d'un graphe ($a$ suit $b$, $b$ suit $c$, $c$ suit $a$), un tel plan peut construire bien plus de lignes
intermédiaires que la réponse : pour $N$ liens, $\Theta(N^2)$ paires $a \to b \to c$ avant de vérifier $c \to a$, alors qu'il existe au plus $N^{1{,}5}$
triangles. Ce $N^{1{,}5}$ est l'**AGM bound** (la borne AGM ; Atserias, Grohe, Marx 2008) : la plus grande réponse qu'une
question peut avoir, calculée à partir des tailles de ses entrées. Un **worst-case optimal join** ne fait jamais plus de
travail que cette borne, à de petits facteurs près (Ngo, Porat, Ré, Rudra 2012).

Cepheus répond avec **Generic Join** (Ngo, Ré, Rudra 2013), le plus simple des worst-case optimal joins : fixer un ordre
des variables ; pour lier la variable suivante, prendre le pattern qui offre le moins de candidats pour elle étant
donné les variables déjà liées (des comptes exacts, lus dans les index), les énumérer, et ne garder chaque candidat que
si chaque autre pattern sur la variable l'accepte (une recherche dans un index chacun, $O(\log n)$). Sur une chaîne de
patterns, il fait ce que feraient des recherches d'index imbriquées ; sur un cycle, il reste dans la borne. L'ordre des
variables est choisi d'après les comptes : l'ordre du moindre travail estimé, par une programmation dynamique sur les
sous-ensembles de variables (Selinger et al. 1979), les champs d'une chose placés juste après elle et ceux d'une
constante en premier, jusqu'à 12 variables dans le programme, de façon gloutonne au-delà. Chaque réponse sort une seule fois (G11). Sur le graphe des follows (568 163
liens), les triangles prennent 1,03 s sur un domain et 371 ms sur trois (PostgreSQL 1,03 s et 603 ms).

## Règles

Une règle dérive des faits à partir de faits (Datalog, un langage de règles logiques) ; le writer garde les faits
dérivés dans la vue, comme des faits, à chaque groupe : après les changements affirmés du groupe, ses retraits sont
tranchées par Backward/Forward et ses additions font tourner les règles par semi-naive evaluation (l'évaluation qui, à
chaque tour, ne joint que les faits nouveaux du tour précédent), dans un working set (un ensemble de travail) de
tableaux hors de la vue du collector ; les changements dérivés rejoignent la frame du groupe avec un octet de sorte
(2 à 5) et la vue en un seul lot trié. Le replay les applique et n'évalue rien. Dans un run, la valeur d'un fait porte
un drapeau « seulement dérivé » dans le bit le plus bas de son champ, dans les blocs qui tiennent un fait dérivé
(formats 7 et 8 ; le format 6 utilisait le bit 63 d'un mot de valeur). Un grand groupe avec des règles raisonne sur ses
propres faits, tenus comme un préfixe trié du working set (pas de chaînes de hachage : les faits d'une chose sont un
intervalle, les choses d'une valeur un intervalle de l'ordre du groupe par propriété), dérive ses tours sur un domain
par thread matériel (`Bulk.threads` : ses recherches attendent la mémoire, ce que cache le second thread d'un cœur), et
fusionne les faits dérivés dans les deux ordres de ses tableaux, écrits avec eux dans le run. Les règles sont compilées
en deux programmes par ensemble de règles : tel qu'il est écrit, et déplié sur les petites relations de la base
(réécrit en une règle par fait de ces relations ; gardé en cache tant que la vue tient les faits de ces relations,
vérifié à chaque groupe par identité) ; un groupe fait tourner le programme déplié sauf s'il change une relation
figée. Les plans d'une règle sont compilés à leur premier passage, une copie par profondeur de récursion de B/F
(Backward/Forward), et les propriétés transitives sont tenues par des modules de closure (une transitive closure :
toutes les paires reliées par un chemin ; des composantes fortement connexes et des unions de cibles pour une closure
calculée de zéro, un produit de sources et de cibles pour une arête ajoutée). Un changement des règles ou de
l'ontologie (les faits qui décrivent les classes et les propriétés, que lisent les règles) est calculé en arrière-plan
dans une base sur le disque, comme un merge : construit à partir de la vue de travail sur un domain à lui, mis à jour
avec les groupes notés entre-temps (sous les nouvelles règles, par lots), et installé par le writer comme un seul
groupe dont la frame est la différence ; sa vue devient la vue de travail. Les tours de 20 000 faits et plus sont
dérivés sur plusieurs domains, par morsels (des petits lots de travail que les domains se partagent). Le tout :
[règles](rules.md).

## Comment c'est testé

- **Deterministic simulation testing** (des tests par simulation déterministe) : le moteur ne touche jamais le disque
  directement ; il passe par une interface (`Disk.t`) qui a deux implémentations, le vrai système de fichiers et un
  disque simulé qui perd ce qui n'a pas été forcé, déchire des secteurs, les réordonne, inverse des bits et fait échouer
  des fsyncs à la demande. Une seule seed décide de tout (les écritures, l'ordre des étapes du writer, les crashs, les
  dommages), si bien qu'un échec se rejoue exactement à partir de sa seed. FoundationDB est testé de cette façon.
- **Énumération exhaustive** : pour de petits journaux et à l'intérieur des merges, chaque état qu'un crash peut laisser
  sur le disque, chacun relu par la recovery et vérifié (la méthode de l'étude ALICE, poussée jusqu'à chaque cas).
- **De vrais crashs** (`kill -9` à des moments au hasard) et le **bank test** (le test de la banque : des virements
  gardés par `Expect`, des lecteurs sur d'autres cœurs qui vérifient que le total ne change jamais).
- **Le test de propriété des règles** : des règles au hasard et des écritures au hasard ; après chaque groupe, la vue est
  comparée au least model (le plus petit modèle) de ses faits affirmés, calculé de zéro par un évaluateur naïf propre
  aux tests (G17) ; la preuve de chaque fait dérivé est vérifiée nœud par nœud (G20) ; la simulation définit aussi des
  règles.
- **TLA+ et TLC** : TLA+ est un langage pour décrire les étapes d'un système en mathématiques (Lamport) ; TLC est son
  model checker, qui visite chaque état atteignable d'un modèle borné et vérifie des invariants dans chacun. Le
  protocole du journal et l'installation d'un merge sont modélisés (`spec/`) : 3 856 315 et 983 080 états, aucune
  violation, et chaque règle de sûreté, retirée seule, donne un contre-exemple (la réécriture de la recovery après un
  fsync qui échoue en 4 étapes).

Détails : [tests](testing.md).

## Pour aller plus loin

- Write-ahead logging et group commit : Mohan et al., ARIES (TODS 1992) ; DeWitt et al. (SIGMOD 1984) ; Helland et al.
  (HPTS 1987).
- Crash consistency (la cohérence après un crash) : Pillai et al., ALICE (OSDI 2014) ; Rebello et al., échecs de fsync
  (USENIX ATC 2020) ; Koopman, CRC-32 (DSN 2002).
- LSM-trees : O'Neil et al. (Acta Informatica 1996) ; Luo et Carey, survey (VLDB Journal 2020) ; Dayan, Athanassoulis,
  Idreos, Monkey (SIGMOD 2017) ; Dayan et Idreos, Dostoevsky (SIGMOD 2018) ; Dong et al., RocksDB (CIDR 2017) ; Balmau
  et al., SILK (USENIX ATC 2019).
- Rank tables et tri : Jacobson, succinct trees (FOCS 1989) ; Knuth, The Art of Computer Programming, vol. 3
  (1998) ; Bentley et Yao, unbounded searching (IPL 1976).
- Buffer management (la gestion des buffers) : Crotty, Leis, Pavlo, mmap (CIDR 2022) ; Leis et al., LeanStore (ICDE
  2018) ; Yang et al., S3-FIFO (SOSP 2023) ; Belady (IBM Systems Journal 1966).
- Joins : Atserias, Grohe, Marx (FOCS 2008) ; Ngo, Porat, Ré, Rudra (PODS 2012) ; Veldhuizen, Leapfrog Triejoin (ICDT
  2014) ; Ngo, Ré, Rudra (SIGMOD Record 2013).
- Tests : Zhou et al., FoundationDB (SIGMOD 2021) ; Lamport, Specifying Systems (2002) ; Newcombe et al., AWS (CACM 2015).

Les entrées complètes, avec leurs liens : [références](references.md).
