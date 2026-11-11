(* The facts. A view is a stack of runs, sorted and columnar, in pages (Pages: the bytes of a run's file, read
   through the cache), plus a delta of the recent changes in persistent maps, so that a view is a value: taking one
   is free, keeping one costs nothing, and a fork is a view with its own delta. The runs are the levels of an LSM tree
   (O'Neil et al. 1996), newest first: each holds the changes of a range of groups on top of the state of the runs
   below it, as facts it adds (part a) and facts of the runs below it retracts (part t, empty at the bottom); a fact
   is in a view when the newest entry for it (the delta's, or the newest run's that has one) adds it. A run's counts
   are net: a run adds only facts absent below it and retracts only facts present below it, so every count is a sum of
   exact counts.

   A part has three sections, coded with a frame of reference (Pack: a base and a bit width a block, Goldstein et
   al. 1998, Zukowski et al. 2006), each value found in O(1) without decoding its neighbours:
     by thing     the things it holds: a rank table (one 64-bit word for 32 thing ids: their presence bits, and how
                  many things come before) gives a thing's slot; the slots in blocks of 128, a block one entry a
                  property its slots have, the entry the offsets of each slot's values (c * i + a residual, none when
                  every slot has c values) and the values, sorted within a slot, in a few bits each from the entry's
                  base. So a block is a small column store of 128 things (PAX, Ailamaki et al. 2001)
     by property  the rows (value, thing) of property p sorted by value then thing, in blocks of 128 rows: the values
                  from the block's first value, the things from the block's least thing; for most properties a value
                  index: a rank table over the property's value range and the first row of each value present, so
                  that the rows of (p, w) are found with one rank and two offsets (links, texts, dates, small ints)
     dictionary   the texts s0 .. s0+ns-1: their offsets, their bytes, and a hash table of their ids (part a only:
                  a run holds the texts interned between the run below it and itself)

   Every lookup is a rank, an offset and the answer, on each run that holds the thing (the rank table says so with
   one bit) and on the delta; every count is exact. *)

