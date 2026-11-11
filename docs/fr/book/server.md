# Le serveur

Cepheus tourne comme un serveur, comme le fait PostgreSQL : un seul processus sur une machine tient ses bases de
données, et les programmes s'y connectent. Cette page en dit tout : ce qu'est le serveur et pourquoi il est construit
ainsi, comment le faire tourner (`cluster.toml`, les tokens, c'est-à-dire les secrets que les programmes présentent
pour prouver leurs droits, les commandes, le démarrage, l'arrêt, le crash), le wire protocol (le format exact des
octets échangés sur une connexion) octet par octet, les lectures dans la mémoire même d'un programme sur la machine du
serveur, la sécurité, les trois garanties que le serveur ajoute (G14, G15 et G16), et sa vitesse à côté de PostgreSQL
18.6, serveur contre serveur, sur une même machine.

Les termes sont expliqués à leur première apparition et dans le [glossaire](glossary.md). Le moteur à l'intérieur du
serveur est celui que décrivent les autres pages ([architecture](architecture.md)) ; ses garanties G1 à G13 tiennent à
travers le serveur ([garanties](guarantees.md)).

## Ce que c'est, et pourquoi

Un **serveur**, ici, est un processus qui tourne longtemps, qui possède les fichiers des bases et qui répond aux
requêtes envoyées sur un **socket** (un canal du noyau, le cœur du système d'exploitation, entre deux processus :
un **Unix-domain socket** relie deux processus d'une même machine par un chemin dans le système de fichiers ; **TCP**
relie deux machines, ou deux processus d'une même machine par l'adresse **loopback** 127.0.0.1, l'adresse de la
machine elle-même). Un programme est un **client** : il se connecte, prouve qui il est, et envoie des requêtes.

```
cepheus serve --config /etc/cepheus/cluster.toml
├── listeners     the Unix socket DIR/.s.cepheus.PORT (same machine) and TCP host:port with TLS 1.3
├── I/O domains   k OCaml domains; a thread a connection, spread over them
├── databases     each declared in cluster.toml: its writer and syncer (a domain of their own), its merges,
│                 its session table (G14), its follow stream to the local readers and its visibility page (G15)
├── tokens        tokens.toml, beside cluster.toml, read again when it changes
└── one cache     the page cache of every database's runs ([storage] cache)
```

Pourquoi un serveur plutôt qu'une bibliothèque que chaque programme ouvre :

