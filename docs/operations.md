# Operations

## Files

```
DIR/cepheus                       the database's id (16 random bytes) and format, written once, atomically, with a CRC
DIR/lock                          held (lockf) while the database is open: one process at a time
DIR/closed                        left by a clean close (everything durable), removed by the next open
DIR/journal/NNNNNNNNNNNNNNNNNNNN.seg   segments named by their first group, 64 MB each, only appended to
DIR/snapshots/LO-HI.run           the runs (levels of the LSM tree): the changes of groups LO+1..HI on top of the
                                  state at LO (20 digits each); the chain from 0 to the newest group is the base, and
                                  the newest bottom run outside it (LO = 0) is kept as a fallback
DIR/snapshots/LO-HI.run.tmp       a merge being written (removed at open if a crash interrupted it)
```

The journal is the truth: runs are caches that can always be rebuilt. Byte layouts: [formats](formats.md).

## Opening and recovery

`Cepheus.open_ DIR` creates the directory and its files if they are missing, else:

1. takes the lock (`Busy` if another process has it);
2. reads the id; if `closed` is there (the last process closed cleanly), removes it; else forces the database's
   directory;
3. removes the files of merges a crash interrupted (`.tmp`);
4. takes the chain of runs from 0 that reaches the newest group with the fewest runs, and checks each (header CRC,
   checksum table, rank tables, the order and bounds of every table; a page's CRC as it is read); a run that does not
   check is set aside and noted (`Cepheus.notes`), and the choice is made again without it;
5. after a crash (no `closed`), writes the newest frame of the journal again and forces the newest segment and the
   journal's directory (a process killed before its fsync left them in the page cache; after a failed fsync the
   page cache may hold bytes the disk does not, G13); then reads the journal from the newest run's position: checks
   every frame, applies every group, and merges into a new run when the changes pass the threshold or the group is a
   large one, as the writer would have; a journal that ends before the newest run's group is damage;
6. at the first frame that does not check: a torn tail is cut (truncate, fsync); damage stops the open with
   `Damaged "file: what, at which offset"` (the merges of the replay before it may have written a run of the
   groups before the damage);
7. a frame whose trailer was torn while its header and body are intact is kept, and its trailer rebuilt.

Recovery time is the runs' check plus the replay of the groups after the newest one. Every merge writes a run, so
the replay is at most a merge threshold of changes (and the groups written while the last merge ran); `Cepheus.snapshot`
merges now, before a planned stop for example.

**When recovery says `Damaged`.** Durable data changed: a disk fault, a mishandled file, a segment missing in the
middle. Do not delete files. Copy the directory aside; run `Cepheus.verify` on the copy for the full list; restore the
database from a backup or (later) a replica. The message names the segment and the offset of the first bad frame. If
and only if you know the damaged part was never confirmed (for example, the frame is the newest one and the machine
lost power while writing it), the tail can be cut by hand at that offset (`truncate -s OFFSET SEGMENT`): this is a
human decision, never taken by Cepheus.

**When a write returns `Io`.** The disk failed during a write or an fsync. The database has stopped: every later write
fails. Cepheus has already cut the journal back to its last durable frame, so the failed writes are not in it (if
that cut failed too, stderr says so, and the failed writes may or may not come back at the reopen). Look at the
system log for the disk's error, then close the database and reopen it; recovery starts from the journal and writes
its newest frame again before trusting it. Cepheus never retries an fsync blindly (Rebello et al. 2020): after a
failed one, Linux has marked the pages clean, and a second fsync would succeed without writing them. A file system
that turned read-only after the error (ext4, Btrfs) or shut down (XFS) refuses the reopen until it is repaired.

## Backup and restore

Segments are only appended to and never rewritten, and snapshots are written beside and renamed, so a consistent copy
needs no stop:

1. copy `DIR/cepheus`;
2. copy the segments in the order of their names (a segment being written may be copied with a torn end: recovery of
   the copy cuts it; every group confirmed before the copy of that segment started is in the copy);
3. optionally copy the newest snapshot (it makes the restore faster; without it, the copy replays the whole journal).

To restore: put the files in a new directory and open it. Then verify the copy: `Cepheus.verify` on it, and compare
`Cepheus.group (Cepheus.view db)` with what you expect. A backup that was never opened and verified is not a backup.

## Verification (scrubbing)

`Cepheus.verify DIR` on a closed database reads every segment from the start and checks every frame, every trailer and
every group number: it returns the number of groups or `Damaged`. Run it regularly on databases and on backups: it is
the only check that reads the old segments, which an open does not read when a snapshot covers them.

## Memory

A database's base (its facts merged and sorted, about 31 bytes a fact) is read in pages of 16 KiB through one cache
for the process, `Cepheus.set_cache bytes` (1 GiB by default). A snapshot that fits in the cache is read whole at open,
every page checked; a larger one is read page by page as questions need it, each page checked against its CRC when it
arrives. Pages in memory stay under 1.25 times the cache: a full collection runs after each quarter of the cache has
been evicted, so that the evicted pages go back to the system. Measured at 10 M facts (snapshot 245 MB): with the
whole base in the cache, 278 MB resident after open; with a 32 MB cache under a 128 MB cap, 64 MB after open and a
peak of 79 to 105 MB through Q1 to Q5 (benchmarks, Larger than memory).

Besides the base: about 170 bytes for each change since the last merge. A merge starts in the background when the
changes pass max(200,000, n/16); it streams the new base into its file and needs only the cache, a few page buffers
and 21 bytes a page of the new base (theory, section 8): with the whole base in the cache, the cache holds the old
and the new base during the merge (twice the base, if the cache is large enough), and the old one leaves it at the
switch. Measured at 10 M facts: write runs at 256 clients with their merges peak at 1.0 to 1.3 GB (1.8 to 3.0 GB when
merges were built in memory); with a 32 MB cache, a merge of the whole 245 MB base runs in a process capped at 128 MB
(peak 99 MB).

## Disk space and merges

The runs are the levels of an LSM tree (theory, section 9): the delta is merged once it holds 200,000 changes, and
level l holds at most 200,000 x 4^l rows (800,000, 3.2 M, 12.8 M, ...). A merge takes the delta and the newest runs
down to the first level that can hold them all, writes one run there (about 25 bytes a fact), forces it, renames it,
and then removes the runs it replaced; the newest bottom run outside the chain is kept as a fallback. A removed
file's space returns only when no view reads it any longer (the file stays open until the garbage collector frees its
run). During a full merge (`snapshot`) the directory holds the base twice and the fallback: budget about three times
the base for `snapshots/`.

A fact is written about (T + 1) / 2 = 2.5 times per level it crosses (T = 4), against up to 17 times with the one level
before; at 10 M facts, three levels. While clients write, a merge forces its file every 8 MiB, so that the journal's
fsyncs, which every write waits for, never queue behind hundreds of MB of a merge's dirty pages; a merge nobody waits
beside (`snapshot`, recovery) forces once, at the end.

A large group (20,000 changes and more, all additions: a load) is merged into a run as it is written, from its facts
sorted in arrays, with no per-fact index update: write a load as a few large groups, not as many small ones. Its
receipt lists every new thing; read `receipt.things` once into a table rather than calling `thing` for each (a walk of
the list each time).

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
