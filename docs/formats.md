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

A frame's body is at most 256 MiB (268,435,456 bytes, `Journal.max_body`): the writer refuses a group whose encoding
would pass it (`Invalid`), and recovery takes a longer length field for a header that does not check. Recovery reads a
segment through a window of 4 MiB (`Journal.window`): a frame that fits is checked and decoded where it lies, a longer
one is checked by its CRC piece by piece (`Crc32c.extend`) and read whole only when its groups must be replayed.

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

## Run `DIR/snapshots/<lo, 20 digits>-<hi, 20 digits>.run`

A run holds the changes of groups lo+1 .. hi on top of the state at group lo (lo = 0: a bottom run, the whole state
at hi). The database's state on disk is a chain of runs from 0, each resting on the end of the one below it, plus the
journal after the newest one.

```
header, 4096 bytes:  0 magic "CPHS" (0x53485043) u32 | 4 format u32 (5) | 8 database id, 16 bytes
  | then u64 fields from 24: hi | lo | level | next thing | journal segment | journal offset | journal group at that
    offset | first text id s0 | part a: rows n, thing range ne, things k, properties np, texts ns, text bytes, room
    for rows, room for things | part t: rows n, thing range ne, things k, properties np, room for rows, room for
    things | body length
  | 208 CRC of the checksum table u32 | 212 CRC of bytes 0..212 u32 | zeros to 4096
body (body length bytes, then zeros to a whole number of 16 KiB pages): part a, then part t, each with its sections
aligned to 8 bytes:
  erank (ceil(ne/32) + 1) u64 | eoff (room for things + 1) u64 | eap room u16 | eav room i64 | poff (np+1) u64
  | avv room i64 | ave room u32 | pdist np u64 | soff (ns+1) u64 | sblob text bytes | ssort ns u32
checksum table, at 4096 + 16384 x pages: one CRC-32C u32 for each 16 KiB page of the body
```

Part a holds the facts the run adds, part t the facts of the runs below it that it retracts (empty in a bottom run);
a run adds only facts absent below it and retracts only facts present below it, so every count of a view is a sum of
the runs' counts. Part t has no texts (ns 0). A run holds the texts s0 .. s0+ns-1: those interned between the run
below it and itself.

`erank` is a rank table (Jacobson 1989): word j holds, in its low 32 bits, which of the things 32j .. 32j+31 the part
holds, and in its high 32 bits how many things it holds below 32j; the last word holds k. The slot of thing e is its
rank, and `eoff[slot]..eoff[slot+1]` are its rows in `eap`/`eav` (property, value word), sorted. A part answers "does
it hold thing e" with one bit, and costs a quarter of a byte a thing id, however few things it holds (a dense table
of offsets cost 8 bytes a thing id, the 65,536 ids below the first thing included). `poff[p]..poff[p+1]` are the rows
of property p in `avv`/`ave` (value word, thing), sorted by value then thing; `pdist[p]` counts its distinct values.
`soff[i]..soff[i+1]` are the bytes of text s0+i in `sblob`; `ssort` lists the texts in byte order (as ids from s0). A
value word is the value itself for int, date, money, link and bool (0/1), a text id for text, and the text id of its
8 IEEE bytes for a float.

A merge knows its counts only once it is done, so it lays its sections out by upper bounds (the rows and things of its
sources): the bytes between a section's end and its room are zeros, and the pages that hold only such bytes are never
written (holes, which read as zeros and whose CRC is that of a page of zeros).

A merge is the one way to write a run (`Snapshot.merge`): the delta, the newest runs of the view, and a large group's
sorted facts, merged in the order of each section and streamed into `<lo>-<hi>.run.tmp`; a page goes out (its CRC
computed, written at its place, admitted to the cache) as soon as all its bytes are written. Then the checksum table,
the header, an fsync (while clients write, the file is also forced every 8 MiB on the way, so that no journal fsync
waits behind hundreds of MB of a merge's dirty pages), and, once the run's group is durable in the journal, the rename
to its name and an fsync of the directory; only then are the runs it replaced removed, but the newest bottom run that
is not in the chain, kept as a fallback (G12). A `.tmp` file found at open is a merge a crash interrupted: it is
removed.

Open takes, among the chains the names allow, the one that reaches the newest group with the fewest runs, and checks
each run (header, checksum table, rank and offset tables); a run that does not check is set aside and the choice made
again without it. Replay starts at the journal position of the newest run's header, whose group may come before the
run's own: a background merge starts from a view that runs ahead of the disk, and its position is the end of the last
durable frame. The groups up to the run's are read and skipped. A journal that ends before the newest run's group is
damage (the run's group was durable before its file got its name).

A page is the unit of the cache: it is read from the file whole (16,384 bytes at 4096 + 16384 k), checked against its
CRC, and only then served. Every 2-, 4- or 8-byte field is aligned to its size, so none crosses a page.

The run is the in-memory format: 64-bit little-endian machines only. The journal is the portable format. Format 4 (one
snapshot `<group>.snap` holding the whole base, with a dense table of offsets by thing) and the earlier ones are set
aside at open (they are caches): the journal is replayed, and the first merge removes them. Format 1 also kept the link
facts by target (`roff`, `rp`, `re`); format 2 had one CRC per MiB and was mapped whole; format 3 had no journal group
in its header.
