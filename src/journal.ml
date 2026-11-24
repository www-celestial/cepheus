exception Damaged of string

type position = { segment : int; offset : int; next : int }

let seg_magic = 0x4A485043 (* "CPHJ" *)
let frame_magic = 0x46485043 (* "CPHF" *)
let tail_magic = 0x54485043 (* "CPHT" *)
(* format 2: groups coded in columns (Group.encode); a journal of format 1 (a change after the other) is converted
   once at open (convert) *)
let format = 2
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
  mutable shared : ((Bytes.t -> bool) * (unit -> unit)) option;  (* the server's commit buffer: see [share] *)
  mutable unforced : bool;  (* frames written since the journal's last fsync (a shared journal's) *)
  lock : Mutex.t;  (* [fd] and [unforced], between the writer and the commit buffer's checkpoints *)
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
let read_header ?(fmt = format) b id name =
  if Bytes.length b < seg_header || u32 b 0 <> seg_magic || u32 b 36 <> Crc32c.bytes b 0 36 then None
  else if u32 b 4 <> fmt then damaged "%s: unknown format %d" name (u32 b 4)
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

let frame_body = body

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
   allowed only in the newest segment; a torn header only in a newest segment no longer than its header, that no run
   names (one a crash left being made). [before r] runs
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
        (* the header by itself: the frames are read from where the scan starts, often the segment's end *)
        let hb = if size < seg_header then Bytes.empty else (let b = Bytes.create seg_header in disk.pread fd 0 b 0 seg_header; b) in
        match read_header hb id name with
        | None ->
          if rest <> [] then damaged "journal: %s has a broken header" name;
          (* The header is forced, and its directory, before anything else is written in the segment
             (write_segment_header), and a run names a position only in a segment the writer had begun: a segment
             that holds bytes past its header, or the one the newest run starts in, had a durable header, which
             changed since (G6). Only a segment of its header's length or less, that no run names, may be one a
             crash left being made: it holds no frame. *)
          if size > seg_header then damaged "journal: %s has a broken header, with %d bytes after it" name (size - seg_header);
          if resume then damaged "journal: %s, where the newest run starts, has a broken header" name;
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

(* ---- The commit buffer's frames, written again (the recovery of a shared journal) ----
   After a power loss, the frames a shared journal wrote after its last fsync may each be lost, kept or torn, so its own
   rule (a torn tail; damage when a frame that checks follows one that does not) cannot be trusted there. The server's
   commit buffer holds, whole, every frame the journal may not have forced (Wal): from the snapshot's position, at
   each group, a frame the buffer holds is written again where it goes (at the start of the segment named by its first
   group when there is one: the writer began that segment, forced, before the frame), and every other frame must check,
   since it was forced (a frame of its own, or one of a buffer's file recycled once its journals were forced). The
   journal's own rule then takes the rest: at most the frame being written at the crash. *)
let repair disk dir (from : position option) frames =
  let info b = Int64.to_int (Bytes.get_int64_le b 8), u32 b 16 in
  let start = match from with Some f -> f.next | None -> 1 in
  match List.filter (fun b -> let f0, c = info b in f0 + c - 1 >= start) frames with
  | [] -> ()
  | frames ->
    let segs = Hashtbl.create 16 in
    List.iter (fun s -> Hashtbl.replace segs s ()) (segments disk dir);
    let seg, off = match from with Some f -> f.segment, f.offset | None -> 1, seg_header in
    if not (Hashtbl.mem segs seg) then damaged "journal: segment %s, where the commit buffer's frames go, is missing" (segment_name seg);
    let s = ref seg and fd = ref (disk.Disk.openf (path dir seg) false) and written = ref false in
    let r = ref None and p = ref off and g = ref start in
    let leave () = if !written then disk.fsync !fd; disk.close !fd in
    (* the frame of group !g starts a segment: the one before it ends here *)
    let next_segment () =
      if !g <> !s && Hashtbl.mem segs !g then begin
        leave ();
        s := !g;
        fd := disk.openf (path dir !g) false;
        written := false;
        r := None;
        p := seg_header
      end
    in
    let reader () = match !r with Some x -> x | None -> let x = reader disk !fd in r := Some x; x in
    (match
       List.iter
         (fun b ->
           let f0, c = info b in
           while !g < f0 do
             next_segment ();
             let rd = reader () in
             match header_at rd !p with
             | Some (len, f1, count, bc, _) when f1 = !g && body_checks rd !p len bc -> p := !p + fh + len + ft; g := !g + count
             | _ -> damaged "%s: the frame at %d (group %d) does not check, before the commit buffer's frames from group %d"
                      (segment_name !s) !p !g f0
           done;
           if !g <> f0 then damaged "journal: the commit buffer's frame of group %d does not start where a frame does (group %d)" f0 !g;
           next_segment ();
           (* what the journal holds there: the same frame (whole, or torn), or bytes that do not make a frame; a
              header that checks and is another frame's means the journal was written without the buffer since (an
              open by a version that does not read it): never written over. The frame is written even when the
              bytes read are its own: a failed fsync may have marked those pages clean, the page cache showing what
              the disk lacks, and only a write makes them dirty again, so that the fsync below writes them (G13) *)
           let n = Bytes.length b and size = disk.size !fd in
           let hn = max 0 (min fh (size - !p)) in
           let have = Bytes.create hn in
           if hn > 0 then disk.pread !fd !p have 0 hn;
           if hn = fh && u32 have 0 = frame_magic && u32 have 24 = Crc32c.bytes have 0 24 && not (Bytes.equal have (Bytes.sub b 0 fh))
           then damaged "%s: the frame at %d is not the one the commit buffer holds for group %d (the database was written without its server's buffer after a crash)" (segment_name !s) !p f0;
           disk.pwrite !fd !p b 0 n;
           written := true;
           r := None;
           p := !p + n;
           g := !g + c)
         frames
     with
     | () -> leave ()
     | exception e -> (try disk.close !fd with Disk.Io _ -> ()); raise e)

(* ---- A Raft cluster's journal, cut where what is known committed ends ----
   In a Raft cluster a journal holds committed frames only, written without an fsync; the Raft log holds them forced
   until a checkpoint forced the journal past them (server/cluster.ml). At open, the frames known committed are
   written again by [repair]; every frame from group [g] on is removed (some may have survived a power loss with holes
   between them): they are applied again from the Raft log once the commit index is known. Frames before [g] must
   check (they were forced, or written again just before). *)
let cut_from disk dir (from : position option) g =
  let segs = List.sort compare (segments disk dir) in
  let start = match from with Some f -> f.next | None -> 1 in
  if g > start then begin
    let seg0 = match from with Some f -> f.segment | None -> (match segs with s :: _ -> s | [] -> 1) in
    let changed = ref false in
    (* the segments from g on go whole *)
    List.iter (fun s -> if s >= g && s > seg0 then (disk.Disk.remove (path dir s); changed := true)) segs;
    let segs = List.filter (fun s -> s >= seg0 && s < g) segs in
    let p0 = match from with Some f -> f.offset | None -> seg_header in
    let at = ref start in
    List.iteri
      (fun k s ->
        if !at < g then begin
          let fd = disk.openf (path dir s) false in
          Fun.protect ~finally:(fun () -> disk.close fd) (fun () ->
              let r = reader disk fd in
              let p = ref (if k = 0 then p0 else seg_header) and go = ref true in
              while !go && !at < g do
                match header_at r !p with
                | Some (len, f1, count, bc, _) when f1 = !at && body_checks r !p len bc -> p := !p + fh + len + ft; at := !at + count
                | Some _ | None when !p >= r.size -> go := false
                | _ -> damaged "%s: the frame at %d (group %d) does not check, before group %d where the journal is cut" (segment_name s) !p !at g
              done;
              if !at >= g && !p < r.size then begin
                if !at > g then damaged "%s: no frame starts at group %d, where the journal is cut" (segment_name s) g;
                disk.truncate fd !p;
                disk.fsync fd;
                changed := true
              end)
        end)
      segs;
    if !changed then disk.sync_dir dir
  end

let recover ?frame ?after ?(copy = []) ?cut ~force disk dir id from on_group =
  repair disk dir from copy;
  Option.iter (cut_from disk dir from) cut;
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
    { disk; dir; id; fd; seg = last.first; size = last.stop; next; closed = false; failed = false; shared = None; unforced = false;
      lock = Mutex.create () }
  | [] ->
    (* no usable segment: the only one was torn at its creation, before any frame *)
    let fd = write_segment_header disk dir id next in
    { disk; dir; id; fd; seg = next; size = seg_header; next; closed = false; failed = false; shared = None; unforced = false;
      lock = Mutex.create () }

let create disk dir id =
  let fd = write_segment_header disk dir id 1 in
  { disk; dir; id; fd; seg = 1; size = seg_header; next = 1; closed = false; failed = false; shared = None; unforced = false;
      lock = Mutex.create () }

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

(* ---- A journal that shares the server's commit buffer ----
   Its frames are written to its segment without an fsync, and forced by the buffer's round (one fsync for every
   database of the server: Wal); the journal itself is forced when the buffer recycles its file (checkpoint), when
   a segment is left, by a frame of its own (a large group, a long frame), before a run is named, and at close. *)

(* the longest frame forced by the commit buffer (1 MiB): a longer one is forced in its own journal *)
let shared_max = ref (1 lsl 20)

let share j give own_done = j.shared <- Some (give, own_done)

(* under [j.lock] *)
let force_unforced j =
  if j.unforced then begin
    j.disk.Disk.fsync j.fd;
    j.unforced <- false
  end

let checkpoint j =
  Mutex.protect j.lock (fun () ->
      if j.failed then raise (Disk.Io "journal: an earlier write failed; reopen the database");
      if not j.closed then
        match force_unforced j with
        | () -> ()
        | exception (Disk.Io _ as e) -> j.failed <- true; raise e)

let forced j = Mutex.protect j.lock (fun () -> not (j.unforced || j.failed))

(* a frame's bytes, whole: what [append] writes *)
let frame_bytes body first count =
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
  b

(* a whole frame's first group, count and body, if its header, body and trailer check (a frame from a peer) *)
let frame_parts b =
  let n = Bytes.length b in
  if n < fh + ft || u32 b 0 <> frame_magic || u32 b 24 <> Crc32c.bytes b 0 24 then None
  else
    let len = u32 b 4 in
    if len <> n - fh - ft || u32 b 20 <> Crc32c.bytes b fh len then None
    else if u32 b (fh + len) <> len || u32 b (fh + len + 4) <> u32 b 20 || u32 b (fh + len + 8) <> u32 b 24 || u32 b (fh + len + 12) <> tail_magic then None
    else
      let first = Int64.to_int (Bytes.get_int64_le b 8) and count = u32 b 16 in
      if first < 1 || count < 1 then None else Some (first, count, Bytes.sub b fh len)

let append j body first count =
  if j.closed then raise (Disk.Io "journal is closed");
  if j.failed then raise (Disk.Io "journal: an earlier write failed; reopen the database");
  if first <> j.next then invalid_arg "Journal.append: groups out of order";
  let b = frame_bytes body first count in
  let n = Bytes.length b in
  (* a frame of a shared journal is forced by the commit buffer's round, but for a long one, forced here: written
     twice, it would cost more than its own fsync *)
  let shared = match j.shared with Some f when n <= !shared_max -> Some f | _ -> None in
  match
    let t0 = clock () in
    Mutex.protect j.lock (fun () ->
        if j.size > seg_header && j.size + n > !segment_limit then begin
          (* every frame of the current segment is durable already, forced in it before it is left when the
             commit buffer forced them: start the next one (made first, so that a failure leaves the journal on the
             old segment, still open) *)
          force_unforced j;
          let fd = write_segment_header j.disk j.dir j.id first in
          j.disk.close j.fd;
          j.fd <- fd;
          j.seg <- first;
          j.size <- seg_header
        end;
        j.disk.pwrite j.fd j.size b 0 n;
        if shared <> None then j.unforced <- true);
    let t1 = clock () in
    let own () = j.disk.fsync j.fd; Mutex.protect j.lock (fun () -> j.unforced <- false) in
    (match shared with
     | None -> own ()
     | Some (give, own_done) -> if not (give b) then Fun.protect ~finally:own_done own);
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
    (* every frame of the current segment is durable already (forced in it now, when the commit buffer forced them):
       the next one is made now, the journal moves to it when the frame is finished *)
    match Mutex.protect j.lock (fun () -> force_unforced j); write_segment_header j.disk j.dir j.id first with
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
    (* its fsync forced every frame before it in its segment *)
    Mutex.protect j.lock (fun () ->
        if p.fresh then begin
          j.disk.close j.fd;
          j.fd <- p.pfd;
          j.seg <- p.pfirst
        end;
        j.unforced <- false);
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

(* A shared journal is forced first; a failure of that fsync is raised once the file is closed. *)
let close j =
  if not j.closed then begin
    let forced =
      Mutex.protect j.lock (fun () ->
          j.closed <- true;
          let r = if j.failed then Ok () else match force_unforced j with () -> Ok () | exception (Disk.Io _ as e) -> Error e in
          j.disk.close j.fd;
          r)
    in
    match forced with Ok () -> () | Error e -> j.failed <- true; raise e
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

(* ---- The journal checked as files: cepheus verify, backup and restore ----
   Each segment is checked on its own, so that a damaged one does not hide the others: its header, then every frame
   (its header, its body's CRC, its trailer, its first group and count, the groups that follow one another), and the
   groups of every frame up to [decode_max] decoded and numbered (a larger frame, a large load's, is checked by its
   CRCs: decoding it would take the memory of its group). The first frame that does not check ends the segment's
   check; how it is read depends on what may lie at the end of the newest segment:
     Strict  a database closed cleanly, or a copy that cepheus backup cut and forced: every byte checks;
     Crash   a database whose process died: the frame being written may be torn (no valid frame or trailer after it),
             its newest frame's trailer alone broken, the newest segment torn at its creation; what recovery cuts or
             rebuilds, and nothing else;
     Copy    a database being written (open in another process), or the files copied from one: from the first frame of
             the newest segment that does not check whole, everything is the frame being written, whatever follows it
             (a large group's header is written after its body, so a copy may see its trailer and not its header).
   Every group confirmed before a copy of its segment started is before that point: it was written whole before it
   was confirmed, and frames are appended one at a time. *)

type tail = Strict | Crash | Copy

type segment_check = {
  sfirst : int;  (** the segment's first group, from its name *)
  sbytes : int;  (** its size *)
  sframes : int;  (** its whole frames *)
  slast : int;  (** the last group of its whole frames ([sfirst - 1]: none) *)
  send : int;  (** where its last whole frame ends (0: its header did not check) *)
  stail : bool;  (** bytes after [send] that the rule takes for the frame being written *)
  sdamage : string option;  (** the first damage, which ended the segment's check *)
}

let decode_max = ref (16 lsl 20)

let check_segment ~tail ~newest ~frame ~on_group disk dir id s =
  let name = segment_name s in
  let fd = disk.Disk.openf (path dir s) false in
  Fun.protect ~finally:(fun () -> try disk.close fd with Disk.Io _ -> ()) @@ fun () ->
  let r = reader disk fd in
  let size = r.size in
  let frames = ref 0 and expect = ref s in
  let result ?damage ?(torn = false) stop =
    { sfirst = s; sbytes = size; sframes = !frames; slast = !expect - 1; send = stop; stail = torn; sdamage = damage }
  in
  let hb = if size < seg_header then Bytes.empty else (let b = Bytes.create seg_header in disk.pread fd 0 b 0 seg_header; b) in
  match read_header hb id name with
  | exception Damaged m -> result ~damage:m 0
  | None ->
    if newest && tail <> Strict && size <= seg_header then result ~torn:true 0
    else result ~damage:(Printf.sprintf "%s has a broken header" name) 0
  | Some first when first <> s -> result ~damage:(Printf.sprintf "%s says it starts at group %d" name first) 0
  | Some _ ->
    (* the frame at p does not check: the tail, or damage, as the rule reads the bytes after it *)
    let broken p =
      if newest && tail = Copy then result ~torn:true p
      else begin
        let rest = Bytes.create (size - p) in
        disk.pread fd p rest 0 (size - p);
        if written_after rest 0 (size - p) then result ~damage:(Printf.sprintf "%s: damaged frame at offset %d (written whole)" name p) p
        else if not newest then result ~damage:(Printf.sprintf "%s: the segment ends with a broken frame at offset %d" name p) p
        else if tail = Strict then result ~damage:(Printf.sprintf "%s: a torn frame at offset %d, in a database closed cleanly" name p) p
        else result ~torn:true p
      end
    in
    let rec loop p =
      if p = size then result p
      else
        match header_at r p with
        | None -> broken p
        | Some (len, f0, count, bc, hc) -> (
          let decoded = if len <= !decode_max then frame_body r p len bc else None in
          if not (if len <= !decode_max then Option.is_some decoded else body_checks r p len bc) then broken p
          else if f0 <> !expect then result ~damage:(Printf.sprintf "%s: the frame at offset %d starts at group %d, where %d was expected" name p f0 !expect) p
          else if count < 1 then result ~damage:(Printf.sprintf "%s: the frame at offset %d holds no group" name p) p
          else
            let stop = p + fh + len + ft in
            let whole = trailer_at r p len bc hc in
            (* a broken trailer: damage, but in a frame being written (Copy), or on the newest frame after a crash,
               which recovery rebuilds *)
            if (not whole) && newest && tail = Copy then result ~torn:true p
            else if (not whole) && not (newest && tail = Crash && stop = size) then
              result ~damage:(Printf.sprintf "%s: the trailer of the frame at offset %d is damaged" name p) p
            else
              let bad =
                match decoded with
                | None -> None
                | Some (b, o) -> (
                  let rd = Codec.reader b o len in
                  match
                    for k = 0 to count - 1 do
                      let g = Group.decode rd in
                      if g.Group.n <> f0 + k then raise Exit;
                      on_group g
                    done
                  with
                  | () -> if Codec.at_end rd then None else Some (Printf.sprintf "%s: the frame at offset %d has bytes after its groups" name p)
                  | exception Exit -> Some (Printf.sprintf "%s: the frame at offset %d does not number its groups from %d" name p f0)
                  | exception Codec.Short -> Some (Printf.sprintf "%s: the frame at offset %d does not decode" name p))
              in
              match bad with
              | Some m -> result ~damage:m p
              | None ->
                frame { segment = s; offset = p; next = f0 } count stop;
                incr frames;
                expect := f0 + count;
                loop stop)
    in
    loop seg_header

type check = {
  segments : segment_check list;  (** in the order of their names *)
  damages : string list;  (** each segment's first damage, and the segments missing between them *)
  last : int;  (** the newest group of the frames that check from group 1 on, with no damage before it *)
}

(* [domains] > 1: the segments checked at once, each by one domain (the callbacks then run on several domains) *)
let check ?(domains = 1) ?(frame = fun _ _ _ -> ()) ?(on_group = fun _ -> ()) ~tail disk dir id =
  let segs = Array.of_list (List.sort compare (segments disk dir)) in
  let n = Array.length segs in
  let out = Array.make n None in
  let next = Atomic.make 0 in
  let work () =
    let rec go () =
      let i = Atomic.fetch_and_add next 1 in
      if i < n then begin
        out.(i) <- Some (match check_segment ~tail ~newest:(i = n - 1) ~frame ~on_group disk dir id segs.(i) with
                         | c -> Ok c
                         | exception Disk.Io m -> Error m);
        go ()
      end
    in
    go ()
  in
  let d = if disk.Disk.parallel then max 1 (min domains n) else 1 in
  let others = List.init (d - 1) (fun _ -> Domain.spawn work) in
  work ();
  List.iter Domain.join others;
  let results = Array.to_list (Array.map Option.get out) in
  (* an unreadable segment (Disk.Io) is named as damage: a read the disk refused *)
  let results =
    List.mapi
      (fun i -> function
        | Ok c -> c
        | Error m -> { sfirst = segs.(i); sbytes = 0; sframes = 0; slast = segs.(i) - 1; send = 0; stail = false; sdamage = Some m })
      results
  in
  let damages = ref [] and last = ref 0 and chained = ref true in
  if n = 0 then damages := [ "journal: no segment" ]
  else if segs.(0) <> 1 then (damages := [ Printf.sprintf "journal: the first segment starts at group %d" segs.(0) ]; chained := false);
  List.iteri
    (fun i c ->
      (match c.sdamage with Some m -> damages := m :: !damages | None -> ());
      (* the segment after a whole one starts where it ended *)
      (if i > 0 then
         let p = List.nth results (i - 1) in
         if p.sdamage = None && not p.stail && c.sfirst <> p.slast + 1 then begin
           damages := Printf.sprintf "journal: %s does not follow group %d (a segment is missing)" (segment_name c.sfirst) p.slast :: !damages;
           chained := false
         end);
      if !chained then begin
        if c.slast >= c.sfirst then last := c.slast;
        if c.sdamage <> None then chained := false
      end)
    results;
  { segments = results; damages = List.rev !damages; last = !last }

(* The number and time of every group, in order, from the start, each frame checked by its CRCs, until [f n time]
   returns false or a frame does not check: for cepheus restore --to-time. A frame longer than [decode_max] that holds
   one group (a large one) has only its group's head read. *)
let times disk dir id f =
  let go = ref true in
  List.iter
    (fun s ->
      if !go then begin
        let fd = disk.Disk.openf (path dir s) false in
        Fun.protect ~finally:(fun () -> try disk.close fd with Disk.Io _ -> ()) @@ fun () ->
        let r = reader disk fd in
        let hb = Bytes.create seg_header in
        if r.size < seg_header then go := false
        else begin
          disk.pread fd 0 hb 0 seg_header;
          if read_header hb id (segment_name s) <> Some s then go := false
        end;
        let rec loop p =
          if !go then
            match header_at r p with
            | None -> ()
            | Some (len, _, count, bc, _) ->
              (if len <= !decode_max || count > 1 then
                 match frame_body r p len bc with
                 | Some (b, o) ->
                   let rd = Codec.reader b o len in
                   let k = ref 0 in
                   while !go && !k < count do
                     let g = Group.decode rd in
                     go := f g.Group.n g.time;
                     incr k
                   done
                 | None -> go := false
               else if body_checks r p len bc then begin
                 let h = Bytes.create (min len 64) in
                 disk.pread fd (p + fh) h 0 (min len 64);
                 let rd = Codec.reader h 0 (min len 64) in
                 let n = Codec.get_varint rd in
                 go := f n (Codec.get_int rd)
               end
               else go := false);
              loop (p + fh + len + ft)
        in
        loop seg_header
      end)
    (List.sort compare (segments disk dir))

(* ---- A copy of the journal ended after group [n] (cepheus restore --to-group) ----
   On a copy that holds group [n]: the segments after the one that begins at group [n + 1] removed, that one kept as
   its header alone (a run of group [n] may name it: its position is the start of the frame that follows), the frame
   that holds [n] ended after it (the groups after [n] taken out of it: its groups decoded and coded again into a frame
   at the same place, whose first group is the same), the segment truncated after it, everything forced. Returns
   false, and changes nothing, when no frame that checks holds group [n]. *)
let cut_after disk dir id n =
  let segs = List.sort compare (segments disk dir) in
  match List.fold_left (fun acc s -> if s <= n then Some s else acc) None segs with
  | None -> false
  | Some s ->
    let fd = disk.Disk.openf (path dir s) false in
    let found =
      Fun.protect ~finally:(fun () -> try disk.close fd with Disk.Io _ -> ()) @@ fun () ->
      let r = reader disk fd in
      let rec walk p =
        match header_at r p with
        | Some (len, f0, count, bc, _) when f0 <= n && body_checks r p len bc ->
          if n <= f0 + count - 1 then Some (p, len, f0, count) else walk (p + fh + len + ft)
        | _ -> None
      in
      let header_ok =
        r.size >= seg_header
        && (let hb = Bytes.create seg_header in
            disk.pread fd 0 hb 0 seg_header;
            match read_header hb id (segment_name s) with Some f -> f = s | None -> false | exception Damaged _ -> false)
      in
      match if header_ok then walk seg_header else None with
      | None -> false
      | Some (p, len, f0, count) ->
        let stop =
          if n = f0 + count - 1 then p + fh + len + ft
          else begin
            let b = Bytes.create len in
            disk.pread fd (p + fh) b 0 len;
            let rd = Codec.reader b 0 len in
            let out = Buffer.create len in
            for _ = f0 to n do Group.encode out (Group.decode rd) done;
            let f = frame_bytes out f0 (n - f0 + 1) in
            disk.pwrite fd p f 0 (Bytes.length f);
            p + Bytes.length f
          end
        in
        disk.truncate fd stop;
        disk.fsync fd;
        true
    in
    if found then begin
      List.iter
        (fun s' ->
          if s' > n + 1 then disk.remove (path dir s')
          else if s' = n + 1 then begin
            let fd = disk.openf (path dir s') false in
            Fun.protect ~finally:(fun () -> disk.close fd) (fun () -> disk.truncate fd seg_header; disk.fsync fd)
          end)
        segs;
      disk.sync_dir dir
    end;
    found


(* The groups after [after], in order, without changing a file: the scan starts at the segment that holds group
   [after + 1], and the frames before it are checked by their CRCs but not decoded. For a database open in this
   process, between frames (the server's session tables, rebuilt at its start). *)
let read_after disk dir id after f =
  let segs = List.sort compare (segments disk dir) in
  let start = List.fold_left (fun acc s -> if s <= after + 1 then Some s else acc) None segs in
  let from = Option.map (fun s -> { segment = s; offset = seg_header; next = s }) start in
  ignore (scan ~after disk dir id from (fun g -> if g.Group.n > after then f g))

(* ---- Format 1, converted once ----
   A segment of format 1 codes its groups a change after the other (Group.decode_v1). At open, before anything reads
   the journal, each such segment is rewritten in format 2, its frames as they were (the same groups, first group and
   count each), their bodies coded again: the new segment is written beside the old one (NAME.seg.tmp), forced,
   renamed over it, and the directory forced, so that a crash leaves either segment whole, and the next open goes on
   with the segments left. Its frames are read as recovery reads them: a frame that does not check ends the segment if
   it is the newest one and nothing written after it checks (a torn tail, cut), and is damage otherwise. Runs older
   than the conversion (formats 5 and 6) name offsets of the old segments; they are set aside anyway (Snapshot.load),
   and the conversion happens before any run of format 7 exists. Returns the segments converted. *)
let convert disk dir id =
  let segs = List.sort compare (segments disk dir) in
  let newest = List.fold_left (fun _ s -> s) 0 segs in
  let converted = ref 0 in
  List.iter
    (fun s ->
      let name = segment_name s and file = path dir s in
      let fd = disk.Disk.openf file false in
      let out =
        Fun.protect ~finally:(fun () -> try disk.close fd with Disk.Io _ -> ()) @@ fun () ->
        let size = disk.Disk.size fd in
        if size < seg_header then None
        else begin
          (* the header alone: a segment of format 2 is left without reading its frames *)
          let hb = Bytes.create seg_header in
          disk.pread fd 0 hb 0 seg_header;
          if u32 hb 0 <> seg_magic || u32 hb 36 <> Crc32c.bytes hb 0 36 || u32 hb 4 <> 1 then None
          else begin
            ignore (read_header ~fmt:1 hb id name);
            let r = reader disk fd in
            let o = Buffer.create (min size (16 lsl 20)) in
            let h = Bytes.copy hb in
            set32 h 4 format;
            set32 h 36 (Crc32c.bytes h 0 36);
            Buffer.add_bytes o h;
            let gbuf = Buffer.create 4096 in
            let broken p =
              let tail = Bytes.create (size - p) in
              disk.pread fd p tail 0 (size - p);
              if written_after tail 0 (size - p) then damaged "%s: damaged frame at offset %d (written whole)" name p
              else if s <> newest then damaged "%s: segment ends with a broken frame at %d" name p
            in
            let rec loop p =
              if p < size then
                match header_at r p with
                | None -> broken p
                | Some (len, f0, count, bc, _) -> (
                  match frame_body r p len bc with
                  | None -> broken p
                  | Some (b, bo) ->
                    let rd = Codec.reader b bo len in
                    Buffer.clear gbuf;
                    (try for _ = 1 to count do Group.encode gbuf (Group.decode_v1 rd) done
                     with Codec.Short -> damaged "%s: frame at %d does not decode" name p);
                    if not (Codec.at_end rd) then damaged "%s: frame at %d has bytes after its groups" name p;
                    let n = Buffer.length gbuf in
                    if n > max_body then damaged "%s: frame at %d is over %d bytes in format 2" name p max_body;
                    let f = Bytes.create (fh + n + ft) in
                    set32 f 0 frame_magic;
                    set32 f 4 n;
                    Bytes.set_int64_le f 8 (Int64.of_int f0);
                    set32 f 16 count;
                    Buffer.blit gbuf 0 f fh n;
                    let c = Crc32c.bytes f fh n in
                    set32 f 20 c;
                    let hc = Crc32c.bytes f 0 24 in
                    set32 f 24 hc;
                    set32 f (fh + n) n;
                    set32 f (fh + n + 4) c;
                    set32 f (fh + n + 8) hc;
                    set32 f (fh + n + 12) tail_magic;
                    Buffer.add_bytes o f;
                    loop (p + fh + len + ft))
            in
            loop seg_header;
            Some o
          end
        end
      in
      match out with
      | None -> ()
      | Some o ->
        let tmp = file ^ ".tmp" in
        let tfd = disk.openf tmp true in
        (match
           disk.truncate tfd 0;
           disk.pwrite tfd 0 (Buffer.to_bytes o) 0 (Buffer.length o);
           disk.fsync tfd
         with
         | () -> disk.close tfd
         | exception (Disk.Io _ as e) -> (try disk.close tfd with Disk.Io _ -> ()); raise e);
        disk.rename tmp file;
        disk.sync_dir dir;
        incr converted)
    segs;
  (* a conversion a crash interrupted leaves its .tmp: the old segment is still there, whole *)
  List.iter (fun n -> if Filename.check_suffix n ".seg.tmp" then disk.Disk.remove (Filename.concat dir n)) (disk.readdir dir);
  !converted

(* ---- A reader of the frames as they are: a replica's sender ----
   The primary sends its frames byte for byte as its journal holds them, read from the files while the writer appends:
   only the frames whose groups are all at or before a durable group, which are whole; their bodies are checked by
   their CRCs here and again by the replica. Two reads a frame (its header, its body), into one buffer that grows to
   the longest body sent. *)

type cursor = {
  cdisk : Disk.t;
  cdir : string;
  cid : string;
  mutable cseg : int;  (* the first group of the segment read *)
  mutable cfd : Disk.fd option;
  mutable coff : int;  (* where the next frame starts *)
  mutable cnext : int;  (* its first group *)
  mutable cbuf : Bytes.t;
}

let cursor_close c = Option.iter (fun fd -> try c.cdisk.Disk.close fd with Disk.Io _ -> ()) c.cfd; c.cfd <- None

(* segment [s] opened, its header checked; false if it is not there or its header is torn (being made) *)
let cursor_open c s =
  cursor_close c;
  let file = path c.cdir s in
  if not (c.cdisk.Disk.exists file) then false
  else begin
    let fd = c.cdisk.openf file false in
    let hb = Bytes.create seg_header in
    let ok =
      try
        if c.cdisk.size fd < seg_header then false
        else (c.cdisk.pread fd 0 hb 0 seg_header; match read_header hb c.cid (segment_name s) with Some f -> f = s | None -> false)
      with e -> c.cdisk.close fd; raise e
    in
    if ok then (c.cfd <- Some fd; c.cseg <- s; c.coff <- seg_header) else c.cdisk.close fd;
    ok
  end

(* the header of the frame at the cursor, if the segment holds one that checks: body length, first, count, body CRC *)
let cursor_header c =
  match c.cfd with
  | None -> None
  | Some fd ->
    let size = c.cdisk.Disk.size fd in
    if size - c.coff < fh then None
    else begin
      let h = Bytes.create fh in
      c.cdisk.pread fd c.coff h 0 fh;
      let len = u32 h 4 in
      if u32 h 0 <> frame_magic || u32 h 24 <> Crc32c.bytes h 0 24 || len > max_body || c.coff + fh + len + ft > size then None
      else Some (len, Int64.to_int (Bytes.get_int64_le h 8), u32 h 16, u32 h 20)
    end

let cursor disk dir id ~next =
  let c = { cdisk = disk; cdir = dir; cid = id; cseg = 0; cfd = None; coff = 0; cnext = 1; cbuf = Bytes.create 4096 } in
  let segs = List.sort compare (segments disk dir) in
  (match List.fold_left (fun acc s -> if s <= next then Some s else acc) None segs with
   | None -> ()
   | Some s ->
     (* a segment whose header is not whole yet is opened again by [frames], once a durable group is in it *)
     c.cnext <- s;
     if cursor_open c s then begin
       (* the frames that end before [next], by their headers only *)
       let rec skip () =
         match cursor_header c with
         | Some (len, f0, count, _) when f0 = c.cnext && f0 + count <= next ->
           c.coff <- c.coff + fh + len + ft;
           c.cnext <- f0 + count;
           skip ()
         | _ -> ()
       in
       skip ()
     end);
  c

let cursor_next c = c.cnext

let frames ?(limit = max_int) c ~upto f =
  let left = ref limit in
  let rec go () =
    if c.cnext <= upto && !left > 0 then
      match cursor_header c with
      | Some (len, f0, count, bc) ->
        if f0 <> c.cnext then damaged "%s: the frame at %d starts at group %d, where %d was expected" (segment_name c.cseg) c.coff f0 c.cnext;
        if count = 0 || f0 + count - 1 > upto then
          (* a frame read before it was durable: [upto] is past its groups only once it is *)
          damaged "%s: the frame at %d (groups %d to %d) is not durable, below group %d" (segment_name c.cseg) c.coff f0 (f0 + count - 1) upto;
        if Bytes.length c.cbuf < len then c.cbuf <- Bytes.create (max len (2 * Bytes.length c.cbuf));
        (match c.cfd with Some fd -> c.cdisk.Disk.pread fd (c.coff + fh) c.cbuf 0 len | None -> ());
        if Crc32c.bytes c.cbuf 0 len <> bc then damaged "%s: the frame at %d (group %d) does not check" (segment_name c.cseg) c.coff f0;
        f ~first:f0 ~count ~crc:bc c.cbuf len;
        c.coff <- c.coff + fh + len + ft;
        c.cnext <- f0 + count;
        decr left;
        go ()
      | None ->
        (* the segment ends here: the next group is in the segment named by it *)
        if cursor_open c c.cnext then go ()
        else damaged "journal: group %d is durable and no frame holds it" c.cnext
  in
  go ()
