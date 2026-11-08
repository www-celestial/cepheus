(* A snapshot is a base, sorted and columnar, in the pages a reader reads it by: a level of the LSM tree. Every base
   but the empty one is a snapshot file, and a merge is the one way to make one: it streams the merged facts (the old
   base, read through the cache, and the delta) into a new file, page by page, so that it needs only the cache and a
   few page buffers, whatever the size of the base. A file: a header page, the base's pages (16 KiB each, the last one
   padded with zeros), then one CRC-32C a page. At open, the header, the CRC table and the offset tables are checked
   (G7); every page is checked against its CRC each time it is read from the disk, so a damaged page is never served,
   even one damaged after the open. A snapshot that fits in the cache is read whole at open; a larger one is read page
   by page as the questions need it. A snapshot that does not check is set aside: the database falls back on an older
   snapshot or on the journal, which is always the truth.

     header (4096 B): magic "CPHS" | format | database id | group | next thing | journal segment | journal offset
                      | journal group at that offset | n | ne | np | ns | text bytes | body length
                      | crc of the crc table | crc of the header

   Replay after a snapshot starts at the journal position, whose first group may come before the snapshot's own
   (a merge in the background starts from a view that runs ahead of the disk): the groups up to the snapshot's are
   skipped.

   A merge installs its file atomically (G12): written under a temporary name, forced, renamed, its directory forced;
   only then the oldest snapshots are removed. A crash at any point leaves the old base or the new one, whole. *)

let magic = 0x53485043 (* "CPHS" *)
let format = 4
let header = 4096
let keep = 2

let name group = Printf.sprintf "%020d.snap" group
let tmp_suffix = ".tmp"
let u32 b i = Int32.to_int (Bytes.get_int32_le b i) land 0xFFFFFFFF

let list disk dir =
  List.filter_map
    (fun n -> if Filename.check_suffix n ".snap" && String.length n = 25 then int_of_string_opt (String.sub n 0 20) else None)
    (disk.Disk.readdir dir)

