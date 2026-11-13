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

(* What a schema thing is, from its facts in v: a property (a name and a type), a rule (a name and a definition), or
   nothing yet. *)
type thing = Prop of Schema.prop | Rule of string * string | Nothing

let read_thing (v : Store.view) p =
  let one q = let r = ref None in Store.iter_values v p q (fun w -> r := Some w); !r in
  match one Schema.p_name, one Schema.p_type, one Schema.p_rule with
  | Some nw, Some tw, None -> (
    match Value.of_code tw with
    | None -> Error (Printf.sprintf "property %d has an unknown type code %d" p tw)
    | Some typ ->
      let flag q = match one q with Some w -> w <> 0 | None -> false in
      Ok (Prop { Schema.name = Store.text v nw; typ; many = flag Schema.p_many; unique = flag Schema.p_unique }))
  | Some nw, None, Some rw ->
    if Store.has_value v p Schema.p_many || Store.has_value v p Schema.p_unique then
      Error (Printf.sprintf "rule %d takes a name and a definition only" p)
    else Ok (Rule (Store.text v nw, Store.text v rw))
  | None, None, None ->
    if Store.has_value v p Schema.p_many || Store.has_value v p Schema.p_unique then
      Error (Printf.sprintf "property %d keeps cepheus/many or cepheus/unique without a name and a type" p)
    else Ok Nothing
  | _, _, Some _ -> Error (Printf.sprintf "rule %d needs a name and a definition, and no type" p)
  | _ -> Error (Printf.sprintf "property %d needs both a name and a type" p)

let install_thing schema p = function
  | Ok (Prop d) -> Schema.set_rule (Schema.set schema p (Some d)) p None
  | Ok (Rule (n, t)) -> Schema.set_rule (Schema.set schema p None) p (Some (n, t))
  | Ok Nothing | Error _ -> Schema.set_rule (Schema.set schema p None) p None

let refresh (v : Store.view) p = { v with schema = install_thing v.schema p (read_thing v p) }

let desc (v : Store.view) p =
  match Schema.find v.schema p with Some d -> d | None -> invalid "no property %d" p

(* Applies one change (the state its kind leaves) and keeps the schema in step. No word is kept for "absent": every
   int is a value's word (min_int is the smallest Int, Date or Money), so a value not in the view is the None of
   Store.word. *)
let apply_word (v : Store.view) (c : Group.change) w s =
  let v' = Store.set v c.e c.p w s in
  let v' = if Schema.is_system c.p && Schema.is_prop_space c.e && v' != v then refresh v' c.e else v' in
  v', v' != v

