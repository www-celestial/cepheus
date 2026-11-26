(* The figures of the model, each drawn from what the engine answers on the data of the page it illustrates:
   facts-question.svg (concepts, Questions), groups-views.svg (concepts, Views), rules-derive.svg (rules),
   pages-after.svg (tutorial 4 and Cepheus from Cesia, pages) and report-groups.svg (Cepheus from Cesia, reports). *)

open Cepheus
open Cepheus_server
open Draw

let ok = function Ok r -> r | Error e -> failwith (message e)

let money l m = nb l (Printf.sprintf "%s.%02d" (thousands (m / 100)) (abs m mod 100))

(* a value as the figures write it: a text in quotes, a link #id, money with its 2 digits *)
let show l = function
  | Value.Text s -> "\"" ^ s ^ "\""
  | Link e -> "#" ^ string_of_int e
  | Money m -> money l m
  | Bool b -> string_of_bool b
  | Int n -> string_of_int n
  | x -> Value.to_string x

let pname v p = match describe v p with Some d -> d.name | None -> string_of_int p

let rows v (a : Answer.answer) = List.init a.n (fun i -> Array.init a.cols (fun j -> Answer.value v a i j))

(* 1. a question's patterns and the facts each answer uses: the data of concepts.md's question *)
let facts_question docs =
  let db = fork empty in
  let[@warning "-8"] (Ok [ city; client; status; total ]) =
    declare db [ prop "client/city" Ttext; prop "invoice/client" Tlink; prop "invoice/status" Ttext; prop "invoice/total" (Tmoney 2) ]
  in
  let r = ok (write db [ Add (-1, city, Text "Lyon"); Add (-2, city, Text "Paris") ]) in
  let lyon = thing r (-1) and paris = thing r (-2) in
  let invoices =
    List.map
      (fun (c, s, t) -> thing (ok (write db [ Add (-1, client, Link c); Add (-1, status, Text s); Add (-1, total, Money t) ])) (-1))
      [ lyon, "unpaid", 12000; lyon, "paid", 5000; paris, "unpaid", 7000; lyon, "unpaid", 3000 ]
  in
  let v = view db in
  let pats =
    [ { e = Var 0; p = city; v = Val (Text "Lyon") }; { e = Var 1; p = client; v = Var 0 }; { e = Var 1; p = status; v = Val (Text "unpaid") };
      { e = Var 1; p = total; v = Var 2 } ]
  in
  let answers = List.sort compare (ok (find v { vars = 3; ranges = []; where = pats })) in
  (* each pattern alone: the facts it matches *)
  let alone =
    List.map
      (fun (pt : pattern) ->
        (* the pattern's variables numbered from 0, as a question of its own *)
        let n = ref 0 and seen = Hashtbl.create 2 in
        let re = function Var k -> (match Hashtbl.find_opt seen k with Some j -> Var j | None -> Hashtbl.add seen k !n; incr n; Var (!n - 1)) | t -> t in
        let e = re pt.e in
        let x = re pt.v in
        List.length (ok (find v { vars = !n; ranges = []; where = [ { pt with e; v = x } ] })))
      pats
  in
  let facts = List.concat_map (fun e -> List.map (fun (p, x) -> e, p, x) (get v e)) ((lyon :: paris :: invoices)) in
  (* the answers that use a fact: those whose binding, put in a pattern, gives that fact *)
  let term b = function Var k -> b.(k) | Val x -> x | Thing e -> Link e in
  let uses (e, p, x) =
    List.concat
      (List.mapi
         (fun k b -> if List.exists (fun (pt : pattern) -> pt.p = p && Value.equal (term b pt.e) (Link e) && Value.equal (term b pt.v) x) pats then [ k + 1 ] else [])
         answers)
  in
  let var = [| "c"; "i"; "t" |] in
  let tm = function Var k -> "?" ^ var.(k) | Val x -> show En x | Thing e -> "#" ^ string_of_int e in
  both docs "facts-question.svg" (fun l f ->
      text f ~cls:"h" 16 22 (tr l "The facts of the view" "Les faits de la vue");
      List.iteri (fun j h -> text f ~cls:"s sm" [| 22; 80; 200; 290 |].(j) 44 h) [ "thing"; "property"; "value"; tr l "answers" "réponses" ];
      let top = 52 and rh = 22 in
      List.iteri
        (fun r ((e, p, x) as fact) ->
          let y = top + (r * rh) in
          let u = uses fact in
          rect f (if u = [] then "row" else "cur") 16 y 330 (rh - 3);
          code f 22 (y + 14) ("#" ^ string_of_int e);
          code f 80 (y + 14) (pname v p);
          code f 200 (y + 14) (show l x);
          List.iteri (fun k a -> circle f "s1" (300 + (k * 22)) (y + 9) 8; text f ~cls:"w h sm" ~anchor:"middle" (300 + (k * 22)) (y + 13) (string_of_int a)) u;
          if u = [] then text f ~cls:"off sm" 296 (y + 14) "-")
        facts;
      let x0 = 366 in
      text f ~cls:"h" x0 22 (tr l "The question: 4 patterns" "La question : 4 motifs");
      text f ~cls:"s sm" (x0 + 330) 44 ~anchor:"end" (tr l "facts it matches alone" "faits qu'il touche seul");
      List.iteri
        (fun k (pt : pattern) ->
          let y = 52 + (k * 26) in
          rect f "box" x0 y 330 22;
          code f (x0 + 8) (y + 15) (Printf.sprintf "[%s, %s, %s]" (tm pt.e) (pname v pt.p) (tm pt.v));
          text f ~cls:"a" ~anchor:"end" (x0 + 322) (y + 15) (string_of_int (List.nth alone k)))
        pats;
      let ya = 52 + (4 * 26) + 30 in
      text f ~cls:"h" x0 ya (Printf.sprintf (trf l "The answer: %d bindings" "La réponse : %d liaisons") (List.length answers));
      text f ~cls:"s sm" x0 (ya + 17) (tr l "each makes every pattern a fact" "chacune fait de chaque motif un fait");
      List.iteri (fun j h -> code f ~cls:"s" (x0 + [| 36; 120; 220 |].(j)) (ya + 40) h) [ "?c"; "?i"; "?t" ];
      List.iteri
        (fun k b ->
          let y = ya + 48 + (k * 26) in
          rect f "cur" x0 y 330 22;
          circle f "s1" (x0 + 14) (y + 11) 8;
          text f ~cls:"w h sm" ~anchor:"middle" (x0 + 14) (y + 15) (string_of_int (k + 1));
          code f (x0 + 36) (y + 15) (show l b.(0));
          code f (x0 + 120) (y + 15) (show l b.(1));
          code f (x0 + 220) (y + 15) (show l b.(2)))
        answers;
      let yn = ya + 48 + (List.length answers * 26) + 20 in
      List.iteri (fun k t -> text f ~cls:"s" x0 (yn + (k * 17)) t)
        (match l with
         | En -> [ "A fact may serve several answers: the city"; "of Lyon, both. The paid invoice and those of"; "Paris match some of the patterns, not all." ]
         | Fr -> [ "Un fait peut servir plusieurs réponses : la ville"; "de Lyon, les deux. La facture payée et celles de"; "Paris touchent une partie des motifs, pas tous." ]);
      let h = max (top + (List.length facts * rh) + 12) (yn + 44) in
      712, h, tr l "The facts of a view and a question of 4 patterns: which facts each answer uses" "Les faits d'une vue et une question de 4 motifs : les faits qu'utilise chaque réponse")

(* 2. groups, and the views after them: a client signs up, is renamed, moves *)
let groups_views docs =
  let db = fork empty in
  let[@warning "-8"] (Ok [ name; city ]) = declare db [ prop "client/name" Ttext; prop "client/city" Ttext ] in
  let g0 = group (view db) in
  let r = ok (write db ~by:7 ~why:"signup" [ Add (-1, name, Text "Ada Martin"); Add (-1, city, Text "Lyon") ]) in
  let ada = thing r (-1) in
  let v1 = view db in
  let r2 = ok (write db ~by:7 ~why:"rename" [ Add (ada, name, Text "Ada Durand") ]) in
  let v2 = view db in
  let r3 = ok (write db ~by:9 ~why:"move" [ Add (ada, city, Text "Paris") ]) in
  let v3 = view db in
  let state v = List.sort compare (get v ada) in
  let diff a b = List.filter (fun x -> not (List.mem x b)) a in
  let steps = [ r.group, 7, "signup", [], state v1; r2.group, 7, "rename", state v1, state v2; r3.group, 9, "move", state v2, state v3 ] in
  both docs "groups-views.svg" (fun l f ->
      let colw = 216 and gap = 20 in
      text f ~cls:"s" 16 22
        (Printf.sprintf (trf l "Groups 1 to %d: the system's properties, then client/name and client/city declared. The thing: #%d." "Groupes 1 à %d : les propriétés du système, puis client/name et client/city déclarées. La chose : #%d.") g0 ada);
      List.iteri
        (fun k (g, by, why, before, after) ->
          let x = 16 + (k * (colw + gap)) in
          rect f "box" x 36 colw 92;
          spans f (x + 10) 56 [ "h", Printf.sprintf (trf l "group %d" "groupe %d") g; "s", Printf.sprintf ",  by %d,  " by; "", Printf.sprintf "%S" why ];
          let lines = List.map (fun c -> "del", "- ", c) (diff before after) @ List.map (fun c -> "add", "+ ", c) (diff after before) in
          List.iteri (fun j (cls, sign, (p, x')) -> code f ~cls (x + 10) (80 + (j * 18)) (Printf.sprintf "%s%s %s" sign (pname v1 p) (show l x'))) lines;
          if k < 2 then arrow f (x + colw + 2) 82 (x + colw + gap - 2) 82;
          (* its view *)
          let vy = 160 in
          arrow f (x + (colw / 2)) 130 (x + (colw / 2)) (vy - 4);
          rect f (if k = 1 then "cur" else "row") x vy colw 70;
          text f ~cls:(if k = 1 then "a" else "s") (x + 10) (vy + 18) (Printf.sprintf (trf l "the view at group %d" "la vue au groupe %d") g);
          List.iteri (fun j (p, x') -> code f (x + 10) (vy + 38 + (j * 18)) (Printf.sprintf "%s %s" (pname v1 p) (show l x'))) after)
        steps;
      let x2 = 16 + colw + gap in
      List.iteri (fun k t -> text f ~cls:"a" x2 (252 + (k * 17)) t)
        [ tr l "A reader that took this view reads the same" "Un lecteur qui a pris cette vue lit les mêmes";
          Printf.sprintf (trf l "facts while group %d is written, and after." "faits pendant que le groupe %d s'écrit, et après.") r3.group ];
      List.iteri (fun k t -> text f ~cls:"s" 16 (300 + (k * 17)) t)
        [ tr l "Nothing is erased: a change of value is a retraction (-) and an addition (+) of a later group," "Rien n'est effacé : un changement de valeur est un retrait (-) et un ajout (+) d'un groupe plus tard,";
          tr l "and the journal keeps every group." "et le journal garde chaque groupe." ];
      712, 330, tr l "Three groups and the view after each: a view is the state after one group, and never changes" "Trois groupes et la vue après chacun : une vue est l'état après un groupe, et ne change jamais")

(* 3. a rule's facts derived, then retracted with their premise: rules.md's first example *)
let rules_derive docs =
  let db = fork empty in
  let[@warning "-8"] (Ok [ ty; parent ]) = declare db [ prop ~many:true "thing/type" Tlink; prop ~many:true "class/parent" Tlink ] in
  let r = ok (write db [ Add (-1, parent, Link (-2)); Add (-2, parent, Link (-3)) ]) in
  let invoice = thing r (-1) and document = thing r (-2) and record = thing r (-3) in
  let is_a =
    { name = "is-a"; vars = 3; where = [ { e = Var 0; p = ty; v = Var 1 }; { e = Var 1; p = parent; v = Var 2 } ]; ranges = []; head = Give { e = Var 0; p = ty; v = Var 2 } }
  in
  ignore (ok (define db [ is_a ]));
  let g1 = ok (write db [ Add (-1, ty, Link invoice) ]) in
  let x = thing g1 (-1) in
  let v1 = view db in
  let refused = match write db [ Retract (x, ty, Link document) ] with Error e -> message e | Ok _ -> "?" in
  let g2 = ok (write db [ Retract (x, ty, Link invoice) ]) in
  let v2 = view db in
  let label = [ invoice, "invoice"; document, "document"; record, "record" ] in
  let cls e = try List.assoc e label with Not_found -> "x" in
  let all v = List.concat_map (fun e -> List.map (fun (p, x) -> e, p, x) (get v e)) [ invoice; document; record; x ] in
  let derived v (e, p, x') = match why v e p x' with Some (By _) -> true | _ -> false in
  let f1 = all v1 and f2 = all v2 in
  let fact l (e, p, x') = Printf.sprintf "[#%d %s %s]" e (pname v1 p) (show l x') in
  let note _ = "" in
  ignore cls;
  both docs "rules-derive.svg" (fun l f ->
      code f 16 22 "is-a: [x, thing/type, c], [c, class/parent, d] => [x, thing/type, d]";
      let col k = 16 + (k * 352) and w = 336 in
      let heads =
        [ Printf.sprintf (trf l "group %d: Add [#%d thing/type #%d]" "groupe %d : Add [#%d thing/type #%d]") g1.group x invoice;
          Printf.sprintf (trf l "group %d: Retract [#%d thing/type #%d]" "groupe %d : Retract [#%d thing/type #%d]") g2.group x invoice ]
      in
      code f ~cls:"s" 16 40 (Printf.sprintf "#%d invoice   #%d document   #%d record   #%d x" invoice document record x);
      List.iteri (fun k h -> text f ~cls:"h" (col k) 66 h) heads;
      let rh = 26 and top = 78 in
      (* before: every fact, the derived ones with their rule *)
      List.iteri
        (fun j ft ->
          let y = top + (j * rh) in
          let d = derived v1 ft in
          rect f (if d then "cur" else "row") (col 0) y w (rh - 4);
          code f (col 0 + 8) (y + 16) (fact l ft);
          text f ~cls:(if d then "a sm" else "s sm") (col 0 + w - 8) (y + 16) ~anchor:"end" (if d then tr l "derived by is-a" "dérivé par is-a" else note ft))
        f1;
      (* after: what stayed, and what went *)
      List.iteri
        (fun j ft ->
          let y = top + (j * rh) in
          let kept = List.mem ft f2 in
          let d = derived v1 ft in
          rect f (if kept then "row" else "rowdel") (col 1) y w (rh - 4);
          code f ~cls:(if kept then "" else "del") (col 1 + 8) (y + 16) (fact l ft);
          if not kept then line f "ldel" (col 1 + 6) (y + 11) (col 1 + 10 + (String.length (fact l ft) * 15 / 2)) (y + 11);
          text f ~cls:(if kept then "s sm" else "del sm") (col 1 + w - 8) (y + 16) ~anchor:"end"
            (if kept then note ft else if d then tr l "no proof left: goes" "plus de preuve : part" else tr l "retracted" "retiré"))
        f1;
      (* the proof of the farthest one, as why gives it *)
      let yp = top + (List.length f1 * rh) + 22 in
      text f ~cls:"h" 16 yp (Printf.sprintf (trf l "why [#%d thing/type #%d] at group %d:" "why [#%d thing/type #%d] au groupe %d :") x record g1.group);
      let y = ref (yp + 20) in
      let rec proof indent = function
        | Given g -> code f (16 + indent) !y (Printf.sprintf "given [#%d %s %s]" g.e (pname v1 g.p) (show l g.v)); y := !y + 18
        | By b ->
          code f ~cls:"a" (16 + indent) !y (Printf.sprintf "[#%d %s %s] by %s" b.e (pname v1 b.p) (show l b.v) b.rule);
          y := !y + 18;
          List.iter (proof (indent + 16)) b.from
      in
      Option.iter (proof 0) (why v1 x ty (Link record));
      text f ~cls:"h" (col 1) yp (tr l "A derived fact alone is not retracted:" "Un fait dérivé seul ne se retire pas :");
      code f ~cls:"del" (col 1) (yp + 20) (Printf.sprintf "Retract [#%d thing/type #%d]" x document);
      let words = String.split_on_char ' ' refused in
      (* the engine's message, cut in lines of about 44 characters *)
      let lines = List.rev (List.fold_left (fun acc w -> match acc with h :: t when String.length h + String.length w < 44 -> (h ^ " " ^ w) :: t | _ -> w :: acc) [] words) in
      List.iteri (fun k s -> code f ~cls:"s" (col 1) (yp + 40 + (k * 18)) s) lines;
      712, max (!y + 6) (yp + 40 + (List.length lines * 18) + 6),
      tr l "A rule's facts derived by the writer, then retracted with their premise (Backward/Forward)" "Les faits d'une règle dérivés par l'écrivain, puis retirés avec leur prémisse (Backward/Forward)")

(* 4. pages: After the last row shown, against OFFSET, with a write between the two pages (tutorial 4) *)
let pages_after docs =
  let db = fork empty in
  let[@warning "-8"] (Ok [ cname; client; total ]) = declare db [ prop "client/name" Ttext; prop "invoice/client" Tlink; prop "invoice/total" (Tmoney 2) ] in
  let rc = ok (write db [ Add (-1, cname, Text "Ada Martin"); Add (-2, cname, Text "Bo Lind") ]) in
  let ada = thing rc (-1) and bo = thing rc (-2) in
  (* tutorial 1's invoices of Ada and Bo: 10 k for k = 1 to 30, Ada's when k mod 3 = 0, Bo's when it is 1 *)
  for k = 1 to 30 do
    if k mod 3 <> 2 then ignore (ok (write db [ Add (-1, client, Link (if k mod 3 = 0 then ada else bo)); Add (-1, total, Money (1000 * k)) ]))
  done;
  let q = { Query.vars = 4; where = [ { Query.e = Var 0; p = total; v = Var 1 }; { e = Var 0; p = client; v = Var 2 }; { e = Var 2; p = cname; v = Var 3 } ]; ranges = [] } in
  let ask v limit after = rows v (Answer.answer ~order:{ Question.Top.keys = [ { col = 0; desc = true } ]; limit; after } v q (Wire.Give [| 1; 3 |])) in
  let v1 = view db in
  let page1 = ask v1 3 None in
  let before = ask v1 8 None in
  ignore (ok (write db [ Add (-1, client, Link ada); Add (-1, total, Money 100000) ]));
  let v2 = view db in
  let cursor = List.nth page1 2 in
  let page2 = ask v2 3 (Some cursor) in
  let after = ask v2 9 None in
  let offset = List.filteri (fun i _ -> i >= 3 && i < 6) after in
  let same a b = Value.equal a.(0) b.(0) && Value.equal a.(1) b.(1) in
  let who = function Value.Text s -> s | _ -> "?" in
  let amount l = function Value.Money m -> money l m | _ -> "?" in
  both docs "pages-after.svg" (fun l f ->
      code f 16 22 "Sort: [cepheus.Desc(t)]   Limit: 3   After: after";
      let lx = 16 and rx = 330 and top = 72 and rh = 26 and rw = 180 in
      text f ~cls:"h" lx 52 (tr l "Page 1, at its group" "Page 1, à son groupe");
      text f ~cls:"h" rx 52 (tr l "Page 2: a new invoice meanwhile" "Page 2 : une nouvelle facture entre-temps");
      let row x y cls r = rect f cls x y rw (rh - 4); text f (x + 10) (y + 16) (who r.(1)); text f ~anchor:"end" (x + rw - 10) (y + 16) (amount l r.(0)) in
      List.iteri (fun i r -> row lx (top + (i * rh)) (if same r cursor then "cur" else "row") r) before;
      (* page 1's bracket and its cursor *)
      path f "br" (Printf.sprintf "M %d %d h 8 V %d h -8" (lx + rw + 6) (top + 2) (top + (3 * rh) - 6));
      text f ~cls:"a" (lx + rw + 20) (top + 30) "Limit: 3";
      text f ~cls:"a" (lx + rw + 20) (top + (2 * rh) + 8) (tr l "the cursor:" "le curseur :");
      code f ~cls:"a" (lx + rw + 20) (top + (2 * rh) + 24) "first[3]";
      List.iteri
        (fun i r ->
          let y = top + (i * rh) in
          let isnew = i = 0 in
          row rx y (if isnew then "rowadd" else if same r cursor then "cur" else "row") r;
          if isnew then text f ~cls:"add sm" (rx + rw + 10) (y + 16) (tr l "written between the pages" "écrite entre les pages"))
        after;
      (* After: the rows after the cursor; OFFSET 3: the 4th to 6th rows of the new order *)
      let idx r = let rec go i = function x :: t -> if same x r then i else go (i + 1) t | [] -> -1 in go 0 after in
      let span rows = idx (List.hd rows), idx (List.nth rows (List.length rows - 1)) in
      let a0, a1 = span page2 and o0, o1 = span offset in
      path f "br" (Printf.sprintf "M %d %d h 8 V %d h -8" (rx + rw + 6) (top + (a0 * rh) + 2) (top + (a1 * rh) + rh - 6));
      text f ~cls:"a" (rx + rw + 20) (top + (a0 * rh) + 22) "After: first[3]";
      text f ~cls:"a" (rx + rw + 20) (top + (a0 * rh) + 39) (tr l "the 3 rows after it" "les 3 lignes après lui");
      path f "ldel" (Printf.sprintf "M %d %d h -8 V %d h 8" (rx - 6) (top + (o0 * rh) + 2) (top + (o1 * rh) + rh - 6));
      text f ~cls:"del" ~anchor:"end" (rx - 18) (top + (o0 * rh) + 16) "OFFSET 3";
      text f ~cls:"del sm" ~anchor:"end" (rx - 18) (top + (o0 * rh) + 33) (Printf.sprintf (trf l "%s twice" "%s deux fois") (amount l cursor.(0)));
      let yl = top + (List.length after * rh) + 16 in
      List.iteri (fun k t -> text f ~cls:"s" lx (yl + (k * 17)) t)
        [ tr l "After goes on after the last row shown, whatever was written before it;" "After reprend après la dernière ligne montrée, quoi qu'on ait écrit avant elle ;";
          tr l "OFFSET counts rows, and the new one pushed them down by one." "OFFSET compte des lignes, et la nouvelle les a toutes décalées d'une." ];
      712, yl + 30,
      tr l "Two pages of invoices, the largest first, with a write between them: After against OFFSET" "Deux pages de factures, la plus grande d'abord, avec une écriture entre elles : After contre OFFSET")

(* 5. a report: rows grouped by a key, each group's aggregates (the sales of Cepheus from Cesia, Reports) *)
let report_groups docs =
  let db = fork empty in
  let[@warning "-8"] (Ok [ cname; client; amount ]) = declare db [ prop "client/name" Ttext; prop "sale/client" Tlink; prop "sale/amount" (Tmoney 2) ] in
  let rc = ok (write db [ Add (-1, cname, Text "Ada Martin"); Add (-2, cname, Text "Bo Lind") ]) in
  let ada = thing rc (-1) and bo = thing rc (-2) in
  List.iter (fun (c, a) -> ignore (ok (write db [ Add (-1, client, Link c); Add (-1, amount, Money (a * 100)) ]))) [ ada, 10; ada, 30; bo, 20; bo, 60 ];
  let v = view db in
  let q = { Query.vars = 4; where = [ { Query.e = Var 0; p = client; v = Var 1 }; { e = Var 1; p = cname; v = Var 2 }; { e = Var 0; p = amount; v = Var 3 } ]; ranges = [] } in
  let order = { Question.Top.keys = [ { col = 0; desc = false } ]; limit = 0; after = None } in
  let raw = rows v (Answer.answer ~order:{ order with keys = [ { col = 0; desc = false }; { col = 1; desc = false } ] } v q (Wire.Give [| 2; 3 |])) in
  let g = rows v (Answer.answer ~order v q (Wire.Group ([| 2 |], [| Wire.Avg 3; Quantile (3, 0.5, false); Quantile (3, 0.25, false); Stddev (3, false) |]))) in
  let num l = function
    | Value.Money m -> money l m
    | Float x -> nb l (if Float.is_integer x then Printf.sprintf "%.1f" x else Printf.sprintf "%.2f" x)
    | x -> Value.to_string x
  in
  let who = function Value.Text s -> s | _ -> "?" in
  both docs "report-groups.svg" (fun l f ->
      code f 16 22 "Give: {Name: n, Mean: Avg(a), Median: Median(a),";
      code f 16 39 "       Low: Quantile(a, 0.25), Spread: Stddev(a)}";
      text f ~cls:"h" 16 66 (tr l "The rows of Where" "Les lignes du Where");
      text f ~cls:"h" 262 66 (tr l "One row a value of the key n" "Une ligne par valeur de la clé n");
      let rh = 26 and top = 80 and rw = 180 in
      List.iteri
        (fun i r ->
          let y = top + (i * rh) + if i >= 2 then 10 else 0 in
          rect f "row" 16 y rw (rh - 4);
          text f 26 (y + 16) (who r.(0));
          text f ~anchor:"end" (16 + rw - 10) (y + 16) (num l r.(1)))
        raw;
      let cx = [| 272; 450; 530; 610; 690 |] in
      List.iteri (fun j h -> text f ~cls:"s sm" cx.(j) (top + 12) ~anchor:(if j = 0 then "start" else "end") h) [ "Name"; "Mean"; "Median"; "Low"; "Spread" ];
      List.iteri
        (fun k r ->
          let y = top + 22 + (k * 60) in
          let ys = top + (k * ((2 * rh) + 10)) in
          path f "br" (Printf.sprintf "M %d %d h 8 V %d h -8" (16 + rw + 6) (ys + 2) (ys + (2 * rh) - 6));
          arrow f (16 + rw + 16) (ys + rh - 2) 258 (y + 11);
          rect f "cur" 262 y 438 (rh - 4);
          text f (cx.(0)) (y + 16) (who r.(0));
          Array.iteri (fun j x -> text f ~cls:"a" ~anchor:"end" cx.(j + 1) (y + 16) (num l x)) (Array.sub r 1 4))
        g;
      let yl = top + (4 * rh) + 34 in
      let a = List.hd g in
      List.iteri (fun k t -> text f ~cls:"s" 16 (yl + (k * 17)) t)
        (match l with
         | En ->
           [ Printf.sprintf "Ada: the mean of 10 and 30 is %s, so is the median; Low is 10 plus a quarter of the way" (num l a.(1));
             Printf.sprintf "to 30, %s; Spread, the difference of the two over √2, %s." (num l a.(3)) (num l a.(4)) ]
         | Fr ->
           [ Printf.sprintf "Ada : la moyenne de 10 et 30 est %s, la médiane aussi ; Low est 10 plus un quart du chemin" (num l a.(1));
             Printf.sprintf "vers 30, %s ; Spread, l'écart des deux sur √2, %s." (num l a.(3)) (num l a.(4)) ]);
      712, yl + 30, tr l "A report: the rows grouped by the client's name, and each group's aggregates" "Un rapport : les lignes groupées par le nom du client, et les agrégats de chaque groupe")

let draw docs =
  facts_question docs;
  groups_views docs;
  rules_derive docs;
  pages_after docs;
  report_groups docs
