(* Unit and property tests. Properties run on random inputs from fixed seeds; each failure names its seed. *)

open Cepheus
module C = Check

let section name = Printf.printf "- %s\n%!" name

(* ---- checksums and codecs ---- *)

let () =
  section "crc32c";
  C.check (Crc32c.string "123456789" = 0xE3069283) "crc32c of 123456789";
  C.check (Crc32c.string "" = 0) "crc32c of nothing";
  let r = Rng.make 1 in
  for _ = 1 to 200 do
    let n = Rng.int r 300 in
    let s = String.init n (fun _ -> Char.chr (Rng.int r 256)) in
    let b = Bigarray.Array1.create Bigarray.char Bigarray.c_layout n in
    String.iteri (Bigarray.Array1.set b) s;
    C.check (Crc32c.bigstring b 0 n = Crc32c.string s) "crc32c bigstring = bytes (%d)" n
  done

let () =
  section "codec and values";
  let r = Rng.make 2 in
  let ints = [ 0; 1; -1; 63; 64; -64; -65; max_int; min_int; 1 lsl 40; -(1 lsl 40) ] @ List.init 500 (fun _ -> Rng.next r) in
  List.iter
    (fun n ->
      let b = Buffer.create 16 in
      Codec.put_int b n;
      let rd = Codec.reader (Buffer.to_bytes b) 0 (Buffer.length b) in
      C.check (Codec.get_int rd = n && Codec.at_end rd) "zigzag round trip %d" n)
    ints;
  let values =
    [ Value.Int min_int; Int max_int; Float nan; Float (-0.0); Float 1e300; Bool true; Bool false; Text ""; Text "Ada";
      Date (-5); Money 12345; Link 70000 ]
  in
  let g = { Group.n = 7; time = 1700000000000; by = -3; why = "test"; first_new = 65536; count_new = 2;
            changes = Array.of_list (List.mapi (fun i v -> { Group.add = i mod 2 = 0; e = 65536 + i; p = 16 + i; v }) values) } in
  let b = Buffer.create 64 in
  Group.encode b g;
  let rd = Codec.reader (Buffer.to_bytes b) 0 (Buffer.length b) in
  C.check (Group.equal (Group.decode rd) g && Codec.at_end rd) "group round trip";
  (* a cut group never decodes as another one *)
  let bytes = Buffer.to_bytes b in
  for cut = 0 to Bytes.length bytes - 1 do
    match Group.decode (Codec.reader bytes 0 cut) with
    | _ -> C.fail "a group cut at %d decoded" cut
    | exception Codec.Short -> incr C.checks
  done

(* ---- the reference semantics of a write, written independently of Resolve ---- *)

type model = { mutable facts : C.F.t; mutable next : int }

