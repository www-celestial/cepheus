(* The time of the server's questions and writes, a database each (cepheus status), and the log of the slow ones
   (cluster.toml, [log] slow_ms).

   What is timed. Each question answered (a Find, a Watch's first answer) and each write answered, at the server,
   from its request decoded to its reply coded: a write's reply is coded once its group is durable, so its wait for
   the fsync (and for the writer's queue) is in it. On the monotonic clock (Histogram.now_us: two reads of about 20 ns
   a request), into histograms of HdrHistogram's buckets (Tene) of 5 bits: a percentile within 1/32 (3.1 %) of the
   value, rounded up.

   The window. The percentiles are over the last minute: [slices] slices of [slice_us], the current one and the five
   before it, so between 50 and 60 seconds of values; a slice is begun again at the first value of its next turn. The
   counts and the sums of times are since the start, as a Prometheus summary's _count and _sum (exposition_formats:
   "quantiles over a sliding time window" for a summary's quantiles, cumulative count and sum).

   No lock a value. A question is timed by its connection's thread, a write by the thread that answers it, each on one
   of the server's domains; each domain records into slices of its own (its shard, by Domain.self_index), so two
   domains never write one counter, and no domain waits for another. The threads of one domain run one at a time and
   switch only where the runtime polls (an allocation, a loop, a blocking call): a record reads its slice and writes
   its counters with no such point between (Histogram.record has no loop; a slice, a ring and a shard are made, the
   allocation done, before the place that is read again and written), so the threads of a domain never interleave
   inside one record. A status reads every shard while their domains write: it copies their counters (a racy read of
   ints, the old or the new value of each in OCaml 5's memory model: Dolan, Sivaramakrishnan, Madhavapeddy, PLDI
   2018) and Histogram.merge_into takes the total as the sum of the counters it read, so the percentiles it gives are
   those of a moment within its read.

   Memory: a slice is 960 counters (7.5 KiB), made at its first value; a database timed by every one of d I/O domains,
   questions and writes, holds at most 2 x 6 x d slices (360 KiB for d = 4), an idle one nothing.

   The log. A question or a write that takes [slow_ms] or more (0: none) is written on a line of the standard error:
   its database, its token's name (never the token), its time, its outcome (ok, or the code of its error: never the
   error's message, which may quote a value), and for a question its candidates (the count the work budget counts),
   its rows and its shape, its constants written ?; for a write its operations by kind, its properties' names and its
   group. A name is escaped (Fault.escape) and a line cut at [max_line] bytes. At most [lines_a_second] lines a second;
   the next line written says how many were left out (they are counted in status all the same). As PostgreSQL's
   log_min_duration_statement, whose line holds the statement with its values, and pg_stat_statements, which keeps
   each statement's shape with its constants replaced. *)

open Cepheus
module Ask = Question.Ask
module Top = Question.Top

let bits = 5
let slice_us = 10_000_000
let slices = 6
let window_s = slices * slice_us / 1_000_000

(* one kind of request of one database, as one domain records it *)
type ring = {
  slots : (int * Histogram.t) array;  (* by slice number mod [slices]: the slice's number, its times *)
  mutable count : int;  (* since the start *)
  mutable sum : int;  (* microseconds, since the start *)
  mutable slow : int;  (* past the threshold, since the start *)
}

(* a slice no value is ever recorded into: its number is no slice's *)
let unused = (-1, Histogram.create ~bits ())

type shard = { q : ring option array; w : ring option array }  (* questions and writes, by database index *)

type t = {
  names : string array;  (* the databases, by index *)
  shards : shard option array Atomic.t;  (* by Domain.self_index *)
  slow_us : int;  (* 0: no log *)
  log : string -> unit;
  lm : Mutex.t;
  mutable second : int;  (* the monotonic clock's second of the lines counted in [written] *)
  mutable written : int;
  mutable left_out : int;  (* lines not written since the last one written *)
}

let lines_a_second = 10
let max_line = 2000

let stderr_line s = try prerr_endline ("cepheus: " ^ s) with _ -> ()

let create ?(slow_ms = 0) ?(log = stderr_line) names =
  { names; shards = Atomic.make [||]; slow_us = 1000 * max 0 slow_ms; log; lm = Mutex.create (); second = -1; written = 0;
    left_out = 0 }

let slow_ms t = t.slow_us / 1000

(* this domain's shard, made at its first record (by a compare-and-set of the whole table: domains are few) *)
let rec shard t =
  let i = Domain.self_index () in
  let a = Atomic.get t.shards in
  if i < Array.length a then match Array.unsafe_get a i with Some s -> s | None -> add t i a else add t i a

and add t i a =
  let n = Array.length t.names in
  let s = { q = Array.make n None; w = Array.make n None } in
  let b = Array.make (max (i + 1) (Array.length a)) None in
  Array.blit a 0 b 0 (Array.length a);
  b.(i) <- Some s;
  if Atomic.compare_and_set t.shards a b then s else shard t

(* a database's ring in a shard, made at its first record: made first, then the place read again and written with no
   point between where another thread of the domain could run *)
let ring_of (a : ring option array) db =
  match Array.unsafe_get a db with
  | Some r -> r
  | None -> (
    let o = Some { slots = Array.make slices unused; count = 0; sum = 0; slow = 0 } in
    match Array.unsafe_get a db with
    | Some r -> r
    | None -> (Array.unsafe_set a db o; match o with Some r -> r | None -> assert false))

(* [us] recorded at [now] (both in microseconds): true when it is past the threshold *)
let record t r ~now us =
  let e = now / slice_us in
  let i = e mod slices in
  let pe, h = Array.unsafe_get r.slots i in
  let h =
    if pe = e then h
    else begin
      (* a slice begun again: made first, then the slot read again (another thread of the domain may have begun it) *)
      let fresh = (e, Histogram.create ~bits ()) in
      let pe, h = Array.unsafe_get r.slots i in
      if pe = e then h else (Array.unsafe_set r.slots i fresh; snd fresh)
    end
  in
  Histogram.record h us;
  r.count <- r.count + 1;
  r.sum <- r.sum + us;
  if t.slow_us > 0 && us >= t.slow_us then (r.slow <- r.slow + 1; true) else false

let question t db ~now us = record t (ring_of (shard t).q db) ~now us
let write t db ~now us = record t (ring_of (shard t).w db) ~now us

(* ---- the log ---- *)

let say t line =
  let sec = Histogram.now_us () / 1_000_000 in
  let n =
    Mutex.protect t.lm (fun () ->
        if sec <> t.second then (t.second <- sec; t.written <- 0);
        if t.written >= lines_a_second then (t.left_out <- t.left_out + 1; -1)
        else (t.written <- t.written + 1; let n = t.left_out in t.left_out <- 0; n))
  in
  if n = 0 then t.log line
  else if n > 0 then t.log (Printf.sprintf "%s (and %d slow questions or writes not written since the line before)" line n)

let cut s = if String.length s <= max_line then s else String.sub s 0 max_line ^ "..."

let name (v : Store.view) p = match Schema.find v.schema p with Some d -> Fault.escape d.name | None -> "property " ^ string_of_int p

(* The shape of a question: its patterns with their properties' names, its variables x0, x1, ..., each constant ?
   (a thing, a value, a range's bounds, a prefix, After's row); an In's values counted, a Limit given (a page's
   size, not a value of the data) *)
let shape (v : Store.view) (q : Query.t) (sel : Wire.select) extra (order : Top.order) =
  let b = Buffer.create 128 in
  let full () = Buffer.length b > max_line in
  let add s = if not (full ()) then Buffer.add_string b s in
  let var x = "x" ^ string_of_int x in
  let term = function Query.Var x -> var x | Thing _ | Val _ -> "?" in
  let pattern (pt : Query.pattern) = add (Printf.sprintf " [%s %s %s]" (term pt.e) (name v pt.p) (term pt.v)) in
  let rec item = function
    | Ask.Pattern pt -> pattern pt
    | Range (x, _, _) -> add (Printf.sprintf " Range(%s, ?, ?)" (var x))
    | In (x, l) -> add (Printf.sprintf " In(%s, %d values)" (var x) (List.length l))
    | Prefix (x, _) -> add (Printf.sprintf " Prefix(%s, ?)" (var x))
    | Not l -> add " Not("; List.iter item l; add " )"
    | Or alts -> add " Or("; List.iteri (fun i l -> if i > 0 then add " |"; List.iter item l) alts; add " )"
  in
  (match sel with
   | Wire.Give [||] -> add "give all"
   | Give g -> add "give"; Array.iter (fun x -> add (" " ^ var x)) g
   | Group (keys, aggs) ->
     add "group";
     Array.iter (fun x -> add (" " ^ var x)) keys;
     Array.iter
       (function
         | Wire.Count -> add " count" | Sum x -> add (" sum " ^ var x) | Min x -> add (" min " ^ var x) | Max x -> add (" max " ^ var x))
       aggs);
  add " where";
  List.iter pattern q.where;
  List.iter (fun (x, _, _) -> add (Printf.sprintf " Range(%s, ?, ?)" (var x))) q.ranges;
  List.iter item extra;
  if order.keys <> [] then begin
    add " sort";
    List.iteri (fun i (k : Top.key) -> add (Printf.sprintf "%s column %d%s" (if i > 0 then "," else "") k.col (if k.desc then " desc" else ""))) order.keys
  end;
  if order.limit > 0 then add (Printf.sprintf " limit %d" order.limit);
  if order.after <> None then add " after ?";
  cut (Buffer.contents b)

(* A write's operations by kind, and the properties it names (the first 8; [more]: others too): taken when it arrives,
   in one pass, so that the slow line needs none of its operations (a large group's are let go of as soon as the
   writer has mapped them) *)
type write_shape = { ops : int; adds : int; retracts : int; expects : int; incrs : int; props : int list; more : bool }

let write_shape (ops : Resolve.op list) =
  let adds = ref 0 and retracts = ref 0 and expects = ref 0 and incrs = ref 0 and n = ref 0 and props = ref [] and k = ref 0
  and more = ref false in
  let see p = if (not !more) && not (List.mem p !props) then if !k < 8 then (props := p :: !props; incr k) else more := true in
  List.iter
    (fun (op : Resolve.op) ->
      (match op with
       | Add (_, p, _) -> incr adds; see p
       | Retract (_, p, _) -> incr retracts; see p
       | Expect (_, p, _) -> incr expects; see p
       | Incr (_, p, _, _) -> incr incrs; see p);
      incr n)
    ops;
  { ops = !n; adds = !adds; retracts = !retracts; expects = !expects; incrs = !incrs; props = List.rev !props; more = !more }

let plural n one = Printf.sprintf "%d %s%s" n one (if n = 1 then "" else "s")

let write_text (v : Store.view) w =
  let kinds =
    List.filter_map (fun (n, s) -> if n > 0 then Some (plural n s) else None)
      [ w.adds, "add"; w.retracts, "retract"; w.expects, "expect"; w.incrs, "incr" ]
  in
  cut
    (Printf.sprintf "%s (%s)%s%s" (plural w.ops "operation") (String.concat ", " kinds)
       (if w.props = [] then "" else " of " ^ String.concat ", " (List.map (name v) w.props))
       (if w.more then " and others" else ""))

let ms us = Printf.sprintf "%.1f ms" (float us /. 1000.)

let question_line ~db ~token ~us ~candidates ~rows ~outcome shape =
  Printf.sprintf "slow question: database %s, token %s, %s, %d candidates%s, %s: %s" db (Fault.escape token) (ms us) candidates
    (match rows with Some n -> Printf.sprintf ", %d rows" n | None -> "")
    outcome shape

let write_line ~db ~token ~us ~group ~outcome text =
  Printf.sprintf "slow write: database %s, token %s, %s%s, %s: %s" db (Fault.escape token) (ms us)
    (if group > 0 then Printf.sprintf ", group %d" group else "")
    outcome text

(* ---- cepheus status ---- *)

let server_lines t = [ "slow_ms", string_of_int (slow_ms t); "latency_window_s", string_of_int window_s ]

(* the lines of database [db]: since the start, and over the window that ends at [now] *)
let lines t db ~now =
  let e = now / slice_us in
  let one (kind : shard -> ring option array) many one_ =
    let acc = Histogram.create ~bits () and count = ref 0 and sum = ref 0 and slow = ref 0 in
    Array.iter
      (function
        | None -> ()
        | Some s -> (
          match (kind s).(db) with
          | None -> ()
          | Some r ->
            count := !count + r.count;
            sum := !sum + r.sum;
            slow := !slow + r.slow;
            Array.iter (fun (pe, h) -> if pe > e - slices && pe <= e then Histogram.merge_into acc h) r.slots))
      (Atomic.get t.shards);
    let k x = "database." ^ t.names.(db) ^ "." ^ x in
    [ k many, string_of_int !count; k (many ^ "_slow"), string_of_int !slow; k (one_ ^ "_us_sum"), string_of_int !sum;
      k (one_ ^ "_us_p50"), string_of_int (Histogram.percentile acc 0.5); k (one_ ^ "_us_p99"), string_of_int (Histogram.percentile acc 0.99);
      k (one_ ^ "_us_max"), string_of_int (Histogram.max acc); k (one_ ^ "_samples"), string_of_int (Histogram.total acc) ]
  in
  one (fun s -> s.q) "questions" "question" @ one (fun s -> s.w) "writes" "write"
