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
| `first_prop`, `first_thing`, `last_thing` | 16, 65,536 and 2,147,483,647 ($2^{31} - 1$, the largest thing number a run holds) |
| `type t`, `initial` | a persistent table of properties and rules (a copy on change); the five system properties |
| `find`, `by_name`, `count` | a property by number, by name; one more than the largest number the table holds |
| `is_system p`, `is_prop_space e` | $1 \le p < 16$; $16 \le e < 65{,}536$ |
| `set`, `facts`, `system` | a changed table; the four facts that declare a property; the descriptions of 1 to 5 |
| `rules`, `rule`, `rule_by_name`, `set_rule`, `has_rules`, `rules_key` | the rules (thing -> name and canonical text); a key that changes when they change, by which their compiled form is cached |

## `Group`: the event (`src/group.mli`)

| name | what it is |
|---|---|
| `type kind` | `Retracted` 0, `Added` 1, `Derived` 2, `Underived` 3, `Now_asserted` 4, `Now_derived` 5: what a change does to its fact, the journal's kind byte ([rules](rules.md#derived-facts-are-in-the-journal)) |
| `type change` | `{ kind; e; p; v }`; `after kind` the state it leaves (0 absent, 1 asserted, 2 only derived), `present c` |
| `type t` | `{ n; time; by; why; first_new; count_new; changes }`: the group's number, the database's clock in ms, who, why, the first new thing and how many, the resolved changes |
| `encode`, `decode`, `equal` | the journal's coding of a group, format 2: its texts once, its changes in columns, in their order ([formats](formats.md#a-group)); `decode` raises `Codec.Short` on bytes that are not a group, never allocates for a count the bytes cannot hold |
| `type source`, `encode_source` | what the coding reads of a group's changes (kinds, things, the column of each value and the columns' properties and tags, the numbers, the floats' bits, the texts): from `t`'s array (`encode`), from a large group's arrays (`Resolve.encode_large`), or from a group's records and changes read by index (`encode_parts`), so all write the same bytes |
| `encode_parts b g ~n ~thing ~prop ~tag ~word ~text`, `tag_of_typ` | `encode` of the group with `n` more changes after its records, each `Derived`, read by index and never made records: a change of the rules' derived facts in its run of their own, read from the run's columns (`Engine`); columns and texts numbered in order of first use over every change, so the bytes are `encode`'s of the whole group. `tag_of_typ`: the tag of a type's values in the coding |
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
| `exception Crash`, `crash_after t n` | the $(n+1)$-th mutating call from now raises `Crash` instead of running: a crash inside a call |
| `type draw` | the choices of a power loss: `Names` (how many of a directory's name changes survive, a prefix), `Length` (a grown file's length), `Cut`, `Sector` (lost, kept or torn), `Tear` (how many bytes of a torn sector) |
| `crash ?choose t` | a power loss: files closed, locks released, each unsynced choice drawn at random or by `choose`, so a test can enumerate every outcome |
| `kill t` | the process dies, the machine stays up: what was written and not forced stays readable, to be lost at a later `crash` |
| `pending_names`, `flip_durable`, `fail_next_fsync`, `advance` | the name changes not synced; a silent bit flip in durable bytes (F3); the next fsync fails and the sectors written since the last fsync are marked clean without reaching the disk: a later fsync does not write them unless they are written again (F4); the clock moves |
| `fail_fsync_at ?crash_after t n`, `failures t` | the $(n+1)$-th fsync from now fails as above, and with `crash_after c` the process dies at the $(c+1)$-th mutating call after it; the fsyncs that failed so far |
| `durable_size`, `files`, `durable_bytes` | what is durable, for the checks |

## `Codec`, `Crc32c`, `Histogram`, `Rng`

