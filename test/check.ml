(* Small helpers for the tests: a counter of checks, failures that name their seed, the facts of a view as a plain
   set (the reference model), and a naive evaluator of questions to compare Generic Join against. *)

open Cepheus

let checks = ref 0
let failures = ref 0

let fail fmt = Printf.ksprintf (fun s -> incr failures; Printf.printf "FAIL %s\n%!" s) fmt

let check cond fmt =
  incr checks;
  Printf.ksprintf (fun s -> if not cond then (incr failures; Printf.printf "FAIL %s\n%!" s)) fmt

let finish name =
  Printf.printf "%s: %d checks, %d failures\n%!" name !checks !failures;
  exit (if !failures = 0 then 0 else 1)

(* ---- The reference model: a set of facts ---- *)

module F = Set.Make (struct
  type t = int * int * Value.t
  let compare (e, p, x) (e', p', x') = match compare e e' with 0 -> (match compare p p' with 0 -> Value.compare x x' | c -> c) | c -> c
end)

let facts_of_view (v : Store.view) =
  let s = ref F.empty in
  for e = 0 to Store.max_thing v do
    Store.iter_facts v e (fun p w ->
        match Schema.find v.schema p with
        | Some d -> s := F.add (e, p, Store.value v d.typ w) !s
        | None -> fail "fact (%d %d) of an unknown property" e p)
  done;
  !s

(* A merge of a view (its runs and delta) into one run file of a simulated disk, read through the cache: what every
   full merge is *)
let merge_disk = lazy (let d = Sim_disk.disk (Sim_disk.create (Rng.make 1)) in d.mkdir "/merge"; d)

let merge_runs (v : Store.view) take =
  let d = Lazy.force merge_disk in
  let w = Snapshot.merge d "/merge" "0123456789abcdef" v ~take ~level:(1 + take) { Journal.segment = 1; offset = 40; next = v.group + 1 } in
  Snapshot.install d "/merge" w;
  w.view

let compact (v : Store.view) = merge_runs v (Array.length v.runs)

(* the delta alone into a new run on top of the others *)
let push (v : Store.view) = merge_runs v 0

(* a view of several runs and a delta, for the tests of reads across runs: [rounds] of [write v] calls on forks,
   each round ending in a merge of the delta alone (a new top run), of the delta and the top run, or of all, as [r]
   draws *)
let layered r (v0 : Store.view) rounds write =
  let v = ref v0 in
  for i = 1 to rounds do
    v := write (Cepheus.fork !v);
    if i < rounds then
      v := (match Rng.int r 4 with
            | 0 -> compact !v
            | 1 when Array.length !v.runs > 0 -> merge_runs !v 1
            | _ -> push !v)
  done;
  !v

let apply_group s (g : Group.t) =
  Array.fold_left (fun s (c : Group.change) -> if Group.present c then F.add (c.e, c.p, c.v) s else F.remove (c.e, c.p, c.v) s) s g.changes

let show_diff a b =
  let only_a = F.diff a b and only_b = F.diff b a in
  let pr s = String.concat "; " (List.map (fun (e, p, x) -> Printf.sprintf "%d %d %s" e p (Value.to_string x)) (F.elements s)) in
  Printf.sprintf "only in the first: [%s]; only in the second: [%s]" (pr only_a) (pr only_b)

(* ---- A naive evaluator: every pattern against every fact, in the given order ---- *)

(* [types]: a rule's variables' own types, when it has a variable property: a variable with one binds only values of
   it, and one without takes whatever it is first bound to *)
let naive ?types (facts : F.t) (q : Query.t) =
  let fl = F.elements facts in
  let out = ref [] in
  let env = Array.make q.vars None in
  let typed i (x : Value.t) = match types with Some (t : Value.typ option array) -> (match t.(i) with Some ty -> Value.has_type ty x | None -> true) | None -> true in
  let matches term (x : Value.t) =
    match term with
    | Query.Var i -> (match env.(i) with None -> if typed i x then `Bind i else `No | Some y -> if Value.equal x y then `Ok else `No)
    | Query.Thing e -> if Value.equal x (Value.Link e) then `Ok else `No
    | Query.Val y -> if Value.equal x y then `Ok else `No
  in
  let in_ranges () =
    List.for_all
      (fun (i, lo, hi) ->
        match env.(i), lo, hi with
        | Some (Value.Int x | Value.Date x | Value.Money x), (Value.Int a | Value.Date a | Value.Money a), (Value.Int b | Value.Date b | Value.Money b) -> x >= a && x <= b
        | _ -> false)
      q.ranges
  in
  let rec go = function
    | [] -> if in_ranges () then out := Array.map Option.get env :: !out
    | (pt : Query.pattern) :: rest ->
      List.iter
        (fun (e, p, x) ->
          if p = pt.p || pt.p < 0 then begin
            let saved = Array.copy env in
            let bind t y = match matches t y with `No -> false | `Ok -> true | `Bind i -> env.(i) <- Some y; true in
            (* a variable property: bound to the fact's, a link to the property thing *)
            let ok = pt.p >= 0 || bind (Query.Var (-1 - pt.p)) (Value.Link p) in
            let ok =
              ok
              &&
              match matches pt.e (Value.Link e) with
              | `No -> false
              | `Ok -> true
              | `Bind i -> env.(i) <- Some (Value.Link e); true
            in
            let ok =
              ok
              &&
              match matches pt.v x with
              | `No -> false
              | `Ok -> true
              | `Bind i -> env.(i) <- Some x; true
            in
            if ok then go rest;
            Array.blit saved 0 env 0 (Array.length env)
          end)
        fl
  in
  go q.where;
  List.sort_uniq compare !out

let sorted_rows l = List.sort compare l

(* ---- The rules' reference: the least model, naively ---- *)

(* the type of a property a rule may give ([ptyp]), for rules with a variable property: a fact whose property is none,
   or whose value is not of its type, refuses its group ([bad] set) *)
type ptyp = int -> Value.typ option

(* a rule's variables' own types (thing places and property variables are links; a value under a constant property
   has its type), for a rule with a variable property *)
let rule_types (ptyp : ptyp) (r : Rules.t) =
  let t = Array.make (max 1 r.vars) None in
  List.iter
    (fun (a : Query.pattern) ->
      (match a.e with Var x -> t.(x) <- Some Value.Tlink | _ -> ());
      if a.p < 0 then t.(-1 - a.p) <- Some Value.Tlink
      else match a.v, ptyp a.p with Var x, Some ty -> t.(x) <- Some ty | _ -> ())
    r.where;
  t

let has_var_prop (r : Rules.t) = List.exists (fun (a : Query.pattern) -> a.p < 0) r.where || match r.head with Give h -> h.p < 0 | Never -> false

(* the facts a rule's body gives a head for, over a set of facts *)
let heads ?ptyp ?bad (r : Rules.t) (facts : F.t) =
  let q = { vars = r.vars; where = r.where; ranges = r.ranges } in
  let types = match ptyp with Some pt when has_var_prop r -> Some (rule_types pt r) | _ -> None in
  let rows = naive ?types facts q in
  match r.head with
  | Never -> List.map (fun _ -> None) rows
  | Give h ->
    let term row = function Var x -> row.(x) | Thing t -> Link t | Val x -> x in
    List.filter_map
      (fun row ->
        (* a rule the engine refuses when it is written may give a thing that is not one: no fact, and [bad] *)
        match term row h.e, (if h.p >= 0 then Value.Link h.p else row.(-1 - h.p)) with
        | Link e, Link p -> (
          let x = term row h.v in
          match ptyp, bad with
          | Some pt, Some bad when has_var_prop r ->
            (match if p >= Schema.first_prop then pt p else None with
             | Some ty when Value.has_type ty x -> Some (Some (e, p, x))
             | _ -> bad := true; None)
          | _ -> Some (Some (e, p, x)))
        | _ -> (match bad with Some b -> b := true | None -> ()); None)
      rows

(* A template's meaning (Rules.every): [c, every L, m] holds for a list c of L when the patterns that name m hold for
   each member of c's L, each copy with variables of its own for those that appear only in such patterns. Written
   here from that sentence, over the facts as values: for each c, the rule with the copies, then evaluated as any
   rule. A list of no member gives nothing. *)
let template_rules (facts : F.t) (r : Rules.t) =
  match List.find_opt (fun (a : Query.pattern) -> Rules.is_every a.p) r.where with
  | None -> [ r ]
  | Some ta ->
    let l = Rules.every_of ta.p and m = (match ta.v with Query.Var m -> m | _ -> -1) in
    let rest = List.filter (fun a -> a != ta) r.where in
    let names (a : Query.pattern) = a.e = Query.Var m || a.v = Query.Var m || a.p = -1 - m in
    let per = List.filter names rest and shared = List.filter (fun a -> not (names a)) rest in
    let vs (a : Query.pattern) = List.filter_map (function Query.Var x -> Some x | _ -> None) [ a.e; a.v ] @ (if a.p < 0 then [ -1 - a.p ] else []) in
    let hv = match r.head with Rules.Give h -> vs h | Never -> [] in
    let held = List.concat_map vs shared @ hv @ vs ta in
    let own x = x <> m && not (List.mem x held) in
    let lists = Hashtbl.create 8 in
    F.iter
      (fun (e, p, x) ->
        if p = l && (match ta.e with Query.Thing c -> c = e | _ -> true) then
          Hashtbl.replace lists e (x :: Option.value (Hashtbl.find_opt lists e) ~default:[]))
      facts;
    Hashtbl.fold
      (fun c xs acc ->
        let xs = List.sort_uniq Value.compare xs in
        let n = ref r.vars and ok = ref true in
        let copies =
          List.concat_map
            (fun x ->
              let mine = Hashtbl.create 4 in
              let rn y = match Hashtbl.find_opt mine y with Some z -> z | None -> let z = !n in incr n; Hashtbl.replace mine y z; z in
              let t (u : Query.term) : Query.term =
                match u with
                | Query.Var y when y = m -> (match x with Value.Link k -> Thing k | x -> Val x)
                | Var y when own y -> Var (rn y)
                | Var y when ta.e = Query.Var y -> Thing c
                | u -> u
              in
              let prop q =
                if q = -1 - m then (match x with Value.Link k when k >= Schema.first_prop && k < Schema.first_thing -> k | _ -> ok := false; 0)
                else if q < 0 && own (-1 - q) then -1 - rn (-1 - q)
                else q
              in
              List.map (fun (a : Query.pattern) -> { Query.e = t a.e; p = prop a.p; v = t a.v }) per)
            xs
        in
        let ct (u : Query.term) : Query.term = match u with Query.Var y when ta.e = Query.Var y -> Thing c | u -> u in
        let shared = List.map (fun (a : Query.pattern) -> { a with e = ct a.e; v = ct a.v }) shared in
        let head = match r.head with Rules.Give h -> Rules.Give { h with e = ct h.e; v = ct h.v } | Never -> Never in
        if xs = [] || not !ok then acc
        else begin
          (* the variables used, numbered again from 0 *)
          let where = shared @ copies in
          let used = Hashtbl.create 8 and k = ref 0 in
          let see y = if not (Hashtbl.mem used y) then (Hashtbl.replace used y !k; incr k) in
          List.iter (fun (a : Query.pattern) -> List.iter see (vs a)) where;
          (match head with Rules.Give h -> List.iter see (vs h) | Never -> ());
          let t (u : Query.term) : Query.term = match u with Query.Var y -> Var (Hashtbl.find used y) | u -> u in
          let pt (a : Query.pattern) = { Query.e = t a.e; p = (if a.p < 0 then -1 - Hashtbl.find used (-1 - a.p) else a.p); v = t a.v } in
          { r with vars = !k; where = List.map pt where; head = (match head with Rules.Give h -> Rules.Give (pt h) | Never -> Never);
                   ranges = List.filter_map (fun (y, lo, hi) -> match Hashtbl.find_opt used y with Some z when not (own y) && y <> m -> Some (z, lo, hi) | _ -> None) r.ranges }
          :: acc
        end)
      lists []

(* the least fixpoint of the facts under the rules (naive evaluation: every rule over everything, until nothing new) *)
let least ?ptyp ?bad (rules : Rules.t list) (facts : F.t) =
  let s = ref facts and go = ref true in
  while !go do
    go := false;
    List.iter
      (fun r ->
        List.iter
          (fun r ->
            List.iter
              (function Some f when not (F.mem f !s) -> s := F.add f !s; go := true | _ -> ())
              (heads ?ptyp ?bad r !s))
          (template_rules !s r))
      rules
  done;
  !s

(* ---- Not and aggregates: the perfect model of stratified rules, naively ----
   A rule decoded on its own: its positive patterns, its Nots (their patterns' properties plain), its aggregate. An
   answer is a binding of the variables of the positive patterns that passes the ranges of those variables and every
   Not: no binding of the Not's own variables (in its patterns only) passes the Not's patterns and the ranges of its own
   variables. An aggregate gives each thing of its head the sum, count, smallest or largest value of its answers. The
   strata are found again here, by longest paths (Bellman-Ford): a rule's stratum is at least that of a rule whose head
   matches a pattern of its body, one more under a Not or for an aggregate, and equal to that of a rule whose head
   matches its head; a growth past the number of rules is a cycle through a Not or an aggregate. *)

type decoded = { src : Rules.t; pos : Query.pattern list; dnots : Query.pattern list list; dagg : Rules.agg option; dhead : Rules.head }

let decode (r : Rules.t) =
  let pos = List.filter (fun (q : Query.pattern) -> not (Rules.is_absent q.p)) r.where in
  let ks = List.sort_uniq compare (List.filter_map (fun (q : Query.pattern) -> if Rules.is_absent q.p then Some (fst (Rules.absent_of q.p)) else None) r.where) in
  let dnots =
    List.map
      (fun k ->
        List.filter_map
          (fun (q : Query.pattern) -> if Rules.is_absent q.p && fst (Rules.absent_of q.p) = k then Some { q with p = snd (Rules.absent_of q.p) } else None)
          r.where)
      ks
  in
  let dhead, dagg = match r.head with Give h when Rules.is_agg h.p -> let f, p = Rules.agg_of h.p in Give { h with p }, Some f | h -> h, None in
  { src = r; pos; dnots; dagg; dhead }

let plain_rule (d : decoded) = d.dnots = [] && d.dagg = None

(* the bindings of [where] over the facts, [env] the variables bound before; unbound variables stay None *)
let bindings ?types (facts : F.t) vars (where : Query.pattern list) ranges (env0 : Value.t option array) =
  let fl = F.elements facts in
  let out = ref [] in
  let env = Array.copy env0 in
  let typed i (x : Value.t) = match types with Some (t : Value.typ option array) -> (match t.(i) with Some ty -> Value.has_type ty x | None -> true) | None -> true in
  let bind t (x : Value.t) =
    match t with
    | Query.Var i -> (match env.(i) with None -> if typed i x then (env.(i) <- Some x; true) else false | Some y -> Value.equal x y)
    | Thing e -> Value.equal x (Value.Link e)
    | Val y -> Value.equal x y
  in
  let num = function Value.Int a | Date a | Money a -> Some a | _ -> None in
  let in_ranges () =
    List.for_all (fun (i, lo, hi) -> match Option.bind env.(i) num, num lo, num hi with Some x, Some a, Some b -> x >= a && x <= b | _ -> false) ranges
  in
  let rec go = function
    | [] -> if in_ranges () then out := Array.copy env :: !out
    | (pt : Query.pattern) :: rest ->
      List.iter
        (fun (e, p, x) ->
          if p = pt.p || pt.p < 0 then begin
            let saved = Array.copy env in
            if (pt.p >= 0 || bind (Query.Var (-1 - pt.p)) (Value.Link p)) && bind pt.e (Value.Link e) && bind pt.v x then go rest;
            Array.blit saved 0 env 0 (Array.length env)
          end)
        fl
  in
  ignore vars;
  go where;
  List.sort_uniq compare !out

(* the variables of a decoded rule's positive patterns *)
let outer_vars (d : decoded) =
  let outer = Array.make (max 1 d.src.vars) false in
  List.iter
    (fun (q : Query.pattern) ->
      List.iter (function Query.Var x -> outer.(x) <- true | _ -> ()) [ q.e; q.v ];
      if q.p < 0 then outer.(-1 - q.p) <- true)
    d.pos;
  outer

(* does every Not of a decoded rule hold for a binding of its positive patterns, over the facts *)
let nots_hold (d : decoded) (facts : F.t) (row : Value.t option array) =
  let outer = outer_vars d in
  List.for_all
    (fun ps ->
      let own = List.concat_map (fun (q : Query.pattern) -> List.filter_map (function Query.Var x when not outer.(x) -> Some x | _ -> None) [ q.e; q.v ]) ps in
      let rg = List.filter (fun (x, _, _) -> List.mem x own) d.src.ranges in
      bindings facts d.src.vars ps rg row = [])
    d.dnots

(* the answers of a decoded rule over the facts (each Not read on the same facts) *)
let answers ?types (d : decoded) (facts : F.t) =
  let r = d.src in
  let outer = outer_vars d in
  let pos_ranges = List.filter (fun (x, _, _) -> outer.(x)) r.ranges in
  let rows = bindings ?types facts r.vars d.pos pos_ranges (Array.make (max 1 r.vars) None) in
  List.filter (nots_hold d facts) rows

(* the head facts of a plain-headed decoded rule's answers ([bad] as [heads]) *)
let head_facts ?ptyp ?bad (d : decoded) rows =
  match d.dhead with
  | Never -> []
  | Give h ->
    let term (row : Value.t option array) = function Query.Var x -> row.(x) | Thing t -> Some (Value.Link t) | Val x -> Some x in
    List.filter_map
      (fun row ->
        match term row h.e, (if h.p >= 0 then Some (Value.Link h.p) else row.(-1 - h.p)) with
        | Some (Link e), Some (Link p) -> (
          let x = Option.get (term row h.v) in
          match ptyp, bad with
          | Some pt, Some bad when has_var_prop d.src ->
            (match if p >= Schema.first_prop then pt p else None with
             | Some ty when Value.has_type ty x -> Some (e, p, x)
             | _ -> bad := true; None)
          | _ -> Some (e, p, x))
        | _ -> (match bad with Some b -> b := true | None -> ()); None)
      rows

(* an aggregate's facts over the facts: one a thing of its head; [bad] when a sum passes the ints *)
let agg_facts ?bad (d : decoded) rows =
  match d.dhead, d.dagg with
  | Give h, Some f ->
    let groups = Hashtbl.create 8 in
    let term (row : Value.t option array) = function Query.Var x -> Option.get row.(x) | Thing t -> Value.Link t | Val x -> x in
    List.iter
      (fun row ->
        let k = term row h.e in
        Hashtbl.replace groups k (term row h.v :: Option.value (Hashtbl.find_opt groups k) ~default:[]))
      rows;
    Hashtbl.fold
      (fun k xs acc ->
        let e = match k with Value.Link e -> e | _ -> -1 in
        let num = function Value.Int a | Date a | Money a -> a | _ -> 0 in
        let mk n = match List.hd xs with Value.Int _ -> Value.Int n | Date _ -> Date n | Money _ -> Money n | x -> x in
        let value =
          match f with
          | `Count -> Value.Int (List.length xs)
          | `Sum ->
            (* exact: the high and low 30 bits summed apart, then the int it is, if any *)
            let hi = List.fold_left (fun s x -> s + (num x asr 30)) 0 xs and lo = List.fold_left (fun s x -> s + (num x land 0x3fffffff)) 0 xs in
            let hi = hi + (lo asr 30) and lo = lo land 0x3fffffff in
            if hi >= min_int asr 30 && hi <= max_int asr 30 then mk ((hi lsl 30) + lo) else ((match bad with Some b -> b := true | None -> ()); mk 0)
          | `Min -> mk (List.fold_left (fun m x -> min m (num x)) max_int xs)
          | `Max -> mk (List.fold_left (fun m x -> max m (num x)) min_int xs)
        in
        (e, h.p, value) :: acc)
      groups []
  | _ -> []

(* a term's constant for the strata: a thing or an inline value; texts and floats match any, as variables do *)
let node_const = function
  | Query.Thing c -> Some (Value.Link c)
  | Val (Text _ | Float _) | Var _ -> None
  | Val x -> Some x

let node_value (x : Value.t) = match x with Int a | Date a | Money a | Link a -> a | Bool b -> if b then 1 else 0 | _ -> 0

let nodes_match (p, v) (p', v') =
  (p < 0 || p' < 0 || p = p') && match v, v' with Some a, Some b -> node_value a = node_value b | _ -> true

(* each rule's stratum, or None for a cycle through a Not or an aggregate *)
let strata_of (ds : decoded array) =
  let n = Array.length ds in
  let head i = match ds.(i).dhead with Give h -> Some (h.p, if ds.(i).dagg <> None || h.p < 0 then None else node_const h.v) | Never -> None in
  let pnode (q : Query.pattern) = (q.p, node_const q.v) in
  let s = Array.make n 0 and changed = ref true and cycle = ref false in
  while !changed && not !cycle do
    changed := false;
    for i = 0 to n - 1 do
      match head i with
      | None -> ()
      | Some hi ->
        for j = 0 to n - 1 do
          match head j with
          | None -> ()
          | Some hj ->
            let need = ref s.(j) in
            if List.exists (fun q -> nodes_match hi (pnode q)) ds.(j).pos then need := max !need (s.(i) + if ds.(j).dagg <> None then 1 else 0);
            if List.exists (List.exists (fun q -> nodes_match hi (pnode q))) ds.(j).dnots then need := max !need (s.(i) + 1);
            if i <> j && nodes_match hi hj then need := max !need s.(i);
            if !need > s.(j) then (s.(j) <- !need; changed := true; if !need > n then cycle := true)
        done
    done
  done;
  if !cycle then None else Some s

(* the perfect model: stratum by stratum, its aggregates over the strata below, then its rules to their fixpoint; the
   least model when every rule is plain. Raises [Exit] for rules that are not stratified. *)
let perfect ?ptyp ?bad (rules : Rules.t list) (facts : F.t) =
  let ds = Array.of_list (List.map decode rules) in
  if Array.for_all plain_rule ds then least ?ptyp ?bad rules facts
  else
    match strata_of ds with
    | None -> raise Exit
    | Some st ->
      let types d = match ptyp with Some pt when has_var_prop d.src -> Some (rule_types pt { d.src with where = d.pos }) | _ -> None in
      let m = ref facts in
      let top = Array.fold_left max 0 st in
      for s = 0 to top do
        Array.iteri (fun i d -> if st.(i) = s && d.dagg <> None then List.iter (fun f -> m := F.add f !m) (agg_facts ?bad d (answers d !m))) ds;
        let go = ref true in
        while !go do
          go := false;
          Array.iteri
            (fun i d ->
              if st.(i) = s && d.dagg = None && d.dhead <> Never then
                List.iter (fun f -> if not (F.mem f !m) then (m := F.add f !m; go := true)) (head_facts ?ptyp ?bad d (answers ?types:(types d) d !m)))
            ds
        done
      done;
      !m

let stratified (rules : Rules.t list) = strata_of (Array.of_list (List.map decode rules)) <> None

let violated (rules : Rules.t list) (m : F.t) =
  List.exists
    (fun (r : Rules.t) ->
      r.head = Never && List.exists (fun r -> let d = decode r in if plain_rule d then heads r m <> [] else answers d m <> []) (template_rules m r))
    rules

(* the facts of a view that are not about schema things, and those asserted *)
let user_facts (v : Store.view) =
  F.filter (fun (e, _, _) -> e >= Schema.first_thing) (facts_of_view v)

let asserted_facts (v : Store.view) =
  F.filter
    (fun (e, p, x) -> match Store.word v x with Some w -> Store.state v e p w = 1 | None -> false)
    (user_facts v)

let rules_of (v : Store.view) =
  List.filter_map
    (fun (_, (name, text)) -> match Rules.of_text name text with Ok r -> Some r | Error _ -> None)
    (Schema.rules v.schema)


(* ---- The Generic Join bound of a question, from the facts alone ----
   For the order the engine chose: the sum, over the levels and over the partial bindings that reach each level, of
   the smallest candidate set a pattern offers the level's variable (Ngo, Re, Rudra 2013: the work of Generic Join).
   The size of an offer is what the engine's indexes count: the facts with both sides fixed, all the facts of the
   property when the other side is free (or those inside the variable's ranges, for a value read off the property's
   sorted index). A partial binding reaches the next level when its value passes every pattern on its variable (a
   fixed other side: the fact exists; a free one: some fact has it) and the ranges.
   With the leapfrog (Veldhuizen 2014): where the smallest offer m is 2 or more, the engine also reads every slice (an
   offer whose other side is known: a thing's values, a value's things) of at most 8 m into a buffer and intersects
   them; the level then costs at most m plus those slices' sizes, at most 1 + 8 (k - 1) times Generic Join's for k
   slices: the bound adds them. *)

let gj_bound (facts : F.t) (q : Query.t) (ord : int array) =
  (* hashed indexes of the facts, values keyed by their printed form (exact, floats included) *)
  let key = Value.to_string in
  let tbl () = Hashtbl.create 64 in
  let add t k x = Hashtbl.replace t k (x :: Option.value (Hashtbl.find_opt t k) ~default:[]) in
  let rows_p = tbl () and by_pw = tbl () and by_ep = tbl () and self_p = tbl () and th_p = tbl () and va_p = tbl () in
  let th_seen = Hashtbl.create 64 and va_seen = Hashtbl.create 64 in
  F.iter
    (fun (e, p, w) ->
      add rows_p p w;
      add by_pw (p, key w) (Value.Link e);
      add by_ep (e, p) w;
      if Value.equal w (Value.Link e) then add self_p p (Value.Link e);
      if not (Hashtbl.mem th_seen (p, e)) then (Hashtbl.replace th_seen (p, e) (); add th_p p (Value.Link e));
      if not (Hashtbl.mem va_seen (p, key w)) then (Hashtbl.replace va_seen (p, key w) (); add va_p p w))
    facts;
  let get t k = Option.value (Hashtbl.find_opt t k) ~default:[] in
  let n = q.vars in
  let env = Array.make n None in
  let pats = List.filter (fun (pt : Query.pattern) -> match pt.e, pt.v with Var _, _ | _, Var _ -> true | _ -> false) q.where in
  let has x = function Query.Var y -> x = y | _ -> false in
  let known = function Query.Var y -> env.(y) | Query.Thing e -> Some (Value.Link e) | Query.Val x -> Some x in
  let num = function Value.Int a | Date a | Money a | Link a -> a | Bool b -> if b then 1 else 0 | _ -> 0 in
  let ranges x = List.filter_map (fun (y, lo, hi) -> if y = x then Some (num lo, num hi) else None) q.ranges in
  let in_ranges x c = List.for_all (fun (lo, hi) -> num c >= lo && num c <= hi) (ranges x) in
  let link = function Value.Link e -> Some e | _ -> None in
  (* what a pattern offers x: its size as the engine counts it, its candidates, and a membership test *)
  (* what a pattern offers x: its size as the engine counts it, its candidates, a membership test, and whether it is a
     slice (its other side known) *)
  let offer x (pt : Query.pattern) =
    let all = List.length (get rows_p pt.p) in
    if has x pt.e && has x pt.v then all, (fun () -> get self_p pt.p), (fun c -> F.mem (Option.get (link c), pt.p, c) facts), false
    else if has x pt.e then
      match known pt.v with
      | Some w -> let l = get by_pw (pt.p, key w) in List.length l, (fun () -> l), (fun c -> F.mem (Option.get (link c), pt.p, w) facts), true
      | None -> all, (fun () -> get th_p pt.p), (fun c -> Hashtbl.mem th_seen (pt.p, Option.get (link c))), false
    else
      match Option.bind (known pt.e) link with
      | Some e -> let l = get by_ep (e, pt.p) in List.length l, (fun () -> l), (fun c -> F.mem (e, pt.p, c) facts), true
      | None ->
        let size = if ranges x = [] then all else List.length (List.filter (in_ranges x) (get rows_p pt.p)) in
        size, (fun () -> get va_p pt.p), (fun c -> Hashtbl.mem va_seen (pt.p, key c)), false
  in
  let total = ref 0 in
  let rec level i =
    if i < n then begin
      let x = ord.(i) in
      let offers = List.map (offer x) (List.filter (fun (pt : Query.pattern) -> has x pt.e || has x pt.v) pats) in
      match List.sort (fun (a, _, _, _) (b, _, _, _) -> compare a b) offers with
      | [] -> ()
      | (size, cands, _, _) :: rest ->
        total := !total + size;
        if size >= 2 then List.iter (fun (s, _, _, sl) -> if sl && s <= 8 * size then total := !total + s) offers;
        List.iter
          (fun c ->
            if in_ranges x c && List.for_all (fun (_, _, accepts, _) -> accepts c) rest then begin
              env.(x) <- Some c; level (i + 1); env.(x) <- None end)
          (cands ())
    end
  in
  level 0;
  !total

(* the work the engine did on a question, and the bound for the order it chose *)
let work_and_bound (v : Store.view) facts (q : Query.t) run =
  let before = Atomic.get Query.work in
  let r = run () in
  let work = Atomic.get Query.work - before in
  let bound = match Query.plan v q with None -> 0 | Some p -> gj_bound facts q p.ord in
  r, work, bound

(* ---- Random questions over the properties [names] of a view: constants drawn from its facts, or not ---- *)

let random_query r (v : Store.view) facts names =
  let ps = Array.of_list (List.filter_map (fun n -> Schema.by_name v.schema n) names) in
  let fl = Array.of_list (F.elements facts) in
  let nv = 1 + Rng.int r 3 in
  let things = v.next_e - Schema.first_thing in
  let pat () =
    let p = Rng.pick r ps in
    let d = Option.get (Schema.find v.schema p) in
    let of_p = List.filter (fun (_, p', _) -> p' = p) (Array.to_list fl) in
    let some_value () =
      if of_p <> [] && Rng.bool r then (let _, _, x = List.nth of_p (Rng.int r (List.length of_p)) in x)
      else
        match d.typ with
        | Ttext -> Value.Text (Rng.pick r [| "a"; "b"; "c"; "na"; "a@x" |])
        | Tint -> Int (Rng.int r 5)
        | Tbool -> Bool (Rng.bool r)
        | Tdate -> Date (Rng.int r 1000)
        | Tmoney _ -> Money (Rng.int r 100000)
        | Tfloat -> Float (float_of_int (Rng.int r 7) /. 3.)
        | Tlink -> Link (Schema.first_thing + Rng.int r (max 1 things))
    in
    let e = if Rng.int r 5 = 0 && things > 0 then Query.Thing (Schema.first_thing + Rng.int r things) else Query.Var (Rng.int r nv) in
    let vt =
      if d.typ = Tlink then (if Rng.int r 4 = 0 then Query.Val (some_value ()) else Query.Var (Rng.int r nv))
      else if Rng.int r 2 = 0 then Query.Val (some_value ()) else Query.Var (Rng.int r nv)
    in
    { Query.e; p; v = vt }
  in
  if ps = [||] then None
  else
  let where = List.init (1 + Rng.int r 3) (fun _ -> pat ()) in
  let q = { Query.vars = nv; where; ranges = [] } in
  match Query.var_types v q with
  | ty ->
    let ranges = ref [] in
    Array.iteri
      (fun i (t : Value.typ) ->
        if Rng.int r 2 = 0 then
          match t with
          | Tint -> ranges := (i, Value.Int (Rng.int r 3), Value.Int (1 + Rng.int r 3)) :: !ranges
          | Tdate -> let a = Rng.int r 1000 in ranges := (i, Value.Date a, Value.Date (a + Rng.int r 400)) :: !ranges
          | Tmoney _ -> let a = Rng.int r 100000 in ranges := (i, Value.Money a, Value.Money (a + Rng.int r 50000)) :: !ranges
          | _ -> ())
      ty;
    Some { q with ranges = !ranges }
  | exception Query.Bad _ -> None

let tmpdir name =
  let base = try Sys.getenv "CEPHEUS_TMP" with Not_found -> Filename.get_temp_dir_name () in
  let d = Filename.concat base (Printf.sprintf "cepheus-%s-%d" name (Unix.getpid ())) in
  ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote d)));
  d

let rmrf d = ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote d)))

(* ---- Equality: the meaning of the rules that make things the same ----
   A rule whose head gives cepheus/same makes its two things one thing (OWL 2 RL's owl:sameAs: eq-ref, eq-sym, eq-trans,
   eq-rep-s, eq-rep-p, eq-rep-o). Computed here naively: a union-find over the things, every fact rewritten onto the
   least member of its class after each pass, the rules evaluated again until nothing changes (the materialisation of
   the axiomatised equality, up to the choice of a member: Motik, Nenov, Piro, Horrocks, AAAI 2015, Theorem 1). Two
   different values made the same set [bad]. *)

let same_head (r : Rules.t) = match r.head with Rules.Give h -> h.p = Schema.p_same | Never -> false

let least_eq ?ptyp ?bad (rules : Rules.t list) (facts : F.t) =
  let parent = Hashtbl.create 16 in
  let rec find x = match Hashtbl.find_opt parent x with Some y when y <> x -> let r = find y in Hashtbl.replace parent x r; r | _ -> x in
  let union a b = let a = find a and b = find b in if a <> b then (if a < b then Hashtbl.replace parent b a else Hashtbl.replace parent a b; true) else false in
  let canon (e, p, (x : Value.t)) = find e, p, (match x with Link t -> Value.Link (find t) | x -> x) in
  let s = ref (F.map canon facts) and go = ref true in
  while !go do
    go := false;
    List.iter
      (fun r ->
        List.iter
          (fun (r : Rules.t) ->
            if same_head r then begin
              let types = match ptyp with Some pt when has_var_prop r -> Some (rule_types pt r) | _ -> None in
              let rows = naive ?types !s { vars = r.vars; where = r.where; ranges = r.ranges } in
              match r.head with
              | Give h ->
                let term row = function Query.Var x -> row.(x) | Thing t -> Value.Link t | Val x -> x in
                List.iter
                  (fun row ->
                    match term row h.e, term row h.v with
                    | Link a, Link b -> if union a b then go := true
                    | x, y -> if not (Value.equal x y) then (match bad with Some b -> b := true | None -> ()))
                  rows
              | Never -> ()
            end
            else
              List.iter (function Some f when not (F.mem f !s) -> s := F.add f !s; go := true | _ -> ()) (heads ?ptyp ?bad r !s))
          (template_rules !s r))
      rules;
    let s' = F.map canon !s in
    if not (F.equal s' !s) then (s := s'; go := true)
  done;
  !s, find

(* a view against the meaning of its rules with equality: the same classes, and the same facts once both are read
   through the view's classes (asserted facts stay where they were written; facts only derived name representatives) *)
let eq_diff ?ptyp (v : Store.view) =
  let bad = ref false in
  let rules = rules_of v in
  let asserted = asserted_facts v in
  let m, find = least_eq ?ptyp ~bad rules asserted in
  let rep x = let r = ref x in Store.iter_values v x Schema.p_same (fun w -> r := w); !r in
  let errors = ref [] in
  let err fmt = Printf.ksprintf (fun s -> errors := s :: !errors) fmt in
  (* the classes: two things are the same in the view exactly when they are in the meaning *)
  let things = Hashtbl.create 64 in
  let see_t = function Value.Link t when t >= Schema.first_thing -> Hashtbl.replace things t () | _ -> () in
  F.iter (fun (e, _, x) -> Hashtbl.replace things e (); see_t x) asserted;
  let ts = Hashtbl.fold (fun t () l -> t :: l) things [] |> List.sort compare in
  let byv = Hashtbl.create 16 and bym = Hashtbl.create 16 in
  List.iter (fun t -> Hashtbl.replace byv t (rep t); Hashtbl.replace bym t (find t)) ts;
  List.iter
    (fun a -> List.iter (fun b -> if a < b && (Hashtbl.find byv a = Hashtbl.find byv b) <> (Hashtbl.find bym a = Hashtbl.find bym b) then err "#%d and #%d: the same in the %s only" a b (if Hashtbl.find byv a = Hashtbl.find byv b then "view" else "meaning")) ts)
    ts;
  let vr x = match Hashtbl.find_opt byv x with Some r -> r | None -> rep x in
  let through (e, p, (x : Value.t)) = vr e, p, (match x with Link t -> Value.Link (vr t) | x -> x) in
  let got = ref F.empty in
  F.iter
    (fun ((e, p, x) as f) ->
      if p <> Schema.p_same then begin
        (* a fact only derived names representatives *)
        (match Store.word v x with
         | Some w when Store.state v e p w = 2 && through f <> f -> err "[%d %d %s] is only derived and names a thing that is no representative" e p (Value.to_string x)
         | _ -> ());
        got := F.add (through f) !got
      end)
    (user_facts v);
  let want = F.map through m in
  if not (F.equal !got want) then begin
    let show s = String.concat " " (List.map (fun (e, p, x) -> Printf.sprintf "[%d %d %s]" e p (Value.to_string x)) (F.elements s)) in
    err "missing %s; extra %s" (show (F.diff want !got)) (show (F.diff !got want))
  end;
  !bad, List.rev !errors
