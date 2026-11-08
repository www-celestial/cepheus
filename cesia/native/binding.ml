(* The natives of the Cesia package cepheus (cesia/cepheus/cepheus.ce), on Cesia's native interface alone (Cesia_v1).

   A program reaches a database through a server: Connect gives a handle of the kind "cepheus.database". On the
   server's machine (its Unix socket) the reads are served from the program's own memory, followed from the server
   (Client, Follower: linearizable, G15); elsewhere, and for every write, they go to the server over TLS. A fork is a
   state in the program's memory, written with the same checks and never sent anywhere (G8): of Empty for a unit test
   that needs no server, of a database read locally, or of another fork.

   What the package keeps between calls is OCaml data: kinds, databases and forks in tables, by the numbers of their
   handles; never a value of the program. *)

module C = Cesia_v1
open Cepheus
open Cepheus_server

(* ---- reading the arguments: a match each, and Cesia's message for a wrong one ---- *)

let int ctx name = function C.Int i -> i | v -> C.need ctx name "an Int" v
let text ctx name = function C.Text s -> s | v -> C.need ctx name "a Text" v
let bool ctx name = function C.Bool b -> b | C.Missing -> false | v -> C.need ctx name "a Bool" v
let opt_text ctx name = function C.Missing -> None | C.Text s -> Some s | v -> C.need ctx name "a Text" v
let list_of ctx name = function C.List l -> Array.init (C.length l) (C.item ctx l) | v -> C.need ctx name "a list" v
let map_of ctx name = function C.Map m | C.Struct m -> m | v -> C.need ctx name "a map" v

(* ---- errors as values: {Kind: "cepheus", Code, Message} ---- *)

let err_keys = C.keys [| "Kind"; "Code"; "Message" |]
let failure ctx code message = C.err ctx (C.record ctx err_keys [| Text "cepheus"; Text code; Text message |])

exception Refused of string * string (* code, message: a call that gives an Err *)

let refuse code fmt = Printf.ksprintf (fun m -> raise (Refused (code, m))) fmt

let resolve_code = function
  | Resolve.Conflict m -> "conflict", m
  | Resolve.Invalid m -> "invalid", m
  | Resolve.Not_unique m -> "unique", m

(* ---- tables by number: a handle's number is its index, found without a hash ---- *)

type 'a table = { mutable items : 'a option array; mutable count : int }

let table () = { items = Array.make 8 None; count = 0 }

let add t x =
  if t.count = Array.length t.items then begin
    let a = Array.make (2 * t.count) None in
    Array.blit t.items 0 a 0 t.count;
    t.items <- a
  end;
  t.items.(t.count) <- Some x;
  t.count <- t.count + 1;
  t.count - 1

let entry t i = if i >= 0 && i < t.count then Array.unsafe_get t.items i else None

(* ---- kinds: declared by the program, the same for every database it reaches ---- *)

type field = { fname : string; pname : string; typ : Value.typ; many : bool; unique : bool }

type kind = {
  kname : string;
  index : int;
  keys : C.keys;  (* "kind" and the fields: the kind's own map *)
  fkeys : C.keys;  (* the fields: a thing's map *)
  fields : field array;
  has_many : bool;
}

(* the kinds, and every field of every kind as a property (the handles "cepheus.property" of patterns) *)
let kinds : kind table = table ()
let properties : (kind * int) table = table ()
let kind_key = C.keys [| "kind" |]
let type_keys = C.keys [| "Type"; "Scale"; "Unique"; "Many" |]

let valid_kind_name s =
  s <> "" && String.for_all (fun c -> (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '_' || c = '-') s

let typ_of_text ctx name t scale =
  match t with
  | "text" -> Value.Ttext
  | "int" -> Tint
  | "float" -> Tfloat
  | "bool" -> Tbool
  | "date" -> Tdate
  | "link" -> Tlink
  | "money" -> (
    match scale with
    | C.Int s when s >= 0 && s <= 18 -> Tmoney s
    | v -> C.need ctx name "a scale of 0 to 18 digits for Money" v)
  | _ -> C.panic ctx (Printf.sprintf "%s: %S is not a type of property (cepheus.Text(), Int(), Float(), Bool(), Date(), Link() or Money(scale))" name t)

let kind ctx a =
  let name = "cepheus.Kind" in
  let kname = text ctx name a.(0) in
  if not (valid_kind_name kname) then
    C.panic ctx (Printf.sprintf "%s: %S is not a kind's name: small letters, digits, _ and -" name kname);
  let m = map_of ctx name a.(1) in
  let names = C.names m and descs = C.values m in
  if Array.length names = 0 then C.panic ctx (name ^ ": a kind needs at least one field");
  let fields =
    Array.mapi
      (fun i fname ->
        if fname = "kind" then C.panic ctx (name ^ ": kind is the name the package keeps for itself: name the field otherwise");
        let d = map_of ctx name descs.(i) in
        match C.fields type_keys d with
        | [| Text t; scale; unique; many |] ->
          { fname; pname = kname ^ "/" ^ fname; typ = typ_of_text ctx name t scale; unique = bool ctx name unique; many = bool ctx name many }
        | _ -> C.need ctx name "a type of property, as cepheus.Text()" descs.(i))
      names
  in
  let index = kinds.count in
  let k = { kname; index; keys = C.keys (Array.append [| "kind" |] names); fkeys = C.keys names; fields;
            has_many = Array.exists (fun f -> f.many) fields } in
  ignore (add kinds k);
  let base = properties.count in
  Array.iteri (fun i _ -> ignore (add properties (k, i))) fields;
  C.record ctx k.keys
    (Array.append [| C.Handle ("cepheus.kind", index) |] (Array.mapi (fun i _ -> C.Handle ("cepheus.property", base + i)) fields))

let kind_of ctx name v =
  let m = map_of ctx name v in
  match C.fields kind_key m with
  | [| C.Handle ("cepheus.kind", i) |] -> (match entry kinds i with Some k -> k | None -> C.need ctx name "a kind" v)
  | _ -> C.need ctx name "a kind, as cepheus.Kind made it" v

let property_of ctx name = function
  | C.Handle ("cepheus.property", p) as v -> (match entry properties p with Some kf -> kf | None -> C.need ctx name "a property" v)
  | v -> C.need ctx name "a property of a kind, as Client.City" v

let props_of (k : kind) = Array.to_list (Array.map (fun f -> { Schema.name = f.pname; typ = f.typ; many = f.many; unique = f.unique }) k.fields)

(* ---- values, between Cesia and the database ---- *)

let pow10 = Array.init 19 (fun i -> let r = ref 1 in for _ = 1 to i do r := !r * 10 done; !r)

(* a date is the seconds since 1970 in Cesia (sys.Now, std/date), the milliseconds in Cepheus; money a decimal of
   [scale] digits: a Float in Cesia, minor units in Cepheus *)
let to_cesia (typ : Value.typ) (x : Value.t) : C.value =
  match x with
  | Int i | Link i -> Int i
  | Float f -> Float f
  | Bool b -> Bool b
  | Text s -> Text s
  | Date ms -> Float (float_of_int ms /. 1000.)
  | Money u -> (match typ with Tmoney s -> Float (float_of_int u /. float_of_int pow10.(s)) | _ -> Int u)

(* straight from an index word: no Value.t is made for an inline type *)
let of_word (v : Store.view) (typ : Value.typ) w : C.value =
  match typ with
  | Tint | Tlink -> Int w
  | Tbool -> Bool (w <> 0)
  | Tdate -> Float (float_of_int w /. 1000.)
  | Tmoney s -> Float (float_of_int w /. float_of_int pow10.(s))
  | Ttext -> Text (Store.text v w)
  | Tfloat -> to_cesia typ (Store.value v typ w)

let describe = function
  | C.Missing -> "missing" | Bool b -> string_of_bool b | Int i -> "the number " ^ string_of_int i
  | Float x -> "the number " ^ string_of_float x | Text s -> Printf.sprintf "the text %S" s | Handle (k, _) -> "a handle " ^ k
  | List _ -> "a list" | Map _ -> "a map" | Struct _ -> "a struct" | Function _ -> "a function" | Other _ -> "a value"

let of_cesia (pname : string) (typ : Value.typ) (x : C.value) : Value.t =
  let wrong what = refuse "invalid" "%s needs %s, not %s" pname what (describe x) in
  match typ, x with
  | Ttext, Text s -> Text s
  | Tint, Int i -> Int i
  | Tfloat, Float f -> Float f
  | Tfloat, Int i -> Float (float_of_int i)
  | Tbool, Bool b -> Bool b
  | Tlink, Int i -> Link i
  | Tdate, (Int _ | Float _) ->
    let s = match x with Int i -> float_of_int i | Float f -> f | _ -> 0. in
    if Float.is_finite s && Float.abs s < 9e15 then Date (Float.to_int (Float.round (s *. 1000.))) else wrong "a date in seconds since 1970"
  | Tmoney sc, Int i ->
    if abs i < max_int / pow10.(sc) then Money (i * pow10.(sc)) else wrong "an amount that fits"
  | Tmoney sc, Float f ->
    let u = Float.round (f *. float_of_int pow10.(sc)) in
    if Float.is_finite u && Float.abs u < 4.6e18 then Money (Float.to_int u) else wrong "an amount that fits"
  | Ttext, _ -> wrong "a Text"
  | (Tint | Tlink), _ -> wrong "an Int"
  | Tfloat, _ -> wrong "a number"
  | Tbool, _ -> wrong "a Bool"
  | Tdate, _ -> wrong "a date in seconds since 1970"
  | Tmoney _, _ -> wrong "an amount"

(* ---- databases: a connection's, or a fork ---- *)

type resolved = { ids : int array; typs : Value.typ array; slot : int array (* property id -> field, or -1 *) }

type source =
  | Server of { conn : Conn.t; mutable cdb : Client.db; dbname : string }
  | Fork of { mutable fv : Store.view }

type db = { src : source; mutable resolved : resolved option array (* by kind *) }

(* closed ones are None: their numbers are never given again *)
let dbs : db table = table ()

let new_handle src = C.Handle ("cepheus.database", add dbs { src; resolved = [||] })

(* handles are never given twice: one no longer in the table was closed *)
let db_of ctx name = function
  | C.Handle ("cepheus.database", i) -> (
    match entry dbs i with Some d -> d | None -> refuse "closed" "this database was closed")
  | v -> C.need ctx name "a database, as cepheus.Connect or Fork gives it" v

(* a property of the database by its name: its id and type *)
let lookup d pname =
  match d.src with
  | Server s -> List.find_map (fun (p, (x : Schema.prop)) -> if x.name = pname then Some (p, x.typ) else None) s.cdb.props
  | Fork f -> (
    match Schema.by_name f.fv.schema pname with
    | Some p -> Option.map (fun (x : Schema.prop) -> p, x.typ) (Schema.find f.fv.schema p)
    | None -> None)

(* the ids of a kind's properties in a database, found once *)
let resolve_kind d (k : kind) =
  match if k.index < Array.length d.resolved then Array.unsafe_get d.resolved k.index else None with
  | Some r -> r
  | None ->
    let ids =
      Array.map
        (fun f ->
          match lookup d f.pname with
          | Some (p, t) when t = f.typ -> p
          | Some (_, t) -> refuse "invalid" "%s is a %s in this database, not a %s" f.pname (Value.typ_name t) (Value.typ_name f.typ)
          | None -> refuse "invalid" "%s is not declared in this database: give its kind to Connect (or Fork)" f.pname)
        k.fields
    in
    let slot = Array.make (1 + Array.fold_left max 0 ids) (-1) in
    Array.iteri (fun i p -> slot.(p) <- i) ids;
    let r = { ids; typs = Array.map (fun f -> f.typ) k.fields; slot } in
    if k.index >= Array.length d.resolved then begin
      let a = Array.make (kinds.count + 4) None in
      Array.blit d.resolved 0 a 0 (Array.length d.resolved);
      d.resolved <- a
    end;
    d.resolved.(k.index) <- Some r;
    r

(* the state to read in this program: a fork's, or a database followed here; None: read at the server *)
let local_state d =
  match d.src with
  | Fork f -> Some f.fv
  | Server s -> Client.local_view s.conn.Conn.cl s.cdb

let park ctx f = C.suspend ctx f

let server_error (r : Wire.reply) what =
  match r with Wire.Err e -> refuse e.code "%s" e.message | _ -> refuse "protocol" "an unexpected reply to %s" what

(* ---- Connect ---- *)

(* cepheus://HOST:PORT/DATABASE, or ?socket=DIR for a Unix socket in another directory than /run/cepheus *)
let parse_url ctx url =
  let name = "cepheus.Connect" in
  let bad why = C.panic ctx (Printf.sprintf "%s: %S is not a database's address (%s): cepheus://host:port/database" name url why) in
  let pre = "cepheus://" in
  let lp = String.length pre in
  if String.length url <= lp || String.sub url 0 lp <> pre then bad "it starts with cepheus://";
  let rest = String.sub url lp (String.length url - lp) in
  let rest, query =
    match String.index_opt rest '?' with Some i -> String.sub rest 0 i, Some (String.sub rest (i + 1) (String.length rest - i - 1)) | None -> rest, None
  in
  let hostport, db =
    match String.index_opt rest '/' with Some i -> String.sub rest 0 i, String.sub rest (i + 1) (String.length rest - i - 1) | None -> bad "a database is named after /"
  in
  if not (Config.valid_name db) then bad "a database's name is small letters, digits, _ and -";
  let host, port =
    match Config.host_port "the address" (if String.contains hostport ':' && not (String.ends_with ~suffix:"]" hostport) then hostport else hostport ^ ":7400") with
    | hp -> hp
    | exception Config.Bad _ -> bad "host:port"
  in
  let socket =
    match query with
    | None -> None
    | Some q when String.length q > 7 && String.sub q 0 7 = "socket=" -> Some (String.sub q 7 (String.length q - 7))
    | Some _ -> bad "the only parameter is socket=DIR"
  in
  host, port, db, socket

(* is this host one of this machine's addresses? a UDP socket binds only to a local one *)
let is_local host =
  match Unix.getaddrinfo host "0" [ Unix.AI_SOCKTYPE Unix.SOCK_DGRAM ] with
  | exception Unix.Unix_error _ -> false
  | ais ->
    List.exists
      (fun (ai : Unix.addr_info) ->
        let s = Unix.socket ~cloexec:true ai.ai_family Unix.SOCK_DGRAM 0 in
        Fun.protect ~finally:(fun () -> Unix.close s) (fun () -> match Unix.bind s ai.ai_addr with () -> true | exception Unix.Unix_error _ -> false))
      ais

(* [f ()], blocking work, on a domain of its own while the calling fiber is parked; its exceptions come back here. If
   the fiber is cancelled meanwhile, the result is dropped by [drop] when it comes. *)
type 'a run = Waiting | Done of ('a, exn) result | Abandoned

let off_domain ctx f ~drop =
  let state = Atomic.make Waiting in
  match
    C.suspend ctx (fun resume ->
        ignore
          (Domain.spawn (fun () ->
               let r = try Ok (f ()) with e -> Error e in
               if Atomic.compare_and_set state Waiting (Done r) then resume ()
               else match r with Ok x -> drop x | Error _ -> ())))
  with
  | () -> ( match Atomic.get state with Done (Ok x) -> x | Done (Error e) -> raise e | Waiting | Abandoned -> assert false)
  | exception e ->
    (* cancelled: whatever comes later is dropped *)
    if not (Atomic.compare_and_set state Waiting Abandoned) then
      (match Atomic.get state with Done (Ok x) -> drop x | _ -> ());
    raise e

(* "auth: the token is unknown" from the client's Hello: its code, when it has one *)
let split_reason m =
  match String.index_opt m ':' with
  | Some i when List.mem (String.sub m 0 i) [ "auth"; "version"; "denied"; "too_many_connections"; "stopping" ] ->
    String.sub m 0 i, String.trim (String.sub m (i + 1) (String.length m - i - 1))
  | _ -> "unreachable", m

let connect ctx a =
  let name = "cepheus.Connect" in
  let url = text ctx name a.(0) in
  let ks = Array.map (kind_of ctx name) (list_of ctx name a.(1)) in
  let token = Option.value (opt_text ctx name a.(2)) ~default:"" in
  let ca = opt_text ctx name a.(3) in
  let host, port, dbname, socket = parse_url ctx url in
  let sock dir = Filename.concat dir (Config.socket_name port) in
  let address =
    match socket with
    | Some dir -> Client.Unix_socket (sock dir)
    | None when Sys.file_exists (sock "/run/cepheus") && is_local host -> Client.Unix_socket (sock "/run/cepheus")
    | None -> Client.Tcp (host, port)
  in
  Option.iter (C.need_read ctx) ca;
  let props = List.concat_map props_of (Array.to_list ks) in
  (* the handshake, the declarations (a write: an fsync) and the Opens wait at the server: in a domain of their own,
     the calling fiber parked meanwhile, so that the program's other fibers run (a silent peer holds only this call,
     for the handshake's time) *)
  let made () =
    let cl =
      match address, ca with
      | Client.Tcp _, None -> refuse "invalid" "%s is reached over the network: give the cluster's certificate authority, ca = \"/etc/cepheus/ca.pem\"" host
      | _ -> (
        match Client.connect ~program:"cesia" ?ca address token with
        | Ok cl -> cl
        | Error m -> (
          match split_reason m with
          | "unreachable", m ->
            let where = match address with Client.Unix_socket p -> p | Client.Tcp (h, p) -> Printf.sprintf "%s:%d" h p in
            refuse "unreachable" "no Cepheus server answers at %s: %s" where m
          | code, m -> refuse code "%s" m))
    in
    let fail code m = Client.close cl; refuse code "%s" m in
    (* declare reads the schema at the server, and opens the database to read it here once it wrote *)
    let cdb =
      match Client.declare cl dbname props with
      | Ok (db, _) when db.wants_local -> db
      | Ok _ -> (match Client.open_db cl dbname with Ok d -> d | Error e -> fail e.code e.message)
      | Error e -> fail e.code e.message
      | exception Client.Broken m -> fail "unreachable" ("the server stopped answering: " ^ m)
    in
    cl, cdb
  in
  match off_domain ctx made ~drop:(fun (cl, _) -> Client.close cl) with
  | cl, cdb -> C.ok ctx (new_handle (Server { conn = Conn.start cl; cdb; dbname }))
  | exception Refused (code, m) -> failure ctx code m

(* ---- Get ---- *)

(* an array of [n] Missing, made inline up to 6 (Array.make calls C) *)
let missing n =
  match n with
  | 1 -> [| C.Missing |]
  | 2 -> [| C.Missing; C.Missing |]
  | 3 -> [| C.Missing; C.Missing; C.Missing |]
  | 4 -> [| C.Missing; C.Missing; C.Missing; C.Missing |]
  | 5 -> [| C.Missing; C.Missing; C.Missing; C.Missing; C.Missing |]
  | 6 -> [| C.Missing; C.Missing; C.Missing; C.Missing; C.Missing; C.Missing |]
  | n -> Array.make n C.Missing

(* a kind's map of a thing, from its facts given by [iter] as (field, value); a field of many values is a list;
   missing when it has none of the kind's facts *)
let record_of ctx (k : kind) iter =
  let n = Array.length k.fields in
  let vals = missing n and found = ref false in
  if not k.has_many then iter (fun i x -> found := true; Array.unsafe_set vals i x)
  else begin
    let many = Array.make n [] in
    iter (fun i x -> found := true; if k.fields.(i).many then many.(i) <- x :: many.(i) else vals.(i) <- x);
    Array.iteri (fun i f -> if f.many then vals.(i) <- C.list ctx (Array.of_list (List.rev many.(i)))) k.fields
  end;
  if !found then C.record ctx k.fkeys vals else C.Missing

let get_thing ctx d (k : kind) thing =
  let r = resolve_kind d k in
  let slot = r.slot and typs = r.typs in
  let ns = Array.length slot in
  match local_state d with
  | Some v -> (
    try
      record_of ctx k (fun f ->
          Store.iter_facts v thing (fun p w ->
              if p < ns then begin
                let i = Array.unsafe_get slot p in
                if i >= 0 then f i (of_word v (Array.unsafe_get typs i) w)
              end))
    with Pages.Unreadable m -> refuse "damaged" "%s" m)
  | None -> (
    match d.src with
    | Fork _ -> assert false
    | Server s -> (
      match Conn.read (park ctx) s.conn (Wire.Get { db = s.cdb.handle; thing }) with
      | Wire.Facts fs ->
        record_of ctx k (fun f ->
            List.iter (fun (p, x) -> if p < ns then (let i = slot.(p) in if i >= 0 then f i (to_cesia typs.(i) x))) fs.facts)
      | rep -> server_error rep "Get"))

let get ctx a =
  let name = "cepheus.Get" in
  try
    let d = db_of ctx name a.(0) in
    let k = kind_of ctx name a.(1) in
    C.ok ctx (get_thing ctx d k (int ctx name a.(2)))
  with Refused (code, m) -> failure ctx code m

(* ---- writing ---- *)

let receipt_keys = C.keys [| "Group"; "Things" |]

let commit ctx d ~by ~why ops =
  match d.src with
  | Fork f -> (
    let v = f.fv in
    match Resolve.resolve v ~n:(v.group + 1) ~time:(Disk.real.now ()) ~by ~why ops with
    | Ok (v', _, temps) -> f.fv <- v'; v'.group, temps
    | Error e -> let code, m = resolve_code e in refuse code "%s" m)
  | Server s -> (
    match Conn.write (park ctx) s.conn ~db:s.cdb.handle ~by ~why ops with
    | Wire.Receipt r -> r.group, r.things
    | rep -> server_error rep "Write")

(* a kind's fields, as a map, into operations on [thing] *)
let field_ops ctx name d (k : kind) thing fields ~update =
  let r = resolve_kind d k in
  let m = map_of ctx name fields in
  let given = C.fields k.fkeys m in
  let ops = ref [] in
  Array.iteri
    (fun i (f : field) ->
      match given.(i) with
      | C.Missing -> ()
      | x when f.many ->
        if update then refuse "invalid" "%s holds several values: change them with Write, Add and Retract" f.pname;
        let xs = match x with C.List l -> Array.init (C.length l) (C.item ctx l) | x -> [| x |] in
        Array.iter (fun x -> ops := Resolve.Add (thing, r.ids.(i), of_cesia f.pname f.typ x) :: !ops) xs
      | x -> ops := Resolve.Add (thing, r.ids.(i), of_cesia f.pname f.typ x) :: !ops)
    k.fields;
  (* a field the kind does not have is a mistake of the program, said rather than dropped *)
  Array.iter
    (fun n -> if not (Array.exists (fun f -> f.fname = n) k.fields) then refuse "invalid" "the kind %s has no field %s" k.kname n)
    (C.names m);
  List.rev !ops

let insert ctx a =
  let name = "cepheus.Insert" in
  try
    let d = db_of ctx name a.(0) in
    let k = kind_of ctx name a.(1) in
    let ops = field_ops ctx name d k (-1) a.(2) ~update:false in
    if ops = [] then refuse "invalid" "Insert needs at least one field of %s" k.kname;
    let _, things = commit ctx d ~by:(int ctx name a.(3)) ~why:(text ctx name a.(4)) ops in
    C.ok ctx (Int (List.assoc (-1) things))
  with Refused (code, m) -> failure ctx code m

let update ctx a =
  let name = "cepheus.Update" in
  try
    let d = db_of ctx name a.(0) in
    let k = kind_of ctx name a.(1) in
    let thing = int ctx name a.(2) in
    if thing <= 0 then refuse "invalid" "Update needs the id of a thing, not %d" thing;
    let ops = field_ops ctx name d k thing a.(3) ~update:true in
    if ops = [] then refuse "invalid" "Update needs at least one field of %s" k.kname;
    let group, _ = commit ctx d ~by:(int ctx name a.(4)) ~why:(text ctx name a.(5)) ops in
    C.ok ctx (Int group)
  with Refused (code, m) -> failure ctx code m

let op_keys = C.keys [| "Op"; "Thing"; "Property"; "Value" |]

let write ctx a =
  let name = "cepheus.Write" in
  try
    let d = db_of ctx name a.(0) in
    let op v =
      match C.fields op_keys (map_of ctx name v) with
      | [| Text o; thing; prop; x |] -> (
        let thing = int ctx name thing in
        let k, i = property_of ctx name prop in
        let f = k.fields.(i) in
        let p = (resolve_kind d k).ids.(i) in
        match o with
        | "add" -> Resolve.Add (thing, p, of_cesia f.pname f.typ x)
        | "retract" -> Resolve.Retract (thing, p, of_cesia f.pname f.typ x)
        | "expect" -> Resolve.Expect (thing, p, if x = C.Missing then None else Some (of_cesia f.pname f.typ x))
        | _ -> C.need ctx name "an operation, as cepheus.Add, Retract or Expect makes it" v)
      | _ -> C.need ctx name "an operation, as cepheus.Add, Retract or Expect makes it" v
    in
    let ops = Array.to_list (Array.map op (list_of ctx name a.(1))) in
    if ops = [] then refuse "invalid" "a group needs at least one operation";
    let group, things = commit ctx d ~by:(int ctx name a.(2)) ~why:(text ctx name a.(3)) ops in
    let things = List.sort compare (List.map (fun (t, e) -> -t, e) things) in
    C.ok ctx (C.record ctx receipt_keys [| Int group; C.list ctx (Array.of_list (List.map (fun (_, e) -> C.Int e) things)) |])
  with Refused (code, m) -> failure ctx code m

(* ---- Find: a question as data, its variables the handles "cepheus.variable" ---- *)

let variables ctx a =
  let n = int ctx "cepheus.Find" a.(0) in
  C.list ctx (Array.init n (fun k -> C.Handle ("cepheus.variable", k)))

let question_keys = C.keys [| "Where"; "Give" |]
let range_keys = C.keys [| "Range"; "Low"; "High"; "Open" |]
let aggregate_keys = C.keys [| "Sum"; "Min"; "Max"; "Count" |]

type column = Var of int | Agg of Wire.agg

let find ctx a =
  let name = "cepheus.Find" in
  try
    let d = db_of ctx name a.(0) in
    let nvars = int ctx name a.(2) in
    let q = map_of ctx name a.(1) in
    let where, give =
      match C.fields question_keys q with
      | [| C.List w; C.Map g |] | [| C.List w; C.Struct g |] -> Array.init (C.length w) (C.item ctx w), g
      | _ -> C.need ctx name "a question {Where: [patterns], Give: {Name: variable}}" a.(1)
    in
    let var = function C.Handle ("cepheus.variable", k) when k < nvars -> Some k | _ -> None in
    let vtyp = Array.make nvars None in
    let patterns = ref [] and ranges = ref [] in
    (* patterns first: they give the variables their types, which ranges need *)
    let filters = ref [] in
    Array.iter
      (fun item ->
        match item with
        | C.List l when C.length l = 3 ->
          let e = C.item ctx l 0 and p = C.item ctx l 1 and x = C.item ctx l 2 in
          let k, i = property_of ctx name p in
          let f = k.fields.(i) in
          let pid = (resolve_kind d k).ids.(i) in
          let e = match var e, e with Some j, _ -> vtyp.(j) <- Some Value.Tlink; Query.Var j | None, C.Int t -> Query.Thing t | _ -> C.need ctx name "a variable or a thing's id first in a pattern" e in
          let x = match var x with Some j -> vtyp.(j) <- Some f.typ; Query.Var j | None -> Query.Val (of_cesia f.pname f.typ x) in
          patterns := { Query.e; p = pid; v = x } :: !patterns
        | C.Map m -> filters := m :: !filters
        | v -> C.need ctx name "a pattern [thing, property, value], or Above, Below or Between" v)
      where;
    List.iter
      (fun m ->
        match C.fields range_keys m with
        | [| x; lo; hi; strict |] -> (
          match var x with
          | Some j -> (
            match vtyp.(j) with
            | Some ((Tint | Tdate | Tmoney _) as t) ->
              let word v = match of_cesia "a range" t v with Int i | Date i | Money i -> i | _ -> 0 in
              (* Above and Below are strict: one minor unit (a millisecond, a cent) past the bound, on whole words *)
              let lo = if lo = C.Missing then min_int else word lo + (if strict = C.Text "low" then 1 else 0) in
              let hi = if hi = C.Missing then max_int else word hi - (if strict = C.Text "high" then 1 else 0) in
              let mk w = match t with Tdate -> Value.Date w | Tmoney _ -> Money w | _ -> Int w in
              ranges := (j, mk lo, mk hi) :: !ranges
            | Some t -> refuse "invalid" "Above, Below and Between are for ints, dates and money, not a %s" (Value.typ_name t)
            | None -> refuse "invalid" "a variable of Above, Below or Between appears in no pattern")
          | None -> C.need ctx name "a variable first in Above, Below or Between" x)
        | _ -> ())
      !filters;
    let names = C.names give and gvals = C.values give in
    let cols =
      Array.map
        (fun g ->
          match var g with
          | Some j -> Var j
          | None -> (
            match g with
            | C.Map m | C.Struct m -> (
              match C.fields aggregate_keys m with
              | [| s; C.Missing; C.Missing; C.Missing |] when var s <> None -> Agg (Wire.Sum (Option.get (var s)))
              | [| C.Missing; s; C.Missing; C.Missing |] when var s <> None -> Agg (Wire.Min (Option.get (var s)))
              | [| C.Missing; C.Missing; s; C.Missing |] when var s <> None -> Agg (Wire.Max (Option.get (var s)))
              | [| C.Missing; C.Missing; C.Missing; C.Bool true |] -> Agg Wire.Count
              | _ -> C.need ctx name "a variable, or Sum, Min, Max or Count" g)
            | _ -> C.need ctx name "a variable, or Sum, Min, Max or Count" g))
        gvals
    in
    let query = { Query.vars = nvars; where = List.rev !patterns; ranges = !ranges } in
    let keys_v = List.filter_map (function Var j -> Some j | Agg _ -> None) (Array.to_list cols) in
    let aggs = List.filter_map (function Agg g -> Some g | Var _ -> None) (Array.to_list cols) in
    let select = if aggs = [] then Wire.Give (Array.of_list keys_v) else Wire.Group (Array.of_list keys_v, Array.of_list aggs) in
    (* the column of the answer for each field of Give: keys first, then aggregates, in their order *)
    let nk = List.length keys_v in
    let at = Array.make (Array.length cols) 0 in
    let ki = ref 0 and ai = ref 0 in
    Array.iteri (fun i c -> match c with Var _ -> at.(i) <- !ki; incr ki | Agg _ -> at.(i) <- nk + !ai; incr ai) cols;
    let ctyp i = match cols.(i) with Var j | Agg (Wire.Sum j | Wire.Min j | Wire.Max j) -> (match vtyp.(j) with Some t -> t | None -> Value.Tint) | Agg Wire.Count -> Value.Tint in
    let typs = Array.init (Array.length cols) ctyp in
    let keys = C.keys names in
    let rows =
      match local_state d with
      | Some v -> (
        match Answer.answer v query select with
        | ans -> Array.init ans.n (fun r -> C.record ctx keys (Array.init (Array.length cols) (fun i -> of_word v typs.(i) (ans.word r at.(i)))))
        | exception Query.Bad m -> refuse "invalid" "%s" m
        | exception Pages.Unreadable m -> refuse "damaged" "%s" m)
      | None -> (
        match d.src with
        | Fork _ -> assert false
        | Server s -> (
          match Conn.read (park ctx) s.conn (Wire.Find { db = s.cdb.handle; query; select }) with
          | Wire.Rows rw ->
            Array.of_list (List.map (fun row -> C.record ctx keys (Array.init (Array.length cols) (fun i -> to_cesia typs.(i) row.(at.(i))))) rw.rows)
          | rep -> server_error rep "Find"))
    in
    C.pay ctx (Array.length rows);
    C.ok ctx (C.list ctx rows)
  with Refused (code, m) -> failure ctx code m

(* ---- forks and Close ---- *)

let fork ctx a =
  let name = "cepheus.Fork" in
  try
    let from =
      match a.(0) with
      | C.Text "cepheus.Empty" -> Store.fork Resolve.empty
      | v -> (
        let d = db_of ctx name v in
        match local_state d with
        | Some s -> Store.fork s
        | None -> refuse "invalid" "a fork starts from Empty, another fork, or a database read on the server's machine; this one is read at the server")
    in
    let ks = Array.map (kind_of ctx name) (list_of ctx name a.(1)) in
    let props = List.concat_map props_of (Array.to_list ks) in
    let v =
      match Resolve.declare from props with
      | Error m -> refuse "invalid" "%s" m
      | Ok (_, []) -> from
      | Ok (_, ops) -> (
        match Resolve.resolve from ~n:(from.group + 1) ~time:(Disk.real.now ()) ~by:0 ~why:"cepheus: declare" ops with
        | Ok (v, _, _) -> v
        | Error e -> let code, m = resolve_code e in refuse code "%s" m)
    in
    C.ok ctx (new_handle (Fork { fv = v }))
  with Refused (code, m) -> failure ctx code m

let close ctx a =
  match a.(0) with
  | C.Handle ("cepheus.database", i) -> (
    match entry dbs i with
    | Some d ->
      dbs.items.(i) <- None;
      (match d.src with Server s -> Conn.close s.conn | Fork _ -> ());
      C.Missing
    | None -> C.Missing)
  | v -> C.need ctx "cepheus.Close" "a database" v

let () =
  C.register
    [ "kind", 2, 2, kind; "connect", 4, 4, connect; "get", 3, 3, get; "insert", 5, 5, insert; "update", 6, 6, update;
      "write", 4, 4, write; "variables", 1, 1, variables; "find", 3, 3, find; "fork", 2, 2, fork; "close", 1, 1, close ]
