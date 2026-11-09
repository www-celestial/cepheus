# Operations

Running a database: its files, what an open does, what to do when it reports damage or a disk error, backups,
verification, memory and disk space, and the tools of the repository.

## Files

```
DIR/cepheus                       the database's id (16 random bytes) and format, written once, atomically, with a CRC
DIR/lock                          held (lockf) while the database is open: one process at a time
DIR/closed                        left by a clean close (everything durable), removed by the next open
DIR/journal/NNNNNNNNNNNNNNNNNNNN.seg   segments named by their first group, 64 MB each, only appended to
DIR/snapshots/LO-HI.run           the runs (levels of the LSM tree): the changes of groups LO+1..HI on top of the
                                  state at LO (20 digits each); the chain from 0 to the newest group is the base, and
                                  nothing else is kept (the journal rebuilds any run)
DIR/snapshots/LO-HI.run.tmp       a merge being written (removed at open if a crash interrupted it)
```

The journal is the truth: runs are caches that can always be rebuilt. Byte layouts: [formats](formats.md).

## Opening and recovery

`Cepheus.open_ DIR` creates the directory and its files if they are missing, else:

1. takes the lock (`Busy` if another process has it);
2. reads the id; if `closed` is there (the last process closed cleanly), removes it; else forces the database's
   directory;
3. converts a journal of format 1 to format 2, once (each segment written beside, forced, renamed over the old one;
   a crash in the middle leaves each segment whole, and the next open goes on), and removes the files of merges a
   crash interrupted (`.tmp`);
4. takes the chain of runs from 0 that reaches the newest group with the fewest runs, and checks each (header CRC,
   page table, rank tables, the order and bounds of every table; a page's CRC as it is read); a run that does not
   check, or of an earlier format (5 and 6: "an earlier format (6), the journal is replayed"), is set aside and noted
   (`Cepheus.notes`), and the choice is made again without it;
5. after a crash (no `closed`), writes the newest frame of the journal again and forces the newest segment and the
   journal's directory (a process killed before its fsync left them in the page cache; after a failed fsync the
   page cache may hold bytes the disk does not, G13); then reads the journal from the newest run's position: checks
   every frame, applies every group, and merges into a new run when the changes pass the threshold or the group is a
   large one, as the writer would have; a journal that ends before the newest run's group is damage. The journal is
   read through a window of 4 MiB: a frame whose groups the runs already hold is checked by its CRC, piece by piece,
   and not decoded; a longer frame to replay is read whole (the memory of its group, as when it was written);
6. at the first frame that does not check: a torn tail is cut (truncate, fsync); damage stops the open with
   `Damaged "file: what, at which offset"` (the merges of the replay before it may have written a run of the
   groups before the damage);
7. a frame whose trailer was torn while its header and body are intact is kept, and its trailer rebuilt; a newest
   segment torn at its creation (its header does not check and it holds no frame) is removed;
8. a new database (no group yet) gets group 1, which describes the five system properties (a database made before
   `cepheus/rule` existed lacks the description of that one: its rules work all the same).

Recovery time is the runs' check plus the replay of the groups after the newest one. Every merge writes a run, so
the replay is at most a merge threshold of changes (and the groups written while the last merge ran); `Cepheus.snapshot`
merges now, before a planned stop for example.

## When recovery says `Damaged`

Durable data changed: a disk fault, a mishandled file, a segment missing in the
middle. Do not delete files. Copy the directory aside; run `Cepheus.verify` on the copy for the full list; restore the
database from a backup or (later) a replica. The message names the segment and the offset of the first bad frame. If
and only if you know the damaged part was never confirmed (for example, the frame is the newest one and the machine
lost power while writing it), the tail can be cut by hand at that offset (`truncate -s OFFSET SEGMENT`): this is a
human decision, never taken by Cepheus.

## When a write returns `Io`

The disk failed during a write or an fsync of the journal. The database has stopped: every later write fails with the
same error, and nothing more is confirmed (G10). Cepheus has already cut the journal back to its last durable frame
(truncated, forced), so the failed writes are not in it; if that cut failed too, stderr says so (`cepheus: the
journal could not be cut back after a failed write: ...`), and the failed writes may or may not come back at the
reopen, and once seen they stay (G13). Look at the system log for the disk's error, fix the disk (space, permissions,
hardware), then close the database and open it again: recovery starts from the journal and writes its newest frame
again before forcing it, so a frame that is only in the page cache reaches the disk before anything rests on it
(G13). No reboot is needed. Cepheus never retries an fsync blindly (Rebello et al. 2020): after a failed one, Linux
has marked the pages clean, and a second fsync would succeed without writing them. A file system that turned
read-only after the error (ext4, Btrfs) or shut down (XFS) refuses the reopen until it is repaired.

