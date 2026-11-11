# Formats de fichier

Chaque fichier d'une base, octet par octet, tel que l'écrivent `src/journal.ml`, `src/group.ml`, `src/value.ml`,
`src/codec.ml` et `src/snapshot.ml`.

Tous les entiers sont little-endian (l'octet de poids faible d'abord). CRC est CRC-32C (Castagnoli), sous forme d'un
nombre de 32 bits non signé : la somme de contrôle d'iSCSI de la RFC 3720 (section 12.1), polynôme 0x1EDC6F41
(0x11EDC6F41 avec son terme en $x^{32}$, comme l'écrit la RFC), calculée bit-reflected (bits pris dans l'ordre inverse :
0x82F63B78), en partant de 0xFFFFFFFF et complémentée à la fin ; le CRC des 9 octets `123456789` est 0xE3069283, et les
exemples de la RFC 3720 (annexe B.4) donnent les valeurs qu'elle affiche, lues comme des nombres little-endian
(`test/unit.ml` les vérifie). L'instruction propre du processeur le calcule (`src/crc32c_stubs.c`) ; le format ne
dépend pas de la façon de le calculer.

## `DIR/cepheus`

`"cepheus database\n"` (17 octets) | identifiant (16 octets) | CRC des 33 octets d'avant (4 octets). Écrit une seule
fois avec un fichier temporaire (`DIR/cepheus.tmp`), fsync (l'appel système qui attend que les octets écrits soient
vraiment sur le disque), renommage, fsync du répertoire.

## `DIR/lock`

Un fichier vide, créé à la première ouverture. Une ouverture prend sur lui un lock `lockf` exclusif (`F_TLOCK` : il
échoue aussitôt plutôt que d'attendre) et le garde jusqu'à `close`, ou jusqu'à ce que le processus meure et que le noyau
le libère.

## `DIR/closed`

Vide. Laissé par une fermeture propre (chaque frame et chaque nom durables, aucun fsync en échec) et supprimé par
l'ouverture suivante, qui saute alors les fsyncs dont a besoin une recovery après un crash (G5 ; la recovery : la
remise en état à l'ouverture, en relisant le journal). Sa création et sa suppression ne sont pas forcées sur le disque.

## Segment de journal `DIR/journal/<first group, 20 digits>.seg`

```
header, 40 bytes:  0 magic "CPHJ" (0x4A485043) u32 | 4 format u32 (2) | 8 database id, 16 bytes
                   | 24 first group u64 | 32 zero u32 | 36 CRC of bytes 0..36 u32
frames, one after the other:
  header, 28 bytes: 0 magic "CPHF" (0x46485043) u32 | 4 body length u32 | 8 first group u64 | 16 group count u32
                    | 20 body CRC u32 | 24 CRC of bytes 0..24 u32
  body: the groups, each encoded as below
  trailer, 16 bytes: 0 body length u32 | 4 body CRC u32 | 8 header CRC u32 | 12 magic "CPHT" (0x54485043) u32
```

Le corps d'une frame (un bloc du journal écrit d'un seul tenant) fait au plus 256 MiB (268 435 456 octets,
`Journal.max_body`) : le writer refuse un groupe dont le codage le dépasserait (`Invalid`), et la recovery prend un
champ de longueur plus grand pour un en-tête qui ne se vérifie pas. La recovery lit un segment à travers une fenêtre de
4 MiB (`Journal.window`) : une frame qui y tient est vérifiée et décodée là où elle se trouve, une plus longue est
vérifiée par son CRC morceau par morceau (`Crc32c.extend`) et lue en entier seulement quand ses groupes doivent être
rejoués.

