# Démarrage rapide

En une dizaine de minutes : compiler Cepheus, démarrer un serveur, et lancer un premier programme Cesia qui écrit dans
une base de données et lui pose une question. Chaque commande ci-dessous a été lancée telle qu'elle est écrite ; ce qui
suit une commande est ce qu'elle a affiché (`/home/you` tient la place de votre dossier personnel). Pour le faire
tourner en production : [le guide de production](production.md).

## Ce qu'il faut

- Linux sur x86-64 ou arm64, avec l'instruction CRC-32C du processeur (un CRC est une somme de contrôle : un nombre
  calculé sur des octets, qui change dès qu'un octet change) ([limites](limits.md#les-fichiers-et-la-plateforme)).
- OCaml 5 avec dune (l'outil de compilation d'OCaml), un compilateur C, et les en-têtes d'OpenSSL 3 (le package
  `libssl-dev` sur Debian et Ubuntu, `openssl-devel` sur Fedora ; un package est du code ou un logiciel groupé sous un
  nom, qui s'installe d'un coup).
- Pour le programme Cesia : Cesia compilé depuis ses sources avec ce même OCaml (le README de Cesia, section « From the
  sources »), ici dans `~/cesia`. Le **moteur** du package, la partie OCaml du client, est compilé contre l'interface
  native du Cesia qui le chargera (le fichier compilé qui décrit ce que Cesia offre au code OCaml qu'il charge)
  ([le package](cesia.md#le-package)), et une release de Cesia (une version publiée) ne contient pas encore cette
  interface.

## 1. Compiler et installer

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
       cepheus token add NAME [--database DB=read|write|read:KIND,...;add:KIND,...]... [--admin] --config FILE
       cepheus token list|remove [NAME] --config FILE
       cepheus cluster init|cert NAME --dir DIR [--host H]...
       cepheus replicate PEER --config FILE
       cepheus promote [--force] --config FILE
```

`CESIA_NATIVE` nomme le dossier de l'interface native de ce Cesia (`cesia_v1.cmi`) : avec elle, la compilation fait
aussi le moteur, `_build/default/cesia/native/cepheus.cmxs`. La compilation prend moins d'une minute sur 8 cœurs.
`~/.local/bin` doit être dans votre `PATH` (la liste des dossiers où le shell cherche les commandes).

## 2. Démarrer un serveur

Un **cluster** est l'ensemble des serveurs qui tiennent les mêmes bases ; une seule machine est un cluster d'un seul
serveur. `cepheus cluster init` en crée un dans un dossier : ses certificats pour TLS (le chiffrement des connexions
réseau ; un certificat prouve au client qu'il parle bien à ce serveur), et `cluster.toml`, sa configuration, avec une
base, `main`. Un programme présente au serveur un **token** (une suite d'octets secrète qui prouve ses droits), et le
token lui donne des droits base par base :

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

Le token lui-même est allé dans `~/shop/app.token` : le serveur n'en garde que le hash (une empreinte courte calculée à
partir de lui, qui ne permet pas de le retrouver), il n'est donc montré qu'une fois. Le serveur écoute sur un socket
Unix dans `~/shop/run` (un canal du noyau entre deux programmes d'une même machine, nommé par un chemin : pour les
programmes de cette machine) et sur le port TCP 7400 avec TLS (pour les autres machines). Chaque clé de `cluster.toml`
et chaque commande : [le serveur](server.md#faire-tourner-un-serveur).

## 3. Un projet pour le programme

Un programme Cesia prend le client comme dépendance (du code d'un autre projet que le sien utilise) : le package
`cesia/cepheus` de ce dépôt. La manière propre à Cesia est `cesia pkg add`, qui va chercher une release marquée d'un tag
(le nom git d'une version) ; Cepheus n'en a pas encore, alors mettez le package dans le `deps/` du projet à partir de
votre compilation, comme le ferait `cesia pkg`, et écrivez son `cesia.lock` :

```sh
mkdir -p ~/todo/deps/www-celestial/cepheus/cesia ~/todo/deps/www-celestial/cepheus/native
cd ~/cepheus
cp cesia.toml ~/todo/deps/www-celestial/cepheus/
cp -R cesia/cepheus ~/todo/deps/www-celestial/cepheus/cesia/
cp _build/default/cesia/native/cepheus.cmxs ~/todo/deps/www-celestial/cepheus/native/cepheus-$(cesia run tools/tag.ce).cmxs
```

Puis créez `~/todo/cesia.toml` :

```toml
[project]
name = "todo"

[deps.cepheus]
from = "github.com/www-celestial/cepheus"
version = "v0.1.0"
take = ["cesia/cepheus"]
```

et écrivez le lock file, l'empreinte de chaque fichier de `deps/`, que Cesia vérifie avant de charger le moteur :

```sh
cd ~/todo
cesia run --allow read,write ~/cepheus/tools/lock.ce
```

## 4. Un premier programme

Créez `~/todo/todo.ce` :

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

et lancez-le avec l'adresse de la base et le token :

```sh
export CEPHEUS_URL="cepheus://localhost:7400/main?socket=$HOME/shop/run"
export CEPHEUS_TOKEN=$(cat ~/shop/app.token)
cesia run --allow native=cepheus,env todo.ce
```

```text
Ok([{Task: 65537, Title: "Read the guide"}])
```

Ce qu'il a fait :

- `cepheus.Kind` nomme une sorte de chose et ses champs (c'est un kind) ; `Connect` déclare dans la base les propriétés
  qui lui manquent (`task/Title`, `task/Done` ; une propriété est un attribut nommé et typé d'une chose), en une seule
  écriture ([kinds](cesia.md#les-kinds-et-les-valeurs-quils-tiennent)).
- Chaque `Insert` et chaque `Update` est un **groupe** : une écriture de plusieurs faits (un fait est un triplet chose,
  propriété, valeur), tout ou rien, qui reçoit sa réponse une fois qu'elle est sur le disque du serveur, et que
  l'historique garde avec `by` et `why` ([Insert, Get, Update](cesia.md#insert-get-update)).
- `Find` est une question : les choses dont `Done` est faux, avec leur titre. Ses patterns (les triplets de la question)
  sont des faits qui doivent être vrais, ses variables sont les paramètres de la fonction
  ([questions](cesia.md#find--les-questions)).
- `--allow native=cepheus,env` permet au programme de charger le moteur du package et de lire les deux variables de son
  environnement ([la permission](cesia.md#le-package)).

Relancez-le : il ajoute deux tâches de plus, et la question trouve les deux qui ne sont pas terminées :

```text
Ok([{Task: 65537, Title: "Read the guide"}, {Task: 65539, Title: "Read the guide"}])
```

## 5. Arrêter, démarrer, regarder

`cepheus status` montre ce que tient le serveur ; il lui faut un token avec `--admin`, que le serveur connaît moins
d'une seconde après son `token add` (il relit `tokens.toml` chaque seconde quand le fichier a changé ; un `status`
envoyé plus tôt est refusé avec `auth: unknown token`) :

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
role: primary
database.main.group: 8
database.main.facts: 36
database.main.resent: 0
database.main.followers: 0
database.main.frames: 7
database.main.follow_ns_a_frame: 6471
database.main.visible: 9
database.main.watches: 0
database.main.epoch: 1
```

Huit groupes : la description que le système fait de ses propriétés, la déclaration des deux propriétés du kind, et
trois écritures pour chaque exécution du programme. Ce que veut dire chaque ligne, et lesquelles surveiller :
[le guide de production](production.md#ce-quil-faut-surveiller).

Arrêtez le serveur, redémarrez-le, et lancez le programme une troisième fois :

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

Les groupes étaient sur le disque quand chaque écriture a reçu sa réponse (G1, [garanties](guarantees.md#g1-durabilité)) ;
un arrêt propre a fermé la base, donc le démarrage n'a rien eu à rejouer (le replay : relire les groupes du journal, le
fichier où la base écrit chaque groupe d'abord, pour refaire l'état).

## La suite

- [Une vraie application](app.md) : une application de factures et de clients sur cette pile, construite pas à pas et
  mise en production.
- [Concepts](concepts.md) : les faits, les groupes, les vues (l'état exact après un groupe), les questions, les forks
  (un état temporaire où l'on écrit sans rien écrire sur le disque).
- [Cepheus depuis Cesia](cesia.md) : chaque appel du client, `Write` avec `Expect`, les agrégats, les questions
  vivantes (`Watch`), les forks pour les tests, les lectures dans la mémoire même du programme.
- [Le serveur](server.md) : `cluster.toml`, les tokens et les droits, TLS pour les programmes d'autres machines.
- [Le guide de production](production.md) : un service, les sauvegardes, quoi surveiller, les mises à jour, les
  crashs.
