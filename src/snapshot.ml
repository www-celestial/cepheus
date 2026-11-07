(* A snapshot is a compacted base written as its pages lie in memory, so that reading one decodes nothing. A file: a
   header page, the base's pages (16 KiB each, the last one padded with zeros), then one CRC-32C a page. At open, the
   header, the CRC table and the offset tables are checked (G7); every page is checked against its CRC each time it
   is read from the disk, so a damaged page is never served, even one damaged after the open. A snapshot that fits in
   the cache is read whole at open (every page checked, the cache warm); a larger one is read page by page as the
   questions need it. A snapshot that does not check is set aside: the database falls back on an older snapshot or
   on the journal, which is always the truth.

     header (4096 B): magic "CPHS" | format | database id | group | next thing | journal segment | journal offset
                      | n | ne | np | ns | text bytes | body length | crc of the crc table | crc of the header *)

let magic = 0x53485043 (* "CPHS" *)
let format = 3
let header = 4096
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
  let body = b.len and np = Pages.count b.pg in
  let h = Bytes.make header '\000' in
  let set i x = Bytes.set_int64_le h i (Int64.of_int x) in
  Bytes.set_int32_le h 0 (Int32.of_int magic);
  Bytes.set_int32_le h 4 (Int32.of_int format);
  Bytes.blit_string id 0 h 8 16;
  List.iteri (fun k x -> set (24 + (8 * k)) x)
    [ v.group; v.next_e; pos.segment; pos.offset; b.n; b.ne; b.np; b.ns; b.sblob; body ];
  let table = Bytes.create (4 * np) in
  let path = Filename.concat dir (name v.group) in
  let tmp = path ^ ".tmp" in
  if disk.Disk.exists tmp then disk.remove tmp;
  let fd = disk.openf tmp true in
  Fun.protect ~finally:(fun () -> disk.close fd) (fun () ->
      disk.truncate fd 0;
      for k = 0 to np - 1 do
        let p = Pages.page b.pg k in
        Bytes.set_int32_le table (4 * k) (Int32.of_int (Crc32c.bytes p 0 Pages.size));
        disk.pwrite fd (header + (k * Pages.size)) p 0 Pages.size
      done;
      disk.pwrite fd (header + (np * Pages.size)) table 0 (Bytes.length table);
      Bytes.set_int32_le h 104 (Int32.of_int (Crc32c.bytes table 0 (Bytes.length table)));
      Bytes.set_int32_le h 108 (Int32.of_int (Crc32c.bytes h 0 108));
      disk.pwrite fd 0 h 0 header;
      disk.fsync fd);
  disk.rename tmp path;
  disk.sync_dir dir;
  (* keep the newest few: they are caches, the journal is the truth *)
  let old = List.rev (list disk dir) in
  List.iteri (fun i g -> if i >= keep then disk.remove (Filename.concat dir (name g))) old;
  if List.length old > keep then disk.sync_dir dir

exception Bad of string

let bad fmt = Printf.ksprintf (fun s -> raise (Bad s)) fmt

(* Checks a snapshot's header, CRC table and offset tables and builds its base, read through the cache; raises Bad. *)
let check_and_build disk path id =
  let fd = disk.Disk.openf path false in
  match
    let size = disk.size fd in
    if size < header then bad "shorter than its header";
    let h = Bytes.create header in
    disk.pread fd 0 h 0 header;
    if u32 h 0 <> magic then bad "not a snapshot";
    if u32 h 108 <> Crc32c.bytes h 0 108 then bad "its header does not check";
    if u32 h 4 <> format then bad "unknown format %d" (u32 h 4);
    if Bytes.sub_string h 8 16 <> id then bad "a snapshot of another database";
    let g k = Int64.to_int (Bytes.get_int64_le h (24 + (8 * k))) in
    let group = g 0 and next_e = g 1 and seg = g 2 and off = g 3 in
    let n = g 4 and ne = g 5 and np = g 6 and ns = g 7 and sblob = g 8 and body = g 9 in
    if List.exists (fun x -> x < 0) [ n; ne; np; ns; sblob; body ] || np > Schema.first_thing then bad "bad counts";
    let npages = Pages.pages body in
    if size < header + (npages * Pages.size) + (4 * npages) then bad "shorter than its header says";
    let table = Bytes.create (4 * npages) in
    disk.pread fd (header + (npages * Pages.size)) table 0 (4 * npages);
    if u32 h 104 <> Crc32c.bytes table 0 (4 * npages) then bad "its checksum table does not check";
    let load k =
      let p = Bytes.create Pages.size in
      (try disk.pread fd (header + (k * Pages.size)) p 0 Pages.size with Disk.Io m -> raise (Pages.Unreadable m));
      if Crc32c.bytes p 0 Pages.size <> u32 table (4 * k) then
        raise (Pages.Unreadable (Printf.sprintf "snapshot %s: page %d does not check" (Filename.basename path) k));
      p
    in
    let pg = Pages.on_file body load in
    if disk == Disk.real then Gc.finalise (fun _ -> try disk.close fd with Disk.Io _ -> ()) pg;
    let b = Store.layout ~pg ~n ~ne ~np ~ns ~sblob () in
    if b.len <> body then bad "its layout does not match its size";
    (* small enough: every page read and checked now, and the cache warm *)
    if npages <= !Pages.capacity then for k = 0 to npages - 1 do ignore (Pages.page pg k) done;
    (* bounds: every offset table in order and within its rows; a row's ids are checked by its page's CRC, and a
       read out of a base's pages fails, it never reads outside *)
    let mono get count total what =
      let prev = ref 0 in
      for i = 0 to count do
        let x = get b i in
        if x < !prev || x > total then bad "%s is out of order" what;
        prev := x
      done;
      if get b count <> total then bad "%s does not end at %d" what total
    in
    mono (Store.safe Store.eoff) ne n "the thing offsets";
    mono (Store.safe Store.poff) np n "the property offsets";
    mono (Store.safe Store.soff) ns sblob "the text offsets";
    let v = Store.of_base ~group ~next_e b in
    let schema = ref Schema.initial in
    for p = Schema.first_prop to min ne Schema.first_thing - 1 do
      if Store.safe Store.eoff b p < Store.safe Store.eoff b (p + 1) then
        match Resolve.read_prop v p with
        | Ok d -> schema := Schema.set !schema p d
        | Error m -> bad "%s" m
    done;
    { v with schema = !schema }, { Journal.segment = seg; offset = off; next = group + 1 }
  with
  | r -> r
  | exception e -> (try disk.close fd with Disk.Io _ -> ()); raise e

(* The newest snapshot that checks; the reasons the newer ones were set aside. *)
let load disk dir id =
  let notes = ref [] in
  let rec go = function
    | [] -> None
    | g :: rest -> (
      let path = Filename.concat dir (name g) in
      let aside m = notes := Printf.sprintf "snapshot %s set aside: %s" (name g) m :: !notes; go rest in
      match check_and_build disk path id with
      | r -> Some r
      | exception Bad m -> aside m
      | exception Pages.Unreadable m -> aside m
      | exception Disk.Io m -> aside m
      | exception Invalid_argument m -> aside m)
  in
  let r = go (List.rev (list disk dir)) in
  r, List.rev !notes