let apply_change (v : Store.view) (c : Group.change) =
  ignore (desc v c.p);
  let s = Group.after c.kind in
  if s > 0 then (let v, w = Store.word_intern v c.v in apply_word v c w s)
  else match Store.word v c.v with Some w -> apply_word v c w s | None -> v, false

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
    if !next - 1 > Schema.last_thing then
      invalid "thing numbers end at %d: this group would make #%d" Schema.last_thing (!next - 1);
    let id x = if x < 0 then Hashtbl.find temps x else x in
    let first_new = v0.next_e and count_new = !next - v0.next_e in
    (* Expect: against the state before the group *)
    List.iter
      (function
        | Expect (e, p, None) ->
          let d = desc v0 p in
          if Store.has_value v0 e p then fail (Conflict (Printf.sprintf "#%d has a value for %s (property %d)" e d.name p))
        | Expect (e, p, Some x) ->
          let d = desc v0 p in
          if not (Value.has_type d.typ x) then invalid "Expect: %s is not a %s" (Value.to_string x) (Value.typ_name d.typ);
          let ok = match Store.word v0 x with Some w -> Store.mem v0 e p w | None -> false in
          if not ok then fail (Conflict (Printf.sprintf "#%d does not have %s for %s (property %d)" e (Value.to_string x) d.name p))
        | _ -> ())
      ops;
    let v = ref { v0 with next_e = !next } and out = ref [] and outw = ref [] in
    (* an asserted change, with the state the fact had (one lookup does both): an addition of a fact a rule derives
       makes it asserted too; a retraction of a fact only derived is refused, naming the rule (choice 10.4 of the
       reasoner design) *)
    let v_before = v0 in
    let assert_word add e p x vi w =
      let v1, prev = Store.swap vi e p w (if add then 1 else 0) in
      let kind : Group.kind option =
        match add, prev with
        | true, 0 -> Some Added
        | true, 2 -> Some Now_asserted
        | false, 1 -> Some Retracted
        | false, 2 ->
          (* derived in the state before the group (Resolve changes asserted facts only): its proof is that state's *)
          invalid "%s" (Reason.derived_message v_before e p w)
        | _ -> None
      in
      match kind with
      | None -> v := vi
      | Some kind ->
        v := if Schema.is_system p && Schema.is_prop_space e then refresh v1 e else v1;
        out := { Group.kind; e; p; v = x } :: !out;
        outw := w :: !outw
    in
    (* a retraction of a value the view has no word for (an unknown text) retracts nothing *)
    let assert_change add e p x =
      let v0 = !v in
      if add then (let vi, w = Store.word_intern v0 x in assert_word add e p x vi w)
      else match Store.word v0 x with Some w -> assert_word add e p x v0 w | None -> ()
    in
    let assert_add e p x = assert_change true e p x and assert_retract e p x = assert_change false e p x in
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
            List.iter (fun w' -> assert_retract e p (Store.value !v d.typ w')) !olds
          end;
          assert_add e p x
        | Retract (e, p, x) ->
          let e = id e and x = (match x with Value.Link t -> Value.Link (id t) | x -> x) in
          let d = desc !v p in
          check_thing e p;
          if not (Value.has_type d.typ x) then invalid "%s is not a %s (property %s)" (Value.to_string x) (Value.typ_name d.typ) d.name;
          assert_retract e p x
        | Expect _ -> ())
      ops;
    let changes = Array.of_list (List.rev !out) in
    (* the schema things this group touched: properties checked below, rules here, before they run *)
    let touched = Hashtbl.create 2 in
    Array.iter (fun (c : Group.change) -> if Schema.is_prop_space c.e then Hashtbl.replace touched c.e ()) changes;
    Hashtbl.iter
      (fun p () ->
        match read_thing !v p, Schema.find v0.schema p, Schema.rule v0.schema p with
        | Error m, _, _ -> invalid "%s" m
        | Ok (Rule _), Some a, _ -> invalid "%s is a property: it never becomes a rule" a.name
        | Ok (Prop d), _, Some _ -> invalid "a rule never becomes a property (%s)" d.name
        | _ -> ())
      touched;
    if Schema.rules_key !v.schema <> Schema.rules_key v0.schema || Hashtbl.length touched > 0 then begin
      let rules =
        List.map
          (fun (_, (name, text)) ->
            match Rules.of_text name text with
            | Error m -> invalid "%s" m
            | Ok r -> (match Rules.check !v r with Error m -> invalid "%s" m | Ok () -> r))
          (Schema.rules !v.schema)
      in
      (* the rule set as a whole: an aggregate's property is its rule's alone, and no property depends on its own
         absence or aggregate (the strata) *)
      if not (List.for_all Rules.is_plain rules) then begin
        let rules = Array.of_list rules in
        let shapes = Array.map Rules.split rules in
        Array.iteri
          (fun i (sh : Rules.shape) ->
            match sh.agg, sh.pos.head with
            | Some _, Give h ->
              let name = match Schema.find !v.schema h.p with Some d -> d.name | None -> string_of_int h.p in
              Array.iteri
                (fun j (o : Rules.shape) ->
                  match o.pos.head with
                  | Give g when j <> i && (g.p = h.p || g.p < 0) -> invalid "rule %s gives %s, which the aggregate %s gives" rules.(j).name name rules.(i).name
                  | _ -> ())
                shapes;
              let mine = try Store.iter_prop !v h.p (fun e w -> if Store.state !v e h.p w = 1 then raise_notrace Exit); true with Exit -> false in
              if not mine then invalid "rule %s: %s holds facts a write asserted; an aggregate's property holds only what it gives" rules.(i).name name
            | _ -> ())
          shapes;
        match Rules.strata !v rules with Error m -> invalid "%s" m | Ok _ -> ()
      end
    end;
    (* the rules: what they derive from this group, and what they no longer derive *)
    let v, changes =
      match Reason.run ~v0 !v changes (Array.of_list (List.rev !outw)) with
      | r -> r
      | exception Reason.Refused m -> invalid "%s" m
    in
    (* unique values, after the whole group *)
    Array.iter
      (fun (c : Group.change) ->
        if c.kind = Added then
          match Schema.find v.schema c.p with
          | Some d when d.unique -> (
            match Store.word v c.v with
            | Some w when Store.mem v c.e c.p w ->
              (* unique is a property of the state after the group: a value replaced within it does not count *)
              let others = ref 0 in
              Store.iter_things v c.p w (fun e -> if e <> c.e then incr others);
              if !others > 0 then fail (Not_unique (Printf.sprintf "%s %s is taken" d.name (Value.to_string c.v)))
            | _ -> ())
          | _ -> ())
      changes;
    (* schema rules for the property things this group touched *)
    Hashtbl.iter
      (fun p () ->
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

(* ---- Large groups ----
   A group of many additions (a load) takes a faster path to the same result: the changes Resolve would record, in
   the same order, without a persistent map per fact. Its facts come out as compact arrays (Bulk), which a merge reads
   as it reads a run. The path takes only what it can decide alone: additions to things the group creates or ordinary
   things; one value at most per new thing for a one-valued property; for an existing thing, many-valued properties
   only; nothing unique already taken. Anything else, or any doubt (an error, a value twice), and the group goes
   through [resolve], which decides as always, errors included: the faster path never accepts or refuses on its own,
   so a fork, which always takes [resolve], answers exactly as the database (G8).

   The operations are cut into chunks (Bulk.chunk) mapped by several domains at once: each chunk's facts go to its
   own place of the arrays, its texts are looked up in the view and those it adds are listed in the order it meets
   them. One pass in the group's order then numbers the new things and the new texts in their order of first use,
   exactly as [resolve] numbers them (a chunk's first uses come before the next chunk's), and the chunks are rewritten
   with the final numbers, again at once. *)

let large_min = ref 20_000

exception Slow

type large = {
  view : Store.view;
  facts : Bulk.t;  (* the effective changes, all additions, in the group's order: what the journal keeps *)
  count : int;
  dense : Bulk.i32;  (* the number of temporary id -t, for 1 <= t <= deep, or -1: what [receipt] reads *)
  farmap : (int, int) Hashtbl.t;  (* the numbers of the temporary ids below -nops *)
  n : int;
  time : int;
  by : int;
  why : string;
  first_new : int;
  count_new : int;
}

(* a property for the faster path: its type (bits 0-2: 1 int, 2 date, 3 money, 4 bool, 5 link, 6 text, 7 float),
   many-valued (bit 3); 0: not for this path *)
let kind_of (d : Schema.prop) =
  let t = match d.typ with
    | Value.Tint -> 1 | Tdate -> 2 | Tmoney _ -> 3 | Tbool -> 4 | Tlink -> 5 | Ttext -> 6 | Tfloat -> 7
  in
  t lor if d.many then 8 else 0

let kinds (v : Store.view) =
  Array.init (Schema.count v.schema) (fun q ->
      match Schema.find v.schema q with Some d when not (Schema.is_system q) -> kind_of d | _ -> 0)

(* in [Bulk.t.e]: a new thing whose temporary id is below -n (n operations), found in its chunk's list *)
let far = Int32.to_int Int32.min_int

let resolve_large (v0 : Store.view) ~n ~time ~by ~why ops =
  try
    let ch = !Bulk.chunk in
    (* the chunks of the list: their first cells, found by one walk *)
    let starts = ref [] and nops = ref 0 in
    let rec walk l i = match l with [] -> nops := i | _ :: r -> if i mod ch = 0 then starts := l :: !starts; walk r (i + 1) in
    walk ops 0;
    let starts = Array.of_list (List.rev !starts) and nops = !nops in
    let nch = Array.length starts in
    let kinds = kinds v0 in
    let np = Array.length kinds in
    (* the properties some rule reads or gives: the group's facts reasoned in bulk, below *)
    let ruled = Reason.reads v0 in
    let fe = Bulk.i32 nops and fp = Bulk.u16 nops and fw = Bulk.ints nops in
    (* each chunk: the texts it adds in its order (the word of the j-th is -j-1 until renumbered), its temporary ids
       below -nops in its order, the largest of its others *)
    let fresh = Array.make nch [||] and fars = Array.make nch [||] and deeps = Array.make nch 0 in
    Bulk.parallel nch (fun c ->
        let l = ref starts.(c) in
        let local = Hashtbl.create 256 and added = ref [] and na = ref 0 and fl = ref [] and deep = ref 0 in
        let text s =
          match Hashtbl.find_opt local s with
          | Some w -> w
          | None ->
            let w = match Store.find_text v0 s with Some w -> w | None -> added := s :: !added; incr na; - !na in
            Hashtbl.add local s w;
            w
        in
        for i = c * ch to min nops ((c + 1) * ch) - 1 do
          match !l with
          | Add (e, p, x) :: rest ->
            l := rest;
            if p < 0 || p >= np then raise Slow;
            let k = Array.unsafe_get kinds p in
            if k = 0 then raise Slow;
            let e =
              if e >= 0 then (if e < Schema.first_thing || e >= v0.next_e || k land 8 = 0 then raise Slow; e)
              else if e >= -nops then ((if -e > !deep then deep := -e); e)
              else (fl := e :: !fl; far)
            in
            let w =
              match k land 7, x with
              | 1, Int n | 2, Date n | 3, Money n -> n
              | 4, Bool b -> if b then 1 else 0
              | 5, Link t ->
                if t >= 0 then (if t < Schema.first_prop || t >= v0.next_e then raise Slow)
                else if t >= -nops && -t > !deep then deep := -t;
                t
              | 6, Text s -> text s
              | 7, Float f -> text (Store.float_key f)
              | _ -> raise Slow
            in
            Bigarray.Array1.unsafe_set fe i (Int32.of_int e);
            Bigarray.Array1.unsafe_set fp i p;
            Bigarray.Array1.unsafe_set fw i w
          | _ -> raise Slow
        done;
        fresh.(c) <- Array.of_list (List.rev !added);
        fars.(c) <- Array.of_list (List.rev !fl);
        deeps.(c) <- !deep);
    (* new things: numbered in order of first use, the thing of an operation before its link's target *)
    let deep = Array.fold_left max 0 deeps in
    let dense = Bulk.i32 (deep + 1) in
    Bigarray.Array1.fill dense (-1l);
    let farmap = Hashtbl.create 16 and next = ref v0.next_e in
    let see t =
      if t >= -deep then begin
        if Bigarray.Array1.unsafe_get dense (-t) < 0l then (Bigarray.Array1.unsafe_set dense (-t) (Int32.of_int !next); incr next)
      end
      else if not (Hashtbl.mem farmap t) then (Hashtbl.add farmap t !next; incr next)
    in
    for c = 0 to nch - 1 do
      let fl = fars.(c) and fi = ref 0 in
      for i = c * ch to min nops ((c + 1) * ch) - 1 do
        let x = Int32.to_int (Bigarray.Array1.unsafe_get fe i) in
        if x < 0 then if x = far then (see fl.(!fi); incr fi) else see x;
        if kinds.(Bigarray.Array1.unsafe_get fp i) land 7 = 5 then
          let t = Bigarray.Array1.unsafe_get fw i in
          if t < 0 then see t
      done
    done;
    (* past the last thing number: Resolve refuses it *)
    if !next - 1 > Schema.last_thing then raise Slow;
    (* new texts: numbered in order of first use, as [intern] would: their places k in that order, then their ids
       first + k *)
    let gtexts = Hashtbl.create (Array.fold_left (fun n a -> n + Array.length a) 16 fresh) and order = ref [] and m = ref 0 in
    let maps =
      Array.map
        (Array.map (fun s ->
             match Hashtbl.find_opt gtexts s with
             | Some k -> k
             | None -> let k = !m in Hashtbl.add gtexts s k; order := s :: !order; incr m; k))
        fresh
    in
    let news = Array.of_list (List.rev !order) in
    let v, first_text = Store.add_texts v0 news in
    Array.iter (fun map -> Array.iteri (fun j k -> map.(j) <- first_text + k) map) maps;
    Bulk.parallel nch (fun c ->
        let fl = fars.(c) and fi = ref 0 and map = maps.(c) in
        let id t = if t >= -deep then Int32.to_int (Bigarray.Array1.unsafe_get dense (-t)) else Hashtbl.find farmap t in
        for i = c * ch to min nops ((c + 1) * ch) - 1 do
          let x = Int32.to_int (Bigarray.Array1.unsafe_get fe i) in
          if x < 0 then
            Bigarray.Array1.unsafe_set fe i (Int32.of_int (if x = far then (let t = fl.(!fi) in incr fi; Hashtbl.find farmap t) else id x));
          let k = kinds.(Bigarray.Array1.unsafe_get fp i) land 7 in
          if k >= 5 then
            let t = Bigarray.Array1.unsafe_get fw i in
            if t < 0 then Bigarray.Array1.unsafe_set fw i (if k = 5 then id t else map.(-t - 1))
        done);
    (* the effective additions: a fact already there (an existing thing's) or added twice is no change; a new thing
       with two values for a one-valued property goes to [resolve]. Read in the order by thing, where the facts of a
       thing and property are together, and a fact twice keeps the group's order *)
    let sorted = Bulk.in_order fe fp fw nops in
    let order = if sorted then Bulk.i32 0 else Bulk.by_thing fe fp fw nops in
    let row r = if sorted then r else Int32.to_int (Bigarray.Array1.unsafe_get order r) in
    let thing i = Int32.to_int (Bigarray.Array1.unsafe_get fe i) in
    let drops = Array.make nch [] in
    Bulk.parallel nch (fun c ->
        let d = ref [] in
        for r = c * ch to min nops ((c + 1) * ch) - 1 do
          let i = row r in
          let e = thing i and p = Bigarray.Array1.unsafe_get fp i and w = Bigarray.Array1.unsafe_get fw i in
          if r > 0 then begin
            let j = row (r - 1) in
            if thing j = e && Bigarray.Array1.unsafe_get fp j = p then
              if Bigarray.Array1.unsafe_get fw j = w then d := i :: !d else if kinds.(p) land 8 = 0 then raise Slow
          end;
          if e < v0.next_e && Store.mem v0 e p w then begin
            (* a fact a rule derives already, asserted now: a change of its flag, for [resolve] *)
            if p < Bytes.length ruled && Bytes.unsafe_get ruled p <> '\000' && Store.state v0 e p w = 2 then raise Slow;
            d := i :: !d
          end
        done;
        drops.(c) <- !d);
    let count, sorted, order =
      if Array.for_all (fun d -> d = []) drops then nops, sorted, order
      else begin
        (* the facts kept, in the group's order *)
        let keep = Bytes.make nops '\001' in
        Array.iter (List.iter (fun i -> Bytes.unsafe_set keep i '\000')) drops;
        let k = ref 0 in
        for i = 0 to nops - 1 do
          if Bytes.unsafe_get keep i = '\001' then begin
            Bigarray.Array1.unsafe_set fe !k (Bigarray.Array1.unsafe_get fe i);
            Bigarray.Array1.unsafe_set fp !k (Bigarray.Array1.unsafe_get fp i);
            Bigarray.Array1.unsafe_set fw !k (Bigarray.Array1.unsafe_get fw i);
            incr k
          end
        done;
        let sorted = Bulk.in_order fe fp fw !k in
        !k, sorted, if sorted then Bulk.i32 0 else Bulk.by_thing fe fp fw !k
      end
    in
    (* the rules: the facts they derive from the group's, appended after them (Bulk.d0), in the order found *)
    let touches_rules =
      Bytes.length ruled > 0
      &&
      let t = ref false in
      for i = 0 to count - 1 do
        let p = Bigarray.Array1.unsafe_get fp i in
        if p < Bytes.length ruled && Bytes.unsafe_get ruled p <> '\000' then t := true
      done;
      !t
    in
    let v, fe, fp, fw, count, d0, sorted, order =
      if not touches_rules then v, fe, fp, fw, count, count, sorted, order
      else
        let rv = { v with next_e = !next } in
        (* the group's own texts are not in the dictionary's map yet: a rule's text the group adds is found here, so
           that a pattern on it matches, and a head that gives it does not intern it twice *)
        let own s = match Hashtbl.find_opt gtexts s with Some k -> Some (first_text + k) | None -> None in
        match (try Reason.bulk ~own rv fe fp fw count with Reason.Refused _ -> None) with
        | None -> raise Slow
        | Some (rv, de, dp, dw, nd) ->
          let n = count + nd in
          let fe' = Bulk.i32 n and fp' = Bulk.u16 n and fw' = Bulk.ints n in
          let blit a b = Bigarray.Array1.blit (Bigarray.Array1.sub a 0 count) (Bigarray.Array1.sub b 0 count) in
          let blit2 a b = Bigarray.Array1.blit a (Bigarray.Array1.sub b count nd) in
          blit fe fe'; blit fp fp'; blit fw fw';
          blit2 de fe'; blit2 dp fp'; blit2 dw fw';
          let sorted = Bulk.in_order fe' fp' fw' n in
          { rv with next_e = v.next_e }, fe', fp', fw', n, count, sorted, (if sorted then Bulk.i32 0 else Bulk.by_thing fe' fp' fw' n)
    in
    let b = Bulk.make ~d0 ~sorted ~order fe fp fw count ~np in
    (* a value two things take for a unique property, or one taken already: to [resolve] *)
    for q = 0 to np - 1 do
      match Schema.find v0.schema q with
      | Some d when d.unique ->
        let lo = b.poff.(q) and hi = b.poff.(q + 1) in
        Bulk.parallel (Bulk.chunks (hi - lo)) (fun c ->
            for r = lo + (c * ch) to min hi (lo + ((c + 1) * ch)) - 1 do
              let w = Bulk.pword b r in
              if r > lo && Bulk.pword b (r - 1) = w && Bulk.pthing b (r - 1) <> Bulk.pthing b r then raise Slow;
              if Store.count_things v0 q w > 0 then raise Slow
            done)
      | _ -> ()
    done;
    let first_new = v0.next_e and count_new = !next - v0.next_e in
    let view = { v with next_e = !next; group = n } in
    Some { view; facts = b; count; dense; farmap; n; time; by; why; first_new; count_new }
  with Slow -> None

(* The receipt's new things, (temporary id, number) in the order of numbering, as [resolve] lists them: a pair a new
   thing (2.4 M for a load of 10 M facts), made beside the merge, off the writer's way. *)
let receipt (l : large) =
  let tmp_of = Bulk.ints l.count_new in
  for t = 1 to Bigarray.Array1.dim l.dense - 1 do
    let x = Int32.to_int (Bigarray.Array1.unsafe_get l.dense t) in
    if x >= 0 then Bigarray.Array1.unsafe_set tmp_of (x - l.first_new) (-t)
  done;
  Hashtbl.iter (fun t x -> Bigarray.Array1.unsafe_set tmp_of (x - l.first_new) t) l.farmap;
  let temps = ref [] in
  for k = l.count_new - 1 downto 0 do temps := (Bigarray.Array1.unsafe_get tmp_of k, l.first_new + k) :: !temps done;
  !temps

(* The group of [l] as Group.encode codes it (one coding: Group.encode_source), from the large group's arrays: its
   changes in the group's order, the asserted ones then the derived (Bulk.d0); a property's column is its type's tag;
   the texts each once, in order of first use. *)
let encode_large (l : large) =
  let kinds = kinds l.view and b = l.facts in
  let np = Array.length kinds in
  let colmap = Array.make np (-1) and cols = ref [] and nc = ref 0 in
  let tags = [| -1; 0; 5; 6; 2; 7; 4; 1 |] in
  let loc = Bulk.i32 (max 1 b.n) and tl = ref [] and nt = ref 0 in
  (* the texts' places in order of first use: a table indexed by text id over the ids the group uses when that range
     is small (a load's: its own new texts and a few old ones), a hash table otherwise *)
  let lo = ref max_int and hi = ref min_int and ntext = ref 0 in
  for i = 0 to b.n - 1 do
    let p = Bulk.prop b i in
    if colmap.(p) < 0 then (colmap.(p) <- !nc; cols := (p, tags.(kinds.(p) land 7)) :: !cols; incr nc);
    if kinds.(p) land 7 = 6 then begin
      let w = Bulk.word b i in
      incr ntext;
      if w < !lo then lo := w;
      if w > !hi then hi := w
    end
  done;
  let place =
    if !ntext > 0 && !hi - !lo < max 65536 (4 * !ntext) then begin
      let lo = !lo in
      let t = Bulk.i32 (!hi - lo + 1) in
      Bigarray.Array1.fill t (-1l);
      fun w ->
        let k = Int32.to_int (Bigarray.Array1.unsafe_get t (w - lo)) in
        if k >= 0 then k else (let k = !nt in Bigarray.Array1.unsafe_set t (w - lo) (Int32.of_int k); tl := w :: !tl; incr nt; k)
    end
    else begin
      let texts = Hashtbl.create 4096 in
      fun w ->
        match Hashtbl.find_opt texts w with
        | Some k -> k
        | None -> let k = !nt in Hashtbl.add texts w k; tl := w :: !tl; incr nt; k
    end
  in
  for i = 0 to b.n - 1 do
    if kinds.(Bulk.prop b i) land 7 = 6 then Bigarray.Array1.unsafe_set loc i (Int32.of_int (place (Bulk.word b i)))
  done;
  let out = Buffer.create (16 + (4 * b.n)) in
  Group.encode_source out ~n:l.n ~time:l.time ~by:l.by ~why:l.why ~first_new:l.first_new ~count_new:l.count_new
    { count = b.n;
      kinds = (fun i -> if Bulk.derived b i then 2 else 1);
      things = (fun i -> Bulk.thing b i);
      col = (fun i -> Array.unsafe_get colmap (Bulk.prop b i));
      cols = Array.of_list (List.rev !cols);
      num = (fun i -> if Array.unsafe_get kinds (Bulk.prop b i) land 7 = 6 then Int32.to_int (Bigarray.Array1.unsafe_get loc i) else Bulk.word b i);
      float = (fun i -> String.get_int64_le (Store.text l.view (Bulk.word b i)) 0);
      texts = Array.of_list (List.rev_map (fun w -> Store.text l.view w) !tl) };
  out

(* A group from the journal that the faster path can replay: every change an addition, the asserted ones first and
   the derived after (a large group's frame), no system property (its additions are facts absent before it,
   distinct: Resolve records only effective changes) *)
let replay_large (v0 : Store.view) (g : Group.t) =
  let d0 =
    let k = ref 0 in
    while !k < Array.length g.changes && g.changes.(!k).kind = Added do incr k done;
    !k
  in
  if Array.length g.changes < !large_min
     || Array.exists (fun (c : Group.change) -> Schema.is_system c.p || Schema.find v0.schema c.p = None) g.changes
     || Array.exists (fun (c : Group.change) -> c.kind <> Derived) (Array.sub g.changes d0 (Array.length g.changes - d0))
  then None
  else begin
    let n = Array.length g.changes in
    let fe = Bulk.i32 n and fp = Bulk.u16 n and fw = Bulk.ints n in
    (* the texts the view has, by their ids; those it lacks by -(k + 1), k their place in order of first use, until
       they are added *)
    let texts = Hashtbl.create 4096 and order = ref [] and m = ref 0 in
    let text s =
      match Hashtbl.find_opt texts s with
      | Some w -> w
      | None ->
        let w = match Store.find_text v0 s with Some w -> w | None -> let k = !m in order := s :: !order; incr m; -k - 1 in
        Hashtbl.replace texts s w;
        w
    in
    Array.iteri
      (fun i (c : Group.change) ->
        Bigarray.Array1.unsafe_set fe i (Int32.of_int c.e);
        Bigarray.Array1.unsafe_set fp i c.p;
        Bigarray.Array1.unsafe_set fw i (match c.v with
            | Int n | Date n | Money n | Link n -> n
            | Bool b -> if b then 1 else 0
            | Text s -> text s
            | Float f -> text (Store.float_key f)))
      g.changes;
    let news = Array.of_list (List.rev !order) in
    let v, first = Store.add_texts v0 news in
    let kinds = kinds v0 in
    for i = 0 to n - 1 do
      let w = Bigarray.Array1.unsafe_get fw i in
      if w < 0 && kinds.(Bigarray.Array1.unsafe_get fp i) land 7 >= 6 then Bigarray.Array1.unsafe_set fw i (first - w - 1)
    done;
    let sorted = Bulk.in_order fe fp fw n in
    let order = if sorted then Bulk.i32 0 else Bulk.by_thing fe fp fw n in
    let facts = Bulk.make ~d0 ~sorted ~order fe fp fw n ~np:(Schema.count v0.schema) in
    Some ({ v with next_e = max v0.next_e (g.first_new + g.count_new); group = g.n }, facts)
  end

(* ---- a new database, and a schema's declarations: one coding for the engine, its forks and the clients ---- *)

(* the facts of the system properties, the first group of every database *)
let bootstrap_ops =
  List.concat_map
    (fun p ->
      match Schema.system.(p) with
      | Some d -> List.map (fun (e, q, x) -> Add (e, q, x)) (Schema.facts p d)
      | None -> [])
    [ 1; 2; 3; 4; 5 ]

(* the empty state with only the system properties *)
let empty =
  match resolve ~bootstrap:true (Store.empty ()) ~n:1 ~time:0 ~by:0 ~why:"cepheus: create" bootstrap_ops with
  | Ok (v, _, _) -> v
  | Error _ -> assert false

(* The property ids for these names on [v], and the operations that declare the missing ones (each with an Expect
   that its id is still free, so that a declaration that lost a race for an id is refused and made again); Error for
   a name declared already with another type, cardinality or unique flag. *)
let declare (v : Store.view) (props : Schema.prop list) =
  let next = ref Schema.first_prop in
  let free () =
    while Schema.find v.schema !next <> None || Store.has_value v !next Schema.p_name do incr next done;
    let p = !next in
    incr next;
    p
  in
  let ops = ref [] and ids = ref [] and bad = ref None in
  List.iter
    (fun (d : Schema.prop) ->
      match Schema.by_name v.schema d.name with
      | Some p ->
        let cur = Option.get (Schema.find v.schema p) in
        if cur.typ <> d.typ || cur.many <> d.many || cur.unique <> d.unique then
          bad := Some (Printf.sprintf "%s is declared already as another kind of property" d.name);
        ids := p :: !ids
      | None ->
        let p = free () in
        ids := p :: !ids;
        ops := Expect (p, Schema.p_name, None) :: !ops;
        List.iter (fun (e, q, x) -> ops := Add (e, q, x) :: !ops) (Schema.facts p d))
    props;
  match !bad with Some m -> Error m | None -> Ok (List.rev !ids, List.rev !ops)