let model_write (m : model) (v : view) ops =
  let schema p = Option.get (describe v p) in
  let temps = Hashtbl.create 4 and next = ref m.next in
  let see x = if x < 0 && not (Hashtbl.mem temps x) then (Hashtbl.replace temps x !next; incr next) in
  List.iter (function Add (e, _, x) | Retract (e, _, x) -> see e; (match x with Link t -> see t | _ -> ()) | Expect _ -> ()) ops;
  let id x = if x < 0 then Hashtbl.find temps x else x in
  let fix = function Link t -> Link (id t) | x -> x in
  let has f e p = C.F.exists (fun (e', p', _) -> e' = e && p' = p) f in
  try
    List.iter
      (function
        | Expect (e, _, _) when e < 0 -> raise Exit
        | Expect (e, p, None) -> if has m.facts e p then raise Exit
        | Expect (e, p, Some x) -> if not (C.F.mem (e, p, x) m.facts) then raise Exit
        | _ -> ())
      ops;
    let f = ref m.facts and added = ref [] in
    List.iter
      (function
        | Add (e, p, x) ->
          let e = id e and x = fix x in
          let d = schema p in
          if e < Schema.first_thing || e >= !next || not (Value.has_type d.typ x) then raise Exit;
          (match x with Link t -> if t < Schema.first_prop || t >= !next then raise Exit | _ -> ());
          if not d.many then f := C.F.filter (fun (e', p', _) -> not (e' = e && p' = p)) !f;
          f := C.F.add (e, p, x) !f;
          added := (e, p, x) :: !added
        | Retract (e, p, x) ->
          let e = id e and x = fix x in
          let d = schema p in
          if e < Schema.first_thing || e >= !next || not (Value.has_type d.typ x) then raise Exit;
          f := C.F.remove (e, p, x) !f
        | Expect _ -> ())
      ops;
    List.iter
      (fun (e, p, x) ->
        if (schema p).unique && C.F.mem (e, p, x) !f && C.F.exists (fun (e', p', x') -> e' <> e && p' = p && Value.equal x x') !f then raise Exit)
      !added;
    m.facts <- !f;
    m.next <- !next;
    true
  with Exit -> false

let props =
  [ prop "name" Ttext; prop ~many:true "tag" Ttext; prop "score" Tint; prop ~unique:true "mail" Ttext;
    prop ~many:true "friend" Tlink; prop "boss" Tlink; prop "w" Tfloat ]

let random_ops r (v : view) ids =
  let p n = Option.get (property v n) in
  let things = v.next_e - Schema.first_thing in
  let some () = if things = 0 || Rng.int r 10 = 0 then -1 - Rng.int r 2 else Schema.first_thing + Rng.int r (things + 1) in
  let small = [| "a"; "b"; "c" |] in
  ignore ids;
  List.init (1 + Rng.int r 4) (fun _ ->
      match Rng.int r 12 with
      | 0 -> Add (some (), p "name", Text (Rng.pick r small))
      | 1 -> Add (some (), p "tag", Text (Rng.pick r small))
      | 2 -> Retract (some (), p "tag", Text (Rng.pick r small))
      | 3 -> Add (some (), p "score", Int (Rng.int r 3))
      | 4 -> Add (some (), p "mail", Text (Rng.pick r small))
      | 5 -> Add (some (), p "friend", Link (some ()))
      | 6 -> Add (some (), p "boss", Link (some ()))
      | 7 -> Expect (some (), p "score", Some (Int (Rng.int r 3)))
      | 8 -> Expect (some (), p "mail", None)
      | 9 -> Add (some (), p "w", Float (float_of_int (Rng.int r 3)))
      | 10 -> Add (some (), p "score", Text "x")
      | _ -> Retract (some (), p "boss", Link (some ())))

let fresh () =
  let f = fork empty in
  ignore (Result.get_ok (declare f props));
  f

let () =
  section "writes against the reference semantics";
  for seed = 1 to 300 do
    let r = Rng.make (1000 + seed) in
    let f = fresh () in
    let m = { facts = C.facts_of_view (view f); next = (view f).next_e } in
    for _ = 1 to 40 do
      let v = view f in
      let ops = random_ops r v () in
      let want = model_write m v ops in
      let got = write f ops in
      C.check (Result.is_ok got = want) "seed %d: write accepted %b, the model says %b (%s)" seed (Result.is_ok got) want
        (match got with Error e -> message e | Ok _ -> "");
      if Result.is_ok got <> want then m.facts <- C.facts_of_view (view f);
      let facts = C.facts_of_view (view f) in
      if not (C.F.equal facts m.facts) then (C.fail "seed %d: facts differ: %s" seed (C.show_diff facts m.facts); m.facts <- facts);
      m.next <- (view f).next_e
    done
  done

(* ---- questions against the naive evaluator ---- *)

let qnames = [ "name"; "tag"; "score"; "friend"; "boss"; "mail" ]

let () =
  section "questions against the naive evaluator (half of them split over 3 domains)";
  Query.domains := 3;
  for seed = 1 to 300 do
    Query.parallel_min := (if seed mod 2 = 0 then 1 else 20_000);
    let r = Rng.make (5000 + seed) in
    let f = fresh () in
    for _ = 1 to 30 do ignore (write f (random_ops r (view f) ())) done;
    if seed mod 3 = 0 then begin
      (* the same questions on a compacted base and on a base plus delta *)
      let v = Store.compact { (view f) with writer = true } in
      for _ = 1 to 10 do ignore (Store.facts v) done
    end;
    let v = view f in
    let facts = C.facts_of_view v in
    for _ = 1 to 15 do
      match C.random_query r v facts qnames with
      | None -> ()
      | Some q -> (
        match C.work_and_bound v facts q (fun () -> find v q) with
        | Error e, _, _ -> C.fail "seed %d: %s" seed (message e)
        | Ok rows, work, bound ->
          let want = C.naive facts q in
          let got = C.sorted_rows rows in
          C.check (List.length got = List.length (List.sort_uniq compare got)) "seed %d: a binding came twice" seed;
          C.check (got = want) "seed %d: %d rows, the naive evaluator gives %d" seed (List.length got) (List.length want);
          C.check (work <= bound) "seed %d: Generic Join enumerated %d candidates, its bound is %d" seed work bound)
    done
  done

let () =
  section "compaction keeps every fact";
  for seed = 1 to 100 do
    let r = Rng.make (9000 + seed) in
    let f = fresh () in
    for _ = 1 to 40 do ignore (write f (random_ops r (view f) ())) done;
    let v = view f in
    let c = Store.compact { v with writer = true } in
    C.check (C.F.equal (C.facts_of_view v) (C.facts_of_view c)) "seed %d: compaction changed the facts" seed;
    (* and the compacted base answers the same questions *)
    let facts = C.facts_of_view c in
    for _ = 1 to 5 do
      match C.random_query r c facts qnames with
      | Some q ->
        let rows, work, bound = C.work_and_bound c facts q (fun () -> Result.get_ok (find c q)) in
        C.check (C.sorted_rows rows = C.naive facts q) "seed %d: compacted questions" seed;
        C.check (work <= bound) "seed %d: compacted: %d candidates, bound %d" seed work bound
      | None -> ()
    done
  done

(* ---- snapshots ---- *)

let () =
  section "snapshots: round trip, and damage set aside";
  for seed = 1 to 60 do
    let r = Rng.make (12000 + seed) in
    let sim = Sim_disk.create (Rng.split r) in
    let disk = Sim_disk.disk sim in
    disk.mkdir "/s";
    let f = fresh () in
    for _ = 1 to 30 do ignore (write f (random_ops r (view f) ())) done;
    let v = Store.compact { (view f) with writer = true } in
    let pos = { Journal.segment = 1; offset = 40; next = v.group + 1 } in
    Snapshot.write disk "/s" "0123456789abcdef" v pos;
    (match Snapshot.load disk "/s" "0123456789abcdef" with
     | Some (v', _), [] ->
       C.check (C.F.equal (C.facts_of_view v) (C.facts_of_view v')) "seed %d: snapshot round trip" seed;
       C.check (v'.next_e = v.next_e && v'.group = v.group) "seed %d: snapshot counters" seed
     | _ -> C.fail "seed %d: snapshot did not load" seed);
    (match Snapshot.load disk "/s" "another database" with
     | None, [ _ ] -> incr C.checks
     | _ -> C.fail "seed %d: a snapshot of another database was taken" seed);
    let file = "/s/" ^ Snapshot.name v.group in
    ignore (Sim_disk.flip_durable sim file 0 (Sim_disk.durable_size sim file));
    match Snapshot.load disk "/s" "0123456789abcdef" with
    | None, [ _ ] -> incr C.checks
    | Some (v', _), _ ->
      (* the flip can only go unseen if it hit padding no check covers: then the facts must be intact *)
      C.check (C.F.equal (C.facts_of_view v) (C.facts_of_view v')) "seed %d: a damaged snapshot was served" seed
    | _ -> C.fail "seed %d: unexpected snapshot load" seed
  done

(* ---- forks and databases on the real disk ---- *)

let () =
  section "forks change nothing, and accept what the database accepts";
  let dir = C.tmpdir "unit" in
  let db = Result.get_ok (open_ dir) in
  ignore (Result.get_ok (declare db props));
  let r = Rng.make 77 in
  for _ = 1 to 20 do ignore (write db (random_ops r (view db) ())) done;
  let v = view db in
  let journal () = List.map (fun f -> f, In_channel.with_open_bin (Filename.concat (dir ^ "/journal") f) In_channel.input_all) (Array.to_list (Sys.readdir (dir ^ "/journal"))) in
  let before = journal () and facts = C.facts_of_view v in
  let f = fork v in
  let r1 = Rng.make 78 and r2 = Rng.make 78 in
  let f2 = fork v in
  for _ = 1 to 30 do
    let a = write f (random_ops r1 (view f) ()) in
    let b = write f2 (random_ops r2 (view f2) ()) in
    C.check (Result.is_ok a = Result.is_ok b) "two forks given the same writes agree"
  done;
  C.check (C.F.equal (C.facts_of_view (view f)) (C.facts_of_view (view f2))) "two forks end equal";
  C.check (C.F.equal facts (C.facts_of_view (view db))) "the database is unchanged by its forks";
  C.check (before = journal ()) "the journal files are unchanged by forks";
  (* the database accepts and refuses what a fork of the same view does *)
  let f3 = fork (view db) in
  let r3 = Rng.make 79 and r4 = Rng.make 79 in
  for _ = 1 to 30 do
    let a = write f3 (random_ops r3 (view f3) ()) in
    let b = write db (random_ops r4 (view db) ()) in
    C.check (Result.is_ok a = Result.is_ok b) "database and fork agree on a write"
  done;
  C.check (C.F.equal (C.facts_of_view (view f3)) (C.facts_of_view (view db))) "database and fork end equal";
  (match open_ dir with
   | Error (Busy _) -> incr C.checks
   | Ok d -> close d; C.fail "a database opened twice (G9)"
   | Error e -> C.fail "second open: %s" (message e));
  close db;
  let db = Result.get_ok (open_ dir) in
  C.check (C.F.equal (C.facts_of_view (view db)) (C.facts_of_view (view f3))) "reopened database equals the fork that mirrored it";
  close db;
  (match verify dir with Ok n -> C.check (n > 20) "verify reads %d groups" n | Error e -> C.fail "verify: %s" (message e));
  C.rmrf dir

(* ---- named cases ---- *)

let () =
  section "named cases: write skew, unique, one value, triangles";
  let f = fork empty in
  let[@warning "-8"] (Ok [ oncall; mail; name; follows ]) =
    declare f [ prop "oncall" Tbool; prop ~unique:true "mail" Ttext; prop "name" Ttext; prop ~many:true "follows" Tlink ]
  in
  let r = Result.get_ok (write f [ Add (-1, oncall, Bool true); Add (-2, oncall, Bool true) ]) in
  let alice = thing r (-1) and bob = thing r (-2) in
  let v = view f in
  (* both read "two on call" in v, both try to leave; the second must fail *)
  let a = write f [ Expect (bob, oncall, Some (Bool true)); Add (alice, oncall, Bool false) ] in
  let b = write f [ Expect (alice, oncall, Some (Bool true)); Add (bob, oncall, Bool false) ] in
  C.check (Result.is_ok a && (match b with Error (Conflict _) -> true | _ -> false)) "write skew is refused";
  C.check (values v alice oncall = [ Bool true ]) "an old view does not change";
  ignore (write f [ Add (alice, mail, Text "a@x") ]);
  C.check (match write f [ Add (bob, mail, Text "a@x") ] with Error (Not_unique _) -> true | _ -> false) "unique";
  ignore (write f [ Add (alice, name, Text "Ada Martin") ]);
  ignore (write f [ Add (alice, name, Text "Ada Durand") ]);
  C.check (values (view f) alice name = [ Text "Ada Durand" ]) "one value: the old one is retracted";
  (* triangles: a -> b -> c -> a *)
  let r = Result.get_ok (write f (List.concat_map (fun i -> [ Add (-i, name, Text (string_of_int i)) ]) [ 1; 2; 3; 4 ])) in
  let t i = thing r (-i) in
  ignore (write f [ Add (t 1, follows, Link (t 2)); Add (t 2, follows, Link (t 3)); Add (t 3, follows, Link (t 1)); Add (t 3, follows, Link (t 4)) ]);
  let q = { vars = 3; where = [ { e = Var 0; p = follows; v = Var 1 }; { e = Var 1; p = follows; v = Var 2 }; { e = Var 2; p = follows; v = Var 0 } ]; ranges = [] } in
  C.check (List.length (Result.get_ok (find (view f) q)) = 3) "one triangle, three rotations";
  C.check (match find (view f) { q with vars = 4 } with Error (Invalid _) -> true | _ -> false) "an unused variable is invalid"

(* ---- costs: the work of a question and of an index lookup stays within its bound ----
   Each case is built so that one list is far larger than the answer: an engine that walks it where a lookup or a
   smaller list would do fails the bound (counted candidates for questions; time, with a margin of 20 or more, for the
   index lookups, which have no counter in their inner loops). *)

let within secs what f =
  let best = ref infinity and tries = ref 0 in
  while !best >= secs && !tries < 3 do
    let t = Unix.gettimeofday () in
    f ();
    best := min !best (Unix.gettimeofday () -. t);
    incr tries
  done;
  C.check (!best < secs) "%s: %.3f s, the bound is %.2f s" what !best secs

let compacted f = fork (Store.compact { (view f) with writer = true })

let () =
  section "costs: questions stay within the Generic Join bound, lookups within O(log n)";
  let f = fork empty in
  let[@warning "-8"] (Ok [ city; client; status; total; _tag; member; score ]) =
    declare f [ prop "city" Ttext; prop "client" Tlink; prop "status" Ttext; prop "total" Tint; prop ~many:true "tag" Ttext;
                prop ~many:true "member" Tint; prop "score" Tint ]
  in
  (* 40 clients in c1 with 2 unpaid invoices each; one client in c2 with 20,000 unpaid invoices *)
  let ops = ref [ Add (-1000, city, Text "c2") ] in
  for k = 1 to 40 do
    ops := Add (-k, city, Text "c1") :: !ops;
    for j = 1 to 2 do
      let i = -((100 * k) + j) in
      ops := Add (i, client, Link (-k)) :: Add (i, status, Text "unpaid") :: Add (i, total, Int j) :: !ops
    done
  done;
  for j = 1 to 20_000 do
    let i = -(10_000 + j) in
    ops := Add (i, client, Link (-1000)) :: Add (i, status, Text "unpaid") :: Add (i, total, Int j) :: !ops
  done;
  ignore (Result.get_ok (write f (List.rev !ops)));
  let q3 = { vars = 3; ranges = [];
             where = [ { e = Var 0; p = city; v = Val (Text "c1") }; { e = Var 1; p = client; v = Var 0 };
                       { e = Var 1; p = status; v = Val (Text "unpaid") }; { e = Var 1; p = total; v = Var 2 } ] } in
  List.iter
    (fun (name, g) ->
      let v = view g in
      let facts = C.facts_of_view v in
      let rows, work, bound = C.work_and_bound v facts q3 (fun () -> Result.get_ok (find v q3)) in
      C.check (List.length rows = 80) "%s: the unpaid invoices of c1: %d rows" name (List.length rows);
      C.check (work <= bound && work <= 400) "%s: unpaid of a city: %d candidates, the bound is %d" name work bound)
    [ "base", compacted f; "delta", f ];
  (* exact counts with a delta: 100 things tagged rare in the base, 1,000 tagged hot in the delta, 50 of them rare *)
  let g = fork empty in
  let[@warning "-8"] (Ok [ tag ]) = declare g [ prop ~many:true "tag" Ttext ] in
  let r = Result.get_ok (write g (List.init 100 (fun k -> Add (-(k + 1), tag, Text "rare")))) in
  let rare = List.map snd r.things in
  let g = compacted g in
  ignore (Result.get_ok (write g (List.filteri (fun i _ -> i < 50) rare |> List.map (fun e -> Add (e, tag, Text "hot")))));
  ignore (Result.get_ok (write g (List.init 950 (fun k -> Add (-(k + 1), tag, Text "hot")))));
  let v = view g in
  let q = { vars = 1; ranges = []; where = [ { e = Var 0; p = tag; v = Val (Text "rare") }; { e = Var 0; p = tag; v = Val (Text "hot") } ] } in
  let rows, work, bound = C.work_and_bound v (C.facts_of_view v) q (fun () -> Result.get_ok (find v q)) in
  C.check (List.length rows = 50) "rare and hot: %d rows" (List.length rows);
  C.check (work <= bound && work <= 100) "rare and hot: %d candidates, the bound is %d (counts must be exact with a delta)" work bound;
  (* a range: 20,000 scores, the question asks for 10 of them *)
  let h = fork empty in
  let[@warning "-8"] (Ok [ score1 ]) = declare h [ prop "score" Tint ] in
  ignore (Result.get_ok (write h (List.init 20_000 (fun k -> Add (-(k + 1), score1, Int k)))));
  let qr = { vars = 2; where = [ { e = Var 0; p = score1; v = Var 1 } ]; ranges = [ 1, Int 100, Int 109 ] } in
  List.iter
    (fun (name, h) ->
      let v = view h in
      let rows, work, bound = C.work_and_bound v (C.facts_of_view v) qr (fun () -> Result.get_ok (find v qr)) in
      C.check (List.length rows = 10) "%s: a range of 10 scores: %d rows" name (List.length rows);
      C.check (work <= bound && work <= 40) "%s: a range of 10 scores: %d candidates, the bound is %d" name work bound)
    [ "delta", h; "base", compacted h ];
  (* one thing with 40,000 values, added one group at a time *)
  let hub = thing (Result.get_ok (write f [ Add (-1, city, Text "hub") ])) (-1) in
  let big = ref f in
  within 1.0 "40,000 values added one group at a time to one thing" (fun () ->
      let g = fork (view f) in
      for k = 1 to 40_000 do ignore (Result.get_ok (write g [ Add (hub, member, Int k) ])) done;
      big := g);
  ignore (Result.get_ok (write !big [ Add (hub, score, Int 7) ]));
  (* in the base: 40,000 values, then a property after them; in the delta: 500 more, 100 retracted *)
  let b = compacted !big in
  let vb = view b in
  within 0.3 "20,000 lookups past 40,000 values of a thing (base)" (fun () ->
      for k = 1 to 20_000 do if not (Store.mem vb hub score 7) || Store.mem vb hub score (k + 7) then C.fail "score lookup" done);
  for k = 1 to 500 do ignore (Result.get_ok (write b [ Add (hub, member, Int (40_000 + k)) ])) done;
  for k = 1 to 100 do ignore (Result.get_ok (write b [ Retract (hub, member, Int (k * 10)) ])) done;
  let vd = view b in
  within 0.3 "20,000 lookups on a thing with 40,000 values in the base and 600 changes in the delta" (fun () ->
      for k = 1 to 20_000 do
        let w = 1 + ((k * 7919) mod 41_000) in
        let want = w <= 40_500 && not (w <= 1000 && w mod 10 = 0) in
        if Store.mem vd hub member w <> want then C.fail "member %d: want %b" w want
      done);
  C.check (Store.count_values vd hub member = 40_400) "a thing's count with a delta is exact: %d" (Store.count_values vd hub member);
  C.check (List.length (values vd hub member) = 40_400) "a thing's values with a delta";
  (* links: 30,000 invoices point at one client by [client], one thing by [boss] *)
  let l = fork empty in
  let[@warning "-8"] (Ok [ client; boss ]) = declare l [ prop "client" Tlink; prop "boss" Tlink ] in
  let r = Result.get_ok (write l [ Add (-1, boss, Link (-1)) ]) in
  let c0 = thing r (-1) in
  ignore (Result.get_ok (write l (Add (-30_001, boss, Link c0) :: List.init 30_000 (fun k -> Add (-(k + 1), client, Link c0)))));
  let vl = view (compacted l) in
  within 0.3 "20,000 lookups of the one boss link among 30,000 links to a thing" (fun () ->
      for _ = 1 to 20_000 do if List.length (things vl boss (Link c0)) <> 2 then C.fail "boss links" done);
  (* compaction of a thing whose 30,000 values arrived out of order *)
  let o = fork empty in
  let[@warning "-8"] (Ok [ member ]) = declare o [ prop ~many:true "member" Tint ] in
  let t = thing (Result.get_ok (write o [ Add (-1, member, Int 0) ])) (-1) in
  ignore (Result.get_ok (write o (List.init 30_000 (fun k -> Add (t, member, Int (((k + 1) * 7919) mod 30_011))))));
  within 0.25 "compaction of a thing with 30,000 values out of order" (fun () ->
      let c = Store.compact { (view o) with writer = true } in
      if Store.count_values c t member <> 30_001 then C.fail "compacted count");
  ignore (city, client, status, total, member, score)

let () = C.finish "unit"
