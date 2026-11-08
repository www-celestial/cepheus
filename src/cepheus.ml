module Bulk = Bulk
module Codec = Codec
module Crc32c = Crc32c
module Disk = Disk
module Engine = Engine
module Group = Group
module Pack = Pack
module Pages = Pages
module Histogram = Histogram
module Journal = Journal
module Query = Query
module Reason = Reason
module Resolve = Resolve
module Rules = Rules
module Rng = Rng
module Schema = Schema
module Sim_disk = Sim_disk
module Snapshot = Snapshot
module Store = Store
module Value = Value

type value = Value.t = Int of int | Float of float | Bool of bool | Text of string | Date of int | Money of int | Link of int
type typ = Value.typ = Tint | Tfloat | Tbool | Ttext | Tdate | Tmoney of int | Tlink

type error = Engine.error =
  | Conflict of string
  | Invalid of string
  | Not_unique of string
  | Damaged of string
  | Io of string
  | Busy of string
  | Closed

let message = Engine.message

type fork = { mutable fv : Store.view; fm : Mutex.t }
type db = Durable of Engine.live | Temporary of fork
type view = Store.view

let open_on disk dir = Result.map (fun e -> Durable (Engine.start e)) (Engine.open_ disk dir)
let open_ dir = open_on Disk.real dir
let close = function Durable l -> Engine.stop l | Temporary _ -> ()
let view = function Durable l -> Atomic.get l.e.published | Temporary f -> f.fv
let group (v : view) = v.group
let fork v = Temporary { fv = Store.fork v; fm = Mutex.create () }
let empty = Resolve.empty

type op = Resolve.op = Add of int * int * value | Retract of int * int * value | Expect of int * int * value option
type receipt = Engine.receipt = { group : int; things : (int * int) list }

