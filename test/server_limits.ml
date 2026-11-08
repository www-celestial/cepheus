(* The limits of a real server's connections: `cepheus cluster init` makes a cluster, its cluster.toml gets
   max_connections = 3 and idle_timeout = 1, a server runs it; then:
   - with three connections open, a fourth over the Unix socket gets the error frame too_many_connections and is
     closed, one over TCP is closed before any byte; once one of the three closes, a new one is served;
   - a connection that sends nothing, one that trickles a byte at a time without ever making a request, and one that
     stops in the middle of its TLS handshake are closed within twice the limit (the first two after an error frame
     idle); a client that pings more often than the limit stays connected;
   - a client left idle past the limit reads again: its library connects again by itself.

     server_limits.exe DIR *)

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

let unix_conn sock =
  let fd = Unix.socket ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.connect fd (Unix.ADDR_UNIX sock);
  fd

let tcp_conn port =
  let fd = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.connect fd (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
  fd

(* what the server sends until it closes (at most [secs] s): the error codes of its frames, and whether it closed *)
let until_closed fd secs =
  Unix.setsockopt_float fd Unix.SO_RCVTIMEO secs;
  let buf = Buffer.create 64 and b = Bytes.create 4096 in
  let rec go () =
    match Unix.read fd b 0 4096 with
    | 0 -> true
    | n -> Buffer.add_subbytes buf b 0 n; go ()
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> false
    | exception Unix.Unix_error (Unix.ECONNRESET, _, _) -> true
  in
  let closed = go () in
  let s = Buffer.to_bytes buf in
  let codes = ref [] and o = ref 0 in
  while Bytes.length s - !o >= Wire.header && Bytes.length s - !o >= 4 + Wire.u32 s !o do
    let len = Wire.u32 s !o in
    (match Wire.get_reply (Bytes.get_uint8 s (!o + 8)) (Bytes.get_uint8 s (!o + 9)) (Codec.reader s (!o + Wire.header) (len - 6)) with
     | Wire.Err e -> codes := e.code :: !codes
     | _ -> codes := "?" :: !codes
     | exception Codec.Short -> codes := "short" :: !codes);
    o := !o + 4 + len
  done;
  closed, List.rev !codes, Bytes.length s

let () =
  let dir = match Sys.argv with [| _; d |] -> d | _ -> prerr_endline "server_limits.exe DIR"; exit 2 in
  C.rmrf dir;
  Unix.mkdir dir 0o700;
  let a = Filename.concat dir "a" in
  C.check (run [ "cluster"; "init"; "limits"; "--dir"; a ] = 0) "cluster init";
  let cfg = Filename.concat a "cluster.toml" in
  let port = 20000 + ((Unix.getpid () + 7) mod 20000) in
  let s = In_channel.with_open_bin cfg In_channel.input_all in
  let s = replace s "127.0.0.1:7400" (Printf.sprintf "127.0.0.1:%d" port) in
  let s = replace s "[clients]\n" "[clients]\nmax_connections = 3\nidle_timeout = 1\n" in
  Out_channel.with_open_bin cfg (fun oc -> output_string oc s);
  let token = Filename.concat a "app.token" in
  C.check (Sys.command (Printf.sprintf "%s token add app --database main=write --config %s > %s" bin (Filename.quote cfg) (Filename.quote token)) = 0) "token add";
  let tok = String.trim (In_channel.with_open_bin token In_channel.input_all) in
  let pid = Unix.create_process bin [| bin; "serve"; "--config"; cfg |] Unix.stdin Unix.stdout Unix.stderr in
  let sock = Filename.concat a (Printf.sprintf "run/.s.cepheus.%d" port) in
  let t0 = Unix.gettimeofday () in
  while not (Sys.file_exists sock) && Unix.gettimeofday () -. t0 < 30. do Thread.delay 0.01 done;
  (* the limit: three connections held, a fourth refused, over the socket with a reason, over TCP before TLS *)
  let held = List.init 3 (fun _ -> unix_conn sock) in
  Thread.delay 0.1;
  let closed, codes, _ = until_closed (unix_conn sock) 2.0 in
  C.check (closed && codes = [ "too_many_connections" ]) "a fourth connection over the socket: too_many_connections, closed (%s)" (String.concat "," codes);
  let closed, _, n = until_closed (tcp_conn port) 2.0 in
  C.check (closed && n = 0) "a fourth connection over TCP: closed before any byte";
  (* idle: the three held are closed within twice the limit, each after the frame idle *)
  let t1 = Unix.gettimeofday () in
  List.iter
    (fun fd ->
      let closed, codes, _ = until_closed fd 3.0 in
      C.check (closed && codes = [ "idle" ]) "a silent connection: idle, closed (%s)" (String.concat "," codes);
      Unix.close fd)
    held;
  C.check (Unix.gettimeofday () -. t1 < 2.5) "the silent connections closed within twice the limit";
  (* room again: a client is served *)
  let c = match Client.connect (Client.Unix_socket sock) tok with Ok c -> c | Error m -> failwith m in
  let db = match Client.open_db c "main" with Ok db -> db | Error e -> failwith e.message in
  C.check (match Client.get c db 1 with Ok (_, f) -> f <> [] | Error _ -> false) "a client is served once there is room";
  (* a byte at a time, never a whole request: closed *)
  let fd = unix_conn sock in
  let t2 = Unix.gettimeofday () in
  (* a frame of 200 bytes announced, then its bytes one by one *)
  let trickle =
    Thread.create
      (fun () ->
        try
          ignore (Unix.write_substring fd "\200\000\000\000" 0 4);
          for _ = 1 to 12 do Thread.delay 0.25; ignore (Unix.write_substring fd "\001" 0 1) done
        with Unix.Unix_error _ -> ())
      ()
  in
  let closed, codes, _ = until_closed fd 4.0 in
  C.check (closed && codes = [ "idle" ] && Unix.gettimeofday () -. t2 < 2.6) "bytes that trickle without a request do not keep a connection (%s)" (String.concat "," codes);
  Thread.join trickle;
  Unix.close fd;
  (* a TLS handshake that stops after the TCP connection: closed *)
  let fd = tcp_conn port in
  let closed, _, n = until_closed fd 3.0 in
  C.check (closed && n = 0) "a TLS handshake that never starts is closed";
  Unix.close fd;
  (* pings more often than the limit keep a connection (a new one: the first has been idle meanwhile) *)
  Client.close c;
  let c = match Client.connect (Client.Unix_socket sock) tok with Ok c -> c | Error m -> failwith m in
  let db = match Client.open_db c "main" with Ok db -> db | Error e -> failwith e.message in
  let ok = ref true in
  for _ = 1 to 8 do
    Thread.delay 0.4;
    match Client.call c (Wire.Ping "x") with Wire.Pong "x" -> () | _ -> ok := false | exception Client.Broken _ -> ok := false
  done;
  C.check !ok "a client that pings every 0.4 s stays connected for 3.2 s";
  (* idle past the limit: the next read connects again by itself *)
  Thread.delay 2.2;
  C.check (match Client.get c db 1 with Ok (_, f) -> f <> [] | Error _ -> false | exception Client.Broken _ -> false) "a read after the idle limit: the library connects again";
  Client.close c;
  Unix.kill pid Sys.sigterm;
  (match Unix.waitpid [] pid with _, Unix.WEXITED 0 -> C.check true "a clean stop" | _ -> C.check false "not a clean stop");
  C.rmrf dir;
  ignore Value.equal;
  C.finish "server limits"
