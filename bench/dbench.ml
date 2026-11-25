(* Deletes and links that name a kind, beside PostgreSQL's DELETE with the same foreign keys (bench/pg/fk.sql).

     dbench.exe load DIR               a database in DIR: 10,000 clients, 100,000 invoices (invoice/client names the
                                       kind client: refuse), 200,000 lines spread over them (line/invoice: cascade),
                                       and the measured things: clients of 0, 100 and 10,000 invoices, invoices of 0,
                                       100 and 10,000 lines, and of 0, 100 and 10,000 notes (note/about: clear)
     dbench.exe delete DIR RUNS        each Delete of those, on a fork of the database (the writer's work, nothing on
                                       the disk; the fork thrown away, so every run deletes the same): RUNS runs each,
                                       microseconds, one a line, as "refuse 100 123.4"; then a group of Retract of
                                       the facts of the 10,000 lines that cascade 10000 deletes ("retract 10000")
     dbench.exe write DIR N MODE       N groups of one invoice of a client each, on a fork: MODE to (invoice/client,
                                       which names client) or plain (bill/client, a link to any thing): microseconds a
                                       group, the median of 5 passes of N / 5

   Without the links' facts (a Cepheus before them), [load] makes no link name a kind and [write to] is refused: the
   plain writes still measure, so that the same program gives the A/B against that Cepheus. *)

open Cepheus

let now = Unix.gettimeofday

let props =
  [ prop "client/name" Ttext; prop "client/city" Ttext; prop "invoice/client" Tlink; prop "invoice/total" (Tmoney 2);
    prop "line/invoice" Tlink; prop "line/price" (Tmoney 2); prop "note/about" Tlink; prop "note/text" Ttext;
    prop "bill/client" Tlink; prop "bill/total" (Tmoney 2) ]

let ids db = Result.get_ok (declare db props)

(* the facts of cepheus/to and cepheus/delete, as Cepheus.link_to writes them; a Cepheus before them refuses them *)
let links db p kind od =
  match write db ~why:"links" [ Add (p, 7, Text kind); Add (p, 8, Text od) ] with
  | Ok _ -> true
  | Error e -> Printf.printf "no links (%s)\n%!" (message e); false

let chunked db ops =
  (* groups of 50,000 operations: the path of loads *)
  let rec go l acc n =
    match l with
    | [] -> if acc <> [] then ignore (Result.get_ok (write db (List.rev acc)))
    | x :: r -> if n = 50_000 then (ignore (Result.get_ok (write db (List.rev acc))); go r [ x ] 1) else go r (x :: acc) (n + 1)
  in
  go ops [] 0

