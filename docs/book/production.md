# Running in production

How to run a Cepheus server on a machine of its own: as a systemd service, with backups taken every night and a
restore drill, what to watch in `cepheus status` and in the log (the times of questions and writes, the slow ones,
Prometheus), how to upgrade, and what to do after a crash or a
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

`cepheus backup` copies every database of the server while it serves, into a folder named by the date
([commands](server.md#commands)). It needs no stop and no token: run it as the server's user, who reads the data
directory. For each database, in the order that keeps a copy consistent while the server writes
([backup and restore](operations.md#backup-and-restore)): its id and its history of promotions; its runs, each opened
before the journal is listed (a merge that removes one meanwhile leaves it readable through its descriptor); its
segments, in the order of their names; its [vault](vault.md), after the journal, so that every file its facts cite is
in the copy. Then each copy is checked as [`cepheus verify`](operations.md#verification-scrubbing) checks a database
(every frame of the journal, every page of the runs, the vault's records), ended after its last whole frame (the frame
being written when it was copied is left out; a frame written whole that does not check is damage, never left out in
silence), forced to the disk, and marked closed. The copies are made in `DEST/DATE.partial`, renamed `DEST/DATE` only
once all of them are whole and forced: a dated folder is always whole; a backup killed midway leaves its `.partial`
folder, which the next backup removes (that name of this user's alone: nothing else in DEST is ever removed). DEST is
the server's user's own: a folder that other users may write is refused.

A copy holds every group confirmed before the copy of its journal started, the commit buffer's included (they are in
the journal's page cache), and never a torn one. It leaves out `lock`, `shared` and `sessions`, and opens as a
database of its own. Taken on a [replica](server.md#backups-from-the-replica), it costs the primary nothing and holds
the groups the replica held: with a primary and a replica, back up the replica.

```sh
sudo -u cepheus cepheus backup --config /etc/cepheus/cluster.toml /backup/cepheus
```

```text
shop: group 4954, 2.5 MB (journal 0.7 MB, runs 1.9 MB), 0.50 s
/backup/cepheus/2026-11-24T224915 (1.15 s)
```

A line a database (the group its copy holds, its size and time), then the folder. Taken here while a program wrote
200 groups a second: the server was at group 4947 when the backup started, and the copy holds group 4954. The exit
status: 0, done; 1, a copy has damage, named on its lines (the folder is kept as `DEST/DATE.damaged` for a look:
verify the live database once its server is stopped, and keep the backups before it); 2, refused or failed (another
backup writes into DEST, a DEST that other users may write, a database whose server crashed and must recover it
first, a full disk), and nothing is named `DEST/DATE`. `cepheus backup --help` says the same.

Every night at 3:00, as the server's user, with `/etc/systemd/system/cepheus-backup.service`:

```ini
[Unit]
Description=Copy the Cepheus databases

[Service]
Type=oneshot
User=cepheus
Group=cepheus
ExecStart=/usr/local/bin/cepheus backup --config /etc/cepheus/cluster.toml /backup/cepheus
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

```sh
sudo install -d -o cepheus -g cepheus -m 700 /backup/cepheus
sudo systemctl daemon-reload
sudo systemctl enable --now cepheus-backup.timer
sudo systemctl start cepheus-backup
journalctl -u cepheus-backup -n 2 -o cat
```

A failed backup is a failed unit (`systemctl --failed`, the exit status in the log): watch for it as for the server.
Copy each night's folder to another machine (`rsync -a /backup/cepheus/ backup-host:cepheus/`): a copy on the same
disk does not survive the disk. And keep a copy of `/etc/cepheus/vault.key` apart, once: the vault's files are sealed
by it, it is never in the data, and a backup of a vault opens no file without it ([the vault](vault.md)). Nothing
removes old backups: remove them yourself (`find /backup/cepheus -maxdepth 1 -name '20*' -mtime +30 -exec rm -r {} +`
keeps a month). How long a backup and a restore take at 10 M facts, beside PostgreSQL's `pg_basebackup` and
SQLite's `.backup`: [benchmarks](benchmarks.md#backup-and-restore-2026-11-24-at-10-million-facts).

### The restore drill

A backup that was never restored is not a backup. Restore the newest one once a month and before every upgrade:

```sh
mkdir -p ~/drill
cepheus restore /backup/cepheus/2026-11-24T224915/shop ~/drill/shop
```

```text
copied: journal 0.7 MB, runs 1.9 MB
group 4954: written 2026-11-24 22:49:15, through the token app
/home/you/drill/shop: restored from /backup/cepheus/2026-11-24T224915/shop at group 4954; its next writes open epoch 2 from group 4955 (0.69 s)
```

`cepheus restore` copies the backup into `DIR.restoring`, opens it as a server opens a database (every run checked,
the groups after the newest run replayed), checks every frame and page, and only then renames it `DIR`: a restore that
fails, or is killed, leaves no half database behind (the next restore removes what it left). It refuses a folder that
holds a database (`--replace` moves that one aside first, never removes it, even one that crashed) or that a running
server holds, and a folder beside a commit buffer that a server's unclean stop left when it holds frames of this
database ([backup and restore](operations.md#backup-and-restore)). The last
line names the group reached; the line before, when and through which token it was written. The drill passes when the
restore ends with exit status 0 at a group at least the one the live server showed when the backup began; a backup
that does not restore names its damage (exit status 1): restore the night before it. The restore opens the copy in
its own process, so the drill may run on the live server's machine; only serving the copy there is refused while the
live server runs, since the copy is one of its databases
(`/dev/shm/cepheus-ID.visible is held by another server`).

To try the programs against it, serve it on a server of its own (port 7500, so that it never answers the live
programs):

```sh
cepheus cluster init drill --dir ~/drill/etc
mkdir ~/drill/etc/data && mv ~/drill/shop ~/drill/etc/data/shop
sed -i 's/127.0.0.1:7400/127.0.0.1:7500/; s/^name = "main"/name = "shop"/' ~/drill/etc/cluster.toml
cepheus serve --config ~/drill/etc/cluster.toml
```

### Restoring to a group: undoing a bad write

The journal keeps every group, so a restore can stop just before the one that did the harm, as PostgreSQL's
point-in-time recovery stops its WAL's replay at a target. `--to-group N` restores up to group N; `--to-time T`, up to
the last group written at or before T (`2026-11-24T14:05`, or `14:05:30`, in the machine's local time, or UTC with a
final `Z`; exactly these digits and a day of the calendar: `2026-02-31` or `14:05:60` is refused, never moved to
another time). A write's receipt names its group (`Group` in Cesia, `receipt.group` in OCaml), and the restore prints the time and the token of the
group it reached: restore to a scratch folder first, and look.

```sh
cepheus restore /backup/cepheus/2026-11-24T224915/shop ~/drill/shop --to-group 4800 --replace
```

```text
copied: journal 0.7 MB, runs 1.9 MB
group 4800: written 2026-11-24 22:49:15, through the token app
/home/you/drill/shop: restored from /backup/cepheus/2026-11-24T224915/shop at group 4800; its next writes open epoch 2 from group 4801 (0.81 s)
the database that was there is kept in /home/you/drill/shop.before-restore-2026-11-24T224935: remove it once the restore is checked
```

In production, the server stopped first:

```sh
sudo systemctl stop cepheus
sudo -u cepheus cepheus restore /backup/cepheus/2026-11-24T224915/shop /var/lib/cepheus/shop --to-group 4800 --replace
sudo systemctl start cepheus
```

How: the runs of groups up to N are copied (a later run would hold the future), the segments up to N, and the frame
that holds N, when later groups share it, is written again without them; the open replays the groups from the newest
run kept up to N. A restore to an old group therefore replays the journal from the last run before it, as
PostgreSQL replays its WAL from its base backup. The writes after N are not lost: the database moved aside holds them
(it is a stopped database: `cepheus restore` restores from it too).

**Epochs.** A restored database writes its next groups in a new epoch, above every epoch its history and the
database it replaces knew ([epochs](server.md#promotion-by-hand)), as PostgreSQL's recovery to a point starts a new
timeline: the groups after N that a replica (or a program's local copy) still holds are
of the old history, and a replica that holds them is refused as diverged rather than followed as if they were this
database's. Make it again from the restored primary (`cepheus replicate`). When a primary's disk is lost and a replica
runs, promote the replica (`cepheus promote`) rather than restore: it holds every group the replica received, more
than the night's backup. A Raft cluster cannot be restored to a group yet: restore into a single server.

### From the script to the command

Before 2026-11-24 this page gave a shell script, `cepheus-backup DATA DEST`, which copies the same files in the same
order. It still works, and its copies restore with `cepheus restore` (a torn end, if the copy has one, is cut by the
open, as after a crash). `cepheus backup` does more: it checks each copy, cuts it at its last whole frame, forces it,
names the folder only once it is whole, copies the vault, refuses a second backup into the same folder, and fails
with its exit status instead of a folder that may be half made. To move, change the service's `ExecStart` line as
above and remove `/usr/local/bin/cepheus-backup`. The script, as it was:

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

## What to watch

`cepheus status` prints one `key: value` a line. Poll it as the server's user, who may read the admin token, every
minute for example, and keep the lines with their time:

```sh
sudo -u cepheus sh -c 'CEPHEUS_TOKEN=$(cat /etc/cepheus/ops.token) cepheus status --config /etc/cepheus/cluster.toml'
```

A shop's server, 14 s after its start on 100,000 invoices: 18,000 questions for a client's invoices, 70 writes of
1,000 invoices, an import of 300,000 in one group, 500 single writes, then four questions that read much (a real
run of the version this book describes):

```text
server: cph-s-9fa7ee8710147141
cluster: cph-c-59f1eb5ca605aacd
uptime_ms: 14195
connections: 1
requests: 18580
gc_minor: 4040
gc_major: 41
stopping: false
questions.timed_out: 1
questions.cancelled: 0
questions.helpers: 0
domains: 8
domains.cap: 128
commit_buffer.rounds: 0
commit_buffer.frames: 0
commit_buffer.alone: 570
role: primary
disk.free_bytes: 3799736320
disk.size_bytes: 240065183744
slow_ms: 200
latency_window_s: 60
cache.capacity_bytes: 4294967296
cache.resident_bytes: 1835008
cache.hits: 291
cache.misses: 217
database.shop.group: 673
database.shop.facts: 1410532
database.shop.resent: 0
database.shop.followers: 0
database.shop.frames: 571
database.shop.follow_ns_a_frame: 1977
database.shop.visible: 573
database.shop.watches: 0
database.shop.epoch: 1
database.shop.journal_bytes: 1808294
database.shop.runs_bytes: 6735456
database.shop.merges: 1
database.shop.merge_us_sum: 207384
database.shop.merge_bytes: 2678640
database.shop.questions: 18004
database.shop.questions_slow: 4
database.shop.question_us_sum: 6640904
database.shop.question_us_p50: 8
database.shop.question_us_p99: 17
database.shop.question_us_max: 2357964
database.shop.question_samples: 18004
database.shop.writes: 571
database.shop.writes_slow: 1
database.shop.write_us_sum: 3708511
database.shop.write_us_p50: 3135
database.shop.write_us_p99: 26623
database.shop.write_us_max: 624869
database.shop.write_samples: 571
```

| line | what it is | watch for |
|---|---|---|
| `server`, `cluster` | the server's id (made at its first start, kept in `DATA/cepheus.server`) and the cluster's | a change: another server, or another data folder |
| `uptime_ms` | milliseconds since the start | lower than at the last poll: the server started again; read the log |
| `connections` | connections open now, local readers' included | near `max_connections`: new ones are refused, and the log says so |
| `requests` | requests answered since the start | a rate that falls while programs run |
| `gc_minor`, `gc_major` | the OCaml runtime's collections so far | beside the process's memory: a rate that keeps growing |
| `stopping` | a stop is under way | `true` outside a planned stop |
| `questions.timed_out`, `questions.cancelled` | questions ended by their time (`question_timeout`, or a program's shorter one), and because their program closed its connection, since the start | a rate that grows: questions too wide for their time (read which programs ask them), or programs that give up |
| `questions.helpers` | the domains helping large questions now (parked a second after their last one) | always at its bound (the cores less one) while questions wait: the machine's cores are the limit |
| `domains`, `domains.cap` | the domains the server holds now (its own, its databases' writers', its connections', the questions' helpers), and the runtime's cap (`OCAMLRUNPARAM=d=N`, 128 by default) | `domains` near the cap: merges and questions then run on fewer domains ([limits](limits.md#files-and-the-platform)) |
| `commit_buffer.rounds`, `.frames`, `.alone` | the buffer's fsyncs, the frames they made durable, the frames forced in their own journal (a database written alone) | `.frames` / `.rounds`: frames shared by one fsync ([commit buffer](server.md#many-databases-one-fsync-the-commit-buffer)) |
| `role` | `primary`; `replica of PEER` on a replica, with each database's `replica.*` lines; `primary (promoted from PEER)` after a `cepheus promote` ([what a replica serves](server.md#what-a-replica-serves)) | a change you did not make (a `cepheus promote`) |
| `database.NAME.group` | its newest durable group | flat while programs write: their writes fail; read their errors and the log |
| `database.NAME.facts` | facts in its newest state | growth, for the disk and the memory |
| `database.NAME.resent` | writes answered again from the session table: sent again after a broken connection, applied once ([G14](server.md#writes-applied-once-sessions-g14)) | a steady rise: connections break (the network, `idle_timeout`, restarts) |
| `database.NAME.followers` | programs of this machine that read in their own memory ([local reads](server.md#local-reads-g15)) | fewer than the programs that should |
| `database.NAME.frames`, `.follow_ns_a_frame` | frames published, and the server's mean time a frame to publish them to the local readers, in nanoseconds | a time that grows with `followers` |
| `database.NAME.visible` | the visibility number the local readers share (G15) | it moves with the frames |
| `database.NAME.watches` | live questions open ([Watch](cesia.md#watch-live-questions)) | more than the screens open |
| `database.NAME.epoch` | the database's epoch: 1, and one more at each promotion of a replica ([what a replica serves](server.md#what-a-replica-serves)) and at each restore ([restoring to a group](#restoring-to-a-group-undoing-a-bad-write)) | a change you did not make |
| `slow_ms`, `latency_window_s` | `[log] slow_ms` of `cluster.toml` (0: no line), and the window of the percentiles below: the last 60 s (six slices of 10 s, the current one and the five before it: between 50 and 60 s of values) | |
| `cache.capacity_bytes`, `.resident_bytes` | the page cache's room (`[storage] cache`) and the pages it holds now, every database's together | `resident` at the room while `misses` rise: the cache is too small for what the questions read |
| `cache.hits`, `cache.misses` | since the start: reads of a page in memory that the cache's policy counted, and pages read from the disk (each checked by its CRC). A page read again and again while the policy has not looked at it again counts once: a read of such a page is one array read, counted nowhere, so `hits` is not every read, and their ratio is that of the reads the policy saw ([the cache](theory.md)) | a rate of `misses` that grows while the questions stay the same |
| `disk.free_bytes`, `.size_bytes` | the file system of the data folder: the bytes free for the server's user (statvfs's `f_bavail`), and its size | under the largest database's `runs_bytes` plus a day of journal: a full merge holds its runs twice while it runs ([disk space](operations.md#disk-space-and-merges)) |
| `database.NAME.journal_bytes`, `.runs_bytes` | the bytes of its journal's segments and of its runs, read from the disk at each status (a stat a file) | the journal grows for ever; the runs about once the data |
| `database.NAME.merges`, `.merge_us_sum`, `.merge_bytes` | since the start: merges installed, their time together in microseconds (a background merge's from its start to its catch-up), and the bytes of the runs they wrote | a mean time a merge that keeps growing at the same `merge_bytes` a merge: the disk |
| `database.NAME.questions`, `.questions_slow`, `.question_us_sum` | since the start: questions answered at the server (a Find, a watch's first answer; a program's local reads are not), those that took `slow_ms` or more, and their time together, in microseconds | a rate of `questions_slow`: their lines in the log say which ([slow questions](#slow-questions-and-writes)) |
| `database.NAME.question_us_p50`, `_p99`, `_max`, `.question_samples` | over the window: the time at the server in microseconds, from the request read to the reply coded, of the median question, the 99th percentile and the slowest, within 1/32 above (3.1 %); and how many questions the window holds (0: the times are 0) | a p99 that grows while `question_samples` stays the same: questions that read more, or a machine that has less |
| `database.NAME.writes`, `.writes_slow`, `.write_us_sum`, `.write_us_p50`, `_p99`, `_max`, `.write_samples` | the same for the writes, from the request read to the reply coded once its group is durable: the wait for the writer, the fsync and the commit buffer are in it (a write answered again from its session's table, or refused before the writer, is not counted) | a p99 that grows: the disk's fsyncs (compare `commit_buffer.frames` / `.rounds`), a merge's switch, or large groups |

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
| `slow question: ...`, `slow write: ...` | below |

### Slow questions and writes

A question or a write that takes `[log] slow_ms` or more (200 ms by default; 0: none) gets one line; those of the
server above:

```text
cepheus: slow question: database shop, token shop-web, 2092.8 ms, 36761990 candidates, 1 row, ok: find group count where [x0 invoice/client ?] [x1 invoice/status ?]
cepheus: slow question: database shop, token shop-web, 1722.7 ms, 37074621 candidates, 20 rows, ok: find give x0 x1 where [x0 invoice/status ?] [x0 invoice/client x2] [x1 invoice/client x2] sort column 1 desc limit 20
cepheus: slow question: database shop, token shop-web, 2358.0 ms, 36761990 candidates, ok: watch group count where [x0 invoice/client ?] [x1 invoice/status ?]
cepheus: slow question: database shop, token shop-web, 303.0 ms, 20111134 candidates, 0 rows, timeout: find group count where [x0 invoice/status ?] [x1 invoice/status ?] [x2 invoice/status ?]
cepheus: slow write: database shop, token shop-web, 624.9 ms, group 173, ok: 900000 operations (900000 adds) of invoice/status, invoice/total, invoice/client
```

- **What it holds**: the database, the name of the token (never the token), the time at the server (from the request
  read to the reply coded; a write's once its group is durable), and the outcome: `ok`, or the code of its error
  (`timeout`, `cancelled` when its program closed its connection, `too_large`, `invalid`, `conflict`...), never the
  error's message, which may quote a value. A question then says its candidates (the count its work budget counts:
  [limits](limits.md#questions)), its rows (a Find's; a watch's first answer gives none here) and its **shape**: its
  select, its patterns with their properties' names, its variables `x0`, `x1`..., its conditions and its order, each
  constant written `?` (a thing, a value, a range's bounds, a prefix, an `After`'s row; an `In`'s values counted, a
  `Limit` given: a page's size, not a value of the data). A write says its operations by kind, the properties it
  names (the first 8; "and others" past them) and its group.
- **No value of the data, no token**: a property's name is the schema's, escaped as every name of the log (a byte
  outside printable ASCII written `\ddd`), and a line is cut at 2,000 bytes. So the log can go where the data may not
  (a log service), and a token that may read leaks nothing through it. `test/server_observe.ml` asks slow questions
  and writes values of its own, then searches the log for each: none is found.
- **At most 10 lines a second**: the next line written says how many were left out (`(and N slow questions or writes
  not written since the line before)`), and `questions_slow` and `writes_slow` count every one. A machine slow for
  everything writes 10 lines a second, not one a question.
- **How to read it**: many candidates for few rows is a question that reads much to keep little: a more selective
  pattern first (a constant), a range, or a page with `Sort` and `Limit` on the index path. Candidates near the rows,
  and a long time, is a machine that is busy (the cores, the disk: `cache.misses`). A slow write with few operations is
  a wait: the fsync (`write_us_p99`), a merge's switch, or a large group ahead of it in the writer.

### With Prometheus

`cepheus status --format prometheus` prints the same numbers in Prometheus's text exposition format, version 0.0.4
(prometheus.io/docs/instrumenting/exposition_formats/): one family a key, in base units (seconds, bytes), a
database's with the label `database`, a replica's or a Raft peer's with `peer`; the times of questions and writes as
summaries (quantiles 0.5, 0.99 and 1, the maximum, over the window, NaN when it is empty; `_sum` and `_count` since
the start, as a summary's are); the ids and the role as labels of a sample of 1, and no other text (an error's
message is left out). It reads the server through its socket with the admin token, as `cepheus status` does, so the
server opens no HTTP port: one listener, one way in. For node_exporter's textfile collector, from a timer or cron
every minute (write beside, then rename, so that the collector never reads half a file):

```sh
#!/bin/sh
# /usr/local/bin/cepheus-metrics: cepheus status for node_exporter (--collector.textfile.directory=/var/lib/node_exporter)
set -eu
out=/var/lib/node_exporter/cepheus.prom
CEPHEUS_TOKEN=$(cat /etc/cepheus/ops.token) cepheus status --format prometheus --config /etc/cepheus/cluster.toml > "$out.tmp"
mv "$out.tmp" "$out"
```

```text
# HELP cepheus_database_question_seconds Time of a question at the server, from its request to its reply
# TYPE cepheus_database_question_seconds summary
cepheus_database_question_seconds_count{database="shop"} 18004
cepheus_database_question_seconds_sum{database="shop"} 6.640904
cepheus_database_question_seconds{database="shop",quantile="0.5"} 0.000008
cepheus_database_question_seconds{database="shop",quantile="0.99"} 0.000017
cepheus_database_question_seconds{database="shop",quantile="1"} 2.357964
# HELP cepheus_database_writes_slow_total Writes that took the slow time or more
# TYPE cepheus_database_writes_slow_total counter
cepheus_database_writes_slow_total{database="shop"} 1
```

Alerts worth having: `rate(cepheus_database_questions_slow_total[5m]) > 0`, a
`cepheus_database_write_seconds{quantile="0.99"}` above the disk's usual fsync, `cepheus_disk_free_bytes` under the
largest `cepheus_database_runs_bytes`, and `time() - node_textfile_mtime_seconds{file="cepheus.prom"}` above a few
minutes (the cron stopped, or the server does not answer).

### What timing costs

Each question and write is timed at the server by two reads of the monotonic clock (`clock_gettime` through the
vDSO, 17 ns alone on the [benchmarks' machine](benchmarks.md)) and a record into three cache lines of its domain's
slices (4 ns). The start is the read the connection makes anyway after its bytes come, for its idle limit, and the
end gives the idle limit its last request, so a program that waits for each answer makes the server read the clock
no more often than before. Measured with the processor's counters (`perf_event_open`, user space: the serving
thread's instructions, the whole server's cycles), two servers up at once, each on a database of 100,000 things
(swapped at each round), their bursts asked in ABBA order, 21 rounds, the servers on one core and the client on
another:

| a point question (a unique value) | instructions | cycles |
|---|---|---|
| one in flight (each answer awaited) | +215 a question, +0.85 % (25,220 before, every round) | not measurable: ±15 % from round to round (the thread's wake-up) |
| 32 in flight | +86 a question (median), geometric mean +0.9 % (95 %: 0.1 to 1.75 %) | +4.1 % (95 %: 2.5 to 5.7 %) |

With 32 in flight, questions read together need a read of the clock each at their end, amid their reads of memory,
which that read waits for (the vDSO orders its read of the TSC): about 2.5 % of the 4.1 % (the same server without
its clock reads and record: +1.6 %, interval -0.04 to 3.3 %). A same-code control (one function added, never run)
gives 1.0014 (0.987 to 1.016): the floor of the method. A write waits for its fsync, about 4 ms on this disk: its
time is lost in it (B/A 0.96, interval 0.94 to 1.17). `cepheus status` costs a readdir and a stat a file of each
database, a statvfs and a copy of the slices, with no lock of the server held.

### Beside the giants

- **PostgreSQL** logs a statement that took at least `log_min_duration_statement` ("Causes the duration of each
  completed statement to be logged if the statement ran for at least the specified amount of time", off by default),
  its text with its values, which may put personal data in the log; Cepheus writes the shape, never the values.
  `pg_stat_statements`, a contrib module loaded by `shared_preload_libraries`, keeps every statement's shape (its
  constants replaced) with its calls, total and mean time, rows and blocks: better than Cepheus, which keeps no
  table of shapes, only the slow ones' lines and a histogram a database. Its statistics are SQL views
  (`pg_stat_database`, `pg_stat_bgwriter`...), read by an exporter of its own; its `blks_hit` counts every read of a
  buffer, where Cepheus's `cache.hits` counts the policy's. Its `auto_explain` logs a slow statement's plan too;
  Cepheus logs no plan. Neither has percentiles: pg_stat_statements has the mean, the minimum, the maximum and the
  standard deviation.
- **Timing's own cost**: PostgreSQL leaves `track_io_timing` off by default "as it will repeatedly query the operating
  system for the current time, which may cause significant overhead on some platforms", and ships `pg_test_timing`
  to measure that clock; `pg_stat_statements` reads the clock around every statement, as Cepheus does around every
  question.
- **SQLite** has none of this: a program times its own statements (`sqlite3_trace_v2`, `sqlite3_profile`).
- **Datomic** Pro calls a function of the operator's every minute with its metrics (`datomic.metricsCallback`: for
  each, such as a transaction's or a storage read's time, its count, sum, minimum and maximum), and Datomic Cloud
  sends them to CloudWatch; no percentile either.
- **Prometheus's exporters** for PostgreSQL and MySQL are other processes that connect with a user of their own;
  `cepheus status --format prometheus` is that exporter, with the admin token, and no process that runs between two
  polls.

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

systemd tries again until its start limit, and the log repeats the line. Do not delete files: `cepheus verify
/var/lib/cepheus/shop` names every damage of the database, and changes nothing; then restore the newest backup that
passes the drill over it, the server stopped (`cepheus restore BACKUP/shop /var/lib/cepheus/shop --replace`, which
keeps the damaged folder aside) ([when recovery says `Damaged`](operations.md#when-recovery-says-damaged)); the
message's meaning: [errors](errors.md#damaged-durable-data-lost-or-changed).

**A failed disk.** A failed write or fsync stops the database and the server exits (`database NAME stopped: ...`);
systemd starts it again, and recovery decides what is durable ([G13](guarantees.md#g13-a-failed-fsync-is-never-trusted)).
A file system that turned read-only refuses the start until it is repaired: read the system's log for the disk's
error ([when a write returns `Io`](operations.md#when-a-write-returns-io)).

**A program that opens the files itself.** After a crash, a database the server held is refused to a program's own
process (`Busy`) until the server has started on it once ([a database of a server](operations.md#a-database-of-a-server)).

**The disk itself.** A power loss keeps what was answered `Ok` only if the disk keeps what `fsync` made durable:
consumer disks may hold writes in a volatile cache. Use disks with power-loss protection for data that matters
([disks](operations.md#disks)).
