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

(* every binding of a question with Not, Or and In over the facts: of its variables ([outer]), each once *)
let bindings_ask (fl : (int * int * Value.t) list) (q : Query.t) (extra : Ask.item list) (outer : bool array) =
  let n = q.vars in
  let key env = let b = Buffer.create 16 in Array.iter (function Some x -> Buffer.add_char b '\001'; Value.encode b x | None -> Buffer.add_char b '\000') env; Buffer.contents b in
  (* every extension of env that makes the items hold: patterns first, then the conditions *)
  let rec holds env (items : Ask.item list) k =
    let pats = List.filter_map (function Ask.Pattern p -> Some p | _ -> None) items
    and conds = List.filter (function Ask.Range _ | In _ -> true | _ -> false) items in
    let env = Array.copy env in
    let bind t (x : Value.t) k =
      match t with
      | Query.Var i -> (match env.(i) with None -> env.(i) <- Some x; k (); env.(i) <- None | Some y -> if Value.equal x y then k ())
      | Thing e -> if Value.equal x (Link e) then k ()
      | Val y -> if Value.equal x y then k ()
    in
    let rec go = function
      | [] ->
        if List.for_all
            (function
              | Ask.Range (x, lo, hi) -> (match env.(x) with Some w -> int_of w >= int_of lo && int_of w <= int_of hi | None -> false)
              | In (x, l) -> (match env.(x) with Some w -> List.exists (Value.equal w) l | None -> false)
              | _ -> true)
            conds
        then k (Array.copy env)
      | (pt : Query.pattern) :: rest -> List.iter (fun (e, p, x) -> if p = pt.p then bind pt.e (Link e) (fun () -> bind pt.v x (fun () -> go rest))) fl
    in
    ignore holds;
    go pats
  in
  let project env = Array.mapi (fun i x -> if outer.(i) then x else None) env in
  let dedup l = let t = Hashtbl.create 16 in List.filter (fun e -> let k = key e in if Hashtbl.mem t k then false else (Hashtbl.replace t k (); true)) l in
  let top = List.map (fun p -> Ask.Pattern p) q.where in
  let start = ref [] in
  holds (Array.make n None) top (fun e -> start := project e :: !start);
  let envs =
    List.fold_left
      (fun envs it ->
        match it with
        | Ask.Or alts ->
          dedup (List.concat_map (fun env -> List.concat_map (fun a -> let out = ref [] in holds env a (fun e -> out := project e :: !out); !out) alts) envs)
        | _ -> envs)
      (dedup !start) extra
  in
  (* the conditions of the question, then its Nots *)
  let conds = List.filter (function Ask.Range _ | In _ -> true | _ -> false) (List.map (fun (x, lo, hi) -> Ask.Range (x, lo, hi)) q.ranges @ extra) in
  let envs = List.filter (fun env -> let ok = ref false in holds env conds (fun _ -> ok := true); !ok) envs in
  let envs = List.filter (fun env -> List.for_all (function Ask.Not l -> let found = ref false in holds env l (fun _ -> found := true); not !found | _ -> true) extra) envs in
  List.map (Array.map (function Some x -> x | None -> Value.Int 0)) envs

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

let engine ?(extra = []) v q sel o =
  let a = Answer.answer ~order:o ~extra v q sel in
  let typs = Array.init a.cols a.typ in
  List.init a.n (fun i -> Array.init a.cols (fun j -> Store.value v typs.(j) (a.word i j)))

(* the request through the wire: coded, read back *)
let wired q extra sel (o : Top.order) =
  let b = Buffer.create 64 in
  Wire.put_request b (Wire.Find { db = 0; query = q; select = sel; extra; order = o });
  let s = Buffer.contents b in
  match Wire.get_request Wire.k_find (Codec.reader (Bytes.of_string s) 0 (String.length s)) with
  | Wire.Find f -> f.query, f.extra, f.select, f.order
  | _ -> assert false

let same a b = List.length a = List.length b && List.for_all2 (fun x y -> Array.for_all2 Value.equal x y) a b

