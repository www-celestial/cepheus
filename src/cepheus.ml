module Bulk = Bulk
module Codec = Codec
module Crc32c = Crc32c
module Disk = Disk
module Engine = Engine
module Group = Group
module Pack = Pack
module Pages = Pages
module Pool = Pool
module Writers = Writers
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
module Wal = Wal
module Zone = Zone

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
  | Timeout of string

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

type op = Resolve.op =
  | Add of int * int * value
  | Retract of int * int * value
  | Expect of int * int * value option
  | Incr of int * int * int * (int * int) option
  | Delete of int * string
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

exception Found of int

type prop = Schema.prop = { name : string; typ : typ; many : bool; unique : bool }

let prop ?(many = false) ?(unique = false) name typ = { name; typ; many; unique }
let property (v : view) n = Schema.by_name v.schema n
let describe (v : view) p = Schema.find v.schema p

type on_delete = Schema.on_delete = Refuse | Cascade | Clear

let link (v : view) p = match Schema.link v.schema p with Some l -> Some (l.kind, l.on_delete) | None -> None

let rec link_to db links =
  let v = view db in
  match List.find_opt (fun (p, _, _) -> Schema.find v.schema p = None) links with
  | Some (p, _, _) -> Error (Invalid (Printf.sprintf "no property %d" p))
  | None -> (
    let named = List.map (fun (p, kind, on_delete) -> p, (Option.get (Schema.find v.schema p)).name, { Schema.kind; on_delete }) links in
    match Resolve.link_ops (Schema.link v.schema) named with
    | Error m -> Error (Invalid m)
    | Ok [] -> Ok ()
    | Ok ops -> (
      match write db ~why:"cepheus: links" ops with
      | Ok _ -> Ok ()
      | Error (Conflict _) -> link_to db links (* another writer named a kind for one of them meanwhile: read again *)
      | Error e -> Error e))

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

let prop_var = Rules.prop_var
let every = Rules.every
let absent = Rules.absent
let aggregate = Rules.aggregate
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

(* ---- OWL 2 RL, a library of rules (src/owl.ml) ---- *)

module Owl = struct
  include Owl

  (* the vocabulary declared, and owl:Thing and owl:Nothing made, once: what is there already is kept *)
  let rec setup db =
    match declare db (List.map (fun (n, typ, many, unique) -> prop ~many ~unique n typ) vocabulary) with
    | Error e -> Error e
    | Ok ids -> (
      let builtin = List.nth ids (List.length ids - 1) in
      let v = view db in
      let find s = match Store.word v (Value.Text s) with Some w -> (match Store.iter_things v builtin w (fun e -> raise_notrace (Found e)) with () -> None | exception Found e -> Some e) | None -> None in
      match find "Thing", find "Nothing" with
      | Some thing, Some nothing -> Ok (make ids ~thing ~nothing)
      | t, n -> (
        let ops = (match t with None -> [ Add (-1, builtin, Text "Thing") ] | Some _ -> []) @ (match n with None -> [ Add (-2, builtin, Text "Nothing") ] | Some _ -> []) in
        match write db ~why:"cepheus: owl" ops with
        | Ok _ | Error (Not_unique _) -> setup db
        | Error e -> Error e))

  (* the description thing of a property: the thing whose owl/Property is p, if one *)
  let description (t : t) (v : view) p = match Store.iter_things v t.property p (fun e -> raise_notrace (Found e)) with () -> None | exception Found e -> Some e
end

type proof = Reason.proof =
  | Given of { e : int; p : int; v : value }
  | By of { rule : string; e : int; p : int; v : value; from : proof list }

