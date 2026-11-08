# File formats

Every file of a database, byte by byte, as `src/journal.ml`, `src/group.ml`, `src/value.ml`, `src/codec.ml` and
`src/snapshot.ml` write it.

All integers little-endian. CRC is CRC-32C (Castagnoli), as an unsigned 32-bit number.

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
header, 40 bytes:  0 magic "CPHJ" (0x4A485043) u32 | 4 format u32 (1) | 8 database id, 16 bytes
                   | 24 first group u64 | 32 zero u32 | 36 CRC of bytes 0..36 u32
frames, one after the other:
  header, 28 bytes: 0 magic "CPHF" (0x46485043) u32 | 4 body length u32 | 8 first group u64 | 16 group count u32
                    | 20 body CRC u32 | 24 CRC of bytes 0..24 u32
  body: the groups, each encoded as below
  trailer, 16 bytes: 0 body length u32 | 4 body CRC u32 | 8 header CRC u32 | 12 magic "CPHT" (0x54485043) u32
```

A segment is created with its header, forced, and its directory forced, before any frame goes in. A new segment
starts when the next frame would take the current one past 64 MiB (67,108,864 bytes); it is made before the old one
is closed, so that a failure leaves the journal on the old segment.

## A group

Varints are LEB128 (7 bits a byte, low first); "int" is a zigzag varint (0, -1, 1, -2... → 0, 1, 2, 3...).

```
number varint | time int (ms) | by int | why string | first new thing varint | count of new things varint
| count of changes varint | changes
change = kind byte (1 add, 0 retract) | thing varint | property varint | value
value  = tag byte, then:  0 Int: int | 1 Float: 8 bytes (IEEE bits) | 2 false | 3 true | 4 Text: string
                          | 5 Date: int | 6 Money: int | 7 Link: int
string = length varint | bytes (UTF-8 by convention; Cepheus does not look inside)
```

## Snapshot `DIR/snapshots/<last group, 20 digits>.snap`

```
header, 4096 bytes:  0 magic "CPHS" (0x53485043) u32 | 4 format u32 (4) | 8 database id, 16 bytes
  | 24 last group | 32 next thing | 40 journal segment | 48 journal offset | 56 journal group at that offset
  | 64 facts n | 72 things ne | 80 properties np | 88 texts ns | 96 text bytes | 104 body length (all u64)
  | 112 CRC of the checksum table u32 | 116 CRC of bytes 0..116 u32 | zeros to 4096
body (body length bytes, then zeros to a whole number of 16 KiB pages): the base, sections aligned to 8 bytes:
  eoff (ne+1) u64 | eap n u16 | eav n i64 | poff (np+1) u64 | avv n i64 | ave n u32 | pdist np u64
  | soff (ns+1) u64 | sblob text bytes | ssort ns u32
checksum table, at 4096 + 16384 x pages: one CRC-32C u32 for each 16 KiB page of the body
```

Every base but the empty one is a snapshot file, and a merge is the one way to write one (`Snapshot.merge`): the old
base, read through the cache, and the delta are merged in the order of each section and streamed into
`<group>.snap.tmp`; a page goes out (its CRC computed, written at its place, admitted to the cache) as soon as all its
bytes are written. Then the checksum table, the header, an fsync (while clients write, the file is also forced every
8 MiB on the way, so that no journal fsync waits behind hundreds of MB of a merge's dirty pages), and, once the snapshot's group is durable
in the journal, the rename to its name and an fsync of the directory; only then are the snapshots beyond the newest
two removed (G12). A `.tmp` file found at open is a merge a crash interrupted: it is removed.

Replay after a snapshot starts at the journal position of the header, whose group (at 56) may come before the
snapshot's own: a background merge starts from a view that runs ahead of the disk, and its position is the end of the
last durable frame. The groups up to the snapshot's are read and skipped. A journal that ends before the snapshot's
group is damage (the snapshot's group was durable before its file got its name).

A page is the unit of the cache: it is read from the file whole (16,384 bytes at 4096 + 16384 k), checked against its
CRC, and only then served. Every 2-, 4- or 8-byte field is aligned to its size, so none crosses a page.

`eoff[e]..eoff[e+1]` are the rows of thing e in `eap`/`eav` (property, value word), sorted. `poff[p]..poff[p+1]` are
the rows of property p in `avv`/`ave` (value word, thing), sorted by value then thing; `pdist[p]` counts its distinct
values (the things that link to t by p are the rows of value t). `soff[i]..soff[i+1]` are
the bytes of text i in `sblob`; `ssort` lists the text ids in byte order. A value word is the value itself for int,
date, money, link and bool (0/1), a text id for text, and the text id of its 8 IEEE bytes for a float.

The snapshot is the in-memory format: 64-bit little-endian machines only. The journal is the portable format. Format
1 also kept the link facts by target (`roff`, `rp`, `re`); format 2 had one CRC per MiB and was mapped whole; format 3
had no journal group in its header (its replay started after its own group). A snapshot of an older format is set
aside at open (it is a cache) and the journal is replayed.
