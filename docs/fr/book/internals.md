# Internals

`src/cepheus.mli` exporte les modules du moteur sous les noms `Cepheus.Value`, `Cepheus.Journal`, ... pour les tests,
les outils et les benchmarks. Ce ne sont pas l'API : ils peuvent changer d'une version à la suivante. Cette page liste
ce qu'offre chacun. Les modules qui ont un fichier d'interface (`.mli`) viennent d'abord, avec chacun de ses noms ; les
autres (`Engine`, `Store`, `Query`, `Resolve`, `Bulk`, `Snapshot`, `Pages`) exposent toute leur implémentation, et seuls
les noms qu'utilisent les tests et les outils sont listés.

```ocaml
open Cepheus

let () =
  (* a database on the simulated disk; a power loss; recovery keeps every confirmed group (G1) *)
  let sim = Sim_disk.create (Rng.make 42) in
  let disk = Sim_disk.disk sim in
  let db = Result.get_ok (open_on disk "db") in
  let[@warning "-8"] (Ok [ n ]) = declare db [ prop "counter/n" Tint ] in
  let r = Result.get_ok (write db [ Add (-1, n, Int 1) ]) in
  Sim_disk.crash sim;
  let db = Result.get_ok (open_on disk "db") in
  Printf.printf "after the power loss: group %d, value %s\n" (group (view db))
    (Value.to_string (List.hd (values (view db) (thing r (-1)) n)));
  close db;
  (* the check value of CRC-32C, and a histogram's percentiles, rounded up to their bucket *)
  Printf.printf "crc32c 123456789 = %08x\n" (Crc32c.string "123456789");
  let h = Histogram.create () in
  List.iter (Histogram.record h) [ 100; 200; 300; 1000; 5000 ];
  Printf.printf "p50 %d us, p99 %d us, max %d us, of %d\n" (Histogram.percentile h 0.5) (Histogram.percentile h 0.99)
    (Histogram.max h) (Histogram.total h)
```

```output
after the power loss: group 3, value 1
crc32c 123456789 = e3069283
p50 301 us, p99 5000 us, max 5000 us, of 5
```

## `Value` : valeurs et types (`src/value.mli`)

