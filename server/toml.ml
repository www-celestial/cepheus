(* The part of TOML 1.0 that cluster.toml and tokens.toml use: comments, [table], [[array of tables]], bare or
   quoted keys, basic and literal strings, integers, booleans, arrays and inline tables. Anything else is an error
   that names its line: a configuration is never guessed. *)

type value = String of string | Int of int | Bool of bool | Array of value list | Table of (string * value) list

exception Error of int * string

let fail line fmt = Printf.ksprintf (fun m -> raise (Error (line, m))) fmt

type st = { s : string; mutable i : int; mutable line : int }

let peek st = if st.i < String.length st.s then Some st.s.[st.i] else None
let adv st = st.i <- st.i + 1

let rec skip_ws st =
  match peek st with
  | Some (' ' | '\t' | '\r') -> adv st; skip_ws st
  | _ -> ()

let skip_comment st =
  skip_ws st;
  if peek st = Some '#' then
    while match peek st with Some '\n' | None -> false | _ -> true do adv st done

(* whitespace, newlines and comments: inside arrays *)
let rec skip_all st =
  skip_comment st;
  match peek st with
  | Some '\n' -> adv st; st.line <- st.line + 1; skip_all st
  | _ -> ()

let bare c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c = '_' || c = '-'

let utf8 b u =
  if u < 0x80 then Buffer.add_char b (Char.chr u)
  else if u < 0x800 then (Buffer.add_char b (Char.chr (0xC0 lor (u lsr 6))); Buffer.add_char b (Char.chr (0x80 lor (u land 0x3F))))
  else if u < 0x10000 then begin
    Buffer.add_char b (Char.chr (0xE0 lor (u lsr 12)));
    Buffer.add_char b (Char.chr (0x80 lor ((u lsr 6) land 0x3F)));
    Buffer.add_char b (Char.chr (0x80 lor (u land 0x3F)))
  end
  else begin
    Buffer.add_char b (Char.chr (0xF0 lor (u lsr 18)));
    Buffer.add_char b (Char.chr (0x80 lor ((u lsr 12) land 0x3F)));
    Buffer.add_char b (Char.chr (0x80 lor ((u lsr 6) land 0x3F)));
    Buffer.add_char b (Char.chr (0x80 lor (u land 0x3F)))
  end

let string st =
  let q = Option.get (peek st) in
  adv st;
  let b = Buffer.create 32 in
  let rec go () =
    match peek st with
    | None | Some '\n' -> fail st.line "a string is not closed"
    | Some c when c = q -> adv st
    | Some '\\' when q = '"' ->
      adv st;
      (match peek st with
       | Some 'n' -> Buffer.add_char b '\n'
       | Some 't' -> Buffer.add_char b '\t'
       | Some 'r' -> Buffer.add_char b '\r'
       | Some '"' -> Buffer.add_char b '"'
       | Some '\\' -> Buffer.add_char b '\\'
       | Some ('u' | 'U' as k) ->
         let n = if k = 'u' then 4 else 8 in
         if st.i + n >= String.length st.s then fail st.line "a short \\%c escape" k;
         (match int_of_string_opt ("0x" ^ String.sub st.s (st.i + 1) n) with
          | Some u -> utf8 b u
          | None -> fail st.line "a bad \\%c escape" k);
         st.i <- st.i + n
       | _ -> fail st.line "an unknown escape in a string");
      adv st;
      go ()
    | Some c -> Buffer.add_char b c; adv st; go ()
  in
  go ();
  Buffer.contents b

let key st =
  skip_ws st;
  match peek st with
  | Some ('"' | '\'') -> string st
  | Some c when bare c ->
    let j = st.i in
    while match peek st with Some c -> bare c | None -> false do adv st done;
    String.sub st.s j (st.i - j)
  | _ -> fail st.line "a key was expected"

