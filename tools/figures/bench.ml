(* The measures beside PostgreSQL and SQLite, drawn from the tables of the book itself (docs/book/benchmarks.md and
   docs/book/server.md), so that a figure says what its table says: bench-windows.svg, bench-pages.svg,
   bench-server.svg, bench-backup.svg, bench-pg-won.svg, bench-rows.svg. A table that no longer has the rows a figure
   names stops the program. *)

open Draw

let lines path = In_channel.with_open_bin path In_channel.input_all |> String.split_on_char '\n'

(* the rows of the first table after the heading that starts with [heading]: each row's cells *)
let table path heading =
  let rec seek = function [] -> failwith ("no section " ^ heading ^ " in " ^ path) | l :: t -> if String.starts_with ~prefix:heading l then t else seek t in
  let rec first = function [] -> [] | l :: t -> if String.starts_with ~prefix:"|" l then l :: t else first t in
  let rec take = function l :: t when String.starts_with ~prefix:"|" l -> l :: take t | _ -> [] in
  let rows = take (first (seek (lines path))) in
  let cells l = let c = String.split_on_char '|' l in List.map String.trim (List.filteri (fun i _ -> i > 0 && i < List.length c - 1) c) in
  match rows with _ :: _ :: body -> List.map cells body | _ -> failwith ("no table under " ^ heading)

(* a measure in a cell: the bold one when there are several, else the first; its value (seconds, or MB) and as written *)
let measure cell =
  let re = Str.regexp "\\(\\*\\*\\)?\\([0-9][0-9,]*\\(\\.[0-9]+\\)?\\) \\(\xc2\xb5s\\|ms\\|s\\|MB\\)" in
  let rec all from acc =
    match Str.search_forward re cell from with
    | exception Not_found -> List.rev acc
    | at ->
      let bold = (try ignore (Str.matched_group 1 cell); true with Not_found -> false) in
      let num = Str.matched_group 2 cell and unit = Str.matched_group 4 cell in
      let v = float_of_string (String.concat "" (String.split_on_char ',' num)) in
      let scale = match unit with "ms" -> 1e-3 | "s" | "MB" -> 1. | _ -> 1e-6 in
      all (at + 1) ((bold, v *. scale, num ^ " " ^ unit) :: acc)
  in
  match all 0 [] with [] -> None | ms -> (match List.find_opt (fun (b, _, _) -> b) ms with Some (_, v, s) -> Some (v, s) | None -> let _, v, s = List.hd ms in Some (v, s))

let get cell = match measure cell with Some m -> m | None -> failwith ("no measure in " ^ cell)

(* the ratio a table writes, PostgreSQL's time over Cepheus's ("1.73×", "Cepheus, 3.2 times", "PostgreSQL, 1.2 times"),
   as written; or the medians' ratio when it writes none *)
let ratio cell c p =
  let re = Str.regexp "\\([0-9]+\\(\\.[0-9]+\\)?\\)\\(\xc3\x97\\| times\\)" in
  match Str.search_forward re cell 0 with
  | _ ->
    let s = Str.matched_group 1 cell in
    let v = float_of_string s in
    if String.starts_with ~prefix:"PostgreSQL" cell then 1. /. v, s else v, s
  | exception Not_found -> let r = p /. c in r, Printf.sprintf "%.1f" (if r >= 1. then r else 1. /. r)

(* a chart of ratios: each row, PostgreSQL's time over Cepheus's on a log scale, Cepheus faster to the right *)
let ratios l f ~top rows =
  let cx = 486 and k = 180. in
  let x r = cx + int_of_float (k *. log10 r) in
  text f ~cls:"s sm" 350 (top - 30) ~anchor:"end" (tr l "Cepheus · PostgreSQL" "Cepheus · PostgreSQL");
  text f ~cls:"a sm" (cx + 8) (top - 30) (tr l "Cepheus faster →" "Cepheus plus rapide →");
  text f ~cls:"sm" (cx - 8) (top - 30) ~anchor:"end" (tr l "← PostgreSQL faster" "← PostgreSQL plus rapide");
  let rh = 22 in
  let bottom = top + (List.length rows * rh) in
  List.iter
    (fun r -> let xr = x r in if xr > 360 && xr < 700 then (line f "grid" xr (top - 16) xr bottom; text f ~cls:"s sm" ~anchor:"middle" xr (top - 6) (nb l (if r < 1. then Printf.sprintf "%g×" (1. /. r) else Printf.sprintf "%g×" r))))
    [ 0.5; 1.; 2.; 4.; 8. ];
  line f "axis" cx (top - 16) cx bottom;
  List.iteri
    (fun i (label, (_, cs), (_, ps), (r, rs)) ->
      let y = top + (i * rh) in
      text f ~cls:"sm" 16 (y + 15) label;
      text f ~cls:"s sm" 350 (y + 15) ~anchor:"end" (nb l cs ^ " · " ^ nb l ps);
      let xr = x r in
      let cls = if r >= 1.1 then "s1" else if r <= 1. /. 1.1 then "s2" else "off" in
      rect f ~r:2 cls (min cx xr) (y + 5) (max 2 (abs (xr - cx))) 13;
      let t = nb l (rs ^ "×") in
      if r >= 1. then text f ~cls:"sm h" (xr + 5) (y + 16) t else text f ~cls:"sm h" (xr - 5) (y + 16) ~anchor:"end" t)
    rows;
  bottom

(* 1. the windows and Each beside PostgreSQL *)
let windows docs =
  let rows = table (Filename.concat docs "book/benchmarks.md") "## Windows and Each" in
  let labels =
    [ "Running(Sum(t)), 1", "1"; "Running(Sum(t)), 100", "100"; "Running(Sum(t)), 10,000", "10 000";
      "Running(Avg(t), last = 3), 1", "1"; "Running(Avg(t), last = 3), 100", "100"; "Running(Avg(t), last = 3), 10,000", "10 000";
      "Rank(), 1", "1"; "Rank(), 100", "100"; "Rank(), 10,000", "10 000";
      "Prev(d), 1", "1"; "Prev(d), 100", "100"; "Prev(d), 10,000", "10 000";
      "Each, Limit: 3 (LATERAL)", ""; "Limit: 1 (DISTINCT ON)", ""; "report of 121 months", ""; "page after the 200,000th", ""; "first page of 51", "" ]
  in
  if List.length rows <> List.length labels then failwith "benchmarks.md, Windows and Each: the table's rows changed";
  both docs "bench-windows.svg" (fun l f ->
      let fr = [ ""; ""; ""; ""; ""; ""; ""; ""; ""; ""; ""; ""; "Each, Limit: 3 (LATERAL)"; "Limit: 1 (DISTINCT ON)"; "rapport de 121 mois"; "page après la 200 000e"; "première page de 51" ] in
      let label i (en, n) =
        match l with
        | En -> if n = "" then en else en ^ (if n = "1" then " group" else " groups")
        | Fr -> if n = "" then List.nth fr i else (String.sub en 0 (String.rindex en ',')) ^ ", " ^ n ^ (if n = "1" then " groupe" else " groupes")
      in
      text f ~cls:"h" 16 22 (tr l "Windows and Each at 1 million facts, the median of 5 rounds" "Windows et Each à 1 million de faits, la médiane de 5 tours");
      let data =
        List.mapi
          (fun i r -> let c = get (List.nth r 1) and p = get (List.nth r 2) in label i (List.nth labels i), c, p, ratio (List.nth r 3) (fst c) (fst p))
          rows
      in
      let bottom = ratios l f ~top:76 data in
      let y = para f ~n:104 16 (bottom + 24)
          (tr l "PostgreSQL 18.6 with the indexes its user makes for these questions; its LATERAL reads 3 rows a client from one, Cepheus the 245,000 invoices once. Times: docs/book/benchmarks.md."
             "PostgreSQL 18.6 avec les index que son utilisateur crée pour ces questions ; son LATERAL lit 3 lignes par client dans l'un d'eux, Cepheus les 245 000 factures une fois. Temps : docs/book/benchmarks.md.") in
      712, y, tr l "Windows and Each beside PostgreSQL: how many times faster each side is, question by question" "Windows et Each à côté de PostgreSQL : combien de fois chaque côté est plus rapide, question par question")

(* 2. a page of 51 by id, after the middle, as the kind grows: the heap before, Cepheus now, PostgreSQL *)
let pages docs =
  let rows = table (Filename.concat docs "book/benchmarks.md") "## Pages of a kind by its things' ids" in
  let pick = List.filter (fun r -> List.nth r 1 = "by id, after the middle") rows in
  if List.length pick <> 3 then failwith "benchmarks.md, Pages of a kind: no 3 rows by id, after the middle";
  let pts col = List.map (fun r -> get (List.nth r col)) pick in
  let old = pts 2 and now = pts 3 and pg = pts 5 in
  let sizes = [ "10,000"; "100,000"; "1,000,000" ] in
  both docs "bench-pages.svg" (fun l f ->
      text f ~cls:"h" 16 22 (tr l "A page of 51 by id, after the middle of the kind, one run" "Une page de 51 par id, après le milieu du kind, un run");
      let x0 = 90 and xs = [| 110; 300; 490 |] and top = 50 and dec = 52 in
      (* 10 µs near the bottom, 100 ms at the top: 4 decades, and room under 10 µs for the labels *)
      let y v = top + int_of_float (float_of_int dec *. (-1. -. log10 v)) in
      let bottom = y 4e-6 in
      List.iter
        (fun (v, s) -> let yy = y v in line f "grid" x0 yy 520 yy; text f ~cls:"s sm" (x0 - 6) (yy + 4) ~anchor:"end" s)
        [ 1e-1, "100 ms"; 1e-2, "10 ms"; 1e-3, "1 ms"; 1e-4, "100 µs"; 1e-5, "10 µs" ];
      Array.iteri (fun i x -> line f "axis" x bottom x (bottom + 4); text f ~cls:"s sm" ~anchor:"middle" x (bottom + 18) (nb l (List.nth sizes i))) xs;
      text f ~cls:"s sm" ((xs.(0) + xs.(2)) / 2) (bottom + 36) ~anchor:"middle" (tr l "things of the kind" "choses du kind");
      let series ?(below = false) cls dot pts name =
        let p = List.mapi (fun i (v, _) -> xs.(i), y v) pts in
        path f cls (String.concat " " (List.mapi (fun i (a, b) -> Printf.sprintf "%s %d %d" (if i = 0 then "M" else "L") a b) p));
        List.iter (fun (a, b) -> circle f "bg" a b 6; circle f dot a b 4) p;
        List.iteri (fun i (_, s) -> let a, b = List.nth p i in text f ~cls:"s sm" a (if below then b + 20 else b - 10) ~anchor:"middle" (nb l s)) pts;
        let a, b = List.nth p 2 in
        text f ~cls:"h sm" (a + 14) (if below then b + 10 else b) name
      in
      series "ks" "off" old (tr l "the heap (before)" "le tas (avant)");
      series "k2" "s2" pg "PostgreSQL 18.6";
      series ~below:true "k1" "s1" now "Cepheus";
      let yb = para f ~n:104 16 (bottom + 60)
          (tr l "Cepheus reads the property's column from the cursor, in the order of the ids, and its page costs the same at every size; PostgreSQL reads its primary key's B-tree from the cursor. Times: docs/book/benchmarks.md."
             "Cepheus lit la colonne de la propriété depuis le curseur, dans l'ordre des ids, et sa page coûte autant à chaque taille ; PostgreSQL lit le B-tree de sa clé primaire depuis le curseur. Temps : docs/book/benchmarks.md.") in
      712, yb, tr l "The time of a page of 51 by id as a kind grows from 10,000 to 1,000,000 things: Cepheus, PostgreSQL, and the heap of before"
        "Le temps d'une page de 51 par id quand un kind grandit de 10 000 à 1 000 000 de choses : Cepheus, PostgreSQL, et le tas d'avant")

(* 3. the server beside PostgreSQL's: reads one at a time, in flight, by many clients; two questions; a connection *)
let server docs =
  let rows = table (Filename.concat docs "book/server.md") "## Speed beside PostgreSQL" in
  let want =
    [ "empty round trip", "empty round trip, Unix socket", "aller-retour vide, socket Unix";
      "point read, 1 client, Unix socket", "a point read, Unix socket", "une lecture ponctuelle, socket Unix";
      "point read, 1 client, TCP + TLS", "a point read, TCP + TLS 1.3", "une lecture ponctuelle, TCP + TLS 1.3";
      "point reads, 16 in flight", "16 reads in flight, a read", "16 lectures en vol, par lecture";
      "8 clients", "8 clients, a read", "8 clients, par lecture";
      "64 clients", "64 clients, a read", "64 clients, par lecture";
      "256 clients", "256 clients, a read", "256 clients, par lecture";
      "Q3", "Q3: the unpaid of a city", "Q3 : les impayées d'une ville";
      "Q4", "Q4: unpaid sum by city", "Q4 : somme impayée par ville";
      "a new connection with TLS", "a new TLS connection", "une nouvelle connexion TLS" ]
  in
  let data l =
    List.map
      (fun (prefix, en, fr) ->
        match List.find_opt (fun r -> String.starts_with ~prefix (List.hd r)) rows with
        | Some r -> let c = get (List.nth r 1) and p = get (List.nth r 2) in tr l en fr, c, p, ratio (List.nth r 3) (fst c) (fst p)
        | None -> failwith ("server.md, Speed beside PostgreSQL: no row " ^ prefix))
      want
  in
  both docs "bench-server.svg" (fun l f ->
      text f ~cls:"h" 16 22 (tr l "The server beside PostgreSQL 18.6's, the median of the rounds" "Le serveur à côté de celui de PostgreSQL 18.6, la médiane des tours");
      let bottom = ratios l f ~top:76 (data l) in
      let y = para f ~n:104 16 (bottom + 24)
          (tr l "The same rows on both sides (1 M facts), 4 I/O domains against a process a connection; pgbench -M prepared. Times: docs/book/server.md."
             "Les mêmes lignes des deux côtés (1 M de faits), 4 I/O domains contre un processus par connexion ; pgbench -M prepared. Temps : docs/book/server.md.") in
      712, y, tr l "The server beside PostgreSQL: how many times faster each side is, measure by measure" "Le serveur à côté de PostgreSQL : combien de fois chaque côté est plus rapide, mesure par mesure")

(* 4. backup and restore beside pg_basebackup and SQLite's .backup: each row on its own scale *)
let backup docs =
  let rows = table (Filename.concat docs "book/benchmarks.md") "## Backup and restore" in
  let want =
    [ "the database", "the database's size", "la taille de la base";
      "a backup, while it serves", "a backup, while it serves", "une sauvegarde, en service";
      "the backup checked", "the backup checked", "la sauvegarde vérifiée";
      "a restore to the end", "a restore to the end", "une restauration jusqu'au bout";
      "the whole history replayed", "the whole history replayed", "tout l'historique rejoué" ]
  in
  both docs "bench-backup.svg" (fun l f ->
      text f ~cls:"h" 16 22 (tr l "Backup and restore at 10 M facts, the median of 21 rounds" "Sauvegarde et restauration à 10 M de faits, la médiane de 21 tours");
      let names = [ "Cepheus", "s1"; "PostgreSQL 18.6", "s2"; "SQLite 3.54", "s3" ] in
      List.iteri (fun i (n, c) -> let x = 16 + (i * 150) in rect f ~r:2 c x 36 12 12; text f ~cls:"sm" (x + 18) 46 n) names;
      let x0 = 250 and w = 330 and top = 70 in
      let y = ref top in
      List.iter
        (fun (prefix, en, fr) ->
          let r = match List.find_opt (fun r -> String.starts_with ~prefix (List.hd r)) rows with Some r -> r | None -> failwith ("benchmarks.md, Backup and restore: no row " ^ prefix) in
          let vals = List.map (fun i -> measure (List.nth r i)) [ 1; 2; 3 ] in
          let best = List.fold_left (fun m -> function Some (v, _) -> min m v | None -> m) infinity vals in
          let most = List.fold_left (fun m -> function Some (v, _) -> max m v | None -> m) 0. vals in
          text f ~cls:"sm" 16 (!y + 26) (tr l en fr);
          List.iteri
            (fun i v ->
              let yy = !y + 6 + (i * 16) in
              match v with
              | Some (v, s) ->
                let bw = max 2 (int_of_float (float_of_int w *. v /. most)) in
                rect f ~r:2 (snd (List.nth names i)) x0 yy bw 13;
                text f ~cls:(if v = best then "sm h" else "s sm") (x0 + bw + 6) (yy + 11) (nb l s)
              | None -> text f ~cls:"off sm" (x0 + 4) (yy + 11) (tr l "none: no history" "aucun : pas d'historique"))
            vals;
          y := !y + 62)
        want;
      let yb = para f ~n:104 16 (!y + 10)
          (tr l "Each row on its own scale, its shortest in bold. The whole history replayed is the same work on both sides; SQLite keeps no history. Times: docs/book/benchmarks.md."
             "Chaque ligne à sa propre échelle, la plus courte en gras. Tout l'historique rejoué est le même travail des deux côtés ; SQLite ne garde pas d'historique. Temps : docs/book/benchmarks.md.") in
      712, yb, tr l "Backup and restore beside PostgreSQL and SQLite: sizes and times at 10 million facts" "Sauvegarde et restauration à côté de PostgreSQL et SQLite : tailles et temps à 10 millions de faits")

(* each question's ratio with main's binaries (a grey dot) and now (a coloured one), on a log scale of PostgreSQL's time
   over Cepheus's: the rows of the first table under [heading], [want] naming each (a text its first cell holds) and
   its label in English and French; the cells of main, now and PostgreSQL at [cols]; [cx] the x of a ratio of 1, [k]
   the width of a factor of 10, [right] the x of the ratios' column, [width] the figure's *)
let dumbbell ?(cx = 598) ?(k = 219.) ?(right = 742) ?(width = 860) docs ~file ~heading ~want ~cols:(cm, cn, cp) ~ticks ~title ~note ~alt =
  let rows = table (Filename.concat docs "book/benchmarks.md") heading in
  let where = "benchmarks.md, " ^ String.sub heading 3 (String.length heading - 3) in
  if List.length rows <> List.length want then failwith (where ^ ": the table's rows changed");
  let contains s sub = let n = String.length sub in let rec go i = i + n <= String.length s && (String.sub s i n = sub || go (i + 1)) in go 0 in
  let data l =
    List.map2
      (fun r (key, en, fr) ->
        if not (contains (List.hd r) key) then failwith (where ^ ": no row " ^ key);
        tr l en fr, get (List.nth r cm), get (List.nth r cn), get (List.nth r cp))
      rows want
  in
  both docs file (fun l f ->
      text f ~cls:"h" 16 22 (title l);
      let top = 84 and rh = 24 in
      let x r = cx + int_of_float (k *. log10 r) in
      let rs = data l in
      let bottom = top + (List.length rs * rh) in
      text f ~cls:"s sm" 380 (top - 30) ~anchor:"end" (tr l "main → now · PostgreSQL" "main → maintenant · PostgreSQL");
      text f ~cls:"a sm" (cx + 8) (top - 30) (tr l "Cepheus faster →" "Cepheus plus rapide →");
      text f ~cls:"sm" (cx - 8) (top - 30) ~anchor:"end" (tr l "← PostgreSQL faster" "← PostgreSQL plus rapide");
      text f ~cls:"s sm" right (top - 30) (tr l "main → now" "main → maintenant");
      List.iter
        (fun r ->
          let xr = x r in
          line f "grid" xr (top - 16) xr bottom;
          text f ~cls:"s sm" ~anchor:"middle" xr (top - 6) (nb l (if r < 1. then Printf.sprintf "%g×" (1. /. r) else Printf.sprintf "%g×" r)))
        ticks;
      line f "axis" cx (top - 16) cx bottom;
      let side r = if r >= 1.1 then "a" else if r <= 1. /. 1.1 then "s2" else "s" in
      let times r = Printf.sprintf "%.1f×" (if r >= 1. then r else 1. /. r) in
      List.iteri
        (fun i (label, (cm, sm), (cn, sn), (p, sp)) ->
          let y = top + (i * rh) in
          let yc = y + 11 in
          let sub = String.starts_with ~prefix:" " label in
          text f ~cls:(if sub then "s sm" else "sm") (if sub then 30 else 16) (y + 15) (String.trim label);
          let num s = match String.index_opt s ' ' with Some i -> String.sub s 0 i | None -> s in
          let unit s = match String.index_opt s ' ' with Some i -> String.sub s (i + 1) (String.length s - i - 1) | None -> "" in
          let before = if unit sm = unit sn then num sm else sm in
          text f ~cls:"s sm" 380 (y + 15) ~anchor:"end" (nb l (before ^ " → " ^ sn ^ " · " ^ sp));
          let rm = p /. cm and rn = p /. cn in
          let xm = x rm and xn = x rn in
          if abs (xn - xm) > 16 then arrow f ~cls:"gr" xm yc (if xn > xm then xn - 7 else xn + 7) yc else line f "gr" xm yc xn yc;
          circle f "bg" xm yc 6;
          circle f "off" xm yc 4;
          circle f "bg" xn yc 7;
          circle f (match side rn with "a" -> "s1" | "s2" -> "s2" | _ -> "off") xn yc 5;
          spans f ~cls:"sm" right (y + 15) [ side rm, nb l (times rm); "s", " → "; side rn ^ " h", nb l (times rn) ])
        rs;
      let y = para f ~n:120 16 (bottom + 24) (note l) in
      width, y, alt l)

(* 5. the cases PostgreSQL still won *)
let pg_won docs =
  dumbbell docs ~file:"bench-pg-won.svg" ~heading:"## The cases PostgreSQL still won" ~cols:(1, 2, 4) ~ticks:[ 0.125; 0.25; 0.5; 1.; 2.; 4. ]
    ~want:
      [ "Less(a, b)", "Less(a, b), every value", "Less(a, b), chaque valeur";
        "the same as the server", "   as the server answers", "   comme le serveur répond";
        "below one invoice's total", "Less, a range, every value", "Less, un intervalle, chaque valeur";
        "the same as the server", "   as the server answers", "   comme le serveur répond";
        "(`Optional`)", "Optional, every value", "Optional, chaque valeur";
        "the same as the server", "   as the server answers", "   comme le serveur répond";
        "`Rank()`, 1 group", "Rank(), 1 group", "Rank(), 1 groupe";
        "the same, 100 groups", "Rank(), 100 groups", "Rank(), 100 groupes";
        "the same, 10,000 groups", "Rank(), 10,000 groups", "Rank(), 10 000 groupes";
        "the 3 latest", "Each, Limit: 3 (LATERAL)", "Each, Limit: 3 (LATERAL)";
        "the last invoice", "Limit: 1 (DISTINCT ON)", "Limit: 1 (DISTINCT ON)";
        "an invoice and its 10,000 lines", "cascade, 10,000 lines", "cascade, 10 000 lignes";
        "an invoice and its 100 lines", "cascade, 100 lines", "cascade, 100 lignes" ]
    ~title:(fun l -> tr l "The cases PostgreSQL still won, at 1 million facts: main, then now" "Les cas que PostgreSQL gagnait encore, à 1 million de faits : main, puis maintenant")
    ~note:(fun l ->
      tr l "The grey dot is main's binaries (af9fb51), the coloured one now (d96aa73), on a log scale of PostgreSQL 18.6's time over Cepheus's: the median of 5 rounds alternated on the same rows. A ratio in blue, Cepheus is faster; in orange, PostgreSQL; in grey, within 10 %. \"As the server answers\" makes each row's index words, not its values. Times: docs/book/benchmarks.md."
        "Le point gris : les binaires de main (af9fb51) ; le point en couleur : maintenant (d96aa73) ; sur une échelle logarithmique du temps de PostgreSQL 18.6 sur celui de Cepheus : la médiane de 5 tours alternés sur les mêmes lignes. Un rapport en bleu, Cepheus est plus rapide ; en orange, PostgreSQL ; en gris, à 10 % près. « Comme le serveur répond » fait les mots d'index de chaque ligne, pas ses valeurs. Temps : docs/book/benchmarks.md.")
    ~alt:(fun l -> tr l "The cases PostgreSQL still won: how many times faster each side was with main and is now, question by question" "Les cas que PostgreSQL gagnait encore : combien de fois chaque côté était plus rapide avec main et l'est maintenant, question par question")

(* 6. rows with every value made, and cascades: each question in the two scopes beside PostgreSQL *)
let rows docs =
  dumbbell ~cx:570 ~k:150. ~right:782 ~width:900 docs ~file:"bench-rows.svg" ~heading:"## Rows with every value made, and cascades"
    ~cols:(1, 2, 4) ~ticks:[ 0.25; 0.5; 1.; 2.; 4.; 8.; 16. ]
    ~want:
      [ "newer client", "Less(a, b), every value", "Less(a, b), chaque valeur";
        "the engine alone", "   the engine alone", "   le moteur seul";
        "below one invoice's total", "Less, a range, every value", "Less, un intervalle, chaque valeur";
        "the engine alone", "   the engine alone", "   le moteur seul";
        "(`Optional`)", "Optional, every value", "Optional, chaque valeur";
        "the engine alone", "   the engine alone", "   le moteur seul";
        "10,000 lines", "cascade, 10,000 lines", "cascade, 10 000 lignes";
        "100 lines", "cascade, 100 lines", "cascade, 100 lignes";
        "10,000 notes", "clear, 10,000 notes", "clear, 10 000 notes" ]
    ~title:(fun l -> tr l "Rows with every value made, and cascades, at 1 million facts: main, then now" "Les lignes avec chaque valeur faite, et les cascades, à 1 million de faits : main, puis maintenant")
    ~note:(fun l ->
      tr l "The grey dot is main's binaries (ec4bb86), the coloured one now, on a log scale of PostgreSQL 18.6's time over Cepheus's: the median of the rounds alternated on the same rows, Cepheus on 8 domains, PostgreSQL in one process. Every value: Cepheus.ask beside a program that receives PostgreSQL's rows through libpq; the engine alone: Cepheus's index words as its server answers, beside PostgreSQL's EXPLAIN ANALYZE; the cascades on a fork thrown away, PostgreSQL's rolled back. A ratio in blue, Cepheus is faster; in orange, PostgreSQL; in grey, within 10 %. Times: docs/book/benchmarks.md."
        "Le point gris : les binaires de main (ec4bb86) ; le point en couleur : maintenant ; sur une échelle logarithmique du temps de PostgreSQL 18.6 sur celui de Cepheus : la médiane des tours alternés sur les mêmes lignes, Cepheus sur 8 domains, PostgreSQL dans un seul process. Chaque valeur : Cepheus.ask à côté d'un programme qui reçoit les lignes de PostgreSQL par libpq ; le moteur seul : les mots d'index de Cepheus comme son serveur répond, à côté de l'EXPLAIN ANALYZE de PostgreSQL ; les cascades sur un fork jeté, celles de PostgreSQL annulées. Un rapport en bleu, Cepheus est plus rapide ; en orange, PostgreSQL ; en gris, à 10 % près. Temps : docs/book/benchmarks.md.")
    ~alt:(fun l -> tr l "Rows with every value made, and cascades: how many times faster each side was with main and is now, in each scope" "Les lignes avec chaque valeur faite, et les cascades : combien de fois chaque côté était plus rapide avec main et l'est maintenant, dans chaque périmètre")

let draw docs =
  windows docs;
  pages docs;
  server docs;
  backup docs;
  pg_won docs;
  rows docs