- **Un seul writer, sans lock entre les programmes** (un lock réserve une donnée à un seul utilisateur à la fois et
  fait attendre les autres). Une base a un seul writer, le thread qui applique ses groupes un à la fois
  ([G9](guarantees.md#g9-un-seul-writer)). Dans un serveur, les écritures de tous les programmes atteignent ce writer
  par le socket, et leurs groupes partagent ses fsyncs (l'appel système qui attend que les octets soient vraiment sur
  le disque) : c'est le group commit entre programmes, où les écritures qui arrivent pendant un fsync partagent le
  suivant ([architecture](architecture.md#le-journal--un-write-ahead-log)).
- **Les droits.** Un programme reçoit exactement les droits de son token, base par base (G16) ; il n'a besoin d'aucune
  permission sur les fichiers des données.
- **Le chemin vers plusieurs machines.** La réplication et Raft (étapes 6 et 7 du plan) vont de serveur à serveur ; un
  programme garde le même code.

Pourquoi des **domains et des threads OCaml** : OCaml 5 exécute les threads (les fils d'exécution d'un processus) d'un
même domain un à la fois (ils partagent le runtime lock du domain, le lock qui ne laisse qu'un thread à la fois
exécuter du code OCaml ; un appel système le relâche, le décodage, la lecture des index et le codage ne le relâchent
pas) ; les domains tournent en parallèle. Un **domain** est une unité de parallélisme d'OCaml, avec son propre runtime
lock et son propre minor heap (la zone de mémoire où naissent les petites valeurs), associée à un thread du système.
Le serveur répartit ses connexions sur k I/O domains (en round robin : chacun à son tour), de sorte que k requêtes
tournent à la fois sur k cœurs ; dans un domain, **un thread par connexion** se bloque dans sa lecture et n'a besoin
d'aucune event loop (une boucle qui surveille toutes les connexions à la fois). Les lectures ne prennent aucun lock
entre elles : une vue est une valeur persistante, qui ne change jamais ([concepts](concepts.md#les-vues)). L'effet
mesuré est dans [les benchmarks](#la-vitesse-à-côté-de-postgresql).

## Faire tourner un serveur

### cluster.toml

La configuration d'un serveur, le même fichier sur chaque machine d'un cluster (les serveurs qui tiennent les mêmes
bases) sauf pour `me` (une seule machine est un cluster d'un seul peer, un peer étant l'un de ces serveurs). Chaque
clé, et chaque règle contre laquelle elle est vérifiée avant que rien ne s'ouvre :

```toml norun
[cluster]
name = "shop-prod"                 # lower-case letters, digits, '_', '-'
id = "cph-c-6f1e9a2b7d40c381"      # made by `cepheus cluster init`; checked at every connection (Welcome)
me = "srv1"                        # which [[peer]] this machine is

[[peer]]                           # exactly one in this version (several need replication: refused)
name = "srv1"
address = "127.0.0.1:7401"         # host:port the peers will use (replication, later)

[clients]
socket = "/run/cepheus"            # the directory of the Unix socket .s.cepheus.PORT (PORT: listen's, or 7400)
listen = "0.0.0.0:7400"            # TCP for programs, always TLS: needs [tls]
domains = 4                        # the I/O domains, 1 to 64; default min(4, cores / 2)
max_connections = 512              # connections open at once (local readers' included), 1 to 65536; default 512
idle_timeout = 600                 # seconds without a whole request before a connection is closed; 0: never; default 600

[tls]                              # made by `cepheus cluster init` (the CA and srv1) and `cepheus cluster cert`
ca = "/etc/cepheus/ca.pem"         # the cluster's CA: the certificates it signed are trusted
cert = "/etc/cepheus/srv1.pem"     # this server's certificate (its chain), signed by the CA
key = "/etc/cepheus/srv1.key"      # its private key, readable by the server's user only

[storage]
data = "/var/lib/cepheus"          # one directory a database inside it, and the server's own files
cache = "4G"                       # the page cache of the runs: K, M, G or bytes; default 1G

[[database]]                       # at least one; names unique: lower-case letters, digits, '_', '-', at most 64
name = "shop"
[[database]]
name = "stock"
```

- Les chemins relatifs le sont par rapport au répertoire de `cluster.toml`.
- `[clients]` demande `socket`, `listen`, ou les deux. `listen` demande `[tls]` : sur TCP, un programme parle toujours
  TLS (le protocole qui chiffre une connexion TCP, décrit plus bas), si bien que son token ne traverse jamais un
  réseau en clair (une seule façon de faire, même sur loopback).
- Une section ou une clé inconnue, une clé manquante, un mauvais type, deux bases ou deux peers du même nom : le
  serveur refuse de démarrer, et dit quelle ligne ou quelle clé (une configuration n'est jamais devinée).
- Une base déclarée et pas encore sur le disque est créée au premier démarrage (son répertoire sous `data`).
- `max_connections` borne les connexions ouvertes à la fois, de l'instant où le serveur les accepte jusqu'à leur
  fermeture (un thread chacune, et un file descriptor, le numéro par lequel un processus désigne un fichier ou un
  socket ouvert). À la limite, une nouvelle connexion est fermée aussitôt : sur le Unix socket après une frame
  d'erreur (un message du protocole qui porte une erreur) `too_many_connections`, sur TCP sans un mot et avant son
  handshake TLS (les premiers échanges, où les deux côtés s'accordent sur des clés), pour qu'une connexion refusée ne
  coûte au serveur aucun handshake (son échange de clés et sa signature : une nouvelle connexion TLS entière coûte
  2,6 ms, des deux côtés, [mesurées plus bas](#la-vitesse-à-côté-de-postgresql)). Le log dit combien ont été refusées,
  au plus une fois par seconde. La valeur par défaut, 512, laisse de la place sous la limite par défaut de systemd, 1 024 descriptors par
  service (`LimitNOFILE`), que se partagent les fichiers des bases (un segment de journal, un fichier de run par
  niveau) ; relevez les deux ensemble. Un serveur à court de descriptors le dit dans son log et recommence à accepter
  dès que des connexions se ferment (`accept` échoue avec `EMFILE` ; la connexion attend dans la file du noyau).
- `idle_timeout` : une connexion doit envoyer une requête entière dans ce nombre de secondes après que le serveur l'a
  acceptée (son handshake TLS compris) et après sa requête précédente, et doit prendre ce que le serveur lui envoie
  dans le même délai ; sinon le serveur lui envoie une frame d'erreur `idle` (id de requête 0) et la ferme. Des octets
  qui arrivent au compte-gouttes sans former une requête ne gardent pas une connexion ouverte. La bibliothèque d'un
  programme garde sa connexion en vie avec `Ping`, ou se reconnecte : le client OCaml renvoie une lecture (Open, Get,
  Find, Ping, status) sur une nouvelle connexion après une connexion rompue, dans son budget de retries (le nombre de
  nouvelles tentatives permis), comme il le fait pour les écritures (G14). Le `idle_session_timeout` de PostgreSQL est
  désactivé par défaut et son `authentication_timeout` est d'une minute ; le `timeout` de Redis est désactivé par
  défaut.

### tokens.toml

Le fichier des tokens des programmes, à côté de `cluster.toml`, lisible par le seul utilisateur du serveur (mode
0600). Il contient des hashs (une empreinte calculée à partir de chaque token, dont on ne peut pas retrouver le
token), jamais des tokens ; les commandes plus bas l'écrivent.

```toml norun
[[token]]
name = "shop-web"
hash = "blake2b-256:9f4c...e1"
databases = { shop = "write", stock = "read" }
[[token]]
name = "ops"
hash = "blake2b-256:51aa...07"
admin = true
```

- `read` : Open, Get, Find sur cette base. `write` : la lecture et Write. `admin = true` : les opérations du serveur
  (`status`) ; aucun droit sur les données à lui seul.
- Le serveur relit le fichier dans la seconde qui suit un changement (de sa date de modification, de sa taille ou de
  son inode) ; un token retiré, ou dont les droits ont été réduits, prend effet à la requête suivante de chaque
  connexion qui le tient (G16). Un fichier qui ne se lit pas comme du TOML valide n'est pas chargé (le serveur dit
  pourquoi, et garde les tokens qu'il avait).
- Un fichier absent ne contient aucun token : le serveur refuse alors tous les programmes.

### Les commandes

```
cepheus cluster init NAME --dir DIR [--host H]...
                                         a new cluster: its CA (DIR/ca.pem, DIR/ca.key), the certificate of its first
                                         peer srv1 for the hosts H (default localhost and 127.0.0.1: DIR/srv1.pem,
                                         .key), DIR/cluster.toml (a fresh id, srv1, a socket in DIR/run, TCP on
                                         127.0.0.1:7400 with TLS, the data in DIR/data, one database "main")
cepheus cluster cert NAME --dir DIR [--host H]...
                                         a certificate of the cluster's CA for NAME and its hosts (another server, a
                                         renewed one): DIR/NAME.pem, DIR/NAME.key
cepheus serve --config FILE              run the server until SIGTERM or SIGINT
cepheus stop --config FILE               SIGTERM to the server that holds FILE's data, and wait for it to end
cepheus status --config FILE             what the server holds and does; an admin token in CEPHEUS_TOKEN
cepheus token add NAME --database DB=read|write ... [--admin] --config FILE
                                         a new token, printed once on stdout (cph_ and 43 characters); its hash goes
                                         to tokens.toml
cepheus token list --config FILE         names and rights (never the tokens)
cepheus token remove NAME --config FILE  removed: its connections are refused at their next request
```

Un premier serveur sur un portable :

```sh
cepheus cluster init shop --dir ~/shop
cepheus token add app --database main=write --config ~/shop/cluster.toml > ~/shop/app.token
cepheus serve --config ~/shop/cluster.toml &
# a program connects to ~/shop/run/.s.cepheus.7400 with the token of app.token
```

`cepheus status` affiche une paire `key: value` par ligne : `server` (l'id du serveur, créé à son premier démarrage et
gardé dans `data/cepheus.server`), `cluster`, `uptime_ms`, `connections`, `requests`, `gc_minor` et `gc_major` (les
passes du garbage collector du runtime OCaml depuis le démarrage ; le garbage collector est la partie qui libère la
mémoire que plus rien n'utilise), `stopping`, et pour chaque base `database.NAME.group` (son groupe durable le plus
récent), `.facts` et `.resent` (les écritures qui ont reçu une seconde fois leur réponse, tirée de la table des
sessions, G14).

### Les fichiers du serveur

```
DATA/cepheus.lock          held (lockf) while the server runs: one server a data directory; holds its pid
DATA/cepheus.server        the server's id, made at its first start
DATA/NAME/                 a database: its files as in operations.md, and
DATA/NAME/sessions         its session table, a checkpoint (G14): written every second while writes come, and at stop
/dev/shm/cepheus-ID.visible
                           a database's visibility page (G15; ID: the database's id in hex): 4 KiB of memory (tmpfs),
                           the first 8 bytes the visibility number, mode 0600; made once, never replaced while the
                           server or a local reader runs; the server maps it and holds a lock on it (a copy of the data
                           directory run beside is refused), its local readers map it read-only. A database removed
                           leaves it until the next reboot (or remove it by hand once no server or reader runs)
SOCKET/.s.cepheus.PORT     the Unix socket, made at start, removed at stop
```

### Démarrage, arrêt, crash

**Démarrage.** Lire et vérifier `cluster.toml` et `tokens.toml` ; prendre le lock du répertoire des données (un second
serveur sur les mêmes données est refusé : G9 étendue au serveur) ; ouvrir chaque base, en parallèle (un domain
chacune, au plus `domains` à la fois), chacune avec sa recovery (ce que fait une ouverture après un crash pour
retrouver le dernier état durable, [exploitation](operations.md#louverture-et-la-recovery)) et sa table des sessions (son
checkpoint, une copie sauvegardée de la table, puis le journal qui le suit) ; ouvrir les listeners (les sockets sur
lesquels le serveur attend les connexions ; un fichier de socket laissé par un serveur mort est supprimé, un fichier
sur lequel répond un serveur vivant est refusé) ; démarrer les I/O domains ; dire à systemd que le serveur est prêt
(`READY=1` sur `$NOTIFY_SOCKET`, un seul datagramme : `sd_notify(3)`). Le serveur affiche une ligne : la durée des
ouvertures, le groupe de chaque base, les listeners.

**Arrêt** (`SIGTERM`, `SIGINT`, `cepheus stop`). Plus aucune nouvelle connexion ; les nouvelles requêtes reçoivent
`Err stopping` ; les écritures en cours deviennent durables et reçoivent leur réponse ; chaque base est fermée
proprement (son marqueur `closed` : l'ouverture suivante ne force rien) et sa table des sessions sauvegardée ; le
fichier du socket est supprimé ; le serveur sort avec le code 0.

**Crash** (kill -9, coupure de courant). Chaque base fait sa recovery comme le moteur le fait à son démarrage suivant
(G1 à G13) ; les tables des sessions sont reconstruites à partir de leurs checkpoints et du journal (G14). La
bibliothèque d'un programme se reconnecte et renvoie ses écritures restées sans réponse : chacune est appliquée une
fois.

**Un disque en panne.** Quand le writer d'une base s'arrête sur une écriture ou un fsync qui a échoué
([G10](guarantees.md#g10-arrêt-sur-une-erreur-du-disque)), le serveur s'arrête (en moins d'une seconde) et sort avec
une erreur : systemd le redémarre, et la recovery décide de ce qui est durable
([G13](guarantees.md#g13-on-ne-se-fie-jamais-à-un-fsync-qui-a-échoué)). PostgreSQL fait de même depuis ses releases du
14 février 2019 (11.2, 10.7, 9.6.12...) : un fsync qui échoue l'arrête (PANIC) au lieu d'être retenté, parce que
« fsync() will report back that it succeeded, but the data ... would not actually be written » (ses release notes :
fsync() dira qu'il a réussi, alors que les données ne seraient pas vraiment écrites ; le réglage `data_sync_retry`,
désactivé par défaut, rétablit l'ancien comportement).

Une unité systemd :

```ini
[Service]
Type=notify
ExecStart=/usr/local/bin/cepheus serve --config /etc/cepheus/cluster.toml
User=cepheus
Restart=on-failure
TimeoutStopSec=120
MemoryMax=8G
```

## Le protocole

### Le framing

Le framing est le découpage d'une connexion en messages. Une connexion porte des **frames** (des messages, chacun d'un
seul bloc) dans les deux sens. Une frame commence par sa longueur : un lecteur prend donc une frame entière sans
l'analyser, et refuse une frame qui dépasse la limite avant de la lire :

```
frame  = length u32 LE (the bytes after this field, 6 to 16 MiB + 6) | id u32 LE | kind u8 | flags u8 | body
flags  = bit 0 more: the reply continues in the next frame of this id (the rows of a Find)
         bit 1 error: the body is an error
```

- `id` : choisi par le client ; une réponse porte l'id et le kind (le type de message) de sa requête.
- Une frame de plus de 16 MiB reçoit la réponse `too_large` et la connexion se ferme : l'autre bout de la connexion,
  s'il annonce 4 GiB, ne peut pas faire allouer cette mémoire au serveur. Un nombre annoncé dans un corps (de faits,
  de lignes, d'opérations) plus grand que les octets qui restent est refusé avant que rien ne soit alloué.
- Les **valeurs** sont codées comme dans le journal ([formats](formats.md)) : un octet de tag, qui donne le type (0
  int, 1 float, 2 false, 3 true, 4 text, 5 date, 6 money, 7 link), puis un varint en zigzag, les 8 octets d'un float,
  ou une longueur et les octets d'un texte. Un **varint** est un entier en groupes de 7 bits, les bits bas d'abord, le
  bit de poids fort de chaque octet disant « encore » (LEB128) ; le **zigzag** envoie 0, -1, 1, -2... sur 0, 1, 2,
  3..., si bien que les petits nombres négatifs restent courts. Un seul codage des valeurs partout : le journal, le
  wire protocol, et plus tard la réplication.

### Requêtes et réponses

| kind | corps de la requête | corps de la réponse |
|---|---|---|
| 1 Hello | la version en varint (1), le token en string, le programme en string, la session en varint (0 : une nouvelle) | Welcome : l'id du serveur, l'id du cluster, la session, la limite des frames, la limite des écritures en cours |
| 2 Open | le nom de la base | Opened : le handle (le numéro de la base ouverte sur cette connexion), le groupe le plus récent, les propriétés (id, nom, code du type, many, unique) |
| 3 Get | handle, chose | Facts : le groupe de la vue, le nombre, (propriété, valeur)... |
| 4 Find | handle, question, select | Rows (en frames d'environ 1 MiB, toutes sauf la dernière avec `more`) : le groupe de la vue, les colonnes, le nombre, les valeurs ligne par ligne |
| 5 Write | handle, serial, floor, by (zigzag), why, nombre, opérations | Receipt : le groupe, le nombre, (id temporaire de la nouvelle chose, son id)... |
| 6 Ping | des octets quelconques | Pong : les mêmes octets |
| 7 Admin | "status" | Status : le nombre, (clé, valeur)... |
| 8 Follow | handle (sur le Unix socket seulement) | Start : l'id de la base, le numéro de visibilité, le nombre, (lo, hi) de chaque run, du plus récent au plus ancien ; les descriptors de `visible` et de chaque run voyagent avec son premier octet. La connexion est alors le follow stream de la base ([lectures locales](#lectures-locales-g15)) |

Sur un follow stream, le serveur pousse (id de requête 0) :

| kind | corps |
|---|---|
| 9 frame | le numéro (0 : une partie du rattrapage, pas visible à elle seule), le premier groupe, le nombre, puis les groupes tels que le journal les code ; une frame longue continue dans des frames du flag `more` qui ne portent que des octets |
| 10 runs | le numéro (le lecteur abandonne ses états sous des numéros plus petits), le nombre, (lo, hi) de chaque run, du plus récent au plus ancien ; leurs descriptors voyagent avec son premier octet |

- Une **question** est une donnée : des variables, des patterns (chose, propriété, valeur, chacune une variable, une
  chose ou une valeur) et des intervalles (ranges), comme `Cepheus.query` ([API](api.md)) ; aucun code ne traverse le
  réseau, et chaque propriété est vérifiée contre le schéma de la base.
- **select** : `Give [x...]` donne ces variables de chaque réponse, dans cet ordre (aucune : toutes) ;
  `Group ([k...], [a...])` donne une ligne par clé distincte : les variables de la clé, puis les agrégats `Count`,
  `Sum x` (int, money), `Min x`, `Max x` (int, money, date), calculés dans le serveur sans construire les réponses (Q4
  plus bas : 100 lignes au lieu de 45 064).
- Une **opération** : 0 Add, 1 Retract, 2 Expect une valeur, 3 Expect aucune ; puis la chose (en zigzag : un id
  négatif est une nouvelle chose du groupe), la propriété, la valeur.
- Chaque lecture nomme le groupe de la vue qui lui a répondu, chaque reçu (Receipt, la réponse à une écriture) son
  groupe : un programme peut vérifier ce qu'il a lu contre ce qu'il a écrit.

### L'ordre, le pipelining et la back-pressure

- **Pipelining** : un client peut envoyer des requêtes sans attendre les réponses, jusqu'à la limite qu'annonce
  Welcome (1 024 écritures en cours, c'est-à-dire envoyées et pas encore répondues, par connexion). Les lectures d'un
  même lot reçoivent leurs réponses en un seul appel système.
- **Les réponses peuvent arriver dans le désordre**, reliées à leur requête par l'id : un long Find ne retient pas les
  courts Gets envoyés après lui (les écritures reçoivent leur réponse quand elles sont durables, les lectures tout de
  suite). PostgreSQL et Redis répondent dans l'ordre sur une connexion.
- **Ce qui reste ordonné** : les écritures d'une connexion vers une base atteignent son writer dans l'ordre d'envoi
  (« monotonic writes », Terry et al. 1994) ; une requête envoyée après l'arrivée du reçu d'une écriture voit cette
  écriture (« read your writes »), puisqu'un reçu n'est envoyé qu'une fois son groupe publié (G5).
- **Back-pressure** (le côté lent qui ralentit le côté rapide au lieu d'être submergé) : à la limite des écritures en
  cours, le serveur cesse de lire ce socket ; les buffers du noyau (sa mémoire d'attente) se remplissent et les
  écritures du client attendent. Rien n'est perdu et aucune erreur n'est à traiter. Les lignes d'un Find sont envoyées
  frame par frame : la frame suivante n'est codée qu'une fois que le socket a pris la précédente (les index words de
  sa réponse, la forme sur 64 bits de chaque valeur dans les index, sont d'abord rassemblés, 8 octets par valeur, si
  bien qu'une très grande réponse coûte ses words dans la mémoire du serveur jusqu'à ce qu'elle soit envoyée).

### À côté des protocoles des géants (d'après leur documentation)

| | framing (le découpage en frames) | plusieurs requêtes en cours | réponses | push du serveur | erreurs | contrôle de flux |
|---|---|---|---|---|---|---|
| PostgreSQL (protocole 3.0 ; 3.2 depuis 18) | « The first byte of a message identifies the message type, and the next four bytes specify the length of the rest of the message » (le premier octet donne le type du message, les quatre suivants la longueur du reste) | pipelining avec le protocole étendu (Parse, Bind, Execute, Sync) | dans l'ordre | `LISTEN`/`NOTIFY` | `ErrorResponse` ; dans un pipeline, « the backend will skip command messages until it finds Sync » (le backend saute les messages de commande jusqu'à trouver Sync) | TCP |
| Redis RESP2/RESP3 | « The first byte in an RESP-serialized payload always identifies its type » (le premier octet donne toujours le type) ; des parties terminées par CRLF, des bulk strings précédées de leur longueur | pipelining | dans l'ordre | le type push de RESP3 | le type d'erreur `-` | TCP ; les clients lents sont fermés |
| etcd | gRPC (« All etcd APIs are defined in gRPC services », toutes les API d'etcd sont des services gRPC) | plusieurs appels | chaque appel a la sienne | les streams Watch | le status gRPC | celui de gRPC ; des requêtes d'au plus 1,5 MiB par défaut |
| FoundationDB | la bibliothèque cliente est le protocole : les programmes appellent sa bibliothèque C (des futures) | des futures | par future | des watches (10 000 par connexion par défaut) | des codes d'erreur | celui de la bibliothèque |
| Cepheus | longueur, id, kind, flags ; le codage des valeurs du journal | jusqu'à la limite qu'annonce Welcome | **par id, dans le désordre** | (les subscriptions, être prévenu des changements : étape 5) | des valeurs `{code, message}` | TCP, et le serveur cesse de lire à la limite |

### Erreurs

Chaque réponse est une valeur ou une erreur `{code, message}`. Les codes du moteur : `conflict`, `invalid`, `unique`,
`damaged`, `io`, `busy`, `closed` ([erreurs](errors.md)). Ceux du serveur :

| code | quand | que faire |
|---|---|---|
| `auth` | Hello avec un token inconnu ; une requête avant Hello ; un token retiré depuis | vérifier le token ; la connexion se ferme |
| `denied` | il manque au token le droit pour cette base ou cette opération ; une session d'un autre token | un token qui a ce droit |
| `version` | Hello avec une autre version du protocole | le serveur et la bibliothèque d'une même release |
| `too_large` | une frame de plus de 16 MiB | écrire en groupes plus petits ; la connexion se ferme |
| `unknown_database` | un nom ou un handle que le serveur ne tient pas | la déclarer dans cluster.toml |
| `stopping` | le serveur s'arrête | se reconnecter : la bibliothèque le fait |
| `too_many_connections` | une nouvelle connexion sur le Unix socket alors que le serveur tient `max_connections` connexions (id de requête 0 ; sur TCP la connexion est fermée sans un mot) | se connecter plus tard, ou relever la limite |
| `idle` | aucune requête entière pendant `idle_timeout` secondes (id de requête 0, puis le serveur ferme la connexion) | envoyer `Ping` entre-temps, ou se reconnecter : le client OCaml le fait |
| `refused` | une écriture renvoyée après qu'une écriture plus tardive de sa session a été appliquée, et dont la première erreur s'est perdue quand le serveur a redémarré (si c'est le même serveur qui l'a refusée, son erreur est redonnée à la place) | elle n'a pas été appliquée : décider à nouveau |
| `invalid` | une requête mal formée (la connexion se ferme), une question qui ne passe pas la vérification, un numéro de série sous le floor de sa session, un why qui commence par le marqueur du serveur, `Follow` sur une connexion qui a des écritures en cours | corriger la requête |
| `denied` (Follow) | `Follow` sur TCP : les lectures locales sont pour les programmes de la machine du serveur, par son Unix socket | lire à travers le serveur ; le client OCaml le fait de lui-même |
| `busy` (Follow) | `Follow` quand les fichiers de runs n'ont pas pu être ouverts huit fois de suite (des merges les supprimant entre-temps) | suivre à nouveau : le client OCaml le fait, en moins de 100 ms |

## Écritures appliquées une seule fois, les sessions (G14)

Une écriture dont la réponse se perd (la connexion a rompu, le serveur est mort) laisse son programme dans le doute :
renvoyée, elle pourrait être appliquée deux fois (deux clients créés par une seule inscription). Les sessions lèvent
le doute.

- Welcome donne à la connexion une **session** (un nombre aléatoire de 62 bits) ; une bibliothèque qui se reconnecte
  l'envoie dans son Hello et la reprend.
- La bibliothèque numérote ses écritures dans la session : c'est le **numéro de série** (le champ serial) 1, 2, 3... ;
  avec chaque écriture, elle envoie son **floor** (son plancher), le plus petit numéro de série qui attend encore sa
  réponse.
- Le serveur garde, pour chaque base et chaque session, les reçus des numéros de série égaux ou supérieurs au floor.
  Un numéro de série revu reçoit son premier reçu (son groupe, et ses nouvelles choses numérotées comme la première
  fois) ; un numéro de série encore en cours attend l'issue du premier, et ne s'exécute jamais deux fois. C'est la
  méthode de la thèse d'Ongaro (section 6.3 : « Each server's state machine maintains a session for each client ...
  latest serial number processed ... along with the associated response », la state machine de chaque serveur garde
  une session par client, avec le dernier numéro de série traité et sa réponse), avec le floor pour que plusieurs
  écritures d'une session puissent être en cours.
- Chaque groupe que le serveur écrit porte son **origine** : le nom du token, la session, le numéro de série et le
  floor, dans le `why` du groupe, avant le texte du programme lui-même (`"\000cph1\000"`, trois varints, le nom ;
  [formats](formats.md)). Ainsi l'historique dit quel programme a écrit chaque groupe, et c'est le journal qui fait
  foi pour la table.
- La table est sauvegardée dans `DATA/NAME/sessions` chaque seconde tant que des écritures arrivent, et à l'arrêt
  (écrite à côté, forcée sur le disque, renommée). Au démarrage : le checkpoint, puis le journal après son groupe
  (`Journal.read_after`). Un checkpoint qui ne passe pas la vérification (son CRC, un checksum qui change si
  les octets changent) est ignoré : le journal est lu depuis son début, plus lentement, jamais faux.
- Une session oublie ses reçus une heure après sa dernière écriture ; une session garde au plus 4 096 reçus (une
  bibliothèque qui n'avance jamais son floor perd les plus anciens).

**G14 Écritures appliquées une seule fois.** *Promesse.* Une écriture envoyée avec une session et un numéro de série
est appliquée au plus une fois, quelles que soient les pannes ; une écriture renvoyée avec sa session et son numéro de
série jusqu'à ce qu'elle reçoive sa réponse est appliquée exactement une fois, et chaque réponse nomme le même groupe
et les mêmes nouvelles choses. *Sous* F1, F2 (les crashs et les coupures de courant du serveur), des connexions
rompues, des octets perdus ou retardés. *Conditions* : la même session et le même numéro de série sont renvoyés dans
l'heure qui suit la dernière écriture de la session ; le programme envoie un numéro de série donné avec les mêmes
opérations (un corps différent reçoit le reçu du premier). *Non couvert* : une écriture dont les retries sont épuisés
(`unreachable`) : appliquée une fois ou pas du tout, la réponse honnête que donne toute base de données en réseau pour
un commit dont la réponse s'est perdue.

*Esquisse de preuve.* (1) Dans un même processus serveur, la table est consultée et l'écriture marquée en cours sous
un seul lock, avant qu'elle soit envoyée au writer : une seconde copie la trouve en cours ou faite, donc une seule
copie s'exécute. (2) À travers un crash : le reçu de chaque écriture dont le groupe vient au plus tard au groupe du
checkpoint est dans le checkpoint, parce que le groupe du checkpoint est
$\min(\text{le groupe publié}, \text{le groupe publié quand chaque écriture en cours a été envoyée})$, et qu'une
écriture envoyée quand le groupe publié était $P$ prend un groupe après $P$ ; chaque écriture après le groupe du
checkpoint est dans le journal avec son origine, lu au démarrage. Un groupe durable est donc toujours retrouvé, et une
écriture qui n'était pas durable n'a pas été appliquée (G1, G3), si bien que la renvoyer l'applique une fois. (3) Les
ids des nouvelles choses sont recalculés à partir du premier nouvel id du groupe et de l'ordre de première apparition
dans les opérations, la règle par laquelle le moteur les numérote.

*Tests.* `server_sim` (simulation : chaque reçu, premier ou renvoyé, contre le journal : chaque (session, numéro de
série) dans au plus un groupe, le reçu le nomme ainsi que ses nouvelles choses ; à travers des crashs, des coupures de
courant, des checkpoints abîmés et des connexions rompues) ; `server_crash` (un vrai serveur tué 20 fois sous quatre
clients qui écrivent : aucune valeur deux fois, aucune confirmée puis absente) ; `server_unit` (la table : en cours,
faite, les floors, le checkpoint et son CRC).

## Lectures locales (G15)

Un programme sur la machine du serveur peut lire une base dans sa propre mémoire, sans round trip (l'aller-retour
d'une requête et de sa réponse) : c'est une **lecture locale**. Elle coûte 0,22 µs là où une lecture par le Unix
socket coûte 10,2 µs et une lecture de PostgreSQL 25,5 µs, et elle voit chaque écriture confirmée avant qu'elle ne
commence, exactement comme une lecture au serveur (G15). Le code du programme est le même : le client OCaml suit de
lui-même une base qu'il ouvre par le Unix socket, et lit à travers le serveur quand il ne le peut pas (sur TCP, ou
pendant que son follower est refait).

### Ce que le programme garde, et ce qu'on lui envoie

Un **follower** est la copie d'une base que garde un lecteur local : les **fichiers de runs** du serveur (les fichiers
triés et immuables du LSM-tree, [architecture](architecture.md)), lus par le page cache du programme lui-même (la
mémoire où il garde des pages de ces fichiers), chaque page vérifiée par son CRC à son arrivée (G7), et un delta des
groupes les plus récents (leurs changements, en mémoire), qu'il applique lui-même comme l'a fait le serveur
(`Resolve.replay`). Le serveur les lui envoie sur une seconde connexion au Unix socket (le **follow stream**, le flux
qui le tient à jour, ouvert par la requête `Follow`) :

```
Follow {db}            the reader's right is checked (G16); then, over this connection only:
Start  {id, n, runs}   the descriptors of the visibility page and of each run file, passed by the kernel (SCM_RIGHTS)
Frame  {0, groups}     the groups after the newest run, up to the state visible under n (a catch-up)
Frame  {n, none}       that state is visible under n
Frame  {n+1, groups}   each frame the writer makes, sent as the writer takes it, before its fsync
Runs   {n, runs}       new runs (a merge, or a large group's run): the reader rests its states on them
```

- **Des descriptors, pas des chemins.** Un **file descriptor** est la poignée d'un processus sur un fichier ouvert ;
  un Unix-domain socket peut porter des descriptors d'un processus à un autre (« SCM_RIGHTS: Send or receive a set of
  open file descriptors from another process », unix(7) : envoyer ou recevoir des file descriptors ouverts d'un autre
  processus) : le receveur obtient son propre descriptor du même fichier ouvert. Le programme n'a besoin d'aucune
  permission sur le répertoire des données, et le serveur décide, après le token, quelle base il peut lire (G16). Le
  serveur ouvre chaque fichier de run à neuf pour chaque lecteur (pour qu'aucun autre processus ne déplace son offset,
  sa position de lecture dans le fichier) et ferme sa propre copie une fois envoyée ; la page de visibilité est un
  seul descriptor en lecture seule que le serveur garde ouvert et passe à chaque lecteur (elle est mappée,
  c'est-à-dire placée dans la mémoire du processus, jamais lue à un offset). Un fichier de run ne change jamais une
  fois nommé, et un descriptor garde un fichier lisible après qu'un merge a supprimé son nom, si bien qu'un lecteur
  qui tient un état plus ancien lit toujours les bons octets. Le module `Unix` d'OCaml n'a pas de `sendmsg` : les 130
  lignes de `server/fdpass_stubs.c` le font, derrière un seul module OCaml (`Fdpass`), testé avec des messages
  aléatoires et des descriptors lus en morceaux aléatoires.
- **Règles** ([règles](rules.md)) : les faits dérivés (ceux que donne une règle) arrivent au lecteur tels qu'ils sont
  sur le disque, avec leur sorte (le flag du run, les kinds de la frame), et le lecteur les applique comme le fait la
  recovery ; il n'évalue jamais une règle, si bien que son état sous un numéro est celui du serveur, faits dérivés
  compris.
- **Les frames voyagent pendant le fsync.** Le lecteur décode et applique une frame (ici celle du journal : les
  groupes qu'un même fsync rend durables) pendant que le disque du serveur la force (environ 3 ms ici), et garde de
  côté l'état qu'elle donne, sous le numéro avec lequel elle a été envoyée. Il ne montre jamais cet état avant que le
  numéro ne le dise.

### Ce que voit une lecture locale : un seul numéro en shared memory

Les lectures **linearizable** (Herlihy et Wing 1990) sont des lectures qui semblent chacune se produire à un instant
unique entre leur appel et leur retour. Pour une base dont les écritures forment un seul ordre de groupes (G4), cela
revient exactement à trois conditions sur chaque lecture, que `spec/LocalReads.tla` énonce et vérifie :

- **Fresh** (à jour) : une lecture contient chaque groupe dont l'auteur (le programme qui l'a écrit) a reçu sa réponse
  avant que la lecture ne commence (pas de lecture périmée) ;
- **Ordered** (ordonnée) : une lecture contient chaque groupe qu'une autre lecture a rendu avant que celle-ci ne
  commence (pas de **new-old inversion** : deux lecteurs dont le plus tardif voit un état plus ancien ; le
  registre *atomic* de Lamport l'interdit, son registre *regular* le permet, On Interprocess Communication, 1986) ;
- **Durable** (durable) : une lecture rend l'état exact après un groupe durable (G5), jamais un état qu'un crash peut
  reprendre.

La règle qui donne les trois est un seul numéro, le **numéro de visibilité**, dans une page de shared memory (une
mémoire que plusieurs processus voient à la fois) : les 8 premiers octets de `/dev/shm/cepheus-ID.visible`, un fichier
de 4 KiB en mémoire (tmpfs, un système de fichiers qui vit en mémoire) que le serveur mappe en lecture-écriture et que
chaque lecteur mappe en lecture seule (`mmap` avec `MAP_SHARED` : une seule page physique, ce que le serveur y écrit
est vu aussitôt par chaque processus ; le lecteur ne peut pas l'écrire). En mémoire plutôt que sur le disque : le
numéro n'a besoin d'aucun fsync (après un reboot il ne reste aucun lecteur), il survit à la mort d'un serveur (la
règle plus bas en a besoin), et une page de tmpfs n'est jamais réécrite sur un disque, si bien que l'écriture du
serveur dans cette page n'en attend jamais un.

Un lecteur mappe la page par un petit stub C (une fonction écrite en C qu'OCaml appelle), avec `PROT_READ` et
`MAP_SHARED`, plutôt qu'avec `Unix.map_file`, qui mappe en lecture-écriture (un mapping partagé demande alors un
descriptor ouvert en écriture, qui laisserait un lecteur déplacer le numéro) ; et d'un mapping privé mmap(2) dit :
« It is unspecified whether changes made to the file after the mmap() call are visible in the mapped region » (on ne
sait pas si les changements faits au fichier après l'appel à mmap() sont visibles dans la région mappée). La règle,
pas à pas :

- Chaque frame est envoyée marquée du numéro sous lequel elle sera visible : le numéro courant plus 1.
- Une fois que le fsync de la frame est revenu et qu'elle est publiée, le serveur écrit le nouveau numéro, puis répond
  aux auteurs de la frame, puis laisse les lectures distantes (celles qui passent par le serveur) la voir.
- Une lecture charge le numéro et sert l'état que le lecteur tient sous ce numéro ; s'il ne le tient pas encore (la
  frame est encore en route, ou en train d'être appliquée), elle l'attend, et n'en sert jamais un plus ancien.
- Un serveur qui démarre ajoute 2 au numéro avant toute chose : un lecteur du serveur mort peut tenir un état sous le
  numéro qu'aurait pris la dernière frame du serveur mort, une frame que la mort a pu perdre, et la frame suivante du
  nouveau serveur prend un autre numéro.

Ainsi un groupe devient visible pour chaque lecteur, local ou distant, en un seul instant : l'écriture du numéro. Une
lecture qui commence plus tard le charge ; une lecture qui a chargé un numéro plus ancien a commencé avant. L'état
sous un numéro est le même pour chaque lecteur (les mêmes groupes dans le même ordre), et il est durable avant que le
numéro soit écrit (G5, G13).

**G15 Les lectures locales sont linearizable.** *Promesse.* Chaque lecture, dans un lecteur local ou au serveur,
contient chaque groupe répondu à n'importe quel programme avant qu'elle ne commence, et chaque groupe qu'une lecture a
rendu avant qu'elle ne commence, et elle est l'état exact après un groupe durable ; avec l'ordre des groupes (G4),
groupes et lectures ensemble sont strictly serializable (équivalents à une exécution une par une, dans un ordre qui
respecte le temps réel). *Sous* F1 (la mort du serveur ou d'un lecteur : l'état d'un lecteur survit à la mort du
serveur, et n'est servi que sous son propre numéro), des lecteurs lents, en pause ou arrêtés (un lecteur ne retient
que ses propres lectures), des streams rompus. *Conditions* : une seule machine : le serveur et ses lecteurs partagent
la page de visibilité, qui n'est jamais supprimée ni remplacée tant qu'ils tournent (un lecteur lit le fichier qu'on
lui a passé : un nouveau fichier le laisserait lire un numéro que personne ne fait avancer) ; un lecteur qui prend
plus de 64 MiB de frames de retard est coupé, et suit à nouveau. *Non couvert* : une vue qu'un programme garde exprès
lit l'état de cette vue, comme partout (une vue ne change jamais, G5). Après une coupure de courant, chaque lecteur
meurt avec la machine.

*Esquisse de preuve.* Soit $w(n)$ l'instant où le serveur écrit le numéro $n$, et $S(n)$ l'état qu'il couvre. (1)
Durable : le serveur n'écrit $n$ qu'après que le fsync de la frame de $S(n)$ est revenu ; un lecteur ne sert $S(n)$
que quand il charge $n$ ; dans un même processus serveur, les numéros suivent les frames une à une, et un nouveau
processus démarre au dernier numéro + 2, si bien qu'un numéro qu'un lecteur tient d'un processus antérieur, au plus le
dernier numéro + 1, n'est jamais écrit à nouveau. (2) Fresh : l'auteur d'un groupe $g$ de $S(n)$ reçoit sa réponse
après $w(n)$ ; une lecture qui commence après la réponse charge un numéro $m \ge n$, et $S(m)$ contient $S(n)$. (3)
Ordered : une lecture qui a rendu $S(n)$ a chargé $n$ après $w(n)$ ; une lecture qui commence après elle charge
$m \ge n$. Les lectures distantes prennent la vue du serveur pour le numéro courant, qu'il fixe après $w(n)$ : le même
argument.

*Tests.* `spec/LocalReads.tla`, model-checked par TLC (le model checker de TLA+, qui visite chaque état atteignable ;
`tools/tlc.sh`) : la règle construite tient Fresh, Ordered et Durable avec deux lecteurs, des lectures distantes et
trois écritures (3 436 820 états distincts), et avec un lecteur, des lectures distantes, trois écritures et une mort
du serveur dont la frame en cours est gardée ou perdue (210 716) ; chaque partie retirée en casse une, et TLC affiche
la trace la plus courte : sans le 2 au démarrage, un groupe que le redémarrage a rendu durable reçoit sa réponse
pendant qu'un lecteur sert l'état d'avant sous le numéro inchangé (Fresh, 8 états) ; le numéro écrit avant le fsync
montre un groupe qu'une mort reprend ensuite (Durable, 6 états) ; les lectures distantes déplacées au fsync, avant le
numéro, donnent une new-old inversion (Ordered, 8 états). `server_sim` (la simulation : des lecteurs locaux qui
suivent le vrai code du fan-out, l'envoi des frames à chaque lecteur, et du follower, en pause, lents, tués et
redémarrés, leurs streams coupés quand le serveur meurt ; chaque lecture, locale ou distante, vérifiée pour les trois
conditions contre l'état du modèle à son groupe) ; `server_crash` (un vrai serveur tué 20 fois pendant que deux
lecteurs lisent dans leur propre mémoire : chaque lecture contient chaque écriture répondue et chaque état rendu avant
qu'elle ne commence) ; `server_unit` (descriptors passés : 400 messages aléatoires ; la page partagée).

### Les règles qu'avait d'abord la conception, et pourquoi elles ont été laissées

La conception du 2026-11-08 proposait un **lease** (une permission qui expire d'elle-même ; Gray et Cheriton,
SOSP 1989) : le serveur envoie `Durable {n, until T}` après le fsync, `T` lu sur la monotonic clock de la machine
(l'horloge qui ne recule jamais), un lecteur sert son état durable le plus récent tant que son horloge lit moins que
`T`, et le serveur répond aux auteurs du groupe n une fois que chaque lecteur dont le `T` est encore à venir a envoyé
son ack de n (son accusé de réception). TLC trouve que cette règle garde Fresh et Durable (289 765 états distincts
avec un lecteur, deux écritures et quatre ticks d'horloge d'un lease de deux) mais casse Ordered, dans une trace de 7
états : le groupe $n$ est publié à son fsync et une lecture distante le rend ; un lecteur local dont le lease court
n'a pas encore appliqué `Durable n`, et une lecture qui commence après la lecture distante rend $n - 1$. Deux lecteurs
locaux donnent la même inversion. De telles lectures forment un registre *regular*, pas un registre *atomic* : la
linearizability demande un instant unique où un groupe devient visible partout, et deux processus qui l'apprennent
chacun par un message ne peuvent pas basculer en un seul instant sans un autre échange pendant lequel les lectures
attendent : dans les Paxos quorum leases, le détenteur d'un lease ne lit localement qu'après avoir vérifié « whether
an update to any of the leased objects is ongoing (i.e., in the process of being committed), and if not » (si une mise
à jour de l'un des objets couverts par le lease est en cours, c'est-à-dire en train d'être validée, et sinon) (Moraru,
Andersen, Kaminsky, SoCC 2014). Sur une seule machine, la shared memory donne cet instant gratuitement. Le premier
brouillon de la conception (un lecteur qui renouvelle son propre lease quand il envoie son ack) casse aussi Fresh (une
trace de 12 états : le lecteur est lent ; son lease expire, si bien que le serveur répond aux auteurs des groupes 1 et
2 sans son ack ; le lecteur prend alors le vieux `Durable 1`, renouvelle son propre lease à partir de ce moment, et
sert le groupe 1 à une lecture qui commence après que le groupe 2 a reçu sa réponse). Les deux sont gardées dans le
modèle, chacune avec sa configuration, pour montrer qu'elles cassent.

Ce que la règle du numéro change par rapport au lease : aucune écriture n'attend aucun lecteur (le lease faisait
attendre à chaque écriture un round trip vers le lecteur le plus lent, et jusqu'à la durée du lease pour un lecteur
arrêté) ; aucune horloge n'est lue lors d'une lecture ; aucun message ne revient du lecteur ; un serveur qui démarre
n'attend rien (le lease le faisait attendre la durée d'un lease). Avec plusieurs machines (étape 7), un lecteur
ailleurs n'a pas de page partagée : les leases y reviennent, entre serveurs (quorum leases), et la page contient alors
la fin du propre lease du serveur local.

### Ce que cela coûte

Sur la machine des [benchmarks](benchmarks.md) (i7-4720HQ, 4 cœurs et 8 threads, 11 GB, un SSD SATA), le 2026-11-08,
le build release de cette version (compilé avec les optimisations) avec 4 I/O domains, PostgreSQL 18.6 sur un cluster
PostgreSQL à nous (`bench/pg/pg.sh`, port 5548), les mêmes 1 M de faits des deux côtés (`bench.exe load`, rechargés
avant ces mesures) ; chaque côté alterné avec les autres à chaque tour, chaque tour sous le lock qui tient à l'écart
les autres travaux lourds de la machine, chaque processus limité à 3 GB ; des médianes et leur intervalle à 95 % sans
hypothèse sur la distribution (par les statistiques d'ordre), n tours comme indiqué. Les mêmes réponses partout : Q3
pour city-7, 396 lignes ; Q4, 45 064 factures impayées dont la somme fait 2 248 567 111 centimes, dans un lecteur
local, par le socket et dans PostgreSQL. Une lecture locale est `Client.get` (ou `find`) dans un programme qui suit la
base (`bench/sbench.ml`, `local` et `localq`) ; par le socket, c'est la même requête, à laquelle répond le serveur.

| | lecture locale | par le Unix socket | PostgreSQL 18.6, Unix socket |
|---|---:|---:|---:|
| lecture ponctuelle (les 4 faits d'une facture), $n = 11$ | **0,221 µs** [0,210 ; 0,293] | 10,17 µs [9,22 ; 13,83] | 25,48 µs [23,76 ; 29,19] |
| Q3, les factures impayées d'une ville (396 lignes), $n = 11$ | **0,461 ms** [0,429 ; 0,522] | 0,500 ms [0,480 ; 0,580] | 0,708 ms [0,684 ; 0,803] |
| Q4, la somme et le nombre des impayés par ville (100 lignes), $n = 11$ | **11,6 ms** [10,2 ; 16,6] | 12,7 ms [11,7 ; 15,9] | 22,2 ms [21,4 ; 23,3] |

- **Une lecture ponctuelle** (une facture lue par son id) dans la mémoire du programme est 115 fois plus rapide que
  celle de PostgreSQL et 46 fois plus rapide qu'une lecture par le socket : ce qui reste est la lecture du moteur
  lui-même (la conception mesurait 0,42 µs dans le processus sur le build d'un autre jour ; le chargement du numéro et
  le choix de l'état ajoutent quelques nanosecondes). La cible du plan était 0,5 µs. Mesuré à nouveau après l'arrivée
  des règles (format de run 6, un flag dans le mot de 64 bits de chaque valeur), sur la même base agrandie par les
  mesures d'écriture plus bas jusqu'à 1,56 M de groupes, $n = 11$ : 0,245 µs [0,231 ; 0,251] dans le programme,
  9,93 µs [9,49 ; 11,27] par le socket, PostgreSQL 24,49 µs [24,11 ; 28,89].
- **Les questions** y gagnent moins : Q3 et Q4 font leur travail dans le lecteur comme dans le serveur ; le round trip
  qu'elles évitent est petit à côté (Q3 s'épargne 39 µs, Q4 environ 1 ms de codage et de décodage de 100 lignes).

**Ce qu'une écriture paie pour ses lecteurs.** Aucune écriture n'attend un lecteur. Tout le travail en plus du writer,
ce sont les deux hooks (des fonctions appelées à un point précis) par frame du follow stream : la frame mise en file
pour chaque lecteur avant son écriture, le numéro écrit et la vue avancée après son fsync. Mesuré dans le serveur
(l'horloge des hooks eux-mêmes, $n = 11$ tours de 3 s d'un client qui écrit) :

| | les hooks, par frame | une écriture durable, un client : latence médiane |
|---|---:|---:|
| aucun lecteur local | 1,42 µs [1,10 ; 1,78] | 3,06 ms [2,88 ; 3,18] |
| 8 lecteurs locaux | 14,97 µs [13,09 ; 16,90] | 3,13 ms [2,94 ; 3,50] |

La cible du plan était 20 µs pour 8 lecteurs ; les hooks coûtent 0,5 % d'un fsync de ce disque, et les deux latences
sont égales dans le bruit du disque. Le coût croît avec les lecteurs (1,4 µs sans aucun) : chaque frame est mise en
file pour chaque lecteur et réveille le thread qui l'envoie.

**Ce que suivre coûte à un lecteur.** Un lecteur local pendant que 256 clients écrivent des factures de 4 faits par le
socket ($n = 7$ tours, son temps CPU sur 4 s) : **32,3 % d'un cœur** [23,3 ; 38,8] à 17 942 groupes par seconde
[12 269 ; 22 027], environ 4,5 µs par changement appliqué. La cible du plan, 20 % d'un cœur à 18 000 groupes par
seconde, est **manquée** : la conception mesurait 1,72 µs par changement pour rejouer un journal seul sur une machine
calme ; ici le lecteur partage les 4 cœurs et les 8 threads matériels de la machine avec le serveur et les 256 clients
qui écrivent, et chaque merge du serveur lui fait appliquer à nouveau, sur les nouveaux runs, les groupes écrits
pendant le merge. Sous cette charge, sa mémoire (Pss : la mémoire du processus, où chaque page partagée compte pour sa
part) était de 273 MB [202 ; 325] : son delta des groupes depuis le run le plus récent, plus gros tant que les
écritures vont plus vite que les merges.

**Ce que huit lecteurs coûtent à la machine.** Huit lecteurs locaux du 1 M de faits, chacun ayant lu une fois chaque
facture de l'échantillon ($n = 7$) : **250 MB de Pss** en tout [249 ; 250], 31 MB chacun, pour l'essentiel sa propre
copie des pages des runs (les runs de la base font 24 MB). Les backends de PostgreSQL (un processus par connexion) qui
servent 8 clients de lectures ponctuelles : 43 MB [43 ; 44] de Pss en tout (12 processus), parce qu'ils partagent un
même buffer pool (la mémoire où une base garde les pages de ses fichiers). Que chaque lecteur garde son propre cache
était le premier choix de la conception (le code du moteur tel qu'il est, chaque page vérifiée) ; une seule copie
partagée par tous les lecteurs est l'étape suivante, quand la mémoire d'un déploiement le demandera. Avec le format de
run 7 (2026-11-09), les mêmes huit lecteurs prennent **106,5 MB de Pss** [105,6 ; 107,1] contre 252,4 [251,5 ; 253,0]
sur main 0ecc09e, en alternance sur 7 tours : la copie des pages des runs de chaque lecteur a rétréci avec les runs
([benchmarks](benchmarks.md#runs-et-journal-compressés-2026-11-09-à-10-millions-de-faits)).

**Par rapport au serveur d'avant l'étape 3** (le même serveur sans lectures locales, ses binaires et les nôtres à tour
de rôle à chaque tour, $n = 11$ ; le rapport nouveau / ancien par tour) : round trip vide 1,05 [0,90 ; 1,18], lecture
ponctuelle par le socket 0,99 [0,79 ; 1,34], écritures durables d'un client 1,21 [0,90 ; 2,26] fois l'ancien débit, de
64 clients 0,97 [0,66 ; 1,52] : aucune différence que les mesures puissent voir (chaque intervalle contient 1).

### À côté des géants (d'après leur documentation)

| | ce que voit une lecture simple | son coût |
|---|---|---|
| PostgreSQL primary (le serveur qui reçoit les écritures), Read Committed | « a snapshot of the database as of the instant the query begins to run » (un snapshot, l'état exact, de la base à l'instant où la requête commence) : chaque instruction voit chaque commit d'avant elle | un round trip (25,5 µs par le Unix socket ici) |
| PostgreSQL hot standby (une copie qui suit le primary et sert des lectures) | « data on the standby is eventually consistent with the primary » (les données du standby finissent par rejoindre celles du primary) ; avec `synchronous_commit = remote_apply`, le commit attend que le standby l'ait « applied it, so that it has become visible to queries on the standby(s) » (appliqué, de sorte qu'il soit visible des requêtes sur le standby) | un round trip vers le standby ; chaque commit attend ses standbys |
| etcd | linearizable par défaut (« linearized requests must go through the Raft consensus process » : ces requêtes passent par le consensus Raft) ; les lectures serializable « may access stale data » (peuvent voir des données périmées) | un tour de quorum (une majorité des serveurs), ou des données périmées |
| FoundationDB | « Each transaction will get a read version » (chaque transaction reçoit une version de lecture) : une version au moins égale à toute version validée | un round trip au début de chaque transaction |
| Datomic peer | « application processes have their own copy of the query engine and database in local memory » (les processus de l'application ont leur propre copie du moteur de requêtes et de la base en mémoire locale) ; `sync` donne « a database value guaranteed to include all transactions that were complete at the time sync was called » (une valeur de la base qui contient à coup sûr toutes les transactions finies au moment de l'appel à sync) | des lectures locales ; linearizable seulement après `sync` (un round trip vers le transactor, le processus qui écrit) |
| Cepheus, lecteur local | linearizable, toujours (G15) | 0,22 µs, aucun round trip ; aucune écriture ne l'attend |

Avec `remote_apply`, le commit du primary de PostgreSQL attend le standby ; les lecteurs de Cepheus ne font attendre
aucune écriture. Les peers de Datomic lisent dans leur propre mémoire mais ne voient les écritures les plus récentes
qu'après `sync` ; les lecteurs de Cepheus les voient toujours. Ce que Cepheus n'a pas ici : des lecteurs sur d'autres
machines (une replica, c'est-à-dire une copie tenue à jour sur une autre machine, étape 6, et Raft avec des quorum
leases, étape 7), et le SQL de PostgreSQL.

## Sécurité

### Les tokens

Un **token** est un secret qu'un programme présente pour prouver qui il est : 32 octets aléatoires venus du noyau
(`/dev/urandom`), montrés une seule fois sous la forme `cph_` suivi de 43 caractères de base64url (RFC 4648,
section 5). Le serveur en garde le **hash BLAKE2b-256** (BLAKE2b : une fonction de hash cryptographique, RFC 7693 ;
`Digest.BLAKE256` d'OCaml), le retrouve par son hash et le compare en temps constant (chaque octet, sans s'arrêter à
la première différence). Un `tokens.toml` volé ne donne aucun token : on ne peut pas remonter d'un hash au token.

Une seule façon d'authentifier un programme, où qu'il tourne : le token, sur le Unix socket comme sur TCP (dans TLS).
Pas de certificats clients (une opération de CA et un fichier de clé pour chaque déploiement), ni les peer credentials
du noyau (l'identité du processus à l'autre bout du socket : une seconde façon, et du C pour `SO_PEERCRED`).

### Les droits (G16)

**G16 Droits.** *Promesse.* Une connexion fait exactement ce que son token permet : une requête sur une base pour
laquelle le token n'a pas le droit est refusée avec `denied`, et de même `status` sans `admin` ; aucun groupe n'est
écrit par un token sans `write` sur sa base. Un token retiré ou restreint dans `tokens.toml` prend effet à la requête
suivante de chaque connexion, dans la seconde qui suit le changement du fichier ; le follow stream d'un lecteur local,
qui ne fait pas de requête, vérifie son token avant chaque frame qu'il envoie et chaque seconde, et se termine quand
le token ne peut plus lire : les états du lecteur disparaissent, et ses lectures vont au serveur, qui les refuse (dans
les deux secondes environ qui suivent le changement du fichier : le rechargement, puis un tick d'une
seconde). *Conditions* : le token est secret ; seul l'utilisateur du serveur peut écrire `tokens.toml`. *Preuve* : chaque
requête passe par une seule vérification des droits de la connexion pour sa base, recalculée chaque fois que la table
des tokens change (une comparaison de l'identité de la table par requête) ; les écritures portent le nom du token dans
leur origine ; les descriptors des fichiers d'une base ne sont passés qu'après la vérification de `Follow`. *Tests* :
`server_unit` (chaque token contre chaque requête sur chaque base, un token retiré, des droits restreints, une origine
forgée refusée, une frame au-delà de la limite) ; `server_sim` (des requêtes aléatoires de chaque token vérifiées
contre ses droits, et chaque groupe du journal contre ceux de son token) ; `server_crash` (un token retiré du fichier
pendant que son programme est connecté et lit dans sa propre mémoire).

### Qui peut atteindre le socket

Le répertoire du Unix socket est la porte d'entrée sur une machine : donnez-lui le mode `0750`, avec pour propriétaire
l'utilisateur du serveur et pour groupe Unix celui des programmes autorisés à se connecter
(`chgrp cepheus /run/cepheus`) ; le token reste nécessaire. Sur TCP, TLS.

### TLS

**TLS** (Transport Layer Security, version 1.3 : RFC 8446) chiffre une connexion TCP et prouve au client que le
serveur est bien celui qu'il voulait : pendant le **handshake** (les premiers round trips, où les deux côtés
s'accordent sur des clés), le serveur montre un **certificat**, une clé publique et un nom signés par une **autorité
de certification** (CA, certificate authority) en qui le client a confiance.

- **La CA du cluster.** `cepheus cluster init` crée une CA propre au cluster (une clé ECDSA sur la courbe P-256, un
  certificat auto-signé valable 10 ans : `ca.pem`, `ca.key`) et le certificat de son premier serveur (valable 825
  jours, son nom et ses hôtes dans son subjectAltName, le champ contre lequel TLS vérifie les noms) ;
  `cepheus cluster cert` signe les suivants. Les clés sont écrites lisibles par leur seul propriétaire, avant qu'aucun
  octet de la clé ne soit dans le fichier. `ca.key` signe des certificats et rien d'autre : gardez-la hors ligne.
- **Ce que vérifie un programme.** Il ne fait confiance qu'à la CA du cluster (`ca`, un paramètre qu'on lui donne), et
  vérifie que le certificat du serveur nomme l'hôte auquel il s'est connecté (une adresse IP dans les entrées IP du
  certificat, un nom dans ses entrées DNS, qu'il envoie aussi comme SNI, Server Name Indication, le nom du serveur
  envoyé au début du handshake) ; puis, dans Welcome, que l'id du cluster est celui qu'il attend, quand on lui en a
  donné un. Le TLS du serveur refuse tout ce qui est plus ancien que TLS 1.3, et ne reprend aucune session TLS (pas de
  tickets : un programme garde sa connexion).
- **Ce que vérifie le serveur.** Le token du programme, dans TLS (les programmes ne montrent aucun certificat :
  choix 2 de la conception). Entre serveurs (la réplication, plus tard), les deux côtés montreront un certificat de la
  CA qui nomme un peer de la liste : du mutual TLS, comme le font FoundationDB et etcd.
- **Refusé, et testé** (`server_tls`) : un serveur dont le certificat a été signé par une autre CA ; un certificat de
  la bonne CA qui ne nomme pas l'hôte qu'a utilisé le programme ; un serveur d'un autre id de cluster ; une connexion
  TCP sans CA ; un client en clair (sans TLS) sur le port TLS, qui ne reçoit aucun Welcome ; et le serveur continue de
  servir après chacun.

**Quelle bibliothèque.** OpenSSL 3, le `libssl` du système (les correctifs de sécurité arrivent avec les mises à jour
du système, le même jour que pour PostgreSQL, qui l'utilise aussi), par environ 370 lignes de C à nous
(`server/tls_stubs.c`) derrière une seule interface OCaml (`server/tls.ml`). OpenSSL ne travaille que sur des buffers
en mémoire (des memory BIOs, qui tiennent lieu de réseau) : le côté OCaml lit et écrit le socket, si bien que le
thread bloqué à lire une requête ne tient aucun lock pendant qu'un autre thread envoie une réponse, et OpenSSL
n'attend jamais. Le calcul du handshake (l'échange de clés et les signatures : une nouvelle connexion coûte 2,6 ms,
mesurées plus bas) tourne sans le runtime lock. L'autre voie, ocaml-tls (Kaloper-Meršinjak et al., USENIX Security
2015), écrit le protocole en OCaml, mais ses ciphers (les algorithmes de chiffrement) sont en C eux aussi
(mirage-crypto), il demande quatorze packages opam, et ce n'est pas un projet OSS-Fuzz (le service qui soumet en
continu les grands logiciels libres au fuzzing : des millions d'entrées générées pour y trouver des fautes) ; OpenSSL
en est un (choix 3 de la conception).

## La vitesse à côté de PostgreSQL

Serveur contre serveur, sur la machine des [benchmarks](benchmarks.md) (i7-4720HQ, 4 cœurs et 8 threads, 11 GB, un SSD
SATA grand public), le 2026-11-08, Cepheus à a980df9 (build release) avec 4 I/O domains, PostgreSQL 18.6 sur un
cluster PostgreSQL à nous (`bench/pg/pg.sh`, port 5547, `fsync` et `synchronous_commit` activés, TLS 1.3 seulement
pour TCP). Les mêmes données des deux côtés : `bench.exe load` de 1 M de faits (11 363 clients, 227 260 factures ;
PostgreSQL : les mêmes lignes par COPY, les index, `VACUUM ANALYZE`). Chaque côté alterné avec l'autre à chaque tour,
chaque tour sous un lock qui tient à l'écart les autres travaux lourds de la machine, chaque processus limité à 3 GB ;
des médianes et leur intervalle à 95 % sans hypothèse sur la distribution (par les statistiques d'ordre,
[benchmarks](benchmarks.md#méthode)), n tours comme indiqué. Le client de Cepheus est `bench/sbench.ml` (OCaml, chaque
réponse décodée) ; celui de PostgreSQL est `pgbench -M prepared` (des prepared statements, le protocole étendu). Une
lecture ponctuelle est une facture lue par son id : `Get` de ses 4 faits contre `SELECT * FROM invoice WHERE id = :k`.

| | Cepheus | PostgreSQL 18.6 | rapport |
|---|---:|---:|---:|
| round trip vide, Unix socket (Ping ; `SELECT 1`), $n = 21$ | 9,32 µs [8,75 ; 9,77] | 15,19 µs [14,57 ; 16,30] | 1,6× |
| lecture ponctuelle, 1 client, Unix socket, $n = 21$ | **10,81 µs** [10,36 ; 11,15] | 26,39 µs [25,22 ; 27,78] | 2,4× |
| lecture ponctuelle, 1 client, TCP + TLS 1.3, $n = 21$ | **39,18 µs** [36,24 ; 44,59] | 49,64 µs [48,31 ; 50,61] | 1,3× |
| lecture ponctuelle, TCP sans TLS (PostgreSQL), $n = 21$ | (pas de TCP en clair : TLS toujours) | 35,81 µs [34,54 ; 37,71] | |
| lectures ponctuelles, 16 en cours sur une connexion (un pipeline de 16), par lecture, $n = 11$ | **1,46 µs** [1,34 ; 2,06] | 9,11 µs [8,78 ; 10,45] | 6,2× |
| lectures ponctuelles, 128 en cours, par lecture, $n = 11$ | 1,31 µs [1,29 ; 1,36] | | |
| 8 clients, une lecture en cours chacun : temps écoulé par lecture, $n = 11$ | **3,22 µs** [2,96 ; 3,47] | 6,54 µs [6,17 ; 7,39] | 2,0× |
| 64 clients, $n = 11$ | 3,14 µs [2,99 ; 3,71] | 7,00 µs [6,78 ; 7,68] | 2,2× |
| 256 clients, $n = 11$ | 2,88 µs [2,73 ; 3,94] | 12,83 µs [11,96 ; 13,75] | 4,5× |
| Q3, les factures impayées d'une ville (city-7 : 396 lignes de 2 valeurs), $n = 11$ | 0,487 ms [0,474 ; 0,526] | 0,662 ms [0,656 ; 0,699] | 1,4× |
| Q4, la somme et le nombre des impayés par ville (100 lignes, agrégées dans le serveur), $n = 11$ | 12,37 ms [11,35 ; 13,87] | 18,47 ms [18,36 ; 19,23] | 1,5× |
| une nouvelle connexion avec TLS et sa première requête, $n = 7$ | 2,60 ms [2,53 ; 2,76] | 4,28 ms [4,24 ; 4,56] | 1,6× |
| une nouvelle connexion, Unix socket (PostgreSQL y lance un nouveau processus backend, par un fork du système), $n = 7$ | | 2,03 ms [2,01 ; 2,04] | |

Ce que cela dit :

- **Un client** : une lecture ponctuelle coûte le round trip du noyau (deux appels système de chaque côté et deux
  réveils : les 9,32 µs de Ping) et 1,5 µs de travail du serveur (le décodage, la lecture de la vue, le codage). Le
  plancher de PostgreSQL lui-même, `SELECT 1`, est de 15,2 µs : son travail par instruction est plus grand que toute
  notre lecture. La cible du plan était 10 µs ; le round trip vide sur cette machine était de 8,46 µs quand la
  conception l'a mesuré et de 9,32 aujourd'hui, donc 10,8 est le plancher plus les mêmes 1,4-1,5 µs de travail. Seul
  le fait de ne pas faire le round trip descend en dessous ([lectures locales](#lectures-locales-g15) : 0,22 µs).
- **Beaucoup de clients** : la cible principale du plan, 8 clients à 4 µs au plus par lecture (PostgreSQL 6,2 µs quand
  la conception l'a mesuré, 6,5 aujourd'hui), tient : 3,22 µs. Avec un seul I/O domain, le serveur répondait toutes
  les 9,6 µs (le prototype) : ce sont les I/O domains qui font gagner (3 tours à chaque $k = 1, 2, 4, 8$ : 9,1-10,0 ;
  5,3-5,5 ; 2,9-4,0 et 2,1-3,1 µs ; 4, la valeur par défaut, tient 16 lectures en cours à 1,3-1,5 µs là où 8 domains
  donnaient 1,5-2,1). Le processus par connexion de PostgreSQL paie davantage à mesure que les connexions augmentent
  (12,8 µs à 256) ; nos threads dans 4 domains, non.
- **Pipelining** (plusieurs requêtes en cours sur une connexion, les réponses reliées par l'id) : 1,46 µs par lecture
  avec 16 en cours, 6,2 fois plus rapide que le pipeline de 16 de PostgreSQL, où le backend répond toujours dans
  l'ordre et analyse chaque instruction.
- **TLS** nous coûte 28,4 µs de plus que le Unix socket (39,2 contre 10,8) ; le round trip TLS d'OpenSSL lui-même, en
  C sur cette machine (64 octets dans chaque sens, le prototype de la conception), coûte 27,06 µs contre 16,04 en TCP
  en clair : 11,0 µs de TLS. Le nôtre ajoute environ 16 µs au TCP en clair (23,2 µs, le serveur de l'étape 1,
  $n = 11$) : les buffers en mémoire par lesquels OpenSSL travaille ici (une copie vers eux et une hors d'eux, et
  davantage d'appels à OpenSSL par lecture) coûtent le reste. Les deux côtés utilisent le cipher TLS 1.3 par défaut
  d'OpenSSL (AES-256-GCM) ; le prototype C, AES-128-GCM. La cible du plan était 36 µs : manquée de 3 µs ; toujours 1,3
  fois plus rapide que PostgreSQL avec TLS. Une nouvelle connexion TLS coûte 2,6 ms (une signature ECDSA par le
  serveur, les vérifications du client ; aucun certificat client), 1,6 fois moins que celle de PostgreSQL.
- **Q3 et Q4** passent par le socket sous forme de lignes (Q3) et d'agrégats calculés dans le serveur (Q4 : 100 lignes
  envoyées, pas 45 064) : 1,4 et 1,5 fois plus rapides que les plans d'exécution de PostgreSQL. Les deux côtés donnent
  les mêmes réponses : 396 lignes pour city-7, et 45 064 factures impayées dont la somme fait 2 248 567 111 centimes
  (un chargement neuf des mêmes données, générées à partir d'une même graine, `bench.exe read` ; PostgreSQL sur ses
  lignes), et les mêmes 100 factures (`sbench.exe check` contre `psql`).

**Écritures durables** (une nouvelle facture de 4 faits par écriture, chacune répondue après son fsync ; groupes par
seconde, $n = 7$, 3 s par mesure ; PostgreSQL : `INSERT` d'une ligne, `synchronous_commit = on`) :

| clients | Cepheus par le serveur | PostgreSQL 18.6 | Cepheus dans le processus (`bench.exe write`) |
|---:|---:|---:|---:|
| 1 | 166 [3 ; 297] | 240 [3 ; 302] | 155 [66 ; 310] |
| 16 | 1 234 [47 ; 2 438] | 1 616 [90 ; 2 482] | 1 737 [951 ; 2 269] |
| 64 | 7 110 [3 937 ; 9 549] | 6 059 [4 385 ; 9 488] | 3 555 [2 211 ; 9 113] |
| 256 | 17 850 [14 450 ; 24 870] | 17 417 [6 770 ; 22 737] | 13 103 [1 364 ; 21 513] |

Les deux côtés attendent le disque : une écriture est une part d'un fsync (group commit), et le fsync de ce SSD a pris
de 3 ms à plusieurs centaines de ms pendant que d'autres travaux utilisaient le disque entre les tours (le minimum de
3 écritures par seconde est un blocage du disque lui-même). Les intervalles se chevauchent à chaque nombre de
clients : le serveur ajoute un round trip (10 µs) à une écriture qui attend un fsync de quelques millisecondes, et les
deux bases sont égales ici dans le bruit du disque. La comparaison des écritures du moteur sur une machine calme est
dans [benchmarks](benchmarks.md#les-écritures-à-256-clients-avec-leurs-merges).

Les nombres bruts et les scripts : les fichiers de mesure de ce travail (pas dans le dépôt) ont été faits avec
`sbench.exe` et les commandes `pgbench` ci-dessus ; `sbench.exe` affiche un nombre par mesure (`ping`,
`get ADDR FACTS DEPTH N`, `clients`, `write`, `q`, `hs`).

## Ce qu'il ne fait pas encore

- Find rassemble les index words de sa réponse avant de les envoyer (plus haut) ; les subscriptions (`Watch`) et les
  forks ne passent pas encore par le protocole.
- Des lecteurs locaux sur d'autres machines (une replica, étape 6 ; Raft avec des leases entre serveurs, étape 7), et
  une seule copie partagée des pages pour beaucoup de lecteurs d'une même machine (chaque lecteur garde son propre
  cache : [ce que cela coûte](#ce-que-cela-coûte)).

Le client Cesia est l'étape 4 ([Cepheus depuis Cesia](cesia.md)) : un programme Cesia atteint une base par un serveur
seulement, par `cepheus.Connect`, et lit localement sur la machine du serveur. Ensuite : les subscriptions par le
réseau et plusieurs bases qui partagent un même fsync (étape 5), une replica (étape 6), Raft sur trois machines
(étape 7), des bases en mémoire avec `Expire` et `Incr` (étape 8). La bibliothèque OCaml ouvre encore un répertoire de
base dans son propre processus (`Cepheus.open_`) : c'est le moteur que fait tourner le serveur, et ce que pilotent ses
tests et ses benchmarks ; les programmes, en Cesia, passent par le serveur.
