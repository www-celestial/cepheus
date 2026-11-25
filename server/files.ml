(* Files in the server: each database's vault (DIR/vault), opened at its first use, and the master key that opens
   every vault of the server, in vault.key beside cluster.toml (the cluster's folder, 0700): never in the data, so
   that a copy of the data (a backup, a stolen disk) opens nothing without it. The key is made at the first use when
   the file is missing, readable by the server's user only, and never logged.

   A file is a thing of a file kind K, with five facts: K/Name (a text), K/Size (an int), K/Type (a text: a media
   type), K/Owner (a link: the thing whose key seals the bytes; none for the database's own key) and K/Content (the
   root of its bytes in the vault, 64 hexadecimal digits). Their rights are the kind's (G16): to put a file, a right
   to add to K; to load one, a right to read K. *)

open Cepheus
open Cepheus_vault

type cell = {
  m : Mutex.t;
  mutable vault : Vault.t option;
  dir : string;
  disk : Disk.t;
  master : unit -> (string, string) result;
  existing : unit -> (string, string) result;  (* the master key, never made (a Raft follower's) *)
}

let cell ?(disk = Disk.real) ?existing ~master dir =
  { m = Mutex.create (); vault = None; dir; disk; master; existing = Option.value existing ~default:master }

(* the vault, opened at its first use; [make] false: with a master key that exists, never one made (a Raft cluster's
   servers share one: a follower that lacks it must not make another) *)
let vault ?(make = true) c =
  Mutex.protect c.m (fun () ->
      match c.vault with
      | Some v -> Ok v
      | None -> (
        match (if make then c.master else c.existing) () with
        | Error m -> Error m
        | Ok key -> (
          match Vault.open_ c.disk c.dir ~master:key with
          | Ok v -> c.vault <- Some v; Ok v
          | Error e -> Error (Vault.message e))))

let close c = Mutex.protect c.m (fun () -> Option.iter Vault.close c.vault; c.vault <- None)

(* ---- the master key ---- *)

let log_made = ref (fun (_ : string) -> ())

(* the 32 bytes of [path], made when missing (written beside and renamed: whole or not at all) unless [make] is false;
   refused when it is a link, has another size, or is readable by anyone but its owner *)
let master_file ?(make = true) path =
  let read () =
    match Unix.lstat path with
    | st when st.st_kind <> Unix.S_REG -> Error (path ^ " is not a plain file")
    | st when st.st_perm land 0o077 <> 0 -> Error (Printf.sprintf "%s is readable by others (mode %o): chmod 600 it" path st.st_perm)
    | st when st.st_size <> 32 -> Error (path ^ " is not a vault key (32 bytes)")
    | _ -> Ok (In_channel.with_open_bin path (fun ic -> really_input_string ic 32))
  in
  match Unix.lstat path with
  | _ -> read ()
  | exception Unix.Unix_error (Unix.ENOENT, _, _) when not make ->
    Error (path ^ " is missing: the servers of a Raft cluster share one vault key; copy the leader's here (mode 0600)")
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> (
    let tmp = path ^ ".tmp" in
    match
      (try Unix.unlink tmp with Unix.Unix_error _ -> ());
      let fd = Unix.openfile tmp [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ] 0o600 in
      Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
          let k = Native.random 32 in
          if Unix.write_substring fd k 0 32 <> 32 then failwith "short write";
          Unix.fsync fd);
      Unix.rename tmp path;
      let d = Unix.openfile (Filename.dirname path) [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
      Fun.protect ~finally:(fun () -> Unix.close d) (fun () -> Unix.fsync d)
    with
    | () -> !log_made path; read ()
    | exception Unix.Unix_error (e, call, _) -> Error (Printf.sprintf "%s: %s: %s" path call (Unix.error_message e))
    | exception Failure m -> Error (path ^ ": " ^ m))
  | exception Unix.Unix_error (e, _, _) -> Error (Printf.sprintf "%s: %s" path (Unix.error_message e))

(* ---- a file kind ---- *)

let fields = [ "Name"; "Size"; "Type"; "Owner"; "Content" ]

type props = { pname : int; psize : int; ptype : int; powner : int; pcontent : int }

(* the five properties of kind [k], declared with their types, or why not *)
let props_of (v : Store.view) k =
  let p f typ =
    match Schema.by_name v.schema (k ^ "/" ^ f) with
    | Some id -> (
      match Schema.find v.schema id with
      | Some d when d.typ = typ && not d.many -> Ok id
      | _ -> Error (Printf.sprintf "%s/%s is not a file kind's property (%s, one value)" k f (Value.typ_name typ)))
    | None -> Error (Printf.sprintf "%s is not a file kind of this database: declare %s/%s first" k k f)
  in
  match p "Name" Ttext, p "Size" Tint, p "Type" Ttext, p "Owner" Tlink, p "Content" Ttext with
  | Ok pname, Ok psize, Ok ptype, Ok powner, Ok pcontent -> Ok { pname; psize; ptype; powner; pcontent }
  | (Error m, _, _, _, _) | (_, Error m, _, _, _) | (_, _, Error m, _, _) | (_, _, _, Error m, _) | (_, _, _, _, Error m) -> Error m

(* the facts of a new file *)
let facts p ~name ~typ ~owner ~size ~root =
  [ Resolve.Add (-1, p.pname, Text name); Add (-1, p.psize, Int size); Add (-1, p.ptype, Text typ); Add (-1, p.pcontent, Text (Vault.hex root)) ]
  @ if owner > 0 then [ Resolve.Add (-1, p.powner, Link owner) ] else []

(* the root of a file: the value of its Content, a property whose name ends with /Content *)
let root_of (v : Store.view) thing prop =
  match Schema.find v.schema prop with
  | Some d when d.typ = Ttext && Filename.check_suffix d.name "/Content" -> (
    match Cepheus.values v thing prop with
    | [ Text h ] -> ( match Vault.of_hex h with Some r -> Ok r | None -> Error ("invalid", "this value is not the root of a file"))
    | _ -> Error ("missing", Printf.sprintf "thing %d has no file of this kind" thing))
  | _ -> Error ("invalid", "a file is loaded by the Content property of its kind")

(* ---- bounds ---- *)

let max_name = 4096
let max_type = 255

(* a connection's files being put at once *)
let max_puts = 4

(* the largest file (1 TiB): a Put that sends more is refused, its bytes already stored left to the vault's cleaning *)
let max_size = ref (1 lsl 40)

let code_of (e : Vault.error) =
  match e with
  | Missing m -> "missing", m
  | Damaged m -> "damaged", m
  | Erased _ -> "erased", Vault.message e
  | Io m -> "io", m
  | Invalid m -> "invalid", m
  | Busy m -> "busy", m

(* a file being put on a connection *)
type put = { w : Vault.writer; p : props; meta : Wire.request; mutable bytes : int }