let write db ?(by = 0) ?(why = "") ops =
  match db with
  | Durable l -> Engine.write l ops by why
  | Temporary f ->
    Mutex.protect f.fm (fun () ->
        let v = f.fv in
        match Resolve.resolve v ~n:(v.group + 1) ~time:(Disk.real.now ()) ~by ~why ops with
        | Ok (v', _, temps) ->
          f.fv <- v';
          Ok { group = v'.group; things = temps }
        | Error e -> Error (Engine.of_resolve e))

let thing r k = List.assoc k r.things

type prop = Schema.prop = { name : string; typ : typ; many : bool; unique : bool }

let prop ?(many = false) ?(unique = false) name typ = { name; typ; many; unique }
let property (v : view) n = Schema.by_name v.schema n
let describe (v : view) p = Schema.find v.schema p

let rec declare db props =
  match Resolve.declare (view db) props with
  | Error m -> Error (Invalid m)
  | Ok (ids, []) -> Ok ids
  | Ok (ids, ops) -> (
    match write db ~why:"cepheus: declare" ops with
    | Ok _ -> Ok ids
    | Error (Conflict _) -> declare db props (* another writer took the id meanwhile: read again *)
    | Error e -> Error e)

(* ---- rules ---- *)

type term = Query.term = Var of int | Thing of int | Val of value
type pattern = Query.pattern = { e : term; p : int; v : term }
type head = Rules.head = Give of pattern | Never
type rule = Rules.t = { name : string; vars : int; where : pattern list; ranges : (int * value * value) list; head : head }

let rec define db (rules : rule list) =
  let v = view db in
  let next = ref Schema.first_prop in
  let free () =
    while Schema.find v.schema !next <> None || Store.has_value v !next Schema.p_name do incr next done;
    let p = !next in
    incr next;
    p
  in
  let ops = ref [] and ids = ref [] and bad = ref None in
  List.iter
    (fun (r : rule) ->
      let text = Rules.to_text r in
      match Schema.rule_by_name v.schema r.name with
      | Some id ->
        ids := id :: !ids;
        (match Schema.rule v.schema id with
         | Some (_, t) when t = text -> ()
         | _ -> ops := Add (id, Schema.p_rule, Text text) :: !ops)
      | None ->
        if Schema.by_name v.schema r.name <> None then bad := Some (Invalid (Printf.sprintf "%s is the name of a property" r.name))
        else begin
          let id = free () in
          ids := id :: !ids;
          ops := Add (id, Schema.p_rule, Text text) :: Add (id, Schema.p_name, Text r.name) :: Expect (id, Schema.p_name, None) :: !ops
        end)
    rules;
  match !bad with
  | Some e -> Error e
  | None ->
    if !ops = [] then Ok (List.rev !ids)
    else (
      match write db ~why:"cepheus: rules" (List.rev !ops) with
      | Ok _ -> Ok (List.rev !ids)
      | Error (Conflict _) -> define db rules
      | Error e -> Error e)

let undefine db names =
  let v = view db in
  let ops =
    List.concat_map
      (fun n ->
        match Schema.rule_by_name v.schema n with
        | Some id -> (
          match Schema.rule v.schema id with
          | Some (_, t) -> [ Retract (id, Schema.p_rule, Text t); Retract (id, Schema.p_name, Text n) ]
          | None -> [])
        | None -> [])
      names
  in
  if ops = [] then Ok () else Result.map (fun _ -> ()) (write db ~why:"cepheus: rules" ops)

type proof = Reason.proof =
  | Given of { e : int; p : int; v : value }
  | By of { rule : string; e : int; p : int; v : value; from : proof list }

let why (v : view) e p x = match Store.word v x with None -> None | Some w -> Reason.why v e p w

let rule_budget = Reason.budget_base, Reason.budget_per

let typ_of (v : view) p = match Schema.find v.schema p with Some d -> Some d.typ | None -> None

let get (v : view) e =
  let out = ref [] in
  Store.iter_facts v e (fun p w -> match typ_of v p with Some t -> out := (p, Store.value v t w) :: !out | None -> ());
  List.sort compare !out

let values (v : view) e p =
  match typ_of v p with
  | None -> []
  | Some t ->
    let out = ref [] in
    Store.iter_values v e p (fun w -> out := Store.value v t w :: !out);
    List.rev !out

let things (v : view) p x =
  match Store.word v x with
  | None -> []
  | Some w ->
    let out = ref [] in
    Store.iter_things v p w (fun e -> out := e :: !out);
    List.sort compare !out

type query = Query.t = { vars : int; where : pattern list; ranges : (int * value * value) list }

let find v q = try Ok (Query.rows v q) with Query.Bad m -> Error (Invalid m) | Pages.Unreadable m -> Error (Damaged m)

let fold v q ~init ~step ~merge =
  try Ok (Query.fold v q ~init ~step ~merge) with Query.Bad m -> Error (Invalid m) | Pages.Unreadable m -> Error (Damaged m)

(* the type of variable x comes from the question, as find decodes its words *)
let decode (v : view) (q : query) x w =
  if x < 0 || x >= q.vars then invalid_arg (Printf.sprintf "Cepheus.decode: variable %d out of range" x);
  match Query.types v q with
  | ty -> Store.value v ty.(x) w
  | exception Query.Bad m -> invalid_arg ("Cepheus.decode: " ^ m)

exception Unreadable = Pages.Unreadable

let set_cache = Pages.set_capacity

let snapshot = function
  | Durable l -> Result.map (fun _ -> ()) (Engine.snapshot_live l)
  | Temporary _ -> Error (Invalid "a fork has no files")

let verify dir =
  try
    let id = Engine.read_meta Disk.real dir in
    Ok (Journal.verify Disk.real (Filename.concat dir "journal") id)
  with
  | Journal.Damaged m -> Error (Damaged m)
  | Disk.Io m -> Error (Io m)

let notes = function Durable l -> l.e.notes | Temporary _ -> []
