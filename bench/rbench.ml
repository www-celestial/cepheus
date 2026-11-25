(* Reports (protocol 9) beside PostgreSQL's aggregates: the data, and each aggregate over 1 million facts with 1, 100
   and 10,000 groups, as the server answers them (Answer: the engine alone, no socket).

     rbench.exe load DIR CSV    10,000 clients (a city of 100 each) and 245,000 invoices (a client, a total of 0.01 to
                                1,000.00, a status, a date over 2017 to 2026): 1,000,000 facts; the same rows as CSV
                                for PostgreSQL (bench/pg/pg.sh reports)
     rbench.exe run DIR         each question RUNS times (21), its median and interval (Stats); a line a question;
                                CEPHEUS_DOMAINS=n: on n domains at most

   The questions: every invoice (1 group), by its client's city (100), by its client (10,000); each with Sum (the
   aggregate of before), Avg, Count of the different statuses, Values of the statuses, the median total, Stddev; and
   the totals by month in Paris (Trunc, 120 groups). *)

open Cepheus
open Cepheus_server

let ok = function Ok r -> r | Error e -> failwith (message e)
let nclients = 10_000
let ninvoices = 245_000
let statuses = [| "paid"; "paid"; "paid"; "paid"; "paid"; "paid"; "paid"; "unpaid"; "unpaid"; "late" |]

(* 2017-01-01 and 2027-01-01, in seconds *)
let t0 = 1_483_228_800 and t1 = 1_798_761_600

let props = [ prop "client/city" Ttext; prop "invoice/client" Tlink; prop "invoice/total" (Tmoney 2); prop "invoice/status" Ttext; prop "invoice/date" Tdate ]

let load dir csv =
  let db = ok (open_ dir) in
  let[@warning "-8"] (Ok [ city; client; total; status; date ]) = declare db props in
  let r = Rng.make 2026 in
  let cities = Array.init nclients (fun _ -> Rng.int r 100) in
  let ids = Array.make nclients 0 in
  let chunk = 2_000 in
  let k = ref 0 in
  while !k < nclients do
    let n = min chunk (nclients - !k) in
    let rc = ok (write db (List.init n (fun j -> Resolve.Add (-1 - j, city, Text (Printf.sprintf "city-%d" cities.(!k + j)))))) in
    List.iter (fun (t, e) -> ids.(!k + (-1 - t)) <- e) rc.things;
    k := !k + n
  done;
  let oc = open_out (Filename.concat csv "rclient.csv") in
  Array.iteri (fun i c -> Printf.fprintf oc "%d,city-%d\n" (i + 1) c) cities;
  close_out oc;
  let oc = open_out (Filename.concat csv "rinvoice.csv") in
  let chunk = 10_000 in
  let k = ref 0 in
  while !k < ninvoices do
    let n = min chunk (ninvoices - !k) in
    let ops =
      List.concat
        (List.init n (fun j ->
             let c = Rng.int r nclients and t = 1 + Rng.int r 100_000 and s = statuses.(Rng.int r 10) and d = t0 + Rng.int r (t1 - t0) in
             Printf.fprintf oc "%d,%d,%d,%s,%d\n" (!k + j + 1) (c + 1) t s d;
             let i = -1 - j in
             [ Resolve.Add (i, client, Link ids.(c)); Add (i, total, Money t); Add (i, status, Text s); Add (i, date, Date (d * 1000)) ]))
    in
    ignore (ok (write db ops));
    k := !k + n
  done;
  close_out oc;
  ok (snapshot db);
  close db;
  Printf.printf "loaded %d clients and %d invoices: %d facts\n" nclients ninvoices ((nclients * 1) + (ninvoices * 4))

let runs = match Sys.getenv_opt "RUNS" with Some r -> int_of_string r | None -> 21

let measure name f =
  let rows = ref 0 in
  let per = Array.init runs (fun _ -> let t = Unix.gettimeofday () in rows := f (); Unix.gettimeofday () -. t) in
  Stats.print (Printf.sprintf "%s (%d rows)" name !rows) per

let run dir =
  (* CEPHEUS_DOMAINS=n: a question on n domains at most (the engine's default: the machine's, at most 8) *)
  Option.iter (fun d -> Query.domains := int_of_string d) (Sys.getenv_opt "CEPHEUS_DOMAINS");
  let db = ok (open_ dir) in
  let v = view db in
  let p n = Option.get (property v n) in
  let city = p "client/city" and client = p "invoice/client" and total = p "invoice/total" and status = p "invoice/status" and date = p "invoice/date" in
  (* each question with the patterns it needs, as PostgreSQL's reads the columns it needs: the invoice 0, its total 1,
     then its status, its client, the client's city as the aggregate and the grouping ask *)
  let ask ~withstatus ~grouping (mk : int -> Wire.agg) =
    let n = ref 2 in
    let fresh () = let x = !n in incr n; x in
    let pats = ref [ { Query.e = Var 0; p = total; v = Var 1 } ] in
    let st = if withstatus then (let x = fresh () in pats := !pats @ [ { e = Var 0; p = status; v = Var x } ]; x) else -1 in
    let keys =
      match grouping with
      | `One -> [||]
      | `Client -> let c = fresh () in pats := !pats @ [ { e = Var 0; p = client; v = Var c } ]; [| c |]
      | `City ->
        let c = fresh () in
        let y = fresh () in
        pats := !pats @ [ { e = Var 0; p = client; v = Var c }; { e = Var c; p = city; v = Var y } ];
        [| y |]
    in
    let q = { Query.vars = !n; where = !pats; ranges = [] } in
    fun () -> (Answer.answer v q (Wire.Group (keys, [| mk (if withstatus then st else 1) |]))).n
  in
  let aggs =
    [ "Sum", false, (fun x -> Wire.Sum x); "Avg", false, (fun x -> Wire.Avg x); "Count(status)", true, (fun x -> Wire.Distinct x);
      "Values(status)", true, (fun x -> Wire.Values x); "Median", false, (fun x -> Wire.Quantile (x, 0.5, false)); "Stddev", false, (fun x -> Wire.Stddev (x, false)) ]
  in
  List.iter
    (fun (gname, grouping) ->
      List.iter (fun (aname, withstatus, mk) -> measure (Printf.sprintf "%s %s" aname gname) (ask ~withstatus ~grouping mk)) aggs)
    [ "1 group", `One; "100 groups (city)", `City; "10,000 groups (client)", `Client ];
  (* by month in Paris: Trunc of the date, variable 5 of a question of 5 *)
  let qd = { Query.vars = 3; where = [ { e = Var 0; p = total; v = Var 1 }; { e = Var 0; p = date; v = Var 2 } ]; ranges = [] } in
  let by zone = (Answer.answer ~extra:[ Question.Ask.Trunc (3, 2, "month", zone) ] v qd (Wire.Group ([| 3 |], [| Wire.Sum 1 |]))).n in
  measure "Sum by month in Paris (Trunc)" (fun () -> by "Europe/Paris");
  measure "Sum by month in UTC (Trunc)" (fun () -> by "UTC");
  close db

let () =
  match Sys.argv with
  | [| _; "load"; dir; csv |] -> load dir csv
  | [| _; "run"; dir |] -> run dir
  | _ -> prerr_endline "rbench.exe load DIR CSV | run DIR"; exit 2
