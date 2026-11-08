# Internals

`src/cepheus.mli` exports the engine's modules as `Cepheus.Value`, `Cepheus.Journal`, ... for the tests, the tools
and the benchmarks. They are not the API: they may change from one version to the next. This page lists what each
one offers. The modules with an interface file (`.mli`) come first, every name of it; the others (`Engine`, `Store`,
`Query`, `Resolve`, `Bulk`, `Snapshot`, `Pages`) expose their whole implementation, and only the names the tests and tools
use are listed.

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

## `Value`: values and types (`src/value.mli`)

| name | what it is |
|---|---|
| `type t` | `Int`, `Float`, `Bool`, `Text`, `Date`, `Money`, `Link`: `Cepheus.value` |
| `type typ` | `Tint`, `Tfloat`, `Tbool`, `Ttext`, `Tdate`, `Tmoney of int`, `Tlink`: `Cepheus.typ` |
| `has_type : typ -> t -> bool` | the value is of the type |
| `code : typ -> int` | the number that stores a type in `cepheus/type`: int 0, float 1, bool 2, text 3, date 4, link 6, money with d digits 5 + 16 d |
| `of_code : int -> typ option` | the reverse; `None` for an unknown code (money beyond 18 digits) |
| `typ_name : typ -> string` | `int`, `float`, `bool`, `text`, `date`, `money(d)`, `link` |
| `to_string : t -> string` | `42`, a float in hexadecimal (`%h`), `true`, a text quoted (`%S`), `date 1700000000000`, `money 120000`, `#65536` |
| `equal`, `compare` | floats by their 64 bits (`nan` equals itself, `0.0` differs from `-0.0`), the rest structurally |
| `encode : Buffer.t -> t -> unit`, `decode : Codec.reader -> t` | the journal form: a tag byte and the payload ([formats](formats.md#a-group)); `decode` raises `Codec.Short` |
| `inline : typ -> bool` | the index word is the value itself (int, date, money, bool, link); texts and floats are dictionary numbers |

## `Schema`: the table of properties (`src/schema.mli`)

| name | what it is |
|---|---|
| `type prop` | `{ name; typ; many; unique }`: `Cepheus.prop` |
| `p_name`, `p_type`, `p_many`, `p_unique` | 1, 2, 3, 4: the system properties |
| `first_prop`, `first_thing`, `last_thing` | 16, 65,536 and 2,147,483,647 (2³¹ − 1, the largest thing number a run holds) |
| `type t`, `initial` | a persistent table of properties (a copy on change); the four system ones |
| `find`, `by_name`, `count` | a property by number, by name; one more than the largest number the table holds |
| `is_system p`, `is_prop_space e` | 1 ≤ p < 16; 16 ≤ e < 65,536 |
| `set`, `facts`, `system` | a changed table; the four facts that declare a property; the descriptions of 1 to 4 |

## `Group`: the event (`src/group.mli`)

| name | what it is |
|---|---|
| `type change` | `{ add; e; p; v }`: an addition (`add = true`) or a retraction of the fact (e, p, v) |
| `type t` | `{ n; time; by; why; first_new; count_new; changes }`: the group's number, the database's clock in ms, who, why, the first new thing and how many, the resolved changes |
| `encode`, `decode`, `equal` | the journal form ([formats](formats.md#a-group)) |

## `Journal`: the write-ahead log (`src/journal.mli`)

| name | what it is |
|---|---|
| `exception Damaged of string` | durable data lost or changed; the message says where ([errors](errors.md#damaged-durable-data-lost-or-changed)) |
| `type position` | `{ segment; offset; next }`: a segment (by its first group), an offset in it, the group of the frame there |
| `max_body : int` | 256 MiB (268,435,456): the largest frame body; recovery takes a longer length field for damage |
| `segment_limit : int ref` | 64 MiB; the tests make it small |
| `window : int ref` | 4 MiB: the bytes of a segment a scan holds at once; the tests make it small (40 at least) |
| `create disk dir id` | a new journal, first group 1 |
| `recover ?frame ?after ~force disk dir id from on_group` | reads from `from` (the start without it) through the window, calls `frame` on each frame's position and `on_group` on each group, but for the frames whose groups are all `after` or before (checked by their CRCs, not decoded); with `force`, before replaying a group of the newest segment, writes that segment's newest frame again (its header if it holds no frame) and forces the segment and the directory (G13); cuts a torn tail durably, rebuilds the trailers of intact frames, returns the journal ready to append |
| `append j body first count` | one frame of `count` groups from `first`: written, then forced; on a failure, cuts the journal back to its last durable frame (forced; a failed cut is reported on stderr) and raises `Disk.Io`; every later append raises `Disk.Io` (G10, G13) |
| `next_group`, `position`, `close` | the next group's number; where the next frame goes; closes |
| `verify disk dir id`, `read disk dir id f` | a strict full read: the number of groups; every group in order |
| `segment_name n` | `%020d.seg` |
| `write_us`, `fsync_us`, `clock` | histograms of each frame's `pwrite` and `fsync`, in µs; the time in µs |

## `Disk`: the file system as the engine sees it (`src/disk.mli`)

| name | what it is |
|---|---|
| `type fd`, `exception Io of string` | an open file; a failed call (`CALL PATH: REASON`) |
| `type t` | 16 operations: `exists`, `mkdir`, `readdir` (sorted), `openf path create`, `size`, `pread`, `pwrite` (exactly the bytes asked), `truncate`, `fsync`, `close`, `rename` (atomic), `remove`, `sync_dir` (makes a directory's names durable), `lock`, `unlock`, `now` (ms) |
| `real` | the machine's file system (`lseek` then `read` or `write`; `lockf` locks, held in a table keyed by the lock file's device and inode, so that every path to one file is one lock) |
| `read_all`, `write_file` | a whole file; a file written durably and atomically (beside it, fsync, rename, fsync of the directory) |

## `Sim_disk`: the simulated disk (`src/sim_disk.mli`)

| name | what it is |
|---|---|
| `create ?reverts rng`, `disk t` | a simulated disk drawing from a seeded generator (`reverts`: a failed fsync undoes the failed writes in memory, as Btrfs does; by default it keeps them, as ext4 and XFS do); the `Disk.t` the engine uses |
| `sector` | 512 bytes: the unit of loss and of tearing |
| `exception Crash`, `crash_after t n` | the (n+1)-th mutating call from now raises `Crash` instead of running: a crash inside a call |
| `type draw` | the choices of a power loss: `Names` (how many of a directory's name changes survive, a prefix), `Length` (a grown file's length), `Cut`, `Sector` (lost, kept or torn), `Tear` (how many bytes of a torn sector) |
| `crash ?choose t` | a power loss: files closed, locks released, each unsynced choice drawn at random or by `choose`, so a test can enumerate every outcome |
| `kill t` | the process dies, the machine stays up: what was written and not forced stays readable, to be lost at a later `crash` |
| `pending_names`, `flip_durable`, `fail_next_fsync`, `advance` | the name changes not synced; a silent bit flip in durable bytes (F3); the next fsync fails and the sectors written since the last fsync are marked clean without reaching the disk: a later fsync does not write them unless they are written again (F4); the clock moves |
| `fail_fsync_at ?crash_after t n`, `failures t` | the (n+1)-th fsync from now fails as above, and with `crash_after c` the process dies at the (c+1)-th mutating call after it; the fsyncs that failed so far |
| `durable_size`, `files`, `durable_bytes` | what is durable, for the checks |

## `Codec`, `Crc32c`, `Histogram`, `Rng`

| name | what it is |
|---|---|
| `Codec.put_varint`, `put_int`, `put_string`, `put_u64` | LEB128 varints (an int ≥ 0 in 1 to 9 bytes), zigzag ints, length-prefixed strings, 8 bytes little-endian |
| `Codec.reader`, `get_varint`, `get_int`, `get_byte`, `get_string`, `get_u64`, `at_end`, `exception Short` | a bounded reader over bytes; every read past the end raises `Short` |
| `Crc32c.bytes b off len`, `Crc32c.extend crc b off len`, `Crc32c.string s` | CRC-32C (`extend`: the CRC of the bytes whose CRC is `crc` followed by these, for a frame checked by pieces), reflected polynomial 0x82F63B78, by the processor's instruction: the module checks the bounds (`Invalid_argument "Crc32c.extend"` otherwise), then calls `src/crc32c_stubs.c` by pieces of at most 1 MiB, so that another domain asking for a collection waits at most about 0.1 ms (a C call never stops for the GC); about 9 GB/s here. Its initialisation fails with `Failure` on a processor without the instruction |
| `Histogram.create`, `record`, `merge_into`, `percentile h q`, `total`, `max`, `mean` | log-linear buckets as HdrHistogram: exact below 256, then 128 a power of two; a percentile is rounded up to its bucket's highest value, never above the largest recorded |
| `Rng.make`, `copy`, `next`, `int r n`, `bool`, `chance r p`, `pick`, `split` | SplitMix64 (Steele, Lea, Flood 2014): the same seed gives the same numbers on every machine; not for cryptography |

## The modules without an interface

| module | the names tests and tools use |
|---|---|
| `Engine` | `open_`, `start`, `stop`, `write`, `snapshot_live`; the deterministic steps the simulation drives: `prepare`, `commit`, `merge_begin` (`~all` for a full merge), `install`, `compact`, `close`; `plan` and `plan_all` (which runs a merge takes, and its level), `cap l` (the capacity of level l); `read_meta disk dir` (the database's id); settings `compact_min` (200,000), `ratio` (4), `frame_limit` (the largest frame body the writer makes: `Journal.max_body`; tests make it small); counters `merges`, `frames`; histograms `prepare_us`, `switch_us`, `merge_us`, `large_resolve_us`, `large_encode_us`, `large_merge_us`; `on_merge` (a hook the bank test uses to compare old and new views at each switch) |
| `Store` | the view (`runs`, newest first, each with its parts `a` and `t`, its groups `lo`, `hi` and its `level`; `delta`, `dict`, `schema`, `group`, `next_e`) and its reads: `iter_facts`, `iter_values`, `iter_things`, `iter_prop`, `iter_range`, `mem`, counts; `value v typ w` and `text v i` (a word back to a value); `facts v` (the number of facts); `run_rows r` (a run's rows, which the levels weigh); `of_runs` |
| `Query` | `plan`, `rows`, `count`, `fold`; settings `parallel_min` (20,000), `domains`; counter `work` (candidates enumerated, held to the Generic Join bound by the tests) |
| `Resolve` | `resolve` (the one function that checks and resolves a group, for the writer and for forks), `replay` (a journal's group onto a view); `resolve_large` (the faster path of a large group: `Some` the same result, or `None` to go the ordinary way), `replay_large`, setting `large_min` (20,000) |
| `Bulk` | a large group's facts in arrays, sorted by (thing, property, value) and by (property, value, thing): counting sorts and a stable radix sort of 11-bit digits; `make` |
| `Snapshot` | `merge ?busy ?bulk disk dir id view ~take ~level pos` (the one way to write a run), `install`, `abandon`, `clean`, `load` (the chain), `check_and_build`, `name lo hi`; setting `sync_every` (8 MiB); counter `open_max` (pages open at once in a merge) |
| `Pages` | `size` (16,384), `capacity`, `set_capacity`, `drop`; counter `misses` (pages read from the disk); trace mode `tracing`, `trace`, `traced` (the cache study) |
