(** A group: the resolved effects of one write, with who, when and why. It is the event: what the journal keeps,
    what replay applies, what replicas copy. Effects are resolved: an [Add] that replaced an old value is written as a
    retraction and an addition, so replay never recomputes anything. *)

type change = { add : bool; e : int; p : int; v : Value.t }

type t = {
  n : int;  (** the group number: 1, 2, 3... without gaps *)
  time : int;  (** the database's clock, milliseconds *)
  by : int;  (** who, as the application names it *)
  why : string;
  first_new : int;  (** the first thing id this group made *)
  count_new : int;  (** how many thing ids it made, from [first_new] on *)
  changes : change array;
}

val encode : Buffer.t -> t -> unit
val decode : Codec.reader -> t
val equal : t -> t -> bool