Une frame est écrite en un seul `pwrite` et forcée, sauf celle d'un grand groupe, qui est seul dans sa frame et écrit par
morceaux à mesure de son codage, à côté de son merge : le corps d'abord (forcé tous les 32 MiB en route), puis
l'en-tête, puis le trailer (la fin de frame), puis le fsync. Les octets sur le disque sont les mêmes dans les deux cas ;
l'ordre compte pour un crash : avant l'en-tête, les morceaux ne forment pas une frame et la recovery les coupe comme
une fin torn (écrite en partie seulement) ; après lui, la frame se vérifie, et un trailer manquant est reconstruit à
partir de son en-tête. Un trailer n'est jamais écrit avant son en-tête (derrière un en-tête qui ne se vérifie pas, un
trailer qui se vérifie se lirait comme un dommage).

Un segment est créé avec son en-tête, forcé, et son répertoire forcé, avant qu'aucune frame y entre. Un nouveau segment
commence quand la frame suivante ferait passer le segment courant au-delà de 64 MiB (67 108 864 octets) ; il est créé
avant que l'ancien soit fermé, pour qu'un échec laisse le journal sur l'ancien segment.

## Un groupe

Les varints sont en LEB128 (des entiers de longueur variable : 7 bits par octet, les bits de poids faible d'abord) ;
« int » est un varint en zigzag (0, -1, 1, -2... → 0, 1, 2, 3...).

Un groupe est codé en **colonnes** (format de journal 2) : son en-tête, les textes qu'il utilise (chacun une fois),
puis ses changements comme des colonnes de nombres, une colonne pour les sortes, une pour les choses, une pour la
colonne de la valeur de chaque changement, puis chaque colonne de valeurs. Les changements gardent leur ordre : le
replay (la relecture du journal) les applique l'un après l'autre, et un groupe peut tenir deux changements d'un même
fait (un fait ajouté, puis retiré, dans la même écriture), ou les faits d'une propriété retirés avant la propriété
elle-même.

```
number varint | time int (ms) | by int | why string | first new thing varint | count of new things varint
| count of changes n varint
| if n > 0:
    texts:   count varint | each text: string        (the group's texts, each once, in order of first use)
    columns: count varint | each: property varint | tag byte
    kinds:   n ints (a column, below): the kind of each change
    things:  n ints: the thing of each change
    cols:    n ints: the column of each change's value, a place in the list above
    then each column's values, in the order of its changes:
      tag 1 (Float): 8 bytes each (the IEEE bits)
      any other tag: an int column of its values: Int, Date, Money, Link: the number; Bool (tag 2): 0 or 1;
                     Text (tag 4): the text's place in the group's texts
kind   = 0 an asserted fact retracted | 1 a fact asserted | 2 a fact derived by a rule | 3 a derived fact without a
         proof any more | 4 a derived fact now asserted too | 5 an asserted fact retracted that a rule still derives
tag    = Value.encode's byte: 0 Int | 1 Float | 2 Bool | 4 Text | 5 Date | 6 Money | 7 Link (one column a
         property and tag: a property's values are all of its type, so one column a property in practice)
string = length varint | bytes (UTF-8 by convention; Cepheus does not look inside)
```

**Une colonne d'entiers** de m nombres est codée en blocs de 128 (le dernier plus court). Chaque bloc est un octet (les
bits 0-6 la largeur w en bits, au plus 63 ; le bit 7 le mode), puis :

- mode 0, un **frame of reference** (une base et une largeur) : la plus petite valeur $b$ du bloc (un int), puis chaque
  valeur moins $b$ en $w$ bits ;
- mode 1, des **deltas** : la première valeur (un int), la plus petite différence $d$ entre une valeur et celle d'avant
  (un int), puis pour chaque valeur suivante sa différence avec celle d'avant moins $d$, en $w$ bits.

