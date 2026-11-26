(* The facts. A view is a stack of runs, sorted and columnar, in pages (Pages: the bytes of a run's file, read
   through the cache), plus a delta of the recent changes in persistent maps, so that a view is a value: taking one
   is free, keeping one costs nothing, and a fork is a view with its own delta. The runs are the levels of an LSM tree
   (O'Neil et al. 1996), newest first: each holds the changes of a range of groups on top of the state of the runs
   below it, as facts it adds (part a) and facts of the runs below it retracts (part t, empty at the bottom); a fact
   is in a view when the newest entry for it (the delta's, or the newest run's that has one) adds it. A run's counts
   are net: a run adds only facts absent below it and retracts only facts present below it, so every count is a sum of
   exact counts.

   A part has four sections, coded with a frame of reference (Pack: a base and a bit width a block, Goldstein et
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
     columns      each property's rows (thing, value) apart, in thing order (the column order, below): every lookup
                  of a thing's property reads there
     text order   (run format 9) for each text property, the distinct texts of its rows in the part, in the order of
                  their bytes: a start for each property, then u32 text ids, so that the texts with a prefix are one
                  stretch of it, found by two binary searches (Prefix, and Sort on a text)

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
  o_tord : int;  (* (np + 1) u64: each text property's first entry; then u32 text ids, each property's in byte order *)
  len : int;  (* the end of the part's sections *)
  d0 : int;  (* every thing from d0 to ne - 1 is held: its slot is r0 + (e - d0), with no rank to read *)
  e_lo : int;  (* no thing below e_lo is held: a run of a load's new things says no for the others without a read *)
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

(* A provisional run (level 0): a change of the rules' derived facts, a run of their own on top of the others, under
   the delta (Engine). Its state is no group's: it is never named, every merge takes it, and the chain on the disk, the
   follow stream and recovery leave it out. *)
let provisional r = r.level = 0

(* the provisional runs of a view: its newest ones *)
let provisionals (rs : run array) =
  let k = ref 0 in
  while !k < Array.length rs && provisional rs.(!k) do incr k done;
  !k

(* the runs of the chain: those that are or will be named, without the provisional ones (always the newest) *)
let chain_runs (rs : run array) =
  let k = ref 0 in
  while !k < Array.length rs && provisional rs.(!k) do incr k done;
  if !k = 0 then rs else Array.sub rs !k (Array.length rs - !k)

(* min and max of ints: Stdlib's are polymorphic, a call to the C comparison each time *)
let[@inline] min (a : int) b = if a <= b then a else b
let[@inline] max (a : int) b = if a >= b then a else b

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
type rooms = { tdata : int; vdata : int; vmb : int; smb : int; crank : int; cdir : int; cdata : int; cmh : int; cmb : int; tord : int }

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
    crank = sum (fun _ -> crank_room ne); cdir = sum cdir_room; cdata = sum cdata_room; cmh = sum cmh_room; cmb = sum cmb_room;
    tord = (8 * (np + 1)) + (4 * n_cap) + 8 }

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
  let o_tord = sec r.tord in
  { pg; hot = pg.Pages.hot; n; ne; k; np; ns; sblob; hbits; o_erank; o_tdir; o_tdata; o_poff; o_pblk; o_pdist; o_pidx;
    o_vdir; o_vdata; o_vrank; o_vmh; o_vmb; o_smh; o_smb; o_sblob; o_shash; o_cp; o_crank; o_cdir; o_cdata; o_cmh; o_cmb;
    o_tord; len = !off; d0 = ne; r0 = k; e_lo = 0; cols = [||] }

(* the offsets of a part, as a run's header lists them, and back *)
let offsets b =
  [ b.o_erank; b.o_tdir; b.o_tdata; b.o_poff; b.o_pblk; b.o_pdist; b.o_pidx; b.o_vdir; b.o_vdata; b.o_vrank; b.o_vmh;
    b.o_vmb; b.o_smh; b.o_smb; b.o_sblob; b.o_shash; b.o_cp; b.o_crank; b.o_cdir; b.o_cdata; b.o_cmh; b.o_cmb; b.o_tord; b.len ]

let of_offsets ~pg ~n ~ne ~k ~np ~ns ~sblob ~hbits = function
  | [ o_erank; o_tdir; o_tdata; o_poff; o_pblk; o_pdist; o_pidx; o_vdir; o_vdata; o_vrank; o_vmh; o_vmb; o_smh; o_smb;
      o_sblob; o_shash; o_cp; o_crank; o_cdir; o_cdata; o_cmh; o_cmb; o_tord; len ] ->
    { pg; hot = pg.Pages.hot; n; ne; k; np; ns; sblob; hbits; o_erank; o_tdir; o_tdata; o_poff; o_pblk; o_pdist; o_pidx;
      o_vdir; o_vdata; o_vrank; o_vmh; o_vmb; o_smh; o_smb; o_sblob; o_shash; o_cp; o_crank; o_cdir; o_cdata; o_cmh; o_cmb;
      o_tord; len; d0 = ne; r0 = k; e_lo = 0; cols = [||] }
  | _ -> invalid_arg "Store.of_offsets"

let noffsets = 24

(* the hash table of ns texts: the least power of two of at least 2 ns slots (load at most 1/2) *)
let hbits_for ns = let b = ref 0 in while 1 lsl !b < 2 * ns do incr b done; !b

(* a part with nothing: every lookup answers at once, without a page *)
let nothing =
  layout ~at:0 ~n:0 ~ne:0 ~k:0 ~k_cap:0 ~np:0 ~ns:0 ~sblob:0 ~hbits:0 ~vb_cap:0 ~vwords:0 ~vm_blocks:0
    { tdata = 0; vdata = 0; vmb = 0; smb = 0; crank = 0; cdir = 0; cdata = 0; cmh = 0; cmb = 0; tord = 0 } ()

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
  else if e < b.e_lo then -1
  else rank (i64 b (b.o_erank + ((e lsr 5) lsl 3))) e

let[@inline] cslot b e =
  if e >= b.d0 then (if e < b.ne then b.r0 + (e - b.d0) else -1)
  else if e < b.e_lo then -1
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
    (* the first thing held: the rank words below it are empty *)
    let j = ref 0 and last = (b.ne - 1) lsr 5 in
    while !j <= last && word !j land 0xFFFFFFFF = 0 do incr j done;
    let e_lo = if !j > last then b.ne else (!j lsl 5) + (let bits = word !j land 0xFFFFFFFF in let i = ref 0 in while (bits lsr !i) land 1 = 0 do incr i done; !i) in
    { b with d0 = !d0; r0; e_lo = min e_lo !d0 }
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

(* the rows of the q-th thing of p: its first, and in cell.(0) its end; the two offsets of one Mono block read with
   one header *)
let[@inline] crows b p q (cell : int array) =
  let q0 = ce b p 3 in
  if q < q0 then (Array.unsafe_set cell 0 (q + 1); q)
  else begin
    let i = q - q0 and mh = ce b p 6 and mb = ce b p 7 in
    if (i + 1) land 127 = 0 then (Array.unsafe_set cell 0 (q0 + mono b mh mb (i + 1)); q0 + mono b mh mb i)
    else begin
      let h = mh + ((i lsr 7) lsl 4) in
      let x = i64 b (h + 8) in
      let w = x land 0xFF and base = i64 b h and at = mb + (x lsr 8) in
      let k = (i land 127) * w in
      Array.unsafe_set cell 0 (q0 + base + field b at (k + w) w);
      q0 + base + field b at k w
    end
  end

let[@inline] ccrows b p q (cell : int array) =
  let q0 = ce b p 3 in
  if q < q0 then (Array.unsafe_set cell 0 (q + 1); q)
  else begin
    let i = q - q0 and mh = ce b p 6 and mb = ce b p 7 in
    if (i + 1) land 127 = 0 then (Array.unsafe_set cell 0 (q0 + cmono b mh mb (i + 1)); q0 + cmono b mh mb i)
    else begin
      let h = mh + ((i lsr 7) lsl 4) in
      let x = ci64 b (h + 8) in
      let w = x land 0xFF and base = ci64 b h and at = mb + (x lsr 8) in
      let k = (i land 127) * w in
      Array.unsafe_set cell 0 (q0 + base + cfield b at (k + w) w);
      q0 + base + cfield b at k w
    end
  end

(* rows lo .. hi-1 of p, of thing e: a block's directory entry read once for its rows *)
let cloop b p e lo hi fn =
  let r = ref lo in
  while !r < hi do
    let j = !r lsr 7 in
    let d = ce b p 4 + (j lsl 4) in
    let h = ci64 b d in
    let base = ci64 b (d + 8) + (if (h lsr 9) land 1 = 0 then 0 else e) in
    let wv = h land 0xFF and fl = (h lsr 8) land 1 and at = ce b p 5 + (h lsr 16) in
    let stop = min hi ((j + 1) lsl 7) in
    for r' = !r to stop - 1 do fn (base + cfield b at (((r' land 127) * wv) + fl) (wv - fl)) done;
    r := stop
  done

let base_iter_ea b e p fn =
  if has_col b p then begin
    let q = ccthing b p e in
    if q >= 0 then begin
      let cell = [| 0 |] in
      let lo = ccrows b p q cell in
      cloop b p e lo cell.(0) fn
    end
  end

(* the same, with each row's state: 1 asserted, 2 only derived (the flag in its field) *)
let cloop_st b p e lo hi fn =
  let r = ref lo in
  while !r < hi do
    let j = !r lsr 7 in
    let d = ce b p 4 + (j lsl 4) in
    let h = ci64 b d in
    let base = ci64 b (d + 8) + (if (h lsr 9) land 1 = 0 then 0 else e) in
    let wv = h land 0xFF and fl = (h lsr 8) land 1 and at = ce b p 5 + (h lsr 16) in
    let stop = min hi ((j + 1) lsl 7) in
    for r' = !r to stop - 1 do
      let o = (r' land 127) * wv in
      fn (base + cfield b at (o + fl) (wv - fl)) (if fl = 1 && cfield b at o 1 = 1 then 2 else 1)
    done;
    r := stop
  done

let base_iter_ea_st b e p fn =
  if has_col b p then begin
    let q = ccthing b p e in
    if q >= 0 then begin
      let cell = [| 0 |] in
      let lo = ccrows b p q cell in
      cloop_st b p e lo cell.(0) fn
    end
  end

(* the rows of (e, p): their count, their first in cell.(1) *)
let range_ea b e p (cell : int array) =
  let q = cthing b p e in
  if q < 0 then 0 else (let lo = crows b p q cell in Array.unsafe_set cell 1 lo; Array.unsafe_get cell 0 - lo)

let rec base_range_ea b e p cell =
  if not (has_col b p) then 0 else match range_ea b e p cell with r -> ended r | exception Miss k -> fault b k; base_range_ea b e p cell

let count_ea b e p =
  let q = cthing b p e in
  if q < 0 then 0
  else if q < ce b p 3 then 1
  else begin
    let i = q - ce b p 3 and mh = ce b p 6 and mb = ce b p 7 in
    if (i + 1) land 127 = 0 then mono b mh mb (i + 1) - mono b mh mb i
    else begin
      let h = mh + ((i lsr 7) lsl 4) in
      let x = i64 b (h + 8) in
      let w = x land 0xFF and at = mb + (x lsr 8) in
      let k = (i land 127) * w in
      field b at (k + w) w - field b at k w
    end
  end

let rec base_count_ea b e p =
  if not (has_col b p) then 0 else match count_ea b e p with r -> ended r | exception Miss k -> fault b k; base_count_ea b e p

(* 0: no row of (e p w) in the part; 1: a row, asserted; 2: a row, only derived. A binary search among e's values
   down to 8, then a scan *)
let state_e b e p w =
  let q = cthing b p e in
  if q < 0 then 0
  else begin
    let cell = [| 0 |] in
    let lo = ref (crows b p q cell) in
    let stop = cell.(0) in
    let hi = ref stop in
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

(* the highest bit set of a 32-bit word that is not 0 *)
let top_bit x =
  let x = ref x and r = ref 0 in
  if !x lsr 16 <> 0 then (r := 16; x := !x lsr 16);
  if !x lsr 8 <> 0 then (r := !r + 8; x := !x lsr 8);
  if !x lsr 4 <> 0 then (r := !r + 4; x := !x lsr 4);
  if !x lsr 2 <> 0 then (r := !r + 2; x := !x lsr 2);
  if !x lsr 1 <> 0 then incr r;
  !r

(* The things of p in a part from thing e on, in the order of their ids (from e down with [desc]), e itself included:
   [next ()] gives the next one, -1 after the last. The column's rank table, a word of 32 things at a time from e's
   word: a seek in O(1), then a step a thing (a word without one of p's things, as another kind's, a step a word). *)
let base_holders b p ~desc e =
  if not (has_col b p) || ce b p 1 < 0 then fun () -> -1
  else begin
    let ra = ce b p 1 and tlo = ce b p 0 and words = ce b p 2 - 1 in
    let word j = ci64 b (ra + (j lsl 3)) land 0xFFFFFFFF in
    (* e - tlo, without wrapping for an e far below (min_int) *)
    let d = if e < tlo then -1 else e - tlo in
    let j = ref 0 and bits = ref 0 in
    if desc then begin
      if d < 0 then j := -1
      else if d lsr 5 >= words then (j := words - 1; if words > 0 then bits := word (words - 1))
      else (j := d lsr 5; bits := word !j land ((1 lsl ((d land 31) + 1)) - 1))
    end
    else if d < 0 then (if words > 0 then bits := word 0)
    else if d lsr 5 >= words then j := words
    else (j := d lsr 5; bits := word !j land lnot ((1 lsl (d land 31)) - 1));
    let rec next () =
      if !bits <> 0 then begin
        if desc then (let h = top_bit !bits in bits := !bits lxor (1 lsl h); tlo + (!j lsl 5) + h)
        else (let low = !bits land - !bits in bits := !bits lxor low; tlo + (!j lsl 5) + popcount (low - 1))
      end
      else if desc then (decr j; if !j < 0 then -1 else (bits := word !j; next ()))
      else (incr j; if !j >= words then -1 else (bits := word !j; next ()))
    in
    next
  end

(* the first row in a part's column of p of the first thing >= e (p's rows when there is none): the things below e
   from the rank table, then their rows from the offsets *)
let base_rows_below b p e =
  if not (has_col b p) || ce b p 1 < 0 then 0
  else begin
    let ra = ce b p 1 and tlo = ce b p 0 and words = ce b p 2 - 1 in
    let d = if e < tlo then 0 else e - tlo in
    let q =
      if d <= 0 then 0
      else if d lsr 5 >= words then ci64 b (ra + (words lsl 3)) lsr 32
      else (let w = ci64 b (ra + ((d lsr 5) lsl 3)) in (w lsr 32) + popcount (w land 0xFFFFFFFF land ((1 lsl (d land 31)) - 1)))
    in
    let q0 = ce b p 3 in
    if q <= q0 then q else q0 + cmono b (ce b p 6) (ce b p 7) (q - q0)
  end

(* the rows of p in a part whose thing is in [lo, hi] *)
let base_count_holders b p lo hi =
  if lo > hi then 0
  else (if hi = max_int then base_rows_below b p max_int else base_rows_below b p (hi + 1)) - base_rows_below b p lo

(* the value of (e, p) when e has exactly one: 1 and the value in cell.(0); 0: none; 2: several *)
let value1 b e p (cell : int array) =
  let q = cthing b p e in
  if q < 0 then 0
  else begin
    let lo = crows b p q cell in
    match Array.unsafe_get cell 0 - lo with
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

(* the rows of (p, w): their count, their first in cell.(1) (one rank and one Mono header with a value index) *)
let range_av b p w (cell : int array) =
  let p0 = poff b p in
  Array.unsafe_set cell 1 p0;
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
        else begin
          let q = (i64 b (x + 24) lsl 7) + (word lsr 32) + popcount (word land ((1 lsl i) - 1)) in
          let m0, m1 =
            if (q + 1) land 127 = 0 then mono b b.o_vmh b.o_vmb q, mono b b.o_vmh b.o_vmb (q + 1)
            else begin
              let h = b.o_vmh + ((q lsr 7) lsl 4) in
              let y = i64 b (h + 8) in
              let wd = y land 0xFF and base = i64 b h and at = b.o_vmb + (y lsr 8) in
              let k = (q land 127) * wd in
              base + field b at k wd, base + field b at (k + wd) wd
            end
          in
          Array.unsafe_set cell 1 (p0 + m0);
          m1 - m0
        end
    end
    else begin
      let lo = lower b p w in
      let hi = if w = max_int then poff b (p + 1) else lower b p (w + 1) in
      Array.unsafe_set cell 1 lo;
      hi - lo
    end
  end

let rec base_range_av b p w cell =
  if b.n = 0 || p < 0 || p >= b.np then (Array.unsafe_set cell 1 0; 0)
  else match range_av b p w cell with r -> ended r | exception Miss k -> fault b k; base_range_av b p w cell

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
           least plus its field otherwise; so a value's first row in the block needs no row before it, and the rows
           are decoded from the first row of row k0's value (a binary search: the values are sorted) *)
        let s =
          if k0 = 0 then 0
          else begin
            let w0 = value k0 and lo = ref 0 and hi = ref k0 in
            while !lo < !hi do let mid = (!lo + !hi) lsr 1 in if value mid < w0 then lo := mid + 1 else hi := mid done;
            !lo
          end
        in
        let t = ref 0 and pw = ref 0 in
        for k = s to k1 - 1 do
          let w = value k and x = Pack.get f (ta + (k * wt)) wt in
          t := if k > s && w = !pw then !t + 1 + x else tl + x;
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

(* the values p takes in a part, each once, in value order, read from its value index's rank words (a bit a value,
   no row decoded): what the rows by value give, one at a time and their copies skipped; false when p has no value
   index (its rows are read then) *)
let base_iter_indexed_values b p fn =
  if p < 0 || p >= b.np || b.n = 0 || cpoff b p = cpoff b (p + 1) then true
  else begin
    let x = b.o_pidx + (32 * p) in
    let w0 = ci64 b (x + 8) in
    if w0 < 0 then false
    else begin
      let vlo = ci64 b x and words = ci64 b (x + 16) in
      for j = 0 to words - 2 do
        let bits = ref (ci64 b (b.o_vrank + ((w0 + j) lsl 3)) land 0xFFFFFFFF) in
        let v0 = vlo + (j lsl 5) in
        while !bits <> 0 do
          let low = !bits land (- !bits) in
          fn (v0 + popcount (low - 1));
          bits := !bits lxor low
        done
      done;
      true
    end
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

(* Maps of ints: the balanced trees of Stdlib's Map.Make (Int), the same functions, written out (they follow
   OCaml 5.5's stdlib/map.ml: AVL trees whose two sides' heights differ by at most 2, persistent by path copying),
   with one more: [of_sorted], the tree of sorted bindings made in O(n), a node a binding. Map's own ways from sorted
   keys copy a path a key (adds, O(n log n)), or split and join by unions (O(n), about 65 words a binding where a node
   is 6): a cascade of 10,000 lines made two such maps a group. *)
module IM = struct
  type 'a t = Empty | Node of { l : 'a t; v : int; d : 'a; r : 'a t; h : int }

  let empty = Empty
  let is_empty = function Empty -> true | Node _ -> false
  let[@inline] height = function Empty -> 0 | Node { h; _ } -> h

  let create l x d r =
    let hl = height l and hr = height r in
    Node { l; v = x; d; r; h = (if hl >= hr then hl + 1 else hr + 1) }

  let singleton x d = Node { l = Empty; v = x; d; r = Empty; h = 1 }

  let bal l x d r =
    let hl = height l and hr = height r in
    if hl > hr + 2 then begin
      match l with
      | Empty -> invalid_arg "IM.bal"
      | Node { l = ll; v = lv; d = ld; r = lr; _ } ->
        if height ll >= height lr then create ll lv ld (create lr x d r)
        else begin
          match lr with
          | Empty -> invalid_arg "IM.bal"
          | Node { l = lrl; v = lrv; d = lrd; r = lrr; _ } -> create (create ll lv ld lrl) lrv lrd (create lrr x d r)
        end
    end
    else if hr > hl + 2 then begin
      match r with
      | Empty -> invalid_arg "IM.bal"
      | Node { l = rl; v = rv; d = rd; r = rr; _ } ->
        if height rr >= height rl then create (create l x d rl) rv rd rr
        else begin
          match rl with
          | Empty -> invalid_arg "IM.bal"
          | Node { l = rll; v = rlv; d = rld; r = rlr; _ } -> create (create l x d rll) rlv rld (create rlr rv rd rr)
        end
    end
    else Node { l; v = x; d; r; h = (if hl >= hr then hl + 1 else hr + 1) }

  let rec add (x : int) data = function
    | Empty -> Node { l = Empty; v = x; d = data; r = Empty; h = 1 }
    | Node { l; v; d; r; h } as m ->
      if x = v then (if d == data then m else Node { l; v = x; d = data; r; h })
      else if x < v then (let ll = add x data l in if l == ll then m else bal ll v d r)
      else (let rr = add x data r in if r == rr then m else bal l v d rr)

  let rec find (x : int) = function Empty -> raise Not_found | Node { l; v; d; r; _ } -> if x = v then d else find x (if x < v then l else r)
  let rec find_opt (x : int) = function Empty -> None | Node { l; v; d; r; _ } -> if x = v then Some d else find_opt x (if x < v then l else r)
  let rec mem (x : int) = function Empty -> false | Node { l; v; r; _ } -> x = v || mem x (if x < v then l else r)

  let rec min_binding = function Empty -> raise Not_found | Node { l = Empty; v; d; _ } -> v, d | Node { l; _ } -> min_binding l

  let rec remove_min_binding = function
    | Empty -> invalid_arg "IM.remove_min_elt"
    | Node { l = Empty; r; _ } -> r
    | Node { l; v; d; r; _ } -> bal (remove_min_binding l) v d r

  let merge t1 t2 =
    match t1, t2 with
    | Empty, t | t, Empty -> t
    | _ -> let x, d = min_binding t2 in bal t1 x d (remove_min_binding t2)

  let rec remove (x : int) = function
    | Empty -> Empty
    | Node { l; v; d; r; _ } as m ->
      if x = v then merge l r
      else if x < v then (let ll = remove x l in if l == ll then m else bal ll v d r)
      else (let rr = remove x r in if r == rr then m else bal l v d rr)

  let rec iter f = function Empty -> () | Node { l; v; d; r; _ } -> iter f l; f v d; iter f r
  let rec fold f m acc = match m with Empty -> acc | Node { l; v; d; r; _ } -> fold f r (f v d (fold f l acc))
  let rec cardinal = function Empty -> 0 | Node { l; r; _ } -> cardinal l + 1 + cardinal r
  let rec bindings_aux acc = function Empty -> acc | Node { l; v; d; r; _ } -> bindings_aux ((v, d) :: bindings_aux acc r) l
  let bindings m = bindings_aux [] m

  (* the binding of the greatest key whose [f] holds, [f] monotonically decreasing *)
  let rec find_last_aux v0 d0 f = function Empty -> Some (v0, d0) | Node { l; v; d; r; _ } -> if f v then find_last_aux v d f r else find_last_aux v0 d0 f l
  let rec find_last_opt f = function Empty -> None | Node { l; v; d; r; _ } -> if f v then find_last_aux v d f r else find_last_opt f l

  let rec add_min_binding k x = function Empty -> singleton k x | Node { l; v; d; r; _ } -> bal (add_min_binding k x l) v d r
  let rec add_max_binding k x = function Empty -> singleton k x | Node { l; v; d; r; _ } -> bal l v d (add_max_binding k x r)

  let rec join l v d r =
    match l, r with
    | Empty, _ -> add_min_binding v d r
    | _, Empty -> add_max_binding v d l
    | Node { l = ll; v = lv; d = ld; r = lr; h = lh }, Node { l = rl; v = rv; d = rd; r = rr; h = rh } ->
      if lh > rh + 2 then bal ll lv ld (join lr v d r) else if rh > lh + 2 then bal (join l v d rl) rv rd rr else create l v d r

  let concat t1 t2 =
    match t1, t2 with
    | Empty, t | t, Empty -> t
    | _ -> let x, d = min_binding t2 in join t1 x d (remove_min_binding t2)

  let concat_or_join t1 v d t2 = match d with Some d -> join t1 v d t2 | None -> concat t1 t2

  let rec split (x : int) = function
    | Empty -> Empty, None, Empty
    | Node { l; v; d; r; _ } ->
      if x = v then l, Some d, r
      else if x < v then (let ll, pres, rl = split x l in ll, pres, join rl v d r)
      else (let lr, pres, rr = split x r in join l v d lr, pres, rr)

  let rec union f s1 s2 =
    match s1, s2 with
    | Empty, s | s, Empty -> s
    | Node { l = l1; v = v1; d = d1; r = r1; h = h1 }, Node { l = l2; v = v2; d = d2; r = r2; h = h2 } ->
      if h1 >= h2 then begin
        let l2, d2, r2 = split v1 s2 in
        let l = union f l1 l2 and r = union f r1 r2 in
        match d2 with None -> join l v1 d1 r | Some d2 -> concat_or_join l v1 (f v1 d1 d2) r
      end
      else begin
        let l1, d1, r1 = split v2 s1 in
        let l = union f l1 l2 and r = union f r1 r2 in
        match d1 with None -> join l v2 d2 r | Some d1 -> concat_or_join l v2 (f v2 d1 d2) r
      end

  type 'a enumeration = End | More of int * 'a * 'a t * 'a enumeration

  let rec cons_enum m e = match m with Empty -> e | Node { l; v; d; r; _ } -> cons_enum l (More (v, d, r, e))
  let rec seq_of_enum_ c () = match c with End -> Seq.Nil | More (k, v, t, rest) -> Seq.Cons ((k, v), seq_of_enum_ (cons_enum t rest))
  let to_seq m = seq_of_enum_ (cons_enum m End)

  let to_seq_from (low : int) m =
    let rec aux low m c =
      match m with
      | Empty -> c
      | Node { l; v; d; r; _ } -> if v = low then More (v, d, r, c) else if v < low then aux low r c else aux low l (More (v, d, r, c))
    in
    seq_of_enum_ (aux low m End)

  (* the tree of the bindings ks.(lo .. hi-1), vs.(lo .. hi-1), the keys strictly increasing: in O(n), a node a
     binding, each node's two sides of heights that differ by at most 1 *)
  let rec of_sorted (ks : int array) (vs : 'a array) lo hi =
    if hi <= lo then Empty else (let mid = (lo + hi) lsr 1 in create (of_sorted ks vs lo mid) ks.(mid) vs.(mid) (of_sorted ks vs (mid + 1) hi))
end

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

(* A property's delta by value: value words to their things, a balanced tree as Map's (the heights of a node's two
   sides differ by at most 2; persistent by path copying: Driscoll, Sarnak, Sleator and Tarjan 1989), each node also
   holding the sums over its subtree of the net counts [vn] and of their additions (vn when positive): an
   order-statistic tree (Cormen, Leiserson, Rivest and Stein, Introduction to Algorithms, 3rd edition, chapter 14). So
   the facts of a range of values, and the value where a count of additions from a value is reached, are found in
   O(log n), where Map's walk of the range took a step a value: the reads of a day of sessions in the delta (the end
   of each, a value) walked every one of them. *)
module VM = struct
  type t = E | N of { l : t; k : int; d : vdelta; r : t; h : int; s : int; a : int }

  let empty = E
  let is_empty = function E -> true | N _ -> false
  let[@inline] height = function E -> 0 | N n -> n.h
  let[@inline] sum = function E -> 0 | N n -> n.s
  let[@inline] adds = function E -> 0 | N n -> n.a
  let[@inline] pos (d : vdelta) = if d.vn > 0 then d.vn else 0

  let create l k (d : vdelta) r =
    let hl = height l and hr = height r in
    N { l; k; d; r; h = (if hl >= hr then hl + 1 else hr + 1); s = sum l + d.vn + sum r; a = adds l + pos d + adds r }

  (* as Map's: the heights of the two sides differ by at most 2 *)
  let[@inline never] bal l k d r =
    let hl = height l and hr = height r in
    if hl > hr + 2 then
      match l with
      | N { l = ll; k = lk; d = ld; r = lr; _ } ->
        if height ll >= height lr then create ll lk ld (create lr k d r)
        else (
          match lr with
          | N { l = lrl; k = lrk; d = lrd; r = lrr; _ } -> create (create ll lk ld lrl) lrk lrd (create lrr k d r)
          | E -> invalid_arg "VM.bal")
      | E -> invalid_arg "VM.bal"
    else if hr > hl + 2 then
      match r with
      | N { l = rl; k = rk; d = rd; r = rr; _ } ->
        if height rr >= height rl then create (create l k d rl) rk rd rr
        else (
          match rl with
          | N { l = rll; k = rlk; d = rld; r = rlr; _ } -> create (create l k d rll) rlk rld (create rlr rk rd rr)
          | E -> invalid_arg "VM.bal")
      | E -> invalid_arg "VM.bal"
    else create l k d r

  let rec add k d = function
    | E -> create E k d E
    | N n -> if k = n.k then create n.l k d n.r else if k < n.k then bal (add k d n.l) n.k n.d n.r else bal n.l n.k n.d (add k d n.r)

  let rec find_opt k = function E -> None | N n -> if k = n.k then Some n.d else find_opt k (if k < n.k then n.l else n.r)

  let rec min_binding = function E -> raise Not_found | N { l = E; k; d; _ } -> (k, d) | N n -> min_binding n.l
  let rec max_binding = function E -> raise Not_found | N { r = E; k; d; _ } -> (k, d) | N n -> max_binding n.r
  let rec remove_min = function E -> invalid_arg "VM.remove_min" | N { l = E; r; _ } -> r | N n -> bal (remove_min n.l) n.k n.d n.r

  let rec remove k = function
    | E -> E
    | N n ->
      if k = n.k then (match n.l, n.r with E, t | t, E -> t | l, r -> let k', d' = min_binding r in bal l k' d' (remove_min r))
      else if k < n.k then bal (remove k n.l) n.k n.d n.r
      else bal n.l n.k n.d (remove k n.r)

  let rec iter f = function E -> () | N n -> iter f n.l; f n.k n.d; iter f n.r
  let rec fold f m acc = match m with E -> acc | N n -> fold f n.r (f n.k n.d (fold f n.l acc))

  (* the bindings with lo <= key <= hi, in order *)
  let rec iter_range lo hi f = function
    | E -> ()
    | N n ->
      if n.k > lo then iter_range lo hi f n.l;
      if n.k >= lo && n.k <= hi then f n.k n.d;
      if n.k < hi then iter_range lo hi f n.r

  (* the net counts of the keys >= lo, <= hi, and lo .. hi *)
  let rec sum_from lo = function E -> 0 | N n -> if n.k < lo then sum_from lo n.r else sum_from lo n.l + n.d.vn + sum n.r
  let rec sum_to hi = function E -> 0 | N n -> if n.k > hi then sum_to hi n.l else sum n.l + n.d.vn + sum_to hi n.r

  let rec sum_range lo hi = function
    | E -> 0
    | N n ->
      if n.k < lo then sum_range lo hi n.r
      else if n.k > hi then sum_range lo hi n.l
      else sum_from lo n.l + n.d.vn + sum_to hi n.r

  (* the additions of the keys below w, above w *)
  let rec adds_below w = function E -> 0 | N n -> if n.k < w then adds n.l + pos n.d + adds_below w n.r else adds_below w n.l
  let rec adds_above w = function E -> 0 | N n -> if n.k > w then adds n.r + pos n.d + adds_above w n.l else adds_above w n.r

  (* the least key whose additions from the least key up to it reach t (t >= 1); the greatest from the top down *)
  let rec reach_up t = function
    | E -> None
    | N n -> let la = adds n.l in if la >= t then reach_up t n.l else (let h = la + pos n.d in if h >= t then Some n.k else reach_up (t - h) n.r)

  let rec reach_down t = function
    | E -> None
    | N n -> let ra = adds n.r in if ra >= t then reach_down t n.r else (let h = ra + pos n.d in if h >= t then Some n.k else reach_down (t - h) n.l)

  (* the least x >= w whose keys w .. x add m facts or more (m >= 1); with [desc], the greatest x <= w whose keys
     x .. w do; None when there are fewer *)
  let nth w m ~desc t = if desc then reach_down (adds_above w t + m) t else reach_up (adds_below w t + m) t

  (* the tree of the bindings ks.(lo .. hi-1), ds.(lo .. hi-1), the keys strictly increasing: built in O(n), each
     node's two sides of heights that differ by at most 1 *)
  let rec of_sorted (ks : int array) (ds : vdelta array) lo hi =
    if hi <= lo then E else (let mid = (lo + hi) lsr 1 in create (of_sorted ks ds lo mid) ks.(mid) ds.(mid) (of_sorted ks ds (mid + 1) hi))
end

(* A stable sort of the indexes [o] by [key], least-significant digit first, 11 bits a pass (Knuth, volume 3, 5.2.5):
   false (nothing done) when the keys' range passes the ints *)
let radix_by (key : int -> int) (o : int array) =
  let n = Array.length o in
  let lo = ref max_int and hi = ref min_int in
  Array.iter (fun j -> let k = key j in if k < !lo then lo := k; if k > !hi then hi := k) o;
  if n = 0 || !hi - !lo < 0 then n = 0
  else begin
    let lo = !lo and range = !hi - !lo in
    let o' = Array.make n 0 and cnt = Array.make 2048 0 in
    let src = ref o and dst = ref o' and sh = ref 0 in
    while !sh < 62 && range lsr !sh > 0 do
      Array.fill cnt 0 2048 0;
      let a = !src and b = !dst and s = !sh in
      for i = 0 to n - 1 do let d = ((key (Array.unsafe_get a i) - lo) lsr s) land 2047 in Array.unsafe_set cnt d (Array.unsafe_get cnt d + 1) done;
      let t = ref 0 in
      for d = 0 to 2047 do let c = cnt.(d) in cnt.(d) <- !t; t := !t + c done;
      for i = 0 to n - 1 do
        let j = Array.unsafe_get a i in
        let d = ((key j - lo) lsr s) land 2047 in
        let at = Array.unsafe_get cnt d in
        Array.unsafe_set cnt d (at + 1);
        Array.unsafe_set b at j
      done;
      src := b;
      dst := a;
      sh := s + 11
    done;
    if !src != o then Array.blit !src 0 o 0 n;
    true
  end

let[@inline] present st = st land 1 <> 0
type pdelta = { pn : int; pk : int  (* values in pm *); pm : VM.t  (* value -> its things *) }

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

(* ---- the text order (run format 9) ---- *)

(* the first entry and the count of property p's texts in a part's text order *)
let tord_range b p =
  if b.n = 0 || p >= b.np || b.o_tord + (8 * (p + 2)) > b.len then 0, 0
  else let s = ci64 b (b.o_tord + (8 * p)) in s, ci64 b (b.o_tord + (8 * (p + 1))) - s

let tord_word b i = cu32 b (b.o_tord + (8 * (b.np + 1)) + (4 * i))

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

(* The words of p's texts that start with [pre], sorted and distinct: in each run, two binary searches in its text
   order give the stretch (texts compared by their bytes); the delta's texts of p are looked at one by one (at most a
   merge's threshold of them). A superset of the texts p's facts hold in the view: a word no fact holds any more is a
   candidate that no pattern accepts. *)
let prefix_words v p pre =
  let n = String.length pre in
  let starts s = String.length s >= n && String.sub s 0 n = pre in
  let out = ref [] in
  Array.iter
    (fun r ->
      let b = r.a in
      let first, count = tord_range b p in
      if count > 0 then begin
        let word i = tord_word b (first + i) in
        let lo = ref 0 and hi = ref count in
        while !lo < !hi do
          let mid = (!lo + !hi) lsr 1 in
          if String.compare (text v (word mid)) pre < 0 then lo := mid + 1 else hi := mid
        done;
        let i = ref !lo in
        while !i < count && starts (text v (word !i)) do out := word !i :: !out; incr i done
      end)
    v.runs;
  (match IM.find_opt p v.delta.dav with
   | Some pd -> VM.iter (fun w _ -> if starts (text v w) then out := w :: !out) pd.pm
   | None -> ());
  Array.of_list (List.sort_uniq compare !out)

(* The words of p's texts in the order of their bytes, the smallest first (the largest with [desc]), from the first
   text >= [from] (<= [from] with [desc]; every text when None): each run's text order (run format 9) from a binary
   search, and the delta's texts of p sorted once, merged; a text in several runs comes once (a text has one id in a
   view). As [prefix_words], a superset of the texts p's facts hold in the view: a word no fact holds any more counts
   no fact. [next ()]: the next word, or -1 at the end. *)
let text_order v p ~desc ~from =
  let cmp a b = if desc then String.compare b a else String.compare a b in
  (* the sources: each run's stretch, then the delta's words; [pos] the next place, [stop] the end *)
  let runs = List.filter_map (fun r -> let first, count = tord_range r.a p in if count > 0 then Some (r.a, first, count) else None) (Array.to_list v.runs) in
  let delta =
    match IM.find_opt p v.delta.dav with
    | None -> [||]
    | Some pd ->
      let ws = Array.of_list (VM.fold (fun w _ acc -> w :: acc) pd.pm []) in
      let ts = Array.map (fun w -> text v w, w) ws in
      Array.sort (fun (a, _) (b, _) -> cmp a b) ts;
      Array.map snd ts
  in
  let k = List.length runs + 1 in
  let word = Array.make k (fun (_ : int) -> 0) and len = Array.make k 0 and pos = Array.make k 0 in
  List.iteri
    (fun j (b, first, count) ->
      (* in a run, the stretch is in ascending order: read backwards when descending *)
      word.(j) <- (if desc then fun i -> tord_word b (first + count - 1 - i) else fun i -> tord_word b (first + i));
      len.(j) <- count)
    runs;
  word.(k - 1) <- (fun i -> delta.(i));
  len.(k - 1) <- Array.length delta;
  (* the first place of each source at or after [from], by a binary search in its order *)
  (match from with
   | None -> ()
   | Some s ->
     for j = 0 to k - 1 do
       let lo = ref 0 and hi = ref len.(j) in
       while !lo < !hi do
         let mid = (!lo + !hi) lsr 1 in
         if cmp (text v (word.(j) mid)) s < 0 then lo := mid + 1 else hi := mid
       done;
       pos.(j) <- !lo
     done);
  (* each source's next text, read once *)
  let head = Array.make k "" and hw = Array.make k (-1) in
  let load j = if pos.(j) < len.(j) then (let w = word.(j) pos.(j) in hw.(j) <- w; head.(j) <- text v w) else hw.(j) <- -1 in
  for j = 0 to k - 1 do load j done;
  fun () ->
    let best = ref (-1) in
    for j = 0 to k - 1 do
      if hw.(j) >= 0 && (!best < 0 || cmp head.(j) head.(!best) < 0) then best := j
    done;
    if !best < 0 then -1
    else begin
      let w = hw.(!best) in
      for j = 0 to k - 1 do
        if hw.(j) = w then (pos.(j) <- pos.(j) + 1; load j)
      done;
      w
    end

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

(* the values of (e, p) with their states, 1 asserted, 2 only derived, as [iter_values] *)
let iter_values_st v e p f =
  let rs = v.runs and td = thing_delta v e in
  if Option.is_none td && Array.length rs = 1 then base_iter_ea_st rs.(0).a e p f
  else begin
    let h = holders_p v e p in
    let one = single h in
    if Option.is_none td && one >= 0 then base_iter_ea_st rs.(one).a e p f
    else begin
      for j = 0 to Array.length rs - 1 do
        if (h lsr j) land 1 = 1 then
          base_iter_ea_st rs.(j).a e p (fun w st ->
              if (match td with Some td -> not (PW.mem (p, w) td.tf) | None -> true) && not (newer v h j e p w) then f w st)
      done;
      Option.iter (fun td -> iter_delta_ep td p (fun w st -> if present st then f w (if st land 2 = 0 then 1 else 2))) td
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

let delta_av v p w = match IM.find_opt p v.delta.dav with None -> None | Some pd -> VM.find_opt w pd.pm

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
            | Some pd -> (match VM.find_opt w pd.pm with Some vd -> IM.mem e vd.vm | None -> false)
            | None -> false
          in
          if (not in_delta) && shown v j e p w then f e w)
    done;
    Option.iter (fun pd -> VM.iter (fun w vd -> IM.iter (fun e st -> if present st then f e w) vd.vm) pd.pm) pd

(* the facts of p with lo <= value word <= hi (an order on values for the inline types) *)
let iter_range v p lo hi f =
  let rs = v.runs in
  match IM.find_opt p v.delta.dav with
  | None when Array.length rs = 1 -> base_iter_range rs.(0).a p lo hi f
  | pd ->
    for j = 0 to Array.length rs - 1 do
      base_iter_range rs.(j).a p lo hi (fun e w ->
          let in_delta = match pd with
            | Some pd -> (match VM.find_opt w pd.pm with Some vd -> IM.mem e vd.vm | None -> false)
            | None -> false
          in
          if (not in_delta) && shown v j e p w then f e w)
    done;
    match pd with
    | None -> ()
    | Some pd -> VM.iter_range lo hi (fun w vd -> IM.iter (fun e st -> if present st then f e w) vd.vm) pd.pm

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

(* the value of (e, p) when e has exactly one, in a view with no change of e whose runs hold facts of e for p in one
   run at most (as [iter_values], a newer run with other facts of e shadows none of these): 1 and the value in
   cell.(0); 0: none; 2: otherwise (several values, or several runs holding (e, p), or a delta: read them by
   [iter_values]). The runs of a load's new things hold disjoint things: one run holds each *)
let value1 v e p cell =
  if is_touched v e then 2
  else if Array.length v.runs = 1 then base_value1 v.runs.(0).a e p cell
  else begin
    let h = holders_p v e p in
    if h = 0 then 0 else (let one = single h in if one >= 0 then base_value1 v.runs.(one).a e p cell else 2)
  end

(* A slice read straight into a buffer, for the leapfrog: in a view of one run with no change of e (or of p), the
   rows of (e, p) or (p, w): their count, their first row in cell.(1); -1 otherwise (count and read them as any) *)
let slice_values v e p cell = if Array.length v.runs = 1 && not (is_touched v e) then base_range_ea v.runs.(0).a e p cell else -1
let slice_things v p w cell = if Array.length v.runs = 1 && not (IM.mem p v.delta.dav) then base_range_av v.runs.(0).a p w cell else -1

(* rows lo .. lo+n-1 of a slice into buf.(0 .. n-1) *)
let read_values v e p lo n (buf : int array) =
  let b = v.runs.(0).a and hi = lo + n in
  let r = ref lo in
  while !r < hi do
    let j = !r lsr 7 in
    let d = ce b p 4 + (j lsl 4) in
    let h = ci64 b d in
    let base = ci64 b (d + 8) + (if (h lsr 9) land 1 = 0 then 0 else e) in
    let wv = h land 0xFF and fl = (h lsr 8) land 1 and at = ce b p 5 + (h lsr 16) in
    let stop = min hi ((j + 1) lsl 7) in
    for r' = !r to stop - 1 do
      Array.unsafe_set buf (r' - lo) (base + cfield b at (((r' land 127) * wv) + fl) (wv - fl))
    done;
    r := stop
  done

(* rows lo .. lo+n-1 of p's rows by value in a part: their things into buf.(0 .. n-1) *)
let base_read_things b p lo n (buf : int array) =
  let r1 = lo + n in
  if lo < r1 then begin
    let p0 = cpoff b p in
    let rows = cpoff b (p + 1) - p0 and j0 = ci64 b (b.o_pblk + (8 * p)) in
    let r = ref lo in
    while !r < r1 do
      let j = j0 + ((!r - p0) lsr 7) and k0 = (!r - p0) land 127 in
      let brows = min tb (rows - ((j - j0) lsl 7)) in
      let k1 = min brows (k0 + (r1 - !r)) in
      let d = b.o_vdir + (16 * j) in
      let o0 = ci64 b d in
      let bo = b.o_vdata + o0 and len = ci64 b (d + 16) - o0 in
      let f0 = framec b bo and i0 = bo land Pages.mask in
      let f = if i0 + len <= Pages.size then f0 else cassemble b bo len and i = if i0 + len <= Pages.size then i0 else 0 in
      let wv = g8 f i and wt = g8 f (i + 2) and tl = g32 f (i + 4) in
      let ta = (i + 8 + pbytes brows wv) lsl 3 in
      let out = !r - lo - k0 in
      if g8 f (i + 3) = 0 then
        for k = k0 to k1 - 1 do Array.unsafe_set buf (out + k) (tl + Pack.get f (ta + (k * wt)) wt) done
      else begin
        (* things by gaps (as [scan]): the rows of one value, from its first row in the block, which a slice of
           (p, w) starts at or continues from the block's first row *)
        let fl = g8 f (i + 1) and va = (i + 8) lsl 3 in
        let value k = if fl = 0 then Pack.get f (va + (k * wv)) wv else Pack.get f (va + (k * wv) + 1) (wv - 1) in
        let s =
          if k0 = 0 then 0
          else begin
            let w0 = value k0 and lo = ref 0 and hi = ref k0 in
            while !lo < !hi do let mid = (!lo + !hi) lsr 1 in if value mid < w0 then lo := mid + 1 else hi := mid done;
            !lo
          end
        in
        let t = ref 0 and pw = ref 0 in
        for k = s to k1 - 1 do
          let w = value k and x = Pack.get f (ta + (k * wt)) wt in
          t := if k > s && w = !pw then !t + 1 + x else tl + x;
          pw := w;
          if k >= k0 then Array.unsafe_set buf (out + k) !t
        done
      end;
      r := !r + (k1 - k0)
    done
  end

let read_things v p lo n buf = base_read_things v.runs.(0).a p lo n buf

(* the rows lo .. lo+n-1 of a slice of [slice_things] (of [slice_values]) given to f in their order: the things (the
   values) [iter_things] ([iter_values]) gives, in a view of one run with no change of p (of e) *)
let iter_slice_things v p lo n f = if n > 0 then scan v.runs.(0).a p lo (lo + n) (fun e _ _ -> f e)
let iter_slice_values v e p lo n f = if n > 0 then cloop v.runs.(0).a p e lo (lo + n) f

(* the things that hold p, each once: in thing order from the column of a view of one run with no change of p;
   otherwise as the facts come, seen once through a table *)
let iter_holders v p f =
  if Array.length v.runs = 1 && not (IM.mem p v.delta.dav) then base_iter_pt v.runs.(0).a p f
  else begin
    let seen = Hashtbl.create 256 in
    iter_prop v p (fun e _ -> if not (Hashtbl.mem seen e) then (Hashtbl.replace seen e (); f e))
  end

(* the values of p with lo <= value word <= hi, each once, in the order [iter_range] meets them first: in value order
   from the rows by value of a view of one run with no change of p, equal values side by side; otherwise seen once
   through a table *)
let iter_range_values v p lo hi f =
  if Array.length v.runs = 1 && not (IM.mem p v.delta.dav) then begin
    let last = ref 0 and first = ref true in
    base_iter_range v.runs.(0).a p lo hi (fun _ w -> if !first || w <> !last then (first := false; last := w; f w))
  end
  else begin
    let seen = Hashtbl.create 256 in
    iter_range v p lo hi (fun _ w -> if not (Hashtbl.mem seen w) then (Hashtbl.replace seen w (); f w))
  end

(* the values p takes, each once: in value order from the rows by value of a view of one run with no change of p, equal
   values side by side; otherwise seen once through a table *)
let iter_taken v p f =
  if Array.length v.runs = 1 && not (IM.mem p v.delta.dav) then begin
    if not (base_iter_indexed_values v.runs.(0).a p f) then begin
      let last = ref 0 and first = ref true in
      base_iter_p v.runs.(0).a p (fun _ w -> if !first || w <> !last then (first := false; last := w; f w))
    end
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

(* the facts of p in a range: exact on the runs, and the delta's part from its sums (VM), O(log n) *)
let[@inline never] count_range v p lo hi =
  let rs = v.runs and n = ref 0 in
  for j = 0 to Array.length rs - 1 do
    n := !n + base_count_range rs.(j).a p lo hi - base_count_range rs.(j).t p lo hi
  done;
  (match IM.find_opt p v.delta.dav with
   | Some pd when lo <= hi -> n := !n + VM.sum_range lo hi pd.pm
   | _ -> ());
  !n

(* the values of p that the delta holds changes of *)
let delta_values v p = match IM.find_opt p v.delta.dav with Some pd -> pd.pk | None -> 0

(* For the windows of the index path (Top): the value of the m-th fact of p from [w] on (from [w] down with [desc]) in
   each run's index and in the delta, the nearest of them to w; None when none of them holds m. The window from w to
   that value holds m facts of the source that gave it, less those newer runs retract, and at most m of each other
   source: a bound of the window of m facts, found in two lookups a run, that the search for that window starts
   from instead of the whole range of ints *)
let nth_bound v p w m ~desc =
  let best = ref None in
  let keep x = match !best with Some b when (if desc then x <= b else x >= b) -> () | _ -> best := Some x in
  if m > 0 then begin
    Array.iter
      (fun r ->
        let b = r.a in
        if has_p b p then begin
          let p0 = cpoff b p and p1 = cpoff b (p + 1) in
          if desc then begin
            let r1 = if w = max_int then p1 else base_lower b p (w + 1) in
            if r1 - m >= p0 then keep (base_pvalue b p (r1 - m))
          end
          else begin
            let r0 = base_lower b p w in
            if r0 + m - 1 < p1 then keep (base_pvalue b p (r0 + m - 1))
          end
        end)
      v.runs;
    match IM.find_opt p v.delta.dav with
    | None -> ()
    | Some pd ->
      (* the delta's additions of p from w: the value where they reach m, from the sums of its tree (VM) *)
      Option.iter keep (VM.nth w m ~desc pd.pm)
  end;
  !best

(* an estimate for the planner: the distinct values of p, the runs' and the delta's (an upper bound) *)
let distinct v p =
  let rs = v.runs and n = ref 0 in
  for j = 0 to Array.length rs - 1 do n := !n + base_pdist rs.(j).a p done;
  max 1 (!n + match IM.find_opt p v.delta.dav with Some pd -> pd.pk | None -> 0)

(* ---- The things of a property in the order of their ids: pages by a thing, and ranges of things ----
   A page sorted by a thing that holds p (Sort on a thing, After its last one: Top's index path) and a range of a thing
   variable (Query) read the things that hold p, or p with the value w, in the order of their ids from a thing on. A
   part's things of p are its column's rank table (base_holders); its things of (p, w) are the rows of (p, w) by
   value, which are in thing order within a value, so that a binary search finds the first one at or past a thing.
   The delta's come from its map by thing (de) for p, from its map by value (dav) for (p, w). Merged over the runs
   and the delta, each thing once. In a view of one run whose delta has no change of p, the run's things are the
   view's; otherwise each is checked (has_value, mem: a newer run or the delta may have retracted its facts), and a
   thing that only the delta gives p is the delta's. *)

(* the things of (p, w) in a part from e on (from e down with [desc]): the first by a binary search among the rows of
   (p, w), then their things read 128 rows at a time *)
(* the first of the rows r0 .. r1-1 of a value of p (in thing order) whose thing is >= t, r1 when none is *)
let av_first b p r0 r1 t =
  let one = [| 0 |] in
  let lo = ref r0 and hi = ref r1 in
  while !lo < !hi do
    let mid = (!lo + !hi) lsr 1 in
    base_read_things b p mid 1 one;
    if one.(0) < t then lo := mid + 1 else hi := mid
  done;
  !lo

let base_holders_av b p w ~desc e =
  let cell = [| 0; 0 |] in
  let c = base_range_av b p w cell in
  if c <= 0 then fun () -> -1
  else begin
    let r0 = cell.(1) in
    let r1 = r0 + c in
    let first t = av_first b p r0 r1 t in
    (* the rows still to give: from [pos] up (to r1), or from [pos] down (to r0) with [desc]; the buffer holds the next
       ones, in the order they are given *)
    let pos = ref (if desc then (if e = max_int then r1 else first (e + 1)) - 1 else first e) in
    let buf = Array.make 128 0 and bn = ref 0 and bi = ref 0 in
    fun () ->
      if !bi < !bn then (let t = buf.(!bi) in incr bi; t)
      else if desc then begin
        if !pos < r0 then -1
        else begin
          let a = max r0 (!pos - 127) in
          let n = !pos - a + 1 in
          base_read_things b p a n buf;
          for i = 0 to (n / 2) - 1 do let t = buf.(i) in buf.(i) <- buf.(n - 1 - i); buf.(n - 1 - i) <- t done;
          bn := n;
          bi := 1;
          pos := a - 1;
          buf.(0)
        end
      end
      else if !pos >= r1 then -1
      else begin
        let n = min 128 (r1 - !pos) in
        base_read_things b p !pos n buf;
        bn := n;
        bi := 1;
        pos := !pos + n;
        buf.(0)
      end
  end

(* the keys of an int map that [keep] takes, from e up (from e down with [desc]), e included; -1 after the last *)
let im_from (m : 'a IM.t) ~desc e (keep : 'a -> bool) =
  if not desc then begin
    let s = ref (IM.to_seq_from e m) in
    let rec next () = match !s () with Seq.Nil -> -1 | Seq.Cons ((k, d), s') -> s := s'; if keep d then k else next () in
    next
  end
  else begin
    let cur = ref e and fin = ref false in
    let rec next () =
      if !fin then -1
      else
        match IM.find_last_opt (fun k -> k <= !cur) m with
        | None -> fin := true; -1
        | Some (k, d) -> if k = min_int then fin := true else cur := k - 1; if keep d then k else next ()
    in
    next
  end

(* does a thing's delta hold a fact of p *)
let delta_has_p p (td : tdelta) =
  let rec go s = match s () with Seq.Cons (((p', _), st), s') when p' = p -> present st || go s' | _ -> false in
  go (PW.to_seq_from (p, min_int) td.tf)

(* The delta's things with a fact of p, in the order of their ids from [from] (down with [desc]), read from its map by
   thing, which holds every thing the delta changed: [scan bound] gives the next one up to [bound] (down to it), -2
   when there is none so far (the scan stops at bound: a thing past it is read again at the next call), -1 after the
   last. So the things of other properties the delta changed are read only within the stretch of ids the runs' things
   reach (a page of clients beside a delta of new invoices reads none past the page) *)
let delta_scan (de : tdelta IM.t) p ~desc from =
  if not desc then begin
    let s = ref (IM.to_seq_from from de) and pend = ref None in
    fun bound ->
      let rec go () =
        let item = match !pend with Some _ as x -> pend := None; x | None -> (match !s () with Seq.Nil -> None | Seq.Cons (x, s') -> s := s'; Some x) in
        match item with
        | None -> -1
        | Some (k, td) -> if k > bound then (pend := item; -2) else if delta_has_p p td then k else go ()
      in
      go ()
  end
  else begin
    let cur = ref from and fin = ref false in
    fun bound ->
      let rec go () =
        if !fin then -1
        else
          match IM.find_last_opt (fun k -> k <= !cur) de with
          | None -> fin := true; -1
          | Some (k, td) ->
            if k < bound then -2
            else begin
              if k = min_int then fin := true else cur := k - 1;
              if delta_has_p p td then k else go ()
            end
      in
      go ()
  end

(* The things the delta gives p (each a present entry of p), sorted and distinct, when the delta holds at most
   [delta_few] entries of p (read from its map by value: a few changes of p, as a client renamed beside a delta of new
   invoices); None past them (the delta's map by thing is scanned then, delta_scan; the tests make it 0) *)
let delta_few = ref 512

let delta_holders (pd : pdelta) =
  let n = ref 0 and out = ref [] in
  (* a value an entry at least: past [delta_few] values, no walk *)
  if pd.pk > !delta_few then None
  else
  match VM.iter (fun _ (vd : vdelta) -> IM.iter (fun e st -> incr n; if !n > !delta_few then raise_notrace Exit; if present st then out := e :: !out) vd.vm) pd.pm with
  | () -> let a = Array.of_list !out in Array.sort compare a; Some a
  | exception Exit -> None

(* the ints of a sorted array from [from] on (from it down with [desc]), [from] included; -1 after the last *)
let sorted_from (a : int array) ~desc from =
  let n = Array.length a in
  let lo = ref 0 and hi = ref n in
  (* the first place whose value is >= from (> from with [desc]) *)
  while !lo < !hi do
    let mid = (!lo + !hi) lsr 1 in
    if (if desc then a.(mid) <= from else a.(mid) < from) then lo := mid + 1 else hi := mid
  done;
  let i = ref (if desc then !lo - 1 else !lo) and last = ref (-1) in
  fun () ->
    let rec go () =
      if !i < 0 || !i >= n then -1
      else begin
        let x = a.(!i) in
        if desc then decr i else incr i;
        if x = !last then go () else (last := x; x)
      end
    in
    go ()

(* The things that hold p (that hold the fact (p, w) with [value]), each once, in the order of their ids from [from]
   on (from [from] down with [desc]), [from] included: [next ()] gives the next one, -1 after the last. A step costs
   the merge of the runs' and the delta's next things, and for a view of several runs, or with changes of p, the
   check of the thing given. *)
let holders_from v p ?value ~desc ~from () =
  let rs = v.runs in
  let pd = IM.find_opt p v.delta.dav in
  (* the things the delta gives p, when it holds a few changes of p *)
  let few = match value, pd with None, Some pd -> delta_holders pd | _ -> None in
  let srcs =
    Array.of_list
      (List.filter_map
         (fun r ->
           let b = r.a in
           if not (has_p b p) then None
           else Some (match value with None -> base_holders b p ~desc from | Some w -> base_holders_av b p w ~desc from))
         (Array.to_list rs)
      @
      match value, pd with
      | Some w, Some pd -> (match VM.find_opt w pd.pm with Some vd -> [ im_from vd.vm ~desc from present ] | None -> [])
      | None, Some _ -> (match few with Some a -> [ sorted_from a ~desc from ] | None -> [])
      | _, None -> [])
  in
  (* past a few changes of p, the things the delta changed scanned by thing, up to the runs' next thing *)
  let scan = match value, pd, few with None, Some _, None -> Some (delta_scan v.delta.de p ~desc from) | _ -> None in
  let check = Array.length rs > 1 || pd <> None in
  let holds e = match value with None -> has_value v e p | Some w -> mem v e p w in
  let k = Array.length srcs in
  let head = Array.map (fun next -> next ()) srcs in
  (* the scan's next thing: -2 not read yet (or none up to the bound it was read to), -1 none left *)
  let dhead = ref (-2) in
  let first a b = if a < 0 then b else if b < 0 then a else if desc then Stdlib.max a b else Stdlib.min a b in
  let rec next () =
    let best = ref (-1) in
    for j = 0 to k - 1 do best := first !best head.(j) done;
    (match scan with
     | Some sc when !dhead = -2 -> dhead := sc (if !best >= 0 then !best else if desc then min_int else max_int)
     | _ -> ());
    let e = first !best (if !dhead >= 0 then !dhead else -1) in
    if e < 0 then -1
    else begin
      for j = 0 to k - 1 do if head.(j) = e then head.(j) <- srcs.(j) () done;
      if !dhead = e then dhead := -2;
      if (not check) || holds e then e else next ()
    end
  in
  next

(* The facts of p whose thing is in [lo, hi]: each run's rows there, less its retractions, from its column's rank table
   and offsets (O(1) a part), and the delta's net count of its things there, read one by one: exact while the delta
   holds at most [delta_look] things in the range, an upper bound past them (the delta's additions of p count for the
   rest). For the planner and the join's choice of a source, which an upper bound leaves right. *)
let delta_look = 256

let count_holders v p lo hi =
  if lo > hi then 0
  else begin
    let n = ref 0 in
    Array.iter (fun r -> n := !n + (if has_p r.a p then base_count_holders r.a p lo hi else 0) - if has_p r.t p then base_count_holders r.t p lo hi else 0) v.runs;
    (match IM.find_opt p v.delta.dav with
     | None -> ()
     | Some pd ->
       let s = ref (IM.to_seq_from lo v.delta.de) and left = ref delta_look in
       while !left > 0 do
         match !s () with
         | Seq.Cons ((e, td), s') when e <= hi -> s := s'; decr left; (match IM.find_opt p td.tn with Some c -> n := !n + c | None -> ())
         | _ -> left := -1
       done;
       if !left = 0 then (match !s () with Seq.Cons ((e, _), _) when e <= hi -> n := !n + VM.adds pd.pm | _ -> ()));
    max 0 !n
  end

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
  let pd = match IM.find_opt p d.dav with Some pd -> pd | None -> { pn = 0; pk = 0; pm = VM.empty } in
  let vold = VM.find_opt w pd.pm in
  let vd = match vold with Some vd -> vd | None -> { vn = 0; vm = IM.empty } in
  let vm = if st < 0 then IM.remove e vd.vm else IM.add e st vd.vm in
  let pm, pk =
    if IM.is_empty vm then VM.remove w pd.pm, (if vold = None then pd.pk else pd.pk - 1)
    else VM.add w { vn = vd.vn + diff; vm } pd.pm, if vold = None then pd.pk + 1 else pd.pk
  in
  let dav = if VM.is_empty pm then IM.remove p d.dav else IM.add p { pn = pd.pn + diff; pk; pm } d.dav in
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

(* A map of n keys from [ks] (strictly increasing) with their values [vs], in O(n), a node a key (IM.of_sorted), where
   n insertions one by one would copy a path each: O(n log n) blocks *)
let im_of_sorted (ks : int array) (vs : 'a array) lo hi = IM.of_sorted ks vs lo hi

(* [m] with the sorted keys and values added (none of them removals): one by one when they are few, else by a union
   with the map they make (O(k log(n/k + 1)) for k keys into n) *)
let im_add_sorted (ks : int array) (vs : 'a array) k (m : 'a IM.t) =
  if k < 64 then (let m = ref m in for i = 0 to k - 1 do m := IM.add ks.(i) vs.(i) !m done; !m)
  else if IM.is_empty m then im_of_sorted ks vs 0 k
  else IM.union (fun _ a _ -> Some a) (im_of_sorted ks vs 0 k) m

(* Many facts set at once: [es], [ps], [ws], [ss] the things, properties, value words and states (0 absent,
   1 asserted, 2 only derived) of n facts, distinct, sorted by (thing, property, value). The same result as [set] one
   after the other, with one walk of the map by thing a thing and one of the map by property a property, where [set]
   walks both for each fact: the derived facts of a group come in clusters (a new thing's types, a class's members).
   [olds]: the facts' states in [v] when the caller knows them (the reasoner does): a fact the delta has no entry for
   is in that state in the runs, and is not looked up there. *)
let[@inline never] set_sorted ?olds v (es : int array) (ps : int array) (ws : int array) (ss : int array) n =
  if n = 0 then v
  else begin
    let d = v.delta in
    let de = ref d.de and dn = ref d.dn and dnet = ref d.dnet in
    (* the entries changed, for the map by property: (p, w, e, entry, diff), in arrays *)
    let cp = Array.make n 0 and cw = Array.make n 0 and ce = Array.make n 0 and cst = Array.make n 0 and cdiff = Array.make n 0 in
    let nc = ref 0 and v = ref v in
    (* the things the delta held nothing of, with their entries, in order: added to [de] at once at the end *)
    let fk = Array.make n 0 and fv = Array.make n { tf = PW.empty; tn = IM.empty } and nf = ref 0 in
    let i = ref 0 in
    while !i < n do
      let e = es.(!i) in
      let td0 = if is_touched !v e then IM.find_opt e !de else None in
      let tf = ref (match td0 with Some t -> t.tf | None -> PW.empty) and tn = ref (match td0 with Some t -> t.tn | None -> IM.empty) in
      let any = ref false in
      while !i < n && es.(!i) = e do
        let p = ps.(!i) and w = ws.(!i) and s = ss.(!i) in
        let old = match PW.find_opt (p, w) !tf with Some st -> st | None -> -1 in
        let cur, rs =
          if old >= 0 then state_of_entry old, state_of_entry (old lsr 2)
          else match olds with Some (o : int array) -> let r = o.(!i) in r, r | None -> let r = runs_state !v e p w in r, r
        in
        if cur <> s then begin
          let st = entry s rs in
          let diff = net st - net old in
          tf := (if st < 0 then PW.remove (p, w) !tf else PW.add (p, w) st !tf);
          if diff <> 0 then begin
            let k = Option.value (IM.find_opt p !tn) ~default:0 + diff in
            tn := if k = 0 then IM.remove p !tn else IM.add p k !tn
          end;
          let c = !nc in
          cp.(c) <- p; cw.(c) <- w; ce.(c) <- e; cst.(c) <- st; cdiff.(c) <- diff;
          nc := c + 1;
          incr dn;
          dnet := !dnet + diff;
          any := true
        end;
        incr i
      done;
      if !any then begin
        v := touch !v e;
        if td0 = None && not (PW.is_empty !tf) then (fk.(!nf) <- e; fv.(!nf) <- { tf = !tf; tn = !tn }; incr nf)
        else de := if PW.is_empty !tf then IM.remove e !de else IM.add e { tf = !tf; tn = !tn } !de
      end
    done;
    de := im_add_sorted fk fv !nf !de;
    (* the changes by (property, value, thing): a sort of their indexes by ints, no tuple; many of them by stable
       radix sorts by thing (when they do not come in its order already), by value, then by property: the same
       order, the facts being distinct *)
    let m = !nc in
    let o = Array.init m Fun.id in
    let sorted_e = let ok = ref true in for j = 1 to m - 1 do if ce.(j) < ce.(j - 1) then ok := false done; !ok in
    if not (m >= 256 && (sorted_e || radix_by (fun j -> Array.unsafe_get ce j) o) && radix_by (fun j -> Array.unsafe_get cw j) o && radix_by (fun j -> Array.unsafe_get cp j) o)
    then begin
      Array.iteri (fun i _ -> o.(i) <- i) o;
      Array.stable_sort
        (fun a b ->
          let x = Array.unsafe_get cp a and y = Array.unsafe_get cp b in
          if x <> y then compare (x : int) y
          else
            let x = Array.unsafe_get cw a and y = Array.unsafe_get cw b in
            if x <> y then compare (x : int) y else compare (Array.unsafe_get ce a : int) (Array.unsafe_get ce b))
        o
    end;
    let dav = ref d.dav in
    let k = ref 0 in
    while !k < m do
      let p = cp.(o.(!k)) in
      let pd = match IM.find_opt p !dav with Some pd -> pd | None -> { pn = 0; pk = 0; pm = VM.empty } in
      let pm = ref pd.pm and pk = ref pd.pk and pn = ref pd.pn in
      (* a property the delta holds no value of: its values' entries made in order, then their tree at once
         (VM.of_sorted, O(n)), where one addition after the other copies a path each *)
      let fresh = VM.is_empty pd.pm in
      let fk = ref [] and fd = ref [] and nf = ref 0 in
      while !k < m && cp.(o.(!k)) = p do
        let w = cw.(o.(!k)) in
        let vold = VM.find_opt w !pm in
        let vd = match vold with Some vd -> vd | None -> { vn = 0; vm = IM.empty } in
        let vm = ref vd.vm and vn = ref vd.vn in
        (* the group's entries of (p, w), by thing: added at once when none is a removal *)
        let k0 = !k in
        let removal = ref false in
        while !k < m && cp.(o.(!k)) = p && cw.(o.(!k)) = w do
          let j = o.(!k) in
          if cst.(j) < 0 then removal := true;
          vn := !vn + cdiff.(j);
          pn := !pn + cdiff.(j);
          incr k
        done;
        if !removal then
          for q = k0 to !k - 1 do
            let j = o.(q) in
            vm := if cst.(j) < 0 then IM.remove ce.(j) !vm else IM.add ce.(j) cst.(j) !vm
          done
        else begin
          let c = !k - k0 in
          let ks = Array.init c (fun q -> ce.(o.(k0 + q))) and vs = Array.init c (fun q -> cst.(o.(k0 + q))) in
          vm := im_add_sorted ks vs c !vm
        end;
        if fresh then begin
          (* nothing before: no removal, every entry new *)
          if not (IM.is_empty !vm) then (fk := w :: !fk; fd := { vn = !vn; vm = !vm } :: !fd; incr nf; incr pk)
        end
        else if IM.is_empty !vm then (pm := VM.remove w !pm; if vold <> None then decr pk)
        else (pm := VM.add w { vn = !vn; vm = !vm } !pm; if vold = None then incr pk)
      done;
      if fresh && !nf > 0 then begin
        let ks = Array.of_list (List.rev !fk) and ds = Array.of_list (List.rev !fd) in
        pm := VM.of_sorted ks ds 0 !nf
      end;
      dav := (if VM.is_empty !pm then IM.remove p !dav else IM.add p { pn = !pn; pk = !pk; pm = !pm } !dav)
    done;
    { !v with delta = { de = !de; dav = !dav; dn = !dn; dnet = !dnet } }
  end

(* the order of n facts by (thing, property, value): a permutation of 0 .. n-1, sorted by comparisons of ints (no
   tuple is built: a large group's derived facts, a change's frame) *)
let fact_order (es : int array) (ps : int array) (ws : int array) n =
  let o = Array.init n Fun.id in
  Array.stable_sort
    (fun i j ->
      let a = Array.unsafe_get es i and b = Array.unsafe_get es j in
      if a <> b then compare (a : int) b
      else
        let a = Array.unsafe_get ps i and b = Array.unsafe_get ps j in
        if a <> b then compare (a : int) b else compare (Array.unsafe_get ws i : int) (Array.unsafe_get ws j))
    o;
  o

(* Adds (asserted) or retracts (e p w); the view itself when nothing changes. *)
let apply v add e p w = set v e p w (if add then 1 else 0)

let max_thing v =
  Array.fold_left (fun m r -> max m (max r.a.ne r.t.ne - 1)) (v.next_e - 1) v.runs

let fork v =
  { v with writer = false; ftouched = (if Bytes.length v.ftouched = 0 then Bytes.empty else Bytes.copy v.ftouched) }

let facts v = Array.fold_left (fun n r -> n + r.a.n - r.t.n) v.delta.dnet v.runs

(* rows of a run: what the merge policy weighs *)
let run_rows r = r.a.n + r.t.n

(* What a property's facts (w < 0), or a (property, value)'s things, are in a view, for a comparison by identity: two
   views of the same runs ([runs] physically equal) whose stamps are physically equal hold the same such facts (the
   delta's maps are persistent, and a change replaces the entries on its path). Unequal stamps say nothing. *)
type stamp = No_entry | Of_p of pdelta | Of_pw of vdelta

let stamp v p w =
  match IM.find_opt p v.delta.dav with
  | None -> No_entry
  | Some pd -> if w < 0 then Of_p pd else (match VM.find_opt w pd.pm with None -> No_entry | Some vd -> Of_pw vd)

let same_stamp a b =
  match a, b with
  | No_entry, No_entry -> true
  | Of_p x, Of_p y -> x == y
  | Of_pw x, Of_pw y -> x == y
  | _ -> false
