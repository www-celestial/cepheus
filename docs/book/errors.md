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
conflict: #65536 has a value for client/age (property 17)
invalid: no property 99
```

A failed write changes nothing: no group number is used, no thing number is taken.

## `Conflict`: an `Expect` did not hold

Returned by `write`. The group was checked against the newest state and one of its `Expect`s was false: another
group changed the fact since the view the client read. **Do**: take a new view, decide again, write again (the usual
loop of optimistic concurrency).

| message | when |
|---|---|
| `#E has a value for N (property P)` | `Expect (E, P, None)`, and E has a value for P, whose name is N |
| `#E does not have V for N (property P)` | `Expect (E, P, Some V)`, and the fact (E, P, V) does not hold; N is P's name |


A change of the rules or the ontology computed in the background ([rules](rules.md#changes-of-the-rules-in-the-background))
answers `Conflict` when a group written meanwhile interfered; `define` tries again by itself:

| message | when |
|---|---|
| `group G, written meanwhile, changed [#E P V], which the change writes` | the group asserted or retracted a fact the change asserts or retracts |
| `group G, written meanwhile, changed the rules` | a change made in its own group (one that makes new things) was ordered first |
| `#E would have two values of NAME under the new rules` | the groups written meanwhile and the new rules give a one-valued property two values |
| `NAME V would be taken twice under the new rules` | the same for a unique property |
| `constraint R: FACTS`, a rule's refusal | the groups written meanwhile break the new rules |
| `the change derived more than N facts with the groups written meanwhile` | the groups written meanwhile took the change past its budget |
| `the facts of the change were written meanwhile` | the change's asserted part changed between its build and its install |

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
| `Incr counts on a one-valued int property of the program's: NAME is X` | an `Incr` of a counter that is not an `Int` (X: `a text`, ...), many-valued, or the database's own |
| `Incr writes into an int property of the program's: NAME is X` | an `Incr` whose `into` is not an `Int`, or is the database's own |
| `Incr: NAME of #E is N, and BY more passes the ints` | the counter's sum would pass the 63 bits of an int: the group is refused, the counter stays N |
| `no thing #E` | E is 65,536 or more and the database never made it |
| `no thing #E to link to` | a `Link` to a number below 16, or to a thing never made |
| `#E is a system thing` | E is below 16: those numbers are reserved |
| `a property thing takes only cepheus/ properties` | an ordinary property written on a property thing (16 to 65,535) |
| `cepheus/ properties describe property things only` | `cepheus/name`, `type`, `many` or `unique` written on an ordinary thing |
| `property P needs both a name and a type` | a group left property thing P with a name and no type, or the reverse |
| `property P keeps cepheus/many or cepheus/unique without a name and a type` | a group left property thing P with `cepheus/many` or `cepheus/unique` but neither a name nor a type |
| `property P has an unknown type code C` | `cepheus/type` holds a code no type has (`Tmoney` with more than 18 digits) |
| `the type and the cardinality of NAME never change` | a group changed a property's type or `many` flag; declare another property |
| `NAME cannot become unique: two things share a value` | `cepheus/unique` set to true while two things share a value |
| `NAME still has values` | a property's name and type retracted while things still have values for it |
| `a group of N bytes is over the frame limit of 268435456` | the group's encoding passes 256 MiB, the largest frame body: split it ([limits](limits.md#writes)) |
| `thing numbers end at 2147483647: this group would make #N` | the group's new things would take thing numbers past $2^{31} - 1$, the largest a run holds ([limits](limits.md#things-properties-values)); the database can make no more things |

From `write` with rules (the writer's reasoning, the same on a database and on a fork; [rules](rules.md)):

| message | when |
|---|---|
| `[#E P V] is derived by rule R from F and G: retract one of those` | a `Retract` of a fact that is only derived: its premises would derive it again; retract the asserted facts it names (the facts of one proof) |
| `[#E P V] is derived by a rule` | the same, when no proof of it could be printed |
| `rule R derived more than N facts from a group of K facts` | the group's derived changes pass the budget, $N = \mathit{base} + \mathit{per} \times K$ ([api](api.md#rules), `rule_budget`); R derived the most. Split the write, or raise the budget |
| `rule R derived more than N facts from a change of the rules or the ontology` | a change's derived facts pass its budget, $N = \mathit{base} + \mathit{per} \times K + 4 \times$ the database's facts (`change_budget`); R derived the most |
| `a change of the rules or the ontology derived more than N facts` | the same, found at the change's install, after the groups it caught up with |
| `rule R read more than N candidates of its patterns for a group of K facts` | the candidates the group's rules read (each fact a pattern of a body, a Not or a constraint enumerates) pass the work budget, $N = 10 \times (\mathit{base} + \mathit{per} \times K)$ (`work_budget`); R read the last one. A body whose patterns share a value walks their product (three things of one tag: $n^3$). Join on a more selective pattern first, split the write, or raise the budget |
| `rule R read more than N candidates of its patterns for a change of the rules or the ontology` | the same for a change, $N = 10 \times$ its budget of derived facts |
| `the change failed: E` | a change in the background met an error of the engine (a bug), written on the standard error too |
| `constraint R: FACTS` | the group would make the body of constraint R true: FACTS are the facts of one instance |
| `rule R gives #E a second value of NAME, which takes one` | a derived value of a one-valued property beside another value |
| `rule R gives NAME V, which another thing has` | a derived value of a unique property that another thing holds |
| `rule R gives a fact about #E, which does not exist` | a head names a thing the database never made |
| `rule R gives a fact of #P, which is not a property it can give` | a head whose property is a variable gives a thing that is no property of the application (none, or a `cepheus/` one) |
| `rule R gives NAME a value of another type` | a head gives a value read under a variable property to a property of another type |
| `rule R gives a fact about a value that is not a thing` | a head's thing is a variable read under a variable property whose values are not links |

From `define`, or a write of a rule's facts (a rule is checked when it is written):

| message | when |
|---|---|
| `NAME is the name of a property` | `define` with a rule named like a property |
| `rule NAME: its body has no pattern` | `where` is empty |
| `rule NAME: N variables (at most 64)` | `vars` above 64 |
| `rule NAME: variable ?K out of range` | a pattern or the head uses K outside 0 to `vars - 1` |
| `rule NAME: variable ?K appears in no pattern of the body` | a variable below `vars` that no pattern of the body uses |
| `rule NAME: the thing of a pattern is a variable or a thing` | a pattern's thing is a `Val` |
| `rule NAME: the property ?K is bound by no pattern whose property is a constant` / `… the property ?K of its head …` | a variable property (`prop_var K`) that no pattern with a constant property has as its thing or its value |
| `rule NAME: no property P` / `… no property P in its head` | a pattern or the head names a property that does not exist |
| `rule NAME: variable X is both a T and a U` | as for a question |
| `rule NAME: a range needs an int, date or money variable` / `… the bounds of ?X are not of its type` | a range on another type, or bounds of another type |
| `rule NAME: V is not a T` | a constant of the wrong type for its property |
| `rule NAME: its head gives a cepheus/ property` | a head on a system property |
| `rule NAME: ?K is not a thing` / `… the thing of its head is a variable or a thing` / `… its head's thing #T is not an ordinary thing` | the head's thing is not a link variable or an ordinary thing |
| `rule NAME: ?K is a T, NAME takes a U` / `… NAME takes a T, not a thing` | the head's value does not fit its property |
| `rule NAME: cannot read its definition at character N` / `… its definition is not in canonical form` | a `cepheus/rule` fact written by hand that is not a rule's canonical text (Rules.to_text) |
| `rule R takes a name and a definition only` / `rule R needs a name and a definition, and no type` | a rule thing with `cepheus/many`, `cepheus/unique` or `cepheus/type`, or without its name |
| `NAME is a property: it never becomes a rule` / `a rule never becomes a property (NAME)` | a schema thing changed from one kind to the other |

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

### Templates and equality

| message | when |
|---|---|
| `rule R: one every [..] a rule`; `rule R: the member ?k of every [..] is in no other pattern`; `… is in its head …`; `rule R: a template (every) takes no Not and no aggregate` | a template written wrong |
| `rule R gives P, the list of the template T: only a write may change a list` | a rule's head is a template's list, or a rule derived a fact of one |
| `rule R: the list of #c has N members (a template takes at most 64)` | a write makes a list too long for its template |
| `rule R makes two different values the same: only things can be the same as another` | an equality between two values that differ (prp-fp over a property of texts with two values) |
| `rule R would make the property #p the same as another thing: a property is the same as no other` | an equality on a property thing |
| `rule R would make #a the same as #b, which a rule names: a thing the rules name keeps its own identity` | an equality on a constant of the rules (owl:Thing, a class an unfolded rule names) |
| `rule R: a rule that makes things the same takes no Not and no aggregate`; `a rule set that makes things the same takes no Not and no aggregate yet` | equality beside negation or aggregates |
| `rule R: cepheus/same is read through the classes of equal things, not by a rule's pattern` | a rule's body reads `cepheus/same` |
| `constraint owl/eq-diff1: [#r owl/DifferentFrom #r]` | two things said different are made the same |

## `Damaged`: durable data lost or changed

The files no longer hold what the database made durable: a disk that changed bytes, a file copied badly, a segment
removed by hand. The database **refuses to open** rather than drop a confirmed group in silence (G6). **Do**: do not
delete or edit files; run `cepheus verify DIR` for every fault (it changes nothing); restore from a backup
(`cepheus restore BACKUP DIR --replace`, which keeps the damaged folder aside). Cut a journal by hand only if you know the damaged frame was never confirmed ([operations](operations.md#when-recovery-says-damaged)).

From `open_` (recovery) and `verify`; `SEG` is the segment's name, an offset is in bytes from the segment's start:

| message | what it means |
|---|---|
| `DIR/cepheus is not a Cepheus database file` | the database's id file is not 37 bytes, or its magic or its CRC is wrong |
| `SEG: unknown format F` | a segment header that checks but has a format other than 2, the journal's (a segment of format 1 is converted at open) |
| `SEG: a segment of another database` | the segment's database id is not this database's (files of two databases mixed) |
| `journal: segment SEG, where the snapshot starts, is missing` | the newest run resumes in a segment that is not there |
| `journal: the first segment starts at group G` | no run, and the oldest segment does not start at group 1 |
| `journal: SEG does not follow group G (a segment is missing)` | a gap between two segments |
| `journal: SEG has a broken header` | a segment other than the newest has a header that does not check |
| `journal: SEG has a broken header, with N bytes after it` | the newest segment holds bytes past its header, which does not check: the header was forced before any frame, so it changed since (G6) |
| `journal: SEG, where the newest run starts, has a broken header` | the newest run resumes in a segment whose header does not check, or that is shorter than its header: the writer had forced that header |
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

From a server's start, its commit buffer ([the server](server.md#many-databases-one-fsync-the-commit-buffer); `FILE` is
`DATA/server.wal.1` or `.2`):

| message | what it means |
|---|---|
| `FILE: a broken header` | a file of the buffer whose header does not check (a file takes its name only once its header is durable) |
| `FILE: unknown format F` | a header that checks, of a format other than 1 |
| `server.wal.N: damaged round at offset O (written whole)` | a round that does not check, in the older file, or followed by a round written whole: once durable, now damaged |
| `FILE: round R at O does not hold its entries` / `has bytes after its entries` | a round that checks but whose entries do not add up to its body |
| `server.wal.1 holds confirmed writes of databases this server did not open (ids ...): open them with it once` | the buffer holds frames of a database `cluster.toml` no longer lists: add it back, start the server, stop it ([operations](operations.md#a-database-of-a-server)) |
| `journal: segment SEG, where the commit buffer's frames go, is missing` | the newest run resumes in a segment that is not there |
| `SEG: the frame at O (group G) does not check, before the commit buffer's frames from group N` | a frame the buffer does not hold, before frames it holds: it was forced, and is damaged |
| `journal: the commit buffer's frame of group G does not start where a frame does (group N)` | the journal's frames and the buffer's do not line up |
| `SEG: the frame at O is not the one the commit buffer holds for group G (the database was written without its server's buffer after a crash)` | another frame that checks is where the buffer's goes: a version without the buffer opened the database after a crash and wrote to it; never written over ([operations](operations.md#a-database-of-a-server)) |

From `verify` only (a full read is strict: recovery repairs these, so after it they are damage):

| message | what it means |
|---|---|
| `journal: the newest segment has a broken header` | a newest segment no longer than its header, torn at its creation, never repaired by a recovery |
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
| `Busy` | `DIR was written through a server's commit buffer and not closed cleanly: its newest writes may be in the server's DATA/server.wal.1 or .2 alone; start the server on its data directory, which writes them into the journal, and stop it` | `open_` in a program's own process of a database a server held when it crashed (`DIR/shared` and no `DIR/closed`) | start the server and stop it; the database then opens anywhere ([operations](operations.md#a-database-of-a-server)) |
| `Closed` | `the database is closed` | `write` or `snapshot` after `close` | open the database again |

## `Timeout`: a question passed its time

| error | message | when | do |
|---|---|---|---|
| `Timeout` | `the question took more than N s, its time: ask a narrower one, or give it more time` | `find`, `ask` or `fold` given `~timeout:N` ran past N seconds (looked at every 1,024 candidates of each domain: it ends within a few milliseconds of its time); nothing is returned of it ([limits](limits.md#questions)) | a narrower question (a selective pattern first, a range, pages with Sort and Limit), or a longer time |

`find`, `ask` and `fold` raise `Invalid_argument` for a timeout of 0 or less, or NaN: a program's mistake.

## Exceptions

| exception | raised by | when |
|---|---|---|
| `Unreadable of string` | `get`, `values`, `things`, a fork's `write` | a page of a run cannot be read or does not check (above) |
| `Not_found` | `thing r k` | k is not a new thing of the group of receipt r |
| `Failure "Cepheus needs the processor's CRC-32C instruction (SSE4.2 on x86-64, CRC32 on arm64), and this processor has none"` | the program's start, before its own code runs (the initialisation of `Crc32c`) | the processor lacks the instruction every checksum uses ([limits](limits.md#files-and-the-platform)): an x86-64 older than the x86-64-v2 level, or an arm64 of ARMv8.0 without the optional CRC32 instructions. Run on another machine; nothing was read or written |
| `Failure "bootstrap: ..."` | `open_` of a new database | the first group, which describes the system properties, was refused: a bug |
| `Invalid_argument` | internals | a broken invariant, which is a bug: `Journal.append: groups out of order`, `Engine.install: not durable`, `Snapshot.merge: ...` (a section that overflows or does not add up, a retraction with nothing below, a fact of a large group past the things, the journal position after the view, more runs than the view has); `Pages: a page of a base built in memory is missing`; or a misuse of an internal function (`Codec.reader`, `Codec.put_varint` of a negative number, `Crc32c.bytes`, `Crc32c.extend`, `Rng.int`); `Journal.append: frame too large` (the writer never makes a frame over 256 MiB, so this is a bug); and `Cepheus.decode: variable X out of range` or `Cepheus.decode: MSG` (a question `fold` refuses), a misuse of `decode` |

## Through the server

A program connected to the server receives every error above as a value `{code, message}` (`conflict`, `invalid`,
`unique`, `damaged`, `io`, `busy`, `closed`, `timeout`), and the server's own codes: `auth`, `denied`, `version`, `too_large`,
`unknown_database`, `stopping`, `refused`, `too_many_connections`, `idle`, `internal`, `read_only` (a replica), and in
a Raft cluster `not_leader` (this server follows a leader: its message names it, and its body carries the leader's
address, which the OCaml library follows by itself) and `no_leader` (an election runs, or the new leader is not ready:
try again; the OCaml library does, within its retry budget). Each, when it comes and what to do: [the server](server.md#errors).

The file vault's ([the vault](vault.md)), through the server or from `Cepheus_vault.Vault`:

| code | message | when | what to do |
|---|---|---|---|
| `missing` | `thing T has no file of this kind`, `chunk H is not in the vault` | a Load of a thing without a file; a record a fact cites that the vault does not hold (a vault copied without its packs) | check the thing; restore the packs |
| `damaged` | `record H: its tag does not check (the bytes changed on the disk)`, `... its header does not check`, `... the record found there is another one`, `... its bytes do not match their CRC` | a chunk or node changed on the disk | put the same file again (the damaged chunk is written anew), or restore from a copy |
| `erased` | `the files of domain D were erased (its key is destroyed)` | a Load of a file of an erased owner, or a Put that names it | nothing: it is for good |
| `invalid` | `the master key does not open the key of domain D (another vault's key?)` | the vault opened with another master key than its own | give the server its own `vault.key` |
| `damaged` | `keys: the entry at N does not check, and later ones do` | the keys' file changed on the disk before its end | restore `keys` from a copy (a lost key is a domain's files lost) |
| `busy` | `DIR is open in another process` | a second process opens the same vault | one process a vault |

## In a Cesia program

The Cesia client ([Cepheus from Cesia](cesia.md)) gives every error above, and the server's, as a value
`result.Err({Kind: "cepheus", Code, Message})`, with the codes in lower case (`conflict`, `unique`, `invalid`,
`damaged`, `io`, `busy`, `closed`, and the server's), and adds its own:

| Code | Message | when | do |
|---|---|---|---|
| `invalid` | `P needs a Text` (an Int, a number, a Bool, a date in seconds since 1970, an amount), `not V` | a value given for the property P is not of its type | give a value of the property's type |
| `invalid` | `P needs an amount that fits` | a Money value past 63 bits once in minor units | a smaller amount |
| `invalid` | `P needs a date in seconds since 1970, not V` | also a date of $4.6 \times 10^{15}$ s or more either way (its milliseconds would pass 63 bits) | a date in range |
| `invalid` | `the kind K has no field F` | a field given to Insert or Update that the kind does not declare | correct the field's name (it is never dropped in silence) |
| `invalid` | `P is not declared in this database: give its kind to Connect (or Fork)` | a kind used on a database that was not given it | add the kind to Connect's list, or Fork's |
| `invalid` | `P is a T in this database, not a U` | the database declares the property with another type | the kind must match the database's schema |
| `invalid` | `Insert needs at least one field of K`, `Update needs at least one field of K`, `Update needs the id of a thing, not N`, `a group needs at least one operation` | an empty write | write something |
| `invalid` | `P holds several values: change them with Write, Add and Retract` | Update of a field of many values | `cepheus.Write` with `Add` and `Retract` |
| `invalid` | `Above, Below and Between are for ints, dates and money, not a T`; `a variable of Above, Below or Between appears in no pattern` | a range on another type, or on a variable of no pattern | filter the rows in Cesia (`list.Filter`) |
| `invalid` | `Sort's keys are fields of Give: a variable or an aggregate that Give gives` | a key of Sort that Give does not give | add it to Give (After is a row: it holds every key) |
| `invalid` | `After needs Sort: the rows after a row, in an order`; `After needs every field of Give: F is missing`; `After's N needs a T, not V` | a cursor without an order, or not a whole row of Give | give Sort, and a row of an earlier answer |
| `invalid` | `Not takes 1 to 4 patterns or conditions, not N`; `Or takes 2 to 4 alternatives, not N`; `And takes 1 to 4 patterns or conditions, not N`; `Not takes patterns and conditions: no Not or Or inside it`; `Or takes patterns, conditions and And: no Not or Or inside it`; `And is for an alternative of Or: Where is already all of its items` | the shape of Not, Or and And | name a deeper condition with a rule, as a derived fact |
| `invalid` | `an Or of one pattern that differs only in its value is In's case: write In(x, [...]) on the pattern's variable` | an `Or` that is an `In` | `cepheus.In` (one way to write it) |
| `invalid` | `variable N is in no pattern of the question: it may be the own of one Not or one Or only`; `variable N is a Not's or an Or's own: Give and Sort take the question's variables`; `a question needs a pattern outside Not` | a variable shared by two Nots, given, or a question of Nots alone | bind it by a pattern of the question |
| `invalid` | `In needs values of the variable's type (a T), not V`; `a variable of In appears in no pattern` | `In` with values of another type | values of the variable's type |
| `invalid` | `this server speaks protocol 1: Not, Or, In, Prefix, Sort, Limit and After need a server of protocol 2` | a question with them, on a connection to a server of an earlier release | upgrade the server ([upgrades](production.md#upgrades)) |
| `invalid` | `this server speaks protocol 3 or older: Incr needs a server of protocol 4` | a group with `cepheus.Incr`, on a connection to a server of an earlier release: refused before it is sent | upgrade the server ([upgrades](production.md#upgrades)) |
| `invalid` | `this server speaks protocol N: a question's timeout needs a server of protocol 6` | `Find` or `Watch` with `timeout`, on a connection to a server of an earlier release: refused before it is sent | upgrade the server, or leave the time to the server's `question_timeout` |
| `timeout` | `the question took more than N s, its time: ask a narrower one, or give it more time` | the question ran past its `timeout`, or past the server's `question_timeout` (a time longer than the server's counts only from an admin token): in the program's memory or at the server alike | a narrower question, or pages; a longer `timeout` where the server allows it |
| `invalid` | `Prefix is for a text, not a T`; `Prefix takes 1 to 1024 bytes, not N`; `variable N of Prefix is the value of no pattern` | `Prefix` on another type, an empty or long prefix | a text variable a pattern gives |
| `invalid` | `Limit: at most 100000 rows a page, not N`; `In takes at most 100000 values, not N`; `a question takes at most 64 operators and their items, not N`; `a question's Ors make N questions to ask (the product of their alternatives): at most 64` | the bounds of a question ([limits](limits.md#questions)) | page, split the list, or ask several questions |
| `too_large` | `the question passed the server's budget of N candidates: ask a narrower one, or several` | a question whose join enumerates more than the server's budget, its lookups over the most patterns one variable has ([limits](limits.md#questions)); a watch past it at a frame (its Not, Or or In, or the refill of its window) ends with it | a narrower question: more constants, a range, a Limit on the index path |
| `too_large` | `the answer passed the server's budget of N cells (rows times columns): ask a narrower question, or pages with Sort, Limit and After` | a Find with Sort or aggregates, or a watch's first answer, whose rows the server would hold past its bound ([limits](limits.md#questions)); a Find without Sort is never refused for its size (past them it is sent as its rows are found) | pages (`Sort`, `Limit`, `After`), or a Find without Sort |
| `too_large` | `the answers the server is building hold its budget of N cells: ask again in a moment, or a narrower question` | the held answers of every connection together are at the server's bound | ask again |
| `too_large` | `a connection keeps 1024 watches at most: unwatch one first`; `the server keeps 65536 watches at most: ...`; `the watches of a connection keep N cells at most (their windows' rows and their groups): ...`; `the watches of the server keep N cells at most: ...` | a Watch past the watches of a connection or of the server, or past the rows their windows and groups keep ([limits](limits.md#the-server)) | unwatch what the program no longer shows; a smaller Limit |
| `invalid` | `a name has at most 255 bytes, not N` | a property or a rule declared through the server with a longer name | a shorter name |
| `too_large` | `a text has at most 16773120 bytes, not N` | a text through the server past the frame limit less 4 KiB | a file in the vault (`Put`) |
| `too_large` | `a group of N new things: its receipt would pass the frame limit of 16777216 bytes; write them in several groups` | a group whose receipt would not fit a frame; nothing is applied | several groups |
| `too_large` | `a row of N bytes is over the frame limit of 16777152: give fewer of its texts at once` | a Find (or a watch) whose row alone passes a frame | give fewer text columns |
| `invalid` | `a question has at most 64 patterns, not N: ask several, or name a part with a rule` | a question of more patterns, refused by the client before it is sent (a hand-written client's is refused by the server, which closes the connection) | split it, or name a part with a rule |
| `invalid` | `a watch has no After: its rows are the first of its order, as they change`; `a watch's Limit needs Sort: the engine's order is no order a watch can keep`; `a watch of aggregates keeps every group: Sort and Limit are for a watch of Give` | `Watch` with After, with Limit and no Sort, or with Sort or Limit and aggregates | a watch of `Give` with `Sort` (and `Limit`); for the next page, `Find` with `After` |
| `invalid` | `this server speaks protocol N: a watch with Sort and Limit needs a server of protocol 5` | a watch with Sort or Limit, on a connection to a server of an earlier release: refused before it is sent | upgrade the server ([upgrades](production.md#upgrades)), or watch without them |
| `invalid` | `H is reached over the network: give the cluster's certificate authority, ca = "/etc/cepheus/ca.pem"` | Connect over TCP without `ca` | the cluster's `ca.pem` (made by `cepheus cluster init`) |
| `invalid` | `a fork starts from Empty, another fork, or a database read on the server's machine; this one is read at the server` | Fork of a database reached over the network | fork `cepheus.Empty`, or run on the server's machine |
| `invalid` | `OWL 2 RL's rules need its vocabulary: give owl.Vocabulary to Connect (or Fork)` | `Define` of `owl.Rl()` on a database without the kind `owl` | add `owl.Vocabulary` to Connect's list, or Fork's |
| `invalid` | `P is declared in this database otherwise than in OWL 2 RL's vocabulary` | a property `owl/...` declared with another type, `many` or `unique` | a database whose `owl/` properties are OWL 2 RL's |
| `invalid` | `N is no rule of OWL 2 RL: owl.Rl() gives its rules` | a map `{Rule, Library: "owl"}` of a name the library does not have | the maps of `owl.Rl()` |
| `conflict` | `owl:Thing and owl:Nothing could not be made: Define again` | other programs made and removed them while `Define` made them, three times | Define again |
| `conflict` | `cepheus.Same: the class of N changed while it was read: read it again` | over the network, a class taken apart between the two questions `Same` asks | call `Same` again |
| `closed` | `this database was closed` | a call on a database after `cepheus.Close` | Connect again |
| `unreachable` | `no Cepheus server answers at ADDRESS: REASON` | Connect: nothing listens at the socket or the host's port, or what listens does not answer the handshake within 5 s (REASON `no answer within 5 s`, or `the TLS handshake: Resource temporarily unavailable`) | start the server, check the address |
| `unreachable` | `the server did not answer for 30 s (REASON): a write in flight was applied once or not at all` | a call after the connection broke and stayed broken for the retry budget | start the server; read before writing again |
| `protocol` | `an unexpected reply to Get` (Find, Write) | the server answered with another kind of reply: a bug | report it |

A mistake in the shape of a call is a bug of the program, not an error value: it stops the fiber, as `bug.Panic`,
with Cesia's message, as `cepheus.Get needs a database, as cepheus.Connect or Fork gives it, not the number 3.`
Those of the package: a database, a kind (`as cepheus.Kind made it`), a property (`as Client.City`), a map, a list,
an operation (`as cepheus.Add, Retract, Expect or Incr makes it`), an `Incr`'s `into` (`[thing, property], as
[cepheus.New(1), Invoice.Number]`), a question (`{Where: [patterns], Give: {Name:
variable}}`), a pattern (`[thing, property, value], or Above, Below or Between`), a variable or a thing's id first in a
pattern, a variable or an aggregate in Give; and at `cepheus.Kind`: a name that is not small letters, digits, `_` and
`-`, no field, a field named `kind`, a type that is none of `Text()`, `Int()`, `Float()`, `Bool()`, `Date()`,
`Link()`, `Money(scale)`, a scale outside 0 to 18; at `cepheus.Connect`: an address that is not
`cepheus://host:port/database` (with `?socket=DIR` its only parameter); at `cepheus.Find`: more than 12 variables.

## Lines on the standard error

A merge runs in the background; when it fails, it says so on the standard error, removes its file, and the database
goes on with its old runs (no error reaches a client); the next merge waits until the delta has grown by another
threshold. Other lines come from the writer and the commit buffer.

| line | when |
|---|---|
| `cepheus: the journal could not be cut back after a failed write: MSG` | after a failed write or fsync of the journal, the cut back to the last durable frame failed too: the failed writes may come back at the reopen (G13) |
| `cepheus: the journal could not be forced at close: MSG` | a shared journal's fsync at close failed: no `closed` marker, and the next open is a recovery |
| `cepheus: the commit buffer could not be cut back after a failed write: MSG` | after a failed write or fsync of the buffer, its cut back to the last forced round failed too: the failed round may come back at the next start |
| `cepheus: the commit buffer could not be emptied: MSG` | a clean stop could not remove `DATA/server.wal.1` or `.2`: the next start reads them, and finds their frames in the journals already |
| `cepheus: the run of a large group could not be named: MSG` | the rename of a large group's run file failed after its frame was durable: the database stops (`Io`), and the next open replays the group from the journal |
| `cepheus: background merge failed: EXN` | the merge domain met an exception (a disk error, an unreadable page) |
| `cepheus: a merge could not be installed: MSG` | the rename or the directory's fsync failed |
| `cepheus: a merge could not catch up: MSG` | a page could not be read while replaying the groups written during the merge |
| `cepheus: ready in T ms: ...` | the server started: the time of its opens, each database's group, its listeners and domains |
| `cepheus: FILE reloaded: N tokens` / `cepheus: FILE not reloaded: MSG` | tokens.toml changed; a file that does not parse is not taken, the server keeps the tokens it had |
| `cepheus: database NAME: the sessions could not be saved: MSG` | the session checkpoint failed (a disk error): the older one stays, and the next start reads more of the journal |
| `cepheus: stopping` / `cepheus: stopped` | SIGTERM or SIGINT: the stop of [the server](server.md#start-stop-crash) |
| `cepheus: connection N (token T), request I of kind K failed: EXN` | a request met what the server did not expect (a bug, memory that ran out): it was answered `internal` and its connection closed ([the server](server.md#a-request-that-makes-the-server-fail)). EXN is the exception's text, cut to 300 bytes, every byte outside printable ASCII written `\ddd` |
| `cepheus: connection N (token T) failed: EXN` | the same in another thread of the connection (a write's reply, a push) or in its reading loop: `internal` on request id 0, then the connection closes |
| `cepheus: a watched question at a frame failed: EXN` | a watched question failed at a frame: its watches end `internal`, the other questions go on |
| `cepheus: the watches of a database failed: EXN` | the hub failed outside one question: every watch of the database ends `internal`, and a new watch starts from the frame's state |
| `cepheus: a connection's thread failed: EXN` / `cepheus: a connection's start failed: EXN` | what no catch of a connection expected, after its socket was closed; or no thread could be made for a new connection (the system's limit): it is closed at once |
| `cepheus: a write's reply failed: EXN` / `cepheus: the receipt of a write in its session's table failed: EXN` | a write's outcome could not be handed on, or kept in its session's table (memory): its waiters are answered all the same |
| `... (and N failures since the line before, not written)` | the lines above come at most once a second: the next one counts those left out |
