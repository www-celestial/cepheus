(* Properties are things too: a property is the thing [p] in [16, 65536) with the facts [p cepheus/name "..."],
   [p cepheus/type code], [p cepheus/many bool], [p cepheus/unique bool]. The four system properties (1 to 4) are
   fixed; their own facts are written by the first group of every database, so the schema can be queried like
   anything else. A schema value is persistent: changing it copies the small table. *)

type prop = { name : string; typ : Value.typ; many : bool; unique : bool }

let p_name = 1
let p_type = 2
let p_many = 3
let p_unique = 4
let p_rule = 5
let p_same = 6
let p_to = 7
let p_delete = 8
let first_prop = 16
let first_thing = 65536
let last_thing = (1 lsl 31) - 1

let system =
  [| None;
     Some { name = "cepheus/name"; typ = Value.Ttext; many = false; unique = true };
     Some { name = "cepheus/type"; typ = Value.Tint; many = false; unique = false };
     Some { name = "cepheus/many"; typ = Value.Tbool; many = false; unique = false };
     Some { name = "cepheus/unique"; typ = Value.Tbool; many = false; unique = false };
     Some { name = "cepheus/rule"; typ = Value.Ttext; many = false; unique = false };
     Some { name = "cepheus/same"; typ = Value.Tlink; many = false; unique = false };
     Some { name = "cepheus/to"; typ = Value.Ttext; many = false; unique = false };
     Some { name = "cepheus/delete"; typ = Value.Ttext; many = false; unique = false } |]

(* ---- links that name a kind: Link(to = "client") ----
   A property's kind is its name before its first '/' (the whole name without one): client/City is of the kind
   client. A thing is of a kind while it has a fact of one of the kind's properties that a write asserted. A link
   property may name a kind ([p cepheus/to "client"]): each of its values is then a thing of that kind, and what its
   facts do when such a thing stops being one is its [cepheus/delete] (refuse when none). *)

type on_delete = Refuse | Cascade | Clear

type link = { kind : string; on_delete : on_delete }

let on_delete_name = function Refuse -> "refuse" | Cascade -> "cascade" | Clear -> "clear"
let on_delete_of = function "refuse" -> Some Refuse | "cascade" -> Some Cascade | "clear" -> Some Clear | _ -> None

let kind_of name = match String.index_opt name '/' with Some i -> String.sub name 0 i | None -> name

(* what the writer reads at each write that touches links, made once a schema: by property id, its kind's number
   (kinds numbered from 0, -1 for no property) and whether some link names it; by kind, its properties and the
   links that name it *)
type index = {
  pkind : int array;
  named : Bytes.t;  (* by property: 1 when its kind is named by a link *)
  pto : int array;  (* by property: the number of the kind its link names, -1 none *)
  kinds : string array;
  kind_ids : (string, int) Hashtbl.t;
  members : int array array;  (* by kind: its properties, by id *)
  linkers : (int * on_delete) array array;  (* by kind: the link properties that name it, by id *)
}

module SM = Map.Make (String)

module IM = Map.Make (Int)

(* rules: rule thing -> (name, definition) *)
type t = {
  props : prop option array;
  names : int SM.t;
  rules : (string * string) IM.t;
  rkey : int;
  links : link IM.t;
  ix : index option Atomic.t;  (* made at the first use, for this table of properties and links *)
}

let keys = Atomic.make 0

let initial =
  let names = ref SM.empty in
  Array.iteri (fun i -> function Some p -> names := SM.add p.name i !names | None -> ()) system;
  { props = Array.append system (Array.make (first_prop - Array.length system) None); names = !names; rules = IM.empty; rkey = 0;
    links = IM.empty; ix = Atomic.make None }

let find s p = if p >= 0 && p < Array.length s.props then Array.unsafe_get s.props p else None
let by_name s n = SM.find_opt n s.names
let is_system p = p > 0 && p < first_prop
let is_prop_space e = e >= first_prop && e < first_thing
let count s = Array.length s.props

