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
   reason.exe apply N               the cost of putting a derived fact into the view (Store.set), alone *)

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
let build ?(bulk = false) ?dir n rules =
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

let count_derived (v : view) =
  let d = ref 0 and all = ref 0 in
  for e = Schema.first_thing to v.next_e - 1 do
    Store.iter_facts v e (fun p w -> incr all; if Store.state v e p w = 2 then incr d)
  done;
  !all, !d

let pct a q = let a = Array.copy a in Array.sort compare a; a.(min (Array.length a - 1) (int_of_float (q *. float_of_int (Array.length a))))

let mat n mode path dir =
  let rules = mode = "rules" in
  Reason.derivations := 0;
  let dir = if dir = "-" then None else Some dir in
  let db, _, _, t, groups = build ~bulk:(path = "bulk") ?dir n rules in
  let all, d = count_derived (view db) in
  let r = !Reason.seconds in
  Printf.printf "mat %d %s %s %s: %.3f s, %d groups, %d facts (%d derived), %d derivations; reasoning %.3f s, %.3f M derived/s\n%!" n
    mode path (if dir = None then "memory" else "disk") t groups all d !Reason.derivations r
    (if r > 0. then float_of_int d /. r /. 1e6 else 0.);
  close db

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

let () =
  match Array.to_list Sys.argv |> List.tl with
  | [ "mat"; n; mode; path; dir ] -> mat (int_of_string n) mode path dir
  | [ "student"; n; r; dir ] -> student_bench dir (int_of_string n) (int_of_string r)
  | [ "why"; n; r; dir ] -> why_bench dir (int_of_string n) (int_of_string r)
  | [ "apply"; n ] -> apply_bench (int_of_string n)
  | _ -> prerr_endline "usage: reason.exe mat N rules|none groups|bulk DIR|- | student N R DIR | why N R DIR | apply N"; exit 2
