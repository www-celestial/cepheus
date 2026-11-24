(* cepheus import and cepheus export (Transfer): their options, the connections to the server of --config, the
   report on stderr. The token is CEPHEUS_TOKEN's, never an argument (a command line is visible to every user of the
   machine): a right to write the database to import, to read it to export.

     cepheus import DB FILE --kind KIND [--format csv|jsonl] [--map COLUMN=FIELD]... [--link FIELD=KIND/KEY|id]...
                    [--skip-bad] [--upsert] --config FILE
     cepheus export DB --kind KIND [--format jsonl|csv] [--link FIELD=KIND/KEY|id]... --config FILE > FILE *)

open Cepheus_server

let die fmt = Printf.ksprintf (fun m -> prerr_endline ("cepheus: " ^ m); exit 1) fmt
let say m = prerr_endline ("cepheus: " ^ m)

let usage () =
  prerr_string
    "usage: cepheus import DB FILE --kind KIND [--format csv|jsonl] [--map COLUMN=FIELD]... [--link FIELD=KIND/KEY|id]...\n\
    \                     [--skip-bad] [--upsert] --config FILE\n\
    \       cepheus export DB --kind KIND [--format jsonl|csv] [--link FIELD=KIND/KEY|id]... --config FILE > FILE\n\
    \       (the token in CEPHEUS_TOKEN: write to import, read to export)\n";
  exit 2

let pair flag s =
  match String.index_opt s '=' with
  | Some i when i > 0 -> String.sub s 0 i, String.sub s (i + 1) (String.length s - i - 1)
  | _ -> die "%s %s: NAME=VALUE" flag s

let format_of s = match s with "csv" -> Tabular.Csv | "jsonl" -> Tabular.Jsonl | _ -> die "--format %s: csv or jsonl" s

(* thousands apart, as the reports print counts *)
let count n =
  let s = string_of_int n in
  let b = Buffer.create 16 in
  String.iteri (fun i c -> if i > 0 && (String.length s - i) mod 3 = 0 then Buffer.add_char b ','; Buffer.add_char b c) s;
  Buffer.contents b

let main cmd args =
  let config = ref None and kind = ref None and format = ref None and maps = ref [] and links = ref [] in
  let skip_bad = ref false and upsert = ref false and pos = ref [] in
  let rec go = function
    | "--config" :: f :: r -> config := Some f; go r
    | "--kind" :: k :: r -> kind := Some k; go r
    | "--format" :: f :: r -> format := Some (format_of f); go r
    | "--map" :: m :: r -> maps := pair "--map" m :: !maps; go r
    | "--link" :: l :: r -> links := pair "--link" l :: !links; go r
    | "--skip-bad" :: r when cmd = "import" -> skip_bad := true; go r
    | "--upsert" :: r when cmd = "import" -> upsert := true; go r
    | ("--help" | "-h") :: _ -> usage ()
    | x :: _ when String.length x > 1 && x.[0] = '-' -> die "unknown option %s (cepheus %s --help)" x cmd
    | x :: r -> pos := x :: !pos; go r
    | [] -> ()
  in
  go args;
  let cfg = match !config with None -> die "--config FILE is needed" | Some f -> ( match Config.load f with Ok c -> c | Error m -> die "%s" m) in
  let kind = match !kind with Some k -> k | None -> die "--kind KIND is needed: the kind of the things (client, invoice...)" in
  let token = match Sys.getenv_opt "CEPHEUS_TOKEN" with Some t -> t | None -> die "CEPHEUS_TOKEN must hold a token (cepheus token add)" in
  let address =
    match Config.socket_path cfg, cfg.listen with
    | Some p, _ -> Client.Unix_socket p
    | None, Some (h, p) -> Client.Tcp (h, p)
    | None, None -> die "the configuration names no socket and no listen address"
  in
  let ca = Option.map (fun (t : Config.tls) -> t.ca) cfg.tls in
  let connect () = match Client.connect ~program:("cepheus " ^ cmd) ?ca ~cluster:cfg.id address token with Ok c -> c | Error m -> die "%s" m in
  let open_ ~local c name = match Client.open_db ~local c name with Ok d -> d | Error e -> die "%s: %s: %s" name e.code e.message in
  try
    match cmd, List.rev !pos with
    | "import", [ database; file ] ->
      let format =
        match !format, Transfer.format_of_file file with
        | Some f, _ | None, Some f -> f
        | None, None -> die "%s: --format csv or jsonl (its name ends in neither .csv nor .jsonl)" file
      in
      let rc = connect () and wc = connect () in
      let rdb = open_ ~local:false rc database and wdb = open_ ~local:false wc database in
      let why = "cepheus import " ^ Filename.basename file in
      let o = { Transfer.file; kind; format; maps = List.rev !maps; links = List.rev !links; skip_bad = !skip_bad; upsert = !upsert; why } in
      let s = Transfer.import_client ~say (rc, rdb) (wc, wdb) o in
      let groups =
        match s.groups with
        | [] -> "nothing to write"
        | [ (g, _, _) ] -> Printf.sprintf "in group %d" g
        | (g, _, _) :: _ -> let gn, _, _ = List.nth s.groups (List.length s.groups - 1) in Printf.sprintf "in %d groups, %d to %d" (List.length s.groups) g gn
      in
      say
        (Printf.sprintf "%s: %s rows, %s facts (%s new things, %s changed) %s; checked in %.2f s, written in %.2f s (%.2f s of it in the server's answers)%s%s"
           (Filename.basename file) (count s.rows) (count s.facts) (count s.inserted) (count s.updated) groups s.check_s s.write_s s.server_s
           (if s.left_out > 0 then Printf.sprintf "; %s bad rows left out" (count s.left_out) else "")
           (if s.empty > 0 then Printf.sprintf "; %s rows without a value" (count s.empty) else ""));
      Client.close rc;
      Client.close wc
    | "export", [ database ] -> (
      let c = connect () in
      let db = open_ ~local:true c database in
      match Client.local_view c db with
      | None ->
        die "export reads one state of %s in this process, from the server's follow stream: run it on the server's machine (the Unix socket of %s's [clients] socket) with a token that reads the whole database"
          database cfg.file
      | Some v ->
        let out s =
          let b = Bytes.unsafe_of_string s in
          let rec go o = if o < Bytes.length b then go (o + Unix.write Unix.stdout b o (Bytes.length b - o)) in
          try go 0 with Unix.Unix_error (Unix.EPIPE, _, _) -> exit 1
        in
        let format = Option.value !format ~default:Tabular.Jsonl in
        let e = Transfer.export v { ekind = kind; eformat = format; elinks = List.rev !links } out in
        say
          (Printf.sprintf "%s at group %d: %s things of %s, %s facts, as %s, in %.2f s" database e.group (count e.things) kind (count e.efacts)
             (if format = Tabular.Csv then "CSV" else "JSON lines") e.seconds);
        Client.close c)
    | _ -> usage ()
  with Transfer.Stop m -> die "%s" m
