(* The bank test (as in Jepsen): accounts and transfers. Client threads move money with read-modify-write groups
   guarded by Expect; reader domains, on other cores, check in every view they take that the total never changes
   and that views never go back (G4 serializable writes, G5 stable views). Usage: bank.exe DIR SECONDS. *)

open Cepheus
module C = Check

let accounts = 8
let start = 100

let () =
  let dir, secs = match Sys.argv with [| _; d; s |] -> d, float_of_string s | _ -> prerr_endline "bank.exe DIR SECONDS"; exit 2 in
  Check.rmrf dir;
  let db = Result.get_ok (open_ dir) in
  let[@warning "-8"] (Ok [ bal ]) = declare db [ prop "balance" Tint ] in
  let r = Result.get_ok (write db (List.init accounts (fun i -> Add (-(i + 1), bal, Int start)))) in
  let ids = Array.init accounts (fun i -> thing r (-(i + 1))) in
  let stop = Atomic.make false in
  let moved = Atomic.make 0 and conflicts = Atomic.make 0 in
  let balance v a = match values v a bal with [ Int x ] -> x | _ -> -1_000_000 in
  let client c () =
    let g = Rng.make c in
    while not (Atomic.get stop) do
      let a = ids.(Rng.int g accounts) and b = ids.(Rng.int g accounts) in
      if a <> b then begin
        let v = view db in
        let ba = balance v a and bb = balance v b in
        let amt = Rng.int g 20 in
        match
          write db ~by:c ~why:"transfer"
            [ Expect (a, bal, Some (Int ba)); Expect (b, bal, Some (Int bb)); Add (a, bal, Int (ba - amt)); Add (b, bal, Int (bb + amt)) ]
        with
        | Ok _ -> Atomic.incr moved
        | Error (Conflict _) -> Atomic.incr conflicts
        | Error e -> C.fail "transfer: %s" (message e)
      end
    done
  in
  let reader () =
    let seen = ref 0 and last = ref 0 and bad = ref 0 in
    while not (Atomic.get stop) do
      let v = view db in
      if group v < !last then incr bad;
      last := group v;
      let total = Array.fold_left (fun acc a -> acc + balance v a) 0 ids in
      if total <> accounts * start then incr bad;
      incr seen
    done;
    !seen, !bad
  in
  let readers = List.init 2 (fun _ -> Domain.spawn reader) in
  let clients = List.init 16 (fun c -> Thread.create (client c) ()) in
  Unix.sleepf secs;
  Atomic.set stop true;
  List.iter Thread.join clients;
  let views = ref 0 in
  List.iter (fun d -> let seen, bad = Domain.join d in views := !views + seen; C.check (bad = 0) "a reader saw %d bad views" bad) readers;
  let v = view db in
  C.check (Array.fold_left (fun acc a -> acc + balance v a) 0 ids = accounts * start) "final total";
  close db;
  let db = Result.get_ok (open_ dir) in
  C.check (Array.fold_left (fun acc a -> acc + balance (view db) a) 0 ids = accounts * start) "total after reopening";
  close db;
  Check.rmrf dir;
  Printf.printf "bank: %d transfers, %d conflicts, %d views checked by 2 reader domains\n" (Atomic.get moved) (Atomic.get conflicts) !views;
  C.finish "bank"
