(* Sort, Limit and After over the rows of an answer, each row an array of index words (a column a variable of Give,
   or a group's key or aggregate).

   The order. Rows compare by their keys, each ascending or descending, then by every other column, ascending, in
   the order of the columns (the Cesia package lists them all, the other fields of Give by name), so that two rows
   compare equal only when they are the same row. Values compare within their type: the inline ones (ints, dates,
   money, bools, links) by their words, which keep their order; texts by their bytes (UTF-8: the order of their code
   points, RFC 3629, section 1); floats by IEEE 754's totalOrder (section 5.10).

   Limit k: the first k rows, and the copies of the k-th (a page never splits identical rows: SQL's WITH TIES, on the
   whole row). After r: the rows strictly after r. Without Sort, Limit takes the first k rows in the engine's order.

   Missing cells (Optional): the rows of a question with an Optional carry, after their columns, the mask of their
   missing ones (bit c: column c is missing, its word 0); a missing cell comes after every value, in both directions
   (SQL's NULLS LAST, for descending keys too), and equals another missing cell. A row of values (a watch's, After)
   holds Value.missing there.

   Two ways to the same rows (docs/book/cesia.md, "Sort, Limit and After"):
   - the heap path: every binding of the question, kept in a buffer of at most about 2 k rows that is sorted and cut
     back to its first k (and their ties) each time it fills: O(N log k) comparisons, O(k) rows held a domain;
   - the index path, when the first key is a column of an int, a date, money, a link or a text that a pattern gives
     as its value (a bool has two values: nothing to gain): the question asked again on windows of that column's
     values, read off the property's index from the cursor on (a text's in the order of its bytes, which each run
     keeps: Store.text_order), the first window of k facts, each next one at least twice the one before, until k rows
     are found. Its budget is half the planner's estimate of the heap path, in facts walked (a fact walked costs about
     twice a candidate of the heap): past it, the heap path answers, so the index path never costs more than about
     twice the heap path (the break-even rule of Karlin, Manasse, Rudolph and Sleator 1988); and it gives up sooner
     when its yield so far says the page cannot be filled within the budget (rows that lie far in the order). *)

type key = { col : int; desc : bool }

type order = { keys : key list; limit : int; after : Value.t array option }
(** [limit] 0: no limit. *)

let none = { keys = []; limit = 0; after = None }

(* the most rows a page: a bound against a question that asks the server to hold its whole answer sorted *)
let max_limit = 100_000

(* which path answers: Auto chooses; the others are for the tests and the benchmarks *)
type path = Auto | Heap | Index

let path = ref Auto

(* the windows the index path asked, those of them read off the things that hold a property (a sort by a thing), and
   how many times it gave up for the heap path: for the tests *)
let windows = Atomic.make 0
let held = Atomic.make 0
let gave_up = Atomic.make 0

let bad = Query.bad

