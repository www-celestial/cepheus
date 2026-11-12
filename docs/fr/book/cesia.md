# Cepheus depuis Cesia

Ce chapitre est pour les programmeurs qui écrivent en [Cesia](https://github.com/www-celestial/cesia) : comment un
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
| `cepheus.Date()` | un instant en UTC, gardé en millisecondes depuis 1970 | un nombre de secondes depuis 1970, comme le donne `sys.Now()` ; relu comme un Float | `1794268800.25` |
| `cepheus.Money(scale)` | un décimal exact de `scale` chiffres après la virgule (0 à 18), gardé en unités mineures | un nombre (Int ou Float), arrondi à l'échelle ; relu comme un Float | `1200.5` |
| `cepheus.Link()` | une autre chose de la base | son identifiant, un Int | `65536` |

Chacun prend `unique = false` et `many = false`. Money est exact dans la base (un entier d'unités mineures, donc les
sommes y sont exactes, `Sum` compris) et un Float en Cesia : un montant d'au plus 15 chiffres significatifs, comme
1 234 567 890 123,45, écrit puis relu, donne les mêmes unités mineures (un flottant de 64 bits en est à moins d'une
demi-unité) ; au-delà, ses derniers chiffres s'arrondissent.

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
question, pas des filtres après elle. Toute autre condition est à Cesia, sur les lignes qu'elle donne (`list.Filter`).

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

La facture de 10 est sous 50 : la ville de Bo est maintenant Lyon, et sa seule facture n'est pas comptée.

## Watch : les questions vivantes

Une **question vivante** (live question) est un `Find` qui reste ouvert. `cepheus.Watch(n, question, db, size = 64)`
prend la même question que `Find` et donne un `Ok` de `{Changes, Watch}` : `Changes` est un **channel** de Cesia (une
queue entre fibers, c'est-à-dire une file qui porte des valeurs d'une fiber à une autre, lue par `fiber.Receive` ou
`for` ; le livre de Cesia, chapitre « Fibers ») qui tient au plus `size` messages. Ce que donne `cepheus.Watch` est un
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
Ok({Group: 10, Rows: [{Invoice: 65538, Total: 80.5}], Added: missing, Removed: missing})
Ok({Group: 11, Rows: missing, Added: [{Invoice: 65543, Total: 45.0}], Removed: []})
Ok({Group: 12, Rows: missing, Added: [], Removed: [{Invoice: 65543, Total: 45.0}]})
```

- Un changement ne vient que quand les lignes changent, et seulement une fois son groupe sur le disque du serveur (G1) :
  un écran ne montre jamais une écriture qu'un crash pourrait défaire.
- Les lignes sont celles de `Find`, avec leurs répétitions : un `Give` qui laisse de côté une variable donne une ligne
  pour chaque binding, comme le fait `Find`. Les agrégats (`Sum`, `Count`, `Min`, `Max`) se suivent aussi : un
  changement retire alors l'ancienne ligne d'un groupe et ajoute la nouvelle.
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

Comment, en bref ([le serveur](server.md#lectures-locales-g15) le raconte en entier) :

- Le serveur passe au programme les fichiers de run de la base, déjà ouverts (`SCM_RIGHTS` : un socket Unix peut porter
  des fichiers ouverts d'un programme à un autre), si bien que le programme n'a besoin d'aucun droit sur les fichiers du
  serveur, et que son token décide de ce qu'il peut lire (G16).
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
pages de la base (256 MB au plus) et les changements depuis le dernier merge
([serveur](server.md#ce-que-cela-coûte)).

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
| `invalid` | une valeur du mauvais type, un champ que le kind n'a pas, un kind non déclaré dans cette base, une question que le moteur refuse, une adresse sans `ca` par le réseau | corriger l'appel |
| `damaged` | une page d'un fichier de run ne s'est pas vérifiée contre son CRC | l'exploitation du serveur : [opérations](operations.md) |
| `io`, `busy` | le disque du serveur a lâché, ou un autre processus tient la base | l'exploitation du serveur |
| `closed` | la base a été fermée par `Close` | se reconnecter |
| `auth`, `denied` | le token est inconnu, ou n'a pas le droit sur cette base (G16) | les droits du token : `cepheus token add` |
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
| par TCP et TLS 1.3 (loopback) | 51,6 [44,1 ; 63,4] | 37,1 [31,3 ; 46,8] | 49,6, dans d'autres tours ([serveur](server.md#la-vitesse-à-côté-de-postgresql)) |
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

**À côté des géants.** Aucun client Cesia de PostgreSQL n'existe (le `std/sql` de Cesia parle à SQLite) ; PostgreSQL est
donc mesuré par sa bibliothèque C, le client le plus rapide qu'il ait : un programme Cesia sur la machine du serveur lit
une ligne 34 fois plus vite que n'importe quel client de PostgreSQL ne le peut, puisqu'il ne fait aucun round trip, et
par le réseau le client Cesia reste dans le coût propre du géant (51,6 contre 49,6 µs, le chiffre de PostgreSQL vient d'autres tours,
[serveur](server.md#la-vitesse-à-côté-de-postgresql)). Là où PostgreSQL gagne : son client se connecte en 2 ms (socket Unix) ou 4,3 ms (TLS), là où le
seul premier appel du client Cesia coûte 13 ms ; et un programme qui ne tient aucune copie des données utilise moins de
mémoire qu'un lecteur local (31 MB pour une base de 1 M de faits, [serveur](server.md#ce-que-cela-coûte)). Les peers
de Datomic lisent aussi dans leur propre processus (« application processes have their own copy of the query engine
and database in local memory »), mais voient les écritures de façon asynchrone sauf s'ils appellent `sync`, un round
trip ([serveur](server.md#à-côté-des-géants-daprès-leur-documentation)) ; une lecture locale de Cepheus est
linearizable sans cela.

## Ce qui n'est pas encore construit

- Les forks d'une base lue au serveur, que le serveur fera.
- `Not`, `Or`, `Prefix` et `In` dans les questions : pas dans le moteur.
- Un programme atteint une seule base par connexion : `Connect` à nouveau pour une autre.

## Références

- **[Ngo 2013]** H. Q. Ngo, C. Ré, A. Rudra. Skew Strikes Back: New Developments in the Theory of Join Algorithms.
  *SIGMOD Record* 42(4), 2013. https://doi.org/10.1145/2590989.2590991 — Generic Join, que fait tourner `Find`.
- **[Herlihy 1990]** M. P. Herlihy, J. M. Wing. Linearizability: A Correctness Condition for Concurrent Objects.
  *ACM TOPLAS* 12(3), 463–492, 1990. https://doi.org/10.1145/78969.78972 — ce que garantit une lecture locale.
- **[Terry 1994]** D. B. Terry et al. Session Guarantees for Weakly Consistent Replicated Data. *PDIS* 1994.
  https://doi.org/10.1109/PDIS.1994.331722 — read your writes et monotonic writes, que gardent les appels d'une fiber.
- **[Ongaro 2014b]** D. Ongaro. Consensus: Bridging Theory and Practice. Thèse de doctorat, Stanford, 2014, §6.3 —
  les numéros de session qui appliquent une seule fois une écriture renvoyée.
- Les autres travaux sur lesquels repose le serveur : [références](references.md#le-serveur).
