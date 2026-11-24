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
   - the vault's files through the log: two files put through the leader (one sealed by an owner's key), read back
     there; a follower without the cluster's vault.key waits (cepheus status says why), then takes them once the key
     is copied; the leader killed: the new one gives both files' bytes; an owner's files erased there are erased;
   - cepheus stop on the leader while a program writes: leadership handed over (Timeout_now), the writes paused far
     less than an election timeout, none it was told committed lost;
   - two servers killed and a byte of a round of each one's Raft log changed: both find their logs damaged (the
     2018 rule: no vote), so the one left cannot be elected alone; they take the committed entries they lack from
     it (Entries), their repair ends, a leader is elected, the program writes again, nothing it was told is lost;
   - the peer port refuses a peer of protocol 1, a certificate of the cluster's CA for a name no peer has, and a
     certificate of another CA.
   - a load, a change of the rules (computed in the leader's background) beside groups that count with one counter
     (Incr), and a load past 8 MiB, carried through the log in pieces; the leader killed: the new one holds the
     loads, the change's consequences and the counter;
   - the catch-up (server/catchup.ml): loads that pass a segment of the Raft log (64 MiB), so that the leader's log
     starts after 1; a follower killed and its data directory removed: started again empty, it asks the others their
     state, takes a copy of the databases from the leader, starts again on it and follows, holding every group; the
     same with the follower killed (kill -9) during its copy, then with the leader killed during it;
   - a group of about 100 MiB (a rule's consequences: 25,600 texts of 4 KiB copied) through the log in pieces, its
     time from the write to the receipt; the same with a follower killed (kill -9) during it (it comes back and holds
     it whole), then with the leader killed during it, the client not trying again: on the new leader and on every
     server, all of its consequences or none.

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
    | [| _; d; "handover"; _ |] -> d, 0
    | [| _; d; "catchup"; _; _ |] -> d, 0
    | [| _; d; "group"; _ |] -> d, 0
    | _ -> prerr_endline "server_raft.exe DIR [failover N | handover N | catchup FACTS N | group N]"; exit 2
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
  (* the leader of the probe that saw it: a second probe could see none, between two terms *)
  let await_leader ?(ok = fun _ -> true) what =
    let got = ref None in
    wait_for what (fun () -> got := (match leader () with Some k when ok k -> Some k | _ -> None); !got <> None);
    Option.get !got
  in
  let l0 = await_leader "a leader" in
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
  (* [catchup FACTS N] (a measure, not a test): FACTS facts loaded through the leader (writes of 100,000), then N
     times a follower killed, its data directory removed and started again: the time from its start to holding every
     group (its copy of the databases taken, checked, installed, the server started again on it, the log's tail
     applied) *)
  if Array.length Sys.argv = 5 && Sys.argv.(2) = "catchup" then begin
    let facts = int_of_string Sys.argv.(3) and n = int_of_string Sys.argv.(4) in
    let t0 = Unix.gettimeofday () in
    let batch = 100_000 in
    for b = 0 to (facts / batch) - 1 do
      match Client.write w mdb (List.init batch (fun i -> Resolve.Add (-(i + 1), mp, Int ((b * batch) + i)))) with
      | Ok _ -> ()
      | Error e -> failwith ("load: " ^ e.message)
    done;
    let same () = match leader () with Some l -> List.for_all (fun db -> let g = group l db in List.for_all (fun k -> alive.(k) && group k db = g) [ 0; 1; 2 ]) [ "main"; "side" ] | None -> false in
    wait_for ~limit:600. "every server holds the load" same;
    Printf.printf "loaded %d facts through the leader in %.1f s\n%!" facts (Unix.gettimeofday () -. t0);
    let log_start k = match String.split_on_char ' ' (stat k "raft.log") with a :: _ -> (match int_of_string_opt a with Some x -> x | None -> 0) | [] -> 0 in
    wait_for ~limit:120. "the leader's log cut" (fun () -> match leader () with Some l -> log_start l > 1 | None -> false);
    let data k = (Result.get_ok (Config.load cfgs.(k))).data in
    let du d = let r = ref 0 in let rec go p = match Unix.lstat p with { Unix.st_kind = Unix.S_DIR; _ } -> Array.iter (fun x -> go (Filename.concat p x)) (Sys.readdir p) | st -> r := !r + st.st_size | exception Unix.Unix_error _ -> () in go d; !r in
    for r = 1 to n do
      let l = await_leader "a leader" in
      let f = (l + 1 + (r mod 2)) mod 3 in
      let db_bytes = du (Filename.concat (data l) "main") + du (Filename.concat (data l) "side") in
      Unix.kill pids.(f) Sys.sigkill;
      ignore (Serve.wait pids.(f));
      alive.(f) <- false;
      C.rmrf (data f);
      let t1 = Unix.gettimeofday () in
      pids.(f) <- Serve.start bin cfgs.(f);
      alive.(f) <- true;
      wait_socket (sock f);
      wait_for ~limit:600. "the follower caught up" (fun () -> same () && stat f "raft.role" = "follower" && List.assoc_opt "raft.repair" (status f) = None);
      Printf.printf "round %d: %s caught up from an empty data directory in %.0f ms (the databases %.1f MB)\n%!" r (List.nth names f)
        ((Unix.gettimeofday () -. t1) *. 1000.) (float_of_int db_bytes /. 1e6)
    done;
    Client.close w;
    Array.iteri (fun k c -> if alive.(k) then (ignore (run [ "stop"; "--config"; c ]); ignore (Serve.wait pids.(k)))) cfgs;
    C.rmrf dir;
    exit 0
  end;
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
  let killed_at = ref 0. and first_after = ref 0. and n_before = !n in
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
  (* the kill comes after the writer's first 50 writes, not after a delay: on a disk in memory 400 writes can end
     before any delay, and the failover would see no write *)
  wait_for "the writer's first writes" (fun () -> !n - n_before >= 50);
  killed_at := Unix.gettimeofday ();
  Unix.kill pids.(l0) Sys.sigkill;
  ignore (Serve.wait pids.(l0));
  alive.(l0) <- false;
  Thread.join writer;
  let l1 = await_leader "a new leader" in
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
  (* the leader stopped (cepheus stop) while a program writes: the longest pause between two writes committed, the
     writes it was told committed and missing, whether the stopped leader's log says it handed over; then it is
     started again and catches up *)
  let handover () =
    let ll = await_leader "a leader" in
    let stop = Atomic.make false and times = ref [] and mine = ref [] and k = ref 0 in
    let wr =
      Thread.create
        (fun () ->
          while not (Atomic.get stop) do
            incr k;
            let v = 50_000_000 + !k in
            match Client.write w mdb [ Resolve.Add (-1, mp, Int v) ] with
            | Ok _ -> times := Unix.gettimeofday () :: !times; mine := v :: !mine
            | Error e -> Printf.printf "write error %s %s\n%!" e.code e.message
          done)
        ()
    in
    Thread.delay 0.4;
    let t_stop = Unix.gettimeofday () in
    ignore (run [ "stop"; "--config"; cfgs.(ll) ]);
    ignore (Serve.wait pids.(ll));
    alive.(ll) <- false;
    ignore (await_leader ~ok:(fun k -> k <> ll && stat k "raft.ready" = "true") "a new leader");
    Thread.delay 0.4;
    Atomic.set stop true;
    Thread.join wr;
    let ts = List.rev !times in
    let rec gaps acc = function a :: (b :: _ as r) -> gaps (if b >= t_stop -. 0.05 then max acc (b -. a) else acc) r | _ -> acc in
    let gap = gaps 0. ts *. 1000. in
    let lost = List.length (List.filter (fun v -> match Client.find w mdb { Query.vars = 1; where = [ { Query.e = Var 0; p = mp; v = Val (Int v) } ]; ranges = [] } with Ok (_, []) -> true | Ok _ -> false | Error _ -> true) !mine) in
    let log_text = In_channel.with_open_bin (Filename.concat (Filename.dirname cfgs.(ll)) "serve.log") In_channel.input_all in
    let has s sub = let n = String.length sub in let rec go i = i + n <= String.length s && (String.sub s i n = sub || go (i + 1)) in go 0 in
    pids.(ll) <- Serve.start bin cfgs.(ll);
    alive.(ll) <- true;
    wait_socket (sock ll);
    let same () = match leader () with Some l -> List.for_all (fun db -> let g = group l db in List.for_all (fun k -> group k db = g) [ 0; 1; 2 ]) [ "main"; "side" ] | None -> false in
    wait_for "the stopped leader catches up" same;
    gap, lost, has log_text "leadership handed over"
  in
  (* [handover N] (a measure, not a test): N clean stops of the leader under writes, each the writes' longest pause *)
  if Array.length Sys.argv = 4 && Sys.argv.(2) = "handover" then begin
    let n = int_of_string Sys.argv.(3) in
    for r = 1 to n do
      let gap, lost, handed = handover () in
      Printf.printf "round %d: the writes paused %.1f ms at the leader's stop (%s), %d lost\n%!" r gap (if handed then "handed over" else "not handed over") lost
    done;
    Client.close w;
    Array.iteri (fun k c -> if alive.(k) then (ignore (run [ "stop"; "--config"; c ]); ignore (Serve.wait pids.(k)))) cfgs;
    C.rmrf dir;
    exit 0
  end;
  (* the vault's files: the cluster's key on every server but one follower *)
  let lv = await_leader "a leader" in
  let fv = (lv + 1) mod 3 in
  let key = String.init 32 (fun i -> Char.chr ((i * 41 + 7) land 255)) in
  let key_path k = Filename.concat (Filename.dirname cfgs.(k)) "vault.key" in
  let put_key k = let fd = Unix.openfile (key_path k) [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600 in ignore (Unix.write_substring fd key 0 32); Unix.close fd in
  List.iter (fun k -> if k <> fv then put_key k) [ 0; 1; 2 ];
  let mdb2, fps =
    match Client.declare w "main" [ prop "doc/Name" Ttext; prop "doc/Size" Tint; prop "doc/Type" Ttext; prop "doc/Owner" Tlink; prop "doc/Content" Ttext; prop "who" Ttext ] with
    | Ok (db, ps) -> db, ps
    | Error e -> failwith ("declare: " ^ e.message)
  in
  let[@warning "-8"] [ _; _; _; _; pcontent; pwho ] = fps in
  let bytes n seed = String.init n (fun i -> Char.chr ((((i * 2654435761) lxor seed) lsr 7) land 255)) in
  let f1 = bytes (3 lsl 20) 1 and f2 = bytes 700_000 2 in
  let owner = match Client.write w mdb2 [ Resolve.Add (-1, pwho, Text "an owner") ] with Ok r -> List.assoc (-1) r.things | Error e -> failwith e.message in
  let put name ?owner data =
    match Client.put w mdb2 ~kind:"doc" ~name ?owner data with Ok r -> List.assoc (-1) r.things | Error e -> C.check false "a put in the cluster: %s %s" e.code e.message; -1
  in
  let t1 = put "one" f1 and t2 = put "two" ~owner f2 in
  let loaded th = match Client.load w mdb2 ~thing:th ~prop:pcontent () with Ok s -> s | Error e -> "error " ^ e.code in
  C.check (loaded t1 = f1 && loaded t2 = f2) "two files put in the cluster, read back on the leader";
  wait_for ~limit:30. "the follower without the key says so" (fun () -> List.mem_assoc "raft.files" (status fv));
  C.check true "a follower without the cluster's vault.key waits: %s" (stat fv "raft.files");
  put_key fv;
  let same_main () = match leader () with Some l -> let g = group l "main" in List.for_all (fun k -> group k "main" = g) [ 0; 1; 2 ] | None -> false in
  wait_for ~limit:30. "the follower takes the files once the key is there" (fun () -> same_main () && not (List.mem_assoc "raft.files" (status fv)));
  C.check true "with the key copied, it takes them (main at %d)" (group lv "main");
  Unix.kill pids.(lv) Sys.sigkill;
  ignore (Serve.wait pids.(lv));
  alive.(lv) <- false;
  let lw = await_leader ~ok:(fun k -> k <> lv && stat k "raft.ready" = "true") "a new leader" in
  C.check (loaded t1 = f1 && loaded t2 = f2) "the new leader %s gives both files' bytes" (List.nth names lw);
  (match Client.erase w mdb2 ~owner with
   | Ok () -> C.check (String.length (loaded t2) >= 6 && String.sub (loaded t2) 0 6 = "error ") "an owner's files erased through the log: %s" (loaded t2)
   | Error e -> C.check false "an erasure in the cluster: %s %s" e.code e.message);
  C.check (loaded t1 = f1) "the database's own file still there";
  pids.(lv) <- Serve.start bin cfgs.(lv);
  alive.(lv) <- true;
  wait_socket (sock lv);
  wait_for ~limit:30. "the old leader catches up" same_main;
  (* cepheus stop on the leader under writes: its leadership handed over *)
  let gap, lost, handed = handover () in
  C.check (handed && gap < float !Cluster.election_ms) "cepheus stop on the leader: handed over, the writes paused %.1f ms" gap;
  C.check (lost = 0) "no write it was told committed lost (%d)" lost;
  (* a damaged majority, repaired by the one left *)
  write_some w 30;
  let ls = await_leader "a leader" in
  wait_for "every server holds the leader's groups" (fun () -> let g = group ls "main" in List.for_all (fun k -> group k "main" = g) [ 0; 1; 2 ]);
  let before = !told in
  let damaged = List.filter (fun k -> k <> ls) [ 0; 1; 2 ] in
  List.iter (fun k -> Unix.kill pids.(k) Sys.sigkill; ignore (Serve.wait pids.(k)); alive.(k) <- false) damaged;
  let flip k =
    let rd = Filename.concat (Result.get_ok (Config.load cfgs.(k))).data "raft" in
    let seg = List.hd (List.rev (List.sort compare (List.filter (fun f -> String.length f = 24 && String.sub f 0 4 = "log.") (Array.to_list (Sys.readdir rd))))) in
    let path = Filename.concat rd seg in
    let size = (Unix.stat path).st_size in
    let fd = Unix.openfile path [ Unix.O_RDWR ] 0 in
    let b = Bytes.create 1 and off = 52 + ((size - 52) * 3 / 5) in
    ignore (Unix.lseek fd off Unix.SEEK_SET);
    ignore (Unix.read fd b 0 1);
    Bytes.set b 0 (Char.chr (Char.code (Bytes.get b 0) lxor 0x5a));
    ignore (Unix.lseek fd off Unix.SEEK_SET);
    ignore (Unix.write fd b 0 1);
    Unix.close fd
  in
  List.iter flip damaged;
  List.iter (fun k -> pids.(k) <- Serve.start bin cfgs.(k); alive.(k) <- true) damaged;
  List.iter (fun k -> wait_socket (sock k)) damaged;
  let logs = List.map (fun k -> In_channel.with_open_bin (Filename.concat (Filename.dirname cfgs.(k)) "serve.log") In_channel.input_all) damaged in
  let has s sub = let n = String.length sub in let rec go i = i + n <= String.length s && (String.sub s i n = sub || go (i + 1)) in go 0 in
  C.check (List.for_all (fun l -> has l "set aside, kept as *.damaged") logs) "both found their logs damaged and set the damage aside";
  let lr = await_leader ~ok:(fun k -> stat k "raft.ready" = "true") "a leader after the damaged majority's repair" in
  C.check (List.for_all (fun k -> List.assoc_opt "raft.repair" (status k) = None) [ 0; 1; 2 ]) "their repair ended: a leader %s" (List.nth names lr);
  write_some w 20;
  let rd = Result.get_ok (Client.open_db ~local:false w "main") in
  let missing = List.length (List.filter (fun (v, _) -> match Client.find w rd { Query.vars = 1; where = [ { Query.e = Var 0; p = mp; v = Val (Int v) } ]; ranges = [] } with Ok (_, []) -> true | Ok _ -> false | Error _ -> true) before) in
  C.check (missing = 0) "after the repair, every write it was told committed is there (%d writes, %d missing)" (List.length before) missing;
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
  (* the reasoner's paths in a cluster: a load, a change of the rules (computed in the background on the leader, its
     30,000 derived facts a run of their own there, every one of them in its frame through the Raft log)
     beside groups that count with one counter (Incr), a load past a Raft entry (8 MiB) refused whole; then the leader
     killed: the new one holds every group, each of them through the Raft log *)
  let sdb2, sps =
    match Client.declare w "side" [ prop "k" Tint; prop ~many:true "k2" Tint; prop "t" Ttext; prop "c" Tint ] with
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
  (* a load past 8 MiB: in pieces through the log, on every server *)
  let side_before = group (await_leader "a leader") "side" in
  let text i = Printf.sprintf "%08d-%s" i (Digest.to_hex (Digest.string (string_of_int i))) in
  (match Client.write w sdb2 (List.init 260_000 (fun i -> Resolve.Add (-(i + 1), st, Text (text i)))) with
   | Ok r -> C.check (r.group = side_before + 1) "a load past 8 MiB in a cluster: taken (group %d)" r.group
   | Error e -> C.check false "a load past 8 MiB: %s %s" e.code e.message);
  let same () =
    match leader () with
    | None -> false
    | Some l -> List.for_all (fun db -> let g = group l db in List.for_all (fun k -> not alive.(k) || group k db = g) [ 0; 1; 2 ]) [ "main"; "side" ]
  in
  wait_for "every server holds the leader's groups" same;
  let lk = await_leader "a leader" in
  C.check (group lk "side" = side_before + 1) "every server holds the load past 8 MiB (side at %d)" (side_before + 1);
  (* the leader killed: the new one holds the load, the change and its consequences, the counter *)
  let side_g = group lk "side" in
  Unix.kill pids.(lk) Sys.sigkill;
  ignore (Serve.wait pids.(lk));
  alive.(lk) <- false;
  let ln = await_leader ~ok:(fun k -> k <> lk && stat k "raft.ready" = "true") "a new leader" in
  C.check (group ln "side" >= side_g) "the new leader %s holds side's groups (%d)" (List.nth names ln) side_g;
  C.check (rows sk = nk && rows sk2 = nk) "on the new leader: the load and the rule's consequences (%d)" nk;
  (match Client.get w sdb2 counter with
   | Ok (_, facts) -> C.check (List.assoc_opt sc facts = Some (Int (Atomic.get counted))) "on the new leader: the counter at %d" (Atomic.get counted)
   | Error e -> C.check false "the counter: %s" e.message);
  (match Client.find w sdb2 { Query.vars = 1; where = [ { Query.e = Var 0; p = st; v = Val (Text (text 259_999)) } ]; ranges = [] } with
   | Ok (_, rows) -> C.check (List.length rows = 1) "on the new leader: the load past 8 MiB, its last fact too"
   | Error e -> C.check false "a read on the new leader: %s" e.message);
  pids.(lk) <- Serve.start bin cfgs.(lk);
  alive.(lk) <- true;
  wait_socket (sock lk);
  wait_for "the killed leader catches up" same;
  C.check true "the killed leader caught up (side at %d)" (group ln "side");
  (* the catch-up: loads past a segment of the Raft log, so that its start passes 1 *)
  let text i = Printf.sprintf "%08d-%s" i (Digest.to_hex (Digest.string (string_of_int i))) in
  let loaded = ref 0 in
  let log_start k = match String.split_on_char ' ' (stat k "raft.log") with a :: _ -> (match int_of_string_opt a with Some x -> x | None -> 0) | [] -> 0 in
  let t_load = Unix.gettimeofday () in
  while log_start (await_leader "a leader") <= 1 && !loaded < 30 do
    let base = 10_000_000 + (!loaded * 200_000) in
    (match Client.write w sdb2 (List.init 180_000 (fun i -> Resolve.Add (-(i + 1), st, Text (text (base + i))))) with
     | Ok _ -> incr loaded
     | Error e -> C.check false "a load for the catch-up: %s %s" e.code e.message; loaded := 99);
    if !loaded >= 9 then Thread.delay 1.2
  done;
  let ll = await_leader "a leader" in
  C.check (log_start ll > 1) "the leader's log starts at %d after %d loads (%.1f s)" (log_start ll) !loaded (Unix.gettimeofday () -. t_load);
  let data k = (Result.get_ok (Config.load cfgs.(k))).data in
  let serve_log k = In_channel.with_open_bin (Filename.concat (Filename.dirname cfgs.(k)) "serve.log") In_channel.input_all in
  let count_in s sub = let n = String.length sub in let c = ref 0 in for i = 0 to String.length s - n do if String.sub s i n = sub then incr c done; !c in
  let caught_up what k =
    wait_for ~limit:120. what (fun () -> alive.(k) && stat k "raft.role" = "follower" && List.assoc_opt "raft.repair" (status k) = None && same ());
    C.check true "%s: %s follows, holds every group (side at %d), its repair done" what (List.nth names k) (group (await_leader "a leader") "side");
    C.check (not (Sys.file_exists (Filename.concat (data k) "raft/copy")) && not (Sys.file_exists (Filename.concat (data k) "raft/copy.partial")))
      "%s: no copy left in %s/raft" what (data k)
  in
  (* a follower killed, its data directory removed, started again empty *)
  let wipe k =
    Unix.kill pids.(k) Sys.sigkill;
    ignore (Serve.wait pids.(k));
    alive.(k) <- false;
    C.rmrf (data k);
    pids.(k) <- Serve.start bin cfgs.(k);
    alive.(k) <- true
  in
  let fk = (ll + 1) mod 3 in
  let installs0 = count_in (serve_log fk) "installed the copy" in
  let t_copy = Unix.gettimeofday () in
  wipe fk;
  caught_up "a follower started on an empty data directory" fk;
  C.check (count_in (serve_log fk) "installed the copy" = installs0 + 1) "it installed one copy of the leader's databases (%.1f s from its start)" (Unix.gettimeofday () -. t_copy);
  (* killed during its copy, then started again *)
  let copying k = match List.assoc_opt "raft.copy" (status k) with Some m -> String.length m > 6 && String.sub m 0 6 = "taking" | None -> false in
  wipe fk;
  wait_for ~limit:60. "the follower's copy" (fun () -> copying fk);
  Unix.kill pids.(fk) Sys.sigkill;
  ignore (Serve.wait pids.(fk));
  pids.(fk) <- Serve.start bin cfgs.(fk);
  caught_up "a follower killed (kill -9) during its copy" fk;
  C.check (count_in (serve_log fk) "removed a copy of the databases that did not finish" >= 1) "the copy it was taking removed at its start";
  (* the leader killed during the copy: the follower's copy breaks; it takes one from the next leader *)
  let ll = await_leader "a leader" in
  let fk = (ll + 1) mod 3 in
  wipe fk;
  wait_for ~limit:60. "the follower's copy" (fun () -> copying fk);
  Unix.kill pids.(ll) Sys.sigkill;
  ignore (Serve.wait pids.(ll));
  alive.(ll) <- false;
  (* the follower without its data cannot vote yet (it has not all it acknowledged): the old leader comes back *)
  pids.(ll) <- Serve.start bin cfgs.(ll);
  alive.(ll) <- true;
  wait_socket (sock ll);
  caught_up "a follower whose source was killed (kill -9) during its copy" fk;
  (* a group of about 100 MiB: the consequences of a rule that copies 25,600 texts of 4 KiB *)
  let sdb3, bps =
    match Client.declare w "side" [ prop "b" Ttext; prop ~many:true "b2" Ttext; prop ~many:true "b3" Ttext; prop ~many:true "b4" Ttext ] with
    | Ok (db, ps) -> db, ps
    | Error e -> failwith ("declare: " ^ e.message)
  in
  let[@warning "-8"] [ pb; pb2; pb3; pb4 ] = bps in
  let big i = Printf.sprintf "%06d%s" i (String.make 4090 (Char.chr (97 + (i mod 26)))) in
  let nbig = 25_600 in
  for part = 0 to 9 do
    match Client.write w sdb3 (List.init (nbig / 10) (fun i -> Resolve.Add (-(i + 1), pb, Text (big ((part * (nbig / 10)) + i))))) with
    | Ok _ -> ()
    | Error e -> C.check false "a load of 4 KiB texts: %s %s" e.code e.message
  done;
  let count p = match Client.find w sdb3 ~select:(Wire.Give [| 0 |]) { Query.vars = 2; where = [ { Query.e = Var 0; p; v = Var 1 } ]; ranges = [] } with Ok (_, rows) -> List.length rows | Error _ -> -1 in
  let rule name p : Cepheus.rule = { name; vars = 2; where = [ { e = Var 0; p = pb; v = Var 1 } ]; ranges = []; head = Give { e = Var 0; p; v = Var 1 } } in
  let rules = ref 0 in
  let add_rule ?(c = w) name p =
    incr rules;
    let rid = Schema.first_thing - 200 - !rules in
    Client.write c sdb3 [ Resolve.Add (rid, Schema.p_name, Text name); Resolve.Add (rid, Schema.p_rule, Text (Rules.to_text (rule name p))); Resolve.Expect (rid, Schema.p_name, None) ]
  in
  (* [group N] (a measure, not a test): N groups of about 100 MiB, each a rule's consequences, from the write to its
     receipt *)
  if Array.length Sys.argv = 4 && Sys.argv.(2) = "group" then begin
    let n = int_of_string Sys.argv.(3) in
    for r = 1 to n do
      let ps = match Client.declare w "side" [ prop ~many:true (Printf.sprintf "g%d" r) Ttext ] with Ok (_, [ p ]) -> p | _ -> failwith "declare" in
      let t0 = Unix.gettimeofday () in
      (match add_rule (Printf.sprintf "g%d" r) ps with
       | Ok _ -> Printf.printf "round %d: a group of 100 MiB committed in %.1f ms\n%!" r ((Unix.gettimeofday () -. t0) *. 1000.)
       | Error e -> Printf.printf "round %d: %s %s\n%!" r e.code e.message);
      wait_for ~limit:120. "every server holds it" same
    done;
    Client.close w;
    Array.iteri (fun k c -> if alive.(k) then (ignore (run [ "stop"; "--config"; c ]); ignore (Serve.wait pids.(k)))) cfgs;
    C.rmrf dir;
    exit 0
  end;
  let t0 = Unix.gettimeofday () in
  (match add_rule "big2" pb2 with
   | Ok r ->
     let ms = (Unix.gettimeofday () -. t0) *. 1000. in
     C.check true "a group of 100 MiB (a rule's %d consequences of 4 KiB) committed in %.0f ms (group %d)" nbig ms r.group;
     Printf.printf "group_100mib_ms %.1f\n%!" ms
   | Error e -> C.check false "a group of 100 MiB: %s %s" e.code e.message);
  wait_for ~limit:120. "every server holds the group of 100 MiB" same;
  C.check (count pb2 = nbig) "its %d consequences on the leader" nbig;
  (* a follower killed during it *)
  let ll = await_leader "a leader" in
  let fk = (ll + 1) mod 3 in
  let res = ref None in
  let th = Thread.create (fun () -> res := Some (add_rule "big3" pb3)) () in
  Thread.delay 0.4;
  Unix.kill pids.(fk) Sys.sigkill;
  ignore (Serve.wait pids.(fk));
  Thread.join th;
  (match !res with Some (Ok _) -> C.check true "a group of 100 MiB committed with a follower killed during it" | Some (Error e) -> C.check false "with a follower killed: %s %s" e.code e.message | None -> ());
  pids.(fk) <- Serve.start bin cfgs.(fk);
  wait_socket (sock fk);
  wait_for ~limit:120. "the killed follower holds the group of 100 MiB" same;
  C.check (count pb3 = nbig) "its %d consequences on the leader; the follower came back and holds its group" nbig;
  (* the leader killed during it, the client trying nothing again: all of it or none, everywhere *)
  let ll = await_leader "a leader" in
  let w4 = match Client.connect ~session:781 ~ca:(Filename.concat ca "ca.pem") (tcp ll) wtext with Ok c -> c | Error m -> failwith m in
  let sdb4 = Result.get_ok (Client.open_db ~local:false w4 "side") in
  ignore sdb4;
  Client.retry_budget := 0.;
  let res = ref None in
  let th = Thread.create (fun () -> res := Some (add_rule ~c:w4 "big4" pb4)) () in
  Thread.delay 0.5;
  Unix.kill pids.(ll) Sys.sigkill;
  ignore (Serve.wait pids.(ll));
  alive.(ll) <- false;
  Thread.join th;
  Client.retry_budget := 30.0;
  Client.close w4;
  let ln = await_leader ~ok:(fun k -> k <> ll && stat k "raft.ready" = "true") "a new leader" in
  let n4 = count pb4 in
  C.check (n4 = 0 || n4 = nbig) "the leader killed during a group of 100 MiB (%s): its consequences on the new leader %s: %d of %d (all or none)"
    (match !res with Some (Ok _) -> "answered committed" | Some (Error e) -> e.code | None -> "?") (List.nth names ln) n4 nbig;
  (match !res with Some (Ok _) -> C.check (n4 = nbig) "answered committed: all of it on the new leader" | _ -> ());
  pids.(ll) <- Serve.start bin cfgs.(ll);
  alive.(ll) <- true;
  wait_socket (sock ll);
  wait_for ~limit:120. "the old leader catches up" same;
  C.check true "the old leader caught up (side at %d)" (group (await_leader "a leader") "side");
  Client.close w;
  Array.iteri (fun k c -> if alive.(k) then (C.check (run [ "stop"; "--config"; c ] = 0) "cepheus stop %s" (List.nth names k); ignore (Serve.wait pids.(k)))) cfgs;
  C.rmrf dir;
  C.finish "server raft"
