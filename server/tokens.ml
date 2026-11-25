(* Tokens: how a program proves who it is, and what it may do (G16). A token is 32 random bytes from the kernel, shown
   once as "cph_" and 43 characters of base64url; the server keeps only its BLAKE2b-256 hash, in tokens.toml beside
   cluster.toml, readable by the server's user only:

     [[token]]
     name = "shop-web"
     hash = "blake2b-256:9f4c...e1"
     databases = { shop = "write", stock = "read" }
     [[token]]
     name = "ops"
     hash = "blake2b-256:51aa...07"
     admin = true

   read: Get, Find; write: read and Write; admin: the server's operations (status), no data right by itself.
   A database's right may also name kinds, by the kinds' names (a property client/City is of the kind client):

     databases = { compta = { read = ["compte", "transaction"], add = ["transaction"] } }

   read: Get, Find and Watch of the facts of those kinds only; add: Write of facts of those kinds, and declaring their
   properties. Such a token never reads locally (a local reader maps the whole database): its reads go to the server. *)

type right = Read | Write | Kinds of { read : string list; add : string list }

type token = { name : string; hash : string;  (* 32 raw bytes *) databases : (string * right) list; admin : bool }

type t = { tokens : token list; by_hash : (string, token) Hashtbl.t }

let empty = { tokens = []; by_hash = Hashtbl.create 1 }

let prefix = "cph_"
let hash_prefix = "blake2b-256:"

let hash_of_text s = Digest.BLAKE256.string s

let hex s = String.concat "" (List.init (String.length s) (fun i -> Printf.sprintf "%02x" (Char.code s.[i])))

let of_hex s =
  if String.length s mod 2 <> 0 then None
  else
    try Some (String.init (String.length s / 2) (fun i -> Char.chr (int_of_string ("0x" ^ String.sub s (2 * i) 2))))
    with _ -> None

let b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

(* base64url without padding (RFC 4648 section 5) *)
let base64url s =
  let b = Buffer.create ((String.length s * 4 / 3) + 4) in
  let n = String.length s in
  let byte i = Char.code s.[i] in
  let i = ref 0 in
  while !i + 2 < n do
    let x = (byte !i lsl 16) lor (byte (!i + 1) lsl 8) lor byte (!i + 2) in
    for k = 3 downto 0 do Buffer.add_char b b64.[(x lsr (6 * k)) land 63] done;
    i := !i + 3
  done;
  (match n - !i with
   | 1 -> let x = byte !i lsl 16 in Buffer.add_char b b64.[x lsr 18]; Buffer.add_char b b64.[(x lsr 12) land 63]
   | 2 ->
     let x = (byte !i lsl 16) lor (byte (!i + 1) lsl 8) in
     Buffer.add_char b b64.[x lsr 18]; Buffer.add_char b b64.[(x lsr 12) land 63]; Buffer.add_char b b64.[(x lsr 6) land 63]
   | _ -> ());
  Buffer.contents b

