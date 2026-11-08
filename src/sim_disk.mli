(** A simulated disk for deterministic tests. It keeps, for every file, what a reader sees now and what is durable
    (covered by a finished fsync), and for every directory the names made durable by [sync_dir]. {!crash} plays a
    power loss: with draws from a seeded {!Rng.t}, each sector written since the last fsync is lost, kept, or torn
    inside the sector; a grown file keeps any length between its durable and its current size; the name changes of a
    directory since its last [sync_dir] survive only as a prefix, in order (as on a journaling file system). Faults
    of durable data (F3) and failing fsyncs (F4) are injected on demand. *)

type t

val create : Rng.t -> t
val disk : t -> Disk.t
(** The [Disk.t] that the engine uses. *)

val sector : int
(** 512 bytes: the unit of loss and of tearing. *)

exception Crash
(** Raised by a call of the disk when a planned crash point is reached: the process "dies" there. *)

val crash_after : t -> int -> unit
(** [crash_after t n]: the [n+1]-th mutating call from now raises {!Crash} instead of running. *)

type draw =
  | Names of string  (** how many of a directory's name changes since its last sync survive (a prefix) *)
  | Length of string  (** a grown file: its durable size (0), its current one (1), or a cut between (2, 3) *)
  | Cut of string  (** where, for a cut *)
  | Sector of string * int  (** a sector written since the last fsync: lost (0, 1), kept (2-4), torn (5) *)
  | Tear of string * int  (** how many bytes of a torn sector *)
(** The choices a power loss makes, each named by what it decides (a file by one of its paths at the crash). *)

val crash : ?choose:(draw -> int -> int) -> t -> unit
(** A power loss now: every open file is closed, every lock released, and the unsynced state resolved: at random, or
    by [choose d n] (a number in [0, n)) for each choice [d], in a fixed order, so that a test can enumerate the
    states a crash can leave. *)

val kill : t -> unit
(** The process dies, the machine stays up: files are closed and locks released, and what was written but not forced
    stays as it is (in the page cache), readable now and still to be lost at a later {!crash}. *)

val pending_names : t -> string -> int
(** The name changes of a directory since its last [sync_dir]. *)

val flip_durable : t -> string -> int -> int -> int option
(** [flip_durable t path lo hi] flips one random bit of the durable content of [path] at an offset in [lo, hi) (cut to
    the durable size): the offset, or None if there is no such byte. The change is silent: reads see it. *)

val fail_next_fsync : t -> unit
(** The next fsync fails with [Disk.Io]; as Linux does, the written pages are then marked clean without reaching the
    disk (Rebello et al., ATC 2020), so a later fsync would succeed without making them durable. *)

val advance : t -> int -> unit
(** Moves the simulated clock by some milliseconds. *)

val durable_size : t -> string -> int
(** The durable size of a file (0 if it has no durable name). *)

val files : t -> string list
(** The current paths of all files. *)

val durable_bytes : t -> string -> Bytes.t
(** The durable content of a file. *)
