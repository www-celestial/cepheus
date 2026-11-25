(* Live questions: a question kept answered as the database changes (Watch). The same code runs at the server, for
   the programs that watch over the network, and in a local reader, for those on the server's machine (Follower).

   A watch gets its question's answer, then, after each frame that changes it, a change: the rows added and the rows
   removed. Its rows are always Find's rows: after a message of group n they are the answer of the question at group
   n, the same multiset (a projecting Give gives a row for each binding).

   The change of a frame, exactly. Let S be the facts before the frame and S' after; Δ+ = S' \ S, Δ- = S \ S' (a fact's
   presence counts, asserted or derived: a rule's conclusions are facts of the frame's groups). A binding of the
   question over S' that is not one over S uses a fact of Δ+ at some pattern; a binding over S that is not one over S'
   uses a fact of Δ-; the others are bindings of both. So the bindings added are those over S' that use a fact of Δ+,
   the bindings removed those over S that use a fact of Δ-. Each is found once: at the first pattern, in the
   question's order, whose fact is in Δ+ (Δ-): the fact fixed there, the patterns before it kept off Δ+ (Δ-), those
   after it free (the ordering the reasoner's semi-naive evaluation uses; the delta queries of Ammar, McSherry,
   Salihoglu, Joglekar, PVLDB 2018, split a join's change the same way). Each part is a selective question, answered by
   the engine's join (Query.fold) on the view after the frame (added) or before it (removed).

   Many watches share a template. Questions that differ only in their constants (the invoices of client c, each screen
   its own c) are one template, its constants parameters (variables after the question's own): a frame's bindings are
   found once for the template and routed by their parameters' values to the watches that hold those values (a hash
   lookup). A parameter fixed by a changed fact that no watch holds stops the search at once.

   Aggregates (Group): a row a key, kept by difference: the count and the sums add and subtract; a minimum or a
   maximum that a removal takes away is asked again for its key only. The aggregates of protocol 9 follow by
   difference too, exactly (Agg): an average's and a variance's exact sums subtract, a bag's count of a value goes
   down; a key's rows (one a value of its Values) are replaced whole when any changes.

   Trunc: a template computes a Trunc's column from its date's word as it gives a row (its variables after the
   template's, parameters included); the question it watches is that of the dates.

   Not, Or, In and Prefix (Ask): the bindings a frame may change are those that agree with one of its facts at a
   pattern of the question, wherever the pattern is: for a pattern of the question, or one inside a Not or an
   alternative that holds a variable of the question, the values of those variables (a key); for one whose variables
   are all the Not's or the alternative's own, the keys its other items give with the fact's values, before and after
   the frame. A binding that agrees with no fact reads no changed fact, and holds after the frame as before. For each
   key, the question is answered again with those values fixed (an In of one value a variable), before and after; the
   bindings added are those after that were not before, the bindings removed the other way, taken as the plain watches'
   are. The cost of a frame is that of its keys' questions; a fact of a pattern with no variable of the question in its
   group (a ground fact, a Not with no variable of the question) is the whole question again.

   Sort and Limit (a window): a watch with Sort keeps the rows of Find with the same Sort and Limit, in that order (the
   rows of each message come in it): with Limit k, the first k rows and the copies of the k-th, which the watch holds
   with the last of them, L. A row of the answer is held exactly when it comes at or before L (every row before the
   k-th is held, and every copy of it), unless the window holds the whole answer (fewer rows than k: then every row).
   So, at a frame, the rows held after it at or before L are those held, less the rows removed that come at or before
   L, plus the rows added that come at or before L: the delta queries' rows, each compared with L (O(d log k) for d
   rows). If they are k or more, the window is their first k and the copies of the k-th. If they are fewer, every row
   after L that the window now needs is one of the answer's after L: it is refilled by one Find of the rows After L,
   with Limit the rows missing, on the view after the frame (the index path when the first key is indexed); a refill
   that finds fewer than asked has found every row, and the window holds the whole answer. After each message the rows
   held are Find's at its group, ties too (spec/WatchWindow.tla checks the rule; test/live_sim.ml checks it against
   Find at every message). A watch without Sort is the plain one above.

   Messages are held until their frame is durable (G5, G13: never shown before a crash can no longer take it back):
   the hub evaluates a frame while it is forced, and gives its messages once it is durable. *)

open Cepheus
module Ask = Question.Ask
module Top = Question.Top

type row = Value.t array

type msg =
  | Answer of { group : int; rows : row list }  (** the whole answer at [group] *)
  | Change of { group : int; added : row list; removed : row list }
  | Same of { group : int }  (** the answer at [group] is the one at the group the watch resumed from *)
  | Ended of { code : string; message : string }  (** the watch is over; "lagging": watch again from its group *)

(* the state of a key of an aggregate: its bindings, each aggregate's word (a count, a sum, a minimum, a maximum),
   and the state of each aggregate of protocol 9 *)
type key = { mutable n : int; acc : int array; st : Agg.state option array }

(* a row of a window, in its order: every row of one window carries the same [cmp] *)
type wrow = { cmp : row -> row -> int; r : row }

module W = Map.Make (struct
  type t = wrow

  let compare a b = a.cmp a.r b.r
end)

