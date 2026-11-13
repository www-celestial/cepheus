(* The server process: listeners, I/O domains, a thread a connection, start and stop (design 2.1, 2.3).

   OCaml 5 threads of one domain share its runtime lock, which a system call releases and decoding, reading the
   store and coding do not: the connections are spread over k I/O domains (round robin), each with its own lock, so
   k requests run at once on k cores. A view is a persistent value: reads take no lock between them. Each database
   keeps its writer and syncer in their own domain (Engine.start). *)

open Cepheus

let log fmt = Printf.ksprintf (fun s -> prerr_endline ("cepheus: " ^ s)) fmt

type database = {
  core : Core.db;
  live : Engine.live;
  follow : Follow.t;
  watch : Watch.t;  (* its live questions over the wire *)
  page : Unix.file_descr;  (* the visibility page, read-only: what every local reader is passed (never closed) *)
  mutable checkpointed : int;
}

(* ---- one connection ---- *)

(* The writes of a connection wait in order: one database's writer answers them in the order they were sent, so the
   oldest is always the next to end; a write to another database at the head may hold a later reply a little, never
   lose it. Engine.deliver signals [wc] under [wm]. *)
type waiter = { wm : Mutex.t; wc : Condition.t; q : (Engine.req * ((Engine.receipt, Engine.error) result -> unit)) Queue.t;
                mutable thread : Thread.t option; mutable closing : bool }

let rec write_all fd b o n =
  if n > 0 then
    let k = Unix.write fd b o n in
    write_all fd b (o + k) (n - k)

let wait_loop w () =
  let go = ref true in
  while !go do
    Mutex.lock w.wm;
    while (Queue.is_empty w.q && not w.closing) || match Queue.peek_opt w.q with Some (r, _) -> r.res = None | None -> false do
      Condition.wait w.wc w.wm
    done;
    match Queue.take_opt w.q with
    | None -> Mutex.unlock w.wm; go := false
    | Some (r, k) ->
      Mutex.unlock w.wm;
      k (Option.get r.res)
  done

(* the sockets of the open connections, shut down at stop so that their threads wake from their reads *)
type sockets = { sm : Mutex.t; open_ : (Unix.file_descr, unit) Hashtbl.t }

