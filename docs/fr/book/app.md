# Une vraie application : factures et clients

Cette page construit une application entière sur cette pile, pas à pas, de `cesia new` à un service en production :
une application de factures et de clients écrite en [Cesia](https://github.com/www-celestial/cesia-lang), ses données dans un
serveur Cepheus, ses écrans tenus à jour en direct par `std/live` de Cesia, et ses tests end-to-end (des tests de
l'application entière, faits comme un utilisateur, dans un vrai navigateur) qui pilotent Firefox par Ceti (un projet qui
commande Firefox depuis un programme ou un test Cesia). Son code est dans
[`examples/invoices`](https://github.com/www-celestial/cepheus/tree/main/examples/invoices) de ce dépôt, environ
1 600 lignes de Cesia, et 460 de tests ; chaque étape ci-dessous montre la partie qui compte et nomme le fichier qui
contient le reste. Chaque commande a été lancée telle qu'elle est écrite, et ce qui la suit est ce qu'elle a affiché
(`/home/you` tient la place du dossier personnel).

## Ce que vous construisez

- **Des clients** (nom, e-mail, ville) et **des factures** (un client, une date, une échéance, des lignes d'une
  quantité et d'un prix, un statut `unpaid`, `paid` ou `late` — impayée, payée ou en retard —, un total calculé à
  partir des lignes) : créés, modifiés, listés et supprimés, chacun avec ses vérifications (une facture payée reste
  telle qu'elle est ; un client qui a des factures reste).
- **Des listes** par pages, qui reprennent après une ligne, jamais par un offset (un décalage : sauter les n premières
  lignes), triées, avec une recherche à mesure qu'on tape, et des filtres.
- **Un tableau de bord en direct** : ce qui n'est pas payé, ce qui est en retard, et les derniers paiements, qui
  changent d'eux-mêmes dans chaque page ouverte dès que quelque chose change.
- **Des utilisateurs** : un admin (l'administrateur), qui fait tout, et un comptable, qui ne fait que lire et ajouter
  des factures, et dont les requêtes vont à la base par un token (le secret qu'un programme présente au serveur pour
  prouver ses droits) qui ne peut rien lire d'autre.
- **Une règle** de la base (un énoncé « si ces faits sont là, ce fait-là l'est aussi » : un client qui a une facture en
  retard est en défaut de paiement) et **une contrainte** (pas de facture d'un client supprimé), que Cepheus fait
  respecter à chaque écriture.
- **Un export CSV** (un fichier texte, une ligne par enregistrement, les champs séparés par des virgules, que lit un
  tableur), **des sauvegardes**, 10 000 clients et 100 000 factures de données inventées chargés en 6 secondes environ,
  des tests unitaires, des tests end-to-end dans Firefox, et la vitesse mesurée de chaque page.

## Ce qu'il faut

- Cepheus compilé avec le moteur de son client Cesia, et la commande `cepheus` dans le `PATH` : les étapes 1 et 2 du
  [démarrage rapide](quickstart.md). Le checkout (la copie locale du dépôt git) est ici `~/cepheus`.
- Cesia 1.1 ou plus récent, celui contre lequel le moteur a été compilé ; il apporte libsodium (une bibliothèque de
  cryptographie), dont `std/crypto` se sert pour les mots de passe.
- Pour les tests end-to-end : Firefox, et un checkout de Ceti, ici `~/ceti`. Pour les mesures : ApacheBench (`ab`, un
  outil qui envoie des requêtes HTTP en nombre et mesure leurs réponses).

## 1. Le projet

```sh
cd ~
cesia new invoices
```

```text
std/ holds the libraries of Cesia 1.1.0.
Created invoices. Run it: cd invoices && cesia do run
```

Copiez-y les fichiers de l'exemple (ils remplacent le `src/main.ce` qu'a écrit `cesia new`), puis mettez les deux
dépendances (le code d'autres projets que l'application utilise) dans `deps/` :

```sh
cd ~/invoices
cp -R ~/cepheus/examples/invoices/cesia.toml ~/cepheus/examples/invoices/src ~/cepheus/examples/invoices/tests ~/cepheus/examples/invoices/tools ~/cepheus/examples/invoices/bench .
CEPHEUS=~/cepheus CETI=~/ceti tools/deps.sh
```

`cesia.toml` nomme les dépendances comme le font les packages de Cesia (un package : un dossier de fichiers Cesia
groupés sous un nom), par un dépôt et un tag (le nom git d'une version) :

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

Ni l'une ni l'autre n'a encore de release marquée d'un tag (une version publiée), donc `cesia pkg install` ne peut pas
aller les chercher : `tools/deps.sh` fait ce qu'il ferait, à partir des deux checkouts. Il copie le package Cesia de
Cepheus et son **moteur** (la partie OCaml du client, compilée avec le checkout de Cepheus,
[le package](cesia.md#le-package)) dans `deps/www-celestial/cepheus`, le `src/browser` de Ceti dans
`deps/www-celestial/ceti`, et écrit `cesia.lock`, l'empreinte de chaque fichier, que Cesia vérifie avant de charger un
fichier. Sans `CETI`, il n'installe que Cepheus : ce qu'il faut à l'application pour tourner.

Les dossiers du projet :

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

Chaque programme a son propre dossier : les fichiers d'un même dossier forment un seul package, donc deux programmes
côte à côte partageraient leurs noms.

## 2. Un serveur de base de données pour l'application

Un serveur à elle, dans `~/invoices-db`, avec une base, `invoices` :

```sh
cepheus cluster init invoices --dir ~/invoices-db
sed -i 's/^name = "main"/name = "invoices"/' ~/invoices-db/cluster.toml
```

```text
/home/you/invoices-db/srv1.pem
/home/you/invoices-db/srv1.key
/home/you/invoices-db/cluster.toml
```

L'application présente au serveur deux **tokens**, les secrets qui donnent des droits sur une base
([droits](server.md#les-droits-g16)) : le sien, qui écrit ; et celui du comptable, qui ne lit et n'ajoute que les kinds
`invoice` et `line` (un kind regroupe sous des noms de champs les propriétés d'une sorte de chose ; la base stocke des
faits, des triplets chose, propriété, valeur, où une chose est un numéro et une propriété un attribut nommé et typé), et
`counter`, qui numérote les factures :

```sh
cd ~/invoices-db
(umask 077
 cepheus token add web --database invoices=write --config cluster.toml > web.token
 cepheus token add books --database "invoices=read:invoice,line,counter;add:invoice,line,counter" --config cluster.toml > books.token
 cepheus token add ops --admin --config cluster.toml > ops.token)
cepheus token list --config cluster.toml
cepheus serve --config ~/invoices-db/cluster.toml &
```

```text
cepheus: token web added to ./tokens.toml; it is shown only now
cepheus: token books added to ./tokens.toml; it is shown only now
cepheus: token ops added to ./tokens.toml; it is shown only now
web invoices=write
books invoices=read:invoice,line,counter;add:invoice,line,counter
ops admin
cepheus: ready in 33.0 ms: invoices at group 1; socket /home/you/invoices-db/run/.s.cepheus.7400, tcp 127.0.0.1:7400; 4 I/O domains, at most 512 connections; server cph-s-9fec02740f6f3f07, cluster cph-c-b13d6097382a6ee2
```

`umask 077` rend les fichiers des tokens lisibles par vous seul. Pourquoi deux tokens pour une seule application :
chaque requête d'un comptable lit et écrit par le second, donc une page qui montrerait un client à un comptable est
refusée deux fois, par l'application (un 403, le code HTTP « interdit ») et, si l'application avait un bug, par la base
elle-même (`denied`). La protection ne repose pas sur le seul code de l'application. Le prix : un token qui a des droits
par kind ne lit jamais dans la mémoire même du programme (ses lectures vont au serveur par son socket, le canal du noyau
qui le relie au serveur : [droits](server.md#les-droits-g16)), ce que montrent les mesures plus bas.

L'application lit ses réglages dans son environnement :

```sh
export CEPHEUS_URL="cepheus://localhost:7400/invoices?socket=$HOME/invoices-db/run"
export CEPHEUS_TOKEN=$(cat ~/invoices-db/web.token) CEPHEUS_BOOKS_TOKEN=$(cat ~/invoices-db/books.token)
```

## 3. Les kinds, la règle et la contrainte

`src/invoices/kinds.ce` déclare ce que tient la base. Un **kind** est une sorte de chose et ses champs ; chaque champ
est une propriété de la base, comme `invoice/Total` ([kinds](cesia.md#les-kinds-et-les-valeurs-quils-tiennent)) :

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
Counter = cepheus.Kind("counter", {Name: cepheus.Text(unique = true), Last: cepheus.Int()})
```

Les choix qu'il contient :

- **`BillTo`** est le nom du client tel qu'il était quand la facture a été faite, comme le garde une vraie facture : le
  comptable, qui n'a pas le droit de lire les clients, voit quand même à qui chaque facture est adressée.
- **`Search`** contient un nom en minuscules. `cepheus.Prefix` compare des octets
  ([Prefix](cesia.md#prefix--le-début-dun-texte)), donc une recherche qui ignore la casse garde un champ sous la forme
  qu'elle cherche. `text.Lower` ne change que A à Z ; le `Lower` de l'application (`check.ce`) met aussi en minuscules
  les lettres accentuées de Latin-1 (le jeu de caractères des langues d'Europe de l'Ouest), pour que « él » trouve
  « Élodie ».
- **`Total`** est calculé à partir des lignes quand une facture est écrite, en centimes, exactement : `Money(2)` garde
  des unités mineures (les centimes, comptés comme un entier).
- Un **`Counter`** (un compteur) garde le dernier numéro qu'il a donné ; celui qui s'appelle `invoice` numérote les
  factures (étape 5).
- **`Overdue`** n'est jamais écrit par l'application : la base le dérive. Chaque client a un **`Name`** (`ClientForm` le
  vérifie) : un client supprimé n'en a pas.

Les deux **règles** ([les règles depuis Cesia](cesia.md#règles)) :

```text
Overdue = cepheus.Rule("overdue", 2, (c, i) -> {Where: [[i, Invoice.Client, c], [i, Invoice.Status, "late"]], Then: [c, Client.Overdue, true]})
NoInvoiceOfDeleted = cepheus.Rule("no-invoice-of-a-deleted-client", 3, (c, i, n) -> {Where: [[i, Invoice.Client, c], cepheus.Not([c, Client.Name, n])], Then: cepheus.Never})
```

- `overdue` : un client qui a une facture en retard est en défaut de paiement. La base ajoute le fait dans le groupe
  (une écriture de plusieurs faits, appliquée tout entière ou pas du tout) qui met une facture en retard, et le retire
  dans le groupe qui paie la dernière facture en retard du client, puisqu'il ne lui reste alors plus de preuve :
  l'application ne fait que lire `Client.Overdue`, sur la page du client.
- `no-invoice-of-a-deleted-client` est une **contrainte** : un groupe qui lui donnerait une réponse est refusé tout
  entier. Son `Not` est vrai quand le client n'a aucun nom : `n` n'est dans aucun autre pattern (un pattern est un
  triplet de la question, dont la chose et la valeur sont des constantes ou des variables), il appartient donc au Not
  lui-même (« il n'existe pas de `n` tel que... »). Supprimer un client vérifie d'abord qu'il n'a pas de facture, pour
  un message clair ; mais entre cette vérification et la suppression, une autre requête pourrait lui en donner une, et
  `Expect` ne vérifie que les faits propres d'une chose, pas qu'aucune facture ne pointe vers elle. La suppression
  retire les champs du client, son nom avec eux : celui des deux groupes qui vient en second est refusé par la base,
  dans un ordre comme dans l'autre, et une facture d'un client qui n'a jamais existé l'est aussi.

`src/main.ce` se connecte avec chaque token et définit les règles à chaque démarrage : `cepheus.Define` n'écrit que
celles qui sont nouvelles ou changées.

```text
full = ready("connect", cepheus.Connect(url, invoices.Kinds, token = setting("CEPHEUS_TOKEN")))
books = ready("connect for the accountant", cepheus.Connect(url, invoices.Books, token = setting("CEPHEUS_BOOKS_TOKEN")))
ready("rules", cepheus.Define(invoices.Rules, full))
```

## 4. Ce qu'envoie un visiteur

`src/invoices/check.ce` lit chaque formulaire avant que quoi que ce soit ne soit écrit ou demandé. Un champ est un texte
de taille bornée (un nom 120 octets, un e-mail 254, un libellé 200), de l'UTF-8 valide (le codage standard du texte),
sans caractères de contrôle ; un id est un nombre entier au-dessus de 0, de 12 chiffres au plus ; une date s'écrit
`2026-11-13` et pas autrement ; un prix a au plus deux décimales et vaut au plus 1 000 000 000 ; une facture a de 1 à 50
lignes, chacune d'une quantité de 1 à 1 000 000. Une vérification donne un `Ok` des valeurs, ou un `Err` d'une map qui
associe à chaque champ faux son message, que le formulaire montre à côté du champ :

```text
ClientForm({name: "", email: "nobody", city: "Lyon"})      (* Err({Name: "A name of 1 to 120 bytes, without control characters.", Email: "An e-mail address, as ada@example.com."}) *)
ClientForm({name: " Ada ", email: " ADA@Example.COM ", city: "Lyon"})   (* Ok({Name: "Ada", Search: "ada", Email: "ada@example.com", City: "Lyon"}) *)
```

Le serveur accepte des corps de requête de 64 KiB au plus (`maxBody` de `http.Serve` ; un formulaire de 50 lignes fait
environ 30 KB), et un curseur de page (la ligne d'où reprend la page suivante, étape 6) de 2 KB au plus.

## 5. Écrire : des factures avec leurs lignes, payées une seule fois

`src/invoices/invoices.ce`. Une facture et ses lignes forment **un seul groupe**, tout ou rien : `cepheus.New(k)` nomme
la k-ième chose nouvelle du groupe, donc les lignes pointent vers la facture avant qu'elle ait un id
([Write](cesia.md#write--des-groupes-de-faits-tout-ou-rien)) :

```text
defn AddInvoice(f, billTo, by, db)
  c = invoiceCounter(db)?
  inv = cepheus.New(1)
  ops = list.Concat([cepheus.Incr(c, Counter.Last, into = [inv, Invoice.Number]), cepheus.Add(inv, Invoice.Client, f.Client), cepheus.Add(inv, Invoice.BillTo, billTo),
                     cepheus.Add(inv, Invoice.Search, Lower(billTo)), cepheus.Add(inv, Invoice.Date, f.Date), cepheus.Add(inv, Invoice.Due, f.Due),
                     cepheus.Add(inv, Invoice.Status, "unpaid"), cepheus.Add(inv, Invoice.Total, f.Total)], lineOps(inv, f.Lines, 2))
  done = cepheus.Write(ops, db, by = by, why = "invoice added")
  if result.IsErr(done) and done.Error.Code == "unique"
    CatchUpNumbers(db)?
    done = cepheus.Write(ops, db, by = by, why = "invoice added")
  end
  result.Ok({Invoice: done?.Things[1]})
end
```

- Les numéros se suivent sans trou, comme la loi de beaucoup de pays le demande pour les factures. Lire le plus grand
  numéro et écrire ce numéro plus un ne conviendrait pas : deux requêtes qui le lisent en même temps prennent le même,
  et l'une d'elles doit réessayer (50 à la fois : 2 905 essais sur 4 200 ont échoué). Le numéro est plutôt le suivant
  du compteur, que la base prend dans le groupe qui crée la facture (`cepheus.Incr`,
  [Write](cesia.md#write--des-groupes-de-faits-tout-ou-rien)) : des groupes qui comptent en même temps n'entrent jamais en
  conflit et ne sautent jamais un numéro, un groupe refusé n'en prend aucun, et des factures créées en même temps
  partagent les fsync du serveur (l'appel système qui attend que les octets écrits soient vraiment sur le disque) au
  lieu de s'attendre les unes les autres.
- `invoiceCounter` trouve le compteur par son nom ; la première facture le crée, à partir du plus grand numéro que
  tient la base, pour qu'une base remplie avant lui reprenne à partir de là (son nom est `unique` : de deux requêtes
  qui le créent en même temps, l'une le crée et l'autre le trouve). Un programme qui numérote des factures sans le
  compteur, comme le fait le seed (le programme qui remplit la base de données inventées), le laisse en arrière : le
  groupe suivant est refusé comme `unique` (`Number` est unique), `CatchUpNumbers` fait monter le compteur jusqu'au plus
  grand numéro, et la facture est écrite de nouveau. Le seed l'appelle une fois, à sa fin.
- `by` est l'id de l'utilisateur et `why` dit ce qu'a fait le groupe : les deux restent avec le groupe dans
  l'historique de la base.

Payer est une vérification **optimiste** (rien n'est bloqué pendant la lecture ; l'écriture vérifie que rien n'a
changé depuis) : le groupe est refusé si le statut n'est plus celui qui a été lu, donc une facture n'est payée qu'une
fois, quoi que fassent deux pages au même instant :

```text
done = cepheus.Write([cepheus.Expect(id, Invoice.Status, inv.Status), cepheus.Add(id, Invoice.Status, "paid"), cepheus.Add(id, Invoice.PaidAt, now)], db, by = by, why = "invoice paid")
```

Modifier une facture (`EditInvoice`) et en supprimer une (`DeleteInvoice`) attendent son statut de la même manière, et
refusent une facture payée : une facture payée est une pièce des comptes. `MarkLate` met en retard les factures
impayées dont l'échéance est passée, 500 par groupe, chacune attendue impayée ; `src/main.ce` le lance chaque minute,
en même temps qu'il met fin aux sessions expirées.

## 6. Lire : pages, recherche et filtres

`src/invoices/paging.ce` donne une page de n'importe quelle question triée. Une page, ce sont les lignes **après** une
ligne, dans l'ordre de la question (`After`, [pages](cesia.md#sort-limit-et-after--des-pages)), jamais « sauter les 4 000
premières » : une page à 50 000 lignes de profondeur coûte ce que coûte la première, et une ligne écrite entre deux
pages n'en déplace aucune. La page d'avant est la même question avec chaque clé de `Sort` inversée, après la première
ligne de la page ; `Page` demande une ligne de plus qu'il n'en montre, pour savoir s'il y a une page suivante. Le
curseur d'un lien est la dernière ligne (ou la première, pour la page d'avant), en Base64 (un codage en lettres et
chiffres qui passe dans une adresse) de son JSON (le format texte des objets de JavaScript) : un visiteur peut en écrire
un à la main, donc il est lu comme toute entrée, un objet JSON de 2 KB au plus, dont la question vérifie les champs
selon leurs types (un faux donne un 400, le code HTTP « requête invalide »).

**Une question par page.** Une page de factures est une seule question triée des sept champs qu'une ligne de la liste
montre (`invoicesQuery` : numéro, destinataire, date, échéance, statut, total, et les filtres ; huit avec la
recherche), son ordre la clé de chaque tri, puis l'échéance et la facture (`sortKeys`), si bien que deux factures
d'une même date viennent toujours dans un seul ordre. Le moteur parcourt l'index (la copie triée des faits où la base
cherche) de la première clé et lit les autres champs de chaque ligne une fois qu'elle passe les filtres ([comment elle
est répondue](cesia.md#sort-limit-et-after--des-pages)) : 62 µs par page dans la mémoire de l'application, contre 113
pour la page de ses clés puis de leurs lignes que l'application demandait avant ([ce que cela
coûte](#14-ce-que-cela-coûte)). Le curseur d'un lien est une ligne des sept champs. Un lien enregistré avant, dont le
curseur est une ligne de cinq clés (`Invoice`, `Number`, `Status`, `Due`, et `X`, le total quand le tri est par total,
sinon la date), marche toujours : `pageCursor` en fait la ligne qu'il représente, ses autres champs lus sur sa facture
(une facture supprimée depuis reçoit des champs vides, qui ne sont jamais comparés : les clés de l'ordre d'avant eux,
son id parmi elles, la placent d'abord), si bien que le lien donne la même page après lui, ou avant lui, qu'avant
(`isPageCursorNewOrOld`, pour chaque ordre). La liste des clients demande d'abord la page de ses clés, puis leurs
e-mails.

**La recherche à mesure qu'on tape** est un `Prefix` sur le nom en minuscules ou sur l'e-mail, l'un ou l'autre, avec
`Or` :

```text
Where: [[c, Client.Name, n], [c, Client.City, y], [c, Client.Search, k], [c, Client.Email, e], cepheus.Or(cepheus.Prefix(k, search), cepheus.Prefix(e, search))]
```

Le script de la page demande `/clients?part=rows&q=...` 100 ms après la dernière touche, et met en place les lignes que
le serveur a faites et échappées (leurs caractères spéciaux du HTML rendus inoffensifs).

**Les filtres** emploient chaque condition d'une question là où elle est naturelle (`filterOf` dans `invoices.ce`) :

- les cases de statut de la liste, une ou deux parmi impayée, en retard et payée : `cepheus.In(s, statuses)` ;
- « en retard ou à échéance dans la semaine » : `cepheus.Or([i, Invoice.Status, "late"], cepheus.And([i, Invoice.Status, "unpaid"], cepheus.Below(u, now + Week)))` ;
- ce que doit un client, et ses factures non payées, sur sa page : `cepheus.Not([i, Invoice.Status, "paid"])`, et la
  somme avec `cepheus.Sum(t)` et `cepheus.Count()`.

Chaque variable d'une question doit être dans un de ses patterns, et on dit à `Find` combien il y en a : ainsi la
liste sans recherche est une question de cinq variables, et avec une recherche, de six.

## 7. Des tests sur des forks

Un **fork** est une base dans la mémoire du programme, avec toutes les vérifications d'une vraie, règles comprises, et
sans serveur ([forks](cesia.md#les-forks)). Chaque test de `src/invoices/store.test.ce` fait un fork de `cepheus.Empty`
avec les kinds et les règles de l'application :

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

et `src/invoices/web.test.ce` demande les routes (une route envoie une méthode et un chemin HTTP à un handler, la
fonction qui répond à la requête) par `http.Handler`, sans réseau : la connexion, les cookies (une petite valeur que le
navigateur garde et renvoie au site à chaque requête), la vérification same-origin (qu'une requête vient bien d'une page
de l'application, étape 8), les rôles, l'échappement, les formulaires, l'export, les en-têtes, un curseur fait à la
main. Les deux chemins d'exécution de Cesia :

```sh
cd ~/invoices
cesia test src
cesia test --no-spec src
```

```text
23 passed, 0 failed
23 passed, 0 failed
```

(Les tests qui se connectent avec un mauvais mot de passe écrivent la ligne de log de l'application, son message de
suivi, `{"level":"warn","message":"sign-in refused"}`, au milieu de ces lignes.) Les tests unitaires sont
`cesia test src` : un `cesia test` seul lancerait aussi `tests/e2e`, qui ont besoin d'un serveur (étape 12).

## 8. L'application web

`src/invoices/web.ce` est l'application : `App(env)` donne ses routes, chacune un handler d'une requête.

**Connecté, et selon le rôle.** Toutes les routes sauf la page de connexion passent par `signed(env, role, handler)` :
il trouve la session du cookie de la requête, refuse un visiteur qui n'en a pas (un GET, la requête HTTP qui lit une
page, est envoyé à `/login`, tout le reste reçoit un 401, le code HTTP « non authentifié ») et un utilisateur d'un autre
rôle (un 403), et donne au handler l'utilisateur avec **la base de son rôle** :

```text
then http.Get("/clients", signed(env, "admin", clientsList))
then http.Get("/invoices", signed(env, "any", invoicesList))
```

```text
u.Db = if u.Role == "admin" env.Full else env.Books end
```

**Mots de passe et sessions** (`auth.ce`). Un mot de passe n'est gardé que sous la forme de son hash Argon2id (un hash
est une empreinte courte calculée à partir d'un texte, qui ne permet pas de retrouver ce texte ; Argon2id est une
fonction de hash faite exprès lente et gourmande en mémoire, pour qu'on ne puisse pas essayer des milliards de mots de
passe ; `crypto.HashPassword`, par libsodium :
[cryptographie](https://github.com/www-celestial/cesia-lang/blob/main/docs/book/crypto.md)). Un identifiant inconnu est
vérifié contre le hash d'un mot de passe que personne n'a, pour qu'il prenne autant de temps qu'un mauvais mot de passe
et que le temps d'une réponse n'apprenne à personne quels identifiants existent ; les deux reçoivent le même message.
Le hash tourne hors du seul thread de l'application (le `slow` de `c.Fn` :
[un appel qui prend du temps](https://github.com/www-celestial/cesia-lang/blob/main/docs/book/c.md#a-call-that-takes-long)) :
pendant qu'un visiteur se connecte, les autres requêtes avancent. Au plus la moitié des cœurs de la machine calculent
un hash à la fois (64 MiB chacun), les autres attendent dans une file de 64 par place, et une de plus reçoit un 500
tout de suite : un flot de connexions prend une mémoire bornée ([les mesures](#14-ce-que-cela-coûte)).
Une session, ce sont 32 octets aléatoires venus du système (`crypto.Random`), envoyés une seule fois dans un cookie ;
la base garde leur hash BLAKE2b (une fonction de hash rapide), donc une copie de la base n'ouvre aucune session. Le
cookie est `HttpOnly` (aucun script ne le lit), `SameSite=Strict` (aucune page d'un autre site ne l'envoie), dure 8
heures, et est `Secure` (envoyé seulement par https) quand l'application sert en https (du HTTP chiffré).

**La vérification same-origin.** Une page d'un autre site pourrait poster un formulaire à l'application avec le cookie
de son visiteur : une *cross-site request forgery* (une requête forgée depuis un autre site). Les navigateurs envoient
l'`Origin` (l'en-tête qui nomme le site d'où part la requête) de chaque requête de ce genre, donc un middleware (du code
placé entre le serveur et ses handlers) refuse toute requête qui change quelque chose (toute méthode sauf GET et HEAD,
les deux qui ne font que lire) à moins que son `Origin` soit le schéma (http ou https) et le `Host` de l'application
elle-même :

```text
if value.IsMissing(origin) or value.IsMissing(host) or (text.Lower(origin) != "http://$(text.Lower(host))" and text.Lower(origin) != "https://$(text.Lower(host))")
  return http.Plain("This request comes from another origin than the app's.", status = 403)
end
```

`std/live` vérifie son WebSocket (une connexion qui reste ouverte entre la page et le serveur, dans les deux sens) de
la même façon.

**Les pages** (`pages.ce`) sont du HTML fait sur le serveur, chaque valeur venue de la base ou d'un visiteur passée par
`http.Escape`, pour qu'un client nommé `<script>` s'affiche comme du texte. Le style et le script sont des routes de
l'application, `/app.css` et `/app.js`, et un middleware donne à chaque réponse une `Content-Security-Policy` (la liste
de ce qu'une page a le droit de charger et d'exécuter) de `default-src 'self'` (pas de code inline, écrit dans la page
elle-même, rien qui vienne d'un autre site), `frame-ancestors 'none'` (aucun site ne peut afficher l'application dans un
cadre), `nosniff` (le navigateur ne devine pas le type d'un fichier), `Referrer-Policy: same-origin` (l'adresse de la
page n'est envoyée qu'à l'application elle-même), `Cache-Control: no-store` (aucune réponse n'est gardée en cache), et
en https `Strict-Transport-Security` (le navigateur n'emploie plus que https pour ce site).

## 9. Le tableau de bord en direct

Les nombres du tableau de bord sont trois **watches** (des questions vivantes : tenues à jour, leur réponse puis ses
changements ; [questions vivantes](cesia.md#watch--les-questions-vivantes)), donnés à la page par `std/live`
([écrans en direct](https://github.com/www-celestial/cesia-lang/blob/main/docs/book/http.md#live-screens-stdlive)).
`live.Route("/live", screen)` les sert ; `screen` tourne quand une page se connecte, trouve son utilisateur par le
cookie de sa requête, et suit les questions par la base de son rôle, chaque watch prenant fin avec la page
(`until = s.Ended`) :

```text
unpaid = cepheus.Watch(2, (i, t) -> {Where: [[i, Invoice.Total, t], cepheus.Not([i, Invoice.Status, "paid"])], Give: {Total: cepheus.Sum(t), Count: cepheus.Count()}}, db, until = s.Ended)?
late = cepheus.Watch(2, (i, t) -> {Where: [[i, Invoice.Status, "late"], [i, Invoice.Total, t]], Give: {Total: cepheus.Sum(t), Count: cepheus.Count()}}, db, until = s.Ended)?
paid = cepheus.Watch(5, LatestPayments, db, until = s.Ended)?
[live.Show("unpaid", unpaid.Changes), live.Show("late", late.Changes), live.Show("payments", paid.Changes)]
```

où `LatestPayments` est une question avec `Sort` et `Limit` ([Sort et Limit dans un
watch](cesia.md#sort-et-limit-dans-un-watch)) : les dix derniers paiements, le plus récent d'abord. Son watch ne tient
que ces dix lignes ; un paiement entre en haut et pousse le dixième dehors, et un paiement qui quitte les dix (sa date
reculée) est remplacé par le onzième, que le watch lit par une page de la question après sa dernière ligne :

```text
LatestPayments(i, p, no, b, t) = {
  Where: [[i, Invoice.PaidAt, p], [i, Invoice.Number, no], [i, Invoice.BillTo, b], [i, Invoice.Total, t]],
  Give: {Invoice: i, PaidAt: p, Number: no, BillTo: b, Total: t},
  Sort: [cepheus.Desc(p), cepheus.Desc(no)],
  Limit: 10,
}
```

et le côté de la page, dans `/app.js`, dessine chaque affichage à mesure qu'il change :

```js
const live = await connect('/live')
live.show('unpaid', rows => tile('unpaid', rows))
live.show('payments', rows => { /* the ten rows, sorted again by PaidAt: live.js holds a show's rows as a set */ })
```

Comment un paiement atteint chaque page ouverte : le groupe est écrit et forcé sur le disque du serveur ; le processus
de l'application, qui suit la base pour ses lectures locales (des lectures dans sa propre mémoire), calcule les
changements des watches à partir du groupe (les totaux par différence,
[comment un changement est calculé](cesia.md#watch--les-questions-vivantes)) et les donne une fois le groupe durable (sur le
disque, à l'abri d'une coupure) ; l'écran de chaque page envoie son changement par son WebSocket ; la page le dessine
à son prochain rafraîchissement. Toutes les pages qui suivent la même question partagent un seul watch. Avant qu'un watch
prenne `Sort` et `Limit`, le tableau de bord suivait chaque paiement des dernières 24 heures et la page gardait les 10
plus récents : sur le seed (les données de départ), 3 410 lignes tenues par chaque page et une première réponse en
6,3 ms, contre 10 lignes et 97 µs maintenant. Le tableau de bord du comptable est le même, par son token ; ses watches sont calculés au serveur, qui les
pousse.

## 10. L'export CSV

`/invoices.csv` donne toutes les factures du filtre de la liste, dans l'ordre de leurs numéros : une question pour les
lignes (pas de page : pas de `Limit`), et une pour les dates de paiement de chaque tranche de 10 000 d'entre elles (un
`In` de 10 000 ids par question ; `In` accepte jusqu'à 100 000 valeurs).
Une cellule qui commence par `=`, `+`, `-`, `@`, une tabulation ou un retour chariot reçoit un `'` devant elle, pour
qu'un tableur n'exécute jamais un nom de destinataire comme une formule (la CSV injection, comme l'appelle l'OWASP, une
fondation qui recense les failles des applications web). Les 100 000 factures du seed s'exportent en 1,2 s environ (une
requête), les 11 006 en retard en 114 ms ([ce que cela coûte](#14-ce-que-cela-coûte)).

## 11. Le faire tourner

Les utilisateurs, avec leurs mots de passe dans l'environnement, jamais sur une ligne de commande, où les autres
utilisateurs de la machine les verraient :

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

`cesia do` lance une tâche de `cesia.toml` avec ses permissions, et affiche la commande qu'il lance. (Une tâche ne prend
pas d'arguments, donc l'identifiant et le rôle viennent aussi de l'environnement.)

Le serveur :

```sh
cesia do serve &
```

```text
> cesia run --allow native=cepheus,ffi=sodium,env=CEPHEUS_URL,env=CEPHEUS_TOKEN,env=CEPHEUS_BOOKS_TOKEN,env=APP_PORT,env=APP_HOST,env=APP_CERT,env=APP_KEY,net=:8090 src/main.ce
{"time":"2026-11-12T23:05:27.255Z","level":"info","message":"ready","Port":8090,"Ms":8.456945419311523}
```

`Ms` est le temps entre la première ligne du programme et son listener (le socket qui attend les connexions) : les
deux connexions, les règles, libsodium.

Ouvrez `http://127.0.0.1:8090/` et connectez-vous comme `ada`. La même chose avec curl (l'outil en ligne de commande qui
envoie des requêtes HTTP), pour voir chaque réponse : la page de connexion d'abord, puis une session, un client, et un
formulaire posté depuis une autre origine :

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

Une facture pour ce client ; puis le comptable, qui n'a pas le droit de voir les clients, la paie et exporte les
factures :

```sh
invoice=$(curl -s -b ada.jar -o /dev/null -w "%{redirect_url}" -H "Origin: $B" -d "client=${client##*/}&date=2026-11-02&due=2026-12-02&label1=Design&quantity1=3&price1=400&label2=Hosting&quantity2=1&price2=80.50" $B/invoices)
echo $invoice
curl -s -c bo.jar -o /dev/null -H "Origin: $B" -d "login=bo&password=another+long+secret" $B/login
curl -s -b bo.jar -o /dev/null -w "%{http_code}\n" $B/clients
curl -s -b bo.jar -o /dev/null -w "%{http_code} %{redirect_url}\n" -H "Origin: $B" -X POST $invoice/pay
curl -s -b bo.jar $B/invoices.csv
```

```text
http://127.0.0.1:8090/invoices/65541
403
303 http://127.0.0.1:8090/invoices/65541
number,date,due,bill_to,status,total,paid_at
1,2026-11-02,2026-12-02,Ada Martin,paid,1280.50,2026-11-12
```

(Les ids sont ceux de la base : ses premières choses ont été les deux utilisateurs et la session d'ada, et la première
facture a créé, avant elle, le compteur des numéros. Le jour du paiement est le jour
UTC.)

**Des données pour l'essayer à sa taille** : `cesia do seed` ajoute 10 000 clients et 100 000 factures de une à cinq
lignes sur l'année passée (2,4 millions de faits), toujours les mêmes : chaque tirage est un hash du numéro de la
facture, et les numéros suivent ceux qui sont déjà là.

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

Les factures entrent par groupes de 20 000, environ 480 000 faits chacun, de façon à prendre le chemin des grands
groupes dans la base (un grand groupe : 20 000 opérations ou plus, toutes des ajouts, qui prend un chemin plus rapide ;
[grands groupes](architecture.md#grands-groupes)). Quand cette exécution a été mesurée, une contrainte, ou une règle
dont la tête (le fait qu'elle conclut) est une propriété à une seule valeur, envoyait un grand groupe sur le chemin
ordinaire du writer (le seul thread, c'est-à-dire fil d'exécution, qui applique les groupes d'une base, un à la fois) ;
et l'application, démarrée plus haut, avait défini ses règles. Dans une base où elles ne sont pas encore définies, le
seed les définit après le chargement, en un seul groupe qui dérive sur tout le chargement, et le seed entier prend
4,84 s ([ce que cela coûte](#14-ce-que-cela-coûte)) ; ici il a pris 12,5 s. Son `Define` n'avait alors rien à écrire,
mais a attendu, comme première lecture après le chargement, que la copie de la base que garde le programme intègre les
groupes du chargement. Désormais, le chemin des grands groupes vérifie les contraintes (avec leur `Not`) et les têtes à
une seule valeur après son point fixe (le moment où les règles ne donnent plus rien de nouveau ;
[règles](rules.md#grands-groupes)) : un chargement dans une base qui a les règles de l'application reste sur ce chemin
(pas mesuré de nouveau ici).

## 12. Tests end-to-end dans Firefox

`tests/e2e/e2e.test.ce` utilise l'application comme le fait un visiteur : Ceti ([son
guide](https://github.com/www-celestial/ceti)) démarre Firefox sans fenêtre, et les tests tapent dans les formulaires et
cliquent. Chaque test sert lui-même l'application, sur un port libre, face à un vrai serveur Cepheus que `tools/e2e.sh`
démarre dans un nouveau dossier, avec les deux tokens, et arrête à la fin quoi qu'il arrive :

- un admin crée un client et une facture par les formulaires, vérifie son total, et la marque payée ;
- deux pages ouvertes : une facture créée, puis payée, dans la première change d'elle-même le tableau de bord de la
  seconde ;
- le comptable n'a pas de lien Clients, reçoit le 403 de l'application sur `/clients`, et son token reçoit `denied` de
  la base pour une question sur les clients ;
- une page d'une autre origine (un autre port) poste un formulaire à l'application avec le cookie du visiteur connecté :
  refusé, et aucun client créé.

```sh
tools/e2e.sh
tools/e2e.sh tests/e2e --no-spec
```

```text
4 passed, 0 failed
4 passed, 0 failed
```

La première exécution crée le profil modèle de Ceti dans `.cesia/firefox`, gardé pour les exécutions suivantes ; aucun
Firefox ne reste quand les tests finissent. Un formulaire posté par un clic emmène la page vers un autre document,
qu'un `Eval` (l'appel de Ceti qui exécute du JavaScript dans la page) lancé avant ne peut pas attendre : les tests
regardent chaque fois `location.origin` dans un `Eval` à part, jusqu'à ce que la page soit là où le formulaire l'a
menée.

## 13. En production

**Le serveur de base de données** tourne comme le dit le [guide de production](production.md) : un service à lui (un
programme que le système démarre et relance de lui-même), un utilisateur à lui, ses données dans `/var/lib/cepheus`,
des sauvegardes chaque nuit et un exercice de restauration chaque mois.

**L'application** sert elle-même en https, par `std/tls` de Cesia (OpenSSL) : `APP_CERT` et `APP_KEY` nomment un
certificat (avec sa chaîne, les certificats intermédiaires qui le relient à une autorité reconnue) et sa clé, et le
cookie est alors `Secure`, avec `Strict-Transport-Security`. La tâche `serve-tls` de `cesia.toml` contient ses
permissions, chacune nécessaire et aucune de plus :

| permission | pour |
|---|---|
| `native=cepheus` | le moteur du client Cepheus : une confiance totale, comme pour une bibliothèque C, puisque son code machine tourne hors des vérifications de Cesia (et peut joindre n'importe quel serveur) |
| `ffi=sodium` | libsodium, pour les mots de passe et les sessions |
| `ffi=ssl`, `ffi=crypto` | OpenSSL, pour https |
| `env=` ses 7 réglages | l'adresse de la base et les deux tokens, le port, l'hôte, le certificat et sa clé |
| `read=/etc/invoices` | le certificat et sa clé |
| `net=0.0.0.0:8443` | écouter sur le port 8443 de toutes les adresses ; rien d'autre du réseau |

Elle n'écrit aucun fichier, et n'en lit aucun hormis les deux de son certificat. Essayé sur cette machine avec un
certificat fait sur place (auto-signé) :

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

Un service, `/etc/systemd/system/invoices.service`, avec ses réglages dans `/etc/invoices/env`, lisible par root seul
(systemd, le gestionnaire de services de Linux, le lit avant d'abandonner ses droits) :

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

`ExecStart` lance la ligne `cesia run` qu'affiche `cesia do serve-tls`, plutôt que `cesia do` : à un arrêt, systemd
envoie TERM (le signal qui demande à un processus de s'arrêter) à chaque processus du service, donc avec `cesia do`
devant, le programme l'entendrait deux fois, de systemd et de `cesia do` qui le transmet, et un second signal d'arrêt
termine un programme Cesia tout de suite au lieu de laisser ses requêtes finir. Lancée comme un service de cet
utilisateur, la même ligne s'arrête proprement :

```sh
systemd-run --user --unit=invoices-guide -p EnvironmentFile=$HOME/invoices-env -p WorkingDirectory=$HOME/invoices -p MemoryMax=1G -p NoNewPrivileges=true -p TimeoutStopSec=70 $(command -v cesia) run --allow native=cepheus,ffi=sodium,env=CEPHEUS_URL,env=CEPHEUS_TOKEN,env=CEPHEUS_BOOKS_TOKEN,env=APP_PORT,env=APP_HOST,env=APP_CERT,env=APP_KEY,net=:8090 src/main.ce
systemctl --user stop invoices-guide
journalctl --user -u invoices-guide -o cat -n 2
```

```text
Stopping [systemd-run] /home/you/cesia/_build/default/src/bin/main.exe run --allow native=cepheus,...
Stopped [systemd-run] /home/you/cesia/_build/default/src/bin/main.exe run --allow native=cepheus,...
```

(Avec `cesia do` à la place, le même arrêt a donné `status=143` : le second signal.)

**Sur chaque cœur.** L'application ne garde aucun état à elle : les sessions sont dans la base, donc
`cesia run --workers 4` lance quatre processus derrière un seul port
([chaque cœur](https://github.com/www-celestial/cesia-lang/blob/main/docs/book/http.md#every-core)). Chacun se connecte à
Cepheus et garde sa propre copie des pages de la base pour ses lectures locales (chaque lecteur tient son cache :
[ce que cela coûte](server.md#ce-que-cela-coûte)), et chacun lance la vérification des retards de chaque minute, que leurs
`Expect` empêchent de s'appliquer deux fois.

**Sauvegardes** : `cepheus-backup` du [guide de production](production.md#les-sauvegardes), pendant que le serveur tourne, puis
l'exercice de restauration sur un autre serveur (ici le serveur en service est arrêté d'abord, puisqu'une copie d'une
base est refusée sur la machine qui fait tourner cette base) :

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

La copie s'ouvre au groupe que tenait le serveur en service (`cepheus status` avec le token ops montrait
`database.invoices.group: 10` avant la copie). L'application, connectée pendant ce temps, a continué à travers le
redémarrage de son serveur : le client se reconnecte de lui-même, et ses lectures sont allées au serveur jusqu'à ce
qu'il suive de nouveau la base.

**Ce qu'il faut surveiller** : l'application écrit une ligne de JSON pour chaque requête (`http.Logger` : sa méthode,
son chemin, son statut et ses millisecondes ; jamais une query, la partie de l'adresse après le point d'interrogation,
ni un cookie ni un corps), `request failed` avec le code et le message d'une erreur causée par le serveur,
`sign-in refused` sans l'identifiant tapé (sinon un mot de passe tapé dans le champ de l'identifiant serait dans le
log), et `keeping failed` si la vérification des retards de la minute échoue ; côté serveur, ce que dit le [guide de
production](production.md#ce-quil-faut-surveiller).

## 14. Ce que cela coûte

Mesuré sur une seule machine (Intel Core i7-4720HQ, 4 cœurs et 8 threads, 11 GB, un SSD SATA, Linux), Cepheus et Cesia
compilés en mode release (optimisé), sur le seed (10 000 clients, 100 000 factures, 300 000 lignes : 30 MB de données),
l'application en un seul processus, la charge envoyée depuis la même machine, chaque partie seule sur la machine (sous
un lock qui tient les autres benchmarks de la machine à l'écart). Chaque nombre est la médiane de 21 tours, avec son
intervalle à 95 % sans hypothèse sur la distribution (les statistiques d'ordre $[x_{(6)}, x_{(16)}]$ des tours,
c'est-à-dire la 6e et la 16e valeur une fois les tours triés) ; le p50 et le p99 d'un tour sont les latences (le temps
d'une requête, de son envoi à sa réponse) que la moitié et 99 sur 100 de ses requêtes n'ont pas dépassées. Les
scripts : `bench/run.sh` (le seed, les démarrages, les pages par ApacheBench, chaque requête sur sa propre connexion),
`bench/actions.sh` (les formulaires, par `bench/load`), `bench/live.sh` (le tableau de bord dans Firefox),
`bench/giants/giants.sh` (à côté de PostgreSQL), `bench/signins` (les pages pendant que des connexions arrivent),
`bench/stats` (les médianes).

**Le démarrage.** Le seed dans une base vide : 4,82 s [4,63 ; 5,22] pour 2,4 millions de faits, surtout le côté Cesia,
qui fabrique les 2,4 millions d'opérations des groupes (une map chacune). Le démarrage du serveur Cepheus sur la base
remplie : 29,6 ms [29,1 ; 30,1]. Le processus de l'application, de sa commande à son port qui accepte une connexion :
78,6 ms [76,9 ; 79,3], dont le `Ms` de sa ligne de log (ses deux connexions, les règles, libsodium) fait environ
41 ms, et le reste est le démarrage de Cesia, la lecture du code de l'application et le premier chargement du moteur
(13 ms, [ce que cela coûte](cesia.md#ce-que-cela-coûte)).

**Les pages**, en ms, avec 1 client (un programme qui envoie les requêtes l'une après l'autre), puis 50 à la fois :

| page | 1 client : p50 | p99 | 50 clients : p50 | p99 | requêtes par seconde à 50 |
|---|---:|---:|---:|---:|---:|
| le plancher : `/app.css`, une constante | 0,11 [0,11 ; 0,12] | 0,20 | 2,75 | 4,10 | 17 969 |
| la page de connexion | 0,12 [0,11 ; 0,12] | 0,26 | 3,09 | 4,85 | 16 300 |
| le tableau de bord (son HTML ; ses nombres arrivent en direct) | 0,19 [0,19 ; 0,20] | 0,36 | 7,63 | 10,7 | 7 183 |
| factures, la première page | 0,77 [0,77 ; 0,78] | 1,13 | 39,5 | 62,2 | 1 402 |
| factures, une page à 50 000 de profondeur | 0,86 [0,85 ; 0,87] | 1,29 | 43,7 | 70,5 | 1 256 |
| factures, impayées ou en retard (`In`) | 1,15 [1,13 ; 1,16] | 1,48 | 58,6 | 93,8 | 928 |
| factures, en retard ou à échéance dans la semaine (`Or`) | 1,43 [1,42 ; 1,44] | 1,79 | 74,7 | 121 | 731 |
| factures, vues par le comptable (lues au serveur) | 1,13 [1,10 ; 1,16] | 1,57 | 50,0 | 77,7 | 997 |
| une facture et ses lignes | 0,29 [0,29 ; 0,30] | 0,51 | 12,8 | 16,0 | 4 352 |
| le formulaire d'une nouvelle facture | 0,26 [0,26 ; 0,27] | 0,47 | 11,4 | 14,0 | 4 932 |
| un client, ce qu'il doit, ses factures non payées | 0,41 [0,40 ; 0,41] | 0,66 | 19,1 | 26,8 | 2 932 |
| clients, la première page par nom | 0,51 [0,50 ; 0,51] | 0,78 | 25,1 | 34,5 | 2 238 |
| clients, la recherche à mesure qu'on tape (« ma ») | 1,65 [1,63 ; 1,66] | 2,08 | 88,8 | 130 | 633 |
| le CSV des factures en retard (11 011 lignes) | 77,0 [76,6 ; 78,3] | | 3 791 | | 12,9 |

- Avec 50 clients à la fois, le seul processus de l'application les sert l'un après l'autre : la latence est environ
  50 fois le travail d'une requête, et les requêtes par seconde disent ce que donne un cœur. `cesia run --workers 4`
  sert le même port depuis 4 processus
  ([chaque cœur](https://github.com/www-celestial/cesia-lang/blob/main/docs/book/http.md#every-core)).
- La liste du comptable coûte 0,5 ms de plus avec un seul client, un round trip (l'aller-retour d'une requête et de sa
  réponse) vers le serveur par son socket (son token lit là-bas, pas dans la mémoire de l'application), et en sert
  davantage à 50, puisque les domains du serveur (des fils d'exécution d'OCaml qui tournent en parallèle, chacun sur
  son cœur) font la lecture à côté du cœur de l'application.
- La liste des clients par nom lit l'index des noms dans leur ordre, comme le fait une liste par un nombre : 0,51 ms,
  là où elle lisait chaque client (10 000) avant de garder les 20 premiers (13,2 ms, 75 par seconde à 50, mesuré le
  2026-11-13). La recherche à mesure qu'on tape coûte 0,46 ms de plus qu'alors : ses clients dont le nom commence par
  « ma » viennent après tous les « A » à « L » dans cet ordre, donc le parcours dans l'ordre de l'index n'en trouve
  aucun avant son budget, et le heap répond ([Sort, Limit et After](cesia.md#sort-limit-et-after--des-pages)).
- Le CSV est surtout du travail de Cesia : la question prend quelques ms ; mettre en forme 11 000 lignes et leurs dates
  fait le reste.
- **Une page en une seule question** (2026-11-20, mesuré après le tableau ci-dessus, dans la mémoire de l'application,
  `InvoicesPage` 200 fois par round, 21 rounds alternés avec l'application telle qu'elle était, la page de ses clés
  puis de leurs lignes ; p50 en µs, le rapport apparié par round) : la première page 62,0 [61,0, 62,9] contre 113 [111,
  114], 0,550 [0,535, 0,564] ; une page à 50 000 de profondeur 67,9 contre 118, 0,575 [0,561, 0,601] ; la recherche
  par préfixe du destinataire (« ad ») 556 [551, 562] contre 525 [523, 540], 1,053 [1,041, 1,063] : là, une seule
  question est 5 % plus lente, puisqu'elle lit les sept champs des lignes que ses fenêtres trouvent au-delà de la page,
  là où la page des clés en lisait cinq.
- **Les paiements du tableau de bord** (le même jour, le watch seul dans la mémoire de l'application, sa première
  réponse 20 fois par round, 21 rounds alternés) : les dix derniers paiements 97 µs [83, 99] contre 6 299 [6 170, 6 576]
  pour chaque paiement des dernières 24 heures (3 410 lignes tenues par chaque page au lieu de 10), une fois que les
  derniers paiements ont chacun leur instant ; sur le seed tel qu'il est fait, où environ 3 000 paiements partagent son
  dernier instant (une seule fenêtre de l'index les tient tous), 1 297 [1 239, 1 377] contre 6 188. Un groupe au hub (les
  trois watches du tableau de bord, 5 000 groupes de paiements, de totaux changés et de paiements repris, en OCaml sur
  une copie du seed) : 11,9 µs à la médiane contre 10,0, 18,7 en moyenne contre 13,5, puisqu'un paiement repris remplit
  à nouveau la fenêtre par une page ; le watch des dernières 24 heures coûte autant qu'avant (le rapport des moyennes
  0,995 [0,968, 1,034]).

**Les actions**, en ms, par les formulaires (`bench/load` : le client HTTP de Cesia, une connexion par requête, ce qui
coûte environ 0,35 ms de plus par requête qu'ApacheBench), chacune répondue une fois son groupe sur le disque du
serveur :

| action | 1 client : p50 | p99 | 50 clients : p50 | p99 | par seconde à 50 |
|---|---:|---:|---:|---:|---:|
| un client créé | 5,51 [3,77 ; 8,25] | 20,8 | 25,6 [24,1 ; 29,9] | 49,5 | 1 470 |
| une facture payée | 6,41 [4,44 ; 9,28] | 21,3 | 25,9 [17,1 ; 36,3] | 40,1 | 1 691 |
| une facture créée, avec deux lignes | 8,21 [5,26 ; 11,9] | 30,4 | 44,4 [25,3 ; 63,8] | 95,4 | 707 |
| une connexion d'utilisateur | 85,1 [82,8 ; 89,9] | 184 | 855 [827 ; 907] | 1 583 | 32 |

- Ces tours (2026-11-19) ont tourné avec le disque plein à 99 % et d'autres jobs qui écrivaient à côté du lock : un
  fsync prenait plus longtemps et variait davantage que le 2026-11-13 (un client créé : 3,82 ms [3,63 ; 4,40] alors,
  1 996 par seconde à 50 ; une facture créée, 1 722 par seconde), d'où les intervalles larges des écritures.
- 50 écritures à la fois partagent les fsync du serveur (le group commit : confirmer plusieurs groupes par un seul
  fsync, [le serveur](server.md)) : environ 1 500 par seconde, contre 150 l'une après l'autre.
- Une facture prend son numéro dans son propre groupe (`Incr`, étape 5), donc 50 à la fois partagent les fsync du
  serveur comme les autres écritures. La numérotation qu'elle a remplacée, une facture à la fois
  dans le processus, mesurée en alternance avec elle sur le même serveur et les mêmes données (21 tours chacune,
  2026-11-13) : 141 par seconde, p50 262 ms à 50 clients ; le rapport des tours en factures par seconde, nouvelle sur
  ancienne, 11,0 [9,4 ; 15,4], et le même avec un seul client (p50 0,99 [0,42 ; 1,38] : la machine était occupée,
  d'où les intervalles larges et le p99 à un seul client). Avant cette file d'attente, 2 905 essais sur 4 200
  échouaient : chacune des 50 lisait le même plus grand numéro.
- Une connexion d'utilisateur, c'est Argon2id, environ 65 ms d'un cœur et 64 MiB, exprès (le coût de deviner un mot
  de passe) ; elle tourne à côté des requêtes, au plus quatre à la fois sur cette machine (la moitié de ses cœurs),
  donc 50 à la fois sont répondues en 855 ms en
  médiane, 32 par seconde, là où elles prenaient 3 062 ms sur le thread de l'application, 16 par seconde, chaque
  requête du processus attendant pendant ce temps.

**Les pages pendant que des connexions arrivent** (`bench/signins` : des connexions à un rythme fixe, chacune envoyée à
son heure quoi que fassent les autres, pendant que 8 clients demandent la première page de factures l'un après
l'autre ; 5 s par tour, 11 tours, les cas dans un ordre tournant à chaque tour ; la mémoire de l'application à son
pic, lue dans `/proc`), en ms :

| connexions | pages par seconde | p50 d'une page | p99 | la plus longue | p50 d'une connexion | p99 | mémoire au pic |
|---|---:|---:|---:|---:|---:|---:|---:|
| aucune | 1 063 [1 003 ; 1 153] | 7,17 | 11,0 | 14,0 | | | 150 MB |
| 50 par seconde, le hash sur le thread de l'application, comme avant le 2026-11-13 | 3 [3 ; 4] | 749 | 7 087 | 7 087 | 7 546 | 12 478 | 152 MB |
| 50 par seconde, le hash à côté des requêtes (maintenant) | 279 [260 ; 309] | 27,1 | 55,5 | 69,3 | 2 032 | 3 316 | 365 MB |
| 20 par seconde, à côté des requêtes | 612 [547 ; 667] | 11,9 | 23,8 | 30,9 | 97,0 | 152 | 293 MB |

- Quand le hash tenait le seul thread de l'application, 50 connexions par seconde ne laissaient que 3 pages par
  seconde, chacune attendant jusqu'à 7 s. À côté des requêtes, les pages continuent à 279 par seconde, et les
  connexions attendent dans leur file.
- 50 par seconde, c'est deux fois ce que cette machine sait hasher : Argon2id est fait pour avoir besoin de ses 64 MiB
  à chaque étape (memory-hard : sa mémoire est le coût qu'on ne peut pas éviter), et quelques-uns à la fois prennent
  la bande passante de la mémoire (ce qu'elle peut lire et écrire par seconde). libsodium seule, appelée depuis du C
  sur cette machine : de 13 à 15 hashes par seconde sur un thread, de 22 à 24 sur deux, de 24 à 33 sur quatre, 30 sur
  huit. Les pages ralentissent pour les mêmes raisons : leur travail attend la mémoire et partage les cœurs.
- À un rythme qu'elle sait hasher (20 par seconde), une connexion prend 97 ms et les pages continuent à 612 par
  seconde, leur p99 à 24 ms.
- Deux hashes à la fois au lieu de quatre (`CESIA_CORES=2`, qui divise aussi par deux les cœurs du travail de Cesia
  sur les tableaux) : sous 50 par seconde, les pages vont deux fois plus vite (552 par seconde, p99 26 ms) et les
  connexions plus lentement (2,9 s), 75 sur 2 750 refusées par la file ; à 20 par seconde, les deux sont les mêmes
  qu'avec quatre.
- La mémoire grandit des hashes qui tournent à la fois, 64 MiB chacun : 365 MB au pic contre 150 MB. 400 connexions à
  la fois : 260 répondues (4 en cours, 256 dans la file), 140 refusées tout de suite par un 500, la mémoire à 367 MB au
  pic, et l'application répond à la page suivante comme avant.

**Le tableau de bord en direct** : de la réponse à un paiement (le groupe durable) au total impayé de la page changé
dans Firefox (`performance.now()` sur la page, la même horloge que celle du programme), 10 paiements par tour, l'un
après l'autre :

| pages ouvertes | p50 | p99 |
|---:|---:|---:|
| 1 | 0,45 ms [0,32 ; 0,50] | 2,32 ms [1,80 ; 6,40] |
| 10 | 1,25 ms [1,12 ; 1,39] | 4,19 ms [3,92 ; 4,95] |

Le changement atteint d'habitude la page moins d'une milliseconde après la réponse du writer : le processus de
l'application l'a calculé à partir du groupe pendant que le serveur forçait ce groupe sur le disque, et l'a donné une
fois le groupe durable ([ce que coûte un changement](cesia.md#ce-que-cela-coûte)).

**À côté des géants : la part de la base seule.** Le même seed dans PostgreSQL 18.6 (`bench/giants/load.sql` : les mêmes
tirages, les index dont les pages ont besoin, des commits durables, comme par défaut ; un commit est la validation d'une
transaction), les mêmes questions par `pgbench -M prepared` (l'outil de mesure de PostgreSQL ; son client C, en requêtes
préparées, analysées une seule fois puis exécutées avec de nouvelles valeurs, une connexion, par son socket Unix) ; côté
Cepheus, les fonctions de l'application elle-même, ses lectures dans sa propre mémoire. En µs, un client, 101 tours
alternés, en 5 lots chacun seul sous le lock (la médiane des p50 des tours avec son intervalle à 95 % sans hypothèse sur
la distribution, ici $[x_{(41)}, x_{(61)}]$ des tours, 95,4 % ; la médiane de leurs p99 ; et le rapport des deux p50
de chaque tour, sa médiane et son intervalle de la même façon), le 2026-11-19 :

| question | Cepheus p50 | p99 | PostgreSQL p50 | p99 | Cepheus / PostgreSQL |
|---|---:|---:|---:|---:|---:|
| une page de factures (20 lignes de 7 champs) | 115 [114 ; 116] | 223 | **42** [42 ; 42] | 76 | 2,71 [2,69 ; 2,76] |
| une page à 50 000 de profondeur | 115 [115 ; 116] | 195 | **45** [44 ; 45] | 81 | 2,58 [2,55 ; 2,59] |
| les factures par un préfixe du nom du destinataire | 540 [537 ; 545] | 738 | **161** [160 ; 161] | 230 | 3,35 [3,34 ; 3,38] |
| les clients par nom | 88 [87 ; 88] | 136 | **36** [36 ; 37] | 72 | 2,41 [2,39 ; 2,44] |
| les clients par un préfixe du nom ou de l'e-mail (`Or`) | **485** [483 ; 488] | 676 | 1 320 [1 312 ; 1 323] | 1 699 | 0,37 [0,36 ; 0,37] |
| le total impayé (`Not`, `Sum`, `Count`) | **8 363** [8 291 ; 8 517] | 16 952 | 10 435 [10 410 ; 10 466] | 13 276 | 0,81 [0,80 ; 0,82] |
| une facture et ses lignes | **23,1** [22,9 ; 23,1] | 43,2 | 49 [49 ; 50] | 84 | 0,47 [0,46 ; 0,47] |
| une mise à jour durable d'une facture | **3 040** [2 989 ; 3 074] | 7 398 | 3 088 [3 012 ; 3 219] | 8 052 | 0,95 [0,92 ; 0,99] |

Face au moteur de la veille (21 tours alternés avec celui-ci, le même matin) : la page 180 µs, à 50 000 de profondeur
179, le préfixe 1 152, les clients 120, le `Or` 1 253, le total 13 721. Le chargement du seed laissait 5 runs côte à
côte, et chaque lecture payait une recherche dans chacun ; le serveur les fusionne maintenant dès que son writer est au repos une seconde
([merges](architecture.md#les-merges--un-log-structured-merge-tree-à-leveling)). La première fenêtre d'une page triée
tient les faits de ses lignes au lieu de deux fois plus, et les champs d'une ligne sont lus après les filtres, une
fois chacun.

Là où PostgreSQL gagne, et pourquoi :

- **Une page triée** : 2,7 fois plus vite. Son B-tree (l'arbre trié de pages où PostgreSQL range ses tables et ses
  index) sur le numéro donne les 20 lignes dans l'ordre, chaque ligne une lecture de sa table ; Cepheus garde chaque
  propriété dans un fait à part (le modèle entity–attribute–value), donc une ligne de 7 champs, ce sont 7 lectures
  d'index, et sa page dans l'ordre de l'index est demandée comme des fenêtres des valeurs du numéro. Des 115 µs de
  Cepheus, la question triée en prend 24 en OCaml, les champs de ses 20 lignes (une deuxième question, `In`) à peu
  près autant, et le reste, ce sont les lignes fabriquées pour Cesia et le travail de Cesia lui-même : une seule
  question pour toute la page en prendrait environ la moitié (53 µs pour 7 patterns triés, contre 110 pour les deux).
- **Un tri sur un texte** : 2,4 fois (3,2 la veille). La question triée seule prend 27 µs en OCaml ; l'essentiel des
  52 µs qui les séparent, c'est l'autre question de la page (les e-mails de ses 20 clients, `In`) et les lignes
  fabriquées pour Cesia.
- **Un préfixe que l'ordre ne suit pas** (les factures adressées à « ad... », les plus grands numéros d'abord) : 3,4
  fois (7,4 la veille). Environ 4 factures sur 100 correspondent ; Cepheus parcourt les numéros dans l'ordre, une
  fenêtre à la fois, et demande le préfixe dans chacune : environ 2 100 candidats pour 20 lignes, 0,2 µs chacun, là
  où PostgreSQL lit les champs d'une ligne dans un seul tuple (la ligne telle que sa table la range).

Là où Cepheus gagne : le total impayé, 1,23 fois plus vite (les faits des 100 000 factures lus dans un seul run au lieu
de cinq ; PostgreSQL parcourt sa table) ; une facture avec ses lignes est lue dans la mémoire même de l'application,
sans round trip (23 µs contre 49) ; la recherche sur l'un de deux préfixes (`Or` de deux `Prefix`), 2,7 fois plus rapide
que les deux `LIKE` de PostgreSQL (son parcours dans l'ordre des noms abandonne après 2 fenêtres, puis le heap répond) ;
une écriture durable coûte presque la même chose, 0,95 du temps de PostgreSQL [0,92 ; 0,99] (les deux attendent un seul
fsync du disque). Et chaque nombre de la colonne PostgreSQL a encore besoin d'un programme autour, qui suivrait les
changements (`LISTEN`/`NOTIFY`, écrit à la main), pour donner un tableau de bord en direct.

## 15. Sécurité

Ce dont l'application se défend, comment, et le test qui le montre :

| menace | défense | test |
|---|---|---|
| un mot de passe deviné ou volé | Argon2id (libsodium), de 12 à 128 octets ; la même réponse et le même temps pour un identifiant inconnu | `isSignedIn` |
| une copie volée de la base | les mots de passe en hashes Argon2id, les sessions en hashes BLAKE2b de leur secret | (par construction) |
| un cookie de session volé | `HttpOnly`, `SameSite=Strict`, 8 heures, `Secure` en https ; la déconnexion retire la session | `isSignedIn` |
| cross-site request forgery | la vérification same-origin sur chaque requête qui change quelque chose ; `SameSite=Strict` | `isOtherOriginRefused`, aux deux niveaux |
| une page qui montre ce qu'elle ne devrait pas | le rôle vérifié par chaque route ; le token du comptable ne lit que les factures, leurs lignes et leur compteur | `isAccountantSeesInvoicesOnly`, `isAccountantSeesNoClient` (refusé par la base) |
| cross-site scripting (du script d'un autre site injecté dans une page) | chaque valeur échappée ; une Content-Security-Policy qui n'autorise que le script de l'application elle-même ; des valeurs dessinées avec `textContent` dans la page | `isClientMadeAndEscaped` |
| CSV injection | un `'` devant une cellule qu'un tableur exécuterait | `isCsvOfTheFilter` |
| une entrée qui casse une vérification ou la mémoire | chaque champ borné et vérifié avant usage ; des corps de 64 KiB au plus ; des curseurs de 2 KB, leurs types vérifiés (la facture d'un curseur plus ancien n'est lue que si c'est un id, et ne sert qu'à l'ordre) | `isClientChecked`, `isInvoiceChecked`, `isBadCursorRefused`, `isPageCursorNewOrOld` |
| deux requêtes à la fois | `Expect` sur le statut (payée une seule fois), le numéro pris par le groupe (`Incr`) et `unique`, `unique` sur l'e-mail, la contrainte sur les clients supprimés | `isPaidOnce`, `isNumberedInOrderAtOnce`, `isAccountantNumbersInvoicesAtOnce`, `isDeleteChecked`, `isEmailUnique` |
| un secret dans les logs | le log ne contient ni query, ni cookie, ni corps, ni token, ni identifiant tapé | (en lisant `web.ce`) |
| les droits de l'application elle-même | les permissions de l'étape 13, aucun fichier écrit | (le `allow` de la tâche) |

Ce qui n'est pas défendu ici : les connexions d'utilisateurs ne sont pas limitées par client, puisque la requête que
reçoit un handler Cesia ne porte pas l'adresse de son client. Un flot de connexions est borné, pas refusé : ses hashes
tournent à côté des requêtes, au plus la moitié des cœurs à la fois, et la file en tient 64 par place ; au-delà, une
connexion reçoit un 500 tout de suite. Sous 50 connexions par seconde, deux fois ce que cette machine sait hasher, la
mémoire de l'application a culminé à 365 MB (150 MB sans) et ses autres pages ont continué à 279 par seconde, le quart
de leur rythme (les mesures plus haut) ; les connexions elles-mêmes ont attendu 2 s dans la file.

## Ce qui n'est pas encore construit

- Des connexions d'utilisateurs limitées par client : la requête d'un handler Cesia ne porte pas l'adresse de son
  client.
