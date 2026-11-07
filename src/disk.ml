type fd = int

exception Io of string

type t = {
  exists : string -> bool;
  mkdir : string -> unit;
  readdir : string -> string list;
  openf : string -> bool -> fd;
  size : fd -> int;
  pread : fd -> int -> Bytes.t -> int -> int -> unit;
  pwrite : fd -> int -> Bytes.t -> int -> int -> unit;
  truncate : fd -> int -> unit;
  fsync : fd -> unit;
  close : fd -> unit;
  rename : string -> string -> unit;
  remove : string -> unit;
  sync_dir : string -> unit;
  lock : string -> bool;
  unlock : string -> unit;
  now : unit -> int;
}

(* ---- The real file system ---- *)

let table : (int, Unix.file_descr * string) Hashtbl.t = Hashtbl.create 16
let next = ref 1
let m = Mutex.create ()
let locks : (string, Unix.file_descr) Hashtbl.t = Hashtbl.create 4
let locked f = Mutex.protect m f

let unix name path f =
  try f () with Unix.Unix_error (e, _, _) -> raise (Io (Printf.sprintf "%s %s: %s" name path (Unix.error_message e)))

let get fd =
  match locked (fun () -> Hashtbl.find_opt table fd) with
  | Some x -> x
  | None -> raise (Io (Printf.sprintf "file %d is closed" fd))

let rec write_all ufd buf pos len path =
  if len > 0 then begin
    let n = unix "write" path (fun () -> Unix.write ufd buf pos len) in
    write_all ufd buf (pos + n) (len - n) path
  end

let rec read_exact ufd buf pos len path =
  if len > 0 then begin
    let n = unix "read" path (fun () -> Unix.read ufd buf pos len) in
    if n = 0 then raise (Io ("read " ^ path ^ ": short file"));
    read_exact ufd buf (pos + n) (len - n) path
  end

let take_lock p =
  locked (fun () ->
      if Hashtbl.mem locks p then false
      else begin
        let ufd = Unix.openfile p [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_CLOEXEC ] 0o644 in
        match Unix.lockf ufd Unix.F_TLOCK 0 with
        | () ->
          Hashtbl.replace locks p ufd;
          true
        | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EACCES), _, _) ->
          Unix.close ufd;
          false
      end)

let real =
  {
    exists = Sys.file_exists;
    mkdir = (fun p -> unix "mkdir" p (fun () -> Unix.mkdir p 0o755));
    readdir = (fun p -> unix "readdir" p (fun () -> List.sort compare (Array.to_list (Sys.readdir p))));
    openf =
      (fun p create ->
        let flags = Unix.O_RDWR :: Unix.O_CLOEXEC :: (if create then [ Unix.O_CREAT ] else []) in
        let ufd = unix "open" p (fun () -> Unix.openfile p flags 0o644) in
        locked (fun () ->
            let fd = !next in
            incr next;
            Hashtbl.replace table fd (ufd, p);
            fd));
    size =
      (fun fd ->
        let ufd, p = get fd in
        unix "fstat" p (fun () -> (Unix.fstat ufd).Unix.st_size));
    pread =
      (fun fd off buf pos len ->
        let ufd, p = get fd in
        ignore (unix "lseek" p (fun () -> Unix.lseek ufd off Unix.SEEK_SET));
        read_exact ufd buf pos len p);
    pwrite =
      (fun fd off buf pos len ->
        let ufd, p = get fd in
        ignore (unix "lseek" p (fun () -> Unix.lseek ufd off Unix.SEEK_SET));
        write_all ufd buf pos len p);
    truncate =
      (fun fd n ->
        let ufd, p = get fd in
        unix "ftruncate" p (fun () -> Unix.ftruncate ufd n));
    fsync =
      (fun fd ->
        let ufd, p = get fd in
        unix "fsync" p (fun () -> Unix.fsync ufd));
    close =
      (fun fd ->
        let ufd, p = get fd in
        locked (fun () -> Hashtbl.remove table fd);
        unix "close" p (fun () -> Unix.close ufd));
    rename = (fun a b -> unix "rename" a (fun () -> Unix.rename a b));
    remove = (fun p -> unix "unlink" p (fun () -> Unix.unlink p));
    sync_dir =
      (fun p ->
        unix "fsync" p (fun () ->
            let d = Unix.openfile p [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
            Fun.protect ~finally:(fun () -> Unix.close d) (fun () -> Unix.fsync d)));
    lock = (fun p -> unix "lock" p (fun () -> take_lock p));
    unlock =
      (fun p ->
        locked (fun () ->
            match Hashtbl.find_opt locks p with
            | Some ufd ->
              Hashtbl.remove locks p;
              (try Unix.close ufd with Unix.Unix_error _ -> ())
            | None -> ()));
    now = (fun () -> int_of_float (Unix.gettimeofday () *. 1000.));
  }

let read_all d path =
  let fd = d.openf path false in
  Fun.protect ~finally:(fun () -> d.close fd) (fun () ->
      let n = d.size fd in
      let b = Bytes.create n in
      d.pread fd 0 b 0 n;
      b)

let write_file d path b =
  let tmp = path ^ ".tmp" in
  if d.exists tmp then d.remove tmp;
  let fd = d.openf tmp true in
  Fun.protect ~finally:(fun () -> d.close fd) (fun () ->
      d.truncate fd 0;
      d.pwrite fd 0 b 0 (Bytes.length b);
      d.fsync fd);
  d.rename tmp path;
  d.sync_dir (Filename.dirname path)
