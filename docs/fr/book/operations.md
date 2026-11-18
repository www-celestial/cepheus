# Exploitation

Faire tourner une base : ses fichiers, ce que fait une ouverture, que faire quand elle signale un dommage ou une erreur
du disque, les sauvegardes, la vérification, la mémoire et l'espace disque, et les outils du dépôt.

## Les fichiers

```
DIR/cepheus                       the database's id (16 random bytes) and format, written once, atomically, with a CRC
DIR/lock                          held (lockf) while the database is open: one process at a time
DIR/closed                        left by a clean close (everything durable), removed by the next open
DIR/shared                        the database is opened by a server, whose commit buffer forces its journal
DIR/journal/NNNNNNNNNNNNNNNNNNNN.seg   segments named by their first group, 64 MB each, only appended to
DIR/snapshots/LO-HI.run           the runs (levels of the LSM tree): the changes of groups LO+1..HI on top of the
                                  state at LO (20 digits each); the chain from 0 to the newest group is the base, and
                                  nothing else is kept (the journal rebuilds any run)
DIR/snapshots/LO-HI.run.tmp       a merge being written (removed at open if a crash interrupted it)
```

Le journal est la vérité : les runs sont des caches qu'on peut toujours reconstruire. La disposition des octets :
[formats](formats.md).

## L'ouverture et la recovery

`Cepheus.open_ DIR` crée le répertoire et ses fichiers s'ils manquent, sinon :

