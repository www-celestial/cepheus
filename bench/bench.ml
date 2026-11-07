(* Benchmarks, the Cepheus side. One seeded generator makes the data for both sides: groups for Cepheus, CSV files
   for PostgreSQL's COPY. Method and results: docs/benchmarks.md.

     bench.exe load DIR CSVDIR FACTS   Cepheus through its writer (64 clients, one group per client and its 20
                                       invoices, then the follow links), a snapshot, and the CSV files
     bench.exe read DIR FACTS          open (restart time), then Q1-Q5: min and median of 5 rounds
     bench.exe write DIR CLIENTS SECS  durable writes of a new invoice (4 facts) with CLIENTS threads *)

open Cepheus

let now = Unix.gettimeofday
let follows_per_client = 5
let facts_per_client = 3 + follows_per_client + 80
let statuses = [| "paid"; "paid"; "paid"; "paid"; "paid"; "paid"; "paid"; "unpaid"; "unpaid"; "late" |]
let email k = Printf.sprintf "c%d@example.com" k

type schema = { name : int; cty : int; mail : int; follows : int; client : int; total : int; status : int; date : int }

let props =
  [ prop "client/name" Ttext; prop "client/city" Ttext; prop ~unique:true "client/email" Ttext;
    prop ~many:true "client/follows" Tlink; prop "invoice/client" Tlink; prop "invoice/total" (Tmoney 2);
    prop "invoice/status" Ttext; prop "invoice/date" Tdate ]

let schema_of v =
  let p n = Option.get (property v n) in
  { name = p "client/name"; cty = p "client/city"; mail = p "client/email"; follows = p "client/follows";
    client = p "invoice/client"; total = p "invoice/total"; status = p "invoice/status"; date = p "invoice/date" }

let schema db =
  match declare db props with
  | Ok [ name; cty; mail; follows; client; total; status; date ] -> { name; cty; mail; follows; client; total; status; date }
  | Ok _ -> assert false
  | Error e -> failwith (message e)

(* client k: its city, the clients it follows, its 20 invoices (total in cents, status, day); seeded by k *)
let client_data nclients k =
  let r = Rng.make ((k * 7919) + 1) in
  let c = Printf.sprintf "city-%d" (Rng.int r 100) in
  let fol = List.init follows_per_client (fun _ -> Rng.int r nclients) |> List.sort_uniq compare |> List.filter (( <> ) k) in
  let inv = List.init 20 (fun _ -> 1 + Rng.int r 100_000, statuses.(Rng.int r 10), Rng.int r 3650) in
  c, fol, inv

let parallel n f =
  let next = Atomic.make 0 in
  let worker () =
    let go = ref true in
    while !go do
      let k = Atomic.fetch_and_add next 1 in
      if k >= n then go := false else f k
    done
  in
  List.iter Thread.join (List.init 64 (fun _ -> Thread.create worker ()))

let ok = function Ok r -> r | Error e -> failwith (message e)

let load dir csv facts =
  let nclients = facts / facts_per_client in
  let db = ok (open_ dir) in
  let s = schema db in
  let cid = Array.make nclients 0 in
  let t0 = now () in
  parallel nclients (fun k ->
      let c, _, inv = client_data nclients k in
      let ops =
        [ Add (-1, s.name, Text (Printf.sprintf "client-%d" k)); Add (-1, s.cty, Text c); Add (-1, s.mail, Text (email k)) ]
        @ List.concat
            (List.mapi
               (fun j (total, st, d) ->
                 let i = -(j + 2) in
                 [ Add (i, s.client, Link (-1)); Add (i, s.total, Money total); Add (i, s.status, Text st); Add (i, s.date, Date d) ])
               inv)
      in
      cid.(k) <- thing (ok (write db ~by:1 ~why:"load" ops)) (-1));
  parallel nclients (fun k ->
      let _, fol, _ = client_data nclients k in
      ignore (ok (write db ~by:1 ~why:"follows" (List.map (fun f -> Add (cid.(k), s.follows, Link cid.(f))) fol))));
  let t1 = now () in
  ok (snapshot db);
  let t2 = now () in
  let v = view db in
  Printf.printf "cepheus load: %d clients, %d facts, %.1f s through the writer (%.0f facts/s), snapshot %.2f s\n%!"
    nclients (Store.facts v) (t1 -. t0) (float (Store.facts v) /. (t1 -. t0)) (t2 -. t1);
  close db;
  (* the same data for PostgreSQL *)
  let oc n = open_out (Filename.concat csv n) in
  let cl = oc "client.csv" and iv = oc "invoice.csv" and fo = oc "follows.csv" in
  for k = 0 to nclients - 1 do
    let c, fol, inv = client_data nclients k in
    Printf.fprintf cl "%d,client-%d,%s,%s\n" k k c (email k);
    List.iter (fun f -> Printf.fprintf fo "%d,%d\n" k f) fol;
    List.iteri (fun j (total, st, d) -> Printf.fprintf iv "%d,%d,%d,%s,%d\n" ((k * 20) + j) k total st d) inv
  done;
  List.iter close_out [ cl; iv; fo ]

