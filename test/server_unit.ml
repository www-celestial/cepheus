(* Unit and property tests of the server's parts: TOML, cluster.toml's rules, tokens, the wire codings (every request
   and reply, round trips of random values), the origin of a group, the session table and its checkpoint, the
   rights of every token against every request (G16), through the server's core, and what local readers need from
   the system: descriptors passed over a socket (random messages and descriptors, read in random pieces) and the
   visibility page shared read-only. *)

open Cepheus
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
    Wire.Find { db = 0; query = q; select }
  | 4 ->
    let op () = match Rng.int r 4 with
      | 0 -> Resolve.Add (Rng.int r 100 - 50, Rng.int r 40, rand_value r)
      | 1 -> Resolve.Retract (Rng.int r 100, Rng.int r 40, rand_value r)
      | 2 -> Resolve.Expect (Rng.int r 100, Rng.int r 40, Some (rand_value r))
      | _ -> Resolve.Expect (Rng.int r 100, Rng.int r 40, None) in
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
      | _ -> ok := false
      | exception (Codec.Short | Wire.Malformed _) -> ()
    end
  done;
  check !ok "wire: 5,000 random requests round trip, every cut refused";
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
        | Err _ -> Wire.k_get in
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
         more = (fun () -> []) }
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
      "Find", Wire.Find { db; query = q; select = Wire.Give [||] }, `Read;
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

let () =
  toml ();
  config ();
  tokens ();
  wire ();
  origins ();
  rights ();
  fdpass ();
  followed_rules ();
  C.finish "server unit"
