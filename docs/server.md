# The server

Cepheus runs as a server, as PostgreSQL does: one process on a machine holds its databases, and programs connect to
it. This page is the whole of it: what the server is and why it is built this way, how to run it (`cluster.toml`,
tokens, the commands, start, stop, crash), the wire protocol byte by byte, security, the two guarantees the server
adds (G14 and G16), and its speed beside PostgreSQL 18.6, server against server, on one machine.

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
├── databases     each declared in cluster.toml: its writer and syncer (a domain of their own), its merges,
│                 its session table (G14)
├── tokens        tokens.toml, beside cluster.toml, read again when it changes
└── one cache     the page cache of every database's runs ([storage] cache)
```

Why a server rather than a library opened by each program:

- **One writer, without a lock between programs.** A database has one writer ([G9](guarantees.md#g9-one-writer)).
  In a server, every program's writes reach that writer through the socket, and their groups share its fsyncs (group
  commit across programs, [architecture](architecture.md#group-commit)).
- **Rights.** A program receives exactly the rights of its token, database by database (G16); it needs no permission
  on the data's files.
- **The path to several machines.** Replication and Raft (steps 6 and 7 of the plan) are server to server; a program
  keeps the same code.

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

```toml
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

### tokens.toml

The tokens of the programs, beside `cluster.toml`, readable by the server's user only (mode 0600). It holds hashes,
never tokens; the commands below write it.

```toml
[[token]]
name = "shop-web"
hash = "blake2b-256:9f4c...e1"
databases = { shop = "write", stock = "read" }
[[token]]
name = "ops"
hash = "blake2b-256:51aa...07"
admin = true
```

- `read`: Open, Get, Find on that database. `write`: read and Write. `admin = true`: the server's operations
  (`status`); no data right by itself.
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
cepheus token add NAME --database DB=read|write ... [--admin] --config FILE
                                         a new token, printed once on stdout (cph_ and 43 characters); its hash goes
                                         to tokens.toml
cepheus token list --config FILE         names and rights (never the tokens)
cepheus token remove NAME --config FILE  removed: its connections are refused at their next request
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
table, G14).

### Files of the server

```
DATA/cepheus.lock          held (lockf) while the server runs: one server a data directory; holds its pid
DATA/cepheus.server        the server's id, made at its first start
DATA/NAME/                 a database: its files as in operations.md, and
DATA/NAME/sessions         its session table, a checkpoint (G14): written every second while writes come, and at stop
SOCKET/.s.cepheus.PORT     the Unix socket, made at start, removed at stop
```

### Start, stop, crash

