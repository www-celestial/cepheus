# Running in production

How to run a Cepheus server on a machine of its own: as a systemd service, with backups taken every night and a
restore drill, what to watch in `cepheus status` and in the log, how to upgrade, and what to do after a crash or a
power loss. The commands were run on a test machine; their output is shown with this page's paths. A first server on
a laptop: [the quick start](quickstart.md). Every key of `cluster.toml` and every command: [the server](server.md).

## The machine

| path | what it holds | owner |
|---|---|---|
| `/usr/local/bin/cepheus` | the server and its commands | root |
| `/etc/cepheus/` | `cluster.toml`, `tokens.toml`, the certificates and keys | cepheus, mode 0700 |
| `/var/lib/cepheus/` | the data: one folder a database, and the server's own files ([files of the server](server.md#files-of-the-server)) | cepheus, mode 0700 |
| `/run/cepheus/` | the Unix socket, made at each start | cepheus, group cepheus, mode 0750 |
| `/backup/cepheus/` | the nightly copies; on another disk, and copied to another machine | cepheus |

A user of its own for the server, the binary built as in the [quick start](quickstart.md#1-build-and-install), and a
cluster whose certificate names the machine's host name and address:

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

`cluster init` writes a `cluster.toml` for a laptop; on a server, change `[clients]` and `[storage]`, and name your
databases (a database declared here is made at the next start):

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

Then give the files to the server's user, and take the CA's key off the machine: it signs certificates and nothing
else ([TLS](server.md#tls)); put it back only to sign one with `cepheus cluster cert`:

```sh
sudo chown -R cepheus:cepheus /etc/cepheus
sudo chmod 700 /etc/cepheus
sudo mv /etc/cepheus/ca.key /root/cepheus-ca.key
```

A token for each program, and one with `--admin` for `cepheus status`. Each is shown once: write it to a file only its
reader may read (`umask 077`), and hand the program its own:

```sh
sudo -u cepheus sh -c 'umask 077; cepheus token add shop-web --database shop=write --config /etc/cepheus/cluster.toml > /etc/cepheus/shop-web.token'
sudo -u cepheus sh -c 'umask 077; cepheus token add ops --admin --config /etc/cepheus/cluster.toml > /etc/cepheus/ops.token'
```

```text
cepheus: token shop-web added to /etc/cepheus/tokens.toml; it is shown only now
cepheus: token ops added to /etc/cepheus/tokens.toml; it is shown only now
```

A program on this machine reaches the socket only if its user is in the group `cepheus` (`sudo usermod -aG cepheus
USER`); its token is still needed ([who may reach the socket](server.md#who-may-reach-the-socket)). Programs on other
machines connect over TCP with TLS, with the cluster's `ca.pem`.

## A service

`/etc/systemd/system/cepheus.service`:

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

- `Type=notify`: the server tells systemd it is ready once every database is open and the socket listens, so the
  services ordered after it start when it answers ([start](server.md#start-stop-crash)).
- `RuntimeDirectory` makes `/run/cepheus` at each start, owned by the server's user and group, mode 0750 (the server
  makes its socket 0660, so that the group's programs may connect); `StateDirectory` makes `/var/lib/cepheus` if it is
  missing, owned by the server's user, 0700 (a data directory others may enter is made 0700 by the server at its
  start, and its log says so).
- `Restart=on-failure`: after a kill, a crash, or the exit that follows a failed disk ([G10](guarantees.md#g10-stop-on-a-disk-error)),
  systemd starts the server again, and recovery decides what is durable. A clean stop (`systemctl stop`, SIGTERM)
  is not restarted.
- `TimeoutStopSec`: a stop waits for the writes in flight and for a merge under way, then closes every database; give
  it time rather than let systemd kill it (a kill is safe, but the next start then recovers).
- `LimitNOFILE` beside `max_connections` (512 by default): a connection holds a descriptor, and so do the databases'
  files ([cluster.toml](server.md#clustertoml)); raise both together.
- `MemoryMax` above the `cache` of `cluster.toml` and the changes since the last merge ([memory](operations.md#memory)).

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now cepheus
journalctl -u cepheus -n 1 -o cat
```

```text
cepheus: ready in 23.9 ms: shop at group 1; socket /run/cepheus/.s.cepheus.7400, tcp 0.0.0.0:7400; 4 I/O domains, at most 512 connections; server cph-s-9fa7ee8710147141, cluster cph-c-59f1eb5ca605aacd
```

## Backups

A database's journal is only appended to and its runs are written beside and renamed, so a copy needs no stop, in
this order: the database's id, its runs, then its segments ([backup and restore](operations.md#backup-and-restore)).
The copy holds every group confirmed before the copy of its segment started, the commit buffer's included. It leaves
out `lock`, `closed`, `shared` and `sessions`: the copy opens as a database of its own. Taken on a
[replica](server.md#backups-from-the-replica), it costs the primary nothing, and holds the groups the replica held.
`/usr/local/bin/cepheus-backup`:

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

Every night at 3:00, as the server's user, with `/etc/systemd/system/cepheus-backup.service`:

```ini
[Unit]
Description=Copy the Cepheus databases

[Service]
Type=oneshot
User=cepheus
Group=cepheus
ExecStart=/usr/local/bin/cepheus-backup /var/lib/cepheus /backup/cepheus
```

and `/etc/systemd/system/cepheus-backup.timer` (`Persistent`: a night the machine was off is made up at its start):

```ini
[Unit]
Description=Copy the Cepheus databases every night

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

Save the script as `cepheus-backup`, then:

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

Taken here while a program wrote 3,000 orders: the server was at group 832 when the copy started, and the copy opens
at group 837. Copy each night's folder to another machine (`rsync -a /backup/cepheus/ backup-host:cepheus/`): a copy
on the same disk does not survive the disk.

### The restore drill

A backup that was never opened is not a backup. Open the newest one on the backup machine, on a server of its own,
once a month and before every upgrade. On the machine of the live server it is refused, since it is a copy of a
database that server holds:

```text
cepheus: database shop: /dev/shm/cepheus-69b9b1ca0ae6b04bbc10fec328e3ddcd.visible is held by another server: a copy of this database's data directory runs on this machine
```

On the backup machine, as any user (port 7500, so that it never answers the live programs):

```sh
mkdir -p ~/drill-base
cepheus cluster init drill --dir ~/drill-base/drill
mkdir ~/drill-base/drill/data
cp -R /backup/cepheus/2026-11-12T194940/shop ~/drill-base/drill/data/shop
```

In `~/drill-base/drill/cluster.toml`, set `listen = "127.0.0.1:7500"` and the database's name, `name = "shop"`; then:

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

The drill passes when the server starts and the group is at least the one the live server showed when the copy
began. A copy that does not open names its damage, as below; restore the night before it. The full check of every
frame of the old segments, `Cepheus.verify` ([verification](operations.md#verification-scrubbing)), has no command yet:
it is a call of the OCaml API.

## What to watch

`cepheus status` prints one `key: value` a line. Poll it as the server's user, who may read the admin token, every
minute for example, and keep the lines with their time:

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
role: primary
database.shop.group: 6202
database.shop.facts: 12428
database.shop.resent: 1
database.shop.followers: 0
database.shop.frames: 679
database.shop.follow_ns_a_frame: 2483
database.shop.visible: 6217
database.shop.watches: 0
database.shop.epoch: 1
```

| line | what it is | watch for |
|---|---|---|
| `server`, `cluster` | the server's id (made at its first start, kept in `DATA/cepheus.server`) and the cluster's | a change: another server, or another data folder |
| `uptime_ms` | milliseconds since the start | lower than at the last poll: the server started again; read the log |
| `connections` | connections open now, local readers' included | near `max_connections`: new ones are refused, and the log says so |
| `requests` | requests answered since the start | a rate that falls while programs run |
| `gc_minor`, `gc_major` | the OCaml runtime's collections so far | beside the process's memory: a rate that keeps growing |
| `stopping` | a stop is under way | `true` outside a planned stop |
| `commit_buffer.rounds`, `.frames`, `.alone` | the buffer's fsyncs, the frames they made durable, the frames forced in their own journal (a database written alone) | `.frames` / `.rounds`: frames shared by one fsync ([commit buffer](server.md#many-databases-one-fsync-the-commit-buffer)) |
| `role` | `primary`; `replica of PEER` on a replica, with each database's `replica.*` lines; `primary (promoted from PEER)` after a `cepheus promote` ([what a replica serves](server.md#what-a-replica-serves)) | a change you did not make (a `cepheus promote`) |
| `database.NAME.group` | its newest durable group | flat while programs write: their writes fail; read their errors and the log |
| `database.NAME.facts` | facts in its newest state | growth, for the disk and the memory |
| `database.NAME.resent` | writes answered again from the session table: sent again after a broken connection, applied once ([G14](server.md#writes-applied-once-sessions-g14)) | a steady rise: connections break (the network, `idle_timeout`, restarts) |
| `database.NAME.followers` | programs of this machine that read in their own memory ([local reads](server.md#local-reads-g15)) | fewer than the programs that should |
| `database.NAME.frames`, `.follow_ns_a_frame` | frames published, and the server's mean time a frame to publish them to the local readers, in nanoseconds | a time that grows with `followers` |
| `database.NAME.visible` | the visibility number the local readers share (G15) | it moves with the frames |
| `database.NAME.watches` | live questions open ([Watch](cesia.md#watch-live-questions)) | more than the screens open |
| `database.NAME.epoch` | the database's epoch: 1, and one more at each promotion of a replica ([what a replica serves](server.md#what-a-replica-serves)) | a change you did not make |

Beside it, the disk: a full merge holds the database's base twice while it runs, and the journal keeps every group
for ever, so keep free at least the size of the largest database's runs, and watch the journal's growth
([disk space](operations.md#disk-space-and-merges)). And the log, `journalctl -u cepheus`: every line starts with
`cepheus:`, and these call for a look ([all of them](errors.md#lines-on-the-standard-error)):

| line | what to do |
|---|---|
| `N connections refused so far: the limit of M is reached (max_connections)` | raise `max_connections` and `LimitNOFILE`, or find the program that leaks connections |
| `accept: out of file descriptors or memory (raise LimitNOFILE, or lower max_connections)` | as it says |
| `background merge failed`, `a merge could not be installed`, `a merge could not catch up` | the disk: space, errors in the system's log; the database goes on with its old runs |
| `database NAME: the sessions could not be saved` | the disk; the next start reads more of the journal |
| `FILE not reloaded: MSG` | `tokens.toml` does not parse: the server keeps the tokens it had |
| `database NAME stopped: MSG`, before an exit | a failed disk: see [after a crash](#after-a-crash-or-a-power-loss) |

## Upgrades

1. Read what the new version changes in [the file formats](formats.md) and [the server](server.md), and run the
   [restore drill](#the-restore-drill) on the newest backup.
2. Build it, and install it over the old binary (the running server keeps its own copy open):
   `sudo install -m 755 _build/default/bin/main.exe /usr/local/bin/cepheus`.
3. `sudo systemctl restart cepheus`: a clean stop, which forces every journal and empties the commit buffer, then a
   start of the new version.
4. `journalctl -u cepheus -n 1 -o cat`: the ready line, every database at its group. An open that converts a format is
   slower once (below).
5. Rebuild the engine of the Cesia programs from the same commit, and their `cesia.lock`
   ([quick start](quickstart.md#3-a-project-for-the-program)): on the server's machine an engine reads the database's
   files itself ([local reads](cesia.md#local-reads)), so it must know the formats the server writes.

What a new version may do at its first start, once:

- **Runs of an earlier format** are set aside and their groups replayed from the journal, which holds them all: a
  slower open (5.2 s for 10 M facts from format 7), and the first merge writes the new format
  ([runs](formats.md#run-dirsnapshotslo-20-digits-hi-20-digitsrun)). Run format 9 (the text order of `Prefix`) came
  this way after format 8; an earlier version sets runs of format 9 aside in turn and replays the journal: going back
  costs one slow open, and loses nothing.

What goes one way only, so that going back to an earlier version needs a backup taken before the upgrade:

- **The journal's format.** A journal of format 1 is converted to format 2 at the first open, segment by segment
  ([formats](formats.md#a-group)); a version that reads only format 1 cannot read it afterwards.
- **The commit buffer.** Versions before it do not read `DATA/server.wal.1` and `.2`. Go back only after a clean stop,
  which removes them; after a crash, start this version once and stop it first
  ([a database of a server](operations.md#a-database-of-a-server)). Done here: the earlier version, started after a
  clean stop, opened the database at its group, and this version again after it.

## After a crash or a power loss

**What happens by itself.** systemd starts the server again (`Restart=on-failure`; after a power loss, at boot). Each
database recovers at its open: the commit buffer's frames written back into its journal, a torn end of the journal
cut, the groups after the newest run replayed ([recovery](operations.md#opening-and-recovery)). Every write that was
answered `Ok` is there (G1); a write in flight may or may not be, and the program's library sends it again: it is
applied once (G14). Here, a server killed with `kill -9` while a program wrote 2,000 orders:

```text
cepheus.service: Main process exited, code=killed, status=9/KILL
cepheus.service: Failed with result 'signal'.
cepheus.service: Scheduled restart job, restart counter is at 1.
cepheus: ready in 30.9 ms: shop at group 3846; socket /run/cepheus/.s.cepheus.7400, tcp 0.0.0.0:7400; 4 I/O domains, at most 512 connections; server cph-s-9fa7ee8710147141, cluster cph-c-59f1eb5ca605aacd
```

The program ended with `2000 orders answered Ok`, and the database held exactly 2,000 groups more than before it;
`database.shop.resent: 1` after it: the write in flight at the kill, sent again by the program and answered from the
session table.

**What to check.** `journalctl -u cepheus -b`: the ready line and the time of the opens; then `cepheus status`: each
database at a group at least as high as the last one its programs saw confirmed.

**When a database is damaged.** A start that finds durable bytes changed does not start: it exits and names the file
and the offset, for example after a byte flipped in a segment of a test copy:

```text
cepheus: database shop: damaged: 00000000000000000001.seg: damaged frame at offset 46961 (written whole)
```

systemd tries again until its start limit, and the log repeats the line. Do not delete files: copy the database's
folder aside, and restore it from the newest backup that passes the drill
([when recovery says `Damaged`](operations.md#when-recovery-says-damaged)); the message's meaning:
[errors](errors.md#damaged-durable-data-lost-or-changed).

**A failed disk.** A failed write or fsync stops the database and the server exits (`database NAME stopped: ...`);
systemd starts it again, and recovery decides what is durable ([G13](guarantees.md#g13-a-failed-fsync-is-never-trusted)).
A file system that turned read-only refuses the start until it is repaired: read the system's log for the disk's
error ([when a write returns `Io`](operations.md#when-a-write-returns-io)).

**A program that opens the files itself.** After a crash, a database the server held is refused to a program's own
process (`Busy`) until the server has started on it once ([a database of a server](operations.md#a-database-of-a-server)).

**The disk itself.** A power loss keeps what was answered `Ok` only if the disk keeps what `fsync` made durable:
consumer disks may hold writes in a volatile cache. Use disks with power-loss protection for data that matters
([disks](operations.md#disks)).
