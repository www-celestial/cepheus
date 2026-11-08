(* A base's bytes, in pages of 16 KiB, and the cache that keeps some of them in memory.

   A base is a table of frames, one a page (the page's bytes, or [absent]), and a table [hot] of the pages that can be
   read with no word to the policy. A read of a hot page is one array read and one comparison, with no lock, from any
   domain. Otherwise the read counts one for the policy and makes the page hot, or, for a page not in memory, takes
   the cache's lock, makes room, reads the page from its file, checks its CRC-32C (a damaged page is never served,
   G7) and publishes it. A frame is never reused in place: an evicted page leaves the tables, and the GC frees its
   bytes once no reader holds them, so a reader that raced with the eviction still reads the right bytes.

   Policy: S3-FIFO (Yang, Zhang, Qiu, Yue, Vinayak, "FIFO queues are all you need for cache eviction", SOSP 2023),
   checked on recorded traces against LRU, CLOCK, 2Q, ARC, SIEVE, W-TinyLFU and Belady's optimum (docs/theory.md):
   a page enters a small FIFO (a tenth of the room) and goes to the main FIFO only if it was read again meanwhile, so
   a scan does not push out the pages read again and again; in the main FIFO a page read since the policy last looked
   at it is kept (its 2-bit counter lowered), as a CLOCK keeps a page whose bit is set. A ghost FIFO remembers the
   pages lately pushed out of the small one: a page that comes back soon goes straight to the main FIFO. *)

let bits = 14
let size = 1 lsl bits
let mask = size - 1

exception Unreadable of string
(* a page that does not check, or that the disk could not read *)

