# File formats

Every file of a database, byte by byte, as `src/journal.ml`, `src/group.ml`, `src/value.ml`, `src/codec.ml` and
`src/snapshot.ml` write it.

All integers little-endian. CRC is CRC-32C (Castagnoli), as an unsigned 32-bit number: the iSCSI checksum of RFC 3720
(section 12.1), polynomial 0x1EDC6F41 (0x11EDC6F41 with its x³² term, as the RFC writes it), computed bit-reflected
(0x82F63B78), starting from 0xFFFFFFFF and complemented at the end; the CRC of the 9 bytes `123456789` is 0xE3069283,
and RFC 3720's examples (appendix B.4) give the values it prints, read as little-endian numbers (`test/unit.ml` checks
them). The processor's own instruction computes it (`src/crc32c_stubs.c`); the format does not depend on how.

## `DIR/cepheus`

`"cepheus database\n"` (17 bytes) | id (16 bytes) | CRC of the 33 bytes before (4 bytes). Written once with a
temporary file (`DIR/cepheus.tmp`), fsync, rename, fsync of the directory.

## `DIR/lock`

An empty file, created at the first open. An open takes an exclusive `lockf` lock on it (`F_TLOCK`: it fails at once
rather than wait) and keeps it until `close`, or until the process dies and the kernel releases it.

## `DIR/closed`

Empty. Left by a clean close (every frame and name durable, no fsync failed) and removed by the next open, which then
skips the fsyncs a recovery after a crash needs (G5). Its creation and removal are not forced.

## Journal segment `DIR/journal/<first group, 20 digits>.seg`

```
header, 40 bytes:  0 magic "CPHJ" (0x4A485043) u32 | 4 format u32 (2) | 8 database id, 16 bytes
                   | 24 first group u64 | 32 zero u32 | 36 CRC of bytes 0..36 u32
frames, one after the other:
  header, 28 bytes: 0 magic "CPHF" (0x46485043) u32 | 4 body length u32 | 8 first group u64 | 16 group count u32
                    | 20 body CRC u32 | 24 CRC of bytes 0..24 u32
  body: the groups, each encoded as below
  trailer, 16 bytes: 0 body length u32 | 4 body CRC u32 | 8 header CRC u32 | 12 magic "CPHT" (0x54485043) u32
```

A frame's body is at most 256 MiB (268,435,456 bytes, `Journal.max_body`): the writer refuses a group whose encoding
would pass it (`Invalid`), and recovery takes a longer length field for a header that does not check. Recovery reads a
segment through a window of 4 MiB (`Journal.window`): a frame that fits is checked and decoded where it lies, a longer
one is checked by its CRC piece by piece (`Crc32c.extend`) and read whole only when its groups must be replayed.

A frame is written in one `pwrite` and forced, except a large group's, which is alone in its frame and written by
pieces as it is encoded, beside its merge: the body first (forced every 32 MiB on the way), then the header, then the
trailer, then the fsync. The bytes on the disk are the same either way; the order matters for a crash: before the
header, the pieces do not make a frame and recovery cuts them as a torn tail; after it, the frame checks, and a missing
trailer is rebuilt from its header. A trailer is never written before its header (behind a header that does not
check, a trailer that checks would read as damage).

A segment is created with its header, forced, and its directory forced, before any frame goes in. A new segment
starts when the next frame would take the current one past 64 MiB (67,108,864 bytes); it is made before the old one
is closed, so that a failure leaves the journal on the old segment.

## A group

Varints are LEB128 (7 bits a byte, low first); "int" is a zigzag varint (0, -1, 1, -2... → 0, 1, 2, 3...).

A group is coded in **columns** (journal format 2): its header, the texts it uses (each once), then its changes as
columns of numbers, one column for the kinds, one for the things, one for the column of each change's value, then
each value column. The changes keep their order: replay applies them one after the other, and a group may hold two
changes of one fact (a fact added, then retracted, in the same write), or a property's facts retracted before the
property itself.

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

**An int column** of m numbers is coded in blocks of 128 (the last one shorter). Each block is a byte (bits 0-6 the
bit width w, at most 63; bit 7 the mode), then:

- mode 0, a **frame of reference**: the block's least value b (an int), then each value minus b in w bits;
- mode 1, **deltas**: the first value (an int), the least difference d between a value and the one before it (an
  int), then for each later value its difference from the one before minus d, in w bits.

