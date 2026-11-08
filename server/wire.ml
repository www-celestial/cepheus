(* The wire protocol, version 1. A connection carries frames both ways:

     frame  = length u32 LE (the bytes after this field, at most 16 MiB) | id u32 LE | kind u8 | flags u8 | body
     flags  = bit 0: more (a reply in several frames: the rows of a Find), bit 1: error (the body is an error)

   A reply carries its request's id and kind; replies may come out of order (choice 7), matched by id. Values are coded
   as in the journal (Value.encode: a tag byte, then varints and strings): one coding of values everywhere. *)

open Cepheus

let version = 1
let header = 10
let max_frame = 16 lsl 20

(* request kinds; a reply has its request's kind *)
let k_hello = 1
let k_open = 2
let k_get = 3
let k_find = 4
let k_write = 5
let k_ping = 6
let k_admin = 7

(* the follow stream (local readers, over the Unix socket only): Follow's reply carries the visibility page's and the
   runs' descriptors (SCM_RIGHTS), then the server pushes (request id 0) frames and runs *)
let k_follow = 8
let k_frame = 9
let k_runs = 10

let f_more = 1
let f_error = 2

type agg = Count | Sum of int | Min of int | Max of int

type select =
  | Give of int array  (** the variables to give, in this order; empty: all of them *)
  | Group of int array * agg array  (** one row a distinct key: the key's variables, then the aggregates *)

type request =
  | Hello of { version : int; token : string; program : string; session : int }
  | Open of string
  | Get of { db : int; thing : int }
  | Find of { db : int; query : Query.t; select : select }
  | Write of { db : int; serial : int; floor : int; by : int; why : string; ops : Resolve.op list }
  | Ping of string
  | Admin of string
  | Follow of int  (** a database: this connection becomes its follow stream *)

type reply =
  | Welcome of { server : string; cluster : string; session : int; frame : int; inflight : int }
  | Opened of { db : int; group : int; props : (int * Schema.prop) list }
  | Facts of { group : int; facts : (int * Value.t) list }
  | Rows of { group : int; cols : int; rows : Value.t array list }
  | Receipt of Engine.receipt
  | Pong of string
  | Status of (string * string) list
  | Start of { id : string; vseq : int; runs : (int * int) list }
      (** Follow's reply: the database's id, the visibility number and the runs (lo, hi) of the state visible under
          it, newest first; the descriptors of the page and of the runs, in that order, ride on its first byte *)
  | Err of { code : string; message : string }

exception Malformed of string

(* ---- frames ---- *)

let u32 b o = Int32.to_int (Bytes.get_int32_le b o) land 0xFFFF_FFFF

(* the frame header and an already coded body *)
let add_frame out ~id ~kind ~flags body =
  Buffer.add_int32_le out (Int32.of_int (6 + Buffer.length body));
  Buffer.add_int32_le out (Int32.of_int id);
  Buffer.add_uint8 out kind;
  Buffer.add_uint8 out flags;
  Buffer.add_buffer out body

(* ---- codings ---- *)

let put_term b = function
  | Query.Var i -> Buffer.add_char b '\000'; Codec.put_varint b i
  | Query.Thing e -> Buffer.add_char b '\001'; Codec.put_varint b e
  | Query.Val v -> Buffer.add_char b '\002'; Value.encode b v

let get_term r =
  match Codec.get_byte r with
  | 0 -> Query.Var (Codec.get_varint r)
  | 1 -> Query.Thing (Codec.get_varint r)
  | 2 -> Query.Val (Value.decode r)
  | _ -> raise Codec.Short

let put_query b (q : Query.t) =
  Codec.put_varint b q.vars;
  Codec.put_varint b (List.length q.where);
  List.iter (fun (p : Query.pattern) -> put_term b p.e; Codec.put_varint b p.p; put_term b p.v) q.where;
  Codec.put_varint b (List.length q.ranges);
  List.iter (fun (x, lo, hi) -> Codec.put_varint b x; Value.encode b lo; Value.encode b hi) q.ranges

(* a count read from the wire, bounded by the bytes left (each item takes one byte at least): a frame cannot make the
   reader allocate more than it holds *)
let count r =
  let n = Codec.get_varint r in
  if n > r.Codec.stop - r.Codec.pos then raise Codec.Short;
  n

let get_query r : Query.t =
  let vars = Codec.get_varint r in
  if vars > 64 then raise (Malformed "a question has at most 64 variables");
  let where = List.init (count r) (fun _ -> let e = get_term r in let p = Codec.get_varint r in let v = get_term r in { Query.e; p; v }) in
  let ranges = List.init (count r) (fun _ -> let x = Codec.get_varint r in let lo = Value.decode r in let hi = Value.decode r in x, lo, hi) in
  { vars; where; ranges }

let put_select b : select -> unit = function
  | Give give -> Buffer.add_char b '\000'; Codec.put_varint b (Array.length give); Array.iter (Codec.put_varint b) give
  | Group (keys, aggs) ->
    Buffer.add_char b '\001';
    Codec.put_varint b (Array.length keys);
    Array.iter (Codec.put_varint b) keys;
    Codec.put_varint b (Array.length aggs);
    Array.iter
      (function
        | Count -> Buffer.add_char b '\000'
        | Sum x -> Buffer.add_char b '\001'; Codec.put_varint b x
        | Min x -> Buffer.add_char b '\002'; Codec.put_varint b x
        | Max x -> Buffer.add_char b '\003'; Codec.put_varint b x)
      aggs

let get_vars r = Array.init (count r) (fun _ -> Codec.get_varint r)

let get_select r : select =
  match Codec.get_byte r with
  | 0 -> Give (get_vars r)
  | 1 ->
    let keys = get_vars r in
    let aggs =
      Array.init (count r) (fun _ ->
          match Codec.get_byte r with
          | 0 -> Count
          | 1 -> Sum (Codec.get_varint r)
          | 2 -> Min (Codec.get_varint r)
          | 3 -> Max (Codec.get_varint r)
          | _ -> raise Codec.Short)
    in
    Group (keys, aggs)
  | _ -> raise Codec.Short

let put_op b = function
  | Resolve.Add (e, p, v) -> Buffer.add_char b '\000'; Codec.put_int b e; Codec.put_varint b p; Value.encode b v
  | Resolve.Retract (e, p, v) -> Buffer.add_char b '\001'; Codec.put_int b e; Codec.put_varint b p; Value.encode b v
  | Resolve.Expect (e, p, Some v) -> Buffer.add_char b '\002'; Codec.put_int b e; Codec.put_varint b p; Value.encode b v
  | Resolve.Expect (e, p, None) -> Buffer.add_char b '\003'; Codec.put_int b e; Codec.put_varint b p

let get_op r =
  let tag = Codec.get_byte r in
  let e = Codec.get_int r in
  let p = Codec.get_varint r in
  match tag with
  | 0 -> Resolve.Add (e, p, Value.decode r)
  | 1 -> Resolve.Retract (e, p, Value.decode r)
  | 2 -> Resolve.Expect (e, p, Some (Value.decode r))
  | 3 -> Resolve.Expect (e, p, None)
  | _ -> raise Codec.Short

let request_kind = function
  | Hello _ -> k_hello
  | Open _ -> k_open
  | Get _ -> k_get
  | Find _ -> k_find
  | Write _ -> k_write
  | Ping _ -> k_ping
  | Admin _ -> k_admin
  | Follow _ -> k_follow

let put_request b = function
  | Hello h ->
    Codec.put_varint b h.version; Codec.put_string b h.token; Codec.put_string b h.program; Codec.put_varint b h.session
  | Open name -> Codec.put_string b name
  | Get g -> Codec.put_varint b g.db; Codec.put_varint b g.thing
  | Find f -> Codec.put_varint b f.db; put_query b f.query; put_select b f.select
  | Write w ->
    Codec.put_varint b w.db;
    Codec.put_varint b w.serial;
    Codec.put_varint b w.floor;
    Codec.put_int b w.by;
    Codec.put_string b w.why;
    Codec.put_varint b (List.length w.ops);
    List.iter (put_op b) w.ops
  | Ping s -> Buffer.add_string b s
  | Admin what -> Codec.put_string b what
  | Follow db -> Codec.put_varint b db

let get_request kind (r : Codec.reader) =
  let req =
    if kind = k_hello then
      let version = Codec.get_varint r in
      let token = Codec.get_string r in
      let program = Codec.get_string r in
      let session = Codec.get_varint r in
      Hello { version; token; program; session }
    else if kind = k_open then Open (Codec.get_string r)
    else if kind = k_get then
      let db = Codec.get_varint r in
      let thing = Codec.get_varint r in
      Get { db; thing }
    else if kind = k_find then
      let db = Codec.get_varint r in
      let query = get_query r in
      let select = get_select r in
      Find { db; query; select }
    else if kind = k_write then
      let db = Codec.get_varint r in
      let serial = Codec.get_varint r in
      let floor = Codec.get_varint r in
      let by = Codec.get_int r in
      let why = Codec.get_string r in
      let ops = List.init (count r) (fun _ -> get_op r) in
      Write { db; serial; floor; by; why; ops }
    else if kind = k_ping then (
      let s = Bytes.sub_string r.buf r.pos (r.stop - r.pos) in
      r.pos <- r.stop;
      Ping s)
    else if kind = k_admin then Admin (Codec.get_string r)
    else if kind = k_follow then Follow (Codec.get_varint r)
    else raise (Malformed (Printf.sprintf "unknown request kind %d" kind))
  in
  if not (Codec.at_end r) then raise (Malformed "bytes after the request");
  req

(* ---- replies ---- *)

let put_prop b (id, (d : Schema.prop)) =
  Codec.put_varint b id;
  Codec.put_string b d.name;
  Codec.put_varint b (Value.code d.typ);
  Buffer.add_char b (if d.many then '\001' else '\000');
  Buffer.add_char b (if d.unique then '\001' else '\000')

let get_prop r =
  let id = Codec.get_varint r in
  let name = Codec.get_string r in
  let typ = match Value.of_code (Codec.get_varint r) with Some t -> t | None -> raise Codec.Short in
  let many = Codec.get_byte r = 1 in
  let unique = Codec.get_byte r = 1 in
  id, { Schema.name; typ; many; unique }

let put_runs b runs = Codec.put_varint b (List.length runs); List.iter (fun (lo, hi) -> Codec.put_varint b lo; Codec.put_varint b hi) runs

let get_runs r = List.init (count r) (fun _ -> let lo = Codec.get_varint r in let hi = Codec.get_varint r in lo, hi)

let put_reply b = function
  | Welcome w ->
    Codec.put_string b w.server; Codec.put_string b w.cluster; Codec.put_varint b w.session; Codec.put_varint b w.frame;
    Codec.put_varint b w.inflight
  | Opened o ->
    Codec.put_varint b o.db; Codec.put_varint b o.group; Codec.put_varint b (List.length o.props); List.iter (put_prop b) o.props
  | Facts f ->
    Codec.put_varint b f.group;
    Codec.put_varint b (List.length f.facts);
    List.iter (fun (p, v) -> Codec.put_varint b p; Value.encode b v) f.facts
  | Rows rw ->
    Codec.put_varint b rw.group;
    Codec.put_varint b rw.cols;
    Codec.put_varint b (List.length rw.rows);
    List.iter (Array.iter (Value.encode b)) rw.rows
  | Receipt r ->
    Codec.put_varint b r.group;
    Codec.put_varint b (List.length r.things);
    List.iter (fun (t, e) -> Codec.put_int b t; Codec.put_varint b e) r.things
  | Pong s -> Buffer.add_string b s
  | Status l -> Codec.put_varint b (List.length l); List.iter (fun (k, v) -> Codec.put_string b k; Codec.put_string b v) l
  | Start st -> Codec.put_string b st.id; Codec.put_varint b st.vseq; put_runs b st.runs
  | Err e -> Codec.put_string b e.code; Codec.put_string b e.message

let get_reply kind flags (r : Codec.reader) =
  if flags land f_error <> 0 then
    let code = Codec.get_string r in
    let message = Codec.get_string r in
    Err { code; message }
  else if kind = k_hello then
    let server = Codec.get_string r in
    let cluster = Codec.get_string r in
    let session = Codec.get_varint r in
    let frame = Codec.get_varint r in
    let inflight = Codec.get_varint r in
    Welcome { server; cluster; session; frame; inflight }
  else if kind = k_open then
    let db = Codec.get_varint r in
    let group = Codec.get_varint r in
    let props = List.init (count r) (fun _ -> get_prop r) in
    Opened { db; group; props }
  else if kind = k_get then
    let group = Codec.get_varint r in
    let facts = List.init (count r) (fun _ -> let p = Codec.get_varint r in let v = Value.decode r in p, v) in
    Facts { group; facts }
  else if kind = k_find then
    let group = Codec.get_varint r in
    let cols = Codec.get_varint r in
    let n = count r in
    let rows = List.init n (fun _ -> Array.init cols (fun _ -> Value.decode r)) in
    Rows { group; cols; rows }
  else if kind = k_write then
    let group = Codec.get_varint r in
    let things = List.init (count r) (fun _ -> let t = Codec.get_int r in let e = Codec.get_varint r in t, e) in
    Receipt { group; things }
  else if kind = k_ping then (
    let s = Bytes.sub_string r.buf r.pos (r.stop - r.pos) in
    r.pos <- r.stop;
    Pong s)
  else if kind = k_admin then
    Status (List.init (count r) (fun _ -> let k = Codec.get_string r in let v = Codec.get_string r in k, v))
  else if kind = k_follow then
    let id = Codec.get_string r in
    let vseq = Codec.get_varint r in
    Start { id; vseq; runs = get_runs r }
  else raise (Malformed (Printf.sprintf "unknown reply kind %d" kind))

(* ---- the follow stream's pushes (request id 0) ----
     frame = vseq | first | count | the groups' bytes (the journal's coding); a long one continues in frames of the
             flag more that carry bytes only
     runs  = vseq | runs (lo, hi), newest first; their descriptors ride on its first byte *)

let put_frame_head b ~vseq ~first ~count = Codec.put_varint b vseq; Codec.put_varint b first; Codec.put_varint b count
let get_frame_head r = let vseq = Codec.get_varint r in let first = Codec.get_varint r in let count = Codec.get_varint r in vseq, first, count
let put_runs_push b ~vseq runs = Codec.put_varint b vseq; put_runs b runs
let get_runs_push r = let vseq = Codec.get_varint r in vseq, get_runs r

(* ---- errors as values: the API's codes and the server's ---- *)

let code_of_error = function
  | Engine.Conflict m -> "conflict", m
  | Engine.Invalid m -> "invalid", m
  | Engine.Not_unique m -> "unique", m
  | Engine.Damaged m -> "damaged", m
  | Engine.Io m -> "io", m
  | Engine.Busy m -> "busy", m
  | Engine.Closed -> "closed", "the database is closed"
