(* The catch-up of a Raft cluster's server from a peer's databases: the role of InstallSnapshot (Ongaro's thesis,
   ch. 5; docs/book/server.md, "A server behind the log's start"). A follower whose log does not hold the entry before
   its leader's log start (Raft's Snap) asks that leader for a copy, on the peer port (Copy, peer protocol 3):

     Copy (empty)
       <- Begin   index X | its term T | bytes | databases      X: the source's applied index when it began
       <- File    database | path | size, then Bytes frames (1 MiB each) holding exactly [size] bytes
       <- ...
       <- End
     or an error frame.

   The source copies each database as cepheus backup does (Ops.plan_database, its session table too), every file
   opened after X was read: every frame of an entry up to X is in its journal (applied there), and what was applied
   since may be too (its entries are then applied again here, their groups skipped). It pins X in its Raft core
   (Raft.pin) while it sends and a minute after, so that the entries after X stay in its log for this follower.

   The follower writes DATA/raft/copy.partial/<database>/ (folders 0700, files 0600, each forced), and refuses: a
   path outside those a database holds, a file of more bytes than it said, a database its cluster.toml does not
   name or names twice, a copy larger than the free space. Then each database is checked as cepheus verify checks
   it (every frame's CRCs and its groups numbered from 1, every run's pages, the runs against the journal, the
   vault's records): its id must be the cluster's, its newest group at least the one this server holds (a copy
   behind this server is a peer that lies or lost data); the frame being written when it was copied is cut. A copy
   that fails any of it is removed, never applied.

   Then the Raft core decides (Raft.install): a log that holds entry X of term T keeps its entries, the copy is
   dropped; else the server becomes inert (it answers nothing from then on), the index is written beside
   (Raftlog.encode_copy), the folder renamed DATA/raft/copy (the commit point), and the server stops cleanly and
   starts again in the same process (exec). Before its databases open ([at_start]), each is replaced by its copy and
   the log made to start at X + 1 (Raftlog.install), the folder removed last. A copy cut by a crash of either side,
   or by a stop, is removed at the next start or the next try; one committed is installed. *)

open Cepheus