| name | what it is |
|---|---|
| `Codec.put_varint`, `put_int`, `put_string`, `put_u64` | LEB128 varints (an int $\ge 0$ in 1 to 9 bytes), zigzag ints, length-prefixed strings, 8 bytes little-endian |
| `Codec.reader`, `get_varint`, `get_int`, `get_byte`, `get_string`, `get_u64`, `at_end`, `exception Short` | a bounded reader over bytes; every read past the end raises `Short` |
| `Pack.width x`, `Pack.mask w`, `Pack.bytes n w`, `Pack.get b bit w`, `Pack.put b bit x w` | bit packing: the bits of $x$ read as an unsigned 63-bit number (0 for 0, 63 for a negative); fields of $w \le 63$ bits one after the other, little-endian (field $i$ at bit $i \cdot w$), read by one unaligned 8-byte load, a shift and a mask when the field fits in it ($w \le 55$), byte by byte otherwise and near the end of the bytes; `put` writes into zero bits |
| `Pack.put_ints out n f`, `Pack.get_ints r n a at` | a column of n ints in blocks of 128, each a frame of reference or deltas, whichever is shorter ([formats](formats.md#a-group)): one pass a block finds both ranges, fields of up to 31 bits are packed by a running word written 4 bytes at a time; `get_ints` raises `Codec.Short` on bytes that are not a column |
| `Crc32c.bytes b off len`, `Crc32c.extend crc b off len`, `Crc32c.string s` | CRC-32C (`extend`: the CRC of the bytes whose CRC is `crc` followed by these, for a frame checked by pieces), reflected polynomial 0x82F63B78, by the processor's instruction: the module checks the bounds (`Invalid_argument "Crc32c.extend"` otherwise), then calls `src/crc32c_stubs.c` by pieces of at most 1 MiB, so that another domain asking for a collection waits at most about 0.1 ms (a C call never stops for the GC); about 9 GB/s here. Its initialisation fails with `Failure` on a processor without the instruction |
| `Histogram.create`, `record`, `merge_into`, `percentile h q`, `total`, `max`, `mean` | log-linear buckets as HdrHistogram: exact below 256, then 128 a power of two; a percentile is rounded up to its bucket's highest value, never above the largest recorded |
| `Rng.make`, `copy`, `next`, `int r n`, `bool`, `chance r p`, `pick`, `split` | SplitMix64 (Steele, Lea, Flood 2014): the same seed gives the same numbers on every machine; not for cryptography |

## The modules without an interface

| module | the names tests and tools use |
|---|---|
| `Engine` | `open_`, `start` (`?follow`: the hooks the syncer calls before a frame's write and after it is published, for the server's local readers), `stop`, `write`, `snapshot_live`; `whole b` (a batch's groups with all their changes: a change's derived facts in its run of their own are coded into its frame from the run's columns and kept in the batch's `rest`, made records only here, by the watch's thread); the deterministic steps the simulation drives: `prepare ?release` (`release i`: request i, a large group, is mapped and its operations can go), `commit`, `merge_begin` (`~all` for a full merge), `install`, `compact`, `close`; `plan`, `plan_all` and `plan_tier` (which runs a merge takes, and its level; `plan_tier`: the delta and the newest runs down to the last of the first level two runs share, for an idle writer), `tidy l` (the server's tick: an idle writer merges such a tier, in the background), `cap l` (the capacity of level l, `compact_min * ratio^l` saturated at `max_int`); `read_meta disk dir` (the database's id); settings `compact_min` (200,000), `ratio` (4), `frame_limit` (the largest frame body the writer makes: `Journal.max_body`; tests make it small); counters `merges`, `frames`; histograms `prepare_us`, `switch_us`, `merge_us`, `large_resolve_us`, `large_encode_us`, `large_merge_us`; `on_merge` (a hook the bank test uses to compare old and new views at each switch) |
| `Store` | the view (`runs`, newest first, each with its parts `a` and `t`, its groups `lo`, `hi` and its `level`; `delta`, `dict`, `schema`, `group`, `next_e`) and its reads: `iter_facts`, `iter_values`, `iter_things`, `iter_prop`, `iter_range`, `mem`, counts; `nth_bound v p w m` (the m-th fact of p from w in each run's index and in the delta, the nearest to w: where the index path's search for a window of m facts starts); the delta's facts of a property by value in `VM`, a balanced tree as `Map`'s whose nodes keep the sums of their subtree's net counts and additions (an order-statistic tree), so that `count_range` and `nth_bound` read the delta in $O(\log n)$; `set_sorted` (a group's changes applied to the delta together: ordered by (property, value, thing), by stable radix sorts of 11 bits a pass, `radix_by`, when there are 256 or more, by the comparisons below; a property the delta holds no value of gets its tree of values built at once from them in order, `VM.of_sorted`, in $O(n)$); the maps of ints of the delta (`IM`: by thing, a value's things, a thing's net counts) are the balanced trees of Stdlib's `Map.Make (Int)` written out, the same functions, with `IM.of_sorted` (the tree of sorted bindings in $O(n)$, a node a binding, where Map's ways from sorted keys copy a path a key or split and join by unions: about 65 words a binding against 6, measured); `iter_range_values` (the values of a range, each once: on one run with no change of the property, side by side, no table); `holders_from v p ?value ~desc ~from ()` (the things that hold p, or the fact (p, w), in the order of their ids from a thing on, each once: each part's column rank table a word of 32 things at a time, the rows of (p, w) from a binary search, the delta's from its map by value (at most 512 entries of p) or by thing (read only up to the runs' next thing), merged, each thing checked when the view has several runs or a change of p: a sort by a thing, a range of a thing) and `count_holders v p lo hi` (the facts of p of the things lo to hi: the rank tables and offsets, $O(1)$ a part); `value v typ w` and `text v i` (a word back to a value); `facts v` (the number of facts); `run_rows r` (a run's rows, which the levels weigh); `of_runs`; `add_texts v texts` (a large group's new texts at once: their ids from the first returned, one new view); the readers of one part (`base_*`), over format 8's sections: a lookup of a thing's property reads its column (`cthing`: a rank word; `crows`: one offset header; `cval`: a directory entry and a field; the entries held in `base.cols` by `ready`), its slices for the leapfrog (`slice_values`, `slice_things`, `read_values`, `read_things`) and for a level's candidates (`iter_slice_values`, `iter_slice_things`: the rows of a slice a level counted, read from its first row with no second lookup), `value1` (a one-valued property's one value), `iter_holders`, `iter_taken` (a property's things, its values, each once; its values read from the value index's rank words, a bit a value and no row decoded, when the property has one: `base_iter_indexed_values`); every fact of a thing reads the directory word and the block's page (its header's bytes; the record from the same page, or field by field for a block across pages), by property a row block's page or a value index; `hash s` (the texts' hash, [formats](formats.md#run-dirsnapshotslo-20-digits-hi-20-digitsrun)); `layout`, `rooms`, `offsets`, `of_offsets` (a part's sections, as a merge lays them out and a header lists them: 25 offsets in format 10, 24 in format 9, whose pairs' section is empty); the pairs (an index of two properties, `Schema.within`, run format 10): a part's section read once by `ready` into `base.prs` (12 words a pair), its readers `pr_find`, `pr_groups`, `pr_w1`, `pr_start`, `pr_w2`, `pr_e`, `pr_group` (a binary search of the groups' values), `pr_lower` (of a group's rows), `pr_mem`; the view's: `pair_ready v ~p1 ~p2` (declared, and held by every run), `pair_from v ~p1 ~p2 w1 ~desc ~from cell` (the things of w1 in p2's order from a value on, each run's rows merged with the delta's, a run's row checked against the delta and the newer runs' parts t), `pair_groups` (the values of p1, every run's and the delta's), `pair_part` (one run and no change of the pair: its groups read where they are, Each's way); the delta's pairs `delta.dpr` (by p2: `byt`, each thing whose p1 or p2 changed since the delta began, its values of both; `byg`, a map of (w1, w2, thing) of those that hold both), kept by `pairs_after` at each change of a paired property's presence (in `change` and `set_sorted`; a thing's values read in the runs alone at its first change, `runs_one`) and made again by `pairs_reset` when a declaration changes (`Resolve.refresh`); `sort_ints` |
| `Query` | `plan`, `rows`, `count`, `fold` (a level's source chosen by exact counts, but for a one-valued property of a bound thing, which offers at most one candidate and is taken before any pattern offering one or more without a lookup: a level where it is always taken reads that one value); checks left to the next level when its variable is theirs; a leaf (a one-valued field in no other pattern) placed after the filters that follow its thing (`order`), its value read once, at its thing's level, by the check that the thing has one (`kept`); slices (a pattern whose other side is known) intersected by `leapfrog` (galloping seeks, `gallop`) when the source is one of 2 or more and the others are at most 8 times it; a level's source that is a slice `choose` counted for the binding is read straight from its run's rows (`Store.iter_slice_things`, `iter_slice_values`), not looked up again; a variable that `Less` bounds by the bindings before it reads its bounds from arrays made once a question, and only for a question with such bounds (`dyn_y`, `dyn_g`, `dyn_s`), no closure at each binding; a level of `parallel_min` candidates or more (exact counts) split across up to `domains` domains wherever it comes in the order, and the first level of two candidates or more past the levels of one, when the planner expects `probe_more` (4) times `parallel_min` candidates of work or more, probed: its candidates run on the asking domain until their work, measured (`probe_min` at least), says the rest takes that much (`fold ?any_order`: a merge that does not depend on the bindings' order, one accumulator a domain; otherwise one a slice, merged in slice order); the budget the sum of every domain's candidates; settings `parallel_min` (20,000), `probe_more` (4), `probe_min` (1,024), `domains`; counters `work` (candidates enumerated, held to the Generic Join bound by the tests), `splits` and `probed_splits` (the levels split, and those a probe split); a question's `stop` (`Timeout`, `Cancelled`, `check` every `every` = 1,024 candidates, `now_ms`, the monotonic clock) |
| `Top` | `Sort`, `Limit` and `After` over rows of index words (`give`: the heap path and the index path, whose `lead` is a pair (`Within`: the question fixes p1, Sort's first key is p2; `pairs`, false for the tests; counter `paired`), a property by value or the things that hold one; `sort_rows`, rows held already); `sort_cut` (a buffer sorted and cut back to its first k and their copies); `sort_radix` (a whole sort of `radix_min` rows or more, 4,096, whose first keys are inline words: each row's key their words one after the other, each from its column's least, or its greatest when descending, in as many bits as the column's range needs, up to 62 bits; a least-significant-digit radix sort of 11 bits a pass, every pass's counts made in one read of the keys, a pass skipped when every key has the same digit there; the runs of equal keys sorted again by the comparisons when the key did not hold the whole order), counter `radix_sorts` |
| `Ask` | the questions with operators (`compile`, `fold`): `fold ~shared` when the step keeps no binding it is given, each domain's bindings then written into one buffer of its own (an accumulator `with_buffer`) rather than an array a binding, and with Optionals each value's row written into that buffer too, one after the other (`expand_shared`: no list of a thing's values, no copy a row; `expand`, for a step that keeps its bindings, copies them), the Nots checked with no closure a binding (`kept`): `Answer`'s folds and `Cepheus.ask`'s, whose rows a domain gathers in chunks of up to 256 (a block of the minor heap each) and lists once at the end from the last row back, a row of up to 4 columns made as an array literal |
| `Pool` | the domains of the process: `cap` (OCAMLRUNPARAM's d, 128), `margin` (16), `live`, `spawn` (counted), `try_spawn` (none past the budget); the questions' helpers (`help`, `limit`: the cores less one, `keep`: 1 s, parked in poll on a pipe), counters `alive`, `spawned`. No systhreads: the Cesia client's engine links it |
| `Writers` | the writers' domains (`run`, `writers`: the cores; a database's writer and syncer threads in the one with the fewest), `background` (a domain, or past the budget a thread of the asking domain: merges, changes of the rules), counter `writer_domains` |
| `Resolve` | `resolve` (the one function that checks and resolves a group, for the writer and for forks; a cascade's or a clear's facts of the linking things of one thing and one link, read in the view before any of them goes, retracted together by `Store.set_sorted`: `Facts`; the group's changes and their words gathered in two arrays that grow, `Out`, where two lists were reversed into arrays at the end), `replay` (a journal's group onto a view); `resolve_large` (the faster path of a large group: `Some` the same result, or `None` to go the ordinary way), `encode_large` (the group as `Group.encode` codes it, in a buffer: the writer's encoding domain codes it, then begins its frame and writes it by pieces of 1 MiB beside the merge), `replay_large`, setting `large_min` (20,000) |
| `Bulk` | a large group's facts in Bigarrays (thing int32, property uint16, value int; by property value int and thing int32), in the group's order and by (property, value, thing), with their order by (thing, property, value) (`sorted`, or the permutation `order`); `in_order`, `by_thing` (a stable radix sort of the indexes), `make` (a counting sort by property in chunks, a stable radix sort of 11-bit digits by value; the group's texts are no longer sorted: the runs' dictionaries keep a hash table); `parallel k f` (f 0 .. f (k-1) taken in turn by `domains` domains, 4: one a core); settings `domains`, `chunk` (65,536 operations; tests make it small) |
| `Snapshot` | `merge ?busy ?bulk ?sync disk dir id view ~take ~level pos` (the one way to write a run; `~sync:false`: not forced at the end, for a large group's run, which its commit forces beside the frame), `force` (a run's file forced, once), `install` (forces a run not yet forced, then names it), `abandon`, `clean`, `load` (the chain), `check_and_build` (a run that fits in the cache read and checked by up to 4 domains), `name lo hi`; the column order written in the pass by thing (`columns`, `col_add`, `columns_end`: one rank table for the properties held by the same things); setting `sync_every` (8 MiB); counter `open_max` (pages open at once in a merge); `schema_of` (the schema of a view of runs, read from their property facts: `load`, and a local reader's runs); `file_page disk path k`, `file_pages disk path` (the file page that holds page k of a run's layout, the pages the file holds: for the tests of damage); the pairs written by the pass by thing (each thing's values of the paired properties the new run holds, against those below it, `Store.runs_one`: `prows`, `prow`), sorted (`prow_sorted`: a counting sort by w1 when its range is within a few times the rows, else a radix sort of 11 bits moving the rows; then each group by w2, stable) and written (`pairs_out`, `ptables`, `proom`); `format9` (for the tests: merges write format 9, as the version before did) |
| `Pages` | `size` (16,384), `capacity`, `set_capacity`, `drop`; counters `misses` (pages read from the disk) and `hits` (reads of a page in memory that the policy counted), `room_pages`, `resident_pages` (cepheus status); trace mode `tracing`, `trace`, `traced` (the cache study) |

`Top.sort_radix` on the invoices of tutorial 14, sorted by `Sort: [Desc(t), d]` (the figure is drawn from the engine's own sort, checked against the comparisons' order):

![Top, a row's key: 1,100 minus its total in 17 bits, then its date from January 5 in milliseconds in 34 bits, 51 bits in one int, cut into 5 digits of 11 bits, digit 0 on the right sorted first. Left, the 11 invoices of 2028 as read, each with its 5 digits; right, the same invoices sorted, 1,100 first, then 1,000, 900, 700, 600, the four of 500 in the order of their dates, then 400 and 300.](images/sort-radix.svg)

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
| `Answer` | a question's answer as index words (`answer`, `stream`), the same at the server and in a local reader (a row with Optionals pushed cell by cell, a word or 0 and the mask after them, no row array); a Group's groups in a `table` of open addressing over the key words (linear probing, at most half full), their Count, Sum, Min and Max in one flat array, a table a domain merged at the end (`merge_tables`), the groups then in their keys' order (`sorted`); `Each` with `Limit: k`, a group's buffer of its first rows (`firsts`): a binding compared with the group's k-th row before it is made a row, and for k up to `small_each` (32) the buffer kept in the order, a row put at its place and those past the k-th but its copies dropped at once (for a larger k, cut back at 2k rows as `Top`'s heap); the tickets that charge an answer's cells (`max_cells`, `pool_cells`) |
| `Agg` | the aggregates of protocol 9: exact sums (`Exact`: limbs of 30 bits), bags (`Bag`), selection (`select`: Hoare's FIND with Musser's bound), a group's `state` for a watch (Live), and the columns of Answer's tables (`col`: an int's exact sums in four ints a group, a group's state only once they would spill or for a float; every group's bag in one table of open addressing, or a table a group once they hold more than `own_min` (64) different values each on average, the domains' tables read together at the end, `by_group`) |
| `Window` | the windows of protocol 10 (`Wire.Over`): their checks (`check`), their types (`typ`), and `compute`, each window over rows given in `Sort`'s order: each group's rows listed by a counting sort of their groups, then one pass a window and a group (a running `Count`; `Sum` and `Avg` from exact sums, `Agg.add_value`, a sliding frame's leaving row taken out; `Min` and `Max` kept as they go, or over the last n rows by a monotone queue of the frame's candidates; `Rank` by the ties of the first keys; `Prev` by the place `back` rows before; one group's rows in their order, no counting sort); a page's `start` (the rows before it counted already, their sums, best values and places) from Answer's one fold of the rows before the cursor |
| `Live` | live questions, the same at the server and in a local reader: a hub of templates (`create`, `frame`, `durable`, `rebase`, `reset`, `stop`), a watch (`subscribe ?extra ?order`, `unsubscribe`); with `?order` (Sort and Limit) a window of its rows kept by the frames' rows and refilled by one page `Find` After its last row |
| `Net` | the process: listeners, I/O domains, a thread a connection, the limits of connections, follow streams (`follow_stream`), start, stop (`serve`) |
| `Follow` | a database's follow stream at the server: the visibility page (`page_path`, `open_page`), the writer's hooks (`hooks`: `before` a frame's write, `after` it is published), the readers' queues (`register`, `take`), the catch-up from the journal (`catch_up`), the view of remote reads (`view`) |
| `Follower` | a local reader's copy of a database: its runs from the files passed (`create`, `runs`), the frames applied (`frame`), the state visible under the page's number (`view`, `try_view`) |
| `Fdpass` | descriptors passed over a Unix socket (`send`, `recv`: SCM_RIGHTS) and a page mapped read-only and shared (`map_page`, `word`); its C is `server/fdpass_stubs.c` |
| `Client` | a client in OCaml (tests, benchmarks, `cepheus status`): `connect`, `open_db` (local reads over the Unix socket: `?local`), `get`, `find`, `write` with its session, `declare`, `watch ?order` and `next_push`, `status` |
| `Timings` | the times of the questions and writes at the server, a database each: `question`, `write` (a time recorded into the calling domain's slices of 10 s, no lock; true when it is past `[log] slow_ms`), `lines` (cepheus status: counts and sums since the start, p50, p99, maximum over 60 s); the slow log (`say`, at most 10 lines a second; `shape` of a question, `write_shape` and `write_text`, constants written `?`) |
| `Space` | what the data takes on the disk, for cepheus status: `statvfs` (its C is `server/space_stubs.c`), a database's journal and runs bytes, its merges |
| `Prometheus` | cepheus status in Prometheus's text exposition format 0.0.4 (`of_status`): families in base units, labels `database` and `peer`, summaries of the times |
| `Tls` | TLS 1.3 by OpenSSL on memory buffers (`server_ctx`, `client_ctx`, `handshake`, `read`, `write`, `make_cert`); its C, a core of plain C and its OCaml wrappers, is `server/tls_stubs.c` |