let show rows = String.concat " | " (List.map (fun r -> String.concat "," (Array.to_list (Array.map Value.to_string r))) rows)

let questions = ref 0 and with_order = ref 0 and empties = ref 0 and with_ops = ref 0

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
        (* Not, Or and In half of the time: their own variables numbered after the question's *)
        let ty_of k = match k with 7 -> Value.Ttext | 8 -> Tlink | 9 -> Tbool | k -> tv k in
        let q, extra, typs, outer =
          if Rng.int r 2 = 0 then q, [], typs, Array.make nv true
          else begin
            let nvars = ref nv and more = ref [] and bound_by_or = ref [] in
            let fresh ty = let x = !nvars in incr nvars; more := !more @ [ ty ]; x in
            let value_of p = match List.filter (fun (_, p', _) -> p' = p) fl with [] -> None | l -> let _, _, x = List.nth l (Rng.int r (List.length l)) in Some x in
            let pat k =
              (* a pattern on x0, of property k: its value a constant of the data, or a variable of its own *)
              let p = prop_of.(k) in
              match value_of p with
              | Some x when Rng.int r 3 = 0 -> Ask.Pattern { Query.e = Var 0; p; v = Val x }
              | _ -> Ask.Pattern { Query.e = Var 0; p; v = Var (fresh (ty_of k)) }
            in
            let last_var () = !nvars - 1 in
            let cond_on x ty =
              match ty with
              | Value.Tint -> [ Ask.Range (x, Int (Rng.int r 30 - 10), Int (Rng.int r 30)) ]
              | Ttext -> [ Ask.In (x, List.init (1 + Rng.int r 3) (fun _ -> Value.Text names.(Rng.int r 6))) ]
              | _ -> []
            in
            let items = ref [] in
            for _ = 1 to 1 + Rng.int r 2 do
              match Rng.int r 4 with
              | 0 ->
                (* In on a variable of the question *)
                let x = Rng.int r nv in
                let p = List.find_map (fun (pt : Query.pattern) -> match pt.v with Var y when y = x -> Some pt.p | _ -> None) where in
                let vals = match p with
                  | Some p -> List.filter_map (fun _ -> value_of p) (List.init (1 + Rng.int r 3) Fun.id)
                  | None -> List.init (1 + Rng.int r 3) (fun _ -> Value.Link (65536 + Rng.int r (n + 2))) in
                let vals = if Rng.int r 4 = 0 then (match typs.(x) with Ttext -> Value.Text "none of them" :: vals | Tlink -> Link 999_999 :: vals | _ -> vals) else vals in
                if vals <> [] then items := Ask.In (x, vals) :: !items
              | 1 ->
                (* Not: a pattern of x0, and now and then a condition on the Not's own variable *)
                let k = Rng.int r 10 in
                let it = pat k in
                let extra = match it with Ask.Pattern { v = Var y; _ } when Rng.bool r -> cond_on y (ty_of k) | _ -> [] in
                items := Ask.Not (it :: extra) :: !items
              | 2 ->
                (* Or of patterns of x0 of different properties, or of And *)
                let ks = List.sort_uniq compare (List.init (2 + Rng.int r 2) (fun _ -> Rng.int r 10)) in
                let ks = if List.length ks < 2 then [ 0; 7 ] else ks in
                items := Ask.Or (List.map (fun k -> let it = pat k in match it with Ask.Pattern { v = Var y; _ } when Rng.bool r -> it :: cond_on y (ty_of k) | _ -> [ it ]) ks) :: !items
              | _ ->
                (* an Or that binds a variable of the question: the score of x0, in one range or another *)
                let y = fresh Value.Tint in
                bound_by_or := y :: !bound_by_or;
                let alt () = [ Ask.Pattern { Query.e = Var 0; p = score; v = Var y }; Ask.Range (y, Int (Rng.int r 30 - 10), Int (Rng.int r 40)) ] in
                ignore last_var;
                items := Ask.Or [ alt (); alt () ] :: !items
            done;
            let typs = Array.append typs (Array.of_list !more) in
            let outer = Array.init !nvars (fun x -> x < nv || List.mem x !bound_by_or) in
            { q with vars = !nvars }, List.rev !items, typs, outer
          end
        in
        let outs = List.filter (fun x -> outer.(x)) (List.init q.vars Fun.id) in
        let sel =
          match Rng.int r 3 with
          | 0 -> Wire.Give (Array.of_list outs)
          | 1 -> let g = List.filter (fun _ -> Rng.int r 2 = 0) outs in Wire.Give (Array.of_list (if g = [] then [ 0 ] else g))
          | _ ->
            let keys = Array.of_list (List.filter (fun _ -> Rng.int r 2 = 0) outs) in
            let aggs = List.filter_map (fun x -> if Rng.int r 3 = 0 && (match typs.(x) with Tint | Tmoney _ -> true | _ -> false) then Some (Wire.Sum x) else if Rng.int r 4 = 0 && (match typs.(x) with Tint | Tmoney _ | Tdate -> true | _ -> false) then Some (if Rng.bool r then Wire.Min x else Max x) else None) outs in
            Wire.Group (keys, Array.of_list (Wire.Count :: aggs))
        in
        if extra <> [] then incr with_ops;
        let ctyp, rows = rows_of typs (if extra = [] then bindings fl q else bindings_ask fl q extra outer) sel in
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
          match engine ~extra v q sel o with
          | got -> check name got
          | exception Query.Bad m -> C.fail "seed %d: %s refused: %s" seed name m
        in
        run_path Top.Heap "heap"; run_path Top.Index "index"; run_path Top.Auto "auto";
        let q', extra', sel', o' = wired q extra sel o in
        Top.path := Auto;
        (match engine ~extra:extra' v q' sel' o' with got -> check "wired" got | exception Query.Bad m -> C.fail "seed %d: wired refused: %s" seed m)
      done)
    views

(* ---- live questions with Not, Or and In: after every frame, a watch's rows are the oracle's at its view ---- *)

let live_checks = ref 0

let live seed =
  let r = Rng.make (seed + 1_000_000) in
  let db = fork empty in
  let[@warning "-8"] (Ok [ name; tag; score; _; _; _; _; owner; _; _ ]) = declare db props in
  let v = ref (view db) in
  let hub = Live.create !v ~tag:!v.group ~durable:!v.group in
  let things = ref [||] in
  let pick () = if Array.length !things = 0 then Store.max_thing !v + 1 else !things.(Rng.int r (Array.length !things)) in
  let tags = [| "hot"; "cold" |] in
  let forms =
    [| (fun () -> { Query.vars = 2; where = [ { e = Var 0; p = name; v = Var 1 } ]; ranges = [] }, [ Ask.Not [ Pattern { e = Var 0; p = tag; v = Val (Text tags.(Rng.int r 2)) } ] ], Wire.Give [| 0; 1 |]);
       (fun () -> { Query.vars = 2; where = []; ranges = [] },
                  [ Ask.Or [ [ Pattern { e = Var 0; p = tag; v = Val (Text "hot") } ]; [ Pattern { e = Var 0; p = score; v = Var 1 }; Range (1, Int 10, Int 50) ] ] ], Wire.Give [| 0 |]);
       (fun () -> { Query.vars = 2; where = [ { e = Var 0; p = score; v = Var 1 } ]; ranges = [] }, [ Ask.In (1, List.init 3 (fun _ -> Value.Int (Rng.int r 60))) ], Wire.Give [| 0; 1 |]);
       (fun () -> { Query.vars = 3; where = [ { e = Var 0; p = name; v = Var 1 } ]; ranges = [] }, [ Ask.Not [ Pattern { e = Var 2; p = owner; v = Var 0 } ] ], Wire.Group ([| 1 |], [| Wire.Count |]));
       (fun () -> { Query.vars = 2; where = [ { e = Var 0; p = owner; v = Var 1 } ]; ranges = [] }, [ Ask.In (1, List.init 2 (fun _ -> Value.Link (pick ()))) ], Wire.Give [| 0 |]) |]
  in
  let watches = ref [] in
  let add () =
    let q, extra, sel = forms.(Rng.int r (Array.length forms)) () in
    let rows = ref None in
    let emit (m : Live.msg) =
      (match m with
       | Answer a -> rows := Some a.rows
       | Change c ->
         let cur = Option.value !rows ~default:[] in
         let rec remove x = function [] -> C.fail "seed %d: live: a row removed that is not there" seed; [] | y :: rest -> if Array.for_all2 Value.equal x y then rest else y :: remove x rest in
         rows := Some (c.added @ List.fold_left (fun acc x -> remove x acc) cur c.removed)
       | Same _ | Ended _ -> ());
      true
    in
    match Live.subscribe ~extra hub q sel ~from:0 ~emit with
    | _ -> watches := (q, extra, sel, rows) :: !watches
    | exception Query.Bad m -> C.fail "seed %d: live: refused: %s" seed m
  in
  for _ = 1 to 4 do add () done;
  for _ = 1 to 40 do
    let n = !v.group + 1 in
    let x = pick () in
    let ops =
      match Rng.int r 6 with
      | 0 -> [ Resolve.Add (-1, name, Text names.(Rng.int r 4)); Add (-1, score, Int (Rng.int r 60)); Add (-1, owner, Link (pick ())) ]
      | 1 -> [ Add (x, tag, Text tags.(Rng.int r 2)) ]
      | 2 -> (match Cepheus.values !v x tag with t :: _ -> [ Retract (x, tag, t) ] | [] -> [ Add (x, score, Int (Rng.int r 60)) ])
      | 3 -> [ Add (x, owner, Link (pick ())) ]
      | 4 -> (match Cepheus.values !v x owner with o :: _ -> [ Retract (x, owner, o) ] | [] -> [ Add (x, name, Text names.(Rng.int r 4)) ])
      | _ -> [ Add (x, score, Int (Rng.int r 60)) ]
    in
    (match Resolve.resolve !v ~n ~time:n ~by:0 ~why:"" ops with
     | Ok (v', g, temps) ->
       v := v';
       List.iter (fun (_, e) -> things := Array.append !things [| e |]) temps;
       Live.frame hub ~tag:v'.group [ g ] v';
       Live.durable hub v'.group
     | Error _ -> ());
    if Rng.int r 8 = 0 then add ();
    let fl = C.F.elements (C.facts_of_view !v) in
    List.iter
      (fun (q, extra, sel, rows) ->
        incr live_checks;
        let a = Ask.compile !v q extra in
        let typs = Ask.typs_of a in
        let _, want = rows_of typs (bindings_ask fl q extra a.outer) sel in
        let key r = let b = Buffer.create 16 in Array.iter (Value.encode b) r; Buffer.contents b in
        let norm l = List.sort compare (List.map key l) in
        match !rows with
        | Some got -> if norm got <> norm want then C.fail "seed %d: live, group %d: %d rows, %d expected" seed !v.group (List.length got) (List.length want) else C.check true ""
        | None -> C.fail "seed %d: live: no answer" seed)
      !watches
  done

let () =
  let seeds = ref 300 and one = ref None in
  Arg.parse [ "--seeds", Arg.Set_int seeds, "N"; "--seed", Arg.Int (fun s -> one := Some s), "S" ] (fun _ -> ()) "questions.exe";
  (match !one with Some s -> run s; live s | None -> for s = 1 to !seeds do run s; if s mod 3 = 0 then live s done);
  Printf.printf "questions: %d questions (%d with an order, %d with Not, Or or In, %d empty), %d windows of the index path, %d given up for the heap path\n"
    !questions !with_order !with_ops !empties (Atomic.get Top.windows) (Atomic.get Top.gave_up);
  Printf.printf "questions: %d checks of live questions with Not, Or and In after a frame\n" !live_checks;
  C.finish "questions"