The coder takes the mode that makes the block shorter. Fields of w bits follow one another, little-endian: field i
holds bits i·w .. i·w + w − 1 of the block's bit stream, bit k of the stream being bit k mod 8 of byte k / 8; the
block ends at its last whole byte. Differences are taken modulo 2^63, as the engine's 63-bit integers wrap, so any
values come back exactly (a block that holds both the least and the greatest int takes 63 bits a value).

A large group's frame is coded by the same function from the group's arrays, so its bytes are those `Group.encode`
writes for the same group. At 10 M facts the load's first group (9.4 M changes) takes 21.6 MB in format 2, against
94.1 MB in format 1 ([benchmarks](benchmarks.md)).

**Format 1** coded the changes one after the other (`kind byte | thing varint | property varint | value`, the value
as a tag byte then its varint or string). A journal of format 1 is **converted once at open**, before anything reads
it: each such segment is rewritten in format 2, its frames as they were (the same first group and count each, their
bodies coded again), written beside the old one (`NAME.seg.tmp`), forced, renamed over it, and the directory forced.
A crash during the conversion leaves each segment whole in one format or the other; the next open converts the rest
and removes a leftover `.seg.tmp`. To find them, the open reads the 40-byte header of each segment, and nothing more
of a segment of format 2. A frame of format 1 that does not check is cut if it is the newest segment's torn
tail (nothing that checks is written after it) and refused as damage otherwise, as recovery decides. The runs of a
database of format 1 are of formats 5 and 6, which open sets aside (below), so the offsets they name in the old
segments are never used.

## Run `DIR/snapshots/<lo, 20 digits>-<hi, 20 digits>.run`

A run holds the changes of groups lo+1 .. hi on top of the state at group lo (lo = 0: a bottom run, the whole state
at hi). The database's state on disk is a chain of runs from 0, each resting on the end of the one below it, plus the
journal after the newest one. Format 8 holds each fact three times: by thing, by property and value, and by property
and thing (the **column order**: each property's rows apart, in thing order). It codes every section with a **frame
of reference** (Goldstein et al. 1998,
Zukowski et al. 2006): a block of values is stored as a base and, for each value, its difference from the base in as
many bits as the block's largest difference needs (the bit packing of the journal's columns, above); any value is
read in O(1) without decoding its neighbours.

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

**The layout and the file.** A merge knows its counts only once it is done, so it lays a run out by upper bounds of
each section (from the rows, things and texts of its sources): the layout is an address space where each section has
its room. Only the pages of the layout that hold bytes go to the file, packed in the order the merge finished them;
the page table says where each is. So a run takes on the disk the bytes it holds (the 10 M-fact bottom run: 54.4 MB
in the file for a layout of 1,118 MB), and no file system support for sparse files is needed. A page of the layout that
no file page holds reads as zeros; no read of a run ever reaches one but past a section's last field.

**The sections of a part**, in this order, each at a multiple of 8 bytes:

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

Part a holds the facts the run adds, part t the facts of the runs below it that it retracts (empty in a bottom run);
a run adds only facts absent below it and retracts only facts present below it, so every count of a view is a sum of
the runs' counts. Part t has no texts (ns 0). A run holds the texts s0 .. s0+ns-1: those interned between the run
below it and itself. A value word is the value itself for int, date, money, link and bool (0/1), a text id for text,
and the text id of its 8 IEEE bytes for a float.

**By thing.** `erank` is a rank table (Jacobson 1989): word j holds, in its low 32 bits, which of the things 32j ..
32j+31 the part holds, and in its high 32 bits how many things it holds below 32j; the last word holds k. The slot of
thing e is its rank. The slots are grouped in **thing blocks** of 128 (slot s is in block s / 128). In a block, a
property that every slot has at most once is a **field** of each slot's record when that takes no more bits than a
column of its own (an invoice's client, date, status and total: a lookup reads one field of the invoice's record);
any other property is a **column** of the block (its slots' offsets and its values: a client's follows, or the
properties of the few clients among a block of invoices).

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

