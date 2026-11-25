(* The commands of operations (server/ops.ml) on real files: verify, backup and restore of a database written by four
   threads (frames of several groups), with small segments and merges, so that runs, segment boundaries and frames
   cut in the middle all occur.

   - restore to a group N, for groups at segment boundaries, inside frames of several groups, before and after runs:
     the restored database is at N and holds exactly the facts of the journal's groups 1..N replayed onto the empty
     state (the oracle), it verifies whole, and its history opens epoch 2 at N + 1 (a replica of the old history
     past N is refused); to the end, to a time; --replace moves the old database aside; refusals;
   - verify names each damage: a byte of a frame changed (the other segments still checked), a segment missing, a
     page of a run, a torn tail (a note after a crash, damage after a clean close), the frame being written of a copy
     (a header written after its body: the tail of a copy, damage after a crash), the vault's records;
   - backup of a stopped server's databases: the dated folder, whole and closed, the facts of the source; a partial
     folder a killed backup left is removed; the vault copied, its file read back from the restored copy. *)

open Cepheus
open Cepheus_server
open Cepheus_vault
module C = Check

let ( // ) = Filename.concat
let root = (try Sys.getenv "CEPHEUS_TMP" with Not_found -> Filename.get_temp_dir_name ()) // "cepheus-ops"

let facts dir =
  match Cepheus.open_ dir with
  | Error e -> C.fail "open %s: %s" dir (Cepheus.message e); 0, C.F.empty
  | Ok db ->
    let v = Cepheus.view db in
    let r = Cepheus.group v, C.facts_of_view v in
    Cepheus.close db;
    r

(* the oracle: groups 1..n of the journal replayed onto the empty state *)
let oracle dir n =
  let id = Engine.read_meta Disk.real dir in
  let v = ref (Store.empty ()) in
  Journal.read Disk.real (dir // "journal") id (fun g -> if g.Group.n <= n then v := Resolve.replay !v g);
  C.facts_of_view !v

let groups dir =
  let id = Engine.read_meta Disk.real dir in
  let l = ref [] in
  Journal.read Disk.real (dir // "journal") id (fun g -> l := g :: !l);
  List.rev !l

let flip file off =
  let fd = Unix.openfile file [ Unix.O_RDWR ] 0 in
  let b = Bytes.create 1 in
  ignore (Unix.lseek fd off Unix.SEEK_SET);
  ignore (Unix.read fd b 0 1);
  Bytes.set b 0 (Char.chr (Char.code (Bytes.get b 0) lxor 0x5a));
  ignore (Unix.lseek fd off Unix.SEEK_SET);
  ignore (Unix.write fd b 0 1);
  Unix.close fd

let copy src dst = C.rmrf dst; ignore (Ops.copy_database src dst)

let contains m s =
  let rec has i = i + String.length s <= String.length m && (String.sub m i (String.length s) = s || has (i + 1)) in
  has 0
let refused f = match f () with _ -> false | exception Ops.Refused _ -> true | exception e -> C.fail "escaped: %s" (Printexc.to_string e); false

(* a command's exit status; an exception it lets escape is a failure, -1, and the checks go on *)
let code f = match f () with c -> c | exception e -> C.fail "escaped: %s" (Printexc.to_string e); -1

let segs dir = List.sort compare (List.filter (fun n -> Filename.check_suffix n ".seg") (Array.to_list (Sys.readdir (dir // "journal"))))

(* ---- a Raft server's copy of the databases from a peer (server/catchup.ml) ----
   The copy of [src] as a source sends it, taken by a follower whose data is in [root]/cdata: whole, installed at
   the start (the database replaced, the log started after the copy's index); refused, nothing applied, for a byte
   changed on its way, a path outside a database, another cluster's id, a copy behind the follower, more bytes than it
   said, a copy cut short, a copy larger than the free space; dropped when the Raft core says its log holds the entry;
   a partial copy left by a crash removed at the start. *)
let catchup src =
  let cfgf = root // "c.toml" in
  Out_channel.with_open_bin cfgf (fun oc ->
      output_string oc
        "[cluster]\nname = \"c\"\nid = \"cph-c-00000000000000c1\"\nme = \"srv2\"\n[[peer]]\nname = \"srv2\"\naddress = \"127.0.0.1:7401\"\n[clients]\nsocket = \"run\"\n[storage]\ndata = \"cdata\"\n[[database]]\nname = \"main\"\n");
  let cfg = match Config.load cfgf with Ok c -> c | Error m -> failwith m in
  C.rmrf cfg.data;
  Unix.mkdir cfg.data 0o700;
  Unix.mkdir (cfg.data // "raft") 0o700;
  let id = Engine.read_meta Disk.real src in
  let frames = ref [] in
  Catchup.serve ~dbs:[ "main", src ] ~start:(fun () -> 7, 2) ~renew:ignore ~send:(fun b -> frames := Buffer.contents b :: !frames)
    ~error:(fun c m -> C.fail "the source refused: %s %s" c m);
  let sent = List.rev !frames in
  let run ?(id_of = fun _ -> id) ?(published = fun _ -> 0) ?(decide = fun _ _ -> true) frames =
    let q = ref frames in
    let next () =
      match !q with
      | f :: rest -> q := rest; Replica.k_copy, 0, Codec.reader (Bytes.of_string f) 0 (String.length f)
      | [] -> raise (Replica.Broken "the peer closed the connection")
    in
    Catchup.fetch cfg ~source:"srv1" ~id_of ~published ~decide ~send:ignore ~next
  in
  let tag f = Char.code f.[0] in
  let field f = let r = Codec.reader (Bytes.of_string f) 1 (String.length f - 1) in r in
  let rel_of f = let r = field f in ignore (Codec.get_string r); Codec.get_string r in
  (* the frames after the File frame of the first segment of the journal, its first Bytes frame changed *)
  let rec change pick g = function
    | f :: b :: rest when tag f = 2 && pick (rel_of f) && tag b = 3 -> f :: g b :: rest
    | f :: rest -> f :: change pick g rest
    | [] -> []
  in
  let flip b = let x = Bytes.of_string b in let o = min (Bytes.length x - 1) 200 in Bytes.set x o (Char.chr (Char.code (Bytes.get x o) lxor 0x41)); Bytes.to_string x in
  let journal r = String.length r > 8 && String.sub r 0 8 = "journal/" in
  let nothing () = not (Sys.file_exists (cfg.data // "raft" // "copy")) && not (Sys.file_exists (cfg.data // "raft" // "copy.partial")) in
  let refused what o = match o with
    | Catchup.Refused m -> C.check (nothing ()) "a copy refused (%s): %s; nothing left" what m
    | Catchup.Installed _ -> C.fail "a copy taken (%s)" what
    | Catchup.Dropped _ -> C.fail "a copy dropped (%s)" what
  in
  refused "a byte of a segment changed on its way" (run (change journal flip sent));
  refused "a path outside a database" (run (change journal (fun b -> b) (List.map (fun f -> if tag f = 2 && journal (rel_of f) then begin
      let b = Buffer.create 64 in Buffer.add_uint8 b 2; Codec.put_string b "main"; Codec.put_string b "../../evil"; Codec.put_varint b 10; Buffer.contents b end else f) sent)));
  refused "another cluster's database" (run ~id_of:(fun _ -> "0123456789abcdef") sent);
  refused "a copy behind this server" (run ~published:(fun _ -> max_int) sent);
  refused "cut short" (run (List.filteri (fun i _ -> i < List.length sent / 2) sent));
  refused "more bytes than it said" (run (List.concat_map (fun f -> if tag f = 3 then [ f; f ] else [ f ]) sent));
  let huge = let b = Buffer.create 32 in Buffer.add_uint8 b 1; Codec.put_varint b 7; Codec.put_varint b 2; Codec.put_varint b (1 lsl 61); Codec.put_varint b 1; Buffer.contents b in
  refused "larger than the free space" (run (huge :: List.tl sent));
  (match run ~decide:(fun _ _ -> false) sent with
   | Catchup.Dropped 7 -> C.check (nothing ()) "a copy the Raft core does not need: dropped, nothing left"
   | _ -> C.fail "a copy the core does not need was not dropped");
  (* whole: committed, installed at the start *)
  (match run sent with
   | Catchup.Installed 7 ->
     C.check (Sys.file_exists (cfg.data // "raft" // "copy" // "index")) "a whole copy: committed (its index)";
     (* a crash after the commit point, then a partial copy of a later try left too *)
     Unix.mkdir (cfg.data // "raft" // "copy.partial") 0o700;
     C.check (Catchup.at_start cfg = Ok ()) "installed at the start";
     C.check (nothing ()) "the copy's folders removed";
     let g, f = facts (cfg.data // "main") in
     C.check (g = fst (facts src) && C.F.equal f (snd (facts src))) "the database replaced by the copy (group %d)" g;
     let rl, r = Raftlog.open_ Disk.real (cfg.data // "raft") ~cluster:cfg.id in
     C.check (r.start = 8 && r.prev_term = 2 && Array.length r.terms = 0) "the log starts after the copy's index (%d, term %d)" r.start r.prev_term;
     Raftlog.close rl
   | Catchup.Installed x -> C.fail "a whole copy installed at %d, not 7" x
   | Catchup.Refused m -> C.fail "a whole copy refused: %s" m
   | Catchup.Dropped _ -> C.fail "a whole copy dropped");
  (* the install repeated after a crash in it: the index still there, the database already moved *)
  Unix.mkdir (cfg.data // "raft" // "copy") 0o700;
  Replica.write_private (cfg.data // "raft" // "copy" // "index") (Bytes.to_string (Raftlog.encode_copy ~index:9 ~term:3 ~source:"srv1"));
  C.check (Catchup.at_start cfg = Ok ()) "an install a crash cut: repeated";
  let rl, r = Raftlog.open_ Disk.real (cfg.data // "raft") ~cluster:cfg.id in
  C.check (r.start = 10 && r.prev_term = 3 && fst (facts (cfg.data // "main")) = fst (facts src)) "repeated: the log at 10, the database kept";
  Raftlog.close rl;
  C.rmrf cfg.data
(* ops_unit.exe --hold DIR: the database in DIR held open (as a server holds it) until stdin closes *)
let hold dir =
  match Cepheus.open_ dir with
  | Error e -> prerr_endline (Cepheus.message e); exit 2
  | Ok _ ->
    print_endline "ready";
    (try ignore (In_channel.input_all stdin) with _ -> ());
    exit 0

let () =
  if Array.length Sys.argv = 3 && Sys.argv.(1) = "--hold" then hold Sys.argv.(2);
  Ops.quiet := true;
  C.rmrf root;
  Unix.mkdir root 0o700;
  Journal.segment_limit := 6000;
  Engine.compact_min := 120;
  let data = root // "data" in
  Unix.mkdir data 0o700;
  let src = data // "main" in
  (* the database: four threads, each a thing a write, and changes of earlier things (replaced values, retractions) *)
  let db = Result.get_ok (Cepheus.open_ src) in
  let[@warning "-8"] (Ok [ k; name ]) = Cepheus.declare db [ Cepheus.prop "k" Tint; Cepheus.prop "name" Ttext ] in
  let writer t () =
    let mine = ref [] in
    for i = 1 to 120 do
      let ops =
        match !mine with
        | e :: _ when i mod 5 = 0 -> [ Resolve.Add (e, name, Text (Printf.sprintf "renamed %d %d" t i)) ]
        | _ :: e :: _ when i mod 7 = 0 -> [ Resolve.Retract (e, k, Int ((t * 1000) + i - 1)); Resolve.Add (e, k, Int (-i)) ]
        | _ -> [ Resolve.Add (-1, k, Int ((t * 1000) + i)); Resolve.Add (-1, name, Text (Printf.sprintf "t%d-%d" t i)) ]
      in
      match Cepheus.write db ~by:t ~why:"ops" ops with
      | Ok r -> (match r.things with (_, e) :: _ -> mine := e :: !mine | [] -> ())
      | Error (Conflict _ | Invalid _) -> ()
      | Error e -> C.fail "write: %s" (Cepheus.message e)
    done
  in
  List.iter Thread.join (List.init 4 (fun t -> Thread.create (writer t) ()));
  Cepheus.close db;
  let all = groups src in
  let last = List.length all in
  let id = Engine.read_meta Disk.real src in
  (* frames of several groups, and segment boundaries *)
  let multi = ref [] in
  ignore (Journal.check ~frame:(fun p count _ -> if count > 2 then multi := (p.next + 1) :: !multi) ~tail:Journal.Strict Disk.real (src // "journal") id);
  let bounds = List.concat_map (fun n -> let s = int_of_string (String.sub n 0 20) in [ s - 1; s ]) (segs src) in
  let runs = List.map (fun (_, hi, _) -> hi) (Snapshot.list Disk.real (src // "snapshots")) in
  C.check (List.length (segs src) >= 4) "several segments (%d)" (List.length (segs src));
  C.check (!multi <> []) "frames of several groups (%d)" (List.length !multi);
  C.check (runs <> []) "runs (%d)" (List.length runs);
  C.check (Ops.verify src = Ops.exit_ok) "verify: the database is whole";
  (* restore to N *)
  let targets =
    List.sort_uniq compare
      (List.filter (fun n -> n >= 1 && n <= last)
         ([ 1; 2; 3; last - 1; last ] @ bounds @ List.concat_map (fun h -> [ h - 1; h; h + 1 ]) runs
         @ List.filteri (fun i _ -> i < 12) !multi))
  in
  List.iter
    (fun n ->
      let dst = root // "r" in
      C.rmrf dst;
      let code = Ops.restore ~target:(Ops.Group n) ~replace:false src dst in
      C.check (code = Ops.exit_ok) "restore --to-group %d: done" n;
      let g, f = facts dst in
      C.check (g = n) "restore --to-group %d: at group %d" n g;
      C.check (C.F.equal f (oracle src n)) "restore --to-group %d: the facts of the journal's groups 1..%d" n n;
      C.check (Ops.verify dst = Ops.exit_ok) "restore --to-group %d: whole" n;
      let h = Replica.load_epochs dst in
      C.check (h = [ 1, 1; 2, n + 1 ]) "restore --to-group %d: epoch 2 from group %d" n (n + 1);
      (* a replica of the old history past n is refused; one at n or before follows *)
      C.check (Result.is_error (Replica.follows ~primary:h ~group:n ~replica:[ 1, 1 ] ~last:(n + 1))) "a replica at %d is refused" (n + 1);
      C.check (Replica.follows ~primary:h ~group:n ~replica:[ 1, 1 ] ~last:n = Ok ()) "a replica at %d follows" n)
    targets;
  (* to the end; and a second time with --replace *)
  let dst = root // "r" in
  C.rmrf dst;
  C.check (Ops.restore ~replace:false src dst = Ops.exit_ok) "restore to the end";
  let g, f = facts dst in
  C.check (g = last && C.F.equal f (oracle src last)) "restore to the end: group %d and its facts" last;
  C.check (refused (fun () -> Ops.restore ~replace:false src dst)) "a folder that holds a database is refused";
  C.check (Ops.restore ~target:(Ops.Group 5) ~replace:true src dst = Ops.exit_ok) "--replace";
  let aside = List.filter (fun n -> String.length n > 2 && String.sub n 0 2 = "r." && n <> "r.restoring") (Array.to_list (Sys.readdir root)) in
  C.check (List.length aside = 1) "--replace: the old database moved aside (%s)" (String.concat " " aside);
  (match aside with a :: _ -> C.check (fst (facts (root // a)) = last) "--replace: the old one kept whole" | [] -> ());
  C.check (fst (facts dst) = 5) "--replace: the new one at group 5";
  let other = root // "other" in
  Unix.mkdir other 0o700;
  Out_channel.with_open_bin (other // "x") (fun oc -> output_string oc "x");
  C.check (refused (fun () -> Ops.restore ~replace:true src other)) "a folder that holds something else is refused";
  C.check (refused (fun () -> Ops.restore ~target:(Ops.Group (last + 1)) ~replace:false src (root // "r9"))) "a group past the end is refused";
  C.check (not (Sys.file_exists (root // "r9")) && not (Sys.file_exists (root // "r9.restoring"))) "a refused restore leaves nothing";
  (* to a time: the last group before the first written after it *)
  let mid = List.nth all (last / 2) in
  let expect = let rec go acc = function (g : Group.t) :: r when g.time <= mid.time -> go g.n r | _ -> acc in go 0 all in
  C.rmrf dst;
  C.check (Ops.restore ~target:(Ops.Time mid.time) ~replace:false src dst = Ops.exit_ok) "--to-time";
  C.check (fst (facts dst) = expect) "--to-time: at group %d (the last at or before the time)" expect;
  C.check (Ops.parse_time "2026-11-24T03:00:00Z" = Some 1795489200000) "a time in UTC";
  C.check (Ops.parse_time "2026-11-24 03:00Z" = Some 1795489200000) "a time without seconds, a space for the T";
  C.check (Ops.parse_time "2026-13-24T03:00" = None) "a time that is none";
  (* exactly its digits, a day of the calendar, 00 to 59: anything else refused, never moved to another day *)
  List.iter (fun t -> C.check (Ops.parse_time t = None) "--to-time %S refused" t)
    [ "2026-02-31T12:00"; "2023-02-29T12:00Z"; "1900-02-29T00:00Z"; "2026-07-01T12:00:60"; "2026-11-24T24:00Z"; "2026-11-24T10:60Z"; "2026-7-1T1:2";
      "+026-07-01T12:00"; "2026-07-01T12:00 "; "99999-01-01T00:00"; "2026-07-01T-1:00"; "2026-07-01T12:00:00.5Z"; "2026-07-01"; "Z"; "" ];
  C.check (Ops.parse_time "2024-02-29T12:00Z" = Some 1709208000000 && Ops.parse_time "2000-02-29T00:00Z" = Some 951782400000) "leap days";
  C.check (Ops.parse_time "9999-12-31T23:59:59Z" = Some 253402300799000 && Ops.parse_time "0000-01-01T00:00Z" = Some (-62167219200000)) "years 0 to 9999";
  (* damage, named *)
  let d = root // "d" in
  let jseg d i = d // "journal" // List.nth (segs d) i in
  copy src d;
  flip (jseg d 1) (40 + 28 + 3);
  let r = Ops.check ~tail:Journal.Crash ~live:false d in
  C.check (List.length r.damages = 1 && contains (List.hd r.damages) (List.nth (segs d) 1))
    "a byte of a frame changed: one damage, naming its segment (%s)" (String.concat "; " r.damages);
  C.check (r.segments = List.length (segs d)) "the other segments are checked (%d)" r.segments;
  C.check (Ops.verify d = Ops.exit_damage) "verify: exit 1 on damage";
  copy src d;
  Sys.remove (jseg d 2);
  let r = Ops.check ~tail:Journal.Crash ~live:false d in
  C.check (List.exists (fun m -> contains m "a segment is missing") r.damages)
    "a segment removed: named (%s)" (String.concat "; " r.damages);
  copy src d;
  (match Snapshot.list Disk.real (d // "snapshots") with
   | (_, _, n) :: _ ->
     let f = d // "snapshots" // n in
     (match Snapshot.file_page Disk.real f 0 with
      | Some p -> flip f (Snapshot.header + (p * Pages.size) + 100)
      | None -> C.fail "the run's first page");
     let r = Ops.check ~tail:Journal.Crash ~live:false d in
     C.check (List.exists (fun m -> contains m "snapshots/") r.damages) "a page of a run changed: named (%s)" (String.concat "; " r.damages)
   | [] -> C.fail "a run to damage");
  (* a torn tail: a note after a crash, damage after a clean close *)
  copy src d;
  let newest = jseg d (List.length (segs d) - 1) in
  let size = (Unix.stat newest).st_size in
  Unix.truncate newest (size - 5);
  let r = Ops.check ~tail:Journal.Crash ~live:false d in
  C.check (r.damages = [] && r.notes <> [] && r.group < last) "a torn tail after a crash: a note (%s)" (String.concat "; " r.notes);
  let r = Ops.check ~tail:Journal.Strict ~live:false d in
  C.check (r.damages <> []) "a torn tail after a clean close: damage";
  (* a copy whose newest frame's header was not written yet, its trailer was: the tail of a copy, damage after a crash *)
  copy src d;
  let newest = jseg d (List.length (segs d) - 1) in
  let c = Journal.check ~tail:Journal.Strict Disk.real (d // "journal") id in
  let s = List.nth c.segments (List.length c.segments - 1) in
  let at = ref 40 in
  ignore (Journal.check ~frame:(fun p _ stop -> if stop = s.send && p.segment = s.sfirst then at := p.offset) ~tail:Journal.Strict Disk.real (d // "journal") id);
  let fd = Unix.openfile newest [ Unix.O_RDWR ] 0 in
  ignore (Unix.lseek fd !at Unix.SEEK_SET);
  ignore (Unix.write fd (Bytes.make 28 '\000') 0 28);
  Unix.close fd;
  let r = Ops.check ~tail:Journal.Copy ~live:false d in
  C.check (r.damages = [] && r.tail = Some (s.sfirst, !at)) "a copy: the frame whose header is not written yet is its tail";
  let r = Ops.check ~tail:Journal.Crash ~live:false d in
  C.check (r.damages <> []) "after a crash, the same bytes are damage (written whole)";
  (* a frame damaged in the middle of the newest segment of a copy: damage, never a tail that would cut the frames
     after it *)
  copy src d;
  let newest = jseg d (List.length (segs d) - 1) in
  flip newest (40 + 28 + 2);
  let r = Ops.check ~tail:Journal.Copy ~live:false d in
  C.check (r.damages <> [] && r.tail = None) "a copy: a damaged frame followed by frames that check is damage (%s)" (String.concat "; " r.damages);
  (* a restore above every epoch the source knew: a source promoted at N + 1, restored to N, opens epoch 3 *)
  copy src d;
  Replica.save_epochs d [ 1, 1; 2, 41 ];
  C.rmrf dst;
  C.check (Ops.restore ~target:(Ops.Group 40) ~replace:false d dst = Ops.exit_ok) "restore of a promoted history to the group before its promotion";
  C.check (Replica.load_epochs dst = [ 1, 1; 3, 41 ]) "a new epoch above the dropped one (3, not 2 again)";
  (* --replace when DIR.before-restore-DATE is taken (an earlier --replace of the same second, or a folder of that
     name): the database is moved aside under a free name (-2), never over the other folder *)
  let stamp t = let t = Unix.localtime t in
    Printf.sprintf "%04d-%02d-%02dT%02d%02d%02d" (t.tm_year + 1900) (t.tm_mon + 1) t.tm_mday t.tm_hour t.tm_min t.tm_sec in
  let now = Unix.time () in
  let planted = List.init 10 (fun i -> dst ^ ".before-restore-" ^ stamp (now +. float i)) in
  List.iter (fun p -> Unix.mkdir p 0o700; Out_channel.with_open_bin (p // "mine") (fun oc -> output_string oc "mine")) planted;
  C.check (code (fun () -> Ops.restore ~target:(Ops.Group 40) ~replace:true d dst) = Ops.exit_ok) "the same restore again over it, its aside name taken";
  let asides = List.filter (fun n -> contains n "r.before-restore-" && Filename.check_suffix n "-2") (Array.to_list (Sys.readdir root)) in
  C.check (List.length asides = 1 && Sys.file_exists (root // List.hd asides // "journal")) "the database moved aside as ...-2 (%s)" (String.concat " " asides);
  C.check (List.for_all (fun p -> Sys.readdir p = [| "mine" |]) planted) "the folders of the names taken unchanged";
  List.iter C.rmrf planted;
  C.check (Replica.load_epochs dst = [ 1, 1; 4, 41 ]) "above the replaced database's epoch too (4)";
  (* the vault: files in packs of 64 KiB, so that closed packs have their index *)
  Vault.pack_limit := 65536;
  let master = String.init 32 (fun i -> Char.chr (i * 7 land 255)) in
  let rng = Rng.make 11 in
  let bytes = Bytes.init 600_000 (fun _ -> Char.chr (Rng.int rng 256)) in
  let root_name =
    match Vault.open_ Disk.real (src // "vault") ~master with
    | Error e -> C.fail "vault: %s" (Vault.message e); ""
    | Ok v ->
      let w = Result.get_ok (Vault.writer v ~domain:0 ~cold:false) in
      ignore (Vault.feed w bytes 0 (Bytes.length bytes));
      let rt, _ = Result.get_ok (Vault.finish w) in
      Vault.close v;
      rt
  in
  let r = Ops.check ~tail:Journal.Strict ~live:false src in
  C.check (r.damages = [] && r.packs >= 2 && r.records > 0) "the vault checked: %d packs, %d records" r.packs r.records;
  (* a backup of the stopped server's database *)
  let cfgf = root // "cluster.toml" in
  Out_channel.with_open_bin cfgf (fun oc ->
      output_string oc
        "[cluster]\nname = \"ops\"\nid = \"cph-c-00000000000000d1\"\nme = \"srv1\"\n[[peer]]\nname = \"srv1\"\naddress = \"127.0.0.1:7401\"\n[clients]\nsocket = \"run\"\n[storage]\ndata = \"data\"\n[[database]]\nname = \"main\"\n[[database]]\nname = \"later\"\n");
  let cfg = match Config.load cfgf with Ok c -> c | Error m -> failwith m in
  let dest = root // "backup" in
  Unix.mkdir dest 0o700;
  Unix.mkdir (dest // "2020-01-01T000000.partial") 0o700;
  Unix.mkdir (dest // "2020-01-01T000000.partial" // "main") 0o700;
  (* a .partial of another program's (a download): never a backup's, kept *)
  Unix.mkdir (dest // "movie.partial") 0o700;
  Out_channel.with_open_bin (dest // "movie.partial" // "film") (fun oc -> output_string oc "x");
  C.check (Ops.backup cfg dest = Ops.exit_ok) "backup";
  let dated = List.filter (fun n -> n <> "cepheus-backup.lock" && n <> "movie.partial") (Array.to_list (Sys.readdir dest)) in
  C.check (List.length dated = 1 && not (Filename.check_suffix (List.hd dated) ".partial")) "one dated folder, the partial one removed (%s)" (String.concat " " dated);
  C.check (Sys.file_exists (dest // "movie.partial" // "film")) "a .partial a backup does not make is kept";
  (* a DEST that others may write, a lock planted there as a link: refused, nothing made through the link *)
  let dest2 = root // "backup2" in
  Unix.mkdir dest2 0o700;
  Unix.chmod dest2 0o777;
  C.check (refused (fun () -> Ops.backup cfg dest2)) "a DEST writable by others: refused";
  Unix.chmod dest2 0o700;
  List.iter (fun n -> C.rmrf (dest2 // n)) (Array.to_list (Sys.readdir dest2));
  Unix.symlink (root // "planted") (dest2 // "cepheus-backup.lock");
  C.check (refused (fun () -> Ops.backup cfg dest2) && not (Sys.file_exists (root // "planted"))) "a lock planted as a link: refused, nothing made through it";
  let b = dest // List.hd dated // "main" in
  C.check (Sys.file_exists (b // "closed")) "the copy is marked closed";
  C.check ((Ops.check ~tail:Journal.Strict ~live:false b).damages = []) "the copy is whole";
  let g, f = facts b in
  C.check (g = last && C.F.equal f (oracle src last)) "the copy holds the source's groups and facts";
  C.rmrf dst;
  C.check (Ops.restore ~replace:false (dest // List.hd dated // "main") dst = Ops.exit_ok) "restore from the backup";
  (match Vault.open_ Disk.real (dst // "vault") ~master with
   | Error e -> C.fail "the restored vault: %s" (Vault.message e)
   | Ok v ->
     let got = Buffer.create 600_000 in
     (match Vault.load v root_name ~from:0 ~len:(Bytes.length bytes) (fun b o n -> Buffer.add_subbytes got b o n) with
      | Ok () -> C.check (Buffer.to_bytes got = bytes) "the restored vault gives the file's bytes"
      | Error e -> C.fail "load: %s" (Vault.message e));
     Vault.close v);
  (* a vault record changed: named *)
  copy src d;
  flip (d // "vault" // "packs" // "00000001.pack") (16 + 64 + 10);
  let r = Ops.check ~tail:Journal.Strict ~live:false d in
  C.check (List.exists (fun m -> contains m "vault/") r.damages) "a vault record changed: named (%s)" (String.concat "; " r.damages);
  (* a database a server's buffer must recover first is refused *)
  copy src d;
  if Sys.file_exists (d // "closed") then Sys.remove (d // "closed");
  Out_channel.with_open_bin (d // "shared") ignore;
  C.check (refused (fun () -> Ops.verify d)) "shared and not closed: refused";
  catchup src;
  (* a run whose journal position is the end of a segment that is no longer the newest: the frame after its groups
     began a new segment (an open resumes from it); whole for verify, restore and restore to its group and after *)
  let limit = !Journal.segment_limit in
  Journal.segment_limit := 2000;
  let se = root // "segend" in
  let db = Result.get_ok (Cepheus.open_ se) in
  let[@warning "-8"] (Ok [ p ]) = Cepheus.declare db [ Cepheus.prop "p" Ttext ] in
  let w s = match Cepheus.write db [ Resolve.Add (-1, p, Text s) ] with Ok _ -> () | Error e -> C.fail "write: %s" (Cepheus.message e) in
  w (String.make 1200 'a');
  (match Cepheus.snapshot db with Ok () -> () | Error e -> C.fail "snapshot: %s" (Cepheus.message e));
  w (String.make 1200 'b');
  w "c";
  Cepheus.close db;
  Journal.segment_limit := limit;
  let sid = Engine.read_meta Disk.real se in
  let at_seg_end =
    List.filter_map
      (fun ((_, hi, _) as r) ->
        let pos, _ = Snapshot.verify Disk.real (se // "snapshots") r sid in
        if List.mem (Journal.segment_name pos.Journal.next) (segs se) then Some hi else None)
      (Snapshot.list Disk.real (se // "snapshots"))
  in
  C.check (at_seg_end <> [] && List.length (segs se) >= 2) "a run at the end of a segment the next one follows (%d runs)" (List.length at_seg_end);
  C.check (code (fun () -> Ops.verify se) = Ops.exit_ok) "a run at a segment's end: verify whole";
  let sg = fst (facts se) in
  List.iter
    (fun (what, target, at) ->
      let r = root // "segend-r" in
      C.rmrf r;
      C.check (code (fun () -> Ops.restore ~target ~replace:false se r) = Ops.exit_ok && fst (facts r) = at && code (fun () -> Ops.verify r) = Ops.exit_ok)
        "a run at a segment's end: restore %s, at group %d and whole" what at)
    ([ "to the end", Ops.End, sg ] @ List.concat_map (fun h -> [ Printf.sprintf "--to-group %d" h, Ops.Group h, h; Printf.sprintf "--to-group %d" (h + 1), Ops.Group (h + 1), h + 1 ]) at_seg_end);
  (* restore --replace over a database of a server that crashed while written through its commit buffer: replaced as
     it is (moved aside); a buffer that an unclean stop left refuses only when it holds frames of the database *)
  let rd = root // "rdata" in
  Unix.mkdir rd 0o700;
  let done_ f = match f () with c -> c = Ops.exit_ok | exception Ops.Refused m -> C.fail "refused: %s" m; false | exception e -> C.fail "escaped: %s" (Printexc.to_string e); false in
  let crashed n =
    let shop = rd // n in
    if done_ (fun () -> Ops.restore ~replace:false src shop) then begin
      Sys.remove (shop // "closed");
      Out_channel.with_open_bin (shop // "shared") ignore
    end;
    shop
  in
  C.check (done_ (fun () -> Ops.restore ~target:(Ops.Group 5) ~replace:true src (crashed "shop1")) && fst (facts (rd // "shop1")) = 5)
    "--replace over a database that crashed through the commit buffer: replaced";
  (* a buffer as the server's leaves it at a crash: a round of a frame of the database [bid] *)
  let buffer_with bid =
    List.iter (fun n -> if Sys.file_exists (rd // n) then Sys.remove (rd // n)) [ "server.wal.1"; "server.wal.2" ];
    let w = Wal.recover Disk.real rd in
    Wal.start w;
    let jd = root // "bj" in
    C.rmrf jd;
    Unix.mkdir jd 0o700;
    let j = Journal.create Disk.real jd bid in
    let alone = !Wal.alone in
    Wal.alone := false;
    Wal.attach w bid j;
    let body = Buffer.create 8 in
    Buffer.add_string body "a group";
    Journal.append j body 1 1;
    Wal.alone := alone;
    let kept = List.filter_map (fun n -> if Sys.file_exists (rd // n) then Some (n, In_channel.with_open_bin (rd // n) In_channel.input_all) else None) [ "server.wal.1"; "server.wal.2" ] in
    Wal.stop w;
    Journal.close j;
    List.iter (fun (n, b) -> Out_channel.with_open_bin (rd // n) (fun oc -> output_string oc b)) kept;
    C.check (kept <> []) "a commit buffer left with a round"
  in
  buffer_with (String.make 16 'z');
  C.check (done_ (fun () -> Ops.restore ~target:(Ops.Group 5) ~replace:true src (crashed "shop2"))) "--replace beside a buffer that holds frames of another database: done";
  let shop3 = crashed "shop3" in
  buffer_with id;
  C.check (refused (fun () -> Ops.restore ~target:(Ops.Group 5) ~replace:true src shop3)) "--replace beside a buffer that holds frames of the database: refused";
  C.check (refused (fun () -> Ops.restore ~replace:false src (rd // "shop4"))) "a restore into a new folder beside it: refused";
  (* a crashed database whose newest frame's trailer alone is broken (kept, as recovery keeps and rebuilds it): its
     backup, marked closed, verifies whole *)
  let t10 = root // "t10" in
  Unix.mkdir t10 0o700;
  Unix.mkdir (t10 // "data") 0o700;
  let one_db dir = Out_channel.with_open_bin (dir // "cluster.toml") (fun oc ->
      output_string oc "[cluster]\nname = \"ops\"\nid = \"cph-c-00000000000000d1\"\nme = \"srv1\"\n[[peer]]\nname = \"srv1\"\naddress = \"127.0.0.1:7401\"\n[clients]\nsocket = \"run\"\n[storage]\ndata = \"data\"\n[[database]]\nname = \"main\"\n");
    match Config.load (dir // "cluster.toml") with Ok c -> c | Error m -> failwith m
  in
  let cfg10 = one_db t10 in
  let m10 = t10 // "data" // "main" in
  copy src m10;
  let newest = jseg m10 (List.length (segs m10) - 1) in
  flip newest ((Unix.stat newest).st_size - 2);
  C.check (code (fun () -> Ops.verify m10) = Ops.exit_ok) "a crashed database, its newest trailer broken: whole (the next open rebuilds it)";
  C.check (code (fun () -> Ops.backup cfg10 (t10 // "b")) = Ops.exit_ok) "its backup";
  (match List.filter (fun n -> n <> "cepheus-backup.lock") (try Array.to_list (Sys.readdir (t10 // "b")) with Sys_error _ -> []) with
   | [ n ] -> C.check (code (fun () -> Ops.verify (t10 // "b" // n // "main")) = Ops.exit_ok) "the backup of a broken newest trailer verifies whole (the trailer written again)"
   | l -> C.fail "the backup of a broken newest trailer: %s" (String.concat " " l));
  (* a live database (another process holds it): what a frame being written shows is left out with a note (a large
     group's header still zeros, a frame not all there); a frame written whole that does not check is damage *)
  let lv = root // "live" in
  Unix.mkdir lv 0o700;
  Unix.mkdir (lv // "data") 0o700;
  let cfgl = one_db lv in
  let ld = lv // "data" // "main" in
  copy src ld;
  let to_child, from_us = Unix.pipe ~cloexec:true () and from_child, to_us = Unix.pipe ~cloexec:true () in
  let child = Unix.create_process Sys.executable_name [| Sys.executable_name; "--hold"; ld |] to_child to_us Unix.stderr in
  Unix.close to_child;
  Unix.close to_us;
  let ready = In_channel.input_line (Unix.in_channel_of_descr from_child) in
  C.check (ready = Some "ready") "the database held by another process";
  let lid = Engine.read_meta Disk.real ld in
  let newest = jseg ld (List.length (segs ld) - 1) in
  let last = ref (0, 0) in
  ignore (Journal.check ~frame:(fun p _ stop -> if p.segment = int_of_string (String.sub (Filename.basename newest) 0 20) then last := (p.offset, stop)) ~tail:Journal.Copy Disk.real (ld // "journal") lid);
  let off, stop = !last in
  let size = (Unix.stat newest).st_size in
  let frame_bytes = let b = Bytes.create (stop - off) in let fd = Unix.openfile newest [ Unix.O_RDONLY ] 0 in ignore (Unix.lseek fd off Unix.SEEK_SET); ignore (Unix.read fd b 0 (stop - off)); Unix.close fd; b in
  let append b = let fd = Unix.openfile newest [ Unix.O_WRONLY; Unix.O_APPEND ] 0 in ignore (Unix.write fd b 0 (Bytes.length b)); Unix.close fd in
  let backups = ref 0 in
  let backup_code () =
    incr backups;
    let d = lv // Printf.sprintf "b%d" !backups in
    let c = code (fun () -> Ops.backup cfgl d) in
    c, List.filter (fun n -> n <> "cepheus-backup.lock") (try Array.to_list (Sys.readdir d) with Sys_error _ -> [])
  in
  (* a large group's frame being written: its header, written last, still zeros *)
  append (Bytes.cat (Bytes.make 28 '\000') (Bytes.make 100 'x'));
  C.check (code (fun () -> Ops.verify ld) = Ops.exit_ok) "live: a header still zeros is the frame being written";
  let c, l = backup_code () in
  C.check (c = Ops.exit_ok && List.length l = 1 && code (fun () -> Ops.verify (lv // Printf.sprintf "b%d" !backups // List.hd l // "main")) = Ops.exit_ok) "live: its backup leaves it out";
  Unix.truncate newest size;
  (* a frame being appended: its header there, not all its bytes yet *)
  append (Bytes.sub frame_bytes 0 ((Bytes.length frame_bytes / 2) + 1));
  C.check (code (fun () -> Ops.verify ld) = Ops.exit_ok) "live: a frame not all there is the frame being written";
  Unix.truncate newest size;
  (* the newest frame, every byte of it there, damaged *)
  flip newest (off + 28 + 2);
  C.check (code (fun () -> Ops.verify ld) = Ops.exit_damage) "live: a frame written whole that does not check is damage";
  let c, l = backup_code () in
  C.check (c = Ops.exit_damage && List.exists (fun n -> Filename.check_suffix n ".damaged") l) "live: its backup is damaged, never cut in silence";
  Unix.close from_us;
  ignore (Unix.waitpid [] child);
  Unix.close from_child;
  (* last, since it changes the process's zone: a local time the clocks skip is none (Paris, 2026-03-29, 02:00 to 03:00) *)
  if Sys.file_exists "/usr/share/zoneinfo/Europe/Paris" then begin
    Unix.putenv "TZ" "Europe/Paris";
    C.check (Ops.parse_time "2026-03-29T02:30" = None && Ops.parse_time "2026-03-29T03:30" <> None && Ops.parse_time "2026-03-29T02:30Z" <> None)
      "a local time the clocks skip is refused"
  end;
  C.rmrf root;
  C.finish "ops"
