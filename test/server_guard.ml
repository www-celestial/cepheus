(* What a connection does not expect, over real sockets: Net.connection serves each one in a thread of its own, on a
   database whose reads raise when the test says (a bug of the request, as the planner's at 64 variables was). Then:
   - a request that raises, on a connection with a watch (the thread of its pushes made) and a write in flight (the
     thread of its replies): the write answered, the request answered internal, the socket closed by the server; the
     connection's thread ends, its watch dropped, the server's descriptors and threads back to what they were;
   - 200 connections in a row, each made to fail by another exception: no descriptor nor thread left over, so a client
     that fails the server in a loop exhausts nothing; the log holds a few lines (one a second);
   - a failure in another thread of a connection (Core.broke, as a write's reply or a push that fails calls it) while
     its reading thread waits in a read, over a Unix socket and over TCP: the reading thread wakes, says internal on
     id 0, and closes; a request sent after it is never answered;
   - after each, a new connection is served.

     server_guard.exe DIR *)

open Cepheus
open Cepheus_server
module C = Check

let fds () = Array.length (Sys.readdir "/proc/self/fd")
let threads () = Array.length (Sys.readdir "/proc/self/task")

(* the number back at [n] within 5 s (threads end, sockets close, a little after the reply) *)
let settles f n =
  let t0 = Unix.gettimeofday () in
  while f () <> n && Unix.gettimeofday () -. t0 < 5. do Thread.delay 0.005 done;
  f ()

(* [ended] set within 5 s: a thread ends a little after its socket closes *)
let ends ended =
  let t0 = Unix.gettimeofday () in
  while not (Atomic.get ended) && Unix.gettimeofday () -. t0 < 5. do Thread.delay 0.005 done;
  Atomic.get ended

let internal_message = "the server failed (its log says why): the connection is closed"

(* ---- a client of raw frames ---- *)

type peer = { fd : Unix.file_descr; mutable buf : Bytes.t; mutable n : int }
type got = Frame of int * int * int * Bytes.t | Eof | Timeout

let peer fd = Unix.setsockopt_float fd Unix.SO_RCVTIMEO 5.0; { fd; buf = Bytes.create 65536; n = 0 }

let send p ~id req =
  let b = Buffer.create 64 and f = Buffer.create 64 in
  Wire.put_request b req;
  Wire.add_frame f ~id ~kind:(Wire.request_kind req) ~flags:0 b;
  let s = Buffer.to_bytes f in
  let rec go o = if o < Bytes.length s then go (o + Unix.write p.fd s o (Bytes.length s - o)) in
  (* a socket whose reading side the server shut down refuses (EPIPE) *)
  try go 0 with Unix.Unix_error _ -> ()

let rec next p =
  if p.n >= 4 && p.n >= 4 + Wire.u32 p.buf 0 then begin
    let len = Wire.u32 p.buf 0 in
    let f = Frame (Wire.u32 p.buf 4, Bytes.get_uint8 p.buf 8, Bytes.get_uint8 p.buf 9, Bytes.sub p.buf Wire.header (len - 6)) in
    Bytes.blit p.buf (4 + len) p.buf 0 (p.n - 4 - len);
    p.n <- p.n - 4 - len;
    f
  end
  else begin
    if p.n >= 4 && 4 + Wire.u32 p.buf 0 > Bytes.length p.buf then begin
      let b = Bytes.create (4 + Wire.u32 p.buf 0) in
      Bytes.blit p.buf 0 b 0 p.n;
      p.buf <- b
    end;
    match Unix.read p.fd p.buf p.n (Bytes.length p.buf - p.n) with
    | 0 -> Eof
    | k -> p.n <- p.n + k; next p
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> Timeout
    | exception Unix.Unix_error (Unix.ECONNRESET, _, _) -> Eof
  end

(* every frame until the server closes: the frames, and whether it closed (false: 5 s passed) *)
let until_closed p =
  let rec go acc = match next p with Frame (i, k, f, b) -> go ((i, k, f, b) :: acc) | Eof -> List.rev acc, true | Timeout -> List.rev acc, false in
  go []

let reply (_, kind, flags, body) = try Some (Wire.get_reply kind flags (Codec.reader body 0 (Bytes.length body))) with _ -> None
let push (_, kind, flags, body) = if kind <> Wire.k_watch || flags land Wire.f_error <> 0 then None else try Some (Wire.get_push (Codec.reader body 0 (Bytes.length body))) with _ -> None
let is_internal ~id ((i, _, _, _) as f) = i = id && match reply f with Some (Wire.Err { code = "internal"; message }) -> message = internal_message | _ -> false
let next_frame p = match next p with Frame (i, k, f, b) -> Some (i, k, f, b) | Eof | Timeout -> None

(* what [f] writes on the standard error *)
let with_stderr dir f =
  let path = Filename.concat dir "stderr" in
  let fd = Unix.openfile path [ O_WRONLY; O_CREAT; O_TRUNC; O_CLOEXEC ] 0o600 in
  flush stderr;
  let saved = Unix.dup ~cloexec:true Unix.stderr in
  Unix.dup2 fd Unix.stderr;
  Unix.close fd;
  let r = Fun.protect ~finally:(fun () -> flush stderr; Unix.dup2 saved Unix.stderr; Unix.close saved) f in
  let s = In_channel.with_open_bin path In_channel.input_all in
  Sys.remove path;
  r, s

let rec remove_tree p =
  match (Unix.lstat p).st_kind with
  | Unix.S_DIR -> Array.iter (fun x -> remove_tree (Filename.concat p x)) (Sys.readdir p); Unix.rmdir p
  | _ -> Unix.unlink p
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let () =
  let dir = Sys.argv.(1) in
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  remove_tree dir;
  Unix.mkdir dir 0o700;
  let e = Result.get_ok (Engine.open_ Disk.real (Filename.concat dir "shop")) in
  let watch = Watch.create e in
  let live = Engine.start ~follow:{ Engine.before = (fun b -> Watch.before watch b); after = (fun () -> Watch.after watch) } e in
  let props = [ { Schema.name = "person/score"; typ = Value.Tint; many = false; unique = false } ] in
  let ids, ops = Result.get_ok (Resolve.declare (Atomic.get e.published) props) in
  ignore (Result.get_ok (Engine.write live ops 0 "declare"));
  let pscore = List.hd ids in
  (* the reads of a request raise what [boom] holds, once [skip] reads have passed *)
  let boom = Atomic.make None and skip = Atomic.make 0 in
  let view () = (match Atomic.get boom with Some x -> if Atomic.fetch_and_add skip (-1) <= 0 then raise x | None -> ()); Atomic.get e.published in
  let word = ref 0 in
  let follow = Follow.create e { Follow.get = (fun () -> !word); set = (fun v -> word := v) } in
  let core =
    { Core.name = "shop"; index = 0; dir = Filename.concat dir "shop"; view; sessions = Sessions.create (); more = (fun () -> []);
      hub = (fun () -> Watch.hub watch); files = Files.cell ~master:(fun () -> Ok (String.make 32 'k')) (Filename.concat dir "shop/vault") }
  in
  let page = Unix.openfile "/dev/null" [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  let dbs = [| { Net.core; live; follow; watch; page = Some page; checkpointed = 0; replica = ref false } |] in
  let tok = { Tokens.name = "w"; hash = Tokens.hash_of_text "cph_w"; databases = [ "shop", Tokens.Write ]; admin = false } in
  let srv =
    Core.create ~server_id:"s" ~cluster_id:"c" ~dbs:[| core |] ~tokens:(Tokens.with_tokens Tokens.empty [ tok ]) ~now:Disk.real.now
      ~new_session:(let n = ref 0 in fun () -> incr n; !n) ()
  in
  let socks = { Net.sm = Mutex.create (); open_ = Hashtbl.create 8 } in
  (* a connection's thread, as the server's I/O domain runs it; what escapes it is kept *)
  let escaped = Atomic.make [] in
  let serve fd =
    let ended = Atomic.make false in
    ignore
      (Thread.create
         (fun () ->
           (try Net.connection srv dbs socks ~idle:0 None fd with x -> Atomic.set escaped (Printexc.to_string x :: Atomic.get escaped));
           Atomic.set ended true)
         ());
    ended
  in
  let pair () =
    let a, b = Unix.socketpair ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    let ended = serve a in
    peer b, ended
  in
  let listener = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.bind listener (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen listener 8;
  let port = match Unix.getsockname listener with Unix.ADDR_INET (_, p) -> p | _ -> 0 in
  let tcp () =
    let c = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
    Unix.connect c (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
    let s, _ = Unix.accept ~cloexec:true listener in
    let ended = serve s in
    peer c, ended
  in
  let hello p = send p ~id:1 (Wire.Hello { version = Wire.version; token = "cph_w"; program = "t"; session = 0 }); next_frame p in
  let welcomed p = match hello p with Some f -> (match reply f with Some (Wire.Welcome _) -> true | _ -> false) | None -> false in
  let scores = { Query.vars = 2; where = [ { Query.e = Var 0; p = pscore; v = Var 1 } ]; ranges = [] } in
  let get = Wire.Get { db = 0; thing = Schema.first_thing } in
  let write v = Wire.Write { db = 0; serial = 0; floor = 0; by = 0; why = "guard"; ops = [ Resolve.Add (-1, pscore, Value.Int v) ] } in
  (* a connection served whole: Hello, Ping, Pong, closed by the client *)
  let served name =
    let p, ended = pair () in
    let ok = welcomed p && (send p ~id:2 (Wire.Ping "x"); match next_frame p with Some f -> reply f = Some (Wire.Pong "x") | None -> false) in
    Unix.close p.fd;
    C.check (ok && ends ended) "%s: a new connection is served, and ends when its client closes" name
  in
  (* the warm-up: a watch makes the hubs' domain and thread, which stay *)
  let p, ended = pair () in
  ignore (welcomed p);
  send p ~id:2 (Wire.Watch { db = 0; query = scores; select = Wire.Give [||]; from = 0; wextra = []; worder = Question.Top.none });
  ignore (next_frame p);
  Unix.close p.fd;
  ignore (ends ended);
  served "warm-up";
  Thread.delay 0.1;
  let fd0 = fds () and th0 = threads () in
  let clean name =
    let f = settles fds fd0 and t = settles threads th0 in
    let conns = Mutex.protect srv.cm (fun () -> Hashtbl.length srv.conns) and opened = Mutex.protect socks.sm (fun () -> Hashtbl.length socks.open_) in
    C.check (f = fd0 && t = th0 && conns = 0 && opened = 0 && Live.watches (Watch.hub watch) = 0 && Atomic.get escaped = [])
      "%s: nothing left: %d descriptors (%d before), %d threads (%d before), %d connections, %d sockets, %d watches, escaped [%s]" name f fd0
      t th0 conns opened (Live.watches (Watch.hub watch)) (String.concat "; " (Atomic.get escaped))
  in
  (* 1. a watch, a write answered, then a write in flight and a request that raises, sent together *)
  let p, ended = pair () in
  let w1 = welcomed p in
  send p ~id:2 (Wire.Watch { db = 0; query = scores; select = Wire.Give [||]; from = 0; wextra = []; worder = Question.Top.none });
  let answered = match next_frame p with Some f -> (match push f with Some (Wire.Answer _) -> true | _ -> false) | None -> false in
  send p ~id:3 (write 1);
  let receipt = ref false and change = ref false in
  for _ = 1 to 2 do
    match next_frame p with
    | Some ((3, _, _, _) as f) -> receipt := (match reply f with Some (Wire.Receipt _) -> true | _ -> false)
    | Some ((2, _, _, _) as f) -> change := (match push f with Some (Wire.Change _) -> true | _ -> false)
    | _ -> ()
  done;
  C.check (w1 && answered && !receipt && !change) "a connection with a watch (its answer, its change) and a write answered";
  let (frames, closed), log =
    with_stderr dir (fun () ->
        (* the write reads once (its published group): the Get's read raises *)
        Atomic.set skip 1;
        Atomic.set boom (Some (Invalid_argument "index out of bounds"));
        let b = Buffer.create 64 in
        let add ~id req = let x = Buffer.create 64 in Wire.put_request x req; Wire.add_frame b ~id ~kind:(Wire.request_kind req) ~flags:0 x in
        add ~id:4 (write 2);
        add ~id:5 get;
        let s = Buffer.to_bytes b in
        ignore (Unix.write p.fd s 0 (Bytes.length s));
        let r = until_closed p in
        Atomic.set boom None;
        r)
  in
  let on id = List.filter (fun (i, _, _, _) -> i = id) frames in
  C.check
    (* the write's change may reach the watch before the connection's end drops it *)
    (closed && List.length frames = 2 + List.length (on 2)
     && List.for_all (fun f -> match push f with Some (Wire.Change _) -> true | _ -> false) (on 2)
     && (match on 5 with [ f ] -> is_internal ~id:5 f | _ -> false)
     && match on 4 with [ f ] -> (match reply f with Some (Wire.Receipt _) -> true | _ -> false) | _ -> false)
    "a request that raised: its write in flight answered, itself answered internal, the connection closed (%d frames, closed %b)" (List.length frames) closed;
  C.check (ends ended) "a request that raised: the connection's thread ended";
  C.check (String.length log > 0 && not (String.contains (String.sub log 0 (String.length log - 1)) '\n')) "a request that raised: one line in the log (%S)" log;
  Unix.close p.fd;
  clean "a request that raised";
  served "after a request that raised";
  (* 2. connections that fail one after the other *)
  let crashes =
    [| Invalid_argument "index out of bounds"; Not_found; Division_by_zero; Out_of_memory; Stack_overflow; Failure "a bug"; Exit;
       Sys_error "/var/lib/cepheus: Permission denied"; Match_failure ("core.ml", 1, 2); Assert_failure ("core.ml", 3, 4) |]
  in
  let bad = ref 0 in
  let (), log =
    with_stderr dir (fun () ->
        for i = 0 to 199 do
          let p, _ = pair () in
          if not (welcomed p) then incr bad
          else begin
            Atomic.set boom (Some crashes.(i mod Array.length crashes));
            send p ~id:2 get;
            let frames, closed = until_closed p in
            Atomic.set boom None;
            match frames with [ f ] when closed && is_internal ~id:2 f -> () | _ -> incr bad
          end;
          Unix.close p.fd
        done)
  in
  let lines = List.length (List.filter (( <> ) "") (String.split_on_char '\n' log)) in
  C.check (!bad = 0) "200 connections that fail in a row: each answered internal and closed (%d not)" !bad;
  (* the line of the first failure above may still hold the second: 0 is right too *)
  C.check (lines <= 3) "200 failures in a row: at most a line a second in the log (%d lines)" lines;
  clean "200 connections that failed";
  served "after 200 connections that failed";
  (* 3. a failure in another thread of the connection, while its reading thread waits in a read *)
  let other name (p, ended) =
    let w = welcomed p in
    (* its pushes' thread made, as a push that fails would find it *)
    send p ~id:2 (Wire.Watch { db = 0; query = scores; select = Wire.Give [||]; from = 0; wextra = []; worder = Question.Top.none });
    ignore (next_frame p);
    let c = Mutex.protect srv.cm (fun () -> Hashtbl.fold (fun _ c _ -> Some c) srv.conns None) in
    let (), _ = with_stderr dir (fun () -> match c with Some c -> Core.broke c (Failure "a push that failed") | None -> ()) in
    send p ~id:3 (Wire.Ping "late");
    let frames, closed = until_closed p in
    C.check (w && closed && match frames with [ f ] -> is_internal ~id:0 f | _ -> false)
      "%s: a failure in another thread wakes the reading one: internal on id 0, nothing more (no Pong), closed (%d frames, closed %b)" name
      (List.length frames) closed;
    C.check (ends ended) "%s: the connection's thread ended" name;
    Unix.close p.fd;
    clean name;
    served ("after " ^ name)
  in
  other "over a Unix socket" (pair ());
  other "over TCP" (tcp ());
  (* 4. the reading buffers: before Hello, a frame longer than Core.max_hello is refused before its body is read; after
     it, long frames begun at once hold Net.max_reading more at most, and each is answered in turn *)
  let raw_frame ~id ~kind body =
    let f = Buffer.create (String.length body + Wire.header) in
    Wire.add_frame f ~id ~kind ~flags:0 (let b = Buffer.create (String.length body) in Buffer.add_string b body; b);
    Buffer.to_bytes f
  in
  let write_all fd b o n = let rec go o n = if n > 0 then (let k = Unix.write fd b o n in go (o + k) (n - k)) in try go o n with Unix.Unix_error _ -> () in
  let p, ended = pair () in
  let head = Bytes.sub (raw_frame ~id:1 ~kind:Wire.k_hello (String.make (16 lsl 20 - 16) 'h')) 0 65536 in
  write_all p.fd head 0 (Bytes.length head);
  let frames, closed = until_closed p in
  C.check (closed && Net.reading.held = 0 && match frames with [ f ] -> (match reply f with Some (Wire.Err { code = "too_large"; _ }) -> true | _ -> false) | _ -> false)
    "before Hello: a frame of 16 MiB is too_large and closes, its buffer never grown (%d frames, closed %b, %d bytes held)" (List.length frames) closed Net.reading.held;
  C.check (ends ended) "before Hello: the connection's thread ended";
  Unix.close p.fd;
  let saved = !Net.max_reading in
  Net.max_reading := 1 lsl 20;
  let big = String.make 700_000 'p' in
  let go = Atomic.make false and pongs = Atomic.make 0 in
  let conns = List.init 3 (fun i -> let p, e = pair () in ignore (welcomed p); p, e, i) in
  let senders =
    List.map
      (fun (p, _, i) ->
        Thread.create
          (fun () ->
            let f = raw_frame ~id:(10 + i) ~kind:Wire.k_ping big in
            let n = Bytes.length f in
            write_all p.fd f 0 (n - 100);
            while not (Atomic.get go) do Thread.delay 0.01 done;
            write_all p.fd f (n - 100) 100;
            match next_frame p with Some f when reply f = Some (Wire.Pong big) -> Atomic.incr pongs | _ -> ())
          ())
      conns
  in
  Thread.delay 0.5;
  let held = Net.reading.held in
  C.check (held > 0 && held <= !Net.max_reading) "after Hello: three frames of 700 KB begun at once hold %d bytes more (the bound %d)" held !Net.max_reading;
  Atomic.set go true;
  List.iter Thread.join senders;
  C.check (Atomic.get pongs = 3 && settles (fun () -> Net.reading.held) 0 = 0) "after Hello: each long frame answered in turn, the room given back (%d answered)" (Atomic.get pongs);
  List.iter (fun (p, e, _) -> Unix.close p.fd; ignore (ends e)) conns;
  Net.max_reading := saved;
  clean "the reading buffers";
  served "after the reading buffers";
  Unix.close listener;
  Unix.close page;
  Engine.stop live;
  remove_tree dir;
  C.finish "server guard"
