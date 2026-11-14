# En production

Comment faire tourner un serveur Cepheus sur une machine qui lui est réservée : comme service systemd (le gestionnaire
de services de Linux, qui lance les programmes au démarrage et les relance), avec des sauvegardes prises chaque nuit et
un exercice de restauration, ce qu'il faut surveiller dans `cepheus status` et dans le log (les messages que le serveur
écrit), comment faire une mise à jour, et que faire après un crash (l'arrêt brutal du processus) ou une coupure de
courant. Les commandes ont été lancées sur une machine de test ; leur sortie est montrée avec les chemins de cette
page. Un premier serveur sur un portable : [le démarrage rapide](quickstart.md). Chaque clé de `cluster.toml` et chaque
commande : [le serveur](server.md).

## La machine

| chemin | ce qu'il contient | propriétaire |
|---|---|---|
| `/usr/local/bin/cepheus` | le serveur et ses commandes | root |
| `/etc/cepheus/` | `cluster.toml`, `tokens.toml`, les certificats et les clés | cepheus, mode 0700 |
| `/var/lib/cepheus/` | les données : un dossier par base de données, et les fichiers propres au serveur ([fichiers du serveur](server.md#files-of-the-server)) | cepheus, mode 0700 |
| `/run/cepheus/` | le Unix socket (un canal entre deux programmes d'une même machine, nommé par un chemin), créé à chaque démarrage | cepheus, groupe cepheus, mode 0750 |
| `/backup/cepheus/` | les copies de chaque nuit ; sur un autre disque, et copiées sur une autre machine | cepheus |

Un utilisateur propre au serveur, le binaire construit comme dans le [démarrage rapide](quickstart.md#1-build-and-install),
et un cluster (les serveurs qui tiennent les mêmes bases) dont le certificat nomme le nom d'hôte et l'adresse de la
machine :

```sh
sudo useradd --system --home-dir /var/lib/cepheus --shell /usr/sbin/nologin cepheus
sudo install -m 755 _build/default/bin/main.exe /usr/local/bin/cepheus
sudo cepheus cluster init prod --dir /etc/cepheus --host db1.example.com --host 10.0.0.5
```

```text
/etc/cepheus/srv1.pem
/etc/cepheus/srv1.key
/etc/cepheus/cluster.toml
```

`cluster init` écrit un `cluster.toml` pour un portable ; sur un serveur, changez `[clients]` et `[storage]`, et nommez
vos bases de données (une base déclarée ici est créée au démarrage suivant) :

```toml norun
[clients]
socket = "/run/cepheus"
listen = "0.0.0.0:7400"

[storage]
data = "/var/lib/cepheus"
cache = "4G"

[[database]]
name = "shop"
```

Puis donnez les fichiers à l'utilisateur du serveur, et retirez de la machine la clé de la CA (l'autorité de
certification du cluster) : elle signe des certificats et rien d'autre ([TLS](server.md#tls)) ; ne la remettez que pour
en signer un avec `cepheus cluster cert` :

```sh
sudo chown -R cepheus:cepheus /etc/cepheus
sudo chmod 700 /etc/cepheus
sudo mv /etc/cepheus/ca.key /root/cepheus-ca.key
```

Un token (la suite d'octets secrète qu'un programme présente pour prouver ses droits) pour chaque programme, et un avec
`--admin` pour `cepheus status`. Chacun n'est montré qu'une fois : écrivez-le dans un fichier que seul son lecteur peut
lire (`umask 077`), et donnez à chaque programme le sien :

```sh
sudo -u cepheus sh -c 'umask 077; cepheus token add shop-web --database shop=write --config /etc/cepheus/cluster.toml > /etc/cepheus/shop-web.token'
sudo -u cepheus sh -c 'umask 077; cepheus token add ops --admin --config /etc/cepheus/cluster.toml > /etc/cepheus/ops.token'
```

```text
cepheus: token shop-web added to /etc/cepheus/tokens.toml; it is shown only now
cepheus: token ops added to /etc/cepheus/tokens.toml; it is shown only now
```

Un programme de cette machine n'atteint le socket que si son utilisateur est dans le groupe `cepheus` (`sudo usermod -aG cepheus
USER`) ; son token reste nécessaire ([qui peut atteindre le socket](server.md#who-may-reach-the-socket)). Les programmes
d'autres machines se connectent par TCP avec TLS, avec le `ca.pem` du cluster.

## Un service

`/etc/systemd/system/cepheus.service` :

```ini
[Unit]
Description=Cepheus database server
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=cepheus
Group=cepheus
ExecStart=/usr/local/bin/cepheus serve --config /etc/cepheus/cluster.toml
RuntimeDirectory=cepheus
RuntimeDirectoryMode=0750
StateDirectory=cepheus
StateDirectoryMode=0700
Restart=on-failure
TimeoutStopSec=120
LimitNOFILE=4096
MemoryMax=8G

[Install]
WantedBy=multi-user.target
```

- `Type=notify` : le serveur dit à systemd qu'il est prêt une fois chaque base ouverte et le socket à l'écoute, donc les
  services rangés après lui démarrent quand il répond ([démarrage](server.md#start-stop-crash)).
- `RuntimeDirectory` crée `/run/cepheus` à chaque démarrage, au nom de l'utilisateur et du groupe du serveur, mode
  0750 ; `StateDirectory` crée `/var/lib/cepheus` s'il manque, au nom de l'utilisateur du serveur.
- `Restart=on-failure` : après un kill (le processus tué par un signal), un crash, ou la sortie qui suit un disque en
  échec ([G10](guarantees.md#g10-stop-on-a-disk-error)), systemd redémarre le serveur, et la recovery (la remise en
  état de chaque base à l'ouverture, en relisant son journal) décide de ce qui est durable. Un arrêt propre
  (`systemctl stop`, SIGTERM) n'est pas suivi d'un redémarrage.
- `TimeoutStopSec` : un arrêt attend les écritures en cours et un merge (la fusion des fichiers triés d'une base) en
  route, puis ferme chaque base ; laissez-lui le temps plutôt que de laisser systemd le tuer (un kill est sans danger,
  mais le démarrage suivant fait alors une recovery).
- `LimitNOFILE` à côté de `max_connections` (512 par défaut) : une connexion tient un descriptor (le numéro par lequel un
  processus désigne un fichier ou un socket ouvert), et les fichiers des bases aussi ([cluster.toml](server.md#clustertoml)) ;
  montez les deux ensemble.
- `MemoryMax` au-dessus du `cache` de `cluster.toml` et des changements depuis le dernier merge
  ([mémoire](operations.md#memory)).

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now cepheus
journalctl -u cepheus -n 1 -o cat
```

```text
cepheus: ready in 23.9 ms: shop at group 1; socket /run/cepheus/.s.cepheus.7400, tcp 0.0.0.0:7400; 4 I/O domains, at most 512 connections; server cph-s-9fa7ee8710147141, cluster cph-c-59f1eb5ca605aacd
```

## Les sauvegardes

Le journal d'une base (le fichier où elle ne fait qu'ajouter ses écritures) n'est jamais que complété à sa fin, et ses
runs (les copies triées de son état, dans des fichiers) sont écrits à côté puis renommés, donc une copie n'a pas besoin
d'arrêt, dans cet ordre : l'id de la base, ses runs, puis ses segments (les fichiers successifs du journal)
([sauvegarde et restauration](operations.md#backup-and-restore)). La copie tient chaque groupe (une écriture, appliquée
tout entière ou pas du tout) confirmé avant le début de la copie de son segment, y compris ceux du commit buffer (le
journal commun du serveur, où les écritures de plusieurs bases partagent un seul fsync, l'appel système qui attend que
les octets soient vraiment sur le disque). Elle laisse de côté `lock`, `closed`, `shared` et `sessions` : la copie
s'ouvre comme une base à part entière. Prise sur une [replica](server.md#backups-from-the-replica) (une copie de la
base tenue à jour sur une autre machine), elle ne coûte rien au primary (le serveur qui reçoit les écritures), et tient
les groupes que tenait la replica. `/usr/local/bin/cepheus-backup` :

```sh
#!/bin/sh
# cepheus-backup DATA DEST: a copy of every database of the data folder DATA, taken while the server runs, in
# DEST/<date>/<database>. Prints the folder it made.
set -eu
data=$1
dest=$2/$(date +%Y-%m-%dT%H%M%S)
for db in "$data"/*/; do
  [ -f "$db/cepheus" ] || continue
  out=$dest/$(basename "$db")
  mkdir -p "$out/snapshots" "$out/journal"
  # 1. the database's id, and its history of promotions if it has one (a replica's: server.md, "A replica")
  cp "$db/cepheus" "$out/"
  if [ -f "$db/epochs" ]; then cp "$db/epochs" "$out/"; fi
  # 2. the runs, before the segments; a merge may remove one meanwhile: only a run still there must copy
  for f in "$db"/snapshots/*.run; do
    [ -e "$f" ] || continue
    cp "$f" "$out/snapshots/" || [ ! -e "$f" ]
  done
  # 3. the segments, in the order of their names
  for f in "$db"/journal/*.seg; do
    cp "$f" "$out/journal/"
  done
done
echo "$dest"
```

Chaque nuit à 3 h, sous l'utilisateur du serveur, avec `/etc/systemd/system/cepheus-backup.service` :

```ini
[Unit]
Description=Copy the Cepheus databases

[Service]
Type=oneshot
User=cepheus
Group=cepheus
ExecStart=/usr/local/bin/cepheus-backup /var/lib/cepheus /backup/cepheus
```

et `/etc/systemd/system/cepheus-backup.timer` (`Persistent` : une nuit où la machine était éteinte est rattrapée à son
démarrage) :

```ini
[Unit]
Description=Copy the Cepheus databases every night

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

Enregistrez le script sous le nom `cepheus-backup`, puis :

```sh
sudo install -m 755 cepheus-backup /usr/local/bin/
sudo install -d -o cepheus -g cepheus -m 700 /backup/cepheus
sudo systemctl daemon-reload
sudo systemctl enable --now cepheus-backup.timer
sudo systemctl start cepheus-backup
journalctl -u cepheus-backup -n 1 -o cat
```

```text
/backup/cepheus/2026-11-12T194940
```

Prise ici pendant qu'un programme écrivait 3 000 commandes : le serveur était au groupe 832 quand la copie a commencé,
et la copie s'ouvre au groupe 837. Copiez le dossier de chaque nuit sur une autre machine
(`rsync -a /backup/cepheus/ backup-host:cepheus/`) : une copie sur le même disque ne survit pas au disque.

### L'exercice de restauration

Une sauvegarde qu'on n'a jamais ouverte n'est pas une sauvegarde. Ouvrez la plus récente sur la machine de sauvegarde,
sur un serveur à part, une fois par mois et avant chaque mise à jour. Sur la machine du serveur en service, elle est
refusée, puisque c'est la copie d'une base que ce serveur tient :

```text
cepheus: database shop: /dev/shm/cepheus-69b9b1ca0ae6b04bbc10fec328e3ddcd.visible is held by another server: a copy of this database's data directory runs on this machine
```

Sur la machine de sauvegarde, sous n'importe quel utilisateur (port 7500, pour que ce serveur ne réponde jamais aux
programmes en service) :

```sh
mkdir -p ~/drill-base
cepheus cluster init drill --dir ~/drill-base/drill
mkdir ~/drill-base/drill/data
cp -R /backup/cepheus/2026-11-12T194940/shop ~/drill-base/drill/data/shop
```

Dans `~/drill-base/drill/cluster.toml`, mettez `listen = "127.0.0.1:7500"` et le nom de la base, `name = "shop"` ;
puis :

```sh
(umask 077; cepheus token add ops --admin --config ~/drill-base/drill/cluster.toml > ~/drill-base/drill/ops.token)
cepheus serve --config ~/drill-base/drill/cluster.toml &
CEPHEUS_TOKEN=$(cat ~/drill-base/drill/ops.token) cepheus status --config ~/drill-base/drill/cluster.toml | grep 'database.shop.g'
cepheus stop --config ~/drill-base/drill/cluster.toml
```

```text
cepheus: ready in 4.4 ms: shop at group 837; socket /home/you/drill-base/drill/run/.s.cepheus.7500, tcp 127.0.0.1:7500; 4 I/O domains, at most 512 connections; server cph-s-79503ed3ea8cf613, cluster cph-c-937d9016144d9776
database.shop.group: 837
stopped (process 610898, 605 ms)
```

L'exercice réussit quand le serveur démarre et que le groupe est au moins celui que montrait le serveur en service
quand la copie a commencé. Une copie qui ne s'ouvre pas nomme son dommage, comme plus bas ; restaurez alors celle de la
nuit d'avant. La vérification complète de chaque frame (un bloc du journal écrit d'un seul tenant, que ses CRC
vérifient) des anciens segments, `Cepheus.verify` ([vérification](operations.md#verification-scrubbing)), n'a pas
encore de commande : c'est un appel de l'API OCaml.

## Ce qu'il faut surveiller

`cepheus status` affiche un `key: value` par ligne. Interrogez-le sous l'utilisateur du serveur, qui peut lire le token
admin, chaque minute par exemple, et gardez les lignes avec leur heure :

```sh
sudo -u cepheus sh -c 'CEPHEUS_TOKEN=$(cat /etc/cepheus/ops.token) cepheus status --config /etc/cepheus/cluster.toml'
```

```text
server: cph-s-9fa7ee8710147141
cluster: cph-c-59f1eb5ca605aacd
uptime_ms: 6050
connections: 2
requests: 683
gc_minor: 23
gc_major: 3
stopping: false
commit_buffer.rounds: 0
commit_buffer.frames: 0
commit_buffer.alone: 679
database.shop.group: 6202
database.shop.facts: 12428
database.shop.resent: 1
database.shop.followers: 0
database.shop.frames: 679
database.shop.follow_ns_a_frame: 2483
database.shop.visible: 6217
database.shop.watches: 0
```

| ligne | ce que c'est | à surveiller |
|---|---|---|
| `server`, `cluster` | l'id du serveur (créé à son premier démarrage, gardé dans `DATA/cepheus.server`) et celui du cluster | un changement : un autre serveur, ou un autre dossier de données |
| `uptime_ms` | les millisecondes depuis le démarrage | plus bas qu'à la dernière interrogation : le serveur a redémarré ; lisez le log |
| `connections` | les connexions ouvertes en ce moment, celles des lecteurs locaux comprises | près de `max_connections` : les nouvelles sont refusées, et le log le dit |
| `requests` | les requêtes répondues depuis le démarrage | un rythme qui baisse alors que des programmes tournent |
| `gc_minor`, `gc_major` | les collections du runtime OCaml jusqu'ici (les passages du garbage collector, qui reprend la mémoire inutilisée) | à côté de la mémoire du processus : un rythme qui ne cesse de croître |
| `stopping` | un arrêt est en cours | `true` en dehors d'un arrêt prévu |
| `commit_buffer.rounds`, `.frames`, `.alone` | les fsyncs du buffer, les frames qu'ils ont rendues durables, les frames forcées dans leur propre journal (une base écrite seule) | `.frames` / `.rounds` : les frames partagées par un seul fsync ([commit buffer](server.md#many-databases-one-fsync-the-commit-buffer)) |
| `database.NAME.group` | son groupe durable le plus récent | immobile alors que des programmes écrivent : leurs écritures échouent ; lisez leurs erreurs et le log |
| `database.NAME.facts` | les faits de son état le plus récent | la croissance, pour le disque et la mémoire |
| `database.NAME.resent` | les écritures répondues de nouveau depuis la table des sessions : envoyées de nouveau après une connexion coupée, appliquées une seule fois ([G14](server.md#writes-applied-once-sessions-g14)) | une hausse régulière : des connexions se coupent (le réseau, `idle_timeout`, des redémarrages) |
| `database.NAME.followers` | les programmes de cette machine qui lisent dans leur propre mémoire ([lectures locales](server.md#local-reads-g15)) | moins que les programmes qui devraient le faire |
| `database.NAME.frames`, `.follow_ns_a_frame` | les frames publiées, et le temps moyen du serveur par frame pour les publier aux lecteurs locaux, en nanosecondes | un temps qui grandit avec `followers` |
| `database.NAME.visible` | le numéro de visibilité que partagent les lecteurs locaux (G15) | il avance avec les frames |
| `database.NAME.watches` | les questions vivantes (tenues à jour) ouvertes ([Watch](cesia.md#watch-live-questions)) | plus que les écrans ouverts |

À côté, le disque : un merge complet tient en double les runs de la base pendant qu'il tourne, et le journal garde
chaque groupe pour toujours, donc gardez libre au moins la taille des runs de la plus grande base, et surveillez la
croissance du journal ([espace disque](operations.md#disk-space-and-merges)). Et le log, `journalctl -u cepheus` :
chaque ligne commence par `cepheus:`, et celles-ci demandent un coup d'œil
([toutes les lignes](errors.md#lines-on-the-standard-error)) :

| ligne | que faire |
|---|---|
| `N connections refused so far: the limit of M is reached (max_connections)` | montez `max_connections` et `LimitNOFILE`, ou trouvez le programme qui laisse fuir des connexions |
| `accept: out of file descriptors or memory (raise LimitNOFILE, or lower max_connections)` | ce qu'elle dit |
| `background merge failed`, `a merge could not be installed`, `a merge could not catch up` | le disque : la place, les erreurs dans le log du système ; la base continue avec ses anciens runs |
| `database NAME: the sessions could not be saved` | le disque ; le démarrage suivant lit une plus grande part du journal |
| `FILE not reloaded: MSG` | `tokens.toml` est mal formé : le serveur garde les tokens qu'il avait |
| `database NAME stopped: MSG`, avant une sortie | un disque en échec : voir [après un crash](#after-a-crash-or-a-power-loss) |

## Les mises à jour

1. Lisez ce que la nouvelle version change dans [les formats de fichiers](formats.md) et dans [le serveur](server.md),
   et faites l'[exercice de restauration](#the-restore-drill) sur la sauvegarde la plus récente.
2. Construisez-la, et installez-la par-dessus l'ancien binaire (le serveur qui tourne garde sa propre copie ouverte) :
   `sudo install -m 755 _build/default/bin/main.exe /usr/local/bin/cepheus`.
3. `sudo systemctl restart cepheus` : un arrêt propre, qui force chaque journal sur le disque et vide le commit buffer,
   puis un démarrage de la nouvelle version.
4. `journalctl -u cepheus -n 1 -o cat` : la ligne « ready » (prêt), chaque base à son groupe. Une ouverture qui
   convertit un format est plus lente une fois (plus bas).
5. Reconstruisez le moteur des programmes Cesia depuis le même commit, et leur `cesia.lock`
   ([démarrage rapide](quickstart.md#3-a-project-for-the-program)) : sur la machine du serveur, un moteur lit lui-même
   les fichiers de la base ([lectures locales](cesia.md#local-reads)), donc il doit connaître les formats qu'écrit le
   serveur.

Ce qu'une nouvelle version peut faire à son premier démarrage, une seule fois :

- **Des runs d'un format antérieur** sont mis de côté et leurs groupes rejoués depuis le journal, qui les tient tous :
  une ouverture plus lente (5,2 s pour 10 M faits depuis le format 7), et le premier merge écrit le nouveau format
  ([runs](formats.md#run-dirsnapshotslo-20-digits-hi-20-digitsrun)). Le format de run 9 (l'ordre des textes de
  `Prefix`) est venu de cette façon après le format 8 ; une version antérieure met à son tour de côté les runs de
  format 9 et rejoue le journal : revenir en arrière coûte une ouverture lente, et ne perd rien.

Ce qui ne va que dans un sens, de sorte que revenir à une version antérieure demande une sauvegarde prise avant la mise
à jour :

- **Le format du journal.** Un journal de format 1 est converti au format 2 à la première ouverture, segment par
  segment ([formats](formats.md#a-group)) ; une version qui ne lit que le format 1 ne peut plus le lire ensuite.
- **Le commit buffer.** Les versions d'avant lui ne lisent pas `DATA/server.wal.1` et `.2`. Ne revenez en arrière
  qu'après un arrêt propre, qui les supprime ; après un crash, démarrez d'abord cette version une fois et arrêtez-la
  ([une base d'un serveur](operations.md#a-database-of-a-server)). Fait ici : la version antérieure, démarrée après un
  arrêt propre, a ouvert la base à son groupe, et cette version de nouveau après elle.

## Après un crash ou une coupure de courant

**Ce qui se passe tout seul.** systemd redémarre le serveur (`Restart=on-failure` ; après une coupure de courant, au
démarrage de la machine). Chaque base fait sa recovery à son ouverture : les frames du commit buffer réécrites dans son
journal, une fin torn du journal (écrite à moitié) coupée, les groupes d'après le run le plus récent rejoués
([recovery](operations.md#opening-and-recovery)). Chaque écriture qui a reçu la réponse `Ok` est là (G1) ; une écriture
en cours peut y être ou non, et la bibliothèque du programme l'envoie de nouveau : elle est appliquée une seule fois
(G14). Ici, un serveur tué par `kill -9` pendant qu'un programme écrivait 2 000 commandes :

```text
cepheus.service: Main process exited, code=killed, status=9/KILL
cepheus.service: Failed with result 'signal'.
cepheus.service: Scheduled restart job, restart counter is at 1.
cepheus: ready in 30.9 ms: shop at group 3846; socket /run/cepheus/.s.cepheus.7400, tcp 0.0.0.0:7400; 4 I/O domains, at most 512 connections; server cph-s-9fa7ee8710147141, cluster cph-c-59f1eb5ca605aacd
```

Le programme a fini avec `2000 orders answered Ok`, et la base tenait exactement 2 000 groupes de plus qu'avant ;
`database.shop.resent: 1` ensuite : l'écriture en cours au moment du kill, envoyée de nouveau par le programme et
répondue depuis la table des sessions.

**Ce qu'il faut vérifier.** `journalctl -u cepheus -b` : la ligne « ready » et la durée des ouvertures ; puis
`cepheus status` : chaque base à un groupe au moins aussi haut que le dernier que ses programmes ont vu confirmé.

**Quand une base est endommagée.** Un démarrage qui trouve des octets durables changés ne démarre pas : il sort en
nommant le fichier et l'offset (la position en octets), par exemple après un octet inversé dans un segment d'une copie
de test :

```text
cepheus: database shop: damaged: 00000000000000000001.seg: damaged frame at offset 46961 (written whole)
```

systemd réessaie jusqu'à sa limite de démarrages, et le log répète la ligne. Ne supprimez pas de fichiers : copiez de
côté le dossier de la base, et restaurez-la depuis la sauvegarde la plus récente qui passe l'exercice
([quand la recovery dit `Damaged`](operations.md#when-recovery-says-damaged)) ; le sens du message :
[erreurs](errors.md#damaged-durable-data-lost-or-changed).

**Un disque en échec.** Une écriture ou un fsync raté arrête la base, et le serveur sort (`database NAME stopped: ...`) ;
systemd le redémarre, et la recovery décide de ce qui est durable
([G13](guarantees.md#g13-a-failed-fsync-is-never-trusted)). Un système de fichiers passé en lecture seule refuse le
démarrage jusqu'à ce qu'il soit réparé : lisez le log du système pour y trouver l'erreur du disque
([quand une écriture renvoie `Io`](operations.md#when-a-write-returns-io)).

**Un programme qui ouvre lui-même les fichiers.** Après un crash, une base que tenait le serveur est refusée au propre
processus d'un programme (`Busy`) jusqu'à ce que le serveur ait démarré dessus une fois
([une base d'un serveur](operations.md#a-database-of-a-server)).

**Le disque lui-même.** Une coupure de courant ne garde ce qui a reçu la réponse `Ok` que si le disque garde ce que
`fsync` a rendu durable : les disques grand public peuvent tenir des écritures dans un cache volatil. Utilisez des
disques avec power-loss protection (une réserve d'énergie qui écrit ce cache sur le disque à la coupure) pour les
données qui comptent ([disques](operations.md#disks)).
