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

let naive (facts : F.t) (q : Query.t) =
  let fl = F.elements facts in
  let out = ref [] in
  let env = Array.make q.vars None in
  let matches term (x : Value.t) =
    match term with
    | Query.Var i -> (match env.(i) with None -> `Bind i | Some y -> if Value.equal x y then `Ok else `No)
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
          if p = pt.p then begin
            let saved = Array.copy env in
            let ok =
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

(* the facts a rule's body gives a head for, over a set of facts *)
let heads (r : Rules.t) (facts : F.t) =
  let q = { vars = r.vars; where = r.where; ranges = r.ranges } in
  let rows = naive facts q in
  match r.head with
  | Never -> List.map (fun _ -> None) rows
  | Give h ->
    let term row = function Var x -> row.(x) | Thing t -> Link t | Val x -> x in
    List.map
      (fun row ->
        let e = match term row h.e with Link t -> t | _ -> assert false in
        Some (e, h.p, term row h.v))
      rows

(* the least fixpoint of the facts under the rules (naive evaluation: every rule over everything, until nothing new) *)
let least (rules : Rules.t list) (facts : F.t) =
  let s = ref facts and go = ref true in
  while !go do
    go := false;
    List.iter
      (fun r ->
        List.iter
          (function Some f when not (F.mem f !s) -> s := F.add f !s; go := true | _ -> ())
          (heads r !s))
      rules
  done;
  !s

let violated (rules : Rules.t list) (m : F.t) = List.exists (fun (r : Rules.t) -> r.head = Never && heads r m <> []) rules

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
