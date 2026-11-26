(* An index of two properties (Cepheus.within, run format 10): random invoices of random clients (their client, date
   and total written, changed, retracted, deleted), a pair declared before the data or after it, undeclared and
   declared again, the delta merged at random into runs (alone on top, with the newest runs, or all: a bottom run).
   After each step, every pair the view can read is checked against the facts by brute force: each group's things in
   the order of their p2 values, from a random place on, ascending and descending (Store.pair_from), and the groups
   (Store.pair_groups). Then questions on both paths, the pair's and the plain join's, must give the same rows in the
   same order: Each with Limit k sorted by p2 (the latest invoices of each client), with filters the pair does not
   know (a total in a range, an Optional), and a page of one client's invoices sorted by p2, with After.
   [pairs.exe --seeds N], [pairs.exe --seed N] replays one. *)

open Cepheus
open Cepheus_server
module C = Check

let props =
  [ prop "inv/client" Tlink; prop "inv/date" Tdate; prop "inv/total" Tint; prop "inv/zone" Tint; prop ~many:true "inv/tag" Ttext;
    prop "cl/name" Ttext ]

(* the things of w1 for the pair p2 within p1, (w2, e) sorted, by brute force over the facts *)
let brute (fl : C.F.t) p1 p2 =
  let one = Hashtbl.create 64 and two = Hashtbl.create 64 in
  C.F.iter
    (fun (e, p, x) ->
      let w = match x with Value.Link w | Int w | Date w | Money w -> w | Bool b -> if b then 1 else 0 | _ -> 0 in
      if p = p1 then Hashtbl.replace one e w;
      if p = p2 then Hashtbl.replace two e w)
    fl;
  let g = Hashtbl.create 64 in
  Hashtbl.iter (fun e w1 -> match Hashtbl.find_opt two e with Some w2 -> Hashtbl.replace g w1 ((w2, e) :: Option.value (Hashtbl.find_opt g w1) ~default:[]) | None -> ()) one;
  Hashtbl.filter_map_inplace (fun _ l -> Some (List.sort compare l)) g;
  g

let stream_checks = ref 0
let ready_views = ref 0

let check_pairs seed (v : Store.view) r =
  let fl = C.facts_of_view v in
  Schema.iter_pairs v.schema (fun p2 p1 ->
      if Store.pair_ready v ~p1 ~p2 then begin
        incr ready_views;
        let g = brute fl p1 p2 in
        let groups = Store.pair_groups v ~p1 ~p2 min_int max_int in
        Hashtbl.iter (fun w1 _ -> C.check (Array.mem w1 groups) "seed %d: the group %d of pair %d within %d is not among the groups" seed w1 p2 p1) g;
        Array.iter
          (fun w1 ->
            let want = Option.value (Hashtbl.find_opt g w1) ~default:[] in
            List.iter
              (fun desc ->
                let from =
                  match want with
                  | [] -> if desc then max_int else min_int
                  | l when Rng.int r 3 = 0 -> fst (List.nth l (Rng.int r (List.length l))) + Rng.int r 3 - 1
                  | _ -> if desc then max_int else min_int
                in
                let expect = List.filter (fun (w2, _) -> if desc then w2 <= from else w2 >= from) want in
                let expect = if desc then List.rev expect else expect in
                let cell = ref 0 in
                let next = Store.pair_from v ~p1 ~p2 w1 ~desc ~from cell in
                let rec all acc = let e = next () in if e < 0 then List.rev acc else all ((!cell, e) :: acc) in
                let got = all [] in
                incr stream_checks;
                if got <> expect then
                  C.fail "seed %d: pair %d within %d, group %d from %d%s: got [%s], want [%s] (%d runs)" seed p2 p1 w1 from (if desc then " down" else "")
                    (String.concat "; " (List.map (fun (a, b) -> Printf.sprintf "%d,%d" a b) got))
                    (String.concat "; " (List.map (fun (a, b) -> Printf.sprintf "%d,%d" a b) expect))
                    (Array.length v.runs))
              [ false; true ])
          groups
      end)

(* ---- questions on both paths ---- *)

let question_checks = ref 0
let on_pair = ref 0

