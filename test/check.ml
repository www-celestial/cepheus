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

let tmpdir name =
  let base = try Sys.getenv "CEPHEUS_TMP" with Not_found -> Filename.get_temp_dir_name () in
  let d = Filename.concat base (Printf.sprintf "cepheus-%s-%d" name (Unix.getpid ())) in
  ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote d)));
  d

let rmrf d = ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote d)))
