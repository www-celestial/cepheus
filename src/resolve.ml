(* From what a client asks to what the journal keeps. One function, used by the writer of a database and by every
   fork, so a fork accepts and refuses exactly what the database would (G8). Checks: types, things that exist,
   one value for a one-valued property (the old value is retracted in the same group), unique values, Expect
   (checked against the state before the group), links that name a kind (their things, and what they do when such a
   thing stops being of the kind), and the schema rules for property things. *)

type op =
  | Add of int * int * Value.t
  | Retract of int * int * Value.t
  | Expect of int * int * Value.t option
  | Incr of int * int * int * (int * int) option
  | Delete of int * string

type error = Conflict of string | Invalid of string | Not_unique of string

exception Fail of error

let fail e = raise (Fail e)
let invalid fmt = Printf.ksprintf (fun s -> fail (Invalid s)) fmt

(* What a schema thing is, from its facts in v: a property (a name and a type), a rule (a name and a definition), or
   nothing yet. *)
type thing = Prop of Schema.prop * Schema.link option | Rule of string * string | Nothing

let read_thing (v : Store.view) p =
  let one q = let r = ref None in Store.iter_values v p q (fun w -> r := Some w); !r in
  let has_link () = Store.has_value v p Schema.p_to || Store.has_value v p Schema.p_delete in
  match one Schema.p_name, one Schema.p_type, one Schema.p_rule with
  | Some nw, Some tw, None -> (
    match Value.of_code tw with
    | None -> Error (Printf.sprintf "property %d has an unknown type code %d" p tw)
    | Some typ -> (
      let flag q = match one q with Some w -> w <> 0 | None -> false in
      let d = { Schema.name = Store.text v nw; typ; many = flag Schema.p_many; unique = flag Schema.p_unique } in
      match one Schema.p_to, one Schema.p_delete with
      | None, None -> Ok (Prop (d, None))
      | None, Some _ -> Error (Printf.sprintf "%s has cepheus/delete without cepheus/to, the kind it links to" d.name)
      | Some kw, dw -> (
        let kind = Store.text v kw in
        if typ <> Value.Tlink then Error (Printf.sprintf "%s is a %s: cepheus/to is for a link" d.name (Value.typ_name typ))
        else if kind = "" || String.contains kind '/' then
          Error (Printf.sprintf "%s: cepheus/to is the name of a kind, without '/', not %S" d.name kind)
        else
          match dw with
          | None -> Ok (Prop (d, Some { Schema.kind; on_delete = Refuse }))
          | Some dw -> (
            match Schema.on_delete_of (Store.text v dw) with
            | Some on_delete -> Ok (Prop (d, Some { Schema.kind; on_delete }))
            | None -> Error (Printf.sprintf "%s: cepheus/delete is refuse, cascade or clear, not %S" d.name (Store.text v dw))))))
  | Some nw, None, Some rw ->
    if Store.has_value v p Schema.p_many || Store.has_value v p Schema.p_unique || has_link () then
      Error (Printf.sprintf "rule %d takes a name and a definition only" p)
    else Ok (Rule (Store.text v nw, Store.text v rw))
  | None, None, None ->
    if Store.has_value v p Schema.p_many || Store.has_value v p Schema.p_unique then
      Error (Printf.sprintf "property %d keeps cepheus/many or cepheus/unique without a name and a type" p)
    else if has_link () then Error (Printf.sprintf "property %d keeps cepheus/to or cepheus/delete without a name and a type" p)
    else Ok Nothing
  | _, _, Some _ -> Error (Printf.sprintf "rule %d needs a name and a definition, and no type" p)
  | _ -> Error (Printf.sprintf "property %d needs both a name and a type" p)

let install_thing schema p = function
  | Ok (Prop (d, l)) -> Schema.set_rule (Schema.set_link (Schema.set schema p (Some d)) p l) p None
  | Ok (Rule (n, t)) -> Schema.set_rule (Schema.set_link (Schema.set schema p None) p None) p (Some (n, t))
  | Ok Nothing | Error _ -> Schema.set_rule (Schema.set_link (Schema.set schema p None) p None) p None

let refresh (v : Store.view) p = { v with schema = install_thing v.schema p (read_thing v p) }

let desc (v : Store.view) p =
  match Schema.find v.schema p with Some d -> d | None -> invalid "no property %d" p