Le codeur prend le mode qui rend le bloc le plus court. Les champs de $w$ bits se suivent, little-endian : le champ $i$
tient les bits $i \cdot w$ .. $i \cdot w + w - 1$ du flux de bits du bloc, le bit $k$ du flux étant le bit $k \bmod 8$ de l'octet $\lfloor k / 8 \rfloor$ ;
le bloc finit à son dernier octet entier. Les différences sont prises modulo $2^{63}$, comme reviennent à zéro les
entiers de 63 bits du moteur, donc n'importe quelles valeurs reviennent exactement (un bloc qui tient à la fois le plus
petit et le plus grand int prend 63 bits par valeur).

La frame d'un grand groupe est codée par la même fonction à partir des tableaux du groupe ; ses octets sont donc ceux
qu'écrit `Group.encode` pour le même groupe. À 10 M de faits, le premier groupe du chargement (9,4 M de changements)
prend 21,6 MB au format 2, contre 94,1 MB au format 1 ([benchmarks](benchmarks.md)).

Le **format 1** codait les changements l'un après l'autre (`kind byte | thing varint | property varint | value`, la
valeur comme un octet de tag puis son varint ou sa chaîne). Un journal au format 1 est **converti une seule fois à
l'ouverture**, avant que quoi que ce soit le lise : chaque segment de ce format est réécrit au format 2, ses frames
telles qu'elles étaient (le même premier groupe et le même compte chacune, leurs corps codés à nouveau), écrit à côté
de l'ancien (`NAME.seg.tmp`), forcé, renommé par-dessus, et le répertoire forcé. Un crash pendant la conversion laisse
chaque segment entier dans un format ou dans l'autre ; l'ouverture suivante convertit le reste et supprime un
`.seg.tmp` resté là. Pour les trouver, l'ouverture lit l'en-tête de 40 octets de chaque segment, et rien de plus d'un
segment au format 2. Une frame au format 1 qui ne se vérifie pas est coupée si c'est la fin torn du segment le plus
récent (rien qui se vérifie n'est écrit après elle) et refusée comme dommage sinon, comme le décide la recovery. Les
runs d'une base au format 1 sont des formats 5 et 6, que l'ouverture met de côté (plus bas) : les offsets qu'ils
nomment dans les anciens segments ne servent donc jamais.

## Run `DIR/snapshots/<lo, 20 digits>-<hi, 20 digits>.run`

Un run tient les changements des groupes lo+1 .. hi par-dessus l'état au groupe lo (lo = 0 : un bottom run, tout
l'état à hi). L'état de la base sur disque est une chaîne de runs depuis 0, chacun reposant sur la fin de celui d'en
dessous, plus le journal après le plus récent. Le format 8 tient chaque fait trois fois : par chose, par propriété et
valeur, et par propriété et chose (le **column order** : les lignes de chaque propriété à part, dans l'ordre des
choses). Il code chaque section en **frame of reference** (Goldstein et al. 1998,
Zukowski et al. 2006) : un bloc de valeurs est rangé comme une base et, pour chaque valeur, sa différence avec la base
en autant de bits qu'en demande la plus grande différence du bloc (le bit packing des colonnes du journal, plus haut) ;
toute valeur se lit en $O(1)$ sans décoder ses voisines.

```
header, 4096 bytes:  0 magic "CPHS" (0x53485043) u32 | 4 format u32 (8) | 8 database id, 16 bytes
  | then u64 fields from 24: hi | lo | level | next thing | journal segment | journal offset | journal group at that
    offset | first text id s0
  | part a: rows n | thing range ne | things k | properties np | texts ns | text bytes | hash bits | its 23 section
    offsets (below, the last one the part's end)
  | part t: rows n | thing range ne | things k | properties np | its 23 section offsets
  | layout length | file pages P
  | 560 CRC of the page table u32 | 564 CRC of bytes 0..564 u32 | zeros to 4096
pages: P pages of 16 KiB at 4096 + 16384 f
page table, at 4096 + 16384 P: for each page k of the layout (ceil(layout length / 16384) of them), 8 bytes: the file
  page f that holds it (u32; 0xFFFFFFFF: none, the page reads as zeros) | the page's CRC-32C (u32)
```

**La disposition et le fichier.** Un merge (la fusion de runs triés en un seul) ne connaît ses comptes qu'une fois
fini ; il dispose donc un run selon des bornes supérieures de chaque section (tirées des lignes, des choses et des
textes de ses sources) : la disposition est un espace d'adresses où chaque section a sa place. Seules les pages de la
disposition qui tiennent des octets vont dans le fichier, serrées dans l'ordre où le merge les a finies ; la page table
dit où se trouve chacune. Un run prend donc sur le disque les octets qu'il tient (le bottom run de 10 M de faits :
54,4 MB dans le fichier pour une disposition de 1 118 MB), et aucun support des fichiers creux (sparse files) par le
système de fichiers n'est nécessaire. Une page de la disposition qu'aucune page du fichier ne tient se lit comme des
zéros ; aucune lecture d'un run n'en atteint jamais une, sauf au-delà du dernier champ d'une section.

