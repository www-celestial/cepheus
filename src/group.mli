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

(** What the journal's coding reads of a group's changes: from {!t}'s array, or from a large group's arrays
    (Resolve.encode_large), so that both write the same bytes. [col i] is change i's column, in order of first use,
    whose (property, tag) [cols] lists (the tag is the value's constructor, as {!Value.encode}'s byte, both booleans
    2); [num i] the number its value is coded by (the int of an Int, a Date, a Money or a Link, 0 or 1 for a Bool, the
    place of a Text in [texts]); [float i] the bits of a Float. *)
type source = {
  count : int;
  kinds : int -> int;
  things : int -> int;
  col : int -> int;
  cols : (int * int) array;
  num : int -> int;
  float : int -> int64;
  texts : string array;  (** the group's texts, each once, in order of first use *)
}

val encode_source : Buffer.t -> n:int -> time:int -> by:int -> why:string -> first_new:int -> count_new:int -> source -> unit

val encode : Buffer.t -> t -> unit
(** The journal's coding of a group (format 2, docs/book/formats.md): its header, its texts once each, then its changes
    in columns, in their order. *)

val decode : Codec.reader -> t
(** Raises {!Codec.Short} on bytes that are not a group. *)

val decode_v1 : Codec.reader -> t
(** The coding of journal format 1 (a change after the other), read only to convert such a journal once. *)
val equal : t -> t -> bool
