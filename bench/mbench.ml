(* Small questions in loops, for an A/B of two builds on one database (bench.exe load's): the fixed cost of a fold, which
   a split's machinery must not raise. The same file compiles against main before the split past a narrow first level,
   so that each side times its own engine. Each question RUNS times (11), each run a loop of calls, its median time a
   call (Stats): a fold of one fact, Prefix, Q3 counted, Not, Optional, a sorted page, a find of every e-mail, Q4's
   fold; CEPHEUS_DOMAINS=n: on n domains at most.

     mbench.exe DIR *)

open Cepheus

let ok = function Ok r -> r | Error e -> failwith (message e)
let runs = match Sys.getenv_opt "RUNS" with Some r -> int_of_string r | None -> 11

let measure name n f =
  let per = Array.init runs (fun _ -> let t = Unix.gettimeofday () in for i = 0 to n - 1 do f i done; (Unix.gettimeofday () -. t) /. float n) in
  Stats.print name per

let () =
  Option.iter (fun d -> Query.domains := int_of_string d) (Sys.getenv_opt "CEPHEUS_DOMAINS");
  let db = ok (open_ Sys.argv.(1)) in
  let v = view db in
  let p n = Option.get (property v n) in
  let cty = p "client/city" and mail = p "client/email" and client = p "invoice/client" and status = p "invoice/status" and total = p "invoice/total"
  and follows = p "client/follows" and name = p "client/name" in
  let rows q = ignore (ok (ask v q)) in
  let c7 = match things v mail (Text "c7@example.com") with [ c ] -> c | _ -> failwith "c7" in
  (* a point fold: one client's name *)
  let point = { Query.vars = 1; ranges = []; where = [ { e = Thing c7; p = name; v = Var 0 } ] } in
  measure "a point fold (a thing's name)" 20_000 (fun _ -> ignore (ok (fold v point ~init:(fun () -> 0) ~step:(fun n _ -> n + 1) ~merge:( + ))));
  (* Prefix *)
  let pre = { Question.vars = 2; items = [ Question.Pattern { e = Var 0; p = mail; v = Var 1 }; Question.Prefix (1, "c1234") ]; give = [| 0; 1 |]; sort = []; limit = 0; after = None } in
  measure "Prefix (ask)" 20_000 (fun _ -> rows pre);
  (* Q3: the unpaid invoices of a city, counted *)
  let q3 k = { Query.vars = 3; ranges = []; where = [ { e = Var 0; p = cty; v = Val (Text (Printf.sprintf "city-%d" (k mod 100))) }; { e = Var 1; p = client; v = Var 0 };
                                                       { e = Var 1; p = status; v = Val (Text "unpaid") }; { e = Var 1; p = total; v = Var 2 } ] } in
  measure "Q3 count (fold)" 300 (fun k -> ignore (ok (fold v (q3 k) ~init:(fun () -> 0) ~step:(fun n _ -> n + 1) ~merge:( + ))));
  (* Not, Optional, a page by the index path *)
  let city = Question.Pattern { e = Var 0; p = cty; v = Val (Text "city-7") } in
  let clear = { Question.vars = 2; items = [ city; Question.Not [ Question.Pattern { e = Var 1; p = client; v = Var 0 }; Question.Pattern { e = Var 1; p = status; v = Val (Text "unpaid") } ] ]; give = [| 0 |]; sort = []; limit = 0; after = None } in
  measure "Not (ask)" 300 (fun _ -> rows clear);
  let fol = { Query.e = Var 0; p = follows; v = Var 1 } in
  let opt = { Question.vars = 2; items = [ city; Question.Optional fol ]; give = [| 0; 1 |]; sort = []; limit = 0; after = None } in
  measure "Optional, city-7 (ask)" 1_000 (fun _ -> rows opt);
  let page = { Question.vars = 2; items = [ Question.Pattern { e = Var 0; p = status; v = Val (Text "unpaid") }; Question.Pattern { e = Var 0; p = total; v = Var 1 } ];
               give = [| 0; 1 |]; sort = [ { Question.col = 1; desc = true } ]; limit = 20; after = None } in
  measure "a page of 20, largest first (ask)" 1_000 (fun _ -> rows page);
  (* a find of every e-mail (11,363 rows of texts), and Q4's fold (the unpaid sum by city, 45,064 invoices) *)
  measure "every e-mail (find)" 20 (fun _ -> ignore (ok (find v { Query.vars = 2; ranges = []; where = [ { e = Var 0; p = mail; v = Var 1 } ] })));
  let q4 = { Query.vars = 4; ranges = [];
             where = [ { e = Var 0; p = status; v = Val (Text "unpaid") }; { e = Var 0; p = client; v = Var 1 }; { e = Var 1; p = cty; v = Var 2 }; { e = Var 0; p = total; v = Var 3 } ] } in
  measure "Q4 sum by city (fold)" 20 (fun _ ->
      ignore (ok (fold v q4 ~init:(fun () -> Hashtbl.create 128)
                    ~step:(fun t env -> let a, n = Option.value (Hashtbl.find_opt t env.(2)) ~default:(0, 0) in Hashtbl.replace t env.(2) (a + env.(3), n + 1); t)
                    ~merge:(fun a b -> Hashtbl.iter (fun c (x, k) -> let y, m = Option.value (Hashtbl.find_opt a c) ~default:(0, 0) in Hashtbl.replace a c (x + y, k + m)) b; a))));
  close db
