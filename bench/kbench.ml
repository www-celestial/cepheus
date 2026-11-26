(* Pages of a kind by its things' ids (keyset pagination), beside PostgreSQL's keyset query (bench/pg/pg.sh keyset). A
   kind of N things: item/name (a text), item/tenant (a link to one of 10 tenants, the k-th item's the (k mod 10)-th)
   and item/n (an int), in one run (merged). A page of 50, asked as Limit 51 (the page and the next page's cursor, as
   Centauri's admin asks), sorted by the thing ascending and descending: the first page, and a deep one (After the
   thing at the middle); then the things of one tenant, likewise. Every page is checked against the ids it must give.
   RUNS runs (11) of a loop of calls each: the median time of a call, its 95 % interval (Stats).

     kbench.exe load DIR N     the kind of N things through the writer, in groups of 10,000 things, then a snapshot
     kbench.exe run DIR        the pages; CEPHEUS_DOMAINS=d on d domains at most
     kbench.exe fork N         the same pages on a fork of N items filled in memory (every fact in its delta)
     kbench.exe mixed DIR N    DIR's pages on a fork of its view whose delta holds N things of another kind, made after
                               every item, and one item renamed (a change of the items' property in the delta)
     kbench.exe csv DIR OUT    the items as PostgreSQL's COPY reads them (id,name,tenant,n), with Cepheus's ids, and
                               the cursors of the deep pages (OUT.cursors: the middle item, the middle item of tenant 3,
                               tenant 3's id) *)

open Cepheus

let ok = function Ok r -> r | Error e -> failwith (message e)
let runs = match Sys.getenv_opt "RUNS" with Some r -> int_of_string r | None -> 11
let per_group = 10_000
let tenants = 10

let measure name n f =
  let per = Array.init runs (fun _ -> let t = Unix.gettimeofday () in for i = 0 to n - 1 do f i done; (Unix.gettimeofday () -. t) /. float n) in
  Stats.print name per

let props = [ prop "item/name" Ttext; prop "item/tenant" Tlink; prop "item/n" Tint; prop "tenant/name" Ttext ]

let fill db n =
  let[@warning "-8"] [ name; tenant; num; tname ] = ok (declare db props) in
  let r = ok (write db (List.init tenants (fun k -> Resolve.Add (-1 - k, tname, Text (Printf.sprintf "tenant %d" k))))) in
  let tid = Array.init tenants (fun k -> thing r (-1 - k)) in
  let t0 = Unix.gettimeofday () in
  let k = ref 0 in
  while !k < n do
    let m = min per_group (n - !k) in
    let ops =
      List.concat
        (List.init m (fun j ->
             let i = !k + j and t = -1 - j in
             [ Resolve.Add (t, name, Text (Printf.sprintf "item %d" i)); Add (t, tenant, Link tid.(i mod tenants)); Add (t, num, Int (i * 7919 mod 1_000_003)) ]))
    in
    ignore (ok (write db ops));
    k := !k + m
  done;
  Unix.gettimeofday () -. t0

let load dir n =
  let db = ok (open_ dir) in
  let t = fill db n in
  let t1 = Unix.gettimeofday () in
  ok (snapshot db);
  close db;
  Printf.printf "loaded %d items (%d facts) in %.1f s, snapshot %.1f s\n%!" n (3 * n) t (Unix.gettimeofday () -. t1)

let schema v = let p s = Option.get (property v s) in p "item/name", p "item/tenant", p "item/n", p "tenant/name"

(* every item's id, ascending, and tenant 3's *)
let ids v =
  let name, tenant, _, tname = schema v in
  let all = List.map (fun r -> match r.(0) with Value.Link e -> e | _ -> assert false) (ok (find v { Query.vars = 2; ranges = []; where = [ { e = Var 0; p = name; v = Var 1 } ] })) in
  let t3 = match things v tname (Text "tenant 3") with [ t ] -> t | _ -> failwith "tenant 3" in
  let of3 = List.map (fun r -> match r.(0) with Value.Link e -> e | _ -> assert false) (ok (find v { Query.vars = 1; ranges = []; where = [ { e = Var 0; p = tenant; v = Val (Link t3) } ] })) in
  let sorted l = let a = Array.of_list l in Array.sort compare a; a in
  sorted all, sorted of3, t3

let pages v =
  Option.iter (fun d -> Query.domains := int_of_string d) (Sys.getenv_opt "CEPHEUS_DOMAINS");
  let name, tenant, _, _ = schema v in
  let all, of3, t3 = ids v in
  let n = Array.length all and n3 = Array.length of3 in
  Printf.printf "%d items, %d of tenant 3, %d runs a measure\n%!" n n3 runs;
  let by_name = Question.Pattern { e = Var 0; p = name; v = Var 1 } in
  let of_tenant = Question.Pattern { e = Var 0; p = tenant; v = Val (Link t3) } in
  (* the admin's question: the things of the kind by their ids, Give {Id: t} *)
  let page items vars desc after = { Question.vars; items; give = [| 0 |]; sort = [ { Question.col = 0; desc } ]; limit = 51; after = Option.map (fun e -> [| Value.Link e |]) after } in
  (* the ids a page must give: the 51 after the cursor, in the order *)
  let want (a : int array) desc after =
    let n = Array.length a in
    let from = match after with None -> if desc then n - 1 else 0 | Some e -> let i = ref 0 in while a.(!i) <> e do incr i done; if desc then !i - 1 else !i + 1 in
    List.filter_map (fun k -> let i = if desc then from - k else from + k in if i >= 0 && i < n then Some a.(i) else None) (List.init 51 Fun.id)
  in
  List.iter
    (fun (what, items, vars, a) ->
      let mid = a.(Array.length a / 2) in
      List.iter
        (fun (label, desc, after) ->
          let q = page items vars desc after in
          let got = List.map (fun r -> match r.(0) with Value.Link e -> e | _ -> assert false) (ok (ask v q)) in
          if got <> want a desc after then failwith (Printf.sprintf "%s, %s: not the ids of the page" what label);
          let w0 = Atomic.get Query.work in
          ignore (ok (ask v q));
          let work = Atomic.get Query.work - w0 in
          let calls = if work > 1_000_000 then 3 else if work > 100_000 then 20 else 500 in
          measure (Printf.sprintf "%s, %s (%d candidates)" what label work) calls (fun _ -> ignore (ok (ask v q))))
        [ "first page", false, None; "deep page", false, Some mid; "first page, desc", true, None; "deep page, desc", true, Some mid ])
    [ "by id", [ by_name ], 2, all; "tenant 3 by id", [ of_tenant ], 1, of3 ]

let run dir = let db = ok (open_ dir) in pages (view db); close db

(* the same pages on a fork filled in memory: every fact in its delta, as a program's database in memory (Centauri's
   admin on its seeded app) *)
let in_memory n =
  let db = fork empty in
  let t = fill db n in
  Printf.printf "a fork of %d items, filled in %.1f s\n%!" n t;
  pages (view db)

(* the pages of DIR's items on a fork of its view, whose delta holds N things of another kind (made after every item)
   and a change of one item's name: the runs' items beside a delta that changed their property *)
let mixed dir n =
  let db = ok (open_ dir) in
  let f = fork (view db) in
  let[@warning "-8"] [ note ] = ok (declare f [ prop "note/text" Ttext ]) in
  let name, _, _, _ = schema (view f) in
  let k = ref 0 in
  while !k < n do
    let m = min per_group (n - !k) in
    ignore (ok (write f (List.init m (fun j -> Resolve.Add (-1 - j, note, Text (Printf.sprintf "note %d" (!k + j)))))));
    k := !k + m
  done;
  let all, _, _ = ids (view f) in
  ignore (ok (write f [ Resolve.Add (all.(1), name, Text "item 1, renamed") ]));
  Printf.printf "a fork of %s with %d things of another kind in its delta, and one item renamed\n%!" dir n;
  pages (view f);
  close db

let csv dir out =
  let db = ok (open_ dir) in
  let v = view db in
  let name, tenant, num, _ = schema v in
  let all, of3, t3 = ids v in
  let oc = open_out out in
  Array.iter
    (fun e ->
      let one p = match Cepheus.values v e p with [ x ] -> x | _ -> failwith "one value" in
      let s = match one name with Value.Text s -> s | _ -> assert false in
      let t = match one tenant with Value.Link t -> t | _ -> assert false in
      let k = match one num with Value.Int k -> k | _ -> assert false in
      Printf.fprintf oc "%d,%s,%d,%d\n" e s t k)
    all;
  close_out oc;
  let oc = open_out (out ^ ".cursors") in
  Printf.fprintf oc "%d %d %d\n" all.(Array.length all / 2) of3.(Array.length of3 / 2) t3;
  close_out oc;
  close db

let () =
  match Sys.argv with
  | [| _; "load"; dir; n |] -> load dir (int_of_string n)
  | [| _; "run"; dir |] -> run dir
  | [| _; "csv"; dir; out |] -> csv dir out
  | [| _; "fork"; n |] -> in_memory (int_of_string n)
  | [| _; "mixed"; dir; n |] -> mixed dir (int_of_string n)
  | _ -> prerr_endline "kbench.exe load DIR N | run DIR | fork N | mixed DIR N | csv DIR OUT"; exit 2
