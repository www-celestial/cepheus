# Erreurs

Chaque erreur que Cepheus renvoie ou lève, le message exact, d'où elle vient, ce qu'elle veut dire, et que faire. Un
message du tableau est le texte à l'intérieur du constructeur ; `message e` ajoute la sorte devant (`"invalid: "`,
`"conflict: "`...). Les messages sont en anglais, tels que les programmes les affichent. Dans les messages, `#E` est un
numéro de chose, `P` un numéro de propriété, `NAME` le nom d'une propriété, `V` une valeur telle que l'affiche
`Value.to_string` (un texte entre guillemets, un lien comme `#E`, `money 120000`, `date 1700000000000`), `T` un type
(`int`, `float`, `bool`, `text`, `date`, `money(2)`, `link`), et `SEG` le nom de fichier d'un segment.

```ocaml
open Cepheus

let () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ email; age ]) = declare db [ prop ~unique:true "client/email" Ttext; prop "client/age" Tint ] in
  let ada = thing (Result.get_ok (write db [ Add (-1, email, Text "ada@example.com") ])) (-1) in
  let try_ ops = match write db ops with Ok r -> Printf.printf "ok, group %d\n" r.group | Error e -> print_endline (message e) in
  try_ [ Add (-1, email, Text "ada@example.com") ];
  try_ [ Add (ada, age, Text "forty") ];
  try_ [ Add (ada + 1, age, Int 40) ];
  try_ [ Expect (ada, age, None); Add (ada, age, Int 40) ];
  try_ [ Expect (ada, age, None); Add (ada, age, Int 41) ];
  try_ [ Add (ada, 99, Int 1) ]
```

```output
not unique: client/email "ada@example.com" is taken
invalid: "forty" is not a int (property client/age)
invalid: no thing #65537
ok, group 4
conflict: #65536 has a value for client/age (property 17)
invalid: no property 99
```

Une écriture qui échoue ne change rien : aucun numéro de groupe n'est utilisé, aucun numéro de chose n'est pris.

## `Conflict` : un `Expect` n'a pas tenu

