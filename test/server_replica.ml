(* A replica between two real servers on this machine, over mutual TLS on loopback. `cepheus cluster init` makes the
   CA and srv1's certificate, `cluster cert` srv2's and an intruder's (of the same CA, a name no [[peer]] has), a
   second cluster its own CA; srv1 and srv2 share one cluster.toml but for `me`. Then:
   - a server refuses a peer port without [tls]; `cepheus replicate` refuses a running server, an unknown peer, itself;
   - srv2, made a replica of srv1 (its role file 0600), copies srv1's databases from nothing while a program writes
     to srv1, and holds every group, the same groups; it refuses writes (read_only) and serves reads;
   - killed (kill -9) while writes go on, it starts again and catches up;
   - a change of the rules on the primary (in its background) and a load on the path of loads with the rule's
     consequences: the replica holds both, read there;
   - the peer port refuses a certificate of another CA, one of the cluster's CA for a name that is no other peer
     (srv1's own, the intruder's), and a peer of another cluster id; a replica of an unknown database is refused;
   - a promotion while srv1 sends is refused, and so is one without the handover after srv1 was killed; srv1's clean
     stop hands every group over; `cepheus promote` then makes srv2 a primary: every group srv1 confirmed is there,
     a write resent in its session gets its first receipt (G14), new writes are taken in epoch 2;
   - an old primary that asks at start (Replica.check_peers) learns that srv2 holds a newer epoch;
   - srv1, made a replica of srv2, follows it from where it stopped (its history a prefix) and both hold the same
     groups; its files 0600, its data directory 0700.

     server_replica.exe DIR *)

open Cepheus
open Cepheus_server
module C = Check

let bin = Filename.concat (Filename.dirname (Filename.dirname Sys.executable_name)) "bin/main.exe"
let run args = Sys.command (String.concat " " (List.map Filename.quote (bin :: args)) ^ " > /dev/null 2>&1")
let write_file path s = Out_channel.with_open_bin path (fun oc -> output_string oc s)

let wait_for what f =
  let t0 = Unix.gettimeofday () in
  let rec go () = if f () then () else if Unix.gettimeofday () -. t0 > 60. then failwith ("timed out: " ^ what) else (Thread.delay 0.02; go ()) in
  go ()

let wait_socket sock =
  wait_for "the server's socket" (fun () ->
      let s = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      let ok = match Unix.connect s (Unix.ADDR_UNIX sock) with () -> true | exception Unix.Unix_error _ -> false in
      Unix.close s;
      ok)

let mode path = (Unix.stat path).st_perm land 0o777

