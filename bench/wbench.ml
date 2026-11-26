(* Windows (protocol 10) beside PostgreSQL's window functions, on the data of bench/rbench.ml (rbench.exe load: 10,000
   clients of 100 cities, 245,000 invoices, 1,000,000 facts), as the server answers them (Answer: the engine alone, no
   socket).

     wbench.exe run DIR     each question RUNS times (21), its median and interval (Stats); a line a question;
                            CEPHEUS_DOMAINS=n: on n domains at most
     wbench.exe pair DIR    the questions an index of two properties answers (invoice/date within invoice/client,
                            Cepheus.within): the 3 latest invoices of each client, the last one of each, the 10 latest
                            of the client with the most invoices and the 10 after them; RUNS times each
     wbench.exe writes DIR  writes on a fork of the database (resolved and applied, no journal: the engine's own cost),
                            RUNS rounds of 2,000 groups each: a new invoice (its client, date, total, status), its date
                            changed (a paired property when the pair is declared), its total changed (a plain one); the
                            median microseconds a group
     wbench.exe within DIR  declares invoice/date within invoice/client, then a merge of every run (snapshot)
     wbench.exe merge DIR   100 groups of a new invoice, no merge in the background, then the merge of every run and
                            the delta into one (snapshot): its time, the file's size (the database is written to: a copy)

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
  (* the same pages without windows: what a window adds *)
  measure "a page of 51 after the 200,000th row, no window" (fun () -> (Answer.answer ~order:{ by_date with limit = 51; after = Some cursor } v q1 (Wire.Give give1)).n);
  measure "the first page of 51, no window" (fun () -> (Answer.answer ~order:{ by_date with limit = 51 } v q1 (Wire.Give give1)).n);
  close db

(* the client with the most invoices (the least id among those): the same in PostgreSQL's rows *)
let busiest (v : Store.view) client =
  let n = Hashtbl.create 10_000 in
  Store.iter_prop v client (fun _ c -> Hashtbl.replace n c (1 + Option.value (Hashtbl.find_opt n c) ~default:0));
  Hashtbl.fold (fun c k (bc, bk) -> if k > bk || (k = bk && c < bc) then (c, k) else (bc, bk)) n (max_int, 0)

let pair dir =
  Option.iter (fun d -> Query.domains := int_of_string d) (Sys.getenv_opt "CEPHEUS_DOMAINS");
  (* the open: its runs read and checked (the pairs' sections too), nothing replayed *)
  Stats.print "open (start-up)" (Array.init runs (fun _ -> let t = Unix.gettimeofday () in let db = ok (open_ dir) in let d = Unix.gettimeofday () -. t in close db; d));
  let db = ok (open_ dir) in
  let v = view db in
  let p n = Option.get (property v n) in
  let client = p "invoice/client" and total = p "invoice/total" and date = p "invoice/date" in
  let q = { Query.vars = 4; where = [ { Query.e = Var 0; p = date; v = Var 1 }; { e = Var 0; p = total; v = Var 2 }; { e = Var 0; p = client; v = Var 3 } ]; ranges = [] } in
  let latest k = { Question.Top.keys = [ { col = 1; desc = true } ]; limit = k; after = None } in
  measure "the 3 latest invoices of each client (Each, Limit 3)" (fun () -> (Answer.answer ~order:(latest 3) v q (Wire.Over (Wire.Give [| 0; 1; 2; 3 |], [| 3 |], [||]))).n);
  measure "the last invoice of each client (Each, Limit 1)" (fun () -> (Answer.answer ~order:(latest 1) v q (Wire.Over (Wire.Give [| 0; 1; 2; 3 |], [| 3 |], [||]))).n);
  let c0, k0 = busiest v client in
  Printf.eprintf "the busiest client: #%d, %d invoices\n%!" c0 k0;
  let qc = { Query.vars = 3; where = [ { Query.e = Var 0; p = client; v = Thing c0 }; { e = Var 0; p = date; v = Var 1 }; { e = Var 0; p = total; v = Var 2 } ]; ranges = [] } in
  let first = Answer.answer ~order:(latest 10) v qc (Wire.Give [||]) in
  let cursor = Array.init first.cols (fun j -> Answer.value v first (first.n - 1) j) in
  measure (Printf.sprintf "the 10 latest invoices of the busiest client (%d invoices)" k0) (fun () -> (Answer.answer ~order:(latest 10) v qc (Wire.Give [||])).n);
  measure "the 10 after them (After)" (fun () -> (Answer.answer ~order:{ (latest 10) with after = Some cursor } v qc (Wire.Give [||])).n);
  (* the process's memory: resident now and at its peak (Linux's /proc/self/status) *)
  let ic = open_in "/proc/self/status" in
  (try
     while true do
       let l = input_line ic in
       if String.length l > 6 && (String.sub l 0 6 = "VmRSS:" || String.sub l 0 6 = "VmHWM:") then print_endline ("memory " ^ l)
     done
   with End_of_file -> ());
  close_in ic;
  close db

let writes dir =
  let db = ok (open_ dir) in
  let v = view db in
  let p n = Option.get (property v n) in
  let client = p "invoice/client" and total = p "invoice/total" and date = p "invoice/date" and status = p "invoice/status" in
  let cs = Array.of_list (List.sort_uniq compare (let l = ref [] in Store.iter_prop v client (fun _ c -> l := c :: !l); !l)) in
  let is = let l = ref [] in Store.iter_prop v client (fun i _ -> l := i :: !l); Array.of_list !l in
  let n = 2_000 in
  let round f =
    let f' = fork v in
    let r = Rng.make 7 in
    let t = Unix.gettimeofday () in
    for k = 1 to n do ignore (ok (write f' (f r k))) done;
    (Unix.gettimeofday () -. t) /. float_of_int n
  in
  let day = 86_400_000 in
  let cases =
    [ "a new invoice (client, date, total, status)", (fun r _ -> [ Resolve.Add (-1, client, Link cs.(Rng.int r (Array.length cs))); Add (-1, date, Date (1_483_228_800_000 + (day * Rng.int r 3650))); Add (-1, total, Money (1 + Rng.int r 100_000)); Add (-1, status, Text "paid") ]);
      "an invoice's date changed", (fun r _ -> [ Resolve.Add (is.(Rng.int r (Array.length is)), date, Date (1_483_228_800_000 + (day * Rng.int r 3650))) ]);
      "an invoice's total changed", (fun r _ -> [ Resolve.Add (is.(Rng.int r (Array.length is)), total, Money (1 + Rng.int r 100_000)) ]) ]
  in
  List.iter
    (fun (name, f) ->
      let per = Array.init runs (fun _ -> round f) in
      Stats.print (Printf.sprintf "write: %s, a group" name) per)
    cases;
  close db

let declare_within dir =
  let db = ok (open_ dir) in
  let v = view db in
  let p n = Option.get (property v n) in
  ok (within db [ (p "invoice/date", p "invoice/client") ]);
  let t = Unix.gettimeofday () in
  ok (snapshot db);
  Printf.printf "declared, merged in %.1f ms\n" (1000. *. (Unix.gettimeofday () -. t));
  close db

let merge dir =
  Engine.compact_min := max_int;
  let db = ok (open_ dir) in
  let v = view db in
  let p n = Option.get (property v n) in
  let client = p "invoice/client" and total = p "invoice/total" and date = p "invoice/date" in
  let c = let r = ref 0 in Store.iter_prop v client (fun _ x -> r := x); !r in
  for k = 1 to 100 do ignore (ok (write db [ Resolve.Add (-1, client, Link c); Add (-1, total, Money k); Add (-1, date, Date (1_483_228_800_000 + k)) ])) done;
  let t = Unix.gettimeofday () in
  ok (snapshot db);
  let d = Unix.gettimeofday () -. t in
  Stats.print "the merge of every run and the delta (snapshot)" [| d |];
  close db;
  let sd = Filename.concat dir "snapshots" in
  Array.iter (fun n -> if Filename.check_suffix n ".run" then Printf.printf "file %s %d bytes\n" n (Unix.stat (Filename.concat sd n)).st_size) (Sys.readdir sd)

let () =
  match Sys.argv with
  | [| _; "run"; dir |] -> run dir
  | [| _; "pair"; dir |] -> pair dir
  | [| _; "writes"; dir |] -> writes dir
  | [| _; "merge"; dir |] -> merge dir
  | [| _; "within"; dir |] -> declare_within dir
  | _ -> prerr_endline "wbench.exe run|pair|writes|within DIR"; exit 2
