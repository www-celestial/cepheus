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

(* the library's module of OWL 2 RL itself (its vocabulary, its rules), not Cepheus.Owl, whose setup is the
   engine's and would link its threads into the client *)
module Owl = Cepheus__Owl

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

let[@inline never] of_cesia (pname : string) (typ : Value.typ) (x : C.value) : Value.t =
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

(* A bound of Above, Below or Between, as a word of its property's type, rounded toward the inside of the range: the
   least word at or above a low bound (above it, for Above), the greatest at or below a high bound (below it, for
   Below). So a bound between two minor units (10.005 for cents, a fraction of a millisecond) keeps exactly the values
   inside it. A bound in floats, scaled to the unit, is the unit it is within 2^-50 of, relative: a decimal written to
   the unit, as 1.1 for cents, whose double times 100 is 110.00000000000001 (a double is within 2^-53 of its decimal,
   relative, and the product adds as much again), or a sum of a few. None: no word is inside (Above the largest Int,
   Below the least). *)
let range_bound (typ : Value.typ) (x : C.value) ~low ~strict =
  let whole w =
    if not strict then Some w
    else if low then (if w = max_int then None else Some (w + 1))
    else if w = min_int then None
    else Some (w - 1)
  in
  let scaled f u what =
    let p = f *. u in
    if not (Float.is_finite p && Float.abs p < 4.6e18) then refuse "invalid" "a range needs %s, not %s" what (describe x)
    else
      let r = Float.round p in
      if Float.abs (p -. r) <= Float.abs p *. 0x1p-50 then whole (Float.to_int r)
      else Some (Float.to_int (if low then Float.ceil p else Float.floor p))
  in
  match typ, x with
  | Tdate, Float f -> scaled f 1000. "a date in seconds since 1970"
  | Tmoney sc, Float f -> scaled f (float_of_int pow10.(sc)) "an amount that fits"
  | _ -> (match of_cesia "a range" typ x with Int w | Date w | Money w -> whole w | _ -> Some 0)

(* ---- databases: a connection's, or a fork ---- *)

type resolved = { ids : int array; typs : Value.typ array; slot : int array (* property id -> field, or -1 *) }

type source =
  | Server of { conn : Conn.t; mutable cdb : Client.db; dbname : string }
  | Fork of { mutable fv : Store.view; mutable fhub : Live.hub option (* its watches, made at the first *) }

type db = { src : source; mutable resolved : resolved option array (* by kind *) }

(* closed ones are None: their numbers are never given again *)
let dbs : db table = table ()

let new_handle src = C.Handle ("cepheus.database", add dbs { src; resolved = [||] })

(* a fork's watches: each of its writes is a frame, durable at once (a fork has no disk) *)
let fork_hub = function
  | Fork f -> (match f.fhub with Some h -> h | None -> let h = Live.create f.fv ~tag:f.fv.group ~durable:f.fv.group in f.fhub <- Some h; h)
  | Server _ -> invalid_arg "fork_hub"

(* handles are never given twice: one no longer in the table was closed *)
let db_of ctx name = function
  | C.Handle ("cepheus.database", i) -> (
    match entry dbs i with Some d -> d | None -> refuse "closed" "this database was closed")
  | v -> C.need ctx name "a database, as cepheus.Connect or Fork gives it" v

(* a property of the database by its name: its id and type *)
let declared d pname =
  match d.src with
  | Server s -> List.find_map (fun (p, (x : Schema.prop)) -> if x.name = pname then Some (p, x) else None) s.cdb.props
  | Fork f -> (
    match Schema.by_name f.fv.schema pname with
    | Some p -> Option.map (fun (x : Schema.prop) -> p, x) (Schema.find f.fv.schema p)
    | None -> None)

let lookup d pname = match declared d pname with Some (p, (x : Schema.prop)) -> Some (p, x.typ) | None -> None

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

(* a value of a property in database [d]: where a link goes, a property of a kind is its id there, so that OWL's axioms
   name properties ([d, owl/Property, Person.Advisor]) *)
let[@inline never] value_in d pname (typ : Value.typ) (x : C.value) : Value.t =
  match typ, x with
  | Tlink, C.Handle ("cepheus.property", p) -> (
    match entry properties p with Some (k, i) -> Link (resolve_kind d k).ids.(i) | None -> of_cesia pname typ x)
  | _ -> of_cesia pname typ x

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

(* a thing read as its class's representative, as Cepheus.get reads it (the facts of things the rules made the same are
   kept on one of them): the server's Get does the same *)
let get_thing ctx d (k : kind) thing =
  let r = resolve_kind d k in
  let slot = r.slot and typs = r.typs in
  let ns = Array.length slot in
  match local_state d with
  | Some v -> (
    try
      record_of ctx k (fun f ->
          Store.iter_facts v (Query.rep v thing) (fun p w ->
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
    | Ok (v', g, temps) ->
      f.fv <- v';
      Option.iter (fun h -> Live.frame h ~tag:v'.group [ g ] v'; Live.durable h v'.group) f.fhub;
      v'.group, temps
    | Error e -> let code, m = resolve_code e in refuse code "%s" m)
  | Server s -> (
    if s.conn.cl.spoken < 4 && Client.has_incr ops then refuse "invalid" "%s" Client.no_incr;
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
        Array.iter (fun x -> ops := Resolve.Add (thing, r.ids.(i), value_in d f.pname f.typ x) :: !ops) xs
      | x -> ops := Resolve.Add (thing, r.ids.(i), value_in d f.pname f.typ x) :: !ops)
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

let op_keys = C.keys [| "Op"; "Thing"; "Property"; "Value"; "Into" |]

let write ctx a =
  let name = "cepheus.Write" in
  try
    let d = db_of ctx name a.(0) in
    let what = "an operation, as cepheus.Add, Retract, Expect or Incr makes it" in
    let op v =
      match C.fields op_keys (map_of ctx name v) with
      | [| Text o; thing; prop; x; into |] -> (
        let thing = int ctx name thing in
        let k, i = property_of ctx name prop in
        let f = k.fields.(i) in
        let p = (resolve_kind d k).ids.(i) in
        match o with
        | "add" -> Resolve.Add (thing, p, value_in d f.pname f.typ x)
        | "retract" -> Resolve.Retract (thing, p, value_in d f.pname f.typ x)
        | "expect" -> Resolve.Expect (thing, p, if x = C.Missing then None else Some (value_in d f.pname f.typ x))
        | "incr" ->
          (* into: [thing, property], or missing *)
          let into =
            match into with
            | C.Missing -> None
            | C.List l when C.length l = 2 ->
              let t = int ctx name (C.item ctx l 0) in
              let k', i' = property_of ctx name (C.item ctx l 1) in
              Some (t, (resolve_kind d k').ids.(i'))
            | v -> C.need ctx name "Incr's into: [thing, property], as [cepheus.New(1), Invoice.Number]" v
          in
          Resolve.Incr (thing, p, int ctx name x, into)
        | _ -> C.need ctx name what v)
      | _ -> C.need ctx name what v
    in
    let ops = Array.to_list (Array.map op (list_of ctx name a.(1))) in
    if ops = [] then refuse "invalid" "a group needs at least one operation";
    let group, things = commit ctx d ~by:(int ctx name a.(2)) ~why:(text ctx name a.(3)) ops in
    let things = List.sort compare (List.map (fun (t, e) -> -t, e) things) in
    C.ok ctx (C.record ctx receipt_keys [| Int group; C.list ctx (Array.of_list (List.map (fun (_, e) -> C.Int e) things)) |])
  with Refused (code, m) -> failure ctx code m

(* ---- files: a file kind's things, their bytes in the server's vault ---- *)

let file_fields = [ "Name", Value.Ttext; "Size", Value.Tint; "Type", Value.Ttext; "Owner", Value.Tlink; "Content", Value.Ttext ]

(* the field of this name of a file kind (cepheus.Files made it): its index *)
let file_field ctx name (k : kind) f =
  let ok = List.for_all (fun (n, t) -> Array.exists (fun (x : field) -> x.fname = n && x.typ = t && not x.many) k.fields) file_fields in
  if not ok then C.panic ctx (Printf.sprintf "%s: %s is not a kind of files: make it with cepheus.Files(%S)" name k.kname k.kname);
  let rec find i = if k.fields.(i).fname = f then i else find (i + 1) in
  find 0

let server_of name d = match d.src with Server s -> s.conn, s.cdb | Fork _ -> refuse "invalid" "%s: a fork holds no file: files are kept in a server's vault" name

let put ctx a =
  let name = "cepheus.Put" in
  try
    let d = db_of ctx name a.(0) in
    let k = kind_of ctx name a.(1) in
    ignore (file_field ctx name k "Content");
    let fname = text ctx name a.(2) and data = text ctx name a.(3) and typ = text ctx name a.(4) in
    let owner = match a.(5) with C.Missing -> 0 | x -> int ctx name x in
    let cold = bool ctx name a.(6) and by = int ctx name a.(7) and why = text ctx name a.(8) in
    if owner < 0 then refuse "invalid" "an owner is the id of a thing, not %d" owner;
    let conn, cdb = server_of name d in
    ignore (resolve_kind d k);
    match Conn.put (park ctx) conn ~db:cdb.handle ~kind:k.kname ~name:fname ~typ ~owner ~cold ~by ~why data with
    | Wire.Receipt r -> C.ok ctx (Int (List.assoc (-1) r.things))
    | rep -> server_error rep "Put"
  with Refused (code, m) -> failure ctx code m

let read ctx a =
  let name = "cepheus.Read" in
  try
    let d = db_of ctx name a.(0) in
    let k = kind_of ctx name a.(1) in
    let content = file_field ctx name k "Content" in
    let thing = int ctx name a.(2) and from = int ctx name a.(3) in
    let len = match a.(4) with C.Missing -> -1 | x -> int ctx name x in
    if thing <= 0 then refuse "invalid" "Read needs the id of a thing, not %d" thing;
    if from < 0 || len < -1 then refuse "invalid" "a range of a file starts at 0 or after and has a length of 0 or more";
    let conn, cdb = server_of name d in
    let prop = (resolve_kind d k).ids.(content) in
    match Conn.read (park ctx) conn (Wire.Load { db = cdb.handle; thing; prop; from; len }) with
    | Wire.Data b -> C.ok ctx (Text b)
    | rep -> server_error rep "Read"
  with Refused (code, m) -> failure ctx code m

(* a file's facts retracted, its Content expected unchanged: its bytes stay where the history cites them *)
let delete ctx a =
  let name = "cepheus.Delete" in
  try
    let d = db_of ctx name a.(0) in
    let k = kind_of ctx name a.(1) in
    let content = file_field ctx name k "Content" in
    let thing = int ctx name a.(2) in
    if thing <= 0 then refuse "invalid" "Delete needs the id of a thing, not %d" thing;
    let conn, cdb = server_of name d in
    let r = resolve_kind d k in
    match Conn.read (park ctx) conn (Wire.Get { db = cdb.handle; thing }) with
    | Wire.Facts fs -> (
      let mine = List.filter (fun (p, _) -> Array.mem p r.ids) fs.facts in
      match List.assoc_opt r.ids.(content) mine with
      | None -> refuse "missing" "thing %d is not a file of the kind %s" thing k.kname
      | Some c ->
        let ops = Resolve.Expect (thing, r.ids.(content), Some c) :: List.map (fun (p, x) -> Resolve.Retract (thing, p, x)) mine in
        let group, _ = commit ctx d ~by:(int ctx name a.(3)) ~why:(text ctx name a.(4)) ops in
        C.ok ctx (Int group))
    | rep -> server_error rep "Delete"
  with Refused (code, m) -> failure ctx code m

let erase ctx a =
  let name = "cepheus.Erase" in
  try
    let d = db_of ctx name a.(0) in
    let owner = int ctx name a.(1) in
    if owner <= 0 then refuse "invalid" "Erase needs an owner, the id of a thing, not %d: the database's own key is never erased" owner;
    let conn, cdb = server_of name d in
    match Conn.call (park ctx) conn (Wire.Erase { db = cdb.handle; owner }) with
    | Wire.Erased -> C.ok ctx C.Missing
    | rep -> server_error rep "Erase"
  with Refused (code, m) -> failure ctx code m

(* ---- Find: a question as data, its variables the handles "cepheus.variable" ---- *)

let variables ctx a =
  let n = int ctx "cepheus.Find" a.(0) in
  C.list ctx (Array.init n (fun k -> C.Handle ("cepheus.variable", k)))

let question_keys = C.keys [| "Where"; "Give"; "Sort"; "Limit"; "After" |]
let desc_keys = C.keys [| "Desc" |]
let op_keys = C.keys [| "Not"; "Or"; "And"; "In"; "Values"; "Prefix"; "Text" |]
let range_keys = C.keys [| "Range"; "Low"; "High"; "Open" |]
let aggregate_keys = C.keys [| "Sum"; "Min"; "Max"; "Count" |]

type column = Var of int | Agg of Wire.agg

(* a question as the program gives it: its patterns and ranges, its select, and for each field of Give its name, its
   column in the answer and its type *)
type question = {
  query : Query.t;
  extra : Question.Ask.item list;  (* Not, Or and In *)
  select : Wire.select;
  qkeys : C.keys;
  at : int array;
  typs : Value.typ array;
  order : Question.Top.order;
  ren : int array;  (* each variable's number in [query], -1 when left out (in no item) *)
}

let question ?(uses = []) ctx name d qv nvars =
    let q = map_of ctx name qv in
    let where, give, sort, limit, after =
      match C.fields question_keys q with
      | [| C.List w; (C.Map g | C.Struct g); sort; limit; after |] -> Array.init (C.length w) (C.item ctx w), g, sort, limit, after
      | _ -> C.need ctx name "a question {Where: [patterns], Give: {Name: variable}}" qv
    in
    let var = function C.Handle ("cepheus.variable", k) when k < nvars -> Some k | _ -> None in
    let vtyp = Array.make nvars None in
    let what = "a pattern [thing, property, value], or Above, Below, Between, In, Not or Or" in
    let pattern_of l =
      let e = C.item ctx l 0 and p = C.item ctx l 1 and x = C.item ctx l 2 in
      let k, i = property_of ctx name p in
      let f = k.fields.(i) in
      let pid = (resolve_kind d k).ids.(i) in
      let e = match var e, e with Some j, _ -> vtyp.(j) <- Some Value.Tlink; Query.Var j | None, C.Int t -> Query.Thing t | _ -> C.need ctx name "a variable or a thing's id first in a pattern" e in
      let x = match var x with Some j -> vtyp.(j) <- Some f.typ; Query.Var j | None -> Query.Val (value_in d f.pname f.typ x) in
      { Query.e; p = pid; v = x }
    in
    (* a list's items; Not, Or and And give their four arguments, those left out missing *)
    let list_of v = match v with C.List l -> List.filter (fun x -> x <> C.Missing) (List.init (C.length l) (C.item ctx l)) | C.Missing -> [] | v -> C.need ctx name "a list" v in
    (* patterns first, nested ones too: they give the variables their types, which ranges and In need *)
    let rec walk item =
      match item with
      | C.List l when C.length l = 3 -> ignore (pattern_of l)
      | C.Map m | C.Struct m -> (
        match C.fields op_keys m with
        | [| n; o; a; _; _; _; _ |] -> List.iter walk (list_of n @ list_of a); List.iter walk (list_of o)
        | _ -> ())
      | _ -> ()
    in
    Array.iter walk where;
    let range_of m =
      match C.fields range_keys m with
      | [| x; lo; hi; strict |] -> (
        match var x with
        | Some j -> (
          match vtyp.(j) with
          | Some ((Tint | Tdate | Tmoney _) as t) ->
            (* Above and Below are strict; each bound rounded toward the inside of the range; no word inside, an empty
               range *)
            let lo = if lo = C.Missing then Some min_int else range_bound t lo ~low:true ~strict:(strict = C.Text "low") in
            let hi = if hi = C.Missing then Some max_int else range_bound t hi ~low:false ~strict:(strict = C.Text "high") in
            let lo, hi = match lo, hi with Some lo, Some hi -> lo, hi | _ -> 1, 0 in
            let mk w = match t with Tdate -> Value.Date w | Tmoney _ -> Money w | _ -> Int w in
            j, mk lo, mk hi
          | Some t -> refuse "invalid" "Above, Below and Between are for ints, dates and money, not a %s" (Value.typ_name t)
          | None -> refuse "invalid" "a variable of Above, Below or Between appears in no pattern")
        | None -> C.need ctx name "a variable first in Above, Below or Between" x)
      | _ -> C.need ctx name what (C.Map m)
    in
    (* an item: [top] at the top of Where; [alt] an alternative of Or, which And may write *)
    let rec item_of ~top ~alt it : Question.Ask.item list =
      match it with
      | C.List l when C.length l = 3 -> [ Question.Ask.Pattern (pattern_of l) ]
      | C.Map m | C.Struct m -> (
        match C.fields op_keys m with
        | [| C.Missing; C.Missing; C.Missing; C.Missing; C.Missing; C.Missing; C.Missing |] -> let j, lo, hi = range_of m in [ Question.Ask.Range (j, lo, hi) ]
        | [| C.Missing; C.Missing; C.Missing; C.Missing; C.Missing; x; t |] -> (
          match var x, t with
          | Some j, C.Text p -> [ Question.Ask.Prefix (j, p) ]
          | Some _, v -> C.need ctx name "a text for Prefix" v
          | None, _ -> C.need ctx name "a variable first in Prefix" x)
        | [| n; C.Missing; C.Missing; C.Missing; C.Missing; C.Missing; C.Missing |] ->
          if not top then refuse "invalid" "Not takes patterns and conditions: no Not or Or inside it";
          [ Question.Ask.Not (List.concat_map (item_of ~top:false ~alt:false) (list_of n)) ]
        | [| C.Missing; o; C.Missing; C.Missing; C.Missing; C.Missing; C.Missing |] ->
          if not top then refuse "invalid" "Or takes patterns, conditions and And: no Not or Or inside it";
          [ Question.Ask.Or (List.map (fun a -> item_of ~top:false ~alt:true a) (list_of o)) ]
        | [| C.Missing; C.Missing; a; C.Missing; C.Missing; C.Missing; C.Missing |] ->
          if not alt then refuse "invalid" "And is for an alternative of Or: Where is already all of its items";
          List.concat_map (item_of ~top:false ~alt:false) (list_of a)
        | [| C.Missing; C.Missing; C.Missing; x; vs; C.Missing; C.Missing |] -> (
          match var x with
          | Some j -> (
            match vtyp.(j) with
            | Some t -> [ Question.Ask.In (j, List.map (value_in d "In" t) (list_of vs)) ]
            | None -> refuse "invalid" "a variable of In appears in no pattern")
          | None -> C.need ctx name "a variable first in In" x)
        | _ -> C.need ctx name what it)
      | v -> C.need ctx name what v
    in
    let patterns = ref [] and ranges = ref [] and extra = ref [] in
    Array.iter
      (fun it ->
        List.iter
          (function
            | Question.Ask.Pattern p -> patterns := p :: !patterns
            | Range (j, lo, hi) -> ranges := (j, lo, hi) :: !ranges
            | x -> extra := x :: !extra)
          (item_of ~top:true ~alt:false it))
      where;
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
    (* a variable in no item of Where, of Give, or of [uses] (a rule's Then), as an optional filter left out, is left
       out: the others numbered again in their order; with every variable used, the question as it is *)
    Array.iteri
      (fun i c -> match c with
        | (Var j | Agg (Wire.Sum j | Wire.Min j | Wire.Max j)) when vtyp.(j) = None -> refuse "invalid" "Give's %s is a variable in no pattern of Where" names.(i)
        | _ -> ())
      cols;
    let used = Array.make nvars false in
    let use j = if j >= 0 && j < nvars then used.(j) <- true in
    let use_t = function Query.Var j -> use j | _ -> () in
    let rec use_item = function
      | Question.Ask.Pattern (q : Query.pattern) -> use_t q.e; use_t q.v
      | Range (j, _, _) | In (j, _) | Prefix (j, _) -> use j
      | Not l -> List.iter use_item l
      | Or alts -> List.iter (List.iter use_item) alts
    in
    List.iter (fun (q : Query.pattern) -> use_t q.e; use_t q.v) !patterns;
    List.iter (fun (j, _, _) -> use j) !ranges;
    List.iter use_item !extra;
    Array.iter (function Var j | Agg (Wire.Sum j | Wire.Min j | Wire.Max j) -> use j | Agg Wire.Count -> ()) cols;
    let rec use_v v = match var v with Some j -> use j | None -> (match v with C.List l -> for i = 0 to C.length l - 1 do use_v (C.item ctx l i) done | C.Map m | C.Struct m -> Array.iter use_v (C.values m) | _ -> ()) in
    List.iter use_v uses;
    let ren = Array.make nvars (-1) in
    let nv = ref 0 in
    Array.iteri (fun j u -> if u then (ren.(j) <- !nv; incr nv)) used;
    let nvars', patterns, ranges, extra, wcols =
      if !nv = nvars then nvars, List.rev !patterns, !ranges, List.rev !extra, cols
      else begin
        let r j = ren.(j) in
        let rt = function Query.Var j -> Query.Var (r j) | t -> t in
        let rp (q : Query.pattern) = { q with e = rt q.e; v = rt q.v } in
        let rec ri = function
          | Question.Ask.Pattern q -> Question.Ask.Pattern (rp q)
          | Range (j, lo, hi) -> Range (r j, lo, hi)
          | In (j, l) -> In (r j, l)
          | Prefix (j, p) -> Prefix (r j, p)
          | Not l -> Not (List.map ri l)
          | Or alts -> Or (List.map (List.map ri) alts)
        in
        let rc = function Var j -> Var (r j) | Agg (Wire.Sum j) -> Agg (Wire.Sum (r j)) | Agg (Wire.Min j) -> Agg (Wire.Min (r j)) | Agg (Wire.Max j) -> Agg (Wire.Max (r j)) | Agg Wire.Count -> Agg Wire.Count in
        !nv, List.rev_map rp !patterns, List.map (fun (j, lo, hi) -> r j, lo, hi) !ranges, List.rev_map ri !extra, Array.map rc cols
      end
    in
    let query = { Query.vars = nvars'; where = patterns; ranges } in
    let keys_v = List.filter_map (function Var j -> Some j | Agg _ -> None) (Array.to_list wcols) in
    let aggs = List.filter_map (function Agg g -> Some g | Var _ -> None) (Array.to_list wcols) in
    let select = if aggs = [] then Wire.Give (Array.of_list keys_v) else Wire.Group (Array.of_list keys_v, Array.of_list aggs) in
    (* the column of the answer for each field of Give: keys first, then aggregates, in their order *)
    let nk = List.length keys_v in
    let at = Array.make (Array.length cols) 0 in
    let ki = ref 0 and ai = ref 0 in
    Array.iteri (fun i c -> match c with Var _ -> at.(i) <- !ki; incr ki | Agg _ -> at.(i) <- nk + !ai; incr ai) cols;
    let ctyp i = match cols.(i) with Var j | Agg (Wire.Sum j | Wire.Min j | Wire.Max j) -> (match vtyp.(j) with Some t -> t | None -> Value.Tint) | Agg Wire.Count -> Value.Tint in
    let typs = Array.init (Array.length cols) ctyp in
    (* Sort: each key a field of Give (its variable or its aggregate), Desc for descending; then every other field by
       name, so that rows equal in the order are the same row. After: a row with every field of Give. *)
    let field_of k =
      let col_of g = match var g with Some j -> Some (Var j) | None -> (match g with C.Map m | C.Struct m -> (match C.fields aggregate_keys m with
          | [| s; C.Missing; C.Missing; C.Missing |] when var s <> None -> Some (Agg (Wire.Sum (Option.get (var s))))
          | [| C.Missing; s; C.Missing; C.Missing |] when var s <> None -> Some (Agg (Wire.Min (Option.get (var s))))
          | [| C.Missing; C.Missing; s; C.Missing |] when var s <> None -> Some (Agg (Wire.Max (Option.get (var s))))
          | [| C.Missing; C.Missing; C.Missing; C.Bool true |] -> Some (Agg Wire.Count)
          | _ -> None) | _ -> None) in
      let desc, g = match k with (C.Map m | C.Struct m) when (match C.fields desc_keys m with [| C.Missing |] -> false | _ -> true) -> true, (C.fields desc_keys m).(0) | _ -> false, k in
      match col_of g with
      | Some c -> (match List.find_opt (fun i -> cols.(i) = c) (List.init (Array.length cols) Fun.id) with
          | Some i -> i, desc
          | None -> refuse "invalid" "Sort's keys are fields of Give: a variable or an aggregate that Give gives")
      | None -> C.need ctx name "a key of Sort: a variable or an aggregate of Give, or Desc of one" k
    in
    let order =
      if sort = C.Missing && limit = C.Missing && after = C.Missing then Question.Top.none
      else begin
        (* a question that uses the newer keys is newer code: a key the package does not know is a mistake there (a
           misspelt After would give the first page for ever), and no question that worked before is refused *)
        Array.iter
          (fun k -> if not (List.mem k [ "Where"; "Give"; "Sort"; "Limit"; "After" ]) then refuse "invalid" "a question has no key %s: Where, Give, Sort, Limit and After" k)
          (C.names q);
        let user = match sort with C.Missing -> [] | C.List l -> List.init (C.length l) (fun i -> field_of (C.item ctx l i)) | v -> C.need ctx name "a list of keys for Sort" v in
        let keys =
          if user = [] then []
          else begin
            let rest = List.filter (fun i -> not (List.mem_assoc i user)) (List.init (Array.length cols) Fun.id) in
            let rest = List.sort (fun a b -> compare names.(a) names.(b)) rest in
            List.map (fun (i, desc) -> { Question.Top.col = at.(i); desc }) user @ List.map (fun i -> { Question.Top.col = at.(i); desc = false }) rest
          end
        in
        let limit = match limit with C.Missing -> 0 | C.Int k when k >= 1 -> k | v -> C.need ctx name "a Limit of 1 row or more" v in
        let after =
          match after with
          | C.Missing -> None
          | C.Map m | C.Struct m ->
            if user = [] then refuse "invalid" "After needs Sort: the rows after a row, in an order";
            let vals = C.fields (C.keys names) m in
            let a = Array.make (Array.length cols) (Value.Int 0) in
            Array.iteri (fun i x -> if x = C.Missing then refuse "invalid" "After needs every field of Give: %s is missing" names.(i); a.(at.(i)) <- of_cesia names.(i) typs.(i) x) vals;
            Some a
          | v -> C.need ctx name "a row of Give for After" v
        in
        { Question.Top.keys; limit; after }
      end
    in
    { query; extra; select; qkeys = C.keys names; at; typs; order; ren }

(* a row of the answer (values) as the program's map *)
let record_of_row ctx qn (row : Value.t array) = C.record ctx qn.qkeys (Array.init (Array.length qn.at) (fun i -> to_cesia qn.typs.(i) row.(qn.at.(i))))

let find ctx a =
  let name = "cepheus.Find" in
  try
    let d = db_of ctx name a.(0) in
    let nvars = int ctx name a.(2) in
    let qn = question ctx name d a.(1) nvars in
    let query = qn.query and select = qn.select and at = qn.at and typs = qn.typs and keys = qn.qkeys in
    let ncols = Array.length at in
    let rows =
      match local_state d with
      | Some v -> (
        match Answer.answer ~order:qn.order ~extra:qn.extra v query select with
        | ans -> Array.init ans.n (fun r -> C.record ctx keys (Array.init ncols (fun i -> of_word v typs.(i) (ans.word r at.(i)))))
        | exception Query.Bad m -> refuse "invalid" "%s" m
        | exception Pages.Unreadable m -> refuse "damaged" "%s" m)
      | None -> (
        match d.src with
        | Fork _ -> assert false
        | Server s when (qn.extra <> [] || qn.order <> Question.Top.none) && s.conn.cl.spoken < 2 -> refuse "invalid" "%s" Client.older
        | Server s -> (
          match Conn.read (park ctx) s.conn (Wire.Find { db = s.cdb.handle; query; select; extra = qn.extra; order = qn.order }) with
          | Wire.Rows rw -> Array.of_list (List.map (fun row -> record_of_row ctx qn row) rw.rows)
          | rep -> server_error rep "Find"))
    in
    C.pay ctx (Array.length rows);
    C.ok ctx (C.list ctx rows)
  with Refused (code, m) -> failure ctx code m

(* ---- Watch: a live question; its messages taken one at a time by the package's fiber (cepheus.ce) ---- *)

type watch = { c : Conn.consumer; wdb : db; qn : question }

let watches : watch table = table ()

(* every watch of the program, by its database and question: one source each *)
let shared : (string, Conn.shared) Hashtbl.t = Hashtbl.create 16

(* both messages have the four fields: an answer's Rows, a change's Added and Removed; the others missing *)
let message_keys = C.keys [| "Group"; "Rows"; "Added"; "Removed" |]

(* a new source for a watch: the local reader's hub, the fork's, or the server; from the group of its last message *)
let find_source d (sh : Conn.shared) =
  let from = if sh.started then sh.group else 0 in
  let local hub =
    match Live.subscribe ~extra:sh.extra ~order:sh.order hub sh.query sh.select ~from ~emit:(fun m -> Conn.deliver sh m; true) with
    | sub -> Mutex.protect sh.sm (fun () -> sh.src <- Local (hub, sub)); true
    | exception Query.Bad m -> Conn.finish sh "invalid" m; true
    | exception Query.Over_budget n -> Conn.finish sh "too_large" (Printf.sprintf "the question passed the budget of %d candidates" n); true
    | exception Pages.Unreadable m -> Conn.finish sh "damaged" m; true
    | exception Failure _ -> false
  in
  match d.src with
  | Fork _ -> local (fork_hub d.src)
  | Server s -> (
    match Client.local_hub s.conn.cl s.cdb with
    | Some hub when local hub -> true
    | _ when sh.extra <> [] && s.conn.cl.spoken < 2 -> Conn.finish sh "invalid" Client.older; true
    | _ when sh.order <> Question.Top.none && s.conn.cl.spoken < 5 -> Conn.finish sh "invalid" (Client.no_sorted_watch s.conn.cl.spoken); true
    | _ ->
      Mutex.protect sh.sm (fun () -> sh.src <- Remote);
      Conn.watch s.conn sh (Wire.Watch { db = s.cdb.handle; query = sh.query; select = sh.select; from; wextra = sh.extra; worder = sh.order }))

(* a watch's source stops: the server's watch, or the hub's *)
let stop_source d (sh : Conn.shared) =
  Hashtbl.remove shared sh.key;
  match Mutex.protect sh.sm (fun () -> let s = sh.src in sh.src <- Nothing; s) with
  | Local (hub, sub) -> Live.unsubscribe hub sub
  | Remote -> (match d.src with Server s -> Conn.unwatch s.conn sh | Fork _ -> ())
  | Nothing -> ()

let message ctx qn = function
  | Conn.M_answer (g, rows) ->
    C.pay ctx (List.length rows);
    C.ok ctx (C.record ctx message_keys [| Int g; C.list ctx (Array.of_list (List.map (record_of_row ctx qn) rows)); C.Missing; C.Missing |])
  | M_change (g, added, removed) ->
    C.pay ctx (List.length added + List.length removed);
    let l rows = C.list ctx (Array.of_list (List.map (record_of_row ctx qn) rows)) in
    C.ok ctx (C.record ctx message_keys [| Int g; C.Missing; l added; l removed |])
  | M_end (code, m) -> failure ctx code m

let watch ctx a =
  let name = "cepheus.Watch" in
  try
    let d = db_of ctx name a.(0) in
    let nvars = int ctx name a.(2) in
    let qn = question ctx name d a.(1) nvars in
    let b = Buffer.create 64 in
    Wire.put_query b qn.query;
    Wire.put_select b qn.select;
    if qn.extra <> [] || qn.order <> Question.Top.none then Wire.put_order b ~extra:qn.extra qn.order;
    let key = string_of_int (match a.(0) with C.Handle (_, i) -> i | _ -> -1) ^ ":" ^ Buffer.contents b in
    let sh =
      match Hashtbl.find_opt shared key with
      | Some sh when sh.ended = None -> sh
      | _ -> let sh = Conn.new_shared ~extra:qn.extra ~order:qn.order key qn.query qn.select in Hashtbl.replace shared key sh; sh
    in
    let c = Conn.join sh in
    (* the first message waited for here: the answer, or why there is none; it is given again by the first next *)
    match Conn.next (park ctx) (find_source d) c with
    | Conn.M_end (code, m) -> if Conn.leave c then stop_source d sh; refuse code "%s" m
    | first ->
      Conn.push_front c first;
      C.ok ctx (C.Handle ("cepheus.watch", add watches { c; wdb = d; qn }))
  with Refused (code, m) -> failure ctx code m

let watch_of ctx name = function
  | C.Handle ("cepheus.watch", i) as v -> (match entry watches i with Some w -> w | None -> C.need ctx name "a watch" v)
  | v -> C.need ctx name "a watch, as cepheus.Watch made it" v

let next ctx a =
  let w = watch_of ctx "cepheus.Watch" a.(0) in
  message ctx w.qn (Conn.next (park ctx) (find_source w.wdb) w.c)

let close_watch i =
  match entry watches i with
  | Some w ->
    watches.items.(i) <- None;
    if Conn.leave w.c then stop_source w.wdb w.c.sh
  | None -> ()

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
    C.ok ctx (new_handle (Fork { fv = v; fhub = None }))
  with Refused (code, m) -> failure ctx code m

(* ---- Define: rules, written as Cepheus.define writes them (a rule is a schema thing: its name and its text) ---- *)

let rule_keys = C.keys [| "Rule"; "Vars"; "Body" |]
let body_keys = C.keys [| "Where"; "Then" |]
let where_give = C.keys [| "Where"; "Give" |]

(* the schema's named things of a database: (id, name), and the rules' texts: (id, text); read where Find reads *)
let named ctx d =
  let rows p =
    let q = { Query.vars = 2; where = [ { Query.e = Var 0; p; v = Var 1 } ]; ranges = [] } in
    match local_state d with
    | Some v ->
      let a = Answer.answer v q (Wire.Give [| 0; 1 |]) in
      List.init a.n (fun r -> a.word r 0, Store.text v (a.word r 1))
    | None -> (
      match d.src with
      | Fork _ -> []
      | Server s -> (
        match Conn.read (park ctx) s.conn (Wire.Find { db = s.cdb.handle; query = q; select = Wire.Give [| 0; 1 |]; extra = []; order = Question.Top.none }) with
        | Wire.Rows rw -> List.filter_map (function [| Value.Link e; Value.Text t |] | [| Value.Int e; Value.Text t |] -> Some (e, t) | _ -> None) rw.rows
        | rep -> server_error rep "Define"))
  in
  rows Schema.p_name, rows Schema.p_rule

let rule_of ctx name d v =
  match C.fields rule_keys (map_of ctx name v) with
  | [| C.Text rname; C.Int n; body |] -> (
    match C.fields body_keys (map_of ctx name body) with
    | [| (C.List _ as w); head |] ->
      let qn = question ~uses:[ head ] ctx name d (C.record ctx where_give [| w; C.record ctx (C.keys [||]) [||] |]) n in
      (* a Not of Where is the rule's k-th Not: its patterns' properties [Rules.absent k p], its conditions the ranges
         of its own variables *)
      let nots = ref 0 and npats = ref [] and nranges = ref [] in
      List.iter
        (function
          | Question.Ask.Not items ->
            let k = !nots in
            incr nots;
            List.iter
              (function
                | Question.Ask.Pattern (q : Query.pattern) -> npats := { q with p = Rules.absent k q.p } :: !npats
                | Range (j, lo, hi) ->
                  (* a condition inside Not is on one of its own variables: on another, it would hold for the rule *)
                  if List.exists (fun (q : Query.pattern) -> q.e = Query.Var j || q.v = Query.Var j) qn.query.where then
                    refuse "invalid" "rule %s: a condition inside Not is on a variable of its own (in no pattern outside Not)" rname;
                  nranges := (j, lo, hi) :: !nranges
                | _ -> refuse "invalid" "rule %s: a Not of a rule holds patterns, Above, Below and Between" rname)
              items
          | _ -> refuse "invalid" "rule %s: a rule's Where holds patterns, Not, Above, Below and Between; Or, In and Prefix are for questions" rname)
        qn.extra;
      if !nots > Rules.max_nots then refuse "invalid" "rule %s: at most %d Nots" rname Rules.max_nots;
      let head =
        match head with
        | C.Text "cepheus.Never" -> Rules.Never
        | C.List l when C.length l = 3 ->
          let var = function C.Handle ("cepheus.variable", k) when k < n -> Some qn.ren.(k) | _ -> None in
          let e = C.item ctx l 0 and p = C.item ctx l 1 and x = C.item ctx l 2 in
          let k, i = property_of ctx name p in
          let f = k.fields.(i) in
          let e = match var e, e with Some j, _ -> Query.Var j | None, C.Int t -> Query.Thing t | _ -> C.need ctx name "a variable or a thing's id first in Then" e in
          let pid = (resolve_kind d k).ids.(i) in
          (* Sum, Min, Max of a variable, or Count: the head gives the property that aggregate of its answers *)
          let agg f = Some f in
          let a, v =
            match x with
            | C.Map m | C.Struct m -> (
              match C.fields aggregate_keys m with
              | [| s; C.Missing; C.Missing; C.Missing |] when var s <> None -> agg `Sum, Query.Var (Option.get (var s))
              | [| C.Missing; s; C.Missing; C.Missing |] when var s <> None -> agg `Min, Query.Var (Option.get (var s))
              | [| C.Missing; C.Missing; s; C.Missing |] when var s <> None -> agg `Max, Query.Var (Option.get (var s))
              | [| C.Missing; C.Missing; C.Missing; C.Bool true |] -> agg `Count, Query.Val (Value.Int 0)
              | _ -> C.need ctx name "a value of Then: a variable, a value, or Sum, Min, Max of a variable, or Count()" x)
            | _ -> None, (match var x with Some j -> Query.Var j | None -> Query.Val (value_in d f.pname f.typ x))
          in
          Rules.Give { Query.e; p = (match a with Some g -> Rules.aggregate g pid | None -> pid); v }
        | v -> C.need ctx name "Then: a pattern [thing, property, value], or cepheus.Never" v
      in
      { Rules.name = rname; vars = qn.query.vars; where = qn.query.where @ List.rev !npats; ranges = qn.query.ranges @ List.rev !nranges; head }
    | _ -> C.need ctx name "a rule {Where: [patterns], Then: pattern}" body)
  | _ -> C.need ctx name "a rule, as cepheus.Rule makes it" v

(* ---- a question of the package's own, whose answers are things: their ids, read where Find reads ---- *)

let ask_ids ctx d (q : Query.t) extra =
  let cols = Array.init q.vars Fun.id in
  match local_state d with
  | Some v -> (
    match Answer.answer ~extra v q (Wire.Give cols) with
    | a -> List.init a.n (fun r -> Array.map (fun c -> a.word r c) cols)
    | exception Pages.Unreadable m -> refuse "damaged" "%s" m)
  | None -> (
    match d.src with
    | Fork _ -> []
    | Server s -> (
      match Conn.read (park ctx) s.conn (Wire.Find { db = s.cdb.handle; query = q; select = Wire.Give cols; extra; order = Question.Top.none }) with
      | Wire.Rows rw -> List.map (Array.map (function Value.Link e | Value.Int e -> e | _ -> refuse "protocol" "an unexpected row")) rw.rows
      | rep -> server_error rep "a question"))

(* ---- Same: the class of a thing, the things the rules made the same as it (cepheus/same) ---- *)

let same_of ctx a =
  let name = "cepheus.Same" in
  try
    let d = db_of ctx name a.(0) in
    let x = int ctx name a.(1) in
    let ids =
      match local_state d with
      | Some v -> Query.same v x
      | None -> (
        (* at the server: the things whose cepheus/same is x's representative (a question reads a thing it names as
           its representative); then, when x is one of them, the representative, x's own cepheus/same: the question
           names x by a range of one link, which is read as written (a link of In or of a pattern would be read as
           the representative, which has none) *)
        let pat e v : Query.pattern = { e; p = Schema.p_same; v } in
        let one q = List.map (fun r -> r.(0)) (ask_ids ctx d q []) in
        match one { Query.vars = 1; where = [ pat (Var 0) (Thing x) ]; ranges = [] } with
        | [] -> [ x ]
        | members when not (List.mem x members) -> List.sort compare (x :: members)
        | members -> (
          match one { Query.vars = 2; where = [ pat (Var 1) (Var 0) ]; ranges = [ 1, Value.Link x, Value.Link x ] } with
          | [ r ] -> List.sort compare (r :: members)
          | _ -> refuse "conflict" "%s: the class of %d changed while it was read: read it again" name x))
    in
    C.ok ctx (C.list ctx (Array.of_list (List.map (fun e -> C.Int e) ids)))
  with Refused (code, m) -> failure ctx code m

(* ---- the library OWL 2 RL (the package cesia/cepheus/owl): owl.Rl() names its rules, {Rule: "owl/cax-sco",
   Library: "owl"}, and Define takes them from the engine's library (Cepheus.Owl.rl), for this database ---- *)

let library_keys = C.keys [| "Rule"; "Library" |]

(* the name of a rule of the library, or None for a rule of the program's own *)
let library_rule ctx name v =
  match v with
  | C.Map m | C.Struct m -> (
    match C.fields library_keys m with
    | [| _; C.Missing |] -> None
    | [| C.Text r; C.Text "owl" |] -> Some r
    | _ -> C.need ctx name "a rule of OWL 2 RL, as owl.Rl() gives it" v)
  | _ -> None

(* the ids of OWL 2 RL's vocabulary in this database (declared by owl.Vocabulary, a kind given to Connect or Fork, as
   Cepheus.Owl.setup declares it), and owl:Thing and owl:Nothing, made once in a group of their own *)
let owl_of ctx d =
  let ids =
    List.map
      (fun (n, typ, many, unique) ->
        match declared d n with
        | Some (p, (x : Schema.prop)) when x.typ = typ && x.many = many && x.unique = unique -> p
        | Some _ -> refuse "invalid" "%s is declared in this database otherwise than in OWL 2 RL's vocabulary" n
        | None -> refuse "invalid" "OWL 2 RL's rules need its vocabulary: give owl.Vocabulary to Connect (or Fork)")
      Owl.vocabulary
  in
  let builtin = List.nth ids (List.length ids - 1) in
  let find s =
    match ask_ids ctx d { Query.vars = 1; where = [ { e = Var 0; p = builtin; v = Val (Text s) } ]; ranges = [] } [] with
    | r :: _ -> Some r.(0)
    | [] -> None
  in
  let rec go tries =
    match find "Thing", find "Nothing" with
    | Some thing, Some nothing -> Owl.make ids ~thing ~nothing
    | t, n ->
      if tries = 0 then refuse "conflict" "owl:Thing and owl:Nothing could not be made: Define again";
      let ops = (if t = None then [ Resolve.Add (-1, builtin, Text "Thing") ] else []) @ if n = None then [ Resolve.Add (-2, builtin, Text "Nothing") ] else [] in
      (* another program that made them at once: read again *)
      (match commit ctx d ~by:0 ~why:"cepheus: owl" ops with _ -> () | exception Refused (("unique" | "conflict"), _) -> ());
      go (tries - 1)
  in
  go 3

(* the new rules and the changed ones in one group, as Cepheus.define: a name taken by a property is refused, a race
   for a free id (another program defining at once) is read again *)
let define ctx a =
  let name = "cepheus.Define" in
  try
    let d = db_of ctx name a.(0) in
    let items = list_of ctx name a.(1) in
    (* the program's rules first, then those of the library, which may write owl:Thing and owl:Nothing *)
    let own = Array.map (fun v -> match library_rule ctx name v with Some r -> Error r | None -> Ok (rule_of ctx name d v)) items in
    let library = lazy (Owl.rl (owl_of ctx d)) in
    let rules =
      Array.to_list
        (Array.map
           (function
             | Ok r -> r
             | Error n -> (
               match List.find_opt (fun (r : Rules.t) -> r.name = n) (Lazy.force library) with
               | Some r -> r
               | None -> refuse "invalid" "%s is no rule of OWL 2 RL: owl.Rl() gives its rules" n))
           own)
    in
    let rec go tries =
      let names, texts = named ctx d in
      let next = ref Schema.first_prop in
      let free () =
        while List.mem_assoc !next names do incr next done;
        let p = !next in
        incr next;
        p
      in
      let ops =
        List.concat_map
          (fun (r : Rules.t) ->
            let text = Rules.to_text r in
            match List.find_opt (fun (_, n) -> n = r.name) names with
            | Some (id, _) when List.mem_assoc id texts -> if List.assoc id texts = text then [] else [ Resolve.Add (id, Schema.p_rule, Text text) ]
            | Some _ -> refuse "invalid" "%s is the name of a property" r.name
            | None ->
              let id = free () in
              [ Resolve.Expect (id, Schema.p_name, None); Add (id, Schema.p_name, Text r.name); Add (id, Schema.p_rule, Text text) ])
          rules
      in
      if ops <> [] then
        match commit ctx d ~by:0 ~why:"cepheus: rules" ops with
        | _ -> ()
        | exception Refused ("conflict", _) when tries > 0 -> go (tries - 1)
    in
    go 8;
    C.ok ctx C.Missing
  with Refused (code, m) -> failure ctx code m

let watch_field = C.keys [| "Watch" |]

(* Close of a database (its watches end too), or of a watch: "watch" then, so that the package's code takes what the
   watch's channel holds (its fiber ends) *)
let close ctx a =
  match a.(0) with
  | C.Handle ("cepheus.database", i) -> (
    match entry dbs i with
    | Some d ->
      dbs.items.(i) <- None;
      for k = 0 to watches.count - 1 do
        match entry watches k with
        | Some w when w.wdb == d -> Conn.finish w.c.sh "closed" "the database was closed"; watches.items.(k) <- None; ignore (Conn.leave w.c); stop_source d w.c.sh
        | _ -> ()
      done;
      (match d.src with Server s -> Conn.close s.conn | Fork _ -> ());
      C.Missing
    | None -> C.Missing)
  | C.Handle ("cepheus.watch", i) -> close_watch i; C.Text "watch"
  | (C.Map m | C.Struct m) as v -> (
    match C.fields watch_field m with
    | [| C.Handle ("cepheus.watch", i) |] -> close_watch i; C.Text "watch"
    | _ -> C.need ctx "cepheus.Close" "a database or a watch" v)
  | v -> C.need ctx "cepheus.Close" "a database or a watch" v

let () =
  C.register
    [ "kind", 2, 2, kind; "connect", 4, 4, connect; "get", 3, 3, get; "insert", 5, 5, insert; "update", 6, 6, update;
      "write", 4, 4, write; "variables", 1, 1, variables; "find", 3, 3, find; "fork", 2, 2, fork; "close", 1, 1, close;
      "watch", 3, 3, watch; "next", 1, 1, next; "define", 2, 2, define; "put", 9, 9, put; "read", 5, 5, read;
      "delete", 5, 5, delete; "erase", 2, 2, erase; "same", 2, 2, same_of ]
