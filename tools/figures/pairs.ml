(* The index of two properties (Cepheus.within, run format 10) of tutorial 15, drawn from a run the engine writes: the
   invoices of 2028 of tutorials 13 and 14 merged into a run with invoice/date within invoice/client, its pairs read
   back from the run's section (the Store.pr_ functions), so that every group, row and number in pair-layout.svg is the engine's. *)

open Cepheus
open Draw

let ok = function Ok r -> r | Error e -> failwith (message e)

let draw docs =
  let db = fork empty in
  let[@warning "-8"] (Ok [ cname; client; total; date ]) =
    declare db [ prop "client/name" Ttext; prop "invoice/client" Tlink; prop "invoice/total" (Tmoney 2); prop "invoice/date" Tdate ]
  in
  ok (within db [ (date, client) ]);
  let names = List.sort_uniq compare (List.map (fun (n, _, _) -> n) Windows.half) in
  let rc = ok (write db (List.mapi (fun i n -> Resolve.Add (-1 - i, cname, Text n)) names)) in
  let id n = let rec find i = function x :: _ when x = n -> i | _ :: tl -> find (i + 1) tl | [] -> assert false in Cepheus.thing rc (-1 - find 0 names) in
  ignore (ok (write db (List.concat (List.mapi (fun i (n, t, d) -> [ Resolve.Add (-1 - i, client, Link (id n)); Add (-1 - i, total, Money (t * 100)); Add (-1 - i, date, Date (d * 1000)) ]) Windows.half))));
  (* the run: the delta merged, on a simulated disk *)
  let disk = Sim_disk.disk (Sim_disk.create (Rng.make 1)) in
  disk.mkdir "/merge";
  let v0 = view db in
  let w = Snapshot.merge disk "/merge" "0123456789abcdef" v0 ~take:0 ~level:1 { Journal.segment = 1; offset = 40; next = v0.group + 1 } in
  let v = w.view in
  if not (Store.pair_ready v ~p1:client ~p2:date) then failwith "pair-layout.svg: the run holds no pair";
  let b = v.runs.(0).a in
  let k = Store.pr_find b client date in
  let groups = List.init (Store.pr_groups b k) (fun q -> Store.pr_w1 b k q, Store.pr_start b k q, Store.pr_start b k (q + 1)) in
  let name_of c = match Cepheus.values v c cname with Value.Text s :: _ -> s | _ -> "?" in
  let date_of e = match Cepheus.values v e date with d :: _ -> d | [] -> Value.missing in
  let invoices = List.sort compare (List.filter_map (fun (e, c) -> Some (e, c)) (let l = ref [] in Store.iter_prop v client (fun e c -> l := (e, c) :: !l); !l)) in
  both docs "pair-layout.svg" (fun l f ->
      let rh = 22 in
      text f ~cls:"h" 16 22 (tr l "The invoices, in the order of their ids" "Les factures, dans l'ordre de leurs ids");
      text f ~cls:"h" 400 22 (tr l "The run's pairs: invoice/date within invoice/client" "Les paires du run : invoice/date within invoice/client");
      code f 16 44 (tr l "invoice   client       date" "facture   client       date");
      List.iteri
        (fun i (e, c) ->
          let y = 54 + (i * rh) in
          rect f "row" 16 y 330 (rh - 4);
          code f 24 (y + 13) (Printf.sprintf "#%d    %-12s %s" e (name_of c) (Windows.day_of l (date_of e))))
        invoices;
      (* the groups: each its client, its first row, its rows (date, invoice) by the date; the last 3 kept *)
      let y = ref 54 in
      List.iter
        (fun (c, r0, r1) ->
          code f ~cls:"s" 400 (!y + 13) (Printf.sprintf (trf l "group %s (#%d), first row %d" "groupe %s (#%d), première ligne %d") (name_of c) c r0);
          y := !y + rh;
          for r = r0 to r1 - 1 do
            let kept = r >= r1 - 3 in
            rect f (if kept then "cur" else "row") 400 !y 300 (rh - 4);
            code f ~cls:(if kept then "" else "off") 408 (!y + 13)
              (Printf.sprintf (trf l "row %2d   %-8s  #%d" "ligne %2d %-8s  #%d") r (Windows.day_of l (Value.Date (Store.pr_w2 b k r))) (Store.pr_e b k r));
            y := !y + rh
          done;
          (* read from the group's end, up *)
          arrow f ~cls:"br" 716 (!y - 8) 716 (!y - (3 * rh) + 4);
          y := !y + 8)
        groups;
      let rows = Store.pr_rows b k in
      let yb = para f ~n:108 16 (max !y (54 + (List.length invoices * rh)) + 14)
          (Printf.sprintf
             (trf l "%d rows, sorted by (client, date, invoice), %d groups. Each with Limit: 3, the latest first, reads each group from its end, 3 rows (in blue), and asks the question with the invoice one of them; a page of one client by date seeks its cursor's date in the group, then reads its page. Read off a run the engine wrote (Snapshot.merge, run format 10)."
                "%d lignes, triées par (client, date, facture), %d groupes. Each avec Limit: 3, la plus récente d'abord, lit chaque groupe par sa fin, 3 lignes (en bleu), et pose la question avec la facture l'une d'elles ; une page d'un client par date cherche la date de son curseur dans le groupe, puis lit sa page. Lu dans un run que le moteur a écrit (Snapshot.merge, le format de run 10).")
             rows (List.length groups))
      in
      860, yb, tr l "The index of two properties of tutorial 15: the invoices by id, and their pairs by client, then date" "L'index de deux propriétés du tutoriel 15 : les factures par id, et leurs paires par client, puis par date")
