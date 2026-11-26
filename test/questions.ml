(* Questions against an oracle: random states (every type of value, one and many values, texts that share their
   first bytes, floats with nan, -0 and the infinities, extreme ints, facts a rule derives, retractions), read from
   the delta and from runs merged at random; random questions (patterns, ranges, a select that gives every
   variable, leaves some out, or aggregates; Not, Or, In, Prefix, Less between two variables, ranges of floats, and
   Optional, whose missing cells sort last) with a random Sort, Limit and After. The oracle answers each one by brute
   force over every fact of the view: every binding, its row, the groups, the order compared value by value, the
   rows after the cursor, the first k and their copies. The engine must give the same rows in the same order, by the
   heap path, by the index path and by its own choice, and the same again after the request's trip through the wire.
   A failure prints its seed; [questions.exe --seed N] replays it. *)

open Cepheus
module Ask = Question.Ask
module Top = Question.Top
open Cepheus_server
module C = Check

let props =
  [ prop "name" Ttext; prop ~many:true "tag" Ttext; prop "score" Tint; prop "price" (Tmoney 2); prop "when" Tdate;
    prop "ratio" Tfloat; prop "ok" Tbool; prop "owner" Tlink; prop ~many:true "friend" Tlink; prop "mark" Tbool ]

let names = [| "a"; "ab"; "abc"; "Ad"; "ad"; "Ada"; "\195\132d"; "z"; "\195\169"; ""; "b"; "ab\000" |]
let floats = [| 0.; -0.; 1.5; -2.25; nan; -.nan; infinity; neg_infinity; 1e300; 3. |]
(* prefixes: of one text, of several, of none, a lone first byte of a two-byte character, a NUL *)
let prefixes = [| "a"; "ab"; "abc"; "A"; "Ad"; "ad"; "\195"; "\195\132"; "zz"; "b"; "ab\000" |]

(* dates: a few milliseconds apart, and the instants about the summer time changes of Paris and New York in 2026,
   the last half hour of 2026 *)
let dates = [| 1_700_000_000_000; 1_700_000_000_001; 1_700_000_000_002; 1_700_000_000_003; 1_700_000_000_004; 1774744200000; 1774746000000;
               1774747800000; 1792888200000; 1792890000000; 1792891800000; 1798759800000; 1793511000000; 1793514600000 |]

let units = [| "second"; "minute"; "hour"; "day"; "week"; "month"; "quarter"; "year"; "decade"; "century"; "millennium" |]
let zones = [| "UTC"; "Europe/Paris"; "America/New_York"; "Australia/Lord_Howe" |]

(* Trunc in UTC by the C library's calendar (this process runs in TZ=UTC: mktime is timegm), apart from Zone's; in
   another zone, Zone's (its offsets are checked against the C library's in reports.exe) *)
let trunc_oracle u z (x : Value.t) =
  match x with
  | Date ms when z = "UTC" ->
    let s = if ms >= 0 then ms / 1000 else -(((-ms) + 999) / 1000) in
    let tm = Unix.gmtime (float_of_int s) in
    let at ?(mon = tm.tm_mon) ?(mday = tm.tm_mday) ?(year = tm.tm_year) () =
      int_of_float (fst (Unix.mktime { tm with tm_year = year; tm_mon = mon; tm_mday = mday; tm_hour = 0; tm_min = 0; tm_sec = 0; tm_isdst = false }))
    in
    let y = tm.tm_year + 1900 in
    let first y = 100 * ((y - 1) / 100) + 1 in
    let r =
      match u with
      | "second" -> s
      | "minute" -> s - tm.tm_sec
      | "hour" -> s - tm.tm_sec - (60 * tm.tm_min)
      | "day" -> at ()
      | "week" -> at () - (86400 * ((tm.tm_wday + 6) mod 7))
      | "month" -> at ~mday:1 ()
      | "quarter" -> at ~mday:1 ~mon:(3 * (tm.tm_mon / 3)) ()
      | "year" -> at ~mday:1 ~mon:0 ()
      | "decade" -> at ~mday:1 ~mon:0 ~year:(y - (y mod 10) - 1900) ()
      | "century" -> at ~mday:1 ~mon:0 ~year:(first y - 1900) ()
      | _ -> at ~mday:1 ~mon:0 ~year:((1000 * ((y - 1) / 1000)) + 1 - 1900) ()
    in
    Value.Date (1000 * r)
  | Date ms -> Value.Date (Zone.trunc (Zone.find z) (Zone.unit_of u) ms)
  | x -> x

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

