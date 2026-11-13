# A real app: invoices and clients

This page builds a whole application on the stack, step by step, from `cesia new` to a service in production: an app
of invoices and clients written in [Cesia](https://github.com/www-celestial/cesia), its data in a Cepheus server, its
screens live through Cesia's `std/live`, and its end-to-end tests driving Firefox through Ceti. Its code is in
[`examples/invoices`](https://github.com/www-celestial/cepheus/tree/main/examples/invoices) of this repository, about 1,600 lines of Cesia, and 460 of tests; each
step below shows the part that matters and names the file that holds the rest. Every command was run as written, and
what follows it is what it printed (`/home/you` stands for the home directory).

## What you build

- **Clients** (name, e-mail, city) and **invoices** (a client, a date, a due date, lines of a quantity and a price, a
  status `unpaid`, `paid` or `late`, a total computed from the lines): made, changed, listed and deleted, each with
  its checks (a paid invoice stays as it is; a client with invoices stays).
- **Lists** in pages after a row, never by an offset, sorted, with a search as one types and filters.
- A **live dashboard**: what is not paid, what is late, and the latest payments, changing by themselves in every open
  page when anything changes.
- **Users**: an admin, who does everything, and an accountant, who reads and adds invoices only, and whose requests
  go to the database through a token that can read nothing else.
- A **rule** of the database (a client with a late invoice is overdue) and a **constraint** (no invoice of a deleted
  client), kept by Cepheus at every write.
- A **CSV export**, **backups**, 10,000 clients and 100,000 invoices of made-up data loaded in about 6 seconds, unit
  tests, end-to-end tests in Firefox, and the measured speed of every page.

## What you need

- Cepheus built with its Cesia client's engine, and the `cepheus` command on the `PATH`: steps 1 and 2 of the
  [quick start](quickstart.md). The checkout is `~/cepheus` here.
- Cesia 1.1 or later, the one the engine was built against; it brings libsodium, which `std/crypto` uses for the
  passwords.
- For the end-to-end tests: Firefox, and a checkout of Ceti, here `~/ceti`. For the measures: ApacheBench (`ab`).

## 1. The project

```sh
cd ~
cesia new invoices
```

```text
std/ holds the libraries of Cesia 1.1.0.
Created invoices. Run it: cd invoices && cesia do run
```

Copy the example's files into it (they replace the `src/main.ce` that `cesia new` wrote), then put the two
dependencies in `deps/`:

```sh
cd ~/invoices
cp -R ~/cepheus/examples/invoices/cesia.toml ~/cepheus/examples/invoices/src ~/cepheus/examples/invoices/tests ~/cepheus/examples/invoices/tools ~/cepheus/examples/invoices/bench .
CEPHEUS=~/cepheus CETI=~/ceti tools/deps.sh
```

`cesia.toml` names the dependencies the way Cesia's packages do, a repository and a tag:

```toml
[deps.cepheus]
from = "github.com/www-celestial/cepheus"
version = "v0.1.0"
take = ["cesia/cepheus"]

[deps.ceti]
from = "github.com/www-celestial/ceti"
version = "v0.1.0"
take = ["src/browser"]
```

Neither has a tagged release yet, so `cesia pkg install` cannot fetch them: `tools/deps.sh` does what it would, from
the two checkouts. It copies the Cesia package of Cepheus and its **engine** (the OCaml part of the client, built
with the Cepheus checkout, [the package](cesia.md#the-package)) into `deps/www-celestial/cepheus`, Ceti's
`src/browser` into `deps/www-celestial/ceti`, and writes `cesia.lock`, the fingerprint of every file, which Cesia
checks before it loads one. Without `CETI`, it installs Cepheus only: what the app needs to run.

The project's folders:

```text
invoices/
  cesia.toml            the dependencies, the tasks and their permissions, the tests' settings
  src/main.ce           the server: connects, defines the rules, serves
  src/invoices/         the app, one package: kinds.ce, check.ce, clients.ce, invoices.ce, paging.ce, auth.ce,
                        pages.ce, assets.ce, web.ce, and its tests store.test.ce and web.test.ce
  src/users/users.ce    adds a user
  src/seed/seed.ce      fills an empty database with made-up data
  tests/e2e/            the end-to-end tests, in Firefox
  tools/                deps.sh, lock.ce, e2e.sh
  bench/                the measures of this page
```

Each program has a folder of its own: the files of one folder are one package, so two programs side by side would
share their names.

## 2. A database server for the app

A server of its own, in `~/invoices-db`, with one database, `invoices`:

```sh
cepheus cluster init invoices --dir ~/invoices-db
sed -i 's/^name = "main"/name = "invoices"/' ~/invoices-db/cluster.toml
```

```text
/home/you/invoices-db/srv1.pem
/home/you/invoices-db/srv1.key
/home/you/invoices-db/cluster.toml
```

The app shows the server two **tokens**, the secrets that grant rights on a database ([rights](server.md#rights-g16)):
its own, which writes; and the accountant's, which reads and adds only the kinds `invoice` and `line`:

```sh
cd ~/invoices-db
(umask 077
 cepheus token add web --database invoices=write --config cluster.toml > web.token
 cepheus token add books --database "invoices=read:invoice,line;add:invoice,line" --config cluster.toml > books.token
 cepheus token add ops --admin --config cluster.toml > ops.token)
cepheus token list --config cluster.toml
cepheus serve --config ~/invoices-db/cluster.toml &
```

```text
cepheus: token web added to ./tokens.toml; it is shown only now
cepheus: token books added to ./tokens.toml; it is shown only now
cepheus: token ops added to ./tokens.toml; it is shown only now
web invoices=write
books invoices=read:invoice,line;add:invoice,line
ops admin
cepheus: ready in 33.0 ms: invoices at group 1; socket /home/you/invoices-db/run/.s.cepheus.7400, tcp 127.0.0.1:7400; 4 I/O domains, at most 512 connections; server cph-s-9fec02740f6f3f07, cluster cph-c-b13d6097382a6ee2
```

`umask 077` makes the token files readable by you only. Why two tokens for one app: every request of an accountant
reads and writes through the second one, so a page that would show an accountant a client is refused twice, by the
app (a 403) and, if the app had a bug, by the database itself (`denied`). The protection does not rest on the app's
code alone. The price: a token with rights per kind never reads in the program's own memory (its reads go to the
server through its socket: [rights](server.md#rights-g16)), which the measures below show.

The app reads its settings from its environment:

```sh
export CEPHEUS_URL="cepheus://localhost:7400/invoices?socket=$HOME/invoices-db/run"
export CEPHEUS_TOKEN=$(cat ~/invoices-db/web.token) CEPHEUS_BOOKS_TOKEN=$(cat ~/invoices-db/books.token)
```

## 3. The kinds, the rule and the constraint

`src/invoices/kinds.ce` declares what the database holds. A **kind** is a sort of thing and its fields; each field
is a property of the database, as `invoice/Total` ([kinds](cesia.md#kinds-and-the-values-they-hold)):

```text
Client = cepheus.Kind("client", {
  Name: cepheus.Text(), Search: cepheus.Text(), Email: cepheus.Text(unique = true), City: cepheus.Text(),
  Overdue: cepheus.Bool(),
})

Invoice = cepheus.Kind("invoice", {
  Number: cepheus.Int(unique = true), Client: cepheus.Link(), BillTo: cepheus.Text(), Search: cepheus.Text(),
  Date: cepheus.Date(), Due: cepheus.Date(), Status: cepheus.Text(), Total: cepheus.Money(2), PaidAt: cepheus.Date(),
})

Line = cepheus.Kind("line", {
  Invoice: cepheus.Link(), Position: cepheus.Int(), Label: cepheus.Text(), Quantity: cepheus.Int(), Price: cepheus.Money(2),
})

User = cepheus.Kind("user", {Login: cepheus.Text(unique = true), Hash: cepheus.Text(), Role: cepheus.Text()})
Session = cepheus.Kind("session", {Key: cepheus.Text(unique = true), User: cepheus.Link(), Expires: cepheus.Date()})
```

The choices in it:

- **`BillTo`** is the client's name as it was when the invoice was made, as a real invoice keeps it: the accountant,
  who may not read clients, still sees whom each invoice bills.
- **`Search`** holds a name in lower case. `cepheus.Prefix` compares bytes ([Prefix](cesia.md#prefix-the-start-of-a-text)),
  so a search without case keeps a field in the form it searches. `text.Lower` changes A to Z only; the app's
  `Lower` (`check.ce`) lowers the accented letters of Latin-1 too, so that "él" finds "Élodie".
- **`Total`** is computed from the lines when an invoice is written, in cents, exactly: `Money(2)` keeps minor units.
- **`Overdue`** is never written by the app: the database derives it. Every client has a **`Name`** (`ClientForm`
  checks it): a deleted client has none.

The two **rules** ([rules from Cesia](cesia.md#rules)):

```text
Overdue = cepheus.Rule("overdue", 2, (c, i) -> {Where: [[i, Invoice.Client, c], [i, Invoice.Status, "late"]], Then: [c, Client.Overdue, true]})
NoInvoiceOfDeleted = cepheus.Rule("no-invoice-of-a-deleted-client", 3, (c, i, n) -> {Where: [[i, Invoice.Client, c], cepheus.Not([c, Client.Name, n])], Then: cepheus.Never})
```

- `overdue`: a client with a late invoice is overdue. The database adds the fact in the group that makes an invoice
  late, and takes it away in the group that pays the client's last late one, since it then has no proof left: the app
  only reads `Client.Overdue`, on the client's page.
- `no-invoice-of-a-deleted-client` is a **constraint**: a group that would give it an answer is refused whole. Its
  `Not` holds when the client has no name at all: `n` is in no other pattern, so it is the Not's own ("there is no
  `n` such that..."). Deleting a client checks first that it has no invoice, for a clear message; but between that
  check and the delete, another request could give it one, and `Expect` checks only a thing's own facts, not that no
  invoice points to it. The delete retracts the client's fields, its name with them: whichever of the two groups
  comes second is refused by the database, in either order, and so is an invoice of a client that never was.

`src/main.ce` connects with each token and defines the rules at every start: `cepheus.Define` writes only those that
are new or changed.

```text
full = ready("connect", cepheus.Connect(url, invoices.Kinds, token = setting("CEPHEUS_TOKEN")))
books = ready("connect for the accountant", cepheus.Connect(url, invoices.Books, token = setting("CEPHEUS_BOOKS_TOKEN")))
ready("rules", cepheus.Define(invoices.Rules, full))
```

## 4. What a visitor sends

`src/invoices/check.ce` reads every form before anything is written or asked. A field is a text of bounded size
(a name 120 bytes, an e-mail 254, a label 200), valid UTF-8, without control characters; an id is a whole number
above 0 of at most 12 digits; a date is `2026-11-13` and nothing else; a price has at most two decimals and at most
1,000,000,000; an invoice has 1 to 50 lines, each a quantity from 1 to 1,000,000. A check gives an `Ok` of the
values, or an `Err` of a map from each wrong field to its message, which the form shows beside the field:

```text
ClientForm({name: "", email: "nobody", city: "Lyon"})      (* Err({Name: "A name of 1 to 120 bytes, without control characters.", Email: "An e-mail address, as ada@example.com."}) *)
ClientForm({name: " Ada ", email: " ADA@Example.COM ", city: "Lyon"})   (* Ok({Name: "Ada", Search: "ada", Email: "ada@example.com", City: "Lyon"}) *)
```

The server takes bodies of at most 64 KiB (`maxBody` of `http.Serve`; a form of 50 lines is about 30 KB), and a
cursor of a page at most 2 KB.

## 5. Writing: invoices with their lines, paid once

`src/invoices/invoices.ce`. An invoice and its lines are **one group**, all or nothing: `cepheus.New(k)` names the
group's k-th new thing, so the lines point to the invoice before it has an id
([Write](cesia.md#write-groups-of-facts-all-or-nothing)):

```text
defn AddInvoice(f, billTo, by, db)
  for attempt in 1..5
    n = nextNumber(db)?
    inv = cepheus.New(1)
    ops = list.Concat([cepheus.Add(inv, Invoice.Number, n), cepheus.Add(inv, Invoice.Client, f.Client), cepheus.Add(inv, Invoice.BillTo, billTo),
                       cepheus.Add(inv, Invoice.Search, Lower(billTo)), cepheus.Add(inv, Invoice.Date, f.Date), cepheus.Add(inv, Invoice.Due, f.Due),
                       cepheus.Add(inv, Invoice.Status, "unpaid"), cepheus.Add(inv, Invoice.Total, f.Total)], lineOps(inv, f.Lines, 2))
    done = cepheus.Write(ops, db, by = by, why = "invoice added")
    if result.IsOk(done)
      return result.Ok({Invoice: done.Value.Things[1], Number: n})
    end
    if done.Error.Code != "unique"
      return done
    end
  end
  result.Err({Code: "busy", Message: "Many invoices are being made at once: try again."})
end
```

- The number is the largest one plus one, read in the index's order (`Sort: [cepheus.Desc(n)], Limit: 1`: one row),
  so that the numbers follow each other without a gap, as the law of many countries asks of invoices. Two requests
  that read the largest at once would take the same number: `AddInvoice` numbers one invoice at a time in the process
  (a channel of one place, `fiber.Send` to take it, `fiber.Receive` to give it back), and `Number` is `unique`, so a
  group of another process that took the number first refuses this one, which takes the next. The price: the
  invoices of one process are made one after the other, each waiting for its group to be on the disk.
- `by` is the user's id and `why` says what the group did: both stay with the group in the database's history.

Paying is an **optimistic** check: the group is refused unless the status is still the one that was read, so an
invoice is paid once, whatever two pages do at the same instant:

```text
done = cepheus.Write([cepheus.Expect(id, Invoice.Status, inv.Status), cepheus.Add(id, Invoice.Status, "paid"), cepheus.Add(id, Invoice.PaidAt, now)], db, by = by, why = "invoice paid")
```

Changing an invoice (`EditInvoice`) and deleting one (`DeleteInvoice`) expect its status the same way, and refuse a
paid one: a paid invoice is a record of the accounts. `MarkLate` makes the unpaid invoices whose due date has passed
late, 500 to a group, each expected unpaid; `src/main.ce` runs it every minute, with the end of the sessions that
lapsed.

## 6. Reading: pages, search and filters

`src/invoices/paging.ce` gives a page of any sorted question. A page is the rows **after** a row, in the question's
order (`After`, [pages](cesia.md#sort-limit-and-after-pages)), never "skip the first 4,000": a page 50,000 rows deep
costs what the first does, and a row written between two pages moves neither. The page before is the same question
with each key of `Sort` reversed, after the page's first row; `Page` asks one row more than it shows, to know whether
there is a next one. The cursor of a link is the last row (or the first, for the page before), as Base64 of its
JSON: a visitor can write one by hand, so it is read as any input, a JSON object of at most 2 KB, whose fields the
question checks against their types (a wrong one is a 400).

**Keys first, then rows.** A sorted page costs about the patterns of each answer it reads; and at 100,000 invoices, a
page of the eight patterns that one row of the list needs (number, bill-to, date, due date, status, total, and the
search) left the index's order and read every answer: 9.1 ms, against 0.88 ms for seven patterns, 0.25 for six and
0.18 for five (the best of 20 runs of each, outside the machine's lock). So the list asks the
page of its **keys** first, five patterns (the number, the status, the due date, the date or the total of the order,
and the filters), then the other fields of those 20 invoices only, with their ids as `cepheus.In`:

```text
rows = cepheus.Find(7, (i, no, b, d, u, s, t) -> {
  Where: [[i, Invoice.Number, no], [i, Invoice.BillTo, b], [i, Invoice.Date, d], [i, Invoice.Due, u], [i, Invoice.Status, s], [i, Invoice.Total, t], cepheus.In(i, [k.Invoice for k in keys])],
  Give: {Invoice: i, Number: no, BillTo: b, Date: d, Due: u, Status: s, Total: t},
}, db)?
```

A page of invoices takes about 1 ms that way, through HTTP, sorted by any of its orders, filtered or searched (one
request each took 9 to 69 ms with a single question): see [what it costs](#14-what-it-costs). The list of clients
does the same for their e-mails.

**The search as one types** is a `Prefix` on the name in lower case or on the e-mail, either one, with `Or`:

```text
Where: [[c, Client.Name, n], [c, Client.City, y], [c, Client.Search, k], [c, Client.Email, e], cepheus.Or(cepheus.Prefix(k, search), cepheus.Prefix(e, search))]
```

The page's script asks `/clients?part=rows&q=...` 100 ms after the last key, and puts the rows that the server made
and escaped in place.

**The filters** use each condition of a question where it is natural (`filterOf` in `invoices.ce`):

- the status boxes of the list, one or two of unpaid, late and paid: `cepheus.In(s, statuses)`;
- "late or due within a week": `cepheus.Or([i, Invoice.Status, "late"], cepheus.And([i, Invoice.Status, "unpaid"], cepheus.Below(u, now + Week)))`;
- what a client owes, and its invoices not paid, on its page: `cepheus.Not([i, Invoice.Status, "paid"])`, and the
  sum with `cepheus.Sum(t)` and `cepheus.Count()`.

Every variable of a question must be in one of its patterns, and `Find` is told how many there are: so the list
without a search is a question of five variables, and with one, of six.

## 7. Tests on forks

A **fork** is a database in the program's memory, with every check of a real one, rules included, and no server
([forks](cesia.md#forks)). Each test of `src/invoices/store.test.ce` forks `cepheus.Empty` with the app's kinds and
rules:

```text
defn isLateAndOverdue()
  s = shop()?
  n = MarkLate(now, s.Db)?
  late = GetInvoice(s.One.Invoice, s.Db)?.Status
  overdue = GetClient(s.Ada, s.Db)?.Overdue
  PayInvoice(s.One.Invoice, now, 0, s.Db)?
  n == 1 and late == "late" and overdue == true and GetClient(s.Ada, s.Db)?.Overdue == missing and MarkLate(now, s.Db)? == 0
end
```

and `src/invoices/web.test.ce` asks the routes through `http.Handler`, with no network: sign-in, cookies, the same-origin
check, roles, escaping, the forms, the export, the headers, a cursor made by hand. Both paths of Cesia:

```sh
cd ~/invoices
cesia test src
cesia test --no-spec src
```

```text
23 passed, 0 failed
23 passed, 0 failed
```

(The tests that sign in with a wrong password write the app's log line, `{"level":"warn","message":"sign-in refused"}`,
between them.) The unit tests are `cesia test src`: a bare `cesia test` would also run `tests/e2e`, which need a
server (step 12).

## 8. The web app

`src/invoices/web.ce` is the app: `App(env)` gives its routes, each a handler of a request.

**Signed in, and by role.** Every route but the sign-in page goes through `signed(env, role, handler)`: it finds the
session of the request's cookie, refuses a visitor without one (a GET goes to `/login`, anything else gets a 401) and
a user of another role (a 403), and gives the handler the user with **the database of its role**:

```text
then http.Get("/clients", signed(env, "admin", clientsList))
then http.Get("/invoices", signed(env, "any", invoicesList))
```

```text
u.Db = if u.Role == "admin" env.Full else env.Books end
```

**Passwords and sessions** (`auth.ce`). A password is kept as its Argon2id hash only (`crypto.HashPassword`, through
libsodium: [cryptography](https://github.com/www-celestial/cesia/blob/main/docs/book/crypto.md)). An unknown login is
checked against the hash of a password nobody has, so that it takes as long as a wrong password and the time of a
reply tells nobody which logins exist; both get the same message. A session is 32 random bytes from the system
(`crypto.Random`), sent once in a cookie; the database keeps their BLAKE2b hash, so a copy of the database opens no
session. The cookie is `HttpOnly` (no script reads it), `SameSite=Strict` (no other site's page sends it), lasts 8
hours, and is `Secure` when the app serves https.

**The same-origin check.** A page of another site could post a form to the app with its visitor's cookie: a
*cross-site request forgery*. Browsers send the `Origin` of every such request, so a middleware refuses any request
that changes something (any method but GET and HEAD) unless its `Origin` is the app's own scheme and `Host`:

```text
if value.IsMissing(origin) or value.IsMissing(host) or (text.Lower(origin) != "http://$(text.Lower(host))" and text.Lower(origin) != "https://$(text.Lower(host))")
  return http.Plain("This request comes from another origin than the app's.", status = 403)
end
```

`std/live` checks its WebSocket the same way.

**Pages** (`pages.ce`) are HTML made on the server, every value from the database or from a visitor put through
`http.Escape`, so that a client named `<script>` shows as text. The style and the script are routes of the app,
`/app.css` and `/app.js`, and a middleware gives every response a `Content-Security-Policy` of `default-src 'self'`
(no inline code, nothing from another site), `frame-ancestors 'none'`, `nosniff`, `Referrer-Policy: same-origin`,
`Cache-Control: no-store`, and over https `Strict-Transport-Security`.

## 9. The live dashboard

The dashboard's numbers are three **watches** ([live questions](cesia.md#watch-live-questions)), given to the page by
`std/live` ([live screens](https://github.com/www-celestial/cesia/blob/main/docs/book/http.md#live-screens-stdlive)).
`live.Route("/live", screen)` serves them; `screen` runs when a page connects, finds its user by the cookie of its
request, and watches through the database of its role, each watch ended with the page (`until = s.Ended`):

```text
unpaid = cepheus.Watch(2, (i, t) -> {Where: [[i, Invoice.Total, t], cepheus.Not([i, Invoice.Status, "paid"])], Give: {Total: cepheus.Sum(t), Count: cepheus.Count()}}, db, until = s.Ended)?
late = cepheus.Watch(2, (i, t) -> {Where: [[i, Invoice.Status, "late"], [i, Invoice.Total, t]], Give: {Total: cepheus.Sum(t), Count: cepheus.Count()}}, db, until = s.Ended)?
paid = cepheus.Watch(5, (i, p, no, b, t) -> {
  Where: [[i, Invoice.PaidAt, p], cepheus.Above(p, since), [i, Invoice.Number, no], [i, Invoice.BillTo, b], [i, Invoice.Total, t]],
  Give: {Invoice: i, PaidAt: p, Number: no, BillTo: b, Total: t},
}, db, until = s.Ended)?
[live.Show("unpaid", unpaid.Changes), live.Show("late", late.Changes), live.Show("payments", paid.Changes)]
```

and the page's side, in `/app.js`, draws each show as it changes:

```js
const live = await connect('/live')
live.show('unpaid', rows => tile('unpaid', rows))
live.show('payments', rows => { /* the 10 latest, by PaidAt */ })
```

How a payment reaches every open page: the group is written and forced to the server's disk; the app's process,
which follows the database for its local reads, computes the watches' changes from the group (the totals by
difference, [how a change is computed](cesia.md#watch-live-questions)) and gives them once the group is durable; each
page's screen sends its change over its WebSocket; the page draws it at its next frame. Every page that watches the
same question shares one watch. A watch keeps no order and no limit, so "the latest payments" watches those of the
last 24 hours, and the page keeps the 10 latest. The accountant's dashboard is the same, through its token; its
watches are computed at the server, which pushes them.

## 10. The CSV export

`/invoices.csv` gives every invoice of the list's filter, in the order of their numbers: one question for the rows
(no page: no `Limit`), and one for the dates of payment of each 10,000 of them (`In` takes at most 10,000 values).
A cell that starts with `=`, `+`, `-`, `@`, a tab or a carriage return gets a `'` in front of it, so that a
spreadsheet never runs a bill-to name as a formula (CSV injection, as OWASP names it). The 100,000 invoices of the
seed export in about 1.2 s (one request), the 11,006 late ones in 114 ms ([what it costs](#14-what-it-costs)).

## 11. Run it

The users, with their passwords in the environment, never on a command line, where other users of the machine would
see them:

```sh
cd ~/invoices
APP_LOGIN=ada APP_ROLE=admin APP_PASSWORD="correct horse battery" cesia do users
APP_LOGIN=bo APP_ROLE=accountant APP_PASSWORD="another long secret" cesia do users
APP_LOGIN=eve APP_ROLE=admin APP_PASSWORD="short" cesia do users
```

```text
> cesia run --allow native=cepheus,ffi=sodium,env=CEPHEUS_URL,env=CEPHEUS_TOKEN,env=APP_LOGIN,env=APP_ROLE,env=APP_PASSWORD src/users/users.ce
user ada added, admin
> cesia run --allow native=cepheus,ffi=sodium,env=CEPHEUS_URL,env=CEPHEUS_TOKEN,env=APP_LOGIN,env=APP_ROLE,env=APP_PASSWORD src/users/users.ce
user bo added, accountant
> cesia run --allow native=cepheus,ffi=sodium,env=CEPHEUS_URL,env=CEPHEUS_TOKEN,env=APP_LOGIN,env=APP_ROLE,env=APP_PASSWORD src/users/users.ce
users: A password has 12 to 128 bytes.
```

`cesia do` runs a task of `cesia.toml` with its permissions, and prints the command it runs. (A task takes no
arguments, so the login and the role come from the environment too.)

The server:

```sh
cesia do serve &
```

```text
> cesia run --allow native=cepheus,ffi=sodium,env=CEPHEUS_URL,env=CEPHEUS_TOKEN,env=CEPHEUS_BOOKS_TOKEN,env=APP_PORT,env=APP_HOST,env=APP_CERT,env=APP_KEY,net=:8090 src/main.ce
{"time":"2026-11-12T23:05:27.255Z","level":"info","message":"ready","Port":8090,"Ms":8.456945419311523}
```

`Ms` is the time from the program's first line to its listener: the two connections, the rules, libsodium.

Open `http://127.0.0.1:8090/` and sign in as `ada`. The same with curl, to see each answer: the sign-in page first,
then a session, a client, and a form posted from another origin:

```sh
cd ~
B=http://127.0.0.1:8090
curl -s -o /dev/null -w "%{http_code} %{redirect_url}\n" $B/
curl -s -c ada.jar -o /dev/null -w "%{http_code} %{redirect_url}\n" -H "Origin: $B" -d "login=ada&password=correct+horse+battery" $B/login
client=$(curl -s -b ada.jar -o /dev/null -w "%{redirect_url}" -H "Origin: $B" -d "name=Ada+Martin&email=ada@example.com&city=Lyon" $B/clients)
echo $client
curl -s -b ada.jar -H "Origin: http://evil.example" -d "name=Mallory&email=m@evil.example" $B/clients
```

```text
303 http://127.0.0.1:8090/login
303 http://127.0.0.1:8090/
http://127.0.0.1:8090/clients/65539
This request comes from another origin than the app's.
```

An invoice for that client; then the accountant, who may not see the clients, pays it and exports the invoices:

```sh
invoice=$(curl -s -b ada.jar -o /dev/null -w "%{redirect_url}" -H "Origin: $B" -d "client=${client##*/}&date=2026-11-02&due=2026-12-02&label1=Design&quantity1=3&price1=400&label2=Hosting&quantity2=1&price2=80.50" $B/invoices)
echo $invoice
curl -s -c bo.jar -o /dev/null -H "Origin: $B" -d "login=bo&password=another+long+secret" $B/login
curl -s -b bo.jar -o /dev/null -w "%{http_code}\n" $B/clients
curl -s -b bo.jar -o /dev/null -w "%{http_code} %{redirect_url}\n" -H "Origin: $B" -X POST $invoice/pay
curl -s -b bo.jar $B/invoices.csv
```

```text
http://127.0.0.1:8090/invoices/65540
403
303 http://127.0.0.1:8090/invoices/65540
number,date,due,bill_to,status,total,paid_at
1,2026-11-02,2026-12-02,Ada Martin,paid,1280.50,2026-11-12
```

(The ids are the database's: its first things were the two users and ada's session. The day of payment is the UTC
day.)

**Data to try it at its size**: `cesia do seed` adds 10,000 clients and 100,000 invoices of one to five lines over
the last year (2.4 million facts), always the same ones: each draw is a hash of the invoice's number, and the numbers
follow those already there.

```sh
cd ~/invoices
cesia do seed
```

```text
> cesia run --allow native=cepheus,env=CEPHEUS_URL,env=CEPHEUS_TOKEN src/seed/seed.ce
10000 clients in 0.34 s
100000 invoices, 2384791 facts with their lines, in 12.50 s
rules defined in 0.95 s
```

The invoices go in groups of 20,000, about 480,000 facts each, so as to take the path of large groups in the database
([large groups](architecture.md#large-groups)). But a constraint, or a rule whose head is a property of one value,
sends a large group to the ordinary path of the writer; and the app, started above, defined its rules. Into a
database where they are not defined yet, the seed defines them after the load, in one group that derives over all of
it, and the whole seed takes 4.84 s ([what it costs](#14-what-it-costs)); here it took 12.5 s. Its `Define` then had
nothing to write, but waited, as the first read after the load, for the program's copy of the database to take in
the load's groups.

## 12. End-to-end tests in Firefox

`tests/e2e/e2e.test.ce` uses the app as a visitor does: Ceti ([its guide](https://github.com/www-celestial/ceti))
starts Firefox without a window, and the tests type in the forms and click. Each test serves the app itself, on a
free port, against a real Cepheus server that `tools/e2e.sh` starts in a new folder, with the two tokens, and stops
at the end whatever happens:

- an admin makes a client and an invoice through the forms, checks its total, and marks it paid;
- two pages open: an invoice made, then paid, in the first changes the second's dashboard by itself;
- the accountant has no Clients link, gets the app's 403 on `/clients`, and its token gets `denied` from the database
  for a question on clients;
- a page of another origin (another port) posts a form to the app with the signed-in visitor's cookie: refused, and no
  client made.

```sh
tools/e2e.sh
tools/e2e.sh tests/e2e --no-spec
```

```text
4 passed, 0 failed
4 passed, 0 failed
```

The first run makes Ceti's template profile in `.cesia/firefox`, kept for the next runs; no Firefox is left when the
tests end. A form posted by a click takes the page to another document, which an `Eval` started before cannot wait
for: the tests look at `location.origin` in an `Eval` of its own each time, until the page is where the form went.

## 13. In production

**The database server** runs as the [production guide](production.md) says: a service of its own, a user of its own,
its data in `/var/lib/cepheus`, nightly backups and a monthly restore drill.

**The app** serves https itself, through Cesia's `std/tls` (OpenSSL): `APP_CERT` and `APP_KEY` name a certificate
(with its chain) and its key, and the cookie is then `Secure`, with `Strict-Transport-Security`. The task
`serve-tls` of `cesia.toml` holds its permissions, every one of them needed and none more:

| permission | for |
|---|---|
| `native=cepheus` | the engine of the Cepheus client: total trust, as a C library, since its machine code runs outside Cesia's checks (and may reach any server) |
| `ffi=sodium` | libsodium, for the passwords and the sessions |
| `ffi=ssl`, `ffi=crypto` | OpenSSL, for https |
| `env=` its 7 settings | the database's address and the two tokens, the port, the host, the certificate and its key |
| `read=/etc/invoices` | the certificate and its key |
| `net=0.0.0.0:8443` | listening on port 8443 of every address; nothing else of the network |

It writes no file, and reads none but the two of its certificate. Tried on this machine with a certificate of its own:

```sh
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout app.key -out app.pem -days 30 -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
APP_PORT=8443 APP_CERT=$PWD/app.pem APP_KEY=$PWD/app.key cesia run --allow native=cepheus,ffi=sodium,ffi=ssl,ffi=crypto,env,read=$PWD,net=:8443 ~/invoices/src/main.ce &
curl -s --cacert app.pem -D - -o /dev/null https://127.0.0.1:8443/login | grep -i "HTTP\|strict"
curl -s --cacert app.pem -D - -o /dev/null -H "Origin: https://127.0.0.1:8443" -d "login=ada&password=correct+horse+battery" https://127.0.0.1:8443/login | grep -i set-cookie
```

```text
HTTP/1.1 200 OK
strict-transport-security: max-age=31536000
set-cookie: sid=…; Path=/; Max-Age=28800; HttpOnly; SameSite=Strict; Secure
```

A service, `/etc/systemd/system/invoices.service`, with its settings in `/etc/invoices/env`, readable by root only
(systemd reads it before it gives up its rights):

```ini
[Unit]
Description=Invoices, the app
After=cepheus.service
Requires=cepheus.service

[Service]
Type=simple
User=invoices
Group=invoices
WorkingDirectory=/opt/invoices
EnvironmentFile=/etc/invoices/env
ExecStart=/usr/local/bin/cesia run --allow native=cepheus,ffi=sodium,ffi=ssl,ffi=crypto,env=CEPHEUS_URL,env=CEPHEUS_TOKEN,env=CEPHEUS_BOOKS_TOKEN,env=APP_PORT,env=APP_HOST,env=APP_CERT,env=APP_KEY,read=/etc/invoices,net=0.0.0.0:8443 src/main.ce
Restart=on-failure
TimeoutStopSec=70
MemoryMax=1G
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/invoices/env, mode 0600
CEPHEUS_URL=cepheus://localhost:7400/invoices
CEPHEUS_TOKEN=cph_...
CEPHEUS_BOOKS_TOKEN=cph_...
APP_HOST=0.0.0.0
APP_PORT=8443
APP_CERT=/etc/invoices/fullchain.pem
APP_KEY=/etc/invoices/privkey.pem
```

`ExecStart` runs the `cesia run` line that `cesia do serve-tls` prints, rather than `cesia do`: on a stop, systemd
sends TERM to every process of the service, so with `cesia do` in front the program would hear it twice, from systemd
and from `cesia do` passing it on, and a second stop signal ends a Cesia program at once instead of letting its
requests end. Run as a service of this user, the same line stops cleanly:

```sh
systemd-run --user --unit=invoices-guide -p EnvironmentFile=$HOME/invoices-env -p WorkingDirectory=$HOME/invoices -p MemoryMax=1G -p NoNewPrivileges=true -p TimeoutStopSec=70 $(command -v cesia) run --allow native=cepheus,ffi=sodium,env=CEPHEUS_URL,env=CEPHEUS_TOKEN,env=CEPHEUS_BOOKS_TOKEN,env=APP_PORT,env=APP_HOST,env=APP_CERT,env=APP_KEY,net=:8090 src/main.ce
systemctl --user stop invoices-guide
journalctl --user -u invoices-guide -o cat -n 2
```

```text
Stopping [systemd-run] /home/you/cesia/_build/default/src/bin/main.exe run --allow native=cepheus,...
Stopped [systemd-run] /home/you/cesia/_build/default/src/bin/main.exe run --allow native=cepheus,...
```

(With `cesia do` instead, the same stop gave `status=143`: the second signal.)

**On every core.** The app holds no state of its own: sessions are in the database, so `cesia run --workers 4` runs
four processes behind one port ([every core](https://github.com/www-celestial/cesia/blob/main/docs/book/http.md#every-core)).
Each one connects to Cepheus and keeps its own copy of the database's pages for its local reads (each reader holds
its cache: [what it costs](server.md#what-it-costs)), and each one runs the minute's late check, which their `Expect`s
keep from applying twice.

**Backups**: `cepheus-backup` of the [production guide](production.md#backups), while the server runs, then the
restore drill on another server (here the live one stopped first, since a copy of a database is refused on the
machine that runs it):

```sh
cepheus-backup ~/invoices-db/data ~/backup
cepheus cluster init drill --dir ~/drill
mkdir ~/drill/data && cp -R ~/backup/2026-11-13T015551/invoices ~/drill/data/invoices
sed -i 's/127.0.0.1:7400/127.0.0.1:7500/; s/^name = "main"/name = "invoices"/' ~/drill/cluster.toml
(umask 077; cepheus token add ops --admin --config ~/drill/cluster.toml > ~/drill/ops.token)
cepheus stop --config ~/invoices-db/cluster.toml
cepheus serve --config ~/drill/cluster.toml &
CEPHEUS_TOKEN=$(cat ~/drill/ops.token) cepheus status --config ~/drill/cluster.toml | grep 'database.invoices.g'
```

```text
/home/you/backup/2026-11-13T015551
stopped (process 3856310, 623 ms)
cepheus: ready in 1.6 ms: invoices at group 10; socket /home/you/drill/run/.s.cepheus.7500, tcp 127.0.0.1:7500; 4 I/O domains, at most 512 connections; server cph-s-f2c75fe637984d7b, cluster cph-c-861cce4c5bec08f9
database.invoices.group: 10
```

The copy opens at the group the live server held (`cepheus status` with the ops token showed
`database.invoices.group: 10` before the copy). The app, connected meanwhile, went on through the restart of its
server: the client connects again by itself, and its reads went to the server until it followed the database again.

**What to watch**: the app writes a line of JSON for each request (`http.Logger`: its method, path, status and
milliseconds; never a query, a cookie or a body), `request failed` with the code and message of an error the server
caused, `sign-in refused` without the login typed (a password typed in the login field would otherwise be in the
log), and `keeping failed` if the minute's late check fails; the server, what the [production
guide](production.md#what-to-watch) says.

## 14. What it costs

Measured on one machine (Intel Core i7-4720HQ, 4 cores and 8 threads, 11 GB, a SATA SSD, Linux), Cepheus and Cesia
in release builds, on the seed (10,000 clients, 100,000 invoices, 300,000 lines: 30 MB of data), the app in one
process, the load from the same machine, every part alone on the machine (under a lock that keeps the machine's other
benchmarks out). Each number is the median of 21 rounds, with its distribution-free 95 % interval (the order
statistics $[x_{(6)}, x_{(16)}]$ of the rounds); a round's p50 and p99 are the latencies that half and 99 in 100 of
its requests did not pass. The scripts: `bench/run.sh` (the seed, the start-ups, the pages through ApacheBench, each
request on a connection of its own), `bench/actions.sh` (the forms, through `bench/load`), `bench/live.sh` (the
dashboard in Firefox), `bench/giants/giants.sh` (beside PostgreSQL), `bench/stats` (the medians).

**Starting.** The seed in an empty database: 4.84 s [4.60, 4.94] for 2.4 million facts, most of it the Cesia
side, which makes the groups' 2.4 million operations (a map each). The Cepheus server's start on the seeded database: 30.9 ms [30.2, 31.7]. The app's
process, from its command to its port accepting a connection: 81.6 ms [80.0, 82.2], of which its log line's `Ms`
(its two connections, the rules, libsodium) is 44 to 54 ms, and the rest Cesia's start, the reading of the app's
code and the engine's first load (13 ms, [what it costs](cesia.md#what-it-costs)).

**The pages**, ms, with 1 client, then 50 at once:

| page | 1 client: p50 | p99 | 50 clients: p50 | p99 | requests a second at 50 |
|---|---:|---:|---:|---:|---:|
| the floor: `/app.css`, a constant | 0.13 [0.12, 0.13] | 0.21 | 2.48 | 4.50 | 19,083 |
| the sign-in page | 0.13 [0.12, 0.14] | 0.32 | 2.78 | 4.41 | 17,568 |
| the dashboard (its HTML; its numbers come live) | 0.21 [0.20, 0.22] | 0.45 | 7.96 | 11.9 | 6,349 |
| invoices, the first page | 0.97 [0.96, 0.99] | 1.70 | 52.4 | 76.0 | 1,059 |
| invoices, a page 50,000 deep | 1.07 [1.06, 1.11] | 1.93 | 58.8 | 84.2 | 963 |
| invoices, unpaid or late (`In`) | 1.33 [1.32, 1.35] | 2.26 | 74.6 | 112 | 753 |
| invoices, late or due in a week (`Or`) | 1.71 [1.70, 1.89] | 2.88 | 94.7 | 132 | 594 |
| invoices, as the accountant (read at the server) | 1.48 [1.44, 1.50] | 2.20 | 41.0 | 72.4 | 1,174 |
| an invoice and its lines | 0.30 [0.30, 0.31] | 0.56 | 12.9 | 18.9 | 4,158 |
| the form of a new invoice | 0.27 [0.26, 0.28] | 0.49 | 11.5 | 16.8 | 4,721 |
| a client, what it owes, its invoices not paid | 0.59 [0.58, 0.61] | 1.00 | 29.0 | 43.2 | 1,902 |
| clients, the first page by name | 13.2 [13.1, 13.5] | 24.7 | 737 | 1,059 | 75 |
| clients, the search as one types ("ma") | 1.19 [1.18, 1.33] | 2.03 | 63.4 | 101 | 870 |
| the CSV of the late invoices (11,006 rows) | 114 [112, 131] | | 5,740 | | 8.5 |

- With 50 clients at once, the app's one process serves them one after another: the latency is about 50 times a
  request's work, and the requests a second say what one core gives. `cesia run --workers 4` serves the same port
  from 4 processes ([every core](https://github.com/www-celestial/cesia/blob/main/docs/book/http.md#every-core)).
- The accountant's list costs 0.5 ms more alone, a round trip to the server through its socket (its token reads
  there, not in the app's memory), and serves more at 50, since the server's domains do the reading beside the app's
  core.
- The list of clients by name is the slow page: a sort on a text reads every client (10,000) before it keeps the
  first 20, where a sort on a number reads the index in its order. The search as one types reads only the clients it
  finds.
- The CSV is mostly Cesia's: the question is a few ms; formatting 11,000 rows and their dates is the rest.

**The actions**, ms, through the forms (`bench/load`: Cesia's HTTP client, a connection a request, which costs
about 0.35 ms a request more than ApacheBench), each answered once its group is on the server's disk:

| action | 1 client: p50 | p99 | 50 clients: p50 | p99 | a second at 50 |
|---|---:|---:|---:|---:|---:|
| a client made | 3.82 [3.63, 4.40] | 16.2 | 20.0 [17.6, 23.2] | 33.6 | 1,996 |
| an invoice paid | 3.76 [3.58, 4.25] | 11.2 | 21.3 [18.6, 23.6] | 29.7 | 2,117 |
| an invoice made, with two lines | 7.50 [5.80, 9.81] | 26.3 | 268 [251, 318] | 415 | 161 |
| a sign-in | 70.2 [65.8, 75.5] | 84.6 | 3,062 [2,989, 3,253] | 3,092 | 16 |

- 50 writes at once share the server's fsyncs (group commit, [the server](server.md)): 2,000 a second, against 240
  one after the other.
- An invoice is numbered one at a time in the process (step 5), so 50 at once wait for each other's fsync: 161 a
  second. (Before that, 2,905 of 4,200 failed after five tries at a number: each of 50 read the same largest one.)
- A sign-in is Argon2id, about 65 ms of the app's one thread, on purpose (the cost of guessing a password); 50 at
  once take 3 s, and the requests of that process wait meanwhile.

**The live dashboard**: from a payment's answer (the group durable) to the page's unpaid total changed in Firefox
(`performance.now()` on the page, the same clock as the program's), 10 payments a round, one after the other:

| pages open | p50 | p99 |
|---:|---:|---:|
| 1 | 0.45 ms [0.32, 0.50] | 2.32 ms [1.80, 6.40] |
| 10 | 1.25 ms [1.12, 1.39] | 4.19 ms [3.92, 4.95] |

The change usually reaches the page within a millisecond of the writer's answer: the app's process computed it from
the group while the server forced it to the disk, and gave it once durable ([what a change costs](cesia.md#what-it-costs)).

**Beside the giants: the database's part alone.** The same seed in PostgreSQL 18.6 (`bench/giants/load.sql`: the same
draws, the indexes the pages need, durable commits as by default), the same questions through `pgbench -M prepared`
(its C client, one connection, through its Unix socket); on Cepheus, the app's own functions, its reads in its own
memory. µs, one client:

| question | Cepheus p50 | p99 | PostgreSQL p50 | p99 |
|---|---:|---:|---:|---:|
| a page of invoices (20 rows of 7 fields) | 375 [369, 377] | 565 | **43** [42, 49] | 86 |
| a page 50,000 deep | 389 [387, 392] | 583 | **47** [45, 54] | 87 |
| invoices by a prefix of the bill-to name | 1,781 [1,773, 1,792] | 2,391 | **163** [161, 167] | 232 |
| clients by name | 12,758 [12,622, 12,997] | 17,516 | **37** [36, 45] | 76 |
| clients by a prefix of the name or of the e-mail (`Or`) | **850** [834, 855] | 1,184 | 1,328 [1,325, 1,329] | 2,063 |
| the total not paid (`Not`, `Sum`, `Count`) | 55,987 [55,594, 56,526] | 251,290 | **10,792** [10,661, 10,874] | 15,555 |
| an invoice and its lines | **25** [25, 26] | 50 | 48 [48, 48] | 99 |
| a durable update of one invoice | **2,704** [2,594, 2,904] | 5,191 | 2,989 [2,965, 3,038] | 7,541 |

Where PostgreSQL wins, and why:

- **A sorted page**: 8 to 9 times faster. Its B-tree on the number gives the 20 rows in order, each row one read of
  its table; Cepheus keeps a fact a property (the entity–attribute–value model), so a row of 7 fields is 7 reads of
  indexes, and its page in the index's order is asked as windows of the number's values. Both are under half a
  millisecond, but this is the order of the gap.
- **A sort on a text**: 345 times. PostgreSQL reads its index on the name in order; Cepheus has no order of an index
  for a text key, and sorts every client.
- **A sum over a filter**: 5 times. PostgreSQL scans its table; Cepheus answers the `Not` for each of the 100,000
  invoices. On the dashboard this is paid once per question (the watch's first answer, shared by every page), then
  each change costs its difference.

Where Cepheus wins: an invoice with its lines is read in the app's own memory with no round trip (25 µs against 48);
the search on either of two prefixes (`Or` of two `Prefix`) is 1.6 times faster than PostgreSQL's two `LIKE`s; a
durable write costs the same (both wait for one fsync of the disk). And every number of the PostgreSQL column still
needs a program around it that would watch the changes (`LISTEN`/`NOTIFY`, written by hand) to give a live dashboard.

## 15. Security

What the app defends against, how, and the test that shows it:

| threat | defence | test |
|---|---|---|
| a guessed or stolen password | Argon2id (libsodium), 12 to 128 bytes; the same answer and the same time for an unknown login | `isSignedIn` |
| a stolen database copy | passwords as Argon2id hashes, sessions as BLAKE2b hashes of their secret | (by construction) |
| a stolen session cookie | `HttpOnly`, `SameSite=Strict`, 8 hours, `Secure` over https; sign-out retracts the session | `isSignedIn` |
| cross-site request forgery | the same-origin check on every request that changes something; `SameSite=Strict` | `isOtherOriginRefused`, both levels |
| a page that shows what it should not | the role checked by every route; the accountant's token reads invoices and lines only | `isAccountantSeesInvoicesOnly`, `isAccountantSeesNoClient` (denied by the database) |
| cross-site scripting | every value escaped; a Content-Security-Policy that allows the app's own script only; values drawn with `textContent` in the page | `isClientMadeAndEscaped` |
| CSV injection | a `'` before a cell that a spreadsheet would run | `isCsvOfTheFilter` |
| input that breaks a check or the memory | every field bounded and checked before use; bodies of 64 KiB at most; cursors of 2 KB, their types checked | `isClientChecked`, `isInvoiceChecked`, `isBadCursorRefused` |
| two requests at once | `Expect` on the status (paid once), `unique` on the number and the e-mail, the constraint on deleted clients | `isPaidOnce`, `isDeleteChecked`, `isEmailUnique` |
| a secret in the logs | the log holds no query, cookie, body, token, or login typed | (by reading `web.ce`) |
| the app's own rights | the permissions of step 13, no file written | (the task's `allow`) |

What is not defended here: sign-ins are not limited by client, since the request a Cesia handler gets carries no
address of its client; and a sign-in costs about 65 ms of Argon2id on the app's one thread, which no other request
of that process passes meanwhile: 50 sign-ins at once take 3 s, and so would any page asked during them (the
actions above). A flood of sign-ins is a denial of service until the hash runs beside the requests.

## What is not built yet

- A watch with an order and a limit (the latest ten payments): the dashboard watches a window of time and the page
  sorts it.
- An index order for a sort on a text (the clients by name read every client), and the bulk path for a load into a
  database with a constraint or a rule whose head is a one-valued property (the seed defines the rules after the
  load).
- A counter that a group itself increments: invoice numbers without a gap are made one at a time in a process.
- Argon2id beside the requests: a sign-in holds the app's thread for its 65 ms.
