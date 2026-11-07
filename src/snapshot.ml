(* A snapshot is a compacted base written as it lies in memory, so that loading is a mapping of the file with nothing
   to decode. A file: a header page, the base's bytes, then one CRC-32C per MiB of the body. Every CRC is checked and
   the offset tables are checked for order and bounds before the first question (G7): a damaged snapshot is never
   served; the database falls back on an older snapshot or on the journal, which is always the truth.

     header (4096 B): magic "CPHS" | format | database id | group | next thing | journal segment | journal offset
                      | n | ne | np | ns | text bytes | body length | crc of the crc table | crc of the header *)

open Bigarray

let magic = 0x53485043 (* "CPHS" *)
let format = 2
let header = 4096
let block = 1 lsl 20
let keep = 2

let name group = Printf.sprintf "%020d.snap" group
let u32 b i = Int32.to_int (Bytes.get_int32_le b i) land 0xFFFFFFFF

let list disk dir =
  List.filter_map
    (fun n -> if Filename.check_suffix n ".snap" && String.length n = 25 then int_of_string_opt (String.sub n 0 20) else None)
    (disk.Disk.readdir dir)

let write disk dir id (v : Store.view) (pos : Journal.position) =
  if v.delta.dn <> 0 then invalid_arg "Snapshot.write: the view is not compacted";
  let b = v.base in
  let body = b.len in
  let nblocks = (body + block - 1) / block in
  let h = Bytes.make header '\000' in
  let set i x = Bytes.set_int64_le h i (Int64.of_int x) in
  Bytes.set_int32_le h 0 (Int32.of_int magic);
  Bytes.set_int32_le h 4 (Int32.of_int format);
  Bytes.blit_string id 0 h 8 16;
  List.iteri (fun k x -> set (24 + (8 * k)) x)
    [ v.group; v.next_e; pos.segment; pos.offset; b.n; b.ne; b.np; b.ns; b.sblob; body ];
  let table = Bytes.create (4 * nblocks) in
  for k = 0 to nblocks - 1 do
    let lo = k * block in
    Bytes.set_int32_le table (4 * k) (Int32.of_int (Crc32c.bigstring b.buf lo (min block (body - lo))))
  done;
  Bytes.set_int32_le h 104 (Int32.of_int (Crc32c.bytes table 0 (Bytes.length table)));
  Bytes.set_int32_le h 108 (Int32.of_int (Crc32c.bytes h 0 108));
  let path = Filename.concat dir (name v.group) in
  let tmp = path ^ ".tmp" in
  if disk.Disk.exists tmp then disk.remove tmp;
  let fd = disk.openf tmp true in
  Fun.protect ~finally:(fun () -> disk.close fd) (fun () ->
      disk.truncate fd 0;
      disk.pwrite fd 0 h 0 header;
      let chunk = Bytes.create block in
      let off = ref 0 in
      while !off < body do
        let len = min block (body - !off) in
        for i = 0 to len - 1 do
          Bytes.unsafe_set chunk i (Array1.unsafe_get b.buf (!off + i))
        done;
        disk.pwrite fd (header + !off) chunk 0 len;
        off := !off + len
      done;
      disk.pwrite fd (header + Store.al body) table 0 (Bytes.length table);
      disk.fsync fd);
  disk.rename tmp path;
  disk.sync_dir dir;
  (* keep the newest few: they are caches, the journal is the truth *)
  let old = List.rev (list disk dir) in
  List.iteri (fun i g -> if i >= keep then disk.remove (Filename.concat dir (name g))) old;
  if List.length old > keep then disk.sync_dir dir

exception Bad of string

let bad fmt = Printf.ksprintf (fun s -> raise (Bad s)) fmt

(* Checks a mapped file and builds its base; raises Bad. *)
let check_and_build id (f : Disk.bigstring) =
  let size = Array1.dim f in
  if size < header then bad "shorter than its header";
  let h = Bytes.create header in
  for i = 0 to header - 1 do Bytes.unsafe_set h i (Array1.unsafe_get f i) done;
  if u32 h 0 <> magic then bad "not a snapshot";
  if u32 h 108 <> Crc32c.bytes h 0 108 then bad "its header does not check";
  if u32 h 4 <> format then bad "unknown format %d" (u32 h 4);
  if Bytes.sub_string h 8 16 <> id then bad "a snapshot of another database";
  let g k = Int64.to_int (Bytes.get_int64_le h (24 + (8 * k))) in
  let group = g 0 and next_e = g 1 and seg = g 2 and off = g 3 in
  let n = g 4 and ne = g 5 and np = g 6 and ns = g 7 and sblob = g 8 and body = g 9 in
  if List.exists (fun x -> x < 0) [ n; ne; np; ns; sblob; body ] || np > Schema.first_thing then bad "bad counts";
  let nblocks = (body + block - 1) / block in
  if size < header + Store.al body + (4 * nblocks) then bad "shorter than its header says";
  let table = Bytes.create (4 * nblocks) in
  for i = 0 to (4 * nblocks) - 1 do Bytes.unsafe_set table i (Array1.unsafe_get f (header + Store.al body + i)) done;
  if u32 h 104 <> Crc32c.bytes table 0 (4 * nblocks) then bad "its checksum table does not check";
  let buf = Array1.sub f header (max 1 body) in
  for k = 0 to nblocks - 1 do
    let lo = k * block in
    if Crc32c.bigstring buf lo (min block (body - lo)) <> u32 table (4 * k) then bad "block %d does not check" k
  done;
  let b = Store.layout ~buf ~n ~ne ~np ~ns ~sblob () in
  if b.len <> body then bad "its layout does not match its size";
  (* bounds: every offset table in order and within its rows, every id in range; then every access stays inside *)
  let mono get count total what =
    let prev = ref 0 in
    for i = 0 to count do
      let x = get b i in
      if x < !prev || x > total then bad "%s is out of order" what;
      prev := x
    done;
    if get b count <> total then bad "%s does not end at %d" what total
  in
  mono Store.eoff ne n "the thing offsets";
  mono Store.poff np n "the property offsets";
  mono Store.soff ns sblob "the text offsets";
  for i = 0 to n - 1 do
    if Store.eap b i >= np || Store.ave b i >= ne then bad "fact %d is out of range" i
  done;
  for i = 0 to ns - 1 do
    if Store.ssort b i >= ns then bad "the text order is out of range"
  done;
  let v = Store.of_base ~group ~next_e b in
  let schema = ref Schema.initial in
  for p = Schema.first_prop to min ne Schema.first_thing - 1 do
    if Store.eoff b p < Store.eoff b (p + 1) then
      match Resolve.read_prop v p with
      | Ok d -> schema := Schema.set !schema p d
      | Error m -> bad "%s" m
  done;
  { v with schema = !schema }, { Journal.segment = seg; offset = off; next = group + 1 }

(* The newest snapshot that checks; the reasons the newer ones were set aside. *)
let load disk dir id =
  let notes = ref [] in
  let rec go = function
    | [] -> None
    | g :: rest -> (
      let path = Filename.concat dir (name g) in
      match check_and_build id (disk.Disk.map path) with
      | r -> Some r
      | exception Bad m ->
        notes := Printf.sprintf "snapshot %s set aside: %s" (name g) m :: !notes;
        go rest
      | exception Disk.Io m ->
        notes := Printf.sprintf "snapshot %s set aside: %s" (name g) m :: !notes;
        go rest
      | exception Invalid_argument m ->
        notes := Printf.sprintf "snapshot %s set aside: %s" (name g) m :: !notes;
        go rest)
  in
  let r = go (List.rev (list disk dir)) in
  r, List.rev !notes
