(* Questions against an oracle: random states (every type of value, one and many values, texts that share their
   first bytes, floats with nan, -0 and the infinities, extreme ints, facts a rule derives, retractions), read from
   the delta and from runs merged at random; random questions (patterns, ranges, a select that gives every
   variable, leaves some out, or aggregates) with a random Sort, Limit and After. The oracle answers each one by brute
   force over every fact of the view: every binding, its row, the groups, the order compared value by value, the
   rows after the cursor, the first k and their copies. The engine must give the same rows in the same order, by the
   heap path, by the index path and by its own choice, and the same again after the request's trip through the wire.
   A failure prints its seed; [questions.exe --seed N] replays it. *)

open Cepheus
open Cepheus_server
module C = Check

let props =
  [ prop "name" Ttext; prop ~many:true "tag" Ttext; prop "score" Tint; prop "price" (Tmoney 2); prop "when" Tdate;
    prop "ratio" Tfloat; prop "ok" Tbool; prop "owner" Tlink; prop ~many:true "friend" Tlink; prop "mark" Tbool ]

let names = [| "a"; "ab"; "abc"; "Ad"; "ad"; "Ada"; "\195\132d"; "z"; "\195\169"; ""; "b"; "ab\000" |]
let floats = [| 0.; -0.; 1.5; -2.25; nan; -.nan; infinity; neg_infinity; 1e300; 3. |]

let ints r = match Rng.int r 12 with 0 -> max_int | 1 -> min_int | 2 -> 0 | _ -> Rng.int r 40 - 10

(* ---- the oracle ---- *)

