(* Durations in microseconds, counted in log-linear buckets as HdrHistogram does (Tene): exact below 2 x 2^bits, then
   2^bits buckets per power of two up to 2^34 us (4.8 hours), so a recorded value is known within 1/2^bits: with the
   default 7 bits, 128 buckets a power (0.8 %) and 3,584 counters; with 5, 32 (3.1 %) and 960. A percentile costs one
   walk of the counters, whatever the number of values. One writer at a time; readers may read while it writes. The
   counters are made at the first value, not at [create]: a program makes histograms when its modules load (the
   engine's, the journal's) and most never record a value, so none costs start-up. Atomic, so that two domains
   recording a first value at once keep one array: the one whose compare-and-set won, which the other then takes. *)

external now_us : unit -> int = "cepheus_monotonic_us" [@@noalloc]

type t = { bits : int; counts : int array Atomic.t; mutable total : int; mutable max : int; mutable sum : int }

let create ?(bits = 7) () =
  if bits < 1 || bits > 7 then invalid_arg "Histogram.create: bits from 1 to 7";
  { bits; counts = Atomic.make [||]; total = 0; max = 0; sum = 0 }

(* 2 x 2^bits exact counters, then 2^bits for each power of two from 2^(bits + 1) to 2^34 *)
let size bits = (1 lsl bits) * (35 - bits)

let counts h =
  let c = Atomic.get h.counts in
  if Array.length c > 0 then c
  else
    let a = Array.make (size h.bits) 0 in
    if Atomic.compare_and_set h.counts c a then a else Atomic.get h.counts

(* the highest bit set of x > 0, by halves: no loop, so no point where the runtime may switch threads (a writer of
   Timings counts on it: its record reads its slot and writes the counters with no such point between) *)
let msb x =
  let r = ref 0 and x = ref x in
  if !x lsr 32 <> 0 then (x := !x lsr 32; r := 32);
  if !x lsr 16 <> 0 then (x := !x lsr 16; r := !r + 16);
  if !x lsr 8 <> 0 then (x := !x lsr 8; r := !r + 8);
  if !x lsr 4 <> 0 then (x := !x lsr 4; r := !r + 4);
  if !x lsr 2 <> 0 then (x := !x lsr 2; r := !r + 2);
  if !x lsr 1 <> 0 then r := !r + 1;
  !r

let index bits v =
  let sub = 1 lsl bits in
  if v < 2 * sub then v
  else
    let e = msb v - bits in
    let i = (2 * sub) + ((e - 1) * sub) + ((v lsr e) - sub) in
    let last = size bits - 1 in
    if i > last then last else i

(* the highest value a bucket holds *)
let upper bits i =
  let sub = 1 lsl bits in
  if i < 2 * sub then i
  else
    let e = ((i - (2 * sub)) / sub) + 1 and s = ((i - (2 * sub)) mod sub) + sub in
    ((s + 1) lsl e) - 1

let record h us =
  let us = if us < 0 then 0 else us in
  let i = index h.bits us and c = counts h in
  c.(i) <- c.(i) + 1;
  h.total <- h.total + 1;
  h.sum <- h.sum + us;
  if us > h.max then h.max <- us

(* the total added is the sum of the counters read, not [src.total]: a reader that merges a histogram while its writer
   records (another domain: Timings) may read a total before or after the counter it goes with, and the percentiles
   of [dst] must walk to a counter that holds their value *)
let merge_into dst src =
  if dst.bits <> src.bits then invalid_arg "Histogram.merge_into: histograms of different precisions";
  let s = Atomic.get src.counts in
  if Array.length s > 0 then begin
    let d = counts dst and n = ref 0 in
    Array.iteri (fun i c -> d.(i) <- d.(i) + c; n := !n + c) s;
    dst.total <- dst.total + !n
  end;
  dst.sum <- dst.sum + src.sum;
  if src.max > dst.max then dst.max <- src.max

(* the value at or below which a fraction q of the values lie (q in 0..1) *)
let percentile h q =
  let c = Atomic.get h.counts in
  if h.total = 0 || Array.length c = 0 then 0
  else begin
    let want = max 1 (int_of_float (Float.ceil (q *. float h.total))) in
    let acc = ref 0 and i = ref 0 in
    while !acc + c.(!i) < want do acc := !acc + c.(!i); incr i done;
    (* the last bucket holds every value from its start on: the maximum is its bound *)
    if !i = size h.bits - 1 then h.max else min h.max (upper h.bits !i)
  end

(* for a writer that keeps its counters in an array of its own (Timings): the bucket of a value, the number of buckets,
   and counters added to a histogram (its total their sum) *)
let bucket ~bits v = index bits (if v < 0 then 0 else v)
let buckets ~bits = size bits

let add_buckets h (a : int array) off ~sum ~max:m =
  let d = counts h and n = ref 0 in
  for i = 0 to Array.length d - 1 do let c = Array.unsafe_get a (off + i) in d.(i) <- d.(i) + c; n := !n + c done;
  h.total <- h.total + !n;
  h.sum <- h.sum + sum;
  if m > h.max then h.max <- m

let total h = h.total
let max h = h.max
let sum h = h.sum
let mean h = if h.total = 0 then 0. else float h.sum /. float h.total
