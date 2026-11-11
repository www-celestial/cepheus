# Garanties

Chaque garantie énonce ce qui est promis, sous quelles pannes, ses conditions exactes, pourquoi elle tient (une esquisse
de preuve) et le test qui la vérifie. Les tests sont dans `test/` ; `tools/test.sh` les lance tous. Les mots sont
expliqués dans [concepts](concepts.md), [architecture](architecture.md) et le [glossaire](glossary.md) ; les
mathématiques sont dans [théorie](theory.md). Tout ce qui suit vaut pour cette version : une seule machine, des runs sur
le disque en niveaux (leveling, ratio 4), pas de réplication ; les règles comme [règles](rules.md) le dit.
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
| G7 | une ouverture depuis les runs sur le disque est égale à un rejeu du journal ; une page abîmée n'est jamais servie | F1 à F3 |
| G8 | un fork ne change rien de sa base | toujours |
| G9 | un seul moteur à la fois ouvre une base, quel que soit le chemin qui la nomme | toujours (le lock est consultatif) |
| G10 | après une écriture ou un fsync qui a échoué, plus rien n'est confirmé | F4 (un cas résiduel) |
| G11 | une question renvoie exactement ses réponses, chacune une fois, dans la borne de Generic Join | toujours |
| G12 | un crash pendant un merge laisse les runs d'avant ou les runs d'après, entiers | F1, F2, F4 |
| G13 | après un fsync qui a échoué, aucune vue ne montre un groupe qu'une coupure de courant pourrait reprendre ; une écriture qui a reçu `Io` est absente (un cas résiduel) | F4 avec F1, F2 |
| G14 | à travers le serveur, une écriture envoyée avec sa session et son numéro de série est appliquée au plus une fois ; renvoyée jusqu'à avoir une réponse, exactement une fois, chaque réponse nommant le même groupe | F1, F2, connexions coupées |
| G15 | chaque lecture, dans un lecteur local ou au serveur, contient chaque groupe répondu et chaque état lu avant son début, et est l'état exact après un groupe durable : les lectures sont linéarisables | F1, lecteurs lents, en pause ou tués, flux coupés |
| G16 | à travers le serveur, une connexion fait exactement ce que permettent les droits de son token | toujours |
| G17 | chaque vue contient exactement le plus petit modèle de ses faits affirmés sous ses règles, et marque exactement ceux qui sont affirmés | toujours (avec G1-G3 sous F1, F2) |
| G18 | aucun groupe confirmé ne laisse une instance d'une contrainte (`Never`) | toujours |
| G19 | un changement de règle prend effet à un seul groupe | toujours |
| G20 | `why` renvoie une preuve bien fondée d'un fait de la vue, ou rien pour un non-fait | toujours |

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

