(** The server's commit buffer: one forced log for every database of a server, so that the databases written at
    once share one fsync a round, as the databases of PostgreSQL share its WAL.

    {v
    DATA/server.wal.1, DATA/server.wal.2   two files that alternate
    file  = header 40 B: magic "CPHW" | format u32 (1) | generation u64 | 20 zero bytes | crc32c of the 36 before
          | rounds
    round = header 28 B: magic "CPHR" | body length u32 | round u64 (0, 1, ... in its file) | entries u32
                         | body crc u32 | header crc u32
          | body: entries, each: database id (16 B) | length u32 | a frame of that database's journal, whole
          | trailer 16 B: body length u32 | body crc u32 | header crc u32 | magic "CPHT"
    v}

    A database's journal writes each frame without an fsync and gives it to the buffer ({!attach}); a round takes every
    frame that came meanwhile, is appended to the active file and forced once, and then each of its frames is durable.
    One round is in flight at a time. When the active file passes {!limit}, the other one, once each journal with
    frames in it has been forced ({!clean}), is emptied and takes the next rounds. Recovery ({!recover}) reads both
    files and gives each database the frames they hold, which its open writes again into its journal
    ([Journal.recover ~copy]); then {!start} empties both before anything new is written. The model:
    [spec/CommitBuffer.tla]. *)

type t

val limit : int ref
(** A file's size after which the next round goes to the other file, once it is clean (64 MB; tests make it small). *)

val names : string array
(** [server.wal.1], [server.wal.2]. *)

val recover : ?manual:bool -> Disk.t -> string -> t
(** [recover disk data]: reads the two files of the data directory [data] (missing ones are empty). At the first
    round that does not check in the newer file, a torn tail if no round written whole follows (the round in flight
    at the crash, never confirmed); anything else that does not check is damage: raises [Journal.Damaged]. With
    [manual] (the simulation), no thread runs: {!commit} performs {!Wait}, and the test calls {!round} and {!clean}. *)

val frames : t -> string -> Bytes.t list
(** [frames t id]: the frames held for the database [id], oldest first (each a frame of its journal, whole). *)

val start : t -> unit
(** Every database whose frames the files held was opened (its journal holds them now, forced): both files are
    emptied, forced, and the rounds start. Raises [Journal.Damaged] when the files hold frames of a database that
    was not opened (they would be lost), or [Disk.Io]. *)

val attach : t -> string -> Journal.t -> unit
(** [attach t id j]: the journal of database [id] shares the buffer from now on ([Journal.share]). *)

val alone : bool ref
(** A frame that comes when the buffer is idle (no round written or waiting) and no journal is forcing one of its own
    is forced in its own journal (true by default; the tests draw it): a database written alone pays no second
    write. *)

type _ Effect.t += Wait : unit Effect.t
(** Performed by a commit of a [manual] buffer: the simulation resumes it after a {!round}. *)

val round : t -> unit
(** The frames that came, as one round, written and forced (the thread of a buffer that is not [manual]). *)

val clean : t -> unit
(** Forces every journal with frames in the file that is not active, so that it may be emptied. A failure stops the
    buffer: every later write fails (G10). *)

val stopped : t -> string option
(** Why the buffer stopped: a write or fsync of its file, or a journal's at {!clean}, failed. *)

val stop : t -> unit
(** After every database is closed: the thread ends; both files are emptied if every journal attached is forced. *)

val status : t -> (string * string) list
(** The rounds, the frames they forced, and the frames forced in their own journal since the start, for the server's
    status. *)