(* Is x a thing of kind k (its number in the index): has it a fact of one of the kind's properties that a write
   asserted? A fact only derived makes no thing of a kind. *)
exception Has
exception Found_thing of int

let is_kind (v : Store.view) (ix : Schema.index) x k =
  x >= Schema.first_thing
  && k >= 0
  && (try
        Array.iter
          (fun p -> if Store.has_value v x p then Store.iter_values_st v x p (fun _ st -> if st = 1 then raise_notrace Has))
          ix.members.(k);
        false
      with Has -> true)

(* the name of a link property, the kind of its things: invoice/Client, invoice *)
let prop_name (v : Store.view) p = match Schema.find v.schema p with Some d -> d.name | None -> string_of_int p

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

(* Facts to retract together: their things, properties and words, asserted in the view they were read from *)
module Facts = struct
  type t = { mutable e : int array; mutable p : int array; mutable w : int array; mutable n : int }

  let create () = { e = Array.make 64 0; p = Array.make 64 0; w = Array.make 64 0; n = 0 }

  let push t e p w =
    if t.n = Array.length t.e then begin
      let grow a = let b = Array.make (2 * t.n) 0 in Array.blit a 0 b 0 t.n; b in
      t.e <- grow t.e; t.p <- grow t.p; t.w <- grow t.w
    end;
    t.e.(t.n) <- e; t.p.(t.n) <- p; t.w.(t.n) <- w;
    t.n <- t.n + 1

  (* the view with them all retracted, as one retraction after the other leaves it: in the order of (thing,
     property, word) that Store.set_sorted takes, each asserted (state 1) before *)
  let retract t (v : Store.view) =
    let n = t.n in
    if n = 0 then v
    else begin
      (* the linking things come in the order of their ids, each one's facts by property and value: in order
         already, most often *)
      let sorted = ref true and i = ref 1 in
      while !sorted && !i < n do
        let j = !i - 1 in
        let c = compare (t.e.(j) : int) t.e.(!i) in
        let c = if c <> 0 then c else compare (t.p.(j) : int) t.p.(!i) in
        if (if c <> 0 then c else compare (t.w.(j) : int) t.w.(!i)) >= 0 then sorted := false;
        incr i
      done;
      let o = if !sorted then [||] else Store.fact_order t.e t.p t.w n in
      let pick a = if !sorted then Array.sub a 0 n else Array.init n (fun i -> a.(o.(i))) in
      Store.set_sorted ~olds:(Array.make n 1) v (pick t.e) (pick t.p) (pick t.w) (Array.make n 0) n
    end
end

(* [reason]: what the rules make of the group's asserted changes (Reason.run; the background path of a change gives
   its own, Engine) *)
