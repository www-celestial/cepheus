# Operations

## Files

```
DIR/cepheus                       the database's id (16 random bytes) and format, written once, atomically, with a CRC
DIR/lock                          held (lockf) while the database is open: one process at a time
DIR/journal/NNNNNNNNNNNNNNNNNNNN.seg   segments named by their first group, 64 MB each, only appended to
DIR/snapshots/NNNNNNNNNNNNNNNNNNNN.snap   the two newest snapshots, named by their last group
```

The journal is the truth: snapshots are caches that can always be rebuilt. Byte layouts: [formats](formats.md).

## Opening and recovery

`Cepheus.open_ DIR` creates the directory and its files if they are missing, else:

1. takes the lock (`Busy` if another process has it);
2. reads the id;
3. loads the newest snapshot that checks (header CRC, checksum table, a CRC per MiB, the order and bounds of every
   table); a snapshot that does not check is set aside and noted (`Cepheus.notes`), and the next older one is tried;
4. reads the journal from the snapshot's position: checks every frame, applies every group, compacting as needed;
5. at the first frame that does not check: a torn tail is cut (truncate, fsync); damage stops the open with
   `Damaged "file: what, at which offset"` and nothing is changed;
6. a frame whose trailer was torn while its header and body are intact is kept, and its trailer rebuilt.

Recovery time is the snapshot's check (about 0.47 s for 10 M facts on the test machine) plus the replay of the groups
after it. Take snapshots regularly (`Cepheus.snapshot`) to keep that short.

**When recovery says `Damaged`.** Durable data changed: a disk fault, a mishandled file, a segment missing in the
middle. Do not delete files. Copy the directory aside; run `Cepheus.verify` on the copy for the full list; restore the
database from a backup or (later) a replica. The message names the segment and the offset of the first bad frame. If
and only if you know the damaged part was never confirmed (for example, the frame is the newest one and the machine
lost power while writing it), the tail can be cut by hand at that offset (`truncate -s OFFSET SEGMENT`): this is a
human decision, never taken by Cepheus.

**When a write returns `Io`.** The disk failed during a write or an fsync. The database has stopped: every later write
fails. Close it and reopen it; recovery starts from the journal. Cepheus never retries an fsync (Rebello et al. 2020).

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

A database in memory costs about 31 bytes a fact (the columns, 22 bytes, plus the dictionary of texts and the offset
tables) and about 170 bytes for each change since the last merge; a merge starts in the background when the changes
pass max(200,000, n/16), and needs room for a second base while it runs (twice the columns for a moment). 10 M facts: 312 MB resident after open (measured). Larger than memory is the next step (design:
segments on disk read through Cepheus' own cache).

## Disks

Cepheus relies on `fsync` meaning durable. Consumer disks may acknowledge writes they keep in a volatile cache; use
disks with power-loss protection for data that matters. Durable writes run at the disk's fsync rate times the frame
size: on the test machine's SATA SSD about 340 fsync a second.
