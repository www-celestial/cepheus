# Limits and defaults

Every bound and every default value of the engine, with where it is set in the code. The settings named `Module.x`
are internal references (`Cepheus.Engine.compact_min := ...`), for tests and benchmarks; an application uses the
defaults, and the cache's size (`set_cache`).

## Things, properties, values

| what | limit or default | where |
|---|---|---|
| thing numbers | from 65,536 up, dense, in the order things are made | `Schema.first_thing` |
| things in a database | below 2³² (4,294,967,296): the by-property rows store a thing in 4 bytes. Not checked: a database must stay below it | `Store.layout` (`ave`) |
| property numbers | 16 to 65,535 (the by-thing rows store a property in 2 bytes): 65,520 properties a database; `declare` takes the lowest free one | `Schema.first_prop`, `eap` |
| system properties | 1 `cepheus/name`, 2 `cepheus/type`, 3 `cepheus/many`, 4 `cepheus/unique`; 0 and 5 to 15 reserved | `Schema.system` |
| `Int`, `Date`, `Money` | 63-bit signed integers: −2⁶² to 2⁶² − 1 | OCaml's `int` |
| `Money` digits | 0 to 18 (`Tmoney 19` is refused: unknown type code) | `Value.of_code` |
| `Float` | any IEEE double; each distinct value takes a dictionary entry of 8 bytes | `Store.float_key` |
| `Text` | any bytes, any length a group can hold (below) | |
| distinct texts and floats | below 2³² (dictionary numbers in 4 bytes in the sorted list) | `ssort` |
| `by` | any `int` (0 by default) | `Cepheus.write` |
| `why` | any text (`""` by default) | `Cepheus.write` |

## Writes

| what | limit or default | where |
|---|---|---|
| one group | its encoding must stay under 256 MiB (the largest frame body). A larger group raises `Invalid_argument` in the syncer thread, which is not caught: the database stops answering. Keep groups to what one event is | `Journal.max_body` |
| operations in a group | no other limit; every `Expect` is checked against the state before the group | |
| a batch | up to 4,096 waiting writes resolved at once | `Engine.max_batch` |
| a frame | the batches resolved during an fsync join the waiting frame until its body passes 8 MiB; then the writer waits for the fsync | `Engine.max_frame` |
| a segment | a new segment begins when the next frame would take the current one past 64 MiB | `Journal.segment_limit` |
| frame overhead | 44 bytes (a 28-byte header and a 16-byte trailer) | `Journal.fh`, `Journal.ft` |
| segment header | 40 bytes | `Journal.seg_header` |
| writers | one per database (the writer thread of its domain) | `Engine.start` |

## Merges and snapshots

| what | limit or default | where |
|---|---|---|
| when a merge starts | when the changes since the last merge pass max(200,000, n/16), n being the facts of the base | `Engine.compact_min` (200,000), `Engine.needs_compaction` |
| what counts as a change | every addition or retraction applied since the last merge (one undone later counts twice) | `Store.change` (`dn`) |
| catch-up | the merge replays the groups written meanwhile until it is fewer than 256 behind; then the writer replays the rest and switches | `Engine.catch_up` |
| a merge's fsyncs | every 8 MiB while the journal is writing, else once at the end | `Snapshot.sync_every` |
| after a failed merge | the next one waits until the delta has grown by another threshold | `Engine.finish_merge` |
| snapshots kept | the newest 2 (a merge's file is the third while it is written) | `Snapshot.keep` |
| snapshot header | 4,096 bytes | `Snapshot.header` |
| page | 16 KiB (16,384 bytes) | `Pages.bits` (14) |
| CRC table | 4 bytes a page | `Snapshot.merge` |
| snapshot format | 4; formats 1 to 3 are set aside at open and rebuilt from the journal | `Snapshot.format` |
| journal format | 1 | `Journal.format` |

## Memory and the cache

| what | limit or default | where |
|---|---|---|
| the cache | 1 GiB (65,536 pages) for the whole process | `Pages.capacity`, `set_cache` |
| smallest cache | 16 pages (256 KiB): `set_cache` rounds below up | `Pages.set_capacity` |
| S3-FIFO's small queue | a tenth of the cache | `Pages.make_room` |
| ghost queue | as many keys as the cache has pages | `Pages.make_room` |
| a page's counter | 2 bits (0 to 3) | `Pages.touch` |
| pages in memory | under 1.25 times the cache: a full collection after each quarter of the cache evicted (16 pages at least) | `Pages.room` |
| a snapshot read whole at open | when its pages fit in the cache | `Snapshot.check_and_build` |
| a merge | the cache, at most 8 page buffers, and 21 bytes a page of the new base | [theory](theory.md#8-merges-written-to-a-file) |
| the delta | about 170 bytes a change, until the next merge | measured |
| the base | about 25 bytes a fact (245,824,096 bytes at 10 M facts), read through the cache | measured |
| recovery | each segment after the snapshot's position is read whole into memory, one at a time (up to 64 MiB) | `Journal.scan` |
| `verify` | every segment read whole, one at a time | `Journal.read` |

## Questions

| what | limit or default | where |
|---|---|---|
| variables | at most 63 (0 to 62: the planner keeps bound variables in the bits of an `int`) | `Query.order` |
| variable orders tried | every order for up to 7 variables (with pruning); greedy beyond | `Query.order` |
| parallel questions | when the first variable has 20,000 candidates or more | `Query.parallel_min` |
| domains of a question | the machine's recommended count, at most 8 | `Query.domains` |
| slices | min(candidates, 16 × domains), taken in turn from a shared counter | `Query.fold` |
| the property of a pattern | a constant: no variable in the property position | `Query.pattern` |

## Files and the platform

| what | limit or default | where |
|---|---|---|
| processes | one per database: an exclusive `lockf` lock on `DIR/lock`, kept until close or death. Inside one process, a table of held locks keyed by the path as written: open a directory under one spelling only | `Disk.real.lock` |
| `DIR/cepheus` | 37 bytes: 17 of magic, 16 of id, 4 of CRC | `Engine.read_meta` |
| file descriptors | one for the journal's current segment, one for each snapshot file a live view holds (closed when the view's base is collected) | `Snapshot.check_and_build` |
| snapshots | 64-bit little-endian machines (the in-memory layout); the journal is portable | [formats](formats.md) |
| durability | relies on `fsync` meaning durable, for files and for directories (Linux and its usual file systems) | [operations](operations.md#disks) |
| OCaml | 5 (domains), with `unix` and `threads`; no C | `src/dune` |

## Measurement tools

| what | value | where |
|---|---|---|
| `Histogram` | exact below 256 µs, then 128 buckets per power of two: every percentile within 1/128 (0.8 %); 3,584 counters | `src/histogram.ml` |
| the simulated disk's sector | 512 bytes, the unit of loss and of tearing | `Sim_disk.sector` |
| benchmark runs | 21 (`RUNS`), median and its 95 % interval [x(6), x(16)], coverage 97.3 % | `bench/stats.ml` |
