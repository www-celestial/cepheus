(* Live questions (Live), checked against the naive evaluator: random groups (new things, one-valued fields replaced,
   tags and links added and retracted, facts a rule derives, retractions that take derived facts away) in frames of
   one to four groups, the views merged into runs at random, watches of questions that share templates (the same
   question with other constants), that project (one row a binding: Find's rows), that aggregate (counts, sums,
   minimums and maximums), with ranges, links and constants in the thing's place; frames made durable at once or
   later; watches that fall behind (their queue full), resume from their group (Same or the answer), or end with a
   large group. At every message a watch gets, its rows must be the naive answer of its question on the facts of the
   view of the message's group, as a multiset (G11 of live questions); and no message is given before its frame is
   durable. A watch of Give may have Sort (random keys, ascending or descending) and a Limit of 1 to 5 rows, or none:
   its rows, in its order, must then be the naive answer sorted and cut (its first k rows and the copies of the k-th)
   and Find's rows with the same Sort and Limit on the view of that group, and each message's rows must come in the
   order. A failure prints its seed; [live_sim.exe --seed N] replays it. *)

open Cepheus
open Cepheus_server
module C = Check

let props =
  [ prop "name" Ttext; prop ~many:true "tag" Ttext; prop "score" Tint; prop "status" Ttext; prop ~many:true "friend" Tlink;
    prop "price" (Tmoney 2); prop "owner" Tlink ]

let messages = ref 0
let sames = ref 0
let laggings = ref 0

module Top = Question.Top

let windows = ref 0

type watch = {
  q : Query.t;
  sel : Wire.select;
  order : Top.order;  (* Sort and Limit, or none *)
  mutable sub : Live.sub option;
  mutable rows : Value.t array list;  (* as its messages left them *)
  mutable group : int;
  mutable started : bool;
  mutable ended : string option;
  mutable full : bool;  (* the next message finds its queue full *)
}

(* the naive answer: the bindings on the facts, projected on Give, or aggregated by key *)
let expected facts (q : Query.t) (sel : Wire.select) =
  let bs = C.naive facts q in
  match sel with
  | Wire.Give g ->
    let g = if Array.length g = 0 then Array.init q.vars Fun.id else g in
    List.sort compare (List.map (fun b -> Array.map (fun x -> b.(x)) g) bs)
  | Group (keys, aggs) ->
    let tbl = Hashtbl.create 16 in
    List.iter
      (fun b ->
        let k = Array.map (fun x -> b.(x)) keys in
        Hashtbl.replace tbl k (b :: Option.value (Hashtbl.find_opt tbl k) ~default:[]))
      bs;
    let num = function Value.Int n | Money n | Date n -> n | _ -> 0 in
    let typed like n = match like with Value.Money _ -> Value.Money n | Date _ -> Date n | _ -> Int n in
    Hashtbl.fold
      (fun k l acc ->
        let a =
          Array.map
            (function
              | Wire.Count -> Value.Int (List.length l)
              | Sum x -> typed (List.hd l).(x) (List.fold_left (fun s b -> s + num b.(x)) 0 l)
              | Min x -> typed (List.hd l).(x) (List.fold_left (fun s b -> min s (num b.(x))) max_int l)
              | Max x -> typed (List.hd l).(x) (List.fold_left (fun s b -> max s (num b.(x))) min_int l))
            aggs
        in
        Array.append k a :: acc)
      tbl []
    |> List.sort compare

let rec remove_one x = function [] -> None | y :: r when y = x -> Some r | y :: r -> Option.map (fun r -> y :: r) (remove_one x r)

let hubr = ref (Live.create (Store.empty ()) ~tag:0 ~durable:0)

