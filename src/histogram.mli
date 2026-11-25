(** Latencies in microseconds, counted in log-linear buckets as HdrHistogram does (Tene): exact below 2 x 2^bits,
    then 2^bits buckets per power of two up to 2^34 us (4.8 hours; a longer value is counted in the last bucket, the
    maximum kept exact), so every percentile is known within 1/2^bits: with the default 7 bits, 128 buckets a power
    (0.8 %) and a fixed memory of 3,584 counters whatever the number of values; with 5 bits, 3.1 % and 960 counters.
    The counters are made at the first value. One writer per histogram; merge the histograms of several writers at the
    end, or while they write (the total merged is the sum of the counters read). *)

type t

val create : ?bits:int -> unit -> t
(** [bits] from 1 to 7 (7 by default): 2^bits buckets per power of two, a relative error of 1/2^bits at most. *)

val record : t -> int -> unit
val merge_into : t -> t -> unit
(** [merge_into dst src] adds the counts of [src] to [dst], of the same [bits]. *)

val percentile : t -> float -> int
(** [percentile h q] is the value at or below which a fraction [q] (0..1) of the values lie, rounded up to its
    bucket's highest value (never above the largest value recorded; the largest one in the last bucket, past 2^34 us);
    0 when [h] is empty. *)

val total : t -> int
val max : t -> int
val sum : t -> int
val mean : t -> float

external now_us : unit -> int = "cepheus_monotonic_us" [@@noalloc]
(** The monotonic clock (CLOCK_MONOTONIC: a change of the wall clock does not move it), in microseconds: an int, no
    allocation, about 20 ns. *)
