(* The real server, killed. A `cepheus serve` process runs on a scratch directory; client threads write through its
   Unix socket, each write a new thing with a value of its own; the server is killed (kill -9) at random moments and
   started again, while the clients go on: their library connects again and sends each unanswered write again with
   its session and serial. At the end (a clean stop, a start, a stop), every write that got a receipt is in the
   database (G1), and no write is there twice (G14). Also: a second server on the same data is refused (G9), the
   status of an admin token, a token removed while its program is connected (G16), `cepheus stop`.

     server_crash.exe DIR ROUNDS *)

open Cepheus
open Cepheus_server
module C = Check

let bin = Filename.concat (Filename.dirname (Filename.dirname Sys.executable_name)) "bin/main.exe"

let write_file path s = Out_channel.with_open_bin path (fun oc -> output_string oc s)

let start cfg =
  let pid = Unix.create_process bin [| bin; "serve"; "--config"; cfg |] Unix.stdin Unix.stdout Unix.stderr in
  pid

let wait_ready sock =
  let t0 = Unix.gettimeofday () in
  let rec go () =
    let s = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    match Unix.connect s (Unix.ADDR_UNIX sock) with
    | () -> Unix.close s
    | exception Unix.Unix_error _ ->
      Unix.close s;
      if Unix.gettimeofday () -. t0 > 30. then failwith "the server did not start";
      Thread.delay 0.005;
      go ()
  in
  go ()