1. prend le lock (`Busy` si un autre processus l'a) ;
2. lit l'id ; si `closed` est là (le dernier processus a fermé proprement), le supprime ; sinon force le répertoire de
   la base. Si `shared` est là et que `closed` n'y est pas, une ouverture dans le processus même d'un programme est
   refusée (`Busy` : [une base d'un serveur](#une-base-dun-serveur)) ; après une fermeture propre, elle supprime
   `shared` et continue ;
3. convertit un journal de format 1 au format 2, une seule fois (chaque segment écrit à côté, forcé, renommé
   par-dessus l'ancien ; un crash au milieu laisse chaque segment entier, et l'ouverture suivante continue), et
   supprime les fichiers des merges qu'un crash a interrompus (`.tmp`) ;
4. prend la chaîne de runs depuis 0 qui atteint le groupe le plus récent avec le moins de runs, et vérifie chacun
   (le CRC de l'en-tête, la table des pages, les rank tables, l'ordre et les bornes de chaque table ; le CRC d'une page
   au moment où elle est lue) ; un run qui ne passe pas la vérification, ou d'un format antérieur (5 et 6 : "an earlier
   format (6), the journal is replayed"), est mis de côté et noté (`Cepheus.notes`), et le choix est refait sans lui ;
5. ouverte par un serveur, écrit d'abord de nouveau dans le journal les frames que son commit buffer (l'endroit où le
   serveur copie les frames de plusieurs bases pour les confirmer par un seul fsync) contient pour cette base
   ([plus bas](#une-base-dun-serveur)), et les force ;
6. après un crash (pas de `closed`), écrit de nouveau la frame la plus récente du journal et force le segment le plus
   récent et le répertoire du journal (un processus tué avant son fsync les a laissés dans le page cache, la copie des
   fichiers que le noyau garde en mémoire ; après un
   fsync qui a échoué, le page cache peut contenir des octets que le disque n'a pas, G13) ; puis lit le journal à partir
   de la position du run le plus récent : vérifie chaque frame, applique chaque groupe, et fait un merge en un nouveau
   run quand les changements dépassent le seuil ou que le groupe est un grand groupe, comme l'aurait fait le writer ;
   un journal qui finit avant le groupe du run le plus récent est un dommage. Le journal est lu à travers une fenêtre
   de 4 MiB : une frame dont les runs contiennent déjà les groupes est vérifiée par son CRC, morceau par morceau, et pas
   décodée ; une frame plus longue à rejouer est lue en entier (la mémoire de son groupe, comme quand il a été écrit) ;
7. à la première frame qui ne passe pas la vérification : un torn tail (une fin de journal à moitié écrite) est coupé
   (truncate, fsync) ; un dommage arrête l'ouverture avec `Damaged "file: what, at which offset"` (le fichier, ce qui
   ne va pas, à quel offset ; les merges du replay avant lui peuvent avoir écrit un run des groupes d'avant le
   dommage) ;
8. une frame dont le trailer a été déchiré alors que son en-tête et son corps sont intacts est gardée, et son trailer
   reconstruit ; un segment le plus récent déchiré à sa création (son en-tête ne passe pas la vérification et il ne
   contient aucune frame) est supprimé ;
9. une nouvelle base (pas encore de groupe) reçoit le groupe 1, qui décrit les cinq propriétés système (une base faite
   avant que `cepheus/rule` existe n'a pas la description de celle-ci : ses règles marchent tout de même).

Le temps de recovery, c'est la vérification des runs plus le replay des groupes qui suivent le plus récent. Chaque
merge écrit un run, donc le replay est d'au plus un seuil de merge de changements (et des groupes écrits pendant que
le dernier merge tournait) ; `Cepheus.snapshot` fait le merge tout de suite, avant un arrêt prévu par exemple.

## Une base d'un serveur

Un serveur force les journaux de toutes ses bases par un seul fsync par tour, à travers son commit buffer
(`DATA/server.wal.1` et `.2` : [le serveur](server.md#plusieurs-bases-un-seul-fsync--le-commit-buffer)). Entre deux
checkpoints d'un journal (les moments où le journal lui-même est forcé), ses frames confirmées les plus récentes
peuvent n'être durables que dans le buffer : le journal les tient dans le page cache, et une coupure de courant peut
les y perdre. Donc :

- **Le serveur les réécrit à son démarrage.** Avant d'ouvrir ses bases, il lit le buffer ; l'ouverture de chaque base
  réécrit à leur place dans son journal les frames que le buffer a pour elle, et les force ; chaque frame du journal
  avant la dernière d'entre elles que le buffer ne contient pas doit passer la vérification (elle a été forcée : sinon
  `Damaged`) ; la règle propre au journal prend ce qui suit. Puis le buffer est vidé. Un démarrage refuse (`Damaged`,
  en nommant les ids) quand le buffer contient des frames d'une base que `cluster.toml` ne liste plus : la rajouter,
  démarrer, arrêter, et la retirer.
- **Le processus même d'un programme refuse la base après un crash.** `Cepheus.open_` d'une base qui a `shared` et pas
  `closed` renvoie `Busy` (`DIR was written through a server's commit buffer and not closed cleanly: ...`) : il
  couperait les frames confirmées comme un torn tail, ou prendrait leurs trous pour un dommage. Démarrez le serveur sur
  son répertoire de données et arrêtez-le : la base est alors fermée proprement, et s'ouvre n'importe où. Après une
  fermeture propre, l'ouverture supprime `shared` et la base redevient une base ordinaire.
- **Revenir à une version antérieure.** Les versions d'avant le commit buffer ne lisent pas `server.wal`. Arrêtez
  d'abord le serveur proprement (un arrêt propre force chaque journal et supprime les deux fichiers) : la version
  antérieure ouvre alors chaque base comme avant. Après un crash, démarrez cette version une fois et arrêtez-la avant
  de revenir en arrière. Si une version antérieure a quand même ouvert une base après un crash et y a écrit, le
  démarrage suivant de cette version refuse cette base (`Damaged` : `the frame at N is not the one the commit buffer
  holds for group G`) plutôt que d'écraser les frames de la version antérieure ; ne supprimez `DATA/server.wal.1` et
  `.2` que si vous acceptez de perdre les écritures qu'ils contenaient.
- **Les sauvegardes** se font comme plus bas : une copie lit le page cache, donc la copie du journal contient chaque
  frame confirmée avant que la copie de son segment commence. Laissez `shared` hors de la copie (ou supprimez-le) : la
  copie s'ouvre comme une base ordinaire.

## Quand la recovery dit `Damaged`

Des données durables ont changé : une panne du disque, un fichier mal manipulé, un segment qui manque au milieu. Ne
supprimez aucun fichier. Copiez le répertoire à part ; lancez `Cepheus.verify` sur la copie pour la liste complète ;
restaurez la base depuis une sauvegarde ou (plus tard) une replica. Le message nomme le segment et l'offset de la
première frame mauvaise. Si et seulement si vous savez que la partie abîmée n'a jamais été confirmée (par exemple, la
frame est la plus récente et la machine a perdu le courant pendant qu'elle l'écrivait), la fin peut être coupée à la
main à cet offset (`truncate -s OFFSET SEGMENT`) : c'est une décision humaine, que Cepheus ne prend jamais.

## Quand une écriture renvoie `Io`

Le disque a échoué pendant une écriture ou un fsync du journal. La base s'est arrêtée : chaque écriture suivante
échoue avec la même erreur, et plus rien n'est confirmé (G10). Cepheus a déjà coupé le journal jusqu'à sa dernière
frame durable (tronqué, forcé), donc les écritures échouées n'y sont pas ; si cette coupe a échoué elle aussi, stderr
le dit (`cepheus: the journal could not be cut back after a failed write: ...`), et les écritures échouées peuvent
revenir ou non à la réouverture, et une fois vues elles restent (G13). Regardez dans le log du système l'erreur du
disque, réparez le disque (l'espace, les permissions, le matériel), puis fermez la base et ouvrez-la de nouveau : la
recovery part du journal et écrit de nouveau sa frame la plus récente avant de la forcer, donc une frame qui n'est que
dans le page cache atteint le disque avant que quoi que ce soit repose sur elle (G13). Aucun redémarrage n'est
nécessaire. Cepheus ne retente jamais un fsync à l'aveugle (Rebello et al. 2020) : après un échec, Linux a marqué les
pages clean (propres, rien à écrire), et un second fsync réussirait sans les écrire. Un système de fichiers passé en
lecture seule après l'erreur (ext4, Btrfs) ou arrêté (XFS) refuse la réouverture jusqu'à ce qu'il soit réparé.

Une erreur du disque pendant qu'un merge écrit son fichier de run n'arrête pas la base : le fichier est supprimé,
stderr le dit, et le merge est retenté une fois que le delta a grandi d'un seuil de plus ; un grand groupe dont le
fichier de run échoue renvoie `Io` pour ce groupe seulement. Chaque message : [erreurs](errors.md#io--le-disque-a-lâché).

## Sauvegarde et restauration

Les segments ne reçoivent que des ajouts et ne sont jamais réécrits, et les fichiers de runs sont écrits à côté puis
renommés, donc une copie cohérente n'a besoin d'aucun arrêt :

1. copiez `DIR/cepheus` ;
2. si vous voulez, copiez les fichiers de runs de `DIR/snapshots/` (ils rendent la restauration plus rapide ; sans eux,
   la copie rejoue tout le journal). Un merge peut supprimer des runs pendant que vous copiez : copiez ce qui est là, et
   l'ouverture de la copie prend la chaîne que ses noms permettent (un run qui manque veut seulement dire un replay plus
   long). Copiez-les **avant** les segments : un run ne reçoit son nom qu'une fois ses groupes durables dans le
   journal, donc les segments copiés après lui les contiennent ; un run copié après les segments peut être plus récent
   que leur fin, et la copie refuserait de s'ouvrir (`the journal ends at group G, before the snapshot of group S`) ;
3. copiez les segments de `DIR/journal/` dans l'ordre de leurs noms. Un segment en cours d'écriture peut être copié
   avec une fin déchirée, que la recovery de la copie coupe ; chaque groupe confirmé avant que la copie de son segment
   commence est dans la copie.

Pour restaurer : mettez les fichiers dans un nouveau répertoire et ouvrez-le (sa recovery coupe une fin déchirée),
comparez `Cepheus.group (Cepheus.view db)` avec ce que vous attendez, fermez-le, et lancez `Cepheus.verify` dessus. Une
sauvegarde qui n'a jamais été ouverte et vérifiée n'est pas une sauvegarde.

## La vérification (scrubbing)

`Cepheus.verify DIR` sur une base fermée lit chaque segment depuis le début et vérifie chaque frame, chaque trailer et
chaque numéro de groupe : il renvoie le nombre de groupes ou `Damaged`. Lancez-le régulièrement sur les bases et sur les
sauvegardes : c'est la seule vérification qui décode les anciens segments, qu'une ouverture ne lit pas quand des runs
les couvrent.

## La mémoire

Les runs d'une base (ses faits fusionnés, triés et codés, environ 5,4 octets par fait à 10 M de faits) sont lus par
pages de 16 KiB à travers un seul cache pour le processus, `Cepheus.set_cache bytes` (1 GiB par défaut). Un run qui
tient dans le cache est lu en entier à l'ouverture, chaque page vérifiée ; un run plus grand est lu page par page selon
les besoins des questions, chaque page vérifiée contre son CRC à son arrivée. Les pages en mémoire restent sous
1,25 fois le cache : une collection complète du garbage collector (la partie qui libère la mémoire que plus rien
n'utilise) tourne après chaque quart du cache évincé, pour que les pages évincées retournent au système. Mesuré à 10 M
de faits (un run de 245 MB, le format à un seul niveau du jalon 2 ; le format à niveaux contient les mêmes lignes) :
avec toute la base dans le cache, 278 MB en mémoire après l'ouverture ; avec un cache de 32 MB sous une limite de
128 MB, 64 MB après l'ouverture et un pic de 79 à 105 MB pendant Q1 à Q5 (benchmarks, Plus grand que la mémoire). Avec
le format 7, la même base est un run de 54,4 MB et le processus tient 66 MB après son ouverture avec le cache de 1 GiB
([benchmarks](benchmarks.md#runs-et-journal-compressés-2026-11-09-à-10-millions-de-faits)).

À côté des runs : environ 170 octets pour chaque changement depuis le dernier merge. Un merge démarre en arrière-plan
quand les changements dépassent 200 000 ; il écrit le nouveau run dans son fichier au fil de l'eau et n'a besoin que du
cache, de quelques buffers de page et de 21 octets par page du nouveau run (théorie, section 8) : avec tout dans le
cache, le cache contient les runs que lit un merge et celui qu'il écrit, et ceux qui sont remplacés le quittent à la
bascule ; un merge complet (`snapshot`) tient la base deux fois pendant un moment. Mesuré à 10 M de faits : les
séries d'écritures à 256 clients avec leurs merges culminent à 762 MB [723 ; 1 300] (1 040 MB avec le niveau unique,
2 095 MB quand les merges étaient construits en mémoire) ; avec un cache de 32 MB, un merge de toute la base de 245 MB
tourne dans un processus limité à 128 MB (pic à 99 MB). Un grand groupe a besoin de ses opérations (la liste de
l'appelant : 883 MB pour 9,4 M d'ajouts), de 26 octets par fait de tableaux compacts et de son reçu : 1,46 GB au pic
d'un chargement de 10 M de faits en deux groupes (2,6 GB avant le 2026-11-08) ; sa frame est écrite par morceaux,
jamais construite en entier. Un appelant qui lâche sa liste une fois que `write` l'a reçue laisse le garbage collector
la reprendre pendant que le groupe est fusionné.

## L'espace disque et les merges

Les runs sont les niveaux d'un LSM tree (théorie, section 9) : le delta est fusionné une fois qu'il contient 200 000
changements, et le niveau $l$ contient au plus $200\,000 \times 4^l$ lignes (800 000, 3,2 M, 12,8 M, ...). Un merge
prend le delta et les runs les plus récents jusqu'au premier niveau qui peut tous les contenir, y écrit un seul run
(environ 5 octets par fait), le force, le renomme, puis supprime les runs qu'il a remplacés, et tout autre run hors de
la chaîne. Aucun run n'est gardé de côté : si le run le plus récent se révélait abîmé à une ouverture, il serait mis de
côté et ses groupes rejoués depuis le journal (une ouverture plus lente, rien de perdu). L'espace d'un fichier
supprimé ne revient que quand plus aucune vue ne le lit (le fichier reste ouvert jusqu'à ce que le garbage collector
libère son run). Pendant un merge complet (`snapshot`), le répertoire contient la base deux fois, l'ancienne et la
nouvelle : prévoyez environ deux fois la base pour `snapshots/` pendant qu'il tourne, une fois la base après.

Un fait est écrit environ $(T + 1) / 2 = 2{,}5$ fois par niveau qu'il traverse ($T = 4$), contre jusqu'à 17 fois avec
le niveau unique d'avant ; à 10 M de faits, trois niveaux. Pendant que des clients écrivent, un merge force son fichier
tous les 8 MiB, pour que les fsyncs du journal, que chaque écriture attend, ne fassent jamais la queue derrière des
centaines de MB de pages dirty (modifiées en mémoire, pas encore écrites sur le disque) d'un merge ; un merge à côté
duquel personne n'attend (`snapshot`, la recovery) force une seule fois, à la fin.

Un grand groupe (20 000 opérations et plus, toutes des ajouts : un chargement) est fusionné en un run pendant qu'il est
écrit, à partir de ses faits triés dans des tableaux sur plusieurs domains (des fils d'exécution d'OCaml 5 qui tournent
en parallèle, chacun sur son cœur), sans mise à jour d'index fait par fait : écrivez un chargement en quelques grands
groupes, pas en beaucoup de petits ; un groupe dont les faits arrivent dans l'ordre des choses (les faits de chaque
chose ensemble, comme un chargeur écrit des lignes) n'a pas besoin d'être trié par chose. Un groupe dont le codage
dépasse 256 MiB est refusé (`Invalid`) avant tout merge : découpez un chargement plus grand en groupes en dessous de
cette taille (9,4 M d'ajouts se codent en environ 94 MB). Plusieurs grands groupes envoyés en même temps par plusieurs
threads sont écrits dans des frames à eux, chacune dans la limite ([limites](limits.md#les-écritures)). Son reçu liste
chaque nouvelle chose ; lisez `receipt.things` une fois dans une table plutôt que d'appeler `thing` pour chacune (un
parcours de la liste à chaque fois). Un chargement laisse quelques runs (à 10 M de faits en deux groupes : le run des
clients et le run des follows) ; les questions qui font des joins entre eux les lisent tous les deux (Q3 et Q4 environ
40 % plus lentes que sur un seul run, benchmarks) : après un chargement, `snapshot` met la base en un seul run (1,3 à
6,5 s à 10 M de faits).

## Les disques

Cepheus compte sur le fait que `fsync` veut dire durable. Les disques grand public peuvent confirmer des écritures
qu'ils gardent dans un cache volatile ; utilisez des disques avec une power-loss protection (une protection contre la
coupure de courant) pour les données qui comptent. Les écritures durables vont au rythme des fsyncs du disque
multiplié par la taille d'une frame : sur le SSD SATA de la machine de test, environ 340 fsyncs par seconde.

Sur btrfs (la machine de test), une frame de 9 000 octets et son fsync, 10 s par tour, 3 tours : en ajout, comme le
fait le journal, p99 (le 99e centile) de 19,6 à 152,6 ms (15,7 à 27,7 ms dans un répertoire marqué NOCOW,
`chattr +C`) ; écrite par-dessus des zéros écrits et forcés à l'avance, p99 de 14,3 à 19,3 ms (7,7 à 15,7 en NOCOW),
et 14 % de fsyncs de plus par seconde (médiane de 5 tours, plus haut dans les 5). Le journal ne préalloue pas encore
(il lui faut un segment préparé à l'avance en arrière-plan, et une recovery qui remplit de zéros un torn tail au lieu de
le couper). Les longs blocages (des fsyncs de 80 à 450 ms, quelques-uns par minute) viennent dans tous les modes : ce
sont ceux du disque.

## Les outils

| outil | ce qu'il fait | page |
|---|---|---|
| `dune build`, `dune test` | compile ; lance les tests unitaires et les tests de propriétés, l'énumération exhaustive, 200 seeds de la simulation, et chaque exemple de la documentation | [tester](testing.md) |
| `tools/test.sh` | chaque test dans la build de release, les lents aussi : `CEPHEUS_TMP` (le répertoire de travail), `SEEDS` (300), `KILLS` (20), `BANK_SECONDS` (2), `SEAT_KILLS` (20), `SERVER_SEEDS` (200), `SERVER_KILLS` (20) | [tester](testing.md) |
| `tools/tlc.sh` | vérifie par model checking `spec/Journal.tla`, `spec/Merge.tla` et `spec/Seats.tla` avec TLC, et vérifie que la vente naïve brise un invariant ; `TLA2TOOLS` nomme `tla2tools.jar` | [tester](testing.md#model-checking) |
| `cepheus` (`bin/main.exe`) | le serveur et ses commandes : `serve`, `stop`, `status`, `token add/list/remove`, `cluster init/cert` | [serveur](server.md#les-commandes) |
| `sbench.exe` | les benchmarks du serveur : `ping`, `get`, `clients`, `write`, `q`, `hs`, `check` | [serveur](server.md#la-vitesse-à-côté-de-postgresql) |
| `bench.exe` | les benchmarks : `load`, `read`, `write`, `merge`, `fsync`, `trace`, `cachesim`, `stats`, `cpu` | [benchmarks](benchmarks.md#commandes) |
| `bench/pg/pg.sh` | le côté de PostgreSQL : `init`, `start`, `load`, `read`, `write`, `stop` | [benchmarks](benchmarks.md#commandes) |
| `bench/sqlite/sqlite.sh` | le côté de SQLite : `load`, `read` | [benchmarks](benchmarks.md#commandes) |
| `bench/sqlite/seats.py`, `bench/pg/pg.sh seats` | les côtés de SQLite et de PostgreSQL de la vente de places | [cas](case-seats.md#la-vitesse-à-côté-des-géants) |
