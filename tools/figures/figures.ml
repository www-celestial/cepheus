(* The figures of the book's windows (docs/book/images/windows-*.svg), drawn from the answers the engine gives on
   the rows of tutorials 13 and 14, so that every number in them is the engine's:

     dune exec tools/figures/figures.exe -- docs/book/images

   Each is a small SVG of its own: a white card (readable on a light page and on a dark one), the text in the system's
   font, the rows a window reads in Sort's order. *)

open Cepheus
open Cepheus_server

let ok = function Ok r -> r | Error e -> failwith (message e)

(* the invoices of 2028 of tutorials 13 and 14: client, total, date (seconds) *)
let half =
  [ "Ada Martin", 700, 1830675600; "Bo Lind", 500, 1831971600; "Cy Moreau", 300, 1833181200; "Ada Martin", 500, 1834390800;
    "Bo Lind", 900, 1835600400; "Ada Martin", 600, 1836723600; "Cy Moreau", 400, 1838793600; "Bo Lind", 500, 1840003200;
    "Ada Martin", 1100, 1841731200; "Bo Lind", 1000, 1843459200; "Cy Moreau", 500, 1845014400 ]

let money = function
  | Value.Money m ->
    let units = m / 100 and cents = abs m mod 100 in
    let s = string_of_int (abs units) in
    let n = String.length s in
    let b = Buffer.create 16 in
    if m < 0 then Buffer.add_char b '-';
    String.iteri (fun i c -> if i > 0 && (n - i) mod 3 = 0 then Buffer.add_char b ','; Buffer.add_char b c) s;
    if cents <> 0 then Buffer.add_string b (Printf.sprintf ".%02d" cents);
    Buffer.contents b
  | x when Value.is_missing x -> "missing"
  | x -> Value.to_string x

let months = [| "January"; "February"; "March"; "April"; "May"; "June"; "July"; "August"; "September"; "October"; "November"; "December" |]

let month_of = function
  | Value.Date ms -> let t = Unix.gmtime (float_of_int (ms / 1000)) in months.(t.tm_mon)
  | _ -> "?"

let day_of = function
  | Value.Date ms -> let t = Unix.gmtime (float_of_int (ms / 1000)) in Printf.sprintf "%s %d" (String.sub months.(t.tm_mon) 0 3) t.tm_mday
  | _ -> "?"

let style =
  {|<style>
text{font-family:system-ui, sans-serif;font-size:13px;fill:#1f2328}
.c{font-family:ui-monospace, Menlo, Consolas, monospace;font-size:12.5px}
.h{font-weight:600}
.s{fill:#57606a}
.a{fill:#3a5ad9}
.off{fill:#8c959f}
.row{fill:#fff;stroke:#d0d7de;stroke-width:1}
.cur{fill:#eef1fc;stroke:#3a5ad9;stroke-width:1.6}
.frame{fill:#eef1fc;stroke:#3a5ad9;stroke-width:1.2;stroke-dasharray:4 3}
.br{stroke:#3a5ad9;stroke-width:1.4;fill:none}
.gr{stroke:#57606a;stroke-width:1.2;fill:none}
.cut{stroke:#8c959f;stroke-width:1}
</style>|}

let svg path w h title body =
  let oc = open_out path in
  Printf.fprintf oc "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\">\n<title>%s</title>\n%s\n" w h w h title style;
  Printf.fprintf oc "<rect width=\"%d\" height=\"%d\" fill=\"#fff\"/>\n" w h;
  List.iter (fun l -> output_string oc l; output_char oc '\n') body;
  output_string oc "</svg>\n";
  close_out oc

let text ?(cls = "") ?(anchor = "start") x y s =
  Printf.sprintf "<text%s x=\"%d\" y=\"%d\"%s>%s</text>" (if cls = "" then "" else Printf.sprintf " class=\"%s\"" cls) x y
    (if anchor = "start" then "" else Printf.sprintf " text-anchor=\"%s\"" anchor) s

let rect cls x y w h = Printf.sprintf "<rect class=\"%s\" x=\"%d\" y=\"%d\" width=\"%d\" height=\"%d\"/>" cls x y w h
let path cls d = Printf.sprintf "<path class=\"%s\" d=\"%s\"/>" cls d

let () =
  let dir = if Array.length Sys.argv > 1 then Sys.argv.(1) else "docs/book/images" in
  let db = fork empty in
  let[@warning "-8"] (Ok [ name; client; total; date ]) =
    declare db [ prop "client/name" Ttext; prop "invoice/client" Tlink; prop "invoice/total" (Tmoney 2); prop "invoice/date" Tdate ]
  in
  let names = List.sort_uniq compare (List.map (fun (n, _, _) -> n) half) in
  let rc = ok (write db (List.mapi (fun i n -> Resolve.Add (-1 - i, name, Text n)) names)) in
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
  let cur = 3 (* April, the row the figure follows *) in
  let x0 = 16 and top = 64 and rh = 28 in
  let cols = [| 16; 128; 236; 360; 470 |] in
  let ycell r = top + (r * rh) in
  let body = ref [] in
  let add l = body := !body @ l in
  add [ text ~cls:"c" x0 22 "Sort: [month(d)]   Give: {Month, Billed: Sum(t), SoFar: Running(Sum(Sum(t))),";
        text ~cls:"c" x0 39 "                        Before: Prev(Sum(t)), Mean3: Running(Avg(Sum(t)), last = 3)}" ];
  let heads = [| "Month"; "Billed"; "SoFar"; "Before"; "Mean3" |] in
  Array.iteri (fun j h -> add [ text ~cls:"h" (cols.(j) + (if j = 0 then 8 else 90)) (top - 8) ~anchor:(if j = 0 then "start" else "end") h ]) heads;
  List.iteri
    (fun r row ->
      let y = ycell r in
      add [ rect (if r = cur then "cur" else "row") x0 y 560 (rh - 4) ];
      (* the frame of last = 3 in Billed: the current row and the 2 before *)
      if r >= cur - 2 && r <= cur then add [ rect "frame" (cols.(1) + 2) (y + 2) 92 (rh - 8) ];
      add [ text (x0 + 8) (y + 17) (month_of row.(0));
            text ~anchor:"end" (cols.(1) + 90) (y + 17) (money row.(1));
            text ~cls:(if r = cur then "a" else "") ~anchor:"end" (cols.(2) + 90) (y + 17) (money row.(2));
            text ~cls:(if Value.is_missing row.(3) then "off" else if r = cur then "a" else "") ~anchor:"end" (cols.(3) + 90) (y + 17) (money row.(3));
            text ~cls:(if r = cur then "a" else "") ~anchor:"end" (cols.(4) + 90) (y + 17) (money row.(4)) ])
    m;
  let n = List.length m in
  let april = List.nth m cur in
  (* the running total's rows: a bracket from the first row to the current one *)
  let yb = ycell 0 + 2 and ye = ycell cur + rh - 6 in
  add [ path "br" (Printf.sprintf "M 590 %d h 8 V %d h -8" yb ye);
        text ~cls:"s" 606 ((yb + ye) / 2 - 6) "SoFar: the sum of";
        text ~cls:"s" 606 ((yb + ye) / 2 + 10) (Printf.sprintf "January to April, %s" (money april.(2))) ];
  (* Prev: March's Billed into April's Before *)
  let ym = ycell (cur - 1) + 13 and ya = ycell cur + 13 in
  add [ path "gr" (Printf.sprintf "M %d %d C %d %d, %d %d, %d %d" (cols.(1) + 94) ym (cols.(1) + 160) ym (cols.(3) + 10) ya (cols.(3) + 36) ya);
        Printf.sprintf "<path d=\"M %d %d l -7 -4 v 8 z\" fill=\"#57606a\"/>" (cols.(3) + 40) ya ];
  let yl = ycell n + 14 in
  add [ text ~cls:"s" x0 yl (Printf.sprintf "April's frame of last = 3 (dashed): February, March and April, mean %s. Prev(Sum(t)): March's %s." (money april.(4)) (money april.(3)));
        text ~cls:"s" x0 (yl + 18) "January has no month before it: Before is missing; its frame is January alone, February's two months." ];
  svg (Filename.concat dir "windows-running.svg") 780 (yl + 32) "The months of 2028 in Sort's order, a running total, the month before and a moving mean of 3" !body;
  (* 2. the invoices by client, the latest first: Each and Limit 3 *)
  let qi =
    { Query.vars = 5; where = [ { Query.e = Var 0; p = date; v = Var 1 }; { e = Var 0; p = total; v = Var 2 }; { e = Var 0; p = client; v = Var 3 }; { e = Var 3; p = name; v = Var 4 } ]; ranges = [] }
  in
  let all = rows (Answer.answer ~order:{ Question.Top.keys = [ { col = 0; desc = false }; { col = 1; desc = true } ]; limit = 0; after = None } v qi (Wire.Give [| 4; 1; 2 |])) in
  let kept = rows (Answer.answer ~order:{ Question.Top.keys = [ { col = 0; desc = false }; { col = 1; desc = true } ]; limit = 3; after = None } v qi (Wire.Over (Wire.Give [| 4; 1; 2 |], [| 0 |], [||]))) in
  let body = ref [] in
  let add l = body := !body @ l in
  add [ text ~cls:"c" 16 22 "Sort: [n, Desc(d)]   Limit: 3   Each: [n]" ];
  let top = 48 and rh = 26 in
  let seen = Hashtbl.create 4 in
  let y = ref top and last = ref "" in
  List.iter
    (fun row ->
      let n = match row.(0) with Value.Text s -> s | _ -> "?" in
      if n <> !last then begin
        if !last <> "" then (add [ Printf.sprintf "<line class=\"cut\" x1=\"16\" y1=\"%d\" x2=\"470\" y2=\"%d\"/>" (!y + 3) (!y + 3) ]; y := !y + 8);
        last := n
      end;
      let k = 1 + Option.value (Hashtbl.find_opt seen n) ~default:0 in
      Hashtbl.replace seen n k;
      let keep = List.exists (fun r -> Value.equal r.(0) row.(0) && Value.equal r.(1) row.(1) && Value.equal r.(2) row.(2)) kept in
      let cls = if keep then "" else "off" in
      add [ rect (if k = 1 then "cur" else "row") 16 !y 454 (rh - 4);
            text ~cls (24) (!y + 16) n; text ~cls 150 (!y + 16) (day_of row.(1)); text ~cls ~anchor:"end" 290 (!y + 16) (money row.(2)) ];
      if not keep then add [ Printf.sprintf "<line class=\"cut\" x1=\"20\" y1=\"%d\" x2=\"300\" y2=\"%d\"/>" (!y + 11) (!y + 11); text ~cls:"off" 312 (!y + 16) "after the 3rd: left out" ]
      else if k = 1 then add [ text ~cls:"a" 312 (!y + 16) "1st: Limit: 1 keeps it" ]
      else add [ text ~cls:"s" 312 (!y + 16) (Printf.sprintf "%s of %s" (if k = 2 then "2nd" else "3rd") n) ];
      y := !y + rh)
    all;
  add [ text ~cls:"s" 16 (!y + 16) (Printf.sprintf "%d invoices read once; %d kept: the first 3 rows of each client in Sort's order." (List.length all) (List.length kept)) ];
  svg (Filename.concat dir "windows-each.svg") 520 (!y + 30) "The invoices of 2028 by client, the latest first: Each by client and Limit 3 keep the first 3 of each" !body;
  (* 3. the leaderboard: Rank, Rank(dense = true), Running(Count()) *)
  let qb = { Query.vars = 4; where = [ { Query.e = Var 0; p = total; v = Var 1 }; { e = Var 0; p = client; v = Var 2 }; { e = Var 2; p = name; v = Var 3 } ]; ranges = [] } in
  let b =
    rows
      (Answer.answer ~order:{ Question.Top.keys = [ { col = 1; desc = true }; { col = 0; desc = false } ]; limit = 0; after = None } v qb
         (Wire.Over (Wire.Group ([| 3 |], [| Wire.Sum 1 |]), [||], [| Wire.Rank (1, false); Rank (1, true); Running (Count, 0) |])))
  in
  let body = ref [] in
  let add l = body := !body @ l in
  add [ text ~cls:"c" 16 22 "Sort: [Desc(Sum(t))]" ];
  let heads = [ 16, "Client"; 150, "Revenue"; 262, "Rank()"; 352, "Rank(dense = true)"; 506, "Running(Count())" ] in
  List.iter (fun (x, h) -> add [ text ~cls:"h" x 50 h ]) heads;
  let top = 60 and rh = 28 in
  List.iteri
    (fun r row ->
      let y = top + (r * rh) in
      add [ rect "row" 16 y 620 (rh - 4); text 24 (y + 17) (match row.(0) with Value.Text s -> s | _ -> "?");
            text ~anchor:"end" 230 (y + 17) (money row.(1)); text ~cls:"a" 290 (y + 17) (Value.to_string row.(2));
            text ~cls:"a" 410 (y + 17) (Value.to_string row.(3)); text ~cls:"a" 560 (y + 17) (Value.to_string row.(4)) ])
    b;
  let yt = top + 2 and ye = top + (2 * rh) - 6 in
  add [ path "br" (Printf.sprintf "M 646 %d h 8 V %d h -8" yt ye); text ~cls:"s" 662 (yt + 12) "equal in Sort's key:"; text ~cls:"s" 662 (yt + 28) "one place" ];
  let yl = top + (List.length b * rh) + 14 in
  add [ text ~cls:"s" 16 yl "Rank() skips the place the tie takes (no 2nd); Rank(dense = true) skips none; Running(Count()) numbers the rows";
        text ~cls:"s" 16 (yl + 18) "one by one, Ada before Bo since Sort then orders by every other field (the client's name)." ];
  svg (Filename.concat dir "windows-rank.svg") 800 (yl + 32) "A leaderboard with a tie: Rank, Rank(dense = true) and Running(Count())" !body