let in_range lo w hi = cmp_value lo w <= 0 && cmp_value w hi <= 0

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
      if List.for_all (fun (x, lo, hi) -> in_range lo row.(x) hi) q.ranges then out := row :: !out
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
    and conds = List.filter (function Ask.Range _ | In _ | Prefix _ | Less _ | Less_or_equal _ -> true | _ -> false) items in
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
              | Ask.Range (x, lo, hi) -> (match env.(x) with Some w -> in_range lo w hi | None -> false)
              | Less (x, y) -> (match env.(x), env.(y) with Some a, Some b -> cmp_value a b < 0 | _ -> false)
              | Less_or_equal (x, y) -> (match env.(x), env.(y) with Some a, Some b -> cmp_value a b <= 0 | _ -> false)
              | In (x, l) -> (match env.(x) with Some w -> List.exists (Value.equal w) l | None -> false)
              | Prefix (x, pre) -> (match env.(x) with Some (Text t) -> String.starts_with ~prefix:pre t | _ -> false)
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
  let conds = List.filter (function Ask.Range _ | In _ | Prefix _ | Less _ | Less_or_equal _ -> true | _ -> false) (List.map (fun (x, lo, hi) -> Ask.Range (x, lo, hi)) q.ranges @ extra) in
  let envs = List.filter (fun env -> let ok = ref false in holds env conds (fun _ -> ok := true); !ok) envs in
  let envs = List.filter (fun env -> List.for_all (function Ask.Not l -> let found = ref false in holds env l (fun _ -> found := true); not !found | _ -> true) extra) envs in
  (* the Optionals last: a binding a value of the thing's property, or one with the variable missing *)
  let expand envs (pt : Query.pattern) =
    List.concat_map
      (fun env ->
        let e = match pt.e with Query.Var x -> (match env.(x) with Some (Value.Link e) -> e | _ -> assert false) | Thing e -> e | Val _ -> assert false in
        let y = match pt.v with Query.Var y -> y | _ -> assert false in
        let set x = let env = Array.copy env in env.(y) <- Some x; env in
        match List.sort_uniq Value.compare (List.filter_map (fun (e', p, x) -> if e' = e && p = pt.p then Some x else None) fl) with
        | [] -> [ set Value.missing ]
        | l -> List.map set l)
      envs
  in
  let envs = List.fold_left expand envs (List.filter_map (function Ask.Optional p -> Some p | _ -> None) extra) in
  List.map (Array.map (function Some x -> x | None -> Value.Int 0)) envs

(* ---- the oracle of the reports' aggregates (protocol 9): each computed again by brute force ---- *)

(* a cell of a group: a value, or the list of Values *)
type cell = One of Value.t | Many of Value.t list

(* a value computed in floats in an order of its own (approx): compared within 1e-9, relative; the others exactly *)
let approx_cols : bool array ref = ref [||]

let bits x = let b = Buffer.create 8 in Value.encode b x; Buffer.contents b

(* the different values, in Sort's order *)
let distinct vs =
  let t = Hashtbl.create 8 in
  List.sort cmp_value (List.filter (fun x -> let k = bits x in if Hashtbl.mem t k then false else (Hashtbl.replace t k (); true)) vs)

let small = function Value.Int a | Money a | Date a -> abs a < 1 lsl 20 && a <> min_int | Float _ -> false | _ -> false

(* a + (b - a) f rounded half away from zero *)
let lerp_int a b f = if f = 0. then a else a + Float.to_int (Float.round (float_of_int (b - a) *. f))

let fl = function Value.Int a | Money a | Date a -> float_of_int a | Float f -> f | _ -> nan

(* the oracle of one aggregate of protocol 9 over a group's values (Optionals' missing ones taken out), and whether
   its value is approximate *)
let report_agg (typs : Value.typ array) (a : Wire.agg) (all : Value.t list) =
  let present = List.filter (fun x -> not (Value.is_missing x)) all in
  let tx x = typs.(x) in
  match a with
  | Wire.Distinct _ -> One (Value.Int (List.length (distinct present))), false
  | Values _ -> Many (distinct present), false
  | Avg x -> (
    let n = List.length all in
    match tx x with
    | Tmoney _ | Tdate ->
      let s = List.fold_left (fun s v -> s + int_of v) 0 all in
      let q = s / n and r = s mod n in
      let q = if 2 * abs r >= n then (if s < 0 then q - 1 else q + 1) else q in
      One (if tx x = Tdate then Value.Date q else Money q), false
    | Tint when List.for_all small all -> One (Value.Float (float_of_int (List.fold_left (fun s v -> s + int_of v) 0 all) /. float_of_int n)), false
    | Tfloat when List.exists (fun v -> Float.is_nan (fl v)) all || (List.mem (Value.Float infinity) all && List.mem (Value.Float neg_infinity) all) -> One (Float nan), false
    | Tfloat when List.mem (Value.Float infinity) all -> One (Float infinity), false
    | Tfloat when List.mem (Value.Float neg_infinity) all -> One (Float neg_infinity), false
    | _ -> let xs = List.sort compare (List.map fl all) in One (Value.Float (List.fold_left ( +. ) 0. xs /. float_of_int n)), true)
  | Variance (x, pop) | Stddev (x, pop) ->
    let n = List.length all in
    let fin v = match a with Stddev _ -> Float.sqrt v | _ -> v in
    if (not pop) && n < 2 then One Value.missing, false
    else if List.exists (fun v -> not (Float.is_finite (fl v))) all then One (Float nan), false
    else begin
      let scale = match tx x with Tmoney sc -> float_of_int (int_of_float (10. ** float_of_int sc)) | _ -> 1. in
      let den = float_of_int (if pop then n * n else n * (n - 1)) *. scale *. scale in
      if List.for_all small all then begin
        let s1 = List.fold_left (fun s v -> s + int_of v) 0 all and s2 = List.fold_left (fun s v -> s + (int_of v * int_of v)) 0 all in
        One (Float (fin (float_of_int ((n * s2) - (s1 * s1)) /. den))), false
      end
      else begin
        let xs = List.sort compare (List.map fl all) in
        let m = List.fold_left ( +. ) 0. xs /. float_of_int n in
        let ss = List.fold_left (fun s v -> s +. ((v -. m) *. (v -. m))) 0. xs in
        One (Float (fin (ss *. float_of_int n /. den))), true
      end
    end
  | Quantile (x, p, discrete) ->
    let sorted = Array.of_list (List.stable_sort cmp_value all) in
    let n = Array.length sorted in
    if discrete then One sorted.(max 1 (Float.to_int (Float.ceil (p *. float_of_int n))) - 1), false
    else begin
      let h = p *. float_of_int (n - 1) in
      let lo = Float.to_int (Float.floor h) and hi = Float.to_int (Float.ceil h) in
      let f = h -. Float.floor h in
      let a = sorted.(lo) and b = sorted.(hi) in
      match tx x with
      | Tint | Tfloat -> One (Float (if lo = hi then fl a else fl a +. ((fl b -. fl a) *. f))), false
      | Tmoney _ -> One (Money (if lo = hi then int_of a else lerp_int (int_of a) (int_of b) f)), false
      | _ -> One (Date (if lo = hi then int_of a else lerp_int (int_of a) (int_of b) f)), false
    end
  | Count | Sum _ | Min _ | Max _ -> assert false

let report_typ (typs : Value.typ array) (a : Wire.agg) =
  match a with
  | Wire.Distinct _ -> Value.Tint
  | Values x | Quantile (x, _, true) -> typs.(x)
  | Avg x | Quantile (x, _, false) -> (match typs.(x) with Tint -> Tfloat | t -> t)
  | Variance _ | Stddev _ -> Tfloat
  | Count -> Tint
  | Sum x | Min x | Max x -> typs.(x)

(* an exact sum of ints as two ints (each value hi 2^31 + lo), None past the 63 bits of an int *)
let exact_sum (xs : int list) =
  let m = (1 lsl 31) - 1 in
  let h, l = List.fold_left (fun (h, l) x -> h + (x asr 31), l + (x land m)) (0, 0) xs in
  let h = h + (l asr 31) and l = l land m in
  if h < -(1 lsl 31) || h > (1 lsl 31) - 1 then None else Some ((h lsl 31) lor l)

(* a group's Sum past the 63 bits of an Int: the engine refuses the question, naming the Sum ("Sum of ...") *)
exception Sum_past

let group_sum bs x = match exact_sum (List.map (fun b -> int_of b.(x)) bs) with Some s -> s | None -> raise Sum_past

(* the rows of a select, with their columns' types: each row's cells (a list for Values) *)
let groups_of (typs : Value.typ array) bs (sel : Wire.select) =
  approx_cols := [||];
  match sel with
  | Give g -> Array.map (fun x -> typs.(x)) g, List.map (fun b -> Array.map (fun x -> One b.(x)) g) bs
  | Group (keys, aggs) when Array.exists (function Wire.Count | Sum _ | Min _ | Max _ -> false | _ -> true) aggs ->
    let t = Hashtbl.create 16 in
    List.iter
      (fun b ->
        let k = Array.map (fun x -> b.(x)) keys in
        let kk = String.concat "" (Array.to_list (Array.map bits k)) in
        let _, l = try Hashtbl.find t kk with Not_found -> k, [] in
        Hashtbl.replace t kk (k, b :: l))
      bs;
    let approx = Array.make (Array.length keys + Array.length aggs) false in
    let agg bs i = function
      | Wire.Count -> One (Value.Int (List.length bs))
      | Sum x -> let s = group_sum bs x in One (match typs.(x) with Tmoney _ -> Money s | Tdate -> Date s | _ -> Int s)
      | Min x -> One (List.fold_left (fun m b -> if cmp_value b.(x) m < 0 then b.(x) else m) (List.hd bs).(x) bs)
      | Max x -> One (List.fold_left (fun m b -> if cmp_value b.(x) m > 0 then b.(x) else m) (List.hd bs).(x) bs)
      | a ->
        let x = match a with Avg x | Distinct x | Values x | Quantile (x, _, _) | Variance (x, _) | Stddev (x, _) -> x | _ -> 0 in
        let c, ap = report_agg typs a (List.map (fun b -> b.(x)) bs) in
        if ap then approx.(Array.length keys + i) <- true;
        c
    in
    let ctyp = Array.append (Array.map (fun x -> typs.(x)) keys) (Array.map (report_typ typs) aggs) in
    approx_cols := approx;
    ctyp, Hashtbl.fold (fun _ (k, bs) acc -> Array.append (Array.map (fun x -> One x) k) (Array.mapi (fun i a -> agg bs i a) aggs) :: acc) t []
  | Group _ -> (
    match sel with
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
      | Sum x -> let s = group_sum bs x in (match typs.(x) with Tmoney _ -> Money s | _ -> Int s)
      | Min x -> List.fold_left (fun m b -> if cmp_value b.(x) m < 0 then b.(x) else m) (List.hd bs).(x) bs
      | Max x -> List.fold_left (fun m b -> if cmp_value b.(x) m > 0 then b.(x) else m) (List.hd bs).(x) bs
      | _ -> assert false
    in
    let ctyp = Array.append (Array.map (fun x -> typs.(x)) keys)
        (Array.map (function Wire.Sum x | Min x | Max x -> typs.(x) | _ -> Value.Tint) aggs) in
    ctyp, Hashtbl.fold (fun _ (k, bs) acc -> Array.map (fun x -> One x) (Array.append k (Array.map (agg bs) aggs)) :: acc) t []
    | Give _ -> assert false)

(* a group's rows: one a value of its longest list (one at least), a list's cell missing past its end *)
let flatten (c : cell array) =
  let n = Array.fold_left (fun m -> function Many l -> max m (List.length l) | One _ -> m) 1 c in
  List.init n (fun i -> Array.map (function One x -> x | Many l -> (match List.nth_opt l i with Some x -> x | None -> Value.missing)) c)

(* a group as the order sees it: a list takes no part *)
let plain c = Array.map (function One x -> x | Many _ -> Value.Int 0) c

let ordered cols (o : Top.order) =
  let listed = List.map (fun (k : Top.key) -> k.col) o.keys in
  o.keys @ List.filter_map (fun c -> if List.mem c listed then None else Some { Top.col = c; desc = false }) (List.init cols Fun.id)

(* a missing cell after every value, in both directions *)
let cmp_row ord a b =
  List.fold_left
    (fun c (k : Top.key) ->
      if c <> 0 then c
      else
        match Value.is_missing a.(k.col), Value.is_missing b.(k.col) with
        | true, true -> 0
        | true, false -> 1
        | false, true -> -1
        | false, false -> let x = cmp_value a.(k.col) b.(k.col) in if k.desc then -x else x)
    0 ord

(* the groups in the order, after the cursor, the first k and their copies, each then its rows (a Values column takes
   no part in the order: the cursor's is set aside too) *)
let oracle cols groups (o : Top.order) =
  let ord = ordered cols o in
  let groups = List.stable_sort (fun a b -> cmp_row ord (plain a) (plain b)) groups in
  let groups =
    match o.after with
    | None -> groups
    | Some a ->
      let a = match groups with g :: _ -> Array.mapi (fun j x -> match g.(j) with Many _ -> Value.Int 0 | One _ -> x) a | [] -> a in
      List.filter (fun r -> cmp_row ord (plain r) a > 0) groups
  in
  let groups =
    if o.limit = 0 then groups
    else begin
      let first = List.filteri (fun i _ -> i < o.limit) groups in
      match List.rev first with
      | [] -> []
      | last :: _ ->
        (* the copies of the k-th row, which follow it *)
        first @ List.filter (fun r -> cmp_row ord (plain r) (plain last) = 0) (List.filteri (fun i _ -> i >= o.limit) groups)
    end
  in
  List.concat_map flatten groups


(* ---- the oracle of windows and Each (protocol 10): each window computed again by brute force ---- *)

let with_windows = ref 0 and with_each = ref 0 and window_cells = ref 0 and window_refusals = ref 0

exception Overflow

(* the windows' values of rows sorted in the order [ord], each group of [each] apart; [ctyp] the columns' types; and
   whether each window's values are approximate (an Avg in floats) *)
let window_oracle (ctyp : Value.typ array) ord (each : int array) (windows : Wire.window array) (rows : Value.t array list) =
  let rows = Array.of_list rows in
  let n = Array.length rows in
  let key i = String.concat "" (Array.to_list (Array.map (fun c -> bits rows.(i).(c)) each)) in
  let before i = List.filter (fun j -> j < i && key j = key i) (List.init n Fun.id) in
  let tie k i j = cmp_row (List.filteri (fun x _ -> x < k) ord) rows.(i) rows.(j) = 0 in
  let approx = Array.make (Array.length windows) false in
  let out =
    Array.mapi
      (fun wi (w : Wire.window) ->
        Array.init n (fun i ->
            (* a sum past 63 bits: None, the engine refuses the question when that row is one it gives *)
            try Some (
            let prev = before i in
            let p = List.length prev in
            match w with
            | Running (a, last) -> (
              let frame = List.filteri (fun x _ -> last = 0 || x >= p - (last - 1)) (prev @ [ i ]) in
              let vals c = List.filter (fun x -> not (Value.is_missing x)) (List.map (fun j -> rows.(j).(c)) frame) in
              match a with
              | Wire.Count -> Value.Int (List.length frame)
              | Sum c -> (
                match vals c with
                | [] -> Value.missing
                | vs -> (match exact_sum (List.map int_of vs) with None -> raise Overflow | Some x -> (match ctyp.(c) with Tmoney _ -> Money x | _ -> Int x)))
              | Avg c -> (
                match vals c, ctyp.(c) with
                | [], _ -> Value.missing
                | vs, Tint when exact_sum (List.map int_of vs) <> None ->
                  (* the exact sum, then one division: within a rounding of the engine's *)
                  approx.(wi) <- true;
                  Value.Float (float_of_int (Option.get (exact_sum (List.map int_of vs))) /. float_of_int (List.length vs))
                | vs, _ -> (match report_agg ctyp (Wire.Avg c) vs with One x, ap -> if ap then approx.(wi) <- true; x | Many _, _ -> assert false))
              | Min c | Max c -> (
                match vals c with
                | [] -> Value.missing
                | v0 :: vs ->
                  let better x y = let d = cmp_value x y in match a with Min _ -> d < 0 | _ -> d > 0 in
                  List.fold_left (fun m x -> if better x m then x else m) v0 vs)
              | _ -> assert false)
            | Rank (k, dense) ->
              let tied = List.filter (fun j -> not (tie k j i)) prev in
              if not dense then Value.Int (1 + List.length tied)
              else begin
                (* the places before: a new one at each row not tied with the one before it *)
                let all = prev @ [ i ] in
                let rec places acc last = function [] -> acc | j :: tl -> (match last with Some l when tie k l j -> places acc last tl | _ -> places (acc + 1) (Some j) tl) in
                Value.Int (places 0 None all)
              end
            | Prev (c, back) -> if p >= back then rows.(List.nth prev (p - back)).(c) else Value.missing)
            with Overflow -> None))
      windows
  in
  out, approx

(* random windows and Each over a select's rows: [cols] columns of types [ctyp], [keys] of them keys *)
let random_windows r (ctyp : Value.typ array) ~nkeys ~sorts =
  let cols = Array.length ctyp in
  let pick l = List.nth l (Rng.int r (List.length l)) in
  let of_types ts = List.filter (fun c -> List.exists (fun t -> match t, ctyp.(c) with `I, Value.Tint | `M, Tmoney _ | `D, Tdate | `F, Tfloat -> true | _ -> false) ts) (List.init cols Fun.id) in
  let last () = if Rng.bool r then 0 else 1 + Rng.int r 4 in
  let one () =
    match Rng.int r 7 with
    | 0 -> Some (Wire.Running (Count, last ()))
    | 1 -> (match of_types [ `I; `M ] with [] -> None | l -> Some (Wire.Running (Sum (pick l), last ())))
    | 2 -> (match of_types [ `I; `M; `D; `F ] with [] -> None | l -> Some (Wire.Running (Avg (pick l), last ())))
    | 3 -> (match of_types [ `I; `M; `D ] with [] -> None | l -> Some (Wire.Running ((if Rng.bool r then Min (pick l) else Max (pick l)), last ())))
    | 4 -> Some (Wire.Rank (1 + Rng.int r sorts, Rng.bool r))
    | _ -> Some (Wire.Prev (Rng.int r cols, 1 + Rng.int r 3))
  in
  let windows = List.filter_map (fun _ -> one ()) (List.init (Rng.int r 4) Fun.id) in
  let each = if nkeys = 0 || Rng.int r 3 = 0 then [] else List.sort_uniq compare (List.init (1 + Rng.int r 2) (fun _ -> Rng.int r nkeys)) in
  Array.of_list each, Array.of_list windows

(* ---- the engine ---- *)

let engine ?(extra = []) v q sel o =
  let a = Answer.answer ~order:o ~extra v q sel in
  List.init a.n (fun i -> Array.init a.cols (fun j -> Answer.value v a i j))

(* the request through the wire: coded, read back *)
let wired q extra sel (o : Top.order) =
  let b = Buffer.create 64 in
  Wire.put_request b (Wire.Find { db = 0; query = q; select = sel; extra; order = o; timeout = 0 });
  let s = Buffer.contents b in
  match Wire.get_request Wire.k_find (Codec.reader (Bytes.of_string s) 0 (String.length s)) with
  | Wire.Find f -> f.query, f.extra, f.select, f.order
  | _ -> assert false

(* a cell the oracle computed in floats in an order of its own: within 1e-9, relative *)
let close (x : Value.t) (y : Value.t) =
  match x, y with
  | Float a, Float b -> Value.equal x y || (Float.is_nan a && Float.is_nan b) || Float.abs (a -. b) <= 1e-9 *. Float.max (Float.abs a) (Float.abs b)
  | _ -> Value.equal x y

let same a b =
  let ap j = j < Array.length !approx_cols && !approx_cols.(j) in
  List.length a = List.length b && List.for_all2 (fun x y -> Array.length x = Array.length y && Array.for_all Fun.id (Array.mapi (fun j c -> if ap j then close c y.(j) else Value.equal c y.(j)) x)) a b

let show rows = String.concat " | " (List.map (fun r -> String.concat "," (Array.to_list (Array.map Value.to_string r))) rows)

let questions = ref 0 and with_order = ref 0 and empties = ref 0 and with_ops = ref 0
let with_less = ref 0 and with_optional = ref 0 and with_floats = ref 0 and with_missing = ref 0
let with_trunc = ref 0 and with_report = ref 0 and split_checks = ref 0 and sum_refusals = ref 0

let starts s pre = String.length s >= String.length pre && String.sub s 0 (String.length pre) = pre

(* Store.text_order: the texts of p in the order of their bytes, from a text on, merged over the runs and the delta:
   strictly in order, every text of p's facts at or after the start, none before it *)
let text_order seed (v : Store.view) fl p =
  let held = List.sort_uniq compare (List.filter_map (fun (_, p', x) -> match x with Value.Text s when p' = p -> Some s | _ -> None) fl) in
  List.iter
    (fun desc ->
      List.iter
        (fun from ->
          let next = Store.text_order v p ~desc ~from in
          let rec all acc = let w = next () in if w < 0 then List.rev acc else all (Store.text v w :: acc) in
          let got = all [] in
          let before a b = if desc then String.compare a b > 0 else String.compare a b < 0 in
          let rec sorted = function a :: (b :: _ as t) -> before a b && sorted t | _ -> true in
          let at s = match from with None -> true | Some f -> not (before s f) in
          C.check
            (sorted got && List.for_all at got && List.for_all (fun s -> List.mem s got) (List.filter at held))
            "seed %d: the text order of %d (desc %b, from %s): %s" seed p desc
            (match from with None -> "-" | Some f -> String.escaped f) (String.concat "," (List.map String.escaped got)))
        (None :: List.map Option.some [ "a"; "ab"; "Ad"; "\195"; "zz"; "" ]))
    [ false; true ]

(* Store.holders_from: the things that hold p (the fact (p, w)), in the order of their ids from a thing on, merged over
   the runs and the delta: strictly in order, every thing of p's facts (of (p, w)) at or past the start, none before
   it; and Store.count_holders: the facts of p of the things of a range, exact here (a delta of a few things) *)
let holders seed (v : Store.view) fl p =
  let facts = List.filter (fun (_, p', _) -> p' = p) fl in
  let things = List.sort_uniq compare (List.map (fun (e, _, _) -> e) fl) in
  let starts = min_int :: max_int :: 0 :: List.concat_map (fun e -> [ e - 1; e; e + 1 ]) things in
  let values = None :: List.filter_map (fun (_, _, x) -> Option.map Option.some (Store.word v x)) facts in
  List.iter
    (fun value ->
      let held = List.sort_uniq compare (List.filter_map (fun (e, _, x) -> match value with None -> Some e | Some w -> if Store.word v x = Some w then Some e else None) facts) in
      List.iter
        (fun desc ->
          List.iter
            (fun from ->
              (* the delta's things of p from its map by value (a few changes of p), and scanned by thing *)
              let got =
                List.map
                  (fun few ->
                    let keep = !Store.delta_few in
                    Store.delta_few := few;
                    Fun.protect ~finally:(fun () -> Store.delta_few := keep) (fun () ->
                        let next = Store.holders_from v p ?value ~desc ~from () in
                        let rec all acc = let e = next () in if e < 0 then List.rev acc else all (e :: acc) in
                        all []))
                  [ 512; 0 ]
              in
              let got = match got with [ a; b ] when a = b -> a | a :: _ -> -1 :: a | [] -> [] in
              let want = List.filter (fun e -> if desc then e <= from else e >= from) held in
              let want = if desc then List.rev want else want in
              C.check (got = want) "seed %d: the things of %d%s (desc %b, from %d): %s, not %s" seed p
                (match value with None -> "" | Some w -> Printf.sprintf " of value %d" w) desc from
                (String.concat "," (List.map string_of_int got)) (String.concat "," (List.map string_of_int want)))
            starts)
        [ false; true ])
    (List.sort_uniq compare values);
  List.iter
    (fun lo ->
      List.iter
        (fun len ->
          let hi = if len < 0 then max_int else lo + len in
          let want = List.length (List.filter (fun (e, _, _) -> e >= lo && e <= hi) facts) in
          let got = Store.count_holders v p lo hi in
          C.check (got = want) "seed %d: the facts of %d of the things %d to %d: %d, not %d" seed p lo hi got want)
        [ 0; 1; 5; -1 ])
    starts

let ask_checks = ref 0

let run seed =
  let r = Rng.make seed in
  (* a range of a thing whose pattern has a constant value: read from its first thing whatever the value's things, a
     seed in two *)
  Query.seek_min := if seed mod 2 = 0 then 0 else 64;
  (* the delta's things of a property scanned by thing (past a few changes of it) a seed in three *)
  Store.delta_few := if seed mod 3 = 1 then 0 else 512;
  (* a whole sort by the bits of its keys (Top.sort_radix) at every size, a seed in two *)
  Top.radix_min := if seed mod 2 = 1 then 2 else 4096;
  (* Each's buffers kept in the order (Limit up to 32), or cut back at 2 k rows, a seed in three *)
  Answer.small_each := if seed mod 3 = 0 then 0 else 32;
  let db = ref (fork empty) in
  let[@warning "-8"] (Ok [ name; tag; score; price; when_; ratio; ok; owner; friend; mark ]) = declare !db props in
  (* a rule: things whose score is 20 or more are marked (derived facts inside the questions) *)
  ignore
    (define !db
       [ { name = "high"; vars = 2; where = [ { e = Var 0; p = score; v = Var 1 } ]; ranges = [ (1, Int 20, Int max_int) ];
           head = Give { e = Var 0; p = mark; v = Val (Bool true) } } ]);
  (* a seed in three: links that name a kind, a thing with a name: an owner's link cleared, a friend's deleted with it *)
  let linked = seed mod 3 = 0 in
  if linked then ignore (Result.get_ok (link_to !db [ owner, "name", Clear; friend, "name", Cascade ]));
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
             let pick () = if Array.length !things = 0 then Value.Link (Store.max_thing (view !db) + 1) else Link !things.(Rng.int r (Array.length !things)) in
             List.filter_map Fun.id
               [ (if Rng.int r 4 > 0 then Some (Resolve.Add (t, name, Text names.(Rng.int r (Array.length names)))) else None);
                 (if Rng.int r 2 = 0 then Some (Resolve.Add (t, tag, Text names.(Rng.int r 4))) else None);
                 (if Rng.int r 3 > 0 then Some (Resolve.Add (t, score, Int (ints r))) else None);
                 (if Rng.int r 2 = 0 then Some (Resolve.Add (t, price, Money (Rng.int r 30))) else None);
                 (if Rng.int r 2 = 0 then Some (Resolve.Add (t, when_, Date dates.(Rng.int r (Array.length dates)))) else None);
                 (if Rng.int r 2 = 0 then Some (Resolve.Add (t, ratio, Float floats.(Rng.int r (Array.length floats)))) else None);
                 (if Rng.int r 2 = 0 then Some (Resolve.Add (t, ok, Bool (Rng.bool r))) else None);
                 (if Rng.int r 2 = 0 then Some (Resolve.Add (t, owner, pick ())) else None);
                 (if Rng.int r 3 = 0 then Some (Resolve.Add (t, friend, pick ())) else None) ]))
    in
    (match write !db ops with
     | Ok rc -> things := Array.append !things (Array.of_list (List.map snd rc.things))
     | Error _ -> ());
    (* retractions now and then *)
    (if Array.length !things > 0 && Rng.int r 3 = 0 then
       let t = !things.(Rng.int r (Array.length !things)) in
       match Cepheus.values (view !db) t score with x :: _ -> ignore (write !db [ Retract (t, score, x) ]) | [] -> ());
    (* and deletes: of a thing's name (its links follow), or its score *)
    (if Array.length !things > 0 && Rng.int r 2 = 0 then
       let t = !things.(Rng.int r (Array.length !things)) in
       ignore (write !db [ Delete (t, if Rng.int r 3 = 0 then "score" else "name") ]));
    if Rng.int r 3 = 0 then begin
      let v = view !db in
      (* the delta and some of the runs, the newest: the writes after it go on top of its run *)
      let take = Rng.int r (Array.length v.runs + 1) in
      let w = Snapshot.merge mdisk "/merge" "0123456789abcdef" v ~take ~level:(1 + Array.length v.runs) { Journal.segment = 1; offset = 40; next = v.group + 1 } in
      Snapshot.install mdisk "/merge" w;
      merged := Some w.view;
      db := fork w.view
    end
  done;
  let views = view !db :: (match !merged with Some m -> [ m ] | None -> []) in
  (* the links that name a kind hold in every view: an owner, a friend, is a thing with a name *)
  if linked then
    List.iter
      (fun (v : Store.view) ->
        let fl = C.F.elements (C.facts_of_view v) in
        List.iter
          (fun (e, p, x) ->
            match x with
            | Value.Link t when p = owner || p = friend ->
              C.check (List.exists (fun (e', p', _) -> e' = t && p' = name) fl) "seed %d: #%d links to #%d, which has no name" seed e t
            | _ -> ())
          fl)
      views;
  List.iter
    (fun (v : Store.view) ->
      let fl = C.F.elements (C.facts_of_view v) in
      text_order seed v fl name;
      text_order seed v fl tag;
      List.iter (holders seed v fl) [ name; tag; score; ok; owner; friend; mark ];
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
        (* a range of a float now and then, its bounds among the floats of the data (nan, -0, the infinities) *)
        let fl_vars = List.filter (fun x -> typs.(x) = Value.Tfloat) (List.init nv Fun.id) in
        let float_range x = let a = floats.(Rng.int r (Array.length floats)) and b = floats.(Rng.int r (Array.length floats)) in
          let a, b = if total_order a b <= 0 || Rng.int r 5 = 0 then a, b else b, a in (x, Value.Float a, Value.Float b) in
        let ranges = if fl_vars <> [] && Rng.int r 3 = 0 then float_range (List.nth fl_vars (Rng.int r (List.length fl_vars))) :: ranges else ranges in
        let q = { Query.vars = nv; where; ranges } in
        (* Not, Or and In half of the time: their own variables numbered after the question's *)
        let ty_of k = match k with 7 -> Value.Ttext | 8 -> Tlink | 9 -> Tbool | k -> tv k in
        let opt_vars = ref [] in
        let q, extra, typs, outer =
          if Rng.int r 2 = 0 then q, [], typs, Array.make nv true
          else begin
            let nvars = ref nv and more = ref [] and bound_by_or = ref [] and optionals = ref [] in
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
            (* two variables of the question of one type that Less compares (x0 with itself when none) *)
            let comparable = List.filter (fun x -> typs.(x) <> Value.Tbool) (List.init nv Fun.id) in
            let less_pair () =
              let pairs = List.concat_map (fun x -> List.filter_map (fun y -> if typs.(y) = typs.(x) && (x <> y || Rng.int r 4 = 0) then Some (x, y) else None) comparable) comparable in
              match pairs with [] -> 0, 0 | l -> List.nth l (Rng.int r (List.length l))
            in
            let less x y = if Rng.bool r then Ask.Less (x, y) else Ask.Less_or_equal (x, y) in
            let cond_on x ty =
              match ty with
              | Value.Tint when Rng.int r 3 = 0 -> (
                (* Less between the own variable and an int of the question *)
                match List.filter (fun y -> typs.(y) = Value.Tint) (List.init nv Fun.id) with
                | [] -> [ Ask.Range (x, Int (Rng.int r 30 - 10), Int (Rng.int r 30)) ]
                | l -> let y = List.nth l (Rng.int r (List.length l)) in [ (if Rng.bool r then less x y else less y x) ])
              | Value.Tint -> [ Ask.Range (x, Int (Rng.int r 30 - 10), Int (Rng.int r 30)) ]
              | Tfloat -> let _, lo, hi = float_range x in [ Ask.Range (x, lo, hi) ]
              | Ttext -> if Rng.bool r then [ Ask.In (x, List.init (1 + Rng.int r 3) (fun _ -> Value.Text names.(Rng.int r 6))) ] else [ Ask.Prefix (x, prefixes.(Rng.int r (Array.length prefixes))) ]
              | _ -> []
            in
            let items = ref [] in
            for _ = 1 to 1 + Rng.int r 2 do
              match Rng.int r 7 with
              | 4 ->
                (* Less between two variables of the question *)
                let x, y = less_pair () in
                items := less x y :: !items
              | 5 ->
                (* Optional: a property of x0, its value a variable of its own, given *)
                let k = Rng.int r 10 in
                let y = fresh (ty_of k) in
                optionals := y :: !optionals;
                items := Ask.Optional { Query.e = Var 0; p = prop_of.(k); v = Var y } :: !items
              | 6 when Rng.bool r ->
                (* Optional of a link's thing: the owner of x0 when x0 has one, now and then a thing's id *)
                let y = fresh Value.Ttext in
                optionals := y :: !optionals;
                let e = match List.filter (fun x -> x > 0 && typs.(x) = Value.Tlink) (List.init nv Fun.id) with
                  | [] -> Query.Thing (65536 + Rng.int r (n + 2)) | l -> Query.Var (List.nth l (Rng.int r (List.length l))) in
                items := Ask.Optional { Query.e; p = name; v = Var y } :: !items
              | 6 ->
                (* Less inside Not: an own variable against one of the question *)
                let x, _ = less_pair () in
                let k = match typs.(x) with Value.Tint -> 1 | Tmoney _ -> 2 | Tdate -> 3 | Tfloat -> 4 | Ttext -> 0 | _ -> 6 in
                let own = fresh (ty_of k) in
                items := Ask.Not [ Ask.Pattern { Query.e = Var 0; p = prop_of.(k); v = Var own }; (if Rng.bool r then less own x else less x own) ] :: !items
              | 0 when Rng.bool r ->
                (* Prefix on a text variable of the question *)
                (match List.filter (fun x -> typs.(x) = Value.Ttext) (List.init nv Fun.id) with
                 | [] -> ()
                 | l -> items := Ask.Prefix (List.nth l (Rng.int r (List.length l)), prefixes.(Rng.int r (Array.length prefixes))) :: !items)
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
            let outer = Array.init !nvars (fun x -> x < nv || List.mem x !bound_by_or || List.mem x !optionals) in
            opt_vars := !optionals;
            { q with vars = !nvars }, List.rev !items, typs, outer
          end
        in
        let outs = List.filter (fun x -> outer.(x)) (List.init q.vars Fun.id) in
        (* Truncs now and then: a date of the question (an Optional's too) truncated, numbered after the variables *)
        let truncs =
          match List.filter (fun x -> typs.(x) = Value.Tdate) outs with
          | [] -> []
          | ds when Rng.int r 3 = 0 ->
            List.init (1 + Rng.int r 2) (fun i -> Ask.Trunc (q.vars + i, List.nth ds (Rng.int r (List.length ds)), units.(Rng.int r (Array.length units)), zones.(Rng.int r (Array.length zones))))
          | _ -> []
        in
        let nt = List.length truncs in
        let typs = Array.append typs (Array.make nt Value.Tdate) in
        let outs = outs @ List.init nt (fun i -> q.vars + i) in
        let src x = if x < q.vars then x else (match List.nth truncs (x - q.vars) with Ask.Trunc (_, y, _, _) -> y | _ -> x) in
        let quants = [| 0.; 0.25; 0.5; 0.9; 1.; 1. /. 3. |] in
        let sel =
          match Rng.int r 4 with
          | 0 -> Wire.Give (Array.of_list outs)
          | 1 -> let g = List.filter (fun _ -> Rng.int r 2 = 0) outs in Wire.Give (Array.of_list (if g = [] then [ 0 ] else g))
          | 2 ->
            let keys = Array.of_list (List.filter (fun _ -> Rng.int r 2 = 0) outs) in
            let outs' = List.filter (fun x -> not (List.mem (src x) !opt_vars)) outs in
            let aggs = List.filter_map (fun x -> if Rng.int r 3 = 0 && (match typs.(x) with Tint | Tmoney _ -> true | _ -> false) then Some (Wire.Sum x) else if Rng.int r 4 = 0 && (match typs.(x) with Tint | Tmoney _ | Tdate -> true | _ -> false) then Some (if Rng.bool r then Wire.Min x else Max x) else None) outs' in
            Wire.Group (keys, Array.of_list (Wire.Count :: aggs))
          | _ ->
            (* a report: the aggregates of protocol 9 beside the others *)
            let keys = Array.of_list (List.filter (fun _ -> Rng.int r 2 = 0) outs) in
            let outs' = List.filter (fun x -> not (List.mem (src x) !opt_vars)) outs in
            let pick l = List.nth l (Rng.int r (List.length l)) in
            let aggs =
              List.filter_map
                (fun x ->
                  let t = typs.(x) in
                  match Rng.int r 8 with
                  | 0 when (match t with Tint | Tmoney _ | Tdate | Tfloat -> true | _ -> false) -> Some (Wire.Avg x)
                  | 1 when (match t with Tint | Tmoney _ | Tfloat -> true | _ -> false) -> Some (if Rng.bool r then Wire.Variance (x, Rng.bool r) else Stddev (x, Rng.bool r))
                  | 2 when (match t with Tint | Tmoney _ | Tdate | Tfloat -> true | _ -> false) -> Some (Wire.Quantile (x, quants.(Rng.int r (Array.length quants)), false))
                  | 3 -> Some (Wire.Quantile (x, quants.(Rng.int r (Array.length quants)), true))
                  | 4 when (match t with Tint | Tmoney _ -> true | _ -> false) -> Some (Wire.Sum x)
                  | _ -> None)
                outs'
            in
            (* Count of the different values and Values: an Optional's variable too, its missing values left out *)
            let lists = List.filter_map (fun x -> match Rng.int r 5 with 0 -> Some (Wire.Distinct x) | 1 -> Some (Wire.Values x) | _ -> None) outs in
            let aggs = aggs @ lists in
            let aggs = if aggs = [] then [ Wire.Distinct (pick outs) ] else aggs in
            Wire.Group (keys, Array.of_list (if Rng.bool r then Wire.Count :: aggs else aggs))
        in
        let extra = extra @ truncs in
        if extra <> [] then incr with_ops;
        let rec has f = function Ask.Not l -> List.exists (has f) l | Or alts -> List.exists (List.exists (has f)) alts | i -> f i in
        if List.exists (has (function Ask.Less _ | Less_or_equal _ -> true | _ -> false)) extra then incr with_less;
        if List.exists (has (function Ask.Optional _ -> true | _ -> false)) extra then incr with_optional;
        if List.exists (fun (_, lo, _) -> match lo with Value.Float _ -> true | _ -> false) q.ranges
           || List.exists (has (function Ask.Range (_, Float _, _) -> true | _ -> false)) extra then incr with_floats;
        let bs = if extra = [] then bindings fl q else bindings_ask fl q extra outer in
        (* the Truncs' columns after the variables *)
        let bs =
          if truncs = [] then bs
          else List.map (fun b -> Array.append b (Array.of_list (List.map (function Ask.Trunc (_, x, u, z) -> trunc_oracle u z b.(x) | _ -> assert false) truncs))) bs
        in
        if truncs <> [] then incr with_trunc;
        (match sel with Group (_, aggs) when Array.exists (function Wire.Count | Sum _ | Min _ | Max _ -> false | _ -> true) aggs -> incr with_report | _ -> ());
        if (match groups_of typs bs sel with _ -> false | exception Sum_past -> true) then begin
          (* a group's Sum past 63 bits: every path refuses the question, naming it, whatever its order, its page and
             its domains *)
          incr sum_refusals;
          let cols = match sel with Group (k, a) -> Array.length k + Array.length a | Give g -> Array.length g | Over _ -> 1 in
          let o = if Rng.bool r then Top.none else { Top.keys = [ { col = Rng.int r cols; desc = Rng.bool r } ]; limit = Rng.int r 3; after = None } in
          let refused name f =
            match f () with
            | got -> C.fail "seed %d: %s: a sum past 63 bits given: %s" seed name (show got)
            | exception Query.Bad m -> C.check (starts m "Sum of ") "seed %d: %s: refused, but %s" seed name m
          in
          List.iter (fun (p, name) -> Top.path := p; refused name (fun () -> engine ~extra v q sel o)) [ (Top.Heap, "heap"); (Top.Index, "index"); (Top.Auto, "auto") ];
          let d0 = !Query.domains and pm0 = !Query.parallel_min and pr0 = !Query.probe_min and pq0 = !Query.probe_more in
          Query.domains := 3;
          Query.parallel_min := 1;
          Query.probe_min := 1;
          Query.probe_more := 1;
          Fun.protect ~finally:(fun () -> Query.domains := d0; Query.parallel_min := pm0; Query.probe_min := pr0; Query.probe_more := pq0)
            (fun () -> refused "split" (fun () -> engine ~extra v q sel o));
          let q', extra', sel', o' = wired q extra sel o in
          refused "wired" (fun () -> engine ~extra:extra' v q' sel' o');
          (* and a window over it (a report without Values) *)
          let lists = match sel with Group (_, aggs) -> Array.exists (function Wire.Values _ -> true | _ -> false) aggs | _ -> false in
          if o.keys <> [] && not lists then refused "windows" (fun () -> engine ~extra v q (Wire.Over (sel, [||], [| Wire.Running (Count, 0) |])) o)
        end
        else begin
        let ctyp, groups = groups_of typs bs sel in
        let rows = List.concat_map flatten groups in
        let has_values = match sel with Group (_, aggs) -> Array.exists (function Wire.Values _ -> true | _ -> false) aggs | Give _ -> false in
        let cols = Array.length ctyp in
        if rows = [] then incr empties;
        if List.exists (Array.exists Value.is_missing) rows then incr with_missing;
        let o =
          (* a Values column is a list: no key of Sort *)
          let listed c = match sel with Group (k, aggs) when c >= Array.length k -> (match aggs.(c - Array.length k) with Wire.Values _ -> true | _ -> false) | _ -> false in
          let keys = List.filter_map (fun c -> if Rng.int r 2 = 0 && not (listed c) then Some { Top.col = c; desc = Rng.bool r } else None) (List.init cols Fun.id) in
          let keys = List.sort_uniq (fun (a : Top.key) b -> compare a.col b.col) keys in
          let keys = if keys <> [] && Rng.bool r then List.rev keys else keys in
          (* Limit alone takes the first groups in the engine's order: of a report with Values, its rows are not known *)
          let limit = if Rng.int r 4 = 0 || (keys = [] && has_values) then 0 else 1 + Rng.int r 7 in
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
            (* each row one of the answer's, as many times at most (a cell the oracle computed in floats within its
               rounding: close) *)
            let pool = ref rows in
            let rec take r acc = function [] -> None | x :: tl -> if same [ r ] [ x ] then Some (List.rev_append acc tl) else take r (x :: acc) tl in
            List.iter (fun r -> match take r [] !pool with
                | Some rest -> pool := rest
                | None -> C.fail "seed %d: %s: a row that is not the answer's: %s" seed what (show [ r ])) got
          end
          else begin
            let want = oracle cols groups o in
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
        (* the same question by Cepheus.ask, its rows as values; without an order, on one domain and split across 3 at
           every level: the same rows in the same order *)
        (match sel with
         | Wire.Give give ->
           let question =
             { Question.vars = q.vars; items = List.map (fun pt -> Ask.Pattern pt) q.where @ List.map (fun (x, lo, hi) -> Ask.Range (x, lo, hi)) q.ranges @ extra;
               give; sort = o.keys; limit = o.limit; after = o.after }
           in
           let asked d =
             let d0 = !Query.domains and pm0 = !Query.parallel_min and pr0 = !Query.probe_min and pq0 = !Query.probe_more in
             Query.domains := d;
             if d > 1 then (Query.parallel_min := 1; Query.probe_min := 1; Query.probe_more := 1);
             Fun.protect ~finally:(fun () -> Query.domains := d0; Query.parallel_min := pm0; Query.probe_min := pr0; Query.probe_more := pq0) (fun () -> ask v question)
           in
           (match asked 1 with
            | Error e -> C.fail "seed %d: ask refused: %s" seed (message e)
            | Ok one ->
              incr ask_checks;
              check "ask" one;
              if o = Top.none then
                match asked 3 with
                | Ok got -> C.check (List.length got = List.length one && List.for_all2 (fun a b -> Array.length a = Array.length b && Array.for_all2 Value.equal a b) got one) "seed %d: ask on 3 domains: other rows or another order" seed
                | Error e -> C.fail "seed %d: ask on 3 domains refused: %s" seed (message e))
         | _ -> ());
        (* split across 3 domains: at every level of two candidates or more, or with the first level of two or more
           probed (run here until its candidates' work is seen) and the levels of 12 or 64 or more split: the same rows
           in the same order as on one domain, bit for bit *)
        Top.path := Auto;
        let on d pm pr =
          let d0 = !Query.domains and pm0 = !Query.parallel_min and pr0 = !Query.probe_min and pq0 = !Query.probe_more in
          let om0 = !Agg.own_min and of0 = !Agg.own_from in
          Query.domains := d;
          Query.parallel_min := pm;
          Query.probe_min := pr;
          Query.probe_more := 1;
          (* split, a report's bags move to a table a group at once *)
          if d > 1 then (Agg.own_min := 0; Agg.own_from := 1);
          Fun.protect
            ~finally:(fun () -> Query.domains := d0; Query.parallel_min := pm0; Query.probe_min := pr0; Query.probe_more := pq0; Agg.own_min := om0; Agg.own_from := of0)
            (fun () -> engine ~extra v q sel o)
        in
        (match on 1 !Query.parallel_min 1 with
         | exception Query.Bad m -> C.fail "seed %d: one domain refused: %s" seed m
         | one ->
           List.iter
             (fun (pm, pr) ->
               match on 3 pm pr with
               | got ->
                 incr split_checks;
                 if List.length got = List.length one && List.for_all2 (fun a b -> Array.length a = Array.length b && Array.for_all2 Value.equal a b) got one then
                   C.check true ""
                 else C.fail "seed %d: split (parallel_min %d): not the rows of one domain\n  got:  %s\n  want: %s" seed pm (show got) (show one)
               | exception Query.Bad m -> C.fail "seed %d: split (parallel_min %d) refused: %s" seed pm m)
             [ (1, 1); (12, 1); (64, 1) ]);
        let q', extra', sel', o' = wired q extra sel o in
        Top.path := Auto;
        (match engine ~extra:extra' v q' sel' o' with got -> check "wired" got | exception Query.Bad m -> C.fail "seed %d: wired refused: %s" seed m);
        (* the same rows with windows and Each (protocol 10), a question in two that has Sort and no Values *)
        if o.keys <> [] && (not has_values) && Rng.bool r then begin
          let nkeys = match sel with Group (k, _) -> Array.length k | _ -> cols in
          let each, windows = random_windows r ctyp ~nkeys ~sorts:(List.length o.keys) in
          (* with Each: no After, and a Limit when there is no window *)
          let o = if each = [||] then o else { o with after = None; limit = (if windows = [||] && o.limit = 0 then 1 + Rng.int r 3 else o.limit) } in
          if each <> [||] || windows <> [||] then begin
            incr with_windows;
            if each <> [||] then incr with_each;
            let osel = Wire.Over (sel, each, windows) in
            let ord = ordered cols o in
            let sorted = List.stable_sort (fun a b -> cmp_row ord a b) (List.map plain groups) in
            let want =
              match window_oracle ctyp ord each windows sorted with
              | out, approx ->
                let sorted = Array.of_list sorted in
                let n = Array.length sorted in
                let key i = String.concat "" (Array.to_list (Array.map (fun c -> bits sorted.(i).(c)) each)) in
                let after i = match o.after with None -> true | Some a -> cmp_row ord sorted.(i) a > 0 in
                let cnt = Hashtbl.create 8 and last = Hashtbl.create 8 in
                let keep =
                  List.filter
                    (fun i ->
                      after i
                      &&
                      let k = key i in
                      let c = Option.value (Hashtbl.find_opt cnt k) ~default:0 in
                      if o.limit = 0 || c < o.limit then (Hashtbl.replace cnt k (c + 1); Hashtbl.replace last k i; true)
                      else cmp_row ord sorted.(Hashtbl.find last k) sorted.(i) = 0)
                    (List.init n Fun.id)
                in
                if List.exists (fun i -> Array.exists (fun w -> w.(i) = None) out) keep then None
                else Some (List.map (fun i -> Array.append sorted.(i) (Array.map (fun w -> Option.get w.(i)) out)) keep, approx)
            in
            let ap j = j >= cols && match want with Some (_, a) -> a.(j - cols) | None -> false in
            let same_w a b = List.length a = List.length b && List.for_all2 (fun x y -> Array.length x = Array.length y && Array.for_all Fun.id (Array.mapi (fun j c -> if ap j then close c y.(j) else Value.equal c y.(j)) x)) a b in
            let checkw name got =
              match want, got with
              | Some (w, _), Ok g -> window_cells := !window_cells + List.fold_left (fun s r -> s + Array.length r - cols) 0 g;
                if same_w g w then C.check true "" else C.fail "seed %d: %s windows %s\n  got:  %s\n  want: %s" seed name (Timings.shape v q osel extra o) (show g) (show w)
              | None, Error m when String.length m >= 13 && String.sub m 0 13 = "Running's Sum" -> incr window_refusals; C.check true ""
              | None, Ok g -> C.fail "seed %d: %s windows: a sum past 63 bits given: %s" seed name (show g)
              | _, Error m -> C.fail "seed %d: %s windows refused: %s" seed name m
            in
            let eng () = match engine ~extra v q osel o with g -> Ok g | exception Query.Bad m -> Error m in
            List.iter (fun (p, name) -> Top.path := p; checkw name (eng ())) [ (Top.Heap, "heap"); (Top.Index, "index"); (Top.Auto, "auto") ];
            Top.path := Auto;
            (* split across 3 domains at every level (Each's buffers of a group merged from each domain's) *)
            let d0 = !Query.domains and pm0 = !Query.parallel_min and pr0 = !Query.probe_min and pq0 = !Query.probe_more in
            Query.domains := 3;
            Query.parallel_min := 1;
            Query.probe_min := 1;
            Query.probe_more := 1;
            Fun.protect ~finally:(fun () -> Query.domains := d0; Query.parallel_min := pm0; Query.probe_min := pr0; Query.probe_more := pq0)
              (fun () -> checkw "split" (eng ()));
            let q', extra', sel', o' = wired q extra osel o in
            checkw "wired" (match engine ~extra:extra' v q' sel' o' with g -> Ok g | exception Query.Bad m -> Error m)
          end
        end
        end
      done)
    views

(* ---- a sorted page reads about the rows it gives ----
   A wide question (7 patterns of a thing, 8 variables, one of them a status of 3 values) sorted by an int, and a question sorted by
   a text, first page, page after a row, and the largest first; the wide question and the things of one status sorted
   by the thing: the same rows as the heap path, from the delta and from runs, and a work (Query.work, the candidates
   enumerated) of a few windows, not the whole answer's. *)
let pages () =
  let db = fork empty in
  let[@warning "-8"] (Ok (num :: status :: name :: rest)) =
    declare db (prop ~unique:true "num" Tint :: prop "status" Ttext :: prop "name" Ttext :: List.init 4 (fun k -> prop (Printf.sprintf "f%d" k) Tint))
  in
  let n = 5000 and groups = 10 in
  let statuses = [| "paid"; "unpaid"; "late" |] in
  for g = 0 to groups - 1 do
    let ops =
      List.concat
        (List.init (n / groups) (fun j ->
             let k = (g * (n / groups)) + j and t = -1 - j in
             [ Resolve.Add (t, num, Int k); Add (t, status, Text statuses.(k mod 3)); Add (t, name, Text (Printf.sprintf "name %03d" (k * 7 mod 500))) ]
             @ List.mapi (fun i p -> Resolve.Add (t, p, Int (k * (i + 2) mod 97))) rest))
    in
    match write db ops with Ok _ -> () | Error e -> C.fail "pages: a write failed: %s" (message e)
  done;
  let mdisk = Sim_disk.disk (Sim_disk.create (Rng.make 7)) in
  mdisk.mkdir "/merge";
  let v0 = view db in
  let w = Snapshot.merge mdisk "/merge" "0123456789abcdef" v0 ~take:0 ~level:1 { Journal.segment = 1; offset = 40; next = v0.group + 1 } in
  Snapshot.install mdisk "/merge" w;
  let pat p x = { Query.e = Var 0; p; v = Var x } in
  let wide = { Query.vars = 8; where = List.mapi (fun i p -> pat p (i + 1)) (num :: status :: name :: rest); ranges = [] } in
  let named = { Query.vars = 3; where = [ pat name 1; pat num 2 ]; ranges = [] } in
  (* a list of the things of a value by their ids, as a tenant's things *)
  let unpaid = { Query.vars = 2; where = [ { Query.e = Var 0; p = status; v = Val (Text "unpaid") }; pat num 1 ]; ranges = [] } in
  (* and the things past the middle one (a range on the thing), by the thing *)
  let mid = (Schema.first_thing + Store.max_thing v0) / 2 in
  let past = { named with ranges = [ (0, Value.Link mid, Value.Link max_int) ] } in
  List.iter
    (fun (where, (v : Store.view)) ->
      List.iter
        (fun (what, q, key, desc, most) ->
          let sel = Wire.Give (Array.init q.Query.vars Fun.id) in
          let first = { Top.keys = [ { Top.col = key; desc } ]; limit = 21; after = None } in
          Top.path := Top.Heap;
          let want = engine v q sel first in
          Top.path := Top.Auto;
          let before = Atomic.get Query.work in
          let got = engine v q sel first in
          let work = Atomic.get Query.work - before in
          C.check (same got want) "pages, %s, %s: the rows of the heap path" where what;
          C.check (work <= most) "pages, %s, %s: %d candidates, at most %d" where what work most;
          (* the page after its last row *)
          let next = { first with after = Some (List.nth got 20) } in
          Top.path := Top.Heap;
          let want = engine v q sel next in
          Top.path := Top.Auto;
          let before = Atomic.get Query.work in
          let got = engine v q sel next in
          let work = Atomic.get Query.work - before in
          C.check (same got want && List.length got = 21) "pages, %s, %s, next page: the rows of the heap path" where what;
          C.check (work <= most) "pages, %s, %s, next page: %d candidates, at most %d" where what work most)
        [ "7 patterns by an int", wide, 1, true, 3_000; "7 patterns by an int ascending", wide, 1, false, 3_000;
          "by a text", named, 1, false, 1_000; "by a text, the largest first", named, 1, true, 1_000;
          "7 patterns by the thing", wide, 0, false, 200; "7 patterns by the thing, the largest first", wide, 0, true, 200;
          "the unpaid by the thing", unpaid, 0, false, 50; "the unpaid by the thing, the largest first", unpaid, 0, true, 50;
          "past a thing by the thing", past, 0, false, 70; "past a thing by the thing, the largest first", past, 0, true, 70 ])
    [ "delta", v0; "a run", w.view ]

(* ---- the planner against main's former one (every order for up to 7 variables, greedily beyond), its code as it was ---- *)

open struct
  open Query
  let old_order ?(sets = []) (v : Store.view) nvars pats ranges =
  let iv = intervals nvars ranges in
  let set_len = Array.make nvars max_int in
  List.iter (fun (x, a) -> set_len.(x) <- min set_len.(x) (Array.length a)) sets;
  let est x bound =
    let known = function W _ -> true | V y -> bound land (1 lsl y) <> 0 in
    List.fold_left
      (fun best pt ->
        let c =
          if has x pt.pe && has x pt.pv then Store.count_prop v pt.pp
          else if has x pt.pe then
            match pt.pv with
            | W w -> Store.count_things v pt.pp w
            | V y when known (V y) -> max 1 (Store.count_prop v pt.pp / Store.distinct v pt.pp)
            | V _ -> Store.count_prop v pt.pp
          else if has x pt.pv then
            if known pt.pe then (match pt.pe with W e -> Store.count_values v e pt.pp | V _ -> if pt.many then 4 else 1)
            else
              match iv.(x) with
              | None -> Store.distinct v pt.pp
              | Some (lo, hi) ->
                let all = max 1 (Store.count_prop v pt.pp) in
                max 1 (Store.count_range v pt.pp lo hi * Store.distinct v pt.pp / all)
          else max_int
        in
        min best c)
      set_len.(x) pats
  in
  let best = ref [||] and best_cost = ref infinity in
  if nvars <= 7 then begin
    let cur = Array.make nvars 0 in
    let rec go k bound size cost =
      if cost < !best_cost then
        if k = nvars then (best_cost := cost; best := Array.copy cur)
        else
          for x = 0 to nvars - 1 do
            if bound land (1 lsl x) = 0 then begin
              let size = size *. float_of_int (max 1 (est x bound)) in
              cur.(k) <- x;
              go (k + 1) (bound lor (1 lsl x)) size (cost +. size)
            end
          done
    in
    go 0 0 1. 0.
  end;
  if !best = [||] then begin
    let out = Array.make nvars 0 and bound = ref 0 and size = ref 1. and cost = ref 0. in
    for k = 0 to nvars - 1 do
      let b = ref (-1) and bc = ref max_int in
      for x = 0 to nvars - 1 do
        if !bound land (1 lsl x) = 0 then begin
          let c = est x !bound in
          if !b < 0 || c < !bc then (b := x; bc := c)
        end
      done;
      out.(k) <- !b;
      bound := !bound lor (1 lsl !b);
      size := !size *. float_of_int (max 1 !bc);
      cost := !cost +. !size
    done;
    best := out;
    best_cost := !cost
  end;
  !best, !best_cost
end

(* Random questions of 2 to 16 variables over a graph of things (chains, stars, cycles, links of one and many values,
   fields, constants, ranges), answered with each planner: the same rows (as a multiset without Sort, the same rows in
   the same order with Sort and Limit). The work of each, summed, is printed. Then the bounds of the search: questions
   of 63 variables, of 12 variables all linked, and of 5,000 patterns are planned in bounded time. *)

(* ---- windows over larger groups: frames up to 40 rows, Min and Max over a sliding frame, exact sums of extreme
   ints, floats and money, Each with 1 to 60 groups, pages after a cursor; the base rows from the engine (checked
   above), each window by brute force ---- *)
let windows_big seeds =
  let db = fork empty in
  let[@warning "-8"] (Ok [ client; amount; price; ratio; day ]) =
    declare db [ prop "client" Tint; prop "amount" Tint; prop "price" (Tmoney 2); prop "ratio" Tfloat; prop "day" Tdate ]
  in
  let r = Rng.make 7 in
  let n = 700 in
  let ops =
    List.concat
      (List.init n (fun k ->
           let t = -1 - k in
           [ Resolve.Add (t, client, Int (Rng.int r 60)); Add (t, amount, Int (match Rng.int r 30 with 0 -> max_int / 3 | 1 -> min_int / 3 | _ -> Rng.int r 2000 - 1000));
             Add (t, day, Date (1_700_000_000_000 + (86_400_000 * Rng.int r 400))) ]
           @ (if Rng.int r 5 > 0 then [ Resolve.Add (t, price, Money (Rng.int r 100_000 - 20_000)) ] else [])
           (* a nan or an infinity as it is: infinity times 0 is the processor's own nan, a payload the oracle's
              totalOrder does not tell apart *)
           @ (if Rng.int r 4 > 0 then [ Resolve.Add (t, ratio, Float (let f = floats.(Rng.int r (Array.length floats)) in if Float.is_finite f then f *. float_of_int (Rng.int r 7) else f)) ] else [])))
  in
  (match write db ops with Ok _ -> () | Error e -> C.fail "windows: a write failed: %s" (message e));
  let v = view db in
  let q = { Query.vars = 6; where = [ { e = Var 0; p = client; v = Var 1 }; { e = Var 0; p = amount; v = Var 2 }; { e = Var 0; p = day; v = Var 3 } ]; ranges = [] } in
  let extra = [ Ask.Optional { e = Var 0; p = price; v = Var 4 }; Ask.Optional { e = Var 0; p = ratio; v = Var 5 } ] in
  for seed = 1 to seeds do
    let r = Rng.make (5000 + seed) in
    (* a Give of the thing, its client, amount, day, price and ratio; or a report by client (and month) *)
    let report = Rng.int r 3 = 0 in
    let sel, ctyp =
      if report then
        let month = Rng.bool r in
        (if month then Wire.Group ([| 1; 6 |], [| Wire.Count; Sum 2; Max 3 |]) else Wire.Group ([| 1 |], [| Wire.Count; Sum 2; Min 3 |])),
        if month then [| Value.Tint; Tdate; Tint; Tint; Tdate |] else [| Value.Tint; Tint; Tint; Tdate |]
      else Wire.Give [| 0; 1; 2; 3; 4; 5 |], [| Value.Tlink; Tint; Tint; Tdate; Tmoney 2; Tfloat |]
    in
    let extra = if report then extra @ (match sel with Wire.Group (k, _) when Array.length k = 2 -> [ Ask.Trunc (6, 3, "month", "Europe/Paris") ] | _ -> []) else extra in
    let cols = Array.length ctyp in
    let nkeys = match sel with Wire.Group (k, _) -> Array.length k | _ -> cols in
    let keys = List.sort_uniq (fun (a : Top.key) b -> compare a.col b.col) (List.init (1 + Rng.int r 2) (fun _ -> { Top.col = Rng.int r cols; desc = Rng.bool r })) in
    let pick l = List.nth l (Rng.int r (List.length l)) in
    let of_t f = List.filter (fun c -> f ctyp.(c)) (List.init cols Fun.id) in
    let last () = if Rng.int r 3 = 0 then 0 else 1 + Rng.int r 40 in
    let windows =
      Array.init (1 + Rng.int r 3) (fun _ ->
          match Rng.int r 6 with
          | 0 -> Wire.Running (Sum (pick (of_t (function Value.Tint | Tmoney _ -> true | _ -> false))), last ())
          | 1 -> Wire.Running (Avg (pick (of_t (function Value.Tint | Tmoney _ | Tdate | Tfloat -> true | _ -> false))), last ())
          | 2 -> Wire.Running (Max (pick (of_t (function Value.Tint | Tmoney _ | Tdate -> true | _ -> false))), last ())
          | 3 -> Wire.Running (Min (pick (of_t (function Value.Tint | Tmoney _ | Tdate -> true | _ -> false))), last ())
          | 4 -> Wire.Rank (1 + Rng.int r (List.length keys), Rng.bool r)
          | _ -> Wire.Prev (Rng.int r cols, 1 + Rng.int r 30))
    in
    let each = if Rng.bool r then [| (if report then 0 else 1) |] else [||] in
    ignore nkeys;
    (* a client's (and month's) Sum past 63 bits: the report refused, naming it *)
    match engine ~extra v q sel { Top.keys; limit = 0; after = None } with
    | exception Query.Bad m when starts m "Sum of " -> incr sum_refusals
    | base ->
    let o =
      let limit = if Rng.bool r then 0 else 1 + Rng.int r 50 in
      let after = if each = [||] && base <> [] && Rng.bool r then Some (List.nth base (Rng.int r (List.length base))) else None in
      { Top.keys; limit; after }
    in
    let ord = ordered cols o in
    let out, approx = window_oracle ctyp ord each windows base in
    begin

      let rows = Array.of_list base in
      let key i = String.concat "" (Array.to_list (Array.map (fun c -> bits rows.(i).(c)) each)) in
      let cnt = Hashtbl.create 8 and lastk = Hashtbl.create 8 in
      let keep =
        List.filter
          (fun i ->
            (match o.after with None -> true | Some a -> cmp_row ord rows.(i) a > 0)
            &&
            let k = key i in
            let c = Option.value (Hashtbl.find_opt cnt k) ~default:0 in
            if o.limit = 0 || c < o.limit then (Hashtbl.replace cnt k (c + 1); Hashtbl.replace lastk k i; true)
            else cmp_row ord rows.(Hashtbl.find lastk k) rows.(i) = 0)
          (List.init (Array.length rows) Fun.id)
      in
      if List.exists (fun i -> Array.exists (fun w -> w.(i) = None) out) keep then
        (match engine ~extra v q (Wire.Over (sel, each, windows)) o with _ -> C.fail "windows %d: a sum past 63 bits given" seed | exception Query.Bad _ -> incr window_refusals)
      else
      let want = List.map (fun i -> Array.append rows.(i) (Array.map (fun w -> Option.get w.(i)) out)) keep in
      List.iter
        (fun (p, name) ->
          Top.path := p;
          match engine ~extra v q (Wire.Over (sel, each, windows)) o with
          | got ->
            incr with_windows;
            window_cells := !window_cells + (List.length got * Array.length windows);
            let ok =
              List.length got = List.length want
              && List.for_all2 (fun a b -> Array.for_all Fun.id (Array.mapi (fun j x -> if j >= cols && approx.(j - cols) then close x b.(j) else Value.equal x b.(j)) a)) got want
            in
            if ok then C.check true ""
            else begin
              let rec first i = function
                | a :: ta, b :: tb -> if Array.length a = Array.length b && Array.for_all2 (fun x y -> Value.equal x y) a b then first (i + 1) (ta, tb) else Printf.sprintf "row %d:\n  got:  %s\n  want: %s" i (show [ a ]) (show [ b ])
                | _ -> Printf.sprintf "lengths %d %d" (List.length got) (List.length want)
              in
              C.fail "windows %d %s: %s\n  %s\n  after: %s\n  windows: %s" seed name (Timings.shape v q (Wire.Over (sel, each, windows)) extra o) (first 0 (got, want))
                (match o.after with Some a -> show [ a ] | None -> "-")
                (String.concat "; " (Array.to_list (Array.map (function Wire.Running (a, l) -> Printf.sprintf "%s %s last %d" (Agg.name a) (match Agg.var_of a with Some c -> string_of_int c | None -> "") l | Rank (k, d) -> Printf.sprintf "rank %d %b" k d | Prev (c, b) -> Printf.sprintf "prev %d %d" c b) windows)))
            end
          | exception Query.Bad m -> C.fail "windows %d %s refused: %s" seed name m)
        [ (Top.Heap, "heap"); (Top.Auto, "auto") ];
      Top.path := Auto
    end
  done

let planners_work = ref (0, 0) and planners_checks = ref 0

let planners seeds =
  let db = fork empty in
  let[@warning "-8"] (Ok [ name; score; owner; friend; kind ]) =
    declare db [ prop "name" Ttext; prop "score" Tint; prop "owner" Tlink; prop ~many:true "friend" Tlink; prop "kind" Ttext ]
  in
  let n = 600 in
  let r = Rng.make 11 in
  let ops =
    List.concat
      (List.init n (fun k ->
           let t = -1 - k in
           let link () = -1 - Rng.int r n in
           [ Resolve.Add (t, name, Text (Printf.sprintf "n%d" (Rng.int r 50))); Add (t, score, Int (Rng.int r 100));
             Add (t, kind, Text (Printf.sprintf "k%d" (Rng.int r 3))) ]
           @ (if Rng.int r 4 > 0 then [ Resolve.Add (t, owner, Link (link ())) ] else [])
           @ List.init (Rng.int r 4) (fun _ -> Resolve.Add (t, friend, Link (link ())))))
  in
  (match write db ops with Ok _ -> () | Error e -> C.fail "planners: a write failed: %s" (message e));
  let v = view db in
  let things = Array.of_list (List.sort_uniq compare (List.map (fun (e, _, _) -> e) (C.F.elements (C.facts_of_view v)))) in
  let key row = let b = Buffer.create 16 in Array.iter (Value.encode b) row; Buffer.contents b in
  let multiset rows = List.sort compare (List.map key rows) in
  let ask_both q sel o =
    let w0 = Atomic.get Query.work in
    let got = engine v q sel o in
    let w1 = Atomic.get Query.work in
    let keep = !Query.planner in
    Query.planner := (fun ~sets ~less:_ v nvars pats ranges -> old_order ~sets v nvars pats ranges);
    let want = Fun.protect ~finally:(fun () -> Query.planner := keep) (fun () -> engine v q sel o) in
    let w2 = Atomic.get Query.work in
    let a, b = !planners_work in
    planners_work := (a + w1 - w0, b + w2 - w1);
    got, want
  in
  for seed = 1 to seeds do
    let r = Rng.make (1000 + seed) in
    let nv = 2 + Rng.int r 15 in
    (* each variable after the first is linked to one before it (a tree), sometimes to another too (a cycle), or is
       a field of one before it *)
    let where = ref [] and links = ref [ 0 ] in
    for x = 1 to nv - 1 do
      let y = List.nth !links (Rng.int r (List.length !links)) in
      (match Rng.int r 5 with
       | 0 -> where := { Query.e = Var y; p = owner; v = Var x } :: !where; links := x :: !links
       | 1 -> where := { Query.e = Var x; p = friend; v = Var y } :: !where; links := x :: !links
       | 2 -> where := { Query.e = Var y; p = score; v = Var x } :: !where
       | 3 -> where := { Query.e = Var y; p = kind; v = Var x } :: !where
       | _ -> where := { Query.e = Var y; p = name; v = Var x } :: !where);
      if Rng.int r 6 = 0 && List.mem x !links then begin
        let z = List.nth !links (Rng.int r (List.length !links)) in
        if z <> x then where := { Query.e = Var x; p = friend; v = Var z } :: !where
      end
    done;
    (* a constant now and then: a thing, or a kind *)
    let where =
      List.map
        (fun (pt : Query.pattern) ->
          if pt.p = kind && Rng.int r 3 = 0 then { pt with v = Val (Text "k1") }
          else if pt.p = owner && Rng.int r 8 = 0 then { pt with e = Thing things.(Rng.int r (Array.length things)) }
          else pt)
        !where
    in
    (* the variables still in a pattern, numbered densely *)
    let used = Array.make nv false in
    List.iter (fun (pt : Query.pattern) -> (match pt.e with Var x -> used.(x) <- true | _ -> ()); match pt.v with Var x -> used.(x) <- true | _ -> ()) where;
    let map = Array.make nv (-1) and k = ref 0 in
    Array.iteri (fun i u -> if u then (map.(i) <- !k; incr k)) used;
    let ren = function Query.Var x -> Query.Var map.(x) | t -> t in
    let where = List.map (fun (pt : Query.pattern) -> { pt with Query.e = ren pt.e; v = ren pt.v }) where in
    let nv = !k in
    if nv > 0 then begin
      let ints = List.filter_map (fun (pt : Query.pattern) -> match pt.v with Var x when pt.p = score -> Some x | _ -> None) where in
      let ranges = if ints <> [] && Rng.bool r then (let a = Rng.int r 100 in [ (List.hd ints, Value.Int a, Value.Int (a + Rng.int r 30)) ]) else [] in
      let q = { Query.vars = nv; where; ranges } in
      let sel = Wire.Give (Array.init nv Fun.id) in
      (* as a multiset; then sorted by a column, a page *)
      let got, want = ask_both q sel Top.none in
      incr planners_checks;
      C.check (multiset got = multiset want) "planners, seed %d: %d rows against %d of the former planner" seed (List.length got) (List.length want);
      let o = { Top.keys = [ { Top.col = Rng.int r nv; desc = Rng.bool r } ]; limit = 1 + Rng.int r 30; after = None } in
      let got, want = ask_both q sel o in
      incr planners_checks;
      if not (same got want) then C.fail "planners, seed %d, sorted:\n  got:  %s\n  want: %s" seed (show got) (show want)
    end
  done;
  (* the bounds of the search: plans of wide questions take bounded time, whatever the patterns *)
  let timed what q most =
    let t0 = Unix.gettimeofday () in
    let p = Query.plan v q in
    let ms = (Unix.gettimeofday () -. t0) *. 1e3 in
    C.check (p <> None && ms < most) "planners: %s planned in %.1f ms (at most %.0f)" what ms most;
    match p with
    | Some p -> C.check (List.sort compare (Array.to_list p.ord) = List.init q.vars Fun.id) "planners: %s: an order of every variable" what
    | None -> ()
  in
  let chain k = { Query.vars = k; where = List.init (k - 1) (fun x -> { Query.e = Var x; p = friend; v = Var (x + 1) }); ranges = [] } in
  timed "a chain of 63 variables" (chain 63) 50.;
  let all k = { Query.vars = k; where = List.concat (List.init k (fun x -> List.init k (fun y -> { Query.e = Var x; p = friend; v = Var y }))); ranges = [] } in
  timed "12 variables, each linked to all" (all 12) 50.;
  timed "13 variables, each linked to all" (all 13) 50.;
  let many = { Query.vars = 12; where = List.concat (List.init 420 (fun _ -> (all 12).where)) |> List.filteri (fun i _ -> i < 5000); ranges = [] } in
  timed "12 variables in 5,000 patterns" many 100.;
  timed "a chain of 64 variables, as many as the wire takes" (chain 64) 50.;
  (* more variables and patterns than an int has bits, answered: 64 variables, the last one planned first (its bit,
     1 lsl 63, is 0) and placed once; and a variable of 70 patterns, 62 of them intersected by the leapfrog, whose
     patterns 62 to 69 must each be checked, not taken for intersected ones *)
  let db = fork empty in
  let[@warning "-8"] (Ok [ next; mark ]) = declare db [ prop ~many:true "next" Tlink; prop ~many:true "mark" Ttext ] in
  let tag j = Value.Text (Printf.sprintf "t%d" j) in
  let ops =
    [ Resolve.Add (-1, next, Link (-2)); Add (-2, next, Link (-3)); Add (-3, next, Link (-1)); Add (-1, mark, Text "start") ]
    (* thing -10 holds t0 to t69; -11 to -14 t0 to t68: pattern 69 alone tells them apart; -20 to -59 t64 to t69 *)
    @ List.init 70 (fun j -> Resolve.Add (-10, mark, tag j))
    @ List.concat (List.init 4 (fun i -> List.init 69 (fun j -> Resolve.Add (-11 - i, mark, tag j))))
    @ List.concat (List.init 40 (fun i -> List.init 6 (fun j -> Resolve.Add (-20 - i, mark, tag (64 + j)))))
  in
  (match write db ops with Ok _ -> () | Error e -> C.fail "planners: a write failed: %s" (message e));
  let v = view db in
  let one q = engine v q (Wire.Give (Array.init q.Query.vars Fun.id)) Top.none in
  let start = one { Query.vars = 1; where = [ { Query.e = Var 0; p = mark; v = Val (Text "start") } ]; ranges = [] } in
  let cyc =
    { Query.vars = 64;
      where = { Query.e = Var 63; p = mark; v = Val (Text "start") } :: List.init 63 (fun x -> { Query.e = Var x; p = next; v = Var (x + 1) });
      ranges = [] }
  in
  (match start, one cyc with
   | [ [| a |] ], [ r ] ->
     let walk = List.for_all (fun x -> Value.equal r.(x) r.(x + 3)) (List.init 61 Fun.id) in
     let three = not (Value.equal r.(61) r.(62) || Value.equal r.(62) r.(63) || Value.equal r.(61) r.(63)) in
     C.check (Value.equal r.(63) a && walk && three) "planners: 64 variables around a cycle of 3: %s" (show [ r ])
   | _, rows -> C.check false "planners: 64 variables around a cycle of 3: %d rows, 1 expected" (List.length rows));
  let wide = { Query.vars = 1; where = List.init 70 (fun j -> { Query.e = Var 0; p = mark; v = Val (tag j) }); ranges = [] } in
  let rows = one wide in
  (* the one thing that holds t0 and t69 holds them all *)
  let only = one { Query.vars = 1; where = [ { Query.e = Var 0; p = mark; v = Val (tag 0) }; { Query.e = Var 0; p = mark; v = Val (tag 69) } ]; ranges = [] } in
  C.check (List.length only = 1 && same rows only) "planners: a variable of 70 patterns: %d rows (1 expected): %s" (List.length rows) (show rows)


(* In at its bound: 100,000 values, the ids of a page of 100,000 rows; and an In inside a Not, whose words are found
   once a question, not once a binding (10,000 texts over 5,000 bindings) *)
let ins () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ num; tag ]) = declare db [ prop "num" Tint; prop ~many:true "tag" Ttext ] in
  let n = 5000 in
  let ops = List.concat (List.init n (fun k -> [ Resolve.Add (-1 - k, num, Int k); Add (-1 - k, tag, Text (Printf.sprintf "t%d" (k mod 7))) ])) in
  (match write db ops with Ok _ -> () | Error e -> C.fail "ins: a write failed: %s" (message e));
  let v = view db in
  let q = { Query.vars = 2; where = [ { Query.e = Var 0; p = num; v = Var 1 } ]; ranges = [] } in
  let all = List.init Ask.max_in (fun k -> Value.Int (2 * k)) in
  let got = engine ~extra:[ Ask.In (1, all) ] v q (Wire.Group ([||], [| Wire.Count |])) Top.none in
  C.check (got = [ [| Value.Int 2500 |] ]) "ins: In of %d values: %s" Ask.max_in (show got);
  (* three Ors of 4 alternatives: 64 conjunctions, one In: its words are found once in the view, not 64 times *)
  let quarter = Ask.Or (List.map (fun (lo, hi) -> [ Ask.Range (1, Value.Int lo, Value.Int hi) ]) [ (0, 999); (1000, 1999); (2000, 2999); (3000, max_int) ]) in
  let a = Ask.compile v q [ Ask.In (1, all); quarter; quarter; quarter ] in
  let rows = Ask.fold v a ~init:(fun () -> 0) ~merge:( + ) ~step:(fun n _ -> n + 1) in
  let cached = match Atomic.get a.Ask.words with Some (_, k) -> List.length k | None -> 0 in
  C.check (List.length a.Ask.conjs = 64 && rows = 2500 && cached = 1) "ins: 64 conjunctions with one In: %d conjunctions, %d rows, %d sets of words" (List.length a.Ask.conjs) rows cached;
  let texts = List.init 10_000 (fun k -> Value.Text (Printf.sprintf "t%d" (k + 3))) in
  let t0 = Unix.gettimeofday () in
  let got = engine ~extra:[ Ask.Not [ Ask.Pattern { Query.e = Var 0; p = tag; v = Var 2 }; Ask.In (2, texts) ] ] v { q with vars = 3 }
      (Wire.Group ([||], [| Wire.Count |])) Top.none in
  let ms = (Unix.gettimeofday () -. t0) *. 1e3 in
  (* t3 .. t6 are in the In: the things of t0, t1 and t2 are kept *)
  let want = List.length (List.filter (fun k -> k mod 7 < 3) (List.init n Fun.id)) in
  C.check (got = [ [| Value.Int want |] ] && ms < 1000.) "ins: a Not with an In of 10,000 values over %d bindings: %s in %.0f ms" n (show got) ms;
  (* a Not's In is read at the Not's first binding, as it always was: one of the wrong type is refused there, and a
     question that never reaches the Not answers *)
  let bad_in = [ Ask.Not [ Ask.Pattern { Query.e = Var 0; p = tag; v = Var 1 }; Ask.In (1, [ Value.Int 1 ]) ] ] in
  let count_of where = engine ~extra:bad_in v { Query.vars = 2; where; ranges = [] } (Wire.Group ([||], [| Wire.Count |])) Top.none in
  (match count_of [ { Query.e = Var 0; p = num; v = Val (Int (-7)) } ] with
   | got -> C.check (List.for_all (fun r -> r = [| Value.Int 0 |]) got) "ins: a Not's mistyped In and no binding: %s" (show got)
   | exception e -> C.check false "ins: a Not's mistyped In and no binding: %s" (Printexc.to_string e));
  match count_of [ { Query.e = Var 0; p = num; v = Val (Int 7) } ] with
  | got -> C.check false "ins: a Not's mistyped In reached: answered %s" (show got)
  | exception Query.Bad _ -> C.check true ""

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
       (fun () -> { Query.vars = 2; where = [ { e = Var 0; p = owner; v = Var 1 } ]; ranges = [] }, [ Ask.In (1, List.init 2 (fun _ -> Value.Link (pick ()))) ], Wire.Give [| 0 |]);
       (* Prefix, on a text of the question *)
       (fun () -> { Query.vars = 2; where = [ { e = Var 0; p = name; v = Var 1 } ]; ranges = [] }, [ Ask.Prefix (1, prefixes.(Rng.int r 3)) ], Wire.Give [| 0; 1 |]);
       (* a Not whose own variable has a condition, and a Prefix inside it; a chain through the Not's own thing *)
       (fun () -> { Query.vars = 4; where = [ { e = Var 0; p = name; v = Var 1 } ]; ranges = [] },
                  [ Ask.Not [ Pattern { e = Var 2; p = owner; v = Var 0 }; Pattern { e = Var 2; p = score; v = Var 3 }; Range (3, Int 20, Int 60) ] ], Wire.Give [| 0 |]);
       (fun () -> { Query.vars = 3; where = [ { e = Var 0; p = score; v = Var 1 } ]; ranges = [] },
                  [ Ask.Not [ Pattern { e = Var 0; p = name; v = Var 2 }; Prefix (2, prefixes.(Rng.int r 3)) ] ], Wire.Give [| 0; 1 |]);
       (* an Or that binds a variable of the question, with an alternative of its own variable, and a sum over it *)
       (fun () -> { Query.vars = 3; where = []; ranges = [] },
                  [ Ask.Or [ [ Pattern { e = Var 0; p = score; v = Var 1 }; Range (1, Int 0, Int 30) ];
                             [ Pattern { e = Var 0; p = score; v = Var 1 }; Pattern { e = Var 0; p = owner; v = Var 2 } ] ] ],
       Wire.Group ([||], [| Wire.Count; Wire.Sum 1 |]));
       (* Optional: a tag added takes away the row where it was missing and gives one; a tag retracted the other way *)
       (fun () -> { Query.vars = 3; where = [ { e = Var 0; p = score; v = Var 1 } ]; ranges = [] }, [ Ask.Optional { e = Var 0; p = tag; v = Var 2 } ], Wire.Give [| 0; 1; 2 |]);
       (* an Optional of the owner (a token that may not read it is denied), counted by owner *)
       (fun () -> { Query.vars = 3; where = [ { e = Var 0; p = name; v = Var 1 } ]; ranges = [] }, [ Ask.Optional { e = Var 0; p = owner; v = Var 2 } ], Wire.Group ([| 2 |], [| Wire.Count |]));
       (* Less: the things whose score is below their owner's, or at most *)
       (fun () -> { Query.vars = 4; where = [ { e = Var 0; p = score; v = Var 1 }; { e = Var 0; p = owner; v = Var 2 }; { e = Var 2; p = score; v = Var 3 } ]; ranges = [] },
                  [ (if Rng.bool r then Ask.Less (1, 3) else Ask.Less_or_equal (1, 3)) ], Wire.Give [| 0; 2 |]);
       (* Less inside a Not: no tag of x0 ... a name below another's *)
       (fun () -> { Query.vars = 3; where = [ { e = Var 0; p = name; v = Var 1 } ]; ranges = [] },
                  [ Ask.Not [ Pattern { e = Var 0; p = tag; v = Var 2 }; Less (2, 1) ] ], Wire.Give [| 0; 1 |]) |]
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
    (* a token that may read every kind but the owner's: its watch is denied when a pattern names it (inside Not and
       Or too), and otherwise its rows are the answer over the facts it may read *)
    let table = Bytes.make (Schema.count !v.schema) '\001' in
    Bytes.set table owner '\000';
    let readable = List.filter (fun (_, p, _) -> p <> owner) fl in
    List.iter
      (fun (q, extra, sel, rows) ->
        incr live_checks;
        let a = Ask.compile !v q extra in
        let typs = Ask.typs_of a in
        let denied = Core.unreadable table !v q extra <> None in
        C.check (denied = List.exists (fun (pt : Query.pattern) -> pt.p = owner) (Ask.patterns q extra)) "seed %d: live: the token's right" seed;
        let _, want = groups_of typs (bindings_ask (if denied then fl else readable) q extra a.outer) sel in
        let want = List.concat_map flatten want in
        let key r = let b = Buffer.create 16 in Array.iter (Value.encode b) r; Buffer.contents b in
        let norm l = List.sort compare (List.map key l) in
        match !rows with
        | Some got -> if norm got <> norm want then C.fail "seed %d: live, group %d: %d rows, %d expected" seed !v.group (List.length got) (List.length want) else C.check true ""
        | None -> C.fail "seed %d: live: no answer" seed)
      !watches
  done

(* ---- Less seeks, Optional, and what they refuse ----
   Less between a bound int and the values of a property reads the range of the sorted index past it, not the whole
   property (Khayyat et al. 2015): the work of the answer. Optional gives every row, the missing ones last in both
   orders, and the pages after a missing cell. The mistakes are refused with their reason. *)
(* A whole sort by the bits of its keys (Top.sort_radix) against the comparisons' sort: rows of 1 to 5 columns of every
   inline type and texts, words of a small range, the extremes of the ints, a constant column, copies of rows; keys
   ascending and descending, a text key after inline ones or first; 2 to 600 rows. The same order, row for row. *)
let radix () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ name ]) = declare db [ prop "name" Ttext ] in
  (match write db (List.mapi (fun i s -> Resolve.Add (-1 - i, name, Text s)) (Array.to_list names)) with Ok _ -> () | Error e -> C.fail "radix: %s" (message e));
  let v = view db in
  let texts = Array.of_list (List.filter_map (fun s -> Store.word v (Text s)) (Array.to_list names)) in
  let r = Rng.make 4242 in
  let types = [| Value.Tint; Tdate; Tmoney 2; Tlink; Tbool; Ttext |] in
  let keep = !Top.radix_min in
  Top.radix_min := 2;
  for t = 1 to 3000 do
    let cols = 1 + Rng.int r 5 in
    let typs = Array.init cols (fun c -> if c = 0 && Rng.int r 4 > 0 then types.(Rng.int r 5) else types.(Rng.int r 6)) in
    let law = Array.init cols (fun _ -> Rng.int r 4) in
    let word c =
      match typs.(c) with
      | Ttext -> texts.(Rng.int r (Array.length texts))
      | Tbool -> Rng.int r 2
      | _ -> (
        match law.(c) with
        | 0 -> Rng.int r 10
        | 1 -> [| min_int; max_int; 0; -1; 1; min_int + 1; max_int - 1 |].(Rng.int r 7)
        | 2 -> 7
        | _ -> Rng.int r 1_000_000_000 - 500_000_000)
    in
    let n = 2 + Rng.int r 600 in
    let base = Array.init (1 + Rng.int r n) (fun _ -> Array.init cols word) in
    let rows = Array.init n (fun _ -> Array.copy base.(Rng.int r (Array.length base))) in
    let keys = List.sort_uniq (fun (a : Top.key) b -> compare a.col b.col) (List.init (1 + Rng.int r cols) (fun _ -> { Top.col = Rng.int r cols; desc = Rng.bool r })) in
    let ord = Top.full cols (List.sort (fun _ _ -> if Rng.bool r then 1 else -1) keys) in
    let mk = Top.sorter v typs ord in
    let want = Array.copy rows in
    Array.stable_sort (mk ()) want;
    let got = { Top.a = Array.copy rows; n } in
    Top.sort_cut ~fast:(typs, ord) mk 0 got;
    C.check (got.a = want) "radix %d: %d rows of %d columns, the order differs" t n cols
  done;
  Top.radix_min := keep

let less_optional () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ num; phone; rate; nick ]) =
    declare db [ prop "num" Tint; prop ~many:true "phone" Ttext; prop "rate" Tfloat; prop "nick" Ttext ]
  in
  let n = 4000 in
  let ops =
    List.concat
      (List.init n (fun k ->
           [ Resolve.Add (-1 - k, num, Int k); Add (-1 - k, rate, Float (float_of_int k /. 100.)) ]
           @ (if k mod 3 = 0 then [ Resolve.Add (-1 - k, phone, Text (Printf.sprintf "p%d" k)) ] else [])
           @ (if k mod 300 = 0 then [ Resolve.Add (-1 - k, phone, Text (Printf.sprintf "q%d" k)) ] else [])))
  in
  (match write db ops with Ok _ -> () | Error e -> C.fail "less: a write failed: %s" (message e));
  let v = view db in
  let t0 = Store.max_thing v - n + 1 in
  (* the things whose num is above the num of the 3,990th thing: 9 of them, read from the index's range *)
  let q = { Query.vars = 3; where = [ { Query.e = Thing (t0 + 3990); p = num; v = Var 0 }; { e = Var 1; p = num; v = Var 2 } ]; ranges = [] } in
  let before = Atomic.get Query.work in
  let got = engine ~extra:[ Ask.Less (0, 2) ] v q (Wire.Give [| 2 |]) { Top.keys = [ { col = 0; desc = false } ]; limit = 0; after = None } in
  let work = Atomic.get Query.work - before in
  C.check (got = List.init 9 (fun k -> [| Value.Int (3991 + k) |]) && work < 100) "less: a seek past a bound int: %s, %d candidates" (show got) work;
  let got = engine ~extra:[ Ask.Less_or_equal (2, 0) ] v q (Wire.Group ([||], [| Wire.Count |])) Top.none in
  C.check (got = [ [| Value.Int 3991 |] ]) "less: at most a bound int: %s" (show got);
  (* floats: a range, and Less, in totalOrder *)
  let qf = { Query.vars = 2; where = [ { Query.e = Var 0; p = rate; v = Var 1 } ]; ranges = [ (1, Float 2.5, Float 3.0) ] } in
  let got = engine v qf (Wire.Group ([||], [| Wire.Count |])) Top.none in
  C.check (got = [ [| Value.Int 51 |] ]) "less: a range of a float, 2.5 to 3.0: %s" (show got);
  (match find v qf with Ok rows -> C.check (List.length rows = 51) "less: find with a range of a float: %d" (List.length rows) | Error e -> C.fail "less: find: %s" (message e));
  let qf2 = { Query.vars = 4; where = [ { Query.e = Thing (t0 + 10); p = rate; v = Var 0 }; { e = Var 1; p = rate; v = Var 2 }; { e = Var 1; p = num; v = Var 3 } ]; ranges = [ (3, Int 0, Int 20) ] } in
  let got = engine ~extra:[ Ask.Less (2, 0) ] v qf2 (Wire.Give [| 3 |]) { Top.keys = [ { col = 0; desc = false } ]; limit = 0; after = None } in
  C.check (got = List.init 10 (fun k -> [| Value.Int k |])) "less: floats below a bound float: %s" (show got);
  (* Optional: every thing, its phones or missing; missing last ascending and descending; the page after one *)
  let qo = { Query.vars = 2; where = [ { Query.e = Var 0; p = num; v = Var 1 } ]; ranges = [ (1, Int 297, Int 303) ] } in
  let opt = [ Ask.Optional { Query.e = Var 0; p = phone; v = Var 2 } ] in
  let qo = { qo with vars = 3 } in
  let page desc after = engine ~extra:opt v qo (Wire.Give [| 1; 2 |]) { Top.keys = [ { col = 1; desc } ]; limit = 3; after } in
  let m = Value.missing in
  let asc = page false None in
  C.check (asc = [ [| Int 297; Text "p297" |]; [| Int 300; Text "p300" |]; [| Int 303; Text "p303" |] ]) "optional: ascending: %s" (show asc);
  let after = page false (Some [| Int 300; Text "q300" |]) in
  C.check (after = [ [| Int 298; m |]; [| Int 299; m |]; [| Int 301; m |] ]) "optional: missing last, after the values: %s" (show after);
  let desc = page true None in
  C.check (desc = [ [| Int 300; Text "q300" |]; [| Int 303; Text "p303" |]; [| Int 300; Text "p300" |] ]) "optional: descending: %s" (show desc);
  let last = page true (Some [| Int 299; m |]) in
  C.check (last = [ [| Int 301; m |]; [| Int 302; m |] ]) "optional: the page after a missing cell, descending: %s" (show last);
  (match ask v { Question.vars = 3; items = Question.[ Pattern { e = Var 0; p = num; v = Val (Int 1) }; Optional { e = Var 0; p = phone; v = Var 2 }; Pattern { e = Var 0; p = num; v = Var 1 } ]; give = [| 1; 2 |]; sort = []; limit = 0; after = None } with
   | Ok rows -> C.check (rows = [ [| Value.Int 1; Value.missing |] ]) "optional: ask's missing cell: %s" (show rows)
   | Error e -> C.fail "optional: ask: %s" (message e));
  (* what is refused, and why *)
  let refused what q extra sel want =
    match engine ~extra v q sel Top.none with
    | _ -> C.fail "refused: %s: answered" what
    | exception Query.Bad m -> C.check (m = want) "refused: %s: %s" what m
  in
  let q2 = { Query.vars = 3; where = [ { Query.e = Var 0; p = num; v = Var 1 }; { e = Var 0; p = nick; v = Var 2 } ]; ranges = [] } in
  refused "Less of two types" q2 [ Ask.Less (1, 2) ] (Wire.Give [| 0 |]) "Less compares two variables of one type, not a int and a text";
  refused "Optional's value used" q2 [ Ask.Optional { e = Var 0; p = phone; v = Var 2 } ] (Wire.Give [| 0 |])
    "the value of Optional is a variable in no other item of the question: variable 2 is in 1";
  refused "Optional inside Not" q2 [ Ask.Not [ Ask.Optional { e = Var 0; p = phone; v = Var 2 } ] ] (Wire.Give [| 0 |])
    "Not takes patterns and conditions: no Not, Or or Optional inside it";
  refused "Optional's thing unbound" { q2 with vars = 4 } [ Ask.Optional { e = Var 3; p = phone; v = Var 2 } ] (Wire.Give [| 0 |])
    "the thing of Optional is a variable that a pattern of the question binds, or a thing's id";
  refused "a sum of an Optional's" { Query.vars = 3; where = [ { Query.e = Var 0; p = rate; v = Var 1 } ]; ranges = [] } [ Ask.Optional { e = Var 0; p = num; v = Var 2 } ] (Wire.Group ([||], [| Wire.Sum 2 |]))
    "Sum, Min and Max take a variable of a pattern, not an Optional's, which may be missing: give its values, or Count the rows";
  refused "a range of a text" q2 [ Ask.Range (2, Text "a", Text "b") ] (Wire.Give [| 0 |]) "a range needs an int, float, date or money variable"

let () =
  (* the oracle's calendar of UTC: mktime is timegm *)
  Unix.putenv "TZ" "UTC";
  let seeds = ref 300 and one = ref None in
  Arg.parse [ "--seeds", Arg.Set_int seeds, "N"; "--seed", Arg.Int (fun s -> one := Some s), "S" ] (fun _ -> ()) "questions.exe";
  (match !one with Some s -> run s; live s | None -> pages (); planners !seeds; windows_big !seeds; ins (); radix (); less_optional (); for s = 1 to !seeds do run s; if s mod 3 = 0 then live s done);
  Printf.printf "questions: %d questions (%d with an order, %d with Not, Or or In, %d empty), %d windows of the index path (%d of a sort by a thing), %d given up for the heap path\n"
    !questions !with_order !with_ops !empties (Atomic.get Top.windows) (Atomic.get Top.held) (Atomic.get Top.gave_up);
  Printf.printf "questions: %d ranges of a thing read from their first thing, %d sorts by the bits of their keys\n" (Atomic.get Query.seeks) (Atomic.get Top.radix_sorts);
  Printf.printf "questions: %d with Less, %d with Optional (%d with a missing cell), %d with a range of a float; %d asked by Cepheus.ask too\n" !with_less !with_optional !with_missing !with_floats !ask_checks;
  Printf.printf "questions: %d reports with Avg, Count(x), Values, Quantile, Variance or Stddev, %d with Trunc\n" !with_report !with_trunc;
  Printf.printf "questions: %d sums past 63 bits refused (every path); %d with windows or Each (%d with Each), %d windows' cells checked, %d running sums past 63 bits refused; %d pages after a cursor (%d read from a range of the first key)\n" !sum_refusals
    !with_windows !with_each !window_cells !window_refusals (Atomic.get Answer.paged) (Atomic.get Answer.ranged);
  Printf.printf "questions: %d answers split across 3 domains (%d levels split, %d by a probe; %d bag columns moved to a table a group), each the rows of one domain in their order\n" !split_checks (Atomic.get Query.splits) (Atomic.get Query.probed_splits) (Atomic.get Agg.owned);
  Printf.printf "questions: %d questions with each planner, the same rows; their work %d candidates, %d with the former one\n"
    !planners_checks (fst !planners_work) (snd !planners_work);
  Printf.printf "questions: %d checks of live questions with Not, Or, In and Prefix after a frame (%d frames answered by their keys, %d by the whole question)\n"
    !live_checks (Atomic.get Live.keyed) (Atomic.get Live.whole);
  C.finish "questions"