let rows_of (v : Store.view) (a : Answer.answer) = List.init a.n (fun i -> Array.init a.cols (fun j -> Answer.value v a i j))

let show rows = String.concat "\n    " (List.map (fun r -> String.concat " " (Array.to_list (Array.map Value.to_string r))) rows)

(* the same question with the pair path and without: the same rows, in the same order (or the same refusal) *)
let both seed (v : Store.view) what ?(extra = []) q sel order =
  let ask () = match Answer.answer ~order ~extra v q sel with a -> Ok (rows_of v a) | exception Query.Bad m -> Error m in
  let before = Atomic.get Answer.pair_each in
  let with_pair = ask () in
  let used = Atomic.get Answer.pair_each > before in
  if used then incr on_pair;
  Answer.use_pairs := false;
  let plain = Fun.protect ~finally:(fun () -> Answer.use_pairs := true) ask in
  incr question_checks;
  if with_pair <> plain then
    C.fail "seed %d: %s (%d runs%s): the pair's rows differ from the join's\n  pair:\n    %s\n  join:\n    %s" seed what (Array.length v.runs)
      (if used then ", on the pair" else "")
      (match with_pair with Ok r -> show r | Error m -> "refused: " ^ m)
      (match plain with Ok r -> show r | Error m -> "refused: " ^ m)

