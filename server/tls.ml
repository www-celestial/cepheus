(* TLS 1.3 over a blocking socket, by OpenSSL (server/tls_stubs.c). OpenSSL works on memory buffers only: this side
   reads the socket and feeds it, and sends what it wrote; every call on one connection holds its lock [m], and every
   byte sent goes out under [wm] in the order OpenSSL wrote it. So a thread blocked reading the socket holds no lock,
   and the thread that sends a reply meanwhile never waits for it. The C side trusts the offsets and lengths it is
   given: they are checked here, and every string it reads must hold no NUL byte (C would stop there). *)

type ctx
type conn

external ctx_ : bool -> string -> string -> string -> bool -> ctx = "cepheus_tls_ctx"
external conn_ : ctx -> bool -> string -> conn = "cepheus_tls_conn"
external handshake_step : conn -> bool = "cepheus_tls_handshake"
external feed : conn -> bytes -> int -> int -> unit = "cepheus_tls_feed"
external take : conn -> bytes -> int -> int -> int = "cepheus_tls_take" [@@noalloc]
external pending : conn -> int = "cepheus_tls_pending" [@@noalloc]
external read_plain : conn -> bytes -> int -> int -> int = "cepheus_tls_read"
external write_plain : conn -> bytes -> int -> int -> unit = "cepheus_tls_write"
external peer_name_ : conn -> string = "cepheus_tls_peer_name"
external close_notify : conn -> unit = "cepheus_tls_close"

external make_cert_ : string -> string -> string -> string -> int -> string * string -> unit
  = "cepheus_tls_make_cert_bc" "cepheus_tls_make_cert"

let c_string what s = if String.contains s '\000' then failwith (what ^ " holds a NUL byte")

let range what b ofs len = if ofs < 0 || len < 0 || ofs > Bytes.length b - len then invalid_arg ("Tls." ^ what)

(* A server's context: its certificate and key; [verify_peer]: the other side must show a certificate of the CA. *)
let server_ctx ~ca ~cert ~key ~verify_peer =
  try List.iter (c_string "a path") [ ca; cert; key ]; Ok (ctx_ true ca cert key verify_peer) with Failure m -> Error m

(* A client's context: the CA it trusts; a certificate of its own for mutual TLS (between servers). *)
let client_ctx ?(cert = "") ?(key = "") ~ca () =
  try List.iter (c_string "a path") [ ca; cert; key ]; Ok (ctx_ false ca cert key true) with Failure m -> Error m

type t = { c : conn; fd : Unix.file_descr; m : Mutex.t; wm : Mutex.t; raw : Bytes.t; out : Bytes.t }

(* what OpenSSL wrote, sent in its order; the caller holds [wm] *)
let send_pending t =
  let rec go () =
    let n = Mutex.protect t.m (fun () -> take t.c t.out 0 (Bytes.length t.out)) in
    if n > 0 then (Fdpass.write_all t.fd t.out 0 n; go ())
  in
  go ()

(* The handshake, as the server ([host] "") or as a client that checks the server's name. [waiting ()] is called
   before each read after the first, when the bytes so far made no whole step: a peer that sends a byte at a time,
   each within the socket's timeout, is stopped there (Slowloris: R. Hansen, 2009), by its Failure. *)
let handshake ?(waiting = ignore) ctx fd ~server ~host =
  match c_string "the host" host; conn_ ctx server host with
  | exception Failure m -> Error m
  | c -> (
    let t = { c; fd; m = Mutex.create (); wm = Mutex.create (); raw = Bytes.create 65536; out = Bytes.create 65536 } in
    let rec go first =
      let fin = handshake_step c in
      send_pending t;
      if not fin then begin
        if not first then waiting ();
        let k = Unix.read fd t.raw 0 (Bytes.length t.raw) in
        if k = 0 then failwith "the TLS handshake: the peer closed the connection";
        feed c t.raw 0 k;
        go false
      end
    in
    match go true with
    | () -> Ok t
    | exception Failure m -> Error m
    | exception Unix.Unix_error (e, _, _) -> Error ("the TLS handshake: " ^ Unix.error_message e))

(* plain bytes, at most [len] (> 0); 0 at the end of the stream. [waiting ()] is called before each read of the
   socket once bytes came that made no whole record: what it raises ends the read (a record sent a byte at a time) *)
let read ?(waiting = ignore) t buf ofs len =
  range "read" buf ofs len;
  let rec go first =
    let n, out = Mutex.protect t.m (fun () -> let n = read_plain t.c buf ofs len in n, pending t.c) in
    if out > 0 then Mutex.protect t.wm (fun () -> send_pending t);
    if n > 0 then n
    else if n < 0 then 0
    else begin
      if not first then waiting ();
      let k = Unix.read t.fd t.raw 0 (Bytes.length t.raw) in
      if k = 0 then 0
      else begin
        Mutex.protect t.m (fun () -> feed t.c t.raw 0 k);
        go false
      end
    end
  in
  go true

let write t buf ofs len =
  range "write" buf ofs len;
  Mutex.protect t.wm (fun () ->
      Mutex.protect t.m (fun () -> write_plain t.c buf ofs len);
      send_pending t)

let peer_name t = Mutex.protect t.m (fun () -> peer_name_ t.c)

let close t =
  (try
     Mutex.protect t.wm (fun () ->
         Mutex.protect t.m (fun () -> close_notify t.c);
         send_pending t)
   with Unix.Unix_error _ | Failure _ -> ())

(* An ECDSA P-256 key and its certificate: a CA ([ca] None: self-signed), or one signed by the CA's certificate and
   key, named [cn], with [san] as subjectAltName ("DNS:srv1,IP:127.0.0.1"). The files must not exist; the key's is
   made readable by its owner only. *)
let make_cert ?ca ~cn ~san ~days ~key ~cert () =
  let ca_cert, ca_key = match ca with Some (c, k) -> c, k | None -> "", "" in
  try
    List.iter (c_string "a certificate's name or path") [ ca_cert; ca_key; cn; san; key; cert ];
    Ok (make_cert_ ca_cert ca_key cn san days (key, cert))
  with Failure m -> Error m