(* how a connection's bytes travel: the socket itself (Unix socket), or TLS over it (TCP) *)
type io = { read : Bytes.t -> int -> int -> int; write : Bytes.t -> int -> int -> unit; bye : unit -> unit }

(* The idle limit (cluster.toml, [clients] idle_timeout): a connection must send a whole request within [idle]
   seconds of its accept and of its previous request, its TLS handshake included, and take what the server sends
   within [idle] seconds; otherwise it is closed. The socket's timeouts wake a blocked read or write at least that
   often (SO_RCVTIMEO, SO_SNDTIMEO: socket(7)); bytes that trickle in without making a request do not reset the clock.
   0: no limit. *)
let timeouts fd idle =
  if idle > 0 then begin
    Unix.setsockopt_float fd Unix.SO_RCVTIMEO (float idle);
    Unix.setsockopt_float fd Unix.SO_SNDTIMEO (float idle)
  end

exception Idle

let plain fd = { read = Unix.read fd; write = write_all fd; bye = ignore }

let over_tls (t : Tls.t) = { read = Tls.read t; write = Tls.write t; bye = (fun () -> Tls.close t) }

(* ---- a follow stream (a local reader, over the Unix socket: Follow) ----
   The connection's thread sends the database's events; another thread waits for the connection's end (the program
   closed it, or the server stops and shuts every socket down). Each run is passed as a descriptor opened for this
   reader alone (its own file offset), and the server's copy closed once sent. *)

let open_ro path = Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0

(* the runs' files, opened now, in order; a run a merge removed meanwhile fails (the reader connects again) *)
let run_files (runs : Follow.run list) =
  let opened = ref [] in
  match
    List.iter
      (fun (r : Follow.run) ->
        let fd =
          match r.tmp with
          | Some tmp -> ( try open_ro tmp with Unix.Unix_error (Unix.ENOENT, _, _) -> open_ro r.path)
          | None -> open_ro r.path
        in
        opened := fd :: !opened)
      runs
  with
  | () -> Ok (List.rev !opened)
  | exception Unix.Unix_error (e, _, p) -> List.iter Unix.close !opened; Error (p ^ ": " ^ Unix.error_message e)

let close_all = List.iter (fun fd -> try Unix.close fd with Unix.Unix_error _ -> ())

(* one wire frame, the descriptors riding on its first byte *)
let send_frame fd ~id ~kind ~flags body fds =
  let f = Buffer.create (Buffer.length body + Wire.header) in
  Wire.add_frame f ~id ~kind ~flags body;
  let b = Buffer.to_bytes f in
  Fdpass.send fd b 0 (Bytes.length b) fds

let piece = 1 lsl 20

let send_event fd = function
  | Follow.Frame f ->
    (* the head and the body's first piece, then pieces of the flag more: the last one without it *)
    let n = Buffer.length f.body in
    let b = Buffer.create (min n piece + 32) in
    Wire.put_frame_head b ~vseq:f.vseq ~first:f.first ~count:f.count;
    let k = min n piece in
    Buffer.add_string b (Buffer.sub f.body 0 k);
    send_frame fd ~id:0 ~kind:Wire.k_frame ~flags:(if k < n then Wire.f_more else 0) b [];
    let o = ref k in
    while !o < n do
      let k = min (n - !o) piece in
      let c = Buffer.create k in
      Buffer.add_string c (Buffer.sub f.body !o k);
      o := !o + k;
      send_frame fd ~id:0 ~kind:Wire.k_frame ~flags:(if !o < n then Wire.f_more else 0) c []
    done
  | Follow.Durable v ->
    let b = Buffer.create 16 in
    Codec.put_varint b v;
    send_frame fd ~id:0 ~kind:Wire.k_durable ~flags:0 b []
  | Follow.Runs r -> (
    match run_files r.runs with
    | Error m -> failwith ("a run to pass: " ^ m)
    | Ok fds ->
      let b = Buffer.create 64 in
      Wire.put_runs_push b ~vseq:r.vseq (List.map (fun (x : Follow.run) -> x.lo, x.hi) r.runs);
      Fun.protect ~finally:(fun () -> close_all fds) (fun () -> send_frame fd ~id:0 ~kind:Wire.k_runs ~flags:0 b fds))

(* The stream checks its token's rights before each batch of events, and every second, as a request would (G16): a
   token removed, or no longer allowed to read the database, ends it (the reader then reads through the server, and
   is refused). *)
let follow_stream (c : Core.conn) (d : database) fd ~id ~stopping =
  let fol = d.follow in
  let gone = Atomic.make false in
  let watcher =
    Thread.create
      (fun () ->
        let b = Bytes.create 64 in
        let rec go () =
          match Unix.read fd b 0 64 with
          | 0 -> ()
          | _ -> go ()
          | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _) -> if not (Atomic.get stopping) then go ()
          | exception Unix.Unix_error _ -> ()
        in
        go ();
        Atomic.set gone true;
        Follow.wake fol)
      ()
  in
  let allowed () = Core.refresh_rights c; c.token <> None && c.rights.(d.core.index) <> None in
  (* the stream ends when the program closes it, the server stops, or the token no longer may read (G16: the ticker
     wakes the stream every second, as the token file is read again) *)
  let stop () = Atomic.get gone || Atomic.get stopping || not (allowed ()) in
  (* registered, then the page's and the runs' files opened: a merge may remove a run between the two, then again *)
  let rec start tries =
    let f, vseq, vis = Follow.register fol in
    let runs = Follow.names fol.sdir vis.runs in
    match run_files runs with
    | Ok fds -> Ok (f, vseq, vis, runs, fds)
    | Error m -> Follow.unregister fol f; if tries > 0 && not (stop ()) then start (tries - 1) else Error m
  in
  (match start 8 with
   | Error m ->
     let b = Buffer.create 64 in
     Wire.put_reply b (Wire.Err { code = "busy"; message = "the database's files could not be passed: " ^ m });
     (try send_frame fd ~id ~kind:Wire.k_follow ~flags:Wire.f_error b [] with Unix.Unix_error _ -> ())
   | Ok (f, vseq, vis, runs, fds) ->
     (try
        let b = Buffer.create 256 in
        Wire.put_reply b (Wire.Start { id = d.live.e.id; vseq; runs = List.map (fun (r : Follow.run) -> r.lo, r.hi) runs });
        (* the page's descriptor is passed, never closed here (its lock); the runs' copies are closed once sent *)
        Fun.protect ~finally:(fun () -> close_all fds) (fun () -> send_frame fd ~id ~kind:Wire.k_follow ~flags:0 b (d.page :: fds));
        (* the groups after the newest run, up to the state visible under the number; then the number *)
        Follow.catch_up Disk.real d.live.e vis (send_event fd);
        send_event fd (Follow.Frame { vseq; first = vis.group + 1; count = 0; body = Buffer.create 0 });
        let rec loop () =
          match Follow.take ~stop fol f with
          | [] -> ()
          | evs -> if not (stop ()) then (List.iter (send_event fd) evs; loop ())
        in
        loop ()
      with Unix.Unix_error _ | Failure _ | Journal.Damaged _ -> ());
     Follow.unregister fol f);
  (* the watcher wakes from its read *)
  (try Unix.shutdown fd Unix.SHUTDOWN_ALL with Unix.Unix_error _ -> ());
  Thread.join watcher

let rec connection (srv : Core.t) (dbs : database array) socks ~idle tls fd =
  Mutex.protect socks.sm (fun () -> Hashtbl.replace socks.open_ fd ());
  (try timeouts fd idle with Unix.Unix_error _ -> ());
  match tls with
  | None -> serve_conn srv dbs socks ~idle fd (plain fd)
  | Some ctx -> (
    (* the handshake in the connection's own thread: its computation (milliseconds) without the runtime lock; a
       peer silent for the idle limit in the middle of it makes a read fail (EAGAIN), and the connection closes *)
    match Tls.handshake ctx fd ~server:true ~host:"" with
    | Ok t -> serve_conn ~tls:t srv dbs socks ~idle fd (over_tls t)
    | Error _ ->
      Mutex.protect socks.sm (fun () -> Hashtbl.remove socks.open_ fd);
      (try Unix.close fd with Unix.Unix_error _ -> ()))

and serve_conn ?tls (srv : Core.t) (dbs : database array) socks ~idle fd io =
  let dead = ref false in
  let scratch = ref (Bytes.create 65536) in
  let c_ref = ref None in
  (* the replies sent in their order: the reading thread and the writes' thread both flush, under the output's lock
     (held through the system call: the other waits, as it would for the socket) *)
  let flush () =
    match !c_ref with
    | None -> ()
    | Some (c : Core.conn) ->
      Mutex.lock c.om;
      let n = Buffer.length c.out in
      if n > 0 then begin
        if n > Bytes.length !scratch then scratch := Bytes.create (max n (2 * Bytes.length !scratch));
        Buffer.blit c.out 0 !scratch 0 n;
        Buffer.clear c.out;
        if not !dead then (try io.write !scratch 0 n with Unix.Unix_error _ | Failure _ -> dead := true)
      end;
      Mutex.unlock c.om
  in
  let w = { wm = Mutex.create (); wc = Condition.create (); q = Queue.create (); thread = None; closing = false } in
  let submit (d : Core.db) ops by why k =
    let live = dbs.(d.index).live in
    let r = { Engine.w = (ops, by, why); res = None; rm = w.wm; rc = w.wc } in
    Mutex.lock w.wm;
    Queue.push (r, k) w.q;
    if w.thread = None then w.thread <- Some (Thread.create (wait_loop w) ());
    Condition.broadcast w.wc;
    Mutex.unlock w.wm;
    if not (Engine.submit live (Engine.Write r)) then Engine.deliver r (Error Engine.Closed)
  in
  (* the watches' pushes: a thread of the connection's sends them as they come, made at the first; the hubs only append
     to the connection's pushes and wake it, so that a slow program never holds a hub *)
  let pusher = ref None and pm = Mutex.create () and pc = Condition.create () and pending = ref false and ending = ref false in
  let push_loop () =
    let go = ref true in
    while !go do
      Mutex.lock pm;
      while (not !pending) && not !ending do Condition.wait pc pm done;
      pending := false;
      let stop = !ending in
      Mutex.unlock pm;
      (match !c_ref with Some c -> if Core.move_pushes c then flush () | None -> ());
      if stop then go := false
    done
  in
  let wake () =
    Mutex.lock pm;
    pending := true;
    if !pusher = None && not !ending then pusher := Some (Thread.create push_loop ());
    Condition.signal pc;
    Mutex.unlock pm
  in
  let c = Core.connect ~wake srv ~flush ~submit in
  c_ref := Some c;
  let buf = ref (Bytes.create 65536) and have = ref 0 in
  let go = ref true in
  (* the time of the accept, then of each whole request *)
  let last = ref (Unix.gettimeofday ()) in
  let read_or_idle b o n =
    let rec go () =
      match io.read b o n with
      | k -> k
      | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
        if Unix.gettimeofday () -. !last >= float idle then raise Idle else go ()
    in
    go ()
  in
  (try
     while !go do
       (* the frames already here first; a read only when a frame is not whole *)
       let before = c.requests in
       let used, why = Core.input c !buf 0 !have in
       if c.requests > before then last := Unix.gettimeofday ();
       Bytes.blit !buf used !buf 0 (!have - used);
       have := !have - used;
       flush ();
       match why with
       | Core.Shut -> go := false
       | _ when !dead -> go := false
       | Core.Follow (d, id) ->
         (* local reads: over the Unix socket only (a descriptor cannot cross machines) *)
         if tls <> None then begin
           Core.err c ~id ~kind:Wire.k_follow "denied" "local reads are for programs on the server's machine, over its Unix socket";
           flush ()
         end
         else follow_stream c dbs.(d.index) fd ~id ~stopping:srv.stopping;
         go := false
       | Core.Full -> Core.wait_room c
       | Core.Need ->
         (* room for the frame begun: its length is known once its first 4 bytes are here *)
         if !have >= 4 then begin
           let need = 4 + Wire.u32 !buf 0 in
           if need > Bytes.length !buf then begin
             let b = Bytes.create need in
             Bytes.blit !buf 0 b 0 !have;
             buf := b
           end
         end;
         let k = read_or_idle !buf !have (Bytes.length !buf - !have) in
         if k = 0 then go := false
         else begin
           have := !have + k;
           (* bytes that trickle in without a whole request do not keep the connection *)
           if idle > 0 && Unix.gettimeofday () -. !last >= float idle then raise Idle
         end
     done
   with
   | Idle ->
     Core.err c ~id:0 ~kind:0 "idle" "no request for %d s (idle_timeout): the connection is closed" idle;
     flush ()
   | Unix.Unix_error _ | Failure _ -> ());
  (* the writes in flight are answered (or fail to send) before the connection goes; its watches end *)
  Core.drain c;
  Core.disconnect c;
  Mutex.lock pm;
  ending := true;
  Condition.signal pc;
  let p = !pusher in
  Mutex.unlock pm;
  Option.iter Thread.join p;
  Mutex.lock w.wm;
  w.closing <- true;
  Condition.broadcast w.wc;
  Mutex.unlock w.wm;
  Option.iter Thread.join w.thread;
  (try io.bye () with Unix.Unix_error _ | Failure _ -> ());
  Mutex.protect socks.sm (fun () -> Hashtbl.remove socks.open_ fd);
  (try Unix.close fd with Unix.Unix_error _ -> ())

(* ---- I/O domains ---- *)

type iod = { m : Mutex.t; cv : Condition.t; fds : (Unix.file_descr * Tls.ctx option) Queue.t; mutable stop : bool; mutable nconn : int }

(* a thread a connection, in this domain; at stop, the domain ends once its connections have; [opened] counts the
   connections of the server, from their accept to their close *)
let io_domain srv dbs socks ~idle ~opened (io : iod) () =
  let go = ref true in
  while !go do
    Mutex.lock io.m;
    while Queue.is_empty io.fds && not io.stop do Condition.wait io.cv io.m done;
    let fd = Queue.take_opt io.fds in
    if fd <> None then io.nconn <- io.nconn + 1;
    Mutex.unlock io.m;
    match fd with
    | Some (fd, tls) ->
      let run () =
        Fun.protect (fun () -> connection srv dbs socks ~idle tls fd)
          ~finally:(fun () ->
            Atomic.decr opened;
            Mutex.protect io.m (fun () -> io.nconn <- io.nconn - 1; Condition.broadcast io.cv))
      in
      ignore (Thread.create run ())
    | None -> go := false
  done;
  Mutex.protect io.m (fun () -> while io.nconn > 0 do Condition.wait io.cv io.m done)

(* ---- the data directory ---- *)

let lock_data dir =
  (* a new data directory's name is forced into its parent: a power loss must not take it with its databases *)
  (match Unix.mkdir dir 0o700 with
   | () -> Disk.real.sync_dir (Filename.dirname dir)
   | exception Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let path = Filename.concat dir "cepheus.lock" in
  let fd = Unix.openfile path [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_CLOEXEC ] 0o600 in
  match Unix.lockf fd Unix.F_TLOCK 0 with
  | () ->
    Unix.ftruncate fd 0;
    let pid = string_of_int (Unix.getpid ()) ^ "\n" in
    ignore (Unix.write_substring fd pid 0 (String.length pid));
    Ok fd
  | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EACCES), _, _) ->
    Unix.close fd;
    Error (Printf.sprintf "%s is held by another server (its pid is in %s)" dir path)

(* the server's id, made at its first start and kept in the data directory *)
let server_id dir =
  let path = Filename.concat dir "cepheus.server" in
  if Sys.file_exists path then String.trim (In_channel.with_open_bin path In_channel.input_all)
  else begin
    let id = "cph-s-" ^ Tokens.hex (Tokens.random 8) in
    Disk.write_file Disk.real path (Bytes.of_string (id ^ "\n"));
    id
  end

(* ---- listeners ---- *)

let unix_listener path =
  if Sys.file_exists path then begin
    (* a socket left by a server that died: removed; one a live server answers on: refused *)
    let s = Unix.socket ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    let alive = match Unix.connect s (Unix.ADDR_UNIX path) with () -> true | exception Unix.Unix_error _ -> false in
    Unix.close s;
    if alive then failwith (Printf.sprintf "a server already listens on %s" path);
    Unix.unlink path
  end;
  let s = Unix.socket ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.bind s (Unix.ADDR_UNIX path);
  Unix.listen s 256;
  s

let tcp_listener host port =
  let addr = Config.resolve host port in
  let s = Unix.socket ~cloexec:true (Unix.domain_of_sockaddr addr) Unix.SOCK_STREAM 0 in
  Unix.setsockopt s Unix.SO_REUSEADDR true;
  Unix.bind s addr;
  Unix.listen s 256;
  s

(* systemd's readiness: one datagram on $NOTIFY_SOCKET (sd_notify(3)) *)
let notify msg =
  match Sys.getenv_opt "NOTIFY_SOCKET" with
  | None | Some "" -> ()
  | Some p ->
    let p = if p.[0] = '@' then "\000" ^ String.sub p 1 (String.length p - 1) else p in
    (try
       let s = Unix.socket ~cloexec:true Unix.PF_UNIX Unix.SOCK_DGRAM 0 in
       ignore (Unix.sendto_substring s msg 0 (String.length msg) [] (Unix.ADDR_UNIX p));
       Unix.close s
     with Unix.Unix_error _ -> ())

(* ---- the server ---- *)

let file_stamp path = match Unix.stat path with st -> Some (st.st_mtime, st.st_size, st.st_ino) | exception Unix.Unix_error _ -> None

let open_databases (cfg : Config.t) wal =
  let one i name =
    let dir = Config.database_dir cfg name in
    match Engine.open_ ~buffer:(Wal.frames wal) Disk.real dir with
    | Error e -> Error (Printf.sprintf "database %s: %s" name (Engine.message e))
    | Ok e ->
      let sessions =
        try Ok (Sessions.load Disk.real dir e.id)
        with Journal.Damaged m -> Engine.close e; Error (Printf.sprintf "database %s: %s" name m)
      in
      match sessions with
      | Error m -> Error m
      | Ok sessions -> (
        match Follow.open_page (Follow.page_path e.id) with
        | exception Unix.Unix_error (err, _, p) ->
          Engine.close e;
          Error (Printf.sprintf "database %s: %s: %s" name p (Unix.error_message err))
        | exception Failure m -> Engine.close e; Error (Printf.sprintf "database %s: %s" name m)
        | word, page ->
          (* the follow stream and the live questions first: the writer calls them from its first frame *)
          let follow = Follow.create e word in
          let watch = Watch.create e in
          let hooks =
            { Engine.before = (fun b -> Follow.before follow b; Watch.before watch b);
              after = (fun () -> Follow.after follow; Watch.after watch) }
          in
          let live = Engine.start ~follow:hooks e in
          let core =
            { Core.name; index = i; dir; view = (fun () -> Follow.view follow); sessions;
              more = (fun () -> Follow.status follow @ Watch.status watch); hub = (fun () -> Watch.hub watch);
              files = Files.cell ~master:(fun () -> Files.master_file (Config.vault_key_path cfg)) (Filename.concat dir "vault") }
          in
          Ok { core; live; follow; watch; page; checkpointed = (Atomic.get e.published).group })
  in
  (* in parallel, a domain each, at most [domains] at once *)
  let names = Array.of_list cfg.databases in
  let res = Array.make (Array.length names) (Error "not opened") in
  let i = ref 0 in
  while !i < Array.length names do
    let batch = List.init (min cfg.domains (Array.length names - !i)) (fun j -> !i + j) in
    let ds = List.map (fun j -> j, Domain.spawn (fun () -> one j names.(j))) batch in
    List.iter (fun (j, d) -> res.(j) <- Domain.join d) ds;
    i := !i + List.length batch
  done;
  let errs = Array.to_list res |> List.filter_map (function Error m -> Some m | Ok _ -> None) in
  if errs <> [] then begin
    Array.iter (function Ok d -> Engine.stop d.live | Error _ -> ()) res;
    Error (String.concat "; " errs)
  end
  else Ok (Array.map (function Ok d -> d | Error _ -> assert false) res)

let checkpoint d =
  let g = (Atomic.get d.live.e.published).group in
  if g <> d.checkpointed then begin
    (match Sessions.save Disk.real d.core.dir d.core.sessions ~published:g ~now:(Disk.real.now ()) with
     | () -> ()
     | exception Disk.Io m -> log "database %s: the sessions could not be saved: %s" d.core.name m);
    d.checkpointed <- g
  end

let serve (cfg : Config.t) =
  Files.log_made := (fun path -> log "made the vault's master key %s: keep a copy apart from the data (without it, no file opens)" path);
  (* SIGTERM and SIGINT are waited for by the main thread: blocked first, so that every thread and domain made from
     here on (the databases' writers too) blocks them and none of them is killed by one *)
  let sigs = [ Sys.sigterm; Sys.sigint ] in
  ignore (Thread.sigmask Unix.SIG_BLOCK sigs);
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  match lock_data cfg.data with
  | Error m -> Error m
  | Ok lockfd -> (
    Pages.set_capacity cfg.cache;
    let tokens_file = Config.tokens_path cfg in
    match Tokens.load tokens_file with
    | Error m -> Error m
    | Ok tokens -> (
      let t0 = Unix.gettimeofday () in
      (* the commit buffer's frames, which each database's open writes again into its journal; then the buffer is
         emptied, and every journal shares it *)
      let opened =
        match Wal.recover Disk.real cfg.data with
        | exception Journal.Damaged m -> Error m
        | exception Disk.Io m -> Error m
        | wal -> (
          match open_databases cfg wal with
          | Error m -> Error m
          | Ok dbs -> (
            match Wal.start wal with
            | () -> Array.iter (fun d -> Wal.attach wal d.live.e.id d.live.e.journal) dbs; Ok (wal, dbs)
            | exception (Journal.Damaged m | Disk.Io m) -> Array.iter (fun d -> Engine.stop d.live) dbs; Error m))
      in
      match opened with
      | Error m -> Error m
      | Ok (wal, dbs) -> (
        let opened_ms = (Unix.gettimeofday () -. t0) *. 1e3 in
        let sid = server_id cfg.data in
        let stop_all () = Array.iter (fun d -> Files.close d.core.files; Engine.stop d.live) dbs; Wal.stop wal in
        let srv =
          Core.create ~server_id:sid ~cluster_id:cfg.id ~dbs:(Array.map (fun d -> d.core) dbs) ~tokens ~now:Disk.real.now
            ~new_session:(fun () -> 1 + (Int64.to_int (String.get_int64_le (Tokens.random 8) 0) land 0x3FFF_FFFF_FFFF_FFFF))
            ~more:(fun () -> Wal.status wal) ()
        in
        (* TLS for TCP: the server's certificate and key; programs show no certificate (a token) *)
        match
          Option.map
            (fun (t : Config.tls) ->
              match Tls.server_ctx ~ca:t.ca ~cert:t.cert ~key:t.key ~verify_peer:false with
              | Ok ctx -> ctx
              | Error m -> failwith ("[tls]: " ^ m))
            cfg.tls
        with
        | exception Failure m ->
          stop_all ();
          Unix.close lockfd;
          Error m
        | tls_ctx ->
        match
          let sock = Option.map unix_listener (Config.socket_path cfg) in
          let tcp = Option.map (fun (h, p) -> tcp_listener h p) cfg.listen in
          sock, tcp
        with
        | exception ((Failure _ | Unix.Unix_error _) as e) ->
          let m = match e with Unix.Unix_error (err, call, arg) -> Printf.sprintf "%s %s: %s" call arg (Unix.error_message err) | Failure m -> m | _ -> "" in
          stop_all ();
          Unix.close lockfd;
          Error m
        | sock, tcp ->
          let ios = Array.init cfg.domains (fun _ -> { m = Mutex.create (); cv = Condition.create (); fds = Queue.create (); stop = false; nconn = 0 }) in
          let socks = { sm = Mutex.create (); open_ = Hashtbl.create 64 } in
          let opened = Atomic.make 0 in
          let doms = Array.map (fun io -> Domain.spawn (io_domain srv dbs socks ~idle:cfg.idle_timeout ~opened io)) ios in
          let next = Atomic.make 0 in
          let accepting = Atomic.make true in
          let refused = Atomic.make 0 and noted = ref 0. in
          (* At the limit of connections ([clients] max_connections), a new one is closed at once: over the Unix
             socket after a frame saying why; over TCP with no word, before its TLS handshake, so that a refused
             connection costs no handshake's computation (milliseconds). The log says so at most once a second. *)
          let refuse fd tls =
            Atomic.incr refused;
            if tls = None then begin
              let b = Buffer.create 128 in
              Wire.put_reply b (Wire.Err { code = "too_many_connections";
                                           message = Printf.sprintf "the server holds its limit of %d connections (max_connections)" cfg.max_connections });
              let f = Buffer.create 160 in
              Wire.add_frame f ~id:0 ~kind:0 ~flags:Wire.f_error b;
              (try Unix.setsockopt_float fd Unix.SO_SNDTIMEO 1.0; ignore (Unix.write fd (Buffer.to_bytes f) 0 (Buffer.length f)) with Unix.Unix_error _ -> ())
            end;
            (try Unix.close fd with Unix.Unix_error _ -> ());
            let now = Unix.gettimeofday () in
            if now -. !noted >= 1.0 then begin
              noted := now;
              log "%d connections refused so far: the limit of %d is reached (max_connections)" (Atomic.get refused) cfg.max_connections
            end
          in
          let accept_loop s nodelay tls () =
            while Atomic.get accepting do
              match Unix.accept ~cloexec:true s with
              | fd, _ ->
                if Atomic.fetch_and_add opened 1 >= cfg.max_connections then (Atomic.decr opened; refuse fd tls)
                else begin
                  if nodelay then Unix.setsockopt fd Unix.TCP_NODELAY true;
                  let io = ios.(Atomic.fetch_and_add next 1 mod Array.length ios) in
                  Mutex.protect io.m (fun () -> Queue.push (fd, tls) io.fds; Condition.signal io.cv)
                end
              | exception Unix.Unix_error ((Unix.EINTR | Unix.ECONNABORTED), _, _) -> ()
              | exception Unix.Unix_error ((Unix.EMFILE | Unix.ENFILE | Unix.ENOBUFS | Unix.ENOMEM), _, _) ->
                (* out of descriptors or memory: the connection waits in the backlog; the server goes on *)
                log "accept: out of file descriptors or memory (raise LimitNOFILE, or lower max_connections)";
                Thread.delay 0.1
              | exception Unix.Unix_error _ -> Atomic.set accepting false
            done
          in
          let acceptors =
            List.filter_map Fun.id
              [ Option.map (fun s -> Thread.create (accept_loop s false None) ()) sock;
                Option.map (fun s -> Thread.create (accept_loop s true tls_ctx) ()) tcp ]
          in
          (* every second: tokens.toml reloaded when it changed, the session tables saved, a writer that stopped on a
             failed disk stops the server (G10: systemd starts it again, and recovery decides) *)
          let stamp = ref (file_stamp tokens_file) in
          let failed = Atomic.make None in
          let ticking = Atomic.make true in
          let ticker () =
            while Atomic.get ticking do
              Thread.delay 1.0;
              let s = file_stamp tokens_file in
              if s <> !stamp then begin
                stamp := s;
                match Tokens.load tokens_file with
                | Ok t -> Atomic.set srv.tokens t; log "%s reloaded: %d tokens" tokens_file (List.length t.tokens)
                | Error m -> log "%s not reloaded: %s" tokens_file m
              end;
              Array.iter checkpoint dbs;
              Array.iter (fun d -> Follow.tick d.follow) dbs;
              Array.iter
                (fun d -> match d.live.e.stopped with
                   | Some e when Atomic.get failed = None ->
                     Atomic.set failed (Some (Printf.sprintf "database %s stopped: %s" d.core.name (Engine.message e)));
                     Unix.kill (Unix.getpid ()) Sys.sigterm
                   | _ -> ())
                dbs
            done
          in
          let tk = Thread.create ticker () in
          log "ready in %.1f ms: %s; %s%s; %d I/O domains, at most %d connections; server %s, cluster %s" opened_ms
            (String.concat ", " (Array.to_list (Array.map (fun d -> Printf.sprintf "%s at group %d" d.core.name (d.core.view ()).group) dbs)))
            (match Config.socket_path cfg with Some p -> "socket " ^ p | None -> "no socket")
            (match cfg.listen with Some (h, p) -> Printf.sprintf ", tcp %s:%d" h p | None -> "")
            cfg.domains cfg.max_connections sid cfg.id;
          notify "READY=1";
          ignore (Thread.wait_signal sigs);
          (* stop: no new connection, no new request; the writes in flight end and are answered; each database closed
             cleanly (its marker), its sessions saved *)
          notify "STOPPING=1";
          log "stopping";
          Atomic.set srv.stopping true;
          Atomic.set accepting false;
          let close_listener s = try Unix.shutdown s Unix.SHUTDOWN_ALL with Unix.Unix_error _ -> () in
          Option.iter close_listener sock;
          Option.iter close_listener tcp;
          List.iter Thread.join acceptors;
          Option.iter Unix.close sock;
          Option.iter Unix.close tcp;
          Option.iter (fun p -> try Unix.unlink p with Unix.Unix_error _ -> ()) (Config.socket_path cfg);
          Array.iter (fun d -> Follow.wake d.follow; Watch.stop d.watch "stopping" "the server is stopping") dbs;
          let conns = Mutex.protect srv.cm (fun () -> Hashtbl.fold (fun _ c acc -> c :: acc) srv.conns []) in
          List.iter Core.drain conns;
          Atomic.set ticking false;
          Thread.join tk;
          stop_all ();
          Array.iter (fun d -> d.checkpointed <- -1; checkpoint d) dbs;
          (* the connections' threads wake from their reads and end *)
          Mutex.protect socks.sm (fun () ->
              Hashtbl.iter (fun fd () -> try Unix.shutdown fd Unix.SHUTDOWN_ALL with Unix.Unix_error _ -> ()) socks.open_);
          Array.iter (fun io -> Mutex.protect io.m (fun () -> io.stop <- true; Condition.signal io.cv)) ios;
          Array.iter Domain.join doms;
          Unix.close lockfd;
          log "stopped";
          match Atomic.get failed with Some m -> Error m | None -> Ok ())))
