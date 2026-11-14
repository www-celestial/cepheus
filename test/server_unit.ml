(* Unit and property tests of the server's parts: TOML, cluster.toml's rules, tokens, the wire codings (every request
   and reply, round trips of random values), the origin of a group, the session table and its checkpoint, the
   rights of every token against every request (G16), through the server's core, and what local readers need from
   the system: descriptors passed over a socket (random messages and descriptors, read in random pieces) and the
   visibility page shared read-only. *)

open Cepheus
module Ask = Question.Ask
module Top = Question.Top
open Cepheus_server
module C = Check

let check = C.check

(* ---- TOML ---- *)

let toml () =
  let d =
    Toml.parse
      "# a comment\n[cluster]\nname = \"shop\" # after\nid = 'cph-c-0123456789abcdef'\n[[peer]]\nname = \"a\"\n\
       [[peer]]\nname = \"b\"\nn = 1_000\nok = true\narr = [1, 2,\n 3]\nt = { x = \"y\", z = 2 }\ns = \"a\\\"b\\u00e9\"\n"
  in
  check (List.assoc_opt "cluster" d = Some (Toml.Table [ "name", Toml.String "shop"; "id", Toml.String "cph-c-0123456789abcdef" ])) "toml: a table";
  (match List.assoc_opt "peer" d with
   | Some (Toml.Array [ Toml.Table a; Toml.Table b ]) ->
     check (List.assoc "name" a = Toml.String "a") "toml: first of an array of tables";
     check (List.assoc "n" b = Toml.Int 1000) "toml: an integer with _";
     check (List.assoc "ok" b = Toml.Bool true) "toml: a boolean";
     check (List.assoc "arr" b = Toml.Array [ Toml.Int 1; Toml.Int 2; Toml.Int 3 ]) "toml: an array over lines";
     check (List.assoc "t" b = Toml.Table [ "x", Toml.String "y"; "z", Toml.Int 2 ]) "toml: an inline table";
     check (List.assoc "s" b = Toml.String "a\"b\xc3\xa9") "toml: escapes"
   | _ -> check false "toml: an array of tables");
  List.iter
    (fun (src, what) -> check (match Toml.parse src with _ -> false | exception Toml.Error _ -> true) "toml refuses %s" what)
    [ "a = ", "a missing value"; "a = 1\na = 2", "a key twice"; "[t]\n[t]", "a table twice"; "a = \"x", "an open string";
      "a = 1.5", "a float"; "a = 1 b", "text after a value"; "a = nope", "an unknown word" ];
  check (match Toml.parse ("k = " ^ Toml.quote "q\"\\\n\t\001") with [ "k", Toml.String s ] -> s = "q\"\\\n\t\001" | _ -> false) "toml: quote round trip"

(* ---- cluster.toml ---- *)

let base =
  "[cluster]\nname = \"shop\"\nid = \"cph-c-0123456789abcdef\"\nme = \"srv1\"\n[[peer]]\nname = \"srv1\"\naddress = \"127.0.0.1:7401\"\n\
   [clients]\nsocket = \"run\"\n[storage]\ndata = \"data\"\ncache = \"64M\"\n[[database]]\nname = \"shop\"\n"

let config () =
  (match Config.of_toml "/etc/cepheus/cluster.toml" (Toml.parse base) with
   | c ->
     check (c.data = "/etc/cepheus/data" && c.socket = Some "/etc/cepheus/run") "config: paths beside the file";
     check (c.cache = 64 lsl 20 && c.port = 7400 && c.databases = [ "shop" ]) "config: values";
     check (Config.socket_path c = Some "/etc/cepheus/run/.s.cepheus.7400") "config: the socket's name";
     check (Config.tokens_path c = "/etc/cepheus/tokens.toml") "config: tokens beside";
     check (c.max_connections = 512 && c.idle_timeout = 600) "config: the limits' defaults"
   | exception Config.Bad m -> check false "config: %s" m);
  let refused edit what =
    let src = edit base in
    check (match Config.of_toml "/x/cluster.toml" (Toml.parse src) with _ -> false | exception Config.Bad _ -> true) "config refuses %s" what
  in
  let repl a b s =
    let rec find i = if i + String.length a > String.length s then failwith a else if String.sub s i (String.length a) = a then i else find (i + 1) in
    let i = find 0 in
    String.sub s 0 i ^ b ^ String.sub s (i + String.length a) (String.length s - i - String.length a)
  in
  refused (repl "me = \"srv1\"" "me = \"srv2\"") "me naming no peer";
  refused (repl "cph-c-0123456789abcdef" "cph-c-xyz") "a bad id";
  refused (repl "socket = \"run\"" "socket = \"run\"\nlisten = \"127.0.0.1:7400\"") "TCP without [tls], even on loopback";
  (match Config.of_toml "/x/cluster.toml" (Toml.parse (repl "[storage]" "listen = \"127.0.0.1:7401\"\n[tls]\nca = \"ca.pem\"\ncert = \"s.pem\"\nkey = \"s.key\"\n[storage]" base)) with
   | c -> check (c.port = 7401 && c.tls = Some { Config.ca = "/x/ca.pem"; cert = "/x/s.pem"; key = "/x/s.key" }) "config: TCP with TLS, and the socket named by its port"
   | exception Config.Bad m -> check false "config with tls: %s" m);
  refused (repl "[[database]]\nname = \"shop\"\n" "") "no database";
  refused (repl "me = \"srv1\"\n[[peer]]" "me = \"srv1\"\nextra = 1\n[[peer]]") "an unknown key";
  refused (fun s -> s ^ "[[peer]]\nname = \"srv2\"\naddress = \"10.0.0.2:7401\"\n") "two peers (no replication yet)";
  refused (fun s -> s ^ "[[database]]\nname = \"shop\"\n") "a database twice";
  refused (repl "cache = \"64M\"" "cache = \"lots\"") "a bad size";
  (match Config.of_toml "/x/cluster.toml" (Toml.parse (repl "socket = \"run\"" "socket = \"run\"\nmax_connections = 3\nidle_timeout = 0" base)) with
   | c -> check (c.max_connections = 3 && c.idle_timeout = 0) "config: max_connections, idle_timeout 0 (no limit)"
   | exception Config.Bad m -> check false "config with limits: %s" m);
  refused (repl "socket = \"run\"" "socket = \"run\"\nmax_connections = 0") "max_connections 0";
  refused (repl "socket = \"run\"" "socket = \"run\"\nmax_connections = \"many\"") "max_connections as a string";
  refused (repl "socket = \"run\"" "socket = \"run\"\nidle_timeout = -1") "a negative idle_timeout";
  refused (repl "socket = \"run\"" "socket = \"run\"\nidle_timeout = 604801") "an idle_timeout over a week";
  refused (repl "name = \"shop\"\n" "name = \"Shop!\"\n" |> fun f s -> let s = f s in repl "[[database]]\nname = \"shop\"" "[[database]]\nname = \"Shop!\"" s) "a bad database name"

(* ---- tokens ---- *)

let tokens () =
  check (Tokens.base64url "" = "" && Tokens.base64url "f" = "Zg" && Tokens.base64url "fo" = "Zm8" && Tokens.base64url "foo" = "Zm9v"
         && Tokens.base64url "\xfb\xff" = "-_8") "tokens: base64url (RFC 4648 vectors)";
  let text, hash = Tokens.generate () in
  check (String.length text = 4 + 43 && String.sub text 0 4 = "cph_") "tokens: cph_ and 43 characters";
  let t = Tokens.with_tokens Tokens.empty [ { name = "web"; hash; databases = [ "shop", Tokens.Write; "stock", Tokens.Read ]; admin = false } ] in
  check (Tokens.check t text <> None) "tokens: the token is known";
  check (Tokens.check t (text ^ "x") = None && Tokens.check t "" = None) "tokens: another is not";
  let back = Tokens.of_toml (Toml.parse (Tokens.to_toml t)) in
  check (back.tokens = t.tokens) "tokens: tokens.toml round trip";
  check (Tokens.equal_ct "abc" "abc" && not (Tokens.equal_ct "abc" "abd") && not (Tokens.equal_ct "abc" "ab")) "tokens: compare";
  let text2, _ = Tokens.generate () in
  check (text2 <> text) "tokens: two differ"

(* ---- the wire ---- *)

let rand_value r =
  match Rng.int r 7 with
  | 0 -> Value.Int (Rng.int r 1000 - 500)
  | 1 -> Float (float_of_int (Rng.int r 1000) /. 7.)
  | 2 -> Bool (Rng.bool r)
  | 3 -> Text (String.init (Rng.int r 20) (fun _ -> Char.chr (Rng.int r 256)))
  | 4 -> Date (Rng.int r 1_000_000_000)
  | 5 -> Money (Rng.int r 100000 - 50000)
  | _ -> Link (Rng.int r 100000)

let rand_term r = match Rng.int r 3 with 0 -> Query.Var (Rng.int r 4) | 1 -> Query.Thing (Rng.int r 70000) | _ -> Query.Val (rand_value r)

let rand_request r =
  match Rng.int r 8 with
  | 0 -> Wire.Hello { version = Rng.int r 3; token = "cph_" ^ string_of_int (Rng.int r 1000); program = "p"; session = Rng.int r 1_000_000 }
  | 1 -> Wire.Open "shop"
  | 2 -> Wire.Get { db = Rng.int r 4; thing = Rng.int r 1_000_000 }
  | 3 ->
    let q = { Query.vars = 1 + Rng.int r 3; where = List.init (Rng.int r 4) (fun _ -> { Query.e = rand_term r; p = Rng.int r 40; v = rand_term r });
              ranges = List.init (Rng.int r 2) (fun _ -> Rng.int r 3, rand_value r, rand_value r) } in
    let select = if Rng.bool r then Wire.Give (Array.init (Rng.int r 3) (fun _ -> Rng.int r 3))
      else Wire.Group ([| Rng.int r 3 |], [| Wire.Count; Wire.Sum 1; Wire.Min 0; Wire.Max 2 |]) in
    let order =
      if Rng.bool r then Top.none
      else { Top.keys = List.init (Rng.int r 3) (fun _ -> { Top.col = Rng.int r 3; desc = Rng.bool r }); limit = Rng.int r 5;
             after = (if Rng.bool r then None else Some (Array.init (Rng.int r 3) (fun _ -> rand_value r))) } in
    Wire.Find { db = 0; query = q; select; extra = []; order }
  | 4 ->
    let op () = match Rng.int r 6 with
      | 0 -> Resolve.Add (Rng.int r 100 - 50, Rng.int r 40, rand_value r)
      | 1 -> Resolve.Retract (Rng.int r 100, Rng.int r 40, rand_value r)
      | 2 -> Resolve.Expect (Rng.int r 100, Rng.int r 40, Some (rand_value r))
      | 3 -> Resolve.Expect (Rng.int r 100, Rng.int r 40, None)
      | 4 -> Resolve.Incr (Rng.int r 100 - 50, Rng.int r 40, (if Rng.bool r then max_int - Rng.int r 3 else min_int + Rng.int r 3), None)
      | _ -> Resolve.Incr (Rng.int r 100 - 50, Rng.int r 40, Rng.int r 21 - 10, Some (Rng.int r 100 - 50, Rng.int r 40)) in
    Wire.Write { db = 0; serial = Rng.int r 100; floor = Rng.int r 100; by = Rng.int r 10 - 5; why = "why"; ops = List.init (Rng.int r 5) (fun _ -> op ()) }
  | 5 -> Wire.Ping (String.make (Rng.int r 30) 'p')
  | 6 -> Wire.Follow (Rng.int r 300)
  | _ -> Wire.Admin "status"

