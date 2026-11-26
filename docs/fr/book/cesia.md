# Cepheus depuis Cesia

Ce chapitre est pour les programmeurs qui écrivent en [Cesia](https://github.com/www-celestial/cesia-lang) : comment un
programme Cesia atteint une base Cepheus, y écrit, la lit et lui pose des questions, ce que donne chaque appel, ce qu'il
coûte, et ce qu'il garantit. Les exemples ci-dessous tournent tels qu'ils sont écrits, contre un vrai serveur, à
chaque passage des tests (`test/cesia.sh`) : ce qui suit chacun est ce qu'il a affiché.

Un programme Cesia atteint une base comme un programme atteint PostgreSQL : par un serveur, `cepheus serve`
([serveur](server.md)). Il y a une seule façon : `cepheus.Connect`. Sur la machine du serveur, le même appel lit dans la
propre mémoire du programme ; ailleurs, il va au serveur par TLS. Le code du programme est le même aux deux endroits.

## Le package

Le client est un **package natif** de Cesia (un package : du code groupé sous un nom) : du code Cesia
(`cesia/cepheus/cepheus.ce`, les fonctions documentées ci-dessous) au-dessus d'un **moteur**, de l'OCaml compilé en
code machine (`cesia/native/`) : le propre lecteur de Cepheus, son moteur de questions (Generic Join) et son client du
protocole, dans un seul fichier que Cesia charge au premier appel du package. Un package natif est la façon dont Cesia
fait tourner de l'OCaml qui vient d'un autre projet : le moteur est compilé une fois contre l'interface native de
Cesia, `Cesia_v1`, dont la définition ne change jamais une fois publiée, si bien que le même fichier se charge dans
chaque Cesia ultérieur construit avec le même OCaml (le livre de Cesia, chapitre « Native packages »).

Un programme prend le package comme dépendance et le nomme dans son `use` :

```toml
# cesia.toml of the program
[deps.cepheus]
from = "github.com/www-celestial/cepheus"
version = "v0.1.0"
take = ["cesia/cepheus"]
```

```text
use deps/www-celestial/cepheus/cesia/cepheus
```

Le moteur est le fichier `native/cepheus-TAG.cmxs` du package, où `TAG` est ce que donne `cesia.Native()`, comme
`1-ocaml5.5.0-linux-x86_64` : la version de l'interface native, l'OCaml qui a construit ce Cesia, et le système.
Comme chaque fichier de `deps/`, il ne se charge que tel que `cesia.lock` dit qu'il a été installé (son empreinte
BLAKE2).

**La permission.** Un moteur est du code machine qui tourne avec les droits du programme : les permissions de Cesia
s'arrêtent à sa porte ; le faire tourner demande donc la confiance `native=cepheus` (le label de la dépendance), comme
une bibliothèque C demande `ffi=` :

```text
cesia run --allow native=cepheus,env shop.ce
```

`env` est pour `sys.Env`, dont se servent les exemples pour lire l'adresse et le token (la suite d'octets secrète qu'un
programme présente pour prouver ses droits). Le package demande à Cesia la permission de lire le fichier de certificat
qu'on lui donne (`ca`) ; il ne peut pas demander `net=`, que l'interface native de Cesia n'offre pas : avec
`native=cepheus`, le programme peut atteindre n'importe quel serveur.

