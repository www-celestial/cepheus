(* The file vault: the bytes of files, cut into content-defined chunks (Chunker, FastCDC), each named by its keyed
   BLAKE2b-256 and stored once in its key domain, compressed (LZ4 warm, Zstandard cold) and sealed (AEGIS-256), in
   packs that are only appended to. A file is a tree of nodes over its chunks (its root names it); the facts that
   describe it (name, size, type, owner, root) live in the database, written after the vault made its bytes durable.

   On disk, in DIR/vault (0700), all through a Disk.t (the simulated disk of the tests too):
     lock             held while the vault is open (one process)
     keys             the key of each domain sealed by the master key, and the domains erased (a log)
     packs/N.pack     records, appended; a pack is closed at 64 MiB
     packs/N.idx      the index of a closed pack: written once its pack is forced, so that an open reads the indexes
                      and not the packs

   A record (64 bytes of header, then the sealed payload):
     0  u32  CRC-32C of bytes 4-63          16 u32  raw length                 32  the name (32 bytes)
     4  u8   format (1)                     20 u32  sealed length (payload)
     5  u8   kind: 1 chunk, 2 node          24 u32  CRC-32C of the payload
     6  u8   codec: 0 none, 1 LZ4, 2 Zstd   28 u32  0
     7  u8   0
     8  u64  the key domain
   The payload is AEGIS-256 under the domain's encryption key, its nonce the name, the header's bytes 4-19 and the
   name authenticated with it, of: the CRC-32C of the raw bytes (u32), then the codec's output. Deterministic: a chunk
   is sealed into the same bytes wherever it is sealed (a synthetic nonce, as SIV: Rogaway and Shrimpton, EUROCRYPT
   2006), so a copy can be checked byte for byte. The name is keyed: without the domain's key it says nothing of the
   bytes, and two domains never share a chunk (deduplication inside a domain only: the design's choice 19).

   A read checks the tag (every byte, by libsodium, in constant time), decodes, and checks the raw bytes' CRC-32C:
   a byte changed on the disk, a record moved, or a codec that went wrong is an error, never a byte served. *)

open Cepheus

type error =
  | Missing of string  (** a chunk or node that the vault does not hold *)
  | Damaged of string  (** a record that does not check *)
  | Erased of int  (** a domain whose key was erased *)
  | Io of string
  | Invalid of string
  | Busy of string

exception Fail of error

let message = function
  | Missing m | Damaged m | Io m | Invalid m | Busy m -> m
  | Erased d -> Printf.sprintf "the files of domain %d were erased (its key is destroyed)" d

let fail e = raise (Fail e)
let failf k fmt = Printf.ksprintf (fun m -> fail (k m)) fmt

(* ---- layout ---- *)

let header = 64
let format = 1
let k_chunk = 1
let k_node = 2
let c_none = 0
let c_lz4 = 1
let c_zstd = 2

(* a node lists at most [fanout] children, each a name and a varint size: under 43 KB *)
let fanout = 1024
let max_node = 1 + 9 + (fanout * (32 + 9))
let max_raw = max Chunker.max_size max_node

(* the plain text of a payload: the raw bytes' CRC, then the codec's output (never larger than raw: else raw) *)
let max_plain = 4 + max_raw
let max_record = header + max_plain + Native.tag_bytes

let pack_magic = "CPHVPACK"
let idx_magic = "CPHVIDX1"
let keys_magic = "CPHVKEYS"
let file_header = 16
(* a pack is closed when its next record would pass 64 MiB (smaller in the tests) *)
let pack_limit = ref (64 lsl 20)

(* the cold codec's level: Zstandard 9 (measured in docs/book/vault.md) *)
let zstd_level = ref 9

let u32 b o = Int32.to_int (Bytes.get_int32_le b o) land 0xFFFF_FFFF
let set_u32 b o v = Bytes.set_int32_le b o (Int32.of_int v)

(* a location in the index: the pack, the offset, the record's length *)
let loc pack off len = (pack lsl 45) lor (off lsl 19) lor len
let loc_pack l = l lsr 45
let loc_off l = (l lsr 19) land ((1 lsl 26) - 1)
let loc_len l = l land ((1 lsl 19) - 1)

let hex s = String.concat "" (List.init (String.length s) (fun i -> Printf.sprintf "%02x" (Char.code s.[i])))
let short name = String.sub (hex name) 0 16

let of_hex s =
  let v c = match c with '0' .. '9' -> Char.code c - 48 | 'a' .. 'f' -> Char.code c - 87 | _ -> -1 in
  if String.length s <> 64 then None
  else
    let b = Bytes.create 32 in
    let ok = ref true in
    for i = 0 to 31 do
      let h = v s.[2 * i] and l = v s.[(2 * i) + 1] in
      if h < 0 || l < 0 then ok := false else Bytes.set b i (Char.chr ((h lsl 4) lor l))
    done;
    if !ok then Some (Bytes.to_string b) else None

(* ---- the vault ---- *)

type keys = { kname : string; knode : string; kenc : string }

type pack_reader = { rm : Mutex.t; mutable rfd : Disk.fd option }

(* the pack being written: [synced] its bytes forced, [named] its name forced in packs/; [users] the threads forcing it
   outside the writers' lock, which keep its descriptor open: a pack closed meanwhile ([retired]) is closed by the last *)
type active = {
  num : int;
  fd : Disk.fd;
  mutable size : int;
  entries : Buffer.t;
  mutable count : int;
  mutable synced : int;
  mutable named : bool;
  mutable users : int;
  mutable retired : bool;
}

type node = { level : int; names : string; ends : int array }

type t = {
  disk : Disk.t;
  dir : string;
  packs : string;
  master : string;
  wm : Mutex.t;  (* appends, sealing a pack, the keys' file *)
  sm : Mutex.t;  (* held by the one thread forcing the pack being written, outside wm (group commit) *)
  im : Mutex.t;  (* the tables below, held for a lookup or a store *)
  index : (string, int) Hashtbl.t;
  keys : (int, keys) Hashtbl.t;
  sealed_keys : (int, string) Hashtbl.t;  (* each domain's entry of the keys' file, as written *)
  erased : (int, unit) Hashtbl.t;
  mutable keys_fd : Disk.fd;
  mutable keys_size : int;
  mutable active : active option;
  mutable next_pack : int;
  mutable failed : string option;
  readers : (int, pack_reader) Hashtbl.t;
  (* decoded nodes and chunks (raw bytes), with their domain: read again without the disk, the tag or the codec *)
  nodes : (int * node) Clock.t;
  chunks : (int * Bytes.t) Clock.t;
  dctxs : Native.dctx list Atomic.t;
  mutable closed : bool;
  (* counts, for the measures and the status *)
  written : int Atomic.t;  (* records appended *)
  stored : int Atomic.t;  (* their bytes *)
  reused : int Atomic.t;  (* chunks found stored already *)
}

let lock_ m f = Mutex.protect m f
let pack_path t n = Filename.concat t.packs (Printf.sprintf "%08d.pack" n)
let idx_path t n = Filename.concat t.packs (Printf.sprintf "%08d.idx" n)

(* ---- keys ---- *)

let derive k = { kname = Native.derive k 1; kenc = Native.derive k 2; knode = Native.derive k 3 }

(* a keys' entry: u32 CRC of bytes 4-111, u8 op (1 a key, 2 erased), 3 zero bytes, u64 domain, a nonce of 32, the key
   sealed by the master key (64: the key and its tag), the op and domain authenticated *)
let key_entry = 112

let entry_ad op d = let b = Bytes.create 9 in Bytes.set_uint8 b 0 op; Bytes.set_int64_le b 1 (Int64.of_int d); Bytes.to_string b

let make_entry master op d key =
  let b = Bytes.make key_entry '\000' in
  Bytes.set_uint8 b 4 op;
  Bytes.set_int64_le b 8 (Int64.of_int d);
  if op = 1 then begin
    let nonce = Native.random 32 in
    Bytes.blit_string nonce 0 b 16 32;
    Native.seal ~key:master ~nonce ~ad:(entry_ad op d) (Bytes.of_string key) 0 32 b 48
  end;
  set_u32 b 0 (Crc32c.bytes b 4 (key_entry - 4));
  Bytes.to_string b

let keys_file_header () =
  let b = Bytes.make file_header '\000' in
  Bytes.blit_string keys_magic 0 b 0 8;
  set_u32 b 8 format;
  set_u32 b 12 (Crc32c.bytes b 0 12);
  b

let check_file_header b magic =
  Bytes.length b >= file_header && Bytes.sub_string b 0 8 = magic && u32 b 8 = format && u32 b 12 = Crc32c.bytes b 0 12

(* the keys' file: entries until the first that does not check; one that does not check followed by one that does is
   damage (refused: the domains after it would lose their files), a bad last one a torn tail (cut) *)
let load_keys t =
  let path = Filename.concat t.dir "keys" in
  if not (t.disk.exists path) then begin
    (* made whole or not at all (written beside, then renamed) *)
    Disk.write_file t.disk path (keys_file_header ());
    file_header
  end
  else
  let b = Disk.read_all t.disk path in
  let n = Bytes.length b in
  if not (check_file_header b keys_magic) then failf (fun m -> Damaged m) "%s: its header does not check" path
  else begin
    let good o = o + key_entry <= n && u32 b o = Crc32c.bytes b (o + 4) (key_entry - 4) in
    let rec go o =
      if o + key_entry > n then o
      else if good o then begin
        let op = Bytes.get_uint8 b (o + 4) and d = Int64.to_int (Bytes.get_int64_le b (o + 8)) in
        (match op with
         | 1 ->
           let key = Bytes.create 32 in
           if not (Native.open_ ~key:t.master ~nonce:(Bytes.sub_string b (o + 16) 32) ~ad:(entry_ad 1 d) b (o + 48) 64 key 0) then
             failf (fun m -> Invalid m) "%s: the master key does not open the key of domain %d (another vault's key?)" path d;
           Hashtbl.replace t.keys d (derive (Bytes.to_string key));
           Hashtbl.replace t.sealed_keys d (Bytes.sub_string b o key_entry)
         | 2 -> Hashtbl.remove t.keys d; Hashtbl.remove t.sealed_keys d; Hashtbl.replace t.erased d ()
         | _ -> failf (fun m -> Damaged m) "%s: an entry of an unknown kind at %d" path o);
        go (o + key_entry)
      end
      else begin
        let rec later p = p + key_entry <= n && (good p || later (p + key_entry)) in
        if later (o + key_entry) then failf (fun m -> Damaged m) "%s: the entry at %d does not check, and later ones do" path o;
        o
      end
    in
    let stop = go file_header in
    if stop < n then begin
      let fd = t.disk.openf path false in
      Fun.protect ~finally:(fun () -> t.disk.close fd) (fun () -> t.disk.truncate fd stop; t.disk.fsync fd)
    end;
    stop
  end

(* the keys of a domain, made (and forced to the disk before any record uses them) at its first file; under wm *)
let domain_keys t d =
  match lock_ t.im (fun () -> Hashtbl.find_opt t.keys d) with
  | Some k -> k
  | None ->
    if lock_ t.im (fun () -> Hashtbl.mem t.erased d) then fail (Erased d);
    let key = Native.random 32 in
    let e = make_entry t.master 1 d key in
    t.disk.pwrite t.keys_fd t.keys_size (Bytes.of_string e) 0 key_entry;
    t.disk.fsync t.keys_fd;
    t.keys_size <- t.keys_size + key_entry;
    let k = derive key in
    lock_ t.im (fun () -> Hashtbl.replace t.keys d k; Hashtbl.replace t.sealed_keys d e);
    k

let read_keys t d =
  match lock_ t.im (fun () -> Hashtbl.find_opt t.keys d, Hashtbl.mem t.erased d) with
  | Some k, _ -> k
  | None, true -> fail (Erased d)
  | None, false -> failf (fun m -> Damaged m) "a record of domain %d, whose key the vault does not hold" d

(* ---- records ---- *)

let ad_of (r : Bytes.t) o = Bytes.sub_string r (o + 4) 16 ^ Bytes.sub_string r (o + 32) 32

(* the record of [len] raw bytes of [src] at [off] into [r] (max_record bytes): its length. [plain] is scratch of
   max_plain bytes. *)
let encode ~kind ~codec ~domain ~(k : keys) ~name ~plain ~r ~cctx (src : Bytes.t) off len =
  set_u32 plain 0 (Crc32c.bytes src off len);
  let room = len - (len / 32) in
  let c, plen =
    let z =
      if codec = c_lz4 then Native.lz4_compress src off len plain 4 room
      else if codec = c_zstd then Native.zstd_compress (Option.get cctx) src off len plain 4 room
      else 0
    in
    if z > 0 then codec, 4 + z
    else begin
      Bytes.blit src off plain 4 len;
      c_none, 4 + len
    end
  in
  let sealed = plen + Native.tag_bytes in
  Bytes.fill r 0 header '\000';
  Bytes.set_uint8 r 4 format;
  Bytes.set_uint8 r 5 kind;
  Bytes.set_uint8 r 6 c;
  Bytes.set_int64_le r 8 (Int64.of_int domain);
  set_u32 r 16 len;
  set_u32 r 20 sealed;
  Bytes.blit_string name 0 r 32 32;
  Native.seal ~key:k.kenc ~nonce:name ~ad:(ad_of r 0) plain 0 plen r header;
  set_u32 r 24 (Crc32c.bytes r header sealed);
  set_u32 r 0 (Crc32c.bytes r 4 (header - 4));
  header + sealed

(* the header at [o] of [r] (the [n] bytes from it there) checks, and its lengths are in bounds: its record's length *)
let header_ok (r : Bytes.t) o n =
  n >= header
  && u32 r o = Crc32c.bytes r (o + 4) (header - 4)
  && Bytes.get_uint8 r (o + 4) = format
  && (let kind = Bytes.get_uint8 r (o + 5) and c = Bytes.get_uint8 r (o + 6) in
      (kind = k_chunk || kind = k_node) && c <= c_zstd)
  && u32 r (o + 16) <= max_raw
  && u32 r (o + 20) >= 4 + Native.tag_bytes
  && u32 r (o + 20) <= max_plain + Native.tag_bytes
  && header + u32 r (o + 20) <= n

let record_len r o = header + u32 r (o + 20)
let payload_ok (r : Bytes.t) o = u32 r (o + 24) = Crc32c.bytes r (o + header) (u32 r (o + 20))

let dctx t =
  let rec take () =
    match Atomic.get t.dctxs with
    | [] -> Native.dctx ()
    | d :: rest as l -> if Atomic.compare_and_set t.dctxs l rest then d else take ()
  in
  take ()

let give t d =
  let rec go () = let l = Atomic.get t.dctxs in if not (Atomic.compare_and_set t.dctxs l (d :: l)) then go () in
  go ()

(* the raw bytes of the record at [o] of [r] (checked: header, name, tag, length, CRC of the raw bytes): a fresh
   buffer of its raw length *)
let decode t (r : Bytes.t) o n ~kind ~name =
  if not (header_ok r o n) then failf (fun m -> Damaged m) "record %s: its header does not check" (short name);
  if Bytes.get_uint8 r (o + 5) <> kind || not (Bytes.sub_string r (o + 32) 32 = name) then
    failf (fun m -> Damaged m) "record %s: the record found there is another one" (short name);
  let domain = Int64.to_int (Bytes.get_int64_le r (o + 8)) and raw = u32 r (o + 16) and sealed = u32 r (o + 20) in
  let k = read_keys t domain in
  let plen = sealed - Native.tag_bytes in
  let plain = Bytes.create plen in
  if not (Native.open_ ~key:k.kenc ~nonce:name ~ad:(ad_of r o) r (o + header) sealed plain 0) then
    failf (fun m -> Damaged m) "record %s: its tag does not check (the bytes changed on the disk)" (short name);
  let out =
    match Bytes.get_uint8 r (o + 6) with
    | 0 -> if plen - 4 <> raw then failf (fun m -> Damaged m) "record %s: a raw length that does not match" (short name); Bytes.sub plain 4 raw
    | c ->
      let out = Bytes.create raw in
      let ok =
        if c = c_lz4 then Native.lz4_decompress plain 4 (plen - 4) out 0 raw
        else begin
          let d = dctx t in
          Fun.protect ~finally:(fun () -> give t d) (fun () -> Native.zstd_decompress d plain 4 (plen - 4) out 0 raw)
        end
      in
      if not ok then failf (fun m -> Damaged m) "record %s: its block does not decode" (short name);
      out
  in
  if Crc32c.bytes out 0 raw <> u32 plain 0 then failf (fun m -> Damaged m) "record %s: its bytes do not match their CRC" (short name);
  domain, out

(* ---- packs ---- *)

let reader t num =
  lock_ t.im (fun () ->
      match Hashtbl.find_opt t.readers num with
      | Some r -> r
      | None -> let r = { rm = Mutex.create (); rfd = None } in Hashtbl.replace t.readers num r; r)

(* at most this many packs open for reading: past it, those not being read are closed *)
let max_open = 64

let read_at t num off (b : Bytes.t) len =
  let r = reader t num in
  lock_ r.rm (fun () ->
      let fd =
        match r.rfd with
        | Some fd -> fd
        | None ->
          let opened = lock_ t.im (fun () -> Hashtbl.fold (fun _ x n -> if x.rfd <> None then n + 1 else n) t.readers 0) in
          if opened >= max_open then
            Hashtbl.iter
              (fun _ x ->
                if x != r && Mutex.try_lock x.rm then begin
                  (match x.rfd with Some f -> t.disk.close f; x.rfd <- None | None -> ());
                  Mutex.unlock x.rm
                end)
              (lock_ t.im (fun () -> Hashtbl.copy t.readers));
          let fd = t.disk.openf (pack_path t num) false in
          r.rfd <- Some fd;
          fd
      in
      t.disk.pread fd off b 0 len)

let read_record t l =
  let len = loc_len l in
  let b = Bytes.create len in
  read_at t (loc_pack l) (loc_off l) b len;
  b

let idx_entry = 40

(* the index of a pack, once its pack is forced: header (magic, format, the pack's checked length, the count), then
   name, offset and length a record, then the CRC of everything before *)
let write_idx t num len (entries : Buffer.t) count =
  let b = Buffer.create (24 + Buffer.length entries) in
  Buffer.add_string b idx_magic;
  let h = Bytes.create 12 in
  set_u32 h 0 format;
  set_u32 h 4 len;
  set_u32 h 8 count;
  Buffer.add_bytes b h;
  Buffer.add_buffer b entries;
  let body = Buffer.to_bytes b in
  let out = Bytes.create (Bytes.length body + 4) in
  Bytes.blit body 0 out 0 (Bytes.length body);
  set_u32 out (Bytes.length body) (Crc32c.bytes body 0 (Bytes.length body));
  Disk.write_file t.disk (idx_path t num) out

let add_entry (entries : Buffer.t) name off len =
  Buffer.add_string entries name;
  let b = Bytes.create 8 in
  set_u32 b 0 off;
  set_u32 b 4 len;
  Buffer.add_bytes entries b

let load_idx t num =
  let p = idx_path t num in
  if not (t.disk.exists p) then false
  else
    let b = Disk.read_all t.disk p in
    let n = Bytes.length b in
    n >= 24
    && Bytes.sub_string b 0 8 = idx_magic
    && u32 b (n - 4) = Crc32c.bytes b 0 (n - 4)
    && u32 b 8 = format
    && (let count = u32 b 16 in
        20 + (count * idx_entry) + 4 = n
        && (let fits i = let o = 20 + (i * idx_entry) in u32 b (o + 32) < 1 lsl 26 && u32 b (o + 36) <= max_record in
            let rec all i = i >= count || (fits i && all (i + 1)) in
            all 0)
        && begin
          for i = 0 to count - 1 do
            let o = 20 + (i * idx_entry) in
            Hashtbl.replace t.index (Bytes.sub_string b o 32) (loc num (u32 b (o + 32)) (u32 b (o + 36)))
          done;
          true
        end)

(* a pack without its index (it was being written at a crash, or its index was lost): every record read and checked,
   header and payload, those that check indexed, up to the first header that does not (the next record cannot be
   found); then the pack is forced (a process killed leaves records in the page cache that no fsync covered: a file
   that finds them stored must not cite bytes a power loss may take), and its index written: it is closed, and
   nothing is ever written to it again *)
let scan_pack t num =
  let b = Disk.read_all t.disk (pack_path t num) in
  let n = Bytes.length b in
  let entries = Buffer.create 4096 in
  let count = ref 0 in
  let stop =
    if not (check_file_header b pack_magic) then 0
    else
      let rec go o =
        if header_ok b o (n - o) then begin
          let len = record_len b o in
          if payload_ok b o then begin
            let name = Bytes.sub_string b (o + 32) 32 in
            Hashtbl.replace t.index name (loc num o len);
            add_entry entries name o len;
            incr count
          end;
          go (o + len)
        end
        else o
      in
      go file_header
  in
  let fd = t.disk.openf (pack_path t num) false in
  Fun.protect ~finally:(fun () -> t.disk.close fd) (fun () -> t.disk.fsync fd);
  write_idx t num stop entries !count

let pack_header () =
  let b = Bytes.make file_header '\000' in
  Bytes.blit_string pack_magic 0 b 0 8;
  set_u32 b 8 format;
  set_u32 b 12 (Crc32c.bytes b 0 12);
  b

(* under wm: the pack being written, made at the first record after an open or a pack closed *)
let active t =
  match t.active with
  | Some a -> a
  | None ->
    let num = t.next_pack in
    t.next_pack <- num + 1;
    let fd = t.disk.openf (pack_path t num) true in
    t.disk.truncate fd 0;
    t.disk.pwrite fd 0 (pack_header ()) 0 file_header;
    let a = { num; fd; size = file_header; entries = Buffer.create 65536; count = 0; synced = 0; named = false; users = 0; retired = false } in
    t.active <- Some a;
    a

(* under wm: the pack closed: forced with its name, its index written; the next record starts another. Its
   descriptor is closed by the last thread forcing it, if one is. *)
let close_active t =
  match t.active with
  | None -> ()
  | Some a ->
    if a.synced < a.size || not a.named then begin
      t.disk.fsync a.fd;
      if not a.named then t.disk.sync_dir t.packs;
      a.synced <- a.size;
      a.named <- true
    end;
    write_idx t a.num a.size a.entries a.count;
    t.active <- None;
    if a.users = 0 then t.disk.close a.fd else a.retired <- true

let check_writable t =
  if t.closed then fail (Invalid "the vault is closed");
  match t.failed with Some m -> failf (fun m -> Io m) "the vault stopped after a failure of the disk (%s): open it again" m | None -> ()

(* under wm: a record of [r] appended to the pack being written, and indexed *)
let append t name (r : Bytes.t) len =
  check_writable t;
  (try
     let a = active t in
     let a = if a.size + len > !pack_limit && a.count > 0 then (close_active t; active t) else a in
     t.disk.pwrite a.fd a.size r 0 len;
     add_entry a.entries name a.size len;
     a.count <- a.count + 1;
     let l = loc a.num a.size len in
     a.size <- a.size + len;
     lock_ t.im (fun () -> Hashtbl.replace t.index name l)
   with Disk.Io m as e -> t.failed <- Some m; raise e);
  Atomic.incr t.written;
  ignore (Atomic.fetch_and_add t.stored len)

(* Everything appended so far forced to the disk, with the pack's name: when it returns, every record appended before
   the call is durable. Group commit (as a database's log: Gray and Reuter, 1993, 9.4.7; Helland et al., HPTS 1987):
   the fsync is made outside wm, so that other puts append meanwhile, by one thread at a time (sm); a thread that
   waited finds its records forced by the fsync that ran meanwhile, if they were appended before it began, and
   returns without one of its own. A failed fsync stops the vault (its pages may be marked clean without reaching
   the disk: Rebello et al., ATC 2020): no later fsync is trusted. A pack closed meanwhile was forced when closed. *)
let force t =
  let target = lock_ t.wm (fun () -> check_writable t; Option.map (fun a -> a, a.size) t.active) in
  match target with
  | None -> ()
  | Some (a, size) ->
    lock_ t.sm (fun () ->
        let job =
          lock_ t.wm (fun () ->
              check_writable t;
              if a.synced >= size && a.named then None
              else begin
                a.users <- a.users + 1;
                Some (a.size, not a.named)
              end)
        in
        match job with
        | None -> ()
        | Some (upto, dir) ->
          let r = match t.disk.fsync a.fd; if dir then t.disk.sync_dir t.packs with () -> None | exception Disk.Io m -> Some m in
          lock_ t.wm (fun () ->
              a.users <- a.users - 1;
              (match r with
               | None -> a.synced <- max a.synced upto; if dir then a.named <- true
               | Some m -> t.failed <- Some m);
              if a.retired && a.users = 0 then try t.disk.close a.fd with Disk.Io _ -> ());
          Option.iter (fun m -> raise (Disk.Io m)) r)

(* the record of a name, if the vault holds it and it checks on the disk (header, name, payload CRC): read again
   before a chunk found stored is used for a new file, so that a damaged chunk is written anew, not cited *)
let holds t name =
  match lock_ t.im (fun () -> Hashtbl.find_opt t.index name) with
  | None -> false
  | Some l -> (
    match read_record t l with
    | r -> header_ok r 0 (Bytes.length r) && Bytes.sub_string r 32 32 = name && payload_ok r 0
    | exception Disk.Io _ -> false)

(* ---- sealing in parallel ---- *)

(* A put cuts its chunks in order (where a chunk ends depends on the bytes before it), then names and seals a batch of
   them on the workers, a few domains of the process shared by every put of every vault, and appends them in their
   order: the records are those of one chunk after the other, made in a fraction of the time. The calling thread
   works too. The workers are made at the first batch and live as long as the process (an idle one waits on a
   condition: it costs nothing). *)
type pool = { qm : Mutex.t; qc : Condition.t; q : (unit -> unit) Queue.t; mutable started : int }

let pool = { qm = Mutex.create (); qc = Condition.create (); q = Queue.create (); started = 0 }

let workers = ref (max 0 (min 3 (Domain.recommended_domain_count () - 1)))

let rec work p =
  Mutex.lock p.qm;
  while Queue.is_empty p.q do Condition.wait p.qc p.qm done;
  let f = Queue.pop p.q in
  Mutex.unlock p.qm;
  f ();
  work p

(* under p.qm: the workers asked for, made now if they are not yet *)
let start_workers p =
  while p.started < !workers do
    ignore (Domain.spawn (fun () -> work p));
    p.started <- p.started + 1
  done

(* every function of [fs] run, on the workers and here; the first exception raised again once all are done *)
let run_all (fs : (unit -> unit) array) =
  let n = Array.length fs in
  if n = 1 || !workers = 0 then Array.iter (fun f -> f ()) fs
  else begin
    let p = pool in
    let left = Atomic.make n and failed = Atomic.make None in
    let dm = Mutex.create () and dc = Condition.create () in
    let job f () =
      (try f () with e -> ignore (Atomic.compare_and_set failed None (Some e)));
      if Atomic.fetch_and_add left (-1) = 1 then Mutex.protect dm (fun () -> Condition.broadcast dc)
    in
    Mutex.protect p.qm (fun () -> start_workers p; Array.iter (fun f -> Queue.push (job f) p.q) fs; Condition.broadcast p.qc);
    (* this thread takes jobs too, then waits for the others *)
    let rec help () =
      match Mutex.protect p.qm (fun () -> Queue.take_opt p.q) with
      | Some f -> f (); help ()
      | None -> ()
    in
    help ();
    Mutex.protect dm (fun () -> while Atomic.get left > 0 do Condition.wait dc dm done);
    match Atomic.get failed with Some e -> raise e | None -> ()
  end

(* a context of Zstandard for each domain *)
let cctx_key = Domain.DLS.new_key (fun () -> Native.cctx !zstd_level)

(* ---- open, close ---- *)

let set_private (disk : Disk.t) dir = if disk == Disk.real then try Unix.chmod dir 0o700 with Unix.Unix_error _ -> ()

let guard f =
  match f () with
  | x -> Ok x
  | exception Fail e -> Error e
  | exception Disk.Io m -> Error (Io m)

(* [open_ disk dir ~master]: the vault in [dir] (made if missing), its keys opened by [master] (32 bytes, kept apart
   from the data: a copy of the data without it opens nothing) *)
let open_ ?(cache = 96 lsl 20) disk dir ~master =
  if String.length master <> 32 then Error (Invalid "a vault's master key is 32 bytes")
  else
    guard (fun () ->
        (* each directory made, its name forced in its parent: a vault whose name a power loss took would take the
           files its facts cite *)
        let rec mkdirs d =
          if not (disk.Disk.exists d) then (mkdirs (Filename.dirname d); disk.mkdir d; set_private disk d; disk.sync_dir (Filename.dirname d))
        in
        mkdirs dir;
        let packs = Filename.concat dir "packs" in
        if not (disk.exists packs) then (disk.mkdir packs; disk.sync_dir dir);
        let lock = Filename.concat dir "lock" in
        if not (disk.lock lock) then fail (Busy (dir ^ " is open in another process"));
        match
          let t =
            { disk; dir; packs; master; wm = Mutex.create (); sm = Mutex.create (); im = Mutex.create (); index = Hashtbl.create 4096; keys = Hashtbl.create 16;
              sealed_keys = Hashtbl.create 16; erased = Hashtbl.create 16; keys_fd = -1; keys_size = 0; active = None; next_pack = 1;
              failed = None; readers = Hashtbl.create 64; nodes = Clock.create (cache / 3); chunks = Clock.create (cache - (cache / 3)); dctxs = Atomic.make []; closed = false;
              written = Atomic.make 0; stored = Atomic.make 0; reused = Atomic.make 0 }
          in
          t.keys_size <- load_keys t;
          t.keys_fd <- disk.openf (Filename.concat dir "keys") false;
          let nums =
            List.filter_map
              (fun f -> if Filename.check_suffix f ".pack" then int_of_string_opt (Filename.chop_suffix f ".pack") else None)
              (disk.readdir packs)
            |> List.sort compare
          in
          List.iter (fun num -> if not (load_idx t num) then scan_pack t num) nums;
          t.next_pack <- 1 + List.fold_left max 0 nums;
          t
        with
        | t -> t
        | exception e -> disk.unlock lock; raise e)

let close t =
  lock_ t.wm (fun () ->
      if not t.closed then begin
        (try close_active t with Disk.Io _ -> ());
        t.closed <- true;
        Hashtbl.iter (fun _ r -> lock_ r.rm (fun () -> Option.iter t.disk.close r.rfd; r.rfd <- None)) t.readers;
        (try t.disk.close t.keys_fd with Disk.Io _ -> ());
        t.disk.unlock (Filename.concat t.dir "lock")
      end)

(* ---- writing a file ---- *)

type level = { lnames : Buffer.t; mutable lcount : int; mutable lbytes : int }

type writer = {
  v : t;
  domain : int;
  k : keys;
  codec : int;
  cctx : Native.cctx option;
  buf : Bytes.t;
  mutable start : int;
  mutable fill : int;
  mutable levels : level array;
  mutable total : int;
  plain : Bytes.t;
  r : Bytes.t;
  mutable finished : bool;
  mutable cut : (int * int) list;  (* chunks cut, not yet stored: offset and length in [buf], newest first *)
}

let buf_size = 4 lsl 20

(* a writer of one file into a domain: [cold] for files read seldom (Zstandard, a third smaller on text than LZ4,
   slower to write); the domain's key is made at its first file. Nothing is visible until [finish]. *)
let writer t ~domain ~cold =
  guard (fun () ->
      if domain < 0 then fail (Invalid "a domain is a number >= 0");
      let k = lock_ t.wm (fun () -> check_writable t; domain_keys t domain) in
      { v = t; domain; k; codec = (if cold then c_zstd else c_lz4); cctx = (if cold then Some (Native.cctx !zstd_level) else None);
        buf = Bytes.create buf_size; start = 0; fill = 0; levels = [||]; total = 0; plain = Bytes.create max_plain;
        r = Bytes.create max_record; finished = false; cut = [] })

let level w i =
  if i >= Array.length w.levels then
    w.levels <- Array.append w.levels (Array.init (i + 1 - Array.length w.levels) (fun _ -> { lnames = Buffer.create 4096; lcount = 0; lbytes = 0 }));
  w.levels.(i)

(* a record written unless the vault holds it already (and it checks); sealed outside the writers' lock, which only
   the append holds (another writer may have stored the same chunk meanwhile: it is not written twice) *)
let store w ~kind name (src : Bytes.t) off len =
  if holds w.v name then Atomic.incr w.v.reused
  else begin
    let n = encode ~kind ~codec:(if kind = k_node then c_none else w.codec) ~domain:w.domain ~k:w.k ~name ~plain:w.plain ~r:w.r ~cctx:w.cctx src off len in
    lock_ w.v.wm (fun () -> if holds w.v name then Atomic.incr w.v.reused else append w.v name w.r n)
  end

let rec push w i name size =
  let l = level w i in
  Buffer.add_string l.lnames name;
  Codec.put_varint l.lnames size;
  l.lcount <- l.lcount + 1;
  l.lbytes <- l.lbytes + size;
  if l.lcount = fanout then ignore (emit w i)

(* the node of level i: [level][count][name, size ...], named by the domain's node key *)
and emit w i =
  let l = w.levels.(i) in
  let b = Buffer.create (Buffer.length l.lnames + 12) in
  Buffer.add_char b (Char.chr i);
  Codec.put_varint b l.lcount;
  Buffer.add_buffer b l.lnames;
  let node = Buffer.to_bytes b in
  let name = Native.hash ~key:w.k.knode node 0 (Bytes.length node) in
  store w ~kind:k_node name node 0 (Bytes.length node);
  let bytes = l.lbytes in
  Buffer.clear l.lnames;
  l.lcount <- 0;
  l.lbytes <- 0;
  push w (i + 1) name bytes;
  name

let chunk w len =
  w.cut <- (w.start, len) :: w.cut;
  w.start <- w.start + len

(* the chunks cut so far: named on the workers; those the vault does not hold sealed there; appended in order *)
let flush w =
  let cs = Array.of_list (List.rev w.cut) in
  w.cut <- [];
  let n = Array.length cs in
  if n > 0 then begin
    let names = Array.make n "" in
    run_all (Array.mapi (fun i (o, l) () -> names.(i) <- Native.hash ~key:w.k.kname w.buf o l) cs);
    let fresh = Array.map (fun name -> if holds w.v name then (Atomic.incr w.v.reused; false) else true) names in
    let recs = Array.make n (Bytes.empty, 0) in
    run_all
      (Array.mapi
         (fun i (o, l) () ->
           if fresh.(i) then begin
             let plain = Bytes.create (4 + l) and r = Bytes.create (header + 4 + l + Native.tag_bytes) in
             let cctx = if w.codec = c_zstd then Some (Domain.DLS.get cctx_key) else None in
             recs.(i) <- r, encode ~kind:k_chunk ~codec:w.codec ~domain:w.domain ~k:w.k ~name:names.(i) ~plain ~r ~cctx w.buf o l
           end)
         cs);
    lock_ w.v.wm (fun () ->
        Array.iteri
          (fun i name ->
            (* stored meanwhile by another put (it checks), or not: a damaged record is written anew *)
            if fresh.(i) then
              if lock_ w.v.im (fun () -> Hashtbl.mem w.v.index name) && holds w.v name then Atomic.incr w.v.reused
              else (let r, len = recs.(i) in append w.v name r len))
          names);
    Array.iteri (fun i name -> push w 0 name (snd cs.(i))) names
  end

(* the bytes of a file, in pieces of any size *)
let feed w (b : Bytes.t) off len =
  if off < 0 || len < 0 || off > Bytes.length b - len then invalid_arg "Vault.feed";
  guard (fun () ->
      if w.finished then fail (Invalid "this file is finished already");
      let o = ref off and n = ref len in
      while !n > 0 do
        if w.fill = buf_size then begin
          Bytes.blit w.buf w.start w.buf 0 (w.fill - w.start);
          w.fill <- w.fill - w.start;
          w.start <- 0
        end;
        let k = min !n (buf_size - w.fill) in
        Bytes.blit b !o w.buf w.fill k;
        w.fill <- w.fill + k;
        o := !o + k;
        n := !n - k;
        while w.fill - w.start >= Chunker.max_size do chunk w (Chunker.cut w.buf w.start (w.fill - w.start)) done;
        (* the chunks cut are stored before the buffer moves: batches of about 55 chunks for the workers *)
        if w.fill = buf_size then flush w
      done;
      w.total <- w.total + len)

(* the file's root and size, once every record it needs is on the disk (forced, and its pack's name): only then may
   a fact cite it (G22) *)
let finish w =
  guard (fun () ->
      if w.finished then fail (Invalid "this file is finished already");
      w.finished <- true;
      while w.fill > w.start do chunk w (Chunker.cut w.buf w.start (w.fill - w.start)) done;
      flush w;
      if Array.length w.levels = 0 then ignore (level w 0);
      (* each level but the top one closed into the one above; the top one, unless it is a single node, is the root *)
      let rec close i =
        let top = i = Array.length w.levels - 1 in
        let l = w.levels.(i) in
        if top && i > 0 && l.lcount = 1 then String.sub (Buffer.contents l.lnames) 0 32
        else if top then emit w i
        else begin
          if l.lcount > 0 then ignore (emit w i);
          close (i + 1)
        end
      in
      let root = close 0 in
      force w.v;
      root, w.total)

(* ---- reading ---- *)

(* a node's plain text: checked whole (its tag checked already: this is against our own mistakes and for the
   fuzzer): a level, at most [fanout] children, each a name and a size > 0, a chunk's at most [Chunker.max_size] *)
let parse_node name (b : Bytes.t) =
    let bad () = failf (fun m -> Damaged m) "node %s: it does not parse" (short name) in
    let rd = Codec.reader b 0 (Bytes.length b) in
    let n =
      match
        let level = Codec.get_byte rd in
        let count = Codec.get_varint rd in
        if count > fanout || level > 8 then bad ();
        let names = Bytes.create (32 * count) and ends = Array.make count 0 in
        let total = ref 0 in
        for i = 0 to count - 1 do
          if rd.stop - rd.pos < 32 then bad ();
          Bytes.blit rd.buf rd.pos names (32 * i) 32;
          rd.pos <- rd.pos + 32;
          let s = Codec.get_varint rd in
          if s <= 0 || (level = 0 && s > Chunker.max_size) || s > max_int / 2 - !total then bad ();
          total := !total + s;
          ends.(i) <- !total
        done;
        if not (Codec.at_end rd) then bad ();
        { level; names = Bytes.to_string names; ends }
      with
      | n -> n
      | exception Codec.Short -> bad ()
    in
    n

(* a domain erased meanwhile: what the caches hold of it is not served (an erasure clears them, but a read that
   decoded before it may add to them after) *)
let live t d = if lock_ t.im (fun () -> Hashtbl.mem t.erased d) then fail (Erased d)

let node_of t name =
  match Clock.find t.nodes name with
  | Some (d, n) -> live t d; n
  | None ->
    let l = match lock_ t.im (fun () -> Hashtbl.find_opt t.index name) with Some l -> l | None -> failf (fun m -> Missing m) "node %s is not in the vault" (short name) in
    let r = read_record t l in
    let d, b = decode t r 0 (Bytes.length r) ~kind:k_node ~name in
    let n = parse_node name b in
    Clock.add t.nodes name (d, n) (Bytes.length b + 64);
    n

let node_size n = let c = Array.length n.ends in if c = 0 then 0 else n.ends.(c - 1)

(* a chunk's raw bytes, from the cache or read and checked; a reader of them never changes them *)
let chunk_of t name =
  match Clock.find t.chunks name with
  | Some (d, b) -> live t d; b
  | None ->
    let l = match lock_ t.im (fun () -> Hashtbl.find_opt t.index name) with Some l -> l | None -> failf (fun m -> Missing m) "chunk %s is not in the vault" (short name) in
    let r = read_record t l in
    let d, b = decode t r 0 (Bytes.length r) ~kind:k_chunk ~name in
    Clock.add t.chunks name (d, b) (Bytes.length b + 64);
    b

let size t root = guard (fun () -> node_size (node_of t root))

(* the bytes [from, from + len) of the file of [root], in order, in pieces given to [f b off len] (a piece is valid
   during the call only): only the chunks that cover the range are read *)
let load t root ~from ~len f =
  guard (fun () ->
      let rootn = node_of t root in
      let size = node_size rootn in
      if from < 0 || len < 0 || from > size - len then failf (fun m -> Invalid m) "the range %d+%d is outside the file (%d bytes)" from len size;
      let lo = from and hi = from + len in
      (* the node [n] of [name] starts at [base] in the file and has [expect] bytes *)
      let rec walk n name base expect =
        if node_size n <> expect then failf (fun m -> Damaged m) "node %s: its size is not the one its parent gives" (short name);
        let count = Array.length n.ends in
        (* the first child that ends after lo *)
        let rec first a b = if a >= b then a else let m = (a + b) / 2 in if base + n.ends.(m) <= lo then first (m + 1) b else first a m in
        let i = ref (first 0 count) in
        while !i < count && base + (if !i = 0 then 0 else n.ends.(!i - 1)) < hi do
          let s = base + (if !i = 0 then 0 else n.ends.(!i - 1)) in
          let e = base + n.ends.(!i) in
          let child = String.sub n.names (32 * !i) 32 in
          if n.level = 0 then begin
            let b = chunk_of t child in
            if Bytes.length b <> e - s then failf (fun m -> Damaged m) "chunk %s: its length is not the one its node gives" (short child);
            let a = max lo s and z = min hi e in
            f b (a - s) (z - a)
          end
          else begin
            let c = node_of t child in
            if c.level <> n.level - 1 then failf (fun m -> Damaged m) "node %s: a child of another level" (short child);
            walk c child s (e - s)
          end;
          incr i
        done
      in
      if len > 0 then walk rootn root 0 size)

(* ---- erasing a domain (crypto-shredding) ---- *)

(* The domain's key destroyed: its files can no longer be read anywhere its records went (copies, backups), since
   the key was only in this file, sealed by the master key. The file is written anew without it, and with a mark
   that the domain is erased (a domain is never made again). The old file's blocks may stay on a flash disk or a
   copy-on-write file system until they are reused: what destroys them for sure is a new master key (the keys
   sealed again under it), after which the old master key is destroyed. *)
let erase t d =
  guard (fun () ->
      lock_ t.wm (fun () ->
          check_writable t;
          if not (lock_ t.im (fun () -> Hashtbl.mem t.erased d)) then begin
            let b = Buffer.create 4096 in
            Buffer.add_bytes b (keys_file_header ());
            let kept = lock_ t.im (fun () -> Hashtbl.fold (fun x e l -> if x = d then l else (x, e) :: l) t.sealed_keys []) in
            List.iter (fun (_, e) -> Buffer.add_string b e) (List.sort compare kept);
            let gone = d :: lock_ t.im (fun () -> Hashtbl.fold (fun x () l -> x :: l) t.erased []) in
            List.iter (fun x -> Buffer.add_string b (make_entry t.master 2 x "")) (List.sort compare gone);
            let path = Filename.concat t.dir "keys" in
            (try
               t.disk.close t.keys_fd;
               Disk.write_file t.disk path (Buffer.to_bytes b);
               t.keys_fd <- t.disk.openf path false
             with Disk.Io m as e -> t.failed <- Some m; raise e);
            t.keys_size <- Buffer.length b;
            lock_ t.im (fun () -> Hashtbl.remove t.keys d; Hashtbl.remove t.sealed_keys d; Hashtbl.replace t.erased d ());
            Clock.clear t.nodes;
            Clock.clear t.chunks
          end))

(* ---- copies: what replication needs ---- *)

(* every record's name *)
let names t = lock_ t.im (fun () -> Hashtbl.fold (fun n _ l -> n :: l) t.index [])

(* the record of a name as it is on the disk, checked (header, name, payload CRC) without its key: a copy is made of
   the sealed bytes, never of plain text *)
let raw t name =
  guard (fun () ->
      match lock_ t.im (fun () -> Hashtbl.find_opt t.index name) with
      | None -> failf (fun m -> Missing m) "record %s is not in the vault" (short name)
      | Some l ->
        let r = read_record t l in
        if not (header_ok r 0 (Bytes.length r) && Bytes.sub_string r 32 32 = name && payload_ok r 0) then
          failf (fun m -> Damaged m) "record %s does not check on the disk" (short name);
        r)

(* a record of another copy appended as it is, once its header and payload check (it is the same bytes everywhere:
   its nonce is its name), unless this vault holds it; forced with [sync] *)
let add_raw t (r : Bytes.t) =
  guard (fun () ->
      let n = Bytes.length r in
      if not (header_ok r 0 n && record_len r 0 = n && payload_ok r 0) then fail (Damaged "a record that does not check");
      let name = Bytes.sub_string r 32 32 in
      lock_ t.wm (fun () -> if not (lock_ t.im (fun () -> Hashtbl.mem t.index name)) then append t name r n))

let sync t = guard (fun () -> force t)

(* the keys' entries (each domain's key sealed by the master key, and the domains erased), to give a copy that has
   the same master key *)
let key_entries t =
  lock_ t.im (fun () ->
      Hashtbl.fold (fun _ e l -> e :: l) t.sealed_keys [] @ Hashtbl.fold (fun d () l -> make_entry t.master 2 d "" :: l) t.erased [])

(* another copy's entries taken: the keys this vault lacks (they must open under its master key), and the domains
   erased there erased here *)
let take_keys t entries =
  guard (fun () ->
      List.iter
        (fun e ->
          let b = Bytes.of_string e in
          if String.length e <> key_entry || u32 b 0 <> Crc32c.bytes b 4 (key_entry - 4) then fail (Damaged "a key entry that does not check");
          let d = Int64.to_int (Bytes.get_int64_le b 8) in
          match Bytes.get_uint8 b 4 with
          | 2 -> ( match erase t d with Ok () -> () | Error x -> fail x)
          | 1 ->
            lock_ t.wm (fun () ->
                check_writable t;
                if not (lock_ t.im (fun () -> Hashtbl.mem t.keys d || Hashtbl.mem t.erased d)) then begin
                  let key = Bytes.create 32 in
                  if not (Native.open_ ~key:t.master ~nonce:(Bytes.sub_string b 16 32) ~ad:(entry_ad 1 d) b 48 64 key 0) then
                    failf (fun m -> Invalid m) "the key of domain %d is sealed by another master key" d;
                  t.disk.pwrite t.keys_fd t.keys_size b 0 key_entry;
                  t.disk.fsync t.keys_fd;
                  t.keys_size <- t.keys_size + key_entry;
                  lock_ t.im (fun () -> Hashtbl.replace t.keys d (derive (Bytes.to_string key)); Hashtbl.replace t.sealed_keys d e)
                end)
          | _ -> fail (Damaged "a key entry of an unknown kind"))
        entries)

(* ---- for the measures and the tests ---- *)

let records t = lock_ t.im (fun () -> Hashtbl.length t.index)
let written t = Atomic.get t.written
let stored t = Atomic.get t.stored
let reused t = Atomic.get t.reused
