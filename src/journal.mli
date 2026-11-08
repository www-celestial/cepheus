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

val window : int ref
(** The bytes of a segment a scan holds at once (4 MiB; tests make it small, 40 at least): a frame that fits is decoded
    where it lies, a longer one checked by pieces and read whole only to be decoded. *)

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

type pending
(** A frame being written by pieces (a large group's): its place in the journal is taken, its header not yet written.
    Nothing else may append to the journal until it is finished or dropped. *)

val begin_frame : t -> int -> int -> int -> pending
(** [begin_frame j len first count]: the place of a frame of [len] body bytes holding [count] groups from [first], at
    the end of the journal or at the start of a new segment (made now, with its header forced, when the current
    segment would pass {!segment_limit}). Raises [Disk.Io]. *)

val force_every : int ref
(** The body's pieces are forced every this many bytes (32 MiB), so that the disk writes them while the group is
    merged. *)

val body : pending -> Bytes.t -> int -> int -> unit
(** [body p buf off n]: the next [n] bytes of the frame's body. *)

val finish : pending -> unit
(** The frame made whole and durable: its header, then its trailer, then an fsync; the journal ends after it. A
    failure of [body] or [finish] raises [Disk.Io] after cutting the journal back to its last durable frame, as
    {!append} does, and the journal refuses every write after it. *)

val drop : pending -> unit
(** The frame's pieces removed from the file (its segment, when it began one), forced: the journal is as before
    {!begin_frame}. Raises [Disk.Io] as {!finish}. *)

val written_body : pending -> Bytes.t
(** The body's bytes written so far, read back from the file: for the simulation, which checks every group. *)

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

val read_after : Disk.t -> string -> string -> int -> (Group.t -> unit) -> unit
(** [read_after disk dir id n f]: [f] on every group after [n], in order, from the segment that holds group [n + 1]
    (the frames before it checked by their CRCs, not decoded), without changing a file; raises {!Damaged}. *)

val convert : Disk.t -> string -> string -> int
(** [convert disk dir id]: every segment of format 1 (a change after the other) rewritten in format 2 (groups in
    columns), its frames as they were, each segment written beside, forced and renamed over the old one, the directory
    forced; a frame that does not check is a torn tail in the newest segment (cut) and damage elsewhere ({!Damaged}).
    Run once at open, before anything reads the journal; returns the number of segments converted. *)