type t = {
  id : int;  (* the cache's name for this base, in the ghost FIFO *)
  frames : Bytes.t array;  (* the resident pages *)
  hot : Bytes.t array;  (* the resident pages read since the policy last looked at them: a read needs nothing more *)
  freq : Bytes.t;  (* a page's reads counted for the policy, 0 to 3 *)
  len : int;  (* bytes *)
  load : (int -> Bytes.t) option;  (* reads and checks page k; None: every page is resident for good *)
}

(* a constant, so that the test of a frame needs no load: no page is empty *)
let absent = Bytes.unsafe_of_string ""
let ids = Atomic.make 0
let pages len = (len + size - 1) / size

(* ---- the cache ---- *)

type entry = { b : t; k : int }

(* a FIFO of entries or keys, in a growing ring *)
module Ring = struct
  type 'a r = { mutable a : 'a array; mutable head : int; mutable n : int; dummy : 'a }

  let make dummy = { a = Array.make 16 dummy; head = 0; n = 0; dummy }

  let push r x =
    if r.n = Array.length r.a then begin
      let a = Array.make (2 * r.n) r.dummy in
      for i = 0 to r.n - 1 do a.(i) <- r.a.((r.head + i) mod r.n) done;
      r.a <- a;
      r.head <- 0
    end;
    r.a.((r.head + r.n) mod Array.length r.a) <- x;
    r.n <- r.n + 1

  let pop r =
    let x = r.a.(r.head) in
    r.a.(r.head) <- r.dummy;
    r.head <- (r.head + 1) mod Array.length r.a;
    r.n <- r.n - 1;
    x
end

let none = { b = { id = -1; frames = [||]; hot = [||]; freq = Bytes.empty; len = 0; load = None }; k = 0 }
let lock = Mutex.create ()
let capacity = ref (65536 (* pages: 1 GiB *))
let small = Ring.make none
let main = Ring.make none
let ghost = Ring.make (-1)
let ghosts : (int, int) Hashtbl.t = Hashtbl.create 1024 (* key -> times in the ghost FIFO *)
let resident = ref 0
let misses = Atomic.make 0 (* pages read from disk: for the tests and benchmarks *)
let evicted = ref 0 (* pages out since the last full collection *)

let key e = (e.b.id lsl 32) lor e.k
let freq e = Char.code (Bytes.unsafe_get e.b.freq e.k)

let set_capacity bytes = capacity := max 16 (bytes / size)

let forget_ghost g =
  match Hashtbl.find_opt ghosts g with
  | Some 1 -> Hashtbl.remove ghosts g
  | Some c -> Hashtbl.replace ghosts g (c - 1)
  | None -> ()

(* frames first, then hot: see touch *)
let evict e =
  e.b.frames.(e.k) <- absent;
  e.b.hot.(e.k) <- absent;
  decr resident;
  incr evicted

(* The counters. A page in the hot table is read with no word to the policy; it leaves the table each time the policy
   looks at it (lowers its counter, or moves it), and the next read of it counts one and puts it back: so a counter
   counts the periods between two looks of the policy in which the page was read, as a CLOCK bit does (Corbato 1968),
   with S3-FIFO's 2 bits. A page just read from the disk is hot for the read that needed it, and leaves the table at
   the next miss, so that only a later read counts. *)
let set_freq e f =
  e.b.hot.(e.k) <- absent;
  Bytes.unsafe_set e.b.freq e.k (Char.unsafe_chr f)

let fresh = ref none

(* one page out, under the lock *)
let rec make_room () =
  if small.n > 0 && (small.n >= !capacity / 10 || main.n = 0) then begin
    let e = Ring.pop small in
    if e.b.frames.(e.k) == absent then make_room ()
    else if freq e > 0 then begin
      (* read again while in the small FIFO: to the main one *)
      set_freq e 0;
      Ring.push main e;
      make_room ()
    end
    else begin
      evict e;
      let g = key e in
      Ring.push ghost g;
      Hashtbl.replace ghosts g (1 + Option.value (Hashtbl.find_opt ghosts g) ~default:0);
      if ghost.n > !capacity then forget_ghost (Ring.pop ghost)
    end
  end
  else if main.n > 0 then begin
    let e = Ring.pop main in
    if e.b.frames.(e.k) == absent then make_room ()
    else
      let f = freq e in
      if f > 0 then begin
        set_freq e (f - 1);
        Ring.push main e;
        make_room ()
      end
      else evict e
  end

(* A base the database no longer uses (replaced by a merge): its pages leave the cache now rather than when the policy
   gets to them, so that two bases are never held for one. A view that still reads it reads its pages again from the
   file. Nothing for a base built in memory (the GC frees it with its last view). *)
let drop b =
  if b.load <> None then begin
    Mutex.lock lock;
    Array.iteri (fun k f -> if f != absent then evict { b; k }) b.frames;
    Mutex.unlock lock
  end

(* trace mode, for the policy study: every read of a page of a cached base is recorded, as a key *)
let tracing = ref false
let trace = ref (Array.make 0 0)
let traced = ref 0

let record b k =
  let g = (b.id lsl 32) lor k in
  if !traced = 0 || Array.unsafe_get !trace (!traced - 1) <> g then begin
    if !traced = Array.length !trace then begin
      let a = Array.make (max 1024 (2 * !traced)) 0 in
      Array.blit !trace 0 a 0 !traced;
      trace := a
    end;
    Array.unsafe_set !trace !traced g;
    incr traced
  end

(* under the lock: room for one more page *)
let room () =
  while !resident >= !capacity && (small.n > 0 || main.n > 0) do make_room () done;
  (* the bytes of evicted pages go back to the system only when a collection finds them: one full collection after
     each quarter of the cache evicted keeps the pages in memory under 1.25 times the cache (and at least 256 pages,
     4 MB, for a tiny cache, where a full collection every few pages costs more than the pages) *)
  if !evicted >= max 256 (!capacity / 4) then begin
    evicted := 0;
    Gc.full_major ()
  end

(* under the lock: page k of b, resident now, enters the policy's FIFOs with a count of 0 *)
let enter b k f =
  b.frames.(k) <- f;
  Bytes.unsafe_set b.freq k '\000';
  incr resident;
  let e = { b; k } in
  if Hashtbl.mem ghosts (key e) then Ring.push main e else Ring.push small e;
  e

let fill b k load =
  Mutex.lock lock;
  match
    if b.frames.(k) != absent then b.frames.(k)
    else begin
      room ();
      let f = load k in
      Atomic.incr misses;
      let e = enter b k f in
      (* the page read before this one leaves the hot table: its next read will count *)
      let p = !fresh in
      if p.b.id >= 0 && freq p = 0 then p.b.hot.(p.k) <- absent;
      fresh := e;
      if not !tracing then b.hot.(k) <- f;
      f
    end
  with
  | f -> Mutex.unlock lock; f
  | exception ex -> Mutex.unlock lock; raise ex

(* A page a merge has just written (and checked by its CRC) enters the cache cold: in the small FIFO, not hot, so that
   the policy keeps it only if it is read before the FIFO reaches it (a merge's output is a scan). Counted as resident
   like every page: a merge holds no more than the cache. *)
let admit b k f =
  Mutex.lock lock;
  match if b.frames.(k) == absent then (room (); ignore (enter b k f)) with
  | () -> Mutex.unlock lock
  | exception ex -> Mutex.unlock lock; raise ex

(* the slow path of a read of a page that is not hot: one read counted and the page hot again, or a miss *)
let[@inline never] touch b k =
  if !tracing then record b k;
  let f = b.frames.(k) in
  if f != absent then begin
    if not !tracing then begin
      let c = Char.code (Bytes.unsafe_get b.freq k) in
      if c < 3 then Bytes.unsafe_set b.freq k (Char.unsafe_chr (c + 1));
      b.hot.(k) <- f;
      (* evicted meanwhile by another domain: not hot after all (its bytes stay right for whoever holds them) *)
      if b.frames.(k) != f then b.hot.(k) <- absent
    end;
    f
  end
  else
    match b.load with
    | Some load -> fill b k load
    | None -> invalid_arg "Pages: a page of a base built in memory is missing"

(* In trace mode no page is hot but for the lookup under way (Store's lookups that read again from their start
   after a miss): each lookup records each page it reads once, and the page leaves the table when it ends. One
   domain only. *)
let warm = ref []

let fault b k =
  let f = touch b k in
  if !tracing then begin
    b.hot.(k) <- f;
    warm := (b, k) :: !warm
  end

let cool () =
  List.iter (fun (b, k) -> b.hot.(k) <- absent) !warm;
  warm := []

let[@inline] frame b o =
  let k = o lsr bits in
  let f = Array.get b.hot k in
  if f != absent then f else touch b k

external get64u : Bytes.t -> int -> int64 = "%caml_bytes_get64u"
external get32u : Bytes.t -> int -> int32 = "%caml_bytes_get32u"
external get16u : Bytes.t -> int -> int = "%caml_bytes_get16u"

(* reads of 2, 4 and 8 bytes are aligned to their size (every section starts at a multiple of 8), so none crosses a
   page *)
let[@inline] get64 b o = Int64.to_int (get64u (frame b o) (o land mask))
let[@inline] get32 b o = Int32.to_int (get32u (frame b o) (o land mask)) land 0xFFFFFFFF
let[@inline] get16 b o = get16u (frame b o) (o land mask)
let[@inline] get8 b o = Char.code (Bytes.unsafe_get (frame b o) (o land mask))

(* ---- a part with no page (Store.nothing) ---- *)

let empty = { id = -1; frames = [||]; hot = [||]; freq = Bytes.empty; len = 0; load = None }

(* ---- runs read from a file through the cache (every run) ---- *)

let on_file len load =
  let n = pages len in
  { id = Atomic.fetch_and_add ids 1; frames = Array.make n absent; hot = Array.make n absent; freq = Bytes.make n '\000';
    len; load = Some load }

(* page k as it is (from the cache or the disk), for writing a base out *)
let page b k = frame b (k lsl bits)
let count b = Array.length b.frames
