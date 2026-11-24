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
    it, or a trailer in its place (the frame was written whole), means damage. A segment's header is forced before any
    frame: one that does not check is a segment torn at its creation (removed) only in the newest segment, no longer
    than its header, where no run resumes; elsewhere it is damage. See [docs/book/guarantees.md], G1-G3, G6. *)

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
  ?frame:(position -> unit) -> ?after:int -> ?copy:Bytes.t list -> ?cut:int -> force:bool -> Disk.t -> string -> string ->
  position option -> (Group.t -> unit) -> t
(** [recover ~force disk dir id from on_group]: reads the journal from [from] (the start without it), calls [frame] on
    the position of each frame and [on_group] on each of its groups, in order (but for the frames whose groups are all
    [after] or before, checked by their CRCs and not decoded), cuts a torn tail durably, and returns
    the journal ready to append. With [force] (after anything but a clean close), before replaying a group of the
    newest segment, it writes that segment's newest frame again (its header if it holds no frame), forces the segment
    and the directory: what a killed process wrote but did not force, or what a failed fsync left in the page cache
    but not on the disk, is on the disk before anything rests on it (G5, G13). [copy]: the frames the server's commit
    buffer holds for this journal (whole, oldest first: {!Wal}), written again where they go before the read, and
    forced; between them, every frame the journal holds must check (it was forced). [cut]: a Raft cluster's journal,
    whose frames from this group on are removed once [copy] is written (applied again from the Raft log once their
    commit is known: server/cluster.ml). Raises {!Damaged}, or [Disk.Io]. *)

val frame_bytes : Buffer.t -> int -> int -> Bytes.t
(** [frame_bytes body first count]: the frame [append] writes, whole (header, body, trailer). *)

val frame_parts : Bytes.t -> (int * int * Bytes.t) option
(** A whole frame's first group, count and body, if its header, body and trailer check (a frame from a peer). *)

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

val share : t -> (Bytes.t -> bool) -> (unit -> unit) -> unit
(** [share j give own_done]: from now on, an append writes its frame without an fsync and gives its bytes to [give],
    which returns true once they are durable (the server's commit buffer forced them: {!Wal}), or false at once: the
    journal forces the frame itself, then calls [own_done]; or raises [Disk.Io]. A frame longer than {!shared_max} is
    forced in the journal. The journal is forced by {!checkpoint}, when a segment is left, by a
    frame forced in it, and by {!close}. *)

val shared_max : int ref
(** The longest frame a shared journal gives to the commit buffer (1 MiB). *)

val checkpoint : t -> unit
(** Forces what a shared journal wrote since its last fsync. Raises [Disk.Io], after which the journal refuses every
    append (G10). *)

val forced : t -> bool
(** Nothing written is waiting for an fsync, and no write or fsync failed. *)

val next_group : t -> int
val position : t -> position
(** Where the next frame goes. *)

val close : t -> unit
(** Forces a shared journal first; a failure of that fsync is raised ([Disk.Io]) once the file is closed. *)

val verify : Disk.t -> string -> string -> int
(** Reads every segment from the start and checks every frame: the number of groups, or {!Damaged}. *)

(** {2 The journal checked as files: cepheus verify, backup and restore} *)

(** What the end of the newest segment may hold: [Strict] for a database closed cleanly or a copy cut and forced
    (every byte checks); [Crash] after a process died (a torn frame with nothing written after it, the newest frame's
    trailer alone broken, the newest segment torn at its creation: what recovery cuts or rebuilds); [Copy] for a
    database being written or the files copied from one (from the newest segment's first frame that does not check
    whole, everything is the frame being written). *)
type tail = Strict | Crash | Copy

type segment_check = {
  sfirst : int;  (** the segment's first group, from its name *)
  sbytes : int;  (** its size *)
  sframes : int;  (** its whole frames *)
  slast : int;  (** the last group of its whole frames ([sfirst - 1]: none) *)
  send : int;  (** where its last whole frame ends (0: its header did not check) *)
  stail : bool;  (** bytes after [send] that the rule takes for the frame being written *)
  sdamage : string option;  (** the first damage, which ended the segment's check *)
}

type check = {
  segments : segment_check list;  (** in the order of their names *)
  damages : string list;  (** each segment's first damage, and the segments missing between them *)
  last : int;  (** the newest group of the frames that check from group 1 on, with no damage before it *)
}

val decode_max : int ref
(** Frames whose body is at most this long (16 MiB) have their groups decoded and numbered by {!check}; a longer one
    (a large load's) is checked by its CRCs. *)

val check :
  ?domains:int -> ?frame:(position -> int -> int -> unit) -> ?on_group:(Group.t -> unit) -> tail:tail -> Disk.t -> string ->
  string -> check
(** [check ~tail disk dir id]: every segment checked on its own (on up to [domains] domains at once: the callbacks then
    run on several), each up to its first damage: its header, every frame's header, body CRC, trailer, first group and
    count, its groups decoded and numbered (up to {!decode_max}); then the segments' order. [frame pos count stop] on
    each whole frame, [on_group] on each decoded group. Never changes a file. *)

val times : Disk.t -> string -> string -> (int -> int -> bool) -> unit
(** [times disk dir id f]: [f n time] on every group in order, from the start, each frame checked by its CRCs, until
    [f] returns false or a frame does not check (a large group's frame: only its head read). *)

val cut_after : Disk.t -> string -> string -> int -> bool
(** [cut_after disk dir id n] on a copy of a journal: ends it after group [n] (the frame that holds [n] coded again
    without the groups after it, at the same place; the segment that begins at [n + 1] kept as its header alone; later
    ones removed), forced. False, nothing changed, when no frame that checks holds [n]. *)

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

type cursor
(** Where a reader of the frames as they are stands (a replica's sender): before the frame that holds a group. *)

val cursor : Disk.t -> string -> string -> next:int -> cursor
(** [cursor disk dir id ~next]: before the frame that holds group [next] (its first group may be before [next]), or at
    the journal's end when no frame holds it yet. The frames before it are passed over by their headers. *)

val cursor_next : cursor -> int
(** The first group of the next frame the cursor gives. *)

val frames : ?limit:int -> cursor -> upto:int -> (first:int -> count:int -> crc:int -> Bytes.t -> int -> unit) -> unit
(** [frames c ~upto f]: [f ~first ~count ~crc body len] on each frame from the cursor up to the one that holds group
    [upto] (at most [limit] frames), which must be durable (every group up to it is whole in the files), in order, across segments; [body] holds
    the frame's [len] bytes, checked by their CRC [crc], until the next call. Raises {!Damaged} when a durable frame
    does not check or is missing, and [Disk.Io]. *)

val cursor_close : cursor -> unit
