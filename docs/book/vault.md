# The file vault

A database often has files beside its facts: a scanned invoice, a contract, a photo, a log. The **vault** keeps their
bytes inside Cepheus, so that they are stored, checked, secured and copied with the database rather than beside it.
A file is a thing of a **file kind** with five facts (its name, size, media type, owner and the root of its bytes);
its bytes are in the database's vault, cut into chunks that are stored once, compressed, and sealed with a key of
their owner. This page is the whole of it: how to use it, how it works and why, its formats byte by byte, what it
guarantees, its security, and what it costs beside reading the same files from the file system.

Terms are explained at their first use and in the [glossary](glossary.md).

## From Cesia

```text
use deps/www-celestial/cepheus/cesia/cepheus

Person = cepheus.Kind("person", {Name: cepheus.Text()})
Scans = cepheus.Files("scan")
db = cepheus.Connect("cepheus://srv1:7400/shop", [Person, Scans], token = sys.Env("CEPHEUS_TOKEN"), ca = "/etc/cepheus/ca.pem")?
ada = cepheus.Insert(Person, {Name: "Ada Martin"}, db)?
f = cepheus.Put(Scans, "2026-11.pdf", sys.Read("2026-11.pdf")?, db, type = "application/pdf", owner = ada)?
cepheus.Get(Scans, f, db)?          (* {Name: "2026-11.pdf", Size: 2480311, Type: "application/pdf", Owner: ada, Content: "9c1e..."} *)
all = cepheus.Read(Scans, f, db)?    (* the whole file, a Text of its bytes *)
page = cepheus.Read(Scans, f, db, from = 1_000_000, len = 65_536)?   (* only the chunks under the range are read *)
cepheus.List(Scans, db)?            (* [{Id, Name, Size, Type}] *)
cepheus.Delete(Scans, f, db)?       (* its facts retracted; its bytes stay while the history cites them *)
cepheus.Erase(ada, db)?             (* ada's key destroyed: every file she owned is unreadable, everywhere *)
```

- `cepheus.Files(name)` is a kind like any other, with the fields `Name`, `Size`, `Type`, `Owner` and `Content`: give
  it to `Connect`, and ask questions on it as on any kind. `List(kind, db)` is the question
  `Find(4, (f, n, s, t) -> {Where: [[f, kind.Name, n], [f, kind.Size, s], [f, kind.Type, t]], Give: {Id: f, Name: n, Size: s, Type: t}}, db)`.
- **Rights are the kind's** ([G16](guarantees.md#g16-rights)): a token that may add to `scan` may put a scan; one that
  may read `scan` may read its bytes; `Erase` needs a token that writes the whole database (it cannot be undone), and
  an owner: the database's own key, under the files of no owner, is never erased (`invalid`).
- `Put` returns once the bytes and the facts are on the server's disk; sent again after a broken connection, it is
  applied once (G14): its bytes are found stored, its group answered again.
- `cold = true` stores a file read seldom smaller (Zstandard rather than LZ4), at a slower put.
- A fork holds no file: files are kept in a server's vault (`Put` on a fork is an Err of Code `invalid`).

## From OCaml

The vault is the library `cepheus_vault` (module `Cepheus_vault.Vault`); the server's OCaml client has `Client.put`,
`Client.load` and `Client.erase` for the same requests as the Cesia package.