**Les sections d'une partie**, dans cet ordre, chacune à un multiple de 8 octets :

```
erank   (ceil(ne/32) + 1) u64     the rank table of things
tdir    (thing blocks + 1) u64    the byte offset of each thing block from tdata; the last, the end of the last block
tdata                             the thing blocks
poff    (np + 1) u64              the first row (by property) of each property; the last, n
pblk    (np + 1) u64              the first row block of each property
pdist   np u64                    the distinct values of each property
pidx    np x 32 bytes             each property's value index: vlo i64 | first rank word u64 (-1: no index)
                                  | rank words u64 | first offset block u64
vdir    (row blocks + 1) x 16     each row block: its byte offset from vdata u64 | its first value i64
vdata                             the row blocks
vrank   u64 words                 the value indexes' rank tables
vmh     16 bytes a block          the value indexes' row offsets (a monotone sequence, below): block headers
vmb                               their bits
smh     16 bytes a block          the texts' byte offsets (a monotone sequence): headers
smb                               their bits
sblob   text bytes + 8            the texts, one after the other
shash   4 x 2^hash bits           the texts' hash table (u32: a text's index from s0, plus 1; 0: empty)
cp      np x 64 bytes             each property's column: tlo | rank | words | q0 | dir | data | mh | mb (u64 each)
crank   u64 words                 the columns' rank tables
cdir    16 bytes a block          the columns' block directories
cdata                             the columns' values
cmh     16 bytes a block          the columns' row offsets (a monotone sequence): headers
cmb                               their bits
```

La partie a tient les faits que le run ajoute, la partie t les faits des runs d'en dessous qu'il retire (vide dans un
bottom run) ; un run n'ajoute que des faits absents en dessous de lui et ne retire que des faits présents en dessous de
lui, donc chaque compte d'une vue est une somme des comptes des runs. La partie t n'a pas de textes (ns 0). Un run
tient les textes s0 .. s0+ns-1 : ceux enregistrés entre le run d'en dessous et lui. Un mot de valeur est la valeur
elle-même pour int, date, money, link et bool (0/1), un numéro de texte pour text, et le numéro de texte de ses 8
octets IEEE pour un float.

**Par chose.** `erank` est une rank table (Jacobson 1989) : le mot $j$ tient, dans ses 32 bits de poids faible, lesquelles
des choses $32j$ .. $32j + 31$ la partie tient, et dans ses 32 bits de poids fort combien de choses elle tient sous $32j$ ;
le dernier mot tient $k$. Le slot (la place) de la chose $e$ est son rank. Les slots sont groupés en **thing blocks** (blocs
de choses) de 128 (le slot $s$ est dans le bloc $\lfloor s / 128 \rfloor$). Dans un bloc, une propriété que chaque slot a au plus une fois est
un **champ** du record de chaque slot quand cela ne prend pas plus de bits qu'une colonne à elle (le client, la date,
le statut et le total d'une facture : une recherche lit un seul champ du record de la facture) ; toute autre propriété
est une **colonne** du bloc (les offsets de ses slots et ses valeurs : les follows d'un client, ou les propriétés des
quelques clients parmi un bloc de factures).

