(* Benchmarks of the server, the client's side: requests over the Unix socket or TCP to a running `cepheus serve`, on
   a database made by `bench.exe load` (method and results: docs/book/benchmarks.md, the server's section). Each command
   prints one number a run: microseconds a request, or groups a second.

     sbench.exe ping ADDR N                  N empty round trips (Ping), one in flight
     sbench.exe get ADDR FACTS DEPTH N       N point reads (Get of an invoice: its 4 facts), DEPTH in flight
     sbench.exe clients ADDR FACTS C N       C processes, a connection each, N reads each, one in flight: wall time a read
     sbench.exe write ADDR FACTS C SECS [W]  C connections (threads), durable writes of a new invoice (4 facts): groups/s,
                                             and the latencies; with W, while W watches of the written client's unpaid
                                             invoices, each on a connection of its own read by a thread of another
                                             process, get every change (the writers' cost of the watches)
     sbench.exe q ADDR FACTS Q3|Q4 N         N runs of a question through Find: Q3 the unpaid invoices of a city (rows),
                                             Q4 the unpaid sum and count by city (aggregates in the server)
     sbench.exe check ADDR FACTS             invoices of the sample as `index client total status date` lines, to compare
                                             with PostgreSQL's rows
     sbench.exe local ADDR FACTS N           N point reads in this process (the database followed: local reads)
     sbench.exe localq ADDR FACTS Q3|Q4 N    N runs of a question in this process
     sbench.exe ids ADDR FACTS               the 81,920 invoices of the sample, one id a line, in the order of their reads
                                             (invoice i): the reads of bench/get.ce, the Cesia client's, are these
     sbench.exe wlat ADDR FACTS local|remote N   N writes of an unpaid invoice of one client, one after the other, each
                                             seen by a watch of that client's unpaid invoices (in this process's
                                             follower, or at the server over a connection of its own): the write's
                                             time, and the time from its receipt to its change (us, p50 and p99)
     sbench.exe stall ADDR FACTS N SECS S    N watches of one question, each on a connection of its own read by a
                                             thread, and S connections that watch and never read, while one writer
                                             writes groups of 20 invoices for SECS: the changes' times after their
                                             receipts (p50, p99), the share delivered, and the server's memory
                                             (CEPHEUS_PID: VmRSS and VmHWM, kB)
     sbench.exe livecpu DIR SCREENS GROUPS   in this process, a database directory not served (a copy): SCREENS
                                             watches of the unpaid invoices of a client (one client each) and a
                                             dashboard (the unpaid sum and count), then GROUPS random groups: the
                                             hub's time a group (us, p50, p99, mean), beside asking again the screens
                                             a group touches and the dashboard; checked against Find at the end
     sbench.exe follow ADDR FACTS SECS       a local reader for SECS seconds, reading every invoice of the sample once at
                                             the start: its CPU time a second of the period (% of a core), the frames it
                                             applied, its memory (Pss and RSS of /proc/self/smaps_rollup, kB)

     sbench.exe mwrite ADDR D C SECS        D databases d1 .. dD of the server (empty ones), C writers each, one fact a
                                             durable group: groups/s in all and the latencies
     sbench.exe rate ADDR RATE SECS W        RATE groups a second of one fact to main for SECS, over W connections: the
                                             groups/s, the write latency, and (CEPHEUS_ADMIN) the replicas' lag

   The other commands open the database for remote reads (the server answers), even over the Unix socket.

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

(* the sample of bench.exe's questions: 4,096 clients drawn with the seed 9, their ids by their e-mail; [local]: the
   database followed in this process *)
let setup ?(local = false) addr facts =
  let c = connect addr in
  let db = ok (Client.open_db ~local c "main") in
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

let write addr facts nclients secs watchers =
  (* the watches in a process of their own, made before any thread: their reading threads never hold the writers'
     runtime lock; it says when they are ready, and how many changes they got once asked *)
  let child =
    if watchers = 0 then None
    else begin
      let ready_r, ready_w = Unix.pipe () and stop_r, stop_w = Unix.pipe () in
      match Unix.fork () with
      | 0 ->
        Unix.close ready_r;
        Unix.close stop_w;
        let s = setup addr facts in
        let pc = s.p "invoice/client" and pt = s.p "invoice/total" and ps = s.p "invoice/status" in
        let q = { Query.vars = 2; where = [ { Query.e = Var 0; p = pc; v = Val (Link s.cids.(0)) }; { e = Var 0; p = ps; v = Val (Text "unpaid") }; { e = Var 0; p = pt; v = Var 1 } ]; ranges = [] } in
        let changes = Atomic.make 0 in
        for _ = 1 to watchers do
          let c = connect addr in
          let db = ok (Client.open_db ~local:false c "main") in
          let id = Client.watch c db q in
          let rec loop () =
            match Client.next_push c id with
            | Client.Pushed (Wire.Change _) -> Atomic.incr changes; loop ()
            | Client.Pushed _ -> loop ()
            | Client.Ended e -> prerr_endline ("watch ended: " ^ e.code)
            | exception Client.Broken _ -> ()
          in
          ignore (Thread.create loop ())
        done;
        Unix.sleepf 0.5;
        let c0 = Atomic.get changes in
        ignore (Unix.write_substring ready_w "r" 0 1);
        ignore (Unix.read stop_r (Bytes.create 1) 0 1);
        let m = string_of_int (Atomic.get changes - c0) in
        ignore (Unix.write_substring ready_w m 0 (String.length m));
        Unix._exit 0
      | pid ->
        Unix.close ready_w;
        Unix.close stop_r;
        ignore (Unix.read ready_r (Bytes.create 1) 0 1);
        Some (pid, ready_r, stop_w)
    end
  in
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
  Printf.printf "%.1f groups/s p50 %.2f p99 %.2f ms%s\n%!" (float n /. dt) (float (Histogram.percentile h 0.5) /. 1e3)
    (float (Histogram.percentile h 0.99) /. 1e3)
    (match child with
     | None -> ""
     | Some (pid, r, w) ->
       ignore (Unix.write_substring w "s" 0 1);
       let b = Bytes.create 32 in
       let n = Unix.read r b 0 32 in
       ignore (Unix.waitpid [] pid);
       Printf.sprintf "; %d watches (another process) got %s changes" watchers (Bytes.sub_string b 0 n))

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

(* ---- local reads ---- *)

let local addr facts n =
  let s = setup ~local:true addr facts in
  if s.db.local = None then failwith "the database is not followed (a Unix socket is needed)";
  (* warm: every invoice of the sample once *)
  for i = 0 to 81_919 do ignore (ok (Client.get s.c s.db (invoice s i))) done;
  let t0 = now () in
  for i = 1 to n do ignore (Client.get s.c s.db (invoice s (i * 7919))) done;
  Printf.printf "%.4f\n%!" ((now () -. t0) /. float n *. 1e6);
  Client.close s.c

let ids addr facts =
  let s = setup addr facts in
  for i = 0 to 81_919 do Printf.printf "%d\n" (invoice s i) done;
  Client.close s.c

let localq addr facts which n =
  let s = setup ~local:true addr facts in
  if s.db.local = None then failwith "the database is not followed";
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
   | "Q3" -> Printf.eprintf "local Q3 rows city-7: %d\n%!" (run 7)
   | _ ->
     let _, rows = ok (Client.find s.c s.db ~select:(Wire.Group ([||], [| Wire.Count; Wire.Sum 3 |])) q4) in
     (match rows with [ [| Value.Int n; Value.Money t |] ] -> Printf.eprintf "local Q4 count, sum: %d %d\n%!" n t | _ -> ()));
  ignore (run 0);
  let t0 = now () in
  for i = 1 to n do ignore (run i) done;
  Printf.printf "%.3f\n%!" ((now () -. t0) /. float n *. 1e6);
  Client.close s.c

(* this process's Pss and RSS, kB *)
let memory () =
  let pss = ref 0 and rss = ref 0 in
  In_channel.with_open_text "/proc/self/smaps_rollup" (fun ic ->
      let rec go () =
        match In_channel.input_line ic with
        | None -> ()
        | Some l ->
          (match String.split_on_char ' ' l |> List.filter (( <> ) "") with
           | [ "Pss:"; n; "kB" ] -> pss := int_of_string n
           | [ "Rss:"; n; "kB" ] -> rss := int_of_string n
           | _ -> ());
          go ()
      in
      go ());
  !pss, !rss

let cpu () = let t = Unix.times () in t.tms_utime +. t.tms_stime

let follow addr facts secs =
  let s = setup ~local:true addr facts in
  let fol = match s.db.local with Some f -> f | None -> failwith "the database is not followed" in
  for i = 0 to 81_919 do ignore (ok (Client.get s.c s.db (invoice s i))) done;
  let a0 = fol.applied and c0 = cpu () and t0 = now () in
  Unix.sleepf secs;
  let a1 = fol.applied and c1 = cpu () and t1 = now () in
  let pss, rss = memory () in
  Printf.printf "cpu %.2f %% of a core, %d frames applied, pss %d kB, rss %d kB\n%!" ((c1 -. c0) /. (t1 -. t0) *. 100.) (a1 - a0) pss rss;
  Client.close s.c

(* ---- live questions ---- *)

let pct (a : float array) q =
  let a = Array.copy a in
  Array.sort compare a;
  if Array.length a = 0 then nan else a.(min (Array.length a - 1) (int_of_float (q *. float (Array.length a))))

let unpaid_of s client =
  let pc = s.p "invoice/client" and pt = s.p "invoice/total" and ps = s.p "invoice/status" in
  { Query.vars = 2;
    where = [ { Query.e = Var 0; p = pc; v = Val (Link client) }; { e = Var 0; p = ps; v = Val (Text "unpaid") }; { e = Var 0; p = pt; v = Var 1 } ];
    ranges = [] }

(* each group's change, as it comes: its time *)
type arrivals = { am : Mutex.t; ac : Condition.t; at : (int, float) Hashtbl.t }

let arrivals () = { am = Mutex.create (); ac = Condition.create (); at = Hashtbl.create 1024 }
let note a g = Mutex.protect a.am (fun () -> Hashtbl.replace a.at g (now ()); Condition.broadcast a.ac)

let wait_for a g limit =
  let deadline = now () +. limit in
  Mutex.protect a.am (fun () ->
      while (not (Hashtbl.mem a.at g)) && now () < deadline do
        Mutex.unlock a.am;
        Thread.delay 0.00002;
        Mutex.lock a.am
      done;
      Hashtbl.find_opt a.at g)

(* a remote watch on a connection of its own, read by a thread: each change's time *)
let remote_watch addr q a =
  let c = connect addr in
  let db = ok (Client.open_db ~local:false c "main") in
  let id = Client.watch c db q in
  let rec loop () =
    match Client.next_push c id with
    | Client.Pushed (Wire.Change ch) -> note a ch.group; loop ()
    | Client.Pushed _ -> loop ()
    | Client.Ended e -> prerr_endline ("watch ended: " ^ e.code)
    | exception Client.Broken _ -> ()
  in
  Thread.create loop ()

let new_invoice s client k =
  let pc = s.p "invoice/client" and pt = s.p "invoice/total" and ps = s.p "invoice/status" and pd = s.p "invoice/date" in
  List.concat
    (List.init k (fun j ->
         [ Resolve.Add (-(j + 1), pc, Link client); Add (-(j + 1), pt, Money (100 + j)); Add (-(j + 1), ps, Text "unpaid"); Add (-(j + 1), pd, Date 1) ]))

let wlat addr facts mode n =
  let s = setup ~local:(mode = "local") addr facts in
  let client = s.cids.(1) in
  let q = unpaid_of s client in
  let a = arrivals () in
  (match mode with
   | "local" -> (
     match Client.local_hub s.c s.db with
     | Some hub -> ignore (Live.subscribe hub q (Wire.Give [||]) ~from:0 ~emit:(function Live.Change ch -> note a ch.group; true | _ -> true))
     | None -> failwith "not followed here")
   | _ -> ignore (remote_watch addr q a));
  Unix.sleepf 0.2;
  let commit = Array.make n 0. and after = Array.make n 0. in
  for i = 0 to n - 1 do
    let t0 = now () in
    let r = ok (Client.write s.c s.db (new_invoice s client 1)) in
    let t1 = now () in
    match wait_for a r.group 5. with
    | Some t2 -> commit.(i) <- (t1 -. t0) *. 1e6; after.(i) <- (t2 -. t1) *. 1e6
    | None -> failwith "a change did not come"
  done;
  Printf.printf "commit p50 %.1f p99 %.1f us; change after the receipt p50 %.1f p99 %.1f us
%!" (pct commit 0.5) (pct commit 0.99)
    (pct after 0.5) (pct after 0.99);
  Client.close s.c

let proc_kb pid key =
  match In_channel.with_open_text (Printf.sprintf "/proc/%d/status" pid) In_channel.input_all with
  | t ->
    List.find_map
      (fun l -> if String.length l > String.length key && String.sub l 0 (String.length key) = key then Scanf.sscanf (String.sub l (String.length key) (String.length l - String.length key)) " %d" (fun x -> Some x) else None)
      (String.split_on_char '\n' t)
    |> Option.value ~default:0
  | exception Sys_error _ -> 0

let stall addr facts n secs stalled =
  let s = setup addr facts in
  let client = s.cids.(2) in
  let q = unpaid_of s client in
  let watchers = Array.init n (fun _ -> arrivals ()) in
  Array.iter (fun a -> ignore (remote_watch addr q a)) watchers;
  (* connections that watch and never read *)
  let silent =
    List.init stalled (fun _ ->
        let c = connect addr in
        let db = ok (Client.open_db ~local:false c "main") in
        ignore (Client.watch c db q);
        c)
  in
  Unix.sleepf 0.5;
  let receipts = Hashtbl.create 1024 in
  let t_end = now () +. secs in
  while now () < t_end do
    let r = ok (Client.write s.c s.db (new_invoice s client 20)) in
    Hashtbl.replace receipts r.group (now ())
  done;
  Unix.sleepf 1.0;
  let lat = ref [] and got = ref 0 and want = ref 0 in
  Hashtbl.iter
    (fun g t ->
      Array.iter
        (fun a ->
          incr want;
          match Mutex.protect a.am (fun () -> Hashtbl.find_opt a.at g) with
          | Some t2 -> incr got; lat := ((t2 -. t) *. 1e6) :: !lat
          | None -> ())
        watchers)
    receipts;
  let l = Array.of_list !lat in
  let pid = match Sys.getenv_opt "CEPHEUS_PID" with Some p -> int_of_string p | None -> 0 in
  Printf.printf "%d watchers, %d silent: %d groups, %.1f %% delivered, after the receipt p50 %.0f p99 %.0f us; server rss %d kB hwm %d kB
%!"
    n stalled (Hashtbl.length receipts) (100. *. float !got /. float (max 1 !want)) (pct l 0.5) (pct l 0.99) (proc_kb pid "VmRSS:")
    (proc_kb pid "VmHWM:");
  List.iter Client.close silent;
  Client.close s.c

(* the hub alone, in this process, on a database directory nobody serves *)
let livecpu dir screens groups =
  let db = match Cepheus.open_ dir with Ok d -> d | Error e -> failwith (Cepheus.message e) in
  let v = ref (Cepheus.view db) in
  let p n = match Cepheus.property !v n with Some p -> p | None -> failwith n in
  let pc = p "invoice/client" and pt = p "invoice/total" and ps = p "invoice/status" and pd = p "invoice/date" and mail = p "client/email" in
  let nclients = Store.facts !v / facts_per_client in
  let cid k =
    match Cepheus.find !v { vars = 1; where = [ { e = Var 0; p = mail; v = Val (Text (Printf.sprintf "c%d@example.com" k)) } ]; ranges = [] } with
    | Ok [ [| Value.Link e |] ] -> e
    | _ -> failwith "email"
  in
  let clients = Array.init screens (fun k -> cid (k * (nclients / screens))) in
  let unpaid c = { Query.vars = 2; where = [ { Query.e = Var 0; p = pc; v = Val (Link c) }; { e = Var 0; p = ps; v = Val (Text "unpaid") }; { e = Var 0; p = pt; v = Var 1 } ]; ranges = [] } in
  let dash = { Query.vars = 2; where = [ { Query.e = Var 0; p = ps; v = Val (Text "unpaid") }; { e = Var 0; p = pt; v = Var 1 } ]; ranges = [] } in
  let dsel = Wire.Group ([||], [| Wire.Count; Wire.Sum 1 |]) in
  let hub = Live.create !v ~tag:!v.group ~durable:!v.group in
  let rows = Array.make screens [] and drow = ref [] and pushes = ref 0 in
  let t0 = now () in
  Array.iteri
    (fun i c ->
      ignore
        (Live.subscribe hub (unpaid c) (Wire.Give [||]) ~from:0 ~emit:(fun m ->
             (match m with
              | Live.Answer a -> rows.(i) <- a.rows
              | Change ch ->
                incr pushes;
                rows.(i) <- ch.added @ List.filter (fun r -> not (List.mem r ch.removed)) rows.(i)
              | _ -> ());
             true)))
    clients;
  ignore
    (Live.subscribe hub dash dsel ~from:0 ~emit:(fun m ->
         (match m with Live.Answer a -> drow := a.rows | Change ch -> drow := ch.added | _ -> ());
         true));
  let t_sub = now () -. t0 in
  (* the invoices of the watched clients: those the groups change *)
  let inv = Array.map (fun c -> Array.of_list (Cepheus.things !v pc (Link c))) clients in
  let r = Rng.make 11 in
  let times = Array.make groups 0. in
  let touched = Array.make groups [] in
  for k = 0 to groups - 1 do
    let i = Rng.int r screens in
    let c = clients.(i) in
    let ops =
      match Rng.int r 5 with
      | 0 | 1 -> [ Resolve.Add (-1, pc, Link c); Add (-1, pt, Money (Rng.int r 100000)); Add (-1, ps, Text "unpaid"); Add (-1, pd, Date 1) ]
      | 2 | 3 ->
        let x = inv.(i).(Rng.int r (Array.length inv.(i))) in
        [ Add (x, ps, Text (if Rng.bool r then "paid" else "unpaid")) ]
      | _ -> let x = inv.(i).(Rng.int r (Array.length inv.(i))) in [ Add (x, pt, Money (Rng.int r 100000)) ]
    in
    touched.(k) <- [ i ];
    match Resolve.resolve !v ~n:(!v.group + 1) ~time:0 ~by:0 ~why:"" ops with
    | Ok (v', g, _) ->
      let t = now () in
      Live.frame hub ~tag:v'.group [ g ] v';
      Live.durable hub v'.group;
      times.(k) <- (now () -. t) *. 1e6;
      v := v'
    | Error e -> failwith (Engine.message (Engine.of_resolve e))
  done;
  (* asking again instead: the screen a group touches, and the dashboard *)
  let m = min groups 1000 in
  let t = now () in
  for k = 0 to m - 1 do List.iter (fun i -> ignore (Answer.answer !v (unpaid clients.(i)) (Wire.Give [||]))) touched.(k) done;
  let reask = (now () -. t) /. float m *. 1e6 in
  let t = now () in
  for _ = 1 to 20 do ignore (Answer.answer !v dash dsel) done;
  let redash = (now () -. t) /. 20. *. 1e6 in
  (* checked: every screen and the dashboard are Find's answers now *)
  let sorted l = List.sort compare l in
  let ok_rows = ref 0 in
  Array.iteri
    (fun i c ->
      let a = Answer.answer !v (unpaid c) (Wire.Give [||]) in
      let want = List.init a.n (fun j -> Array.init a.cols (fun x -> Store.value !v (a.typ x) (a.word j x))) in
      if sorted want = sorted rows.(i) then incr ok_rows)
    clients;
  let a = Answer.answer !v dash dsel in
  let dwant = List.init a.n (fun j -> Array.init a.cols (fun x -> Store.value !v (a.typ x) (a.word j x))) in
  let mean = Array.fold_left ( +. ) 0. times /. float groups in
  Printf.printf
    "%d screens + a dashboard (subscribed in %.0f ms): a group %.2f us p50, %.2f p99, %.2f mean; %d changes given; asking again the screen a group touches %.1f us and the dashboard %.0f us; %d/%d screens and the dashboard %s Find's
%!"
    screens (t_sub *. 1e3) (pct times 0.5) (pct times 0.99) mean !pushes reask redash !ok_rows screens
    (if sorted dwant = sorted !drow then "equal to" else "NOT equal to")

(* D databases d1 .. dD of one server, C writers each (a connection each), each writing one fact a group for SECS:
   groups a second in all, and the latency of a write (each database forces its own journal) *)
let mwrite addr dbs per secs =
  let stop = Atomic.make false in
  let n = dbs * per in
  let hist = Array.init n (fun _ -> Histogram.create ()) and cnt = Array.make n 0 in
  let worker k () =
    let c = connect addr in
    let name = Printf.sprintf "d%d" (1 + (k mod dbs)) in
    let db, p =
      match Client.declare c name [ { Schema.name = "n/k"; typ = Value.Tint; many = false; unique = false } ] with
      | Ok (db, [ p ]) -> db, p
      | Ok _ -> failwith "declare"
      | Error e -> failwith (e.code ^ ": " ^ e.message)
    in
    let i = ref 0 in
    while not (Atomic.get stop) do
      let t = now () in
      ignore (ok (Client.write c db [ Resolve.Add (-1, p, Int !i) ]));
      incr i;
      Histogram.record hist.(k) (int_of_float ((now () -. t) *. 1e6));
      cnt.(k) <- cnt.(k) + 1
    done;
    Client.close c
  in
  let t0 = now () in
  let ts = List.init n (fun k -> Thread.create (worker k) ()) in
  Unix.sleepf secs;
  Atomic.set stop true;
  List.iter Thread.join ts;
  let dt = now () -. t0 in
  let h = Histogram.create () in
  Array.iter (Histogram.merge_into h) hist;
  Printf.printf "%d databases, %d writers each: %.1f groups/s p50 %.2f p99 %.2f ms\n%!" dbs per (float (Array.fold_left ( + ) 0 cnt) /. dt)
    (float (Histogram.percentile h 0.5) /. 1e3) (float (Histogram.percentile h 0.99) /. 1e3)

(* Writes at a steady rate: RATE groups a second of one fact each for SECS seconds, spread over W connections (one in
   flight each, each on its own schedule: an open loop, a write that is late goes at once); then, after a second, the
   lines of the status that name the replicas (an admin token in CEPHEUS_ADMIN): the replica lag from a group durable
   on the primary to the replica's word that it holds it durably *)
let rate addr r secs w =
  let stop = Atomic.make false in
  let hist = Array.init w (fun _ -> Histogram.create ()) and cnt = Array.make w 0 in
  let t0 = now () in
  let worker k () =
    let c = connect addr in
    let db, p =
      match Client.declare c "main" [ { Schema.name = "n/k"; typ = Value.Tint; many = false; unique = false } ] with
      | Ok (db, [ p ]) -> db, p
      | Ok _ -> failwith "declare"
      | Error e -> failwith (e.code ^ ": " ^ e.message)
    in
    let gap = float w /. float r in
    let i = ref 0 in
    while not (Atomic.get stop) do
      let at = t0 +. (gap *. (float !i +. (float k /. float w))) in
      let d = at -. now () in
      if d > 0. then Unix.sleepf d;
      let t = now () in
      ignore (ok (Client.write c db [ Resolve.Add (-1, p, Int !i) ]));
      incr i;
      Histogram.record hist.(k) (int_of_float ((now () -. t) *. 1e6));
      cnt.(k) <- cnt.(k) + 1
    done;
    Client.close c
  in
  let ts = List.init w (fun k -> Thread.create (worker k) ()) in
  Unix.sleepf secs;
  Atomic.set stop true;
  List.iter Thread.join ts;
  let dt = now () -. t0 in
  let h = Histogram.create () in
  Array.iter (Histogram.merge_into h) hist;
  Printf.printf "rate %d: %.1f groups/s, write p50 %.3f p99 %.3f ms" r (float (Array.fold_left ( + ) 0 cnt) /. dt)
    (float (Histogram.percentile h 0.5) /. 1e3) (float (Histogram.percentile h 0.99) /. 1e3);
  (match Sys.getenv_opt "CEPHEUS_ADMIN" with
   | None -> ()
   | Some a -> (
     Unix.sleepf 1.0;
     match Client.connect ~program:"sbench" ?ca:(Sys.getenv_opt "CEPHEUS_CA") (Client.address_of_string addr) a with
     | Error m -> failwith m
     | Ok c ->
       (match Client.status c with
        | Ok l ->
          List.iter
            (fun (k, v) ->
              let has s = let n = String.length s in let rec f i = i + n <= String.length k && (String.sub k i n = s || f (i + 1)) in f 0 in
              if has ".replica." && (has "lag" || has ".group") then Printf.printf " %s %s" k v)
            l
        | Error e -> failwith e.message);
       Client.close c));
  print_newline ()

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

(* The cost of the rights per kind a write: Core.unaddable on a group of 4 facts, a schema of 40 properties of 10 kinds,
   a token that adds 3 of them; ROUNDS rounds of N groups, each round's ns a group *)
let rights rounds n =
  let sim = Sim_disk.create (Rng.make 1) in
  let disk = Sim_disk.disk sim in
  disk.mkdir "/r";
  let e = Result.get_ok (Engine.open_ disk "/r/db") in
  let decl = List.concat (List.init 40 (fun i ->
      List.map (fun (t, p, v) -> Resolve.Add (t, p, v)) (Schema.facts (16 + i) { Schema.name = Printf.sprintf "k%d/f%d" (i / 4) i; typ = Value.Tint; many = false; unique = false }))) in
  ignore (Engine.commit e (Engine.prepare e [| decl, 0, "declare" |]));
  let d = { Core.name = "db"; index = 0; dir = "/r/db"; view = (fun () -> Atomic.get e.published); sessions = Sessions.create ();
            more = (fun () -> []); hub = (fun () -> Live.create (Atomic.get e.published) ~tag:0 ~durable:max_int);
            files = Files.cell ~disk ~master:(fun () -> Ok (String.make 32 'k')) "/r/db/vault" } in
  let r = Tokens.Kinds { read = [ "k0"; "k1"; "k2" ]; add = [ "k0"; "k1"; "k2" ] } in
  let tok = { Tokens.name = "k"; hash = Tokens.hash_of_text "cph_k"; databases = [ "db", r ]; admin = false } in
  let srv = Core.create ~server_id:"s" ~cluster_id:"c" ~dbs:[| d |] ~tokens:(Tokens.with_tokens Tokens.empty [ tok ]) ~now:disk.now ~new_session:(fun () -> 1) () in
  let c = Core.connect srv ~flush:ignore ~submit:(fun _ _ _ _ _ -> ()) in
  c.rights <- [| Some r |];
  c.kinds <- [| None |];
  let v = d.view () in
  let ops = [ Resolve.Add (-1, 16, Value.Int 1); Add (-1, 17, Int 2); Add (-1, 21, Int 3); Add (-1, 27, Int 4) ] in
  for _ = 1 to rounds do
    let t0 = Unix.gettimeofday () in
    let bad = ref 0 in
    for _ = 1 to n do if Core.unaddable c 0 v r ops <> None then incr bad done;
    let dt = Unix.gettimeofday () -. t0 in
    if !bad > 0 then failwith "rights: denied";
    Printf.printf "%.2f\n%!" (dt /. float n *. 1e9)
  done

(* A change under a watch of each operator, in a hub of its own, against the question answered again in full: on the
   data of the benchmarks (10 M facts), changes made in memory one at a time (no disk), the frame of each timed
   (Live.frame: the keys it touches, their questions before and after) and the whole answer after it. 21 changes. *)
let watches dir =
  let module Ask = Question.Ask in
  let db = match Cepheus.open_ dir with Ok db -> db | Error e -> failwith (Cepheus.message e) in
  let v = ref (Cepheus.view db) in
  let p n = Option.get (Cepheus.property !v n) in
  let cty = p "client/city" and mail = p "client/email" and client = p "invoice/client" and status = p "invoice/status" in
  let pat e p x = { Query.e; p; v = x } in
  let forms =
    [ "Not: the clients of city-7 with no unpaid invoice",
      { Query.vars = 2; where = [ pat (Var 0) cty (Val (Text "city-7")) ]; ranges = [] },
      [ Ask.Not [ Pattern (pat (Var 1) client (Var 0)); Pattern (pat (Var 1) status (Val (Text "unpaid"))) ] ], Wire.Give [| 0 |];
      "Or: the clients of city-7, or of one e-mail",
      { Query.vars = 1; where = []; ranges = [] },
      [ Ask.Or [ [ Pattern (pat (Var 0) cty (Val (Text "city-7"))) ]; [ Pattern (pat (Var 0) mail (Val (Text "c5@example.com"))) ] ] ], Wire.Give [| 0 |];
      "In: the clients of city-7 or city-8",
      { Query.vars = 2; where = [ pat (Var 0) cty (Var 1) ]; ranges = [] }, [ Ask.In (1, [ Text "city-7"; Text "city-8" ]) ], Wire.Give [| 0 |];
      "Prefix: the clients whose e-mail starts with c1234",
      { Query.vars = 2; where = [ pat (Var 0) mail (Var 1) ]; ranges = [] }, [ Ask.Prefix (1, "c1234") ], Wire.Give [| 0; 1 |] ]
  in
  (* the changes that touch each watch: an invoice of a city-7 client paid, then unpaid again (Not); a client moved to
     city-7 (Or), to city-8 (In); an e-mail changed to c1234... (Prefix) *)
  let ids q = List.map (fun r -> match r.(0) with Value.Link e -> e | _ -> 0) (Result.get_ok (Cepheus.find !v q)) in
  let c7 = ids { vars = 1; ranges = []; where = [ pat (Var 0) cty (Val (Text "city-7")) ] } in
  let inv = Array.of_list (List.concat_map (fun c -> ids { vars = 1; ranges = []; where = [ pat (Var 0) client (Val (Link c)) ] }) (List.filteri (fun i _ -> i < 30) c7)) in
  let c3 = Array.of_list (ids { vars = 1; ranges = []; where = [ pat (Var 0) cty (Val (Text "city-3")) ] }) in
  (* a client of the Not's answer (no unpaid invoice): one of its invoices unpaid, then paid again *)
  let clear = List.filter_map (fun r -> match r.(0) with Value.Link e -> Some e | _ -> None)
      (match Answer.answer ~extra:(let _, _, e, _ = List.hd forms in e) !v (let _, q, _, _ = List.hd forms in q) (Wire.Give [| 0 |]) with
       | a -> List.init a.n (fun i -> [| Value.Link (a.word i 0) |])) in
  let its = Array.of_list (ids { vars = 1; ranges = []; where = [ pat (Var 0) client (Val (Link (List.hd clear))) ] }) in
  ignore inv;
  let change = [| (fun k -> [ Resolve.Add (its.(0), status, Text (if k mod 2 = 1 then "unpaid" else "paid")) ]);
                  (fun k -> [ Resolve.Add (c3.(k), cty, Text "city-7") ]);
                  (fun k -> [ Resolve.Add (c3.(100 + k), cty, Text "city-8") ]);
                  (fun k -> [ Resolve.Add (c3.(200 + k), mail, Text (Printf.sprintf "c1234%d@example.com" (900000 + k))) ]) |] in
  List.iteri
    (fun i (name, q, extra, sel) ->
      let h = Live.create !v ~tag:!v.group ~durable:!v.group in
      let changes = ref 0 in
      ignore (Live.subscribe ~extra h q sel ~from:0 ~emit:(function Live.Change _ -> incr changes; true | _ -> true));
      let tc = ref [] and ta = ref [] in
      for k = 1 to 21 do
        let n = !v.group + 1 in
        match Resolve.resolve !v ~n ~time:n ~by:0 ~why:"" (change.(i) k) with
        | Ok (v', g, _) ->
          let t = now () in
          Live.frame h ~tag:v'.group [ g ] v';
          tc := (now () -. t) :: !tc;
          Live.durable h v'.group;
          let t = now () in
          ignore (Answer.answer ~extra v' q sel);
          ta := (now () -. t) :: !ta;
          v := v'
        | Error _ -> failwith "the change was refused"
      done;
      let show what l = let l = List.sort compare l in Printf.printf "%-60s %s median %8.1f us, min %8.1f us\n" name what (1e6 *. List.nth l 10) (1e6 *. List.hd l) in
      show "a change    " !tc;
      show "again, whole" !ta;
      Printf.printf "%-60s %d changes of 21 changed its rows\n%!" name !changes)
    forms;
  Cepheus.close db

let () =
  match Sys.argv with
  | [| _; "watches"; dir |] -> watches dir
  | [| _; "ping"; a; n |] -> ping a (int_of_string n)
  | [| _; "get"; a; f; d; n |] -> get a (int_of_string f) (int_of_string d) (int_of_string n)
  | [| _; "clients"; a; f; c; n |] -> clients a (int_of_string f) (int_of_string c) (int_of_string n)
  | [| _; "write"; a; f; c; secs |] -> write a (int_of_string f) (int_of_string c) (float_of_string secs) 0
  | [| _; "write"; a; f; c; secs; w |] -> write a (int_of_string f) (int_of_string c) (float_of_string secs) (int_of_string w)
  | [| _; "q"; a; f; q; n |] -> question a (int_of_string f) q (int_of_string n)
  | [| _; "check"; a; f |] -> check a (int_of_string f)
  | [| _; "hs"; a; n |] -> hs a (int_of_string n)
  | [| _; "local"; a; f; n |] -> local a (int_of_string f) (int_of_string n)
  | [| _; "localq"; a; f; q; n |] -> localq a (int_of_string f) q (int_of_string n)
  | [| _; "follow"; a; f; secs |] -> follow a (int_of_string f) (float_of_string secs)
  | [| _; "ids"; a; f |] -> ids a (int_of_string f)
  | [| _; "wlat"; a; f; m; n |] -> wlat a (int_of_string f) m (int_of_string n)
  | [| _; "stall"; a; f; n; secs; st |] -> stall a (int_of_string f) (int_of_string n) (float_of_string secs) (int_of_string st)
  | [| _; "mwrite"; a; d; c; secs |] -> mwrite a (int_of_string d) (int_of_string c) (float_of_string secs)
  | [| _; "rate"; a; r; secs; w |] -> rate a (int_of_string r) (float_of_string secs) (int_of_string w)
  | [| _; "livecpu"; d; n; g |] -> livecpu d (int_of_string n) (int_of_string g)
  | [| _; "rights"; rounds; n |] -> rights (int_of_string rounds) (int_of_string n)
  | _ ->
    prerr_endline
      "sbench.exe ping ADDR N | get ADDR FACTS DEPTH N | clients ADDR FACTS C N | write ADDR FACTS C SECS [W] | q ADDR FACTS Q3|Q4 N | check ADDR FACTS | local ADDR FACTS N | localq ADDR FACTS Q3|Q4 N | follow ADDR FACTS SECS | ids ADDR FACTS | wlat ADDR FACTS local|remote N | stall ADDR FACTS N SECS S | livecpu DIR SCREENS GROUPS | mwrite ADDR D C SECS | rate ADDR RATE SECS W | rights ROUNDS N";
    exit 2