**Démarrage.** Rien du moteur ne se charge avant le premier appel du package : un programme qui utilise le package ne
paie à son démarrage que la lecture du code Cesia du package, comme pour tout package, et le démarrage de Cesia lui-même
ne change pas ([mesuré](#ce-que-cela-coûte)). Le premier appel charge le moteur : la vérification de son empreinte,
l'édition de liens dynamique du moteur et des bibliothèques d'OpenSSL, une fois par processus.

## Connect

```cesia norun
use deps/www-celestial/cepheus/cesia/cepheus
use std/date
use std/fiber
use std/io
use std/result
use std/sys

Client = cepheus.Kind("client", {Name: cepheus.Text(), City: cepheus.Text(), Email: cepheus.Text(unique = true)})
Invoice = cepheus.Kind("invoice", {Client: cepheus.Link(), Total: cepheus.Money(2), Status: cepheus.Text()})

db = result.Unwrap(cepheus.Connect(sys.Env("CEPHEUS_URL"), [Client, Invoice], token = sys.Env("CEPHEUS_TOKEN")))
io.Print(cepheus.Get(Client, 1, db))
```

```text
Ok(missing)
```

`cepheus.Connect(url, kinds, token = missing, ca = missing)` donne un `Ok` de la base, à passer à chaque autre appel, ou
un `Err`. Ici le programme lit l'adresse dans `CEPHEUS_URL`, comme le fait un programme configuré par son
environnement ; écrite en entier, elle est :

```text
cepheus://srv1:7400/shop                     the database shop of the server srv1, port 7400 (the default)
cepheus://localhost:7400/shop?socket=DIR     the Unix socket in DIR instead of /run/cepheus
```

Ce que fait `Connect`, dans l'ordre :

1. **Local ou distant.** Un **Unix-domain socket** est un canal entre deux programmes d'une même machine, nommé par un
   chemin : il ne peut pas traverser les machines, donc un programme qui atteint le serveur par l'un d'eux est sur la
   machine du serveur. Si l'URL nomme un dossier de socket (`?socket=`), le package se connecte par
   `DIR/.s.cepheus.PORT` ; sinon, si `/run/cepheus/.s.cepheus.PORT` existe et que l'hôte est une adresse de cette
   machine (le package le vérifie en y attachant un socket UDP, ce que seule une adresse locale permet), par celui-là ;
   sinon par TCP avec **TLS 1.3**, le chiffrement de la connexion, qui demande `ca`, le fichier de la certificate
   authority du cluster (l'autorité qui signe ses certificats), pour vérifier que le serveur est bien celui du cluster
   (`cepheus cluster init` le crée).
2. **Le token.** Le programme montre son token, un secret créé par `cepheus token add NAME --database shop=write` ; le
   serveur répond avec les droits de ce token sur chaque base : `read` ou `write` (G16).
3. **Les kinds.** Les propriétés des kinds que donne le programme et qui manquent à la base sont déclarées en un seul
   groupe ; une propriété déjà déclarée avec un autre type est un `Err` de Code `"invalid"`.
4. **Les lectures locales.** Sur la machine du serveur, le package **suit** ensuite la base : le serveur lui passe les
   fichiers de la base, déjà ouverts, puis chaque groupe qu'il écrit, qu'un domain du package (une unité de
   parallélisme d'OCaml, un thread système à lui) applique à un état dans la mémoire du programme. À partir de là, `Get`
   et `Find` lisent cet état, sans round trip (l'aller-retour d'une requête et de sa réponse) jusqu'au serveur
   ([lectures locales](#lectures-locales)).

`Connect` attend dans sa propre fiber : son travail au serveur (le handshake, la poignée de main qui ouvre la
connexion ; les déclarations, qui sont une écriture ; et les Opens) tourne sur un domain du package pendant que les
autres fibers du programme tournent. Un pair qui prend la connexion et ne répond pas (un serveur bloqué, un autre
programme sur le port) est abandonné après 5 s pour le handshake (connexion, TLS, Hello), avec un `Err` de Code
`"unreachable"` ([limites](limits.md#le-serveur)).

Une seule connexion sert toutes les fibers du programme (une **fiber** est l'un des threads légers de Cesia : beaucoup
tournent sur un seul cœur, chacune attendant sans retenir les autres) : voir
[beaucoup de fibers, une seule connexion](#beaucoup-de-fibers-une-seule-connexion).
`cepheus.Close(db)` la termine ; tout appel sur elle ensuite donne un `Err` de Code `"closed"`.

## Les kinds, et les valeurs qu'ils tiennent

Cepheus garde des **faits** : un fait est un triplet *(chose, propriété, valeur)*, « la facture 70021 a le statut
impayé ». Une **chose** est un numéro, son identifiant ; une **propriété** a un nom, un type, et dit si une chose peut
en avoir plusieurs valeurs (`many`) et si deux choses peuvent partager une valeur (`unique`). C'est le modèle
entity–attribute–value ([concepts](concepts.md)).

Un **kind** regroupe sous des noms de champs les propriétés d'une sorte de chose. `cepheus.Kind(name, fields)` en
déclare un : un nom fait de lettres minuscules, de chiffres, de `_` et de `-`, et une map de champs, chacun un type. Sa
propriété dans la base est le nom du kind, une barre oblique et celui du champ : `client/City`. La valeur qu'il donne est
une map de ses champs, chacun une propriété à nommer dans les questions et dans `Write` (`Client.City`), et le champ
`kind`, que le package garde pour lui :

| Type | Les valeurs de la propriété | En Cesia | Exemple |
|---|---|---|---|
| `cepheus.Text()` | un texte UTF-8 | un Text | `"Lyon"` |
| `cepheus.Int()` | un nombre entier de 63 bits | un Int | `42` |
| `cepheus.Float()` | un flottant de 64 bits (IEEE 754) | un Float (un Int est accepté aussi) | `2.5` |
| `cepheus.Bool()` | vrai ou faux | un Bool | `true` |
| `cepheus.Date()` | un instant en UTC, gardé en millisecondes depuis 1970 | un nombre de secondes depuis 1970, comme le donne `sys.Now()`, sous $4{,}6 \times 10^{15}$ dans les deux sens (146 millions d'années : ses millisecondes tiennent dans un Int) ; relu comme un Float | `1794268800.25` |
| `cepheus.Money(scale)` | un décimal exact de `scale` chiffres après la virgule (0 à 18), gardé en unités mineures | un nombre (Int ou Float), arrondi à l'échelle, dont les unités mineures tiennent dans un Int ; relu comme un Float | `1200.5` |
| `cepheus.Link()` | une autre chose de la base | son identifiant, un Int | `65536` |

Chacun prend `unique = false` et `many = false`. Money est exact dans la base (un entier d'unités mineures, donc les
sommes y sont exactes, `Sum` compris) et un Float en Cesia : un montant d'au plus 15 chiffres significatifs, comme
1 234 567 890 123,45, écrit puis relu, donne les mêmes unités mineures (un flottant de 64 bits en est à moins d'une
demi-unité) ; au-delà, ses derniers chiffres s'arrondissent.

`cepheus.Link(to = "client")` est un lien qui **nomme un kind**, la **foreign key** (la clé étrangère) de SQL
(`REFERENCES client`) : la chose vers laquelle il pointe doit être un client, c'est-à-dire avoir un fait du kind client
qu'une écriture lui a donné (une valeur d'un de ses champs ; un fait que seule une règle donne ne fait d'aucune chose un
client), vérifié par le serveur à chaque écriture sur l'état d'après le groupe, si bien qu'un client fait dans le même
groupe compte. `to` prend le nom du kind, un Text, pour qu'un kind puisse pointer vers lui-même (le parent d'une
catégorie, le chef d'un employé) et deux kinds l'un vers l'autre. `onDelete` dit ce que fait le lien quand sa chose
cesse d'être un client : `"refuse"` (par défaut) refuse le groupe qui la laisserait ainsi, `"cascade"` supprime aussi
la chose qui pointe, `"clear"` retire le lien ([supprimer une chose](#supprimer-une-chose)). Un `Link()` sans `to`
prend l'id de n'importe quelle chose, comme avant.

## Insert, Get, Update

```cesia norun
ada = result.Unwrap(cepheus.Insert(Client, {Name: "Ada Martin", City: "Lyon", Email: "ada@example.com"}, db, by = 7, why = "signup"))
io.Print(ada)
io.Print(cepheus.Get(Client, ada, db))
```

```text
65536
Ok({Name: "Ada Martin", City: "Lyon", Email: "ada@example.com"})
```

- `cepheus.Insert(kind, fields, db, by = 0, why = "")` : une nouvelle chose avec ces champs, en un seul **groupe** (une
  écriture de plusieurs faits, tout ou rien, gardée pour toujours dans l'historique avec `by`, le numéro de qui a
  écrit, et `why`) : un `Ok` de son identifiant. Un champ laissé de côté n'a pas de fait ; un champ à valeurs `many`
  prend une liste.
- `cepheus.Get(kind, id, db)` : un `Ok` de la map des champs de ce kind pour la chose, `missing` pour un champ dont elle
  n'a pas de valeur, une liste pour un champ à valeurs `many` (vide quand elle n'en a pas) ; un `Ok` de `missing` quand
  la chose n'a aucun des faits du kind (comme l'a montré le premier exemple).
- `cepheus.Update(kind, id, fields, db, by = 0, why = "")` : de nouvelles valeurs pour ces champs, en un seul groupe,
  chacune remplaçant la valeur du champ (une propriété à une seule valeur en garde une) : un `Ok` du numéro du groupe.
  Un champ à valeurs `many` change avec `Write` (`Add` et `Retract`), pour que ce qu'il ajoute et ce qu'il retire
  soient écrits en toutes lettres.

Comme partout en Cesia, la base vient en dernier : `db then cepheus.Get(Client, ada)` lit la même chose.

```cesia norun
for total in [1200, 80.5]
  result.Unwrap(cepheus.Insert(Invoice, {Client: ada, Total: total, Status: "unpaid"}, db))
end
bo = result.Unwrap(cepheus.Insert(Client, {Name: "Bo Lind", City: "Paris", Email: "bo@example.com"}, db))
result.Unwrap(cepheus.Insert(Invoice, {Client: bo, Total: 10, Status: "paid"}, db))
io.Print(cepheus.Update(Client, bo, {City: "Lyon"}, db))
io.Print(cepheus.Get(Client, bo, db))
io.Print(cepheus.Insert(Client, {Name: "Eve", Email: "ada@example.com"}, db))
```

```text
Ok(8)
Ok({Name: "Bo Lind", City: "Lyon", Email: "bo@example.com"})
Err({Kind: "cepheus", Code: "unique", Message: "client/Email \"ada@example.com\" is taken"})
```

## Write : des groupes de faits, tout ou rien

`cepheus.Write(ops, db, by = 0, why = "")` écrit un groupe d'opérations, tout ou rien : un `Ok` de `{Group, Things}`,
le numéro du groupe et les identifiants des choses qu'il a créées, ou un `Err` et rien d'écrit.

- `cepheus.Add(thing, property, value)` : le fait ajouté ; sur une propriété à une seule valeur, il remplace l'ancienne.
- `cepheus.Retract(thing, property, value)` : le fait retiré.
- `cepheus.Expect(thing, property, value)` : le groupe est refusé avec le Code `"conflict"` sauf si le fait tient avant
  lui ; `cepheus.Expect(thing, property)`, sauf si la chose n'a aucune valeur de la propriété. C'est ainsi qu'un
  programme écrit « seulement si personne ne l'a changé depuis que je l'ai lu », une vérification **optimiste** : rien
  n'est verrouillé par un lock ; le groupe qui arrive en second est refusé, et le programme relit.
- `cepheus.Incr(thing, property, by = 1, into = missing)` : un **compteur** que le groupe incrémente. La valeur de la
  chose pour une propriété `Int()` à une seule valeur (pas de valeur compte pour 0) augmente de `by` (un `by` négatif
  compte à rebours), lue par la base à ce point du groupe. `into = [thing, property]` y ajoute aussi la nouvelle
  valeur, une propriété `Int()` : une facture reçoit son numéro dans le groupe qui la crée. Une valeur au-delà des 63
  bits d'un Int refuse le groupe, Code `"invalid"`.
- `cepheus.New(k)` : la k-ième nouvelle chose du groupe, à toute place où va une chose : `New(1)`, `New(2)`...
  `Things[k]` est son identifiant.

```cesia norun
first = cepheus.Find(1, (i) -> {Where: [[i, Invoice.Total, 1200]], Give: {Invoice: i}}, db)
inv = result.Unwrap(first)[1].Invoice
pay = [cepheus.Expect(inv, Invoice.Status, "unpaid"), cepheus.Add(inv, Invoice.Status, "paid")]
io.Print(cepheus.Write(pay, db, by = 7, why = "paid by card"))
io.Print(cepheus.Write(pay, db, by = 7, why = "paid by card"))
io.Print(cepheus.Write([cepheus.Add(cepheus.New(1), Client.Name, "Cy"), cepheus.Add(cepheus.New(2), Invoice.Client, cepheus.New(1))], db))
```

```text
Ok({Group: 9, Things: []})
Err({Kind: "cepheus", Code: "conflict", Message: "#65537 does not have \"unpaid\" for invoice/Status (property 21)"})
Ok({Group: 10, Things: [65541, 65542]})
```

Le second paiement est refusé : le premier a rendu la facture payée. Chaque groupe est une **transaction** qui voit la
base telle qu'elle était après le groupe d'avant, et les groupes d'une base sont appliqués l'un après l'autre : ils
sont **serializable** (leur résultat est celui d'une exécution un par un), et plus encore, **strictly serializable** :
un groupe qui commence après qu'un autre a été confirmé vient après lui
([garanties](guarantees.md#g4-strict-serializability)).

Des numéros qui se suivent sans trou, comme la loi de beaucoup de pays le demande pour les factures, sont un compteur
que le groupe incrémente lui-même. Lire le plus grand numéro et écrire ce numéro plus un ne suffirait pas : deux
programmes qui lisent en même temps prennent le même numéro, et l'un d'eux doit réessayer. Avec `Incr`, la base lit le
compteur quand elle applique le groupe ; des groupes qui comptent en même temps ne sont donc jamais en conflit et ne
sautent jamais un numéro, et un groupe refusé n'en prend aucun :

```cesia norun
Counter = cepheus.Kind("counter", {Last: cepheus.Int()})
Bill = cepheus.Kind("bill", {Number: cepheus.Int(unique = true), Client: cepheus.Link()})
db = result.Unwrap(cepheus.Connect(sys.Env("CEPHEUS_URL"), [Client, Invoice, Counter, Bill], token = sys.Env("CEPHEUS_TOKEN")))
counter = result.Unwrap(cepheus.Insert(Counter, {Last: 0}, db))
bill = [cepheus.Incr(counter, Counter.Last, into = [cepheus.New(1), Bill.Number]), cepheus.Add(cepheus.New(1), Bill.Client, bo)]
first = result.Unwrap(cepheus.Write(bill, db)).Things[1]
second = result.Unwrap(cepheus.Write(bill, db)).Things[1]
io.Print(cepheus.Get(Bill, first, db), cepheus.Get(Bill, second, db))
refused = cepheus.Write([cepheus.Expect(bo, Client.City, "Rome"), cepheus.Incr(counter, Counter.Last, into = [cepheus.New(1), Bill.Number])], db)
io.Print(refused.Error.Code, cepheus.Get(Counter, counter, db))
```

```text
Ok({Number: 1, Client: 65539}) Ok({Number: 2, Client: 65539})
conflict Ok({Last: 2})
```

`Incr` est une opération du groupe, comme `Add` : les autres faits de la facture, ses lignes, sont dans le même
groupe, tout ou rien.

Une écriture par le réseau reçoit sa réponse une fois son groupe sur le disque du serveur (un fsync, l'appel système
qui attend que les octets soient vraiment sur le disque, G1) ; les écritures qui arrivent pendant que le disque
travaille partagent le suivant (le **group commit**). Si la connexion casse avant la réponse, le package se reconnecte
et envoie l'écriture à nouveau avec son numéro dans la **session** du programme : le serveur répond à une écriture
qu'il a déjà appliquée par sa première réponse ; elle est donc appliquée **une fois** (G14). Après 30 secondes sans
serveur, chaque appel en attente donne un `Err` de Code `"unreachable"`, et une écriture en cours a alors été
appliquée une fois ou pas du tout, la réponse honnête de toute base de données en réseau.

## Find : les questions

Une question est une fonction Cesia : ses paramètres sont les **variables**, et elle donne `{Where, Give}`. `Where` est
une liste de **patterns** `[thing, property, value]` (un pattern : un triplet de la question), chacun un fait qui doit
tenir, où la chose et la valeur peuvent être des variables ou des constantes (la propriété est toujours un champ d'un
kind) ; `Give` est une map de ce qu'il faut donner, chacun une variable ou un agrégat. `cepheus.Find(n, question, db)`
donne un `Ok` d'une liste de maps, une par réponse.

```cesia norun
unpaid = cepheus.Find(3, (c, i, total) -> {
  Where: [[c, Client.City, "Lyon"], [i, Invoice.Client, c], [i, Invoice.Status, "unpaid"], [i, Invoice.Total, total]],
  Give: {Invoice: i, Total: total},
}, db)
io.Print(unpaid)
```

```text
Ok([{Invoice: 65538, Total: 80.5}])
```

`n` est le nombre de variables de la question (ici 3 : `c`, `i` et `total`). Cesia ne laisse pas un package demander à
une fonction combien de paramètres elle a ; le programme le dit donc.

**Comment on y répond.** La question est jointe variable par variable, pas pattern par pattern (**Generic Join**, Ngo,
Ré et Rudra 2013) : pour chaque variable, le pattern qui lui donne le moins de candidats (des comptes exacts lus dans
les index) les donne, et chaque autre pattern de cette variable vérifie chacun par une recherche. Son travail ne dépasse
jamais la plus grande réponse que les patterns pourraient avoir (l'**AGM bound**, la borne AGM), là où un plan de
joins deux à deux, comme en fait une base SQL, peut faire bien plus sur un graphe
([théorie](theory.md#4-generic-join)). Chaque réponse vient une fois : les réponses sont un ensemble (G11).

**Conditions.** `cepheus.Above(x, v)` ($x > v$), `cepheus.Below(x, v)` ($x < v$) et `cepheus.Between(x, lo, hi)`
($\mathit{lo} \le x \le \mathit{hi}$), pour une variable d'un Int, d'une Date ou de Money, lisent l'index trié : ce sont des intervalles de la
question, pas des filtres après elle. Sur une chose, ils prennent son id, un Int (`Above(c, bo)` : les clients faits
après Bo), et lisent les choses de la propriété de son pattern à partir de la première de l'intervalle, dans l'ordre de
leurs ids. Sur un Float, ils gardent les valeurs de leur côté dans l'ordre que donne `Sort`
(le totalOrder d'IEEE 754 : $-0$ avant $0$, NaN après l'infini), chaque candidat vérifié ([plus bas](#less-lessorequal-et-optional)).
Deux variables se comparent avec `cepheus.Less` et `cepheus.LessOrEqual` (même section). Toute autre condition est à
Cesia, sur les lignes qu'elle donne (`list.Filter`).
Une Date est gardée à la milliseconde et Money à ses chiffres, si bien qu'une borne qui tombe entre deux d'entre
elles (`Above(price, 10.005)` pour des centimes, une heure de `sys.Now()`) garde exactement les valeurs de son côté :
elle est arrondie vers l'intérieur de l'intervalle, 10,005 vers 10,01 pour Above et vers 10,00 pour Below. Une borne
de floats à moins de $2^{-50}$ (en relatif) d'une unité est cette unité, comme l'est un décimal écrit au centime
(10,01 fois 100 vaut `1000.9999999999999` en floats) : `Above(price, 10.01)` laisse 10,01 dehors. `Above(n, v)` avec
le plus grand Int, ou `Below(n, v)` avec le plus petit, ne garde rien.

**Agrégats.** Dans `Give`, `cepheus.Sum(x)`, `cepheus.Min(x)`, `cepheus.Max(x)` et `cepheus.Count()` groupent les
réponses par les autres champs de `Give`, comme le fait le `GROUP BY` de SQL ; `Count()` compte les réponses d'un
groupe. Ils sont calculés là où tourne la question (dans le programme sur la machine du serveur, sinon au serveur), si
bien qu'un total sur 400 000 factures traverse le réseau comme une seule ligne.

```cesia norun
byCity = cepheus.Find(4, (c, i, city, total) -> {
  Where: [[i, Invoice.Client, c], [c, Client.City, city], [i, Invoice.Total, total], cepheus.Above(total, 50)],
  Give: {City: city, Total: cepheus.Sum(total), Invoices: cepheus.Count()},
}, db)
io.Print(byCity)
```

```text
Ok([{City: "Lyon", Total: 1280.5, Invoices: 2}])
```

La facture de 10 est sous 50 : la ville de Bo est maintenant Lyon, et sa seule facture n'est pas comptée. Les
moyennes, les médianes et les quantiles, les dispersions, les listes de valeurs, le compte des valeurs différentes, et
le jour, le mois ou l'année d'une date dans un fuseau horaire sont dans
[les rapports](#les-rapports--avg-countx-values-quantile-variance-stddev-trunc).

**Son temps.** `timeout = secondes` borne une question : au-delà, `Find` est un `Err` de Code `"timeout"`, dont le
message nomme le temps, et le travail s'arrête (en quelques millisecondes : il est regardé tous les 1 024 candidats).
Au serveur, le `question_timeout` du serveur (30 s par défaut, [le serveur](server.md#clustertoml)) est le plus
qu'une question prend : un `timeout` plus court est celui de la question, un plus long ne compte que pour un token
admin. Dans la mémoire du programme (sur la machine du serveur), seul le `timeout` du programme la borne. Une question
que le programme n'attend plus (sa connexion fermée) s'arrête aussi au serveur.

```cesia norun
names = result.Unwrap(cepheus.Fork(cepheus.Empty, [Client]))
result.Unwrap(cepheus.Write([cepheus.Add(cepheus.New(k), Client.Name, "c$k") for k in 1..300], names))
rows = cepheus.Find(6, (a, x, b, y, c, z) -> {
  Where: [[a, Client.Name, x], [b, Client.Name, y], [c, Client.Name, z]],
  Give: {Count: cepheus.Count()},
}, names, timeout = 0.1)
io.Print(rows.Error.Code)
```

```text
timeout
```

Trois patterns qui ne partagent aucune variable sont tous les triplets de noms (un produit cartésien) : 300 noms font
27 millions de réponses, un million $10^{18}$ ; la question finit à son temps au lieu de tenir les cœurs (ici ceux du
programme, sur un fork à lui : [forks](#les-forks)). `cepheus.Watch` prend le même `timeout`, pour sa première
réponse.

## Not, Or et In

Trois conditions de `Where` disent ce qui ne doit pas tenir, ce qui peut tenir de plusieurs façons, et quelles valeurs
une variable peut prendre :

```cesia norun
clear = cepheus.Find(2, (c, i) -> {
  Where: [[c, Client.City, "Lyon"], cepheus.Not([i, Invoice.Client, c], [i, Invoice.Status, "unpaid"])],
  Give: {Client: c},
}, db)
io.Print(clear)
either = cepheus.Find(1, (c) -> {Where: [cepheus.Or([c, Client.Name, "Cy"], [c, Client.Email, "bo@example.com"])], Give: {Client: c}}, db)
io.Print(either)
some = cepheus.Find(2, (i, s) -> {Where: [[i, Invoice.Status, s], cepheus.In(s, ["paid", "late"])], Give: {Invoice: i}}, db)
io.Print(some)
```

```text
Ok([{Client: 65539}])
Ok([{Client: 65541}, {Client: 65539}])
Ok([{Invoice: 65537}, {Invoice: 65540}])
```

- `cepheus.Not(a, b, c, d)` : 1 à 4 patterns et conditions ; le binding (une valeur pour chaque variable de la
  question) est gardé quand aucune valeur des variables propres au Not ne les rend toutes vraies. Une variable est
  propre au Not quand elle n'apparaît à aucune autre place de la question : ici `i`, si bien que la première question
  se lit « les clients de Lyon sans facture qui soit à eux et impayée ». Ses autres variables doivent être liées par
  un pattern de la question.
- `cepheus.Or(a, b, c, d)` : 2 à 4 alternatives, chacune un pattern, une condition, ou un `cepheus.And(...)` de 1 à 4
  d'entre eux ; au moins une tient. Une variable présente dans chaque alternative est liée par le Or (`c` plus haut) ;
  une variable présente dans certaines seulement est propre à chaque alternative (« il en existe une valeur »), et ne
  peut pas être donnée. Chaque réponse vient une fois, même quand plusieurs alternatives tiennent pour elle. `And` ne
  sert qu'à une alternative : `Where` exige déjà tous ses items. Un `Or` d'un seul pattern dont les alternatives ne
  diffèrent que par leur valeur est refusé : c'est `In`.
- `cepheus.In(x, values)` : x est l'une des valeurs, de son type (des ids pour un lien : les factures de ces clients).
  Une valeur que la base ne tient pas n'est pas un candidat ; une liste vide n'a pas de réponse. Il prend jusqu'à
  100 000 valeurs, autant qu'une page a de lignes : les ids d'une page reviennent en une seule question
  ([limites](limits.md#les-questions)).

**Sens exact.** Chaque opérateur lit les faits de la vue à laquelle on répond à la question, y compris les faits que
dérivent les règles : ils sont dans chaque vue, exactement (G17) ; un `Not` lit donc un ensemble complet de faits. (Un
`Not` dans le corps d'une *règle* est la même fonction, [règles](#règles).) `Not` et `Or` ne peuvent pas contenir un
`Not` ou un `Or` : nommez une condition plus profonde avec une règle, comme un fait dérivé.

**Comment on y répond.** `In` est une relation d'une seule colonne pour Generic Join : ses valeurs sont les candidats
de x quand elles sont moins nombreuses que celles de chaque pattern, sinon chaque candidat est vérifié contre elles.
`Not` est un **anti-join** (on ne garde que ce qui ne trouve aucun partenaire) : un binding passe quand une recherche
ne trouve rien (un seul pattern : le fait est-il là, la chose a-t-elle une valeur, la valeur a-t-elle une chose), ou,
pour plusieurs items, quand la question propre au Not, ses autres variables fixées, n'a pas de réponse (demandée
jusqu'à sa première). `Or` est demandé une fois pour chaque alternative, avec les alternatives d'avant comme des
`Not`, si bien que les réponses des alternatives sont disjointes et qu'aucune n'a besoin d'être gardée pour retirer
les copies (sauf celles d'une alternative qui a ses propres variables, qui peut donner un binding une fois pour
chacune de leurs valeurs).

Un `Watch` (une question vivante, tenue à jour, plus bas) garde `Not`, `Or`, `In`, `Prefix`, `Less` et `Optional`, et un changement
n'envoie que les lignes qu'il ajoute ou retire. Le fait d'une frame (un bloc du journal qui porte un ou plusieurs
groupes) ne peut changer que les réponses qui s'accordent avec lui à l'un des patterns de la question, où que soit ce
pattern : pour un pattern qui tient des variables de la question, les réponses avec ces valeurs ; pour un pattern à
l'intérieur d'un `Not` ou d'une alternative dont toutes les variables lui sont propres, les réponses que ses autres
items atteignent à partir du fait (une facture payée : son client). Pour chacun de ces ensembles de valeurs, on répond
de nouveau à la question avec ces valeurs fixées, avant et après la frame, et la différence est le changement. Ainsi
un fait ajouté sous un `Not` retire les lignes qu'il exclut maintenant, un fait retiré peut rendre des lignes, une
alternative est lue avec celles d'avant elle, `In`, `Prefix` et `Less` filtrent les valeurs que donne le fait, et une
valeur ajoutée sous un `Optional` retire la ligne où elle manquait et donne la sienne (une valeur retirée, l'inverse).
Le coût
d'une frame est celui des réponses qu'elle touche, pas celui de toute la question (un fait qu'aucune variable de la
question n'atteint, comme sous un `Not` sur toute une propriété, redemande toute la question).

## Prefix : le début d'un texte

`cepheus.Prefix(x, text)` : le texte x commence par ces octets. Avec Sort et Limit, c'est une recherche pendant qu'on
tape :

```cesia norun
found = cepheus.Find(2, (c, n) -> {Where: [[c, Client.Name, n], cepheus.Prefix(n, "B")], Give: {Client: c, Name: n}, Sort: [n], Limit: 10}, db)
io.Print(found)
```

```text
Ok([{Client: 65539, Name: "Bo Lind"}])
```

- La comparaison porte sur les octets : `"Ad"` correspond à « Ada », pas à « ada » ni à « Ädam ». Une recherche qui
  ignore la casse garde un champ à elle sous la forme qu'elle cherche (le nom en minuscules, écrit avec le nom).
- x est une variable de texte qu'un pattern donne comme sa valeur ; le préfixe a de 1 à 1 024 octets.

**Comment on y répond.** Chaque run (un fichier trié de l'état de la base) tient, pour chaque propriété de texte, ses
textes distincts dans l'ordre de leurs octets (format de run 9, [formats](formats.md#run-dirsnapshotslo-20-digits-hi-20-digitsrun)) :
les textes qui commencent par le préfixe en forment un seul tronçon, trouvé par deux binary searches (des recherches
par moitiés successives) ; avec les quelques textes écrits depuis le dernier merge (la fusion des runs en un seul), ils
sont les candidats de x, comme un `In` d'eux. Le travail est celui des textes qui correspondent et de leurs choses, pas
de chaque texte de la base ; et il ne lit que les textes de la propriété de x.

## Sort, Limit et After : des pages

Trois autres clés de la question trient ses lignes, les coupent, et donnent la page qui suit une ligne :

```cesia norun
page = (after) -> ((i, t) -> {
  Where: [[i, Invoice.Total, t]],
  Give: {Invoice: i, Total: t},
  Sort: [cepheus.Desc(t)],
  Limit: 2,
  After: after,
})
first = result.Unwrap(cepheus.Find(2, page(missing), db))
io.Print(first)
io.Print(cepheus.Find(2, page(first[2]), db))
```

```text
[{Invoice: 65537, Total: 1200.0}, {Invoice: 65538, Total: 80.5}]
Ok([{Invoice: 65540, Total: 10.0}])
```

- `Sort: [key, ...]` : chaque clé est un champ de `Give`, sa variable ou son agrégat (`cepheus.Desc(cepheus.Sum(t))`
  quand `Give` tient `cepheus.Sum(t)`), dans l'ordre croissant, ou `cepheus.Desc(key)` pour les plus grandes valeurs
  d'abord. Les lignes égales sur les clés sont rangées par les autres champs de `Give`, par nom, si bien que deux
  lignes ne sont égales dans l'ordre que lorsqu'elles sont la même ligne. Les valeurs se comparent dans leur type : les
  nombres, les dates et Money comme des nombres ; `false` avant `true` ; les liens par leur id, l'ordre dans lequel
  les choses ont été créées ; les textes par leurs octets (UTF-8 : l'ordre de leurs code points, les numéros des
  caractères dans Unicode, si bien que « Z » vient avant « a » et « é » après « z », pas l'ordre d'une langue) ; les
  floats par le totalOrder d'IEEE 754. Un champ qu'un `Optional` a laissé `missing` vient après toute valeur, dans les
  deux sens, là où PostgreSQL met ses NULL en premier dans un ordre décroissant ([plus bas](#less-lessorequal-et-optional)).
- `Limit: k` : les k premières lignes, et les copies de la k-ième quand `Give` laisse de côté une variable (une page ne
  sépare jamais des lignes identiques). Sans `Sort`, k lignes de la réponse, dans l'ordre du moteur.
- `After: row` : les lignes qui viennent après cette ligne dans l'ordre : la page suivante. Il demande `Sort`, et une
  valeur pour chaque champ de `Give` (ou `missing` pour celui d'un `Optional`) ; la ligne n'a pas besoin d'être encore dans la base.

**La page précédente** est la même question avec chaque clé inversée (`Desc` ajouté ou retiré) et `After` la première
ligne de la page courante ; inversez ses lignes (`list.Reverse`). Il n'y a pas d'offset (« sauter les 4 000
premières ») : une page après une ligne coûte la même chose à n'importe quelle profondeur, là où un offset compte
chaque ligne qu'il saute, et une ligne écrite entre deux pages les décale d'une. Une ligne inchangée aux groupes des
deux pages vient une fois ; une ligne écrite entre elles se montre à sa place, si cette place est après le curseur (la
ligne après laquelle commence la page).

![Deux listes de factures triées par total, la plus grande d'abord. À gauche, la page 1 à son groupe : 300,00, 280,00 et 270,00, la dernière étant le curseur. À droite, l'ordre après une nouvelle facture de 1 000,00 écrite entre les pages, en vert en haut : After le curseur donne 250,00, 240,00 et 220,00 ; OFFSET 3 donne 270,00, 250,00 et 240,00, et montre 270,00 deux fois.](images/pages-after.svg)

**Comment on y répond.** Deux façons donnent les mêmes lignes ([théorie](theory.md#4-generic-join)) :

- par un **heap** (un tas : une structure qui garde à portée les meilleures lignes) : chaque réponse de la question,
  gardée dans un buffer d'environ deux fois k lignes, trié et ramené à ses k premières chaque fois qu'il se remplit :
  le travail de la question elle-même plus $O(N \log k)$ comparaisons, avec $k$ lignes gardées, et k lignes envoyées
  au lieu de $N$ ;
- **dans l'ordre de l'index**, quand la première clé est un int, une date, Money, un lien ou un texte qu'un pattern
  donne comme sa valeur : la question est demandée de nouveau sur des fenêtres des valeurs de cette variable lues dans
  l'index de la propriété, à partir du curseur, la première fenêtre tenant k faits (une liste sans filtre lit sa page
  et rien de plus), chaque suivante au moins deux fois plus que la précédente, jusqu'à ce que k lignes soient
  trouvées : le travail des lignes dont la page a besoin. La fenêtre d'un texte, ce sont les textes suivants dans
  l'ordre de leurs octets, que chaque run sur le disque garde pour sa propriété (l'ordre que lit aussi `Prefix`),
  fusionnés sur les runs et les changements pas encore fusionnés. Son budget est la moitié de l'estimation, par le
  planner (la partie qui choisit comment répondre à une question), du travail du heap, en faits lus, puisqu'un fait lu
  de cette façon coûte environ deux fois une étape du heap ; au-delà, le heap répond, si bien que cette façon ne coûte
  jamais plus d'environ deux fois l'autre (la règle du ski-rental problem, le problème de la location de skis : louer
  jusqu'à ce que la location atteigne le prix, puis acheter). Elle abandonne plus tôt quand les lignes trouvées
  jusque-là disent que la page ne peut pas être remplie dans le budget : même au rendement le plus optimiste qu'elles
  permettent (la borne supérieure à 99 % de la moyenne d'un compte de Poisson,
  [Garwood 1936](references.md#les-joins), par l'approximation de [Wilson 1931](references.md#les-joins)), les lignes
  qui manquent demanderaient plus de faits qu'il n'en reste au budget ; une fenêtre suivante tient au moins les faits
  dont les lignes qui manquent ont besoin à ce rendement. Elle perd quand les lignes que veut la page sont loin dans
  l'ordre : les clients dont le nom commence par « ma », triés par nom, viennent après tous les « A » à « L » ; la
  marche abandonne alors après 2 fenêtres au lieu de 5 (en OCaml, 396 µs contre 657 quand elle allait jusqu'à son
  budget, et 322 pour le heap seul, sur les données de l'application du [guide](app.md#14-ce-que-cela-coûte)) ;
- **dans l'ordre des ids des choses**, quand la première clé est la chose d'un pattern : une liste d'un kind
  par ses ids (`Sort: [c]` sur `[c, Client.Name, n]`), ou les choses d'une valeur d'un champ (les clients d'un tenant,
  c'est-à-dire d'un locataire de la plateforme, `[c, Client.Tenant, t]`), dans les `Above`, `Below` et `Between` de la
  question sur cette chose. Une fenêtre, ce sont les choses suivantes qui tiennent la propriété du pattern (qui tiennent
  sa valeur, quand c'est une constante), lues dans la colonne de la propriété, que chaque run sur le disque garde dans
  l'ordre des ids des choses, à partir du curseur, fusionnées sur les runs et les changements pas encore fusionnés ;
  des patterns que tient la chose, celui qui a le moins de faits. La première fenêtre tient k choses, k + 1 après un
  curseur (la chose du curseur d'abord : ses lignes peuvent venir après lui par les autres champs), les suivantes
  grandissent comme plus haut, dans le même budget : une page des choses d'un kind lit ses k choses et rien de plus, à
  n'importe quelle profondeur et quelle que soit la taille du kind. C'est la keyset query de PostgreSQL (la requête qui
  reprend après la dernière clé lue) sur sa clé primaire, `WHERE id > $1 ORDER BY id LIMIT 50`, sans index à choisir :
  une page de 51 sur 10 000, 100 000 ou 1 000 000 de choses prend 24 à 27 µs, là où le heap lisait tout le kind (2,1
  à 2,8, 8,5 à 11 et 81 à 99 ms), et le moteur de PostgreSQL 36 à 62 µs
  ([les benchmarks](benchmarks.md#les-pages-dun-kind-par-les-ids-de-ses-choses-2026-11-26-de-10-000-à-1-000-000-de-choses)).

Le tri d'une réponse entière (sans `Limit`, ou les lignes qu'une fenêtre lit) de 4 096 lignes ou plus dont les
premières clés sont des ints, des dates, de la money, des links ou des bools ne fait aucune comparaison : la clé de
chaque ligne est faite des mots de ces colonnes l'un après l'autre, chacun compté depuis le plus petit de sa colonne
(depuis le plus grand en ordre décroissant) sur autant de bits que l'écart de la colonne en demande, jusqu'à 62 bits,
et les clés sont triées par un radix sort (un tri par les chiffres de la clé, sans comparaison) de 11 bits par passe
(n déplacements par passe, une passe sautée quand toutes les clés ont le même chiffre à cet endroit :
[Knuth 1998](references.md#les-index-et-la-compression), section 5.2.5, et [Herf 2001](references.md#les-index-et-la-compression)) ;
les lignes dont les clés sont égales, quand la clé ne tenait pas tout l'ordre (un texte ou un float après ces clés,
une colonne coupée à 62 bits), sont triées à nouveau par comparaisons. L'ordre est le même, ligne pour ligne.

`Watch` prend aussi `Sort` et `Limit`, et garde les premières lignes de l'ordre à mesure qu'elles changent
([plus bas](#sort-et-limit-dans-un-watch)) ; il refuse `After`. Une question qui tient `Sort`, `Limit` ou `After` est refusée si elle tient une autre clé que
`Where`, `Give`, `Sort`, `Limit` et `After` : un `After` mal écrit donnerait sinon la première page encore et encore
(une question sans elles est lue comme avant, ses autres clés laissées de côté).

## Less, LessOrEqual et Optional

Deux variables comparées entre elles, des intervalles de floats, et une valeur qu'une chose peut ne pas avoir :

```cesia norun
Loan = cepheus.Kind("loan", {Client: cepheus.Link(), Rate: cepheus.Float(), Due: cepheus.Date(), PaidAt: cepheus.Date()})
(* a fork, so that what this example writes stays out of db *)
loans = result.Unwrap(cepheus.Fork(db, [Loan]))
for l in [{Client: ada, Rate: 2.5, Due: 1794268800, PaidAt: 1794268800}, {Client: bo, Rate: 3.1, Due: 1794268800, PaidAt: 1794441600}, {Client: ada, Rate: 2.99, Due: 1794355200}]
  result.Unwrap(cepheus.Insert(Loan, l, loans))
end
late = cepheus.Find(5, (l, c, n, d, p) -> {
  Where: [[l, Loan.Client, c], [c, Client.Name, n], [l, Loan.Due, d], [l, Loan.PaidAt, p], cepheus.Less(d, p)],
  Give: {Name: n, Due: d, Paid: p},
}, loans)
io.Print(late)
io.Print(cepheus.Find(2, (l, r) -> {Where: [[l, Loan.Rate, r], cepheus.Between(r, 2.5, 3.0)], Give: {Rate: r}, Sort: [r]}, loans))
emails = cepheus.Find(3, (c, n, e) -> {
  Where: [[c, Client.Name, n], cepheus.Optional([c, Client.Email, e])],
  Give: {Name: n, Email: e},
  Sort: [e],
}, db)
io.Print(emails)
```

```text
Ok([{Name: "Bo Lind", Due: 1794268800.0, Paid: 1794441600.0}])
Ok([{Rate: 2.5}, {Rate: 2.99}])
Ok([{Name: "Ada Martin", Email: "ada@example.com"}, {Name: "Bo Lind", Email: "bo@example.com"}, {Name: "Cy", Email: missing}])
```

La première question est « les prêts remboursés après leur échéance » : le premier prêt d'Ada a été payé le jour même,
son second n'est pas encore payé (il n'a pas de `PaidAt`, donc pas de ligne). La dernière est le `LEFT JOIN` de SQL (un
join qui garde chaque ligne du côté gauche, même sans rien en face) : chaque client, avec un e-mail ou sans.

- `cepheus.Less(x, y)` garde $x < y$, `cepheus.LessOrEqual(x, y)` $x \le y$ : deux variables d'un même type, chacune
  donnée par un pattern de la question (ou propres au `Not`, dans un `Not`). Les ints, floats, dates, money, textes et
  links se comparent comme `Sort` les range : les textes par leurs octets, les floats dans le totalOrder d'IEEE 754,
  les links par leur id (l'ordre dans lequel les choses ont été créées) ; un bool, ou deux types, est refusé
  (`invalid`). Il va en haut de `Where`, dans un `Not` et dans une alternative d'`Or`. Une variable contre une
  constante, c'est `Above` ou `Below` ; `Less(x, x)` ne garde rien et `LessOrEqual(x, x)` garde tout.
- `Above`, `Below` et `Between` prennent aussi une variable Float : ses valeurs dans le totalOrder, l'ordre de `Sort`
  ($-0$ avant $0$, donc `Below(r, 0)` garde $-0$ ; NaN après $+\infty$). `Above` et `Below` sont stricts : la borne
  elle-même est dehors.
- `cepheus.Optional([thing, property, v])` : pour chaque réponse du reste de `Where`, une ligne pour chaque valeur
  que la chose a de la propriété, ou une ligne où v est `missing` (absent) quand elle n'en a pas. La chose est une
  variable qu'un pattern de `Where` lie (ou l'id d'une chose) ; v est une variable dans aucun autre élément de la
  question ; `Optional` va en haut de `Where`, pas dans un `Not` ni dans un `Or`. Une propriété à plusieurs valeurs
  (`many`) donne une ligne par valeur, comme un `LEFT JOIN` ; deux `Optional` se multiplient leurs lignes. La map d'une
  ligne tient `missing` pour v, comme `Get` pour un champ sans valeur.
- **missing dans un ordre.** `Sort` met une valeur absente après toute valeur, en ordre croissant comme décroissant
  (PostgreSQL met par défaut ses NULL en dernier en croissant et en premier en décroissant : ici une page des plus
  grands d'abord ne commence jamais par les lignes qui n'ont pas la valeur). `After` prend une ligne dont le champ est
  absent : la page suivante continue parmi ces lignes.
- **missing dans un groupe.** `Count()` compte les lignes, celles où v est absent aussi, et v comme clé de `Give` fait
  un groupe des lignes absentes. `Sum`, `Min` et `Max` de v sont refusés (`invalid`) : donnez ses valeurs, ou comptez
  les lignes.
- La question inverse, « les clients sans e-mail », c'est `cepheus.Not([c, Client.Email, e])` ([Not, Or et
  In](#not-or-et-in)) ; le client d'une facture qui peut ne pas en avoir est une question à partir des factures (le
  lien va de la facture vers son client) : `Optional` lit une propriété d'une chose, pas les choses qui pointent vers
  elle.

**Comment on y répond.** `Less` lie la variable que le join atteint en second à partir de la valeur de la première :
pour les ints, les dates, money et les links, dont l'index garde les valeurs dans l'ordre, les candidats de la seconde
variable sont alors un range de l'index trié, une recherche (seek) jusqu'à la première valeur après l'autre et une
lecture à partir de là, pas un parcours de toutes les valeurs (l'inequality join, la jointure d'inégalité, de
[Khayyat 2015](references.md#les-joins)) ; le mot d'index d'un texte ou d'un float est un numéro du dictionnaire, dans
aucun ordre de valeurs, donc chaque candidat est vérifié (ses octets, son totalOrder). Le planner compte un tiers des
valeurs distinctes de la propriété pour le côté borné, la part que le planner de Selinger donne à un range ouvert
([Selinger 1979](references.md#les-joins)), si bien qu'un pattern lié vient en premier et que l'autre côté est
recherché. Deux grands ensembles que rien d'autre ne joint sont un produit cartésien : $n^2/2$ paires gardées de $n$
valeurs de chaque côté ; une telle question s'arrête à son temps et, au serveur, à son budget de travail
([limites](limits.md#les-questions)), comme tout produit cartésien.
`Optional` est lié en dernier, après le join et ses `Not` : chaque ligne du reste cherche les valeurs de la propriété
de la chose, une recherche dans l'index, comme `Get` lit un champ. C'est l'`OPTIONAL` de SPARQL pour un pattern, dont
[Pérez, Arenas et Gutierrez (2009)](references.md#les-joins) ont fixé le sens. Sa variable n'est dans aucun autre
élément parce que, avec une variable qu'une autre partie C a aussi, « A, puis B s'il peut, puis C » et « A et C, puis
B s'il peut » donnent des lignes différentes (une ligne où B a donné à la variable une valeur que C refuse ensuite est
perdue dans l'une et gardée avec B absent dans l'autre) ; leurs patterns *well-designed* (bien construits) sont ceux
où les deux s'accordent. Les éléments de `Where` n'ont pas d'ordre, donc une telle question n'aurait pas un seul sens :
elle est refusée.

Ce qu'ils coûtent à côté de PostgreSQL, sur les données des benchmarks : [benchmarks](benchmarks.md#less-optional-et-un-compteur-partagé-2026-11-25-à-1-million-de-faits)
(`Optional` coûte ce que coûte le join ; `Less` ce que coûte le filtre des lignes dans le programme).

## Les rapports : Avg, Count(x), Values, Quantile, Variance, Stddev, Trunc

Les agrégats d'un **rapport** (un report : une question qui groupe ses réponses et les résume), à côté de `Sum`,
`Min`, `Max` et `Count()`, et le mois d'une date (ou son jour, sa semaine, son année...) dans un fuseau horaire comme
clé des lignes :

```cesia norun
Sale = cepheus.Kind("sale", {Client: cepheus.Link(), Amount: cepheus.Money(2), Day: cepheus.Date(), Tag: cepheus.Text(many = true)})
(* a fork, so that what this example writes stays out of db *)
sales = result.Unwrap(cepheus.Fork(db, [Sale]))
for x in [[ada, 10, 1801438200, ["new"]], [ada, 30, 1802250000, ["new", "web"]], [bo, 20, 1802250000, ["web"]], [bo, 60, 1806532200, []]]
  result.Unwrap(cepheus.Insert(Sale, {Client: x[1], Amount: x[2], Day: x[3], Tag: x[4]}, sales))
end
io.Print(cepheus.Find(4, (i, c, n, a) -> {
  Where: [[i, Sale.Client, c], [c, Client.Name, n], [i, Sale.Amount, a]],
  Give: {Name: n, Mean: cepheus.Avg(a), Median: cepheus.Median(a), Low: cepheus.Quantile(a, 0.25), Spread: cepheus.Stddev(a)},
  Sort: [n],
}, sales))
paris(d) = cepheus.Trunc(d, "month", zone = "Europe/Paris")
for r in result.Unwrap(cepheus.Find(3, (i, a, d) -> {Where: [[i, Sale.Amount, a], [i, Sale.Day, d]], Give: {Month: paris(d), Total: cepheus.Sum(a)}, Sort: [paris(d)]}, sales))
  io.Print(date.Format(date.FromUnix(r.Month)), r.Total)
end
io.Print(cepheus.Find(4, (i, c, n, t) -> {
  Where: [[i, Sale.Client, c], [c, Client.Name, n], cepheus.Optional([i, Sale.Tag, t])],
  Give: {Name: n, Tags: cepheus.Values(t), Different: cepheus.Count(t), Sales: cepheus.Count(i)},
  Sort: [n],
}, sales))
```

```text
Ok([{Name: "Ada Martin", Mean: 20.0, Median: 20.0, Low: 15.0, Spread: 14.142135623730951}, {Name: "Bo Lind", Mean: 40.0, Median: 40.0, Low: 30.0, Spread: 28.284271247461902}])
2027-01-31T23:00:00Z 60.0
2027-03-31T22:00:00Z 60.0
Ok([{Name: "Ada Martin", Tags: ["new", "web"], Different: 2, Sales: 2}, {Name: "Bo Lind", Tags: ["web"], Different: 1, Sales: 2}])
```

La moyenne d'Ada, de 10 et 30, est 20, sa médiane aussi, entre les deux ; son premier quartile est 15 (10 plus un quart
du chemin jusqu'à 30) ; la dispersion de deux valeurs est leur écart divisé par $\sqrt 2$. Les mois : la dernière
vente de Bo, de 22 h 30 UTC le 31 mars, est d'avril à Paris (0 h 30 le 1er avril, heure d'été), et la première d'Ada,
de 23 h 30 UTC le 31 janvier, de février (0 h 30 le 1er février) ; février commence à 23 h UTC le 31 janvier, avril à
22 h UTC le 31 mars. La deuxième vente d'Ada a deux tags, la dernière de Bo aucun : `Values` donne la liste des tags
différents, `Count(t)` les compte, `Count(i)` compte les ventes (`Count()` compterait les lignes, une par tag).

![À gauche, les quatre lignes du Where : Ada Martin 10,00 et 30,00, Bo Lind 20,00 et 60,00. Des flèches mènent les deux lignes de chaque client à une ligne du rapport : Ada Martin avec Mean 20,00, Median 20,00, Low 15,00 et Spread 14,14 ; Bo Lind avec 40,00, 40,00, 30,00 et 28,28.](images/report-groups.svg)

- `cepheus.Avg(x)` : la moyenne. D'ints et de floats un Float ; de money, de la money de son échelle, arrondie au plus
  proche en s'éloignant de zéro à mi-chemin (comme l'est un Float écrit dans un champ de money : 10,005 euros fait
  10,01) ; de dates, une date, arrondie à la milliseconde. C'est la somme exacte divisée une seule fois : la même quel
  que soit l'ordre des lignes.
- `cepheus.Count(x)` : le nombre de valeurs *différentes* de x dans le groupe, le `COUNT(DISTINCT x)` de SQL (des
  floats sont différents quand leurs bits le sont, comme `Sort` distingue $-0$ de $0$). `cepheus.Count()` compte
  toujours les réponses.
- `cepheus.Values(x)` : les valeurs différentes de x, une liste dans l'ordre de `Sort`, chacune une fois. Jointes en
  Cesia, c'est le `string_agg` de SQL : `text.Join(", ", row.Tags)`. Un champ `Values` n'est pas une clé de `Sort`.
- `cepheus.Quantile(x, p)`, p de 0 à 1 : la valeur à la fraction p des valeurs du groupe dans l'ordre, entre ses deux
  valeurs les plus proches (la définition 7 de Hyndman et Fan, le `percentile_cont` de PostgreSQL, celle par défaut de
  R et de NumPy) : avec n valeurs dans l'ordre et $h = p (n - 1)$,
  $x_{\lfloor h \rfloor} + (h - \lfloor h \rfloor)(x_{\lceil h \rceil} - x_{\lfloor h \rfloor})$, comptées depuis 0.
  D'ints et de floats un Float, de money de la money (arrondie à son échelle), de dates une date.
  `cepheus.Quantile(x, p, discrete = true)` : la première valeur dont le rang atteint $p\,n$ (la définition 1,
  `percentile_disc`), une des valeurs, de tout type (le nom médian d'une liste de textes). `cepheus.Median(x)` est
  `cepheus.Quantile(x, 0.5)` :

  | le sucre | sa forme simple | SQL |
  |---|---|---|
  | `cepheus.Median(x)` | `cepheus.Quantile(x, 0.5)` | `percentile_cont(0.5) WITHIN GROUP (ORDER BY x)` |
  | `cepheus.Count(x)` | (aucune : son propre agrégat) | `count(DISTINCT x)` |

- `cepheus.Variance(x)` et `cepheus.Stddev(x)` (la variance et l'écart type, standard deviation) : de l'échantillon,
  divisées par $n - 1$ (le `variance`, le `var_samp`, le `stddev`, le `stddev_samp` de PostgreSQL) : `missing` pour
  un groupe d'une seule valeur, comme le `NULL` de PostgreSQL ; avec `population = true`, divisées par n (`var_pop`,
  `stddev_pop`). D'ints, de floats et de money (dans ses unités, des euros au carré pour la variance), un Float.
- `cepheus.Trunc(d, unit, zone = "UTC")` : l'instant où commence l'unité de la date d dans l'heure locale du fuseau,
  une clé des lignes comme l'est une variable (et une clé de `Sort`). Les unités : `"second"`, `"minute"`, `"hour"`,
  `"day"`, `"week"` (ISO 8601 : depuis le lundi), `"month"`, `"quarter"`, `"year"`, `"decade"`, `"century"` (de 2001
  à 2100 est le XXIe, comme compte PostgreSQL), `"millennium"`. Un fuseau (une time zone) est un nom IANA, comme
  `"Europe/Paris"` ou `"America/New_York"`, heure d'été comprise, ou `"UTC"`. Un jour, une semaine, un mois commence
  au premier instant dont l'heure locale est à son minuit ou après : un jour dont un changement d'heure saute le
  minuit commence au changement, et les jours se suivent sur la ligne du temps ; une heure, une minute ou une seconde
  commence là où le dit l'horloge de l'instant, si bien que l'heure qu'un retour à l'heure d'hiver répète fait deux
  lignes, chacune son instant. Le `date_trunc(unit, d, zone)` de PostgreSQL 18.6 donne les mêmes instants (55 784
  essayés, jours de changement d'heure compris), sauf pour les heures d'un fuseau qui bouge de 30 minutes (l'île Lord
  Howe) : là PostgreSQL garde le décalage de l'instant et fait commencer une telle heure 30 minutes avant le
  changement.
- **missing.** La valeur absente d'un Optional est laissée de côté par `Count(x)` et `Values(x)` (comme SQL laisse de
  côté ses `NULL` : la vente de Bo sans tag) ; `Avg`, `Quantile`, `Median`, `Variance` et `Stddev` de la variable
  d'un Optional sont refusés (`invalid`), comme l'est `Sum`. Un `Trunc` d'une date absente est absent.
- **Erreurs.** Un fuseau qui n'en est pas un (`"Europe/Pariss"`, ou un nom qui n'est aucun fuseau de la base, comme
  `"../etc/passwd"`), une unité qui n'en est pas une, `Avg` d'un texte, une fraction hors de 0 à 1 : `Err` de Code
  `"invalid"`, qui les nomme ([erreurs](errors.md)).

**Comment on y répond.** Chaque groupe garde, à côté de sa clé, ce dont a besoin chaque agrégat, à mesure que les
lignes viennent, sur chaque cœur qui les lit, fusionné à la fin. La moyenne, la variance et l'écart type viennent de
**sommes exactes** (exact sums) : la somme des valeurs et la somme de leurs carrés, gardées comme des entiers d'autant
de morceaux de 30 bits qu'il leur faut (un float, qui vaut exactement $m \cdot 2^e$, à sa place binaire), si bien
qu'aucun arrondi n'a lieu avant la fin ; la variance est alors $\frac{n \sum x^2 - (\sum x)^2}{n (n - 1)}$, son
numérateur exact, divisé une seule fois et arrondi au float le plus proche (l'écart type est sa racine carrée). La
formule des manuels en floats perd tous ses chiffres quand les valeurs sont loin de 0 (des dates, en millisecondes
depuis 1970) et la mise à jour de Welford ([Welford 1962](references.md#les-rapports)) dépend de l'ordre des lignes ;
des sommes exactes donnent les mêmes bits quels que soient l'ordre et le nombre de cœurs, ce que fait PostgreSQL pour
ses agrégats `numeric` (en floats, ceux de `float8` dépendent de l'ordre). `Count(x)`, `Values` et `Quantile` gardent
les valeurs différentes de chaque groupe avec leurs comptes (une table à adressage ouvert) : un groupe d'un million de
lignes à cent valeurs différentes tient cent entrées ; un quantile est la valeur d'un rang, trouvée par **sélection**
(selection : le FIND de Hoare, [Hoare 1961](references.md#les-rapports) : une partition autour de la médiane de trois,
linéaire en moyenne, qui trie le reste après quelques tours, si bien qu'aucune entrée ne la rend quadratique :
[Musser 1997](references.md#les-rapports)). Un `Trunc` est calculé à partir de la date à mesure que chaque ligne est
donnée, à partir des règles du fuseau : la base des fuseaux horaires du système (ses fichiers TZif, [RFC
8536](references.md#les-rapports), dans `$TZDIR` ou `/usr/share/zoneinfo`, que met à jour le package `tzdata` du
système), chaque fuseau lu une seule fois par un processus ; un serveur lit une nouvelle version des règles à son
prochain démarrage, comme le fait PostgreSQL compilé avec les données de fuseaux du système.

**Suivi.** Un `Watch` d'un rapport garde chaque groupe par différence : les sommes, les sommes exactes et les comptes
des sacs ajoutent une ligne qui vient et retirent une ligne qui part ; un groupe dont les lignes changent est remplacé
en entier (son ancienne ligne retirée, sa nouvelle ajoutée), et rien d'autre n'est redemandé. Les `Values` d'un
groupe sont une ligne par valeur au serveur et dans le protocole ; le package les replie en une seule map, si bien
qu'un message donne la map du groupe en entier.

**Bornes.** Les valeurs qu'un groupe garde (`Count(x)`, `Values`, `Quantile`) comptent dans les cellules de la
réponse, la borne de mémoire d'une question au serveur ([limites](limits.md#les-questions)) : au-delà, `Err` de Code
`"too_large"`, jamais un serveur à court de mémoire.

## Les fenêtres : Running, Rank, Prev, Each

Une **window** (une fenêtre : un champ calculé à partir des autres lignes de la réponse) est un champ de `Give` dont
la valeur vient des autres lignes de la réponse, lues dans l'ordre de `Sort` : un total cumulé, une moyenne mobile, la
place de la ligne, la ligne d'avant. Et `Each` coupe les lignes en groupes : les fenêtres repartent de la première
ligne de chaque groupe, et `Limit` est celle de chaque groupe.

```cesia norun
day(d) = date.FormatDate(date.FromUnix(d))
for r in result.Unwrap(cepheus.Find(5, (i, c, n, a, d) -> {
  Where: [[i, Sale.Client, c], [c, Client.Name, n], [i, Sale.Amount, a], [i, Sale.Day, d]],
  Give: {Name: n, Day: d, Amount: a, SoFar: cepheus.Running(cepheus.Sum(a)), Before: cepheus.Prev(a),
         Mean2: cepheus.Running(cepheus.Avg(a), last = 2), Row: cepheus.Running(cepheus.Count())},
  Sort: [d],
}, sales))
  io.Print(day(r.Day), r.Name, r.Amount, r.SoFar, r.Before, r.Mean2, r.Row)
end
(* each client's balance: the windows start again at each client's first sale *)
for r in result.Unwrap(cepheus.Find(5, (i, c, n, a, d) -> {
  Where: [[i, Sale.Client, c], [c, Client.Name, n], [i, Sale.Amount, a], [i, Sale.Day, d]],
  Give: {Name: n, Day: d, Amount: a, Balance: cepheus.Running(cepheus.Sum(a))},
  Sort: [n, d],
  Each: [n],
}, sales))
  io.Print(r.Name, day(r.Day), r.Amount, r.Balance)
end
(* the largest sale of each client: Limit is each group's *)
io.Print(cepheus.Find(4, (i, c, n, a) -> {
  Where: [[i, Sale.Client, c], [c, Client.Name, n], [i, Sale.Amount, a]],
  Give: {Name: n, Amount: a}, Sort: [cepheus.Desc(a)], Limit: 1, Each: [n],
}, sales))
(* the clients by their total, with their places: a window over a report's groups *)
io.Print(cepheus.Find(4, (i, c, n, a) -> {
  Where: [[i, Sale.Client, c], [c, Client.Name, n], [i, Sale.Amount, a]],
  Give: {Name: n, Total: cepheus.Sum(a), Place: cepheus.Rank(), SoFar: cepheus.Running(cepheus.Sum(cepheus.Sum(a)))},
  Sort: [cepheus.Desc(cepheus.Sum(a))],
}, sales))
```

```text
2027-01-31 Ada Martin 10.0 10.0 missing 10.0 1
2027-02-10 Bo Lind 20.0 30.0 10.0 15.0 2
2027-02-10 Ada Martin 30.0 60.0 20.0 25.0 3
2027-03-31 Bo Lind 60.0 120.0 30.0 45.0 4
Ada Martin 2027-01-31 10.0 10.0
Ada Martin 2027-02-10 30.0 40.0
Bo Lind 2027-02-10 20.0 20.0
Bo Lind 2027-03-31 60.0 80.0
Ok([{Name: "Bo Lind", Amount: 60.0}, {Name: "Ada Martin", Amount: 30.0}])
Ok([{Name: "Bo Lind", Total: 80.0, Place: 1, SoFar: 80.0}, {Name: "Ada Martin", Total: 40.0, Place: 2, SoFar: 120.0}])
```

![Six mois dans l'ordre de Sort, chacun avec son total. Le total cumulé d'un mois est la somme de janvier jusqu'à lui : 1 200, 2 000, 3 500... Pour avril, le frame de last = 3 couvre février, mars et avril, dont la moyenne est 1 066,67, et Prev donne les 1 500 de mars.](images/windows-running.svg)

Le 10 février, la vente de Bo vient avant celle d'Ada : `Sort` ordonne les lignes d'un même jour par leurs autres
champs, le montant d'abord (20 avant 30), donc le total cumulé, la ligne d'avant et le numéro de la ligne sont les
mêmes à chaque exécution. La figure montre les mois du [tutoriel 13](tutorials.md#13-un-solde-mensuel-avec-un-total-cumulé-lécart-au-mois-précédent-et-une-moyenne-mobile-sur-3-mois) :
chaque fenêtre lit les lignes dans l'ordre de `Sort`, de la première jusqu'à la ligne, ou les 3 dernières.

- `cepheus.Running(f)` : l'agrégat f sur les lignes depuis la première du groupe de la ligne jusqu'à la ligne (le
  `f(x) OVER (ORDER BY ... ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` de SQL) ; `cepheus.Running(f, last = n)` :
  sur la ligne et les n - 1 d'avant (`ROWS BETWEEN n - 1 PRECEDING AND CURRENT ROW`), moins pour les premières lignes
  du groupe, comme le **frame** de SQL (le cadre : les lignes qu'un agrégat de fenêtre lit pour une ligne) tient les
  lignes qu'il peut. f est `Sum`, `Avg`, `Min` ou `Max` d'un champ de `Give`, des types que ces agrégats prennent (une
  somme d'ints ou de money, une moyenne d'ints, de floats, de money ou de dates, le plus petit ou le plus grand int,
  money ou date), ou `Count()`, les lignes du frame : `Running(Count())` est le numéro de la ligne, le `row_number()` de
  SQL.
- `cepheus.Rank()` : la place de la ligne dans l'ordre de `Sort` au sein de son groupe, les lignes égales sur les clés
  de `Sort` la partageant et les places qu'elles prennent sautées : 1, 2, 2, 4 (le `rank()` de SQL) ;
  `cepheus.Rank(dense = true)` : aucune sautée, 1, 2, 2, 3 (`dense_rank()`).
- `cepheus.Prev(x)` : le champ x de `Give` dans la ligne d'avant, dans l'ordre de `Sort` au sein du groupe (le
  `lag(x)` de SQL) ; `cepheus.Prev(x, back = n)` : n lignes avant (`lag(x, n)`, le même mois l'an dernier :
  `back = 12`) ; `missing` pour les premières lignes du groupe, comme `lag` donne `NULL`. La valeur de la ligne
  suivante est `Prev` dans l'ordre inverse (le `lead` de SQL).
- `Each: [x, ...]`, une clé de la question à côté de `Sort` et `Limit` : des champs de `Give` qui sont des variables
  ou des `Trunc` (les clés d'un rapport), qui coupent les lignes en groupes (le `PARTITION BY` de SQL). Les fenêtres
  repartent de la première ligne de chaque groupe ; `Limit: k` garde les k premières lignes de chaque groupe et les
  copies de sa k-ième (le `LATERAL (... ORDER BY ... LIMIT k)` de SQL, ou `row_number() OVER (PARTITION BY ...) <=
  k`) ; `Limit: 1` est le `DISTINCT ON` de SQL. Les lignes viennent toujours dans l'ordre de `Sort`, celui de toute la
  réponse : pour avoir les lignes de chaque groupe ensemble, trier d'abord par le groupe.

  | le sucre | sa forme simple | SQL |
  |---|---|---|
  | `cepheus.Running(cepheus.Count())` | (aucune : les lignes du frame comptées) | `row_number() OVER (...)` |
  | `cepheus.Prev(x)` | `cepheus.Prev(x, back = 1)` | `lag(x) OVER (...)` |
  | `Limit: 1, Each: [x]` | (aucune : la Limit de chaque groupe) | `DISTINCT ON (x)` |

- **L'argument d'une fenêtre est un champ de `Give`**, écrit comme `Sort` écrit ses clés : une variable, un agrégat
  ou un `Trunc` que `Give` donne. Ainsi des lignes égales dans l'ordre de `Sort` sont la même ligne, et la valeur d'une
  fenêtre est la même à chaque exécution. Dans un rapport, une ligne est un groupe : le total cumulé des sommes des
  groupes est `Running(Sum(Sum(t)))`, la `Sum` du champ `Sum(t)`, et la moyenne des totaux des trois derniers mois
  `Running(Avg(Sum(t)), last = 3)`, comme SQL écrit `sum(sum(t)) OVER (...)` et `avg(sum(t)) OVER (...)`.
- **L'ordre.** Une fenêtre a besoin de `Sort` (sans lui, `Err` de Code `"invalid"`, jamais des lignes dans un ordre
  que personne n'a choisi). L'ordre de `Sort` est total : ses clés, puis chaque autre champ par son nom, donc
  `Running` compte une par une, dans cet ordre, les lignes égales sur les clés (le `ROWS` de SQL). Le frame par défaut
  de PostgreSQL pour `sum(x) OVER (ORDER BY ...)` est `RANGE` : les lignes égales sur l'`ORDER BY` partagent un seul
  total, celui d'après la dernière d'entre elles ; avec un ordre unique les deux sont les mêmes. `Rank` compare les
  clés données à `Sort`, pas les autres champs.
- **Les pages.** Les fenêtres sont calculées avant `After` et `Limit` : un total cumulé sur la deuxième page continue
  celui de la première, un `Rank` compte les lignes des pages d'avant, un `Prev` lit la dernière ligne de la page
  d'avant. `Each` ne prend pas d'`After` (`Limit` est alors celle de chaque groupe, donc une page n'a pas de dernière
  ligne) : paginer les groupes avec une question à eux, puis demander leurs lignes avec `In`.
- **missing.** Une valeur absente (celle d'un `Optional`, un `Prev` de la première ligne, une variance d'une seule
  valeur) est laissée de côté par `Sum`, `Avg`, `Min` et `Max`, comme SQL laisse de côté `NULL` ; un frame sans
  aucune valeur donne `missing`. `Count()` compte les lignes du frame, quelles que soient leurs valeurs.
- **Les types et l'exactitude.** Comme ceux des agrégats : une somme cumulée d'ints est un Int, de money de la money ;
  une moyenne d'ints un Float, de money de la money de son échelle arrondie au plus proche en s'éloignant de zéro à
  mi-chemin, de dates une date ; à partir de **sommes exactes**, donc une moyenne mobile sur un frame qui glisse a
  les mêmes bits que la moyenne de ses lignes calculée à part. Une somme cumulée au-delà des 63 bits d'un Int est un
  `Err` de Code `"invalid"` (dans une ligne que la réponse donne ; une somme au-delà dans une ligne après la page n'est
  pas une erreur).
- **Les erreurs.** Une fenêtre sans `Sort`, une fenêtre d'un champ que `Give` ne donne pas, une fenêtre comme clé de
  `Sort`, `Running` de `Count(x)`, de `Values` ou d'un quantile, `last` ou `back` hors de 1 à 100 000, `Each` sans
  `Sort`, `Each` sans `Limit` ni fenêtre, `Each` avec `After`, `Each` d'un agrégat, une fenêtre ou `Each` sur un
  rapport avec `Values` : `Err` de Code `"invalid"`, qui le nomme ([erreurs](errors.md)).

**Comment c'est répondu.** Les lignes sont faites comme sans fenêtres (les k premières de l'ordre pour une `Limit`,
lues dans l'index de la première clé quand c'en est un, [pages](#sort-limit-et-after--des-pages)), les lignes de
chaque groupe listées une fois dans l'ordre (un tri par comptage de leurs groupes), et chaque fenêtre est alors un
passage sur chaque groupe, les méthodes de [Leis 2015](references.md#les-fenêtres) : un frame depuis la première
ligne garde son agrégat au fil des lignes (la cumulative aggregation, l'agrégation cumulative) ; un frame des n
dernières lignes ajoute la ligne qui arrive et retire celle qui part (la removable cumulative aggregation, l'agrégation
cumulative qu'on peut retirer), que les sommes exactes permettent sans aucune erreur, là où des sommes de floats
dériveraient ; `Min` et `Max` sur les n dernières lignes, qu'aucune soustraction ne défait, gardent une file des
candidats du frame, chacun plus tard et meilleur que celui d'avant, donc chaque ligne entre et sort une seule fois
([Lemire 2006](references.md#les-fenêtres)). Une fenêtre coûte un passage sur ses lignes, quel que soit son frame. Avec
`Each` et `Limit: k`, chaque groupe garde ses k premières lignes pendant que la question est lue, sur chaque cœur :
pour k jusqu'à 32 dans l'ordre, une ligne mise à sa place et celles au-delà de la k-ième (sauf ses copies) retirées
aussitôt ; pour un k plus grand, au plus 2k lignes, triées pour revenir à ses k premières quand elles sont pleines. Un
binding (une liaison des variables) au-delà de la k-ième du groupe est mis de côté après une seule comparaison, avant
d'être fait ligne : le travail est d'environ une comparaison par ligne, la mémoire de k lignes par groupe. Une page
après un curseur ne trie pas les lignes d'avant : un seul passage sur elles donne leur nombre, leurs sommes, leurs
meilleures valeurs et les quelques dernières lignes qu'un frame ou un `Prev` demande, lues dans l'intervalle de la
première clé avant le curseur quand c'est celle d'un index, et la page elle-même est lue comme l'est une page sans
fenêtres.

**Surveillé.** Un `Watch` d'une question avec des fenêtres ou `Each` est refusé (`invalid`) : un total cumulé, une
place ou une ligne d'avant dépend de chaque ligne d'avant, et les premières lignes d'un groupe avec `Each` de chaque
ligne du groupe, donc un seul changement changerait chaque ligne d'après. Surveiller la question sans elles et les
calculer dans le programme, ou redemander `Find` quand le watch dit que les lignes ont changé.

**Les bornes.** Au plus 64 fenêtres par question ; `last` et `back` au plus 100 000 lignes ; les lignes, les clés des
groupes et les valeurs des fenêtres comptent dans les cellules de la réponse ([limites](limits.md#les-questions)) :
au-delà, `Err` de Code `"too_large"`.

## Watch : les questions vivantes

Une **question vivante** (live question) est un `Find` qui reste ouvert. `cepheus.Watch(n, question, db, size = 64, until = missing)`
prend la même question que `Find` et donne un `Ok` de `{Changes, Watch}` : `Changes` est un **channel** de Cesia (une
queue entre fibers, c'est-à-dire une file qui porte des valeurs d'une fiber à une autre, lue par `fiber.Receive` ou
`for` ; le livre de Cesia, chapitre « Fibers ») qui tient au plus `size` messages. Ce qu'il donne est un
**watch** (de l'anglais « surveiller » : la question tenue ouverte). Son premier message est la **réponse**,
`{Group, Rows}` : les lignes que donne `Find` au groupe `Group`. Chaque message suivant est un **changement**,
`{Group, Added, Removed}` : les lignes venues et les lignes parties avec le groupe `Group`, si bien que les lignes
tenues, `Added` ajoutées et `Removed` retirées, sont alors les lignes de `Find` à ce groupe. Chaque message a les quatre
champs ; les deux qu'il n'utilise pas sont `missing`.

```cesia norun
unpaidOf(c) = (i, total) -> {
  Where: [[i, Invoice.Client, c], [i, Invoice.Status, "unpaid"], [i, Invoice.Total, total]],
  Give: {Invoice: i, Total: total},
}
w = result.Unwrap(cepheus.Watch(2, unpaidOf(ada), db))
io.Print(fiber.Receive(w.Changes))
small = result.Unwrap(cepheus.Insert(Invoice, {Client: ada, Total: 45, Status: "unpaid"}, db))
result.Unwrap(cepheus.Update(Invoice, small, {Status: "paid"}, db))
io.Print(fiber.Receive(w.Changes))
io.Print(fiber.Receive(w.Changes))
cepheus.Close(w)
```

```text
Ok({Group: 14, Rows: [{Invoice: 65538, Total: 80.5}], Added: missing, Removed: missing})
Ok({Group: 15, Rows: missing, Added: [{Invoice: 65546, Total: 45.0}], Removed: []})
Ok({Group: 16, Rows: missing, Added: [], Removed: [{Invoice: 65546, Total: 45.0}]})
```

- Un changement ne vient que quand les lignes changent, et seulement une fois son groupe sur le disque du serveur (G1) :
  un écran ne montre jamais une écriture qu'un crash pourrait défaire.
- Les lignes sont celles de `Find`, avec leurs répétitions : un `Give` qui laisse de côté une variable donne une ligne
  pour chaque binding, comme le fait `Find`. Les agrégats (`Sum`, `Count`, `Min`, `Max`, et ceux d'un rapport :
  `Avg`, `Values`, `Quantile`...) se suivent aussi : un changement retire alors l'ancienne ligne d'un groupe et ajoute
  la nouvelle.
- **Pas de trou, pas de répétition.** Quand la connexion casse ou que le serveur redémarre, le watch reprend de
  lui-même au groupe de son dernier message : le serveur répond que rien de ce que lit la question n'a changé depuis
  (et rien ne vient), ou par la réponse à son groupe le plus récent, que le package transforme en changement à partir
  des lignes qu'il tient. Le programme ne voit ni trou ni message deux fois.
- **Une fiber lente ne retient personne.** Chaque fiber qui suit une question garde sa propre queue de 256 messages
  dans le package ; celle qui prend plus de retard perd cette queue et reçoit à nouveau la réponse entière,
  `{Group, Rows}`, à sa prochaine lecture, plutôt que chaque changement manqué. Au serveur, une connexion qui tient
  plus de 8 MiB de messages qu'elle n'a pas encore pris termine ses watches par `"lagging"` (« en retard »), et le
  package relance le watch depuis son dernier groupe. Les écritures n'attendent jamais un watch.
- **Un seul watch par question.** Toutes les fibers du programme qui suivent la même question (les mêmes patterns,
  constantes et `Give`) partagent un seul watch : le serveur calcule ses changements une fois, et le package donne à
  chaque fiber sa copie.
- **Où c'est calculé**, comme pour `Find` : sur la machine du serveur, dans le programme, à partir des groupes qu'il
  suit pour ses lectures locales (il calcule les changements de chaque frame pendant que le serveur la force sur le
  disque, et les donne une fois qu'elle est durable) ; ailleurs au serveur, qui les pousse. Les watches d'un fork se
  calculent dans le fork, à chacune de ses écritures.
- `cepheus.Close(w)` termine le watch : son channel se ferme une fois son dernier message pris. Un watch ne se termine
  de lui-même que quand sa base est fermée ou que son token n'a plus le droit de lire la base : le channel se ferme, et
  le `cepheus.Watch` suivant de cette question dit pourquoi.
- `until`, un channel, termine le watch dès qu'il se ferme, comme le fait `cepheus.Close(w)`. Un écran vivant de
  `std/live` de Cesia en donne un, `s.Ended`, qui se ferme quand sa page s'en va : son affichage est alors
  `live.Show("unpaid", cepheus.Watch(1, unpaidOf(c), db, until = s.Ended)?.Changes)`, et le watch se termine avec la
  page.

**Comment un changement se calcule.** Une question est un join de patterns (une conjunctive query, une requête faite de
conditions qui doivent toutes être vraies). Quand un groupe ajoute des faits, les nouvelles lignes sont les bindings
qui utilisent un fait ajouté dans au moins un pattern ; chacun est trouvé une fois, au premier pattern qui correspond à
un fait ajouté (les patterns d'avant lui lisent la base sans les faits du groupe, ceux d'après avec eux), chaque partie
une seule recherche dans les index, ce fait fixé : la **delta query** (la requête du changement) d'Ammar, McSherry,
Salihoglu et Joglekar (2018), menée par le même Generic Join que `Find`. Les faits retirés donnent de la même façon les
lignes retirées, sur la base d'avant le groupe. `Sum` et `Count` suivent par différence ; `Min` et `Max` sont
redemandés pour la clé dont l'extremum est parti. Les questions qui ne diffèrent que par leurs constantes (les factures
impayées de chaque client) partagent un seul **template** (un modèle de question, dont les constantes deviennent des
paramètres) : le changement d'un fait se calcule une fois et ses lignes vont aux watches dont les constantes leur
correspondent, si bien qu'un groupe coûte autant avec 10 watches qu'avec 10 000 ([ce que cela coûte](#ce-que-cela-coûte)).

![À gauche, le groupe 15 ajoute la facture impayée 65546 d'Ada, de total 45, et le groupe 16 la marque payée. Au milieu, le template unpaidOf(c) et ses trois motifs calcule chaque changement une fois (la delta query). À droite, la watch de c = ada, partagée par les fibers A et B, reçoit les lignes ; celle de c = bo ne reçoit rien. En dessous, les trois messages que reçoit la fiber A : la réponse au groupe 14, puis la facture 65546 ajoutée au groupe 15, puis retirée au groupe 16.](images/watch-flow.svg)


### Sort et Limit dans un watch

`Watch` prend `Sort` et `Limit` comme `Find` : à chaque message ses lignes sont celles de `Find` avec les mêmes `Sort`
et `Limit` au groupe du message (les k premières lignes dans l'ordre, et les copies de la k-ième), et chaque message
donne ses lignes dans l'ordre : les `Rows` d'une réponse, les `Added` et les `Removed` d'un changement, chacun trié.
Les messages gardent leurs deux formes, si bien qu'un lecteur de watch en lit un avec `Sort` comme un autre ; les
lignes tenues restent un ensemble auquel on ajoute `Added` et dont on retire `Removed` : une page qui les montre dans
l'ordre place `Added` à sa place ou retrie les k lignes (`std/live` tient les lignes d'un affichage comme un
ensemble).

```cesia norun
top2 = (i, total) -> {
  Where: [[i, Invoice.Total, total]],
  Give: {Invoice: i, Total: total},
  Sort: [cepheus.Desc(total)],
  Limit: 2,
}
w = result.Unwrap(cepheus.Watch(2, top2, db))
io.Print(fiber.Receive(w.Changes))
big = result.Unwrap(cepheus.Insert(Invoice, {Client: bo, Total: 500, Status: "paid"}, db))
io.Print(fiber.Receive(w.Changes))
result.Unwrap(cepheus.Update(Invoice, big, {Total: 5}, db))
io.Print(fiber.Receive(w.Changes))
cepheus.Close(w)
```

```text
Ok({Group: 16, Rows: [{Invoice: 65537, Total: 1200.0}, {Invoice: 65538, Total: 80.5}], Added: missing, Removed: missing})
Ok({Group: 17, Rows: missing, Added: [{Invoice: 65547, Total: 500.0}], Removed: [{Invoice: 65538, Total: 80.5}]})
Ok({Group: 18, Rows: missing, Added: [{Invoice: 65538, Total: 80.5}], Removed: [{Invoice: 65547, Total: 500.0}]})
```

- Une ligne qui vient avant la dernière ligne de la fenêtre (window : les k lignes que le watch tient) y entre, et
  pousse dehors les lignes au-delà de la k-ième ; une ligne de la fenêtre qui part est remplacée par la suivante de
  l'ordre, que le watch lit par un seul `Find` des lignes d'après sa dernière (`After` elle, `Limit` les lignes qui
  manquent) au groupe du changement. Le watch tient k lignes, jamais toute la réponse, et sa première réponse coûte une
  page.
- Une ligne de la fenêtre dont les champs changent part et revient avec ses nouveaux champs dans le même changement, à
  sa nouvelle place (ou pas du tout, quand sa nouvelle place est au-delà de la k-ième). Une écriture qui ne change rien
  à la fenêtre (une ligne au-delà de la k-ième, un fait qu'aucune ligne de la question ne lit) ne donne aucun message.
- `Sort` sans `Limit` garde toutes les lignes de la réponse, dans l'ordre.
- Refusés, `invalid` : `After` (les lignes d'un watch sont les premières de son ordre, à mesure qu'elles changent),
  `Limit` sans `Sort` (l'ordre du moteur n'est pas un ordre qu'un watch peut garder), `Sort` ou `Limit` avec des
  agrégats, un `Limit` de plus de 100 000 lignes (comme pour `Find`). Face à un serveur d'une version antérieure
  (protocole 4 ou plus ancien), un tel watch est refusé dans le programme, jamais envoyé : « this server speaks
  protocol 4: a watch with Sort and Limit needs a server of protocol 5 ». Un watch sans eux part comme avant.
- **Ce qu'il coûte.** Un changement coûte les delta queries ci-dessus, comme pour tout watch, plus la comparaison de
  chaque ligne qu'elles ajoutent ou retirent avec la dernière ligne de la fenêtre, $O(d \log k)$ pour $d$ lignes, plus un
  `Find` d'une page quand une ligne quitte la fenêtre. Sur l'application du [guide](app.md#9-le-tableau-de-bord-en-direct),
  les dix derniers paiements de son tableau de bord : la première réponse en 97 µs contre 6 299 µs pour les paiements des
  dernières 24 heures que la page triait (3 410 lignes tenues au lieu de 10), et un groupe au hub (le fil qui calcule les
  changements) 11,9 µs à la médiane contre 10,0, 18,7 en moyenne contre 13,5 (un paiement repris remplit à nouveau la
  fenêtre : un `Find` d'une page) ([ce que cela coûte](app.md#14-ce-que-cela-coûte)).

**Comment la fenêtre est tenue.** Le watch tient sa fenêtre W (les lignes de `Find` avec `Limit` k) et L, sa dernière
ligne. Une ligne de la réponse est dans W exactement quand elle vient à L ou avant dans l'ordre (toutes les lignes
d'avant la k-ième, et toutes les copies de la k-ième), sauf si W est toute la réponse (moins de k lignes : alors toutes
y sont). Donc, après un groupe, les lignes de la nouvelle réponse à L ou avant sont celles de W, moins les lignes
retirées à L ou avant, plus les lignes ajoutées à L ou avant : les lignes des delta queries, chacune comparée à L. Si
elles sont k ou plus, la nouvelle W est leurs k premières et les copies de la k-ième ; si elles sont moins, chaque
ligne qui manque encore à la nouvelle W vient après L, et un seul `Find` avec `After` L et `Limit` les lignes qui
manquent les donne (un remplissage qui en trouve moins qu'il n'en demande les a toutes trouvées, et W est alors toute
la réponse). `spec/WatchWindow.tla` vérifie la règle : après chaque groupe W est les lignes de `Find`, et TLC la casse
quand on enlève le remplissage, quand la coupe sépare les copies de la k-ième ligne, ou quand « à L ou avant » devient
« avant L » ; `test/live_sim.ml` la vérifie contre `Find` et un oracle à lui à chaque message.

## Règles

Une **règle** dérive des faits à partir de faits, et la base les tient à jour à chaque écriture : « un client qui a une
facture en retard est en retard de paiement » ([règles](rules.md) dit comment, et ce que cela coûte).
`cepheus.Rule(name, n, rule)` en écrit une comme une question : une fonction de `n` variables qui donne
`{Where, Then}`, `Where` ses patterns (et `Above`, `Below`, `Between`), `Then` le fait qu'elle donne pour chaque
réponse. `cepheus.Define(rules, db)` les définit, en un seul groupe :

```cesia norun
Standing = cepheus.Kind("standing", {Overdue: cepheus.Bool()})
db = result.Unwrap(cepheus.Connect(sys.Env("CEPHEUS_URL"), [Client, Invoice, Standing], token = sys.Env("CEPHEUS_TOKEN")))
overdue = cepheus.Rule("overdue", 2, (c, i) -> {Where: [[i, Invoice.Client, c], [i, Invoice.Status, "late"]], Then: [c, Standing.Overdue, true]})
io.Print(cepheus.Define([overdue], db))
late = result.Unwrap(cepheus.Insert(Invoice, {Client: bo, Total: 30, Status: "late"}, db))
io.Print(cepheus.Get(Standing, bo, db))
result.Unwrap(cepheus.Update(Invoice, late, {Status: "paid"}, db))
io.Print(cepheus.Get(Standing, bo, db))
```

```text
Ok(missing)
Ok({Overdue: true})
Ok(missing)
```

- Le fait dérivé est écrit dans le même groupe que la facture qui le donne, et s'en va dans le groupe qui paie la
  facture, puisqu'il n'a pas d'autre preuve : une question le lit comme n'importe quel fait (ici `Get`), et un `Watch`
  de ce fait change avec lui.
- `Define` trouve chaque règle par son nom : une règle déjà définie telle qu'elle est donnée n'écrit rien, une règle
  dont la définition a changé est remplacée ; un programme définit donc ses règles à chaque démarrage, après `Connect`.
  La première définition dérive ce que la règle donne sur les faits déjà là.
- `Then: cepheus.Never` fait une **contrainte** : un groupe qui donnerait une réponse à son `Where` est refusé en
  entier, avec le Code `"invalid"` et le nom de la règle (G18).
- `Where` prend des patterns, `Above`, `Below`, `Between` et `Not` ; `Or`, `In` et `Prefix` sont pour les questions.
  Une variable de `Then` doit être dans un pattern de `Where` hors d'un `Not`, et une règle ne peut pas prendre le nom
  d'une propriété : les deux sont refusés avec le Code `"invalid"`.
- Les règles sont pour les tokens qui écrivent toute la base ([droits](server.md#les-droits-g16)) : une règle lit chaque
  kind.

Le `Where` d'une règle peut tenir `cepheus.Not(...)` : une réponse tient quand aucun fait ne correspond à ses patterns,
ses variables qui ne sont dans aucun autre pattern lui étant propres (« il n'y a pas de facture `j` de `c` qui soit
impayée »). La valeur de `Then` peut être `cepheus.Sum(x)`, `Min(x)`, `Max(x)` ou `Count()` : la règle donne à sa
chose un seul fait, la somme, la plus petite ou la plus grande valeur de `x`, ou le nombre de réponses, tenu à jour
par différence à chaque écriture ([règles](rules.md#la-négation-et-les-agrégats--les-strata)) :

```cesia norun
Books = cepheus.Kind("books", {Due: cepheus.Money(2), Clear: cepheus.Bool()})
db = result.Unwrap(cepheus.Connect(sys.Env("CEPHEUS_URL"), [Client, Invoice, Books], token = sys.Env("CEPHEUS_TOKEN")))
dueOf = cepheus.Rule("due-of", 3, (c, i, t) -> {Where: [[i, Invoice.Client, c], [i, Invoice.Status, "unpaid"], [i, Invoice.Total, t]], Then: [c, Books.Due, cepheus.Sum(t)]})
clear = cepheus.Rule("clear", 3, (c, i, j) -> {Where: [[i, Invoice.Client, c], cepheus.Not([j, Invoice.Client, c], [j, Invoice.Status, "unpaid"])], Then: [c, Books.Clear, true]})
io.Print(cepheus.Define([dueOf, clear], db))
io.Print(cepheus.Get(Books, ada, db))
io.Print(cepheus.Get(Books, bo, db))
owed = result.Unwrap(cepheus.Find(1, (i) -> {Where: [[i, Invoice.Client, ada], [i, Invoice.Status, "unpaid"]], Give: {Invoice: i}}, db))
result.Unwrap(cepheus.Update(Invoice, owed[1].Invoice, {Status: "paid"}, db))
io.Print(cepheus.Get(Books, ada, db))
```

```text
Ok(missing)
Ok({Due: 80.5, Clear: missing})
Ok({Due: missing, Clear: true})
Ok({Due: missing, Clear: true})
```

- Un ensemble de règles où une propriété dépend de sa propre absence (`Not`) ou de son propre agrégat est refusé avec
  le Code `"invalid"`, qui nomme le cycle : une telle règle rendrait fausse sa propre prémisse.
- La propriété d'un agrégat prend une seule valeur, et seule cette règle la donne : une écriture de cette propriété est
  refusée. Une chose sans réponse n'a pas de fait (le `Due` d'Ada s'en est allé avec sa dernière facture impayée). Une
  somme au-delà du plus grand int refuse le groupe ; elle ne repart jamais de l'autre bout.

## OWL 2 RL

**OWL 2** est le langage des **ontologies** du W3C : une ontologie dit ce que veulent dire les mots d'un domaine de
connaissance, ses **classes** (« un professeur est une personne ») et ses propriétés (« le directeur de thèse, advisor,
est un professeur », « un e-mail est celui d'une seule personne »). **OWL 2 RL** en est la partie que des règles
calculent entièrement : le W3C la donne sous forme de 78 règles ([règles](rules.md#owl-2-rl-une-bibliothèque-de-règles) dit
comment Cepheus tient chacune). Depuis Cesia, c'est le package `owl`, à côté de `cepheus`, que le programme prend
aussi :

```toml
take = ["cesia/cepheus", "cesia/cepheus/owl"]
```

```cesia norun
use deps/www-celestial/cepheus/cesia/cepheus/owl
use std/list

Person = cepheus.Kind("person", {Name: cepheus.Text(), Email: cepheus.Text(many = true), Advisor: cepheus.Link(many = true)})
Label = cepheus.Kind("label", {Name: cepheus.Text(unique = true)})
onto = result.Unwrap(cepheus.Fork(cepheus.Empty, [owl.Vocabulary, Person, Label]))
io.Print(cepheus.Define(owl.Rl(), onto))
(* the ontology: a professor is a person; an advisor is a professor; an e-mail is one person's *)
c = result.Unwrap(cepheus.Write([
  cepheus.Add(cepheus.New(1), Label.Name, "Person"), cepheus.Add(cepheus.New(2), Label.Name, "Professor"),
  cepheus.Add(cepheus.New(2), owl.SubClassOf, cepheus.New(1)),
  cepheus.Add(cepheus.New(3), owl.Property, Person.Advisor), cepheus.Add(cepheus.New(3), owl.Range, cepheus.New(2)),
  cepheus.Add(cepheus.New(4), owl.Property, Person.Email), cepheus.Add(cepheus.New(4), owl.InverseFunctional, true)], onto)).Things
(* two records of one professor, the same e-mail in both, and a student whose advisor is the first *)
r = result.Unwrap(cepheus.Write([
  cepheus.Add(cepheus.New(1), Person.Email, "ada@uni.org"), cepheus.Add(cepheus.New(2), Person.Email, "ada@uni.org"),
  cepheus.Add(cepheus.New(2), Person.Name, "Ada"), cepheus.Add(cepheus.New(3), Person.Advisor, cepheus.New(1))], onto)).Things
io.Print(cepheus.Same(r[1], onto))
io.Print(cepheus.Get(Person, r[1], onto))
io.Print(list.Sort(result.Unwrap(cepheus.Get(owl.Vocabulary, r[2], onto)).Type), "are", c[1], "and", c[2])
(* a class disjoint from Person: Ada in it is refused *)
io.Print(cepheus.Write([cepheus.Add(cepheus.New(1), owl.DisjointWith, c[1]), cepheus.Add(r[1], owl.Type, cepheus.New(1))], onto))
result.Unwrap(cepheus.Write([cepheus.Retract(r[2], Person.Email, "ada@uni.org")], onto))
io.Print(cepheus.Same(r[1], onto), cepheus.Get(Person, r[1], onto))
```

```text
Ok(missing)
Ok([65542, 65543])
Ok({Name: "Ada", Email: ["ada@uni.org"], Advisor: []})
[65538, 65539] are 65538 and 65539
Err({Kind: "cepheus", Code: "invalid", Message: "constraint owl/cax-dw: [#65545 owl/DisjointWith #65538] [#65542 owl/Type #65545] [#65542 owl/Type #65538]"})
Ok([65542]) Ok({Name: missing, Email: ["ada@uni.org"], Advisor: []})
```

- **Le vocabulaire** est un kind comme un autre, nommé `owl` : `owl.Vocabulary`, donné à `Connect` (ou à `Fork`) avec
  les kinds propres du programme, déclare ses propriétés `owl/Type`, `owl/SubClassOf` et les autres (les mêmes que
  déclare la bibliothèque du moteur : [le vocabulaire](rules.md#le-vocabulaire)), et chacune est un nom du package :
  `owl.SubClassOf`. Une classe est une chose de la base, comme une autre ; une ontologie est faite de faits, écrits
  avec `Write`, versionnés comme les autres.
- **Un axiome sur une propriété** (une affirmation de l'ontologie) est un fait de sa **description**, une chose à part
  dont l'`owl.Property` est la propriété : `[d, owl.Property, Person.Advisor]`, puis `[d, owl.Range, professor]`. Une
  propriété d'un kind, écrite là où va un lien, est son id dans la base (relue, elle est cet Int).
- **`owl.Rl()` est une donnée** : une liste de 63 maps `{Rule, Library}`, une par règle, nommée `owl/` suivi du nom du
  W3C (`owl/cax-sco`). `Define` prend la définition de chaque règle dans la bibliothèque du moteur, pour cette base,
  crée une seule fois les choses owl:Thing et owl:Nothing (leur `owl.Builtin` est `"Thing"` et `"Nothing"`), et
  définit les règles en un seul groupe, comme n'importe quelles règles : un programme les définit à chaque démarrage, et
  la seconde fois n'écrit rien. C'est une liste comme une autre : `list.Filter` en garde une partie.
- **Des choses rendues une seule.** `owl/prp-ifp` a fait des deux fiches une seule chose : `cepheus.Same(x, db)` donne
  la **classe** de x, les choses que les règles ont rendues identiques à x. Les faits d'une classe sont gardés sur
  l'une d'elles, et `Get`, `Find` et `Watch` lisent n'importe quelle chose d'une classe comme celle-là : le nom écrit
  sur la seconde fiche se lit sur la première. L'e-mail retiré, ce sont de nouveau deux choses.
- **Refus.** Une contrainte d'OWL 2 RL (ici `owl/cax-dw` : aucune chose dans deux classes disjointes) refuse son groupe
  en entier, avec le Code `"invalid"` et le nom de la règle. Une règle du programme qui donne la liste de l'un des
  templates de la bibliothèque (`owl.IntersectionOf`, `owl.HasKey` : des règles sur tous les membres d'une liste à la
  fois) est refusée par `Define` : seule une écriture change une telle liste.
  Aucune règle à côté de celles d'OWL 2 RL ne peut tenir un `Not` ou un agrégat : ses règles sur une propriété qui est
  une variable peuvent donner n'importe quelle propriété, et une telle règle pourrait donc lire sa propre absence. C'est
  pourquoi cet exemple tourne sur un [fork](#les-forks) : la base du chapitre tient les règles avec `Not` et `Sum` plus
  haut. `owl.Rl()` sans le vocabulaire, ou un nom qui n'est pas l'une de ses règles, est un `Err` de Code `"invalid"`.
- **Droits.** Les règles d'OWL 2 RL lisent des propriétés qui sont des variables, si bien que ce qu'elles donnent peut
  venir de n'importe quel kind : un token ne le lit, et ne lit `Same`, que s'il lit chaque kind
  ([droits](server.md#les-droits-g16)) ; `Define` demande un token qui écrit toute la base. Un token de certains kinds
  reçoit `denied` pour `Same`, pour une question et pour `Define`, et ne reçoit de `Get` aucun des faits que les règles
  peuvent donner : il n'apprend aucune égalité.
- **Sécurité.** Rien de nouveau n'est décodé : les maps de `owl.Rl()` ne font que nommer des règles, que `Define` prend
  dans la bibliothèque du moteur (un nom qui lui manque est un `Err`), et le writer (le seul thread qui applique les
  groupes de la base) les vérifie comme n'importe quelle règle, sous les budgets des règles (une tempête d'égalités
  coûte n − 1 faits, jamais n², [règles](rules.md#légalité--des-classes-de-choses-égales)). `Same` par le réseau pose au
  serveur au plus deux questions, chacune sous son budget de question.

## Fichiers

Un **kind de fichiers** garde des fichiers dans la base : `Scans = cepheus.Files("scan")` est un kind avec les champs
`Name`, `Size`, `Type`, `Owner` et `Content`, donné à `Connect` comme n'importe quel autre.
`cepheus.Put(Scans, name, bytes, db, type, owner, cold)` stocke un fichier et donne son id une fois ses octets et ses
faits sur le disque du serveur ; `cepheus.Read(Scans, id, db, from, len)` donne ses octets, tous ou un intervalle
(seuls les chunks, les morceaux du fichier, qui sont sous cet intervalle sont lus) ; `cepheus.List(Scans, db)` ses
fichiers (un `Find`) ; `cepheus.Delete(Scans, id, db)` retire ses faits ([supprimer une chose](#supprimer-une-chose)) ;
`cepheus.Erase(owner, db)` détruit la clé
d'un propriétaire, après quoi chaque fichier qu'il possédait est illisible, partout où ses octets sont allés. Les droits
d'un token sur le kind sont ses droits sur les fichiers. Comment les octets sont gardés (des chunks stockés une seule
fois, compressés, scellés, vérifiés à chaque lecture) : [le vault](vault.md).

```text
Scans = cepheus.Files("scan")
db = cepheus.Connect("cepheus://srv1:7400/shop", [Client, Scans], token = sys.Env("CEPHEUS_TOKEN"), ca = "/etc/cepheus/ca.pem")?
f = cepheus.Put(Scans, "2026-11.pdf", sys.Read("2026-11.pdf")?, db, type = "application/pdf", owner = ada)?
head = cepheus.Read(Scans, f, db, from = 0, len = 1024)?
```

## Supprimer une chose

`cepheus.Delete(kind, id, db, by = 0, why = "")` supprime une chose d'un kind, le `DELETE` de SQL : au serveur, ses
faits de ce kind (chaque valeur de chaque champ du kind) sont retirés, et chaque lien qui nomme le kind et pointe vers
elle fait ce que dit son `onDelete`, le tout en un seul groupe : un `Ok` du numéro du groupe, ou un `Err` et rien
d'écrit.

```cesia norun
Order = cepheus.Kind("order", {Client: cepheus.Link(to = "client"), Total: cepheus.Money(2)})
Line = cepheus.Kind("line", {Order: cepheus.Link(to = "order", onDelete = "cascade"), Price: cepheus.Money(2)})
db = result.Unwrap(cepheus.Connect(sys.Env("CEPHEUS_URL"), [Client, Invoice, Order, Line], token = sys.Env("CEPHEUS_TOKEN")))
order = result.Unwrap(cepheus.Insert(Order, {Client: ada, Total: 30}, db))
for price in [10, 20]
  result.Unwrap(cepheus.Insert(Line, {Order: order, Price: price}, db))
end
io.Print(cepheus.Insert(Order, {Client: order, Total: 1}, db).Error.Message)
io.Print(cepheus.Delete(Client, ada, db).Error.Message)
io.Print(cepheus.Delete(Order, order, db))
io.Print(cepheus.Find(1, (l) -> {Where: [[l, Line.Order, order]], Give: {Line: l}}, db))
```

```text
order/Client links to client things only, and #65549 is not one
the client #65536 cannot be deleted while the order #65549 links to it (order/Client: refuse)
Ok(30)
Ok([])
```

- **refuse** (par défaut) : un groupe qui laisse une chose qui n'est plus du kind alors qu'un lien de `"refuse"` pointe
  encore vers elle est refusé en entier, avec le Code `"invalid"`, qui nomme le kind, la chose, une chose qui pointe
  vers elle et la propriété.
- **cascade** : la chose qui pointe est supprimée aussi, dans le kind de son lien (`Line.Order` est du kind line), comme
  `Delete` le ferait, et les liens vers elle suivent à leur tour ; une chose atteinte deux fois n'est suivie qu'une
  fois, si bien qu'un cycle (deux choses qui pointent l'une vers l'autre, une chose qui pointe vers elle-même, un arbre
  de catégories) se termine.
- **clear** : le lien est retiré ; la chose qui pointe garde ses autres champs.

Exactement : une chose **cesse d'être** d'un kind quand un groupe la laisse sans aucun fait du kind qu'une écriture a
affirmé, quoi que ce soit qui l'ait fait, un `Delete` ou le `Retract` de son dernier champ ; les liens suivent leur
`onDelete` de la même façon. Un `Delete` d'une chose sans fait du kind ne change rien (un `Ok`, son groupe n'écrit
aucun fait). Les faits qu'un `Delete` et ses liens lisent et retirent sont au plus le budget de travail du groupe, un
million pour un seul `Delete` (10 x (100 000 + 100 par opération), le budget des règles) : au-delà, le groupe est
refusé en entier, Code `"invalid"`, et rien n'est fait ; supprimez d'abord les choses qui pointent, dans des groupes à
elles. Les choses qui pointent vers une chose sont trouvées par l'index par valeur, qui tient chaque fait : une seule
recherche par propriété de lien, quel que soit leur nombre (un refus prend 6 µs, que 10 ou 10 000 factures pointent
vers le client, une cascade environ 1,4 µs par ligne : [mesuré](benchmarks.md#les-suppressions-et-les-liens-qui-nomment-un-kind-2026-11-25)).
Les règles voient un `Delete` comme les retraits qu'il
fait : ce qu'elles dérivent suit, et un `Never` est vérifié sur l'état d'après. `Watch` les voit comme n'importe quel
changement : les lignes qu'ils emportent. Une chose supprimée reste dans l'historique, comme chaque groupe. Supprimer
des choses d'un kind demande un token qui peut ajouter à ce kind et à chaque kind qu'une cascade ou un clear peut
atteindre à partir de lui, et lire chaque kind dont les liens le refusent (G16) : refusé en entier sinon, avant que
rien ne soit fait. Aucune règle ne donne un lien qui nomme un kind (un ensemble de règles qui le ferait est refusé à
`Define`).

Les liens d'un kind sont déclarés par `Connect` (et `Fork`) avec le kind : une propriété qui n'a pas de `to` dans la base
le reçoit, et le serveur vérifie chaque valeur qu'elle tient déjà (un `Err` qui en nomme une qui n'est pas une chose du
kind) ; une qui nomme un autre kind, ou un autre `onDelete`, est un `Err` à `Connect` (les changer est une migration,
pas encore construite). Un `Link()` sans `to` accepte une base où un autre programme en a déclaré un : ses écritures
sont vérifiées de la même façon.

Il y a un seul `Delete`, pour chaque kind. Sur un kind de [fichiers](#fichiers), il fait ce qu'il a toujours fait, les
faits d'un fichier retirés, avec deux vérifications à lui : le groupe est refusé, Code `"conflict"`, si le fichier a
changé entre-temps, et une chose qui n'est pas un fichier du kind est un `Err` de Code `"missing"` ; ses octets restent
dans le vault tant que l'historique les cite.

## Les forks

Un **fork** est une base dans la mémoire du programme qui part d'une autre : il lit et écrit comme une base, avec chaque
vérification (types, `unique`, `Expect`, le schéma), et rien de ce qu'il écrit ne va nulle part : la base dont il est
parti ne change pas, ni son historique (G8). En faire un ne copie rien : le fork partage l'état dont il part (une
structure **persistante** : un changement fait de nouveaux nœuds et garde les anciens, si bien que les deux états
restent lisibles).

`cepheus.Fork(from, kinds = [])` donne un `Ok` d'un fork de `cepheus.Empty` (une base vide, pour un test qui n'a besoin
d'aucun serveur), d'un autre fork, ou d'une base lue sur la machine du serveur (son état local en ce moment), avec ces
kinds déclarés dedans :

```cesia norun
what = result.Unwrap(cepheus.Fork(db))
result.Unwrap(cepheus.Update(Client, ada, {City: "Nice"}, what))
io.Print(cepheus.Get(Client, ada, what))
io.Print(cepheus.Get(Client, ada, db))
```

```text
Ok({Name: "Ada Martin", City: "Nice", Email: "ada@example.com"})
Ok({Name: "Ada Martin", City: "Lyon", Email: "ada@example.com"})
```

Un fork d'une base lue au serveur (un programme sur une autre machine) n'est pas encore construit : il donne un `Err` de
Code `"invalid"` : voir [Ce qui n'est pas encore construit](#ce-qui-nest-pas-encore-construit).

### Tests

Un test de `cesia test` n'a besoin d'aucun serveur : il fait un fork de `cepheus.Empty` avec les kinds qu'il utilise.
Un fichier de test se tient à côté du code qu'il teste (`shop.test.ce` à côté de `shop.ce`), et ses fonctions sont
nommées `is` suivi d'une majuscule :

```cesia norun
use deps/www-celestial/cepheus/cesia/cepheus
use std/result

Invoice = cepheus.Kind("invoice", {Total: cepheus.Money(2), Status: cepheus.Text()})

defn isPaidOnce()
  t = cepheus.Fork(cepheus.Empty, [Invoice])?
  inv = cepheus.Insert(Invoice, {Total: 12, Status: "unpaid"}, t)?
  pay = [cepheus.Expect(inv, Invoice.Status, "unpaid"), cepheus.Add(inv, Invoice.Status, "paid")]
  cepheus.Write(pay, t)?
  cepheus.Write(pay, t).Error.Code == "conflict" and cepheus.Get(Invoice, inv, t)?.Status == "paid"
end
```

```text
cesia test --allow native=cepheus
```

Les propres tests du package sont de tels tests, chaque fonction sur des forks de `Empty`
(`cesia/tests/cepheus.test.ce`).

## Lectures locales

Sur la machine du serveur, un programme lit sa propre copie de la base : `Get` et `Find` ne coûtent aucun round trip
jusqu'au serveur. Ce qu'il lit n'est jamais périmé : une lecture qui commence après qu'une écriture a été confirmée, à
ce programme ou à n'importe quel autre, voit cette écriture. Les lectures sont **linearizable** (Herlihy et Wing 1990 :
chaque lecture et chaque écriture semble prendre effet à un instant entre son appel et sa réponse, dans un ordre qui
respecte le temps réel), et, avec les groupes, strictly serializable (G15).

![À gauche, le processus du serveur, cepheus serve : ses listeners (le socket Unix, et TCP avec TLS 1.3), ses I/O domains, une base avec son writer, son journal et ses runs, le commit buffer et la page de visibilité dans /dev/shm. À droite, trois programmes : l'un, ailleurs, lit par TCP et TLS en 41,3 µs ; l'un, sur la même machine, par le socket Unix en 9,7 µs ; l'un, en lecture locale, reçoit les fichiers run et les frames par le follow stream, mappe la page de visibilité en lecture seule et lit dans sa propre mémoire en 0,22 µs.](images/server-reads.svg)

Comment, en bref ([le serveur](server.md#lectures-locales-g15) le raconte en entier) :

- Le serveur passe au programme les fichiers de run de la base, déjà ouverts (`SCM_RIGHTS` : un socket Unix peut porter
  des fichiers ouverts d'un programme à un autre), si bien que le programme n'a besoin d'aucun droit sur les fichiers du
  serveur, et que son token décide de ce qu'il peut lire (G16). Un token qui a des [droits par kind](server.md#les-droits-g16)
  ne peut pas lire toute la base : ses lectures vont au serveur, qui ne lui donne que les kinds qu'il lit.
- Ensuite, le serveur envoie les octets de chaque groupe sur le follow stream (le flux qui suit la base) avant de les
  forcer sur son disque, et le package les applique à un nouvel état pendant que le disque travaille.
- Un seul numéro en shared memory (de la mémoire partagée entre processus), une page du serveur que chaque lecteur local
  mappe en lecture seule, dit quel état est visible : le serveur l'écrit après chaque fsync et avant de répondre aux
  writers. Une lecture le charge et sert l'état tenu sous lui, ou attend les microsecondes qu'il faut pour que cet état
  soit appliqué. Aucune écriture n'attend un lecteur.
- Chaque page lue dans un fichier de run est vérifiée par son CRC (son checksum, un nombre calculé sur ses octets) à son arrivée (G7).

Le follow stream est ouvert quand `Connect` revient ; la première lecture locale peut attendre que le follower (le
lecteur qui suit la base) applique les groupes écrits depuis le run le plus récent de la base (son rattrapage), et les
suivantes seulement, de temps en temps, les microsecondes d'une frame en route. Ce que cela coûte : un domain du
programme applique chaque groupe qu'écrit le serveur, quel que soit le programme qui l'écrit (1,7 µs par changement
seul, environ 4,5 µs sous 18 000 groupes par seconde, mesuré au serveur), et le programme tient un cache des
pages des runs les plus récents de la base (256 MB au plus : les runs qu'un merge a remplacés en sortent aussitôt) et
les changements depuis le dernier merge ([serveur](server.md#ce-que-cela-coûte)).

Si le follow stream se termine (le serveur a redémarré), le package lit au serveur en attendant et suit à nouveau, au
plus toutes les 100 ms, sans que le programme s'en aperçoive.

## Beaucoup de fibers, une seule connexion

Toutes les fibers du programme partagent l'unique connexion à la base. Une requête part aussitôt, avec son numéro ; la
fiber qui l'a envoyée attend, les autres tournent ; un domain du package lit les réponses, qui arrivent dans n'importe
quel ordre, appariées par leur numéro, et réveille chaque fiber quand sa réponse est arrivée. Ainsi :

- 200 fibers qui insèrent chacune une chose envoient 200 écritures à la fois, que le serveur groupe en quelques
  fsyncs : elles finissent ensemble, en à peu près le temps de quelques écritures, pas de 200
  ([mesuré](#ce-que-cela-coûte)).
- Un long `Find` au serveur ne retient aucun `Get` d'une autre fiber.
- Les propres appels d'une fiber gardent son ordre : elle attend chaque réponse avant son appel suivant, donc elle lit
  ce qu'elle a écrit (« read your writes ») et ses écritures atteignent la base dans l'ordre où elle les a faites
  (« monotonic writes », Terry et al. 1994).

## Erreurs

Chaque appel donne une valeur : `result.Ok` de son résultat, ou `result.Err` de `{Kind: "cepheus", Code, Message}`, que
`?` prend dans une fonction. Une faute du programme dans la forme d'un appel (une base qui n'en est pas une, une
question qui n'est pas `{Where, Give}`) est un bug : elle arrête la fiber, comme `bug.Panic`, et nomme ce qui était
attendu.

| Code | Quand | Que faire |
|---|---|---|
| `conflict` | un `Expect` du groupe n'a pas tenu | relire et décider à nouveau |
| `unique` | une valeur d'une propriété `unique` est prise | une autre valeur, ou la chose qui l'a |
| `invalid` | une valeur du mauvais type, un champ que le kind n'a pas, un kind non déclaré dans cette base, une question que le moteur refuse, une adresse sans `ca` par le réseau, un lien vers une chose qui n'est pas de son kind, une suppression qu'un lien refuse, une cascade au-delà du budget du groupe | corriger l'appel ; supprimer d'abord ce qui pointe vers elle |
| `damaged` | une page d'un fichier de run ne s'est pas vérifiée contre son CRC | l'exploitation du serveur : [opérations](operations.md) |
| `io`, `busy` | le disque du serveur a lâché, ou un autre processus tient la base | l'exploitation du serveur |
| `closed` | la base a été fermée par `Close` | se reconnecter |
| `auth`, `denied` | le token est inconnu, ou n'a pas le droit sur cette base ou sur un kind que l'appel lit ou auquel il ajoute (G16) | les droits du token : `cepheus token add` |
| `unreachable` | aucun serveur n'a répondu (à `Connect`), ou aucun pendant 30 s (à un appel ensuite) | démarrer le serveur ; une écriture a été appliquée une fois ou pas du tout |
| `unknown_database` | le serveur n'a pas de base de ce nom | l'ajouter à `cluster.toml` |
| `too_large`, `stopping`, `too_many_connections`, `version` | les limites et l'état du serveur ([erreurs](errors.md)) | comme le dit le message |

## Ce que cela coûte

Mesuré sur une seule machine (Intel Core i7-4720HQ, 4 cœurs et 8 threads, SSD SATA, Linux), builds de release, chaque
processus limité à 3 GB, chaque tour sous un lock qui tient à l'écart les autres benchmarks de la machine, les côtés
alternés à chaque tour ; chaque chiffre est une médiane avec son intervalle à 95 % sans hypothèse sur la distribution
(statistiques d'ordre). La base est celle des benchmarks (`bench.exe load`, 1 M de faits, [benchmarks](benchmarks.md)) ;
une lecture est un `cepheus.Get` d'une facture, un kind de 4 champs (`client`, `total`, `status`, `date`), sur les
factures de l'échantillon du benchmark du serveur dans le même ordre (`bench/cesia/get.ce`, `sbench.exe ids`) ; le
client OCaml est `sbench.exe`, PostgreSQL 18.6 est mené par `pgbench -M
prepared` (C, libpq) qui lit `SELECT * FROM invoice WHERE id = $1`, les mêmes lignes.

**Une lecture ponctuelle**, en µs ($n = 11$ tours) :

| | client Cesia | client OCaml | PostgreSQL 18.6 |
|---|---:|---:|---:|
| sur la machine du serveur : une lecture locale | **0,77** [0,76 ; 0,82] | 0,24 [0,22 ; 0,36] | 26,4 [23,9 ; 32,3] par son socket Unix |
| par TCP et TLS 1.3 (loopback) | 51,6 [44,1 ; 63,4] | 37,1 [31,3 ; 46,8] | 52,3, dans d'autres tours ([serveur](server.md#la-vitesse-à-côté-de-postgresql)) |
| au serveur par son socket Unix | (pas un chemin du client Cesia : il y lit en local) | 8,9 [8,0 ; 9,6] | |

- La lecture locale est 34 fois plus rapide que celle de PostgreSQL par son socket, et 3,2 fois plus lente que celle
  du client OCaml : les 0,53 µs entre elles sont la part de Cesia dans l'appel, mesurée à part sur un fork : l'appel de
  la native d'un package (une fonction Cesia, le stub de la native, ses 3 arguments convertis) environ 0,10 µs ; trouver
  la base et le kind, 0,05 ; faire la map de 4 champs et son `Ok` par l'interface native de Cesia, environ 0,17 ; la
  boucle du benchmark elle-même, 0,08 (dans le chiffre ci-dessus : une boucle qui appelle une fonction Cesia avec les
  mêmes arguments). La cible fixée avant de le construire, 1 µs, est tenue.
- Par TLS, une lecture paie le round trip, le chiffrement (environ 11 µs par round trip en C avec OpenSSL ici) et le
  travail du serveur. Le client Cesia lit sa réponse lui-même quand rien d'autre n'est en vol (la fenêtre de trois round
  trips, [beaucoup de fibers](#beaucoup-de-fibers-une-seule-connexion)) : sans cela, une réponse passait du domain
  lecteur du package à celui de Cesia par un pipe, et une lecture coûtait 74,1 µs [51,2 ; 101,7] dans les mêmes tours
  (le chemin rapide : 0,67 fois cela, la médiane des rapports des tours). Les 14 µs qui restent au-dessus du client
  OCaml sont le réveil du scheduler de Cesia (la partie qui choisit quelle fiber tourne) et les valeurs faites pour
  Cesia ; la cible de 11 µs au serveur par son socket Unix vaut pour le chemin du client OCaml, que ne prend pas un
  programme Cesia sur la machine du serveur (il lit en local).

**Écritures durables**, $n = 7$ tours de 3 s (chaque écriture une facture de 4 faits, son groupe forcé sur le disque) :

| | client Cesia, une seule connexion | client OCaml |
|---|---:|---:|
| un seul writer | 189 par seconde [94 ; 296], 3,45 ms [3,01 ; 7,81] de latence médiane | 229 [155 ; 286], une seule connexion |
| 64 writers | 7 021 par seconde [1 799 ; 8 604] : 64 fibers sur une seule connexion | 4 828 [335 ; 7 288] : 64 connexions |

Les intervalles sont larges : le fsync du disque prend 2 à 3 fois plus de temps d'une exécution à l'autre (les
[benchmarks](server.md#la-vitesse-à-côté-de-postgresql) du serveur ont vu la même chose). Ce qu'ils montrent : 64 fibers
sur une seule connexion écrivent aussi vite que 64 connexions, puisque leurs écritures partent en pipelining (envoyées
sans attendre les réponses) et partagent les fsyncs du serveur.

**Démarrage et premier appel**, en ms pour un processus entier (`cesia run`, $n = 101$ exécutions de chaque, alternées) :
`io.Print(1)` seul 3,09 [3,04 ; 3,13] ; le même avec le package utilisé mais pas appelé 3,51 [3,49 ; 3,54] ; avec un
appel 18,7 [18,6 ; 18,8].

- Rien du moteur ne se charge avant le premier appel : les 0,42 ms d'un programme qui utilise le package sont son code
  Cesia lu et compilé, comme pour tout package (`std/csv`, 40 lignes, environ 0,2 ms ; `std/sql` environ 3 ms, mesurés
  de la même façon mais sans le lock). `Watch` a allongé le code du package de 41 lignes : 0,13 ms de plus (3,66 ms
  [3,60 ; 3,75] contre 3,53 [3,48 ; 3,59] avant lui, $n = 51$ exécutions alternées).
- Le premier appel coûte 13 ms de plus (le moteur sans sa table des symboles, tel qu'il est construit maintenant :
  17,8 ms [17,6 ; 18,0] contre 20,3 [20,2 ; 20,5] avant, $n = 55$ ; le processus de cette exécution avec le package non
  utilisé : 4,5) : la vérification de l'empreinte du moteur (BLAKE2 de 2,3 MB, 3,9 ms), le chargement de l'OpenSSL du
  système (1,3 ms), et l'édition de liens de 1,4 MB de code machine dans le processus. Une fois par processus : un
  programme se connecte une fois, à son démarrage.

**OWL 2 RL** (`bench/reason.ml owlprep 1` : LUBM-1, le Lehigh University Benchmark à une université, 150 477 faits
avec l'ontologie univ-bench dans le vocabulaire d'OWL 2 RL et aucune règle, une copie pour chaque exécution ;
`Define(owl.Rl())` chronométré dans le programme, `reason.exe owldefine` pour le `define db (Owl.rl o)` d'OCaml ;
$n = 21$ tours alternés, chacun avec les mêmes 75 560 faits de `owl/Type` après) : au serveur par son socket Unix
1,26 s [1,20 ; 1,44] contre 0,93 [0,90 ; 1,01] pour OCaml sur la base dans son propre processus, 1,32× [1,22 ; 1,53]
par les rapports des tours ; dans un fork 0,82 s [0,81 ; 0,84] contre 0,78 [0,76 ; 0,81], 1,06× [0,99 ; 1,10].

- Le serveur raisonne comme OCaml : par TLS, où le programme ne garde aucune copie, `Define` prend 0,84 à 0,94 s
  (5 tours). Les 0,3 s de plus par le socket sont la copie locale du programme qui applique les 75 560 faits dérivés
  du changement, pour que ses lectures les voient (un `Define` de nouveau, qui n'écrit rien, l'attend là aussi
  longtemps, 2 ms par TLS) : le prix des lectures locales pour une écriture aussi grande, payé une fois.
- Dans un fork, le moteur est le même code dans le processus du programme : les 6 % sont le processus de Cesia autour
  de lui.
- Le démarrage ne s'allonge pas : le package `owl` n'est lu que par un programme qui s'en sert. `io.Print(1)` avec le
  package `cepheus` utilisé, pas appelé, 3,64 ms contre 3,62 avant OWL (1,005 [0,98 ; 1,04], $n = 21$ tours de 30
  exécutions, alternés) ; le premier appel, qui charge le moteur, 18,87 ms contre 18,78 (1,007 [0,98 ; 1,02]) ;
  `io.Print(1)` seul, le même programme dans les deux dossiers, 1,013 [1,00 ; 1,05] : le bruit. Le moteur tient les
  règles d'OWL 2 RL, 58 KB de plus à vérifier à son chargement (4,58 MB) ; le code propre de l'interface native (le
  binding) est plus petit de 14 KB qu'avant.

**Le reste du programme.** Le lecteur du package et, sur la machine du serveur, son follower sont des domains du
processus du programme, et OCaml 5 arrête chaque domain à chaque collection mineure du garbage collector (la partie qui
libère la mémoire que plus rien n'utilise), alors que l'état du follower vit dans le tas du programme. Une boucle qui
fait 2 millions de maps (`bench/cesia/gc.ce`, la meilleure de trois, $n = 7$) : 125,8 ms [124,8 ;
131,7] seule, 126,9 [125,1 ; 129,0] avec une connexion locale ouverte ; par TLS, 124,9 et 128,2 avec elle ; pendant que
64 writers écrivent et que le follower applique leurs groupes, 140,7 ms seule et 149,4 avec elle (les intervalles se
recouvrent ; le serveur des writers et le benchmark se partagent les cœurs de la machine). Au repos, une connexion ne
coûte rien de mesurable au programme.

**Le fan-out d'une question vivante** (sa distribution à beaucoup de lecteurs), en µs entre le reçu d'une écriture et
le changement d'une fiber (`bench/cesia/watch.ce` : N fibers suivent les factures impayées d'un client, un seul watch
partagé, pendant que le programme écrit 50 factures de ce client l'une après l'autre, chacune son propre groupe ; le
programme sur la machine du serveur, donc son follower calcule les changements ; $n = 5$ tours, un serveur démarré de
la même base pour chacun) :

| fibers qui suivent | une livraison, p50 | la dernière fiber de chaque groupe, p50 | son p99 |
|---:|---:|---:|---:|
| 1 | 19 [7 ; 21] | 19 | 68 |
| 100 | 359 [300 ; 556] | 475 [390 ; 790] | 2 505 |
| 1 000 | 3 756 [3 262 ; 4 325] | 5 420 [4 206 ; 7 141] | 15 204 |
| 2 500 | 12 901 [11 846 ; 16 575] | 17 597 [16 626 ; 21 970] | 35 810 |
| 10 000 | 66 073 [63 702 ; 71 294] | 90 119 [86 154 ; 101 859] | 129 904 |

- Une fiber reçoit son changement 19 µs après le reçu de l'écriture : le follower l'a calculé pendant le fsync. Les
  changements d'un groupe coûtent autant pour 1 ou 10 000 watches d'une question (une seule évaluation,
  [serveur](server.md#ce-que-coûte-un-watch)) ; ce qui grandit, c'est la livraison à chaque fiber, environ 9 µs par
  fiber à 10 000 : un réveil depuis le domain du follower, la fiber du package qui remplit le channel, et le channel
  jusqu'à la fiber qui suit. Les channels de Cesia seuls (un seul envoyeur, 10 000 fibers qui lisent chacune son
  channel) mettent 57 ms à atteindre la dernière fiber : le chemin du package coûte environ le double.
- À côté de `LISTEN`/`NOTIFY` de PostgreSQL avec un serveur Go (mesuré sur la même machine le 2026-11-11 avec PostgreSQL 18.6 et Go 1.26.3, par un banc d'essai hors de ce dépôt ; du commit à
  l'écran, sa WebSocket comprise) : 137 µs pour 1 écran, 538 pour 100, 2 822 pour 1 000. À 1 et à 100, le programme
  Cesia a son changement plus tôt, avant toute WebSocket ; à 1 000, Go passe devant, son fan-out sur 4 cœurs contre un
  seul domain de Cesia.
- 10 000 écrans d'un seul programme : 90 ms jusqu'à la dernière fiber, avant leurs WebSockets. Un programme serveur
  lancé par `cesia run --workers 4` tient 2 500 écrans par processus, chaque processus avec sa propre connexion et son
  watch : 17,6 ms jusqu'à la dernière fiber.

**Sous des écritures soutenues.** Les updates de TechEmpower (une requête : 20 lectures locales, puis une écriture
de 20 faits ; 32 connexions ; la base fusionne son delta toutes les quelques secondes), le 2026-11-25, la machine
partagée avec d'autres travaux (charge de 3,6 à 11,8), chaque côté dans son propre processus sur la même base, servis
tour à tour, à côté d'un serveur Go sur PostgreSQL 18.6 comme témoin (`net/http` et `pgx`, les mêmes tests) :

| | plaintext, le premier tiers des tours, puis le dernier | RSS après environ 20 minutes d'écritures : un programme qui ne fait que suivre ; un programme qui lit et écrit |
|---|---:|---:|
| Cesia d'avant 1.3 et le client d'avant ces corrections | 29 950 puis **14 852** par seconde | **322 MB** ; **196 MB** |
| Cesia 1.3 et cette version | 29 075 puis 35 690 | 51 MB ; 64 MB |
| Go et PostgreSQL | 42 247 puis 65 086 | son processus 25 à 28 MB ; PostgreSQL 109 à 199 |

- Le débit (12 tours de 15 s d'updates et 5 s de plaintext, 19 minutes) : avant, un programme tombait de moitié après
  quelques minutes et ne revenait jamais, plaintext compris, pendant que Go montait à mesure que la machine se
  libérait. La cause était dans Cesia : une fois un quart de sa limite de mémoire réservé, il vérifiait la limite à
  chaque grande allocation, en demandant chaque fois à OCaml la taille de son heap ; un programme `std/http` sans base
  tombait pareil (29 294 puis 14 918). Cesia 1.3 regarde une fois par quart. (Ces tours tournaient avec la première
  des deux corrections ci-dessous, qui ne changent que les pages gardées.)
- La mémoire (20 minutes, deux writers tour à tour, 10 minutes d'écritures chacun, un programme qui ne fait que suivre
  à côté) : la copie locale gardait les pages de chaque run qu'un merge avait remplacé jusqu'à ce que son cache, 256
  MB, soit plein, une base entière à chaque merge ; et les lectures faites pendant que la copie posait ses états sur la
  nouvelle base relisaient l'ancienne, pour de bon (avec la première correction seule, le writer montait encore à
  119 MB). Maintenant les runs remplacés sortent une fois les nouveaux états publiés, et les pages relues sortent au
  merge suivant. Le débit du writer est resté stable : 1 430 puis 1 384 par seconde.
- Là où Go gagne : le plaintext, 1,8 fois ; et son processus tient moins de la moitié de la mémoire (28 contre 64 MB),
  son pool ne tenant aucune copie des données, même si avec leur base les deux côtés pèsent à peu près autant
  (PostgreSQL de 109 à 199 MB, le serveur Cepheus de 115 à 130). Les updates de Cesia passent devant ici : 1 870
  contre 1 662 par seconde au dernier tiers.

**À côté des géants.** Aucun client Cesia de PostgreSQL n'existe (le `std/sql` de Cesia parle à SQLite) ; PostgreSQL est
donc mesuré par sa bibliothèque C, le client le plus rapide qu'il ait : un programme Cesia sur la machine du serveur lit
une ligne 34 fois plus vite que n'importe quel client de PostgreSQL ne le peut, puisqu'il ne fait aucun round trip, et
par le réseau le client Cesia reste dans le coût propre du géant (51,6 contre 52,3 µs, le chiffre de PostgreSQL vient d'autres tours,
[serveur](server.md#la-vitesse-à-côté-de-postgresql)). Là où PostgreSQL gagne : son client se connecte en 2 ms (socket Unix) ou 4,3 ms (TLS), là où le
seul premier appel du client Cesia coûte 13 ms ; et un programme qui ne tient aucune copie des données utilise moins de
mémoire qu'un lecteur local (31 MB pour une base de 1 M de faits, [serveur](server.md#ce-que-cela-coûte)). Les peers
de Datomic lisent aussi dans leur propre processus (« application processes have their own copy of the query engine
and database in local memory »), mais voient les écritures de façon asynchrone sauf s'ils appellent `sync`, un round
trip ([serveur](server.md#à-côté-des-géants-daprès-leur-documentation)) ; une lecture locale de Cepheus est
linearizable sans cela.

## Ce qui n'est pas encore construit

- Les forks d'une base lue au serveur, que le serveur fera.
- Un programme atteint une seule base par connexion : `Connect` à nouveau pour une autre.
- Un changement du kind qu'un lien nomme, ou de son `onDelete`, sur une base qui l'a (une migration) ; `Delete` comme
  opération de `Write`, à côté d'autres dans un même groupe ; une valeur par défaut pour un lien (le `SET DEFAULT` de
  SQL) ; l'effacement d'une chose supprimée de l'historique.
- Les fenêtres : les frames `RANGE` (les lignes égales dans l'ordre comptées ensemble, et les frames d'une durée de
  dates), `Next` (le `lead` de SQL : `Prev` dans l'ordre inverse), `ntile`, `percent_rank`, une `Variance`, un
  `Stddev` ou un quantile mobiles, et un watch d'une question avec des fenêtres ou `Each`.

## Références

- **[Ngo 2013]** H. Q. Ngo, C. Ré, A. Rudra. Skew Strikes Back: New Developments in the Theory of Join Algorithms.
  *SIGMOD Record* 42(4), 2013. https://doi.org/10.1145/2590989.2590991 — Generic Join, que fait tourner `Find`.
- **[Herlihy 1990]** M. P. Herlihy, J. M. Wing. Linearizability: A Correctness Condition for Concurrent Objects.
  *ACM TOPLAS* 12(3), 463–492, 1990. https://doi.org/10.1145/78969.78972 — ce que garantit une lecture locale.
- **[Terry 1994]** D. B. Terry et al. Session Guarantees for Weakly Consistent Replicated Data. *PDIS* 1994.
  https://doi.org/10.1109/PDIS.1994.331722 — read your writes et monotonic writes, que gardent les appels d'une fiber.
- **[Ongaro 2014b]** D. Ongaro. Consensus: Bridging Theory and Practice. Thèse de doctorat, Stanford, 2014, §6.3 —
  les numéros de session qui appliquent une seule fois une écriture renvoyée.
- **[Leis 2015]** V. Leis, K. Kundhikanjana, A. Kemper, T. Neumann. Efficient Processing of Window Functions in
  Analytical SQL Queries. *PVLDB* 8(10), 1058–1069, 2015. https://doi.org/10.14778/2794367.2794375 — l'agrégation
  cumulative, et celle qu'on peut retirer, des fenêtres ([fenêtres](#les-fenêtres--running-rank-prev-each)).
- **[Lemire 2006]** D. Lemire. Streaming Maximum-Minimum Filter Using No More than Three Comparisons per Element.
  *Nordic Journal of Computing* 13(4), 328–339, 2006. https://arxiv.org/abs/cs/0610046 — `Min` et `Max` sur les n
  dernières lignes.
- Les autres travaux sur lesquels repose le serveur : [références](references.md#le-serveur).
