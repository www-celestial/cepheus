# Théorie

Les mathématiques derrière chaque partie de Cepheus, et la recherche sur laquelle elles s'appuient. Une citation entre
crochets, [O'Neil 1996], est une entrée des [références](references.md), avec son lien et ce que Cepheus en a pris. Le
récit en mots simples des mêmes parties est dans [architecture](architecture.md).

## 1. Le journal et la recovery

**Modèle.** Le journal est une suite de frames $f_1, f_2, \dots$ (une frame : un bloc du journal écrit d'un seul tenant, qui
porte des groupes et se vérifie par ses CRC) ajoutées à la fin de fichiers de segment (les fichiers successifs du
journal). Chaque frame contient des groupes de numéros consécutifs. Soit $D$ le préfixe durable du fichier (les octets
couverts par un `fsync` terminé ; fsync est l'appel système qui attend que les octets écrits soient vraiment sur le
disque). Un crash (F1, F2) remplace le fichier par $D$ suivi de quelques octets $R$ venus des écritures pas encore
synchronisées (n'importe quel sous-ensemble de leurs secteurs, peut-être torn, c'est-à-dire écrits en partie
seulement). La recovery (la relecture du journal à l'ouverture, qui rebâtit l'état après un crash) lit les frames depuis
le début et s'arrête au premier indice $j$ où les octets ne forment pas une frame valide.

**Invariant I1** (discipline d'ajout) : une frame n'est écrite qu'après le retour du `fsync` de la frame précédente ;
ainsi, à tout instant, au plus une frame est en partie non synchronisée, et toutes les frames avant elle sont dans $D$.

**Invariant I2** (acquittement) : un groupe n'est confirmé qu'après le retour du `fsync` de sa frame ; un groupe
confirmé est donc dans $D$.

**Théorème (G1-G3).** Sous F1 et F2, la recovery rend les groupes $1, \dots, k$ avec $k \ge$ tout groupe confirmé,
chacun intact.
*Preuve.* Par I1 et I2, les frames des groupes confirmés sont dans $D$ ; le crash ne change pas $D$ ; chacune de ces
frames se vérifie (CRC de l'en-tête et du corps ; un CRC est un checksum, un nombre calculé sur les octets qui
change dès qu'un octet change), donc la lecture les passe. La lecture s'arrête à la première frame qui ne se vérifie
pas, qui se trouve après les frames confirmées de $D$, et tout ce qui la suit est coupé ; les frames sont dans l'ordre
des groupes, donc le résultat est un préfixe. ∎

**Dommage ou torn write.** À la première frame mauvaise, à l'offset $p$ (la position en octets dans le fichier), la
recovery doit trancher : soit des octets ont été torn (jamais confirmés : on coupe), soit des octets durables ont été
endommagés (F3 : on refuse). Deux signes prouvent que la frame a été écrite en entier, et qu'elle a donc eu un jour la
forme d'une frame durable : un en-tête de frame qui se vérifie après $p$ (I1 : une frame après $p$ a été écrite après
que celle de $p$ a été forcée sur le disque), ou un
trailer (la fin de la frame, qui répète sa longueur et le CRC de son corps) à l'offset $t$ dont le champ de longueur
vaut $t - p - 28$ et dont le CRC du corps correspond aux octets entre les deux. Un torn write (une écriture interrompue
dont seule une partie des secteurs a atteint le disque) ne laisse ni l'un ni l'autre, sauf s'il a perdu exactement le
secteur de l'en-tête et gardé tous les secteurs suivants de la frame (possible seulement sur un appareil qui réordonne
les écritures de secteurs) ; la recovery refuse alors d'ouvrir : une fausse alarme, jamais une perte. Le test
exhaustif énumère tous les états de crash de petits journaux et ne trouve aucune fausse alarme en pratique, parce que
l'en-tête partage son secteur avec le début du corps.

**Un fsync qui échoue (F4).** I1 repose sur une prémisse que Linux ne tient pas : que des octets non couverts par un
`fsync` terminé ne soient au moins pas pris pour des octets durables. Après un `fsync` qui échoue, ext4 et XFS marquent
les pages clean (identiques au disque, plus rien à écrire) tout en gardant leurs nouveaux octets en mémoire ; un `fsync`
suivant renvoie un succès sans les écrire, et toutes les lectures jusqu'à un redémarrage les voient ([Rebello 2020],
section 3.3). Le processus suivant, qui lit le page cache (la copie des fichiers que le noyau garde en mémoire),
verrait donc une frame hors de $D$ qui a l'air entière. Deux règles font de $D$ la vérité. (W) Après un `fsync` qui
échoue, le writer (le seul thread qui applique les groupes d'une base, un à la fois) s'arrête et tronque le fichier à
la fin de sa dernière frame durable, puis le force (`Journal.cut`) : la frame quitte à la fois le page cache et le
disque. (R) Une recovery après autre chose qu'une fermeture propre écrit à nouveau sa frame la plus récente avant de la
forcer (`Journal.rewrite_newest`) : ces pages redeviennent dirty (modifiées en mémoire et pas encore écrites sur le
disque), donc un `fsync` réussi les écrit et la frame entre dans $D$ ; s'il échoue, l'ouverture échoue. Par I1 et
l'arrêt au premier échec, la frame la plus récente est la seule qui peut se trouver hors de $D$ ; (R) seule suffit donc
pour la sûreté (aucune vue hors de $D$, G13) ; (W) rend certaine l'absence d'une écriture qui a échoué et épargne à une
coupure de courant ultérieure la fausse alarme ci-dessus. Le modèle `spec/Journal.tla` (écrit en TLA+, un langage pour
décrire un système et ses états) sépare le page cache du disque et vérifie les deux règles : sans (R), TLC (le model
checker de TLA+, qui parcourt tous les états du modèle) trouve la trace écriture, `fsync` qui échoue, mort du processus
avant (W), recovery qui publie la frame.

**Pouvoir de détection** ([Koopman 2002], [Castagnoli 1993]). CRC-32C a une distance de Hamming de 4 (le nombre minimal
de bits qu'il faut changer pour qu'une erreur passe inaperçue) pour les messages jusqu'à environ $2^{31}$ bits, et de 6
jusqu'à 5 243 bits : toute erreur d'au plus 3 bits dans une frame (5 bits dans une frame d'au plus 655 octets) est
détectée, toute erreur en rafale (burst : des bits faux qui se suivent) d'au plus 32 bits est détectée, et les autres
erreurs aléatoires échappent avec une probabilité $2^{-32}$.

## 2. Group commit

Le group commit consiste à confirmer plusieurs groupes par un seul fsync. Avec un seul writer et un `fsync` de durée
$f$, un système fermé (closed loop : chaque client attend sa réponse avant d'envoyer la suite) de $N$ clients qui
écrivent chacun un groupe à la fois atteint un régime stable où chaque frame contient les groupes arrivés pendant le
`fsync` précédent. Par la loi de Little
($L = \lambda W$ [Little 1961]), avec $N$ clients dans le système et un temps de réponse $W$, le débit est $\lambda = N / W$. Si chaque groupe
attend au plus la fin du `fsync` en cours puis le sien, $f/2 \le W - f \le f$ en moyenne, donc
$\lambda \approx N / (1{,}5 f)$ jusqu'à la limite CPU $C$ du writer (les groupes par seconde que le writer peut résoudre) : $\lambda \approx \min(N / (1{,}5 f), C)$.
Sur la machine de test, $f \approx 3$ ms (environ 340 fsync/s) et $C \approx 146\,000$ groupes/s pour des groupes de 5 faits (mesuré) : 8
clients donnent au plus ~1 800 groupes/s, 256 clients ~57 000 ; les chiffres mesurés sont dans les
[benchmarks](benchmarks.md).
Le writer résout la frame suivante pendant que le syncer (le thread qui fait les fsyncs du journal) force la
précédente (deux étages), et les groupes qui arrivent pendant un `fsync` sont fusionnés dans la frame en attente : une
frame contient donc tout ce qui est arrivé entre-temps ([DeWitt 1984], [Helland 1987]).

## 3. Index

Une vue est une pile de runs $R_1$ (le plus récent) .. $R_k$ (des colonnes triées dans des pages, section 9 ; un run
est une copie triée de l'état, dans un fichier) plus un delta $\Delta$ (les changements récents, en mémoire, dans des
persistent maps : des tables associatives dont les anciennes versions restent valides après un changement).
Chaque run a deux parties : les faits qu'il ajoute (a) et les faits des runs en dessous de lui qu'il retire (t).
Chaque partie garde ses lignes dans trois ordres (format de run 8). Avec $n$ lignes dans une partie, $e$ numéros de
chose et $p$ propriétés :

| ordre | disposition | recherche |
|---|---|---|
| par chose | une rank table (un mot de 64 bits pour 32 numéros de chose : leurs bits de présence et le nombre de choses tenues avant eux), les slots en blocs de 128, un record par slot avec ses valeurs par propriété, triées | les faits d'une chose : un rank (un mot lu, un popcount), l'en-tête du bloc et le record, $O(1)$ par partie, $O(k)$ pour lire ; une propriété : $O(m)$ pour les $m$ propriétés du bloc ; un fait : $O(m + \log k)$ |
| par propriété | `poff[0..p]`, les lignes `(w, thing)` triées, en blocs de 128 ; un value index (des mots de rank sur les valeurs de p, la première ligne de chacune) pour la plupart des propriétés | les choses avec $(p, w)$, ou qui pointent vers $w$ par $p$ : $O(1)$ avec un value index, sinon $O(\log n_p)$, $+ O(\text{réponse})$ ; un intervalle de valeurs : pareil |
| column order | les lignes `(thing, w)` de chaque propriété à part, dans l'ordre des choses, en blocs de 128 ; une rank table sur ses choses (partagée par les propriétés que tiennent les mêmes choses) ; des offsets seulement à partir de sa première chose à plusieurs valeurs | une propriété d'une chose : un rank, $O(1)$, puis $O(1)$ pour une propriété à une seule valeur, $O(\log k)$ pour un fait parmi $k$ valeurs ; les valeurs de $p$ d'une chose comme une slice triée ; les choses de $p$ dans l'ordre, chacune une fois |

Une **rank table** (le rank directory de Jacobson [Jacobson 1989]) répond à « la chose $e$ est-elle dans cette partie,
et si oui à quel slot ? » avec un seul mot : le bit $e \bmod 32$ du mot $\lfloor e / 32 \rfloor$ dit si $e$ est présente, et son slot
(sa place dans la partie) est le compte rangé dans le mot plus les bits à 1 sous le bit $e$ (ce compte de bits à 1 est
le popcount, une seule instruction du processeur ; lire ainsi la place d'une chose s'appelle un rank). Elle coûte un
quart d'octet par numéro de chose, là où une table dense d'offsets (une entrée par numéro de chose, présente ou non :
la base à un seul niveau, d'avant les niveaux) en coûtait 8 ; une partie qui tient toutes les choses depuis un numéro
jusqu'à sa fin (un chargement, un merge complet) n'y lit aucun rank, son slot étant une addition. Ainsi, pour
localiser les faits d'une chose dans un run, il faut un rank, l'en-tête d'un bloc et son record (le record d'une chose :
ses valeurs par propriété) : environ 0,4 µs à 10 M de faits sur un seul run
([benchmarks](benchmarks.md#runs-et-journal-compressés-2026-11-09-à-10-millions-de-faits)). Hexastore
[Weiss 2008] et RDF-3X [Neumann 2008] gardent six ordres des triplets ; Cepheus en garde deux, parce qu'un numéro dense
rend « par chose » direct, et que « par propriété puis valeur » sert « toutes les choses qui ont cette propriété »,
« les choses qui pointent vers t par p » (les lignes de la valeur t) et les intervalles de valeurs ; le format 8 ajoute
le **column order** (les lignes de chaque propriété rangées à part, ce qu'on appelle vertical partitioning, Abadi et al.
[Abadi 2007]) : la recherche d'une propriété d'une chose ne lit que les octets de cette propriété (un mot de rank, une
entrée de répertoire, un champ : 20 à 40 ns sur des factures consécutives, contre 46 à 61 dans le bloc d'une chose), et
une question sur quelques propriétés ne lit que les leurs (les triangles lisent `follows` : 2,2 MB d'un run de 70 MB).
Il coûte 13,9 MB à 10 M de faits, 1,4 octet par fait. Taille d'une partie (format 7, section 11, avant le column
order) : chaque valeur en autant de bits qu'en demande son bloc de 128 à partir de sa plus petite valeur, un quart
d'octet par numéro de chose pour la rank table, 8 octets par bloc de 128 choses et 16 par bloc de 128 lignes, les value
indexes, et le dictionnaire (les octets de ses textes, leurs offsets en quelques bits chacun, une hash table de deux
slots de 4 octets par texte) : 5,4 octets par fait à 10 M de faits, contre 24,6 au format 6 (22 octets par ligne en
mots fixes, 8 octets par chose, 12 octets par texte).

Le delta est un ensemble de persistent maps (Driscoll et al. [Driscoll 1989], Okasaki [Okasaki 1998]) : chaque
changement copie un chemin, $O(\log d)$, et une ancienne version reste valide gratuitement. C'est ce qui rend les vues et les forks
gratuits (un fork : un état temporaire qui part d'une vue, où l'on écrit sans rien écrire sur le disque). Il est rangé
comme un run (par chose puis (propriété, valeur) ; par propriété puis valeur puis chose) : toute recherche est donc une
recherche dichotomique dans chaque run qui peut tenir la clé plus une recherche dans une map, jamais le parcours d'une
liste ; et il garde le nombre net de faits à côté de chaque map, pour que chaque compte que lit le query planner (la
partie qui choisit l'ordre d'évaluation d'une question) soit exact, runs et delta ensemble (section 9). Il coûte environ
170 octets par changement ; il est donc borné : quand il dépasse 200 000 changements (`Engine.compact_min`), un merge (la
fusion de runs triés en un seul) démarre **dans un autre domain** (un domain : un fil d'exécution d'OCaml qui tourne en
parallèle sur un autre cœur) : il déverse le delta et les runs les plus récents, fusionnés dans l'ordre, dans un nouveau
fichier de run ($O(n + d)$, section 8), puis rejoue les groupes écrits entre-temps (le writer les note), jusqu'à n'avoir
plus que moins de 256 groupes de retard ; le writer attend alors que le syncer soit inactif (au plus un fsync), rejoue
le reste et bascule ses vues sur les nouveaux runs. Les écritures n'attendent jamais la partie en $O(n)$. C'est un
LSM-tree [O'Neil 1996] (log-structured merge-tree : des fichiers triés, fusionnés de proche en proche) : le delta est le
composant en mémoire (C0, niveau 0), les runs sont les composants sur disque, en niveaux (section 9).

## 4. Generic Join

Une question est une requête conjonctive $Q$ sur des variables $x_1, \dots, x_m$ et des atomes $R_j$ (chaque pattern est une relation à deux
colonnes, la chose et la valeur, restreinte à une propriété et à ses constantes ; un pattern : un triplet d'une
question dont la chose et la valeur sont des constantes ou des variables).

**AGM bound** (la borne AGM ; Atserias, Grohe, Marx [Atserias 2008]). Pour toute fractional edge cover $u$ des
variables par les atomes (une couverture fractionnaire : un poids par atome, $\sum_{j \ni x} u_j \ge 1$ pour toute variable $x$), $|Q| \le \prod_j |R_j|^{u_j}$. Pour le triangle $R(a, b)$, $S(b, c)$, $T(c, a)$ avec
$N$ faits chacun, $u = (\frac{1}{2}, \frac{1}{2}, \frac{1}{2})$ donne $|Q| \le N^{3/2}$, et certaines instances l'atteignent. Tout plan de joins
deux à deux (un join : l'opération qui associe les lignes de deux entrées par leurs valeurs communes) peut construire
$\Theta(N^2)$ lignes intermédiaires sur certaines instances (Ngo et al. [Ngo 2012]).

**Algorithme** (Ngo, Ré, Rudra [Ngo 2013] ; Veldhuizen [Veldhuizen 2014] pour la forme par itérateurs). On fixe un ordre
des variables. Pour lier $x_i$ sachant $x_1, \dots, x_{i-1}$ : parmi les atomes qui contiennent $x_i$, on prend celui qui a le moins de
candidats pour $x_i$ sous les bindings courants (un binding : une valeur pour chaque variable déjà liée ; des comptes
exacts, lus dans les index), on les énumère, et on garde un candidat $c$ seulement si chaque autre atome sur $x_i$
l'accepte (une recherche dans un index chacun). On recommence au niveau suivant. Une variable avec un intervalle, du
côté valeur d'un atome dont la chose est libre, est énumérée à partir de l'index trié de cette propriété, sur
l'intervalle seulement. Avec des recherches en $O(\log n)$, le temps d'exécution est
$O(m \cdot |\text{atomes}| \cdot \text{AGM}(Q) \cdot \log n)$ (l'argument de [Ngo 2013], théorème 4.2 : les candidats de chaque niveau sont bornés par
le plus petit membre de l'intersection, et la somme sur les niveaux se télescope jusqu'à la borne). La borne demande
deux choses au moteur : les comptes doivent être exacts (une estimation sous la vérité fait passer un grand ensemble
pour un petit), et un atome qui n'est pas la source doit coûter une recherche, pas le parcours de ses propres
candidats. Une version du jalon 2 cassait la seconde : elle matérialisait et triait les candidats de chaque atome
lié pour les intersecter, et payait donc à chaque binding pour le plus grand ensemble (un statut partagé par 450 000
factures, trié une fois par client d'une ville : le benchmark à 10 M n'a jamais fini sa troisième question).
L'intersection triée (Leapfrog Triejoin [Veldhuizen 2014]) ne garde la borne qu'avec des itérateurs qui sautent
(seek) à l'intérieur des index, ou avec des ensembles de tailles comparables.

**Leapfrog (format de run 8).** Un pattern dont l'autre côté est connu à son niveau est une **slice** (une suite
contiguë de lignes) : les valeurs d'une propriété pour une chose (le column order) ou les choses d'une valeur (l'ordre
par propriété), contiguës et triées dans un run. Quand la source d'un niveau est une slice d'au moins 2 candidats,
chaque autre slice du niveau dont le compte vaut au plus 8 fois celui de la source est lue aussi, dans un buffer (une
zone de mémoire de travail ; triée à nouveau seulement si les runs ou le delta de la vue l'ont donnée dans le
désordre), et les buffers sont intersectés par **leapfrog** [Veldhuizen 2014] (saute-mouton) : les itérateurs dans
l'ordre de leurs clés, chacun à son tour saute jusqu'à la plus grande clé par galloping [Bentley 1976] (une recherche
à pas doublés, $O(\log d)$ pour $d$ places) ; une clé que tous atteignent est un candidat, vérifié contre les autres patterns du
niveau. Le niveau lit $m + \sum n_j \le (1 + 8 (k - 1))\, m$ lignes pour une source de $m$ et $k$ slices, et compare
$O(m \log(n/m))$ : à une constante près du travail de Generic Join, donc dans la borne AGM à cette constante et au
facteur log près. Le compte d'une slice et sa première ligne viennent d'un rank et d'un en-tête d'offsets, et sont
gardés pour le côté connu pour lequel ils ont été lus (le « qui suit $a$ » des triangles est lu une fois pour tous les $b$
que suit $a$). Sur les triangles, cela remplace cinq recherches d'appartenance par arête, chacune à une place au hasard
dans la colonne de `follows`, par deux lectures de quelques lignes contiguës : 1,16 s → 0,26 s sur un cœur
(benchmarks).

**Une seule valeur, et des vérifications laissées au niveau suivant.** Un pattern $(y, p, x)$ d'une propriété $p$ à une seule valeur,
avec $y$ lié, offre au plus un candidat à $x$ ; son compte n'est pas recherché (1 contre $2c$ pour un compte exact
$c$, voir G11). Quand c'est le premier pattern de ce genre à son niveau et que chaque autre pattern du niveau a un compte
fixe de 1 ou plus (un autre côté constant, ou lié seulement plus tard), `choose` le prendrait pour chaque binding : le
niveau lit cette unique valeur (`Store.value1`) et saute le comptage. Un pattern dont l'autre côté est la variable du
niveau suivant n'est pas vérifié à son propre niveau (une chose sans cette propriété) : au niveau suivant, il n'offre
aucun candidat à ce binding et en est alors la source ; les bindings, les réponses et les candidats comptés sont donc
les mêmes. Q4 lit le client d'une facture, la ville du client et le total de la facture comme trois valeurs seules :
247 → 127 ms sur un cœur.

**La borne testée.** `Check.gj_bound` additionne, sur les niveaux et les bindings partiels qui atteignent chacun, la
plus petite offre $m$ et, quand $m \ge 2$, la taille de chaque offre en slice d'au plus $8m$ (les lignes que le leapfrog
peut lire) ; chaque question aléatoire des tests et de la simulation énumère au plus cela (`Query.work` compte les
candidats d'une source et les lignes lues dans les buffers).

**Correction (G11).** *Validité :* un binding complet a passé chaque atome au niveau de sa dernière variable, avec
toutes les autres variables de l'atome liées ; chaque atome est donc un fait. *Complétude :* pour une réponse $a$, à
chaque niveau, $a_i$ satisfait l'atome source (il est donc énuméré) et chaque autre atome (il est donc gardé). *Pas de
doublons :* les candidats d'un niveau sont distincts (chaque index donne un ensemble : une partie d'un run tient chaque
fait une fois, une ligne d'un run plus ancien n'est montrée que si aucun run plus récent ni le delta n'a d'entrée pour
le même fait, et le delta n'ajoute que des faits absents en dessous de lui) ; des préfixes distincts donnent des
bindings distincts.

**Ordre.** Cepheus garde l'ordre des variables dont le travail estimé est le plus petit : les candidats qu'énumèrent
ses niveaux, soit, à chaque niveau, ses bindings partiels multipliés par les candidats par binding de la variable
suivante (le compte du meilleur pattern, étant donné les variables liées avant). Les bindings partiels d'un ensemble
de variables sont les mêmes quel que soit l'ordre qui les a liées ; ils sont donc estimés une fois par ensemble : le
plus petit produit des candidats par binding parmi les ordres de l'ensemble, puisque chacun de ces produits les borne
par au-dessus. Le meilleur ordre d'un ensemble est alors le meilleur ordre de l'ensemble privé d'une variable, suivi
de cette variable : une programmation dynamique sur les sous-ensembles, comme celle par laquelle Selinger et al.
[Selinger 1979] choisissent un ordre des joins, en $n 2^{n-1}$ étapes pour $n$ variables, et exacte pour ce coût.

Deux sortes de variables ont leur place choisie avant la programmation dynamique, et restent en dehors. Une variable
dont le seul pattern n'a pas d'autre variable et lui offre au plus un candidat (un champ d'une chose donnée par son
id) vient en premier : elle y coûte 1, le moins que puisse coûter une étape, et ne multiplie rien (exact). Une *leaf*
(une feuille), c'est-à-dire une variable $y$ dont le seul pattern la donne comme valeur d'une propriété à une seule
valeur d'une variable $x$, avec $d \ge 2$ valeurs en tout, vient juste après $x$ : là, elle a un candidat par binding,
ne multiplie rien, et coûte les bindings partiels $S$ de l'étape de $x$, le moins qu'elle puisse coûter après $x$ (les
bindings partiels ne diminuent jamais le long d'un ordre). La règle est exacte quand le compte de $x$ ne dépend pas de
$y$ (aucun autre pattern de $x$ ne lui offre plus que la moyenne de la leaf, $\lfloor N / d \rfloor$ pour $N$ faits de
la propriété) : avant $x$, $y$ coûterait au moins 1 et multiplierait par $d$ l'étape de $x$ et chaque étape entre les
deux, ce qui change le coût d'au plus $S + S - d S \le 0$ en faveur de l'après (un argument d'échange). Sinon, c'est
une heuristique, à un facteur 2 près de la lecture de la leaf en premier à cette étape : avant $x$, les deux étapes
coûtent environ $d + N$ par binding des étapes d'avant, après $x$ au plus $2 N$. Les mesures lui donnent raison : pour
la somme des totaux de 100 000 factures (`[i, Total, t]`), l'estimation préfère lire les totaux valeur par valeur
($d + N$) plutôt que facture par facture ($2 N$), et cette seconde lecture, celle que donne la règle, prend 16,2 ms
contre 53,6 ms (cinq runs sur le disque : les factures de chaque valeur coûtent une recherche dans chaque run). Ainsi
les champs d'une ligne (le numéro d'une facture, son statut, son total, ses dates) sont des leaves de la chose de la
ligne, et une page de 7 champs ne laisse à la programmation dynamique qu'une ou deux variables. La programmation
dynamique tourne sur les variables qui restent, jusqu'à 12 (24 576 étapes, chacune sur au plus une entrée par autre
variable : les comptes sont lus une fois par question, fusionnés par la variable de l'autre côté, quel que soit le
nombre de patterns) ; au-delà de 12, vient ensuite la variable qui a le moins de candidats (de façon gloutonne). Le
planner d'avant essayait chaque ordre jusqu'à 7 variables et devenait glouton à 8, ce qui, pour une page triée des 7
champs d'une facture (8 variables), commençait par le statut, à 3 valeurs, et lisait chaque facture dans chaque
fenêtre du chemin de l'index : 8,4 ms contre 0,17 ms maintenant (`probe`, 100 000 factures).
Freitag et al. [Freitag 2020], Mhedhbi et Salihoglu [Mhedhbi 2019] et Wang et al. [Wang 2023] montrent
que l'ordre et le mélange avec des joins ordinaires comptent le plus en pratique ; le coût mesuré de chaque question
est dans les [benchmarks](benchmarks.md).

## 5. Serializability et isolation

Soit une history $H$ (un historique) : la suite des groupes confirmés avec leurs lectures (`Expect`) et leurs
écritures. Le writer exécute les groupes un à la fois, chacun sur l'état laissé par le précédent, donc $H$ est serial
(en série, sans recouvrement ; Papadimitriou [Papadimitriou 1979]) ; elle est donc conflict-serializable, et, avec des
numéros attribués après la soumission, strictly serializable (le résultat est celui d'une exécution une par une, dans
l'ordre réel des confirmations ; linearizable comme un seul objet, Herlihy et Wing [Herlihy 1990]). Dans les termes
d'Adya [Adya 1999], aucun cycle G0, G1 ou G2 ne peut se former entre groupes. Une transaction cliente qui lit une vue
puis écrit est un groupe avec des préconditions : si elle déclare chaque fait qu'elle a lu comme un `Expect`, le writer
les valide sur l'état le plus récent (backward validation, Kung et Robinson [Kung 1981]), donc la transaction cliente
est serializable. Deux lectures ne sont pas validées. Un fait lu et pas déclaré : deux read-then-writes (lire, puis
écrire selon ce qu'on a lu) de la même valeur réussissent tous les deux, un lost update (une mise à jour perdue), que
snapshot isolation (chaque transaction lit l'état figé de son début) refuserait (first committer wins, [Berenson 1995]).
Une lecture par prédicat, l'ensemble des faits qui correspondent à un pattern : un `Expect` nomme un seul fait, donc un
fait ajouté entre-temps à l'ensemble (un phantom) n'est pas vu, sauf si chaque writer de l'ensemble attend et change un
fait qui le représente (un numéro de version : materializing the conflict, [Fekete 2005]). Dans ces limites, un
read-then-write est serializable ; au-delà, il est plus faible que snapshot isolation.
Le défaut de PostgreSQL est Read Committed ; son SERIALIZABLE est SSI (Cahill et al. [Cahill 2008], Ports et Grittner [Ports 2012]) ;
le « serializable » d'Oracle est snapshot isolation, qui admet le write skew (Fekete et al. [Fekete 2005]).

## 6. Forks

Un fork est une paire $(\text{vue}, \text{delta}')$ où $\text{delta}'$ commence égal au delta de la vue. Les écritures produisent de nouvelles
versions persistantes (path copying : on copie le chemin modifié, le reste est partagé), donc la vue d'origine reste
inchangée par construction ; un fork coûte $O(1)$ à créer et $O(\log d)$ par changement.
Le `with` de Datomic ([comparaison](comparison.md#datomic)) est la même idée sur une valeur de base de données ; HyPer [Kemper 2011] fait un fork
du processus pour des snapshots OLAP ; Rodeh [Rodeh 2008] fait du copy-on-write pour les B-trees.

## 7. Les pages et le cache

Les runs sont lus par pages de 16 KiB à travers un seul cache pour le processus (`Pages` : le cache propre de
Cepheus plutôt que mmap [Crotty 2022], comme le font LeanStore [Leis 2018], Umbra [Neumann 2020] et vmcache [Leis 2023]).

**Une lecture.** Chaque partie d'un run garde une table `hot` avec un slot par page : les octets de la page, ou une
constante « absente ». Lire 8 octets à l'offset o, c'est `hot.(o lsr 14)`, une comparaison, puis la lecture dans la
page : pas de lock, pas de hash table, depuis n'importe quel domain. Une page absente de `hot` prend le chemin lent :
si elle est en mémoire, une lecture est comptée pour la politique d'éviction et la page revient dans `hot` ; sinon, on
prend le lock du cache, on fait de la place, la page est lue depuis son fichier et vérifiée contre son CRC-32C avant
que quiconque puisse la voir (G7). Le chemin lent est un appel de fonction, et OCaml sauve chaque valeur vivante sur
la pile autour d'un appel même quand il n'est pas pris ; les recherches qui n'appellent rien d'autre (recherches
dichotomiques, comptes, appartenance) utilisent donc des lecteurs qui lèvent une exception sur une page qui n'est pas
hot, et reprennent depuis leur début une fois la page présente (elles ne changent rien avant de rendre la main) ; les
boucles qui appellent une fonction par ligne, qui sauvent de toute façon leurs valeurs autour de cet appel, utilisent
des lecteurs qui appellent. Les pages évincées ne sont jamais réutilisées sur place : un lecteur en course avec
l'éviction garde encore les anciens octets, qui sont justes, et le GC (le garbage collector, la partie qui libère la
mémoire que plus rien n'utilise) les libère ; une collection complète après chaque quart du cache évincé garde les
pages en mémoire sous 1,25 fois le cache. Les FIFOs de la politique (les files de S3-FIFO, plus bas) tiennent les tables d'un run (ses
pages, `hot` et les compteurs), jamais le run lui-même, dont le fichier est fermé par un finaliser (une fonction que
le GC appelle quand il libère une valeur) une fois qu'aucune vue ne tient le run : un run qu'un merge a remplacé les
quitte aussitôt, ses pages retirées et ses entrées supprimées (un passage sur les FIFOs par merge), et une page qu'une
vue plus ancienne lit ensuite de lui y entre comme une autre, sans garder son fichier ouvert.

**Le coût quand tout est en mémoire**, 10 M de faits, build de release, 11 exécutions x 2 tours alternés, contre la
base mappée du jalon 2 (c67e52d) : Q1 0,37 à 0,39 µs (+5 %), Q2 1,73 à 1,66 µs (-4 %), Q3 3,67 à 3,98 ms (+8 %),
Q4 199 à 226 ms (+13 %), Q5 0,93-0,95 à 0,97-1,02 s (+3 à +8 %). Le reste est le prix de la table : un chargement
dépendant de plus par lecture et un gestionnaire d'exception par recherche. Des pages de 64 KiB (une table quatre fois
plus petite) ont donné les mêmes temps ; le garbage collector n'est pas en cause (18 collections majeures contre 2 sur
une exécution, mais un space overhead de 400, le réglage d'OCaml qui laisse le tas grandir davantage avant de
collecter, ne change rien).

**La politique.** S3-FIFO [Yang 2023] : une page entre dans une petite FIFO (une file où le premier entré est le premier
sorti ; 10 % de la place) ; quand elle en sort, elle passe dans la FIFO principale si elle a été lue à nouveau
entre-temps, sinon elle sort (sa clé va dans une ghost FIFO, et une page trouvée là lors d'un miss va directement dans
la FIFO principale) ; une page au bout de la FIFO principale est gardée si elle a été lue depuis la dernière fois que la
politique l'a regardée (son compteur de 2 bits diminué), sinon elle sort. Ses compteurs ne demandent aucune liste à
réordonner sur un hit (un hit : la page demandée est déjà dans le cache ; un miss : elle n'y est pas) : ici, la lecture
d'une page hot n'apprend rien à la politique, et la politique retire une page de `hot` quand elle la regarde, pour que
la lecture suivante compte. C'est ce qu'il faut à un cache lu par plusieurs domains sans lock ; LRU, 2Q [Johnson 1994]
et ARC [Megiddo 2003] déplacent une page dans une liste à chaque hit, ce qui demande un lock ou des buffers de hits
(comme le fait Caffeine pour W-TinyLFU [Einziger 2017]).

**Vérifié sur des traces enregistrées**, contre l'optimum de Belady [Belady 1966] (évincer la page qui sera lue à
nouveau le plus loin dans le futur ; avec admission, une page lue à nouveau plus tard que toutes les pages résidentes
n'est pas gardée : aucune politique en ligne ne fait mieux). Une trace est la suite des pages lues par une journée de
questions sur la base de 10 M, une entrée par page et par recherche (`bench.exe trace`, puis `bench.exe cachesim`) ;
taux de hits, tailles de cache en part des 8 612 pages lues :

| une journée : 30 000 questions ponctuelles sur des clients tirés selon une loi de Zipf (0,99), une Q4, une Q5 ; 91,5 M de lectures | LRU | CLOCK | 2Q | ARC | SIEVE | S3-FIFO | W-TinyLFU | OPT |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 2 % (172 pages) | 94,02 | 94,02 | 93,81 | 94,01 | 93,94 | 94,02 | 85,43 | 95,21 |
| 5 % | 94,43 | 94,45 | 94,65 | 94,46 | 94,48 | 94,47 | 92,85 | 96,06 |
| 10 % | 94,98 | 95,00 | 95,34 | 95,06 | 95,08 | 95,17 | 94,72 | 96,92 |
| 25 % | 96,31 | 96,32 | 96,68 | 96,39 | 96,57 | 96,53 | 96,89 | 98,43 |

| questions ponctuelles seules (Zipf), 19,5 M de lectures, 7 873 pages | LRU | CLOCK | 2Q | ARC | SIEVE | S3-FIFO | W-TinyLFU | OPT |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 2 % | 97,77 | 97,76 | 97,71 | 97,76 | 97,69 | 97,77 | 91,64 | 98,01 |
| 5 % | 97,85 | 97,84 | 97,96 | 97,85 | 97,82 | 97,85 | 95,82 | 98,22 |
| 10 % | 97,91 | 97,91 | 98,13 | 97,91 | 97,90 | 97,93 | 98,15 | 98,43 |
| 25 % | 98,04 | 98,04 | 98,44 | 98,04 | 98,04 | 98,23 | 98,48 | 99,03 |

| les mêmes avec le scan d'une Q4 au milieu, 31,7 M de lectures, 8 195 pages | LRU | CLOCK | 2Q | ARC | SIEVE | S3-FIFO | W-TinyLFU | OPT |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 2 % | 98,61 | 98,61 | 98,57 | 98,61 | 98,57 | 98,62 | 94,85 | 98,76 |
| 5 % | 98,66 | 98,66 | 98,74 | 98,66 | 98,64 | 98,66 | 98,20 | 98,89 |
| 10 % | 98,70 | 98,70 | 98,84 | 98,70 | 98,70 | 98,71 | 98,85 | 99,03 |
| 25 % | 98,78 | 98,78 | 99,04 | 98,78 | 98,78 | 98,90 | 99,06 | 99,42 |

(La loi uniforme donne le même tableau que la loi de Zipf pour la journée, à 0,02 point près : Q4 et Q5 font 90 % de
ses lectures.)

Ce que cela dit. Les pages qu'une recherche lit en premier (le haut d'une recherche dichotomique, les tables
d'offsets) sont lues si souvent que 2 % des pages servent déjà 94 à 98 % des lectures, et les politiques diffèrent de
moins d'un point de taux de hits, sauf W-TinyLFU aux petites tailles (sa fenêtre de 1 % y fait une ou deux pages). En
misses, les écarts sont plus grands : à 25 %, LRU manque 1,96 % des lectures ponctuelles, S3-FIFO 1,77 %, 2Q 1,56 %,
W-TinyLFU 1,52 %, Belady 0,97 % : les meilleures politiques en ligne manquent 12 à 14 % de moins que S3-FIFO, et
l'optimum environ moitié moins que n'importe laquelle. S3-FIFO vaut LRU et CLOCK partout et fait mieux à 25 %, sans lock
sur un hit ; 2Q et W-TinyLFU réordonnent une liste à chaque hit. L'écart qui compte davantage est la disposition des
données (plus bas). Choisi : S3-FIFO ; le gain de 2Q ne vaudrait un lock que si les hits restaient dans un seul
domain, ce que les questions en parallèle cassent.

**Plus grand que la mémoire**, 10 M de faits (une base de 245 MB au jalon 2), cache de 32 MB, le processus limité
à 128 MB (benchmarks) : ouverture 67 ms (64 MB résidents), Q1 41 µs, Q2 1,8 µs, Q3 89 ms, Q4 385 ms sur un cœur et
247 ms sur trois (les mêmes réponses ; PostgreSQL avec 32 MB de buffers sous la même limite : 176 µs, 5,5 µs, 446 ms
par son socket, 697 et 658 ms), pic de 79 à 105 MB ; sur un seul run des niveaux depuis, Q1 39,7 µs, Q2 1,54 µs, Q3
85,8 ms, Q4 383 ms, Q5 96,8 s. Q5 prend 97 à 102 s (PostgreSQL 1,05 s) : les liens follow d'un client se trouvent
parmi les lignes de ses factures (la base range les lignes par chose), donc la question des triangles lit des pages
au hasard dans les 120 MB de lignes par chose, pour quelques octets chacune. Un troisième ordre des lignes, par
propriété puis chose (comme le gardent Hexastore [Weiss 2008] et RDF-3X [Neumann 2008]), rendrait locale une propriété
de beaucoup de choses ; il coûte 10 octets de plus par fait. À décider sur des mesures de charges réelles.

**Ce que coûtait un merge, jusqu'à ce qu'il soit écrit dans un fichier.** Un merge construisait la nouvelle base en
mémoire (des tableaux pour son tri, puis ses pages) à côté de l'ancienne, et les pages des deux vivaient sur le tas
d'OCaml : les exécutions d'écriture avec merges montaient jusqu'à 1,8 à 3,3 GB à 10 M de faits. La section 8 est le
remède.

## 8. Merges écrits dans un fichier

Un merge réunit le delta (niveau 0 : des persistent maps en mémoire) et les runs les plus récents sur disque en un
seul run (section 9) : le rolling merge d'un LSM-tree [O'Neil 1996], plusieurs composants dans le suivant. Chaque entrée est déjà triée dans l'ordre de
chaque section d'un run (par chose : chose, propriété, valeur ; par propriété : propriété, valeur, chose ; les textes
par numéro) ; chaque section du nouveau run est donc une fusion d'entrées triées, faite en une passe avec un curseur
dans chacune : $O(n + d)$ étapes pour $n$ lignes dans les runs et $d$ changements, et aucun tri. Les sources sont lues un bloc à
la fois (le record d'une chose, un bloc de 128 lignes décodé dans un petit tableau), et les blocs du nouveau run sont
codés à mesure qu'ils se remplissent : 128 choses, ou 128 lignes d'une propriété (section 11).

**En flux.** Le nouveau run est écrit en trois passes, chacune pour ses deux parties : par chose (les rank tables, les
blocs de choses et leur répertoire), par propriété (offsets, blocs de lignes et leur répertoire, les value indexes,
les comptes de valeurs distinctes), le dictionnaire (offsets, octets, la hash table, construite en mémoire : 4 octets
par slot ; partie a seulement). Une partie est disposée selon des bornes supérieures de ses comptes (un merge ne les
connaît qu'une fois fini) : la place que ses flux n'atteignent pas compte comme des zéros écrits, et une page tout
entière dans cette place n'est jamais écrite : le fichier ne tient que les pages écrites, dans l'ordre où elles se
terminent, et une page table à sa fin associe chaque page de la disposition à sa page du fichier (une page de la
disposition qu'aucune ne tient se lit comme des zéros). Dans une passe, les flux de ses sections avancent côte à côte,
chacun dans sa propre région de la disposition. Une page de 16 KiB est complète une fois tous ses octets écrits (deux
sections peuvent en partager une) et part aussitôt : son CRC-32C, un `pwrite` comme page suivante du fichier, et le
cache, qui l'admet froide (dans la petite file de S3-FIFO, pas hot : la sortie d'un merge est un scan, gardé seulement
s'il est lu avant que la file l'atteigne). Puis la page table, l'en-tête, un fsync, et l'installation (G12).

**La borne de mémoire.** Soit $C$ la capacité du cache et $P$ les pages du nouveau run. Pendant un merge, le processus
tient, en plus de ce qu'il tenait avant (le delta, le log des groupes écrits entre-temps) :
- les pages des runs qu'il lit et du nouveau run qu'il écrit, toutes comptées par le cache : au plus $C$, par
  construction (une page n'entre que par `Pages.fill` ou `Pages.admit`, qui font de la place d'abord) ;
- les pages en cours de remplissage : la page sous la tête de chaque flux, et la première page d'une section pendant
  qu'elle attend que la section d'avant y finisse : au plus 2 pour chaque flux de la passe, $2s$ pour $s$ flux : 18 dans
  la passe par propriété ; dans la passe par chose, le run format 8 en ajoute 4 pour la colonne de chaque propriété, si
  bien que $s$ grandit avec les propriétés du schéma (19 pages mesurées dans le test unitaire, dont la borne est 24) ;
- les tables du nouveau run : 4 octets de CRC, 4 de sa place dans le fichier, deux slots de 8 octets (frame et hot) et
  un compte par page de sa disposition, 25 octets pour 16 KiB de disposition (la disposition d'un run codé est
  lâche : 1 118 MB pour les 54,4 MB du bottom run de 10 M, le run du niveau le plus bas, donc 1,7 MB de tables, 3,1 %
  du run) ;
- les blocs en cours de codage (128 choses ou 128 lignes, avec leur buffer de travail : quelques KiB, plus seulement
  pour une chose qui a énormément de valeurs) et la hash table des textes (4 octets par slot, deux slots par texte du
  nouveau run).

Donc $M_{\text{merge}} \le C + 2s \times 16\ \text{KiB} + 25 P + 8\, \mathit{ns}$ ($s$ les flux de la plus grande
passe, $\mathit{ns}$ les textes du nouveau run), indépendant de la taille des runs, à part les tables. Le
merge en mémoire qu'il a remplacé tenait 7 mots par fait pour son tri (560 MB à 10 M de faits) et toute la nouvelle
base hors du cache. Mesuré sur le niveau unique (benchmarks, le merge écrit dans un fichier) : avec toute la base dans
un cache de 1 GiB, un merge de la base de 10 M et d'un delta de 400 000 faits fait passer le processus de 412 MB à un
pic de 651 à 656 MB (les 245 MB de pages de la nouvelle base), contre 1 222 à 1 450 MB pour le merge en mémoire ; avec
un cache de 32 MB, de 63 MB à un pic de 99 MB, sous une limite de 128 MB qui tue le merge en mémoire.

**Ce que cela coûte en écritures.** Avec un seul niveau (avant la section 9), un merge écrivait toute la base chaque
fois que le delta dépassait $\max(200\,000, n/16)$ changements : jusqu'à 17 faits écrits par changement (le size ratio $r = 16$ d'un
LSM-tree à deux composants, coût amorti $r + 1$ [O'Neil 1996]), 245 MB par merge à 10 M de faits, environ 400 octets
par changement. Ces écritures font concurrence aux fsyncs du journal, que chaque client attend. Forcées une fois à la
fin, les 100 à 245 MB de dirty pages d'un merge faisaient attendre un fsync du journal plusieurs secondes (un
chargement de 3 M de faits : fsync du journal au p99,9 1,6 s, max 4,7 s) ; forcées tous les 8 MiB à mesure de
l'écriture (ce que fait le `bytes_per_sync` de RocksDB [Dong 2017]), la queue est tombée à p99,9 0,43 s, max 1,0 s. Chaque fsync
coûte cependant du temps au merge ; un merge ne force donc par étapes que pendant que le journal écrit, et une seule
fois sinon. Un chargement soutenu payait encore les octets : 10 M de faits chargés en 135 à 153 s contre 63 à 79 s avec
les merges en mémoire ; espacer les écritures du merge (un token bucket, comme le rate limiter de RocksDB) n'a pas
aidé sur ce disque. La section 9 est le remède : des niveaux, et les grands groupes fusionnés d'un coup.

**Sûreté face aux crashs.** Voir G12 dans les [garanties](guarantees.md) : le fichier est forcé avant son renommage, il
n'est nommé qu'une fois son groupe durable dans le journal, les runs qu'il remplace ne partent qu'une fois le nouveau
nom durable, et la recovery écrit à nouveau la frame la plus récente et force ce qu'un processus tué a laissé dans le
page cache avant de rejouer. `spec/Merge.tla` modélise le protocole avec le journal réduit à ses groupes écrits et
durables, des chaînes de runs (section 9), F1, F2, F4 et le marqueur de fermeture propre qui épargne ses fsyncs à une
ouverture ; TLC vérifie cinq invariants sur 983 080 états, et chacune des cinq règles, retirée seule, donne un
contre-exemple en 4 ou 5 étapes. C'est le protocole qu'ALICE [Pillai 2014] a trouvé mal fait dans beaucoup
d'applications (un renommage avant le fsync des données, un fichier cru avant que son répertoire soit forcé).

## 9. Niveaux sur disque, et grands groupes

**Les mots.** Un **run** est un fichier trié du LSM-tree ; un **level** (un niveau) est une place pour des runs, avec
une capacité, chaque niveau étant $T$ fois plus grand que celui du dessus ($T$ est le **size ratio**, le rapport de
taille). La **write amplification** $W$ est le nombre de fois qu'un fait est écrit sur le disque par les merges au cours
de sa vie, pour une écriture par un client ; la **read amplification** $R$ est le nombre de runs qu'une lecture doit
visiter. Sous **leveling**, chaque niveau tient un seul run, et un run qui descend est fusionné avec celui qui s'y trouve
déjà ; sous **tiering**, un niveau tient jusqu'à $T$ runs, fusionnés ensemble dans le niveau suivant quand il est plein.
L'un s'échange contre l'autre : moins de runs à lire pour plus de réécriture.

**Leveling ou tiering.** Soit $N$ les faits, $B$ les changements que le delta tient avant d'être fusionné (`compact_min`,
200 000), $T$ le size ratio entre niveaux, $L = \lceil \log_T(N/B) \rceil$ les niveaux sur disque. Sous leveling [O'Neil 1996], [Luo 2020], chaque
niveau est un seul run trié, au plus $T$ fois celui du dessus ; un run entre dans un niveau par un merge avec le run qui
s'y trouve déjà. Un niveau se remplit en environ $T$ merges venus du niveau du dessus ; un fait qui descend au $k$-ième
d'entre eux est écrit à ce moment, puis à nouveau à chacun des $T - k$ suivants, soit $T - k + 1$ fois, et la moyenne sur $k = 1, \dots, T$ est $(T + 1)/2$. Un
fait est donc écrit environ $(T + 1)/2$ fois par niveau : write amplification $W \approx L (T + 1)/2$. Une lecture visite un run par niveau :
$R = L$. Sous tiering [Luo 2020], un niveau tient jusqu'à $T$ runs, fusionnés en un run du niveau suivant quand il est
plein : un fait est écrit une fois par niveau, $W \approx L$, mais une lecture visite jusqu'à $T$ runs par niveau, $R \approx T L$. Le lazy
leveling (Dostoevsky [Dayan 2018]) applique le tiering à chaque niveau sauf le dernier : $W \approx L - 1 + (T + 1)/2$, $R \approx T (L - 1) + 1$. Les
Bloom filters (de petites tables de bits qui disent « absent à coup sûr » ou « peut-être présent ») font coûter à la
lecture ponctuelle d'une clé environ la sonde d'un seul run, quel que soit $R$ (Monkey [Dayan 2017]), mais ils n'aident
que les recherches d'une clé entière ; les lectures de Cepheus sont des intervalles courts (les faits d'une chose, les
choses d'une valeur) et des comptes exacts, qui visitent chaque run qui peut tenir la clé. Ici $R$ pèse donc autant que
$W$, et le leveling est le choix.

Les chiffres, tirés d'un modèle du chargement de 10 M des benchmarks (un court script gardé avec les sorties brutes,
hors du dépôt : les groupes du chargement dans l'ordre, de petits groupes d'un client chacun, les merges que fait
chaque politique ; les faits qu'écrit chaque merge sont comptés, ainsi que les runs qu'une lecture visiterait après
chaque groupe) :

```
policy (B = 200,000)        facts written   amplification   runs at most   runs on average
one level (before)          145 M           14.5            1              1
leveling, T = 4              58 M            5.8            3              2.1
leveling, T = 10             75 M            7.5            2              1.8
tiering, T = 4               39 M            3.9            8              4.4
tiering, T = 8               29 M            2.9           12              7.0
```

$T = 4$ écrit 23 % de moins que $T = 10$ (58 M de faits contre 75 M) pour un run de plus au maximum à 10 M de faits (3 contre 2).
La formule concorde : à $N/B = 50$, elle donne $L (T + 1)/2 = 8$, 7,5 et 9 écritures par fait pour $T = 3$, 4 et 5 ($L = 4$, 3, 3),
et 11 pour $T = 10$ ($L = 2$) ; le modèle écrit moins que la formule parce que le dernier niveau est loin d'être plein.
Le ratio par défaut de RocksDB, 10 (son `max_bytes_for_level_multiplier`), convient à un lecteur qui a des Bloom
filters. Choisi : le leveling, $T = 4$ (`Engine.ratio`) : le niveau $l$ tient au plus $B \cdot 4^l$ lignes. Un merge prend le delta et les runs les
plus récents jusqu'au premier niveau qui peut tous les tenir, et y écrit un seul run (`Engine.plan`) : les niveaux
qu'il saute sont fusionnés dans la même passe, donc un fait les traverse en une seule écriture.

**Plusieurs runs lus comme un seul.** Un run tient les changements d'un intervalle de groupes par-dessus les runs en
dessous de lui : les faits qu'il ajoute (partie a), et les faits des runs en dessous qu'il retire (partie t, vide au
fond). Ses comptes sont nets : il n'ajoute que des faits absents en dessous de lui et ne retire que des faits présents en
dessous de lui. Alors un fait est dans une vue si et seulement si l'entrée la plus récente qui le concerne l'ajoute, et
chaque compte est la somme, sur les runs, des lignes de la partie a moins celles de la partie t, plus celles du delta :
les comptes exacts restent en $O(R \log n)$. Un merge de sources (le delta, les runs les plus récents) décide de chaque fait d'après sa
seule entrée la plus récente et sa seule entrée la plus ancienne : la plus récente dit s'il est dans le nouvel état, la
plus ancienne s'il était dans l'état sous les runs fusionnés (une addition là veut dire qu'il n'y était pas) ; le
nouveau run l'ajoute s'il y est et n'y était pas, le retire s'il n'y est pas et y était, et ne tient rien sinon. Un
merge dans le niveau du fond ne tient aucun retrait.

Une ligne d'un run plus ancien n'est montrée que si aucun run plus récent ne tient d'entrée pour le même fait. Chaque
partie a une rank table par chose (le rank directory de Jacobson [Jacobson 1989] : par 32 numéros de chose, leurs bits
de présence et le compte avant eux) : un bit dit si une partie tient une chose ou non, donc la vérification coûte
quelques tests de bits, sauf si un run plus récent tient la même chose ; et une partie coûte un quart d'octet par
numéro de chose, là où la table dense d'offsets de la base à un seul niveau en coûtait 8 (les 65 536 numéros sous la
première chose compris : 512 KiB par base, même minuscule). Une recherche dans une partie est son rank (un mot de 8
octets, un popcount, aucun quand les 32 choses du bloc sont toutes là), puis les offsets de son slot, comme avant.

**Grands groupes.** Un groupe de beaucoup d'additions (`Resolve.large_min`, 20 000) prend un chemin plus rapide vers le
même résultat (`Resolve.resolve_large`) : ses additions vont dans des tableaux compacts (des Bigarrays, des tableaux
d'OCaml hors du tas : 14 octets par fait, hors du tas du garbage collector), traités par plusieurs domains en chunks
(morceaux) pris à tour de rôle [Leis 2014] ; les nouvelles choses et les nouveaux textes sont numérotés par une passe dans
l'ordre du groupe ; les faits sont triés par chose (rien à faire pour un groupe dans l'ordre des choses, sinon un radix
sort LSD stable des index ; un radix sort trie chiffre par chiffre, LSD en commençant par le chiffre le moins
significatif) et par propriété (un counting sort, un tri par comptage), puis par un radix sort LSD stable par valeur à
l'intérieur de chaque propriété (des chiffres de 11 bits, Knuth [Knuth 1998], 5.2.5), et un merge les lit comme une
source de plus, la plus récente, à côté du delta et des runs ; aucune persistent map n'est construite pour eux. Le
chemin rapide ne décide que ce qu'il peut décider seul (des additions à des choses nouvelles ou ordinaires, une valeur
par chose nouvelle pour une propriété à une seule valeur, des additions à plusieurs valeurs à des choses existantes,
aucune valeur unique déjà prise) ; au moindre doute, le groupe passe par `Resolve.resolve`, qui décide comme toujours
(erreurs comprises). Son résultat est le même : les mêmes changements dans le même ordre, les mêmes numéros de chose,
les mêmes numéros de texte (chaque texte est numéroté à sa première addition, comme `Resolve` l'enregistre) ; un fork,
qui prend toujours `Resolve`, répond donc comme la base (G8).

*Pourquoi la numérotation est celle de Resolve, bien que les chunks soient traités dans n'importe quel ordre.*
`Resolve` donne au $k$-ième numéro temporaire distinct rencontré dans l'ordre du groupe le numéro $\mathit{next}_e + k - 1$ (la cible d'un
lien après la chose de son opération), et au $j$-ième nouveau texte le numéro de texte suivant. Les chunks découpent
l'ordre du groupe en slices consécutives ; un chunk note, dans son propre ordre, ce qu'il rencontre, et la passe de
numérotation lit les chunks dans leur ordre, chacun dans le sien : elle rencontre chaque première utilisation dans
l'ordre du groupe, et attribue donc les mêmes numéros. Les tests unitaires comparent les deux chemins sur des grands
groupes aléatoires (des chunks de 1 à 9 opérations, des numéros temporaires près de -1 et loin sous la longueur du
groupe, des groupes sans ordre et dans l'ordre des choses) : le codage octet pour octet, le reçu, les faits après le
merge et après un replay (une relecture du journal).

*Coût.* Pour $n$ faits d'un groupe dans l'ordre des choses, avec $k$ domains : le traitement et la réécriture en $O(n / k)$
chacun, la numérotation en $O(n)$ sur un domain (un tableau lu par fait), le counting sort par propriété en $O(n / k)$, le radix
sort en $O(d n / 2)$ avec $d$ passes (2 à 10 M de faits : des valeurs sous $2^{22}$), le merge en $O(n)$ sur un domain à côté du codage sur
un autre. Mémoire : 14 octets par fait dans l'ordre du groupe et 12 par propriété, la place d'une passe de radix pour la
plus grande propriété sur chacun de ses 2 domains, et le reçu que reçoit l'appelant (une paire par chose nouvelle).

Le merge d'un grand groupe tourne dans le writer, quand le groupe est préparé, et écrit un fichier de run qui n'est
nommé qu'une fois la frame du groupe durable et le run lui-même forcé (le commit force les deux à la fois, sur deux
fichiers, puis installe le run, comme celui d'un merge en arrière-plan : G12). Aucun merge en arrière-plan ne tourne à
côté, et sa frame, écrite par morceaux à côté du merge, est la seule frame en cours d'écriture.

## 10. Règles

Les règles sont du Datalog (un langage de règles logiques : « si ces faits sont là, ce fait-là l'est aussi ») ; ce
que tient une base avec des règles est le least model (le plus petit modèle) de ses faits affirmés ([Abiteboul 1995]).
Quatre faits rendent la maintenance du writer exacte et son coût ce qu'il est ([règles](rules.md) décrit les
algorithmes) :

- **Le travail d'un groupe** est $\Theta(D)$ pour $D$ instances de règles qui touchent un fait changé par le groupe : la
  semi-naive evaluation (l'évaluation qui, à chaque tour, ne joint que les faits nouveaux du tour précédent) énumère
  chaque instance une fois, à son fait le plus récent, les atomes avant celui qui correspond sur les tours plus anciens
  et ceux d'après sur les tours jusqu'au sien (la propriété semi-naive, [Ramakrishnan 1990]). Le modèle de coût d'un groupe est
  $D \times c_d + N \times c_i$ : $c_d$ une dérivation (les joins de son corps et le test de sa tête), $c_i$ un nouveau fait mis dans la
  vue, pour $N$ nouveaux faits. Chaque fait a au moins une dérivation, donc $D \ge N$ ; des données en forme de LUBM ont $D \approx 3{,}7 N$.
- **L'insertion est complète** : une instance d'une règle sur l'état après le groupe, soit touche un fait que le groupe
  a rendu présent, et semi-naive la trouve au tour de ce fait, soit ne touche que des faits plus anciens, et le groupe
  d'avant l'a trouvée (récurrence sur les groupes ; une règle ajoutée est évaluée une fois sur tout l'état).
- **Le retrait enlève exactement les faits sans preuve** (Backward/Forward, [Motik 2015]) : un fait n'est gardé que si
  la vérification en arrière le prouve à partir de faits non réfutés ; un fait n'est réfuté qu'après sa vérification,
  qui explore chaque instance de chaque règle qui le donne. La vérification tourne sur l'état d'avant le départ des
  faits réfutés (un fait supprimé peut remplir plusieurs atomes d'une même instance), et les faits retirés par le groupe
  restent dans l'état, plus affirmés, jusqu'à ce qu'ils soient tranchés : les conditions sous lesquelles l'algorithme
  est exact.
- **Aucun algorithme de maintenance n'est bon marché dans le pire cas** : une relation transitive matérialisée répond à
  l'accessibilité, et la fermeture transitive décrémentale n'a pas d'algorithme beaucoup meilleur que le recalcul, sous
  la conjecture OMv ([Henzinger 2015]) ; le pire cas de B/F est un recalcul des faits qu'il atteint. Mesurées sur des
  données en forme de LUBM, les petits retraits restent dans les microsecondes
  ([benchmarks](benchmarks.md#règles-2026-11-08)).
- **Les dérivations d'une closure, face à ses faits.** Pour prp-trp (la règle d'OWL 2 RL d'une propriété
  transitive), $T(x, z) \leftarrow T(x, y), T(y, z)$, le fait $(x, z)$ de la closure (la transitive closure, la
  fermeture transitive du point précédent : tous les couples reliés par un chemin) est dérivé une fois pour chaque $y$
  tel que $(x, y)$ et $(y, z)$ soient dans la closure : $D = \sum_{(x,z) \in T^+}
  |\{y : (x,y), (y,z) \in T^+\}|$, environ $n^3/6$ pour $n^2/2$ faits sur une chaîne de $n$ (166 par fait à $n = 500$).
  La règle linéaire dérive $(x, z)$ une fois pour chaque arête qui part de $x$ sur un chemin vers $z$. Le module de
  closure fait chaque nouveau fait une seule fois : depuis zéro, sur les strong components (les composantes fortement
  connexes : des groupes de nœuds qui s'atteignent tous les uns les autres) dans l'ordre topologique inverse, les
  cibles d'une composante sont l'union de celles de ses successeurs et de ces successeurs eux-mêmes, si bien que le
  travail est $O(V + E + \sum_{u \to w} |\mathrm{targets}(w)| + |T^+|)$, soit $O(|T^+|)$ sur une forêt (les cibles de
  chaque chose sont celles de son parent, plus ce parent : on remonte, sans aucune union) ; une arête ajoutée à une
  closure déjà présente coûte ses nouveaux faits et les faits rencontrés : $(\{a\} \cup \mathrm{pred}(a)) \times
  (\{b\} \cup \mathrm{succ}(b))$, testés une fois chacun (Hu, Motik, Horrocks [Hu 2019], [Hu 2022] ; Nuutila
  [Nuutila 1995] ; les composantes de Tarjan [Tarjan 1972]).
- **Le dépliage est exact tant que ses relations ne bougent pas.** Pour une règle $\rho$ dont les atomes $A$ portent
  sur les relations $R$, et dont $B$ est le reste, les instances de $\rho$ sur un état $S$ sont l'union, sur les
  bindings joints $\theta$ de $A$ dans $S$, des instances de $B\theta \to H\theta$ : c'est la partial evaluation
  (l'évaluation partielle : un programme spécialisé sur une partie de ses entrées) de $\rho$ sur $R$ ([Jones 1993]).
  Le programme déplié et $\rho$ ont donc le même least model sur tout état dont le $R$ est celui sur lequel on a
  déplié. B/F avec le programme déplié tient les faits de $R$ pour prouvés ; c'est correct quand aucun fait de $R$ ne
  peut perdre sa preuve sans qu'on le voie : $R$ ne doit pas dépendre de ce que donnent les règles dépliées (sinon un
  cycle à travers $R$ pourrait garder en vie deux faits qui ne se soutiennent que l'un l'autre, comme le faisaient les
  propriétés inverses avec le comptage), et un groupe qui supprime ou dérive un fait de $R$ est raisonné avec $\rho$
  telle qu'elle est écrite. Côté coût : une règle sur une propriété variable, telle qu'écrite, part de chaque fait ;
  dépliée, elle ne part que des faits de ses propriétés, chaque plan avec ses constantes en place.

## 11. Runs et journal compressés : le codage et sa borne

**Frame of reference.** Un bloc de $n$ entiers $x_1, \dots, x_n$ est rangé comme sa plus petite valeur $b$ et, pour chacun, $x_i - b$ en
$w = \lceil \log_2(\max - b + 1) \rceil$ bits, serrés l'un après l'autre (Goldstein, Ramakrishnan, Shaft [Goldstein 1998] pour des pages
de tuples ; Zukowski et al. [Zukowski 2006] pour des colonnes, avec là les valeurs aberrantes corrigées à part). Le
champ $i$ est au bit $i \cdot w$ :
il se lit par un chargement non aligné de 8 octets, un décalage et un masque (le dépaquetage scalaire de Lemire et
Boytsov [Lemire 2015] ; pas de SIMD en OCaml), donc toute valeur d'un bloc coûte $O(1)$ et ne décode rien d'autre. Un
bloc de valeurs triées coûte $w \approx \log_2(\text{étendue du bloc})$ bits par valeur ; le codeur du journal essaie aussi les **deltas** (la
première valeur, la plus petite différence $d$, puis chaque différence moins $d$), qui gagnent quand les valeurs croissent
régulièrement (les choses d'un chargement : différences 0 et 1, 1 bit chacune), et prend le bloc le plus court, un choix
fait par bloc comme le fait BtrBlocks [Kuschewski 2023]. Les différences sont modulo $2^{63}$ (les entiers de 63 bits
d'OCaml), donc chaque valeur revient exactement.

**Ce que tient le format, face à ce que tiennent les données.** À 10 M de faits (les 113 636 clients et 2,27 M de
factures du bench), l'information que tiennent les données est de 13 à 18 MB (des totaux uniformes sur 100 000
valeurs, 16,6 bits ; des dates sur 3 650, 11,8 bits ; des statuts à 70/20/10 %, 1,16 bit d'entropie ; une ville parmi
100, 6,6 bits ; un follow parmi 113 636 clients, 15,4 bits par lien pour 5 distincts ; noms et e-mails 3,4 MB
d'octets), et les listes de choses par valeur ajoutent environ 18 MB à la borne d'Elias-Fano de $2 + \lceil \log_2(u/n) \rceil$ bits par
élément [Vigna 2013] : un store qui indexe chaque propriété dans les deux sens a un plancher vers 31 à 36 MB. Le run du
format 7 prend 54,4 MB, 1,5 à 1,8 fois ce plancher, contre 24,6 octets par fait (246 MB) au format 6 (tailles en MB
de $10^6$ octets, chaque section comptée par les pages du fichier qui la tiennent) :

| section | octets | par fait | où vont les bits |
|---|---:|---:|---|
| par chose : blocs | 23,5 MB | 2,35 B | le record de champs d'une facture (client 7 bits, date 12, statut 2, total 17, chacun après un bit « présent » dans les blocs qui mêlent clients et factures) ; les propriétés des clients et leurs follows en petites colonnes |
| par chose : rank table et répertoire | 0,8 MB | 0,08 B | 32 numéros de chose par mot ; 8 octets par bloc de 128 choses |
| par propriété : blocs de lignes | 20,3 MB | 2,0 B | les choses en 7-22 bits (des choses au hasard parmi 2,27 M de numéros en prennent 21-22 : l'ordre par valeur est une permutation), les valeurs en 0-10 bits (triées) ; les choses par écarts (gaps) là où une valeur se répète (statut 3,6 bits par ligne au lieu de 8,7, date 16,2 au lieu de 19,8) |
| par propriété : répertoire et value indexes | 3,4 MB | 0,34 B | 16 octets par bloc de 128 lignes ; un mot de rank pour 32 valeurs de l'intervalle de chaque propriété, et la première ligne de chaque valeur |
| dictionnaire | 5,9 MB | 0,59 B | les octets des textes (3,4 MB), leurs offsets (0,4 MB), la hash table (2,1 MB, deux slots par texte) |
| page table | 0,5 MB | 0,05 B | 8 octets par page de la disposition (68 231 pages) |

Les deux plus gros termes tiennent à la conception : chaque fait est tenu deux fois (par chose et par propriété, chaque
ordre répondant à ses propres recherches en $O(1)$ ou $O(\log n)$), et l'ordre par propriété d'une propriété aléatoire est une
permutation de ses choses, à la borne d'information $\log_2(n!)/n \approx \log_2 n - 1{,}44$ bits par ligne pour $n$ lignes (Stirling), que les
écarts n'atteignent que là où une valeur se répète. Le reste est à un facteur 1,5 de la borne.

**Champs et colonnes par chose.** Trois dispositions d'un bloc de choses ont été mesurées sur les mêmes 10 M de faits
(un domain) :
une colonne par propriété (PAX, Ailamaki et al. [Ailamaki 2001]) : la recherche d'une facture touchait environ 16
cache lines (les blocs de 64 octets que le processeur lit d'un coup) dans des blocs qui mêlent clients et factures
(8 propriétés, chacune avec sa colonne et ses offsets), Q1 0,79 µs ; un record par chose avec chaque valeur et un compte
par propriété (un row store, comme les pages NSM) : Q1 0,43 µs, mais la recherche d'une propriété sautait les valeurs
des propriétés d'avant, 65 à 120 ns sur des factures consécutives contre 37 à 41 au format 6 (Q3 5,8 ms, Q4 316 ms) ;
et celle qui a été gardée, un record de **champs** pour les propriétés que chaque chose du bloc a au plus une fois,
quand cela ne prend pas plus de bits qu'une colonne, et des colonnes pour les autres : la recherche du statut d'une
facture est la recherche de l'entrée parmi les 8 du bloc et un champ (46 à 61 ns), Q1 0,39 µs, Q3 3,9 ms, Q4 241 ms,
pour 1,9 MB de plus que les records à 10 M de faits (des champs absents et leurs bits « présent » dans les blocs qui
mêlent clients et factures).
Les scans par propriété lisent les blocs de lignes, qui sont déjà des colonnes.

**Recherches.** Le slot d'une chose : un mot de rank. Son bloc : le mot du répertoire, l'en-tête (les entrées de ses
propriétés, 16 octets chacune : une recherche parmi les $m$ du bloc). Un champ : un chargement à $k R$ plus le bit du champ. Une
colonne : deux offsets ($c k + \text{reste}_k$) et une recherche dichotomique parmi les valeurs de la chose pour cette propriété (triées,
d'une seule largeur). Par propriété avec un value index : $O(1)$ (un mot de rank, deux offsets) ; sans : $O(\log b)$ sur les $b$ blocs de
la propriété, puis $O(\log 128)$ dans un bloc.

**Pages et trous.** Un merge dispose un run selon des bornes (il ne connaît ses comptes qu'à la fin), qui sont lâches
pour les sections codées (le bottom run de 10 M : une disposition de 1 118 MB pour 54,4 MB d'octets). Une page table
associe chaque page de la disposition à la page du fichier qui la tient ; le fichier ne tient donc que des pages
écrites, et une page jamais écrite se lit comme des zéros ; le coût est de 8 octets par page de la disposition dans le
fichier (0,5 MB ici) et de 17 octets par page en mémoire pour les tables du cache d'un run ouvert (1,2 MB). Un bloc pas
plus grand qu'une page commence à la page suivante quand il en traverserait une, donc une recherche lit ses
champs dans les octets d'une seule page (les fins sautées coûtent environ 3 % des octets des blocs).

**Textes.** Les textes de chaque run se trouvent par une hash table en open addressing (les entrées rangées dans la
table elle-même) avec linear probing (en cas de collision, on essaie le slot suivant), au plus à moitié pleine : en
moyenne 1,5 sonde pour un texte présent et 2,5 pour un texte absent (Knuth [Knuth 1998], 6.4), chaque sonde étant un
slot et une comparaison du texte dans sa page. Le hash mélange 7 octets à la fois par multiplication avec le
multiplicateur de xorshift64* [Vigna 2016]. Q2 (un client par son e-mail) passe d'une recherche dichotomique de 18
étapes (1,6 µs) à une sonde et au value index de la propriété e-mail (0,65 µs).

**Les colonnes du journal.** Un groupe est codé changement par changement dans son ordre (le replay applique les
changements dans l'ordre : un fait ajouté puis retiré dans un même groupe, les faits d'une propriété non déclarée avant
sa déclaration), mais par colonnes : les sortes, les choses, la colonne de chaque changement (sa propriété et son
constructeur), puis les valeurs de chaque colonne, chacune en blocs de 128 codés comme ci-dessus, les textes du groupe
une fois chacun. Le groupe du chargement, 9,4 M de changements : sortes 0 bit (une seule valeur), choses 1-2 bits
(deltas 0 et 1), colonnes 3 bits, valeurs par propriété (client par deltas, date 12 bits, statut 2, total 17), textes
3,4 MB une fois : 21,6 MB, 2,3 octets par changement, là où les varints du format 1 en prenaient 10. La commande zstd au
niveau 19 fait 29,4 MB de la même frame de 94 MB (mesuré ici, 2026-11-08 ; LZ4 au niveau 1, 56,6 MB) : un codage qui
connaît la structure bat les compresseurs généraux, sans C.

## 12. Ce qui vient ensuite, et pourquoi

- **Plus grand que la mémoire, le reste** (design, section 15) : des filtres par run pour les recherches par valeur
  (des Bloom filters dimensionnés par niveau comme dans Monkey [Dayan 2017]) si les lectures à travers les runs en ont
  besoin ; planifier les merges autour des clients comme le fait SILK [Balmau 2019]. Le column order (format de run 8)
  a fait passer les triangles sous une limite de 48 MB de plus de 2,5 minutes par exécution (format 7) à 0,26 s sur un
  cœur, contre 1,02 s pour SQLite ([benchmarks](benchmarks.md)).
- **Des questions plus proches des noyaux** (les 5 ms du prototype pour Q4 et 90 ms pour Q5, contre 129 et 259 ms sur
  un cœur) : les candidats d'un niveau recherchés par lots (vectorized execution, l'exécution par lots de valeurs) là où
  les appels par binding coûtent maintenant plus que les lectures ; des slices parcourues par galloping à l'intérieur du
  run plutôt que lues dans des buffers (un bloc codé par écarts ne s'ouvre qu'à la première ligne d'une valeur). Le
  codage du merge (environ 100 ns par fait) sur deux domains, un par passe, une fois qu'un domain d'appoint ne ralentira
  plus les cycles du GC (mesuré : un domain à côté de la passe par chose, inactif ou occupé, gardait 300 MB de tas de
  plus au pic du chargement en 4 groupes). Un dictionnaire qui préserve l'ordre, reconstruit à chaque merge (Binnig et
  al. [Binnig 2009]), pour les intervalles sur des textes.
- **Règles, les étapes suivantes** ([règles](rules.md#ce-qui-nest-pas-encore-là)) : le module de fermeture pour les propriétés
  transitives (la materialisation modulaire de Hu, Motik et Horrocks, [Hu 2019]), des règles spécialisées par
  l'ontologie, des dérivations parallèles triées, l'égalité par réécriture ; des abonnements par les
  règles de delta de DBSP.
- **Réplication** : Raft [Ongaro 2014] avec une recovery consciente du protocole [Alagappan 2018] ; le journal est la seule chose répliquée (Aurora [Verbitski 2017]).
- **Plusieurs machines** : des bases réparties sur des machines, puis le stockage sur des object stores (Socrates [Antonopoulos 2019]), puis une base
  partitionnée par chose avec un ordre déterministe des groupes entre partitions (Calvin [Thomson 2012]) et un Generic Join
  distribué (BiGJoin [Ammar 2018]).

## Pour aller plus loin

Chaque section nomme ses sources ; les entrées, avec leurs liens et ce que Cepheus a pris de chacune, sont dans les
[références](references.md), par sujet : stockage et LSM-trees, journalisation et recovery, gestion des buffers,
index, joins, transactions et isolation, structures persistantes, tests et vérification, benchmarks et statistiques.