let resolve ?(bootstrap = false) ?(reason = fun ~v0 v changes words -> Reason.run ~v0 v changes words) (v0 : Store.view) ~n ~time ~by ~why ops =
  try
    (* new things: negative ids, numbered in order of first use *)
    let temps = Hashtbl.create 4 and order = ref [] in
    let next = ref v0.next_e in
    let see x = if x < 0 && not (Hashtbl.mem temps x) then (Hashtbl.replace temps x !next; order := x :: !order; incr next) in
    List.iter
      (function
        | Add (e, _, x) | Retract (e, _, x) -> see e; (match x with Value.Link t -> see t | _ -> ())
        | Expect (e, _, _) -> if e < 0 then invalid "Expect on a new thing"
        | Incr (e, _, _, into) -> see e; (match into with Some (t, _) -> see t | None -> ())
        | Delete (e, _) -> if e < 0 then invalid "Delete of a new thing")
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
    let add e p x =
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
    in
    (* Delete, and the links followed when a thing stops being of a kind: the facts they read and retract, at most the
       work budget of a group of this many operations (as the rules' work: Reason.work_per x its budget) *)
    let work = ref 0 and wlimit = Reason.work_limit (!Reason.budget_base + (!Reason.budget_per * List.length ops)) in
    let tick what =
      incr work;
      if !work > wlimit then
        invalid "%s: the links followed passed %d facts, the work budget of a group of %d operations: delete the things that link to it first, in groups of their own" (what ()) wlimit (List.length ops)
    in
    (* the asserted facts of thing e of kind k (its number in [ix]), retracted at this point of the group *)
    let retract_kind ix e k what =
      Array.iter
        (fun p ->
          if Store.has_value !v e p then begin
            let d = desc !v p and ws = ref [] in
            Store.iter_values_st !v e p (fun w st -> if st = 1 then ws := w :: !ws);
            List.iter (fun w -> tick what; assert_word false e p (Store.value !v d.typ w) !v w) (List.rev !ws)
          end)
        ix.Schema.members.(k)
    in
    (* Incr's properties: ints of the program's, the counter's one-valued *)
    let int_prop what ~one p =
      let d = desc !v p in
      if Schema.is_system p || (one && d.many) || d.typ <> Value.Tint then
        invalid "Incr %s %s int property of the program's: %s is %s" what (if one then "a one-valued" else "an") d.name
          (if Schema.is_system p then "the database's own" else if d.typ <> Value.Tint then "a " ^ Value.typ_name d.typ else "many-valued");
      d
    in
    List.iter
      (function
        | Add (e, p, x) -> add (id e) p (match x with Value.Link t -> Value.Link (id t) | x -> x)
        | Incr (e, p, by, into) ->
          (* the counter's value at this point of the group (none counts 0), grown by [by] exactly: a sum past the
             ints refuses the group; then written as an Add would, and into [into] *)
          let e = id e in
          let d = int_prop "counts on" ~one:true p in
          check_thing e p;
          let old = ref 0 in
          Store.iter_values !v e p (fun w -> match Store.value !v d.typ w with Value.Int n -> old := n | _ -> ());
          let old = !old in
          if (by > 0 && old > max_int - by) || (by < 0 && old < min_int - by) then
            invalid "Incr: %s of #%d is %d, and %d more passes the ints" d.name e old by;
          let x = Value.Int (old + by) in
          add e p x;
          Option.iter (fun (t, q) -> ignore (int_prop "writes into" ~one:false q); add (id t) q x) into
        | Retract (e, p, x) ->
          let e = id e and x = (match x with Value.Link t -> Value.Link (id t) | x -> x) in
          let d = desc !v p in
          check_thing e p;
          if not (Value.has_type d.typ x) then invalid "%s is not a %s (property %s)" (Value.to_string x) (Value.typ_name d.typ) d.name;
          assert_retract e p x
        | Delete (e, k) ->
          let ix = Schema.index !v.schema in
          let ki = Schema.kind_id ix k in
          if e < Schema.first_thing || e >= !next then invalid "Delete: no thing #%d" e;
          if ki < 0 || Array.length ix.members.(ki) = 0 then invalid "Delete: the kind %s has no property in this database" k;
          retract_kind ix e ki (fun () -> Printf.sprintf "deleting the %s #%d" k e)
        | Expect _ -> ())
      ops;
    (* links that name a kind: what their facts do when the thing they link to stops being of it, and the things
       they link to after the group *)
    if Schema.has_links !v.schema then begin
      let ix = Schema.index !v.schema in
      (* the things that lost an asserted fact of a kind some link names, followed in order: a thing no longer of
         the kind is lost, and each link to it does what its property says: cascade deletes the linking thing in its
         own kind (a thing reached twice is followed once: cycles end), clear retracts the link, refuse leaves it to
         the check below *)
      let queue = Queue.create () in
      List.iter (fun (c : Group.change) -> if c.kind = Retracted && Schema.named ix c.p then Queue.push (c.e, ix.pkind.(c.p)) queue) !out;
      if not (Queue.is_empty queue) then begin
        let seen = Hashtbl.create 16 and lost = ref [] in
        while not (Queue.is_empty queue) do
          let ((x, k) as xk) = Queue.pop queue in
          if not (Hashtbl.mem seen xk) then begin
            Hashtbl.add seen xk ();
            if not (is_kind !v ix x k) then begin
              lost := xk :: !lost;
              Array.iter
                (fun (l, od) ->
                  if od <> Schema.Refuse then begin
                    let lk = ix.pkind.(l) in
                    let what () = Printf.sprintf "deleting the %s #%d (%s: %s)" ix.kinds.(k) x (prop_name !v l) (Schema.on_delete_name od) in
                    let ys = ref [] in
                    Store.iter_things !v l x (fun y -> ys := y :: !ys);
                    (* the facts the linking things lose, read in the view before any of them goes (each thing's
                       own facts, which no other linking thing's retraction touches) and retracted together at the
                       end (Store.set_sorted: one walk of the maps a thing and a value, where a retraction one by one
                       walks both for each fact); the group's changes in the order of before *)
                    let batch = Facts.create () in
                    let gather e p x w = out := { Group.kind = Retracted; e; p; v = x } :: !out; outw := w :: !outw; Facts.push batch e p w in
                    List.iter
                      (fun y ->
                        tick what;
                        if Store.state !v y l x = 1 then begin
                          (match od with
                           | Schema.Clear -> gather y l (Value.Link x) x
                           | _ ->
                             Array.iter
                               (fun p ->
                                 if Store.has_value !v y p then begin
                                   let d = desc !v p and ws = ref [] in
                                   Store.iter_values_st !v y p (fun w st -> if st = 1 then ws := w :: !ws);
                                   List.iter (fun w -> tick what; gather y p (Store.value !v d.typ w) w) (List.rev !ws)
                                 end)
                               ix.Schema.members.(lk));
                          if Schema.named ix l then Queue.push (y, lk) queue
                        end)
                      (List.rev !ys);
                    v := Facts.retract batch !v
                  end)
                ix.linkers.(k)
            end
          end
        done;
        (* a link left to a thing no longer of its kind: refused, naming one *)
        List.iter
          (fun (x, k) ->
            Array.iter
              (fun (l, _) ->
                match Store.iter_things !v l x (fun y -> raise_notrace (Found_thing y)) with
                | () -> ()
                | exception Found_thing y ->
                  invalid "the %s #%d cannot be deleted while the %s #%d links to it (%s: refuse)" ix.kinds.(k) x
                    ix.kinds.(ix.pkind.(l)) y (prop_name !v l))
              ix.linkers.(k))
          (List.rev !lost)
      end;
      (* a link added: to a thing of its kind after the group *)
      List.iter
        (fun (c : Group.change) ->
          if c.kind = Added && c.p < Array.length ix.pto && ix.pto.(c.p) >= 0 then
            match c.v with
            | Value.Link t ->
              let k = ix.pto.(c.p) in
              if not (is_kind !v ix t k) then invalid "%s links to %s things only, and #%d is not one" (prop_name !v c.p) ix.kinds.(k) t
            | _ -> ())
        !out
    end;
    let changes = Array.of_list (List.rev !out) in
    (* the schema things this group touched: properties checked below, rules here, before they run *)
    let touched = Hashtbl.create 2 in
    Array.iter (fun (c : Group.change) -> if Schema.is_prop_space c.e then Hashtbl.replace touched c.e ()) changes;
    Hashtbl.iter
      (fun p () ->
        match read_thing !v p, Schema.find v0.schema p, Schema.rule v0.schema p with
        | Error m, _, _ -> invalid "%s" m
        | Ok (Rule _), Some a, _ -> invalid "%s is a property: it never becomes a rule" a.name
        | Ok (Prop (d, _)), _, Some _ -> invalid "a rule never becomes a property (%s)" d.name
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
      (* a link that names a kind is written only: its things are checked at the write that gives it *)
      List.iter
        (fun (r : Rules.t) ->
          match r.head with
          | Rules.Give h when h.p >= 0 && Schema.link !v.schema h.p <> None ->
            invalid "rule %s gives %s, a link that names a kind: no rule gives one" r.name (prop_name !v h.p)
          | _ -> ())
        rules;
      (* a template's list changes by writes only: no rule gives it *)
      let lists = List.concat_map (fun (r : Rules.t) -> List.filter_map (fun (a : Query.pattern) -> if Rules.is_every a.p then Some (Rules.every_of a.p, r.name) else None) r.where) rules in
      List.iter
        (fun (r : Rules.t) ->
          match r.head with
          | Rules.Give h when h.p >= 0 && List.mem_assoc h.p lists ->
            let name = match Schema.find !v.schema h.p with Some d -> d.name | None -> string_of_int h.p in
            invalid "rule %s gives %s, the list of the template %s: only a write may change a list" r.name name (List.assoc h.p lists)
          | _ -> ())
        rules;
      (* equality and negation or aggregates in one rule set: not yet (a Not or an aggregate would read the state of
         things that rewriting moves) *)
      if List.exists (fun (r : Rules.t) -> match r.head with Rules.Give h -> h.p = Schema.p_same | Never -> false) rules
         && not (List.for_all Rules.is_plain rules)
      then invalid "a rule set that makes things the same takes no Not and no aggregate yet";
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
      match reason ~v0 !v changes (Array.of_list (List.rev !outw)) with
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
    (* a link that names a kind for the first time, or another: every value it has is a thing of that kind *)
    Hashtbl.iter
      (fun p () ->
        match Schema.link v.schema p with
        | Some l when (match Schema.link v0.schema p with Some l0 -> l0.kind <> l.kind | None -> true) ->
          let ix = Schema.index v.schema in
          let k = Schema.kind_id ix l.kind and name = prop_name v p in
          if k < 0 || Array.length ix.members.(k) = 0 then invalid "%s links to the kind %s, which has no property" name l.kind;
          Store.iter_prop v p (fun e w ->
              if not (is_kind v ix w k) then invalid "%s cannot link to %s things only: #%d links to #%d, which is not one" name l.kind e w)
        | _ -> ())
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

(* A change's catch-up (the background path, Engine): the groups [gs], resolved by the writer under the old rules, oldest
   first, applied to [v], a view under the new rules, at once: their net asserted changes (a fact's asserted state
   before the first of them and after the last; their kinds found again against [v]), then the new rules'
   consequences (Reason.run), the derived changes they had under the old rules dropped. Only the state after the last
   group matters to the change (its derived facts are a function of the asserted ones: the least model), and every
   check runs on that state (a constraint, one value, a unique value: a failure raises [Fail], and the change ends with
   Conflict); the states between, under the old rules, are not the new rules' to judge. [d]: a view of the writer
   after the groups, whose dictionary has every text of theirs (the background interns none of its own). *)
let catch_up ?limit ?stop (v : Store.view) (d : Store.view) (gs : Group.t list) =
  try
    let next = List.fold_left (fun n (g : Group.t) -> max n (g.first_new + g.count_new)) v.next_e gs in
    let v0 = { v with dict = d.dict; next_e = next } in
    (* each fact's asserted state before the first change and after the last, in the order first met *)
    let net = Hashtbl.create 256 and order = ref [] in
    List.iter
      (fun (g : Group.t) ->
        Array.iter
          (fun (c : Group.change) ->
            match c.kind with
            | Derived | Underived -> ()
            | _ when c.p = Schema.p_rule ->
              (* one change at a time: a change made in its group meanwhile (it makes new things) comes first *)
              fail (Conflict (Printf.sprintf "group %d, written meanwhile, changed the rules" g.n))
            | k -> (
              match Store.word v0 c.v with
              | None -> fail (Conflict "a text of a group written meanwhile is not in the change's view")
              | Some w ->
                let key = (c.e, c.p, w) and after = Group.after k = 1 in
                match Hashtbl.find_opt net key with
                | Some (b, _, x) -> Hashtbl.replace net key (b, after, x)
                | None ->
                  let before = match k with Retracted | Now_derived -> true | _ -> false in
                  Hashtbl.replace net key (before, after, c.v);
                  order := key :: !order))
          g.changes)
      gs;
    let v = ref v0 and out = ref [] and outw = ref [] in
    List.iter
      (fun ((e, p, w) as key) ->
        let before, after, x = Hashtbl.find net key in
        if before <> after then begin
          let v1, prev = Store.swap !v e p w (if after then 1 else 0) in
          let kind : Group.kind =
            match after, prev with
            | true, 0 -> Added
            | true, 2 -> Now_asserted
            | false, 1 -> Retracted
            | _ -> fail (Conflict "a fact the groups written meanwhile assert or retract has another state in the change's view")
          in
          v := if Schema.is_system p && Schema.is_prop_space e then refresh v1 e else v1;
          out := { Group.kind; e; p; v = x } :: !out;
          outw := w :: !outw
        end)
      (List.rev !order);
    let changes = Array.of_list (List.rev !out) in
    let v, changes =
      match Reason.run ?limit ?stop ~v0 !v changes (Array.of_list (List.rev !outw)) with
      | r -> r
      | exception Reason.Refused m -> fail (Conflict m)
    in
    (* links that name a kind, under the change's schema (the writer checked the groups against its own): every link
       they added goes to a thing of its kind, and none is left to a thing that stopped being of it *)
    if Schema.has_links v.schema then begin
      let ix = Schema.index v.schema in
      Array.iter
        (fun (c : Group.change) ->
          match c.kind with
          | (Added | Now_asserted) when c.p < Array.length ix.pto && ix.pto.(c.p) >= 0 -> (
            match c.v with
            | Value.Link t when not (is_kind v ix t ix.pto.(c.p)) ->
              fail (Conflict (Printf.sprintf "a group written meanwhile links %s of #%d to #%d, which is no %s thing under the change" (prop_name v c.p) c.e t ix.kinds.(ix.pto.(c.p))))
            | _ -> ())
          | Retracted when Schema.named ix c.p && not (is_kind v ix c.e ix.pkind.(c.p)) ->
            Array.iter
              (fun (l, _) ->
                match Store.iter_things v l c.e (fun y -> raise_notrace (Found_thing y)) with
                | () -> ()
                | exception Found_thing y ->
                  fail (Conflict (Printf.sprintf "a group written meanwhile leaves #%d linked by %s to #%d, which is no %s thing any more" y (prop_name v l) c.e ix.kinds.(ix.pkind.(c.p)))))
              ix.linkers.(ix.pkind.(c.p))
          | _ -> ())
        changes
    end;
    (* the checks of one value and of unique values, for the asserted additions too: the writer checked them under
       the old rules *)
    Array.iter
      (fun (c : Group.change) ->
        match c.kind with
        | Added | Now_asserted | Derived -> (
          match Schema.find v.schema c.p, Store.word v c.v with
          | Some d, Some w ->
            if (not d.many) && Store.count_values v c.e c.p > 1 then
              fail (Conflict (Printf.sprintf "#%d would have two values of %s under the new rules" c.e d.name));
            if d.unique && Store.count_things v c.p w > 1 then
              fail (Conflict (Printf.sprintf "%s %s would be taken twice under the new rules" d.name (Value.to_string c.v)))
          | _ -> ())
        | _ -> ())
      changes;
    let last = List.fold_left (fun n (g : Group.t) -> max n g.n) v.group gs in
    Ok ({ v with group = last }, changes)
  with Fail e -> Error e

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
  nows : (int * int * int) array;  (* facts derived already that the group asserts (kind Now_asserted), in its order:
                                      in the view's delta, merged into the run with it; the frame's first changes *)
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
    (* the strings hashed by the chunks' domains at once, then placed in order in a table of open addressing (a
       load's 600,000 texts: 0.2 s through a Hashtbl, its hashing and its buckets, on one domain) *)
    let total = Array.fold_left (fun n a -> n + Array.length a) 0 fresh in
    let hs = Array.map (fun a -> Array.make (Array.length a) 0) fresh in
    Bulk.parallel nch (fun c -> let a = fresh.(c) and h = hs.(c) in for j = 0 to Array.length a - 1 do h.(j) <- Hashtbl.hash a.(j) done);
    let size = let z = ref 16 in while !z < 2 * total do z := 2 * !z done; !z in
    let mask = size - 1 in
    let slot_k = Array.make size (-1) and slot_h = Array.make size 0 and news = Array.make total "" and m = ref 0 in
    (* the slot of string s (hash h): its own, or the empty one where it goes *)
    let slot s h =
      let i = ref (h land mask) in
      while (let k = Array.unsafe_get slot_k !i in k >= 0 && not (Array.unsafe_get slot_h !i = h && String.equal (Array.unsafe_get news k) s)) do
        i := (!i + 1) land mask
      done;
      !i
    in
    let maps =
      Array.mapi
        (fun c a ->
          Array.mapi
            (fun j s ->
              let h = hs.(c).(j) in
              let i = slot s h in
              let k = Array.unsafe_get slot_k i in
              if k >= 0 then k
              else begin
                let k = !m in
                Array.unsafe_set slot_k i k;
                Array.unsafe_set slot_h i h;
                Array.unsafe_set news k s;
                incr m;
                k
              end)
            a)
        fresh
    in
    let news = Array.sub news 0 !m in
    let gtext s = let k = Array.unsafe_get slot_k (slot s (Hashtbl.hash s)) in if k >= 0 then Some k else None in
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
    let drops = Array.make nch [] and nows = Array.make nch [] in
    Bulk.parallel nch (fun c ->
        let d = ref [] and nw = ref [] in
        for r = c * ch to min nops ((c + 1) * ch) - 1 do
          let i = row r in
          let e = thing i and p = Bigarray.Array1.unsafe_get fp i and w = Bigarray.Array1.unsafe_get fw i in
          let twice =
            r > 0
            &&
            let j = row (r - 1) in
            thing j = e && Bigarray.Array1.unsafe_get fp j = p
            && (Bigarray.Array1.unsafe_get fw j = w || (if kinds.(p) land 8 = 0 then raise Slow else false))
          in
          if twice then d := i :: !d
          else if e < v0.next_e && Store.mem v0 e p w then begin
            (* a fact a rule derives already, asserted now: its flag changes (kind Now_asserted), in the delta *)
            if Store.state v0 e p w = 2 then nw := i :: !nw;
            d := i :: !d
          end
        done;
        drops.(c) <- !d;
        nows.(c) <- !nw);
    let nows =
      let l = List.sort compare (List.concat (Array.to_list nows)) in
      Array.of_list (List.map (fun i -> thing i, Bigarray.Array1.unsafe_get fp i, Bigarray.Array1.unsafe_get fw i) l)
    in
    let v = Array.fold_left (fun v (e, p, w) -> Store.set v e p w 1) v nows in
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
    let b = Bulk.make ~sorted ~order fe fp fw count ~np in
    (* a value two things take for a unique property, or one taken already: to [resolve] (the derived facts of a
       unique property are counted by Reason.bulk) *)
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
    (* a link that names a kind: to a thing of it before the group, or to a new thing the group gives a fact of it;
       anything else (an old thing that becomes one in the group, or a refusal) to [resolve] *)
    if Schema.has_links v0.schema then begin
      let ix = Schema.index v0.schema in
      let nnew = !next - v0.next_e in
      (* by kind: the new things the group gives a fact of it, a bit each, made at its first link *)
      let news = Hashtbl.create 4 in
      let fresh k =
        match Hashtbl.find_opt news k with
        | Some s -> s
        | None ->
          let s = Bytes.make ((nnew lsr 3) + 1) '\000' in
          Array.iter
            (fun q ->
              if q < np then
                for r = b.poff.(q) to b.poff.(q + 1) - 1 do
                  let e = Bulk.pthing b r - v0.next_e in
                  if e >= 0 then Bytes.unsafe_set s (e lsr 3) (Char.unsafe_chr (Char.code (Bytes.unsafe_get s (e lsr 3)) lor (1 lsl (e land 7))))
                done)
            ix.members.(k);
          Hashtbl.add news k s;
          s
      in
      for q = 0 to min np (Array.length ix.pto) - 1 do
        let k = ix.pto.(q) in
        if k >= 0 && b.poff.(q + 1) > b.poff.(q) then begin
          let s = fresh k in
          for r = b.poff.(q) to b.poff.(q + 1) - 1 do
            let t = Bulk.pword b r in
            let ok =
              if t >= v0.next_e then (let e = t - v0.next_e in Char.code (Bytes.unsafe_get s (e lsr 3)) land (1 lsl (e land 7)) <> 0)
              else is_kind v0 ix t k
            in
            if not ok then raise Slow
          done
        end
      done
    end;
    (* the rules: the facts they derive from the group's, appended after them (Bulk.d0) *)
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
    let v, b =
      if not touches_rules then v, b
      else
        let rv = { v with next_e = !next } in
        (* the group's own texts are not in the dictionary's map yet: a rule's text the group adds is found here, so
           that a pattern on it matches, and a head that gives it does not intern it twice *)
        let own s = match gtext s with Some k -> Some (first_text + k) | None -> None in
        match (try Reason.bulk ~own ~first_new:v0.next_e rv b with Reason.Refused _ -> None) with
        | None -> raise Slow
        | Some (rv, de, dp, dw, nd) ->
          let b = Bulk.add_derived b de dp dw nd ~np in
          { rv with next_e = v.next_e }, b
    in
    let first_new = v0.next_e and count_new = !next - v0.next_e in
    let view = { v with next_e = !next; group = n } in
    Some { view; facts = b; count; dense; farmap; n; time; by; why; first_new; count_new; nows }
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
  (* change j: the facts asserted again first (Now_asserted), then the group's facts and the derived ones *)
  let m = Array.length l.nows in
  let count = m + b.n in
  let te j = if j < m then (let e, _, _ = l.nows.(j) in e) else Bulk.thing b (j - m)
  and tp j = if j < m then (let _, p, _ = l.nows.(j) in p) else Bulk.prop b (j - m)
  and tw j = if j < m then (let _, _, w = l.nows.(j) in w) else Bulk.word b (j - m) in
  let colmap = Array.make np (-1) and cols = ref [] and nc = ref 0 in
  let tags = [| -1; 0; 5; 6; 2; 7; 4; 1 |] in
  let loc = Bulk.i32 (max 1 count) and tl = ref [] and nt = ref 0 in
  (* the texts' places in order of first use: a table indexed by text id over the ids the group uses when that range
     is small (a load's: its own new texts and a few old ones), a hash table otherwise *)
  let lo = ref max_int and hi = ref min_int and ntext = ref 0 in
  for j = 0 to count - 1 do
    let p = tp j in
    if colmap.(p) < 0 then (colmap.(p) <- !nc; cols := (p, tags.(kinds.(p) land 7)) :: !cols; incr nc);
    if kinds.(p) land 7 = 6 then begin
      let w = tw j in
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
  for j = 0 to count - 1 do
    if kinds.(tp j) land 7 = 6 then Bigarray.Array1.unsafe_set loc j (Int32.of_int (place (tw j)))
  done;
  let out = Buffer.create (16 + (4 * count)) in
  Group.encode_source out ~n:l.n ~time:l.time ~by:l.by ~why:l.why ~first_new:l.first_new ~count_new:l.count_new
    { count;
      kinds = (fun j -> if j < m then Group.code Now_asserted else if Bulk.derived b (j - m) then 2 else 1);
      things = te;
      col = (fun j -> Array.unsafe_get colmap (tp j));
      cols = Array.of_list (List.rev !cols);
      num = (fun j -> if Array.unsafe_get kinds (tp j) land 7 = 6 then Int32.to_int (Bigarray.Array1.unsafe_get loc j) else tw j);
      float = (fun j -> String.get_int64_le (Store.text l.view (tw j)) 0);
      texts = Array.of_list (List.rev_map (fun w -> Store.text l.view w) !tl) };
  out

(* A group from the journal that the faster path can replay: every change an addition, the asserted ones first and
   the derived after (a large group's frame), no system property (its additions are facts absent before it,
   distinct: Resolve records only effective changes) *)
let replay_large (v0 : Store.view) (g : Group.t) =
  (* facts derived already that the group asserted first (Now_asserted), into the delta *)
  let k0 =
    let k = ref 0 in
    while !k < Array.length g.changes && g.changes.(!k).kind = Now_asserted do incr k done;
    !k
  in
  let d0 =
    let k = ref k0 in
    while !k < Array.length g.changes && g.changes.(!k).kind = Added do incr k done;
    !k
  in
  if Array.length g.changes - k0 < !large_min
     || Array.exists (fun (c : Group.change) -> Schema.is_system c.p || Schema.find v0.schema c.p = None) g.changes
     || Array.exists (fun (c : Group.change) -> c.kind <> Derived) (Array.sub g.changes d0 (Array.length g.changes - d0))
     || Array.exists (fun (c : Group.change) -> Store.word v0 c.v = None) (Array.sub g.changes 0 k0)
  then None
  else begin
    let v0 =
      Array.fold_left (fun v (c : Group.change) -> Store.set v c.e c.p (Option.get (Store.word v c.v)) 1) v0 (Array.sub g.changes 0 k0)
    in
    let g = { g with changes = Array.sub g.changes k0 (Array.length g.changes - k0) } in
    let d0 = d0 - k0 in
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

(* The operations that make link properties name kinds: (id, name, link), [current] the link each names now (None for
   one declared in the same group). One that names none gets its two facts, with an Expect that it still names none
   (a declaration that lost a race is refused, and read again); one that names another kind, or the same with
   another on_delete, is an Error: a change of them is a migration. *)
let link_ops current (links : (int * string * Schema.link) list) =
  let ops = ref [] and bad = ref None in
  List.iter
    (fun (p, name, (l : Schema.link)) ->
      match current p with
      | Some l0 when l0 = l -> ()
      | Some (l0 : Schema.link) ->
        if !bad = None then
          bad := Some (Printf.sprintf "%s links to %s things in this database, with on delete %s, not to %s things with %s" name l0.kind
                         (Schema.on_delete_name l0.on_delete) l.kind (Schema.on_delete_name l.on_delete))
      | None ->
        ops := Add (p, Schema.p_delete, Value.Text (Schema.on_delete_name l.on_delete)) :: Add (p, Schema.p_to, Value.Text l.kind)
               :: Expect (p, Schema.p_to, None) :: !ops)
    links;
  match !bad with Some m -> Error m | None -> Ok (List.rev !ops)
