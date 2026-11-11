(* A run file holds one run of the LSM tree (Store): its two parts, in the pages a reader reads them by. A merge is
   the one way to make a run: it merges the delta and the newest runs of a view (sorted runs, merged as they stream,
   O'Neil et al. 1996) into a new file, page by page, so that it needs only the cache and a few page buffers whatever
   the size of the runs. A file: a header page, the pages that hold bytes (16 KiB each, in the order the merge
   finished them), then the page table: for each page of the run's layout, the file page that holds it and its
   CRC-32C. At open, the header, the page table, the rank and offset tables are checked (G7); every page is checked
   against its CRC each time it is read from the disk, so a damaged page is never served, even one damaged after the
   open. A run that fits in the cache is read whole at open; a larger one is read page by page as the questions need
   it. A run that does not check is set aside: the database rests on the runs that remain, then on the journal, which
   is always the truth.

     name             DIR/snapshots/<lo, 20 digits>-<hi, 20 digits>.run: the changes of groups lo+1..hi on top of the
                      state at lo (lo = 0: a bottom run, the whole state at hi)
     header (4096 B)  magic "CPHS" | format | database id | hi | lo | level | next thing | journal segment | journal
                      offset | journal group at that offset | first text | part a: rows, things range, things,
                      properties, texts, text bytes, hash bits, its 17 section offsets | part t: rows, things range,
                      things, properties, its 17 section offsets | layout length | file pages | crc of the page table
                      | crc of the header

   Recovery takes the newest chain of runs whose ranges follow one another from 0 (Snapshot.load), then replays the
   journal from the newest run's position, whose first group may come before its own (a merge in the background
   starts from a view that runs ahead of the disk): the groups up to the run's are skipped.

   A merge installs its file atomically (G12): written under a temporary name, forced, renamed, its directory forced;
   only then the runs it replaced are removed. A crash at any point leaves the old runs or the new one, whole. *)

let magic = 0x53485043 (* "CPHS" *)

(* format 7: the sections coded in blocks by a frame of reference, a page table; formats 5 and 6 (fixed 8-byte value
   words, the flag of a derived fact in bit 63 in format 6) are set aside at open, their groups replayed from the
   journal, as formats 1 to 4 were *)
let format = 8
let header = 4096

let name lo hi = Printf.sprintf "%020d-%020d.run" lo hi
let tmp_suffix = ".tmp"
let u32 b i = Int32.to_int (Bytes.get_int32_le b i) land 0xFFFFFFFF

(* the runs named in a directory: (lo, hi, file name) *)
let list disk dir =
  List.filter_map
    (fun n ->
      if Filename.check_suffix n ".run" && String.length n = 45 && n.[20] = '-' then
        match int_of_string_opt (String.sub n 0 20), int_of_string_opt (String.sub n 21 20) with
        | Some lo, Some hi when lo < hi -> Some (lo, hi, n)
        | _ -> None
      else None)
    (disk.Disk.readdir dir)

(* files of earlier formats (format 4 and before: <group>.snap) *)
let old_files disk dir = List.filter (fun n -> Filename.check_suffix n ".snap") (disk.Disk.readdir dir)

(* ---- writing a merge, page by page ----
   The sections of the new run are written by streams side by side, each in order, at their places in the run's
   layout (laid out by upper bounds); a page of the layout is complete once every byte of it is written (two sections
   can share a page), and goes out at once: the next page of the file, its CRC, its pwrite, the cache. What a
   section's stream does not reach of its room is counted written (zeros), and the pages it alone covers are never
   written: no page of the file holds them (they read as zeros), so a run takes on the disk the bytes it holds, not
   its bounds. The pages open at any time are those under the streams' heads and the pages two sections share: a
   handful. *)

type acc = { buf : Bytes.t; mutable filled : int }

