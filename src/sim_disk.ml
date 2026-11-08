let sector = 512

type inode = {
  mutable cur : Bytes.t;  (* what reads see; [cur_len] bytes are valid *)
  mutable cur_len : int;
  mutable dur : Bytes.t;  (* what survives a crash for sure *)
  mutable dur_len : int;
  dirty : (int, unit) Hashtbl.t;  (* sectors written since the last fsync *)
  lost : (int, unit) Hashtbl.t;
      (* sectors a failed fsync marked clean: reads see their new bytes, the disk may not have them, and no later
         fsync writes them unless they are written again; a power loss resolves them as it does dirty ones *)
}

type nsop = Link of string * int | Unlink of string | Mkdir of string

type t = {
  rng : Rng.t;
  mutable names : (string, int) Hashtbl.t;  (* current path -> inode *)
  mutable dnames : (string, int) Hashtbl.t;  (* durable path -> inode *)
  mutable dirs : (string, unit) Hashtbl.t;
  mutable ddirs : (string, unit) Hashtbl.t;
  pending : (string, nsop list) Hashtbl.t;  (* per directory, newest first, since its last sync_dir *)
  inodes : (int, inode) Hashtbl.t;
  mutable next_inode : int;
  fds : (int, int * string) Hashtbl.t;
  mutable next_fd : int;
  locks : (string, unit) Hashtbl.t;
  mutable fail_in : int;  (* fsyncs left before one fails; -1: none planned *)
  mutable then_crash : int;  (* the crash planned when it fails, as for [crash_after]; -1: none *)
  mutable failures : int;  (* fsyncs failed so far *)
  reverts : bool;  (* a failed fsync undoes the failed writes in memory too (Btrfs), rather than keeping them (ext4, XFS) *)
  mutable clock : int;
  mutable countdown : int;  (* mutating calls left before a crash; -1: none planned *)
}

exception Crash

let create ?(reverts = false) rng =
  let t =
    { rng; names = Hashtbl.create 16; dnames = Hashtbl.create 16; dirs = Hashtbl.create 8; ddirs = Hashtbl.create 8;
      pending = Hashtbl.create 8; inodes = Hashtbl.create 16; next_inode = 1; fds = Hashtbl.create 16; next_fd = 1;
      locks = Hashtbl.create 2; fail_in = -1; then_crash = -1; failures = 0; reverts; clock = 1_700_000_000_000; countdown = -1 }
  in
  Hashtbl.replace t.dirs "." ();
  Hashtbl.replace t.ddirs "." ();
  Hashtbl.replace t.dirs "/" ();
  Hashtbl.replace t.ddirs "/" ();
  t

let io fmt = Printf.ksprintf (fun s -> raise (Disk.Io s)) fmt
let parent p = Filename.dirname p

let note t dir op =
  let l = Option.value (Hashtbl.find_opt t.pending dir) ~default:[] in
  Hashtbl.replace t.pending dir (op :: l)

let inode t fd =
  match Hashtbl.find_opt t.fds fd with
  | Some (i, _) -> Hashtbl.find t.inodes i
  | None -> io "file %d is closed" fd

let ensure (n : inode) len =
  if Bytes.length n.cur < len then begin
    let b = Bytes.make (max len (2 * Bytes.length n.cur)) '\000' in
    Bytes.blit n.cur 0 b 0 n.cur_len;
    n.cur <- b
  end

(* a sector written again is dirty again, even one a failed fsync marked clean *)
let mark_dirty (n : inode) off len =
  if len > 0 then
    for s = off / sector to (off + len - 1) / sector do
      Hashtbl.replace n.dirty s ();
      Hashtbl.remove n.lost s
    done

let new_inode t =
  let i = t.next_inode in
  t.next_inode <- i + 1;
  Hashtbl.replace t.inodes i { cur = Bytes.create 0; cur_len = 0; dur = Bytes.create 0; dur_len = 0; dirty = Hashtbl.create 8; lost = Hashtbl.create 2 };
  i

let need_dir t p = if not (Hashtbl.mem t.dirs (parent p)) then io "no directory %s" (parent p)

let openf t p create =
  let i =
    match Hashtbl.find_opt t.names p with
    | Some i -> i
    | None ->
      if not create then io "open %s: no such file" p;
      need_dir t p;
      let i = new_inode t in
      Hashtbl.replace t.names p i;
      note t (parent p) (Link (p, i));
      i
  in
  let fd = t.next_fd in
  t.next_fd <- fd + 1;
  Hashtbl.replace t.fds fd (i, p);
  fd

