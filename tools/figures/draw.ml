(* What every figure of the book is drawn with: a small SVG of its own, with its own background, light or dark as the
   reader's system is (prefers-color-scheme), so that it reads on a light page and on a dark one; text in the system's
   font, code in its monospace; only the elements the site shows (svg, title, style, rect, path, line, polygon,
   circle, text, tspan, g), nothing that loads or runs. A figure with words is drawn once a language: English into
   docs/book/images, French into docs/fr/book/images, under the same name; one without words, once, for both. *)

type lang = En | Fr

let tr l en fr = match l with En -> en | Fr -> fr

(* the same for a format of Printf *)
let trf l (en : ('a, unit, string) format) (fr : ('a, unit, string) format) = match l with En -> en | Fr -> fr

let esc s =
  let b = Buffer.create (String.length s) in
  String.iter (function '&' -> Buffer.add_string b "&amp;" | '<' -> Buffer.add_string b "&lt;" | '>' -> Buffer.add_string b "&gt;" | c -> Buffer.add_char b c) s;
  Buffer.contents b

(* a number written in English (1,200.50, 104.7 MB) as the French pages write it (1 200,50, 104,7 Mo; the space one
   that never breaks) *)
let nb l s =
  match l with
  | En -> s
  | Fr ->
    let b = Buffer.create (String.length s + 4) in
    String.iter (function ',' -> Buffer.add_string b "\xc2\xa0" | '.' -> Buffer.add_char b ',' | c -> Buffer.add_char b c) s;
    let t = Buffer.contents b in
    (* megabytes, as the French pages write them *)
    if String.ends_with ~suffix:" MB" t then String.sub t 0 (String.length t - 2) ^ "Mo" else t

(* an int with its thousands: 245000 -> 245,000 *)
let thousands n =
  let s = string_of_int (abs n) in
  let k = String.length s in
  let b = Buffer.create (k + 4) in
  if n < 0 then Buffer.add_char b '-';
  String.iteri (fun i c -> if i > 0 && (k - i) mod 3 = 0 then Buffer.add_char b ','; Buffer.add_char b c) s;
  Buffer.contents b

(* the colors: each class light, then dark; the series are the first three slots of a palette checked for colour
   blindness in both modes (blue, orange, aqua) *)
let classes =
  [ "text", "font-family:system-ui,sans-serif;font-size:13px;fill:#1f2328", "fill:#e6edf3";
    ".c", "font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12.5px", "";
    ".h", "font-weight:600", "";
    ".sm", "font-size:11.5px", "";
    ".w", "fill:#ffffff", "fill:#ffffff";
    ".s", "fill:#57606a", "fill:#9198a1";
    ".a", "fill:#3a5ad9", "fill:#8fa8ff";
    ".off", "fill:#8c959f", "fill:#6e7681";
    ".add", "fill:#1a7f37", "fill:#3fb950";
    ".del", "fill:#cf222e", "fill:#f85149";
    ".bg", "fill:#ffffff", "fill:#0d1117";
    ".row", "fill:#ffffff;stroke:#d0d7de;stroke-width:1", "fill:#161b22;stroke:#3d444d";
    ".box", "fill:#f6f8fa;stroke:#d0d7de;stroke-width:1", "fill:#1c2128;stroke:#3d444d";
    ".cur", "fill:#eef1fc;stroke:#3a5ad9;stroke-width:1.6", "fill:#1f2a4d;stroke:#8fa8ff";
    ".frame", "fill:#eef1fc;stroke:#3a5ad9;stroke-width:1.2;stroke-dasharray:4 3", "fill:#1f2a4d;stroke:#8fa8ff";
    ".dash", "fill:none;stroke:#8c959f;stroke-width:1.2;stroke-dasharray:4 3", "stroke:#6e7681";
    ".rowadd", "fill:#dafbe1;stroke:#1a7f37;stroke-width:1.2", "fill:#12261e;stroke:#3fb950";
    ".rowdel", "fill:#ffebe9;stroke:#cf222e;stroke-width:1.2", "fill:#2d1517;stroke:#f85149";
    ".br", "stroke:#3a5ad9;stroke-width:1.4;fill:none", "stroke:#8fa8ff";
    ".gr", "stroke:#57606a;stroke-width:1.2;fill:none", "stroke:#9198a1";
    ".cut", "stroke:#8c959f;stroke-width:1", "stroke:#6e7681";
    ".grid", "stroke:#eaeef2;stroke-width:1", "stroke:#262c36";
    ".axis", "stroke:#8c959f;stroke-width:1", "stroke:#6e7681";
    ".fa", "fill:#3a5ad9", "fill:#8fa8ff";
    ".fs", "fill:#57606a", "fill:#9198a1";
    ".fdel", "fill:#cf222e", "fill:#f85149";
    ".ladd", "stroke:#1a7f37;stroke-width:1.4;fill:none", "stroke:#3fb950";
    ".ldel", "stroke:#cf222e;stroke-width:1.4;fill:none", "stroke:#f85149";
    ".s1", "fill:#257de0", "fill:#338ced";
    ".s2", "fill:#f47230", "fill:#e76624";
    ".s3", "fill:#00b894", "fill:#00a888";
    ".k1", "stroke:#257de0;stroke-width:2;fill:none", "stroke:#338ced";
    ".k2", "stroke:#f47230;stroke-width:2;fill:none", "stroke:#e76624";
    ".k3", "stroke:#00b894;stroke-width:2;fill:none", "stroke:#00a888";
    ".ks", "stroke:#8c959f;stroke-width:2;fill:none;stroke-dasharray:5 3", "stroke:#6e7681" ]