| nom | ce que c'est |
|---|---|
| `type t` | `Int`, `Float`, `Bool`, `Text`, `Date`, `Money`, `Link` : `Cepheus.value` |
| `type typ` | `Tint`, `Tfloat`, `Tbool`, `Ttext`, `Tdate`, `Tmoney of int`, `Tlink` : `Cepheus.typ` |
| `has_type : typ -> t -> bool` | la valeur est du type |
| `code : typ -> int` | le nombre qui range un type dans `cepheus/type` : int 0, float 1, bool 2, text 3, date 4, link 6, money à d chiffres 5 + 16 d |
| `of_code : int -> typ option` | l'inverse ; `None` pour un code inconnu (money au-delà de 18 chiffres) |
| `typ_name : typ -> string` | `int`, `float`, `bool`, `text`, `date`, `money(d)`, `link` |
| `to_string : t -> string` | `42`, un flottant en hexadécimal (`%h`), `true`, un texte entre guillemets (`%S`), `date 1700000000000`, `money 120000`, `#65536` |
| `equal`, `compare` | les flottants par leurs 64 bits (`nan` est égal à lui-même, `0.0` diffère de `-0.0`), le reste structurellement |
| `encode : Buffer.t -> t -> unit`, `decode : Codec.reader -> t` | une valeur seule : un octet de tag et le contenu (le protocole du serveur ; le journal code les valeurs d'un groupe en colonnes, [formats](formats.md#un-groupe)) ; `decode` lève `Codec.Short` |
| `inline : typ -> bool` | le mot d'index est la valeur elle-même (int, date, money, bool, link) ; les textes et les flottants sont des numéros du dictionnaire |

## `Schema` : la table des propriétés (`src/schema.mli`)

| nom | ce que c'est |
|---|---|
| `type prop` | `{ name; typ; many; unique }` : `Cepheus.prop` |
| `p_name`, `p_type`, `p_many`, `p_unique`, `p_rule` | 1, 2, 3, 4, 5 : les propriétés système |
| `first_prop`, `first_thing`, `last_thing` | 16, 65 536 et 2 147 483 647 ($2^{31} - 1$, le plus grand numéro de chose que tient un run) |
| `type t`, `initial` | une table persistante des propriétés et des règles (une copie à chaque changement) ; les cinq propriétés système |
| `find`, `by_name`, `count` | une propriété par son numéro, par son nom ; un de plus que le plus grand numéro que tient la table |
| `is_system p`, `is_prop_space e` | $1 \le p < 16$ ; $16 \le e < 65\,536$ |
| `set`, `facts`, `system` | une table changée ; les quatre faits qui déclarent une propriété ; les descriptions de 1 à 5 |
| `rules`, `rule`, `rule_by_name`, `set_rule`, `has_rules`, `rules_key` | les règles (chose -> nom et texte canonique) ; une clé qui change quand elles changent, qui sert de clé au cache de leur forme compilée |

## `Group` : l'événement (`src/group.mli`)

| nom | ce que c'est |
|---|---|
| `type kind` | `Retracted` 0, `Added` 1, `Derived` 2, `Underived` 3, `Now_asserted` 4, `Now_derived` 5 : ce que fait un changement à son fait, l'octet de sorte du journal ([règles](rules.md#les-faits-dérivés-sont-dans-le-journal)) |
| `type change` | `{ kind; e; p; v }` ; `after kind` l'état qu'il laisse (0 absent, 1 affirmé, 2 seulement dérivé), `present c` |
| `type t` | `{ n; time; by; why; first_new; count_new; changes }` : le numéro du groupe, l'horloge de la base en ms, qui, pourquoi, la première nouvelle chose et combien, les changements résolus |
| `encode`, `decode`, `equal` | le codage d'un groupe dans le journal, format 2 : ses textes une fois, ses changements en colonnes, dans leur ordre ([formats](formats.md#un-groupe)) ; `decode` lève `Codec.Short` sur des octets qui ne sont pas un groupe, et n'alloue jamais pour un compte que les octets ne peuvent pas tenir |
| `type source`, `encode_source` | ce que le codage lit des changements d'un groupe (les sortes, les choses, la colonne de chaque valeur et les propriétés et tags des colonnes, les nombres, les bits des flottants, les textes) : depuis le tableau de `t` (`encode`), depuis les tableaux d'un grand groupe (`Resolve.encode_large`), ou depuis les records d'un groupe et des changements lus par indice (`encode_parts`), si bien que tous écrivent les mêmes octets |
| `encode_parts b g ~n ~thing ~prop ~tag ~word ~text`, `tag_of_typ` | `encode` du groupe avec `n` changements de plus après ses records, chacun `Derived`, lus par indice et jamais faits records : les faits dérivés d'un changement des règles dans leur run à eux, lus dans les colonnes du run (`Engine`) ; les colonnes et les textes numérotés dans l'ordre de leur premier usage sur tous les changements, donc les octets sont ceux d'`encode` du groupe entier. `tag_of_typ` : le tag des valeurs d'un type dans le codage |
| `decode_v1` | le codage du format 1 (un changement après l'autre), lu seulement par `Journal.convert` |

## `Journal` : le write-ahead log (`src/journal.mli`)

| nom | ce que c'est |
|---|---|
| `exception Damaged of string` | des données durables perdues ou changées ; le message dit où ([erreurs](errors.md#damaged--des-données-durables-perdues-ou-changées)) |
| `type position` | `{ segment; offset; next }` : un segment (par son premier groupe), un offset dans celui-ci, le groupe de la frame qui s'y trouve |
| `max_body : int` | 256 MiB (268 435 456) : le plus grand corps de frame ; la recovery prend un champ de longueur plus grand pour un dommage |
| `segment_limit : int ref` | 64 MiB ; les tests le rendent petit |
| `window : int ref` | 4 MiB : les octets d'un segment qu'un parcours tient à la fois ; les tests le rendent petit (40 au moins) |
| `create disk dir id` | un nouveau journal, premier groupe 1 |
| `recover ?frame ?after ~force disk dir id from on_group` | lit depuis `from` (depuis le début sans lui) à travers la fenêtre, appelle `frame` sur la position de chaque frame et `on_group` sur chaque groupe, sauf pour les frames dont tous les groupes sont `after` ou avant (vérifiées par leurs CRC, pas décodées) ; avec `force`, avant de rejouer un groupe du segment le plus récent, écrit à nouveau la frame la plus récente de ce segment (son en-tête s'il ne tient aucune frame) et force le segment et le répertoire (G13) ; coupe de façon durable une fin torn, reconstruit les trailers des frames intactes, rend le journal prêt pour l'ajout |
| `append j body first count` | une frame de `count` groupes à partir de `first` : écrite, puis forcée ; en cas d'échec, ramène le journal à sa dernière frame durable (forcée ; une coupe qui échoue est signalée sur stderr) et lève `Disk.Io` ; chaque ajout suivant lève `Disk.Io` (G10, G13) |
| `type pending`, `begin_frame j len first count`, `body p buf off n`, `finish p`, `drop p` | une frame écrite par morceaux (celle d'un grand groupe) : sa place prise à la fin du journal (dans un nouveau segment, créé et forcé à ce moment, quand le segment courant dépasserait sa limite) ; les morceaux du corps écrits dans l'ordre, forcés tous les `force_every` octets (32 MiB) ; puis l'en-tête, le trailer et un fsync ; ou les morceaux retirés du fichier, forcé. Un échec de `body`, `finish` ou `drop` ramène le journal en arrière et le fait échouer, comme celui d'`append`. Rien d'autre ne peut être ajouté entre `begin_frame` et `finish` ou `drop` |
| `written_body p` | les octets du corps écrits jusque-là, relus (pour la simulation) |
| `next_group`, `position`, `close` | le numéro du groupe suivant ; l'endroit où va la frame suivante ; ferme |
| `verify disk dir id`, `read disk dir id f` | une lecture complète stricte : le nombre de groupes ; chaque groupe dans l'ordre |
| `convert disk dir id` | lit l'en-tête de chaque segment (40 octets) ; chaque segment au format 1 réécrit au format 2 (écrit à côté, forcé, renommé par-dessus, le répertoire forcé), ses frames telles qu'elles étaient ; une frame qui ne se vérifie pas est une fin torn dans le segment le plus récent (coupée) et un dommage ailleurs (`Damaged`) ; rend les segments convertis. `Engine.open_` l'appelle avant que quoi que ce soit lise le journal |
| `segment_name n` | `%020d.seg` |
| `write_us`, `fsync_us`, `clock` | des histogrammes du `pwrite` et du `fsync` de chaque frame, en µs ; l'heure en µs |

## `Disk` : le système de fichiers tel que le voit le moteur (`src/disk.mli`)

| nom | ce que c'est |
|---|---|
| `type fd`, `exception Io of string` | un fichier ouvert ; un appel qui a échoué (`CALL PATH: REASON`) |
| `type t` | 16 opérations : `exists`, `mkdir`, `readdir` (trié), `openf path create`, `size`, `pread`, `pwrite` (exactement les octets demandés), `truncate`, `fsync`, `close`, `rename` (atomique), `remove`, `sync_dir` (rend durables les noms d'un répertoire), `lock`, `unlock`, `now` (ms) ; et `parallel` : les appels peuvent venir de plusieurs domains à la fois, chacun sur ses propres fichiers (`true` pour le vrai disque ; `false` pour le disque simulé, pour que le moteur les fasse l'un après l'autre et qu'une seed les rejoue) |
| `real` | le système de fichiers de la machine (`lseek` puis `read` ou `write` ; des locks `lockf`, tenus dans une table dont la clé est le device et l'inode du fichier de lock, pour que tous les chemins vers un même fichier soient un seul lock) |
| `read_all`, `write_file` | un fichier entier ; un fichier écrit de façon durable et atomique (à côté, fsync, renommage, fsync du répertoire) |

## `Sim_disk` : le disque simulé (`src/sim_disk.mli`)

| nom | ce que c'est |
|---|---|
| `create ?reverts rng`, `disk t` | un disque simulé qui tire d'un générateur avec seed (`reverts` : un fsync qui échoue défait en mémoire les écritures qui ont échoué, comme le fait Btrfs ; par défaut il les garde, comme le font ext4 et XFS) ; le `Disk.t` qu'utilise le moteur |
| `sector` | 512 octets : l'unité de perte et de déchirure |
| `exception Crash`, `crash_after t n` | le $(n+1)$-ième appel qui modifie quelque chose à partir de maintenant lève `Crash` au lieu de s'exécuter : un crash à l'intérieur d'un appel |
| `type draw` | les choix d'une coupure de courant : `Names` (combien des changements de noms d'un répertoire survivent, un préfixe), `Length` (la longueur d'un fichier qui a grandi), `Cut`, `Sector` (perdu, gardé ou déchiré), `Tear` (combien d'octets d'un secteur déchiré) |
| `crash ?choose t` | une coupure de courant : fichiers fermés, locks libérés, chaque choix non synchronisé tiré au hasard ou par `choose`, si bien qu'un test peut énumérer chaque issue |
| `kill t` | le processus meurt, la machine reste allumée : ce qui a été écrit et pas forcé reste lisible, pour être perdu à un `crash` ultérieur |
| `pending_names`, `flip_durable`, `fail_next_fsync`, `advance` | les changements de noms pas synchronisés ; un bit inversé en silence dans des octets durables (F3) ; le fsync suivant échoue et les secteurs écrits depuis le dernier fsync sont marqués clean sans atteindre le disque : un fsync ultérieur ne les écrit pas sauf s'ils sont écrits à nouveau (F4) ; l'horloge avance |
| `fail_fsync_at ?crash_after t n`, `failures t` | le $(n+1)$-ième fsync à partir de maintenant échoue comme ci-dessus, et avec `crash_after c` le processus meurt au $(c+1)$-ième appel qui modifie quelque chose après lui ; les fsyncs qui ont échoué jusque-là |
| `durable_size`, `files`, `durable_bytes` | ce qui est durable, pour les vérifications |

## `Codec`, `Crc32c`, `Histogram`, `Rng`

| nom | ce que c'est |
|---|---|
| `Codec.put_varint`, `put_int`, `put_string`, `put_u64` | des varints LEB128 (un int $\ge 0$ en 1 à 9 octets), des ints en zigzag, des chaînes précédées de leur longueur, 8 octets little-endian |
| `Codec.reader`, `get_varint`, `get_int`, `get_byte`, `get_string`, `get_u64`, `at_end`, `exception Short` | un lecteur borné sur des octets ; chaque lecture au-delà de la fin lève `Short` |
| `Pack.width x`, `Pack.mask w`, `Pack.bytes n w`, `Pack.get b bit w`, `Pack.put b bit x w` | le bit packing : les bits de $x$ lus comme un nombre non signé de 63 bits (0 pour 0, 63 pour un négatif) ; des champs de $w \le 63$ bits l'un après l'autre, little-endian (le champ $i$ au bit $i \cdot w$), lus par un chargement non aligné de 8 octets, un décalage et un masque quand le champ y tient ($w \le 55$), octet par octet sinon et près de la fin des octets ; `put` écrit dans des bits à zéro |
| `Pack.put_ints out n f`, `Pack.get_ints r n a at` | une colonne de n ints en blocs de 128, chacun en frame of reference ou en deltas, selon ce qui est le plus court ([formats](formats.md#un-groupe)) : une seule passe par bloc trouve les deux étendues, les champs d'au plus 31 bits sont serrés par un mot courant écrit 4 octets à la fois ; `get_ints` lève `Codec.Short` sur des octets qui ne sont pas une colonne |
| `Crc32c.bytes b off len`, `Crc32c.extend crc b off len`, `Crc32c.string s` | CRC-32C (`extend` : le CRC des octets dont le CRC est `crc` suivis de ceux-ci, pour une frame vérifiée par morceaux), polynôme réfléchi 0x82F63B78, par l'instruction du processeur : le module vérifie les bornes (`Invalid_argument "Crc32c.extend"` sinon), puis appelle `src/crc32c_stubs.c` par morceaux d'au plus 1 MiB, pour qu'un autre domain qui demande une collection attende au plus environ 0,1 ms (un appel C ne s'arrête jamais pour le GC, le garbage collector) ; environ 9 GB/s ici. Son initialisation échoue avec `Failure` sur un processeur sans l'instruction |
| `Histogram.create`, `record`, `merge_into`, `percentile h q`, `total`, `max`, `mean` | des buckets log-linéaires comme HdrHistogram : exacts sous 256, puis 128 par puissance de deux ; un percentile est arrondi vers le haut à la plus haute valeur de son bucket, jamais au-dessus de la plus grande enregistrée |
| `Rng.make`, `copy`, `next`, `int r n`, `bool`, `chance r p`, `pick`, `split` | SplitMix64 (Steele, Lea, Flood 2014) : la même seed donne les mêmes nombres sur chaque machine ; pas pour la cryptographie |

## Les modules sans interface

| module | les noms qu'utilisent les tests et les outils |
|---|---|
| `Engine` | `open_`, `start` (`?follow` : les hooks que le syncer appelle avant l'écriture d'une frame et après sa publication, pour les lecteurs locaux du serveur), `stop`, `write`, `snapshot_live` ; `whole b` (les groupes d'un batch avec tous leurs changements : les faits dérivés d'un changement dans leur run à eux sont codés dans sa frame depuis les colonnes du run et gardés dans le `rest` du batch, faits records seulement ici, par le thread des watches) ; les étapes déterministes que mène la simulation : `prepare ?release` (`release i` : la requête i, un grand groupe, est traitée et ses opérations peuvent partir), `commit`, `merge_begin` (`~all` pour un merge complet), `install`, `compact`, `close` ; `plan`, `plan_all` et `plan_tier` (quels runs prend un merge, et son niveau ; `plan_tier` : le delta et les runs les plus récents jusqu'au dernier du premier niveau que deux runs partagent, pour un writer au repos), `tidy l` (le tic du serveur : un writer au repos fusionne de tels runs, en arrière-plan), `cap l` (la capacité du niveau l, `compact_min * ratio^l` saturée à `max_int`) ; `read_meta disk dir` (l'identifiant de la base) ; les réglages `compact_min` (200 000), `ratio` (4), `frame_limit` (le plus grand corps de frame que fait le writer : `Journal.max_body` ; les tests le rendent petit) ; les compteurs `merges`, `frames` ; les histogrammes `prepare_us`, `switch_us`, `merge_us`, `large_resolve_us`, `large_encode_us`, `large_merge_us` ; `on_merge` (un hook que le test de la banque utilise pour comparer l'ancienne et la nouvelle vue à chaque bascule) |
| `Store` | la vue (`runs`, les plus récents d'abord, chacun avec ses parties `a` et `t`, ses groupes `lo`, `hi` et son `level` ; `delta`, `dict`, `schema`, `group`, `next_e`) et ses lectures : `iter_facts`, `iter_values`, `iter_things`, `iter_prop`, `iter_range`, `mem`, les comptes ; `nth_bound v p w m` (le m-ième fait de p à partir de w dans l'index de chaque run et dans le delta, le plus proche de w : là où commence la recherche du chemin par index pour une fenêtre de m faits) ; les faits du delta d'une propriété par valeur dans `VM`, un arbre équilibré comme celui de `Map` dont chaque nœud garde les sommes des comptes nets et des ajouts de son sous-arbre (un order-statistic tree, un arbre qui sait compter ses éléments par intervalle), pour que `count_range` et `nth_bound` lisent le delta en $O(\log n)$ ; `iter_range_values` (les valeurs d'un intervalle, chacune une fois : sur un seul run sans changement de la propriété, côte à côte, sans table) ; `holders_from v p ?value ~desc ~from ()` (les choses qui tiennent p, ou le fait (p, w), dans l'ordre de leurs ids à partir d'une chose, chacune une fois : la rank table de la colonne de chaque partie, un mot de 32 choses à la fois, les lignes de (p, w) à partir d'une recherche binaire, celles du delta lues dans sa map par valeur (au plus 512 entrées de p) ou par chose (seulement jusqu'à la chose suivante des runs), fusionnés, chaque chose vérifiée quand la vue a plusieurs runs ou un changement de p : un tri par une chose, un range d'une chose) et `count_holders v p lo hi` (les faits de p des choses lo à hi : les rank tables et les offsets, $O(1)$ par partie) ; `value v typ w` et `text v i` (d'un mot vers une valeur) ; `facts v` (le nombre de faits) ; `run_rows r` (les lignes d'un run, que pèsent les niveaux) ; `of_runs` ; `add_texts v texts` (les nouveaux textes d'un grand groupe d'un coup : leurs numéros à partir du premier rendu, une seule nouvelle vue) ; les lecteurs d'une partie (`base_*`), sur les sections du format 8 : la recherche d'une propriété d'une chose lit sa colonne (`cthing` : un mot de rank ; `crows` : un en-tête d'offsets ; `cval` : une entrée de répertoire et un champ ; les entrées tenues dans `base.cols` par `ready`), ses slices pour le leapfrog (`slice_values`, `slice_things`, `read_values`, `read_things`), `value1` (l'unique valeur d'une propriété à une seule valeur), `iter_holders`, `iter_taken` (les choses d'une propriété, ses valeurs, chacune une fois) ; chaque fait d'une chose lit le mot du répertoire et la page du bloc (les octets de son en-tête ; le record dans la même page, ou champ par champ pour un bloc à cheval sur plusieurs pages), par propriété la page d'un row block ou un value index ; `hash s` (le hash des textes, [formats](formats.md#run-dirsnapshotslo-20-digits-hi-20-digitsrun)) ; `layout`, `rooms`, `offsets`, `of_offsets` (les sections d'une partie, telles qu'un merge les dispose et qu'un en-tête les liste) |
| `Query` | `plan`, `rows`, `count`, `fold` (la source d'un niveau choisie par des comptes exacts, sauf pour une propriété à une seule valeur d'une chose liée, qui offre au plus un candidat et est prise sans recherche avant tout pattern qui en offre un ou plus : un niveau où elle est toujours prise lit cette unique valeur) ; des vérifications laissées au niveau suivant quand sa variable est la leur ; une feuille (un champ à une valeur dans aucun autre pattern) placée après les filtres qui suivent sa chose (`order`), sa valeur lue une fois, au niveau de sa chose, par le test qui vérifie que la chose en a une (`kept`) ; des slices (un pattern dont l'autre côté est connu) intersectées par `leapfrog` (des sauts par galloping, `gallop`) quand la source en est une de 2 ou plus et que les autres font au plus 8 fois sa taille ; un niveau de `parallel_min` candidats ou plus (des comptes exacts) découpé sur jusqu'à `domains` domains où qu'il vienne dans l'ordre, et le premier niveau de deux candidats ou plus après les niveaux d'un seul, quand le planner attend `probe_more` (4) fois `parallel_min` candidats de travail ou plus, sondé : ses candidats tournent sur le domain qui pose la question jusqu'à ce que leur travail, mesuré (`probe_min` au moins), dise que le reste en prend autant (`fold ?any_order` : un merge qui ne dépend pas de l'ordre des bindings, un accumulateur par domain ; sinon un par slice, fusionnés dans l'ordre des slices) ; le budget est la somme des candidats de tous les domains ; les réglages `parallel_min` (20 000), `probe_more` (4), `probe_min` (1 024), `domains` ; les compteurs `work` (les candidats énumérés, tenus dans la borne de Generic Join par les tests), `splits` et `probed_splits` (les niveaux découpés, et ceux qu'une sonde a découpés) ; le `stop` d'une question (`Timeout`, `Cancelled`, `check` tous les `every` = 1 024 candidats, `now_ms`, l'horloge monotone) |
| `Pool` | les domains du processus : `cap` (le d d'OCAMLRUNPARAM, 128), `margin` (16), `live`, `spawn` (compté), `try_spawn` (aucun au-delà du budget) ; les helpers des questions (`help`, `limit` : les cœurs moins un, `keep` : 1 s, garés dans un poll sur un pipe), les compteurs `alive`, `spawned`. Pas de systhreads : le moteur du client Cesia le lie |
| `Writers` | les domains des writers (`run`, `writers` : les cœurs ; le thread writer et le thread syncer d'une base dans celui qui en a le moins), `background` (un domain, ou au-delà du budget un thread du domain qui le demande : les merges, les changements des règles), le compteur `writer_domains` |
| `Resolve` | `resolve` (la seule fonction qui vérifie et résout un groupe, pour le writer et pour les forks), `replay` (le groupe d'un journal sur une vue) ; `resolve_large` (le chemin rapide d'un grand groupe : `Some` le même résultat, ou `None` pour prendre le chemin ordinaire), `encode_large` (le groupe tel que le code `Group.encode`, dans un buffer : le domain de codage du writer le code, puis commence sa frame et l'écrit par morceaux de 1 MiB à côté du merge), `replay_large`, le réglage `large_min` (20 000) |
| `Bulk` | les faits d'un grand groupe dans des Bigarrays (chose int32, propriété uint16, valeur int ; par propriété valeur int et chose int32), dans l'ordre du groupe et par (propriété, valeur, chose), avec leur ordre par (chose, propriété, valeur) (`sorted`, ou la permutation `order`) ; `in_order`, `by_thing` (un radix sort stable des index), `make` (un counting sort par propriété en chunks, un radix sort stable par chiffres de 11 bits par valeur ; les textes du groupe ne sont plus triés : les dictionnaires des runs gardent une hash table) ; `parallel k f` (f 0 .. f (k-1) pris à tour de rôle par `domains` domains, 4 : un par cœur) ; les réglages `domains`, `chunk` (65 536 opérations ; les tests le rendent petit) |
| `Snapshot` | `merge ?busy ?bulk ?sync disk dir id view ~take ~level pos` (la seule façon d'écrire un run ; `~sync:false` : pas forcé à la fin, pour le run d'un grand groupe, que son commit force à côté de la frame), `force` (le fichier d'un run forcé, une fois), `install` (force un run pas encore forcé, puis le nomme), `abandon`, `clean`, `load` (la chaîne), `check_and_build` (un run qui tient dans le cache lu et vérifié par jusqu'à 4 domains), `name lo hi` ; le column order écrit dans la passe par chose (`columns`, `col_add`, `columns_end` : une seule rank table pour les propriétés tenues par les mêmes choses) ; le réglage `sync_every` (8 MiB) ; le compteur `open_max` (les pages ouvertes à la fois dans un merge) ; `schema_of` (le schéma d'une vue de runs, lu dans leurs faits de propriété : `load`, et les runs d'un lecteur local) ; `file_page disk path k`, `file_pages disk path` (la page du fichier qui tient la page k de la disposition d'un run, les pages que tient le fichier : pour les tests de dommages) |
| `Pages` | `size` (16 384), `capacity`, `set_capacity`, `drop` ; les compteurs `misses` (les pages lues sur le disque) et `hits` (les lectures d'une page en mémoire que la politique a comptées), `room_pages`, `resident_pages` (cepheus status) ; le mode trace `tracing`, `trace`, `traced` (l'étude du cache) |

## Les modules du serveur (`server/`, bibliothèque `cepheus_server`)

| module | ce que c'est |
|---|---|
| `Toml` | la partie de TOML 1.0 qu'utilisent `cluster.toml` et `tokens.toml` ; une erreur nomme sa ligne |
| `Config` | `cluster.toml` lu et vérifié (`load`), ses chemins (`socket_path`, `tokens_path`, `database_dir`) |
| `Tokens` | `tokens.toml` : les tokens (`generate`, `check`, `save`), les droits (`right`, `can_read`, `can_write`) |
| `Origin` | le token, la session, le numéro de série et le floor que porte un groupe dans son `why` (`wrap`, `parse`, `why`) |
| `Wire` | le protocole : les frames, les requêtes et les réponses, leurs codages, les codes d'erreur |
| `Sessions` | la table des sessions d'une base (`start`, `finish`, `replay`), son checkpoint (`save`, `load`) |
| `Core` | le serveur sans sockets : les frames d'une connexion en entrée (`input`), les réponses en sortie, les droits, les écritures à `submit` ; la réponse à une question (`answer`), la même au serveur et dans un lecteur local |
| `Answer` | la réponse à une question en mots de l'index (`answer`, `stream`), la même au serveur et dans un lecteur local ; les groupes d'un Group dans une `table` à adressage ouvert sur les mots de la clé (sondage linéaire, à moitié pleine au plus), leurs Count, Sum, Min et Max dans un tableau plat, une table par domain fusionnées à la fin (`merge_tables`), les groupes ensuite dans l'ordre de leurs clés (`sorted`) ; les tickets qui comptent les cellules d'une réponse (`max_cells`, `pool_cells`) |
| `Agg` | les agrégats du protocole 9 : les sommes exactes (`Exact` : des limbs de 30 bits), les sacs (`Bag`), la sélection (`select` : FIND de Hoare avec la borne de Musser), l'état d'un groupe pour un watch (`state`, Live), et les colonnes des tables d'Answer (`col` : les sommes exactes d'un entier en quatre entiers par groupe, l'état d'un groupe seulement quand elles déborderaient ou pour un float ; le sac de tous les groupes dans une table à adressage ouvert, ou une table par groupe dès qu'ils tiennent plus de `own_min` (64) valeurs différentes chacun en moyenne, les tables des domains lues ensemble à la fin, `by_group`) |
| `Window` | les fenêtres du protocole 10 (`Wire.Over`) : leurs vérifications (`check`), leurs types (`typ`), et `compute`, chaque fenêtre sur des lignes données dans l'ordre de `Sort` : les lignes de chaque groupe listées par un tri par comptage de leurs groupes, puis un passage par fenêtre et par groupe (un `Count` cumulé ; `Sum` et `Avg` à partir de sommes exactes, `Agg.add_value`, la ligne qui quitte un frame glissant retirée ; `Min` et `Max` gardés au fil des lignes, ou sur les n dernières lignes par une file monotone des candidats du frame ; `Rank` par les égalités des premières clés ; `Prev` par la place `back` lignes avant) ; le `start` d'une page (les lignes d'avant déjà comptées, leurs sommes, meilleures valeurs et places) à partir du seul fold d'Answer des lignes avant le curseur |
| `Live` | les questions vivantes, les mêmes au serveur et dans un lecteur local : un hub de templates (`create`, `frame`, `durable`, `rebase`, `reset`, `stop`), un watch (`subscribe ?extra ?order`, `unsubscribe`) ; avec `?order` (Sort et Limit), une fenêtre de ses lignes tenue par les lignes des frames et remplie à nouveau par un `Find` d'une page After sa dernière ligne |
| `Net` | le processus : les écoutes, les I/O domains, un thread par connexion, les limites de connexions, les follow streams (`follow_stream`), le démarrage, l'arrêt (`serve`) |
| `Follow` | le follow stream d'une base au serveur : la page de visibilité (`page_path`, `open_page`), les hooks du writer (`hooks` : `before` l'écriture d'une frame, `after` sa publication), les files des lecteurs (`register`, `take`), le rattrapage depuis le journal (`catch_up`), la vue des lectures distantes (`view`) |
| `Follower` | la copie d'une base que tient un lecteur local : ses runs à partir des fichiers passés (`create`, `runs`), les frames appliquées (`frame`), l'état visible sous le numéro de la page (`view`, `try_view`) |
| `Fdpass` | des descripteurs passés sur un socket Unix (`send`, `recv` : SCM_RIGHTS) et une page mappée en lecture seule et partagée (`map_page`, `word`) ; son C est `server/fdpass_stubs.c` |
| `Client` | un client en OCaml (tests, benchmarks, `cepheus status`) : `connect`, `open_db` (des lectures locales par le socket Unix : `?local`), `get`, `find`, `write` avec sa session, `declare`, `watch ?order` et `next_push`, `status` |
| `Timings` | les temps des questions et des écritures au serveur, une base chacune : `question`, `write` (un temps compté dans les tranches de 10 s du domain qui appelle, sans verrou ; vrai quand il dépasse `[log] slow_ms`), `lines` (cepheus status : comptes et sommes depuis le démarrage, p50, p99, maximum sur 60 s) ; le log des lentes (`say`, au plus 10 lignes par seconde ; la `shape` d'une question, `write_shape` et `write_text`, les constantes écrites `?`) |
| `Space` | ce que les données prennent sur le disque, pour cepheus status : `statvfs` (son C est `server/space_stubs.c`), les octets du journal et des runs d'une base, ses merges |
| `Prometheus` | cepheus status dans le format texte d'exposition 0.0.4 de Prometheus (`of_status`) : des familles en unités de base, les labels `database` et `peer`, des summaries pour les temps |
| `Tls` | TLS 1.3 par OpenSSL sur des buffers en mémoire (`server_ctx`, `client_ctx`, `handshake`, `read`, `write`, `make_cert`) ; son C, un cœur de C simple et ses enveloppes OCaml, est `server/tls_stubs.c` |
