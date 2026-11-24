# Le serveur

Cepheus tourne comme un serveur, comme le fait PostgreSQL : un seul processus sur une machine tient ses bases de
données, et les programmes s'y connectent. Cette page en dit tout : ce qu'est le serveur et pourquoi il est construit
ainsi, comment le faire tourner (`cluster.toml`, les tokens, c'est-à-dire les secrets que les programmes présentent
pour prouver leurs droits, les commandes, le démarrage, l'arrêt, le crash), un seul fsync (l'appel système qui attend
que les octets écrits soient vraiment sur le disque) pour les écritures de toutes ses bases (le commit buffer, un
journal propre au serveur que toutes ses bases partagent), le wire protocol (le format exact des
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
├── databases     each declared in cluster.toml: its writer and syncer (threads of the writers' domains), its merges,
│                 its session table (G14), its follow stream to the local readers and its visibility page (G15)
├── commit buffer DATA/server.wal.1 and .2: one fsync a round for the writes of every database (a domain of its own)
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
- **Le chemin vers plusieurs machines.** La réplication et Raft ([une replica](#une-replica), [un cluster de
  trois](#un-cluster-de-trois-raft)) vont de serveur à serveur ; un programme garde le même code.

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

[[peer]]                           # one; or several: a primary and its replicas (needs [tls], below)
name = "srv1"
address = "127.0.0.1:7401"         # host:port of this peer's port, mutual TLS, opened only with several peers

[clients]
socket = "/run/cepheus"            # the directory of the Unix socket .s.cepheus.PORT (PORT: listen's, or 7400)
listen = "0.0.0.0:7400"            # TCP for programs, always TLS: needs [tls]
domains = 4                        # the I/O domains, 1 to 64; default min(4, cores / 2)
max_connections = 512              # connections open at once (local readers' included), 1 to 65536; default 512
idle_timeout = 600                 # seconds without a whole request before a connection is closed; 0: never; default 600
question_timeout = 30              # seconds a question may take (a Find, a watch's first answer); 0: no limit; default 30

[tls]                              # made by `cepheus cluster init` (the CA and srv1) and `cepheus cluster cert`
ca = "/etc/cepheus/ca.pem"         # the cluster's CA: the certificates it signed are trusted
cert = "/etc/cepheus/srv1.pem"     # this server's certificate (its chain), signed by the CA
key = "/etc/cepheus/srv1.key"      # its private key, readable by the server's user only

[storage]
data = "/var/lib/cepheus"          # one directory a database inside it, and the server's own files
cache = "4G"                       # the page cache of the runs: K, M, G or bytes; default 1G

[log]
slow_ms = 200                      # a question or a write of this many ms or more gets a line; 0: none; default 200

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
  socket ouvert). À la limite, une nouvelle connexion prend la place de la plus ancienne connexion qui n'a encore
  montré aucun token, et celle-ci est fermée sans un mot (une connexion qui a montré son token n'est jamais prise :
  ceux qui se connectent sans rien envoyer ne peuvent pas tenir les programmes dehors) ; quand chaque connexion en a
  montré un, la nouvelle est fermée aussitôt : sur le Unix socket après une frame
  d'erreur (un message du protocole qui porte une erreur) `too_many_connections`, sur TCP sans un mot et avant son
  handshake TLS (les premiers échanges, où les deux côtés s'accordent sur des clés), pour qu'une connexion refusée ne
  coûte au serveur aucun handshake (son échange de clés et sa signature : une nouvelle connexion TLS entière coûte
  2,6 ms, des deux côtés, [mesurées plus bas](#la-vitesse-à-côté-de-postgresql)). Le log dit combien ont été refusées,
  au plus une fois par seconde. La valeur par défaut, 512, laisse de la place sous la limite par défaut de systemd, 1 024 descriptors par
  service (`LimitNOFILE`), que se partagent les fichiers des bases (un segment de journal, un fichier de run par
  niveau) ; relevez les deux ensemble. Un serveur à court de descriptors le dit dans son log et recommence à accepter
  dès que des connexions se ferment (`accept` échoue avec `EMFILE` ; la connexion attend dans la file du noyau).
- `idle_timeout` : une connexion doit envoyer une requête entière dans ce nombre de secondes après sa requête
  précédente, et doit prendre ce que le serveur lui envoie dans le même délai ; sinon le serveur lui envoie une frame
  d'erreur `idle` (id de requête 0) et la ferme. Avant son Hello, elle a 10 s depuis que le serveur l'a acceptée (ou
  `idle_timeout`, s'il est plus court) pour son handshake TLS et son Hello, quel que soit `idle_timeout` (0 compris) ;
  le client d'un programme abandonne après 5 s. Des octets qui arrivent au compte-gouttes sans former une requête ne
  gardent pas une connexion ouverte : l'horloge est regardée après chaque lecture, dans le handshake TLS et aussi dans
  un record TLS (un bloc chiffré du flux TLS), si bien que l'autre bout qui envoie un octet à la fois, chacun dans le
  timeout du socket, est fermé (l'attaque Slowloris, R. Hansen 2009 : tenir les connexions d'un serveur en envoyant
  très lentement). La bibliothèque d'un
  programme garde sa connexion en vie avec `Ping`, ou se reconnecte : le client OCaml renvoie une lecture (Open, Get,
  Find, Ping, status) sur une nouvelle connexion après une connexion rompue, dans son budget de retries (le nombre de
  nouvelles tentatives permis), comme il le fait pour les écritures (G14). Le `idle_session_timeout` de PostgreSQL est
  désactivé par défaut et son `authentication_timeout` est d'une minute ; le `timeout` de Redis est désactivé par
  défaut.
- `question_timeout` : une question (un Find, la première réponse d'un Watch) finit avec l'erreur `timeout` une fois
  qu'elle a tourné ce nombre de secondes, son message nommant le temps ; le travail s'arrête là (il est regardé tous
  les 1 024 candidats de chacun de ses domains, une lecture de l'horloge monotone, celle qu'un changement de l'heure ne
  fait pas bouger, ce qui coûte moins de 1 % à une question, mesuré). Un programme peut donner à une question un temps
  plus court (`timeout` en Cesia, `?timeout` en OCaml : protocole 6) ; un plus long ne compte que d'un token admin,
  pour qu'un token qui peut lire ne prenne pas plus des cœurs du serveur que le serveur n'en donne à chaque programme.
  Une question dont le programme a fermé sa connexion s'arrête aussi, ses domains rendus (la connexion est regardée
  avec le `POLLRDHUP` de `poll` au plus toutes les 10 ms de la question : le `client_connection_check_interval` de
  PostgreSQL, désactivé par défaut chez lui). Le `statement_timeout` de PostgreSQL est désactivé par défaut ; SQLite
  n'a pas de réglage à lui (le `sqlite3_progress_handler` ou le `sqlite3_interrupt` d'un programme) ; Datomic prend le
  `:timeout` d'une requête. Les écritures n'ont pas de temps : un groupe est tout ou rien, et les budgets du writer le
  bornent ([limites](limits.md#les-écritures)).
- `slow_ms` : une question (un Find, la première réponse d'un watch) ou une écriture qui prend ce nombre de
  millisecondes ou plus au serveur, de sa requête à sa réponse (celle d'une écriture une fois son groupe durable),
  reçoit une ligne dans le log du serveur, ses valeurs laissées de côté : `cepheus: slow question: database shop, token
  shop-web, 412.3 ms, 18204331 candidates, 20 rows, ok: find give x0 x1 where [x0 invoice/status ?] [x0 invoice/total
  x1] sort column 1 desc limit 20`. De 0 à 3 600 000 (une heure) ; 0 : aucune ligne. Ce que tient la ligne, et comment
  la lire : [les questions et les écritures lentes](production.md#les-questions-et-les-écritures-lentes).

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
name = "billing"
hash = "blake2b-256:0c7d...a2"
databases = { shop = { read = ["client", "invoice"], add = ["invoice"] } }
[[token]]
name = "ops"
hash = "blake2b-256:51aa...07"
admin = true
```

- `read` : Open, Get, Find sur cette base. `write` : la lecture et Write. `admin = true` : les opérations du serveur
  (`status`) ; aucun droit sur les données à lui seul.
- **Les droits par kind**, `{ read = [...], add = [...] }` : le droit de lire, et d'ajouter, seulement les kinds
  nommés. Le **kind** d'une propriété (sa sorte) est son nom jusqu'à son premier `/` : `invoice/Total` est du kind
  `invoice`, comme le nomme le `cepheus.Kind("invoice", ...)` du client Cesia. Voir [les droits](#les-droits-g16).
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
cepheus status [--format text|prometheus] --config FILE
                                         what the server holds and does, and its times; an admin token in
                                         CEPHEUS_TOKEN; --format prometheus: in Prometheus's text format
                                         (production.md, "What to watch")
cepheus token add NAME --database DB=read|write|read:KIND,...;add:KIND,... ... [--admin] --config FILE
                                         a new token, printed once on stdout (cph_ and 43 characters); its hash goes
                                         to tokens.toml
cepheus token list --config FILE         names and rights (never the tokens)
cepheus token remove NAME --config FILE  removed: its connections are refused at their next request
cepheus replicate PEER --config FILE     this server, stopped, becomes a replica of PEER at its next start
                                         (DATA/cepheus.role; [a replica](#a-replica))
cepheus promote [--force] --config FILE  the running replica becomes a primary; an admin token in CEPHEUS_TOKEN;
                                         --force without its primary's handover
cepheus verify DIR                       a database's files checked as they are, nothing changed: every frame,
                                         every page, the runs against the journal, the vault's records; each damage
                                         named (operations.md, "Verification")
cepheus backup --config FILE DEST        every database of FILE's server copied while it serves, into DEST/DATE,
                                         each copy checked, cut after its last whole frame, forced; no token
                                         (production.md, "Backups")
cepheus restore SRC DIR [--to-group N | --to-time T] [--replace]
                                         a backup restored into DIR, to its end, a group or a time, opened and
                                         checked, in a new epoch; --replace moves a database in DIR aside
cepheus verify|backup|restore --help     the usage, and the exit status: 0 done, 1 damage found, 2 refused or failed
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
sessions, G14) ; `role` et les lignes des replicas (une replica est un second serveur qui garde une copie des bases
d'un autre : [une replica](#ce-que-sert-une-replica)). Après elles, les temps du serveur : le cache de pages et le
disque, et pour chaque base les octets de son journal et de ses runs, ses merges, et ses questions et ses écritures
(les comptes depuis le démarrage, p50, p99 et maximum sur la dernière minute) ; `--format prometheus` affiche les
mêmes nombres dans le format texte de Prometheus. Chaque ligne : [ce qu'il faut surveiller](production.md#ce-quil-faut-surveiller).

### Les fichiers du serveur

```
DATA/cepheus.lock          held (lockf) while the server runs: one server a data directory; holds its pid
DATA/cepheus.server        the server's id, made at its first start
DATA/NAME/                 a database: its files as in operations.md, and
DATA/NAME/sessions         its session table, a checkpoint (G14): written every second while writes come, and at stop
DATA/NAME/shared           the database is the server's: its journal is forced through the commit buffer
DATA/NAME/vault/           its files' bytes ([the vault](vault.md)), made at its first file
DATA/cepheus.role          the server's role, mode 0600: absent, a primary; replica_of (cepheus replicate), or
                           promoted_from and the epochs it opened (cepheus promote) ([a replica](#a-replica))
DATA/NAME/epochs           the database's history of promotions, mode 0600: absent, epoch 1 from group 1
DATA/NAME/handover         on a replica, the group its primary's clean stop handed over, mode 0600
CONFIG/vault.key           the master key of every vault of the server: 32 random bytes, mode 0600, beside
                           cluster.toml (never in DATA: a copy of the data opens no file without it), made at the
                           first file; keep a copy apart from the data, since without it no file opens
DATA/server.wal.1, .2      the commit buffer (below): two files that alternate; removed at start, once their frames
                           are in the journals, and at a clean stop
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
serveur sur les mêmes données est refusé : G9 étendue au serveur) ; lire les fichiers du commit buffer
([plus bas](#plusieurs-bases-un-seul-fsync--le-commit-buffer)) ; ouvrir chaque base, en parallèle (un domain chacune, au
plus `domains` à la fois), chacune avec sa recovery (ce que fait une ouverture après un crash pour retrouver le
dernier état durable, [exploitation](operations.md#louverture-et-la-recovery)), qui récrit d'abord dans son journal
les frames (les blocs du journal, écrits chacun d'un seul tenant) que le buffer garde pour elle, et sa table des
sessions (son checkpoint, une copie sauvegardée de la table, puis le journal qui le suit) ; vider le buffer et lancer
ses rounds (ses fsyncs communs, décrits plus bas) ; ouvrir les listeners (les sockets sur
lesquels le serveur attend les connexions ; un fichier de socket laissé par un serveur mort est supprimé, un fichier
sur lequel répond un serveur vivant est refusé) ; démarrer les I/O domains ; dire à systemd que le serveur est prêt
(`READY=1` sur `$NOTIFY_SOCKET`, un seul datagramme : `sd_notify(3)`). Le serveur affiche une ligne : la durée des
ouvertures, le groupe de chaque base, les listeners.

**Arrêt** (`SIGTERM`, `SIGINT`, `cepheus stop`). Plus aucune nouvelle connexion ; les nouvelles requêtes reçoivent
`Err stopping` ; les écritures en cours deviennent durables et reçoivent leur réponse ; chaque base est fermée
proprement (son journal forcé, son marqueur `closed` : l'ouverture suivante ne force rien) et sa table des sessions
sauvegardée ; les fichiers du commit buffer sont supprimés ; le fichier du socket est supprimé ; le serveur sort avec
le code 0.

**Crash** (kill -9, coupure de courant). Chaque base fait sa recovery comme le moteur le fait à son démarrage suivant
(G1 à G13), avec les frames que le commit buffer a gardées ; les tables des sessions sont reconstruites à partir de leurs checkpoints et du journal (G14). La
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

## Plusieurs bases, un seul fsync : le commit buffer

**Pourquoi.** Une écriture est confirmée une fois sa frame durable, et rendre des octets durables coûte un **fsync**
(l'appel système qui ne revient qu'une fois que le disque tient ce qui a été écrit dans un fichier : 3 ms ou plus sur
le SSD de cette machine). Dans une même base, les écritures qui arrivent pendant qu'un fsync tourne partagent le
suivant (group commit, [architecture](architecture.md#le-journal--un-write-ahead-log)). D'une base à l'autre, elles ne
le partageaient pas tant que chaque base forçait son propre journal : 64 bases écrites à la fois faisaient 64 fsyncs
de 64 fichiers, et une écriture attendait 24,1 ms à la médiane, contre 3,07 ms avec une seule base écrite
(`sbench.exe mwrite`, $n = 5$, avant le buffer). Les bases de PostgreSQL partagent un seul **WAL** (write-ahead log :
le fichier où chaque changement est rendu durable avant de compter), si bien que les commits de toutes se groupent.

**Ce qu'il fait.** Le serveur tient un journal à lui, le **commit buffer** (`DATA/server.wal.1` et `.2`,
`src/wal.ml` ; la disposition de ses octets dans [formats](formats.md#les-fichiers-du-serveur)) :

```
database d1: frame -> d1's journal (written, no fsync) --+
database d2: frame -> d2's journal (written, no fsync) --+--> a round: d1's frame | d2's frame | ...
database dN: frame -> dN's journal (written, no fsync) --+      appended to DATA/server.wal.N, one fsync,
                                                                then each of its frames is confirmed
```

Le syncer de chaque base (le thread qui fait les fsyncs de son journal) écrit sa frame dans son journal sans fsync, en
donne une copie au buffer, et attend la confirmation de cette frame avant d'écrire la suivante (une seule frame en vol
par base : la recovery en a besoin, plus bas). Un **round** (une tournée du buffer) prend toutes les frames venues
pendant que le round précédent était forcé, les ajoute en un seul enregistrement au fichier actif du buffer, et le
force une fois ; puis chaque frame du round est confirmée. Un seul round est en vol à la fois, si bien qu'avec 64
bases écrites à la fois, un fsync confirme jusqu'à 64 frames. Une frame qui arrive quand le buffer est au repos
(aucun round écrit ou en attente) et qu'aucun journal n'en force une à lui est forcée dans son propre journal, comme
avant le buffer : une base écrite seule ne paie aucune seconde écriture, et les frames des autres qui arrivent
entre-temps partagent le round suivant. `cepheus status` les compte : `commit_buffer.rounds`, `commit_buffer.frames`
(les frames que les rounds ont forcées) et `commit_buffer.alone` (les frames forcées dans leur propre journal).

Chaque journal reste la vérité de sa base (ses runs, sa recovery, ses sauvegardes et ses lecteurs locaux sont comme
avant) ; le buffer ne garde une seconde copie de chaque frame que jusqu'à un **checkpoint** de son journal (un fsync
de celui-ci). Ses deux fichiers alternent : quand le fichier actif dépasse 64 MB, le round suivant va dans l'autre,
une fois celui-ci propre ; le thread de nettoyage du serveur force chaque journal qui a des frames dans l'ancien
fichier, après quoi ce fichier peut être recommencé (son en-tête et son premier round écrits à côté, forcés, puis
renommés par-dessus lui). Un journal est aussi forcé quand il quitte un segment, avant qu'un merge ne nomme un run
(aucun run ne repose sur des frames que seul le buffer tient), et à la fermeture. Une frame de plus de 1 MiB, et la
frame d'un grand groupe, est forcée dans son propre journal et pas copiée : écrite deux fois, elle coûterait plus que
son propre fsync.

**Recovery.** Après une coupure de courant, les frames qu'un journal a écrites après son dernier fsync peuvent chacune
être perdues, gardées ou torn (déchirées : une partie seulement de leurs octets a atteint le disque), l'une
indépendamment de l'autre : la règle propre d'un journal (une fin torn est coupée ; une frame qui se vérifie après une
qui ne se vérifie pas est un dommage) couperait des frames confirmées, ou prendrait pour un dommage un trou suivi d'une
frame gardée. Donc au démarrage, avant d'ouvrir ses bases, le serveur lit les deux fichiers du buffer (le plus récent
peut finir par un round torn : celui qui était en vol au crash, jamais confirmé) ; l'ouverture de chaque base récrit
les frames que le buffer tient pour elle à leur place dans son journal, même là où le page cache (la copie des
fichiers que le noyau garde en mémoire) les montre déjà (un fsync qui a échoué a pu marquer ces pages clean,
c'est-à-dire identiques au disque : seule une écriture les rend à nouveau dirty, à écrire,
[G13](guarantees.md#g13-on-ne-se-fie-jamais-à-un-fsync-qui-a-échoué)), et les force ; chaque frame placée avant la dernière d'entre
elles et que le buffer ne tient pas doit se vérifier (elle a été forcée : sinon `Damaged`) ; la règle propre du journal
prend ensuite ce qui suit, au plus la seule frame en vol. Puis les deux fichiers sont supprimés et les rounds
commencent. Un arrêt propre force chaque journal et supprime les fichiers : un démarrage après lui ne lit rien.

**Les pannes.** Une écriture ou un fsync du buffer qui échoue, ou ceux d'un journal à un checkpoint, arrête le
buffer : chaque écriture suivante échoue avec `Io` et plus rien n'est confirmé
([G10](guarantees.md#g10-arrêt-sur-une-erreur-du-disque)) ; le round qui a échoué est aussitôt retranché de son fichier ; la
base dont l'écriture a échoué s'arrête, et le serveur sort en moins d'une seconde, comme plus haut. Une base ouverte
par un serveur est refusée par le propre processus d'un programme après un crash, tant que le serveur n'a pas démarré
une fois dessus : [exploitation](operations.md#une-base-dun-serveur), où le retour à une version antérieure est
expliqué aussi.

**Ce qu'il gagne et ce qu'il coûte** (2026-11-12, la machine des autres benchmarks, builds release ; `sbench.exe
mwrite` : un serveur de 64 bases vides démarré sur une copie fraîche de celles-ci, D bases écrites à la fois pendant
5 s, W writers chacune ; cette version contre main 1b12c35, celle d'avant le buffer, alternées dans chaque tour, chaque
exécution sous le lock des benchmarks et sur une machine calme ; $n = 7$ tours ; des médianes, le rapport avec / avant
dans chaque tour, et des intervalles entre la plus petite et la plus grande valeur, 98,4 %) :

| écrit | groupes par seconde, avant / avec | rapport par tour | attente à la médiane, avant / avec |
|---|---|---|---|
| 64 bases, 1 writer chacune | 2 637 / 5 870 | 2,20 [1,70 ; 3,82], plus haut dans 7 tours sur 7 | 22,5 / 8,0 ms |
| 16 bases, 1 writer chacune | 1 423 / 1 498 | 0,98 [0,88 ; 1,46] | 9,98 / 6,75 ms (plus basse dans 7 sur 7) ; p99 27,0 / 35,6 ms |
| 1 base, 1 writer | 308 / 263 | 0,86 [0,66 ; 1,21] | 2,86 / 2,99 ms |
| 1 base, 16 writers | 2 447 / 2 083 | 0,88 [0,27 ; 1,08] | 5,73 / 6,01 ms |

- À 64 bases, un fsync confirme les frames de beaucoup d'entre elles : 2,2 fois les écritures, une écriture qui
  attend trois fois moins longtemps.
- À 16, l'attente médiane baisse d'un tiers, mais les écritures par seconde ne montent pas : les écritures les plus
  lentes attendent plus longtemps (p99 27,0 / 35,6 ms), et l'intervalle du rapport contient 1. Un round tient alors
  8 frames en moyenne (`cepheus status` après 2 s : 441 rounds, 3 526 frames, 1 frame seule). Ces 16 bases ont tourné
  juste après les 64 : la mesure plus bas, dans l'autre ordre, trouve 1,55 fois les écritures.
- Une base écrite seule a ses frames forcées dans son propre journal (la règle plus haut ; `cepheus status` : aucun
  round). La première version du buffer, sans cette règle, rendait les 16 writers d'une base 18 % plus lents (2 240 /
  1 843 groupes par seconde, l'attente médiane plus haute dans 7 tours sur 7) ; avec elle, la différence est dans le
  bruit (l'intervalle de chaque rapport contient 1), et de même sur une base de 1 M de faits (`sbench.exe write`,
  $n = 5$, intervalles de 93,8 %) : un client 305 / 287 groupes par seconde (rapport 0,95 [0,83 ; 1,28]), 16 clients
  2 296 / 2 145 (0,94 [0,56 ; 1,43]). L'attente médiane est pourtant de 4 à 7 % plus haute dans chacune de ces quatre
  mesures : un petit coût peut rester, que ces tours ne savent pas distinguer du bruit.
- Un démarrage après un arrêt propre (64 bases, $n = 7$) : 215 / 199 ms (rapport 1,10 [0,23 ; 1,62]). Le premier
  démarrage de cette version sur des bases faites avant elle écrit un marqueur `shared` dans chacune, avec un fsync de
  son répertoire : à 64 bases 849 / 1 250 ms, une fois.

**Mesuré à nouveau** avec les chargements en chunks (par morceaux) et les lectures de l'ouverture dans l'ordre du
fichier (537d03a contre main 1b12c35, la même méthode), les cas dans l'autre ordre : une base d'abord, puis 16, puis
64, pour qu'aucun cas ne commence pendant que le disque écrit encore ce qu'une exécution de 64 bases a laissé. $n = 8$
tours (21 étaient prévus ; une coupure de courant a interrompu le 9e, et seuls les tours entiers sont gardés), des
intervalles entre la plus petite et la plus grande valeur, 99,2 % :

| écrit | groupes par seconde, avant / avec | rapport par tour | attente à la médiane, avant / avec |
|---|---|---|---|
| 1 base, 1 writer | 261 / 277 | 1,10 [0,59 ; 1,73], plus haut dans 5 tours sur 8 | 3,17 / 2,94 ms |
| 1 base, 16 writers | 2 283 / 2 374 | 1,03 [0,80 ; 1,22], plus haut dans 5 sur 8 | 5,94 / 5,76 ms |
| 16 bases, 1 writer chacune | 1 284 / 2 049 | 1,55 [1,17 ; 2,10], plus haut dans 8 sur 8 | 10,4 / 6,48 ms (plus basse dans 8 sur 8) ; p99 29,7 / 23,9 ms |
| 64 bases, 1 writer chacune | 2 841 / 6 356 | 2,25 [1,64 ; 4,17], plus haut dans 8 sur 8 | 21,9 / 7,56 ms ; p99 47,0 / 29,6 ms |

- L'ordre fait la différence à 16 bases. Le buffer écrit chaque frame deux fois : une fois dans le buffer, forcée sur
  le disque, et une fois dans le journal de sa base, laissée dans la mémoire du système jusqu'à ce que le système
  l'écrive (ces pages en mémoire pas encore sur le disque sont les dirty pages, `Dirty` dans `/proc/meminfo`). Après
  une exécution de 64 bases, l'exécution suivante commence avec 3,4 à 10,3 MB de dirty pages, contre 0,3 à 0,9 MB
  avant le buffer, et le système de fichiers les écrit pendant cette exécution (un commit de btrfs de 814 ms est tombé
  dans l'une). Passées en premier, 16 bases obtiennent 1,55 fois les écritures et un p99 plus bas, dans 8 tours sur 8
  (sign test, le test du signe : p = 0,008).
- Une base écrite seule : aucun coût dans l'un ou l'autre ordre (16 writers juste après 64 bases, $n = 7$ : rapport
  0,97 [0,82 ; 1,19] ; en premier, plus haut : 1,10 et 1,03). Un coût plus petit que le bruit de ces tours n'est pas
  exclu.

**Testé par** `test/wal_sim.ml` (trois bases qui partagent un buffer dont les fichiers alternent après 300 à
3 300 octets : écritures, rounds, nettoyages, merges, grands groupes et longues frames, morts du processus, coupures de
courant, crashs à l'intérieur de n'importe quel appel au disque, ceux de la recovery aussi, fsyncs du buffer et des
journaux qui échouent, une version sans le buffer qui ouvre une base après un crash ; après chaque recovery, chaque
base tient chaque groupe confirmé, exactement les groupes écrits, dans l'ordre ; `BUFFER_SEEDS`, 300 dans
`tools/test.sh`), `test/exhaustive.ml` partie 6 (chaque point de crash d'une exécution fixe de deux bases, chaque
fsync de celle-ci échouant à son tour, avec une réouverture dans le même boot), et `test/server_crash.ml` (un vrai
serveur de deux bases, tué 20 fois sous des clients qui écrivent : l'écriture de chaque reçu est là, une fois).
**Vérifié par model checking** (un programme parcourt tous les états d'un modèle du système) :
`spec/CommitBuffer.tla` ([tests](testing.md#model-checking)).

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
  s'il annonce 4 GiB, ne peut pas faire allouer cette mémoire au serveur. Avant Hello, la limite est de 4 KiB :
  l'autre bout, tant qu'il n'a montré aucun token, tient au plus 64 KiB de la mémoire du serveur. Un nombre annoncé dans un corps (de faits,
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
| 1 Hello | la version en varint (1 à 6), le token en string, le programme en string, la session en varint (0 : une nouvelle) | Welcome : l'id du serveur, l'id du cluster, la session, la limite des frames, la limite des écritures en cours ; un second Hello sur une connexion est `invalid` (son token reste celui du premier) |
| 2 Open | le nom de la base | Opened : le handle (le numéro de la base ouverte sur cette connexion), le groupe le plus récent, les propriétés (id, nom, code du type, many, unique) ; au-delà de la limite des frames, en frames d'environ 1 MiB de propriétés, toutes sauf la dernière avec `more`, chacune avec son handle, son groupe et son nombre |
| 3 Get | handle, chose | Facts : le groupe de la vue, le nombre, (propriété, valeur)... ; au-delà de la limite des frames, en frames d'environ 1 MiB de faits, toutes sauf la dernière avec `more`, chacune avec son groupe et son nombre |
| 4 Find | handle, question, select, puis, seulement quand la question en a, ses opérateurs et son ordre : un octet 1, ses opérateurs (un nombre, puis chacun : 0 un pattern, 1 un range, 2 In : variable, nombre, valeurs, 3 Not : nombre, éléments, 4 Or : nombre d'alternatives, chacune un nombre et ses éléments, 5 Prefix : variable, texte), Sort (un nombre, puis la colonne de chaque clé et un octet 1 quand elle est décroissante), Limit (0 : aucune), After (un octet 0, ou 1, un nombre et les valeurs) ; puis, depuis la version 6 et seulement quand le programme en donne un, le temps de la question en millisecondes (de 1 à une semaine ; l'ordre est alors envoyé, vide s'il le faut) | Rows (en frames d'environ 1 MiB, toutes sauf la dernière avec `more` ; un Give sans Sort qui dépasse les cellules que le serveur tient, lignes fois colonnes, est envoyé à mesure que ses lignes sont trouvées, aucune n'est tenue) : le groupe de la vue, les colonnes, le nombre, les valeurs ligne par ligne |
| 5 Write | handle, serial, floor, by (zigzag), why, nombre, opérations | Receipt : le groupe, le nombre, (id temporaire de la nouvelle chose, son id)... |
| 6 Ping | des octets quelconques | Pong : les mêmes octets |
| 7 Admin | "status" | Status : le nombre, (clé, valeur)... |
| 8 Follow | handle (sur le Unix socket seulement) | Start : l'id de la base, le numéro de visibilité, le nombre, (lo, hi) de chaque run, du plus récent au plus ancien ; les descriptors de `visible` et de chaque run voyagent avec son premier octet. La connexion est alors le follow stream de la base ([lectures locales](#lectures-locales-g15)) |
| 11 Watch | handle, question, select, from (le groupe de la réponse que tient le programme ; 0 : aucune), puis ses opérateurs, Sort et Limit tels que Find les code, quand il en a (pas d'After ; Sort et Limit depuis la version 5), et le temps de sa première réponse comme celui de Find (version 6) | des pushes (des messages que le serveur envoie sans qu'on les lui demande) sur l'id du Watch, jusqu'à Unwatch ou une erreur ([questions vivantes](#les-questions-vivantes-watch)) |
| 12 Unwatch | l'id du Watch | Unwatched |
| 14 Put (version 3) | handle, serial, floor, by (zigzag), why, le kind du fichier, le nom, le media type, le propriétaire (0 : la clé propre de la base), cold (un octet), puis les premiers octets du fichier ; le flag `more` quand des Pieces suivent | Receipt du groupe de ses faits (kind/Name, Size, Type, Owner, Content), une fois ses octets et ce groupe durables ([le vault](vault.md) : le vault de fichiers, où le serveur garde les octets des fichiers) |
| 15 Piece | d'autres octets du Put de cet id ; `more` sauf sur le dernier | (la réponse du Put) |
| 16 Load | handle, chose, la propriété Content du kind, from, length (zigzag ; -1 : jusqu'à la fin) | les octets, en frames de 1 MiB, toutes sauf la dernière avec `more` |
| 17 Erase | handle, owner (une chose, > 0 ; réservé à un token qui écrit toute la base) | Erased |

Sur un follow stream, le serveur pousse (id de requête 0) :

| kind | corps |
|---|---|
| 9 frame | le numéro (0 : une partie du rattrapage, pas visible à elle seule), le premier groupe, le nombre, puis les groupes tels que le journal les code ; une frame longue continue dans des frames du flag `more` qui ne portent que des octets |
| 10 runs | le numéro (le lecteur abandonne ses états sous des numéros plus petits), le nombre, (lo, hi) de chaque run, du plus récent au plus ancien ; leurs descriptors voyagent avec son premier octet |
| 13 durable | le numéro : les frames envoyées sous ce numéro et en dessous sont durables (les questions vivantes du lecteur donnent leurs changements) ; un lecteur qui ne connaît pas ce kind le saute |

- Une **question** est une donnée : des variables, des patterns (chose, propriété, valeur, chacune une variable, une
  chose ou une valeur) et des intervalles (ranges), comme `Cepheus.query` ([API](api.md)) ; aucun code ne traverse le
  réseau, et chaque propriété est vérifiée contre le schéma de la base.
- **select** : `Give [x...]` donne ces variables de chaque réponse, dans cet ordre (aucune : toutes) ;
  `Group ([k...], [a...])` donne une ligne par clé distincte : les variables de la clé, puis les agrégats `Count`,
  `Sum x` (int, money), `Min x`, `Max x` (int, money, date), calculés dans le serveur sans construire les réponses (Q4
  plus bas : 100 lignes au lieu de 45 064).
- **Les versions.** La version 6 ajoute le temps d'une question (celui d'un Find, de la première réponse d'un Watch)
  et rien d'autre : un programme de version 6 se connecte à un serveur de 5 en 5, et une question avec un `timeout`
  est refusée dans le programme (`invalid` : « this server speaks protocol 5: a question's timeout needs a server of
  protocol 6 ») avant d'être envoyée, puisqu'un serveur plus ancien refuse les octets après la question ; le
  `question_timeout` propre au serveur borne chaque question quelle que soit la version du programme. La version 5
  ajoute le Sort et le Limit d'un Watch ([questions vivantes](#les-questions-vivantes-watch)) et rien d'autre :
  un programme de version 5 se connecte à un serveur de 4 en 4, et un watch avec Sort ou Limit est refusé dans le
  programme (`invalid` : « this server speaks protocol 4: a watch with Sort and Limit needs a server of protocol 5 »)
  avant d'être envoyé, puisqu'un serveur plus ancien refuse l'ordre d'un Watch. La version 4 ajoute l'opération `Incr` (plus bas : ajouter un nombre à un compteur) et rien d'autre : un programme de version 4 se
  connecte à un serveur de 3 en 3, et un groupe avec un `Incr` est refusé dans le programme (`invalid` : « this server
  speaks protocol 3 or older: Incr needs a server of protocol 4 ») avant d'être envoyé. La version 3 ajoute les
  fichiers (Put, Piece, Load, Erase) et rien d'autre : un programme de version 3 se connecte à un serveur de 2 en 2
  (comme plus bas), et un fichier est refusé dans le programme (`invalid` : « this server speaks protocol 2 or older:
  files need a server of protocol 3 »). La version 2 ajoute les opérateurs et l'ordre de la question (plus bas) et rien
  d'autre ; un serveur parle les versions 1 à 6, et répond de la même façon à chaque connexion. Une bibliothèque dit 2
  dans Hello ; un serveur de version 1 se contente de la refuser (`version`) et ferme, et la bibliothèque se reconnecte
  en 1 : ses questions de patterns et de ranges reçoivent leur réponse comme avant, et une question avec `Not`, `Or`,
  `In`, `Prefix`, Sort, Limit ou After est refusée dans le programme (`invalid` : « this server speaks protocol 1: ...
  need a server of protocol 2 ») plutôt qu'envoyée. Un programme de version 1 est servi par un serveur de 2 exactement
  comme avant.
- **L'ordre** : Sort, Limit et After sur les colonnes du select ([pages](cesia.md#sort-limit-et-after--des-pages)). Il suit
  le select seulement quand la question en a un, si bien que toute autre question est codée comme avant ; un serveur
  qui ne le connaît pas refuse un tel Find (« bytes after the request ») plutôt que d'y répondre sans trier.
- Une **opération** : 0 Add, 1 Retract, 2 Expect une valeur, 3 Expect aucune ; puis la chose (en zigzag : un id
  négatif est une nouvelle chose du groupe), la propriété, la valeur. 4 Incr (version 4) : la chose, la propriété,
  `by` (zigzag), puis un octet 0, ou 1 suivi de la chose (zigzag) et de la propriété d'`into`. Un token ajoute un
  `Incr` quand il peut ajouter au kind du compteur et à celui d'`into` ([les droits](#les-droits-g16)).
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
| Cepheus | longueur, id, kind, flags ; le codage des valeurs du journal | jusqu'à la limite qu'annonce Welcome | **par id, dans le désordre** | `Watch` : la réponse d'une question, puis ses changements exacts, sur l'id du Watch | des valeurs `{code, message}` | TCP, et le serveur cesse de lire à la limite ; un watch dont la connexion tient 8 MiB non envoyés se termine par `lagging` |

### Les questions vivantes (Watch)

Un `Watch` tient une question à jour : c'est une question vivante (live question), qu'on appelle aussi un watch. Ses
pushes arrivent sur l'id du Watch, kind 11, chacun un message :

```
answer = 0 | group | cols | count | rows                          the whole answer at group
change = 1 | group | cols | added: count | rows | removed: count | rows
same   = 2 | group                                                 nothing the question reads changed since from
```

- Le premier push est la réponse au groupe durable le plus récent, ou `same` (« le même ») quand `from` est donné, que
  le ring des changements récents du serveur (un anneau qui garde les changements de son dernier million de faits, les
  plus anciens remplacés par les nouveaux) couvre chaque groupe après lui, et qu'aucun d'eux ne touche les patterns de
  la question (une propriété et ses constantes). Ensuite un `change` pour chaque groupe durable qui change les lignes,
  dans l'ordre des groupes. Une longue réponse ou un long changement continue dans des frames d'environ 1 MiB avec le
  flag `more`, chacune de la même forme, ses lignes ajoutées à celles du message.
- **Durable d'abord.** Un changement se calcule pendant que sa frame est forcée sur le disque (le syncer passe la frame
  au hub de la base, le thread qui calcule ses questions vivantes, au moment où il la prend) et part une fois la frame
  durable : rien de ce qu'un crash pourrait défaire n'est jamais montré.
- **Une erreur termine le watch** : `lagging` (« en retard » : la connexion tient plus de 8 MiB de pushes qu'elle n'a
  pas pris, ou le hub a pris 65 536 frames de retard, ou un grand groupe dans sa propre frame a changé la base : le
  programme relance le watch depuis le groupe de son dernier message) ; `denied` (le token n'a plus le droit de lire la
  base : G16 se vérifie à chaque message, la table des tokens n'étant relue que quand elle a changé) ; `stopping` (le
  serveur ou la base s'arrête) ; `internal` (le serveur a échoué sur la question du watch à une frame, ce qui ne
  termine que les watches de cette question, ou sur les watches de la base dans leur ensemble, ce qui les termine
  tous : relancer le watch ; le log dit pourquoi).
- **Personne n'attend un watch.** Le writer et le syncer donnent chaque frame à une queue et continuent ; un thread de
  hub par base suivie l'évalue, tous les threads de hub dans un domain à eux (créé au premier `Watch` : rien ne tourne
  pour une base que personne ne suit) ; un push va dans le buffer de sa connexion, qu'un thread de la connexion envoie,
  si bien qu'un programme qui ne lit jamais ne retient que sa propre connexion (testé : `test/server_limits.ml` ;
  mesuré plus bas).
- **Le follow stream** porte `durable` (kind 13) après que chaque frame est durable : un lecteur local calcule les
  questions vivantes de son propre programme à partir des frames qu'il applique, pendant le fsync du serveur, et les
  donne à `durable`. Un lecteur d'une version plus ancienne saute ce kind.
- **Sort et Limit** (version 5) : les lignes du watch sont celles de Find avec les mêmes Sort et Limit au groupe de
  chaque message, et les lignes de chaque message viennent dans l'ordre (celles de la réponse, les lignes ajoutées et
  les lignes retirées d'un changement). Le hub tient la fenêtre (window) de chaque watch de ce genre, k lignes et sa
  dernière : les lignes d'un frame sont comparées à la dernière, et une ligne qui quitte la fenêtre est remplacée par
  un seul Find After la dernière ligne, Limit les lignes qui manquent, sur le fil du hub, avec la question même du watch
  (les droits pour lesquels sa première réponse a été vérifiée) et le budget de questions du serveur (au-delà, ce watch
  se termine `too_large`). Un Limit de plus de 100 000, un After, un Limit sans Sort, et des agrégats avec Sort ou Limit
  sont refusés (`invalid`) : [Sort et Limit dans un watch](cesia.md#sort-et-limit-dans-un-watch), la règle vérifiée par
  model checking dans `spec/WatchWindow.tla`.
- **Les bornes.** Une connexion garde au plus 1 024 watches, le serveur 65 536, et ce que leurs fenêtres et leurs
  groupes gardent entre deux messages compte comme des cellules, au plus celles d'une réponse pour une connexion ; la
  première réponse d'un watch est construite dans les bornes d'une réponse, sous le lock du hub. Au-delà de l'une
  d'elles, le Watch est `too_large` ; un watch que le serveur a terminé ne compte plus
  ([limites](limits.md#le-serveur)).
- Ce qu'est un changement, et comment il se calcule : [Cepheus depuis Cesia](cesia.md#watch--les-questions-vivantes) ;
  la règle de reprise est vérifiée par model checking dans `spec/Watch.tla` (pas de trou, pas de répétition, les lignes
  jamais plus anciennes que le dernier message : 1 015 657 états ; sans le test des patterns touchés ou sans la borne
  du ring, TLC trouve un contre-exemple).

### Ce que coûte un watch

Mesuré sur la machine des autres benchmarks (4 cœurs, 8 threads, SSD SATA, Linux), builds de release, la base de 1 M
de faits (`bench.exe load`), chaque côté d'une comparaison sur un serveur démarré de la même copie de celle-ci, chaque
exécution sous le lock qui tient à l'écart les autres benchmarks de la machine ; des médianes et leur intervalle à 95 %
sans hypothèse sur la distribution. Les commandes `wlat`, `stall`, `write ... W` et `livecpu` de `sbench.exe`.

| | mesuré | à côté |
|---|---|---|
| un changement après le reçu de son écriture, au serveur, par son socket Unix ($n = 7$, 200 écritures chacun) | p50 16,0 µs [11,0 ; 26,9], p99 68 | `NOTIFY` de PostgreSQL avec un serveur Go, du commit à l'écran, sa WebSocket comprise : 137 µs [128 ; 148] (mesuré sur la même machine le 2026-11-11 avec PostgreSQL 18.6 et Go 1.26.3, par un banc d'essai hors de ce dépôt) |
| le même, dans le follower du programme sur la machine du serveur | p50 −6,9 µs [−14,8 ; −1,0] : avant le reçu ; p99 19,8 | |
| l'écriture elle-même (son fsync) | p50 3 409 µs [2 970 ; 5 879] | l'insert de PostgreSQL avec son fsync : 3 317 µs [3 122 ; 3 438] (le même banc d'essai) |
| 100 watches, chacun sur une connexion lue par un thread, un writer de groupes de 20 factures pendant 10 s, sans / avec une connexion qui suit une question et ne lit jamais ($n = 7$) | livrés 100 % / 100 % ; après le reçu p50 1 314 µs [1 259 ; 1 348] / 1 341 [1 186 ; 1 582], p99 4 880 [3 862 ; 7 126] / 5 747 [4 852 ; 96 319] ; le pic de mémoire du serveur 111 / 107 MB | le même banc d'essai, un écran bloqué parmi 100 : Node `ws` et Go `gorilla` 100 % (p99 113 ms et 4,3 ms) ; un hub d'une seule fiber qui attend sur chaque socket, 50,6 % |
| le hub seul (`livecpu`, dans un seul processus, $n = 5$) : S écrans, chacun suivant les factures impayées de son client, et un tableau de bord (la somme et le nombre des impayées), puis 20 000 groupes au hasard (nouvelles factures, paiements, totaux changés) | un groupe, tableau de bord compris, à 100 / 1 000 / 10 000 écrans : p50 16,0 µs [16,0 ; 21,0] / 13,1 [12,2 ; 19,1] / 12,2 [12,2 ; 12,9], moyenne 17,2 / 14,6 / 14,5 ; chaque écran et le tableau de bord égaux à ceux de `Find` à la fin | redemander à la place : la somme du tableau de bord 10,0 ms [9,7 ; 11,6] par groupe à 10 000 écrans ; l'écran que touche un groupe 8,1 µs |
| 16 writers pendant 5 s sans / avec 100 watches de ce qu'ils écrivent, les watches lus par un autre processus ($n = 7$) | 1 844 groupes par seconde [568 ; 2 058] / 1 598 [977 ; 1 981] ; le rapport dans chaque tour 1,20 [0,29 ; 2,09] | PostgreSQL, 16 writers avec le `NOTIFY` d'un trigger : 8,6 fois moins d'inserts [6,1 ; 22,2] (ses commits font la queue sur le lock de `NOTIFY`, `async.c`) |

- Un changement part environ 16 µs après le reçu de son écriture, qui part lui-même environ 5 µs après que le groupe
  est durable (la moitié du round trip à vide) : environ 20 µs après durable au serveur, quelques µs dans le follower,
  qui le calcule pendant le fsync. La borne de la conception était 50 µs après durable.
- Les changements d'un groupe coûtent au hub à peu près autant pour 100 ou 10 000 watches (une seule évaluation par
  template, le modèle commun des questions qui ne diffèrent que par leurs constantes, ses lignes routées par la valeur
  du client), et 12 µs à 10 000 contre 10 ms pour redemander le tableau de bord : la borne de la conception était 20 µs
  par groupe à 10 000 écrans. Redemander seulement l'écran que touche un groupe coûte à peu près autant que la
  différence (8,1 µs) ; la différence gagne sur les agrégats, et elle sait quels écrans ont changé sans en redemander
  aucun.
- Une connexion qui ne lit jamais ne coûte rien de mesurable aux autres, et ses messages non envoyés s'arrêtent à
  8 MiB (son watch se termine alors par `lagging`) ; les bornes hautes de ses intervalles sont le bruit du disque (un
  tour de chaque côté a eu un fsync lent).
- Ce que coûtent les 100 watches aux 16 writers n'est pas mesurable ici (l'intervalle du rapport contient 1) : le
  writer et le syncer passent chaque frame à une queue. Le `NOTIFY` de PostgreSQL fait passer ses commits un par un.
- Là où PostgreSQL + Go gagnent : leur fan-out (la distribution d'un changement à chaque lecteur) vers beaucoup
  d'écrans utilise chaque cœur (à 1 000 écrans 2 822 µs du commit à un écran, la médiane, sa WebSocket comprise, contre
  3 756 µs jusqu'à une fiber d'un seul programme Cesia avant toute WebSocket, [Cesia](cesia.md#ce-que-cela-coûte)).

### Erreurs

Chaque réponse est une valeur ou une erreur `{code, message}`. Les codes du moteur : `conflict`, `invalid`, `unique`,
`damaged`, `io`, `busy`, `closed` ([erreurs](errors.md)). Ceux du serveur :

| code | quand | que faire |
|---|---|---|
| `auth` | Hello avec un token inconnu ; une requête avant Hello ; un token retiré depuis | vérifier le token ; la connexion se ferme |
| `denied` | il manque au token le droit pour cette base ou cette opération ; une session d'un autre token | un token qui a ce droit |
| `version` | Hello avec une version du protocole que le serveur ne parle pas (il parle les versions 1 à 5) | une bibliothèque se reconnecte dans la version d'avant ; sinon, un serveur et une bibliothèque d'une même release |
| `too_large` | une frame de plus de 16 MiB (la connexion se ferme) ; une question qui dépasse le budget de travail du serveur, ou une réponse qu'il tiendrait au-delà de ses cellules (un Find avec Sort ou des agrégats, la première réponse d'un watch) ; un Watch au-delà des watches d'une connexion ou du serveur ([limites](limits.md#les-questions)) | écrire en groupes plus petits ; poser une question plus étroite, ou demander des pages ; faire d'abord un Unwatch |
| `unknown_database` | un nom ou un handle que le serveur ne tient pas | la déclarer dans cluster.toml |
| `stopping` | le serveur s'arrête | se reconnecter : la bibliothèque le fait |
| `too_many_connections` | une nouvelle connexion sur le Unix socket alors que le serveur tient `max_connections` connexions (id de requête 0 ; sur TCP la connexion est fermée sans un mot) | se connecter plus tard, ou relever la limite |
| `idle` | aucune requête entière pendant `idle_timeout` secondes, ou aucun Hello dans les 10 s qui suivent la connexion (id de requête 0, puis le serveur ferme la connexion) | envoyer `Ping` entre-temps, ou se reconnecter : le client OCaml le fait |
| `timeout` | une question (un Find, la première réponse d'un Watch) a dépassé son temps : le `question_timeout` du serveur, ou le temps plus court que son programme lui a donné ; les frames déjà envoyées d'un Find en flux finissent par elle ([limites](limits.md#les-questions)) | poser une question plus étroite, ou demander des pages ; donner un `timeout` plus long (un token admin au-delà de celui du serveur) |
| `refused` | une écriture renvoyée après qu'une écriture plus tardive de sa session a été appliquée, et dont la première erreur s'est perdue quand le serveur a redémarré (si c'est le même serveur qui l'a refusée, son erreur est redonnée à la place) | elle n'a pas été appliquée : décider à nouveau |
| `missing` | Load d'une chose qui n'a pas de fichier de ce kind ; un chunk (un morceau d'un fichier) que le vault ne tient pas | |
| `erased` | Load, ou Put, d'un propriétaire dont la clé a été effacée | |
| `invalid` | une requête mal formée (la connexion se ferme), une question qui ne passe pas la vérification, un numéro de série sous le floor de sa session, un why qui commence par le marqueur du serveur, `Follow` sur une connexion qui a des écritures en cours | corriger la requête |
| `denied` (Follow) | `Follow` sur TCP : les lectures locales sont pour les programmes de la machine du serveur, par son Unix socket | lire à travers le serveur ; le client OCaml le fait de lui-même |
| `busy` (Follow) | `Follow` quand les fichiers de runs n'ont pas pu être ouverts huit fois de suite (des merges les supprimant entre-temps) | suivre à nouveau : le client OCaml le fait, en moins de 100 ms |
| `internal` | le serveur a échoué sur une requête, ou dans une autre tâche de la connexion (la réponse d'une écriture, un push), sur ce qu'il n'attendait pas : un bug, ou de la mémoire qui a manqué. Sur l'id de la requête, ou sur l'id 0 ; puis la connexion se ferme, ses écritures en cours recevant d'abord leur réponse ([plus bas](#une-requête-qui-fait-échouer-le-serveur)) | se reconnecter (le client OCaml le fait) ; signaler la ligne du log du serveur |
| `read_only` | `Write`, `Put` ou `Erase` sur une replica ; le message nomme son primary (le serveur qui prend les écritures) et l'adresse du primary | écrire au primary |
| `denied` (Follow, replica) | `Follow` sur une replica : son état est en retard sur celui de son primary | lire par le socket ; le client OCaml le fait de lui-même |
| `invalid` (promote) | `promote` (qui fait d'une replica un primary : la promotion) sur un primary, pendant que le primary envoie encore, ou sans son handover (la passation que fait l'arrêt propre du primary) et sans `--force` | arrêter proprement le primary, puis promouvoir ; `--force` une fois qu'il ne peut plus écrire |
| `busy` (promote) | une promotion en cours, ou une page de visibilité tenue par un autre serveur de cette machine | promouvoir à nouveau une fois qu'elle s'est terminée |
| `unreachable` (promote) | la connexion a rompu avant la réponse : la promotion a été faite une fois ou pas du tout | `cepheus status` dit laquelle des deux |

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
n'attend rien (le lease le faisait attendre la durée d'un lease). Un lecteur sur une autre machine n'a pas de
page partagée : ses lectures locales demanderaient des leases entre serveurs (quorum leases), que Cepheus n'a pas
encore ; dans un cluster Raft, le leader sert les lectures, sous un lease à lui ([les
lectures](#les-lectures-et-ce-que-voit-un-programme)).

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
  le choix de l'état ajoutent quelques nanosecondes). La cible de la conception était 0,5 µs. Mesuré à nouveau après
  l'arrivée des règles (format de run 6, un flag dans le mot de 64 bits de chaque valeur), sur la même base agrandie par
  les mesures d'écriture plus bas jusqu'à 1,56 M de groupes, $n = 11$ : 0,245 µs [0,231 ; 0,251] dans le programme,
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

La cible de la conception était 20 µs pour 8 lecteurs ; les hooks coûtent 0,5 % d'un fsync de ce disque, et les deux
latences sont égales dans le bruit du disque. Le coût croît avec les lecteurs (1,4 µs sans aucun) : chaque frame est
mise en file pour chaque lecteur et réveille le thread qui l'envoie.

**Ce que suivre coûte à un lecteur.** Un lecteur local pendant que 256 clients écrivent des factures de 4 faits par le
socket ($n = 7$ tours, son temps CPU sur 4 s) : **32,3 % d'un cœur** [23,3 ; 38,8] à 17 942 groupes par seconde
[12 269 ; 22 027], environ 4,5 µs par changement appliqué. La cible de la conception, 20 % d'un cœur à 18 000 groupes
par seconde, est **manquée** : la conception mesurait 1,72 µs par changement pour rejouer un journal seul sur une
machine calme ; ici le lecteur partage les 4 cœurs et les 8 threads matériels de la machine avec le serveur et les 256
clients qui écrivent, et chaque merge du serveur lui fait appliquer à nouveau, sur les nouveaux runs, les groupes écrits
pendant le merge. Sous cette charge, sa mémoire (Pss : la mémoire du processus, où chaque page partagée compte pour sa
part) était de 273 MB [202 ; 325] : son delta des groupes depuis le run le plus récent, plus gros tant que les écritures
vont plus vite que les merges.

**Ce que huit lecteurs coûtent à la machine.** Huit lecteurs locaux du 1 M de faits, chacun ayant lu une fois chaque
facture de l'échantillon ($n = 7$) : **250 MB de Pss** en tout [249 ; 250], 31 MB chacun, pour l'essentiel sa propre
copie des pages des runs (les runs de la base font 24 MB). Les backends de PostgreSQL (un processus par connexion) qui
servent 8 clients de lectures ponctuelles : 43 MB [43 ; 44] de Pss en tout (12 processus), parce qu'ils partagent un
même buffer pool (la mémoire où une base garde les pages de ses fichiers). Que chaque lecteur garde son propre cache
était le premier choix de la conception (le code du moteur tel qu'il est, chaque page vérifiée) ; une seule copie
partagée par tous les lecteurs n'est pas construite. Avec le format de run 7 (2026-11-09), les mêmes huit lecteurs
prennent **106,5 MB de Pss** [105,6 ; 107,1] contre 252,4 [251,5 ; 253,0] sur main 0ecc09e, en alternance sur 7 tours :
la copie des pages des runs de chaque lecteur a rétréci avec les runs
([benchmarks](benchmarks.md#runs-et-journal-compressés-2026-11-09-à-10-millions-de-faits)).

**Par rapport au serveur d'avant les lectures locales** (le même serveur sans elles, ses binaires et les nôtres à tour
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
qu'après `sync` ; les lecteurs de Cepheus les voient toujours. Ce que Cepheus n'a pas ici : des lecteurs locaux sur
d'autres machines (une replica, c'est-à-dire une copie tenue à jour sur une autre machine, sert ses lectures par son
socket, le leader d'un cluster Raft sert chaque lecture ; les quorum leases ne sont pas construits), et le SQL de
PostgreSQL.

## Une replica

Une **replica** est un second serveur, sur une autre machine, qui garde une copie de chaque base d'un **primary** (le
serveur qui prend les écritures), groupe par groupe, dans son propre journal, forcé par ses propres fsyncs. Elle donne
une seconde copie qui survit à la perte de la machine du primary, un endroit d'où prendre les sauvegardes sans toucher
au primary, et, à la main, un nouveau primary quand l'ancien a disparu (`cepheus promote`). Elle est **asynchrone** :
le primary confirme une écriture dès que son propre fsync revient et n'attend jamais une replica, si bien qu'une
replica a du retard, son lag (mesuré [plus bas](#ce-que-coûte-une-replica)), et qu'une écriture confirmée pendant ce lag
n'est que sur le primary. Un cluster Raft ([plus bas](#un-cluster-de-trois-raft)) attend une majorité avant de
confirmer.

### En mettre une en place

Les deux serveurs partagent un même `cluster.toml` sauf pour `me`, avec un `[[peer]]` chacun et `[tls]` : les serveurs
ne se joignent que par TCP avec TLS mutuel (chacun montre un certificat de la CA du cluster, l'autorité de
certification qui signe les certificats de ses serveurs), si bien que deux peers sans `[tls]` sont refusés au
démarrage.

```toml norun
[cluster]
name = "shop"
id = "cph-c-6f1e9a2b7d40c381"
me = "srv2"                        # "srv1" on the primary's machine

[[peer]]
name = "srv1"
address = "10.0.1.11:7401"         # the peer port: servers only, mutual TLS
[[peer]]
name = "srv2"
address = "10.0.2.11:7401"

[tls]
ca = "/etc/cepheus/ca.pem"
cert = "/etc/cepheus/srv2.pem"     # srv2's own: cepheus cluster cert srv2 --host 10.0.2.11
key = "/etc/cepheus/srv2.key"
```

```sh
# on srv1's machine (the CA's key stays there, or offline)
cepheus cluster cert srv2 --dir /etc/cepheus --host 10.0.2.11     # copy ca.pem, srv2.pem and srv2.key to srv2
# on srv2's machine, the server stopped, its data directory empty
cepheus replicate srv1 --config /etc/cepheus/cluster.toml
systemctl start cepheus
```

`cepheus replicate PEER` écrit `DATA/cepheus.role` (mode 0600, `replica_of = "srv1"`) ; il refuse un serveur qui
tourne, un peer que le fichier ne déclare pas, et le serveur lui-même. À son démarrage, la replica crée chaque base
qu'elle n'a pas encore, avec l'id qu'elle a chez son primary (elle le lui demande ; le démarrage échoue, et dit
pourquoi, quand le primary ne répond pas à ce moment-là), et se connecte au port peer du primary, une fois par base.
Un serveur dont le cluster n'a qu'un peer n'ouvre aucun port peer : un ancien `cluster.toml` ne change rien. Avec
plusieurs peers, chaque serveur écoute sur l'adresse de son propre `[[peer]]`.

### Ce qui voyage, et pourquoi c'est sûr

Le **sender** du primary (l'envoyeur), un thread par replica et par base, lit le journal de la base tel que ses
fichiers le tiennent, frame après frame, octet pour octet avec le CRC de chaque frame, à partir du groupe qui suit le
plus récent de la replica, et seulement jusqu'au groupe **durable** le plus récent du primary. Il n'envoie jamais une
frame dont le fsync n'est pas revenu : si ce fsync échouait, le primary s'arrêterait, et son démarrage suivant
pourrait ne pas garder la frame ([G10](guarantees.md#g10-arrêt-sur-une-erreur-du-disque),
[G13](guarantees.md#g13-on-ne-se-fie-jamais-à-un-fsync-qui-a-échoué)), laissant à la replica un groupe que le primary n'a pas.
Donc **le journal d'une replica est toujours un préfixe des groupes durables de son primary**. Le sender est réveillé
après chaque frame durable, par la condition que signale déjà le flux des lecteurs locaux : le writer et le syncer ne
font rien de plus pour lui.

La replica vérifie le CRC-32C de chaque frame, la décode (chaque nombre borné par les octets qui restent), rejoue ses
groupes (replay) comme le fait la recovery (un grand groupe fusionné d'un coup dans un run, comme sur le primary), et
les ajoute à son propre journal par son propre writer et son propre syncer : les frames qui arrivent pendant qu'une
autre est forcée partagent le fsync suivant, et toutes les bases de la replica partagent son commit buffer. Puis elle
dit au primary jusqu'à quel groupe elle les tient durablement (`Applied`). Une replica très en retard, ou arrêtée
pendant un jour, lit à partir de là où elle en est : le rattrapage et le flux en direct sont un seul chemin. Le primary
garde en mémoire une frame par replica, quel que soit le retard de la replica ; la replica garde au plus 64 MiB de
frames données à son writer et pas encore durables (toujours une frame au moins, jusqu'aux 256 MiB que permet le
journal).

Le protocole des peers ne passe que par le port peer, dans les frames du [protocole](#le-framing), kinds 20 à 26 :

| message | de | contient |
|---|---|---|
| `PeerHello` | les deux | la version (1), l'id du cluster, le nom du serveur ; un autre id de cluster est refusé |
| `Replicate` | replica | la base, son groupe suivant, ses epochs (l'historique de ses promotions, [plus bas](#la-promotion-à-la-main)) ; la réponse : l'id de la base, le groupe le plus récent du primary, ses epochs, ou une erreur (`diverged`, `newer`, `unknown_database`, `not_primary`) |
| `Epochs` | un primary qui démarre | rien ; la réponse : le groupe le plus récent et les epochs de chaque base |
| `Frame` | primary | le premier groupe, le nombre, le CRC, la longueur, puis les octets, en morceaux de 1 MiB |
| `Beat` | primary | son groupe durable le plus récent, chaque seconde sans frame |
| `Stopped` | primary | son arrêt propre : chaque groupe jusqu'à celui-ci a été envoyé ([plus bas](#la-promotion-à-la-main)) |
| `Applied` | replica | elle tient durablement chaque groupe jusqu'à celui-ci |

Le certificat que montre un peer doit être signé par la CA du cluster et nommer un `[[peer]]` autre que le serveur
lui-même ; un serveur qui se connecte vérifie le certificat de l'autre pour son adresse et son nom. Chaque côté donne à
l'autre 5 s pour son handshake et son Hello, puis 30 s de silence avant de fermer le flux ; la replica se reconnecte
après 0,1 s, puis après un délai deux fois plus long à chaque fois, jusqu'à 5 s.

### Ce que sert une replica

Les lectures (`Open`, `Get`, `Find`, `Watch`) : l'état après un de ses groupes, chaque groupe d'avant compris, jamais
un groupe que son primary n'a pas rendu durable. Une lecture sur une replica n'est pas linearizable (elle ne voit pas
forcément chaque écriture confirmée avant son début) : elle peut manquer une écriture que le primary a confirmée un
instant plus tôt (G15 tient sur la machine du primary). `Write`, `Put` et `Erase` reçoivent `Err read_only`, dont le
message nomme le primary et son adresse. `Follow` (les lectures locales) reçoit `denied` : les clients OCaml et Cesia
lisent alors par le socket. Les fichiers du [vault](vault.md) ne sont pas encore copiés : un `Load` sur une replica ne
trouve aucun octet.

`cepheus status` dit `role: replica of srv1` et, pour chaque base, `replica_of`, `replica.connected`,
`replica.primary_group` (le groupe le plus récent du primary, d'après ses beats, les messages qu'il envoie chaque
seconde), `replica.handover`, `replica.epoch` et, tant que suivre échoue, `replica.error`. Sur le primary,
`role: primary`, l'`epoch` de chaque base et, pour chaque replica qui le suit : `replica.srv2.group` (ce qu'elle tient
durablement), `replica.srv2.lag_us_p50`, `_p99`, `_max` et `lag_samples` : des microsecondes, de l'instant où le
sender a vu un groupe durable jusqu'à l'`Applied` de la replica pour ce groupe.

### La promotion, à la main

```sh
cepheus stop --config /etc/cepheus/cluster.toml                            # on srv1: its clean stop hands over
CEPHEUS_TOKEN=cph_... cepheus promote --config /etc/cepheus/cluster.toml   # on srv2, an admin token
```

- **Le handover** (la passation). L'arrêt propre d'un primary (`SIGTERM`, `cepheus stop`) répond à ses écritures en
  cours, ferme ses bases, envoie à chaque replica ses dernières frames et `Stopped {group}`, et attend (au plus 10 s)
  qu'elle dise qu'elle les tient ; la replica écrit alors `DIR/handover` (0600). Après un handover, **aucun groupe que
  le primary a confirmé ne manque sur la replica.**
- `cepheus promote` est refusé tant que le primary envoie encore à la replica (il est vivant : l'arrêter d'abord), et,
  sans `--force`, à moins que chaque base n'ait reçu son handover. Avec `--force` (le primary a disparu : sa machine a
  brûlé, il ne démarre pas), les groupes qu'il a confirmés après le plus récent de la replica sont perdus ; le lag dit
  combien de millisecondes d'écritures cela représente.
- Puis les followers (les threads de la replica qui suivent le primary) s'arrêtent, chaque frame donnée au writer est
  durable, chaque base ouvre une nouvelle **epoch** (une époque : une période de l'histoire de la base sous un même
  primary) à partir du groupe qui suit son plus récent, `DATA/cepheus.role` dit `promoted_from` (le point de commit de
  la promotion : un crash après lui est réparé au démarrage suivant), la page de visibilité de chaque base est ouverte
  (les lecteurs locaux sont admis), et les écritures sont prises. La table des sessions a suivi les groupes (G14) : un
  programme qui renvoie, avec sa session et son serial, une écriture que l'ancien primary a confirmée reçoit son
  premier reçu du nouveau primary.
- Les programmes joignent le nouveau primary à sa propre adresse : un client qui nomme les deux serveurs et passe au
  suivant sur `read_only` n'est pas encore là.

**Les epochs.** Chaque base garde l'historique de ses promotions dans `DIR/epochs` (0600) : une liste de (epoch, son
premier groupe) ; sans le fichier, l'epoch 1 à partir du groupe 1 (toute base faite avant les replicas). L'idée est la
timeline history de PostgreSQL. Quand une copie demande à suivre un primary, elle envoie son historique et son groupe
le plus récent : son historique doit être un préfixe de celui du primary, et son groupe le plus récent doit tomber dans
sa dernière epoch sur le primary. Sinon, elle tient des groupes que le primary n'a jamais eus (écrits par un ancien
primary après la promotion, ou jamais envoyés à la replica qui a été promue) : elle est refusée (`diverged`), jamais
fusionnée. Une copie dont l'historique est plus récent que celui du primary est refusée aussi (`newer`). L'ancien
primary devient une replica du nouveau avec `cepheus replicate srv2` et rattrape à partir de là où il s'est arrêté ;
une fois qu'il a divergé, il faut le recopier depuis rien (un répertoire de données vide).

**Deux primaries à la fois** (un split brain : deux serveurs qui prennent les écritures d'une même base). Ce que cette
version empêche : une promotion pendant que le primary parle à sa replica ; un ancien primary qui redémarre (systemd, un
reboot) alors qu'il joint un serveur d'une epoch plus récente : à son démarrage, à côté de ses ouvertures, un primary de
plusieurs peers demande aux autres leurs epochs (au plus 1 s) et refuse de démarrer si l'un en tient une plus récente ;
et la fusion d'un historique qui a divergé. Ce qu'elle ne peut pas empêcher : après une promotion forcée, un ancien
primary coupé du nouveau mais encore joint par des programmes confirme des écritures qui n'existent que chez lui (elles
sont refusées comme divergentes quand on en fait une replica). Isolez-le avant `--force` : arrêtez-le, coupez-le du
réseau, ou éteignez-le. Dans un cluster Raft ([plus bas](#un-cluster-de-trois-raft)), cela ne peut pas arriver : un
leader ne confirme rien sans une majorité.

### Les sauvegardes depuis la replica

Le répertoire de données d'une replica tient les fichiers des bases de son primary (leur id, leurs runs, leurs
segments), si bien que [`cepheus backup`](production.md#les-sauvegardes) avec le `cluster.toml` de la replica les copie
pendant que la replica tourne, et le primary ne fait aucun travail pour cela : avec un primary et une replica,
sauvegardez la replica. La copie tient les groupes que tenait la replica (quelques-uns derrière le primary au plus, son
retard dans `cepheus status`), et `epochs` aussi : une copie sans lui recommencerait à l'epoch 1, et un historique
promu la refuserait comme replica. Le script de sauvegarde des versions d'avant les copie de la même façon.

### Ce que coûte une replica

Sur la machine des [benchmarks](benchmarks.md) (i7-4720HQ, 4 cœurs et 8 threads, 11 GB, un SSD SATA), le 2026-11-13,
le build release ; chaque tour sous le lock qui tient à l'écart les autres travaux lourds de la machine, chaque serveur
limité à 2 GB ; $n = 21$ tours ; des médianes sur les tours, et pour un rapport la médiane de ses valeurs tour par tour
avec son intervalle à 95 % sans hypothèse sur la distribution (par les statistiques d'ordre). Le primary `srv1` et sa
replica `srv2` tournent sur cette seule machine et se parlent par loopback. Les écritures sont `sbench.exe rate` : un
débit régulier de groupes d'un fait chacun pendant 4 s, sur 16 connexions à 1 000 groupes/s et sur 200 à 10 000 (une
open loop : une écriture en retard part aussitôt, pour qu'un serveur lent n'ait pas le temps de souffler). La replica
rattrape d'abord les groupes qu'elle a manqués, puis redémarre, pour que son lag ne compte que les groupes mesurés.
**Le lag** est celui du primary (`replica.srv2.lag_us_*` dans `cepheus status`) : de l'instant où son sender voit un
groupe durable jusqu'à l'`Applied` de la replica pour lui, si bien qu'il contient le trajet de la frame par TLS, ses
vérifications et son replay sur la replica, l'écriture et le fsync de la replica, et le trajet du retour.

Les données de la replica à deux endroits : **en mémoire** (`/dev/shm` : son fsync ne coûte rien et elle ne partage
pas le disque du primary ; c'est, sur cette seule machine, ce qui ressemble le plus à une replica sur une machine à
elle, moins le fsync de cette machine et le réseau), et **sur le SSD du primary** (deux serveurs qui forcent un même
disque). Les deux dernières colonnes comparent la latence d'écriture du primary, tour par tour, à celle du même débit
écrit vers un serveur sans replica.

| | lag p50 | lag p99 | lag max | écriture du primary p50 / sans | son écriture p99 / sans |
|---|---:|---:|---:|---:|---:|
| 1 000 groupes/s, replica en mémoire | **0,22 ms** | 1,37 ms | 3,52 ms | 1,13 [0,94 ; 1,40] | 1,47 [1,19 ; 2,15] |
| 10 000 groupes/s, replica en mémoire | **0,67 ms** | 3,50 ms | 7,20 ms | 0,99 [0,94 ; 1,31] | 1,62 [1,06 ; 4,27] |
| 1 000 groupes/s, replica sur le SSD du primary | 9,21 ms | 34,3 ms | 469 ms | 2,21 [1,99 ; 2,54] | 1,52 [0,73 ; 2,51] |
| 10 000 groupes/s, replica sur le SSD du primary | 11,1 ms | 40,5 ms | 467 ms | 1,73 [1,62 ; 2,04] | 1,83 [1,11 ; 2,69] |

Sans replica, le serveur a écrit 998,5 et 9 965 groupes/s, son écriture p50 5,82 et 8,77 ms, son p99 35,1 et
40,2 ms ; avec la replica en mémoire 998,7 et 9 963 groupes/s ; avec la replica sur son SSD 908 et 9 350 groupes/s
(en dessous du débit demandé).

- **Le lag.** Une replica qui ne partage pas le disque de son primary a moins d'une milliseconde de retard à la
  médiane, à 1 000 comme à 10 000 groupes/s, et quelques millisecondes à son p99 : c'est ce qu'une promotion `--force`
  peut perdre (les écritures confirmées pendant le lag). Sur une machine à elle, son propre fsync s'y ajoute (3 ms ou
  plus sur ce genre de SSD : les frames qui arrivent pendant qu'une autre est forcée partagent le suivant), et
  l'aller-retour du réseau aussi ; non mesuré ici.
- **Les écritures du primary** gardent leur médiane ; leur p99 croît d'environ moitié (1,47 et 1,62 fois), car le
  sender, son TLS et toute la replica tournaient sur les mêmes 4 cœurs. Ce qu'il en reste quand la replica a sa propre
  machine n'est pas mesuré ici.
- **Jamais sur le disque du primary.** Deux journaux forcés sur un même SSD rendent l'écriture médiane du primary 1,7
  à 2,2 fois plus longue, mettent la replica une demi-seconde en retard une fois dans la plupart des exécutions (son
  lag max : plus de 0,4 s dans 14 exécutions sur 21 à 1 000 groupes/s), ce que la replica en mémoire ne montre jamais,
  et ne gardent rien que la perte de ce disque n'emporterait pas avec les deux.
- **Le rattrapage.** Une nouvelle replica en mémoire a pris les 648 571 groupes de son primary en 10 s, environ
  65 000 groupes par seconde, ses bases reconstruites par replay (une seule exécution, $n = 1$).

**Un serveur sans replicas** (un `cluster.toml` d'un seul peer, comme tous ceux d'avant les replicas) ne paie rien qui
se voie. Le binaire de main (923da1b) contre celui de cette version, alternés dans chaque tour et leur ordre changeant
d'un tour à l'autre, le `sbench.exe` de main étant le client des deux :

| | main | cette version | cette version / main |
|---|---:|---:|---:|
| le démarrage du binaire (`cepheus` sans argument, 100 lancements par tour) : médiane | 4,864 ms | 4,898 ms | 1,017 [0,976 ; 1,029] |
| le même, le minimum de chaque tour | 4,300 ms | 4,399 ms | 1,020 [1,003 ; 1,053] |
| le serveur prêt (son `ready in` : les ouvertures d'un répertoire de données agrandi par ces exécutions) | 262 ms | 243 ms | 1,002 [0,946 ; 1,089] |
| un round trip vide (`ping`) | 9,35 µs | 10,54 µs | 1,117 [0,969 ; 1,266] |
| écritures durables, 1 writer, juste après le démarrage : p50 | 3,06 ms | 3,12 ms | 1,010 [0,964 ; 1,106] |
| le même, 3 s plus tard : p50 | 3,09 ms | 3,13 ms | 0,984 [0,920 ; 1,189] |
| écritures durables, 16 writers : groupes/s | 1 828 | 1 467 | 1,014 [0,655 ; 1,225] |
| le même : p50 | 6,08 ms | 7,62 ms | 0,978 [0,689 ; 1,408] |

Le binaire est passé de 15,09 à 15,46 MB (2,5 %, le code de la replica) : son démarrage le plus rapide a lieu 2 %
(0,1 ms) plus tard, dans le bruit à la médiane. Le cas d'un seul writer a été mesuré deux fois : d'abord dans des
tours qui alternaient avec les exécutions à débit fixe plus haut, où les deux côtés calaient par moments (un p50 de
plus de 6 ms : 8 exécutions de cette version, 2 de main) et où le rapport sortait à 1,128 [1,010 ; 2,990] ; puis seul,
21 tours de plus, les deux lignes plus haut, où rien ne les sépare (calages : 4 exécutions de cette version, 3 de
main). Rien n'a changé sur le chemin d'écriture d'un primary, au-delà de quelques tests par écriture et par frame (le
serveur est-il une replica, un lot tient-il le run d'un grand groupe).

### Comment c'est testé

- `replica_sim` (une simulation déterministe : une seed, la graine du hasard, décide de tout, et `--seed N` la
  rejoue) : un primary et sa replica sur deux disques simulés ; des écritures en sessions, de grands groupes, des
  merges des deux côtés ; le sender qui lit le journal du primary une frame à la fois dans un lien d'un nombre borné
  d'octets ; le lien coupé n'importe où (la replica se reconnecte à partir de son groupe durable le plus récent) ou
  laissé coupé pendant que le primary écrit à travers plusieurs segments ; des frames abîmées en route (un bit inversé,
  coupées court : le CRC les refuse) ou bien formées et fausses (d'autres octets ou d'autres groupes sous un bon CRC :
  le décodage les refuse, et rien ne change) ; des coupures de courant et des morts du processus des deux machines à
  l'intérieur de n'importe quel appel au disque ; des fsyncs qui échouent sur le primary. À chaque recovery de la
  replica et à la fin, son journal est un préfixe des groupes durables du primary, groupe par groupe. Puis une
  promotion : après un handover aucun groupe confirmé ne manque, et chaque écriture confirmée d'une session reçoit son
  premier reçu de la table de la replica promue ; après une coupure de courant et `--force`, la replica est toujours un
  préfixe. La replica promue écrit dans l'epoch 2, l'ancien primary continue parfois d'écrire (un split brain), puis
  demande à suivre : les epochs ne l'acceptent que si son journal est vraiment un préfixe de celui du nouveau primary,
  toujours quand il ne tient rien après la promotion, et alors les deux journaux finissent identiques.
- `server_replica` : deux vrais serveurs en TLS mutuel sur loopback : une copie depuis rien pendant qu'un programme
  écrit ; la replica tuée (kill -9) qui rattrape ; des refus au port peer (un certificat d'une autre CA, un certificat
  de la CA pour un nom qu'aucun peer n'a, le nom du serveur lui-même, un autre id de cluster, une base inconnue) ; des
  écritures refusées sur une replica ; des promotions refusées pendant que le primary envoie et sans handover ; le
  handover de l'arrêt propre et `cepheus promote` (chaque groupe confirmé est là, une écriture renvoyée reçoit son
  premier reçu, des écritures prises dans l'epoch 2) ; un ancien primary informé au démarrage de l'epoch plus récente ;
  l'ancien primary qui suit le nouveau ; les mêmes groupes dans les deux journaux ; les modes des fichiers (0600, le
  répertoire de données 0700) ; un changement des règles sur le primary et un chargement sur le chemin des grands
  groupes avec les conséquences de la règle, tous deux lus sur la replica.

### Sécurité

- **Qui peut se connecter.** Le port peer ne parle que le TLS mutuel : un certificat de la CA du cluster qui nomme un
  autre `[[peer]]` (jamais le serveur lui-même), puis l'id du cluster. Le token d'un programme n'y ouvre rien, et le
  certificat d'un serveur n'ouvre rien sur le port des clients.
- **Ce qu'envoie un peer est vérifié avant d'être utilisé.** La longueur de chaque frame est vérifiée avant que rien ne
  soit alloué pour elle (16 MiB par message, 256 MiB par frame de journal), son CRC-32C avant qu'elle ne soit décodée,
  son décodage est borné par ses octets, et ses groupes doivent suivre le plus récent de la replica sans trou. Une
  frame qui échoue à l'une de ces vérifications est refusée, l'état de la replica inchangé, et le flux recommence. Un
  primary vérifie l'historique d'une replica avant de lui envoyer quoi que ce soit.
- **Le déni de service.** Au plus 256 connexions de peers à la fois ; 5 s depuis l'accept pour un handshake et son
  Hello, un octet à la fois ou non (l'horloge regardée après chaque lecture, dans le handshake et dans un record TLS),
  30 s de silence sur un flux ; la replica tient au plus 64 MiB de frames en vol, le primary une frame par replica.
- **Les fichiers.** `cepheus.role`, `epochs` et `handover` sont écrits à côté (un nouveau nom ouvert avec `O_EXCL`, si
  bien qu'un lien posé là n'est jamais suivi), forcés, renommés, puis le répertoire est forcé, mode 0600 ; le
  répertoire de données 0700.
- **Ce que cela n'arrête pas.** Un peer dont la clé est volée peut agir comme une replica (lire chaque base) ou, comme
  primary, envoyer des groupes à une replica : gardez les clés des peers comme celle de la CA, lisibles par le seul
  utilisateur du serveur.

## Un cluster de trois (Raft)

Avec trois `[[peer]]` ou plus, les serveurs forment un **cluster Raft** (Raft : un algorithme de consensus, par lequel
des serveurs s'accordent sur une même suite d'écritures ; Ongaro et Ousterhout, *In Search of an Understandable
Consensus Algorithm*, USENIX ATC 2014 ; la thèse d'Ongaro, Stanford 2014). Un serveur, le **leader**, prend chaque
écriture ; il ne confirme une écriture qu'une fois qu'une **majorité** des serveurs (2 sur 3, 3 sur 5) la tient forcée
sur leurs disques ; quand le leader est perdu (sa machine, son réseau, son processus), les autres en élisent un nouveau
d'eux-mêmes, et aucune écriture que l'ancien leader a confirmée n'est perdue. Un cluster de 3 survit à la perte d'un
serveur, un cluster de 5 à celle de 2.

### En mettre un en place

Le même `cluster.toml` sur chaque machine sauf pour `me`, trois `[[peer]]` et `[tls]` ; chaque `[[peer]]` peut dire où
les programmes le joignent (`clients` ; par défaut son propre hôte, au port de la section `[clients]` de ce fichier) :

```toml norun
[cluster]
name = "shop"
id = "cph-c-6f1e9a2b7d40c381"
me = "srv1"                        # "srv2", "srv3" on the other machines

[[peer]]
name = "srv1"
address = "10.0.1.11:7401"         # the peer port: servers only, mutual TLS
clients = "10.0.1.11:7400"         # where programs reach srv1 (a follower sends them there)
[[peer]]
name = "srv2"
address = "10.0.2.11:7401"
[[peer]]
name = "srv3"
address = "10.0.3.11:7401"

[clients]
listen = "0.0.0.0:7400"

[tls]
ca = "/etc/cepheus/ca.pem"
cert = "/etc/cepheus/srv1.pem"
key = "/etc/cepheus/srv1.key"
```

Les trois démarrent sur des **répertoires de données vides** : chaque base reçoit le même id sur chaque serveur
(calculé à partir de l'id du cluster et du nom de la base) et le même premier groupe, et chaque groupe suivant arrive
par le log du cluster (plus bas). Un répertoire de données écrit par un serveur seul est refusé (`was not made by this
Raft cluster`) : faire grandir un serveur seul en cluster n'est pas construit. Avec 1 `[[peer]]`, un serveur est
seul, avec 2 c'est un primary et sa replica ([plus haut](#une-replica)), avec 3 ou plus un cluster Raft : une seule
façon de basculer (fail over : passer à un autre serveur quand l'un tombe) pour un cluster de chaque taille. Dans un
cluster Raft, `cepheus replicate` et `cepheus promote` sont refusés, et `DATA/cepheus.role` ne doit pas exister. Un
nombre pair de serveurs fonctionne, mais ajoute une machine qui peut tomber en panne sans ajouter une panne à laquelle
le cluster survit (une majorité de 4, c'est 3).

### Un seul log pour le cluster

Le cluster tient un seul **log** (le log répliqué de Raft, distinct du journal de chaque base) : chaque entrée est une
frame du journal d'une base, entière, marquée de l'id de la base (ou le no-op du leader, plus bas). Son index est la
place de l'entrée, son **term** le numéro du mandat du leader qui l'a faite (un term grandit à chaque élection, et a
au plus un leader). Sur le leader, chaque base résout ses écritures comme le fait un serveur seul (une frame pour
toutes les écritures arrivées pendant que la précédente était commitée : le group commit), puis **propose** la
frame : le leader l'ajoute à son log et la force, pendant qu'il l'envoie aux followers (les autres serveurs, qui
suivent le leader), dont chacun la force aussi et le dit. Une fois qu'une majorité la tient forcée (le fsync du leader
lui-même et celui d'un follower, en parallèle), l'entrée est **committed** (acquise : aucun leader futur ne la perdra) :
le leader écrit la frame dans le journal de la base (sans fsync : le log la tient forcée), la publie, et répond au
programme. Chaque serveur applique ensuite chaque frame committed à sa propre base, dans l'ordre du log. Le journal
d'une base ne tient donc **que des frames committed** : rien n'est jamais repris d'un journal, d'un run ou d'une vue.

Toute frame que fait une base passe par le log : celle d'une écriture (un `Incr` compris, son compteur lu à son point
sur le leader), celle d'un chargement, et le groupe d'un changement des règles calculé en arrière-plan
([règles](rules.md#les-changements-des-règles-en-arrière-plan)), proposé seul une fois que plus rien d'autre n'est en vol.
Un changement qui tourne pendant que son leader cesse d'être leader reçoit `not_leader`, rien de lui n'étant écrit.
Une entrée est une seule frame du protocole : un groupe fait au plus 8 MiB dans un cluster, et un chargement prend le
chemin ordinaire du writer (pas celui des grands groupes, qui écrit une frame par morceaux avant qu'elle soit
durable) ; un groupe de plus de 8 MiB est refusé en entier (`invalid`, « over the frame limit of 8388608 ») : un
chargement se découpe en groupes ; un changement des règles dont les conséquences dépassent cette limite ne le peut
pas (les grandes entrées par morceaux ne sont pas construites).

Le log est `DATA/raft/` (0700) : des segments `log.<first index>` (0600), chacun un en-tête et des **rounds**, un
round étant les entrées d'un même fsync, vérifiés par CRC-32C comme les frames d'un journal
([formats](formats.md#les-fichiers-du-serveur)) ; et `DATA/raft/state` (0600), le term du serveur, son vote, et sa marque de
réparation, écrits à côté, forcés et renommés. Chaque seconde, une fois le journal de chaque base forcé, les segments
entiers du log que chaque journal tient et que chaque serveur tient sont supprimés. Un serveur qui fait sa recovery
récrit dans les journaux les frames dont le log sait qu'elles sont committed, coupe chaque journal après elles, et
applique le reste une fois qu'il apprend jusqu'où le cluster a commité.

### Les élections

Un follower qui n'entend rien d'un leader pendant son **election timeout** (son délai d'élection : 500 ms, plus un
temps tiré au hasard jusqu'à 500 ms de plus, pour que deux serveurs commencent rarement en même temps) demande aux
autres leurs **pre-votes** (des votes d'essai) pour son prochain term (thèse 9.6) : un serveur n'en accorde un que
s'il n'a entendu aucun leader pendant le timeout minimal et que le log du demandeur est au moins aussi à jour que le
sien ; un pre-vote ne change rien chez le votant. Avec une majorité de pre-votes, le serveur augmente son term, vote
pour lui-même (vote forcé avant que rien ne parte) et demande des votes ; un serveur vote au plus une fois par term
(son vote forcé avant qu'il ne réponde), pour un log au moins aussi à jour que le sien, et jamais dans les 500 ms qui
suivent un message d'un leader ou son propre démarrage (la **stickiness**, l'attachement au leader en place, thèse
4.2.3). Un serveur qui a gagné une majorité devient leader : sa première entrée est un **no-op** de son term (une
entrée qui ne fait rien, section 8 de Raft), puisqu'un leader ne commit une entrée d'un term antérieur qu'à travers
une des siennes (section 5.4.2) ; il sert les programmes une fois son no-op committed et chaque entrée d'avant
appliquée. Un leader qui n'entend aucune majorité pendant un election timeout se retire (**CheckQuorum**, thèse 6.2).

Pourquoi ces durées : les heartbeats (les messages par lesquels le leader montre qu'il est là) partent toutes les
50 ms ; un follower répond aussitôt à un heartbeat, quoi que fasse son disque (son acquittement d'entrées attend leur
fsync, celui d'un heartbeat non), si bien que le timeout couvre le réseau et une pause du processus, pas un fsync
lent. Une bascule prend le timeout (0,5 à 1 s), un tour de pre-votes et un tour de votes (un fsync pour le vote), et le
no-op du nouveau leader (un fsync) : mesuré [plus bas](#ce-que-coûte-un-cluster). etcd attend plus longtemps par défaut
(« By default, etcd uses a 100ms heartbeat interval » : un heartbeat toutes les 100 ms ; « By default, etcd uses a
1000ms election timeout » : un election timeout de 1 000 ms ; son guide de réglage pour la v3.5), et demande que
« Election timeouts must be at least 10 times the round-trip time » (l'election timeout doit valoir au moins 10 round
trips) : sur un LAN (0,1 à 0,5 ms), 500 ms font mille round trips.

### Les lectures, et ce que voit un programme

Seul le leader sert les lectures et les écritures. Une lecture sur le leader est **linearizable** (elle voit chaque
écriture confirmée avant son début) sous le **lease** du leader (un bail : une promesse valable un temps donné, thèse
6.4.1) : les followers qui ont répondu à un heartbeat ont promis de ne voter pour personne pendant 500 ms à partir de
sa réception ; le leader sert à partir de l'instant où ce heartbeat a été envoyé, pendant 450 ms, pour que des
horloges qui divergent jusqu'à 10 % gardent le lease à l'intérieur des promesses. Un leader dont le lease a expiré
(une majorité n'a pas répondu récemment) ne sert rien jusqu'à ce qu'il soit renouvelé.

Un follower répond à chaque lecture et à chaque écriture par `Err not_leader`, dont le message nomme le leader et dont
le corps porte, après le message, l'adresse du leader pour les programmes (le décodeur de chaque client, jusqu'au
protocole 1, saute les octets qui suivent le message d'une erreur : pas de nouvelle version du protocole ; de même, le
`Welcome` d'un serveur Raft porte, après ses champs, l'adresse de chaque membre pour les programmes). La bibliothèque
OCaml le suit (`Client`, qu'utilisent la commande `cepheus`, les tests et les benchmarks) : elle se connecte au leader
et renvoie la requête, une écriture avec sa session et son serial, pour qu'elle soit appliquée une fois (G14). Le client
Cesia ne le suit pas encore : il donne au programme `not_leader`, dont le message nomme l'adresse du leader. Tant qu'il
n'y a pas de leader (une élection est en cours) ou que le nouveau n'est pas prêt, un serveur répond `Err no_leader`, et
la bibliothèque réessaie après une pause (10 ms, qui double jusqu'à 50 ms dans un cluster, 1 s ailleurs), dans son
budget de retries (30 s) ; un programme dont le serveur a disparu essaie le membre suivant que ce serveur a nommé dans
son Welcome. Une écriture qui était en vol quand son leader a cessé d'être leader reçoit le même traitement : appliquée
une fois ou pas du tout, le nouveau leader répondant à son renvoi à partir de sa table des sessions si elle était
committed.

Ce qui n'est pas encore là : les lectures locales (`Follow`) sur les serveurs d'un cluster (`denied` : la bibliothèque
lit par le socket) ; des lectures sur les followers sous des leases à eux (conception 8.4) ; les fichiers du vault
(`Put` et `Erase` sont refusés) ; les watches ne passent au leader que quand le programme les rouvre.

### Un log abîmé : la règle de 2018

Alagappan et al. (*Protocol-Aware Recovery for Consensus-Based Storage*, FAST 2018) ont montré que les systèmes de
consensus « can lose data or become unavailable » (peuvent perdre des données ou devenir indisponibles) quand un seul
secteur du log d'un serveur est abîmé : un serveur qui prend son log abîmé pour un log plus court peut voter pour un
candidate (un serveur qui demande des votes) à qui manquent des entrées qu'il avait acquittées, et une entrée
committed est perdue. Cepheus distingue une fin torn (le round qu'on écrivait au moment d'un crash, jamais acquitté :
coupé) d'un dommage (un round qui ne se vérifie pas suivi d'un round qui se vérifie, ou écrit en entier : refusé),
comme le fait son journal. Sur un dommage, un serveur **ne supprime jamais** ce qu'il a trouvé : le segment abîmé et
ceux qui le suivent sont mis de côté (renommés `*.damaged`), les rounds d'avant le dommage sont gardés, et
`DATA/raft/state` note l'index le plus récent que nomme un en-tête qui se vérifie (l'entrée la plus récente qu'il a pu
acquitter). Il **ne vote plus et ne se présente plus** à une élection tant qu'il ne tient pas chaque entrée jusqu'à
cet index, reçue d'un leader dont le commit index (l'index jusqu'où il sait les entrées committed) l'atteint ; en
attendant, il stocke et acquitte ce que le leader envoie, comme tout follower. La règle est la nôtre, éclairée par
l'article (dont la propre recovery, CTRL, va chercher les entrées abîmées chez les autres serveurs) ; sa preuve est le
modèle TLA+ plus bas, où le même serveur qui vote comme si son log était plus court perd une entrée committed. Le coût
porte sur la disponibilité, jamais sur la sûreté : si une majorité est abîmée à la fois, aucun leader n'est élu tant
qu'un opérateur n'en a pas réparé un. Un `DATA/raft/state` abîmé (son CRC ne correspond pas) empêche le démarrage :
le serveur ne peut pas savoir quels votes il a donnés.

### Le protocole des peers, version 2

Sur le port peer, dans les frames du [protocole](#le-framing) : `PeerHello` dit version 2 ; un peer de version 1 est
refusé avec `version`. `Raft` (kind 27) fait d'une connexion un flux de messages de Raft, dans un seul sens, venant du
peer du certificat, chacun une frame de kind 28 (id 0) : `Pre_vote` et `Vote` (un term, le dernier index et le
dernier term du demandeur), leurs réponses (accordé, un term), `Append` (le term du leader, un numéro, l'index et le
term qui précèdent les entrées, les terms et les octets des entrées, le commit index, et le plancher : l'index le plus
récent que tient chaque serveur), et sa réponse (ok et l'index le plus récent tenu forcé, ou refusé et où réessayer).
Chaque serveur garde une connexion vers chaque autre serveur pour ce qu'il envoie ; les réponses reviennent sur celle
de l'autre. Un message plus vieux qu'un election timeout dans la file d'un expéditeur est abandonné (Raft renvoie ce
qui compte).

`cepheus status` dit `raft.role` (leader, follower, pre-candidate, candidate), `raft.term`, `raft.leader`,
`raft.ready` (un leader dont le no-op est committed et appliqué), `raft.commit`, `raft.applied`, `raft.log` (les index
qu'il tient), `raft.forced`, et sur le leader, pour chaque autre serveur, `raft.peer.srv2: match M, next N` ;
`raft.repair` tant que la règle de 2018 retient un serveur, `raft.failed` si son disque a échoué (le serveur s'arrête
alors, comme sur tout disque en panne).

### La sécurité d'un cluster

- **Qui peut parler Raft.** Le TLS mutuel du port peer ([celui d'une replica](#sécurité)) : un certificat de la CA du
  cluster qui nomme un autre `[[peer]]`, puis l'id du cluster ; un peer du protocole 1 reçoit `version`. Un flux Raft
  n'est accepté que d'un peer de la liste, et chaque message qu'il porte est celui de ce peer (son expéditeur est le
  nom du certificat, jamais un champ).
- **Ce qu'envoie un peer est vérifié avant d'être utilisé.** La longueur d'une frame avant qu'elle soit lue (16 MiB),
  les nombres de chaque message contre les octets qui restent (un message qui ne se décode pas ferme le flux), le CRC
  de l'en-tête, le CRC du corps et le trailer de chaque frame committed avant qu'elle soit appliquée, et l'id de sa
  base contre celui de ce serveur ; une entrée d'un leader qui contredit une entrée committed est refusée, jamais
  prise.
- **Des promesses tenues à travers les crashs.** Le term et le vote sont forcés (écrits à côté, fsync, renommage, le
  répertoire forcé) avant que tout message de ce term ne parte, et une entrée n'est acquittée qu'une fois forcée : TLA+
  montre qu'un cluster sans l'un ou l'autre perd une écriture committed ou élit deux leaders dans un même term. Un log
  abîmé suit la règle de 2018 ([plus haut](#un-log-abîmé--la-règle-de-2018)).
- **Le déni de service.** Au plus 256 connexions de peers, deux flux Raft par peer (un plus ancien est fermé), 4 096
  messages en file pour un peer (puis abandonnés : Raft renvoie ce qui compte), les messages plus vieux qu'un election
  timeout abandonnés.
- **Les fichiers.** `DATA/raft/` 0700, son état et ses segments 0600.
- **Ce que cela n'arrête pas.** Un peer dont la clé est volée peut perturber les élections (un term élevé) ou, élu,
  écrire des entrées : gardez les clés des peers comme celle de la CA, lisibles par le seul utilisateur du serveur.

### Ce que coûte un cluster

Sur la machine des [benchmarks](benchmarks.md) (i7-4720HQ, 4 cœurs et 8 threads, 11 GB, un SSD SATA), le 2026-11-14,
le build release ; chaque tour sous le lock qui tient à l'écart les autres travaux lourds de la machine, chaque serveur
limité à 2 GB ; $n = 21$ tours, les côtés alternés dans un ordre qui tourne ; des médianes sur les tours, et pour un
rapport la médiane de ses valeurs tour par tour avec son intervalle à 95 % sans hypothèse sur la distribution. Les
trois serveurs tournent sur cette seule machine et se parlent par loopback en TLS mutuel, si bien que c'est une
indication du coût du protocole, pas de trois machines : un seul processeur, un seul disque. **L'endroit où sont les
données compte** : avec trois serveurs, un commit attend le deuxième plus rapide de trois fsyncs.

Des écritures durables d'un fait par groupe (`sbench mwrite`, 2 s chacune), par 1 connexion et par 16, au serveur dont
les données sont sur le SSD ; contre un primary et sa replica asynchrone (la façon de la release précédente, le
primary sur le SSD, la replica dans `/dev/shm`, ses écritures n'attendant jamais la replica) :

| | primary et replica | cluster A : followers dans `/dev/shm` | cluster B : un follower sur le SSD aussi |
|---|---:|---:|---:|
| 1 connexion : une écriture, médiane | 3,41 ms | **0,29 ms** (0,085 [0,055 ; 0,097]) | 6,53 ms (1,81 [1,36 ; 2,06]) |
| 1 connexion : une écriture, p99 | 19,8 ms | 6,2 ms | 25,6 ms |
| 16 connexions : groupes par seconde | 1 653 | **18 489** (11,2 [8,6 ; 12,0]) | 536 (0,28 [0,22 ; 0,48]) |
| 16 connexions : une écriture, médiane | 8,5 ms | 0,80 ms | 23,7 ms |

Ce qu'ils disent :
- **A** montre ce que coûte Raft lui-même : deux followers en mémoire font une majorité à eux seuls, si bien qu'un
  commit n'attend aucun SSD : un round trip par loopback avec TLS, le fsync d'un follower en mémoire, et les passages
  de relais entre les threads : 0,29 ms. Ce n'est pas un commit durable sur trois disques.
- **B** est le cas pessimiste d'une seule machine : un commit attend le deuxième plus rapide de trois fsyncs, dont deux
  sur le même SSD à la fois, ce qui ralentit les deux (le primary de la replica a ce SSD pour lui seul). Sur trois
  machines, chacune avec son disque, un commit coûte le fsync du leader et celui d'un follower (un round trip réseau
  plus tard), en parallèle : à peu près le chiffre du primary ici, plus le round trip.
- **Le débit.** La base d'un leader a une frame en vol (ses écritures suivantes attendent, réunies dans une seule
  frame, qu'elle soit committed) : la latence d'un commit borne donc les frames par seconde d'une base. Plusieurs
  frames en vol ne sont pas construites.

Un serveur sans peers est inchangé (cette release contre la précédente, alternées, $n = 21$) : prêt en 1,03 [0,96 ;
1,07] fois le temps d'avant (médiane 129 ms ici, la machine chargée), un round trip vide 0,97 [0,87 ; 1,16], les
écritures d'une connexion 1,03 [0,95 ; 1,48] à la médiane et celles de 16 connexions 0,94 [0,61 ; 1,76] : aucune
différence. Le démarrage du binaire lui-même (`cepheus` sans argument, 100 lancements par tour) : 5,28 ms contre 5,13,
**1,031 [1,020 ; 1,047]** : 0,15 ms de plus, pour 0,59 MB de code en plus (16,05 MB) : le cœur Raft, son log et sa
partie serveur.

**La bascule** (21 fois : trois serveurs sur le SSD, un programme qui écrit sans pause par TCP et TLS, le leader tué
par `kill -9`) : un nouveau leader prêt (son no-op committed, chaque entrée d'avant appliquée) 893 ms après le kill
(médiane ; de 557 à 1 395 ms) ; la première écriture du programme committed par lui 910 ms après (de 595 à 1 385). Le
tirage de l'election timeout (500 à 1 000 ms après le dernier heartbeat) en fait l'essentiel ; puis un tour de
pre-votes, un vote (un fsync), le no-op (un fsync). Avec l'ancienne pause de la bibliothèque (qui doublait jusqu'à
1 s), le programme attendait à la médiane 1 290 ms un leader prêt à 772 : dans un cluster, sa pause s'arrête
désormais à 50 ms.

### Comment c'est prouvé

- **TLA+** (`spec/Raft.tla`, vérifié par `tools/tlc.sh`) : l'algorithme du cluster avec Pre-Vote laissé libre (tout
  serveur peut se présenter à une élection : un sur-ensemble de ce que permettent les pre-votes), la stickiness, le
  no-op, les votes durables, des acquittements d'entrées forcées seulement, des redémarrages qui perdent ce qui
  n'était pas forcé, la règle de 2018, et le lease. Les messages sont perdus, retardés, réordonnés et dupliqués.
  Invariants (des propriétés qui doivent tenir dans chaque état) : au plus un leader par term ; des logs d'accord sur
  une entrée le sont sur tout ce qui la précède ; chaque leader ultérieur tient chaque entrée committed ; jamais deux
  entrées committed au même index ; une lecture sous le lease voit chaque entrée committed. Vérifié par parties,
  chacune de façon exhaustive dans ses bornes (3 serveurs, des terms jusqu'à 2, des logs de 2 entrées, 2 messages en
  vol ; TLC 1.7.4) : les élections et le log avec un redémarrage qui perd ce qui n'était pas forcé (14 136 156 états
  distincts, tout le graphe jusqu'à la profondeur 71), la règle de 2018 avec un serveur abîmé (5 786 757 états,
  profondeur 58), et le lease avec un redémarrage (5 853 164 états, profondeur 49) : aucun invariant violé. Chaque
  règle retirée seule en viole un, TLC affichant les étapes : commiter des entrées de terms plus anciens en les
  comptant (LeaderCompleteness, la Figure 8 de l'article, avec des terms jusqu'à 4 : 1 083 149 états), un vote oublié
  à un redémarrage (ElectionSafety), un acquittement avant le fsync (LeaderCompleteness), des votes qui ignorent les
  logs (LeaderCompleteness), un serveur abîmé qui vote comme si son log était plus court (LeaderCompleteness :
  l'échec décrit par l'article de 2018), une promesse qui finit avant le lease qu'elle soutient, un serveur qui vote
  juste après son démarrage, des votes accordés malgré une promesse, et des lectures avant que le no-op soit committed
  (chacune : ReadFresh, une lecture périmée).
- **La simulation** (`raft_sim`, 3 et 5 serveurs, une seed qui décide de tout, `--seed N` la rejoue) : le cœur Raft du
  serveur lui-même et son log, chaque serveur sur un disque simulé avec sa propre horloge (jusqu'à 3 % d'écart) ; des
  messages perdus, dupliqués et réordonnés ; des partitions (un serveur seul, une minorité, un lien coupé dans un seul
  sens) ; des morts du processus, des coupures de courant (des octets non forcés perdus ou torn), des morts à
  l'intérieur d'un appel au disque, un octet forcé du log inversé avant un redémarrage, des fsyncs lents (jusqu'à
  300 ms), des pauses (jusqu'à 400 ms). Vérifié : au plus un leader par term ; chaque entrée appliquée où que ce soit
  est celle du log committed ; chaque écriture dont un client a appris qu'elle était committed est dans le log final à
  son index ; des lectures linearizable (une lecture à l'index r rend l'état du log committed à r, voit chaque écriture
  répondue avant son début et aucune écriture commencée après sa fin, et aucune lecture finie avant son début n'a vu un
  index plus récent) ; une fois les pannes arrêtées, un seul commit et un seul log partout. Les seeds 1 à 300 à 3
  serveurs et 1 à 100 à 5 : aucun échec (50 103 et 16 616 vérifications ; `tools/test.sh` en lance 100 et 50). Comptés à
  part : 16 exécutions finissent avec un follower en retard sur le début du log de son leader, et 5 avec une majorité
  abîmée qui n'élit aucun leader (le rattrapage et la réparation par n'importe quel peer ne sont pas encore construits,
  plus haut). En chemin, elle a trouvé six bugs, chacun corrigé avant cette release : un leader déchu qui disait
  « committed » à un programme pour un index qu'un nouveau leader avait rempli ; une indication de commit écrite à côté
  d'entrées qu'une troncature ultérieure a remplacées, puis prise pour committed après un crash ; un dommage au dernier
  round du log pris pour une fin torn et coupé (l'échec de 2018 lui-même) ; un refus amplifié en une tempête de sondes
  par des messages dupliqués ; un follower qui coupait son log au-delà de ce dont d'autres avaient encore besoin ; et un
  pre-vote qu'un serveur en retard de terms ne pouvait jamais gagner.
- **De vrais serveurs** (`server_raft`) : trois serveurs en TLS mutuel sur loopback ; un programme connecté à un
  follower écrit à travers le leader ; le leader tué (kill -9) pendant qu'un programme écrit, un nouveau élu, chaque
  écriture dont le programme a appris qu'elle était committed présente, une écriture renvoyée dans sa session répondue
  avec son premier reçu ; l'ancien leader revenu comme follower, rattrapé ; des refus au port peer ; les modes des
  fichiers ; un chargement, un changement des règles à côté de groupes qui comptent avec un même compteur, un
  chargement de plus de 8 MiB refusé en entier, puis le leader tué : le nouveau tient le chargement, les conséquences
  du changement et le compteur, rien du chargement refusé.

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
leur origine ; les descriptors des fichiers d'une base ne sont passés qu'après la vérification de `Follow` ; pour un
token par kind, chaque fait d'un `Get`, chaque pattern d'un `Find` ou d'un `Watch` (ceux qui sont à l'intérieur de
`Not` et de `Or` aussi : l'absence ou l'alternative d'un fait d'un kind lit ce kind) et chaque fait d'un `Write` est
vérifié contre un octet par propriété, refait quand le schéma change. `In`, `Prefix`, Sort, Limit et After agissent
ensuite sur les lignes d'une question dont le token lit tous les kinds, si bien que les lignes, leur ordre, leur
nombre et une page après un curseur fait à la main ne révèlent rien qu'une question de ces kinds ne pourrait révéler,
et un `Prefix` ne lit l'ordre que des textes de sa propre propriété (son temps dépend des textes de cette propriété,
d'aucune autre). *Tests* : `server_unit` (chaque token contre chaque requête sur chaque base, un token retiré, des
droits restreints, une origine forgée refusée, une frame au-delà de la limite, chaque requête d'un token par kind,
600 questions aléatoires avec `Not`, `Or`, `In`, Sort, Limit et After (des curseurs faits à la main) d'un token par
kind contre les réponses d'un token write, `tokens.toml` réécrit octet pour octet) ; `server_sim` (des requêtes aléatoires de chaque token vérifiées
contre ses droits, et chaque groupe du journal contre ceux de son token) ; `server_crash` (un token retiré du fichier
pendant que son programme est connecté et lit dans sa propre mémoire).

Un token qui a des **droits par kind** (`{ read = ["client", "invoice"], add = ["invoice"] }`, ou
`--database "shop=read:client,invoice;add:invoice"`) ne lit et n'ajoute que ces kinds :

- `Get` ne donne que les faits des kinds qu'il lit, comme si la chose n'en avait pas d'autres. Un `Find` ou un `Watch`
  qui a un pattern sur un kind qu'il ne lit pas est refusé avec `denied` dès son arrivée. `Open` liste toujours le nom
  de chaque propriété : le schéma n'est pas une donnée.
- `Write` n'ajoute, ne retire ou n'attend (Expect) que des faits des kinds qu'il ajoute, et ne déclare que des
  propriétés de ces kinds ; un groupe qui a un seul fait d'un autre kind est refusé en entier avec `denied`. Un `Incr`
  ajoute au kind de son compteur et à celui de son `into` : il lui faut les deux (comme un `Expect`, il apprend au
  token la valeur du compteur). Les règles sont pour les tokens `write` seulement : une règle lit chaque kind.
- Il ne lit jamais dans sa propre mémoire : un lecteur local projette en mémoire (map) toute la base, si bien que le
  serveur refuse son `Follow`, et ses lectures vont au serveur. Les clients le font d'eux-mêmes.
- Avec des règles, il ne lit une propriété que s'il lit le kind de la propriété **et chaque kind dont peuvent venir
  les faits dérivés de la propriété** par les règles (`sources`,
  [règles](rules.md#une-propriété-comme-variable--la-forme-des-règles-dowl-du-w3c) ; une règle sur une propriété variable peut
  lire n'importe quel kind) : sinon un fait dérivé lui dirait quelque chose des faits qu'il ne peut pas lire. Une telle
  propriété est, pour lui, un kind qu'il ne lit pas (`Get` laisse ses faits de côté, une question sur elle reçoit
  `denied`). Un refus par les règles ne nomme que la règle (`constraint NAME`, `rule NAME refused the group`) :
  l'instance de la contrainte ou les prémisses d'un fait dérivé peuvent être de kinds qu'il ne lit pas. *Testé par*
  `test/server_unit.ml` (« rules and kinds » : 25 seeds de règles aléatoires sur trois kinds et de faits aléatoires,
  cinq tokens qui lisent certains kinds, chaque `Get` et chaque question après chaque groupe comparés à ce que
  l'oracle, un modèle simple qui donne la bonne réponse, calcule à partir des règles).

La vérification coûte 21,95 ns [21,85 ; 22,07] par groupe de 4 faits (`sbench rights` : la médiane de 21 tours d'un
million de groupes, avec son intervalle à 95 % ; un schéma de 40 propriétés de 10 kinds), à côté des dizaines de
microsecondes d'une écriture à travers le serveur ; un token `read` ou `write` paie une comparaison de plus par
requête.

### Une requête qui fait échouer le serveur

Une requête peut rencontrer ce que le serveur n'attendait pas : un bug (un index hors des bornes, une valeur
introuvable), ou de la mémoire qui a manqué. Elle n'emporte jamais avec elle le thread de sa connexion, ni le thread
d'une autre connexion ou celui des watches de la base. Chaque endroit qui sert l'autre côté arrête l'échec chez lui :
la requête, la réponse d'une écriture, un push, les propres threads de la connexion, une question suivie à une frame.

- **La requête** reçoit `internal` sur son id, avec un message fixe : aucune exception, aucun chemin, aucun état du
  serveur ne passe sur le réseau. Un échec dans un autre thread de la connexion (la réponse de son écriture, son push)
  dit `internal` sur l'id 0, et la connexion ne lit plus aucune requête après lui.
- **La connexion se ferme**, et lâche ce qu'elle tenait : ses écritures en cours reçoivent d'abord leur réponse, ses
  watches et ses fichiers inachevés sont abandonnés, ses threads finissent, son socket est fermé. Un programme qui fait
  échouer le serveur en boucle lui coûte à chaque fois sa propre connexion, et n'épuise ni les descriptors ni les
  threads (testé : 200 connexions de suite).
- **Une question suivie** qui échoue à une frame termine ses propres watches avec `internal` ; les autres questions
  continuent. Un échec du hub en dehors d'une question termine chaque watch de la base avec `internal`, et le hub
  repart de l'état de cette frame, pour qu'un nouveau watch parte juste.
- **Le log** reçoit une ligne sur la sortie d'erreur : ce qui a échoué (le numéro de la connexion, le nom de son
  token, l'id et le kind de la requête) et le texte de l'exception, coupé à 300 octets, chaque octet hors de l'ASCII
  imprimable écrit `\ddd`, pour que les octets d'un client dans le texte d'une exception ne puissent ni former une
  ligne à eux, ni parler au terminal qui affiche le log. Au plus une telle ligne par seconde : la suivante compte
  celles qui ont été laissées de côté. Les lignes sont dans [erreurs](errors.md#les-lignes-sur-la-sortie-derreur).
- **Une frame est entière ou n'est pas** : une réponse dont le codage échoue ne laisse rien d'elle dans la sortie, un
  push de plusieurs frames est donné entier ou pas du tout, et une réponse de plusieurs frames qui échoue après
  quelques-unes finit par `internal` sur son id, que le client prend pour sa fin.

La mémoire qui a manqué : OCaml lève `Out_of_memory` quand une allocation ne peut pas être obtenue (sous Linux,
surtout une taille au-delà de ce que la machine pourrait donner, celle que demande la requête elle-même), et le tas
est encore sain, si bien que le serveur continue. Une machine vraiment à court de mémoire voit plutôt le processus tué
par le noyau ; systemd le redémarre, et la recovery décide de ce qui est durable. Une pile qui déborde lève
`Stack_overflow` en OCaml 5, qui déroule la pile de ce thread : le serveur continue.

*Testé par* `test/server_unit.ml` (huit exceptions levées par une requête, les octets d'un client dans le texte d'une
exception, une réponse coupée entre ses frames, une écriture dont le passage de relais échoue, la réponse d'une
écriture et un push qui échouent, une question suivie et un hub qui échouent, des échecs en boucle) et
`test/server_guard.ml` (de vrais sockets : une connexion avec un watch et une écriture en cours, 200 connexions qui
échouent, un échec dans un autre thread sur un Unix socket et sur TCP ; les descriptors et les threads du processus
comptés avant et après).

### Qui peut atteindre le socket

Le répertoire du Unix socket est la porte d'entrée sur une machine : donnez-lui le mode `0750`, avec pour propriétaire
l'utilisateur du serveur et pour groupe Unix celui des programmes autorisés à se connecter
(`chgrp cepheus /run/cepheus`) ; le token reste nécessaire. Le serveur met le socket en mode 0660 dès qu'il l'a lié à
son adresse, quel que soit son umask (le masque des droits qu'un processus retire aux fichiers qu'il crée) : Linux ne
laisse un programme se connecter qu'avec le droit d'écrire sur le socket (unix(7)), si bien que le groupe de son
propriétaire peut se connecter, et personne d'autre. Sur TCP, TLS.

### Le répertoire de données

Ses fichiers tiennent les faits en clair (le journal, les runs, les tables des sessions) : chaque fichier que fait une
base est en mode 0600 et chaque dossier en 0700, quel que soit l'umask du processus. Un répertoire de données qui
laisse entrer son groupe ou les autres (fait à la main sous l'umask habituel, 0755) est rendu au seul serveur à son
démarrage, et le log le dit ; un répertoire qu'il ne peut pas changer (un autre propriétaire) est refusé. *Testé par*
`test/server_limits.ml` (un répertoire de données de mode 755 : 0700 après le démarrage, chaque fichier de la base
0600 et chaque dossier 0700, le socket 0660).

### Aucun chemin dans une réponse

Une erreur des propres fichiers du serveur (le disque, le vault et sa clé) parvient au programme comme son code
(`io`, `busy`) et un message fixe, "the server could not use its files (its log says why)" ; ce qu'elle dit (les
chemins, les mots du système) va dans le log du serveur seulement. *Testé par* `test/server_unit.ml` (une clé du vault
lisible par d'autres : `io` pour le programme, son chemin dans le log seulement).

### Le déni de service

Ce que l'autre bout d'une connexion, quel qu'il soit, peut faire tenir ou faire au serveur ; chaque borne est
refusée, ou attendue, avant d'être dépassée ([limites](limits.md#le-serveur)) :

- **Avant un token.** Une frame avant Hello fait au plus 4 KiB, si bien que l'autre bout, tant qu'il ne montre aucun
  token, tient le buffer de 64 KiB de sa connexion et rien de plus, pendant 10 s au plus depuis l'accept (son
  handshake TLS et son Hello, un octet à la fois ou non) ; à `max_connections`, une nouvelle connexion prend la place
  de la plus ancienne de ce genre, jamais celle d'un programme.
- **Les bouts lents.** Après Hello, une requête entière dans les `idle_timeout` secondes qui suivent la précédente :
  l'horloge est regardée après chaque lecture, dans un record TLS aussi.
- **La lecture.** Une frame plus longue agrandit le buffer de sa connexion, qui revient à 64 KiB une fois qu'elle a
  servi ; les buffers agrandis tiennent au plus 64 MiB de plus, pour tout le serveur, et une connexion qui les
  dépasserait attend de la place : 512 connexions qui commencent chacune une frame de 16 MiB ne font pas tenir 8 GiB
  au serveur.
- **Ce qui reste à envoyer.** Une connexion dont les réponses pas encore envoyées dépassent 1 MiB n'a plus aucune de
  ses requêtes décodée tant qu'elles ne sont pas parties : 100 Gets d'un texte de 900 KB envoyés en 1 400 octets et
  jamais lus tiennent un MiB et une réponse, pas 90 MB.
- **Les frames.** Aucune réponse ne dépasse la limite des frames, que chaque client refuse : un Get ou un Open qui la
  dépasserait est envoyé en frames de l'indicateur `more` ; un nom fait au plus 255 octets et un texte la frame moins
  4 KiB, si bien qu'un token qui peut ajouter à un kind ne peut pas rendre la base impossible à ouvrir ; un groupe
  dont le reçu dépasserait une frame est refusé avant d'être appliqué.
- **Les réponses.** Une réponse que le serveur tient (Sort, agrégats, la première réponse d'un watch) est bornée par
  ses cellules, lignes fois colonnes, celles d'une question et celles de toutes les connexions ensemble ; un Find sans
  Sort qui les dépasse ne tient aucune de ses lignes (il est posé de nouveau, et ses lignes envoyées à mesure qu'elles
  sont trouvées), si bien qu'un produit cartésien de patterns qui ne partagent aucune variable (chaque réponse de l'un
  avec chaque réponse de l'autre ; la taille du produit, la borne AGM : Atserias, Grohe, Marx 2008) coûte au serveur
  son temps, pas sa mémoire. Une question prend au plus 64 patterns, et son travail est compté en lookups (des
  recherches dans un index).
- **Les watches.** 1 024 par connexion, 65 536 pour le serveur, et ce que gardent leurs fenêtres et leurs groupes
  compte dans les cellules d'une connexion.

*Testé par* `test/server_unit.ml` ("the bounds of an answer at the server" : un produit cartésien demandé de toutes
les façons, le pool tenu par d'autres (la réserve de cellules commune aux connexions), 65 patterns, un pattern répété,
les watches d'une connexion et du serveur ; "replies within the frame limit" : un Open de 17 MB de noms et un Get de
17 MB de faits rejoints à partir de leurs frames, des noms et des textes au-delà de leurs bornes, un reçu au-delà
d'une frame) et `test/server_limits.ml` (un vrai serveur : des connexions qui ne montrent aucun token et tiennent
chaque place pendant qu'un programme se connecte, un handshake TLS et un record TLS après Hello envoyés un octet à la
fois) et `test/server_guard.ml` (de vrais sockets : une frame de 16 MiB avant Hello, trois frames de 700 KB
commencées à la fois sous une borne de 1 MiB, 3 000 Finds de 14 KB envoyés à la fois par un client qui ne lit encore
rien).

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
- **Ce que vérifie le serveur.** Le token du programme, dans TLS (les programmes ne montrent aucun certificat : choix 2
  de la conception). Entre serveurs (une replica et son primary, un cluster Raft), les deux côtés montrent un certificat
  de la CA qui nomme un peer de la liste : du mutual TLS, comme le font FoundationDB et etcd ([celui d'une
  replica](#sécurité)).
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

Les cinq lignes à $n = 101$ ont été mesurées de nouveau pour la première version, le 2026-11-19 : le serveur de Cepheus
à 19cb5ac (build release, 4 I/O domains), PostgreSQL 18.6 sur un nouveau cluster à lui (port 5548) avec les mêmes
lignes, 101 tours chacun seul sous le lock, l'ordre des deux côtés inversé à chaque tour (`sbench.exe` `ping`, `get` à 1
et à 16 en cours et `clients` 8, contre `pgbench -M prepared -T 1`) ; leur rapport est le temps de PostgreSQL sur celui
de Cepheus dans chaque tour, sa médiane et son intervalle de la même façon. La charge de la machine pendant la minute
avant un tour (le travail qui tenait le lock juste avant) avait une médiane de 4,8 ; dans les 19 tours commencés en
dessous de 2, une lecture ponctuelle prenait 8,87 µs et 8 clients 3,51 µs par lecture.

| | Cepheus | PostgreSQL 18.6 | rapport |
|---|---:|---:|---:|
| round trip vide, Unix socket (Ping ; `SELECT 1`), $n = 101$ | 8,86 µs [8,79 ; 9,03] | 15,24 µs [15,00 ; 15,60] | 1,73× [1,69 ; 1,77] |
| lecture ponctuelle, 1 client, Unix socket, $n = 101$ | **9,68 µs** [9,17 ; 10,09] | 24,91 µs [24,41 ; 25,26] | 2,62× [2,51 ; 2,75] |
| lecture ponctuelle, 1 client, TCP + TLS 1.3, $n = 101$ | **41,33 µs** [40,49 ; 42,12] | 52,31 µs [51,53 ; 52,92] | 1,27× [1,22 ; 1,31] |
| lecture ponctuelle, TCP sans TLS (PostgreSQL), $n = 21$ | (pas de TCP en clair : TLS toujours) | 35,81 µs [34,54 ; 37,71] | |
| lectures ponctuelles, 16 en cours sur une connexion (un pipeline de 16), par lecture, $n = 101$ | **1,30 µs** [1,29 ; 1,32] | 9,05 µs [9,00 ; 9,13] | 6,95× [6,88 ; 7,01] |
| lectures ponctuelles, 128 en cours, par lecture, $n = 11$ | 1,31 µs [1,29 ; 1,36] | | |
| 8 clients, une lecture en cours chacun : temps écoulé par lecture, $n = 101$ | **3,71 µs** [3,64 ; 3,78] | 6,27 µs [6,25 ; 6,29] | 1,71× [1,68 ; 1,74] |
| 64 clients, $n = 11$ | 3,14 µs [2,99 ; 3,71] | 7,00 µs [6,78 ; 7,68] | 2,2× |
| 256 clients, $n = 11$ | 2,88 µs [2,73 ; 3,94] | 12,83 µs [11,96 ; 13,75] | 4,5× |
| Q3, les factures impayées d'une ville (city-7 : 396 lignes de 2 valeurs), $n = 11$ | 0,487 ms [0,474 ; 0,526] | 0,662 ms [0,656 ; 0,699] | 1,4× |
| Q4, la somme et le nombre des impayés par ville (100 lignes, agrégées dans le serveur), $n = 11$ | 12,37 ms [11,35 ; 13,87] | 18,47 ms [18,36 ; 19,23] | 1,5× |
| une nouvelle connexion avec TLS et sa première requête, $n = 7$ | 2,60 ms [2,53 ; 2,76] | 4,28 ms [4,24 ; 4,56] | 1,6× |
| une nouvelle connexion, Unix socket (PostgreSQL y lance un nouveau processus backend, par un fork du système), $n = 7$ | | 2,03 ms [2,01 ; 2,04] | |

Ce que cela dit :

- **Un client** : une lecture ponctuelle coûte le round trip du noyau (deux appels système de chaque côté et deux
  réveils : les 8,86 µs de Ping) et le travail du serveur (le décodage, la lecture de la vue, le codage), petit à côté :
  la lecture a pris 0,65 µs de plus que Ping, apparié par tour [0,04 ; 1,03], et moins dans 38 tours sur 101 (le serveur
  renvoie les 16 octets de Ping ; 1,5 µs de plus le 2026-11-08). Le plancher de PostgreSQL lui-même, `SELECT 1`, est de
  15,2 µs : son travail par instruction est plus grand que toute notre lecture. La cible de la conception était 10 µs :
  9,68 maintenant (10,81 le 2026-11-08, quand le round trip vide prenait 9,32 ; 8,46 quand la conception l'a mesuré).
  Seul le fait de ne pas faire le round trip descend en dessous ([lectures locales](#lectures-locales-g15) : 0,22 µs).
- **Beaucoup de clients** : la cible principale de la conception, 8 clients à 4 µs au plus par lecture (PostgreSQL
  6,2 µs quand la conception l'a mesuré, 6,27 maintenant), tient : 3,71 µs (3,51 dans les tours commencés sous une
  charge de 2 ; 3,22 le 2026-11-08, $n = 11$). Avec un seul I/O domain, le serveur répondait toutes les 9,6 µs (le
  prototype) : ce sont les I/O domains qui font gagner (3 tours à chaque $k = 1, 2, 4, 8$ : 9,1-10,0 ; 5,3-5,5 ; 2,9-4,0
  et 2,1-3,1 µs ; 4, la valeur par défaut, tient 16 lectures en cours à 1,3-1,5 µs là où 8 domains donnaient 1,5-2,1).
  Le processus par connexion de PostgreSQL paie davantage à mesure que les connexions augmentent (12,8 µs à 256) ; nos
  threads dans 4 domains, non.
- **Pipelining** (plusieurs requêtes en cours sur une connexion, les réponses reliées par l'id) : 1,30 µs par lecture
  avec 16 en cours, 6,95 fois plus rapide que le pipeline de 16 de PostgreSQL (9,05 µs), où le backend répond toujours
  dans l'ordre et analyse chaque instruction.
- **TLS** nous coûte 31,9 µs de plus que le Unix socket (41,3 contre 9,7 ; apparié par tour [30,9 ; 32,8]) ; le round
  trip TLS d'OpenSSL lui-même, en C sur cette machine (64 octets dans chaque sens, le prototype de la conception), coûte
  27,06 µs contre 16,04 en TCP en clair : 11,0 µs de TLS. Le nôtre ajoute environ 18 µs au TCP en clair (23,2 µs, la
  première version du serveur, $n = 11$) : les buffers en mémoire par lesquels OpenSSL travaille ici (une copie vers eux
  et une hors d'eux, et davantage d'appels à OpenSSL par lecture) coûtent le reste. Les deux côtés utilisent le cipher
  TLS 1.3 par défaut d'OpenSSL (AES-256-GCM) ; le prototype C, AES-128-GCM. La cible de la conception était 36 µs :
  manquée de 5 µs ; toujours 1,27 fois plus rapide que PostgreSQL avec TLS (52,3 µs). Une nouvelle connexion TLS coûte
  2,6 ms (une signature ECDSA par le serveur, les vérifications du client ; aucun certificat client), 1,6 fois moins que
  celle de PostgreSQL.
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

- Find rassemble les index words de sa réponse avant de les envoyer (plus haut) ; les forks ne passent pas encore par
  le protocole.
- Des lecteurs locaux sur d'autres machines (une replica sert ses lectures par son socket ; dans un cluster Raft, le
  leader sert chaque lecture, les followers aucune : les lectures sur les followers sous des leases ne sont pas
  construites), et une seule copie partagée des pages pour beaucoup de lecteurs d'une même machine (chaque lecteur garde
  son propre cache : [ce que cela coûte](#ce-que-cela-coûte)).
- Une replica ne copie pas encore les fichiers du vault, un client ne passe pas de lui-même au nouveau primary, et une
  promotion se fait à la main ([une replica](#une-replica)).
- Dans un cluster Raft ([plus haut](#un-cluster-de-trois-raft)) : ajouter ou retirer un serveur (un à la fois, des
  learners d'abord, des serveurs qui reçoivent le log sans voter), un serveur qui rejoint le cluster avec des données
  ou qui tombe en retard sur le début du log du leader (un rattrapage à partir des journaux), les lectures locales, les
  fichiers du vault, un groupe de plus de 8 MiB, un serveur abîmé réparé par n'importe quel peer (pas seulement par un
  leader), le leadership passé à un autre serveur lors d'un arrêt propre, et le client Cesia qui suit `not_leader`.

Ce qui est construit : le client Cesia ([Cepheus depuis Cesia](cesia.md)), par lequel un programme Cesia atteint une
base par un serveur seulement, par `cepheus.Connect`, et lit localement sur la machine du serveur ; les questions
vivantes sur le protocole ([plus haut](#les-questions-vivantes-watch)) ; plusieurs bases qui partagent un seul fsync
([le commit buffer](#plusieurs-bases-un-seul-fsync--le-commit-buffer)) ; une replica qui suit son primary ([plus
haut](#une-replica)) ; trois serveurs qui élisent un leader et confirment les écritures sur une majorité ([plus
haut](#un-cluster-de-trois-raft)) ; `Incr`, un compteur augmenté dans son groupe
([groupes](concepts.md#les-groupes--une-écriture-est-une-transaction)). Pas construit : ce que nomme la liste plus haut,
et des bases tenues en mémoire seulement, avec `Expire`. La bibliothèque OCaml ouvre encore un répertoire de base dans
son propre processus (`Cepheus.open_`) : c'est le moteur que fait tourner le serveur, et ce que pilotent ses tests et
ses benchmarks ; les programmes, en Cesia, passent par le serveur.