let total_order a b =
  (* by cases, apart from Top's bit trick: negative nans first, positive nans last, -0 before +0 *)
  let neg f = Int64.compare (Int64.bits_of_float f) 0L < 0 in
  match Float.is_nan a, Float.is_nan b with
  | true, true -> compare (neg b) (neg a)
  | true, false -> if neg a then -1 else 1
  | false, true -> if neg b then 1 else -1
  | false, false -> if a = b then (if a = 0. then compare (neg b) (neg a) else 0) else compare a b

let cmp_value (x : Value.t) (y : Value.t) =
  match x, y with
  | (Int a | Date a | Money a | Link a), (Int b | Date b | Money b | Link b) -> compare a b
  | Bool a, Bool b -> compare a b
  | Text a, Text b -> String.compare a b
  | Float a, Float b -> total_order a b
  | _ -> invalid_arg "cmp_value"

let int_of = function Value.Int a | Date a | Money a | Link a -> a | Bool b -> if b then 1 else 0 | _ -> invalid_arg "int_of"

(* every binding of the question over the facts, as values *)
let bindings (fl : (int * int * Value.t) list) (q : Query.t) =
  let out = ref [] in
  let env = Array.make q.vars None in
  let bind t (x : Value.t) k =
    match t with
    | Query.Var i -> (match env.(i) with None -> env.(i) <- Some x; k (); env.(i) <- None | Some y -> if Value.equal x y then k ())
    | Thing e -> if Value.equal x (Link e) then k ()
    | Val y -> if Value.equal x y then k ()
  in
  let rec go = function
    | [] ->
      let row = Array.map Option.get env in
      if List.for_all (fun (x, lo, hi) -> let w = int_of row.(x) in w >= int_of lo && w <= int_of hi) q.ranges then out := row :: !out
    | (pt : Query.pattern) :: rest -> List.iter (fun (e, p, x) -> if p = pt.p then bind pt.e (Link e) (fun () -> bind pt.v x (fun () -> go rest))) fl
  in
  go q.where;
  !out

(* the rows of a select, with their columns' types *)
let rows_of (typs : Value.typ array) bs (sel : Wire.select) =
  match sel with
  | Give g -> Array.map (fun x -> typs.(x)) g, List.map (fun b -> Array.map (fun x -> b.(x)) g) bs
  | Group (keys, aggs) ->
    (* groups by values as Cepheus tells them apart (floats by their bits: nan and -nan, 0 and -0 are two) *)
    let t = Hashtbl.create 16 in
    List.iter
      (fun b ->
        let k = Array.map (fun x -> b.(x)) keys in
        let kb = Buffer.create 16 in
        Array.iter (Value.encode kb) k;
        let kk = Buffer.contents kb in
        let _, l = try Hashtbl.find t kk with Not_found -> k, [] in
        Hashtbl.replace t kk (k, b :: l))
      bs;
    let agg bs = function
      | Wire.Count -> Value.Int (List.length bs)
      | Sum x -> let s = List.fold_left (fun s b -> s + int_of b.(x)) 0 bs in (match typs.(x) with Tmoney _ -> Money s | _ -> Int s)
      | Min x -> List.fold_left (fun m b -> if cmp_value b.(x) m < 0 then b.(x) else m) (List.hd bs).(x) bs
      | Max x -> List.fold_left (fun m b -> if cmp_value b.(x) m > 0 then b.(x) else m) (List.hd bs).(x) bs
    in
    let ctyp = Array.append (Array.map (fun x -> typs.(x)) keys)
        (Array.map (function Wire.Count -> Value.Tint | Sum x | Min x | Max x -> typs.(x)) aggs) in
    ctyp, Hashtbl.fold (fun _ (k, bs) acc -> Array.append k (Array.map (agg bs) aggs) :: acc) t []

let ordered cols (o : Top.order) =
  let listed = List.map (fun (k : Top.key) -> k.col) o.keys in
  o.keys @ List.filter_map (fun c -> if List.mem c listed then None else Some { Top.col = c; desc = false }) (List.init cols Fun.id)

let cmp_row ord a b =
  List.fold_left (fun c (k : Top.key) -> if c <> 0 then c else let x = cmp_value a.(k.col) b.(k.col) in if k.desc then -x else x) 0 ord

let oracle cols rows (o : Top.order) =
  let ord = ordered cols o in
  let rows = List.stable_sort (cmp_row ord) rows in
  let rows = match o.after with None -> rows | Some a -> List.filter (fun r -> cmp_row ord r a > 0) rows in
  if o.limit = 0 then rows
  else begin
    let first = List.filteri (fun i _ -> i < o.limit) rows in
    match List.rev first with
    | [] -> []
    | last :: _ ->
      (* the copies of the k-th row, which follow it *)
      first @ List.filter (fun r -> cmp_row ord r last = 0) (List.filteri (fun i _ -> i >= o.limit) rows)
  end

(* ---- the engine ---- *)

let engine v q sel o =
  let a = Answer.answer ~order:o v q sel in
  let typs = Array.init a.cols a.typ in
  List.init a.n (fun i -> Array.init a.cols (fun j -> Store.value v typs.(j) (a.word i j)))

(* the request through the wire: coded, read back *)
let wired q sel (o : Top.order) =
  let b = Buffer.create 64 in
  Wire.put_request b (Wire.Find { db = 0; query = q; select = sel; order = o });
  let s = Buffer.contents b in
  match Wire.get_request Wire.k_find (Codec.reader (Bytes.of_string s) 0 (String.length s)) with
  | Wire.Find f -> f.query, f.select, f.order
  | _ -> assert false

let same a b = List.length a = List.length b && List.for_all2 (fun x y -> Array.for_all2 Value.equal x y) a b

let show rows = String.concat " | " (List.map (fun r -> String.concat "," (Array.to_list (Array.map Value.to_string r))) rows)

let questions = ref 0 and with_order = ref 0 and empties = ref 0

let run seed =
  let r = Rng.make seed in
  let db = fork empty in
  let[@warning "-8"] (Ok [ name; tag; score; price; when_; ratio; ok; owner; friend; mark ]) = declare db props in
  (* a rule: things whose score is 20 or more are marked (derived facts inside the questions) *)
  ignore
    (define db
       [ { name = "high"; vars = 2; where = [ { e = Var 0; p = score; v = Var 1 } ]; ranges = [ (1, Int 20, Int max_int) ];
           head = Give { e = Var 0; p = mark; v = Val (Bool true) } } ]);
  let mdisk = Sim_disk.disk (Sim_disk.create (Rng.make seed)) in
  mdisk.mkdir "/merge";
  let merged = ref None in
  let n = 5 + Rng.int r 60 in
  let things = ref [||] in
  for _ = 1 to 1 + Rng.int r 4 do
    let ops =
      List.concat
        (List.init (1 + Rng.int r (n / 2 + 1)) (fun k ->
             let t = if Array.length !things > 0 && Rng.int r 3 = 0 then !things.(Rng.int r (Array.length !things)) else -1 - k in
             let pick () = if Array.length !things = 0 then Value.Link (Store.max_thing (view db) + 1) else Link !things.(Rng.int r (Array.length !things)) in
             List.filter_map Fun.id
               [ (if Rng.int r 4 > 0 then Some (Resolve.Add (t, name, Text names.(Rng.int r (Array.length names)))) else None);
                 (if Rng.int r 2 = 0 then Some (Resolve.Add (t, tag, Text names.(Rng.int r 4))) else None);
                 (if Rng.int r 3 > 0 then Some (Resolve.Add (t, score, Int (ints r))) else None);
                 (if Rng.int r 2 = 0 then Some (Resolve.Add (t, price, Money (Rng.int r 30))) else None);
                 (if Rng.int r 2 = 0 then Some (Resolve.Add (t, when_, Date (1_700_000_000_000 + Rng.int r 5))) else None);
                 (if Rng.int r 2 = 0 then Some (Resolve.Add (t, ratio, Float floats.(Rng.int r (Array.length floats)))) else None);
                 (if Rng.int r 2 = 0 then Some (Resolve.Add (t, ok, Bool (Rng.bool r))) else None);
                 (if Rng.int r 2 = 0 then Some (Resolve.Add (t, owner, pick ())) else None);
                 (if Rng.int r 3 = 0 then Some (Resolve.Add (t, friend, pick ())) else None) ]))
    in
    (match write db ops with
     | Ok rc -> things := Array.append !things (Array.of_list (List.map snd rc.things))
     | Error _ -> ());
    (* retractions now and then *)
    (if Array.length !things > 0 && Rng.int r 3 = 0 then
       let t = !things.(Rng.int r (Array.length !things)) in
       match Cepheus.values (view db) t score with x :: _ -> ignore (write db [ Retract (t, score, x) ]) | [] -> ());
    if Rng.int r 3 = 0 then begin
      let v = view db in
      let w = Snapshot.merge mdisk "/merge" "0123456789abcdef" v ~take:(Array.length v.runs) ~level:(1 + Array.length v.runs) { Journal.segment = 1; offset = 40; next = v.group + 1 } in
      Snapshot.install mdisk "/merge" w;
      merged := Some w.view
    end
  done;
  let views = view db :: (match !merged with Some m -> [ m ] | None -> []) in
  List.iter
    (fun (v : Store.view) ->
      let fl = C.F.elements (C.facts_of_view v) in
      let tv x = match x with
        | 0 -> Value.Ttext | 1 -> Tint | 2 -> Tmoney 2 | 3 -> Tdate | 4 -> Tfloat | 5 -> Tbool | 6 -> Tlink | _ -> Ttext in
      let prop_of = [| name; score; price; when_; ratio; ok; owner; tag; friend; mark |] in
      for _ = 1 to 40 do
        incr questions;
        (* one to three patterns: a thing x0, values x1.. of chosen properties, sometimes a link followed *)
        let np = 1 + Rng.int r 3 in
        let vars = ref 1 and where = ref [] and typs = ref [ Value.Tlink ] in
        for _ = 1 to np do
          let k = Rng.int r 10 in
          let p = prop_of.(k) in
          let ty = match k with 7 -> Value.Ttext | 8 -> Tlink | 9 -> Tbool | k -> tv k in
          let e = if !vars > 1 && Rng.int r 4 = 0 && List.nth !typs (!vars - 1) = Value.Tlink then Query.Var (!vars - 1) else Query.Var 0 in
          let x = !vars in
          incr vars;
          typs := !typs @ [ ty ];
          where := { Query.e; p; v = Var x } :: !where
        done;
        let vars = !vars and typs = Array.of_list !typs in
        let where = List.rev !where in
        (* a constant now and then, from a fact *)
        let where =
          List.map (fun (pt : Query.pattern) ->
              if Rng.int r 6 = 0 then match List.filter (fun (_, p, _) -> p = pt.p) fl with
                | [] -> pt
                | l -> let _, _, x = List.nth l (Rng.int r (List.length l)) in { pt with v = Val x }
              else pt) where
        in
        (* the variables that are still in a pattern *)
        let used = Array.make vars false in
        List.iter (fun (pt : Query.pattern) -> (match pt.e with Var x -> used.(x) <- true | _ -> ()); match pt.v with Var x -> used.(x) <- true | _ -> ()) where;
        (* renumber them densely *)
        let map = Array.make vars (-1) and k = ref 0 in
        Array.iteri (fun i u -> if u then (map.(i) <- !k; incr k)) used;
        let nv = !k in
        let ren = function Query.Var x -> Query.Var map.(x) | t -> t in
        let where = List.map (fun (pt : Query.pattern) -> { pt with Query.e = ren pt.e; v = ren pt.v }) where in
        let typs = Array.of_list (List.filteri (fun i _ -> used.(i)) (Array.to_list typs)) in
        let inline = List.filter (fun x -> Value.inline typs.(x) && typs.(x) <> Tbool) (List.init nv Fun.id) in
        let ranges =
          if inline <> [] && Rng.int r 4 = 0 then
            let x = List.nth inline (Rng.int r (List.length inline)) in
            let mk w = match typs.(x) with Tdate -> Value.Date w | Tmoney _ -> Money w | Tlink -> Link w | _ -> Int w in
            let base = match typs.(x) with Tdate -> 1_700_000_000_000 | Tlink -> 65536 | _ -> 0 in
            let a = base + Rng.int r 20 - 5 in
            [ (x, mk a, mk (a + Rng.int r 15)) ]
          else []
        in
        let q = { Query.vars = nv; where; ranges } in
        let sel =
          match Rng.int r 3 with
          | 0 -> Wire.Give (Array.init nv Fun.id)
          | 1 -> let g = List.filter (fun _ -> Rng.int r 2 = 0) (List.init nv Fun.id) in Wire.Give (Array.of_list (if g = [] then [ 0 ] else g))
          | _ ->
            let keys = Array.of_list (List.filter (fun _ -> Rng.int r 2 = 0) (List.init nv Fun.id)) in
            let aggs = List.filter_map (fun x -> if Rng.int r 3 = 0 && (match typs.(x) with Tint | Tmoney _ -> true | _ -> false) then Some (Wire.Sum x) else if Rng.int r 4 = 0 && (match typs.(x) with Tint | Tmoney _ | Tdate -> true | _ -> false) then Some (if Rng.bool r then Wire.Min x else Max x) else None) (List.init nv Fun.id) in
            Wire.Group (keys, Array.of_list (Wire.Count :: aggs))
        in
        let ctyp, rows = rows_of typs (bindings fl q) sel in
        let cols = Array.length ctyp in
        if rows = [] then incr empties;
        let o =
          let keys = List.filter_map (fun c -> if Rng.int r 2 = 0 then Some { Top.col = c; desc = Rng.bool r } else None) (List.init cols Fun.id) in
          let keys = List.sort_uniq (fun (a : Top.key) b -> compare a.col b.col) keys in
          let keys = if keys <> [] && Rng.bool r then List.rev keys else keys in
          let limit = if Rng.int r 4 = 0 then 0 else 1 + Rng.int r 7 in
          let after =
            if keys <> [] && Rng.int r 3 = 0 && rows <> [] then Some (List.nth rows (Rng.int r (List.length rows)))
            else None
          in
          { Top.keys; limit; after }
        in
        if o <> Top.none then incr with_order;
        let check what got =
          if o.keys = [] then begin
            (* Limit alone: k rows of the answer *)
            let want = List.length rows in
            C.check (List.length got = (if o.limit = 0 then want else min want o.limit)) "seed %d: %s: %d rows of %d (limit %d)" seed what (List.length got) want o.limit;
            (* each row one of the answer's, as many times at most *)
            let key r = let b = Buffer.create 16 in Array.iter (Value.encode b) r; Buffer.contents b in
            let pool = Hashtbl.create 16 in
            List.iter (fun r -> Hashtbl.replace pool (key r) (1 + try Hashtbl.find pool (key r) with Not_found -> 0)) rows;
            List.iter (fun r -> match Hashtbl.find_opt pool (key r) with
                | Some n when n > 0 -> Hashtbl.replace pool (key r) (n - 1)
                | _ -> C.fail "seed %d: %s: a row that is not the answer's: %s" seed what (show [ r ])) got
          end
          else begin
            let want = oracle cols rows o in
            if same got want then C.check true "" else C.fail "seed %d: %s\n  got:  %s\n  want: %s" seed what (show got) (show want)
          end
        in
        let run_path p name =
          Top.path := p;
          match engine v q sel o with
          | got -> check name got
          | exception Query.Bad m -> C.fail "seed %d: %s refused: %s" seed name m
        in
        run_path Top.Heap "heap"; run_path Top.Index "index"; run_path Top.Auto "auto";
        let q', sel', o' = wired q sel o in
        Top.path := Auto;
        (match engine v q' sel' o' with got -> check "wired" got | exception Query.Bad m -> C.fail "seed %d: wired refused: %s" seed m)
      done)
    views

let () =
  let seeds = ref 300 and one = ref None in
  Arg.parse [ "--seeds", Arg.Set_int seeds, "N"; "--seed", Arg.Int (fun s -> one := Some s), "S" ] (fun _ -> ()) "questions.exe";
  (match !one with Some s -> run s | None -> for s = 1 to !seeds do run s done);
  Printf.printf "questions: %d questions (%d with an order, %d empty), %d windows of the index path, %d given up for the heap path\n"
    !questions !with_order !empties (Atomic.get Top.windows) (Atomic.get Top.gave_up);
  C.finish "questions"
