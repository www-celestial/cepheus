(* The questions of before reports, for an A/B of two builds on one database (rbench.exe load's): the same file
   compiles against a build without protocol 9, so that each side times its own engine. Each question RUNS times (21),
   its median and interval (Stats): Give of a join, the groups of Sum, Count, Min and Max (100 and 10,000), a sorted
   page, Not, Less, Optional.

     abench.exe DIR *)

open Cepheus
open Cepheus_server
module Ask = Question.Ask
module Top = Question.Top

let ok = function Ok r -> r | Error e -> failwith (message e)
let runs = match Sys.getenv_opt "RUNS" with Some r -> int_of_string r | None -> 21

let measure name f =
  let rows = ref 0 in
  let per = Array.init runs (fun _ -> let t = Unix.gettimeofday () in rows := f (); Unix.gettimeofday () -. t) in
  Stats.print (Printf.sprintf "%s (%d rows)" name !rows) per

let () =
  let dir = Sys.argv.(1) in
  let db = ok (open_ dir) in
  let v = view db in
  let p n = Option.get (property v n) in
  let city = p "client/city" and client = p "invoice/client" and total = p "invoice/total" and status = p "invoice/status" in
  let inv = [ { Query.e = Var 0; p = client; v = Var 1 }; { e = Var 0; p = total; v = Var 2 }; { e = Var 0; p = status; v = Var 3 } ] in
  let bycity = { Query.vars = 5; where = inv @ [ { e = Var 1; p = city; v = Var 4 } ]; ranges = [] } in
  let unpaid7 = { Query.vars = 3; where = [ { e = Var 1; p = city; v = Val (Text "city-7") }; { e = Var 0; p = client; v = Var 1 }; { e = Var 0; p = status; v = Val (Text "unpaid") }; { e = Var 0; p = total; v = Var 2 } ]; ranges = [] } in
  let a ?(order = Top.none) ?(extra = []) q sel = (Answer.answer ~order ~extra v q sel).n in
  measure "Give: the unpaid invoices of city-7" (fun () -> a unpaid7 (Wire.Give [| 0; 2 |]));
  measure "Sum, Count by city (100 groups)" (fun () -> a bycity (Wire.Group ([| 4 |], [| Wire.Sum 2; Count |])));
  measure "Min, Max by client (10,000 groups)" (fun () -> a { bycity with vars = 4; where = inv } (Wire.Group ([| 1 |], [| Wire.Min 2; Max 2 |])));
  measure "Sum by city, sorted" (fun () -> a ~order:{ Top.keys = [ { col = 1; desc = true } ]; limit = 10; after = None } bycity (Wire.Group ([| 4 |], [| Wire.Sum 2 |])));
  measure "a page of 20 unpaid, largest first" (fun () ->
      a ~order:{ Top.keys = [ { col = 1; desc = true } ]; limit = 20; after = None }
        { Query.vars = 2; where = [ { e = Var 0; p = status; v = Val (Text "unpaid") }; { e = Var 0; p = total; v = Var 1 } ]; ranges = [] } (Wire.Give [| 0; 1 |]));
  measure "Not: clients of city-7 with no late invoice" (fun () ->
      a ~extra:[ Ask.Not [ Ask.Pattern { e = Var 1; p = client; v = Var 0 }; Ask.Pattern { e = Var 1; p = status; v = Val (Text "late") } ] ]
        { Query.vars = 2; where = [ { e = Var 0; p = city; v = Val (Text "city-7") } ]; ranges = [] } (Wire.Give [| 0 |]));
  measure "Less: invoices of city-7 below 5.00" (fun () ->
      a { unpaid7 with ranges = [ (2, Value.Money 0, Value.Money 500) ] } (Wire.Give [| 0 |]));
  measure "Optional: invoices of city-7 and their status" (fun () ->
      a ~extra:[ Ask.Optional { e = Var 0; p = status; v = Var 3 } ]
        { Query.vars = 4; where = [ { e = Var 1; p = city; v = Val (Text "city-7") }; { e = Var 0; p = client; v = Var 1 }; { e = Var 0; p = total; v = Var 2 } ]; ranges = [] } (Wire.Give [| 0; 3 |]));
  close db