A field is its value's difference from the entry's base, after a bit "present" when some slot lacks the property.
A column's slot k has the values c k + res k .. c (k+1) + res (k+1) − 1 of the column (no residuals when every slot
has c values). A value flagged as derived (a rule's, not asserted: [rules](rules.md)) keeps its flag in the lowest
bit of its value bits; an entry with no derived value spends no bit on it. Values of a slot for one property are
contiguous and sorted, so a membership test is a binary search on fields of fixed width. A thing with thousands of
values makes a block larger than a page: its header (a few hundred bytes) is copied once a lookup and the rest read
from the pages field by field, so a lookup stays O(log n).

**By property.** `poff[p]..poff[p+1]` are the rows of property p (value word, thing), sorted by value then thing;
`pdist[p]` counts its distinct values. Each property's rows are cut in **row blocks** of 128 (property p's first is
block `pblk[p]`); a block never crosses a page:

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

A property has a **value index** when its rank table takes at most 2 bytes a row (or 4 KiB): links, texts, dates,
small ints. `pidx[p]` gives vlo, the least value the merge could meet for p, and its rank words in `vrank`: word j
tells which of the values vlo + 32j .. vlo + 32j + 31 p takes (low 32 bits) and how many it takes below them (high
32 bits); the last word holds pdist. Offset q of p's offsets (a monotone sequence starting at block `pidx[p]` first
offset block) is the first row, from `poff[p]`, of p's q-th distinct value, and offset pdist the rows of p. So the
rows of (p, w) are found with one rank word and two offsets, O(1), whatever the rows; without an index, by a binary
search of the row blocks' first values, then one inside a block.

**By column (the column order).** Each property's rows (thing, value) apart from the others', in thing order, the
values of one thing sorted: vertical partitioning (Abadi, Marcus, Madden, Hollenbach, VLDB 2007), a column of the
property alone. Every lookup of a thing's property in a part (its values, their count, a membership test) reads here;
the thing blocks serve "every fact of a thing" (one block, all its properties) and the merges. Entry `cp[p]`:

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

