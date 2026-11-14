(* A Raft cluster of three real servers on this machine, over mutual TLS on loopback, each with its own data
   directory and its own ports (peers and programs). `cepheus cluster init` makes the CA and srv1's certificate,
   `cluster cert` srv2's, srv3's and an intruder's. Then:
   - the three elect one leader; a program connected to any of them is sent to it (not_leader, its address) and
     writes there; every server holds the same groups;
   - a follower answers a program that cannot follow (the Unix socket, no CA) with not_leader and the leader's
     address; `cepheus promote` and `cepheus replicate` are refused in a Raft cluster;
   - the leader killed (kill -9) while a program writes: another is elected, the program goes on through it (its
     write in flight sent again in its session, applied once: G14), no write it was told committed is missing; the
     time from the kill to the first write committed by the new leader is the failover time;
   - the old leader started again follows the new one and catches up; its data directory 0700, its Raft state and
     log 0600;
   - the peer port refuses a peer of protocol 1, a certificate of the cluster's CA for a name no peer has, and a
     certificate of another CA.
   - a load, a change of the rules (computed in the leader's background) beside groups that count with one counter
     (Incr), and a load past one Raft entry (8 MiB), refused whole; the leader killed: the new one holds the load,
     the change's consequences and the counter, nothing of the refused load.

     server_raft.exe DIR *)

open Cepheus
open Cepheus_server
module C = Check

let bin = Filename.concat (Filename.dirname (Filename.dirname Sys.executable_name)) "bin/main.exe"
let run args = Sys.command (String.concat " " (List.map Filename.quote (bin :: args)) ^ " > /dev/null 2>&1")
let write_file path s = Out_channel.with_open_bin path (fun oc -> output_string oc s)

let wait_for ?(limit = 60.) what f =
  let t0 = Unix.gettimeofday () in
  let rec go () = if f () then () else if Unix.gettimeofday () -. t0 > limit then failwith ("timed out: " ^ what) else (Thread.delay 0.01; go ()) in
  go ()

let wait_socket sock =
  wait_for "the server's socket" (fun () ->
      let s = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      let ok = match Unix.connect s (Unix.ADDR_UNIX sock) with () -> true | exception Unix.Unix_error _ -> false in
      Unix.close s;
      ok)

let mode path = (Unix.stat path).st_perm land 0o777

let () =
  (* a signal ends the test through exit: its servers are stopped (Serve's at_exit) *)
  List.iter (fun sg -> Sys.set_signal sg (Sys.Signal_handle (fun _ -> exit 3))) [ Sys.sigterm; Sys.sigint; Sys.sighup ];
  let dir, rounds =
    match Sys.argv with
    | [| _; d |] -> d, 0
    | [| _; d; "failover"; n |] -> d, int_of_string n
    | _ -> prerr_endline "server_raft.exe DIR [failover N]"; exit 2
  in
  C.rmrf dir;
  Unix.mkdir dir 0o700;
  let ca = Filename.concat dir "ca" and other = Filename.concat dir "other" in
  C.check (run [ "cluster"; "init"; "three"; "--dir"; ca ] = 0) "cluster init";
  List.iter (fun n -> C.check (run [ "cluster"; "cert"; n; "--dir"; ca ] = 0) "cluster cert %s" n) [ "srv2"; "srv3"; "intruder" ];
  C.check (run [ "cluster"; "init"; "other"; "--dir"; other ] = 0) "another cluster";
  C.check (run [ "cluster"; "cert"; "srv2"; "--dir"; other ] = 0) "another cluster's srv2";
  let id =
    let l = List.find (fun l -> String.length l > 5 && String.sub l 0 5 = "id = ") (String.split_on_char '\n' (In_channel.with_open_bin (Filename.concat ca "cluster.toml") In_channel.input_all)) in
    String.sub (String.trim l) 6 (String.length (String.trim l) - 7)
  in
  let base = 20000 + (Unix.getpid () mod 14000) in
  let names = [ "srv1"; "srv2"; "srv3" ] in
  let peer_port k = base + k and client_port k = base + 10 + k in
  let peers =
    String.concat ""
      (List.mapi (fun k n -> Printf.sprintf "[[peer]]\nname = %S\naddress = \"127.0.0.1:%d\"\nclients = \"127.0.0.1:%d\"\n" n (peer_port k) (client_port k)) names)
  in
  let config k me =
    let d = Filename.concat dir me in
    Unix.mkdir d 0o700;
    Unix.mkdir (Filename.concat d "run") 0o700;
    let f = Filename.concat d "cluster.toml" in
    write_file f
      (Printf.sprintf
         "[cluster]\nname = \"three\"\nid = %S\nme = %S\n%s[clients]\nlisten = \"127.0.0.1:%d\"\nsocket = \"run\"\ndomains = 1\n\
          [tls]\nca = \"%s/ca.pem\"\ncert = \"%s/%s.pem\"\nkey = \"%s/%s.key\"\n[storage]\ndata = \"data\"\ncache = \"64M\"\n\
          [[database]]\nname = \"main\"\n[[database]]\nname = \"side\"\n"
         id me peers (client_port k) ca ca me ca me);
    f
  in
  let cfgs = Array.of_list (List.mapi config names) in
  let wtext, whash = Tokens.generate () and atext, ahash = Tokens.generate () in
  let toks = Tokens.with_tokens Tokens.empty
      [ { Tokens.name = "w"; hash = whash; databases = [ "main", Tokens.Write; "side", Tokens.Write ]; admin = false };
        { Tokens.name = "a"; hash = ahash; databases = []; admin = true } ] in
  Array.iter (fun c -> Tokens.save (Filename.concat (Filename.dirname c) "tokens.toml") toks) cfgs;
  let sock k = Filename.concat dir (List.nth names k ^ "/run/.s.cepheus." ^ string_of_int (client_port k)) in
  let status k =
    match Client.connect (Client.Unix_socket (sock k)) atext with
    | Error _ -> []
    | Ok c -> Fun.protect ~finally:(fun () -> Client.close c) (fun () -> match Client.status c with Ok l -> l | Error _ -> [])
  in
  let stat k key = match List.assoc_opt key (status k) with Some v -> v | None -> "" in
  let pids = Array.map (fun c -> Serve.start bin c) cfgs in
  Array.iteri (fun k _ -> wait_socket (sock k)) cfgs;
  let alive = Array.make 3 true in
  let leader () =
    let ls = List.filter (fun k -> alive.(k) && stat k "raft.role" = "leader") [ 0; 1; 2 ] in
    match ls with [ k ] -> Some k | _ -> None
  in
  wait_for "a leader" (fun () -> leader () <> None);
  let l0 = Option.get (leader ()) in
  C.check true "the three elected %s (term %s)" (List.nth names l0) (stat l0 "raft.term");
  (* a program connected to a follower is sent to the leader *)
  let follower = (l0 + 1) mod 3 in
  let tcp k = Client.Tcp ("127.0.0.1", client_port k) in
  let w = match Client.connect ~session:777 ~ca:(Filename.concat ca "ca.pem") (tcp follower) wtext with Ok c -> c | Error m -> failwith m in
  let declare c name = match Client.declare c name [ prop "k" Tint ] with Ok (db, [ p ]) -> db, p | _ -> failwith "declare" in
  let mdb, mp = declare w "main" in
  let sdb, sp = declare w "side" in
  C.check (w.address = tcp l0) "a program connected to a follower writes through the leader";
  let told = ref [] and n = ref 0 in
  let write_some c count =
    for _ = 1 to count do
      incr n;
      let v = !n in
      (match Client.write c mdb [ Resolve.Add (-1, mp, Int v) ] with
       | Ok r -> told := (v, r.group) :: !told
       | Error e -> C.check false "a write: %s %s" e.code e.message);
      if v mod 3 = 0 then ignore (Client.write c sdb [ Resolve.Add (-1, sp, Int v) ])
    done
  in
  write_some w 200;
  let group k db = match int_of_string_opt (stat k ("database." ^ db ^ ".group")) with Some g -> g | None -> -1 in
  let same () = List.for_all (fun db -> let g = group l0 db in List.for_all (fun k -> group k db = g) [ 0; 1; 2 ]) [ "main"; "side" ] in
  wait_for "every server holds the leader's groups" same;
  C.check true "the three hold the same groups (main at %d)" (group l0 "main");
  (* a program that cannot follow: not_leader and the leader's address *)
  let r = Result.get_ok (Client.connect (Client.Unix_socket (sock follower)) wtext) in
  Client.retry_budget := 1.0;
  (match Client.open_db ~local:false r "main" with
   | Error e -> C.check false "a follower's socket, without a CA: %s %s" e.code e.message
   | Ok _ -> C.check false "a follower's socket served a read"
   | exception Client.Broken m -> C.check (String.length m > 11 && String.sub m 0 11 = "not_leader:") "a follower's socket, without a CA: %s" m);
  Client.retry_budget := 30.0;
  Client.close r;
  let raw = Result.get_ok (Client.connect (Client.Unix_socket (sock follower)) wtext) in
  (match Client.send raw (Wire.Open "main") with
   | id -> (
     Client.flush raw;
     match Client.frames raw id with
     | [ (kind, flags, body) ] -> (
       match Client.decode kind flags body, Wire.moved flags (Codec.reader body 0 (Bytes.length body)) with
       | Wire.Err { code = "not_leader"; message }, Some a ->
         C.check (a = Printf.sprintf "127.0.0.1:%d" (client_port l0)) "a follower answers not_leader with the leader's address %s (%s)" a message
       | Wire.Err e, _ -> C.check false "a follower answered %s %s" e.code e.message
       | _ -> C.check false "a follower served Open")
     | _ -> C.check false "a follower's answer in several frames"));
  Client.close raw;
  let promote k = Sys.command (Printf.sprintf "CEPHEUS_TOKEN=%s %s promote --config %s > /dev/null 2>&1" atext (Filename.quote bin) (Filename.quote cfgs.(k))) in
  C.check (promote follower <> 0) "cepheus promote is refused in a Raft cluster";
  C.check (run [ "replicate"; List.nth names l0; "--config"; cfgs.(follower) ] <> 0) "cepheus replicate is refused in a Raft cluster";
  (* [failover N] (a measure, not a test): the leader killed N times under writes; each time, from the kill: a new
     leader ready (the servers' status, polled every 5 ms) and the first write the program had committed by it *)
  if rounds > 0 then begin
    let cur = ref l0 in
    for r = 1 to rounds do
      let old = !cur in
      let stop = Atomic.make false and first = ref 0. and killed = ref 0. in
      let writer =
        Thread.create
          (fun () ->
            while not (Atomic.get stop) do
              incr n;
              match Client.write w mdb [ Resolve.Add (-1, mp, Int !n) ] with
              | Ok _ -> if !killed > 0. && !first = 0. && w.address <> tcp old then first := Unix.gettimeofday ()
              | Error e -> Printf.printf "write error %s %s\n%!" e.code e.message
            done)
          ()
      in
      Thread.delay 0.5;
      killed := Unix.gettimeofday ();
      Unix.kill pids.(old) Sys.sigkill;
      ignore (Serve.wait pids.(old));
      alive.(old) <- false;
      let ready = ref 0. in
      wait_for "a new leader" (fun () ->
          let leads k = let st = status k in List.assoc_opt "raft.role" st = Some "leader" && List.assoc_opt "raft.ready" st = Some "true" in
          match List.find_opt (fun k -> alive.(k) && leads k) [ 0; 1; 2 ] with
          | Some k when k <> old -> cur := k; if !ready = 0. then ready := Unix.gettimeofday (); !first > 0.
          | _ -> Thread.delay 0.005; false);
      Atomic.set stop true;
      Thread.join writer;
      Printf.printf "round %d: leader %s killed; a new leader (%s) %.1f ms after, the program's first write it committed %.1f ms after\n%!" r
        (List.nth names old) (List.nth names !cur) ((!ready -. !killed) *. 1000.) ((!first -. !killed) *. 1000.);
      pids.(old) <- Serve.start bin cfgs.(old);
      alive.(old) <- true;
      wait_socket (sock old);
      let same () = List.for_all (fun db -> let g = group !cur db in List.for_all (fun k -> group k db = g) [ 0; 1; 2 ]) [ "main"; "side" ] in
      wait_for "the old leader catches up" same
    done;
    Client.close w;
    Array.iteri (fun k c -> if alive.(k) then (ignore (run [ "stop"; "--config"; c ]); ignore (Serve.wait pids.(k)))) cfgs;
    C.rmrf dir;
    exit 0
  end;
  (* the leader killed while the program writes *)
  let killed_at = ref 0. and first_after = ref 0. in
  let writer =
    Thread.create
      (fun () ->
        for _ = 1 to 400 do
          incr n;
          let v = !n in
          match Client.write w mdb [ Resolve.Add (-1, mp, Int v) ] with
          | Ok r ->
            told := (v, r.group) :: !told;
            if !killed_at > 0. && !first_after = 0. && w.address <> tcp l0 then first_after := Unix.gettimeofday ()
          | Error e -> C.check false "a write during the failover: %s %s" e.code e.message
        done)
      ()
  in
  Thread.delay 0.3;
  killed_at := Unix.gettimeofday ();
  Unix.kill pids.(l0) Sys.sigkill;
  ignore (Serve.wait pids.(l0));
  alive.(l0) <- false;
  Thread.join writer;
  let l1 = Option.get (leader ()) in
  C.check (l1 <> l0) "a new leader: %s (term %s)" (List.nth names l1) (stat l1 "raft.term");
  if !first_after > 0. then begin
    let ms = (!first_after -. !killed_at) *. 1000. in
    C.check true "failover: the first write committed by the new leader %.0f ms after the kill" ms;
    Printf.printf "failover_ms %.1f\n%!" ms
  end
  else C.check false "no write committed by the new leader";
  (* nothing it was told is lost: every value at its group, on the new leader *)
  let rd = Result.get_ok (Client.open_db ~local:false w "main") in
  let missing = ref 0 in
  List.iter
    (fun (v, g) ->
      match Client.find w rd { Query.vars = 1; where = [ { Query.e = Var 0; p = mp; v = Val (Int v) } ]; ranges = [] } with
      | Ok (_, rows) -> if rows = [] then (incr missing; ignore g)
      | Error _ -> incr missing)
    !told;
  C.check (!missing = 0) "every write the program was told committed is there (%d writes, %d missing)" (List.length !told) !missing;
  (* G14: the last write sent again in its session gets its first receipt *)
  let last_v, last_g = List.hd !told in
  ignore last_v;
  (match Client.call w (Wire.Write { db = mdb.handle; serial = w.serial; floor = w.serial; by = 0; why = ""; ops = [ Resolve.Add (-1, mp, Int last_v) ] }) with
   | Wire.Receipt rc -> C.check (rc.group = last_g) "a write sent again after the failover gets its first receipt (group %d)" rc.group
   | Wire.Err e -> C.check false "the write sent again: %s %s" e.code e.message
   | _ -> C.check false "the write sent again: an unexpected reply");
  (* the old leader again: it follows and catches up *)
  pids.(l0) <- Serve.start bin cfgs.(l0);
  alive.(l0) <- true;
  wait_socket (sock l0);
  write_some w 50;
  let same () = List.for_all (fun db -> let g = group l1 db in List.for_all (fun k -> group k db = g) [ 0; 1; 2 ]) [ "main"; "side" ] in
  wait_for "the old leader catches up" same;
  C.check (stat l0 "raft.role" = "follower") "the old leader follows (main at %d)" (group l1 "main");
  let c0 = Result.get_ok (Config.load cfgs.(l0)) in
  let rdir = Filename.concat c0.data "raft" in
  C.check (mode c0.data = 0o700 && mode rdir = 0o700) "the data directory and its raft folder are 0700";
  C.check (mode (Filename.concat rdir "state") = 0o600) "the Raft state is 0600";
  C.check (List.for_all (fun f -> mode (Filename.concat rdir f) = 0o600) (List.filter (fun f -> String.length f > 4 && String.sub f 0 4 = "log.") (Array.to_list (Sys.readdir rdir)))) "the Raft log's segments are 0600";
  (* the peer port refuses *)
  let c1 = Result.get_ok (Config.load cfgs.(1)) in
  let target = List.nth c1.peers l1 in
  let refused what (c : Config.t) =
    match Replica.connect c target with
    | Error _ -> C.check true "%s" what
    | Ok l -> (
      match Replica.send l ~kind:Replica.k_raft (Buffer.create 1); Replica.expect l Replica.k_raft with
      | Ok _ -> Replica.close_link l; C.check false "%s: answered" what
      | Error _ | (exception (Replica.Broken _ | Codec.Short)) -> Replica.close_link l; C.check true "%s" what)
  in
  let with_tls (c : Config.t) ca cert key = { c with tls = Some { Config.ca; cert; key } } in
  let f d x = Filename.concat d x in
  refused "a certificate of another CA" (with_tls c1 (f other "ca.pem") (f other "srv2.pem") (f other "srv2.key"));
  refused "a certificate of the cluster's CA for a name no peer has" (with_tls { c1 with me = "intruder" } (f ca "ca.pem") (f ca "intruder.pem") (f ca "intruder.key"));
  let v = Replica.version in
  Replica.version_override := Some 1;
  (match Replica.connect c1 target with
   | Error m -> C.check (String.length m > 0) "a peer of protocol 1 is refused (%s)" m
   | Ok l -> Replica.close_link l; C.check false "a peer of protocol 1 was taken");
  Replica.version_override := None;
  ignore v;
  (* the reasoner's paths in a cluster: a load, a change of the rules (computed in the background on the leader)
     beside groups that count with one counter (Incr), a load past a Raft entry (8 MiB) refused whole; then the leader
     killed: the new one holds every group, each of them through the Raft log *)
  let sdb2, sps =
    match Client.declare w "side" [ prop "k" Tint; prop "k2" Tint; prop "t" Ttext; prop "c" Tint ] with
    | Ok (db, ps) -> db, ps
    | Error e -> failwith ("declare: " ^ e.message)
  in
  let[@warning "-8"] [ sk; sk2; st; sc ] = sps in
  let load = 30_000 in
  (match Client.write w sdb2 (List.init load (fun i -> Resolve.Add (-(i + 1), sk, Int (1_000_000 + i)))) with
   | Ok _ -> C.check true "a load of %d facts in the cluster" load
   | Error e -> C.check false "a load in the cluster: %s %s" e.code e.message);
  let counter = match Client.write w sdb2 [ Resolve.Add (-1, sc, Int 0) ] with Ok r -> List.assoc (-1) r.things | Error e -> failwith e.message in
  let w2 = match Client.connect ~session:779 ~ca:(Filename.concat ca "ca.pem") (tcp follower) wtext with Ok c -> c | Error m -> failwith m in
  let cdb = Result.get_ok (Client.open_db ~local:false w2 "side") in
  let counted = Atomic.make 0 and stop = Atomic.make false in
  let counting =
    Thread.create
      (fun () ->
        while not (Atomic.get stop) do
          match Client.write w2 cdb [ Resolve.Incr (counter, sc, 1, None) ] with
          | Ok _ -> Atomic.incr counted
          | Error e -> C.check false "an Incr in the cluster: %s %s" e.code e.message; Atomic.set stop true
        done)
      ()
  in
  let rid = Schema.first_thing - 100 in
  let copy : Cepheus.rule = { name = "copy"; vars = 2; where = [ { e = Var 0; p = sk; v = Var 1 } ]; ranges = []; head = Give { e = Var 0; p = sk2; v = Var 1 } } in
  (match Client.write w sdb2 [ Resolve.Add (rid, Schema.p_name, Text "copy"); Resolve.Add (rid, Schema.p_rule, Text (Rules.to_text copy)); Resolve.Expect (rid, Schema.p_name, None) ] with
   | Ok _ -> C.check true "a change of the rules in the cluster, beside %d Incr" (Atomic.get counted)
   | Error e -> C.check false "a change of the rules in the cluster: %s %s" e.code e.message);
  Thread.delay 0.2;
  Atomic.set stop true;
  Thread.join counting;
  Client.close w2;
  let rows p = match Client.find w sdb2 { Query.vars = 2; where = [ { Query.e = Var 0; p; v = Var 1 } ]; ranges = [] } with Ok (_, rows) -> List.length rows | Error _ -> -1 in
  let nk = rows sk in
  C.check (nk >= load && rows sk2 = nk) "the rule's consequences on the leader: %d of %d" (rows sk2) nk;
  (* a load past one Raft entry: refused whole, on every server *)
  let side_before = group (Option.get (leader ())) "side" in
  let text i = Printf.sprintf "%08d-%s" i (Digest.to_hex (Digest.string (string_of_int i))) in
  (match Client.write w sdb2 (List.init 260_000 (fun i -> Resolve.Add (-(i + 1), st, Text (text i)))) with
   | Error { code = "invalid"; message } ->
     let has m sub = let n = String.length sub in let rec go i = i + n <= String.length m && (String.sub m i n = sub || go (i + 1)) in go 0 in
     C.check (has message "over the frame limit of 8388608")
       "a load past 8 MiB in a cluster: refused (%s)" message
   | Error e -> C.check false "a load past 8 MiB: %s %s" e.code e.message
   | Ok _ -> C.check false "a load past 8 MiB was taken by a cluster");
  let same () = List.for_all (fun db -> let g = group (Option.get (leader ())) db in List.for_all (fun k -> not alive.(k) || group k db = g) [ 0; 1; 2 ]) [ "main"; "side" ] in
  wait_for "every server holds the leader's groups" same;
  let lk = Option.get (leader ()) in
  C.check (group lk "side" = side_before) "nothing of the refused load on any server (side at %d)" side_before;
  (* the leader killed: the new one holds the load, the change and its consequences, the counter *)
  let side_g = group lk "side" in
  Unix.kill pids.(lk) Sys.sigkill;
  ignore (Serve.wait pids.(lk));
  alive.(lk) <- false;
  wait_for "a new leader" (fun () -> match leader () with Some k -> k <> lk && stat k "raft.ready" = "true" | None -> false);
  let ln = Option.get (leader ()) in
  C.check (group ln "side" >= side_g) "the new leader %s holds side's groups (%d)" (List.nth names ln) side_g;
  C.check (rows sk = nk && rows sk2 = nk) "on the new leader: the load and the rule's consequences (%d)" nk;
  (match Client.get w sdb2 counter with
   | Ok (_, facts) -> C.check (List.assoc_opt sc facts = Some (Int (Atomic.get counted))) "on the new leader: the counter at %d" (Atomic.get counted)
   | Error e -> C.check false "the counter: %s" e.message);
  (match Client.find w sdb2 { Query.vars = 1; where = [ { Query.e = Var 0; p = st; v = Val (Text (text 7)) } ]; ranges = [] } with
   | Ok (_, rows) -> C.check (rows = []) "on the new leader: nothing of the refused load"
   | Error e -> C.check false "a read on the new leader: %s" e.message);
  pids.(lk) <- Serve.start bin cfgs.(lk);
  alive.(lk) <- true;
  wait_socket (sock lk);
  wait_for "the killed leader catches up" same;
  C.check true "the killed leader caught up (side at %d)" (group ln "side");
  Client.close w;
  Array.iteri (fun k c -> if alive.(k) then (C.check (run [ "stop"; "--config"; c ] = 0) "cepheus stop %s" (List.nth names k); ignore (Serve.wait pids.(k)))) cfgs;
  C.rmrf dir;
  C.finish "server raft"
