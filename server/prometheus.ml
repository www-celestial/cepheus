(* cepheus status in Prometheus's text exposition format, version 0.0.4 (prometheus.io/docs/instrumenting/
   exposition_formats/, "Text-based format"): the same lines, read by the client (cepheus status --format
   prometheus), for node_exporter's textfile collector or a cron, rather than an HTTP port of the server: one listener,
   one way to authenticate (the admin token).

   Each status key is a sample of a family named cepheus_..., in base units (seconds, bytes), with its HELP and TYPE
   lines first and its samples together, as the format asks ("All lines for a given metric must be provided as one
   single group"). A database's key gives a sample with the label database="NAME"; a replica's or a Raft peer's, the
   label peer too. The times of questions and writes are summaries: their quantiles 0.5, 0.99 and 1 (the maximum)
   over the window, NaN when it holds none, and their _sum and _count since the start, as a summary's are. A text that
   names something (the role, a database's primary, the server's and the cluster's ids) is a label of a sample of 1;
   another text (an error's message) is left out: a label holds a name or an id, never a value of the data nor a
   token. A key this client does not know (a newer server's) with a number or a boolean is written untyped under its
   own name. *)

type kind = Counter | Gauge | Summary | Untyped

type family = { fname : string; kind : kind; help : string; mutable samples : (string * (string * string) list * string) list }

let kind_name = function Counter -> "counter" | Gauge -> "gauge" | Summary -> "summary" | Untyped -> "untyped"

(* a metric's name: [a-zA-Z_:][a-zA-Z0-9_:]*, any other byte made _ *)
let sanitize s =
  String.mapi
    (fun i c -> if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_' || c = ':' || (i > 0 && c >= '0' && c <= '9') then c else '_')
    s

(* a label's value: backslash, double quote and line feed escaped; HELP: backslash and line feed *)
let escape ~quote s =
  let b = Buffer.create (String.length s + 8) in
  String.iter
    (function
      | '\\' -> Buffer.add_string b "\\\\" | '\n' -> Buffer.add_string b "\\n" | '"' when quote -> Buffer.add_string b "\\\"" | c -> Buffer.add_char b c)
    s;
  Buffer.contents b

(* n / 10^d written exactly in decimal *)
let scaled n d =
  if d = 0 then string_of_int n
  else begin
    let p = int_of_float (10. ** float d) in
    let a = abs n in
    let frac = Printf.sprintf "%0*d" d (a mod p) in
    let k = ref (String.length frac) in
    while !k > 0 && frac.[!k - 1] = '0' do decr k done;
    (if n < 0 then "-" else "") ^ string_of_int (a / p) ^ if !k = 0 then "" else "." ^ String.sub frac 0 !k
  end

let number s = int_of_string_opt (String.trim s)
let boolean = function "true" -> Some 1 | "false" -> Some 0 | _ -> None

(* how a known key is written: its family's name (after cepheus_ or cepheus_database_), kind, help, and the power of
   ten its value is divided by *)
let server_keys =
  [ "uptime_ms", ("uptime_seconds", Gauge, "Seconds since the server started", 3);
    "connections", ("connections", Gauge, "Connections open, the local readers' included", 0);
    "requests", ("requests_total", Counter, "Requests answered since the start", 0);
    "gc_minor", ("gc_minor_collections_total", Counter, "Minor collections of the OCaml runtime", 0);
    "gc_major", ("gc_major_collections_total", Counter, "Major collections of the OCaml runtime", 0);
    "stopping", ("stopping", Gauge, "1 while a stop is under way", 0);
    "questions.timed_out", ("questions_timed_out_total", Counter, "Questions ended by their time", 0);
    "questions.cancelled", ("questions_cancelled_total", Counter, "Questions ended because their connection closed", 0);
    "questions.helpers", ("question_helpers", Gauge, "Domains helping large questions now", 0);
    "domains", ("domains", Gauge, "Domains the server holds now", 0);
    "domains.cap", ("domains_cap", Gauge, "The runtime's cap of domains", 0);
    "commit_buffer.rounds", ("commit_buffer_rounds_total", Counter, "The commit buffer's fsyncs", 0);
    "commit_buffer.frames", ("commit_buffer_frames_total", Counter, "Frames the commit buffer made durable", 0);
    "commit_buffer.alone", ("commit_buffer_alone_total", Counter, "Frames forced in their own journal", 0);
    "slow_ms", ("slow_seconds", Gauge, "The time past which a question or a write is logged (0: none)", 3);
    "latency_window_s", ("latency_window_seconds", Gauge, "The window of the time quantiles", 0);
    "cache.capacity_bytes", ("cache_capacity_bytes", Gauge, "The room of the page cache", 0);
    "cache.resident_bytes", ("cache_resident_bytes", Gauge, "Pages in the page cache now", 0);
    "cache.hits", ("cache_hits_total", Counter, "Reads of a page in memory that the cache's policy counted", 0);
    "cache.misses", ("cache_misses_total", Counter, "Pages read from the disk", 0);
    "disk.free_bytes", ("disk_free_bytes", Gauge, "Bytes free for the server on the data's file system", 0);
    "disk.size_bytes", ("disk_size_bytes", Gauge, "Size of the data's file system", 0);
    "raft.term", ("raft_term", Gauge, "The Raft term", 0);
    "raft.ready", ("raft_ready", Gauge, "1 when this server serves as the leader", 0);
    "raft.commit", ("raft_commit", Gauge, "The Raft log's commit index", 0);
    "raft.applied", ("raft_applied", Gauge, "The Raft log's index applied", 0);
    "raft.forced", ("raft_forced", Gauge, "The Raft log's index forced to the disk", 0) ]

let database_keys =
  [ "group", ("group", Gauge, "The newest durable group", 0);
    "facts", ("facts", Gauge, "Facts in the newest state", 0);
    "resent", ("resent_total", Counter, "Writes answered again from the session table", 0);
    "followers", ("followers", Gauge, "Local readers following the database", 0);
    "frames", ("frames_total", Counter, "Frames published", 0);
    "follow_ns_a_frame", ("follow_seconds_a_frame", Gauge, "Mean time a frame to publish it to the local readers", 9);
    "visible", ("visible", Gauge, "The visibility number of the local readers", 0);
    "watches", ("watches", Gauge, "Live questions open", 0);
    "epoch", ("epoch", Gauge, "The database's epoch", 0);
    "journal_bytes", ("journal_bytes", Gauge, "Bytes of the journal's segments", 0);
    "runs_bytes", ("runs_bytes", Gauge, "Bytes of the runs", 0);
    "merges", ("merges_total", Counter, "Merges installed since the start", 0);
    "merge_us_sum", ("merge_seconds_total", Counter, "Time of the merges installed", 6);
    "merge_bytes", ("merge_bytes_total", Counter, "Bytes of the runs the merges wrote", 0);
    "questions_slow", ("questions_slow_total", Counter, "Questions that took the slow time or more", 0);
    "question_samples", ("question_window_samples", Gauge, "Questions in the window of the quantiles", 0);
    "writes_slow", ("writes_slow_total", Counter, "Writes that took the slow time or more", 0);
    "write_samples", ("write_window_samples", Gauge, "Writes in the window of the quantiles", 0);
    "replica.connected", ("replica_connected", Gauge, "1 while the replica is connected to its primary", 0);
    "replica.primary_group", ("replica_primary_group", Gauge, "The primary's newest group the replica knows", 0);
    "replica.handover", ("replica_handover", Gauge, "The group of a handover under way", 0);
    "replica.epoch", ("replica_epoch", Gauge, "The replica's epoch", 0) ]

(* the summaries: a key's suffix -> the family, its sample (a quantile, _sum or _count) *)
let summaries =
  [ "question", ("question_seconds", "Time of a question at the server, from its request to its reply");
    "write", ("write_seconds", "Time of a write at the server, from its request to its reply, its group durable") ]

let of_status (lines : (string * string) list) =
  let fams = Hashtbl.create 64 and order = ref [] in
  let family name kind help =
    match Hashtbl.find_opt fams name with
    | Some f -> f
    | None -> let f = { fname = name; kind; help; samples = [] } in Hashtbl.replace fams name f; order := f :: !order; f
  in
  let sample name kind help ?(suffix = "") labels value =
    let f = family name kind help in
    f.samples <- (name ^ suffix, labels, value) :: f.samples
  in
  let all = Hashtbl.create 64 in
  List.iter (fun (k, v) -> Hashtbl.replace all k v) lines;
  let info = ref [] in
  let one_key prefix labels table k v =
    match List.assoc_opt k table with
    | Some (n, kind, help, d) -> (
      match number v, boolean v with
      | Some x, _ -> sample (prefix ^ n) kind help labels (scaled x d)
      | None, Some b -> sample (prefix ^ n) kind help labels (string_of_int b)
      | None, None -> ())
    | None -> (
      match number v, boolean v with
      | Some x, _ -> sample (prefix ^ sanitize k) Untyped ("cepheus status " ^ k) labels (string_of_int x)
      | None, Some b -> sample (prefix ^ sanitize k) Untyped ("cepheus status " ^ k) labels (string_of_int b)
      | None, None -> ())
  in
  (* a time of [what] (question, write) of database [db]: [rest] after it *)
  let timed db what rest v =
    let n, help = List.assoc what summaries in
    let name = "cepheus_database_" ^ n and labels = [ "database", db ] in
    let empty = match Hashtbl.find_opt all (Printf.sprintf "database.%s.%s_samples" db what) with Some "0" -> true | _ -> false in
    let quantile q = sample name Summary help (labels @ [ "quantile", q ]) (if empty then "NaN" else match number v with Some x -> scaled x 6 | None -> "NaN") in
    match rest with
    | "us_p50" -> quantile "0.5"
    | "us_p99" -> quantile "0.99"
    | "us_max" -> quantile "1"
    | "us_sum" -> Option.iter (fun x -> sample name Summary help ~suffix:"_sum" labels (scaled x 6)) (number v)
    | _ -> ()
  in
  let database db rest v =
    let labels = [ "database", db ] in
    match String.split_on_char '.' rest with
    | [ "questions" ] -> Option.iter (fun x -> sample "cepheus_database_question_seconds" Summary (snd (List.assoc "question" summaries)) ~suffix:"_count" labels (string_of_int x)) (number v)
    | [ "writes" ] -> Option.iter (fun x -> sample "cepheus_database_write_seconds" Summary (snd (List.assoc "write" summaries)) ~suffix:"_count" labels (string_of_int x)) (number v)
    | [ r ] when String.length r > 9 && String.sub r 0 9 = "question_" && List.mem (String.sub r 9 (String.length r - 9)) [ "us_p50"; "us_p99"; "us_max"; "us_sum" ] ->
      timed db "question" (String.sub r 9 (String.length r - 9)) v
    | [ r ] when String.length r > 6 && String.sub r 0 6 = "write_" && List.mem (String.sub r 6 (String.length r - 6)) [ "us_p50"; "us_p99"; "us_max"; "us_sum" ] ->
      timed db "write" (String.sub r 6 (String.length r - 6)) v
    | [ "replica_of" ] -> sample "cepheus_database_replica_of" Gauge "The primary a replica follows" (labels @ [ "primary", v ]) "1"
    | [ "replica"; "error" ] -> ()
    | [ "replica"; peer; x ] -> (
      let labels = labels @ [ "peer", peer ] in
      let lag = "cepheus_database_replica_lag_seconds" and help = "Time from a group durable on the primary to the replica's word that it holds it" in
      match x, number v with
      | "group", Some g -> sample "cepheus_database_replica_group" Gauge "The newest group a replica holds" labels (string_of_int g)
      | "lag_us_p50", Some g -> sample lag Summary help (labels @ [ "quantile", "0.5" ]) (scaled g 6)
      | "lag_us_p99", Some g -> sample lag Summary help (labels @ [ "quantile", "0.99" ]) (scaled g 6)
      | "lag_us_max", Some g -> sample lag Summary help (labels @ [ "quantile", "1" ]) (scaled g 6)
      | "lag_samples", Some g -> sample lag Summary help ~suffix:"_count" labels (string_of_int g)
      | _ -> one_key "cepheus_database_" labels [] (String.concat "_" [ "replica"; x ]) v)
    | _ -> one_key "cepheus_database_" labels database_keys rest v
  in
  List.iter
    (fun (k, v) ->
      match String.split_on_char '.' k with
      | [ ("server" | "cluster") ] -> info := (k, v) :: !info
      | [ "role" ] -> sample "cepheus_role" Gauge "The server's role" [ "role", v ] "1"
      | [ "raft"; "role" ] -> sample "cepheus_raft_role" Gauge "This server's Raft role" [ "role", v ] "1"
      | [ "raft"; "leader" ] -> if v <> "none" then sample "cepheus_raft_leader" Gauge "The Raft leader this server knows" [ "leader", v ] "1"
      | [ "raft"; "log" ] -> (
        match String.split_on_char ' ' v with
        | [ a; "to"; b ] ->
          Option.iter (fun x -> sample "cepheus_raft_log_start" Gauge "The first index of the Raft log" [] (string_of_int x)) (number a);
          Option.iter (fun x -> sample "cepheus_raft_log_last" Gauge "The last index of the Raft log" [] (string_of_int x)) (number b)
        | _ -> ())
      | [ "raft"; "peer"; peer ] -> (
        match String.split_on_char ' ' (String.map (fun c -> if c = ',' then ' ' else c) v) |> List.filter (( <> ) "") with
        | "match" :: m :: "next" :: n :: _ ->
          Option.iter (fun x -> sample "cepheus_raft_peer_match" Gauge "The index a peer holds, as the leader knows it" [ "peer", peer ] (string_of_int x)) (number m);
          Option.iter (fun x -> sample "cepheus_raft_peer_next" Gauge "The next index the leader sends a peer" [ "peer", peer ] (string_of_int x)) (number n)
        | _ -> ())
      | "database" :: db :: (_ :: _ as rest) -> database db (String.concat "." rest) v
      | _ -> one_key "cepheus_" [] server_keys k v)
    lines;
  (match List.assoc_opt "server" !info, List.assoc_opt "cluster" !info with
   | None, None -> ()
   | s, c ->
     let f = family "cepheus_info" Gauge "The server's id and its cluster's" in
     f.samples <- f.samples @ [ ("cepheus_info", List.filter_map (fun (k, v) -> Option.map (fun v -> k, v) v) [ "server", s; "cluster", c ], "1") ]);
  let b = Buffer.create 4096 in
  List.iter
    (fun f ->
      Printf.bprintf b "# HELP %s %s\n# TYPE %s %s\n" f.fname (escape ~quote:false f.help) f.fname (kind_name f.kind);
      List.iter
        (fun (n, labels, value) ->
          Buffer.add_string b n;
          if labels <> [] then begin
            Buffer.add_char b '{';
            List.iteri (fun i (k, v) -> if i > 0 then Buffer.add_char b ','; Printf.bprintf b "%s=\"%s\"" k (escape ~quote:true v)) labels;
            Buffer.add_char b '}'
          end;
          Printf.bprintf b " %s\n" value)
        (List.rev f.samples))
    (List.rev !order);
  Buffer.contents b
