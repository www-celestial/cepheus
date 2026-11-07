(* Durations in microseconds, counted in log-linear buckets as HdrHistogram does (Tene): exact below 256, then 128
   buckets per power of two, so a recorded value is known within 1/128 (0.8 %) and a percentile costs one walk of
   about 3,500 counters, whatever the number of values. One writer at a time; readers may read while it writes. *)

let sub = 128
let size = (2 * sub) + (26 * sub)

type t = { counts : int array; mutable total : int; mutable max : int; mutable sum : int }

let create () = { counts = Array.make size 0; total = 0; max = 0; sum = 0 }

let msb x = let r = ref 0 and x = ref x in while !x > 1 do x := !x lsr 1; incr r done; !r

let index v =
  if v < 2 * sub then v
  else
    let e = msb v - 7 in
    min (size - 1) ((2 * sub) + ((e - 1) * sub) + ((v lsr e) - sub))

(* the highest value a bucket holds *)
let upper i =
  if i < 2 * sub then i
  else
    let e = ((i - (2 * sub)) / sub) + 1 and s = ((i - (2 * sub)) mod sub) + sub in
    ((s + 1) lsl e) - 1

let record h us =
  let us = max 0 us in
  let i = index us in
  h.counts.(i) <- h.counts.(i) + 1;
  h.total <- h.total + 1;
  h.sum <- h.sum + us;
  if us > h.max then h.max <- us

let merge_into dst src =
  Array.iteri (fun i c -> dst.counts.(i) <- dst.counts.(i) + c) src.counts;
  dst.total <- dst.total + src.total;
  dst.sum <- dst.sum + src.sum;
  dst.max <- max dst.max src.max

(* the value at or below which a fraction q of the values lie (q in 0..1) *)
let percentile h q =
  if h.total = 0 then 0
  else begin
    let want = max 1 (int_of_float (Float.ceil (q *. float h.total))) in
    let acc = ref 0 and i = ref 0 in
    while !acc + h.counts.(!i) < want do acc := !acc + h.counts.(!i); incr i done;
    min h.max (upper !i)
  end


let total h = h.total
let max h = h.max
let mean h = if h.total = 0 then 0. else float h.sum /. float h.total
