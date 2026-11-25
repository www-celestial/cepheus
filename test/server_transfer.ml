(* cepheus import and cepheus export against a real server (`cepheus serve`, its Unix socket, tokens):
   - the text forms: dates, money, floats, CSV fields and JSON strings read back as they were written, the UTF-8
     check against the standard library's, and random bytes never raising anything but Tabular.Bad;
   - the round trip: a database of the invoices app (clients, invoices, lines, users, sessions, a counter, its rule
     overdue) and a kind of every type (many values, floats with -0, NaN and infinities, money of 0 and 4 decimals),
     exported as CSV and as JSON lines, imported into two new databases (the CSV into one, the JSON lines into the
     other), exported again: the same bytes, and the same facts (the derived ones given again by the rule);
   - hostile files refused with their line and nothing written: a quote not closed (at the end, and in a file of
     10 MiB), a character after a closing quote, a quote inside a field, wrong types, 3 decimals for cents, NUL
     bytes, bytes that are not UTF-8, a record of 9 MiB, a wrong number of fields, a unique value twice in the file
     (in one round and in two, read again from the file) or taken in the database, an unknown column, a link to
     nothing, JSON's duplicate keys, objects, nesting 100 deep, a bad escape, a lone surrogate, \u0000; a 1 MB field
     is accepted and comes back whole;
   - a BOM, CR LF, line breaks inside quotes, blank lines, --map, --skip-bad, --upsert;
   - an import of several groups (small groups for the test), one refused by a rule's constraint midway: the lines
     written named, the rest not written; a token that may only read: nothing written; an export by a token of one
     kind, refused.

     server_transfer.exe DIR *)

open Cepheus
open Cepheus_server
module C = Check
module T = Tabular

let bin = Filename.concat (Filename.dirname (Filename.dirname Sys.executable_name)) "bin/main.exe"
let started = ref []

let () =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  at_exit (fun () ->
      List.iter (fun pid -> (try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ()); try ignore (Unix.waitpid [] pid) with Unix.Unix_error _ -> ()) !started)

let read f = In_channel.with_open_bin f In_channel.input_all
let write f s = Out_channel.with_open_bin f (fun oc -> output_string oc s)

let has s sub =
  let n = String.length s and m = String.length sub in
  let rec go i = i + m <= n && (String.sub s i m = sub || go (i + 1)) in
  go 0

let replace s a b =
  let la = String.length a and buf = Buffer.create (String.length s) and i = ref 0 in
  while !i < String.length s do
    if !i + la <= String.length s && String.sub s !i la = a then (Buffer.add_string buf b; i := !i + la) else (Buffer.add_char buf s.[!i]; incr i)
  done;
  Buffer.contents buf

let dir = ref ""

(* the command with these arguments: its exit code and its stderr; its stdout to [out] *)
let run ?(out = "/dev/null") args =
  let err = Filename.concat !dir "stderr" in
  let code = Sys.command (String.concat " " (List.map Filename.quote (bin :: args)) ^ " > " ^ Filename.quote out ^ " 2> " ^ Filename.quote err) in
  code, read err

(* ---- the text forms ---- *)

