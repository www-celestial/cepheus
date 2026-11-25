(* The time of the server's questions and writes, a database each (cepheus status), and the log of the slow ones
   (cluster.toml, [log] slow_ms).

   What is timed. Each question answered (a Find, a Watch's first answer) and each write answered, at the server,
   from its bytes read to its reply coded: a write's reply is coded once its group is durable, so its wait for the
   fsync (and for the writer's queue) is in it. On the monotonic clock (Histogram.now_us, about 20 ns a read): its
   start is the read the connection makes after its bytes come for its idle limit (Net), or the end of the request
   before it among frames read together; its end is a read, which also gives the idle limit its last request, so
   that the clock is read no more often than before requests were timed. Into histograms of HdrHistogram's buckets (Tene) of 5 bits: a percentile within 1/32 (3.1 %) of the
   value, rounded up.

   The window. The percentiles are over the last minute: [slices] slices of [slice_us], the current one and the five
   before it, so between 50 and 60 seconds of values; a slice is begun again at the first value of its next turn. The
   counts and the sums of times are since the start, as a Prometheus summary's _count and _sum (exposition_formats:
   "quantiles over a sliding time window" for a summary's quantiles, cumulative count and sum).

   No lock a value. A question is timed by its connection's thread, a write by the thread that answers it, each on
   one of the server's domains; each domain records into a ring of its own (its shard, by Domain.self_index), so two
   domains never write one counter, and no domain waits for another. The threads of one domain run one at a time and
   switch only where the runtime polls (an allocation, a loop, a blocking call): a record reads its slice and writes
   its counters with no such point between (no loop, no allocation: Histogram.bucket has no loop, Array.fill is C; a
   ring and a shard are made, the allocation done, before the place that is read again and written), so the threads
   of a domain never interleave inside one record. A ring is one flat array of ints, its since-start counters and its
   threshold, then its six slices side by side, and a connection keeps its question ring at hand (Core), so that a
   record reads three cache lines of one array and follows no chain of pointers (a question's own work has pushed
   them out of the nearest cache by then: each pointer followed costs a miss, one after the other). A status reads
   every ring while their domains write: it copies a slice's counters (a racy read of ints, the old or the new value
   of each in OCaml 5's memory model: Dolan, Sivaramakrishnan, Madhavapeddy, PLDI 2018) between two reads of its
   number, which a slice begun again sets to -1 first; a slice whose number changed meanwhile is left out of that
   status. Histogram.add_buckets takes the total as the sum of the counters copied, so the percentiles it gives are
   those of a moment within its read.

   Memory: a ring is six slices of 963 counters and four more (45 KiB), made at its first value; a database timed by
   every one of d I/O domains, questions and writes, holds at most 2 x d rings (361 KiB for d = 4), an idle one
   nothing.

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

let nb = Histogram.buckets ~bits

(* a slice in a ring: its number (-1 while it is begun again), the sum and the maximum of its times, its buckets *)
let stride = 3 + nb

(* One kind of request of one database, as one domain records it: one flat array. At 0, 1 and 2 the count, the sum of
   the times (microseconds) and the count past the threshold, since the start; at 3 the threshold (0: none), so that
   a record reads nothing but the ring; then the [slices] slices, slice e at [head] + (e mod slices) x [stride]. [||]:
   none yet. *)
type ring = int array

let head = 4

type shard = { q : ring array; w : ring array }  (* questions and writes, by database index *)

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

let new_ring t =
  let d = Array.make (head + (slices * stride)) 0 in
  d.(3) <- t.slow_us;
  for s = 0 to slices - 1 do d.(head + (s * stride)) <- -1 done;
  d

(* this domain's shard, made at its first record (by a compare-and-set of the whole table: domains are few) *)
let rec shard t =
  let i = Domain.self_index () in
  let a = Atomic.get t.shards in
  if i < Array.length a then match Array.unsafe_get a i with Some s -> s | None -> add t i a else add t i a

and add t i a =
  let n = Array.length t.names in
  let s = { q = Array.make n [||]; w = Array.make n [||] } in
  let b = Array.make (max (i + 1) (Array.length a)) None in
  Array.blit a 0 b 0 (Array.length a);
  b.(i) <- Some s;
  if Atomic.compare_and_set t.shards a b then s else shard t

(* a database's ring in a shard, made at its first record: made first, then the place read again and written with no
   point between where another thread of the domain could run *)
let ring_of t (a : ring array) db =
  let r = Array.unsafe_get a db in
  if Array.length r > 0 then r
  else
    let o = new_ring t in
    let r = Array.unsafe_get a db in
    if Array.length r > 0 then r else (Array.unsafe_set a db o; o)

(* [us] recorded at [now] (both in microseconds) into ring [d]: true when it is past the threshold. No allocation, no
   loop, and nothing read but [d]: its since-start counters and slice 0's number share a cache line, a slice's number,
   sum and maximum another, its bucket a third. *)
let record (d : ring) ~now us =
  let us = if us < 0 then 0 else us in
  let e = now / slice_us in
  let b = head + (e mod slices * stride) in
  if Array.unsafe_get d b <> e then begin
    (* a slice begun again: its number -1 while its counters go back to 0 (a status reading it meanwhile leaves it out) *)
    Array.unsafe_set d b (-1);
    Array.fill d (b + 1) (stride - 1) 0;
    Array.unsafe_set d b e
  end;
  Array.unsafe_set d (b + 1) (Array.unsafe_get d (b + 1) + us);
  if us > Array.unsafe_get d (b + 2) then Array.unsafe_set d (b + 2) us;
  let i = b + 3 + Histogram.bucket ~bits us in
  Array.unsafe_set d i (Array.unsafe_get d i + 1);
  Array.unsafe_set d 0 (Array.unsafe_get d 0 + 1);
  Array.unsafe_set d 1 (Array.unsafe_get d 1 + us);
  let slow = Array.unsafe_get d 3 in
  if slow > 0 && us >= slow then (Array.unsafe_set d 2 (Array.unsafe_get d 2 + 1); true) else false

(* the calling domain's ring of a database's questions: a connection keeps it (Core), with the domain it is of *)
let question_ring t db = ring_of t (shard t).q db
let question t db ~now us = record (question_ring t db) ~now us
let write t db ~now us = record (ring_of t (shard t).w db) ~now us

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
    (match rows with Some n -> ", " ^ plural n "row" | None -> "")
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
  let one (kind : shard -> ring array) many one_ =
    let acc = Histogram.create ~bits () and count = ref 0 and sum = ref 0 and slow = ref 0 and copy = Array.make nb 0 in
    Array.iter
      (function
        | None -> ()
        | Some s ->
          let r = (kind s).(db) in
          if Array.length r > 0 then begin
            count := !count + r.(0);
            sum := !sum + r.(1);
            slow := !slow + r.(2);
            for s = 0 to slices - 1 do
              let b = head + (s * stride) in
              let pe = r.(b) in
              if pe > e - slices && pe <= e then begin
                let ssum = r.(b + 1) and smax = r.(b + 2) in
                Array.blit r (b + 3) copy 0 nb;
                (* begun again meanwhile: left out *)
                if r.(b) = pe then Histogram.add_buckets acc copy 0 ~sum:ssum ~max:smax
              end
            done
          end)
      (Atomic.get t.shards);
    let k x = "database." ^ t.names.(db) ^ "." ^ x in
    [ k many, string_of_int !count; k (many ^ "_slow"), string_of_int !slow; k (one_ ^ "_us_sum"), string_of_int !sum;
      k (one_ ^ "_us_p50"), string_of_int (Histogram.percentile acc 0.5); k (one_ ^ "_us_p99"), string_of_int (Histogram.percentile acc 0.99);
      k (one_ ^ "_us_max"), string_of_int (Histogram.max acc); k (one_ ^ "_samples"), string_of_int (Histogram.total acc) ]
  in
  one (fun s -> s.q) "questions" "question" @ one (fun s -> s.w) "writes" "write"
