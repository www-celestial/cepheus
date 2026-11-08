(* Real crashes. A child process writes with several client threads and prints each confirmation; the parent kills
   it with SIGKILL at a random moment, reopens the database (recovery), and checks that every confirmed group is there
   with its exact content (G1-G3), on the real disk and the real threads; merges run every 50 changes, so that many
   kills land inside one: recovery must set no snapshot aside and leave no merge's file (G12). One more thread loads:
   large groups of 150 new things (300 additions, the path of large groups from 200 here, in chunks of 64), whose
   frames are written by pieces beside their merges and forced every 2 KB, so that kills land inside them too; its
   first and last things are checked. A rule marks each client's thing in the client's own group: the mark must come
   back with it (a derived fact is durable with its group, replayed from the frame). Then it starts the next child on
   the same database. Usage: crash.exe DIR ROUNDS
   [SEED]. *)

open Cepheus
module C = Check

let clients = 8

let loaded = 150

let child dir =
  Engine.compact_min := 50;
  Resolve.large_min := 200;
  Bulk.chunk := 64;
  Journal.force_every := 2048;
  let db = match open_ dir with Ok db -> db | Error e -> prerr_endline (message e); exit 2 in
  let[@warning "-8"] (Ok [ name; seq; by; mark ]) =
    declare db [ prop ~unique:true "name" Ttext; prop "seq" Tint; prop "by" Tint; prop "mark" Tbool ] in
  (* a rule: each client's thing is marked, by the writer, in the client's group (the loader's things are not) *)
  ignore (define db [ { name = "marked"; vars = 2; where = [ { e = Var 0; p = by; v = Var 1 } ]; ranges = [];
                        head = Give { e = Var 0; p = mark; v = Val (Bool true) } } ]);
  let m = Mutex.create () in
  let run c =
    let k = ref 0 in
    while true do
      incr k;
      let label = Printf.sprintf "%d-%d-%d" (Unix.getpid ()) c !k in
      match write db ~by:c ~why:"crash" [ Add (-1, name, Text label); Add (-1, seq, Int !k); Add (-1, by, Int c) ] with
      | Ok r ->
        Mutex.lock m;
        Printf.printf "%d %s %d\n%!" r.group label !k;
        Mutex.unlock m
      | Error e -> prerr_endline (message e); exit 3
    done
  in
  let load () =
    let k = ref 0 in
    while true do
      incr k;
      let label = Printf.sprintf "%d-L-%d" (Unix.getpid ()) !k in
      let ops = List.concat (List.init loaded (fun j -> [ Add (-j - 1, name, Text (Printf.sprintf "%s-%d" label j)); Add (-j - 1, seq, Int !k) ])) in
      match write db ~by:clients ~why:"load" ops with
      | Ok r ->
        Mutex.lock m;
        Printf.printf "%d %s-0 %d\n%d %s-%d %d\n%!" r.group label !k r.group label (loaded - 1) !k;
        Mutex.unlock m
      | Error e -> prerr_endline (message e); exit 3
    done
  in
  let ts = Thread.create load () :: List.init clients (fun c -> Thread.create run c) in
  List.iter Thread.join ts

let parent dir rounds seed =
  let r = Rng.make seed in
  let total = ref 0 and recov = ref [] and in_merge = ref 0 in
  let sdir = Filename.concat dir "snapshots" in
  let tmps () = if Sys.file_exists sdir then List.filter (fun f -> Filename.check_suffix f ".tmp") (Array.to_list (Sys.readdir sdir)) else [] in
  for round = 1 to rounds do
    let rd, wr = Unix.pipe ~cloexec:true () in
    let pid = Unix.create_process Sys.executable_name [| Sys.executable_name; "--child"; dir |] Unix.stdin wr Unix.stderr in
    Unix.close wr;
    let ic = Unix.in_channel_of_descr rd in
    let acks = ref [] in
    let until = Unix.gettimeofday () +. (0.02 +. (float_of_int (Rng.int r 400) /. 1000.)) in
    (* read confirmations until the deadline, then kill: lines already written stay in the pipe *)
    let reader = Thread.create (fun () ->
        try
          while true do
            let l = input_line ic in
            Scanf.sscanf l "%d %s %d" (fun g label k -> acks := (g, label, k) :: !acks)
          done
        with End_of_file -> ()) () in
    while Unix.gettimeofday () < until do Thread.delay 0.005 done;
    Unix.kill pid Sys.sigkill;
    ignore (Unix.waitpid [] pid);
    Thread.join reader;
    close_in ic;
    if tmps () <> [] then incr in_merge;
    let t0 = Unix.gettimeofday () in
    match open_ dir with
    | Error e -> C.fail "round %d: recovery failed: %s" round (message e)
    | Ok db ->
      recov := (Unix.gettimeofday () -. t0) :: !recov;
      C.check (not (List.exists (fun n -> String.length n > 8 && String.sub n 0 8 = "snapshot") (notes db)))
        "round %d: a snapshot was set aside: %s" round (String.concat "; " (notes db));
      C.check (tmps () = []) "round %d: a merge's file was left" round;
      let v = view db in
      let name = Option.get (property v "name") and seq = Option.get (property v "seq") and mark = Option.get (property v "mark") in
      List.iter
        (fun (g, label, k) ->
          incr total;
          C.check (group v >= g) "round %d: group %d confirmed, recovered up to %d" round g (group v);
          let loaded = String.contains label 'L' in
          match things v name (Text label) with
          | [ e ] ->
            C.check (values v e seq = [ Int k ]) "round %d: %s has the wrong content" round label;
            (* the derived fact came back with its group, from the frame: G1 for derived facts *)
            C.check (values v e mark = (if loaded then [] else [ Bool true ])) "round %d: %s has the wrong mark" round label
          | l -> C.fail "round %d: confirmed %s (group %d) found %d times" round label g (List.length l))
        !acks;
      close db
  done;
  let a = Array.of_list (List.sort compare !recov) in
  let n = Array.length a in
  Printf.printf "crash: %d kills (%d inside a merge), %d confirmed groups checked, recovery median %.1f ms, max %.1f ms\n"
    rounds !in_merge !total (1000. *. a.(n / 2)) (1000. *. a.(n - 1));
  C.finish "crash"

let () =
  match Sys.argv with
  | [| _; "--child"; dir |] -> child dir
  | [| _; dir; rounds |] -> parent dir (int_of_string rounds) 42
  | [| _; dir; rounds; seed |] -> parent dir (int_of_string rounds) (int_of_string seed)
  | _ -> prerr_endline "crash.exe DIR ROUNDS [SEED]"; exit 2