let () =
  let dir, rounds = match Sys.argv with [| _; d; n |] -> d, int_of_string n | _ -> prerr_endline "server_crash.exe DIR ROUNDS"; exit 2 in
  C.rmrf dir;
  Unix.mkdir dir 0o700;
  Unix.mkdir (Filename.concat dir "run") 0o700;
  let cfg = Filename.concat dir "cluster.toml" in
  write_file cfg
    "[cluster]\nname = \"crash\"\nid = \"cph-c-00000000000000c1\"\nme = \"srv1\"\n[[peer]]\nname = \"srv1\"\naddress = \"127.0.0.1:7401\"\n\
     [clients]\nsocket = \"run\"\ndomains = 2\n[storage]\ndata = \"data\"\ncache = \"64M\"\n[[database]]\nname = \"main\"\n";
  let wtext, whash = Tokens.generate () and atext, ahash = Tokens.generate () in
  let toks = Tokens.with_tokens Tokens.empty
      [ { Tokens.name = "w"; hash = whash; databases = [ "main", Tokens.Write ]; admin = false };
        { Tokens.name = "a"; hash = ahash; databases = []; admin = true } ] in
  Tokens.save (Filename.concat dir "tokens.toml") toks;
  let sock = Filename.concat dir "run/.s.cepheus.7400" in
  let addr = Client.Unix_socket sock in
  let pid = ref (start cfg) in
  wait_ready sock;
  (* the property, declared once *)
  let c0 = Result.get_ok (Client.connect addr wtext) in
  let db, p = match Client.declare c0 "main" [ prop "k" Tint ] with Ok (db, [ p ]) -> db, p | _ -> failwith "declare" in
  Client.close c0;
  (* G9: a second server on the same data is refused *)
  let second = Unix.create_process bin [| bin; "serve"; "--config"; cfg |] Unix.stdin Unix.stdout (Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0) in
  (match Unix.waitpid [] second with
   | _, Unix.WEXITED n -> C.check (n <> 0) "a second server on the same data is refused"
   | _ -> C.check false "a second server: killed?");
  (* writers: thread t writes values t * 1_000_000 + i *)
  let nthreads = 4 in
  let acked = Array.make nthreads [] and lost = Atomic.make 0 and stop = Atomic.make false in
  let writer t () =
    match Client.connect addr wtext with
    | Error m -> C.check false "connect: %s" m
    | Ok c ->
      let i = ref 0 in
      while not (Atomic.get stop) do
        let v = (t * 1_000_000) + !i in
        incr i;
        match Client.write c db ~why:"crash" [ Resolve.Add (-1, p, Int v) ] with
        | Ok r -> acked.(t) <- (v, r.group) :: acked.(t)
        | Error { code = "unreachable"; _ } -> Atomic.incr lost
        | Error e -> C.check false "a write failed: %s %s" e.code e.message
      done;
      Client.close c
  in
  let ts = List.init nthreads (fun t -> Thread.create (writer t) ()) in
  let r = Rng.make 7 in
  for _ = 1 to rounds do
    Thread.delay (0.05 +. (float (Rng.int r 250) /. 1000.));
    Unix.kill !pid Sys.sigkill;
    ignore (Unix.waitpid [] !pid);
    pid := start cfg;
    wait_ready sock
  done;
  Thread.delay 0.2;
  Atomic.set stop true;
  List.iter Thread.join ts;
  (* status, with the admin token *)
  let ca = Result.get_ok (Client.connect addr atext) in
  (match Client.status ca with
   | Ok l -> C.check (List.mem_assoc "database.main.group" l) "status names the database"
   | Error e -> C.check false "status: %s" e.message);
  Client.close ca;
  (* a clean stop by `cepheus stop`, then a start: everything acknowledged is there, once *)
  let code = Sys.command (Printf.sprintf "%s stop --config %s > /dev/null" bin (Filename.quote cfg)) in
  C.check (code = 0) "cepheus stop";
  ignore (Unix.waitpid [] !pid);
  pid := start cfg;
  wait_ready sock;
  let c = Result.get_ok (Client.connect addr wtext) in
  let q = { Query.vars = 2; where = [ { Query.e = Var 0; p; v = Var 1 } ]; ranges = [] } in
  (match Client.find c db q with
   | Error e -> C.check false "find: %s" e.message
   | Ok (_, rows) ->
     let seen = Hashtbl.create 1024 in
     List.iter (fun row -> match row.(1) with Value.Int v -> Hashtbl.replace seen v (1 + Option.value (Hashtbl.find_opt seen v) ~default:0) | _ -> ()) rows;
     let twice = Hashtbl.fold (fun _ n k -> if n > 1 then k + 1 else k) seen 0 in
     let n_acked = Array.fold_left (fun n l -> n + List.length l) 0 acked in
     let missing = Array.fold_left (fun n l -> n + List.length (List.filter (fun (v, _) -> not (Hashtbl.mem seen v)) l)) 0 acked in
     C.check (twice = 0) "no write applied twice (%d values twice)" twice;
     C.check (missing = 0) "every acknowledged write is there (%d missing of %d)" missing n_acked;
     Printf.printf "server crash: %d kills, %d writes acknowledged, %d in the database, %d unreachable, 0 twice, 0 lost\n%!"
       rounds n_acked (Hashtbl.length seen) (Atomic.get lost));
  (* G16: a token removed from tokens.toml while its program is connected: refused at its next request *)
  Tokens.save (Filename.concat dir "tokens.toml") (Tokens.with_tokens Tokens.empty [ List.nth toks.tokens 1 ]);
  let t0 = Unix.gettimeofday () in
  let rec refused () =
    match Client.get c db 65536 with
    | Error { code = "auth"; _ } -> true
    | exception Client.Broken _ -> true
    | _ -> if Unix.gettimeofday () -. t0 > 5. then false else (Thread.delay 0.1; refused ())
  in
  C.check (refused ()) "a removed token is refused within the reload";
  Client.close c;
  Unix.kill !pid Sys.sigterm;
  (match Unix.waitpid [] !pid with
   | _, Unix.WEXITED 0 -> C.check true "SIGTERM: a clean exit"
   | _ -> C.check false "SIGTERM: not a clean exit");
  C.check (not (Sys.file_exists sock)) "the socket is removed at stop";
  C.rmrf dir;
  C.finish "server crash"