let pwrite t fd off buf pos len =
  let n = inode t fd in
  if off > n.cur_len then begin
    ensure n off;
    Bytes.fill n.cur n.cur_len (off - n.cur_len) '\000';
    mark_dirty n n.cur_len (off - n.cur_len);
    n.cur_len <- off
  end;
  ensure n (off + len);
  Bytes.blit buf pos n.cur off len;
  if off + len > n.cur_len then n.cur_len <- off + len;
  mark_dirty n off len

let pread t fd off buf pos len =
  let n = inode t fd in
  if off < 0 || off + len > n.cur_len then io "read past the end";
  Bytes.blit n.cur off buf pos len

let truncate t fd len =
  let n = inode t fd in
  if len < n.cur_len then n.cur_len <- len
  else begin
    ensure n len;
    Bytes.fill n.cur n.cur_len (len - n.cur_len) '\000';
    mark_dirty n n.cur_len (len - n.cur_len);
    n.cur_len <- len
  end;
  (* a truncation is a change of the size: the sector it ends in counts as written *)
  mark_dirty n (max 0 (len - 1)) 1

(* A failed fsync, as Linux file systems do it (Rebello et al., ATC 2020, section 3.3): the written sectors are marked
   clean without reaching the disk. ext4 and XFS keep their new bytes in memory (reads see them until a reboot) and
   ext4 may make the new size durable over sectors never written (they read as zeros after a reboot); Btrfs undoes
   the failed writes in memory, size included. A successful fsync writes the dirty sectors and the size, nothing
   else: a sector marked clean stays off the disk until it is written again. *)
let fsync t fd =
  let n = inode t fd in
  if t.fail_in > 0 then t.fail_in <- t.fail_in - 1
  else if t.fail_in = 0 then begin
    t.fail_in <- -1;
    t.failures <- t.failures + 1;
    if t.then_crash >= 0 then (t.countdown <- t.then_crash; t.then_crash <- -1);
    if t.reverts then begin
      ensure n n.dur_len;
      Bytes.blit n.dur 0 n.cur 0 n.dur_len;
      n.cur_len <- n.dur_len
    end
    else begin
      Hashtbl.iter (fun s () -> Hashtbl.replace n.lost s ()) n.dirty;
      if Rng.bool t.rng && n.cur_len > n.dur_len then begin
        let d = Bytes.make n.cur_len '\000' in
        Bytes.blit n.dur 0 d 0 n.dur_len;
        n.dur <- d;
        n.dur_len <- n.cur_len
      end
    end;
    Hashtbl.reset n.dirty;
    io "fsync: input/output error (simulated)"
  end;
  let d = Bytes.make n.cur_len '\000' in
  Bytes.blit n.dur 0 d 0 (min n.dur_len n.cur_len);
  Hashtbl.iter
    (fun s () ->
      let lo = s * sector in
      if lo < n.cur_len then Bytes.blit n.cur lo d lo (min n.cur_len (lo + sector) - lo))
    n.dirty;
  n.dur <- d;
  n.dur_len <- n.cur_len;
  Hashtbl.reset n.dirty;
  Hashtbl.filter_map_inplace (fun s () -> if s * sector < n.cur_len then Some () else None) n.lost

(* an inode no name, no durable name, no name change a power loss may yet keep, and no open file refers to is gone:
   its bytes are freed *)
let forget t i =
  let used = Hashtbl.fold (fun _ j u -> u || j = i) t.names false || Hashtbl.fold (fun _ j u -> u || j = i) t.dnames false
             || Hashtbl.fold (fun _ (j, _) u -> u || j = i) t.fds false
             || Hashtbl.fold (fun _ ops u -> u || List.exists (function Link (_, j) -> j = i | _ -> false) ops) t.pending false in
  if not used then Hashtbl.remove t.inodes i

let rename t a b =
  match Hashtbl.find_opt t.names a with
  | None -> io "rename %s: no such file" a
  | Some i ->
    need_dir t b;
    Hashtbl.remove t.names a;
    Hashtbl.replace t.names b i;
    (* the two changes are made durable together by a sync of their directory (same directory here) *)
    note t (parent b) (Link (b, i));
    note t (parent a) (Unlink a)

