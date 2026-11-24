# Le vault de fichiers

Une base de données a souvent des fichiers à côté de ses faits : une facture scannée, un contrat, une photo, un fichier
de log. Le **vault** (le coffre : « le vault de fichiers ») garde leurs octets dans Cepheus, pour qu'ils soient
stockés, vérifiés, protégés et copiés avec la base de données plutôt qu'à côté d'elle. Un fichier est une chose d'un
**kind de fichiers** (un kind regroupe sous des noms de champs les propriétés d'une sorte de chose) avec cinq faits
(son nom, sa taille, son type de média, son propriétaire et la racine de ses octets, c'est-à-dire le nom du sommet de
l'arbre qui les liste, plus bas) ; ses octets sont dans le vault de la base, découpés en chunks (des morceaux) stockés
une seule fois, compressés, et scellés (chiffrés et authentifiés) par une clé de leur propriétaire. Cette page en dit
tout : comment s'en servir, comment il marche et pourquoi, ses formats octet par octet, ce qu'il garantit, sa sécurité,
et ce qu'il coûte à côté de la lecture des mêmes fichiers dans le système de fichiers.

Les termes sont expliqués à leur première apparition et dans le [glossaire](glossary.md).

## Depuis Cesia

```cesia norun
use deps/www-celestial/cepheus/cesia/cepheus
use std/result
use std/sys

Person = cepheus.Kind("person", {Name: cepheus.Text()})
Scans = cepheus.Files("scan")
db = result.Unwrap(cepheus.Connect("cepheus://srv1:7400/shop", [Person, Scans], token = sys.Env("CEPHEUS_TOKEN"), ca = "/etc/cepheus/ca.pem"))
ada = result.Unwrap(cepheus.Insert(Person, {Name: "Ada Martin"}, db))
f = result.Unwrap(cepheus.Put(Scans, "2026-11.pdf", result.Unwrap(sys.Read("2026-11.pdf")), db, type = "application/pdf", owner = ada))
result.Unwrap(cepheus.Get(Scans, f, db))   (* {Name: "2026-11.pdf", Size: 2480311, Type: "application/pdf", Owner: ada, Content: "9c1e..."} *)
all = result.Unwrap(cepheus.Read(Scans, f, db))   (* the whole file, a Text of its bytes *)
page = result.Unwrap(cepheus.Read(Scans, f, db, from = 1_000_000, len = 65_536))   (* only the chunks under the range are read *)
result.Unwrap(cepheus.List(Scans, db))   (* [{Id, Name, Size, Type}] *)
result.Unwrap(cepheus.Delete(Scans, f, db))   (* its facts retracted; its bytes stay while the history cites them *)
result.Unwrap(cepheus.Erase(ada, db))   (* ada's key destroyed: every file she owned is unreadable, everywhere *)
```

- `cepheus.Files(name)` est un kind comme les autres, avec les champs `Name`, `Size`, `Type`, `Owner` et `Content` :
  donnez-le à `Connect`, et posez des questions sur lui comme sur n'importe quel kind. `List(kind, db)` est la question
  `Find(4, (f, n, s, t) -> {Where: [[f, kind.Name, n], [f, kind.Size, s], [f, kind.Type, t]], Give: {Id: f, Name: n, Size: s, Type: t}}, db)`.
- **Les droits sont ceux du kind** ([G16](server.md#les-droits-g16)) : un token (la suite d'octets secrète qu'un
  programme présente pour prouver ses droits) qui peut ajouter à `scan` peut déposer un scan ; un token qui peut lire
  `scan` peut lire ses octets ; `Erase` demande un token qui écrit toute la base (l'effacement ne peut pas être
  annulé), et un propriétaire : la clé propre de la base, celle des fichiers sans propriétaire, n'est jamais effacée
  (`invalid`).
- `Put` rend la main une fois les octets et les faits sur le disque du serveur ; envoyé de nouveau après une connexion
  coupée, il est appliqué une seule fois (G14) : ses octets sont trouvés déjà stockés, et la réponse de son groupe (son
  écriture, appliquée tout entière ou pas du tout) est redonnée.
- `cold = true` stocke plus petit un fichier rarement lu (Zstandard au lieu de LZ4), au prix d'un put (le dépôt d'un
  fichier dans le vault) plus lent.
- Un fork (un état temporaire qui part d'une vue de la base, où l'on écrit sans rien écrire sur le disque) ne tient
  aucun fichier : les fichiers sont gardés dans le vault d'un serveur (`Put` sur un fork est un Err de Code
  `invalid`).

## Depuis OCaml

Le vault est la bibliothèque `cepheus_vault` (module `Cepheus_vault.Vault`) ; le client OCaml du serveur a
`Client.put`, `Client.load` et `Client.erase` pour les mêmes requêtes que le package Cesia.

```ocaml
open Cepheus
open Cepheus_vault

let () =
  let dir = Filename.concat (try Sys.getenv "CEPHEUS_TMP" with Not_found -> Filename.get_temp_dir_name ()) "vault-doc" in
  ignore (Sys.command ("rm -rf " ^ Filename.quote dir));
  let master = String.make 32 'k' (* a server makes it at random, in vault.key *) in
  let v = Result.get_ok (Vault.open_ Disk.real dir ~master) in
  let text = Bytes.of_string (String.concat "" (List.init 20_000 (fun i -> Printf.sprintf "line %d of the log\n" (i mod 100)))) in
  let w = Result.get_ok (Vault.writer v ~domain:7 ~cold:false) in
  ignore (Vault.feed w text 0 (Bytes.length text));
  let root, size = Result.get_ok (Vault.finish w) in
  Printf.printf "%d bytes, named by a root of %d bytes\n" size (String.length root);
  let part = Buffer.create 16 in
  ignore (Vault.load v root ~from:7 ~len:10 (fun b o n -> Buffer.add_subbytes part b o n));
  Printf.printf "bytes 7 to 16: %S\n" (Buffer.contents part);
  Printf.printf "stored once: %b\n" (Vault.written v > 0 && Vault.stored v < size / 4);
  ignore (Vault.erase v 7);
  print_endline (match Vault.size v root with Error e -> Vault.message e | Ok _ -> "still readable");
  Vault.close v
```

```output
378000 bytes, named by a root of 32 bytes
bytes 7 to 16: "of the log"
stored once: true
the files of domain 7 were erased (its key is destroyed)
```

Un `writer` prend les octets en morceaux de n'importe quelle taille et en garde au plus quelques MiB ; rien du fichier
n'est visible avant que `finish` ne rende sa racine, une fois forcé sur le disque chaque octet dont il a besoin (forcé :
écrit, puis confirmé par fsync, l'appel système qui attend que les octets soient vraiment sur le disque) : alors
seulement un fait peut la citer. `load` donne les octets d'une plage en morceaux, en ne lisant que les chunks qui la
couvrent.

## Comment ça marche

### Des chunks coupés selon leur contenu

Un fichier est découpé en **chunks** par **FastCDC** (un content-defined chunking : un découpage décidé par le contenu
lui-même ; Xia, Zhou, Jiang, Feng, Hua, Hu, Liu, Zhang, "FastCDC: a Fast and Efficient Content-Defined Chunking
Approach for Data Deduplication", USENIX ATC 2016). Un **Gear hash** (un hash roulant : un nombre calculé sur les derniers
octets lus, mis à jour à chaque octet) parcourt les octets, h = 2h + G[byte] avec G une table fixe de 256 mots
aléatoires : le bit k de h ne dépend que des k + 1 derniers octets, puisque chaque doublement fait sortir par le haut
les octets plus anciens. Un chunk se termine après un octet où les bits de h sous un masque (bits 44 à 61 : une fenêtre
de 45 à 62 octets) sont tous à zéro : avec un masque de k bits, une chance de 2^-k à chaque octet. L'endroit où tombe
une coupure dépend des octets qui l'entourent et de rien d'autre : un octet inséré au début d'un fichier ne déplace que
les coupures proches de lui, et chaque chunk qui suit est retrouvé (des chunks de taille fixe se décaleraient tous :
dans les tests, 24 MB avec 100 octets insérés à deux endroits, plus de 97 % des octets de la copie sont retrouvés avec
FastCDC, moins de 30 % avec des chunks fixes de 64 KiB).

Le **normalized chunking** (le découpage normalisé ; la section 3.3 de l'article, niveau 2) garde les tailles proches
de 64 KiB : aucune coupure dans les 16 premiers KiB d'un chunk ; un masque de 18 bits jusqu'à 64 KiB (une coupure y est
rare) ; 14 bits après (elle vient vite) ; une coupure d'office à 256 KiB. La chance d'une coupure entre 16 et 64 KiB est
1 - (1 - 2^-18)^49152 ≈ 17 %, puis vient une queue géométrique de moyenne 2^14 = 16 KiB : une moyenne d'environ
0,17 × 40 + 0,83 × 80 ≈ 73 KiB (mesurée sur des octets aléatoires : à 10 % près, testé).

### Les noms, et chaque chunk stocké une seule fois

Le **nom** d'un chunk est son **BLAKE2b-256** (une fonction de hash cryptographique qui donne 256 bits ; Aumasson,
Neves, Wilcox-O'Hearn, Winnerlein, "BLAKE2: simpler, smaller, fast as MD5", ACNS 2013 ; RFC 7693) **à clé** (keyed :
le résultat dépend aussi d'une clé secrète), calculé avec une clé de son domain (la chose dont la clé scelle le
fichier, définie plus bas ; sans rapport avec les domains d'OCaml) : le `crypto_generichash` de libsodium avec une
clé. Un chunk dont le vault a déjà le nom n'est pas stocké de nouveau : c'est la **déduplication**. 256 bits à cause du
birthday bound (la borne des anniversaires : parmi des valeurs tirées au hasard, deux égales deviennent probables bien
plus tôt qu'on ne le croit) : avec n chunks, P(deux noms égaux) ≈ n² / 2^257 ; pour 2^40 chunks (64 PiB), cela fait
2^-177 ; un adversaire qui fabrique des fichiers a besoin d'environ 2^128 essais pour une collision. Une collision
laisserait un chunk passer pour un autre : d'où 256 bits, et pas 128.

La clé compte pour la vie privée. Un simple hash des octets laisserait quiconque tient les fichiers du vault tester si
un fichier connu s'y trouve (le hasher, chercher le nom), et les fichiers identiques de deux personnes partageraient un
chunk : la faiblesse connue du stockage dédupliqué (Harnik, Pinkas, Shulman-Peleg, "Side Channels in Cloud Services:
Deduplication in Cloud Storage", IEEE Security & Privacy 2010 ; la convergent encryption, un chiffrement dont la clé
est tirée des octets eux-mêmes, Douceur et al., ICDCS 2002). Avec la clé du domain du propriétaire, un nom ne dit rien
sans la clé, et les chunks ne sont dédupliqués **qu'à l'intérieur d'un domain**, jamais entre deux : la vie privée
avant la place (le choix 19 de la conception).

Un **domain** est la chose dont la clé scelle un fichier : son propriétaire (une personne, un dossier partagé), ou 0,
la base elle-même.

### Compressé, warm ou cold, une seule fois

Chaque chunk est compressé quand cela fait gagner au moins 1/32 de sa taille, sinon gardé tel quel :

- **warm** (tiède, le choix par défaut) : **LZ4** 1.10.0 (Collet), dont le décodeur tourne à des gigaoctets par
  seconde ;
- **cold** (froid, `cold = true`) : **Zstandard** 1.5.7 au niveau 9 (Collet, Kucherawy, RFC 8878), un tiers plus petit
  sur du texte, plus lent à écrire.

Un chunk est compressé une seule fois, quand il est stocké ; une lecture le décode et ne le réécrit jamais. Les deux
bibliothèques sont les officielles, fuzzées par OSS-Fuzz (nourries sans fin d'entrées générées et mutées pour trouver
leurs plantages), copiées dans le dépôt (vendored) à ces versions dans `vendor/` et compilées avec leurs symboles
cachés (la libcrypto du système lie la libzstd du système, qui garde les siens). La décision d'utiliser du C pour
elles, et les mesures derrière elle, sont dans la conception (le décodeur LZ4 en OCaml écrit d'abord tournait à la
moitié de la vitesse de liblz4, et aucun décodeur Zstandard n'existe en OCaml). Aucun test d'entropie (une estimation
du désordre des octets, pour deviner s'ils se compressent) ne choisit le codec (l'algorithme qui compresse et
décompresse) : les deux codecs abandonnent vite sur des octets qui ne se compressent pas (LZ4 à plus de 3 GB/s sur un
PDF), donc le test coûterait plus qu'il ne fait gagner.

### Scellé : AEGIS-256 sous la clé du propriétaire

Chaque domain a une clé aléatoire de 32 octets, gardée dans le fichier `keys` du vault, scellée par la **master key**
du serveur (la clé maîtresse : 32 octets dans `vault.key`, à côté de `cluster.toml`, jamais dans les données). De la clé
du domain, le `crypto_kdf` de libsodium (une key derivation function, qui tire d'une clé d'autres clés indépendantes ;
ici par BLAKE2b) dérive trois sous-clés : une nomme les chunks, une nomme les nœuds, une scelle.

Un chunk est scellé par **AEGIS-256** (Wu et Preneel, "AEGIS: A Fast Authenticated Encryption Algorithm", SAC 2013 ;
draft-irtf-cfrg-aegis-aead), le `crypto_aead_aegis256` de libsodium : un **chiffrement authentifié** (authenticated
encryption : il chiffre les octets et y joint un tag, un court code calculé avec la clé qui prouve qu'ils n'ont pas
changé) dont le tag de 256 bits vérifie chaque octet. Son **nonce** de 256 bits (le nombre utilisé une seule fois dont
un chiffrement a besoin) est le nom du chunk : un **synthetic nonce** (un nonce synthétique, tiré du contenu), comme
SIV (Rogaway et Shrimpton, "A Provable-Security Treatment of the Key-Wrap Problem", EUROCRYPT 2006) : deux
chiffrements sous une même clé ne partagent un nonce que pour les mêmes octets, qui donnent alors les mêmes octets
scellés. Ainsi un chunk est scellé en les mêmes octets où qu'il soit scellé, et une copie d'un vault peut être vérifiée
octet par octet sans ses clés. L'en-tête du record (l'entrée stockée d'un chunk ou d'un nœud : un en-tête, puis les
octets scellés) — format, sorte, codec, domain, longueur brute — et son nom sont authentifiés avec lui : un record
déplacé, ou un champ changé, ne s'ouvre pas.

Pourquoi AEGIS-256 plutôt que XChaCha20-Poly1305 (RFC 8439 avec un nonce de 192 bits), le choix habituel : mesurés ici
avec libsodium 1.0.22 sur 64 KiB, AEGIS-256 scelle à 5,7 à 5,9 GB/s et ouvre à 5,8 GB/s, XChaCha20-Poly1305 va à
1,1 GB/s dans les deux sens (AES-256-GCM : 1,2 à 1,4 GB/s, et un nonce de 96 bits seulement, trop court pour être tiré
d'un nom). Un chunk de 64 KiB s'ouvre en 11 µs au lieu de 58 : une lecture de 4 KiB d'un fichier coûte un cinquième de
ce qu'elle coûterait. AEGIS a besoin des instructions AES du processeur pour être rapide (tous les x86-64 depuis 2010 et
tous les ARMv8 avec leur extension de cryptographie les ont).

### Les packs, et leurs index

Les records sont ajoutés à la fin de **packs**, des fichiers de 64 MiB au plus qui ne changent plus une fois écrits
(comme les packs de Git ou de restic) : un fichier écrit d'un coup est rangé en une seule suite, et lu en une seule. Un
pack plein est forcé sur le disque, puis son **index** est écrit à côté de lui (le nom, l'offset, c'est-à-dire la
position en octets, et la longueur de chaque record) : une ouverture lit les index, pas les packs. Un pack sans index
(celui qu'on écrivait quand le processus est mort) est lu en entier à l'ouverture suivante, chaque record vérifié par
ses CRC (des sommes de contrôle : un nombre calculé sur les octets, qui change dès qu'un octet change), forcé (un
processus tué laisse dans le page cache, la copie des fichiers que le noyau garde en mémoire, des records qu'aucun
fsync n'a couverts, et un fichier plus tard peut les trouver stockés et les citer), puis indexé ; on n'y ajoute plus
jamais rien, donc aucun octet écrit n'est jamais réécrit. La table des noms vers les places est en mémoire : environ
100 octets par record (un TB de fichiers à 73 KiB par chunk : 1,4 GB de mémoire ; un index sur le disque est pour plus
tard).

### Un fichier est un arbre de nœuds

Les chunks d'un fichier sont listés par des **nœuds** : un nœud liste jusqu'à 1 024 enfants (un nom et les octets
qu'il couvre), un nœud de niveau 0 liste des chunks, un nœud de niveau k des nœuds de niveau k - 1. La **racine** (le
root) nomme le fichier : un fichier de 1 GB fait environ 14 000 chunks sous 14 nœuds sous sa racine. Un nœud est scellé
et stocké comme un chunk (et retrouvé de même : deux fichiers égaux partagent leur racine). Une plage se lit en
descendant de la racine aux chunks qui la couvrent, chaque nœud choisissant ses enfants par une binary search (une
recherche par moitiés successives) de leurs fins : une lecture de 4 KiB lit un chunk (deux là où elle chevauche une
coupure), quelle que soit la taille du fichier. Les nœuds et les chunks une fois lus sont gardés en mémoire, décodés
(96 MiB, dont un tiers pour les nœuds, remplacés par CLOCK, qui garde un bit « servi récemment » par entrée et chasse
la première entrée dont le bit est à zéro : Corbató 1968) : un chunk relu est servi sans le disque, sans le tag et sans
le codec, puisqu'il a été vérifié à sa lecture. Un effacement vide les deux caches, et un hit (une entrée trouvée dans
le cache) n'est servi que tant que son domain n'est pas effacé (une lecture qui a décodé un chunk juste avant un
effacement peut l'ajouter après).

### Chaque lecture est vérifiée

Un chunk lu sur le disque est vérifié avant qu'aucun de ses octets ne soit donné : le CRC-32C de son en-tête, le nom
qu'il porte (celui qui est demandé : un record déplacé par-dessus un autre est refusé), son tag (AEGIS-256 vérifie
chaque octet, en temps constant, c'est-à-dire en un temps qui ne dépend pas des octets et ne laisse donc rien deviner),
la longueur de sortie du codec, et le CRC-32C des octets bruts, gardé à l'intérieur des octets scellés (un codec qui se
trompe est refusé aussi). Un chunk qui échoue est une erreur `damaged`, jamais un octet servi ; stocker de nouveau le
même fichier réécrit un chunk endommagé (un chunk trouvé stocké est relu et vérifié avant qu'un nouveau fichier ne le
cite).

### Écrire un fichier, et un crash

1. Le writer du vault découpe les octets, nomme chaque chunk, et ajoute les chunks qu'il ne trouve pas, puis les
   nœuds.
2. `finish` force le pack (et, pour un nouveau pack, son dossier), et seulement ensuite rend la racine. Le fsync est
   partagé par les puts qui finissent en même temps (**group commit**, comme le journal d'une base de données : Gray et
   Reuter, *Transaction Processing*, 1993, 9.4.7) : il tourne hors du lock (le verrou qui ne laisse passer qu'un
   thread à la fois) sous lequel on ajoute, un fsync à la fois ; un put qui finit pendant que tourne le fsync d'un
   autre l'attend, et rend la main sans fsync à lui quand ses records ont été ajoutés avant le début de ce fsync. Un
   fsync raté arrête le vault (un fsync suivant peut réussir sans écrire les pages que le raté a abandonnées : Rebello
   et al., ATC 2020).
3. Le serveur écrit ensuite les faits du fichier comme n'importe quel groupe (G1 à G3).

Un crash avant la fin de l'étape 2 laisse des chunks qu'aucun fait ne cite : ils sont sans danger (et seront repris
par un nettoyage du vault, pas encore construit). Un crash après elle laisse un fichier dont les octets sont tous là,
et peut-être encore aucun fait. Aucun fait ne cite jamais un chunk qui n'est pas sur le disque
([G22](guarantees.md#g22-les-fichiers-sont-durables-avant-leurs-faits)).

### Effacer un propriétaire

`Erase(owner)` réécrit le fichier des clés sans la clé du propriétaire, et avec une marque qui dit que le domain est
effacé (il n'est jamais recréé : un nouveau fichier de ce propriétaire est refusé). Chaque chunk des fichiers du
propriétaire est alors scellé par une clé qui n'existe plus nulle part : illisible sur ce disque, dans une replica (une
copie de la base tenue à jour sur une autre machine), dans une sauvegarde des packs (le « crypto-shredding » : détruire
des données en détruisant leur clé). Ce que cela n'efface pas : les faits des fichiers (leurs noms, tailles, types)
restent dans le journal (le fichier où la base ne fait qu'ajouter ses écritures) comme tout fait, jusqu'à ce que le
journal efface lui-même les valeurs personnelles ; et les blocs de l'ancien fichier des clés peuvent rester sur un
disque flash ou sur un système de fichiers copy-on-write (qui écrit chaque changement ailleurs au lieu de réécrire en
place) jusqu'à ce qu'ils soient réutilisés. Ce qui les détruit à coup sûr, c'est une nouvelle master key (les clés
scellées de nouveau sous elle, l'ancienne détruite) : pas encore construit.

### Les copies : ce qui manque à une replica, par des Merkle trees

Une replica a besoin des records qui lui manquent, et de ceux-là seulement. Les noms du vault sont des valeurs uniformes
de 256 bits : leurs 16 premiers bits mettent chacun dans une des 65 536 feuilles d'un **Merkle tree** (un arbre de
hashes, où chaque nœud porte le hash de ses enfants ; Merkle, "A Digital Signature Based on a Conventional Encryption
Function", CRYPTO 1987), le digest (le hash qui résume) d'une feuille étant le BLAKE2b-256 de ses noms triés, celui d'un
nœud le BLAKE2b-256 de ceux de ses 16 enfants (quatre niveaux sous la racine). Deux copies comparent leurs arbres depuis
la racine vers le bas, seulement là où les digests diffèrent, comme l'anti-entropy de Dynamo (la comparaison de fond qui
remet les copies d'accord ; DeCandia et al., SOSP 2007) : pour d records qui manquent à une copie parmi n, au plus 64
digests par différence et les noms d'au plus d feuilles passent d'une copie à l'autre, au lieu de n noms. Les records
sont copiés tels quels (scellés : la copie les vérifie par leurs CRC, et n'a besoin d'aucune clé pour les stocker) ; les
clés des domains partent scellées par la master key, que partagent les copies d'un même cluster (les serveurs qui
tiennent les mêmes bases), et un effacement part avec elles. Construit et testé entre deux vaults d'un même processus ;
le protocole entre serveurs n'est pas construit : une replica ne copie pas encore les fichiers du vault ([le
serveur](server.md#une-replica)).

## Formats

```
DIR/vault/                      0700
DIR/vault/lock                  held while the vault is open
DIR/vault/keys                  "CPHVKEYS" | u32 format (1) | u32 CRC-32C of the 12 bytes before, then entries of 112 bytes:
                                  u32 CRC-32C of bytes 4-111 | u8 op (1 a key, 2 erased) | 3 zero bytes | u64 domain |
                                  a nonce (32) | the key sealed by the master key, AEGIS-256 (32 + 32), op and domain
                                  authenticated; written again whole (beside, renamed) by an erasure, appended otherwise
DIR/vault/packs/N.pack          "CPHVPACK" | u32 format | u32 CRC, then records
DIR/vault/packs/N.idx           "CPHVIDX1" | u32 format | u32 the pack's checked length | u32 count |
                                  (name 32 | u32 offset | u32 length) a record | u32 CRC-32C of everything before
record                          0  u32 CRC-32C of bytes 4-63      16 u32 raw length        32 the name (32 bytes)
                                4  u8 format (1)                  20 u32 sealed length
                                5  u8 kind: 1 chunk, 2 node       24 u32 CRC-32C of the sealed bytes
                                6  u8 codec: 0, 1 LZ4, 2 Zstd     28 u32 0
                                7  u8 0       8 u64 domain
                                then the sealed bytes: AEGIS-256 (nonce: the name; authenticated: bytes 4-19 and the
                                name) of u32 CRC-32C of the raw bytes | the codec's output
node (its raw bytes)            u8 level | varint count (<= 1024) | (name 32 | varint size) a child
```

Tous les entiers sont little-endian (l'octet de poids faible d'abord). Le fait `Content` d'un fichier est le nom de sa
racine en 64 chiffres hexadécimaux minuscules.

## Garanties

- **G22 Les fichiers sont durables avant leurs faits.** Un fait ne cite jamais un chunk ou un nœud qui n'est pas sur le
  disque : `finish` force chaque record dont un fichier a besoin (et le nom d'un nouveau pack) avant de rendre la main,
  et les faits sont écrits après ; la recovery (la remise en état à l'ouverture, après un crash) ne laisse jamais
  tomber un record forcé (un pack sans son index est relu en entier, rien n'est coupé).
- **G23 Aucun octet faux n'est servi.** Un octet d'un fichier n'est donné qu'à partir d'un record dont le tag et le CRC
  des octets bruts sont bons, sous le nom demandé ; sinon `damaged`. Un changement aléatoire passe le tag avec une
  probabilité de 2^-256.
- **G24 Les fichiers d'un propriétaire effacé sont illisibles.** Après `Erase`, aucune lecture de ce vault, ou d'une
  copie qui a pris ses clés depuis, ne donne un octet des fichiers du propriétaire : `erased`.

Leurs tests ([tests](testing.md#le-vault-de-fichiers)) : une coupure de courant simulée à des points aléatoires des puts
(120 seeds, c'est-à-dire 120 valeurs de départ du générateur aléatoire, trois crashes chacune, des secteurs torn,
écrits à moitié, et des secteurs perdus, chaque fichier fini avant le crash relu), `kill -9` d'un processus qui dépose
des fichiers jusqu'à 40 MB et écrit leurs faits (20 tours : chaque fichier cité relu exact, chaque fichier confirmé
présent), des bits changés dans les packs, des records déplacés par-dessus d'autres, des clés effacées et copiées.

## Sécurité

| menace | ce qui l'arrête | test |
|---|---|---|
| un octet changé sur le disque, par une panne ou par une personne | le tag (AEGIS-256) et les CRC de chaque record lu | tests de dommages, 20 000 records changés au hasard |
| un record déplacé ou copié par-dessus un autre | le nom dans son en-tête, authentifié, comparé à celui qui est demandé | le test du record déplacé |
| une copie des données, un disque volé | tout est scellé ; les clés des domains sont scellées par la master key, qui n'est pas dans les données | le fichier des clés ne tient aucune clé en clair |
| deviner si un fichier est stocké (la déduplication comme oracle, un moyen de poser une question qu'on ne devrait pas pouvoir poser) | des noms à clé du domain ; aucune déduplication entre domains | des domains ne partagent jamais un chunk |
| un token qui ne peut pas lire le kind | Load vérifie le droit sur le Content du kind ; une racine n'est jamais prise du client, seulement du fait | tests de droits du serveur |
| un propriétaire effacé | la clé partie du fichier des clés, un domain jamais recréé | tests d'effacement |
| un fichier énorme, beaucoup de puts | 1 TiB par fichier, 4 puts à la fois par connexion, noms de 4 KiB, types de 255 octets, frames (les messages du protocole) de 16 MiB | tests de bornes |
| un record, un nœud ou une frame malformé | chaque longueur vérifiée avant qu'un octet ne soit lu ou écrit ; les sorties des codecs bornées ; une fenêtre Zstandard de 1 MiB au plus | le fuzzer OCaml (il nourrit le code d'entrées générées et mutées), `test/fuzz_vault.c` sous libFuzzer et les sanitizers (des contrôles que le compilateur ajoute pour arrêter le programme à la première faute de mémoire ou au premier comportement indéfini), 24 000 requêtes changées |
| une clé dans un log | les clés ne sont jamais écrites dans un log ; le fichier de la master key est refusé si d'autres peuvent le lire, ou si c'est un lien | |
| le timing (deviner un secret à la durée d'une opération) | le tag est vérifié en temps constant par libsodium ; les entrées de la master key sont ouvertes, pas comparées | |

Le C que fait tourner le vault, ce sont LZ4 et Zstandard copiés dans le dépôt, libsodium, et `vault/vault_stubs.c`
(une centaine de lignes qui convertissent des valeurs, chaque offset vérifié en OCaml avant l'appel), fuzzés avec
libFuzzer :

```text
clang -g -O1 -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=all -DCEPHEUS_VAULT_CORE_ONLY \
  -I vendor/zstd-1.5.7/lib test/fuzz_vault.c vault/vault_stubs.c vault/lz4_lib.c vault/zstd_lib.c -lsodium \
  -o fuzz_vault && ./fuzz_vault -max_len=300000 -max_total_time=300
```

## Ce qu'il coûte

Mesuré sur la machine des [benchmarks](benchmarks.md) (les mesures de vitesse faites selon une méthode fixe ; Intel
i7-4720HQ de 2015, 4 cœurs, 11 GB, btrfs sur un SSD SATA), partagée avec d'autres travaux, par `bench/vbench.exe`, le
2026-11-13 : 21 exécutions pour chaque mesure, la médiane et son intervalle à 97,3 % par order statistics (deux
valeurs prises à un rang fixe dans les mesures triées, comme dans les [benchmarks](benchmarks.md#méthode)). Les
octets : les premiers 1 MB, 100 MB et 1 GB de 1 GiB des propres fichiers du système mis bout à bout (`/usr/lib`,
`/usr/bin`, la documentation, les pages de manuel) : des programmes, des bibliothèques et du texte. Chaque put va dans
un vault en service (la clé de son domain déjà faite), et se termine quand `finish` l'a forcé sur le disque. Un **cache
froid** (cold cache), ce sont les pages des packs retirées du page cache du noyau et le vault rouvert (ses propres
caches vides) ; le système de fichiers, ce sont les mêmes octets lus d'un seul fichier par lectures de 1 MiB.

**Un fichier déposé et lu en entier** (MB/s, sauf les deux premières lignes ; put : le dépôt, get : la lecture du
fichier entier ; workers : des threads de travail) :

| | 1 MB | 100 MB | 1 GB |
|---|---|---|---|
| sur le disque, warm (LZ4) | 49,8 % | 55,1 % | 52,0 % |
| sur le disque, cold (Zstandard 9) | 33,6 % | 37,7 % | 35,8 % |
| put warm, 3 workers | 112 [78 ; 127] | 174 [138 ; 224] | 137 [111 ; 143] |
| put warm, un seul cœur | 77 [65 ; 92] | 111 [88 ; 125] | 104 [95 ; 116] |
| put cold | 44 [27 ; 56] | 64 [58 ; 68] | 64 [59 ; 70] |
| get warm, page cache | 865 [657 ; 961] | 1 119 [1 060 ; 1 183] | 784 [633 ; 834] |
| get warm, cache froid | 113 [88 ; 145] | 791 [676 ; 829] | 870 [747 ; 885] |
| get stocké cold, page cache | 503 [458 ; 544] | 512 [439 ; 551] | 541 [517 ; 578] |
| get stocké cold, cache froid | 109 [58 ; 152] | 460 [383 ; 486] | 546 [502 ; 574] |
| système de fichiers, page cache | 4 193 [3 626 ; 4 639] | 5 279 [4 611 ; 6 506] | 538 [452 ; 568] |
| système de fichiers, cache froid | 74 [67 ; 93] | 387 [336 ; 471] | 533 [409 ; 541] |

La colonne de 1 GB vient de la version d'avant le cache de chunks et les batches (les lots) d'un buffer (une zone de
mémoire de travail) plein : une exécution plus récente demande plus que les 3 GB que le banc de mesure peut prendre (il
tient tout le GiB en mémoire, ce que le serveur ne fait jamais) ; à 100 MB, cette version était plus lente ou égale sur
chaque ligne (put 144, 108 et 54 MB/s, get 971, 818, 509 et 510).

- **Put** : 100 à 175 MB/s en warm, 44 à 64 en cold. Un put nomme chaque chunk par BLAKE2b (0,92 à 1,02 GB/s par cœur,
  mesuré), le scelle et l'ajoute ; trois workers vont 1,3 à 1,6 fois plus vite qu'un seul cœur. LZ4 et AEGIS-256 ne
  sont pas ce qui le limite (tous deux à plusieurs GB/s) ; Zstandard au niveau 9 l'est, pour un put cold.
- **Get depuis la mémoire** : 0,8 à 1,1 GB/s en warm, 0,5 pour un fichier stocké en cold (le décodeur de Zstandard).
  Là, **le système de fichiers gagne**, environ 5 fois (à 1 MB et 100 MB ; le fichier de 1 GB n'est pas resté dans le
  page cache) : une copie depuis son cache, contre un tag vérifié, un décodage et un CRC pour chaque octet.
- **Get depuis le disque** : le vault lit moitié moins d'octets, donc à 100 MB et 1 GB il lit plus vite que le système
  de fichiers (791 contre 387 MB/s, 870 contre 533). À 1 MB, tous deux paient leurs premières lectures (113 contre 74).

**4 KiB à des endroits aléatoires**, 21 exécutions de 1 000 lectures (la médiane et le 99e percentile de chaque
exécution, c'est-à-dire la durée sous laquelle tombent 99 % de ses lectures, puis leurs médianes) :

| | vault | système de fichiers (`pread`) |
|---|---|---|
| un fichier de 1 GB dans le page cache : médiane | 80,8 µs [73,9 ; 94,9] | **2,86 µs** [2,15 ; 2,86] |
| son p99 | 451 µs [366 ; 568] | 508 µs [426 ; 646] |
| un fichier de 1 GB, mémoire partagée avec d'autres (le fichier surtout hors du page cache) : médiane | **123 µs** [98 ; 139] | 332 µs [314 ; 345] |
| son p99 | 1,14 ms [0,55 ; 2,95] | 812 µs [764 ; 879] |
| les 8 premiers MiB du fichier (dans le cache de chunks) : médiane | **0,95 µs** [0,95 ; 1,19] | 1,91 µs [1,91 ; 1,91] |
| son p99 | 2,15 µs [2,15 ; 4,05] | 2,15 µs [2,15 ; 6,91] |

Une lecture de 4 KiB décode tout son chunk (73 KiB en moyenne : lecture, tag, codec, CRC) : 81 µs là où le page cache
donne les 4 KiB du système de fichiers en 2,9 µs, le prix de chunks qui se compressent et sont stockés une seule fois.
Un chunk relu vient du cache de chunks, sans appel système : 0,95 µs. Quand la mémoire manque, les packs du vault, deux
fois plus petits que le fichier, gardent une plus grande part d'eux-mêmes dans le page cache : la deuxième ligne.

**Beaucoup de petits fichiers** : 400 fichiers de 1 à 16 KiB, chacun déposé seul, par 1, 4 et 16 threads à la fois
(fichiers par seconde) :

| threads | un fsync chacun (avant le group commit) | group commit |
|---|---|---|
| 1 | 147 [125 ; 218] | 161 [60 ; 199] |
| 4 | 160 [113 ; 191] | 503 [385 ; 735] |
| 16 | 143 [115 ; 224] | **2 155** [1 900 ; 2 444] |

Un put seul attend son fsync (environ 6 ms sur ce SSD : quelque 160 puts par seconde) ; des puts simultanés en
partagent un, et 16 threads déposent 13 fois plus de fichiers qu'un seul.

**La place sur de vrais fichiers**, chaque ensemble déposé dans un vault neuf (une seule exécution : les octets ne
varient pas) :

| fichiers | octets | sur le disque, warm | sur le disque, cold | chunks trouvés déjà stockés |
|---|---|---|---|---|
| 1 339 images (PNG, JPEG) d'un ordinateur de bureau | 390 MB | 48,0 % | 47,2 % | 2 269 (des copies) |
| 421 logs | 50,5 MB | 21,0 % | 12,6 % | 216 |
| 1 408 fichiers source | 7,6 MB | 54,7 % | 36,7 % | 166 |

Les images sont déjà compressées : ce que le vault gagne sur elles, ce sont leurs copies. Un petit fichier coûte un
chunk et un nœud (deux records de 64 octets d'en-tête et de 32 de tag) : pour des fichiers de quelques KiB, quelques
pour cent.

**Ce que coûte au reste le fait de lier le vault** (de l'inclure dans le programme) : le programme `cepheus` démarre
en 4,68 ms au lieu de 4,40 (21 tours de 100 démarrages, en alternance avec la version sans le vault : rapport 1,08),
pour moitié libsodium (chargée et démarrée) et pour moitié un programme plus gros. Le temps qu'un serveur met à être
prêt (11,0 contre 10,8 ms), 20 000 pings, et les lectures ponctuelles (une chose lue par son id), une et 16 en cours,
sont égaux (rapports 0,96 à 1,05, chaque intervalle contenant 1). Les programmes Cesia ne lient pas le vault.

### À côté des géants (d'après leur documentation)

- **Les large objects de PostgreSQL** découpent un fichier en pages de `LOBLKSIZE` (un quart de bloc : 2 kB), une ligne
  de `pg_largeobject` chacune, lues par plages comme ici ; ils ne sont ni dédupliqués ni scellés par une clé de
  propriétaire (PostgreSQL ne chiffre rien au repos par lui-même). Cela ne change aucun choix ; c'est pourquoi les
  chunks du vault sont plus gros (un codec compresse bien mieux un chunk de 64 KiB qu'une page de 2 kB).
- **Un object store à la S3** (un stockage d'objets, des fichiers rangés sous une clé et lus par HTTP) garde chaque
  objet entier, lu par plages (HTTP `Range`), vérifié par un checksum de l'objet ou de ses parties, et scellé avec une
  clé que donne la requête (SSE-C, le chiffrement côté serveur avec la clé du client) ; deux versions d'un objet ne
  partagent rien. Cela ne change aucun choix non plus : des chunks découpés selon le contenu sont ce qui permet à un
  vault de garder deux versions d'un fichier pour le prix d'une seule et de sa modification.

## Ce qu'il ne fait pas encore

- **Le nettoyage** : les chunks qu'aucun fait ne cite (un put interrompu, les fichiers d'un propriétaire effacé)
  restent dans les packs jusqu'à ce qu'un nettoyage marque ce que les faits et l'historique citent et réécrive les
  packs (comme `restic prune`).
- **La réplication entre serveurs** : la comparaison et la copie sont construites ; le protocole, son modèle TLA+ (un
  langage pour décrire un système et en vérifier tous les états ; ici : chaque chunk cité présent sur la replica), et la
  réparation d'un chunk endommagé depuis une replica ne le sont pas : une replica ([le serveur](server.md#une-replica))
  ne copie pas encore les fichiers du vault.
- **Une nouvelle master key** (la clé de chaque domain scellée de nouveau), et l'effacement des faits personnels par le
  journal.
- **Un index des noms sur le disque** plutôt qu'en mémoire, pour des vaults de nombreux téraoctets.
