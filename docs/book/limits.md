# Limits and defaults

Every bound and every default value of the engine, with where it is set in the code. The settings named `Module.x`
are internal references (`Cepheus.Engine.compact_min := ...`), for tests and benchmarks; an application uses the
defaults, and the cache's size (`set_cache`).

## Things, properties, values

| what | limit or default | where |
|---|---|---|
| thing numbers | from 65,536 up, dense, in the order things are made | `Schema.first_thing` |
| thing numbers | at most 2,147,483,647 ($2^{31} - 1$): a run stores a row block's least thing in 4 bytes, a large group a thing in 4 bytes, and a part counts the things it holds in the high 32 bits of a rank table's 64-bit word, read back into OCaml's 63-bit `int` (31 bits). A group that would make a larger number is refused with `Invalid "thing numbers end at 2147483647: this group would make #N"`; nothing wraps | `Schema.last_thing`, `Resolve.resolve` |
| property numbers | 16 to 65,535 (a thing block's entry stores its property in 2 bytes): 65,520 properties a database; `declare` takes the lowest free one | `Schema.first_prop`, `Snapshot.tblock_flush` |
| system properties | 1 `cepheus/name`, 2 `cepheus/type`, 3 `cepheus/many`, 4 `cepheus/unique`, 5 `cepheus/rule`; 0 and 6 to 15 reserved | `Schema.system` |
| `Int`, `Date`, `Money` | 63-bit signed integers: $-2^{62}$ to $2^{62} - 1$ | OCaml's `int` |
| `Money` digits | 0 to 18 (`Tmoney 19` is refused: unknown type code) | `Value.of_code` |
| `Float` | any IEEE double; each distinct value takes a dictionary entry of 8 bytes | `Store.float_key` |
| `Text` | any bytes, any length a group can hold (below) | |
| distinct texts and floats | below $2^{32}$ a run (a run's hash table holds a text's place in 4 bytes) | `Snapshot.merge` |
| values of one thing for one property | below $2^{32}$ in a run (a thing block's entry counts in 4 bytes); a merge that would pass it fails with `Invalid_argument` | `Snapshot.tblock_flush` |
| `by` | any `int` (0 by default) | `Cepheus.write` |
| `why` | any text (`""` by default) | `Cepheus.write` |

## Writes

| what | limit or default | where |
|---|---|---|
| one group | its encoding must stay within 256 MiB (268,435,456 bytes, the largest frame body): a larger group is refused with `Invalid "a group of N bytes is over the frame limit of 268435456"`, and the writer goes on | `Journal.max_body`, `Engine.too_large` |
| several groups at once | the groups resolved together go into one frame only while its body stays within 256 MiB: a group that would pass it waits for the next frame, and a large group starts a frame of its own, so a frame never passes the limit | `Engine.frame_limit`, `Engine.prepare`, `Engine.writer` |
| a large group | 20,000 operations or more, all `Add`: the faster path (arrays, sorts, a run merged at once; with rules, its facts a sorted prefix of the working set and its derived facts merged into its orders); below, or on any doubt (a rule that derives with a `Not` or an aggregate, a constraint broken, a second value of a one-valued property), the ordinary path | `Resolve.large_min`, `Reason.bulk` |
| derived changes of a group | at most $100{,}000 + 100 \times \text{its asserted changes}$, else refused, naming the rule that derived the most | `rule_budget` (`Reason.budget_base`, `Reason.budget_per`) |
| derived changes of a change of the rules or the ontology | at most $100{,}000 + 100 \times \text{its asserted changes} + 4 \times \text{the database's facts}$ | `change_budget` (`Reason.change_per`) |
| changes in the background | one at a time (the next waits); none beside a background merge; the writer waits for one more than 65,536 groups behind; one with new things is computed in its group | `Engine.change_backlog` |
| rounds on several domains | from 20,000 facts a round, up to 4 domains (`Bulk.domains`), rules without `Not` and aggregates, in a group the writer reasons itself (not a change in the background) | `Reason.par_min` |
| a rule | 1 pattern or more, at most 64 variables; a pattern's property a constant, or a variable bound by a pattern whose property is a constant | `Rules.check` |
| a small relation (unfolded on) | at most 10,000 facts, by exact counts; at most 10,000 rules unfolded from one rule | `Reason.small_limit`, `Reason.unfold_limit` |
| a template | one `every` pattern a rule, no `Not` or aggregate beside it; a list of at most 64 members (a group that makes a longer one is refused, naming the rule); no rule gives a list's property | `Reason.template_limit`, `Rules.check` |
| equality (`cepheus/same`) | two values are never the same thing, nor two properties, nor a thing a rule names; no `Not` or aggregate in a rule set that makes things the same; with equality the closure modules, the path of loads and the rounds on several domains are off | `Reason.apply_merges`, `Resolve` |
| OWL 2 RL (`Cepheus.Owl`) | property chains of two links (a longer one through properties of the program's); `owl/HasValue` a thing and `owl/TargetValue` a text (other values: a rule of the program's); AllDifferent, AllDisjointClasses, AllDisjointProperties as their pairs; `Why` gives the rewriting of an equality, not the equality's own proof; from Cesia (`cesia/cepheus/owl`) no `Why`, and the n-ary axioms written as their pairs by the program | `src/owl.ml` |
| a closure module | prp-trp, or the linear pair over another property, with distinct variables, no constant, no range; on a property of links that takes many values, none unique; one module a property | `Reason.find_modules` |
| operations in a group | no other limit; every `Expect` is checked against the state before the group | |
| a batch | up to 4,096 waiting writes resolved at once | `Engine.max_batch` |
| a frame | the batches resolved during an fsync join the waiting frame until its body passes 8 MiB; then the writer waits for the fsync | `Engine.max_frame` |
| a segment | a new segment begins when the next frame would take the current one past 64 MiB | `Journal.segment_limit` |
| frame overhead | 44 bytes (a 28-byte header and a 16-byte trailer) | `Journal.fh`, `Journal.ft` |
| segment header | 40 bytes | `Journal.seg_header` |
| writers | one per database (the writer thread of its domain) | `Engine.start` |

## Merges and runs

| what | limit or default | where |
|---|---|---|
| when a merge starts | when the changes since the last merge pass 200,000 | `Engine.compact_min` (200,000), `Engine.needs_compaction` |
| levels | level $l$ (1, 2, 3, ...) holds at most $200{,}000 \times 4^l$ rows: 800,000, 3.2 M, 12.8 M, 51.2 M, ...; a run's rows are its additions and its retractions | `Engine.ratio` (4), `Engine.cap` |
| what a merge takes | the delta and the newest runs, down to the first level whose capacity holds them all; one run is written there | `Engine.plan` |
| a large group's merge | the delta and the newest runs of the levels below the one that holds it; its run stays beside that level's runs until 16 of them would lie side by side, then all are merged | `Engine.tier` (16), `Engine.plan_large` |
| runs a merge takes | at most 31 (the pass by thing keeps a thing's sources in the bits of an integer, two a run); a database has at most 16 plus one a level | `Snapshot.max_take` |
| `snapshot` | the delta and every run into one run, at the deepest level among the runs or deeper if they do not fit there; nothing if there is one run and no group since the last merge | `Engine.plan_all`, `Engine.snapshot` |
| what counts as a change | every addition or retraction applied since the last merge (one undone later counts twice) | `Store.change` (`dn`) |
| catch-up | the merge replays the groups written meanwhile until it is fewer than 256 behind; then the writer replays the rest and switches | `Engine.catch_up` |
| a merge's fsyncs | every 8 MiB while the journal is writing, else once at the end | `Snapshot.sync_every` |
| after a failed merge | the next one waits until the delta has grown by another threshold | `Engine.finish_merge` |
| run files kept | the chain from 0 to the newest group (no fallback outside it: the journal rebuilds any run); a merge's file is one more while it is written | `Snapshot.install` |
| run header | 4,096 bytes | `Snapshot.header` |
| page | 16 KiB (16,384 bytes) | `Pages.bits` (14) |
| page table | 8 bytes a page of the run's layout (the file page that holds it, its CRC) | `Snapshot.merge` |
| thing block, row block, offsets block | 128 things, 128 rows of a property, 128 offsets | `Store.tb` |
| run format | 9; runs of formats 5 to 8 and the snapshots of formats 1 to 4 (`<group>.snap`) are set aside at open, the journal replayed, and the first merge removes them | `Snapshot.format` |
| journal format | 2; a journal of format 1 is converted once at open | `Journal.format`, `Journal.convert` |

## Memory and the cache

| what | limit or default | where |
|---|---|---|
| the cache | 1 GiB (65,536 pages) for the whole process | `Pages.capacity`, `set_cache` |
| smallest cache | 16 pages (256 KiB): `set_cache` rounds below up | `Pages.set_capacity` |
| S3-FIFO's small queue | a tenth of the cache | `Pages.make_room` |
| ghost queue | as many keys as the cache has pages | `Pages.make_room` |
| a page's counter | 2 bits (0 to 3) | `Pages.touch` |
| pages in memory | under 1.25 times the cache: a full collection after each quarter of the cache evicted (256 pages, 4 MiB, at least) | `Pages.room` |
| a run read whole at open | when its pages fit in the cache | `Snapshot.check_and_build` |
| a larger run's tables read at open | when their pages fit in the room the cache has left; read in the file's order, up to 64 file pages (1 MiB) a read, by up to 4 domains from 64 pages | `Snapshot.check_and_build` |
| a merge | the cache, at most 2 page buffers for each of the 18 streams of the pass by property (11 measured), 25 bytes a page of the new run's layout, the block being coded, and the new run's text hash table (8 bytes a text) | [theory](theory.md#8-merges-written-to-a-file) |
| a large group | the caller's list of operations (72 bytes an `Add` and its value: 883 MB for 9.4 M), 14 bytes a fact in the group's order and 12 by property (Bigarrays), the radix sort's room for its largest property on each of 2 domains, and the receipt (a pair a new thing), the group's journal coding (21.6 MB at 9.4 M facts, built in memory, then written by pieces of 1 MiB): about 1.5 GB at the peak of a load of 10 M facts in two groups, of which 0.88 GB is the caller's list | measured ([benchmarks](benchmarks.md#the-load-in-parallel-and-without-copies-2026-11-08-at-10-million-facts)) |
| the delta | about 170 bytes a change, until the next merge | measured |
| the runs | about 5.4 bytes a fact at 10 M facts (the bench's data), read through the cache; 17 bytes a page of a run's layout for the cache's tables | measured |
| recovery | each segment through a window of 4 MiB; a frame longer than the window is checked by pieces and read whole only to replay its groups; a frame that does not check is read whole from its offset to the segment's end, to decide torn or damaged | `Journal.window`, `Journal.scan` |
| `verify` | the same window; every frame decoded, a longer one read whole | `Journal.read` |

## Questions

| what | limit or default | where |
|---|---|---|
| variables | at most 64, the wire's bound (below); the planner's estimates keep the bound variables in the bits of an `int`, 0 to 62: the 64th is placed by a flag of its own and estimated as unbound | `Query.order` |
| the order of the variables | the best order for its estimated work, by a dynamic program over the subsets of the variables that are neither a thing's field nor a constant's (those have a known place), for up to 12 of them ($n 2^{n-1}$ steps); greedy beyond | `Query.order`, `Query.dp_max` |
| parallel questions | when the first variable has 20,000 candidates or more | `Query.parallel_min` |
| domains of a question | the machine's recommended count, at most 8 | `Query.domains` |
| slices | $\min(\text{candidates}, 16 \times \text{domains})$, taken in turn from a shared counter | `Query.fold` |
| the leapfrog of a level | the slices among a variable's first 62 patterns whose count is at most 8 times the source's; its other patterns are checked one by one | `Query.fold` |
| the property of a pattern | a constant: no variable in the property position | `Query.pattern` |
| Sort, Limit, After | keys: columns of the select, one a column at most; Limit 1 to 100,000 rows a page (0 on the wire: none), plus the copies of its last row; After needs Sort and a value of its type for every column, else `invalid` | `Top.check`, `Top.max_limit` |
| Prefix | 1 to 1,024 bytes; a text variable that a pattern gives as its value | `Ask.max_prefix` |
| Not, Or, And, In | Not and And: 1 to 4 patterns and conditions; Or: 2 to 4 alternatives; In: at most 100,000 values (a page's rows at most: a page's ids go back in one question); at most 64 operators and their items in a question, and its Ors at most 64 questions to ask (the product of their alternatives); no Not or Or inside Not and Or | `Ask.compile`, `Ask.max_in`, `Ask.max_operators`, `Ask.max_conjunctions` |
| a question's work at the server | 1,000,000,000 candidates of its join a domain, its Nots' own questions together counted against it: past it, `too_large` ("the question passed the server's budget"); a watch past it at a frame ends with `too_large`; a program reading in its own memory has none | `Answer.question_budget`, `Query.Over_budget` |
| the heap path | a buffer of at most $\max(64, 2k)$ rows a domain before it is sorted and cut back to $k$ | `Top.push` |
| the index path | the first key an int, a date, money, a link or a text that a pattern gives as its value; windows of $2k$, $4k$, ... facts (a text's: the next texts in byte order, merged over the runs and the delta; the heap answers when the delta holds more values of the property than the estimate); a budget of the planner's estimate of the question (`Query.estimate`), past which the heap path answers; taken when the estimate is over $4k$ | `Top.give` |

## Files and the platform

| what | limit or default | where |
|---|---|---|
| processes | one engine per database: an exclusive `lockf` lock on `DIR/lock`, kept until close or death; inside one process, a table of the held locks keyed by the lock file's device and inode, so every path to the directory is one database | `Disk.real.lock` |
| `DIR/cepheus` | 37 bytes: 17 of magic, 16 of id, 4 of CRC | `Engine.read_meta` |
| file descriptors | one for the journal's current segment, one for each run file a live view holds (closed when no view holds the run any longer and the garbage collector frees it) | `Snapshot.check_and_build` |
| run files | 64-bit little-endian machines (the in-memory layout); the journal is portable | [formats](formats.md) |
| durability | relies on `fsync` meaning durable, for files and for directories (Linux and its usual file systems) | [operations](operations.md#disks) |
| OCaml | 5 (domains), with `unix` and `threads`, and its C compiler for `src/crc32c_stubs.c` | `src/dune` |
| processor | x86-64 with SSE4.2 (part of the x86-64-v2 level; Intel since Nehalem, 2008, AMD since Bulldozer, 2011), or arm64 with the CRC32 instructions (optional in ARMv8.0, required from ARMv8.1), on Linux or macOS; another one is refused when the program starts, another architecture does not build | `src/crc32c_stubs.c` |

## The server

| what | limit or default | where |
|---|---|---|
| a frame | at most 16 MiB of body (a length over it is answered `too_large` and the connection closes before the body is read); a header of 10 bytes | `Wire.max_frame`, `Wire.header` |
| writes in flight a connection | 1,024 (stated in Welcome); at the limit the server stops reading the socket | `Core.create ~max_inflight` |
| a Find's reply | frames of about 1 MiB of rows (all but the last with the flag more) | `Core.chunk` |
| variables of a question over the wire | 64 | `Wire.get_query` |
| a session's receipts | at most 4,096; forgotten an hour after the session's last write | `Sessions.max_receipts`, `Sessions.expiry_ms` |
| the session checkpoint | written every second while writes come, and at stop | `Net.checkpoint` |
| tokens.toml | read again within a second of a change | `Net.serve`'s ticker |
| a token | 32 random bytes, `cph_` and 43 characters of base64url; at most 256 characters are looked at | `Tokens.generate`, `Tokens.check` |
| I/O domains | `[clients] domains`, 1 to 64; default $\min(4, \text{cores} / 2)$ | `Config.default_domains` |
| the page cache | `[storage] cache`, default 1 GiB | `Config.of_toml` |
| the Unix socket | `.s.cepheus.PORT`, PORT the port of `listen` or 7400 | `Config.socket_name` |
| peers | exactly one in this version | `Config.of_toml` |
| TLS | 1.3 only; certificates: ECDSA P-256, the CA valid 3,650 days, the others 825 | `server/tls_stubs.c`, `bin/main.ml` |
| the connections' threads | one a connection (and one more while it has writes in flight) | `Net.connection` |
| a local reader's queue | 64 MiB of frames not yet sent; past it the reader is cut off and follows again | `Follow.max_behind` |
| descriptors a message | 64 (a database with more runs than that cannot be followed; a database has at most 16 plus one a level) | `Fdpass.max_fds` |
| the visibility page | 4 KiB a database (`/dev/shm/cepheus-ID.visible`), the number in its first 8 bytes | `Fdpass.page_size`, `Follow.page_path` |
| a local reader's page cache | 256 MiB, set for the process when it follows its first database (`Client.local_cache`) | `Client.follow` |
| a follow stream's frames | the writer's frame, in wire frames of at most 1 MiB of groups (the flag `more`) | `Net.piece` |
| connections | `[clients] max_connections`, 1 to 65,536; default 512; over it a new connection is closed at its accept (`too_many_connections` over the Unix socket) | `Config.default_max_connections`, `Net.serve` |
| an idle connection | `[clients] idle_timeout` seconds, 0 to 604,800 (0: no limit); default 600: a whole request within it from the accept (the TLS handshake included) and from the previous request, and what the server sends taken within it | `Config.default_idle_timeout`, `Net.timeouts` |
| a client's handshake | 5 s for connect, TLS and Hello (and a follow stream's Follow and Start), then the socket waits as long as it must; past it the attempt is given up as broken and tried again within the retry budget | `Client.handshake_timeout` |
| a client's retry budget | 30 s of tries to connect again after a broken connection; then `unreachable` (a write in flight was applied once or not at all) | `Client.retry_budget` |

## The file vault

| what | limit or default | where |
|---|---|---|
| a chunk | 16 KiB to 256 KiB, about 73 KiB on average (FastCDC, normal size 64 KiB); the last of a file shorter | `Chunker.min_size`, `normal`, `max_size` |
| a node | 1,024 children at most (about 42 KB) | `Vault.fanout` |
| a pack | closed when its next record would pass 64 MiB | `Vault.pack_limit` |
| packs open for reading | 64 at once; past it, those not being read are closed | `Vault.max_open` |
| decoded nodes and chunks kept | 96 MiB in all, a third of it for nodes (CLOCK each) | `Vault.open_ ?cache` |
| compression | kept when it saves at least 1/32 of a chunk; warm LZ4 (acceleration 1), cold Zstandard level 9 | `Vault.encode`, `Vault.zstd_level` |
| a Zstandard frame's window | 1 MiB at most (a frame that asks for more is refused) | `vault_stubs.c` |
| a file | 1 TiB (2^40 bytes) through the server | `Files.max_size` |
| files being put at once | 4 a connection | `Files.max_puts` |
| a file's name, its type | 4,096 bytes, 255 bytes | `Files.max_name`, `Files.max_type` |
| a Put's pieces, a Load's frames | 1 MiB each (the client's); a frame 16 MiB at most | `Client.piece`, `Core.chunk`, `Wire.max_frame` |
| the index in memory | about 100 bytes a record | `Vault.index` |
| the master key | 32 bytes in `vault.key`, mode 0600 (refused if others may read it, or if it is a link) | `Files.master_file` |

## Measurement tools

| what | value | where |
|---|---|---|
| `Histogram` | exact below 256 µs, then 128 buckets per power of two: every percentile within 1/128 (0.8 %); 3,584 counters | `src/histogram.ml` |
| the simulated disk's sector | 512 bytes, the unit of loss and of tearing | `Sim_disk.sector` |
| benchmark runs | 21 (`RUNS`), median and its 95 % interval $[x(6), x(16)]$, coverage 97.3 % | `bench/stats.ml` |
