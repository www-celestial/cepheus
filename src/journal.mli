(** The journal of one database: segment files, only ever appended to, each a header and then frames. A frame is one
    group commit: the groups that arrived while the previous fsync ran, written with one write and made durable with
    one fsync.

    {v
    segment = header 40 B: magic "CPHJ" | format | database id (16 B) | first group u64 | 0 | crc32c
            | frames
    frame   = header 28 B: magic "CPHF" | body length u32 | first group u64 | count u32 | body crc u32 | header crc u32
            | body: the groups
            | trailer 16 B: body length u32 | body crc u32 | header crc u32 | magic "CPHT"
    v}

    Recovery reads the frames in order. At the first frame that does not check, it decides between a torn tail
    (written during a crash, never acknowledged: cut off) and damage (refuse to open, never drop): a valid frame after
    it, or a trailer in its place (the frame was written whole), means damage. See [docs/guarantees.md], G1-G3, G6. *)

exception Damaged of string
(** The journal has lost or changed data it had made durable. The message says where. *)

type position = {
  segment : int;  (** the first group of the segment *)
  offset : int;
  next : int;  (** the group of the frame at [offset] *)
}

type t

val segment_limit : int ref
(** A new segment starts once a segment passes this size (64 MB; tests make it small). *)

val create : Disk.t -> string -> string -> t
(** [create disk dir id]: a new journal in [dir] (which exists), for the database [id]; the first group is 1. *)

val recover : Disk.t -> string -> string -> position option -> (Group.t -> unit) -> t
(** [recover disk dir id from on_group]: reads the journal from [from] (the start without it), calls [on_group] on
    each group in order, cuts a torn tail durably, and returns the journal ready to append. Raises {!Damaged}. *)

val append : t -> Buffer.t -> int -> int -> unit
(** [append j body first count]: one frame of [count] groups from [first], written and made durable. Raises
    [Disk.Io]; after that the journal must not be used again (the database stops). *)

val next_group : t -> int
val position : t -> position
(** Where the next frame goes. *)

val close : t -> unit

val verify : Disk.t -> string -> string -> int
(** Reads every segment from the start and checks every frame: the number of groups, or {!Damaged}. *)

val read : Disk.t -> string -> string -> (Group.t -> unit) -> unit
(** Every group of the journal, in order, without changing a file; raises {!Damaged}. *)

val segment_name : int -> string
