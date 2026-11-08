exception Damaged of string

type position = { segment : int; offset : int; next : int }

let seg_magic = 0x4A485043 (* "CPHJ" *)
let frame_magic = 0x46485043 (* "CPHF" *)
let tail_magic = 0x54485043 (* "CPHT" *)
let format = 1
let seg_header = 40
let fh = 28
let ft = 16
let max_body = 1 lsl 28
let segment_limit = ref (64 * 1024 * 1024)

(* where the time of an append goes, in microseconds: for the benchmarks (one writer: the syncer) *)
let write_us = Histogram.create ()
let fsync_us = Histogram.create ()
let clock () = int_of_float (Unix.gettimeofday () *. 1e6)

type t = {
  disk : Disk.t;
  dir : string;
  id : string;
  mutable fd : Disk.fd;
  mutable seg : int;  (* first group of the current segment *)
  mutable size : int;  (* end of the current segment *)
  mutable next : int;  (* the next group number *)
  mutable closed : bool;
  mutable failed : bool;  (* a write or fsync failed: never used again (G10) *)
}

let damaged fmt = Printf.ksprintf (fun s -> raise (Damaged s)) fmt
let segment_name first = Printf.sprintf "%020d.seg" first
let path dir first = Filename.concat dir (segment_name first)
let u32 b i = Int32.to_int (Bytes.get_int32_le b i) land 0xFFFFFFFF
let set32 b i x = Bytes.set_int32_le b i (Int32.of_int x)

let segments disk dir =
  List.filter_map
    (fun n ->
      if Filename.check_suffix n ".seg" && String.length n = 24 then int_of_string_opt (String.sub n 0 20) else None)
    (disk.Disk.readdir dir)

let write_segment_header disk dir id first =
  let b = Bytes.make seg_header '\000' in
  set32 b 0 seg_magic;
  set32 b 4 format;
  Bytes.blit_string id 0 b 8 16;
  Bytes.set_int64_le b 24 (Int64.of_int first);
  set32 b 36 (Crc32c.bytes b 0 36);
  let fd = disk.Disk.openf (path dir first) true in
  match
    disk.truncate fd 0;
    disk.pwrite fd 0 b 0 seg_header;
    disk.fsync fd;
    disk.sync_dir dir
  with
  | () -> fd
  | exception (Disk.Io _ as e) -> (try disk.close fd with Disk.Io _ -> ()); raise e

(* the header of a segment: Some first group if it checks, None if short or bad (torn) *)
let read_header b id name =
  if Bytes.length b < seg_header || u32 b 0 <> seg_magic || u32 b 36 <> Crc32c.bytes b 0 36 then None
  else if u32 b 4 <> format then damaged "%s: unknown format %d" name (u32 b 4)
  else if Bytes.sub_string b 8 16 <> id then damaged "%s: a segment of another database" name
  else Some (Int64.to_int (Bytes.get_int64_le b 24))

let frame_ok b p size =
  size - p >= fh
  && u32 b p = frame_magic
  && u32 b (p + 24) = Crc32c.bytes b p 24
  &&
  let len = u32 b (p + 4) in
  len <= max_body && p + fh + len + ft <= size && Crc32c.bytes b (p + fh) len = u32 b (p + 20)

(* Was the frame at p written whole although it does not check? A valid frame anywhere after p, or a trailer whose
   length field puts its frame exactly at p. *)
