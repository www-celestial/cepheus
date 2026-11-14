(** Latencies in microseconds, counted in log-linear buckets as HdrHistogram does (Tene): exact below 256, then 128
    buckets per power of two, so every percentile is known within 1/128 (0.8 %), with a fixed memory of 3,584 counters
    whatever the number of values, made at the first value. One writer per histogram; merge the histograms of several
    writers at the end. *)

type t

val create : unit -> t
val record : t -> int -> unit
val merge_into : t -> t -> unit
(** [merge_into dst src] adds the counts of [src] to [dst]. *)

val percentile : t -> float -> int
(** [percentile h q] is the value at or below which a fraction [q] (0..1) of the values lie, rounded up to its
    bucket's highest value (never above the largest value recorded); 0 when [h] is empty. *)

val total : t -> int
val max : t -> int
val mean : t -> float
