(* A run file holds one run of the LSM tree (Store): its two parts, in the pages a reader reads them by. A merge is
   the one way to make a run: it merges the delta and the newest runs of a view (sorted runs, merged as they stream,
   O'Neil et al. 1996) into a new file, page by page, so that it needs only the cache and a few page buffers whatever
   the size of the runs. A file: a header page, the run's pages (16 KiB each), then one CRC-32C a page. At open, the
   header, the CRC table, the rank and offset tables are checked (G7); every page is checked against its CRC each time
   it is read from the disk, so a damaged page is never served, even one damaged after the open. A run that fits in
   the cache is read whole at open; a larger one is read page by page as the questions need it. A run that does not
   check is set aside: the database rests on the runs that remain, then on the journal, which is always the truth.

     name             DIR/snapshots/<lo, 20 digits>-<hi, 20 digits>.run: the changes of groups lo+1..hi on top of the
                      state at lo (lo = 0: a bottom run, the whole state at hi)
     header (4096 B)  magic "CPHS" | format | database id | hi | lo | level | next thing | journal segment | journal
                      offset | journal group at that offset | first text | part a: rows, things range, things,
                      properties, texts, text bytes, room for rows, room for things | part t: rows, things range,
                      things, properties, room for rows, room for things | body length | crc of the crc table
                      | crc of the header

   Recovery takes the newest chain of runs whose ranges follow one another from 0 (Snapshot.load), then replays the
   journal from the newest run's position, whose first group may come before its own (a merge in the background
   starts from a view that runs ahead of the disk): the groups up to the run's are skipped.

   A merge installs its file atomically (G12): written under a temporary name, forced, renamed, its directory forced;
   only then the runs it replaced are removed. A crash at any point leaves the old runs or the new one, whole. *)

let magic = 0x53485043 (* "CPHS" *)
let format = 5
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
   The sections of the new run are written by streams side by side, each in order; a page is complete once every
   byte of it is written (two sections can share a page), and goes out at once: its CRC, its pwrite, the cache. A
   section is laid out by an upper bound of its size: what its stream does not reach is counted written (zeros), and
   the pages it alone covers are never written (holes, which read as zeros and check). The pages open at any time are
   those under the streams' heads and the pages two sections share: a handful. *)

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
  mutable done_pages : (int * Bytes.t) list;  (* complete, not yet written *)
  mutable ndone : int;
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

(* the pages complete but not yet written: written together, a run of neighbours with one pwrite, so that a merge
   makes a system call per few hundred KB rather than per page *)
let batch = 32

let flush o =
  let l = List.sort (fun (a, _) (b, _) -> compare a b) o.done_pages in
  o.done_pages <- [];
  o.ndone <- 0;
  let rec go = function
    | [] -> ()
    | (k, _) :: _ as l ->
      (* the longest run k, k+1, ... *)
      let rec run m = function (k', b) :: r when k' = k + m -> let bs, r = run (m + 1) r in b :: bs, r | r -> [], r in
      let bs, rest = run 0 l in
      let m = List.length bs in
      let buf = if m = 1 then List.hd bs else Bytes.concat Bytes.empty bs in
      o.disk.Disk.pwrite o.fd (header + (k * Pages.size)) buf 0 (m * Pages.size);
      o.unforced <- o.unforced + (m * Pages.size);
      go rest
  in
  go l;
  if o.unforced >= !sync_every && o.busy () then begin
    o.disk.fsync o.fd;
    o.unforced <- 0
  end

let complete o k a =
  Hashtbl.remove o.open_pages k;
  Bytes.set_int32_le o.crcs (4 * k) (Int32.of_int (Crc32c.bytes a.buf 0 Pages.size));
  o.done_pages <- (k, a.buf) :: o.done_pages;
  o.ndone <- o.ndone + 1;
  if o.ndone >= batch then flush o;
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

(* the end of a section: the rest of its room counts as written, zeros. Only its first and last pages can hold bytes
   of another section; a page all inside the rest is never written (a hole: it reads as zeros, which its CRC says) *)
let close s =
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

type written = {
  tmp : string;
  path : string;
  group : int;
  view : Store.view;
  replaced : Store.run list;  (* the runs the new one replaces *)
}

(* ---- the merge of the sources' entries ----
   The sources are a large group's facts (Bulk, all additions: age 0), the delta (age 1) and the merged runs (run j:
   age j + 2), each giving a fact as added or retracted.
   For one fact, the newest entry says whether it is in the new state, and the oldest one whether it was in the state
   below the merged runs (an addition there means it was not: a run adds only facts absent below it; a retraction
   means it was). The new run holds an addition if the fact is in the new state and was not below, a retraction in the
   opposite case, and nothing when the two agree. *)