Renvoyée par `write`. Le groupe a été vérifié contre l'état le plus récent et l'un de ses `Expect` était faux : un autre
groupe a changé le fait depuis la vue que le client a lue. **Que faire** : prendre une nouvelle vue, décider à
nouveau, écrire à nouveau (la boucle habituelle de l'optimistic concurrency, le contrôle de concurrence optimiste).

| message | quand |
|---|---|
| `#E has a value for N (property P)` | `Expect (E, P, None)`, et E a une valeur pour P, dont le nom est N |
| `#E does not have V for N (property P)` | `Expect (E, P, Some V)`, et le fait (E, P, V) ne tient pas ; N est le nom de P |

## `Not_unique`

| message | quand | que faire |
|---|---|---|
| `NAME V is taken` | après le groupe, une autre chose a la valeur V pour la propriété unique NAME | choisir une autre valeur, ou la retirer de l'autre chose dans le même groupe |

## `Invalid` : la requête est fausse

Rien n'a été écrit. **Que faire** : corriger la requête ; réessayer sans rien changer donne la même erreur.

Depuis `write` (les vérifications du writer, les mêmes sur une base et sur un fork) :

| message | quand |
|---|---|
| `no property P` | P n'est pas une propriété déclarée de la vue |
| `Expect on a new thing` | un `Expect` nomme une chose négative (nouvelle) : elle n'a aucun fait avant le groupe |
| `Expect: V is not a T` | la valeur d'un `Expect` n'est pas du type de la propriété |
| `V is not a T (property NAME)` | un `Add` ou un `Retract` avec une valeur du mauvais type |
| `no thing #E` | E vaut 65 536 ou plus et la base ne l'a jamais créée |
| `no thing #E to link to` | un `Link` vers un numéro sous 16, ou vers une chose jamais créée |
| `#E is a system thing` | E est sous 16 : ces numéros sont réservés |
| `a property thing takes only cepheus/ properties` | une propriété ordinaire écrite sur une chose propriété (16 à 65 535) |
| `cepheus/ properties describe property things only` | `cepheus/name`, `type`, `many` ou `unique` écrit sur une chose ordinaire |
| `property P needs both a name and a type` | un groupe a laissé la chose propriété P avec un nom et pas de type, ou l'inverse |
| `property P keeps cepheus/many or cepheus/unique without a name and a type` | un groupe a laissé la chose propriété P avec `cepheus/many` ou `cepheus/unique` mais ni nom ni type |
| `property P has an unknown type code C` | `cepheus/type` tient un code qu'aucun type n'a (`Tmoney` avec plus de 18 chiffres) |
| `the type and the cardinality of NAME never change` | un groupe a changé le type ou le drapeau `many` d'une propriété ; déclarez une autre propriété |
| `NAME cannot become unique: two things share a value` | `cepheus/unique` mis à true alors que deux choses partagent une valeur |
| `NAME still has values` | le nom et le type d'une propriété retirés alors que des choses ont encore des valeurs pour elle |
| `a group of N bytes is over the frame limit of 268435456` | le codage du groupe dépasse 256 MiB, le plus grand corps de frame : découpez-le ([limites](limits.md#les-écritures)) |
| `thing numbers end at 2147483647: this group would make #N` | les nouvelles choses du groupe prendraient des numéros de chose au-delà de $2^{31} - 1$, le plus grand que tient un run ([limites](limits.md#choses-propriétés-valeurs)) ; la base ne peut plus créer de choses |

Depuis `write` avec des règles (le raisonnement du writer, le même sur une base et sur un fork ; [règles](rules.md)) :

| message | quand |
|---|---|
| `[#E P V] is derived by rule R from F and G: retract one of those` | un `Retract` d'un fait qui n'est que dérivé : ses prémisses le dériveraient à nouveau ; retirez les faits affirmés qu'il nomme (les faits d'une preuve) |
| `[#E P V] is derived by a rule` | la même chose, quand aucune preuve n'a pu en être affichée |
| `rule R derived more than N facts from a group of K facts` | les changements dérivés du groupe dépassent le budget, $N = \mathit{base} + \mathit{per} \times K$ ([api](api.md#règles), `rule_budget`) ; R est celle qui a le plus dérivé. Découpez l'écriture, ou relevez le budget |
| `constraint R: FACTS` | le groupe rendrait vrai le corps de la contrainte R : FACTS sont les faits d'une instance |
| `rule R gives #E a second value of NAME, which takes one` | une valeur dérivée d'une propriété à une seule valeur à côté d'une autre valeur |
| `rule R gives NAME V, which another thing has` | une valeur dérivée d'une propriété unique qu'une autre chose tient |
| `rule R gives a fact about #E, which does not exist` | une tête nomme une chose que la base n'a jamais créée |

Depuis `define`, ou une écriture des faits d'une règle (une règle est vérifiée quand elle est écrite) :

| message | quand |
|---|---|
| `NAME is the name of a property` | `define` avec une règle nommée comme une propriété |
| `rule NAME: its body has no pattern` | `where` est vide |
| `rule NAME: N variables (at most 64)` | `vars` au-dessus de 64 |
| `rule NAME: variable ?K out of range` | un pattern ou la tête utilise K hors de 0 à `vars - 1` |
| `rule NAME: variable ?K appears in no pattern of the body` | une variable sous `vars` qu'aucun pattern du corps n'utilise |
| `rule NAME: the thing of a pattern is a variable or a thing` | la chose d'un pattern est un `Val` |
| `rule NAME: no property P` / `… no property P in its head` | un pattern ou la tête nomme une propriété qui n'existe pas |
| `rule NAME: variable X is both a T and a U` | comme pour une question |
| `rule NAME: a range needs an int, date or money variable` / `… the bounds of ?X are not of its type` | un intervalle sur un autre type, ou des bornes d'un autre type |
| `rule NAME: V is not a T` | une constante du mauvais type pour sa propriété |
| `rule NAME: its head gives a cepheus/ property` | une tête sur une propriété système |
| `rule NAME: ?K is not a thing` / `… the thing of its head is a variable or a thing` / `… its head's thing #T is not an ordinary thing` | la chose de la tête n'est ni une variable de lien ni une chose ordinaire |
| `rule NAME: ?K is a T, NAME takes a U` / `… NAME takes a T, not a thing` | la valeur de la tête ne convient pas à sa propriété |
| `rule NAME: cannot read its definition at character N` / `… its definition is not in canonical form` | un fait `cepheus/rule` écrit à la main qui n'est pas le texte canonique d'une règle (Rules.to_text) |
| `rule R takes a name and a definition only` / `rule R needs a name and a definition, and no type` | une chose règle avec `cepheus/many`, `cepheus/unique` ou `cepheus/type`, ou sans son nom |
| `NAME is a property: it never becomes a rule` / `a rule never becomes a property (NAME)` | une chose du schéma changée d'une sorte en l'autre |

Depuis `declare` et `snapshot` :

| message | quand |
|---|---|
| `NAME is declared already as another kind of property` | `declare` avec un nom qui existe avec un autre type, une autre cardinalité ou un autre drapeau unique |
| `a fork has no files` | `snapshot` sur un fork |

Depuis `find` et `fold` (la question est mal formée) :

| message | quand |
|---|---|
| `no property P` | un pattern nomme une propriété qui n'existe pas |
| `variable X out of range` | un pattern utilise la variable X hors de 0 à `vars - 1` |
| `variable X is both a T and a U` | X apparaît avec deux propriétés de types différents (une place de chose est un `link`) |
| `variable X appears in no pattern` | une variable sous `vars` qu'aucun pattern n'utilise |
| `V is not a T` | une valeur constante du mauvais type pour sa propriété |
| `a range needs an int, date or money variable` | un intervalle sur une variable texte ou flottante, ou sur une variable hors de 0 à `vars - 1` (les intervalles acceptent aussi les variables bool et link) |

## `Damaged` : des données durables perdues ou changées

Les fichiers ne tiennent plus ce que la base a rendu durable : un disque qui a changé des octets, un fichier mal copié,
un segment supprimé à la main. La base **refuse de s'ouvrir** plutôt que de laisser tomber un groupe confirmé en
silence (G6). **Que faire** : ne supprimez ni ne modifiez aucun fichier ; copiez le répertoire à part ; lancez
`Cepheus.verify` sur la copie pour trouver le premier défaut ; restaurez depuis une sauvegarde. Ne coupez un journal à
la main que si vous savez que la frame endommagée n'a jamais été confirmée
([opérations](operations.md#quand-la-recovery-dit-damaged)).

Depuis `open_` (la recovery, la remise en état à l'ouverture) et `verify` ; `SEG` est le nom du segment, un offset est
en octets depuis le début du segment :

| message | ce qu'il veut dire |
|---|---|
| `DIR/cepheus is not a Cepheus database file` | le fichier d'identifiant de la base ne fait pas 37 octets, ou son nombre magique ou son CRC est faux |
| `SEG: unknown format F` | un en-tête de segment qui se vérifie mais a un format autre que 2, celui du journal (un segment de format 1 est converti à l'ouverture) |
| `SEG: a segment of another database` | l'identifiant de base du segment n'est pas celui de cette base (fichiers de deux bases mélangés) |
| `journal: segment SEG, where the snapshot starts, is missing` | le run le plus récent reprend dans un segment qui n'est pas là |
| `journal: the first segment starts at group G` | aucun run, et le segment le plus ancien ne commence pas au groupe 1 |
| `journal: SEG does not follow group G (a segment is missing)` | un trou entre deux segments |
| `journal: SEG has a broken header` | un segment autre que le plus récent a un en-tête qui ne se vérifie pas |
| `journal: SEG says it starts at group G` | l'en-tête d'un segment et son nom de fichier ne sont pas d'accord |
| `journal: SEG is shorter than the snapshot says` | le run le plus récent reprend au-delà de la fin du segment |
| `SEG: frame at O starts at group G, expected N` | une frame qui se vérifie, hors de la séquence |
| `SEG: group G where N was expected` | un groupe hors de la séquence à l'intérieur d'une frame |
| `SEG: frame at O does not decode` | une frame qui se vérifie mais dont les groupes ne peuvent pas être lus |
| `SEG: frame at O has bytes after its groups` | la même chose |
| `SEG: damaged frame at offset O (written whole)` | la frame ne se vérifie pas, et un en-tête de frame plus loin se vérifie ou son trailer correspond à son corps : autrefois durable, maintenant endommagée |
| `SEG: segment ends with a broken frame at O` | une frame qui ne se vérifie pas à la fin d'un segment qui n'est pas le plus récent (les segments sont forcés en entier avant que le suivant commence) |
| `the journal ends at group G, before the snapshot of group S` | le run le plus récent tient des groupes que le journal a perdus (un run n'est nommé qu'une fois ses groupes durables) |
| `group N uses property P, which does not exist` | le replay a rencontré un changement d'une propriété qu'aucun groupe n'a déclarée |

Depuis `verify` seulement (une lecture complète est stricte : la recovery répare ceux-ci, donc après elle ce sont des
dommages) :

| message | ce qu'il veut dire |
|---|---|
| `journal: the newest segment has a broken header` | un segment le plus récent torn (écrit en partie seulement) à sa création, jamais réparé par une recovery |
| `SEG: the trailer of the frame at O is damaged` | une frame dont l'en-tête et le corps se vérifient, mais pas son trailer |
| `SEG: the frame at O does not check` | la frame la plus récente ne se vérifie pas (une fin torn, ou un dommage de la frame la plus récente : le cas résiduel de G6) |

Depuis les lectures des runs (`find`, `fold`, `write` et `snapshot` renvoient `Damaged` ; `get`, `values`, `things` et
le `write` d'un fork lèvent `Unreadable` avec le même message) :

| message | ce qu'il veut dire | que faire |
|---|---|---|
| `run NAME: page K does not check` | la page K (16 KiB) du fichier d'un run a été lue sur le disque et son CRC-32C ne correspond pas : jamais servie | le run est endommagé (c'est un cache : le journal est intact). Fermez la base et ouvrez-la à nouveau : un run qui tient dans le cache est vérifié en entier à l'ouverture et mis de côté. Un plus grand n'est pas lu en entier à l'ouverture : sortez son fichier de `snapshots/` (gardez-le pour le diagnostic) et ouvrez à nouveau ; les autres runs et le journal reconstruisent l'état |
| un message de `Disk.Io` (plus bas) | le disque n'a pas pu lire la page | comme pour `Io` |

Les **runs mis de côté à l'ouverture** ne sont pas des erreurs : l'ouverture choisit une autre chaîne de runs sans lui,
ou rejoue le journal, et `notes db` liste `snapshot NAME set aside: REASON`, où REASON est l'un de `shorter than its
header`, `not a run`, `its header does not check`, `unknown format F`, `a run of another database`, `its groups are not
those of its name`, `bad counts`, `its journal position is after its group`, `shorter than its header says`, `its
checksum table does not check`, `its layout does not match its size`, `the rank table of its additions is out of
order`, `the rank table of its additions does not end at N` (et la même chose pour `its retractions`), `the thing
offsets of its additions is out of order`, `the property offsets of its retractions does not end at N` (chaque table de
chaque partie), `the text offsets is out of order`, une erreur de schéma du tableau ci-dessus, une page qui ne se
vérifie pas, ou un message de `Disk.Io`. Un snapshot d'un format plus ancien (`<group>.snap`, format 4 et avant) donne
`snapshot NAME set aside: an earlier format, the journal is replayed` : l'ouverture rejoue tout le journal une fois, et
le premier merge supprime l'ancien fichier.

## `Io` : le disque a lâché

Un appel système a échoué. Pendant une écriture ou un fsync du journal (fsync : l'appel système qui attend que les
octets écrits soient vraiment sur le disque), la base **s'arrête** (G10) : ce groupe et chaque groupe suivant renvoient
un `Io`, `snapshot` aussi ; elle ne retente jamais le fsync, parce qu'après un fsync qui échoue le noyau a marqué clean
(identiques au disque) les pages qu'il n'a pas pu écrire, et un second fsync réussirait sans les écrire (Rebello et al.
2020). Le writer ramène aussitôt le journal à sa dernière frame durable, si bien que les écritures qui ont échoué sont
absentes (G13). **Que faire** : réparez le disque (place, permissions, matériel), fermez la base avec `close` et
ouvrez-la à nouveau : la recovery repart du journal, après avoir écrit à nouveau sa frame la plus récente (aucun
redémarrage de la machine n'est nécessaire). Un merge qui échoue n'arrête pas la base (plus bas) ; un grand groupe dont
le fichier de run échoue renvoie `Io` pour ce seul groupe. Le message est `CALL PATH: REASON`, où CALL est l'un de
`open`, `read`, `write`, `lseek`, `fstat`,
`ftruncate`, `fsync`, `close`, `rename`, `unlink`, `mkdir`, `readdir`, `lock`, et REASON le texte du système (`No space
left on device`) ; ou bien `read PATH: short file` (un fichier plus court que ne le dit son en-tête), `file N is
closed`, `journal is closed`, et `journal: an earlier write failed; reopen the database` (les écritures après le
premier échec).

## `Busy` et `Closed`

| erreur | message | quand | que faire |
|---|---|---|---|
| `Busy` | `DIR is open in another process` | un autre processus tient `DIR/lock`, ou ce processus a déjà la base ouverte, sous ce chemin ou n'importe quel autre qui nomme le même répertoire (un lien symbolique, `DIR/.`, `x/../DIR`) | fermer l'autre ; un seul moteur par base |
| `Closed` | `the database is closed` | `write` ou `snapshot` après `close` | ouvrir la base à nouveau |

## Exceptions

| exception | levée par | quand |
|---|---|---|
| `Unreadable of string` | `get`, `values`, `things`, le `write` d'un fork | une page d'un run ne peut pas être lue ou ne se vérifie pas (plus haut) |
| `Not_found` | `thing r k` | k n'est pas une nouvelle chose du groupe du reçu r |
| `Failure "Cepheus needs the processor's CRC-32C instruction (SSE4.2 on x86-64, CRC32 on arm64), and this processor has none"` | le démarrage du programme, avant que son propre code tourne (l'initialisation de `Crc32c`) | le processeur n'a pas l'instruction qu'utilise chaque checksum ([limites](limits.md#les-fichiers-et-la-plateforme)) : un x86-64 plus ancien que le niveau x86-64-v2, ou un arm64 ARMv8.0 sans les instructions CRC32 optionnelles. Lancez-le sur une autre machine ; rien n'a été lu ni écrit |
| `Failure "bootstrap: ..."` | `open_` d'une nouvelle base | le premier groupe, qui décrit les propriétés système, a été refusé : un bug |
| `Invalid_argument` | internals | un invariant cassé, ce qui est un bug : `Journal.append: groups out of order`, `Engine.install: not durable`, `Snapshot.merge: ...` (une section qui déborde ou dont les comptes ne tombent pas juste, un retrait sans rien en dessous, un fait d'un grand groupe au-delà des choses, la position du journal après la vue, plus de runs que n'en a la vue) ; `Pages: a page of a base built in memory is missing` ; ou un mauvais usage d'une fonction interne (`Codec.reader`, `Codec.put_varint` d'un nombre négatif, `Crc32c.bytes`, `Crc32c.extend`, `Rng.int`) ; `Journal.append: frame too large` (le writer ne fait jamais de frame au-delà de 256 MiB, c'est donc un bug) ; et `Cepheus.decode: variable X out of range` ou `Cepheus.decode: MSG` (une question que `fold` refuse), un mauvais usage de `decode` |

## À travers le serveur

Un programme connecté au serveur reçoit chaque erreur ci-dessus comme une valeur `{code, message}` (`conflict`,
`invalid`, `unique`, `damaged`, `io`, `busy`, `closed`), et les codes propres au serveur : `auth`, `denied`, `version`,
`too_large`, `unknown_database`, `stopping`, `refused`, `too_many_connections`, `idle`. Chacun, quand il arrive et que
faire : [le serveur](server.md#erreurs).

## Dans un programme Cesia

Le client Cesia ([Cepheus depuis Cesia](cesia.md)) donne chaque erreur ci-dessus, et celles du serveur, comme une
valeur `result.Err({Kind: "cepheus", Code, Message})`, avec les codes en minuscules (`conflict`, `unique`, `invalid`,
`damaged`, `io`, `busy`, `closed`, et ceux du serveur), et ajoute les siennes :

| Code | Message | quand | que faire |
|---|---|---|---|
| `invalid` | `P needs a Text` (an Int, a number, a Bool, a date in seconds since 1970, an amount), `not V` | une valeur donnée pour la propriété P n'est pas de son type | donner une valeur du type de la propriété |
| `invalid` | `P needs an amount that fits` | une valeur Money au-delà de 63 bits une fois en unités mineures | un montant plus petit |
| `invalid` | `the kind K has no field F` | un champ donné à Insert ou Update que le kind ne déclare pas | corriger le nom du champ (il n'est jamais laissé tomber en silence) |
| `invalid` | `P is not declared in this database: give its kind to Connect (or Fork)` | un kind utilisé sur une base à qui on ne l'a pas donné | ajouter le kind à la liste de Connect, ou de Fork |
| `invalid` | `P is a T in this database, not a U` | la base déclare la propriété avec un autre type | le kind doit correspondre au schéma de la base |
| `invalid` | `Insert needs at least one field of K`, `Update needs at least one field of K`, `Update needs the id of a thing, not N`, `a group needs at least one operation` | une écriture vide | écrire quelque chose |
| `invalid` | `P holds several values: change them with Write, Add and Retract` | un Update d'un champ à plusieurs valeurs | `cepheus.Write` avec `Add` et `Retract` |
| `invalid` | `Above, Below and Between are for ints, dates and money, not a T`; `a variable of Above, Below or Between appears in no pattern` | un intervalle sur un autre type, ou sur une variable d'aucun pattern | filtrer les lignes en Cesia (`list.Filter`) |
| `invalid` | `H is reached over the network: give the cluster's certificate authority, ca = "/etc/cepheus/ca.pem"` | Connect par TCP sans `ca` | le `ca.pem` du cluster (créé par `cepheus cluster init`) |
| `invalid` | `a fork starts from Empty, another fork, or a database read on the server's machine; this one is read at the server` | un Fork d'une base atteinte par le réseau | faire un fork de `cepheus.Empty`, ou tourner sur la machine du serveur |
| `closed` | `this database was closed` | un appel sur une base après `cepheus.Close` | se reconnecter avec Connect |
| `unreachable` | `no Cepheus server answers at ADDRESS: REASON` | Connect : rien n'écoute au socket ou au port de l'hôte, ou ce qui écoute ne répond pas au handshake (la poignée de main qui ouvre la connexion) en 5 s (REASON `no answer within 5 s`, ou `the TLS handshake: Resource temporarily unavailable`) | démarrer le serveur, vérifier l'adresse |
| `unreachable` | `the server did not answer for 30 s (REASON): a write in flight was applied once or not at all` | un appel après que la connexion a cassé et est restée cassée pendant tout le budget de nouvelles tentatives | démarrer le serveur ; relire avant d'écrire à nouveau |
| `protocol` | `an unexpected reply to Get` (Find, Write) | le serveur a répondu par une autre sorte de réponse : un bug | le signaler |

Une faute dans la forme d'un appel est un bug du programme, pas une valeur d'erreur : elle arrête la fiber, comme
`bug.Panic`, avec le message de Cesia, comme `cepheus.Get needs a database, as cepheus.Connect or Fork gives it, not the
number 3.` Celles du package : une base, un kind (`as cepheus.Kind made it`), une propriété (`as Client.City`), une map,
une liste, une opération (`as cepheus.Add, Retract or Expect makes it`), une question (`{Where: [patterns], Give:
{Name: variable}}`), un pattern (`[thing, property, value], or Above, Below or Between`), une variable ou l'identifiant
d'une chose en premier dans un pattern, une variable ou un agrégat dans Give ; et à `cepheus.Kind` : un nom qui n'est
pas fait de lettres minuscules, de chiffres, de `_` et de `-`, aucun champ, un champ nommé `kind`, un type qui n'est
aucun de `Text()`, `Int()`, `Float()`, `Bool()`, `Date()`, `Link()`, `Money(scale)`, une échelle hors de 0 à 18 ; à
`cepheus.Connect` : une adresse qui n'est pas `cepheus://host:port/database` (avec `?socket=DIR` pour seul
paramètre) ; à `cepheus.Find` : plus de 12 variables.

## Les lignes sur la sortie d'erreur

Un merge tourne en arrière-plan ; quand il échoue, il le dit sur la sortie d'erreur standard, supprime son fichier, et
la base continue avec ses anciens runs (aucune erreur n'atteint un client) ; le merge suivant attend que le delta ait
grandi d'un seuil de plus. Deux autres lignes viennent du writer.

| ligne | quand |
|---|---|
| `cepheus: the journal could not be cut back after a failed write: MSG` | après une écriture ou un fsync du journal qui a échoué, le retour à la dernière frame durable a échoué aussi : les écritures qui ont échoué peuvent revenir à la réouverture (G13) |
| `cepheus: the run of a large group could not be named: MSG` | le renommage du fichier de run d'un grand groupe a échoué après que sa frame était durable : la base s'arrête (`Io`), et l'ouverture suivante rejoue le groupe depuis le journal |
| `cepheus: background merge failed: EXN` | le domain du merge a rencontré une exception (une erreur de disque, une page illisible) |
| `cepheus: a merge could not be installed: MSG` | le renommage ou le fsync du répertoire a échoué |
| `cepheus: a merge could not catch up: MSG` | une page n'a pas pu être lue pendant le replay des groupes écrits pendant le merge |
| `cepheus: ready in T ms: ...` | le serveur a démarré : le temps de ses ouvertures, le groupe de chaque base, ses écoutes et ses domains |
| `cepheus: FILE reloaded: N tokens` / `cepheus: FILE not reloaded: MSG` | tokens.toml a changé ; un fichier qui ne se lit pas n'est pas pris, le serveur garde les tokens qu'il avait |
| `cepheus: database NAME: the sessions could not be saved: MSG` | le checkpoint des sessions a échoué (une erreur de disque) : l'ancien reste, et le démarrage suivant lit davantage du journal |
| `cepheus: stopping` / `cepheus: stopped` | SIGTERM ou SIGINT : l'arrêt du [serveur](server.md#démarrage-arrêt-crash) |
