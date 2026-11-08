(* TLS between programs and a real server. `cepheus cluster init` makes a cluster (its CA, the certificate of srv1
   for 127.0.0.1); a server runs it; then:
   - a client that trusts the cluster's CA and names 127.0.0.1 connects and reads;
   - one that trusts another cluster's CA is refused at the handshake (the server's certificate does not check);
   - a server whose certificate (of the same CA) does not hold the name the client uses is refused by the client;
   - one that expects another cluster id is refused after Welcome;
   - a plain TCP client on the TLS port gets no reply: the server drops it;
   and the server goes on serving good clients after all of them. Also: listen without [tls] is refused.

     server_tls.exe DIR *)

open Cepheus
open Cepheus_server
module C = Check

let bin = Filename.concat (Filename.dirname (Filename.dirname Sys.executable_name)) "bin/main.exe"

let run args = Sys.command (String.concat " " (List.map Filename.quote (bin :: args)) ^ " > /dev/null")

let replace s a b =
  let la = String.length a in
  let buf = Buffer.create (String.length s) in
  let i = ref 0 in
  while !i < String.length s do
    if !i + la <= String.length s && String.sub s !i la = a then (Buffer.add_string buf b; i := !i + la)
    else (Buffer.add_char buf s.[!i]; incr i)
  done;
  Buffer.contents buf

let wait_port port =
  let t0 = Unix.gettimeofday () in
  let rec go () =
    let s = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    match Unix.connect s (Unix.ADDR_INET (Unix.inet_addr_loopback, port)) with
    | () -> Unix.close s
    | exception Unix.Unix_error _ ->
      Unix.close s;
      if Unix.gettimeofday () -. t0 > 30. then failwith "the server did not start";
      Thread.delay 0.01;
      go ()
  in
  go ()

let () =
  let dir = match Sys.argv with [| _; d |] -> d | _ -> prerr_endline "server_tls.exe DIR"; exit 2 in
  C.rmrf dir;
  Unix.mkdir dir 0o700;
  let a = Filename.concat dir "a" and b = Filename.concat dir "b" in
  C.check (run [ "cluster"; "init"; "tls-a"; "--dir"; a ] = 0) "cluster init a";
  C.check (run [ "cluster"; "init"; "tls-b"; "--dir"; b ] = 0) "cluster init b";
  C.check (Sys.file_exists (Filename.concat a "ca.pem") && Sys.file_exists (Filename.concat a "srv1.key")) "the CA and srv1's files";
  C.check ((Unix.stat (Filename.concat a "srv1.key")).st_perm land 0o077 = 0) "a key readable by its owner only";
  C.check (run [ "cluster"; "init"; "tls-a"; "--dir"; a ] <> 0) "cluster init refuses an existing cluster";
  let cfg = Filename.concat a "cluster.toml" in
  (* a port of its own: 7400 + the pid's last digits *)
  let port = 20000 + (Unix.getpid () mod 20000) in
  let s = In_channel.with_open_bin cfg In_channel.input_all in
  let s = replace s "127.0.0.1:7400" (Printf.sprintf "127.0.0.1:%d" port) in
  Out_channel.with_open_bin cfg (fun oc -> output_string oc s);
  let token = Filename.concat a "app.token" in
  C.check (Sys.command (Printf.sprintf "%s token add app --database main=write --config %s > %s" bin (Filename.quote cfg) (Filename.quote token)) = 0) "token add";
  let tok = String.trim (In_channel.with_open_bin token In_channel.input_all) in
  let pid = Unix.create_process bin [| bin; "serve"; "--config"; cfg |] Unix.stdin Unix.stdout Unix.stderr in
  wait_port port;
  let ca_a = Filename.concat a "ca.pem" and ca_b = Filename.concat b "ca.pem" in
  let good host =
    match Client.connect ~ca:ca_a (Client.Tcp (host, port)) tok with
    | Error m -> C.check false "a good client (%s): %s" host m
    | Ok c ->
      (match Client.open_db c "main" with
       | Ok db -> C.check (match Client.get c db 1 with Ok (_, facts) -> facts <> [] | Error _ -> false) "a read over TLS (%s)" host
       | Error e -> C.check false "open over TLS: %s" e.message);
      Client.close c
  in
  good "127.0.0.1";
  let refused what f =
    match f () with
    | Ok c -> Client.close c; C.check false "%s: accepted" what
    | Error m -> C.check true "%s" what; ignore m
  in
  refused "another cluster's CA is refused" (fun () -> Client.connect ~ca:ca_b (Client.Tcp ("127.0.0.1", port)) tok);
  refused "another cluster id is refused" (fun () -> Client.connect ~ca:ca_a ~cluster:"cph-c-ffffffffffffffff" (Client.Tcp ("127.0.0.1", port)) tok);
  refused "a TCP connection without a CA is refused" (fun () -> Client.connect (Client.Tcp ("127.0.0.1", port)) tok);
  (* a plain client: the server waits for a TLS ClientHello, gets a Hello frame, drops the connection *)
  (let fd = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
   Unix.connect fd (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
   let b = Buffer.create 64 and f = Buffer.create 64 in
   Wire.put_request b (Wire.Hello { version = Wire.version; token = tok; program = "plain"; session = 0 });
   Wire.add_frame f ~id:1 ~kind:Wire.k_hello ~flags:0 b;
   let s = Buffer.to_bytes f in
   ignore (Unix.write fd s 0 (Bytes.length s));
   let r = Bytes.create 64 in
   let n = try Unix.read fd r 0 64 with Unix.Unix_error _ -> 0 in
   (* a TLS alert, or nothing: never a Welcome *)
   C.check (n = 0 || Bytes.get_uint8 r 0 = 0x15) "a plain client on the TLS port gets no Welcome";
   Unix.close fd);
  good "127.0.0.1";
  Unix.kill pid Sys.sigterm;
  ignore (Unix.waitpid [] pid);
  (* the same CA, another name: srv2's certificate is for 10.9.9.9 only; a client that names 127.0.0.1 refuses it *)
  C.check (run [ "cluster"; "cert"; "srv2"; "--dir"; a; "--host"; "10.9.9.9" ] = 0) "cluster cert srv2";
  let s = In_channel.with_open_bin cfg In_channel.input_all in
  Out_channel.with_open_bin cfg (fun oc -> output_string oc (replace (replace s "srv1.pem" "srv2.pem") "srv1.key" "srv2.key"));
  let pid = Unix.create_process bin [| bin; "serve"; "--config"; cfg |] Unix.stdin Unix.stdout Unix.stderr in
  wait_port port;
  refused "a certificate without the name the client uses is refused" (fun () -> Client.connect ~ca:ca_a (Client.Tcp ("127.0.0.1", port)) tok);
  Unix.kill pid Sys.sigterm;
  ignore (Unix.waitpid [] pid);
  (* listen without [tls] *)
  let plain = Filename.concat dir "plain.toml" in
  Out_channel.with_open_bin plain (fun oc ->
      output_string oc
        "[cluster]\nname = \"p\"\nid = \"cph-c-0000000000000001\"\nme = \"srv1\"\n[[peer]]\nname = \"srv1\"\naddress = \"127.0.0.1:1\"\n\
         [clients]\nlisten = \"127.0.0.1:7999\"\n[storage]\ndata = \"pdata\"\n[[database]]\nname = \"main\"\n");
  C.check (match Config.load plain with Error _ -> true | Ok _ -> false) "listen without [tls] is refused";
  C.rmrf dir;
  ignore Value.equal;
  C.finish "server tls"