(* the style of a figure: only the classes its lines use (the classes named in its class="..." attributes) *)
let style lines =
  let used = Hashtbl.create 32 in
  let re = Str.regexp "class=\"\\([^\"]*\\)\"" in
  List.iter
    (fun l ->
      let rec scan from =
        match Str.search_forward re l from with
        | at -> List.iter (fun c -> Hashtbl.replace used ("." ^ c) ()) (String.split_on_char ' ' (Str.matched_group 1 l)); scan (at + 1)
        | exception Not_found -> ()
      in
      scan 0)
    lines;
  let keep = List.filter (fun (c, _, _) -> c = "text" || c = ".bg" || Hashtbl.mem used c) classes in
  let b = Buffer.create 2048 in
  Buffer.add_string b "<style>\n";
  List.iter (fun (c, l, _) -> Printf.bprintf b "%s{%s}\n" c l) keep;
  Buffer.add_string b "@media (prefers-color-scheme:dark){\n";
  List.iter (fun (c, _, d) -> if d <> "" then Printf.bprintf b "%s{%s}\n" c d) keep;
  Buffer.add_string b "}\n</style>";
  Buffer.contents b

(* a figure being drawn: its lines, in order *)
type fig = { mutable body : string list }

let fig () = { body = [] }
let add f s = f.body <- s :: f.body

let text f ?(cls = "") ?(anchor = "start") x y s =
  add f
    (Printf.sprintf "<text%s x=\"%d\" y=\"%d\"%s>%s</text>" (if cls = "" then "" else Printf.sprintf " class=\"%s\"" cls) x y
       (if anchor = "start" then "" else Printf.sprintf " text-anchor=\"%s\"" anchor) (esc s))

(* code: monospace, its spaces kept *)
let code f ?(cls = "") ?(anchor = "start") x y s =
  add f
    (Printf.sprintf "<text class=\"c%s\" xml:space=\"preserve\" x=\"%d\" y=\"%d\"%s>%s</text>" (if cls = "" then "" else " " ^ cls) x y
       (if anchor = "start" then "" else Printf.sprintf " text-anchor=\"%s\"" anchor) (esc s))

(* a text of several pieces, each with its class: [("", "x = "); ("a", "4")] *)
let spans f ?(cls = "") ?(anchor = "start") x y parts =
  add f
    (Printf.sprintf "<text%s xml:space=\"preserve\" x=\"%d\" y=\"%d\"%s>%s</text>" (if cls = "" then "" else Printf.sprintf " class=\"%s\"" cls) x y
       (if anchor = "start" then "" else Printf.sprintf " text-anchor=\"%s\"" anchor)
       (String.concat "" (List.map (fun (c, s) -> if c = "" then esc s else Printf.sprintf "<tspan class=\"%s\">%s</tspan>" c (esc s)) parts)))

let rect f ?(r = 0) cls x y w h =
  add f (Printf.sprintf "<rect class=\"%s\" x=\"%d\" y=\"%d\" width=\"%d\" height=\"%d\"%s/>" cls x y w h (if r = 0 then "" else Printf.sprintf " rx=\"%d\"" r))