let log fmt = Printf.ksprintf (fun s -> prerr_endline ("cepheus: " ^ s)) fmt
let ( // ) = Filename.concat
let piece = 1 lsl 20
let t_begin = 1
let t_file = 2
let t_bytes = 3
let t_end = 4

(* the free space a copy leaves at least, beyond its own bytes *)
let margin = 64 lsl 20

(* how long the source keeps the entries after X for the follower, after its last byte sent (ms) *)
let pin_ms = ref 60_000

(* the bytes of a copy sent or received so far: cepheus status, and the tests *)
let sent = Atomic.make 0
let received = Atomic.make 0

(* the frames of a copy go through [send] (Replica.send on the link; the tests: a list) *)
let frame send tag f =
  let b = Buffer.create 64 in
  Buffer.add_uint8 b tag;
  f b;
  send b

(* ---- the source ---- *)

(* The databases [dbs] (name, folder) sent: [start ()] gives X and its term, pinned; [renew ()] pins X again;
   [error code m] refuses the copy *)
let serve ~dbs ~start ~renew ~send ~error =
  let x, term = start () in
  match List.map (fun (name, dir) -> name, Ops.plan_database ~sessions:true dir) dbs with
  | exception Unix.Unix_error (e, _, p) ->
    log "a copy of the databases could not be made: %s: %s" p (Unix.error_message e);
    error "io" "the server could not read its databases (its log says why)"
  | plans ->
    Fun.protect ~finally:(fun () -> List.iter (fun (_, p) -> Ops.close_plan p) plans) (fun () ->
        let total = List.fold_left (fun a (_, p) -> List.fold_left (fun a (i : Ops.item) -> a + i.size) a p) 0 plans in
        frame send t_begin (fun b -> Codec.put_varint b x; Codec.put_varint b term; Codec.put_varint b total; Codec.put_varint b (List.length dbs));
        let buf = Bytes.create piece in
        let last = ref (Unix.gettimeofday ()) in
        List.iter
          (fun (name, plan) ->
            List.iter
              (fun (i : Ops.item) ->
                frame send t_file (fun b -> Codec.put_string b name; Codec.put_string b i.rel; Codec.put_varint b i.size);
                let rec go left =
                  if left > 0 then begin
                    let n = Unix.read i.fd buf 0 (min piece left) in
                    (* a file shorter than when it was opened (it cannot be: they are only appended to, or replaced
                       whole): the copy stops, the follower's check refuses it *)
                    if n = 0 then raise (Replica.Broken (Printf.sprintf "%s/%s ended before its size" name i.rel));
                    frame send t_bytes (fun b -> Buffer.add_subbytes b buf 0 n);
                    Atomic.fetch_and_add sent n |> ignore;
                    let now = Unix.gettimeofday () in
                    if now -. !last >= 1.0 then (last := now; renew ());
                    go (left - n)
                  end
                in
                go i.size)
              plan)
          plans;
        frame send t_end ignore;
        renew ();
        log "sent a copy of the databases at index %d (%.1f MB)" x (float_of_int total /. 1e6))

(* ---- the follower ---- *)

let is_dir p = match Unix.stat p with st -> st.Unix.st_kind = Unix.S_DIR | exception Unix.Unix_error _ -> false
let digits s = s <> "" && String.for_all (fun c -> c >= '0' && c <= '9') s

(* the paths a database's copy may hold, and nothing else *)
let valid_path rel =
  match String.split_on_char '/' rel with
  | [ ("cepheus" | "epochs" | "sessions") ] -> true
  | [ "snapshots"; n ] -> String.length n = 45 && digits (String.sub n 0 20) && n.[20] = '-' && digits (String.sub n 21 20) && Filename.check_suffix n ".run"
  | [ "journal"; n ] -> String.length n = 24 && digits (String.sub n 0 20) && Filename.check_suffix n ".seg"
  | [ "vault"; "keys" ] -> true
  | [ "vault"; "packs"; n ] ->
    String.length n >= 9 && digits (String.sub n 0 8) && (n = String.sub n 0 8 ^ ".pack" || n = String.sub n 0 8 ^ ".idx")
  | _ -> false

exception Refuse of string

let refuse fmt = Printf.ksprintf (fun m -> raise (Refuse m)) fmt

type outcome = Installed of int | Dropped of int | Refused of string

(* [next ()]: the next frame (Replica.next_frame on the link) *)
let next_copy next =
  match next () with
  | k, flags, _ when flags land Wire.f_error <> 0 && k = 0 -> refuse "the peer refused the copy"
  | k, _, r when k = Replica.k_copy ->
    if r.Codec.pos >= r.stop then raise Codec.Short;
    let tag = Bytes.get_uint8 r.buf r.pos in
    r.pos <- r.pos + 1;
    tag, r
  | k, _, _ -> raise (Replica.Broken (Printf.sprintf "a frame of kind %d in a copy" k))

(* The copy from the peer on [l] into DATA/raft/copy.partial, checked, then committed or dropped as [decide x term]
   says (the Raft core's word, under its lock). [id_of name]: the database's id in this cluster; [published name]:
   the newest group this server holds of it. *)
let fetch (cfg : Config.t) ~source ~id_of ~published ~decide ~send ~next =
  let raft = cfg.data // "raft" in
  let partial = raft // "copy.partial" in
  Ops.rmrf partial;
  Ops.mkdir_private partial;
  Ops.sync_dir raft;
  let fd = ref None in
  let close () = Option.iter (fun f -> try Unix.close f with Unix.Unix_error _ -> ()) !fd; fd := None in
  match
    frame send 0 ignore;
    let x, term, total, n =
      match next_copy next with
      | tag, r when tag = t_begin ->
        let x = Codec.get_varint r in
        let term = Codec.get_varint r in
        let total = Codec.get_varint r in
        let n = Codec.get_varint r in
        x, term, total, n
      | _ -> raise Codec.Short
    in
    if x < 1 then refuse "a copy at index %d" x;
    if n <> List.length cfg.databases then refuse "a copy of %d databases, where this server has %d" n (List.length cfg.databases);
    let free = try Fdpass.free_bytes raft with Unix.Unix_error _ -> max_int in
    if total > free - margin then
      refuse "a copy of %.1f MB, where %s has %.1f MB free (and keeps %d MB): not taken" (float_of_int total /. 1e6) raft (float_of_int free /. 1e6) (margin lsr 20);
    let seen = Hashtbl.create 8 in
    let got = ref 0 in
    let left = ref 0 and cur = ref "" in
    let finish_file () =
      if !left <> 0 then refuse "%s: %d bytes missing" !cur !left;
      Option.iter (fun f -> Unix.fsync f) !fd;
      close ()
    in
    let rec loop () =
      match next_copy next with
      | tag, r when tag = t_file ->
        finish_file ();
        let name = Codec.get_string r in
        let rel = Codec.get_string r in
        let size = Codec.get_varint r in
        if not (List.mem name cfg.databases) then refuse "a database %S, which this server's %s does not name" name cfg.file;
        if not (valid_path rel) then refuse "%s: a path %S that no database holds" name rel;
        if !got + size > total then refuse "more bytes than the copy said (%d)" total;
        let dir = partial // name in
        if not (Hashtbl.mem seen name) then begin
          Hashtbl.replace seen name ();
          Ops.mkdir_private dir;
          Ops.mkdir_private (dir // "journal");
          Ops.mkdir_private (dir // "snapshots")
        end;
        if String.length rel > 6 && String.sub rel 0 6 = "vault/" then begin
          if not (is_dir (dir // "vault")) then Ops.mkdir_private (dir // "vault");
          if not (is_dir (dir // "vault" // "packs")) then Ops.mkdir_private (dir // "vault" // "packs")
        end;
        fd := Some (Unix.openfile (dir // rel) [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ] 0o600);
        left := size;
        cur := name // rel;
        loop ()
      | tag, r when tag = t_bytes ->
        let k = r.stop - r.pos in
        if !fd = None || k > !left then refuse "%s: more bytes than its size" !cur;
        let f = Option.get !fd in
        let rec w o n = if n > 0 then let m = Unix.write f r.buf o n in w (o + m) (n - m) in
        w r.pos k;
        left := !left - k;
        got := !got + k;
        Atomic.fetch_and_add received k |> ignore;
        loop ()
      | tag, _ when tag = t_end -> finish_file ()
      | _ -> raise Codec.Short
    in
    loop ();
    (* every database of this server, each checked as cepheus verify checks it *)
    List.iter
      (fun name ->
        let dir = partial // name in
        if not (Hashtbl.mem seen name) then refuse "it lacks database %s" name;
        List.iter (fun d -> if is_dir (dir // d) then Ops.sync_dir (dir // d)) (List.rev Ops.copy_dirs);
        Ops.sync_dir dir;
        let id = match Engine.read_meta Disk.read_only dir with id -> id | exception (Journal.Damaged m | Disk.Io m) -> refuse "%s: %s" name m in
        if id <> id_of name then refuse "database %s is not this cluster's (its id %s)" name id;
        let r = Ops.check ~tail:Journal.Copy ~live:false dir in
        (match r.damages with [] -> () | m :: _ -> refuse "database %s is damaged: %s" name m);
        if r.group < published name then refuse "database %s is at group %d, where this server holds %d" name r.group (published name);
        Option.iter (Ops.cut_copy dir) r.tail;
        Ops.mark_closed dir)
      cfg.databases;
    Ops.sync_dir partial;
    x, term
  with
  | exception Refuse m -> close (); Ops.rmrf partial; Refused (Printf.sprintf "the copy from %s is refused: %s" source m)
  | exception Replica.Broken m -> close (); Ops.rmrf partial; Refused (Printf.sprintf "the copy from %s broke: %s" source m)
  | exception Codec.Short -> close (); Ops.rmrf partial; Refused (Printf.sprintf "the copy from %s does not decode" source)
  | exception Unix.Unix_error (e, call, p) -> close (); Ops.rmrf partial; Refused (Printf.sprintf "the copy from %s: %s %s: %s" source call p (Unix.error_message e))
  | exception Ops.Refused m -> close (); Ops.rmrf partial; Refused (Printf.sprintf "the copy from %s: %s" source m)
  | x, term ->
    if not (decide x term) then (Ops.rmrf partial; Dropped x)
    else begin
      Replica.write_private (partial // "index") (Bytes.to_string (Raftlog.encode_copy ~index:x ~term ~source));
      Unix.rename partial (raft // "copy");
      Ops.sync_dir raft;
      Installed x
    end

(* Before the databases open: a copy that did not finish removed, one committed installed (each database replaced,
   the log made to start after the copy's index), the folder removed last *)
let at_start (cfg : Config.t) =
  let raft = cfg.data // "raft" in
  let partial = raft // "copy.partial" in
  let dir = raft // "copy" in
  let secure p = try Unix.chmod p (if Sys.is_directory p then 0o700 else 0o600) with Unix.Unix_error _ | Sys_error _ -> () in
  match
    if Sys.file_exists partial then begin
      Ops.rmrf partial;
      Ops.sync_dir raft;
      log "removed a copy of the databases that did not finish (a crash or a stop during it)"
    end;
    if is_dir dir then
      match Raftlog.decode_copy (Bytes.of_string (In_channel.with_open_bin (dir // "index") In_channel.input_all)) with
      | None | (exception Sys_error _) ->
        Ops.rmrf dir;
        Ops.sync_dir raft;
        log "removed a copy of the databases whose index does not check"
      | Some (x, term, source) ->
        List.iter
          (fun name ->
            if is_dir (dir // name) then begin
              let d = Config.database_dir cfg name in
              Ops.rmrf d;
              Unix.rename (dir // name) d;
              Ops.sync_dir cfg.data
            end)
          cfg.databases;
        Raftlog.install ~secure Disk.real raft ~cluster:cfg.id ~first:(x + 1) ~prev_term:term;
        Ops.rmrf dir;
        Ops.sync_dir raft;
        log "installed the copy of %s's databases at index %d: the log starts at %d" source x (x + 1)
  with
  | () -> Ok ()
  | exception Unix.Unix_error (e, call, p) -> Error (Printf.sprintf "the copy of the databases could not be installed: %s %s: %s" call p (Unix.error_message e))
  | exception Disk.Io m -> Error ("the copy of the databases could not be installed: " ^ m)
  | exception Raftlog.Damaged m -> Error m