```
thing block (at tdata + tdir[s / 128]; a block that fits in a page never crosses one: the merge starts it on the next
page otherwise):
  0 B u16 (its slots) | 2 m u16 (its entries) | 4 hv u8 (1: a record's first bit says its slot has values in a
  column) | 5 zero bytes to 8 | 8 R u32 (the bits of a record) | 12 zero u32
  | 16: m entries of 16 bytes, by property: p u16 | wv u8 (bits a value, the flag included) | mode u8 (bit 7: each
        value's lowest bit is its derived flag; bit 6: a field of the records, bit 5: with a bit "present" before it;
        otherwise bits 0-5: bits of a residual, 0 when every slot has c values) | c u32 (a field: its bit in a record;
        a column: the least count) | base i64 (the least value)
  | m u32: each column's data, its byte from the block's start (0 for a field)
  | at 16 + 20 m, rounded up to 8: B records of R bits: [the "has values in a column" bit] then each field
  | each column's data: B + 1 residuals of wr bits (when wr > 0), then its values, by slot, sorted within a slot
```

Un champ est la différence de sa valeur avec la base de l'entrée, après un bit « présent » quand un slot n'a pas la
propriété. Le slot $k$ d'une colonne a les valeurs $c k + \mathit{res}_k$ .. $c (k+1) + \mathit{res}_{k+1} - 1$ de la colonne (pas de résidus quand chaque slot
a $c$ valeurs). Une valeur marquée comme dérivée (celle d'une règle, pas affirmée : [règles](rules.md)) garde son
drapeau dans le bit le plus bas de ses bits de valeur ; une entrée sans valeur dérivée n'y dépense aucun bit. Les
valeurs d'un slot pour une propriété sont contiguës et triées, donc un test d'appartenance est une recherche
dichotomique sur des champs de largeur fixe. Une chose qui a des milliers de valeurs fait un bloc plus grand qu'une
page : son en-tête (quelques centaines d'octets) est copié une fois par recherche et le reste lu dans les pages champ
par champ, donc une recherche reste en $O(\log n)$.

**Par propriété.** `poff[p]..poff[p+1]` sont les lignes de la propriété p (mot de valeur, chose), triées par valeur
puis par chose ; `pdist[p]` compte ses valeurs distinctes. Les lignes de chaque propriété sont coupées en **row
blocks** (blocs de lignes) de 128 (le premier de la propriété p est le bloc `pblk[p]`) ; un bloc ne traverse jamais une
page :

```
row block (at vdata + vdir[j].offset; its first value vdir[j].first):
  0 wv u8 (bits a value, the flag included) | 1 fl u8 (1: each value's lowest bit is its derived flag)
  | 2 wt u8 (bits a thing) | 3 gaps u8 | 4 the least thing u32
  | 8: the values, each its difference from the block's first value in wv bits (sorted, so the block's first is its
    least), rounded up to a byte | then the things, wt bits each:
      gaps 0: each its difference from the least thing;
      gaps 1: a row whose value is the row before's: its thing minus the thing before minus 1; the other rows: their
              thing minus the least (the writer takes this coding when it takes fewer bits: long runs of one value)
```

Une propriété a un **value index** quand sa rank table prend au plus 2 octets par ligne (ou 4 KiB) : liens, textes,
dates, petits entiers. `pidx[p]` donne vlo, la plus petite valeur que le merge pouvait rencontrer pour $p$, et ses mots de
rank dans `vrank` : le mot $j$ dit lesquelles des valeurs $\mathit{vlo} + 32j$ .. $\mathit{vlo} + 32j + 31$ $p$ prend (32 bits de poids faible) et
combien elle en prend sous elles (32 bits de poids fort) ; le dernier mot tient pdist. L'offset $q$ des offsets de $p$ (une
suite monotone qui commence au bloc d'offsets `pidx[p]` first) est la première ligne, depuis `poff[p]`, de la $q$-ième
valeur distincte de $p$, et l'offset pdist les lignes de $p$. Les lignes de $(p, w)$ se trouvent donc avec un mot de rank et
deux offsets, en $O(1)$, quel que soit le nombre de lignes ; sans index, par une recherche dichotomique des premières
valeurs des row blocks, puis une à l'intérieur d'un bloc.

**Par colonne (le column order).** Les lignes (chose, valeur) de chaque propriété à part de celles des autres, dans
l'ordre des choses, les valeurs d'une chose triées : le vertical partitioning (Abadi, Marcus, Madden, Hollenbach, VLDB
2007), une colonne de la propriété seule. Toute recherche d'une propriété d'une chose dans une partie (ses valeurs, leur
compte, un test d'appartenance) lit ici ; les thing blocks servent « tous les faits d'une chose » (un bloc, toutes ses
propriétés) et les merges. L'entrée `cp[p]` :

```
tlo    the thing of bit 0 of p's first rank word (a multiple of 32)
rank   the byte (in the run) of p's first rank word; -1: p has no rows in the part (the other fields unused)
words  its rank words: word j holds which of the things tlo + 32j .. tlo + 32j + 31 hold p (low 32 bits) and how
       many things of p come before them (high 32 bits); the last word holds the things of p (its bits 0)
q0     the first thing of p (by rank, from 0) that has several values; the things of p when none has
dir    the byte of p's block directory: block j (rows 128j .. 128j + 127): u64 (its byte from data) lsl 16 | mode
       lsl 8 | wv, then its base i64; mode bit 0: each value's lowest bit is its derived flag; bit 1: the values are
       coded from their thing (value - thing); wv the bits a value, its flag included
data   the byte of p's values, bit-packed block after block
mh mb  p's row offsets, a monotone sequence (below) of things - q0 + 1 entries, from 0 to rows - q0; unused when q0
       is the things of p
```

La $q$-ième chose de $p$ a la seule ligne $q$ tant que $q < q_0$ ; à partir de $q_0$, ses lignes sont
$q_0 + m(q - q_0)$ .. $q_0 + m(q - q_0 + 1) - 1$. Une propriété dont toutes les choses ont une seule valeur (le client, le total, le statut, la date d'une
facture) n'a donc aucun offset : sa ligne est le rank de sa chose. La ligne $r$ de $p$ est le champ $r \bmod 128$ du bloc $\lfloor r / 128 \rfloor$ :
sa valeur est la base du bloc plus le champ (plus la chose, dans un bloc codé à partir de la chose : le client d'une
facture est son propre numéro moins 1 à 20, 5 bits au lieu de 8). Les propriétés tenues par les mêmes choses partagent
une seule rank table (`rank` le même octet) : le run de 10 M de faits en a deux, celle des clients et celle des
factures. Le column order prend 13,9 MB de ce run (valeurs 11,4, rank tables 1,2, répertoires 1,25, offsets 0,01) :
une recherche du client d'une facture lit un mot de rank, une entrée de répertoire et un champ.

**Une suite monotone** (des offsets qui ne décroissent jamais) est rangée en blocs de 128 : un en-tête de 16 octets par
bloc (sa première valeur i64, puis un u64 qui tient la largeur $w$ dans son octet de poids faible et l'offset en octets des
bits du bloc au-dessus), et les bits du bloc à part ; l'entrée $q$ est l'en-tête du bloc $\lfloor q / 128 \rfloor$ plus le champ $q \bmod 128$ de $w$ bits.

**Le dictionnaire.** `soff` (une suite monotone de ns + 1 offsets) donne les octets du texte s0+i : `sblob[soff i ..
soff (i+1))`. `shash` est une hash table en open addressing (les entrées rangées dans la table elle-même) avec linear
probing (en cas de collision, on essaie le slot suivant ; Knuth, TAOCP vol. 3, 6.4) de $2^b$ slots
($b$ le plus petit avec $2^b \ge 2\, \mathit{ns}$ : au plus à moitié pleine) : le slot d'un texte est formé des $b$ bits de poids faible de son
hash, le suivant quand il est pris. Le hash d'un texte $s$ de $n$ octets, en arithmétique sur 63 bits (les ints d'OCaml :
modulo $2^{63}$), avec $K =$
0x2545F4914F6CDD1D (le multiplicateur de xorshift64*, Vigna 2016) :

```
h := n * K
for each group g of 7 bytes of s (little-endian; the last group padded with zeros): h := (h xor g) * K
h := h xor (h lsr 32); h := h * K; h := h xor (h lsr 29)
```

Un texte se trouve en sondant à partir de son slot jusqu'à ce que le slot soit vide (absent) ou tienne un texte égal :
environ 1,5 sonde pour un texte présent (Knuth 6.4, à moitié de charge). Rien ne lit les textes dans l'ordre des
octets : la liste triée de numéros du format 6 (`ssort`) a disparu.

**Écriture.** Un merge est la seule façon d'écrire un run (`Snapshot.merge`) : le delta, les runs les plus récents de
la vue, et les faits triés d'un grand groupe, fusionnés dans l'ordre de chaque section et déversés dans
`<lo>-<hi>.run.tmp`. Les colonnes sont écrites par la passe par chose (ses lignes arrivent dans l'ordre des choses
pour chaque propriété) ; la présence des choses de chaque propriété est gardée comme un bit par chose jusqu'à la fin de
la passe, puis écrite en rank tables, une pour les propriétés tenues par les mêmes choses ; une page de la
disposition part (son CRC calculé, écrite comme la page suivante du fichier, admise dans le cache, sauf pour le run
d'un grand groupe, lu plus tard depuis le fichier) dès que tous ses octets sont écrits. Puis la page table, l'en-tête,
un fsync (pendant que des clients écrivent, le fichier est aussi forcé tous les 8 MiB en route, pour qu'aucun fsync du
journal n'attende derrière des centaines de MB de dirty pages d'un merge, des pages modifiées en mémoire et pas encore
écrites), et, une fois le groupe du run durable dans le journal, le renommage à son nom et un fsync du
répertoire ; c'est seulement alors que les runs qu'il a remplacés sont supprimés, ainsi que tout autre run hors de la
chaîne (G12). Aucun run n'est gardé de côté comme solution de repli : le journal tient chaque groupe, donc un run
trouvé endommagé à une ouverture est mis de côté et ses groupes rejoués depuis le journal. Un fichier `.tmp` trouvé à
l'ouverture est un merge qu'un crash a interrompu : il est supprimé.

**Ouverture.** L'ouverture prend, parmi les chaînes que permettent les noms, celle qui atteint le groupe le plus récent
avec le moins de runs, et vérifie chaque run : son en-tête, sa page table (par son CRC, et le fait qu'elle associe
chaque page du fichier au plus une fois), l'ordre de ses sections, ses rank tables, le répertoire des thing blocks
(dans l'ordre, dans sa place), les offsets des propriétés, les row blocks (autant qu'en demandent les lignes de chaque
propriété, dans l'ordre), les value indexes (dans leur place), les offsets des textes, et chaque colonne (son entrée
dans ses sections, les comptes de sa rank table, ses offsets de 0 à ses lignes chacun plus grand que le précédent, ses
blocs dans l'ordre et dans leur place, ses lignes celles de la propriété par valeur) ; un run qui ne se vérifie pas est
mis de côté et le choix refait sans lui. Un run qui tient dans le cache est lu et vérifié en entier à l'ouverture, par
jusqu'à 4 domains (des fils d'exécution d'OCaml qui tournent en parallèle) quand il a 512 pages ou plus (chacun avec
son propre descripteur ; le CRC fait l'essentiel du temps d'une ouverture). Le replay commence à la
position du journal inscrite dans l'en-tête du run le plus récent, dont le groupe peut précéder celui du run lui-même :
un merge en arrière-plan part d'une vue en avance sur le disque, et sa position est la fin de la dernière frame
durable. Les groupes jusqu'à celui du run sont lus et sautés. Un journal qui finit avant le groupe du run le plus
récent est un dommage (le groupe du run était durable avant que son fichier reçoive son nom).

Une page est l'unité du cache : elle est lue du fichier en entier (16 384 octets à 4096 + 16384 f, f venant de la page
table), vérifiée contre son CRC, et servie seulement ensuite. Un champ de 2, 4 ou 8 octets dans une table est aligné sur
sa taille, donc aucun ne traverse une page ; un champ serré au bit près le peut, et il est alors lu dans les deux pages.

Le **format 7** (le format 8 sans le column order) est mis de côté à l'ouverture de la même façon : ses groupes rejoués
depuis le journal (une base de 10 M de faits : 5,2 s, une seule fois), le premier merge écrivant le format 8.

Les **formats 5 et 6** (chaque fait deux fois en mots fixes : par chose une propriété u16 et une valeur i64, par
propriété une valeur i64 et une chose u32, un offset dense u64 par slot de chose ; le format 6 avec le drapeau d'un fait
dérivé dans le bit 63 des mots de valeur ; 24,6 octets par fait à 10 M de faits) sont mis de côté à l'ouverture, comme
l'ont été les formats 1 à 4 : les runs sont des caches du journal, qui tient chaque groupe, donc leurs groupes sont
rejoués (une base de 10 M de faits se rejoue en à peu près le temps de son chargement) et le premier merge écrit le
format actuel.

Le run est le format en mémoire : machines 64 bits little-endian seulement. Le journal est le format portable. Le
format 4 (un seul snapshot `<group>.snap` qui tient toute la base, avec une table dense d'offsets par chose) et ceux
d'avant sont mis de côté à l'ouverture (ce sont des caches) : le journal est rejoué, et le premier merge les supprime.
Le format 1 gardait aussi les faits de lien par cible (`roff`, `rp`, `re`) ; le format 2 avait un CRC par MiB et était
mappé en entier ; le format 3 n'avait pas de groupe du journal dans son en-tête.

## Les fichiers du serveur

**L'origine d'un groupe** (dans son `why`, pour les groupes écrits par le serveur ;
[serveur](server.md#écritures-appliquées-une-seule-fois-les-sessions-g14)) :

```
why = "\000cph1\000" (6 bytes) | session varint | serial varint | floor varint | token name (varint length, bytes)
    | the program's why (the rest)
```

Un `why` qui ne commence pas par les 6 octets appartient au programme seul. Le serveur refuse un `why` de programme qui
commence par eux.

**`DATA/NAME/sessions`**, le checkpoint de la table des sessions (écrit à côté, forcé, renommé, le répertoire forcé) :

```
magic "cepheus sessions\n" (17 bytes) | format varint (1) | group varint (every receipt up to it is here)
| count varint | each session: id varint | token name (length, bytes) | floor varint | highest applied serial varint
                 | time of its last write (zigzag, ms) | count varint | each receipt: serial, group, first new thing (varints)
| CRC-32C u32 LE of everything before
```

Un checkpoint dont le CRC ne correspond pas est ignoré : le journal est alors lu depuis son début.

**`DATA/cepheus.lock`** : le pid du serveur en décimal et un saut de ligne, sous un lock `lockf` exclusif tant qu'il
tourne.
**`DATA/cepheus.server`** : l'identifiant du serveur (`cph-s-` et 16 chiffres hexadécimaux) et un saut de ligne.
