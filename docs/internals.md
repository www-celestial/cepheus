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
| `encode : Buffer.t -> t -> unit`, `decode : Codec.reader -> t` | a value alone: a tag byte and the payload (the server's protocol; the journal codes a group's values in columns, [formats](formats.md#a-group)); `decode` raises `Codec.Short` |
| `inline : typ -> bool` | the index word is the value itself (int, date, money, bool, link); texts and floats are dictionary numbers |

## `Schema`: the table of properties (`src/schema.mli`)

| name | what it is |
|---|---|
| `type prop` | `{ name; typ; many; unique }`: `Cepheus.prop` |
| `p_name`, `p_type`, `p_many`, `p_unique`, `p_rule` | 1, 2, 3, 4, 5: the system properties |
| `first_prop`, `first_thing`, `last_thing` | 16, 65,536 and 2,147,483,647 (2³¹ − 1, the largest thing number a run holds) |
| `type t`, `initial` | a persistent table of properties and rules (a copy on change); the five system properties |
| `find`, `by_name`, `count` | a property by number, by name; one more than the largest number the table holds |
| `is_system p`, `is_prop_space e` | 1 ≤ p < 16; 16 ≤ e < 65,536 |
| `set`, `facts`, `system` | a changed table; the four facts that declare a property; the descriptions of 1 to 5 |
| `rules`, `rule`, `rule_by_name`, `set_rule`, `has_rules`, `rules_key` | the rules (thing -> name and canonical text); a key that changes when they change, by which their compiled form is cached |

## `Group`: the event (`src/group.mli`)

| name | what it is |
|---|---|
| `type kind` | `Retracted` 0, `Added` 1, `Derived` 2, `Underived` 3, `Now_asserted` 4, `Now_derived` 5: what a change does to its fact, the journal's kind byte ([rules](rules.md#derived-facts-are-in-the-journal)) |
| `type change` | `{ kind; e; p; v }`; `after kind` the state it leaves (0 absent, 1 asserted, 2 only derived), `present c` |
| `type t` | `{ n; time; by; why; first_new; count_new; changes }`: the group's number, the database's clock in ms, who, why, the first new thing and how many, the resolved changes |
| `encode`, `decode`, `equal` | the journal's coding of a group, format 2: its texts once, its changes in columns, in their order ([formats](formats.md#a-group)); `decode` raises `Codec.Short` on bytes that are not a group, never allocates for a count the bytes cannot hold |
| `type source`, `encode_source` | what the coding reads of a group's changes (kinds, things, the column of each value and the columns' properties and tags, the numbers, the floats' bits, the texts): from `t`'s array (`encode`) or from a large group's arrays (`Resolve.encode_large`), so both write the same bytes |
| `decode_v1` | the coding of format 1 (a change after the other), read only by `Journal.convert` |

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
| `type pending`, `begin_frame j len first count`, `body p buf off n`, `finish p`, `drop p` | a frame written by pieces (a large group's): its place taken at the end of the journal (in a new segment, made and forced now, when the current one would pass its limit); the body's pieces written in order, forced every `force_every` bytes (32 MiB); then the header, the trailer and an fsync; or the pieces taken back off the file, forced. A failure of `body`, `finish` or `drop` cuts the journal back and fails it, as `append`'s does. Nothing else may append between `begin_frame` and `finish` or `drop` |
| `written_body p` | the body's bytes written so far, read back (for the simulation) |
| `next_group`, `position`, `close` | the next group's number; where the next frame goes; closes |
| `verify disk dir id`, `read disk dir id f` | a strict full read: the number of groups; every group in order |
| `convert disk dir id` | reads each segment's header (40 bytes); every segment of format 1 rewritten in format 2 (written beside, forced, renamed over, the directory forced), its frames as they were; a frame that does not check is a torn tail in the newest segment (cut) and damage elsewhere (`Damaged`); returns the segments converted. `Engine.open_` calls it before anything reads the journal |
| `segment_name n` | `%020d.seg` |
| `write_us`, `fsync_us`, `clock` | histograms of each frame's `pwrite` and `fsync`, in µs; the time in µs |

## `Disk`: the file system as the engine sees it (`src/disk.mli`)

| name | what it is |
|---|---|
| `type fd`, `exception Io of string` | an open file; a failed call (`CALL PATH: REASON`) |
| `type t` | 16 operations: `exists`, `mkdir`, `readdir` (sorted), `openf path create`, `size`, `pread`, `pwrite` (exactly the bytes asked), `truncate`, `fsync`, `close`, `rename` (atomic), `remove`, `sync_dir` (makes a directory's names durable), `lock`, `unlock`, `now` (ms); and `parallel`: calls may come from several domains at once, each on its own files (`true` for the real disk; `false` for the simulated one, so that the engine makes them one after the other and a seed replays them) |
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
| `Pack.width x`, `Pack.mask w`, `Pack.bytes n w`, `Pack.get b bit w`, `Pack.put b bit x w` | bit packing: the bits of x read as an unsigned 63-bit number (0 for 0, 63 for a negative); fields of w ≤ 63 bits one after the other, little-endian (field i at bit i·w), read by one unaligned 8-byte load, a shift and a mask when the field fits in it (w ≤ 55), byte by byte otherwise and near the end of the bytes; `put` writes into zero bits |
| `Pack.put_ints out n f`, `Pack.get_ints r n a at` | a column of n ints in blocks of 128, each a frame of reference or deltas, whichever is shorter ([formats](formats.md#a-group)); `get_ints` raises `Codec.Short` on bytes that are not a column |
| `Crc32c.bytes b off len`, `Crc32c.extend crc b off len`, `Crc32c.string s` | CRC-32C (`extend`: the CRC of the bytes whose CRC is `crc` followed by these, for a frame checked by pieces), reflected polynomial 0x82F63B78, by the processor's instruction: the module checks the bounds (`Invalid_argument "Crc32c.extend"` otherwise), then calls `src/crc32c_stubs.c` by pieces of at most 1 MiB, so that another domain asking for a collection waits at most about 0.1 ms (a C call never stops for the GC); about 9 GB/s here. Its initialisation fails with `Failure` on a processor without the instruction |
| `Histogram.create`, `record`, `merge_into`, `percentile h q`, `total`, `max`, `mean` | log-linear buckets as HdrHistogram: exact below 256, then 128 a power of two; a percentile is rounded up to its bucket's highest value, never above the largest recorded |
| `Rng.make`, `copy`, `next`, `int r n`, `bool`, `chance r p`, `pick`, `split` | SplitMix64 (Steele, Lea, Flood 2014): the same seed gives the same numbers on every machine; not for cryptography |

## The modules without an interface

| module | the names tests and tools use |
|---|---|
| `Engine` | `open_`, `start` (`?follow`: the hooks the syncer calls before a frame's write and after it is published, for the server's local readers), `stop`, `write`, `snapshot_live`; the deterministic steps the simulation drives: `prepare ?release` (`release i`: request i, a large group, is mapped and its operations can go), `commit`, `merge_begin` (`~all` for a full merge), `install`, `compact`, `close`; `plan` and `plan_all` (which runs a merge takes, and its level), `cap l` (the capacity of level l, `compact_min * ratio^l` saturated at `max_int`); `read_meta disk dir` (the database's id); settings `compact_min` (200,000), `ratio` (4), `frame_limit` (the largest frame body the writer makes: `Journal.max_body`; tests make it small); counters `merges`, `frames`; histograms `prepare_us`, `switch_us`, `merge_us`, `large_resolve_us`, `large_encode_us`, `large_merge_us`; `on_merge` (a hook the bank test uses to compare old and new views at each switch) |
| `Store` | the view (`runs`, newest first, each with its parts `a` and `t`, its groups `lo`, `hi` and its `level`; `delta`, `dict`, `schema`, `group`, `next_e`) and its reads: `iter_facts`, `iter_values`, `iter_things`, `iter_prop`, `iter_range`, `mem`, counts; `value v typ w` and `text v i` (a word back to a value); `facts v` (the number of facts); `run_rows r` (a run's rows, which the levels weigh); `of_runs`; `add_texts v texts` (a large group's new texts at once: their ids from the first returned, one new view); the readers of one part (`base_*`), over format 7's blocks: a lookup by thing reads the directory word and the block's page (its header's bytes; the record from the same page, or field by field for a block across pages), by property a row block's page or a value index; `hash s` (the texts' hash, [formats](formats.md#run-dirsnapshotslo-20-digits-hi-20-digitsrun)); `layout`, `rooms`, `offsets`, `of_offsets` (a part's sections, as a merge lays them out and a header lists them) |
| `Query` | `plan`, `rows`, `count`, `fold` (a level's source chosen by exact counts, but for a one-valued property of a bound thing, which offers at most one candidate and is taken before any pattern offering one or more without a lookup); settings `parallel_min` (20,000), `domains`; counter `work` (candidates enumerated, held to the Generic Join bound by the tests) |
| `Resolve` | `resolve` (the one function that checks and resolves a group, for the writer and for forks), `replay` (a journal's group onto a view); `resolve_large` (the faster path of a large group: `Some` the same result, or `None` to go the ordinary way), `encode_large` (the group as `Group.encode` codes it, in a buffer: the writer's encoding domain codes it, then begins its frame and writes it by pieces of 1 MiB beside the merge), `replay_large`, setting `large_min` (20,000) |
| `Bulk` | a large group's facts in Bigarrays (thing int32, property uint16, value int; by property value int and thing int32), in the group's order and by (property, value, thing), with their order by (thing, property, value) (`sorted`, or the permutation `order`); `in_order`, `by_thing` (a stable radix sort of the indexes), `make` (a counting sort by property in chunks, a stable radix sort of 11-bit digits by value; the group's texts are no longer sorted: the runs' dictionaries keep a hash table); `parallel k f` (f 0 .. f (k-1) taken in turn by `domains` domains, 4: one a core); settings `domains`, `chunk` (65,536 operations; tests make it small) |
| `Snapshot` | `merge ?busy ?bulk ?sync disk dir id view ~take ~level pos` (the one way to write a run; `~sync:false`: not forced at the end, for a large group's run, which its commit forces beside the frame), `force` (a run's file forced, once), `install` (forces a run not yet forced, then names it), `abandon`, `clean`, `load` (the chain), `check_and_build`, `name lo hi`; setting `sync_every` (8 MiB); counter `open_max` (pages open at once in a merge); `schema_of` (the schema of a view of runs, read from their property facts: `load`, and a local reader's runs); `file_page disk path k`, `file_pages disk path` (the file page that holds page k of a run's layout, the pages the file holds: for the tests of damage) |
| `Pages` | `size` (16,384), `capacity`, `set_capacity`, `drop`; counter `misses` (pages read from the disk); trace mode `tracing`, `trace`, `traced` (the cache study) |

## The server's modules (`server/`, library `cepheus_server`)

| module | what it is |
|---|---|
| `Toml` | the part of TOML 1.0 that `cluster.toml` and `tokens.toml` use; an error names its line |
| `Config` | `cluster.toml` read and checked (`load`), its paths (`socket_path`, `tokens_path`, `database_dir`) |
| `Tokens` | `tokens.toml`: tokens (`generate`, `check`, `save`), rights (`right`, `can_read`, `can_write`) |
| `Origin` | the token, session, serial and floor a group carries in its `why` (`wrap`, `parse`, `why`) |
| `Wire` | the protocol: frames, requests and replies, their codings, the error codes |
| `Sessions` | the session table of a database (`start`, `finish`, `replay`), its checkpoint (`save`, `load`) |
| `Core` | the server without sockets: a connection's frames in (`input`), replies out, rights, writes to `submit`; a question's answer (`answer`), the same at the server and in a local reader |
| `Net` | the process: listeners, I/O domains, a thread a connection, the limits of connections, follow streams (`follow_stream`), start, stop (`serve`) |
| `Follow` | a database's follow stream at the server: the visibility page (`page_path`, `open_page`), the writer's hooks (`hooks`: `before` a frame's write, `after` it is published), the readers' queues (`register`, `take`), the catch-up from the journal (`catch_up`), the view of remote reads (`view`) |
| `Follower` | a local reader's copy of a database: its runs from the files passed (`create`, `runs`), the frames applied (`frame`), the state visible under the page's number (`view`, `try_view`) |
| `Fdpass` | descriptors passed over a Unix socket (`send`, `recv`: SCM_RIGHTS) and a page mapped read-only and shared (`map_page`, `word`); its C is `server/fdpass_stubs.c` |
| `Client` | a client in OCaml (tests, benchmarks, `cepheus status`): `connect`, `open_db` (local reads over the Unix socket: `?local`), `get`, `find`, `write` with its session, `declare`, `status` |
| `Tls` | TLS 1.3 by OpenSSL on memory buffers (`server_ctx`, `client_ctx`, `handshake`, `read`, `write`, `make_cert`); its C, a core of plain C and its OCaml wrappers, is `server/tls_stubs.c` |