The q-th thing of p has the row q alone while q < q0; from q0 on, its rows are q0 + m(q - q0) .. q0 + m(q - q0 + 1)
- 1. So a property whose things all have one value (an invoice's client, total, status, date) has no offsets at all:
its row is its thing's rank. Row r of p is field r mod 128 of block r / 128: its value is the block's base plus the
field (plus the thing, in a block coded from the thing: an invoice's client is its own id minus 1 to 20, 5 bits
instead of 8). Properties held by the same things share one rank table (`rank` the same byte): the 10 M-fact run has
two, the clients' and the invoices'. The column order takes 13.9 MB of that run (values 11.4, rank tables 1.2,
directories 1.25, offsets 0.01): a lookup of an invoice's client reads one rank word, one directory entry and one
field.

**A monotone sequence** (offsets that never decrease) is stored in blocks of 128: a header of 16 bytes a block (its
first value i64, then a u64 holding the width w in its low byte and the byte offset of the block's bits above it),
and the block's bits apart; entry q is the header of block q / 128 plus field q mod 128 of w bits.

**The dictionary.** `soff` (a monotone sequence of ns + 1 offsets) gives the bytes of text s0+i: `sblob[soff i ..
soff (i+1))`. `shash` is an open-addressing hash table with linear probing (Knuth, TAOCP vol. 3, 6.4) of 2^b slots
(b the least with 2^b >= 2 ns: at most half full): a text's slot is the low b bits of its hash, the next one when it
is taken. The hash of a text s of n bytes, in 63-bit arithmetic (OCaml's ints: modulo 2^63), with K =
0x2545F4914F6CDD1D (the multiplier of xorshift64*, Vigna 2016):

```
h := n * K
for each group g of 7 bytes of s (little-endian; the last group padded with zeros): h := (h xor g) * K
h := h xor (h lsr 32); h := h * K; h := h xor (h lsr 29)
```

A text is found by probing from its slot until the slot is empty (not there) or holds a text equal to it: about 1.5
probes for a text that is there (Knuth 6.4, at half load). Nothing reads the texts in byte order: format 6's sorted
list of ids (`ssort`) is gone.

**Writing.** A merge is the one way to write a run (`Snapshot.merge`): the delta, the newest runs of the view, and a
large group's sorted facts, merged in the order of each section and streamed into `<lo>-<hi>.run.tmp`. The columns
are written by the pass by thing (its rows arrive in thing order for each property); the presence of each property's
things is kept as one bit a thing until the pass ends, then written as rank tables, one for the properties held by the
same things; a page of the
layout goes out (its CRC computed, written as the next file page, admitted to the cache, but for a large group's run,
read later from the file) as soon as all its bytes are written. Then the page table, the header, an fsync (while
clients write, the file is also forced every 8 MiB on the way, so that no journal fsync waits behind hundreds of MB
of a merge's dirty pages), and, once the run's group is durable in the journal, the rename to its name and an fsync of
the directory; only then are the runs it replaced removed, and every other run outside the chain (G12). No run is
kept aside as a fallback: the journal holds every group, so a run found damaged at an open is set aside and its groups
replayed from the journal. A `.tmp` file found at open is a merge a crash interrupted: it is removed.

**Opening.** Open takes, among the chains the names allow, the one that reaches the newest group with the fewest
runs, and checks each run: its header, its page table (by its CRC, and that it maps each file page at most once),
the order of its sections, its rank tables, the thing blocks' directory (in order, within its room), the property
offsets, the row blocks (as many as each property's rows need, in order), the value indexes (within their room), the
text offsets, and each column (its entry within its sections, its rank table's counts, its offsets from 0 to its rows
each larger than the one before, its blocks in order and within their room, its rows those of the property by value);
a run that does not check is set aside and the choice made again without it. A run that fits in the cache is read and
checked whole at open, by up to 4 domains when it has 512 pages or more (each its own descriptor; the CRC is most of
an open's time). Replay starts at the
journal position of the newest run's header, whose group may come before the run's own: a background merge starts
from a view that runs ahead of the disk, and its position is the end of the last durable frame. The groups up to the
run's are read and skipped. A journal that ends before the newest run's group is damage (the run's group was durable
before its file got its name).

A page is the unit of the cache: it is read from the file whole (16,384 bytes at 4096 + 16384 f, f from the page
table), checked against its CRC, and only then served. A field of 2, 4 or 8 bytes in a table is aligned to its size,
so none crosses a page; a bit-packed field may, and is then read from both pages.

**Format 7** (format 8 without the column order) is set aside at open in the same way: its groups replayed from
the journal (a 10 M-fact database: 5.2 s, once), the first merge writing format 8.

**Formats 5 and 6** (every fact twice in fixed words: by thing a u16 property and an i64 value, by property an i64
value and a u32 thing, a dense u64 offset a thing slot; format 6 the flag of a derived fact in bit 63 of the value
words; 24.6 bytes a fact at 10 M facts) are set aside at open, as formats 1 to 4 were: the runs are caches of the
journal, which holds every group, so their groups are replayed (a 10 M-fact database replays in about the time of its
load) and the first merge writes the current format.

The run is the in-memory format: 64-bit little-endian machines only. The journal is the portable format. Format 4 (one
snapshot `<group>.snap` holding the whole base, with a dense table of offsets by thing) and the earlier ones are set
aside at open (they are caches): the journal is replayed, and the first merge removes them. Format 1 also kept the link
facts by target (`roff`, `rp`, `re`); format 2 had one CRC per MiB and was mapped whole; format 3 had no journal group
in its header.

## The server's files

**A group's origin** (in its `why`, for groups written through the server; [server](server.md#writes-applied-once-sessions-g14)):

```
why = "\000cph1\000" (6 bytes) | session varint | serial varint | floor varint | token name (varint length, bytes)
    | the program's why (the rest)
```

A `why` that does not start with the 6 bytes is the program's alone. The server refuses a program's `why` that starts
with them.

**`DATA/NAME/sessions`**, the session table's checkpoint (written beside, forced, renamed, the directory forced):

```
magic "cepheus sessions\n" (17 bytes) | format varint (1) | group varint (every receipt up to it is here)
| count varint | each session: id varint | token name (length, bytes) | floor varint | highest applied serial varint
                 | time of its last write (zigzag, ms) | count varint | each receipt: serial, group, first new thing (varints)
| CRC-32C u32 LE of everything before
```

A checkpoint whose CRC does not match is ignored: the journal is read from its start instead.

**`DATA/cepheus.lock`**: the server's pid in decimal and a newline, under an exclusive `lockf` lock while it runs.
**`DATA/cepheus.server`**: the server's id (`cph-s-` and 16 hex digits) and a newline.

