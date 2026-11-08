(* Benchmarks of the server, the client's side: requests over the Unix socket or TCP to a running `cepheus serve`, on
   a database made by `bench.exe load` (method and results: docs/benchmarks.md, the server's section). Each command
   prints one number a run: microseconds a request, or groups a second.

     sbench.exe ping ADDR N                  N empty round trips (Ping), one in flight
     sbench.exe get ADDR FACTS DEPTH N       N point reads (Get of an invoice: its 4 facts), DEPTH in flight
     sbench.exe clients ADDR FACTS C N       C processes, a connection each, N reads each, one in flight: wall time a read
     sbench.exe write ADDR FACTS C SECS      C connections (threads), durable writes of a new invoice (4 facts): groups/s,
                                             and the latencies
     sbench.exe q ADDR FACTS Q3|Q4 N         N runs of a question through Find: Q3 the unpaid invoices of a city (rows),
                                             Q4 the unpaid sum and count by city (aggregates in the server)
     sbench.exe check ADDR FACTS             invoices of the sample as `index client total status date` lines, to compare
                                             with PostgreSQL's rows

   ADDR is a socket path or host:port; the token is CEPHEUS_TOKEN. *)

open Cepheus
open Cepheus_server

let now = Unix.gettimeofday
let token () = match Sys.getenv_opt "CEPHEUS_TOKEN" with Some t -> t | None -> failwith "CEPHEUS_TOKEN"
let facts_per_client = 88
let ok = function Ok x -> x | Error (e : Client.error) -> failwith (e.code ^ ": " ^ e.message)

(* TCP is TLS: the cluster's CA in CEPHEUS_CA *)
let connect addr =
  match Client.connect ~program:"sbench" ?ca:(Sys.getenv_opt "CEPHEUS_CA") (Client.address_of_string addr) (token ()) with
  | Ok c -> c
  | Error m -> failwith m

type setup = { c : Client.t; db : Client.db; cids : int array; sample : int array; p : string -> int }

(* the sample of bench.exe's questions: 4,096 clients drawn with the seed 9, their ids by their e-mail *)
let setup addr facts =
  let c = connect addr in
  let db = ok (Client.open_db c "main") in
  let p n = match Client.prop db n with Some p -> p | None -> failwith ("no property " ^ n) in
  let nclients = facts / facts_per_client in
  let r = Rng.make 9 in
  let sample = Array.init 4096 (fun _ -> Rng.int r nclients) in
  let mail = p "client/email" in
  let cids =
    Array.map
      (fun k ->
        let q = { Query.vars = 1; where = [ { Query.e = Var 0; p = mail; v = Val (Text (Printf.sprintf "c%d@example.com" k)) } ]; ranges = [] } in
        match ok (Client.find c db q) with _, [ [| Value.Link e |] ] -> e | _ -> failwith "email")
      sample
  in
  { c; db; cids; sample; p }

(* the invoice of read i, as bench.exe's Q1: client i mod 4096, its invoice i mod 20 *)
let invoice s i = s.cids.(i land 4095) + 1 + (i mod 20)

(* raw frames: requests coded once into a buffer, replies decoded as a client must; through the client's socket or
   its TLS *)
type raw = { c : Client.t; buf : Bytes.t; mutable have : int; out : Buffer.t; body : Buffer.t }

let raw (c : Client.t) = { c; buf = Bytes.create (1 lsl 20); have = 0; out = Buffer.create 65536; body = Buffer.create 64 }

let queue r id req =
  Buffer.clear r.body;
  Wire.put_request r.body req;
  Wire.add_frame r.out ~id ~kind:(Wire.request_kind req) ~flags:0 r.body

let send r =
  let b = Buffer.to_bytes r.out in
  Buffer.clear r.out;
  Client.io_write r.c b 0 (Bytes.length b)

(* reads until [want] replies have come; each decoded *)
let replies r want =
  let got = ref 0 and facts = ref 0 in
  while !got < want do
    let o = ref 0 in
    while !got < want && r.have - !o >= 4 && r.have - !o >= 4 + Wire.u32 r.buf !o do
      let len = Wire.u32 r.buf !o in
      (match Wire.get_reply (Bytes.get_uint8 r.buf (!o + 8)) (Bytes.get_uint8 r.buf (!o + 9)) (Codec.reader r.buf (!o + Wire.header) (len - 6)) with
       | Wire.Facts f -> facts := !facts + List.length f.facts
       | Wire.Pong _ -> ()
       | Wire.Err e -> failwith (e.code ^ ": " ^ e.message)
       | _ -> ());
      incr got;
      o := !o + 4 + len
    done;
    Bytes.blit r.buf !o r.buf 0 (r.have - !o);
    r.have <- r.have - !o;
    if !got < want then begin
      let k = Client.io_read r.c r.buf r.have (Bytes.length r.buf - r.have) in
      if k = 0 then failwith "the server closed";
      r.have <- r.have + k
    end
  done;
  !facts

(* N requests, DEPTH in flight: microseconds a request *)
let loop r depth n make =
  let warm = min n 1000 in
  for i = 0 to warm - 1 do queue r i (make i) done;
  send r;
  ignore (replies r warm);
  let t0 = now () in
  let sent = ref 0 and done_ = ref 0 in
  let refill () =
    let k = min (n - !sent) (depth - (!sent - !done_)) in
    for _ = 1 to k do queue r !sent (make !sent); incr sent done;
    if k > 0 then send r
  in
  refill ();
  while !done_ < n do
    ignore (replies r 1);
    incr done_;
    refill ()
  done;
  (now () -. t0) /. float n *. 1e6

let ping addr n =
  let c = connect addr in
  let r = raw c in
  Printf.printf "%.3f\n%!" (loop r 1 n (fun _ -> Wire.Ping "0123456789abcdef"))

let get addr facts depth n =
  let s = setup addr facts in
  let r = raw s.c in
  Printf.printf "%.3f\n%!" (loop r depth n (fun i -> Wire.Get { db = s.db.handle; thing = invoice s i }))

(* C connections, one request in flight each: min(C, 8) processes (as pgbench -j 8), each with C / 8 threads, each
   thread its connection; everything set up before a common start: the wall time of all the reads *)
let clients addr facts nconn n =
  let nproc = min nconn 8 in
  let per = nconn / nproc in
  let go_r, go_w = Unix.pipe () in
  let ready_r, ready_w = Unix.pipe () in
  let pids =
    List.init nproc (fun k ->
        match Unix.fork () with
        | 0 ->
          let s = setup addr facts in
          let conns = Array.init per (fun j -> if j = 0 then s.c else connect addr) in
          let raws = Array.map raw conns in
          ignore (Unix.write_substring ready_w "r" 0 1);
          let b = Bytes.create 1 in
          ignore (Unix.read go_r b 0 1);
          let run j () = ignore (loop raws.(j) 1 n (fun i -> Wire.Get { db = s.db.handle; thing = invoice s (i + (((k * per) + j) * 7919)) })) in
          if per = 1 then run 0 () else List.iter Thread.join (List.init per (fun j -> Thread.create (run j) ()));
          exit 0
        | pid -> pid)
  in
  let b = Bytes.create 1 in
  for _ = 1 to nproc do ignore (Unix.read ready_r b 0 1) done;
  let t0 = now () in
  ignore (Unix.write_substring go_w (String.make nproc 'g') 0 nproc);
  List.iter (fun pid -> ignore (Unix.waitpid [] pid)) pids;
  let dt = now () -. t0 in
  (* every request in the wall time: the warm-up's too *)
  Printf.printf "%.3f\n%!" (dt /. float (nproc * per * (n + min n 1000)) *. 1e6)

let write addr facts nclients secs =
  let s = setup addr facts in
  let some_client = s.cids.(0) in
  let pc = s.p "invoice/client" and pt = s.p "invoice/total" and ps = s.p "invoice/status" and pd = s.p "invoice/date" in
  let stop = Atomic.make false in
  let hist = Array.init nclients (fun _ -> Histogram.create ()) and cnt = Array.make nclients 0 in
  let worker k () =
    let c = connect addr in
    let r = Rng.make k in
    while not (Atomic.get stop) do
      let t = now () in
      ignore (ok (Client.write c s.db ~by:k ~why:"invoice"
                    [ Resolve.Add (-1, pc, Link some_client); Add (-1, pt, Money (Rng.int r 100000)); Add (-1, ps, Text "unpaid");
                      Add (-1, pd, Date (Rng.int r 3650)) ]));
      Histogram.record hist.(k) (int_of_float ((now () -. t) *. 1e6));
      cnt.(k) <- cnt.(k) + 1
    done;
    Client.close c
  in
  let t0 = now () in
  let ts = List.init nclients (fun k -> Thread.create (worker k) ()) in
  Unix.sleepf secs;
  Atomic.set stop true;
  List.iter Thread.join ts;
  let dt = now () -. t0 in
  let n = Array.fold_left ( + ) 0 cnt in
  let h = Histogram.create () in
  Array.iter (Histogram.merge_into h) hist;
  Printf.printf "%.1f groups/s p50 %.2f p99 %.2f ms\n%!" (float n /. dt) (float (Histogram.percentile h 0.5) /. 1e3)
    (float (Histogram.percentile h 0.99) /. 1e3)

let question addr facts which n =
  let s = setup addr facts in
  let p = s.p in
  let q3 city =
    { Query.vars = 3; ranges = [];
      where = [ { e = Var 0; p = p "client/city"; v = Val (Text city) }; { e = Var 1; p = p "invoice/client"; v = Var 0 };
                { e = Var 1; p = p "invoice/status"; v = Val (Text "unpaid") }; { e = Var 1; p = p "invoice/total"; v = Var 2 } ] }
  in
  let q4 =
    { Query.vars = 4; ranges = [];
      where = [ { e = Var 0; p = p "invoice/status"; v = Val (Text "unpaid") }; { e = Var 0; p = p "invoice/client"; v = Var 1 };
                { e = Var 1; p = p "client/city"; v = Var 2 }; { e = Var 0; p = p "invoice/total"; v = Var 3 } ] }
  in
  let run i =
    match which with
    | "Q3" -> List.length (snd (ok (Client.find s.c s.db ~select:(Wire.Give [| 1; 2 |]) (q3 (Printf.sprintf "city-%d" (i mod 100))))))
    | _ -> List.length (snd (ok (Client.find s.c s.db ~select:(Wire.Group ([| 2 |], [| Wire.Sum 3; Wire.Count |])) q4)))
  in
  (match which with
   | "Q3" -> Printf.eprintf "Q3 rows city-7: %d\n%!" (run 7)
   | _ ->
     let _, rows = ok (Client.find s.c s.db ~select:(Wire.Group ([||], [| Wire.Count; Wire.Sum 3 |])) q4) in
     (match rows with [ [| Value.Int n; Value.Money t |] ] -> Printf.eprintf "Q4 count, sum: %d %d\n%!" n t | _ -> ()));
  ignore (run 0);
  let t0 = now () in
  for i = 1 to n do ignore (run i) done;
  Printf.printf "%.3f\n%!" ((now () -. t0) /. float n *. 1e6)

(* N new connections, each its handshake (TLS on TCP) and Hello, then closed: microseconds a connection *)
let hs addr n =
  let t0 = now () in
  for _ = 1 to n do Client.close (connect addr) done;
  Printf.printf "%.3f\n%!" ((now () -. t0) /. float n *. 1e6)

let check addr facts =
  let s = setup addr facts in
  let pc = s.p "invoice/client" and pt = s.p "invoice/total" and ps = s.p "invoice/status" and pd = s.p "invoice/date" in
  (* the client's index by its id: the sample's *)
  let index = Hashtbl.create 4096 in
  Array.iteri (fun i k -> Hashtbl.replace index s.cids.(i) k) s.sample;
  for i = 0 to 99 do
    let _, facts = ok (Client.get s.c s.db (invoice s i)) in
    let f p = List.assoc p facts in
    let k = s.sample.(i land 4095) in
    match f pc, f pt, f ps, f pd with
    | Value.Link cl, Value.Money t, Value.Text st, Value.Date d ->
      Printf.printf "%d %d %d %s %d\n" ((k * 20) + (i mod 20)) (Hashtbl.find index cl) t st d
    | _ -> failwith "an invoice"
  done

let () =
  match Sys.argv with
  | [| _; "ping"; a; n |] -> ping a (int_of_string n)
  | [| _; "get"; a; f; d; n |] -> get a (int_of_string f) (int_of_string d) (int_of_string n)
  | [| _; "clients"; a; f; c; n |] -> clients a (int_of_string f) (int_of_string c) (int_of_string n)
  | [| _; "write"; a; f; c; secs |] -> write a (int_of_string f) (int_of_string c) (float_of_string secs)
  | [| _; "q"; a; f; q; n |] -> question a (int_of_string f) q (int_of_string n)
  | [| _; "check"; a; f |] -> check a (int_of_string f)
  | [| _; "hs"; a; n |] -> hs a (int_of_string n)
  | _ -> prerr_endline "sbench.exe ping ADDR N | get ADDR FACTS DEPTH N | clients ADDR FACTS C N | write ADDR FACTS C SECS | q ADDR FACTS Q3|Q4 N | check ADDR FACTS"; exit 2
