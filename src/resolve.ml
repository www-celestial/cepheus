(* From what a client asks to what the journal keeps. One function, used by the writer of a database and by every
   fork, so a fork accepts and refuses exactly what the database would (G8). Checks: types, things that exist,
   one value for a one-valued property (the old value is retracted in the same group), unique values, Expect
   (checked against the state before the group), and the schema rules for property things. *)

type op =
  | Add of int * int * Value.t
  | Retract of int * int * Value.t
  | Expect of int * int * Value.t option

type error = Conflict of string | Invalid of string | Not_unique of string

exception Fail of error

let fail e = raise (Fail e)
let invalid fmt = Printf.ksprintf (fun s -> fail (Invalid s)) fmt

(* The descriptor of a property thing from its facts in v. *)
let read_prop (v : Store.view) p =
  let one q = let r = ref None in Store.iter_values v p q (fun w -> r := Some w); !r in
  match one Schema.p_name, one Schema.p_type with
  | Some nw, Some tw -> (
    match Value.of_code tw with
    | None -> Error (Printf.sprintf "property %d has an unknown type code %d" p tw)
    | Some typ ->
      let flag q = match one q with Some w -> w <> 0 | None -> false in
      Ok (Some { Schema.name = Store.text v nw; typ; many = flag Schema.p_many; unique = flag Schema.p_unique }))
  | None, None -> if Store.has_value v p Schema.p_many || Store.has_value v p Schema.p_unique then Error "half" else Ok None
  | _ -> Error (Printf.sprintf "property %d needs both a name and a type" p)

let refresh (v : Store.view) p =
  match read_prop v p with
  | Ok d -> { v with schema = Schema.set v.schema p d }
  | Error _ -> { v with schema = Schema.set v.schema p None }

let desc (v : Store.view) p =
  match Schema.find v.schema p with Some d -> d | None -> invalid "no property %d" p

(* Applies one change and keeps the schema in step. *)
let apply_change (v : Store.view) (c : Group.change) =
  let d = desc v c.p in
  let v, w =
    if c.add then Store.word_intern v c.v
    else match Store.word v c.v with Some w -> v, w | None -> v, min_int
  in
  if w = min_int then v, false
  else begin
    let v' = Store.apply v c.add c.e c.p w in
    ignore d;
    let v' = if Schema.is_system c.p && Schema.is_prop_space c.e && v' != v then refresh v' c.e else v' in
    v', v' != v
  end