(* a thing named, and a thing as the value, read as their classes' representatives (as get and values read them) *)
let why (v : view) e p x =
  let e = Query.rep v e and x = match x with Link t -> Link (Query.rep v t) | x -> x in
  match Store.word v x with None -> None | Some w -> Reason.why v e p w

let sources = Reason.sources
let rule_budget = Reason.budget_base, Reason.budget_per
let change_budget = Reason.change_per
let work_budget = Reason.work_per

let typ_of (v : view) p = match Schema.find v.schema p with Some d -> Some d.typ | None -> None

(* ---- classes of equal things ---- *)

let same (v : view) x = Query.same v x

let get (v : view) e =
  let e = Query.rep v e in
  let out = ref [] in
  Store.iter_facts v e (fun p w -> match typ_of v p with Some t -> out := (p, Store.value v t w) :: !out | None -> ());
  List.sort compare !out

let values (v : view) e p =
  let e = Query.rep v e in
  match typ_of v p with
  | None -> []
  | Some t ->
    let out = ref [] in
    Store.iter_values v e p (fun w -> out := Store.value v t w :: !out);
    List.rev !out

let things (v : view) p x =
  let x = match x with Link t -> Link (Query.rep v t) | x -> x in
  match Store.word v x with
  | None -> []
  | Some w ->
    let out = ref [] in
    Store.iter_things v p w (fun e -> out := e :: !out);
    List.sort compare !out

type query = Query.t = { vars : int; where : pattern list; ranges : (int * value * value) list }

(* a question's time, in seconds: its stop (none when not given) *)
let stop_of = function
  | None -> None
  | Some t ->
    if Float.is_nan t || t <= 0. then invalid_arg (Printf.sprintf "Cepheus: a question's timeout is a number of seconds above 0, not %g" t);
    Some (Query.stop t)

let find ?timeout v q =
  let stop = stop_of timeout in
  try Ok (Query.rows ?stop v q)
  with Query.Bad m -> Error (Invalid m) | Pages.Unreadable m -> Error (Damaged m) | Query.Timeout t -> Error (Timeout (Query.timeout_message t))

module Question = Question

(* a domain's rows of [ask], newest first, after the rows of the domains merged into it (their lists, the newest
   first, each newest first); the word and value of each column in its row before *)
type rows = { mutable rows : Value.t array list; mutable before : Value.t array list list; word : int array; last : Value.t array }

let ask ?timeout v (q : Question.t) =
  let stop = stop_of timeout in
  try
    let where = List.filter_map (function Ask.Pattern p -> Some p | _ -> None) q.items in
    let ranges = List.filter_map (function Ask.Range (x, lo, hi) -> Some (x, lo, hi) | _ -> None) q.items in
    let extra = List.filter (function Ask.Pattern _ | Ask.Range _ -> false | _ -> true) q.items in
    (* its Truncs: columns computed from a date as a row is given *)
    let truncs, extra = Ask.truncs extra in
    let base = { Query.vars = q.vars; where; ranges } in
    let t = Ask.compile v base extra in
    let derived = Ask.derived ~name:(fun x -> Ask.var_name v (Ask.patterns base extra) x) ~vars:q.vars ~outer:(fun x -> t.outer.(x)) (Ask.typs_of t) truncs in
    let nd = Array.length derived in
    let give = if Array.length q.give = 0 then Array.of_list (List.filter (fun x -> t.outer.(x)) (List.init q.vars Fun.id)) else q.give in
    Array.iter (fun x -> if x < 0 || x >= q.vars + nd || (x < q.vars && not t.outer.(x)) then Query.bad "give: variable %d is not one of the question's" x) give;
    let ty = Ask.typs_of t in
    let typs = Array.map (fun x -> if x < q.vars then ty.(x) else Value.Tdate) give in
    let masked = Array.length t.opts > 0 in
    let src =
      { Top.fold =
          (fun window ~seq ~init ~step ~merge ->
            match window with
            | None -> Ask.fold ~seq ~shared:true ?stop v t ~init ~step ~merge
            | Some (Top.Range (x, lo, hi)) -> Ask.fold ~seq ~shared:true ?stop ~range:(x, lo, hi) v t ~init ~step ~merge
            | Some (Top.Words (x, ws)) -> Ask.fold ~seq ~shared:true ?stop ~words:(x, ws) v t ~init ~step ~merge);
        project = (if nd = 0 then Ask.projector t give else Ask.derived_projector ~vars:q.vars ~mask:masked derived give);
        var = (fun c -> if give.(c) < q.vars then Some give.(c) else None);
        lead = Top.lead v base;
        estimate = (fun () -> Ask.estimate v t) }
    in
    let order = { Top.keys = q.sort; limit = q.limit; after = q.after } in
    let k = Array.length give in
    let values r = Array.init k (fun i -> if masked && Top.missing k r i then Value.missing else Store.value v typs.(i) r.(i)) in
    if order = Top.none then begin
      (* each row's values made in the step, by the domain that found it, from its binding (no row of words between);
         a domain's rows in a list, newest first, and the lists of the domains joined at the end in their order *)
      (* a column's value made again only when its word changes from the domain's row before (the outer variables of
         a join repeat over the inner ones): the same immutable value shared, one allocation the less a cell *)
      let row a =
        if nd > 0 then fun b -> values (src.project b)
        else
          fun (b : int array) ->
            let r = Array.make k Value.missing in
            for i = 0 to k - 1 do
              let x = Array.unsafe_get give i in
              if not (masked && (Array.unsafe_get b q.vars lsr x) land 1 = 1) then begin
                let w = Array.unsafe_get b x in
                let last = Array.unsafe_get a.last i in
                if last != Value.missing && Array.unsafe_get a.word i = w then Array.unsafe_set r i last
                else begin
                  let y = Store.value v (Array.unsafe_get typs i) w in
                  Array.unsafe_set a.word i w;
                  Array.unsafe_set a.last i y;
                  Array.unsafe_set r i y
                end
              end
            done;
            r
      in
      let acc =
        Ask.fold ~shared:true ?stop v t ~init:(fun () -> { rows = []; before = []; word = Array.make k 0; last = Array.make k Value.missing })
          ~merge:(fun a b -> a.before <- b.before @ (a.rows :: a.before); a.rows <- b.rows; a)
          ~step:(fun a b -> a.rows <- row a b :: a.rows; a)
      in
      Ok (List.fold_left (fun l part -> List.rev_append part l) (List.rev acc.rows) acc.before)
    end
    else Ok (List.map values (Array.to_list (Top.give ~masked v ~typs src order)))
  with Query.Bad m -> Error (Invalid m) | Pages.Unreadable m -> Error (Damaged m) | Query.Timeout t -> Error (Timeout (Query.timeout_message t))

let fold ?timeout v q ~init ~step ~merge =
  let stop = stop_of timeout in
  try Ok (Query.fold ?stop v q ~init ~step ~merge)
  with Query.Bad m -> Error (Invalid m) | Pages.Unreadable m -> Error (Damaged m) | Query.Timeout t -> Error (Timeout (Query.timeout_message t))

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