let () =
  let dir = match Sys.argv with [| _; d |] -> d | _ -> prerr_endline "server_replica.exe DIR"; exit 2 in
  C.rmrf dir;
  Unix.mkdir dir 0o700;
  let ca = Filename.concat dir "ca" and other = Filename.concat dir "other" in
  C.check (run [ "cluster"; "init"; "rep"; "--dir"; ca ] = 0) "cluster init";
  C.check (run [ "cluster"; "cert"; "srv2"; "--dir"; ca ] = 0) "cluster cert srv2";
  C.check (run [ "cluster"; "cert"; "intruder"; "--dir"; ca ] = 0) "cluster cert intruder";
  C.check (run [ "cluster"; "init"; "other"; "--dir"; other ] = 0) "another cluster";
  C.check (run [ "cluster"; "cert"; "srv2"; "--dir"; other ] = 0) "another cluster's srv2";
  let id = String.trim (List.hd (List.filter (fun l -> String.length l > 5 && String.sub l 0 5 = "id = ") (String.split_on_char '\n' (In_channel.with_open_bin (Filename.concat ca "cluster.toml") In_channel.input_all)))) in
  let id = String.sub id 6 (String.length id - 7) in
  let base = 20000 + (Unix.getpid () mod 15000) in
  let p1 = base and p2 = base + 1 in
  let config me =
    let d = Filename.concat dir me in
    Unix.mkdir d 0o700;
    Unix.mkdir (Filename.concat d "run") 0o700;
    let f = Filename.concat d "cluster.toml" in
    write_file f
      (Printf.sprintf
         "[cluster]\nname = \"rep\"\nid = %S\nme = %S\n[[peer]]\nname = \"srv1\"\naddress = \"127.0.0.1:%d\"\n[[peer]]\nname = \"srv2\"\naddress = \"127.0.0.1:%d\"\n\
          [clients]\nsocket = \"run\"\ndomains = 1\n[tls]\nca = \"%s/ca.pem\"\ncert = \"%s/%s.pem\"\nkey = \"%s/%s.key\"\n\
          [storage]\ndata = \"data\"\ncache = \"64M\"\n[[database]]\nname = \"main\"\n[[database]]\nname = \"side\"\n"
         id me p1 p2 ca ca me ca me);
    f
  in
  let cfg1 = config "srv1" and cfg2 = config "srv2" in
  let c1 = Result.get_ok (Config.load cfg1) and c2 = Result.get_ok (Config.load cfg2) in
  (* several peers need [tls] *)
  let plain = Filename.concat dir "plain.toml" in
  write_file plain
    (Printf.sprintf "[cluster]\nname = \"p\"\nid = %S\nme = \"srv1\"\n[[peer]]\nname = \"srv1\"\naddress = \"127.0.0.1:1\"\n[[peer]]\nname = \"srv2\"\naddress = \"127.0.0.1:2\"\n[clients]\nsocket = \"run\"\n[storage]\ndata = \"pdata\"\n[[database]]\nname = \"main\"\n" id);
  C.check (match Config.load plain with Error _ -> true | Ok _ -> false) "two peers without [tls] are refused";
  let wtext, whash = Tokens.generate () and atext, ahash = Tokens.generate () in
  let toks = Tokens.with_tokens Tokens.empty
      [ { Tokens.name = "w"; hash = whash; databases = [ "main", Tokens.Write; "side", Tokens.Write ]; admin = false };
        { Tokens.name = "a"; hash = ahash; databases = []; admin = true } ] in
  List.iter (fun c -> Tokens.save (Filename.concat (Filename.dirname c) "tokens.toml") toks) [ cfg1; cfg2 ];
  let sock me = Filename.concat dir (me ^ "/run/.s.cepheus.7400") in
  let status me =
    match Client.connect (Client.Unix_socket (sock me)) atext with
    | Error m -> failwith m
    | Ok c -> Fun.protect ~finally:(fun () -> Client.close c) (fun () -> match Client.status c with Ok l -> l | Error e -> failwith e.message)
  in
  let stat me k = match List.assoc_opt k (status me) with Some v -> v | None -> "" in
  let group me db = int_of_string (stat me ("database." ^ db ^ ".group")) in
  let a1 = Serve.start bin cfg1 in
  wait_socket (sock "srv1");
  let pid1 = ref a1 in
  (* a program writes to srv1 *)
  let w = Result.get_ok (Client.connect (Client.Unix_socket (sock "srv1")) wtext) in
  let declare c name = match Client.declare c name [ prop "k" Tint ] with Ok (db, [ p ]) -> db, p | _ -> failwith "declare" in
  let mdb, mp = declare w "main" in
  let sdb, sp = declare w "side" in
  let writes = ref 0 in
  let write_some c n =
    for _ = 1 to n do
      incr writes;
      (match Client.write c mdb [ Resolve.Add (-1, mp, Int !writes) ] with Ok _ -> () | Error e -> C.check false "a write: %s" e.message);
      if !writes mod 3 = 0 then ignore (Client.write c sdb [ Resolve.Add (-1, sp, Int !writes) ])
    done
  in
  write_some w 200;
  (* cepheus replicate: never on a running server, a peer it knows, not itself *)
  C.check (run [ "replicate"; "srv2"; "--config"; cfg1 ] <> 0) "replicate refuses a running server";
  C.check (run [ "replicate"; "srv9"; "--config"; cfg2 ] <> 0) "replicate refuses an unknown peer";
  C.check (run [ "replicate"; "srv2"; "--config"; cfg2 ] <> 0) "replicate refuses the server itself";
  C.check (run [ "replicate"; "srv1"; "--config"; cfg2 ] = 0) "cepheus replicate srv1";
  let role2 = Replica.role_path c2.data in
  C.check (mode role2 = 0o600) "the role file is 0600";
  C.check (mode c2.data = 0o700) "the replica's data directory is 0700";
  let pid2 = ref (Serve.start bin cfg2) in
  wait_socket (sock "srv2");
  (* it copies from nothing while srv1 is written *)
  let wt = Thread.create (fun () -> write_some w 300) () in
  Thread.join wt;
  let caught_up () = group "srv2" "main" = group "srv1" "main" && group "srv2" "side" = group "srv1" "side" in
  wait_for "the replica catches up" caught_up;
  C.check true "the replica holds every group of srv1 (%d)" (group "srv1" "main");
  C.check (stat "srv2" "role" = "replica of srv1") "status: role";
  wait_for "the primary's status names its replica" (fun () -> stat "srv1" "database.main.replica.srv2.group" = string_of_int (group "srv1" "main"));
  C.check true "the primary's status names its replica and the group it holds";
  (* writes refused, reads served *)
  let r = Result.get_ok (Client.connect (Client.Unix_socket (sock "srv2")) wtext) in
  let rdb = Result.get_ok (Client.open_db r "main") in
  (match Client.write r rdb [ Resolve.Add (-1, mp, Int 0) ] with
   | Error { code = "read_only"; message } -> C.check (String.length message > 0) "a write to the replica: read_only (%s)" message
   | Error e -> C.check false "a write to the replica: %s %s" e.code e.message
   | Ok _ -> C.check false "a write to the replica was taken");
  (match Client.get r rdb (Schema.first_thing + 1) with
   | Ok (_, facts) -> C.check (facts <> []) "a read on the replica"
   | Error e -> C.check false "a read on the replica: %s" e.message);
  Client.close r;
  (* killed while writes go on, it catches up *)
  let wt = Thread.create (fun () -> write_some w 300) () in
  Thread.delay 0.05;
  Unix.kill !pid2 Sys.sigkill;
  ignore (Serve.wait !pid2);
  Thread.join wt;
  pid2 := Serve.start bin cfg2;
  wait_socket (sock "srv2");
  wait_for "the replica catches up after kill -9" caught_up;
  C.check true "the replica caught up after kill -9 (%d)" (group "srv1" "main");
  (* a change of the rules on the primary (computed in its background), then a load past a large group's size (the
     path of loads, its frame written by pieces, the rule's consequences in it): the replica holds both, read there *)
  let sdb2, sps = match Client.declare w "side" [ prop "k" Tint; prop "k2" Tint ] with Ok (db, ps) -> db, ps | Error e -> failwith ("declare: " ^ e.message) in
  let[@warning "-8"] [ sk; sk2 ] = sps in
  let rid = Schema.first_thing - 100 in
  let copy : Cepheus.rule = { name = "copy"; vars = 2; where = [ { e = Var 0; p = sk; v = Var 1 } ]; ranges = []; head = Give { e = Var 0; p = sk2; v = Var 1 } } in
  (match Client.write w sdb2 [ Resolve.Add (rid, Schema.p_name, Text "copy"); Resolve.Add (rid, Schema.p_rule, Text (Rules.to_text copy)); Resolve.Expect (rid, Schema.p_name, None) ] with
   | Ok _ -> C.check true "a change of the rules on the primary"
   | Error e -> C.check false "a change of the rules on the primary: %s %s" e.code e.message);
  let load = 25_000 in
  (match Client.write w sdb2 (List.init load (fun i -> Resolve.Add (-(i + 1), sk, Int (1_000_000 + i)))) with
   | Ok _ -> C.check true "a load of %d facts on the primary" load
   | Error e -> C.check false "a load on the primary: %s %s" e.code e.message);
  wait_for "the replica catches up after the change and the load" caught_up;
  let rows c db p = match Client.find c db { Query.vars = 2; where = [ { Query.e = Var 0; p; v = Var 1 } ]; ranges = [] } with Ok (_, rows) -> List.length rows | Error _ -> -1 in
  let nk = rows w sdb2 sk in
  C.check (nk >= load && rows w sdb2 sk2 = nk) "the primary: the load and the rule's consequences (%d)" nk;
  let r = Result.get_ok (Client.connect (Client.Unix_socket (sock "srv2")) wtext) in
  let rdb = Result.get_ok (Client.open_db r "side") in
  C.check (rows r rdb sk = nk && rows r rdb sk2 = nk) "the replica: the load and the rule's consequences, read there (%d)" (rows r rdb sk2);
  Client.close r;
  (* the peer port refuses: another CA, a name that is no other peer, another cluster id, an unknown database *)
  let with_tls (c : Config.t) ca cert key = { c with tls = Some { Config.ca; cert; key } } in
  let f d x = Filename.concat d x in
  let p1peer = Option.get (Replica.peer_of c1 "srv1") in
  let refused what (c : Config.t) =
    match Replica.connect c p1peer with
    | Error _ -> C.check true "%s" what
    | Ok l -> (
      (* the handshake may pass on this side: the server then closes before any answer *)
      match Replica.send l ~kind:Replica.k_epochs (Buffer.create 1); Replica.expect l Replica.k_epochs with
      | Ok _ -> Replica.close_link l; C.check false "%s: answered" what
      | Error _ | (exception (Replica.Broken _ | Codec.Short)) -> Replica.close_link l; C.check true "%s" what)
  in
  refused "a certificate of another CA" (with_tls c2 (f other "ca.pem") (f other "srv2.pem") (f other "srv2.key"));
  refused "srv1's own certificate" (with_tls c2 (f ca "ca.pem") (f ca "srv1.pem") (f ca "srv1.key"));
  refused "a certificate of the cluster's CA for a name no peer has" (with_tls c2 (f ca "ca.pem") (f ca "intruder.pem") (f ca "intruder.key"));
  refused "another cluster id" { c2 with id = "cph-c-ffffffffffffffff" };
  (match Replica.primary_id c2 p1peer "nothing" with
   | Error _ -> C.check true "a replica of an unknown database is refused"
   | Ok _ -> C.check false "a replica of an unknown database");
  (* promotion: refused while srv1 sends; after srv1's kill -9, refused without --force *)
  let promote ?(force = false) () =
    Sys.command (Printf.sprintf "CEPHEUS_TOKEN=%s %s promote %s--config %s > /dev/null 2>&1" atext (Filename.quote bin) (if force then "--force " else "") (Filename.quote cfg2))
  in
  C.check (promote () <> 0) "a promotion while the primary sends is refused";
  Unix.kill !pid1 Sys.sigkill;
  ignore (Serve.wait !pid1);
  wait_for "the replica sees the primary gone" (fun () -> stat "srv2" "database.main.replica.connected" = "false");
  C.check (promote () <> 0) "a promotion without the handover is refused (without --force)";
  (* srv1 again, written, then stopped cleanly: it hands every group over *)
  pid1 := Serve.start bin cfg1;
  wait_socket (sock "srv1");
  Client.close w;
  let w = Result.get_ok (Client.connect ~session:4242 (Client.Unix_socket (sock "srv1")) wtext) in
  write_some w 100;
  let last_receipt = match Client.write w mdb [ Resolve.Add (-1, mp, Int 999_999) ] with Ok r -> r | Error e -> failwith e.message in
  let last_serial = w.serial in
  let final_main = group "srv1" "main" and final_side = group "srv1" "side" in
  Client.close w;
  wait_for "the replica follows the restarted primary" caught_up;
  C.check (run [ "stop"; "--config"; cfg1 ] = 0) "cepheus stop srv1";
  ignore (Serve.wait !pid1);
  wait_for "the handover" (fun () -> stat "srv2" "database.main.replica.handover" = string_of_int final_main && stat "srv2" "database.side.replica.handover" = string_of_int final_side);
  C.check true "srv1's clean stop handed over main at %d and side at %d" final_main final_side;
  C.check (mode (Filename.concat (Config.database_dir c2 "main") "handover") = 0o600) "the handover file is 0600";
  C.check (promote () = 0) "cepheus promote";
  C.check (stat "srv2" "role" = "primary (promoted from srv1)") "status: promoted";
  C.check (group "srv2" "main" = final_main && group "srv2" "side" = final_side) "no confirmed group missing after the promotion";
  C.check (stat "srv2" "database.main.epoch" = "2") "epoch 2";
  C.check (mode (Filename.concat (Config.database_dir c2 "main") "epochs") = 0o600) "the epochs file is 0600";
  (* G14 across the promotion: the last write, sent again in its session, gets its first receipt *)
  let w2 = Result.get_ok (Client.connect ~session:4242 (Client.Unix_socket (sock "srv2")) wtext) in
  (match Client.call w2 (Wire.Write { db = mdb.handle; serial = last_serial; floor = last_serial; by = 0; why = ""; ops = [ Resolve.Add (-1, mp, Int 999_999) ] }) with
   | Wire.Receipt rc -> C.check (rc.group = last_receipt.group) "a write sent again after the promotion gets its first receipt (group %d)" rc.group
   | Wire.Err e -> C.check false "the write sent again: %s %s" e.code e.message
   | _ -> C.check false "the write sent again: an unexpected reply");
  Client.close w2;
  let w3 = Result.get_ok (Client.connect (Client.Unix_socket (sock "srv2")) wtext) in
  write_some w3 50;
  C.check (group "srv2" "main" > final_main) "the promoted server takes writes";
  (* the old primary, asking at its start, would learn that srv2 holds a newer epoch *)
  (match Replica.check_peers c1 [ "main", Replica.first_epochs; "side", Replica.first_epochs ] with
   | Error m -> C.check true "an old primary is told at start that srv2 was promoted (%s)" (String.sub m 0 (min 40 (String.length m)))
   | Ok () -> C.check false "an old primary was not told of the promotion");
  (* srv1 follows srv2 *)
  C.check (run [ "replicate"; "srv2"; "--config"; cfg1 ] = 0) "cepheus replicate srv2 (the old primary)";
  pid1 := Serve.start bin cfg1;
  wait_socket (sock "srv1");
  write_some w3 50;
  wait_for "the old primary follows the new one" (fun () -> group "srv1" "main" = group "srv2" "main" && group "srv1" "side" = group "srv2" "side");
  C.check true "the old primary holds the new primary's groups (%d)" (group "srv2" "main");
  Client.close w3;
  (* the same groups, byte for byte: both journals read *)
  C.check (run [ "stop"; "--config"; cfg1 ] = 0 && run [ "stop"; "--config"; cfg2 ] = 0) "both stopped";
  ignore (Serve.wait !pid1);
  ignore (Serve.wait !pid2);
  List.iter
    (fun db ->
      let read c =
        let d = Config.database_dir c db in
        let l = ref [] in
        Journal.read Disk.real (Filename.concat d "journal") (Engine.read_meta Disk.real d) (fun g -> l := g :: !l);
        !l
      in
      let a = read c1 and b = read c2 in
      C.check (List.length a = List.length b && List.for_all2 Group.equal a b) "%s: the two journals hold the same %d groups" db (List.length b))
    [ "main"; "side" ];
  List.iter (fun db -> try Sys.remove (Follow.page_of_dir (Config.database_dir c2 db)) with Sys_error _ -> ()) [ "main"; "side" ];
  List.iter (fun db -> try Sys.remove (Follow.page_of_dir (Config.database_dir c1 db)) with Sys_error _ -> ()) [ "main"; "side" ];
  C.rmrf dir;
  ignore Value.equal;
  C.finish "server replica"
