(* The server process: listeners, I/O domains, a thread a connection, start and stop (design 2.1, 2.3).

   OCaml 5 threads of one domain share its runtime lock, which a system call releases and decoding, reading the
   store and coding do not: the connections are spread over k I/O domains (round robin), each with its own lock, so
   k requests run at once on k cores. A view is a persistent value: reads take no lock between them. Each database
   keeps its writer and syncer in their own domain (Engine.start). *)

open Cepheus

let log fmt = Printf.ksprintf (fun s -> prerr_endline ("cepheus: " ^ s)) fmt

type database = { core : Core.db; live : Engine.live; mutable checkpointed : int }

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

let connection (srv : Core.t) (dbs : database array) socks fd =
  Mutex.protect socks.sm (fun () -> Hashtbl.replace socks.open_ fd ());
  let wmx = Mutex.create () in
  let dead = ref false in
  let scratch = ref (Bytes.create 65536) in
  let c_ref = ref None in
  let flush () =
    match !c_ref with
    | None -> ()
    | Some (c : Core.conn) ->
      Mutex.protect wmx (fun () ->
          let n =
            Mutex.protect c.om (fun () ->
                let n = Buffer.length c.out in
                if n > Bytes.length !scratch then scratch := Bytes.create (max n (2 * Bytes.length !scratch));
                Buffer.blit c.out 0 !scratch 0 n;
                Buffer.clear c.out;
                n)
          in
          if not !dead then try write_all fd !scratch 0 n with Unix.Unix_error _ -> dead := true)
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
  let c = Core.connect srv ~flush ~submit in
  c_ref := Some c;
  let buf = ref (Bytes.create 65536) and have = ref 0 in
  let go = ref true in
  (try
     while !go do
       (* the frames already here first; a read only when a frame is not whole *)
       let used, why = Core.input c !buf 0 !have in
       Bytes.blit !buf used !buf 0 (!have - used);
       have := !have - used;
       flush ();
       match why with
       | Core.Shut -> go := false
       | _ when !dead -> go := false
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
         let k = Unix.read fd !buf !have (Bytes.length !buf - !have) in
         if k = 0 then go := false else have := !have + k
     done
   with Unix.Unix_error _ -> ());
  (* the writes in flight are answered (or fail to send) before the connection goes *)
  Core.drain c;
  Mutex.lock w.wm;
  w.closing <- true;
  Condition.broadcast w.wc;
  Mutex.unlock w.wm;
  Option.iter Thread.join w.thread;
  Core.disconnect c;
  Mutex.protect socks.sm (fun () -> Hashtbl.remove socks.open_ fd);
  (try Unix.close fd with Unix.Unix_error _ -> ())

(* ---- I/O domains ---- *)

type io = { m : Mutex.t; cv : Condition.t; fds : Unix.file_descr Queue.t; mutable stop : bool; mutable nconn : int }

(* a thread a connection, in this domain; at stop, the domain ends once its connections have *)
let io_domain srv dbs socks (io : io) () =
  let go = ref true in
  while !go do
    Mutex.lock io.m;
    while Queue.is_empty io.fds && not io.stop do Condition.wait io.cv io.m done;
    let fd = Queue.take_opt io.fds in
    if fd <> None then io.nconn <- io.nconn + 1;
    Mutex.unlock io.m;
    match fd with
    | Some fd ->
      let run () =
        Fun.protect (fun () -> connection srv dbs socks fd)
          ~finally:(fun () -> Mutex.protect io.m (fun () -> io.nconn <- io.nconn - 1; Condition.broadcast io.cv))
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

let resolve host port =
  match Unix.getaddrinfo host (string_of_int port) [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ] with
  | ai :: _ -> ai.Unix.ai_addr
  | [] -> failwith (Printf.sprintf "%s does not resolve" host)

let tcp_listener host port =
  let addr = resolve host port in
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

