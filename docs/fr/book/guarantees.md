# Garanties

Chaque garantie énonce ce qui est promis, sous quelles pannes, ses conditions exactes, pourquoi elle tient (une esquisse
de preuve) et le test qui la vérifie. Les tests sont dans `test/` ; `tools/test.sh` les lance tous. Les mots sont
expliqués dans [concepts](concepts.md), [architecture](architecture.md) et le [glossaire](glossary.md) ; les
mathématiques sont dans [théorie](theory.md). Tout ce qui suit vaut pour cette version : une seule machine, des runs sur
le disque en niveaux (leveling, ratio 4), une replica asynchrone (une copie de la base tenue à jour sur une autre
machine, sans que les écritures l'attendent : [serveur](server.md#une-replica) ; son journal est un préfixe des groupes
durables du primary, le serveur qui reçoit les écritures, et sa promotion, le passage de la replica au rôle de
primary, se fait à la main), et un cluster Raft de trois serveurs ou plus, dont les invariants propres et leur preuve
sont dans [sa section](server.md#comment-cest-prouvé) ; les règles comme [règles](rules.md) le dit.
G14, G15 et G16 appartiennent au serveur : leurs énoncés, leurs preuves et leurs tests sont dans [la page du serveur](server.md#écritures-appliquées-une-seule-fois-les-sessions-g14)
([G15](server.md#lectures-locales-g15) : des lectures dans la mémoire même d'un programme, sur la machine du serveur).
À travers le serveur, G1 à G13 gardent leurs énoncés : un groupe est confirmé quand son reçu est envoyé, après son
fsync (l'appel système qui attend que les octets soient vraiment sur le disque), et chaque lecture nomme le groupe
durable à partir duquel elle a été répondue ; `server_sim` les vérifie sur un réseau simulé, avec les crashs du serveur.

| | la promesse, en une ligne | sous |
|---|---|---|
| G1 | un groupe confirmé survit à tout crash et à toute recovery | F1, F2 |
| G2 | un groupe est tout ou rien | F1, F2 |
| G3 | après la recovery, les groupes sont un préfixe $1, \dots, k$ de l'historique, $k \ge$ le dernier confirmé | F1, F2 |
| G4 | les groupes sont strictly serializable | toujours |
| G5 | une vue ne change jamais et ne contient que des groupes durables ; les vues ne reculent jamais | F1, F2, F4 (avec G13) |
| G6 | un dommage aux octets durables du journal est détecté, jamais écarté en silence | F3 (un cas résiduel) |
| G7 | une ouverture depuis les runs sur le disque est égale à un replay du journal ; une page abîmée n'est jamais servie | F1 à F3 |
| G8 | un fork ne change rien de sa base | toujours |
| G9 | un seul moteur à la fois ouvre une base, quel que soit le chemin qui la nomme | toujours (le lock est consultatif) |
| G10 | après une écriture ou un fsync qui a échoué, plus rien n'est confirmé | F4 (un cas résiduel) |
| G11 | une question renvoie exactement ses réponses, chacune une fois, dans la borne de Generic Join | toujours |
| G12 | un crash pendant un merge laisse les runs d'avant ou les runs d'après, entiers | F1, F2, F4 |
| G13 | après un fsync qui a échoué, aucune vue ne montre un groupe qu'une coupure de courant pourrait reprendre ; une écriture qui a reçu `Io` est absente (un cas résiduel) | F4 avec F1, F2 |
| G14 | à travers le serveur, une écriture envoyée avec sa session et son numéro de série est appliquée au plus une fois ; renvoyée jusqu'à avoir une réponse, exactement une fois, chaque réponse nommant le même groupe | F1, F2, connexions coupées |
| G15 | chaque lecture, dans un lecteur local ou au serveur, contient chaque groupe répondu et chaque état lu avant son début, et est l'état exact après un groupe durable : les lectures sont linearizable | F1, lecteurs lents, en pause ou tués, flux coupés |
| G16 | à travers le serveur, une connexion fait exactement ce que permettent les droits de son token | toujours |
| G17 | chaque vue contient exactement le plus petit modèle de ses faits affirmés sous ses règles (avec l'égalité : lu à travers ses classes), et marque exactement ceux qui sont affirmés | toujours (avec G1-G3 sous F1, F2) |
| G18 | aucun groupe confirmé ne laisse une instance d'une contrainte (`Never`) | toujours |
| G19 | un changement de règle prend effet à un seul groupe | toujours |
| G20 | `why` renvoie une preuve bien fondée d'un fait de la vue, ou rien pour un non-fait | toujours |
| G21 | chaque message d'une question vivante (`Watch`) laisse au programme exactement les lignes de `Find` à son groupe, un groupe durable ; ses groupes ne font que croître, sans en sauter un qui a changé les lignes | F1, F2, connexions coupées, programmes lents |
| G22 | aucun fait ne cite un chunk (un morceau d'un fichier) ou un nœud (une entrée de l'arbre qui relie les chunks d'un fichier) du vault de fichiers (là où Cepheus garde les octets des fichiers) qui n'est pas sur le disque | F1, F2 |
| G23 | le vault ne sert aucun octet d'un fichier autre que les octets qui y ont été mis | F3 (tout changement du disque) |
| G24 | après `Erase`, aucune lecture du vault, ni d'une copie qui a pris ses clés depuis, ne donne un octet des fichiers du propriétaire | toujours |

## Les pannes

- **F1 crash du processus** : le processus s'arrête à n'importe quelle instruction (`kill -9`, un bug, l'OOM killer,
  la partie du noyau Linux qui tue un processus quand la mémoire manque). Ce qu'il a écrit sans le forcer sur le disque
  reste dans le page cache (la copie des fichiers que le noyau garde en mémoire) : lisible par le processus suivant, et
  perdu à une coupure de courant ultérieure.
- **F2 coupure de courant** : la machine s'arrête à n'importe quel moment. Les données qu'aucun `fsync` terminé ne
  couvre peuvent être perdues, gardées, gardées dans n'importe quel ordre secteur par secteur (512 octets), ou déchirées
  à l'intérieur d'un secteur ; un fichier créé, renommé ou supprimé sans un `fsync` de son répertoire peut perdre ce
  changement. Les changements de noms dans un même répertoire survivent sous forme de préfixe, dans l'ordre.
- **F3 corruption silencieuse** : des octets déjà durables changent (des bits inversés, un secteur remplacé).
- **F4 erreur d'I/O** (d'entrée-sortie) : une écriture ou un `fsync` échoue. Les systèmes de fichiers de Linux marquent
  alors comme propres les pages que ce `fsync` couvrait, bien qu'elles n'aient jamais atteint le disque ; ext4 et XFS
  gardent leurs nouveaux octets en mémoire, lisibles jusqu'à ce que les pages quittent le page cache (un redémarrage, un
  manque de mémoire), et un `fsync` ultérieur réussit sans les écrire ; ext4 peut rendre durable la nouvelle taille du
  fichier par-dessus des blocs jamais écrits ; Btrfs défait lui aussi en mémoire les écritures qui ont échoué (Rebello,
  Patel, Alagappan, Arpaci-Dusseau, Arpaci-Dusseau, "Can Applications Recover from fsync Failures?", USENIX ATC 2020,
  section 3.3). En bref : après un `fsync` qui a échoué, ce qu'un processus relit peut être des octets que le disque ne
  contient pas.

Hors de portée d'une seule machine (la réplication les couvrira) : un disque qui confirme un `fsync` sans écrire (et
ext4 monté avec `data=journal`, qui signale une écriture échouée au `fsync` suivant plutôt qu'à celui qui la couvrait :
la section 3.3.1 de l'article) ; la perte d'une frame durable entière à la fin du journal sans rien d'écrit après elle ;
quelqu'un qui réécrit le journal et ses checksums ; une RAM corrompue (utilisez de l'ECC).

Un groupe est **confirmé** quand `write` a renvoyé `Ok`.

## G1 Durabilité

*Promesse.* Sous F1 et F2, un groupe confirmé est présent après toute suite de crashs et de recoverys, avec exactement
ses changements.

*Conditions.* Le disque garde ce qu'un `fsync` a déclaré fait (les disques grand public avec un cache d'écriture
volatile peuvent ne pas le faire : [exploitation](operations.md#les-disques)) ; la frame du groupe confirmé n'est pas
abîmée ensuite (c'est F3, G6). La promesse porte sur les groupes dont le `write` a renvoyé `Ok` : un groupe dont le
`write` a renvoyé une erreur, ou qui était encore en cours, peut être présent ou absent.

*Preuve.* `write` revient après que le `fsync`, par le syncer (le thread qui force les écritures sur le disque), de la frame qui contient
le groupe est revenu (le writer publie et répond dans `Engine.commit`, après `Journal.append`, dont le dernier appel est
`fsync`). Un nouveau segment n'est utilisé qu'après que son en-tête a été écrit, son fichier forcé et son répertoire
forcé (`write_segment_header`). Donc chaque octet de chaque frame jusqu'à celle du groupe est durable ; F2 ne touche
pas aux octets durables. La recovery (`Journal.scan`) lit les frames dans l'ordre et ne s'arrête qu'à la première frame
qui ne passe pas la vérification ; toutes les frames avant une frame durable sont durables, donc intactes, donc lues.
Les runs utilisés à la recovery sont cohérents avec le journal (G7).

*Avec le commit buffer d'un serveur* ([le serveur](server.md#plusieurs-bases-un-seul-fsync--le-commit-buffer) ; le commit
buffer est l'endroit où le serveur copie les frames de plusieurs bases pour les confirmer toutes par un seul fsync), la
frame est écrite dans le journal sans fsync, et `write` revient après le fsync du round du buffer (sa tournée : les frames venues ensemble, forcées d'un seul fsync) qui en contient une
copie entière (ou, quand le buffer était inactif, après le fsync de son propre journal, comme sans le buffer). Jusqu'à
ce que le journal soit forcé (un checkpoint, le moment où le journal lui-même est rendu durable), le buffer garde cette
copie : un fichier du buffer n'est vidé qu'une fois que chaque journal qui y a des frames a été forcé après elles, et un
run n'est nommé qu'une fois son journal forcé (`Engine.install`), donc aucun état durable ne repose sur des frames que
le buffer est seul à contenir. Une base n'écrit sa frame suivante qu'une fois la précédente confirmée ; donc, après une
coupure de courant, son journal contient, après sa dernière frame forcée, des frames que le buffer contient, chacune
entière, perdue ou torn (écrite à moitié, interrompue en cours de route), et au plus une frame qu'aucun fsync n'a
confirmée. La recovery réécrit à sa place chaque frame que contient le buffer avant de lire le journal
(`Journal.repair`), et chaque autre frame avant la dernière d'entre elles doit passer la vérification (elle a été
forcée) ; la règle propre au journal prend le reste. Donc chaque frame confirmée est lue.

*Testé par* `test/sim.ml` (à chaque recovery : "lost acknowledged groups"), `test/exhaustive.ml` (chaque état de crash
de petits journaux ; partie 6, le commit buffer), `test/crash.ml` (de vrais `kill -9`, le contenu de chaque
confirmation vérifié), `test/wal_sim.ml` (trois bases qui partagent un buffer, avec chaque panne),
`test/server_crash.ml` (un vrai serveur de deux bases, tué). Vérifié par model checking (l'exploration par une
machine de tous les états d'un modèle) : `spec/CommitBuffer.tla`.

## G2 Tout ou rien

*Promesse.* Après la recovery, chaque groupe est soit entièrement présent, soit absent.

*Preuve.* Un groupe est codé à l'intérieur d'une seule frame ; une frame n'est prise que si le CRC de son en-tête et
celui de son corps sont bons (un CRC est un checksum, un petit nombre calculé sur des octets, qui change quand ils
changent) et si ses groupes se décodent jusqu'au bout du corps ; sinon la recovery s'arrête avant elle. Une frame
déchirée au milieu échoue au CRC de son corps, sauf avec une probabilité $2^{-32}$ (pour un dommage aléatoire). La
frame d'un grand groupe, qui le contient seul, est écrite par morceaux au fur et à mesure du codage : tout son corps
d'abord, puis son en-tête, puis son trailer (la fin de frame), puis un seul fsync ; tant que l'en-tête n'est pas écrit,
les morceaux ne font pas de frame (la recovery les coupe comme un torn tail, une fin de journal à moitié écrite), et le
groupe n'est confirmé qu'après le fsync.

*Testé par* la simulation (les groupes sur le disque comparés un par un avec ceux qui ont été écrits) et l'énumération
exhaustive.

## G3 Préfixe

*Promesse.* Après la recovery, les groupes présents sont exactement $1, \dots, k$ pour un certain $k \ge$ le dernier
groupe confirmé, et l'état est l'application des groupes $1, \dots, k$ dans l'ordre.

*Preuve.* Les frames sont ajoutées dans l'ordre des groupes (`Journal.append` refuse un autre ordre) ; la recovery
vérifie que chaque frame commence au groupe attendu et que chaque groupe a le numéro attendu, d'un segment à l'autre
("a segment is missing" sinon), et coupe tout ce qui suit la première frame qui ne passe pas la vérification. Le replay
applique les changements enregistrés dans l'ordre (`Resolve.replay`). Si le run le plus récent dit groupe S, un journal
qui finit avant S est un dommage, pas un historique plus court.

*Testé par* la simulation : après chaque recovery, l'état est comparé au modèle de référence (les groupes enregistrés
1..k appliqués à un ensemble de faits), et on vérifie que k se trouve entre le dernier groupe confirmé et le dernier
groupe préparé.

## G4 Strict serializability

*Promesse.* L'historique des groupes est équivalent à leur exécution un par un dans l'ordre de leurs numéros, et cet
ordre respecte le temps réel : si `write a` est revenu avant que `write b` commence, le numéro de a est plus petit.

*Exactement ce qu'elle couvre.* Les groupes, chacun avec ses `Expect` comme seules lectures. Un read-then-write (la
lecture d'une vue, puis un groupe) n'est serializable que pour les faits et les absences que son groupe énonce avec
`Expect` : un fait lu et non énoncé peut être écrasé par un autre groupe entre-temps (un lost update, une mise à jour
perdue), et un ensemble lu par une question peut gagner un membre entre-temps (un phantom), sauf si un fait qui
représente l'ensemble est attendu et changé par chaque programme qui écrit dans cet ensemble
([concepts](concepts.md#lisolation--exactement-ce-que-voient-un-lecteur-et-un-writer), [théorie](theory.md#5-serializability-et-isolation)).

*Preuve.* Il y a un seul writer par base (G9), et il résout le groupe $n$ sur l'état de travail $S(n-1)$, ce qui
produit $S(n)$ : l'exécution est sérielle par construction (Papadimitriou 1979). Un numéro est donné quand le writer
prend un groupe, donc après qu'il a été soumis ; si $a$ est revenu, son numéro a été donné avant que $b$ soit soumis.
Les lectures des `Expect` d'un groupe sont évaluées sur $S(n-1)$ à l'intérieur du writer, donc un read-modify-write
qui énonce avec `Expect` ce qu'il a lu est serializable (validation optimiste, Kung et Robinson 1981) ; un
read-modify-write qui ne le fait pas n'est pas protégé contre un lost update.

*Testé par* `test/bank.ml` (des virements avec `Expect` depuis 16 threads ; le total est constant dans chaque vue et à
la fin) et le cas nommé de write skew dans `test/unit.ml`.

## G5 Des vues stables et durables

*Promesse.* Une vue est l'état exact après un groupe ; elle ne change jamais ; la vue de la base ne montre que des
groupes durables ; après que `write` a renvoyé le groupe $n$, chaque vue prise ensuite a un numéro $\ge n$ ; les vues
qu'un thread prend ne reculent jamais.

*Conditions.* Sur une base, pas sur un fork (un fork n'a pas de disque : sa vue contient ses écritures tout de suite).
« Ne reculent jamais » vaut pour les vues qu'un même thread prend l'une après l'autre avec `view db` ; deux threads
peuvent tenir des vues de groupes différents. Après un échec de fsync et une réouverture sans redémarrage de la
machine, voir le cas résiduel de G10.

*Preuve.* Une vue est une valeur persistante (des runs immuables et des maps persistantes) ; le writer construit de
nouvelles vues et ne change jamais les anciennes. La vue publiée est remplacée par une seule écriture atomique après le
`fsync` de la frame, avant que les clients reçoivent leur réponse (`Engine.commit`), et les atomiques d'OCaml placent
cette écriture avant la réponse.

*Après une recovery aussi.* L'état sur lequel une recovery ouvre est publié tout de suite, il doit donc être durable :
or un processus tué entre le `pwrite` et le `fsync` d'une frame, ou entre la création d'un segment et le `fsync` de son
répertoire, les laisse dans le page cache, où la recovery les lit et où une coupure de courant ultérieure les reprend.
La recovery écrit donc de nouveau la frame la plus récente (G13 : après un fsync qui a échoué, forcer seul n'écrit
rien) et force le segment le plus récent et le répertoire du journal avant de rejouer le moindre groupe de ce segment
(`Journal.recover`), et l'ouverture force le répertoire de la base, sauf si le dernier processus a fermé proprement :
`close` laisse un marqueur (`DIR/closed`) une fois que chaque frame et chaque nom sont durables, et seulement si aucun
fsync n'a échoué ; une ouverture le supprime avant d'écrire quoi que ce soit. Un marqueur vu signifie donc qu'aucun
processus n'a écrit depuis une fermeture propre, ou qu'une coupure de courant est venue après les écritures, et une
coupure de courant ne laisse rien dans le page cache ; la création et la suppression du marqueur lui-même n'ont besoin
d'aucun fsync (perdues, elles font seulement forcer la prochaine ouverture). PostgreSQL garde le même état dans
`pg_control` (shut down, ou in production). (Trouvé par la simulation dès qu'elle a pu tuer un processus sans coupure
de courant ; mutation check, où l'on retire le code pour voir si les tests échouent : sans le fsync du segment, 9 seeds
sur 300 échouent, sans celui du répertoire, 5.)

*Testé par* le test bank (des domains lecteurs vérifient chaque vue qu'ils prennent : total constant, numéros qui ne
reculent jamais) et la simulation (la vue publiée est égale au modèle à son numéro, qui est $\ge$ le dernier confirmé ;
après une recovery, le numéro rétabli compte comme confirmé, et les morts de processus sont suivies de coupures de
courant).

*Les merges en arrière-plan* gardent G5 : un merge écrit un nouveau run à partir d'une vue et rejoue les groupes
journalisés après elle, et le writer ne passe à ce run que quand rien n'est en cours et que la nouvelle vue contient
exactement les mêmes groupes ; la vue publiée est remplacée par une seule écriture atomique. *Testé par* le test bank,
qui fait un merge toutes les quelques dizaines de changements (156 merges en 4 s) et compare les faits de l'ancienne et
de la nouvelle vue à chaque bascule, et par les tours de kill -9 avec des merges fréquents.

## G6 Rien n'est perdu en silence

*Promesse.* Sous F3, un changement d'octets durables du journal est détecté par la première lecture qui les couvre :
une lecture complète (`Cepheus.verify`, `Journal.read`) le signale ; la recovery refuse d'ouvrir (`Damaged`, avec le
nom du fichier et la position) plutôt que d'écarter une frame durable. Un cas résiduel : un dommage à la frame la plus
récente du journal, sans rien d'écrit après elle, ressemble à un torn write (une écriture interrompue en cours de
route) et est coupé à la recovery (une lecture complète avant la recovery le signale).

*Preuve.* Chaque octet d'un segment est couvert : son en-tête par le CRC d'en-tête, l'en-tête de chaque frame par son
CRC d'en-tête, son corps par le CRC du corps (répété dans le trailer), le trailer par comparaison avec l'en-tête. À la
recovery, la première frame qui ne passe pas la vérification est un dommage quand un en-tête de frame correct la suit
(les frames sont écrites l'une après l'autre, chacune forcée avant la suivante, donc un en-tête plus loin prouve que
cette frame a été écrite entière), ou quand un trailer à la bonne distance porte le CRC du corps (la frame a été écrite
entière, seul son en-tête a changé) ; sinon c'est un torn tail. Un torn write ne peut produire aucun de ces deux signes,
sauf s'il a perdu exactement le secteur de l'en-tête et gardé le reste (après un fsync qui a échoué, c'est plus
probable, les secteurs de l'écriture échouée atteignant le disque ou non un par un : la coupe du writer, G13, retire la
frame avant qu'une coupure de courant puisse la laisser ainsi). CRC-32C détecte toute rafale d'au plus 32 bits et toute
erreur d'au plus 3 bits dans des frames de taille réaliste ; un autre dommage aléatoire échappe avec une probabilité
$2^{-32}$ (Koopman 2002). Une lecture complète est stricte : sur un journal que la recovery a coupé et réparé, toute
frame ou tout trailer qui ne passe pas la vérification est un dommage.

*Vérifié par model checking* (l'exploration par une machine de tous les états d'un modèle) avec `tools/tlc.sh`
(`spec/Journal.tla`) : avec jusqu'à 7 frames et 3 dommages silencieux, des morts de processus et des fsyncs qui
échouent (G13), les invariants Durable, RefuseOnlyOnDamage, PublishedOnDisk, Prefix, NoTornData, StopSafe et
ResidualBound tiennent dans les 3 856 315 états atteignables. TLC a d'abord trouvé une trace où deux frames abîmées à
la fin étaient toutes les deux coupées ; la règle ci-dessus (un en-tête plus loin qui passe la vérification) l'a fermée.

*Testé par* `test/exhaustive.ml` (chaque bit de deux journaux inversé : toujours vu par une lecture complète ; la
recovery refuse, ou garde chaque groupe quand l'inversion a touché un trailer, qu'elle reconstruit, ou, pour une
inversion dans la frame la plus récente, la coupe : compté comme le cas résiduel) et la simulation (des inversions
aléatoires dans les segments durables).

## G7 Les runs sur le disque

*Promesse.* Ouvrir depuis les runs sur le disque et le journal qui les suit donne le même état que rejouer tout le
journal. Une page abîmée d'un run n'est jamais servie : un run qui tient dans le cache est vérifié en entier avant la
première question, et la base se rabat sur d'autres runs ou sur le journal ; une page d'un run plus grand est vérifiée
chaque fois qu'elle est lue sur le disque (y compris quand elle a été abîmée après l'ouverture), et la lecture échoue :
`find` et `fold` renvoient `Damaged`, `get`, `values` et `things` lèvent `Unreadable`, une écriture qui avait besoin de
la page échoue. Jamais une réponse fausse.

*Preuve.* Un run est le fichier d'un merge (G12) : les changements des groupes lo+1..hi par-dessus l'état à lo, nets
(il n'ajoute que des faits absents en dessous de lui, ne retire que des faits présents en dessous de lui), avec la
position dans le journal de la dernière frame durable avant son groupe. L'ouverture prend une chaîne de runs depuis 0,
chacun posé sur la fin de celui d'en dessous (une telle chaîne est toujours l'état à son sommet, puisqu'un run contient
les changements de ses groupes par-dessus l'état à son lo, quels que soient les runs qui font cet état) ; le replay
commence à la position du run le plus récent et saute les groupes qu'il contient. Le chargement vérifie le CRC de
l'en-tête, le CRC de la table des pages et le fait qu'elle place chaque page du fichier au plus une fois, l'ordre des
sections, les rank tables (les tables de rangs : le compte de chaque mot découle des bits qui le précèdent, le dernier
est égal au nombre de choses) et l'ordre et les bornes de chaque table de positions et de chaque répertoire, ceux des
colonnes compris (chaque colonne dans ses sections, les comptes de sa rank table, ses positions de lignes chacune plus
grande que la précédente jusqu'à ses lignes, ses blocs dans l'ordre : `Snapshot.check_and_build`). Un run qui tient
dans le cache est lu et vérifié en entier avant d'être pris ; pour un run plus grand, les pages de ses tables sont lues
et vérifiées d'abord, quand le cache a de la place pour elles (par jusqu'à 4 domains à partir de 64 pages, chacun avec
son propre descripteur). Une page lue dans le fichier d'un run n'entre dans la frame table (la table des emplacements
de pages du cache) qu'une fois vérifié le CRC-32C que donne sa table des pages : à l'ouverture
(`Snapshot.check_and_build`) ou à la demande (`Pages.fill`) ; une page qu'un merge vient d'écrire entre depuis les
octets dont il a calculé le CRC (`Pages.admit`). Aucun autre chemin n'y met une page. Chaque accès à un run vérifie ses bornes (la
frame table, puis les octets de la page ou la copie d'un bloc), donc une lecture ne sort jamais des octets du run. Le
codage des formats 7 et 8 (des blocs par frame of reference, une table des pages, le column order) change ce que
contient une page, pas cet argument : une valeur n'est décodée que depuis une page qui a passé la vérification. Pour un
dommage aléatoire d'une page, CRC-32C le manque avec une probabilité $2^{-32}$ ; il détecte toute rafale d'au plus
32 bits (Castagnoli, Bräuer, Herrmann 1993).

*Plusieurs runs lus comme un seul état.* Un fait est dans une vue si et seulement si l'entrée la plus récente qui le
concerne (celle du delta, ou celle du run le plus récent qui en a une) l'ajoute ; un compte est la somme des lignes de
chaque run moins ses retraits, plus le compte net du delta (les runs sont nets, donc rien n'est compté deux fois) ; une
itération ne montre une ligne d'un run que si aucun run plus récent n'a d'entrée pour le même fait
([théorie](theory.md#9-niveaux-sur-disque-et-grands-groupes), section 9).

*Testé par* la simulation (des merges à des moments aléatoires, des crashs pendant leur écriture, des inversions de bits
dans les fichiers de runs) et `test/unit.ml` (aller-retour ; un run d'une autre base est refusé ; un run aux bits
inversés est mis de côté ; un run trois fois plus grand que le cache, lu par trois domains, avec un bit inversé après
l'ouverture : les questions répondent juste ou renvoient `Damaged`, et c'est exactement la page abîmée qui échoue ;
"several runs" : 120 vues aléatoires de jusqu'à 4 runs qui ajoutent et retirent, comparées à leur merge complet et à un
évaluateur naïf ; "large groups").

## G8 Les forks

*Promesse.* Écrire dans un fork ne change ni la base, ni aucune de ses vues, ni un octet de ses fichiers ; un fork
accepte et refuse exactement ce que la base accepterait et refuserait sur le même état.

*Preuve.* Un fork tient une vue et un mutex (un lock qu'un seul thread tient à la fois), et aucun disque ; ses
écritures passent par `Resolve.resolve`, la fonction qu'utilise le writer, vers le delta persistant propre au fork, et
ses nouveaux textes vers sa propre couche de dictionnaire (un fork n'ajoute jamais rien au dictionnaire partagé de la
base). Les structures persistantes ne sont jamais changées sur place, sauf un bitset des choses touchées, qu'un fork
copie.

*Testé par* la simulation (des forks de la vue publiée où l'on écrit au hasard ; les faits de la vue et les octets de
chaque fichier comparés avant et après) et `test/unit.ml` (deux forks qui reçoivent les mêmes écritures sont d'accord ;
une base et un fork qui reçoivent les mêmes écritures acceptent et refusent les mêmes et finissent égaux ; les fichiers
du journal ne sont pas changés par les forks).

## G9 Un seul writer

*Promesse.* Deux processus ne peuvent pas ouvrir une base en même temps, et un processus ne peut pas l'ouvrir deux
fois, sous aucun chemin qui nomme son répertoire : `shop`, `shop/`, `shop/.`, `./shop`, `x/../shop` et un lien
symbolique vers elle sont une seule base (et un bind mount d'elle aussi, qui montre le même device et le même inode ;
pas testé ici).

*Conditions.* Le lock est consultatif : il arrête un autre Cepheus, pas un programme qui écrit les fichiers sans le
prendre (une copie, un éditeur, un second programme sur une autre machine à travers un système de fichiers réseau dont
les locks n'arrivent pas jusqu'ici).

*Preuve.* L'ouverture prend un lock exclusif `lockf` sur `DIR/lock`, tenu jusqu'à la fermeture ; le noyau le libère
quand le processus meurt. Un lock POSIX appartient à un processus et à un fichier, donc le noyau laisse le même
processus prendre deux fois un lock sur un fichier : à l'intérieur d'un processus, une table des locks tenus refuse une seconde
ouverture. Elle est indexée par l'identité du fichier de lock, ses numéros de device et d'inode (`st_dev`, `st_ino`),
que partagent tous les chemins vers le fichier, plutôt que par le chemin tel qu'il est écrit ou par sa forme canonique
(`realpath` résout les liens symboliques, mais un bind mount donne encore un second nom). Le fait que le lock soit tenu
est décidé par un `stat` du chemin, avant qu'aucun descripteur soit ouvert : fermer un second descripteur d'un fichier
sur lequel le processus a un lock libérerait le lock. Un second `close` d'une base ne fait rien : il ne libère pas de
nouveau le lock (un autre moteur peut le tenir entre-temps) et ne laisse pas le marqueur de fermeture propre dans un
répertoire qu'un autre moteur a ouvert.

*Testé par* `test/unit.ml` (une seconde ouverture renvoie `Busy` sous sept écritures du chemin et à travers un lien
symbolique ; ouvert par le lien, le répertoire est occupé sous son propre nom ; un second close d'un ancien handle
laisse le lock et le marqueur du moteur qui tient la base).

## G10 Arrêt sur une erreur du disque

*Promesse.* Sous F4, après une écriture ou un `fsync` du journal qui a échoué, plus aucun groupe n'est confirmé :
chaque écriture suivante renvoie la même erreur `Io`, jusqu'à ce que la base soit fermée et rouverte ; la recovery part
du journal. Le `fsync` n'est jamais retenté.

*Conditions.* L'arrêt concerne le journal, qui est la vérité. Une erreur du disque pendant qu'un merge écrit un fichier
de run (un merge en arrière-plan, le run d'un grand groupe, `snapshot`) n'arrête pas la base : aucun groupe ne repose
sur ce fichier (il ne prend son nom qu'une fois ses groupes durables, G12), donc le fichier est supprimé, l'erreur va
sur stderr ou à l'appelant de `snapshot`, et le writer continue avec les runs qu'il avait ; un grand groupe dont le run
échoue renvoie `Io` pour ce groupe seulement, et les morceaux de sa frame sont retirés du journal (`Journal.drop`,
forcé ; si cela échoue, la base s'arrête). Un échec du fichier du journal lui-même pendant que le corps d'un grand
groupe est écrit par morceaux arrête la base comme le fait un `append` qui échoue : le journal est coupé jusqu'à sa
dernière frame durable. Un échec pour forcer le run d'un grand groupe ou pour lui donner son nom, après que sa frame
est durable, arrête la base, le groupe étant confirmé (la prochaine ouverture le rejoue depuis le journal).

*Cas résiduel dans cette version.* Ce que sont devenues les écritures qui ont reçu `Io` n'est certain que quand la
coupe du writer jusqu'à la dernière frame durable a réussi (G13) : elles sont alors absentes de tout état ultérieur.
Si le processus est mort avant la coupe, ou si la coupe a échoué elle aussi (sur stderr :
`cepheus: the journal could not be cut back after a failed write`), la frame qui a échoué peut être sur le disque ou
non, et une réouverture peut montrer ses groupes, entiers (G2), bien qu'aucun programme n'ait reçu `Ok` ; une fois
qu'une vue les montre, ils restent (G13). Donc après un `Io`, une application qui doit savoir lit l'état après la
réouverture plutôt que de supposer l'écriture absente. Aucun redémarrage de la machine n'est nécessaire (avant G13, une
réouverture pendant le même démarrage pouvait publier une frame qu'une coupure de courant ultérieure reprenait).

*Preuve.* `Engine.commit` attrape l'erreur, marque le moteur comme arrêté, fait échouer le batch (le lot d'écritures
traitées ensemble) ; `prepare` fait échouer chaque requête suivante tant que le moteur est arrêté. Retenter un `fsync`
après un échec pourrait confirmer des données que le noyau a abandonnées (Rebello et al. 2020).

*Testé par* la simulation (des fsyncs qui échouent, injectés ; une confirmation après l'un d'eux est un échec du test ;
le disque simulé marque les pages comme propres sans les écrire, comme le fait Linux, et un fsync ultérieur ne les
écrit pas non plus : voir G13).

## G11 Des réponses exactes

*Promesse.* Une question renvoie exactement les bindings qui font de tous ses patterns des faits de la vue, chacun une
fois.

*Preuve.* Voir [théorie](theory.md), Generic Join : chaque binding est construit variable par variable à partir de
candidats qui satisfont chaque pattern sur les variables déjà liées, donc chaque résultat est une réponse ; les valeurs
de chaque réponse sont des candidats à chaque niveau (elles satisfont le pattern pris comme source et sont acceptées
par les autres), donc chaque réponse sort ; les candidats d'un même niveau sont distincts, donc aucune réponse ne vient
deux fois.

*Et son coût.* À chaque niveau, les candidats énumérés pour un binding partiel sont le plus petit ensemble qu'offre un
pattern (des comptes exacts, sur la base comme sur le delta) ; chaque autre pattern ne fait que chercher chacun d'eux,
en $O(\log n)$. Le total est l'instance bound de Generic Join (la borne calculée sur les données mêmes ; Ngo, Ré, Rudra
2013), dans l'AGM bound de la question. Un pattern d'une propriété à une valeur dont la chose est liée offre au plus un
candidat ; son compte n'est pas cherché : il est pris avant chaque pattern qui en offre un ou plus et après un pattern
qui n'en offre aucun (`Query.count_with` compare $2c$ pour un compte exact $c$ à 1 pour lui). Dans les deux cas, le
niveau énumère au plus le plus petit compte exact : si le pattern n'a pas de valeur, il ne donne rien, et si un autre
n'en offre aucune, c'est celui-là qui est pris. La borne est donc inchangée, et la borne exacte des tests unitaires
tient toujours. Une vérification laissée au niveau suivant (un pattern dont l'autre côté est la variable suivante) ne
change aucun compte : un binding qui y échoue atteint le niveau suivant, où ce pattern n'offre rien et devient la
source. Le leapfrog (run format 8, [théorie](theory.md#4-generic-join)) lit, à un niveau dont la source est une slice
(une tranche de liste triée) de $m \ge 2$, chaque autre slice d'au plus $8m$ : la borne testée ajoute la taille de ces
slices, au plus $1 + 8 (k - 1)$ fois celle de Generic Join pour $k$ slices.

*Testé par* les tests de propriétés et la simulation : chaque question aléatoire, sur des vues avec un delta et après
des recoverys, doit donner les réponses de l'évaluateur naïf et énumérer au plus la borne que `test/check.ml` calcule à
partir des seuls faits (`Query.work` compte les candidats) ; et des cas nommés où une liste est bien plus grande que la
réponse (un statut partagé par 20 000 factures, un tag très fréquent dans le delta, un intervalle de 10 scores parmi
20 000, une chose avec 40 000 valeurs). Et par `test/unit.ml` : 300 bases aléatoires et 15 questions aléatoires pour chacune (jusqu'à 3 patterns, des
constantes, des liens, des intervalles) comparées à un évaluateur naïf sur tous les faits, sur une base avec un delta
et sur une base compactée.

*Avec Not, Or et In* ([Cepheus depuis Cesia](cesia.md#not-or-et-in)), la promesse porte sur les variables propres
à la question : ses bindings qui font tenir ses patterns et ses conditions, qui font tenir une alternative de chaque
`Or` pour une valeur des variables propres à cette alternative, et pour lesquels aucune valeur des variables propres à
chaque `Not` ne fait tenir ses éléments, chacun une fois. `In` restreint les candidats, `Not` ne fait que retirer des
bindings, et un `Or` est une union disjointe (l'alternative j avec les alternatives d'avant elle comme des `Not` : un
binding tient pour un plus petit j, et il est une réponse de la question j et d'aucune autre), donc chacun vient une
fois ; une alternative qui a ses propres variables garde les bindings qu'elle a donnés. Avec Sort, Limit et After, les
lignes sont celles du select (ce que la question renvoie), dans l'ordre, coupées comme le dit le chapitre. *Testé
par* `test/questions.ml` : des états aléatoires (chaque type, des flottants avec nan et -0, les faits dérivés d'une
règle, des retraits, des runs fusionnés au hasard) et des questions aléatoires avec des patterns, des intervalles,
`Not`, `Or`, `And` et `In`, et un select, Sort, Limit et After aléatoires, répondues par un oracle (un évaluateur de
référence) en force brute sur chaque fait (les bindings, les groupes, l'ordre valeur par valeur, le curseur, les
ex aequo), et par le moteur sur le chemin du heap (un tas qui garde les meilleures lignes), sur le chemin de l'index et
selon son propre choix, avant et après un aller-retour sur le réseau : les mêmes lignes, dans le même ordre ; et des
questions vivantes avec `Not`, `Or` et `In` vérifiées par l'oracle après chaque frame.

## G12 Les merges sont atomiques

*Promesse.* Après un crash à n'importe quel point d'un merge (F1, F2, F4), la base s'ouvre sur les runs d'avant ou sur
les runs d'après, chacun entier, jamais un mélange ; son état est le replay du journal jusqu'au groupe rétabli (G7) ;
aucun run n'a à être mis de côté et aucun fichier de merge ne reste. Un merge n'a pas besoin de plus de mémoire que le
cache, quelques buffers de page et 21 octets par page du nouveau run (voir [théorie](theory.md), section 8).

*Preuve.* (a) Un merge écrit son fichier sous un nom temporaire et le force avant le rename (le renommage) : un nom,
durable ou non, ne pointe jamais vers des octets qui ne sont pas sur le disque (le run d'un grand groupe est forcé dans
son commit, en même temps que le fsync de sa frame, sur l'autre fichier ; `Snapshot.install` force tout run pas encore
forcé avant de le renommer). (b) Le rename est atomique ; sous F2, un préfixe des changements de noms du répertoire
survit : le nouveau nom, ou pas. (c) Un fichier ne reçoit son nom qu'une fois son groupe durable dans le journal :
l'installation se fait quand rien n'est en cours (le writer a attendu le syncer), ou, pour le run d'un grand groupe,
dans le commit après que la frame du groupe a été forcée ; et seulement si aucun fsync n'a échoué (G10) ; les merges
qu'une recovery fait en rejouant une longue fin de journal viennent après qu'elle a écrit de nouveau la frame la plus
récente et forcé le journal (G5, G13). Le journal n'est jamais coupé en dessous d'un run : un journal qui finit avant le
groupe du run le plus récent a perdu des frames durables, et la base refuse de s'ouvrir (G6). (d) Les runs qu'un merge
a remplacés ne sont supprimés qu'après le fsync du répertoire qui a rendu le nouveau nom durable, donc une chaîne
jusqu'au groupe le plus récent a toujours un nom. (e) L'ouverture supprime les fichiers `.tmp` des merges interrompus,
et prend la chaîne de runs nommés depuis 0 qui atteint le groupe le plus récent avec le moins de runs (G7). Un merge qui
échoue (une erreur du disque pendant l'écriture) supprime son fichier et le writer continue avec les anciens runs ; le
merge suivant attend que le delta ait grandi d'un seuil de plus.

*Testé par*
- l'énumération exhaustive (`test/exhaustive.ml`, partie 4) : à chaque appel au disque qui change quelque chose
  pendant un merge (un merge immédiat de tous les runs ; un merge commencé depuis une vue en avance sur le disque et
  installé deux frames plus tard ; celui d'un grand groupe, fait pendant que le groupe est préparé et nommé une fois sa
  frame durable ; les merges d'une recovery qui rejoue une longue fin de journal), chaque état de crash : une mort du
  processus (puis une coupure de courant), et des coupures de courant qui gardent chaque préfixe des changements de
  noms de chaque répertoire, avec les octets non forcés perdus, gardés, déchirés, ou gardés un secteur sur deux :
  194 points de crash, 1 944 états, chacun rétabli et vérifié (l'état de la référence, chaque groupe confirmé, les
  anciens ou les nouveaux runs, rien mis de côté, aucun `.tmp` restant) ;
- la simulation (des merges des runs les plus récents à des niveaux aléatoires, commencés en avance sur le disque et
  installés quelques pas plus tard, abandonnés après un fsync qui a échoué ; des grands groupes ; des morts de
  processus ; des crashs à l'intérieur de n'importe quel appel au disque d'un merge ; le fichier d'un merge forcé
  toutes les 8 pages) ;
- les tours de kill -9 (des merges tous les 50 changements ; les tours qui tuent pendant un merge sont comptés) ;
- `spec/Merge.tla`, vérifié par TLC (`tools/tlc.sh`) : des chaînes de runs nommés par leurs groupes, des merges de
  n'importe quel nombre des runs les plus récents, la recovery qui prend la chaîne qui atteint le groupe le plus
  récent ; les invariants NoMix, SnapshotInJournal, ChainNamed (les runs qu'un processus lit sont nommés et forment une
  chaîne depuis 0), PublishedDurable, AckedDurable sur 983 080 états (3 groupes) ; chacune de ses cinq règles (forcer
  avant le rename, n'installer que quand c'est durable, forcer le journal à la recovery sans marqueur, un marqueur
  seulement si aucun fsync n'a échoué, la frame la plus récente écrite de nouveau à la recovery), retirée tour à tour,
  donne un contre-exemple en 4 ou 5 pas ;
- `test/unit.ml` : un merge d'un run 8 fois plus grand que le cache garde chaque fait, tient au plus 7 pages ouvertes,
  et n'a jamais plus de pages en mémoire que le cache.

## G13 On ne se fie jamais à un fsync qui a échoué

*Promesse.* Sous F4 tel que Linux l'implémente, mêlé à F1 et F2 dans n'importe quel ordre : aucune vue ne montre jamais
un groupe qu'une coupure de courant ultérieure peut retirer, que ce soit dans le processus où le `fsync` a échoué,
après une réouverture pendant le même démarrage (qui lit le page cache), ou après un redémarrage ; chaque groupe
confirmé reste (G1) ; un refus d'ouvrir ne vient jamais de l'échec lui-même. Et une écriture qui a reçu une erreur `Io`
est absente de tout état ultérieur, sauf si le processus est mort avant que le journal soit coupé ou si la coupe a
échoué elle aussi : elle peut alors être présente après une réouverture, et une fois qu'une vue la montre, elle reste.

*Pourquoi il le fallait.* Avant cette garantie, l'ouverture suivante pendant le même démarrage forçait le journal, ce
qui n'écrivait rien (les pages étaient propres), lisait la frame qui avait échoué dans le page cache, la publiait, et
ajoutait après elle. Une coupure de courant reprenait ensuite la frame : des lecteurs avaient vu un groupe qui avait
disparu, et les frames confirmées après le trou faisaient refuser l'ouverture de la base. L'article trouve le même
"false failure" (un faux échec) dans LevelDB, le write-ahead log de SQLite et PostgreSQL, dont la recovery lit le log à
travers le page cache (section 4.3). La simulation l'a trouvé dès que son disque a modélisé F4 de cette façon (8 seeds
sur 300 échouaient) ; avant, son `fsync` copiait sur le disque chaque octet en mémoire, y compris les octets qu'un
`fsync` échoué avait marqués propres.

*Preuve.* (a) Dans le processus en cours, une vue n'est publiée qu'après que le `fsync` de sa frame est revenu (G5).
Cette frame a été écrite entière après le dernier `fsync` réussi, donc chaque page qu'elle touche est dirty (modifiée
en mémoire et pas encore écrite sur le disque), et un `fsync` réussi les écrit. Après un échec, le writer s'arrête
(G10) et ne publie plus rien. (b) Le writer coupe alors le journal jusqu'à la fin de sa dernière frame durable
(`Journal.cut`) : le fichier tronqué à cet endroit, un segment qu'une bascule échouée avait commencé supprimé, le
fichier et le répertoire forcés. Quand cela réussit, la frame échouée n'est ni dans le page cache ni sur le disque,
donc son écriture est absente pour de bon, et aucune coupure de courant ne peut en laisser une partie que la recovery
prendrait pour un dommage (la fausse alerte de G6, une frame dont seul le secteur de l'en-tête a été perdu). (c) Le
processus peut mourir avant la coupe, ou la coupe peut échouer. Donc une recovery après autre chose qu'une fermeture
propre écrit de nouveau la frame la plus récente du journal avant de rejouer le moindre groupe du segment le plus
récent (`Journal.rewrite_newest` ; l'en-tête du segment quand il ne contient aucune frame), puis force le segment et le
répertoire. Seule cette frame peut manquer sur le disque : les frames sont écrites une à la fois, chacune forcée avant
la suivante ; le writer s'arrête au premier échec ; un segment n'est commencé qu'une fois chaque frame du précédent
durable. Les pages écrites de nouveau sont dirty, donc un `fsync` réussi les écrit : sur ext4 et XFS, les octets en
mémoire sont la frame, qui devient durable ; sur Btrfs, ce sont déjà ceux du disque, et les écrire de nouveau ne change
rien. Si ce `fsync` échoue, l'ouverture échoue et ne publie rien ; la suivante écrit de nouveau. C'est le conseil même
de l'article : rendre les pages de nouveau dirty en les réécrivant (section 5, #7), et faire reposer la recovery sur ce
que contient le disque (#8). Rien n'est retenté à l'aveugle (G10) : un `fsync` qui suit une nouvelle écriture des mêmes
octets est une nouvelle écriture. (d) Après une fermeture propre, aucun `fsync` n'avait échoué : `close` ne laisse son
marqueur que dans ce cas. (e) Après une coupure de courant, les lectures montrent le disque. Coût : un `pwrite` de la
frame la plus récente à une ouverture après un crash (quelques KB, au plus 8 MiB pour les frames de petits groupes ; la
frame entière d'un grand groupe, jusqu'à 256 MiB, quand c'est la plus récente, réécrite à travers la fenêtre de
4 MiB) ; rien à une ouverture après une fermeture propre, rien sur le chemin des écritures.

*Vérifié par model checking* avec `tools/tlc.sh` : `spec/Journal.tla` modélise à part le page cache et le disque (écrit
et non forcé, marqué propre par un `fsync` échoué, gardé ou défait en mémoire, une troncature forcée ou non), des morts
de processus avec des recoverys qui lisent le page cache, et des coupures de courant ; ses invariants PublishedOnDisk
(chaque frame que des lecteurs peuvent voir est sur le disque), RefuseOnlyOnDamage, Durable, StopSafe tiennent dans
les 3 856 315 états (7 frames, 3 dommages). Sans la réécriture de la recovery, TLC trouve un contre-exemple en 4 pas,
même avec la coupe du writer : écrire, le `fsync` échoue, le processus meurt avant la coupe, la recovery publie la
frame. Sans la coupe du writer, les invariants tiennent encore (la coupe est ce qui rend certaine l'issue d'une
écriture échouée, ce que le modèle n'énonce pas). `spec/Merge.tla` a la même règle (RewriteAtRecovery) ; sans elle, un
groupe publié n'est pas durable en 5 pas.

*Testé par*
- la simulation, dont le disque fait désormais ce que l'article a mesuré : un `fsync` échoué marque propres les
  secteurs écrits, garde leurs octets en mémoire (ext4, XFS ; la nouvelle taille rendue durable au hasard) ou les
  défait (Btrfs, un tiers des seeds), et un `fsync` ultérieur n'écrit que les secteurs écrits depuis ; une coupure de
  courant résout les secteurs marqués propres en perdus, gardés ou déchirés. Des fsyncs échoués sont injectés, parfois
  avec une mort du processus quelques appels plus tard (pendant la coupe). Mutation check, 1 000 seeds : sans la
  réécriture (la coupe gardée), 1 seed échoue ; sans la coupe (la réécriture gardée), aucun n'échoue mais 2 finissent
  sur la fausse alerte de G6 (un refus d'ouvrir après une coupure de courant qui a gardé la frame échouée sans le
  secteur de son en-tête) ;
- l'énumération exhaustive (`test/exhaustive.ml`, partie 5) : chaque `fsync` d'une petite exécution (des frames, des
  bascules de segment, un merge) échoue tour à tour, sur les deux sortes de systèmes de fichiers ; le processus meurt à
  chacun des quatre appels au disque suivants ou continue ; une réouverture pendant le même démarrage ou aucune ; une
  coupure de courant qui garde tous les changements de noms ou aucun, les octets non forcés perdus, gardés, déchirés ou
  gardés un secteur sur deux ; chaque réouverture doit donner un état de la référence avec chaque groupe confirmé, et
  ce que la première réouverture a publié doit survivre : 13 fsyncs, 2 880 réouvertures, aucun échec. Sans la
  réécriture, 44 d'entre elles échouent (les morts entre le fsync échoué et la coupe).

## G17 Une matérialisation exacte

*Promesse.* Chaque vue — de n'importe quel groupe, dans n'importe quel processus, après n'importe quel crash et
n'importe quelle recovery, d'un fork — contient exactement le **least model** (le plus petit modèle) de ses faits
affirmés sous les règles définies à son groupe (avec `Not` et des agrégats : le **perfect model**, le modèle parfait,
des règles stratifiées, c'est-à-dire rangées en strata, des étages dont chacun ne lit sous une négation et sous les agrégats
que ce que donnent les étages plus bas, le perfect model étant le least model calculé étage par étage ; [Apt 1988],
[Przymusinski 1988]) : un fait est dans la vue si et seulement s'il est affirmé ou s'il a une
preuve (un arbre fini d'instances de règles dont les feuilles sont des faits affirmés). Et un fait est marqué affirmé
dans la vue si et seulement s'il est affirmé.

*Conditions.* Les règles telles que cette version les a : du Datalog avec `Not` et des agrégats (`Sum`, `Count`, `Min`,
`Max`) stratifiés et sans nouvelles choses dans les têtes, chaque règle range-restricted (chaque variable de la tête
apparaît dans le corps) et typée (vérifié quand elle est écrite ; la propriété d'un pattern est une constante ou une
variable liée par un pattern dont la propriété est une constante, et les types de ses valeurs sont ceux de la propriété
à chaque instance). Un groupe refusé (par son budget, une contrainte, une règle du schéma, un fait dérivé qui ne
convient pas à sa propriété) ne laisse rien.

*Avec l'égalité* (une règle dont la tête donne `cepheus/same`, comme celles d'OWL 2 RL, le profil de règles du langage
d'ontologies OWL du W3C) : les classes de choses égales sont celles du least model des règles avec l'égalité
axiomatisée (eq-ref, eq-sym, eq-trans, eq-rep-s, eq-rep-p, eq-rep-o : [W3C 2012], Table 4), chaque membre sauf son
représentant (la chose qui tient lieu de toute sa classe) ayant `[x cepheus/same r]` ; et les faits de la vue, chaque
chose lue comme le représentant de sa classe, sont ceux de ce modèle, lus de la même façon : un fait seulement dérivé
nomme des représentants, un fait qu'un programme a affirmé reste tel qu'il a été écrit (la réécriture de
[Motik 2015b], Théorème 1 : T et ρ ensemble représentent la matérialisation de l'égalité axiomatisée). *Esquisse de
preuve.* Insertion : chaque égalité que donne une instance fusionne deux classes avant que le fait suivant soit traité,
et chaque fait qui nomme le représentant du plus petit côté est réécrit sur celui du plus grand au tour suivant, donc
les règles, qui ne lisent que des représentants, voient exactement les faits réécrits (l'invariant 2 de Motik et al. :
chaque fait non marqué est sa propre réécriture) ; la réécriture d'un fait est dérivée de la réécriture de ses
prémisses, donc le least model réécrit est atteint. Retrait : une classe dont les faits ont pu perdre une preuve est
défaite (chaque membre redevient son propre représentant, chaque fait seulement dérivé qui nomme son représentant est
supprimé, ses conséquences vérifiées par B/F, Backward/Forward, l'algorithme qui retire les faits restés sans preuve)
et les faits affirmés de ses membres forment le tour 0 de l'insertion : Delete-Rederive (supprimer, puis dériver de
nouveau) sur la classe ([Gupta 1993]), exact quel que soit l'ordre des suppressions. *Testé par* `test/owl.ml` contre
`Check.least_eq` (un union-find, la structure qui tient des classes que l'on fusionne, chaque fait réécrit après chaque
passe), sur cinq chemins et des suites aléatoires avec des retraits ; un mutant (une copie du code changée exprès) qui
ne défait jamais une classe échoue à 75 vérifications.

*Preuve.* (1) *Insertion.* La semi-naive evaluation à partir des ajouts affirmés du groupe atteint le plus petit point
fixe des règles sur l'état après les retraits : chaque instance de règle avec un fait du tour r est énumérée au tour r
(les atomes avant celui qui correspond, sur les tours en dessous de r, ceux d'après sur les tours jusqu'à r), donc
chaque instance qui met en jeu un nouveau fait est trouvée, chacune une fois ([Bancilhon 1986], [Ramakrishnan 1990]) ;
les instances sur des faits plus anciens seulement ont été trouvées par les groupes d'avant (récurrence sur les
groupes). (2) *Retrait.* Backward/Forward retire exactement les faits restés sans preuve ([Motik 2015]), sous trois
conditions que cette implémentation respecte et que les tests vérifient : les instances perdues d'un fait supprimé sont
énumérées sur l'état d'avant son départ ; les faits retirés du groupe quittent tout de suite l'ensemble des faits
affirmés, et l'état seulement quand leur preuve est réfutée ; un fait retiré puis affirmé de nouveau est affirmé.
(3) *Changements de règles.* Une règle ajoutée est évaluée sur tout l'état (ses instances sur des faits plus anciens),
puis avec les autres par la semi-naive evaluation ; une règle supprimée donne ses têtes à B/F comme candidats.
(4) *Durabilité.* Les changements dérivés sont dans la frame même du groupe, écrits et forcés avec elle (G1, G2) ; le
replay les applique selon leur sorte et n'évalue rien, donc une vue rétablie, celle d'une replica ou celle du passé est
celle du writer, octet pour octet de faits. (5) *Runs.* Un merge garde l'indicateur de chaque fait : pour chaque fait,
l'entrée la plus récente donne son état dans la nouvelle vue et la plus ancienne son état en dessous des runs
fusionnés ; un indicateur changé est un retrait et un ajout dans le nouveau run.
(6) *Les modules de closure.* Pour prp-trp (la règle d'OWL 2 RL d'une propriété transitive) sur $T$, le $T$ du least
model est la transitive closure $T^+$ (la fermeture transitive : chaque paire reliée par un chemin) des autres faits
de $T$ ; pour la paire linéaire (deux règles : chaque arête donne un fait de la closure, et une arête suivie d'un fait
de la closure en donne un), c'est $E^{\ast} \circ (E \cup B)$, $B$ étant les faits de $T$ affirmés ou donnés par d'autres
règles. De zéro, le module calcule exactement ceux-ci sur les composantes fortement connexes (les cibles d'une
composante sont celles de ses successeurs avec eux, et ses propres membres quand elle contient un cycle), et fait
chaque paire qui n'est pas présente ; de façon incrémentale, l'état avant le groupe contient la closure (G17 pour le
groupe d'avant, par récurrence), donc une nouvelle arête $(a, b)$ ajoute exactement
$(\{a\} \cup \mathrm{pred}(a)) \times (\{b\} \cup \mathrm{succ}(b))$ (pour la paire linéaire : les choses qui atteignent $a$
par $E$, et, pour un nouveau fait $(c, d)$ de $B$, celles qui atteignent $c$, fois $d$), chaque nouveau fait au tour
suivant, où les autres règles le voient. Retrait par des parcours : si aucune autre règle ne donne $T$ ou $E$, les
arêtes sont les faits que le groupe laisse affirmés, donc les nouvelles cibles d'une source sur les arêtes restantes
sont ses cibles dans le least model ; une source qui n'atteint aucune arête retirée les garde (ses chemins sont
intacts), donc seules les sources calculées peuvent perdre des faits, et elles perdent exactement ceux qui sont hors de
leurs nouvelles cibles. Sinon, B/F avec les plans des deux règles, exact par (2).
(7) *Les propriétés variables et le dépliage.* Une règle dépliée (unfolded : réécrite en une règle par fait d'une
petite relation, les constantes à leur place) est la règle générique où les variables de ses petits atomes sont
remplacées par les mots d'un de leurs bindings communs dans la vue (les intervalles gardés, les instances qui ne
peuvent pas exister écartées) : sur tout état dont les petites relations contiennent exactement ces faits, les
instances des règles dépliées sont celles de la règle générique, une pour une. Le writer n'utilise le programme déplié
que pour un groupe dont l'état les garde : la vue contient les faits sur lesquels il a été déplié (vérifié à chaque
groupe), le groupe n'en affirme ni n'en retire aucun, et la dérivation ou la suppression de l'un d'eux fait recommencer
le groupe avec les règles telles qu'elles sont écrites. Une relation ne sert au dépliage que si aucune chaîne de règles
ne mène des têtes des règles dépliées jusqu'à elle, donc les preuves de ses faits ne passent pas par les règles
dépliées sur elle : les vérifications du programme déplié (B/F) le supposent, et cela tient alors.
(8) *Les strata.* Un ensemble de règles avec un cycle à travers `Not` ou un agrégat est refusé à sa définition, donc
chaque règle ne lit sous `Not` et sous les agrégats que ce que donnent les strata plus bas. Les strata sont tenus à jour
dans l'ordre : quand le stratum $s$ tourne, ceux d'en dessous contiennent leur perfect model de l'état du groupe
(récurrence sur $s$), donc ce sont des faits fixes pour $s$, et les règles de $s$ sont monotones dans les faits propres
à $s$ ; (1) et (2) s'appliquent à elles, avec les instances que les changements des strata plus bas enlèvent et
donnent : un fait rendu présent que filtre un `Not` enlève les instances que ce `Not` permettait (les candidats de
B/F, leurs instances perdues énumérées avec les `Not` lus sur l'état d'avant le groupe) ; un fait parti donne les
instances que son absence permet (le tour 1 de l'insertion) ([Motik 2019]). Les réponses qu'un agrégat réunit sous
une clé ne changent que par des réponses qui contiennent l'un des faits que le groupe a changés : chacune de ces
réponses est trouvée une fois, à partir de ce fait (sur l'état d'après le groupe s'il est venu, d'avant s'il est
parti), et la somme et le compte changent de la somme des changements des réponses ([Budiu 2023]) ; un minimum ou un
maximum est relu sur toutes les réponses de sa clé quand l'extrême les a quittées. Aucune écriture n'affirme la
propriété d'un agrégat et aucune autre règle ne la donne, donc ses faits sont exactement les valeurs de l'agrégat.

*Testé par* `test/reasoning.ml` (après chaque groupe de suites aléatoires de 60 groupes, 60 seeds simples et 60 avec les
faits fusionnés en runs entre les groupes dans `tools/test.sh`, `RULES_SEEDS` pour plus : des règles aléatoires sûres et
typées définies, changées et supprimées, des ajouts et des retraits aléatoires de faits affirmés, dérivés et les deux,
la vue égale au plus petit modèle de ses faits affirmés recalculé de zéro par évaluation naïve avec l'évaluateur propre
au vérificateur, `Check.least`, et ses faits affirmés égaux à ceux du modèle ; parmi les règles, des transitive
closures des deux formes et des règles sur une propriété variable liée par une petite relation, que le moteur déplie ;
et les suites simples une seconde fois avec le dépliage coupé, la vue de chaque groupe égale à celle de l'exécution
dépliée, et avec les closures retirées par B/F au lieu des parcours ; le cas nommé "a closure's retractions decided by
walks" : 120 groupes d'ajouts et de retraits sur les deux formes et une règle qui lit les deux, le least model après
chacun, les règles aléatoires avec des `Not` et des agrégats (`Sum`, `Count`, `Min`, `Max` sur des propriétés int à
une valeur qu'aucune écriture n'affirme) comparées au perfect model recalculé de zéro, stratum par stratum
(`Check.perfect`, les strata par les plus longs chemins), les cycles à travers eux refusés comme prévu, et les mêmes
vues que celles de B/F) ; la simulation (trois règles à partir
du troisième groupe de chaque seed : les vues publiées, rétablies et de fork égales au plus petit modèle, après des
crashs à chaque appel au disque, des coupures de courant, des fichiers abîmés, des merges commencés en avance) ;
`test/crash.ml` (une règle marque la chose de chaque client ; après chaque `kill -9`, chaque chose confirmée a sa
marque, celles du chargeur aucune).

## G18 Les contraintes tiennent

*Promesse.* Aucun groupe confirmé ne laisse une instance d'une contrainte (une règle dont la tête est `Never`) ; un
groupe qui en laisserait une est refusé en entier, `Invalid "constraint NAME: …"` ; une contrainte ne se définit que
sur un état sans instance d'elle.

*Preuve.* Les règles sans négation sont monotones : une nouvelle instance du corps d'une contrainte a besoin d'un fait
que le groupe a rendu présent. Après le point fixe, les plans de la contrainte tournent sur chacun de ces faits (chaque
atome du corps mis en correspondance avec lui, les autres sur l'état final) ; avec un `Not`, une instance vient aussi
d'un fait que le groupe a enlevé et que le `Not` lisait, et les plans tournent aussi sur chacun de ces faits (le
pattern de son `Not` mis en correspondance avec lui, le reste sur l'état final) ; une contrainte ajoutée tourne sur tout
l'état. Un groupe qui trouve une instance lève une exception avant que sa frame soit faite.

*Testé par* `test/reasoning.ml` (des contraintes aléatoires parmi les règles aléatoires : un groupe est refusé
exactement quand le plus petit modèle d'après lui a une instance de l'une d'elles, vérifié de zéro ; le cas nommé : le
groupe refusé ne change rien).

## G19 Un changement de règle prend effet à un seul groupe

*Promesse.* Définir, changer ou supprimer des règles prend effet au groupe qui l'écrit : chaque vue d'avant contient le
plus petit modèle sous les anciennes règles, chaque vue à partir de ce groupe le plus petit modèle sous les nouvelles.

*Conditions.* Aucune : sur un fork et dans le cœur déterministe, le changement est raisonné dans son groupe ; dans le
writer à threads d'une base sur le disque, il est calculé à côté du writer et installé comme un seul groupe
([règles](rules.md#les-changements-des-règles-en-arrière-plan)) ; un crash à n'importe quel moment compris.

*Preuve.* Les faits de la règle et les changements dérivés qu'ils causent forment un seul groupe : G2 les rend tous
visibles d'un coup, ou aucun.
Sur le chemin en arrière-plan, la frame de ce groupe est la différence exacte entre la vue du writer et celle de
l'arrière-plan, qui est le least model de l'état au switch (l'instant où le writer adopte la nouvelle vue) sous les
nouvelles règles : chaque batch de groupes que l'arrière-plan a rattrapé la garde telle (le least model est une
fonction des faits affirmés, et le raisonnement incrémental l'atteint : G17), et la partie affirmée du changement
commute avec ces groupes (aucun fait en commun, vérifié, sinon `Conflict`). Le writer n'adopte cette vue qu'avec le
groupe, donc aucune vue d'avant lui ne contient un fait des nouvelles règles ; le replay de la frame donne la vue
adoptée, donc une recovery, une replica ou un lecteur local reçoit entière chaque vue à partir de lui. Avant que sa
frame soit durable, le changement n'est pas confirmé, et un crash n'en laisse rien. Le protocole est vérifié par
model checking (`spec/RuleChange.tla`).

*Testé par* `test/reasoning.ml` (des règles définies, changées et supprimées au hasard parmi les écritures, sur des
forks et sur des bases sur le disque où chaque changement prend le chemin en arrière-plan : G17 vérifié sur la vue de
chaque groupe, les mêmes décisions que celles du modèle, et la base rouverte à l'identique) ; `test/rulechange.ml` (des
groupes écrits pendant qu'un changement est retenu après sa construction, rattrapés exactement et rangés avant lui ; un
groupe qui interfère y met fin par `Conflict` ; 6 clients qui écrivent, 24 changements et 2 lecteurs qui vérifient
chaque vue qu'ils prennent contre le least model sous ses propres règles ; une fermeture pendant un changement ; des
kill -9 pendant des changements, chaque vue rétablie exacte ; la même chose avec les faits dérivés de chaque
changement dans un run à eux, tué aussi entre leur écriture et l'installation) ; `tools/tlc.sh` (`spec/RuleChange.tla`,
et ses treize variantes qui doivent échouer, parmi elles la reprise de frames par un membre de Raft, l'algorithme de
consensus qui garde le même log sur plusieurs serveurs, et le run à lui des faits d'un changement).

## G20 `why` renvoie une preuve

*Promesse.* `why v e p x` sur un fait de v renvoie une preuve bien fondée : ses feuilles sont des faits affirmés de v,
ses nœuds des instances de règles définies à v dont les faits du corps sont ses enfants, chaque enfant prouvé avant son
parent ; sur un triplet qui n'est pas un fait de v, elle renvoie `None`.

*Preuve.* La preuve est construite par la vérification arrière de B/F sur v, sans rien supprimer : un fait est prouvé
quand il est affirmé, ou quand une instance dont les faits du corps sont tous prouvés l'a pour tête ; l'instance qui a
prouvé chaque fait est gardée à ce moment-là, donc les enfants de chaque nœud ont été prouvés avant lui, et l'arbre n'a
pas de cycle. Par G17, chaque fait dérivé de v a une preuve, que la vérification trouve : elle explore chaque instance
de chaque règle qui donne le fait, jusqu'à ce que l'une soit prouvée.

Avec l'égalité, un fait d'un représentant qui réécrit le fait affirmé d'un membre est prouvé par un nœud
`cepheus/same` dont les enfants sont ce fait affirmé et les faits des classes (`[x cepheus/same r]`, eux-mêmes des
nœuds de `cepheus/same` sans enfants : la preuve d'une égalité elle-même n'est pas encore donnée).

*Testé par* `test/reasoning.ml` (un groupe sur cinq de chaque suite aléatoire : la preuve de chaque fait dérivé
vérifiée nœud par nœud — la règle de chaque nœud existe, les atomes de son corps se lient de façon cohérente aux faits
des enfants dans l'ordre, sa tête est le fait du nœud, ses intervalles tiennent, chaque feuille est affirmée dans la
vue — et le cas nommé d'une preuve en deux étapes).

## La sécurité des règles


- **Un travail et une mémoire bornés.** Chaque fait dérivé compte dans le budget ($100\,000 + 100 \times$ les
  changements affirmés du groupe) sur chaque chemin : l'instance d'un plan, chaque fait qu'un module de closure fait de
  façon incrémentale, les cibles d'un batch vérifiées contre le budget à mesure qu'elles grandissent (donc sa mémoire
  avant un refus est en proportion du budget), les faits d'une forêt comptés avant qu'aucun soit fait, et les
  suppressions de B/F. Un ensemble de règles ou des données dont les conséquences le dépassent sont refusés en entier,
  en nommant la règle : jamais un writer qui manque de mémoire ou qui cale sur une closure de $n^2$ faits.
  *Testé par* `test/reasoning.ml` ("a closure past the budget" : des chaînes de 200 dans un groupe, les deux formes de
  règles, des arêtes vers des choses plus anciennes et plus récentes ; l'arête qui joint deux chaînes de 40 ; le
  prp-trp du W3C déplié sur une chaîne ; chacun refusé en entier, la vue inchangée, le least model après).
- **Un changement des règles est borné et peut être arrêté.** Ses faits dérivés comptent dans le budget d'un
  changement ($100\,000 + 100 \times$ ses changements affirmés $+ 4 \times$ les faits de la base), à la construction
  et sur les groupes qu'il rattrape, donc sa mémoire reste en proportion de la base : une règle de $n^2$ faits est
  refusée, nommée, pendant que les autres clients continuent d'écrire. Un tour sur plusieurs domains garde en têtes au
  plus deux fois le budget restant avant de revenir à un seul domain, qui refuse là où il le doit. Si l'arrière-plan
  prend 65 536 groupes de retard, le writer l'attend : la liste des groupes à rattraper et les deltas restent bornés.
  Une fermeture annule un changement en cours (son raisonnement vérifie un indicateur tous les 1 024 faits dérivés) ;
  un kill ne laisse rien d'un changement pas encore durable. Les règles ne sont écrites que par des tokens qui écrivent
  chaque kind (un kind regroupe les propriétés d'une sorte de chose ; le serveur le vérifie avant que l'écriture soit
  mise en file, comme pour toute règle). *Testé par* `test/rulechange.ml` (un produit cartésien refusé pendant qu'un
  client continue d'écrire ; une fermeture ; kill -9) et `test/server_unit.ml` ("rules are for write
  tokens").
- **Les règles dépliées donnent exactement les règles telles qu'elles sont écrites.** À côté de la preuve de G17 (7),
  les suites aléatoires tournent une troisième fois avec le dépliage coupé (`Reason.specialise`), et la vue de chaque
  groupe doit être égale à celle de l'exécution dépliée, et les deux au least model recalculé de zéro : une faute du
  dépliage ne peut pas changer une réponse sans qu'on le voie.
- **Les droits par kind et les faits dérivés.** Un fait dérivé est un fait de sa propriété, lu sous les droits de son
  kind comme n'importe quel autre. Il peut venir de faits d'autres kinds (le corps d'une règle) : `sources v p` donne
  les propriétés dont peuvent venir les faits dérivés d'une propriété, de proche en proche, sur les règles telles
  qu'elles sont écrites (si on ne les connaît pas : une propriété variable lit n'importe laquelle). Un lecteur autorisé
  à certains kinds seulement n'apprend, par les faits dérivés d'une propriété, rien qu'il n'ait le droit de lire quand
  il lit chaque kind de ses sources, et les droits par kind du serveur en tiennent compte : un tel lecteur ne lit une
  propriété que s'il lit aussi chaque kind de ses sources, et un refus par les règles ne lui nomme que la règle
  ([serveur](server.md)). *Testé par* `test/reasoning.ml` ("where a property's derived facts come from") et
  `test/server_unit.ml` ("rules and kinds" : des règles, des faits et des tokens aléatoires, les lectures de chaque
  token comparées au propre calcul de l'oracle).
- **Les tempêtes d'égalités restent linéaires.** Celui qui écrit des règles peut rendre beaucoup de choses égales (une
  propriété fonctionnelle, qui n'a qu'une valeur par chose, avec n valeurs sur une chose) : n choses coûtent n − 1
  faits de `cepheus/same`, jamais les n² faits de l'égalité axiomatisée, et chaque fait est déplacé O(log n) fois sur
  toute suite de fusions (l'union par taille : la plus petite classe rejoint la plus grande). Les égalités sont
  appliquées fait par fait, donc une telle propriété coûte O(n) instances de règles, pas les n² paires qu'un tour
  énumérerait. Chaque fait qu'une fusion écrit ou déplace compte dans le budget, donc une tempête qui le dépasse est
  refusée en entier. *Testé par* `test/owl.ml` ("an equality storm" : 3 000 choses en une classe, 2 999 faits,
  0,05 s ; au-delà d'un budget de 100 faits, refusée, rien d'appliqué).
- **Une égalité ne peut pas atteindre ce qu'elle ne doit pas.** Deux valeurs, une chose qui est une propriété, ou une
  chose que nomment les règles (owl:Thing, une classe que nomme une règle dépliée) ne sont jamais rendues égales : le
  groupe est refusé, en nommant la règle. `cepheus/same` est lu comme un fait dérivé : un token qui a des droits par
  kind le lit, ainsi que toute propriété d'un ensemble de règles avec égalité (dont une fusion peut réécrire les
  faits), seulement s'il lit chaque kind d'où viennent les égalités ; le `Get` du serveur ne lit une chose comme sa
  classe que pour un token qui lit `cepheus/same` (un autre reçoit les propres faits de la chose, et n'apprend aucune
  égalité). *Testé par* `test/owl.ml` (eq-rep-p, prp-fp sur des valeurs), `test/server_unit.ml` ("equality and
  kinds") et `test/cesia-live.ce` (OWL 2 RL par TLS, un token d'un seul kind : `Same` et les questions refusés, `Get`
  rien).
- **Les templates sont bornés.** Une liste se déplie en une règle d'au plus 64 copies de ses patterns (un template est
  une règle dont un pattern se répète pour chaque membre d'une liste ; un groupe qui fait une liste plus longue est
  refusé, en nommant la règle) ; écrire une liste est un changement des règles, sous le budget d'un changement ; aucune
  règle ne peut donner une liste, donc une liste ne change que par des écritures, que le writer voit. Rien de nouveau
  n'est décodé : un template est le texte canonique d'une règle (`*p` pour sa liste), lu par le parser des règles, qui
  refuse tout texte qui ne se réimprime pas à l'identique ; les faits de `cepheus/same` sont des faits dérivés
  ordinaires de la frame.

## G21 Les questions vivantes

*Promesse.* Le premier message d'un watch (une question vivante : sa réponse, puis ses changements) est la réponse de `Find`
à un groupe durable ; après chaque message suivant (un changement, ou à nouveau la réponse), les lignes que tient le
programme, le changement appliqué, sont exactement la réponse de `Find` au groupe de ce message, un groupe durable
(G1 : aucun crash ne peut le reprendre). Les groupes des messages d'un watch ne font que croître, et chaque groupe qui a
changé les lignes entre deux messages est dans le changement du second : aucun changement n'est perdu, aucun ne vient
deux fois, quoi qu'il casse entre-temps (la connexion, le serveur par `kill -9`, la lecture du programme). Un watch
d'une question avec `Not`, `Or`, `In` ou `Prefix` tient la promesse par ses clés : un binding dont une frame change
l'appartenance à la réponse s'accorde avec l'un des faits de la frame à un pattern de la question (un binding qui ne
s'accorde avec aucun ne lit aucun fait changé), donc les bindings qui ont les valeurs que donnent ces faits (ou, pour
un pattern dont les variables sont toutes propres à un `Not` ou à une alternative, les valeurs qu'atteignent ses autres
éléments, avant et après la frame) sont répondus de nouveau avant et après, et le changement est leur différence ;
`test/questions.ml` vérifie ses lignes par l'oracle après chaque frame, et celles d'un token restreint par l'oracle sur
les faits qu'il a le droit de lire.

*Conditions.* La question est une conjunctive query (les patterns et les intervalles de `Find`), avec `Give` ou des
agrégats. Un programme qui lit plus lentement que n'arrivent les changements reçoit à nouveau la réponse plutôt que
chaque changement (il tient alors les lignes de `Find` au groupe de la réponse). Un watch se termine pour de bon à
`Close`, à une base fermée ou à un token qui n'a plus le droit de la lire (G16).

*Preuve.* (1) *Le changement d'une frame.* Soit $S$ les faits avant une frame et $S'$ après ; un binding des patterns
sur $S'$ qui n'en est pas un sur $S$ utilise un fait de $S' - S$ dans un pattern au moins. Prendre pour chacun de ces
bindings le premier pattern qui correspond à un fait ajouté, les patterns d'avant lui sur $S'$ sans les faits ajoutés
de la frame et ceux d'après lui sur $S'$, donne chaque nouveau binding exactement une fois (les parties sont disjointes
et les couvrent) ; les bindings retirés s'obtiennent de même sur $S$ avec les faits retirés (la delta query, la
requête du changement, de [Ammar 2018] ; la règle de la semi-naive evaluation, G17 (1)). Les lignes sont celles de `Find` avec leurs
répétitions, donc le multiset des lignes après la frame (un ensemble où un élément peut revenir plusieurs fois) est
celui d'avant, plus les lignes des nouveaux bindings, moins celles des bindings retirés ; `Sum` et `Count` suivent par
différence, et un `Min` ou un `Max` dont la valeur est partie est redemandé pour sa clé. (2) *Durable.* Un changement
est retenu jusqu'à ce que le groupe de sa frame soit durable (le syncer du serveur, l'événement `durable` d'un
lecteur), si bien que son groupe est un de ceux que garde G1. (3) *Ordre et reprise.* Les messages partent dans l'ordre
des groupes sur une seule queue ; après une connexion coupée ou une fin `lagging` (« en retard »), le package relance
le watch `from` le groupe de son dernier message, et le serveur ne répond `same` que quand son ring des changements
récents (un anneau qui garde les derniers changements) couvre chaque groupe depuis et qu'aucun ne touche les patterns
de la question (une propriété et ses constantes), sinon par la réponse à son groupe le plus récent, que le package
transforme en changement à partir de ses lignes : `spec/Watch.tla` vérifie que les lignes sont toujours la réponse à
leur groupe et ne reviennent jamais en arrière, avec le lagging, les connexions coupées, et un watch arrêté puis
relancé (1 015 657 états) ; sans le test des patterns touchés, ou sans la borne du ring, TLC trouve un contre-exemple
(`tools/tlc.sh` vérifie les deux).

*Testé par* `test/live_sim.ml` (100 seeds dans `tools/test.sh`, `LIVE_SEEDS` pour plus : des groupes au hasard
d'ajouts, de retraits, de faits dérivés et de merges en runs, des grands groupes ; chaque message de chaque watch,
simple, qui projette ou qui agrège, égal à la réponse de l'évaluateur naïf à son groupe ; la reprise par `same` ou par
la réponse, le lagging) ; `test/server_sim.ml` (des watches sur le réseau simulé : des pushes coupés à n'importe quel
octet, des connexions coupées à n'importe quel message et des watches repris, le hub en retard ou tout de suite, le
lagging, unwatch avec des pushes en route, des grands groupes, les crashes du serveur : les lignes de chaque message
sont la réponse naïve à un groupe durable, jamais plus ancienne que la dernière) ; `test/server_limits.ml` (un watch
qui ne lit jamais à côté d'un qui lit : le lecteur reçoit chaque changement dans l'ordre, le silencieux se termine par
`lagging`) ; les tests du package sur des forks (`cesia/tests/cepheus.test.ce`) ; `test/cesia.sh` (un watch par TLS,
un local, et un qui continue à travers un `kill -9` du serveur pendant que 1 500 lignes s'écrivent : ses groupes ne
font que croître et il finit avec les 1 500).

## G22 Les fichiers sont durables avant leurs faits

*Énoncé.* Un fait qui cite la racine d'un fichier nomme un arbre de nœuds et de chunks qui sont tous sur le disque :
chacun de ses chunks et de ses nœuds se relit après tout crash et toute recovery.

*Preuve.* `Vault.finish` force le pack (un fichier du vault où ses records, les entrées qu'il écrit, s'ajoutent les uns
après les autres) qui contient les records du fichier, et le répertoire d'un nouveau pack, avant de renvoyer la racine
(par son propre fsync, ou par un fsync partagé avec d'autres puts, les opérations qui mettent un fichier dans le vault,
commencés après que ses records ont été ajoutés : le group commit, plusieurs écritures confirmées par un seul fsync) ;
un pack fermé plus tôt a été forcé avant que son index soit écrit. Les faits sont écrits après le retour de `finish`,
comme tout groupe (G1). La recovery ne coupe rien : un pack qui a son index est pris tel que le dit l'index (écrit
après que le pack a été forcé) ; un pack sans index est lu en entier, chaque record vérifié par ses CRC, forcé (après
un `kill -9`, ses records peuvent n'être que dans le page cache, et un nouveau fichier peut les trouver déjà stockés),
et fermé tel qu'il est, jamais réécrit. Un record qu'un crash a laissé torn n'a jamais été forcé, donc aucun fait ne le
cite. Un chunk trouvé déjà stocké est relu et vérifié avant qu'un nouveau fichier le cite, donc un chunk endommagé est
écrit de nouveau plutôt que cité.

*Testé par* `test/vault_unit.ml` (120 seeds de coupures de courant à des appels pris au hasard pendant des puts sur le
disque simulé, trois par seed : chaque fichier terminé avant un crash se relit exact ; quatre threads qui mettent des
fichiers en même temps, coupés par une coupure de courant à un moment au hasard, 40 seeds ; un kill au milieu d'un put,
le fichier remis, puis une coupure de courant, 30 seeds) et `test/vault_crash.ml` (20 `kill -9` d'un processus qui met
des fichiers et écrit leurs faits : chaque fichier cité se relit exact, chaque fichier confirmé est là).

## G23 Aucun octet faux n'est servi

*Énoncé.* Un octet que donne le vault est un octet du fichier qui a été mis, à sa place ; sinon la lecture est une
erreur (`damaged`, `missing` ou `erased`).

*Preuve.* Un record n'est utilisé que si le CRC de son en-tête passe la vérification, s'il porte le nom demandé (le nom
de son en-tête, que le tag authentifie), et si son tag AEGIS-256 (le code d'authentification que le chiffrement
calcule avec la clé) passe la vérification sur ses octets scellés (chiffrés et authentifiés) et les champs de son
en-tête : un changement passe avec une probabilité de 2^-256, et un record déplacé sur un autre porte un autre nom. Le
CRC-32C des octets bruts, scellé avec eux, est vérifié après le codec (la décompression). Les tailles d'un nœud sont
vérifiées contre celles de son parent, la longueur d'un chunk contre celle de son nœud.

*Testé par* `test/vault_unit.ml` : des octets changés dans des packs, un record déplacé sur un autre, 20 000 records
changés au hasard (des octets, des coupures, des champs avec leurs CRC recalculés), chaque lecture donnant les bons
octets ou une erreur.

## G24 L'effacement

*Énoncé.* Après le retour de `Erase(owner)`, aucune lecture du vault ne donne un octet d'un fichier scellé avec la clé
du propriétaire, ni aucune lecture d'une copie des records du vault qui a pris ses clés depuis ; aucun nouveau fichier
ne nomme ce propriétaire.

*Preuve.* La clé du propriétaire n'existait que dans le fichier des clés, scellée par la clé maîtresse ; `Erase`
réécrit ce fichier sans elle (à côté, forcé, renommé par-dessus l'ancien, le répertoire forcé), avec une marque qui dit
que le domaine est effacé (le domaine : les fichiers scellés avec cette clé), avant de revenir. Un record du
propriétaire a alors besoin d'une clé qu'aucun fichier ne contient. Une copie qui prend les clés prend la marque et
laisse tomber la clé. Non couvert : une copie du fichier des clés faite avant l'effacement (une sauvegarde) contient
toujours la clé ; les blocs de l'ancien fichier peuvent rester sur un disque flash jusqu'à leur réutilisation
([le vault](vault.md#effacer-un-propriétaire)).

*Testé par* `test/vault_unit.ml` (les fichiers d'un domaine effacé `erased`, après une réouverture aussi ; sa clé
scellée absente du fichier des clés ; effacé sur une copie qui a pris les clés) et `server_unit` (Erase à travers le
serveur, les droits, et un put refusé après lui).
