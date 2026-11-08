(* Benchmarks, the Cepheus side. One seeded generator makes the data for both sides: groups for Cepheus, CSV files
   for PostgreSQL's COPY. Method and results: docs/benchmarks.md.

     bench.exe load DIR CSVDIR FACTS   Cepheus through its writer (64 clients, one group per client and its 20
                                       invoices, then the follow links; GROUP=N clients a group, THREADS=T), a
                                       snapshot, and the CSV files
     bench.exe read DIR FACTS [QS]     open (restart time), then Q1-Q5 (or those named in QS, as Q1,Q4): median
                                       and its 95 % interval over RUNS runs (21); CEPHEUS_DOMAINS=d runs a question
                                       on up to d domains
     bench.exe write DIR CLIENTS SECS [RATE]
                                       durable writes of a new invoice (4 facts) with CLIENTS threads: as fast as
                                       they go (closed loop), or RATE groups a second in all (open loop: a write's
                                       latency counts from the time it was due, so a stall is never hidden)
     bench.exe merge DIR GROUPS        GROUPS new invoices with no merge in the background, then one merge of the
                                       whole base and the delta into a new file (snapshot): its time and the peak
                                       resident memory of the merge alone; CACHE_MB sets the cache
     bench.exe fsync DIR SECS MODE     a frame and its fsync in a loop: MODE append grows the file, overwrite writes
                                       into a file filled with zeros beforehand
     bench.exe trace DIR FACTS OUT LAW MIX
                                       a trace of the page reads of questions on clients drawn by LAW (uniform or
                                       zipf), MIX: day (with a Q4 and a Q5), points, or scan (points and a Q4)
     bench.exe cachesim TRACE          the cache policies on a trace, against Belady's optimum
     bench.exe stats NAME [us]         the summary of the numbers on stdin (one a line, in ms; with us, latencies
                                       in microseconds into a histogram) *)

open Cepheus

let now = Unix.gettimeofday
let follows_per_client = 5
let facts_per_client = 3 + follows_per_client + 80
let statuses = [| "paid"; "paid"; "paid"; "paid"; "paid"; "paid"; "paid"; "unpaid"; "unpaid"; "late" |]
let email k = Printf.sprintf "c%d@example.com" k

type schema = { name : int; cty : int; mail : int; follows : int; client : int; total : int; status : int; date : int }

let props =
  [ prop "client/name" Ttext; prop "client/city" Ttext; prop ~unique:true "client/email" Ttext;
    prop ~many:true "client/follows" Tlink; prop "invoice/client" Tlink; prop "invoice/total" (Tmoney 2);
    prop "invoice/status" Ttext; prop "invoice/date" Tdate ]

let schema_of v =
  let p n = Option.get (property v n) in
  { name = p "client/name"; cty = p "client/city"; mail = p "client/email"; follows = p "client/follows";
    client = p "invoice/client"; total = p "invoice/total"; status = p "invoice/status"; date = p "invoice/date" }

let schema db =
  match declare db props with
  | Ok [ name; cty; mail; follows; client; total; status; date ] -> { name; cty; mail; follows; client; total; status; date }
  | Ok _ -> assert false
  | Error e -> failwith (message e)

(* client k: its city, the clients it follows, its 20 invoices (total in cents, status, day); seeded by k *)
let client_data nclients k =
  let r = Rng.make ((k * 7919) + 1) in
  let c = Printf.sprintf "city-%d" (Rng.int r 100) in
  let fol = List.init follows_per_client (fun _ -> Rng.int r nclients) |> List.sort_uniq compare |> List.filter (( <> ) k) in
  let inv = List.init 20 (fun _ -> 1 + Rng.int r 100_000, statuses.(Rng.int r 10), Rng.int r 3650) in
  c, fol, inv

let parallel_n threads n f =
  let next = Atomic.make 0 in
  let worker () =
    let go = ref true in
    while !go do
      let k = Atomic.fetch_and_add next 1 in
      if k >= n then go := false else f k
    done
  in
  List.iter Thread.join (List.init threads (fun _ -> Thread.create worker ()))

let parallel n f = parallel_n 64 n f

let ok = function Ok r -> r | Error e -> failwith (message e)

