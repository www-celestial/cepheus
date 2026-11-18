(* Benchmarks of the rules, in the process (a fork: no disk), on LUBM-shaped data (Guo, Pan, Heflin 2005): universities
   generated from the published ranges of the UBA generator, with the univ-bench ontology's axioms as one rule an
   axiom (subclass, domain, range, subproperty, inverse, transitive, the six defined classes in the direction OWL 2 RL
   can use: 94 rules). It is not the official UBA output.

   reason.exe mat N rules|none groups|bulk DIR|-   load N universities, a group a department or one group, into a
                                     database on the disk (DIR, made empty first) or in memory (-); the time, the facts,
                                     the derived facts, the time of the reasoning alone
   reason.exe student N R DIR       N universities in DIR-rules and DIR-none (a snapshot: one run), then in a fork of
                                     each: R graduate students written (10 facts, a group each), then retracted (a
                                     group each), with the rules and without; per group, in microseconds
   reason.exe why N R DIR           the same base with rules: R proofs of derived facts of five kinds
   reason.exe apply N               the cost of putting a derived fact into the view (Store.set), alone
   reason.exe closure KIND FORM DIR|-   a graph's edges in one group, with a transitive closure's rules: KIND hierarchy
                                     (100,000 nodes, 4 children each, depth 8), deep (20,000 nodes, 2 children
                                     each), dag (5,000 nodes, 3 edges down each, the design's random DAG) or chain (500
                                     nodes); FORM trp (prp-trp over the edges' property), linear (edges and closure apart)
                                     or none; on the disk in DIR (the path of large groups) or in memory (-): the time,
                                     the closure's facts, the reasoning alone
   reason.exe notagg N K R agg|plain|none   N invoices of K lines, then R rounds of a line added and retracted, a
                                     payment added and retracted: aggregates and a Not, against the same bodies as plain
                                     rules, and without rules; per group, in microseconds
   reason.exe w3c N groups|bulk DIR|-   as mat N rules, with the univ-bench ontology as facts and the W3C's form of the
                                     OWL 2 RL rules it needs (10 rules, variable properties), which the engine unfolds
   reason.exe owl N groups|bulk DIR|-   the same with OWL 2 RL whole (Cepheus.Owl: its vocabulary and every rule)
   reason.exe owlprep N DIR         N universities and the ontology in OWL 2 RL's vocabulary in DIR, with no rule
   reason.exe owldefine DIR disk|fork   OWL 2 RL defined on DIR (or a fork of it): the time, the facts of owl/Type
   reason.exe uobm N rew|ax         UOBM-like: N universities, a quarter of the people recorded 2 to 4 times, the e-mail
                                     inverse functional; equality by rewriting (rew) or axiomatised (ax), in memory *)

open Cepheus

let now = Unix.gettimeofday
let ok = function Ok x -> x | Error e -> failwith (message e)

let props =
  [| "advisor"; "affiliatedOrganizationOf"; "affiliateOf"; "age"; "degreeFrom"; "doctoralDegreeFrom";
     "emailAddress"; "hasAlumnus"; "headOf"; "listedCourse"; "mastersDegreeFrom"; "member"; "memberOf"; "name";
     "officeNumber"; "orgPublication"; "publicationAuthor"; "publicationDate"; "publicationResearch";
     "researchInterest"; "researchProject"; "softwareDocumentation"; "softwareVersion"; "subOrganizationOf";
     "takesCourse"; "teacherOf"; "teachingAssistantOf"; "telephone"; "tenured"; "title"; "undergraduateDegreeFrom";
     "worksFor" |]

let literal = [ "age"; "emailAddress"; "name"; "officeNumber"; "publicationDate"; "researchInterest"; "softwareVersion"; "telephone"; "title"; "tenured" ]

let classes =
  [| "AdministrativeStaff"; "Article"; "AssistantProfessor"; "AssociateProfessor"; "Book"; "Chair"; "ClericalStaff";
     "College"; "ConferencePaper"; "Course"; "Dean"; "Department"; "Director"; "Employee"; "Faculty";
     "FullProfessor"; "GraduateCourse"; "GraduateStudent"; "Institute"; "JournalArticle"; "Lecturer"; "Manual";
     "Organization"; "Person"; "PostDoc"; "Professor"; "Program"; "Publication"; "Research"; "ResearchAssistant";
     "ResearchGroup"; "Schedule"; "Software"; "Specification"; "Student"; "SystemsStaff"; "TeachingAssistant";
     "TechnicalReport"; "UndergraduateStudent"; "University"; "UnofficialPublication"; "VisitingProfessor"; "Work" |]

type ids = { ty : int; pr : string -> int; cls : string -> int; univ : int -> int }

(* the schema, the class things and 1,000 universities (degrees come from universities 0 .. 999, as UBA does) *)
let setup db =
  let ps =
    prop ~many:true "type" Tlink
    :: Array.to_list (Array.map (fun n -> if List.mem n literal then prop ~many:true n Ttext else prop ~many:true n Tlink) props)
  in
  let pids = Array.of_list (ok (declare db ps)) in
  let ty = pids.(0) in
  let pr n = let rec go i = if props.(i) = n then pids.(i + 1) else go (i + 1) in go 0 in
  let label = pr "name" in
  let r = ok (write db (Array.to_list (Array.mapi (fun i c -> Add (-(i + 1), label, Text c)) classes))) in
  let cids = Array.mapi (fun i _ -> thing r (-(i + 1))) classes in
  let cls n = let rec go i = if classes.(i) = n then cids.(i) else go (i + 1) in go 0 in
  let r = ok (write db (List.init 1000 (fun u -> Add (-(u + 1), label, Text (Printf.sprintf "University%d" u))))) in
  let us = Array.init 1000 (fun u -> thing r (-(u + 1))) in
  { ty; pr; cls; univ = (fun u -> us.(u)) }

(* the univ-bench axioms, one rule each *)
let ontology_rules ids =
  let x = Var 0 and y = Var 1 and z = Var 2 in
  let ty = ids.ty and pr = ids.pr and cls = ids.cls in
  let k = ref 0 in
  let rule where head = incr k; { name = Printf.sprintf "ub%02d" !k; vars = 3; where; ranges = []; head = Give head } in
  let renum (r : rule) =
    (* vars used, densely *)
    let used = Array.make 3 false in
    List.iter (fun (q : pattern) -> List.iter (function Var v -> used.(v) <- true | _ -> ()) [ q.e; q.v ]) r.where;
    let map = Array.make 3 0 and n = ref 0 in
    Array.iteri (fun v u -> if u then (map.(v) <- !n; incr n)) used;
    let t = function Var v -> Var map.(v) | t -> t in
    let pat (q : pattern) = { q with e = t q.e; v = t q.v } in
    { r with vars = !n; where = List.map pat r.where; head = (match r.head with Give h -> Give (pat h) | Never -> Never) }
  in
  let out = ref [] in
  let add r = out := renum r :: !out in
  let sub a b = add (rule [ { e = x; p = ty; v = Thing (cls a) } ] { e = x; p = ty; v = Thing (cls b) }) in
  List.iter (fun (a, b) -> sub a b)
    [ "AdministrativeStaff", "Employee"; "Article", "Publication"; "AssistantProfessor", "Professor";
      "AssociateProfessor", "Professor"; "Book", "Publication"; "Chair", "Professor"; "ClericalStaff", "AdministrativeStaff";
      "College", "Organization"; "ConferencePaper", "Article"; "Course", "Work"; "Dean", "Professor";
      "Department", "Organization"; "Faculty", "Employee"; "FullProfessor", "Professor"; "GraduateCourse", "Course";
      "GraduateStudent", "Person"; "Institute", "Organization"; "JournalArticle", "Article"; "Lecturer", "Faculty";
      "Manual", "Publication"; "PostDoc", "Faculty"; "Professor", "Faculty"; "Program", "Organization";
      "Research", "Work"; "ResearchAssistant", "Person"; "ResearchGroup", "Organization"; "Software", "Publication";
      "Specification", "Publication"; "SystemsStaff", "AdministrativeStaff"; "TechnicalReport", "Article";
      "UndergraduateStudent", "Student"; "University", "Organization"; "UnofficialPublication", "Publication";
      "VisitingProfessor", "Professor"; "Chair", "Person"; "Employee", "Person"; "Student", "Person";
      "TeachingAssistant", "Person"; "Director", "Person" ];
  let dom p c = add (rule [ { e = x; p = pr p; v = y } ] { e = x; p = ty; v = Thing (cls c) }) in
  let rng p c = add (rule [ { e = x; p = pr p; v = y } ] { e = y; p = ty; v = Thing (cls c) }) in
  dom "advisor" "Person"; rng "advisor" "Professor";
  dom "affiliatedOrganizationOf" "Organization"; rng "affiliatedOrganizationOf" "Organization";
  dom "affiliateOf" "Organization"; rng "affiliateOf" "Person";
  dom "age" "Person";
  dom "degreeFrom" "Person"; rng "degreeFrom" "University";
  dom "doctoralDegreeFrom" "Person"; rng "doctoralDegreeFrom" "University";
  dom "emailAddress" "Person";
  dom "hasAlumnus" "University"; rng "hasAlumnus" "Person";
  dom "listedCourse" "Schedule"; rng "listedCourse" "Course";
  dom "mastersDegreeFrom" "Person"; rng "mastersDegreeFrom" "University";
  dom "member" "Organization"; rng "member" "Person";
  dom "orgPublication" "Organization"; rng "orgPublication" "Publication";
  dom "publicationAuthor" "Publication"; rng "publicationAuthor" "Person";
  dom "publicationResearch" "Publication"; rng "publicationResearch" "Research";
  dom "researchProject" "ResearchGroup"; rng "researchProject" "Research";
  dom "softwareDocumentation" "Software"; rng "softwareDocumentation" "Publication";
  dom "subOrganizationOf" "Organization"; rng "subOrganizationOf" "Organization";
  dom "teacherOf" "Faculty"; rng "teacherOf" "Course";
  dom "teachingAssistantOf" "TeachingAssistant"; rng "teachingAssistantOf" "Course";
  dom "tenured" "Professor";
  dom "undergraduateDegreeFrom" "Person"; rng "undergraduateDegreeFrom" "University";
  let subp a b = add (rule [ { e = x; p = pr a; v = y } ] { e = x; p = pr b; v = y }) in
  subp "doctoralDegreeFrom" "degreeFrom"; subp "mastersDegreeFrom" "degreeFrom";
  subp "undergraduateDegreeFrom" "degreeFrom"; subp "headOf" "worksFor"; subp "worksFor" "memberOf";
  let inv a b =
    add (rule [ { e = x; p = pr a; v = y } ] { e = y; p = pr b; v = x });
    add (rule [ { e = x; p = pr b; v = y } ] { e = y; p = pr a; v = x })
  in
  inv "member" "memberOf";
  inv "hasAlumnus" "degreeFrom";
  add (rule [ { e = x; p = pr "subOrganizationOf"; v = y }; { e = y; p = pr "subOrganizationOf"; v = z } ] { e = x; p = pr "subOrganizationOf"; v = z });
  (* the defined classes, right to left: C = A and some P D *)
  let define c a p d =
    let body = [ { e = x; p = pr p; v = y }; { e = y; p = ty; v = Thing (cls d) } ] in
    let body = match a with Some a -> { e = x; p = ty; v = Thing (cls a) } :: body | None -> body in
    add (rule body { e = x; p = ty; v = Thing (cls c) })
  in
  define "Chair" (Some "Person") "headOf" "Department";
  define "Dean" None "headOf" "College";
  define "Director" (Some "Person") "headOf" "Program";
  define "Employee" (Some "Person") "worksFor" "Organization";
  define "Student" (Some "Person") "takesCourse" "Course";
  define "TeachingAssistant" (Some "Person") "teachingAssistantOf" "Course";
  List.rev !out

(* ---- the data: a group a department ---- *)

type gen = { mutable st : int; mutable lit : int }

let rand g lo hi =
  let x = g.st in
  let x = x lxor ((x lsl 13) land 0x7FFFFFFFFFFFFFFF) in
  let x = x lxor (x lsr 7) in
  let x = x lxor ((x lsl 17) land 0x7FFFFFFFFFFFFFFF) in
  g.st <- x;
  lo + ((x land 0x3FFFFFFF) mod (hi - lo + 1))

let lit g = g.lit <- g.lit + 1; Text (Printf.sprintf "l%d" g.lit)

(* the groups of university u: its own facts, then one group a department (new things are temporary ids) *)
let university ids g u (write : op list -> unit) =
  let pr = ids.pr and cls = ids.cls and ty = ids.ty in
  let univ = ids.univ u in
  write [ Add (univ, ty, Link (cls "University")) ];
  for _ = 1 to rand g 15 25 do
    let ops = ref [] and next = ref 0 in
    let fresh () = decr next; !next in
    let e s p o = ops := Add (s, p, o) :: !ops in
    let tyf s c = e s ty (Link (cls c)) in
    let d = fresh () in
    tyf d "Department";
    e d (pr "name") (lit g);
    e d (pr "subOrganizationOf") (Link univ);
    for _ = 1 to rand g 10 20 do
      let rg = fresh () in
      tyf rg "ResearchGroup";
      e rg (pr "subOrganizationOf") (Link d)
    done;
    let courses = ref [] and gcourses = ref [] and profs = ref [] and nf = ref 0 in
    let faculty kind (lo, hi) =
      let f = fresh () in
      incr nf;
      tyf f kind;
      e f (pr "name") (lit g); e f (pr "emailAddress") (lit g); e f (pr "telephone") (lit g);
      e f (pr "worksFor") (Link d);
      e f (pr "undergraduateDegreeFrom") (Link (ids.univ (rand g 0 999)));
      e f (pr "mastersDegreeFrom") (Link (ids.univ (rand g 0 999)));
      e f (pr "doctoralDegreeFrom") (Link (ids.univ (rand g 0 999)));
      if kind <> "Lecturer" then (e f (pr "researchInterest") (lit g); profs := f :: !profs);
      for _ = 1 to rand g 1 2 do
        let c = fresh () in tyf c "Course"; e c (pr "name") (lit g); e f (pr "teacherOf") (Link c); courses := c :: !courses
      done;
      for _ = 1 to rand g 1 2 do
        let c = fresh () in tyf c "GraduateCourse"; e c (pr "name") (lit g); e f (pr "teacherOf") (Link c); gcourses := c :: !gcourses
      done;
      for _ = 1 to rand g lo hi do
        let pb = fresh () in tyf pb "Publication"; e pb (pr "name") (lit g); e pb (pr "publicationAuthor") (Link f)
      done;
      f
    in
    let fulls = List.init (rand g 7 10) (fun _ -> faculty "FullProfessor" (15, 20)) in
    e (List.hd fulls) (pr "headOf") (Link d);
    for _ = 1 to rand g 10 14 do ignore (faculty "AssociateProfessor" (10, 18)) done;
    for _ = 1 to rand g 8 11 do ignore (faculty "AssistantProfessor" (5, 10)) done;
    for _ = 1 to rand g 5 7 do ignore (faculty "Lecturer" (0, 5)) done;
    let courses = Array.of_list !courses and gcourses = Array.of_list !gcourses and profs = Array.of_list !profs in
    let pick a = a.(rand g 0 (Array.length a - 1)) in
    for _ = 1 to !nf * rand g 8 14 do
      let s = fresh () in
      tyf s "UndergraduateStudent";
      e s (pr "name") (lit g); e s (pr "emailAddress") (lit g); e s (pr "telephone") (lit g);
      e s (pr "memberOf") (Link d);
      for _ = 1 to rand g 2 4 do e s (pr "takesCourse") (Link (pick courses)) done;
      if rand g 1 5 = 1 then e s (pr "advisor") (Link (pick profs))
    done;
    for _ = 1 to !nf * rand g 3 4 do
      let s = fresh () in
      tyf s "GraduateStudent";
      e s (pr "name") (lit g); e s (pr "emailAddress") (lit g); e s (pr "telephone") (lit g);
      e s (pr "memberOf") (Link d);
      e s (pr "undergraduateDegreeFrom") (Link (ids.univ (rand g 0 999)));
      for _ = 1 to rand g 1 3 do e s (pr "takesCourse") (Link (pick gcourses)) done;
      e s (pr "advisor") (Link (pick profs));
      if rand g 1 4 = 1 then e s (pr "teachingAssistantOf") (Link (pick courses));
      if rand g 1 3 = 1 then tyf s "ResearchAssistant"
    done;
    write (List.rev !ops)
  done

(* a database with n universities, the rules first when [rules]; in memory (a fork), or on the disk in [dir]; a group a
   department, or with [bulk] all of it in one group (a load: on the disk, the path of large groups; a fork always
   takes the ordinary path) *)
let build ?(bulk = false) ?(chunks = false) ?dir n rules =
  let db = match dir with None -> fork empty | Some d -> ok (open_ d) in
  let ids = setup db in
  if rules then ignore (ok (define db (ontology_rules ids)));
  let g = { st = (7 * 0x1E3779B97F4A7C15) lor 1; lit = 0 } in
  let groups = ref 0 in
  if not bulk then begin
    let t0 = now () in
    for u = 0 to n - 1 do university ids g u (fun ops -> incr groups; ignore (ok (write db ops))) done;
    db, ids, g, now () -. t0, !groups
  end
  else if chunks then begin
    (* a university a group (a load in chunks: about 135,000 facts a group), its operations made just before it is
       written; the clock runs only while the groups are written *)
    let t = ref 0. in
    for u = 0 to n - 1 do
      let all = ref [] and off = ref 0 in
      university ids g u (fun ops ->
          let low = ref 0 in
          let tr x = if x < 0 then (low := min !low x; x - !off) else x in
          List.iter (function Add (e, p, v) -> all := Add (tr e, p, (match v with Link l -> Link (tr l) | v -> v)) :: !all | o -> all := o :: !all) ops;
          off := !off - !low);
      let ops = List.rev !all in
      all := [];
      let t0 = now () in
      ignore (ok (write db ops));
      t := !t +. (now () -. t0);
      incr groups
    done;
    db, ids, g, !t, !groups
  end
  else begin
    (* every department's operations in one list, their new things numbered apart *)
    let all = ref [] and off = ref 0 in
    for u = 0 to n - 1 do
      university ids g u (fun ops ->
          let low = ref 0 in
          let t x = if x < 0 then (low := min !low x; x - !off) else x in
          List.iter
            (function
              | Add (e, p, v) -> all := Add (t e, p, (match v with Link l -> Link (t l) | v -> v)) :: !all
              | o -> all := o :: !all)
            ops;
          off := !off - !low)
    done;
    let ops = List.rev !all in
    Gc.compact ();
    let t0 = now () in
    ignore (ok (write db ops));
    db, ids, g, now () -. t0, 1
  end

let digest = ref 0

(* every fact counted, and a digest of the facts and their flags (the same database, however it was loaded) *)
let count_derived (v : view) =
  let d = ref 0 and all = ref 0 and h = ref 0 in
  for e = Schema.first_thing to v.next_e - 1 do
    Store.iter_facts v e (fun p w ->
        incr all;
        let st = Store.state v e p w in
        if st = 2 then incr d;
        h := !h + Hashtbl.hash (e, p, w, st))
  done;
  digest := !h;
  !all, !d

(* the ids of a database [setup] made: the properties declared again (their ids), the class things and the universities
   found by their names *)
let ids_of db =
  let ps =
    prop ~many:true "type" Tlink
    :: Array.to_list (Array.map (fun n -> if List.mem n literal then prop ~many:true n Ttext else prop ~many:true n Tlink) props)
  in
  let pids = Array.of_list (ok (declare db ps)) in
  let pr n = let rec go i = if props.(i) = n then pids.(i + 1) else go (i + 1) in go 0 in
  let v = view db in
  let named s = match things v (pr "name") (Text s) with x :: _ -> x | [] -> failwith ("no thing named " ^ s) in
  let cids = Array.map named classes in
  let cls n = let rec go i = if classes.(i) = n then cids.(i) else go (i + 1) in go 0 in
  let us = Array.init 1000 (fun u -> named (Printf.sprintf "University%d" u)) in
  { ty = pids.(0); pr; cls; univ = (fun u -> us.(u)) }

let pct a q = let a = Array.copy a in Array.sort compare a; a.(min (Array.length a - 1) (int_of_float (q *. float_of_int (Array.length a))))

let mat n mode path dir =
  let rules = mode = "rules" in
  Reason.derivations := 0;
  let dir = if dir = "-" then None else Some dir in
  (match Sys.getenv_opt "CACHE_MB" with Some m -> set_cache (int_of_string m * 1024 * 1024) | None -> ());
  let db, _, _, t, groups = build ~bulk:(path = "bulk" || path = "chunks") ~chunks:(path = "chunks") ?dir n rules in
  let all, d = count_derived (view db) in
  let r = !Reason.seconds and ix = !Reason.bulk_index_seconds in
  Printf.printf "mat %d %s %s %s: %.3f s, %d groups, %d facts (%d derived), %d derivations; reasoning %.3f s, %.3f M derived/s; of which the working set's build %.3f s, saturation %.3f M derived/s\n%!" n
    mode path (if dir = None then "memory" else "disk") t groups all d !Reason.derivations r
    (if r > 0. then float_of_int d /. r /. 1e6 else 0.) ix (if r -. ix > 0. then float_of_int d /. (r -. ix) /. 1e6 else 0.);
  Printf.printf "  digest %x\n" !digest;
  Printf.printf "  resolve %.3f encode %.3f merge %.3f\n" (float (Histogram.max Engine.large_resolve_us) /. 1e6) (float (Histogram.max Engine.large_encode_us) /. 1e6) (float (Histogram.max Engine.large_merge_us) /. 1e6);
  (let ic = open_in "/proc/self/status" in
   (try while true do let l = input_line ic in if String.length l > 6 && String.sub l 0 6 = "VmHWM:" then print_endline ("  " ^ l) done with End_of_file -> ());
   close_in ic);
  close db;
  (* the bytes on the disk: the runs and the journal, a fact *)
  match dir with
  | None -> ()
  | Some d ->
    let size sub = let p = Filename.concat d sub in if Sys.file_exists p then Array.fold_left (fun t f -> t + (Unix.stat (Filename.concat p f)).Unix.st_size) 0 (Sys.readdir p) else 0 in
    let r = size "snapshots" and j = size "journal" in
    Printf.printf "  disk: runs %d bytes (%.2f a fact), journal %d bytes (%.2f a fact)\n%!" r (float r /. float all) j (float j /. float all)

(* a graduate student of department d: 10 facts, 6 derived with the rules *)
let student ids g dept course prof =
  let pr = ids.pr in
  [ Add (-1, ids.ty, Link (ids.cls "GraduateStudent")); Add (-1, pr "name", lit g); Add (-1, pr "emailAddress", lit g);
    Add (-1, pr "telephone", lit g); Add (-1, pr "memberOf", Link dept);
    Add (-1, pr "undergraduateDegreeFrom", Link (ids.univ (rand g 0 999))); Add (-1, pr "takesCourse", Link course);
    Add (-1, pr "advisor", Link prof); Add (-1, pr "teachingAssistantOf", Link course);
    Add (-1, ids.ty, Link (ids.cls "ResearchAssistant")) ]

(* the database of [n] universities on the disk in [dir] (one group a department), merged into one run (a snapshot),
   and a fork of its view: the writer's work alone, on a base as a database has it (a fork never merges: written to
   with a whole load, its persistent maps would hold every fact) *)
let on_disk dir n rules =
  let db, ids, g, _, _ = build ~dir n rules in
  ok (snapshot db);
  let f = fork (view db) in
  close db;
  f, ids, g

let student_bench dir n reps =
  List.iter
    (fun rules ->
      let db, ids, g = on_disk (Printf.sprintf "%s-%s" dir (if rules then "rules" else "none")) n rules in
      let v = view db in
      (* a department, a graduate course and a professor of it *)
      let first p c = List.hd (things v p (Link c)) in
      let dept = first ids.ty (ids.cls "Department") in
      let course = first ids.ty (ids.cls "GraduateCourse") and prof = first ids.ty (ids.cls "FullProfessor") in
      let ins = Array.make reps 0. and del = Array.make reps 0. in
      let made = Array.make reps (0, []) in
      Reason.derivations := 0;
      for i = 0 to reps - 1 do
        let ops = student ids g dept course prof in
        let t0 = now () in
        let r = ok (write db ops) in
        ins.(i) <- (now () -. t0) *. 1e6;
        let x = thing r (-1) in
        made.(i) <- (x, List.map (function Add (_, p, v) -> Retract (x, p, (match v with Link t when t < 0 -> Link x | v -> v)) | o -> o) ops)
      done;
      let derived = List.length (List.filter (fun (p, x) -> Store.state (view db) (fst made.(0)) p (Option.get (Store.word (view db) x)) = 2) (get (view db) (fst made.(0)))) in
      for i = 0 to reps - 1 do
        let _, ops = made.(i) in
        let t0 = now () in
        ignore (ok (write db ops));
        del.(i) <- (now () -. t0) *. 1e6
      done;
      Printf.printf "student %d %s: %d derived a student; write median %.1f us p90 %.1f; retract median %.1f us p90 %.1f\n%!" n
        (if rules then "rules" else "none") derived (pct ins 0.5) (pct ins 0.9) (pct del 0.5) (pct del 0.9))
    [ false; true ]

let why_bench dir n reps =
  let db, ids, _ = on_disk dir n true in
  let v = view db in
  let kinds = [ "Person"; "Employee"; "Student"; "Organization"; "Faculty" ] in
  List.iter
    (fun c ->
      let xs = Array.of_list (List.filter (fun x -> Store.state v x ids.ty (ids.cls c) = 2) (things v ids.ty (Link (ids.cls c)))) in
      if Array.length xs > 0 then begin
        let ts = Array.make reps 0. and size = ref 0 in
        for i = 0 to reps - 1 do
          let x = xs.(i mod Array.length xs) in
          let t0 = now () in
          let p = why v x ids.ty (Link (ids.cls c)) in
          ts.(i) <- (now () -. t0) *. 1e6;
          let rec sz = function Given _ -> 1 | By b -> 1 + List.fold_left (fun n p -> n + sz p) 0 b.from in
          if i = 0 then size := (match p with Some p -> sz p | None -> 0)
        done;
        Printf.printf "why %s: median %.1f us p90 %.1f (a proof of %d facts)\n%!" c (pct ts 0.5) (pct ts 0.9) !size
      end)
    kinds

(* derived facts put into a view whose delta holds [n] changes, 6 a thing (a new thing's derived types, say): one
   Store.set a fact, then Store.set_sorted a batch of a thing's 6, as the reasoner puts a group's derived facts *)
let apply_bench n =
  let db = fork empty in
  let p = List.hd (ok (declare db [ prop ~many:true "x" Tlink ])) in
  let v = ref (view db) in
  for i = 0 to n - 1 do v := Store.set !v (Schema.first_thing + i) p (Schema.first_thing + i + 1) 1 done;
  let v0 = !v in
  let k = 100_000 in
  let t0 = now () in
  let v = ref v0 in
  for i = 0 to k - 1 do v := Store.set !v (Schema.first_thing + n + (i / 6)) p (Schema.first_thing + (i mod 6)) 2 done;
  let t1 = now () in
  let v = ref v0 in
  let ws = Array.init 6 (fun j -> Schema.first_thing + j) and ss = Array.make 6 2 in
  for t = 0 to (k / 6) - 1 do
    let e = Schema.first_thing + n + t in
    v := Store.set_sorted !v (Array.make 6 e) (Array.make 6 p) ws ss 6
  done;
  let t2 = now () in
  Printf.printf "apply: a derived fact into a delta of %d changes: %.3f us one by one, %.3f us in sorted batches of 6\n%!" n
    ((t1 -. t0) /. float k *. 1e6) ((t2 -. t1) /. float (6 * (k / 6)) *. 1e6)

(* ---- transitive closures (the design's section 6.4) ---- *)

(* the prototype's graphs: a tree whose node i > 0 has parent (i - 1) / b; a random DAG whose node i links to k nodes
   below it (OCaml's Random, seed 1, as the prototype drew it) *)
let tree n b = List.init (n - 1) (fun i -> let c = i + 1 in c, (c - 1) / b)

let dag n k seed =
  let rng = Random.State.make [| seed |] in
  List.concat (List.init (n - 1) (fun i -> let c = i + 1 in List.init k (fun _ -> c, Random.State.int rng c)))
  |> List.sort_uniq compare

let closure_bench kind form dir =
  Reason.trace := Sys.getenv_opt "TRACE" <> None;
  let n, edges =
    match kind with
    | "hierarchy" -> 100_000, tree 100_000 4
    | "deep" -> 20_000, tree 20_000 2
    | "dag" -> 5_000, dag 5_000 3 1
    | "chain" -> 500, tree 500 1
    | k -> failwith ("no graph " ^ k)
  in
  let db = if dir = "-" then fork empty else ok (open_ dir) in
  let e, t = match ok (declare db [ prop ~many:true "edge" Tlink; prop ~many:true "within" Tlink ]) with [ e; t ] -> e, t | _ -> assert false in
  let x = Var 0 and y = Var 1 and z = Var 2 in
  let edge_p = if form = "linear" then e else t in
  (match form with
   | "trp" -> ignore (ok (define db [ { name = "trp"; vars = 3; where = [ { e = x; p = t; v = y }; { e = y; p = t; v = z } ]; ranges = []; head = Give { e = x; p = t; v = z } } ]))
   | "linear" ->
     ignore (ok (define db [ { name = "base"; vars = 2; where = [ { e = x; p = e; v = y } ]; ranges = []; head = Give { e = x; p = t; v = y } };
                             { name = "step"; vars = 3; where = [ { e = x; p = e; v = y }; { e = y; p = t; v = z } ]; ranges = []; head = Give { e = x; p = t; v = z } } ]))
   | _ -> ());
  (* the nodes, then the edges in one group *)
  let r = ok (write db (List.init n (fun i -> Add (-(i + 1), e, Link (-(i + 1)))))) in
  let node = Array.init n (fun i -> thing r (-(i + 1))) in
  ignore (ok (write db (List.init n (fun i -> Retract (node.(i), e, Link node.(i))))));
  let ops = List.map (fun (a, b) -> Add (node.(a), edge_p, Link node.(b))) edges in
  Gc.compact ();
  Reason.seconds := 0.;
  Reason.module_seconds := 0.;
  Reason.bulk_index_seconds := 0.;
  Reason.derivations := 0;
  let t0 = now () in
  ignore (ok (write db ops));
  let el = now () -. t0 in
  let v = view db in
  let closure = ref 0 and derived = ref 0 in
  Array.iter (fun a -> Store.iter_values v a t (fun w -> incr closure; if Store.state v a t w = 2 then incr derived)) node;
  Printf.printf "closure %s %s %s: %d nodes, %d edges: %.4f s, closure %d facts (%d derived), %d derivations; reasoning %.4f s, of which the module %.4f s, the working set's build %.4f s\n%!" kind form
    (if dir = "-" then "memory" else "disk") n (List.length edges) el !closure !derived !Reason.derivations !Reason.seconds
    !Reason.module_seconds !Reason.bulk_index_seconds;
  close db

(* the retraction of one edge of a closure built as above (the edge of node [k]: in the hierarchy a node of depth 2,
   its subtree 6,250 things; in the DAG the first edge of node 2,500), by walks or by B/F through the rule's plans:
   the group's time, its reasoning, the facts lost; the closure after counted *)
let closure_del kind form dir how =
  Reason.walk_retract := how = "walk";
  let n, edges, k =
    match kind with
    | "hierarchy" -> 100_000, tree 100_000 4, 5
    | "dag" -> 5_000, dag 5_000 3 1, 2_500
    | "chain" -> 500, tree 500 1, 250
    | k -> failwith ("no graph " ^ k)
  in
  let k = match Sys.getenv_opt "DEL_NODE" with Some s -> int_of_string s | None -> k in
  let db = if dir = "-" then fork empty else ok (open_ dir) in
  let e, t = match ok (declare db [ prop ~many:true "edge" Tlink; prop ~many:true "within" Tlink ]) with [ e; t ] -> e, t | _ -> assert false in
  let x = Var 0 and y = Var 1 and z = Var 2 in
  let edge_p = if form = "linear" then e else t in
  (match form with
   | "trp" -> ignore (ok (define db [ { name = "trp"; vars = 3; where = [ { e = x; p = t; v = y }; { e = y; p = t; v = z } ]; ranges = []; head = Give { e = x; p = t; v = z } } ]))
   | _ ->
     ignore (ok (define db [ { name = "base"; vars = 2; where = [ { e = x; p = e; v = y } ]; ranges = []; head = Give { e = x; p = t; v = y } };
                             { name = "step"; vars = 3; where = [ { e = x; p = e; v = y }; { e = y; p = t; v = z } ]; ranges = []; head = Give { e = x; p = t; v = z } } ])));
  let r = ok (write db (List.init n (fun i -> Add (-(i + 1), e, Link (-(i + 1)))))) in
  let node = Array.init n (fun i -> thing r (-(i + 1))) in
  ignore (ok (write db (List.init n (fun i -> Retract (node.(i), e, Link node.(i))))));
  ignore (ok (write db (List.map (fun (a, b) -> Add (node.(a), edge_p, Link node.(b))) edges)));
  let a, b = List.find (fun (a, _) -> a = k) edges in
  let count () = let c = ref 0 in Array.iter (fun x -> Store.iter_values (view db) x t (fun _ -> incr c)) node; !c in
  let before = count () in
  Gc.compact ();
  Reason.seconds := 0.;
  let t0 = now () in
  ignore (ok (write db [ Retract (node.(a), edge_p, Link node.(b)) ]));
  let el = now () -. t0 in
  let after = count () in
  Printf.printf "closure-del %s %s %s: the edge %d -> %d retracted in %.4f s, reasoning %.4f s; closure %d -> %d facts (%d lost)\n%!" kind form how a b el
    !Reason.seconds before after (before - after);
  close db

(* ---- LUBM with the W3C's form of the rules: the ontology as facts ---- *)

let w3c_props =
  [| "subClassOf"; "domainOf"; "rangeOf"; "subProperty"; "superProperty"; "inverseA"; "inverseB"; "transitive";
     "onProperty"; "someValuesFrom"; "intersection1"; "intersection2" |]

(* the univ-bench axioms as facts (a property is a link: a property thing takes no other fact, so an axiom about two
   properties is a thing of its own), and the W3C rules over them (OWL 2 Profiles, section 4.3: cax-sco, scm-sco,
   prp-dom, prp-rng, prp-spo1, prp-inv1, prp-inv2, prp-trp, cls-svf1, cls-int1 over two members) *)
let w3c_ontology db ids =
  let ps = Array.of_list (ok (declare db (Array.to_list (Array.map (fun n -> prop ~many:true n Tlink) w3c_props)))) in
  let q n = let rec go i = if w3c_props.(i) = n then ps.(i) else go (i + 1) in go 0 in
  let ty = ids.ty and pr = ids.pr and cls = ids.cls in
  let ops = ref [] and next = ref 0 in
  let fresh () = decr next; !next in
  let add s p o = ops := Add (s, p, Link o) :: !ops in
  List.iter
    (fun (a, b) -> add (cls a) (q "subClassOf") (cls b))
    [ "AdministrativeStaff", "Employee"; "Article", "Publication"; "AssistantProfessor", "Professor";
      "AssociateProfessor", "Professor"; "Book", "Publication"; "Chair", "Professor"; "ClericalStaff", "AdministrativeStaff";
      "College", "Organization"; "ConferencePaper", "Article"; "Course", "Work"; "Dean", "Professor";
      "Department", "Organization"; "Faculty", "Employee"; "FullProfessor", "Professor"; "GraduateCourse", "Course";
      "GraduateStudent", "Person"; "Institute", "Organization"; "JournalArticle", "Article"; "Lecturer", "Faculty";
      "Manual", "Publication"; "PostDoc", "Faculty"; "Professor", "Faculty"; "Program", "Organization";
      "Research", "Work"; "ResearchAssistant", "Person"; "ResearchGroup", "Organization"; "Software", "Publication";
      "Specification", "Publication"; "SystemsStaff", "AdministrativeStaff"; "TechnicalReport", "Article";
      "UndergraduateStudent", "Student"; "University", "Organization"; "UnofficialPublication", "Publication";
      "VisitingProfessor", "Professor"; "Chair", "Person"; "Employee", "Person"; "Student", "Person";
      "TeachingAssistant", "Person"; "Director", "Person" ];
  let dom p c = add (cls c) (q "domainOf") (pr p) and rng p c = add (cls c) (q "rangeOf") (pr p) in
  dom "advisor" "Person"; rng "advisor" "Professor";
  dom "affiliatedOrganizationOf" "Organization"; rng "affiliatedOrganizationOf" "Organization";
  dom "affiliateOf" "Organization"; rng "affiliateOf" "Person";
  dom "age" "Person";
  dom "degreeFrom" "Person"; rng "degreeFrom" "University";
  dom "doctoralDegreeFrom" "Person"; rng "doctoralDegreeFrom" "University";
  dom "emailAddress" "Person";
  dom "hasAlumnus" "University"; rng "hasAlumnus" "Person";
  dom "listedCourse" "Schedule"; rng "listedCourse" "Course";
  dom "mastersDegreeFrom" "Person"; rng "mastersDegreeFrom" "University";
  dom "member" "Organization"; rng "member" "Person";
  dom "orgPublication" "Organization"; rng "orgPublication" "Publication";
  dom "publicationAuthor" "Publication"; rng "publicationAuthor" "Person";
  dom "publicationResearch" "Publication"; rng "publicationResearch" "Research";
  dom "researchProject" "ResearchGroup"; rng "researchProject" "Research";
  dom "softwareDocumentation" "Software"; rng "softwareDocumentation" "Publication";
  dom "subOrganizationOf" "Organization"; rng "subOrganizationOf" "Organization";
  dom "teacherOf" "Faculty"; rng "teacherOf" "Course";
  dom "teachingAssistantOf" "TeachingAssistant"; rng "teachingAssistantOf" "Course";
  dom "tenured" "Professor";
  dom "undergraduateDegreeFrom" "Person"; rng "undergraduateDegreeFrom" "University";
  let two a pa b pb = let x = fresh () in add x (q pa) (pr a); add x (q pb) (pr b) in
  List.iter (fun (a, b) -> two a "subProperty" b "superProperty")
    [ "doctoralDegreeFrom", "degreeFrom"; "mastersDegreeFrom", "degreeFrom"; "undergraduateDegreeFrom", "degreeFrom";
      "headOf", "worksFor"; "worksFor", "memberOf" ];
  two "member" "inverseA" "memberOf" "inverseB";
  two "hasAlumnus" "inverseA" "degreeFrom" "inverseB";
  (let x = fresh () in add x (q "transitive") (pr "subOrganizationOf"));
  (* C = A and some P D: a restriction r = some P D, and C's two members (or r a subclass of C) *)
  let define c a p d =
    let r = fresh () in
    add r (q "onProperty") (pr p);
    add r (q "someValuesFrom") (cls d);
    match a with
    | Some a -> add (cls c) (q "intersection1") (cls a); ops := Add (cls c, q "intersection2", Link r) :: !ops
    | None -> ops := Add (r, q "subClassOf", Link (cls c)) :: !ops
  in
  define "Chair" (Some "Person") "headOf" "Department";
  define "Dean" None "headOf" "College";
  define "Director" (Some "Person") "headOf" "Program";
  define "Employee" (Some "Person") "worksFor" "Organization";
  define "Student" (Some "Person") "takesCourse" "Course";
  define "TeachingAssistant" (Some "Person") "teachingAssistantOf" "Course";
  ignore (ok (write db (List.rev !ops)));
  let v n = Var n in
  let pa s p o = { e = s; p; v = o } in
  let pv k = prop_var k in
  let x = v 0 and y = v 1 and z = v 2 and c1 = v 3 and c2 = v 4 and c3 = v 5 and p1 = v 6 and p2 = v 7 and a = v 8 in
  (* the variables numbered densely, a property variable among them *)
  let rule name _ where head =
    let used = Array.make 9 false in
    let see (q : pattern) = List.iter (function Var k -> used.(k) <- true | _ -> ()) [ q.e; q.v ]; if q.p < 0 then used.(-1 - q.p) <- true in
    List.iter see where;
    see head;
    let map = Array.make 9 (-1) and n = ref 0 in
    Array.iteri (fun k u -> if u then (map.(k) <- !n; incr n)) used;
    let t = function Var k -> Var map.(k) | t -> t in
    let pat (q : pattern) = { e = t q.e; p = (if q.p < 0 then prop_var map.(-1 - q.p) else q.p); v = t q.v } in
    { name; vars = !n; where = List.map pat where; ranges = []; head = Give (pat head) }
  in
  [ rule "cax-sco" 5 [ pa x ty c1; pa c1 (q "subClassOf") c2 ] (pa x ty c2);
    rule "scm-sco" 6 [ pa c1 (q "subClassOf") c2; pa c2 (q "subClassOf") c3 ] (pa c1 (q "subClassOf") c3);
    rule "prp-dom" 7 [ pa c1 (q "domainOf") p1; pa x (pv 6) y ] (pa x ty c1);
    rule "prp-rng" 7 [ pa c1 (q "rangeOf") p1; pa x (pv 6) y ] (pa y ty c1);
    rule "prp-spo1" 9 [ pa a (q "subProperty") p1; pa a (q "superProperty") p2; pa x (pv 6) y ] (pa x (pv 7) y);
    rule "prp-inv1" 9 [ pa a (q "inverseA") p1; pa a (q "inverseB") p2; pa x (pv 6) y ] (pa y (pv 7) x);
    rule "prp-inv2" 9 [ pa a (q "inverseA") p1; pa a (q "inverseB") p2; pa x (pv 7) y ] (pa y (pv 6) x);
    rule "prp-trp" 9 [ pa a (q "transitive") p1; pa x (pv 6) y; pa y (pv 6) z ] (pa x (pv 6) z);
    rule "cls-svf1" 9 [ pa a (q "someValuesFrom") c1; pa a (q "onProperty") p1; pa x (pv 6) y; pa y ty c1 ] (pa x ty a);
    rule "cls-int1" 6 [ pa c3 (q "intersection1") c1; pa c3 (q "intersection2") c2; pa x ty c1; pa x ty c2 ] (pa x ty c3) ],
  ps

(* the univ-bench axioms in the vocabulary of the OWL library (Cepheus.Owl), its rules being owl.Rl(): the same axioms
   as [w3c_ontology], a description thing a property (its domain, range, superproperties, inverse, transitivity), the
   defined classes as an intersection of two members (the class and a restriction) *)
let owl_ontology db ids (o : Owl.t) =
  let pr = ids.pr and cls = ids.cls in
  let ops = ref [] and next = ref 0 in
  let fresh () = decr next; !next in
  let add s p x = ops := Add (s, p, Link x) :: !ops in
  let descr = Hashtbl.create 32 in
  let d p = match Hashtbl.find_opt descr p with Some t -> t | None -> let t = fresh () in Hashtbl.replace descr p t; add t o.property (pr p); t in
  List.iter
    (fun (a, b) -> add (cls a) o.sub_class_of (cls b))
    [ "AdministrativeStaff", "Employee"; "Article", "Publication"; "AssistantProfessor", "Professor";
      "AssociateProfessor", "Professor"; "Book", "Publication"; "Chair", "Professor"; "ClericalStaff", "AdministrativeStaff";
      "College", "Organization"; "ConferencePaper", "Article"; "Course", "Work"; "Dean", "Professor";
      "Department", "Organization"; "Faculty", "Employee"; "FullProfessor", "Professor"; "GraduateCourse", "Course";
      "GraduateStudent", "Person"; "Institute", "Organization"; "JournalArticle", "Article"; "Lecturer", "Faculty";
      "Manual", "Publication"; "PostDoc", "Faculty"; "Professor", "Faculty"; "Program", "Organization";
      "Research", "Work"; "ResearchAssistant", "Person"; "ResearchGroup", "Organization"; "Software", "Publication";
      "Specification", "Publication"; "SystemsStaff", "AdministrativeStaff"; "TechnicalReport", "Article";
      "UndergraduateStudent", "Student"; "University", "Organization"; "UnofficialPublication", "Publication";
      "VisitingProfessor", "Professor"; "Chair", "Person"; "Employee", "Person"; "Student", "Person";
      "TeachingAssistant", "Person"; "Director", "Person" ];
  let dom p c = add (d p) o.domain (cls c) and rng p c = add (d p) o.range (cls c) in
  dom "advisor" "Person"; rng "advisor" "Professor";
  dom "affiliatedOrganizationOf" "Organization"; rng "affiliatedOrganizationOf" "Organization";
  dom "affiliateOf" "Organization"; rng "affiliateOf" "Person";
  dom "age" "Person";
  dom "degreeFrom" "Person"; rng "degreeFrom" "University";
  dom "doctoralDegreeFrom" "Person"; rng "doctoralDegreeFrom" "University";
  dom "emailAddress" "Person";
  dom "hasAlumnus" "University"; rng "hasAlumnus" "Person";
  dom "listedCourse" "Schedule"; rng "listedCourse" "Course";
  dom "mastersDegreeFrom" "Person"; rng "mastersDegreeFrom" "University";
  dom "member" "Organization"; rng "member" "Person";
  dom "orgPublication" "Organization"; rng "orgPublication" "Publication";
  dom "publicationAuthor" "Publication"; rng "publicationAuthor" "Person";
  dom "publicationResearch" "Publication"; rng "publicationResearch" "Research";
  dom "researchProject" "ResearchGroup"; rng "researchProject" "Research";
  dom "softwareDocumentation" "Software"; rng "softwareDocumentation" "Publication";
  dom "subOrganizationOf" "Organization"; rng "subOrganizationOf" "Organization";
  dom "teacherOf" "Faculty"; rng "teacherOf" "Course";
  dom "teachingAssistantOf" "TeachingAssistant"; rng "teachingAssistantOf" "Course";
  dom "tenured" "Professor";
  dom "undergraduateDegreeFrom" "Person"; rng "undergraduateDegreeFrom" "University";
  List.iter (fun (a, b) -> add (d a) o.sub_property_of (pr b))
    [ "doctoralDegreeFrom", "degreeFrom"; "mastersDegreeFrom", "degreeFrom"; "undergraduateDegreeFrom", "degreeFrom";
      "headOf", "worksFor"; "worksFor", "memberOf" ];
  add (d "member") o.inverse_of (pr "memberOf");
  add (d "hasAlumnus") o.inverse_of (pr "degreeFrom");
  ops := Add (d "subOrganizationOf", o.transitive, Bool true) :: !ops;
  let define c a p dc =
    let r = fresh () in
    add r o.on_property (pr p);
    add r o.some_values_from (cls dc);
    match a with
    | Some a -> add (cls c) o.intersection_of (cls a); add (cls c) o.intersection_of r
    | None -> add r o.sub_class_of (cls c)
  in
  define "Chair" (Some "Person") "headOf" "Department";
  define "Dean" None "headOf" "College";
  define "Director" (Some "Person") "headOf" "Program";
  define "Employee" (Some "Person") "worksFor" "Organization";
  define "Student" (Some "Person") "takesCourse" "Course";
  define "TeachingAssistant" (Some "Person") "teachingAssistantOf" "Course";
  ignore (ok (write db (List.rev !ops)))

(* DROP=1: the database directory a run made is removed when it ends (a series of loads keeps the disk small); only a
   directory named w-* or o-* under a folder named owl-t, the job's own *)
let drop_db dir =
  if Sys.getenv_opt "DROP" = Some "1" && Filename.basename (Filename.dirname dir) = "owl-t"
     && (let b = Filename.basename dir in String.length b > 2 && (String.sub b 0 2 = "w-" || String.sub b 0 2 = "o-"))
  then begin
    let rec rm p =
      if Sys.is_directory p then (Array.iter (fun f -> rm (Filename.concat p f)) (Sys.readdir p); Sys.rmdir p) else Sys.remove p
    in
    if Sys.file_exists dir then rm dir
  end

(* the derived facts of the data, not of the ontology's things: what the two forms of the rules must agree on *)
let data_derived (v : view) ~from_e ~skip =
  let d = ref 0 in
  for e = from_e to v.next_e - 1 do
    Store.iter_facts v e (fun p w -> if Store.state v e p w = 2 && not (skip p w) then incr d)
  done;
  !d

let w3c ?(form = "w3c") n path dir =
  Reason.derivations := 0;
  let dir = if dir = "-" then None else Some dir in
  let db = match dir with None -> fork empty | Some d -> ok (open_ d) in
  let ids = setup db in
  let ids, ps, on_property =
    if form = "owl" then begin
      (* OWL 2 RL whole (Cepheus.Owl): its vocabulary, its rules, the ontology in it; the data's types are owl/Type *)
      let o = ok (Owl.setup db) in
      ignore (ok (define db (Owl.rl o)));
      let ids = { ids with ty = o.type_ } in
      owl_ontology db ids o;
      let ps = Array.of_list (List.map (fun (n, _, _, _) -> Option.get (property (view db) n)) Owl.vocabulary) in
      ids, ps, o.on_property
    end
    else begin
      let rules, ps = w3c_ontology db ids in
      ignore (ok (define db rules));
      ids, ps, ps.(8)
    end
  in
  (* the restrictions are things of the ontology: a fact [x type r] is the W3C form's own step *)
  let restriction = Hashtbl.create 8 in
  Store.iter_prop (view db) on_property (fun e _ -> Hashtbl.replace restriction e ());
  let g = { st = (7 * 0x1E3779B97F4A7C15) lor 1; lit = 0 } in
  let groups = ref 0 in
  Reason.seconds := 0.;
  Reason.bulk_index_seconds := 0.;
  Reason.spec_groups := 0;
  Reason.gen_groups := 0;
  let t =
    if path <> "bulk" then begin
      let t0 = now () in
      let trace = Sys.getenv_opt "TRACE" <> None in
      for u = 0 to n - 1 do
        university ids g u (fun ops ->
            incr groups;
            let g0 = !Reason.gen_groups in
            ignore (ok (write db ops));
            if trace && !Reason.gen_groups > g0 then Printf.printf "group %d (%d ops) as written\n%!" !groups (List.length ops))
      done;
      now () -. t0
    end
    else begin
      let all = ref [] and off = ref 0 in
      for u = 0 to n - 1 do
        university ids g u (fun ops ->
            let low = ref 0 in
            let t x = if x < 0 then (low := min !low x; x - !off) else x in
            List.iter (function Add (e, p, v) -> all := Add (t e, p, (match v with Link l -> Link (t l) | v -> v)) :: !all | o -> all := o :: !all) ops;
            off := !off - !low)
      done;
      let ops = List.rev !all in
      Gc.compact ();
      groups := 1;
      let t0 = now () in
      ignore (ok (write db ops));
      now () -. t0
    end
  in
  let v = view db in
  let all, d = count_derived v in
  let dd = data_derived v ~from_e:Schema.first_thing ~skip:(fun p w -> (p <> ids.ty && Array.mem p ps) || (p = ids.ty && Hashtbl.mem restriction w)) in
  let r = !Reason.seconds and ix = !Reason.bulk_index_seconds in
  Printf.printf "%s %d %s %s: %.3f s, %d groups (%d unfolded, %d as written), %d facts (%d derived, %d of the data without the restrictions' types), %d derivations; reasoning %.3f s, %.3f M derived/s; of which the working set's build %.3f s\n%!" form n
    path (if dir = None then "memory" else "disk") t !groups !Reason.spec_groups !Reason.gen_groups all d dd !Reason.derivations r
    (if r > 0. then float_of_int d /. r /. 1e6 else 0.) ix;
  close db;
  Option.iter drop_db dir

(* ---- OWL 2 RL defined on a database that holds its data already: the OCaml side of the Cesia package's measure ---- *)

(* N universities and the univ-bench ontology in OWL 2 RL's vocabulary, in DIR, made empty first: no rule *)
let owl_prep n dir =
  if Sys.file_exists dir then failwith (dir ^ " exists");
  let db = ok (open_ dir) in
  let ids = setup db in
  let o = ok (Owl.setup db) in
  let ids = { ids with ty = o.type_ } in
  owl_ontology db ids o;
  let g = { st = (7 * 0x1E3779B97F4A7C15) lor 1; lit = 0 } in
  for u = 0 to n - 1 do university ids g u (fun ops -> ignore (ok (write db ops))) done;
  let all, d = count_derived (view db) in
  Printf.printf "owlprep %d: %d facts (%d derived)\n%!" n all d;
  close db

(* OWL 2 RL defined on the database DIR (disk: in it, the change of the rules on the disk; fork: in a fork of it, in
   memory): the time of define, and the facts of owl/Type after *)
let owl_define dir mode =
  let db = ok (open_ dir) in
  let t = if mode = "fork" then fork (view db) else db in
  let t0 = now () in
  let o = ok (Owl.setup t) in
  ignore (ok (define t (Owl.rl o)));
  let s = now () -. t0 in
  let types = Store.count_prop (view t) o.type_ in
  Printf.printf "owldefine %s: %.3f s, %d facts of owl/Type\n%!" mode s types;
  close db

(* ---- UOBM-like: equality, by rewriting (rew) or axiomatised (ax) ----
   LUBM-shaped data with the univ-bench ontology in OWL 2 RL's vocabulary, where a quarter of the people are recorded
   2 to 4 times (a record a department that knows them: the same e-mail, part of their facts each), and the e-mail is
   inverse functional (prp-ifp): each person's records are one thing. UOBM (Ma et al., ESWC 2006) adds such equalities to
   LUBM; Motik, Nenov, Piro, Horrocks (AAAI 2015) measure rewriting against the axiomatised equality on it. rew: OWL 2 RL
   whole (the classes and the rewriting); ax: the same rules, their equalities given as owl/SameAs facts, with eq-sym,
   eq-trans, and eq-rep-s and eq-rep-o written once for each property (eq-ref left out, which only makes ax larger).
   Both are read through their classes at the end (each fact's things as their class's least member): the digests
   must agree. *)
let uobm n mode =
  Reason.derivations := 0;
  let db = fork empty in
  let ids = setup db in
  let o = ok (Owl.setup db) in
  let rules =
    if mode = "rew" || mode = "plain" then Owl.rl o
    else begin
      let same_to_fact (r : rule) =
        match r.head with
        | Give h when h.p = Schema.p_same -> if r.name = "owl/eq" then None else Some { r with head = Give { h with p = o.same_as } }
        | _ -> Some r
      in
      let base = List.filter_map same_to_fact (Owl.rl o) in
      let x = Var 0 and y = Var 1 and z = Var 2 in
      let v = view db in
      (* the data's properties and owl/Type: the things made equal are people (the ontology's things never are) *)
      let props = o.type_ :: Array.to_list (Array.map ids.pr props) in
      let link p = match describe v p with Some d -> d.typ = Tlink | None -> false in
      base
      @ [ { name = "ax/eq-sym"; vars = 2; where = [ { e = x; p = o.same_as; v = y } ]; ranges = []; head = Give { e = y; p = o.same_as; v = x } };
          { name = "ax/eq-trans"; vars = 3; where = [ { e = x; p = o.same_as; v = y }; { e = y; p = o.same_as; v = z } ]; ranges = []; head = Give { e = x; p = o.same_as; v = z } } ]
      @ List.map (fun p -> { name = Printf.sprintf "ax/eq-rep-s-%d" p; vars = 3; where = [ { e = x; p = o.same_as; v = y }; { e = x; p; v = z } ]; ranges = []; head = Give { e = y; p; v = z } }) props
      @ List.filter_map (fun p -> if link p then Some { name = Printf.sprintf "ax/eq-rep-o-%d" p; vars = 3; where = [ { e = x; p = o.same_as; v = y }; { e = z; p; v = x } ]; ranges = []; head = Give { e = z; p; v = y } } else None) props
    end
  in
  ignore (ok (define db rules));
  let ids = { ids with ty = o.type_ } in
  owl_ontology db ids o;
  (* the e-mail, inverse functional (not in mode plain: the same data, nothing made the same) *)
  if mode <> "plain" then ignore (ok (write db [ Add (-1, o.property, Link (ids.pr "emailAddress")); Add (-1, o.inverse_functional, Bool true) ]));
  let g = { st = (7 * 0x1E3779B97F4A7C15) lor 1; lit = 0 } in
  let email = ids.pr "emailAddress" in
  let groups = ref 0 and records = ref 0 in
  Reason.seconds := 0.;
  let t0 = now () in
  for u = 0 to n - 1 do
    university ids g u (fun ops ->
        (* the people of this group (things with an e-mail), their facts; a quarter recorded again 1 to 3 times *)
        let facts = Hashtbl.create 1024 in
        List.iter (function Add (e, p, x) -> Hashtbl.add facts e (p, x) | _ -> ()) ops;
        let next = ref (List.fold_left (fun m -> function Add (e, _, x) -> min m (min e (match x with Link l -> l | _ -> 0)) | _ -> m) 0 ops) in
        let extra = ref [] in
        Hashtbl.iter
          (fun e (p, x) ->
            if p = email && rand g 1 4 = 1 then
              for _ = 1 to rand g 1 3 do
                decr next;
                incr records;
                let d = !next in
                extra := Add (d, email, x) :: !extra;
                List.iter (fun (q, y) -> if q <> email && rand g 0 1 = 1 then extra := Add (d, q, y) :: !extra) (Hashtbl.find_all facts e)
              done)
          facts;
        incr groups;
        ignore (ok (write db (ops @ List.rev !extra))))
  done;
  let t = now () -. t0 in
  let v = view db in
  (* the classes: rew's cepheus/same, ax's owl/SameAs closure; a fact read through them, its things as the least member *)
  let cls = Hashtbl.create 1024 in
  let least x = match Hashtbl.find_opt cls x with Some m -> m | None -> x in
  if mode = "rew" then begin
    let reps = Hashtbl.create 1024 in
    Store.iter_prop v Schema.p_same (fun e r -> Hashtbl.replace reps r (min e (Option.value (Hashtbl.find_opt reps r) ~default:r)));
    Store.iter_prop v Schema.p_same (fun e r -> Hashtbl.replace cls e (Hashtbl.find reps r));
    Hashtbl.iter (fun r m -> Hashtbl.replace cls r m) reps
  end
  else Store.iter_prop v o.same_as (fun e w -> if w < least e then Hashtbl.replace cls e w);
  let seen = Hashtbl.create 100_000 and h = ref 0 and all = ref 0 and derived = ref 0 and nsame = ref 0 in
  for e = Schema.first_thing to v.next_e - 1 do
    Store.iter_facts v e (fun p w ->
        incr all;
        if Store.state v e p w = 2 then incr derived;
        if p = o.same_as || p = Schema.p_same then incr nsame
        else begin
          (* a value as its words would differ between the two (their dictionaries' order): as a value *)
          let f = match describe v p with
            | Some { typ = Tlink; _ } -> least e, p, string_of_int (least w)
            | Some d -> least e, p, Value.to_string (Store.value v d.typ w)
            | None -> least e, p, "?" in
          if not (Hashtbl.mem seen f) then (Hashtbl.replace seen f (); h := !h + Hashtbl.hash f)
        end)
  done;
  (match Sys.getenv_opt "DUMP" with
   | Some f ->
     let oc = open_out f in
     List.iter (fun (e, p, w) -> Printf.fprintf oc "%d %d %s\n" e p w) (List.sort compare (Hashtbl.fold (fun k () l -> k :: l) seen []));
     close_out oc
   | None -> ());
  let r = !Reason.seconds in
  Printf.printf "uobm %d %s: %.3f s, %d groups, %d records more, %d facts (%d derived, %d of equality), %d derivations; reasoning %.3f s (merges %.3f s; groups unfolded %d, as written %d, again %d); read through the classes: %d facts, digest %x\n%!"
    n mode t !groups !records !all !derived !nsame !Reason.derivations r !Reason.merge_seconds !Reason.spec_groups !Reason.gen_groups !Reason.respecs (Hashtbl.length seen) !h

(* ---- an equality storm: one thing with n values of a functional property, so n things become one; rewriting must
   keep it linear (n - 1 facts of cepheus/same) where the axiomatised equality holds n^2 facts ---- *)
let storm ?(mode = "rew") n =
  let db = fork empty in
  let o = ok (Owl.setup db) in
  let[@warning "-8"] [ k; tx ] = ok (declare db [ prop ~many:true "t/k" Tlink; prop ~many:true "t/text" Ttext ]) in
  (* ax: the equality axiomatised, as in [uobm] (the equalities as owl/SameAs facts, eq-sym, eq-trans, eq-rep-s and
     eq-rep-o for the two properties) *)
  let rules =
    if mode = "rew" then Owl.rl o
    else
      let x = Var 0 and y = Var 1 and z = Var 2 in
      List.filter_map (fun (r : rule) -> match r.head with Give h when h.p = Schema.p_same -> if r.name = "owl/eq" then None else Some { r with head = Give { h with p = o.same_as } } | _ -> Some r) (Owl.rl o)
      @ [ { name = "ax/eq-sym"; vars = 2; where = [ { e = x; p = o.same_as; v = y } ]; ranges = []; head = Give { e = y; p = o.same_as; v = x } };
          { name = "ax/eq-trans"; vars = 3; where = [ { e = x; p = o.same_as; v = y }; { e = y; p = o.same_as; v = z } ]; ranges = []; head = Give { e = x; p = o.same_as; v = z } } ]
      @ List.map (fun p -> { name = Printf.sprintf "ax/eq-rep-s-%d" p; vars = 3; where = [ { e = x; p = o.same_as; v = y }; { e = x; p; v = z } ]; ranges = []; head = Give { e = y; p; v = z } }) [ k; tx ]
      @ [ { name = "ax/eq-rep-o"; vars = 3; where = [ { e = x; p = o.same_as; v = y }; { e = z; p = k; v = x } ]; ranges = []; head = Give { e = z; p = k; v = y } } ]
  in
  ignore (ok (define db rules));
  ignore (ok (write db [ Add (-1, o.property, Link k); Add (-1, o.functional, Bool true) ]));
  let r = ok (write db (Add (-1, tx, Text "x") :: List.init n (fun i -> Add (-(i + 2), tx, Text (string_of_int i))))) in
  (* the receipt's things read once into a table (a walk of the list each would be n^2) *)
  let ids = Hashtbl.create (2 * n) in
  List.iter (fun (t, id) -> Hashtbl.replace ids t id) r.things;
  let thing _ t = Hashtbl.find ids t in
  let x = thing r (-1) in
  Reason.seconds := 0.;
  Reason.merge_seconds := 0.;
  Reason.derivations := 0;
  let t0 = now () in
  ignore (ok (write db (List.init n (fun i -> Add (x, k, Link (thing r (-(i + 2))))))));
  let t = now () -. t0 in
  let v = view db in
  Printf.printf "storm %d %s: %.3f s (reasoning %.3f s, merges %.3f s), %d derivations, %d facts (%d of cepheus/same, %d of owl/SameAs)\n%!" n mode t !Reason.seconds
    !Reason.merge_seconds !Reason.derivations (Store.facts v) (Store.count_prop v Schema.p_same) (Store.count_prop v o.same_as)

(* ---- Not and aggregates (the reasoner's step 4) ----
   N invoices of K lines each (an amount, a day), a group an invoice, then R rounds on them in turn: a line added (of
   the earliest day), that line retracted (Min read again over the K lines), a payment added, then retracted. MODE agg:
   the rules total = sum of the amounts, count of the lines, first and last day (Min, Max), unpaid (an invoice with no
   payment, a Not); plain: the same bodies as rules that give one fact an answer (the delta plans alone: what agg costs
   beyond them) and a rule over the payment instead of its absence; none: no rule. Per group, in microseconds. *)
let notagg_bench n k reps mode =
  let db = fork empty in
  let line, amount, day, total, count, first, last, paid, label, seen, seen_day =
    match declare db [ prop ~many:true "line" Tlink; prop "amount" Tint; prop "day" Tdate; prop "total" Tint; prop "count" Tint;
                       prop "first" Tdate; prop "last" Tdate; prop ~many:true "paid" Tdate; prop ~many:true "label" Ttext;
                       prop ~many:true "seen" Tint; prop ~many:true "seen_day" Tdate ] with
    | Ok [ a; b; c; d; e; f; g; h; i; j; l ] -> a, b, c, d, e, f, g, h, i, j, l
    | _ -> assert false
  in
  let i = Var 0 and l = Var 1 and x = Var 2 in
  let body p = [ { e = i; p = line; v = l }; { e = l; p; v = x } ] in
  let r name vars where head = { name; vars; where; ranges = []; head = Give head } in
  let rules =
    match mode with
    | "agg" ->
      [ r "total-of" 3 (body amount) { e = i; p = aggregate `Sum total; v = x };
        r "count-of" 2 [ { e = i; p = line; v = l } ] { e = i; p = aggregate `Count count; v = Val (Int 0) };
        r "first-of" 3 (body day) { e = i; p = aggregate `Min first; v = x };
        r "last-of" 3 (body day) { e = i; p = aggregate `Max last; v = x };
        r "unpaid" 3 [ { e = i; p = line; v = l }; { e = i; p = absent 0 paid; v = x } ] { e = i; p = label; v = Val (Text "unpaid") } ]
    | "plain" ->
      [ r "total-of" 3 (body amount) { e = i; p = seen; v = x };
        r "count-of" 2 [ { e = i; p = line; v = l } ] { e = i; p = label; v = Val (Text "has lines") };
        r "first-of" 3 (body day) { e = i; p = seen_day; v = x };
        r "last-of" 3 (body day) { e = i; p = seen_day; v = x };
        r "paid-of" 3 [ { e = i; p = line; v = l }; { e = i; p = paid; v = x } ] { e = i; p = label; v = Val (Text "paid") } ]
    | _ -> []
  in
  ignore (first, last);
  if rules <> [] then ignore (ok (define db rules));
  let invs =
    Array.init n (fun u ->
        let ops = List.concat (List.init k (fun j -> [ Add (-(j + 2), amount, Int (100 + j)); Add (-(j + 2), day, Date (1000 + (u + j) mod 97)); Add (-1, line, Link (-(j + 2))) ])) in
        thing (ok (write db ops)) (-1))
  in
  let f = fork (view db) in
  let t op = let t0 = now () in ignore (ok (write f op)); (now () -. t0) *. 1e6 in
  let add = Array.make reps 0. and del = Array.make reps 0. and pay = Array.make reps 0. and unpay = Array.make reps 0. in
  for q = 0 to reps - 1 do
    let inv = invs.(q mod n) in
    let t0 = now () in
    let rr = ok (write f [ Add (-1, amount, Int 7); Add (-1, day, Date 1); Add (inv, line, Link (-1)) ]) in
    add.(q) <- (now () -. t0) *. 1e6;
    let ln = thing rr (-1) in
    del.(q) <- t [ Retract (inv, line, Link ln) ];
    pay.(q) <- t [ Add (inv, paid, Date 5) ];
    unpay.(q) <- t [ Retract (inv, paid, Date 5) ]
  done;
  Printf.printf "notagg %d %d %s: add a line median %.2f us p90 %.2f; retract it median %.2f us p90 %.2f; pay median %.2f us p90 %.2f; unpay median %.2f us p90 %.2f\n%!"
    n k mode (pct add 0.5) (pct add 0.9) (pct del 0.5) (pct del 0.9) (pct pay 0.5) (pct pay 0.9) (pct unpay 0.5) (pct unpay 0.9)

(* the univ-bench rules defined over n universities loaded without them, in memory: one change, inline (a fork) *)
let define_bench n =
  let db, ids, _, t, _ = build n false in
  Gc.compact ();
  let all0, _ = count_derived (view db) in
  Reason.seconds := 0.;
  let t0 = now () in
  ignore (ok (define db (ontology_rules ids)));
  let dt = now () -. t0 in
  let all, d = count_derived (view db) in
  Printf.printf "define %d: loaded in %.2f s, %d facts; the 94 rules defined in %.3f s (reasoning %.3f s): %d derived, %.2f M derived/s, %d facts after\n%!"
    n t all0 dt !Reason.seconds d (float d /. dt /. 1e6) all

(* Durable writes of graduate students by [clients] threads for [secs] seconds into a copy of base (n universities
   without rules); [at] seconds in, with [mode] = with, the univ-bench rules defined (the background path). Prints the
   change's times and the groups confirmed by each 10 ms, for the windows' throughputs (bench/change.sh). *)
let change_bench n clients secs at mode dir =
  (* kind one: the base has the 94 rules, the change adds one (every Person is also a Schedule, a class the data and the
     rules leave empty, as the design's Person ⊑ Agent); kind all: the base has none, the change defines the 94 *)
  let kind = match Sys.getenv_opt "CHANGE" with Some k -> k | None -> "one" in
  let dir = dir ^ "-" ^ kind in
  let base = dir ^ "-base" in
  if not (Sys.file_exists base) then begin
    let db, _, _, t, _ = build ~dir:base n (kind = "one") in
    ok (snapshot db);
    close db;
    Printf.printf "base: %d universities in %.1f s\n%!" n t
  end;
  let run = dir ^ "-run" in
  ignore (Sys.command (Printf.sprintf "rm -rf %s && cp -a %s %s" (Filename.quote run) (Filename.quote base) (Filename.quote run)));
  let db = ok (open_ run) in
  let ids = ids_of db in
  let v = view db in
  let first p c = List.hd (things v p (Link c)) in
  let dept = first ids.ty (ids.cls "Department") in
  let course = first ids.ty (ids.cls "GraduateCourse") and prof = first ids.ty (ids.cls "FullProfessor") in
  let bins = int_of_float (secs *. 100.) + 1 in
  let counts = Array.init clients (fun _ -> Array.make bins 0) in
  let t0 = now () and stop = Atomic.make false in
  let worker k () =
    let g = { st = ((k + 1) * 0x1E3779B97F4A7C15) lor 1; lit = 1_000_000 * (k + 1) } in
    while not (Atomic.get stop) do
      ignore (ok (write db (student ids g dept course prof)));
      let b = int_of_float ((now () -. t0) *. 100.) in
      if b < bins then counts.(k).(b) <- counts.(k).(b) + 1
    done
  in
  let ts = List.init clients (fun k -> Thread.create (worker k) ()) in
  Thread.delay at;
  Reason.seconds := 0.;
  let c0 = now () in
  if mode = "with" then
    ignore
      (ok
         (define db
            (if kind = "one" then
               [ { name = "person-work"; vars = 1; where = [ { e = Var 0; p = ids.ty; v = Thing (ids.cls "Person") } ]; ranges = [];
                   head = Give { e = Var 0; p = ids.ty; v = Thing (ids.cls "Schedule") } } ]
             else ontology_rules ids)));
  let c1 = now () in
  (* the change's derived facts, by the count of the class it fills (kind one), or all (and those of the few students
     written since its install) *)
  let derived =
    if mode <> "with" then 0
    else if kind = "one" then List.length (things (view db) ids.ty (Link (ids.cls "Schedule")))
    else snd (count_derived (view db))
  in
  Thread.delay (Float.max 0. (secs -. (c1 -. t0)));
  Atomic.set stop true;
  List.iter Thread.join ts;
  let total = Array.init bins (fun b -> Array.fold_left (fun s a -> s + a.(b)) 0 counts) in
  let p50 h = float (Histogram.max h) in
  Printf.printf "change %s: start %.3f s, end %.3f s, build %.3f s, run %.3f s, background %.3f s, install %.3f s\n" mode (c0 -. t0) (c1 -. t0)
    (p50 Engine.build_us /. 1e6) (p50 Engine.run_us /. 1e6) (p50 Engine.change_us /. 1e6) (p50 Engine.install_us /. 1e6);
  print_string "bins";
  Array.iter (fun c -> Printf.printf " %d" c) total;
  print_newline ();
  if mode = "with" then Printf.printf "facts derived %d\n%!" derived;
  close db;
  (* KEEP: the database stays (an older binary reads it back: bench digest) *)
  if Sys.getenv_opt "KEEP" = None then ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote run)))

(* reads: the cost of [get] and [values] by id (the reads a question's constant and a program's Get make), on
   LUBM-1 with its rules, in memory: 2,000,000 of each on things drawn at random, the time a read *)
let reads_bench () =
  let db, ids, _, _, _ = build 1 true in
  let v = view db in
  let lo = Schema.first_thing and hi = v.next_e in
  let g = { st = (13 * 0x1E3779B97F4A7C15) lor 1; lit = 0 } in
  let xs = Array.init 2_000_000 (fun _ -> rand g lo (hi - 1)) in
  let s = ref 0 in
  let t0 = now () in
  Array.iter (fun x -> s := !s + List.length (get v x)) xs;
  let t1 = now () in
  Array.iter (fun x -> s := !s + List.length (values v x ids.ty)) xs;
  let t2 = now () in
  Printf.printf "reads: get %.1f ns, values %.1f ns (%d)\n%!" ((t1 -. t0) *. 1e9 /. 2e6) ((t2 -. t1) *. 1e9 /. 2e6) !s

let () =
  (match Sys.getenv_opt "DOMAINS" with Some d -> Bulk.domains := int_of_string d | None -> ());
  match Array.to_list Sys.argv |> List.tl with
  | [ "digest"; dir ] ->
    (* a database opened and read whole: its facts, derived ones, and the digest of every fact and flag *)
    let db = ok (open_ dir) in
    let all, d = count_derived (view db) in
    Printf.printf "digest %s: %d facts (%d derived), digest %x\n" dir all d !digest;
    close db
  | [ "define"; n ] -> define_bench (int_of_string n)
  | [ "reads" ] -> reads_bench ()
  | [ "change"; n; c; secs; at; mode; dir ] -> change_bench (int_of_string n) (int_of_string c) (float_of_string secs) (float_of_string at) mode dir
  | [ "mat"; n; mode; path; dir ] -> mat (int_of_string n) mode path dir
  | [ "student"; n; r; dir ] -> student_bench dir (int_of_string n) (int_of_string r)
  | [ "why"; n; r; dir ] -> why_bench dir (int_of_string n) (int_of_string r)
  | [ "apply"; n ] -> apply_bench (int_of_string n)
  | [ "closure"; kind; form; dir ] -> closure_bench kind form dir
  | [ "closure-del"; kind; form; dir; how ] -> closure_del kind form dir how
  | [ "w3c"; n; path; dir ] -> w3c (int_of_string n) path dir
  | [ "owl"; n; path; dir ] -> w3c ~form:"owl" (int_of_string n) path dir
  | [ "owlprep"; n; dir ] -> owl_prep (int_of_string n) dir
  | [ "owldefine"; dir; mode ] -> owl_define dir mode
  | [ "uobm"; n; mode ] -> uobm (int_of_string n) mode
  | [ "storm"; n ] -> storm (int_of_string n)
  | [ "storm"; n; mode ] -> storm ~mode (int_of_string n)
  | [ "notagg"; n; k; r; mode ] -> notagg_bench (int_of_string n) (int_of_string k) (int_of_string r) mode
  | _ -> prerr_endline "usage: reason.exe mat N rules|none groups|bulk DIR|- | student N R DIR | why N R DIR | apply N"; exit 2
