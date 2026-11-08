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

(* A segment read through a window of 4 MiB: a frame that fits is checked and decoded where it lies in the window; a
   longer one is checked by pieces, and read whole only to be decoded. A scan holds the window and the largest frame it
   decodes, whatever the size of the segment: a large group's frame passes 100 MB, and an open decodes no frame its
   runs already hold. *)
let window = ref (4 * 1024 * 1024)

type reader = {
  disk : Disk.t;
  fd : Disk.fd;
  size : int;
  w : int;  (* the window's size: at least a segment header *)
  buf : Bytes.t;
  mutable at : int;
  mutable len : int;
}

let reader disk fd =
  let size = disk.Disk.size fd and w = max seg_header !window in
  { disk; fd; size; w; buf = Bytes.create (max 1 (min w size)); at = 0; len = 0 }

(* Where the bytes [p, p + n) of the segment are in [r.buf] (n <= r.w, p + n <= r.size). *)
let get r p n =
  if p >= r.at && p + n <= r.at + r.len then p - r.at
  else begin
    let len = min r.w (r.size - p) in
    r.disk.pread r.fd p r.buf 0 len;
    r.at <- p;
    r.len <- len;
    0
  end

(* The header of the frame at p, if it checks and its frame fits in the segment: body length, first group, count,
   body CRC, header CRC. *)
let header_at r p =
  if r.size - p < fh then None
  else begin
    let o = get r p fh in
    let b = r.buf in
    let len = u32 b (o + 4) in
    if u32 b o <> frame_magic || u32 b (o + 24) <> Crc32c.bytes b o 24 || len > max_body || p + fh + len + ft > r.size
    then None
    else Some (len, Int64.to_int (Bytes.get_int64_le b (o + 8)), u32 b (o + 16), u32 b (o + 20), u32 b (o + 24))
  end

(* Does the body of the frame at p have the CRC [bc]? Read by pieces: for a frame that is not decoded. *)
let body_checks r p len bc =
  let stop = p + fh + len in
  let rec go q c =
    if q >= stop then c
    else
      let n = min r.w (stop - q) in
      let o = get r q n in
      go (q + n) (Crc32c.extend c r.buf o n)
  in
  go (p + fh) 0 = bc

(* The body of the frame at p, if its CRC is [bc]: in the window, or read whole when it is longer. *)
let body r p len bc =
  if len <= r.w then begin
    let o = get r (p + fh) len in
    if Crc32c.bytes r.buf o len = bc then Some (r.buf, o) else None
  end
  else begin
    let b = Bytes.create len in
    r.disk.pread r.fd (p + fh) b 0 len;
    if Crc32c.bytes b 0 len = bc then Some (b, 0) else None
  end

let trailer_at r p len bc hc =
  let o = get r (p + fh + len) ft in
  let b = r.buf in
  u32 b (o + 12) = tail_magic && u32 b o = len && u32 b (o + 4) = bc && u32 b (o + 8) = hc

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

(* What a scan found in one segment. *)
type seg = {
  first : int;
  file : string;
  stop : int;  (* end of the last good frame *)
  torn : bool;  (* bytes after [stop] to cut *)
  bad_trailers : int list;  (* starts of intact frames whose trailer is broken *)
}

(* Read-only, but for [before]: checks the segments from [from] and calls [on_group] on each group. A torn tail is
   allowed only in the newest segment; a torn header only in a newest segment that holds nothing. [before r] runs
   on the newest segment's reader before any of its groups is replayed. *)
let scan ?(frame = fun _ -> ()) ?(before = fun (_ : reader) -> ()) ?(after = 0) disk dir id from on_group =
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
      let name = segment_name s and file = path dir s in
      let resume = match from with Some f -> f.segment = s | None -> false in
      if s <> !expect && not resume then damaged "journal: %s does not follow group %d (a segment is missing)" name (!expect - 1);
      let fd = disk.Disk.openf file false in
      let found =
        Fun.protect ~finally:(fun () -> try disk.close fd with Disk.Io _ -> ()) @@ fun () ->
        let r = reader disk fd in
        let size = r.size in
        if rest = [] then before r;
        let hb = if size < seg_header then Bytes.empty else Bytes.sub r.buf (get r 0 seg_header) seg_header in
        match read_header hb id name with
        | None ->
          if rest <> [] then damaged "journal: %s has a broken header" name;
          None
        | Some first ->
          if first <> s then damaged "journal: %s says it starts at group %d" name first;
          let start = match from with Some f when f.segment = s -> f.offset | _ -> seg_header in
          if start < seg_header || start > size then damaged "journal: %s is shorter than the snapshot says" name;
          let bad = ref [] in
          let rec loop p =
            if p = size then p, false
            else
              let h = header_at r p in
              (* a frame whose groups are all [after] or before is in the runs already: checked by its CRC, not
                 decoded *)
              let skip = match h with Some (_, f0, count, _, _) -> f0 + count - 1 <= after | None -> false in
              let decoded = match h with Some (len, _, _, bc, _) when not skip -> body r p len bc | _ -> None in
              match h with
              | Some (len, f0, count, bc, hc) when (if skip then body_checks r p len bc else Option.is_some decoded) ->
                if f0 <> !expect then damaged "%s: frame at %d starts at group %d, expected %d" name p f0 !expect;
                frame { segment = s; offset = p; next = f0 };
                (match decoded with
                 | None -> expect := !expect + count
                 | Some (b, o) ->
                   let rd = Codec.reader b o len in
                   (try
                      for _ = 1 to count do
                        let g = Group.decode rd in
                        if g.Group.n <> !expect then damaged "%s: group %d where %d was expected" name g.Group.n !expect;
                        on_group g;
                        incr expect
                      done
                    with Codec.Short -> damaged "%s: frame at %d does not decode" name p);
                   if not (Codec.at_end rd) then damaged "%s: frame at %d has bytes after its groups" name p);
                if not (trailer_at r p len bc hc) then bad := p :: !bad;
                loop (p + fh + len + ft)
              | _ ->
                (* the frame at p does not check: torn, or damage, decided from the bytes after it (read whole: a
                   crash's tail, or damage, which stops the open) *)
                let tail = Bytes.create (size - p) in
                disk.pread fd p tail 0 (size - p);
                if written_after tail 0 (size - p) then damaged "%s: damaged frame at offset %d (written whole)" name p
                else if rest <> [] then damaged "%s: segment ends with a broken frame at %d" name p
                else p, true
          in
          let stop, torn = loop start in
          Some { first = s; file; stop; torn; bad_trailers = !bad }
      in
      (match found with
       | None -> List.rev acc, Some s
       | Some sg -> go (sg :: acc) rest)
  in
  let found, torn_header = go [] segs in
  found, torn_header, !expect

(* Where the newest frame of a segment starts: the last frame whose header checks, walking the frames by their lengths
   from the segment's header; 0 if there is none. *)
let newest_frame r =
  let rec go p last = match header_at r p with Some (len, _, _, _, _) -> go (p + fh + len + ft) p | None -> last in
  if r.size >= seg_header then go seg_header 0 else 0

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
let rewrite_newest disk dir r =
  let rec copy x =
    if x < r.size then begin
      let n = min r.w (r.size - x) in
      let o = get r x n in
      disk.Disk.pwrite r.fd x r.buf o n;
      copy (x + n)
    end
  in
  copy (newest_frame r);
  disk.fsync r.fd;
  disk.sync_dir dir

let recover ?frame ?after ~force disk dir id from on_group =
  (* Not needed after a clean close ([force] false: the database's marker, Engine.open_), which leaves nothing off the
     disk and no failed fsync. *)
  let before = if force then rewrite_newest disk dir else fun _ -> () in
  let found, torn_header, next = scan ?frame ~before ?after disk dir id from on_group in
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

(* ---- A frame written as its body is made ----
   A large group's body (hundreds of MB) goes to the file by pieces as it is encoded, beside its merge, instead of
   being built in memory and copied into a frame: [begin_frame] takes the frame's place at the end of the journal (in a
   new segment when the current one would pass its limit, as [append] does), [body] writes the pieces in order and
   forces them now and then, so that the disk writes them while the merge runs, [finish] writes the header, then the
   trailer, and forces the frame; [drop] takes the pieces back off the file. Only the header makes a frame: a crash
   before it leaves pieces that recovery cuts as a torn tail; a crash after it, a frame whose trailer recovery
   rebuilds, as after a torn [append]. Nothing else may append between [begin_frame] and [finish] or [drop]. *)

type pending = {
  pj : t;
  pfd : Disk.fd;
  fresh : bool;  (* the frame starts a segment, made by [begin_frame] *)
  at : int;  (* the frame's offset *)
  plen : int;
  pfirst : int;
  pcount : int;
  mutable put : int;  (* body bytes written *)
  mutable crc : int;
  mutable unforced : int;
}

(* the body's pieces are forced every [force_every] bytes: the disk works while the merge does *)
let force_every = ref (32 lsl 20)

let begin_frame j len first count =
  if j.closed then raise (Disk.Io "journal is closed");
  if j.failed then raise (Disk.Io "journal: an earlier write failed; reopen the database");
  if first <> j.next then invalid_arg "Journal.begin_frame: groups out of order";
  if len > max_body then invalid_arg "Journal.begin_frame: frame too large";
  let n = fh + len + ft in
  let base = { pj = j; pfd = j.fd; fresh = false; at = j.size; plen = len; pfirst = first; pcount = count; put = 0;
               crc = 0; unforced = 0 } in
  if j.size > seg_header && j.size + n > !segment_limit then
    (* every frame of the current segment is durable already: the next one is made now, the journal moves to it
       when the frame is finished *)
    match write_segment_header j.disk j.dir j.id first with
    | fd -> { base with pfd = fd; fresh = true; at = seg_header }
    | exception (Disk.Io _ as e) -> j.failed <- true; cut j; raise e
  else base

(* a failure of the pending frame's file: the journal is never used again, cut back to its last durable frame *)
let fail_pending p e =
  let j = p.pj in
  j.failed <- true;
  if p.fresh then (try j.disk.Disk.close p.pfd with Disk.Io _ -> ());
  cut j;
  raise e

let body p buf off n =
  if p.put + n > p.plen then invalid_arg "Journal.body: longer than the frame";
  match
    p.pj.disk.Disk.pwrite p.pfd (p.at + fh + p.put) buf off n;
    p.crc <- Crc32c.extend p.crc buf off n;
    p.put <- p.put + n;
    p.unforced <- p.unforced + n;
    if p.unforced >= !force_every then (p.pj.disk.fsync p.pfd; p.unforced <- 0)
  with
  | () -> ()
  | exception (Disk.Io _ as e) -> fail_pending p e

let finish p =
  let j = p.pj in
  if p.put <> p.plen then invalid_arg "Journal.finish: the body is shorter than the frame";
  let h = Bytes.create fh and t = Bytes.create ft in
  set32 h 0 frame_magic;
  set32 h 4 p.plen;
  Bytes.set_int64_le h 8 (Int64.of_int p.pfirst);
  set32 h 16 p.pcount;
  set32 h 20 p.crc;
  let hc = Crc32c.bytes h 0 24 in
  set32 h 24 hc;
  set32 t 0 p.plen;
  set32 t 4 p.crc;
  set32 t 8 hc;
  set32 t 12 tail_magic;
  match
    (* the header first: a trailer that checks behind a missing header would read as damage *)
    let t0 = clock () in
    j.disk.Disk.pwrite p.pfd p.at h 0 fh;
    j.disk.pwrite p.pfd (p.at + fh + p.plen) t 0 ft;
    let t1 = clock () in
    j.disk.fsync p.pfd;
    Histogram.record write_us (t1 - t0);
    Histogram.record fsync_us (clock () - t1)
  with
  | () ->
    if p.fresh then begin
      j.disk.close j.fd;
      j.fd <- p.pfd;
      j.seg <- p.pfirst
    end;
    j.size <- p.at + fh + p.plen + ft;
    j.next <- p.pfirst + p.pcount
  | exception (Disk.Io _ as e) -> fail_pending p e

(* The pieces taken back: a later frame must never find them behind it. A failure leaves the journal failed. *)
let drop p =
  let j = p.pj in
  try
    if p.fresh then begin
      j.disk.Disk.close p.pfd;
      j.disk.remove (path j.dir p.pfirst);
      j.disk.sync_dir j.dir
    end
    else if p.put > 0 then begin
      j.disk.truncate j.fd j.size;
      j.disk.fsync j.fd
    end
  with Disk.Io _ as e -> fail_pending { p with fresh = false } e

let written_body p =
  let b = Bytes.create p.put in
  p.pj.disk.Disk.pread p.pfd (p.at + fh) b 0 p.put;
  b

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


(* The groups after [after], in order, without changing a file: the scan starts at the segment that holds group
   [after + 1], and the frames before it are checked by their CRCs but not decoded. For a database open in this
   process, between frames (the server's session tables, rebuilt at its start). *)
let read_after disk dir id after f =
  let segs = List.sort compare (segments disk dir) in
  let start = List.fold_left (fun acc s -> if s <= after + 1 then Some s else acc) None segs in
  let from = Option.map (fun s -> { segment = s; offset = seg_header; next = s }) start in
  ignore (scan ~after disk dir id from (fun g -> if g.Group.n > after then f g))