type base = {
  pg : Pages.t;
  hot : Bytes.t array;  (* pg's hot table, here so that a read is one load less *)
  n : int;  (* rows *)
  ne : int;  (* thing ids 0 .. ne-1 in the rank table *)
  k : int;  (* things with rows *)
  np : int;  (* property ids 0 .. np-1 *)
  ns : int;  (* texts *)
  sblob : int;  (* bytes of all texts *)
  hbits : int;  (* the text hash table has 2^hbits slots *)
  o_erank : int;  (* (blocks ne + 1) words *)
  o_tdir : int;  (* (thing blocks + 1) u64: the byte offset of each thing block from o_tdata *)
  o_tdata : int;
  o_poff : int;  (* (np + 1) u64: the first row of each property *)
  o_pblk : int;  (* (np + 1) u64: the first row block of each property *)
  o_pdist : int;  (* np u64: distinct values *)
  o_pidx : int;  (* np entries of 32 bytes: the value index (vlo, first rank word or -1, words, first offset block) *)
  o_vdir : int;  (* (row blocks + 1) entries of 16 bytes: the block's byte offset from o_vdata, its first value *)
  o_vdata : int;
  o_vrank : int;  (* the value indexes' rank words *)
  o_vmh : int;  (* their offsets: Mono headers, then bits *)
  o_vmb : int;
  o_smh : int;  (* the texts' offsets: Mono headers, then bits *)
  o_smb : int;
  o_sblob : int;
  o_shash : int;  (* 2^hbits u32: a text's index + 1, or 0 *)
  o_cp : int;  (* np entries of 64 bytes: each property's column (Column order below) *)
  o_crank : int;  (* the columns' rank words *)
  o_cdir : int;  (* their block directories *)
  o_cdata : int;  (* their values *)
  o_cmh : int;  (* their offsets for things of several values: Mono headers, then bits *)
  o_cmb : int;
  len : int;  (* the end of the part's sections *)
  d0 : int;  (* every thing from d0 to ne - 1 is held: its slot is r0 + (e - d0), with no rank to read *)
  r0 : int;
  cols : int array;  (* the columns' entries (8 ints a property, as o_cp holds them), read once *)
}

type run = {
  a : base;  (* the facts it adds, and its texts *)
  t : base;  (* the facts of the runs below that it retracts *)
  lo : int;  (* the state it rests on: the runs below it hold groups 1..lo *)
  hi : int;  (* its last group *)
  level : int;  (* 1, 2, ...: level l holds at most compact_min * ratio^l rows *)
  s0 : int;  (* the id of its first text *)
}

let al x = (x + 7) land lnot 7
let blocks ne = (ne + 31) lsr 5

(* the block sizes: 128 slots a thing block, 128 rows a row block, 128 offsets a Mono block *)
let tb = 128
let blocks128 n = (n + 127) lsr 7

(* bytes of n fields of w bits, and of a Mono (monotone sequence) block of 128 fields of w bits *)
let pbytes n w = Pack.bytes n w

(* The rooms a merge lays a part out by. A merge knows its counts only once it is done, so it lays a part out by
   upper bounds, and the bytes past the counts are never written (logical pages no file page holds, Snapshot): what a
   section's room is, from [n_cap] rows, [k_cap] things, [np] properties, [vb_cap] row blocks (each property's rows
   start a block), [vwords] rank words and [vm_blocks] offset blocks of the value indexes, [ns] texts of [sblob] bytes. *)
type rooms = { tdata : int; vdata : int; vmb : int; smb : int; crank : int; cdir : int; cdata : int; cmh : int; cmb : int }

let wmax = 64

(* the rooms of a column of at most [cap] rows: its block directory, its values (at most 64 bits a row), its offsets
   (Mono headers, then bits); and of a rank table over [ne] thing ids. Each property's rooms follow one another in its
   sections, in property order (Snapshot.col_at) *)
let cdir_room cap = 16 * blocks128 cap
let cdata_room cap = (8 * cap) + 8
let cmh_room cap = 16 * blocks128 (cap + 1)
let cmb_room cap = (blocks128 (cap + 1) * pbytes tb (Pack.width (cap + 1))) + 8
let crank_room ne = 8 * (blocks ne + 2)

let rooms ~n_cap ~k_cap ~np ~vb_cap ~vm_blocks ~ns ~sblob ~ne ~caps =
  let tbn = blocks128 k_cap in
  let entries = min n_cap (np * tbn) in
  (* a thing block: 16 bytes and 20 an entry (at most min(rows, np) a block), the records' first bits, and each entry's
     data as a column would take it (a field is chosen only when it takes no more): 129 residuals of at most 32 bits,
     values of at most 64 bits *)
  let tdata = (16 * tbn) + (24 * entries) + (entries * (pbytes (tb + 1) 32 + 8)) + (tbn * 24) + (8 * n_cap) + 8 in
  (* a row block: 8 bytes, values of at most 64 bits, things of at most 32 *)
  let vdata = (24 * vb_cap) + (12 * n_cap) + 8 in
  (* and the rest of a page skipped before a block that does not fit in it: at most a block's size a block *)
  let tdata = 2 * tdata and vdata = 2 * vdata in
  let sum f = Array.fold_left (fun n cap -> if cap > 0 then n + al (f cap) else n) 0 caps in
  { tdata; vdata; vmb = (vm_blocks * pbytes tb (Pack.width (n_cap + 1))) + 8; smb = (blocks128 (ns + 1) * pbytes tb (Pack.width (sblob + 1))) + 8;
    crank = sum (fun _ -> crank_room ne); cdir = sum cdir_room; cdata = sum cdata_room; cmh = sum cmh_room; cmb = sum cmb_room }

(* The sections of a part from offset [at]. *)
let layout ?(pg = Pages.empty) ~at ~n ~ne ~k ~k_cap ~np ~ns ~sblob ~hbits ~vb_cap ~vwords ~vm_blocks (r : rooms) () =
  let off = ref at in
  let sec bytes = let o = !off in off := al (!off + bytes); o in
  let o_erank = sec (8 * (blocks ne + 1)) in
  let o_tdir = sec (8 * (blocks128 k_cap + 1)) in
  let o_tdata = sec r.tdata in
  let o_poff = sec (8 * (np + 1)) in
  let o_pblk = sec (8 * (np + 1)) in
  let o_pdist = sec (8 * np) in
  let o_pidx = sec (32 * np) in
  let o_vdir = sec (16 * (vb_cap + 1)) in
  let o_vdata = sec r.vdata in
  let o_vrank = sec (8 * vwords) in
  let o_vmh = sec (16 * vm_blocks) in
  let o_vmb = sec r.vmb in
  let o_smh = sec (16 * blocks128 (ns + 1)) in
  let o_smb = sec r.smb in
  let o_sblob = sec (sblob + 8) in
  let o_shash = sec (if ns = 0 then 0 else 4 lsl hbits) in
  let o_cp = sec (64 * np) in
  let o_crank = sec r.crank in
  let o_cdir = sec r.cdir in
  let o_cdata = sec r.cdata in
  let o_cmh = sec r.cmh in
  let o_cmb = sec r.cmb in
  { pg; hot = pg.Pages.hot; n; ne; k; np; ns; sblob; hbits; o_erank; o_tdir; o_tdata; o_poff; o_pblk; o_pdist; o_pidx;
    o_vdir; o_vdata; o_vrank; o_vmh; o_vmb; o_smh; o_smb; o_sblob; o_shash; o_cp; o_crank; o_cdir; o_cdata; o_cmh; o_cmb;
    len = !off; d0 = ne; r0 = k; cols = [||] }

(* the offsets of a part, as a run's header lists them, and back *)
let offsets b =
  [ b.o_erank; b.o_tdir; b.o_tdata; b.o_poff; b.o_pblk; b.o_pdist; b.o_pidx; b.o_vdir; b.o_vdata; b.o_vrank; b.o_vmh;
    b.o_vmb; b.o_smh; b.o_smb; b.o_sblob; b.o_shash; b.o_cp; b.o_crank; b.o_cdir; b.o_cdata; b.o_cmh; b.o_cmb; b.len ]

let of_offsets ~pg ~n ~ne ~k ~np ~ns ~sblob ~hbits = function
  | [ o_erank; o_tdir; o_tdata; o_poff; o_pblk; o_pdist; o_pidx; o_vdir; o_vdata; o_vrank; o_vmh; o_vmb; o_smh; o_smb;
      o_sblob; o_shash; o_cp; o_crank; o_cdir; o_cdata; o_cmh; o_cmb; len ] ->
    { pg; hot = pg.Pages.hot; n; ne; k; np; ns; sblob; hbits; o_erank; o_tdir; o_tdata; o_poff; o_pblk; o_pdist; o_pidx;
      o_vdir; o_vdata; o_vrank; o_vmh; o_vmb; o_smh; o_smb; o_sblob; o_shash; o_cp; o_crank; o_cdir; o_cdata; o_cmh; o_cmb;
      len; d0 = ne; r0 = k; cols = [||] }
  | _ -> invalid_arg "Store.of_offsets"

let noffsets = 23

(* the hash table of ns texts: the least power of two of at least 2 ns slots (load at most 1/2) *)
let hbits_for ns = let b = ref 0 in while 1 lsl !b < 2 * ns do incr b done; !b

(* a part with nothing: every lookup answers at once, without a page *)
let nothing =
  layout ~at:0 ~n:0 ~ne:0 ~k:0 ~k_cap:0 ~np:0 ~ns:0 ~sblob:0 ~hbits:0 ~vb_cap:0 ~vwords:0 ~vm_blocks:0
    { tdata = 0; vdata = 0; vmb = 0; smb = 0; crank = 0; cdir = 0; cdata = 0; cmh = 0; cmb = 0 } ()

external get64u : Bytes.t -> int -> int64 = "%caml_bytes_get64u"
external get32u : Bytes.t -> int -> int32 = "%caml_bytes_get32u"
external get16u : Bytes.t -> int -> int = "%caml_bytes_get16u"

(* Two kinds of readers of the base's pages. A read of a hot page is one load and one comparison either way; they
   differ in what happens otherwise:
   - the raising readers (i64, field, ...) raise [Miss k]: a lookup that calls nothing (a binary search, a count, a
     membership test) is run by [safe] or its own wrapper again from its start once page k is in. With no call on
     its path, OCaml keeps the loop's values in registers (a call would make it save them all on the stack);
   - the calling readers (ci64, cfield, ...) bring the page in themselves (Pages.touch), for the loops that call a
     function per row, which save their registers around that call anyway.
   A [Miss] never leaves the functions of this section. *)
exception Miss of int

let fault b k = Pages.fault b.pg k

(* a lookup's end: in trace mode, its pages leave the hot table *)
let[@inline] ended r = if !Pages.tracing then Pages.cool (); r

let[@inline] frame b o =
  let k = o lsr Pages.bits in
  let f = Array.get b.hot k in
  if f != Pages.absent then f else raise_notrace (Miss k)

let[@inline] framec b o =
  let k = o lsr Pages.bits in
  let f = Array.get b.hot k in
  if f != Pages.absent then f else Pages.touch b.pg k

(* aligned reads: 2, 4 and 8 bytes at a multiple of their size, which never cross a page *)
let[@inline] i64 b o = Int64.to_int (get64u (frame b o) (o land Pages.mask))
let[@inline] u32 b o = Int32.to_int (get32u (frame b o) (o land Pages.mask)) land 0xFFFFFFFF
let[@inline] u16 b o = get16u (frame b o) (o land Pages.mask)
let[@inline] byte b o = Char.code (Bytes.unsafe_get (frame b o) (o land Pages.mask))
let[@inline] ci64 b o = Int64.to_int (get64u (framec b o) (o land Pages.mask))
let[@inline] cu32 b o = Int32.to_int (get32u (framec b o) (o land Pages.mask)) land 0xFFFFFFFF
let[@inline] cu16 b o = get16u (framec b o) (o land Pages.mask)
let[@inline] cbyte b o = Char.code (Bytes.unsafe_get (framec b o) (o land Pages.mask))

(* the 8 bytes at o, any alignment, as an int (bit 63 dropped): one load, or byte by byte across a page's end *)
let[@inline never] w64x b o =
  let x = ref 0 in
  for j = 7 downto 0 do x := (!x lsl 8) lor byte b (o + j) done;
  !x

let[@inline] w64 b o =
  let f = frame b o and i = o land Pages.mask in
  if i <= Pages.size - 8 then Int64.to_int (get64u f i) else w64x b o

let[@inline never] cw64x b o =
  let x = ref 0 in
  for j = 7 downto 0 do x := (!x lsl 8) lor cbyte b (o + j) done;
  !x

let[@inline] cw64 b o =
  let f = framec b o and i = o land Pages.mask in
  if i <= Pages.size - 8 then Int64.to_int (get64u f i) else cw64x b o

(* The field of w bits (at most 63) at bit [bit] of the bit-packed array at byte o (Pack's layout): one unaligned
   load, a shift and a mask; a field that reaches past bit 62 of its load takes a ninth byte. *)
let[@inline never] fieldx b o bit w =
  let o = o + (bit lsr 3) and sh = bit land 7 in
  let lo = w64 b o lsr sh in
  let rest = (byte b (o + 7) lsr 7) lor (byte b (o + 8) lsl 1) in
  (lo lor (rest lsl (63 - sh))) land Pack.mask w

let[@inline] field b o bit w =
  if w = 0 then 0
  else
    let sh = bit land 7 in
    if sh + w <= 63 then (w64 b (o + (bit lsr 3)) lsr sh) land Pack.mask w else fieldx b o bit w

let[@inline never] cfieldx b o bit w =
  let o = o + (bit lsr 3) and sh = bit land 7 in
  let lo = cw64 b o lsr sh in
  let rest = (cbyte b (o + 7) lsr 7) lor (cbyte b (o + 8) lsl 1) in
  (lo lor (rest lsl (63 - sh))) land Pack.mask w

let[@inline] cfield b o bit w =
  if w = 0 then 0
  else
    let sh = bit land 7 in
    if sh + w <= 63 then (cw64 b (o + (bit lsr 3)) lsr sh) land Pack.mask w else cfieldx b o bit w

(* A monotone sequence (Mono: offsets) in blocks of 128: a header of 16 bytes a block (the base, then the width in
   the low byte and the offset of the block's bits from [mb] above it), the bits apart; entry q in O(1) *)
let[@inline] mono b mh mb q =
  let h = mh + ((q lsr 7) lsl 4) in
  let x = i64 b (h + 8) in
  let w = x land 0xFF in
  i64 b h + field b (mb + (x lsr 8)) ((q land 127) * w) w

let[@inline] cmono b mh mb q =
  let h = mh + ((q lsr 7) lsl 4) in
  let x = ci64 b (h + 8) in
  let w = x land 0xFF in
  ci64 b h + cfield b (mb + (x lsr 8)) ((q land 127) * w) w

(* A fact only derived (by a rule, not asserted) carries a flag. In the 64-bit value words of runs of formats 5 and 6
   it was bit 63; in a block of format 7, an entry or a row block with a derived fact keeps each value's flag in the
   lowest bit of its field, the value in the bits above, and a block with none spends no bit on it. *)

(* the bits set in a 32-bit word (Warren, Hacker's Delight, 5-1) *)
let[@inline] popcount x =
  let x = x - ((x lsr 1) land 0x55555555) in
  let x = (x land 0x33333333) + ((x lsr 2) land 0x33333333) in
  let x = (x + (x lsr 4)) land 0x0F0F0F0F in
  ((x * 0x01010101) lsr 24) land 0xFF

(* the slot of thing e in the part, or -1: one word of the rank table; a block whose 32 things are all there needs no
   count *)
let[@inline] rank w e =
  let bits = w land 0xFFFFFFFF and i = e land 31 in
  if (bits lsr i) land 1 = 0 then -1
  else (w lsr 32) + if bits = 0xFFFFFFFF then i else popcount (bits land ((1 lsl i) - 1))

let[@inline] slot b e =
  if e >= b.d0 then (if e < b.ne then b.r0 + (e - b.d0) else -1)
  else if e < 0 then -1
  else rank (i64 b (b.o_erank + ((e lsr 5) lsl 3))) e

let[@inline] cslot b e =
  if e >= b.d0 then (if e < b.ne then b.r0 + (e - b.d0) else -1)
  else if e < 0 then -1
  else rank (ci64 b (b.o_erank + ((e lsr 5) lsl 3))) e

(* d0 and r0 of a part, from its rank table: the longest run of things held up to the end (a part made by a load or a
   full merge holds every thing above the property things: their lookups read no rank) *)
let dense b =
  if b.ne = 0 then b
  else begin
    let word j = ci64 b (b.o_erank + (j lsl 3)) in
    let d0 = ref b.ne and go = ref true and j = ref ((b.ne - 1) lsr 5) in
    while !go && !j >= 0 do
      let lo = !j lsl 5 in
      let hi = min b.ne (lo + 32) in
      let mask = (1 lsl (hi - lo)) - 1 in
      let bits = word !j land mask in
      if bits = mask then (d0 := lo; decr j)
      else begin
        (* the highest thing not held, in this block *)
        let x = ref (hi - lo - 1) in
        while (bits lsr !x) land 1 = 1 do decr x done;
        d0 := lo + !x + 1;
        go := false
      end
    done;
    let r0 = if !d0 >= b.ne then b.k else rank (word (!d0 lsr 5)) !d0 in
    { b with d0 = !d0; r0 }
  end

(* a part as it is read: d0 and r0, and its columns' entries in memory (np 64-byte entries: a few KB) *)
let ready b =
  let b = dense b in
  { b with cols = Array.init (8 * b.np) (fun i -> ci64 b (b.o_cp + (8 * i))) }

(* [f b x] again until it misses no page; for a raising reader, or a lookup made of them *)
let rec safe f b x = match f b x with r -> ended r | exception Miss k -> fault b k; safe f b x

(* ---- By thing: the blocks of 128 slots ----
   A block holds the rows of up to 128 slots (things). A property that every slot has at most once is a fixed field
   of each slot's record, when that takes no more bits than a column of its own: a lookup of it reads the record's
   field. The others are columns: their slots' offsets (c k + residual k) and their values.
     0 B u16 (slots) | 2 m u16 (entries) | 4 hv u8 (1: a record's first bit says the slot has values in a column)
     | 5 three zero bytes | 8 R u32 (bits of a record) | 12 zero u32
     | 16 m entries of 16 bytes, by property: p u16 | wv u8 (bits a value, its flag included) | mode u8 (bit 7: each
       value's lowest bit is its derived flag; bit 6: a fixed field, bit 5: with a bit "present" first; otherwise
       bits 0-5: bits of a residual, 0 when every slot has c values) | c u32 (a field: its bit in the record; a
       column: the least count) | base i64 (the values' least)
     | m u32: a column's data, its byte from the block's start (0 for a field)
     | at 8-aligned 16 + 20 m: B records of R bits | the columns' data: B + 1 residuals of wr bits (when wr > 0),
       then the values, sorted within a slot
   A block no larger than a page lies in one page (the writer starts it on the next page otherwise): its fields are
   read from that page's bytes; a block across pages (a thing with thousands of values) has its header copied and
   the rest read from the pages field by field, so a lookup reads a few fields, never the whole. *)

(* bytes [o, o + n) of the run, copied: a header, or a row block, across pages *)
let[@inline never] assemble b o n =
  let c = Bytes.make (n + 8) '\000' in
  let j = ref 0 in
  while !j < n do
    let x = o + !j in
    let m = min (n - !j) (Pages.size - (x land Pages.mask)) in
    Bytes.blit (frame b x) (x land Pages.mask) c !j m;
    j := !j + m
  done;
  c

let[@inline never] cassemble b o n =
  let c = Bytes.make (n + 8) '\000' in
  let j = ref 0 in
  while !j < n do
    let x = o + !j in
    let m = min (n - !j) (Pages.size - (x land Pages.mask)) in
    Bytes.blit (framec b x) (x land Pages.mask) c !j m;
    j := !j + m
  done;
  c

let[@inline] g16 f i = Bytes.get_uint16_le f i
let[@inline] g8 f i = Bytes.get_uint8 f i
let[@inline] g32 f i = Int32.to_int (Bytes.get_int32_le f i) land 0xFFFFFFFF
let[@inline] g64 f i = Int64.to_int (Bytes.get_int64_le f i)

(* the next block's offset, from the directory word at d (the same page but at a page's last word) *)
let[@inline] tnext b d = let i = d land Pages.mask in if i <= Pages.size - 16 then Int64.to_int (get64u (frame b d) (i + 8)) else i64 b (d + 8)
let[@inline] ctnext b d = let i = d land Pages.mask in if i <= Pages.size - 16 then Int64.to_int (get64u (framec b d) (i + 8)) else ci64 b (d + 8)

(* a block's header length, from its first word (B, m) *)
let[@inline] hlen8 x = al (16 + (20 * ((x lsr 16) land 0xFFFF)))

(* bit [bit] (from the block's start) of the block: from f's bytes when the whole block is there (one), from the pages
   otherwise (bo the block's byte in the run) *)
let[@inline] rget b bo f rb one bit w = if one then Pack.get f (rb + bit) w else field b bo bit w
let[@inline] crget b bo f rb one bit w = if one then Pack.get f (rb + bit) w else cfield b bo bit w

(* the entry of property p in the header at i of f: its index, or -1 *)
let tentry f i p =
  let m = g16 f (i + 2) in
  if m <= 8 then begin
    let j = ref 0 and r = ref (-1) in
    while !j < m do
      let q = g16 f (i + 16 + (16 * !j)) in
      if q >= p then (if q = p then r := !j; j := m) else incr j
    done;
    !r
  end
  else begin
    let lo = ref 0 and hi = ref m in
    while !lo < !hi do
      let mid = (!lo + !hi) lsr 1 in
      if g16 f (i + 16 + (16 * mid)) < p then lo := mid + 1 else hi := mid
    done;
    if !lo < m && g16 f (i + 16 + (16 * !lo)) = p then !lo else -1
  end

(* ---- A thing's block: its values ---- *)

(* value x of the values at bit va (wv bits each, flagged or not, from base), and its flag *)
let[@inline] tval b bo f rb one va wv fl base x =
  if fl = 0 then base + rget b bo f rb one (va + (x * wv)) wv else base + rget b bo f rb one (va + (x * wv) + 1) (wv - 1)
let[@inline] ctval b bo f rb one va wv fl base x =
  if fl = 0 then base + crget b bo f rb one (va + (x * wv)) wv else base + crget b bo f rb one (va + (x * wv) + 1) (wv - 1)
let[@inline] tflag b bo f rb one va wv fl x = fl <> 0 && rget b bo f rb one (va + (x * wv)) 1 = 1
let[@inline] ctflag b bo f rb one va wv fl x = fl <> 0 && crget b bo f rb one (va + (x * wv)) 1 = 1

(* the place of the first value >= w among values lo .. hi-1 from va: a binary search down to 8, then a scan *)
let[@inline] tlower b bo f rb one va wv fl base lo hi w =
  let lo = ref lo and hi = ref hi in
  while !hi - !lo > 8 do
    let mid = (!lo + !hi) lsr 1 in
    if tval b bo f rb one va wv fl base mid < w then lo := mid + 1 else hi := mid
  done;
  while !lo < !hi && tval b bo f rb one va wv fl base !lo < w do incr lo done;
  !lo

(* A column's offset of slot k (its data at byte d of the block, from the block's start), and where its values start *)
let[@inline] toff b bo f rb one c wr d k = if wr = 0 then c * k else (c * k) + rget b bo f rb one ((d lsl 3) + (k * wr)) wr
let[@inline] ctoff b bo f rb one c wr d k = if wr = 0 then c * k else (c * k) + crget b bo f rb one ((d lsl 3) + (k * wr)) wr
let[@inline] tvals nb wr d = (d + if wr = 0 then 0 else pbytes (nb + 1) wr) lsl 3

(* The block of slot s, read with two page lookups (the directory's page, the block's): f its header's bytes (the
   page, or a copy of a header across pages), i where it starts in them, one: the whole block lies in that page.
   Written out in each lookup below: a function returning them all would allocate. *)

(* every row of e, in (property, value) order, with its flag; a record whose first bit says it has no values in a
   column reads no column *)
let base_iter_ef b e fn =
  let s = cslot b e in
  if s >= 0 then begin
    let d = b.o_tdir + ((s lsr 7) lsl 3) in
    let o0 = ci64 b d in
    let bo = b.o_tdata + o0 and n = ctnext b d - o0 in
    let i = bo land Pages.mask in
    let f = framec b bo in
    let h = hlen8 (Int64.to_int (get64u f i)) in
    let one = i + n <= Pages.size and hp = i + h <= Pages.size in
    let f = if hp then f else cassemble b bo h and i = if hp then i else 0 in
    let m = g16 f (i + 2) and rb = i lsl 3 and k = s land 127 in
    let rec_at = (h lsl 3) + (k * g32 f (i + 8)) in
    let cols = g8 f (i + 4) = 0 || crget b bo f rb one rec_at 1 = 1 in
    for j = 0 to m - 1 do
      let en = i + 16 + (16 * j) in
      let p = g16 f en and wv = g8 f (en + 2) and mode = g8 f (en + 3) and base = g64 f (en + 8) in
      let fl = mode lsr 7 in
      if mode land 0x40 <> 0 then begin
        let at = rec_at + g32 f (en + 4) in
        if mode land 0x20 = 0 then fn p (ctval b bo f rb one at wv fl base 0) (ctflag b bo f rb one at wv fl 0)
        else if crget b bo f rb one at 1 = 1 then fn p (ctval b bo f rb one (at + 1) wv fl base 0) (ctflag b bo f rb one (at + 1) wv fl 0)
      end
      else if cols then begin
        let c = g32 f (en + 4) and wr = mode land 0x3F and dd = g32 f (i + 16 + (16 * m) + (4 * j)) in
        let lo = ctoff b bo f rb one c wr dd k and hi = ctoff b bo f rb one c wr dd (k + 1) in
        let va = tvals (g16 f i) wr dd in
        for x = lo to hi - 1 do fn p (ctval b bo f rb one va wv fl base x) (ctflag b bo f rb one va wv fl x) done
      end
    done
  end

let base_iter_e b e fn = base_iter_ef b e (fun p w _ -> fn p w)

(* ---- The column order: each property's rows (thing, value) in thing order ----
   Vertical partitioning (Abadi, Marcus, Madden, Hollenbach, VLDB 2007): the rows of one property, apart from the
   others, so that a lookup of (thing, property) reads one property's bytes and a question over a few properties
   reads only theirs. Every lookup of (e, p) in a part reads here; the thing blocks above serve "every fact of e".
     entry of p at o_cp + 64 p: tlo | rank (byte of its first rank word, -1: no rows) | words | q0 | dir | data |
       mh | mb (bytes in the run)
     rank words  as the part's own: word j has the presence bits of things tlo + 32 j .. tlo + 32 j + 31 and, above
                 them, the things of p before; the last word holds the things of p. Properties held by the same
                 things share one table
     rows        the q-th thing of p (from 0) has the rows q .. q (one value) while q < q0; from q0 on, its rows start
                 at q0 + m(q - q0), m a Mono sequence (mh, mb) from m(0) = 0 to m(things - q0) = rows - q0: a property
                 whose things all have one value has no offsets at all
     blocks      row r is in block r / 128; a block's directory entry (16 bytes at dir + 16 (r / 128)): its byte from
                 data lsl 16 | mode lsl 8 | wv, then its base; mode bit 0: each value's lowest bit is its derived
                 flag; bit 1: the values are coded from their thing (value - thing: a link to a nearby thing, as an
                 invoice's client). Value = base + its field (+ the thing). Values of one thing are sorted *)

(* the rank (from 0) of thing e among those of p, or -1 *)
let[@inline] ce b p k = Array.unsafe_get b.cols ((p lsl 3) + k)

let[@inline] cthing b p e =
  let ra = ce b p 1 in
  if ra < 0 then -1
  else
    let d = e - ce b p 0 in
    if d < 0 || d lsr 5 >= ce b p 2 - 1 then -1 else rank (i64 b (ra + ((d lsr 5) lsl 3))) d

let[@inline] ccthing b p e =
  let ra = ce b p 1 in
  if ra < 0 then -1
  else
    let d = e - ce b p 0 in
    if d < 0 || d lsr 5 >= ce b p 2 - 1 then -1 else rank (ci64 b (ra + ((d lsr 5) lsl 3))) d

(* the first row of the q-th thing of p (q = things: the rows of p) *)
let[@inline] crow b p q =
  let q0 = ce b p 3 in
  if q <= q0 then q else q0 + mono b (ce b p 6) (ce b p 7) (q - q0)

let[@inline] ccrow b p q =
  let q0 = ce b p 3 in
  if q <= q0 then q else q0 + cmono b (ce b p 6) (ce b p 7) (q - q0)

(* the value of row r of p, of thing e *)
let[@inline] cval b p e r =
  let d = ce b p 4 + ((r lsr 7) lsl 4) in
  let h = i64 b d in
  let wv = h land 0xFF and mode = (h lsr 8) land 0xFF in
  let fl = mode land 1 in
  let v = i64 b (d + 8) + field b (ce b p 5 + (h lsr 16)) (((r land 127) * wv) + fl) (wv - fl) in
  if mode land 2 = 0 then v else v + e

let[@inline] ccval b p e r =
  let d = ce b p 4 + ((r lsr 7) lsl 4) in
  let h = ci64 b d in
  let wv = h land 0xFF and mode = (h lsr 8) land 0xFF in
  let fl = mode land 1 in
  let v = ci64 b (d + 8) + cfield b (ce b p 5 + (h lsr 16)) (((r land 127) * wv) + fl) (wv - fl) in
  if mode land 2 = 0 then v else v + e

(* the derived flag of row r of p *)
let[@inline] cflag b p r =
  let d = ce b p 4 + ((r lsr 7) lsl 4) in
  let h = i64 b d in
  (h lsr 8) land 1 = 1 && field b (ce b p 5 + (h lsr 16)) ((r land 127) * (h land 0xFF)) 1 = 1

(* ---- One part alone ---- *)

let[@inline] has_col b p = p >= 0 && p < b.np && b.n > 0

let base_iter_ea b e p fn =
  if has_col b p then begin
    let q = ccthing b p e in
    if q >= 0 then begin
      let lo = ccrow b p q and hi = ccrow b p (q + 1) in
      for r = lo to hi - 1 do fn (ccval b p e r) done
    end
  end

let count_ea b e p =
  let q = cthing b p e in
  if q < 0 then 0 else crow b p (q + 1) - crow b p q

let rec base_count_ea b e p =
  if not (has_col b p) then 0 else match count_ea b e p with r -> ended r | exception Miss k -> fault b k; base_count_ea b e p

(* 0: no row of (e p w) in the part; 1: a row, asserted; 2: a row, only derived. A binary search among e's values
   down to 8, then a scan *)
let state_e b e p w =
  let q = cthing b p e in
  if q < 0 then 0
  else begin
    let stop = crow b p (q + 1) in
    let lo = ref (crow b p q) and hi = ref stop in
    while !hi - !lo > 8 do
      let mid = (!lo + !hi) lsr 1 in
      if cval b p e mid < w then lo := mid + 1 else hi := mid
    done;
    while !lo < !hi && cval b p e !lo < w do incr lo done;
    if !lo < stop && cval b p e !lo = w then (if cflag b p !lo then 2 else 1) else 0
  end

let rec base_state b e p w =
  if not (has_col b p) then 0 else match state_e b e p w with r -> ended r | exception Miss k -> fault b k; base_state b e p w

let rec base_mem b e p w =
  has_col b p && match state_e b e p w with r -> ended (r > 0) | exception Miss k -> fault b k; base_mem b e p w

(* the things of p in the part, in thing order, each once *)
let base_iter_pt b p fn =
  if has_col b p then begin
    let ra = ce b p 1 in
    if ra >= 0 then begin
      let tlo = ce b p 0 and words = ce b p 2 in
      for j = 0 to words - 2 do
        let bits = ref (ci64 b (ra + (j lsl 3)) land 0xFFFFFFFF) in
        let e0 = tlo + (j lsl 5) in
        while !bits <> 0 do
          let low = !bits land (- !bits) in
          fn (e0 + popcount (low - 1));
          bits := !bits lxor low
        done
      done
    end
  end

(* the value of (e, p) when e has exactly one: 1 and the value in cell.(0); 0: none; 2: several *)
let value1 b e p (cell : int array) =
  let q = cthing b p e in
  if q < 0 then 0
  else begin
    let lo = crow b p q in
    match crow b p (q + 1) - lo with
    | 1 -> Array.unsafe_set cell 0 (cval b p e lo); 1
    | 0 -> 0
    | _ -> 2
  end

let rec base_value1 b e p cell =
  if not (has_col b p) then 0 else match value1 b e p cell with r -> ended r | exception Miss k -> fault b k; base_value1 b e p cell

(* does e hold p in the part: one bit of the column's rank table (a thing it counts has a row at least) *)
let rec base_has_p b e p = has_col b p && match cthing b p e with q -> ended (q >= 0) | exception Miss k -> fault b k; base_has_p b e p

(* The open's checks of a column (Snapshot.check_and_build), on pages that checked: a rank table's counts follow from
   its bits (its last word a count alone): the things it counts, or -1; offsets from 0 to [last], each larger than the
   one before (a thing has a value at least); blocks in order within [room] bytes of values, of widths at most 64. *)
let check_rank b at words =
  let r = ref 0 and ok = ref (words >= 2) in
  for j = 0 to words - 1 do
    let w = ci64 b (at + (j lsl 3)) in
    if w lsr 32 <> !r || (j = words - 1 && w land 0xFFFFFFFF <> 0) then ok := false;
    r := !r + popcount (w land 0xFFFFFFFF)
  done;
  if !ok then !r else -1

let check_offsets b mh mb n last =
  let ok = ref (cmono b mh mb 0 = 0 && cmono b mh mb n = last) and prev = ref (-1) in
  for q = 0 to n do
    let x = cmono b mh mb q in
    if x <= !prev then ok := false;
    prev := x
  done;
  !ok

let check_blocks b dir rows room =
  let ok = ref true and prev = ref 0 in
  for j = 0 to blocks128 rows - 1 do
    let h = ci64 b (dir + (j lsl 4)) in
    let n = min tb (rows - (j lsl 7)) and wv = h land 0xFF and off = h lsr 16 in
    if off < !prev || wv > 64 || (h lsr 8) land 0xFF > 3 || off + pbytes n wv > room then ok := false;
    prev := off + pbytes n wv
  done;
  !ok

let rec base_has b e = b.k > 0 && match slot b e with s -> ended (s >= 0) | exception Miss k -> fault b k; base_has b e

(* ---- By property: the row blocks of 128 rows, and the value indexes ----
   A row block: wv u8 (bits a value, its flag included) | fl u8 | wt u8 (bits a thing) | gaps u8 | the least
   thing u32 | the values (from the block's first value, in the directory), then the things: from the least (gaps 0),
   or, gaps 1, each from the thing before it when its value is the one before's (minus 1: things of a value differ).
   A
   value index of p (pidx: vlo, the first of its rank words, their count, its first offset block): word j tells which
   of the values vlo + 32j .. vlo + 32j + 31 p takes, and how many it takes below them; offset q is the first row,
   from p's first, of p's q-th value, and offset pdist the rows of p. *)

let[@inline] poff b p = i64 b (b.o_poff + (8 * p))
let[@inline] cpoff b p = ci64 b (b.o_poff + (8 * p))
let[@inline] pdist b p = i64 b (b.o_pdist + (8 * p))

(* the row block j: its bytes and where it starts in them, its first value *)
let[@inline] vbytes b j =
  let d = b.o_vdir + (16 * j) in
  let o0 = i64 b d in
  let bo = b.o_vdata + o0 and n = i64 b (d + 16) - o0 in
  let f = frame b bo and i = bo land Pages.mask in
  if i + n <= Pages.size then f, i else assemble b bo n, 0

let[@inline] cvbytes b j =
  let d = b.o_vdir + (16 * j) in
  let o0 = ci64 b d in
  let bo = b.o_vdata + o0 and n = ci64 b (d + 16) - o0 in
  let f = framec b bo and i = bo land Pages.mask in
  if i + n <= Pages.size then f, i else cassemble b bo n, 0

(* the value of row k of a row block (its bytes at i, its first value) *)
let[@inline] bval f i first k =
  let wv = g8 f i in
  if g8 f (i + 1) = 0 then first + Pack.get f (((i + 8) lsl 3) + (k * wv)) wv
  else first + Pack.get f (((i + 8) lsl 3) + (k * wv) + 1) (wv - 1)

(* the value of row k of the row block j *)
let rval b j k = let f, i = vbytes b j in bval f i (i64 b (b.o_vdir + (16 * j) + 8)) k

(* the value of row r of p (p0 <= r < p1) *)
let pvalue b p r = let d = r - poff b p in rval b (i64 b (b.o_pblk + (8 * p)) + (d lsr 7)) (d land 127)
let rec base_pvalue b p r = match pvalue b p r with x -> ended x | exception Miss k -> fault b k; base_pvalue b p r

(* the rows of p before the first one whose value is >= w (w < vlo: none; w past the range: all) *)
let lower b p w =
  let p0 = poff b p and p1 = poff b (p + 1) in
  if p0 = p1 then p0
  else begin
    let x = b.o_pidx + (32 * p) in
    let w0 = i64 b (x + 8) in
    if w0 >= 0 then begin
      let vlo = i64 b x and words = i64 b (x + 16) in
      if w <= vlo then p0
      else
        let d = w - vlo in
        if d < 0 || d lsr 5 >= words - 1 then p1
        else
          let word = i64 b (b.o_vrank + ((w0 + (d lsr 5)) lsl 3)) in
          let q = (word lsr 32) + popcount (word land ((1 lsl (d land 31)) - 1)) in
          p0 + mono b b.o_vmh b.o_vmb ((i64 b (x + 24) lsl 7) + q)
    end
    else begin
      (* the first block whose first value is >= w; the rows before it in the block before *)
      let j0 = i64 b (b.o_pblk + (8 * p)) and j1 = i64 b (b.o_pblk + (8 * (p + 1))) in
      let lo = ref j0 and hi = ref j1 in
      while !lo < !hi do
        let mid = (!lo + !hi) lsr 1 in
        if i64 b (b.o_vdir + (16 * mid) + 8) < w then lo := mid + 1 else hi := mid
      done;
      if !lo = j0 then p0
      else begin
        let j = !lo - 1 in
        let r0 = p0 + ((j - j0) lsl 7) in
        let rows = min tb (p1 - r0) in
        let f, i = vbytes b j and first = i64 b (b.o_vdir + (16 * j) + 8) in
        let lo = ref 0 and hi = ref rows in
        while !lo < !hi do
          let mid = (!lo + !hi) lsr 1 in
          if bval f i first mid < w then lo := mid + 1 else hi := mid
        done;
        r0 + !lo
      end
    end
  end

let rec base_lower b p w = match lower b p w with r -> ended r | exception Miss k -> fault b k; base_lower b p w

(* the rows of (p, w) *)
let count_av b p w =
  if p < 0 || p >= b.np then 0
  else begin
    let x = b.o_pidx + (32 * p) in
    let w0 = i64 b (x + 8) in
    if w0 >= 0 then begin
      let vlo = i64 b x and words = i64 b (x + 16) in
      let d = w - vlo in
      if w < vlo || d < 0 || d lsr 5 >= words - 1 then 0
      else
        let word = i64 b (b.o_vrank + ((w0 + (d lsr 5)) lsl 3)) in
        let i = d land 31 in
        if (word lsr i) land 1 = 0 then 0
        else
          let q = (word lsr 32) + popcount (word land ((1 lsl i) - 1)) and q0 = i64 b (x + 24) lsl 7 in
          mono b b.o_vmh b.o_vmb (q0 + q + 1) - mono b b.o_vmh b.o_vmb (q0 + q)
    end
    else
      let lo = lower b p w in
      let hi = if w = max_int then poff b (p + 1) else lower b p (w + 1) in
      hi - lo
  end

let rec base_count_av b p w =
  if b.n = 0 then 0 else match count_av b p w with r -> ended r | exception Miss k -> fault b k; base_count_av b p w

(* rows r0 .. r1-1 of p: f thing value derived, a block's bytes read once *)
let scan b p r0 r1 fn =
  if r0 < r1 then begin
    let p0 = cpoff b p and rows = cpoff b (p + 1) - cpoff b p and j0 = ci64 b (b.o_pblk + (8 * p)) in
    let r = ref r0 in
    while !r < r1 do
      let j = j0 + ((!r - p0) lsr 7) and k0 = (!r - p0) land 127 in
      let brows = min tb (rows - ((j - j0) lsl 7)) in
      let k1 = min brows (k0 + (r1 - !r)) in
      let first = ci64 b (b.o_vdir + (16 * j) + 8) in
      let f, i = cvbytes b j in
      let wv = g8 f i and fl = g8 f (i + 1) and wt = g8 f (i + 2) and tl = g32 f (i + 4) in
      let va = (i + 8) lsl 3 in
      let ta = (i + 8 + pbytes brows wv) lsl 3 in
      let value k = if fl = 0 then first + Pack.get f (va + (k * wv)) wv else first + Pack.get f (va + (k * wv) + 1) (wv - 1) in
      if g8 f (i + 3) = 0 then
        for k = k0 to k1 - 1 do fn (tl + Pack.get f (ta + (k * wt)) wt) (value k) (fl <> 0 && Pack.get f (va + (k * wv)) 1 = 1) done
      else begin
        (* things by gaps: a row's thing is the one before plus 1 plus its field when it has the same value, the
           least plus its field otherwise; decoded from the block's first row *)
        let t = ref 0 and pw = ref 0 in
        for k = 0 to k1 - 1 do
          let w = value k and x = Pack.get f (ta + (k * wt)) wt in
          t := if k > 0 && w = !pw then !t + 1 + x else tl + x;
          pw := w;
          if k >= k0 then fn !t w (fl <> 0 && Pack.get f (va + (k * wv)) 1 = 1)
        done
      end;
      r := !r + (k1 - k0)
    done
  end

let base_iter_av b p w fn =
  if p >= 0 && p < b.np && b.n > 0 then begin
    let lo = base_lower b p w in
    let hi = lo + base_count_av b p w in
    scan b p lo hi (fun e _ _ -> fn e)
  end

let base_iter_range b p lo hi fn =
  if p >= 0 && p < b.np && b.n > 0 && lo <= hi then begin
    let r0 = base_lower b p lo in
    let r1 = if hi = max_int then cpoff b (p + 1) else base_lower b p (hi + 1) in
    scan b p r0 r1 (fun e w _ -> fn e w)
  end

let base_iter_p b p fn = if p >= 0 && p < b.np && b.n > 0 then scan b p (cpoff b p) (cpoff b (p + 1)) (fun e w _ -> fn e w)

(* every row of p, with its flag: for the merge *)
let base_iter_pf b p fn = if p >= 0 && p < b.np && b.n > 0 then scan b p (cpoff b p) (cpoff b (p + 1)) fn

let count_range b p lo hi =
  if p < 0 || p >= b.np || lo > hi then 0
  else (if hi = max_int then poff b (p + 1) else lower b p (hi + 1)) - lower b p lo

let rec base_count_range b p lo hi =
  if b.n = 0 then 0
  else match count_range b p lo hi with r -> ended r | exception Miss k -> fault b k; base_count_range b p lo hi

let base_count_p b p = if p >= 0 && p < b.np && b.n > 0 then cpoff b (p + 1) - cpoff b p else 0
let base_pdist b p = if p >= 0 && p < b.np && b.n > 0 then safe pdist b p else 0

(* ---- The dictionary ---- *)

(* The hash of a text, the slot it starts its probe at in a run's table (low bits): 7 bytes at a time
   (little-endian, the last ones padded with zeros), each mixed in by a multiplication, in 63-bit arithmetic
   (OCaml's ints: modulo 2^63), then a final mix; the constant is the multiplier of xorshift64* (Vigna 2016). *)
let hash_k = 0x2545F4914F6CDD1D

let hash (s : string) =
  let n = String.length s in
  let h = ref (n * hash_k) and i = ref 0 in
  while !i < n do
    let g =
      if !i + 8 <= n then Int64.to_int (String.get_int64_le s !i) land 0xFFFFFFFFFFFFFF
      else begin
        let g = ref 0 in
        for j = min n (!i + 7) - 1 downto !i do g := (!g lsl 8) lor Char.code (String.unsafe_get s j) done;
        !g
      end
    in
    h := (!h lxor g) * hash_k;
    i := !i + 7
  done;
  let h = !h lxor (!h lsr 32) in
  let h = h * hash_k in
  h lxor (h lsr 29)

let[@inline] soff b i = mono b b.o_smh b.o_smb i

let text_r b i =
  let lo = b.o_sblob + soff b i in
  let n = (b.o_sblob + soff b (i + 1)) - lo in
  if (lo land Pages.mask) + n <= Pages.size then Bytes.sub_string (frame b lo) (lo land Pages.mask) n
  else String.init n (fun k -> Char.unsafe_chr (byte b (lo + k)))

let rec base_text b i = match text_r b i with r -> ended r | exception Miss k -> fault b k; base_text b i

(* is s the part's text i *)
let eq_r b s i =
  let lo = b.o_sblob + soff b i in
  let len = (b.o_sblob + soff b (i + 1)) - lo in
  let n = String.length s in
  n = len
  &&
  if (lo land Pages.mask) + len <= Pages.size then begin
    (* the text in one page: compared in place *)
    let p = frame b lo and at = lo land Pages.mask in
    let k = ref 0 in
    while !k < n && String.unsafe_get s !k = Bytes.unsafe_get p (at + !k) do incr k done;
    !k = n
  end
  else begin
    let k = ref 0 in
    while !k < n && Char.code (String.unsafe_get s !k) = byte b (lo + !k) do incr k done;
    !k = n
  end

(* the hash table: open addressing with linear probing (Knuth, TAOCP vol. 3, 6.4), at most half full *)
let find_text_r b s h =
  let m = (1 lsl b.hbits) - 1 in
  let i = ref (h land m) and r = ref (-2) in
  while !r = -2 do
    let x = u32 b (b.o_shash + (4 * !i)) in
    if x = 0 then r := -1 else if eq_r b s (x - 1) then r := x - 1 else i := (!i + 1) land m
  done;
  !r

let rec base_find_text b s h =
  if b.ns = 0 then -1 else match find_text_r b s h with r -> ended r | exception Miss k -> fault b k; base_find_text b s h

(* ---- Dictionary, delta, views ---- *)

module IM = Map.Make (Int)
module SM = Map.Make (String)

module PW = Map.Make (struct
  type t = int * int

  let compare ((p : int), (w : int)) (p', w') = if p <> p' then compare p p' else compare w w'
end)

type chunks = { c0 : int; mutable arr : string array array; mutable count : int }

let chunk_bits = 12

type dict = { chunks : chunks; dcount : int; smap : int SM.t; extra : string IM.t; dnext : int }

(* An entry is a difference from the runs' state, as a small int: bit 0, the fact is in the view; bit 1, it is only
   derived there; bit 2, it is in the runs; bit 3, it is only derived there. So 1 (or 3, derived) is a fact the runs
   lack, 4 (or 12) a fact of theirs retracted, 5, 7, 13 a fact of theirs whose flag changed. Beside each map, its net
   count (facts added minus facts retracted), so that every count is exact. *)
type tdelta = { tf : int PW.t;  (* (property, value) -> entry *) tn : int IM.t  (* property -> net count *) }
type vdelta = { vn : int; vm : int IM.t  (* thing -> entry *) }

let[@inline] present st = st land 1 <> 0
type pdelta = { pn : int; pk : int  (* values in pm *); pm : vdelta IM.t  (* value -> its things *) }

type delta = {
  de : tdelta IM.t;  (* by thing *)
  dav : pdelta IM.t;  (* by property, then value *)
  dn : int;  (* changes made: what a merge folds in *)
  dnet : int;  (* net count of facts *)
}

let empty_delta = { de = IM.empty; dav = IM.empty; dn = 0; dnet = 0 }

type touched = { mutable bits : Bytes.t }

type view = {
  runs : run array;  (* newest first *)
  delta : delta;
  touched : touched;  (* the writer's: things that may have a delta entry; bits are only ever set *)
  ftouched : Bytes.t;  (* a fork's own, or empty *)
  dict : dict;
  schema : Schema.t;
  group : int;  (* the last group applied *)
  next_e : int;  (* the next thing id *)
  writer : bool;  (* only the writer's views append to the shared dictionary *)
}

let new_chunks c0 = { c0; arr = [||]; count = c0 }

(* the id after the newest run's texts *)
let texts_end runs = if Array.length runs = 0 then 0 else runs.(0).s0 + runs.(0).a.ns

let of_runs ?(schema = Schema.initial) ~group ~next_e runs =
  let c0 = texts_end runs in
  { runs; delta = empty_delta; touched = { bits = Bytes.make 64 '\000' }; ftouched = Bytes.empty;
    dict = { chunks = new_chunks c0; dcount = c0; smap = SM.empty; extra = IM.empty; dnext = c0 };
    schema; group; next_e; writer = true }

let empty () = of_runs ~group:0 ~next_e:Schema.first_thing [||]

let[@inline] bit (b : Bytes.t) e =
  let i = e lsr 3 in
  i < Bytes.length b && Char.code (Bytes.unsafe_get b i) land (1 lsl (e land 7)) <> 0

let set_bit (b : Bytes.t) e =
  let i = e lsr 3 in
  Bytes.unsafe_set b i (Char.unsafe_chr (Char.code (Bytes.unsafe_get b i) lor (1 lsl (e land 7))))

let grown (b : Bytes.t) e =
  let need = (e lsr 3) + 1 in
  if need <= Bytes.length b then b
  else begin
    let nb = Bytes.make (max need (2 * Bytes.length b)) '\000' in
    Bytes.blit b 0 nb 0 (Bytes.length b);
    nb
  end

let[@inline] is_touched v e = bit v.touched.bits e || (Bytes.length v.ftouched > 0 && bit v.ftouched e)

let touch v e =
  if v.writer then begin
    let b = grown v.touched.bits e in
    if b != v.touched.bits then v.touched.bits <- b;
    set_bit b e;
    v
  end
  else begin
    let b = grown v.ftouched e in
    set_bit b e;
    if b == v.ftouched then v else { v with ftouched = b }
  end

let text v i =
  if i >= v.dict.chunks.c0 then
    if i < v.dict.dcount then
      let k = i - v.dict.chunks.c0 in
      v.dict.chunks.arr.(k lsr chunk_bits).(k land ((1 lsl chunk_bits) - 1))
    else IM.find i v.dict.extra
  else begin
    (* the run whose texts start at or before i: runs are newest first, their texts in decreasing ranges *)
    let j = ref 0 in
    while v.runs.(!j).s0 > i do incr j done;
    let r = v.runs.(!j) in
    base_text r.a (i - r.s0)
  end

let find_text v s =
  match SM.find_opt s v.dict.smap with
  | Some i -> Some i
  | None ->
    let rs = v.runs in
    if Array.length rs = 0 then None
    else begin
      (* the hash once, a probe of each run's table *)
      let h = hash s in
      let r = ref (-1) and j = ref 0 in
      while !r < 0 && !j < Array.length rs do
        let l = base_find_text rs.(!j).a s h in
        if l >= 0 then r := rs.(!j).s0 + l;
        incr j
      done;
      if !r < 0 then None else Some !r
    end

let intern v s =
  match find_text v s with
  | Some i -> v, i
  | None ->
    let d = v.dict in
    if v.writer then begin
      let c = d.chunks in
      (* texts past this view's count were interned by a group that failed: nobody holds their ids *)
      if c.count > d.dcount then c.count <- d.dcount;
      let k = c.count - c.c0 in
      let ci = k lsr chunk_bits in
      if ci >= Array.length c.arr then begin
        let a = Array.make (max 4 (2 * Array.length c.arr)) [||] in
        Array.blit c.arr 0 a 0 (Array.length c.arr);
        c.arr <- a
      end;
      if Array.length c.arr.(ci) = 0 then c.arr.(ci) <- Array.make (1 lsl chunk_bits) "";
      c.arr.(ci).(k land ((1 lsl chunk_bits) - 1)) <- s;
      let i = c.count in
      c.count <- i + 1;
      { v with dict = { d with dcount = i + 1; smap = SM.add s i d.smap; dnext = i + 1 } }, i
    end
    else
      let i = d.dnext in
      { v with dict = { d with smap = SM.add s i d.smap; extra = IM.add i s d.extra; dnext = i + 1 } }, i

(* The texts a large group adds: their ids, consecutive from the first returned, as [intern] would give them one
   after the other, but without their entries in the delta's map (the merge of the group, which follows at once, puts
   every text of the view in its run's hash table), and one new view for all. The view is for that merge. *)
let add_texts v (ss : string array) =
  let d = v.dict and n = Array.length ss in
  if v.writer then begin
    let c = d.chunks in
    if c.count > d.dcount then c.count <- d.dcount;
    let first = c.count in
    Array.iter
      (fun s ->
        let k = c.count - c.c0 in
        let ci = k lsr chunk_bits in
        if ci >= Array.length c.arr then begin
          let a = Array.make (max 4 (2 * Array.length c.arr)) [||] in
          Array.blit c.arr 0 a 0 (Array.length c.arr);
          c.arr <- a
        end;
        if Array.length c.arr.(ci) = 0 then c.arr.(ci) <- Array.make (1 lsl chunk_bits) "";
        c.arr.(ci).(k land ((1 lsl chunk_bits) - 1)) <- s;
        c.count <- c.count + 1)
      ss;
    { v with dict = { d with dcount = first + n; dnext = first + n } }, first
  end
  else begin
    let first = d.dnext and extra = ref d.extra in
    Array.iteri (fun k s -> extra := IM.add (first + k) s !extra) ss;
    { v with dict = { d with extra = !extra; dnext = first + n } }, first
  end

let float_key f = let b = Bytes.create 8 in Bytes.set_int64_le b 0 (Int64.bits_of_float f); Bytes.unsafe_to_string b

(* A value as an index word, for reading: None when it cannot be in the view (an unknown text). *)
let word v (x : Value.t) =
  match x with
  | Int n | Date n | Money n | Link n -> Some n
  | Bool b -> Some (if b then 1 else 0)
  | Text s -> find_text v s
  | Float f -> find_text v (float_key f)

let word_intern v (x : Value.t) =
  match x with
  | Int n | Date n | Money n | Link n -> v, n
  | Bool b -> v, if b then 1 else 0
  | Text s -> intern v s
  | Float f -> intern v (float_key f)

let value v (ty : Value.typ) w : Value.t =
  match ty with
  | Tint -> Int w
  | Tdate -> Date w
  | Tmoney _ -> Money w
  | Tlink -> Link w
  | Tbool -> Bool (w <> 0)
  | Ttext -> Text (text v w)
  | Tfloat -> Float (Int64.float_of_bits (String.get_int64_le (text v w) 0))

(* ---- The runs and the delta: what a reader sees ----
   One run alone (a base just merged, or every database that is not being written) reads as before, with no check.
   With several, a row of an older run is shown only if no newer run has an entry for the same fact (an entry there
   decides: it added it, and that run shows it, or it retracted it); the rank tables tell in one bit which runs hold
   a thing at all, so the check costs a few bit tests unless a newer run holds the same thing. *)

let thing_delta v e = if is_touched v e then IM.find_opt e v.delta.de else None

(* does a part hold rows of property p at all (two offsets, on a page every lookup of p reads) *)
let[@inline] has_p (b : base) p = b.n > 0 && p >= 0 && p < b.np && cpoff b (p + 1) > cpoff b p

(* the runs holding facts of thing e for property p, as bits: run j is bit j *)
let holders_p v e p =
  let rs = v.runs and m = ref 0 in
  for j = 0 to Array.length rs - 1 do
    let r = rs.(j) in
    if (has_p r.a p && base_has r.a e) || (has_p r.t p && base_has r.t e) then m := !m lor (1 lsl j)
  done;
  !m

(* the runs holding thing e, as bits: run j is bit j *)
let holders v e =
  let rs = v.runs and m = ref 0 in
  for j = 0 to Array.length rs - 1 do
    let r = rs.(j) in
    if base_has r.a e || base_has r.t e then m := !m lor (1 lsl j)
  done;
  !m

(* an entry for (e p w) in a run newer than j (h: the holders of e); loops, not closures: these run per row *)
let newer v h j e p w =
  h land ((1 lsl j) - 1) <> 0
  && begin
    let found = ref false and i = ref 0 in
    while (not !found) && !i < j do
      let r = v.runs.(!i) in
      (* a run with no row of p at all says no without a lookup by thing *)
      if (h lsr !i) land 1 = 1
         && ((base_count_p r.a p > 0 && base_mem r.a e p w) || (base_count_p r.t p > 0 && base_mem r.t e p w))
      then found := true;
      incr i
    done;
    !found
  end

(* the state of (e p w) in the runs, the delta aside: 0 absent, 1 asserted, 2 only derived; the newest run with an
   entry decides (a run that changed a fact's flag holds a retraction and an addition of it: the addition decides) *)
let[@inline never] runs_state v e p w =
  let rs = v.runs in
  let n = Array.length rs in
  if n = 1 then base_state rs.(0).a e p w
  else begin
    let r = ref (-1) and j = ref 0 in
    while !r < 0 && !j < n do
      let x = rs.(!j) in
      if has_p x.a p then (let s = base_state x.a e p w in if s > 0 then r := s);
      if !r < 0 && has_p x.t p && base_mem x.t e p w then r := 0;
      incr j
    done;
    max 0 !r
  end

(* is (e p w) in the state of the runs (the delta aside): the newest run with an entry decides *)
let runs_mem v e p w =
  let rs = v.runs in
  let n = Array.length rs in
  if n = 1 then base_mem rs.(0).a e p w
  else begin
    let r = ref 0 and j = ref 0 in
    while !r = 0 && !j < n do
      let x = rs.(!j) in
      if has_p x.a p && base_mem x.a e p w then r := 1 else if has_p x.t p && base_mem x.t e p w then r := 2;
      incr j
    done;
    !r = 1
  end

(* the delta's facts of thing e for property p, in value order *)
let iter_delta_ep (td : tdelta) p f =
  let rec go s = match s () with Seq.Cons (((p', w), st), s') when p' = p -> f w st; go s' | _ -> () in
  go (PW.to_seq_from (p, min_int) td.tf)

(* the one run of h when it has one bit, else -1 *)
let single h = if h <> 0 && h land (h - 1) = 0 then (let j = ref 0 in while (h lsr !j) land 1 = 0 do incr j done; !j) else -1

let iter_values v e p f =
  let rs = v.runs and td = thing_delta v e in
  if Option.is_none td && Array.length rs = 1 then base_iter_ea rs.(0).a e p f
  else begin
    (* only the runs with facts of p for e matter: a newer run with other facts of e shadows none of these *)
    let h = holders_p v e p in
    let one = single h in
    if Option.is_none td && one >= 0 then base_iter_ea rs.(one).a e p f
    else begin
      for j = 0 to Array.length rs - 1 do
        if (h lsr j) land 1 = 1 then
          base_iter_ea rs.(j).a e p (fun w ->
              if (match td with Some td -> not (PW.mem (p, w) td.tf) | None -> true) && not (newer v h j e p w) then f w)
      done;
      Option.iter (fun td -> iter_delta_ep td p (fun w st -> if present st then f w)) td
    end
  end

(* every fact of e, in (property, value) order *)
let iter_facts v e f =
  let rs = v.runs and td = thing_delta v e in
  if Option.is_none td && Array.length rs = 1 then base_iter_e rs.(0).a e f
  else begin
    let h = holders v e in
    let one = single h in
    if Option.is_none td && one >= 0 then base_iter_e rs.(one).a e f
    else if Option.is_some td || h <> 0 then begin
      let l = ref [] in
      for j = 0 to Array.length rs - 1 do
        if (h lsr j) land 1 = 1 then
          base_iter_e rs.(j).a e (fun p w ->
              if (match td with Some td -> not (PW.mem (p, w) td.tf) | None -> true) && not (newer v h j e p w) then
                l := (p, w) :: !l)
      done;
      Option.iter (fun td -> PW.iter (fun pw st -> if present st then l := pw :: !l) td.tf) td;
      List.iter (fun (p, w) -> f p w) (List.sort compare !l)
    end
  end

let delta_av v p w = match IM.find_opt p v.delta.dav with None -> None | Some pd -> IM.find_opt w pd.pm

(* a row (e p w) of run j, older runs and the delta aside: shown? *)
let[@inline] shown v j e p w = j = 0 || not (newer v (holders v e) j e p w)

let iter_things v p w f =
  let rs = v.runs in
  match delta_av v p w with
  | None when Array.length rs = 1 -> base_iter_av rs.(0).a p w f
  | vd ->
    for j = 0 to Array.length rs - 1 do
      base_iter_av rs.(j).a p w (fun e ->
          if (match vd with Some vd -> not (IM.mem e vd.vm) | None -> true) && shown v j e p w then f e)
    done;
    Option.iter (fun vd -> IM.iter (fun e st -> if present st then f e) vd.vm) vd

let iter_prop v p f =
  let rs = v.runs in
  match IM.find_opt p v.delta.dav with
  | None when Array.length rs = 1 -> base_iter_p rs.(0).a p f
  | pd ->
    for j = 0 to Array.length rs - 1 do
      base_iter_p rs.(j).a p (fun e w ->
          let in_delta = match pd with
            | Some pd -> (match IM.find_opt w pd.pm with Some vd -> IM.mem e vd.vm | None -> false)
            | None -> false
          in
          if (not in_delta) && shown v j e p w then f e w)
    done;
    Option.iter (fun pd -> IM.iter (fun w vd -> IM.iter (fun e st -> if present st then f e w) vd.vm) pd.pm) pd

(* the facts of p with lo <= value word <= hi (an order on values for the inline types) *)
let iter_range v p lo hi f =
  let rs = v.runs in
  match IM.find_opt p v.delta.dav with
  | None when Array.length rs = 1 -> base_iter_range rs.(0).a p lo hi f
  | pd ->
    for j = 0 to Array.length rs - 1 do
      base_iter_range rs.(j).a p lo hi (fun e w ->
          let in_delta = match pd with
            | Some pd -> (match IM.find_opt w pd.pm with Some vd -> IM.mem e vd.vm | None -> false)
            | None -> false
          in
          if (not in_delta) && shown v j e p w then f e w)
    done;
    match pd with
    | None -> ()
    | Some pd ->
      let rec go s =
        match s () with
        | Seq.Cons ((w, vd), s') when w <= hi -> IM.iter (fun e st -> if present st then f e w) vd.vm; go s'
        | _ -> ()
      in
      if lo <= hi then go (IM.to_seq_from lo pd.pm)

let mem v e p w =
  match thing_delta v e with
  | Some td -> (match PW.find_opt (p, w) td.tf with Some st -> present st | None -> runs_mem v e p w)
  | None -> runs_mem v e p w

(* the state of (e p w) in the view: 0 absent, 1 asserted, 2 only derived *)
let[@inline] state_of_entry st = if st land 1 = 0 then 0 else if st land 2 = 0 then 1 else 2

let[@inline never] state v e p w =
  match thing_delta v e with
  | Some td -> (match PW.find_opt (p, w) td.tf with Some st -> state_of_entry st | None -> runs_state v e p w)
  | None -> runs_state v e p w

(* exact counts: each run's rows minus its retractions, and the delta's net counts *)
let count_values v e p =
  let rs = v.runs in
  let n =
    if Array.length rs = 1 then base_count_ea rs.(0).a e p
    else begin
      let n = ref 0 in
      for j = 0 to Array.length rs - 1 do
        let r = rs.(j) in
        if has_p r.a p then n := !n + base_count_ea r.a e p;
        if has_p r.t p then n := !n - base_count_ea r.t e p
      done;
      !n
    end
  in
  n + match thing_delta v e with Some td -> Option.value (IM.find_opt p td.tn) ~default:0 | None -> 0

let has_value v e p =
  if Array.length v.runs = 1 && not (is_touched v e) then base_has_p v.runs.(0).a e p else count_values v e p > 0

(* the value of (e, p) when e has exactly one in a view of one run that has no change of e: 1 and the value in
   cell.(0); 0: none; 2: otherwise (several values, or several runs, or a delta: read them by [iter_values]) *)
let value1 v e p cell = if Array.length v.runs = 1 && not (is_touched v e) then base_value1 v.runs.(0).a e p cell else 2

(* the things that hold p, each once: in thing order from the column of a view of one run with no change of p;
   otherwise as the facts come, seen once through a table *)
let iter_holders v p f =
  if Array.length v.runs = 1 && not (IM.mem p v.delta.dav) then base_iter_pt v.runs.(0).a p f
  else begin
    let seen = Hashtbl.create 256 in
    iter_prop v p (fun e _ -> if not (Hashtbl.mem seen e) then (Hashtbl.replace seen e (); f e))
  end

(* the values p takes, each once: in value order from the rows by value of a view of one run with no change of p, equal
   values side by side; otherwise seen once through a table *)
let iter_taken v p f =
  if Array.length v.runs = 1 && not (IM.mem p v.delta.dav) then begin
    let last = ref 0 and first = ref true in
    base_iter_p v.runs.(0).a p (fun _ w -> if !first || w <> !last then (first := false; last := w; f w))
  end
  else begin
    let seen = Hashtbl.create 256 in
    iter_prop v p (fun _ w -> if not (Hashtbl.mem seen w) then (Hashtbl.replace seen w (); f w))
  end

let count_things v p w =
  let rs = v.runs in
  let n =
    if Array.length rs = 1 then base_count_av rs.(0).a p w
    else begin
      let n = ref 0 in
      for j = 0 to Array.length rs - 1 do
        n := !n + base_count_av rs.(j).a p w - base_count_av rs.(j).t p w
      done;
      !n
    end
  in
  n + match delta_av v p w with Some vd -> vd.vn | None -> 0

let count_prop v p =
  let rs = v.runs and n = ref 0 in
  for j = 0 to Array.length rs - 1 do
    n := !n + base_count_p rs.(j).a p - base_count_p rs.(j).t p
  done;
  !n + match IM.find_opt p v.delta.dav with Some pd -> pd.pn | None -> 0

(* the facts of p in a range: exact on the runs, and the delta's part walked over the range only *)
let count_range v p lo hi =
  let rs = v.runs and n = ref 0 in
  for j = 0 to Array.length rs - 1 do
    n := !n + base_count_range rs.(j).a p lo hi - base_count_range rs.(j).t p lo hi
  done;
  (match IM.find_opt p v.delta.dav with
   | None -> ()
   | Some pd ->
     let rec go s = match s () with Seq.Cons ((w, vd), s') when w <= hi -> n := !n + vd.vn; go s' | _ -> () in
     if lo <= hi then go (IM.to_seq_from lo pd.pm));
  !n

(* an estimate for the planner: the distinct values of p, the runs' and the delta's (an upper bound) *)
let distinct v p =
  let rs = v.runs and n = ref 0 in
  for j = 0 to Array.length rs - 1 do n := !n + base_pdist rs.(j).a p done;
  max 1 (!n + match IM.find_opt p v.delta.dav with Some pd -> pd.pk | None -> 0)

(* ---- Changing a view ---- *)

(* an entry's net count against the runs: in the view, minus in the runs; -1 is no entry *)
let[@inline] net st = if st < 0 then 0 else (st land 1) - ((st lsr 2) land 1)

(* the entry of (e p w) becomes [st] (-1: none, the view agrees with the runs); [old], its entry now (-1: none) and
   [td] its thing's entries, found by the caller *)
let[@inline never] change v e p w ~td ~old st =
  let d = v.delta in
  let td = match td with Some td -> td | None -> { tf = PW.empty; tn = IM.empty } in
  let diff = net st - net old in
  let tf = if st < 0 then PW.remove (p, w) td.tf else PW.add (p, w) st td.tf in
  let tn =
    if diff = 0 then td.tn
    else
      let k = Option.value (IM.find_opt p td.tn) ~default:0 + diff in
      if k = 0 then IM.remove p td.tn else IM.add p k td.tn
  in
  let de = if PW.is_empty tf then IM.remove e d.de else IM.add e { tf; tn } d.de in
  let pd = match IM.find_opt p d.dav with Some pd -> pd | None -> { pn = 0; pk = 0; pm = IM.empty } in
  let vold = IM.find_opt w pd.pm in
  let vd = match vold with Some vd -> vd | None -> { vn = 0; vm = IM.empty } in
  let vm = if st < 0 then IM.remove e vd.vm else IM.add e st vd.vm in
  let pm, pk =
    if IM.is_empty vm then IM.remove w pd.pm, (if vold = None then pd.pk else pd.pk - 1)
    else IM.add w { vn = vd.vn + diff; vm } pd.pm, if vold = None then pd.pk + 1 else pd.pk
  in
  let dav = if IM.is_empty pm then IM.remove p d.dav else IM.add p { pn = pd.pn + diff; pk; pm } d.dav in
  { v with delta = { de; dav; dn = d.dn + 1; dnet = d.dnet + diff } }

(* the entry for a state (0 absent, 1 asserted, 2 only derived) over a state of the runs; -1 when they agree *)
let[@inline] entry s rs =
  if s = rs then -1 else (if s = 0 then 0 else if s = 1 then 1 else 3) lor (if rs = 0 then 0 else if rs = 1 then 4 else 12)

(* (e p w) takes state [s] (0 absent, 1 asserted, 2 only derived): the view (itself when nothing changes) and the
   state the fact had, from one lookup *)
let[@inline never] swap v e p w s =
  let td = thing_delta v e in
  let old = match td with Some td -> (match PW.find_opt (p, w) td.tf with Some st -> st | None -> -1) | None -> -1 in
  let cur, rs = if old >= 0 then state_of_entry old, state_of_entry (old lsr 2) else (let r = runs_state v e p w in r, r) in
  if cur = s then v, cur else change (touch v e) e p w ~td ~old (entry s rs), cur

let set v e p w s = fst (swap v e p w s)

(* Many facts set at once: [es], [ps], [ws], [ss] the things, properties, value words and states (0 absent,
   1 asserted, 2 only derived) of n facts, distinct, sorted by (thing, property, value). The same result as [set] one
   after the other, with one walk of the map by thing a thing and one of the map by property a property, where [set]
   walks both for each fact: the derived facts of a group come in clusters (a new thing's types, a class's members). *)
let[@inline never] set_sorted v (es : int array) (ps : int array) (ws : int array) (ss : int array) n =
  if n = 0 then v
  else begin
    let d = v.delta in
    let de = ref d.de and dn = ref d.dn and dnet = ref d.dnet in
    (* the entries changed, for the map by property: (p, w, e, entry, diff) *)
    let ch = ref [] and v = ref v in
    let i = ref 0 in
    while !i < n do
      let e = es.(!i) in
      let td0 = if is_touched !v e then IM.find_opt e !de else None in
      let tf = ref (match td0 with Some t -> t.tf | None -> PW.empty) and tn = ref (match td0 with Some t -> t.tn | None -> IM.empty) in
      let any = ref false in
      while !i < n && es.(!i) = e do
        let p = ps.(!i) and w = ws.(!i) and s = ss.(!i) in
        let old = match PW.find_opt (p, w) !tf with Some st -> st | None -> -1 in
        let cur, rs = if old >= 0 then state_of_entry old, state_of_entry (old lsr 2) else (let r = runs_state !v e p w in r, r) in
        if cur <> s then begin
          let st = entry s rs in
          let diff = net st - net old in
          tf := (if st < 0 then PW.remove (p, w) !tf else PW.add (p, w) st !tf);
          if diff <> 0 then begin
            let k = Option.value (IM.find_opt p !tn) ~default:0 + diff in
            tn := if k = 0 then IM.remove p !tn else IM.add p k !tn
          end;
          ch := (p, w, e, st, diff) :: !ch;
          incr dn;
          dnet := !dnet + diff;
          any := true
        end;
        incr i
      done;
      if !any then begin
        v := touch !v e;
        de := if PW.is_empty !tf then IM.remove e !de else IM.add e { tf = !tf; tn = !tn } !de
      end
    done;
    let ch = List.sort (fun (p, w, e, _, _) (p', w', e', _, _) -> compare (p, w, e) (p', w', e')) !ch in
    let dav = ref d.dav in
    let rec by_p = function
      | [] -> ()
      | (p, _, _, _, _) :: _ as l ->
        let pd = match IM.find_opt p !dav with Some pd -> pd | None -> { pn = 0; pk = 0; pm = IM.empty } in
        let pm = ref pd.pm and pk = ref pd.pk and pn = ref pd.pn in
        let rec by_w = function
          | (p', w, _, _, _) :: _ as l when p' = p ->
            let vold = IM.find_opt w !pm in
            let vd = match vold with Some vd -> vd | None -> { vn = 0; vm = IM.empty } in
            let vm = ref vd.vm and vn = ref vd.vn in
            let rec by_e = function
              | (p'', w', e, st, diff) :: r when p'' = p && w' = w ->
                vm := (if st < 0 then IM.remove e !vm else IM.add e st !vm);
                vn := !vn + diff;
                pn := !pn + diff;
                by_e r
              | r -> r
            in
            let rest = by_e l in
            if IM.is_empty !vm then (pm := IM.remove w !pm; if vold <> None then decr pk)
            else (pm := IM.add w { vn = !vn; vm = !vm } !pm; if vold = None then incr pk);
            by_w rest
          | r -> r
        in
        let rest = by_w l in
        dav := (if IM.is_empty !pm then IM.remove p !dav else IM.add p { pn = !pn; pk = !pk; pm = !pm } !dav);
        by_p rest
    in
    by_p ch;
    { !v with delta = { de = !de; dav = !dav; dn = !dn; dnet = !dnet } }
  end

(* Adds (asserted) or retracts (e p w); the view itself when nothing changes. *)
let apply v add e p w = set v e p w (if add then 1 else 0)

let max_thing v =
  Array.fold_left (fun m r -> max m (max r.a.ne r.t.ne - 1)) (v.next_e - 1) v.runs

let fork v =
  { v with writer = false; ftouched = (if Bytes.length v.ftouched = 0 then Bytes.empty else Bytes.copy v.ftouched) }

let facts v = Array.fold_left (fun n r -> n + r.a.n - r.t.n) v.delta.dnet v.runs

(* rows of a run: what the merge policy weighs *)
let run_rows r = r.a.n + r.t.n
