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

val max_body : int
(** The largest frame body, in bytes (256 MiB): recovery takes a longer length field for damage. *)

val segment_limit : int ref
(** A new segment starts once a segment passes this size (64 MB; tests make it small). *)

val create : Disk.t -> string -> string -> t
(** [create disk dir id]: a new journal in [dir] (which exists), for the database [id]; the first group is 1. *)

val recover :
  ?frame:(position -> unit) -> ?after:int -> force:bool -> Disk.t -> string -> string -> position option ->
  (Group.t -> unit) -> t
(** [recover ~force disk dir id from on_group]: reads the journal from [from] (the start without it), calls [frame] on
    the position of each frame and [on_group] on each of its groups, in order (but for the frames whose groups are all
    [after] or before, checked by their CRCs and not decoded), cuts a torn tail durably, and returns
    the journal ready to append. With [force] (after anything but a clean close), before replaying a group of the
    newest segment, it writes that segment's newest frame again (its header if it holds no frame), forces the segment
    and the directory: what a killed process wrote but did not force, or what a failed fsync left in the page cache
    but not on the disk, is on the disk before anything rests on it (G5, G13). Raises {!Damaged}, or [Disk.Io]. *)

val append : t -> Buffer.t -> int -> int -> unit
(** [append j body first count]: one frame of [count] groups from [first], written and made durable. Raises
    [Disk.Io], after cutting the journal back to the end of its last durable frame (forced; a failure of the cut is
    reported on stderr); after that the journal refuses every append (the database stops, G10, G13). *)

val next_group : t -> int
val position : t -> position
(** Where the next frame goes. *)

val close : t -> unit

val verify : Disk.t -> string -> string -> int
(** Reads every segment from the start and checks every frame: the number of groups, or {!Damaged}. *)

val read : Disk.t -> string -> string -> (Group.t -> unit) -> unit
(** Every group of the journal, in order, without changing a file; raises {!Damaged}. *)

val segment_name : int -> string

val write_us : Histogram.t
val fsync_us : Histogram.t
(** Where the time of each append went, in microseconds (the pwrite of the frame, then its fsync): for the
    benchmarks. *)

val clock : unit -> int
(** The time in microseconds. *)
