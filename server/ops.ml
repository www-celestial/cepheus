(* The commands of operations: cepheus verify, backup and restore (docs/book/production.md, "Backups";
   docs/book/operations.md, "Backup and restore" and "Verification").

     verify DIR       a database's files checked as they are, nothing changed: every frame of the journal (its CRCs,
                      its groups numbered), every run (as an open checks it, and every page against its CRC), the
                      runs against the journal, the vault's records; each damage named. A database open in another
                      process is checked up to the frame being written.
     backup DEST      every database of a server copied while it serves, into DEST/<date>.partial: its id and
                      history, its runs (opened before the journal is listed: a run a merge removes meanwhile stays
                      readable), its segments in order, its vault; each copy checked as verify checks it, cut after
                      its last whole frame (what was being written is left out), forced, marked closed; then the
                      folder renamed DEST/<date>, so that a dated folder is always whole.
     restore SRC DIR  a copy of SRC in DIR.restoring: the runs of groups up to N, the journal ended after group N
                      (--to-group; the backup's end without it), the history of promotions opening a new epoch after
                      N; opened (the groups after the newest run replayed), closed, verified; then renamed DIR. A
                      folder that holds a database is never written into: --replace moves it aside first.

   Exit codes: 0 done (and whole), 1 damage found (named), 2 anything else (the usage, a refusal, a failed disk). *)

open Cepheus
open Cepheus_vault

let exit_ok = 0
let exit_damage = 1
let exit_failed = 2

exception Refused of string
(* the command stops with exit 2 *)

