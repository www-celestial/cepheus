(* The limits of a real server's connections: `cepheus cluster init` makes a cluster, its cluster.toml gets
   max_connections = 3 and idle_timeout = 1, a server runs it; then:
   - with three connections open, a fourth over the Unix socket gets the error frame too_many_connections and is
     closed, one over TCP is closed before any byte; once one of the three closes, a new one is served;
   - a connection that sends nothing, one that trickles a byte at a time without ever making a request, and one that
     stops in the middle of its TLS handshake are closed within twice the limit (the first two after an error frame
     idle); a client that pings more often than the limit stays connected;
   - a client left idle past the limit reads again: its library connects again by itself.
   Before the limits, with the defaults: a watch on a connection that never reads holds nobody (the watch beside it
   gets every change, each within a second of its write), and its unsent pushes are bounded: its watch ends lagging.

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

let contains s sub =
  let n = String.length sub in
  let rec go i = i + n <= String.length s && (String.sub s i n = sub || go (i + 1)) in
  go 0

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

(* A watcher that never reads beside one that reads: notes of 4,000 bytes, 50 a group, 60 groups (12 MB of changes, over
   the 8 MiB a connection may hold unsent). The reader gets every group's change, in order, each within a second of
   its write's receipt; the silent one, read at the end, has the answer, fewer changes than groups, then lagging. *)
let stall sock tok =
  let groups = 60 and text = String.make 4000 'x' in
  let conn () = match Client.connect (Client.Unix_socket sock) tok with Ok c -> c | Error m -> failwith m in
  let w = conn () in
  let prop name typ = { Schema.name; typ; many = false; unique = false } in
  let db, pt = match Client.declare w "main" [ prop "note/text" Value.Ttext ] with Ok (db, [ p ]) -> db, p | _ -> failwith "declare" in
  let q = { Query.vars = 2; where = [ { Query.e = Var 0; p = pt; v = Var 1 } ]; ranges = [] } in
  let watcher () =
    let c = conn () in
    let d = match Client.open_db ~local:false c "main" with Ok d -> d | Error e -> failwith e.message in
    c, Client.watch c d q
  in
  let r, rid = watcher () and s, sid = watcher () in
  let m = Mutex.create () and seen = Hashtbl.create 64 and order = ref true and last = ref 0 in
  let reader =
    Thread.create
      (fun () ->
        (* a change a group: it stops at the last *)
        let rec go k =
          if k > 0 then
            match Client.next_push r rid with
            | Client.Pushed (Wire.Change ch) ->
              Mutex.protect m (fun () -> if ch.group <= !last then order := false; last := ch.group; Hashtbl.replace seen ch.group (Unix.gettimeofday ()));
              go (k - 1)
            | Client.Pushed _ -> go k
            | Client.Ended _ | (exception Client.Broken _) -> ()
        in
        go groups)
      ()
  in
  Thread.delay 0.2;
  let receipts =
    List.init groups (fun k ->
        let ops = List.init 50 (fun j -> Resolve.Add (-(j + 1), pt, Value.Text (Printf.sprintf "%d %d %s" k j text))) in
        match Client.write w db ops with Ok g -> g.group, Unix.gettimeofday () | Error e -> failwith e.message)
  in
  let final = fst (List.nth receipts (groups - 1)) in
  let t0 = Unix.gettimeofday () in
  while Mutex.protect m (fun () -> !last < final) && Unix.gettimeofday () -. t0 < 10. do Thread.delay 0.01 done;
  let late =
    Mutex.protect m (fun () ->
        List.fold_left (fun acc (g, t) -> match Hashtbl.find_opt seen g with Some t' when t' -. t < 1.0 -> acc | _ -> acc + 1) 0 receipts)
  in
  let all = Mutex.protect m (fun () -> !order && late = 0) in
  C.check all "beside a watcher that never reads, a watcher gets every change in order, each within a second (%d late or missing)" late;
  let rec silent changes =
    match Client.next_push s sid with
    | Client.Pushed (Wire.Change _) -> silent (changes + 1)
    | Client.Pushed _ -> silent changes
    | Client.Ended e -> changes, e.code
    | exception Client.Broken m -> changes, "broken: " ^ m
  in
  let changes, code = silent 0 in
  C.check (changes < groups && code = "lagging") "a watcher that never read: %d changes of %d, then %s (lagging)" changes groups code;
  (* the reader has stopped at the last group (else the test failed and its thread is left) *)
  if all then Thread.join reader;
  Client.close r;
  Client.close s;
  Client.close w

(* Questions under load, on a server of 200 databases (each a writer and a syncer, in the writers' domains: before,
   a domain each, which the runtime's cap of 128 stopped at about 120): every database opens and is served, and the
   process holds fewer domains than the cap; 30 programs ask a large question each at once (60,000 things, its first
   variable split among domains): each gets its exact answer, none internal, and the helpers stay within the pool;
   a question given 0.1 s of a cross product ends timeout within 0.3 s; a program that sends a question that takes
   seconds and closes its connection stops it: the server counts it cancelled within a second (its log has no
   failure). *)
let load sock tok admin =
  let conn t = match Client.connect (Client.Unix_socket sock) t with Ok c -> c | Error m -> failwith m in
  let stat c k = match Client.status c with Ok l -> (try List.assoc k l with Not_found -> "") | Error e -> "error " ^ e.message in
  let ops = conn admin in
  let dbs = int_of_string_opt (stat ops "domains") and cap = int_of_string_opt (stat ops "domains.cap") in
  C.check (match dbs, cap with Some d, Some c -> d < c | _ -> false) "200 databases open on %s domains, under the cap of %s" (stat ops "domains") (stat ops "domains.cap");
  let w = conn tok in
  let prop name = { Schema.name; typ = Value.Tint; many = false; unique = false } in
  (* every database served *)
  let ok = ref 0 in
  for i = 0 to 199 do
    match Client.declare w (Printf.sprintf "d%d" i) [ prop "x/n" ] with
    | Ok (db, [ p ]) -> (match Client.write w db [ Resolve.Add (-1, p, Int i) ] with Ok _ -> incr ok | Error _ -> ())
    | _ -> ()
  done;
  C.check (!ok = 200) "each of the 200 databases takes a write (%d)" !ok;
  let db, a, b = match Client.declare w "main" [ prop "load/a"; prop "load/b" ] with Ok (db, [ a; b ]) -> db, a, b | _ -> failwith "declare" in
  let n = 60_000 in
  let rec fill i = if i < n then begin
      let k = min 5000 (n - i) in
      (match Client.write w db (List.concat (List.init k (fun j -> [ Resolve.Add (-(j + 1), a, Int (i + j)); Resolve.Add (-(j + 1), b, Int ((i + j) mod 7)) ]))) with
       | Ok _ -> () | Error e -> failwith e.message);
      fill (i + k) end in
  fill 0;
  let q = { Query.vars = 3; where = [ { Query.e = Var 0; p = a; v = Var 1 }; { e = Var 0; p = b; v = Var 2 } ]; ranges = [] } in
  let sel = Wire.Group ([| 2 |], [| Wire.Count |]) in
  let results = Array.make 30 "none" in
  let threads =
    Array.init 30 (fun i ->
        Thread.create
          (fun () ->
            let c = conn tok in
            let d = match Client.open_db ~local:false c "main" with Ok d -> d | Error e -> failwith e.message in
            results.(i) <-
              (match Client.find c d ~select:sel q with
               | Ok (_, rows) when List.length rows = 7 && List.for_all (function [| _; Value.Int k |] -> k >= n / 7 | _ -> false) rows -> "ok"
               | Ok (_, rows) -> Printf.sprintf "%d rows" (List.length rows)
               | Error e -> e.code);
            Client.close c)
          ())
  in
  let t30 = Unix.gettimeofday () in
  Array.iter Thread.join threads;
  let t30 = Unix.gettimeofday () -. t30 in
  let bad = List.filter (( <> ) "ok") (Array.to_list results) in
  C.check (bad = []) "30 large questions at once: each its exact answer, none internal (%s)" (String.concat "," bad);
  C.check (match int_of_string_opt (stat ops "questions.helpers") with Some h -> h < Domain.recommended_domain_count () | None -> false)
    "the questions' helpers within the pool (%s)" (stat ops "questions.helpers");
  (* a program's time *)
  let cross = { Query.vars = 6; where = [ { Query.e = Var 0; p = a; v = Var 1 }; { e = Var 2; p = a; v = Var 3 }; { e = Var 4; p = a; v = Var 5 } ]; ranges = [] } in
  let c = conn tok in
  let d = match Client.open_db ~local:false c "main" with Ok d -> d | Error e -> failwith e.message in
  let t0 = Unix.gettimeofday () in
  let r = Client.find c d ~select:(Wire.Group ([||], [| Wire.Count |])) ~timeout:0.1 cross in
  let took0 = Unix.gettimeofday () -. t0 in
  C.check ((match r with Error e -> e.code = "timeout" | Ok _ -> false) && took0 < 0.3) "a cross product given 0.1 s: timeout (%.3f s)" took0;
  Client.close c;
  (* a question whose program leaves *)
  let before = stat ops "questions.cancelled" in
  let fd = Unix.socket ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.connect fd (Unix.ADDR_UNIX sock);
  let send id req =
    let body = Buffer.create 64 and f = Buffer.create 64 in
    Wire.put_request body req;
    Wire.add_frame f ~id ~kind:(Wire.request_kind req) ~flags:0 body;
    ignore (Unix.write_substring fd (Buffer.contents f) 0 (Buffer.length f))
  in
  send 1 (Wire.Hello { version = Wire.version; token = tok; program = "leaves"; session = 0 });
  send 2 (Wire.Find { db = db.Client.handle; query = cross; select = Wire.Group ([||], [| Wire.Count |]); extra = []; order = Question.Top.none; timeout = 0 });
  Thread.delay 0.3;
  Unix.close fd;
  let t1 = Unix.gettimeofday () in
  while stat ops "questions.cancelled" = before && Unix.gettimeofday () -. t1 < 3. do Thread.delay 0.01 done;
  let took = Unix.gettimeofday () -. t1 in
  C.check (stat ops "questions.cancelled" <> before && took < 1.) "a question whose program closed its connection: cancelled within %.3f s" took;
  Printf.printf "load: 200 databases on %s domains (cap %s); 30 large questions at once in %.3f s; a 0.1 s timeout in %.3f s; cancelled %.3f s after the close\n%!"
    (stat ops "domains") (stat ops "domains.cap") t30 took0 took;
  Client.close w;
  Client.close ops

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
  Out_channel.with_open_bin cfg (fun oc -> output_string oc s);
  let token = Filename.concat a "app.token" in
  C.check (Sys.command (Printf.sprintf "%s token add app --database main=write --config %s > %s" bin (Filename.quote cfg) (Filename.quote token)) = 0) "token add";
  let tok = String.trim (In_channel.with_open_bin token In_channel.input_all) in
  let sock = Filename.concat a (Printf.sprintf "run/.s.cepheus.%d" port) in
  let serve () =
    let pid = Serve.start bin cfg in
    let t0 = Unix.gettimeofday () in
    while not (Sys.file_exists sock) && Unix.gettimeofday () -. t0 < 30. do Thread.delay 0.01 done;
    pid
  in
  (* a data directory made by hand under the usual umask (0755): the server makes it its own, its databases' files
     0600 and folders 0700, and its socket 0660 (the directory's group is the gate) *)
  let data = Filename.concat a "data" in
  (try Unix.mkdir data 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Unix.chmod data 0o755;
  (* the defaults: a watcher that never reads *)
  let pid = serve () in
  let rec modes p =
    let st = Unix.lstat p in
    match st.st_kind with
    | Unix.S_DIR -> (p, st.st_perm, true) :: List.concat_map (fun x -> modes (Filename.concat p x)) (Array.to_list (Sys.readdir p))
    | Unix.S_REG -> [ p, st.st_perm, false ]
    | _ -> []
  in
  let wrong = List.filter (fun (_, m, dir) -> m <> if dir then 0o700 else 0o600) (modes (Filename.concat data "main")) in
  C.check ((Unix.stat data).st_perm = 0o700) "a data directory of mode 755 made the server's alone (%o)" (Unix.stat data).st_perm;
  C.check (wrong = []) "a database's files 0600 and folders 0700 (%s)" (String.concat ", " (List.map (fun (p, m, _) -> Printf.sprintf "%s %o" (Filename.basename p) m) wrong));
  C.check ((Unix.stat sock).st_perm land 0o777 = 0o660) "the socket 0660, whatever the umask (%o)" ((Unix.stat sock).st_perm land 0o777);
  stall sock tok;
  Unix.kill pid Sys.sigterm;
  (match Serve.wait pid with _, Unix.WEXITED 0 -> () | _ -> C.check false "not a clean stop");
  (* the limits *)
  Out_channel.with_open_bin cfg (fun oc -> output_string oc (replace s "[clients]\n" "[clients]\nmax_connections = 3\nidle_timeout = 1\n"));
  let pid = serve () in
  (* the limit: three programs connected, a fourth connection refused, over the socket with a reason, over TCP before
     TLS *)
  let programs = List.init 3 (fun _ -> match Client.connect (Client.Unix_socket sock) tok with Ok c -> c | Error m -> failwith m) in
  let closed, codes, _ = until_closed (unix_conn sock) 2.0 in
  C.check (closed && codes = [ "too_many_connections" ]) "a fourth connection over the socket: too_many_connections, closed (%s)" (String.concat "," codes);
  let closed, _, n = until_closed (tcp_conn port) 2.0 in
  C.check (closed && n = 0) "a fourth connection over TCP: closed before any byte";
  List.iter Client.close programs;
  Thread.delay 0.2;
  (* three connections that show no token hold the slots: a program takes the oldest one's, which is closed at once
     with no word; the two others are closed within twice the limit, each after the frame idle *)
  let held = List.init 3 (fun _ -> let fd = unix_conn sock in Thread.delay 0.02; fd) in
  Thread.delay 0.1;
  let t1 = Unix.gettimeofday () in
  let c = match Client.connect (Client.Unix_socket sock) tok with Ok c -> c | Error m -> failwith m in
  let db = match Client.open_db ~local:false c "main" with Ok db -> db | Error e -> failwith e.message in
  C.check (match Client.get c db 1 with Ok (_, f) -> f <> [] | Error _ -> false) "a program is served while connections that show no token hold every slot";
  (match held with
   | oldest :: rest ->
     let closed, codes, _ = until_closed oldest 1.0 in
     C.check (closed && codes = [] && Unix.gettimeofday () -. t1 < 0.9) "the oldest of them gave its slot: closed at once, no word (%s)" (String.concat "," codes);
     List.iter
       (fun fd ->
         let closed, codes, _ = until_closed fd 3.0 in
         C.check (closed && codes = [ "idle" ]) "a silent connection: idle, closed (%s)" (String.concat "," codes))
       rest
   | [] -> ());
  List.iter Unix.close held;
  C.check (Unix.gettimeofday () -. t1 < 2.5) "the silent connections closed within twice the limit";
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
  (* a byte at a time, each within the socket's timeout: a TLS record of the handshake (a header announcing 512 bytes,
     then its bytes one by one), and after Hello a record of the application's data; both closed within the limit *)
  let drip fd head =
    Thread.create
      (fun () ->
        try
          ignore (Unix.write_substring fd head 0 (String.length head));
          for _ = 1 to 40 do Thread.delay 0.25; ignore (Unix.write_substring fd "\001" 0 1) done
        with Unix.Unix_error _ -> ())
      ()
  in
  let fd = tcp_conn port in
  let t3 = Unix.gettimeofday () in
  let d = drip fd "\022\003\001\002\000" in
  let closed, _, _ = until_closed fd 6.0 in
  C.check (closed && Unix.gettimeofday () -. t3 < 2.6) "a TLS handshake that trickles a byte at a time is closed within twice the limit (%.1f s)" (Unix.gettimeofday () -. t3);
  Thread.join d;
  Unix.close fd;
  let ca = Filename.concat a "ca.pem" in
  (match Client.connect ~ca (Client.Tcp ("127.0.0.1", port)) tok with
   | Error m -> C.check false "TLS: %s" m
   | Ok tc -> (
     match tc.Client.fd with
     | None -> C.check false "TLS: no socket"
     | Some fd ->
       let t4 = Unix.gettimeofday () in
       let d = drip fd "\023\003\003\001\000" in
       let closed, _, _ = until_closed fd 6.0 in
       C.check (closed && Unix.gettimeofday () -. t4 < 2.6) "after Hello, a TLS record that trickles a byte at a time is closed within twice the limit (%.1f s)" (Unix.gettimeofday () -. t4);
       Thread.join d;
       Client.close tc));
  (* pings more often than the limit keep a connection (a new one: the first has been idle meanwhile) *)
  Client.close c;
  let c = match Client.connect (Client.Unix_socket sock) tok with Ok c -> c | Error m -> failwith m in
  let db = match Client.open_db ~local:false c "main" with Ok db -> db | Error e -> failwith e.message in
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
  (match Serve.wait pid with _, Unix.WEXITED 0 -> C.check true "a clean stop" | _ -> C.check false "not a clean stop");
  (* 200 databases, questions under load (the limits back to their defaults; a question's time of 5 s) *)
  let dbs = String.concat "" (List.init 200 (fun i -> Printf.sprintf "[[database]]\nname = \"d%d\"\n" i)) in
  Out_channel.with_open_bin cfg (fun oc -> output_string oc (replace s "[clients]\n" "[clients]\nquestion_timeout = 5\n" ^ dbs));
  let rights = String.concat " " (List.init 200 (fun i -> Printf.sprintf "--database d%d=write" i)) in
  let token2 = Filename.concat a "load.token" and admin_token = Filename.concat a "ops.token" in
  C.check (Sys.command (Printf.sprintf "%s token add load --database main=write %s --config %s > %s" bin rights (Filename.quote cfg) (Filename.quote token2)) = 0) "token add load";
  C.check (Sys.command (Printf.sprintf "%s token add ops --admin --config %s > %s" bin (Filename.quote cfg) (Filename.quote admin_token)) = 0) "token add ops";
  let read t = String.trim (In_channel.with_open_bin t In_channel.input_all) in
  let pid = serve () in
  load sock (read token2) (read admin_token);
  Unix.kill pid Sys.sigterm;
  (match Serve.wait pid with _, Unix.WEXITED 0 -> C.check true "a clean stop of 200 databases" | _ -> C.check false "not a clean stop of 200 databases");
  let log = In_channel.with_open_bin (Filename.concat a "serve.log") In_channel.input_all in
  C.check (not (contains log "failed")) "the server's log says no failure";
  (try Sys.remove (Follow.page_of_dir (Filename.concat a "data/main")) with Sys_error _ -> ());
  List.iter (fun i -> try Sys.remove (Follow.page_of_dir (Filename.concat a (Printf.sprintf "data/d%d" i))) with Sys_error _ -> ()) (List.init 200 Fun.id);
  C.rmrf dir;
  ignore Value.equal;
  C.finish "server limits"
