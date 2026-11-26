(* Windows (protocol 10) beside PostgreSQL's window functions, on the data of bench/rbench.ml (rbench.exe load: 10,000
   clients of 100 cities, 245,000 invoices, 1,000,000 facts), as the server answers them (Answer: the engine alone, no
   socket).

     wbench.exe run DIR     each question RUNS times (21), its median and interval (Stats); a line a question;
                            CEPHEUS_DOMAINS=n: on n domains at most

   The questions: every invoice with its date and total, sorted by date, and one window: the running total, the
   moving average of the last 3, the rank by total, the previous invoice's date; in one group (no Each), each city's
   (100 groups: Each by the client's city), each client's (10,000); the 3 latest invoices of each client (Each and
   Limit 3) and the last one of each (Limit 1, DISTINCT ON); and the monthly totals in Paris with their running total,
   the month before and the 3-month moving average (a report of 120 groups). bench/pg/pg.sh windows asks
   PostgreSQL the same. *)

open Cepheus
open Cepheus_server

let ok = function Ok r -> r | Error e -> failwith (message e)
let runs = match Sys.getenv_opt "RUNS" with Some r -> int_of_string r | None -> 21

let measure name f =
  let rows = ref 0 in
  let per = Array.init runs (fun _ -> let t = Unix.gettimeofday () in rows := f (); Unix.gettimeofday () -. t) in
  Stats.print (Printf.sprintf "%s (%d rows)" name !rows) per

let run dir =
  Option.iter (fun d -> Query.domains := int_of_string d) (Sys.getenv_opt "CEPHEUS_DOMAINS");
  let db = ok (open_ dir) in
  let v = view db in
  let p n = Option.get (property v n) in
  let city = p "client/city" and client = p "invoice/client" and total = p "invoice/total" and date = p "invoice/date" in
  (* the invoice 0, its date 1, its total 2, then its client 3 and the client's city 4 as the grouping asks *)
  let ask grouping =
    let pats = [ { Query.e = Var 0; p = date; v = Var 1 }; { e = Var 0; p = total; v = Var 2 } ] in
    let pats, give, each =
      match grouping with
      | `One -> pats, [| 0; 1; 2 |], [||]
      | `City -> pats @ [ { e = Var 0; p = client; v = Var 3 }; { e = Var 3; p = city; v = Var 4 } ], [| 0; 1; 2; 4 |], [| 3 |]
      | `Client -> pats @ [ { e = Var 0; p = client; v = Var 3 } ], [| 0; 1; 2; 3 |], [| 3 |]
    in
    let vars = match grouping with `City -> 5 | `Client -> 4 | `One -> 3 in
    { Query.vars; where = pats; ranges = [] }, give, each
  in
  let by_date = { Question.Top.keys = [ { col = 1; desc = false } ]; limit = 0; after = None } in
  let by_total = { Question.Top.keys = [ { col = 2; desc = true } ]; limit = 0; after = None } in
  let windows =
    [ "Running(Sum(t))", by_date, Wire.Running (Sum 2, 0); "Running(Avg(t), last = 3)", by_date, Wire.Running (Avg 2, 3);
      "Rank() by total", by_total, Wire.Rank (1, false); "Prev(d)", by_date, Wire.Prev (1, 1) ]
  in
  List.iter
    (fun (gname, grouping) ->
      let q, give, each = ask grouping in
      List.iter
        (fun (wname, order, w) ->
          measure (Printf.sprintf "%s %s" wname gname) (fun () -> (Answer.answer ~order v q (Wire.Over (Wire.Give give, each, [| w |]))).n))
        windows)
    [ "1 group", `One; "100 groups (city)", `City; "10,000 groups (client)", `Client ];
  (* the 3 latest invoices of each client, the last one of each *)
  let q, give, each = ask `Client in
  let latest k = { Question.Top.keys = [ { col = 1; desc = true } ]; limit = k; after = None } in
  measure "the 3 latest invoices of each client (Each, Limit 3)" (fun () -> (Answer.answer ~order:(latest 3) v q (Wire.Over (Wire.Give give, each, [||]))).n);
  measure "the last invoice of each client (Each, Limit 1)" (fun () -> (Answer.answer ~order:(latest 1) v q (Wire.Over (Wire.Give give, each, [||]))).n);
  (* the monthly totals in Paris, with their running total, the month before and the 3-month moving average *)
  let qd = { Query.vars = 3; where = [ { e = Var 0; p = total; v = Var 1 }; { e = Var 0; p = date; v = Var 2 } ]; ranges = [] } in
  let months = { Question.Top.keys = [ { col = 0; desc = false } ]; limit = 0; after = None } in
  measure "monthly totals in Paris with Running, Prev and a 3-month Avg (a report)" (fun () ->
      (Answer.answer ~order:months ~extra:[ Question.Ask.Trunc (3, 2, "month", "Europe/Paris") ] v qd
         (Wire.Over (Wire.Group ([| 3 |], [| Wire.Sum 1 |]), [||], [| Wire.Running (Sum 1, 0); Prev (1, 1); Running (Avg 1, 3) |]))).n);
  (* a page deep in the running total: the 51 rows after the 200,000th, the windows over every row before it *)
  let q1, give1, _ = ask `One in
  let all = Answer.answer ~order:by_date v q1 (Wire.Give give1) in
  let cursor = Array.init all.cols (fun j -> Answer.value v all 200_000 j) in
  measure "a page of 51 after the 200,000th row, its running total" (fun () ->
      (Answer.answer ~order:{ by_date with limit = 51; after = Some cursor } v q1 (Wire.Over (Wire.Give give1, [||], [| Wire.Running (Sum 2, 0) |]))).n);
  measure "the first page of 51, its running total" (fun () ->
      (Answer.answer ~order:{ by_date with limit = 51 } v q1 (Wire.Over (Wire.Give give1, [||], [| Wire.Running (Sum 2, 0) |]))).n);
  close db

let () =
  match Sys.argv with
  | [| _; "run"; dir |] -> run dir
  | _ -> prerr_endline "wbench.exe run DIR"; exit 2
