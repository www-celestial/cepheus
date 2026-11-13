(* Real crashes of files. A child process puts files into the vault of a database and writes each one's facts (its
   name, size and root) once its bytes are durable, as the server does, and prints each confirmation; the parent kills
   it with SIGKILL at a random moment, often in the middle of a put of several megabytes, opens the database and its
   vault again, and checks that every file the facts cite reads back whole and exact (its bytes made again from its
   name), that every confirmed file is there, and that no fact cites a file half written (V1). Then it starts the next
   child on the same database. Usage: vault_crash.exe DIR ROUNDS [SEED]. *)

open Cepheus
open Cepheus_vault
module C = Check

let master = String.make 32 'k'

(* the bytes of the file named [seed]: their size and content from it alone *)
let content seed =
  let r = Rng.make seed in
  let n = match Rng.int r 8 with 0 -> Rng.int r 40_000_000 | 1 | 2 -> Rng.int r 100_000 | _ -> Rng.int r 4_000_000 in
  if Rng.int r 2 = 0 then Bytes.init n (fun _ -> Char.chr (Rng.int r 256))
  else begin
    let words = [| "file "; "vault "; "chunk "; "a "; "of "; "\n"; "1234 " |] in
    let b = Buffer.create n in
    while Buffer.length b < n do Buffer.add_string b words.(Rng.int r (Array.length words)) done;
    Bytes.sub (Buffer.to_bytes b) 0 n
  end

let props db =
  match declare db [ prop "f/Name" Ttext; prop "f/Size" Tint; prop "f/Content" Ttext ] with
  | Ok [ name; size; content ] -> name, size, content
  | Ok _ -> assert false
  | Error e -> prerr_endline (message e); exit 2

let child dir =
  Vault.pack_limit := 8 lsl 20;
  let db = match open_ dir with Ok db -> db | Error e -> prerr_endline (message e); exit 2 in
  let pname, psize, pcontent = props db in
  let v = match Vault.open_ Disk.real (Filename.concat dir "vault") ~master with Ok v -> v | Error e -> prerr_endline (Vault.message e); exit 2 in
  let k = ref 0 in
  while true do
    incr k;
    let seed = (Unix.getpid () * 10_000) + !k in
    let b = content seed in
    let w = match Vault.writer v ~domain:(seed mod 3) ~cold:(seed mod 5 = 0) with Ok w -> w | Error e -> prerr_endline (Vault.message e); exit 3 in
    let o = ref 0 in
    while !o < Bytes.length b do
      let n = min (1 lsl 20) (Bytes.length b - !o) in
      (match Vault.feed w b !o n with Ok () -> () | Error e -> prerr_endline (Vault.message e); exit 3);
      o := !o + n
    done;
    match Vault.finish w with
    | Error e -> prerr_endline (Vault.message e); exit 3
    | Ok (root, size) -> (
      match write db ~why:"put" [ Add (-1, pname, Text (string_of_int seed)); Add (-1, psize, Int size); Add (-1, pcontent, Text (Vault.hex root)) ] with
      | Ok _ -> Printf.printf "%d\n%!" seed
      | Error e -> prerr_endline (message e); exit 3)
  done

let parent dir rounds seed =
  let r = Rng.make seed in
  let files = ref 0 and acked = ref 0 in
  for round = 1 to rounds do
    let rd, wr = Unix.pipe ~cloexec:true () in
    let pid = Unix.create_process Sys.executable_name [| Sys.executable_name; "--child"; dir |] Unix.stdin wr Unix.stderr in
    Unix.close wr;
    let ic = Unix.in_channel_of_descr rd in
    let acks = ref [] in
    let reader = Thread.create (fun () -> try while true do acks := int_of_string (input_line ic) :: !acks done with End_of_file | Sys_error _ -> ()) () in
    Unix.sleepf (0.05 +. (float_of_int (Rng.int r 1500) /. 1000.));
    Unix.kill pid Sys.sigkill;
    ignore (Unix.waitpid [] pid);
    Thread.join reader;
    close_in ic;
    (* the database and its vault opened again: recovery *)
    let db = match open_ dir with Ok db -> db | Error e -> C.fail "round %d: the database does not open: %s" round (message e); exit 1 in
    let v = match Vault.open_ Disk.real (Filename.concat dir "vault") ~master with Ok v -> v | Error e -> C.fail "round %d: the vault does not open: %s" round (Vault.message e); exit 1 in
    let pname, psize, pcontent = props db in
    let q = { vars = 3; ranges = []; where = [ { e = Var 0; p = pname; v = Var 1 }; { e = Var 0; p = pcontent; v = Var 2 } ] } in
    let rows = Result.get_ok (find (view db) q) in
    let found = Hashtbl.create 64 in
    List.iter
      (fun row ->
        match row.(1), row.(2) with
        | Text label, Text h -> (
          let s = int_of_string label in
          Hashtbl.replace found s ();
          let want = content s in
          match Vault.of_hex h with
          | None -> C.fail "round %d: file %s has no root" round label
          | Some root ->
            let out = Buffer.create (Bytes.length want) in
            (match Vault.load v root ~from:0 ~len:(Bytes.length want) (fun b o n -> Buffer.add_subbytes out b o n) with
             | Ok () -> C.check (Buffer.length out = Bytes.length want && Buffer.to_bytes out = want) "round %d: file %s reads back exact" round label
             | Error e -> C.fail "round %d: file %s: %s" round label (Vault.message e));
            (match values (view db) (match row.(0) with Link t -> t | _ -> -1) psize with
             | [ Int n ] -> C.check (n = Bytes.length want) "round %d: file %s's size" round label
             | _ -> C.fail "round %d: file %s has no size" round label))
        | _ -> C.fail "round %d: a file's facts of the wrong types" round)
      rows;
    List.iter (fun s -> C.check (Hashtbl.mem found s) "round %d: confirmed file %d is there" round s) !acks;
    files := Hashtbl.length found;
    acked := !acked + List.length !acks;
    Vault.close v;
    close db
  done;
  Printf.printf "%d rounds killed: %d files confirmed, %d cited at the end, each read back exact\n" rounds !acked !files

let () =
  match Array.to_list Sys.argv with
  | [ _; "--child"; dir ] -> child dir
  | [ _; dir; rounds ] -> parent dir (int_of_string rounds) 1; C.finish "vault crash"
  | [ _; dir; rounds; seed ] -> parent dir (int_of_string rounds) (int_of_string seed); C.finish "vault crash"
  | _ -> prerr_endline "usage: vault_crash.exe DIR ROUNDS [SEED]"; exit 2
