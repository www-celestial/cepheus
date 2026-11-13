(* cluster.toml: what a server is, where it listens, where its data lives, which databases it holds. The same file on
   every machine of a cluster but for [me]. Read once at start; every rule is checked before anything opens. *)

type peer = { pname : string; address : string; clients : string option  (* where programs reach it (a Raft cluster) *) }

type tls = { ca : string; cert : string; key : string }

type t = {
  file : string;  (* the configuration's path *)
  name : string;
  id : string;  (* cph-c- and 16 hex digits: every handshake checks it *)
  me : string;
  peers : peer list;
  listen : (string * int) option;  (* TCP for programs: host, port *)
  socket : string option;  (* the directory of the Unix socket *)
  port : int;  (* the port that names the socket: listen's, or 7400 *)
  tls : tls option;
  data : string;
  cache : int;  (* bytes of run pages kept in memory *)
  domains : int;  (* I/O domains *)
  max_connections : int;  (* connections open at once, the local readers' included *)
  idle_timeout : int;  (* seconds a connection may go without a whole request (from its accept); 0: no limit *)
  databases : string list;
}

let default_port = 7400
let default_max_connections = 512
let default_idle_timeout = 600

exception Bad of string

let bad fmt = Printf.ksprintf (fun m -> raise (Bad m)) fmt

let socket_name port = Printf.sprintf ".s.cepheus.%d" port
let socket_path c = Option.map (fun d -> Filename.concat d (socket_name c.port)) c.socket
let tokens_path c = Filename.concat (Filename.dirname c.file) "tokens.toml"
(* the master key of the databases' vaults: beside cluster.toml, never in the data *)
let vault_key_path c = Filename.concat (Filename.dirname c.file) "vault.key"
let database_dir c name = Filename.concat c.data name

let valid_name s =
  s <> "" && String.length s <= 64
  && String.for_all (fun c -> (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '_' || c = '-') s

let valid_id s =
  String.length s = 22 && String.sub s 0 6 = "cph-c-"
  && String.for_all (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) (String.sub s 6 16)

(* "4G", "256M", "512K" or a number of bytes *)
let size s =
  let n = String.length s in
  if n = 0 then None
  else
    let mult, digits =
      match s.[n - 1] with
      | 'K' | 'k' -> 1 lsl 10, String.sub s 0 (n - 1)
      | 'M' | 'm' -> 1 lsl 20, String.sub s 0 (n - 1)
      | 'G' | 'g' -> 1 lsl 30, String.sub s 0 (n - 1)
      | _ -> 1, s
    in
    match int_of_string_opt digits with Some k when k > 0 -> Some (k * mult) | _ -> None

let host_port what s =
  match String.rindex_opt s ':' with
  | None -> bad "%s %S: host:port was expected" what s
  | Some i -> (
    let h = String.sub s 0 i and p = String.sub s (i + 1) (String.length s - i - 1) in
    let h = if String.length h >= 2 && h.[0] = '[' && h.[String.length h - 1] = ']' then String.sub h 1 (String.length h - 2) else h in
    match int_of_string_opt p with
    | Some p when p > 0 && p < 65536 && h <> "" -> h, p
    | _ -> bad "%s %S: host:port was expected" what s)

(* where programs reach peer [p] (a Raft cluster sends them to its leader): its [clients], or its host at this
   file's [clients] port *)
let client_address c p =
  match p.clients with
  | Some a -> a
  | None -> (
    let h, _ = host_port "[[peer]] address" p.address in
    let h = if String.contains h ':' then "[" ^ h ^ "]" else h in
    Printf.sprintf "%s:%d" h c.port)

(* the first address of a host for a TCP port *)
let resolve host port =
  match Unix.getaddrinfo host (string_of_int port) [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ] with
  | ai :: _ -> ai.Unix.ai_addr
  | [] -> failwith (Printf.sprintf "%s does not resolve" host)

let default_domains () = max 1 (min 4 (Domain.recommended_domain_count () / 2))

let of_toml file (doc : (string * Toml.value) list) =
  let base = Filename.dirname file in
  let path p = if Filename.is_relative p then Filename.concat base p else p in
  let table name =
    match List.assoc_opt name doc with
    | Some (Toml.Table t) -> Some t
    | Some _ -> bad "[%s] must be a table" name
    | None -> None
  in
  let tables name =
    match List.assoc_opt name doc with
    | Some (Toml.Array l) -> List.map (function Toml.Table t -> t | _ -> bad "[[%s]] must be tables" name) l
    | Some _ -> bad "%s must be written [[%s]]" name name
    | None -> []
  in
  let known where t keys =
    List.iter (fun (k, _) -> if not (List.mem k keys) then bad "[%s] has an unknown key %s" where k) t
  in
  let str where t k =
    match List.assoc_opt k t with
    | Some (Toml.String s) -> Some s
    | Some _ -> bad "[%s] %s must be a string" where k
    | None -> None
  in
  let need where t k = match str where t k with Some s -> s | None -> bad "[%s] needs %s" where k in
  List.iter
    (fun (k, _) ->
      if not (List.mem k [ "cluster"; "peer"; "clients"; "tls"; "storage"; "database" ]) then bad "unknown section %s" k)
    doc;
  let cl = match table "cluster" with Some t -> t | None -> bad "[cluster] is missing" in
  known "cluster" cl [ "name"; "id"; "me" ];
  let name = need "cluster" cl "name" and id = need "cluster" cl "id" and me = need "cluster" cl "me" in
  if not (valid_id id) then bad "[cluster] id %S is not an id made by cepheus cluster init (cph-c- and 16 hex digits)" id;
  let peers =
    List.map
      (fun t ->
        known "peer" t [ "name"; "address"; "clients" ];
        let pname = need "peer" t "name" and address = need "peer" t "address" in
        ignore (host_port "[[peer]] address" address);
        let clients = str "peer" t "clients" in
        Option.iter (fun c -> ignore (host_port "[[peer]] clients" c)) clients;
        { pname; address; clients })
      (tables "peer")
  in
  if peers = [] then bad "[[peer]] is missing: a single machine is a cluster of one peer";
  if not (List.exists (fun p -> p.pname = me) peers) then bad "[cluster] me = %S names no [[peer]]" me;
  let names = List.map (fun p -> p.pname) peers in
  if List.length (List.sort_uniq compare names) <> List.length names then bad "two [[peer]] have the same name";
  let clients = Option.value (table "clients") ~default:[] in
  known "clients" clients [ "listen"; "socket"; "domains"; "max_connections"; "idle_timeout" ];
  let listen = Option.map (host_port "[clients] listen") (str "clients" clients "listen") in
  let socket = Option.map path (str "clients" clients "socket") in
  if listen = None && socket = None then bad "[clients] needs listen (TCP), socket (a directory for the Unix socket), or both";
  let domains =
    match List.assoc_opt "domains" clients with
    | Some (Toml.Int n) when n >= 1 && n <= 64 -> n
    | Some _ -> bad "[clients] domains must be an integer from 1 to 64"
    | None -> default_domains ()
  in
  let max_connections =
    match List.assoc_opt "max_connections" clients with
    | Some (Toml.Int n) when n >= 1 && n <= 65536 -> n
    | Some _ -> bad "[clients] max_connections must be an integer from 1 to 65536"
    | None -> default_max_connections
  in
  let idle_timeout =
    match List.assoc_opt "idle_timeout" clients with
    | Some (Toml.Int n) when n >= 0 && n <= 604_800 -> n
    | Some _ -> bad "[clients] idle_timeout must be a number of seconds from 0 (no limit) to 604800 (a week)"
    | None -> default_idle_timeout
  in
  let tls =
    match table "tls" with
    | None -> None
    | Some t ->
      known "tls" t [ "ca"; "cert"; "key" ];
      Some { ca = path (need "tls" t "ca"); cert = path (need "tls" t "cert"); key = path (need "tls" t "key") }
  in
  (match listen, tls with
   | Some (h, _), None -> bad "[clients] listen = %S needs [tls]: programs reach the server over TCP with TLS only" h
   | _ -> ());
  if List.length peers > 1 && tls = None then
    bad "%d peers need [tls]: servers reach one another over TCP with mutual TLS only (a replica and its primary)" (List.length peers);
  let st = match table "storage" with Some t -> t | None -> bad "[storage] is missing" in
  known "storage" st [ "data"; "cache" ];
  let data = path (need "storage" st "data") in
  let cache =
    match str "storage" st "cache" with
    | None -> 1 lsl 30
    | Some s -> ( match size s with Some n -> n | None -> bad "[storage] cache %S: a size such as 4G, 256M was expected" s)
  in
  let databases =
    List.map
      (fun t ->
        known "database" t [ "name" ];
        let n = need "database" t "name" in
        if not (valid_name n) then bad "[[database]] name %S: lower-case letters, digits, '_' and '-', at most 64" n;
        n)
      (tables "database")
  in
  if databases = [] then bad "[[database]] is missing: the server holds the databases this file declares";
  if List.length (List.sort_uniq compare databases) <> List.length databases then bad "two [[database]] have the same name";
  let port = match listen with Some (_, p) -> p | None -> default_port in
  { file; name; id; me; peers; listen; socket; port; tls; data; cache; domains; max_connections; idle_timeout; databases }

let load file =
  match Toml.parse_file file with
  | doc -> ( try Ok (of_toml file doc) with Bad m -> Error (Printf.sprintf "%s: %s" file m))
  | exception Toml.Error (line, m) -> Error (Printf.sprintf "%s, line %d: %s" file line m)
  | exception Sys_error m -> Error m