(* a text cut in lines of at most n bytes, written from y down; the y after its last line *)
let wrap n s =
  List.rev
    (List.fold_left
       (fun acc w -> match acc with h :: t when String.length h + 1 + String.length w <= n -> (h ^ " " ^ w) :: t | _ -> w :: acc)
       [] (String.split_on_char ' ' s))

let para f ?(cls = "s") ?(n = 92) x y s =
  let ls = wrap n s in
  List.iteri (fun k t -> text f ~cls x (y + (k * 17)) t) ls;
  y + (List.length ls * 17)

let line f cls x1 y1 x2 y2 = add f (Printf.sprintf "<line class=\"%s\" x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\"/>" cls x1 y1 x2 y2)
let path f cls d = add f (Printf.sprintf "<path class=\"%s\" d=\"%s\"/>" cls d)
let circle f cls x y r = add f (Printf.sprintf "<circle class=\"%s\" cx=\"%d\" cy=\"%d\" r=\"%d\"/>" cls x y r)

(* the head of an arrow at (x, y), pointing along (dx, dy) *)
let head f cls x y dx dy =
  let len = sqrt (float_of_int ((dx * dx) + (dy * dy))) in
  let ux = float_of_int dx /. len and uy = float_of_int dy /. len in
  let p a b = Printf.sprintf "%.1f,%.1f" a b in
  let fx = float_of_int x and fy = float_of_int y in
  add f
    (Printf.sprintf "<polygon class=\"%s\" points=\"%s %s %s\"/>" cls (p fx fy)
       (p (fx -. (8. *. ux) +. (4. *. uy)) (fy -. (8. *. uy) -. (4. *. ux)))
       (p (fx -. (8. *. ux) -. (4. *. uy)) (fy -. (8. *. uy) +. (4. *. ux))))

(* a straight arrow; [cls] the line's class (gr, br, ladd, ldel), its head filled to match *)
let arrow f ?(cls = "gr") x1 y1 x2 y2 =
  let hc = match cls with "br" -> "fa" | "ldel" -> "fdel" | _ -> "fs" in
  let dx = x2 - x1 and dy = y2 - y1 in
  let len = sqrt (float_of_int ((dx * dx) + (dy * dy))) in
  let sx = x2 - int_of_float (6. *. float_of_int dx /. len) and sy = y2 - int_of_float (6. *. float_of_int dy /. len) in
  line f cls x1 y1 sx sy;
  head f hc x2 y2 dx dy

(* a curve from (x1, y1) to (x2, y2) leaving and arriving horizontally *)
let curve f ?(cls = "gr") x1 y1 x2 y2 =
  let hc = match cls with "br" -> "fa" | "ldel" -> "fdel" | _ -> "fs" in
  let mx = (x1 + x2) / 2 in
  path f cls (Printf.sprintf "M %d %d C %d %d, %d %d, %d %d" x1 y1 mx y1 mx y2 (x2 - 6) y2);
  head f hc x2 y2 (if x2 >= x1 then 1 else -1) 0

(* the figure written: [dir/name], with its title (the alt text says what it shows; the title names it) *)
let save dir name w h title f =
  let oc = open_out_bin (Filename.concat dir name) in
  let body = List.rev f.body in
  Printf.fprintf oc "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\">\n<title>%s</title>\n%s\n" w h w h (esc title) (style body);
  Printf.fprintf oc "<rect class=\"bg\" width=\"%d\" height=\"%d\"/>\n" w h;
  List.iter (fun l -> output_string oc l; output_char oc '\n') body;
  output_string oc "</svg>\n";
  close_out oc

(* where each language's figures go, from the docs folder *)
let dir docs = function En -> Filename.concat docs "book/images" | Fr -> Filename.concat docs "fr/book/images"

(* a figure drawn in both languages: [draw l f] returns its width, height and title *)
let both docs name draw =
  List.iter
    (fun l ->
      let f = fig () in
      let w, h, title = draw l f in
      let d = dir docs l in
      if not (Sys.file_exists d) then Sys.mkdir d 0o755;
      save d name w h title f)
    [ En; Fr ]

(* a figure without words: drawn once, in the English folder, which the French pages share *)
let once docs name draw =
  let f = fig () in
  let w, h, title = draw f in
  save (dir docs En) name w h title f
