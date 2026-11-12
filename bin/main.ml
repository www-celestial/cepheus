(* The cepheus command.

     cepheus serve --config FILE                  run the server of FILE (cluster.toml) until SIGTERM or SIGINT
     cepheus stop --config FILE                   stop it (SIGTERM to the pid its data directory's lock names) and wait
     cepheus status --config FILE                 what it holds and does (an admin token in CEPHEUS_TOKEN)
     cepheus token add NAME [--database DB=read|write|read:KIND,...;add:KIND,...]... [--admin] --config FILE
                                                  a new token, printed once; its hash goes to tokens.toml
     cepheus token list --config FILE             the tokens' names and rights (never the tokens)
     cepheus token remove NAME --config FILE      a token removed: its connections are refused at their next request
     cepheus cluster init NAME --dir DIR [--host H]...
                                                  a new cluster: its CA (DIR/ca.pem, DIR/ca.key: keep the key offline),
                                                  the certificate of its first peer srv1 (DIR/srv1.pem, .key) for the
                                                  hosts H (default 127.0.0.1 and localhost), DIR/cluster.toml
     cepheus cluster cert NAME --dir DIR [--host H]...
                                                  a certificate of the cluster's CA for NAME and its hosts *)

open Cepheus_server

let die fmt = Printf.ksprintf (fun m -> prerr_endline ("cepheus: " ^ m); exit 1) fmt

let usage () =
  prerr_string
    "usage: cepheus serve|stop|status --config FILE\n\
    \       cepheus token add NAME [--database DB=read|write|read:KIND,...;add:KIND,...]... [--admin] --config FILE\n\
    \       cepheus token list|remove [NAME] --config FILE\n\
    \       cepheus cluster init|cert NAME --dir DIR [--host H]...\n";
  exit 2

let hosts = ref []

(* --config FILE, --database X (repeated), --admin, --dir DIR, --host H (repeated); the rest positional *)
let parse args =
  let config = ref None and dbs = ref [] and admin = ref false and dir = ref None and pos = ref [] in
  let rec go = function
    | "--host" :: h :: r -> hosts := h :: !hosts; go r
    | "--config" :: f :: r -> config := Some f; go r
    | "--database" :: d :: r -> dbs := d :: !dbs; go r
    | "--admin" :: r -> admin := true; go r
    | "--dir" :: d :: r -> dir := Some d; go r
    | x :: _ when String.length x > 1 && x.[0] = '-' -> die "unknown option %s" x
    | x :: r -> pos := x :: !pos; go r
    | [] -> ()
  in
  go args;
  !config, List.rev !dbs, !admin, !dir, List.rev !pos

let config_of = function
  | None -> die "--config FILE is needed"
  | Some f -> ( match Config.load f with Ok c -> c | Error m -> die "%s" m)

let serve cfg =
  match Net.serve cfg with
  | Ok () -> exit 0
  | Error m -> die "%s" m

let lock_pid cfg =
  let path = Filename.concat cfg.Config.data "cepheus.lock" in
  match In_channel.with_open_bin path In_channel.input_all with
  | s -> int_of_string_opt (String.trim s)
  | exception Sys_error _ -> None

let held cfg =
  let path = Filename.concat cfg.Config.data "cepheus.lock" in
  match Unix.openfile path [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0 with
  | exception Unix.Unix_error _ -> false
  | fd ->
    let h = match Unix.lockf fd Unix.F_TEST 0 with () -> false | exception Unix.Unix_error _ -> true in
    Unix.close fd;
    h

let stop cfg =
  if not (held cfg) then die "no server runs on %s" cfg.Config.data;
  match lock_pid cfg with
  | None -> die "the lock of %s names no process" cfg.Config.data
  | Some pid ->
    (try Unix.kill pid Sys.sigterm with Unix.Unix_error (e, _, _) -> die "process %d: %s" pid (Unix.error_message e));
    let t0 = Unix.gettimeofday () in
    while held cfg do
      if Unix.gettimeofday () -. t0 > 120. then die "process %d still runs after 120 s" pid;
      Unix.sleepf 0.02
    done;
    Printf.printf "stopped (process %d, %.0f ms)\n" pid ((Unix.gettimeofday () -. t0) *. 1e3)

let client_address cfg =
  match Config.socket_path cfg, cfg.Config.listen with
  | Some p, _ -> Client.Unix_socket p
  | None, Some (h, p) -> Client.Tcp (h, p)
  | None, None -> die "the configuration names no socket and no listen address"

let status cfg =
  let token = match Sys.getenv_opt "CEPHEUS_TOKEN" with Some t -> t | None -> die "CEPHEUS_TOKEN must hold an admin token" in
  match Client.connect ~program:"cepheus status" (client_address cfg) token with
  | Error m -> die "%s" m
  | Ok c -> (
    match Client.status c with
    | Ok l -> List.iter (fun (k, v) -> Printf.printf "%s: %s\n" k v) l
    | Error e -> die "%s: %s" e.code e.message)

let tokens_of cfg =
  let f = Config.tokens_path cfg in
  match Tokens.load f with Ok t -> f, t | Error m -> die "%s" m

let token_add cfg name dbs admin =
  if not (Config.valid_name name) then die "a token's name: lower-case letters, digits, '_' and '-', at most 64";
  let file, t = tokens_of cfg in
  if List.exists (fun (k : Tokens.token) -> k.name = name) t.tokens then die "a token named %s exists: remove it first" name;
  let databases =
    List.map
      (fun d ->
        match String.split_on_char '=' d with
        | [ db; r ] -> (match Tokens.right_of_name r with Some r -> db, r | None -> die "--database %s: DB=read, DB=write or DB=read:KIND,KIND;add:KIND" d)
        | _ -> die "--database %s: DB=read, DB=write or DB=read:KIND,KIND;add:KIND" d)
      dbs
  in
  List.iter (fun (db, _) -> if not (List.mem db cfg.databases) then die "%s declares no database %s" cfg.file db) databases;
  if databases = [] && not admin then die "a token needs --database DB=read|write|read:KIND,...;add:KIND,... or --admin";
  let text, hash = Tokens.generate () in
  Tokens.save file (Tokens.with_tokens t (t.tokens @ [ { Tokens.name; hash; databases; admin } ]));
  print_endline text;
  prerr_endline ("cepheus: token " ^ name ^ " added to " ^ file ^ "; it is shown only now")

let token_list cfg =
  let _, t = tokens_of cfg in
  List.iter
    (fun (k : Tokens.token) ->
      Printf.printf "%s%s%s\n" k.name
        (String.concat "" (List.map (fun (d, r) -> Printf.sprintf " %s=%s" d (Tokens.right_name r)) k.databases))
        (if k.admin then " admin" else ""))
    t.tokens

let token_remove cfg name =
  let file, t = tokens_of cfg in
  if not (List.exists (fun (k : Tokens.token) -> k.name = name) t.tokens) then die "no token named %s" name;
  Tokens.save file (Tokens.with_tokens t (List.filter (fun (k : Tokens.token) -> k.name <> name) t.tokens));
  prerr_endline ("cepheus: token " ^ name ^ " removed")

(* subjectAltName: the peer's name, and each host as an IP address or a DNS name *)
let san name hosts =
  let one h = match Unix.inet_addr_of_string h with _ -> "IP:" ^ h | exception Failure _ -> "DNS:" ^ h in
  String.concat "," (("DNS:" ^ name) :: List.map one (List.rev hosts))

let cert dir name hosts =
  if not (Config.valid_name name) then die "a peer's name: lower-case letters, digits, '_' and '-', at most 64";
  let f x = Filename.concat dir x in
  let hosts = if hosts = [] then [ "localhost"; "127.0.0.1" ] else hosts in
  match Tls.make_cert ~ca:(f "ca.pem", f "ca.key") ~cn:name ~san:(san name hosts) ~days:825 ~key:(f (name ^ ".key")) ~cert:(f (name ^ ".pem")) () with
  | Ok () -> Printf.printf "%s\n%s\n" (f (name ^ ".pem")) (f (name ^ ".key"))
  | Error m -> die "%s" m

let cluster_init name dir =
  if not (Config.valid_name name) then die "a cluster's name: lower-case letters, digits, '_' and '-', at most 64";
  (try Unix.mkdir dir 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let file = Filename.concat dir "cluster.toml" in
  if Sys.file_exists file then die "%s exists already" file;
  let id = "cph-c-" ^ Tokens.hex (Tokens.random 8) in
  let f x = Filename.concat dir x in
  (match Tls.make_cert ~cn:(name ^ " CA") ~san:"" ~days:3650 ~key:(f "ca.key") ~cert:(f "ca.pem") () with
   | Ok () -> ()
   | Error m -> die "the CA: %s" m);
  cert dir "srv1" !hosts;
  let s =
    Printf.sprintf
      "[cluster]\nname = %s\nid = %s\nme = \"srv1\"\n\n[[peer]]\nname = \"srv1\"\naddress = \"127.0.0.1:7401\"\n\n\
       [clients]\nsocket = \"run\"\nlisten = \"127.0.0.1:7400\"\n\n[tls]\nca = \"ca.pem\"\ncert = \"srv1.pem\"\nkey = \"srv1.key\"\n\n[storage]\ndata = \"data\"\ncache = \"1G\"\n\n[[database]]\nname = \"main\"\n"
      (Toml.quote name) (Toml.quote id)
  in
  Cepheus.Disk.write_file Cepheus.Disk.real file (Bytes.of_string s);
  (try Unix.mkdir (Filename.concat dir "run") 0o750 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Printf.printf "%s\n" file

let () =
  match Array.to_list Sys.argv with
  | _ :: cmd :: rest -> (
    let config, dbs, admin, dir, pos = parse rest in
    match cmd, pos with
    | "serve", [] -> serve (config_of config)
    | "stop", [] -> stop (config_of config)
    | "status", [] -> status (config_of config)
    | "token", [ "add"; name ] -> token_add (config_of config) name dbs admin
    | "token", [ "list" ] -> token_list (config_of config)
    | "token", [ "remove"; name ] -> token_remove (config_of config) name
    | "cluster", [ "init"; name ] -> cluster_init name (match dir with Some d -> d | None -> die "--dir DIR is needed")
    | "cluster", [ "cert"; name ] -> cert (match dir with Some d -> d | None -> die "--dir DIR is needed") name !hosts
    | _ -> usage ())
  | _ -> usage ()
