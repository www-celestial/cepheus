# The server

Cepheus runs as a server, as PostgreSQL does: one process on a machine holds its databases, and programs connect to
it. This page is the whole of it: what the server is and why it is built this way, how to run it (`cluster.toml`,
tokens, the commands, start, stop, crash), one fsync for the writes of all its databases (the commit buffer), the
wire protocol byte by byte, reads in a program's own memory on the
server's machine, security, the three guarantees the server adds (G14, G15 and G16), and its speed beside
PostgreSQL 18.6, server against server, on one machine.

Terms are explained at their first use and in the [glossary](glossary.md). The engine inside the server is the one
the other pages describe ([architecture](architecture.md)); its guarantees G1 to G13 hold through the server
([guarantees](guarantees.md)).

## What it is, and why

A **server** here is a long-running process that owns the databases' files and answers requests sent over a
**socket** (a channel of the kernel between two processes: a **Unix-domain socket** links two processes of one machine
through a path in the file system; **TCP** links two machines, or two processes of one machine through the
**loopback** address 127.0.0.1). A program is a **client**: it connects, proves who it is, and sends requests.

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

Why a server rather than a library opened by each program:

- **One writer, without a lock between programs.** A database has one writer ([G9](guarantees.md#g9-one-writer)).
  In a server, every program's writes reach that writer through the socket, and their groups share its fsyncs (group
  commit across programs, [architecture](architecture.md#the-journal-a-write-ahead-log)).
- **Rights.** A program receives exactly the rights of its token, database by database (G16); it needs no permission
  on the data's files.
- **The path to several machines.** Replication and Raft ([a replica](#a-replica), [a cluster of
  three](#a-cluster-of-three-raft)) are server to server; a program keeps the same code.

Why **OCaml domains and threads**: OCaml 5 runs threads of one domain one at a time (they share the domain's runtime
lock, which a system call releases, and decoding, reading the indexes and coding do not); domains run in parallel. A
**domain** is an OCaml unit of parallelism with its own runtime lock and minor heap, mapped to a system thread. The
server spreads its connections over k I/O domains (round robin), so k requests run at once on k cores; within a
domain, a **thread a connection** blocks in its read and needs no event loop. Reads take no lock between them: a view
is a persistent value ([concepts](concepts.md#views)). The measured effect is in [the benchmarks](#speed-beside-postgresql).

## Running a server

### cluster.toml

The configuration of a server, the same file on every machine of a cluster but for `me` (a single machine is a
cluster of one peer). Every key, and every rule it is checked against before anything opens:

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

[[database]]                       # at least one; names unique: lower-case letters, digits, '_', '-', at most 64
name = "shop"
[[database]]
name = "stock"
```

- Relative paths are relative to the directory of `cluster.toml`.
- `[clients]` needs `socket`, `listen`, or both. `listen` needs `[tls]`: over TCP, a program always speaks TLS, so
  its token never crosses a network in clear (one way, even on loopback).
- An unknown section or key, a missing one, a wrong type, two databases or peers of one name: the server refuses to
  start, and says which line or key (a configuration is never guessed).
- A database declared and not yet on disk is created at the first start (its directory under `data`).
- `max_connections` bounds the connections open at once, from their accept to their close (a thread each, and a file
  descriptor). At the limit a new connection takes the slot of the oldest connection that has shown no token yet,
  which is closed without a word (a connection that has shown its token is never taken: peers that connect and send
  nothing cannot keep programs out); when every connection has shown one, the new one is closed at once: over the
  Unix socket after an error frame `too_many_connections`, over TCP without a word and before its TLS handshake, so that a refused connection costs the
  server no handshake (its key exchange and signature: a whole new TLS connection costs 2.6 ms, both sides,
  [measured below](#speed-beside-postgresql)). The log says how many were refused, at most once a second. The
  default, 512, leaves room under systemd's default limit of 1,024 descriptors a service (`LimitNOFILE`), which the
  databases' files share (a journal segment, a run file a level); raise both together. A server out of descriptors
  says so in its log and keeps accepting once some close (`accept` fails with `EMFILE`; the connection waits in the
  kernel's queue).
- `idle_timeout`: a connection must send a whole request within this many seconds of its previous request, and must
  take what the server sends within as long; otherwise the server sends it an error frame `idle` (request id 0) and
  closes it. Before its Hello it has 10 s from its accept (or `idle_timeout`, when shorter) for its TLS handshake and
  its Hello, whatever `idle_timeout` is (0 included); a program's client gives up after 5 s. Bytes that trickle in
  without making a request do not keep a connection open: the clock is checked after every read, inside the TLS
  handshake and inside a TLS record too, so a peer that sends a byte at a time, each within the socket's timeout, is
  closed (Slowloris, R. Hansen 2009). A program's library keeps its connection alive with `Ping`, or connects again: the OCaml
  client sends a read (Open, Get, Find, Ping, status) again on a new connection after a broken one, within its retry
  budget, as it does for writes (G14). PostgreSQL's `idle_session_timeout` is off by default and its
  `authentication_timeout` is one minute; Redis's `timeout` is off by default.
- `question_timeout`: a question (a Find, the first answer of a Watch) ends with the error `timeout` once it has run
  this many seconds, its message naming the time; the work stops there (it is looked at every 1,024 candidates of
  each of its domains, a read of the monotonic clock, which costs a question under 1 % measured). A program may give a
  question a shorter time (`timeout` in Cesia, `?timeout` in OCaml: protocol 6); a longer one counts only from an
  admin token, so that a token that may read cannot take more of the server's cores than the server gives every
  program. A question whose program closed its connection stops too, its domains given back (the connection is
  looked at with `poll`'s `POLLRDHUP` at most every 10 ms of the question: PostgreSQL's
  `client_connection_check_interval`, off by default there). PostgreSQL's `statement_timeout` is off by default;
  SQLite has no setting of its own (a program's `sqlite3_progress_handler` or `sqlite3_interrupt`); Datomic takes a
  query's `:timeout`. Writes have no time: a group is all or nothing, and the writer's own budgets bound it
  ([limits](limits.md#writes)).

### tokens.toml

The tokens of the programs, beside `cluster.toml`, readable by the server's user only (mode 0600). It holds hashes,
never tokens; the commands below write it.

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

- `read`: Open, Get, Find on that database. `write`: read and Write. `admin = true`: the server's operations
  (`status`); no data right by itself.
- **Rights per kind**, `{ read = [...], add = [...] }`: the right to read, and to add to, only the kinds named. A
  property's **kind** is its name up to its first `/`: `invoice/Total` is of the kind `invoice`, as the Cesia client's
  `cepheus.Kind("invoice", ...)` names it. See [Rights](#rights-g16).
- The server reads the file again within a second of a change (its time, size or inode); a token removed, or whose
  rights shrank, takes effect at the next request of every connection that holds it (G16). A file that does not
  parse is not loaded (the server says why, and keeps the tokens it had).
- A missing file holds no token: the server then refuses every program.

### Commands

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
cepheus token add NAME --database DB=read|write|read:KIND,...;add:KIND,... ... [--admin] --config FILE
                                         a new token, printed once on stdout (cph_ and 43 characters); its hash goes
                                         to tokens.toml
cepheus token list --config FILE         names and rights (never the tokens)
cepheus token remove NAME --config FILE  removed: its connections are refused at their next request
cepheus replicate PEER --config FILE     this server, stopped, becomes a replica of PEER at its next start
                                         (DATA/cepheus.role; [a replica](#a-replica))
cepheus promote [--force] --config FILE  the running replica becomes a primary; an admin token in CEPHEUS_TOKEN;
                                         --force without its primary's handover
```

A first server on a laptop:

```sh
cepheus cluster init shop --dir ~/shop
cepheus token add app --database main=write --config ~/shop/cluster.toml > ~/shop/app.token
cepheus serve --config ~/shop/cluster.toml &
# a program connects to ~/shop/run/.s.cepheus.7400 with the token of app.token
```

`cepheus status` prints one `key: value` a line: `server` (the server's id, made at its first start and kept in
`data/cepheus.server`), `cluster`, `uptime_ms`, `connections`, `requests`, `gc_minor` and `gc_major` (the OCaml
runtime's collections so far), `stopping`, and for each database
`database.NAME.group` (its newest durable group), `.facts` and `.resent` (writes answered again from the session
table, G14); `role` and the replicas' lines ([a replica](#what-a-replica-serves)).

### Files of the server

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

### Start, stop, crash

**Start.** Read and check `cluster.toml` and `tokens.toml`; take the data directory's lock (a second server on the
same data is refused: G9 lifted to the server); read the commit buffer's files ([below](#many-databases-one-fsync-the-commit-buffer));
open every database, in parallel (a domain each, at most `domains` at once), each with its recovery
([operations](operations.md#opening-and-recovery)), which first writes again into its journal the frames the buffer
holds for it, and its session table (its checkpoint, then the journal after it); empty the buffer and start its
rounds; open the listeners (a socket file left by a server that died is removed; one a live
server answers on is refused); start the I/O domains; tell systemd it is ready (`READY=1` on `$NOTIFY_SOCKET`, one
datagram: `sd_notify(3)`). The server prints one line: the time of the opens, each database's group, the listeners.

**Stop** (`SIGTERM`, `SIGINT`, `cepheus stop`). No new connection; new requests get `Err stopping`; the writes in
flight become durable and are answered; each database is closed cleanly (its journal forced, its `closed` marker: the
next open forces nothing) and its session table saved; the commit buffer's files are removed; the socket file is
removed; exit 0.

**Crash** (kill -9, power loss). Each database recovers as the engine does at its next start (G1 to G13), with the
frames the commit buffer kept; the session tables are rebuilt from their checkpoints and the journal (G14). A program's library connects again and sends its
unanswered writes again: each is applied once.

**A failed disk.** When a database's writer stops on a failed write or fsync ([G10](guarantees.md#g10-stop-on-a-disk-error)),
the server stops (within a second) and exits with an error: systemd starts it again, and recovery decides what is
durable ([G13](guarantees.md#g13-a-failed-fsync-is-never-trusted)). PostgreSQL does the same since its releases of
14 February 2019 (11.2, 10.7, 9.6.12...): a failed fsync stops it (PANIC) rather than being retried, because "fsync()
will report back that it succeeded, but the data ... would not actually be written" (its release notes; the setting
`data_sync_retry`, off by default, restores the old behaviour).

A systemd unit:

```ini
[Service]
Type=notify
ExecStart=/usr/local/bin/cepheus serve --config /etc/cepheus/cluster.toml
User=cepheus
Restart=on-failure
TimeoutStopSec=120
MemoryMax=8G
```

## Many databases, one fsync: the commit buffer

**Why.** A write is confirmed once its frame is durable, and making bytes durable costs an **fsync** (the system call
that returns once the disk holds what was written to a file: from 3 ms on this machine's SSD). Within one database the
writes that arrive while an fsync runs share the next one (group commit, [architecture](architecture.md#the-journal-a-write-ahead-log)).
Across databases they did not while each database forced its own journal: 64 databases written at once made 64
fsyncs of 64 files, and a write waited 24.1 ms at the median against 3.07 ms with one database written (`sbench.exe
mwrite`, $n = 5$, before the buffer). PostgreSQL's databases share one **WAL** (write-ahead log: the file where every
change is made durable before it counts), so the commits of all of them group.

**What it does.** The server keeps one log of its own, the **commit buffer** (`DATA/server.wal.1` and `.2`,
`src/wal.ml`; byte layout in [formats](formats.md#the-servers-files)):

```
database d1: frame -> d1's journal (written, no fsync) --+
database d2: frame -> d2's journal (written, no fsync) --+--> a round: d1's frame | d2's frame | ...
database dN: frame -> dN's journal (written, no fsync) --+      appended to DATA/server.wal.N, one fsync,
                                                                then each of its frames is confirmed
```

Each database's syncer writes its frame to its journal without an fsync, gives a copy to the buffer, and waits for
that frame's confirmation before it writes its next one (one frame in flight a database: recovery needs it, below). A
**round** takes every frame that came while the previous round was forced, appends them as one record to the
buffer's active file, and forces it once; then every frame of the round is confirmed. One round is in flight at a
time, so at 64 databases written at once, one fsync confirms up to 64 frames. A frame that comes when the buffer is
idle (no round written or waiting) and no journal is forcing one of its own is forced in its own journal, as before
the buffer: a database written alone pays no second write, and the frames of the others that come meanwhile share the
next round. `cepheus status` counts them: `commit_buffer.rounds`, `commit_buffer.frames` (the frames the rounds
forced) and `commit_buffer.alone` (the frames forced in their own journal).

Each journal stays the truth of its database (its runs, its recovery, its backups and its local readers are as
before); the buffer holds a second copy of each frame only until a **checkpoint** of its journal (an fsync of it). Its
two files alternate: when the active one passes 64 MB, the next round goes to the other one, once it is clean; the
server's cleaner thread forces each journal that has frames in the old file, after which that file may be begun again
(its header and first round written beside, forced, renamed over it). A journal is also forced when it leaves a
segment, before a merge names a run (no run rests on frames the buffer alone holds), and at close. A frame longer
than 1 MiB, and a large group's frame, is forced in its own journal and not copied: written twice, it would cost more
than its own fsync.

**Recovery.** After a power loss, the frames a journal wrote after its last fsync may each be lost, kept or torn, the
one independently of the other: a journal's own rule (a torn tail is cut; a frame that checks after one that does not
is damage) would cut confirmed frames, or take a hole followed by a kept frame for damage. So at start, before it
opens its databases, the server reads both files of the buffer (the newer one may end with a torn round: the one in
flight at the crash, never confirmed); each database's open writes the buffer's frames for it again at their place in
its journal, even where the page cache already shows them (a failed fsync may have marked those pages clean: only a
write makes them dirty again, [G13](guarantees.md#g13-a-failed-fsync-is-never-trusted)), and forces them; every frame
before the last of them that the buffer does not hold must check (it was forced: else `Damaged`); the journal's own
rule then takes what follows, at most the one frame in flight. Then both files are removed and the rounds start. A
clean stop forces every journal and removes the files: a start after it reads nothing.

**Faults.** A failed write or fsync of the buffer, or of a journal at a checkpoint, stops the buffer: every later
write fails with `Io` and nothing more is confirmed ([G10](guarantees.md#g10-stop-on-a-disk-error)); the failed round
is cut back off its file at once; the database whose write failed stops, and the server exits within a second, as
above. A database opened by a server is refused by a program's own process after a crash, until the server has
started on it once: [operations](operations.md#a-database-of-a-server), where going back to an earlier version is
explained too.

**What it gains and costs** (2026-11-12, the machine of the other benchmarks, release builds; `sbench.exe mwrite`: a
server of 64 empty databases started on a fresh copy of them, D databases written at once for 5 s, W writers each;
this version against main 1b12c35, the one before the buffer, alternated in each round, each run under the
benchmarks' lock and on a quiet machine; $n = 7$ rounds; medians, the ratio with / before within each round, and
intervals between the smallest and the largest value, 98.4 %):

| written | groups a second, before / with | ratio by round | wait at the median, before / with |
|---|---|---|---|
| 64 databases, 1 writer each | 2,637 / 5,870 | 2.20 [1.70, 3.82], higher in 7 rounds of 7 | 22.5 / 8.0 ms |
| 16 databases, 1 writer each | 1,423 / 1,498 | 0.98 [0.88, 1.46] | 9.98 / 6.75 ms (lower in 7 of 7); p99 27.0 / 35.6 ms |
| 1 database, 1 writer | 308 / 263 | 0.86 [0.66, 1.21] | 2.86 / 2.99 ms |
| 1 database, 16 writers | 2,447 / 2,083 | 0.88 [0.27, 1.08] | 5.73 / 6.01 ms |

- At 64 databases one fsync confirms the frames of many: 2.2 times the writes, a write waiting a third as long.
- At 16, the median wait falls by a third, but the writes a second do not rise: the slowest writes wait longer (p99
  27.0 / 35.6 ms), and the ratio's interval holds 1. A round then holds 8 frames on average (`cepheus status` after
  2 s: 441 rounds, 3,526 frames, 1 frame alone). These 16 databases ran right after the 64: the measure below,
  in the other order, finds 1.55 times the writes.
- A database written alone has its frames forced in its own journal (the rule above; `cepheus status`: no round).
  The first version of the buffer, without that rule, made one database's 16 writers 18 % slower (2,240 / 1,843
  groups a second, the median wait higher in 7 rounds of 7); with it, the difference is within the noise (each
  ratio's interval holds 1), and so on one database of 1 M facts (`sbench.exe write`, $n = 5$, intervals of 93.8 %): one client 305 / 287 groups a
  second (ratio 0.95 [0.83, 1.28]), 16 clients 2,296 / 2,145 (0.94 [0.56, 1.43]). The median wait is 4 to 7 % higher
  in each of these four measures, though: a small cost may remain that these rounds cannot tell from the noise.
- A start after a clean stop (64 databases, $n = 7$): 215 / 199 ms (ratio 1.10 [0.23, 1.62]). The first start of
  this version on databases made before it writes a `shared` marker in each, with an fsync of its directory: at 64
  databases 849 / 1,250 ms, once.

**Measured again** with the chunked loads and the open's reads in the file's order (537d03a against main 1b12c35,
the same method), the cases in the other order: one database first, then 16, then 64, so that no case starts while
the disk still writes back what a run of 64 databases left. $n = 8$ rounds (21 were planned; a power loss cut the
9th, and only whole rounds are kept), intervals between the smallest and the largest value, 99.2 %:

| written | groups a second, before / with | ratio by round | wait at the median, before / with |
|---|---|---|---|
| 1 database, 1 writer | 261 / 277 | 1.10 [0.59, 1.73], higher in 5 rounds of 8 | 3.17 / 2.94 ms |
| 1 database, 16 writers | 2,283 / 2,374 | 1.03 [0.80, 1.22], higher in 5 of 8 | 5.94 / 5.76 ms |
| 16 databases, 1 writer each | 1,284 / 2,049 | 1.55 [1.17, 2.10], higher in 8 of 8 | 10.4 / 6.48 ms (lower in 8 of 8); p99 29.7 / 23.9 ms |
| 64 databases, 1 writer each | 2,841 / 6,356 | 2.25 [1.64, 4.17], higher in 8 of 8 | 21.9 / 7.56 ms; p99 47.0 / 29.6 ms |

- The order makes the difference at 16 databases. The buffer writes each frame twice: once in the buffer, forced to
  the disk, and once in its database's journal, left in the system's memory until the system writes it out (these
  pages in memory not yet on the disk are the dirty pages, `Dirty` in `/proc/meminfo`). After a run of 64 databases
  the next run starts with 3.4 to 10.3 MB of dirty pages, against 0.3 to 0.9 MB before the buffer, and the file
  system writes them out during that run (a btrfs commit of 814 ms fell in one). Run first, 16 databases get 1.55
  times the writes and a lower p99, in 8 rounds of 8 (sign test: p = 0.008).
- A database written alone: no cost in either order (16 writers right after 64 databases, $n = 7$: ratio 0.97
  [0.82, 1.19]; first, above: 1.10 and 1.03). A cost smaller than the noise of these rounds is not ruled out.

**Tested by** `test/wal_sim.ml` (three databases sharing one buffer whose files alternate after 300 to 3,300 bytes:
writes, rounds, cleanings, merges, large groups and long frames, process deaths, power losses, crashes inside any disk
call, recovery's too, failed fsyncs of the buffer and of the journals, a version without the buffer opening a
database after a crash; after every recovery each database holds every confirmed group, exactly the groups written,
in order; `BUFFER_SEEDS`, 300 in `tools/test.sh`), `test/exhaustive.ml` part 6 (every crash point of a fixed run of two
databases, every fsync of it failing in turn, with a reopen in the same boot), and `test/server_crash.ml` (a real
server of two databases, killed 20 times under writing clients: every receipt's write is there, once).
**Model-checked**: `spec/CommitBuffer.tla` ([testing](testing.md#model-checking)).

## The protocol

### Framing

A connection carries **frames** both ways. A frame is a length first, so a reader takes a whole frame without
parsing it, and refuses one over the limit before reading it:

```
frame  = length u32 LE (the bytes after this field, 6 to 16 MiB + 6) | id u32 LE | kind u8 | flags u8 | body
flags  = bit 0 more: the reply continues in the next frame of this id (the rows of a Find)
         bit 1 error: the body is an error
```

- `id`: chosen by the client; a reply carries its request's id and kind.
- A frame over 16 MiB is answered `too_large` and the connection closes: a peer that announces 4 GiB cannot make the
  server allocate it. Before Hello the limit is 4 KiB: a peer that has shown no token holds 64 KiB of the server's
  memory at most. A count inside a body (of facts, of rows, of operations) larger than the bytes that remain is
  refused before anything is allocated.
- **Values** are coded as in the journal ([formats](formats.md)): a tag byte (0 int, 1 float, 2 false, 3 true, 4 text,
  5 date, 6 money, 7 link), then a zigzag varint, 8 bytes of a float, or a length and the bytes of a text. A
  **varint** is an integer in 7-bit groups, low first, the high bit of each byte saying "more" (LEB128); **zigzag**
  maps 0, -1, 1, -2... to 0, 1, 2, 3... so small negatives stay short. One coding of values everywhere: journal, wire,
  and later replication.

### Requests and replies

| kind | request body | reply body |
|---|---|---|
| 1 Hello | version varint (1 to 6), token string, program string, session varint (0: a new one) | Welcome: server id, cluster id, session, frame limit, writes in flight limit; a second Hello on a connection is `invalid` (its token stays the first's) |
| 2 Open | database name | Opened: handle, newest group, the properties (id, name, type code, many, unique); past the frame limit, in frames of about 1 MiB of properties, all but the last with `more`, each with its handle, group and count |
| 3 Get | handle, thing | Facts: the view's group, count, (property, value)...; past the frame limit, in frames of about 1 MiB of facts, all but the last with `more`, each with its group and count |
| 4 Find | handle, question, select, then, only when the question has them, its operators and order: a byte 1, its operators (a count, then each: 0 a pattern, 1 a range, 2 In: variable, count, values, 3 Not: count, items, 4 Or: count of alternatives, each a count and its items, 5 Prefix: variable, text), Sort (a count, then each key's column and a byte 1 when descending), Limit (0: none), After (a byte 0, or 1, a count and the values); then, from version 6 and only when the program gives one, the question's time in milliseconds (1 to a week; the order is then sent, empty if need be) | Rows (in frames of about 1 MiB, all but the last with `more`; a Give without Sort past the server's cells sent as its rows are found, none held): the view's group, columns, count, values row by row |
| 5 Write | handle, serial, floor, by (zigzag), why, count, operations | Receipt: the group, count, (new thing's temporary id, its id)... |
| 6 Ping | any bytes | Pong: the same bytes |
| 7 Admin | "status" | Status: count, (key, value)... |
| 8 Follow | handle (over the Unix socket only) | Start: the database's id, the visibility number, count, (lo, hi) of each run, newest first; the descriptors of `visible` and of each run ride on its first byte. The connection is then the database's follow stream ([local reads](#local-reads-g15)) |
| 11 Watch | handle, question, select, from (the group of the answer the program holds; 0: none), then its operators, Sort and Limit as Find codes them, when it has some (no After; Sort and Limit from version 5), and the time of its first answer as Find's (version 6) | pushes on the Watch's id until Unwatch or an error ([live questions](#live-questions-watch)) |
| 12 Unwatch | the Watch's id | Unwatched |
| 14 Put (version 3) | handle, serial, floor, by (zigzag), why, the file kind, name, media type, owner (0: the database's own key), cold (a byte), then the file's first bytes; the flag `more` when Pieces follow | Receipt of the group of its facts (kind/Name, Size, Type, Owner, Content), once its bytes and that group are durable ([the vault](vault.md)) |
| 15 Piece | more bytes of the Put of this id; `more` but on the last | (the Put's reply) |
| 16 Load | handle, thing, the kind's Content property, from, length (zigzag; -1: to the end) | the bytes, in frames of 1 MiB, all but the last with `more` |
| 17 Erase | handle, owner (a thing, > 0; a token that writes the whole database) | Erased |

On a follow stream the server pushes (request id 0):

| kind | body |
|---|---|
| 9 frame | number (0: part of the catch-up, not visible on its own), first group, count, then the groups as the journal codes them; a long one continues in frames of the flag `more` that carry bytes only |
| 10 runs | number (the reader drops its states under smaller numbers), count, (lo, hi) of each run, newest first; their descriptors ride on its first byte |
| 13 durable | number: the frames sent under this number and below are durable (the reader's live questions give their changes); a reader that does not know the kind skips it |

- A **question** is data: variables, patterns (thing, property, value, each a variable, a thing or a value) and ranges,
  as `Cepheus.query` ([API](api.md)); no code crosses the wire, and every property is checked against the database's
  schema.
- **select**: `Give [x...]` gives those variables of each answer, in this order (none: all); `Group ([k...], [a...])`
  gives one row a distinct key: the key's variables, then the aggregates `Count`, `Sum x` (int, money), `Min x`, `Max x`
  (int, money, date), computed in the server without building the answers (Q4 below: 100 rows instead of 45,064).
- **Versions.** Version 6 adds a question's time (a Find's, a Watch's first answer's) and nothing else: a program of
  version 6 connects to a server of 5 in 5, and a question with a `timeout` is refused in the program (`invalid`:
  "this server speaks protocol 5: a question's timeout needs a server of protocol 6") before it is sent, since an
  older server refuses the bytes after the question; the server's own `question_timeout` bounds every question
  whatever the program's version. Version 5 adds a Watch's Sort and Limit ([live questions](#live-questions-watch)) and nothing else: a
  program of version 5 connects to a server of 4 in 4, and a watch with Sort or Limit is refused in the program
  (`invalid`: "this server speaks protocol 4: a watch with Sort and Limit needs a server of protocol 5") before it is
  sent, since an older server refuses a Watch's order. Version 4 adds the operation `Incr` (below) and nothing else: a program of version 4 connects to a
  server of 3 in 3, and a group with an `Incr` is refused in the program (`invalid`: "this server speaks protocol 3 or
  older: Incr needs a server of protocol 4") before it is sent. Version 3 adds the files (Put, Piece, Load, Erase) and
  nothing else: a program of version 3 connects to a server of 2 in 2 (as below), and a file is refused in the program
  (`invalid`: "this server speaks protocol 2 or older: files need a server of protocol 3"). Version 2 adds the
  question's operators and order (below) and nothing else; a server speaks 1 to 6, and answers each connection alike. A library says 2 in Hello; a server of version 1 only refuses it (`version`)
  and closes, and the library connects again in 1: its questions of patterns and ranges are answered as before, and
  one with `Not`, `Or`, `In`, `Prefix`, Sort, Limit or After is refused in the program (`invalid`: "this server speaks
  protocol 1: ... need a server of protocol 2") rather than sent. A program of version 1 is served by a server of 2
  exactly as before.
- **order**: Sort, Limit and After over the select's columns ([pages](cesia.md#sort-limit-and-after-pages)). It
  follows the select only when the question has it, so that every other question is coded as before; a server that
  does not know it refuses such a Find ("bytes after the request") rather than answer it unsorted.
- An **operation**: 0 Add, 1 Retract, 2 Expect a value, 3 Expect none; then the thing (zigzag: a negative id is a new
  thing of the group), the property, the value. 4 Incr (version 4): the thing, the property, `by` (zigzag), then a
  byte 0, or 1 followed by `into`'s thing (zigzag) and property. A token adds an `Incr` when it may add to the
  counter's kind and to `into`'s ([rights](#rights-g16)).
- Every read names the group of the view it was answered from, every receipt its group: a program can check what it
  read against what it wrote.

### Order, pipelining and back-pressure

- **Pipelining**: a client may send requests without waiting for replies, up to the limit Welcome states (1,024
  writes in flight a connection). The reads of one batch are answered in one system call.
- **Replies may come out of order**, matched by id: a long Find does not hold the short Gets sent after it (writes are
  answered when durable, reads at once). PostgreSQL and Redis answer in order on a connection.
- **What stays ordered**: a connection's writes to one database reach its writer in the order sent ("monotonic writes",
  Terry et al. 1994); a request sent after a write's receipt arrived sees that write ("read your writes"), since a
  receipt is sent once its group is published (G5).
- **Back-pressure**: at the limit of writes in flight, the server stops reading that socket; the kernel's buffers
  fill and the client's writes wait. Nothing is dropped and no error has to be handled. A Find's rows are sent frame
  by frame: the next frame is coded once the socket took the previous one (its answer's index words are gathered
  first, 8 bytes a value, so a very large answer costs its words in the server's memory until it is sent).

### Beside the protocols of the giants (by their documentation)

| | framing | many requests in flight | replies | pushes | errors | flow control |
|---|---|---|---|---|---|---|
| PostgreSQL (protocol 3.0; 3.2 since 18) | "The first byte of a message identifies the message type, and the next four bytes specify the length of the rest of the message" | pipelining with the extended protocol (Parse, Bind, Execute, Sync) | in order | `LISTEN`/`NOTIFY` | `ErrorResponse`; in a pipeline "the backend will skip command messages until it finds Sync" | TCP |
| Redis RESP2/RESP3 | "The first byte in an RESP-serialized payload always identifies its type"; CRLF-terminated parts, length-prefixed bulk strings | pipelining | in order | RESP3 push type | error type `-` | TCP; slow clients closed |
| etcd | gRPC ("All etcd APIs are defined in gRPC services") | many calls | each call its own | Watch streams | gRPC status | gRPC's; requests at most 1.5 MiB by default |
| FoundationDB | the client library is the protocol: programs call its C library (futures) | futures | per future | watches (10,000 a connection by default) | error codes | the library's |
| Cepheus | length, id, kind, flags; the journal's coding of values | up to the limit Welcome states | **by id, out of order** | `Watch`: a question's answer, then its exact changes, on the Watch's id | `{code, message}` values | TCP, and the server stops reading at the limit; a watch whose connection holds 8 MiB unsent ends `lagging` |

### Live questions (Watch)

A `Watch` keeps a question answered. Its pushes come on the Watch's id, kind 11, each a message:

```
answer = 0 | group | cols | count | rows                          the whole answer at group
change = 1 | group | cols | added: count | rows | removed: count | rows
same   = 2 | group                                                 nothing the question reads changed since from
```

- The first push is the answer at the newest durable group, or `same` when `from` is given, the server's ring of recent
  changes (its last million facts' changes) covers every group after it, and none of them touches the question's
  patterns (a property and its constants). Then a `change` for each durable group that changes the rows, in group
  order. A long answer or change continues in frames of about 1 MiB with the flag `more`, each of the same form, its
  rows added to the message's.
- **Durable first.** A change is computed while its frame is forced (the syncer hands the frame to the database's hub
  as it takes it) and pushed once the frame is durable: nothing a crash could undo is ever shown.
- **An error ends the watch**: `lagging` (the connection holds more than 8 MiB of pushes it has not taken, or the hub
  fell 65,536 frames behind, or a large group of its own frame changed the database: the program watches again from
  the group of its last message); `denied` (the token may no longer read the database: G16 is checked at each message,
  the table of tokens read again only when it changed); `stopping` (the server or the database stops); `internal`
  (the server failed on the watch's question at a frame, which ends that question's watches only, or on the
  database's watches as a whole, which ends them all: watch again; the log says why).
- **Nobody waits for a watch.** The writer and the syncer give each frame to a queue and go on; a hub thread per
  watched database evaluates it, all the hub threads in a domain of their own (made at the first `Watch`: nothing runs
  for a database nobody watches); a push goes to its connection's buffer, which a thread of the connection sends, so
  a program that never reads holds only its own connection (tested: `test/server_limits.ml`; measured below).
- **The follow stream** carries `durable` (kind 13) after each frame is durable: a local reader computes its own
  program's live questions from the frames it applies, during the server's fsync, and gives them at `durable`. A
  reader of an earlier version skips the kind.
- **Sort and Limit** (version 5): the watch's rows are Find's with the same Sort and Limit at each message's group,
  and each message's rows come in the order (the answer's, a change's added and its removed rows). The hub keeps the
  window of each such watch, k rows and its last one: a frame's rows are compared with the last, and a row that leaves
  the window is replaced by one Find After the last row, Limit the rows missing, on the hub's thread with the watch's
  own question (the rights its first answer was checked for) and the server's question budget (past it, that watch
  ends `too_large`). A Limit over 100,000, an After, a Limit without Sort, and aggregates with Sort or Limit are
  refused (`invalid`): [Sort and Limit in a watch](cesia.md#sort-and-limit-in-a-watch), the rule model-checked in
  `spec/WatchWindow.tla`.
- **Bounds.** A connection keeps 1,024 watches at most, the server 65,536, and what their windows and groups keep
  between messages counts as cells, a connection's at most one answer's; a watch's first answer is built within the
  answer's bounds, under the hub's lock. Past any, the Watch is `too_large`; a watch the server ended no longer counts
  ([limits](limits.md#the-server)).
- What a change is, and how it is computed: [Cepheus from Cesia](cesia.md#watch-live-questions); the resume rule is
  model-checked in `spec/Watch.tla` (no gap, no repeat, the rows never older than the last message: 1,015,657 states;
  without the touch test or the ring's bound, TLC finds a counterexample).

### What a watch costs

Measured on the machine of the other benchmarks (4 cores, 8 threads, SATA SSD, Linux), release builds, the database of
1 M facts (`bench.exe load`), each side of a comparison on a server started from the same copy of it, every run under
the lock that keeps the machine's other benchmarks out; medians with their distribution-free 95 % interval.
`sbench.exe`'s commands `wlat`, `stall`, `write ... W` and `livecpu`.

| | measured | beside |
|---|---|---|
| a change after its write's receipt, at the server, over its Unix socket ($n = 7$, 200 writes each) | p50 16.0 µs [11.0, 26.9], p99 68 | PostgreSQL `NOTIFY` with a Go server, from the commit to the screen, its WebSocket included: 137 µs [128, 148] (measured on the same machine on 2026-11-11 with PostgreSQL 18.6 and Go 1.26.3, a harness outside this repository) |
| the same, in the program's follower on the server's machine | p50 −6.9 µs [−14.8, −1.0]: before the receipt; p99 19.8 | |
| the write itself (its fsync) | p50 3,409 µs [2,970, 5,879] | PostgreSQL's insert with its fsync: 3,317 µs [3,122, 3,438] (the same harness) |
| 100 watches, each on a connection read by a thread, one writer of 20-invoice groups for 10 s, without / with a connection that watches and never reads ($n = 7$) | delivered 100 % / 100 %; after the receipt p50 1,314 µs [1,259, 1,348] / 1,341 [1,186, 1,582], p99 4,880 [3,862, 7,126] / 5,747 [4,852, 96,319]; the server's peak memory 111 / 107 MB | the same harness, a stalled screen among 100: Node `ws` and Go `gorilla` 100 % (p99 113 ms and 4.3 ms); a hub of one fiber that waits on each socket, 50.6 % |
| the hub alone (`livecpu`, in one process, $n = 5$): S screens, each watching the unpaid invoices of its client, and a dashboard (the unpaid sum and count), then 20,000 random groups (new invoices, payments, changed totals) | a group, the dashboard included, at 100 / 1,000 / 10,000 screens: p50 16.0 µs [16.0, 21.0] / 13.1 [12.2, 19.1] / 12.2 [12.2, 12.9], mean 17.2 / 14.6 / 14.5; every screen and the dashboard equal to `Find`'s at the end | asking again instead: the dashboard's sum 10.0 ms [9.7, 11.6] a group at 10,000 screens; the screen a group touches 8.1 µs |
| 16 writers for 5 s without / with 100 watches of what they write, the watches read by another process ($n = 7$) | 1,844 groups a second [568, 2,058] / 1,598 [977, 1,981]; the ratio within each round 1.20 [0.29, 2.09] | PostgreSQL, 16 writers with a trigger's `NOTIFY`: 8.6 times fewer inserts [6.1, 22.2] (its committers queue on `NOTIFY`'s lock, `async.c`) |

- A change leaves about 16 µs after its write's receipt, which itself leaves about 5 µs after the group is durable
  (half the empty round trip): about 20 µs after durable at the server, a few µs in the follower, which computes it
  during the fsync. The design's bound was 50 µs after durable.
- A group's changes cost the hub about the same for 100 or 10,000 watches (one evaluation a question's template, its
  rows routed by the client's value), and 12 µs at 10,000 against 10 ms to ask the dashboard again: the design's bound
  was 20 µs a group at 10,000 screens. Asking again only the screen a group touches costs about as much as the
  difference (8.1 µs); the difference wins on aggregates, and it knows which screens changed without asking any.
- A connection that never reads costs the others nothing measurable, and its unsent messages stop at 8 MiB (its watch
  then ends `lagging`); its intervals' upper ends are the disk's noise (one round of each side had a slow fsync).
- What the 100 watches cost the 16 writers is not measurable here (the ratio's interval holds 1): the writer and the
  syncer hand each frame to a queue. PostgreSQL's `NOTIFY` serializes its committers.
- Where PostgreSQL + Go win: their fan-out to many screens uses every core (at 1,000 screens 2,822 µs from the commit to
  a screen, the median, its WebSocket included, against 3,756 µs to a fiber of one Cesia program before any WebSocket,
  [Cesia](cesia.md#what-it-costs)).

### Errors

Every reply is a value or an error `{code, message}`. The engine's codes: `conflict`, `invalid`, `unique`, `damaged`,
`io`, `busy`, `closed` ([errors](errors.md)). The server's:

| code | when | what to do |
|---|---|---|
| `auth` | Hello with an unknown token; a request before Hello; a token removed since | check the token; the connection closes |
| `denied` | the token lacks the right for this database or operation; a session of another token | a token with the right |
| `version` | Hello with a protocol version the server does not speak (it speaks 1 to 5) | a library connects again in the version before; else a server and a library of the same release |
| `too_large` | a frame over 16 MiB (the connection closes); a question past the server's work budget, or an answer it would hold past its cells (a Find with Sort or aggregates, a watch's first answer); a Watch past the watches of a connection or of the server ([limits](limits.md#questions)) | write in smaller groups; ask a narrower question, or pages; unwatch first |
| `unknown_database` | a name or handle the server does not hold | declare it in cluster.toml |
| `stopping` | the server is stopping | connect again: the library does |
| `too_many_connections` | a new connection over the Unix socket while the server holds `max_connections` (request id 0; over TCP the connection is closed without a word) | connect later, or raise the limit |
| `idle` | no whole request for `idle_timeout` seconds, or no Hello within 10 s of the connection (request id 0, then the server closes the connection) | send `Ping` meanwhile, or connect again: the OCaml client does |
| `timeout` | a question (a Find, a Watch's first answer) ran past its time: the server's `question_timeout`, or the shorter one its program gave it; a streamed Find's frames sent before end with it ([limits](limits.md#questions)) | ask a narrower question, or pages; give a longer `timeout` (an admin token past the server's) |
| `refused` | a write sent again after a later write of its session was applied, whose first error was lost when the server started again (its error, when the same server refused it, is given again instead) | it was not applied: decide again |
| `missing` | Load of a thing that has no file of the kind; a chunk the vault does not hold | |
| `erased` | Load, or Put, of an owner whose key was erased | |
| `invalid` | a malformed request (the connection closes), a question that does not check, a serial below its session's floor, a why that starts with the server's marker, `Follow` on a connection with writes in flight | fix the request |
| `denied` (Follow) | `Follow` over TCP: local reads are for programs on the server's machine, over its Unix socket | read through the server; the OCaml client does by itself |
| `busy` (Follow) | `Follow` when the run files could not be opened eight times in a row (merges removing them meanwhile) | follow again: the OCaml client does, within 100 ms |
| `internal` | the server failed on a request, or in another task of the connection (a write's reply, a push), with what it did not expect: a bug, or memory that ran out. On the request's id, or on id 0; then the connection closes, its writes in flight answered first ([below](#a-request-that-makes-the-server-fail)) | connect again (the OCaml client does); report the server's log line |
| `read_only` | `Write`, `Put` or `Erase` on a replica; the message names its primary and the primary's address | write to the primary |
| `denied` (Follow, replica) | `Follow` on a replica: its state is behind its primary's | read through the socket; the OCaml client does by itself |
| `invalid` (promote) | `promote` on a primary, while the primary still sends, or without its handover and without `--force` | stop the primary cleanly, then promote; `--force` once it cannot write any more |
| `busy` (promote) | a promotion under way, or a visibility page held by another server of this machine | promote again once it ends |
| `unreachable` (promote) | the connection broke before the answer: the promotion was made once or not at all | `cepheus status` says which |

## Writes applied once: sessions (G14)

A write whose reply is lost (the connection broke, the server died) leaves its program unsure: sent again, it could
be applied twice (two clients made by one signup). Sessions remove the doubt.

- Welcome gives the connection a **session** (a random 62-bit number); a library that connects again sends it in its
  Hello and resumes it.
- The library numbers its writes in the session: the **serial** 1, 2, 3...; with each write it sends its **floor**,
  the lowest serial still waiting for its reply.
- The server keeps, for each database and session, the receipts of the serials at or above the floor. A serial seen
  again gets its first receipt (its group, and its new things numbered as the first time); a serial still in flight
  waits for the first one's outcome, never runs twice. This is the method of Ongaro's thesis (section 6.3: "Each
  server's state machine maintains a session for each client ... latest serial number processed ... along with the
  associated response"), with the floor so that many writes of a session may be in flight.
- Each group the server writes carries its **origin**: the token's name, the session, the serial and the floor, in the
  group's `why` before the program's own text (`"\000cph1\000"`, three varints, the name; [formats](formats.md)). So
  the history says which program wrote each group, and the journal is the truth of the table.
- The table is saved to `DATA/NAME/sessions` every second while writes come and at stop (written beside, forced,
  renamed). At start: the checkpoint, then the journal after its group (`Journal.read_after`). A checkpoint that does
  not check (its CRC) is ignored: the journal is read from its beginning, slower, never wrong.
- A session forgets its receipts an hour after its last write; a session keeps at most 4,096 receipts (a library that
  never moves its floor loses the oldest).

**G14 Writes applied once.** *Promise.* A write sent with a session and a serial is applied at most once, whatever
the faults; a write sent again with its session and serial until it is answered is applied exactly once, and every
answer names the same group and the same new things. *Under* F1, F2 (the server's crashes and power losses), broken
connections, lost and delayed bytes. *Conditions*: the same session and serial are sent again within an hour of the
session's last write; the program sends a given serial with the same operations (a different body gets the first
one's receipt). *Not covered*: a write whose retries ran out (`unreachable`): applied once or not at all, the honest
answer every networked database gives for a commit whose reply was lost.

*Proof sketch.* (1) Within one server process, the table is consulted and the write marked in flight under one lock,
before it is sent to the writer: a second copy finds it in flight or done, so one copy runs. (2) Across a crash: the
receipt of every write at or before the checkpoint's group is in the checkpoint, because the checkpoint's group is
$\min(\text{the published group}, \text{the published group when each write in flight was sent})$, and a write sent when the published
group was $P$ takes a group after $P$; every write after the checkpoint's group is in the journal with its origin, read
at start. A durable group is therefore always found, and a write that was not durable was not applied (G1, G3), so
sending it again applies it once. (3) The new things' ids are recomputed from the group's first new id and the order
of first use in the operations, the rule the engine numbers them by.

*Tests.* `server_sim` (simulation: every receipt, first or resent, against the journal: each (session, serial) in at
most one group, the receipt names it and its new things; through crashes, power losses, damaged checkpoints and
broken connections); `server_crash` (a real server killed 20 times under four writing clients: no value twice, none
acknowledged missing); `server_unit` (the table: in flight, done, floors, the checkpoint and its CRC).

## Local reads (G15)

A program on the server's machine can read a database in its own memory, with no round trip: a **local read**. It
costs 0.22 µs where a read through the Unix socket costs 10.2 µs and one of PostgreSQL's 25.5 µs, and it sees
every write confirmed before it started, exactly as a read at the server does (G15). The program's code is the
same: the OCaml client follows a database it opens over the Unix socket by itself, and reads through the server
when it cannot (over TCP, or while its follower is being made again).

### What the program holds, and what it is sent

A **follower** is the copy of a database a local reader keeps: the server's **run files** (the sorted, immutable
files of the LSM-tree, [architecture](architecture.md)), read through the program's own page cache with every page
checked by its CRC as it arrives (G7), and a delta of the newest groups, which it applies itself as the server did
(`Resolve.replay`). The server sends it, over a second connection to the Unix socket (the **follow stream**, opened
by the request `Follow`):

```
Follow {db}            the reader's right is checked (G16); then, over this connection only:
Start  {id, n, runs}   the descriptors of the visibility page and of each run file, passed by the kernel (SCM_RIGHTS)
Frame  {0, groups}     the groups after the newest run, up to the state visible under n (a catch-up)
Frame  {n, none}       that state is visible under n
Frame  {n+1, groups}   each frame the writer makes, sent as the writer takes it, before its fsync
Runs   {n, runs}       new runs (a merge, or a large group's run): the reader rests its states on them
```

- **Descriptors, not paths.** A **file descriptor** is a process's handle on an open file; a Unix-domain socket can
  carry descriptors from one process to another ("SCM_RIGHTS: Send or receive a set of open file descriptors from
  another process", unix(7)): the receiver gets its own descriptor of the same open file. The program needs no
  permission on the data directory, and the server decides, after the token, which database it may read (G16). The
  server opens each run file afresh for each reader (so no other process moves its file offset) and closes its own
  copy once sent; the visibility page is one read-only descriptor the server keeps open and passes to every reader
  (it is mapped, never read at an offset). A run file never changes once named, and a descriptor keeps a file readable after a merge removes its
  name, so a reader holding an older state still reads the right bytes. OCaml's `Unix` has no `sendmsg`: the 130
  lines of `server/fdpass_stubs.c` do it, behind one OCaml module (`Fdpass`), tested with random messages and
  descriptors read in random pieces.
- **Rules** ([rules](rules.md)): derived facts come to the reader as they are on the disk, with their kind (the run's
  flag, the frame's kinds), and the reader applies them as recovery does; it never evaluates a rule, so its state
  under a number is the server's, derived facts included.
- **Frames travel during the fsync.** The reader decodes and applies a frame while the server's disk forces it
  (about 3 ms here), and keeps the state it gives aside, under the number it was sent with. It never shows that state
  before the number says so.

### What a local read sees: one number in shared memory

**Linearizable** reads (Herlihy and Wing 1990) are reads that each appear to happen at one instant between their call
and their return. For a database whose writes form one order of groups (G4), that is exactly three conditions on
every read, which `spec/LocalReads.tla` states and checks:

- **Fresh**: a read holds every group whose writer was answered before the read started (no stale read);
- **Ordered**: a read holds every group that another read returned before this one started (no **new-old
  inversion**: two readers where the later one sees an older state; Lamport's *atomic* register forbids it, his
  *regular* register allows it, On Interprocess Communication, 1986);
- **Durable**: a read returns the exact state after a durable group (G5), never one that a crash can take back.

The rule that gives all three is one number, the **visibility number**, in a page of shared memory: the first 8
bytes of `/dev/shm/cepheus-ID.visible`, a 4 KiB file of memory (tmpfs) that the server maps read-write and every
reader maps read-only (`mmap` with `MAP_SHARED`: one physical page, the server's store seen at once by every process;
the reader cannot write it). In memory rather than on the disk: the number needs no fsync (after a reboot no reader
is left), it outlives a server's death (the rule below needs it), and a page of tmpfs is never written back to a
disk, so the server's store into it never waits for one.

A reader maps the page through a small C stub, with `PROT_READ` and `MAP_SHARED`, rather than with `Unix.map_file`,
which maps read-write (a shared mapping then needs a descriptor open for writing, which would let a reader move the
number); and of a private mapping mmap(2) says: "It is unspecified whether changes made to the file after the mmap()
call are visible in the mapped region". The rule, step by step:

- Each frame is sent tagged with the number it will be visible under: the current one plus 1.
- Once the frame's fsync returns and it is published, the server stores the new number, then answers the frame's
  writers, then lets remote reads see it.
- A read loads the number and serves the state the reader holds under it; if it does not hold it yet (the frame is
  still on its way, or being applied), it waits for it, and never serves an older one.
- A server that starts adds 2 to the number before anything else: a reader of the dead server may hold a state under
  the number the dead server's last frame would have taken, a frame the death may have lost, and the next frame of
  the new server takes another number.

So a group becomes visible to every reader, local or remote, at one instant: the store of the number. A read that
starts later loads it; a read that loaded an older number started before. The state under a number is the same for
every reader (the same groups in the same order), and it is durable before the number is stored (G5, G13).

**G15 Local reads are linearizable.** *Promise.* Every read, in a local reader or at the server, holds every group
answered to any program before it started, and every group any read returned before it started, and is the exact
state after a durable group; with the groups' order (G4), groups and reads together are strictly serializable.
*Under* F1 (the server's or a reader's death: a reader's state survives the server's death, and is served only under
its own number), slow, paused or stopped readers (a reader holds back its own reads only), broken streams.
*Conditions*: one machine: the server and its readers share the visibility page, which is never removed or
replaced while they run (a reader reads the file it was passed: a new file would leave it reading a number nobody
moves); a reader that falls more than 64 MiB of frames behind is cut off, and follows again. *Not covered*: a view a
program keeps on purpose reads that view's state, as everywhere (a view never changes, G5). After a
power loss every reader dies with the machine.

*Proof sketch.* Let $w(n)$ be the instant the server stores number $n$, and $S(n)$ the state it covers. (1) Durable: the
server stores $n$ only after the fsync of $S(n)$'s frame returned; a reader serves $S(n)$ only when it loads $n$; within one
server process numbers follow frames one to one, and a new process starts at the last number + 2, so a number a
reader holds from an earlier process, at most the last number + 1, is never stored again. (2) Fresh: a writer of
group $g$ in $S(n)$ is answered after $w(n)$; a read that starts after the answer loads a number $m \ge n$, and $S(m)$ holds
$S(n)$. (3) Ordered: a read that returned $S(n)$ loaded $n$ after $w(n)$; a read that starts after it loads $m \ge n$.
Remote reads take the server's view of the current number, which it sets after $w(n)$: the same argument.

*Tests.* `spec/LocalReads.tla`, model-checked by TLC (`tools/tlc.sh`): the rule built holds Fresh, Ordered and
Durable with two readers, remote reads and three writes (3,436,820 distinct states), and with one reader, remote reads,
three writes and a server death whose frame in flight is kept or lost (210,716); each part of it removed breaks one,
and TLC prints the shortest trace: without the 2 at a start, a group the restart made durable is answered while a
reader serves the state before it under the unchanged number (Fresh, 8 states); the number stored before the fsync
shows a group that a death then takes back (Durable, 6 states); remote reads moved at the fsync, before the number,
give a new-old inversion (Ordered, 8 states). `server_sim` (the simulation: local readers that follow the real fan-out and follower code, paused,
slow, killed and started again, their streams cut when the server dies; every read, local or remote, checked for
the three conditions against the model's state at its group); `server_crash` (a real server killed 20 times while two
readers read in their own memory: every read holds every write answered and every state returned before it
started); `server_unit` (descriptors passed: 400 random messages; the shared page).

### The rules the design first had, and why they were left

The design of 2026-11-08 proposed a **lease** (a permission that expires by itself; Gray and Cheriton, SOSP 1989): the
server sends `Durable {n, until T}` after the fsync, `T` read on the machine's monotonic clock, a reader serves its
newest durable state while its clock reads less than `T`, and the server answers group n's writers once every reader
whose `T` is still ahead acked n. TLC finds that this rule keeps Fresh and Durable (289,765 distinct states with one
reader, two writes and four ticks of a lease of two) but breaks Ordered, in a trace of 7 states:
group $n$ is published at its fsync and a remote read returns it; a local reader whose lease runs has not yet applied
`Durable n`, and a read that starts after the remote one returns $n - 1$. Two local readers give the same inversion.
Such reads form a regular register, not an atomic one: linearizability needs one instant at which a group becomes
visible everywhere, and two processes that each learn of it by a message cannot switch at one instant without
another round in which reads wait: in Paxos quorum leases a lease holder reads locally only after it has assessed
"whether an update to any of the leased objects is ongoing (i.e., in the process of being committed), and if not"
(Moraru, Andersen, Kaminsky, SoCC 2014). On one machine shared memory gives that instant for free. The design's first draft (a reader renewing its own lease when it acks) breaks Fresh as well
(a trace of 12 states: the reader is slow; its lease lapses, so the server answers the writers of groups 1 and 2
without its ack; the reader then takes the old `Durable 1`, renews its own lease from that moment, and serves group 1
to a read that starts after group 2 was answered). Both are kept in the model, each with its configuration, to show they break.

What the number rule changes against the lease: no write waits for any reader (the lease made each write wait one
round trip to the slowest reader, and up to the lease's length for a reader that stopped); no clock is read on a
read; no message goes back from the reader; a server that starts waits for nothing (the lease made it wait one lease
length). A reader on another machine has no shared page: its local reads would need leases between servers
(quorum leases), which Cepheus does not have yet; in a Raft cluster the leader serves the reads, under a lease of its
own ([reads](#reads-and-what-a-program-sees)).

### What it costs

On the machine of [the benchmarks](benchmarks.md) (i7-4720HQ, 4 cores and 8 threads, 11 GB, a SATA SSD), 2026-11-08,
the release build of this version with 4 I/O domains, PostgreSQL 18.6 on a cluster of our own (`bench/pg/pg.sh`, port
5548), the same 1 M facts on both sides (`bench.exe load`, loaded again before these runs); each side alternated with
the others in every round, every round under the lock that keeps the machine's other heavy jobs away, every process
under a 3 GB cap; medians and their distribution-free 95 % interval (order statistics), n rounds as given. The same
answers everywhere: Q3 for city-7, 396 rows; Q4, 45,064 unpaid invoices summing to 2,248,567,111 cents, in a local
reader, through the socket and in PostgreSQL. A local read is `Client.get` (or `find`) in a program that follows the
database (`bench/sbench.ml`, `local` and `localq`); through the socket, the same request answered by the server.

| | local read | through the Unix socket | PostgreSQL 18.6, Unix socket |
|---|---:|---:|---:|
| point read (an invoice's 4 facts), $n = 11$ | **0.221 µs** [0.210, 0.293] | 10.17 µs [9.22, 13.83] | 25.48 µs [23.76, 29.19] |
| Q3, the unpaid invoices of a city (396 rows), $n = 11$ | **0.461 ms** [0.429, 0.522] | 0.500 ms [0.480, 0.580] | 0.708 ms [0.684, 0.803] |
| Q4, the unpaid sum and count by city (100 rows), $n = 11$ | **11.6 ms** [10.2, 16.6] | 12.7 ms [11.7, 15.9] | 22.2 ms [21.4, 23.3] |

- **A point read** in the program's memory is 115 times PostgreSQL's and 46 times a read through the socket: what is
  left is the engine's own read (the design measured 0.42 µs in the process on another day's build; the load of the
  number and the choice of the state add a few nanoseconds). The design's target was 0.5 µs. Measured again after the
  rules came in (run format 6, a flag in each value word), on the same database grown by the write measurements below
  to 1.56 M groups, $n = 11$: 0.245 µs [0.231, 0.251] in the program, 9.93 µs [9.49, 11.27] through the socket,
  PostgreSQL 24.49 µs [24.11, 28.89].
- **Questions** gain less: Q3 and Q4 do their work in the reader as they do in the server; the round trip they skip
  is small beside it (Q3 loses 39 µs, Q4 about 1 ms of coding and decoding 100 rows).

**What a write pays for its readers.** No write waits for a reader. The writer's whole extra work is the follow
stream's two hooks a frame: the frame queued for each reader before its write, the number stored and the view moved
after its fsync. Measured inside the server (the hooks' own clock, $n = 11$ rounds of 3 s of one client writing):

| | the hooks, a frame | a durable write, one client: median latency |
|---|---:|---:|
| no local reader | 1.42 µs [1.10, 1.78] | 3.06 ms [2.88, 3.18] |
| 8 local readers | 14.97 µs [13.09, 16.90] | 3.13 ms [2.94, 3.50] |

The design's target was 20 µs for 8 readers; the hooks cost 0.5 % of an fsync of this disk, and the two latencies are
equal within the disk's noise. The cost grows with the readers (1.4 µs with none): each frame is queued for each
reader and wakes the thread that sends it.

**What following costs a reader.** One local reader while 256 clients write invoices of 4 facts through the socket
($n = 7$ rounds, its CPU time over 4 s): **32.3 % of a core** [23.3, 38.8] at 17,942 groups a second [12,269,
22,027], about 4.5 µs a change applied. The design's target, 20 % of a core at 18,000 groups a second, is **missed**:
the design measured 1.72 µs a change to replay a journal alone on a quiet machine; here the reader shares the
machine's 4 cores and 8 hardware threads with the server and the 256 writers, and each merge of the server makes it
apply again, onto the new runs, the groups written during the merge. Under that load its memory (Pss) was 273 MB
[202, 325]: its delta of the groups since the newest run, larger while the writes outrun the merges.

**What eight readers cost the machine.** Eight local readers of the 1 M facts, each having read every invoice of the
sample once ($n = 7$): **250 MB of Pss** in all [249, 250], 31 MB each, most of it its own copy of the run pages (the
database's runs are 24 MB). PostgreSQL's backends serving 8 clients of point reads: 43 MB [43, 44] of Pss in all (12
processes), because they share one buffer pool. Each reader keeping its own cache was the design's first choice (the
engine's code as it is, every page checked); one copy shared by all readers is not built. With run format 7 (2026-11-09)
the same eight readers take **106.5 MB of Pss** [105.6, 107.1] against 252.4 [251.5, 253.0] on main 0ecc09e, alternated
in 7 rounds: each reader's copy of the run pages shrank with the runs
([benchmarks](benchmarks.md#compressed-runs-and-journal-2026-11-09-at-10-million-facts)).

**Against the server before local reads** (the same server without them, its binaries and ours in turn in every
round, $n = 11$; the ratio new / old by round): empty round trip 1.05 [0.90, 1.18], point read through the socket
0.99 [0.79, 1.34], durable writes of one client 1.21 [0.90, 2.26] times the old rate, of 64 clients 0.97 [0.66,
1.52]: no difference the measures can see (every interval holds 1).

### Beside the giants (by their documentation)

| | what a plain read sees | its cost |
|---|---|---|
| PostgreSQL primary, Read Committed | "a snapshot of the database as of the instant the query begins to run": each statement sees every commit before it | a round trip (25.5 µs over the Unix socket here) |
| PostgreSQL hot standby | "data on the standby is eventually consistent with the primary"; with `synchronous_commit = remote_apply` the commit waits until the standby "applied it, so that it has become visible to queries on the standby(s)" | a round trip to the standby; each commit waits for its standbys |
| etcd | linearizable by default ("linearized requests must go through the Raft consensus process"); serializable reads "may access stale data" | a quorum round, or staleness |
| FoundationDB | "Each transaction will get a read version": a version no less than any committed | a round trip at each transaction's start |
| Datomic peer | "application processes have their own copy of the query engine and database in local memory"; `sync` gives "a database value guaranteed to include all transactions that were complete at the time sync was called" | local reads; linearizable only after `sync` (a round trip to the transactor) |
| Cepheus local reader | linearizable, always (G15) | 0.22 µs, no round trip; no write waits for it |

PostgreSQL's standby with `remote_apply` makes the primary's commit wait for the standby; Cepheus's readers make no
write wait. Datomic's peers read in their own memory but see the newest writes only after `sync`; Cepheus's readers
always do. What Cepheus does not have here: local readers on other machines (a replica serves its reads through its
socket, a Raft cluster's leader serves every read; quorum leases are not built), and PostgreSQL's SQL.

## A replica

A **replica** is a second server, on another machine, that keeps a copy of every database of a **primary** (the
server that takes the writes), group for group, in its own journal, forced by its own fsyncs. It gives a second copy
that survives the loss of the primary's machine, a place to take backups from without touching the primary, and, by
hand, a new primary when the old one is gone (`cepheus promote`). It is **asynchronous**: the primary confirms a write
once its own fsync returns and never waits for a replica, so a replica is behind by its lag (measured
[below](#what-a-replica-costs)), and a write confirmed during that lag is on the primary alone. A Raft cluster
([below](#a-cluster-of-three-raft)) waits for a majority before it confirms.

### Setting one up

Both servers share one `cluster.toml` but for `me`, with a `[[peer]]` each and `[tls]`: servers reach one another over
TCP with mutual TLS only (each shows a certificate of the cluster's CA), so two peers without `[tls]` are refused at
start.

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

`cepheus replicate PEER` writes `DATA/cepheus.role` (mode 0600, `replica_of = "srv1"`); it refuses a running server, a
peer the file does not declare, and the server itself. At its start the replica creates each database it does not
have yet with its primary's id (it asks the primary; the start fails, and says why, when the primary does not answer
then), and connects to the primary's peer port, once a database. A server whose cluster has one peer opens no peer
port: an old `cluster.toml` changes nothing. With several peers, every server listens on its own `[[peer]]` address.

### What travels, and why it is safe

The primary's **sender**, a thread a replica and a database, reads the database's journal as its files hold it,
frame after frame, byte for byte with each frame's CRC, from the group after the replica's newest, and only up to
the primary's newest **durable** group. It never sends a frame whose fsync has not returned: if that fsync failed, the
primary would stop, and its next start might not keep the frame ([G10](guarantees.md#g10-stop-on-a-disk-error),
[G13](guarantees.md#g13-a-failed-fsync-is-never-trusted)), leaving the replica with a group the primary does not have.
So **a replica's journal is always a prefix of its primary's durable groups**. The sender is woken after each durable
frame, by the condition the local readers' stream already signals: the writer and the syncer do nothing more for it.

The replica checks each frame's CRC-32C, decodes it (every count bounded by the bytes left), replays its groups as
recovery does (a large group merged at once into a run, as on the primary), and appends them to its own journal
through its own writer and syncer: frames that arrive while one is forced share the next fsync, and every database
of the replica shares its commit buffer. Then it tells the primary up to which group it holds them durably
(`Applied`). A replica far behind, or stopped for a day, reads from where it stands: catch-up and the live stream are
one path. The primary holds one frame a replica in memory, however far behind the replica is; the replica holds at
most 64 MiB of frames given to its writer and not yet durable (always one frame, up to the journal's 256 MiB).

The peer protocol runs on the peer port only, in the frames of [the protocol](#framing), kinds 20 to 26:

| message | from | holds |
|---|---|---|
| `PeerHello` | both | the version (1), the cluster's id, the server's name; another cluster id is refused |
| `Replicate` | replica | the database, its next group, its epochs ([below](#promotion-by-hand)); the reply: the database's id, the primary's newest group, its epochs, or an error (`diverged`, `newer`, `unknown_database`, `not_primary`) |
| `Epochs` | a starting primary | nothing; the reply: each database's newest group and epochs |
| `Frame` | primary | first group, count, CRC, length, then the bytes, in pieces of 1 MiB |
| `Beat` | primary | its newest durable group, each second without a frame |
| `Stopped` | primary | its clean stop: every group up to this one was sent ([below](#promotion-by-hand)) |
| `Applied` | replica | it holds every group up to this one durably |

The certificate a peer shows must be signed by the cluster's CA and name a `[[peer]]` other than the server itself;
a server connecting checks the other's certificate for its address and its name. Each side gives the other 5 s for
its handshake and Hello, then 30 s of silence before it closes the stream; the replica connects again after 0.1 s,
then twice as long each time, up to 5 s.

### What a replica serves

Reads (`Open`, `Get`, `Find`, `Watch`): the state after one of its groups, every group before it included, never a
group its primary did not make durable. A read on a replica is not linearizable: it may miss a write the primary
confirmed a moment ago (G15 holds on the primary's machine). `Write`, `Put` and `Erase` get `Err read_only`, whose
message names the primary and its address. `Follow` (local reads) gets `denied`: the OCaml and Cesia clients then
read through the socket. The files of [the vault](vault.md) are not copied yet: a `Load` on a replica finds no bytes.

`cepheus status` says `role: replica of srv1` and, for each database, `replica_of`, `replica.connected`,
`replica.primary_group` (the primary's newest group, from its beats), `replica.handover`, `replica.epoch` and, while
following fails, `replica.error`. On the primary, `role: primary`, each database's `epoch` and, for each replica that
follows it: `replica.srv2.group` (what it holds durably), `replica.srv2.lag_us_p50`, `_p99`, `_max` and
`lag_samples`: microseconds from the moment the sender saw a group durable to the replica's `Applied` for it.

### Promotion, by hand

```sh
cepheus stop --config /etc/cepheus/cluster.toml                            # on srv1: its clean stop hands over
CEPHEUS_TOKEN=cph_... cepheus promote --config /etc/cepheus/cluster.toml   # on srv2, an admin token
```

- **The handover.** A primary's clean stop (`SIGTERM`, `cepheus stop`) answers its writes in flight, closes its
  databases, sends each replica its last frames and `Stopped {group}`, and waits (at most 10 s) for it to say that it
  holds them; the replica then writes `DIR/handover` (0600). After a handover, **no group the primary confirmed is
  missing on the replica.**
- `cepheus promote` is refused while the primary still sends to the replica (it is alive: stop it first), and,
  without `--force`, unless every database was handed over. With `--force` (the primary is gone: its machine burned,
  it does not start), the groups it confirmed after the replica's newest are lost; the lag says how many
  milliseconds of writes that is.
- Then the followers stop, every frame given to the writer is durable, each database opens a new **epoch** from the
  group after its newest, `DATA/cepheus.role` says `promoted_from` (the promotion's commit point: a crash after it is
  made whole at the next start), each database's visibility page is opened (local readers are let in), and writes
  are taken. The session table followed the groups (G14): a program that sends again, with its session and serial, a
  write the old primary confirmed gets its first receipt from the new primary.
- Programs reach the new primary at its own address: a client that names both servers and moves to the next on
  `read_only` is not there yet.

**Epochs.** Each database keeps the history of its promotions in `DIR/epochs` (0600): a list of (epoch, its first
group); without the file, epoch 1 from group 1 (every database made before replicas). The idea is PostgreSQL's
timeline history. When a copy asks to follow a primary, it sends its history and its newest group: its history must
be a prefix of the primary's, and its newest group must lie within its last epoch on the primary. Otherwise it holds
groups the primary never had (written by an old primary after the promotion, or never sent to the replica that was
promoted): it is refused (`diverged`), never merged. A copy whose history is newer than the primary's is refused too
(`newer`). The old primary becomes a replica of the new one with `cepheus replicate srv2` and catches up from where it
stopped; once it diverged, copy it again from nothing (an empty data directory).

**Two primaries at once** (a split brain: two servers taking writes for one database). What this version prevents: a
promotion while the primary talks to its replica; an old primary that starts again (systemd, a reboot) while it reaches
a server of a newer epoch: at its start, beside its opens, a primary of several peers asks the others for their epochs
(at most 1 s) and refuses to start if one holds a newer one; and the merge of a diverged history. What it cannot
prevent: after a forced promotion, an old primary that is cut off from the new one but still reached by programs
confirms writes that exist on it alone (they are refused as diverged when it is made a replica). Fence it before
`--force`: stop it, cut it off, or power it off. In a Raft cluster ([below](#a-cluster-of-three-raft)) this cannot
happen: a leader confirms nothing without a majority.

### Backups from the replica

A replica's data directory holds the files of its primary's databases (their id, their runs, their segments), so
[the backup script](production.md#backups) copies it while the replica runs, and the primary does no work for it. The
script copies `epochs` too: a copy without it starts again at epoch 1, and a promoted history refuses it as a
replica.

### What a replica costs

On the machine of [the benchmarks](benchmarks.md) (i7-4720HQ, 4 cores and 8 threads, 11 GB, a SATA SSD), 2026-11-13,
the release build; every round under the lock that keeps the machine's other heavy jobs away, every server under a 2
GB cap; $n = 21$ rounds; medians over the rounds, and for a ratio the median of its round-by-round values with their
distribution-free 95 % interval (order statistics). The primary `srv1` and its replica `srv2` run on this one machine
and talk over loopback. The writes are `sbench.exe rate`: a steady rate of groups of one fact each for 4 s, over 16
connections at 1,000 groups/s and 200 at 10,000 (an open loop: a write that is late goes at once, so that a slow
server is not given time to breathe). The replica first catches up the groups it missed, then starts again, so that
its lag counts the measured groups only. **The lag** is the primary's own (`replica.srv2.lag_us_*` in `cepheus
status`): from the moment its sender sees a group durable to the replica's `Applied` for it, so it holds the frame's
way over TLS, its checks and replay on the replica, the replica's write and fsync, and the way back.

The replica's data in two places: **in memory** (`/dev/shm`: its fsync costs nothing and it does not share the
primary's disk, the nearest this one machine comes to a replica on a machine of its own, less that machine's fsync and
the network), and **on the primary's SSD** (two servers forcing one disk). The last two columns compare the primary's
write latency, round by round, with the same rate written to a server without a replica.

| | lag p50 | lag p99 | lag max | primary's write p50 / without | its write p99 / without |
|---|---:|---:|---:|---:|---:|
| 1,000 groups/s, replica in memory | **0.22 ms** | 1.37 ms | 3.52 ms | 1.13 [0.94, 1.40] | 1.47 [1.19, 2.15] |
| 10,000 groups/s, replica in memory | **0.67 ms** | 3.50 ms | 7.20 ms | 0.99 [0.94, 1.31] | 1.62 [1.06, 4.27] |
| 1,000 groups/s, replica on the primary's SSD | 9.21 ms | 34.3 ms | 469 ms | 2.21 [1.99, 2.54] | 1.52 [0.73, 2.51] |
| 10,000 groups/s, replica on the primary's SSD | 11.1 ms | 40.5 ms | 467 ms | 1.73 [1.62, 2.04] | 1.83 [1.11, 2.69] |

Without a replica the server wrote 998.5 and 9,965 groups/s, its write p50 5.82 and 8.77 ms, its p99 35.1 and 40.2
ms; with the replica in memory 998.7 and 9,963 groups/s; with the replica on its SSD 908 and 9,350 groups/s (behind
the rate asked).

- **The lag.** A replica that does not share its primary's disk is less than a millisecond behind at the median, at
  1,000 as at 10,000 groups/s, and a few milliseconds at its p99: that is how much a `--force` promotion can lose (the
  writes confirmed during the lag). On a machine of its own, its own fsync adds to it (from 3 ms on this SSD's kind:
  frames that arrive while one is forced share the next), and so does the network's round trip; not measured here.
- **The primary's writes** keep their median; their p99 grows by about half (1.47 and 1.62 times), as the sender, its
  TLS and the whole replica ran on the same 4 cores. How much of that is left when the replica has its own machine is
  not measured here.
- **Never on the primary's disk.** Two journals forced on one SSD make the primary's median write 1.7 to 2.2 times
  longer, put the replica half a second behind once in most runs (its max lag: over 0.4 s in 14 runs of 21 at 1,000
  groups/s), which the replica in memory never shows, and keep nothing that the loss of that disk would not take with
  both.
- **Catch-up.** A new replica in memory took its primary's 648,571 groups in 10 s, about 65,000 groups a second, its
  databases rebuilt by replay (one run, $n = 1$).

**A server without replicas** (a `cluster.toml` of one peer, as every one before replicas) pays nothing that can be
seen. Main's binary (923da1b) against this version's, alternated in each round and their order from round to round,
main's `sbench.exe` the client of both:

| | main | this version | this version / main |
|---|---:|---:|---:|
| start of the binary (`cepheus` with no argument, 100 spawns a round): median | 4.864 ms | 4.898 ms | 1.017 [0.976, 1.029] |
| the same, the minimum of each round | 4.300 ms | 4.399 ms | 1.020 [1.003, 1.053] |
| the server ready (its `ready in`: the opens of a data directory grown by these runs) | 262 ms | 243 ms | 1.002 [0.946, 1.089] |
| an empty round trip (`ping`) | 9.35 µs | 10.54 µs | 1.117 [0.969, 1.266] |
| durable writes, 1 writer, right after the start: p50 | 3.06 ms | 3.12 ms | 1.010 [0.964, 1.106] |
| the same, 3 s later: p50 | 3.09 ms | 3.13 ms | 0.984 [0.920, 1.189] |
| durable writes, 16 writers: groups/s | 1,828 | 1,467 | 1.014 [0.655, 1.225] |
| the same: p50 | 6.08 ms | 7.62 ms | 0.978 [0.689, 1.408] |

The binary grew from 15.09 to 15.46 MB (2.5 %, the replica's code): its fastest start is 2 % (0.1 ms) later, within
the noise at the median. The one writer was measured twice: first in rounds that alternated with the rate runs
above, where both sides stalled at times (a p50 over 6 ms: 8 runs of this version, 2 of main) and the ratio came out
at 1.128 [1.010, 2.990]; then on its own, 21 rounds more, the two rows above, where nothing separates them (stalls: 4
runs of this version, 3 of main). Nothing on a primary's write path changed beyond a few tests a write and a frame (is
the server a replica, does a batch hold a large group's run).

### How it is tested

- `replica_sim` (a deterministic simulation: one seed decides everything, and `--seed N` replays it): a primary and
  its replica on two simulated disks; writes in sessions, large groups, merges on both sides; the sender reading the
  primary's journal a frame at a time into a link of bounded bytes; the link cut anywhere (the replica connects again
  from its newest durable group) or left down while the primary writes across segments; frames damaged on the way (a
  bit flipped, cut short: the CRC refuses them) or well formed and wrong (other bytes or other groups under a good
  CRC: decoding refuses them, and nothing changes); power losses and process deaths of both machines inside any disk
  call; failed fsyncs on the primary. At every recovery of the replica and at the end, its journal is a prefix of the
  primary's durable groups, group for group. Then a promotion: after a handover no confirmed group is missing, and
  every confirmed write of a session gets its first receipt from the promoted replica's table; after a power loss
  and `--force`, the replica is still a prefix. The promoted replica writes in epoch 2, the old primary sometimes
  writes on (a split brain), then asks to follow: the epochs accept it only if its journal is truly a prefix of the
  new primary's, always when it holds nothing past the promotion, and then both journals end identical.
- `server_replica`: two real servers over mutual TLS on loopback: a copy from nothing while a program writes; the
  replica killed (kill -9) and catching up; refusals at the peer port (a certificate of another CA, one of the CA
  for a name no peer has, the server's own name, another cluster id, an unknown database); writes refused on a
  replica; promotions refused while the primary sends and without a handover; the clean stop's handover and `cepheus
  promote` (every confirmed group there, a write sent again answered with its first receipt, writes taken in epoch
  2); an old primary told at start of the newer epoch; the old primary following the new one; the same groups in
  both journals; the files' modes (0600, the data directory 0700); a change of the rules on the primary and a load
  on the path of large groups with the rule's consequences, both read on the replica.

### Security

- **Who may connect.** The peer port speaks mutual TLS only: a certificate of the cluster's CA that names another
  `[[peer]]` (never the server itself), then the cluster's id. A program's token opens nothing there, and a server's
  certificate opens nothing on the client port.
- **What a peer sends is checked before it is used.** Each frame's length is checked before anything is allocated
  for it (16 MiB a message, 256 MiB a journal frame), its CRC-32C before it is decoded, its decoding is bounded by
  its bytes, and its groups must follow the replica's newest without a gap. A frame that fails any of these is
  refused, the replica's state unchanged, and the stream starts again. A primary checks a replica's history before it
  sends anything.
- **Denial of service.** At most 256 peer connections at once; 5 s from the accept for a handshake and its Hello, a
  byte at a time or not (the clock checked after every read, inside the handshake and inside a TLS record), 30 s of
  silence on a stream; the replica holds at most 64 MiB of frames in flight, the primary one frame a replica.
- **Files.** `cepheus.role`, `epochs` and `handover` are written beside (a new name opened with `O_EXCL`, so a link
  planted there is never followed), forced, renamed and the directory forced, mode 0600; the data directory 0700.
- **What it does not stop.** A peer whose key is stolen can act as a replica (read every database) or, as a
  primary, send groups to a replica: keep the peers' keys as the CA's, readable by the server's user only.

## A cluster of three (Raft)

With three or more `[[peer]]`, the servers form a **Raft cluster** (Ongaro and Ousterhout, *In Search of an
Understandable Consensus Algorithm*, USENIX ATC 2014; Ongaro's thesis, Stanford 2014). One server, the **leader**,
takes every write; it confirms a write only once a **majority** of the servers (2 of 3, 3 of 5) hold it forced on
their disks; when the leader is lost (its machine, its network, its process), the others elect a new one by
themselves, and no write the old leader confirmed is lost. A cluster of 3 survives the loss of 1 server, 5 of 2.

### Setting one up

The same `cluster.toml` on every machine but `me`, three `[[peer]]` and `[tls]`; each `[[peer]]` may say where
programs reach it (`clients`; by default its own host at this file's `[clients]` port):

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

The three start from **empty data directories**: each database gets the same id on every server (from the cluster's
id and the database's name) and the same first group, and every later group comes through the cluster's log. A data
directory written by a single server is refused (`was not made by this Raft cluster`): growing a server into a
cluster is not built. With 1 `[[peer]]` a server is alone, with 2 it is a primary and its replica
([above](#a-replica)), with 3 or more a Raft cluster: one way to fail over a cluster of each size. In a Raft cluster,
`cepheus replicate` and `cepheus promote` are refused, and `DATA/cepheus.role` must not exist. An even number of
servers works, but adds a machine that can fail without adding a failure the cluster survives (a majority of 4 is 3).

### One log for the cluster

The cluster keeps one **log**: each entry is a frame of one database's journal, whole, marked with the database's id
(or the leader's no-op, below). Its index is the entry's place, its **term** the number of the leader's term that
made it (a term grows at each election, and has at most one leader). On the leader, each database resolves its writes
as a single server does (one frame for every write that arrived while the previous one was committed: group commit),
then **proposes** the frame: the leader appends it to its log and forces it, while it sends it to the followers, each
of which forces it too and says so. Once a majority holds it forced (the leader's own fsync and one follower's, in
parallel), the entry is **committed**: the leader writes the frame into the database's journal (without an fsync: the
log holds it forced), publishes it, and answers the program. Every server then applies each committed frame to its
own database, in the log's order. A database's journal thus holds **committed frames only**: nothing is ever taken
back from a journal, a run, or a view.

Every frame a database makes goes through the log: a write's (an `Incr` included, its counter read at its point on
the leader), a load's, and the group of a change of the rules computed in the background
([rules](rules.md#changes-of-the-rules-in-the-background)), proposed alone once nothing else is in flight. A change
that runs while its leader stops leading is answered `not_leader`, nothing of it written. An entry is one wire frame:
a group is at most 8 MiB in a cluster, and a load takes the ordinary path of the writer (not the path of large groups,
which writes a frame by pieces before it is durable); a group past 8 MiB is refused whole (`invalid`, "over the frame
limit of 8388608"): a load is split into groups; a change of the rules whose consequences pass it cannot be
(large entries in pieces are not built).

The log is `DATA/raft/` (0700): segments `log.<first index>` (0600), each a header and **rounds**, a round being the
entries of one fsync, checked by CRC-32C as a journal's frames are ([formats](formats.md#the-servers-files)); and
`DATA/raft/state` (0600), the server's term, its vote, and its repair mark, written beside, forced and renamed. Each
second, once every database's journal is forced, the log's whole segments that every journal holds and every server
holds are removed. A server that recovers writes the frames the log knows committed again into the journals, cuts each
journal after them, and applies the rest once it learns how far the cluster committed.

### Elections

A follower that hears nothing from a leader for its **election timeout** (500 ms, then a random time up to 500 ms
more, so that two servers rarely start at once) asks the others for their **pre-votes** for its next term (thesis
9.6): a server grants one only if it heard from no leader within the minimum timeout and the asker's log is at least as
up to date as its own; a pre-vote changes nothing at the voter. With a majority of them, the server raises its term,
votes for itself (forced before anything leaves) and asks for votes; a server votes at most once a term (its vote
forced before it answers), for a log at least as up to date as its own, and never within 500 ms of hearing from a
leader or of its own start (**stickiness**, thesis 4.2.3). A server that won a majority leads: its first entry is a
**no-op** of its term (Raft section 8), since a leader commits an entry of an earlier term only through one of its
own (section 5.4.2); it serves programs once its no-op is committed and every entry before it applied. A leader that
hears from no majority within an election timeout steps down (**CheckQuorum**, thesis 6.2).

Why these times: heartbeats go every 50 ms; a follower answers a heartbeat at once, whatever its disk does (its
acknowledgement of entries waits for their fsync, a heartbeat's does not), so the timeout covers the network and a
pause of the process, not a slow fsync. A failover takes the timeout (0.5 to 1 s), a pre-vote and a vote round (one
fsync for the vote), and the new leader's no-op (one fsync): measured [below](#what-a-cluster-costs). etcd waits
longer by default ("By default, etcd uses a 100ms heartbeat interval", "By default, etcd uses a 1000ms election
timeout", its tuning guide for v3.5), and asks that "Election timeouts must be at least 10 times the round-trip time":
on a LAN (0.1 to 0.5 ms) 500 ms is a thousand round trips.

### Reads, and what a program sees

Only the leader serves reads and writes. A read on the leader is **linearizable** (it sees every write confirmed
before it began) under the leader's **lease** (thesis 6.4.1): the followers that answered a heartbeat promised to vote
for no one for 500 ms from its receipt; the leader serves from the time that heartbeat was sent, for 450 ms, so that
clocks that run up to 10 % apart keep the lease inside the promises. A leader whose lease lapsed (a majority did not
answer lately) serves nothing until it is renewed.

A follower answers every read and write with `Err not_leader`, whose message names the leader and whose body carries the
leader's address for programs after the message (every client's decoder, back to protocol 1, skips bytes after an
error's message: no new protocol version; likewise, a Raft server's `Welcome` carries every member's address for
programs after its fields). The OCaml library follows it (`Client`, which the `cepheus` command, the tests and the
benchmarks use): it connects to the leader and sends the request again, a write with its session and serial, so that it
is applied once (G14). The Cesia client does not follow it yet: it gives the program `not_leader`, whose message names
the leader's address. While there is no leader (an election runs) or the new one is not ready, a server answers
`Err no_leader`, and the library tries again after a pause (10 ms, doubling up to 50 ms in a cluster, 1 s elsewhere), within
its retry budget (30 s); a program whose server is gone tries the next member the server named in its Welcome. A write
that was in flight when its leader stopped leading gets the same treatment: applied once or not at all, the new leader
answers its resend from its session table if it was committed.

What is not there yet: local reads (`Follow`) on a cluster's servers (`denied`: the library reads through the
socket); reads on followers under leases of their own (design 8.4); the vault's files (`Put` and `Erase` are refused);
watches move to the leader only when the program opens them again.

### A damaged log: the 2018 rule

Alagappan et al. (*Protocol-Aware Recovery for Consensus-Based Storage*, FAST 2018) showed that consensus systems
"can lose data or become unavailable" when a single sector of a server's log is damaged: a server that takes its
damaged log for a shorter one may vote for a candidate that lacks entries it had acknowledged, and a committed entry
is lost. Cepheus tells a torn tail (the round being written at a crash, never acknowledged: cut) from damage (a round
that does not check followed by one that does, or written whole: refused) as its journal does. On damage, a server
**never deletes** what it found: the damaged segment and those after it are set aside (renamed `*.damaged`), the rounds
before the damage are kept, and `DATA/raft/state` records the newest index any header that checks names (the newest
entry it may have acknowledged). It then **neither votes nor stands for election** until it holds every entry up to
that index from a leader whose commit index reaches it; meanwhile it stores and acknowledges what the leader sends, as
any follower. The rule is ours, informed by the paper (whose own recovery, CTRL, fetches the damaged entries from
the other servers); its proof is the TLA+ model below, where the same server voting as if its log were shorter loses a
committed entry. The cost is availability, never safety: if a majority is damaged at once, no leader is elected until
an operator repairs one. A damaged `DATA/raft/state` (its CRC does not match) refuses the start: the server cannot know
the votes it gave.

### The peer protocol, version 2

On the peer port, in the frames of [the protocol](#framing): `PeerHello` says version 2; a peer of version 1 is
refused with `version`. `Raft` (kind 27) turns a connection into a stream of Raft's messages, one way, from the
certificate's peer, each a frame of kind 28 (id 0): `Pre_vote` and `Vote` (a term, the asker's last index and term),
their replies (granted, a term), `Append` (the leader's term, a number, the index and term before the entries, the
entries' terms and bytes, the commit index, and the floor: the newest index every server holds), and its reply (ok and
the newest index held forced, or refused and where to try again). Each server keeps one connection to each other
server for what it sends; replies come back on the other's. A message older than an election timeout in a sender's
queue is dropped (Raft sends again what matters).

`cepheus status` says `raft.role` (leader, follower, pre-candidate, candidate), `raft.term`, `raft.leader`,
`raft.ready` (a leader whose no-op is committed and applied), `raft.commit`, `raft.applied`, `raft.log` (the indexes it holds), `raft.forced`, and on the leader, for each other
server, `raft.peer.srv2: match M, next N`; `raft.repair` while the 2018 rule holds a server back, `raft.failed` if its
disk failed (the server then stops, as on any failed disk).

### Security of a cluster

- **Who may speak Raft.** The peer port's mutual TLS ([a replica's](#security)): a certificate of the cluster's CA
  naming another `[[peer]]`, then the cluster's id; a peer of protocol 1 gets `version`. A Raft stream is taken only
  from a listed peer, and every message on it is that peer's (its sender is the certificate's name, never a field).
- **What a peer sends is checked before it is used.** A frame's length before it is read (16 MiB), each message's
  counts against the bytes left (a message that does not decode closes the stream), each committed frame's header
  CRC, body CRC and trailer before it is applied, and its database's id against this server's; a leader's entry
  that contradicts a committed one is refused, never taken.
- **Promises kept across crashes.** The term and the vote are forced (written beside, fsync, rename, the directory
  forced) before any message of that term leaves, and an entry is acknowledged only once forced: TLA+ shows a cluster
  without either losing a committed write or electing two leaders in a term. A damaged log follows the 2018 rule
  ([above](#a-damaged-log-the-2018-rule)).
- **Denial of service.** At most 256 peer connections, two Raft streams a peer (an older one is closed), 4,096 messages
  queued for a peer (then dropped: Raft sends again what matters), messages older than an election timeout dropped.
- **Files.** `DATA/raft/` 0700, its state and segments 0600.
- **What it does not stop.** A peer whose key is stolen can disturb elections (a high term) or, elected, write
  entries: keep the peers' keys as the CA's, readable by the server's user only.

### What a cluster costs

On the machine of [the benchmarks](benchmarks.md) (i7-4720HQ, 4 cores and 8 threads, 11 GB, a SATA SSD), 2026-11-14,
the release build; every round under the lock that keeps the machine's other heavy jobs away, every server under a 2
GB cap; $n = 21$ rounds, the sides alternated in a rotating order; medians over the rounds, and for a ratio the median
of its round-by-round values with its distribution-free 95 % interval. The three servers run on this one machine and
talk over loopback with mutual TLS, so this is an indication of the protocol's cost, not of three machines: one CPU,
one disk. **Where the data is matters**: with three servers, a commit waits for the second fastest of three fsyncs.

Durable writes of one fact a group (`sbench mwrite`, 2 s each), by 1 connection and by 16, at the server whose data
is on the SSD; against a primary and its asynchronous replica (the previous release's way, the primary on the SSD,
the replica in `/dev/shm`, its writes never waiting for the replica):

| | primary and replica | cluster A: followers in `/dev/shm` | cluster B: one follower on the SSD too |
|---|---:|---:|---:|
| 1 connection: a write, median | 3.41 ms | **0.29 ms** (0.085 [0.055, 0.097]) | 6.53 ms (1.81 [1.36, 2.06]) |
| 1 connection: a write, p99 | 19.8 ms | 6.2 ms | 25.6 ms |
| 16 connections: groups a second | 1,653 | **18,489** (11.2 [8.6, 12.0]) | 536 (0.28 [0.22, 0.48]) |
| 16 connections: a write, median | 8.5 ms | 0.80 ms | 23.7 ms |

What they say:
- **A** shows what Raft itself costs: two followers in memory make a majority by themselves, so a commit waits for no
  SSD at all: a round trip over loopback with TLS, a follower's fsync in memory, and the hand-offs between the
  threads: 0.29 ms. It is not a durable commit on three disks.
- **B** is the pessimistic case of one machine: a commit waits for the second fastest of three fsyncs, two of them on
  the same SSD at once, which slows both (the replica's primary has that SSD to itself). On three machines, each its
  own disk, a commit costs the leader's fsync and a follower's (a network round trip later), in parallel: about the
  primary's figure here plus the round trip.
- **Throughput.** A leader's database has one frame in flight (its next writes wait, in one frame, until it is
  committed): so a commit's latency bounds a database's frames a second. Several frames in flight are not built.

A server without peers is unchanged (this release against the previous one, alternated, $n = 21$): ready 1.03 [0.96,
1.07] of before (median 129 ms here, the machine loaded), an empty round trip 0.97 [0.87, 1.16], writes by 1
connection 1.03 [0.95, 1.48] at the median and by 16 0.94 [0.61, 1.76]: no difference. The binary's own start (`cepheus` with no
argument, 100 spawns a round): 5.28 ms against 5.13, **1.031 [1.020, 1.047]**: 0.15 ms more, for 0.59 MB more of
code (16.05 MB): the Raft core, its log and its server part.

**Failover** (21 times: three servers on the SSD, a program writing without pause through TCP and TLS, the leader
killed with `kill -9`): a new leader ready (its no-op committed, every entry before it applied) 893 ms after the kill
(median; 557 to 1,395 ms); the program's first write committed by it 910 ms after (595 to 1,385). The election
timeout's draw (500 to 1,000 ms after the last heartbeat) is most of it; then a pre-vote round, a vote (one fsync),
the no-op (one fsync). With the library's former pause (doubling up to 1 s), the program waited 1,290 ms at the
median for a leader ready at 772: in a cluster its pause now stops at 50 ms.

### How it is proved

- **TLA+** (`spec/Raft.tla`, checked by `tools/tlc.sh`): the cluster's algorithm with Pre-Vote left free (any server may
  stand for election: a superset of what pre-votes allow), stickiness, the no-op, durable votes, acknowledgements of
  forced entries only, restarts that lose what was not forced, the 2018 rule, and the lease. Messages are lost,
  delayed, reordered and duplicated. Invariants: at most one leader a term, logs that agree on an entry agree before
  it, every later leader holds every committed entry, no two entries committed at one index, a read under the lease
  sees every committed entry. Checked by parts, each exhaustively within its bounds (3 servers, terms up to 2, logs
  of 2 entries, 2 messages in flight; TLC 1.7.4): the elections and the log with a restart that loses what was not
  forced (14,136,156 distinct states, the whole graph to depth 71), the 2018 rule with a damaged server (5,786,757
  states, depth 58), and the lease with a restart (5,853,164 states, depth 49): no invariant broken. Each rule removed
  alone breaks one, TLC printing the steps: committing entries of older terms by counting (LeaderCompleteness, the
  paper's Figure 8, with terms up to 4: 1,083,149 states), a vote forgotten at a restart (ElectionSafety), an
  acknowledgement before the fsync (LeaderCompleteness), votes that ignore the logs (LeaderCompleteness), a damaged
  server that votes as if its log were shorter (LeaderCompleteness: the paper's failure), a promise that ends before
  the lease it supports, a server that votes right after it starts, votes granted despite a promise, and reads before
  the no-op is committed (each: ReadFresh, a stale read).
- **Simulation** (`raft_sim`, 3 and 5 servers, one seed deciding everything, `--seed N` replays it): the server's own
  Raft core and log, each server on a simulated disk with its own clock (up to 3 % apart); messages lost, duplicated and
  reordered; partitions (a server alone, a minority, a link cut one way); process deaths, power losses (unforced bytes
  lost or torn), deaths inside a disk call, a forced byte of the log flipped before a restart, slow fsyncs (up to
  300 ms), pauses (up to 400 ms). Checked: at most one leader a term; every entry applied anywhere is the committed
  log's; every write a client was told committed is in the final log at its index; reads linearizable (a read at index r
  returns the committed log's state at r, sees every write answered before it began, no write that began after it ended,
  and no read that ended before it began saw a later index); once the faults stop, one commit and one log everywhere.
  Seeds 1 to 300 of 3 servers and 1 to 100 of 5: no failure (50,103 and 16,616 checks; `tools/test.sh` runs 100 and 50).
  Counted apart: 16 runs end with a follower behind its leader's log start, and 5 with a damaged majority electing no
  leader (the catch-up and the repair by any peer are not built yet, above). On its way it found six bugs, each fixed
  before this release: a deposed leader telling a program "committed" for an index a new leader had filled; a commit
  hint written beside entries that a later truncation replaced, then taken for committed after a crash; damage at the
  log's last round taken for a torn tail and cut (the 2018 failure itself); a refusal amplified into a storm of probes
  by duplicated messages; a follower that cut its log past what others still needed; and a pre-vote that a server behind
  in terms could never win.
- **Real servers** (`server_raft`): three servers over mutual TLS on loopback; a program connected to a follower writes
  through the leader; the leader killed (kill -9) while a program writes, a new one elected, every write the program
  was told committed there, a write sent again in its session answered with its first receipt; the old leader back
  as a follower, caught up; refusals at the peer port; the files' modes; a load, a change of the rules beside groups
  that count with one counter, a load past 8 MiB refused whole, then the leader killed: the new one holds the load,
  the change's consequences and the counter, nothing of the refused load.

## Security

### Tokens

A **token** is a secret a program shows to prove who it is: 32 random bytes from the kernel (`/dev/urandom`), shown
once as `cph_` and 43 characters of base64url (RFC 4648, section 5). The server stores its **BLAKE2b-256 hash**
(BLAKE2b: a cryptographic hash function, RFC 7693; OCaml's `Digest.BLAKE256`), finds it by its hash and compares it
in constant time (every byte, no early exit). A stolen `tokens.toml` gives no token: a hash cannot be turned back.

One way to authenticate a program, wherever it runs: the token, over the Unix socket as over TCP (inside TLS). Not
client certificates (a CA operation and a key file for each deployment) and not the kernel's peer credentials (a
second way, and C for `SO_PEERCRED`).

### Rights (G16)

**G16 Rights.** *Promise.* A connection does exactly what its token permits: a request on a database whose right
the token lacks is refused with `denied`, and so is `status` without `admin`; no group is written by a token without
`write` on its database. A token removed or narrowed in `tokens.toml` holds at the next request of every connection,
within a second of the file's change; a local reader's follow stream, which makes no request, checks its token
before each frame it sends and every second, and ends when the token may no longer read: the reader's states go,
and its reads go to the server, which refuses them (within about two seconds of the file's change: the reload,
then a tick). *Conditions*: the token is secret; `tokens.toml` is writable by the server's user only. *Proof*: every
request passes one check of the connection's rights for its database, recomputed whenever the table of tokens
changes (one comparison of the table's identity a request); writes carry the token's name in their origin; the
descriptors of a database's files are passed only after the check of `Follow`; for a token per kind, each fact of a `Get`, each pattern of a `Find` or a
`Watch` (those inside `Not` and `Or` too: an absence or an alternative of a fact of a kind reads that kind) and each
fact of a `Write` is checked against one byte a property, made again when the schema changes. `In`, `Prefix`, Sort,
Limit and After then act on the rows of a question of kinds read only, so the rows, their order, their count and a
page after a cursor made by hand reveal nothing a question of those kinds could not, and a `Prefix` reads the order of
the texts of its own property only (its time depends on that property's texts, no other's). *Tests*: `server_unit` (every token against every request on every database, a removed token, rights
narrowed, a forged origin refused, a frame over the limit, every request of a token per kind, 600 random questions
with `Not`, `Or`, `In`, Sort, Limit and After (cursors made by hand) of a token per kind against a write token's
answers, `tokens.toml` written back byte for byte); `server_sim` (random requests of every token checked
against its rights, and every group of the journal against its token's); `server_crash` (a token removed from the file
while its program is connected and reads in its own memory).

A token with **rights per kind** (`{ read = ["client", "invoice"], add = ["invoice"] }`, or
`--database "shop=read:client,invoice;add:invoice"`) reads and adds only those kinds:

- `Get` gives only the facts of the kinds it reads, as if the thing had no others. A `Find` or a `Watch` with a pattern
  on a kind it does not read is refused with `denied` when it arrives. `Open` still lists every property's name: the
  schema is not data.
- `Write` adds, retracts or expects facts of the kinds it adds only, and declares properties of those kinds only; a
  group with one fact of another kind is refused whole with `denied`. An `Incr` adds to its counter's kind and to its
  `into`'s: it needs both (as an `Expect` does, it tells the token the counter's value). Rules are for `write` tokens only: a rule reads
  every kind.
- It never reads in its own memory: a local reader maps the whole database, so the server refuses its `Follow`, and
  its reads go to the server. The clients do it by themselves.
- With rules, it reads a property only when it reads the property's kind **and every kind the property's derived
  facts can come from** through the rules (`sources`, [rules](rules.md#a-property-as-a-variable-the-w3cs-form-of-owls-rules);
  a rule over a variable property can read any kind): otherwise a derived fact would tell it something of the facts
  it may not read. Such a property is, for it, a kind it does not read (`Get` leaves its facts out, a question on it
  is `denied`). A refusal by the rules names only the rule (`constraint NAME`, `rule NAME refused the group`): the
  constraint's instance or a derived fact's premises may be of kinds it does not read. *Tested by*
  `test/server_unit.ml` ("rules and kinds": 25 seeds of random rules across three kinds and random facts, five
  tokens reading some kinds, every `Get` and question after every group against the oracle's reckoning from the rules).

The check costs 21.95 ns [21.85, 22.07] a group of 4 facts (`sbench rights`: the median of 21 rounds of a million
groups, with its 95 % interval; a schema of 40 properties of 10 kinds), beside the tens of microseconds of a write
through the server; a token `read` or `write` pays one comparison more a request.

### A request that makes the server fail

A request may meet what the server did not expect: a bug (an index out of bounds, a value not found), or memory
that ran out. It never takes its connection's thread with it, nor the thread of another connection or of the
database's watches. Each place that serves a peer ends there: the request, a write's reply, a push, the connection's
own threads, a watched question at a frame.

- **The request** is answered `internal` on its id, with a fixed message: no exception, path or state of the server
  crosses the wire. A failure in another thread of the connection (its write's reply, its push) says `internal` on
  id 0, and the connection reads no request after it.
- **The connection closes**, and lets go of what it held: its writes in flight are answered first, its watches and its
  unfinished files are dropped, its threads end, its socket is closed. A program that makes the server fail in a loop
  costs each time its own connection, and exhausts neither descriptors nor threads (tested: 200 connections in a row).
- **A watched question** that fails at a frame ends its own watches with `internal`; the other questions go on. A
  failure of the hub outside one question ends every watch of the database with `internal`, and the hub starts again
  at that frame's state, so that a new watch starts right.
- **The log** gets one line on the standard error: what failed (the connection's number, its token's name, the
  request's id and kind) and the exception's text, cut to 300 bytes, every byte outside printable ASCII written
  `\ddd`, so that a client's bytes in an exception's text can neither make a line of their own nor speak to the
  terminal that shows the log. At most one such line a second: the next one counts those left out. The lines are in
  [errors](errors.md#lines-on-the-standard-error).
- **A frame is whole or not at all**: a reply whose coding fails leaves nothing of itself in the output, a push of
  several frames is given whole or not at all, and a reply of several frames that fails after some ends with
  `internal` on its id, which the client takes as its end.

Memory that ran out: OCaml raises `Out_of_memory` when one allocation cannot be had (on Linux, mostly a size past
what the machine could give, the request's own), and the heap is still sound, so the server goes on. A machine truly
out of memory has the process killed by the kernel instead; systemd starts it again, and recovery decides what is
durable. A stack that overflows raises `Stack_overflow` in OCaml 5, which unwinds that thread's stack: the server goes
on.

*Tested by* `test/server_unit.ml` (eight exceptions raised by a request, a client's bytes in an exception's text, a
reply cut between its frames, a write whose hand-off fails, a write's reply and a push that fail, a watched question
and a hub that fail, failures in a loop) and `test/server_guard.ml` (real sockets: a connection with a watch and a
write in flight, 200 failing connections, a failure in another thread over a Unix socket and over TCP; the process's
descriptors and threads counted before and after).

### Who may reach the socket

The Unix socket's directory is the gate on one machine: make it `0750`, owned by the server's user and a group of
the programs allowed to connect (`chgrp cepheus /run/cepheus`); the token is still needed. The server makes the socket
0660 once it is bound, whatever its umask: Linux lets a program connect only with the right to write the socket
(unix(7)), so its owner's group may connect and nobody else. Over TCP, TLS.

### The data directory

Its files hold the facts in the clear (the journal, the runs, the session tables): every file a database makes is
0600 and every folder 0700, whatever the process's umask. A data directory that lets its group or others in (made
by hand under the usual umask, 0755) is made the server's alone at its start, and the log says so; one it cannot
change (another owner) is refused. *Tested by* `test/server_limits.ml` (a data directory of mode 755: 0700 after the
start, every file of the database 0600 and every folder 0700, the socket 0660).

### No path in a reply

An error of the server's own files (the disk, the vault and its key) reaches the program as its code (`io`, `busy`)
and a fixed message, "the server could not use its files (its log says why)"; what it says (the paths, the
system's words) goes to the server's log only. *Tested by* `test/server_unit.ml` (a vault key readable by others:
`io` to the program, its path in the log only).

### Denial of service

What one peer may make the server hold or do, each bound refused or waited for before it is passed
([limits](limits.md#the-server)):

- **Before a token.** A frame before Hello is 4 KiB at most, so a peer that shows no token holds its connection's
  64 KiB buffer and nothing more, for 10 s at most from its accept (its TLS handshake and its Hello, a byte at a time
  or not); at `max_connections` a new connection takes the slot of the oldest such one, never a program's.
- **Slow peers.** After Hello, a whole request within `idle_timeout` of the previous one: the clock is checked after
  every read, inside a TLS record too.
- **Reading.** A longer frame grows its connection's buffer, back to 64 KiB once it is used; the grown buffers hold
  64 MiB more at most, server-wide, a connection past it waiting for room: 512 connections that each begin a frame of
  16 MiB do not make the server hold 8 GiB.
- **Replies.** A connection whose replies not yet sent pass 1 MiB has no more of its requests decoded until they are
  sent: 100 Gets of a 900 KB text sent in 1,400 bytes and never read hold a MiB and a reply, not 90 MB.
- **Frames.** No reply passes the frame limit, which every client refuses: a Get or an Open that would is sent in
  frames of the flag `more`; a name is 255 bytes at most and a text the frame less 4 KiB, so a token that may add to
  one kind cannot make the database unopenable; a group whose receipt would pass a frame is refused before it is
  applied.
- **Answers.** An answer the server holds (Sort, aggregates, a watch's first answer) is bounded by its cells, rows
  times columns, a question's and every connection's together; a Find without Sort past them holds none of its rows
  (asked again and sent as they are found), so a cross product of patterns that share no variable (the size of the product, the AGM bound: Atserias, Grohe, Marx 2008)
  costs the server its time, not its memory. A question takes 64 patterns at most, and its work is counted in lookups.
- **Watches.** 1,024 a connection, 65,536 the server, and what their windows and groups keep counts against a
  connection's cells.

*Tested by* `test/server_unit.ml` ("the bounds of an answer at the server": a cross product asked every way, the
pool held by others, 65 patterns, a pattern repeated, the watches of a connection and of the server; "replies
within the frame limit": an Open of 17 MB of names and a Get of 17 MB of facts joined from their frames, names and
texts past their bounds, a receipt past a frame) and
`test/server_limits.ml` (a real server: connections that show no token holding every slot while a program connects,
a TLS handshake and a TLS record after Hello sent a byte at a time) and `test/server_guard.ml` (real sockets: a frame
of 16 MiB before Hello, three frames of 700 KB begun at once under a
bound of 1 MiB, 3,000 Finds of 14 KB sent at once by a client that reads nothing yet).

### TLS

**TLS** (Transport Layer Security, version 1.3: RFC 8446) encrypts a TCP connection and proves to the client that the
server is the one it meant: during the **handshake** (the first round trips, where the two sides agree on keys) the
server shows a **certificate**, a public key and a name signed by a **certificate authority** (CA) the client trusts.

- **The cluster's CA.** `cepheus cluster init` makes a CA of the cluster's own (an ECDSA key on the P-256 curve, a
  self-signed certificate valid 10 years: `ca.pem`, `ca.key`) and the certificate of its first server (valid 825
  days, its name and hosts in its subjectAltName, the field TLS checks names against); `cepheus cluster cert` signs the
  next ones. Keys are written readable by their owner only, before any byte of the key is in the file. `ca.key` signs
  certificates and nothing else: keep it offline.
- **What a program checks.** It trusts the cluster's CA only (`ca`, a parameter it is given), and checks that the
  server's certificate names the host it connected to (an IP address in the certificate's IP entries, a name in its
  DNS entries, which it also sends as SNI); then, in Welcome, that the cluster id is the one it expects, when it was
  given one. The server's TLS refuses anything older than TLS 1.3, and resumes no session (no tickets: a program keeps
  its connection).
- **What the server checks.** The program's token, inside TLS (programs show no certificate: choice 2 of the design).
  Between servers (a replica and its primary, a Raft cluster), both sides show a certificate of the CA naming a
  listed peer: mutual TLS, as FoundationDB and etcd do ([a replica's](#security)).
- **Refused, and tested** (`server_tls`): a server whose certificate another CA signed; a certificate of the right CA
  that does not name the host the program used; a server of another cluster id; a TCP connection without a CA; a
  plain (non-TLS) client on the TLS port, which gets no Welcome; and the server goes on serving after each.

**Which library.** OpenSSL 3, the system's `libssl` (security fixes arrive with the system's updates, the same day as
for PostgreSQL, which uses it too), through about 370 lines of C of ours (`server/tls_stubs.c`) behind one OCaml
interface (`server/tls.ml`). OpenSSL works on memory buffers only (memory BIOs): the OCaml side reads and writes the
socket, so the thread blocked reading a request holds no lock while another thread sends a reply, and OpenSSL never
waits. The handshake's computation (key exchange and signatures: a new connection costs 2.6 ms, measured below) runs
without the runtime lock.
The other way, ocaml-tls (Kaloper-Meršinjak et al., USENIX Security 2015), writes the protocol in OCaml but its ciphers
are C too (mirage-crypto), needs fourteen opam packages, and is not an OSS-Fuzz project; OpenSSL is (design choice 3).

## Speed beside PostgreSQL

Server against server, on the machine of [benchmarks](benchmarks.md) (i7-4720HQ, 4 cores and 8 threads, 11 GB, a
consumer SATA SSD), 2026-11-08, Cepheus at a980df9 (release build) with 4 I/O domains, PostgreSQL 18.6 on a cluster of
our own (`bench/pg/pg.sh`, port 5547, `fsync` and `synchronous_commit` on, TLS 1.3 only for TCP). The same data on both
sides: `bench.exe load` of 1 M facts (11,363 clients, 227,260 invoices; PostgreSQL: the same rows by COPY, indexes,
`VACUUM ANALYZE`). Each side alternated with the other in every round, each round under a lock that keeps the
machine's other heavy jobs away, every process under a 3 GB cap; medians and their distribution-free 95 % interval
(order statistics, [benchmarks](benchmarks.md#method)), n rounds as given. Cepheus's client is `bench/sbench.ml`
(OCaml, every reply decoded); PostgreSQL's is `pgbench -M prepared` (prepared statements, the extended protocol). A
point read is an invoice by its id: `Get` of its 4 facts against `SELECT * FROM invoice WHERE id = :k`.

The five rows at $n = 101$ were measured again for the first version, 2026-11-19: Cepheus' server at 19cb5ac (release
build, 4 I/O domains), PostgreSQL 18.6 on a new cluster of its own (port 5548) with the same rows, 101 rounds each under
the lock alone, the two sides' order swapped every round (`sbench.exe` `ping`, `get` at depths 1 and 16 and `clients` 8,
against `pgbench -M prepared -T 1`); their ratio is PostgreSQL's time over Cepheus' in each round, its median and
interval the same way. The machine's load over the minute before a round (the job that held the lock just before) had a
median of 4.8; in the 19 rounds begun below 2, a point read took 8.87 µs and 8 clients 3.51 µs a read.

| | Cepheus | PostgreSQL 18.6 | ratio |
|---|---:|---:|---:|
| empty round trip, Unix socket (Ping; `SELECT 1`), $n = 101$ | 8.86 µs [8.79, 9.03] | 15.24 µs [15.00, 15.60] | 1.73× [1.69, 1.77] |
| point read, 1 client, Unix socket, $n = 101$ | **9.68 µs** [9.17, 10.09] | 24.91 µs [24.41, 25.26] | 2.62× [2.51, 2.75] |
| point read, 1 client, TCP + TLS 1.3, $n = 101$ | **41.33 µs** [40.49, 42.12] | 52.31 µs [51.53, 52.92] | 1.27× [1.22, 1.31] |
| point read, TCP without TLS (PostgreSQL), $n = 21$ | (no plain TCP: TLS always) | 35.81 µs [34.54, 37.71] | |
| point reads, 16 in flight on one connection (a pipeline of 16), per read, $n = 101$ | **1.30 µs** [1.29, 1.32] | 9.05 µs [9.00, 9.13] | 6.95× [6.88, 7.01] |
| point reads, 128 in flight, per read, $n = 11$ | 1.31 µs [1.29, 1.36] | | |
| 8 clients, one read in flight each: wall time per read, $n = 101$ | **3.71 µs** [3.64, 3.78] | 6.27 µs [6.25, 6.29] | 1.71× [1.68, 1.74] |
| 64 clients, $n = 11$ | 3.14 µs [2.99, 3.71] | 7.00 µs [6.78, 7.68] | 2.2× |
| 256 clients, $n = 11$ | 2.88 µs [2.73, 3.94] | 12.83 µs [11.96, 13.75] | 4.5× |
| Q3, the unpaid invoices of a city (city-7: 396 rows of 2 values), $n = 11$ | 0.487 ms [0.474, 0.526] | 0.662 ms [0.656, 0.699] | 1.4× |
| Q4, the unpaid sum and count by city (100 rows, aggregated in the server), $n = 11$ | 12.37 ms [11.35, 13.87] | 18.47 ms [18.36, 19.23] | 1.5× |
| a new connection with TLS and its first request, $n = 7$ | 2.60 ms [2.53, 2.76] | 4.28 ms [4.24, 4.56] | 1.6× |
| a new connection, Unix socket (PostgreSQL's fork of a backend), $n = 7$ | | 2.03 ms [2.01, 2.04] | |

What it says:

- **One client**: a point read costs the kernel's round trip (two system calls a side and two wake-ups: the 8.86 µs of
  Ping) and the server's work (decoding, the read of the view, coding), small beside it: the read took 0.65 µs more than
  Ping, paired by round [0.04, 1.03], and less in 38 rounds of 101 (the server sends Ping's 16 bytes back; 1.5 µs more
  on 2026-11-08). PostgreSQL's own floor, `SELECT 1`, is 15.2 µs: its work a statement is larger than our whole read.
  The design's target was 10 µs: 9.68 now (10.81 on 2026-11-08, when the empty round trip took 9.32; 8.46 when the design
  measured it). Only not making the round trip goes below it ([local reads](#local-reads-g15): 0.22 µs).
- **Many clients**: the design's main target, 8 clients at most 4 µs a read (PostgreSQL 6.2 µs when the design measured
  it, 6.27 now), holds: 3.71 µs (3.51 in the rounds begun below a load of 2; 3.22 on 2026-11-08, $n = 11$). With one I/O
  domain the server answered every 9.6 µs (the prototype): the I/O domains are what wins it (3 rounds at each
  $k = 1, 2, 4, 8$: 9.1-10.0, 5.3-5.5, 2.9-4.0 and 2.1-3.1 µs; 4, the default, keeps 16 in flight at 1.3-1.5 µs where 8
  domains gave 1.5-2.1). PostgreSQL's process a connection pays more as connections grow (12.8 µs at 256); our threads
  in 4 domains do not.
- **Pipelining** (several requests in flight on one connection, the replies matched by id): 1.30 µs a read with 16 in
  flight, 6.95 times PostgreSQL's pipeline of 16 (9.05 µs), where the backend still answers in order and parses each
  statement.
- **TLS** costs us 31.9 µs more than the Unix socket (41.3 against 9.7; paired by round [30.9, 32.8]); OpenSSL's own TLS
  round trip in C on this machine (64 bytes each way, the design's prototype) costs 27.06 µs against 16.04 in plain TCP:
  11.0 µs of TLS. Ours adds about 18 µs over plain TCP (23.2 µs, the server's first version, $n = 11$): the memory
  buffers through which OpenSSL works here (a copy into them and one out, and more OpenSSL calls a read) cost the rest.
  Both sides use OpenSSL's default TLS 1.3 cipher (AES-256-GCM); the C prototype, AES-128-GCM. The design's target was
  36 µs: missed by 5 µs; still 1.27 times PostgreSQL with TLS (52.3 µs). A new TLS connection costs 2.6 ms (one ECDSA
  signature by the server, the client's checks; no client certificate), 1.6 times less than PostgreSQL's.
- **Q3 and Q4** go through the socket as rows (Q3) and as aggregates computed in the server (Q4: 100 rows sent,
  not 45,064): 1.4 and 1.5 times faster than PostgreSQL's plans. Both sides give the same answers: 396 rows for
  city-7, and 45,064 unpaid invoices summing to 2,248,567,111 cents (a fresh load of the same seeded data,
  `bench.exe read`; PostgreSQL on its rows), and the same 100 invoices (`sbench.exe check` against `psql`).

**Durable writes** (a new invoice of 4 facts a write, each answered after its fsync; groups a second, $n = 7$, 3 s a
run; PostgreSQL: `INSERT` of a row, `synchronous_commit = on`):

| clients | Cepheus through the server | PostgreSQL 18.6 | Cepheus in the process (`bench.exe write`) |
|---:|---:|---:|---:|
| 1 | 166 [3, 297] | 240 [3, 302] | 155 [66, 310] |
| 16 | 1,234 [47, 2,438] | 1,616 [90, 2,482] | 1,737 [951, 2,269] |
| 64 | 7,110 [3,937, 9,549] | 6,059 [4,385, 9,488] | 3,555 [2,211, 9,113] |
| 256 | 17,850 [14,450, 24,870] | 17,417 [6,770, 22,737] | 13,103 [1,364, 21,513] |

Both sides wait for the disk: a write is one fsync's share (group commit), and this SSD's fsync took from 3 ms to
several hundred ms while other jobs used the disk between the rounds (the minimum of 3 writes a second is a stall of
the disk itself). The intervals overlap at every count: the server adds a round trip (10 µs) to a write that waits
for an fsync of milliseconds, and the two databases are equal here within the disk's noise. The quiet-machine
comparison of the engine's writes is in [benchmarks](benchmarks.md#writes-at-256-clients-with-their-merges).

Raw numbers and scripts: the job's measurement files (not in the repository) were made with `sbench.exe` and the
`pgbench` commands above; `sbench.exe` prints one number a run (`ping`, `get ADDR FACTS DEPTH N`, `clients`, `write`,
`q`, `hs`).

## What it does not do yet

- Find gathers its answer's index words before it sends them (above); forks are not on the wire yet.
- Local readers on other machines (a replica serves its reads through its socket; in a Raft cluster the leader serves
  every read, followers none: reads on followers under leases are not built), and one shared copy of the pages for many
  readers of one machine (each reader keeps its own cache: [what it costs](#what-it-costs)).
- A replica does not copy the files of the vault yet, a client does not move to the new primary by itself, and a
  promotion is made by hand ([a replica](#a-replica)).
- In a Raft cluster ([above](#a-cluster-of-three-raft)): adding or removing a server (one at a time, learners first),
  a server that joins with data or falls behind the leader's log start (a catch-up from the journals), local reads,
  the vault's files, a group over 8 MiB, a damaged server repaired by any peer (not only by a leader), leadership
  handed over at a clean stop, and the Cesia client following `not_leader`.

What is built: the Cesia client ([Cepheus from Cesia](cesia.md)), by which a Cesia program reaches a database through
a server only, by `cepheus.Connect`, and reads locally on the server's machine; live questions on the wire
([above](#live-questions-watch)); many databases sharing one fsync ([the commit
buffer](#many-databases-one-fsync-the-commit-buffer)); a replica that follows its primary ([above](#a-replica)); three
servers that elect a leader and confirm writes on a majority ([above](#a-cluster-of-three-raft)); `Incr`, a counter
raised in its group ([groups](concepts.md#groups-a-write-is-a-transaction)). Not built: what the list above names,
and databases held in memory only, with `Expire`. The OCaml library still opens a database directory in its own
process (`Cepheus.open_`): it is the engine the server runs, and what its tests and benchmarks drive; programs, in
Cesia, go through the server.
