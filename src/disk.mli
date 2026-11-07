(** The file system as the engine sees it. Every read and write of the engine goes through a [Disk.t], so that the
    same engine runs on the real disk and on {!Sim_disk}, a simulated disk that loses, tears and damages data on
    purpose. A file is durable only after [fsync]; a created, renamed or removed name is durable only after
    [sync_dir] of its directory. Every failure raises {!Io}. *)

type fd = int
(** An open file, a number given by the disk. *)

exception Io of string
(** A failed system call; the message names the call and the file. *)

type t = {
  exists : string -> bool;
  mkdir : string -> unit;
  readdir : string -> string list;  (** the names in a directory, sorted *)
  openf : string -> bool -> fd;  (** [openf path create]: read and write; [create] makes a missing file *)
  size : fd -> int;
  pread : fd -> int -> Bytes.t -> int -> int -> unit;  (** [pread fd off buf pos len]: exactly [len] bytes *)
  pwrite : fd -> int -> Bytes.t -> int -> int -> unit;  (** [pwrite fd off buf pos len] *)
  truncate : fd -> int -> unit;
  fsync : fd -> unit;
  close : fd -> unit;
  rename : string -> string -> unit;  (** atomic replacement of the target *)
  remove : string -> unit;
  sync_dir : string -> unit;  (** makes the names of a directory durable *)
  lock : string -> bool;  (** an exclusive lock on a file, held until [unlock] or the process ends *)
  unlock : string -> unit;
  now : unit -> int;  (** the time in milliseconds since 1970; simulated on {!Sim_disk} *)
}

val real : t
(** The machine's file system. Reads and writes go through [lseek] and [read] or [write]. *)

val read_all : t -> string -> Bytes.t
(** A whole file. *)

val write_file : t -> string -> Bytes.t -> unit
(** Writes a whole file durably and atomically: beside it, fsync, rename over, fsync of the directory. *)
