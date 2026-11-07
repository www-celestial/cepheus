(* Properties are things too: a property is the thing [p] in [16, 65536) with the facts [p cepheus/name "..."],
   [p cepheus/type code], [p cepheus/many bool], [p cepheus/unique bool]. The four system properties (1 to 4) are
   fixed; their own facts are written by the first group of every database, so the schema can be queried like
   anything else. A schema value is persistent: changing it copies the small table. *)

type prop = { name : string; typ : Value.typ; many : bool; unique : bool }

let p_name = 1
let p_type = 2
let p_many = 3
let p_unique = 4
let first_prop = 16
let first_thing = 65536

let system =
  [| None;
     Some { name = "cepheus/name"; typ = Value.Ttext; many = false; unique = true };
     Some { name = "cepheus/type"; typ = Value.Tint; many = false; unique = false };
     Some { name = "cepheus/many"; typ = Value.Tbool; many = false; unique = false };
     Some { name = "cepheus/unique"; typ = Value.Tbool; many = false; unique = false } |]

module SM = Map.Make (String)

type t = { props : prop option array; names : int SM.t }

let initial =
  let names = ref SM.empty in
  Array.iteri (fun i -> function Some p -> names := SM.add p.name i !names | None -> ()) system;
  { props = Array.append system (Array.make (first_prop - Array.length system) None); names = !names }

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
  { props; names }

(* The facts that declare property [p]. *)
let facts p d =
  [ p, p_name, Value.Text d.name; p, p_type, Value.Int (Value.code d.typ); p, p_many, Value.Bool d.many;
    p, p_unique, Value.Bool d.unique ]