(* Sort and Limit: the rows a watch holds, in its order *)
type window = {
  order : Top.order;  (* Sort's keys and Limit (0: every row); no After *)
  cmp : row -> row -> int;  (* the keys, then every other column ascending (Top.full) *)
  mutable kept : int W.t;  (* the rows held, each with its copies *)
  mutable n : int;  (* the rows held, copies counted *)
  mutable complete : bool;  (* they are every row of the answer *)
}

type sub = {
  sid : int;
  t : template;
  params : row;
  q : Query.t;  (* the question as asked *)
  emit : msg -> bool;  (* false: its queue is full (lagging) *)
  mutable gone : bool;
  keys : (row, key) Hashtbl.t;  (* Group: the state of every key *)
  (* the frame being evaluated *)
  mutable touched : bool;
  mutable plus : row list;
  mutable minus : row list;
  net : (row, int) Hashtbl.t;  (* a projecting Give: rows added minus removed *)
  before : (row, row list) Hashtbl.t;  (* Group: a touched key's rows before the frame *)
  dirty : (row, unit) Hashtbl.t;  (* Group: a key whose minimum or maximum was removed *)
  win : window option;  (* Sort and Limit *)
}

and template = {
  tkey : string;
  tq : Query.t;  (* the question, its constants as variables nq .. nq + np - 1 *)
  nq : int;
  np : int;
  pats : Query.pattern array;
  typs : Value.typ array;  (* of every variable of tq *)
  give : int array;  (* Give: its columns; Group: the key's variables (a Trunc's: dbase + i) *)
  qgive : int array;  (* the same, numbered as the question (a Trunc's: nq + i), for Answer *)
  aggs : Wire.agg array;  (* empty for Give *)
  truncs : Ask.item list;  (* the question's Truncs *)
  derived : (int * (int -> int)) array;  (* each Trunc's date (a variable of tq) and function *)
  dbase : int;  (* the number of the first Trunc's column in [give]: tq.vars *)
  projecting : bool;  (* Give leaves out a variable: two bindings may give one row *)
  subs : (row, sub list) Hashtbl.t;  (* by parameters *)
  slots : (Value.t, int) Hashtbl.t array;  (* each parameter's values among the watches, counted *)
  mutable count : int;
  extra : Ask.item list;  (* Not, Or, In and Prefix: the question kept by the keys a frame touches *)
  outer : bool array;  (* with them: the question's variables (not a Not's or an alternative's own) *)
  occ : (Query.pattern * Ask.item list option) array;  (* every pattern, and the items of its Not or alternative *)
}

type held = { tag : int; out : (sub * msg) list }

type hub = {
  hm : Mutex.t;
  templates : (string, template) Hashtbl.t;
  by_prop : (int, (template * int) list) Hashtbl.t;
  mutable view : Store.view;  (* the state after the newest frame given *)
  mutable tag : int;  (* the newest frame's tag: its last group (server) or its visibility number (local) *)
  mutable durable : int;  (* frames of this tag or below are durable *)
  mutable held : held list;  (* oldest first *)
  ring : (int * (int * int * Value.t) array) Queue.t;  (* recent frames: last group, facts whose presence changed *)
  mutable ring_n : int;
  mutable ring_from : int;  (* the ring holds every change after this group *)
  mutable next : int;
  mutable stopped : (string * string) option;
}

let ring_max = ref 1_000_000

(* for status and the benchmarks *)
let frames_us = Histogram.create ()

let create (v : Store.view) ~tag ~durable =
  { hm = Mutex.create (); templates = Hashtbl.create 16; by_prop = Hashtbl.create 16; view = v; tag; durable; held = [];
    ring = Queue.create (); ring_n = 0; ring_from = v.group; next = 1; stopped = None }

let watches h = Mutex.protect h.hm (fun () -> Hashtbl.fold (fun _ t n -> n + t.count) h.templates 0)

(* ---- questions with some variables fixed ---- *)

let num (x : Value.t) = match x with Int n | Date n | Money n | Link n -> Some n | Bool b -> Some (if b then 1 else 0) | _ -> None

(* [q] with the variables [asg] gives a value replaced by it, the others numbered again from 0, and the patterns
   [drop] says left out: the question and, for each of its variables, the one of [q]; None when a fixed value cannot
   hold (out of a range, a thing that is not a link) *)
let fix (q : Query.t) (asg : Value.t option array) ~drop =
  let map = Array.make q.vars (-1) and back = Array.make q.vars 0 and n = ref 0 in
  let var x = if map.(x) < 0 then (map.(x) <- !n; back.(!n) <- x; incr n); Query.Var map.(x) in
  let ok = ref true in
  let side ~thing = function
    | Query.Var x -> (
      match asg.(x) with
      | None -> var x
      | Some (Value.Link e) when thing -> Query.Thing e
      | Some _ when thing -> ok := false; Query.Thing 0
      | Some x -> Query.Val x)
    | t -> t
  in
  let where = List.filteri (fun i _ -> not (drop i)) q.where in
  let where = List.map (fun (pt : Query.pattern) -> let e = side ~thing:true pt.e in let v = side ~thing:false pt.v in { pt with e; v }) where in
  let ranges =
    List.filter_map
      (fun (x, lo, hi) ->
        match asg.(x) with
        | Some y ->
          (match y, lo, hi with
           | Value.Float c, Float a, Float b -> if Value.total_order a c > 0 || Value.total_order c b > 0 then ok := false
           | _ -> (match num y, num lo, num hi with Some c, Some a, Some b when c >= a && c <= b -> () | _ -> ok := false));
          None
        | None -> Some ((match var x with Query.Var y -> y | _ -> 0), lo, hi))
      q.ranges
  in
  if !ok then Some ({ Query.vars = !n; where; ranges }, Array.sub back 0 !n) else None

(* a binding's words for every variable of [q]: those [asg] fixes (their words in [v]), then those the fold gives *)
let fold_fixed (v : Store.view) (q : Query.t) asg ~drop (k : int array -> unit) =
  match fix q asg ~drop with
  | None -> ()
  | Some (q', back) ->
    (* a large question runs on several domains: each gathers its own bindings, given to [k] once the fold is done *)
    let base = Array.make q.vars 0 in
    let known = ref true in
    Array.iteri (fun x a -> match a with Some y -> (match Store.word v y with Some w -> base.(x) <- w | None -> known := false) | None -> ()) asg;
    if !known then
      Query.fold v q' ~init:(fun () -> []) ~merge:List.rev_append
        ~step:(fun acc env -> let full = Array.copy base in Array.iteri (fun i w -> full.(back.(i)) <- w) env; full :: acc)
      |> List.iter k

(* ---- templates ---- *)

let projecting (q : Query.t) give = let seen = Array.make q.vars false in Array.iter (fun x -> if x < q.vars then seen.(x) <- true) give; Array.exists not seen

(* the template of a question: its constants as parameters, in the order they appear; its key, and the parameters *)
let templatize ?(truncs = []) (q : Query.t) (sel : Wire.select) =
  let params = ref [] and np = ref 0 in
  let param x = let k = q.vars + !np in incr np; params := x :: !params; Query.Var k in
  let side = function Query.Var _ as t -> t | Thing c -> param (Value.Link c) | Val x -> param x in
  let where = List.map (fun (pt : Query.pattern) -> let e = side pt.e in let v = side pt.v in { pt with e; v }) q.where in
  let tq = { Query.vars = q.vars + !np; where; ranges = q.ranges } in
  let b = Buffer.create 64 in
  Wire.put_query b tq;
  Codec.put_varint b q.vars;
  Wire.put_select b sel;
  if truncs <> [] then Wire.put_order b ~extra:truncs Top.none;
  tq, Buffer.contents b, Array.of_list (List.rev !params)

(* a select's variables numbered for a template whose Truncs' columns start at [dbase] (the question's at [nq]) *)
let renumber ~nq ~dbase (sel : Wire.select) =
  let r x = if x >= nq then dbase + (x - nq) else x in
  let ra : Wire.agg -> Wire.agg = function
    | Count -> Count | Sum x -> Sum (r x) | Min x -> Min (r x) | Max x -> Max (r x) | Avg x -> Avg (r x)
    | Distinct x -> Distinct (r x) | Values x -> Values (r x) | Quantile (x, p, d) -> Quantile (r x, p, d)
    | Variance (x, b) -> Variance (r x, b) | Stddev (x, b) -> Stddev (r x, b)
  in
  match sel with Wire.Give g -> Wire.Give (Array.map r g) | Group (k, a) -> Group (Array.map r k, Array.map ra a)

let new_template ?(truncs = []) (v : Store.view) key tq nq (sel : Wire.select) =
  let typs = Query.var_types v tq in
  let derived = Ask.derived ~vars:nq ~outer:(fun _ -> true) typs truncs in
  let qgive = match sel with Wire.Give g -> if Array.length g = 0 then Array.init nq Fun.id else g | Group (k, _) -> k in
  let give, aggs = match renumber ~nq ~dbase:tq.vars sel with Wire.Give g -> (if Array.length g = 0 then Array.init nq Fun.id else g), [||] | Group (k, a) -> k, a in
  let q0 = { tq with vars = nq } in
  { tkey = key; tq; nq; np = tq.vars - nq; pats = Array.of_list tq.where; typs; give; qgive; aggs; truncs; derived; dbase = tq.vars;
    projecting = (Array.length aggs = 0 && projecting q0 give); subs = Hashtbl.create 64;
    slots = Array.init (tq.vars - nq) (fun _ -> Hashtbl.create 8); count = 0; extra = []; outer = [||]; occ = [||] }

(* every pattern of a question with Not, Or and In, theirs too: the properties a frame must touch *)
let all_patterns = Ask.patterns

(* every pattern of a question with operators, with the items of the Not or the alternative it is in (None: the
   question's own; an Optional's: [Optional p] alone) *)
let occurrences (q : Query.t) extra =
  let group l = List.filter_map (function Ask.Pattern p -> Some (p, Some l) | _ -> None) l in
  let of_item = function Ask.Not l -> group l | Or alts -> List.concat_map group alts | Optional p -> [ (p, Some [ Ask.Optional p ]) ] | _ -> [] in
  Array.of_list (List.map (fun p -> p, None) q.where @ List.concat_map of_item extra)

let whole_template ?(truncs = []) (v : Store.view) key (q : Query.t) (sel : Wire.select) extra =
  let a = Ask.compile v q extra in
  let derived = Ask.derived ~vars:q.vars ~outer:(fun x -> a.outer.(x)) (Ask.typs_of a) truncs in
  let give, aggs =
    match sel with
    | Wire.Give g -> (if Array.length g = 0 then Array.of_list (List.filter (fun x -> a.outer.(x)) (List.init q.vars Fun.id)) else g), [||]
    | Group (k, a) -> k, a
  in
  (* an Optional's variable may be missing: no Sum, Min or Max of it, as Find refuses (Answer) *)
  let src x = if x < q.vars then x else fst derived.(x - q.vars) in
  Array.iter
    (function
      | Wire.Sum x | Min x | Max x when Array.exists (fun (o : Ask.opt) -> o.ov = src x) a.opts ->
        Query.bad "Sum, Min and Max take a variable of a pattern, not an Optional's, which may be missing: give its values, or Count the rows"
      | g -> (
        match Agg.var_of g with
        | Some x when Agg.is_new g ->
          let ty = if x < q.vars then (Ask.typs_of a).(x) else Value.Tdate in
          Agg.check g ty ~optional:(Array.exists (fun (o : Ask.opt) -> o.ov = src x) a.opts)
        | _ -> ()))
    aggs;
  (* its rows' columns, Ask.projector's: refused here as Find refuses them *)
  let (_ : int array -> int array) = if derived = [||] then Ask.projector a give else Ask.derived_projector ~vars:q.vars ~mask:(Array.length a.opts > 0) derived give in
  let projecting = Array.length aggs = 0 && Array.exists Fun.id (Array.mapi (fun x o -> o && not (Array.mem x give)) a.outer) in
  { tkey = key; tq = q; nq = q.vars; np = 0; pats = Array.of_list (all_patterns q extra); typs = Ask.typs_of a; give; qgive = give; aggs;
    truncs; derived; dbase = q.vars; projecting; subs = Hashtbl.create 4; slots = [||]; count = 0; extra; outer = a.outer;
    occ = occurrences q extra }

(* the bindings of a question with operators that hold these values (an In of one value a variable) *)
let fixed_bindings (v : Store.view) (q : Query.t) extra (fixes : (int * Value.t) list) =
  let a = Ask.compile v q (extra @ List.map (fun (x, y) -> Ask.In (x, [ y ])) fixes) in
  Ask.fold ~budget:!Answer.question_budget v a ~init:(fun () -> []) ~merge:List.rev_append ~step:(fun acc b -> b :: acc)

(* ---- the state of a watch ---- *)

(* a binding's values; a binding of a question with Optionals has the mask of its missing variables after them; a
   Trunc's column (dbase + i) computed from its date's word, missing when the date is *)
let word (t : template) (b : int array) x = if x < t.dbase then b.(x) else let s, f = t.derived.(x - t.dbase) in f b.(s)
let vtyp (t : template) x = if x < t.dbase then t.typs.(x) else Value.Tdate
let src (t : template) x = if x < t.dbase then x else fst t.derived.(x - t.dbase)

let values (v : Store.view) (t : template) (b : int array) cols =
  let m = Array.length t.typs in
  if t.derived = [||] then begin
    if Array.length b > m then Array.map (fun x -> if (b.(m) lsr x) land 1 = 1 then Value.missing else Store.value v t.typs.(x) b.(x)) cols
    else Array.map (fun x -> Store.value v t.typs.(x) b.(x)) cols
  end
  else if Array.length b > m then Array.map (fun x -> if (b.(m) lsr src t x) land 1 = 1 then Value.missing else Store.value v (vtyp t x) (word t b x)) cols
  else Array.map (fun x -> Store.value v (vtyp t x) (word t b x)) cols

(* is the variable of aggregate i missing in b (an Optional's) *)
let agg_missing (t : template) (b : int array) x = let m = Array.length t.typs in Array.length b > m && (b.(m) lsr src t x) land 1 = 1

let agg_value (t : template) i w : Value.t =
  match t.aggs.(i) with
  | Wire.Count -> Int w
  | Sum x | Min x | Max x -> (match vtyp t x with Tmoney _ -> Money w | Tdate -> Date w | _ -> Int w)
  | _ -> Value.missing

let agg_start (t : template) = Array.map (function Wire.Min _ -> max_int | Wire.Max _ -> min_int | _ -> 0) t.aggs

let new_key (t : template) = { n = 0; acc = agg_start t; st = Array.map (fun a -> if Agg.is_new a then Some (Agg.fresh a) else None) t.aggs }

(* an aggregate of protocol 9 given a binding that comes (sign 1) or goes (-1): exact sums and bags follow by
   difference (a bag's words are the dictionary's, which keeps a text's or a float's number for the database's life) *)
let agg_new (v : Store.view) (t : template) (k : key) i sign (b : int array) =
  match k.st.(i), Agg.var_of t.aggs.(i) with
  | Some st, Some x when not (agg_missing t b x) -> ignore (Agg.add v (vtyp t x) st sign (word t b x))
  | _ -> ()

let agg_add (v : Store.view) (t : template) (k : key) (b : int array) =
  k.n <- k.n + 1;
  Array.iteri
    (fun i a ->
      match a with
      | Wire.Count -> k.acc.(i) <- k.acc.(i) + 1
      | Sum x -> k.acc.(i) <- k.acc.(i) + word t b x
      | Min x -> let w = word t b x in if w < k.acc.(i) then k.acc.(i) <- w
      | Max x -> let w = word t b x in if w > k.acc.(i) then k.acc.(i) <- w
      | _ -> agg_new v t k i 1 b)
    t.aggs

(* a removal: true when it takes away a minimum or a maximum, which must be asked again *)
let agg_remove (v : Store.view) (t : template) (k : key) (b : int array) =
  k.n <- k.n - 1;
  let again = ref false in
  Array.iteri
    (fun i a ->
      match a with
      | Wire.Count -> k.acc.(i) <- k.acc.(i) - 1
      | Sum x -> k.acc.(i) <- k.acc.(i) - word t b x
      | Min x | Max x -> if word t b x = k.acc.(i) then again := true
      | _ -> agg_new v t k i (-1) b)
    t.aggs;
  !again

(* a key's rows: its values, then its aggregates; one a value of its Values (Agg.flatten); none when it has no
   binding *)
let key_rows (v : Store.view) (t : template) kv (k : key) =
  if k.n <= 0 then []
  else if Array.for_all Option.is_none k.st then [ Array.append kv (Array.mapi (fun i w -> agg_value t i w) k.acc) ]
  else begin
    let cells =
      Array.append (Array.map (fun x -> Agg.One x) kv)
        (Array.mapi
           (fun i a ->
             match k.st.(i), Agg.var_of a with
             | Some st, Some x -> (
               let tx = vtyp t x in
               match a with
               | Wire.Values _ -> Agg.Many (Array.map (Store.value v tx) (Agg.sorted_values v tx st))
               | _ -> Agg.One (Agg.result v a tx st))
             | _ -> Agg.One (agg_value t i k.acc.(i)))
           t.aggs)
    in
    Agg.flatten cells
  end

(* the key's state asked again on [v]: its bindings only (the question with the key fixed; a Trunc's column is not a
   variable of the question: its bindings are those whose Trunc gives the key's) *)
let recount (v : Store.view) (s : sub) kv =
  let t = s.t in
  let mine b = t.derived = [||] || compare (values v t b t.give) kv = 0 in
  let k = new_key t in
  if t.extra <> [] then begin
    let fixes = List.filter_map Fun.id (Array.to_list (Array.mapi (fun i x -> if x < t.dbase then Some (x, kv.(i)) else None) t.give)) in
    List.iter (fun b -> if mine b then agg_add v t k b) (fixed_bindings v s.q t.extra fixes);
    k
  end
  else begin
    let asg = Array.make s.q.vars None in
    Array.iteri (fun i x -> if x < t.dbase then asg.(x) <- Some kv.(i)) t.give;
    fold_fixed v s.q asg ~drop:(fun _ -> false) (fun b -> if mine b then agg_add v t k b);
    k
  end

(* ---- Sort and Limit: a window ---- *)

let new_window (o : Top.order) cols =
  let ord = Top.full cols o.keys in
  { order = o; cmp = Top.compare_value_rows ord; kept = W.empty; n = 0; complete = true }

let win_add w r d =
  w.kept <- W.update { cmp = w.cmp; r } (function None -> Some d | Some c -> Some (c + d)) w.kept;
  w.n <- w.n + d

(* one copy of [r] taken away, if held *)
let win_take w r =
  let k = { cmp = w.cmp; r } in
  match W.find_opt k w.kept with
  | Some c ->
    w.kept <- (if c = 1 then W.remove k w.kept else W.add k (c - 1) w.kept);
    w.n <- w.n - 1;
    true
  | None -> false

(* a watch's answer at the server counts four cells a cell: its rows become values (an int boxed, a text its string),
   about three words more than the index word each *)
let weight = 4

(* an answer's rows as values *)
let values_of (v : Store.view) (a : Answer.answer) =
  let typs = Array.init a.cols a.typ in
  ignore typs;
  List.init a.n (fun i -> Array.init a.cols (fun j -> Answer.value v a i j))

(* the rows of [s]'s question in its order on [v], from the row after [after] (None: the first), [limit] of them and
   the copies of the last (0: all) *)
let ordered ?ticket ?(budget = !Answer.question_budget) ?stop (v : Store.view) (s : sub) (w : window) ~after ~limit =
  let t = s.t in
  let order = { w.order with Top.limit; after } in
  let a = Answer.answer ?ticket ~weight ~order ~extra:(t.extra @ t.truncs) ~budget ?stop v s.q (Wire.Give t.qgive) in
  values_of v a

(* the window filled with the answer on [v]: its rows *)
let win_answer ?ticket ?budget ?stop (v : Store.view) (s : sub) (w : window) =
  let rows = ordered ?ticket ?budget ?stop v s w ~after:None ~limit:w.order.limit in
  w.kept <- W.empty;
  w.n <- 0;
  List.iter (fun r -> win_add w r 1) rows;
  w.complete <- w.order.limit = 0 || w.n < w.order.limit;
  rows

(* A frame's rows added and removed (the delta queries') moved into the window, on the view after the frame [v1]: the
   rows it gains and loses, each in the order (the rule at the top of this file) *)
let slide (v1 : Store.view) (s : sub) (w : window) added removed =
  (* each row's copies gained (> 0) or lost, in the order *)
  let net = ref W.empty in
  let note r d = net := W.update { cmp = w.cmp; r } (fun o -> Some (d + Option.value o ~default:0)) !net in
  let last = match W.max_binding_opt w.kept with Some (k, _) -> Some k.r | None -> None in
  let inside r = w.complete || match last with Some l -> w.cmp r l <= 0 | None -> false in
  List.iter (fun r -> if inside r && win_take w r then note r (-1)) removed;
  List.iter (fun r -> if inside r then (win_add w r 1; note r 1)) added;
  let k = w.order.limit in
  if k > 0 && w.n > k then begin
    (* the first k rows and the copies of the k-th: the whole entries after it go *)
    let go = ref true in
    while !go do
      match W.max_binding_opt w.kept with
      | Some (m, c) when w.n - c >= k -> w.kept <- W.remove m w.kept; w.n <- w.n - c; w.complete <- false; note m.r (-c)
      | _ -> go := false
    done
  end;
  if k > 0 && w.n < k && not w.complete then begin
    (* every row held is at or before L, and every row of the answer there is held: the missing ones come after L *)
    let need = k - w.n in
    let more = ordered v1 s w ~after:last ~limit:need in
    List.iter (fun r -> win_add w r 1; note r 1) more;
    if List.length more < need then w.complete <- true
  end;
  let copies r c acc = let rec go i acc = if i = 0 then acc else go (i - 1) (r :: acc) in go c acc in
  let a, r = W.fold (fun x d (a, r) -> if d > 0 then copies x.r d a, r else if d < 0 then a, copies x.r (-d) r else a, r) !net ([], []) in
  List.rev a, List.rev r

(* the watch's answer now, and its state (the keys of an aggregate, the window); at the server, its cells charged to
   [ticket] as they are found, and its work within [budget] (Answer) *)
let answer ?ticket ?budget ?stop (v : Store.view) (s : sub) =
  let t = s.t in
  match s.win with
  | Some w -> win_answer ?ticket ?budget ?stop v s w
  | None ->
  if Array.length t.aggs = 0 then begin
    let a =
      if t.extra = [] then Answer.answer ?ticket ~weight ~extra:t.truncs ?budget ?stop v s.q (Wire.Give t.qgive)
      else Answer.answer ?ticket ~weight ~extra:(t.extra @ t.truncs) ~budget:(Option.value budget ~default:!Answer.question_budget) ?stop v s.q (Wire.Give t.qgive)
    in
    values_of v a
  end
  else begin
    Hashtbl.reset s.keys;
    (* a table a domain, joined at the end *)
    let combine (a : key) (b : key) =
      a.n <- a.n + b.n;
      Array.iteri
        (fun i g ->
          match g with
          | Wire.Count | Sum _ -> a.acc.(i) <- a.acc.(i) + b.acc.(i)
          | Min _ -> a.acc.(i) <- min a.acc.(i) b.acc.(i)
          | Max _ -> a.acc.(i) <- max a.acc.(i) b.acc.(i)
          | _ -> (match a.st.(i), b.st.(i) with Some x, Some y -> Agg.merge x y | _ -> ()))
        t.aggs
    in
    let fold ~init ~merge ~step =
      if t.extra = [] then Query.fold ?budget ?stop v s.q ~init ~merge ~step
      else Ask.fold ~budget:(Option.value budget ~default:!Answer.question_budget) ?stop v (Ask.compile v s.q t.extra) ~init ~merge ~step
    in
    (* a key's cells (its values and its aggregates, four words each), charged by grains of keys *)
    let width = weight * max 1 (Array.length t.give + Array.length t.aggs) in
    let every = max 1 (Answer.grain / width) in
    let added = match ticket with None -> ignore | Some tk -> fun n -> if n mod every = 0 then Answer.charge tk (every * width) in
    let tbl =
      fold ~init:(fun () -> Hashtbl.create 16)
        ~merge:(fun a b -> Hashtbl.iter (fun kv k -> match Hashtbl.find_opt a kv with Some k' -> combine k' k | None -> Hashtbl.replace a kv k) b; a)
        ~step:(fun tbl b ->
          let kv = values v t b t.give in
          let k =
            match Hashtbl.find_opt tbl kv with
            | Some k -> k
            | None -> let k = new_key t in Hashtbl.replace tbl kv k; added (Hashtbl.length tbl); k
          in
          agg_add v t k b;
          tbl)
    in
    Hashtbl.iter (fun kv k -> Hashtbl.replace s.keys kv k) tbl;
    let rows = Hashtbl.fold (fun kv k acc -> List.rev_append (key_rows v t kv k) acc) s.keys [] in
    List.sort compare rows
  end

(* a question checked as Find checks it: its variables (its Truncs' after them), its constants' types, its
   aggregates' variables *)
let check ?(truncs = []) (v : Store.view) (q : Query.t) (sel : Wire.select) =
  let ty = Query.var_types v q in
  let nd = Array.length (Ask.derived ~vars:q.vars ~outer:(fun _ -> true) ty truncs) in
  let tyx x = if x < q.vars then ty.(x) else Value.Tdate in
  let var x = if x < 0 || x >= q.vars + nd then Query.bad "variable %d out of range" x in
  ignore (Query.plan v q);
  match sel with
  | Wire.Give g -> Array.iter var g
  | Group (keys, aggs) ->
    Array.iter var keys;
    Array.iter
      (function
        | Wire.Count -> ()
        | Sum x -> var x; (match tyx x with Tint | Tmoney _ -> () | t -> Query.bad "a sum of a %s variable" (Value.typ_name t))
        | Min x | Max x ->
          var x;
          (match tyx x with Tint | Tmoney _ | Tdate -> () | t -> Query.bad "a min or max of a %s variable" (Value.typ_name t))
        | g -> (match Agg.var_of g with Some x -> var x; Agg.check g (tyx x) ~optional:false | None -> ()))
      aggs

(* ---- a frame ---- *)

(* a binding of the template, with its sign, given to the watch: into the frame's change *)
let take (v : Store.view) (s : sub) sign (b : int array) =
  let t = s.t in
  s.touched <- true;
  if Array.length t.aggs = 0 then begin
    let r = values v t b t.give in
    if t.projecting then Hashtbl.replace s.net r (sign + Option.value (Hashtbl.find_opt s.net r) ~default:0)
    else if sign > 0 then s.plus <- r :: s.plus
    else s.minus <- r :: s.minus
  end
  else begin
    let kv = values v t b t.give in
    let k = match Hashtbl.find_opt s.keys kv with Some k -> k | None -> let k = new_key t in Hashtbl.replace s.keys kv k; k in
    if not (Hashtbl.mem s.before kv) then Hashtbl.replace s.before kv (key_rows v t kv k);
    if sign > 0 then agg_add v t k b else if agg_remove v t k b then Hashtbl.replace s.dirty kv ()
  end

(* the frame's change of a watch, its scratch cleared: None when its rows did not change *)
let finish (v1 : Store.view) (s : sub) =
  let t = s.t in
  s.touched <- false;
  let added, removed =
    if Array.length t.aggs = 0 then begin
      if t.projecting then begin
        let a = ref [] and r = ref [] in
        Hashtbl.iter (fun row d -> if d > 0 then for _ = 1 to d do a := row :: !a done else for _ = 1 to -d do r := row :: !r done) s.net;
        Hashtbl.reset s.net;
        !a, !r
      end
      else begin
        let a = s.plus and r = s.minus in
        s.plus <- [];
        s.minus <- [];
        a, r
      end
    end
    else begin
      let a = ref [] and r = ref [] in
      Hashtbl.iter
        (fun kv old ->
          let k = Hashtbl.find s.keys kv in
          if Hashtbl.mem s.dirty kv && k.n > 0 then begin
            let k' = recount v1 s kv in
            Array.blit k'.acc 0 k.acc 0 (Array.length k.acc)
          end;
          let now = key_rows v1 t kv k in
          if k.n <= 0 then Hashtbl.remove s.keys kv;
          (* compare, not <>: a NaN is its own row again *)
          if compare old now <> 0 then begin
            r := List.rev_append (List.rev old) !r;
            a := List.rev_append (List.rev now) !a
          end)
        s.before;
      Hashtbl.reset s.before;
      Hashtbl.reset s.dirty;
      !a, !r
    end
  in
  let added, removed = match s.win with Some w when added <> [] || removed <> [] -> slide v1 s w added removed | _ -> added, removed in
  if added = [] && removed = [] then None else Some (added, removed)

(* The bindings of the template over [v] that use a fact of [delta] (a table of the frame's facts on this side, by
   their words in [v]), each at the first pattern whose fact is in [delta]: given to the watches of their
   parameters. *)
let side_bindings (v : Store.view) (t : template) (facts : (int * int * Value.t) list) (delta : (int * int * int, unit) Hashtbl.t) sign touched =
  let fact_of (pt : Query.pattern) b =
    let e = match pt.e with Query.Var x -> b.(x) | _ -> -1 and w = match pt.v with Query.Var x -> b.(x) | _ -> -1 in
    e, pt.p, w
  in
  List.iter
    (fun (fe, fp, fx) ->
      Array.iteri
        (fun i (pt : Query.pattern) ->
          if pt.p = fp then begin
            let asg = Array.make t.tq.vars None in
            let set x y = match asg.(x) with None -> asg.(x) <- Some y; true | Some z -> Value.equal y z in
            let ok =
              (match pt.e with Query.Var x -> set x (Value.Link fe) | _ -> false)
              && (match pt.v with Query.Var x -> set x fx | _ -> false)
            in
            (* a parameter that no watch holds: nothing to give *)
            let held = ref true in
            for x = t.nq to t.tq.vars - 1 do
              match asg.(x) with Some y when not (Hashtbl.mem t.slots.(x - t.nq) y) -> held := false | _ -> ()
            done;
            if ok && !held then
              fold_fixed v t.tq asg ~drop:(fun j -> j = i) (fun b ->
                  let first = ref true in
                  for j = 0 to i - 1 do if !first && Hashtbl.mem delta (fact_of t.pats.(j) b) then first := false done;
                  if !first then begin
                    let ps = Array.init t.np (fun k -> Store.value v t.typs.(t.nq + k) b.(t.nq + k)) in
                    match Hashtbl.find_opt t.subs ps with
                    | Some ss ->
                      List.iter
                        (fun s ->
                          if not s.gone then begin
                            if not s.touched then touched := s :: !touched;
                            take v s sign b
                          end)
                        ss
                    | None -> ()
                  end)
          end)
        t.pats)
    facts

(* ---- a frame's change of a question with operators ---- *)

(* the values a fact gives a pattern's variables, if it is a fact of that pattern *)
let assign (pt : Query.pattern) fe (fx : Value.t) =
  let asg = ref [] and ok = ref true in
  let set x y = match List.assoc_opt x !asg with Some z -> if not (Value.equal y z) then ok := false | None -> asg := (x, y) :: !asg in
  (match pt.e with Query.Var x -> set x (Value.Link fe) | Thing c -> if c <> fe then ok := false | Val y -> if not (Value.equal y (Link fe)) then ok := false);
  (match pt.v with Query.Var x -> set x fx | Thing c -> if not (Value.equal (Link c) fx) then ok := false | Val y -> if not (Value.equal y fx) then ok := false);
  if !ok then Some !asg else None

(* the keys a group's own question gives (the items of a Not or of an alternative, the fact's values fixed), in each
   view: the values of the question's variables of the group; None when they cannot be asked alone *)
let group_keys (vs : Store.view list) (t : template) items asg outer_asg gout =
  let used = List.sort_uniq compare (List.concat_map Ask.vars_of_item items) in
  let dense = Array.make t.tq.vars (-1) in
  List.iteri (fun i x -> dense.(x) <- i) used;
  let ren = function Query.Var x -> Query.Var dense.(x) | t -> t in
  let where = List.filter_map (function Ask.Pattern (p : Query.pattern) -> Some { p with Query.e = ren p.e; v = ren p.v } | _ -> None) items in
  let ranges = List.filter_map (function Ask.Range (x, lo, hi) -> Some (dense.(x), lo, hi) | _ -> None) items in
  let conds = List.filter_map (function Ask.In (x, l) -> Some (Ask.In (dense.(x), l)) | Prefix (x, p) -> Some (Ask.Prefix (dense.(x), p)) | _ -> None) items in
  let q = { Query.vars = List.length used; where; ranges } in
  let fixes = List.map (fun (x, y) -> Ask.In (dense.(x), [ y ])) asg in
  match
    List.concat_map
      (fun (v : Store.view) ->
        let a = Ask.compile v q (conds @ fixes) in
        let bs = Ask.fold ~budget:!Answer.question_budget v a ~init:(fun () -> []) ~merge:List.rev_append ~step:(fun acc b -> b :: acc) in
        List.map (fun b -> outer_asg @ List.filter_map (fun x -> if List.mem_assoc x outer_asg then None else Some (x, Store.value v t.typs.(x) b.(dense.(x)))) gout) bs)
      vs
  with
  | keys -> Some keys
  | exception Query.Bad _ -> None

(* frames of questions with operators answered by their keys, and those that took the whole question: for the tests *)
let keyed = Atomic.make 0
let whole = Atomic.make 0

(* the bindings a frame adds to and removes from a question with operators, as words of v1 and v0 *)
let whole_delta (v0 : Store.view) (v1 : Store.view) (t : template) (facts : (int * int * Value.t) list) =
  let keys = Hashtbl.create 16 and all = ref false in
  let enc k = let b = Buffer.create 32 in List.iter (fun (x, y) -> Codec.put_varint b x; Value.encode b y) (List.sort compare k); Buffer.contents b in
  let add k = Hashtbl.replace keys (enc k) k in
  List.iter
    (fun (fe, fp, fx) ->
      Array.iter
        (fun ((pt : Query.pattern), grp) ->
          if (not !all) && pt.p = fp then
            match assign pt fe fx with
            | None -> ()
            | Some asg -> (
              let outer_asg = List.filter (fun (x, _) -> t.outer.(x)) asg in
              match grp with
              | None -> if outer_asg = [] then all := true else add outer_asg
              | Some [ Ask.Optional { v = Var y; _ } ] ->
                (* an Optional's fact: the rows of its thing, whose value it adds, changes or takes away (missing) *)
                let k = List.filter (fun (x, _) -> x <> y) outer_asg in
                if k = [] then all := true else add k
              | Some items -> (
                let gout = List.filter (fun x -> t.outer.(x)) (List.sort_uniq compare (List.concat_map Ask.vars_of_item items)) in
                if gout = [] then all := true
                else if List.for_all (fun x -> List.mem_assoc x outer_asg) gout then add outer_asg
                else match group_keys [ v0; v1 ] t items asg outer_asg gout with Some ks -> List.iter add ks | None -> all := true)))
        t.occ)
    facts;
  (* a binding's key: its variables' words, and the mask of its missing ones (Optional) after them *)
  let bkey b = let buf = Buffer.create 32 in Array.iteri (fun x w -> if x >= Array.length t.outer || t.outer.(x) then Codec.put_int buf w) b; Buffer.contents buf in
  let set (v : Store.view) =
    let h = Hashtbl.create 64 in
    let put b = Hashtbl.replace h (bkey b) b in
    if !all then List.iter put (fixed_bindings v t.tq t.extra [])
    else Hashtbl.iter (fun _ k -> List.iter put (fixed_bindings v t.tq t.extra k)) keys;
    h
  in
  if Hashtbl.length keys = 0 && not !all then [], []
  else begin
    Atomic.incr (if !all then whole else keyed);
    let r0 = set v0 and r1 = set v1 in
    let minus a b = Hashtbl.fold (fun k x acc -> if Hashtbl.mem b k then acc else x :: acc) a [] in
    minus r1 r0, minus r0 r1
  end

(* the facts whose presence the groups change, with the sign of the change: a fact added and then retracted in one
   frame changes nothing *)
let net_changes (groups : Group.t list) =
  let net = Hashtbl.create 64 and order = ref [] in
  List.iter
    (fun (g : Group.t) ->
      Array.iter
        (fun (c : Group.change) ->
          let s = match c.kind with Added | Derived -> 1 | Retracted | Underived -> -1 | Now_asserted | Now_derived -> 0 in
          if s <> 0 then begin
            let k = c.e, c.p, c.v in
            match Hashtbl.find_opt net k with
            | Some d -> Hashtbl.replace net k (d + s)
            | None -> Hashtbl.replace net k s; order := k :: !order
          end)
        g.changes)
    groups;
  List.filter_map (fun k -> let d = Hashtbl.find net k in if d = 0 then None else Some (k, d)) (List.rev !order)

let give h tag out = if out <> [] then h.held <- h.held @ [ { tag; out } ]

let remove h s =
  if not s.gone then s.gone <- true;
  let t = s.t in
  (match Hashtbl.find_opt t.subs s.params with
   | Some l when List.memq s l ->
     let l = List.filter (fun x -> x != s) l in
     if l = [] then Hashtbl.remove t.subs s.params else Hashtbl.replace t.subs s.params l;
     t.count <- t.count - 1;
     Array.iteri
       (fun k y ->
         let c = Option.value (Hashtbl.find_opt t.slots.(k) y) ~default:1 - 1 in
         if c <= 0 then Hashtbl.remove t.slots.(k) y else Hashtbl.replace t.slots.(k) y c)
       s.params
   | _ -> ());
  if t.count = 0 then begin
    Hashtbl.remove h.templates t.tkey;
    Hashtbl.filter_map_inplace
      (fun _ l -> match List.filter (fun (t', _) -> t' != t) l with [] -> None | l -> Some l)
      h.by_prop
  end

(* the messages of the frames now durable, in order; a watch whose queue is full ends (lagging) *)
let release h =
  let rec go () =
    match h.held with
    | x :: rest when x.tag <= h.durable ->
      h.held <- rest;
      List.iter
        (fun (s, m) ->
          if not s.gone then
            if not (s.emit m) then begin
              remove h s;
              ignore (s.emit (Ended { code = "lagging"; message = "the watch fell behind: watch again from its group" }))
            end)
        x.out;
      go ()
    | _ -> ()
  in
  go ()

(* every watch ends: the database stopped, the stream of a local reader ended, or a frame came whose changes are not
   known (a large group, which the next answer covers) *)
let end_all h code message =
  h.held <- [];
  Hashtbl.iter
    (fun _ t -> Hashtbl.iter (fun _ ss -> List.iter (fun s -> if not s.gone then (s.gone <- true; ignore (s.emit (Ended { code; message })))) ss) t.subs)
    h.templates;
  Hashtbl.reset h.templates;
  Hashtbl.reset h.by_prop

(* A question that failed at a frame with what it did not expect (a bug, memory that ran out): logged (Fault), its
   watches told internal at once and dropped (what they had held is never sent); the other questions go on. *)
let failed h t e =
  Fault.log "a watched question at a frame" e;
  let ss = Hashtbl.fold (fun _ l acc -> List.rev_append l acc) t.subs [] in
  List.iter
    (fun s ->
      if not s.gone then begin
        remove h s;
        ignore (s.emit (Ended { code = "internal"; message = "the server failed on this watch's question (its log says why)" }))
      end)
    ss

(* A frame: its groups, and the state after them, under [tag]. Its messages are held until [durable] passes the tag. *)
let frame h ~tag (groups : Group.t list) (v1 : Store.view) =
  Mutex.protect h.hm (fun () ->
      let t0 = Journal.clock () in
      let v0 = h.view in
      let changes = net_changes groups in
      (* the ring of recent changes, for watches that resume *)
      let arr = Array.of_list (List.map fst changes) in
      if Array.length arr > 0 then begin
        Queue.push (v1.group, arr) h.ring;
        h.ring_n <- h.ring_n + Array.length arr;
        while h.ring_n > !ring_max do
          let g, a = Queue.pop h.ring in
          h.ring_n <- h.ring_n - Array.length a;
          h.ring_from <- g
        done
      end;
      if Hashtbl.length h.templates > 0 && changes <> [] then begin
        let plus = List.filter_map (fun (k, d) -> if d > 0 then Some k else None) changes
        and minus = List.filter_map (fun (k, d) -> if d < 0 then Some k else None) changes in
        let words (v : Store.view) l =
          let tbl = Hashtbl.create 16 in
          List.iter (fun (e, p, x) -> match Store.word v x with Some w -> Hashtbl.replace tbl (e, p, w) () | None -> ()) l;
          tbl
        in
        let touched = ref [] in
        let props = Hashtbl.create 8 in
        List.iter (fun (_, p, _) -> Hashtbl.replace props p ()) (List.map fst changes);
        let ts = Hashtbl.create 8 in
        Hashtbl.iter (fun p () -> List.iter (fun (t, _) -> Hashtbl.replace ts t.tkey t) (Option.value (Hashtbl.find_opt h.by_prop p) ~default:[])) props;
        let dplus = lazy (words v1 plus) and dminus = lazy (words v0 minus) in
        let wholes = ref [] and broken = ref [] and over = ref [] in
        (* what a question did not expect, in its changes or its rows, ends its own watches (failed); a damaged page
           ends every watch (below) *)
        let guard t f =
          match f () with
          | () -> ()
          | exception ((Pages.Unreadable _ | Query.Bad _) as e) -> raise e
          | exception e -> if not (List.exists (fun (t', _) -> t' == t) !broken) then broken := (t, e) :: !broken
        in
        let ok (s : sub) = not (s.gone || List.exists (fun (t, _) -> t == s.t) !broken) in
        (match
           Hashtbl.iter
             (fun _ t ->
               guard t @@ fun () ->
                 if t.extra <> [] then begin
                   let each f = Hashtbl.iter (fun _ ss -> List.iter (fun s -> if not s.gone then f s) ss) t.subs in
                   match whole_delta v0 v1 t (List.map fst changes) with
                   | added, removed ->
                     if added <> [] || removed <> [] then
                       each (fun s ->
                           if not s.touched then touched := s :: !touched;
                           List.iter (take v1 s 1) added;
                           List.iter (take v0 s (-1)) removed)
                   | exception Query.Over_budget n ->
                     each (fun s -> wholes := (s, Ended { code = "too_large"; message = Printf.sprintf "the question passed the server's budget of %d candidates" n }) :: !wholes)
                 end
                 else begin
                   if plus <> [] then side_bindings v1 t plus (Lazy.force dplus) 1 touched;
                   if minus <> [] then side_bindings v0 t minus (Lazy.force dminus) (-1) touched
                 end)
             ts;
           let out = ref [] in
           List.iter
             (fun s ->
               if ok s then
                 guard s.t @@ fun () ->
                 match finish v1 s with
                 | Some (added, removed) -> out := (s, Change { group = v1.group; added; removed }) :: !out
                 | None -> ()
                 (* a window's refill past the budget: that watch ends *)
                 | exception Query.Over_budget n -> over := (s, n) :: !over)
             (List.rev !touched);
           List.rev !out
         with
        | out ->
          List.iter (fun (t, e) -> failed h t e) (List.rev !broken);
          List.iter
            (fun (s, n) ->
              remove h s;
              ignore (s.emit (Ended { code = "too_large"; message = Printf.sprintf "the question passed the server's budget of %d candidates" n })))
            (List.rev !over);
          give h tag (List.filter (fun (s, _) -> not s.gone) (out @ List.rev !wholes))
        | exception (Pages.Unreadable m | Query.Bad m) -> end_all h "damaged" m)
      end;
      h.view <- v1;
      h.tag <- tag;
      Histogram.record frames_us (Journal.clock () - t0);
      release h)

(* the runs changed, the state did not (a merge): the newest state on its new runs *)
let rebase h (v : Store.view) = Mutex.protect h.hm (fun () -> if v.group = h.view.group then h.view <- v)

(* the frames of this tag or below are durable *)
let durable h tag = Mutex.protect h.hm (fun () -> if tag > h.durable then (h.durable <- tag; release h))

let stop h code message = Mutex.protect h.hm (fun () -> h.stopped <- Some (code, message); end_all h code message)

(* every watch ends with [code], and the hub starts again at [v], its ring empty *)
let restart h (v : Store.view) ~tag code message =
  end_all h code message;
  Queue.clear h.ring;
  h.ring_n <- 0;
  h.ring_from <- v.group;
  h.view <- v;
  h.tag <- tag

(* a frame whose changes are not given (a large group): every watch is asked again *)
let reset h (v : Store.view) ~tag =
  Mutex.protect h.hm (fun () -> restart h v ~tag "lagging" "a large group changed the database: watch again from its group")

(* What the hub's thread did not expect outside one question's work (a bug, memory that ran out): logged, every watch
   ends internal, and the hub goes on at [at] (the state of the frame that failed; None: its own), so that a watch made
   after it starts from the right state. *)
let broken h e at =
  Fault.log "the watches of a database" e;
  Mutex.protect h.hm (fun () ->
      let v, tag = match at with Some x -> x | None -> h.view, h.tag in
      restart h v ~tag "internal" "the server failed on this database's watches (its log says why): watch again")

(* does a change of the ring after group [n] touch the question: a fact of one of its patterns' properties that
   matches its constants *)
let touched_since h (q : Query.t) n =
  let hit (e, p, x) =
    List.exists
      (fun (pt : Query.pattern) ->
        pt.p = p
        && (match pt.e with Query.Var _ -> true | Thing c -> c = e | Val y -> Value.equal y (Link e))
        && match pt.v with Query.Var _ -> true | Thing c -> Value.equal x (Link c) | Val y -> Value.equal x y)
      q.where
  in
  Queue.fold (fun acc (g, a) -> acc || (g > n && Array.exists hit a)) false h.ring

(* A watch of [q] with [sel], resuming from group [from] (0: a new one): its first message is the answer at the hub's
   newest state, or Same when that answer is the one at [from] (the ring holds every change since and none touches
   the question), held until that state is durable; then a change after each frame that changes its rows. [emit] is
   called under the hub's lock and must not wait. With [order] (Sort, and Limit or none), its rows are Find's with
   that order, in it (a window, above). At the server, the first answer's cells are charged to [ticket] and its work
   is within [budget] (Answer) and [stop] (its deadline: Query.check); [admit] takes the watch, or refuses it by an
   exception, before it is kept. Raises Query.Bad for a question that is not valid, Query.Over_budget, Query.Timeout,
   Query.Cancelled, Answer.Too_large, and Pages.Unreadable. *)
(* the cells a watch keeps between its messages, four a value as its answer's: its window's rows, or its aggregate's
   keys (a plain watch keeps none of its rows) *)
let kept (s : sub) =
  match s.win with
  | Some w -> weight * w.n * max 1 (Array.length s.t.give)
  | None ->
    if Array.length s.t.aggs = 0 then 0
    else begin
      (* and the bags' values (Agg.entry_cells each), the exact sums' limbs (eight words, about) *)
      let extra =
        Hashtbl.fold
          (fun _ (k : key) n ->
            Array.fold_left (fun n -> function Some (Agg.Bag b) -> n + (b.live * Agg.entry_cells) | Some (Agg.Sums _) -> n + 8 | None -> n) n k.st)
          s.keys 0
      in
      (weight * Hashtbl.length s.keys * max 1 (Array.length s.t.give + Array.length s.t.aggs)) + (weight * extra)
    end

let subscribe ?(extra = []) ?(order = Top.none) ?ticket ?budget ?stop ?(admit = ignore) h (q : Query.t) (sel : Wire.select) ~from ~(emit : msg -> bool) =
  Mutex.protect h.hm (fun () ->
      (match h.stopped with Some (code, m) -> raise (Failure (code ^ ": " ^ m)) | None -> ());
      if order <> Top.none then begin
        (match sel with Wire.Group _ -> Query.bad "a watch of aggregates keeps every group: Sort and Limit are for a watch of Give" | Give _ -> ());
        if order.after <> None then Query.bad "a watch has no After: its rows are the first of its order, as they change";
        if order.keys = [] then Query.bad "a watch's Limit needs Sort: the engine's order is no order a watch can keep"
      end;
      let v = h.view in
      (* its Truncs are columns of its rows, not conditions: the template's own *)
      let truncs, extra = Ask.truncs extra in
      let tq, key, params =
        if extra = [] then (check ~truncs v q sel; templatize ~truncs q sel)
        else begin
          (* a question with Not, Or or In: one template a question, its constants its own *)
          let b = Buffer.create 64 in
          Buffer.add_char b 'W';
          Wire.put_query b q;
          Wire.put_select b sel;
          Wire.put_order b ~extra:(extra @ truncs) Top.none;
          q, Buffer.contents b, [||]
        end
      in
      let t =
        match Hashtbl.find_opt h.templates key with
        | Some t -> t
        | None -> if extra = [] then new_template ~truncs v key tq q.vars sel else whole_template ~truncs v key q sel extra
      in
      (* the order checked as Find checks it (its columns, its Limit: a client's bytes) before a window is made of it *)
      let win = if order = Top.none then None else (Top.check (Array.length t.give) [||] order; Some (new_window order (Array.length t.give))) in
      let s =
        { sid = h.next; t; params; q; emit; gone = false; keys = Hashtbl.create 8; touched = false; plus = []; minus = [];
          net = Hashtbl.create 8; before = Hashtbl.create 8; dirty = Hashtbl.create 8; win }
      in
      let first =
        if from > 0 && from >= h.ring_from && from <= v.group && not (touched_since h { q with where = all_patterns q extra } from) then begin
          (* the keys of an aggregate, and a window, are needed for the changes to come *)
          if Array.length t.aggs > 0 || win <> None then ignore (answer ?ticket ?budget ?stop v s);
          Same { group = v.group }
        end
        else Answer { group = v.group; rows = answer ?ticket ?budget ?stop v s }
      in
      (* the watch is taken or refused before any of it is kept *)
      admit s;
      h.next <- h.next + 1;
      if not (Hashtbl.mem h.templates key) then begin
        Hashtbl.replace h.templates key t;
        Array.iteri
          (fun i (pt : Query.pattern) -> Hashtbl.replace h.by_prop pt.p ((t, i) :: Option.value (Hashtbl.find_opt h.by_prop pt.p) ~default:[]))
          t.pats
      end;
      Hashtbl.replace t.subs params (s :: Option.value (Hashtbl.find_opt t.subs params) ~default:[]);
      Array.iteri (fun k y -> Hashtbl.replace t.slots.(k) y (1 + Option.value (Hashtbl.find_opt t.slots.(k) y) ~default:0)) params;
      t.count <- t.count + 1;
      give h h.tag [ (s, first) ];
      release h;
      s)

let unsubscribe h s = Mutex.protect h.hm (fun () -> remove h s)
