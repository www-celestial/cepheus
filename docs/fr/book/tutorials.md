# Tutoriels : des problèmes d'entreprise résolus pas à pas, PostgreSQL à côté

Chaque tutoriel prend un problème que les logiciels de gestion rencontrent tous les jours, et le résout avec Cepheus
pas à pas : le problème, la solution de Cepheus, ce que PostgreSQL écrit pour la même chose, et la différence, mesurée
ou garantie. Les mots sont expliqués là où ils apparaissent pour la première fois, et dans le
[glossaire](glossary.md) ; chaque appel est décrit exactement dans [Cepheus depuis Cesia](cesia.md).

**Comment lire le code.** Les blocs Cesia tournent tels qu'ils sont écrits, contre un vrai serveur, à chaque passage
des tests (`test/cesia.sh`) : chaque bloc tourne avec tous les blocs d'avant lui, comme un seul programme, et ce qui
le suit est ce qu'il a affiché. Les tutoriels partagent donc une seule base, comme les parties d'une même application.
Le SQL est celui de PostgreSQL 18.6, lancé avec `psql` sur les mêmes tables qui tiennent les mêmes lignes ; ce qui le
suit est ce que PostgreSQL a répondu.

## La base des tutoriels

Des clients et leurs factures, les données que tous les tutoriels utilisent. Un **kind** (une sorte) regroupe les
propriétés d'une sorte de chose ; une **chose** (thing) est un numéro, son id ; une propriété à plusieurs valeurs
(`many`) tient une liste (les téléphones d'un client) ; `Closed` est un drapeau qu'a un compte fermé ;
`Link(to = "client")` relie une facture à une chose qui doit être un client, la foreign key (clé étrangère) de SQL
([tutoriel 10](#10-un-client-qui-a-des-factures-ne-se-supprime-pas-les-lignes-dune-facture-partent-avec-elle)).

```cesia norun
use deps/www-celestial/cepheus/cesia/cepheus
use std/fiber
use std/io
use std/list
use std/math
use std/result
use std/sys
use std/value

Client = cepheus.Kind("client", {Name: cepheus.Text(), City: cepheus.Text(), Phone: cepheus.Text(many = true), Closed: cepheus.Bool()})
Invoice = cepheus.Kind("invoice", {
  Client: cepheus.Link(to = "client"), Number: cepheus.Int(unique = true), Total: cepheus.Money(2), Status: cepheus.Text(),
  Date: cepheus.Date(), Due: cepheus.Date(), PaidAt: cepheus.Date(),
})

defn connect(kinds)
  (** The tutorials' database, with these kinds declared in it: its address and its token from the environment. *)
  result.Unwrap(cepheus.Connect(sys.Env("CEPHEUS_URL"), kinds, token = sys.Env("CEPHEUS_TOKEN")))
end

db = connect([Client, Invoice])
ada = result.Unwrap(cepheus.Insert(Client, {Name: "Ada Martin", City: "Lyon", Phone: ["04 00 00 00 01", "06 00 00 00 01"]}, db))
bo = result.Unwrap(cepheus.Insert(Client, {Name: "Bo Lind", City: "Paris", Phone: ["01 00 00 00 02"]}, db))
cy = result.Unwrap(cepheus.Insert(Client, {Name: "Cy Moreau", City: "Nice"}, db))
di = result.Unwrap(cepheus.Insert(Client, {Name: "Di Weber", City: "Lyon", Closed: true}, db))
io.Print(ada, bo, cy, di)
```

```text
65536 65537 65538 65539
```

Les mêmes tables dans PostgreSQL, comme un utilisateur de PostgreSQL les écrit (les téléphones d'un client dans une
table à eux, puisqu'un client peut en avoir plusieurs) :

```sql
CREATE TABLE client (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, name text NOT NULL, city text NOT NULL,
                     closed bool NOT NULL DEFAULT false);
CREATE TABLE phone (client bigint NOT NULL REFERENCES client, number text NOT NULL);
CREATE TABLE invoice (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, client bigint NOT NULL REFERENCES client,
                      number bigint UNIQUE, total numeric(12,2) NOT NULL, status text NOT NULL,
                      date timestamptz NOT NULL, due timestamptz, paid_at timestamptz);
```

## 1. Des numéros de facture sans trou

**Le problème.** Une facture porte « un numéro séquentiel, basé sur une ou plusieurs séries, qui identifie la
facture de façon unique » (la directive européenne sur la TVA, 2006/112/CE, article 226), et les administrations
fiscales de plusieurs pays, dont la France, le lisent comme une suite sans trou : un numéro qui manque doit être
expliqué. Beaucoup de personnes et de programmes facturent en même temps, et certaines factures sont refusées en
route (un compte fermé, une vérification qui échoue) : une facture refusée ne doit prendre aucun numéro.

**La solution de Cepheus.** Un **compteur**, une chose avec une propriété `Int`, que le groupe qui fait la facture
incrémente avec `cepheus.Incr` : la base lit le compteur quand elle applique le groupe, et `into` écrit la nouvelle
valeur comme numéro de la facture, dans le même groupe. Un **groupe** est une écriture de plusieurs faits, tout ou
rien : refusé, il n'écrit rien, donc il ne prend aucun numéro.

```cesia norun
Counter = cepheus.Kind("counter", {Last: cepheus.Int()})
db = connect([Client, Invoice, Counter])
numbers = result.Unwrap(cepheus.Insert(Counter, {Last: 0}, db))

defn bill(client, total, date, db)
  (** An invoice of this client, numbered in the group that makes it: refused whole, taking no number, when the
      client's account is closed. *)
  cepheus.Write([
    cepheus.Expect(client, Client.Closed),
    cepheus.Incr(numbers, Counter.Last, into = [cepheus.New(1), Invoice.Number]),
    cepheus.Add(cepheus.New(1), Invoice.Client, client),
    cepheus.Add(cepheus.New(1), Invoice.Total, total),
    cepheus.Add(cepheus.New(1), Invoice.Date, date),
    cepheus.Add(cepheus.New(1), Invoice.Status, "unpaid")
  ], db)
end
```

Pas à pas : `Expect(client, Client.Closed)` ne tient que si le client n'a pas de fait `Closed` (Di en a un) ; `Incr`
compte un de plus ; `New(1)` est la chose que le groupe crée, la facture, qui reçoit le numéro. Maintenant 30 factures
en même temps, une **fiber** chacune (un des threads légers de Cesia), un tiers d'entre elles pour Di :

```cesia norun
who = [ada, bo, di]
when = [1772409600, 1748822400, 1772409600]
tasks = [fiber.Spawn(() -> bill(who[1 + math.Mod(k, 3)], 10 * k, when[1 + math.Mod(k, 3)], db)) for k in 1..30]
outcomes = [result.Unwrap(fiber.Wait(t)) for t in tasks]
io.Print("written:", list.Count(result.IsOk, outcomes), "refused:", list.Count(result.IsErr, outcomes))
got = result.Unwrap(cepheus.Find(2, (i, n) -> {Where: [[i, Invoice.Number, n]], Give: {Number: n}, Sort: [n]}, db))
io.Print([r.Number for r in got])
io.Print(cepheus.Get(Counter, numbers, db))
```

```text
written: 20 refused: 10
[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]
Ok({Last: 20})
```

(Les factures d'Ada sont datées du 2 mars 2026, celles de Bo du 2 juin 2025 : `when` donne des secondes depuis 1970,
comme `sys.Now()`.) Les 20 factures écrites tiennent les numéros 1 à 20, quel que soit l'ordre où les fibers ont
tourné, et les 10 refusées n'en ont pris aucun.

**PostgreSQL** donne des numéros avec une **sequence** (une séquence), `nextval`, qui ne revient jamais en arrière :
une transaction qui prend un numéro puis est annulée (rollback) laisse un trou. Les mêmes 20 factures y ont pris les
numéros 1 à 20 ; ensuite :

```sql
CREATE SEQUENCE invoice_number;
BEGIN;
INSERT INTO invoice (client, number, total, status, date) VALUES (1, nextval('invoice_number'), 10, 'unpaid', now());
ROLLBACK;
INSERT INTO invoice (client, number, total, status, date)
  VALUES (1, nextval('invoice_number'), 20, 'unpaid', now()) RETURNING number;
```

```text
 number
--------
     22
```

Le numéro 21 est parti avec la transaction annulée. C'est voulu : la documentation de PostgreSQL dit qu'une valeur
donnée par `nextval` n'est pas reprise quand sa transaction échoue, pour que des transactions qui numérotent en même
temps ne s'attendent jamais, et que les échecs et les pannes laissent donc des trous ([Sequence Manipulation
Functions](https://www.postgresql.org/docs/18/functions-sequence.html)). La façon sans trou dans PostgreSQL est une
ligne de compteur que la transaction de chaque facture met à jour :

```sql
CREATE TABLE counter (id int PRIMARY KEY, last bigint NOT NULL);
-- the counter row stays locked until the transaction ends
WITH n AS (UPDATE counter SET last = last + 1 WHERE id = 1 RETURNING last)
INSERT INTO invoice (client, number, total, status, date) SELECT 1, last, 30, 'unpaid', now() FROM n;
```

**La différence.** Les deux ne laissent aucun trou de cette façon ; le coût diffère. L'`UPDATE` de PostgreSQL pose un
lock (un verrou) sur la ligne du compteur jusqu'à la fin de la transaction, et une transaction se termine une fois son
commit sur le disque (un fsync, l'écriture forcée sur le disque) : chaque facture attend que celle d'avant soit écrite,
si bien que les factures se font un fsync à la fois, quel que soit le nombre de personnes qui facturent. Cepheus ne
pose aucun lock : son writer unique applique les groupes dans l'ordre, en lisant le compteur à chacun, et les groupes
qui arrivent pendant que le disque travaille partagent le fsync suivant (le group commit), si bien que 30 personnes
attendent ensemble à peu près un fsync, pas 30 l'un après l'autre. Mesuré avec 64 écrivains sur un même compteur :
Cepheus 5 890 écritures par seconde, PostgreSQL 154 ([ce que cela coûte](#ce-que-cela-coûte)).

## 2. Une file de jobs où chaque job est pris une seule fois

**Le problème.** Le travail à faire plus tard est mis dans une file : envoyer une relance, faire un PDF, appeler une
banque. Plusieurs workers (des processus qui font ce travail) prennent les jobs, en même temps ; chaque job doit être
fait une seule fois, jamais par deux workers, et un worker qui s'arrête au milieu d'un job (une panne, un déploiement)
ne doit pas le perdre.

**La solution de Cepheus.** Un job est une chose avec un `State`. Un worker prend un job par un groupe qui ne tient que
si le job est encore en file (`Expect`), et le marque pris dans le même groupe : de deux workers qui essaient le même
job, le groupe du second est refusé avec le Code `"conflict"`, et ce worker en prend un autre. Rien n'est verrouillé :
le refus est la réponse du même aller-retour.

```cesia norun
Job = cepheus.Kind("job", {Task: cepheus.Text(), State: cepheus.Text(), Worker: cepheus.Int(), Since: cepheus.Date()})
db = connect([Client, Invoice, Counter, Job])
for k in 1..40
  result.Unwrap(cepheus.Insert(Job, {Task: "send reminder $k", State: "queued"}, db))
end

defn take(w, db)
  (** Worker w takes one of the four oldest queued jobs (each worker aims at another one): an Ok of its id, an Ok of
      missing when none is queued, or the write's Err; a job another worker took first is a conflict, and w looks
      again. *)
  while true
    next = cepheus.Find(1, (j) -> {Where: [[j, Job.State, "queued"]], Give: {Job: j}, Sort: [j], Limit: 4}, db)?
    return result.Ok(missing) if value.Len(next) == 0
    j = next[1 + math.Mod(w, value.Len(next))].Job
    taken = cepheus.Write([
      cepheus.Expect(j, Job.State, "queued"),
      cepheus.Add(j, Job.State, "taken"), cepheus.Add(j, Job.Worker, w), cepheus.Add(j, Job.Since, sys.Now())
    ], db)
    return result.Ok(j) if result.IsOk(taken)
    return taken if taken.Error.Code != "conflict"
  end
end

defn worker(w, db)
  (** Takes jobs until none is queued, does each, and marks it done: an Ok of the number of jobs it did. *)
  did = 0
  while true
    j = take(w, db)?
    break if value.IsMissing(j)
    (* the work itself: here, send the reminder *)
    cepheus.Update(Job, j, {State: "done"}, db)?
    did += 1
  end
  result.Ok(did)
end
```

Quatre workers, en même temps :

```cesia norun
crew = [fiber.Spawn(() -> worker(w, db)) for w in 1..4]
did = [result.Unwrap(result.Unwrap(fiber.Wait(c))) for c in crew]
done = result.Unwrap(cepheus.Find(1, (j) -> {Where: [[j, Job.State, "done"]], Give: {Done: cepheus.Count()}}, db))
io.Print("jobs done by the workers:", list.Reduce((a, b) -> a + b, 0, did), "jobs done in the database:", done[1].Done)
```

```text
jobs done by the workers: 40 jobs done in the database: 40
```

Les workers ont fait 40 jobs à eux tous et la base tient 40 jobs faits : si deux workers avaient pris un même job, ils
en auraient compté 41. **Un worker qui s'arrête** laisse son job pris ; un balayage remet en file les jobs pris il y a
plus de 5 minutes, chacun seulement si personne ne l'a repris depuis (le même état et la même heure, deux `Expect`) :

```cesia norun
lost = result.Unwrap(cepheus.Insert(Job, {Task: "send reminder 41", State: "taken", Worker: 9, Since: sys.Now() - 3600}, db))
stale = result.Unwrap(cepheus.Find(2, (j, s) -> {
  Where: [[j, Job.State, "taken"], [j, Job.Since, s], cepheus.Below(s, sys.Now() - 300)],
  Give: {Job: j, Since: s},
}, db))
for r in stale
  back = [cepheus.Expect(r.Job, Job.State, "taken"), cepheus.Expect(r.Job, Job.Since, r.Since), cepheus.Add(r.Job, Job.State, "queued")]
  io.Print(result.IsOk(cepheus.Write(back, db)))
end
io.Print(result.Unwrap(cepheus.Get(Job, lost, db)).State)
```

```text
true
queued
```

**PostgreSQL** prend un job avec un lock de ligne, `FOR UPDATE`, et `SKIP LOCKED` laisse un worker passer les lignes
que d'autres workers ont verrouillées au lieu de les attendre :

```sql
CREATE TABLE job (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, task text NOT NULL, state text NOT NULL,
                  worker int, since timestamptz);
UPDATE job SET state = 'taken', worker = 1, since = now()
 WHERE id = (SELECT id FROM job WHERE state = 'queued' ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED)
 RETURNING id;
UPDATE job SET state = 'queued' WHERE state = 'taken' AND since < now() - interval '5 minutes';
```

**La différence.** Les deux prennent chaque job une seule fois : PostgreSQL par le lock de ligne (le second worker
saute la ligne, ou, sans `SKIP LOCKED`, attend et la trouve prise), Cepheus par `Expect` dans un ordre strictement
sérialisable ([G4](guarantees.md#g4-strict-serializability)). La documentation de PostgreSQL prévient que sauter les
lignes verrouillées donne une vue incohérente des données, bonne pour une table utilisée comme file et pas pour un
travail général ([SELECT, the locking
clause](https://www.postgresql.org/docs/18/sql-select.html#SQL-FOR-UPDATE-SHARE)) ; un job gardé verrouillé pendant tout
son travail tient une connexion et une transaction ouverte pendant ce temps, ce qui retient le nettoyage de la table
par `VACUUM`. Cepheus ne tient rien pendant le travail : l'état d'un job est un fait, son histoire gardée (qui l'a
pris, quand, pourquoi il est revenu). Ce que PostgreSQL fait et que Cepheus ne fait pas : un lock tenu par un worker
qui meurt part avec sa connexion, donc son job revient tout seul ; avec Cepheus, c'est le balayage plus haut qui le
fait.

## 3. Des données de test qui ne laissent rien

**Le problème.** Un test, ou un « et si » (les totaux si les prix montaient de 5 %), écrit de vraies données par le
vrai code, vérifie le résultat, et ne doit rien laisser derrière lui : ni dans la base, ni dans ses compteurs, ni dans
son histoire.

**La solution de Cepheus.** Un **fork** : une base dans la mémoire du programme qui part d'une autre, avec chaque
vérification (les types, `unique`, `Expect`, les règles), et dont les écritures ne vont nulle part. En faire un ne
copie rien (le fork partage l'état d'où il part) ([les forks](cesia.md#les-forks)).

```cesia norun
what = result.Unwrap(cepheus.Fork(db))
for k in 1..3
  result.Unwrap(bill(bo, 1000 * k, 1772409600, what))
end
io.Print(cepheus.Get(Counter, numbers, what), cepheus.Get(Counter, numbers, db))
io.Print(bill(di, 50, 1772409600, what).Error.Code)
```

```text
Ok({Last: 23}) Ok({Last: 20})
conflict
```

Le fork a numéroté trois factures, 21 à 23, avec le code du [tutoriel 1](#1-des-numéros-de-facture-sans-trou) ; le
compteur de la base est toujours à 20, et la facture de Di est refusée dans le fork comme elle le serait dans la base.
Un test de `cesia test` n'a besoin d'aucun serveur : il fait un fork de `cepheus.Empty`, une base vide, avec les kinds
qu'il utilise.

```cesia norun
use deps/www-celestial/cepheus/cesia/cepheus
use std/list
use std/result

Counter = cepheus.Kind("counter", {Last: cepheus.Int()})
Invoice = cepheus.Kind("invoice", {Number: cepheus.Int(unique = true), Total: cepheus.Money(2)})

defn isNumberedWithoutGap()
  t = cepheus.Fork(cepheus.Empty, [Counter, Invoice])?
  c = cepheus.Insert(Counter, {Last: 0}, t)?
  bill = [cepheus.Incr(c, Counter.Last, into = [cepheus.New(1), Invoice.Number]), cepheus.Add(cepheus.New(1), Invoice.Total, 10)]
  first = cepheus.Write(bill, t)?.Things[1]
  refused = cepheus.Write(list.Prepend(cepheus.Expect(c, Counter.Last, 99), bill), t)
  second = cepheus.Write(bill, t)?.Things[1]
  refused.Error.Code == "conflict" and cepheus.Get(Invoice, first, t)?.Number == 1 and cepheus.Get(Invoice, second, t)?.Number == 2
end
```

```text
cesia test --allow native=cepheus
```

**PostgreSQL** fait tourner un test dans une transaction qu'il annule :

```sql
BEGIN;
INSERT INTO invoice (client, number, total, status, date) VALUES (2, nextval('invoice_number'), 1000, 'unpaid', now());
ROLLBACK;
SELECT last_value FROM invoice_number;
```

```text
 last_value
------------
         23
```

**La différence.** La transaction annulée a laissé sa séquence avancée (`last_value` 23 : le trou du tutoriel 1 de
nouveau), et tant qu'une telle transaction est ouverte, les lignes qu'elle a changées restent verrouillées contre tout
autre écrivain ; un code testé qui fait son commit lui-même termine la transaction du test, et ses données restent. Un
fork ne laisse rien nulle part, c'est garanti : la base d'où il part et son histoire ne changent pas
([G8](guarantees.md#g8-les-forks)), aucun lock n'est pris, et autant de forks d'une même base qu'on veut vivent en même
temps, chacun le sien. Ce que PostgreSQL fait et qu'un fork ne fait pas : les écritures d'une transaction vont sur son
disque, là où celles d'un fork restent dans la mémoire du programme, donc un test qui écrit des gigaoctets a besoin de
cette mémoire ; et un fork d'une base lue au serveur (un programme sur une autre machine) n'est pas encore construit
([cesia](cesia.md#ce-qui-nest-pas-encore-construit)).

## 4. Des pages qui ne sautent jamais une ligne

**Le problème.** Une liste de factures se lit une page à la fois, les plus grandes d'abord. Entre deux pages, d'autres
écrivent : une nouvelle facture ne doit pas faire montrer deux fois une ligne à la page suivante ni en cacher une, et
la page 400 doit coûter ce que coûte la page 1.

**La solution de Cepheus.** `Sort`, `Limit` et `After` : la page suivante, ce sont les lignes qui viennent après la
dernière ligne montrée, dans l'ordre ([les pages](cesia.md#sort-limit-et-after--des-pages)).

```cesia norun
page = (after) -> ((i, t, c, n) -> {
  Where: [[i, Invoice.Total, t], [i, Invoice.Client, c], [c, Client.Name, n]],
  Give: {Total: t, Client: n},
  Sort: [cepheus.Desc(t)],
  Limit: 3,
  After: after,
})
first = result.Unwrap(cepheus.Find(4, page(missing), db))
io.Print(first)
(* meanwhile, another clerk writes an invoice larger than all of them *)
result.Unwrap(bill(ada, 1000, 1772409600, db))
io.Print(cepheus.Find(4, page(first[3]), db))
```

```text
[{Total: 300.0, Client: "Ada Martin"}, {Total: 280.0, Client: "Bo Lind"}, {Total: 270.0, Client: "Ada Martin"}]
Ok([{Total: 250.0, Client: "Bo Lind"}, {Total: 240.0, Client: "Ada Martin"}, {Total: 220.0, Client: "Bo Lind"}])
```

La seconde page continue après 270, quoi qu'il soit venu avant elle entre-temps ; la nouvelle facture est sur la
première page, pour qui la lira ensuite.

**PostgreSQL** fait des pages avec `OFFSET`, les lignes à sauter :

```sql
SELECT total FROM invoice ORDER BY total DESC LIMIT 3;            -- 300.00, 280.00, 270.00
INSERT INTO invoice (client, number, total, status, date) VALUES (1, nextval('invoice_number'), 1000, 'unpaid', now());
SELECT total FROM invoice ORDER BY total DESC LIMIT 3 OFFSET 3;
```

```text
 total
--------
 270.00
 250.00
 240.00
```

**La différence.** Avec `OFFSET`, la facture écrite entre les pages a poussé chaque ligne d'un rang : 270 apparaît deux
fois, et une ligne effacée entre les pages en cacherait une. `OFFSET 12000` lit aussi et jette 12 000 lignes avant la
page, si bien qu'une page profonde coûte ce que coûtent toutes les pages d'avant elle. La réponse de PostgreSQL aux
deux est la **keyset pagination** (des pages par la clé de la dernière ligne), `WHERE (total, id) < (270.00, 18) ORDER
BY total DESC, id DESC`, avec un index sur `(total, id)` et la colonne qui départage écrite à la main. `After`, c'est
cela, intégré : il départage par les autres champs de la ligne elle-même, si bien que deux lignes ne sont égales dans
l'ordre que si elles sont la même ligne, et n'a besoin d'aucun index choisi pour lui ; la page après une ligne coûte
la même chose à toute profondeur ([comment on y répond](cesia.md#sort-limit-et-after--des-pages)).

## 5. Les clients sans facture cette année

**Le problème.** Le marketing veut les clients qui n'ont rien acheté cette année, pour les appeler. La réponse porte
sur ce qui n'est *pas* dans la base.

**La solution de Cepheus.** `cepheus.Not` : le client est gardé quand aucune de ses factures n'est datée de cette
année. Les variables `i` et `d` sont propres au `Not` (elles n'apparaissent nulle part ailleurs dans la question) :
« il n'y a pas de `i` et de `d` tels que... ».

```cesia norun
y2026 = 1767225600
y2027 = 1798761600
idle = (c, n, i, d) -> {
  Where: [[c, Client.Name, n], cepheus.Not([i, Invoice.Client, c], [i, Invoice.Date, d], cepheus.Between(d, y2026, y2027 - 0.001))],
  Give: {Name: n},
  Sort: [n],
}
io.Print(cepheus.Find(4, idle, db))
```

```text
Ok([{Name: "Bo Lind"}, {Name: "Cy Moreau"}, {Name: "Di Weber"}])
```

Les factures de Bo sont de 2025, Cy n'en a pas, et celles de Di ont été refusées. La liste peut rester vivante sur
l'écran du marketing : un `Watch` (une question tenue à jour) de la même question envoie les lignes qu'elle perd et
qu'elle gagne. Bo achète :

```cesia norun
w = result.Unwrap(cepheus.Watch(4, idle, db))
fiber.Receive(w.Changes)
result.Unwrap(bill(bo, 75, 1772409600, db))
io.Print(result.Unwrap(fiber.Receive(w.Changes)).Removed)
cepheus.Close(w)
```

```text
[{Name: "Bo Lind"}]
```

**PostgreSQL** écrit `NOT EXISTS` :

```sql
SELECT name FROM client c
 WHERE NOT EXISTS (SELECT 1 FROM invoice i WHERE i.client = c.id
                   AND i.date >= '2026-01-01' AND i.date < '2027-01-01')
 ORDER BY name;
```

**La différence.** Les deux font un **anti-join** (une jointure qui garde ce qui n'a pas de correspondant) : pour
chaque client, une recherche qui ne doit rien trouver (le plan de PostgreSQL dit `Hash Anti Join` ou `Nested Loop
Anti Join`). Deux différences restent. Le `NOT IN` de SQL, la forme que beaucoup écrivent d'abord, ne donne plus aucune
ligne dès que sa sous-requête donne un seul `NULL` (`x NOT IN (1, NULL)` est inconnu, jamais vrai) ; Cepheus n'a pas
de `NULL`, et `Not` a un seul sens. Et un `Watch` garde la réponse vivante, chaque changement calculé à partir des faits
qui ont changé ([Not, Or et In](cesia.md#not-or-et-in)), là où l'écran de PostgreSQL redemande.

## 6. Les factures de Lyon ou de Paris, impayées ou contestées

**Le problème.** Le service du recouvrement veut les factures de deux villes qui sont impayées ou contestées,
comptées par ville et par état ; puis une liste de ce qui est urgent : les factures impayées de Paris au-dessus de 200,
et toutes celles qui sont contestées, où qu'elles soient.

**La solution de Cepheus.** `cepheus.In` pour « l'une de ces valeurs », `cepheus.Or` pour « l'une de ces conditions ».
D'abord, des factures sont payées et d'autres contestées (`byTotal` trouve une facture par son total, unique ici) :

```cesia norun
defn byTotal(t)
  (** The invoice of this total. *)
  result.Unwrap(cepheus.Find(1, (i) -> {Where: [[i, Invoice.Total, t]], Give: {Invoice: i}}, db))[1].Invoice
end
for t in [30, 60, 10]
  result.Unwrap(cepheus.Update(Invoice, byTotal(t), {Status: "paid"}, db))
end
result.Unwrap(bill(cy, 55, 1772409600, db))
for t in [90, 40, 55]
  result.Unwrap(cepheus.Update(Invoice, byTotal(t), {Status: "disputed"}, db))
end
open = cepheus.Find(4, (i, c, city, s) -> {
  Where: [[i, Invoice.Client, c], [c, Client.City, city], cepheus.In(city, ["Lyon", "Paris"]),
    [i, Invoice.Status, s], cepheus.In(s, ["unpaid", "disputed"])],
  Give: {City: city, Status: s, Invoices: cepheus.Count()},
  Sort: [city, s],
}, db)
io.Print(open)
urgent = cepheus.Find(5, (i, c, n, t, s) -> {
  Where: [[i, Invoice.Client, c], [c, Client.Name, n], [i, Invoice.Total, t], [i, Invoice.Status, s],
    cepheus.Or(cepheus.And([c, Client.City, "Paris"], [i, Invoice.Status, "unpaid"], cepheus.Above(t, 200)), [i, Invoice.Status, "disputed"])],
  Give: {Name: n, Total: t, Status: s},
  Sort: [n, t],
}, db)
io.Print(urgent)
```

```text
Ok([{City: "Lyon", Status: "disputed", Invoices: 1}, {City: "Lyon", Status: "unpaid", Invoices: 8}, {City: "Paris", Status: "disputed", Invoices: 1}, {City: "Paris", Status: "unpaid", Invoices: 9}])
Ok([{Name: "Ada Martin", Total: 90.0, Status: "disputed"}, {Name: "Bo Lind", Total: 40.0, Status: "disputed"}, {Name: "Bo Lind", Total: 220.0, Status: "unpaid"}, {Name: "Bo Lind", Total: 250.0, Status: "unpaid"}, {Name: "Bo Lind", Total: 280.0, Status: "unpaid"}, {Name: "Cy Moreau", Total: 55.0, Status: "disputed"}])
```

La facture contestée de Cy est à Nice : hors de la première question, dans la seconde.

**PostgreSQL** écrit `IN` et `OR`, les mêmes mots :

```sql
SELECT c.city, i.status, count(*) FROM invoice i JOIN client c ON c.id = i.client
 WHERE c.city IN ('Lyon', 'Paris') AND i.status IN ('unpaid', 'disputed')
 GROUP BY c.city, i.status ORDER BY c.city, i.status;
SELECT c.name, i.total, i.status FROM invoice i JOIN client c ON c.id = i.client
 WHERE (c.city = 'Paris' AND i.status = 'unpaid' AND i.total > 200) OR i.status = 'disputed'
 ORDER BY c.name, i.total;
```

**La différence.** Les mots sont les mêmes ; la façon diffère. Chaque alternative de l'`Or` de Cepheus est posée comme
une question à elle, à partir de l'index qui lui donne le moins de candidats (ici les factures contestées, lues dans
l'index de `Status`), avec les alternatives d'avant elle comme des `Not`, si bien que leurs réponses ne se recouvrent
jamais et qu'aucune n'est gardée pour retirer des copies ; chaque réponse vient une fois, c'est garanti
([G11](guarantees.md#g11-des-réponses-exactes)). PostgreSQL lit un `OR` sur deux tables d'un join comme un filtre sur
les lignes jointes (son plan ici : un `Hash Join` dont le `Join Filter` est l'`OR`, sur chaque facture), sauf s'il le
réécrit (un `BitmapOr` marche dans une seule table) ; la réécriture à la main est une `UNION`, qui trie ou hache
chaque ligne pour retirer les copies. `In` est une liste de valeurs dans les deux.

## 7. Un stock qui ne descend jamais sous zéro

**Le problème.** Une boutique vend ses dernières lampes à beaucoup d'acheteurs à la fois. Le stock ne doit jamais
descendre sous zéro : aucune lampe vendue qui ne soit pas là, quel que soit le nombre d'acheteurs qui cliquent au même
moment.

**La solution de Cepheus.** Le stock est un compteur que chaque commande décompte avec `Incr`, dans le groupe de la
commande, et une **contrainte**, une règle dont la tête est `cepheus.Never`, refuse chaque groupe après lequel un stock
serait négatif ([les règles](cesia.md#règles), [G18](guarantees.md#g18-les-contraintes-tiennent)). La règle est définie
une fois, au démarrage du programme :

```cesia norun
Item = cepheus.Kind("item", {Name: cepheus.Text(), Stock: cepheus.Int()})
db = connect([Client, Invoice, Counter, Job, Item])
never = cepheus.Rule("stock-never-negative", 2, (x, q) -> {Where: [[x, Item.Stock, q], cepheus.Below(q, 0)], Then: cepheus.Never})
io.Print(cepheus.Define([never], db))
lamp = result.Unwrap(cepheus.Insert(Item, {Name: "desk lamp", Stock: 10}, db))
orders = [fiber.Spawn(() -> cepheus.Write([cepheus.Incr(lamp, Item.Stock, by = -1)], db)) for k in 1..12]
outcomes = [result.Unwrap(fiber.Wait(o)) for o in orders]
io.Print("sold:", list.Count(result.IsOk, outcomes), "refused:", [r.Error.Code for r in list.Filter(result.IsErr, outcomes)])
io.Print(cepheus.Get(Item, lamp, db))
```

```text
Ok(missing)
sold: 10 refused: ["invalid", "invalid"]
Ok({Name: "desk lamp", Stock: 0})
```

Douze acheteurs, dix lampes : dix commandes écrites, deux refusées, le stock à 0. Les autres faits d'une commande (ses
lignes, son client) vont dans le même groupe que l'`Incr`, donc une commande refusée n'en laisse aucun.

**PostgreSQL** écrit un `CHECK` et un `UPDATE` qui décompte :

```sql
CREATE TABLE item (id int PRIMARY KEY, name text NOT NULL, stock int NOT NULL CHECK (stock >= 0));
INSERT INTO item VALUES (1, 'desk lamp', 0);
UPDATE item SET stock = stock - 1 WHERE id = 1;
```

```text
ERROR:  new row for relation "item" violates check constraint "item_stock_check"
DETAIL:  Failing row contains (1, desk lamp, -1).
```

**La différence.** Les deux gardent le stock à zéro ou plus, c'est garanti. Un `CHECK` voit une seule ligne ; une
contrainte de Cepheus est une question sur n'importe quels faits (« les lampes réservées ne dépassent jamais les lampes
en stock », sur les lignes des commandes), là où PostgreSQL a besoin d'un trigger (un code lancé à chaque écriture), et
un trigger qui lit d'autres lignes est trompé par deux transactions à la fois (chacune lit les lignes de l'autre comme
elles étaient avant elle) sauf s'il tourne sous `SERIALIZABLE` ou pose des locks ; le writer unique de Cepheus vérifie
chaque groupe contre la base que les groupes d'avant ont faite. Et le coût, comme pour le compteur du tutoriel 1 :
chaque `UPDATE` de la ligne de la lampe attend que celui d'avant ait fait son commit, 154 commandes par seconde au plus
avec 64 acheteurs, contre 5 890 pour Cepheus ([ce que cela coûte](#ce-que-cela-coûte)).

## 8. Les factures payées en retard, les prêts entre 2,5 et 3 %

**Le problème.** La finance veut les factures payées après leur échéance (deux dates d'une même facture comparées
entre elles), et les prêts dont le taux est entre 2,5 et 3 % (un intervalle de floats, des nombres à virgule).

**La solution de Cepheus.** `cepheus.Less(x, y)` garde $x < y$, deux variables d'un même type ; `Between` prend une
variable `Float` ([Less, LessOrEqual et Optional](cesia.md#less-lessorequal-et-optional)). D'abord, trois des
factures d'Ada sont payées, avec leurs échéances :

```cesia norun
for x in [[120, 1774915200, 1776211200], [150, 1774915200, 1774915200], [180, 1777507200, 1779235200]]
  result.Unwrap(cepheus.Update(Invoice, byTotal(x[1]), {Due: x[2], PaidAt: x[3], Status: "paid"}, db))
end
late = result.Unwrap(cepheus.Find(6, (i, c, n, t, d, p) -> {
  Where: [[i, Invoice.Client, c], [c, Client.Name, n], [i, Invoice.Total, t], [i, Invoice.Due, d], [i, Invoice.PaidAt, p], cepheus.Less(d, p)],
  Give: {Client: n, Total: t, Due: d, Paid: p},
  Sort: [t],
}, db))
io.Print([{Client: r.Client, Total: r.Total, DaysLate: (r.Paid - r.Due) / 86400} for r in late])

Loan = cepheus.Kind("loan", {Client: cepheus.Link(), Rate: cepheus.Float()})
db = connect([Client, Invoice, Counter, Job, Item, Loan])
for x in [[ada, 2.4], [bo, 2.5], [cy, 2.75], [ada, 3.0], [bo, 3.1]]
  result.Unwrap(cepheus.Insert(Loan, {Client: x[1], Rate: x[2]}, db))
end
io.Print(cepheus.Find(4, (l, c, n, r) -> {
  Where: [[l, Loan.Rate, r], cepheus.Between(r, 2.5, 3.0), [l, Loan.Client, c], [c, Client.Name, n]],
  Give: {Client: n, Rate: r},
  Sort: [r],
}, db))
```

```text
[{Client: "Ada Martin", Total: 120.0, DaysLate: 15.0}, {Client: "Ada Martin", Total: 180.0, DaysLate: 20.0}]
Ok([{Client: "Bo Lind", Rate: 2.5}, {Client: "Cy Moreau", Rate: 2.75}, {Client: "Ada Martin", Rate: 3.0}])
```

La facture de 150 a été payée le jour de son échéance : `Less` est strict, donc elle n'est pas en retard
(`LessOrEqual` la garderait).

**PostgreSQL** écrit la comparaison et l'intervalle dans `WHERE` :

```sql
SELECT c.name, i.total, i.due, i.paid_at FROM invoice i JOIN client c ON c.id = i.client
 WHERE i.due < i.paid_at ORDER BY i.total;
SELECT c.name, l.rate FROM loan l JOIN client c ON c.id = l.client
 WHERE l.rate BETWEEN 2.5 AND 3.0 ORDER BY l.rate;
```

**La différence.** Les mêmes réponses. Deux dates d'une même facture se comparent ligne par ligne dans les deux. Entre
deux choses (les factures datées après le dernier paiement d'un client, par exemple), Cepheus lit le second côté comme
un range (un intervalle) de son index trié une fois le premier lié, l'inequality join (la jointure d'inégalité) de
[Khayyat 2015](references.md#les-joins). Sur les floats, Cepheus range comme son `Sort`, dans le totalOrder d'IEEE
754 : $-0$ vient avant $0$, donc `Below(r, 0)` garde un $-0$ ; le `float8` de PostgreSQL tient $-0 = 0$, donc
`r < 0` le laisse dehors. Les deux mettent NaN après tout nombre. Mesuré sur les données des benchmarks :
[plus bas](#ce-que-cela-coûte).

## 9. Les clients avec leur téléphone, s'ils en ont un

**Le problème.** La liste des clients pour le centre d'appels : chaque client, avec chacun de ses téléphones, et les
clients sans téléphone aussi, en dernier, pour qu'ils en reçoivent un.

**La solution de Cepheus.** `cepheus.Optional([c, Client.Phone, p])` : pour chaque client, une ligne par téléphone,
ou une ligne où `p` est `missing` (absent) quand le client n'en a pas. C'est le `LEFT JOIN` de SQL.

```cesia norun
calls = (c, n, p) -> {Where: [[c, Client.Name, n], cepheus.Optional([c, Client.Phone, p])], Give: {Name: n, Phone: p}, Sort: [n]}
io.Print(cepheus.Find(3, calls, db))
byPhone = (c, n, p) -> {Where: [[c, Client.Name, n], cepheus.Optional([c, Client.Phone, p])], Give: {Name: n, Phone: p}, Sort: [cepheus.Desc(p)]}
io.Print(cepheus.Find(3, byPhone, db))
```

```text
Ok([{Name: "Ada Martin", Phone: "04 00 00 00 01"}, {Name: "Ada Martin", Phone: "06 00 00 00 01"}, {Name: "Bo Lind", Phone: "01 00 00 00 02"}, {Name: "Cy Moreau", Phone: missing}, {Name: "Di Weber", Phone: missing}])
Ok([{Name: "Ada Martin", Phone: "06 00 00 00 01"}, {Name: "Ada Martin", Phone: "04 00 00 00 01"}, {Name: "Bo Lind", Phone: "01 00 00 00 02"}, {Name: "Cy Moreau", Phone: missing}, {Name: "Di Weber", Phone: missing}])
```

Ada a deux téléphones, donc deux lignes ; les clients sans téléphone viennent en dernier, dans les deux ordres. Sur
l'écran du centre d'appels la liste est vivante : Cy donne un téléphone, et le changement retire la ligne de Cy sans
téléphone et donne la ligne avec.

```cesia norun
w = result.Unwrap(cepheus.Watch(3, calls, db))
fiber.Receive(w.Changes)
result.Unwrap(cepheus.Write([cepheus.Add(cy, Client.Phone, "04 00 00 00 03")], db))
change = result.Unwrap(fiber.Receive(w.Changes))
io.Print(change.Added, change.Removed)
cepheus.Close(w)
```

```text
[{Name: "Cy Moreau", Phone: "04 00 00 00 03"}] [{Name: "Cy Moreau", Phone: missing}]
```

**PostgreSQL** écrit un `LEFT JOIN` :

```sql
SELECT c.name, p.number FROM client c LEFT JOIN phone p ON p.client = c.id ORDER BY p.number DESC;
```

```text
    name    |     number
------------+----------------
 Di Weber   |
 Cy Moreau  |
 Ada Martin | 06 00 00 00 01
 Ada Martin | 04 00 00 00 01
 Bo Lind    | 01 00 00 00 02
```

**La différence.** PostgreSQL met ses `NULL` en dernier en ordre croissant et *en premier* en ordre décroissant, si
bien que la liste du centre d'appels par téléphone, du plus grand au plus petit, commence par les clients qui n'en ont
pas, sauf si la requête dit `NULLS LAST` ; Cepheus met une valeur absente en dernier dans les deux sens. Le sens est
celui du `LEFT JOIN` de SQL, et de l'`OPTIONAL` de SPARQL, pour un pattern ([Pérez, Arenas et Gutierrez
2009](references.md#les-joins)), avec une règle dont PostgreSQL n'a pas besoin : la variable optionnelle n'est dans
aucune autre partie de la question, si bien que la question a un seul sens quel que soit l'ordre de ses parties.
Mesuré : [plus bas](#ce-que-cela-coûte).

## 10. Un client qui a des factures ne se supprime pas, les lignes d'une facture partent avec elle

**Le problème.** Un client s'en va, ou a été saisi deux fois, et quelqu'un le supprime. Ses factures doivent rester, et
garder leur client : une facture est une pièce comptable, gardée dix ans en France (Code de commerce, article L123-22),
et une facture dont le client a disparu ne pointe vers rien. Un brouillon de facture qu'on jette, en revanche, emporte
ses lignes : une ligne n'a pas de sens sans sa facture. Et la note d'un employé sur ce brouillon reste : elle perd
seulement son lien.

**La solution de Cepheus.** Un lien qui nomme un kind, `cepheus.Link(to = "client")`, que la base des tutoriels déclare
pour `Invoice.Client` dès le début : à chaque écriture, la chose liée doit être un client, c'est-à-dire avoir un fait
du kind client (un champ d'un client) ; c'est la **foreign key** (clé étrangère) de SQL, `REFERENCES client`.
`onDelete` dit ce que fait un lien quand sa chose cesse d'être du kind : `"refuse"`, par défaut, refuse la
suppression ; `"cascade"` supprime avec elle la chose qui pointe ; `"clear"` retire le lien.
`cepheus.Delete(kind, id, db)` supprime une chose d'un kind, le `DELETE` de SQL : ses faits de ce kind sont retirés,
et les liens vers elle suivent leur `onDelete`, en un seul groupe.

```cesia norun
Line = cepheus.Kind("line", {Invoice: cepheus.Link(to = "invoice", onDelete = "cascade"), Label: cepheus.Text(), Amount: cepheus.Money(2)})
Note = cepheus.Kind("note", {About: cepheus.Link(to = "invoice", onDelete = "clear"), Text: cepheus.Text()})
db = connect([Client, Invoice, Counter, Line, Note])
io.Print(cepheus.Insert(Invoice, {Client: numbers, Total: 5, Status: "draft"}, db))
```

```text
Err({Kind: "cepheus", Code: "invalid", Message: "invoice/Client links to client things only, and #65540 is not one"})
```

Pas à pas : `Connect` déclare les deux nouveaux kinds et leurs liens ; une facture dont le client est le compteur du
tutoriel 1 est refusée, puisque cette chose n'est pas un client. Maintenant Ada, qui a des factures :

```cesia norun
io.Print(cepheus.Delete(Client, ada, db))
io.Print(cepheus.Get(Client, ada, db))
```

```text
Err({Kind: "cepheus", Code: "invalid", Message: "the client #65536 cannot be deleted while the invoice #65542 links to it (invoice/Client: refuse)"})
Ok({Name: "Ada Martin", City: "Lyon", Phone: ["04 00 00 00 01", "06 00 00 00 01"], Closed: missing})
```

Sa suppression est refusée, en nommant une de ses factures, et rien n'a été écrit. Une nouvelle cliente, Eve, et un
brouillon pour elle avec deux lignes et une note, puis jeté, pendant qu'un écran regarde les lignes du brouillon :

```cesia norun
eve = result.Unwrap(cepheus.Insert(Client, {Name: "Eve Roux", City: "Lille"}, db))
draft = result.Unwrap(cepheus.Insert(Invoice, {Client: eve, Total: 120, Status: "draft"}, db))
paper = result.Unwrap(cepheus.Insert(Line, {Invoice: draft, Label: "paper", Amount: 20}, db))
ink = result.Unwrap(cepheus.Insert(Line, {Invoice: draft, Label: "ink", Amount: 100}, db))
memo = result.Unwrap(cepheus.Insert(Note, {About: draft, Text: "Eve asked for a discount"}, db))
w = result.Unwrap(cepheus.Watch(2, (l, a) -> {Where: [[l, Line.Invoice, draft], [l, Line.Amount, a]], Give: {Line: l, Amount: a}}, db))
fiber.Receive(w.Changes)
io.Print(cepheus.Delete(Invoice, draft, db, why = "draft thrown away"))
io.Print(result.Unwrap(fiber.Receive(w.Changes)).Removed)
cepheus.Close(w)
io.Print(cepheus.Get(Invoice, draft, db), cepheus.Get(Line, paper, db), cepheus.Get(Line, ink, db), cepheus.Get(Note, memo, db))
io.Print(cepheus.Delete(Client, eve, db), cepheus.Get(Client, eve, db))
```

```text
Ok(190)
[{Line: 65614, Amount: 100.0}, {Line: 65613, Amount: 20.0}]
Ok(missing) Ok(missing) Ok(missing) Ok({About: missing, Text: "Eve asked for a discount"})
Ok(191) Ok(missing)
```

Un seul groupe a supprimé le brouillon et ses deux lignes (`cascade`) et retiré le lien de la note (`clear`), et
l'écran l'a reçu comme un seul changement qui emporte les deux lignes. Eve n'avait alors plus de facture, et est
supprimée. Une chose supprimée reste dans l'historique : le journal garde chaque groupe, celui-ci aussi, avec qui et
pourquoi ([Cepheus depuis Cesia](cesia.md#supprimer-une-chose)).

**PostgreSQL** déclare la même chose avec `REFERENCES … ON DELETE` :

```sql
CREATE TABLE line (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                   invoice bigint NOT NULL REFERENCES invoice ON DELETE CASCADE,
                   label text NOT NULL, amount numeric(12,2) NOT NULL);
CREATE TABLE note (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                   invoice bigint REFERENCES invoice ON DELETE SET NULL, text text NOT NULL);
INSERT INTO invoice (client, total, status, date) VALUES (99, 5, 'draft', now());
DELETE FROM client WHERE name = 'Ada Martin';
```

```text
ERROR:  insert or update on table "invoice" violates foreign key constraint "invoice_client_fkey"
DETAIL:  Key (client)=(99) is not present in table "client".
ERROR:  update or delete on table "client" violates foreign key constraint "invoice_client_fkey" on table "invoice"
DETAIL:  Key (id)=(1) is still referenced from table "invoice".
```

```sql
INSERT INTO client (name, city) VALUES ('Eve Roux', 'Lille') RETURNING id;
INSERT INTO invoice (client, total, status, date) VALUES (5, 120, 'draft', now()) RETURNING id;
INSERT INTO line (invoice, label, amount) VALUES (22, 'paper', 20), (22, 'ink', 100);
INSERT INTO note (invoice, text) VALUES (22, 'Eve asked for a discount');
DELETE FROM invoice WHERE id = 22;
SELECT count(*) AS lines FROM line WHERE invoice = 22;
SELECT invoice, text FROM note;
DELETE FROM client WHERE name = 'Eve Roux';
```

```text
 id
----
  5

 id
----
 22

DELETE 1
 lines
-------
     0

 invoice |           text
---------+--------------------------
         | Eve asked for a discount

DELETE 1
```

`REFERENCES client` sans `ON DELETE` est `NO ACTION`, qui refuse comme `RESTRICT` (il vérifie à la fin de
l'instruction, ou de la transaction quand la contrainte est différée) ; `SET NULL` est le `clear` de Cepheus, et
PostgreSQL a aussi `SET DEFAULT`, que Cepheus n'a pas : un lien n'a pas de valeur par défaut.

**La différence.** Les trois mêmes réponses, et quatre différences. Trouver les lignes d'une facture à supprimer est
une recherche par valeur dans les lignes : PostgreSQL n'indexe pas de lui-même la colonne qui pointe (« the
declaration of a foreign key constraint does not automatically create an index on the referencing columns »,
[Foreign Keys](https://www.postgresql.org/docs/18/ddl-constraints.html#DDL-CONSTRAINTS-FK)), si bien que sans un
`CREATE INDEX ON line (invoice)` chaque facture supprimée lit toutes les lignes ; Cepheus indexe chaque fait dans les
deux sens, par sa valeur aussi, si bien que les choses qui pointent vers une chose sont toujours à une recherche de là.
PostgreSQL fait une cascade avec les droits du propriétaire des tables : un rôle qui peut supprimer des factures, et ne
peut pas supprimer de lignes, supprime quand même leurs lignes (lancé sur PostgreSQL 18.6 : son `DELETE FROM line`
refusé, son `DELETE FROM invoice` a ensuite emporté la ligne) ; un token de Cepheus ne supprime que s'il peut écrire
chaque kind que sa suppression peut atteindre, et est refusé en entier sinon. Une cascade de Cepheus est bornée :
au-delà du budget de travail du groupe (un million de faits pour un seul `Delete`) elle est refusée en entier, rien de
fait, là où PostgreSQL supprime n'importe quel nombre de lignes, dans une seule transaction qui tient leurs locks. Et un
client supprimé reste dans l'historique de Cepheus, là où la ligne de PostgreSQL a disparu une fois `VACUUM` passé ;
effacer une chose de l'historique est une autre opération, pas encore construite. Une chose cesse aussi d'être un
client quand son dernier fait de client est retiré, par `Retract` comme par `Delete`, et les liens vers elle suivent
leur `onDelete` de la même façon. Mesuré : [plus bas](#ce-que-cela-coûte).

## Ce que cela coûte

Mesuré sur les données des benchmarks à 1 million de faits (11 363 clients, 227 260 factures, 56 797 liens de suivi),
les mêmes lignes dans PostgreSQL 18.6, sur une machine que d'autres jobs partageaient (une charge moyenne de 5 à 6,5
sur ses 8 threads) ; la méthode, chaque chiffre et son intervalle sont dans [les
benchmarks](benchmarks.md#less-optional-et-un-compteur-partagé-2026-11-25-à-1-million-de-faits).

| question | Cepheus | PostgreSQL 18.6 | |
|---|---:|---:|---|
| 64 écrivains sur un même compteur (`Incr` ; une ligne de compteur) | **5 890 écritures par seconde** | 154 | Cepheus, 38 fois |
| les clients d'une ville avec les clients que chacun suit (`Optional` ; `LEFT JOIN`), 490 lignes | **0,099 ms** | 0,554 ms | Cepheus, 5,6 fois |
| chaque client avec les clients qu'il suit, 56 797 lignes | 29,4 ms | **16,4 ms** | PostgreSQL, 1,8 fois |
| les liens de suivi vers un client plus récent (`Less(a, b)` ; `a < b`), 28 271 lignes | 14,7 ms | **3,97 ms** | PostgreSQL, 3,7 fois |
| les factures sous le total d'une facture (`Less` ; `total < (SELECT ...)`), 122 962 lignes | 76,2 ms | **22,0 ms** | PostgreSQL, 3,5 fois |
| un client qui a 10 000 factures, refusé (`Delete`, `refuse` ; `DELETE`, `REFERENCES`) | **6 µs** | 89 µs | Cepheus, 15 fois |
| une facture et ses 100 lignes (`cascade` ; `ON DELETE CASCADE`) | **176 µs** | 193 µs | à peu près pareil |
| une facture et ses 10 000 lignes | 27,3 ms | **5,16 ms** | PostgreSQL, 5,3 fois |
| une facture et le lien de ses 10 000 notes (`clear` ; `ON DELETE SET NULL`) | **11,1 ms** | 46,5 ms | Cepheus, 4,2 fois |
| la vérification d'un lien qui nomme un kind, à chaque écriture (celle d'une foreign key) | **0,2 µs** | 9,6 µs | Cepheus, 48 fois |

- Un compteur que beaucoup d'écrivains partagent est là où un lock coûte le plus : PostgreSQL tient la ligne jusqu'à
  ce que chaque commit soit sur le disque, le writer de Cepheus lit le compteur à mesure qu'il applique chaque groupe,
  et les groupes partagent leur fsync.
- `Optional` coûte ce que coûte le même join ; sur une question sélective les index de Cepheus gagnent, sur deux
  tables entières c'est le hash join de PostgreSQL.
- `Less` ne coûte pas plus que filtrer les lignes dans le programme, mais le parcours d'une table étroite par
  PostgreSQL, dans un seul processus, est plus rapide que la lecture des faits un par un ; et le range plus haut tourne
  sur un seul des domains de Cepheus, puisqu'une question n'est partagée entre domains qu'à son premier niveau (ici,
  le seul total de la borne) : une façon de la partager plus loin n'est pas encore construite.
- Les suppressions sont le travail du moteur, rien sur le disque, à une charge de 2,7 à 3,1, sur 680 681 faits et les
  mêmes lignes ([les benchmarks](benchmarks.md#les-suppressions-et-les-liens-qui-nomment-un-kind-2026-11-25)). Trouver
  ce qui pointe vers une chose est une seule recherche dans Cepheus, quel que soit leur nombre, là où PostgreSQL fait
  passer la requête de sa foreign key par un trigger ; une grande cascade coûte à Cepheus ce que coûte le retrait de
  ses faits (1 µs par fait), PostgreSQL ne fait que marquer ses lignes.

## Chaque tutoriel en une ligne

| Problème | Cepheus | PostgreSQL | La différence |
|---|---|---|---|
| [des numéros de facture sans trou](#1-des-numéros-de-facture-sans-trou) | `Incr` dans le numéro, dans le groupe de la facture | `SEQUENCE` (des trous) ou une ligne de compteur (un lock jusqu'au commit) | aucun trou et aucun lock : les groupes partagent le fsync |
| [un job pris une seule fois](#2-une-file-de-jobs-où-chaque-job-est-pris-une-seule-fois) | `Expect` le job en file | `FOR UPDATE SKIP LOCKED` | rien de verrouillé pendant le travail ; un balayage pour les workers arrêtés |
| [des données de test qui ne laissent rien](#3-des-données-de-test-qui-ne-laissent-rien) | `Fork` | `BEGIN` … `ROLLBACK` | rien ne bouge, pas même un compteur ; aucun lock |
| [des pages qui ne sautent jamais une ligne](#4-des-pages-qui-ne-sautent-jamais-une-ligne) | `Sort`, `Limit`, `After` | `OFFSET`, ou keyset à la main | le keyset intégré, l'égalité départagée par la ligne |
| [les clients sans facture cette année](#5-les-clients-sans-facture-cette-année) | `Not` | `NOT EXISTS` | un seul sens (pas de `NULL`), vivant avec `Watch` |
| [Lyon ou Paris, impayées ou contestées](#6-les-factures-de-lyon-ou-de-paris-impayées-ou-contestées) | `In`, `Or` | `IN`, `OR`, `UNION` | chaque alternative à partir de son propre index, aucune copie à retirer |
| [un stock jamais sous zéro](#7-un-stock-qui-ne-descend-jamais-sous-zéro) | `Incr` et une règle `Never` | `CHECK` et `UPDATE` | une contrainte sur n'importe quels faits, pas une ligne |
| [payées en retard, des prêts dans un intervalle](#8-les-factures-payées-en-retard-les-prêts-entre-25-et-3-) | `Less`, `Between` sur un float | `a < b`, `BETWEEN` | le totalOrder sur les floats |
| [les clients avec leur téléphone](#9-les-clients-avec-leur-téléphone-sils-en-ont-un) | `Optional` | `LEFT JOIN` | l'absent en dernier dans les deux sens, vivant avec `Watch` |
| [un client qui a des factures gardé](#10-un-client-qui-a-des-factures-ne-se-supprime-pas-les-lignes-dune-facture-partent-avec-elle) | `Link(to, onDelete)`, `Delete` | `REFERENCES … ON DELETE` | des liens toujours indexés dans les deux sens ; une cascade demande les droits du token, et est bornée |