A disk error while a merge writes its run file does not stop the database: the file is removed, stderr says so, and
the merge is tried again once the delta has grown by another threshold; a large group whose run file fails returns
`Io` for that group only. Every message: [errors](errors.md#io-the-disk-failed).

## Backup and restore

Segments are only appended to and never rewritten, and run files are written beside and renamed, so a consistent copy
needs no stop:

1. copy `DIR/cepheus`;
2. optionally, copy the run files of `DIR/snapshots/` (they make the restore faster; without them, the copy replays the
   whole journal). A merge may remove runs while you copy: copy what is there, and the copy's open takes the chain its
   names allow (a missing run only means a longer replay). Copy them **before** the segments: a run is named only once
   its groups are durable in the journal, so the segments copied after it hold them; a run copied after the segments
   may be newer than their end, and the copy would refuse to open (`the journal ends at group G, before the snapshot
   of group S`);
3. copy the segments of `DIR/journal/` in the order of their names. A segment being written may be copied with a torn
   end, which the copy's recovery cuts; every group confirmed before the copy of its segment started is in the copy.

To restore: put the files in a new directory and open it (its recovery cuts a torn end), compare
`Cepheus.group (Cepheus.view db)` with what you expect, close it, and run `Cepheus.verify` on it. A backup that was
never opened and verified is not a backup.

## Verification (scrubbing)

`Cepheus.verify DIR` on a closed database reads every segment from the start and checks every frame, every trailer and
every group number: it returns the number of groups or `Damaged`. Run it regularly on databases and on backups: it is
the only check that decodes the old segments, which an open does not read when runs cover them.

## Memory

A database's runs (its facts merged, sorted and coded, about 5.4 bytes a fact at 10 M facts) are read in pages of 16
KiB through one cache
for the process, `Cepheus.set_cache bytes` (1 GiB by default). A run that fits in the cache is read whole at open,
every page checked; a larger one is read page by page as questions need it, each page checked against its CRC when it
arrives. Pages in memory stay under 1.25 times the cache: a full collection runs after each quarter of the cache has
been evicted, so that the evicted pages go back to the system. Measured at 10 M facts (one run of 245 MB, the one-level
format of milestone 2; the levels' format holds the same rows): with the whole base in the cache, 278 MB resident after open; with a 32 MB cache under a 128 MB cap, 64 MB after open and a
peak of 79 to 105 MB through Q1 to Q5 (benchmarks, Larger than memory). With format 7 the same base is a run of 54.4 MB
and the process holds 66 MB after its open with the 1 GiB cache ([benchmarks](benchmarks.md#compressed-runs-and-journal-2026-11-09-at-10-million-facts)).

Besides the runs: about 170 bytes for each change since the last merge. A merge starts in the background when the
changes pass 200,000; it streams the new run into its file and needs only the cache, a few page buffers and 21 bytes a
page of the new run (theory, section 8): with everything in the cache, the cache holds the runs a merge reads and the
one it writes, and the replaced ones leave it at the switch; a full merge (`snapshot`) holds the base twice for a
while. Measured at 10 M facts: write runs at 256 clients with their merges peak at 762 MB [723, 1,300] (1,040 MB with
the one level, 2,095 MB when merges were built in memory); with a 32 MB cache, a merge of the whole 245 MB base runs in
a process capped at 128 MB (peak 99 MB). A large group needs its operations (the caller's list: 883 MB for 9.4 M
additions), 26 bytes a fact of compact arrays and its receipt: 1.46 GB at the peak of a load of 10 M facts in two
groups (2.6 GB before 2026-11-08); its frame is written by pieces, never built whole. A caller that drops its list
once `write` has it lets the collector reclaim it while the group is merged.

## Disk space and merges

The runs are the levels of an LSM tree (theory, section 9): the delta is merged once it holds 200,000 changes, and
level l holds at most 200,000 x 4^l rows (800,000, 3.2 M, 12.8 M, ...). A merge takes the delta and the newest runs
down to the first level that can hold them all, writes one run there (about 5 bytes a fact), forces it, renames it,
and then removes the runs it replaced, and any other run outside the chain. No run is kept aside: should the newest run
be found damaged at an open, it is set aside and its groups are replayed from the journal (a slower open, nothing
lost). A removed file's space returns only when no view reads it any longer (the file stays open until the garbage
collector frees its run). During a full merge (`snapshot`) the directory holds the base twice, the old and the new:
budget about twice the base for `snapshots/` while it runs, once the base after it.

A fact is written about (T + 1) / 2 = 2.5 times per level it crosses (T = 4), against up to 17 times with the one level
before; at 10 M facts, three levels. While clients write, a merge forces its file every 8 MiB, so that the journal's
fsyncs, which every write waits for, never queue behind hundreds of MB of a merge's dirty pages; a merge nobody waits
beside (`snapshot`, recovery) forces once, at the end.

A large group (20,000 operations and more, all additions: a load) is merged into a run as it is written, from its
facts sorted in arrays on several domains, with no per-fact index update: write a load as a few large groups, not as
many small ones; a group whose facts come in thing order (each thing's facts together, as a loader writes rows) needs
no sorting by thing. A group whose encoding passes 256 MiB is refused (`Invalid`) before any merge: split a larger load
into groups below it (9.4 M additions encode to about 94 MB). Several large groups sent at once by several threads are written in frames of their own, each
within the limit ([limits](limits.md#writes)). Its
receipt lists every new thing; read `receipt.things` once into a table rather than calling `thing` for each (a walk of
the list each time). A load leaves a few runs (at 10 M facts in two groups: the clients' run and the follows' run);
questions that join across them read both (Q3 and Q4 about 40 % slower than on one run, benchmarks): after a load,
`snapshot` puts the base in one run (1.3 to 6.5 s at 10 M facts).

## Disks

Cepheus relies on `fsync` meaning durable. Consumer disks may acknowledge writes they keep in a volatile cache; use
disks with power-loss protection for data that matters. Durable writes run at the disk's fsync rate times the frame
size: on the test machine's SATA SSD about 340 fsync a second.

On btrfs (the test machine), a 9,000-byte frame and its fsync, 10 s a round, 3 rounds: appended, as the journal
does, p99 19.6 to 152.6 ms (15.7 to 27.7 ms in a directory marked NOCOW, `chattr +C`); written over zeros written and
forced beforehand, p99 14.3 to 19.3 ms (7.7 to 15.7 NOCOW), and 14 % more fsyncs a second (median of 5 rounds,
higher in all 5). The journal does not preallocate yet (it needs a segment made ahead in the background, and recovery
that zeroes a torn tail instead of cutting it). The long stalls (fsyncs of 80 to 450 ms, a few a minute) come in every
mode: they are the disk's.

## Tools

| tool | what it does | page |
|---|---|---|
| `dune build`, `dune test` | builds; runs the unit and property tests, the exhaustive enumeration, 200 seeds of the simulation, and every example of the documentation | [testing](testing.md) |
| `tools/test.sh` | every test in the release build, the slow ones too: `CEPHEUS_TMP` (scratch directory), `SEEDS` (300), `KILLS` (20), `BANK_SECONDS` (2), `SEAT_KILLS` (20), `SERVER_SEEDS` (200), `SERVER_KILLS` (20) | [testing](testing.md) |
| `tools/tlc.sh` | model-checks `spec/Journal.tla`, `spec/Merge.tla` and `spec/Seats.tla` with TLC, and checks that the naive sale breaks an invariant; `TLA2TOOLS` names `tla2tools.jar` | [testing](testing.md#model-checking) |
| `cepheus` (`bin/main.exe`) | the server and its commands: `serve`, `stop`, `status`, `token add/list/remove`, `cluster init/cert` | [server](server.md#commands) |
| `sbench.exe` | the server's benchmarks: `ping`, `get`, `clients`, `write`, `q`, `hs`, `check` | [server](server.md#speed-beside-postgresql) |
| `bench.exe` | the benchmarks: `load`, `read`, `write`, `merge`, `fsync`, `trace`, `cachesim`, `stats`, `cpu` | [benchmarks](benchmarks.md#commands) |
| `bench/pg/pg.sh` | PostgreSQL's side: `init`, `start`, `load`, `read`, `write`, `stop` | [benchmarks](benchmarks.md#commands) |
| `bench/sqlite/sqlite.sh` | SQLite's side: `load`, `read` | [benchmarks](benchmarks.md#commands) |
| `bench/sqlite/seats.py`, `bench/pg/pg.sh seats` | SQLite's and PostgreSQL's sides of the sale of seats | [case](case-seats.md#speed-beside-the-giants) |