let refuse fmt = Printf.ksprintf (fun m -> raise (Refused m)) fmt
(* what the commands print, on stdout (the tests make it quiet) *)
let quiet = ref false
let say fmt = Printf.ksprintf (fun m -> if not !quiet then print_endline m) fmt
let mb n = Printf.sprintf "%.1f MB" (float_of_int n /. 1e6)
let since t0 = Printf.sprintf "%.2f s" (Unix.gettimeofday () -. t0)
let ( // ) = Filename.concat
let is_dir p = match Unix.stat p with st -> st.Unix.st_kind = Unix.S_DIR | exception Unix.Unix_error _ -> false
let starts s p = String.length s >= String.length p && String.sub s 0 (String.length p) = p

(* A process holds the lock of [file] (lockf, as Disk.lock takes it). Opened read-only, so that a copy anyone may
   read can be checked; never called on a file this process locked (closing a descriptor drops the process's lock). *)
let held file =
  match Unix.openfile file [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 with
  | exception Unix.Unix_error _ -> false
  | fd ->
    Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
        match Unix.lockf fd Unix.F_TEST 0 with
        | () -> false
        | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EACCES), _, _) -> true)

(* What a database's folder is: open in a process (a server, a program), closed cleanly, or left by a process that
   died. One written through a server's commit buffer and not closed cleanly is refused: its newest confirmed frames
   may be in the server's buffer alone (operations.md, "A database of a server"). *)
type state = Open | Closed | Crashed

let state dir =
  if not (Sys.file_exists (dir // "cepheus")) then refuse "%s holds no database (no file %s)" dir (dir // "cepheus");
  if held (dir // "lock") then Open
  else if Sys.file_exists (dir // "closed") then Closed
  else if Sys.file_exists (dir // "shared") then
    refuse "%s was written through a server's commit buffer and not closed cleanly: its newest writes may be in the server's DATA/server.wal.1 or .2 alone; start the server on its data directory and stop it (cepheus stop), then run this again" dir
  else Crashed

(* ---- verify ---- *)

type report = {
  group : int;  (* the newest group of the journal's whole frames *)
  segments : int;
  journal_bytes : int;
  frames : int;
  runs : int;
  run_bytes : int;
  pages : int;
  packs : int;
  vault_bytes : int;
  records : int;
  damages : string list;
  notes : string list;
  tail : (int * int) option;  (* the newest segment and the end of its last whole frame, when bytes follow it *)
}

let file_size p = match Unix.stat p with st -> st.Unix.st_size | exception Unix.Unix_error _ -> 0

(* Every file of the database in [dir] checked through [disk] (read-only), the newest segment's end read by [tail];
   [live]: a process writes it meanwhile (a run a merge removes is no damage). *)
let check ?(disk = Disk.read_only) ~tail ~live dir =
  let damages = ref [] and notes = ref [] in
  let damage fmt = Printf.ksprintf (fun m -> damages := m :: !damages) fmt in
  let note fmt = Printf.ksprintf (fun m -> notes := m :: !notes) fmt in
  match Engine.read_meta disk dir with
  | exception Journal.Damaged m ->
    { group = 0; segments = 0; journal_bytes = 0; frames = 0; runs = 0; run_bytes = 0; pages = 0; packs = 0; vault_bytes = 0;
      records = 0; damages = [ m ]; notes = []; tail = None }
  | exception Disk.Io m -> refuse "%s" m
  | id ->
    (* the runs: each as an open checks it, and every page *)
    let sdir = dir // "snapshots" in
    let names = if is_dir sdir then disk.Disk.readdir sdir else [] in
    List.iter
      (fun n ->
        if Filename.check_suffix n ".tmp" then
          note "snapshots/%s: %s" n (if live then "a merge being written: not checked" else "a merge a crash interrupted: the next open removes it")
        else if Filename.check_suffix n ".snap" then note "snapshots/%s: a run of an earlier format: the next open replays its groups" n)
      names;
    let runs = List.sort compare (Snapshot.list disk sdir) in
    let good = ref [] and run_bytes = ref 0 and pages = ref 0 in
    List.iter
      (fun ((lo, hi, n) as r) ->
        match Snapshot.verify disk sdir r id with
        | pos, p ->
          good := (n, lo, hi, pos) :: !good;
          run_bytes := !run_bytes + file_size (sdir // n);
          pages := !pages + p
        | exception Snapshot.Bad m when starts m "an earlier format" -> note "snapshots/%s: %s" n m
        | exception (Snapshot.Bad m | Pages.Unreadable m | Invalid_argument m) -> damage "snapshots/%s: %s" n m
        | exception Disk.Io m ->
          if live && not (Sys.file_exists (sdir // n)) then note "snapshots/%s: removed by a merge meanwhile" n
          else damage "snapshots/%s: %s" n m
        | exception e -> damage "snapshots/%s: %s" n (Printexc.to_string e))
      runs;
    (* the journal, its segments on up to 4 domains; the runs' positions looked for among its frames *)
    let jdir = dir // "journal" in
    let wanted = Hashtbl.create 8 and found = Hashtbl.create 8 and fm = Mutex.create () in
    List.iter (fun (_, _, _, (p : Journal.position)) -> Hashtbl.replace wanted (p.segment, p.offset) ()) !good;
    let frame (p : Journal.position) _ _ =
      if Hashtbl.mem wanted (p.segment, p.offset) then Mutex.protect fm (fun () -> Hashtbl.replace found (p.segment, p.offset) p.next)
    in
    let c =
      if is_dir jdir then Journal.check ~domains:4 ~frame ~tail disk jdir id
      else { Journal.segments = []; damages = [ "journal: the folder is missing" ]; last = 0 }
    in
    List.iter (fun m -> damage "journal/%s" m) c.damages;
    let newest = match List.rev c.segments with s :: _ -> Some s | [] -> None in
    let tail_at =
      match newest with
      | Some s when s.stail ->
        (match tail with
         | Journal.Copy when live -> note "journal/%s: the frame being written from offset %d is not checked (the database is open)" (Journal.segment_name s.sfirst) s.send
         | Journal.Crash when s.send = 0 -> note "journal/%s: a segment torn at its creation, holding no frame (the next open removes it)" (Journal.segment_name s.sfirst)
         | Journal.Crash -> note "journal/%s: a frame torn from offset %d, never confirmed (the next open cuts it)" (Journal.segment_name s.sfirst) s.send
         | _ -> ());
        Some (s.sfirst, s.send)
      | _ -> None
    in
    (* the runs against the journal: each run's groups in it, its position the start of one of its frames (or its end) *)
    if c.damages = [] then
      List.iter
        (fun (n, _, hi, (p : Journal.position)) ->
          if hi > c.last then damage "snapshots/%s holds groups up to %d, past the journal's end (group %d)" n hi c.last
          else
            let at_end = match newest with Some s -> p.segment = s.sfirst && p.offset = s.send && p.next = c.last + 1 | None -> false in
            (* or the end of a segment the next one follows: the frame after the run's groups began a new segment *)
            let at_seg_end =
              List.exists (fun (s : Journal.segment_check) -> s.sfirst = p.segment && s.send = p.offset && s.slast = p.next - 1) c.segments
              && List.exists (fun (s : Journal.segment_check) -> s.sfirst = p.next) c.segments
            in
            if not (at_end || at_seg_end || Hashtbl.find_opt found (p.segment, p.offset) = Some p.next) then
              damage "snapshots/%s: its journal position (%s at offset %d, group %d) is not the start of a frame" n
                (Journal.segment_name p.segment) p.offset p.next)
        (List.rev !good);
    (* the vault's packs, by their CRCs (no key needed) *)
    let vdir = dir // "vault" in
    let packs, vault_bytes, records =
      if is_dir vdir then begin
        let v = Vault.check ~live disk vdir in
        List.iter (fun m -> damage "vault/%s" m) v.Vault.vdamages;
        List.iter (fun m -> note "vault/%s" m) v.vnotes;
        v.vpacks, v.vbytes, v.vrecords
      end
      else 0, 0, 0
    in
    { group = c.last; segments = List.length c.segments; journal_bytes = List.fold_left (fun a (s : Journal.segment_check) -> a + s.sbytes) 0 c.segments;
      frames = List.fold_left (fun a (s : Journal.segment_check) -> a + s.sframes) 0 c.segments; runs = List.length !good;
      run_bytes = !run_bytes; pages = !pages; packs; vault_bytes; records; damages = List.rev !damages; notes = List.rev !notes;
      tail = tail_at }

let print_report r =
  say "journal: %d segment%s, %s, %d frames, groups 1 to %d" r.segments (if r.segments = 1 then "" else "s") (mb r.journal_bytes) r.frames r.group;
  say "runs: %d, %s, %d pages" r.runs (mb r.run_bytes) r.pages;
  if r.packs > 0 then say "vault: %d pack%s, %s, %d records" r.packs (if r.packs = 1 then "" else "s") (mb r.vault_bytes) r.records;
  List.iter (fun m -> say "note: %s" m) r.notes;
  List.iter (fun m -> say "damaged: %s" m) r.damages

(* Run pages are read through a cache of 256 MiB: a run that fits is read and checked whole by its open's check, a
   larger one page by page; the memory stays under it whatever the database's size. *)
let verify_cache = 256 lsl 20

let verify dir =
  let t0 = Unix.gettimeofday () in
  Pages.set_capacity verify_cache;
  let st = state dir in
  let tail = match st with Open -> Journal.Copy | Closed -> Journal.Strict | Crashed -> Journal.Crash in
  let r = check ~tail ~live:(st = Open) dir in
  print_report r;
  match r.damages with
  | [] -> say "%s: whole, at group %d (%s)" dir r.group (since t0); exit_ok
  | l -> say "%s: %d damaged (%s)" dir (List.length l) (since t0); exit_damage

(* ---- copies ---- *)

let buf = lazy (Bigarray.Array1.create Bigarray.char Bigarray.c_layout (4 lsl 20))

let rec write_all fd b off n = if n > 0 then let k = Unix.write_bigarray fd b off n in write_all fd b (off + k) (n - k)

(* [src] (open) copied into the new file [dst] (never through a name planted there: O_EXCL), mode 0600, up to the
   size it has now (a segment being appended is not chased) or its end, forced: the bytes copied *)
let copy_fd src dst =
  let limit = (Unix.fstat src).Unix.st_size in
  let b = Lazy.force buf in
  let out = Unix.openfile dst [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ] 0o600 in
  Fun.protect ~finally:(fun () -> Unix.close out) (fun () ->
      let rec go total =
        let want = min (Bigarray.Array1.dim b) (limit - total) in
        if want <= 0 then total
        else
          let n = Unix.read_bigarray src b 0 want in
          if n = 0 then total else (write_all out b 0 n; go (total + n))
      in
      let n = go 0 in
      Unix.fsync out;
      n)

let open_ro p = Unix.openfile p [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0

let copy_file src dst =
  let fd = open_ro src in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> copy_fd fd dst)

let mkdir_private p = Unix.mkdir p 0o700; Unix.chmod p 0o700
let sync_dir p = Disk.real.Disk.sync_dir p

let rec rmrf p =
  match Unix.lstat p with
  | { Unix.st_kind = Unix.S_DIR; _ } -> Array.iter (fun n -> rmrf (p // n)) (Sys.readdir p); Unix.rmdir p
  | _ -> Unix.unlink p
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let segment_names jdir =
  List.sort compare
    (List.filter (fun n -> Filename.check_suffix n ".seg" && String.length n = 24 && int_of_string_opt (String.sub n 0 20) <> None)
       (Array.to_list (Sys.readdir jdir)))

type copied = { journal : int; runs_ : int; vault : int }

(* The vault's files: each pack and its index if it has one, then the keys. Copied after the journal, so that the records
   of every file its facts cite are in the copy: a fact names a file only once its records are forced (G22). A pack
   copied while it is written may end in a torn record: the copy's open indexes it up to its last whole record, as
   after a crash. *)
let copy_vault src dst =
  mkdir_private dst;
  let n = ref 0 in
  let sp = src // "packs" and dp = dst // "packs" in
  mkdir_private dp;
  if is_dir sp then
    List.iter
      (fun f ->
        if Filename.check_suffix f ".pack" || Filename.check_suffix f ".idx" then
          match open_ro (sp // f) with
          | fd -> n := !n + Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> copy_fd fd (dp // f))
          | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ())
      (List.sort compare (Array.to_list (Sys.readdir sp)));
  (* the keys after the packs: a domain's key is forced before its first record, so the keys copied now hold every
     key a copied record needs *)
  if Sys.file_exists (src // "keys") then n := !n + copy_file (src // "keys") (dst // "keys");
  sync_dir dp;
  sync_dir dst;
  !n

(* A database's files copied in the order that makes the copy consistent while it is written (operations.md, "Backup
   and restore"): the id and the history of promotions; the runs [keep] allows, each opened before any segment is
   listed (a merge may remove one meanwhile: its descriptor still reads it), then copied; the segments [keep_seg]
   allows, in the order of their names, the newest up to where it ends when it is read; the vault. *)
let copy_database ?(keep = fun _ -> true) ?(keep_seg = fun _ -> true) src dst =
  mkdir_private dst;
  mkdir_private (dst // "journal");
  mkdir_private (dst // "snapshots");
  ignore (copy_file (src // "cepheus") (dst // "cepheus"));
  if Sys.file_exists (src // "epochs") then ignore (copy_file (src // "epochs") (dst // "epochs"));
  let sdir = src // "snapshots" in
  let runs =
    if is_dir sdir then
      List.filter_map
        (fun ((_, _, n) as r) -> if not (keep r) then None else match open_ro (sdir // n) with fd -> Some (n, fd) | exception Unix.Unix_error (Unix.ENOENT, _, _) -> None)
        (List.sort compare (Snapshot.list Disk.read_only sdir))
    else []
  in
  let run_bytes =
    List.fold_left (fun a (n, fd) -> a + Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> copy_fd fd (dst // "snapshots" // n))) 0 runs
  in
  let jdir = src // "journal" in
  let journal =
    List.fold_left
      (fun a n -> if keep_seg (int_of_string (String.sub n 0 20)) then a + copy_file (jdir // n) (dst // "journal" // n) else a)
      0 (segment_names jdir)
  in
  let vault = if is_dir (src // "vault") then copy_vault (src // "vault") (dst // "vault") else 0 in
  sync_dir (dst // "journal");
  sync_dir (dst // "snapshots");
  sync_dir dst;
  { journal; runs_ = run_bytes; vault }

(* ---- backup ---- *)

let stamp () =
  let t = Unix.localtime (Unix.time ()) in
  Printf.sprintf "%04d-%02d-%02dT%02d%02d%02d" (t.tm_year + 1900) (t.tm_mon + 1) t.tm_mday t.tm_hour t.tm_min t.tm_sec

(* the copy in [dir] ended after its last whole frame: what was being written when it was copied left out *)
let cut_copy dir (s, stop) =
  let f = dir // "journal" // Journal.segment_name s in
  if stop = 0 then Unix.unlink f
  else begin
    let fd = Unix.openfile f [ Unix.O_WRONLY; Unix.O_CLOEXEC ] 0 in
    Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.ftruncate fd stop; Unix.fsync fd)
  end;
  sync_dir (dir // "journal")

let mark_closed dir =
  let fd = Unix.openfile (dir // "closed") [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_CLOEXEC ] 0o600 in
  Unix.fsync fd;
  Unix.close fd;
  sync_dir dir

let backup (cfg : Config.t) dest =
  let t0 = Unix.gettimeofday () in
  Pages.set_capacity verify_cache;
  if not (is_dir cfg.data) then refuse "%s: the data directory %s is missing" cfg.file cfg.data;
  if not (Sys.file_exists dest) then (mkdir_private dest; sync_dir (Filename.dirname dest));
  if not (is_dir dest) then refuse "%s is not a folder" dest;
  (* one backup into DEST at a time *)
  let lock = Unix.openfile (dest // "cepheus-backup.lock") [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_CLOEXEC ] 0o600 in
  Fun.protect ~finally:(fun () -> Unix.close lock) @@ fun () ->
  (match Unix.lockf lock Unix.F_TLOCK 0 with
   | () -> ()
   | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EACCES), _, _) -> refuse "another cepheus backup writes into %s" dest);
  (* what a backup that did not finish left *)
  Array.iter
    (fun n -> if Filename.check_suffix n ".partial" then (rmrf (dest // n); say "note: removed %s, left by a backup that did not finish" (dest // n)))
    (Sys.readdir dest);
  let name =
    let s = stamp () in
    let rec free k = let n = if k = 1 then s else Printf.sprintf "%s-%d" s k in if List.exists (fun x -> Sys.file_exists (dest // (n ^ x))) [ ""; ".partial"; ".damaged" ] then free (k + 1) else n in
    free 1
  in
  (* every database's state before anything is copied: one a server's buffer must recover first refuses the backup *)
  let dbs =
    List.map
      (fun db ->
        let src = Config.database_dir cfg db in
        db, src, if Sys.file_exists (src // "cepheus") then Some (state src) else None)
      cfg.databases
  in
  let partial = dest // (name ^ ".partial") in
  mkdir_private partial;
  let damaged = ref 0 in
  List.iter
    (fun (db, src, st) ->
      match st with
      | None -> say "%s: no database yet (made at the server's first start)" db
      | Some st ->
        let t1 = Unix.gettimeofday () in
        let live = st = Open in
        let out = partial // db in
        let c = copy_database src out in
        (* the copy's end read as the source's: one being written may end in the frame being written *)
        let tail = match st with Open -> Journal.Copy | Closed -> Journal.Strict | Crashed -> Journal.Crash in
        let r = check ~tail ~live:false out in
        List.iter (fun m -> say "%s: note: %s" db m) r.notes;
        match r.damages with
        | [] ->
          Option.iter
            (fun ((s, stop) as t) ->
              let f = out // "journal" // Journal.segment_name s in
              say "%s: note: journal/%s: %d bytes from offset %d left out, %s" db (Journal.segment_name s) (file_size f - stop) stop
                (if st = Open then "the frame being written when it was copied" else "a frame torn at a crash, never confirmed");
              cut_copy out t)
            r.tail;
          mark_closed out;
          say "%s: group %d, %s (journal %s, runs %s%s), %s%s" db r.group (mb (c.journal + c.runs_ + c.vault)) (mb c.journal) (mb c.runs_)
            (if c.vault > 0 then ", vault " ^ mb c.vault else "") (since t1) (if live then "" else ", the database was closed")
        | l ->
          incr damaged;
          List.iter (fun m -> say "%s: damaged: %s" db m) l)
    dbs;
  sync_dir partial;
  if !damaged > 0 then begin
    let kept = dest // (name ^ ".damaged") in
    Unix.rename partial kept;
    sync_dir dest;
    say "%s: %d database%s damaged: the copy is kept for a look; run cepheus verify on the database once its server is stopped" kept !damaged
      (if !damaged = 1 then "" else "s");
    exit_damage
  end
  else begin
    let final = dest // name in
    Unix.rename partial final;
    sync_dir dest;
    say "%s (%s)" final (since t0);
    exit_ok
  end

(* ---- restore ---- *)

(* days since 1970-01-01 of a date of the Gregorian calendar (Hinnant's days_from_civil) *)
let days y m d =
  let y = if m <= 2 then y - 1 else y in
  let era = (if y >= 0 then y else y - 399) / 400 in
  let yoe = y - (era * 400) in
  let doy = (((153 * (if m > 2 then m - 3 else m + 9)) + 2) / 5) + d - 1 in
  (era * 146097) + (yoe * 365) + (yoe / 4) - (yoe / 100) + doy - 719468

(* YYYY-MM-DDTHH:MM[:SS] (or a space for the T) in the machine's local time, or with a final Z in UTC: milliseconds
   since 1970. Exactly these digits, a day of the calendar (leap years), hours 00 to 23, minutes and seconds 00 to 59;
   a local time the clocks skip (the change to summer time) is none; anything else is refused. *)
let parse_time s =
  let utc = String.length s > 0 && s.[String.length s - 1] = 'Z' in
  let n = String.length s - if utc then 1 else 0 in
  let digits i k = let v = ref 0 in for j = i to i + k - 1 do (match s.[j] with '0' .. '9' as c -> v := (!v * 10) + Char.code c - 48 | _ -> raise Exit) done; !v in
  match
    if not (n = 16 || n = 19) || s.[4] <> '-' || s.[7] <> '-' || (s.[10] <> 'T' && s.[10] <> ' ') || s.[13] <> ':' || (n = 19 && s.[16] <> ':') then raise Exit;
    let y = digits 0 4 and mo = digits 5 2 and d = digits 8 2 and h = digits 11 2 and mi = digits 14 2 and sec = if n = 19 then digits 17 2 else 0 in
    if mo < 1 || mo > 12 || d < 1 || d > Tabular.month_days y mo || h > 23 || mi > 59 || sec > 59 then raise Exit;
    y, mo, d, h, mi, sec
  with
  | exception Exit -> None
  | y, mo, d, h, mi, sec ->
    if utc then Some (((days y mo d * 86400) + (h * 3600) + (mi * 60) + sec) * 1000)
    else
      let tm = { Unix.tm_year = y - 1900; tm_mon = mo - 1; tm_mday = d; tm_hour = h; tm_min = mi; tm_sec = sec; tm_wday = 0; tm_yday = 0; tm_isdst = false } in
      match Unix.mktime tm with
      | exception Unix.Unix_error _ -> None
      | t, _ ->
        (* the time read back: mktime moves a local time the clocks skip *)
        let b = Unix.localtime t in
        if (b.tm_year, b.tm_mon, b.tm_mday, b.tm_hour, b.tm_min, b.tm_sec) = (y - 1900, mo - 1, d, h, mi, sec) then Some (int_of_float t * 1000) else None

let time_text ms =
  let t = Unix.localtime (float_of_int ms /. 1000.) in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d" (t.tm_year + 1900) (t.tm_mon + 1) t.tm_mday t.tm_hour t.tm_min t.tm_sec

type target = End | Group of int | Time of int

(* The last group of SRC's journal before the first one written after [ms] (time: the database's clock, in
   milliseconds), the frames checked by their CRCs; 0 when the first is after it *)
let group_at_time src id ms =
  let last = ref 0 in
  Journal.times Disk.read_only (src // "journal") id (fun n time -> if time > ms then false else (last := n; true));
  !last

let restore ?(target = End) ~replace src dst =
  let t0 = Unix.gettimeofday () in
  Pages.set_capacity verify_cache;
  (* the source: a backup, or a database no process writes *)
  if not (is_dir src) then refuse "%s is not a folder" src;
  (match state src with
   | Open -> refuse "%s is open in another process: restore from a backup (cepheus backup), or stop its server first" src
   | Closed | Crashed -> ());
  let id = match Engine.read_meta Disk.read_only src with id -> id | exception Journal.Damaged m -> refuse "%s" m | exception Disk.Io m -> refuse "%s" m in
  (* the destination: a new folder, or an empty one, or with --replace a database no process holds *)
  let dst = if Filename.check_suffix dst "/" && String.length dst > 1 then String.sub dst 0 (String.length dst - 1) else dst in
  let has_db = Sys.file_exists (dst // "cepheus") in
  if Sys.file_exists dst && not (is_dir dst) then refuse "%s is not a folder" dst;
  if Sys.file_exists dst && (not has_db) && Sys.readdir dst <> [||] then refuse "%s is not empty and holds no database: restore into a new folder" dst;
  if has_db && not replace then
    refuse "%s holds a database: restore into a new folder, or add --replace (the database there is moved aside, never removed)" dst;
  if has_db then ignore (match state dst with Open -> refuse "%s is open in another process: stop its server first (cepheus stop)" dst | s -> s);
  let parent = Filename.dirname dst in
  if (Sys.file_exists (parent // "server.wal.1") || Sys.file_exists (parent // "server.wal.2")) && not (held (parent // "cepheus.lock")) then
    refuse "the server of %s did not stop cleanly: its commit buffer (server.wal.1, .2) may hold frames of this database, which its next start would write into the restored journal; start the server and stop it (cepheus stop), then restore" parent;
  if not (is_dir parent) then refuse "%s: the folder %s is missing" dst parent;
  let n =
    match target with
    | End -> None
    | Group n -> if n < 1 then refuse "--to-group %d: the groups start at 1" n else Some n
    | Time ms ->
      let n = match group_at_time src id ms with n -> n | exception Journal.Damaged m -> refuse "%s: %s (cepheus verify names every damage)" src m in
      if n < 1 then refuse "--to-time: %s holds no group written at or before %s" src (time_text ms);
      Some n
  in
  (* the copy, in DIR.restoring: one restore of DIR at a time (its lock, held to the end); one a kill interrupted is
     removed *)
  let tmp = dst ^ ".restoring" in
  if Sys.file_exists tmp then begin
    if held (tmp // "restore.lock") then refuse "another cepheus restore writes %s" tmp;
    rmrf tmp;
    say "note: removed %s, left by a restore that did not finish" tmp
  end;
  mkdir_private tmp;
  let lockfd = Unix.openfile (tmp // "restore.lock") [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_CLOEXEC ] 0o600 in
  Fun.protect ~finally:(fun () -> Unix.close lockfd) @@ fun () ->
  (match Unix.lockf lockfd Unix.F_TLOCK 0 with () -> () | exception Unix.Unix_error _ -> refuse "another cepheus restore writes %s" tmp);
  let fail_with code msg = (try rmrf tmp with Unix.Unix_error _ -> ()); say "%s" msg; code in
  match
    let upto = Option.value n ~default:max_int in
    let c =
      copy_database ~keep:(fun (_, hi, _) -> hi <= upto) ~keep_seg:(fun s -> upto = max_int || s <= upto + 1) src (tmp // "db")
    in
    let db = tmp // "db" in
    (* the journal ended after N; without N, a torn end is cut by the open, as after a crash *)
    (match n with
     | Some n ->
       if not (Journal.cut_after Disk.real (db // "journal") id n) then begin
         let r = check ~tail:Journal.Crash ~live:false src in
         refuse "%s holds groups 1 to %d%s: no group %d to restore to" src r.group (if r.damages = [] then "" else " before its damage (cepheus verify)") n
       end
     | None -> ());
    (* the database opened: its runs checked, the groups after the newest one replayed and checked *)
    let reached, notes =
      match Cepheus.open_ db with
      | Error e -> raise (Journal.Damaged (Cepheus.message e))
      | Ok d ->
        let g = Cepheus.group (Cepheus.view d) and notes = Cepheus.notes d in
        Cepheus.close d;
        g, notes
    in
    (match n with Some n when reached <> n -> refuse "the restored database opened at group %d, not %d" reached n | _ -> ());
    (* a new epoch after the group reached: a replica that holds later groups of the old history is refused, never
       followed as if they were this database's (server.md, "Epochs") *)
    let full = Replica.load_epochs db in
    let h = List.filter (fun (_, f) -> f <= reached) full in
    (* the new epoch above every one the source's history and the database replaced knew: never a history another
       copy of this database already has (as PostgreSQL's new timeline after a recovery to a point) *)
    let known = List.map fst full @ (if has_db then (try List.map fst (Replica.load_epochs dst) with Journal.Damaged _ -> []) else []) in
    let e = 1 + List.fold_left max 0 known in
    Replica.save_epochs db (h @ [ e, reached + 1 ]);
    let r = check ~tail:Journal.Strict ~live:false db in
    let last = ref None in
    Journal.read_after Disk.read_only (db // "journal") id (reached - 1) (fun g -> if g.Group.n = reached then last := Some g);
    c, reached, notes, e, (r, !last)
  with
  | exception Refused m -> (try rmrf tmp with Unix.Unix_error _ -> ()); raise (Refused m)
  | exception Journal.Damaged m -> fail_with exit_damage (Printf.sprintf "damaged: %s\n%s: not restored (the copy is removed; %s is unchanged)" m src dst)
  | exception Disk.Io m -> fail_with exit_failed (Printf.sprintf "cepheus: %s\n%s: not restored (%s is unchanged)" m src dst)
  | exception Unix.Unix_error (e, call, p) ->
    fail_with exit_failed (Printf.sprintf "cepheus: %s %s: %s\n%s: not restored (%s is unchanged)" call p (Unix.error_message e) src dst)
  | _, _, _, _, (r, _) when r.damages <> [] ->
    print_report r;
    fail_with exit_damage (Printf.sprintf "%s: not restored: the restored copy does not check (%s is unchanged)" src dst)
  | c, reached, notes, e, (_, last) ->
    List.iter (fun m -> say "note: %s" m) notes;
    (* into place: the old database moved aside first, never removed *)
    let aside =
      if has_db then begin
        let a = dst ^ ".before-restore-" ^ stamp () in
        Unix.rename dst a;
        Some a
      end
      else begin
        if Sys.file_exists dst then Unix.rmdir dst;
        None
      end
    in
    Unix.rename (tmp // "db") dst;
    sync_dir parent;
    Unix.unlink (tmp // "restore.lock");
    Unix.rmdir tmp;
    sync_dir parent;
    say "copied: journal %s, runs %s%s" (mb c.journal) (mb c.runs_) (if c.vault > 0 then ", vault " ^ mb c.vault else "");
    (* the group's origin: the token of the program that wrote it through a server (Origin), who and why *)
    Option.iter
      (fun (g : Group.t) ->
        let token, why = match Origin.parse g.why with Some (o, w) -> Printf.sprintf ", through the token %s" o.token, w | None -> "", g.why in
        say "group %d: written %s%s%s%s" g.n (time_text g.time) token (if g.by = 0 then "" else Printf.sprintf ", by %d" g.by)
          (if why = "" then "" else Printf.sprintf ", why %S" why))
      last;
    say "%s: restored from %s at group %d; its next writes open epoch %d from group %d (%s)" dst src reached e (reached + 1) (since t0);
    Option.iter (fun a -> say "the database that was there is kept in %s: remove it once the restore is checked" a) aside;
    exit_ok
