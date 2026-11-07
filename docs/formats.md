# File formats

All integers little-endian. CRC is CRC-32C (Castagnoli), as an unsigned 32-bit number.

## `DIR/cepheus`

`"cepheus database\n"` (17 bytes) | id (16 bytes) | CRC of the 33 bytes before (4 bytes). Written once with a
temporary file, fsync, rename, fsync of the directory.

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
starts when the current one would pass 64 MB.

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
header, 4096 bytes:  0 magic "CPHS" (0x53485043) u32 | 4 format u32 (1) | 8 database id, 16 bytes
  | 24 last group | 32 next thing | 40 journal segment | 48 journal offset | 56 facts n | 64 things ne | 72 properties np
  | 80 links nr | 88 texts ns | 96 text bytes | 104 body length (all u64)
  | 112 CRC of the checksum table u32 | 116 CRC of bytes 0..116 u32 | zeros to 4096
body (body length bytes): the base, sections aligned to 8 bytes, in this order:
  eoff (ne+1) u64 | eap n u16 | eav n i64 | poff (np+1) u64 | avv n i64 | ave n u32 | pdist np u64
  | roff (ne+1) u64 | rp nr u16 | re nr u32 | soff (ns+1) u64 | sblob text bytes | ssort ns u32
checksum table, at 4096 + body length rounded up to 8: one CRC u32 for each MiB of the body
```

`eoff[e]..eoff[e+1]` are the rows of thing e in `eap`/`eav` (property, value word), sorted. `poff[p]..poff[p+1]` are
the rows of property p in `avv`/`ave` (value word, thing), sorted by value then thing; `pdist[p]` counts its distinct
values. `roff[t]..roff[t+1]` are the link facts pointing at t, in `rp`/`re` (property, thing). `soff[i]..soff[i+1]` are
the bytes of text i in `sblob`; `ssort` lists the text ids in byte order. A value word is the value itself for int,
date, money, link and bool (0/1), a text id for text, and the text id of its 8 IEEE bytes for a float.

The snapshot is the in-memory format: 64-bit little-endian machines only. The journal is the portable format.
