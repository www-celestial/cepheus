(* The figures of the windows (cesia.md, tutorials 13 and 14), drawn from the answers the engine gives on the rows of
   the tutorials, so that every number in them is the engine's: windows-running.svg, windows-each.svg,
   windows-rank.svg; and sort-radix.svg, the invoices of tutorial 14 sorted by the engine's whole sort by the bits of
   its keys (Top.sort_radix), checked against the comparisons' order. *)

open Cepheus
open Cepheus_server
open Draw

let ok = function Ok r -> r | Error e -> failwith (message e)

(* the invoices of 2028 of tutorials 13 and 14: client, total, date (seconds) *)
let half =
  [ "Ada Martin", 700, 1830675600; "Bo Lind", 500, 1831971600; "Cy Moreau", 300, 1833181200; "Ada Martin", 500, 1834390800;
    "Bo Lind", 900, 1835600400; "Ada Martin", 600, 1836723600; "Cy Moreau", 400, 1838793600; "Bo Lind", 500, 1840003200;
    "Ada Martin", 1100, 1841731200; "Bo Lind", 1000, 1843459200; "Cy Moreau", 500, 1845014400 ]

let money l = function
  | Value.Money m ->
    let s = thousands (m / 100) in
    nb l (if m mod 100 <> 0 then Printf.sprintf "%s.%02d" s (abs m mod 100) else s)
  | x when Value.is_missing x -> "missing"
  | x -> Value.to_string x

let months = function
  | En -> [| "January"; "February"; "March"; "April"; "May"; "June"; "July"; "August"; "September"; "October"; "November"; "December" |]
  | Fr -> [| "janvier"; "février"; "mars"; "avril"; "mai"; "juin"; "juillet"; "août"; "septembre"; "octobre"; "novembre"; "décembre" |]

let tm = function Value.Date ms -> Some (Unix.gmtime (float_of_int (ms / 1000))) | _ -> None
let month_of l d = match tm d with Some t -> (months l).(t.tm_mon) | None -> "?"

let day_of l d =
  match tm d with
  | Some t -> (match l with En -> Printf.sprintf "%s %d" (String.sub (months En).(t.tm_mon) 0 3) t.tm_mday | Fr -> Printf.sprintf "%d %s" t.tm_mday (months Fr).(t.tm_mon))
  | None -> "?"

let name = function Value.Text s -> s | _ -> "?"

let draw docs =
  let db = fork empty in
  let[@warning "-8"] (Ok [ cname; client; total; date ]) =
    declare db [ prop "client/name" Ttext; prop "invoice/client" Tlink; prop "invoice/total" (Tmoney 2); prop "invoice/date" Tdate ]
  in
  let names = List.sort_uniq compare (List.map (fun (n, _, _) -> n) half) in
  let rc = ok (write db (List.mapi (fun i n -> Resolve.Add (-1 - i, cname, Text n)) names)) in
  let id n = let rec find i = function x :: _ when x = n -> i | _ :: tl -> find (i + 1) tl | [] -> assert false in Cepheus.thing rc (-1 - find 0 names) in
  ignore (ok (write db (List.concat (List.mapi (fun i (n, t, d) -> [ Resolve.Add (-1 - i, client, Link (id n)); Add (-1 - i, total, Money (t * 100)); Add (-1 - i, date, Date (d * 1000)) ]) half))));
  let v = view db in
  let rows (a : Answer.answer) = List.init a.n (fun i -> Array.init a.cols (fun j -> Answer.value v a i j)) in
  (* 1. the months of 2028: Billed, its running total, the month before, the mean of the last 3 *)
  let q = { Query.vars = 3; where = [ { Query.e = Var 0; p = date; v = Var 1 }; { e = Var 0; p = total; v = Var 2 } ]; ranges = [] } in
  let by_month = { Question.Top.keys = [ { col = 0; desc = false } ]; limit = 0; after = None } in
  let m =
    rows
      (Answer.answer ~order:by_month ~extra:[ Question.Ask.Trunc (3, 1, "month", "UTC") ] v q
         (Wire.Over (Wire.Group ([| 3 |], [| Wire.Sum 2 |]), [||], [| Wire.Running (Sum 1, 0); Prev (1, 1); Running (Avg 1, 3) |])))
  in
  both docs "windows-running.svg" (fun l f ->
      let cur = 3 (* April, the row the figure follows *) in
      let x0 = 16 and top = 64 and rh = 28 in
      let cols = [| 16; 128; 236; 360; 470 |] in
      let ycell r = top + (r * rh) in
      code f x0 22 "Sort: [month(d)]   Give: {Month, Billed: Sum(t), SoFar: Running(Sum(Sum(t))),";
      code f x0 39 "                        Before: Prev(Sum(t)), Mean3: Running(Avg(Sum(t)), last = 3)}";
      Array.iteri (fun j h -> text f ~cls:"h" (cols.(j) + if j = 0 then 8 else 90) (top - 8) ~anchor:(if j = 0 then "start" else "end") h) [| "Month"; "Billed"; "SoFar"; "Before"; "Mean3" |];
      List.iteri
        (fun r row ->
          let y = ycell r in
          rect f (if r = cur then "cur" else "row") x0 y 560 (rh - 4);
          (* the frame of last = 3 in Billed: the current row and the 2 before *)
          if r >= cur - 2 && r <= cur then rect f "frame" (cols.(1) + 2) (y + 2) 92 (rh - 8);
          text f (x0 + 8) (y + 17) (month_of l row.(0));
          text f ~anchor:"end" (cols.(1) + 90) (y + 17) (money l row.(1));
          text f ~cls:(if r = cur then "a" else "") ~anchor:"end" (cols.(2) + 90) (y + 17) (money l row.(2));
          text f ~cls:(if Value.is_missing row.(3) then "off" else if r = cur then "a" else "") ~anchor:"end" (cols.(3) + 90) (y + 17) (money l row.(3));
          text f ~cls:(if r = cur then "a" else "") ~anchor:"end" (cols.(4) + 90) (y + 17) (money l row.(4)))
        m;
      let n = List.length m in
      let april = List.nth m cur in
      (* the running total's rows: a bracket from the first row to the current one *)
      let yb = ycell 0 + 2 and ye = ycell cur + rh - 6 in
      path f "br" (Printf.sprintf "M 590 %d h 8 V %d h -8" yb ye);
      text f ~cls:"s" 606 (((yb + ye) / 2) - 6) (tr l "SoFar: the sum of" "SoFar : la somme de");
      text f ~cls:"s" 606 (((yb + ye) / 2) + 10) (Printf.sprintf (trf l "January to April, %s" "janvier à avril, %s") (money l april.(2)));
      (* Prev: March's Billed into April's Before *)
      let ym = ycell (cur - 1) + 13 and ya = ycell cur + 13 in
      curve f (cols.(1) + 94) ym (cols.(3) + 40) ya;
      let yl = ycell n + 14 in
      text f ~cls:"s" x0 yl
        (Printf.sprintf (trf l "April's frame of last = 3 (dashed): February, March and April, mean %s. Prev(Sum(t)): March's %s." "Le frame de last = 3 d'avril (en pointillés) : février, mars et avril, moyenne %s. Prev(Sum(t)) : les %s de mars.")
           (money l april.(4)) (money l april.(3)));
      text f ~cls:"s" x0 (yl + 18)
        (tr l "January has no month before it: Before is missing; its frame is January alone, February's two months."
           "Janvier n'a pas de mois avant lui : Before est missing ; son frame est janvier seul, celui de février deux mois.");
      780, yl + 32, tr l "The months of 2028 in Sort's order, a running total, the month before and a moving mean of 3" "Les mois de 2028 dans l'ordre de Sort, un total cumulé, le mois d'avant et une moyenne mobile de 3");
  (* 2. the invoices by client, the latest first: Each and Limit 3 *)
  let qi =
    { Query.vars = 5; where = [ { Query.e = Var 0; p = date; v = Var 1 }; { e = Var 0; p = total; v = Var 2 }; { e = Var 0; p = client; v = Var 3 }; { e = Var 3; p = cname; v = Var 4 } ]; ranges = [] }
  in
  let order limit = { Question.Top.keys = [ { col = 0; desc = false }; { col = 1; desc = true } ]; limit; after = None } in
  let all = rows (Answer.answer ~order:(order 0) v qi (Wire.Give [| 4; 1; 2 |])) in
  let kept = rows (Answer.answer ~order:(order 3) v qi (Wire.Over (Wire.Give [| 4; 1; 2 |], [| 0 |], [||]))) in
  both docs "windows-each.svg" (fun l f ->
      code f 16 22 "Sort: [n, Desc(d)]   Limit: 3   Each: [n]";
      let top = 48 and rh = 26 in
      let seen = Hashtbl.create 4 in
      let y = ref top and last = ref "" in
      List.iter
        (fun row ->
          let n = name row.(0) in
          if n <> !last then begin
            if !last <> "" then (line f "cut" 16 (!y + 3) 470 (!y + 3); y := !y + 8);
            last := n
          end;
          let k = 1 + Option.value (Hashtbl.find_opt seen n) ~default:0 in
          Hashtbl.replace seen n k;
          let keep = List.exists (fun r -> Value.equal r.(0) row.(0) && Value.equal r.(1) row.(1) && Value.equal r.(2) row.(2)) kept in
          let cls = if keep then "" else "off" in
          rect f (if k = 1 then "cur" else "row") 16 !y 454 (rh - 4);
          text f ~cls 24 (!y + 16) n;
          text f ~cls 150 (!y + 16) (day_of l row.(1));
          text f ~cls ~anchor:"end" 290 (!y + 16) (money l row.(2));
          if not keep then begin
            line f "cut" 20 (!y + 11) 300 (!y + 11);
            text f ~cls:"off" 312 (!y + 16) (tr l "after the 3rd: left out" "après la 3e : laissée de côté")
          end
          else if k = 1 then text f ~cls:"a" 312 (!y + 16) (tr l "1st: Limit: 1 keeps it" "1re : Limit: 1 la garde")
          else text f ~cls:"s" 312 (!y + 16) (Printf.sprintf (trf l "%s of %s" "%s de %s") (match l, k with En, 2 -> "2nd" | En, _ -> "3rd" | Fr, 2 -> "2e" | Fr, _ -> "3e") n);
          y := !y + rh)
        all;
      text f ~cls:"s" 16 (!y + 16)
        (Printf.sprintf (trf l "%d invoices read once; %d kept: the first 3 rows of each client in Sort's order." "%d factures lues une fois ; %d gardées : les 3 premières lignes de chaque client dans l'ordre de Sort.")
           (List.length all) (List.length kept));
      (match l with En -> 520 | Fr -> 560), !y + 30,
      tr l "The invoices of 2028 by client, the latest first: Each by client and Limit 3 keep the first 3 of each" "Les factures de 2028 par client, la plus récente d'abord : Each par client et Limit 3 gardent les 3 premières de chacun");
  (* 3. the leaderboard: Rank, Rank(dense = true), Running(Count()) *)
  let qb = { Query.vars = 4; where = [ { Query.e = Var 0; p = total; v = Var 1 }; { e = Var 0; p = client; v = Var 2 }; { e = Var 2; p = cname; v = Var 3 } ]; ranges = [] } in
  let b =
    rows
      (Answer.answer ~order:{ Question.Top.keys = [ { col = 1; desc = true }; { col = 0; desc = false } ]; limit = 0; after = None } v qb
         (Wire.Over (Wire.Group ([| 3 |], [| Wire.Sum 1 |]), [||], [| Wire.Rank (1, false); Rank (1, true); Running (Count, 0) |])))
  in
  both docs "windows-rank.svg" (fun l f ->
      code f 16 22 "Sort: [Desc(Sum(t))]";
      List.iter (fun (x, h) -> text f ~cls:"h" x 50 h) [ 16, "Client"; 150, tr l "Revenue" "Chiffre"; 262, "Rank()"; 352, "Rank(dense = true)"; 506, "Running(Count())" ];
      let top = 60 and rh = 28 in
      List.iteri
        (fun r row ->
          let y = top + (r * rh) in
          rect f "row" 16 y 620 (rh - 4);
          text f 24 (y + 17) (name row.(0));
          text f ~anchor:"end" 230 (y + 17) (money l row.(1));
          text f ~cls:"a" 290 (y + 17) (Value.to_string row.(2));
          text f ~cls:"a" 410 (y + 17) (Value.to_string row.(3));
          text f ~cls:"a" 560 (y + 17) (Value.to_string row.(4)))
        b;
      let yt = top + 2 and ye = top + (2 * rh) - 6 in
      path f "br" (Printf.sprintf "M 646 %d h 8 V %d h -8" yt ye);
      text f ~cls:"s" 662 (yt + 12) (tr l "equal in Sort's key:" "égaux pour la clé de Sort :");
      text f ~cls:"s" 662 (yt + 28) (tr l "one place" "une seule place");
      let yl = top + (List.length b * rh) + 14 in
      text f ~cls:"s" 16 yl
        (tr l "Rank() skips the place the tie takes (no 2nd); Rank(dense = true) skips none; Running(Count()) numbers the rows"
           "Rank() saute la place que prend l'égalité (pas de 2e) ; Rank(dense = true) n'en saute aucune ; Running(Count()) numérote les lignes");
      text f ~cls:"s" 16 (yl + 18)
        (tr l "one by one, Ada before Bo since Sort then orders by every other field (the client's name)."
           "une à une, Ada avant Bo puisque Sort ordonne ensuite par chaque autre champ (le nom du client).");
      (match l with En -> 800 | Fr -> 840), yl + 32, tr l "A leaderboard with a tie: Rank, Rank(dense = true) and Running(Count())" "Un classement avec une égalité : Rank, Rank(dense = true) et Running(Count())")
  ;
  (* 4. a whole sort by the bits of its keys: the invoices of 2028 sorted by Top.sort_radix, Sort: [Desc(t), d]; each
     row's key and its digits of 11 bits as the engine makes them *)
  let words = Array.of_list (List.mapi (fun i (_, t, d) -> [| t * 100; d * 1000; i |]) half) in
  let n = Array.length words in
  let ord = [| { Question.Top.col = 0; desc = true }; { col = 1; desc = false } |] in
  let cmp (x : int array) (y : int array) = match compare y.(0) x.(0) with 0 -> (match compare x.(1) y.(1) with 0 -> compare x.(2) y.(2) | c -> c) | c -> c in
  let sorted = Array.copy words in
  if not (Question.Top.sort_radix [| Value.Tmoney 2; Value.Tdate; Value.Tint |] ord cmp sorted n) then failwith "sort-radix.svg: no radix sort";
  let by_cmp = Array.copy words in
  Array.stable_sort cmp by_cmp;
  if sorted <> by_cmp then failwith "sort-radix.svg: the radix sort's order is not the comparisons'";
  let col j = Array.map (fun r -> r.(j)) words in
  let lo_t = Array.fold_left min max_int (col 0) and hi_t = Array.fold_left max min_int (col 0) in
  let lo_d = Array.fold_left min max_int (col 1) and hi_d = Array.fold_left max min_int (col 1) in
  let bt = Question.Top.bits_of (hi_t - lo_t) and bd = Question.Top.bits_of (hi_d - lo_d) in
  let db = Question.Top.digit_bits in
  let key r = ((hi_t - r.(0)) lsl bd) lor (r.(1) - lo_d) in
  let passes = (bt + bd + db - 1) / db in
  let digit k d = (k lsr (d * db)) land ((1 lsl db) - 1) in
  let who r = let c, _, _ = List.nth half r.(2) in c in
  both docs "sort-radix.svg" (fun l f ->
      code f 16 22 "Sort: [Desc(t), d]";
      text f ~cls:"s" 170 22 (Printf.sprintf (trf l "the invoices of 2028, %d rows (the engine sorts this way from 4,096)" "les factures de 2028, %d lignes (le moteur trie ainsi dès 4 096)") n);
      (* the key: 10 px a bit, bit 0 on the right *)
      let bits = bt + bd in
      let x0 = 150 and px = 10 and yb = 50 in
      let xe = x0 + (bits * px) in
      text f ~cls:"h sm" 16 (yb + 17) (tr l "a row's key" "la clé d'une ligne");
      rect f ~r:2 "s1" x0 yb (bt * px) 26;
      rect f ~r:2 "s3" (x0 + (bt * px)) yb (bd * px) 26;
      text f ~cls:"w sm" (x0 + 8) (yb + 17) (Printf.sprintf (trf l "%s − t: %d bits" "%s − t : %d bits") (money l (Value.Money hi_t)) bt);
      text f ~cls:"w sm" (x0 + (bt * px) + 8) (yb + 17) (Printf.sprintf (trf l "d − %s, in ms: %d bits" "d − %s, en ms : %d bits") (day_of l (Value.Date lo_d)) bd);
      text f ~cls:"s sm" (xe + 8) (yb + 17) (Printf.sprintf (trf l "%d bits in one int" "%d bits dans un int") bits);
      for d = 0 to passes - 1 do
        let xr = xe - (d * db * px) and xl = max x0 (xe - ((d + 1) * db * px)) in
        line f "axis" xr (yb + 30) xr (yb + 40);
        if d = passes - 1 then line f "axis" xl (yb + 30) xl (yb + 40);
        text f ~cls:"s sm" ~anchor:"middle" ((xl + xr) / 2) (yb + 46) (Printf.sprintf (trf l "digit %d" "chiffre %d") d);
        text f ~cls:"a sm" ~anchor:"middle" ((xl + xr) / 2) (yb + 62) (Printf.sprintf (trf l "pass %d" "passe %d") (d + 1))
      done;
      (* the rows as read, their keys' digits; the rows sorted *)
      let top = 152 and rh = 22 in
      let dx d = 300 + ((passes - 1 - d) * 46) in
      text f ~cls:"h sm" 16 (top - 8) (tr l "as read" "dans l'ordre lu");
      for d = passes - 1 downto 0 do
        text f ~cls:"s sm" ~anchor:"end" (dx d + 36) (top - 24) (tr l "digit" "chiffre");
        text f ~cls:"h sm" ~anchor:"end" (dx d + 36) (top - 8) (string_of_int d)
      done;
      text f ~cls:"h sm" 586 (top - 8) (tr l "sorted" "triées");
      Array.iteri
        (fun i r ->
          let y = top + (i * rh) in
          rect f (if r.(0) = 50000 then "frame" else "row") 16 y 512 (rh - 3);
          text f ~cls:"sm" 22 (y + 14) (who r);
          text f ~cls:"sm" ~anchor:"end" 168 (y + 14) (money l (Value.Money r.(0)));
          text f ~cls:"s sm" 180 (y + 14) (day_of l (Value.Date r.(1)));
          let k = key r in
          for d = passes - 1 downto 0 do text f ~cls:(if d = 0 then "a sm" else "sm") ~anchor:"end" (dx d + 36) (y + 14) (nb l (thousands (digit k d))) done)
        words;
      Array.iteri
        (fun i r ->
          let y = top + (i * rh) in
          rect f (if r.(0) = 50000 then "frame" else "row") 580 y 250 (rh - 3);
          text f ~cls:"a sm" 588 (y + 14) (string_of_int (i + 1));
          text f ~cls:"sm" 610 (y + 14) (who r);
          text f ~cls:"sm" ~anchor:"end" 750 (y + 14) (money l (Value.Money r.(0)));
          text f ~cls:"s sm" 760 (y + 14) (day_of l (Value.Date r.(1))))
        sorted;
      let ym = top + (n * rh / 2) in
      arrow f ~cls:"br" 534 ym 574 ym;
      let ties = List.length (List.filter (fun (_, t, _) -> t = 500) half) in
      let yl = top + (n * rh) + 18 in
      let yl =
        para f ~n:118 16 yl
          (Printf.sprintf
             (trf l "%d passes, each a count of the %d keys' digit and %d moves, stable, no comparison: digit 0 first (blue), digit %d last. The %d invoices of %s (dashed) share their high bits; their dates, in the low bits, order them. The comparisons' sort gives the same order, row for row."
                "%d passes, chacune un compte du chiffre des %d clés et %d déplacements, stable, sans comparaison : le chiffre 0 d'abord (en bleu), le chiffre %d en dernier. Les %d factures de %s (en pointillés) partagent leurs bits hauts ; leurs dates, dans les bits bas, les ordonnent. Le tri par comparaisons donne le même ordre, ligne pour ligne.")
             passes n n (passes - 1) ties (money l (Value.Money 50000)))
      in
      860, yl + 10,
      tr l "A whole sort by the bits of its keys: each row's key, the largest total first then the date, and its digits of 11 bits, sorted by a radix sort"
        "Un tri entier par les bits de ses clés : la clé de chaque ligne, le plus grand total d'abord puis la date, et ses chiffres de 11 bits, triés par un radix sort")