(* ---- reads ---- *)

let rounds = 5

let measure name n f =
  let per = Array.init rounds (fun _ ->
      let t = now () in
      for i = 0 to n - 1 do f i done;
      (now () -. t) /. float n) in
  Array.sort compare per;
  let unit x = if x < 1e-3 then Printf.sprintf "%.2f us" (x *. 1e6) else Printf.sprintf "%.2f ms" (x *. 1e3) in
  Printf.printf "%-34s min %s  median %s\n%!" name (unit per.(0)) (unit per.(rounds / 2))

let rss () =
  let ic = open_in "/proc/self/status" in
  let r = ref 0 in
  (try while true do let l = input_line ic in if String.length l > 6 && String.sub l 0 6 = "VmRSS:" then Scanf.sscanf l "VmRSS: %d" (fun k -> r := k) done
   with End_of_file -> ());
  close_in ic;
  !r

let read dir facts =
  (match Sys.getenv_opt "CEPHEUS_DOMAINS" with Some d -> Query.domains := int_of_string d | None -> ());
  Printf.printf "questions on up to %d domains\n" !Query.domains;
  let nclients = facts / facts_per_client in
  let t0 = now () in
  let db = ok (open_ dir) in
  let t1 = now () in
  let v = view db in
  Printf.printf "open (restart from the snapshot): %.1f ms, %d facts, RSS %d MB\n%!" ((t1 -. t0) *. 1e3) (Store.facts v) (rss () / 1024);
  let s = schema_of v in
  let r = Rng.make 9 in
  let sample = Array.init 4096 (fun _ -> Rng.int r nclients) in
  let cids = Array.map (fun k -> match things v s.mail (Text (email k)) with [ e ] -> e | _ -> failwith "email") sample in
  (* Q1: all the facts of an invoice (a client's id + 1 + j) *)
  measure "Q1 an invoice by id" 200_000 (fun i -> ignore (get v (cids.(i land 4095) + 1 + (i mod 20))));
  measure "Q2 a client by e-mail" 200_000 (fun i -> ignore (things v s.mail (Text (email sample.(i land 4095)))));
  let q3 city =
    { vars = 3; ranges = [];
      where = [ { e = Var 0; p = s.cty; v = Val (Text city) }; { e = Var 1; p = s.client; v = Var 0 };
                { e = Var 1; p = s.status; v = Val (Text "unpaid") }; { e = Var 1; p = s.total; v = Var 2 } ] }
  in
  let n3 = List.length (ok (find v (q3 "city-7"))) in
  measure (Printf.sprintf "Q3 unpaid of a city (%d rows)" n3) 200 (fun i ->
      ignore (fold v (q3 (Printf.sprintf "city-%d" (i mod 100))) ~init:(fun () -> 0) ~step:(fun n _ -> n + 1) ~merge:( + )));
  let q4 =
    { vars = 4; ranges = [];
      where = [ { e = Var 0; p = s.status; v = Val (Text "unpaid") }; { e = Var 0; p = s.client; v = Var 1 };
                { e = Var 1; p = s.cty; v = Var 2 }; { e = Var 0; p = s.total; v = Var 3 } ] }
  in
  (* per domain: a table city -> (sum, count); merged at the end *)
  let q4run () =
    ok (fold v q4 ~init:(fun () -> Hashtbl.create 128)
          ~step:(fun t env ->
              let a, n = Option.value (Hashtbl.find_opt t env.(2)) ~default:(0, 0) in
              Hashtbl.replace t env.(2) (a + env.(3), n + 1);
              t)
          ~merge:(fun a b ->
              Hashtbl.iter (fun c (x, k) -> let y, m = Option.value (Hashtbl.find_opt a c) ~default:(0, 0) in Hashtbl.replace a c (x + y, k + m)) b;
              a))
  in
  let sums = q4run () in
  let total = Hashtbl.fold (fun _ (a, _) acc -> acc + a) sums 0 and cnt = Hashtbl.fold (fun _ (_, n) acc -> acc + n) sums 0 in
  measure (Printf.sprintf "Q4 unpaid sum by city (%d inv, %d)" cnt total) 5 (fun _ -> q4run ());
  let q5 =
    { vars = 3; ranges = [];
      where = [ { e = Var 0; p = s.follows; v = Var 1 }; { e = Var 1; p = s.follows; v = Var 2 }; { e = Var 2; p = s.follows; v = Var 0 } ] }
  in
  let tri = ok (fold v q5 ~init:(fun () -> 0) ~step:(fun n _ -> n + 1) ~merge:( + )) in
  measure (Printf.sprintf "Q5 triangles (%d rotations)" tri) 3 (fun _ -> ignore (fold v q5 ~init:(fun () -> 0) ~step:(fun n _ -> n + 1) ~merge:( + )));
  close db

(* ---- durable writes ---- *)

let write_bench dir clients secs =
  let db = ok (open_ dir) in
  let s = schema_of (view db) in
  let v = view db in
  let some_client = match things v s.mail (Text (email 0)) with [ e ] -> e | _ -> failwith "no client 0" in
  let stop = Atomic.make false in
  let lat = Array.make clients [] and cnt = Array.make clients 0 in
  let worker c () =
    let r = Rng.make c in
    while not (Atomic.get stop) do
      let t = now () in
      ignore (ok (write db ~by:c ~why:"invoice"
                    [ Add (-1, s.client, Link some_client); Add (-1, s.total, Money (Rng.int r 100000)); Add (-1, s.status, Text "unpaid");
                      Add (-1, s.date, Date (Rng.int r 3650)) ]));
      if cnt.(c) land 15 = 0 then lat.(c) <- (now () -. t) :: lat.(c);
      cnt.(c) <- cnt.(c) + 1
    done
  in
  let t0 = now () in
  let ts = List.init clients (fun c -> Thread.create (worker c) ()) in
  Unix.sleepf secs;
  Atomic.set stop true;
  List.iter Thread.join ts;
  let dt = now () -. t0 in
  let n = Array.fold_left ( + ) 0 cnt in
  let l = Array.of_list (List.sort compare (List.concat (Array.to_list lat))) in
  let pct p = 1000. *. l.(min (Array.length l - 1) (int_of_float (p *. float (Array.length l)))) in
  Printf.printf "W1 %3d clients: %7.0f durable groups/s, latency median %.1f ms, p99 %.1f ms, %.1f groups a frame\n%!" clients
    (float n /. dt) (pct 0.5) (pct 0.99) (float n /. float (max 1 (Atomic.get Engine.frames)));
  close db

(* the writer's work alone, without the disk: the same groups into a fork *)
let cpu dir n =
  let db = ok (open_ dir) in
  let s = schema_of (view db) in
  let c0 = match things (view db) s.mail (Text (email 0)) with [ e ] -> e | _ -> failwith "no client 0" in
  let f = fork (view db) in
  let t = now () in
  for i = 1 to n do
    ignore (ok (write f [ Add (-1, s.client, Link c0); Add (-1, s.total, Money i); Add (-1, s.status, Text "unpaid");
                          Add (-1, s.date, Date (i mod 3650)); Add (-1, s.status, Text "unpaid") ]))
  done;
  let dt = now () -. t in
  Printf.printf "writer work alone: %.1f us a group (%.0f groups/s), delta %d changes\n" (dt /. float n *. 1e6) (float n /. dt) (view f).delta.dn;
  close db

let () =
  match Sys.argv with
  | [| _; "cpu"; dir; n |] -> cpu dir (int_of_string n)
  | [| _; "load"; dir; csv; facts |] -> load dir csv (int_of_string facts)
  | [| _; "read"; dir; facts |] -> read dir (int_of_string facts)
  | [| _; "write"; dir; clients; secs |] -> write_bench dir (int_of_string clients) (float_of_string secs)
  | _ -> prerr_endline "bench.exe load DIR CSVDIR FACTS | read DIR FACTS | write DIR CLIENTS SECS"; exit 2