```ocaml
open Cepheus
open Cepheus_vault

let () =
  let dir = Filename.concat (try Sys.getenv "CEPHEUS_TMP" with Not_found -> Filename.get_temp_dir_name ()) "vault-doc" in
  ignore (Sys.command ("rm -rf " ^ Filename.quote dir));
  let master = String.make 32 'k' (* a server makes it at random, in vault.key *) in
  let v = Result.get_ok (Vault.open_ Disk.real dir ~master) in
  let text = Bytes.of_string (String.concat "" (List.init 20_000 (fun i -> Printf.sprintf "line %d of the log\n" (i mod 100)))) in
  let w = Result.get_ok (Vault.writer v ~domain:7 ~cold:false) in
  ignore (Vault.feed w text 0 (Bytes.length text));
  let root, size = Result.get_ok (Vault.finish w) in
  Printf.printf "%d bytes, named by a root of %d bytes\n" size (String.length root);
  let part = Buffer.create 16 in
  ignore (Vault.load v root ~from:7 ~len:10 (fun b o n -> Buffer.add_subbytes part b o n));
  Printf.printf "bytes 7 to 16: %S\n" (Buffer.contents part);
  Printf.printf "stored once: %b\n" (Vault.written v > 0 && Vault.stored v < size / 4);
  ignore (Vault.erase v 7);
  print_endline (match Vault.size v root with Error e -> Vault.message e | Ok _ -> "still readable");
  Vault.close v
```

```output
378000 bytes, named by a root of 32 bytes
bytes 7 to 16: "of the log"
stored once: true
the files of domain 7 were erased (its key is destroyed)
```

A `writer` takes the bytes in pieces of any size and holds at most a few MiB; nothing of the file is visible until
`finish` returns its root, once every byte it needs is forced to the disk: only then may a fact cite it. `load` gives
the bytes of a range in pieces, reading only the chunks under it.

## How it works

### Chunks cut by their content

