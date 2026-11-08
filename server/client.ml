(* A client of the protocol, in OCaml: for the tests, the benchmarks and the `cepheus` command (the Cesia client of
   step 4 speaks the same protocol). One connection; requests may be pipelined ([send] then [recv]); replies are
   matched by id. Writes are numbered in the connection's session: when the connection breaks, [write] connects
   again with the same session and sends the write again with the same serial, so it is applied once (G14). *)

open Cepheus

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
}

exception Broken of string

let address_of_string s =
  if String.length s > 0 && (s.[0] = '/' || s.[0] = '.') then Unix_socket s
  else
    let h, p = Config.host_port "address" s in
    Tcp (h, p)

let open_socket = function
  | Unix_socket p ->
    let fd = Unix.socket ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    (try Unix.connect fd (Unix.ADDR_UNIX p) with e -> Unix.close fd; raise e);
    fd
  | Tcp (h, p) ->
    let addr = Net.resolve h p in
    let fd = Unix.socket ~cloexec:true (Unix.domain_of_sockaddr addr) Unix.SOCK_STREAM 0 in
    (try Unix.setsockopt fd Unix.TCP_NODELAY true; Unix.connect fd addr with e -> Unix.close fd; raise e);
    fd

let rec write_all fd b o n =
  if n > 0 then
    let k = Unix.write fd b o n in
    write_all fd b (o + k) (n - k)

let fd c = match c.fd with Some fd -> fd | None -> raise (Broken "not connected")

