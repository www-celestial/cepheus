# Glossaire

Chaque terme qu'emploie la documentation, en mots simples, avec la page qui l'explique. Les termes techniques restent en
anglais, comme dans les pages ; quand les pages françaises disent un mot français (fait, chose, groupe, vue...), il est
donné entre parenthèses. Là où le nom de Cepheus diffère du nom habituel, les deux sont donnés.

- **AEGIS-256** — un chiffrement authentifié (Wu et Preneel, 2013 : il chiffre les octets et y joint un tag, une
  empreinte qui révèle tout changement) avec une clé, un nonce (un nombre à ne jamais réutiliser sous une même clé) et
  un tag de 256 bits, rapide grâce aux instructions AES du processeur : il scelle chaque chunk du vault (chaque morceau
  d'un fichier gardé dans le vault de fichiers de la base). [vault](vault.md#scellé--aegis-256-sous-la-clé-du-propriétaire)
- **AGM bound** — la plus grande réponse que peut avoir une conjunctive query, calculée à partir des tailles de ses
  entrées par une fractional edge cover (une couverture fractionnaire des arêtes ; Atserias, Grohe, Marx 2008) :
  $N^{1{,}5}$ pour les triangles de $N$ liens. Un worst-case optimal join ne travaille jamais beaucoup au-delà.
  [théorie](theory.md#4-generic-join)
- **anti-dependency** (rw edge) — dans une history (un historique de transactions), une arête d'une transaction qui a
  lu une version d'une donnée vers la transaction qui a écrit la version suivante : le lecteur a vu l'état d'avant
  l'écrivain. Un cycle qui passe par une telle arête est l'anomalie G2 d'Adya.
  [cas](case-seats.md#de-vrais-crashs-et-un-vérificateur-de-tout-lhistorique)
- **append-only** — un fichier qu'on ne fait jamais qu'allonger, sans jamais le réécrire sur place : les segments du
  journal. [architecture](architecture.md#le-journal--un-write-ahead-log)
- **asserted fact** (un fait affirmé) — un fait qu'un programme a écrit (`Add`), par opposition à un fait qu'une règle
  a dérivé ; l'extensional database (EDB) de Datalog. Un fait peut être à la fois affirmé et dérivé.
  [règles](rules.md#ce-que-tient-la-base--le-least-model)
- **atomic** (tout ou rien ; atomique) — appliqué entièrement ou pas du tout : un groupe (G2) ; un renommage ; le
  passage à une nouvelle vue (une seule écriture atomique en mémoire). [garanties](guarantees.md#g2-tout-ou-rien)
- **atomic register**, **regular register**, **new-old inversion** — les classes de registres partagés de Lamport (On
  Interprocess Communication, 1986) : une lecture d'un registre *regular* renvoie la dernière valeur écrite avant elle
  ou une valeur en train d'être écrite, donc deux lectures l'une après l'autre peuvent voir une nouvelle valeur puis
  l'ancienne (une **new-old inversion**) ; un registre *atomic* l'interdit, chaque lecture et chaque écriture semblant
  avoir lieu à un seul instant. Les lectures linearizable sont atomiques : G15 interdit l'inversion ; le lease (un
  droit accordé pour une durée limitée) que la conception proposait d'abord la permettait.
  [serveur](server.md#lectures-locales-g15)
- **back-pressure** — un côté lent qui ralentit le côté rapide au lieu d'être submergé : à sa limite d'écritures en
  cours, une connexion n'est plus lue, les buffers du noyau se remplissent, et les écritures du programme attendent.
  Rien n'est perdu. [serveur](server.md#lordre-le-pipelining-et-la-back-pressure)
- **Backward/Forward** (B/F) — l'algorithme qui garde justes les faits dérivés quand des faits s'en vont (Motik et al.
  2015) : un fait qui a perdu une dérivation est vérifié en arrière (est-il affirmé, ou prouvé par une instance de règle
  dont les faits du corps sont prouvés ?), chaque fait une fois ; les preuves se propagent en avant parmi les faits
  vérifiés ; un fait sans preuve s'en va, et les faits qu'il donnait sont vérifiés à leur tour.
  [règles](rules.md#le-retrait--backwardforward)
- **base** — les runs d'une vue pris ensemble : les faits tels qu'ils sont aux derniers merges, triés, en colonnes,
  dans des fichiers de runs lus à travers le cache. [architecture](architecture.md#les-index--les-runs-et-le-delta)
- **baseline** — ce qu'on mesure avant que rien ne change, pour que le changement ait un nombre auquel être comparé.
  [cas](case-seats.md#2-mesurer-avant-de-rien-changer)
- **batch** — les écritures que le writer résout d'un coup (jusqu'à 4 096) ; plusieurs batches peuvent faire une seule
  frame. [limites](limits.md#les-écritures)
- **Belady's optimum** (OPT) — la politique d'éviction (le choix de la page à retirer du cache) qui retire la page dont
  on aura besoin le plus tard ; aucune politique réelle ne peut connaître le futur, c'est donc l'étalon.
  [théorie](theory.md#7-les-pages-et-le-cache)
- **Bigarray** — un tableau OCaml dont les éléments sont hors du tas que gère le garbage collector (la partie qui
  libère la mémoire que plus rien n'utilise), dans un seul bloc de mémoire simple (`Stdlib.Bigarray`), chaque élément
  d'une sorte et d'une taille fixes (un int32 sur 4 octets, un entier non signé de 16 bits sur 2) : le collector ne
  parcourt, ne copie ni ne déplace jamais son contenu. Les faits d'un grand groupe vivent dans des Bigarrays : 14 octets
  par fait, là où un tableau OCaml de records prendrait 8 octets par champ et serait parcouru par chaque collection
  majeure. [architecture](architecture.md#grands-groupes)
- **binary join** — un join de deux entrées à la fois ; un plan fait de tels joins peut construire plus de lignes
  intermédiaires que la réponse sur des questions cycliques. [architecture](architecture.md#questions)
- **binding** — une valeur pour chaque variable d'une question ; une réponse est un binding qui fait de chaque pattern
  un fait. [concepts](concepts.md#les-questions)
- **birthday problem** (le paradoxe des anniversaires) — la probabilité que parmi m personnes deux aient le même
  anniversaire, bien plus élevée que ce que dit l'intuition ; ici, la probabilité que deux acheteurs parmi m
  choisissent la même place parmi dix. [cas](case-seats.md#une-borne)
- **bit packing** — des nombres de $w$ bits rangés l'un après l'autre sans octet entre eux : le champ $i$ occupe les
  bits $i \cdot w$ à $i \cdot w + w - 1$, lus avec un seul chargement de 8 octets, un décalage et un masque. Avec un
  frame of reference, c'est ainsi que les runs et le journal rangent les nombres. [formats](formats.md#un-groupe)
- **BLAKE2b** — une fonction de hachage cryptographique (RFC 7693) : à partir de n'importe quels octets, 32 octets
  (BLAKE2b-256) dont on ne peut pas retrouver l'entrée. Le serveur ne garde les tokens que sous la forme de leur hash
  BLAKE2b-256. [serveur](server.md#les-tokens)
- **block** (thing block, row block ; un bloc) — l'unité dans laquelle sont codées les valeurs d'un run : 128 choses
  (par chose : un en-tête avec une base et une largeur pour chaque propriété, puis un record par chose avec ses
  propriétés à une valeur, et des colonnes pour les autres) ou 128 lignes d'une propriété (par propriété : valeurs et
  choses) ; n'importe quelle valeur d'un bloc se lit sans décoder les autres.
  [formats](formats.md#run-dirsnapshotslo-20-digits-hi-20-digitsrun)
- **body** (d'une règle ; le corps) — ses patterns et ses intervalles : la question dont les réponses donnent la tête.
  [règles](rules.md#une-règle-est-une-question-avec-une-conclusion)
- **bottom run** — un run qui ne repose sur rien (son nom commence par 20 zéros) : il contient tout l'état à son
  dernier groupe et aucun retrait.
  [architecture](architecture.md#les-runs-sur-disque)
- **buffer pool** (le cache) — la mémoire où une base garde des pages de ses fichiers, en décidant elle-même ce qui
  reste ; celui de Cepheus contient les pages de 16 KiB des runs, 1 GiB par défaut.
  [architecture](architecture.md#les-pages-et-le-cache)
- **cascade**, **clear**, **refuse** (à la suppression) — ce que fait un lien qui nomme un kind quand la chose vers
  laquelle il pointe cesse d'être du kind (`onDelete`) : `cascade` supprime aussi la chose qui pointe, `clear` retire
  le lien, `refuse` (par défaut) refuse le groupe ; les `ON DELETE CASCADE`, `SET NULL` et `RESTRICT` (ou `NO ACTION`)
  de SQL. [Cesia](cesia.md#supprimer-une-chose)
- **cardinality** (la cardinalité) — combien de valeurs une chose peut avoir pour une propriété : une (le défaut) ou
  plusieurs (`~many:true`). [concepts](concepts.md#les-propriétés-et-le-schéma)
- **certificate** (un certificat) — une clé publique et un nom, signés par une certificate authority : ce qu'un serveur
  montre dans un handshake TLS (l'échange qui ouvre une connexion chiffrée) pour prouver qu'il est celui que le client
  voulait joindre. [serveur](server.md#tls)
- **certificate authority** (CA) — la clé dont un client fait confiance aux signatures ; chaque cluster a la sienne,
  faite par `cepheus cluster init` (ECDSA, P-256), dont la clé privée doit rester hors ligne. [serveur](server.md#tls)
- **Cesia client** (le client Cesia) — le package `cesia/cepheus` de ce dépôt : les fonctions Cesia `Connect`, `Kind`,
  `Insert`, `Get`, `Update`, `Write`, `Find`, `Fork`, `Close`, au-dessus d'un moteur en OCaml (`cesia/native/`) qui
  parle le protocole et lit en local sur la machine du serveur. [Cesia](cesia.md)
- **chain** (de runs ; une chaîne) — des runs posés les uns sur les autres depuis 0 : chacun contient les groupes qui
  suivent le dernier groupe de celui d'en dessous. Une ouverture prend la chaîne qui atteint le groupe le plus récent
  avec le moins de runs. [architecture](architecture.md#les-runs-sur-disque)
- **checkpoint** (d'un journal, avec le commit buffer) — un fsync du journal d'une base, qui y rend durables les frames
  que le commit buffer a forcées ; un fichier du buffer n'est vidé qu'une fois que chaque journal qui y a des frames a
  eu le sien. Le checkpoint de PostgreSQL écrit ses pages de données pour que son WAL puisse être recyclé : le même
  rôle. [le serveur](server.md#plusieurs-bases-un-seul-fsync--le-commit-buffer)
- **checksum**, **CRC**, **CRC-32C** — un nombre court calculé à partir d'octets, qui change s'ils changent ; CRC-32C
  (le polynôme de Castagnoli, le checksum d'iSCSI, RFC 3720) détecte toute rafale d'au plus 32 bits et laisse passer un
  dommage aléatoire avec une probabilité $2^{-32}$. Cepheus le calcule par l'instruction même du processeur (SSE4.2 sur
  x86-64, CRC32 sur arm64). [architecture](architecture.md#le-journal--un-write-ahead-log)
- **chunk** (d'un grand groupe) — 65 536 opérations d'un grand groupe (`Bulk.chunk`), l'unité de travail que les
  domains prennent à tour de rôle pendant que le groupe est rangé dans ses tableaux, vérifié et trié (morsel-driven
  scheduling, le partage du travail en petits morceaux, [Leis 2014]).
  [architecture](architecture.md#grands-groupes)
- **clean close**, **marker** (une fermeture propre, le marqueur) — `close` laisse `DIR/closed` une fois que tout est
  durable, et l'ouverture suivante peut sauter les fsyncs dont une recovery a besoin.
  [exploitation](operations.md#louverture-et-la-recovery)
- **client** — un programme connecté au serveur : il prouve qui il est avec un token et envoie des requêtes.
  [serveur](server.md#ce-que-cest-et-pourquoi)
- **CLOCK** — une politique d'éviction qui approche LRU (retirer la page utilisée il y a le plus longtemps) avec un bit
  par page et une aiguille qui tourne (Corbató 1968).
- **closed loop**, **open loop** — une charge où chaque client attend sa dernière écriture avant la suivante, contre
  une charge où les écritures sont dues à un rythme fixe quoi qu'il arrive ; seule l'open loop mesure la latence
  pendant les blocages. [benchmarks](benchmarks.md#méthode)
- **closure module** (le module de closure) — la façon dont le writer tient les faits d'une propriété transitive (Hu,
  Motik, Horrocks 2019) : chaque nouveau fait de la closure (la transitive closure : tous les couples reliés par un
  chemin) est trouvé une seule fois par des parcours, au lieu d'une fois par chemin par la règle ; reconnu sous deux
  formes, prp-trp et la paire linéaire. [règles](rules.md#les-transitive-closures--le-closure-module)
- **class of equal things** (une classe de choses égales) — les choses que les règles ont rendues identiques (le
  owl:sameAs d'OWL) : l'une d'elles, le représentant, tient les faits de la classe, et chaque autre membre x tient
  `[x cepheus/same r]`. [règles](rules.md#légalité--des-classes-de-choses-égales)
- **cluster** — les serveurs qui tiennent les mêmes bases ; une machine seule est un cluster d'un seul peer (un
  membre). Son id (`cph-c-` et 16 chiffres hexadécimaux) est dans `cluster.toml` et dans chaque Welcome.
  [serveur](server.md#clustertoml)
- **column order** (vertical partitioning) — le troisième ordre d'un run (format 8) : les lignes (chose, valeur) de
  chaque propriété à part de celles des autres, dans l'ordre des choses, les valeurs d'une chose triées (Abadi et al.
  2007). Chercher une propriété d'une chose lit un mot de rank, une entrée de répertoire et un champ des seuls octets de
  cette propriété ; une question sur quelques propriétés ne lit que les leurs.
  [formats](formats.md#run-dirsnapshotslo-20-digits-hi-20-digitsrun)
- **columns** (columnar coding ; les colonnes) — ranger ensemble les valeurs d'un même champ plutôt qu'enregistrement
  par enregistrement, pour que des valeurs semblables soient côte à côte et se codent en peu de bits : le journal code
  en colonnes les sortes, les choses et les valeurs de chaque propriété d'un groupe ; l'ordre par propriété d'un run
  est une colonne de chaque propriété. [formats](formats.md#un-groupe)
- **commit buffer** — le log forcé propre au serveur (`DATA/server.wal.1` et `.2`) : les frames de toutes ses bases y
  entrent par rounds (des tournées), un fsync par round pour tout le serveur, comme les bases de PostgreSQL partagent
  son WAL ; le journal de chaque base est écrit tout de suite mais n'est forcé qu'à ses checkpoints.
  [le serveur](server.md#plusieurs-bases-un-seul-fsync--le-commit-buffer)
- **committed** (Raft) — une entrée du log d'un cluster (le log répliqué de Raft) qu'une majorité des serveurs tient
  forcée, comptée par un leader pour une entrée de son propre term ; elle n'est plus jamais perdue ensuite.
  [serveur](server.md#un-seul-log-pour-le-cluster)
- **compaction** — un autre nom pour un merge dans un LSM-tree.
  [architecture](architecture.md#les-merges--un-log-structured-merge-tree-à-leveling)
- **component** — une des structures d'un LSM-tree : le delta en mémoire (C0), les runs sur le disque.
- **confirmed** (confirmé) — un groupe dont le `write` a renvoyé `Ok` : il est durable.
  [garanties](guarantees.md#les-pannes)
- **conjunctive query** — une question faite de patterns qui doivent tous être vrais à la fois (un ET de faits), sur
  des variables communes. [concepts](concepts.md#les-questions)
- **connection limit** — le plus grand nombre de connexions que le serveur garde ouvertes à la fois
  (`max_connections`, 512 par défaut) ; une nouvelle connexion au-delà prend la place de la plus ancienne connexion
  qui n'a montré aucun token, ou elle est fermée dès son accept.
  [serveur](server.md#clustertoml)
- **constant-time comparison** — comparer deux secrets octet par octet jusqu'au bout, quelle que soit la première
  différence, pour que le temps pris ne dise rien à un attaquant sur la part d'une tentative qui était juste.
  [serveur](server.md#les-tokens)
- **constraint** (une contrainte) — une règle dont la tête est `Never` : une réponse de son corps refuse le groupe
  (G18). [règles](rules.md#les-contraintes--never)
- **coordinated omission** — l'erreur d'une mesure en closed loop : un client bloqué par une écriture lente n'envoie
  rien pendant ce temps, donc les écritures qui auraient attendu ne sont jamais comptées (Tene 2015).
  [benchmarks](benchmarks.md#méthode)
- **copie des bases** (catch-up : le rattrapage) — dans un cluster Raft, ce que prend un follower quand le leader ne
  peut plus lui envoyer d'entrées (elles sont avant le début du log du leader) : les fichiers de chaque base, copiés
  comme le fait `cepheus backup`, vérifiés comme le fait `cepheus verify`, installés au démarrage suivant du follower ;
  le rôle d'InstallSnapshot dans Raft. [serveur](server.md#un-serveur-en-retard-sur-le-début-du-log--une-copie-des-bases)
- **counterexample** (un contre-exemple) — une suite de pas qui mène d'un état initial à un état où un invariant est
  faux ; ce qu'affiche un model checker. [cas](case-seats.md#un-modèle-formel-vérifié-par-une-machine)
- **counting** (view maintenance) — garder pour chaque fait dérivé le nombre de ses dérivations, et le supprimer à zéro
  (Gupta et al. 1993) ; exact pour les règles non récursives seulement : deux faits qui se dérivent l'un l'autre
  gardent mutuellement leur compte au-dessus de zéro. [règles](rules.md#le-retrait--backwardforward)
- **counting sort** — un tri qui compte combien d'éléments tombent sur chaque clé, puis place chaque élément à la place
  de sa clé en une passe : $O(n + \text{clés})$, sans comparaison. Les faits d'un grand groupe sont triés par propriété
  de cette façon, en chunks comptés et répartis en même temps par plusieurs domains.
  [théorie](theory.md#9-niveaux-sur-disque-et-grands-groupes)
- **cut** (du journal ; la coupe) — après une écriture ou un fsync qui a échoué, le writer tronque le journal jusqu'à
  la fin de sa dernière frame durable et le force, pour que l'écriture échouée ait disparu de la mémoire et du disque
  (G13). [garanties](guarantees.md#g13-on-ne-se-fie-jamais-à-un-fsync-qui-a-échoué)
- **damage** (un dommage) — des octets durables qui ont changé (la panne F3) ; la recovery refuse d'ouvrir plutôt que
  de les écarter, à la différence d'un torn write. [architecture](architecture.md#la-recovery--torn-writes-et-dommages)
- **Datalog** — le langage de règles des bases de données déductives : des règles `H ← B1, …, Bn` sur des relations,
  sans symboles de fonction ; ses programmes finissent toujours et ont un least model. Les règles de Cepheus sont du
  Datalog sur des faits. [règles](rules.md#une-règle-est-une-question-avec-une-conclusion)
- **datom** — le fait de Datomic : entité, attribut, valeur, transaction, ajouté. Le fait de Cepheus, ce sont les trois
  premiers ; le groupe et l'indicateur d'ajout ou de retrait vivent dans le journal.
  [concepts](concepts.md#les-faits--le-modèle-entityattributevalue)
- **Delete** (d'une chose ; supprimer) — l'opération qui supprime une chose d'un kind, le `DELETE` de SQL : les faits
  de la chose du kind retirés au writer, et les liens vers elle suivis, en un seul groupe ; la chose reste dans
  l'historique. [Cesia](cesia.md#supprimer-une-chose)
- **delta** — les changements depuis le dernier merge, dans des persistent maps (des tables dont les anciennes versions
  restent valides) ; le niveau 0 du LSM-tree (C0), environ 170 octets par changement.
  [architecture](architecture.md#les-index--les-runs-et-le-delta) Dans le reasoner (la partie qui applique les
  règles), $\Delta$ est autre chose : les faits qu'un groupe change, à partir desquels la semi-naive evaluation dérive
  (le tour 0, ce sont les ajouts affirmés du groupe).
  [règles](rules.md#comment-le-writer-la-tient-à-jour--la-semi-naive-evaluation)
- **delta debugging** — réduire un cas qui échoue en en retirant des parties tant qu'il échoue encore, jusqu'à ce que
  chaque partie restante soit nécessaire (Zeller et Hildebrandt 2002).
  [cas](case-seats.md#3-une-hypothèse-quon-peut-réfuter-et-sa-cause)
- **delta query** (la requête du changement) — le changement de la réponse d'un join quand des faits sont ajoutés ou
  retirés, calculé à partir de ces faits seuls : chaque nouveau binding trouvé une fois, au premier pattern qui
  correspond à un fait ajouté (Ammar et al. 2018). [Cepheus depuis Cesia](cesia.md#watch--les-questions-vivantes)
- **deltas** (delta coding) — des nombres rangés sous la forme de leur différence avec le nombre d'avant : une suite
  croissante (les choses d'un chargement : 0 et 1) prend un bit ou deux par nombre. Les colonnes du journal le prennent
  bloc par bloc quand c'est plus court que le frame of reference. [formats](formats.md#un-groupe)
- **dependency graph** (d'une history ; le graphe des dépendances) — les transactions comme nœuds, et une arête pour
  chaque raison pour laquelle l'une doit venir avant une autre : ww (elle a écrit la version que l'autre a remplacée),
  wr (l'autre a lu ce qu'elle a écrit), rw (une anti-dependency). La history est serializable quand le graphe n'a pas
  de cycle (Adya 1999).
  [cas](case-seats.md#de-vrais-crashs-et-un-vérificateur-de-tout-lhistorique)
- **derivation** (rule instance ; une dérivation) — une règle avec un fait pour chaque atome du corps, qui rend son
  corps vrai ; elle dérive sa tête. Un fait peut avoir beaucoup de dérivations.
  [règles](rules.md#comment-le-writer-la-tient-à-jour--la-semi-naive-evaluation)
- **derived fact** (un fait dérivé) — un fait que donne une règle ; tenu dans la vue comme n'importe quel fait, marqué
  « seulement dérivé » quand aucun programme ne l'a affirmé (le bit 63 de son mot de valeur dans un run).
  [règles](rules.md)
- **deterministic simulation testing** — faire tourner le moteur sur un disque simulé où une seule seed décide de
  chaque événement, pour que tout échec se rejoue exactement. [tester](testing.md)
- **description** — dans le vocabulaire d'OWL 2 RL, la chose qui porte les axiomes d'une propriété :
  `[d, owl/Property, p]`, puis `[d, owl/Domain, c]`, `[d, owl/Transitive, true]` (la chose d'une propriété ne prend
  aucun fait qui lui soit propre). [règles](rules.md#le-vocabulaire)
- **dictionary** (le dictionnaire) — la table qui numérote une seule fois chaque texte distinct (et chaque float) ; les
  lignes contiennent le numéro. Un run garde les octets de ses textes, leurs offsets (leurs positions en octets) et une
  table de hachage de ceux-ci.
- **dirty page**, **writeback** — une page du page cache du noyau qu'un programme a écrite et que le disque ne contient
  pas encore est dirty ; le writeback, c'est le noyau qui l'écrit sur le disque, à un fsync ou en arrière-plan. La frame
  d'un grand groupe est forcée par morceaux pendant que son run est fait, pour que son writeback se fasse en même temps
  que le merge. [architecture](architecture.md#grands-groupes)
- **domain** — l'unité de parallélisme d'OCaml 5 : un fil d'exécution sur son propre cœur, avec son propre jeune tas
  et son propre runtime lock ; les threads d'un même domain se relaient.
  [architecture](architecture.md#un-seul-writer-threads-et-domains)
- **DRed** (delete and rederive) — l'algorithme de maintenance qui supprime toutes les conséquences des faits
  supprimés, puis dérive de nouveau celles qui ont encore une preuve (Gupta et al. 1993).
  [règles](rules.md#le-retrait--backwardforward)
- **durable** — sur le disque lui-même, pas seulement dans la mémoire du noyau : couvert par un fsync terminé.
- **EDB, IDB** — extensional et intensional database : les faits affirmés, et les faits dérivés.
  [règles](rules.md#ce-que-tient-la-base--le-least-model)
- **Elle** — le vérificateur qu'utilise Jepsen pour trouver des anomalies d'isolation dans l'historique enregistré
  d'une base, en déduisant son dependency graph et en y cherchant des cycles (Kingsbury et Alvaro 2020).
- **engine** (d'un package natif ; le moteur) — l'OCaml d'un package natif de Cesia, compilé en code machine dans un
  seul fichier (`native/cepheus-TAG.cmxs`, un plugin OCaml : une bibliothèque partagée que le programme en cours lie à
  lui-même) que Cesia charge au premier appel du package, et qui n'atteint le programme qu'à travers l'interface native
  figée de Cesia, `Cesia_v1`. [Cesia](cesia.md#le-package)
- **entity–attribute–value** (EAV) — un modèle où les données sont un ensemble d'énoncés (entité, attribut, valeur)
  au lieu de tables ; chez Cepheus, (chose, propriété, valeur).
  [concepts](concepts.md#les-faits--le-modèle-entityattributevalue)
- **epoch** (une epoch) — une partie numérotée de l'historique d'une base, entre deux promotions : `DIR/epochs` liste
  chaque epoch et son premier groupe (PostgreSQL l'appelle une timeline). Une copie ne peut suivre un primary que si
  son historique est un préfixe de celui du primary. [serveur](server.md#la-promotion-à-la-main)
- **eviction policy** (la politique d'éviction) — la règle qui choisit quelle page quitte un cache plein ; celle de
  Cepheus est S3-FIFO.
- **`Expect`** — une précondition d'un groupe : un fait qui doit être vrai (ou une valeur qui doit être absente) juste
  avant lui ; le writer la vérifie, et sinon le groupe échoue avec `Conflict`.
  [concepts](concepts.md#les-groupes--une-écriture-est-une-transaction)
- **F1, F2, F3, F4** — les pannes couvertes : un crash du processus, une coupure de courant, un dommage silencieux
  d'octets durables, une écriture ou un fsync qui échoue. [garanties](guarantees.md#les-pannes)
- **fact** (un fait) — un triplet (chose, propriété, valeur).
  [concepts](concepts.md#les-faits--le-modèle-entityattributevalue)
- **failed fsync**, **marked clean** — quand un fsync échoue, Linux marque comme clean (propres, rien à écrire) les
  pages qu'il n'a pas pu écrire, bien qu'elles n'aient jamais atteint le disque : ext4 et XFS gardent leurs nouveaux
  octets en mémoire, lisibles jusqu'à un redémarrage, et un fsync ultérieur réussit sans les écrire (Rebello et al.
  2020). Cepheus ne s'y fie jamais (G13). [garanties](guarantees.md#les-pannes)
- **falsifiable hypothesis** (une hypothèse réfutable) — une affirmation énoncée de façon qu'une expérience puisse
  montrer qu'elle est fausse ; une affirmation qu'aucun résultat ne pourrait contredire ne dit rien.
  [cas](case-seats.md#3-une-hypothèse-quon-peut-réfuter-et-sa-cause)
- **fiber** — un des threads légers de Cesia (un green thread, comme les goroutines de Go) : beaucoup se relaient sur
  un seul cœur, chacun avec sa propre pile, et celui qui attend (une réponse du serveur) laisse tourner les autres.
  Tous les fibers d'un programme partagent l'unique connexion de sa base.
  [Cesia](cesia.md#beaucoup-de-fibers-une-seule-connexion)
- **file descriptor**, **descriptor passing** (`SCM_RIGHTS`) — un descriptor est le numéro qu'un processus donne à un
  fichier ouvert ; un socket Unix-domain (un canal de communication local entre processus) peut porter des descriptors
  vers un autre processus, qui reçoit ses propres descriptors des mêmes fichiers ouverts (unix(7)). Le serveur passe
  ainsi à un lecteur local ses fichiers de runs et sa page de visibilité : le lecteur n'a besoin d'aucune permission sur
  le répertoire des données. [serveur](server.md#lectures-locales-g15)
- **fixpoint** (least ; le plus petit point fixe) — un ensemble de faits que l'application des règles ne change pas ;
  le plus petit qui contient les faits affirmés est le least model.
  [règles](rules.md#ce-que-tient-la-base--le-least-model)
- **floor** — le plus petit numéro de série d'une session qui attend encore sa réponse, envoyé avec chaque écriture :
  les reçus en dessous sont oubliés. [serveur](server.md#écritures-appliquées-une-seule-fois-les-sessions-g14)
- **follow stream**, **follower** — un follow stream est la seconde connexion d'un lecteur local, sur laquelle le
  serveur envoie chaque frame que fait le writer, avant son fsync, et les runs de la base ; le follower est la copie de
  la base que le lecteur en tire, en appliquant chaque frame comme l'a fait le serveur.
  [serveur](server.md#lectures-locales-g15)
- **foreign key** (une clé étrangère) — en SQL, une colonne dont les valeurs doivent être les clés des lignes d'une
  autre table (`REFERENCES client`) ; dans Cepheus, un lien qui nomme un kind (`Link(to = "client")`) : chaque chose
  vers laquelle il pointe est de ce kind, vérifié à chaque écriture. [Cesia](cesia.md#les-kinds-et-les-valeurs-quils-tiennent)
- **fork** — une base temporaire qui part d'une vue : les mêmes écritures et les mêmes vérifications, rien sur le
  disque, rien à payer pour en faire un. [concepts](concepts.md#les-forks)
- **frame** — l'unité d'une écriture et d'un fsync dans le journal : un en-tête, les groupes, un trailer.
  [formats](formats.md#segment-de-journal-dirjournalfirst-group-20-digitsseg)
- **frame of reference** (FOR) — un bloc de nombres rangés sous la forme de leur plus petite valeur (la base) et, pour
  chacun, sa différence avec la base sur autant de bits qu'en demande la plus grande différence : des valeurs entre
  20 000 et 23 650 prennent 12 bits chacune, pas 64 (Goldstein et al. 1998 ; PFOR, sa forme patched, Zukowski et al.
  2006). [théorie](theory.md#11-runs-et-journal-compressés--le-codage-et-sa-borne)
- **frozen relation** (une relation figée) — une petite relation sur laquelle les règles ont été dépliées : tant que
  ses faits restent les mêmes, ce sont les règles dépliées qui tournent ; un groupe qui change l'un de ses faits fait
  tourner les règles telles qu'elles sont écrites. [règles](rules.md#la-spécialisation-par-petites-relations)
- **fsync** — l'appel système qui revient une fois que les octets d'un fichier sont sur le disque.
- **fuzzing**, **libFuzzer**, **sanitizer** — le fuzzing fait tourner une fonction sur des millions d'entrées qu'un
  programme modifie pour atteindre de nouveaux chemins dans le code, et s'arrête à la première qui échoue ; libFuzzer
  est le fuzzer de LLVM. Un sanitizer est une vérification que le compilateur ajoute à chaque accès à la mémoire
  (AddressSanitizer : une lecture ou une écriture hors de son bloc) ou à chaque opération que C laisse indéfinie
  (UndefinedBehaviorSanitizer). Les fichiers C du CRC et de TLS sont fuzzés avec les deux.
  [tester](testing.md#le-fichier-c-fuzzé)
- **galloping search** (exponential search) — une recherche qui essaie 1, 2, 4, 8... places plus loin avant de couper
  en deux, pour que trouver une place à $k$ pas coûte $O(\log k)$ (Bentley et Yao 1976) ; c'est ainsi que cherche le
  leapfrog. [théorie](theory.md#8-merges-écrits-dans-un-fichier)
- **gaps** — dans un row block, les choses d'une valeur rangées sous la forme de leur différence avec la chose d'avant
  (moins un) : « les factures impayées », proches les unes des autres, prennent 3-4 bits chacune au lieu de 9-10.
  [formats](formats.md#run-dirsnapshotslo-20-digits-hi-20-digitsrun)
- **Generic Join** — le worst-case optimal join qu'utilise Cepheus : une variable à la fois, le plus petit ensemble de
  candidats, chaque candidat vérifié contre les autres patterns (Ngo, Ré, Rudra 2013).
  [architecture](architecture.md#questions)
- **ghost queue** — la mémoire qu'a S3-FIFO des pages récemment évincées de sa petite file ; une page redemandée bientôt
  va directement dans la file principale.
- **group** (un groupe) — la transaction de Cepheus : une liste d'opérations appliquées tout ou rien, avec un numéro,
  qui, quand et pourquoi. [concepts](concepts.md#les-groupes--une-écriture-est-une-transaction)
- **group commit** — les écritures qui arrivent pendant qu'un fsync tourne partagent le suivant.
  [architecture](architecture.md#le-journal--un-write-ahead-log)
- **handover** (la passation) — l'arrêt propre d'un primary, qui envoie ses derniers groupes à sa replica et attend
  qu'elle les tienne : après lui, aucun groupe confirmé ne manque sur la replica. [serveur](server.md#la-promotion-à-la-main)
- **handshake** — les premiers round trips (allers-retours) d'une connexion TLS, où les deux côtés se mettent d'accord
  sur des clés et où le serveur montre son certificat : environ 4,8 ms de calcul ici, c'est pourquoi les connexions
  vivent longtemps. [serveur](server.md#tls)
- **hash table** (open addressing, linear probing ; une table de hachage) — une table de slots où une clé va au slot
  que nomme son hash, ou au premier slot libre après lui ; une recherche sonde à partir de ce slot jusqu'à trouver la
  clé ou un slot vide. Remplie au plus à moitié, environ 1,5 sonde pour une clé qui s'y trouve (Knuth, 6.4). Les textes
  de chaque run se trouvent par une telle table.
  [formats](formats.md#run-dirsnapshotslo-20-digits-hi-20-digitsrun)
- **head** (d'une règle ; la tête) — le pattern qu'elle donne pour chaque réponse de son corps, ou `Never`.
  [règles](rules.md#une-règle-est-une-question-avec-une-conclusion)
- **history** (l'historique) — la suite de toutes les transactions qu'une base a appliquées, avec ce que chacune a lu
  et écrit ; le journal de Cepheus en est une, dans l'ordre des groupes.
- **idle timeout** — le temps pendant lequel une connexion peut rester sans une requête entière avant que le serveur la
  ferme (`idle_timeout`, 600 s par défaut) ; avant son Hello, 10 s au plus, son handshake TLS compris.
  [serveur](server.md#clustertoml)
- **inequality join** (une jointure d'inégalité) — un join sur $<$ ou $\le$ entre deux variables plutôt que sur
  l'égalité : les factures payées après leur échéance. Lu dans des valeurs triées plutôt que comme un produit
  cartésien suivi d'un filtre (Khayyat et al. 2015) : `Less`. [Cesia](cesia.md#less-lessorequal-et-optional)
- **index word** — la forme sur 64 bits d'une valeur dans les index : la valeur elle-même, ou un numéro du dictionnaire
  pour les textes et les floats ; ce que donne `fold`, et que `decode` change de nouveau en valeur.
  [api](api.md#questions)
- **information bound** (entropy ; l'entropie) — le plus petit nombre de bits dont un codage quelconque a besoin pour
  des données, d'après le nombre de valeurs différentes qu'elles auraient pu prendre : un statut qui vaut "paid" 70 % du
  temps, "unpaid" 20 % et "late" 10 % demande 1,16 bit en moyenne, pas 2.
  [théorie](theory.md#11-runs-et-journal-compressés--le-codage-et-sa-borne)
- **instruction** (du processeur), **intrinsic** — une opération qu'exécute le processeur ; un intrinsic est une
  fonction C que le compilateur change en une instruction donnée (`_mm_crc32_u64` en `crc32` sur x86-64, `__crc32cd`
  en `crc32cx` sur arm64). Le compilateur d'OCaml n'en a pas pour celles-ci, d'où le fichier C.
  [architecture](architecture.md#le-journal--un-write-ahead-log)
- **I/O domain** — un des k domains OCaml sur lesquels le serveur répartit ses connexions, chacun avec son propre
  runtime lock, pour que k requêtes tournent en même temps. [serveur](server.md#ce-que-cest-et-pourquoi)
- **isolation** — ce qu'une transaction peut voir des autres qui tournent en même temps.
  [concepts](concepts.md#lisolation--exactement-ce-que-voient-un-lecteur-et-un-writer)
- **journal** — le write-ahead log de Cepheus : des segments faits de frames de groupes.
  [architecture](architecture.md#le-journal--un-write-ahead-log)
- **journal window** — les 4 MiB d'un segment que la recovery tient à la fois : une frame qui y tient est décodée là où
  elle se trouve, une plus longue est vérifiée par morceaux et lue en entier seulement pour la rejouer.
  [architecture](architecture.md#la-recovery--torn-writes-et-dommages)
- **kind** (client Cesia) — une sorte de chose dans un programme Cesia : un nom et des champs, chacun une propriété d'un
  type (`client/City` pour le champ `City` du kind `client`) ; `Insert` et `Get` écrivent et lisent les champs d'une
  chose pour un kind sous la forme d'une map. [Cesia](cesia.md#les-kinds-et-les-valeurs-quils-tiennent)
- **link that names a kind**, **of a kind** (un lien qui nomme un kind, d'un kind) — une propriété de lien avec un
  kind (`cepheus/to`) : ses valeurs sont des choses de ce kind. Une chose est d'un kind tant qu'elle a un fait d'une
  des propriétés du kind qu'une écriture a affirmé. [API](api.md#les-liens-qui-nomment-un-kind--les-foreign-keys)
- **LEFT JOIN** (left outer join) — le join de SQL qui garde chaque ligne de son côté gauche même quand le côté
  droit n'a rien pour elle, les colonnes du côté droit étant alors NULL ; l'`Optional` de Cepheus, dont la cellule est
  alors `missing`. [Cesia](cesia.md#less-lessorequal-et-optional)
- **leader**, **follower** — dans un cluster Raft, le seul serveur d'un term qui prend les écritures et sert les
  lectures, et les autres, qui stockent ses entrées et votent. [serveur](server.md#un-cluster-de-trois-raft)
- **lagging** (« en retard ») — la fin d'un watch dont le programme a pris trop de retard (8 MiB de pushes qu'il n'a
  pas pris, au serveur) : le package relance le watch depuis son dernier groupe.
  [serveur](server.md#les-questions-vivantes-watch)
- **large group** (un grand groupe) — un groupe de 20 000 opérations ou plus, toutes des ajouts : il prend un chemin
  plus rapide vers le même résultat (ses faits dans des Bigarrays, rangés et triés par plusieurs domains, fusionnés
  d'un coup en un run pendant que sa frame s'écrit à côté, par morceaux).
  [architecture](architecture.md#grands-groupes)
- **lazy leveling** — du tiering à chaque niveau sauf le dernier, qui est en leveling (Dayan et Idreos 2018).
  [théorie](theory.md#9-niveaux-sur-disque-et-grands-groupes)
- **leadership transfer** (passage de la direction) — l'arrêt propre du leader d'un cluster Raft : il abandonne son
  lease, attend que le follower le plus à jour tienne tout son log, et lui dit de se présenter aussitôt à l'élection
  (`Timeout_now`). [serveur](server.md#larrêt-propre-du-leader--la-direction-passée)
- **leapfrog** (leapfrog intersection) — l'intersection de listes triées par des sauts : les listes dans l'ordre de
  leurs clés courantes, chacune saute à son tour jusqu'à la première clé au moins égale à la plus grande (par
  galloping), et une clé que toutes atteignent est dans chaque liste (Veldhuizen 2014). Un niveau d'une question
  intersecte ainsi ses slices au lieu de chercher chaque candidat. [théorie](theory.md)
- **lease** — une permission qui prend fin d'elle-même après un temps, sauf si elle est renouvelée (Gray et Cheriton
  1989). La conception en proposait un pour les lectures locales ; il a été laissé au profit du numéro de visibilité,
  qui n'a besoin d'aucune horloge (entre machines, le leader d'un cluster Raft sert ses lectures sous un lease).
  [serveur](server.md#les-règles-quavait-dabord-la-conception-et-pourquoi-elles-ont-été-laissées)
- **least model** — le plus petit ensemble de faits qui contient les faits affirmés et qui est clos par les règles : ce
  que contient une base avec des règles (G17). [règles](rules.md#ce-que-tient-la-base--le-least-model)
- **level**, **size ratio** — un niveau : une place pour des runs avec une capacité dans un LSM-tree ; chaque niveau
  est $T$ fois plus grand que celui du dessus ($T$, le size ratio, vaut 4 ici) : le niveau $l$ contient au plus
  $200\,000 \times 4^l$ lignes. [architecture](architecture.md#les-merges--un-log-structured-merge-tree-à-leveling)
- **leveling**, **tiering** — les deux façons dont un LSM-tree de plusieurs niveaux fait ses merges : en leveling,
  chaque niveau contient un seul run, et un run qui descend est fusionné avec lui (Cepheus) ; en tiering, un niveau
  contient jusqu'à T runs, fusionnés ensemble dans le niveau suivant quand il est plein. Le leveling écrit plus et lit
  moins de runs. [théorie](theory.md#9-niveaux-sur-disque-et-grands-groupes)
- **linearizability** — chaque opération semble prendre effet à un seul instant entre son appel et son retour
  (Herlihy et Wing 1990) ; un groupe, en tant qu'écriture sur un seul objet, est linearizable.
- **live question** (une question vivante), **watch** (un watch) — une question tenue à jour : sa réponse, puis le
  changement de ses lignes à chaque groupe durable qui les change (`cepheus.Watch`).
  [Cepheus depuis Cesia](cesia.md#watch--les-questions-vivantes), [G21](guarantees.md#g21-les-questions-vivantes)
- **local read** (une lecture locale) — une lecture qu'un programme fait dans sa propre mémoire, sur la machine du
  serveur, à partir de la base qu'il suit : aucun round trip, linearizable (G15).
  [serveur](server.md#lectures-locales-g15)
- **loopback** — l'adresse réseau de la machine elle-même (127.0.0.1, ::1) : du TCP qui ne quitte jamais la machine.
  [serveur](server.md#ce-que-cest-et-pourquoi)
- **lost update** — deux read-then-writes lisent la même valeur et écrivent tous les deux, donc un changement est
  perdu ; Cepheus ne l'empêche que quand la lecture est énoncée avec `Expect`.
- **LSM-tree** (log-structured merge-tree) — les écritures récentes dans une petite structure en mémoire, fusionnées
  en masse dans des structures triées sur le disque (O'Neil et al. 1996).
  [architecture](architecture.md#les-merges--un-log-structured-merge-tree-à-leveling)
- **materialisation** (la matérialisation) — garder les faits dérivés stockés et à jour, pour que les questions les
  lisent comme des faits ; l'autre façon est de raisonner au moment de la question (query rewriting, magic sets).
  [règles](rules.md)
- **materialize the conflict** — protéger un ensemble contre les phantoms en gardant un fait que chaque programme qui
  écrit dans l'ensemble attend et change (Fekete et al. 2005).
- **memory BIO** — un buffer d'OpenSSL en mémoire qui tient lieu de réseau : OpenSSL lit les octets qu'on lui donne et
  y écrit les octets à envoyer, sans jamais toucher au socket, donc il n'attend jamais. [serveur](server.md#tls)
- **merge** — la fusion du delta et des runs les plus récents en un seul nouveau fichier de run ; il tourne en
  arrière-plan et il est atomique (G12) ; `snapshot` est le merge complet, de tous les runs.
  [architecture](architecture.md#les-merges--un-log-structured-merge-tree-à-leveling)
- **model checking** — visiter chaque état atteignable d'un modèle borné et vérifier des invariants dans chacun ; TLC
  le fait pour TLA+. [tester](testing.md#model-checking)
- **missing** (une cellule absente) — la cellule d'une ligne où un `Optional` n'a pas trouvé de valeur : `missing` en
  Cesia, `Value.missing` en OCaml, rangée après toute valeur dans les deux sens. [Cesia](cesia.md#less-lessorequal-et-optional)
- **monotone sequence** (une suite monotone) — des nombres qui ne décroissent jamais (des offsets), rangés par blocs de
  128 sous forme de frame of reference avec l'en-tête de chaque bloc à part, pour que l'entrée q soit un en-tête et un
  champ. [formats](formats.md#run-dirsnapshotslo-20-digits-hi-20-digitsrun)
- **monotonic writes** — une session guarantee (une garantie donnée à une session ; Terry et al. 1994) : les écritures
  d'un programme sont appliquées dans l'ordre où il les a envoyées.
  [serveur](server.md#lordre-le-pipelining-et-la-back-pressure)
- **mutual TLS** — du TLS où les deux côtés montrent un certificat de la même CA ; entre serveurs Cepheus (un primary et
  ses replicas, sur le port des peers), pas pour les programmes, qui montrent un token. [serveur](server.md#tls)
- **native package** (un package natif) — un package Cesia dont les fonctions sont, sous leur code Cesia, un moteur en
  OCaml compilé une fois : la façon dont Cesia fait tourner de l'OCaml qui vient d'un autre projet ; en faire tourner un
  demande la permission `native=LABEL`, une confiance totale, comme `ffi=` pour le C. [Cesia](cesia.md#le-package)
- **net** (run ; un run net) — un run n'ajoute que des faits absents en dessous de lui et ne retire que des faits
  présents en dessous de lui, donc chaque compte d'une vue est une somme de comptes exacts.
  [architecture](architecture.md#les-index--les-runs-et-le-delta)
- **no-op** (Raft) — la première entrée d'un nouveau leader, vide, de son propre term : quand elle est committed,
  toutes les entrées d'avant le sont aussi. [serveur](server.md#les-élections)
- **optimistic concurrency control** — lire sans locks, et vérifier à la fin que ce qui a été lu est toujours vrai
  (Kung et Robinson 1981) : `Expect`.
- **Optional** — un pattern d'une question qui peut n'avoir aucun fait : l'`OPTIONAL` de SPARQL et le `LEFT JOIN` de
  SQL sur une propriété. [Cesia](cesia.md#less-lessorequal-et-optional)
- **OWL 2 RL** — la partie d'OWL 2, le langage d'ontologies du W3C (une ontologie : les classes et les propriétés
  d'un domaine, et leurs axiomes), que des règles calculent entièrement : 78 règles en six tables (OWL 2 Profiles,
  section 4.3) ; dans Cepheus, une bibliothèque de règles, `Cepheus.Owl`. [règles](rules.md#owl-2-rl-une-bibliothèque-de-règles)
- **origin** — le nom du token, la session, le numéro de série et le floor qu'un groupe écrit à travers le serveur porte
  dans son `why` : quel programme l'a écrit, et comment une écriture renvoyée est reconnue.
  [serveur](server.md#écritures-appliquées-une-seule-fois-les-sessions-g14)
- **page** — 16 KiB d'un fichier de run, l'unité du cache, vérifiée par son CRC chaque fois qu'elle est lue sur le
  disque.
- **page cache** (celui du noyau) — la copie en mémoire des fichiers que garde le système d'exploitation ; ce qu'un
  crash du processus garde et qu'une coupure de courant perd.
- **page table** (d'un run ; la table des pages) — à la fin du fichier d'un run, pour chaque page de la disposition du
  run, la page du fichier qui la contient et son CRC : un run est disposé d'après des bornes supérieures, et seules les
  pages qui contiennent des octets sont écrites. [formats](formats.md#run-dirsnapshotslo-20-digits-hi-20-digitsrun)
- **part** (d'un run ; une partie) — un run en a deux : les faits qu'il ajoute (la partie a) et les faits des runs en
  dessous de lui qu'il retire (la partie t). [architecture](architecture.md#les-index--les-runs-et-le-delta)
- **PAX** (Partition Attributes Across) — une disposition de page qui garde ensemble, à l'intérieur de chaque page, les
  valeurs de chaque attribut (Ailamaki et al. 2001) : des colonnes à l'intérieur d'une page. Mesurée pour les thing
  blocks et mise de côté : chercher une chose touchait une cache line (le bloc de 64 octets que le processeur lit d'un
  coup) par propriété ; un bloc garde un record par chose pour ses propriétés à une valeur.
  [théorie](theory.md#11-runs-et-journal-compressés--le-codage-et-sa-borne)
- **persistent data structure** — une structure qui n'est jamais changée sur place : un changement fait une nouvelle
  version et l'ancienne reste valide. [architecture](architecture.md#les-index--les-runs-et-le-delta)
- **phantom** — un nouveau membre d'un ensemble lu plus tôt (les faits qui correspondent à un pattern), que ne voit pas
  une vérification de faits isolés.
- **piece** (morceau d'une frame) — dans un cluster Raft, une entrée qui porte un MiB d'une frame plus longue ; la
  frame est appliquée en entier à son dernier morceau, sur chaque serveur, ou jamais.
  [serveur](server.md#un-seul-log-pour-le-cluster)
- **pipelining** — envoyer des requêtes sans attendre les réponses des précédentes : les round trips se recouvrent, et
  beaucoup de réponses reviennent en un seul appel système.
  [serveur](server.md#lordre-le-pipelining-et-la-back-pressure)
- **plan** (d'une règle) — la règle compilée en closures (des fonctions qui gardent les valeurs qu'elles utilisent)
  avec un atome mis en correspondance avec un fait donné, les autres joints dans un ordre choisi d'après les comptes du
  stockage. [règles](rules.md#comment-le-writer-la-tient-à-jour--la-semi-naive-evaluation)
- **population count** (popcount) — le nombre de bits à 1 dans un mot ; une recherche dans une rank table en fait un.
- **pre-vote** — la question qu'un serveur Raft pose aux autres avant de se présenter à une élection : voteriez-vous
  pour moi ? Il n'augmente son term qu'avec une majorité de oui, si bien qu'un serveur coupé puis revenu ne perturbe
  pas le cluster (thèse d'Ongaro, 9.6). [serveur](server.md#les-élections)
- **primary** (le primary) — le serveur qui prend les écritures d'une base ; ses replicas copient ses groupes.
  [serveur](server.md#une-replica)
- **promotion** (la promotion) — une replica dont on fait un primary (`cepheus promote`) : une nouvelle epoch, et les
  écritures acceptées. [serveur](server.md#la-promotion-à-la-main)
- **proof** (une preuve) — un arbre dont les feuilles sont des faits affirmés et dont les nœuds sont des instances de
  règles, les enfants de chaque nœud étant les faits de son corps ; *well-founded* (bien fondée) : chaque enfant prouvé
  avant son parent. `why` en renvoie une (G20). [règles](rules.md#why)
- **property** (une propriété) — l'attribut d'un fait ; elle-même une chose (de 16 à 65 535) avec un nom, un type et
  deux indicateurs.
- **provenance** — l'origine d'un fait : ici, une preuve de ce fait. [règles](rules.md#why)
- **question** — la query (la requête) de Cepheus : des patterns sur des variables.
  [concepts](concepts.md#les-questions)
- **question timeout** — le temps qu'une question peut prendre avant de finir avec le code `timeout` : le
  `question_timeout` du serveur (30 s par défaut), ou le `timeout` plus court d'un programme.
  [serveur](server.md#clustertoml)
- **radix sort** (least significant digit first) — un tri qui trie selon le chiffre le plus bas, puis le suivant,
  chaque passe étant un counting sort stable, pour que l'ordre des chiffres plus bas soit gardé :
  $O(n \times \text{chiffres})$. Les valeurs d'un grand groupe à l'intérieur d'une propriété sont triées avec des
  chiffres de 11 bits (Knuth, vol. 3, 5.2.5), chaque passe d'un buffer à l'autre, et ses index par chose aussi quand il
  n'arrive pas dans l'ordre des choses. [théorie](theory.md#9-niveaux-sur-disque-et-grands-groupes)
- **range restriction** (safety) — chaque variable de la tête d'une règle apparaît dans son corps : une règle ne donne
  de faits que sur ce que contient la base, et le least model est fini.
  [règles](rules.md#une-règle-est-une-question-avec-une-conclusion)
- **rank table** (rank directory) — un bit pour chaque numéro de chose et, tous les 32 bits, combien de bits sont à 1
  avant eux : « la chose e est-elle là, et à quel slot ? », c'est un mot et un popcount (Jacobson 1989). Chaque partie
  d'un run en a une. [théorie](theory.md#3-index)
- **read amplification** — combien de runs une lecture doit visiter : un par niveau en leveling, au plus 3 à 10 M de
  faits. [architecture](architecture.md#les-merges--un-log-structured-merge-tree-à-leveling)
- **read your writes** — une session guarantee (Terry et al. 1994) : une lecture envoyée après l'arrivée du reçu d'une
  écriture voit cette écriture. [serveur](server.md#lordre-le-pipelining-et-la-back-pressure)
- **read-then-write** — une transaction d'un client qui lit une vue, puis écrit un groupe ; validée par ses `Expect`.
- **recovery** — ce que fait une ouverture après un crash : la chaîne de runs la plus récente qui passe la
  vérification, puis le journal qui la suit, dont elle écrit d'abord de nouveau la frame la plus récente.
  [exploitation](operations.md#louverture-et-la-recovery)
- **recursive rule** (une règle récursive) — une règle dont la propriété de la tête est lue par son propre corps,
  directement ou à travers d'autres règles : « chaque ancêtre », à n'importe quelle profondeur.
  [règles](rules.md#une-règle-est-une-question-avec-une-conclusion)
- **redo log** — un log de changements à appliquer de nouveau après un crash, jamais à défaire ; le journal en est un.
- **replay** — appliquer les groupes du journal dans l'ordre pour reconstruire un état.
- **Raft** — l'algorithme de consensus (la façon dont plusieurs serveurs s'accordent sur une même suite d'écritures)
  que fait tourner un cluster de trois serveurs ou plus (Ongaro et Ousterhout 2014) : un leader par term, élu par une
  majorité ; une écriture est confirmée dès qu'une majorité la tient forcée. [serveur](server.md#un-cluster-de-trois-raft)
- **Raft log** (le log) — le log unique d'un cluster : chaque entrée est une frame du journal d'une base, entière, ou
  le no-op d'un leader, avec son index et son term ; `DATA/raft/`. [formats](formats.md#les-fichiers-du-serveur)
- **replica** (une replica) — un serveur sur une autre machine qui garde une copie de chaque base de son primary,
  groupe pour groupe, dans son propre journal ; asynchrone : elle est en retard de son lag, et le primary ne l'attend
  jamais. [serveur](server.md#une-replica)
- **replica lag** (le lag d'une replica) — le temps qui va d'un groupe durable sur le primary au moment où la replica
  dit qu'elle le tient de façon durable. [serveur](server.md#ce-que-coûte-une-replica)
- **representative** (le représentant) — le membre d'une classe de choses égales qui tient les faits de la classe ;
  les lectures et les questions désignent une chose par son représentant.
  [règles](rules.md#légalité--des-classes-de-choses-égales)
- **retry** — exécuter de nouveau une transaction après que la base l'a refusée (un `Conflict` dans Cepheus, une
  serialization failure dans PostgreSQL), à partir d'une nouvelle lecture.
- **rewriting** (de l'égalité ; la réécriture) — garder les faits d'une classe de choses égales sur son représentant,
  au lieu de copier chaque fait sur chaque membre comme le feraient les règles de l'égalité d'OWL (Motik et al., AAAI
  2015). [règles](rules.md#légalité--des-classes-de-choses-égales)
- **rewrite of the newest frame** (la réécriture de la frame la plus récente) — à une recovery après autre chose qu'une
  fermeture propre, la frame la plus récente du journal est écrite de nouveau avant d'être forcée, pour que les pages
  qu'un fsync échoué a marquées clean redeviennent dirty et soient vraiment écrites (G13).
  [garanties](guarantees.md#g13-on-ne-se-fie-jamais-à-un-fsync-qui-a-échoué)
- **right** (un droit) — ce qu'un token peut faire sur une base : `read` (Open, Get, Find) ou `write` (et Write) ;
  `admin` : les opérations du serveur. [serveur](server.md#les-droits-g16)
- **right per kind** (un droit par kind) — un droit d'un token sur une base qui nomme des kinds : ne lire que les faits
  de certains kinds, et n'ajouter qu'à certains (`{ read = ["client", "invoice"], add = ["invoice"] }`) ; le kind
  d'une propriété est son nom jusqu'à son premier `/`. Un tel token lit au serveur, jamais dans sa propre mémoire.
  [serveur](server.md#les-droits-g16)
- **round** (du commit buffer ; une tournée) — les frames de toutes les bases arrivées pendant que le round précédent
  était forcé, écrites comme un seul enregistrement du buffer et forcées par un seul fsync ; chaque frame est
  confirmée après lui. Un seul round est en vol à la fois. [le serveur](server.md#plusieurs-bases-un-seul-fsync--le-commit-buffer)
- **round trip** — une requête et sa réponse : le temps entre l'envoi de l'une et la réception de l'autre, dont la plus
  grande part est le travail du noyau (les appels système, le réveil de l'autre processus).
  [serveur](server.md#la-vitesse-à-côté-de-postgresql)
- **row store**, **column store** — un row store garde ensemble les champs de chaque enregistrement (chercher un
  enregistrement lit un seul endroit), un column store les valeurs de chaque champ (parcourir un champ lit un seul
  endroit). Un run est les deux : par chose, un record par chose pour ses propriétés à une valeur (avec de petites
  colonnes pour les autres), par propriété, une colonne de chaque propriété.
  [théorie](theory.md#11-runs-et-journal-compressés--le-codage-et-sa-borne)
- **rule** (une règle) — les patterns d'une question et une tête : chaque fois que les patterns sont des faits pour
  certaines valeurs, la tête est un fait pour les mêmes valeurs. Une chose du schéma (`cepheus/name`, `cepheus/rule`).
  [règles](rules.md)
- **run**, **run file** — une structure triée du LSM-tree sur le disque : les changements d'un intervalle de groupes
  par-dessus les runs en dessous de lui, dans un fichier `DIR/snapshots/<lo>-<hi>.run`.
  [architecture](architecture.md#les-runs-sur-disque)
- **S3-FIFO** — la politique d'éviction du cache : trois files FIFO (small, main, ghost), rien n'est déplacé sur un hit
  (quand la page est déjà dans le cache ; Yang et al. 2023). [architecture](architecture.md#les-pages-et-le-cache)
- **same** (« le même ») — la réponse du serveur à un watch repris `from` un groupe quand rien de ce que lit la
  question n'a changé depuis : les lignes du programme sont toujours justes, et rien n'est envoyé.
- **schedule** (un ordonnancement) — un ordre dans lequel s'entrelacent les pas de transactions concurrentes.
  [cas](case-seats.md#correction-sur-des-entrées-générées)
- **schema** (le schéma) — les propriétés et leurs types ; dans Cepheus, des faits comme le reste.
  [concepts](concepts.md#les-propriétés-et-le-schéma)
- **segment** — un fichier du journal, jusqu'à 64 MiB, nommé par son premier groupe.
- **semi-naive evaluation** — évaluer les règles seulement sur ce qui a changé : chaque tour met en correspondance les
  faits nouveaux du tour d'avant, donc chaque instance de règle est trouvée une fois (Bancilhon, Ramakrishnan 1986).
  [règles](rules.md#comment-le-writer-la-tient-à-jour--la-semi-naive-evaluation)
- **serial** (le numéro de série) — le numéro que la bibliothèque d'un programme donne à chaque écriture de sa
  session : 1, 2, 3... Un numéro de série envoyé deux fois est appliqué une fois (G14).
  [serveur](server.md#écritures-appliquées-une-seule-fois-les-sessions-g14)
- **serializable** — le résultat est celui d'une exécution des transactions une par une, dans un certain ordre.
- **serializable snapshot isolation** (SSI) — le SERIALIZABLE de PostgreSQL : la snapshot isolation plus une
  vérification des conflits lecture-écriture entre transactions, qui en annule une quand deux d'entre elles se suivent
  ainsi (Cahill, Röhm et Fekete 2008 ; Ports et Grittner 2012).
- **server** (le serveur) — le processus qui possède les fichiers des bases et répond aux requêtes des programmes sur
  des sockets : `cepheus serve`. [serveur](server.md)
- **serveur frais** (fresh server) — dans un cluster Raft, un serveur qui a démarré sans état Raft (celui d'un nouveau
  cluster, ou un serveur dont le répertoire de données a été perdu) : il ne participe à rien tant que ⌊n/2⌋ + 1 autres
  serveurs ne lui ont pas dit leurs terms et leurs logs. [serveur](server.md#un-serveur-démarré-sur-un-répertoire-de-données-vide)
- **session** — un numéro que le serveur donne à une connexion (Welcome) et que la bibliothèque du programme garde
  d'une reconnexion à l'autre ; ses écritures y sont numérotées.
  [serveur](server.md#écritures-appliquées-une-seule-fois-les-sessions-g14)
- **session table** (la table des sessions) — pour chaque base et chaque session, les reçus des numéros de série égaux
  ou supérieurs au floor ; enregistrée dans `DATA/NAME/sessions` et reconstruite au démarrage à partir de ce fichier et
  du journal. [serveur](server.md#écritures-appliquées-une-seule-fois-les-sessions-g14)
- **shared mapping** (`mmap`, `MAP_SHARED`) — les pages d'un fichier placées dans la mémoire d'un processus de façon
  que chaque processus qui les mappe voie une seule copie physique : ce qu'écrit l'un est vu aussitôt par les autres.
  La page de visibilité est mappée ainsi, en lecture-écriture par le serveur et en lecture seule par les lecteurs.
  [serveur](server.md#lectures-locales-g15)
- **single writer** (un seul writer) — un seul thread writer applique chaque groupe d'une base, dans l'ordre.
  [architecture](architecture.md#un-seul-writer-threads-et-domains)
- **sink** (un puits) — une règle dont aucune règle ne lit les faits : aucun pattern d'aucune règle ne peut correspondre à
  sa tête. Ses faits ne déclenchent rien, donc un changement en fait des faits par un seul tri à la fin de son
  raisonnement, plutôt qu'un par un dans son working set.
  [règles](rules.md#les-changements-des-règles-en-arrière-plan)
- **slice** — les candidats qu'un pattern offre à une variable quand son autre côté est connu : les valeurs d'une
  propriété pour une chose, ou les choses qui ont une valeur. Dans un run, c'est une suite de lignes, triée : deux
  d'entre elles à un même niveau sont intersectées par leapfrog. [théorie](theory.md)
- **snapshot** (l'opération) — `Cepheus.snapshot`, le merge complet : le delta et tous les runs en un seul run, pour
  que l'ouverture suivante ne rejoue rien. Le fichier des versions antérieures (format 4 et avant, `<group>.snap`)
  contenait toute la base ; un fichier de run l'a remplacé. [api](api.md#opérations)
- **snapshot** (l'état), **view** (une vue) — l'état exact après un groupe. [concepts](concepts.md#les-vues)
- **snapshot isolation** — chaque transaction lit l'état à son début, et échoue si une autre a écrit la même donnée
  entre-temps (first committer wins, le premier qui valide gagne) ; elle laisse passer le write skew.
- **SNI** (Server Name Indication) — le nom du serveur, envoyé par le client au début d'un handshake TLS.
  [serveur](server.md#tls)
- **socket** — un canal du noyau entre deux processus, qu'on écrit et qu'on lit comme un fichier.
  [serveur](server.md#ce-que-cest-et-pourquoi)
- **space amplification** — l'espace disque utilisé divisé par la taille des données : la chaîne seule après un merge
  (1, puisque les runs sont nets), et pendant un merge complet une nouvelle copie de la base à côté de l'ancienne (2).
  [architecture](architecture.md#les-merges--un-log-structured-merge-tree-à-leveling)
- **split brain** — deux serveurs qui prennent en même temps les écritures d'une même base, chacun ignorant l'autre ;
  ce qu'une promotion à la main peut empêcher et ce qu'elle ne peut pas empêcher : [serveur](server.md#la-promotion-à-la-main)
- **SSE4.2**, **x86-64-v2** — SSE4.2 est un ensemble d'instructions des processeurs x86-64 (Intel depuis Nehalem,
  2008 ; AMD depuis Bulldozer, 2011), dont `crc32`, qui calcule CRC-32C 8 octets à la fois ; un programme voit si le
  processeur l'a au bit 20 d'un registre que remplit l'instruction `cpuid`. x86-64-v2 est le niveau de x86-64 qui
  l'inclut, avec CMPXCHG16B, LAHF-SAHF, POPCNT, SSE3, SSSE3 et SSE4.1 (la table "Micro-Architecture Levels" du psABI
  x86-64). Cepheus n'exige que SSE4.2. [limites](limits.md#les-fichiers-et-la-plateforme)
- **stable sort** (un tri stable) — un tri qui garde les clés égales dans l'ordre où elles sont venues : trier par
  valeur les faits d'un grand groupe, à partir d'un ordre par chose, laisse les faits d'une même valeur dans l'ordre
  des choses, qui est l'ordre (propriété, valeur, chose) dont un run a besoin.
  [architecture](architecture.md#grands-groupes)
- **strict serializability** — serializable dans un ordre qui respecte le temps réel.
  [garanties](guarantees.md#g4-strict-serializability)
- **strong component** (une composante fortement connexe) — un plus grand ensemble de choses qui s'atteignent toutes
  les unes les autres par les arêtes d'un graphe ; chaque membre d'une composante atteint les mêmes choses. On les
  trouve par l'algorithme de Tarjan (1972). [règles](rules.md#les-transitive-closures--le-closure-module)
- **structural sharing** — une nouvelle version d'une structure persistante partage avec l'ancienne chaque partie non
  touchée.
- **subjectAltName** — le champ d'un certificat qui liste les noms (DNS) et les adresses (IP) pour lesquels il est
  valable ; un client vérifie avec lui l'hôte auquel il s'est connecté. [serveur](server.md#tls)
- **syncer** — le thread qui écrit et force les frames, à côté du writer.
- **system property** (une propriété système) — `cepheus/name`, `cepheus/type`, `cepheus/many`, `cepheus/unique` (de
  1 à 4).
- **template** (un template) — (1) les questions qui ne diffèrent que par leurs constantes (les factures impayées de
  chaque client), gardées comme une seule dont les constantes sont des paramètres : le changement d'un fait se calcule
  une fois et ses lignes sont routées par les valeurs des paramètres. (2) Une règle avec un pattern de liste
  `[c, every L, m]`, écrite une fois pour chaque membre de la liste L de c quand on la déplie (cls-int1 d'OWL 2 RL sur
  une intersection). [règles](rules.md#templates--des-règles-sur-des-listes)
- **term** (Raft ; le term) — le numéro d'une élection ; il augmente à chacune, et un term a au plus un leader. Un
  serveur force son term et son vote avant de répondre. [serveur](server.md#les-élections)
- **thing** (une chose) — l'entité d'un fait : un numéro, à partir de 65 536.
  [concepts](concepts.md#les-faits--le-modèle-entityattributevalue)
- **threat to validity** (une menace sur la validité) — une façon dont la preuve ou la mesure pourrait être fausse, à
  nommer et à écarter. [cas](case-seats.md#menaces-sur-la-validité)
- **TLA+**, **TLC** — un langage qui décrit les pas d'un système en mathématiques (Lamport), et son model checker.
  [tester](testing.md#model-checking)
- **TLS** (Transport Layer Security) — le protocole qui chiffre une connexion TCP et prouve l'identité du serveur par
  son certificat ; la version 1.3 (RFC 8446) seulement. [serveur](server.md#tls)
- **token** — le secret qu'un programme montre au serveur pour prouver qui il est : `cph_` et 43 caractères, fait par
  `cepheus token add`, montré une seule fois. [serveur](server.md#les-tokens)
- **torn write** — une écriture que le disque faisait quand le courant a été coupé, dont une partie seulement est
  arrivée ; la recovery la coupe.
- **totalOrder** — l'ordre que IEEE 754 (2019, section 5.10) donne à chaque float, $-0$ avant $+0$ et NaN après
  $+\infty$ : l'ordre de `Sort`, des intervalles et de `Less` sur des floats. [Cesia](cesia.md#sort-limit-et-after--des-pages)
- **trailer** — les 16 derniers octets d'une frame, qui répètent sa longueur et ses CRC : un signe que la frame a été
  écrite entière.
- **transaction** — une unité de travail appliquée entièrement ou pas du tout ; le groupe de Cepheus.
- **transitive property** (une propriété transitive) — une propriété qui relie une chose à tout ce qu'elle atteint :
  une partie d'une partie est une partie. Tenue par le closure module. [règles](rules.md#les-transitive-closures--le-closure-module)
- **unfolding** (le dépliage ; specialisation by small relations, partial evaluation) — une règle réécrite en une
  règle par fait d'une petite relation de son corps, les mots de ce fait (ses constantes) à la place de ses
  variables : ce que le moteur fait tourner pour les règles écrites sur l'ontologie.
  [règles](rules.md#la-spécialisation-par-petites-relations)
- **unique** — une propriété dont aucune valeur n'est partagée par deux choses, vérifiée après chaque groupe.
- **Unix-domain socket** — un socket entre deux processus d'une même machine, nommé par un chemin dans le système de
  fichiers (`.s.cepheus.7400`) ; il ne peut pas aller d'une machine à une autre.
  [serveur](server.md#ce-que-cest-et-pourquoi)
- **value** (une valeur) — la troisième partie d'un fait, atomique et typée.
- **value index** — dans l'ordre par propriété d'un run, une rank table sur les valeurs que prend une propriété et la
  première ligne de chacune : les lignes de « city = Lyon » ou de « client = #c » en un rank et deux offsets, quel que
  soit le nombre de lignes. Gardé pour une propriété quand elle prend au plus 2 octets par ligne (des liens, des
  textes, des dates, de petits entiers). [formats](formats.md#run-dirsnapshotslo-20-digits-hi-20-digitsrun)
- **variable** — une inconnue d'une question, numérotée à partir de 0.
- **variable property** (une propriété variable) — un pattern de règle dont la propriété est une variable
  (`prop_var k`), liée par un autre pattern du corps : la forme des règles d'OWL 2 RL chez le W3C.
  [règles](rules.md#une-propriété-comme-variable--la-forme-des-règles-dowl-du-w3c)
- **varint** (LEB128), **zigzag** — un nombre entier en morceaux de 7 bits, les petits étant courts ; zigzag fait
  correspondre les nombres signés aux non signés (0, -1, 1, -2 → 0, 1, 2, 3). [formats](formats.md#un-groupe)
- **visibility number**, **visibility page** (le numéro de visibilité, la page de visibilité) — le numéro, dans les
  8 premiers octets d'une page de mémoire (`/dev/shm/cepheus-ID.visible`), sous lequel l'état durable le plus récent
  est visible : le serveur l'écrit après chaque fsync, avant de répondre aux programmes qui ont écrit ; une lecture
  locale le charge et sert l'état tenu sous lui. Une seule écriture en mémoire rend un groupe visible à tous les
  lecteurs au même instant. [serveur](server.md#lectures-locales-g15)
- **window** (la fenêtre, d'un watch) — les lignes que tient un watch avec `Sort` et `Limit` : les k premières lignes
  de `Find` dans son ordre et les copies de la k-ième, tenues par les lignes de chaque frame comparées à sa dernière
  ligne, et remplies à nouveau par un `Find` d'une page après cette ligne quand une ligne en part ([Sort et Limit dans
  un watch](cesia.md#sort-et-limit-dans-un-watch)).
- **working set** — les tableaux du reasoner pour un groupe : les faits qu'il a touchés, leurs états, leurs tours et
  leurs marques, dans des tables en open addressing avec des chaînes par (propriété, chose) et (propriété, valeur), hors
  de la vue du collector. [règles](rules.md#grands-groupes)
- **working view** — l'état du writer avec chaque groupe résolu, durable ou non ; les lecteurs ne le voient jamais.
- **worst-case optimal join** — un join dont le travail ne dépasse jamais, à de petits facteurs près, la plus grande
  réponse que la question pourrait avoir (l'AGM bound) (Ngo et al. 2012).
- **write amplification** — combien de fois un fait est écrit sur le disque par les merges pour une écriture d'un
  client : environ $(T + 1)/2$ par niveau en leveling, 5,8 pour le chargement de 10 M de faits (14,5 avec l'unique
  niveau des versions antérieures). [architecture](architecture.md#les-merges--un-log-structured-merge-tree-à-leveling)
- **write skew** — deux transactions lisent les mêmes faits et chacune en écrit un différent, ce qui ensemble brise une
  règle (deux médecins quittent chacun la garde) ; la snapshot isolation le permet, `Expect` le refuse.
  [concepts](concepts.md#lisolation--exactement-ce-que-voient-un-lecteur-et-un-writer)
- **write-ahead log** (WAL) — un fichier où chaque changement est rendu durable avant de compter, pour qu'un crash ne
  perde rien de confirmé. [architecture](architecture.md#le-journal--un-write-ahead-log)
- **writer** — le thread qui résout les groupes sur la working view, l'unique writer d'une base.
- **zigzag** — un codage des entiers signés en entiers non signés (0, -1, 1, -2... en 0, 1, 2, 3...), pour que les
  petits négatifs restent courts sous forme de varints. [serveur](server.md#le-framing)