type out = {
  disk : Disk.t;
  fd : Disk.fd;
  mutable unforced : int;  (* bytes written since the last fsync *)
  busy : unit -> bool;  (* the journal wrote a frame lately: clients wait for its fsyncs *)
  len : int;  (* bytes of the layout *)
  map : int array;  (* page of the layout -> page of the file, -1: none *)
  crcs : Bytes.t;  (* one CRC-32C a page of the layout: the table at the end of the file and the loader's check *)
  mutable next : int;  (* the next page of the file *)
  pg : Pages.t;
  admit : bool;  (* the pages enter the cache as they are written *)
  open_pages : (int, acc) Hashtbl.t;
  mutable done_pages : (int * Bytes.t) list;  (* complete, not yet written: (page of the file, bytes) *)
  mutable ndone : int;
  wbuf : Bytes.t;  (* neighbours written together, copied here *)
  mutable free : Bytes.t list;  (* pages written and not admitted: their buffers again *)
  olock : Mutex.t;  (* the columns' domain writes beside the pass by thing: a stream enters and closes pages under it *)
}

let open_max = ref 0 (* the most pages open at once in a merge of this process: for the tests *)

(* While clients write, a merge forces its file every [sync_every] bytes rather than once at the end: the disk then
   never holds hundreds of MB of a merge's dirty pages for a journal fsync to wait behind (measured at 3 M facts with
   merges beside the writes: the journal's fsync p99.9 1.6 s and max 4.7 s with one fsync at the end, 0.43 s and 1.0 s
   forced every 8 MiB; RocksDB's bytes_per_sync answers the same). Each fsync costs a merge time (a merge of 10 M
   facts: 2.8 s forced once, 10 s forced every 8 MiB), so a merge nobody waits beside (a snapshot, a recovery) forces
   once. *)
let sync_every = ref (8 lsl 20)

let zero_crc = Crc32c.bytes (Bytes.make Pages.size '\000') 0 Pages.size

(* the pages complete but not yet written: written together, a run of neighbours in the file with one pwrite, so that
   a merge makes a system call per few hundred KB rather than per page; the pages of the file are numbered in the
   order they complete, so the list is such a run *)
let batch = 32

let flush o =
  let l = List.sort (fun ((a : int), _) (b, _) -> compare a b) o.done_pages in
  o.done_pages <- [];
  o.ndone <- 0;
  let rec go = function
    | [] -> ()
    | (k, _) :: _ as l ->
      let rec run m = function (k', b) :: r when k' = k + m -> let bs, r = run (m + 1) r in b :: bs, r | r -> [], r in
      let bs, rest = run 0 l in
      let m = List.length bs in
      let buf = if m = 1 then List.hd bs else (List.iteri (fun i b -> Bytes.blit b 0 o.wbuf (i * Pages.size) Pages.size) bs; o.wbuf) in
      o.disk.Disk.pwrite o.fd (header + (k * Pages.size)) buf 0 (m * Pages.size);
      o.unforced <- o.unforced + (m * Pages.size);
      if not o.admit then List.iter (fun b -> o.free <- b :: o.free) bs;
      go rest
  in
  go l;
  if o.unforced >= !sync_every && o.busy () then begin
    o.disk.fsync o.fd;
    o.unforced <- 0
  end

let complete o k a =
  Hashtbl.remove o.open_pages k;
  let f = o.next in
  o.next <- f + 1;
  o.map.(k) <- f;
  Bytes.set_int32_le o.crcs (4 * k) (Int32.of_int (Crc32c.bytes a.buf 0 Pages.size));
  o.done_pages <- (f, a.buf) :: o.done_pages;
  o.ndone <- o.ndone + 1;
  if o.admit then Pages.admit o.pg k a.buf;
  if o.ndone >= batch then flush o

let need o k = min Pages.size (o.len - (k lsl Pages.bits))

let page_acc o k =
  match Hashtbl.find_opt o.open_pages k with
  | Some a -> a
  | None ->
    let buf = match o.free with b :: r -> o.free <- r; Bytes.fill b 0 Pages.size '\000'; b | [] -> Bytes.make Pages.size '\000' in
    let a = { buf; filled = 0 } in
    Hashtbl.replace o.open_pages k a;
    if Hashtbl.length o.open_pages > !open_max then open_max := Hashtbl.length o.open_pages;
    a

(* [n] bytes of page k counted written (their zeros) *)
let fill o k n =
  let a = page_acc o k in
  a.filled <- a.filled + n;
  if a.filled = need o k then complete o k a

(* a stream writes one section from [pos] to at most [stop]; [from]: where it started in its current page *)
type stream = { o : out; mutable pos : int; stop : int; mutable k : int; mutable a : acc; mutable from : int }

let no_page = { buf = Bytes.empty; filled = 0 }
let stream o off bytes = { o; pos = off; stop = Store.al (off + bytes); k = -1; a = no_page; from = off }

let leave s =
  if s.k >= 0 then begin
    s.a.filled <- s.a.filled + (s.pos - s.from);
    if s.a.filled = need s.o s.k then complete s.o s.k s.a
  end

let[@inline never] enter s =
  if s.pos >= s.stop then invalid_arg "Snapshot.merge: a section overflows";
  Mutex.lock s.o.olock;
  match
    leave s;
    s.k <- s.pos lsr Pages.bits;
    s.a <- page_acc s.o s.k;
    s.from <- s.pos
  with
  | () -> Mutex.unlock s.o.olock
  | exception e -> Mutex.unlock s.o.olock; raise e

(* writes of 2, 4 and 8 bytes are aligned to their size in a section that starts at a multiple of 8: none crosses a
   page *)
let[@inline] at s w =
  if s.pos lsr Pages.bits <> s.k then enter s;
  let o = s.pos land Pages.mask in
  s.pos <- s.pos + w;
  o

let put64 s x = let o = at s 8 in Bytes.set_int64_le s.a.buf o (Int64.of_int x)

(* bytes, as many as fit in each page at once *)
let put_sub s (src : Bytes.t) off n =
  let i = ref 0 in
  while !i < n do
    if s.pos lsr Pages.bits <> s.k then enter s;
    let o = s.pos land Pages.mask in
    let m = min (n - !i) (Pages.size - o) in
    Bytes.blit src (off + !i) s.a.buf o m;
    s.pos <- s.pos + m;
    i := !i + m
  done

let put_string s t = put_sub s (Bytes.unsafe_of_string t) 0 (String.length t)

(* A block of [n] bytes goes at the start of the next page unless it fits in the rest of this one: a block no larger
   than a page is then held by one page, and a reader reads its fields from that page's bytes, with no copy. The rest
   of the page counts written (zeros). Returns the bytes skipped. *)
let align_block s n =
  let left = Pages.size - (s.pos land Pages.mask) in
  if n <= Pages.size && n > left && left < Pages.size then begin
    if s.pos lsr Pages.bits <> s.k then enter s;
    s.pos <- s.pos + left;
    left
  end
  else 0

(* the end of a section: the rest of its room counts as written, zeros. Only its first and last pages can hold bytes
   of another section; a page all inside the rest is never written (no page of the file holds it) *)
let close_in s =
  if s.pos > s.stop then invalid_arg "Snapshot.merge: a section is longer than its room";
  let p = s.pos in
  leave s;
  s.k <- -1;
  if p < s.stop then begin
    let first = p lsr Pages.bits and last = (s.stop - 1) lsr Pages.bits in
    let part k =
      let k0 = k lsl Pages.bits in
      let a = max p k0 and z = min s.stop (k0 + need s.o k) in
      let whole = a = k0 && z = k0 + need s.o k && not (Hashtbl.mem s.o.open_pages k) in
      if a < z && not whole then fill s.o k (z - a)
    in
    part first;
    if last <> first then part last
  end;
  s.pos <- s.stop

let close s =
  Mutex.lock s.o.olock;
  match close_in s with () -> Mutex.unlock s.o.olock | exception e -> Mutex.unlock s.o.olock; raise e

(* ---- the coders of the sections: a scratch buffer of bits, then the bytes to a stream ---- *)

type scratch = { mutable sb : Bytes.t }

let room (sc : scratch) n = if Bytes.length sc.sb < n + 16 then sc.sb <- Bytes.create (max (n + 16) (2 * Bytes.length sc.sb))

(* A monotone sequence (Store.mono) written as it comes: 128 values a block, the block's header (its first value, the
   offset of its bits and its width) to [mh], its bits to [mb]. [cut] ends a block early: a value index starts its
   offsets at a block's start. *)
type mono = { mh : stream; mb : stream; mv : int array; mutable mn : int; mutable moff : int; mutable mblocks : int; msc : scratch }

let mono mh mb = { mh; mb; mv = Array.make Store.tb 0; mn = 0; moff = 0; mblocks = 0; msc = { sb = Bytes.create 1100 } }

let mono_cut m =
  if m.mn > 0 then begin
    let base = m.mv.(0) in
    let w = Pack.width (m.mv.(m.mn - 1) - base) in
    let nb = Store.pbytes m.mn w in
    room m.msc nb;
    Bytes.fill m.msc.sb 0 (nb + 8) '\000';
    for i = 0 to m.mn - 1 do Pack.put m.msc.sb (i * w) (m.mv.(i) - base) w done;
    put64 m.mh base;
    put64 m.mh ((m.moff lsl 8) lor w);
    put_sub m.mb m.msc.sb 0 nb;
    m.moff <- m.moff + nb;
    m.mn <- 0;
    m.mblocks <- m.mblocks + 1
  end

let mono_add m x =
  m.mv.(m.mn) <- x;
  m.mn <- m.mn + 1;
  if m.mn = Store.tb then mono_cut m

(* ---- The column order (Store's layout) ----
   Written in the pass by thing, which emits a part's rows in (thing, property, value) order: each property's rows come
   in thing order. A column a property: its blocks of 128 rows and their directory as they fill, its offsets from its
   first thing of several values on, and the presence of its things as bits until the pass ends, when the properties
   held by the same things share one rank table (a bit a thing between its first and its last, held while the pass
   runs). *)
type column = {
  cdir : stream;
  cdata : stream;
  coff : mono;
  mutable cdoff : int;  (* bytes of values written *)
  mutable crows : int;
  mutable cthings : int;
  mutable clast : int;  (* the thing of the last row, or -1 *)
  mutable cfirst : int;  (* the first row of the last thing *)
  mutable q0 : int;  (* the first thing of several values, or -1 *)
  mutable tlo : int;  (* the first thing, rounded down to 32 *)
  mutable pres : Bytes.t;  (* bit i: thing tlo + i holds the property *)
  cw : int array;
  ce : int array;
  cd : Bytes.t;
  mutable cn : int;
  csc : scratch;
}

let column cdir cdata coff =
  { cdir; cdata; coff; cdoff = 0; crows = 0; cthings = 0; clast = -1; cfirst = 0; q0 = -1; tlo = 0; pres = Bytes.empty;
    cw = Array.make Store.tb 0; ce = Array.make Store.tb 0; cd = Bytes.make Store.tb '\000'; cn = 0;
    csc = { sb = Bytes.create 1100 } }

(* the block under way coded: from its least value, or from each row's thing when that takes fewer bits *)
let col_flush c =
  let n = c.cn in
  if n > 0 then begin
    let fl = ref 0 and lw = ref max_int and hw = ref min_int and lr = ref max_int and hr = ref min_int in
    for k = 0 to n - 1 do
      if Bytes.unsafe_get c.cd k <> '\000' then fl := 1;
      let w = c.cw.(k) in
      let r = w - c.ce.(k) in
      if w < !lw then lw := w;
      if w > !hw then hw := w;
      if r < !lr then lr := r;
      if r > !hr then hr := r
    done;
    let wp = Pack.width (!hw - !lw) and wr = Pack.width (!hr - !lr) in
    let rel = wr < wp in
    let base = if rel then !lr else !lw in
    let wv = min 64 ((if rel then wr else wp) + !fl) in
    let nb = Store.pbytes n wv in
    room c.csc nb;
    let sb = c.csc.sb in
    Bytes.fill sb 0 (nb + 8) '\000';
    for k = 0 to n - 1 do
      let x = (if rel then c.cw.(k) - c.ce.(k) else c.cw.(k)) - base in
      if !fl = 0 then Pack.put sb (k * wv) x wv
      else begin
        if Bytes.unsafe_get c.cd k <> '\000' then Pack.put sb (k * wv) 1 1;
        Pack.put sb ((k * wv) + 1) x (wv - 1)
      end
    done;
    put64 c.cdir ((c.cdoff lsl 16) lor (((if rel then 2 else 0) lor !fl) lsl 8) lor wv);
    put64 c.cdir base;
    put_sub c.cdata sb 0 nb;
    c.cdoff <- c.cdoff + nb;
    c.cn <- 0
  end

(* the last thing's values are all there: its offset, from the first thing of several values on *)
let col_end_thing c =
  if c.clast >= 0 then begin
    let q = c.cthings - 1 in
    if c.q0 >= 0 then mono_add c.coff (c.crows - c.q0)
    else if c.crows - c.cfirst <> 1 then begin
      c.q0 <- q;
      mono_add c.coff 0;
      mono_add c.coff (c.crows - q)
    end
  end

let col_thing c e =
  col_end_thing c;
  if c.clast < 0 then (c.tlo <- e land lnot 31; c.pres <- Bytes.make 64 '\000');
  let i = e - c.tlo in
  if (i lsr 3) + 8 >= Bytes.length c.pres then begin
    let b = Bytes.make (max (2 * Bytes.length c.pres) ((i lsr 3) + 64)) '\000' in
    Bytes.blit c.pres 0 b 0 (Bytes.length c.pres);
    c.pres <- b
  end;
  Bytes.unsafe_set c.pres (i lsr 3) (Char.unsafe_chr (Char.code (Bytes.unsafe_get c.pres (i lsr 3)) lor (1 lsl (i land 7))));
  c.cthings <- c.cthings + 1;
  c.clast <- e;
  c.cfirst <- c.crows

let[@inline] col_add c e w d =
  if e <> c.clast then col_thing c e;
  let k = c.cn in
  Array.unsafe_set c.cw k w;
  Array.unsafe_set c.ce k e;
  Bytes.unsafe_set c.cd k (if d then '\001' else '\000');
  c.cn <- k + 1;
  c.crows <- c.crows + 1;
  if k + 1 = Store.tb then col_flush c

(* The columns of a part [l] for the rows' bounds [caps]: each property's rooms in its sections, in property order; a
   property with no room shares [none], whose streams have none: a row of it is a bug of the bounds *)
let columns o (l : Store.base) caps =
  let d = ref l.o_cdir and v = ref l.o_cdata and h = ref l.o_cmh and m = ref l.o_cmb in
  let ats = Array.make (Array.length caps) (0, 0, 0, 0) in
  let z = stream o 0 0 in
  let none = column z z (mono z z) in
  let cols =
    Array.mapi
      (fun p cap ->
        if cap = 0 then none
        else begin
          ats.(p) <- (!d, !v, !h, !m);
          let c =
            column (stream o !d (Store.cdir_room cap)) (stream o !v (Store.cdata_room cap))
              (mono (stream o !h (Store.cmh_room cap)) (stream o !m (Store.cmb_room cap)))
          in
          d := !d + Store.al (Store.cdir_room cap);
          v := !v + Store.al (Store.cdata_room cap);
          h := !h + Store.al (Store.cmh_room cap);
          m := !m + Store.al (Store.cmb_room cap);
          c
        end)
      caps
  in
  cols, ats, none

(* The pass by thing is over: each column's last block and offsets, the rank tables (one for the properties held by
   the same things), the entries. *)
let columns_end o (l : Store.base) (cols, ats, none) =
  let np = Array.length cols in
  if none.crows > 0 then invalid_arg "Snapshot.merge: a row of a property without room";
  let cp = stream o l.o_cp (64 * np) and rk = stream o l.o_crank (l.o_cdir - l.o_crank) in
  let rank_at = Array.make np (-1) and words = Array.make np 0 in
  let same c c' =
    c'.cthings = c.cthings && c'.tlo = c.tlo && c'.clast = c.clast
    && begin
      let n = ((c.clast - c.tlo) lsr 3) + 1 in
      let i = ref 0 in
      while !i < n && Bytes.unsafe_get c.pres !i = Bytes.unsafe_get c'.pres !i do incr i done;
      !i = n
    end
  in
  for p = 0 to np - 1 do
    let c = cols.(p) in
    if c != none then begin
      col_end_thing c;
      col_flush c;
      if c.q0 < 0 then c.q0 <- c.cthings else mono_cut c.coff;
      List.iter close [ c.cdir; c.cdata; c.coff.mh; c.coff.mb ];
      if c.cthings > 0 then begin
        let rep = ref (-1) and q = ref 0 in
        while !rep < 0 && !q < p do
          if rank_at.(!q) >= 0 && same c cols.(!q) then rep := !q;
          incr q
        done;
        if !rep >= 0 then (rank_at.(p) <- rank_at.(!rep); words.(p) <- words.(!rep))
        else begin
          let nw = ((c.clast - c.tlo) lsr 5) + 2 in
          rank_at.(p) <- rk.pos;
          words.(p) <- nw;
          let count = ref 0 in
          for j = 0 to nw - 2 do
            let bits = Int32.to_int (Bytes.get_int32_le c.pres (4 * j)) land 0xFFFFFFFF in
            put64 rk (bits lor (!count lsl 32));
            count := !count + Store.popcount bits
          done;
          put64 rk (!count lsl 32)
        end
      end
    end
  done;
  Array.iter (fun c -> c.pres <- Bytes.empty) cols;
  for p = 0 to np - 1 do
    let c = cols.(p) in
    let d, v, h, m = ats.(p) in
    if c == none || c.cthings = 0 then List.iter (put64 cp) [ 0; -1; 0; 0; d; v; h; m ]
    else List.iter (put64 cp) [ c.tlo; rank_at.(p); words.(p); c.q0; d; v; h; m ]
  done;
  List.iter close [ cp; rk ]

(* The columns' domain. The pass by thing hands it a part's rows in chunks of 8192, in order; it fills that part's
   columns while the pass goes on (with a disk that is not parallel, the simulation's, the pass fills them itself). At
   most 8 chunks wait: the memory stays bounded. *)
let chunk_rows = 8192

type chunk = { he : int array; hp : int array; hw : int array; hd : Bytes.t; mutable hn : int; hcols : column array }

type feed = {
  par : bool;
  fm : Mutex.t;
  fc : Condition.t;
  chunks : chunk Queue.t;
  mutable spare : chunk list;
  mutable ended : bool;
  mutable failed : exn option;
}

let chunk cols =
  { he = Array.make chunk_rows 0; hp = Array.make chunk_rows 0; hw = Array.make chunk_rows 0;
    hd = Bytes.make chunk_rows '\000'; hn = 0; hcols = cols }

let feed par = { par; fm = Mutex.create (); fc = Condition.create (); chunks = Queue.create (); spare = []; ended = false; failed = None }

(* a full chunk to the columns' domain, and an empty one back for the same part *)
let hand f (c : chunk) =
  Mutex.lock f.fm;
  while Queue.length f.chunks >= 8 && f.failed = None do Condition.wait f.fc f.fm done;
  (match f.failed with Some e -> Mutex.unlock f.fm; raise e | None -> ());
  Queue.push c f.chunks;
  let mine, others = List.partition (fun x -> x.hcols == c.hcols) f.spare in
  let fresh = match mine with x :: rest -> f.spare <- rest @ others; x.hn <- 0; Some x | [] -> None in
  Condition.broadcast f.fc;
  Mutex.unlock f.fm;
  match fresh with Some x -> x | None -> chunk c.hcols

(* the columns' domain: every chunk in order, until the pass ends *)
let columns_domain f =
  let rec next () =
    Mutex.lock f.fm;
    while Queue.is_empty f.chunks && not f.ended do Condition.wait f.fc f.fm done;
    let c = if Queue.is_empty f.chunks then None else Some (Queue.pop f.chunks) in
    Condition.broadcast f.fc;
    Mutex.unlock f.fm;
    match c with
    | None -> ()
    | Some c ->
      for k = 0 to c.hn - 1 do
        col_add (Array.unsafe_get c.hcols (Array.unsafe_get c.hp k)) (Array.unsafe_get c.he k) (Array.unsafe_get c.hw k)
          (Bytes.unsafe_get c.hd k <> '\000')
      done;
      Mutex.lock f.fm;
      f.spare <- c :: f.spare;
      Mutex.unlock f.fm;
      next ()
  in
  match next () with
  | () -> ()
  | exception e -> Mutex.lock f.fm; f.failed <- Some e; Condition.broadcast f.fc; Mutex.unlock f.fm

(* the pass is over, or failed: the last chunks handed (none after a failure), the domain joined, its failure raised *)
let feed_end f dom last =
  Mutex.lock f.fm;
  List.iter (fun c -> if c.hn > 0 then Queue.push c f.chunks) last;
  f.ended <- true;
  Condition.broadcast f.fc;
  Mutex.unlock f.fm;
  Domain.join dom;
  match f.failed with Some e -> raise e | None -> ()

(* A part's things, as a merge emits their rows in (thing, property, value) order: the rank table, a block of 128
   slots at a time (Store's layout), its offset in the directory. *)
type tblocks = {
  rk : stream;  (* the rank table *)
  dir : stream;
  data : stream;
  mutable doff : int;  (* bytes of data written *)
  mutable bits : int;  (* the rank word under way: the things held among the current 32 *)
  mutable rank : int;  (* things before the current 32 *)
  mutable things : int;  (* things held *)
  mutable rows : int;
  mutable last : int;  (* the thing of the last row, or -1 *)
  (* the block under way: its rows (slot in the block, property, value, derived) *)
  mutable bs : int;  (* its slots *)
  mutable si : int array;
  mutable bp : int array;
  mutable bw : int array;
  mutable bd : Bytes.t;
  mutable nr : int;
  ent : int array;  (* property -> its entry in the block, or -1 *)
  tsc : scratch;
  cnt : int array;  (* a slot's values of one entry *)
  cols : column array;  (* the part's columns, a property each *)
  feed : feed;
  mutable ch : chunk;  (* the rows under way to the columns' domain *)
}

let tblocks ~np ~cols ~feed rk dir data =
  { rk; dir; data; doff = 0; bits = 0; rank = 0; things = 0; rows = 0; last = -1; bs = 0; si = Array.make 1024 0;
    bp = Array.make 1024 0; bw = Array.make 1024 0; bd = Bytes.make 1024 '\000'; nr = 0; ent = Array.make (max 1 np) (-1);
    tsc = { sb = Bytes.create 65536 }; cnt = Array.make (Store.tb + 1) 0; cols; feed; ch = (if feed.par then chunk cols else chunk [||]) }

(* The block under way coded and written, as Store reads it: its entries by property, each either a fixed field of
   every slot's record (a property every slot has at most once, when that is shorter: its value, a bit "present" when
   some slot lacks it, the derived flag when some value has one) or a column of its own (its slots' offsets, c i + a
   residual, and its values); then the records, R bits each (a bit "has values in a column" first when there are
   columns), then the columns' data. *)
let tblock_flush t =
  if t.bs > 0 then begin
    let nr = t.nr and b = t.bs in
    (* the properties of the block, in order *)
    let props = ref [] in
    for r = 0 to nr - 1 do let p = t.bp.(r) in if t.ent.(p) < 0 then (t.ent.(p) <- 0; props := p :: !props) done;
    let props = Array.of_list (List.sort compare !props) in
    let m = Array.length props in
    if m > 0xFFFF then invalid_arg "Snapshot.merge: a block of more than 65535 properties";
    Array.iteri (fun j p -> t.ent.(p) <- j) props;
    let cmin = Array.make m max_int and cmax = Array.make m 0 and lo = Array.make m max_int and hi = Array.make m min_int
    and fl = Array.make m 0 and total = Array.make m 0 in
    let cnt = Array.make m 0 and first = Array.make (b + 1) 0 in
    (* the rows of slot k: first.(k) .. first.(k + 1) - 1 (rows come by slot, then property, then value) *)
    let r = ref 0 in
    for k = 0 to b - 1 do
      first.(k) <- !r;
      Array.fill cnt 0 m 0;
      while !r < nr && t.si.(!r) = k do
        let j = t.ent.(t.bp.(!r)) and w = t.bw.(!r) in
        cnt.(j) <- cnt.(j) + 1;
        if w < lo.(j) then lo.(j) <- w;
        if w > hi.(j) then hi.(j) <- w;
        if Bytes.unsafe_get t.bd !r <> '\000' then fl.(j) <- 1;
        incr r
      done;
      for j = 0 to m - 1 do
        if cnt.(j) < cmin.(j) then cmin.(j) <- cnt.(j);
        if cnt.(j) > cmax.(j) then cmax.(j) <- cnt.(j);
        total.(j) <- total.(j) + cnt.(j)
      done
    done;
    first.(b) <- nr;
    let wv = Array.init m (fun j -> min 64 (Pack.width (hi.(j) - lo.(j)) + fl.(j))) in
    let res j = total.(j) - (cmin.(j) * b) in
    let wr = Array.init m (fun j -> if cmax.(j) = cmin.(j) then 0 else Pack.width (res j)) in
    Array.iteri (fun j c -> if c > 0xFFFFFFFF || res j > 0xFFFFFFFF then invalid_arg "Snapshot.merge: a thing with too many values") cmin;
    let colbits j = (if wr.(j) = 0 then 0 else 8 * Store.pbytes (b + 1) wr.(j)) + (8 * Store.pbytes total.(j) wv.(j)) in
    (* a fixed field when the property is at most once a slot, fits a field, and takes no more bits than a column *)
    let fw j = wv.(j) + if cmin.(j) = 0 then 1 else 0 in
    let fixed = Array.init m (fun j -> cmax.(j) <= 1 && fw j <= 63 && b * fw j <= colbits j) in
    let hv = Array.exists not fixed in
    let pos = Array.make m 0 and rbits = ref (if hv then 1 else 0) in
    for j = 0 to m - 1 do if fixed.(j) then (pos.(j) <- !rbits; rbits := !rbits + fw j) done;
    let rr = !rbits in
    if rr > 0xFFFFFFFF then invalid_arg "Snapshot.merge: a block too large";
    let head = Store.al (16 + (20 * m)) in
    let recb = Store.pbytes (b * rr) 1 in
    let doff = Array.make m 0 and d = ref (head + recb) in
    for j = 0 to m - 1 do if not fixed.(j) then (doff.(j) <- !d; d := !d + (colbits j / 8)) done;
    let total_bytes = Store.al !d in
    room t.tsc total_bytes;
    let sb = t.tsc.sb in
    Bytes.fill sb 0 (total_bytes + 8) '\000';
    Bytes.set_uint16_le sb 0 b;
    Bytes.set_uint16_le sb 2 m;
    Bytes.set_uint8 sb 4 (if hv then 1 else 0);
    Bytes.set_int32_le sb 8 (Int32.of_int rr);
    for j = 0 to m - 1 do
      let e = 16 + (16 * j) in
      Bytes.set_uint16_le sb e props.(j);
      Bytes.set_uint8 sb (e + 2) wv.(j);
      let mode =
        (fl.(j) lsl 7) lor if fixed.(j) then 0x40 lor (if cmin.(j) = 0 then 0x20 else 0) else wr.(j)
      in
      Bytes.set_uint8 sb (e + 3) mode;
      Bytes.set_int32_le sb (e + 4) (Int32.of_int (if fixed.(j) then pos.(j) else cmin.(j)));
      Bytes.set_int64_le sb (e + 8) (Int64.of_int lo.(j));
      Bytes.set_int32_le sb (16 + (16 * m) + (4 * j)) (Int32.of_int doff.(j))
    done;
    (* a value in w bits at bit [at]: the flag in the lowest bit when the entry has one *)
    let put_value at j x =
      let w = wv.(j) in
      if fl.(j) = 0 then Pack.put sb at (t.bw.(x) - lo.(j)) w
      else begin
        if Bytes.unsafe_get t.bd x <> '\000' then Pack.put sb at 1 1;
        Pack.put sb (at + 1) (t.bw.(x) - lo.(j)) (w - 1)
      end
    in
    (* the records *)
    let rec0 = head * 8 in
    for k = 0 to b - 1 do
      let at = rec0 + (k * rr) in
      let anyv = ref false in
      for x = first.(k) to first.(k + 1) - 1 do
        let j = t.ent.(t.bp.(x)) in
        if fixed.(j) then begin
          let fa = at + pos.(j) in
          if cmin.(j) = 0 then (Pack.put sb fa 1 1; put_value (fa + 1) j x) else put_value fa j x
        end
        else anyv := true
      done;
      if hv && !anyv then Pack.put sb at 1 1
    done;
    (* the columns: offsets (residuals) and values *)
    for j = 0 to m - 1 do
      if not fixed.(j) then begin
        let base = doff.(j) * 8 in
        let w = wr.(j) and c = cmin.(j) in
        let vbase = base + if w = 0 then 0 else 8 * Store.pbytes (b + 1) w in
        let acc = ref 0 and v = ref 0 in
        for k = 0 to b - 1 do
          if w > 0 then Pack.put sb (base + (k * w)) (!acc - (c * k)) w;
          for x = first.(k) to first.(k + 1) - 1 do
            if t.ent.(t.bp.(x)) = j then begin
              put_value (vbase + (!v * wv.(j))) j x;
              incr v;
              incr acc
            end
          done
        done;
        if w > 0 then Pack.put sb (base + (b * w)) (!acc - (c * b)) w
      end
    done;
    Array.iter (fun p -> t.ent.(p) <- -1) props;
    t.doff <- t.doff + align_block t.data total_bytes;
    put64 t.dir t.doff;
    put_sub t.data sb 0 total_bytes;
    t.doff <- t.doff + total_bytes;
    t.bs <- 0;
    t.nr <- 0
  end

let grow t =
  let n = 2 * Array.length t.si in
  let g a = let a' = Array.make n 0 in Array.blit a 0 a' 0 t.nr; a' in
  t.si <- g t.si; t.bp <- g t.bp; t.bw <- g t.bw;
  let d = Bytes.make n '\000' in
  Bytes.blit t.bd 0 d 0 t.nr;
  t.bd <- d

(* the rank words up to thing e (excluded), then e's slot opened *)
let new_thing t e =
  if t.last >= 0 && (t.last lsr 5) < (e lsr 5) then begin
    (* the words of the 32-blocks between the last thing and e *)
    put64 t.rk (t.bits lor (t.rank lsl 32));
    t.rank <- t.things;
    t.bits <- 0;
    for _ = (t.last lsr 5) + 1 to (e lsr 5) - 1 do put64 t.rk (t.rank lsl 32) done
  end
  else if t.last < 0 then for _ = 0 to (e lsr 5) - 1 do put64 t.rk 0 done;
  t.bits <- t.bits lor (1 lsl (e land 31));
  if t.bs = Store.tb then tblock_flush t;
  t.bs <- t.bs + 1;
  t.things <- t.things + 1;
  t.last <- e

let[@inline] row t e p w d =
  if e <> t.last then new_thing t e;
  if t.nr = Array.length t.si then grow t;
  let r = t.nr in
  Array.unsafe_set t.si r (t.bs - 1);
  Array.unsafe_set t.bp r p;
  Array.unsafe_set t.bw r w;
  Bytes.unsafe_set t.bd r (if d then '\001' else '\000');
  t.nr <- r + 1;
  t.rows <- t.rows + 1;
  if not t.feed.par then col_add (Array.unsafe_get t.cols p) e w d
  else begin
    let c = t.ch in
    let k = c.hn in
    Array.unsafe_set c.he k e;
    Array.unsafe_set c.hp k p;
    Array.unsafe_set c.hw k w;
    Bytes.unsafe_set c.hd k (if d then '\001' else '\000');
    c.hn <- k + 1;
    if k + 1 = chunk_rows then t.ch <- hand t.feed c
  end

(* the part's end: the last block, the rank words up to ne, the directory's end *)
let tblocks_end t ne =
  tblock_flush t;
  if ne > 0 then begin
    let last_block = (ne - 1) lsr 5 in
    if t.last < 0 then for _ = 0 to last_block do put64 t.rk 0 done
    else begin
      put64 t.rk (t.bits lor (t.rank lsl 32));
      t.rank <- t.things;
      for _ = (t.last lsr 5) + 1 to last_block do put64 t.rk (t.rank lsl 32) done
    end
  end;
  put64 t.rk (t.things lsl 32);
  put64 t.dir t.doff

(* A part's rows by property, as a merge emits them in (property, value, thing) order: blocks of 128 rows, their
   directory (offset, first value), and the value index of the properties that have one. *)
type vblocks = {
  poffs : stream;
  pblks : stream;
  pdists : stream;
  pidxs : stream;
  vdir : stream;
  vdata : stream;
  vrank : stream;
  voff : mono;
  mutable voff_blocks : int;
  mutable vdoff : int;
  mutable vblocks : int;
  mutable vrows : int;
  (* the property under way *)
  mutable p0 : int;  (* its first row *)
  mutable dist : int;
  mutable lastw : int;
  (* its value index, when it has one: its range, its first word, the word under way *)
  mutable idx : bool;
  mutable vlo : int;
  mutable words : int;
  mutable wq : int;  (* the word under way, from vlo *)
  mutable wbits : int;
  mutable wcount : int;
  mutable rwords : int;  (* rank words written, every property's *)
  (* the row block under way *)
  rw : int array;
  re : int array;
  rd : Bytes.t;
  mutable rn : int;
  vsc : scratch;
}

let vblocks poffs pblks pdists pidxs vdir vdata vrank voff =
  { poffs; pblks; pdists; pidxs; vdir; vdata; vrank; voff; voff_blocks = 0; vdoff = 0; vblocks = 0; vrows = 0; p0 = 0;
    dist = 0; lastw = 0; idx = false; vlo = 0; words = 0; wq = 0; wbits = 0; wcount = 0; rwords = 0; rw = Array.make Store.tb 0;
    re = Array.make Store.tb 0; rd = Bytes.make Store.tb '\000'; rn = 0; vsc = { sb = Bytes.create 2200 } }

let vblock_flush v =
  let n = v.rn in
  if n > 0 then begin
    let first = v.rw.(0) and fl = ref 0 and tl = ref max_int and th = ref min_int in
    for k = 0 to n - 1 do
      if Bytes.unsafe_get v.rd k <> '\000' then fl := 1;
      let e = v.re.(k) in
      if e < !tl then tl := e;
      if e > !th then th := e
    done;
    let wv = min 64 (Pack.width (v.rw.(n - 1) - first) + !fl) and wt = Pack.width (!th - !tl) in
    if !tl < 0 || !tl > 0xFFFFFFFF then invalid_arg "Snapshot.merge: a thing out of range";
    (* the things by gaps when that takes fewer bits: a row of the same value as the one before from its thing, the
       others from the least *)
    let gap k = if k > 0 && v.rw.(k) = v.rw.(k - 1) then v.re.(k) - v.re.(k - 1) - 1 else v.re.(k) - !tl in
    let wg = ref 0 in
    for k = 0 to n - 1 do let w = Pack.width (gap k) in if w > !wg then wg := w done;
    let gaps = !wg < wt in
    let wt = if gaps then !wg else wt in
    let nv = Store.pbytes n wv in
    let total = Store.al (8 + nv + Store.pbytes n wt) in
    room v.vsc total;
    let sb = v.vsc.sb in
    Bytes.fill sb 0 (total + 8) '\000';
    Bytes.set_uint8 sb 0 wv;
    Bytes.set_uint8 sb 1 !fl;
    Bytes.set_uint8 sb 2 wt;
    Bytes.set_uint8 sb 3 (if gaps then 1 else 0);
    Bytes.set_int32_le sb 4 (Int32.of_int !tl);
    for k = 0 to n - 1 do
      if !fl = 0 then Pack.put sb (64 + (k * wv)) (v.rw.(k) - first) wv
      else begin
        if Bytes.unsafe_get v.rd k <> '\000' then Pack.put sb (64 + (k * wv)) 1 1;
        Pack.put sb (64 + (k * wv) + 1) (v.rw.(k) - first) (wv - 1)
      end;
      Pack.put sb ((8 + nv) * 8 + (k * wt)) (if gaps then gap k else v.re.(k) - !tl) wt
    done;
    v.vdoff <- v.vdoff + align_block v.vdata total;
    put64 v.vdir v.vdoff;
    put64 v.vdir first;
    put_sub v.vdata sb 0 total;
    v.vdoff <- v.vdoff + total;
    v.vblocks <- v.vblocks + 1;
    v.rn <- 0
  end

(* the rank words of the value index up to word q (excluded) *)
let words_to v q =
  while v.wq < q do
    put64 v.vrank (v.wbits lor (v.wcount lsl 32));
    v.wcount <- v.wcount + Store.popcount v.wbits;
    v.wbits <- 0;
    v.wq <- v.wq + 1;
    v.rwords <- v.rwords + 1
  done

(* property p begins: [idx] its value index's range (vlo, words), or None *)
let vprop v ~idx =
  put64 v.poffs v.vrows;
  put64 v.pblks v.vblocks;
  v.p0 <- v.vrows;
  v.dist <- 0;
  match idx with
  | Some (vlo, words) ->
    v.idx <- true;
    v.vlo <- vlo;
    v.words <- words;
    v.wq <- 0;
    v.wbits <- 0;
    v.wcount <- 0;
    put64 v.pidxs vlo;
    put64 v.pidxs v.rwords;
    put64 v.pidxs words;
    put64 v.pidxs v.voff.mblocks
  | None ->
    v.idx <- false;
    put64 v.pidxs 0;
    put64 v.pidxs (-1);
    put64 v.pidxs 0;
    put64 v.pidxs 0

let vrow v w e d =
  if v.dist = 0 || w <> v.lastw then begin
    if v.idx then begin
      let x = w - v.vlo in
      if x < 0 || x lsr 5 >= v.words - 1 then invalid_arg "Snapshot.merge: a value out of its index's range";
      words_to v (x lsr 5);
      v.wbits <- v.wbits lor (1 lsl (x land 31));
      mono_add v.voff (v.vrows - v.p0)
    end;
    v.dist <- v.dist + 1;
    v.lastw <- w
  end;
  v.rw.(v.rn) <- w;
  v.re.(v.rn) <- e;
  Bytes.unsafe_set v.rd v.rn (if d then '\001' else '\000');
  v.rn <- v.rn + 1;
  v.vrows <- v.vrows + 1;
  if v.rn = Store.tb then vblock_flush v

(* property p ends: its last row block, its distinct values, its value index's last words and offsets *)
let vprop_end v =
  vblock_flush v;
  put64 v.pdists v.dist;
  if v.idx then begin
    words_to v (v.words - 1);
    put64 v.vrank (v.wcount lsl 32);
    v.rwords <- v.rwords + 1;
    mono_add v.voff (v.vrows - v.p0);
    mono_cut v.voff
  end

let vblocks_end v =
  put64 v.poffs v.vrows;
  put64 v.pblks v.vblocks;
  put64 v.vdir v.vdoff;
  put64 v.vdir 0

type written = {
  tmp : string;
  path : string;
  group : int;
  view : Store.view;
  replaced : Store.run list;  (* the runs the new one replaces *)
  sync : unit -> unit;  (* the file's fsync *)
  mutable forced : bool;  (* its bytes are durable: [install] forces it first otherwise *)
}

(* The file of [w] forced, once. *)
let force w = if not w.forced then (w.sync (); w.forced <- true)

(* ---- the merge of the sources' entries ----
   The sources are a large group's facts (Bulk, all additions: age 0), the delta (age 1) and the merged runs (run j:
   age j + 2), each giving an entry for a fact as the delta writes one (Store.tdelta): bits 0-1 the state it leaves
   (absent, asserted, only derived), bits 2-3 the state below it. A run's addition is 1 (3 derived): absent below it,
   for a run adds only facts absent below it, or that it retracts itself; its retraction is 4 (12): present below it.
   A run that changed a fact's flag holds both: the addition is its newer entry, the retraction its older.
   For one fact, the newest entry says its state in the new run's view, the oldest one its state below the merged
   runs; the new run holds nothing when the two agree, else a retraction of the state below (if the fact was there)
   and an addition of the new one (if it is there): a flag changed is the pair, so that counts stay exact. *)

let[@inline] fin c = Store.state_of_entry c
let[@inline] below c = Store.state_of_entry (c lsr 2)

(* a cursor over the rows of a property in a source part, a block decoded at a time *)
type cur = {
  cb : Store.base;
  cp : int;
  mutable cr : int;
  cstop : int;
  cw : int array;
  ce : int array;
  cd : Bytes.t;
  mutable ck : int;
  mutable cn : int;
}

let refill c =
  let n = min Store.tb (c.cstop - c.cr) in
  let i = ref 0 in
  Store.scan c.cb c.cp c.cr (c.cr + n) (fun e w d ->
      c.ce.(!i) <- e;
      c.cw.(!i) <- w;
      Bytes.unsafe_set c.cd !i (if d then '\001' else '\000');
      incr i);
  c.ck <- 0;
  c.cn <- n

let cursor (b : Store.base) p =
  let r0, r1 = if p < b.np && b.n > 0 then Store.cpoff b p, Store.cpoff b (p + 1) else 0, 0 in
  let c =
    { cb = b; cp = p; cr = r0; cstop = r1; cw = Array.make Store.tb 0; ce = Array.make Store.tb 0;
      cd = Bytes.make Store.tb '\000'; ck = 0; cn = 0 }
  in
  if r0 < r1 then refill c;
  c

let[@inline] live c = c.cr < c.cstop

let[@inline] advance c =
  c.cr <- c.cr + 1;
  c.ck <- c.ck + 1;
  if c.ck = c.cn && c.cr < c.cstop then refill c

(* The bounds of a part's output, property by property, from its sources: the rows (an upper bound) and the values
   (least and greatest). lo > hi: no value. *)
type bounds = { rows : int array; lo : int array; hi : int array }

let bounds np = { rows = Array.make (max 1 np) 0; lo = Array.make (max 1 np) max_int; hi = Array.make (max 1 np) min_int }

let widen bd p lo hi rows =
  if rows > 0 then begin
    bd.rows.(p) <- bd.rows.(p) + rows;
    if lo < bd.lo.(p) then bd.lo.(p) <- lo;
    if hi > bd.hi.(p) then bd.hi.(p) <- hi
  end

let of_part bd np (b : Store.base) =
  for p = 0 to min np b.np - 1 do
    let n = Store.base_count_p b p in
    if n > 0 then
      widen bd p (Store.base_pvalue b p (Store.cpoff b p)) (Store.base_pvalue b p (Store.cpoff b (p + 1) - 1)) n
  done

(* The value index of p: its range and rank words, when its rank table takes at most 2 bytes a row (or 4 KiB) *)
let index_of bd p =
  let lo = bd.lo.(p) and hi = bd.hi.(p) and rows = bd.rows.(p) in
  if rows = 0 || lo > hi || hi - lo < 0 then None
  else
    let words = ((hi - lo) lsr 5) + 2 in
    if 8 * words <= max 4096 (2 * rows) then Some (lo, words) else None

(* The merge of [v]'s delta and its [take] newest runs into one run at [level], with [pos] the journal position replay
   starts from (pos.next <= v.group + 1). Written under a temporary name and forced (also on the way, while [busy]
   says clients write; with [~sync:false], not at the end: [force] does it later, or [install]); [install] gives it its
   name, forced first. On a failure of the disk, the file is removed and the failure raised. *)
let no_bulk = Bulk.empty

let merge ?(busy = fun () -> false) ?(bulk = no_bulk) ?(sync = true) disk dir id (v : Store.view) ~take ~level
    (pos : Journal.position) =
  if pos.next > v.group + 1 then invalid_arg "Snapshot.merge: the journal position is after the view";
  let rs = v.runs in
  let nr = Array.length rs in
  if take < 0 || take > nr then invalid_arg "Snapshot.merge: more runs than the view has";
  let bottom = take = nr in
  let lo = if bottom then 0 else rs.(take).hi in
  let src = Array.sub rs 0 take in
  (* the delta's additions, retractions and things *)
  let da = ref 0 and dt = ref 0 in
  Store.IM.iter
    (fun _ (td : Store.tdelta) -> Store.PW.iter (fun _ st -> if st land 1 <> 0 then incr da; if st land 4 <> 0 then incr dt) td.tf)
    v.delta.de;
  let dthings = Store.IM.cardinal v.delta.de in
  let ne = Store.max_thing v + 1 and np = Schema.count v.schema in
  let s0 = if take = 0 then v.dict.chunks.c0 else src.(take - 1).s0 in
  let s1 = v.dict.dnext in
  let ns = s1 - s0 in
  let sblob = ref 0 in
  Array.iter (fun (r : Store.run) -> sblob := !sblob + r.a.sblob) src;
  for i = v.dict.chunks.c0 to s1 - 1 do sblob := !sblob + String.length (Store.text v i) done;
  let sum f = Array.fold_left (fun n r -> n + f r) 0 src in
  let a_ncap = sum (fun r -> r.a.n) + !da + bulk.n and a_kcap = min ne (sum (fun r -> r.a.k) + dthings + bulk.n) in
  let t_ncap = if bottom then 0 else sum (fun r -> r.t.n) + !dt
  and t_kcap = if bottom then 0 else min ne (sum (fun r -> r.t.k) + dthings) in
  let t_ne = if bottom then 0 else ne and t_np = if bottom then 0 else np in
  (* the bounds of each property's rows and values, for the room of its rows and its value index *)
  let ba = bounds np and bt = bounds np in
  Array.iter (fun (r : Store.run) -> of_part ba np r.a; of_part bt np r.t) src;
  Store.IM.iter
    (fun p (pd : Store.pdelta) ->
      if p < np && not (Store.IM.is_empty pd.pm) then begin
        let n = Store.IM.fold (fun _ (vd : Store.vdelta) n -> n + Store.IM.cardinal vd.vm) pd.pm 0 in
        let lo = fst (Store.IM.min_binding pd.pm) and hi = fst (Store.IM.max_binding pd.pm) in
        widen ba p lo hi n;
        widen bt p lo hi n
      end)
    v.delta.dav;
  for p = 0 to min np (Array.length bulk.poff - 1) - 1 do
    let r0 = bulk.poff.(p) and r1 = bulk.poff.(p + 1) in
    if r1 > r0 then widen ba p (Bulk.pword bulk r0) (Bulk.pword bulk (r1 - 1)) (r1 - r0)
  done;
  let idx_a = Array.init np (index_of ba) and idx_t = Array.init t_np (index_of bt) in
  let vcap bd idx np =
    let vb = ref 0 and vw = ref 0 and vm = ref 0 in
    for p = 0 to np - 1 do
      vb := !vb + Store.blocks128 bd.rows.(p);
      match idx.(p) with Some (_, w) -> vw := !vw + w; vm := !vm + Store.blocks128 (bd.rows.(p) + 1) | None -> ()
    done;
    !vb, !vw, !vm
  in
  let a_vb, a_vw, a_vm = vcap ba idx_a np and t_vb, t_vw, t_vm = vcap bt idx_t t_np in
  let hbits = Store.hbits_for ns in
  let caps_a = Array.init np (fun p -> ba.rows.(p)) and caps_t = Array.init t_np (fun p -> bt.rows.(p)) in
  let ra = Store.rooms ~n_cap:a_ncap ~k_cap:a_kcap ~np ~vb_cap:a_vb ~vm_blocks:a_vm ~ns ~sblob:!sblob ~ne ~caps:caps_a in
  let rt = Store.rooms ~n_cap:t_ncap ~k_cap:t_kcap ~np:t_np ~vb_cap:t_vb ~vm_blocks:t_vm ~ns:0 ~sblob:0 ~ne:t_ne ~caps:caps_t in
  let la =
    Store.layout ~at:0 ~n:0 ~ne ~k:0 ~k_cap:a_kcap ~np ~ns ~sblob:!sblob ~hbits ~vb_cap:a_vb ~vwords:a_vw ~vm_blocks:a_vm ra ()
  in
  let lt =
    Store.layout ~at:la.len ~n:0 ~ne:t_ne ~k:0 ~k_cap:t_kcap ~np:t_np ~ns:0 ~sblob:0 ~hbits:0 ~vb_cap:t_vb ~vwords:t_vw
      ~vm_blocks:t_vm rt ()
  in
  let len = lt.len in
  let npages = Pages.pages len in
  let path = Filename.concat dir (name lo v.group) in
  let tmp = path ^ tmp_suffix in
  if disk.Disk.exists tmp then disk.remove tmp;
  let fd = disk.openf tmp true in
  let crcs = Bytes.make (4 * npages) '\000' and map = Array.make npages (-1) in
  let load k =
    let f = map.(k) in
    if f < 0 then Bytes.make Pages.size '\000'
    else begin
      let p = Bytes.create Pages.size in
      (try disk.pread fd (header + (f * Pages.size)) p 0 Pages.size with Disk.Io m -> raise (Pages.Unreadable m));
      if Crc32c.bytes p 0 Pages.size <> u32 crcs (4 * k) then
        raise (Pages.Unreadable (Printf.sprintf "run %s: page %d does not check" (Filename.basename path) k));
      p
    end
  in
  let pg = Pages.on_file len load in
  (* a large group's run is a load's: its pages are read later, from the file, rather than held now *)
  let o =
    { olock = Mutex.create (); disk; fd; unforced = 0; busy; len; map; crcs; next = 0; pg; admit = bulk.n = 0; open_pages = Hashtbl.create 16;
      done_pages = []; ndone = 0; wbuf = Bytes.create (batch * Pages.size); free = [] }
  in
  let failed () = (try disk.close fd with Disk.Io _ -> ()); (try disk.remove tmp with Disk.Io _ -> ()) in
  let ca = columns o la caps_a and ct = columns o lt caps_t in
  let fd_cols = feed (disk.parallel && a_ncap + t_ncap >= 4 * chunk_rows) in
  let ta =
    tblocks ~np ~cols:(let c, _, _ = ca in c) ~feed:fd_cols (stream o la.o_erank (8 * (Store.blocks ne + 1)))
      (stream o la.o_tdir (8 * (Store.blocks128 a_kcap + 1))) (stream o la.o_tdata ra.tdata)
  and tt =
    tblocks ~np:t_np ~cols:(let c, _, _ = ct in c) ~feed:fd_cols (stream o lt.o_erank (8 * (Store.blocks t_ne + 1)))
      (stream o lt.o_tdir (8 * (Store.blocks128 t_kcap + 1))) (stream o lt.o_tdata rt.tdata)
  in
  let na = ref 0 and nt = ref 0 in
  match
    disk.truncate fd 0;
    (* ---- by thing: the pass, its columns filled beside it by the columns' domain ---- *)
    let dom = if fd_cols.par then Some (Domain.spawn (fun () -> columns_domain fd_cols)) else None in
    let pass () =
      (* ---- by thing: the rank tables, the blocks of 128 things held, their directory ---- *)
      let emit_a e p w d = row ta e p w d
      and emit_t e p w d = if bottom then invalid_arg "Snapshot.merge: a retraction with nothing below"; row tt e p w d in
      (* a fact whose state is [f] in the new view and [b] below the merged runs (0 absent, 1 asserted, 2 derived) *)
      let out e p w f b =
        if f <> b then begin
          if b > 0 then emit_t e p w (b = 2);
          if f > 0 then emit_a e p w (f = 2)
        end
      in
      (* the delta's next thing, its changes, the rest *)
      let dnext = ref (Store.IM.to_seq v.delta.de ()) in
      let entries = ref [] in
      let bi = ref 0 in
      for e = 0 to ne - 1 do
        let td =
          match !dnext with
          | Seq.Cons ((e', td), rest) when e' = e -> dnext := rest (); Some td
          | _ -> None
        in
        (* the large group's rows of e: bulk.by_thing.(b0 .. !bi - 1) *)
        let b0 = !bi in
        while !bi < bulk.n && Bulk.thing bulk (Bulk.row bulk !bi) = e do incr bi done;
        let nb = !bi - b0 in
        let h = ref 0 and nh = ref 0 in
        for j = 0 to take - 1 do
          if Store.base_has src.(j).a e then (h := !h lor (1 lsl (2 * j)); incr nh);
          if Store.base_has src.(j).t e then (h := !h lor (1 lsl ((2 * j) + 1)); incr nh)
        done;
        if Option.is_none td && !nh = 0 && nb > 0 then
          (* the large group's rows alone, as they are *)
          for r = b0 to !bi - 1 do
            let i = Bulk.row bulk r in
            row ta e (Bulk.prop bulk i) (Bulk.word bulk i) (Bulk.derived bulk i)
          done
        else if !nh = 0 && nb = 0 && Option.is_some td then
          (* the delta alone: its entries, in (p, w) order, as they are *)
          Store.PW.iter (fun (p, w) st -> out e p w (fin st) (below st)) (Option.get td).tf
        else if Option.is_none td && !nh = 1 && nb = 0 then begin
          (* one source: its rows as they are *)
          let j = ref 0 in
          while (!h lsr !j) land 1 = 0 do incr j done;
          let r = src.(!j / 2) in
          if !j land 1 = 0 then Store.base_iter_ef r.a e (fun p w d -> emit_a e p w d)
          else Store.base_iter_ef r.t e (fun p w d -> emit_t e p w d)
        end
        else if Option.is_some td || !nh > 0 || nb > 0 then begin
          (* entries (p, w, 2 age (+1 for a run's retraction), entry), newest first within a fact *)
          entries := [];
          for r = b0 to !bi - 1 do
            let i = Bulk.row bulk r in
            entries := (Bulk.prop bulk i, Bulk.word bulk i, 0, if Bulk.derived bulk i then 3 else 1) :: !entries
          done;
          Option.iter (fun (td : Store.tdelta) -> Store.PW.iter (fun (p, w) st -> entries := (p, w, 2, st) :: !entries) td.tf) td;
          for j = 0 to take - 1 do
            let age = 2 * (j + 2) in
            if (!h lsr (2 * j)) land 1 = 1 then
              Store.base_iter_ef src.(j).a e (fun p w d -> entries := (p, w, age, if d then 3 else 1) :: !entries);
            if (!h lsr ((2 * j) + 1)) land 1 = 1 then
              Store.base_iter_ef src.(j).t e (fun p w d -> entries := (p, w, age + 1, if d then 12 else 4) :: !entries)
          done;
          let rec go = function
            | [] -> ()
            | (p, w, _, c) :: rest ->
              let rec last oldest = function (p', w', _, c') :: r when p' = p && w' = w -> last c' r | r -> oldest, r in
              let oldest, rest = last c rest in
              out e p w (fin c) (below oldest);
              go rest
          in
          go (List.sort compare !entries)
        end
      done;
      if !bi <> bulk.n then invalid_arg "Snapshot.merge: a fact of the large group is past the things";
      tblocks_end ta ne;
      tblocks_end tt t_ne;
    in
    (match dom with
     | None -> pass ()
     | Some d -> (
       match pass () with
       | () -> feed_end fd_cols d [ ta.ch; tt.ch ]
       | exception e -> (try feed_end fd_cols d [] with _ -> ()); raise e));
    columns_end o la ca;
    columns_end o lt ct;
    na := ta.rows;
    nt := tt.rows;
    List.iter close [ ta.rk; ta.dir; ta.data; tt.rk; tt.dir; tt.data ];
    (* ---- by property: the rows (value, thing) in blocks, their directory, the value indexes ---- *)
    let vb (l : Store.base) (r : Store.rooms) np vb_cap vw vm =
      vblocks (stream o l.o_poff (8 * (np + 1))) (stream o l.o_pblk (8 * (np + 1))) (stream o l.o_pdist (8 * np))
        (stream o l.o_pidx (32 * np)) (stream o l.o_vdir (16 * (vb_cap + 1))) (stream o l.o_vdata r.vdata)
        (stream o l.o_vrank (8 * vw)) (mono (stream o l.o_vmh (16 * vm)) (stream o l.o_vmb r.vmb))
    in
    let va = vb la ra np a_vb a_vw a_vm and vt = vb lt rt t_np t_vb t_vw t_vm in
    let out_a w e d = vrow va w e d and out_t w e d = vrow vt w e d in
    (* cursors: 2 a source run (its part a, its part t) *)
    let nsrc = 2 * take in
    let part s = if s land 1 = 0 then src.(s / 2).a else src.(s / 2).t in
    for p = 0 to np - 1 do
      vprop va ~idx:idx_a.(p);
      if not bottom then vprop vt ~idx:idx_t.(p);
      let cs = Array.init nsrc (fun s -> cursor (part s) p) in
      let nlive = Array.fold_left (fun n c -> if live c then n + 1 else n) 0 cs in
      let pd = Store.IM.find_opt p v.delta.dav in
      (* the large group's rows of p: bulk.pw, pe (bp .. bq - 1) *)
      let bp = ref (if p + 1 < Array.length bulk.poff then bulk.poff.(p) else 0)
      and bq = if p + 1 < Array.length bulk.poff then bulk.poff.(p + 1) else 0 in
      (* the delta's entries of p, in (value, thing) order *)
      let dl =
        match pd with
        | None -> [||]
        | Some pd ->
          let l = ref [] in
          Store.IM.iter (fun w (vd : Store.vdelta) -> Store.IM.iter (fun e st -> l := (w, e, st) :: !l) vd.vm) pd.pm;
          Array.of_list (List.rev !l)
      in
      if Array.length dl = 0 && nlive = 0 && !bp < bq then
        (* the large group's rows alone, as they are *)
        for r = !bp to bq - 1 do out_a (Bulk.pword bulk r) (Bulk.pthing bulk r) (Bulk.pderived bulk r) done
      else if Array.length dl = 0 && nlive = 1 && !bp = bq then begin
        (* one source: its rows as they are *)
        let s = ref 0 in
        while not (live cs.(!s)) do incr s done;
        let b = part !s in
        if !s land 1 = 0 then Store.base_iter_pf b p (fun e w d -> out_a w e d)
        else Store.base_iter_pf b p (fun e w d -> out_t w e d)
      end
      else begin
        let di = ref 0 in
        let more () = Array.exists live cs || !di < Array.length dl || !bp < bq in
        while more () do
          (* the smallest (value, thing) among the heads *)
          let bw = ref max_int and be = ref max_int and any = ref false in
          if !bp < bq then (bw := Bulk.pword bulk !bp; be := Bulk.pthing bulk !bp; any := true);
          if !di < Array.length dl then begin
            let w, e, _ = dl.(!di) in
            if (not !any) || w < !bw || (w = !bw && e < !be) then (bw := w; be := e; any := true)
          end;
          for s = 0 to nsrc - 1 do
            let c = cs.(s) in
            if live c then begin
              let hw = c.cw.(c.ck) and he = c.ce.(c.ck) in
              if (not !any) || hw < !bw || (hw = !bw && he < !be) then (bw := hw; be := he; any := true)
            end
          done;
          let w = !bw and e = !be in
          (* its entries, newest first: the large group, the delta, then the runs in order (a run's addition before its
             retraction) *)
          let newest = ref (-1) and oldest = ref 0 in
          if !bp < bq && Bulk.pword bulk !bp = w && Bulk.pthing bulk !bp = e then begin
            let c = if Bulk.pderived bulk !bp then 3 else 1 in
            newest := c;
            oldest := c;
            incr bp
          end;
          if !di < Array.length dl then begin
            let w', e', st = dl.(!di) in
            if w' = w && e' = e then ((if !newest < 0 then newest := st); oldest := st; incr di)
          end;
          for s = 0 to nsrc - 1 do
            let c = cs.(s) in
            if live c && c.cw.(c.ck) = w && c.ce.(c.ck) = e then begin
              let d = Bytes.unsafe_get c.cd c.ck <> '\000' in
              let code = if s land 1 = 0 then (if d then 3 else 1) else if d then 12 else 4 in
              if !newest < 0 then newest := code;
              oldest := code;
              advance c
            end
          done;
          let f = fin !newest and b = below !oldest in
          if f <> b then begin
            if b > 0 then (if bottom then invalid_arg "Snapshot.merge: a retraction with nothing below" else out_t w e (b = 2));
            if f > 0 then out_a w e (f = 2)
          end
        done
      end;
      vprop_end va;
      if not bottom then vprop_end vt
    done;
    vblocks_end va;
    vblocks_end vt;
    if va.vrows <> !na || vt.vrows <> !nt then invalid_arg "Snapshot.merge: the facts by property and by thing differ";
    List.iter
      (fun (x : vblocks) ->
        mono_cut x.voff;
        List.iter close [ x.poffs; x.pblks; x.pdists; x.pidxs; x.vdir; x.vdata; x.vrank; x.voff.mh; x.voff.mb ])
      [ va; vt ];
    (* ---- the dictionary: the texts s0 .. s1-1, their offsets, and their hash table ---- *)
    let soff = mono (stream o la.o_smh (16 * Store.blocks128 (ns + 1))) (stream o la.o_smb ra.smb)
    and sb = stream o la.o_sblob (!sblob + 8)
    and sh = stream o la.o_shash (if ns = 0 then 0 else 4 lsl hbits) in
    let table = Bytes.make (if ns = 0 then 0 else 4 lsl hbits) '\000' in
    let hm = (1 lsl hbits) - 1 in
    let off = ref 0 in
    for i = s0 to s1 - 1 do
      mono_add soff !off;
      let t = Store.text v i in
      put_string sb t;
      off := !off + String.length t;
      let k = ref (Store.hash t land hm) in
      while u32 table (4 * !k) <> 0 do k := (!k + 1) land hm done;
      Bytes.set_int32_le table (4 * !k) (Int32.of_int (i - s0 + 1))
    done;
    mono_add soff !off;
    mono_cut soff;
    if !off <> !sblob then invalid_arg "Snapshot.merge: the texts' bytes do not add up";
    put_sub sh table 0 (Bytes.length table);
    List.iter close [ soff.mh; soff.mb; sb; sh ];
    (* the part t's dictionary sections: empty *)
    List.iter close [ stream o lt.o_smh (16 * Store.blocks128 1); stream o lt.o_smb rt.smb; stream o lt.o_sblob 8; stream o lt.o_shash 0 ];
    if Hashtbl.length o.open_pages <> 0 then invalid_arg "Snapshot.merge: a page was left unwritten";
    flush o;
    (* the page table, the header, and the file forced *)
    let table = Bytes.create (8 * npages) in
    for k = 0 to npages - 1 do
      Bytes.set_int32_le table (8 * k) (Int32.of_int map.(k));
      Bytes.set_int32_le table ((8 * k) + 4) (Bytes.get_int32_le crcs (4 * k))
    done;
    disk.pwrite fd (header + (o.next * Pages.size)) table 0 (8 * npages);
    let h = Bytes.make header '\000' in
    Bytes.set_int32_le h 0 (Int32.of_int magic);
    Bytes.set_int32_le h 4 (Int32.of_int format);
    Bytes.blit_string id 0 h 8 16;
    let fields =
      [ v.group; lo; level; v.next_e; pos.segment; pos.offset; pos.next; s0; !na; ne; ta.things; np; ns; !sblob; hbits ]
      @ Store.offsets la @ [ !nt; t_ne; tt.things; t_np ] @ Store.offsets lt @ [ len; o.next ]
    in
    List.iteri (fun k x -> Bytes.set_int64_le h (24 + (8 * k)) (Int64.of_int x)) fields;
    let e = 24 + (8 * List.length fields) in
    Bytes.set_int32_le h e (Int32.of_int (Crc32c.bytes table 0 (8 * npages)));
    Bytes.set_int32_le h (e + 4) (Int32.of_int (Crc32c.bytes h 0 (e + 4)));
    disk.pwrite fd 0 h 0 header;
    if sync then disk.fsync fd
  with
  | () ->
    if disk == Disk.real then Gc.finalise (fun _ -> try disk.close fd with Disk.Io _ -> ()) pg;
    let part (l : Store.base) ~n ~k = Store.ready { l with pg; hot = pg.Pages.hot; n; k; r0 = k } in
    let a = part la ~n:!na ~k:ta.things and t = part lt ~n:!nt ~k:tt.things in
    let run = { Store.a; t; lo; hi = v.group; level; s0 } in
    let runs = Array.append [| run |] (Array.sub rs take (nr - take)) in
    { tmp; path; group = v.group; view = Store.of_runs ~schema:v.schema ~group:v.group ~next_e:v.next_e runs;
      replaced = Array.to_list src; sync = (fun () -> disk.fsync fd); forced = sync }
  | exception (Disk.Io _ as e) -> failed (); raise e
  | exception (Pages.Unreadable _ as e) -> failed (); raise e

(* The file takes its name (G12): renamed over, the directory forced; then every run of the directory that is in no
   chain to the new state is removed (the runs it replaced, those an earlier crash left), and the files of earlier
   formats. No run is kept aside: the journal is the truth and keeps every group, so a run found damaged at an open is
   set aside and its groups replayed from the journal, nothing lost (a space amplification of 1 rather than 2 after a
   full merge: Dong et al., CIDR 2017). *)
let install disk dir w =
  force w;
  disk.Disk.rename w.tmp w.path;
  disk.sync_dir dir;
  let live = Array.to_list (Array.map (fun (r : Store.run) -> name r.lo r.hi) w.view.runs) in
  let gone = List.filter (fun n -> not (List.mem n live)) (List.map (fun (_, _, n) -> n) (list disk dir)) @ old_files disk dir in
  List.iter (fun n -> disk.remove (Filename.concat dir n)) gone;
  if gone <> [] then disk.sync_dir dir

(* A merge not installed (the database stopped, or the disk failed): its file goes. *)
let abandon disk w = try if disk.Disk.exists w.tmp then disk.remove w.tmp with Disk.Io _ -> ()

(* At open: the files of merges a crash interrupted. *)
let clean disk dir =
  let stray = List.filter (fun n -> Filename.check_suffix n tmp_suffix) (disk.Disk.readdir dir) in
  List.iter (fun n -> disk.remove (Filename.concat dir n)) stray;
  if stray <> [] then disk.sync_dir dir

exception Bad of string

let bad fmt = Printf.ksprintf (fun s -> raise (Bad s)) fmt

(* Checks a run's header, page table, rank and offset tables and builds it, read through the cache; raises Bad. *)
let check_and_build disk dir (lo0, hi0, file) id =
  let path = Filename.concat dir file in
  let fd = disk.Disk.openf path false in
  match
    let size = disk.size fd in
    if size < header then bad "shorter than its header";
    let h = Bytes.create header in
    disk.pread fd 0 h 0 header;
    if u32 h 0 <> magic then bad "not a run";
    let nfields = 15 + Store.noffsets + 4 + Store.noffsets + 2 in
    let e = 24 + (8 * nfields) in
    let fmt = u32 h 4 in
    if fmt <> format then bad "an earlier format (%d), the journal is replayed" fmt;
    if u32 h (e + 4) <> Crc32c.bytes h 0 (e + 4) then bad "its header does not check";
    if Bytes.sub_string h 8 16 <> id then bad "a run of another database";
    let g k = Int64.to_int (Bytes.get_int64_le h (24 + (8 * k))) in
    let hi = g 0 and lo = g 1 and level = g 2 and next_e = g 3 and seg = g 4 and off = g 5 and next = g 6 and s0 = g 7 in
    let an = g 8 and ane = g 9 and ak = g 10 and anp = g 11 and ans = g 12 and asb = g 13 and hbits = g 14 in
    let aoffs = List.init Store.noffsets (fun i -> g (15 + i)) in
    let tbase = 15 + Store.noffsets in
    let tn = g tbase and tne = g (tbase + 1) and tk = g (tbase + 2) and tnp = g (tbase + 3) in
    let toffs = List.init Store.noffsets (fun i -> g (tbase + 4 + i)) in
    let len = g (tbase + 4 + Store.noffsets) and phys = g (tbase + 5 + Store.noffsets) in
    if lo <> lo0 || hi <> hi0 then bad "its groups are not those of its name";
    if List.exists (fun x -> x < 0) ([ an; ane; ak; anp; ans; asb; tn; tne; tk; tnp; s0; level; len; phys; hbits ] @ aoffs @ toffs)
       || ak > ane || tk > tne || ak > an || tk > tn || hbits > 40
       || anp > Schema.first_thing || tnp > Schema.first_thing || (lo = 0 && tn > 0)
       || (ans > 0 && 1 lsl hbits < 2 * ans)
    then bad "bad counts";
    let mono_offs l = let rec ok = function a :: (b :: _ as r) -> a <= b && ok r | _ -> true in ok l in
    if not (mono_offs (aoffs @ toffs)) || List.nth toffs 0 <> List.nth aoffs (Store.noffsets - 1)
       || List.nth toffs (Store.noffsets - 1) <> len
    then bad "its sections are out of order";
    if next < 1 || next > hi + 1 then bad "its journal position is after its group";
    let npages = Pages.pages len in
    if phys > npages || size < header + (phys * Pages.size) + (8 * npages) then bad "shorter than its header says";
    let table = Bytes.create (8 * npages) in
    disk.pread fd (header + (phys * Pages.size)) table 0 (8 * npages);
    if u32 h e <> Crc32c.bytes table 0 (8 * npages) then bad "its page table does not check";
    let map = Array.init npages (fun k -> Int32.to_int (Bytes.get_int32_le table (8 * k))) in
    let seen = Bytes.make (max 1 phys) '\000' in
    Array.iter
      (fun f ->
        if f >= 0 then begin
          if f >= phys || Bytes.get seen f <> '\000' then bad "its page table is not a map of its pages";
          Bytes.set seen f '\001'
        end
        else if f <> -1 then bad "its page table is not a map of its pages")
      map;
    let load_from fd k =
      let f = map.(k) in
      if f < 0 then Bytes.make Pages.size '\000'
      else begin
        let p = Bytes.create Pages.size in
        (try disk.pread fd (header + (f * Pages.size)) p 0 Pages.size with Disk.Io m -> raise (Pages.Unreadable m));
        if Crc32c.bytes p 0 Pages.size <> u32 table ((8 * k) + 4) then
          raise (Pages.Unreadable (Printf.sprintf "run %s: page %d does not check" file k));
        p
      end
    in
    let pg = Pages.on_file len (load_from fd) in
    if disk == Disk.real then Gc.finalise (fun _ -> try disk.close fd with Disk.Io _ -> ()) pg;
    let a = Store.of_offsets ~pg ~n:an ~ne:ane ~k:ak ~np:anp ~ns:ans ~sblob:asb ~hbits aoffs in
    let t = Store.of_offsets ~pg ~n:tn ~ne:tne ~k:tk ~np:tnp ~ns:0 ~sblob:0 ~hbits:0 toffs in
    (* small enough: every page that the file holds read and checked now, and the cache warm. A large run's pages are
       read and checked by up to 4 domains, each with its own descriptor (the CRC is most of an open: 14 us a page),
       then enter the cache *)
    if phys <= !Pages.capacity then begin
      let d = if disk.parallel && phys >= 512 then max 1 (min 4 (Domain.recommended_domain_count ())) else 1 in
      if d = 1 then Array.iteri (fun k f -> if f >= 0 then ignore (Pages.page pg k)) map
      else begin
        let got = Array.make npages Bytes.empty in
        let part i () =
          let fd' = disk.openf path false in
          Fun.protect ~finally:(fun () -> try disk.close fd' with Disk.Io _ -> ()) @@ fun () ->
          for k = i * npages / d to ((i + 1) * npages / d) - 1 do if map.(k) >= 0 then got.(k) <- load_from fd' k done
        in
        let others = List.init (d - 1) (fun i -> Domain.spawn (part (i + 1))) in
        let mine = match part 0 () with () -> None | exception e -> Some e in
        let theirs = List.filter_map (fun dm -> match Domain.join dm with () -> None | exception e -> Some e) others in
        (match mine, theirs with Some e, _ | None, e :: _ -> raise e | None, [] -> ());
        Array.iteri (fun k f -> if f >= 0 then (Pages.admit pg k got.(k); Atomic.incr Pages.misses)) map
      end
    end;
    (* bounds: the rank tables count right, every offset table in order and within its rows and its room; a row's
       ids are checked by its page's CRC, and a read out of a run's pages fails, it never reads outside *)
    let ranks (b : Store.base) what =
      let r = ref 0 in
      for j = 0 to Store.blocks b.ne do
        let w = Store.safe Store.i64 b (b.o_erank + (8 * j)) in
        if w lsr 32 <> !r then bad "the rank table of %s is out of order" what;
        r := !r + Store.popcount (w land 0xFFFFFFFF)
      done;
      if !r <> b.k then bad "the rank table of %s does not end at %d" what b.k
    in
    let mono get count total what =
      let prev = ref 0 in
      for i = 0 to count do
        let x = get i in
        if x < !prev || x > total then bad "%s is out of order" what;
        prev := x
      done;
      if get count <> total then bad "%s does not end at %d" what total
    in
    (* in order, and within a room (the first block may start after the rest of a page: a block that would cross a
       page starts on the next one) *)
    let upto get count room what =
      let prev = ref 0 in
      if get 0 < 0 || get 0 >= Pages.size then bad "%s do not start at their section's start" what;
      for i = 0 to count do
        let x = get i in
        if x < !prev || x > room then bad "%s are out of order" what;
        prev := x
      done
    in
    List.iter
      (fun ((b : Store.base), what) ->
        ranks b what;
        let tbn = Store.blocks128 b.k in
        upto (fun j -> Store.safe Store.i64 b (b.o_tdir + (8 * j))) tbn (b.o_poff - b.o_tdata) ("the thing blocks of " ^ what);
        if b.np > 0 then begin
          mono (fun p -> Store.safe Store.i64 b (b.o_poff + (8 * p))) b.np b.n ("the property offsets of " ^ what);
          let blocks = ref 0 in
          for p = 0 to b.np - 1 do
            let rows = Store.safe Store.i64 b (b.o_poff + (8 * (p + 1))) - Store.safe Store.i64 b (b.o_poff + (8 * p)) in
            if Store.safe Store.i64 b (b.o_pblk + (8 * p)) <> !blocks then bad "the row blocks of %s are out of order" what;
            blocks := !blocks + Store.blocks128 rows;
            let x = b.o_pidx + (32 * p) in
            let w0 = Store.safe Store.i64 b (x + 8) and words = Store.safe Store.i64 b (x + 16) in
            if w0 >= 0 && (words < 2 || w0 + words > (b.o_vmh - b.o_vrank) / 8) then bad "a value index of %s is out of its room" what
          done;
          if Store.safe Store.i64 b (b.o_pblk + (8 * b.np)) <> !blocks then bad "the row blocks of %s do not add up" what;
          upto (fun j -> Store.safe Store.i64 b (b.o_vdir + (16 * j))) !blocks (b.o_vrank - b.o_vdata) ("the row blocks of " ^ what)
        end)
      [ a, "its additions"; t, "its retractions" ];
    (* the columns: each property's entry within its sections, its rank table (once for the properties that share
       it), its offsets, its blocks; its rows those of the property by value *)
    List.iter
      (fun ((b : Store.base), what) ->
        let ranks = Hashtbl.create 8 in
        for p = 0 to b.np - 1 do
          let x = b.o_cp + (64 * p) in
          let g k = Store.safe Store.i64 b (x + (8 * k)) in
          let tlo = g 0 and at = g 1 and words = g 2 and q0 = g 3 and dir = g 4 and data = g 5 and mh = g 6 and mb = g 7 in
          let rows = Store.safe Store.i64 b (b.o_poff + (8 * (p + 1))) - Store.safe Store.i64 b (b.o_poff + (8 * p)) in
          let col fmt = Printf.ksprintf (fun m -> bad "the column %d of %s %s" p what m) fmt in
          if at < 0 then (if rows <> 0 then col "has no rows")
          else begin
            if tlo < 0 || tlo land 31 <> 0 || words < 2 || at < b.o_crank || at land 7 <> 0 || at + (8 * words) > b.o_cdir
               || dir < b.o_cdir || dir + (16 * Store.blocks128 rows) > b.o_cdata || data < b.o_cdata || data > b.o_cmh
            then col "is out of its sections";
            let things =
              match Hashtbl.find_opt ranks at with
              | Some (w, k) -> if w <> words then col "shares a rank table of another length"; k
              | None -> let k = Store.check_rank b at words in Hashtbl.replace ranks at (words, k); k
            in
            if things < 1 || things > rows || q0 < 0 || q0 > things then col "has a rank table out of order";
            if q0 = things then (if rows <> things then col "has rows of no thing")
            else if mh < b.o_cmh || mh + (16 * Store.blocks128 (things - q0 + 1)) > b.o_cmb || mb < b.o_cmb || mb > b.len
                    || not (Store.check_offsets b mh mb (things - q0) (rows - q0))
            then col "has offsets out of order";
            if not (Store.check_blocks b dir rows (b.o_cmh - data)) then col "has blocks out of order"
          end
        done)
      [ a, "its additions"; t, "its retractions" ];
    if a.ns > 0 then mono (fun i -> Store.safe (fun b i -> Store.soff b i) a i) a.ns a.sblob "the text offsets";
    { Store.a = Store.ready a; t = Store.ready t; lo; hi; level; s0 }, next_e, { Journal.segment = seg; offset = off; next }
  with
  | r -> r
  | exception e -> (try disk.close fd with Disk.Io _ -> ()); raise e

(* The schema of a view of runs, read from the facts of the schema things (properties, rules; raises Bad); for the
   server's local readers too, which build views of the runs they are passed. *)
let schema_of (v : Store.view) =
  let schema = ref Schema.initial in
  for p = Schema.first_prop to min (Store.max_thing v + 1) Schema.first_thing - 1 do
    if Store.holders v p <> 0 then
      match Resolve.read_thing v p with
      | Ok _ as t -> schema := Resolve.install_thing !schema p t
      | Error m -> bad "%s" m
  done;
  !schema

(* The newest chain of runs that check, from 0: the newest runs first, the next thing id and the journal position of
   the newest one; the reasons runs were set aside. Among the chains the run names allow (each run resting on the
   group the one below it ends at), the one reaching the newest group, with the fewest runs. *)
let load disk dir id =
  let notes = ref [] in
  List.iter (fun n -> notes := Printf.sprintf "snapshot %s set aside: an earlier format, the journal is replayed" n :: !notes) (old_files disk dir);
  let rec go excluded =
    let runs = List.filter (fun (_, _, n) -> not (List.mem n excluded)) (list disk dir) in
    (* best.(hi): the shortest chain reaching hi, newest run first *)
    let best = Hashtbl.create 8 in
    Hashtbl.replace best 0 [];
    List.iter
      (fun ((lo, hi, _) as r) ->
        match Hashtbl.find_opt best lo with
        | Some c -> (match Hashtbl.find_opt best hi with Some c' when List.length c' <= List.length c + 1 -> () | _ -> Hashtbl.replace best hi (r :: c))
        | None -> ())
      (List.sort (fun (lo, hi, _) (lo', hi', _) -> compare (hi, lo) (hi', lo')) runs);
    let top = Hashtbl.fold (fun hi _ m -> max hi m) best 0 in
    match Hashtbl.find best top with
    | [] -> None
    | chain -> (
      (* checked from the bottom up *)
      let rec check acc = function
        | [] -> Ok acc
        | ((_, _, n) as r) :: rest -> (
          match check_and_build disk dir r id with
          | x -> check (x :: acc) rest
          | exception Bad m -> Error (n, m)
          | exception Pages.Unreadable m -> Error (n, m)
          | exception Disk.Io m -> Error (n, m)
          | exception Invalid_argument m -> Error (n, m))
      in
      let aside n m = notes := Printf.sprintf "snapshot %s set aside: %s" n m :: !notes; go (n :: excluded) in
      match check [] (List.rev chain) with
      | Error (n, m) -> aside n m
      | Ok built -> (
        (* built: the newest first; the schema read from the facts of the schema things (properties, rules) *)
        let runs = Array.of_list (List.map (fun (r, _, _) -> r) built) in
        let _, next_e, pos = List.hd built in
        let v = Store.of_runs ~group:runs.(0).hi ~next_e runs in
        match schema_of v with
        | schema -> Some ({ v with schema }, pos)
        | exception Bad m -> let _, _, n = List.hd chain in aside n m
        | exception Pages.Unreadable m -> let _, _, n = List.hd chain in aside n m))
  in
  let r = go [] in
  r, List.rev !notes

(* The page of the file that holds page k of a run's layout, or None (a page no file page holds): for the tests of
   damage, which flip bits of the file. *)
let file_page disk path k =
  let fd = disk.Disk.openf path false in
  Fun.protect ~finally:(fun () -> disk.close fd) @@ fun () ->
  let h = Bytes.create header in
  disk.pread fd 0 h 0 header;
  let g i = Int64.to_int (Bytes.get_int64_le h (24 + (8 * i))) in
  let base = 15 + Store.noffsets + 4 + Store.noffsets in
  let phys = g (base + 1) in
  let b = Bytes.create 8 in
  disk.pread fd (header + (phys * Pages.size) + (8 * k)) b 0 8;
  let f = Int32.to_int (Bytes.get_int32_le b 0) in
  if f < 0 then None else Some f

(* the pages the file holds *)
let file_pages disk path =
  let fd = disk.Disk.openf path false in
  Fun.protect ~finally:(fun () -> disk.close fd) @@ fun () ->
  let h = Bytes.create header in
  disk.pread fd 0 h 0 header;
  Int64.to_int (Bytes.get_int64_le h (24 + (8 * (15 + Store.noffsets + 4 + Store.noffsets + 1))))