let set s p d =
  let props =
    if p < Array.length s.props then Array.copy s.props
    else begin
      let a = Array.make (max (p + 1) (2 * Array.length s.props)) None in
      Array.blit s.props 0 a 0 (Array.length s.props);
      a
    end
  in
  let names = match props.(p) with Some old -> SM.remove old.name s.names | None -> s.names in
  props.(p) <- d;
  let names = match d with Some d -> SM.add d.name p names | None -> names in
  { s with props; names; ix = Atomic.make None }

let rules s = IM.bindings s.rules
let rules_key s = s.rkey
let has_rules s = not (IM.is_empty s.rules)
let rule s p = IM.find_opt p s.rules
let rule_by_name s n = IM.fold (fun p (n', _) acc -> if n' = n then Some p else acc) s.rules None

let set_rule s p r =
  match IM.find_opt p s.rules, r with
  | Some a, Some b when a = b -> s
  | None, None -> s
  | _ ->
    let rules = match r with Some r -> IM.add p r s.rules | None -> IM.remove p s.rules in
    { s with rules; rkey = 1 + Atomic.fetch_and_add keys 1 }

let link s p = if IM.is_empty s.links then None else IM.find_opt p s.links
let has_links s = not (IM.is_empty s.links)
let links s = IM.bindings s.links

let set_link s p l =
  match IM.find_opt p s.links, l with
  | None, None -> s
  | Some a, Some b when a = b -> s
  | _ -> { s with links = (match l with Some l -> IM.add p l s.links | None -> IM.remove p s.links); ix = Atomic.make None }

let make_index s =
  let n = Array.length s.props in
  let kind_ids = Hashtbl.create 16 and kinds = ref [] and nk = ref 0 in
  let id k = match Hashtbl.find_opt kind_ids k with Some i -> i | None -> let i = !nk in Hashtbl.add kind_ids k i; kinds := k :: !kinds; incr nk; i in
  let pkind = Array.make n (-1) in
  for p = first_prop to n - 1 do match s.props.(p) with Some d -> pkind.(p) <- id (kind_of d.name) | None -> () done;
  (* a kind a link names that has no property yet: numbered all the same *)
  IM.iter (fun _ l -> ignore (id l.kind)) s.links;
  let members = Array.make !nk [] and linkers = Array.make !nk [] in
  for p = n - 1 downto first_prop do if pkind.(p) >= 0 then members.(pkind.(p)) <- p :: members.(pkind.(p)) done;
  List.iter (fun (p, l) -> let k = id l.kind in linkers.(k) <- (p, l.on_delete) :: linkers.(k)) (List.rev (IM.bindings s.links));
  let pto = Array.make n (-1) in
  IM.iter (fun p l -> if p < n then pto.(p) <- id l.kind) s.links;
  let named = Bytes.make n '\000' in
  for p = first_prop to n - 1 do if pkind.(p) >= 0 && linkers.(pkind.(p)) <> [] then Bytes.set named p '\001' done;
  { pkind; named; pto; kinds = Array.of_list (List.rev !kinds); kind_ids; members = Array.map Array.of_list members;
    linkers = Array.map Array.of_list linkers }

let index s =
  match Atomic.get s.ix with
  | Some i -> i
  | None -> let i = make_index s in Atomic.set s.ix (Some i); i

let kind_id ix k = match Hashtbl.find_opt ix.kind_ids k with Some i -> i | None -> -1
let named ix p = p >= 0 && p < Bytes.length ix.named && Bytes.unsafe_get ix.named p <> '\000'

(* The facts that declare property [p]. *)
let facts p d =
  [ p, p_name, Value.Text d.name; p, p_type, Value.Int (Value.code d.typ); p, p_many, Value.Bool d.many;
    p, p_unique, Value.Bool d.unique ]
