(* The figures of the machine: how a write reaches the journal (journal-commit.svg), the server and its three ways
   to read (server-reads.svg), a write with a replica and in a Raft cluster (replica-raft.svg), a failover
   (raft-failover.svg), a watch (watch-flow.svg) and the vault's chunks (vault-chunks.svg, cut by the vault's own
   chunker). Their numbers are the book's: the sizes of formats.md, the times measured in server.md. *)

open Draw

(* a box with a title and lines under it *)
let box f ?(cls = "box") ?(tcls = "h") x y w h title lines =
  rect f ~r:4 cls x y w h;
  if title <> "" then text f ~cls:tcls (x + 10) (y + 18) title;
  List.iteri (fun k (c, s) -> if c = "code" then code f (x + 10) (y + 38 + (k * 17)) s else text f ~cls:c (x + 10) (y + 38 + (k * 17)) s) lines

(* 1. group commit: the writer resolves while the syncer forces a frame; then a segment's frames *)
let journal_commit docs =
  both docs "journal-commit.svg" (fun l f ->
      let x0 = 110 and ms = 64 (* pixels a millisecond *) in
      let t x = x0 + int_of_float (x *. float_of_int ms) in
      let lane = [| 44; 92; 152 |] in
      List.iteri (fun k s -> text f ~cls:"h" 16 (lane.(k) + 4) s) [ tr l "programs" "programmes"; "writer"; "syncer" ];
      Array.iter (fun y -> line f "grid" x0 y 700 y) lane;
      (* the writes: when each comes, the frame it goes into *)
      let writes = [ 0.1, 1; 0.5, 2; 1.4, 2; 2.2, 2; 3.6, 3 ] in
      let frames = [ 1, 0.25, 3.25; 2, 3.35, 6.35; 3, 6.45, 9.25 ] in
      List.iteri
        (fun k (at, fr) ->
          let x = t at in
          arrow f x (lane.(0) - 14) x (lane.(1) - 8);
          code f ~cls:"s" ~anchor:"middle" x (lane.(0) - 18) (Printf.sprintf "w%d" (k + 1));
          rect f ~r:2 "frame" (x - 1) (lane.(1) - 7) 14 14;
          ignore fr)
        writes;
      List.iter
        (fun (n, a, b) ->
          rect f ~r:3 "cur" (t a) (lane.(2) - 12) (t b - t a) 24;
          text f ~cls:"a sm" (t a + 8) (lane.(2) + 4) (if b < 9. then Printf.sprintf (trf l "frame %d: pwrite, fsync" "frame %d : pwrite, fsync") n else Printf.sprintf "frame %d" n);
          (* the frame's end: its view published, its programs answered *)
          if b < 9. then arrow f ~cls:"br" (t b) (lane.(2) - 14) (t b) (lane.(0) + 8))
        frames;
      text f ~cls:"a sm" (t 3.25 + 6) (lane.(0) + 22) (tr l "w1 answered" "w1 répondu");
      text f ~cls:"a sm" (t 6.35 + 6) (lane.(0) + 22) (tr l "w2 w3 w4 answered" "w2 w3 w4 répondus");
      path f "br" (Printf.sprintf "M %d %d v 6 H %d v -6" (t 0.5 - 2) (lane.(1) + 14) (t 2.2 + 14));
      text f ~cls:"s sm" (t 0.5) (lane.(1) + 32) (tr l "they wait together for frame 2" "elles attendent la frame 2");
      (* the time axis *)
      let ya = lane.(2) + 30 in
      line f "axis" x0 ya 700 ya;
      for k = 0 to 9 do
        let x = t (float_of_int k) in
        if x <= 700 then (line f "axis" x ya x (ya + 4); text f ~cls:"s sm" ~anchor:"middle" x (ya + 16) (string_of_int k))
      done;
      text f ~cls:"s sm" 16 (ya + 16) "ms";
      let yn = para f ~cls:"s sm" ~n:104 16 (ya + 34) (tr l "An fsync takes about 3 ms on the test machine's SSD: one for frame 1's group, one for the 3 groups of frame 2." "Un fsync prend environ 3 ms sur le SSD de la machine de test : un pour le groupe de la frame 1, un pour les 3 groupes de la frame 2.") in
      (* a segment: its header, then frames appended *)
      let ys = yn + 22 in
      code f ~cls:"h" 16 ys "DIR/journal/00000000000000000001.seg";
      let y = ys + 12 in
      let seg = [ "box", 56, "segment", "40 B"; "cur", 60, tr l "header" "en-tête", "28 B"; "row", 170, tr l "groups, in columns" "groupes, en colonnes", "frame 1"; "cur", 60, "trailer", "16 B";
                  "cur", 60, tr l "header" "en-tête", "28 B"; "row", 170, tr l "groups, in columns" "groupes, en colonnes", "frame 2"; "cur", 60, "trailer", "16 B" ] in
      let x = ref 16 in
      List.iter
        (fun (cls, w, a, b) ->
          rect f cls !x y w 40;
          text f ~cls:"sm" ~anchor:"middle" (!x + (w / 2)) (y + 17) a;
          code f ~cls:"s sm" ~anchor:"middle" (!x + (w / 2)) (y + 33) b;
          x := !x + w)
        seg;
      line f "dash" !x (y + 20) (!x + 40) (y + 20);
      text f ~cls:"s sm" 696 ys ~anchor:"end" (tr l "only ever appended to" "on n'y fait qu'ajouter");
      let yb = para f 16 (y + 64)
          (tr l "A frame's header: magic CPHF, body length, first group, group count, body CRC, header CRC; its trailer repeats the length and both CRCs. A frame holds whole groups: a crash leaves a group whole or absent."
             "L'en-tête d'une frame : magic CPHF, longueur du corps, premier groupe, nombre de groupes, CRC du corps, CRC de l'en-tête ; son trailer répète la longueur et les deux CRC. Une frame tient des groupes entiers : un crash laisse un groupe entier ou absent.") in
      712, yb + 10,
      tr l "Group commit: writes that come during an fsync share the next one; the frames of a journal segment"
        "Group commit : les écritures venues pendant un fsync partagent le suivant ; les frames d'un segment du journal")

(* 2. the server, and a read three ways: TCP with TLS, the Unix socket, local reads *)
let server_reads docs =
  both docs "server-reads.svg" (fun l f ->
      let sx = 16 and sw = 280 in
      rect f ~r:6 "box" sx 16 sw 352;
      code f ~cls:"h" (sx + 12) 38 "cepheus serve";
      let part y h title lines = box f ~cls:"row" (sx + 12) y (sw - 24) h title lines in
      part 50 62 "listeners" [ "code", "DIR/.s.cepheus.PORT"; "code", "TCP host:port, TLS 1.3" ];
      part 120 38 (tr l "I/O domains: a thread a connection" "I/O domains : un thread par connexion") [];
      part 164 92 (tr l "a database" "une base") [ "", "writer, syncer, merges"; "code", "journal/*.seg  snapshots/*.run"; "", tr l "its views: runs + delta" "ses vues : runs + delta" ];
      part 264 40 "commit buffer" [];
      text f ~cls:"s sm" (sx + 130) 282 (tr l "one fsync a round," "un fsync par tour,");
      text f ~cls:"s sm" (sx + 130) 296 (tr l "every database" "toutes les bases");
      part 312 46 (tr l "the visibility page" "la page de visibilité") [];
      code f ~cls:"s sm" (sx + 22) 350 "/dev/shm/cepheus-ID.visible";
      (* the three programs *)
      let px = 462 and pw = 234 in
      let prog y title sub cost = box f ~cls:"row" px y pw 70 title [ "s sm", sub ]; text f ~cls:"a h" (px + pw - 10) (y + 60) ~anchor:"end" cost in
      let both_ways x1 y1 x2 y2 = arrow f x1 y1 x2 y2; arrow f x2 y2 x1 y1 in
      prog 40 (tr l "a program elsewhere" "un programme ailleurs") "TCP + TLS 1.3" (tr l "41.3 µs a read" "41,3 µs par lecture");
      both_ways (px - 4) 72 (sx + sw - 4) 72;
      prog 140 (tr l "a program on this machine" "un programme sur cette machine") "Unix socket" (tr l "9.7 µs a read" "9,7 µs par lecture");
      both_ways (px - 4) 168 (sx + sw - 4) 96;
      text f ~cls:"s sm" (sx + sw + 12) 62 (tr l "requests, replies" "requêtes, réponses");
      (* local reads *)
      rect f ~r:4 "cur" px 236 pw 132;
      text f ~cls:"h" (px + 10) 254 (tr l "a program, local reads" "un programme, lectures locales");
      text f ~cls:"sm" (px + 10) 274 (tr l "its follower: the run files" "son follower : les fichiers run");
      text f ~cls:"sm" (px + 10) 290 (tr l "and the frames as they come" "et les frames comme elles viennent");
      text f ~cls:"sm" (px + 10) 306 (tr l "reads in its own memory," "lit dans sa propre mémoire,");
      text f ~cls:"sm" (px + 10) 322 (tr l "up to the visibility number" "jusqu'au numéro de visibilité");
      text f ~cls:"a h" (px + pw - 10) 358 ~anchor:"end" (tr l "0.22 µs a read" "0,22 µs par lecture");
      curve f ~cls:"br" (sx + sw - 4) 210 (px - 4) 254;
      List.iteri (fun k t -> text f ~cls:"a sm" (sx + sw + 12) (250 + (k * 14)) t) [ "follow stream:"; tr l "Start (descriptors)," "Start (descripteurs),"; "Frame, Runs" ];
      line f "br" (sx + sw - 4) 335 (px - 6) 335;
      head f "fa" (px - 4) 335 1 0;
      text f ~cls:"a sm" (sx + sw + 12) 328 (tr l "mapped read-only" "mappée en lecture seule");
      712, 384, tr l "The server, and a read three ways: through TCP and TLS, through the Unix socket, and local reads" "Le serveur, et une lecture de trois façons : par TCP et TLS, par le socket Unix, et en lecture locale")

(* 3. a write with a replica (asynchronous) and in a Raft cluster of 3 (a majority) *)
let replica_raft docs =
  both docs "replica-raft.svg" (fun l f ->
      let lifeline x y0 y1 name = text f ~cls:"h" ~anchor:"middle" x y0 name; line f "axis" x (y0 + 8) x y1 in
      let work x y h s = rect f ~r:3 "cur" (x - 8) y 16 h; text f ~cls:"a sm" (x + 12) (y + (h / 2) + 4) s in
      let msg ?(cls = "gr") x1 x2 y s = arrow f ~cls x1 y x2 y; text f ~cls:"s sm" ~anchor:"middle" ((x1 + x2) / 2) (y - 5) s in
      let ybot = 268 in
      (* a primary and its replica *)
      text f ~cls:"h" 16 22 (tr l "A primary and its replica: asynchronous" "Un primary et sa replica : asynchrone");
      let p = 46 and a = 150 and b = 270 in
      lifeline p 48 ybot (tr l "program" "programme");
      lifeline a 48 ybot "primary";
      lifeline b 48 ybot "replica";
      msg p a 76 "write";
      work a 84 42 "fsync";
      msg ~cls:"br" a p 140 "Ok";
      msg a b 164 "frame";
      work b 172 42 "fsync";
      path f "ldel" (Printf.sprintf "M %d %d h -10 V %d h 10" (p - 6) 140 214);
      text f ~cls:"del sm" 16 236 (tr l "between Ok and the replica's fsync," "entre Ok et le fsync de la replica,");
      text f ~cls:"del sm" 16 252 (tr l "the write is on the primary alone: the lag" "l'écriture est sur le primary seul : le lag");
      (* Raft *)
      let x0 = 350 in
      text f ~cls:"h" x0 22 (tr l "Raft, 3 servers: a majority" "Raft, 3 serveurs : une majorité");
      let p = x0 + 24 and ld = x0 + 118 and f2 = x0 + 218 and f3 = x0 + 300 in
      lifeline p 48 ybot (tr l "program" "programme");
      lifeline ld 48 ybot "leader";
      lifeline f2 48 ybot "follower";
      lifeline f3 48 ybot "follower";
      msg p ld 76 "write";
      rect f ~r:3 "cur" (ld - 8) 84 16 42;
      text f ~cls:"a sm" (ld - 12) 118 ~anchor:"end" "log, fsync";
      msg ld f2 96 "entry";
      arrow f ld 100 f3 104;
      work f2 104 40 "fsync";
      work f3 112 92 "fsync";
      arrow f f2 156 (ld + 10) 156;
      text f ~cls:"s sm" ((ld + f2) / 2) 151 ~anchor:"middle" "ack";
      rect f ~r:3 "rowadd" (ld - 60) 168 120 22;
      text f ~cls:"add sm" ld 183 ~anchor:"middle" (tr l "2 of 3: committed" "2 sur 3 : committed");
      msg ~cls:"br" ld p 206 "Ok";
      arrow f f3 214 (ld + 10) 222;
      text f ~cls:"s sm" (f3 - 40) 236 ~anchor:"middle" (tr l "the 3rd may come later" "le 3e peut venir plus tard");
      text f ~cls:"add sm" x0 256 (tr l "Ok once 2 of the 3 hold it forced: a lost leader" "Ok dès que 2 des 3 la tiennent forcée : un leader");
      text f ~cls:"add sm" x0 272 (tr l "loses no write it confirmed" "perdu ne perd aucune écriture confirmée");
      712, 288, tr l "One write with a replica, answered after the primary's fsync alone, and in a Raft cluster, answered once a majority holds it"
        "Une écriture avec une replica, répondue après le seul fsync du primary, et dans un cluster Raft, répondue dès qu'une majorité la tient")

(* 4. a failover: the leader killed, an election, a new leader ready (the medians of server.md, 21 times) *)
let raft_failover docs =
  both docs "raft-failover.svg" (fun l f ->
      let x0 = 130 and xw = 560 in
      let t ms = x0 + (ms * xw / 1500) in
      let lanes = [| 50; 92; 134; 176 |] in
      List.iteri (fun k s -> text f ~cls:"h" 16 (lanes.(k) + 4) s) [ "srv1"; "srv2"; "srv3"; tr l "program" "programme" ];
      Array.iter (fun y -> line f "grid" x0 y (x0 + xw) y) lanes;
      (* the leader's heartbeats, every 50 ms, then kill -9 at 0 *)
      for k = 1 to 3 do let x = t 0 - (k * 50 * xw / 1500) in line f "br" x (lanes.(0) - 6) x (lanes.(0) + 6) done;
      text f ~cls:"del h" (t 0) (lanes.(0) + 5) ~anchor:"middle" "✕";
      spans f ~cls:"sm" (t 0 + 12) (lanes.(0) + 4) [ "del", "kill -9"; "s", tr l "   (before it, a heartbeat every 50 ms)" "   (avant lui, un heartbeat toutes les 50 ms)" ];
      (* the followers' election timeouts: 500 ms, then up to 500 more *)
      List.iter (fun k -> rect f "frame" (t 500) (lanes.(k) - 9) (t 1000 - t 500) 18; line f "dash" (t 0) lanes.(k) (t 500) lanes.(k)) [ 1; 2 ];
      text f ~cls:"a sm" (t 500 + 6) (lanes.(2) + 4) (tr l "timeout: 500 + 0 to 500 ms" "timeout : 500 + 0 à 500 ms");
      (* srv2 wins: pre-vote, vote (fsync), no-op (fsync), ready *)
      let tv = 872 and tr_ = 893 in
      rect f ~r:3 "cur" (t tv) (lanes.(1) - 10) (t tr_ - t tv) 20;
      text f ~cls:"a sm" (t tv - 6) (lanes.(1) - 14) ~anchor:"end" (tr l "timed out: pre-vote, vote (fsync)" "délai passé : pre-vote, vote (fsync)");
      text f ~cls:"a sm" (t tr_ + 6) (lanes.(1) + 4) (tr l "leader: no-op (fsync), ready" "leader : no-op (fsync), prêt");
      arrow f (t tv) (lanes.(1) + 10) (t tv) (lanes.(2) - 10);
      arrow f (t tv + 6) (lanes.(2) - 10) (t tv + 6) (lanes.(1) + 10);
      (* the program: writes refused, then sent to the new leader *)
      line f "dash" (t 0) lanes.(3) (t 910) lanes.(3);
      text f ~cls:"s sm" (t 40) (lanes.(3) - 8) (tr l "writes wait: no leader" "les écritures attendent : pas de leader");
      circle f "s1" (t 910) lanes.(3) 6;
      text f ~cls:"a sm" (t 910 + 10) (lanes.(3) + 4) (tr l "first write committed, 910 ms" "première écriture committed, 910 ms");
      (* the axis, and the medians' spread *)
      let ya = 206 in
      line f "axis" x0 ya (x0 + xw) ya;
      List.iter (fun ms -> let x = t ms in line f "axis" x ya x (ya + 4); text f ~cls:"s sm" ~anchor:"middle" x (ya + 16) (string_of_int ms)) [ 0; 250; 500; 750; 1000; 1250; 1500 ];
      text f ~cls:"s sm" 16 (ya + 16) "ms";
      rect f "frame" (t 557) (ya + 26) (t 1395 - t 557) 10;
      line f "br" (t 893) (ya + 22) (t 893) (ya + 40);
      text f ~cls:"a sm" (t 557) (ya + 54) (tr l "a leader ready in 21 failovers: 557 to 1,395 ms, median 893" "un leader prêt en 21 failovers : 557 à 1 395 ms, médiane 893");
      712, ya + 66,
      tr l "A failover in a Raft cluster of 3: the leader killed, an election, a new leader ready after 893 ms at the median"
        "Un failover dans un cluster Raft de 3 : le leader tué, une élection, un nouveau leader prêt après 893 ms en médiane")

(* 5. a watch: a group's change computed once a question, sent to every fiber that watches it *)
let watch_flow docs =
  both docs "watch-flow.svg" (fun l f ->
      (* the writer's groups *)
      text f ~cls:"h" 16 22 (tr l "Groups, once on the disk" "Groupes, une fois sur le disque");
      box f ~cls:"rowadd" 16 34 196 46 (tr l "group 15" "groupe 15") [ "code", "+ 65546 ada unpaid 45" ];
      box f ~cls:"rowdel" 16 90 196 46 (tr l "group 16" "groupe 16") [ "code", "- 65546 unpaid, + paid" ];
      (* the template *)
      text f ~cls:"h" 252 22 (tr l "One template, its constants" "Un template, ses constantes");
      rect f ~r:4 "cur" 252 34 222 102;
      code f ~cls:"a" 262 54 "unpaidOf(c)";
      code f 262 74 "[i, Client, c]";
      code f 262 90 "[i, Status, \"unpaid\"]";
      code f 262 106 "[i, Total, total]";
      text f ~cls:"s sm" 262 126 (tr l "delta query: each change once" "delta query : une fois par changement");
      curve f ~cls:"br" 212 57 250 70;
      curve f ~cls:"br" 212 113 250 100;
      (* the watches and their fibers *)
      text f ~cls:"h" 500 22 (tr l "Watches, their fibers" "Watches, leurs fibers");
      box f ~cls:"row" 500 34 196 62 "c = ada" [ "s sm", tr l "fibers A and B share it" "les fibers A et B la partagent" ];
      box f ~cls:"row" 500 106 196 46 "c = bo" [ "s sm", tr l "its rows unchanged: nothing" "ses lignes inchangées : rien" ];
      curve f ~cls:"br" 474 70 498 64;
      (* the messages A receives *)
      let y = 172 in
      text f ~cls:"h" 16 y (tr l "What fiber A receives, in order (fiber B the same, a copy)" "Ce que reçoit la fiber A, dans l'ordre (la fiber B la même chose, une copie)");
      let msgs =
        [ "row", "Ok({Group: 14, Rows: [{Invoice: 65538, Total: 80.5}], Added: missing, Removed: missing})";
          "rowadd", "Ok({Group: 15, Rows: missing, Added: [{Invoice: 65546, Total: 45.0}], Removed: []})";
          "rowdel", "Ok({Group: 16, Rows: missing, Added: [], Removed: [{Invoice: 65546, Total: 45.0}]})" ]
      in
      List.iteri (fun k (cls, s) -> rect f cls 16 (y + 12 + (k * 28)) 680 22; code f ~cls:"sm" 24 (y + 27 + (k * 28)) s) msgs;
      let yl = para f 16 (y + 12 + (3 * 28) + 18)
          ~n:108 (tr l "The first message is the answer at the watch's group; each next one, the rows that came and went with a group, sent once that group is on the server's disk. A group costs the same with 10 watches of a template or 10,000."
             "Le premier message est la réponse au groupe de la watch ; chaque suivant, les lignes venues et parties avec un groupe, envoyées une fois ce groupe sur le disque du serveur. Un groupe coûte autant avec 10 watches d'un template qu'avec 10 000.") in
      712, yl + 10,
      tr l "A watch: a group's changes computed once for a template, sent to the watches whose constants they match, each fiber its copy"
        "Une watch : les changements d'un groupe calculés une fois par template, envoyés aux watches dont ils touchent les constantes, chaque fiber sa copie")

(* 6. the vault: a file cut by its content, an insertion, and a range read; the cuts are the vault's own *)
let vault_chunks docs =
  let n = 1_500_000 in
  (* the bytes of a file: a xorshift from a fixed seed, so that the figure is the same at each run *)
  let file =
    let b = Bytes.create n and r = ref 0x2545F4914F6CDD1D in
    for i = 0 to n - 1 do
      r := !r lxor (!r lsl 13); r := !r lxor (!r lsr 7); r := !r lxor (!r lsl 17);
      Bytes.unsafe_set b i (Char.unsafe_chr (!r land 255))
    done;
    b
  in
  let cuts b =
    let len = Bytes.length b in
    let rec go off acc = if off >= len then List.rev acc else let k = Cepheus_vault.Chunker.cut b off (len - off) in go (off + k) ((off, k) :: acc) in
    go 0 []
  in
  let at = 400_000 and ins = 100 in
  let copy = Bytes.cat (Bytes.sub file 0 at) (Bytes.cat (Bytes.make ins 'x') (Bytes.sub file at (n - at))) in
  let a = cuts file and b = cuts copy in
  let digest by (o, k) = Digest.subbytes by o k in
  let known = List.map (digest file) a in
  let again = List.map (fun c -> List.mem (digest copy c) known) b in
  let found = List.length (List.filter Fun.id again) in
  let bytes_again = List.fold_left2 (fun s (_, k) g -> if g then s + k else s) 0 b again in
  let from = 1_000_000 and len = 65_536 in
  let under = List.filter (fun (o, k) -> o + k > from && o < from + len) a in
  both docs "vault-chunks.svg" (fun l f ->
      let x0 = 16 and w = 680 in
      let px total x = x0 + (x * w / total) in
      let bar y total chunks cls_of =
        List.iteri (fun i (o, k) -> rect f (cls_of i (o, k)) (px total o) y (max 1 (px total (o + k) - px total o)) 28) chunks
      in
      text f ~cls:"h" 16 22
        (Printf.sprintf (trf l "A file of %s bytes, cut by its content: %d chunks of 16 to 256 KiB" "Un fichier de %s octets, coupé selon son contenu : %d chunks de 16 à 256 Kio") (nb l (thousands n)) (List.length a));
      bar 34 n a (fun _ c -> if List.mem c under then "cur" else "row");
      (* the range read *)
      let rx = px n from and rw = max 2 (px n (from + len) - px n from) in
      path f "br" (Printf.sprintf "M %d %d v -6 h %d v 6" rx 32 rw);
      let k = List.length under and pl = if List.length under > 1 then "s" else "" in
      text f ~cls:"a sm" (rx + (rw / 2)) 78 ~anchor:"middle"
        (match l with
         | En -> Printf.sprintf "Read(..., from = 1_000_000, len = 65_536): the %d chunk%s under the range" k pl
         | Fr -> Printf.sprintf "Read(..., from = 1_000_000, len = 65_536) : le%s %d chunk%s sous la plage" pl k pl);
      (* the copy with 100 bytes inserted *)
      text f ~cls:"h" 16 110
        (Printf.sprintf (trf l "The same file with %d bytes inserted at byte %s" "Le même fichier avec %d octets insérés à l'octet %s") ins (nb l (thousands at)));
      bar 122 (n + ins) b (fun i _ -> if List.nth again i then "row" else "rowdel");
      line f "ldel" (px (n + ins) at) 116 (px (n + ins) at) 156;
      text f ~cls:"s sm" 16 172
        (Printf.sprintf (trf l "%d of its %d chunks found stored (%s of %s bytes): only the chunks at the insertion are new (red)" "%d de ses %d chunks trouvés stockés (%s octets sur %s) : seuls les chunks de l'insertion sont neufs (en rouge)") found (List.length b)
           (nb l (thousands bytes_again)) (nb l (thousands (n + ins))));
      (* a chunk's way into a pack, and the tree that finds it *)
      let y = 196 in
      let steps =
        [ tr l "a chunk" "un chunk", tr l "its bytes" "ses octets";
          tr l "named" "nommé", "BLAKE2b-256, keyed";
          tr l "compressed" "compressé", tr l "LZ4 (cold: Zstd)" "LZ4 (cold : Zstd)";
          tr l "sealed" "scellé", "AEGIS-256";
          tr l "stored once" "stocké une fois", tr l "a record of a pack" "un record d'un pack" ]
      in
      List.iteri
        (fun k (h, s) ->
          let x = 16 + (k * 138) in
          rect f ~r:4 (if k = 0 then "cur" else "box") x y 124 44;
          text f ~cls:"h sm" (x + 8) (y + 18) h;
          text f ~cls:"s sm" (x + 8) (y + 35) s;
          if k < 4 then arrow f (x + 126) (y + 22) (x + 136) (y + 22))
        steps;
      let yt = para f 16 (y + 70)
          (tr l "A node lists up to 1,024 children, each with the byte it ends at; the root names the file. A read walks from the root to the chunks under its range, by a binary search of the ends: a 4 KiB read reads one chunk, two where it crosses a cut."
             "Un nœud liste jusqu'à 1 024 enfants, chacun avec l'octet où il finit ; la racine nomme le fichier. Une lecture descend de la racine aux chunks sous sa plage, par une recherche dichotomique des fins : une lecture de 4 Kio lit un chunk, deux là où elle passe une coupe.") in
      712, yt + 10,
      tr l "A file cut into chunks by its content, the chunks a range read reads, and an insertion that leaves the other chunks as they were"
        "Un fichier coupé en chunks selon son contenu, les chunks que lit une lecture d'une plage, et une insertion qui laisse les autres chunks tels quels")

let draw docs =
  journal_commit docs;
  server_reads docs;
  replica_raft docs;
  raft_failover docs;
  watch_flow docs;
  vault_chunks docs