(* IEEE 754's totalOrder on two floats: -NaN < -inf < ... < -0 < +0 < ... < +inf < +NaN *)
let total_order = Value.total_order

let float_of_word v w = Int64.float_of_bits (String.get_int64_le (Store.text v w) 0)

let compare_words v (ty : Value.typ) (a : int) b =
  if a = b then 0
  else
    match ty with
    | Ttext -> String.compare (Store.text v a) (Store.text v b)
    | Tfloat -> total_order (float_of_word v a) (float_of_word v b)
    | _ -> compare a b

(* every column in the order: the keys, then the others ascending *)
let full cols keys =
  let listed = Array.make cols false in
  List.iter (fun k -> listed.(k.col) <- true) keys;
  Array.of_list (keys @ List.filter_map (fun c -> if listed.(c) then None else Some { col = c; desc = false }) (List.init cols Fun.id))

let compare_rows v (typs : Value.typ array) (ord : key array) (a : int array) (b : int array) =
  let c = ref 0 and i = ref 0 in
  while !c = 0 && !i < Array.length ord do
    let k = ord.(!i) in
    let x = compare_words v typs.(k.col) a.(k.col) b.(k.col) in
    c := if k.desc then -x else x;
    incr i
  done;
  !c

(* is column c of a row of [cols] columns missing (its mask after them) *)
let[@inline] missing cols (r : int array) c = (Array.unsafe_get r cols lsr c) land 1 = 1

(* two cells' order when one is missing, or 0: a missing cell after a value, in both directions *)
let[@inline] by_mask ma mb = if ma = mb then 0 else if ma then 1 else -1

(* [compare_rows] of rows with a mask after their [cols] columns *)
let compare_masked v (typs : Value.typ array) (ord : key array) (a : int array) (b : int array) =
  let cols = Array.length typs in
  let c = ref 0 and i = ref 0 in
  while !c = 0 && !i < Array.length ord do
    let k = ord.(!i) in
    let ma = missing cols a k.col and mb = missing cols b k.col in
    if ma || mb then c := by_mask ma mb
    else (let x = compare_words v typs.(k.col) a.(k.col) b.(k.col) in c := if k.desc then -x else x);
    incr i
  done;
  !c

(* rows of values (a watch's, Live) in the order [ord], as compare_rows orders their words: an int, a date, money or a
   link is its own word (Store.word), a bool 0 or 1; Value.missing after every value, in both directions *)
let compare_values (a : Value.t) (b : Value.t) =
  match a, b with
  | Text x, Text y -> String.compare x y
  | Float x, Float y -> total_order x y
  | (Int x | Date x | Money x | Link x), (Int y | Date y | Money y | Link y) -> compare x y
  | Bool x, Bool y -> compare x y
  | _ -> compare a b

let compare_value_rows (ord : key array) (a : Value.t array) (b : Value.t array) =
  let c = ref 0 and i = ref 0 in
  while !c = 0 && !i < Array.length ord do
    let k = ord.(!i) in
    let x = a.(k.col) and y = b.(k.col) in
    let ma = Value.is_missing x and mb = Value.is_missing y in
    if ma || mb then c := by_mask ma mb
    else (let x = compare_values x y in c := if k.desc then -x else x);
    incr i
  done;
  !c

(* a cursor's cell, ready to compare with a word; M: missing *)
type cell = W of int | S of string | F of float | M

let cell v (ty : Value.typ) name (x : Value.t) =
  if Value.is_missing x then M
  else begin
    if not (Value.has_type ty x) then bad "After's %s needs a %s, not %s" name (Value.typ_name ty) (Value.to_string x);
    match x with
    | Text s -> S s
    | Float f -> F f
    | x -> (match Store.word v x with Some w -> W w | None -> bad "After's %s: %s" name (Value.to_string x))
  end

(* a row against the cursor: > 0 when the row comes after it; [masked]: the row has its mask after its columns *)
let compare_cursor ?(masked = false) v (typs : Value.typ array) (ord : key array) (row : int array) (cur : cell array) =
  let cols = Array.length typs in
  let c = ref 0 and i = ref 0 in
  while !c = 0 && !i < Array.length ord do
    let k = ord.(!i) in
    let w = row.(k.col) in
    let mr = masked && missing cols row k.col and mc = cur.(k.col) = M in
    if mr || mc then c := by_mask mr mc
    else begin
      let x =
        match cur.(k.col) with
        | W u -> compare w u
        | S s -> String.compare (Store.text v w) s
        | F f -> total_order (float_of_word v w) f
        | M -> 0
      in
      c := if k.desc then -x else x
    end;
    incr i
  done;
  !c

(* ---- the buffer of the heap path ---- *)

type acc = { mutable a : int array array; mutable n : int }

let fresh () = { a = [||]; n = 0 }

(* The comparator of one sort, made by [mk ()]: the rows in [ord]; when a key is a text, each text is read once a sort,
   into a table of the sort's own (a sort of n rows compares a row's texts about log n times, each a read of a run's
   pages: the clients sorted by name, then by city for the clients of one name), so that the heap path's domains,
   each sorting its own buffer, share none *)
let sorter ?(masked = false) v (typs : Value.typ array) (ord : key array) =
  if masked then (let c = compare_masked v typs ord in fun () -> c)
  else if not (Array.exists (fun k -> typs.(k.col) = Value.Ttext) ord) then (let c = compare_rows v typs ord in fun () -> c)
  else fun () ->
    let memo = Hashtbl.create 64 in
    let text w = match Hashtbl.find_opt memo w with Some s -> s | None -> let s = Store.text v w in Hashtbl.add memo w s; s in
    fun (a : int array) (b : int array) ->
      let c = ref 0 and i = ref 0 in
      while !c = 0 && !i < Array.length ord do
        let k = ord.(!i) in
        let x = a.(k.col) and y = b.(k.col) in
        let r =
          if x = y then 0
          else match typs.(k.col) with Ttext -> String.compare (text x) (text y) | Tfloat -> total_order (float_of_word v x) (float_of_word v y) | _ -> compare x y
        in
        c := if k.desc then -r else r;
        incr i
      done;
      !c

let sort_cut mk cap t =
  let cmp = mk () in
  let s = Array.sub t.a 0 t.n in
  Array.stable_sort cmp s;
  let n = if cap > 0 && t.n > cap then (let m = ref cap in while !m < t.n && cmp s.(cap - 1) s.(!m) = 0 do incr m done; !m) else t.n in
  t.a <- s;
  t.n <- n

let push mk cap t row =
  if t.n = Array.length t.a then begin
    let a = Array.make (max 64 (2 * t.n)) [||] in
    Array.blit t.a 0 a 0 t.n;
    t.a <- a
  end;
  t.a.(t.n) <- row;
  t.n <- t.n + 1;
  if cap > 0 && t.n >= max 64 (2 * cap) then sort_cut mk cap t

let append mk cap a b =
  for i = 0 to b.n - 1 do push mk cap a b.a.(i) done;
  a

(* ---- the answer ---- *)

(* A window of the index path: one more range [lo <= x <= hi] on a variable, or the words it may take (sorted). *)
type window = Range of int * Value.t * Value.t | Words of int * int array

(* The index the index path reads for x, the first key's variable: [Value_of p], the property of a pattern that gives x
   as its value (p's rows by value); [Holder], the property of a pattern whose thing is x, with the word of its value
   when it is a constant (the things of p, or of the fact (p, w), by their ids), and the ids the question's ranges on
   x leave, lo to hi. *)
type lead = Value_of of int | Holder of { p : int; value : int option; lo : int; hi : int }

(* [fold window ~seq ~init ~step ~merge]: the question's bindings (an env of index words a binding), within a window
   when one is given. [project env]: the row of a binding. [var col]: the
   variable a column gives, if it is one. [lead x]: the index of a pattern on x, if any ({!lead}).
   [estimate ()]: the planner's estimate of the question's work. *)
type source = {
  fold : 'a. window option -> seq:bool -> init:(unit -> 'a) -> step:('a -> int array -> 'a) -> merge:('a -> 'a -> 'a) -> 'a;
  project : int array -> int array;
  var : int -> int option;
  lead : int -> lead option;
  estimate : unit -> float;
}

exception Enough

(* The 99 % upper bound of the mean of a Poisson count of x (one-sided): the most hopeful yield of a walk that found
   x rows. Exact, it is half the chi-square quantile of 2x + 2 degrees (Garwood 1936); here by the cube-root
   approximation of Wilson and Hilferty 1931 (Byar's formula, in Breslow and Day 1987), within 0.2 % of the exact bound
   for x from 0 to 199 (4.61 for x = 0, the exact -ln 0.01 = 4.605). A walk given up on it when it would have filled
   the page within its budget needs a yield above that bound: under 1 in 100 at each window for rows spread evenly
   in the order. *)
let poisson_upper x =
  let n = float_of_int (x + 1) in
  let t = 1. -. (1. /. (9. *. n)) +. (2.326 /. (3. *. sqrt n)) in
  n *. t *. t *. t

let check cols (typs : Value.typ array) o =
  List.iter (fun k -> if k.col < 0 || k.col >= cols then bad "Sort: column %d out of range" k.col) o.keys;
  if o.limit < 0 then bad "Limit needs a number of rows of 1 or more, not %d" o.limit;
  if o.limit > max_limit then bad "Limit: at most %d rows a page, not %d" max_limit o.limit;
  if List.length o.keys > cols then bad "Sort: at most one key a column";
  match o.after with
  | Some a ->
    if o.keys = [] then bad "After needs Sort: the rows after a row, in an order";
    if Array.length a <> cols then bad "After needs a value for each of the %d columns, not %d" cols (Array.length a);
    ignore typs
  | None -> ()

let word_value (ty : Value.typ) w : Value.t =
  match ty with
  | Tint -> Int w
  | Tdate -> Date w
  | Tmoney _ -> Money w
  | Tlink -> Link w
  | Tbool | Ttext | Tfloat -> invalid_arg "Top.word_value"

(* the rows of a question's Give, in the order [o]; [masked]: each row has the mask of its missing cells after its
   columns (Optional) *)
let give ?(masked = false) (v : Store.view) ~(typs : Value.typ array) (src : source) (o : order) : int array array =
  let cols = Array.length typs in
  check cols typs o;
  if o.keys = [] then begin
    (* Limit alone: the first k rows in the engine's order, on one domain, stopped once there *)
    let rows = ref [] and k = ref 0 in
    (try
       ignore
         (src.fold None ~seq:true ~init:(fun () -> [||]) ~merge:(fun a _ -> a)
            ~step:(fun a env -> rows := src.project env :: !rows; incr k; if o.limit > 0 && !k >= o.limit then raise Enough; a))
     with Enough -> ());
    Array.of_list (List.rev !rows)
  end
  else begin
    let ord = full cols o.keys in
    let mk = sorter ~masked v typs ord in
    let keep =
      match o.after with
      | None -> fun _ -> true
      | Some a ->
        let cur = Array.mapi (fun i x -> cell v typs.(i) (string_of_int i) x) a in
        fun row -> compare_cursor ~masked v typs ord row cur > 0
    in
    let cap = o.limit in
    let heap range =
      let acc =
        src.fold range ~seq:false ~init:fresh ~merge:(append mk cap)
          ~step:(fun t env -> let r = src.project env in if keep r then push mk cap t r; t)
      in
      sort_cut mk cap acc;
      acc
    in
    let first = List.hd o.keys in
    (* the planner's estimate of the heap path's work, once: the index path's budget, and its choice *)
    let estimate = lazy (src.estimate ()) in
    (* a cursor missing in the first key: the heap (the index holds no missing cell) *)
    let after_missing = match o.after with Some a -> Value.is_missing a.(first.col) | None -> false in
    let lead =
      match src.var first.col with
      | _ when after_missing -> None
      | Some x when (Value.inline typs.(first.col) && typs.(first.col) <> Tbool) || typs.(first.col) = Ttext ->
        (match src.lead x with Some l -> Some (x, l) | None -> None)
      | _ -> None
    in
    (* the windows of x's values in the order of the first key, from the cursor on: [next m] gives the next one, of
       about m facts, its facts and whether it is the last; each window's rows are those of the question asked on it,
       and every row of a later window comes after every row of an earlier one, so k rows found end the walk. The walk
       reads at most half the heap's estimate in facts, its last window cut to what is left: a fact walked costs about
       twice a candidate of the heap (0.41 to 0.55 us against 0.28 on the invoices app's clients), so the walk given
       up costs about the heap's own time, and the whole about twice the heap's at worst. The first window holds k
       facts (the page's rows when each fact gives one: a list without a filter reads its page and no more); each next
       one twice the one before, or more when the yield so far says the page needs more: the facts the missing rows
       need at the most hopeful yield (the Poisson bound below), which it needs with a probability of 99 % or more *)
    let windowed ?(opening = cap) next =
      let budget = Lazy.force estimate /. 2. in
      let got = fresh () and spent = ref 0 and m = ref opening and over = ref false and found = ref None in
      while !found = None && not !over do
        let win, facts, last = next !m in
        Atomic.incr windows;
        spent := !spent + facts;
        (match win with
         | Some win ->
           let w = heap (Some win) in
           for i = 0 to w.n - 1 do push mk cap got w.a.(i) done;
           sort_cut mk cap got
         | None -> ());
        if got.n >= cap || last then found := Some got
        else begin
          let left = budget -. float_of_int !spent in
          (* the page's rows still missing, at the most hopeful yield the walk so far allows: the walk is given up
             when even they need more facts than the budget has left (rows that come late in the order) *)
          let need = float_of_int (cap - got.n) *. float_of_int !spent /. poisson_upper got.n in
          (* an estimate past the ints (a cross product's) cuts nothing: int_of_float would give 0 there *)
          let int f = if f >= 1e18 then max_int else int_of_float (Float.ceil f) in
          if left <= 0. || need > left then over := true
          else m := max 1 (min (max (2 * !m) (int need)) (int left))
        end
      done;
      match !found with Some g -> g | None -> Atomic.incr gave_up; heap None
    in
    (* an int, a date, money or a link: the values' words keep their order, so a window is a range of words read off
       p's index, of m facts *)
    let ranges (x, p) =
      let ty = typs.(first.col) in
      let mk w = word_value ty w in
      let edge =
        ref
          (match o.after with
           | Some a -> (match cell v ty "" a.(first.col) with W w -> w | _ -> assert false)
           | None -> if first.desc then max_int else min_int)
      in
      windowed (fun m ->
          let lo, hi, last =
            if first.desc then begin
              let hi = !edge in
              let left = Store.count_range v p min_int hi in
              if left <= m then (min_int, hi, true)
              else begin
                (* the largest lo whose window [lo, hi] holds m facts: searched from a bound of it (Store.nth_bound)
                   when the bound's window holds them, from min_int else *)
                let bot = match Store.nth_bound v p hi m ~desc:true with Some l when Store.count_range v p l hi >= m -> l | _ -> min_int in
                let a = ref bot and b = ref hi in
                while !a < !b do
                  let mid = (!a asr 1) + (!b asr 1) + (!a land !b land 1) + 1 in
                  if Store.count_range v p mid hi >= m then a := mid else b := mid - 1
                done;
                (!a, hi, !a = min_int)
              end
            end
            else begin
              let lo = !edge in
              let left = Store.count_range v p lo max_int in
              if left <= m then (lo, max_int, true)
              else begin
                (* the least hi whose window [lo, hi] holds m facts, likewise *)
                let top = match Store.nth_bound v p lo m ~desc:false with Some u when Store.count_range v p lo u >= m -> u | _ -> max_int in
                let a = ref lo and b = ref top in
                while !a < !b do
                  let mid = (!a asr 1) + (!b asr 1) + (!a land !b land 1) in
                  if Store.count_range v p lo mid >= m then b := mid else a := mid + 1
                done;
                (lo, !a, !a = max_int)
              end
            end
          in
          if not last then edge := if first.desc then lo - 1 else hi + 1;
          (Some (Range (x, mk lo, mk hi)), Store.count_range v p lo hi, last))
    in
    (* a text: its words do not keep the order of the bytes, but each run keeps p's texts in that order (run format
       9): a window is the next texts of that order, merged over the runs and the delta (Store.text_order), until they
       hold m facts, the question asked with x one of them *)
    let texts (x, p) =
      let from = match o.after with Some a -> (match cell v Ttext "" a.(first.col) with S s -> Some s | _ -> assert false) | None -> None in
      let next = Store.text_order v p ~desc:first.desc ~from in
      let ended = ref false in
      windowed (fun m ->
          let ws = ref [] and facts = ref 0 in
          while (not !ended) && !facts < m do
            let w = next () in
            if w < 0 then ended := true else (ws := w :: !ws; facts := !facts + Store.count_things v p w)
          done;
          let ws = Array.of_list !ws in
          Array.sort compare ws;
          ((if Array.length ws = 0 then None else Some (Words (x, ws))), !facts, !ended))
    in
    (* a thing x that holds p (the fact (p, w) when the pattern's value is a constant): the things of the order from
       the cursor on, read off p's column (off the rows of (p, w)) in the order of their ids, merged over the runs and
       the delta (Store.holders_from); a window is the next m of them, the question asked with x one of them. A list
       of a kind by its things' ids, from a cursor, reads its page and no more *)
    let holders x p value lo hi =
      let from =
        match o.after with
        | Some a -> (match cell v Tlink "" a.(first.col) with W w -> w | _ -> assert false)
        | None -> if first.desc then max_int else min_int
      in
      (* from the cursor, or the first id the ranges on x leave; to their last *)
      let from = if first.desc then min from hi else max from lo in
      let next = Store.holders_from v p ?value ~desc:first.desc ~from () in
      let next () = let e = next () in if e < lo || e > hi then -1 else e in
      let ended = ref false in
      (* after a cursor, its own thing first, whose rows may come after it in the order (by the other columns), and
         then the page's: k + 1 things in the first window *)
      windowed ~opening:(if o.after = None then cap else cap + 1) (fun m ->
          Atomic.incr held;
          let ws = ref (Array.make (min m 4096) 0) and k = ref 0 in
          while (not !ended) && !k < m do
            let e = next () in
            if e < 0 then ended := true
            else begin
              if !k = Array.length !ws then (let a = Array.make (2 * !k) 0 in Array.blit !ws 0 a 0 !k; ws := a);
              Array.unsafe_set !ws !k e;
              incr k
            end
          done;
          (* the words of a window, ascending: those of a descending walk reversed *)
          let ws = Array.sub !ws 0 !k in
          if first.desc then (let n = !k in for i = 0 to (n / 2) - 1 do let t = ws.(i) in ws.(i) <- ws.(n - 1 - i); ws.(n - 1 - i) <- t done);
          ((if !k = 0 then None else Some (Words (x, ws))), !k, !ended))
    in
    let index (x, l) =
      match l with
      | Holder { p; value; lo; hi } -> holders x p value lo hi
      | Value_of p ->
        if typs.(first.col) <> Ttext then ranges (x, p)
        else if float_of_int (Store.delta_values v p) > Lazy.force estimate then
          (* the delta's texts of p are sorted before the first window: past the heap's estimate, the heap answers *)
          (Atomic.incr gave_up; heap None)
        else texts (x, p)
    in
    let use_index =
      cap > 0
      && lead <> None
      && match !path with Heap -> false | Index -> true | Auto -> Lazy.force estimate > float_of_int (4 * cap)
    in
    let acc = match lead with Some l when use_index -> index l | _ -> heap None in
    Array.sub acc.a 0 acc.n
  end

(* The index the index path reads for x: a property of a pattern that gives x as its value, the one with the fewest
   facts; else, x a thing, a property of a pattern whose thing is x, the one with the fewest facts (of its constant
   value when it has one, as a tenant's things): every row's x holds it, and lies in the question's ranges on x *)
let lead (v : Store.view) (q : Query.t) x =
  let by_value =
    List.fold_left
      (fun best (pt : Query.pattern) ->
        match pt.v, best with
        | Var y, None when y = x -> Some pt.p
        | Var y, Some b when y = x && Store.count_prop v pt.p < Store.count_prop v b -> Some pt.p
        | _ -> best)
      None q.where
  in
  match by_value with
  | Some p -> Some (Value_of p)
  | None ->
    let held =
      List.filter_map
        (fun (pt : Query.pattern) ->
          match pt.e, pt.v with
          | Var y, Var z when y = x && z <> x -> Some ((pt.p, None), Store.count_prop v pt.p)
          | Var y, (Thing c | Val (Value.Link c)) when y = x -> let w = Query.rep v c in Some ((pt.p, Some w), Store.count_things v pt.p w)
          | Var y, Val c when y = x -> (match Store.word v c with Some w -> Some ((pt.p, Some w), Store.count_things v pt.p w) | None -> None)
          | _ -> None)
        q.where
    in
    let lo, hi =
      List.fold_left
        (fun (lo, hi) (y, a, b) ->
          match y = x, Store.word v a, Store.word v b with
          | true, Some a, Some b -> Stdlib.max lo a, Stdlib.min hi b
          | _ -> lo, hi)
        (min_int, max_int) q.ranges
    in
    match List.sort (fun (_, a) (_, b) -> compare (a : int) b) held with
    | ((p, value), _) :: _ -> Some (Holder { p; value; lo; hi })
    | [] -> None

(* rows held already (a group's key and aggregates), in the order [o]; [masked]: as [give]'s *)
let sort_rows ?(masked = false) (v : Store.view) ~(typs : Value.typ array) (o : order) (rows : int array array) =
  let cols = Array.length typs in
  check cols typs o;
  if o.keys = [] then (if o.limit > 0 && Array.length rows > o.limit then Array.sub rows 0 o.limit else rows)
  else begin
    let ord = full cols o.keys in
    let rows =
      match o.after with
      | None -> rows
      | Some a ->
        let cur = Array.mapi (fun i x -> cell v typs.(i) (string_of_int i) x) a in
        Array.of_list (List.filter (fun r -> compare_cursor ~masked v typs ord r cur > 0) (Array.to_list rows))
    in
    let t = { a = Array.copy rows; n = Array.length rows } in
    sort_cut (sorter ~masked v typs ord) o.limit t;
    Array.sub t.a 0 t.n
  end