A file is cut into **chunks** by **FastCDC** (Xia, Zhou, Jiang, Feng, Hua, Hu, Liu, Zhang, "FastCDC: a Fast and Efficient
Content-Defined Chunking Approach for Data Deduplication", USENIX ATC 2016). A **Gear hash** rolls over the bytes,
h = 2h + G[byte] with G a fixed table of 256 random words: bit k of h depends on the last k + 1 bytes only, since each
doubling pushes the older bytes out at the top. A chunk ends after a byte where the bits of h under a mask (bits 44 to
61: a window of 45 to 62 bytes) are all zero: with a mask of k bits, a chance of 2^-k at each byte. Where a cut falls
depends on the bytes around it and nowhere else: a byte inserted at the start of a file moves the cuts near it only,
and every chunk after it is found again (fixed-size chunks would all shift: in the tests, 24 MB with 100 bytes
inserted at two places, over 97 % of the copy's bytes are found again with FastCDC, under 30 % with fixed 64 KiB
chunks).

**Normalized chunking** (the paper's section 3.3, level 2) keeps the sizes close to 64 KiB: no cut in a chunk's first
16 KiB; a mask of 18 bits up to 64 KiB (a cut is rare); 14 bits after it (soon); a cut at 256 KiB. The chance of a cut
between 16 and 64 KiB is 1 - (1 - 2^-18)^49152 ≈ 17 %, then a geometric tail of mean 2^14 = 16 KiB: a mean of about
0.17 × 40 + 0.83 × 80 ≈ 73 KiB (measured on random bytes: within 10 % of it, tested).

### Names, and each chunk stored once

A chunk's **name** is its **BLAKE2b-256** (Aumasson, Neves, Wilcox-O'Hearn, Winnerlein, "BLAKE2: simpler, smaller, fast
as MD5", ACNS 2013; RFC 7693) **keyed** by a key of its domain (libsodium's `crypto_generichash` with a key). A chunk
whose name the vault holds is not stored again: **deduplication**. 256 bits by the birthday bound: with n chunks,
P(two names alike) ≈ n² / 2^257; for 2^40 chunks (64 PiB) that is 2^-177; an adversary who makes files needs about
2^128 tries for a collision. A collision would let one chunk stand for another: so 256 bits, not 128.

The key matters for privacy. A plain hash of the bytes would let anyone who holds the vault's files test whether a
known file is there (hash it, look for the name), and two people's identical files would share a chunk: the known
weakness of deduplicated storage (Harnik, Pinkas, Shulman-Peleg, "Side Channels in Cloud Services: Deduplication in
Cloud Storage", IEEE Security & Privacy 2010; convergent encryption, Douceur et al., ICDCS 2002). Keyed by the owner's
domain, a name says nothing without the key, and chunks are deduplicated **inside a domain only**, never between two:
privacy before space (the design's choice 19).

A **domain** is the thing whose key seals a file: its owner (a person, a shared folder), or 0, the database's own.

### Compressed, warm or cold, never again

Each chunk is compressed when that saves at least 1/32 of it, else kept as it is:

- **warm** (the default): **LZ4** 1.10.0 (Collet), whose decoder runs at gigabytes a second;
- **cold** (`cold = true`): **Zstandard** 1.5.7 at level 9 (Collet, Kucherawy, RFC 8878), a third smaller on text,
  slower to write.

A chunk is compressed once, when it is stored; a read decodes it and never writes it again. Both libraries are the
official ones, fuzzed by OSS-Fuzz, vendored at those versions in `vendor/` and compiled with their symbols hidden
(the system's libcrypto links the system's libzstd, which keeps its own). The decision to use C for them, and the
measures behind it, are in the design (the OCaml LZ4 decoder written first ran at half liblz4's speed, and no Zstandard
decoder exists in OCaml). No entropy test chooses the codec: both codecs give up fast on bytes that do not compress
(LZ4 at over 3 GB/s on a PDF), so the test would cost more than it saves.

### Sealed: AEGIS-256 under the owner's key

Each domain has a random 32-byte key, kept in the vault's `keys` file sealed by the server's **master key** (32 bytes
in `vault.key`, beside `cluster.toml`, never in the data). From the domain's key, libsodium's `crypto_kdf` (BLAKE2b)
derives three subkeys: one names chunks, one names nodes, one seals.

A chunk is sealed by **AEGIS-256** (Wu and Preneel, "AEGIS: A Fast Authenticated Encryption Algorithm", SAC 2013;
draft-irtf-cfrg-aegis-aead), libsodium's `crypto_aead_aegis256`: an **authenticated encryption** whose 256-bit tag
checks every byte. Its 256-bit **nonce** (the number used once that an encryption needs) is the chunk's name: a
**synthetic nonce**, as SIV (Rogaway and Shrimpton, "A Provable-Security Treatment of the Key-Wrap Problem",
EUROCRYPT 2006): two encryptions under one key share a nonce only for the same bytes, which then give the same
sealed bytes. So a chunk is sealed into the same bytes wherever it is sealed, and a copy of a vault can be checked byte
for byte without its keys. The record's header (format, kind, codec, domain, raw length) and its name are
authenticated with it: a record moved, or a field changed, does not open.

Why AEGIS-256 rather than XChaCha20-Poly1305 (RFC 8439 with a 192-bit nonce), the usual choice: measured here with
libsodium 1.0.22 on 64 KiB, AEGIS-256 seals at 5.7 to 5.9 GB/s and opens at 5.8 GB/s, XChaCha20-Poly1305 at 1.1 GB/s
both ways (AES-256-GCM: 1.2 to 1.4 GB/s, and only a 96-bit nonce, too short to derive from a name). A 64 KiB chunk
opens in 11 µs rather than 58: a 4 KiB read of a file costs a fifth of what it would. AEGIS needs the processor's AES
instructions to be fast (every x86-64 since 2010 and every ARMv8 with its cryptography extension have them).

### Packs, and their indexes

Records are appended to **packs**, files of 64 MiB at most that are never changed once written (as the packs of Git
or restic): a file written in one go is laid out in one sequence, and read in one. A pack that is full is forced to
the disk, then its **index** is written beside it (each record's name, offset and length): an open reads the indexes,
not the packs. A pack without an index (the one being written when the process died) is read whole at the next open,
each record checked by its CRCs, forced (a process killed leaves records in the page cache that no fsync covered,
and a later file may find them stored and cite them), and indexed then; nothing is ever appended to it again, so no
byte that was written is ever written over. The table of names to places is in memory: about 100 bytes a record (a
TB of files at 73 KiB a chunk: 1.4 GB of memory; an index on disk is for later).

### A file is a tree of nodes

A file's chunks are listed by **nodes**: a node lists up to 1,024 children (a name and the bytes under it), a node of
level 0 lists chunks, a node of level k nodes of level k - 1. The **root** names the file: a file of 1 GB is about
14,000 chunks under 14 nodes under its root. A node is sealed and stored as a chunk is (and found again: two equal
files share their root). A range is read by walking from the root to the chunks under it, each node choosing its
children by a binary search of their ends: a 4 KiB read reads one chunk (two where it crosses a cut), whatever the
file's size. Nodes and chunks
once read are kept in memory, decoded (96 MiB, a third of it for nodes, by CLOCK: Corbató 1968): a chunk read again
is served without the disk, the tag or the codec, since it was checked when it was read. An erasure empties both, and
a hit is served only while its domain is not erased (a read that decoded a chunk just before an erasure may add it
after).

### Every read is checked

A chunk read from the disk is checked before any byte of it is given: its header's CRC-32C, the name it carries
(the one asked for: a record moved over another is refused), its tag (AEGIS-256 checks every byte, in constant time),
the codec's output length, and the CRC-32C of the raw bytes, kept inside the sealed bytes (a codec gone wrong is
refused too). A chunk that fails is an error `damaged`, never a byte served; storing the same file again rewrites a
damaged chunk (a chunk found stored is read again and checked before a new file cites it).

### Writing a file, and a crash

1. The writer cuts the bytes, names each chunk, and appends the chunks it does not find, then the nodes.
2. `finish` forces the pack (and, for a new pack, its directory), and only then returns the root. The fsync is
   shared by the puts that finish at once (**group commit**, as a database's log: Gray and Reuter, *Transaction
   Processing*, 1993, 9.4.7): it runs outside the lock that appends, one at a time; a put that finishes while
   another's fsync runs waits for it, and returns without one of its own when its records were appended before that
   fsync began. A failed fsync stops the vault (a later fsync may succeed without writing the pages the failed one
   dropped: Rebello et al., ATC 2020).
3. The server then writes the file's facts as any group (G1 to G3).

A crash before step 2 ends leaves chunks that no fact cites: they are harmless (and taken back by a later cleaning of
the vault, not built yet). A crash after it leaves a file whose bytes are all there, and maybe no facts yet. No fact
ever cites a chunk that is not on the disk ([G22](guarantees.md#g22-files-are-durable-before-their-facts)).

### Erasing an owner

`Erase(owner)` writes the keys' file again without the owner's key, and with a mark that the domain is erased (it is
never made again: a new file of that owner is refused). Every chunk of the owner's files is then sealed by a key that
exists nowhere: unreadable on this disk, in a replica, in a backup of the packs ("crypto-shredding"). What it does not
erase: the files' facts (their names, sizes, types) stay in the journal as any fact does, until the journal's own
erasure of personal values; and the old keys' file's blocks may stay on a flash disk or a copy-on-write file system
until they are reused. What destroys those for sure is a new master key (the keys sealed again under it, the old one
destroyed): not built yet.

### Copies: what a replica lacks, by Merkle trees

A replica needs the records it lacks, and only those. The vault's names are uniform 256-bit values: the first 16
bits put each in one of 65,536 leaves of a **Merkle tree** (Merkle, "A Digital Signature Based on a Conventional
Encryption Function", CRYPTO 1987), a leaf's digest the BLAKE2b-256 of its names sorted, a node's the BLAKE2b-256 of
its 16 children's (four levels under the root). Two copies compare their trees from the root down, only where the
digests differ, as the anti-entropy of Dynamo (DeCandia et al., SOSP 2007): for d records one copy lacks among n,
at most 64 digests a difference and the names of at most d leaves cross, rather than n names. Records are copied as
they are (sealed: the copy checks them by their CRCs, and needs no key to store them); the domains' keys go sealed by
the master key, which the copies of one cluster share, and an erasure goes with them. Built and tested between two
vaults of one process; the protocol between servers comes with replication (the server's design, section 8).

## Formats

```
DIR/vault/                      0700
DIR/vault/lock                  held while the vault is open
DIR/vault/keys                  "CPHVKEYS" | u32 format (1) | u32 CRC-32C of the 12 bytes before, then entries of 112 bytes:
                                  u32 CRC-32C of bytes 4-111 | u8 op (1 a key, 2 erased) | 3 zero bytes | u64 domain |
                                  a nonce (32) | the key sealed by the master key, AEGIS-256 (32 + 32), op and domain
                                  authenticated; written again whole (beside, renamed) by an erasure, appended otherwise
DIR/vault/packs/N.pack          "CPHVPACK" | u32 format | u32 CRC, then records
DIR/vault/packs/N.idx           "CPHVIDX1" | u32 format | u32 the pack's checked length | u32 count |
                                  (name 32 | u32 offset | u32 length) a record | u32 CRC-32C of everything before
record                          0  u32 CRC-32C of bytes 4-63      16 u32 raw length        32 the name (32 bytes)
                                4  u8 format (1)                  20 u32 sealed length
                                5  u8 kind: 1 chunk, 2 node       24 u32 CRC-32C of the sealed bytes
                                6  u8 codec: 0, 1 LZ4, 2 Zstd     28 u32 0
                                7  u8 0       8 u64 domain
                                then the sealed bytes: AEGIS-256 (nonce: the name; authenticated: bytes 4-19 and the
                                name) of u32 CRC-32C of the raw bytes | the codec's output
node (its raw bytes)            u8 level | varint count (<= 1024) | (name 32 | varint size) a child
```

All integers are little-endian. A file's `Content` fact is its root's name in 64 lower-case hexadecimal digits.

## Guarantees

- **G22 Files are durable before their facts.** A fact never cites a chunk or a node that is not on the disk: `finish`
  forces every record a file needs (and the name of a new pack) before it returns, and the facts are written after
  it; recovery never drops a forced record (a pack without its index is read again whole, nothing is cut).
- **G23 No wrong byte is served.** A byte of a file is given only from a record whose tag and raw CRC check, under the
  name asked for; otherwise `damaged`. A random change passes the tag with a probability of 2^-256.
- **G24 An erased owner's files are unreadable.** After `Erase`, no read of this vault, or of a copy that took its
  keys since, gives a byte of the owner's files: `erased`.

Their tests ([testing](testing.md#the-file-vault)): a power loss simulated at random points of puts (120 seeds, three
crashes each, torn and lost sectors, every file finished before it read back), `kill -9` of a process that puts files
of up to 40 MB and writes their facts (20 rounds: every cited file read back exact, every confirmed one there), bits
changed in packs, records moved over others, keys erased and copied.

## Security

| threat | what stops it | test |
|---|---|---|
| a byte changed on the disk, by a fault or a person | the tag (AEGIS-256) and the CRCs of every record read | damage tests, 20,000 records changed at random |
| a record moved or copied over another | the name in its header, authenticated, compared with the one asked for | the moved-record test |
| a copy of the data, a stolen disk | everything sealed; the domains' keys sealed by the master key, which is not in the data | the keys' file holds no plain key |
| guessing whether a file is stored (dedup as an oracle) | names keyed by the domain; no deduplication between domains | domains never share a chunk |
| a token that may not read the kind | Load checks the right on the kind's Content; a root is never taken from the client, only from the fact | rights tests of the server |
| an erased owner | the key gone from the keys' file, a domain never made again | erase tests |
| a huge file, many puts | 1 TiB a file, 4 puts at once a connection, names 4 KiB, types 255 bytes, frames 16 MiB | bounds tests |
| a malformed record, node or frame | every length checked before a byte is read or written; the codecs' outputs bounded; a Zstandard window of 1 MiB at most | the OCaml fuzzer, `test/fuzz_vault.c` under libFuzzer and the sanitizers, 24,000 changed requests |
| a key in a log | keys are never logged; the master key's file is refused if others may read it, or if it is a link | |
| timing | the tag is checked in constant time by libsodium; the master key's entries opened, not compared | |

The C the vault runs is the vendored LZ4 and Zstandard, libsodium, and `vault/vault_stubs.c` (a hundred lines that
convert values, with every offset checked in OCaml before the call), fuzzed with libFuzzer:

```text
clang -g -O1 -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=all -DCEPHEUS_VAULT_CORE_ONLY \
  -I vendor/zstd-1.5.7/lib test/fuzz_vault.c vault/vault_stubs.c vault/lz4_lib.c vault/zstd_lib.c -lsodium \
  -o fuzz_vault && ./fuzz_vault -max_len=300000 -max_total_time=300
```

## What it costs

Measured on the machine of the [benchmarks](benchmarks.md) (Intel i7-4720HQ of 2015, 4 cores, 11 GB, btrfs on a SATA
SSD), shared with other jobs, by `bench/vbench.exe`, 2026-11-13: 21 runs each, the median and its 97.3 % interval by
order statistics (as in the [benchmarks](benchmarks.md#method)). The bytes: the first 1 MB, 100 MB and 1 GB of 1 GiB of
the system's own files laid end to end (`/usr/lib`, `/usr/bin`, documentation, manual pages): programs, libraries and
text. Each put goes into a vault in use (its domain's key made), and ends when `finish` has forced it to the disk. A
**cold cache** is the packs' pages dropped from the kernel's page cache and the vault opened again (its own caches
empty); the file system is the same bytes read from one file by reads of 1 MiB.

**A file put and read whole** (MB/s, but the first two lines):

| | 1 MB | 100 MB | 1 GB |
|---|---|---|---|
| on disk, warm (LZ4) | 49.8 % | 55.1 % | 52.0 % |
| on disk, cold (Zstandard 9) | 33.6 % | 37.7 % | 35.8 % |
| put warm, 3 workers | 112 [78, 127] | 174 [138, 224] | 137 [111, 143] |
| put warm, one core | 77 [65, 92] | 111 [88, 125] | 104 [95, 116] |
| put cold | 44 [27, 56] | 64 [58, 68] | 64 [59, 70] |
| get warm, page cache | 865 [657, 961] | 1,119 [1,060, 1,183] | 784 [633, 834] |
| get warm, cold cache | 113 [88, 145] | 791 [676, 829] | 870 [747, 885] |
| get cold-stored, page cache | 503 [458, 544] | 512 [439, 551] | 541 [517, 578] |
| get cold-stored, cold cache | 109 [58, 152] | 460 [383, 486] | 546 [502, 574] |
| file system, page cache | 4,193 [3,626, 4,639] | 5,279 [4,611, 6,506] | 538 [452, 568] |
| file system, cold cache | 74 [67, 93] | 387 [336, 471] | 533 [409, 541] |

The column of 1 GB comes from the build before the chunk cache and the batches of a full buffer (a later run needs
more than the 3 GB the bench may take: it holds the whole 1 GiB in memory, which the server never does); at 100 MB that
build was slower or even on every line (put 144, 108 and 54 MB/s, get 971, 818, 509 and 510).

- **Put**: 100 to 175 MB/s warm, 44 to 64 cold. A put names every chunk by BLAKE2b (0.92 to 1.02 GB/s a core,
  measured), seals it and appends it; three workers run 1.3 to 1.6 times one core. LZ4 and AEGIS-256 are not what
  limits it (both several GB/s); Zstandard at level 9 is, for a cold put.
- **Get from memory**: 0.8 to 1.1 GB/s warm, 0.5 cold-stored (Zstandard's decoder). There **the file system wins**,
  about 5 times (at 1 MB and 100 MB; the file of 1 GB did not stay in the page cache): a copy from its cache against
  a tag checked, a decode and a CRC for every byte.
- **Get from the disk**: the vault reads half the bytes, so at 100 MB and 1 GB it reads faster than the file system
  (791 against 387 MB/s, 870 against 533). At 1 MB both pay their first reads (113 against 74).

**4 KiB at random places**, 21 runs of 1,000 reads (each run's median and 99th percentile, then their medians):

| | vault | file system (`pread`) |
|---|---|---|
| a file of 1 GB in the page cache: median | 80.8 µs [73.9, 94.9] | **2.86 µs** [2.15, 2.86] |
| its p99 | 451 µs [366, 568] | 508 µs [426, 646] |
| a file of 1 GB, memory shared (the file mostly out of the page cache): median | **123 µs** [98, 139] | 332 µs [314, 345] |
| its p99 | 1.14 ms [0.55, 2.95] | 812 µs [764, 879] |
| the first 8 MiB of the file (in the chunk cache): median | **0.95 µs** [0.95, 1.19] | 1.91 µs [1.91, 1.91] |
| its p99 | 2.15 µs [2.15, 4.05] | 2.15 µs [2.15, 6.91] |

A 4 KiB read decodes its whole chunk (73 KiB on average: read, tag, codec, CRC): 81 µs where the page cache gives the
file system's 4 KiB in 2.9 µs, the price of chunks that compress and are stored once. A chunk read again comes from
the chunk cache, with no system call: 0.95 µs. When memory is short, the vault's packs, half the size of the file, keep
more of themselves in the page cache: the second row.

**Many small files**: 400 files of 1 to 16 KiB, each put by itself, by 1, 4 and 16 threads at once (files a second):

| threads | an fsync each (before group commit) | group commit |
|---|---|---|
| 1 | 147 [125, 218] | 161 [60, 199] |
| 4 | 160 [113, 191] | 503 [385, 735] |
| 16 | 143 [115, 224] | **2,155** [1,900, 2,444] |

A put alone waits for its fsync (about 6 ms on this SSD: some 160 puts a second); puts at once share one, and 16
threads put 13 times as many files as one.

**Space on real files**, each set put into a fresh vault (one run: the bytes do not vary):

| files | bytes | on disk, warm | on disk, cold | chunks found stored |
|---|---|---|---|---|
| 1,339 images (PNG, JPEG) of a desktop | 390 MB | 48.0 % | 47.2 % | 2,269 (copies) |
| 421 logs | 50.5 MB | 21.0 % | 12.6 % | 216 |
| 1,408 source files | 7.6 MB | 54.7 % | 36.7 % | 166 |

Images are compressed already: what the vault saves on them is their copies. A small file costs a chunk and a node
(two records of 64 bytes of header and 32 of tag): for files of a few KiB, that is a few percent.

**What linking the vault costs the rest**: the `cepheus` program starts in 4.68 ms rather than 4.40 (21 rounds of 100
starts, alternated with the build without the vault: ratio 1.08), half of it libsodium (loaded and started) and half a
larger program. A server's ready time (11.0 against 10.8 ms), 20,000 pings, and point reads one and 16 in flight are
even (ratios 0.96 to 1.05, every interval holding 1). Cesia programs do not link the vault.

### Beside the giants (by their documentation)

- **PostgreSQL's large objects** cut a file into pages of `LOBLKSIZE` (a quarter of a block: 2 kB), a row each of
  `pg_largeobject`, read by ranges as here; they are not deduplicated and not sealed by an owner's key (PostgreSQL
  encrypts nothing at rest by itself). This changes no choice; it is why the vault's chunks are larger (a codec
  compresses a 64 KiB chunk much better than a 2 kB page).
- **An S3-like object store** keeps each object whole, read by ranges (HTTP `Range`), checked by a checksum of the
  object or its parts, and sealed with a key a request gives (SSE-C); two versions of an object share nothing. This
  changes no choice either: content-defined chunks are what lets a vault keep two versions of a file for the price
  of one and its edit.

## What it does not do yet

- **Cleaning**: chunks no fact cites (a put interrupted, the files of an erased owner) stay in the packs until a
  cleaning marks what the facts and the history cite and writes the packs again (as `restic prune`).
- **Replication between servers**: the comparison and the copy are built; the protocol, its TLA+ model (every chunk
  cited present on the replica), and the repair of a damaged chunk from a replica come with the replica of the
  server's step 6.
- **A new master key** (every domain's key sealed again), and the journal's erasure of personal facts.
- **An index of the names on disk** rather than in memory, for vaults of many terabytes.
