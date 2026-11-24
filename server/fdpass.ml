(* Open files passed between processes over a Unix-domain socket, and a page of shared memory read in place
   (server/fdpass_stubs.c: sendmsg and recvmsg with SCM_RIGHTS, unix(7); mmap read-only and shared). The server
   passes a local reader the run files of a database and its visibility page, so that the reader needs no right on
   the data directory: the server decides, after the token's check, what it may read (G16). *)

type page = (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t

external send_ : Unix.file_descr -> Bytes.t -> int -> int -> Unix.file_descr array -> int = "cepheus_fd_send"
external recv_ : Unix.file_descr -> Bytes.t -> int -> int -> int * Unix.file_descr array = "cepheus_fd_recv"
external map_ro_ : Unix.file_descr -> int -> page = "cepheus_fd_map_ro"

(* the monotonic clock, in milliseconds (Raft's timeouts and leases: a change of the wall clock does not move it) *)
external monotonic_ms : unit -> int = "cepheus_monotonic_ms" [@@noalloc]

(* the bytes this process may still write on the file system that holds [path] (statvfs: Unix.Unix_error) *)
external free_bytes : string -> int = "cepheus_free_bytes"

let max_fds = 64

let range what b ofs len = if ofs < 0 || len < 0 || ofs > Bytes.length b - len then invalid_arg ("Fdpass." ^ what)

(* All [len] bytes from [ofs] on a socket, sent with MSG_NOSIGNAL: a write to a connection the peer closed fails with
   EPIPE instead of raising SIGPIPE, so a client needs no change to the process's signals (the Cesia client runs in a
   program's process, whose signals are not its own). *)
let write_all sock b ofs len =
  range "write_all" b ofs len;
  let rec go o n = if n > 0 then let k = send_ sock b o n [||] in go (o + k) (n - k) in
  go ofs len

(* All [len] bytes from [ofs], the descriptors [fds] riding on the first byte; the kernel gives each a new
   descriptor in the receiver, for the same open file. *)
let send sock b ofs len fds =
  range "send" b ofs len;
  if List.length fds > max_fds then invalid_arg "Fdpass.send: more than 64 descriptors";
  if len = 0 && fds <> [] then invalid_arg "Fdpass.send: descriptors need a byte to ride on";
  if len > 0 then begin
    let k = send_ sock b ofs len (Array.of_list fds) in
    write_all sock b (ofs + k) (len - k)
  end

(* At most [len] bytes into [ofs], and the descriptors that came with them, in their order (close-on-exec); 0 bytes
   at the end of the stream. *)
let recv sock b ofs len =
  range "recv" b ofs len;
  if len = 0 then invalid_arg "Fdpass.recv: no room";
  let n, fds = recv_ sock b ofs len in
  n, Array.to_list fds

let page_size = 4096

(* The first page of the file of [fd], mapped read-only and shared: what the server stores in it is read at once. One
   mapping a file for the process (by device and inode), never unmapped: a reader that follows the same database
   again reads the same page. *)
let pages : (int * int, page) Hashtbl.t = Hashtbl.create 4
let pm = Mutex.create ()

let map_page fd =
  let st = Unix.fstat fd in
  if st.st_size < page_size then failwith "Fdpass.map_page: the file is shorter than a page";
  Mutex.protect pm (fun () ->
      let k = st.st_dev, st.st_ino in
      match Hashtbl.find_opt pages k with
      | Some p -> p
      | None ->
        let p = map_ro_ fd page_size in
        Hashtbl.replace pages k p;
        p)

(* the page's first word: a plain load *)
let[@inline] word (p : page) = Int64.to_int (Bigarray.Array1.unsafe_get p 0)