*Testé par* `test/sim.ml` (à chaque recovery : "lost acknowledged groups"), `test/exhaustive.ml` (chaque état de crash
de petits journaux), `test/crash.ml` (de vrais `kill -9`, le contenu de chaque confirmation vérifié).

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
("a segment is missing" sinon), et coupe tout ce qui suit la première frame qui ne passe pas la vérification. Le rejeu
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
les changements de ses groupes par-dessus l'état à son lo, quels que soient les runs qui font cet état) ; le rejeu
commence à la position du run le plus récent et saute les groupes qu'il contient. Le chargement vérifie le CRC de
l'en-tête, le CRC de la table des pages et le fait qu'elle place chaque page du fichier au plus une fois, l'ordre des
sections, les rank tables (les tables de rangs : le compte de chaque mot découle des bits qui le précèdent, le dernier
est égal au nombre de choses) et l'ordre et les bornes de chaque table de positions et de chaque répertoire, ceux des
colonnes compris (chaque colonne dans ses sections, les comptes de sa rank table, ses positions de lignes chacune plus
grande que la précédente jusqu'à ses lignes, ses blocs dans l'ordre : `Snapshot.check_and_build`). Un run qui tient
dans le cache est lu et vérifié en entier, par jusqu'à 4 domains pour un run de 512 pages ou plus, chacun avec son
propre descripteur, avant d'être pris. Chaque page passe par `Pages.fill`, qui lit la page du fichier que nomme la
table des pages et vérifie le CRC-32C que donne la table avant que la page entre dans la frame table (la table des
emplacements de pages du cache) : aucun autre chemin n'y met une page. Chaque accès à un run vérifie ses bornes (la
frame table, puis les octets de la page ou la copie d'un bloc), donc une lecture ne sort jamais des octets du run. Le
codage des formats 7 et 8 (des blocs par frame of reference, une table des pages, l'ordre par colonne) change ce que
contient une page, pas cet argument : une valeur n'est décodée que depuis une page qui a passé la vérification. Pour un
dommage aléatoire d'une page, CRC-32C le manque avec une probabilité $2^{-32}$ ; il détecte toute rafale d'au plus
32 bits (Castagnoli, Bräuer, Herrmann 1993).

*Plusieurs runs lus comme un seul état.* Un fait est dans une vue si et seulement si l'entrée la plus récente qui le
concerne (celle du delta, ou celle du run le plus récent qui en a une) l'ajoute ; un compte est la somme des lignes de
chaque run moins ses retraits, plus le compte net du delta (les runs sont nets, donc rien n'est compté deux fois) ; une
itération ne montre une ligne d'un run que si aucun run plus récent n'a d'entrée pour le même fait
(docs/book/theory.md, section 9). *Testé par* `test/unit.ml` ("several runs" : 120 vues aléatoires de jusqu'à 4 runs qui
ajoutent et retirent, comparées à leur merge complet et à un évaluateur naïf ; "large groups").

*Testé par* la simulation (des merges à des moments aléatoires, des crashs pendant leur écriture, des inversions de bits
dans les fichiers de runs) et `test/unit.ml` (aller-retour ; un run d'une autre base est refusé ; un run aux bits
inversés est mis de côté ; un run trois fois plus grand que le cache, lu par trois domains, avec un bit inversé après
l'ouverture : les questions répondent juste ou renvoient `Damaged`, et c'est exactement la page abîmée qui échoue).

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
processus verrouiller deux fois un fichier : à l'intérieur d'un processus, une table des locks tenus refuse une seconde
ouverture. Elle est indexée par l'identité du fichier de lock, ses numéros de device et d'inode (`st_dev`, `st_ino`),
que partagent tous les chemins vers le fichier, plutôt que par le chemin tel qu'il est écrit ou par sa forme canonique
(`realpath` résout les liens symboliques, mais un bind mount donne encore un second nom). Le fait que le lock soit tenu
est décidé par un `stat` du chemin, avant qu'aucun descripteur soit ouvert : fermer un second descripteur d'un fichier
que le processus a verrouillé libérerait le lock. Un second `close` d'une base ne fait rien : il ne libère pas de
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
20 000, une chose avec 40 000 valeurs).

*Testé par* `test/unit.ml` : 300 bases aléatoires et 15 questions aléatoires pour chacune (jusqu'à 3 patterns, des
constantes, des liens, des intervalles) comparées à un évaluateur naïf sur tous les faits, sur une base avec un delta
et sur une base compactée.

## G12 Les merges sont atomiques

*Promesse.* Après un crash à n'importe quel point d'un merge (F1, F2, F4), la base s'ouvre sur les runs d'avant ou sur
les runs d'après, chacun entier, jamais un mélange ; son état est le rejeu du journal jusqu'au groupe rétabli (G7) ;
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
affirmés sous les règles définies à son groupe : un fait est dans la vue si et seulement s'il est affirmé ou s'il a une
preuve (un arbre fini d'instances de règles dont les feuilles sont des faits affirmés). Et un fait est marqué affirmé
dans la vue si et seulement s'il est affirmé.

*Conditions.* Les règles telles que cette version les a : du Datalog sans négation, sans agrégats et sans nouvelles
choses dans les têtes, chaque règle range-restricted (chaque variable de la tête apparaît dans le corps) et typée
(vérifié quand elle est écrite). Un groupe refusé (par son budget, une contrainte, une règle du schéma) ne laisse rien.

*Preuve.* (1) *Insertion.* L'évaluation semi-naive à partir des ajouts affirmés du groupe atteint le plus petit point
fixe des règles sur l'état après les retraits : chaque instance de règle avec un fait du tour r est énumérée au tour r
(les atomes avant celui qui correspond, sur les tours en dessous de r, ceux d'après sur les tours jusqu'à r), donc
chaque instance qui met en jeu un nouveau fait est trouvée, chacune une fois ([Bancilhon 1986], [Ramakrishnan 1990]) ;
les instances sur des faits plus anciens seulement ont été trouvées par les groupes d'avant (récurrence sur les
groupes). (2) *Retrait.* Backward/Forward retire exactement les faits restés sans preuve ([Motik 2015]), sous trois
conditions que cette implémentation respecte et que les tests vérifient : les instances perdues d'un fait supprimé sont
énumérées sur l'état d'avant son départ ; les faits retirés du groupe quittent tout de suite l'ensemble des faits
affirmés, et l'état seulement quand leur preuve est réfutée ; un fait retiré puis affirmé de nouveau est affirmé.
(3) *Changements de règles.* Une règle ajoutée est évaluée sur tout l'état (ses instances sur des faits plus anciens),
puis avec les autres par l'évaluation semi-naive ; une règle supprimée donne ses têtes à B/F comme candidats.
(4) *Durabilité.* Les changements dérivés sont dans la frame même du groupe, écrits et forcés avec elle (G1, G2) ; le
rejeu les applique selon leur sorte et n'évalue rien, donc une vue rétablie, celle d'une réplique ou celle du passé est
celle du writer, octet pour octet de faits. (5) *Runs.* Un merge garde l'indicateur de chaque fait : pour chaque fait,
l'entrée la plus récente donne son état dans la nouvelle vue et la plus ancienne son état en dessous des runs
fusionnés ; un indicateur changé est un retrait et un ajout dans le nouveau run.

*Testé par* `test/reasoning.ml` (après chaque groupe de suites aléatoires de 60 groupes, 60 seeds simples et 60 avec les
faits fusionnés en runs entre les groupes dans `tools/test.sh`, `RULES_SEEDS` pour plus : des règles aléatoires sûres et
typées définies, changées et supprimées, des ajouts et des retraits aléatoires de faits affirmés, dérivés et les deux,
la vue égale au plus petit modèle de ses faits affirmés recalculé de zéro par évaluation naïve avec l'évaluateur propre
au vérificateur, `Check.least`, et ses faits affirmés égaux à ceux du modèle) ; la simulation (trois règles à partir
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
atome du corps mis en correspondance avec lui, les autres sur l'état final) ; une contrainte ajoutée tourne sur tout
l'état. Un groupe qui trouve une instance lève une exception avant que sa frame soit faite.

*Testé par* `test/reasoning.ml` (des contraintes aléatoires parmi les règles aléatoires : un groupe est refusé
exactement quand le plus petit modèle d'après lui a une instance de l'une d'elles, vérifié de zéro ; le cas nommé : le
groupe refusé ne change rien).

## G19 Un changement de règle prend effet à un seul groupe

*Promesse.* Définir, changer ou supprimer des règles prend effet au groupe qui l'écrit : chaque vue d'avant contient le
plus petit modèle sous les anciennes règles, chaque vue à partir de ce groupe le plus petit modèle sous les nouvelles.

*Conditions.* Cette version raisonne en ligne, dans le groupe qui change les règles, sous le budget ; le chemin en
arrière-plan que prévoit la conception pour les très grands changements vient plus tard et garde la même promesse.

*Preuve.* Les faits de la règle et les changements dérivés qu'ils causent forment un seul groupe : G2 les rend tous
visibles d'un coup, ou aucun.

*Testé par* `test/reasoning.ml` (des règles définies, changées et supprimées au hasard parmi les écritures ; G17 vérifié
sur la vue de chaque groupe).

## G20 `why` renvoie une preuve

*Promesse.* `why v e p x` sur un fait de v renvoie une preuve bien fondée : ses feuilles sont des faits affirmés de v,
ses nœuds des instances de règles définies à v dont les faits du corps sont ses enfants, chaque enfant prouvé avant son
parent ; sur un triplet qui n'est pas un fait de v, elle renvoie `None`.

*Preuve.* La preuve est construite par la vérification arrière de B/F sur v, sans rien supprimer : un fait est prouvé
quand il est affirmé, ou quand une instance dont les faits du corps sont tous prouvés l'a pour tête ; l'instance qui a
prouvé chaque fait est gardée à ce moment-là, donc les enfants de chaque nœud ont été prouvés avant lui, et l'arbre n'a
pas de cycle. Par G17, chaque fait dérivé de v a une preuve, que la vérification trouve : elle explore chaque instance
de chaque règle qui donne le fait, jusqu'à ce que l'une soit prouvée.

*Testé par* `test/reasoning.ml` (un groupe sur cinq de chaque suite aléatoire : la preuve de chaque fait dérivé
vérifiée nœud par nœud — la règle de chaque nœud existe, les atomes de son corps se lient de façon cohérente aux faits
des enfants dans l'ordre, sa tête est le fait du nœud, ses intervalles tiennent, chaque feuille est affirmée dans la
vue — et le cas nommé d'une preuve en deux étapes).