let questions seed (v : Store.view) r ~client ~date ~total ~zone ~tag ~name =
  for _ = 1 to 6 do
    let k = [| 1; 2; 3; 5; 40 |].(Rng.int r 5) and desc = Rng.bool r in
    (* i 0, d 1, t 2, c 3, then n 4 (the client's name) or x 4 (a zone) *)
    let base = [ { Query.e = Var 0; p = client; v = Var 3 }; { e = Var 0; p = date; v = Var 1 }; { e = Var 0; p = total; v = Var 2 } ] in
    let variant = Rng.int r 7 in
    let where, vars =
      match variant with
      | 1 -> base @ [ { e = Var 3; p = name; v = Var 4 } ], 5
      | 2 -> base @ [ { e = Var 0; p = zone; v = Var 4 } ], 5
      | _ -> base, 4
    in
    let ranges =
      match variant with
      | 3 -> [ (2, Value.Int 10, Value.Int 30) ]
      | 4 -> let a = 1_700_000_000_000 + (1000 * Rng.int r 40) in [ (1, Value.Date a, Value.Date (a + (1000 * Rng.int r 20))) ]
      | _ -> []
    in
    let extra =
      match variant with
      | 5 -> [ Question.Ask.Not [ Pattern { e = Var 0; p = zone; v = Val (Int (Rng.int r 4)) } ] ]
      | 6 -> [ Question.Ask.Optional { e = Var 0; p = tag; v = Var 4 } ]
      | _ -> []
    in
    let vars = if variant = 6 then 5 else vars in
    let q = { Query.vars; where; ranges } in
    let give = Array.init vars Fun.id in
    let order = { Question.Top.keys = [ { col = 1; desc } ]; limit = k; after = None } in
    let windows = if Rng.int r 4 = 0 then [| Wire.Running (Sum 2, 0) |] else [||] in
    both seed v (Printf.sprintf "Each Limit %d, variant %d%s" k variant (if desc then ", descending" else "")) ~extra q (Wire.Over (Wire.Give give, [| 3 |], windows)) order
  done

(* a page of one client's invoices sorted by date, with After: on the pair (the index path forced, so that a small
   group takes it too) and by the heap, the plain join *)
let pages seed (v : Store.view) r ~client ~date ~total =
  let fl = C.facts_of_view v in
  let cs = C.F.fold (fun (_, p, x) acc -> match x with Value.Link c when p = client -> c :: acc | _ -> acc) fl [] in
  if cs <> [] then
    for _ = 1 to 4 do
      let c0 = List.nth cs (Rng.int r (List.length cs)) in
      let q =
        { Query.vars = 3; where = [ { e = Var 0; p = client; v = Thing c0 }; { e = Var 0; p = date; v = Var 1 }; { e = Var 0; p = total; v = Var 2 } ];
          ranges = (if Rng.int r 4 = 0 then (let a = 1_700_000_000_000 + (1000 * Rng.int r 40) in [ (1, Value.Date a, Value.Date (a + (1000 * Rng.int r 20))) ]) else []) }
      in
      let desc = Rng.bool r and k = 1 + Rng.int r 6 in
      let order = { Question.Top.keys = [ { col = 1; desc } ]; limit = k; after = None } in
      let all = Answer.answer ~order:{ order with limit = 0 } v q (Wire.Give [||]) in
      let order = if all.n > 0 && Rng.bool r then { order with after = Some (Array.init all.cols (fun j -> Answer.value v all (Rng.int r all.n) j)) } else order in
      let ask path pairs =
        Question.Top.path := path;
        Question.Top.pairs := pairs;
        Fun.protect ~finally:(fun () -> Question.Top.path := Auto; Question.Top.pairs := true) (fun () -> rows_of v (Answer.answer ~order v q (Wire.Give [||])))
      in
      let a = ask Index true and b = ask Heap false in
      incr question_checks;
      if a <> b then C.fail "seed %d: a page of #%d by date%s, limit %d (%d runs): the pair's rows differ from the heap's\n  pair:\n    %s\n  heap:\n    %s" seed c0 (if desc then " down" else "") k (Array.length v.runs) (show a) (show b)
    done

let run seed =
  let r = Rng.make seed in
  let db = ref (fork empty) in
  let[@warning "-8"] (Ok [ client; date; total; zone; tag; name ]) = declare !db props in
  let declared = ref false in
  let declare_now () =
    (match within !db (if seed mod 2 = 0 then [ (date, client) ] else [ (date, client); (total, zone) ]) with
     | Ok () -> declared := true
     | Error e -> C.fail "seed %d: within: %s" seed (message e))
  in
  if seed mod 3 <> 0 then declare_now ();
  let clients = ref [||] and invoices = ref [||] in
  let rounds = 4 + Rng.int r 8 in
  for round = 1 to rounds do
    let v = view !db in
    let ops = ref [] in
    (* new clients, new invoices, changes *)
    for k = 1 to 1 + Rng.int r 4 do ops := Resolve.Add (-k, name, Text (Printf.sprintf "c%d-%d" round k)) :: !ops done;
    let nc = List.length !ops in
    let pick_client () = if Array.length !clients = 0 || Rng.int r 3 = 0 then Value.Link (-1 - Rng.int r nc) else Link !clients.(Rng.int r (Array.length !clients)) in
    let dt () = Value.Date (1_700_000_000_000 + (1000 * Rng.int r 40)) in
    for k = 1 to Rng.int r 30 do
      let t = -100 - k in
      if Rng.int r 8 > 0 then ops := Resolve.Add (t, client, pick_client ()) :: !ops;
      if Rng.int r 8 > 0 then ops := Add (t, date, dt ()) :: !ops;
      ops := Add (t, total, Int (Rng.int r 50)) :: !ops;
      if Rng.int r 2 = 0 then ops := Add (t, zone, Int (if Rng.int r 5 = 0 then [| min_int; max_int; -1; 1 lsl 40 |].(Rng.int r 4) else Rng.int r 4)) :: !ops;
      if Rng.int r 3 = 0 then ops := Add (t, tag, Text "x") :: !ops
    done;
    if Array.length !invoices > 0 then
      for _ = 1 to Rng.int r 10 do
        let t = !invoices.(Rng.int r (Array.length !invoices)) in
        match Rng.int r 6 with
        | 0 -> ops := Add (t, date, dt ()) :: !ops
        | 1 -> ops := Add (t, client, pick_client ()) :: !ops
        | 2 -> (match Cepheus.values v t date with x :: _ -> ops := Retract (t, date, x) :: !ops | [] -> ())
        | 3 -> (match Cepheus.values v t client with x :: _ -> ops := Retract (t, client, x) :: !ops | [] -> ())
        | 4 -> ops := Delete (t, "inv") :: !ops
        | _ -> ops := Add (t, zone, Int (Rng.int r 4)) :: !ops
      done;
    (match write !db (List.rev !ops) with
     | Ok rc ->
       List.iter (fun (k, id) -> if k > -100 then clients := Array.append !clients [| id |] else invoices := Array.append !invoices [| id |]) rc.things
     | Error e -> C.fail "seed %d: a write: %s" seed (message e));
    (* the pair declared late, undeclared, declared again *)
    if (not !declared) && Rng.int r 3 = 0 then declare_now ()
    else if !declared && Rng.int r 10 = 0 then begin
      (match write !db [ Retract (date, Schema.p_within, Link client) ] with Ok _ -> declared := false | Error e -> C.fail "seed %d: undeclare: %s" seed (message e))
    end;
    (* merges: the delta alone on top, with the newest runs, or all *)
    if Rng.int r 3 = 0 then begin
      let v = view !db in
      let take = Rng.int r (Array.length v.runs + 1) in
      db := fork (C.merge_runs v take)
    end;
    check_pairs seed (view !db) r;
    questions seed (view !db) r ~client ~date ~total ~zone ~tag ~name;
    pages seed (view !db) r ~client ~date ~total
  done;
  (* the end: one run, every pair held *)
  let v = C.compact (view !db) in
  if !declared then C.check (Store.pair_ready v ~p1:client ~p2:date) "seed %d: a full merge gives the pair" seed;
  check_pairs seed v r;
  questions seed v r ~client ~date ~total ~zone ~tag ~name;
  pages seed v r ~client ~date ~total

(* ---- live watches: a page of each client's invoices by date, Sort and Limit 3, kept by Live over writes and
   merges; at every message the watch's rows must be the join's (the pair set aside) on the view of its group ---- *)

let live_checks = ref 0

let ok = function Ok r -> r | Error e -> failwith (message e)

let rec remove_one x = function [] -> None | y :: t -> if y = x then Some t else Option.map (fun t -> y :: t) (remove_one x t)

let live seed =
  let r = Rng.make seed in
  let db = fork empty in
  let[@warning "-8"] [ client; date; total; _; _; name ] = ok (declare db props) in
  ok (within db [ (date, client) ]);
  let v = ref (view db) in
  let views = Hashtbl.create 64 in
  Hashtbl.replace views !v.group !v;
  let hub = Live.create !v ~tag:!v.group ~durable:max_int in
  let mdisk = Sim_disk.disk (Sim_disk.create (Rng.make seed)) in
  mdisk.mkdir "/merge";
  let write ops =
    let n = !v.group + 1 in
    match Resolve.resolve !v ~n ~time:n ~by:0 ~why:"" ops with
    | Ok (v', g, temps) -> v := v'; Hashtbl.replace views n v'; Live.frame hub ~tag:v'.group [ g ] v'; List.map snd temps
    | Error (Resolve.Conflict m | Invalid m | Not_unique m) -> C.fail "live %d: a write refused: %s" seed m; []
  in
  let cs = Array.of_list (write (List.init 4 (fun k -> Resolve.Add (-1 - k, name, Text (string_of_int k))))) in
  let invoices = ref [||] in
  let page c desc = { Query.vars = 3; where = [ { e = Var 0; p = client; v = Val (Link c) }; { e = Var 0; p = date; v = Var 1 }; { e = Var 0; p = total; v = Var 2 } ]; ranges = [] }, { Question.Top.keys = [ { col = 1; desc } ]; limit = 3; after = None } in
  let join g q order =
    let v = Hashtbl.find views g in
    Question.Top.pairs := false;
    Fun.protect ~finally:(fun () -> Question.Top.pairs := true) (fun () -> List.sort compare (rows_of v (Answer.answer ~order v q (Wire.Give [||]))))
  in
  let watches =
    List.concat_map
      (fun c ->
        List.map
          (fun desc ->
            let q, order = page c desc in
            let rows = ref [] and group = ref 0 in
            let emit (m : Live.msg) =
              (match m with
               | Live.Answer a -> rows := a.rows; group := a.group
               | Change ch ->
                 List.iter (fun x -> match remove_one x !rows with Some l -> rows := l | None -> C.fail "live %d: a row removed that is not there" seed) ch.removed;
                 rows := ch.added @ !rows;
                 group := ch.group
               | Same s -> group := s.group
               | Ended e -> C.fail "live %d: a watch ended: %s" seed e.message);
              incr live_checks;
              if List.sort compare !rows <> join !group q order then C.fail "live %d: a watch of #%d's page%s at group %d differs from the join" seed c (if desc then " (down)" else "") !group;
              true
            in
            ignore (Live.subscribe ~order hub q (Wire.Give [||]) ~from:0 ~emit))
          [ true; false ])
      (Array.to_list cs)
  in
  ignore watches;
  for _ = 1 to 40 do
    let dt () = Value.Date (1_700_000_000_000 + (1000 * Rng.int r 30)) in
    (match Rng.int r 4 with
     | 0 | 1 -> invoices := Array.append !invoices (Array.of_list (write [ Resolve.Add (-1, client, Link cs.(Rng.int r 4)); Add (-1, date, dt ()); Add (-1, total, Int (Rng.int r 9)) ]))
     | 2 when Array.length !invoices > 0 ->
       let i = !invoices.(Rng.int r (Array.length !invoices)) in
       ignore (write [ (if Rng.bool r then Resolve.Add (i, date, dt ()) else Add (i, total, Int (Rng.int r 9))) ])
     | _ when Array.length !invoices > 0 -> ignore (write [ Resolve.Add (!invoices.(Rng.int r (Array.length !invoices)), client, Link cs.(Rng.int r 4)) ])
     | _ -> ());
    if Rng.int r 6 = 0 then begin
      let take = if Rng.bool r then 0 else Array.length !v.runs in
      let w = Snapshot.merge mdisk "/merge" "0123456789abcdef" !v ~take ~level:(1 + take) { Journal.segment = 1; offset = 40; next = !v.group + 1 } in
      Snapshot.install mdisk "/merge" w;
      v := w.view;
      Hashtbl.replace views !v.group !v;
      Live.rebase hub !v
    end
  done

(* ---- on a real disk: format 9, reopen and replay, a replica's replay, damage, races ---- *)

let rec rm path =
  if Sys.file_exists path then
    if Sys.is_directory path then (Array.iter (fun n -> rm (Filename.concat path n)) (Sys.readdir path); Unix.rmdir path) else Sys.remove path

let copy_file a b =
  let ic = open_in_bin a and oc = open_out_bin b in
  Fun.protect ~finally:(fun () -> close_in ic; close_out oc) (fun () -> output_string oc (really_input_string ic (in_channel_length ic)))

(* the latest 3 invoices of each client and a page of one client's, as rows of values (on the pair when it is ready) *)
let answers (v : Store.view) ~client ~date ~total =
  let q = { Query.vars = 4; where = [ { e = Var 0; p = client; v = Var 3 }; { e = Var 0; p = date; v = Var 1 }; { e = Var 0; p = total; v = Var 2 } ]; ranges = [] } in
  let each = rows_of v (Answer.answer ~order:{ Question.Top.keys = [ { col = 1; desc = true } ]; limit = 3; after = None } v q (Wire.Over (Wire.Give [| 0; 1; 2; 3 |], [| 3 |], [||]))) in
  let c0 = match each with r :: _ -> (match r.(3) with Value.Link c -> c | _ -> 0) | [] -> 0 in
  let qp = { Query.vars = 3; where = [ { e = Var 0; p = client; v = Thing c0 }; { e = Var 0; p = date; v = Var 1 }; { e = Var 0; p = total; v = Var 2 } ]; ranges = [] } in
  Question.Top.path := Index;
  let page = Fun.protect ~finally:(fun () -> Question.Top.path := Auto) (fun () -> rows_of v (Answer.answer ~order:{ Question.Top.keys = [ { col = 1; desc = false } ]; limit = 5; after = None } v qp (Wire.Give [||]))) in
  each, page

(* the writes of a shop: n clients, then m invoices of random clients and dates *)
let shop db r ~client ~date ~total ~name n m =
  let rc = ok (write db (List.init n (fun k -> Resolve.Add (-1 - k, name, Text (Printf.sprintf "c%d" k))))) in
  let cs = Array.of_list (List.map snd rc.things) in
  let k = ref 0 in
  while !k < m do
    let b = min 500 (m - !k) in
    ignore (ok (write db (List.concat (List.init b (fun j -> [ Resolve.Add (-1 - j, client, Link cs.(Rng.int r n)); Add (-1 - j, date, Date (1_700_000_000_000 + (60_000 * Rng.int r 5000))); Add (-1 - j, total, Int (Rng.int r 1000)) ])))));
    k := !k + b
  done;
  cs

let run_format (path : string) = let ic = open_in_bin path in let b = really_input_string ic 8 in close_in ic; Char.code b.[4] lor (Char.code b.[5] lsl 8)

let runs_of dir = List.filter (fun n -> Filename.check_suffix n ".run") (Array.to_list (Sys.readdir (Filename.concat dir "snapshots")))

(* page k of a run's layout rewritten by [f], its CRC, the page table's and the header's computed again: damage that
   every checksum lets through *)
let rewrite_page path k f =
  let fd = Unix.openfile path [ O_RDWR ] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) @@ fun () ->
  let pread off n = let b = Bytes.create n in ignore (Unix.lseek fd off SEEK_SET); let rec go o = if o < n then go (o + Unix.read fd b o (n - o)) in go 0; b in
  let pwrite off b = ignore (Unix.lseek fd off SEEK_SET); ignore (Unix.write fd b 0 (Bytes.length b)) in
  let h = pread 0 Snapshot.header in
  let fmt = Int32.to_int (Bytes.get_int32_le h 4) in
  let nf = Snapshot.fields_of fmt in
  let g i = Int64.to_int (Bytes.get_int64_le h (24 + (8 * i))) in
  let len = g (nf - 2) and phys = g (nf - 1) in
  let npages = Pages.pages len in
  let table = pread (Snapshot.header + (phys * Pages.size)) (8 * npages) in
  let fp = Int32.to_int (Bytes.get_int32_le table (8 * k)) in
  let page = pread (Snapshot.header + (fp * Pages.size)) Pages.size in
  f page;
  pwrite (Snapshot.header + (fp * Pages.size)) page;
  Bytes.set_int32_le table ((8 * k) + 4) (Int32.of_int (Crc32c.bytes page 0 Pages.size));
  pwrite (Snapshot.header + (phys * Pages.size)) table;
  let e = 24 + (8 * nf) in
  Bytes.set_int32_le h e (Int32.of_int (Crc32c.bytes table 0 (8 * npages)));
  Bytes.set_int32_le h (e + 4) (Int32.of_int (Crc32c.bytes h 0 (e + 4)));
  pwrite 0 (Bytes.sub h 0 Snapshot.header)

let disk_tests () =
  let tmp = Option.value (Sys.getenv_opt "CEPHEUS_TMP") ~default:(Filename.get_temp_dir_name ()) in
  let dir = Filename.concat tmp (Printf.sprintf "cepheus-pairs-%d" (Unix.getpid ())) and dir2 = Filename.concat tmp (Printf.sprintf "cepheus-pairs2-%d" (Unix.getpid ())) in
  rm dir; rm dir2;
  let r = Rng.make 7 in
  (* 1. a database of format 9, as the version before wrote it *)
  Snapshot.format9 := true;
  let db = ok (open_ dir) in
  let[@warning "-8"] [ client; date; total; _; _; name ] = ok (declare db props) in
  ignore (shop db r ~client ~date ~total ~name 200 4000);
  ok (snapshot db);
  let a0 = answers (view db) ~client ~date ~total in
  close db;
  Snapshot.format9 := false;
  C.check (List.for_all (fun n -> run_format (Filename.concat (Filename.concat dir "snapshots") n) = 9) (runs_of dir)) "format 9 written";
  let db = ok (open_ dir) in
  C.check (notes db = []) "a database of format 9 opens as it is, no run set aside, nothing replayed: %s" (String.concat "; " (notes db));
  C.check (answers (view db) ~client ~date ~total = a0) "a database of format 9: the same answers";
  (* declared: its run of format 9 holds no pair, the plain join answers *)
  ok (within db [ (date, client) ]);
  C.check (Schema.within (view db).schema date = Some client) "the pair declared";
  C.check (not (Store.pair_ready (view db) ~p1:client ~p2:date)) "a run of format 9 holds no pair: not read";
  let before = Atomic.get Answer.pair_each in
  C.check (answers (view db) ~client ~date ~total = a0) "declared over a run of format 9: the same answers";
  C.check (Atomic.get Answer.pair_each = before) "declared over a run of format 9: the plain join";
  (* merged: format 10, every run with the pair *)
  ok (snapshot db);
  C.check (List.for_all (fun n -> run_format (Filename.concat (Filename.concat dir "snapshots") n) = 10) (runs_of dir)) "merged: format 10";
  C.check (Store.pair_ready (view db) ~p1:client ~p2:date) "merged: the pair read";
  C.check (answers (view db) ~client ~date ~total = a0) "merged, on the pair: the same answers";
  C.check (Atomic.get Answer.pair_each > before) "merged: the pair answers";
  ignore (C.pairs_hold "merged" (view db));
  (* 2. reopened, then writes left in the journal and replayed at the next open *)
  close db;
  let db = ok (open_ dir) in
  C.check (notes db = [] && Store.pair_ready (view db) ~p1:client ~p2:date) "reopened: the pair read, nothing set aside";
  ignore (shop db r ~client ~date ~total ~name 20 3000);
  let a1 = answers (view db) ~client ~date ~total in
  Answer.use_pairs := false;
  let a1' = Fun.protect ~finally:(fun () -> Answer.use_pairs := true) (fun () -> answers (view db) ~client ~date ~total) in
  C.check (a1 = a1') "with a delta: the pair's answers are the join's";
  close db;
  let db = ok (open_ dir) in
  C.check (answers (view db) ~client ~date ~total = a1) "replayed: the same answers";
  ignore (C.pairs_hold "replayed" (view db));
  let facts = C.facts_of_view (view db) in
  close db;
  (* 3. a replica's state: the journal alone, every group replayed (the declaration with them), its own merge *)
  Unix.mkdir dir2 0o700;
  Unix.mkdir (Filename.concat dir2 "journal") 0o700;
  copy_file (Filename.concat dir "cepheus") (Filename.concat dir2 "cepheus");
  Array.iter (fun n -> copy_file (Filename.concat (Filename.concat dir "journal") n) (Filename.concat (Filename.concat dir2 "journal") n)) (Sys.readdir (Filename.concat dir "journal"));
  let db2 = ok (open_ dir2) in
  C.check (Schema.within (view db2).schema date = Some client) "a replica given the journal: the declaration";
  ok (snapshot db2);
  C.check (Store.pair_ready (view db2) ~p1:client ~p2:date) "a replica's merge: the pair";
  C.check (C.F.equal (C.facts_of_view (view db2)) facts && answers (view db2) ~client ~date ~total = a1) "a replica: the same facts and answers";
  ignore (C.pairs_hold "a replica" (view db2));
  close db2;
  rm dir2;
  (* 4. a page of the pairs flipped: its CRC refuses it, the run set aside, the journal replayed *)
  let db = ok (open_ dir) in
  ok (snapshot db);
  let a2 = answers (view db) ~client ~date ~total in
  let rp = (view db).runs.(0).a.o_pairs in
  close db;
  let file = Filename.concat (Filename.concat dir "snapshots") (List.hd (runs_of dir)) in
  let k = (rp + 40) lsr Pages.bits in
  (match Snapshot.file_page Disk.real file k with
   | Some f ->
     let fd = Unix.openfile file [ O_RDWR ] 0 in
     ignore (Unix.lseek fd (Snapshot.header + (f * Pages.size) + ((rp + 40) land Pages.mask)) SEEK_SET);
     ignore (Unix.write fd (Bytes.of_string "\xAA") 0 1);
     Unix.close fd
   | None -> C.fail "the pairs' page is in the file");
  let db = ok (open_ dir) in
  C.check (List.exists (fun n -> String.length n > 0) (notes db)) "a flipped page of the pairs: the run set aside (%s)" (String.concat "; " (notes db));
  C.check (answers (view db) ~client ~date ~total = a2) "a flipped page of the pairs: the same answers, replayed";
  ok (snapshot db);
  let rp = (view db).runs.(0).a.o_pairs in
  close db;
  (* 5. its groups' count made larger than its rows, every checksum computed again: the section's checks refuse it *)
  let file = Filename.concat (Filename.concat dir "snapshots") (List.hd (runs_of dir)) in
  let at = rp + 8 + 24 in
  rewrite_page file (at lsr Pages.bits) (fun page -> let o = at land Pages.mask in Bytes.set_int64_le page o (Int64.add (Bytes.get_int64_le page o) 100000L));
  let db = ok (open_ dir) in
  C.check (List.exists (fun n -> let m = "pair" in let ln = String.length m in let rec has i = i + ln <= String.length n && (String.sub n i ln = m || has (i + 1)) in has 0) (notes db))
    "a pair's counts out of their rows, the checksums good: refused by the checks (%s)" (String.concat "; " (notes db));
  C.check (answers (view db) ~client ~date ~total = a2) "the pairs' checks: the same answers, replayed";
  (* 6. a declaration racing writes: writers in threads while the pair is undeclared and declared again *)
  let stop = Atomic.make false and written = Atomic.make 0 in
  let writer seed () =
    let r = Rng.make seed in
    while not (Atomic.get stop) do
      ignore (ok (write db (List.concat (List.init 20 (fun j -> [ Resolve.Add (-1 - j, client, Link (List.hd (List.map snd (ok (write db [ Add (-1, name, Text "x") ])).things))); Add (-1 - j, date, Date (1_700_000_000_000 + Rng.int r 1_000_000)) ])))));
      Atomic.incr written
    done
  in
  let ts = List.init 3 (fun i -> Thread.create (writer (100 + i)) ()) in
  for _ = 1 to 5 do
    ignore (ok (write db [ Retract (date, Schema.p_within, Link client) ]));
    Thread.delay 0.02;
    ok (within db [ (date, client) ]);
    Thread.delay 0.02;
    if Rng.bool r then ok (snapshot db)
  done;
  Atomic.set stop true;
  List.iter Thread.join ts;
  C.check (Atomic.get written > 0) "the writers wrote";
  ignore (C.pairs_hold "after the race" (view db));
  let a3 = answers (view db) ~client ~date ~total in
  Answer.use_pairs := false;
  C.check (Fun.protect ~finally:(fun () -> Answer.use_pairs := true) (fun () -> answers (view db) ~client ~date ~total) = a3) "after the race: the pair's answers are the join's";
  ok (snapshot db);
  C.check (Store.pair_ready (view db) ~p1:client ~p2:date) "after the race, merged: the pair";
  ignore (C.pairs_hold "after the race, merged" (view db));
  (* 7. two declarations of one property within two others at once: one wins, the other is refused, naming both *)
  let[@warning "-8"] [ zone ] = ok (declare db [ prop "inv/zone" Tint ]) in
  ignore (ok (write db [ Retract (date, Schema.p_within, Link client) ]));
  let res = Array.make 2 (Ok ()) in
  let t1 = Thread.create (fun () -> res.(0) <- within db [ (date, client) ]) () and t2 = Thread.create (fun () -> res.(1) <- within db [ (date, zone) ]) () in
  Thread.join t1;
  Thread.join t2;
  let oks = Array.fold_left (fun n x -> if Result.is_ok x then n + 1 else n) 0 res in
  C.check (oks = 1) "two declarations at once: one wins (%s)" (String.concat "; " (Array.to_list (Array.map (function Ok () -> "ok" | Error e -> message e) res)));
  close db;
  rm dir

let () =
  let seeds = ref 100 and one = ref None in
  Arg.parse [ ("--seeds", Arg.Set_int seeds, "N"); ("--seed", Arg.Int (fun s -> one := Some s), "N") ] (fun _ -> ()) "pairs.exe";
  (match !one with Some s -> run s; live s | None -> for s = 1 to !seeds do run s; if s <= 50 then live s done; disk_tests ());
  Printf.printf "  %d streams of a group checked, on %d views that read a pair\n" !stream_checks !ready_views;
  Printf.printf "  %d messages of live watches checked against the join\n" !live_checks;
  Printf.printf "  %d questions on both paths, %d Each of them on the pair (%d folds), %d pages on the pair\n" !question_checks !on_pair
    (Atomic.get Answer.pair_rounds) (Atomic.get Question.Top.paired);
  C.finish "pairs"
