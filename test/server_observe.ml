(* What the server shows of its own time: the histograms' percentiles against the sorted values (within their stated
   error), the window of Timings (slices in and out, records from several domains and threads at once, a status read
   meanwhile), Prometheus's text format parsed back by a parser of its own (the exposition format's grammar: HELP and
   TYPE first, a family's lines together, names and labels, escapes, values), the shapes of questions and writes
   (no constant in them), cluster.toml's [log] slow_ms; then a real server (`cepheus serve`, slow_ms = 1): a line for
   each slow question (a Find, a Watch, one ended by its timeout) and each slow write, with the database, the token's
   name, the candidates, the rows, the outcome; no value of the data and no token in its log (a search for each finds
   none), nor in `cepheus status --format prometheus`; status's lines, the earlier ones in their order and the new
   ones after them.

     server_observe.exe DIR *)

open Cepheus
open Cepheus_server
module C = Check
module Top = Question.Top
module Ask = Question.Ask

let ( // ) = Filename.concat
let bin = Filename.dirname (Filename.dirname Sys.executable_name) // "bin/main.exe"
let write_file path s = Out_channel.with_open_bin path (fun oc -> output_string oc s)
let read_file path = In_channel.with_open_bin path In_channel.input_all

let contains s sub =
  let n = String.length s and m = String.length sub in
  let rec go i = i + m <= n && (String.sub s i m = sub || go (i + 1)) in
  m = 0 || go 0

let lines s = List.filter (( <> ) "") (String.split_on_char '\n' s)

(* ---- the histograms against the sorted values ---- *)

let () =
  let r = Rng.make 77 in
  List.iter
    (fun bits ->
      for round = 1 to 40 do
        let n = 1 + Rng.int r 5000 in
        (* log-uniform up to 2^(10 + round mod 25) microseconds, and some exact small ones *)
        let top = 10 + (round mod 25) in
        let xs = Array.init n (fun _ -> if Rng.int r 10 = 0 then Rng.int r 300 else int_of_float (2. ** (float (Rng.int r 1_000_000) /. 1e6 *. float top))) in
        let h = Histogram.create ~bits () in
        Array.iter (Histogram.record h) xs;
        let s = Array.copy xs in
        Array.sort compare s;
        let err = 1. /. float (1 lsl bits) in
        List.iter
          (fun q ->
            let want = max 1 (int_of_float (Float.ceil (q *. float n))) in
            let exact = s.(want - 1) and p = Histogram.percentile h q in
            C.check (p >= exact && float p <= (float exact *. (1. +. err)) +. 1. && p <= s.(n - 1))
              "%d bits, %d values: p%g is %d, the sorted values' %d (within 1/%d above)" bits n (q *. 100.) p exact (1 lsl bits))
          [ 0.; 0.5; 0.9; 0.99; 0.999; 1. ];
        C.check (Histogram.max h = s.(n - 1) && Histogram.total h = n && Histogram.sum h = Array.fold_left ( + ) 0 xs)
          "%d bits: max, total and sum exact" bits;
        (* two halves merged: the same percentiles *)
        let a = Histogram.create ~bits () and b = Histogram.create ~bits () and m = Histogram.create ~bits () in
        Array.iteri (fun i x -> Histogram.record (if i mod 2 = 0 then a else b) x) xs;
        Histogram.merge_into m a;
        Histogram.merge_into m b;
        C.check (List.for_all (fun q -> Histogram.percentile m q = Histogram.percentile h q) [ 0.5; 0.99; 1. ] && Histogram.total m = n)
          "%d bits: halves merged give the same percentiles" bits
      done)
    [ 4; 5; 7 ];
  (* a value past 2^34 us: counted in the last bucket, the maximum exact *)
  let h = Histogram.create ~bits:5 () in
  Histogram.record h (1 lsl 40);
  C.check (Histogram.max h = 1 lsl 40 && Histogram.percentile h 1. = 1 lsl 40) "a value past 2^34 us keeps its maximum";
  C.check (match Histogram.merge_into (Histogram.create ~bits:5 ()) (Histogram.create ~bits:7 ()) with () -> false | exception Invalid_argument _ -> true)
    "histograms of two precisions are not merged"

(* ---- the window ---- *)

let status_of l k = match List.assoc_opt k l with Some v -> int_of_string v | None -> C.fail "no line %s" k; -1

let () =
  let t = Timings.create ~slow_ms:5 [| "a"; "b" |] in
  let s = Timings.slice_us in
  (* slice 10: 1..100 us; slice 13: 1000; slice 16: 5000 (slow) *)
  for i = 1 to 100 do ignore (Timings.question t 0 ~now:(10 * s) i) done;
  ignore (Timings.question t 0 ~now:((13 * s) + 5) 1000);
  C.check (Timings.question t 0 ~now:(16 * s) 5000) "5 ms is slow at slow_ms = 5";
  C.check (not (Timings.question t 0 ~now:(16 * s) 4999)) "4.999 ms is not";
  let l = Timings.lines t 0 ~now:((16 * s) + 1) in
  (* the window at slice 16 holds slices 11 to 16: 1000, 5000 and 4999 *)
  C.check (status_of l "database.a.question_samples" = 3 && status_of l "database.a.questions" = 103) "the window: the slices of the last minute, the count since the start";
  C.check (status_of l "database.a.question_us_max" = 5000 && status_of l "database.a.questions_slow" = 1) "the window's max, the slow ones";
  C.check (status_of l "database.a.question_us_sum" = 5050 + 1000 + 5000 + 4999) "the sum since the start";
  let p50 = status_of l "database.a.question_us_p50" in
  C.check (p50 >= 4999 && p50 <= 4999 + (4999 / 32) + 1) "the window's median (%d)" p50;
  let l = Timings.lines t 0 ~now:(15 * s) in
  C.check (status_of l "database.a.question_samples" = 101 || status_of l "database.a.question_samples" = 1)
    "an earlier window";
  let l = Timings.lines t 0 ~now:(10 * s) in
  C.check (status_of l "database.a.question_samples" = 100 && status_of l "database.a.question_us_p99" = 99) "slice 10 alone: p99 of 1..100 is 99";
  let l = Timings.lines t 0 ~now:(30 * s) in
  C.check (status_of l "database.a.question_samples" = 0 && status_of l "database.a.question_us_p50" = 0) "an old window: empty";
  let l = Timings.lines t 1 ~now:(16 * s) in
  C.check (status_of l "database.b.questions" = 0 && status_of l "database.b.writes" = 0) "the other database: nothing";
  (* a slice taken again a turn later (slice 16 + 6 = 22): begun again *)
  ignore (Timings.write t 1 ~now:(16 * s) 7);
  ignore (Timings.write t 1 ~now:(22 * s) 9);
  let l = Timings.lines t 1 ~now:(22 * s) in
  C.check (status_of l "database.b.write_samples" = 1 && status_of l "database.b.write_us_max" = 9 && status_of l "database.b.writes" = 2)
    "a slice of the next turn begun again"

(* records from 4 domains of 3 threads each, a status read meanwhile: every value counted once *)
let () =
  let t = Timings.create [| "a" |] in
  let per = 100_000 and stop = Atomic.make false and reads = Atomic.make 0 in
  let reader =
    Domain.spawn (fun () ->
        while not (Atomic.get stop) do
          let l = Timings.lines t 0 ~now:(Histogram.now_us ()) in
          let p50 = status_of l "database.a.question_us_p50" and p99 = status_of l "database.a.question_us_p99" in
          if p50 > p99 then C.fail "a status read while domains record: p50 %d above p99 %d" p50 p99;
          Atomic.incr reads
        done)
  in
  let domains =
    List.init 4 (fun d ->
        Domain.spawn (fun () ->
            let ths = List.init 3 (fun k -> Thread.create (fun () -> for i = 1 to per do ignore (Timings.question t 0 ~now:(Histogram.now_us ()) (1 + ((i * (d + k + 1)) mod 977))) done) ()) in
            List.iter Thread.join ths))
  in
  List.iter Domain.join domains;
  Atomic.set stop true;
  Domain.join reader;
  let l = Timings.lines t 0 ~now:(Histogram.now_us ()) in
  C.check (status_of l "database.a.questions" = 12 * per) "12 threads on 4 domains: %d values counted, %d recorded" (status_of l "database.a.questions") (12 * per);
  C.check (status_of l "database.a.question_samples" <= 12 * per && status_of l "database.a.question_us_max" <= 977) "the window holds them (%d)" (status_of l "database.a.question_samples");
  C.check (Atomic.get reads > 0) "status read %d times meanwhile" (Atomic.get reads)

(* ---- Prometheus's text format, parsed back ---- *)

type psample = { pname : string; plabels : (string * string) list; pvalue : float }

(* the exposition format's text, version 0.0.4: Some (families in order, their types, samples), or a failure *)
let parse_prometheus text =
  let types = Hashtbl.create 32 and helps = Hashtbl.create 32 and samples = ref [] and order = ref [] in
  let bad fmt = Printf.ksprintf (fun m -> failwith m) fmt in
  let name_ok s =
    s <> ""
    && String.for_all (fun c -> (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c = '_' || c = ':') s
    && not (s.[0] >= '0' && s.[0] <= '9')
  in
  let family_of n =
    let strip suf = let k = String.length suf in if String.length n > k && String.sub n (String.length n - k) k = suf then Some (String.sub n 0 (String.length n - k)) else None in
    match List.find_map (fun suf -> match strip suf with Some b when Hashtbl.find_opt types b = Some "summary" -> Some b | _ -> None) [ "_sum"; "_count" ] with
    | Some b -> b
    | None -> n
  in
  let seen_done = Hashtbl.create 32 and current = ref "" in
  let enter f =
    if f <> !current then begin
      if Hashtbl.mem seen_done f then bad "family %s in two groups" f;
      if !current <> "" then Hashtbl.replace seen_done !current ();
      current := f;
      order := f :: !order
    end
  in
  List.iter
    (fun line ->
      if String.length line >= 7 && String.sub line 0 7 = "# HELP " then begin
        match String.index_from_opt line 7 ' ' with
        | Some i ->
          let n = String.sub line 7 (i - 7) in
          if not (name_ok n) then bad "HELP of a bad name %S" n;
          if Hashtbl.mem types n || Hashtbl.mem helps n then bad "HELP of %s after its TYPE or twice" n;
          enter n;
          Hashtbl.replace helps n ()
        | None -> bad "a HELP line without text: %S" line
      end
      else if String.length line >= 7 && String.sub line 0 7 = "# TYPE " then begin
        match String.split_on_char ' ' line with
        | [ _; _; n; ty ] ->
          if not (name_ok n) then bad "TYPE of a bad name %S" n;
          if not (List.mem ty [ "counter"; "gauge"; "summary"; "histogram"; "untyped" ]) then bad "a type %S" ty;
          if Hashtbl.mem types n then bad "two TYPE lines for %s" n;
          enter n;
          Hashtbl.replace types n ty
        | _ -> bad "a TYPE line %S" line
      end
      else if line.[0] = '#' then ()
      else begin
        (* name, labels, value *)
        let i = ref 0 and n = String.length line in
        while !i < n && line.[!i] <> '{' && line.[!i] <> ' ' do incr i done;
        let name = String.sub line 0 !i in
        if not (name_ok name) then bad "a sample of a bad name %S" name;
        let labels = ref [] in
        if !i < n && line.[!i] = '{' then begin
          incr i;
          while !i < n && line.[!i] <> '}' do
            let j = !i in
            while !i < n && line.[!i] <> '=' do incr i done;
            let ln = String.sub line j (!i - j) in
            if not (name_ok ln) || contains ln ":" then bad "a label name %S" ln;
            incr i;
            if !i >= n || line.[!i] <> '"' then bad "a label value without its quote in %S" line;
            incr i;
            let b = Buffer.create 16 in
            while !i < n && line.[!i] <> '"' do
              (if line.[!i] = '\\' then begin
                 incr i;
                 match line.[!i] with
                 | '\\' -> Buffer.add_char b '\\' | '"' -> Buffer.add_char b '"' | 'n' -> Buffer.add_char b '\n'
                 | c -> bad "an escape \\%c" c
               end
               else Buffer.add_char b line.[!i]);
              incr i
            done;
            if !i >= n then bad "an unended label value in %S" line;
            incr i;
            labels := (ln, Buffer.contents b) :: !labels;
            if !i < n && line.[!i] = ',' then incr i
          done;
          if !i >= n then bad "unended labels in %S" line;
          incr i
        end;
        if !i >= n || line.[!i] <> ' ' then bad "no value in %S" line;
        let rest = String.sub line (!i + 1) (n - !i - 1) in
        let v = match String.split_on_char ' ' rest with [ v ] | [ v; _ ] -> v | _ -> bad "a value %S" rest in
        let value =
          match v with
          | "NaN" -> Float.nan | "+Inf" -> Float.infinity | "-Inf" -> Float.neg_infinity
          | v -> (match float_of_string_opt v with Some f -> f | None -> bad "a value %S" v)
        in
        let f = family_of name in
        enter f;
        if not (Hashtbl.mem types f) then bad "a sample of %s before its TYPE" f;
        samples := { pname = name; plabels = List.rev !labels; pvalue = value } :: !samples
      end)
    (lines text);
  List.rev !order, types, List.rev !samples

let find_sample samples name labels =
  List.find_opt (fun s -> s.pname = name && List.for_all (fun l -> List.mem l s.plabels) labels) samples

let () =
  let status =
    [ "server", "cph-s-0123456789abcdef"; "cluster", "cph-c-0123456789abcdef"; "uptime_ms", "6050"; "connections", "2"; "requests", "683";
      "stopping", "false"; "questions.timed_out", "3"; "role", "replica of srv\"1\\x\ny"; "slow_ms", "200"; "latency_window_s", "60";
      "database.shop.group", "6202"; "database.shop.follow_ns_a_frame", "2483"; "database.shop.replica.srv2.lag_us_p50", "1500";
      "database.shop.replica.srv2.lag_samples", "9"; "database.shop.replica.error", "a message with a /path"; "database.shop.questions", "120";
      "database.shop.question_us_sum", "9876543"; "database.shop.question_us_p50", "85"; "database.shop.question_us_p99", "1200";
      "database.shop.question_us_max", "4100"; "database.shop.question_samples", "17"; "database.shop.writes", "0"; "database.shop.write_us_sum", "0";
      "database.shop.write_us_p50", "0"; "database.shop.write_samples", "0"; "database.side.group", "3"; "raft.log", "5 to 90";
      "raft.peer.srv2", "match 88, next 89, probing"; "a.future_key", "42"; "a.future_text", "words" ]
  in
  match parse_prometheus (Prometheus.of_status status) with
  | exception Failure m -> C.fail "Prometheus text: %s" m
  | fams, types, samples ->
    let v name labels = match find_sample samples name labels with Some s -> s.pvalue | None -> C.fail "no sample %s" name; Float.nan in
    C.check (v "cepheus_uptime_seconds" [] = 6.05 && v "cepheus_requests_total" [] = 683. && v "cepheus_stopping" [] = 0.) "server samples, in seconds";
    C.check (Hashtbl.find_opt types "cepheus_requests_total" = Some "counter" && Hashtbl.find_opt types "cepheus_connections" = Some "gauge") "their types";
    C.check (v "cepheus_role" [ "role", "replica of srv\"1\\x\ny" ] = 1.) "a label with a quote, a backslash and a line feed, parsed back";
    C.check (v "cepheus_database_group" [ "database", "shop" ] = 6202. && v "cepheus_database_group" [ "database", "side" ] = 3.) "a family of two databases";
    C.check (v "cepheus_database_follow_seconds_a_frame" [ "database", "shop" ] = 2.483e-06) "nanoseconds to seconds";
    C.check (v "cepheus_database_question_seconds" [ "database", "shop"; "quantile", "0.99" ] = 0.0012
             && v "cepheus_database_question_seconds" [ "database", "shop"; "quantile", "1" ] = 0.0041
             && v "cepheus_database_question_seconds_sum" [ "database", "shop" ] = 9.876543
             && v "cepheus_database_question_seconds_count" [ "database", "shop" ] = 120.)
      "a summary: quantiles, sum and count";
    C.check (Float.is_nan (v "cepheus_database_write_seconds" [ "database", "shop"; "quantile", "0.5" ])) "an empty window's quantile is NaN";
    C.check (Hashtbl.find_opt types "cepheus_database_question_seconds" = Some "summary") "a summary's type";
    C.check (v "cepheus_database_replica_lag_seconds" [ "database", "shop"; "peer", "srv2"; "quantile", "0.5" ] = 0.0015
             && v "cepheus_database_replica_lag_seconds_count" [ "peer", "srv2" ] = 9.) "a replica's lag, labelled by its peer";
    C.check (v "cepheus_raft_log_start" [] = 5. && v "cepheus_raft_log_last" [] = 90. && v "cepheus_raft_peer_next" [ "peer", "srv2" ] = 89.) "Raft's lines";
    C.check (v "cepheus_a_future_key" [] = 42. && Hashtbl.find_opt types "cepheus_a_future_key" = Some "untyped") "a key it does not know: untyped";
    C.check (v "cepheus_info" [ "server", "cph-s-0123456789abcdef"; "cluster", "cph-c-0123456789abcdef" ] = 1.) "the ids, as labels of one sample";
    C.check (not (List.exists (fun s -> List.exists (fun (_, x) -> contains x "/path" || contains x "words") s.plabels) samples)) "no text but names in a label";
    C.check (List.length fams = List.length (List.sort_uniq compare fams)) "each family in one group";
    C.check (Prometheus.scaled 1 6 = "0.000001" && Prometheus.scaled 1_000_000 6 = "1" && Prometheus.scaled (-1500) 3 = "-1.5" && Prometheus.scaled 7 0 = "7") "exact decimals"

(* ---- shapes: no constant of a question or a write ---- *)

let () =
  let disk = Sim_disk.disk (Sim_disk.create (Rng.make 3)) in
  disk.mkdir "/s";
  let db = match Cepheus.open_on disk "/s" with Ok db -> db | Error e -> failwith (Cepheus.message e) in
  let[@warning "-8"] (Ok [ name; code; ok ]) = Cepheus.declare db [ prop "c/name" Ttext; prop "c/code" Tint; prop "c/ok" Tbool ] in
  let v = Cepheus.view db in
  let q =
    { Query.vars = 2;
      where = [ { e = Var 0; p = name; v = Val (Text "secret-name-81723") }; { e = Thing 99887766; p = code; v = Var 1 }; { e = Var 0; p = ok; v = Val (Bool true) } ];
      ranges = [ (1, Value.Int 31415926, Value.Int 27182818) ] }
  in
  let extra = [ Ask.In (1, [ Value.Int 55501; Value.Int 55502 ]); Ask.Prefix (0, "secret-prefix"); Ask.Not [ Ask.Pattern { e = Var 0; p = code; v = Val (Int 4242424) } ];
                Ask.Or [ [ Ask.Range (1, Value.Int 1, Value.Int 8080808) ]; [ Ask.Pattern { e = Var 0; p = name; v = Val (Text "secret-or") } ] ] ] in
  let order = { Top.keys = [ { col = 1; desc = true } ]; limit = 20; after = Some [| Value.Text "secret-after"; Value.Int 6060606 |] } in
  let s = Timings.shape v q (Wire.Give [| 0; 1 |]) extra order in
  List.iter (fun x -> C.check (not (contains s x)) "the shape holds no %s: %s" x s)
    [ "secret"; "99887766"; "31415926"; "27182818"; "55501"; "4242424"; "8080808"; "6060606"; "true" ];
  C.check (contains s "[x0 c/name ?]" && contains s "[? c/code x1]" && contains s "In(x1, 2 values)" && contains s "limit 20" && contains s "after ?")
    "the shape names its properties and variables: %s" s;
  let w = Timings.write_shape [ Resolve.Add (-1, name, Text "secret-w"); Resolve.Add (-1, code, Int 123454321); Resolve.Retract (5, ok, Bool true) ] in
  let t = Timings.write_text v w in
  C.check (not (contains t "secret") && not (contains t "123454321") && contains t "3 operations (2 adds, 1 retract) of c/name, c/code, c/ok") "a write's text: %s" t;
  Cepheus.close db

(* ---- cluster.toml's [log] slow_ms ---- *)

let base = "[cluster]\nname = \"o\"\nid = \"cph-c-0000000000000001\"\nme = \"s\"\n[[peer]]\nname = \"s\"\naddress = \"127.0.0.1:7401\"\n[clients]\nsocket = \"run\"\n[storage]\ndata = \"data\"\n[[database]]\nname = \"main\"\n"

let () =
  let conf s = Config.of_toml "/x/cluster.toml" (Toml.parse s) in
  C.check ((conf base).slow_ms = 200) "slow_ms: 200 by default";
  C.check ((conf (base ^ "[log]\nslow_ms = 0\n")).slow_ms = 0 && (conf (base ^ "[log]\nslow_ms = 1500\n")).slow_ms = 1500) "slow_ms 0 (none) and 1500";
  List.iter
    (fun (s, what) -> C.check (match conf (base ^ s) with _ -> false | exception Config.Bad _ -> true) "refused: %s" what)
    [ "[log]\nslow_ms = -1\n", "a negative slow_ms"; "[log]\nslow_ms = \"200ms\"\n", "slow_ms as a string"; "[log]\nslow_ms = 3600001\n", "past an hour";
      "[log]\nslow = 200\n", "an unknown key of [log]" ]

(* ---- a real server ---- *)

let started = ref []

let start cfg =
  let log = Unix.openfile (Filename.dirname cfg // "serve.log") [ O_WRONLY; O_CREAT; O_APPEND; O_CLOEXEC ] 0o644 in
  let null = Unix.openfile "/dev/null" [ O_RDONLY; O_CLOEXEC ] 0 in
  let pid = Unix.create_process "setsid" [| "setsid"; bin; "serve"; "--config"; cfg |] null log log in
  Unix.close log;
  Unix.close null;
  started := pid :: !started;
  pid

let () =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  at_exit (fun () -> List.iter (fun pid -> try Unix.kill pid Sys.sigkill; ignore (Unix.waitpid [] pid) with Unix.Unix_error _ -> ()) !started)

let wait_ready sock =
  let t0 = Unix.gettimeofday () in
  let rec go () =
    let s = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    match Unix.connect s (Unix.ADDR_UNIX sock) with
    | () -> Unix.close s
    | exception Unix.Unix_error _ ->
      Unix.close s;
      if Unix.gettimeofday () -. t0 > 30. then failwith "the server did not start";
      Thread.delay 0.01;
      go ()
  in
  go ()

let run_out args env =
  let out = Filename.temp_file "cepheus-observe" ".out" in
  let code = Sys.command (Printf.sprintf "%s %s %s > %s 2>&1" env bin (String.concat " " (List.map Filename.quote args)) (Filename.quote out)) in
  let s = read_file out in
  Sys.remove out;
  code, s

let key_values s =
  List.filter_map (fun l -> match String.index_opt l ':' with Some i -> Some (String.sub l 0 i, String.trim (String.sub l (i + 1) (String.length l - i - 1))) | None -> None) (lines s)

let () =
  let dir = match Sys.argv with [| _; d |] -> d | _ -> prerr_endline "server_observe.exe DIR"; exit 2 in
  C.rmrf dir;
  Unix.mkdir dir 0o700;
  Unix.mkdir (dir // "run") 0o700;
  let cfg = dir // "cluster.toml" and sock = dir // "run/.s.cepheus.7400" in
  write_file cfg (base ^ "[log]\nslow_ms = 1\n");
  let wtext, whash = Tokens.generate () and atext, ahash = Tokens.generate () in
  Tokens.save (dir // "tokens.toml")
    (Tokens.with_tokens Tokens.empty
       [ { Tokens.name = "obs-writer"; hash = whash; databases = [ "main", Tokens.Write ]; admin = false };
         { Tokens.name = "obs-admin"; hash = ahash; databases = []; admin = true } ]);
  let pid = start cfg in
  wait_ready sock;
  let addr = Client.Unix_socket sock in
  let c = match Client.connect addr wtext with Ok c -> c | Error m -> failwith m in
  let db, name, code, tag =
    match Client.declare c "main" [ prop "c/name" Ttext; prop "c/code" Tint; prop "c/tag" Ttext ] with
    | Ok (db, [ n; k; t ]) -> db, n, k, t
    | _ -> failwith "declare"
  in
  (* values of the data no line may show: texts and numbers of its own *)
  let secret i = Printf.sprintf "zq-secret-%06d" (731 * i) and number i = 913_000_000 + (7 * i) and tag_value = "zq-tag-4711" in
  let n = 1500 in
  (* one large group (slow at 1 ms), then small ones *)
  let ops = List.concat (List.init n (fun i -> [ Resolve.Add (-(i + 1), name, Text (secret i)); Resolve.Add (-(i + 1), code, Int (number i)); Resolve.Add (-(i + 1), tag, Text tag_value) ])) in
  (match Client.write c db ~why:"load" ops with Ok _ -> () | Error e -> C.fail "the load: %s %s" e.code e.message);
  for i = 0 to 9 do ignore (Client.write c db [ Resolve.Add (-1, name, Text (secret (n + i))); Resolve.Add (-1, code, Int (number (n + i))) ]) done;
  (* slow questions: a product counted (1500 x 1500), a watch of it, the same with three patterns past a 50 ms timeout *)
  let product = { Query.vars = 2; where = [ { e = Var 0; p = tag; v = Val (Text tag_value) }; { e = Var 1; p = tag; v = Val (Text tag_value) } ]; ranges = [] } in
  (match Client.find c db ~select:(Wire.Group ([||], [| Wire.Count |])) product with
   | Ok (_, [ [| Value.Int k |] ]) -> C.check (k = n * n) "the product counted: %d" k
   | Ok _ -> C.fail "the product: an unexpected answer"
   | Error e -> C.fail "the product: %s %s" e.code e.message);
  let three = { product with Query.vars = 3; where = product.where @ [ { e = Var 2; p = tag; v = Val (Text tag_value) } ] } in
  (match Client.find c db ~select:(Wire.Group ([||], [| Wire.Count |])) ~timeout:0.05 three with
   | Error { code = "timeout"; _ } -> C.check true "three patterns: timeout"
   | Ok _ -> C.fail "three patterns answered within 50 ms"
   | Error e -> C.fail "three patterns: %s %s" e.code e.message);
  let one = { Query.vars = 1; where = [ { e = Var 0; p = code; v = Val (Int (number 42)) } ]; ranges = [] } in
  (match Client.find c db one with Ok (_, [ _ ]) -> () | _ -> C.fail "a point question");
  (* a watch of the product's count (its first answer timed) *)
  let w = Client.watch c db ~select:(Wire.Group ([||], [| Wire.Count |])) product in
  (match Client.next_push c w with Client.Pushed (Wire.Answer _) -> () | _ -> C.fail "the watch's first answer");
  Client.close c;
  (* the log *)
  let log = read_file (dir // "serve.log") in
  let slow = List.filter (fun l -> contains l "slow question" || contains l "slow write") (lines log) in
  let has_line what = List.exists (fun l -> List.for_all (contains l) what) slow in
  C.check (has_line [ "slow question: database main, token obs-writer"; "candidates"; "1 rows, ok: find group count where [x0 c/tag ?] [x1 c/tag ?]" ])
    "a line for the product, its shape and rows:\n%s" (String.concat "\n" slow);
  C.check (has_line [ "slow question: database main, token obs-writer"; "timeout: find group count where [x0 c/tag ?] [x1 c/tag ?] [x2 c/tag ?]" ]) "a line for the timeout";
  C.check (has_line [ "slow question: database main, token obs-writer"; "ok: watch group count" ]) "a line for the watch";
  C.check (has_line [ "slow write: database main, token obs-writer"; "group"; "ok: 4500 operations (4500 adds) of c/name, c/code, c/tag" ]) "a line for the large group";
  List.iter
    (fun l ->
      match String.index_opt l ',' with
      | _ when contains l "slow question" ->
        (* its candidates: a number *)
        C.check (List.exists (fun w -> int_of_string_opt w <> None) (String.split_on_char ' ' l)) "a count in %s" l
      | _ -> ())
    slow;
  (* no value of the data, no token *)
  let values = tag_value :: wtext :: atext :: List.concat (List.init (n + 10) (fun i -> [ secret i; string_of_int (number i) ])) in
  let leaked = List.filter (contains log) values in
  C.check (leaked = []) "no value nor token in the server's log (%d found: %s)" (List.length leaked) (String.concat ", " (List.filteri (fun i _ -> i < 3) leaked));
  (* status: the earlier lines in their order, the new ones present *)
  let env = "CEPHEUS_TOKEN=" ^ Filename.quote atext in
  let code_text, text = run_out [ "status"; "--config"; cfg ] env in
  C.check (code_text = 0) "cepheus status: %s" text;
  let kv = key_values text in
  let keys = List.map fst kv in
  let earlier =
    [ "server"; "cluster"; "uptime_ms"; "connections"; "requests"; "gc_minor"; "gc_major"; "stopping"; "questions.timed_out"; "questions.cancelled";
      "questions.helpers"; "domains"; "domains.cap"; "commit_buffer.rounds"; "commit_buffer.frames"; "commit_buffer.alone"; "role";
      "database.main.group"; "database.main.facts"; "database.main.resent"; "database.main.followers"; "database.main.frames";
      "database.main.follow_ns_a_frame"; "database.main.visible"; "database.main.watches"; "database.main.epoch" ]
  in
  let rec in_order l = function [] -> true | k :: rest -> (match List.find_index (( = ) k) l with Some i -> in_order (List.filteri (fun j _ -> j > i) l) rest | None -> false) in
  C.check (in_order keys earlier) "the earlier lines, in their order";
  let num k = match List.assoc_opt k kv with Some v -> (match int_of_string_opt v with Some x -> x | None -> -1) | None -> C.fail "no status line %s" k; -1 in
  C.check (num "database.main.questions" >= 4 && num "database.main.questions_slow" >= 3 && num "database.main.writes" = 12) "questions and writes counted (%d, %d slow; %d)"
    (num "database.main.questions") (num "database.main.questions_slow") (num "database.main.writes");
  let p50 = num "database.main.question_us_p50" and p99 = num "database.main.question_us_p99" and mx = num "database.main.question_us_max" in
  C.check (0 < p50 && p50 <= p99 && p99 <= mx && mx >= 50_000) "questions: p50 %d <= p99 %d <= max %d (the timeout's 50 ms in it)" p50 p99 mx;
  C.check (num "database.main.write_us_max" >= num "database.main.write_us_p50" && num "database.main.write_samples" = 12) "writes in the window";
  C.check (num "questions.timed_out" = 1 && num "slow_ms" = 1 && num "latency_window_s" = 60) "timed_out, slow_ms, the window";
  C.check (num "database.main.journal_bytes" > 0 && num "database.main.runs_bytes" >= 0 && num "database.main.merges" >= 0) "the journal's bytes";
  C.check (num "disk.free_bytes" > 0 && num "disk.size_bytes" >= num "disk.free_bytes" && num "cache.capacity_bytes" = 1 lsl 30) "the disk, the cache";
  C.check (num "cache.hits" >= 0 && num "cache.misses" >= 0 && num "cache.resident_bytes" >= 0) "the cache's counters";
  (* Prometheus: parsed back, the same numbers, every key known, no value nor token *)
  let code_p, prom = run_out [ "status"; "--format"; "prometheus"; "--config"; cfg ] env in
  C.check (code_p = 0) "cepheus status --format prometheus";
  (match parse_prometheus prom with
   | exception Failure m -> C.fail "the server's Prometheus text: %s\n%s" m prom
   | _, types, samples ->
     let v name labels = match find_sample samples name labels with Some s -> s.pvalue | None -> C.fail "no sample %s" name; Float.nan in
     C.check (v "cepheus_database_group" [ "database", "main" ] = float (num "database.main.group")) "the group, the same";
     C.check (v "cepheus_database_writes_slow_total" [ "database", "main" ] >= 1. && v "cepheus_questions_timed_out_total" [] = 1.) "counters";
     C.check (v "cepheus_database_question_seconds_count" [ "database", "main" ] >= 4.) "the questions' count";
     C.check (not (Hashtbl.fold (fun _ t u -> u || t = "untyped") types false)) "every key of this server known (none untyped)";
     C.check (List.for_all (fun x -> not (contains prom x)) values) "no value nor token in the Prometheus text");
  let code_bad, out = run_out [ "status"; "--format"; "json"; "--config"; cfg ] env in
  C.check (code_bad <> 0 && contains out "text or prometheus") "--format json refused: %s" out;
  Unix.kill pid Sys.sigterm;
  ignore (Unix.waitpid [] pid);
  started := [];
  (try Sys.remove (Follow.page_of_dir (dir // "data/main")) with Sys_error _ -> ());
  C.rmrf dir;
  C.finish "server observe"