let resolve ?(bootstrap = false) (v0 : Store.view) ~n ~time ~by ~why ops =
  try
    (* new things: negative ids, numbered in order of first use *)
    let temps = Hashtbl.create 4 and order = ref [] in
    let next = ref v0.next_e in
    let see x = if x < 0 && not (Hashtbl.mem temps x) then (Hashtbl.replace temps x !next; order := x :: !order; incr next) in
    List.iter
      (function
        | Add (e, _, x) | Retract (e, _, x) -> see e; (match x with Value.Link t -> see t | _ -> ())
        | Expect (e, _, _) -> if e < 0 then invalid "Expect on a new thing")
      ops;
    let id x = if x < 0 then Hashtbl.find temps x else x in
    let first_new = v0.next_e and count_new = !next - v0.next_e in
    (* Expect: against the state before the group *)
    List.iter
      (function
        | Expect (e, p, None) ->
          ignore (desc v0 p);
          if Store.has_value v0 e p then fail (Conflict (Printf.sprintf "#%d has a value for property %d" e p))
        | Expect (e, p, Some x) ->
          let d = desc v0 p in
          if not (Value.has_type d.typ x) then invalid "Expect: %s is not a %s" (Value.to_string x) (Value.typ_name d.typ);
          let ok = match Store.word v0 x with Some w -> Store.mem v0 e p w | None -> false in
          if not ok then fail (Conflict (Printf.sprintf "#%d does not have %s for property %d" e (Value.to_string x) p))
        | _ -> ())
      ops;
    let v = ref { v0 with next_e = !next } and out = ref [] in
    let record (c : Group.change) =
      let v', changed = apply_change !v c in
      v := v';
      if changed then out := c :: !out
    in
    let check_thing e p =
      if e >= Schema.first_thing then (if e >= !next then invalid "no thing #%d" e)
      else if Schema.is_prop_space e then (if not (Schema.is_system p) then invalid "a property thing takes only cepheus/ properties")
      else if not bootstrap then invalid "#%d is a system thing" e;
      if Schema.is_system p && e >= Schema.first_thing then invalid "cepheus/ properties describe property things only"
    in
    List.iter
      (function
        | Add (e, p, x) ->
          let e = id e and x = (match x with Value.Link t -> Value.Link (id t) | x -> x) in
          let d = desc !v p in
          check_thing e p;
          if not (Value.has_type d.typ x) then invalid "%s is not a %s (property %s)" (Value.to_string x) (Value.typ_name d.typ) d.name;
          (match x with
           | Value.Link t -> if t < Schema.first_prop || t >= !next then invalid "no thing #%d to link to" t
           | _ -> ());
          if not d.many then begin
            let olds = ref [] in
            let w = Store.word !v x in
            Store.iter_values !v e p (fun w' -> if Some w' <> w then olds := w' :: !olds);
            List.iter (fun w' -> record { add = false; e; p; v = Store.value !v d.typ w' }) !olds
          end;
          record { add = true; e; p; v = x }
        | Retract (e, p, x) ->
          let e = id e and x = (match x with Value.Link t -> Value.Link (id t) | x -> x) in
          let d = desc !v p in
          check_thing e p;
          if not (Value.has_type d.typ x) then invalid "%s is not a %s (property %s)" (Value.to_string x) (Value.typ_name d.typ) d.name;
          record { add = false; e; p; v = x }
        | Expect _ -> ())
      ops;
    let changes = Array.of_list (List.rev !out) in
    let v = !v in
    (* unique values, after the whole group *)
    Array.iter
      (fun (c : Group.change) ->
        if c.add then
          match Schema.find v.schema c.p with
          | Some d when d.unique -> (
            match Store.word v c.v with
            | Some w ->
              let others = ref 0 in
              Store.iter_things v c.p w (fun e -> if e <> c.e then incr others);
              if !others > 0 then fail (Not_unique (Printf.sprintf "%s %s is taken" d.name (Value.to_string c.v)))
            | None -> ())
          | _ -> ())
      changes;
    (* schema rules for the property things this group touched *)
    let touched = Hashtbl.create 2 in
    Array.iter (fun (c : Group.change) -> if Schema.is_prop_space c.e then Hashtbl.replace touched c.e ()) changes;
    Hashtbl.iter
      (fun p () ->
        (match read_prop v p with Error m -> invalid "%s" m | Ok _ -> ());
        match Schema.find v0.schema p, Schema.find v.schema p with
        | Some a, Some b ->
          if a.typ <> b.typ || a.many <> b.many then invalid "the type and the cardinality of %s never change" a.name;
          if b.unique && not a.unique then begin
            let seen = Hashtbl.create 64 in
            Store.iter_prop v p (fun e w ->
                match Hashtbl.find_opt seen w with
                | Some e' when e' <> e -> invalid "%s cannot become unique: two things share a value" b.name
                | _ -> Hashtbl.replace seen w e)
          end
        | Some a, None -> if Store.count_prop v p > 0 then invalid "%s still has values" a.name
        | None, _ -> ())
      touched;
    let temps = List.rev_map (fun t -> t, Hashtbl.find temps t) !order in
    Ok ({ v with group = n }, { Group.n; time; by; why; first_new; count_new; changes }, temps)
  with Fail e -> Error e

(* Replay: the resolved changes of a group, from the journal. *)
let replay (v : Store.view) (g : Group.t) =
  let v = ref { v with next_e = max v.next_e (g.first_new + g.count_new) } in
  Array.iter
    (fun (c : Group.change) ->
      match Schema.find !v.schema c.p with
      | None -> raise (Journal.Damaged (Printf.sprintf "group %d uses property %d, which does not exist" g.n c.p))
      | Some _ -> v := fst (apply_change !v c))
    g.changes;
  { !v with group = g.n }

let error_message = function
  | Conflict m -> "conflict: " ^ m
  | Invalid m -> "invalid: " ^ m
  | Not_unique m -> "not unique: " ^ m
