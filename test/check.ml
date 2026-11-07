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

let apply_group s (g : Group.t) =
  Array.fold_left (fun s (c : Group.change) -> if c.add then F.add (c.e, c.p, c.v) s else F.remove (c.e, c.p, c.v) s) s g.changes

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

(* ---- The Generic Join bound of a question, from the facts alone ----
   For the order the engine chose: the sum, over the levels and over the partial bindings that reach each level, of
   the smallest candidate set a pattern offers the level's variable (Ngo, Re, Rudra 2013: the work of Generic Join).
   The size of an offer is what the engine's indexes count: the facts with both sides fixed, all the facts of the
   property when the other side is free (or those inside the variable's ranges, for a value read off the property's
   sorted index). A partial binding reaches the next level when its value passes every pattern on its variable (a
   fixed other side: the fact exists; a free one: some fact has it) and the ranges. *)

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
  let offer x (pt : Query.pattern) =
    let all = List.length (get rows_p pt.p) in
    if has x pt.e && has x pt.v then all, (fun () -> get self_p pt.p), fun c -> F.mem (Option.get (link c), pt.p, c) facts
    else if has x pt.e then
      match known pt.v with
      | Some w -> let l = get by_pw (pt.p, key w) in List.length l, (fun () -> l), fun c -> F.mem (Option.get (link c), pt.p, w) facts
      | None -> all, (fun () -> get th_p pt.p), fun c -> Hashtbl.mem th_seen (pt.p, Option.get (link c))
    else
      match Option.bind (known pt.e) link with
      | Some e -> let l = get by_ep (e, pt.p) in List.length l, (fun () -> l), fun c -> F.mem (e, pt.p, c) facts
      | None ->
        let size = if ranges x = [] then all else List.length (List.filter (in_ranges x) (get rows_p pt.p)) in
        size, (fun () -> get va_p pt.p), fun c -> Hashtbl.mem va_seen (pt.p, key c)
  in
  let total = ref 0 in
  let rec level i =
    if i < n then begin
      let x = ord.(i) in
      let offers = List.map (offer x) (List.filter (fun (pt : Query.pattern) -> has x pt.e || has x pt.v) pats) in
      match List.sort (fun (a, _, _) (b, _, _) -> compare a b) offers with
      | [] -> ()
      | (size, cands, _) :: rest ->
        total := !total + size;
        List.iter
          (fun c ->
            if in_ranges x c && List.for_all (fun (_, _, accepts) -> accepts c) rest then begin
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
