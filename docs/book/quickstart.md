# Quick start

In about ten minutes: build Cepheus, start a server, and run a first Cesia program that writes to a database and asks
it a question. Each command below was run as written; what follows a command is what it printed (`/home/you` stands
for your home directory). Running it in production: [the production guide](production.md).

## What you need

- Linux on x86-64 or arm64, with the processor's CRC-32C instruction ([limits](limits.md#files-and-the-platform)).
- OCaml 5 with dune, a C compiler, and the headers of OpenSSL 3 (the package `libssl-dev` on Debian and Ubuntu,
  `openssl-devel` on Fedora).
- For the Cesia program: Cesia built from its sources with that same OCaml (Cesia's README, "From the sources"), here
  in `~/cesia`. The package's **engine**, the OCaml part of the client, is compiled against the native interface of
  the Cesia that will load it ([the package](cesia.md#the-package)), and a release of Cesia does not hold that
  interface yet.

## 1. Build and install

```sh
git clone https://github.com/www-celestial/cepheus.git ~/cepheus
cd ~/cepheus
export CESIA_NATIVE=~/cesia/_build/default/src/native/.cesia_native.objs/byte
dune build --profile release
mkdir -p ~/.local/bin
install -m 755 _build/default/bin/main.exe ~/.local/bin/cepheus
cepheus
```

```text
usage: cepheus serve|stop|status --config FILE
       cepheus token add NAME [--database DB=read|write]... [--admin] --config FILE
       cepheus token list|remove [NAME] --config FILE
       cepheus cluster init|cert NAME --dir DIR [--host H]...
```

`CESIA_NATIVE` names the folder of that Cesia's native interface (`cesia_v1.cmi`): with it, the build also makes the
engine, `_build/default/cesia/native/cepheus.cmxs`. The build takes under a minute on 8 cores. `~/.local/bin` must be
in your `PATH`.

## 2. Start a server

A **cluster** is the set of servers that hold the same databases; a single machine is a cluster of one.
`cepheus cluster init` makes one in a folder: its certificates for TLS, and `cluster.toml`, its configuration, with
one database, `main`. A program shows a **token** to the server, which grants it rights database by database:

```sh
cepheus cluster init shop --dir ~/shop
cepheus token add app --database main=write --config ~/shop/cluster.toml > ~/shop/app.token
cepheus serve --config ~/shop/cluster.toml &
```

```text
/home/you/shop/srv1.pem
/home/you/shop/srv1.key
/home/you/shop/cluster.toml
cepheus: token app added to /home/you/shop/tokens.toml; it is shown only now
cepheus: ready in 29.6 ms: main at group 1; socket /home/you/shop/run/.s.cepheus.7400, tcp 127.0.0.1:7400; 4 I/O domains, at most 512 connections; server cph-s-1145b71ef8b792d9, cluster cph-c-fb63d087d53d9a15
```

The token itself went into `~/shop/app.token`: the server keeps only its hash, so it is shown once. The server
listens on a Unix socket in `~/shop/run` (programs of this machine) and on TCP port 7400 with TLS (other machines).
Every key of `cluster.toml` and every command: [the server](server.md#running-a-server).

## 3. A project for the program

A Cesia program takes the client as a dependency, the package `cesia/cepheus` of this repository. Cesia's own way is
`cesia pkg add`, which fetches a tagged release; Cepheus has none yet, so put the package in the project's `deps/`
from your build, as `cesia pkg` would, and write its `cesia.lock`:

```sh
mkdir -p ~/todo/deps/www-celestial/cepheus/cesia ~/todo/deps/www-celestial/cepheus/native
cd ~/cepheus
cp cesia.toml ~/todo/deps/www-celestial/cepheus/
cp -R cesia/cepheus ~/todo/deps/www-celestial/cepheus/cesia/
cp _build/default/cesia/native/cepheus.cmxs ~/todo/deps/www-celestial/cepheus/native/cepheus-$(cesia run tools/tag.ce).cmxs
```

Then make `~/todo/cesia.toml`:

```toml
[project]
name = "todo"

[deps.cepheus]
from = "github.com/www-celestial/cepheus"
version = "v0.1.0"
take = ["cesia/cepheus"]
```

and write the lock, the fingerprint of each file of `deps/`, which Cesia checks before it loads the engine:

```sh
cd ~/todo
cesia run --allow read,write ~/cepheus/tools/lock.ce
```

## 4. A first program

Make `~/todo/todo.ce`:

```cesia norun
use deps/www-celestial/cepheus/cesia/cepheus
use std/io
use std/result
use std/sys

Task = cepheus.Kind("task", {Title: cepheus.Text(), Done: cepheus.Bool()})

db = result.Unwrap(cepheus.Connect(sys.Env("CEPHEUS_URL"), [Task], token = sys.Env("CEPHEUS_TOKEN")))

milk = result.Unwrap(cepheus.Insert(Task, {Title: "Buy milk", Done: false}, db, by = 1, why = "quick start"))
result.Unwrap(cepheus.Insert(Task, {Title: "Read the guide", Done: false}, db, by = 1, why = "quick start"))
result.Unwrap(cepheus.Update(Task, milk, {Done: true}, db, by = 1, why = "bought"))

open = cepheus.Find(2, (t, title) -> {
  Where: [[t, Task.Done, false], [t, Task.Title, title]],
  Give: {Task: t, Title: title},
}, db)
io.Print(open)
```

and run it with the address of the database and the token:

```sh
export CEPHEUS_URL="cepheus://localhost:7400/main?socket=$HOME/shop/run"
export CEPHEUS_TOKEN=$(cat ~/shop/app.token)
cesia run --allow native=cepheus,env todo.ce
```

```text
Ok([{Task: 65537, Title: "Read the guide"}])
```

What it did:

- `cepheus.Kind` names a sort of thing and its fields; `Connect` declares in the database the properties it lacks
  (`task/Title`, `task/Done`), in one write ([kinds](cesia.md#kinds-and-the-values-they-hold)).
- Each `Insert` and `Update` is a **group**: a write of several facts, all or nothing, answered once it is on the
  server's disk, and kept in the history with `by` and `why` ([Insert, Get, Update](cesia.md#insert-get-update)).
- `Find` is a question: the things whose `Done` is false, with their title. Its patterns are facts that must hold,
  its variables the function's parameters ([questions](cesia.md#find-questions)).
- `--allow native=cepheus,env` lets the program load the package's engine and read the two variables of its
  environment ([the permission](cesia.md#the-package)).

Run it again: it adds two more tasks, and the question finds both unfinished ones:

```text
Ok([{Task: 65537, Title: "Read the guide"}, {Task: 65539, Title: "Read the guide"}])
```

## 5. Stop, start, look

`cepheus status` shows what the server holds; it needs a token with `--admin`:

```sh
cepheus token add ops --admin --config ~/shop/cluster.toml > ~/shop/ops.token
CEPHEUS_TOKEN=$(cat ~/shop/ops.token) cepheus status --config ~/shop/cluster.toml
```

```text
server: cph-s-1145b71ef8b792d9
cluster: cph-c-fb63d087d53d9a15
uptime_ms: 31666
connections: 1
requests: 19
gc_minor: 2
gc_major: 0
stopping: false
commit_buffer.rounds: 0
commit_buffer.frames: 0
commit_buffer.alone: 7
database.main.group: 8
database.main.facts: 36
database.main.resent: 0
database.main.followers: 0
database.main.frames: 7
database.main.follow_ns_a_frame: 6471
database.main.visible: 9
database.main.watches: 0
```

Eight groups: the system's description of its properties, the declaration of the kind's two, and three writes for
each run of the program. What each line means, and which to watch: [the production guide](production.md#what-to-watch).

Stop the server, start it again, and run the program a third time:

```sh
cepheus stop --config ~/shop/cluster.toml
cepheus serve --config ~/shop/cluster.toml &
cd ~/todo && cesia run --allow native=cepheus,env todo.ce
```

```text
stopped (process 541045, 443 ms)
cepheus: ready in 1.7 ms: main at group 8; socket /home/you/shop/run/.s.cepheus.7400, tcp 127.0.0.1:7400; 4 I/O domains, at most 512 connections; server cph-s-1145b71ef8b792d9, cluster cph-c-fb63d087d53d9a15
Ok([{Task: 65537, Title: "Read the guide"}, {Task: 65539, Title: "Read the guide"}, {Task: 65541, Title: "Read the guide"}])
```

The groups were on the disk when each write was answered (G1, [guarantees](guarantees.md#g1-durability)); a clean
stop closed the database, so the start replayed nothing.

## Next

- [A real app](app.md): an app of invoices and clients on this stack, built step by step and run in production.
- [Concepts](concepts.md): facts, groups, views, questions, forks.
- [Cepheus from Cesia](cesia.md): every call of the client, `Write` with `Expect`, aggregates, live questions
  (`Watch`), forks for tests, reads in the program's own memory.
- [The server](server.md): `cluster.toml`, tokens and rights, TLS for programs on other machines.
- [The production guide](production.md): a service, backups, what to watch, upgrades, crashes.
