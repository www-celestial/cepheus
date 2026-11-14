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
   - a change with an Incr in its group: computed in its group, beside groups that count with the same counter;
   - a Raft member: a change's frame proposed; a frame taken back or another leader's frame answers it not_leader;
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
  section "a change in its group while another runs in the background: that one ends with Conflict and tries again";
  Engine.change_pause := 0.3;
  let res = in_thread (fun () -> define db [ rule "later" [ { e = x; p = ty; v = y } ] (Give { e = y; p = b; v = x }) ]) in
  Unix.sleepf 0.05;
  let id = free_id (view db) in
  let text = Rules.to_text (rule "made2" [ { e = x; p = sub; v = y } ] (Give { e = y; p = a; v = x })) in
  ignore (ok (write db [ Add (id + 1, Schema.p_name, Text "made2"); Add (id + 1, Schema.p_rule, Text text); Add (-1, sub, Link t.(4)) ]));
  (match res () with
   | Ok _ ->
     let v = view db in
     C.check (Schema.rule_by_name v.schema "later" <> None && Schema.rule_by_name v.schema "made2" <> None && exact v) "both rules, exact"
   | Error e -> C.fail "the change after a Conflict: %s" (message e));
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

(* a change of the rules with an Incr in its group: computed in its group (inline), its counter read at its point, so
   that the groups counting with the same counter meanwhile never conflict with it and none is lost *)
let counting () =
  section "a change with an Incr in its group: computed in its group, beside groups that count with the same counter";
  let d = C.tmpdir "rc-incr" in
  let db = open_db d in
  let a, b, _, _ = schema db in
  let n = Option.get (property (view db) "n") in
  let t = things db 20 in
  ignore (ok (write db (List.init 19 (fun i -> Add (t.(i), a, Link t.(i + 1))))));
  let counter = t.(0) and before = Atomic.get Engine.changes_done in
  let stop = Atomic.make false and counted = Atomic.make 0 and refused = Atomic.make 0 in
  let w = Thread.create (fun () -> while not (Atomic.get stop) do (match write db [ Incr (counter, n, 1, None) ] with Ok _ -> Atomic.incr counted | Error _ -> Atomic.incr refused) done) () in
  Unix.sleepf 0.05;
  let id = free_id (view db) in
  let text = Rules.to_text (rule "copy" [ { e = x; p = a; v = y } ] (Give { e = x; p = b; v = y })) in
  let res = write db [ Add (id, Schema.p_name, Text "copy"); Add (id, Schema.p_rule, Text text); Expect (id, Schema.p_name, None); Incr (counter, n, 1, None) ] in
  Unix.sleepf 0.05;
  Atomic.set stop true;
  Thread.join w;
  (match res with
   | Ok _ ->
     let v = view db in
     C.check (Schema.rule_by_name v.schema "copy" <> None && Store.count_prop v b = 19 && exact v) "the rule and its consequences are there, exact";
     C.check (values v counter n = [ Int (Atomic.get counted + 1) ]) "the counter counted every group (%d and the change's)" (Atomic.get counted);
     C.check (Atomic.get Engine.changes_done = before) "the change was computed in its group, not in the background"
   | Error e -> C.fail "a change with an Incr: %s" (message e));
  C.check (Atomic.get refused = 0 && Atomic.get counted > 0) "the groups counting beside it: %d, none refused" (Atomic.get counted);
  close db;
  let db = open_db d in
  C.check (exact (view db) && values (view db) counter n = [ Int (Atomic.get counted + 1) ]) "reopened: the same";
  close db;
  C.rmrf d

(* A Raft cluster's member (Engine.start ~raft: each write's frame proposed, written once committed; Cluster's
   propose replaced here by a function that records the frames, or refuses one as a server that stopped leading):
   a change's frame is proposed as every write's; a frame refused and taken back, or a frame of another leader
   applied, while a change runs in the background, answers the change not_leader and installs nothing of it: its view
   held a group that was never committed, or missed one. An equality rule's classes (cepheus/same) go through the
   same frames. The journal replayed gives the same view. *)
