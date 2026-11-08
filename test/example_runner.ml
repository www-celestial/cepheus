(* Runs the documentation's examples (test/extract.ml): each in a fresh directory of its own under $CEPHEUS_TMP (the
   system's temp dir by default), with its standard output captured and compared with the block that follows it. *)

let rec remove p =
  match Unix.lstat p with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun n -> remove (Filename.concat p n)) (Sys.readdir p);
    Unix.rmdir p
  | _ -> Unix.unlink p
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let read_file p =
  let ic = open_in_bin p in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

(* trailing spaces and blank lines do not count *)
let normal s =
  let lines = List.map (fun l -> let n = ref (String.length l) in while !n > 0 && l.[!n - 1] = ' ' do decr n done; String.sub l 0 !n)
      (String.split_on_char '\n' s) in
  let rec drop = function "" :: r -> drop r | l -> l in
  String.concat "\n" (List.rev (drop (List.rev lines)))

let run examples =
  let base = try Sys.getenv "CEPHEUS_TMP" with Not_found -> Filename.get_temp_dir_name () in
  let root = Filename.concat base (Printf.sprintf "cepheus-examples-%d" (Unix.getpid ())) in
  remove root;
  Unix.mkdir root 0o755;
  let home = Sys.getcwd () in
  let failures = ref 0 and checked = ref 0 in
  List.iteri
    (fun i (file, line, f, expected) ->
      let dir = Filename.concat root (string_of_int i) in
      Unix.mkdir dir 0o755;
      Sys.chdir dir;
      let out = Filename.concat dir "stdout" in
      flush stdout;
      let saved = Unix.dup Unix.stdout in
      let fd = Unix.openfile out [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o644 in
      Unix.dup2 fd Unix.stdout;
      Unix.close fd;
      let result = match f () with () -> Ok () | exception e -> Error (Printexc.to_string e) in
      flush stdout;
      Unix.dup2 saved Unix.stdout;
      Unix.close saved;
      Sys.chdir home;
      let got = read_file out in
      incr checked;
      (match result, expected with
       | Error e, _ -> incr failures; Printf.printf "FAIL %s:%d raised %s\n%s" file line e got
       | Ok (), Some want when normal want <> normal got ->
         incr failures;
         Printf.printf "FAIL %s:%d printed:\n%s\nexpected:\n%s\n" file line got want
       | Ok (), _ -> ());
      flush stdout)
    examples;
  remove root;
  Printf.printf "examples: %d examples run, %d with their output checked, %d failures\n" !checked
    (List.length (List.filter (fun (_, _, _, e) -> e <> None) examples)) !failures;
  exit (if !failures = 0 then 0 else 1)