(* n bytes from the kernel's generator *)
let random n = In_channel.with_open_bin "/dev/urandom" (fun ic -> really_input_string ic n)

let generate () =
  let text = prefix ^ base64url (random 32) in
  text, hash_of_text text

(* the same length, every byte compared: no early exit an attacker could time *)
let equal_ct a b =
  String.length a = String.length b
  && (let d = ref 0 in String.iteri (fun i c -> d := !d lor (Char.code c lxor Char.code b.[i])) a; !d = 0)

let check t text =
  if String.length text > 256 then None
  else
    let h = hash_of_text text in
    match Hashtbl.find_opt t.by_hash h with Some tok when equal_ct tok.hash h -> Some tok | _ -> None

let right t db = List.assoc_opt db t.databases

(* The kind of a property: its name up to the first '/', or the whole name *)
let kind_of = Cepheus.Schema.kind_of

let reads_kind r k = match r with Read | Write -> true | Kinds x -> List.mem k x.read
let adds_kind r k = match r with Write -> true | Read -> false | Kinds x -> List.mem k x.add

(* as cepheus token add takes it and token list shows it *)
let right_name = function
  | Read -> "read"
  | Write -> "write"
  | Kinds { read; add } ->
    String.concat ";" (List.filter_map (fun (w, l) -> if l = [] then None else Some (w ^ ":" ^ String.concat "," l)) [ "read", read; "add", add ])

(* "read", "write", or "read:K,K;add:K": the right of --database DB=RIGHT *)
let right_of_name s =
  match s with
  | "read" -> Some Read
  | "write" -> Some Write
  | _ -> (
    let parts = List.map (fun p -> String.split_on_char ':' p) (String.split_on_char ';' s) in
    let kinds w = List.concat_map (function [ x; l ] when x = w -> String.split_on_char ',' l | _ -> []) parts in
    let known = List.for_all (function [ ("read" | "add"); l ] -> List.for_all Config.valid_name (String.split_on_char ',' l) | _ -> false) parts in
    match kinds "read", kinds "add" with
    | [], [] -> None
    | read, add when known -> Some (Kinds { read; add })
    | _ -> None)

let right_toml = function
  | (Read | Write) as r -> Toml.quote (right_name r)
  | Kinds { read; add } ->
    let list l = "[" ^ String.concat ", " (List.map Toml.quote l) ^ "]" in
    "{ " ^ String.concat ", " (List.filter_map (fun (w, l) -> if l = [] then None else Some (w ^ " = " ^ list l)) [ "read", read; "add", add ]) ^ " }"

let of_toml (doc : (string * Toml.value) list) =
  let fail fmt = Printf.ksprintf (fun m -> raise (Config.Bad m)) fmt in
  List.iter (fun (k, _) -> if k <> "token" then fail "unknown section %s" k) doc;
  let items =
    match List.assoc_opt "token" doc with
    | Some (Toml.Array l) -> List.map (function Toml.Table t -> t | _ -> fail "[[token]] must be tables") l
    | Some _ -> fail "token must be written [[token]]"
    | None -> []
  in
  let tokens =
    List.map
      (fun t ->
        List.iter (fun (k, _) -> if not (List.mem k [ "name"; "hash"; "databases"; "admin" ]) then fail "[[token]] has an unknown key %s" k) t;
        let name = match List.assoc_opt "name" t with Some (Toml.String s) when Config.valid_name s -> s | _ -> fail "a [[token]] needs a name (lower-case letters, digits, '_', '-')" in
        let hash =
          match List.assoc_opt "hash" t with
          | Some (Toml.String s)
            when String.length s > String.length hash_prefix && String.sub s 0 (String.length hash_prefix) = hash_prefix -> (
            match of_hex (String.sub s (String.length hash_prefix) (String.length s - String.length hash_prefix)) with
            | Some h when String.length h = 32 -> h
            | _ -> fail "token %s: a bad hash" name)
          | _ -> fail "token %s needs hash = \"blake2b-256:...\"" name
        in
        let databases =
          match List.assoc_opt "databases" t with
          | None -> []
          | Some (Toml.Table l) ->
            List.map
              (fun (db, v) ->
                match v with
                | Toml.String "read" -> db, Read
                | Toml.String "write" -> db, Write
                | Toml.Table kinds ->
                  let names w =
                    match List.assoc_opt w kinds with
                    | None -> []
                    | Some (Toml.Array l) ->
                      List.map (function Toml.String k when Config.valid_name k -> k | _ -> fail "token %s: the kinds of %s on %s are names of kinds" name w db) l
                    | Some _ -> fail "token %s: %s on %s is a list of kinds" name w db
                  in
                  List.iter (fun (k, _) -> if k <> "read" && k <> "add" then fail "token %s: the right on %s takes read and add, not %s" name db k) kinds;
                  (match names "read", names "add" with
                   | [], [] -> fail "token %s: the right on %s names no kind" name db
                   | read, add -> db, Kinds { read; add })
                | _ -> fail "token %s: the right on %s must be \"read\", \"write\" or { read = [...], add = [...] }" name db)
              l
          | Some _ -> fail "token %s: databases = { name = \"read\" | \"write\" | { read = [...], add = [...] }, ... }" name
        in
        let admin = match List.assoc_opt "admin" t with Some (Toml.Bool b) -> b | None -> false | Some _ -> fail "token %s: admin must be true or false" name in
        { name; hash; databases; admin })
      items
  in
  let names = List.map (fun t -> t.name) tokens in
  if List.length (List.sort_uniq compare names) <> List.length names then fail "two tokens have the same name";
  let by_hash = Hashtbl.create 16 in
  List.iter (fun t -> Hashtbl.replace by_hash t.hash t) tokens;
  { tokens; by_hash }

(* a missing file holds no token: the server then refuses every program *)
let load file =
  if not (Sys.file_exists file) then Ok empty
  else
    match Toml.parse_file file with
    | doc -> ( try Ok (of_toml doc) with Config.Bad m -> Error (Printf.sprintf "%s: %s" file m))
    | exception Toml.Error (line, m) -> Error (Printf.sprintf "%s, line %d: %s" file line m)
    | exception Sys_error m -> Error m

let to_toml t =
  let b = Buffer.create 256 in
  Buffer.add_string b "# Cepheus tokens: written by `cepheus token`; the server reloads this file when it changes.\n";
  List.iter
    (fun tok ->
      Buffer.add_string b "\n[[token]]\n";
      Printf.bprintf b "name = %s\n" (Toml.quote tok.name);
      Printf.bprintf b "hash = %s\n" (Toml.quote (hash_prefix ^ hex tok.hash));
      if tok.databases <> [] then
        Printf.bprintf b "databases = { %s }\n"
          (String.concat ", " (List.map (fun (d, r) -> Printf.sprintf "%s = %s" d (right_toml r)) tok.databases));
      if tok.admin then Buffer.add_string b "admin = true\n")
    t.tokens;
  Buffer.contents b

(* written beside, forced, renamed over, the directory forced; readable by the owner only *)
let save file t =
  let tmp = file ^ ".tmp" in
  let fd = Unix.openfile tmp [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC; Unix.O_CLOEXEC ] 0o600 in
  let s = to_toml t in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
      let n = Unix.write_substring fd s 0 (String.length s) in
      if n <> String.length s then failwith "short write";
      Unix.fsync fd);
  Unix.rename tmp file;
  let d = Unix.openfile (Filename.dirname file) [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  Fun.protect ~finally:(fun () -> Unix.close d) (fun () -> Unix.fsync d)

let with_tokens (_ : t) tokens =
  let by_hash = Hashtbl.create 16 in
  List.iter (fun tok -> Hashtbl.replace by_hash tok.hash tok) tokens;
  { tokens; by_hash }
