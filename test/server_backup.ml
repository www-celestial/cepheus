(* The restore drill, end to end, with the commands as an operator runs them. A real server (`cepheus serve`) holds
   two databases that four client threads write to without a pause; meanwhile `cepheus verify` checks a live
   database, `cepheus backup` copies both, one backup is killed (kill -9) in its middle and the next one removes what
   it left; then the server is killed (kill -9) under the writes. `cepheus restore` restores the backup in a new data
   directory, and the restored database:
     - holds every write acknowledged before the backup started, and opens at a group at least the newest of them;
     - holds exactly the facts of the original journal's groups 1..G replayed onto the empty state (the oracle; the
       original recovered by a start and a stop of its server), G its group;
     - restored again with --to-group G/2: at G/2, with the oracle's facts at G/2;
     - is served by a server of its own, at G, in epoch 2, and takes writes.
   The server, killed, is started again at once: its writers' library sends their unanswered writes again.
   Also: a restore killed (kill -9) leaves the folder it was to make absent, and the next restore removes what it
   left; a restore into the database of a running server is refused, as is a second backup into the same folder.

     server_backup.exe DIR *)

open Cepheus
open Cepheus_server
module C = Check

let ( // ) = Filename.concat
let bin = Filename.dirname (Filename.dirname Sys.executable_name) // "bin/main.exe"
let write_file path s = Out_channel.with_open_bin path (fun oc -> output_string oc s)

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

(* a command of the binary: its exit status and its output *)
let run args =
  let out = Filename.temp_file "cepheus-ops" ".out" in
  let code = Sys.command (Printf.sprintf "%s %s > %s 2>&1" bin (String.concat " " (List.map Filename.quote args)) (Filename.quote out)) in
  let s = In_channel.with_open_bin out In_channel.input_all in
  Sys.remove out;
  code, s

let lines s = List.filter (( <> ) "") (String.split_on_char '\n' s)

(* a command started in the background, to be killed *)
let spawn args =
  let null = Unix.openfile "/dev/null" [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0 in
  let pid = Unix.create_process bin (Array.of_list (bin :: args)) null null null in
  Unix.close null;
  pid

let config dir name =
  Unix.mkdir dir 0o700;
  Unix.mkdir (dir // "run") 0o700;
  write_file (dir // "cluster.toml")
    (Printf.sprintf
       "[cluster]\nname = %S\nid = \"cph-c-00000000000000b1\"\nme = \"srv1\"\n[[peer]]\nname = \"srv1\"\naddress = \"127.0.0.1:7401\"\n\
        [clients]\nsocket = \"run\"\ndomains = 2\n[storage]\ndata = \"data\"\ncache = \"64M\"\n[[database]]\nname = \"main\"\n[[database]]\nname = \"side\"\n"
       name);
  dir // "cluster.toml", dir // "run/.s.cepheus.7400", dir // "data"

let tokens dir =
  let wtext, whash = Tokens.generate () and atext, ahash = Tokens.generate () in
  Tokens.save (dir // "tokens.toml")
    (Tokens.with_tokens Tokens.empty
       [ { Tokens.name = "w"; hash = whash; databases = [ "main", Tokens.Write; "side", Tokens.Write ]; admin = false };
         { Tokens.name = "a"; hash = ahash; databases = []; admin = true } ]);
  wtext, atext

(* the oracle: groups 1..n of a closed database's journal replayed onto the empty state *)
let oracle dir n =
  let id = Engine.read_meta Disk.real dir in
  let v = ref (Store.empty ()) in
  Journal.read Disk.real (dir // "journal") id (fun g -> if g.Group.n <= n then v := Resolve.replay !v g);
  C.facts_of_view !v

let opened dir =
  match Cepheus.open_ dir with
  | Error e -> failwith (dir ^ ": " ^ Cepheus.message e)
  | Ok db ->
    let v = Cepheus.view db in
    let r = Cepheus.group v, C.facts_of_view v in
    Cepheus.close db;
    r

let has_int f v = C.F.exists (fun (_, _, x) -> x = Value.Int v) f

let () =
  let dir = match Sys.argv with [| _; d |] -> d | _ -> prerr_endline "server_backup.exe DIR"; exit 2 in
  C.rmrf dir;
  Unix.mkdir dir 0o700;
  let cfg, sock, data = config (dir // "a") "backup" in
  let wtext, _ = tokens (dir // "a") in
  let addr = Client.Unix_socket sock in
  let pid = ref (Serve.start bin cfg) in
  wait_ready sock;
  let c0 = Result.get_ok (Client.connect addr wtext) in
  let declare name = match Client.declare c0 name [ prop "k" Tint ] with Ok (db, [ p ]) -> db, p | _ -> failwith "declare" in
  let main = declare "main" and side = declare "side" in
  Client.close c0;
  (* writers: thread t writes values t * 1_000_000 + i, half to each database *)
  let n = 4 in
  let acked = Array.make n [] and stop = Atomic.make false in
  let writer t () =
    match Client.connect addr wtext with
    | Error m -> C.fail "connect: %s" m
    | Ok c ->
      let i = ref 0 in
      let db, p = if t mod 2 = 0 then main else side in
      while not (Atomic.get stop) do
        let v = (t * 1_000_000) + !i in
        incr i;
        match Client.write c db ~why:"drill" [ Resolve.Add (-1, p, Int v) ] with
        | Ok r -> acked.(t) <- (v, r.group) :: acked.(t)
        | Error { code = "unreachable"; _ } -> ()
        | Error e -> C.fail "a write failed: %s %s" e.code e.message
        | exception Client.Broken _ -> ()
      done;
      (try Client.close c with _ -> ())
  in
  let ts = List.init n (fun t -> Thread.create (writer t) ()) in
  Thread.delay 1.0;
  (* a live database verified: whole up to the frame being written *)
  let code, out = run [ "verify"; data // "main" ] in
  C.check (code = 0) "verify of a live database: exit 0 (%s)" (String.concat " | " (lines out));
  (* the backup, while the writes go on *)
  let before = Array.map (fun l -> l) acked in
  let dest = dir // "backup" in
  let code, out = run [ "backup"; "--config"; cfg; dest ] in
  C.check (code = 0) "backup while writing: exit 0 (%s)" (String.concat " | " (lines out));
  let folder = match List.rev (lines out) with l :: _ -> List.hd (String.split_on_char ' ' l) | [] -> "" in
  C.check (Sys.file_exists (folder // "main" // "closed") && Sys.file_exists (folder // "side" // "closed")) "the dated folder holds both copies (%s)" folder;
  (* a backup killed in its middle, then one that removes what it left *)
  Thread.delay 1.1;
  let k = spawn [ "backup"; "--config"; cfg; dest ] in
  Thread.delay 0.02;
  Unix.kill k Sys.sigkill;
  ignore (Unix.waitpid [] k);
  let left = Array.to_list (Sys.readdir dest) in
  C.check (List.for_all (fun f -> f = "cepheus-backup.lock" || Filename.check_suffix f ".partial" || Sys.file_exists (dest // f // "main" // "closed")) left)
    "a killed backup leaves only whole dated folders and a partial one (%s)" (String.concat " " left);
  Thread.delay 1.1;
  let code, out = run [ "backup"; "--config"; cfg; dest ] in
  C.check (code = 0) "the next backup: exit 0 (%s)" (String.concat " | " (lines out));
  C.check (not (Array.exists (fun f -> Filename.check_suffix f ".partial") (Sys.readdir dest))) "no partial folder left";
  (* the server killed under the writes, and started again: the writers' library sends their unanswered writes again *)
  Thread.delay 0.3;
  Unix.kill !pid Sys.sigkill;
  ignore (Serve.wait !pid);
  pid := Serve.start bin cfg;
  wait_ready sock;
  Thread.delay 0.2;
  Atomic.set stop true;
  List.iter Thread.join ts;
  (* restore the first backup into a new data directory *)
  let rcfg, rsock, rdata = config (dir // "b") "restored" in
  let rw, ra = tokens (dir // "b") in
  Unix.mkdir rdata 0o700;
  List.iter
    (fun db ->
      let code, out = run [ "restore"; folder // db; rdata // db ] in
      C.check (code = 0) "restore %s: exit 0 (%s)" db (String.concat " | " (lines out)))
    [ "main"; "side" ];
  (* the original, recovered by its server, then stopped: the oracle's journal *)
  let code, _ = run [ "restore"; folder // "main"; data // "main"; "--replace" ] in
  C.check (code = 2) "a restore into the database of a running server is refused";
  let code, _ = run [ "stop"; "--config"; cfg ] in
  C.check (code = 0) "cepheus stop";
  ignore (Serve.wait !pid);
  List.iteri
    (fun i db ->
      let g, f = opened (rdata // db) in
      let mine = List.concat (List.filteri (fun t _ -> t mod 2 = i) (Array.to_list before)) in
      let newest = List.fold_left (fun m (_, g) -> max m g) 0 mine in
      C.check (g >= newest) "%s: restored at group %d, after the newest acknowledged before the backup (%d)" db g newest;
      let missing = List.length (List.filter (fun (v, _) -> not (has_int f v)) mine) in
      C.check (missing = 0) "%s: every write acknowledged before the backup is restored (%d of %d missing)" db missing (List.length mine);
      C.check (C.F.equal f (oracle (data // db) g)) "%s: the facts of the original journal's groups 1..%d" db g;
      if db = "main" then begin
        let half = max 1 (g / 2) in
        let r2 = dir // "half" in
        let code, out = run [ "restore"; folder // db; r2; "--to-group"; string_of_int half ] in
        C.check (code = 0) "restore --to-group %d: exit 0 (%s)" half (String.concat " | " (lines out));
        let g2, f2 = opened r2 in
        C.check (g2 = half && C.F.equal f2 (oracle (data // db) half)) "restore --to-group %d: at %d, the oracle's facts" half g2;
        (* a restore killed in its middle: the folder it was to make is absent, the next one removes what it left *)
        let r3 = dir // "killed" in
        let k = spawn [ "restore"; folder // db; r3 ] in
        Thread.delay 0.01;
        Unix.kill k Sys.sigkill;
        ignore (Unix.waitpid [] k);
        C.check ((not (Sys.file_exists r3)) || fst (opened r3) = g) "a killed restore leaves no half database";
        if not (Sys.file_exists r3) then begin
          let code, out = run [ "restore"; folder // db; r3 ] in
          C.check (code = 0 && not (Sys.file_exists (r3 ^ ".restoring"))) "the next restore: done, what the killed one left removed (%s)" (String.concat " | " (lines out))
        end
      end)
    [ "main"; "side" ];
  (* a second backup into one folder at a time *)
  let lock = Unix.openfile (dest // "cepheus-backup.lock") [ Unix.O_RDWR ] 0 in
  Unix.lockf lock Unix.F_LOCK 0;
  let code, out = run [ "backup"; "--config"; cfg; dest ] in
  C.check (code = 2) "a second backup into the same folder is refused (%s)" (String.concat " | " (lines out));
  Unix.close lock;
  (* the restored data served by a server of its own *)
  let g, _ = opened (rdata // "main") in
  let rpid = Serve.start bin rcfg in
  wait_ready rsock;
  let ca = Result.get_ok (Client.connect (Client.Unix_socket rsock) ra) in
  (match Client.status ca with
   | Ok l ->
     C.check (List.assoc_opt "database.main.group" l = Some (string_of_int g)) "the restored server serves main at group %d" g;
     C.check (List.assoc_opt "database.main.epoch" l = Some "2") "in epoch 2 (%s)" (Option.value (List.assoc_opt "database.main.epoch" l) ~default:"?")
   | Error e -> C.fail "status: %s" e.message);
  Client.close ca;
  let cw = Result.get_ok (Client.connect (Client.Unix_socket rsock) rw) in
  (match Client.open_db cw "main" with
   | Ok db -> (
     match Client.write cw db ~why:"after the restore" [ Resolve.Add (-1, snd main, Int 42) ] with
     | Ok r -> C.check (r.group = g + 1) "a write after the restore: group %d" r.group
     | Error e -> C.fail "write: %s" e.message)
   | Error e -> C.fail "open_db: %s" e.message);
  Client.close cw;
  Unix.kill rpid Sys.sigterm;
  ignore (Serve.wait rpid);
  List.iter (fun d -> List.iter (fun n -> try Sys.remove (Follow.page_of_dir (d // n)) with Sys_error _ | Journal.Damaged _ -> ()) [ "main"; "side" ]) [ data ];
  let acked_total = Array.fold_left (fun a l -> a + List.length l) 0 acked in
  Printf.printf "server backup: %d writes acknowledged, a backup while writing, one killed, the server killed, restored whole and to a group\n%!" acked_total;
  C.rmrf dir;
  C.finish "server backup"
