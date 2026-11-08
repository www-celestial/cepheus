module Bulk = Bulk
module Codec = Codec
module Crc32c = Crc32c
module Disk = Disk
module Engine = Engine
module Group = Group
module Pages = Pages
module Histogram = Histogram
module Journal = Journal
module Query = Query
module Resolve = Resolve
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
let empty =
  match Resolve.resolve ~bootstrap:true (Store.empty ()) ~n:1 ~time:0 ~by:0 ~why:"cepheus: create" Engine.bootstrap_ops with
  | Ok (v, _, _) -> v
  | Error _ -> assert false

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
  let v = view db in
  let next = ref Schema.first_prop in
  let free () =
    while Schema.find v.schema !next <> None || Store.has_value v !next Schema.p_name do incr next done;
    let p = !next in
    incr next;
    p
  in
  let ops = ref [] and ids = ref [] in
  let bad = ref None in
  List.iter
    (fun (d : prop) ->
      match Schema.by_name v.schema d.name with
      | Some p ->
        let cur = Option.get (Schema.find v.schema p) in
        if cur.typ <> d.typ || cur.many <> d.many || cur.unique <> d.unique then
          bad := Some (Invalid (Printf.sprintf "%s is declared already as another kind of property" d.name));
        ids := p :: !ids
      | None ->
        let p = free () in
        ids := p :: !ids;
        ops := Expect (p, Schema.p_name, None) :: !ops;
        List.iter (fun (e, q, x) -> ops := Add (e, q, x) :: !ops) (Schema.facts p d))
    props;
  match !bad with
  | Some e -> Error e
  | None ->
    if !ops = [] then Ok (List.rev !ids)
    else (
      match write db ~why:"cepheus: declare" (List.rev !ops) with
      | Ok _ -> Ok (List.rev !ids)
      | Error (Conflict _) -> declare db props (* another writer took the id meanwhile: read again *)
      | Error e -> Error e)

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

type term = Query.term = Var of int | Thing of int | Val of value
type pattern = Query.pattern = { e : term; p : int; v : term }
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
