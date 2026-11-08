# Errors

Every error Cepheus returns or raises, the exact message, where it comes from, what it means, and what to do. A
message in the table is the text inside the constructor; `message e` adds the kind in front (`"invalid: "`,
`"conflict: "`...). In the messages, `#E` is a thing number, `P` a property number, `NAME` a property's name, `V` a
value as `Value.to_string` prints it (a text in quotes, a link as `#E`, `money 120000`, `date 1700000000000`), `T` a
type (`int`, `float`, `bool`, `text`, `date`, `money(2)`, `link`), and `SEG` a segment's file name.

```ocaml
open Cepheus

let () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ email; age ]) = declare db [ prop ~unique:true "client/email" Ttext; prop "client/age" Tint ] in
  let ada = thing (Result.get_ok (write db [ Add (-1, email, Text "ada@example.com") ])) (-1) in
  let try_ ops = match write db ops with Ok r -> Printf.printf "ok, group %d\n" r.group | Error e -> print_endline (message e) in
  try_ [ Add (-1, email, Text "ada@example.com") ];
  try_ [ Add (ada, age, Text "forty") ];
  try_ [ Add (ada + 1, age, Int 40) ];
  try_ [ Expect (ada, age, None); Add (ada, age, Int 40) ];
  try_ [ Expect (ada, age, None); Add (ada, age, Int 41) ];
  try_ [ Add (ada, 99, Int 1) ]
```

```output
not unique: client/email "ada@example.com" is taken
invalid: "forty" is not a int (property client/age)
invalid: no thing #65537
ok, group 4
conflict: #65536 has a value for property 17
invalid: no property 99
```

A failed write changes nothing: no group number is used, no thing number is taken.

## `Conflict`: an `Expect` did not hold

Returned by `write`. The group was checked against the newest state and one of its `Expect`s was false: another
group changed the fact since the view the client read. **Do**: take a new view, decide again, write again (the usual
loop of optimistic concurrency).

| message | when |
|---|---|
| `#E has a value for property P` | `Expect (E, P, None)`, and E has a value for P |
| `#E does not have V for property P` | `Expect (E, P, Some V)`, and the fact (E, P, V) does not hold |

## `Not_unique`

| message | when | do |
|---|---|---|
| `NAME V is taken` | after the group, another thing has the value V for the unique property NAME | choose another value, or retract it from the other thing in the same group |

## `Invalid`: the request is wrong

Nothing was written. **Do**: fix the request; trying again unchanged gives the same error.