let remove t p =
  match Hashtbl.find_opt t.names p with
  | None -> io "unlink %s: no such file" p
  | Some i ->
    Hashtbl.remove t.names p;
    note t (parent p) (Unlink p);
    forget t i

let mkdir t p =
  if Hashtbl.mem t.dirs p then io "mkdir %s: exists" p;
  need_dir t p;
  Hashtbl.replace t.dirs p ();
  note t (parent p) (Mkdir p)

let apply_durable t = function
  | Link (p, i) -> Hashtbl.replace t.dnames p i
  | Unlink p -> Hashtbl.remove t.dnames p
  | Mkdir p -> Hashtbl.replace t.ddirs p ()

let sync_dir t d =
  if not (Hashtbl.mem t.dirs d) then io "fsync %s: no such directory" d;
  let ops = List.rev (Option.value (Hashtbl.find_opt t.pending d) ~default:[]) in
  List.iter (apply_durable t) ops;
  Hashtbl.remove t.pending d;
  List.iter (function Unlink p -> ignore p | _ -> ()) ops;
  let ids = Hashtbl.fold (fun i _ acc -> i :: acc) t.inodes [] in
  if List.exists (function Unlink _ -> true | _ -> false) ops then List.iter (forget t) ids

let in_dir d p = parent p = d

let readdir t d =
  if not (Hashtbl.mem t.dirs d) then io "readdir %s: no such directory" d;
  let l = Hashtbl.fold (fun p _ acc -> if in_dir d p then Filename.basename p :: acc else acc) t.names [] in
  let l = Hashtbl.fold (fun p () acc -> if p <> d && in_dir d p then Filename.basename p :: acc else acc) t.dirs l in
  List.sort compare l

type draw = Names of string | Length of string | Cut of string | Sector of string * int | Tear of string * int

let crash_inode pick path (n : inode) =
  let new_len =
    if n.cur_len = n.dur_len then n.dur_len
    else
      match pick (Length path) 4 with
      | 0 -> n.dur_len
      | 1 -> n.cur_len
      | _ ->
        let lo = min n.dur_len n.cur_len and hi = max n.dur_len n.cur_len in
        lo + pick (Cut path) (hi - lo + 1)
  in
  let b = Bytes.make new_len '\000' in
  Bytes.blit n.dur 0 b 0 (min n.dur_len new_len);
  (* in sector order, so that the draws replay *)
  let dirty = List.sort_uniq compare (Hashtbl.fold (fun s () acc -> s :: acc) n.dirty (Hashtbl.fold (fun s () acc -> s :: acc) n.lost [])) in
  List.iter
    (fun s ->
      let lo = s * sector in
      let hi = min new_len (lo + sector) in
      let cur_hi = min hi n.cur_len in
      if lo < hi then
        match pick (Sector (path, s)) 6 with
        | 0 | 1 -> ()  (* the sector never reached the disk *)
        | 2 | 3 | 4 -> if lo < cur_hi then Bytes.blit n.cur lo b lo (cur_hi - lo)  (* it did *)
        | _ ->
          (* torn inside the sector: a prefix of the new bytes *)
          if lo < cur_hi then begin
            let k = pick (Tear (path, s)) (cur_hi - lo + 1) in
            Bytes.blit n.cur lo b lo k
          end)
    dirty;
  n.cur <- b;
  n.cur_len <- new_len;
  n.dur <- Bytes.copy b;
  n.dur_len <- new_len;
  Hashtbl.reset n.dirty;
  Hashtbl.reset n.lost