let run seed =
  let r = Rng.make seed in
  let db = fork empty in
  let[@warning "-8"] (Ok [ name; tag; score; status; friend; price; owner ]) = declare db props in
  (* a rule half of the time: friends are friends both ways *)
  if Rng.int r 2 = 0 then
    ignore
      (define db
         [ { name = "both-ways"; vars = 2; where = [ { e = Var 0; p = friend; v = Var 1 } ]; ranges = [];
             head = Give { e = Var 1; p = friend; v = Var 0 } } ]);
  let v = ref (view db) in
  let views = Hashtbl.create 256 in
  Hashtbl.replace views !v.group !v;
  let things = ref [||] in
  let pick () = if Array.length !things = 0 then Store.max_thing !v + 1 else !things.(Rng.int r (Array.length !things)) in
  let statuses = [| "unpaid"; "paid"; "late" |] and tags = [| "hot"; "cold" |] and names = [| "ada"; "bob"; "cyd"; "dee" |] in
  let hub = Live.create !v ~tag:!v.group ~durable:!v.group in
  hubr := hub;
  let durable = ref !v.group and pending = ref [] in
  let watches = ref [] in
  let facts = Hashtbl.create 64 in
  let facts_at g = match Hashtbl.find_opt facts g with Some f -> f | None -> let f = C.facts_of_view (Hashtbl.find views g) in Hashtbl.replace facts g f; f in
  (* merges into runs of this seed's own disk *)
  let mdisk = Sim_disk.disk (Sim_disk.create (Rng.make seed)) in
  mdisk.mkdir "/merge";
  let merge (v : Store.view) take =
    let w = Snapshot.merge mdisk "/merge" "0123456789abcdef" v ~take ~level:(1 + take) { Journal.segment = 1; offset = 40; next = v.group + 1 } in
    Snapshot.install mdisk "/merge" w;
    w.view
  in
  let check_now w g what =
    let f = facts_at g in
    let want = expected f w.q w.sel and got = List.sort compare w.rows in
    let want, got =
      if w.order = Top.none then want, got
      else begin
        (* in the order: the oracle's rows, and Find's on the view of that group *)
        incr windows;
        let o = C.top_rows w.order want and mine = C.top_rows { w.order with limit = 0 } w.rows in
        let v = Hashtbl.find views g in
        let a = Answer.answer ~order:w.order v w.q w.sel in
        let find = List.init a.n (fun i -> Array.init a.cols (fun j -> Store.value v (a.typ j) (a.word i j))) in
        C.check (find = o) "seed %d: %s of group %d: Find gives %d rows, the oracle %d" seed what g (List.length find) (List.length o);
        o, mine
      end
    in
    if want <> got && Sys.getenv_opt "LIVE_DEBUG" <> None then begin
      let pr l = String.concat " | " (List.map (fun r -> String.concat "," (Array.to_list (Array.map Value.to_string r))) l) in
      Printf.printf "question: %s\n  got: %s\n  want: %s\n  watch group %d\n" (String.concat "; " (List.map (fun (pt : Query.pattern) ->
        let t = function Query.Var x -> "?" ^ string_of_int x | Thing e -> "#" ^ string_of_int e | Val x -> Value.to_string x in
        Printf.sprintf "[%s %d %s]" (t pt.e) pt.p (t pt.v)) w.q.where)) (pr got) (pr want) w.group;
      (match w.sub with
       | Some s -> Printf.printf "  template held: %b, count %d, subs %d, slots %s, gone %b, in by_prop %b\n" (Hashtbl.mem !hubr.Live.templates s.t.tkey) s.t.count (Hashtbl.length s.t.subs)
           (String.concat "," (List.map (fun (k, n) -> Value.to_string k ^ ":" ^ string_of_int n) (List.of_seq (Hashtbl.to_seq s.t.slots.(0))))) s.gone
           (Hashtbl.fold (fun _ l acc -> acc || List.exists (fun (t', _) -> t' == s.t) l) !hubr.Live.by_prop false)
       | None -> ())
    end;
    C.check (want = got) "seed %d: %s of group %d: %d rows, %d expected" seed what g (List.length got) (List.length want)
  in
  let emit w (m : Live.msg) =
    match m with
    | Live.Ended e ->
      if e.code = "lagging" then incr laggings;
      w.ended <- Some e.code;
      w.sub <- None;
      true
    | _ when w.full -> w.full <- false; false
    | _ -> (
      incr messages;
      match m with
      | Answer a ->
        C.check (w.order = Top.none || C.in_order w.order a.rows) "seed %d: an answer's rows out of the order" seed;
        C.check (a.group <= !durable) "seed %d: an answer of group %d given before it is durable (%d)" seed a.group !durable;
        C.check (a.group >= w.group) "seed %d: an answer of group %d after %d" seed a.group w.group;
        w.rows <- a.rows; w.group <- a.group; w.started <- true; check_now w a.group "an answer"; true
      | Change c ->
        C.check (w.order = Top.none || (C.in_order w.order c.added && C.in_order w.order c.removed)) "seed %d: a change's rows out of the order" seed;
        C.check (w.started && c.group > w.group) "seed %d: a change of group %d after %d" seed c.group w.group;
        C.check (c.group <= !durable) "seed %d: a change of group %d given before it is durable (%d)" seed c.group !durable;
        List.iter (fun x -> match remove_one x w.rows with Some rows -> w.rows <- rows | None -> C.check false "seed %d: a row removed that is not there" seed) c.removed;
        w.rows <- c.added @ w.rows;
        w.group <- c.group;
        check_now w c.group "a change";
        true
      | Same s ->
        incr sames;
        C.check (w.started && s.group >= w.group) "seed %d: same %d after %d" seed s.group w.group;
        w.group <- s.group;
        check_now w s.group "same";
        true
      | Ended _ -> true)
  in
  let subscribe w ~from =
    w.ended <- None;
    match Live.subscribe ~order:w.order hub w.q w.sel ~from ~emit:(emit w) with
    | s -> if w.ended = None then w.sub <- Some s (* its first message may end it at once (its queue full) *)
    | exception Query.Bad m -> C.check false "seed %d: a question refused: %s" seed m
  in
  let questions () =
    let st () = Value.Text statuses.(Rng.int r 3) and who () = pick () in
    match Rng.int r 9 with
    | 0 -> { Query.vars = 1; where = [ { e = Var 0; p = status; v = Val (st ()) } ]; ranges = [] }, Wire.Give [||]
    | 1 ->
      { vars = 2; where = [ { e = Var 0; p = owner; v = Val (Link (who ())) }; { e = Var 0; p = status; v = Val (Text "unpaid") }; { e = Var 0; p = price; v = Var 1 } ]; ranges = [] },
      Wire.Give [| 0; 1 |]
    | 2 -> { vars = 2; where = [ { e = Var 0; p = owner; v = Val (Link (who ())) }; { e = Var 0; p = price; v = Var 1 } ]; ranges = [] }, Wire.Give [| 1 |]
    | 3 ->
      { vars = 2; where = [ { e = Var 0; p = status; v = Val (st ()) }; { e = Var 0; p = price; v = Var 1 } ]; ranges = [] },
      Wire.Group ([||], [| Count; Sum 1; Min 1; Max 1 |])
    | 4 -> { vars = 3; where = [ { e = Var 0; p = owner; v = Var 1 }; { e = Var 0; p = price; v = Var 2 } ]; ranges = [] }, Wire.Group ([| 1 |], [| Count; Sum 2; Max 2 |])
    | 5 -> { vars = 3; where = [ { e = Var 0; p = friend; v = Var 1 }; { e = Var 1; p = name; v = Var 2 } ]; ranges = [] }, Wire.Give [| 0; 2 |]
    | 6 -> { vars = 1; where = [ { e = Thing (who ()); p = friend; v = Var 0 } ]; ranges = [] }, Wire.Give [||]
    | 7 ->
      let lo = Rng.int r 50 in
      { vars = 2; where = [ { e = Var 0; p = score; v = Var 1 } ]; ranges = [ 1, Int lo, Int (lo + 30) ] }, Wire.Give [||]
    | _ -> { vars = 2; where = [ { e = Var 0; p = tag; v = Val (Text tags.(Rng.int r 2)) }; { e = Var 0; p = name; v = Var 1 } ]; ranges = [] }, Wire.Give [| 1 |]
  in
  let add_watch () =
    let q, sel = questions () in
    (* Sort and Limit half of the time on a Give: random keys, a limit of 1 to 5, or none *)
    let order =
      match sel with
      | Wire.Give g when Rng.int r 2 = 0 -> C.random_order r (if Array.length g = 0 then q.vars else Array.length g)
      | _ -> Top.none
    in
    let w = { q; sel; order; sub = None; rows = []; group = 0; started = false; ended = None; full = false } in
    watches := w :: !watches;
    subscribe w ~from:0
  in
  let random_ops () =
    let x = pick () in
    match Rng.int r 8 with
    | 0 | 1 ->
      [ Resolve.Add (-1, name, Text names.(Rng.int r 4)); Add (-1, status, Text statuses.(Rng.int r 3)); Add (-1, price, Money (Rng.int r 900));
        Add (-1, owner, Link (pick ())); Add (-1, score, Int (Rng.int r 100)) ]
    | 2 -> [ Add (x, status, Text statuses.(Rng.int r 3)) ]
    | 3 -> [ Add (x, price, Money (Rng.int r 900)); Add (x, score, Int (Rng.int r 100)) ]
    | 4 -> (match Cepheus.values !v x tag with t :: _ when Rng.int r 2 = 0 -> [ Retract (x, tag, t) ] | _ -> [ Add (x, tag, Text tags.(Rng.int r 2)) ])
    | 5 -> (match Cepheus.values !v x friend with f :: _ when Rng.int r 2 = 0 -> [ Retract (x, friend, f) ] | _ -> [ Add (x, friend, Link (pick ())) ])
    | 6 -> List.map (fun (p, y) -> Resolve.Retract (x, p, y)) (Cepheus.get !v x |> List.filter (fun (p, _) -> p >= Schema.first_prop))
    | _ -> [ Add (x, owner, Link (pick ())); Add (x, name, Text names.(Rng.int r 4)) ]
  in
  for _ = 1 to 6 do add_watch () done;
  let rounds = 60 + Rng.int r 60 in
  for _ = 1 to rounds do
    (* a frame of one to four groups *)
    let gs = ref [] in
    for _ = 1 to 1 + Rng.int r 4 do
      let n = !v.group + 1 in
      match Resolve.resolve !v ~n ~time:n ~by:0 ~why:"" (random_ops ()) with
      | Ok (v', g, temps) ->
        v := v';
        Hashtbl.replace views n v';
        gs := g :: !gs;
        List.iter (fun (_, e) -> things := Array.append !things [| e |]) temps
      | Error _ -> ()
    done;
    if !gs <> [] then begin
      if Sys.getenv_opt "LIVE_DEBUG" <> None then
        List.iter (fun (g : Group.t) -> Printf.printf "group %d: %s\n" g.n (String.concat "; " (Array.to_list (Array.map (fun (c : Group.change) ->
          Printf.sprintf "%d %d %d %s" (Group.code c.kind) c.e c.p (Value.to_string c.v)) g.changes)))) (List.rev !gs);
      Live.frame hub ~tag:!v.group (List.rev !gs) !v;
      pending := !v.group :: !pending
    end;
    (* durable now, or a frame or two later *)
    if Rng.int r 3 > 0 && !pending <> [] then begin
      durable := List.hd !pending;
      pending := [];
      Live.durable hub !durable;
      (* a watch that got no message of a durable frame: its rows did not change *)
      List.iter (fun w -> if w.started && w.sub <> None && w.ended = None && not w.full then check_now w !durable "no message") !watches
    end;
    (* the view on runs, as after a merge *)
    if Rng.int r 10 = 0 then begin
      let v' = if Rng.int r 2 = 0 then merge !v 0 else merge !v (Array.length !v.runs) in
      v := v';
      Hashtbl.replace views v'.group v';
      Live.rebase hub v'
    end;
    match Rng.int r 20 with
    | 0 | 1 -> add_watch ()
    | 2 -> (match !watches with w :: _ when w.sub <> None -> w.full <- true | _ -> ())
    | 3 ->
      (* a watch stops and resumes from its group *)
      (match List.filter (fun w -> w.sub <> None && w.started) !watches with
       | w :: _ ->
         Live.unsubscribe hub (Option.get w.sub);
         w.sub <- None;
         subscribe w ~from:w.group
       | [] -> ())
    | 4 when Rng.int r 4 = 0 ->
      if Sys.getenv_opt "LIVE_DEBUG" <> None then print_endline "reset";
      (* a large group: every watch asked again *)
      Live.reset hub !v ~tag:!v.group
    | _ -> ()
  done;
  (* the end: everything durable; each watch that fell behind watches again from its group *)
  durable := !v.group;
  Live.durable hub !durable;
  List.iter (fun w -> if w.sub = None then subscribe w ~from:w.group) !watches;
  (* no change since a watch's last message: its rows are the answer now *)
  List.iter (fun w -> if w.started && w.sub <> None && w.ended = None then check_now w !v.group "the end") !watches

let () =
  let seeds = ref 400 and one = ref None in
  Arg.parse [ "--seeds", Arg.Set_int seeds, "N"; "--seed", Arg.Int (fun s -> one := Some s), "N" ] ignore "live_sim.exe";
  (match !one with Some s -> run s | None -> for s = 1 to !seeds do run s done);
  Printf.printf "live: %d messages checked (%d same, %d lagging; %d checks of a window against Find)\n" !messages !sames !laggings !windows;
  C.finish "live"