(* the connection's bytes: TLS when it has it *)
let io_read c b o n = match c.tls with Some t -> Tls.read t b o n | None -> Unix.read (fd c) b o n
let io_write c b o n = match c.tls with Some t -> Tls.write t b o n | None -> write_all (fd c) b o n

(* queue a request: it leaves at the next [flush] *)
let send c req =
  let id = c.next_id in
  c.next_id <- (c.next_id + 1) land 0x7FFF_FFFF;
  Buffer.clear c.body;
  Wire.put_request c.body req;
  Wire.add_frame c.out ~id ~kind:(Wire.request_kind req) ~flags:0 c.body;
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
    let prev = Option.value (Hashtbl.find_opt c.early id') ~default:[] in
    Hashtbl.replace c.early id' ((kind, flags, body) :: prev);
    frames c id

(* the reply to [id]: the rows of every frame of a Find joined *)
let recv c id =
  match frames c id with
  | [ (kind, flags, body) ] -> decode kind flags body
  | fs -> (
    let parts = List.map (fun (k, f, b) -> decode k f b) fs in
    match List.find_opt (function Wire.Err _ -> true | _ -> false) parts with
    | Some e -> e
    | None ->
      let group = ref 0 and cols = ref 0 in
      let rows =
        List.concat_map (function Wire.Rows r -> group := r.group; cols := r.cols; r.rows | _ -> raise (Broken "a reply in parts that is not rows")) parts
      in
      Wire.Rows { group = !group; cols = !cols; rows })

let call c req =
  let id = send c req in
  flush c;
  recv c id

let hello c =
  match call c (Wire.Hello { version = Wire.version; token = c.token; program = c.program; session = c.session }) with
  | Wire.Welcome w when (match c.cluster with Some id -> id <> w.cluster | None -> false) ->
    Error (Printf.sprintf "the server belongs to cluster %s, not %s" w.cluster (Option.get c.cluster))
  | Wire.Welcome w as r -> c.session <- w.session; c.welcome <- Some r; Ok ()
  | Wire.Err e -> Error (e.code ^ ": " ^ e.message)
  | _ -> Error "an unexpected reply to Hello"

let reconnect c =
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
      | Tcp _, None -> Error "a TCP connection needs the cluster's CA (ca)"
      | Tcp (host, _), Some ca -> (
        match Tls.client_ctx ~ca () with
        | Error m -> Error m
        | Ok ctx -> ( match Tls.handshake ctx fd ~server:false ~host with Ok t -> c.tls <- Some t; Ok () | Error m -> Error m))
    in
    match secured with
    | Error m -> (try Unix.close fd with Unix.Unix_error _ -> ()); c.fd <- None; Error m
    | Ok () -> ( try hello c with Broken m -> Error m))
  | exception Unix.Unix_error (e, _, _) -> Error (Unix.error_message e)

let connect ?(program = "ocaml") ?(session = 0) ?ca ?cluster address token =
  let c =
    { address; token; program; fd = None; tls = None; ca; cluster; inb = Bytes.create 65536; have = 0; next_id = 1; out = Buffer.create 4096;
      body = Buffer.create 4096; session; serial = 0; waiting = Hashtbl.create 8; early = Hashtbl.create 8; welcome = None }
  in
  Result.map (fun () -> c) (reconnect c)

let close c =
  match c.fd with
  | Some fd -> c.fd <- None; (try Unix.close fd with Unix.Unix_error _ -> ())
  | None -> ()

type error = { code : string; message : string }

let result = function Wire.Err e -> Error { code = e.code; message = e.message } | r -> Ok r

type db = { handle : int; group : int; props : (int * Schema.prop) list }

let open_db c name =
  match call c (Wire.Open name) with
  | Wire.Opened o -> Ok { handle = o.db; group = o.group; props = o.props }
  | r -> Error (match result r with Error e -> e | Ok _ -> { code = "protocol"; message = "an unexpected reply to Open" })

let prop db name = List.find_map (fun (p, (d : Schema.prop)) -> if d.name = name then Some p else None) db.props

let get c db thing =
  match call c (Wire.Get { db = db.handle; thing }) with
  | Wire.Facts f -> Ok (f.group, f.facts)
  | r -> Error (match result r with Error e -> e | Ok _ -> { code = "protocol"; message = "an unexpected reply to Get" })

let find c db ?(select = Wire.Give [||]) query =
  match call c (Wire.Find { db = db.handle; query; select }) with
  | Wire.Rows r -> Ok (r.group, r.rows)
  | r -> Error (match result r with Error e -> e | Ok _ -> { code = "protocol"; message = "an unexpected reply to Find" })

(* how long [write] keeps trying to reach the server after the connection broke *)
let retry_budget = ref 30.0

let floor c = Hashtbl.fold (fun s () m -> min s m) c.waiting (c.serial + 1)

(* A write in the session: sent, and sent again with the same serial after a broken connection, until it is answered
   or the budget is spent: then Error unreachable, and the write was applied once or not at all. *)
let write c db ?(by = 0) ?(why = "") ops =
  c.serial <- c.serial + 1;
  let serial = c.serial in
  Hashtbl.replace c.waiting serial ();
  let deadline = Unix.gettimeofday () +. !retry_budget in
  let rec attempt pause =
    match
      let fl = floor c in
      call c (Wire.Write { db = db.handle; serial; floor = fl; by; why; ops })
    with
    | r ->
      Hashtbl.remove c.waiting serial;
      (match r with
       | Wire.Receipt rc -> Ok rc
       | r -> Error (match result r with Error e -> e | Ok _ -> { code = "protocol"; message = "an unexpected reply to Write" }))
    | exception Broken _ ->
      let rec again pause =
        if Unix.gettimeofday () > deadline then begin
          Hashtbl.remove c.waiting serial;
          Error { code = "unreachable"; message = "the server did not answer in time: the write was applied once or not at all" }
        end
        else
          match reconnect c with
          | Ok () -> attempt pause
          | Error _ -> Thread.delay pause; again (min 1.0 (pause *. 2.))
      in
      again pause
  in
  attempt 0.01

let ping c s = match call c (Wire.Ping s) with Wire.Pong p -> Ok p | r -> Error (match result r with Error e -> e | Ok _ -> { code = "protocol"; message = "Ping" })

let status c =
  match call c (Wire.Admin "status") with
  | Wire.Status l -> Ok l
  | r -> Error (match result r with Error e -> e | Ok _ -> { code = "protocol"; message = "an unexpected reply to Admin" })

(* the properties' ids for these names, declaring the missing ones in one write (as Cepheus.declare): the schema is
   read with Open again, and a declaration that lost a race for an id is made again *)
let rec declare c name (props : Schema.prop list) =
  match open_db c name with
  | Error e -> Error e
  | Ok db ->
    let used = List.map fst db.props in
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
        | Error { code = "conflict"; _ } -> declare c name props
        | Error e -> Error e)
