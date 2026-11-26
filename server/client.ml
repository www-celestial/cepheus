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
  mutable address : address;  (* a Raft cluster's follower sends it to its leader (not_leader) *)
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
  mutable follows : (Unix.file_descr * (unit -> unit)) list;
      (* the follow streams of its databases, each a domain of its own, and its join *)
  mutable spoken : int;  (* the protocol's version this connection speaks: 6, or less with a server that speaks no more *)
  mutable members : address list;  (* a Raft cluster's servers, from Welcome: where to go when this one is gone *)
}

(* a question with Not, Or, In, Prefix, Sort, Limit or After, on a connection to a server of protocol 1 *)
let older = "this server speaks protocol 1: Not, Or, In, Prefix, Sort, Limit and After need a server of protocol 2"

(* a question the server refuses before it decodes it (Wire.max_patterns): refused here, before it is sent *)
let too_many_patterns (q : Query.t) =
  Printf.sprintf "a question has at most %d patterns, not %d: ask several, or name a part with a rule" Wire.max_patterns (List.length q.where)

(* a file, on a connection to a server of protocol 1 or 2 *)
let no_files = "this server speaks protocol 2 or older: files need a server of protocol 3"

(* an Incr, on a connection to a server of protocol 3 or older: refused here, never sent (such a server closes the
   connection on an operation it does not know) *)
let no_incr = "this server speaks protocol 3 or older: Incr needs a server of protocol 4"

(* Trunc, or an aggregate of a report (Avg, Count of a variable, Values, Quantile, Variance, Stddev), on a connection
   to a server of protocol 8 or older: refused here, never sent (such a server refuses the request whole) *)
let no_report spoken =
  Printf.sprintf "this server speaks protocol %d: Trunc, Avg, Count(x), Values, Quantile, Variance and Stddev need a server of protocol 9" spoken

(* windows (Running, Rank, Prev) and Each on a connection to a server of protocol 9 or older: refused here, never
   sent (such a server cannot read the select) *)
let no_window spoken = Printf.sprintf "this server speaks protocol %d: Running, Rank, Prev and Each need a server of protocol 10" spoken

let has_incr ops = List.exists (function Resolve.Incr _ -> true | _ -> false) ops

(* a Delete, or a link that names a kind (the facts of cepheus/to and cepheus/delete), on a connection to a server of
   protocol 7 or older: refused here, never sent (such a server closes the connection on the operation, and knows no
   property 7 or 8) *)
let no_delete spoken = Printf.sprintf "this server speaks protocol %d: Delete and links that name a kind need a server of protocol 8" spoken

let needs_8 ops =
  List.exists
    (function
      | Resolve.Delete _ -> true
      | Resolve.Add (_, p, _) | Resolve.Retract (_, p, _) | Resolve.Expect (_, p, _) -> p = Schema.p_to || p = Schema.p_delete
      | Resolve.Incr _ -> false)
    ops

(* a watch with Sort and Limit, on a connection to a server of protocol 4 or older: refused here, never sent (such a
   server refuses the watch's order) *)
let no_sorted_watch spoken = Printf.sprintf "this server speaks protocol %d: a watch with Sort and Limit needs a server of protocol 5" spoken

(* a question's time, on a connection to a server of protocol 5 or older: refused here, never sent (such a server
   closes the connection on the bytes after the question) *)
let no_timeout spoken = Printf.sprintf "this server speaks protocol %d: a question's timeout needs a server of protocol 6" spoken

(* Less and Optional, on a connection to a server of protocol 6 or older: refused here, never sent (such a server
   refuses an operator it does not know) *)
let no_less spoken = Printf.sprintf "this server speaks protocol %d: Less, LessOrEqual and Optional need a server of protocol 7" spoken

(* a question's time in seconds as the wire's milliseconds (0: none given), 1 ms to a week; an infinite, NaN or
   negative time is the program's mistake *)
let timeout_ms = function
  | None -> 0
  | Some t ->
    if Float.is_nan t || t <= 0. then invalid_arg (Printf.sprintf "a question's timeout is a number of seconds above 0, not %g" t);
    int_of_float (Float.ceil (Float.min (t *. 1000.) (float_of_int Wire.max_timeout)))

(* the stop of a question read in the program's own memory: its time, if it has one *)
let local_stop = function None -> None | Some t -> ignore (timeout_ms (Some t)); Some (Query.stop t)

exception Broken of string

(* a Raft cluster's refusal: Some address, the leader's, to ask instead (not_leader); None, no leader now
   (no_leader): asked again after a pause. [with_retry] follows both, within the retry budget *)
exception Moved of string option

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
  match address with
  | Unix_socket p ->
    Option.iter failwith (Config.long_socket p);
    let fd = Unix.socket ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    (try set_timeouts fd !handshake_timeout; Unix.connect fd (Unix.ADDR_UNIX p) with e -> Unix.close fd; raise e);
    fd
  | Tcp (h, p) -> Config.connect h p (fun fd -> Unix.setsockopt fd Unix.TCP_NODELAY true; set_timeouts fd !handshake_timeout)

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

(* a reply in several frames joined: the rows of a Find, the bytes of a Load, the facts of a Get and the properties of
   an Open too long for one frame (a server of an earlier version sends those in one) *)
let join parts =
  let two () = raise (Broken "a reply in parts of two kinds") in
  match List.find_opt (function Wire.Err _ -> true | _ -> false) parts with
  | Some e -> e
  | None -> (
    match parts with
    | Wire.Data _ :: _ -> Wire.Data (String.concat "" (List.map (function Wire.Data s -> s | _ -> two ()) parts))
    | Wire.Facts f :: _ -> Wire.Facts { f with facts = List.concat_map (function Wire.Facts x -> x.facts | _ -> two ()) parts }
    | Wire.Opened o :: _ -> Wire.Opened { o with props = List.concat_map (function Wire.Opened x -> x.props | _ -> two ()) parts }
    | _ ->
      let group = ref 0 and cols = ref 0 in
      let rows =
        List.concat_map (function Wire.Rows r -> group := r.group; cols := r.cols; r.rows | _ -> raise (Broken "a reply in parts that is not rows")) parts
      in
      Wire.Rows { group = !group; cols = !cols; rows })

(* the reply to [id]; a Raft cluster's not_leader and no_leader raise Moved *)
let recv c id =
  match frames c id with
  | [ (kind, flags, body) ] -> (
    match decode kind flags body with
    | Wire.Err { code = "not_leader"; _ } -> raise (Moved (Wire.moved flags (Codec.reader body 0 (Bytes.length body))))
    | Wire.Err { code = "no_leader"; _ } -> raise (Moved None)
    | r -> r)
  | fs -> join (List.map (fun (k, f, b) -> decode k f b) fs)

let call c req =
  let id = send c req in
  flush c;
  recv c id

(* Error (permanent, why): a refusal that trying again will not change (the token, the version, another cluster) *)
let hello c =
  let id = send c (Wire.Hello { version = c.spoken; token = c.token; program = c.program; session = c.session }) in
  flush c;
  let reply =
    match frames c id with
    | [ (kind, flags, body) ] ->
      let r = decode kind flags body in
      (match r with
       | Wire.Welcome _ ->
         let l = Wire.members (Codec.reader body 0 (Bytes.length body)) in
         if l <> [] then c.members <- List.filter_map (fun a -> try Some (address_of_string a) with Config.Bad _ -> None) l
       | _ -> ());
      r
    | fs -> join (List.map (fun (k, f, b) -> decode k f b) fs)
  in
  match reply with
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
  | exception Failure m -> Error (true, m)

(* A write to a connection the server closed fails with EPIPE, never SIGPIPE: every write is a send with MSG_NOSIGNAL
   (Fdpass.write_all), so the library leaves the process's signals alone. *)
let connect ?(program = "ocaml") ?(session = 0) ?ca ?cluster address token =
  let c =
    { address; token; program; fd = None; tls = None; ca; cluster; inb = Bytes.create 65536; have = 0; next_id = 1; out = Buffer.create 4096;
      body = Buffer.create 4096; session; serial = 0; waiting = Hashtbl.create 8; early = Hashtbl.create 8; welcome = None;
      follows = []; spoken = Wire.version; members = [] }
  in
  match reconnect c with Ok () -> Ok c | Error (_, m) -> Error m

let close c =
  (match c.fd with
   | Some fd -> c.fd <- None; (try Unix.close fd with Unix.Unix_error _ -> ())
   | None -> ());
  (* the follow streams end; their domains stop *)
  List.iter (fun (fd, _) -> try Unix.shutdown fd Unix.SHUTDOWN_ALL with Unix.Unix_error _ -> ()) c.follows;
  List.iter (fun (_, join) -> join ()) c.follows;
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
      | Some fol -> (
        (* a domain of its own, counted (Pool), so that its frames never wait for the program's computation; the
           Cesia client's engine has no systhreads to share one *)
        match Pool.spawn (follow_loop fc fol) with
        | d -> c.follows <- (fd, fun () -> Domain.join d) :: c.follows; Some fol
        | exception _ -> fclose fc; None)
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
  (* the pause between two tries doubles up to 1 s; in a Raft cluster (its members known) up to 50 ms: another member
     answers at once, and an election lasts about a second *)
  let cap = if c.members <> [] then 0.05 else 1.0 in
  let rec go pause =
    match attempt () with
    | r -> r
    | exception Moved where ->
      (* a Raft cluster: to its leader (at once the first time, then after a pause: an address that sends back),
         or again here after a pause while an election runs *)
      if Unix.gettimeofday () > deadline then gave_up "no leader answered within the retry budget"
      else begin
        let moved = match where with Some a -> (try let a' = address_of_string a in let m = a' <> c.address in c.address <- a'; m with Config.Bad _ -> false) | None -> false in
        if not moved then Unix.sleepf pause;
        match if moved then reconnect c else Ok () with
        | Ok () -> go (if moved then pause else min cap (pause *. 2.))
        | Error (true, m) ->
          gave_up (match where with Some a -> Printf.sprintf "not_leader: the leader is at %s, which this connection cannot reach (%s)" a m | None -> m)
        | Error (false, _) -> Unix.sleepf pause; go (min cap (pause *. 2.))
      end
    | exception Broken m ->
      let rec again pause =
        if Unix.gettimeofday () > deadline then gave_up m
        else
          match reconnect c with
          | Ok () -> go pause
          | Error (true, m) -> gave_up m
          | Error (false, _) ->
            (* a Raft cluster's server gone: the next member (it sends the program on to the leader); over TCP only,
               the members' addresses being TCP's *)
            (match c.members, c.ca with
             | (_ :: _ as l), Some _ ->
               let rec after = function x :: (y :: _ as rest) -> if x = c.address then y else after rest | _ -> List.hd l in
               c.address <- after l
             | _ -> ());
            Unix.sleepf pause;
            again (min cap (pause *. 2.))
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

let find c db ?(select = Wire.Give [||]) ?(extra = []) ?(order = Top.none) ?timeout query =
  let ms = timeout_ms timeout in
  match local_view c db with
  | Some v -> (
    match Answer.answer ~order ~extra ?stop:(local_stop timeout) v query select with
    | a ->
      let typs = Array.init a.cols a.typ in
      ignore typs;
      Ok (v.group, List.init a.n (fun i -> Array.init a.cols (fun j -> Answer.value v a i j)))
    | exception Query.Bad m -> Error { code = "invalid"; message = m }
    | exception Query.Timeout t -> Error { code = "timeout"; message = Query.timeout_message t }
    | exception Pages.Unreadable m -> Error { code = "damaged"; message = m })
  | None when (extra <> [] || order <> Top.none) && c.spoken < 2 -> Error { code = "invalid"; message = older }
  | None when ms > 0 && c.spoken < 6 -> Error { code = "invalid"; message = no_timeout c.spoken }
  | None when c.spoken < 7 && Wire.needs_7 extra -> Error { code = "invalid"; message = no_less c.spoken }
  | None when c.spoken < 9 && Wire.needs_9 extra select -> Error { code = "invalid"; message = no_report c.spoken }
  | None when c.spoken < 10 && Wire.needs_10 select -> Error { code = "invalid"; message = no_window c.spoken }
  | None when List.length query.where > Wire.max_patterns -> Error { code = "invalid"; message = too_many_patterns query }
  | None -> (
    match read_call c (Wire.Find { db = db.handle; query; select; extra; order; timeout = ms }) with
    | Wire.Rows r -> Ok (r.group, r.rows)
    | r -> Error (match result r with Error e -> e | Ok _ -> { code = "protocol"; message = "an unexpected reply to Find" }))

let floor c = Hashtbl.fold (fun s () m -> min s m) c.waiting (c.serial + 1)

(* A write in the session: sent, and sent again with the same serial after a broken connection, until it is answered
   or the budget is spent: then Error unreachable, and the write was applied once or not at all. *)
let write c db ?(by = 0) ?(why = "") ops =
  (* before the first try only: once sent, the write may be applied, and only the server's answer or the budget
     tells (a connection made again to an older server, which closes it on the operation, ends as unreachable) *)
  if c.spoken < 4 && has_incr ops then Error { code = "invalid"; message = no_incr }
  else if c.spoken < 8 && needs_8 ops then Error { code = "invalid"; message = no_delete c.spoken }
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

(* an admin operation (promote): sent once, never again on a new connection (its effect may be done) *)
let admin c what =
  match call c (Wire.Admin what) with
  | Wire.Status l -> Ok l
  | r -> Error (match result r with Error e -> e | Ok _ -> { code = "protocol"; message = "an unexpected reply to Admin" })
  | exception Broken m -> Error { code = "unreachable"; message = m ^ ": the operation was done once or not at all (see cepheus status)" }

(* the kind a property of the database links to, from the facts of the property thing (a Get) *)
let link_of c db p =
  match read_call c (Wire.Get { db = db.handle; thing = p }) with
  | Wire.Facts f ->
    let one q = List.find_map (fun (q', (x : Value.t)) -> match x with Text s when q' = q -> Some s | _ -> None) f.facts in
    Ok
      (match one Schema.p_to with
       | None -> None
       | Some kind -> Some { Schema.kind; on_delete = Option.value ~default:Schema.Refuse (Option.bind (one Schema.p_delete) Schema.on_delete_of) })
  | r -> Error (match result r with Error e -> e | Ok _ -> { code = "protocol"; message = "an unexpected reply to Get" })

(* the property a property of the database is ordered within, from the facts of the property thing (a Get) *)
let within_of c db p =
  match read_call c (Wire.Get { db = db.handle; thing = p }) with
  | Wire.Facts f -> Ok (List.find_map (fun (q, (x : Value.t)) -> match x with Link p1 when q = Schema.p_within -> Some p1 | _ -> None) f.facts)
  | r -> Error (match result r with Error e -> e | Ok _ -> { code = "protocol"; message = "an unexpected reply to Get" })

(* the properties' ids for these names, declaring the missing ones in one write (as Cepheus.declare): the schema is
   read with Open again, and a declaration that lost a race for an id is made again without the ids it tried. Open
   lists the properties only: an id held by a rule (a schema thing too) is found by that conflict, and skipped.
   [links]: (name, link) of link properties that name a kind, declared in the same write (Resolve.link_ops); the kind
   an existing one names is read from its facts. *)
let rec declare ?(avoid = []) ?(links = []) ?(withins = []) c name (props : Schema.prop list) =
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
    (* the links: by the id each name has now (in the database, or in this write) *)
    let id_of n = List.assoc n (List.combine (List.map (fun (d : Schema.prop) -> d.name) props) (List.rev !ids)) in
    let fresh p = List.exists (function Resolve.Expect (q, r, None) -> q = p && r = Schema.p_name | _ -> false) !ops in
    let named = List.map (fun (n, l) -> id_of n, n, l) links in
    let current = Hashtbl.create 4 in
    let read_links =
      List.fold_left
        (fun acc (p, _, _) ->
          match acc with
          | Error _ -> acc
          | Ok () when fresh p -> Hashtbl.replace current p None; acc
          | Ok () -> (match link_of c db p with Ok l -> Hashtbl.replace current p l; Ok () | Error e -> Error e))
        (Ok ()) named
    in
    let lops =
      match !bad, read_links with
      | Some e, _ | None, Error e -> Error e
      | None, Ok () -> (
        match Resolve.link_ops (fun p -> Option.join (Hashtbl.find_opt current p)) named with
        | Ok l -> Ok l
        | Error m -> Error { code = "invalid"; message = m })
    in
    (* the pairs (p2 within p1, by name), likewise: the p1 an existing p2 is within read from its facts *)
    let wops =
      match lops with
      | Error e -> Error e
      | Ok _ -> (
        let named = List.map (fun (n2, n1) -> id_of n2, n2, id_of n1, n1) withins in
        let current = Hashtbl.create 4 in
        let read =
          List.fold_left
            (fun acc (p2, _, _, _) ->
              match acc with
              | Error _ -> acc
              | Ok () when fresh p2 -> Hashtbl.replace current p2 None; acc
              | Ok () -> (match within_of c db p2 with Ok w -> Hashtbl.replace current p2 w; Ok () | Error e -> Error e))
            (Ok ()) named
        in
        let name_of p = match List.find_opt (fun (q, _) -> q = p) db.props with Some (_, d) -> d.Schema.name | None -> string_of_int p in
        match read with
        | Error e -> Error e
        | Ok () -> (
          match Resolve.within_ops (fun p -> Option.map (fun p1 -> p1, name_of p1) (Option.join (Hashtbl.find_opt current p))) named with
          | Ok l -> Ok l
          | Error m -> Error { code = "invalid"; message = m }))
    in
    let lops = match lops, wops with Ok l, Ok w -> Ok (l @ w) | (Error e, _) | (_, Error e) -> Error e in
    match lops with
    | Error e -> Error e
    | Ok lops -> (
      let all = List.rev_append !ops lops in
      if all = [] then Ok (db, List.rev !ids)
      else
        match write c db ~why:"cepheus: declare" all with
        | Ok _ -> ( match open_db c name with Ok db -> Ok (db, List.rev !ids) | Error e -> Error e)
        | Error { code = "conflict"; _ } ->
          let tried = List.filter_map (function Resolve.Expect (p, q, None) when q = Schema.p_name -> Some p | _ -> None) !ops in
          declare ~avoid:(tried @ avoid) ~links ~withins c name props
        | Error e -> Error e)

(* ---- live questions ----
   A watch at the server: [watch] sends it, [next_push] gives its messages in order: the answer (or same), then the
   changes; [Ended] once the server ends it ("lagging": watch again from the group of the last message). On the
   server's machine a program watches its follower instead (Follower.hub, Live.subscribe): no network at all. *)

type pushed = Pushed of Wire.push | Ended of error

let watch c db ?(select = Wire.Give [||]) ?(from = 0) ?(extra = []) ?(order = Top.none) ?timeout query =
  let ms = timeout_ms timeout in
  if extra <> [] && c.spoken < 2 then invalid_arg older;
  if order <> Top.none && c.spoken < 5 then invalid_arg (no_sorted_watch c.spoken);
  if ms > 0 && c.spoken < 6 then invalid_arg (no_timeout c.spoken);
  if c.spoken < 7 && Wire.needs_7 extra then invalid_arg (no_less c.spoken);
  if c.spoken < 9 && Wire.needs_9 extra select then invalid_arg (no_report c.spoken);
  if c.spoken < 10 && Wire.needs_10 select then invalid_arg (no_window c.spoken);
  if List.length query.where > Wire.max_patterns then invalid_arg (too_many_patterns query);
  let id = send c (Wire.Watch { db = db.handle; query; select; from; wextra = extra; worder = order; wtimeout = ms }) in
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