let cache_from_env () =
  (match Sys.getenv_opt "CACHE_MB" with Some m -> set_cache (int_of_string m * 1024 * 1024) | None -> ());
  match Sys.getenv_opt "SYNC_MB" with Some m -> Snapshot.sync_every := int_of_string m lsl 20 | None -> ()

(* resident memory now, and its peak, in KB *)
let status field =
  let ic = open_in "/proc/self/status" in
  let r = ref 0 and n = String.length field in
  (try while true do
       let l = input_line ic in
       if String.length l > n && String.sub l 0 n = field then Scanf.sscanf (String.sub l n (String.length l - n)) " %d" (fun k -> r := k)
     done
   with End_of_file -> ());
  close_in ic;
  !r

let rss () = status "VmRSS:"
let peak () = status "VmHWM:"

(* the bytes of a directory's files, recursively *)
let rec du path =
  if Sys.is_directory path then Array.fold_left (fun n f -> n + du (Filename.concat path f)) 0 (Sys.readdir path)
  else (Unix.stat path).Unix.st_size

(* GROUP clients a group (1: a group per client, through 64 threads, as an application writing one invoice book at
   a time; more: large groups, a load), THREADS clients writing at once (64, or 1 with large groups) *)
let load dir csv facts =
  cache_from_env ();
  let nclients = facts / facts_per_client in
  let per = match Sys.getenv_opt "GROUP" with Some g -> max 1 (int_of_string g) | None -> 1 in
  let threads = match Sys.getenv_opt "THREADS" with Some t -> int_of_string t | None -> if per > 1 then 1 else 64 in
  let db = ok (open_ dir) in
  let s = schema db in
  let cid = Array.make nclients 0 in
  let nbatch = (nclients + per - 1) / per in
  let gc0 = Gc.quick_stat () and f0 = Atomic.get Engine.frames in
  let t0 = now () in
  (* a large group's operations made by several domains, each its share of the clients, as a loader would parse its
     input in parallel *)
  let build k0 k1 =
    let part lo hi =
      let ops = ref [] in
      for k = hi - 1 downto lo do
        let c, _, inv = client_data nclients k in
        let base = -1 - (21 * (k - k0)) in
        ops :=
          [ Add (base, s.name, Text (Printf.sprintf "client-%d" k)); Add (base, s.cty, Text c); Add (base, s.mail, Text (email k)) ]
          @ List.concat
              (List.mapi
                 (fun j (total, st, d) ->
                   let i = base - 1 - j in
                   [ Add (i, s.client, Link base); Add (i, s.total, Money total); Add (i, s.status, Text st); Add (i, s.date, Date d) ])
                 inv)
          @ !ops
      done;
      !ops
    in
    let d = if k1 - k0 >= 1000 then 4 else 1 in
    let cut i = k0 + ((k1 - k0) * i / d) in
    let doms = List.init d (fun i -> Domain.spawn (fun () -> part (cut i) (cut (i + 1)))) in
    List.concat (List.map Domain.join doms)
  in
  let built = ref 0 in
  parallel_n threads nbatch (fun b ->
      let k0 = b * per and k1 = min nclients ((b + 1) * per) in
      let ops = build k0 k1 in
      (* what the client's own list of operations holds, before the engine sees it *)
      if b = 0 then built := rss ();
      let r = ok (write db ~by:1 ~why:"load" ops) in
      (* the clients' new ids, read off the receipt in one walk (thing r t walks the list): client k of the group is
         the temporary id -1 - 21 (k - k0), its invoices the 20 after it *)
      List.iter (fun (t, e) -> let x = -1 - t in if x mod 21 = 0 then cid.(k0 + (x / 21)) <- e) r.things);
  let t1 = now () in
  parallel_n threads nbatch (fun b ->
      let k0 = b * per and k1 = min nclients ((b + 1) * per) in
      let ops = ref [] in
      for k = k1 - 1 downto k0 do
        let _, fol, _ = client_data nclients k in
        ops := List.map (fun f -> Add (cid.(k), s.follows, Link cid.(f))) fol @ !ops
      done;
      ignore (ok (write db ~by:1 ~why:"follows" !ops)));
  let t2 = now () in
  let peak_load = peak () in
  let gc1 = Gc.quick_stat () in
  let size1 = du dir and runs_before = Array.length (view db).runs in
  (* SNAPSHOT=0 leaves the runs as the load made them (for the reads across runs) *)
  if Sys.getenv_opt "SNAPSHOT" <> Some "0" then ok (snapshot db);
  let t3 = now () in
  let v = view db in
  Printf.printf "cepheus load: %d clients, %d facts in groups of %d clients by %d threads: %.2f s to confirm every group (clients %.2f s, follows %.2f s; %.0f facts/s), peak RSS %d MB, on disk %d MB (journal and runs)\n%!"
    nclients (Store.facts v) per threads (t2 -. t0) (t1 -. t0) (t2 -. t1) (float (Store.facts v) /. (t2 -. t0)) (peak_load / 1024) (size1 / 1048576);
  Printf.printf "  the client's operations of the first group built: RSS %d MB\n" (!built / 1024);
  Printf.printf "  then snapshot (every run merged into one) %.2f s, on disk %d MB; %d runs before it; peak RSS with it %d MB\n" (t3 -. t2) (du dir / 1048576) runs_before (peak () / 1024);
  Printf.printf "  %d frames, %d merges in the background; GC: %.0f M words minor, %.0f M major, %d major collections\n"
    (Atomic.get Engine.frames - f0) (Atomic.get Engine.merges) ((gc1.minor_words -. gc0.minor_words) /. 1e6)
    ((gc1.major_words -. gc0.major_words) /. 1e6) (gc1.major_collections - gc0.major_collections);
  Stats.print_latency "  writer resolves a batch" Engine.prepare_us;
  Stats.print_latency "  a large group resolved and sorted" Engine.large_resolve_us;
  Stats.print_latency "  a large group encoded" Engine.large_encode_us;
  Stats.print_latency "  a large group merged into a run" Engine.large_merge_us;
  Stats.print_latency "  writer waits for a merge switch" Engine.switch_us;
  Stats.print_latency "  a background merge" Engine.merge_us;
  Stats.print_latency "  journal pwrite" Journal.write_us;
  Stats.print_latency "  journal fsync" Journal.fsync_us;
  close db;
  if Sys.getenv_opt "NOCSV" <> None then exit 0;
  (* the same data for PostgreSQL *)
  let oc n = open_out (Filename.concat csv n) in
  let cl = oc "client.csv" and iv = oc "invoice.csv" and fo = oc "follows.csv" in
  for k = 0 to nclients - 1 do
    let c, fol, inv = client_data nclients k in
    Printf.fprintf cl "%d,client-%d,%s,%s\n" k k c (email k);
    List.iter (fun f -> Printf.fprintf fo "%d,%d\n" k f) fol;
    List.iteri (fun j (total, st, d) -> Printf.fprintf iv "%d,%d,%d,%s,%d\n" ((k * 20) + j) k total st d) inv
  done;
  List.iter close_out [ cl; iv; fo ]

(* ---- reads ---- *)

(* RUNS runs (21 by default); a run times [n] calls and gives the time of one; Stats summarises the runs *)
let runs = match Sys.getenv_opt "RUNS" with Some r -> int_of_string r | None -> 21

let measure name n f =
  let per = Array.init runs (fun _ ->
      let t = now () in
      for i = 0 to n - 1 do f i done;
      (now () -. t) /. float n) in
  Stats.print name per


(* the five questions on a view: Q1 and Q2 take a client's index, Q3 a city's; each returns a number to check *)
type questions = { q1 : int -> int; q2 : int -> int; q3 : int -> int; q4 : unit -> int * int; q5 : unit -> int }

let questions v s nclients =
  let r = Rng.make 9 in
  let sample = Array.init 4096 (fun _ -> Rng.int r nclients) in
  let cids = Array.map (fun k -> match things v s.mail (Text (email k)) with [ e ] -> e | _ -> failwith "email") sample in
  let q3 city =
    { vars = 3; ranges = [];
      where = [ { e = Var 0; p = s.cty; v = Val (Text city) }; { e = Var 1; p = s.client; v = Var 0 };
                { e = Var 1; p = s.status; v = Val (Text "unpaid") }; { e = Var 1; p = s.total; v = Var 2 } ] }
  in
  let q4 =
    { vars = 4; ranges = [];
      where = [ { e = Var 0; p = s.status; v = Val (Text "unpaid") }; { e = Var 0; p = s.client; v = Var 1 };
                { e = Var 1; p = s.cty; v = Var 2 }; { e = Var 0; p = s.total; v = Var 3 } ] }
  in
  let q5 =
    { vars = 3; ranges = [];
      where = [ { e = Var 0; p = s.follows; v = Var 1 }; { e = Var 1; p = s.follows; v = Var 2 }; { e = Var 2; p = s.follows; v = Var 0 } ] }
  in
  let count q = ok (fold v q ~init:(fun () -> 0) ~step:(fun n _ -> n + 1) ~merge:( + )) in
  (* Q1: all the facts of an invoice (a client's id + 1 + j) *)
  { q1 = (fun i -> List.length (get v (cids.(i land 4095) + 1 + (i mod 20))));
    q2 = (fun i -> List.length (things v s.mail (Text (email sample.(i land 4095)))));
    q3 = (fun i -> count (q3 (Printf.sprintf "city-%d" (i mod 100))));
    (* per domain: a table city -> (sum, count); merged at the end *)
    q4 = (fun () ->
        let sums =
          ok (fold v q4 ~init:(fun () -> Hashtbl.create 128)
                ~step:(fun t env ->
                    let a, n = Option.value (Hashtbl.find_opt t env.(2)) ~default:(0, 0) in
                    Hashtbl.replace t env.(2) (a + env.(3), n + 1);
                    t)
                ~merge:(fun a b ->
                    Hashtbl.iter (fun c (x, k) -> let y, m = Option.value (Hashtbl.find_opt a c) ~default:(0, 0) in Hashtbl.replace a c (x + y, k + m)) b;
                    a))
        in
        Hashtbl.fold (fun _ (_, n) acc -> acc + n) sums 0, Hashtbl.fold (fun _ (a, _) acc -> acc + a) sums 0);
    q5 = (fun () -> count q5) }

let read dir facts only =
  let asked q = match only with None -> true | Some l -> List.mem q (String.split_on_char ',' l) in
  (match Sys.getenv_opt "CEPHEUS_DOMAINS" with Some d -> Query.domains := int_of_string d | None -> ());
  cache_from_env ();
  Printf.printf "questions on up to %d domains, cache %d MB\n" !Query.domains (!Pages.capacity * Pages.size / 1048576);
  let nclients = facts / facts_per_client in
  let t0 = now () in
  let db = ok (open_ dir) in
  let t1 = now () in
  let v = view db in
  Printf.printf "open (restart from the snapshot): %.1f ms, %d facts, RSS %d MB, %d pages read\n%!" ((t1 -. t0) *. 1e3) (Store.facts v)
    (rss () / 1024) (Atomic.get Pages.misses);
  let s = schema_of v in
  let q = questions v s nclients in
  let miss0 = ref (Atomic.get Pages.misses) in
  let misses () = let m = Atomic.get Pages.misses in let d = m - !miss0 in miss0 := m; d in
  if asked "Q1" then measure "Q1 an invoice by id" 200_000 (fun i -> ignore (q.q1 i));
  if asked "Q2" then measure "Q2 a client by e-mail" 200_000 (fun i -> ignore (q.q2 i));
  if asked "Q3" then measure (Printf.sprintf "Q3 unpaid of a city (%d rows)" (q.q3 7)) 100 (fun i -> ignore (q.q3 i));
  if asked "Q4" then begin
    let cnt, total = q.q4 () in
    measure (Printf.sprintf "Q4 unpaid sum by city (%d inv, %d)" cnt total) 1 (fun _ -> ignore (q.q4 ()))
  end;
  if asked "Q5" then measure (Printf.sprintf "Q5 triangles (%d rotations)" (q.q5 ())) 1 (fun _ -> ignore (q.q5 ()));
  Printf.printf "pages read from the disk by the questions: %d; RSS %d MB, peak %d MB\n" (misses ()) (rss () / 1024) (peak () / 1024);
  close db

(* A trace of page reads for the cache study: a day of the application, point questions on clients drawn uniformly
   or by a Zipf law of exponent 0.99 (Gray et al. 1994, "Quickly generating billion-record synthetic databases"; YCSB's
   default, Cooper et al. 2010), with a Q4 and a Q5 among them (an analyst's scans). Written as 8-byte keys. *)
let trace dir facts out law mix =
  Query.domains := 1;
  let nclients = facts / facts_per_client in
  let db = ok (open_ dir) in
  let v = view db in
  let s = schema_of v in
  let q = questions v s nclients in
  let r = Rng.make 11 in
  let zipf =
    let h = Array.make nclients 0. in
    let acc = ref 0. in
    for k = 0 to nclients - 1 do acc := !acc +. (1. /. (float (k + 1) ** 0.99)); h.(k) <- !acc done;
    fun () ->
      let u = float (Rng.int r (1 lsl 30)) /. float (1 lsl 30) *. !acc in
      let lo = ref 0 and hi = ref (nclients - 1) in
      while !lo < !hi do let m = (!lo + !hi) / 2 in if h.(m) < u then lo := m + 1 else hi := m done;
      (* rank -> a client spread over the ids *)
      (!lo * 7919) mod nclients
  in
  let pick () = if law = "zipf" then zipf () else Rng.int r nclients in
  (* MIX: day, 30,000 point questions (a Q3 every 100) with a Q4 at a third and a Q5 at two thirds; points, 100,000
     point questions (a Q3 every 1,000); scan, the same with a Q4 in the middle *)
  let n = if mix = "day" then 30_000 else 100_000 and q3_every = if mix = "day" then 100 else 1000 in
  Pages.tracing := true;
  for i = 1 to n do
    (match i mod 10 with
     | 0 | 1 | 2 | 3 -> ignore (q.q1 (pick ()))
     | 4 | 5 | 6 -> ignore (q.q2 (pick ()))
     | _ -> if i mod q3_every = 7 then ignore (q.q3 (pick () mod 100)) else ignore (q.q1 (pick ())));
    if mix = "day" && i = 10_000 then ignore (q.q4 ());
    if mix = "day" && i = 20_000 then ignore (q.q5 ());
    if mix = "scan" && i = n / 2 then ignore (q.q4 ())
  done;
  Pages.tracing := false;
  let oc = open_out_bin out in
  let b = Bytes.create 8 in
  for i = 0 to !Pages.traced - 1 do Bytes.set_int64_le b 0 (Int64.of_int !Pages.trace.(i)); output_bytes oc b done;
  close_out oc;
  Printf.printf "trace %s: %d page reads\n" out !Pages.traced;
  close db

let cachesim file =
  let ic = open_in_bin file in
  let n = in_channel_length ic / 8 in
  let b = Bytes.create (8 * 65536) in
  let tr = Array.make n 0 in
  let i = ref 0 in
  while !i < n do
    let m = min 65536 (n - !i) in
    really_input ic b 0 (8 * m);
    for j = 0 to m - 1 do tr.(!i + j) <- Int64.to_int (Bytes.get_int64_le b (8 * j)) done;
    i := !i + m
  done;
  close_in ic;
  Cachesim.run (Filename.basename file) tr [ 0.02; 0.05; 0.1; 0.25 ]

(* ---- durable writes ---- *)

let write_bench dir clients secs rate =
  cache_from_env ();
  let db = ok (open_ dir) in
  let s = schema_of (view db) in
  let v = view db in
  let some_client = match things v s.mail (Text (email 0)) with [ e ] -> e | _ -> failwith "no client 0" in
  let stop = Atomic.make false in
  let hist = Array.init clients (fun _ -> Histogram.create ()) and cnt = Array.make clients 0 in
  let t0 = now () +. 0.01 in
  let worker c () =
    let r = Rng.make c in
    while not (Atomic.get stop) do
      (* open loop: the k-th write of client c is due at t0 + (k clients + c) / rate *)
      let due = if rate > 0. then t0 +. (float ((cnt.(c) * clients) + c) /. rate) else now () in
      let wait = due -. now () in
      if wait > 0. then Thread.delay wait;
      ignore (ok (write db ~by:c ~why:"invoice"
                    [ Add (-1, s.client, Link some_client); Add (-1, s.total, Money (Rng.int r 100000)); Add (-1, s.status, Text "unpaid");
                      Add (-1, s.date, Date (Rng.int r 3650)) ]));
      Histogram.record hist.(c) (int_of_float ((now () -. due) *. 1e6));
      cnt.(c) <- cnt.(c) + 1
    done
  in
  let gc0 = Gc.quick_stat () and m0 = Atomic.get Engine.merges and f0 = Atomic.get Engine.frames in
  let ts = List.init clients (fun c -> Thread.create (worker c) ()) in
  Unix.sleepf secs;
  Atomic.set stop true;
  List.iter Thread.join ts;
  let dt = now () -. t0 in
  let gc1 = Gc.quick_stat () in
  let n = Array.fold_left ( + ) 0 cnt in
  let h = Histogram.create () in
  Array.iter (Histogram.merge_into h) hist;
  let frames = Atomic.get Engine.frames - f0 in
  Printf.printf "W1 %3d clients%s: %7.0f durable groups/s, %.1f groups a frame, %d merges, GC %d minor %d major\n%!" clients
    (if rate > 0. then Printf.sprintf " at %.0f/s" rate else "") (float n /. dt) (float n /. float (max 1 frames))
    (Atomic.get Engine.merges - m0) (gc1.minor_collections - gc0.minor_collections) (gc1.major_collections - gc0.major_collections);
  Stats.print_latency "  write" h;
  close db;
  Stats.print_latency "  journal pwrite" Journal.write_us;
  Stats.print_latency "  journal fsync" Journal.fsync_us;
  Stats.print_latency "  writer resolves a batch" Engine.prepare_us;
  Stats.print_latency "  writer waits for a merge switch" Engine.switch_us;
  Stats.print_latency "  a background merge" Engine.merge_us;
  Printf.printf "  peak RSS %d MB\n%!" (peak () / 1024)

(* One merge, timed: GROUPS new invoices (4 facts each) written through the writer by 64 clients, with no merge in
   the background, then [snapshot], which merges the delta into a new base and its file. The peak resident memory
   of the merge alone: the process's peak is reset (/proc/self/clear_refs, 5) just before it. *)
let merge_bench dir groups =
  cache_from_env ();
  Engine.compact_min := max_int;
  let t0 = now () in
  let db = ok (open_ dir) in
  let t1 = now () in
  let s = schema_of (view db) in
  let some_client = match things (view db) s.mail (Text (email 0)) with [ e ] -> e | _ -> failwith "no client 0" in
  parallel groups (fun k ->
      ignore (ok (write db ~by:1 ~why:"invoice"
                    [ Add (-1, s.client, Link some_client); Add (-1, s.total, Money (1 + (k mod 100_000))); Add (-1, s.status, Text "unpaid");
                      Add (-1, s.date, Date (k mod 3650)) ])));
  let t2 = now () in
  let before = rss () in
  Printf.printf "merge: %d groups written in %.1f s, RSS %d MB; merging\n%!" groups (t2 -. t1) (before / 1024);
  let oc = open_out "/proc/self/clear_refs" in
  output_string oc "5";
  close_out oc;
  let t3 = now () in
  ok (snapshot db);
  let t4 = now () in
  Printf.printf "merge: %d facts, open %.2f s, %d groups written in %.1f s, merge of the delta %.2f s, RSS before %d MB, peak during the merge %d MB, after %d MB\n%!"
    (Store.facts (view db)) (t1 -. t0) groups (t2 -. t1) (t4 -. t3) (before / 1024) (peak () / 1024) (rss () / 1024);
  close db

(* the file system alone: a frame of 9,000 bytes (a frame of 125 groups) and its fsync, appended or overwriting zeros
   written and forced beforehand *)
let fsync_bench dir secs mode =
  let path = Filename.concat dir "fsync-test" in
  let len = 9000 and total = 64 * 1024 * 1024 in
  let fd = Unix.openfile path [ O_RDWR; O_CREAT; O_TRUNC ] 0o644 in
  let frame = Bytes.make len 'x' in
  if mode = "overwrite" then begin
    let z = Bytes.make (1 lsl 20) '\000' in
    for _ = 1 to total lsr 20 do ignore (Unix.write fd z 0 (Bytes.length z)) done;
    Unix.fsync fd;
    ignore (Unix.lseek fd 0 SEEK_SET)
  end;
  let h = Histogram.create () and w = Histogram.create () in
  let t0 = now () and off = ref 0 in
  while now () -. t0 < secs && !off + len <= total do
    let t = now () in
    ignore (Unix.write fd frame 0 len);
    let t1 = now () in
    Unix.fsync fd;
    let t2 = now () in
    Histogram.record w (int_of_float ((t1 -. t) *. 1e6));
    Histogram.record h (int_of_float ((t2 -. t1) *. 1e6));
    off := !off + len
  done;
  Unix.close fd;
  Unix.unlink path;
  Printf.printf "%s: %d frames of %d bytes in %.1f s\n" mode (Histogram.total h) len (now () -. t0);
  Stats.print_latency "  write" w;
  Stats.print_latency "  fsync" h

(* numbers on stdin, one a line *)
let stats name us =
  let xs = ref [] in
  (try while true do
       let l = String.trim (input_line stdin) in
       if l <> "" then xs := float_of_string l :: !xs
     done with End_of_file -> ());
  if us then begin
    let h = Histogram.create () in
    List.iter (fun x -> Histogram.record h (int_of_float x)) !xs;
    Stats.print_latency name h
  end
  else Stats.print name (Array.of_list (List.rev_map (fun x -> x /. 1e3) !xs))

(* CRC-32C alone, by the processor's instruction: a frame header, a 4 KiB block, a page, 1 MiB and a 96 MiB frame
   from an odd offset; a run times enough calls to last 20 ms or more *)
let crc_bench () =
  let r = Rng.make 3 in
  let big = Bytes.init (96 lsl 20) (fun _ -> Char.chr (Rng.int r 256)) in
  List.iter
    (fun len ->
      let calls = max 1 (20_000_000 / len) in
      let per = Array.init runs (fun _ ->
          let t = now () in
          for _ = 1 to calls do ignore (Sys.opaque_identity (Crc32c.bytes big 3 len)) done;
          (now () -. t) /. float calls) in
      let s = Stats.summary per in
      Stats.print (Printf.sprintf "crc32c of %d bytes" len) per;
      Printf.printf "  %.0f MB/s [%.0f, %.0f]\n%!" (float len /. s.median /. 1e6) (float len /. s.hi /. 1e6) (float len /. s.lo /. 1e6))
    [ 24; 4096; 16384; 1 lsl 20; (96 lsl 20) - 3 ]

(* the writer's work alone, without the disk: the same groups into a fork *)
let cpu dir n =
  let db = ok (open_ dir) in
  let s = schema_of (view db) in
  let c0 = match things (view db) s.mail (Text (email 0)) with [ e ] -> e | _ -> failwith "no client 0" in
  let f = fork (view db) in
  let t = now () in
  for i = 1 to n do
    ignore (ok (write f [ Add (-1, s.client, Link c0); Add (-1, s.total, Money i); Add (-1, s.status, Text "unpaid");
                          Add (-1, s.date, Date (i mod 3650)); Add (-1, s.status, Text "unpaid") ]))
  done;
  let dt = now () -. t in
  Printf.printf "writer work alone: %.1f us a group (%.0f groups/s), delta %d changes\n" (dt /. float n *. 1e6) (float n /. dt) (view f).delta.dn;
  close db

let () =
  match Sys.argv with
  | [| _; "cpu"; dir; n |] -> cpu dir (int_of_string n)
  | [| _; "load"; dir; csv; facts |] -> load dir csv (int_of_string facts)
  | [| _; "read"; dir; facts |] -> read dir (int_of_string facts) None
  | [| _; "read"; dir; facts; qs |] -> read dir (int_of_string facts) (Some qs)
  | [| _; "write"; dir; clients; secs |] -> write_bench dir (int_of_string clients) (float_of_string secs) 0.
  | [| _; "write"; dir; clients; secs; rate |] -> write_bench dir (int_of_string clients) (float_of_string secs) (float_of_string rate)
  | [| _; "fsync"; dir; secs; mode |] -> fsync_bench dir (float_of_string secs) mode
  | [| _; "merge"; dir; groups |] -> merge_bench dir (int_of_string groups)
  | [| _; "trace"; dir; facts; out; law; mix |] -> trace dir (int_of_string facts) out law mix
  | [| _; "cachesim"; file |] -> cachesim file
  | [| _; "crc" |] -> crc_bench ()
  | [| _; "stats"; name |] -> stats name false
  | [| _; "stats"; name; "us" |] -> stats name true
  | _ -> prerr_endline "bench.exe load DIR CSVDIR FACTS | read DIR FACTS [Q1,Q2,..] | write DIR CLIENTS SECS [RATE] | merge DIR GROUPS | fsync DIR SECS MODE | stats NAME [us] | trace DIR FACTS OUT uniform|zipf day|points|scan | cachesim TRACE | cpu DIR N | crc"; exit 2