let written_after b p size =
  let found = ref false and q = ref (p + 1) in
  while (not !found) && !q + 4 <= size do
    let w = u32 b !q in
    (* a frame header that checks, after p: that frame was written after the one at p was forced *)
    if w = frame_magic && !q + fh <= size && u32 b (!q + 24) = Crc32c.bytes b !q 24 then found := true
    else if w = tail_magic then begin
      (* a trailer whose length and body checksum match the bytes between p and it: the frame was written whole and
         only its header changed; a torn write cannot do that unless it lost the header's sector alone *)
      let ts = !q - 12 in
      if ts >= p + fh && u32 b ts = ts - p - fh && Crc32c.bytes b (p + fh) (ts - p - fh) = u32 b (ts + 4) then found := true
    end;
    incr q
  done;
  !found

let trailer_ok b p =
  let len = u32 b (p + 4) in
  let t = p + fh + len in
  u32 b (t + 12) = tail_magic && u32 b t = len && u32 b (t + 4) = u32 b (p + 20) && u32 b (t + 8) = u32 b (p + 24)

(* What a scan found in one segment. *)
type seg = {
  first : int;
  file : string;
  stop : int;  (* end of the last good frame *)
  torn : bool;  (* bytes after [stop] to cut *)
  bad_trailers : int list;  (* starts of intact frames whose trailer is broken *)
}

(* Read-only, but for [before]: checks the segments from [from] and calls [on_group] on each group. A torn tail is
   allowed only in the newest segment; a torn header only in a newest segment that holds nothing. [before path b]
   runs on the newest segment's bytes before any of its groups is replayed. *)
let scan ?(frame = fun _ -> ()) ?(before = fun _ _ -> ()) disk dir id from on_group =
  let all = segments disk dir in
  let segs = match from with None -> all | Some f -> List.filter (fun s -> s >= f.segment) all in
  (match from, segs with
   | Some f, s :: _ when s = f.segment -> ()
   | Some f, _ -> damaged "journal: segment %s, where the snapshot starts, is missing" (segment_name f.segment)
   | None, s :: _ when s <> 1 -> damaged "journal: the first segment starts at group %d" s
   | None, _ -> ());
  let expect = ref (match from, segs with Some f, _ -> f.next | None, s :: _ -> s | None, [] -> 1) in
  let rec go acc = function
    | [] -> List.rev acc, None
    | s :: rest ->
      let name = segment_name s in
      let b = Disk.read_all disk (path dir s) in
      let size = Bytes.length b in
      let resume = match from with Some f -> f.segment = s | None -> false in
      if s <> !expect && not resume then damaged "journal: %s does not follow group %d (a segment is missing)" name (!expect - 1);
      if rest = [] then before (path dir s) b;
      (match read_header b id name with
       | None ->
         if rest <> [] then damaged "journal: %s has a broken header" name;
         List.rev acc, Some s
       | Some first ->
         if first <> s then damaged "journal: %s says it starts at group %d" name first;
         let start = match from with Some f when f.segment = s -> f.offset | _ -> seg_header in
         if start < seg_header || start > size then damaged "journal: %s is shorter than the snapshot says" name;
         let bad = ref [] in
         let rec loop p =
           if p = size then p, false
           else if frame_ok b p size then begin
             let len = u32 b (p + 4) in
             let f0 = Int64.to_int (Bytes.get_int64_le b (p + 8)) and count = u32 b (p + 16) in
             if f0 <> !expect then damaged "%s: frame at %d starts at group %d, expected %d" name p f0 !expect;
             frame { segment = s; offset = p; next = f0 };
             let r = Codec.reader b (p + fh) len in
             (try
                for _ = 1 to count do
                  let g = Group.decode r in
                  if g.Group.n <> !expect then damaged "%s: group %d where %d was expected" name g.Group.n !expect;
                  on_group g;
                  incr expect
                done
              with Codec.Short -> damaged "%s: frame at %d does not decode" name p);
             if not (Codec.at_end r) then damaged "%s: frame at %d has bytes after its groups" name p;
             if not (trailer_ok b p) then bad := p :: !bad;
             loop (p + fh + len + ft)
           end
           else if written_after b p size then damaged "%s: damaged frame at offset %d (written whole)" name p
           else if rest <> [] then damaged "%s: segment ends with a broken frame at %d" name p
           else p, true
         in
         let stop, torn = loop start in
         go ({ first = s; file = path dir s; stop; torn; bad_trailers = !bad } :: acc) rest)
  in
  let found, torn_header = go [] segs in
  found, torn_header, !expect

(* Where the newest frame of a segment starts: the last frame whose header checks, walking the frames by their lengths
   from the segment's header; 0 if there is none. *)
let newest_frame b =
  let size = Bytes.length b in
  let rec go p last =
    if size - p >= fh && u32 b p = frame_magic && u32 b (p + 24) = Crc32c.bytes b p 24
       && u32 b (p + 4) <= max_body && p + fh + u32 b (p + 4) + ft <= size
    then go (p + fh + u32 b (p + 4) + ft) p
    else last
  in
  if size >= seg_header then go seg_header 0 else 0

(* What the last process may have left off the disk, written again and forced, before anything rests on it (G5, G12,
   G13). A process killed between the pwrite of a frame and its fsync, or between the creation of a segment and the
   fsync of its directory, leaves them in the page cache, where recovery reads them and a power loss takes them back.
   And after a failed fsync, Linux marks the pages clean without writing them (Rebello et al., ATC 2020): ext4 and XFS
   keep their new bytes in memory, so a later fsync succeeds without writing them, and recovery would read a frame
   the disk does not hold. Written again, the pages are dirty again, and the fsync writes them (on Btrfs, which undoes
   a failed write in memory too, the bytes read are the disk's: writing them again changes nothing). Only the newest
   frame can be off the disk, or the newest segment's header if it holds no frame: frames are written one at a time,
   each forced before the next, and the writer stops at the first failure (G10); a segment is begun only once every
   frame of the previous one is durable. *)
let rewrite_newest disk dir file b =
  let q = newest_frame b in
  let fd = disk.Disk.openf file false in
  Fun.protect ~finally:(fun () -> disk.close fd) (fun () ->
      if Bytes.length b > q then disk.pwrite fd q b q (Bytes.length b - q);
      disk.fsync fd);
  disk.sync_dir dir

let recover ?frame ~force disk dir id from on_group =
  (* Not needed after a clean close ([force] false: the database's marker, Engine.open_), which leaves nothing off the
     disk and no failed fsync. *)
  let before = if force then rewrite_newest disk dir else fun _ _ -> () in
  let found, torn_header, next = scan ?frame ~before disk dir id from on_group in
  (match torn_header with
   | Some s ->
     disk.Disk.remove (path dir s);
     disk.sync_dir dir
   | None -> ());
  match List.rev found with
  | last :: _ ->
    let fd = disk.openf last.file false in
    if last.torn then disk.truncate fd last.stop;
    (* rebuild the trailers of intact frames from their headers: recovery relies on them *)
    List.iter
      (fun p ->
        let h = Bytes.create fh in
        disk.pread fd p h 0 fh;
        let len = u32 h 4 in
        let t = Bytes.create ft in
        set32 t 0 len;
        set32 t 4 (u32 h 20);
        set32 t 8 (u32 h 24);
        set32 t 12 tail_magic;
        disk.pwrite fd (p + fh + len) t 0 ft)
      last.bad_trailers;
    if last.torn || last.bad_trailers <> [] then disk.fsync fd;
    { disk; dir; id; fd; seg = last.first; size = last.stop; next; closed = false; failed = false }
  | [] ->
    (* no usable segment: the only one was torn at its creation, before any frame *)
    let fd = write_segment_header disk dir id next in
    { disk; dir; id; fd; seg = next; size = seg_header; next; closed = false; failed = false }

let create disk dir id =
  let fd = write_segment_header disk dir id 1 in
  { disk; dir; id; fd; seg = 1; size = seg_header; next = 1; closed = false; failed = false }

(* After a failed write or fsync: the journal back to the end of its last durable frame ([size] grows only after a
   successful fsync), a segment that a failed switch began removed, the cut and the directory forced. So a write
   answered with an error is not in the journal, and a power loss cannot leave a part of it that recovery would take
   for damage (G6: a frame whose header's sector alone was lost). The process may die before the cut, or the cut may
   fail: the next recovery writes the newest frame again before it forces it ([rewrite_newest]), which is what keeps
   every view on the disk (G13); the cut only makes the outcome of a failed write certain when it succeeds. *)
let cut j =
  try
    List.iter (fun s -> if s > j.seg then j.disk.Disk.remove (path j.dir s)) (segments j.disk j.dir);
    j.disk.truncate j.fd j.size;
    j.disk.fsync j.fd;
    j.disk.sync_dir j.dir
  with Disk.Io m -> prerr_endline ("cepheus: the journal could not be cut back after a failed write: " ^ m)

let append j body first count =
  if j.closed then raise (Disk.Io "journal is closed");
  if j.failed then raise (Disk.Io "journal: an earlier write failed; reopen the database");
  if first <> j.next then invalid_arg "Journal.append: groups out of order";
  let len = Buffer.length body in
  if len > max_body then invalid_arg "Journal.append: frame too large";
  let n = fh + len + ft in
  let b = Bytes.create n in
  set32 b 0 frame_magic;
  set32 b 4 len;
  Bytes.set_int64_le b 8 (Int64.of_int first);
  set32 b 16 count;
  Buffer.blit body 0 b fh len;
  let bc = Crc32c.bytes b fh len in
  set32 b 20 bc;
  let hc = Crc32c.bytes b 0 24 in
  set32 b 24 hc;
  let t = fh + len in
  set32 b t len;
  set32 b (t + 4) bc;
  set32 b (t + 8) hc;
  set32 b (t + 12) tail_magic;
  match
    if j.size > seg_header && j.size + n > !segment_limit then begin
      (* every frame of the current segment is durable already: start the next one (made first, so that a failure
         leaves the journal on the old segment, still open) *)
      let fd = write_segment_header j.disk j.dir j.id first in
      j.disk.close j.fd;
      j.fd <- fd;
      j.seg <- first;
      j.size <- seg_header
    end;
    let t0 = clock () in
    j.disk.pwrite j.fd j.size b 0 n;
    let t1 = clock () in
    j.disk.fsync j.fd;
    Histogram.record write_us (t1 - t0);
    Histogram.record fsync_us (clock () - t1)
  with
  | () ->
    j.size <- j.size + n;
    j.next <- first + count
  | exception (Disk.Io _ as e) ->
    j.failed <- true;
    cut j;
    raise e

let next_group j = j.next
let position j = { segment = j.seg; offset = j.size; next = j.next }

let close j =
  if not j.closed then begin
    j.closed <- true;
    j.disk.close j.fd
  end

(* A full read, for a closed database: recovery rebuilds the trailer of an intact newest frame (a crash can tear
   just the trailer), so after it any broken trailer is damage. *)
let read disk dir id f =
  let found, torn_header, _ = scan disk dir id None f in
  if torn_header <> None then damaged "journal: the newest segment has a broken header";
  List.iter
    (fun sg ->
      (match sg.bad_trailers with p :: _ -> damaged "%s: the trailer of the frame at %d is damaged" (Filename.basename sg.file) p | [] -> ());
      if sg.torn then damaged "%s: the frame at %d does not check" (Filename.basename sg.file) sg.stop)
    found

let verify disk dir id =
  let n = ref 0 in
  read disk dir id (fun _ -> incr n);
  !n