(* ---- writing a merge, page by page ----
   The sections of the new base are written by streams side by side, each in order; a page is complete once every
   byte of it is written (two sections can share a page), and goes out at once: its CRC, its pwrite, the cache. The
   pages open at any time are those under the streams' heads and the pages two sections share: a handful. *)

type acc = { buf : Bytes.t; mutable filled : int }

type out = {
  disk : Disk.t;
  fd : Disk.fd;
  mutable unforced : int;  (* bytes written since the last fsync *)
  busy : unit -> bool;  (* the journal wrote a frame lately: clients wait for its fsyncs *)
  len : int;  (* body bytes *)
  crcs : Bytes.t;  (* one CRC-32C a page, the table at the end of the file and the loader's check *)
  pg : Pages.t;
  open_pages : (int, acc) Hashtbl.t;
}

let open_max = ref 0 (* the most pages open at once in a merge of this process: for the tests *)

(* While clients write, a merge forces its file every [sync_every] bytes rather than once at the end: the disk then
   never holds hundreds of MB of a merge's dirty pages for a journal fsync to wait behind (measured at 3 M facts with
   merges beside the writes: the journal's fsync p99.9 1.6 s and max 4.7 s with one fsync at the end, 0.43 s and 1.0 s
   forced every 8 MiB; RocksDB's bytes_per_sync answers the same). Each fsync costs a merge time (a merge of 10 M
   facts: 2.8 s forced once, 10 s forced every 8 MiB), so a merge nobody waits beside (a snapshot, a recovery) forces
   once. *)
let sync_every = ref (8 lsl 20)

let complete o k a =
  Hashtbl.remove o.open_pages k;
  Bytes.set_int32_le o.crcs (4 * k) (Int32.of_int (Crc32c.bytes a.buf 0 Pages.size));
  o.disk.Disk.pwrite o.fd (header + (k * Pages.size)) a.buf 0 Pages.size;
  o.unforced <- o.unforced + Pages.size;
  if o.unforced >= !sync_every && o.busy () then begin
    o.disk.fsync o.fd;
    o.unforced <- 0
  end;
  Pages.admit o.pg k a.buf

let need o k = min Pages.size (o.len - (k lsl Pages.bits))

let page_acc o k =
  match Hashtbl.find_opt o.open_pages k with
  | Some a -> a
  | None ->
    let a = { buf = Bytes.make Pages.size '\000'; filled = 0 } in
    Hashtbl.replace o.open_pages k a;
    if Hashtbl.length o.open_pages > !open_max then open_max := Hashtbl.length o.open_pages;
    a

(* a stream writes one section from [pos] to [stop]; [from]: where it started in its current page *)
type stream = { o : out; mutable pos : int; stop : int; mutable k : int; mutable a : acc; mutable from : int }

let no_page = { buf = Bytes.empty; filled = 0 }
let stream o off bytes = { o; pos = off; stop = Store.al (off + bytes); k = -1; a = no_page; from = off }

let leave s =
  if s.k >= 0 then begin
    s.a.filled <- s.a.filled + (s.pos - s.from);
    if s.a.filled = need s.o s.k then complete s.o s.k s.a
  end

let[@inline never] enter s =
  leave s;
  if s.pos >= s.stop then invalid_arg "Snapshot.merge: a section overflows";
  s.k <- s.pos lsr Pages.bits;
  s.a <- page_acc s.o s.k;
  s.from <- s.pos

(* writes of 2, 4 and 8 bytes are aligned to their size in a section that starts at a multiple of 8: none crosses a
   page *)
let[@inline] at s w =
  if s.pos lsr Pages.bits <> s.k then enter s;
  let o = s.pos land Pages.mask in
  s.pos <- s.pos + w;
  o

let put64 s x = let o = at s 8 in Bytes.set_int64_le s.a.buf o (Int64.of_int x)
let put32 s x = let o = at s 4 in Bytes.set_int32_le s.a.buf o (Int32.of_int x)
let put16 s x = let o = at s 2 in Bytes.set_uint16_le s.a.buf o x
let put8 s c = let o = at s 1 in Bytes.unsafe_set s.a.buf o c

(* the end of a section: its padding is zeros already; it must end where the layout says *)
let close s =
  if s.pos > s.stop || Store.al s.pos <> s.stop then invalid_arg "Snapshot.merge: a section is not the size of its layout";
  s.pos <- s.stop;
  leave s;
  s.k <- -1

type written = { tmp : string; path : string; group : int; view : Store.view }

(* The merge of [v]'s base and delta into a new snapshot file at v.group, with [pos] the journal position replay
   starts from (pos.next <= v.group + 1). Written under a temporary name and forced (also on the way, while [busy]
   says clients write); [install] gives it its name. On a failure of the disk, the file is removed and the failure
   raised. *)
let merge ?(busy = fun () -> false) disk dir id (v : Store.view) (pos : Journal.position) =
  if pos.next > v.group + 1 then invalid_arg "Snapshot.merge: the journal position is after the view";
  let ob = v.base in
  let n = Store.facts v and ne = Store.max_thing v + 1 and np = Schema.count v.schema and ns = v.dict.dnext in
  let sblob = ref ob.sblob in
  for i = ob.ns to ns - 1 do sblob := !sblob + String.length (Store.text v i) done;
  let lay = Store.layout ~n ~ne ~np ~ns ~sblob:!sblob () in
  let npages = Pages.pages lay.len in
  let path = Filename.concat dir (name v.group) in
  let tmp = path ^ tmp_suffix in
  if disk.Disk.exists tmp then disk.remove tmp;
  let fd = disk.openf tmp true in
  let crcs = Bytes.create (4 * npages) in
  let load k =
    let p = Bytes.create Pages.size in
    (try disk.pread fd (header + (k * Pages.size)) p 0 Pages.size with Disk.Io m -> raise (Pages.Unreadable m));
    if Crc32c.bytes p 0 Pages.size <> u32 crcs (4 * k) then
      raise (Pages.Unreadable (Printf.sprintf "snapshot %s: page %d does not check" (Filename.basename path) k));
    p
  in
  let pg = Pages.on_file lay.len load in
  let o = { disk; fd; unforced = 0; busy; len = lay.len; crcs; pg; open_pages = Hashtbl.create 16 } in
  let failed () = (try disk.close fd with Disk.Io _ -> ()); (try disk.remove tmp with Disk.Io _ -> ()) in
  match
    disk.truncate fd 0;
    (* by thing: the offsets, then each thing's rows (property, value), in order *)
    let eoff = stream o lay.o_eoff (8 * (ne + 1)) and eap = stream o lay.o_eap (2 * n)
    and eav = stream o lay.o_eav (8 * n) in
    let c = ref 0 in
    for e = 0 to ne - 1 do
      put64 eoff !c;
      Store.iter_facts v e (fun p w -> put16 eap p; put64 eav w; incr c)
    done;
    put64 eoff !c;
    if !c <> n then invalid_arg "Snapshot.merge: the facts by thing do not add up";
    List.iter close [ eoff; eap; eav ];
    (* by property: the offsets, the rows (value, thing) in order, the distinct values *)
    let poff = stream o lay.o_poff (8 * (np + 1)) and avv = stream o lay.o_avv (8 * n)
    and ave = stream o lay.o_ave (4 * n) and pdist = stream o lay.o_pdist (8 * np) in
    let c = ref 0 in
    for p = 0 to np - 1 do
      put64 poff !c;
      let d = ref 0 and last = ref 0 and start = !c in
      Store.iter_prop_sorted v p (fun e w ->
          put64 avv w;
          put32 ave e;
          if !c = start || w <> !last then incr d;
          last := w;
          incr c);
      put64 pdist !d
    done;
    put64 poff !c;
    if !c <> n then invalid_arg "Snapshot.merge: the facts by property do not add up";
    List.iter close [ poff; avv; ave; pdist ];
    (* the dictionary: texts by id, and the ids in text order *)
    let soff = stream o lay.o_soff (8 * (ns + 1)) and sb = stream o lay.o_sblob !sblob
    and ssort = stream o lay.o_ssort (4 * ns) in
    let off = ref 0 in
    for i = 0 to ns - 1 do
      put64 soff !off;
      let t = Store.text v i in
      String.iter (put8 sb) t;
      off := !off + String.length t
    done;
    put64 soff !off;
    let c = ref 0 in
    Store.iter_texts_sorted v (fun i -> put32 ssort i; incr c);
    if !c <> ns then invalid_arg "Snapshot.merge: the sorted texts do not add up";
    List.iter close [ soff; sb; ssort ];
    if Hashtbl.length o.open_pages <> 0 then invalid_arg "Snapshot.merge: a page was left unwritten";
    (* the CRC table, the header, and the file forced *)
    disk.pwrite fd (header + (npages * Pages.size)) crcs 0 (4 * npages);
    let h = Bytes.make header '\000' in
    Bytes.set_int32_le h 0 (Int32.of_int magic);
    Bytes.set_int32_le h 4 (Int32.of_int format);
    Bytes.blit_string id 0 h 8 16;
    List.iteri
      (fun k x -> Bytes.set_int64_le h (24 + (8 * k)) (Int64.of_int x))
      [ v.group; v.next_e; pos.segment; pos.offset; pos.next; n; ne; np; ns; !sblob; lay.len ];
    Bytes.set_int32_le h 112 (Int32.of_int (Crc32c.bytes crcs 0 (4 * npages)));
    Bytes.set_int32_le h 116 (Int32.of_int (Crc32c.bytes h 0 116));
    disk.pwrite fd 0 h 0 header;
    disk.fsync fd
  with
  | () ->
    if disk == Disk.real then Gc.finalise (fun _ -> try disk.close fd with Disk.Io _ -> ()) pg;
    let b = Store.layout ~pg ~n ~ne ~np ~ns ~sblob:!sblob () in
    { tmp; path; group = v.group; view = Store.of_base ~schema:v.schema ~group:v.group ~next_e:v.next_e b }
  | exception (Disk.Io _ as e) -> failed (); raise e
  | exception (Pages.Unreadable _ as e) -> failed (); raise e

(* The file takes its name (G12): renamed over, the directory forced; then the snapshots beyond the newest [keep]
   are removed (they are caches: the journal is the truth). *)
let install disk dir w =
  disk.Disk.rename w.tmp w.path;
  disk.sync_dir dir;
  let old = List.rev (list disk dir) in
  List.iteri (fun i g -> if i >= keep then disk.remove (Filename.concat dir (name g))) old;
  if List.length old > keep then disk.sync_dir dir

(* A merge not installed (the database stopped, or the disk failed): its file goes. *)
let abandon disk w = try if disk.Disk.exists w.tmp then disk.remove w.tmp with Disk.Io _ -> ()

(* At open: the files of merges a crash interrupted. *)
let clean disk dir =
  let stray = List.filter (fun n -> Filename.check_suffix n tmp_suffix) (disk.Disk.readdir dir) in
  List.iter (fun n -> disk.remove (Filename.concat dir n)) stray;
  if stray <> [] then disk.sync_dir dir

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
    if u32 h 116 <> Crc32c.bytes h 0 116 then bad "its header does not check";
    if u32 h 4 <> format then bad "unknown format %d" (u32 h 4);
    if Bytes.sub_string h 8 16 <> id then bad "a snapshot of another database";
    let g k = Int64.to_int (Bytes.get_int64_le h (24 + (8 * k))) in
    let group = g 0 and next_e = g 1 and seg = g 2 and off = g 3 and next = g 4 in
    let n = g 5 and ne = g 6 and np = g 7 and ns = g 8 and sblob = g 9 and body = g 10 in
    if List.exists (fun x -> x < 0) [ n; ne; np; ns; sblob; body ] || np > Schema.first_thing then bad "bad counts";
    if next < 1 || next > group + 1 then bad "its journal position is after its group";
    let npages = Pages.pages body in
    if size < header + (npages * Pages.size) + (4 * npages) then bad "shorter than its header says";
    let table = Bytes.create (4 * npages) in
    disk.pread fd (header + (npages * Pages.size)) table 0 (4 * npages);
    if u32 h 112 <> Crc32c.bytes table 0 (4 * npages) then bad "its checksum table does not check";
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
    { v with schema = !schema }, { Journal.segment = seg; offset = off; next }
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