let wire () =
  let r = Rng.make 11 in
  let ok = ref true in
  for _ = 1 to 5000 do
    let q = rand_request r in
    let b = Buffer.create 64 in
    Wire.put_request b q;
    let bytes = Buffer.to_bytes b in
    let back = Wire.get_request (Wire.request_kind q) (Codec.reader bytes 0 (Bytes.length bytes)) in
    (* floats compare by bits (Value.equal); a structural compare is enough for these *)
    if back <> q then ok := false;
    (* every cut of the body is refused, never read past its end *)
    let n = Bytes.length bytes in
    (* a Ping's body is its bytes to the end: any cut of it is a shorter Ping *)
    if n > 0 && (match q with Wire.Ping _ -> false | _ -> true) then begin
      let k = Rng.int r n in
      match Wire.get_request (Wire.request_kind q) (Codec.reader bytes 0 k) with
      (* a Find cut where its Sort, Limit and After begin is the same question without them: the section is optional,
         so that a server that does not know it reads every other question as before (a frame's length tells where
         its body ends: no connection cuts one) *)
      | Wire.Find f' when (match q with Wire.Find f -> f.order <> Top.none && f'.order = Top.none && f'.query = f.query && f'.select = f.select | _ -> false) -> ()
      | _ -> ok := false
      | exception (Codec.Short | Wire.Malformed _) -> ()
    end
  done;
  check !ok "wire: 5,000 random requests round trip, every cut refused";
  (* the question's extension fuzzed: random operators, Sort, Limit and After round trip; every byte flipped, every
     cut, bytes inserted, huge counts: the request is read, or refused (Short, Malformed), never anything else; a
     question without them is coded byte for byte as before them *)
  let r = Rng.make 13 in
  let rec item depth =
    match Rng.int r (if depth > 1 then 3 else 5) with
    | 0 -> Ask.Pattern { Query.e = rand_term r; p = Rng.int r 40; v = rand_term r }
    | 1 -> Range (Rng.int r 4, rand_value r, rand_value r)
    | 2 -> In (Rng.int r 4, List.init (Rng.int r 4) (fun _ -> rand_value r))
    | 3 -> Not (List.init (1 + Rng.int r 3) (fun _ -> item (depth + 1)))
    | _ -> Or (List.init (2 + Rng.int r 2) (fun _ -> List.init (1 + Rng.int r 2) (fun _ -> item (depth + 1))))
  in
  let fine = ref true and outcomes = ref 0 in
  for _ = 1 to 3000 do
    let q = { Query.vars = 1 + Rng.int r 3; where = List.init (Rng.int r 3) (fun _ -> { Query.e = rand_term r; p = Rng.int r 40; v = rand_term r }); ranges = [] } in
    let extra = List.init (Rng.int r 3) (fun _ -> item 0) in
    let order = if Rng.bool r then Top.none else { Top.keys = [ { col = Rng.int r 3; desc = Rng.bool r } ]; limit = Rng.int r 9; after = if Rng.bool r then Some [| rand_value r |] else None } in
    let req = Wire.Find { db = 0; query = q; select = Wire.Give [| 0 |]; extra; order } in
    let b = Buffer.create 64 in
    Wire.put_request b req;
    let bytes = Buffer.to_bytes b in
    (match Wire.get_request Wire.k_find (Codec.reader bytes 0 (Bytes.length bytes)) with
     | back -> if back <> req then fine := false
     | exception _ -> fine := false);
    if extra = [] && order = Top.none then begin
      let old = Buffer.create 64 in
      Codec.put_varint old 0; Wire.put_query old q; Wire.put_select old (Wire.Give [| 0 |]);
      if Buffer.contents old <> Bytes.to_string bytes then fine := false
    end;
    for _ = 1 to 8 do
      let m = Bytes.copy bytes in
      let n = Bytes.length m in
      let m =
        match Rng.int r 4 with
        | 0 when n > 0 -> let i = Rng.int r n in Bytes.set m i (Char.chr (Rng.int r 256)); m
        | 1 when n > 0 -> Bytes.sub m 0 (Rng.int r n)
        | 2 -> let i = Rng.int r (n + 1) in Bytes.cat (Bytes.sub m 0 i) (Bytes.cat (Bytes.make (1 + Rng.int r 9) (Char.chr (Rng.int r 256))) (Bytes.sub m i (n - i)))
        | _ -> Bytes.cat m (Bytes.of_string "\001\255\255\255\255\015")
      in
      incr outcomes;
      match Wire.get_request Wire.k_find (Codec.reader m 0 (Bytes.length m)) with
      | _ -> ()
      | exception (Codec.Short | Wire.Malformed _) -> ()
      | exception e -> fine := false; Printf.printf "fuzz: %s\n" (Printexc.to_string e)
    done
  done;
  check !fine "wire: %d fuzzed questions with operators and an order: read or refused, never more; the plain ones coded as before" !outcomes;
  (* Incr (version 4), from a hostile program: every byte changed, cuts, bytes inserted, huge numbers; the request
     is read (each count bounded by the bytes left) or refused (Short, Malformed), never more; a Write without Incr
     is coded byte for byte as before it *)
  let r = Rng.make 17 in
  let good = ref true and tries = ref 0 in
  for _ = 1 to 2000 do
    let op () =
      match Rng.int r 3 with
      | 0 -> Resolve.Incr (Rng.int r 200 - 100, Rng.int r 70000, Rng.int r 1000 - 500, None)
      | 1 -> Resolve.Incr (Rng.int r 200 - 100, Rng.int r 40, (if Rng.bool r then max_int else min_int), Some (Rng.int r 200 - 100, Rng.int r 40))
      | _ -> Resolve.Add (Rng.int r 100, Rng.int r 40, rand_value r)
    in
    let req = Wire.Write { db = 0; serial = Rng.int r 9; floor = 0; by = 0; why = "w"; ops = List.init (1 + Rng.int r 3) (fun _ -> op ()) } in
    let b = Buffer.create 64 in
    Wire.put_request b req;
    let bytes = Buffer.to_bytes b in
    (match Wire.get_request Wire.k_write (Codec.reader bytes 0 (Bytes.length bytes)) with
     | back -> if back <> req then good := false
     | exception _ -> good := false);
    for _ = 1 to 8 do
      let m = Bytes.copy bytes in
      let n = Bytes.length m in
      let m =
        match Rng.int r 4 with
        | 0 -> let i = Rng.int r n in Bytes.set m i (Char.chr (Rng.int r 256)); m
        | 1 -> Bytes.sub m 0 (Rng.int r n)
        | 2 -> let i = Rng.int r (n + 1) in Bytes.cat (Bytes.sub m 0 i) (Bytes.cat (Bytes.make (1 + Rng.int r 9) (Char.chr (Rng.int r 256))) (Bytes.sub m i (n - i)))
        | _ -> Bytes.cat m (Bytes.of_string "\004\255\255\255\255\255\255\255\255\255\001\002")
      in
      incr tries;
      match Wire.get_request Wire.k_write (Codec.reader m 0 (Bytes.length m)) with
      | _ -> ()
      | exception (Codec.Short | Wire.Malformed _) -> ()
      | exception e -> good := false; Printf.printf "fuzz incr: %s\n" (Printexc.to_string e)
    done
  done;
  (* an op tag past 4, and Incr's into byte past 1: refused *)
  let raw tail =
    let b = Buffer.create 16 in
    Codec.put_varint b 0; Codec.put_varint b 1; Codec.put_varint b 0; Codec.put_int b 0; Codec.put_string b ""; Codec.put_varint b 1;
    Buffer.add_string b tail;
    Buffer.to_bytes b
  in
  let refused tail = match Wire.get_request Wire.k_write (let m = raw tail in Codec.reader m 0 (Bytes.length m)) with _ -> false | exception (Codec.Short | Wire.Malformed _) -> true in
  check (!good && refused "\005\002\016\000" && refused "\004\002\016\002\002" && refused "\004\002\016\002\001\002")
    "wire: Incr round trips; %d fuzzed Writes with Incr read or refused, never more; a tag past 4 and a wrong into refused" !tries;
  let replies =
    [ Wire.Welcome { server = "s"; cluster = "c"; session = 9; frame = 16; inflight = 3 };
      Wire.Opened { db = 1; group = 7; props = [ 16, { Schema.name = "a"; typ = Tmoney 2; many = true; unique = false } ] };
      Wire.Facts { group = 3; facts = [ 16, Value.Text "x"; 17, Value.Int (-4) ] };
      Wire.Rows { group = 5; cols = 2; rows = [ [| Value.Int 1; Value.Text "a" |]; [| Value.Int 2; Value.Text "b" |] ] };
      Wire.Receipt { group = 4; things = [ -1, 65536; -2, 65537 ] }; Wire.Pong "x"; Wire.Status [ "a", "b" ];
      Wire.Start { id = "0123456789abcdef"; vseq = 77; runs = [ 40, 90; 0, 40 ] };
      Wire.Err { code = "denied"; message = "no" } ]
  in
  List.iter
    (fun rep ->
      let kind = match rep with
        | Wire.Welcome _ -> Wire.k_hello | Opened _ -> Wire.k_open | Facts _ -> Wire.k_get | Rows _ -> Wire.k_find
        | Receipt _ -> Wire.k_write | Pong _ -> Wire.k_ping | Status _ -> Wire.k_admin | Start _ -> Wire.k_follow
        | Unwatched -> Wire.k_unwatch | Data _ -> Wire.k_load | Erased -> Wire.k_erase | Err _ -> Wire.k_get in
      let flags = match rep with Wire.Err _ -> Wire.f_error | _ -> 0 in
      let b = Buffer.create 64 in
      Wire.put_reply b rep;
      let bytes = Buffer.to_bytes b in
      check (Wire.get_reply kind flags (Codec.reader bytes 0 (Bytes.length bytes)) = rep) "wire: a reply round trips")
    replies;
  (* a count larger than the bytes left is refused before anything is allocated *)
  let b = Buffer.create 16 in
  Codec.put_varint b 0; Codec.put_varint b 1; Codec.put_varint b 1_000_000_000;
  let bytes = Buffer.to_bytes b in
  check (match Wire.get_reply Wire.k_get 0 (Codec.reader bytes 0 (Bytes.length bytes)) with _ -> false | exception Codec.Short -> true)
    "wire: a huge count is refused"

(* ---- origins and sessions ---- *)

let origins () =
  let o = { Origin.token = "web"; session = 123456789; serial = 42; floor = 40 } in
  check (Origin.parse (Origin.wrap o "pay invoice") = Some (o, "pay invoice")) "origin: round trip";
  check (Origin.parse "pay invoice" = None && Origin.why "pay" = "pay") "origin: an application's why alone";
  check (Origin.why (Origin.wrap o "") = "") "origin: an empty why";
  check (Sessions.things [ Resolve.Add (-2, 16, Link (-1)); Add (-1, 17, Int 1); Add (70000, 18, Link (-3)) ] 100
         = [ -2, 100; -1, 101; -3, 102 ]) "sessions: new things in order of first use";
  let t = Sessions.create () in
  let got = ref [] in
  let k r = got := r :: !got in
  let p = match Sessions.start t ~sid:5 ~token:"w" ~serial:1 ~floor:1 ~published:10 ~now:0 [] k with Sessions.Fresh p -> p | _ -> failwith "fresh" in
  check (Sessions.start t ~sid:5 ~token:"w" ~serial:1 ~floor:1 ~published:10 ~now:0 [] k = Sessions.Wait) "sessions: a resend in flight waits";
  check (match Sessions.start t ~sid:5 ~token:"x" ~serial:2 ~floor:1 ~published:10 ~now:0 [] k with Sessions.Refuse ("denied", _) -> true | _ -> false)
    "sessions: another token's session is refused";
  let g, _ = Sessions.snapshot t ~published:12 ~now:0 in
  check (g = 10) "sessions: the checkpoint stops before a write in flight";
  Sessions.finish t p (Ok { Engine.group = 11; things = [] });
  check (List.length !got = 2) "sessions: both waiters answered";
  check (Sessions.start t ~sid:5 ~token:"w" ~serial:1 ~floor:1 ~published:12 ~now:0 [] k = Sessions.Replay { Engine.group = 11; things = [] })
    "sessions: a resend after the end gets the receipt";
  let g, bytes = Sessions.snapshot t ~published:12 ~now:0 in
  check (g = 12) "sessions: nothing in flight: the published group";
  (match Sessions.decode bytes with
   | Some (12, t') ->
     check (Sessions.start t' ~sid:5 ~token:"w" ~serial:1 ~floor:1 ~published:12 ~now:0 [] k = Sessions.Replay { Engine.group = 11; things = [] })
       "sessions: the checkpoint keeps the receipt"
   | _ -> check false "sessions: the checkpoint decodes");
  Bytes.set bytes 20 (Char.chr (Char.code (Bytes.get bytes 20) lxor 1));
  check (Sessions.decode bytes = None) "sessions: a damaged checkpoint is refused";
  check (match Sessions.start t ~sid:5 ~token:"w" ~serial:3 ~floor:3 ~published:12 ~now:0 [] k with Sessions.Fresh _ -> true | _ -> false)
    "sessions: a new serial";
  check (match Sessions.start t ~sid:5 ~token:"w" ~serial:1 ~floor:1 ~published:12 ~now:0 [] k with Sessions.Refuse ("invalid", _) -> true | _ -> false)
    "sessions: a serial below the floor is refused"

(* ---- the rights of every token against every request, through the core (G16) ---- *)

let rights () =
  let sim = Sim_disk.create (Rng.make 5) in
  let disk = Sim_disk.disk sim in
  disk.mkdir "/d";
  let open_db name =
    let e = Result.get_ok (Engine.open_ disk ("/d/" ^ name)) in
    e, { Core.name; index = (if name = "shop" then 0 else 1); dir = "/d/" ^ name; view = (fun () -> Atomic.get e.published); sessions = Sessions.create ();
         more = (fun () -> []); hub = (fun () -> Live.create (Atomic.get e.published) ~tag:0 ~durable:max_int);
         files = Files.cell ~disk ~master:(fun () -> Ok (String.make 32 'k')) ("/d/" ^ name ^ "/vault") }
  in
  let e0, d0 = open_db "shop" and e1, d1 = open_db "stock" in
  let mk name databases admin = { Tokens.name; hash = Tokens.hash_of_text ("cph_" ^ name); databases; admin } in
  let toks =
    Tokens.with_tokens Tokens.empty
      [ mk "w" [ "shop", Tokens.Write ] false; mk "r" [ "shop", Tokens.Read ] false; mk "o" [ "stock", Tokens.Write ] false;
        mk "a" [] true ]
  in
  let srv = Core.create ~server_id:"s" ~cluster_id:"c" ~dbs:[| d0; d1 |] ~tokens:toks ~now:disk.now ~new_session:(let n = ref 0 in fun () -> incr n; !n) () in
  let engines = [| e0; e1 |] in
  let submit (d : Core.db) ops by why k =
    let e = engines.(d.index) in
    let b = Engine.prepare e [| ops, by, why |] in
    k (Engine.commit e b).(0)
  in
  let session tok =
    let out = Buffer.create 256 in
    let rec c = lazy (Core.connect srv ~flush:(fun () -> let cc = Lazy.force c in Buffer.add_buffer out cc.Core.out; Buffer.clear cc.Core.out) ~submit) in
    let c = Lazy.force c in
    let ask req =
      let b = Buffer.create 64 and f = Buffer.create 64 in
      Wire.put_request b req;
      Wire.add_frame f ~id:1 ~kind:(Wire.request_kind req) ~flags:0 b;
      let bytes = Buffer.to_bytes f in
      ignore (Core.input c bytes 0 (Bytes.length bytes));
      c.flush ();
      let s = Buffer.to_bytes out in
      Buffer.clear out;
      if Bytes.length s = 0 then None
      else
        let len = Wire.u32 s 0 in
        Some (Wire.get_reply (Bytes.get_uint8 s 8) (Bytes.get_uint8 s 9) (Codec.reader s Wire.header (len - 6)))
    in
    ignore (ask (Wire.Hello { version = Wire.version; token = "cph_" ^ tok; program = "t"; session = 0 }));
    ask
  in
  let q = { Query.vars = 1; where = [ { Query.e = Var 0; p = Schema.p_name; v = Val (Text "cepheus/name") } ]; ranges = [] } in
  let requests db =
    [ "Open", Wire.Open (if db = 0 then "shop" else "stock"), `Read; "Get", Wire.Get { db; thing = 1 }, `Read;
      "Find", Wire.Find { db; query = q; select = Wire.Give [||]; extra = []; order = Top.none }, `Read;
      "Write", Wire.Write { db; serial = 0; floor = 0; by = 0; why = "t"; ops = [] }, `Write ]
  in
  let right tok db = match tok, db with "w", 0 -> `Write | "r", 0 -> `Read | "o", 1 -> `Write | _ -> `None in
  List.iter
    (fun tok ->
      let ask = session tok in
      List.iter
        (fun db ->
          List.iter
            (fun (what, req, need) ->
              let has = match right tok db, need with `Write, _ -> true | `Read, `Read -> true | _ -> false in
              match ask req with
              | Some (Wire.Err { code = "denied"; _ }) -> check (not has) "rights: %s denied %s on database %d" tok what db
              | Some (Wire.Err e) -> check false "rights: %s %s on %d: %s %s" tok what db e.code e.message
              | Some _ -> check has "rights: %s may not %s on database %d" tok what db
              | None -> check false "rights: no reply")
            (requests db))
        [ 0; 1 ];
      (match ask (Wire.Admin "status") with
       | Some (Wire.Status _) -> check (tok = "a") "rights: status for %s" tok
       | Some (Wire.Err { code = "denied"; _ }) -> check (tok <> "a") "rights: status denied to %s" tok
       | _ -> check false "rights: status");
      (* Follow: a reader's right is enough; granted, the core answers nothing (the transport takes the connection) *)
      List.iter
        (fun db ->
          let ask = session tok in
          match ask (Wire.Follow db) with
          | None -> check (right tok db <> `None) "rights: %s may not follow database %d" tok db
          | Some (Wire.Err { code = "denied"; _ }) -> check (right tok db = `None) "rights: %s denied following database %d" tok db
          | Some _ -> check false "rights: a reply to Follow")
        [ 0; 1 ])
    [ "w"; "r"; "o"; "a" ];
  (* Sort, Limit and After through the server: the rows the engine gives on the same view, in its order, and an After
     without Sort refused *)
  (let ask = session "r" in
   let q = { Query.vars = 2; where = [ { Query.e = Var 0; p = Schema.p_name; v = Var 1 } ]; ranges = [] } in
   let order = { Top.keys = [ { col = 0; desc = true } ]; limit = 2; after = None } in
   let want =
     let a = Answer.answer ~order (d0.view ()) q (Wire.Give [| 1 |]) in
     List.init a.n (fun i -> [| Store.value (d0.view ()) (a.typ 0) (a.word i 0) |])
   in
   (match ask (Wire.Find { db = 0; query = q; select = Wire.Give [| 1 |]; extra = []; order }) with
    | Some (Wire.Rows r) -> check (List.length want = 2 && r.rows = want) "order: the server's rows are the engine's, sorted and cut"
    | _ -> check false "order: no rows");
   match ask (Wire.Find { db = 0; query = q; select = Wire.Give [| 1 |]; extra = []; order = { Top.none with after = Some [| Value.Text "a" |] } }) with
   | Some (Wire.Err { code = "invalid"; _ }) -> check true ""
   | _ -> check false "order: After without Sort is refused");
  (* an unknown token, and requests before Hello *)
  let ask = session "nobody" in
  check (match ask (Wire.Get { db = 0; thing = 1 }) with Some (Wire.Err { code = "auth"; _ }) -> true | _ -> false) "rights: an unknown token";
  (* a token removed from the table: its connection is refused at its next request *)
  let ask = session "w" in
  check (match ask (Wire.Get { db = 0; thing = 1 }) with Some (Wire.Facts _) -> true | _ -> false) "rights: w reads";
  Atomic.set srv.tokens (Tokens.with_tokens Tokens.empty (List.filter (fun (t : Tokens.token) -> t.name <> "w") toks.tokens));
  check (match ask (Wire.Get { db = 0; thing = 1 }) with Some (Wire.Err { code = "auth"; _ }) -> true | _ -> false) "rights: a removed token";
  (* rights narrowed: write to read *)
  Atomic.set srv.tokens toks;
  let ask = session "w" in
  Atomic.set srv.tokens (Tokens.with_tokens Tokens.empty (mk "w" [ "shop", Tokens.Read ] false :: toks.tokens |> List.filteri (fun i _ -> i <> 1)));
  check (match ask (Wire.Write { db = 0; serial = 0; floor = 0; by = 0; why = "t"; ops = [] }) with Some (Wire.Err { code = "denied"; _ }) -> true | _ -> false)
    "rights: narrowed at the next request";
  (* a why with the server's marker is refused: a program cannot write another's origin *)
  Atomic.set srv.tokens toks;
  let ask = session "w" in
  check (match ask (Wire.Write { db = 0; serial = 0; floor = 0; by = 0; why = Origin.marker ^ "x"; ops = [] }) with Some (Wire.Err { code = "invalid"; _ }) -> true | _ -> false)
    "rights: a forged origin is refused";
  (* a frame over the limit closes the connection before its body is read *)
  let c = Core.connect srv ~flush:(fun () -> ()) ~submit in
  let big = Bytes.create 10 in
  Bytes.set_int32_le big 0 (Int32.of_int (Wire.max_frame + 1));
  check (snd (Core.input c big 0 10) = Core.Shut) "rights: a frame over 16 MiB closes"


(* Every token file of the old forms reads the same and is written back byte for byte (the writer of main wrote
   exactly this); the new form of rights per kind, and cepheus token add's DB=read:K,K;add:K. *)
let tokens_golden () =
  let h1 = String.make 64 'a' and h2 = String.make 64 'b' and h3 = String.make 64 'c' in
  let old =
    "# Cepheus tokens: written by `cepheus token`; the server reloads this file when it changes.\n\n[[token]]\nname = \"shop-web\"\nhash = \"blake2b-256:"
    ^ h1 ^ "\"\ndatabases = { shop = \"write\", stock = \"read\" }\n\n[[token]]\nname = \"ops\"\nhash = \"blake2b-256:" ^ h2
    ^ "\"\nadmin = true\n\n[[token]]\nname = \"both\"\nhash = \"blake2b-256:" ^ h3 ^ "\"\ndatabases = { shop = \"read\" }\nadmin = true\n"
  in
  let t = Tokens.of_toml (Toml.parse old) in
  let rights = List.map (fun (k : Tokens.token) -> k.name, k.databases, k.admin) t.tokens in
  check (rights = [ "shop-web", [ "shop", Tokens.Write; "stock", Tokens.Read ], false; "ops", [], true; "both", [ "shop", Tokens.Read ], true ])
    "tokens: an old file reads as before";
  check (Tokens.to_toml t = old) "tokens: an old file is written back byte for byte";
  let kinds = Tokens.Kinds { read = [ "compte"; "transaction" ]; add = [ "transaction" ] } in
  let t2 = Tokens.with_tokens Tokens.empty [ { name = "compta-web"; hash = String.make 32 'x'; databases = [ "compta", kinds; "shop", Tokens.Read ]; admin = false } ] in
  let text = Tokens.to_toml t2 in
  check (List.exists (fun l -> l = "databases = { compta = { read = [\"compte\", \"transaction\"], add = [\"transaction\"] }, shop = \"read\" }") (String.split_on_char '\n' text))
    "tokens: rights per kind written as the design says";
  check ((Tokens.of_toml (Toml.parse text)).tokens = t2.tokens) "tokens: rights per kind round trip";
  check (Tokens.right_of_name "read:compte,transaction;add:transaction" = Some kinds) "tokens: DB=read:K,K;add:K";
  check (Tokens.right_name kinds = "read:compte,transaction;add:transaction") "tokens: a right per kind listed as it is given";
  check (Tokens.right_of_name "add:transaction" = Some (Tokens.Kinds { read = []; add = [ "transaction" ] })) "tokens: add only";
  check (List.for_all (fun r -> Tokens.right_of_name r = None) [ ""; "reed"; "read:"; "read:A"; "delete:x"; "read:a;;add:b"; "read:a:b" ]) "tokens: bad rights refused";
  check (Tokens.right_of_name "read" = Some Tokens.Read && Tokens.right_of_name "write" = Some Tokens.Write) "tokens: read and write as before";
  check (Tokens.kind_of "client/City" = "client" && Tokens.kind_of "plain" = "plain") "tokens: a property's kind";
  let bad doc = match Tokens.of_toml (Toml.parse doc) with _ -> false | exception Config.Bad _ -> true in
  let head = "[[token]]\nname = \"x\"\nhash = \"blake2b-256:" ^ h1 ^ "\"\n" in
  check (bad (head ^ "databases = { compta = { read = [] } }\n")) "tokens: a right per kind of no kind is refused";
  check (bad (head ^ "databases = { compta = { delete = [\"a\"] } }\n")) "tokens: an unknown right per kind is refused";
  check (bad (head ^ "databases = { compta = { read = [\"Upper\"] } }\n")) "tokens: a kind's name in small letters";
  check (bad (head ^ "databases = { compta = { read = \"a\" } }\n")) "tokens: kinds in a list"

(* Rights per kind through the core: questions checked when they arrive, writes at each fact and declaration, Get's
   facts of the kinds read only, no local reads. *)
let rights_kinds () =
  let sim = Sim_disk.create (Rng.make 7) in
  let disk = Sim_disk.disk sim in
  disk.mkdir "/k";
  let e = Result.get_ok (Engine.open_ disk "/k/compta") in
  let d = { Core.name = "compta"; index = 0; dir = "/k/compta"; view = (fun () -> Atomic.get e.published); sessions = Sessions.create ();
            more = (fun () -> []); hub = (fun () -> Live.create (Atomic.get e.published) ~tag:0 ~durable:max_int);
            files = Files.cell ~disk ~master:(fun () -> Ok (String.make 32 'k')) "/k/compta/vault" } in
  let mk name databases = { Tokens.name; hash = Tokens.hash_of_text ("cph_" ^ name); databases; admin = false } in
  let kinds = Tokens.Kinds { read = [ "compte"; "transaction" ]; add = [ "transaction" ] } in
  let toks = Tokens.with_tokens Tokens.empty
      [ mk "w" [ "compta", Tokens.Write ]; mk "k" [ "compta", kinds ]; mk "add" [ "compta", Tokens.Kinds { read = []; add = [ "transaction" ] } ] ] in
  let srv = Core.create ~server_id:"s" ~cluster_id:"c" ~dbs:[| d |] ~tokens:toks ~now:disk.now ~new_session:(let n = ref 0 in fun () -> incr n; !n) () in
  let submit (_ : Core.db) ops by why k = let b = Engine.prepare e [| ops, by, why |] in k (Engine.commit e b).(0) in
  let session tok =
    let out = Buffer.create 256 in
    let rec c = lazy (Core.connect srv ~flush:(fun () -> let cc = Lazy.force c in Buffer.add_buffer out cc.Core.out; Buffer.clear cc.Core.out) ~submit) in
    let c = Lazy.force c in
    let ask req =
      let b = Buffer.create 64 and f = Buffer.create 64 in
      Wire.put_request b req;
      Wire.add_frame f ~id:1 ~kind:(Wire.request_kind req) ~flags:0 b;
      let bytes = Buffer.to_bytes f in
      ignore (Core.input c bytes 0 (Bytes.length bytes));
      c.flush ();
      let s = Buffer.to_bytes out in
      Buffer.clear out;
      if Bytes.length s = 0 then None
      else Some (Wire.get_reply (Bytes.get_uint8 s 8) (Bytes.get_uint8 s 9) (Codec.reader s Wire.header (Wire.u32 s 0 - 6)))
    in
    ignore (ask (Wire.Hello { version = Wire.version; token = "cph_" ^ tok; program = "t"; session = 0 }));
    ask
  in
  let declare p name typ = List.map (fun (e, p, v) -> Resolve.Add (e, p, v)) (Schema.facts p { Schema.name; typ; many = false; unique = false }) in
  let write ask ops = ask (Wire.Write { db = 0; serial = 0; floor = 0; by = 0; why = "t"; ops }) in
  let ok = function Some (Wire.Receipt _) -> true | _ -> false in
  let denied = function Some (Wire.Err { code = "denied"; _ }) -> true | _ -> false in
  let w = session "w" and k = session "k" and a = session "add" in
  check (ok (write w (declare 16 "compte/Name" Ttext @ declare 17 "transaction/Amount" Tint @ declare 18 "secret/Note" Ttext))) "kinds: declared by a writer";
  let made = write w [ Add (-1, 16, Text "Ada"); Add (-1, 17, Int 90); Add (-1, 18, Text "hush") ] in
  check (ok made) "kinds: facts of three kinds";
  let thing = match made with Some (Wire.Receipt { things = (_, t) :: _; _ }) -> t | _ -> 0 in
  let q ps = { Query.vars = 2; where = List.map (fun p -> { Query.e = Var 0; p; v = Var 1 }) ps; ranges = [] } in
  let find ask ps = ask (Wire.Find { db = 0; query = q ps; select = Wire.Give [||]; extra = []; order = Top.none }) in
  let watch ask ps = ask (Wire.Watch { db = 0; query = q ps; select = Wire.Give [||]; from = 0; wextra = [] }) in
  check (match find k [ 17 ] with Some (Wire.Rows _) -> true | _ -> false) "kinds: a question on a kind read";
  check (denied (find k [ 18 ]) && denied (find k [ 16; 18 ])) "kinds: a question that touches a kind not read is denied";
  check (denied (watch k [ 18 ])) "kinds: a watch too, when it arrives";
  check (not (denied (watch k [ 16; 17 ]))) "kinds: a watch of kinds read";
  (match k (Wire.Get { db = 0; thing }) with
   | Some (Wire.Facts f) -> check (List.sort compare (List.map fst f.facts) = [ 16; 17 ]) "kinds: Get gives the facts of the kinds read only"
   | _ -> check false "kinds: Get");
  (match w (Wire.Get { db = 0; thing }) with
   | Some (Wire.Facts f) -> check (List.length f.facts = 3) "kinds: a write token's Get as before"
   | _ -> check false "kinds: Get of w");
  check (ok (write k [ Add (-1, 17, Int 5) ])) "kinds: a fact of a kind added";
  check (denied (write k [ Add (-1, 16, Text "Bo") ])) "kinds: a fact of a kind not added is denied";
  check (denied (write k [ Add (-1, 17, Int 1); Add (-1, 18, Text "x") ])) "kinds: a group with one such fact, all of it";
  check (ok (write k (declare 19 "transaction/Date" Tdate))) "kinds: declaring a property of a kind added";
  check (denied (write k (declare 20 "secret/More" Ttext))) "kinds: declaring one of another kind is denied";
  check (denied (write k [ Add (21, Schema.p_name, Text "r"); Add (21, Schema.p_rule, Text "x") ])) "kinds: rules are for write tokens";
  check (denied (k (Wire.Follow 0))) "kinds: no local reads";
  check (not (denied (w (Wire.Follow 0)))) "kinds: a write token still follows";
  check (match k (Wire.Open "compta") with Some (Wire.Opened _) -> true | _ -> false) "kinds: Open";
  check (ok (write a [ Add (-1, 17, Int 7) ]) && denied (find a [ 17 ])) "kinds: add only: writes, reads nothing";
  (* Incr adds to its counter's kind and to its into's: both must be kinds the token adds *)
  check (ok (write w (declare 22 "transaction/Number" Tint @ declare 23 "compte/Next" Tint))) "kinds: counters declared";
  check (ok (write k [ Incr (-1, 17, 1, Some (-2, 22)) ])) "kinds: an Incr within the kinds added";
  check (denied (write k [ Incr (thing, 23, 1, None) ])) "kinds: an Incr of a counter of a kind not added is denied";
  check (denied (write k [ Incr (-1, 17, 1, Some (thing, 23)) ])) "kinds: an Incr into a kind not added is denied";
  check (denied (write a [ Incr (-1, 22, 1, Some (-2, 16)) ])) "kinds: add only, into another kind: denied";
  check (ok (write a [ Incr (-1, 22, 1, Some (-2, 17)) ])) "kinds: add only, within its kind: written";
  (* every operator under rights per kind, on random questions: denied when any pattern, those inside Not and Or too,
     names a kind the token may not read (16 and 17 read, 18 not); else the rows a write token gets, in the same
     order, whatever Sort, Limit and After a client sends (a cursor made by hand included) *)
  for i = 1 to 30 do ignore (write w [ Add (-1, 16, Text (Printf.sprintf "n%d" (i mod 7))); Add (-1, 17, Int (i mod 5)); Add (-1, 18, Text (Printf.sprintf "s%d" (i mod 3))) ]) done;
  let r = Rng.make 41 in
  let leaks = ref 0 and denials = ref 0 and answered = ref 0 in
  let typ p = if p = 17 then Value.Tint else Ttext in
  let sample p = if p = 17 then Value.Int (Rng.int r 6) else if p = 16 then Text (Printf.sprintf "n%d" (Rng.int r 8)) else Text (Printf.sprintf "s%d" (Rng.int r 4)) in
  for _ = 1 to 600 do
    let pk () = 16 + Rng.int r 3 in
    let top = pk () and np = pk () and oa = pk () and ob = pk () in
    let uses = ref [ top ] in
    let extra = ref [] and vars = ref 2 in
    let fresh () = let x = !vars in incr vars; x in
    if Rng.bool r then (uses := np :: !uses; extra := Ask.Not [ Pattern { e = Var 0; p = np; v = Val (sample np) } ] :: !extra);
    if Rng.bool r && oa <> ob then begin
      uses := oa :: ob :: !uses;
      let a = fresh () and b = fresh () in
      extra := Ask.Or [ [ Pattern { e = Var 0; p = oa; v = Var a } ]; [ Pattern { e = Var 0; p = ob; v = Var b } ] ] :: !extra
    end;
    if Rng.bool r then extra := Ask.In (1, List.init (1 + Rng.int r 3) (fun _ -> sample top)) :: !extra;
    let q = { Query.vars = !vars; where = [ { e = Var 0; p = top; v = Var 1 } ]; ranges = [] } in
    let order =
      if Rng.bool r then Top.none
      else { Top.keys = [ { col = 1; desc = Rng.bool r } ]; limit = Rng.int r 4;
             after = (if Rng.bool r then Some [| Value.Link (65536 + Rng.int r 100); sample top |] else None) } in
    let req = Wire.Find { db = 0; query = q; select = Wire.Give [| 0; 1 |]; extra = !extra; order } in
    let readable = List.for_all (fun p -> p <> 18) !uses in
    ignore typ;
    match k req, w req with
    | Some (Wire.Err { code = "denied"; _ }), _ -> incr denials; if readable then incr leaks
    | Some (Wire.Rows a), Some (Wire.Rows b) -> incr answered; if (not readable) || a.rows <> b.rows then incr leaks
    | Some (Wire.Err e), Some (Wire.Err e') -> if e.code <> e'.code then incr leaks
    | _ -> incr leaks
  done;
  check (!leaks = 0 && !denials > 100 && !answered > 100) "kinds: every operator, Sort and After under rights per kind (%d denied, %d answered, %d wrong)" !denials !answered !leaks;
  check (denied (k (Wire.Watch { db = 0; query = q [ 16 ]; select = Wire.Give [||]; from = 0; wextra = [ Ask.Not [ Pattern { e = Var 0; p = 18; v = Var 2 } ] ] })))
    "kinds: a watch with a Not over a kind not read is denied";
  (* the bounds, each with its error; the work budget; a cursor by hand that is not a row *)
  let invalid = function Some (Wire.Err { code = "invalid"; _ }) -> true | _ -> false in
  let fq ?(extra = []) ?(order = Top.none) () = w (Wire.Find { db = 0; query = q [ 16 ]; select = Wire.Give [||]; extra; order }) in
  check (invalid (fq ~order:{ Top.keys = [ { col = 0; desc = false } ]; limit = Top.max_limit + 1; after = None } ())) "bounds: Limit";
  check (invalid (fq ~extra:[ Ask.In (1, List.init (Ask.max_in + 1) (fun i -> Value.Text (string_of_int i))) ] ())) "bounds: In's values";
  check (invalid (fq ~extra:(List.init 4 (fun _ -> Ask.Or [ [ Pattern { e = Var 0; p = 16; v = Var 1 } ]; [ Pattern { e = Var 0; p = 17; v = Var 2 } ];
                                                        [ Pattern { e = Var 0; p = 18; v = Var 3 } ] ])) ())) "bounds: the Ors' product";
  check (invalid (fq ~extra:(List.init 70 (fun _ -> Ask.Not [ Pattern { e = Var 0; p = 18; v = Val (Text "x") } ])) ())) "bounds: operators";
  check (invalid (fq ~order:{ Top.keys = [ { col = 0; desc = false } ]; limit = 2; after = Some [| Value.Text "not a link"; Text "a" |] } ())) "bounds: a cursor of other types";
  check (invalid (fq ~order:{ Top.keys = [ { col = 0; desc = false } ]; limit = 2; after = Some [| Value.Link 1 |] } ())) "bounds: a cursor short of a column";
  let saved = !Answer.question_budget in
  Answer.question_budget := 10;
  check (match fq () with Some (Wire.Err { code = "too_large"; _ }) -> true | _ -> false) "bounds: the question's work budget";
  Answer.question_budget := saved;
  check (match fq () with Some (Wire.Rows _) -> true | _ -> false) "bounds: within its budget"

(* Rights per kind with equality: cepheus/same (the classes the rules make) is read as a derived fact, through what the
   equalities read; and with equality, every property's facts may be rewritten, so its readers must read that too *)
let rights_equality () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ ax; by_ ]) = declare db [ prop ~many:true "a/x" Tlink; prop ~many:true "b/y" Tlink ] in
  let same_rule =
    { name = "a-key"; vars = 3; where = [ { e = Var 0; p = ax; v = Var 2 }; { e = Var 1; p = ax; v = Var 2 } ]; ranges = [];
      head = Give { e = Var 0; p = Schema.p_same; v = Var 1 } }
  in
  ignore (Result.get_ok (define db [ same_rule ]));
  let v = view db in
  let k read = Tokens.Kinds { read; add = [] } in
  check (not (Core.reads_prop v (k [ "b" ]) Schema.p_same)) "equality and kinds: cepheus/same unread without the kind the equalities read";
  check (Core.reads_prop v (k [ "a" ]) Schema.p_same) "equality and kinds: cepheus/same read with it";
  check (not (Core.reads_prop v (k [ "b" ]) by_)) "equality and kinds: b's facts may be rewritten by a's equalities: unread without a";
  check (Core.reads_prop v (k [ "a"; "b" ]) by_) "equality and kinds: read with both"

(* Rights per kind with rules: a token sees a property's facts, derived ones included, only when it reads the kind
   of the property and every kind those facts can come from through the rules. Random rules (across kinds, over a
   variable property too) and random facts, written by a write token; tokens reading some kinds; after every group,
   each token's Get of each thing and its questions against the oracle's own reckoning from the rules (not
   Reason.sources). And a refusal by a constraint names only the constraint to such a token. *)
let rights_derived () =
  let kinds_of = [| "a"; "a"; "b"; "c"; "c" |] in
  let names = [| "a/x"; "a/n"; "b/y"; "c/z"; "c/meta" |] in
  let types = [| Value.Tlink; Tint; Tlink; Tlink; Tlink |] in
  let readers = [ [ "a" ]; [ "a"; "b" ]; [ "b"; "c" ]; [ "a"; "b"; "c" ]; [] ] in
  for seed = 1 to 25 do
    let r = Rng.make (1000 + seed) in
    let sim = Sim_disk.create (Rng.make seed) in
    let disk = Sim_disk.disk sim in
    disk.mkdir "/r";
    let e = Result.get_ok (Engine.open_ disk "/r/db") in
    let d = { Core.name = "db"; index = 0; dir = "/r/db"; view = (fun () -> Atomic.get e.published); sessions = Sessions.create ();
              more = (fun () -> []); hub = (fun () -> Live.create (Atomic.get e.published) ~tag:0 ~durable:max_int);
              files = Files.cell ~disk ~master:(fun () -> Ok (String.make 32 'k')) "/r/db/vault" } in
    let mk name databases = { Tokens.name; hash = Tokens.hash_of_text ("cph_" ^ name); databases; admin = false } in
    let kt i ks = mk (Printf.sprintf "k%d" i) [ "db", Tokens.Kinds { read = ks; add = [ "a" ] } ] in
    let toks = Tokens.with_tokens Tokens.empty (mk "w" [ "db", Tokens.Write ] :: List.mapi kt readers) in
    let srv = Core.create ~server_id:"s" ~cluster_id:"c" ~dbs:[| d |] ~tokens:toks ~now:disk.now ~new_session:(let n = ref 0 in fun () -> incr n; !n) () in
    let submit (_ : Core.db) ops by why k = let b = Engine.prepare e [| ops, by, why |] in k (Engine.commit e b).(0) in
    let session () =
      let out = Buffer.create 256 in
      let rec c = lazy (Core.connect srv ~flush:(fun () -> let cc = Lazy.force c in Buffer.add_buffer out cc.Core.out; Buffer.clear cc.Core.out) ~submit) in
      let c = Lazy.force c in
      fun req ->
        let b = Buffer.create 64 and f = Buffer.create 64 in
        Wire.put_request b req;
        Wire.add_frame f ~id:1 ~kind:(Wire.request_kind req) ~flags:0 b;
        let bytes = Buffer.to_bytes f in
        ignore (Core.input c bytes 0 (Bytes.length bytes));
        c.flush ();
        let s = Buffer.to_bytes out in
        Buffer.clear out;
        if Bytes.length s = 0 then None
        else Some (Wire.get_reply (Bytes.get_uint8 s 8) (Bytes.get_uint8 s 9) (Codec.reader s Wire.header (Wire.u32 s 0 - 6)))
    in
    let hello ask tok = ignore (ask (Wire.Hello { version = Wire.version; token = "cph_" ^ tok; program = "t"; session = 0 })); ask in
    let w = hello (session ()) "w" in
    let ks = List.mapi (fun i k -> k, hello (session ()) (Printf.sprintf "k%d" i)) readers in
    let write ask ops = ask (Wire.Write { db = 0; serial = 0; floor = 0; by = 0; why = "t"; ops }) in
    let decl = List.concat (List.init 5 (fun i -> List.map (fun (e, p, v) -> Resolve.Add (e, p, v)) (Schema.facts (16 + i) { Schema.name = names.(i); typ = types.(i); many = true; unique = false }))) in
    ignore (write w decl);
    let things = match write w (List.init 6 (fun i -> Resolve.Add (-(i + 1), 17, Value.Int i))) with
      | Some (Wire.Receipt { things; _ }) -> Array.of_list (List.map snd things) | _ -> [||] in
    (* a constraint's refusal, to a token that may not read every kind: its name only (before any fact of a/x or b/y) *)
    ignore (write w [ Add (60, Schema.p_name, Text "no-a-b"); Add (60, Schema.p_rule, Text (Rules.to_text
      { name = "no-a-b"; vars = 2; where = [ { e = Var 0; p = 16; v = Var 1 }; { e = Var 0; p = 18; v = Var 1 } ]; ranges = []; head = Never })) ]);
    ignore (write w [ Add (things.(0), 18, Link things.(1)) ]);
    (match write (snd (List.hd ks)) [ Add (things.(0), 16, Link things.(1)) ] with
     | Some (Wire.Err { code = "invalid"; message }) -> check (message = "constraint no-a-b") "rules and kinds: a constraint's refusal names it only: %s" message
     | _ -> check false "rules and kinds: the constraint must refuse");
    ignore (write w [ Retract (things.(0), 18, Link things.(1)); Retract (60, Schema.p_rule, Text (Rules.to_text
      { name = "no-a-b"; vars = 2; where = [ { e = Var 0; p = 16; v = Var 1 }; { e = Var 0; p = 18; v = Var 1 } ]; ranges = []; head = Never })); Retract (60, Schema.p_name, Text "no-a-b") ]);
    let thing () = things.(Rng.int r (Array.length things)) in
    let links = [| 16; 18; 19 |] in
    let next_rule = ref 30 in
    let rule () =
      let pick () = links.(Rng.int r 3) in
      let x = Query.Var 0 and y = Query.Var 1 and z = Query.Var 2 in
      let rl : Rules.t =
        match Rng.int r 4 with
        | 0 -> { name = "r"; vars = 2; where = [ { e = x; p = pick (); v = y } ]; ranges = []; head = Give { e = x; p = pick (); v = y } }
        | 1 -> { name = "r"; vars = 3; where = [ { e = x; p = pick (); v = y }; { e = y; p = pick (); v = z } ]; ranges = []; head = Give { e = x; p = pick (); v = z } }
        | 2 -> { name = "r"; vars = 4; where = [ { e = Var 3; p = 20; v = Var 2 }; { e = x; p = Rules.prop_var 2; v = y } ]; ranges = []; head = Give { e = x; p = pick (); v = y } }
        | _ -> { name = "r"; vars = 2; where = [ { e = x; p = 17; v = Var 1 } ]; ranges = []; head = Give { e = x; p = pick (); v = x } }
      in
      let id = !next_rule in
      incr next_rule;
      let name = Printf.sprintf "rule%d" id in
      ignore (write w [ Add (id, Schema.p_name, Text name); Add (id, Schema.p_rule, Text (Rules.to_text { rl with name })) ])
    in
    for _ = 1 to 3 do rule () done;
    for g = 1 to 25 do
      if Rng.int r 6 = 0 then rule ()
      else
        ignore (write w (List.init (1 + Rng.int r 3) (fun _ ->
                   match Rng.int r 5 with
                   | 0 -> Resolve.Add (thing (), 20, Link (16 + Rng.int r 5))
                   | 1 -> Retract (thing (), links.(Rng.int r 3), Link (thing ()))
                   | _ -> Add (thing (), links.(Rng.int r 3), Link (thing ())))));
      let v = Atomic.get e.published in
      (* the oracle: the properties each property's facts can come from, from the rules' texts *)
      let rules = List.filter_map (fun (_, (n, t)) -> Result.to_option (Rules.of_text n t)) (Schema.rules v.schema) in
      let from p =
        let seen = Hashtbl.create 8 and any = ref false and q = Queue.create () in
        Queue.add p q;
        while not (Queue.is_empty q) do
          let x = Queue.pop q in
          List.iter
            (fun (rl : Rules.t) ->
              match rl.head with
              | Give h when h.p = x || h.p < 0 ->
                List.iter (fun (a : Query.pattern) -> if a.p < 0 then any := true else if not (Hashtbl.mem seen a.p) then (Hashtbl.replace seen a.p (); Queue.add a.p q)) rl.where
              | _ -> ())
            rules
        done;
        if !any then List.init 5 (fun i -> 16 + i) else Hashtbl.fold (fun k () l -> k :: l) seen []
      in
      let kind p = if p >= 16 && p < 21 then kinds_of.(p - 16) else "?" in
      List.iter
        (fun (kr, ask) ->
          let may p = List.mem (kind p) kr && List.for_all (fun q -> List.mem (kind q) kr) (from p) in
          Array.iter
            (fun t ->
              let want = ref [] in
              Store.iter_facts v t (fun p w -> if may p then want := (p, w) :: !want);
              match ask (Wire.Get { db = 0; thing = t }) with
              | Some (Wire.Facts f) ->
                let got = List.sort compare (List.map (fun (p, x) -> p, Option.get (Store.word v x)) f.facts) in
                check (got = List.sort compare !want) "rules and kinds: seed %d group %d: a token reading %s sees exactly what it may of #%d"
                  seed g (String.concat "," kr) t
              | _ -> check false "rules and kinds: Get")
            things;
          List.iter
            (fun p ->
              let q = { Query.vars = 2; where = [ { Query.e = Var 0; p; v = Var 1 } ]; ranges = [] } in
              match ask (Wire.Find { db = 0; query = q; select = Wire.Give [||]; extra = []; order = Top.none }) with
              | Some (Wire.Err { code = "denied"; _ }) -> check (not (may p)) "rules and kinds: seed %d: a question on %d denied only when it may not be read" seed p
              | Some (Wire.Rows _) -> check (may p) "rules and kinds: seed %d: a question on %d answered only when it may be read" seed p
              | _ -> check false "rules and kinds: Find")
            [ 16; 17; 18; 19 ])
        ks
    done;
  done

(* ---- what local readers need from the system ---- *)

let open_fds () = Array.length (Sys.readdir "/proc/self/fd")

let fdpass () =
  let r = Rng.make 23 in
  let before = open_fds () in
  let a, b = Unix.socketpair ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  (* the files passed: pipes' read ends, each known by its inode *)
  let pool = Array.init 8 (fun _ -> let x, y = Unix.pipe ~cloexec:true () in Unix.close y; x) in
  let ino fd = (Unix.fstat fd).st_ino in
  let ok = ref true and passed = ref 0 in
  for _ = 1 to 400 do
    let n = 1 + Rng.int r 6000 in
    let msg = Bytes.init n (fun _ -> Char.chr (Rng.int r 256)) in
    let fds = List.init (Rng.int r 9) (fun _ -> Rng.pick r pool) in
    let t = Thread.create (fun () -> Fdpass.send a msg 0 n fds) () in
    let got = Buffer.create n and rfds = ref [] in
    while Buffer.length got < n do
      let piece = 1 + Rng.int r 3000 in
      let buf = Bytes.create (piece + 7) in
      let m, fs = Fdpass.recv b buf 7 piece in
      Buffer.add_subbytes got buf 7 m;
      rfds := !rfds @ fs
    done;
    Thread.join t;
    if Buffer.to_bytes got <> msg then ok := false;
    if List.map ino !rfds <> List.map ino fds then ok := false;
    (* each a new descriptor of the same open file, close-on-exec *)
    List.iter (fun fd -> if List.mem fd fds then ok := false) !rfds;
    passed := !passed + List.length !rfds;
    List.iter Unix.close !rfds
  done;
  check !ok "fdpass: 400 random messages with up to 8 descriptors, read in random pieces: the bytes and the files in order";
  check (match Fdpass.send a (Bytes.create 1) 0 1 (List.init 65 (fun _ -> pool.(0))) with _ -> false | exception Invalid_argument _ -> true)
    "fdpass: more than 64 descriptors are refused";
  check (match Fdpass.recv b (Bytes.create 4) 2 3 with _ -> false | exception Invalid_argument _ -> true) "fdpass: a range out of the buffer is refused";
  Array.iter Unix.close pool;
  Unix.close a;
  Unix.close b;
  check (open_fds () = before) "fdpass: no descriptor left open (%d passed)" !passed;
  (* the visibility page: the server's store is read at once through a read-only mapping, one a file *)
  let dir = Filename.concat (Option.value (Sys.getenv_opt "CEPHEUS_TMP") ~default:(Filename.get_temp_dir_name ())) (Printf.sprintf "cepheus-page-%d" (Unix.getpid ())) in
  C.rmrf dir;
  Unix.mkdir dir 0o700;
  let path = Filename.concat dir "page" in
  let word, ro = Follow.open_page path in
  word.set 12345;
  (* as a reader maps the read-only descriptor it is passed (here the server's own: closing a copy of it in this
     process would release the server's lock, as POSIX locks go) *)
  let p = Fdpass.map_page ro in
  check (Fdpass.word p = 12345) "page: the reader reads the server's number";
  word.set 7;
  check (Fdpass.word p = 7) "page: a store is seen at once";
  check (Fdpass.map_page ro == p) "page: one mapping a file";
  (* a second server of the same database (another process) is refused: the page's lock *)
  (match Unix.fork () with
   | 0 -> Unix._exit (match Follow.open_page path with _ -> 0 | exception Failure _ -> 3)
   | pid -> check (match Unix.waitpid [] pid with _, Unix.WEXITED 3 -> true | _ -> false) "page: a second server is refused");
  check (Follow.page_path "\001\255" = "/dev/shm/cepheus-01ff.visible") "page: named by the database's id";
  C.rmrf dir

(* A follower of a database with a rule: its derived facts come in the run (bit 63) and in the frames (the journal's
   kinds); the follower applies them as replay does, never evaluating a rule, and holds exactly the engine's facts
   and kinds, from its start and after it rests its states on a new base. *)
let followed_rules () =
  let ok = function Ok x -> x | Error e -> failwith (Cepheus.message e) in
  let base = Filename.concat (Option.value (Sys.getenv_opt "CEPHEUS_TMP") ~default:(Filename.get_temp_dir_name ())) (Printf.sprintf "cepheus-rules-%d" (Unix.getpid ())) in
  C.rmrf base;
  Unix.mkdir base 0o700;
  let dir = Filename.concat base "db" in
  let db = ok (Cepheus.open_ dir) in
  let ty, parent = match ok (Cepheus.declare db [ prop ~many:true "type" Tlink; prop ~many:true "parent" Tlink ]) with [ a; b ] -> a, b | _ -> assert false in
  let r = ok (Cepheus.write db [ Add (-1, ty, Link (-1)); Add (-2, ty, Link (-2)); Add (-3, ty, Link (-3)) ]) in
  let invoice = Cepheus.thing r (-1) and document = Cepheus.thing r (-2) and thing_ = Cepheus.thing r (-3) in
  ignore (ok (Cepheus.write db [ Add (invoice, parent, Link document); Add (document, parent, Link thing_) ]));
  let is_a =
    { Cepheus.name = "is-a"; vars = 3; where = [ { e = Var 0; p = ty; v = Var 1 }; { e = Var 1; p = parent; v = Var 2 } ]; ranges = [];
      head = Give { e = Var 0; p = ty; v = Var 2 } }
  in
  ignore (ok (Cepheus.define db [ is_a ]));
  let xs = List.init 5 (fun _ -> Cepheus.thing (ok (Cepheus.write db [ Add (-1, ty, Link invoice) ])) (-1)) in
  (* everything into one run: its derived facts carry their flag *)
  ok (Cepheus.snapshot db);
  (* then frames with every kind: derived, asserted over derived, back to derived, premises retracted *)
  List.iteri
    (fun i x ->
      ignore (ok (Cepheus.write db [ Add (x, ty, Link document) ]));
      if i mod 2 = 0 then ignore (ok (Cepheus.write db [ Retract (x, ty, Link document) ]));
      if i = 4 then ignore (ok (Cepheus.write db [ Retract (x, ty, Link invoice) ])))
    xs;
  ignore (ok (Cepheus.write db [ Add (-1, ty, Link document) ]));
  let v = Cepheus.view db in
  (* the follower, as a reader would build it: the run's bytes, then the groups after it from the journal *)
  let id = Engine.read_meta Disk.real dir in
  let sdir = Filename.concat dir "snapshots" in
  let runs = List.sort (fun (_, h, _) (_, h', _) -> compare h' h) (Snapshot.list Disk.real sdir) in
  let fol =
    Follower.create ~id ~word:(fun () -> 1) ~names:(List.map (fun (lo, hi, _) -> lo, hi) runs)
      ~files:(List.map (fun (_, _, n) -> Follower.Mem (Disk.read_all Disk.real (Filename.concat sdir n))) runs)
  in
  let top = match runs with (_, hi, _) :: _ -> hi | [] -> 0 in
  Journal.read_after Disk.real (Filename.concat dir "journal") id top (fun g ->
      let b = Buffer.create 64 in
      Group.encode b g;
      Follower.frame fol ~vseq:0 ~first:g.n ~count:1 (Buffer.to_bytes b));
  Follower.frame fol ~vseq:1 ~first:0 ~count:0 Bytes.empty;
  let same what (f : Store.view) =
    check (f.group = v.group) "%s: at the engine's group (%d, %d)" what f.group v.group;
    check (C.F.equal (C.facts_of_view f) (C.facts_of_view v)) "%s: the engine's facts" what;
    check (C.F.equal (C.asserted_facts f) (C.asserted_facts v)) "%s: the engine's asserted facts" what;
    check (List.length (C.rules_of f) = 1) "%s: the rule in the schema" what
  in
  (match Follower.try_view fol with Some f -> same "a follower of a database with a rule" f | None -> check false "the follower holds no state");
  check (C.F.cardinal (C.user_facts v) > C.F.cardinal (C.asserted_facts v)) "rules: some facts are derived only";
  (* its states rested on the same run again (as after a merge): rebuilt from its frames *)
  Follower.runs fol ~vseq:1 ~names:(List.map (fun (lo, hi, _) -> lo, hi) runs)
    ~files:(List.map (fun (_, _, n) -> Follower.Mem (Disk.read_all Disk.real (Filename.concat sdir n))) runs);
  (match Follower.try_view fol with Some f -> same "after a new base" f | None -> check false "no state after a new base");
  Cepheus.close db;
  C.rmrf base

(* ---- the client's request ids: 0 is the server's own id (a frame that says why it closes a connection), never a
   request's, even after 2^31 requests on one connection ---- *)

let request_ids () =
  match Client.connect (Client.Unix_socket "/nonexistent/.s.cepheus.1") "t" with
  | Ok _ -> check false "ids: a connection to nothing"
  | Error _ ->
    let c =
      { Client.address = Client.Unix_socket "/nonexistent"; token = ""; program = "unit"; fd = None; tls = None; ca = None;
        cluster = None; inb = Bytes.create 16; have = 0; next_id = 0x7FFF_FFFE; out = Buffer.create 64; body = Buffer.create 64;
        session = 0; serial = 0; waiting = Hashtbl.create 1; early = Hashtbl.create 1; welcome = None; follows = []; spoken = Wire.version; members = [] }
    in
    let ids = List.init 4 (fun _ -> Client.send c (Wire.Ping "")) in
    check (not (List.mem 0 ids) && List.length (List.sort_uniq compare ids) = 4) "ids: no request takes id 0 when they wrap (%s)"
      (String.concat ", " (List.map string_of_int ids))

(* ---- protocol 2 beside protocol 1 ----
   A server speaks 1 and 2 and refuses the others; a program speaks 2, and with a server of protocol 1 only (here a
   small one of its own on a Unix socket, which refuses Hello 2 as such a server does, then welcomes Hello 1) it
   connects again in 1, and asks no question with the extension there. *)
let versions () =
  let sim = Sim_disk.create (Rng.make 7) in
  let disk = Sim_disk.disk sim in
  disk.mkdir "/v";
  let e = Result.get_ok (Engine.open_ disk "/v/shop") in
  let d = { Core.name = "shop"; index = 0; dir = "/v/shop"; view = (fun () -> Atomic.get e.published); sessions = Sessions.create ();
            more = (fun () -> []); hub = (fun () -> Live.create (Atomic.get e.published) ~tag:0 ~durable:max_int);
            files = Files.cell ~disk ~master:(fun () -> Ok (String.make 32 'k')) "/v/shop/vault" } in
  let toks = Tokens.with_tokens Tokens.empty [ { Tokens.name = "r"; hash = Tokens.hash_of_text "cph_r"; databases = [ "shop", Tokens.Read ]; admin = false } ] in
  let srv = Core.create ~server_id:"s" ~cluster_id:"c" ~dbs:[| d |] ~tokens:toks ~now:disk.now ~new_session:(fun () -> 1) () in
  let hello version =
    let out = Buffer.create 64 in
    let rec c = lazy (Core.connect srv ~flush:(fun () -> let cc = Lazy.force c in Buffer.add_buffer out cc.Core.out; Buffer.clear cc.Core.out) ~submit:(fun _ _ _ _ _ -> ())) in
    let c = Lazy.force c in
    let b = Buffer.create 64 and f = Buffer.create 64 in
    Wire.put_request b (Wire.Hello { version; token = "cph_r"; program = "t"; session = 0 });
    Wire.add_frame f ~id:1 ~kind:Wire.k_hello ~flags:0 b;
    let bytes = Buffer.to_bytes f in
    ignore (Core.input c bytes 0 (Bytes.length bytes));
    c.flush ();
    let s = Buffer.to_bytes out in
    Wire.get_reply (Bytes.get_uint8 s 8) (Bytes.get_uint8 s 9) (Codec.reader s Wire.header (Wire.u32 s 0 - 6))
  in
  let welcome = function Wire.Welcome _ -> true | _ -> false in
  check (welcome (hello 1) && welcome (hello 2) && welcome (hello 3) && welcome (hello 4)) "versions: a server speaks 1, 2, 3 and 4";
  check (match hello 5 with Wire.Err { code = "version"; _ } -> true | _ -> false) "versions: and refuses 5";
  (* a program against a server of protocol 1 *)
  let base = try Sys.getenv "CEPHEUS_TMP" with Not_found -> Filename.get_temp_dir_name () in
  let path = Filename.concat base (Printf.sprintf "cph-v1-%d.sock" (Unix.getpid ())) in
  (try Unix.unlink path with Unix.Unix_error _ -> ());
  let sock = Unix.socket ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.bind sock (Unix.ADDR_UNIX path);
  Unix.listen sock 4;
  let seen = ref [] in
  let rec read_all fd b o n = if n > 0 then (let k = Unix.read fd b o n in if k = 0 then raise End_of_file; read_all fd b (o + k) (n - k)) in
  let reply fd ~id ~flags rep =
    let b = Buffer.create 64 and f = Buffer.create 64 in
    Wire.put_reply b rep;
    Wire.add_frame f ~id ~kind:Wire.k_hello ~flags b;
    let s = Buffer.to_bytes f in
    ignore (Unix.write fd s 0 (Bytes.length s))
  in
  let old = Thread.create (fun () ->
      for _ = 1 to Wire.version do
        let fd, _ = Unix.accept ~cloexec:true sock in
        (try
           let h = Bytes.create Wire.header in
           read_all fd h 0 Wire.header;
           let body = Bytes.create (Wire.u32 h 0 - 6) in
           read_all fd body 0 (Bytes.length body);
           let id = Wire.u32 h 4 in
           match Wire.get_request Wire.k_hello (Codec.reader body 0 (Bytes.length body)) with
           | Wire.Hello hh ->
             seen := hh.version :: !seen;
             if hh.version <> 1 then reply fd ~id ~flags:Wire.f_error (Wire.Err { code = "version"; message = "this protocol is not spoken here (1 is)" })
             else begin
               reply fd ~id ~flags:0 (Wire.Welcome { server = "old"; cluster = "c"; session = 3; frame = Wire.max_frame; inflight = 16 });
               (* until the program closes *)
               (try while Unix.read fd (Bytes.create 64) 0 64 > 0 do () done with Unix.Unix_error _ -> ())
             end
           | _ -> ()
         with End_of_file | Unix.Unix_error _ -> ());
        Unix.close fd
      done) () in
  (match Client.connect (Client.Unix_socket path) "cph_r" with
   | Ok c ->
     check (c.spoken = 1 && List.rev !seen = [ 4; 3; 2; 1 ]) "versions: a program connects again in 1 to a server of 1 (spoke %s)" (String.concat "," (List.map string_of_int (List.rev !seen)));
     (* an Incr to a server of protocol 3 or older is refused in the program, never sent; a write without it is sent *)
     let db = { Client.handle = 0; group = 0; props = []; local = None; wants_local = false; retry_at = 0. } in
     check (Client.write c db [ Resolve.Incr (65536, 16, 1, None) ] = Error { code = "invalid"; message = Client.no_incr } && c.serial = 0)
       "versions: an Incr to a server of 1 is refused before it is sent";
     c.spoken <- 3;
     check (Client.write c db [ Resolve.Add (65536, 16, Int 1); Resolve.Incr (65536, 17, 1, Some (-1, 18)) ] = Error { code = "invalid"; message = Client.no_incr })
       "versions: and to a server of 3";
     Client.close c
   | Error m -> check false "versions: no connection to a server of 1: %s" m);
  Thread.join old;
  Unix.close sock;
  (try Unix.unlink path with Unix.Unix_error _ -> ())

(* ---- files through the core: Put in pieces, Load whole and in ranges, rights per kind, bounds, Erase ---- *)

let files () =
  let sim = Sim_disk.create (Rng.make 9) in
  let disk = Sim_disk.disk sim in
  disk.mkdir "/f";
  let e = Result.get_ok (Engine.open_ disk "/f/shop") in
  let d = { Core.name = "shop"; index = 0; dir = "/f/shop"; view = (fun () -> Atomic.get e.published); sessions = Sessions.create ();
            more = (fun () -> []); hub = (fun () -> Live.create (Atomic.get e.published) ~tag:0 ~durable:max_int);
            files = Files.cell ~disk ~master:(fun () -> Ok (String.make 32 'k')) "/f/shop/vault" } in
  let submit (_ : Core.db) ops by why k = let b = Engine.prepare e [| ops, by, why |] in k (Engine.commit e b).(0) in
  (* the file kinds scan and other, and a person *)
  let props = List.concat_map (fun k -> List.map (fun (f, t) -> { Schema.name = k ^ "/" ^ f; typ = t; many = false; unique = false })
                                   [ "Name", Value.Ttext; "Size", Tint; "Type", Ttext; "Owner", Tlink; "Content", Ttext ]) [ "scan"; "other" ]
              @ [ { Schema.name = "person/Name"; typ = Ttext; many = false; unique = false } ] in
  let ids, ops = Result.get_ok (Resolve.declare (Atomic.get e.published) props) in
  submit d ops 0 "declare" (fun r -> ignore (Result.get_ok r));
  let pid = List.nth ids 10 in
  let ada = ref 0 in
  submit d [ Resolve.Add (-1, pid, Text "Ada") ] 0 "ada" (fun r -> ada := List.assoc (-1) (Result.get_ok r).things);
  let ada = !ada in
  let content_of k = Option.get (Schema.by_name (Atomic.get e.published).schema (k ^ "/Content")) in
  let mk name databases = { Tokens.name; hash = Tokens.hash_of_text ("cph_" ^ name); databases; admin = false } in
  let toks =
    Tokens.with_tokens Tokens.empty
      [ mk "w" [ "shop", Tokens.Write ]; mk "r" [ "shop", Tokens.Read ];
        mk "k" [ "shop", Tokens.Kinds { read = [ "scan" ]; add = [ "scan" ] } ];
        mk "kr" [ "shop", Tokens.Kinds { read = [ "scan" ]; add = [] } ];
        mk "n" [ "shop", Tokens.Kinds { read = [ "other" ]; add = [ "other" ] } ] ]
  in
  let srv = Core.create ~server_id:"s" ~cluster_id:"c" ~dbs:[| d |] ~tokens:toks ~now:disk.now ~new_session:(let n = ref 0 in fun () -> incr n; !n) () in
  (* a connection: frames in, every reply frame out, a Load's joined *)
  let session tok =
    let out = Buffer.create 256 in
    let rec c = lazy (Core.connect srv ~flush:(fun () -> let cc = Lazy.force c in Buffer.add_buffer out cc.Core.out; Buffer.clear cc.Core.out) ~submit) in
    let c = Lazy.force c in
    let next = ref 1 in
    let frames req =
      let f = Buffer.create 64 and b = Buffer.create 64 in
      let id = !next in
      incr next;
      (match req with
       | Wire.Put p when String.length p.data > 1000 ->
         let n = String.length p.data in
         Wire.put_request b (Wire.Put { p with data = String.sub p.data 0 1000 });
         Wire.add_frame f ~id ~kind:Wire.k_put ~flags:Wire.f_more b;
         let o = ref 1000 in
         while !o < n do
           let k = min (1 + (!o * 7 mod 300_000)) (n - !o) in
           Buffer.clear b;
           Buffer.add_substring b p.data !o k;
           o := !o + k;
           Wire.add_frame f ~id ~kind:Wire.k_piece ~flags:(if !o < n then Wire.f_more else 0) b
         done
       | _ -> Wire.put_request b req; Wire.add_frame f ~id ~kind:(Wire.request_kind req) ~flags:0 b);
      Buffer.to_bytes f
    in
    let ask req =
      let bytes = frames req in
      ignore (Core.input c bytes 0 (Bytes.length bytes));
      c.flush ();
      let s = Buffer.to_bytes out in
      Buffer.clear out;
      let rec parts o acc =
        if o >= Bytes.length s then List.rev acc
        else
          let len = Wire.u32 s o in
          parts (o + 4 + len) (Wire.get_reply (Bytes.get_uint8 s (o + 8)) (Bytes.get_uint8 s (o + 9)) (Codec.reader s (o + Wire.header) (len - 6)) :: acc)
      in
      match parts 0 [] with [] -> None | [ x ] -> Some x | l -> Some (Client.join l)
    in
    ignore (ask (Wire.Hello { version = Wire.version; token = "cph_" ^ tok; program = "t"; session = 0 }));
    ask
  in
  let r = Rng.make 3 in
  let data = String.init 3_000_000 (fun i -> if i mod 3 = 0 then Char.chr (Rng.int r 256) else 'a') in
  let put ?(owner = ada) ?(name = "a.pdf") ?(kind = "scan") ?(serial = 1) ask =
    ask (Wire.Put { db = 0; serial; floor = serial; by = 7; why = "upload"; kind; name; typ = "application/pdf"; owner; cold = false; data })
  in
  let load ask ?(from = 0) ?(len = -1) ?(prop = content_of "scan") thing = ask (Wire.Load { db = 0; thing; prop; from; len }) in
  let w = session "w" in
  let f =
    match put w with
    | Some (Wire.Receipt rc) -> List.assoc (-1) rc.things
    | Some (Wire.Err e) -> check false "files: put: %s %s" e.code e.message; 0
    | _ -> check false "files: put: no receipt"; 0
  in
  let facts = Cepheus.get (Atomic.get e.published) f in
  let named n = Option.get (Schema.by_name (Atomic.get e.published).schema n) in
  check (List.assoc_opt (named "scan/Name") facts = Some (Text "a.pdf") && List.assoc_opt (named "scan/Size") facts = Some (Int 3_000_000)
         && List.assoc_opt (named "scan/Owner") facts = Some (Link ada) && List.assoc_opt (named "scan/Type") facts = Some (Text "application/pdf"))
    "files: a put's facts";
  check (load w f = Some (Wire.Data data)) "files: loaded whole";
  for _ = 1 to 20 do
    let from = Rng.int r 3_000_000 in
    let len = Rng.int r (min 2_500_000 (3_000_000 - from)) in
    check (load w ~from ~len f = Some (Wire.Data (String.sub data from len))) "files: a range %d+%d" from len
  done;
  check (load w ~from:3_000_000 ~len:0 f = Some (Wire.Data "")) "files: an empty range at the end";
  check (match load w ~from:2_999_999 ~len:2 f with Some (Wire.Err { code = "invalid"; _ }) -> true | _ -> false) "files: a range past the end";
  (* sent again with its serial (a broken connection): applied once *)
  check (match put w with Some (Wire.Receipt rc) -> List.assoc (-1) rc.things = f | _ -> false) "files: a put sent again is answered with its receipt";
  (* rights per kind *)
  let code = function Some (Wire.Err e) -> e.code | Some (Wire.Receipt _) -> "receipt" | Some (Wire.Data _) -> "data" | _ -> "none" in
  List.iter
    (fun (tok, want_put, want_load) ->
      let a = session tok in
      check (code (put ~serial:5 a) = want_put) "files: %s puts: %s" tok want_put;
      check (code (load a f) = want_load) "files: %s loads: %s" tok want_load)
    [ "r", "denied", "data"; "k", "receipt", "data"; "kr", "denied", "data"; "n", "denied", "denied" ];
  (* the bounds and the kind, checked before a byte is stored *)
  check (code (put ~serial:2 ~kind:"nope" w) = "invalid") "files: an undeclared file kind";
  check (code (put ~serial:3 ~kind:"person" w) = "invalid") "files: a kind that is not a file kind";
  check (code (put ~serial:4 ~owner:999_999 w) = "invalid") "files: an owner that is no thing";
  check (code (put ~serial:6 ~name:(String.make 5000 'x') w) = "too_large") "files: a name too long";
  check (code (load w ~prop:(named "scan/Name") f) = "invalid") "files: a load by another property than Content";
  check (code (load w ada) = "missing") "files: a thing without a file";
  (* at most four files at once on a connection; the pieces of a refused Put are dropped *)
  let c5 = session "w" in
  let starts = List.init 5 (fun i ->
      let b = Buffer.create 64 and fr = Buffer.create 64 in
      Wire.put_request b (Wire.Put { db = 0; serial = 10 + i; floor = 10; by = 0; why = ""; kind = "scan"; name = "p"; typ = "t"; owner = 0; cold = false; data = "x" });
      Wire.add_frame fr ~id:(100 + i) ~kind:Wire.k_put ~flags:Wire.f_more b;
      Buffer.to_bytes fr) in
  ignore c5;
  let sess = Core.connect srv ~flush:(fun () -> ()) ~submit in
  let hb = Buffer.create 64 and hf = Buffer.create 64 in
  Wire.put_request hb (Wire.Hello { version = Wire.version; token = "cph_w"; program = "t"; session = 0 });
  Wire.add_frame hf ~id:1 ~kind:Wire.k_hello ~flags:0 hb;
  let hbytes = Buffer.to_bytes hf in
  ignore (Core.input sess hbytes 0 (Bytes.length hbytes));
  List.iter (fun b -> ignore (Core.input sess b 0 (Bytes.length b))) starts;
  check (Hashtbl.length sess.Core.puts = Files.max_puts) "files: %d puts open at once at most" Files.max_puts;
  Core.disconnect sess;
  (* a token whose right to write goes in the middle of a put: its next piece ends the put, refused *)
  let out = Buffer.create 64 in
  let rec cl = lazy (Core.connect srv ~flush:(fun () -> let cc = Lazy.force cl in Buffer.add_buffer out cc.Core.out; Buffer.clear cc.Core.out) ~submit) in
  let cl = Lazy.force cl in
  let frame ~id ~kind ~flags req =
    let b = Buffer.create 64 and fr = Buffer.create 64 in
    (match req with Some r -> Wire.put_request b r | None -> Buffer.add_string b "more bytes");
    Wire.add_frame fr ~id ~kind ~flags b;
    let x = Buffer.to_bytes fr in
    ignore (Core.input cl x 0 (Bytes.length x));
    cl.flush ()
  in
  frame ~id:1 ~kind:Wire.k_hello ~flags:0 (Some (Wire.Hello { version = Wire.version; token = "cph_w"; program = "t"; session = 0 }));
  frame ~id:7 ~kind:Wire.k_put ~flags:Wire.f_more
    (Some (Wire.Put { db = 0; serial = 1; floor = 1; by = 0; why = ""; kind = "scan"; name = "n"; typ = "t"; owner = 0; cold = false; data = "x" }));
  Atomic.set srv.tokens (Tokens.with_tokens Tokens.empty (mk "w" [ "shop", Tokens.Read ] :: List.filter (fun (t : Tokens.token) -> t.name <> "w") toks.tokens));
  Buffer.clear out;
  frame ~id:7 ~kind:Wire.k_piece ~flags:0 None;
  let s = Buffer.to_bytes out in
  check (Bytes.length s > 10 && Bytes.get_uint8 s 9 land Wire.f_error <> 0 && Hashtbl.length cl.Core.puts = 0)
    "files: a right to write gone in the middle of a put ends it, refused";
  Atomic.set srv.tokens toks;
  (* erasing an owner: a right to write the whole database *)
  let erase tok = code (Some (match (session tok) (Wire.Erase { db = 0; owner = ada }) with Some x -> x | None -> Wire.Err { code = "none"; message = "" })) in
  check (erase "k" = "denied" && erase "r" = "denied") "files: erasing needs a right to write every kind";
  check (code (Some (match (session "w") (Wire.Erase { db = 0; owner = 0 }) with Some x -> x | None -> Wire.Err { code = "none"; message = "" })) = "invalid")
    "files: the database's own key (owner 0) is never erased";
  check (match (session "w") (Wire.Erase { db = 0; owner = ada }) with Some Wire.Erased -> true | _ -> false) "files: erased";
  check (code (load w f) = "erased") "files: an erased owner's file: erased";
  check (code (put ~serial:8 w) = "erased") "files: no new file of an erased owner";
  Engine.close e

(* every request of the files read back as written, and any change of its bytes read or refused, nothing else *)
let files_wire () =
  let r = Rng.make 13 in
  let rnd n = String.init n (fun _ -> Char.chr (Rng.int r 256)) in
  let req () =
    match Rng.int r 4 with
    | 0 -> Wire.Put { db = Rng.int r 9; serial = Rng.int r 1000; floor = Rng.int r 1000; by = Rng.int r 100 - 50; why = rnd (Rng.int r 9);
                      kind = rnd (Rng.int r 9); name = rnd (Rng.int r 30); typ = rnd (Rng.int r 9); owner = Rng.int r 100_000;
                      cold = Rng.int r 2 = 0; data = rnd (Rng.int r 100) }
    | 1 -> Wire.Piece (rnd (Rng.int r 100))
    | 2 -> Wire.Load { db = Rng.int r 9; thing = Rng.int r 100_000; prop = Rng.int r 300; from = Rng.int r 1_000_000; len = Rng.int r 1000 - 1 }
    | _ -> Wire.Erase { db = Rng.int r 9; owner = Rng.int r 100_000 }
  in
  let n = ref 0 and m = ref 0 in
  for _ = 1 to 3000 do
    let q = req () in
    let b = Buffer.create 64 in
    Wire.put_request b q;
    let s = Buffer.to_bytes b in
    let kind = Wire.request_kind q in
    (match Wire.get_request kind (Codec.reader s 0 (Bytes.length s)) with
     | q' -> if q' = q then incr n else check false "files wire: a request read back otherwise"
     | exception _ -> check false "files wire: a request does not read back");
    for _ = 1 to 8 do
      let t = Bytes.copy s in
      let t =
        match Rng.int r 3 with
        | 0 when Bytes.length t > 0 -> let i = Rng.int r (Bytes.length t) in Bytes.set t i (Char.chr (Rng.int r 256)); t
        | 1 -> Bytes.sub t 0 (Rng.int r (Bytes.length t + 1))
        | _ -> Bytes.cat t (Bytes.of_string (rnd (1 + Rng.int r 5)))
      in
      match Wire.get_request kind (Codec.reader t 0 (Bytes.length t)) with
      | _ -> incr m
      | exception (Codec.Short | Wire.Malformed _) -> incr m
      | exception e -> check false "files wire: a changed request raised %s" (Printexc.to_string e)
    done
  done;
  check (!n = 3000 && !m = 24000) "files wire: 3000 requests read back, 24000 changed ones read or refused"

(* ---- what a request does not expect: it ends where the peer is served, never the thread ---- *)

(* an exception whose text is a client's bytes as they came *)
exception Raw of string

let () = Printexc.register_printer (function Raw s -> Some s | _ -> None)

let internal_message = "the server failed (its log says why): the connection is closed"

(* the frames of [s], each whole: (id, kind, flags, body); None when the bytes do not end at a frame's end *)
let frames_of s =
  let rec go o acc =
    if o = Bytes.length s then Some (List.rev acc)
    else if Bytes.length s - o < Wire.header then None
    else
      let len = Wire.u32 s o in
      if len < 6 || o + 4 + len > Bytes.length s then None
      else go (o + 4 + len) ((Wire.u32 s (o + 4), Bytes.get_uint8 s (o + 8), Bytes.get_uint8 s (o + 9), Bytes.sub s (o + Wire.header) (len - 6)) :: acc)
  in
  go 0 []

let reply_of (_, kind, flags, body) = try Some (Wire.get_reply kind flags (Codec.reader body 0 (Bytes.length body))) with _ -> None
let is_internal ~id ((i, _, flags, _) as f) =
  i = id && flags land Wire.f_more = 0 && match reply_of f with Some (Wire.Err { code = "internal"; message }) -> message = internal_message | _ -> false

let contains s sub =
  let n = String.length sub in
  let rec go i = i + n <= String.length s && (String.sub s i n = sub || go (i + 1)) in
  go 0

(* what [f] writes on the standard error *)
let with_stderr f =
  let base = Option.value (Sys.getenv_opt "CEPHEUS_TMP") ~default:(Filename.get_temp_dir_name ()) in
  let path = Filename.concat base (Printf.sprintf "cepheus-guard-%d.err" (Unix.getpid ())) in
  let fd = Unix.openfile path [ O_WRONLY; O_CREAT; O_TRUNC; O_CLOEXEC ] 0o600 in
  flush stderr;
  let saved = Unix.dup ~cloexec:true Unix.stderr in
  Unix.dup2 fd Unix.stderr;
  Unix.close fd;
  let r = Fun.protect ~finally:(fun () -> flush stderr; Unix.dup2 saved Unix.stderr; Unix.close saved) f in
  let s = In_channel.with_open_bin path In_channel.input_all in
  Sys.remove path;
  r, s

type gconn = { gc : Core.conn; send : Wire.request -> int * Core.input option; take : unit -> (int * int * int * Bytes.t) list option;
               bad_flush : bool ref; bad_wake : bool ref; closed : int ref }

let guard () =
  let sim = Sim_disk.create (Rng.make 17) in
  let disk = Sim_disk.disk sim in
  disk.mkdir "/g";
  let e = Result.get_ok (Engine.open_ disk "/g/shop") in
  (* the database's view raises what [boom] holds: a bug of the request that reads it *)
  let boom = ref None in
  let view () = (match !boom with Some x -> raise x | None -> ()); Atomic.get e.published in
  let v0 = Atomic.get e.published in
  let hub = Live.create v0 ~tag:v0.group ~durable:max_int in
  let d = { Core.name = "shop"; index = 0; dir = "/g/shop"; view; sessions = Sessions.create (); more = (fun () -> []); hub = (fun () -> hub);
            files = Files.cell ~disk ~master:(fun () -> Ok (String.make 32 'k')) "/g/shop/vault" } in
  (* the writer, its groups given to the hub at once; [handoff] makes the next hand-off fail before the write is taken *)
  let handoff = ref None in
  let submit (_ : Core.db) ops by why k =
    (match !handoff with Some x -> handoff := None; raise x | None -> ());
    let b = Engine.prepare e [| ops, by, why |] in
    let r = (Engine.commit e b).(0) in
    if b.count > 0 then Live.frame hub ~tag:b.after.group (List.rev b.groups) b.after;
    k r
  in
  let props = [ { Schema.name = "person/name"; typ = Value.Ttext; many = false; unique = false };
                { Schema.name = "person/score"; typ = Tint; many = false; unique = false } ] in
  let ids, ops = Result.get_ok (Resolve.declare (Atomic.get e.published) props) in
  submit d ops 0 "declare" (fun r -> ignore (Result.get_ok r));
  let pname = List.nth ids 0 and pscore = List.nth ids 1 in
  let mk name = { Tokens.name; hash = Tokens.hash_of_text ("cph_" ^ name); databases = [ "shop", Tokens.Write ]; admin = false } in
  let srv = Core.create ~server_id:"s" ~cluster_id:"c" ~dbs:[| d |] ~tokens:(Tokens.with_tokens Tokens.empty [ mk "w" ]) ~now:disk.now
              ~new_session:(let n = ref 0 in fun () -> incr n; !n) () in
  let conn ?(session = 0) () =
    let out = Buffer.create 256 in
    let bad_flush = ref false and bad_wake = ref false and closed = ref 0 in
    let rec c =
      lazy
        (Core.connect srv
           ~wake:(fun () -> if !bad_wake then raise (Sys_error "Thread.create: Resource temporarily unavailable"))
           ~close:(fun () -> incr closed)
           ~flush:(fun () ->
             if !bad_flush then (bad_flush := false; raise (Raw "the transport failed"));
             let cc = Lazy.force c in
             Buffer.add_buffer out cc.Core.out;
             Buffer.clear cc.Core.out)
           ~submit)
    in
    let c = Lazy.force c in
    let next = ref 1 in
    let send req =
      let id = !next in
      incr next;
      let b = Buffer.create 64 and f = Buffer.create 64 in
      Wire.put_request b req;
      Wire.add_frame f ~id ~kind:(Wire.request_kind req) ~flags:0 b;
      let bytes = Buffer.to_bytes f in
      match Core.input c bytes 0 (Bytes.length bytes) with
      | _, why -> id, Some why
      | exception x -> check false "guard: request %d raised %s out of Core.input" id (Printexc.to_string x); id, None
    in
    (* every frame given since, the pushes too *)
    let take () =
      ignore (Core.move_pushes c);
      Buffer.add_buffer out c.out;
      Buffer.clear c.out;
      let s = Buffer.to_bytes out in
      Buffer.clear out;
      frames_of s
    in
    let g = { gc = c; send; take; bad_flush; bad_wake; closed } in
    ignore (send (Wire.Hello { version = Wire.version; token = "cph_w"; program = "t"; session }));
    ignore (take ());
    g
  in
  let get = Wire.Get { db = 0; thing = Schema.first_thing } in
  (* a request that raises: answered internal on its id, nothing more, the connection closed; the first one's line in
     the log, escaped *)
  let crashes =
    [ Raw "x\ncepheus: a forged line\027[2J"; Invalid_argument "index out of bounds"; Not_found; Division_by_zero; Out_of_memory;
      Stack_overflow; Sys_error "/secret/data/shop: Permission denied"; Failure "a bug" ]
  in
  List.iteri
    (fun i x ->
      let g = conn () in
      boom := Some x;
      let (id, why), log = with_stderr (fun () -> g.send get) in
      boom := None;
      let what = Printexc.to_string x in
      (match g.take () with
       | Some [ f ] ->
         check (is_internal ~id f && why = Some Core.Shut) "guard: a request that raised %s: answered internal, the connection closed" what;
         let m = match reply_of f with Some (Wire.Err e) -> e.message | _ -> "" in
         check (not (List.exists (contains m) [ what; "secret"; "forged"; "Raised"; "index"; "memory"; "overflow" ])) "guard: nothing of %s told the client" what
       | Some fs -> check false "guard: a request that raised %s: %d frames" what (List.length fs)
       | None -> check false "guard: a request that raised %s: a frame not whole" what);
      if i = 0 then begin
        let lines = List.filter (( <> ) "") (String.split_on_char '\n' log) in
        check
          (match lines with
           | [ l ] -> String.starts_with ~prefix:"cepheus: connection" l && contains l "x\\010cepheus: a forged line\\027[2J" && not (String.contains l '\027')
           | _ -> false)
          "guard: the failure in one line of the log, the client's bytes escaped (%S)" log
      end)
    crashes;
  (* rows over a MiB, then a failure between two frames of their reply: the frames sent are whole, the error ends them *)
  let text = String.make 48 'n' in
  for k = 0 to 24 do
    submit d (List.init 1000 (fun j -> Resolve.Add (-(j + 1), pname, Value.Text (Printf.sprintf "%s %d %d" text k j)))) 0 "rows" (fun r -> ignore (Result.get_ok r))
  done;
  let names = { Query.vars = 2; where = [ { Query.e = Var 0; p = pname; v = Var 1 } ]; ranges = [] } in
  let g = conn () in
  g.bad_flush := true;
  let id, why = g.send (Wire.Find { db = 0; query = names; select = Wire.Give [||]; extra = []; order = Top.none }) in
  (match g.take () with
   | Some ((first :: _ :: _) as fs) ->
     let last = List.nth fs (List.length fs - 1) in
     let (i1, _, fl1, _) = first in
     check (i1 = id && fl1 land Wire.f_more <> 0 && is_internal ~id last && why = Some Core.Shut && List.length fs = 2)
       "guard: a reply cut between its frames: whole frames, then internal on its id (%d frames)" (List.length fs)
   | Some fs -> check false "guard: a reply cut between its frames: %d frames" (List.length fs)
   | None -> check false "guard: a reply cut between its frames: a frame not whole");
  (* a write whose hand-off fails is not taken: the connection's flight and the session's left empty, the write sent
     again on a new connection applied once *)
  let a = conn () in
  let session = a.gc.session in
  let w = Wire.Write { db = 0; serial = 1; floor = 1; by = 0; why = "once"; ops = [ Resolve.Add (-1, pname, Value.Text "once") ] } in
  handoff := Some (Sys_error "Thread.create: Resource temporarily unavailable");
  let id, why = a.send w in
  handoff := None;
  (match a.take () with
   | Some [ f ] -> check (is_internal ~id f && why = Some Core.Shut && a.gc.inflight = 0) "guard: a hand-off that failed: internal, nothing in flight (%d)" a.gc.inflight
   | _ -> check false "guard: a hand-off that failed: not one frame");
  let b = conn ~session () in
  let id, _ = b.send w in
  (match b.take () with
   | Some [ f ] -> check (match reply_of f with Some (Wire.Receipt _) -> true | _ -> false) "guard: the write sent again after a failed hand-off is applied"
   | Some fs -> check false "guard: the write sent again after a failed hand-off: %d frames (none: it waits for a write never taken)" (List.length fs)
   | None -> check false "guard: the write sent again: a frame not whole");
  ignore id;
  let once = { Query.vars = 1; where = [ { Query.e = Var 0; p = pname; v = Val (Value.Text "once") } ]; ranges = [] } in
  check ((match Cepheus.find (Atomic.get e.published) once with Ok l -> List.length l | Error _ -> -1) = 1) "guard: the write sent again is applied once";
  (* a write's reply that fails, in the thread that ends the write: that connection ends (internal, at its end), its
     flight empty; the thread goes on *)
  let a = conn () in
  a.bad_flush := true;
  let id, why = a.send (Wire.Write { db = 0; serial = 0; floor = 0; by = 0; why = "reply"; ops = [ Resolve.Add (-1, pscore, Value.Int 7) ] }) in
  Core.ending a.gc;
  (match a.take () with
   | Some [ r; f ] ->
     check (match reply_of r with Some (Wire.Receipt _) -> true | _ -> false) "guard: a reply that failed to be sent: its frame whole (id %d)" id;
     check (is_internal ~id:0 f && !(a.closed) = 1 && a.gc.inflight = 0 && why <> None)
       "guard: a reply that failed: the connection told internal and closed, nothing in flight (%d closes, %d in flight)" !(a.closed) a.gc.inflight
   | Some fs -> check false "guard: a reply that failed: %d frames" (List.length fs)
   | None -> check false "guard: a reply that failed: a frame not whole");
  (* a push that fails (the thread of its pushes not made) ends its own connection, never the hub: another watch of the
     question gets every change *)
  let scores = { Query.vars = 2; where = [ { Query.e = Var 0; p = pscore; v = Var 1 } ]; ranges = [] } in
  let watch g = ignore (g.send (Wire.Watch { db = 0; query = scores; select = Wire.Give [||]; from = 0; wextra = [] })); ignore (g.take ()) in
  let a = conn () and b = conn () and wr = conn () in
  watch a;
  watch b;
  a.bad_wake := true;
  let changes g =
    match g.take () with
    | Some fs -> List.length (List.filter (fun (_, kind, flags, _) -> kind = Wire.k_watch && flags land Wire.f_error = 0) fs)
    | None -> -1
  in
  let write v = ignore (wr.send (Wire.Write { db = 0; serial = 0; floor = 0; by = 0; why = "push"; ops = [ Resolve.Add (-1, pscore, Value.Int v) ] })) in
  write 8;
  check (!(a.closed) = 1) "guard: a push that failed closes its connection (%d)" !(a.closed);
  Core.ending a.gc;
  check (match a.take () with Some fs -> List.exists (is_internal ~id:0) fs | None -> false) "guard: a push that failed: internal at the connection's end";
  let n1 = changes b in
  write 9;
  let n2 = changes b in
  check (n1 = 1 && n2 = 1) "guard: beside a push that failed, the other watch gets every change (%d, %d)" n1 n2;
  (* a watched question that fails at a frame (a view that lost a text its facts cite: a bug) ends its own watches,
     internal; the other questions go on *)
  let ada = ref 0 in
  submit d [ Resolve.Add (-1, pname, Value.Text "Ada") ] 0 "ada" (fun r -> ada := List.assoc (-1) (Result.get_ok r).things);
  let v = Atomic.get e.published in
  let h = Live.create v ~tag:v.group ~durable:max_int in
  let got1 = ref [] and got2 = ref [] in
  let q1 = { Query.vars = 3; where = [ { Query.e = Var 0; p = pscore; v = Var 1 }; { Query.e = Var 0; p = pname; v = Var 2 } ]; ranges = [] } in
  ignore (Live.subscribe h q1 (Wire.Give [| 2 |]) ~from:0 ~emit:(fun m -> got1 := m :: !got1; true));
  ignore (Live.subscribe h scores (Wire.Give [| 1 |]) ~from:0 ~emit:(fun m -> got2 := m :: !got2; true));
  let bt = Engine.prepare e [| [ Resolve.Add (!ada, pscore, Value.Int 3) ], 0, "frame" |] in
  ignore (Engine.commit e bt);
  let bad = { bt.after with Store.dict = (Store.empty ()).dict } in
  (match Live.frame h ~tag:bt.after.group (List.rev bt.groups) bad with
   | () ->
     check (match !got1 with Live.Ended { code = "internal"; _ } :: _ -> true | _ -> false) "guard: a watched question that failed at a frame: its watch ended internal";
     check (match !got2 with Live.Change { added = [ [| Value.Int 3 |] ]; _ } :: _ -> true | _ -> false) "guard: beside it, another question's watch gets its change"
   | exception x -> check false "guard: a watched question's failure at a frame left the hub: %s" (Printexc.to_string x));
  (* the hub's thread failing outside one question: every watch ends internal, and a watch made after starts at the
     frame's state, then gets its changes *)
  got2 := [];
  let bt = Engine.prepare e [| [ Resolve.Add (!ada, pscore, Value.Int 4) ], 0, "broken" |] in
  ignore (Engine.commit e bt);
  ignore (with_stderr (fun () -> Live.broken h (Failure "a bug of the hub") (Some (bt.after, bt.after.group))));
  check (match !got2 with [ Live.Ended { code = "internal"; _ } ] -> true | _ -> false) "guard: the hub's failure ends its watches internal";
  let got3 = ref [] in
  ignore (Live.subscribe h scores (Wire.Give [| 1 |]) ~from:0 ~emit:(fun m -> got3 := m :: !got3; true));
  let bt = Engine.prepare e [| [ Resolve.Add (!ada, pscore, Value.Int 5) ], 0, "after" |] in
  ignore (Engine.commit e bt);
  Live.frame h ~tag:bt.after.group (List.rev bt.groups) bt.after;
  let rows = function Live.Answer a -> List.sort compare a.rows | Live.Change ch -> List.sort compare ch.added | _ -> [] in
  check
    (match List.rev !got3 with
     | [ a; c ] -> List.mem [| Value.Int 4 |] (rows a) && rows c = [ [| Value.Int 5 |] ]
     | l -> ignore l; false)
    "guard: after the hub's failure, a new watch starts at the frame's state and gets the next change (%d messages)" (List.length !got3);
  (* a client that makes failures in a loop writes a line a second: the next one counts those left out *)
  let (), log = with_stderr (fun () -> for i = 1 to 50 do Fault.log "a test" (Failure (string_of_int i)) done) in
  Fault.last := neg_infinity;
  let (), log2 = with_stderr (fun () -> Fault.log "a test" (Failure "51")) in
  let lines s = List.filter (( <> ) "") (String.split_on_char '\n' s) in
  check (List.length (lines log) <= 1 && contains log2 "(and " && List.length (lines log2) = 1)
    "guard: failures in a loop, at most a line a second, the next one counting those left out (%S, %S)" log log2;
  Engine.close e

let () =
  toml ();
  config ();
  versions ();
  tokens ();
  wire ();
  origins ();
  rights ();
  tokens_golden ();
  rights_kinds ();
  rights_derived ();
  rights_equality ();
  fdpass ();
  followed_rules ();
  request_ids ();
  files ();
  files_wire ();
  (* last: its questions spawn domains, after which no test may fork *)
  guard ();
  C.finish "server unit"
