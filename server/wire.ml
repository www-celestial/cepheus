(* The wire protocol, versions 1 to 8. Version 2 adds the question's extension (Not, Or, In, Prefix, Sort, Limit,
   After: below), version 3 the files of the vault (Put, Piece, Load: below), version 4 the operation Incr (tag 4 of
   put_op), version 5 a Watch's Sort and Limit (its extension's order, which an older server refuses), version 6 a
   question's time (a Find's or a Watch's, after its extension), version 7 the operators Less, Less_or_equal and
   Optional (tags 6, 7 and 8 of put_item; a missing cell of a row is Value.missing, the link -2^62, which no thing
   has), version 8 the operation Delete (tag 5 of put_op) and the links that name a kind (the facts of cepheus/to and
   cepheus/delete, properties 7 and 8, in a Write), and nothing else: a server speaks all eight, a program says in
   Hello the version it speaks, and against an older server a program speaks that server's version (Client.hello)
   and asks nothing that version lacks. A connection carries frames both ways:

     frame  = length u32 LE (the bytes after this field, at most 16 MiB) | id u32 LE | kind u8 | flags u8 | body
     flags  = bit 0: more (a reply in several frames: the rows of a Find), bit 1: error (the body is an error)

   A reply carries its request's id and kind; replies may come out of order (choice 7), matched by id. A value is
   coded alone by Value.encode (a tag byte, then varints and strings), as a value is everywhere one goes alone (the
   journal codes a group's values in columns, Group). *)

open Cepheus
module Ask = Question.Ask
module Top = Question.Top

let version = 8

(* the oldest version a server still speaks *)
let oldest = 1
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

(* live questions: Watch's reply is a stream of pushes on its id (an answer, or same, then changes), until Unwatch, or
   an error that ends it; the follow stream's Durable says up to which visibility number the frames are durable *)
let k_watch = 11
let k_unwatch = 12
let k_durable = 13

(* files (version 3): a Put (its description and its first bytes), then Pieces on the same id, each frame but the
   last with the flag more; the reply (on the Put's id and kind) is the receipt of the group that describes the file,
   written once its bytes are on the disk. A Load's reply is the bytes, in frames of the flag more but the last. *)
let k_put = 14
let k_piece = 15
let k_load = 16

(* the key of an owner destroyed: its files can no longer be read, anywhere their bytes went *)
let k_erase = 17

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
  | Find of { db : int; query : Query.t; select : select; extra : Ask.item list; order : Top.order; timeout : int }
      (** [extra]: Not, Or and In; [order]: Sort, Limit and After; with neither, the request is coded as before them;
          [timeout]: the milliseconds the program gives the question (version 6; 0: the server's question_timeout),
          coded after the extension when not 0 *)
  | Write of { db : int; serial : int; floor : int; by : int; why : string; ops : Resolve.op list }
  | Ping of string
  | Admin of string
  | Follow of int  (** a database: this connection becomes its follow stream *)
  | Watch of { db : int; query : Query.t; select : select; from : int; wextra : Ask.item list; worder : Top.order; wtimeout : int }
      (** the question kept answered; [from]: the group whose answer the program holds (0: none); [worder]: Sort and
          Limit (version 5), coded as Find's order; with neither it nor [wextra], the request is coded as before them;
          [wtimeout]: the milliseconds its first answer may take (version 6), as Find's *)
  | Unwatch of int  (** the id of the Watch *)
  | Put of {
      db : int;
      serial : int;
      floor : int;
      by : int;
      why : string;
      kind : string;  (** the file kind: its facts are kind/Name, kind/Size, kind/Type, kind/Owner, kind/Content *)
      name : string;
      typ : string;  (** a media type, as "application/pdf" *)
      owner : int;  (** the thing whose key the file is sealed with (0: the database's own) *)
      cold : bool;
      data : string;  (** its first bytes *)
    }
  | Piece of string  (** more bytes of the Put of this id *)
  | Load of { db : int; thing : int; prop : int; from : int; len : int  (** -1: to the end *) }
  | Erase of { db : int; owner : int }

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
  | Unwatched
  | Data of string  (** bytes of a file (a Load's reply joins its frames') *)
  | Erased
  | Err of { code : string; message : string }

exception Malformed of string

(* ---- frames ---- *)

let u32 b o = Int32.to_int (Bytes.get_int32_le b o) land 0xFFFF_FFFF

(* the frame header and an already coded body: whole or not at all (a buffer that cannot grow, memory, leaves [out]
   as it was: half a frame would make the peer read the next frame as its body) *)
let add_frame out ~id ~kind ~flags body =
  let n = Buffer.length out in
  try
    Buffer.add_int32_le out (Int32.of_int (6 + Buffer.length body));
    Buffer.add_int32_le out (Int32.of_int id);
    Buffer.add_uint8 out kind;
    Buffer.add_uint8 out flags;
    Buffer.add_buffer out body
  with e -> Buffer.truncate out n; raise e

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

(* the patterns of a question over the wire, at most: as many as its variables may be (64), so that the planner and
   the join's lookups (each candidate is looked up in every other pattern of its variable) stay in proportion to a
   question a program writes; refused before they are decoded *)
let max_patterns = 64

let get_query r : Query.t =
  let vars = Codec.get_varint r in
  if vars > 64 then raise (Malformed "a question has at most 64 variables");
  let n = count r in
  if n > max_patterns then raise (Malformed (Printf.sprintf "a question has at most %d patterns, not %d" max_patterns n));
  let where = List.init n (fun _ -> let e = get_term r in let p = Codec.get_varint r in let v = get_term r in { Query.e; p; v }) in
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

(* What a question asks beyond its patterns, ranges and select, after them in a Find (and a Watch): a byte 1, then its
   operators (a count, then each: 0 a pattern, 1 a range, 2 In (variable, count, values), 3 Not (count, items), 4 Or
   (count of alternatives, each a count and its items), 5 Prefix (variable, text), 6 Less (two variables), 7
   Less_or_equal (two variables), 8 Optional (a pattern)), its Sort (a count, then each key's column and a byte 1 when
   descending), its Limit (0: none) and its After (a byte 0, or 1 then a count and the values). A question without
   them is coded as before them, so that a server that does not know them reads every other question as it did, and
   refuses this one (bytes after the request). *)
let rec put_item b = function
  | Ask.Pattern (p : Query.pattern) -> Buffer.add_char b '\000'; put_term b p.e; Codec.put_varint b p.p; put_term b p.v
  | Range (x, lo, hi) -> Buffer.add_char b '\001'; Codec.put_varint b x; Value.encode b lo; Value.encode b hi
  | In (x, l) -> Buffer.add_char b '\002'; Codec.put_varint b x; Codec.put_varint b (List.length l); List.iter (Value.encode b) l
  | Prefix (x, p) -> Buffer.add_char b '\005'; Codec.put_varint b x; Codec.put_string b p
  | Not l -> Buffer.add_char b '\003'; Codec.put_varint b (List.length l); List.iter (put_item b) l
  | Or alts -> Buffer.add_char b '\004'; Codec.put_varint b (List.length alts); List.iter (fun a -> Codec.put_varint b (List.length a); List.iter (put_item b) a) alts
  | Less (x, y) -> Buffer.add_char b '\006'; Codec.put_varint b x; Codec.put_varint b y
  | Less_or_equal (x, y) -> Buffer.add_char b '\007'; Codec.put_varint b x; Codec.put_varint b y
  | Optional p -> Buffer.add_char b '\008'; put_term b p.e; Codec.put_varint b p.p; put_term b p.v

let rec get_item depth r =
  if depth > 2 then raise (Malformed "operators nested too deep");
  match Codec.get_byte r with
  | 0 -> let e = get_term r in let p = Codec.get_varint r in let v = get_term r in Ask.Pattern { Query.e; p; v }
  | 1 -> let x = Codec.get_varint r in let lo = Value.decode r in let hi = Value.decode r in Range (x, lo, hi)
  | 2 -> let x = Codec.get_varint r in In (x, List.init (count r) (fun _ -> Value.decode r))
  | 3 -> Not (List.init (count r) (fun _ -> get_item (depth + 1) r))
  | 4 -> Or (List.init (count r) (fun _ -> List.init (count r) (fun _ -> get_item (depth + 1) r)))
  | 5 -> let x = Codec.get_varint r in Prefix (x, Codec.get_string r)
  | 6 -> let x = Codec.get_varint r in Less (x, Codec.get_varint r)
  | 7 -> let x = Codec.get_varint r in Less_or_equal (x, Codec.get_varint r)
  | 8 -> let e = get_term r in let p = Codec.get_varint r in let v = get_term r in Optional { Query.e; p; v }
  | _ -> raise (Malformed "an operator this server does not know")

(* does a question's extension hold an operator of version 7 (Less, Less_or_equal, Optional), which a server of an
   earlier version does not know *)
let rec newer = function Ask.Less _ | Less_or_equal _ | Optional _ -> true | Not l -> List.exists newer l | Or alts -> List.exists (List.exists newer) alts | _ -> false

let needs_7 extra = List.exists newer extra

let put_order b ?(extra = []) (o : Top.order) =
  Buffer.add_char b '\001';
  Codec.put_varint b (List.length extra);
  List.iter (put_item b) extra;
  Codec.put_varint b (List.length o.keys);
  List.iter (fun (k : Top.key) -> Codec.put_varint b k.col; Buffer.add_char b (if k.desc then '\001' else '\000')) o.keys;
  Codec.put_varint b o.limit;
  match o.after with
  | None -> Buffer.add_char b '\000'
  | Some a -> Buffer.add_char b '\001'; Codec.put_varint b (Array.length a); Array.iter (Value.encode b) a

let get_order r : Ask.item list * Top.order =
  if Codec.at_end r then [], Top.none
  else begin
    if Codec.get_byte r <> 1 then raise (Malformed "an unknown extension of a question");
    let extra = List.init (count r) (fun _ -> get_item 0 r) in
    let keys =
      List.init (count r) (fun _ ->
          let col = Codec.get_varint r in
          let desc = match Codec.get_byte r with 0 -> false | 1 -> true | _ -> raise Codec.Short in
          { Top.col; desc })
    in
    let limit = Codec.get_varint r in
    let after = match Codec.get_byte r with 0 -> None | 1 -> Some (Array.init (count r) (fun _ -> Value.decode r)) | _ -> raise Codec.Short in
    extra, { keys; limit; after }
  end

(* a question's time in milliseconds after its extension (version 6), at most a week; none: 0 *)
let max_timeout = 604_800_000

let get_timeout r =
  if Codec.at_end r then 0
  else
    let t = Codec.get_varint r in
    if t < 1 || t > max_timeout then raise (Malformed "a question's time is 1 ms to a week") else t

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
  (* version 4: by (zigzag), then a byte 0, or 1 and into's thing (zigzag) and property *)
  | Resolve.Incr (e, p, by, into) -> (
    Buffer.add_char b '\004'; Codec.put_int b e; Codec.put_varint b p; Codec.put_int b by;
    match into with
    | None -> Buffer.add_char b '\000'
    | Some (t, q) -> Buffer.add_char b '\001'; Codec.put_int b t; Codec.put_varint b q)
  (* version 8: the thing (zigzag), then the kind's name *)
  | Resolve.Delete (e, k) -> Buffer.add_char b '\005'; Codec.put_int b e; Codec.put_string b k

let get_op r =
  let tag = Codec.get_byte r in
  let e = Codec.get_int r in
  if tag = 5 then Resolve.Delete (e, Codec.get_string r)
  else
  let p = Codec.get_varint r in
  match tag with
  | 0 -> Resolve.Add (e, p, Value.decode r)
  | 1 -> Resolve.Retract (e, p, Value.decode r)
  | 2 -> Resolve.Expect (e, p, Some (Value.decode r))
  | 3 -> Resolve.Expect (e, p, None)
  | 4 -> (
    let by = Codec.get_int r in
    match Codec.get_byte r with
    | 0 -> Resolve.Incr (e, p, by, None)
    | 1 -> let t = Codec.get_int r in let q = Codec.get_varint r in Resolve.Incr (e, p, by, Some (t, q))
    | _ -> raise Codec.Short)
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
  | Watch _ -> k_watch
  | Unwatch _ -> k_unwatch
  | Put _ -> k_put
  | Piece _ -> k_piece
  | Load _ -> k_load
  | Erase _ -> k_erase

let put_request b = function
  | Hello h ->
    Codec.put_varint b h.version; Codec.put_string b h.token; Codec.put_string b h.program; Codec.put_varint b h.session
  | Open name -> Codec.put_string b name
  | Get g -> Codec.put_varint b g.db; Codec.put_varint b g.thing
  | Find f ->
    Codec.put_varint b f.db; put_query b f.query; put_select b f.select;
    if f.extra <> [] || f.order <> Top.none || f.timeout > 0 then put_order b ~extra:f.extra f.order;
    if f.timeout > 0 then Codec.put_varint b f.timeout
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
  | Watch w ->
    Codec.put_varint b w.db; put_query b w.query; put_select b w.select; Codec.put_varint b w.from;
    if w.wextra <> [] || w.worder <> Top.none || w.wtimeout > 0 then put_order b ~extra:w.wextra w.worder;
    if w.wtimeout > 0 then Codec.put_varint b w.wtimeout
  | Unwatch id -> Codec.put_varint b id
  | Put p ->
    Codec.put_varint b p.db;
    Codec.put_varint b p.serial;
    Codec.put_varint b p.floor;
    Codec.put_int b p.by;
    Codec.put_string b p.why;
    Codec.put_string b p.kind;
    Codec.put_string b p.name;
    Codec.put_string b p.typ;
    Codec.put_varint b p.owner;
    Buffer.add_char b (if p.cold then '\001' else '\000');
    Buffer.add_string b p.data
  | Piece s -> Buffer.add_string b s
  | Load l -> Codec.put_varint b l.db; Codec.put_varint b l.thing; Codec.put_varint b l.prop; Codec.put_varint b l.from; Codec.put_int b l.len
  | Erase e -> Codec.put_varint b e.db; Codec.put_varint b e.owner

(* the rest of a frame's body *)
let rest (r : Codec.reader) = let s = Bytes.sub_string r.buf r.pos (r.stop - r.pos) in r.pos <- r.stop; s

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
      let extra, order = get_order r in
      let timeout = get_timeout r in
      Find { db; query; select; extra; order; timeout }
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
    else if kind = k_watch then
      let db = Codec.get_varint r in
      let query = get_query r in
      let select = get_select r in
      let from = Codec.get_varint r in
      let wextra, worder = get_order r in
      let wtimeout = get_timeout r in
      Watch { db; query; select; from; wextra; worder; wtimeout }
    else if kind = k_unwatch then Unwatch (Codec.get_varint r)
    else if kind = k_put then
      let db = Codec.get_varint r in
      let serial = Codec.get_varint r in
      let floor = Codec.get_varint r in
      let by = Codec.get_int r in
      let why = Codec.get_string r in
      let kind = Codec.get_string r in
      let name = Codec.get_string r in
      let typ = Codec.get_string r in
      let owner = Codec.get_varint r in
      let cold = match Codec.get_byte r with 0 -> false | 1 -> true | _ -> raise Codec.Short in
      Put { db; serial; floor; by; why; kind; name; typ; owner; cold; data = rest r }
    else if kind = k_piece then Piece (rest r)
    else if kind = k_load then
      let db = Codec.get_varint r in
      let thing = Codec.get_varint r in
      let prop = Codec.get_varint r in
      let from = Codec.get_varint r in
      let len = Codec.get_int r in
      if len < -1 then raise (Malformed "a Load's length is -1 (to the end) or more");
      Load { db; thing; prop; from; len }
    else if kind = k_erase then
      let db = Codec.get_varint r in
      let owner = Codec.get_varint r in
      Erase { db; owner }
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
  | Unwatched -> ()
  | Data s -> Buffer.add_string b s
  | Erased -> ()
  | Err e -> Codec.put_string b e.code; Codec.put_string b e.message

(* an error that names where to ask instead (a Raft cluster's not_leader): the address after the message, which
   [get_reply] skips (as every decoder since protocol 1 does: none checks an error's end); [moved] reads it *)
let put_moved b ~code ~message ~address =
  Codec.put_string b code;
  Codec.put_string b message;
  if address <> "" then Codec.put_string b address

(* a Raft cluster's Welcome: the members' addresses for programs after its fields, which every client's decoder since
   protocol 1 skips; [members] reads them (none from a single server) *)
let put_members b l = Codec.put_varint b (List.length l); List.iter (Codec.put_string b) l

let members (r : Codec.reader) =
  match
    let _ = Codec.get_string r in
    let _ = Codec.get_string r in
    let _ = Codec.get_varint r in
    let _ = Codec.get_varint r in
    let _ = Codec.get_varint r in
    if Codec.at_end r then []
    else
      let n = Codec.get_varint r in
      if n > 64 then [] else List.init n (fun _ -> Codec.get_string r)
  with
  | l -> l
  | exception Codec.Short -> []

let moved flags (r : Codec.reader) =
  if flags land f_error = 0 then None
  else
    match
      let _ = Codec.get_string r in
      let _ = Codec.get_string r in
      if Codec.at_end r then None else Some (Codec.get_string r)
    with
    | x -> x
    | exception Codec.Short -> None

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
  else if kind = k_unwatch then Unwatched
  else if kind = k_put then
    let group = Codec.get_varint r in
    let things = List.init (count r) (fun _ -> let t = Codec.get_int r in let e = Codec.get_varint r in t, e) in
    Receipt { group; things }
  else if kind = k_load then Data (rest r)
  else if kind = k_erase then Erased
  else raise (Malformed (Printf.sprintf "unknown reply kind %d" kind))

(* ---- the follow stream's pushes (request id 0) ----
     frame = vseq | first | count | the groups' bytes (the journal's coding); a long one continues in frames of the
             flag more that carry bytes only
     runs  = vseq | runs (lo, hi), newest first; their descriptors ride on its first byte *)

let put_frame_head b ~vseq ~first ~count = Codec.put_varint b vseq; Codec.put_varint b first; Codec.put_varint b count
let get_frame_head r = let vseq = Codec.get_varint r in let first = Codec.get_varint r in let count = Codec.get_varint r in vseq, first, count
let put_runs_push b ~vseq runs = Codec.put_varint b vseq; put_runs b runs
let get_runs_push r = let vseq = Codec.get_varint r in vseq, get_runs r

(* ---- a watch's pushes: on the Watch's id, kind k_watch ----
     answer = 0 | group | cols | n | rows                     the whole answer at group
     change = 1 | group | cols | added: n | rows | removed: n | rows
     same   = 2 | group                                       the answer at group is the one at from
   A long answer or change continues in frames of the flag more, each of the same form (its rows added to the
   message's); an error (the flag error) ends the watch: "lagging" asks the program to watch again from its group. *)

type push =
  | Answer of { group : int; cols : int; rows : Value.t array list }
  | Change of { group : int; cols : int; added : Value.t array list; removed : Value.t array list }
  | Same of int

let push_chunk = 1 lsl 20

(* a row of a push whose coding would pass the frame limit by itself: its watch ends (Core) *)
exception Row_too_large of int

let put_rows b rows = Codec.put_varint b (List.length rows); List.iter (Array.iter (Value.encode b)) rows

(* the push as frames of about a MiB *)
let add_push out ~id (p : push) =
  let body = Buffer.create 256 in
  let frame ~more = add_frame out ~id ~kind:k_watch ~flags:(if more then f_more else 0) body; Buffer.clear body in
  (* rows taken while the chunk is under its size, one at least; a row that would take the chunk past a frame goes
     to the next *)
  let rec cut acc size = function
    | r :: rest when size < push_chunk || acc = [] ->
      let rb = Buffer.create 64 in
      Array.iter (Value.encode rb) r;
      let k = Buffer.length rb in
      if k > max_frame - 64 then raise (Row_too_large k);
      if size > 0 && size + k > max_frame - 64 then List.rev acc, r :: rest, size else cut (r :: acc) (size + k) rest
    | rest -> List.rev acc, rest, size
  in
  match p with
  | Same g -> Buffer.add_char body '\002'; Codec.put_varint body g; frame ~more:false
  | Answer a ->
    let rec go rows =
      let now, rest, _ = cut [] 0 rows in
      Buffer.add_char body '\000'; Codec.put_varint body a.group; Codec.put_varint body a.cols; put_rows body now;
      frame ~more:(rest <> []);
      if rest <> [] then go rest
    in
    go a.rows
  | Change c ->
    let rec go added removed =
      let na, ra, size = cut [] 0 added in
      let nr, rr, _ = if ra = [] then cut [] size removed else [], removed, size in
      Buffer.add_char body '\001'; Codec.put_varint body c.group; Codec.put_varint body c.cols; put_rows body na; put_rows body nr;
      let more = ra <> [] || rr <> [] in
      frame ~more;
      if more then go ra rr
    in
    go c.added c.removed

let get_rows r cols = let n = count r in List.init n (fun _ -> Array.init cols (fun _ -> Value.decode r))

(* one frame of a push *)
let get_push (r : Codec.reader) =
  match Codec.get_byte r with
  | 0 -> let group = Codec.get_varint r in let cols = Codec.get_varint r in Answer { group; cols; rows = get_rows r cols }
  | 1 ->
    let group = Codec.get_varint r in
    let cols = Codec.get_varint r in
    let added = get_rows r cols in
    let removed = get_rows r cols in
    Change { group; cols; added; removed }
  | 2 -> Same (Codec.get_varint r)
  | _ -> raise Codec.Short

(* the frames of one push joined *)
let join_push a b =
  match a, b with
  | Answer x, Answer y -> Answer { x with rows = x.rows @ y.rows }
  | Change x, Change y -> Change { x with added = x.added @ y.added; removed = x.removed @ y.removed }
  | _, y -> y

(* ---- errors as values: the API's codes and the server's ---- *)

let code_of_error = function
  | Engine.Conflict m -> "conflict", m
  | Engine.Invalid m -> "invalid", m
  | Engine.Not_unique m -> "unique", m
  | Engine.Damaged m -> "damaged", m
  | Engine.Io m -> "io", m
  | Engine.Busy m -> "busy", m
  | Engine.Closed -> "closed", "the database is closed"
  | Engine.Timeout m -> "timeout", m