From `write` (the writer's checks, the same on a database and on a fork):

| message | when |
|---|---|
| `no property P` | P is not a declared property of the view |
| `Expect on a new thing` | an `Expect` names a negative (new) thing: it has no facts before the group |
| `Expect: V is not a T` | the value of an `Expect` is not of the property's type |
| `V is not a T (property NAME)` | an `Add` or `Retract` with a value of the wrong type |
| `no thing #E` | E is 65,536 or more and the database never made it |
| `no thing #E to link to` | a `Link` to a number below 16, or to a thing never made |
| `#E is a system thing` | E is below 16: those numbers are reserved |
| `a property thing takes only cepheus/ properties` | an ordinary property written on a property thing (16 to 65,535) |
| `cepheus/ properties describe property things only` | `cepheus/name`, `type`, `many` or `unique` written on an ordinary thing |
| `property P needs both a name and a type` | a group left property thing P with a name and no type, or the reverse |
| `half` | a group left property thing P with `cepheus/many` or `cepheus/unique` but neither a name nor a type |
| `property P has an unknown type code C` | `cepheus/type` holds a code no type has (`Tmoney` with more than 18 digits) |
| `the type and the cardinality of NAME never change` | a group changed a property's type or `many` flag; declare another property |
| `NAME cannot become unique: two things share a value` | `cepheus/unique` set to true while two things share a value |
| `NAME still has values` | a property's name and type retracted while things still have values for it |
| `a group of N bytes is over the frame limit of 268435456` | the group's encoding passes 256 MiB, the largest frame body: split it ([limits](limits.md#writes)) |
| `thing numbers end at 2147483647: this group would make #N` | the group's new things would take thing numbers past 2³¹ − 1, the largest a run holds ([limits](limits.md#things-properties-values)); the database can make no more things |

From `declare` and `snapshot`:

| message | when |
|---|---|
| `NAME is declared already as another kind of property` | `declare` with a name that exists with another type, cardinality or unique flag |
| `a fork has no files` | `snapshot` on a fork |

From `find` and `fold` (the question is malformed):

| message | when |
|---|---|
| `no property P` | a pattern names a property that does not exist |
| `variable X out of range` | a pattern uses variable X outside 0 to `vars - 1` |
| `variable X is both a T and a U` | X appears with two properties of different types (a thing position is a `link`) |
| `variable X appears in no pattern` | a variable below `vars` that no pattern uses |
| `V is not a T` | a constant value of the wrong type for its property |
| `a range needs an int, date or money variable` | a range on a text or float variable, or on a variable outside 0 to `vars - 1` (ranges also accept bool and link variables) |

## `Damaged`: durable data lost or changed

The files no longer hold what the database made durable: a disk that changed bytes, a file copied badly, a segment
removed by hand. The database **refuses to open** rather than drop a confirmed group in silence (G6). **Do**: do not
delete or edit files; copy the directory aside; run `Cepheus.verify` on the copy for the first fault; restore from a
backup. Cut a journal by hand only if you know the damaged frame was never confirmed ([operations](operations.md#when-recovery-says-damaged)).

From `open_` (recovery) and `verify`; `SEG` is the segment's name, an offset is in bytes from the segment's start:

| message | what it means |
|---|---|
| `DIR/cepheus is not a Cepheus database file` | the database's id file is not 37 bytes, or its magic or its CRC is wrong |
| `SEG: unknown format F` | a segment header that checks but has a format other than 1 |
| `SEG: a segment of another database` | the segment's database id is not this database's (files of two databases mixed) |
| `journal: segment SEG, where the snapshot starts, is missing` | the newest run resumes in a segment that is not there |
| `journal: the first segment starts at group G` | no run, and the oldest segment does not start at group 1 |
| `journal: SEG does not follow group G (a segment is missing)` | a gap between two segments |
| `journal: SEG has a broken header` | a segment other than the newest has a header that does not check |
| `journal: SEG says it starts at group G` | a segment's header and its file name disagree |
| `journal: SEG is shorter than the snapshot says` | the newest run resumes past the end of the segment |
| `SEG: frame at O starts at group G, expected N` | a frame that checks, out of sequence |
| `SEG: group G where N was expected` | a group out of sequence inside a frame |
| `SEG: frame at O does not decode` | a frame that checks but whose groups cannot be read |
| `SEG: frame at O has bytes after its groups` | the same |
| `SEG: damaged frame at offset O (written whole)` | the frame does not check, and a later frame header checks or its trailer matches its body: once durable, now damaged |
| `SEG: segment ends with a broken frame at O` | a frame that does not check at the end of a segment that is not the newest (segments are forced whole before the next begins) |
| `the journal ends at group G, before the snapshot of group S` | the newest run holds groups the journal lost (a run is named only once its groups are durable) |
| `group N uses property P, which does not exist` | the replay met a change of a property no group declared |

From `verify` only (a full read is strict: recovery repairs these, so after it they are damage):

| message | what it means |
|---|---|
| `journal: the newest segment has a broken header` | a newest segment torn at its creation, never repaired by a recovery |
| `SEG: the trailer of the frame at O is damaged` | a frame whose header and body check, but not its trailer |
| `SEG: the frame at O does not check` | the newest frame does not check (a torn tail, or damage to the newest frame: the residual case of G6) |

From reads of the runs (`find`, `fold`, `write` and `snapshot` return `Damaged`; `get`, `values`, `things` and a
fork's `write` raise `Unreadable` with the same message):

| message | what it means | do |
|---|---|---|
| `run NAME: page K does not check` | page K (16 KiB) of a run's file was read from the disk and its CRC-32C does not match: never served | the run is damaged (it is a cache: the journal is intact). Close the database and open it again: a run that fits in the cache is checked whole at open and set aside. A larger one is not read whole at open: move its file out of `snapshots/` (keep it for the diagnosis) and open again; the other runs and the journal rebuild the state |
| a `Disk.Io` message (below) | the disk could not read the page | as for `Io` |

**Runs set aside at open** are not errors: the open chooses another chain of runs without it, or replays the
journal, and `notes db` lists `snapshot NAME set aside: REASON`, with REASON one of `shorter than its header`, `not a
run`, `its header does not check`, `unknown format F`, `a run of another database`, `its groups are not those of its
name`, `bad counts`, `its journal position is after its group`, `shorter than its header says`, `its checksum table
does not check`, `its layout does not match its size`, `the rank table of its additions is out of order`, `the rank
table of its additions does not end at N` (and the same for `its retractions`), `the thing offsets of its additions
is out of order`, `the property offsets of its retractions does not end at N` (each table of each part), `the text
offsets is out of order`, a schema error of the table above, a page that does not check, or a `Disk.Io` message. A
snapshot of an earlier format (`<group>.snap`, format 4 and before) gives `snapshot NAME set aside: an earlier format,
the journal is replayed`: the open replays the whole journal once, and the first merge removes the old file.

## `Io`: the disk failed

A system call failed. During a write or an fsync of the journal, the database **stops** (G10): this group and every
later one return an `Io`, `snapshot` too; it never retries the fsync, because after a failed fsync the kernel has
marked the pages it could not write clean, and a second fsync would succeed without writing them (Rebello et al.
2020). The writer cuts the journal back to its last durable frame at once, so the failed writes are absent (G13).
**Do**: fix the disk (space, permissions, hardware), `close` the database and open it again: recovery starts from the
journal, after writing its newest frame again (no reboot needed). A failed merge does not stop the database (below);
a large group whose run file fails returns `Io` for that group only. The message is `CALL PATH: REASON`, with CALL one of `open`, `read`, `write`, `lseek`, `fstat`,
`ftruncate`, `fsync`, `close`, `rename`, `unlink`, `mkdir`, `readdir`, `lock`, and REASON the system's text (`No space
left on device`); or `read PATH: short file` (a file shorter than its header says), `file N is closed`, `journal is
closed`, and `journal: an earlier write failed; reopen the database` (the writes after the first failure).

## `Busy` and `Closed`

| error | message | when | do |
|---|---|---|---|
| `Busy` | `DIR is open in another process` | another process holds `DIR/lock`, or this process has the database open already, under this path or any other that names the same directory (a symbolic link, `DIR/.`, `x/../DIR`) | close the other one; one engine per database |
| `Closed` | `the database is closed` | `write` or `snapshot` after `close` | open the database again |

## Exceptions

| exception | raised by | when |
|---|---|---|
| `Unreadable of string` | `get`, `values`, `things`, a fork's `write` | a page of a run cannot be read or does not check (above) |
| `Not_found` | `thing r k` | k is not a new thing of the group of receipt r |
| `Failure "Cepheus needs the processor's CRC-32C instruction (SSE4.2 on x86-64, CRC32 on arm64), and this processor has none"` | the program's start, before its own code runs (the initialisation of `Crc32c`) | the processor lacks the instruction every checksum uses ([limits](limits.md#files-and-the-platform)): an x86-64 older than the x86-64-v2 level, or an arm64 of ARMv8.0 without the optional CRC32 instructions. Run on another machine; nothing was read or written |
| `Failure "bootstrap: ..."` | `open_` of a new database | the first group, which describes the system properties, was refused: a bug |
| `Invalid_argument` | internals | a broken invariant, which is a bug: `Journal.append: groups out of order`, `Engine.install: not durable`, `Snapshot.merge: ...` (a section that overflows or does not add up, a retraction with nothing below, a fact of a large group past the things, the journal position after the view, more runs than the view has); `Pages: a page of a base built in memory is missing`; or a misuse of an internal function (`Codec.reader`, `Codec.put_varint` of a negative number, `Crc32c.bytes`, `Crc32c.extend`, `Rng.int`); `Journal.append: frame too large` (the writer never makes a frame over 256 MiB, so this is a bug); and `Cepheus.decode: variable X out of range` or `Cepheus.decode: MSG` (a question `fold` refuses), a misuse of `decode` |

## Lines on the standard error

A merge runs in the background; when it fails, it says so on the standard error, removes its file, and the database
goes on with its old runs (no error reaches a client); the next merge waits until the delta has grown by another
threshold. Two other lines come from the writer.

| line | when |
|---|---|
| `cepheus: the journal could not be cut back after a failed write: MSG` | after a failed write or fsync of the journal, the cut back to the last durable frame failed too: the failed writes may come back at the reopen (G13) |
| `cepheus: the run of a large group could not be named: MSG` | the rename of a large group's run file failed after its frame was durable: the database stops (`Io`), and the next open replays the group from the journal |
| `cepheus: background merge failed: EXN` | the merge domain met an exception (a disk error, an unreadable page) |
| `cepheus: a merge could not be installed: MSG` | the rename or the directory's fsync failed |
| `cepheus: a merge could not catch up: MSG` | a page could not be read while replaying the groups written during the merge |