let raft_member () =
  section "a Raft member: a change's frame proposed; a frame taken back, or another leader's frame, answers the change not_leader";
  let d = C.tmpdir "rc-raft" in
  let e = match Engine.open_ Disk.real d with Ok e -> e | Error e -> failwith (message e) in
  let l = Engine.start ~raft:true e in
  let proposed = ref [] and refuse = Atomic.make false and pm = Mutex.create () in
  l.propose <-
    (fun first count _ ->
      if Atomic.exchange refuse false then Error Engine.not_leader
      else (Mutex.protect pm (fun () -> proposed := (first, count) :: !proposed); Ok ()));
  let wr ops = Engine.write l ops 0 "w" in
  let pub () = Atomic.get e.published in
  let ids, ops = Result.get_ok (Resolve.declare (pub ()) [ prop ~many:true "a" Tlink; prop ~many:true "b" Tlink; prop ~many:true "type" Tlink; prop "n" Tint ]) in
  ignore (ok (wr ops));
  let[@warning "-8"] [ a; b; ty; n ] = ids in
  let r = ok (wr (List.init 30 (fun i -> Add (-(i + 1), n, Int i)))) in
  let t = Array.init 30 (fun i -> List.assoc (-(i + 1)) r.things) in
  ignore (ok (wr (List.init 29 (fun i -> Add (t.(i), a, Link t.(i + 1))))));
  let define name where head =
    let id = free_id (Atomic.get e.published) in
    let text = Rules.to_text (rule name where head) in
    [ Add (id, Schema.p_name, Text name); Add (id, Schema.p_rule, Text text); Expect (id, Schema.p_name, None) ]
  in
  let has v x p y = List.mem (Link y) (values v x p) in
  let applied = ref [] in
  let all_proposed () =
    (* every group from 2 on (group 1 is made at the open) proposed once, in order, none twice, but another leader's *)
    let gs = List.concat_map (fun (f, c) -> List.init c (fun k -> f + k)) (Mutex.protect pm (fun () -> !proposed)) in
    List.sort compare (gs @ !applied) = List.init ((pub ()).group - 1) (fun k -> k + 2)
  in
  let in_thread_w ops = in_thread (fun () -> wr ops) in
  (* a change beside writes: its frame proposed *)
  Engine.change_pause := 0.2;
  let before = Atomic.get Engine.changes_done in
  let res = in_thread_w (define "copy" [ { e = x; p = a; v = y } ] (Give { e = x; p = b; v = y })) in
  Unix.sleepf 0.05;
  for i = 0 to 4 do ignore (ok (wr [ Add (t.(i), ty, Link t.(29)) ])) done;
  (match res () with
   | Ok rc ->
     C.check (Atomic.get Engine.changes_done = before + 1) "the change went the background path";
     C.check (List.exists (fun (f, c) -> f <= rc.group && rc.group < f + c) (Mutex.protect pm (fun () -> !proposed))) "the change's group %d was proposed" rc.group;
     C.check (exact (pub ()) && Store.count_prop (pub ()) b = 29) "its consequences there, exact"
   | Error er -> C.fail "a change on a Raft member: %s" (message er));
  C.check (all_proposed ()) "every group was proposed, once, in order";
  (* a frame refused while a change runs: taken back; the change answered not_leader, nothing of it there *)
  let res = in_thread_w (define "back" [ { e = x; p = a; v = y } ] (Give { e = y; p = b; v = x })) in
  Unix.sleepf 0.05;
  Atomic.set refuse true;
  (match wr [ Add (t.(5), ty, Link t.(6)) ] with
   | Error er -> C.check (Engine.is_not_leader er) "a frame refused: not_leader (%s)" (message er)
   | Ok _ -> C.fail "a refused frame was confirmed");
  ignore (ok (wr [ Add (t.(7), ty, Link t.(8)) ]));
  (match res () with
   | Error er -> C.check (Engine.is_not_leader er) "the change beside a frame taken back: not_leader (%s)" (message er)
   | Ok _ -> C.fail "a change whose view held a group taken back was installed");
  let v = pub () in
  C.check (Schema.rule_by_name v.schema "back" = None && not (has v t.(5) ty t.(6)) && has v t.(7) ty t.(8) && exact v)
    "nothing of the change nor of the group taken back; the next group there; exact";
  C.check (all_proposed ()) "every group was proposed, once, in order, after the frame taken back";
  (* a frame of another leader applied while a change runs: the change answered not_leader *)
  let res = in_thread_w (define "typed" [ { e = x; p = a; v = y } ] (Give { e = y; p = ty; v = Thing t.(0) })) in
  Unix.sleepf 0.05;
  let v = pub () in
  let g = match Resolve.resolve v ~n:(v.group + 1) ~time:0 ~by:0 ~why:"another leader" [ Add (t.(9), ty, Link t.(10)) ] with
    | Ok (_, g, _) -> g | Error _ -> failwith "another leader's group" in
  let body = Buffer.create 256 in
  Group.encode body g;
  let body = Buffer.to_bytes body in
  (match Engine.call l (fun r -> Engine.Apply (r, { Engine.first = g.n; count = 1; body; len = Bytes.length body })) with
   | Ok _ -> applied := g.n :: !applied; C.check true "another leader's frame applied"
   | Error er -> C.fail "another leader's frame: %s" (message er));
  (match res () with
   | Error er -> C.check (Engine.is_not_leader er) "the change beside another leader's frame: not_leader (%s)" (message er)
   | Ok _ -> C.fail "a change was installed across another leader's frame");
  let v = pub () in
  C.check (Schema.rule_by_name v.schema "typed" = None && has v t.(9) ty t.(10) && exact v) "nothing of the change; the frame there; exact";
  Engine.change_pause := 0.;
  (* a change once the lineage is steady again: installed *)
  (match wr (define "typed" [ { e = x; p = a; v = y } ] (Give { e = y; p = ty; v = Thing t.(0) })) with
   | Ok _ -> C.check (Schema.rule_by_name (pub ()).schema "typed" <> None && exact (pub ())) "a change after them: installed, exact"
   | Error er -> C.fail "a change after them: %s" (message er));
  (* equality (cepheus/same, OWL's owl:sameAs by rewriting): its rule a change of the rules, its classes derived
     facts of ordinary frames, all proposed; the journal gives the same classes *)
  (match wr (define "same-n" [ { e = x; p = n; v = z }; { e = y; p = n; v = z } ] (Give { e = x; p = Schema.p_same; v = y })) with
   | Ok _ -> C.check true "an equality rule defined on a Raft member"
   | Error er -> C.fail "an equality rule on a Raft member: %s" (message er));
  let twin = List.assoc (-1) (ok (wr [ Add (-1, n, Int 3) ])).things in
  let cls v = List.sort compare (same v twin) in
  C.check (List.mem t.(3) (cls (pub ())) && List.length (cls (pub ())) = 2) "a new thing made equal to #%d by the rule: one class of two" t.(3);
  C.check (all_proposed ()) "every group was proposed (but the other leader's), the equality's included";
  let last = C.user_facts (pub ()) and last_cls = cls (pub ()) in
  Engine.stop l;
  let db = open_db d in
  C.check (F.equal (C.user_facts (view db)) last && cls (view db) = last_cls) "reopened: the journal gives the same view and the same class";
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
    counting ();
    raft_member ();
    kills rounds;
    C.finish "rulechange"
