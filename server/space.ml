(* What a server's data takes on its disk, for cepheus status: the file system's free bytes and size (statvfs), and a
   database's journal and runs. Read when status asks, never kept: a readdir and a stat a file (a journal's segments
   are of 64 MiB, so 16 a GiB), no lock of the server held. *)

external statvfs : string -> int * int = "cepheus_statvfs"

(* the bytes free for the server's user, and the size, of the file system that holds [dir]; (0, 0) when it cannot be
   read *)
let room dir = try statvfs dir with Unix.Unix_error _ -> 0, 0

(* the bytes of the files of [dir] whose names end with [suffix] (files that go meanwhile, a merge's, are left out) *)
let bytes_of dir suffix =
  match Sys.readdir dir with
  | names ->
    Array.fold_left
      (fun n f -> if Filename.check_suffix f suffix then (match Unix.stat (Filename.concat dir f) with st -> n + st.st_size | exception Unix.Unix_error _ -> n) else n)
      0 names
  | exception Sys_error _ -> 0

let server_lines data =
  let free, size = room data in
  [ "disk.free_bytes", string_of_int free; "disk.size_bytes", string_of_int size ]

(* a database's: its journal's segments, its runs, and the merges its engine installed since the open *)
let database_lines dir (e : Cepheus.Engine.t) =
  [ "journal_bytes", string_of_int (bytes_of (Filename.concat dir "journal") ".seg");
    "runs_bytes", string_of_int (bytes_of (Filename.concat dir "snapshots") ".run");
    "merges", string_of_int (Atomic.get e.merged_runs); "merge_us_sum", string_of_int (Atomic.get e.merged_us);
    "merge_bytes", string_of_int (Atomic.get e.merged_bytes) ]
