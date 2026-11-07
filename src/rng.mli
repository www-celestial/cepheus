(** A small seeded random generator (SplitMix64): the same seed gives the same sequence everywhere. The simulated disk
    and every randomized test draw from it, so that a failing seed replays exactly. *)

type t

val make : int -> t
val copy : t -> t
val next : t -> int
val int : t -> int -> int  (** [int r n] in [0, n) *)
val bool : t -> bool
val chance : t -> float -> bool  (** [chance r p] is true with probability [p] *)
val pick : t -> 'a array -> 'a
val split : t -> t  (** an independent generator drawn from this one *)
