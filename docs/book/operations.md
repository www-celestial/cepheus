# Operations

Running a database: its files, what an open does, what to do when it reports damage or a disk error, backups,
verification, memory and disk space, import and export, and the tools of the repository.

## Files

```
DIR/cepheus                       the database's id (16 random bytes) and format, written once, atomically, with a CRC
DIR/lock                          held (lockf) while the database is open: one process at a time
DIR/closed                        left by a clean close (everything durable), removed by the next open
DIR/shared                        the database is opened by a server, whose commit buffer forces its journal
DIR/journal/NNNNNNNNNNNNNNNNNNNN.seg   segments named by their first group, 64 MB each, only appended to
DIR/snapshots/LO-HI.run           the runs (levels of the LSM tree): the changes of groups LO+1..HI on top of the
                                  state at LO (20 digits each); the chain from 0 to the newest group is the base, and
                                  nothing else is kept (the journal rebuilds any run)
DIR/snapshots/LO-HI.run.tmp       a merge being written (removed at open if a crash interrupted it)
```

The journal is the truth: runs are caches that can always be rebuilt. Byte layouts: [formats](formats.md). Every file
is made 0600 and every folder 0700, whatever the process's umask: they hold the facts in the clear (`Disk.real`).

## Opening and recovery

`Cepheus.open_ DIR` creates the directory and its files if they are missing, else:

