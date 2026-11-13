(* A client of the protocol, in OCaml: for the tests, the benchmarks and the `cepheus` command (the Cesia client of
   step 4 speaks the same protocol). One connection; requests may be pipelined ([send] then [recv]); replies are
   matched by id. Writes are numbered in the connection's session: when the connection breaks, [write] connects
   again with the same session and sends the write again with the same serial, so it is applied once (G14).

   Local reads: a database opened over the Unix socket (the server's machine) is followed in this process (a second
   connection, Follow, applied by a domain of its own: Follower), and [get] and [find] read it here, linearizably
   (Follow); over TCP, or when following fails, they ask the server. The program's code is the same. *)

open Cepheus
module Top = Question.Top

type address = Unix_socket of string | Tcp of string * int

type t = {
  address : address;
  token : string;
  program : string;
  mutable fd : Unix.file_descr option;
  mutable tls : Tls.t option;
  ca : string option;  (* the cluster's CA: TCP needs it *)
  cluster : string option;  (* the cluster id the server must have *)
  mutable inb : Bytes.t;
  mutable have : int;
  mutable next_id : int;
  out : Buffer.t;
  body : Buffer.t;
  mutable session : int;
  mutable serial : int;  (* the last serial given *)
  waiting : (int, unit) Hashtbl.t;  (* serials sent, not yet answered *)
  early : (int, (int * int * Bytes.t) list) Hashtbl.t;  (* replies that came before they were asked for *)
  mutable welcome : Wire.reply option;
  mutable follows : (Unix.file_descr * unit Domain.t) list;  (* the follow streams of its databases *)
  mutable spoken : int;  (* the protocol's version this connection speaks: 4, or less with a server that speaks no more *)
}

(* a question with Not, Or, In, Prefix, Sort, Limit or After, on a connection to a server of protocol 1 *)
let older = "this server speaks protocol 1: Not, Or, In, Prefix, Sort, Limit and After need a server of protocol 2"

(* a file, on a connection to a server of protocol 1 or 2 *)
let no_files = "this server speaks protocol 2 or older: files need a server of protocol 3"

(* an Incr, on a connection to a server of protocol 3 or older: refused here, never sent (such a server closes the
   connection on an operation it does not know) *)
let no_incr = "this server speaks protocol 3 or older: Incr needs a server of protocol 4"

let has_incr ops = List.exists (function Resolve.Incr _ -> true | _ -> false) ops

exception Broken of string

let address_of_string s =
  if String.length s > 0 && (s.[0] = '/' || s.[0] = '.') then Unix_socket s
  else
    let h, p = Config.host_port "address" s in
    Tcp (h, p)

(* How long a connection's handshake may take (connect, TLS, Hello; Follow and its Start for a follow stream) before it
   is given up as broken, and tried again within the retry budget: a peer that takes the connection and never answers
   (a hung server, another program on the port) never holds a client for ever. Past the handshake, reads and writes
   wait as long as they must (a write's fsync, a long Find, an idle connection). *)
let handshake_timeout = ref 5.0

(* the socket's reads and writes (and connect, on Linux) give up after [t] seconds; 0: never *)
let set_timeouts fd t = Unix.setsockopt_float fd Unix.SO_RCVTIMEO t; Unix.setsockopt_float fd Unix.SO_SNDTIMEO t

let open_socket address =
  let fd, addr =
    match address with
    | Unix_socket p -> Unix.socket ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0, Unix.ADDR_UNIX p
    | Tcp (h, p) ->
      let addr = Config.resolve h p in
      let fd = Unix.socket ~cloexec:true (Unix.domain_of_sockaddr addr) Unix.SOCK_STREAM 0 in
      (try Unix.setsockopt fd Unix.TCP_NODELAY true with e -> Unix.close fd; raise e);
      fd, addr
  in
  (try set_timeouts fd !handshake_timeout; Unix.connect fd addr with e -> Unix.close fd; raise e);
  fd

let write_all = Fdpass.write_all

let fd c = match c.fd with Some fd -> fd | None -> raise (Broken "not connected")

(* the connection's bytes: TLS when it has it *)
let io_read c b o n = match c.tls with Some t -> Tls.read t b o n | None -> Unix.read (fd c) b o n
let io_write c b o n = match c.tls with Some t -> Tls.write t b o n | None -> write_all (fd c) b o n

(* a Put's bytes go in frames of a MiB: the Put with the first, then Pieces *)
let piece = 1 lsl 20

(* queue a request: it leaves at the next [flush] *)
let send c req =
  let id = c.next_id in
  (* 1 to 2^31 - 1, then 1 again: 0 is the server's own id, for a frame that says why it closes the connection *)
  c.next_id <- (if c.next_id >= 0x7FFF_FFFF then 1 else c.next_id + 1);
  Buffer.clear c.body;
  (match req with
   | Wire.Put p when String.length p.data > piece ->
     let n = String.length p.data in
     Wire.put_request c.body (Wire.Put { p with data = String.sub p.data 0 piece });
     Wire.add_frame c.out ~id ~kind:Wire.k_put ~flags:Wire.f_more c.body;
     let o = ref piece in
     while !o < n do
       let k = min piece (n - !o) in
       Buffer.clear c.body;
       Buffer.add_substring c.body p.data !o k;
       o := !o + k;
       Wire.add_frame c.out ~id ~kind:Wire.k_piece ~flags:(if !o < n then Wire.f_more else 0) c.body
     done
   | _ ->
     Wire.put_request c.body req;
     Wire.add_frame c.out ~id ~kind:(Wire.request_kind req) ~flags:0 c.body);
  id

let flush c =
  let s = Buffer.to_bytes c.out in
  Buffer.clear c.out;
  try io_write c s 0 (Bytes.length s) with
  | Unix.Unix_error (e, _, _) -> raise (Broken (Unix.error_message e))
  | Failure m -> raise (Broken m)

(* the next frame: id, kind, flags, body *)
let next_frame c =
  let rec fill need =
    if c.have < need then begin
      if need > Bytes.length c.inb then begin
        let b = Bytes.create (max need (2 * Bytes.length c.inb)) in
        Bytes.blit c.inb 0 b 0 c.have;
        c.inb <- b
      end;
      let k =
        try io_read c c.inb c.have (Bytes.length c.inb - c.have) with
        | Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
          raise (Broken (Printf.sprintf "no answer within %g s" !handshake_timeout))
        | Unix.Unix_error (e, _, _) -> raise (Broken (Unix.error_message e))
        | Failure m -> raise (Broken m)
      in
      if k = 0 then raise (Broken "the server closed the connection");
      c.have <- c.have + k;
      fill need
    end
  in
  fill 4;
  let len = Wire.u32 c.inb 0 in
  if len < 6 || len > Wire.max_frame then raise (Broken "a malformed frame");
  fill (4 + len);
  let id = Wire.u32 c.inb 4 and kind = Bytes.get_uint8 c.inb 8 and flags = Bytes.get_uint8 c.inb 9 in
  let body = Bytes.sub c.inb Wire.header (len - 6) in
  Bytes.blit c.inb (4 + len) c.inb 0 (c.have - 4 - len);
  c.have <- c.have - 4 - len;
  id, kind, flags, body

let decode kind flags body =
  let r = Codec.reader body 0 (Bytes.length body) in
  try Wire.get_reply kind flags r with Codec.Short -> raise (Broken "a reply does not decode")

(* the frames of reply [id], in order (a Find in several frames ends with one without the flag more) *)
let rec frames c id =
  match Hashtbl.find_opt c.early id with
  | Some fs when List.exists (fun (_, f, _) -> f land Wire.f_more = 0) fs ->
    Hashtbl.remove c.early id;
    List.rev fs
  | _ ->
    let id', kind, flags, body = next_frame c in
    (* request id 0: the server says why it closes the connection (idle, too many connections) *)
    if id' = 0 && flags land Wire.f_error <> 0 then
      raise (Broken (match decode kind flags body with Wire.Err e -> e.code ^ ": " ^ e.message | _ -> "the server closed the connection"));
    let prev = Option.value (Hashtbl.find_opt c.early id') ~default:[] in
    Hashtbl.replace c.early id' ((kind, flags, body) :: prev);
    frames c id

(* a reply in several frames joined: the rows of a Find, the bytes of a Load *)
let join parts =
  match List.find_opt (function Wire.Err _ -> true | _ -> false) parts with
  | Some e -> e
  | None -> (
    match parts with
    | Wire.Data _ :: _ -> Wire.Data (String.concat "" (List.map (function Wire.Data s -> s | _ -> raise (Broken "a reply in parts of two kinds")) parts))
    | _ ->
      let group = ref 0 and cols = ref 0 in
      let rows =
        List.concat_map (function Wire.Rows r -> group := r.group; cols := r.cols; r.rows | _ -> raise (Broken "a reply in parts that is not rows")) parts
      in
      Wire.Rows { group = !group; cols = !cols; rows })

(* the reply to [id] *)
let recv c id =
  match frames c id with
  | [ (kind, flags, body) ] -> decode kind flags body
  | fs -> join (List.map (fun (k, f, b) -> decode k f b) fs)

let call c req =
  let id = send c req in
  flush c;
  recv c id

(* Error (permanent, why): a refusal that trying again will not change (the token, the version, another cluster) *)
let hello c =
  match call c (Wire.Hello { version = c.spoken; token = c.token; program = c.program; session = c.session }) with
  | Wire.Welcome w when (match c.cluster with Some id -> id <> w.cluster | None -> false) ->
    Error (true, Printf.sprintf "the server belongs to cluster %s, not %s" w.cluster (Option.get c.cluster))
  | Wire.Welcome w as r -> c.session <- w.session; c.welcome <- Some r; Ok ()
  | Wire.Err e when e.code = "version" && c.spoken > Wire.oldest ->
    (* an older server: the connection is made again in the version before (it closed this one) *)
    c.spoken <- c.spoken - 1;
    Error (false, "retry")
  | Wire.Err e -> Error (List.mem e.code [ "auth"; "version"; "denied" ], e.code ^ ": " ^ e.message)
  | _ -> Error (true, "an unexpected reply to Hello")

let rec reconnect c =
  (match c.fd with Some fd -> (try Unix.close fd with Unix.Unix_error _ -> ()) | None -> ());
  c.fd <- None;
  c.tls <- None;
  c.have <- 0;
  Hashtbl.reset c.early;
  match open_socket c.address with
  | fd -> (
    c.fd <- Some fd;
    let secured =
      match c.address, c.ca with
      | Unix_socket _, _ -> Ok ()
      | Tcp _, None -> Error (true, "a TCP connection needs the cluster's CA (ca)")
      | Tcp (host, _), Some ca -> (
        match Tls.client_ctx ~ca () with
        | Error m -> Error (true, m)
        | Ok ctx -> ( match Tls.handshake ctx fd ~server:false ~host with Ok t -> c.tls <- Some t; Ok () | Error m -> Error (false, m)))
    in
    let ready = match secured with Error e -> Error e | Ok () -> ( try hello c with Broken m -> Error (false, m)) in
    match ready with
    | Ok () -> set_timeouts fd 0.; Ok ()
    | Error (false, "retry") -> (try Unix.close fd with Unix.Unix_error _ -> ()); c.fd <- None; c.tls <- None; reconnect c
    | Error e -> (try Unix.close fd with Unix.Unix_error _ -> ()); c.fd <- None; c.tls <- None; Error e)
  | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINPROGRESS), _, _) ->
    Error (false, Printf.sprintf "no answer within %g s" !handshake_timeout)
  | exception Unix.Unix_error (e, _, _) -> Error (false, Unix.error_message e)

(* A write to a connection the server closed fails with EPIPE, never SIGPIPE: every write is a send with MSG_NOSIGNAL
   (Fdpass.write_all), so the library leaves the process's signals alone. *)
let connect ?(program = "ocaml") ?(session = 0) ?ca ?cluster address token =
  let c =
    { address; token; program; fd = None; tls = None; ca; cluster; inb = Bytes.create 65536; have = 0; next_id = 1; out = Buffer.create 4096;
      body = Buffer.create 4096; session; serial = 0; waiting = Hashtbl.create 8; early = Hashtbl.create 8; welcome = None;
      follows = []; spoken = Wire.version }
  in
  match reconnect c with Ok () -> Ok c | Error (_, m) -> Error m

let close c =
  (match c.fd with
   | Some fd -> c.fd <- None; (try Unix.close fd with Unix.Unix_error _ -> ())
   | None -> ());
  (* the follow streams end; their domains stop *)
  List.iter (fun (fd, _) -> try Unix.shutdown fd Unix.SHUTDOWN_ALL with Unix.Unix_error _ -> ()) c.follows;
  List.iter (fun (_, d) -> Domain.join d) c.follows;
  c.follows <- []

type error = { code : string; message : string }

let result = function Wire.Err e -> Error { code = e.code; message = e.message } | r -> Ok r

type db = {
  handle : int;
  group : int;
  props : (int * Schema.prop) list;
  mutable local : Follower.t option;  (* followed in this process *)
  mutable wants_local : bool;
  mutable retry_at : float;  (* a follower that stopped (the server restarted) is made again from this time on *)
}

(* ---- local reads: the follow stream ---- *)

(* the page cache of this process's local readers (Pages), set when the first database is followed *)
let local_cache = ref (256 lsl 20)
let cache_set = ref false

(* a follow connection's bytes and descriptors, read with recvmsg only: a plain read would drop the descriptors *)
type fconn = { ffd : Unix.file_descr; mutable fb : Bytes.t; mutable fhave : int; fds : Unix.file_descr Queue.t }

let ffill fc need =
  while fc.fhave < need do
    if need > Bytes.length fc.fb then begin
      let b = Bytes.create (max need (2 * Bytes.length fc.fb)) in
      Bytes.blit fc.fb 0 b 0 fc.fhave;
      fc.fb <- b
    end;
    let n, fds = Fdpass.recv fc.ffd fc.fb fc.fhave (Bytes.length fc.fb - fc.fhave) in
    List.iter (fun f -> Queue.push f fc.fds) fds;
    if n = 0 then raise (Broken "the follow stream ended");
    fc.fhave <- fc.fhave + n
  done

let fnext fc =
  ffill fc 4;
  let len = Wire.u32 fc.fb 0 in
  if len < 6 || len > Wire.max_frame then raise (Broken "a malformed frame on the follow stream");
  ffill fc (4 + len);
  let id = Wire.u32 fc.fb 4 and kind = Bytes.get_uint8 fc.fb 8 and flags = Bytes.get_uint8 fc.fb 9 in
  let body = Bytes.sub fc.fb Wire.header (len - 6) in
  Bytes.blit fc.fb (4 + len) fc.fb 0 (fc.fhave - 4 - len);
  fc.fhave <- fc.fhave - 4 - len;
  id, kind, flags, body

let take_fds fc k =
  if Queue.length fc.fds < k then raise (Broken "the follow stream's descriptors are missing");
  List.init k (fun _ -> Queue.pop fc.fds)

let fclose fc =
  (try Unix.close fc.ffd with Unix.Unix_error _ -> ());
  Queue.iter (fun f -> try Unix.close f with Unix.Unix_error _ -> ()) fc.fds;
  Queue.clear fc.fds

(* the stream, applied in order until it ends; then nothing more is served locally *)
let follow_loop fc fol () =
  (try
     while true do
       let _, kind, flags, body = fnext fc in
       if flags land Wire.f_error <> 0 then raise Exit;
       let r = Codec.reader body 0 (Bytes.length body) in
       if kind = Wire.k_frame then begin
         let vseq, first, count = Wire.get_frame_head r in
         let data =
           if flags land Wire.f_more = 0 then Bytes.sub body r.pos (r.stop - r.pos)
           else begin
             let b = Buffer.create (4 * Bytes.length body) in
             Buffer.add_subbytes b body r.pos (r.stop - r.pos);
             let rec more () =
               let _, k, fl, part = fnext fc in
               if k <> Wire.k_frame || fl land Wire.f_error <> 0 then raise Exit;
               Buffer.add_bytes b part;
               if fl land Wire.f_more <> 0 then more ()
             in
             more ();
             Buffer.to_bytes b
           end
         in
         Follower.frame fol ~vseq ~first ~count data
       end
       else if kind = Wire.k_durable then Follower.durable fol (Codec.get_varint r)
       else if kind = Wire.k_runs then begin
         let vseq, runs = Wire.get_runs_push r in
         let fds = take_fds fc (List.length runs) in
         Follower.runs fol ~vseq ~names:runs ~files:(List.map (fun f -> Follower.Fd f) fds)
       end
     done
   with
   | Exit | Broken _ | Unix.Unix_error _ -> ()
   | e -> prerr_endline ("cepheus client: local reads stopped: " ^ Printexc.to_string e));
  Follower.stop fol;
  fclose fc

(* the server refuses to follow for this token: one that may not read every kind *)
exception Not_followed

(* a second connection, Follow on it: the page and the runs passed, the follower made, the rest applied by a domain
   of its own; None over TCP, or when the server refuses (the reads then go to the server) *)
let follow c handle =
  match c.address with
  | Tcp _ -> None
  | Unix_socket _ -> (
    match open_socket c.address with
    | exception Unix.Unix_error _ -> None
    | fd -> (
      let fc = { ffd = fd; fb = Bytes.create 65536; fhave = 0; fds = Queue.create () } in
      let ask id req =
        let b = Buffer.create 64 and f = Buffer.create 80 in
        Wire.put_request b req;
        Wire.add_frame f ~id ~kind:(Wire.request_kind req) ~flags:0 b;
        let s = Buffer.to_bytes f in
        write_all fd s 0 (Bytes.length s);
        let _, kind, flags, body = fnext fc in
        Wire.get_reply kind flags (Codec.reader body 0 (Bytes.length body))
      in
      match
        match ask 1 (Wire.Hello { version = c.spoken; token = c.token; program = c.program ^ " (follow)"; session = 0 }) with
        | Wire.Welcome _ -> (
          match ask 2 (Wire.Follow handle) with
          | Wire.Err { code = "denied"; _ } -> raise Not_followed
          | Wire.Start st ->
            (* the handshake is over: the stream waits for the server's groups as long as there are none *)
            set_timeouts fd 0.;
            let fds = take_fds fc (1 + List.length st.runs) in
            let page = Fun.protect ~finally:(fun () -> Unix.close (List.hd fds)) (fun () -> Fdpass.map_page (List.hd fds)) in
            if not !cache_set then (cache_set := true; Pages.set_capacity !local_cache);
            Some
              (Follower.create ~id:st.id ~word:(fun () -> Fdpass.word page) ~names:st.runs
                 ~files:(List.map (fun f -> Follower.Fd f) (List.tl fds)))
          | _ -> None)
        | _ -> None
      with
      | Some fol ->
        let d = Domain.spawn (follow_loop fc fol) in
        c.follows <- (fd, d) :: c.follows;
        Some fol
      | None -> fclose fc; None
      | exception Not_followed -> fclose fc; raise Not_followed
      | exception (Broken _ | Follower.Stream _ | Codec.Short | Unix.Unix_error _ | Failure _ | Wire.Malformed _) -> fclose fc; None))

(* the state to read locally, if this database is followed: None when it is not, or no longer; a follower that
   stopped (its server restarted) is made again, at most every 100 ms while it fails *)
let local_view c db =
  match db.local with
  | Some f when not (Follower.dead f) -> Follower.view f
  | _ when db.wants_local && Unix.gettimeofday () >= db.retry_at -> (
    (* a token that may not read every kind is never followed: its reads stay at the server *)
    (db.local <- try follow c db.handle with Not_followed -> db.wants_local <- false; None);
    match db.local with
    | Some f -> Follower.view f
    | None -> db.retry_at <- Unix.gettimeofday () +. 0.1; None)
  | _ -> None

let facts_of (v : Store.view) thing =
  let l = ref [] in
  Store.iter_facts v thing (fun p w -> match Schema.find v.schema p with Some d -> l := (p, Store.value v d.typ w) :: !l | None -> ());
  List.rev !l

(* how long a request keeps trying to reach the server after the connection broke *)
let retry_budget = ref 30.0

(* [attempt ()] again on a new connection after a broken one (the server stopped, restarted, or closed an idle
   connection), until it returns or the budget is spent; then [gave_up ()] *)
let with_retry c attempt gave_up =
  let deadline = Unix.gettimeofday () +. !retry_budget in
  let rec go pause =
    match attempt () with
    | r -> r
    | exception Broken m ->
      let rec again pause =
        if Unix.gettimeofday () > deadline then gave_up m
        else
          match reconnect c with
          | Ok () -> go pause
          | Error (true, m) -> gave_up m
          | Error (false, _) -> Unix.sleepf pause; again (min 1.0 (pause *. 2.))
      in
      again pause
  in
  go 0.01

(* a read (it changes nothing): sent again as it is *)
let read_call c req = with_retry c (fun () -> call c req) (fun m -> raise (Broken m))

(* [local] false: the reads of this handle go to the server even over the Unix socket (declare's Opens, and the
   benchmarks of the socket's round trip) *)
let open_db ?(local = true) c name =
  match read_call c (Wire.Open name) with
  | Wire.Opened o ->
    let fol, wants = if local then (match follow c o.db with f -> f, true | exception Not_followed -> None, false) else None, false in
    Ok { handle = o.db; group = o.group; props = o.props; local = fol; wants_local = wants; retry_at = 0. }
  | r -> Error (match result r with Error e -> e | Ok _ -> { code = "protocol"; message = "an unexpected reply to Open" })

let prop db name = List.find_map (fun (p, (d : Schema.prop)) -> if d.name = name then Some p else None) db.props

let get c db thing =
  match local_view c db with
  | Some v -> ( match facts_of v thing with f -> Ok (v.group, f) | exception Pages.Unreadable m -> Error { code = "damaged"; message = m })
  | None -> (
    match read_call c (Wire.Get { db = db.handle; thing }) with
    | Wire.Facts f -> Ok (f.group, f.facts)
    | r -> Error (match result r with Error e -> e | Ok _ -> { code = "protocol"; message = "an unexpected reply to Get" }))

let find c db ?(select = Wire.Give [||]) ?(extra = []) ?(order = Top.none) query =
  match local_view c db with
  | Some v -> (
    match Answer.answer ~order ~extra v query select with
    | a ->
      let typs = Array.init a.cols a.typ in
      Ok (v.group, List.init a.n (fun i -> Array.init a.cols (fun j -> Store.value v typs.(j) (a.word i j))))
    | exception Query.Bad m -> Error { code = "invalid"; message = m }
    | exception Pages.Unreadable m -> Error { code = "damaged"; message = m })
  | None when (extra <> [] || order <> Top.none) && c.spoken < 2 -> Error { code = "invalid"; message = older }
  | None -> (
    match read_call c (Wire.Find { db = db.handle; query; select; extra; order }) with
    | Wire.Rows r -> Ok (r.group, r.rows)
    | r -> Error (match result r with Error e -> e | Ok _ -> { code = "protocol"; message = "an unexpected reply to Find" }))

let floor c = Hashtbl.fold (fun s () m -> min s m) c.waiting (c.serial + 1)

(* A write in the session: sent, and sent again with the same serial after a broken connection, until it is answered
   or the budget is spent: then Error unreachable, and the write was applied once or not at all. *)
let write c db ?(by = 0) ?(why = "") ops =
  (* before the first try only: once sent, the write may be applied, and only the server's answer or the budget
     tells (a connection made again to an older server, which closes it on the operation, ends as unreachable) *)
  if c.spoken < 4 && has_incr ops then Error { code = "invalid"; message = no_incr }
  else begin
    c.serial <- c.serial + 1;
    let serial = c.serial in
    Hashtbl.replace c.waiting serial ();
    with_retry c
      (fun () ->
        let r = call c (Wire.Write { db = db.handle; serial; floor = floor c; by; why; ops }) in
        Hashtbl.remove c.waiting serial;
        match r with
        | Wire.Receipt rc -> Ok rc
        | r -> Error (match result r with Error e -> e | Ok _ -> { code = "protocol"; message = "an unexpected reply to Write" }))
      (fun _ ->
        Hashtbl.remove c.waiting serial;
        Error { code = "unreachable"; message = "the server did not answer in time: the write was applied once or not at all" })
  end

(* A file: its bytes and its facts (kind/Name, Size, Type, Owner, Content), a Put of the session: sent again with the
   same serial after a broken connection (its bytes then found stored), applied once; its receipt's thing [-1] is
   the file. [owner]: the thing whose key seals the bytes (0: the database's own); [cold]: Zstandard, for files read
   seldom. *)
let put c db ~kind ~name ?(typ = "application/octet-stream") ?(owner = 0) ?(cold = false) ?(by = 0) ?(why = "") data =
  if c.spoken < 3 then Error { code = "invalid"; message = no_files }
  else begin
    c.serial <- c.serial + 1;
    let serial = c.serial in
    Hashtbl.replace c.waiting serial ();
    with_retry c
      (fun () ->
        let r = call c (Wire.Put { db = db.handle; serial; floor = floor c; by; why; kind; name; typ; owner; cold; data }) in
        Hashtbl.remove c.waiting serial;
        match r with
        | Wire.Receipt rc -> Ok rc
        | r -> Error (match result r with Error e -> e | Ok _ -> { code = "protocol"; message = "an unexpected reply to Put" }))
      (fun _ ->
        Hashtbl.remove c.waiting serial;
        Error { code = "unreachable"; message = "the server did not answer in time: the file was stored once or not at all" })
  end

(* the bytes [from, from + len) of a file (len -1: to its end), by its thing and its kind's Content property *)
let load c db ~thing ~prop ?(from = 0) ?(len = -1) () =
  if c.spoken < 3 then Error { code = "invalid"; message = no_files }
  else
    match read_call c (Wire.Load { db = db.handle; thing; prop; from; len }) with
    | Wire.Data s -> Ok s
    | r -> Error (match result r with Error e -> e | Ok _ -> { code = "protocol"; message = "an unexpected reply to Load" })

(* the key of an owner destroyed (a right to write the whole database): its files can no longer be read *)
let erase c db ~owner =
  if c.spoken < 3 then Error { code = "invalid"; message = no_files }
  else
    match read_call c (Wire.Erase { db = db.handle; owner }) with
    | Wire.Erased -> Ok ()
    | r -> Error (match result r with Error e -> e | Ok _ -> { code = "protocol"; message = "an unexpected reply to Erase" })

let ping c s = match read_call c (Wire.Ping s) with Wire.Pong p -> Ok p | r -> Error (match result r with Error e -> e | Ok _ -> { code = "protocol"; message = "Ping" })

let status c =
  match read_call c (Wire.Admin "status") with
  | Wire.Status l -> Ok l
  | r -> Error (match result r with Error e -> e | Ok _ -> { code = "protocol"; message = "an unexpected reply to Admin" })

(* the properties' ids for these names, declaring the missing ones in one write (as Cepheus.declare): the schema is
   read with Open again, and a declaration that lost a race for an id is made again without the ids it tried. Open
   lists the properties only: an id held by a rule (a schema thing too) is found by that conflict, and skipped. *)
let rec declare ?(avoid = []) c name (props : Schema.prop list) =
  match open_db ~local:false c name with
  | Error e -> Error e
  | Ok db ->
    let used = avoid @ List.map fst db.props in
    let next = ref Schema.first_prop and ops = ref [] and ids = ref [] and bad = ref None in
    let free () =
      while List.mem !next used do incr next done;
      let p = !next in
      incr next;
      p
    in
    List.iter
      (fun (d : Schema.prop) ->
        match prop db d.name with
        | Some p ->
          let cur = List.assoc p db.props in
          if cur.typ <> d.typ || cur.many <> d.many || cur.unique <> d.unique then
            bad := Some { code = "invalid"; message = d.name ^ " is declared already as another kind of property" };
          ids := p :: !ids
        | None ->
          let p = free () in
          ids := p :: !ids;
          ops := Resolve.Expect (p, Schema.p_name, None) :: !ops;
          List.iter (fun (e, q, x) -> ops := Resolve.Add (e, q, x) :: !ops) (Schema.facts p d))
      props;
    match !bad with
    | Some e -> Error e
    | None -> (
      if !ops = [] then Ok (db, List.rev !ids)
      else
        match write c db ~why:"cepheus: declare" (List.rev !ops) with
        | Ok _ -> ( match open_db c name with Ok db -> Ok (db, List.rev !ids) | Error e -> Error e)
        | Error { code = "conflict"; _ } ->
          let tried = List.filter_map (function Resolve.Expect (p, q, None) when q = Schema.p_name -> Some p | _ -> None) !ops in
          declare ~avoid:(tried @ avoid) c name props
        | Error e -> Error e)

(* ---- live questions ----
   A watch at the server: [watch] sends it, [next_push] gives its messages in order: the answer (or same), then the
   changes; [Ended] once the server ends it ("lagging": watch again from the group of the last message). On the
   server's machine a program watches its follower instead (Follower.hub, Live.subscribe): no network at all. *)

type pushed = Pushed of Wire.push | Ended of error

let watch c db ?(select = Wire.Give [||]) ?(from = 0) ?(extra = []) query =
  if extra <> [] && c.spoken < 2 then invalid_arg older;
  let id = send c (Wire.Watch { db = db.handle; query; select; from; wextra = extra }) in
  flush c;
  id

(* the next message of watch [id], its frames joined *)
let rec next_push c id =
  let fs = List.rev (Option.value (Hashtbl.find_opt c.early id) ~default:[]) in
  let rec split acc = function
    | ((_, f, _) as x) :: rest -> if f land Wire.f_more = 0 then Some (List.rev (x :: acc), rest) else split (x :: acc) rest
    | [] -> None
  in
  match split [] fs with
  | Some (mine, rest) -> (
    if rest = [] then Hashtbl.remove c.early id else Hashtbl.replace c.early id (List.rev rest);
    match mine with
    | [ (k, f, b) ] when f land Wire.f_error <> 0 -> (
      match decode k f b with Wire.Err e -> Ended { code = e.code; message = e.message } | _ -> Ended { code = "protocol"; message = "a watch's end" })
    | _ ->
      let parts =
        List.map (fun (_, _, b) -> try Wire.get_push (Codec.reader b 0 (Bytes.length b)) with Codec.Short -> raise (Broken "a push does not decode")) mine
      in
      Pushed (List.fold_left Wire.join_push (List.hd parts) (List.tl parts)))
  | None ->
    let id', kind, flags, body = next_frame c in
    if id' = 0 && flags land Wire.f_error <> 0 then
      raise (Broken (match decode kind flags body with Wire.Err e -> e.code ^ ": " ^ e.message | _ -> "the server closed the connection"));
    let prev = Option.value (Hashtbl.find_opt c.early id') ~default:[] in
    Hashtbl.replace c.early id' ((kind, flags, body) :: prev);
    next_push c id

let unwatch c id = match call c (Wire.Unwatch id) with Wire.Unwatched -> Ok () | r -> Error (match result r with Error e -> e | Ok _ -> { code = "protocol"; message = "Unwatch" })

(* the hub of this program's live questions on a database it follows here: None when it is read at the server *)
let local_hub c db = match local_view c db with Some _ -> Option.bind db.local Follower.hub | None -> None