let forms () =
  let r = Rng.make 7 in
  let bad f = match f () with _ -> false | exception T.Bad _ -> true in
  (* dates: every millisecond form written reads back; the forms of RFC 3339 and PostgreSQL's *)
  for _ = 1 to 20_000 do
    let ms = Rng.int r (253_402_300_800_000 + 62_167_219_200_000) - 62_167_219_200_000 in
    C.check (T.date_of_text (T.date_text ms) = ms) "date %d: %s" ms (T.date_text ms)
  done;
  C.check (T.date_of_text "1970-01-01" = 0) "1970-01-01";
  C.check (T.date_of_text "2026-11-24 10:30:00+03" = T.date_of_text "2026-11-24T07:30:00Z") "a zone of hours";
  C.check (T.date_of_text "2026-11-24T10:30:00.123456+01:00" = T.date_of_text "2026-11-24T09:30:00.123Z") "microseconds cut";
  C.check (T.date_of_text "2024-02-29T00:00" = 1709164800000) "a leap day";
  C.check (T.date_text (-1) = "1969-12-31T23:59:59.999Z") "before 1970";
  List.iter (fun s -> C.check (bad (fun () -> T.date_of_text s)) "date %S refused" s)
    [ "2026-02-29"; "2026-13-01"; "2026-11-24T24:00:00Z"; "2026-11-24T10:61"; "2026-11-24T10:30:60Z"; "26-11-24"; "2026-11-24T10:30:00+0"; "2026-11-24x"; "" ];
  (* money: exact, at most its decimals *)
  for _ = 1 to 20_000 do
    let u = Rng.int r 2_000_000_000_000 - 1_000_000_000_000 and sc = Rng.int r 6 in
    C.check (T.money_of_text sc (T.money_text sc u) = u) "money %d scale %d: %s" u sc (T.money_text sc u)
  done;
  C.check (T.money_of_text 2 "12.5" = 1250 && T.money_of_text 2 "-0.05" = -5 && T.money_of_text 2 ".5" = 50 && T.money_of_text 0 "7" = 7) "money forms";
  C.check (T.money_of_text 2 "46116860184273879.03" = 4611686018427387903) "the largest amount";
  List.iter (fun s -> C.check (bad (fun () -> T.money_of_text 2 s)) "money %S refused" s) [ "12.505"; "1e3"; "12,50"; "-"; ""; "4611686018427387904"; "46116860184273879.04"; "1.2.3"; "$5" ];
  C.check (T.int_of_text "-4611686018427387904" = min_int && bad (fun () -> T.int_of_text "4611686018427387904")) "63 bits";
  (* floats: the shortest text that reads back, bit for bit *)
  for _ = 1 to 20_000 do
    let f = Int64.float_of_bits (Int64.logor (Int64.of_int (Rng.int r max_int)) (Int64.shift_left (Int64.of_int (Rng.int r 2)) 63)) in
    if not (Float.is_nan f) then C.check (Int64.equal (Int64.bits_of_float (T.float_of_text (T.float_text f))) (Int64.bits_of_float f)) "float %h: %s" f (T.float_text f)
  done;
  C.check (T.float_text 0.1 = "0.1" && T.float_text (-0.0) = "-0" && Float.is_nan (T.float_of_text "NaN")) "float forms";
  List.iter (fun s -> C.check (bad (fun () -> T.float_of_text s)) "float %S refused" s) [ "0x1p3"; "1_000"; "1e"; "."; "-"; "1.5f" ];
  (* UTF-8: as the standard library's, NUL aside *)
  for _ = 1 to 50_000 do
    let s = String.init (Rng.int r 8) (fun _ -> Char.chr (if Rng.bool r then Rng.int r 256 else 0x80 + Rng.int r 64)) in
    let mine = T.bad_utf8 s 0 (String.length s) = -1 in
    C.check (mine = (String.is_valid_utf_8 s && not (String.contains s '\000'))) "UTF-8 of %S" s
  done;
  (* a CSV field and a JSON string read back *)
  for _ = 1 to 20_000 do
    let pieces = [| "a"; " "; ","; "\""; "\n"; "\r"; "\t"; "z"; "\\"; "é"; "\001"; "名" |] in
    let s = String.concat "" (List.init (Rng.int r 12) (fun _ -> pieces.(Rng.int r (Array.length pieces)))) in
    let b = Buffer.create 16 in
    T.csv_add b s;
    Buffer.add_char b ',';
    T.csv_add b "x";
    let line = Buffer.to_bytes b in
    let fs = T.csv_fields line 0 (Bytes.length line) in
    C.check (Array.length fs = 2 && fs.(0).text = s && (s <> "" || fs.(0).quoted)) "CSV field %S" s;
    let b = Buffer.create 16 in
    Buffer.add_string b "{\"k\":";
    T.json_add b s;
    Buffer.add_char b '}';
    let line = Buffer.to_bytes b in
    C.check (T.json_object line 0 (Bytes.length line) = [ "k", T.Str s ]) "JSON string %S" s
  done;
  (* random bytes: Bad or a value, nothing else *)
  let alphabet = "{}[]\",:\\u0aeE.-+ntrufals\n\r\000\255 9" in
  for _ = 1 to 50_000 do
    let b = Bytes.init (Rng.int r 40) (fun _ -> alphabet.[Rng.int r (String.length alphabet)]) in
    (try ignore (T.csv_fields b 0 (Bytes.length b)) with T.Bad _ -> ());
    (try ignore (T.json_value b 0 (Bytes.length b)) with T.Bad _ -> ())
  done

(* ---- the reader's bounds and the import's failures, in this process (find and write given) ---- *)

let mprop ?(many = false) ?(unique = false) name typ = { Schema.name; typ; many; unique }
let mock_props = [ 16, mprop "client/Name" Value.Ttext; 17, mprop "client/Age" Value.Tint; 18, mprop ~many:true "client/Tags" Value.Tint ]

(* an import of [content] with [find] and [write]: its summary, or the reason it stopped *)
let mock ?(props = mock_props) ?(find = fun _ _ -> []) ?(wr = fun _ -> Ok 1) ?(skip_bad = true) content =
  let file = Filename.concat !dir "mock.csv" in
  write file content;
  let o = { Transfer.file; kind = "client"; format = T.Csv; maps = []; links = []; skip_bad; upsert = false; why = "test" } in
  let said = Buffer.create 256 in
  match Transfer.import ~props ~find ~write:wr ~say:(fun m -> Buffer.add_string said (m ^ "\n")) o with
  | s -> Ok s, Buffer.contents said
  | exception Transfer.Stop m -> Error m, Buffer.contents said
  | exception e -> Error ("escaped: " ^ Printexc.to_string e), Buffer.contents said

(* the heap's growth in MB while [f] runs: its peak above what the process held before *)
let peak_mb f =
  Gc.compact ();
  let before = (Gc.quick_stat ()).Gc.top_heap_words in
  let r = f () in
  r, ((Gc.quick_stat ()).Gc.top_heap_words - before) * 8 / 1_000_000

let short s = if String.length s > 300 then String.sub s 0 300 else s

let bounds () =
  (* blank lines: passed and dropped, never held: the buffer stays at its 2 MiB, before a record and after one *)
  List.iter
    (fun (what, blank) ->
      let f = Filename.concat !dir "blank.csv" in
      let b = Buffer.create (25 lsl 20) and k = ref 0 in
      Buffer.add_string b "first\n";
      while Buffer.length b < 24 lsl 20 do Buffer.add_string b blank; incr k done;
      Buffer.add_string b "last\n";
      write f (Buffer.contents b);
      let fd = Unix.openfile f [ Unix.O_RDONLY ] 0 in
      let r = T.reader T.Csv fd in
      let got = ref [] and fin = ref false in
      while not !fin do
        let bt = T.next r (1 lsl 20) in
        if Array.length bt.T.starts = 0 then fin := true
        else Array.iteri (fun j s -> got := (Bytes.sub_string bt.data s (bt.stops.(j) - s), bt.lines.(j)) :: !got) bt.starts
      done;
      Unix.close fd;
      C.check (List.rev !got = [ "first", 1; "last", 2 + !k ]) "24 MiB of %s: the two records and their lines" what;
      C.check (Bytes.length r.T.buf <= 4 lsl 20) "24 MiB of %s: the reader's buffer at %d bytes (2 MiB, doubled once at most)" what (Bytes.length r.T.buf))
    [ "LF", "\n"; "CR LF", "\r\n" ];
  (* a quote opens a quoted field at a field's start only (RFC 4180): elsewhere it opens nothing and the record ends
     at its line break; "" inside quotes, and a quote right after a closing one *)
  let f = Filename.concat !dir "quotes.csv" in
  write f "a,b\nbob\"x,2\ncarl,3\n\"q\"\"r\",4\n\"multi\nline\",5\n\"c\"x\"d,6\ndora,7\n\"\",\"\"\"\"\n";
  let fd = Unix.openfile f [ Unix.O_RDONLY ] 0 in
  let bt = T.next (T.reader T.Csv fd) (1 lsl 20) in
  Unix.close fd;
  let recs = Array.to_list (Array.mapi (fun j s -> Bytes.sub_string bt.T.data s (bt.T.stops.(j) - s), bt.T.lines.(j)) bt.T.starts) in
  C.check
    (recs = [ "a,b", 1; "bob\"x,2", 2; "carl,3", 3; "\"q\"\"r\",4", 4; "\"multi\nline\",5", 5; "\"c\"x\"d,6", 7; "dora,7", 8; "\"\",\"\"\"\"", 9 ])
    "records end at their line break when a quote is inside a field (%d records)" (List.length recs);
  let fields s = Array.to_list (Array.map (fun (x : T.field) -> x.text) (T.csv_fields (Bytes.of_string s) 0 (String.length s))) in
  let bad f = match f () with _ -> false | exception T.Bad _ -> true in
  C.check (fields "\"q\"\"r\",4" = [ "q\"r"; "4" ] && fields "\"\",\"\"\"\"" = [ ""; "\"" ]) "quoted fields";
  C.check (bad (fun () -> fields "bob\"x,2") && bad (fun () -> fields "\"c\"x\"d,6")) "a quote inside a field, a character after a closing quote: bad";
  (* --skip-bad: each line with a quote inside a field left out and named; the lines between them written *)
  let written = ref [] in
  let wr ops = written := ops @ !written; Ok 1 in
  (match mock ~wr "Name,Age\nann,1\nbob\"x,2\ncarl,3\ndora,4\neve\"y,5\nfred,6\n" with
   | Ok s, said ->
     let names = List.sort compare (List.filter_map (function Resolve.Add (_, 16, Value.Text t) -> Some t | _ -> None) !written) in
     C.check (s.rows = 4 && s.left_out = 2 && names = [ "ann"; "carl"; "dora"; "fred" ] && has said "line 3: a quote inside field 1" && has said "line 6: a quote inside field 1")
       "--skip-bad and stray quotes: 4 rows written (%s), 2 named: %s" (String.concat " " names) said
   | Error m, _ -> C.check false "--skip-bad and stray quotes: %s" m);
  (* a record that a quote at a field's start runs over several lines: its last line named *)
  (match mock "Name,Age\n\"open,1\nnext,2\n\"x,3\nlast,4\n" with
   | Ok s, said -> C.check (s.rows = 1 && s.left_out = 1 && has said "line 2: a character after the closing quote of field 1" && has said "runs to line 4") "a bad record over three lines: %s" said
   | Error m, _ -> C.check false "a bad record over three lines: %s" m);
  (* a record of 8 MiB of commas, a list of 8 MiB of values: refused, their fields and values never all made *)
  let n = (8 lsl 20) - 16 in
  let commas = "Name,Age\n" ^ String.make n ',' ^ "\n" in
  let (r, said), mb = peak_mb (fun () -> mock commas) in
  C.check ((match r with Ok s -> s.left_out = 1 | Error _ -> false) && has said (Printf.sprintf "line 2: %d fields, the header has 2" (n + 1)) && mb < 64)
    "a record of 8 MiB of commas: refused, its count named, %d MB at the peak: %s" mb (short said);
  let b = Buffer.create (8 lsl 20) in
  Buffer.add_string b "Name,Age,Tags\nx,1,\"[";
  while Buffer.length b < n do Buffer.add_string b "1," done;
  Buffer.add_string b "1]\"\n";
  let ones = Buffer.contents b in
  let (r, said), mb = peak_mb (fun () -> mock ones) in
  C.check ((match r with Ok s -> s.left_out = 1 | Error _ -> false) && has said "more than 100000 values in one record" && mb < 100)
    "a list of 4 M values: refused, %d MB at the peak: %s" mb (short said);
  (* a failure in the second pass that is no refusal (the connection lost): the groups written named *)
  let rows = String.concat "" ("Name,Age,Boss\n" :: List.init 5000 (fun i -> Printf.sprintf "n%d,%d,7\n" i i)) in
  let ops0 = !Transfer.group_ops and bb0 = !Transfer.batch_bytes in
  Transfer.group_ops := 1000;
  Transfer.batch_bytes := 4096;
  let props = [ 16, mprop "client/Name" Value.Ttext; 17, mprop "client/Age" Value.Tint; 18, mprop "client/Boss" Value.Tlink; 19, mprop ~unique:true "boss/Code" Value.Tint ] in
  let groups = ref 0 in
  let find _ vals = if !groups >= 2 then raise (Client.Broken "the server closed the connection") else List.map (fun v -> 70000, v) vals in
  let wr _ = incr groups; Ok !groups in
  (match mock ~props ~find ~wr ~skip_bad:false rows with
   | Error m, _ -> C.check (has m "the connection to the server: the server closed the connection" && has m "written before it: lines 2 to") "a connection lost in the second pass: %s" m
   | Ok _, _ -> C.check false "a connection lost in the second pass: written");
  (* a write whose answer is lost: its group may be in the database, never called refused *)
  let groups = ref 0 in
  let find _ vals = List.map (fun v -> 70000, v) vals in
  let wr _ = incr groups; if !groups = 3 then raise (Client.Broken "the server closed the connection") else Ok !groups in
  (match mock ~props ~find ~wr ~skip_bad:false rows with
   | Error m, _ -> C.check (has m "the answer to their group was lost" && has m "it may be in the database" && has m "in groups 1 to 2") "a lost answer: %s" m
   | Ok _, _ -> C.check false "a lost answer: written");
  Transfer.group_ops := ops0;
  Transfer.batch_bytes := bb0

(* ---- the database of the invoices app ---- *)

let prop ?(unique = false) ?(many = false) name typ = { Schema.name; typ; many; unique }

let kinds =
  Value.
    [ prop "client/Name" Ttext; prop "client/Search" Ttext; prop ~unique:true "client/Email" Ttext; prop "client/City" Ttext;
      prop "client/Overdue" Tbool;
      prop ~unique:true "invoice/Number" Tint; prop "invoice/Client" Tlink; prop "invoice/BillTo" Ttext; prop "invoice/Search" Ttext;
      prop "invoice/Date" Tdate; prop "invoice/Due" Tdate; prop "invoice/Status" Ttext; prop "invoice/Total" (Tmoney 2); prop "invoice/PaidAt" Tdate;
      prop "line/Invoice" Tlink; prop "line/Position" Tint; prop "line/Label" Ttext; prop "line/Quantity" Tint; prop "line/Price" (Tmoney 2);
      prop ~unique:true "user/Login" Ttext; prop "user/Hash" Ttext; prop "user/Role" Ttext;
      prop ~unique:true "session/Key" Ttext; prop "session/User" Tlink; prop "session/Expires" Tdate;
      prop ~unique:true "counter/Name" Ttext; prop "counter/Last" Tint;
      prop "note/Title" Ttext; prop ~many:true "note/Tags" Ttext; prop "note/Weight" Tfloat; prop "note/Ok" Tbool;
      prop ~many:true "note/Refs" Tlink; prop "note/Fee" (Tmoney 0); prop "note/Rate" (Tmoney 4); prop ~many:true "note/Days" Tdate ]

let ok what = function Ok x -> x | Error (e : Client.error) -> C.check false "%s: %s: %s" what e.code e.message; failwith what

(* the kinds declared, and the rule overdue (and, given [never], a constraint) defined *)
let setup c name ?(never = []) () =
  let db, ids = ok "declare" (Client.declare c name kinds) in
  let id n = List.assoc n (List.combine (List.map (fun (p : Schema.prop) -> p.name) kinds) ids) in
  let free = ref (List.fold_left max 0 ids + 1) in
  let rule (r : Rules.t) =
    let p = !free in
    incr free;
    [ Resolve.Expect (p, Schema.p_name, None); Add (p, Schema.p_name, Text r.name); Add (p, Schema.p_rule, Text (Rules.to_text r)) ]
  in
  let overdue =
    { Rules.name = "overdue"; vars = 2; ranges = [];
      where = [ { e = Var 1; p = id "invoice/Client"; v = Var 0 }; { e = Var 1; p = id "invoice/Status"; v = Val (Text "late") } ];
      head = Give { e = Var 0; p = id "client/Overdue"; v = Val (Bool true) } }
  in
  let nevers = List.map (fun st -> { Rules.name = "never-" ^ st; vars = 1; ranges = []; where = [ { e = Var 0; p = id "invoice/Status"; v = Val (Text st) } ]; head = Never }) never in
  ignore (ok "rules" (Client.write c db ~why:"rules" (List.concat_map rule (overdue :: nevers))));
  let db = ok "open" (Client.open_db c name) in
  db, id

let cities = [| "Lyon"; "Paris"; "Marseille"; "Nice, Côte d'Azur"; "Saint-\"Malo\"" |]
let names = [| "Ada Martin"; "Bo, \"the\" Builder"; "Chloé\nDubois"; " Leading"; "Trailing "; "名前 Ünïcödé"; ""; "=SUM(A1)"; "Ok\r\nCRLF"; "Tab\there" |]
let day = 86_400_000
let t0 = 1_764_000_000_123

let seed c db id =
  let r = Rng.make 11 in
  let w ops = (ok "seed" (Client.write c db ~why:"seed" ops)).Engine.things in
  let nclients = 300 and ninvoices = 1200 in
  let things = w (List.concat (List.init nclients (fun k ->
      let t = -1 - k in
      let name = names.(k mod Array.length names) ^ (if k >= Array.length names then string_of_int k else "") in
      [ Resolve.Add (t, id "client/Name", Text name); Add (t, id "client/Search", Text (String.lowercase_ascii name));
        Add (t, id "client/Email", Text (Printf.sprintf "client%d@example.com" k)) ]
      @ if k mod 7 = 3 then [] else [ Add (t, id "client/City", Text cities.(Rng.int r (Array.length cities))) ]))) in
  let client k = List.assoc (-1 - k) things in
  let inv = w (List.concat (List.init ninvoices (fun k ->
      let t = -1 - k and date = t0 - (Rng.int r 365 * day) - Rng.int r day in
      let st = [| "unpaid"; "late"; "paid" |].(Rng.int r 3) in
      [ Resolve.Add (t, id "invoice/Number", Int (k + 1)); Add (t, id "invoice/Client", Link (client (Rng.int r nclients)));
        Add (t, id "invoice/BillTo", Text names.(k mod Array.length names)); Add (t, id "invoice/Date", Date date);
        Add (t, id "invoice/Due", Date (date + (30 * day))); Add (t, id "invoice/Status", Text st);
        Add (t, id "invoice/Total", Money (Rng.int r 10_000_000 - 100_000)) ]
      @ if st = "paid" then [ Add (t, id "invoice/PaidAt", Date (date + (Rng.int r 40 * day))) ] else []))) in
  let invoice k = List.assoc (-1 - k) inv in
  let n = ref 0 in
  ignore (w (List.concat (List.init ninvoices (fun k ->
      List.concat (List.init (1 + Rng.int r 3) (fun j ->
          decr n;
          [ Resolve.Add (!n, id "line/Invoice", Link (invoice k)); Add (!n, id "line/Position", Int (j + 1));
            Add (!n, id "line/Label", Text [| "Design"; "Hosting, monthly"; "Support \"gold\"" |].(j));
            Add (!n, id "line/Quantity", Int (1 + Rng.int r 9)); Add (!n, id "line/Price", Money (Rng.int r 100_000)) ]))))));
  let users = w (List.concat (List.init 5 (fun k ->
      [ Resolve.Add (-1 - k, id "user/Login", Text (Printf.sprintf "user%d" k)); Add (-1 - k, id "user/Hash", Text "$argon2id$v=19$m=65536,t=3,p=4$c2FsdA$aGFzaA");
        Add (-1 - k, id "user/Role", Text (if k = 0 then "admin" else "accountant")) ]))) in
  ignore (w (List.concat (List.init 10 (fun k ->
      [ Resolve.Add (-1 - k, id "session/Key", Text (Printf.sprintf "%064x" (k * 977))); Add (-1 - k, id "session/User", Link (List.assoc (-1 - (k mod 5)) users));
        Add (-1 - k, id "session/Expires", Date (t0 + (k * 3_600_000))) ]))));
  ignore (w [ Add (-1, id "counter/Name", Text "invoice"); Add (-1, id "counter/Last", Int ninvoices) ]);
  let weights = [| 0.1; -0.0; 1e300; 5e-324; Float.nan; Float.infinity; Float.neg_infinity; 3.0; -2.5e-7 |] in
  ignore (w (List.concat (List.init 50 (fun k ->
      let t = -1 - k in
      [ Resolve.Add (t, id "note/Title", Text (Printf.sprintf "note %d" k)); Add (t, id "note/Weight", Float weights.(k mod Array.length weights));
        Add (t, id "note/Ok", Bool (k mod 2 = 0)); Add (t, id "note/Fee", Money (k * 1000 - 7)); Add (t, id "note/Rate", Money (k * 12345)) ]
      @ List.init (k mod 4) (fun j -> Resolve.Add (t, id "note/Tags", Text [| "red"; "a, b"; "say \"hi\""; "" |].(j)))
      @ List.init (k mod 3) (fun j -> Resolve.Add (t, id "note/Refs", Link (client (k + j))))
      @ List.init (k mod 2) (fun j -> Resolve.Add (t, id "note/Days", Date (t0 + (j * day))))))))

let order = [ "client"; "user"; "counter"; "invoice"; "line"; "session"; "note" ]
let links k = if k = "note" then [ "--link"; "Refs=client/Email" ] else []

(* the number of facts of each property, and of Overdue, read in the database *)
let census c db id =
  List.map
    (fun (p : Schema.prop) ->
      let q = { Query.vars = 2; where = [ { e = Var 0; p = id p.name; v = Var 1 } ]; ranges = [] } in
      p.name, List.length (snd (ok "census" (Client.find c db q))))
    kinds

(* ---- hostile files, and the options ---- *)

(* the last group of a database, read at the server *)
let group c name = (ok "open" (Client.open_db ~local:false c name)).Client.group

let hostile c cfg =
  let n = ref 0 in
  let path content = incr n; let p = Filename.concat !dir (Printf.sprintf "h%d.%s" !n (if String.length content > 0 && content.[0] = '{' then "jsonl" else "csv")) in write p content; p in
  let import ?(kind = "client") ?(args = []) content = run ([ "import"; "h"; path content; "--kind"; kind; "--config"; cfg ] @ args) in
  let accept ?kind ?args what content =
    let code, err = import ?kind ?args content in
    C.check (code = 0) "%s: accepted: %s" what err;
    err
  in
  let refuse ?kind ?args ?(nothing = true) what content phrase =
    let g0 = group c "h" in
    let code, err = import ?kind ?args content in
    C.check (code = 1 && has err phrase && ((not nothing) || has err "nothing was written") && group c "h" = g0) "%s: refused (%S): %s" what phrase err
  in
  ignore (accept "the clients" "Name,Email,City\nAda,ada@x.org,Lyon\nBo,bo@x.org,Paris\n");
  refuse "a quote not closed at the end" "Name,Email\nAda,a1@x\n\"Bo,b1@x\n" "line 3: a quoted field is not closed";
  refuse "a character after a closing quote" "Name,Email\n\"Ada\"x,a2@x\n" "line 2: a character after the closing quote";
  refuse "a quote inside a field" "Name,Email\nAd\"a,a3@x\n" "line 2: a quote inside field 1";
  refuse ~kind:"invoice" "an Int" "Number,Client\n12a,ada@x.org\n" "line 2: Number: \"12a\" is not a whole number";
  refuse ~kind:"invoice" "cents" "Number,Total\n5,12.505\n" "Total: 12.505 has more than 2 decimals";
  refuse ~kind:"invoice" "a day" "Number,Date\n7,2026-02-30\n" "2026-02-30 is not a day of the calendar";
  refuse "a NUL byte" "Name,Email\nA\000da,a6@x\n" "line 2: Name: a NUL byte";
  refuse "bytes not UTF-8" "Name,Email\nA\255da,a7@x\n" "Name: bytes that are not UTF-8";
  refuse "fields" "Name,Email\nA,a11@x,extra\n" "line 2: 3 fields, the header has 2";
  refuse "twice in the file" "Name,Email\nA,d@x\nB,d@x\n" "line 3: Email \"d@x\" is on line 2 too";
  refuse "taken" "Name,Email\nZ,ada@x.org\n" "Email \"ada@x.org\" is taken by #";
  refuse ~nothing:false ~args:[ "--link"; "Name=id" ] "--link on a text" "Name,Email\nA,l@x\n" "--link Name: client/Name is not a link (a text)";
  refuse ~nothing:false "an unknown column" "Name,Mail\nA,m@x\n" "\"Mail\" is no field of the kind";
  refuse ~kind:"invoice" "a link to nothing" "Number,Client\n9,nobody@x\n" "Client: no thing has client/Email \"nobody@x\"";
  refuse "JSON: a key twice" "{\"Name\":\"A\",\"Name\":\"B\"}\n" "line 1: Name twice";
  refuse "JSON: an object" "{\"Name\":{\"x\":1}}\n" "Name: a string, not an object";
  refuse "JSON: 100 deep" ("{\"Name\":" ^ String.make 100 '[' ^ "\n") "nested more than 64";
  refuse "JSON: an escape" "{\"Name\":\"\\q\"}\n" "a bad escape";
  refuse "JSON: a lone surrogate" "{\"Name\":\"\\ud800\"}\n" "a lone surrogate";
  refuse "JSON: \\u0000" "{\"Name\":\"\\u0000\"}\n" "a NUL character";
  refuse "JSON: after the object" "{\"Name\":\"A\"} x\n" "something after the value";
  refuse "JSON: not an object" "{\"Email\":\"j@x\"}\n[1]\n" "line 2: a line of JSON lines here holds an object";
  (* a field of 1 MB is a text like any other; a record of 9 MiB is refused, as a quote left open in 10 MiB *)
  let big = String.make 1_000_000 'x' in
  ignore (accept "a field of 1 MB" (Printf.sprintf "Name,Email\n%s,big@x\n" big));
  let out = Filename.concat !dir "h-client.jsonl" in
  ignore (run ~out [ "export"; "h"; "--kind"; "client"; "--config"; cfg ]);
  C.check (has (read out) big) "a field of 1 MB comes back whole";
  refuse "a record of 9 MiB" (Printf.sprintf "Name,Email\n%s,huge@x\n" (String.make (9 lsl 20) 'y')) "line 2: a record of more than 8 MiB";
  let lots = Buffer.create (11 lsl 20) in
  Buffer.add_string lots "Name,Email\nA,a10@x\n\"B,b10@x\n";
  for i = 1 to 900_000 do Buffer.add_string lots (Printf.sprintf "C,c%d@x\n" i) done;
  refuse "a quote left open in 10 MiB" (Buffer.contents lots) "line 3: a record of more than 8 MiB (a quote left open?)";
  (* a quote inside a field makes its line bad, and no other: --skip-bad writes the lines around it *)
  let err = accept ~args:[ "--skip-bad" ] "stray quotes, --skip-bad" "Name,Email\nann,q1@x\nbob\"x,q2@x\ncarl,q3@x\ndora,q4@x\neve\"y,q5@x\nfred,q6@x\n" in
  C.check (has err "line 3: a quote inside field 1" && has err "line 6: a quote inside field 1" && has err "4 rows" && has err "2 bad rows left out") "stray quotes: %s" err;
  ignore (run ~out [ "export"; "h"; "--kind"; "client"; "--config"; cfg ]);
  let o = read out in
  C.check (has o "\"q3@x\"" && has o "\"q4@x\"" && not (has o "q2@x") && not (has o "q5@x")) "stray quotes: the lines between them written";
  refuse "a quote inside a field, without --skip-bad" "Name,Email\nbob\"x,z1@x\nok,z2@x\n" "line 2: a quote inside field 1";
  (* a record that a quote at a field's start runs over lines: named to its last line *)
  refuse "a record over three lines" "Name,Email\n\"open,r1@x\nnext,r2@x\n\"x,r3@x\n" "(the record runs to line 4: a quote at a field's start opens a field to the next quote";
  (* 20 MiB of blank lines between two rows: read through, never held *)
  let blank = Buffer.create (21 lsl 20) in
  Buffer.add_string blank "Name,Email\nb1,b1@x\n";
  Buffer.add_string blank (String.make (20 lsl 20) '\n');
  Buffer.add_string blank "b2,b2@x\n";
  let err = accept "20 MiB of blank lines" (Buffer.contents blank) in
  C.check (has err "2 rows") "20 MiB of blank lines: 2 rows: %s" err;
  (* a record of 8 MiB of commas: its count named, its fields never made; a list of more than 100,000 values; a
     header of more than 100,000 columns *)
  refuse "a record of 8 MiB of commas" ("Name,Email\n" ^ String.make ((8 lsl 20) - 16) ',' ^ "\n") (Printf.sprintf "line 2: %d fields, the header has 2" ((8 lsl 20) - 15));
  refuse ~kind:"note" ~args:[ "--link"; "Refs=id" ] "a list of 100,001 values"
    ("{\"Title\":\"t\",\"Tags\":[" ^ String.concat "," (List.init 100_001 (fun _ -> "\"a\"")) ^ "]}\n") "line 1: more than 100000 values in one record";
  refuse ~nothing:false ~args:[ "--map"; "X=" ] "a header of 100,001 columns" (String.concat "," (List.init 100_001 (fun _ -> "X")) ^ "\n") "the header: more than 100000 columns";
  (* a duplicate far from the first: read again from the file *)
  let lots = Buffer.create (11 lsl 20) in
  Buffer.add_string lots "Name,Email\n";
  for i = 1 to 500_000 do Buffer.add_string lots (Printf.sprintf "C,far%d@x\n" i) done;
  Buffer.add_string lots "D,far1@x\n";
  refuse "twice, far apart" (Buffer.contents lots) "line 500002: Email \"far1@x\" is on line 2 too";
  (* a BOM, CR LF, a line break inside quotes, blank lines: lines counted as an editor does *)
  let crlf = "\xEF\xBB\xBFName,Email,City\r\n\"Multi\r\nline\",m1@x,Lyon\r\n\r\nGood,m2@x,\r\n" in
  refuse "a line counted" (crlf ^ "Bad,m3@x,\"x\"y\r\n") "line 6: a character after the closing quote";
  ignore (accept "a BOM, CR LF, a line break in quotes" crlf);
  ignore (run ~out [ "export"; "h"; "--kind"; "client"; "--config"; cfg ]);
  let o = read out in
  C.check (has o "{\"Name\":\"Multi\\r\\nline\",\"Email\":\"m1@x\",\"City\":\"Lyon\"}" && has o "{\"Name\":\"Good\",\"Email\":\"m2@x\"}") "what the CSV held: %s" "";
  ignore (accept ~args:[ "--map"; "Nom=Name"; "--map"; "Courriel=Email"; "--map"; "Autre=" ] "--map" "Nom,Courriel,Autre\nX,map@x,zzz\n");
  ignore (accept "a header in small letters" "name,email\nlow,low@x\n");
  (* --skip-bad: the good rows written, the bad ones listed *)
  let err = accept ~args:[ "--skip-bad" ] "--skip-bad" "Name,Email\nS1,s1@x\nS2,ada@x.org\nS3,s3@x\nS4,s\0004@x\n" in
  C.check (has err "line 3: Email \"ada@x.org\" is taken" && has err "line 5: Email: a NUL byte" && has err "2 bad rows left out") "--skip-bad lists: %s" err;
  (* --upsert: a thing found by its unique value takes the row's values *)
  let err = accept ~args:[ "--upsert" ] "--upsert" "Email,City\nada@x.org,Nice\nnew@x,Brest\n" in
  C.check (has err "1 new things, 1 changed") "--upsert: %s" err;
  ignore (run ~out [ "export"; "h"; "--kind"; "client"; "--config"; cfg ]);
  let o = read out in
  C.check (has o "{\"Name\":\"Ada\",\"Email\":\"ada@x.org\",\"City\":\"Nice\"}" && has o "{\"Email\":\"new@x\",\"City\":\"Brest\"}" && not (has o "S2")) "after --skip-bad and --upsert: %s" "";
  refuse ~kind:"note" ~nothing:false ~args:[ "--upsert"; "--link"; "Refs=id" ] "--upsert without a unique field" "Title\nx\n" "--upsert finds a thing by a unique field, and note has none"

(* ---- several groups, in this process: small groups and batches ---- *)

let groups c sock tok =
  Transfer.group_ops := 1000;
  Transfer.batch_bytes := 4096;
  let u, _ = setup c "u" ~never:[ "void" ] () in
  ignore u;
  let conn () = ok "connect" (Result.map_error (fun m -> { Client.code = "connect"; message = m }) (Client.connect (Client.Unix_socket sock) tok)) in
  let r = conn () and w = conn () in
  let rdb = ok "open" (Client.open_db r "u") and wdb = ok "open" (Client.open_db ~local:false w "u") in
  let said = Buffer.create 256 in
  let import ?(upsert = false) kind content =
    let file = Filename.concat !dir (kind ^ "-u.csv") in
    write file content;
    let o = { Transfer.file; kind; format = T.Csv; maps = []; links = []; skip_bad = false; upsert; why = "test" } in
    match Transfer.import_client ~say:(fun m -> Buffer.add_string said (m ^ "\n")) (r, rdb) (w, wdb) o with
    | s -> Ok s
    | exception Transfer.Stop m -> Error m
  in
  let csv header n row = String.concat "" (header :: List.init n row) in
  (match import "client" (csv "Name,Email\n" 100 (fun i -> Printf.sprintf "C%d,c%d@u\n" i i)) with
   | Ok s -> C.check (s.rows = 100 && List.length s.groups = 1) "100 clients in one group (%d)" (List.length s.groups)
   | Error m -> C.check false "clients: %s" m);
  let invoices f = csv "Number,Client,Status,Total\n" 3000 (fun i -> f i (Printf.sprintf "%d,c%d@u,%s,%d.%02d\n" (i + 1) (i mod 100) (if i mod 3 = 0 then "late" else "paid") i (i mod 100))) in
  let g0 = group c "u" in
  (match import "invoice" (invoices (fun i l -> if i = 2899 then "1,c1@u,paid,1.00\n" else l)) with
   | Error m -> C.check (has m "line 2901: Number 1 is on line 2 too; nothing was written" && group c "u" = g0) "a duplicate far apart, by small batches: %s" m
   | Ok _ -> C.check false "a duplicate far apart, by small batches: written");
  (match import "invoice" (invoices (fun i l -> if i = 2499 then "2500,c1@u,void,1.00\n" else l)) with
   | Error m ->
     let n = List.length (snd (ok "find" (Client.find c (ok "open" (Client.open_db c "u")) { Query.vars = 2; where = [ { e = Var 0; p = Option.get (Client.prop rdb "invoice/Number"); v = Var 1 } ]; ranges = [] }))) in
     C.check (has m "lines 2252 to 2501: the database refused their group: invalid: constraint never-void" && has m "written before it: lines 2 to 2251, in groups" && n = 2250) "refused midway (%d written): %s" n m
   | Ok _ -> C.check false "refused midway: written");
  (match import "invoice" (invoices (fun i l -> if i < 2250 then "" else l)) with
   | Ok s -> C.check (s.rows = 750 && List.length s.groups = 3) "the rest, after (%d rows, %d groups)" s.rows (List.length s.groups)
   | Error m -> C.check false "the rest: %s" m);
  (match import ~upsert:true "invoice" (invoices (fun _ l -> l)) with
   | Ok s -> C.check (s.updated = 3000 && s.inserted = 0 && List.length s.groups = 12) "--upsert of 3000 in 12 groups (%d changed)" s.updated
   | Error m -> C.check false "--upsert: %s" m);
  Transfer.group_ops := 500_000;
  Transfer.batch_bytes := 1 lsl 20;
  Client.close r;
  Client.close w

(* ---- the server ---- *)

let start cfg sock =
  let log = Unix.openfile (Filename.concat (Filename.dirname cfg) "serve.log") [ O_WRONLY; O_CREAT; O_APPEND; O_CLOEXEC ] 0o644 in
  let null = Unix.openfile "/dev/null" [ O_RDONLY; O_CLOEXEC ] 0 in
  let pid = Unix.create_process "setsid" [| "setsid"; bin; "serve"; "--config"; cfg |] null log log in
  Unix.close log;
  Unix.close null;
  started := pid :: !started;
  let t = Unix.gettimeofday () in
  while not (Sys.file_exists sock) && Unix.gettimeofday () -. t < 30. do Thread.delay 0.01 done

let token cfg name rights =
  let out = Filename.concat !dir (name ^ ".token") in
  let code, err = run ~out ([ "token"; "add"; name ] @ List.concat_map (fun r -> [ "--database"; r ]) rights @ [ "--config"; cfg ]) in
  C.check (code = 0) "token add %s: %s" name err;
  String.trim (read out)


let () =
  dir := (match Sys.argv with [| _; d |] -> d | _ -> prerr_endline "server_transfer.exe DIR"; exit 2);
  C.rmrf !dir;
  Unix.mkdir !dir 0o700;
  forms ();
  bounds ();
  let s = Filename.concat !dir "s" in
  C.check (fst (run [ "cluster"; "init"; "transfer"; "--dir"; s ]) = 0) "cluster init";
  let cfg = Filename.concat s "cluster.toml" in
  let port = 20000 + ((Unix.getpid () + 11) mod 20000) in
  let dbs = [ "a"; "b"; "c"; "h"; "u" ] in
  write cfg
    (replace (replace (read cfg) "127.0.0.1:7400" (Printf.sprintf "127.0.0.1:%d" port)) "[[database]]\nname = \"main\"\n"
       (String.concat "" (List.map (Printf.sprintf "[[database]]\nname = \"%s\"\n") dbs)));
  let app = token cfg "app" (List.map (fun d -> d ^ "=write") dbs) in
  let reader = token cfg "reader" [ "a=read"; "h=read" ] in
  let one = token cfg "one" [ "a=read:client" ] in
  let sock = Filename.concat s (Printf.sprintf "run/.s.cepheus.%d" port) in
  C.check (String.length sock < 107) "the socket's path holds %d bytes" (String.length sock);
  start cfg sock;
  Unix.putenv "CEPHEUS_TOKEN" app;
  let c = ok "connect" (Result.map_error (fun m -> { Client.code = "connect"; message = m }) (Client.connect (Client.Unix_socket sock) app)) in
  (* the round trip *)
  let a, id = setup c "a" () in
  seed c a id;
  let file d k f = Filename.concat !dir (Printf.sprintf "%s-%s.%s" d k f) in
  let export d k f =
    let code, err = run ~out:(file d k f) ([ "export"; d; "--kind"; k; "--format"; f; "--config"; cfg ] @ links k) in
    C.check (code = 0 && has err (Printf.sprintf "%s at group" d)) "export %s %s %s: %s" d k f err
  in
  List.iter (fun k -> export "a" k "csv"; export "a" k "jsonl") order;
  C.check (not (has (read (file "a" "client" "jsonl")) "\"Overdue\"")) "derived facts are not exported";
  let b, _ = setup c "b" () and cdb, _ = setup c "c" () in
  List.iter
    (fun (d, f) ->
      List.iter
        (fun k ->
          let code, err = run ([ "import"; d; file "a" k f; "--kind"; k; "--config"; cfg ] @ links k) in
          C.check (code = 0 && has err "rows") "import %s %s %s: %s" d k f err)
        order)
    [ "b", "csv"; "c", "jsonl" ];
  List.iter
    (fun d ->
      List.iter
        (fun k ->
          export d k "csv";
          export d k "jsonl";
          List.iter (fun f -> C.check (read (file d k f) = read (file "a" k f)) "round trip %s %s %s: the same bytes" d k f) [ "csv"; "jsonl" ])
        order)
    [ "b"; "c" ];
  let ca = census c a id in
  C.check (List.assoc "client/Overdue" ca > 0) "some clients are overdue";
  List.iter (fun d -> C.check (census c d id = ca) "round trip %s: the same facts, the derived ones included" (if d == b then "b" else "c")) [ b; cdb ];
  (* exports: a token of one kind is not followed, and says so; a token that reads may export *)
  Unix.putenv "CEPHEUS_TOKEN" one;
  let code, err = run [ "export"; "a"; "--kind"; "client"; "--config"; cfg ] in
  C.check (code = 1 && has err "reads the whole database") "export by a token of one kind: %s" err;
  Unix.putenv "CEPHEUS_TOKEN" reader;
  let code, err = run ~out:(file "r" "client" "jsonl") [ "export"; "a"; "--kind"; "client"; "--config"; cfg ] in
  C.check (code = 0 && read (file "r" "client" "jsonl") = read (file "a" "client" "jsonl")) "export by a token that reads: %s" err;
  (* a token that only reads: nothing written *)
  let h, _ = setup c "h" () in
  ignore h;
  let g0 = group c "h" in
  let code, err = run [ "import"; "h"; file "a" "client" "csv"; "--kind"; "client"; "--config"; cfg ] in
  C.check (code = 1 && has err "nothing was written" && group c "h" = g0) "import by a token that reads: %s" err;
  Unix.putenv "CEPHEUS_TOKEN" app;
  hostile c cfg;
  groups c sock app;
  Client.close c;
  C.finish "server_transfer"