let open_databases (cfg : Config.t) =
  let one i name =
    let dir = Config.database_dir cfg name in
    match Engine.open_ Disk.real dir with
    | Error e -> Error (Printf.sprintf "database %s: %s" name (Engine.message e))
    | Ok e ->
      let sessions =
        try Ok (Sessions.load Disk.real dir e.id)
        with Journal.Damaged m -> Engine.close e; Error (Printf.sprintf "database %s: %s" name m)
      in
      Result.map
        (fun sessions ->
          let live = Engine.start e in
          let core = { Core.name; index = i; dir; view = (fun () -> Atomic.get live.e.published); sessions } in
          { core; live; checkpointed = (Atomic.get e.published).group })
        sessions
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
      match open_databases cfg with
      | Error m -> Error m
      | Ok dbs -> (
        let opened_ms = (Unix.gettimeofday () -. t0) *. 1e3 in
        let sid = server_id cfg.data in
        let srv =
          Core.create ~server_id:sid ~cluster_id:cfg.id ~dbs:(Array.map (fun d -> d.core) dbs) ~tokens ~now:Disk.real.now
            ~new_session:(fun () -> 1 + (Int64.to_int (String.get_int64_le (Tokens.random 8) 0) land 0x3FFF_FFFF_FFFF_FFFF))
            ()
        in
        match
          let sock = Option.map unix_listener (Config.socket_path cfg) in
          let tcp = Option.map (fun (h, p) -> tcp_listener h p) cfg.listen in
          sock, tcp
        with
        | exception (Failure m | Unix.Unix_error (_, _, m)) ->
          Array.iter (fun d -> Engine.stop d.live) dbs;
          Unix.close lockfd;
          Error m
        | sock, tcp ->
          let ios = Array.init cfg.domains (fun _ -> { m = Mutex.create (); cv = Condition.create (); fds = Queue.create (); stop = false; nconn = 0 }) in
          let socks = { sm = Mutex.create (); open_ = Hashtbl.create 64 } in
          let doms = Array.map (fun io -> Domain.spawn (io_domain srv dbs socks io)) ios in
          let next = Atomic.make 0 in
          let accepting = Atomic.make true in
          let accept_loop s nodelay () =
            while Atomic.get accepting do
              match Unix.accept ~cloexec:true s with
              | fd, _ ->
                if nodelay then Unix.setsockopt fd Unix.TCP_NODELAY true;
                let io = ios.(Atomic.fetch_and_add next 1 mod Array.length ios) in
                Mutex.protect io.m (fun () -> Queue.push fd io.fds; Condition.signal io.cv)
              | exception Unix.Unix_error ((Unix.EINTR | Unix.ECONNABORTED), _, _) -> ()
              | exception Unix.Unix_error _ -> Atomic.set accepting false
            done
          in
          let acceptors =
            List.filter_map Fun.id
              [ Option.map (fun s -> Thread.create (accept_loop s false) ()) sock;
                Option.map (fun s -> Thread.create (accept_loop s true) ()) tcp ]
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
          log "ready in %.1f ms: %s; %s%s; %d I/O domains; server %s, cluster %s" opened_ms
            (String.concat ", " (Array.to_list (Array.map (fun d -> Printf.sprintf "%s at group %d" d.core.name (d.core.view ()).group) dbs)))
            (match Config.socket_path cfg with Some p -> "socket " ^ p | None -> "no socket")
            (match cfg.listen with Some (h, p) -> Printf.sprintf ", tcp %s:%d" h p | None -> "")
            cfg.domains sid cfg.id;
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
          let conns = Mutex.protect srv.cm (fun () -> Hashtbl.fold (fun _ c acc -> c :: acc) srv.conns []) in
          List.iter Core.drain conns;
          Atomic.set ticking false;
          Thread.join tk;
          Array.iter (fun d -> Engine.stop d.live) dbs;
          Array.iter (fun d -> d.checkpointed <- -1; checkpoint d) dbs;
          (* the connections' threads wake from their reads and end *)
          Mutex.protect socks.sm (fun () ->
              Hashtbl.iter (fun fd () -> try Unix.shutdown fd Unix.SHUTDOWN_ALL with Unix.Unix_error _ -> ()) socks.open_);
          Array.iter (fun io -> Mutex.protect io.m (fun () -> io.stop <- true; Condition.signal io.cv)) ios;
          Array.iter Domain.join doms;
          Unix.close lockfd;
          log "stopped";
          match Atomic.get failed with Some m -> Error m | None -> Ok ())))