let rec value st =
  skip_ws st;
  match peek st with
  | Some ('"' | '\'') -> String (string st)
  | Some '[' ->
    adv st;
    let items = ref [] in
    let rec go () =
      skip_all st;
      match peek st with
      | Some ']' -> adv st
      | _ ->
        items := value st :: !items;
        skip_all st;
        (match peek st with
         | Some ',' -> adv st; go ()
         | Some ']' -> adv st
         | _ -> fail st.line "',' or ']' was expected in an array")
    in
    go ();
    Array (List.rev !items)
  | Some '{' ->
    adv st;
    let items = ref [] in
    skip_ws st;
    if peek st = Some '}' then adv st
    else begin
      let rec go () =
        let k = key st in
        skip_ws st;
        if peek st <> Some '=' then fail st.line "'=' was expected after %s" k;
        adv st;
        if List.mem_assoc k !items then fail st.line "%s is given twice" k;
        items := (k, value st) :: !items;
        skip_ws st;
        match peek st with
        | Some ',' -> adv st; go ()
        | Some '}' -> adv st
        | _ -> fail st.line "',' or '}' was expected in an inline table"
      in
      go ()
    end;
    Table (List.rev !items)
  | Some ('t' | 'f') ->
    let j = st.i in
    while match peek st with Some c -> bare c | None -> false do adv st done;
    (match String.sub st.s j (st.i - j) with
     | "true" -> Bool true
     | "false" -> Bool false
     | w -> fail st.line "unknown value %s" w)
  | Some c when (c >= '0' && c <= '9') || c = '-' || c = '+' ->
    let j = st.i in
    adv st;
    while match peek st with Some c -> bare c | None -> false do adv st done;
    let w = String.sub st.s j (st.i - j) in
    let digits = String.concat "" (String.split_on_char '_' w) in
    (match int_of_string_opt digits with
     | Some n when String.for_all (fun c -> (c >= '0' && c <= '9') || c = '-' || c = '+' || c = '_') w -> Int n
     | _ -> fail st.line "%s is not an integer (floats and dates are not used here)" w)
  | _ -> fail st.line "a value was expected"

(* tables in the order they appear; the document is the table "" *)
let parse s =
  let st = { s; i = 0; line = 1 } in
  let root = ref [] in
  (* the current table: a key path from the root, and whether it is the last element of an array of tables *)
  let set_in path k v =
    let rec put tbl = function
      | [] ->
        if List.mem_assoc k tbl then fail st.line "%s is given twice" k;
        tbl @ [ k, v ]
      | (name, last) :: rest -> (
        match List.assoc_opt name tbl with
        | Some (Table t) when not last -> List.map (fun (n, x) -> if n = name then n, Table (put t rest) else n, x) tbl
        | Some (Array items) when last -> (
          match List.rev items with
          | Table t :: before -> List.map (fun (n, x) -> if n = name then n, Array (List.rev (Table (put t rest) :: before)) else n, x) tbl
          | _ -> fail st.line "%s is not an array of tables" name)
        | _ -> fail st.line "no table %s" name)
    in
    root := put !root path
  in
  let path = ref [] in
  let rec lines () =
    skip_comment st;
    match peek st with
    | None -> ()
    | Some '\n' -> adv st; st.line <- st.line + 1; lines ()
    | Some '[' ->
      adv st;
      let arr = peek st = Some '[' in
      if arr then adv st;
      let name = key st in
      skip_ws st;
      if peek st <> Some ']' then fail st.line "']' was expected after [%s" name;
      adv st;
      if arr then (if peek st <> Some ']' then fail st.line "']]' was expected after [[%s" name; adv st);
      (match List.assoc_opt name !root with
       | None -> root := !root @ [ name, if arr then Array [ Table [] ] else Table [] ]
       | Some (Array items) when arr -> root := List.map (fun (n, x) -> if n = name then n, Array (items @ [ Table [] ]) else n, x) !root
       | Some _ -> fail st.line "[%s] is given twice" name);
      path := [ name, arr ];
      end_line ()
    | Some _ ->
      let k = key st in
      skip_ws st;
      if peek st <> Some '=' then fail st.line "'=' was expected after %s" k;
      adv st;
      let v = value st in
      set_in !path k v;
      end_line ()
  and end_line () =
    skip_comment st;
    (match peek st with
     | None -> ()
     | Some '\n' -> adv st; st.line <- st.line + 1
     | Some _ -> fail st.line "unexpected text after a value");
    lines ()
  in
  lines ();
  !root

let parse_file path =
  let s = In_channel.with_open_bin path In_channel.input_all in
  parse s

(* ---- reading a parsed document ---- *)

let quote s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (function
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | '\t' -> Buffer.add_string b "\\t"
      | c when Char.code c < 0x20 -> Buffer.add_string b (Printf.sprintf "\\u%04X" (Char.code c))
      | c -> Buffer.add_char b c)
    s;
  Buffer.add_char b '"';
  Buffer.contents b