1. takes the lock (`Busy` if another process has it);
2. reads the id; if `closed` is there (the last process closed cleanly), removes it; else forces the database's
   directory. If `shared` is there and `closed` is not, an open in a program's own process is refused (`Busy`: [a
   database of a server](#a-database-of-a-server)); after a clean close it removes `shared` and goes on. The
   directory is forced after the removal of `closed` too when `shared` is there, so that no power loss brings it back;
3. converts a journal of format 1 to format 2, once (each segment written beside, forced, renamed over the old one;
   a crash in the middle leaves each segment whole, and the next open goes on), and removes the files of merges a
   crash interrupted (`.tmp`);
4. takes the chain of runs from 0 that reaches the newest group with the fewest runs, and checks each (header CRC,
   page table, rank tables, the order and bounds of every table; a page's CRC as it is read); a run that does not
   check, or of an earlier format (5 and 6: "an earlier format (6), the journal is replayed"), is set aside and noted
   (`Cepheus.notes`), and the choice is made again without it;
5. opened by a server, first writes again into the journal the frames its commit buffer holds for this database
   ([below](#a-database-of-a-server)), and forces them;
6. after a crash (no `closed`), writes the newest frame of the journal again and forces the newest segment and the
   journal's directory (a process killed before its fsync left them in the page cache; after a failed fsync the
   page cache may hold bytes the disk does not, G13); then reads the journal from the newest run's position: checks
   every frame, applies every group, and merges into a new run when the changes pass the threshold or the group is a
   large one, as the writer would have; a journal that ends before the newest run's group is damage. The journal is
   read through a window of 4 MiB: a frame whose groups the runs already hold is checked by its CRC, piece by piece,
   and not decoded; a longer frame to replay is read whole (the memory of its group, as when it was written);
7. at the first frame that does not check: a torn tail is cut (truncate, fsync); damage stops the open with
   `Damaged "file: what, at which offset"` (the merges of the replay before it may have written a run of the
   groups before the damage);
8. a frame whose trailer was torn while its header and body are intact is kept, and its trailer rebuilt; a newest
   segment torn at its creation (no longer than its header, which does not check, and no run resumes in it) is
   removed; a header that does not check in a segment that holds more, or where the newest run resumes, is damage;
9. a new database (no group yet) gets group 1, which describes the five system properties (a database made before
   `cepheus/rule` existed lacks the description of that one: its rules work all the same).

Recovery time is the runs' check plus the replay of the groups after the newest one. Every merge writes a run, so
the replay is at most a merge threshold of changes (and the groups written while the last merge ran); `Cepheus.snapshot`
merges now, before a planned stop for example.

## A database of a server

A server forces the journals of all its databases with one fsync a round, through its commit buffer
(`DATA/server.wal.1` and `.2`: [the server](server.md#many-databases-one-fsync-the-commit-buffer)). Between two
checkpoints of a journal, its newest confirmed frames may be durable in the buffer alone: the journal holds them in
the page cache, and a power loss may lose them there. So:

- **The server writes them back at its start.** Before it opens its databases it reads the buffer; each database's
  open writes the buffer's frames for it again at their place in its journal and forces them; every frame of the
  journal before the last of them that the buffer does not hold must check (it was forced: else `Damaged`); the
  journal's own rule takes what follows. Then the buffer is emptied. A start refuses (`Damaged`, naming the ids) when
  the buffer holds frames of a database that `cluster.toml` no longer lists: add it back, start, stop, and remove it.
- **A program's own process refuses the database after a crash.** `Cepheus.open_` of a database that has `shared` and
  no `closed` returns `Busy` (`DIR was written through a server's commit buffer and not closed cleanly: ...`): it
  would cut the confirmed frames as a torn tail, or take their holes for damage. Start the server on its data
  directory and stop it: the database is then closed cleanly, and opens anywhere. After a clean close, the open
  removes `shared` and the database is an ordinary one again.
- **Going back to an earlier version.** Versions before the commit buffer do not read `server.wal`. Stop the server
  cleanly first (a clean stop forces every journal and removes both files): the earlier version then opens every
  database as before. After a crash, start this version once and stop it before going back. If an earlier version
  opened a database after a crash anyway and wrote to it, this version's next start refuses that database
  (`Damaged`: `the frame at N is not the one the commit buffer holds for group G`) rather than write over the earlier
  version's frames; remove `DATA/server.wal.1` and `.2` only if you accept to lose the writes they held.
- **Backups** are as below: a copy reads the page cache, so the journal's copy holds every frame confirmed before the
  copy of its segment started. Leave `shared` out of the copy (or remove it): the copy is opened as an ordinary
  database.

## When recovery says `Damaged`

Durable data changed: a disk fault, a mishandled file, a segment missing in the middle. Do not delete files. Run
`cepheus verify DIR` for the full list (it changes nothing); restore the database from a backup (`cepheus restore
BACKUP DIR --replace`, which moves the damaged folder aside; after a crash it is refused while the server's commit
buffer holds frames of this database, [below](#backup-and-restore)), which can be taken on a replica ([backups from the
replica](server.md#backups-from-the-replica)), or promote its replica. The message names the segment and the offset of
the first bad frame. If and only if you know the damaged part was never confirmed (for example, the frame is the
newest one and the machine lost power while writing it), the tail can be cut by hand at that offset (`truncate -s
OFFSET SEGMENT`): this is a human decision, never taken by Cepheus.

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

`cepheus backup --config FILE DEST` copies every database of a running server ([production](production.md#backups)),
`cepheus restore SRC DIR` restores one ([the restore drill](production.md#the-restore-drill)). What they rest on:
segments are only appended to and never rewritten, and run files are written beside and renamed, so a consistent copy
needs no stop, in this order:

1. `DIR/cepheus`, and `DIR/epochs` if there is one (a replica's history of promotions);
2. the run files of `DIR/snapshots/`, each opened before the segments are listed. They make the restore faster
   (without them, the copy replays the whole journal). A merge may remove a run meanwhile: an opened file still reads,
   and a run removed before its open is only a longer replay (the copy's open takes the chain its names allow). They
   come **before** the segments: a run is named only once its groups are durable in the journal, so the segments
   copied after it hold them; a run copied after the segments may be newer than their end, and the copy would refuse
   to open (`the journal ends at group G, before the snapshot of group S`);
3. the segments of `DIR/journal/`, in the order of their names, each up to the size it had when it was opened. The
   newest one may be copied while a frame is being written: the first frame of its copy that does not check whole
   (header, body and trailer), when no frame that checks starts after it, is that frame, and the copy is cut there (a
   large group's header is written after its body, but its trailer after its header: a copy that ends where the file
   did never holds a trailer without its header); followed by a frame that checks, it is damage. Every group
   confirmed before the copy of its segment started is before that point: it was written whole before it was
   confirmed, and frames are appended one at a time. A frame being written shows its bytes as they are written: a
   frame is appended in one write, which a reader sees in order up to the size it reads, and a large group's header,
   written last into its place, reads as zeros until then. So a first frame that does not check while every byte of
   it is there (its header checks and the whole length it gives is there, or its header is there, not zeros, and does
   not check) is no frame being written: the live segment is read again ten times in a second (a header being written
   into its place is whole within microseconds), and a frame that stays so is damage (exit status 1), never cut;
4. `DIR/vault/`, after the journal: each pack and its index, then its `keys` (a fact names a file only once the
   file's records are forced, G22, so every file the copied journal cites is in the copied packs; a domain's key is
   forced before its first record, so the keys copied after the packs hold every key they need; the pack being
   written may end in a torn record, which the copy's open indexes up to its last whole one, as after a crash).

The copy leaves out `lock`, `closed`, `shared` and `sessions`. `cepheus backup` then checks it as `cepheus verify`
does, cuts it after its last whole frame, forces it and writes its `closed` marker: a backup is a database closed
cleanly, and a later `cepheus verify` of it takes any torn byte for damage. So the newest frame of a database left by a
process that died, whose trailer alone is broken (the crash rule keeps it: recovery writes the trailer again from the
frame's header), has its trailer written again in the copy first, as the next open would.

DEST is the user's own: a folder that other users may write is refused (they could plant names in it), as one that
belongs to another user. A backup removes there only what a backup that did not finish left, a folder of this user's
named `DATE.partial` (`2026-11-24T224915.partial`, or `...-2.partial`), never through a link: another program's
`movie.partial` stays. Its lock, `DEST/cepheus-backup.lock`, is opened as a file of this user's, never through a link.

`cepheus restore SRC DIR [--to-group N | --to-time T]` copies into `DIR.restoring`, in the same order, the runs whose
groups end at N or before and the segments up to the one that begins at N + 1 (kept as its header alone: a run of
group N may name it), ends the journal after group N (the frame that holds N, when later groups share it, is coded
again without them, at the same place, with the same first group), writes into `DIR/epochs` a new epoch from group
N + 1, above every epoch the source's history and a replaced database knew, opens the copy (its runs checked, the groups after the newest one replayed), closes it, checks it as
`cepheus verify` does, and renames it `DIR`; with `--replace`, a database already in `DIR` is first renamed
`DIR.before-restore-DATE` (`-2`, `-3` after it when a folder has that name: two restores in one second), never
removed nor renamed over another folder. It refuses a source or a target that a process holds open, a source written
through a server's commit buffer and not closed cleanly, and a target beside a commit buffer that a server's unclean
stop left (`DATA/server.wal.1` or `.2`, no server holding the data folder) when that buffer holds frames of the
database restored or of the one replaced, or does not read: the server's next start would write them into the
restored journal. A target that crashed while written through the buffer is replaced as it is (moved aside, never
read). `--to-time T` takes `YYYY-MM-DDTHH:MM` or `YYYY-MM-DDTHH:MM:SS` (a space for the `T`), exactly these digits, a
day of the calendar (leap years), hours 00 to 23, minutes and seconds 00 to 59, in the machine's local time (a time
its clocks skip at the change to summer time is refused) or in UTC with a final `Z`; anything else is refused, never
moved to another time. The exit status of both: 0 done, 1 damage found, 2 refused or failed; neither leaves a half
copy under its final name.

## Verification (scrubbing)

`cepheus verify DIR` checks a database's files as they are and changes nothing (it opens them read-only):

- every segment of the journal on its own (on up to 4 domains), so that a damaged one does not hide the others: its
  header, then every frame (its header's and body's CRCs, its trailer, its first group and count, the groups following
  one another), the groups of every frame up to 16 MiB decoded and numbered (a larger frame, a large load's, is checked
  by its CRCs: decoding it would take the memory of its group); the first damage of each segment named, with its
  offset, and the segments missing between them;
- every run, as an open checks it (its header, page table, rank and offset tables), and every page against its CRC
  (read through a cache of 256 MiB: the memory stays under it whatever the database's size);
- each run against the journal: its groups in the journal, its journal position the start of a frame;
- the vault's records, by their CRCs, without the master key: the keys' file, every record each pack's index names,
  the packs without an index up to their torn end.

The end of the newest segment is read by the database's state: closed cleanly, every byte must check; left by a
process that died, a torn frame with nothing written after it is a note (the next open cuts it), as a newest frame
whose trailer alone is broken (the next open writes it again); open in a server, the frame being written is not
checked, and a frame that does not check while every byte of it is there is read again for a second, then damage if
it stays so ([backup and restore](#backup-and-restore), point 3); a frame that does not check with a frame that checks
after it is damage, in every state. A database written through a server's commit buffer and not closed cleanly is
refused: start its server and stop it first. Exit status 0: whole (the last line names the group); 1: damage, one
`damaged:` line each; 2: not a database, unreadable, or refused. Run it on the backups (`cepheus backup` runs it on
each copy) and now and then on the live databases: it is the only check that reads the old segments and every page,
which an open does not read when runs cover them. `Cepheus.verify DIR`, the OCaml call, stays: it reads every frame of
a closed database's journal and returns the number of groups or `Damaged`.

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
level $l$ holds at most $200{,}000 \times 4^l$ rows (800,000, 3.2 M, 12.8 M, ...). A merge takes the delta and the newest runs
down to the first level that can hold them all, writes one run there (about 5 bytes a fact), forces it, renames it,
and then removes the runs it replaced, and any other run outside the chain. No run is kept aside: should the newest run
be found damaged at an open, it is set aside and its groups are replayed from the journal (a slower open, nothing
lost). A removed file's space returns only when no view reads it any longer (the file stays open until the garbage
collector frees its run, and closes it then). During a full merge (`snapshot`) the directory holds the base twice, the old and the new:
budget about twice the base for `snapshots/` while it runs, once the base after it.

A fact is written about $(T + 1) / 2 = 2.5$ times per level it crosses ($T = 4$), against up to 17 times with the one level
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

## Import and export

`cepheus import` loads the things of a kind from a file, `cepheus export` writes them out: to start from an existing
base (PostgreSQL, SQLite, a spreadsheet), for reports and audits, and to leave Cepheus. Both go through the server
with a token, as any program does, never by opening the files of a live database; the token is in `CEPHEUS_TOKEN`,
never on the command line (which every user of the machine can read): a right to write the database to import, to
read it to export.

```sh
cepheus import shop clients.csv --kind client --config /etc/cepheus/cluster.toml        # CSV with a header row
cepheus import shop invoices.jsonl --kind invoice --config /etc/cepheus/cluster.toml    # JSON lines
cepheus export shop --kind invoice --config /etc/cepheus/cluster.toml > invoices.jsonl
cepheus export shop --kind invoice --format csv --config /etc/cepheus/cluster.toml > invoices.csv
```

The kind is the program's: its fields are the properties `kind/Field` declared in the database (a Cesia program's
`cepheus.Connect` declares its kinds, [Cepheus from Cesia](cesia.md)), so a program connects once before its first
import. A column of the CSV header, or a key of JSON lines, names a field: the same name, or the one field whose name
differs only by its capitals (PostgreSQL's columns are in small letters: `email` is `Email`); `--map Col=Field` when
they differ, `--map Col=` to leave a column out. A column that names no field stops the import before it reads a row.

From PostgreSQL or SQLite, their own commands write the file:

```sh
psql -c "\copy (SELECT name AS \"Name\", city AS \"City\", email AS \"Email\" FROM client) TO 'clients.csv' WITH (FORMAT csv, HEADER true)"
sqlite3 -csv -header shop.db "SELECT name AS Name, city AS City, email AS Email FROM client" > clients.csv
cepheus import shop clients.csv --kind client --config /etc/cepheus/cluster.toml
```

### The files

**CSV** as RFC 4180 writes it (the IETF's description of comma-separated values): a header row, then one record a
row; a field that starts with a quote is quoted and may hold commas and line breaks, `""` inside it being a quote. A
quote anywhere else, or a character after a closing quote, is refused: it is a broken file, not data. Such a quote opens
nothing, so that its line alone is bad and `--skip-bad` reads the lines after it (RFC 4180's grammar: a field that does
not start with a quote holds none). PostgreSQL 18.6's `COPY` reads a quote inside a field as the start of a quoted
part instead: the lines `bob"x,2`, `carl,3` and `eve"y,5` load there as one row, its name `bobx,2`, `carl,3` and
`evey` joined by line breaks, its number 5, with no error (measured). A bad record that a quote at a field's start runs over several lines is named with its last line
too. A record ends at a line break outside quotes, LF or CR LF; blank lines are skipped as they are read (a file of
blank lines holds no memory); a UTF-8 byte order mark at the start (the three bytes EF BB BF that some editors write
first) is skipped. As in PostgreSQL's `COPY` (sql-copy.html: "a NULL is written as an
unquoted empty string, while an empty string data value is written with double quotes"), an unquoted empty field is no
value and `""` is the empty text. An export writes CR LF, as RFC 4180 does.

**JSON lines** as jsonlines.org describes them: one JSON object a line (RFC 8259), `{"Name": "Ada", "City": "Lyon"}`;
`null` or a key left out is no value. A key twice, a nested object, nesting deeper than 64, a bad escape, a lone
surrogate (half of a character in `\u` escapes) are refused.

A value is read by its field's type, exactly:

| type | CSV | JSON lines | export |
|---|---|---|---|
| `Int` | `-12` (63 bits) | a whole number | the same |
| `Float` | `2.5`, `1e-7`, `NaN`, `Infinity` | a number, `"NaN"`, `"Infinity"` | the shortest decimal that reads back as the same double |
| `Bool` | `true`, `false`, `t`, `f`, `1`, `0` | `true`, `false` | `true`, `false` |
| `Text` | UTF-8 without NUL | a string | the same |
| `Date` | `2026-11-24`, `2026-11-24T10:30:00Z`, `2026-11-24 10:30:00.123+01:00` (RFC 3339; no zone: UTC) | a string of the same | `2026-11-24T10:30:00.123Z` |
| `Money(s)` | `12.50`: at most `s` decimals, never through a float | a number of the same form | `12.50`, exactly `s` decimals |
| `Link` | the key of the thing linked (below) | the key, of the key's type | the key |
| many values | a JSON list in the field: `"[""red"",""blue""]"` | a list | a list |

A date is kept to the millisecond: finer digits (PostgreSQL's microseconds) are cut; one that its zone moves out of
the years 0 to 9999 in UTC (`0000-01-01T00:00:00+01:00`) is refused, since an export could not write it back. Money is read from its decimal
digits into minor units, so `12.505` for cents is refused and `0.1` is ten cents, never 0.1000000000000000055. A text
is checked as UTF-8 and a NUL byte refused (PostgreSQL refuses `0x00` in a text too); an export refuses a text that
holds one (CSV and JSON lines carry neither).

**Links.** A link is written as the key of the thing linked: a unique field of one value. By default the kind named
as the field in small letters, by its one unique field: `Client` is a client found by its `Email`. `--link
Client=client/Email` names the key, `--link Client=id` writes the things' ids instead (an export for an audit, an
import into the same database). The things linked must be in the database first: import the clients, then the
invoices, then their lines.

### What an import checks, and when it writes

The file is read twice. The first pass checks every row: the number of its fields, each value against its type, each
link found in the database, each unique value against the database and against the other rows of the file. A bad row
stops the import with its line (the line it starts at, counting the line breaks inside quotes) and the reason, and
**nothing is written**:

```text
cepheus: clients.csv line 1204: Email "ada@example.com" is on line 7 too; nothing was written
```

`--skip-bad` writes the good rows and lists the bad ones on stderr, each with its line. A failure that is no refusal
(the connection to the server lost, the disk) stops the import as well, at any point, naming the groups written; the
group whose answer was lost is named as such: it may be in the database, the one after those named. `--upsert` changes the thing
that a row's unique value finds rather than refusing it: the row's values replace its fields, an empty field leaves
one as it is, and a field of many values is refused (`Write` changes those); two rows of the file with one unique
value are refused even then, as PostgreSQL's `ON CONFLICT DO UPDATE` refuses to change a row twice.

The second pass reads the file again and writes it in groups of at most a million operations (15 MiB of request,
under the frame's 16 MiB), each taken by the large-group path of the database (20,000 operations and more: sorted in
arrays by several domains, merged into a run as it is written), from a thread of its own on a connection of its own,
while domains parse the rows that come next. So:

- **An import that fits one group is all or nothing**, a constraint of the rules included: the database refuses the
  group whole.
- **A larger import is checked whole first**, then written group after group. The database refuses a group only for
  what the first pass cannot see: a constraint of a rule, or a unique value that another program wrote meanwhile.
  The import then stops and names what is written:

```text
cepheus: invoices.csv lines 2252 to 2501: the database refused their group: invalid: constraint never-void: ...;
written before it: lines 2 to 2251, in groups 5 to 13
```

  The rows before are in the database, the rows after are not: fix the file, and import its rows from that line on.

An import is one command's work: two imports of one kind at once may each find a unique value free in their first
pass; the database then refuses the second one's group, as above. The file must be a file (not a pipe: it is read
twice), and not change while it is read (its size and time are checked between the passes).

### What an export gives

Every thing of the kind at one state of the database, the group of that state on stderr
(`cepheus: shop at group 6202: 100,000 things of invoice, 900,000 facts, as CSV, in 0.31 s`), the things by id, each
with the **asserted** facts of its fields: what the rules derive (a client's `Overdue`) is left out, since the rules of
the database the export is imported into derive it again. Links are written as their key (`--link`, as above); a
linked thing without its key stops the export (`--link Field=id` writes the ids). An export imported into a new
database gives the same facts: the test does it for the invoices app, and its exports of both are the same bytes.

The export reads one view in its own process, through the server's follow stream over its Unix socket
([local reads](server.md#local-reads-g15)): a view never changes while it is read, so the file is one consistent state
however long it takes, and no write waits for it. So it runs on the server's machine, with a token that reads the
whole database (a token of some kinds is never followed); elsewhere it says so and stops. Reading at an earlier group
(`--as-of`) waits for reads at a past group.

### Security

- The server checks the token at every request: an import's writes need `write`, an export's follow stream needs
  `read` on the whole database. The command opens the file under its user's rights; the server never sees a path.
- What a file holds is data: a record is at most 8 MiB, so a quote left open in a file of 10 GB stops the import at
  its line rather than reading the rest as one field; a record's fields are made up to the header's count, one more
  counted and not made (8 MiB of commas is 8.4 M fields, 740 MB to make); a record's JSON holds at most 100,000
  values, its lists' items and its objects' members, all its fields together (the bound of `In`), and a header at most
  100,000 columns; JSON nesting is at most 64 deep; texts are checked UTF-8 without NUL; the file is read through the
  descriptor checked, never by its path again, so that a file renamed over it meanwhile is not read.
- An export writes the values exactly as they are, since a round trip needs them: a text that starts with `=`, `+`,
  `-` or `@` is a formula to a spreadsheet that opens the CSV (CSV injection). Open an export in a spreadsheet as text,
  or write the report through the app (the invoices app's CSV guards its cells, [the app](app.md#10-the-csv-export)).

### Memory and speed

The first pass keeps 8 bytes for each unique value (a hash of 30 bits and the row's number, in a table of open
addressing at most 3/4 full); two values of one hash are told apart by reading the earlier row again (the offset of
every 1,024th row is kept), so the check is exact. Everything else is bounded whatever the file's size: rounds of
eight batches of a MiB, two groups in flight, the record bound.

Measured on the test machine (Intel i7-4720HQ, 4 cores, SATA SSD; its btrfs 97 % full, other jobs building beside)
on 2026-11-25 with `bench/transfer.sh DIR 120482 7`: 120,482 clients and 2,409,640 invoices, 10.0 M facts, 149 MB of
CSV; seven rounds, the sides in turn, each durable; median [min, max]. Each side loads the clients (a unique e-mail),
then the invoices, their link found by the client's e-mail: Cepheus by `cepheus import` of each file; PostgreSQL 18.6
by `\copy` of the clients, then `\copy` of the invoices into a table of their text and `INSERT ... SELECT` joined on
the e-mail, in one transaction; SQLite 3.54 by `.import --csv` of each file into a table of its own and the same
`INSERT ... SELECT`.

| | Cepheus | PostgreSQL 18.6 | SQLite 3.54 |
|---|---:|---:|---:|
| the clients (361,446 facts) | 1.18 s [1.05, 6.63] | 1.43 s [0.64, 7.21] | 0.47 s [0.43, 2.08] |
| the invoices (9,638,560 facts) | 25.0 s [15.7, 42.1] | 39.7 s [27.4, 83.7] | 8.94 s [7.74, 9.28] |
| both | 28.5 s [16.8, 43.2] | 43.7 s [28.3, 85.2] | 9.71 s [8.17, 10.3] |
| memory at the peak of the load | the command 556 MB [511, 577], the server 450 MB [332, 571] | the backend 316 MB (shared_buffers 1 GB) | 11 MB |
| the export of the invoices with their client's e-mail | 2.61 s [1.76, 3.99], 245 MB | 3.94 s [3.56, 11.5] | 1.61 s [1.57, 1.93] |
| on the disk after the load | 111 to 198 MB (journal and runs) | 237 MB | 276 MB |

SQLite loads fastest: one process writes one file, and it checks nothing of the values (its columns take any text:
the amounts and the dates stay texts). Cepheus reads the file twice, and the first pass, every row checked and every
link found, takes 3.57 s [3.15, 6.37] of the invoices' time; the rest is the server writing ten large groups, which
varied from 11.7 to 38.1 s on this disk (7.8 s in a quiet run of the same build the hour before), where the library
writes the same facts in its own process, in two large groups, in 5.13 s ([benchmarks](benchmarks.md)): each group crosses the
socket, coded and decoded (one of 960,000 facts, 0.72 s through the server, 0.41 s in the process). PostgreSQL loses
the invoices: its join and its foreign key check each row after the copy. An invoice whose e-mail no client has is
dropped in silence by the join of PostgreSQL and SQLite; Cepheus refuses the file, naming the line, before it
writes anything.

A file of 10 GiB (10,737,434,790 bytes, 192,506,762 rows: 13 clients' invoices over and over, in a folder compressed
by btrfs, `chattr +c`, so that it held 1.2 GB of a disk with 7 GB free) whose last row has 3 decimals for cents is
checked whole and refused at that line, nothing written: 253 s (42 MB/s), the command's peak 244 MB, against 130 MB
for the 149 MB of the bench's invoices: the memory does not follow the file.

`bench/transfer.sh DIR CLIENTS [ROUNDS]` runs the three sides.

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
| `bench/transfer.sh` | `cepheus import` and `export` beside PostgreSQL's `COPY` and SQLite's `.import` | [import and export](#memory-and-speed) |