**Start.** Read and check `cluster.toml` and `tokens.toml`; take the data directory's lock (a second server on the
same data is refused: G9 lifted to the server); open every database, in parallel (a domain each, at most `domains` at
once), each with its recovery ([operations](operations.md#opening-and-recovery)) and its session table (its checkpoint,
then the journal after it); open the listeners (a socket file left by a server that died is removed; one a live
server answers on is refused); start the I/O domains; tell systemd it is ready (`READY=1` on `$NOTIFY_SOCKET`, one
datagram: `sd_notify(3)`). The server prints one line: the time of the opens, each database's group, the listeners.

**Stop** (`SIGTERM`, `SIGINT`, `cepheus stop`). No new connection; new requests get `Err stopping`; the writes in
flight become durable and are answered; each database is closed cleanly (its `closed` marker: the next open forces
nothing) and its session table saved; the socket file is removed; exit 0.

**Crash** (kill -9, power loss). Each database recovers as the engine does at its next start (G1 to G13); the session
tables are rebuilt from their checkpoints and the journal (G14). A program's library connects again and sends its
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
  server allocate it. A count inside a body (of facts, of rows, of operations) larger than the bytes that remain is
  refused before anything is allocated.
- **Values** are coded as in the journal ([formats](formats.md)): a tag byte (0 int, 1 float, 2 false, 3 true, 4 text,
  5 date, 6 money, 7 link), then a zigzag varint, 8 bytes of a float, or a length and the bytes of a text. A
  **varint** is an integer in 7-bit groups, low first, the high bit of each byte saying "more" (LEB128); **zigzag**
  maps 0, -1, 1, -2... to 0, 1, 2, 3... so small negatives stay short. One coding of values everywhere: journal, wire,
  and later replication.

### Requests and replies

| kind | request body | reply body |
|---|---|---|
| 1 Hello | version varint (1), token string, program string, session varint (0: a new one) | Welcome: server id, cluster id, session, frame limit, writes in flight limit |
| 2 Open | database name | Opened: handle, newest group, the properties (id, name, type code, many, unique) |
| 3 Get | handle, thing | Facts: the view's group, count, (property, value)... |
| 4 Find | handle, question, select | Rows (in frames of about 1 MiB, all but the last with `more`): the view's group, columns, count, values row by row |
| 5 Write | handle, serial, floor, by (zigzag), why, count, operations | Receipt: the group, count, (new thing's temporary id, its id)... |
| 6 Ping | any bytes | Pong: the same bytes |
| 7 Admin | "status" | Status: count, (key, value)... |

- A **question** is data: variables, patterns (thing, property, value, each a variable, a thing or a value) and ranges,
  as `Cepheus.query` ([API](api.md)); no code crosses the wire, and every property is checked against the database's
  schema.
- **select**: `Give [x...]` gives those variables of each answer, in this order (none: all); `Group ([k...], [a...])`
  gives one row a distinct key: the key's variables, then the aggregates `Count`, `Sum x` (int, money), `Min x`, `Max x`
  (int, money, date), computed in the server without building the answers (Q4 below: 100 rows instead of 453,866).
- An **operation**: 0 Add, 1 Retract, 2 Expect a value, 3 Expect none; then the thing (zigzag: a negative id is a new
  thing of the group), the property, the value.
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
  by frame: the next frame is coded once the socket took the previous one.

### Beside the protocols of the giants (by their documentation)

| | framing | many requests in flight | replies | pushes | errors | flow control |
|---|---|---|---|---|---|---|
| PostgreSQL (protocol 3.0; 3.2 since 18) | "The first byte of a message identifies the message type, and the next four bytes specify the length of the rest of the message" | pipelining with the extended protocol (Parse, Bind, Execute, Sync) | in order | `LISTEN`/`NOTIFY` | `ErrorResponse`; in a pipeline "the backend will skip command messages until it finds Sync" | TCP |
| Redis RESP2/RESP3 | "The first byte in an RESP-serialized payload always identifies its type"; CRLF-terminated parts, length-prefixed bulk strings | pipelining | in order | RESP3 push type | error type `-` | TCP; slow clients closed |
| etcd | gRPC ("All etcd APIs are defined in gRPC services") | many calls | each call its own | Watch streams | gRPC status | gRPC's; requests at most 1.5 MiB by default |
| FoundationDB | the client library is the protocol: programs call its C library (futures) | futures | per future | watches (10,000 a connection by default) | error codes | the library's |
| Cepheus | length, id, kind, flags; the journal's coding of values | up to the limit Welcome states | **by id, out of order** | (subscriptions: step 5) | `{code, message}` values | TCP, and the server stops reading at the limit |

### Errors

Every reply is a value or an error `{code, message}`. The engine's codes: `conflict`, `invalid`, `unique`, `damaged`,
`io`, `busy`, `closed` ([errors](errors.md)). The server's:

| code | when | what to do |
|---|---|---|
| `auth` | Hello with an unknown token; a request before Hello; a token removed since | check the token; the connection closes |
| `denied` | the token lacks the right for this database or operation; a session of another token | a token with the right |
| `version` | Hello with another protocol version | the server and the library of one release |
| `too_large` | a frame over 16 MiB | write in smaller groups; the connection closes |
| `unknown_database` | a name or handle the server does not hold | declare it in cluster.toml |
| `stopping` | the server is stopping | connect again: the library does |
| `refused` | a write sent again after a later write of its session was applied, whose first error was lost when the server started again (its error, when the same server refused it, is given again instead) | it was not applied: decide again |
| `invalid` | a malformed request (the connection closes), a question that does not check, a serial below its session's floor, a why that starts with the server's marker | fix the request |

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
min(the published group, the published group when each write in flight was sent), and a write sent when the published
group was P takes a group after P; every write after the checkpoint's group is in the journal with its origin, read
at start. A durable group is therefore always found, and a write that was not durable was not applied (G1, G3), so
sending it again applies it once. (3) The new things' ids are recomputed from the group's first new id and the order
of first use in the operations, the rule the engine numbers them by.

*Tests.* `server_sim` (simulation: every receipt, first or resent, against the journal: each (session, serial) in at
most one group, the receipt names it and its new things; through crashes, power losses, damaged checkpoints and
broken connections); `server_crash` (a real server killed 20 times under four writing clients: no value twice, none
acknowledged missing); `server_unit` (the table: in flight, done, floors, the checkpoint and its CRC).

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
within a second of the file's change. *Conditions*: the token is secret; `tokens.toml` is writable by the server's
user only. *Proof*: every request passes one check of the connection's rights for its database, recomputed whenever
the table of tokens changes (one comparison of the table's identity a request); writes carry the token's name in
their origin. *Tests*: `server_unit` (every token against every request on every database, a removed token, rights
narrowed, a forged origin refused, a frame over the limit); `server_sim` (random requests of every token checked
against its rights, and every group of the journal against its token's); `server_crash` (a token removed from the file
while its program is connected).

### Who may reach the socket

The Unix socket's directory is the gate on one machine: make it `0750`, owned by the server's user and a group of
the programs allowed to connect (`chgrp cepheus /run/cepheus`); the token is still needed. Over TCP, TLS.

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
  Between servers (replication, later), both sides will show a certificate of the CA naming a listed peer: mutual
  TLS, as FoundationDB and etcd do.
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

| | Cepheus | PostgreSQL 18.6 | ratio |
|---|---:|---:|---:|
| empty round trip, Unix socket (Ping; `SELECT 1`), n = 21 | 9.32 µs [8.75, 9.77] | 15.19 µs [14.57, 16.30] | 1.6× |
| point read, 1 client, Unix socket, n = 21 | **10.81 µs** [10.36, 11.15] | 26.39 µs [25.22, 27.78] | 2.4× |
| point read, 1 client, TCP + TLS 1.3, n = 21 | **39.18 µs** [36.24, 44.59] | 49.64 µs [48.31, 50.61] | 1.3× |
| point read, TCP without TLS (PostgreSQL), n = 21 | (no plain TCP: TLS always) | 35.81 µs [34.54, 37.71] | |
| point reads, 16 in flight on one connection (a pipeline of 16), per read, n = 11 | **1.46 µs** [1.34, 2.06] | 9.11 µs [8.78, 10.45] | 6.2× |
| point reads, 128 in flight, per read, n = 11 | 1.31 µs [1.29, 1.36] | | |
| 8 clients, one read in flight each: wall time per read, n = 11 | **3.22 µs** [2.96, 3.47] | 6.54 µs [6.17, 7.39] | 2.0× |
| 64 clients, n = 11 | 3.14 µs [2.99, 3.71] | 7.00 µs [6.78, 7.68] | 2.2× |
| 256 clients, n = 11 | 2.88 µs [2.73, 3.94] | 12.83 µs [11.96, 13.75] | 4.5× |
| Q3, the unpaid invoices of a city (city-7: 396 rows of 2 values), n = 11 | 0.487 ms [0.474, 0.526] | 0.662 ms [0.656, 0.699] | 1.4× |
| Q4, the unpaid sum and count by city (100 rows, aggregated in the server), n = 11 | 12.37 ms [11.35, 13.87] | 18.47 ms [18.36, 19.23] | 1.5× |
| a new connection with TLS and its first request, n = 7 | 2.60 ms [2.53, 2.76] | 4.28 ms [4.24, 4.56] | 1.6× |
| a new connection, Unix socket (PostgreSQL's fork of a backend), n = 7 | | 2.03 ms [2.01, 2.04] | |

What it says:

- **One client**: a point read costs the kernel's round trip (two system calls a side and two wake-ups: the 9.32 µs
  of Ping) and 1.5 µs of the server's work (decoding, the read of the view, coding). PostgreSQL's own floor, `SELECT 1`,
  is 15.2 µs: its work a statement is larger than our whole read. The plan's target was 10 µs; the empty round trip
  on this machine was 8.46 µs when the design measured it and 9.32 today, so 10.8 is the floor plus the same 1.4-1.5
  µs of work. Only not making the round trip goes below it (local reads, step 3: 0.42 µs).
- **Many clients**: the plan's main target, 8 clients at most 4 µs a read (PostgreSQL 6.2 µs when the design measured
  it, 6.5 today), holds: 3.22 µs. With one I/O domain the server answered every 9.6 µs (the prototype): the I/O
  domains are what wins it (3 rounds at each k = 1, 2, 4, 8: 9.1-10.0, 5.3-5.5, 2.9-4.0 and 2.1-3.1 µs; 4, the default,
  keeps 16 in flight at 1.3-1.5 µs where 8 domains gave 1.5-2.1). PostgreSQL's
  process a connection pays more as connections grow (12.8 µs at 256); our threads in 4 domains do not.
- **Pipelining** (several requests in flight on one connection, the replies matched by id): 1.46 µs a read with 16 in
  flight, 6.2 times PostgreSQL's pipeline of 16, where the backend still answers in order and parses each statement.
- **TLS** costs us 28.4 µs more than the Unix socket (39.2 against 10.8); OpenSSL's own TLS round trip in C on this
  machine (64 bytes each way, the design's prototype) costs 27.06 µs against 16.04 in plain TCP: 11.0 µs of TLS. Ours
  adds about 16 µs over plain TCP (23.2 µs, step 1's server, n = 11): the memory buffers through which OpenSSL works
  here (a copy into them and one out, and more OpenSSL calls a read) cost the rest. Both sides use OpenSSL's default
  TLS 1.3 cipher (AES-256-GCM); the C prototype, AES-128-GCM. The plan's target was 36 µs: missed by 3 µs; still
  1.3 times PostgreSQL with TLS. A new TLS connection costs 2.6 ms (one ECDSA signature by the server, the client's
  checks; no client certificate), 1.6 times less than PostgreSQL's.
- **Q3 and Q4** go through the socket as rows (Q3) and as aggregates computed in the server (Q4: 100 rows sent,
  not 45,064): 1.4 and 1.5 times faster than PostgreSQL's plans. Both sides give the same answers: 396 rows for
  city-7, and 45,064 unpaid invoices summing to 2,248,567,111 cents (a fresh load of the same seeded data,
  `bench.exe read`; PostgreSQL on its rows), and the same 100 invoices (`sbench.exe check` against `psql`).

**Durable writes** (a new invoice of 4 facts a write, each answered after its fsync; groups a second, n = 7, 3 s a
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

Local reads in the program's own memory with leases (step 3), the Cesia client (step 4),
subscriptions over the wire and many databases sharing one fsync (step 5), a replica (step 6), Raft on three machines
(step 7), memory databases with `Expire` and `Incr` (step 8). Until the Cesia client exists, a program written in
OCaml can still open a database directory in its own process (`Cepheus.open_`), which the tests use; the server is
the one way for everything else.