let crash ?choose t =
  let pick = match choose with Some c -> fun d n -> max 0 (min (n - 1) (c d n)) | None -> fun _ n -> Rng.int t.rng n in
  (* names: per directory, a random prefix of its changes since its last sync survives, in order *)
  let dirs = List.sort compare (Hashtbl.fold (fun d _ acc -> d :: acc) t.pending []) in
  List.iter
    (fun d ->
      let ops = Array.of_list (List.rev (Hashtbl.find t.pending d)) in
      let k = pick (Names d) (Array.length ops + 1) in
      for j = 0 to k - 1 do
        apply_durable t ops.(j)
      done)
    dirs;
  Hashtbl.reset t.pending;
  (* a directory whose creation was lost takes its files with it *)
  let rec dir_ok d = d = "." || d = "/" || (Hashtbl.mem t.ddirs d && dir_ok (parent d)) in
  let names = Hashtbl.create 16 in
  Hashtbl.iter (fun p i -> if dir_ok (parent p) then Hashtbl.replace names p i) t.dnames;
  let dirs = Hashtbl.create 8 in
  Hashtbl.iter (fun d () -> if dir_ok d then Hashtbl.replace dirs d ()) t.ddirs;
  t.dnames <- names;
  t.names <- Hashtbl.copy names;
  t.ddirs <- dirs;
  t.dirs <- Hashtbl.copy dirs;
  (* contents, in a fixed order so that the draws replay; a file is named by one of its current paths *)
  let ids = List.sort compare (Hashtbl.fold (fun i _ acc -> i :: acc) t.inodes []) in
  let path_of = Hashtbl.create 16 in
  Hashtbl.iter (fun p i -> Hashtbl.replace path_of i p) t.names;
  List.iter
    (fun i -> crash_inode pick (Option.value (Hashtbl.find_opt path_of i) ~default:"") (Hashtbl.find t.inodes i))
    ids;
  Hashtbl.reset t.fds;
  Hashtbl.reset t.locks;
  t.countdown <- -1;
  t.fail_in <- -1;
  t.then_crash <- -1

let kill t =
  Hashtbl.reset t.fds;
  Hashtbl.reset t.locks;
  t.countdown <- -1;
  t.fail_in <- -1;
  t.then_crash <- -1

let pending_names t d = List.length (Option.value (Hashtbl.find_opt t.pending d) ~default:[])

let flip_durable t p lo hi =
  match Hashtbl.find_opt t.names p with
  | None -> None
  | Some i ->
    let n = Hashtbl.find t.inodes i in
    let hi = min hi n.dur_len in
    if lo >= hi then None
    else begin
      let off = lo + Rng.int t.rng (hi - lo) in
      let bit = 1 lsl Rng.int t.rng 8 in
      let flip (b : Bytes.t) = Bytes.set b off (Char.chr (Char.code (Bytes.get b off) lxor bit)) in
      flip n.dur;
      if off < n.cur_len then flip n.cur;
      Some off
    end

let durable_size t p =
  match Hashtbl.find_opt t.dnames p with Some i -> (Hashtbl.find t.inodes i).dur_len | None -> 0

let durable_bytes t p =
  match Hashtbl.find_opt t.dnames p with
  | Some i ->
    let n = Hashtbl.find t.inodes i in
    Bytes.sub n.dur 0 n.dur_len
  | None -> Bytes.empty

let files t = List.sort compare (Hashtbl.fold (fun p _ acc -> p :: acc) t.names [])
let fail_fsync_at ?(crash_after = -1) t n = t.fail_in <- n; t.then_crash <- crash_after
let fail_next_fsync t = fail_fsync_at t 0
let failures t = t.failures
let advance t ms = t.clock <- t.clock + ms

let crash_after t n = t.countdown <- n

let tick t =
  if t.countdown = 0 then begin
    t.countdown <- -1;
    raise Crash
  end
  else if t.countdown > 0 then t.countdown <- t.countdown - 1

let disk t : Disk.t =
  let tk f x = tick t; f x in
  {
    exists = (fun p -> Hashtbl.mem t.names p || Hashtbl.mem t.dirs p);
    mkdir = tk (mkdir t);
    readdir = readdir t;
    openf = (fun p c -> if c then tick t; openf t p c);
    size = (fun fd -> (inode t fd).cur_len);
    pread = pread t;
    pwrite = (fun fd off b pos len -> tick t; pwrite t fd off b pos len);
    truncate = (fun fd n -> tick t; truncate t fd n);
    fsync = tk (fsync t);
    close = (fun fd -> ignore (inode t fd); let i, _ = Hashtbl.find t.fds fd in Hashtbl.remove t.fds fd; forget t i);
    rename = (fun a b -> tick t; rename t a b);
    remove = tk (remove t);
    sync_dir = tk (sync_dir t);
    lock = (fun p -> if Hashtbl.mem t.locks p then false else (Hashtbl.replace t.locks p (); true));
    unlock = (fun p -> Hashtbl.remove t.locks p);
    now = (fun () -> t.clock);
  }