let load dir =
  let db = Result.get_ok (open_ dir) in
  let[@warning "-8"] [ name; city; iclient; itotal; linvoice; lprice; nabout; ntext; _; _ ] = ids db in
  let linked = links db iclient "client" "refuse" && links db linvoice "invoice" "cascade" && links db nabout "invoice" "clear" in
  let t0 = now () in
  (* clients *)
  let r = Result.get_ok (write db (List.concat (List.init 10_000 (fun k -> [ Add (-(k + 1), name, Text (Printf.sprintf "client-%d" k)); Add (-(k + 1), city, Text (Printf.sprintf "city-%d" (k mod 20))) ])))) in
  let client k = thing r (-(k + 1)) in
  (* the measured clients: 0, 100 and 10,000 invoices; the others' 100,000 invoices *)
  let special = Result.get_ok (write db [ Add (-1, name, Text "zero"); Add (-2, name, Text "hundred"); Add (-3, name, Text "tenthousand") ]) in
  let c0 = thing special (-1) and c100 = thing special (-2) and c10k = thing special (-3) in
  let invoices c n tag = List.concat (List.init n (fun k -> [ Add (-(k + 1), iclient, Link (c k)); Add (-(k + 1), itotal, Money (tag + k)) ])) in
  (* 100,000 invoices of the 10,000 clients, by groups of 25,000: their ids kept for the lines below *)
  let others = ref [] in
  for b = 0 to 3 do
    let rc = Result.get_ok (write db (invoices (fun k -> client (((b * 25_000) + k) mod 10_000)) 25_000 0)) in
    others := List.rev_append (List.map snd rc.things) !others
  done;
  chunked db (invoices (fun _ -> c100) 100 1);
  chunked db (invoices (fun _ -> c10k) 10_000 2);
  (* the measured invoices, each of a client: 0, 100 and 10,000 lines; 0, 100 and 10,000 notes *)
  let inv = Result.get_ok (write db (List.concat (List.init 6 (fun k -> [ Add (-(k + 1), iclient, Link (client k)); Add (-(k + 1), itotal, Money k) ])))) in
  let i k = thing inv (-(k + 1)) in
  let lines target n = List.concat (List.init n (fun k -> [ Add (-(k + 1), linvoice, Link target); Add (-(k + 1), lprice, Money k) ])) in
  let notes target n = List.concat (List.init n (fun k -> [ Add (-(k + 1), nabout, Link target); Add (-(k + 1), ntext, Text "n") ])) in
  chunked db (lines (i 1) 100);
  chunked db (lines (i 2) 10_000);
  chunked db (notes (i 4) 100);
  chunked db (notes (i 5) 10_000);
  (* 200,000 lines over the other invoices: the index of line/invoice is not that of the measured ones alone *)
  let others = Array.of_list !others in
  for b = 0 to 7 do
    chunked db (List.concat (List.init 25_000 (fun k -> [ Add (-(k + 1), linvoice, Link others.(((b * 25_000) + k) mod Array.length others)); Add (-(k + 1), lprice, Money k) ])))
  done;
  ignore (snapshot db);
  let oc = open_out (Filename.concat dir "measured") in
  Printf.fprintf oc "%d %d %d %d %d %d %d %d %d\n" c0 c100 c10k (i 0) (i 1) (i 2) (i 3) (i 4) (i 5);
  close_out oc;
  Printf.printf "loaded in %.1f s: %d facts, links %b\n" (now () -. t0) (Store.facts (view db)) linked;
  close db

let measured dir =
  let ic = open_in (Filename.concat dir "measured") in
  let l = input_line ic in
  close_in ic;
  Array.of_list (List.map int_of_string (String.split_on_char ' ' (String.trim l)))

(* delete: *)
let delete dir runs =
  let db = Result.get_ok (open_ dir) in
  let m = measured dir in
  let v = view db in
  let cases = [ "refuse", "client", [| m.(0); m.(1); m.(2) |]; "cascade", "invoice", [| m.(3); m.(4); m.(5) |]; "clear", "invoice", [| m.(6); m.(7); m.(8) |] ] in
  List.iter
    (fun (what, kind, xs) ->
      Array.iteri
        (fun j x ->
          let n = [| 0; 100; 10_000 |].(j) in
          for _ = 1 to runs do
            let f = fork v in
            let t0 = now () in
            let r = write f [ Delete (x, kind) ] in
            let us = (now () -. t0) *. 1e6 in
            let ok = match r, what with Error (Invalid _), "refuse" when n > 0 -> true | Ok _, _ -> true | _ -> false in
            if not ok then Printf.printf "%s %d: unexpected %s\n" what n (match r with Ok _ -> "Ok" | Error e -> message e);
            Printf.printf "%s %d %.1f\n%!" what n us
          done)
        xs)
    cases;
  (* beside: the same facts as cascade 10000's lines, retracted by a group of Retract (no link followed) *)
  let p name = Option.get (property v name) in
  let lines = things v (p "line/invoice") (Link m.(5)) in
  let ops = List.concat_map (fun l -> List.map (fun (q, x) -> Retract (l, q, x)) (get v l)) lines in
  for _ = 1 to runs do
    let f = fork v in
    let t0 = now () in
    ignore (Result.get_ok (write f ops));
    Printf.printf "retract %d %.1f\n%!" (List.length lines) ((now () -. t0) *. 1e6)
  done;
  close db
(* end delete *)

let write_bench dir n mode =
  let db = Result.get_ok (open_ dir) in
  let v = view db in
  let p name = Option.get (property v name) in
  let link, total = if mode = "to" then p "invoice/client", p "invoice/total" else p "bill/client", p "bill/total" in
  let clients = Array.of_list (things v (p "client/city") (Text "city-3")) in
  let f = fork v in
  let pass = n / 5 in
  let times =
    List.init 5 (fun r ->
        let t0 = now () in
        for k = 0 to pass - 1 do
          match write f [ Add (-1, link, Link clients.(k mod Array.length clients)); Add (-1, total, Money ((r * pass) + k)) ] with
          | Ok _ -> ()
          | Error e -> failwith (message e)
        done;
        (now () -. t0) *. 1e6 /. float pass)
  in
  let a = Array.of_list times in
  Array.sort compare a;
  Printf.printf "write %s %.3f [%.3f, %.3f] us a group, %d groups a pass\n" mode a.(2) a.(0) a.(4) pass;
  close db

let () =
  match Array.to_list Sys.argv |> List.tl with
  | [ "load"; dir ] -> load dir
  | [ "delete"; dir; runs ] -> delete dir (int_of_string runs)
  | [ "write"; dir; n; mode ] -> write_bench dir (int_of_string n) mode
  | _ -> prerr_endline "dbench.exe load DIR | delete DIR RUNS | write DIR N to|plain"; exit 2