let decide ~newest ~oldest = if newest = oldest then (if newest then 1 else -1) else 0

(* The merge of [v]'s delta and its [take] newest runs into one run at [level], with [pos] the journal position replay
   starts from (pos.next <= v.group + 1). Written under a temporary name and forced (also on the way, while [busy]
   says clients write); [install] gives it its name. On a failure of the disk, the file is removed and the failure
   raised. *)
let no_bulk = Bulk.make [||] [||] [||] 0 ~np:0

let merge ?(busy = fun () -> false) ?(bulk = no_bulk) disk dir id (v : Store.view) ~take ~level (pos : Journal.position) =
  if pos.next > v.group + 1 then invalid_arg "Snapshot.merge: the journal position is after the view";
  let rs = v.runs in
  let nr = Array.length rs in
  if take < 0 || take > nr then invalid_arg "Snapshot.merge: more runs than the view has";
  let bottom = take = nr in
  let lo = if bottom then 0 else rs.(take).hi in
  let src = Array.sub rs 0 take in
  (* the delta's additions, retractions and things *)
  let da = ref 0 and dt = ref 0 in
  Store.IM.iter (fun _ (td : Store.tdelta) -> Store.PW.iter (fun _ add -> if add then incr da else incr dt) td.tf) v.delta.de;
  let dthings = Store.IM.cardinal v.delta.de in
  let ne = Store.max_thing v + 1 and np = Schema.count v.schema in
  let s0 = if take = 0 then v.dict.chunks.c0 else src.(take - 1).s0 in
  let s1 = v.dict.dnext in
  let sblob = ref 0 in
  Array.iter (fun (r : Store.run) -> sblob := !sblob + r.a.sblob) src;
  for i = v.dict.chunks.c0 to s1 - 1 do sblob := !sblob + String.length (Store.text v i) done;
  let sum f = Array.fold_left (fun n r -> n + f r) 0 src in
  let a_ncap = sum (fun r -> r.a.n) + !da + bulk.n and a_kcap = min ne (sum (fun r -> r.a.k) + dthings + bulk.n) in
  let t_ncap = if bottom then 0 else sum (fun r -> r.t.n) + !dt
  and t_kcap = if bottom then 0 else min ne (sum (fun r -> r.t.k) + dthings) in
  let t_ne = if bottom then 0 else ne and t_np = if bottom then 0 else np in
  let la = Store.layout ~at:0 ~n:0 ~n_cap:a_ncap ~ne ~k:0 ~k_cap:a_kcap ~np ~ns:(s1 - s0) ~sblob:!sblob () in
  let lt = Store.layout ~at:la.len ~n:0 ~n_cap:t_ncap ~ne:t_ne ~k:0 ~k_cap:t_kcap ~np:t_np ~ns:0 ~sblob:0 () in
  let len = lt.len in
  let npages = Pages.pages len in
  let path = Filename.concat dir (name lo v.group) in
  let tmp = path ^ tmp_suffix in
  if disk.Disk.exists tmp then disk.remove tmp;
  let fd = disk.openf tmp true in
  let crcs = Bytes.create (4 * npages) in
  for k = 0 to npages - 1 do Bytes.set_int32_le crcs (4 * k) (Int32.of_int zero_crc) done;
  let load k =
    let p = Bytes.create Pages.size in
    (try disk.pread fd (header + (k * Pages.size)) p 0 Pages.size with Disk.Io m -> raise (Pages.Unreadable m));
    if Crc32c.bytes p 0 Pages.size <> u32 crcs (4 * k) then
      raise (Pages.Unreadable (Printf.sprintf "run %s: page %d does not check" (Filename.basename path) k));
    p
  in
  let pg = Pages.on_file len load in
  let o = { disk; fd; unforced = 0; busy; len; crcs; pg; open_pages = Hashtbl.create 16; done_pages = []; ndone = 0 } in
  let failed () = (try disk.close fd with Disk.Io _ -> ()); (try disk.remove tmp with Disk.Io _ -> ()) in
  let na = ref 0 and ka = ref 0 and nt = ref 0 and kt = ref 0 in
  match
    disk.truncate fd 0;
    (* ---- by thing: the rank tables, the offsets of the things held, their rows ---- *)
    let ar = stream o la.o_erank (8 * (Store.blocks ne + 1)) and aoff = stream o la.o_eoff (8 * (a_kcap + 1))
    and aap = stream o la.o_eap (2 * a_ncap) and aav = stream o la.o_eav (8 * a_ncap) in
    let tr = stream o lt.o_erank (8 * (Store.blocks t_ne + 1)) and toff = stream o lt.o_eoff (8 * (t_kcap + 1))
    and tap = stream o lt.o_eap (2 * t_ncap) and tav = stream o lt.o_eav (8 * t_ncap) in
    let abits = ref 0 and arank = ref 0 and tbits = ref 0 and trank = ref 0 in
    let emit_a e p w =
      let bit = 1 lsl (e land 31) in
      if !abits land bit = 0 then (abits := !abits lor bit; put64 aoff !na; incr ka);
      put16 aap p; put64 aav w; incr na
    and emit_t e p w =
      if bottom then invalid_arg "Snapshot.merge: a retraction with nothing below";
      let bit = 1 lsl (e land 31) in
      if !tbits land bit = 0 then (tbits := !tbits lor bit; put64 toff !nt; incr kt);
      put16 tap p; put64 tav w; incr nt
    in
    let de = ref (Store.IM.to_seq v.delta.de) in
    let entries = ref [] in
    let bi = ref 0 in
    for e = 0 to ne - 1 do
      let td =
        match !de () with
        | Seq.Cons ((e', td), rest) when e' = e -> de := rest; Some td
        | _ -> None
      in
      (* the large group's rows of e: bulk.by_thing.(b0 .. !bi - 1) *)
      let b0 = !bi in
      while !bi < bulk.n && bulk.e.(bulk.by_thing.(!bi)) = e do incr bi done;
      let nb = !bi - b0 in
      let h = ref 0 and nh = ref 0 in
      for j = 0 to take - 1 do
        if Store.base_has src.(j).a e then (h := !h lor (1 lsl (2 * j)); incr nh);
        if Store.base_has src.(j).t e then (h := !h lor (1 lsl ((2 * j) + 1)); incr nh)
      done;
      if td = None && !nh = 0 && nb > 0 then
        for r = b0 to !bi - 1 do let i = bulk.by_thing.(r) in emit_a e bulk.p.(i) bulk.w.(i) done
      else if td = None && !nh = 1 && nb = 0 then begin
        (* one source: its rows as they are *)
        let j = ref 0 in
        while (!h lsr !j) land 1 = 0 do incr j done;
        let r = src.(!j / 2) in
        if !j land 1 = 0 then Store.base_iter_e r.a e (fun p w -> emit_a e p w)
        else Store.base_iter_e r.t e (fun p w -> emit_t e p w)
      end
      else if td <> None || !nh > 0 || nb > 0 then begin
        (* entries (p, w, age, added), newest first within a fact *)
        entries := [];
        for r = b0 to !bi - 1 do let i = bulk.by_thing.(r) in entries := (bulk.p.(i), bulk.w.(i), 0, true) :: !entries done;
        Option.iter (fun (td : Store.tdelta) -> Store.PW.iter (fun (p, w) add -> entries := (p, w, 1, add) :: !entries) td.tf) td;
        for j = 0 to take - 1 do
          if (!h lsr (2 * j)) land 1 = 1 then Store.base_iter_e src.(j).a e (fun p w -> entries := (p, w, j + 2, true) :: !entries);
          if (!h lsr ((2 * j) + 1)) land 1 = 1 then Store.base_iter_e src.(j).t e (fun p w -> entries := (p, w, j + 2, false) :: !entries)
        done;
        let rec go = function
          | [] -> ()
          | (p, w, _, add) :: rest ->
            let rec last oldest = function (p', w', _, a) :: r when p' = p && w' = w -> last a r | r -> oldest, r in
            let oldest, rest = last add rest in
            (match decide ~newest:add ~oldest with 1 -> emit_a e p w | -1 -> emit_t e p w | _ -> ());
            go rest
        in
        go (List.sort compare !entries)
      end;
      if e land 31 = 31 || e = ne - 1 then begin
        put64 ar (!abits lor (!arank lsl 32));
        arank := !ka;
        abits := 0;
        if not bottom then begin
          put64 tr (!tbits lor (!trank lsl 32));
          trank := !kt;
          tbits := 0
        end
      end
    done;
    if !bi <> bulk.n then invalid_arg "Snapshot.merge: a fact of the large group is past the things";
    put64 ar (!ka lsl 32);
    put64 aoff !na;
    put64 tr (!kt lsl 32);
    put64 toff !nt;
    List.iter close [ ar; aoff; aap; aav; tr; toff; tap; tav ];
    (* ---- by property: the offsets, the rows (value, thing) in order, the distinct values ---- *)
    let apo = stream o la.o_poff (8 * (np + 1)) and avv = stream o la.o_avv (8 * a_ncap)
    and ave = stream o la.o_ave (4 * a_ncap) and apd = stream o la.o_pdist (8 * np) in
    let tpo = stream o lt.o_poff (8 * (t_np + 1)) and tvv = stream o lt.o_avv (8 * t_ncap)
    and tve = stream o lt.o_ave (4 * t_ncap) and tpd = stream o lt.o_pdist (8 * t_np) in
    let ca = ref 0 and ct = ref 0 in
    let adist = ref 0 and alast = ref 0 and tdist = ref 0 and tlast = ref 0 in
    let out_a w e = if !adist = 0 || w <> !alast then incr adist; alast := w; put64 avv w; put32 ave e; incr ca
    and out_t w e = if !tdist = 0 || w <> !tlast then incr tdist; tlast := w; put64 tvv w; put32 tve e; incr ct in
    (* cursors: 2 a source run (its part a, its part t) *)
    let nsrc = 2 * take in
    let cur = Array.make nsrc 0 and stop = Array.make nsrc 0 and hw = Array.make nsrc 0 and he = Array.make nsrc 0 in
    let part s = if s land 1 = 0 then src.(s / 2).a else src.(s / 2).t in
    let head s = let b = part s in hw.(s) <- Store.cavv b cur.(s); he.(s) <- Store.cave b cur.(s) in
    for p = 0 to np - 1 do
      put64 apo !ca;
      if not bottom then put64 tpo !ct;
      adist := 0; tdist := 0;
      let live = ref 0 in
      for s = 0 to nsrc - 1 do
        let b = part s in
        if p < b.np && b.n > 0 then (cur.(s) <- Store.cpoff b p; stop.(s) <- Store.cpoff b (p + 1)) else (cur.(s) <- 0; stop.(s) <- 0);
        if cur.(s) < stop.(s) then (incr live; head s)
      done;
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
          Store.IM.iter (fun w (vd : Store.vdelta) -> Store.IM.iter (fun e add -> l := (w, e, add) :: !l) vd.vm) pd.pm;
          Array.of_list (List.rev !l)
      in
      if Array.length dl = 0 && !live = 0 && !bp < bq then
        for r = !bp to bq - 1 do out_a bulk.pw.(r) bulk.pe.(r) done
      else if Array.length dl = 0 && !live = 1 && !bp = bq then begin
        (* one source: its rows as they are *)
        let s = ref 0 in
        while cur.(!s) >= stop.(!s) do incr s done;
        let b = part !s in
        if !s land 1 = 0 then for i = cur.(!s) to stop.(!s) - 1 do out_a (Store.cavv b i) (Store.cave b i) done
        else for i = cur.(!s) to stop.(!s) - 1 do out_t (Store.cavv b i) (Store.cave b i) done
      end
      else begin
        let di = ref 0 in
        let more () = !live > 0 || !di < Array.length dl || !bp < bq in
        while more () do
          (* the smallest (value, thing) among the heads *)
          let bw = ref max_int and be = ref max_int in
          if !bp < bq then (bw := bulk.pw.(!bp); be := bulk.pe.(!bp));
          if !di < Array.length dl then (let w, e, _ = dl.(!di) in if w < !bw || (w = !bw && e < !be) then (bw := w; be := e));
          for s = 0 to nsrc - 1 do
            if cur.(s) < stop.(s) && (hw.(s) < !bw || (hw.(s) = !bw && he.(s) < !be)) then (bw := hw.(s); be := he.(s))
          done;
          let w = !bw and e = !be in
          (* its entries, newest first: the delta, then the runs in order *)
          let newest = ref None and oldest = ref true in
          if !bp < bq then begin
            if bulk.pw.(!bp) = w && bulk.pe.(!bp) = e then (newest := Some true; oldest := true; incr bp)
          end;
          if !di < Array.length dl then begin
            let w', e', add = dl.(!di) in
            if w' = w && e' = e then ((if !newest = None then newest := Some add); oldest := add; incr di)
          end;
          for s = 0 to nsrc - 1 do
            if cur.(s) < stop.(s) && hw.(s) = w && he.(s) = e then begin
              let add = s land 1 = 0 in
              if !newest = None then newest := Some add;
              oldest := add;
              cur.(s) <- cur.(s) + 1;
              if cur.(s) < stop.(s) then head s else decr live
            end
          done;
          match decide ~newest:(Option.get !newest) ~oldest:!oldest with
          | 1 -> out_a w e
          | -1 -> if bottom then invalid_arg "Snapshot.merge: a retraction with nothing below" else out_t w e
          | _ -> ()
        done
      end;
      put64 apd !adist;
      if not bottom then put64 tpd !tdist
    done;
    put64 apo !ca;
    put64 tpo !ct;
    if !ca <> !na || !ct <> !nt then invalid_arg "Snapshot.merge: the facts by property and by thing differ";
    (* ---- the dictionary: the texts s0 .. s1-1 by id, and their ids in text order ---- *)
    let soff = stream o la.o_soff (8 * (s1 - s0 + 1)) and sb = stream o la.o_sblob !sblob
    and ssort = stream o la.o_ssort (4 * (s1 - s0)) in
    let off = ref 0 in
    for i = s0 to s1 - 1 do
      put64 soff !off;
      let t = Store.text v i in
      String.iter (put8 sb) t;
      off := !off + String.length t
    done;
    put64 soff !off;
    (* the sorted ids: the merged runs' and the delta's merged (a text is in one place only). The texts of every
       source but the largest run are read in id order (one pass over their pages) and merged in memory; they are
       then placed among the largest run's by searches that gallop from the last place (Bentley, Yao 1976), so that
       its texts, read in text order at random places, are read only where an other text falls *)
    let big = ref (-1) in
    for j = 0 to take - 1 do if !big < 0 || src.(j).a.ns > src.(!big).a.ns then big := j done;
    let others = ref (Array.to_list bulk.texts) in
    Store.SM.iter (fun t i -> others := (t, i) :: !others) v.dict.smap;
    for j = 0 to take - 1 do
      if j <> !big then
        for l = 0 to src.(j).a.ns - 1 do others := (Store.base_text src.(j).a l, src.(j).s0 + l) :: !others done
    done;
    let others = Array.of_list !others in
    Array.sort (fun (a, _) (b, _) -> compare a b) others;
    let c = ref 0 in
    let emit i = put32 ssort (i - s0); incr c in
    if !big < 0 then Array.iter (fun (_, i) -> emit i) others
    else begin
      let r = src.(!big) in
      let b = r.a in
      let id k = Store.safe Store.ssort b k in
      let pos = ref 0 in
      Array.iter
        (fun (t, i) ->
          (* the first place at or after pos whose text is above t: gallop, then halve *)
          let lo = ref !pos and step = ref 1 in
          while !lo + !step <= b.ns && Store.base_cmp b t (id (!lo + !step - 1)) > 0 do lo := !lo + !step; step := 2 * !step done;
          let hi = ref (min b.ns (!lo + !step)) in
          while !lo < !hi do
            let m = (!lo + !hi) / 2 in
            if Store.base_cmp b t (id m) > 0 then lo := m + 1 else hi := m
          done;
          for k = !pos to !lo - 1 do emit (r.s0 + id k) done;
          pos := !lo;
          emit i)
        others;
      for k = !pos to b.ns - 1 do emit (r.s0 + id k) done
    end;
    if !c <> s1 - s0 then invalid_arg "Snapshot.merge: the sorted texts do not add up";
    List.iter close [ apo; avv; ave; apd; tpo; tvv; tve; tpd; soff; sb; ssort ];
    (* the part t's dictionary sections: empty *)
    List.iter close [ stream o lt.o_soff 8; stream o lt.o_sblob 0; stream o lt.o_ssort 0 ];
    if Hashtbl.length o.open_pages <> 0 then invalid_arg "Snapshot.merge: a page was left unwritten";
    flush o;
    (* the CRC table, the header, and the file forced *)
    disk.pwrite fd (header + (npages * Pages.size)) crcs 0 (4 * npages);
    let h = Bytes.make header '\000' in
    Bytes.set_int32_le h 0 (Int32.of_int magic);
    Bytes.set_int32_le h 4 (Int32.of_int format);
    Bytes.blit_string id 0 h 8 16;
    List.iteri
      (fun k x -> Bytes.set_int64_le h (24 + (8 * k)) (Int64.of_int x))
      [ v.group; lo; level; v.next_e; pos.segment; pos.offset; pos.next; s0; !na; ne; !ka; np; s1 - s0; !sblob; a_ncap;
        a_kcap; !nt; t_ne; !kt; t_np; t_ncap; t_kcap; len ];
    Bytes.set_int32_le h 208 (Int32.of_int (Crc32c.bytes crcs 0 (4 * npages)));
    Bytes.set_int32_le h 212 (Int32.of_int (Crc32c.bytes h 0 212));
    disk.pwrite fd 0 h 0 header;
    disk.fsync fd
  with
  | () ->
    if disk == Disk.real then Gc.finalise (fun _ -> try disk.close fd with Disk.Io _ -> ()) pg;
    let a = Store.layout ~pg ~at:0 ~n:!na ~n_cap:a_ncap ~ne ~k:!ka ~k_cap:a_kcap ~np ~ns:(s1 - s0) ~sblob:!sblob () in
    let t = Store.layout ~pg ~at:a.len ~n:!nt ~n_cap:t_ncap ~ne:t_ne ~k:!kt ~k_cap:t_kcap ~np:t_np ~ns:0 ~sblob:0 () in
    let run = { Store.a; t; lo; hi = v.group; level; s0 } in
    let runs = Array.append [| run |] (Array.sub rs take (nr - take)) in
    { tmp; path; group = v.group; view = Store.of_runs ~schema:v.schema ~group:v.group ~next_e:v.next_e runs;
      replaced = Array.to_list src }
  | exception (Disk.Io _ as e) -> failed (); raise e
  | exception (Pages.Unreadable _ as e) -> failed (); raise e

(* The file takes its name (G12): renamed over, the directory forced; then every run of the directory that is in no
   chain to the new state is removed (the runs it replaced, those an earlier crash left), but for the newest bottom
   run outside the chain, kept as a fallback should the chain's be damaged, and the files of earlier formats. The
   journal is the truth: runs are caches of it. *)
let install disk dir w =
  disk.Disk.rename w.tmp w.path;
  disk.sync_dir dir;
  let live = Array.to_list (Array.map (fun (r : Store.run) -> name r.lo r.hi) w.view.runs) in
  let runs = list disk dir in
  let spare =
    List.fold_left (fun best (lo, hi, n) -> if lo = 0 && not (List.mem n live) then (match best with Some (h, _) when h >= hi -> best | _ -> Some (hi, n)) else best) None runs
  in
  let keep n = List.mem n live || (match spare with Some (_, s) -> s = n | None -> false) in
  let gone = List.filter (fun n -> not (keep n)) (List.map (fun (_, _, n) -> n) runs) @ old_files disk dir in
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

(* Checks a run's header, CRC table, rank and offset tables and builds it, read through the cache; raises Bad. *)
let check_and_build disk dir (lo0, hi0, file) id =
  let path = Filename.concat dir file in
  let fd = disk.Disk.openf path false in
  match
    let size = disk.size fd in
    if size < header then bad "shorter than its header";
    let h = Bytes.create header in
    disk.pread fd 0 h 0 header;
    if u32 h 0 <> magic then bad "not a run";
    if u32 h 212 <> Crc32c.bytes h 0 212 then bad "its header does not check";
    if u32 h 4 <> format then bad "unknown format %d" (u32 h 4);
    if Bytes.sub_string h 8 16 <> id then bad "a run of another database";
    let g k = Int64.to_int (Bytes.get_int64_le h (24 + (8 * k))) in
    let hi = g 0 and lo = g 1 and level = g 2 and next_e = g 3 and seg = g 4 and off = g 5 and next = g 6 and s0 = g 7 in
    let an = g 8 and ane = g 9 and ak = g 10 and anp = g 11 and ans = g 12 and asb = g 13 and ancap = g 14 and akcap = g 15 in
    let tn = g 16 and tne = g 17 and tk = g 18 and tnp = g 19 and tncap = g 20 and tkcap = g 21 and body = g 22 in
    if lo <> lo0 || hi <> hi0 then bad "its groups are not those of its name";
    if List.exists (fun x -> x < 0) [ an; ane; ak; anp; ans; asb; tn; tne; tk; tnp; s0; level ]
       || an > ancap || ak > akcap || tn > tncap || tk > tkcap || ak > ane || tk > tne
       || anp > Schema.first_thing || tnp > Schema.first_thing || (lo = 0 && tn > 0)
    then bad "bad counts";
    if next < 1 || next > hi + 1 then bad "its journal position is after its group";
    let npages = Pages.pages body in
    if size < header + (npages * Pages.size) + (4 * npages) then bad "shorter than its header says";
    let table = Bytes.create (4 * npages) in
    disk.pread fd (header + (npages * Pages.size)) table 0 (4 * npages);
    if u32 h 208 <> Crc32c.bytes table 0 (4 * npages) then bad "its checksum table does not check";
    let load k =
      let p = Bytes.create Pages.size in
      (try disk.pread fd (header + (k * Pages.size)) p 0 Pages.size with Disk.Io m -> raise (Pages.Unreadable m));
      if Crc32c.bytes p 0 Pages.size <> u32 table (4 * k) then
        raise (Pages.Unreadable (Printf.sprintf "run %s: page %d does not check" file k));
      p
    in
    let pg = Pages.on_file body load in
    if disk == Disk.real then Gc.finalise (fun _ -> try disk.close fd with Disk.Io _ -> ()) pg;
    let a = Store.layout ~pg ~at:0 ~n:an ~n_cap:ancap ~ne:ane ~k:ak ~k_cap:akcap ~np:anp ~ns:ans ~sblob:asb () in
    let t = Store.layout ~pg ~at:a.len ~n:tn ~n_cap:tncap ~ne:tne ~k:tk ~k_cap:tkcap ~np:tnp ~ns:0 ~sblob:0 () in
    if t.len <> body then bad "its layout does not match its size";
    (* small enough: every page read and checked now, and the cache warm *)
    if npages <= !Pages.capacity then for k = 0 to npages - 1 do ignore (Pages.page pg k) done;
    (* bounds: the rank tables count right, every offset table in order and within its rows; a row's ids are checked
       by its page's CRC, and a read out of a run's pages fails, it never reads outside *)
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
    List.iter
      (fun ((b : Store.base), what) ->
        ranks b what;
        mono (Store.safe Store.eoff b) b.k b.n ("the thing offsets of " ^ what);
        if b.np > 0 then mono (Store.safe Store.poff b) b.np b.n ("the property offsets of " ^ what))
      [ a, "its additions"; t, "its retractions" ];
    mono (Store.safe Store.soff a) a.ns a.sblob "the text offsets";
    { Store.a; t; lo; hi; level; s0 }, next_e, { Journal.segment = seg; offset = off; next }
  with
  | r -> r
  | exception e -> (try disk.close fd with Disk.Io _ -> ()); raise e

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
        (* built: the newest first; the schema read from the facts of the property things *)
        let runs = Array.of_list (List.map (fun (r, _, _) -> r) built) in
        let _, next_e, pos = List.hd built in
        let v = Store.of_runs ~group:runs.(0).hi ~next_e runs in
        match
          let schema = ref Schema.initial in
          for p = Schema.first_prop to min (Store.max_thing v + 1) Schema.first_thing - 1 do
            if Store.holders v p <> 0 then
              match Resolve.read_prop v p with
              | Ok d -> schema := Schema.set !schema p d
              | Error m -> bad "%s" m
          done;
          !schema
        with
        | schema -> Some ({ v with schema }, pos)
        | exception Bad m -> let _, _, n = List.hd chain in aside n m
        | exception Pages.Unreadable m -> let _, _, n = List.hd chain in aside n m))
  in
  let r = go [] in
  r, List.rev !notes
