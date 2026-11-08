(** A group: the resolved effects of one write, with who, when and why. It is the event: what the journal keeps,
    what replay applies, what replicas copy. Effects are resolved: an [Add] that replaced an old value is written as a
    retraction and an addition, and the facts the rules derive are written beside the asserted ones, so replay never
    recomputes anything, never evaluates a rule. *)

(** What a change does to its fact; the journal's kind byte is the number. *)
type kind =
  | Retracted  (** 0: an asserted fact retracted: it is gone *)
  | Added  (** 1: a fact asserted that was not there *)
  | Derived  (** 2: a fact a rule derives that was not there *)
  | Underived  (** 3: a derived fact that has no proof any more: it is gone *)
  | Now_asserted  (** 4: a fact derived already, now asserted too *)
  | Now_derived  (** 5: an asserted fact retracted that a rule still derives: it stays, only derived *)

type change = { kind : kind; e : int; p : int; v : Value.t }

val code : kind -> int
val of_code : int -> kind option

val after : kind -> int
(** The state a change leaves its fact in: 0 absent, 1 asserted, 2 only derived. *)

val present : change -> bool
(** The fact is there after the change. *)

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
