(* The background path of a change of the rules or the ontology (Engine; G19; spec/RuleChange.tla), on databases on the
   disk with their threaded writer:
   - interleavings forced (Engine.change_pause holds the background after its build): groups written meanwhile are
     caught up exactly and ordered before the change; one that writes a fact the change writes, that breaks a
     constraint the change adds, or that takes the id the change expects free ends the change with Conflict, and the
     retry decides on the newer state;
   - concurrency: writers, a thread that changes the rules again and again, and readers that check every view they take
     against the least model of its asserted facts under its own rules (never the old rules' facts beside the new
     ones'); then the database reopened (replay) holds the same;
   - the change budget: a rule that would derive past it is refused, named, while writers go on; a change of the
     ontology past a data write's budget is accepted, on the disk and on a fork alike, and a data write past it is not;
   - close during a change: the change answered Closed, nothing of it after the reopen;
   - kill -9 during changes (child processes): after each recovery the view is exact under its rules, a rule there
     with all its consequences or not at all.
   Usage: rulechange.exe [KILLS]; scratch databases in $CEPHEUS_TMP. *)

open Cepheus
module C = Check
module F = C.F

let section name = Printf.printf "- %s\n%!" name
let ok = function Ok x -> x | Error e -> failwith (message e)

let has_sub m sub =
  let n = String.length sub in
  let rec go i = i + n <= String.length m && (String.sub m i n = sub || go (i + 1)) in
  go 0

let exact (v : view) = F.equal (C.user_facts v) (C.perfect (C.rules_of v) (C.asserted_facts v))

let open_db d = match open_ d with Ok db -> db | Error e -> failwith (message e)

let schema db =
  match declare db [ prop ~many:true "a" Tlink; prop ~many:true "b" Tlink; prop ~many:true "type" Tlink; prop ~many:true "sub" Tlink; prop "n" Tint ] with
  | Ok [ a; b; ty; sub; _ ] -> a, b, ty, sub
  | _ -> assert false

(* n new things, each with its number *)
let things db n =
  let p = Option.get (property (view db) "n") in
  let r = ok (write db (List.init n (fun i -> Add (-(i + 1), p, Int i)))) in
  Array.init n (fun i -> thing r (-(i + 1)))

let x = Var 0 and y = Var 1 and z = Var 2

(* a rule, its variables counted from its patterns *)
let rule name where head =
  let m = ref (-1) in
  let term = function Var k -> m := max !m k | _ -> () in
  List.iter (fun (q : pattern) -> term q.e; term q.v) (where @ match head with Give h -> [ h ] | Never -> []);
  { name; vars = !m + 1; where; ranges = []; head }

(* a define in a thread: its result, once it has one *)
let in_thread f =
  let res = ref None and m = Mutex.create () in
  let t = Thread.create (fun () -> let r = f () in Mutex.protect m (fun () -> res := Some r)) () in
  fun () -> Thread.join t; Option.get !res

(* the first free schema thing, as define finds it *)
let free_id (v : view) =
  let p = ref Schema.first_prop in
  while Schema.find v.schema !p <> None || Store.has_value v !p Schema.p_name do incr p done;
  !p

let interleavings () =
  section "a change caught up with the groups written meanwhile, ordered after them";
  let d = C.tmpdir "rc-inter" in
  let db = open_db d in
  let a, b, ty, sub = schema db in
  let t = things db 40 in
  for i = 0 to 38 do ignore (ok (write db [ Add (t.(i), a, Link t.(i + 1)) ])) done;
  Engine.change_pause := 0.3;
  let res = in_thread (fun () -> define db [ rule "copy" [ { e = x; p = a; v = y } ] (Give { e = x; p = b; v = y }) ]) in
  Unix.sleepf 0.05;
  (* meanwhile: retractions and additions of what the rule reads, a type, all confirmed under the old rules *)
  let gs = ref [] in
  for i = 0 to 9 do
    let r = ok (write db [ Retract (t.(i), a, Link t.(i + 1)); Add (t.(i), a, Link t.(39 - i)); Add (t.(i), ty, Link t.(0)) ]) in
    C.check (Store.count_prop (view db) b = 0) "a view before the change holds no fact of the new rule";
    gs := r.group :: !gs
  done;
  (match res () with
   | Ok _ ->
     let v = view db in
     C.check (exact v) "the view after the change is the least model under the new rules";
     C.check (Store.count_prop v b = 39) "every edge copied, those written meanwhile included (%d)" (Store.count_prop v b);
     C.check (List.for_all (fun g -> g < v.group) !gs) "the groups written meanwhile are ordered before the change"
   | Error e -> C.fail "the change: %s" (message e));
  section "a group written meanwhile that writes a fact the change writes: Conflict";
  let id = free_id (view db) in
  let text = Rules.to_text (rule "mixed" [ { e = x; p = ty; v = y } ] (Give { e = y; p = b; v = x })) in
  let res = in_thread (fun () ->
      write db [ Add (id, Schema.p_name, Text "mixed"); Add (id, Schema.p_rule, Text text); Expect (id, Schema.p_name, None);
                 Add (t.(20), ty, Link t.(21)) ]) in
  Unix.sleepf 0.05;
  ignore (ok (write db [ Add (t.(20), ty, Link t.(21)) ]));
  (match res () with
   | Error (Conflict m) -> C.check true "conflict: %s" m
   | Ok _ -> C.fail "a change whose fact was written meanwhile must end with Conflict"
   | Error e -> C.fail "expected Conflict: %s" (message e));
  C.check (Schema.rule_by_name (view db).schema "mixed" = None) "nothing of the change is there";
  section "a group written meanwhile that breaks a constraint the change adds: Conflict, then the retry refuses it";
  let res = in_thread (fun () ->
      define db [ rule "two-types" [ { e = x; p = ty; v = Thing t.(1) }; { e = x; p = ty; v = Thing t.(2) } ] Never ]) in
  Unix.sleepf 0.05;
  ignore (ok (write db [ Add (t.(30), ty, Link t.(1)); Add (t.(30), ty, Link t.(2)) ]));
  (match res () with
   | Error (Invalid m) -> C.check (has_sub m "constraint two-types") "refused on the newer state: %s" m
   | Ok _ -> C.fail "a constraint broken by a group ordered before it must be refused"
   | Error e -> C.fail "expected Invalid: %s" (message e));
  C.check (exact (view db)) "the view is still exact";
  section "a group written meanwhile that takes the id the change expects free: Conflict, and define tries again";
  let res = in_thread (fun () -> define db [ rule "back" [ { e = x; p = a; v = y } ] (Give { e = y; p = b; v = x }) ]) in
  Unix.sleepf 0.05;
  (match declare db [ prop "late" Tint ] with Ok [ _ ] -> () | _ -> C.fail "declare during a change");
  (match res () with
   | Ok [ id ] ->
     let v = view db in
     C.check (Schema.by_name v.schema "late" <> Some id) "the property and the rule have their own ids";
     C.check (exact v) "the view is exact under both rules"
   | Ok _ -> C.fail "one id"
   | Error e -> C.fail "define after a Conflict: %s" (message e));
  section "a change that makes a new thing: computed in its group, its thing numbered in order";
  let id = free_id (view db) in
  let text = Rules.to_text (rule "made" [ { e = x; p = sub; v = y } ] (Give { e = x; p = ty; v = y })) in
  (match write db [ Add (id, Schema.p_name, Text "made"); Add (id, Schema.p_rule, Text text); Add (-1, sub, Link t.(3)) ] with
   | Ok r ->
     let v = view db in
     C.check (thing r (-1) = v.next_e - 1) "the new thing is the newest";
     C.check (Store.count_things v ty t.(3) > 0 && exact v) "its consequences are there, exact"
   | Error e -> C.fail "a change with a new thing: %s" (message e));
  Engine.change_pause := 0.;
  close db;
  let db = open_db d in
  C.check (exact (view db)) "reopened: exact";
  close db;
  C.rmrf d

(* writers, a thread changing the rules, readers checking every view *)
let concurrency () =
  section "concurrency: 6 writers, rules changed 24 times, 2 readers checking every view against the least model";
  let d = C.tmpdir "rc-conc" in
  let db = open_db d in
  let a, b, ty, _ = schema db in
  let t = things db 30 in
  let pool =
    [| rule "r1" [ { e = x; p = a; v = y } ] (Give { e = x; p = b; v = y });
       rule "r2" [ { e = x; p = b; v = y }; { e = y; p = b; v = z } ] (Give { e = x; p = b; v = z });
       rule "r3" [ { e = x; p = ty; v = Thing t.(0) } ] (Give { e = x; p = ty; v = Thing t.(1) });
       rule "r4" [ { e = x; p = a; v = y } ] (Give { e = y; p = ty; v = Thing t.(0) });
       rule "r5" [ { e = x; p = a; v = y }; { e = y; p = ty; v = Thing t.(1) } ] (Give { e = x; p = ty; v = Thing t.(2) }) |]
  in
  let stop = Atomic.make false and bad = Atomic.make 0 and views = Atomic.make 0 and writes = Atomic.make 0 in
  let writer k () =
    let r = Rng.make (100 + k) in
    while not (Atomic.get stop) do
      let f () = let p = [| a; a; ty; b |].(Rng.int r 4) in t.(Rng.int r 30), p, Link t.(Rng.int r 30) in
      let ops = List.init (1 + Rng.int r 3) (fun _ -> let e, p, x = f () in if Rng.int r 3 = 0 then Retract (e, p, x) else Add (e, p, x)) in
      match write db ops with Ok _ -> Atomic.incr writes | Error _ -> ()
    done
  in
  let reader () =
    while not (Atomic.get stop) do
      let v = view db in
      Atomic.incr views;
      if not (exact v) then begin
        Atomic.incr bad;
        Printf.printf "  view of group %d: %s\n%!" v.group (C.show_diff (C.user_facts v) (C.perfect (C.rules_of v) (C.asserted_facts v)))
      end
    done
  in
  let ws = List.init 6 (fun k -> Thread.create (writer k) ()) and rs = List.init 2 (fun _ -> Thread.create reader ()) in
  let r = Rng.make 7 and done_ = ref 0 and conflicts = ref 0 in
  let installed0 = Atomic.get Engine.changes_done in
  (* each change waits a little after its build: the writers' groups pile up for its catch-up *)
  Engine.change_pause := 0.02;
  for _ = 1 to 24 do
    let res =
      if Rng.bool r then define db (List.filter (fun _ -> Rng.bool r) (Array.to_list pool))
      else Result.map (fun () -> []) (undefine db [ pool.(Rng.int r 5).name ])
    in
    (match res with Ok _ -> incr done_ | Error (Conflict _) -> incr conflicts | Error e -> C.fail "a change: %s" (message e));
    Unix.sleepf 0.01
  done;
  Engine.change_pause := 0.;
  Atomic.set stop true;
  List.iter Thread.join ws;
  List.iter Thread.join rs;
  Printf.printf "  %d changes done (%d ended by a conflict), %d installed in the background, %d writes beside them, %d views checked\n%!" !done_
    !conflicts (Atomic.get Engine.changes_done - installed0) (Atomic.get writes) (Atomic.get views);
  C.check (Atomic.get bad = 0) "no view mixes the rules: %d inexact of %d" (Atomic.get bad) (Atomic.get views);
  C.check (Atomic.get views > 100 && Atomic.get writes > 100) "the readers and the writers ran (%d views, %d writes)" (Atomic.get views) (Atomic.get writes);
  let last = C.user_facts (view db) in
  C.check (exact (view db)) "the last view is exact";
  close db;
  let db = open_db d in
  C.check (F.equal (C.user_facts (view db)) last) "reopened: the same facts (the changes' frames replayed)";
  close db;
  C.rmrf d

let budget () =
  section "the change budget: a rule past it refused, named, while writers go on";
  let d = C.tmpdir "rc-budget" in
  let db = open_db d in
  let a, b, ty, sub = schema db in
  let t = things db 60 in
  for i = 0 to 58 do ignore (ok (write db [ Add (t.(i), a, Link t.(i + 1)) ])) done;
  let b0 = !Reason.budget_base and b1 = !Reason.budget_per and c0 = !Reason.change_per in
  Reason.budget_base := 200;
  Reason.budget_per := 1;
  Reason.change_per := 1;
  let stop = Atomic.make false and writes = Atomic.make 0 in
  let w = Thread.create (fun () -> while not (Atomic.get stop) do (match write db [ Add (t.(Atomic.get writes mod 60), ty, Link t.(5)) ] with Ok _ -> Atomic.incr writes | Error _ -> ()) done) () in
  (* every pair of edges: 59 x 59 facts, past 200 + 1 x the database's facts *)
  let cross = rule "cross" [ { e = x; p = a; v = y }; { e = z; p = a; v = Var 3 } ] (Give { e = x; p = b; v = Var 3 }) in
  (match define db [ cross ] with
   | Error (Invalid m) -> C.check (has_sub m "rule cross derived more than" && has_sub m "from a change of the rules") "refused: %s" m
   | Ok _ -> C.fail "a change past its budget must be refused"
   | Error e -> C.fail "expected Invalid: %s" (message e));
  Atomic.set stop true;
  Thread.join w;
  C.check (Atomic.get writes > 0) "writes went on (%d)" (Atomic.get writes);
  C.check (Schema.rule_by_name (view db).schema "cross" = None && Store.count_prop (view db) b = 0) "nothing of it is there";
  section "a change of the ontology past a data write's budget: a change's budget, on the disk and on a fork alike";
  ignore (ok (define db [ rule "cax-sco" [ { e = x; p = ty; v = y }; { e = y; p = sub; v = z } ] (Give { e = x; p = ty; v = z }) ]));
  let r = ok (write db (List.init 300 (fun i -> Add (-(i + 1), ty, Link t.(10))))) in
  ignore r;
  Reason.budget_base := 100;
  Reason.change_per := 2;
  let f = fork (view db) in
  let onto = [ Add (t.(10), sub, Link t.(11)); Add (t.(11), sub, Link t.(12)) ] in
  (match write db onto, write f onto with
   | Ok _, Ok _ ->
     C.check (exact (view db) && F.equal (C.user_facts (view db)) (C.user_facts (view f))) "the same view on the disk and on the fork, exact";
     C.check (Store.count_things (view db) ty t.(11) >= 300) "every member of the class has the new type"
   | a, b ->
     let s = function Ok _ -> "ok" | Error e -> message e in
     C.fail "an ontology change must pass on both: %s / %s" (s a) (s b));
  (* a data write past a data write's budget: refused on both *)
  let data = List.init 150 (fun i -> Add (-(i + 1), ty, Link t.(10))) in
  (match write db data, write f data with
   | Error (Invalid m), Error (Invalid m') -> C.check (m = m') "the same refusal on both: %s" m
   | _ -> C.fail "a data write past its budget must be refused on both");
  Reason.budget_base := b0;
  Reason.budget_per := b1;
  Reason.change_per := c0;
  close db;
  C.rmrf d

let closing () =
  section "close during a change: Closed, nothing of it after the reopen";
  let d = C.tmpdir "rc-close" in
  let db = open_db d in
  let a, b, _, _ = schema db in
  let t = things db 20 in
  ignore (ok (write db (List.init 19 (fun i -> Add (t.(i), a, Link t.(i + 1))))));
  Engine.change_pause := 0.5;
  let res = in_thread (fun () -> define db [ rule "copy" [ { e = x; p = a; v = y } ] (Give { e = x; p = b; v = y }) ]) in
  Unix.sleepf 0.1;
  let t0 = Unix.gettimeofday () in
  close db;
  let dt = Unix.gettimeofday () -. t0 in
  Engine.change_pause := 0.;
  (match res () with Error Closed -> C.check true "Closed" | Ok _ -> C.fail "a change cut by the close must not be confirmed" | Error e -> C.fail "expected Closed: %s" (message e));
  C.check (dt < 2.) "the close waited %.2f s" dt;
  let db = open_db d in
  C.check (Schema.rule_by_name (view db).schema "copy" = None && Store.count_prop (view db) b = 0 && exact (view db)) "reopened: no trace of it";
  close db;
  C.rmrf d

(* ---- kill -9: a child writes and changes the rules until killed ---- *)

let child d =
  let db = open_db d in
  let a, b, ty, _ = schema db in
  let v = view db in
  let t =
    if Store.count_prop v a = 0 then begin
      let t = things db 400 in
      ignore (ok (write db (List.init 399 (fun i -> Add (t.(i), a, Link t.(i + 1))))));
      t
    end
    else (let l = ref [] in Store.iter_prop v a (fun e _ -> l := e :: !l); Array.of_list (List.sort_uniq compare !l))
  in
  let n = Array.length t in
  let pool =
    [| rule "copy" [ { e = x; p = a; v = y } ] (Give { e = x; p = b; v = y });
       rule "back" [ { e = x; p = a; v = y } ] (Give { e = y; p = b; v = x });
       rule "typed" [ { e = x; p = b; v = y } ] (Give { e = y; p = ty; v = Thing t.(0) }) |]
  in
  for k = 0 to 2 do
    ignore (Thread.create (fun () ->
        let r = Rng.make (Unix.getpid () + k) in
        while true do ignore (write db [ Add (t.(Rng.int r n), a, Link t.(Rng.int r n)); Retract (t.(Rng.int r n), a, Link t.(Rng.int r n)) ]) done) ())
  done;
  let r = Rng.make (Unix.getpid ()) in
  while true do
    if Rng.bool r then ignore (define db [ pool.(Rng.int r 3) ]) else ignore (undefine db [ pool.(Rng.int r 3).name ])
  done

let kills rounds =
  section (Printf.sprintf "kill -9 during changes, %d rounds: after each recovery the view is exact under its rules" rounds);
  let d = C.tmpdir "rc-kill" in
  let r = Rng.make 11 and seen = ref [] in
  for round = 1 to rounds do
    let pid = Unix.create_process Sys.executable_name [| Sys.executable_name; "--child"; d |] Unix.stdin Unix.stdout Unix.stderr in
    Unix.sleepf (0.2 +. (float (Rng.int r 800) /. 1000.));
    Unix.kill pid Sys.sigkill;
    ignore (Unix.waitpid [] pid);
    match open_ d with
    | Error e -> C.fail "round %d: reopen: %s" round (message e)
    | Ok db ->
      let v = view db in
      C.check (exact v) "round %d: the recovered view (group %d) is exact under its %d rules" round v.group (List.length (C.rules_of v));
      seen := List.sort_uniq compare (List.map (fun (rl : rule) -> rl.name) (C.rules_of v)) :: !seen;
      close db
  done;
  Printf.printf "  rule sets recovered: %s\n%!" (String.concat " " (List.map (fun l -> "{" ^ String.concat "," l ^ "}") (List.rev !seen)));
  C.rmrf d

let () =
  match Sys.argv with
  | [| _; "--child"; d |] -> child d
  | _ ->
    Pages.set_capacity (32 lsl 20);
    let rounds = if Array.length Sys.argv > 1 then int_of_string Sys.argv.(1) else 10 in
    interleavings ();
    concurrency ();
    budget ();
    closing ();
    kills rounds;
    C.finish "rulechange"
