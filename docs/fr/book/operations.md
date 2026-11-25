# Exploitation

Faire tourner une base : ses fichiers, ce que fait une ouverture, que faire quand elle signale un dommage ou une erreur
du disque, les sauvegardes, la vérification, la mémoire et l'espace disque, l'import et l'export, et les outils du
dépôt.

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
[formats](formats.md). Chaque fichier est créé en mode 0600 et chaque dossier en 0700, quel que soit l'umask du
processus (le masque des droits qu'un processus retire aux fichiers qu'il crée) : ils tiennent les faits en clair
(`Disk.real`).

## L'ouverture et la recovery

`Cepheus.open_ DIR` crée le répertoire et ses fichiers s'ils manquent, sinon :

1. prend le lock (`Busy` si un autre processus l'a) ;
2. lit l'id ; si `closed` est là (le dernier processus a fermé proprement), le supprime ; sinon force le répertoire de
   la base. Si `shared` est là et que `closed` n'y est pas, une ouverture dans le processus même d'un programme est
   refusée (`Busy` : [une base d'un serveur](#une-base-dun-serveur)) ; après une fermeture propre, elle supprime
   `shared` et continue. Le répertoire est forcé aussi après la suppression de `closed` quand `shared` est là, pour
   qu'aucune coupure de courant ne le fasse revenir ;
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
   reconstruit ; un segment le plus récent déchiré à sa création (pas plus long que son en-tête, qui ne passe pas la
   vérification, et aucun run n'y reprend) est supprimé ; un en-tête qui ne passe pas la vérification dans un segment
   qui tient davantage, ou là où reprend le run le plus récent, est un dommage ;
9. une nouvelle base (pas encore de groupe) reçoit le groupe 1, qui décrit les cinq propriétés système (une base faite
   avant que `cepheus/rule` existe n'a pas la description de celle-ci : ses règles marchent tout de même).

Le temps de recovery, c'est la vérification des runs plus le replay des groupes qui suivent le plus récent. Chaque
merge écrit un run, donc le replay est d'au plus un seuil de merge de changements (et des groupes écrits pendant que
le dernier merge tournait) ; `Cepheus.snapshot` fait le merge tout de suite, avant un arrêt prévu par exemple.

## Une base d'un serveur

Un serveur force les journaux de toutes ses bases par un seul fsync par round (une tournée : les frames venues ensemble, forcées d'un coup), à travers son commit buffer
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
supprimez aucun fichier. Lancez `cepheus verify DIR` pour la liste complète (il ne change rien) ; restaurez la base
depuis une sauvegarde (`cepheus restore BACKUP DIR --replace`, qui met de côté le dossier endommagé ; après un crash,
elle est refusée tant que le commit buffer du serveur tient des frames de cette base, [plus bas](#sauvegarde-et-restauration)),
qui peut se prendre sur une replica ([les sauvegardes depuis la replica](server.md#les-sauvegardes-depuis-la-replica)), ou
promouvez sa replica. Le message nomme le segment et l'offset de la première frame mauvaise. Si et seulement si vous
savez que la partie abîmée n'a jamais été confirmée (par exemple, la frame est la plus récente et la machine a perdu
le courant pendant qu'elle l'écrivait), la fin peut être coupée à la main à cet offset (`truncate -s OFFSET SEGMENT`) :
c'est une décision humaine, que Cepheus ne prend jamais.

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

`cepheus backup --config FILE DEST` copie chaque base d'un serveur en marche ([production](production.md#les-sauvegardes)),
`cepheus restore SRC DIR` en restaure une ([l'exercice de restauration](production.md#lexercice-de-restauration)). Ce
sur quoi elles reposent : les segments ne reçoivent que des ajouts et ne sont jamais réécrits, et les fichiers de runs
sont écrits à côté puis renommés, donc une copie cohérente n'a besoin d'aucun arrêt, dans cet ordre :

1. `DIR/cepheus`, et `DIR/epochs` s'il existe (l'historique de promotions d'une replica) ;
2. les fichiers de runs de `DIR/snapshots/`, chacun ouvert avant qu'on liste les segments. Ils rendent la restauration
   plus rapide (sans eux, la copie rejoue tout le journal). Un merge peut supprimer un run pendant ce temps : un
   fichier ouvert se lit encore, et un run supprimé avant son ouverture veut seulement dire un replay plus long
   (l'ouverture de la copie prend la chaîne que ses noms permettent). Ils viennent **avant** les segments : un run ne
   reçoit son nom qu'une fois ses groupes durables dans le journal, donc les segments copiés après lui les
   contiennent ; un run copié après les segments peut être plus récent que leur fin, et la copie refuserait de
   s'ouvrir (`the journal ends at group G, before the snapshot of group S`) ;
3. les segments de `DIR/journal/`, dans l'ordre de leurs noms, chacun jusqu'à la taille qu'il avait à son ouverture.
   Le plus récent peut être copié pendant qu'une frame s'écrit : la première frame de sa copie qui ne se vérifie pas
   entière (en-tête, corps et trailer, la fin de la frame qui répète ses longueurs et ses CRC), quand aucune frame qui
   se vérifie ne commence après elle, est cette frame, et la copie est coupée là (l'en-tête d'un grand groupe est écrit
   après son corps, mais son trailer après son en-tête : une copie qui finit là où finissait le fichier ne tient
   jamais un trailer sans son en-tête) ; suivie d'une frame qui se vérifie, c'est un dommage. Chaque groupe confirmé
   avant que la copie de son segment commence est avant ce point : il a été écrit entier avant d'être confirmé, et les
   frames sont ajoutées une à la fois. Une frame en cours d'écriture montre ses octets à mesure qu'ils s'écrivent : une
   frame est ajoutée en une seule écriture, qu'un lecteur voit dans l'ordre jusqu'à la taille qu'il lit, et l'en-tête
   d'un grand groupe, écrit en dernier à sa place, se lit comme des zéros jusque-là. Donc une première frame qui ne se
   vérifie pas alors que chacun de ses octets est là (son en-tête se vérifie et toute la longueur qu'il donne est là,
   ou son en-tête est là, pas des zéros, et ne se vérifie pas) n'est pas une frame en cours d'écriture : le segment de
   la base en service est relu dix fois en une seconde (un en-tête qui s'écrit à sa place est entier en quelques
   microsecondes), et une frame qui reste ainsi est un dommage (code de sortie 1), jamais coupée ;
4. `DIR/vault/`, après le journal : chaque pack (un fichier d'enregistrements du vault) et son index, puis ses `keys`
   (un fait ne nomme un fichier qu'une fois les enregistrements du fichier forcés, G22, donc chaque fichier que cite le
   journal copié est dans les packs copiés ; la clé d'un domaine est forcée avant son premier enregistrement, donc les
   clés copiées après les packs tiennent chaque clé dont ils ont besoin ; le pack en cours d'écriture peut finir par
   un enregistrement déchiré, que l'ouverture de la copie indexe jusqu'au dernier entier, comme après un crash).

La copie laisse de côté `lock`, `closed`, `shared` et `sessions`. `cepheus backup` la vérifie ensuite comme le fait
`cepheus verify`, la coupe après sa dernière frame entière, la force sur le disque et écrit son marqueur `closed` : une
sauvegarde est une base fermée proprement, et un `cepheus verify` plus tard prend tout octet déchiré pour un dommage.
Donc la frame la plus récente d'une base laissée par un processus mort, dont seul le trailer est cassé (la règle du
crash la garde : la recovery réécrit le trailer depuis l'en-tête de la frame), voit d'abord son trailer réécrit dans la
copie, comme le ferait l'ouverture suivante.

DEST appartient à l'utilisateur : un dossier où d'autres utilisateurs peuvent écrire est refusé (ils pourraient y
planter des noms), comme un dossier à un autre utilisateur. Une sauvegarde n'y supprime que ce qu'a laissé une
sauvegarde qui n'a pas fini, un dossier de cet utilisateur nommé `DATE.partial` (`2026-11-24T224915.partial`, ou
`...-2.partial`), jamais à travers un lien (link, un nom qui renvoie vers un autre fichier) : le `movie.partial` d'un
autre programme reste. Son verrou, `DEST/cepheus-backup.lock`, s'ouvre comme un fichier de cet utilisateur, jamais à
travers un lien.

`cepheus restore SRC DIR [--to-group N | --to-time T]` copie dans `DIR.restoring`, dans le même ordre, les runs dont
les groupes finissent à N ou avant et les segments jusqu'à celui qui commence à N + 1 (gardé réduit à son en-tête : un
run du groupe N peut le nommer), finit le journal après le groupe N (la frame qui tient N, quand des groupes plus
récents la partagent, est codée de nouveau sans eux, à la même place, avec le même premier groupe), écrit dans
`DIR/epochs` une nouvelle epoch à partir du groupe N + 1, au-dessus de chaque epoch que connaissaient l'historique de
la source et une base remplacée, ouvre la copie (ses runs vérifiés, les groupes d'après le
plus récent rejoués), la ferme, la vérifie comme le fait `cepheus verify`, et la renomme `DIR` ; avec `--replace`, une
base déjà dans `DIR` est d'abord renommée `DIR.before-restore-DATE`, jamais supprimée. Elle refuse une source ou une
cible qu'un processus tient ouverte, une source écrite à travers le commit buffer d'un serveur et pas fermée
proprement, et une cible à côté d'un commit buffer qu'a laissé l'arrêt pas propre d'un serveur (`DATA/server.wal.1` ou
`.2`, aucun serveur ne tenant le dossier des données) quand ce buffer tient des frames de la base restaurée ou de celle
remplacée, ou ne se lit pas : le démarrage suivant du serveur les écrirait dans le journal restauré. Une cible qui a
crashé pendant qu'on l'écrivait à travers le buffer est remplacée telle quelle (mise de côté, jamais lue).
`--to-time T` prend `YYYY-MM-DDTHH:MM` ou `YYYY-MM-DDTHH:MM:SS` (une espace à la place du `T`), exactement ces
chiffres, un jour du calendrier (années bissextiles comprises), des heures de 00 à 23, des minutes et des secondes de
00 à 59, à l'heure locale de la machine (une heure que ses horloges sautent au passage à l'heure d'été est refusée)
ou en UTC avec un `Z` final ; tout le reste est refusé, jamais déplacé vers une autre heure. Le code de sortie des
deux : 0 fait, 1 un dommage trouvé, 2 refusé ou échoué ; aucune des deux ne laisse une demi-copie sous son nom final.

## La vérification (scrubbing)

`cepheus verify DIR` vérifie les fichiers d'une base tels qu'ils sont et ne change rien (il les ouvre en lecture
seule) :

- chaque segment du journal à part (sur jusqu'à 4 domains, les fils d'exécution d'OCaml sur leurs propres cœurs),
  pour qu'un segment abîmé ne cache pas les autres : son en-tête, puis chaque frame (les CRC de son en-tête et de son
  corps, son trailer, son premier groupe et son nombre, les groupes qui se suivent), les groupes de chaque frame
  jusqu'à 16 MiB décodés et numérotés (une frame plus grande, celle d'un gros chargement, est vérifiée par ses CRC :
  la décoder prendrait la mémoire de son groupe) ; le premier dommage de chaque segment nommé, avec son offset, et les
  segments qui manquent entre eux ;
- chaque run, comme une ouverture le vérifie (son en-tête, sa table des pages, ses tables de rangs et d'offsets), et
  chaque page contre son CRC (lue à travers un cache de 256 MiB : la mémoire reste en dessous quelle que soit la
  taille de la base) ;
- chaque run contre le journal : ses groupes dans le journal, sa position dans le journal au début d'une frame ;
- les enregistrements du vault, par leurs CRC, sans la clé maîtresse : le fichier des clés, chaque enregistrement que
  nomme l'index de chaque pack, les packs sans index jusqu'à leur fin déchirée.

La fin du segment le plus récent est lue selon l'état de la base : fermée proprement, chaque octet doit se vérifier ;
laissée par un processus mort, une frame déchirée sans rien d'écrit après elle est une note (l'ouverture suivante la
coupe), comme une frame la plus récente dont seul le trailer est cassé (l'ouverture suivante le réécrit) ; ouverte
dans un serveur, la frame en cours d'écriture n'est pas vérifiée, et une frame qui ne se vérifie pas alors que chacun
de ses octets est là est relue pendant une seconde, puis tenue pour un dommage si elle reste ainsi
([sauvegarde et restauration](#sauvegarde-et-restauration), point 3) ; une frame qui ne se vérifie pas suivie d'une
frame qui se vérifie est un dommage, dans tous les états. Une base écrite à travers le commit
buffer d'un serveur et pas fermée proprement est refusée : démarrez son serveur et arrêtez-le d'abord. Code de sortie
0 : entière (la dernière ligne nomme le groupe) ; 1 : un dommage, une ligne `damaged:` chacun ; 2 : pas une base,
illisible, ou refusée. Lancez-le sur les sauvegardes (`cepheus backup` le lance sur chaque copie) et de temps en temps
sur les bases en service : c'est la seule vérification qui lit les anciens segments et chaque page, qu'une ouverture
ne lit pas quand des runs les couvrent. `Cepheus.verify DIR`, l'appel OCaml, reste : il lit chaque frame du journal
d'une base fermée et renvoie le nombre de groupes ou `Damaged`.

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
libère son run, et il est fermé alors). Pendant un merge complet (`snapshot`), le répertoire contient la base deux fois, l'ancienne et la
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

## Import et export

`cepheus import` charge les choses d'une sorte depuis un fichier, `cepheus export` les écrit : pour partir d'une base
qui existe (PostgreSQL, SQLite, un tableur), pour les rapports et les audits, et pour quitter Cepheus. Les deux passent
par le serveur avec un token, comme tout programme, jamais en ouvrant les fichiers d'une base vivante ; le token est
dans `CEPHEUS_TOKEN`, jamais sur la ligne de commande (que chaque utilisateur de la machine peut lire) : le droit
d'écrire la base pour importer, de la lire pour exporter.

```sh
cepheus import shop clients.csv --kind client --config /etc/cepheus/cluster.toml        # CSV with a header row
cepheus import shop invoices.jsonl --kind invoice --config /etc/cepheus/cluster.toml    # JSON lines
cepheus export shop --kind invoice --config /etc/cepheus/cluster.toml > invoices.jsonl
cepheus export shop --kind invoice --format csv --config /etc/cepheus/cluster.toml > invoices.csv
```

La sorte (kind) est celle du programme : ses champs sont les propriétés `kind/Field` déclarées dans la base (le
`cepheus.Connect` d'un programme Cesia déclare ses sortes, [Cepheus depuis Cesia](cesia.md)), si bien qu'un programme
se connecte une fois avant le premier import. Une colonne de l'en-tête du CSV, ou une clé des JSON lines, nomme un
champ : le même nom, ou le seul champ dont le nom ne diffère que par ses majuscules (les colonnes de PostgreSQL sont en
minuscules : `email` est `Email`) ; `--map Col=Field` quand ils diffèrent, `--map Col=` pour laisser une colonne de
côté. Une colonne qui ne nomme aucun champ arrête l'import avant qu'il lise une ligne.

Depuis PostgreSQL ou SQLite, leurs propres commandes écrivent le fichier :

```sh
psql -c "\copy (SELECT name AS \"Name\", city AS \"City\", email AS \"Email\" FROM client) TO 'clients.csv' WITH (FORMAT csv, HEADER true)"
sqlite3 -csv -header shop.db "SELECT name AS Name, city AS City, email AS Email FROM client" > clients.csv
cepheus import shop clients.csv --kind client --config /etc/cepheus/cluster.toml
```

### Les fichiers

**CSV** comme l'écrit la RFC 4180 (la description, par l'IETF, des valeurs séparées par des virgules) : une ligne
d'en-tête, puis un enregistrement (record) par ligne ; un champ qui commence par un guillemet est entre guillemets et
peut contenir des virgules et des sauts de ligne, `""` y étant un guillemet. Un guillemet ailleurs, ou un caractère
après un guillemet fermant, est refusé : c'est un fichier cassé, pas une donnée. Un tel guillemet n'ouvre rien, si bien
que sa ligne seule est mauvaise et que `--skip-bad` lit les lignes d'après (la grammaire de la RFC 4180 : un champ qui
ne commence pas par un guillemet n'en contient aucun). Le `COPY` de PostgreSQL 18.6 lit au contraire un guillemet
dans un champ comme le début d'une partie entre guillemets : les lignes `bob"x,2`, `carl,3` et `eve"y,5` y entrent
comme une seule ligne de table, son nom `bobx,2`, `carl,3` et `evey` joints par des sauts de ligne, son nombre 5, sans
erreur (mesuré). Un mauvais enregistrement qu'un guillemet au début d'un champ étend sur plusieurs lignes est nommé
aussi avec sa dernière ligne. Un enregistrement finit à un saut de ligne hors des guillemets, LF ou CR LF ; les lignes
vides sont sautées à mesure qu'elles sont lues (un fichier de lignes vides ne tient aucune mémoire) ; une marque
d'ordre des octets UTF-8 au début (le BOM, les trois octets EF BB BF que certains éditeurs écrivent en premier) est
sautée. Comme dans le `COPY` de
PostgreSQL (sql-copy.html : « a NULL is written as an unquoted empty string, while an empty string data value is
written with double quotes »), un champ vide sans guillemets n'est aucune valeur et `""` est le texte vide. Un export
écrit CR LF, comme la RFC 4180.

**JSON lines** comme les décrit jsonlines.org : un objet JSON par ligne (RFC 8259), `{"Name": "Ada", "City": "Lyon"}` ;
`null` ou une clé absente n'est aucune valeur. Une clé deux fois, un objet imbriqué, une imbrication de plus de 64
niveaux, un échappement faux, un surrogate seul (la moitié d'un caractère dans des échappements `\u`) sont refusés.

Une valeur est lue selon le type de son champ, exactement :

| type | CSV | JSON lines | export |
|---|---|---|---|
| `Int` | `-12` (63 bits) | un nombre entier | le même |
| `Float` | `2.5`, `1e-7`, `NaN`, `Infinity` | un nombre, `"NaN"`, `"Infinity"` | le plus court décimal qui se relit en le même double |
| `Bool` | `true`, `false`, `t`, `f`, `1`, `0` | `true`, `false` | `true`, `false` |
| `Text` | UTF-8 sans NUL | une chaîne | la même |
| `Date` | `2026-11-24`, `2026-11-24T10:30:00Z`, `2026-11-24 10:30:00.123+01:00` (RFC 3339 ; sans fuseau : UTC) | une chaîne de la même forme | `2026-11-24T10:30:00.123Z` |
| `Money(s)` | `12.50` : au plus `s` décimales, jamais par un float | un nombre de la même forme | `12.50`, exactement `s` décimales |
| `Link` | la clé de la chose liée (plus bas) | la clé, du type de la clé | la clé |
| plusieurs valeurs | une liste JSON dans le champ : `"[""red"",""blue""]"` | une liste | une liste |

Une date est gardée à la milliseconde : les chiffres plus fins (les microsecondes de PostgreSQL) sont coupés ; une
date que son fuseau déplace hors des années 0 à 9999 en UTC (`0000-01-01T00:00:00+01:00`) est refusée, puisqu'un
export ne pourrait pas la réécrire. L'argent
(money) est lu depuis ses chiffres décimaux en unités mineures, si bien que `12.505` pour des centimes est refusé et
que `0.1` vaut dix centimes, jamais 0.1000000000000000055. Un texte est vérifié en UTF-8 et un octet NUL refusé
(PostgreSQL refuse `0x00` dans un texte aussi) ; un export refuse un texte qui en contient un (ni le CSV ni les JSON
lines n'en portent).

**Les liens.** Un lien s'écrit comme la clé de la chose liée : un champ unique d'une valeur. Par défaut la sorte
nommée comme le champ en minuscules, par son seul champ unique : `Client` est un client trouvé par son `Email`.
`--link Client=client/Email` nomme la clé, `--link Client=id` écrit plutôt les ids des choses (un export pour un audit,
un import dans la même base). Les choses liées doivent être dans la base d'abord : importez les clients, puis les
factures, puis leurs lignes.

### Ce qu'un import vérifie, et quand il écrit

Le fichier est lu deux fois. La première passe vérifie chaque ligne : le nombre de ses champs, chaque valeur contre son
type, chaque lien trouvé dans la base, chaque valeur unique contre la base et contre les autres lignes du fichier. Une
mauvaise ligne arrête l'import avec sa ligne (celle où elle commence, en comptant les sauts de ligne entre guillemets)
et la raison, et **rien n'est écrit** :

```text
cepheus: clients.csv line 1204: Email "ada@example.com" is on line 7 too; nothing was written
```

`--skip-bad` écrit les bonnes lignes et liste les mauvaises sur stderr, chacune avec sa ligne. Un échec qui n'est pas
un refus (la connexion au serveur perdue, le disque) arrête aussi l'import, à tout moment, en nommant les groupes
écrits ; le groupe dont la réponse s'est perdue est nommé comme tel : il est peut-être dans la base, celui d'après les
groupes nommés. `--upsert` change la
chose que trouve une valeur unique de la ligne au lieu de la refuser : les valeurs de la ligne remplacent ses champs,
un champ vide en laisse un tel quel, et un champ de plusieurs valeurs est refusé (`Write` change ceux-là) ; deux lignes
du fichier avec une même valeur unique sont refusées même alors, comme le `ON CONFLICT DO UPDATE` de PostgreSQL refuse
de changer une ligne deux fois.

La seconde passe relit le fichier et l'écrit en groupes d'au plus un million d'opérations (15 MiB de requête, sous les
16 MiB d'une frame), chacun pris par le chemin des grands groupes de la base (20 000 opérations et plus : triés dans des
tableaux par plusieurs domains, fusionnés dans un run à mesure qu'ils s'écrivent), depuis un thread à lui sur une
connexion à lui, pendant que des domains (les fils d'exécution parallèles d'OCaml) analysent les lignes qui suivent.
Donc :

- **Un import qui tient dans un groupe est tout ou rien**, une contrainte des règles comprise : la base refuse le
  groupe en entier.
- **Un import plus grand est vérifié en entier d'abord**, puis écrit groupe après groupe. La base ne refuse un groupe
  que pour ce que la première passe ne peut pas voir : une contrainte d'une règle, ou une valeur unique qu'un autre
  programme a écrite entre-temps. L'import s'arrête alors et nomme ce qui est écrit :

```text
cepheus: invoices.csv lines 2252 to 2501: the database refused their group: invalid: constraint never-void: ...;
written before it: lines 2 to 2251, in groups 5 to 13
```

  Les lignes d'avant sont dans la base, celles d'après non : corrigez le fichier, et importez ses lignes à partir de
  celle-là.

Un import est le travail d'une commande : deux imports d'une même sorte en même temps peuvent chacun trouver une valeur
unique libre à leur première passe ; la base refuse alors le groupe du second, comme ci-dessus. Le fichier doit être un
fichier (pas un pipe : il est lu deux fois), et ne pas changer pendant sa lecture (sa taille et sa date sont vérifiées
entre les passes).

### Ce que donne un export

Chaque chose de la sorte à un état de la base, le groupe de cet état sur stderr
(`cepheus: shop at group 6202: 100,000 things of invoice, 900,000 facts, as CSV, in 0.31 s`), les choses par id, chacune
avec les faits **asserted** (écrits par un programme) de ses champs : ce que les règles dérivent (le `Overdue` d'un
client) est laissé de côté, puisque les règles de la base où l'export est importé le dérivent à nouveau. Les liens
s'écrivent par leur clé (`--link`, comme plus haut) ; une chose liée sans sa clé arrête l'export (`--link Field=id`
écrit les ids). Un export importé dans une nouvelle base donne les mêmes faits : le test le fait pour l'app des
factures, et ses exports des deux sont les mêmes octets.

L'export lit une view (un état figé de la base) dans son propre processus, par le follow stream du serveur sur son
socket Unix ([lectures locales](server.md#lectures-locales-g15)) : une view ne change jamais pendant sa lecture,
si bien que le fichier est un seul état cohérent quel que soit le temps qu'il prend, et aucune écriture ne l'attend.
Il tourne donc sur la machine du serveur, avec un token qui lit toute la base (un token de quelques sortes n'est jamais
suivi) ; ailleurs il le dit et s'arrête. Lire à un groupe passé (`--as-of`) attend les lectures à un groupe passé.

### Sécurité

- Le serveur vérifie le token à chaque requête : les écritures d'un import demandent `write`, le follow stream d'un
  export demande `read` sur toute la base. La commande ouvre le fichier avec les droits de son utilisateur ; le serveur
  ne voit jamais un chemin.
- Ce que contient un fichier est une donnée : un enregistrement fait au plus 8 MiB, si bien qu'un guillemet laissé
  ouvert dans un fichier de 10 GB arrête l'import à sa ligne au lieu de lire le reste comme un seul champ ; les champs
  d'un enregistrement sont faits jusqu'au nombre de l'en-tête, un de plus compté et pas fait (8 MiB de virgules font
  8,4 M champs, 740 MB à faire) ; le JSON d'un enregistrement tient au plus 100 000 valeurs, les éléments de ses
  listes et les membres de ses objets, tous ses champs ensemble (la borne de `In`), et un en-tête au plus 100 000
  colonnes ; l'imbrication JSON est d'au plus 64 niveaux ; les textes sont vérifiés UTF-8 sans NUL ; le fichier est
  lu par le descripteur (file descriptor, le fichier ouvert) vérifié, jamais de nouveau par son chemin, si bien qu'un
  fichier renommé par-dessus entre-temps n'est pas lu.
- Un export écrit les valeurs exactement telles qu'elles sont, puisqu'un aller-retour en a besoin : un texte qui
  commence par `=`, `+`, `-` ou `@` est une formule pour un tableur qui ouvre le CSV (la CSV injection). Ouvrez un
  export dans un tableur comme du texte, ou écrivez le rapport par l'app (le CSV de l'app des factures protège ses
  cellules, [l'app](app.md#10-lexport-csv)).

### Mémoire et vitesse

La première passe garde 8 octets pour chaque valeur unique (un hash de 30 bits et le numéro de la ligne, dans une table
d'adressage ouvert au plus pleine aux 3/4) ; deux valeurs d'un même hash sont départagées en relisant la ligne d'avant
(l'offset de chaque 1 024e ligne est gardé), si bien que la vérification est exacte. Tout le reste est borné quelle que
soit la taille du fichier : des tours de huit lots d'un MiB, deux groupes en vol, la borne d'un enregistrement.

Mesuré sur la machine de test (Intel i7-4720HQ, 4 cœurs, SSD SATA ; son btrfs plein à 97 %, d'autres jobs qui
compilaient à côté) le 2026-11-25 avec `bench/transfer.sh DIR 120482 7` : 120 482 clients et 2 409 640 factures,
10,0 M de faits, 149 MB de CSV ; sept tours, les côtés à tour de rôle, chacun durable ; médiane [min, max]. Chaque côté
charge les clients (un e-mail unique), puis les factures, leur lien trouvé par l'e-mail du client : Cepheus par
`cepheus import` de chaque fichier ; PostgreSQL 18.6 par `\copy` des clients, puis `\copy` des factures dans une
table de leur texte et `INSERT ... SELECT` joint sur l'e-mail, en une transaction ; SQLite 3.54 par `.import --csv` de
chaque fichier dans une table à lui et le même `INSERT ... SELECT`.

| | Cepheus | PostgreSQL 18.6 | SQLite 3.54 |
|---|---:|---:|---:|
| les clients (361 446 faits) | 1,18 s [1,05, 6,63] | 1,43 s [0,64, 7,21] | 0,47 s [0,43, 2,08] |
| les factures (9 638 560 faits) | 25,0 s [15,7, 42,1] | 39,7 s [27,4, 83,7] | 8,94 s [7,74, 9,28] |
| les deux | 28,5 s [16,8, 43,2] | 43,7 s [28,3, 85,2] | 9,71 s [8,17, 10,3] |
| la mémoire au pic du chargement | la commande 556 MB [511, 577], le serveur 450 MB [332, 571] | le backend 316 MB (shared_buffers 1 GB) | 11 MB |
| l'export des factures avec l'e-mail de leur client | 2,61 s [1,76, 3,99], 245 MB | 3,94 s [3,56, 11,5] | 1,61 s [1,57, 1,93] |
| sur le disque après le chargement | 111 à 198 MB (journal et runs) | 237 MB | 276 MB |

SQLite charge le plus vite : un processus écrit un fichier, et il ne vérifie rien des valeurs (ses colonnes prennent
n'importe quel texte : les montants et les dates restent des textes). Cepheus lit le fichier deux fois, et la première
passe, chaque ligne vérifiée et chaque lien trouvé, prend 3,57 s [3,15, 6,37] du temps des factures ; le reste est le
serveur qui écrit dix grands groupes, ce qui a varié de 11,7 à 38,1 s sur ce disque (7,8 s dans un tour calme du même
build l'heure d'avant), là où la bibliothèque écrit les mêmes faits dans son propre processus, en deux grands groupes, en
5,13 s ([benchmarks](benchmarks.md)) : chaque groupe traverse le socket, codé et décodé (un de 960 000 faits, 0,72 s par le
serveur, 0,41 s dans le processus). PostgreSQL perd les factures : sa jointure et sa vérification de clé étrangère
(foreign key) reprennent chaque ligne après la copie. Une facture dont aucun client n'a l'e-mail est laissée de côté
en silence par la jointure de PostgreSQL et de SQLite ; Cepheus refuse le fichier, en nommant la ligne, avant d'écrire
quoi que ce soit.

Un fichier de 10 GiB (10 737 434 790 octets, 192 506 762 lignes : les factures de 13 clients encore et encore, dans un
dossier compressé par btrfs, `chattr +c`, pour qu'il tienne en 1,2 GB sur un disque qui avait 7 GB de libre) dont la
dernière ligne a 3 décimales pour des centimes est vérifié en entier et refusé à cette ligne, rien d'écrit : 253 s
(42 MB/s), le pic de la commande 244 MB, contre 130 MB pour les 149 MB des factures du benchmark : la mémoire ne suit
pas le fichier.

`bench/transfer.sh DIR CLIENTS [ROUNDS]` fait tourner les trois côtés.

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
| `bench/transfer.sh` | `cepheus import` et `export` à côté du `COPY` de PostgreSQL et du `.import` de SQLite | [import et export](#mémoire-et-vitesse) |
