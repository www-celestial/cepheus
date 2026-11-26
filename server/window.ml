(* Windows (protocol 10): columns computed from the rows of an answer in Sort's order, within each group of Each, the
   same code at the server and in a program that reads locally (Answer). Exact meaning: docs/book/cesia.md, "Windows".

   - The rows. A window reads the rows of the answer it is over (a Give's, or a report's groups) in Sort's order: its
     keys, then every other column ascending, so that two rows equal in the order are the same row (Top) and a window's
     value does not depend on how the engine found them. Each's columns cut the rows into groups (SQL's PARTITION BY):
     a window starts again at each group's first row; the rows still come in Sort's order.
   - Running (a, last): the aggregate a of a column over a frame of the group's rows: from its first row to this one
     (last 0: SQL's ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), or this row and the last - 1 before it (ROWS
     BETWEEN last - 1 PRECEDING AND CURRENT ROW). Count counts the frame's rows (SQL's count of rows: Running (Count, 0) is
     row_number()); Sum, Avg, Min and Max the column's values, a missing value left out as SQL leaves out NULL, a frame
     with none missing. Rank (keys, dense): 1 + the rows of the group before this one in the first [keys] keys of
     Sort (rank(): rows equal in them share a place, 1, 2, 2, 4), or 1 + the different places before (dense_rank():
     1, 2, 2, 3). Prev (c, back): column c of the row [back] rows before this one in its group (lag(c, back)),
     missing for the group's first [back] rows.
   - Algorithms (Leis, Kundhikanjana, Kemper, Neumann, "Efficient Processing of Window Functions in Analytical SQL
     Queries", PVLDB 8(10), 2015, section 4): the rows of each group listed once in order (a counting sort of their
     groups, O(n)); a frame that only grows keeps its aggregate as it goes (their cumulative aggregation); a frame of
     the last n rows adds the row that comes and takes out the one that goes (their removable cumulative
     aggregation), which Sum and Avg allow exactly here: their sums are exact integers (Agg.Exact, as a report's), so
     taking a value out leaves the same sums as never adding it, where floats would drift (the paper's warning). Min
     and Max over the last n rows, which no subtraction undoes, by a monotone queue of the frame's candidates (each
     row in and out once: O(1) amortized a row; Lemire, "Streaming maximum-minimum filter using no more than three
     comparisons per element", Nordic Journal of Computing 13(4), 2006), where the paper's segment tree takes O(log n)
     a row for any frame. So a window costs O(n) for n rows, whatever its frame. *)

open Cepheus
module Top = Question.Top

(* the most rows a frame or a Prev reaches back: a page's (Top.max_limit) *)
let max_frame = Top.max_limit

let bad = Query.bad

(* the type of a window's value, from its columns' *)
let typ (typs : int -> Value.typ) : Wire.window -> Value.typ = function
  | Running (Count, _) | Rank _ -> Tint
  | Running (a, _) -> (match Agg.var_of a with Some c -> Agg.typ a (typs c) | None -> Tint)
  | Prev (c, _) -> typs c

let name = function Wire.Running _ -> "Running" | Rank _ -> "Rank" | Prev _ -> "Prev"

(* A select's windows and Each checked against the columns of the rows they are over: [cols] of them, of types
   [typs], [key c] whether column c is a key of the rows (a Give's every column, a report's keys), [list c] whether
   it is a list (Values: no window reads it), [order] the Sort, Limit and After. Raises Query.Bad. *)
let check ~cols ~(typs : int -> Value.typ) ~key ~list (each : int array) (windows : Wire.window array) (o : Top.order) =
  let column what c =
    if c < 0 || c >= cols then bad "%s: column %d out of range" what c;
    if list c then bad "%s takes no Values column: it is a list" what
  in
  if Array.length windows > Wire.max_windows then bad "at most %d windows, not %d" Wire.max_windows (Array.length windows);
  if o.keys = [] then begin
    if windows <> [||] then bad "%s needs Sort: a window reads the rows in an order" (name windows.(0));
    if each <> [||] then bad "Each needs Sort: the first rows of each group, or its windows, are in an order"
  end;
  if each <> [||] then begin
    if windows = [||] && o.limit = 0 then bad "Each is for Limit or a window (Running, Rank, Prev): this question has neither";
    if o.after <> None then bad "Each takes no After: with Each, Limit is each group's, so a page has no last row to go on from; ask a page of the groups, then their rows (In)";
    Array.iteri
      (fun i c ->
        column "Each" c;
        if not (key c) then bad "Each takes the keys of a report, not its aggregates: column %d" c;
        for j = 0 to i - 1 do if each.(j) = c then bad "Each: column %d twice" c done)
      each
  end;
  Array.iter
    (function
      | Wire.Running (a, last) -> (
        if last < 0 || last > max_frame then bad "Running's last is 1 to %d rows (0: from the first row), not %d" max_frame last;
        match a with
        | Wire.Count -> ()
        | Sum c -> (
          column "Running" c;
          match typs c with Tint | Tmoney _ -> () | t -> bad "Running's Sum is of ints and money, not a %s" (Value.typ_name t))
        | Avg c -> (
          column "Running" c;
          match typs c with Tint | Tfloat | Tmoney _ | Tdate -> () | t -> bad "Running's Avg is of ints, floats, money and dates, not a %s" (Value.typ_name t))
        | Min c | Max c -> (
          column "Running" c;
          match typs c with
          | Tint | Tmoney _ | Tdate -> ()
          | t -> bad "Running's %s is of ints, money and dates, not a %s" (Agg.name a) (Value.typ_name t))
        | a -> bad "Running takes Sum, Avg, Min or Max of a column, or Count(), not %s" (Agg.name a))
      | Rank (keys, _) ->
        let n = List.length o.keys in
        if keys < 1 || keys > n then bad "Rank ranks by 1 to %d keys of Sort, not %d" n keys
      | Prev (c, back) ->
        column "Prev" c;
        if back < 1 || back > max_frame then bad "Prev goes back 1 to %d rows, not %d" max_frame back)
    windows

(* ---- the windows of rows ---- *)

(* The rows of each group in their order: [off.(g)] to [off.(g + 1) - 1] in [rows], by a counting sort of the
   groups of rows 0 to n - 1 (each group's in the order of the rows) *)
let members n groups (part : int -> int) =
  let off = Array.make (groups + 1) 0 in
  let gs = Array.init n part in
  Array.iter (fun g -> off.(g + 1) <- off.(g + 1) + 1) gs;
  for g = 1 to groups do off.(g) <- off.(g) + off.(g - 1) done;
  let at = Array.sub off 0 (max 1 groups) and rows = Array.make n 0 in
  Array.iteri (fun i g -> rows.(at.(g)) <- i; at.(g) <- at.(g) + 1) gs;
  off, rows

let compare_values = Top.compare_values

(* a running sum past 63 bits, in the cell of its row: the question is refused only when that row is one it gives
   (a row past the page's last is no part of the answer) *)
let past = Value.Text "running sum past 63 bits"

let check_past (out : Value.t array array) idx =
  Array.iter (fun w -> Array.iter (fun i -> if w.(i) == past then bad "Running's Sum passed the 63 bits of an Int: sum fewer rows (last = n)") idx) out

(* Where the rows of a page start in their one group (After, Answer): the [skip] rows given first are the last of
   the rows before the page (as many as a frame or a Prev reaches back), whose values are not asked; [offset] rows of
   the group come before them; and for each window, what the rows before the page give it: the exact sums and the
   best value of every row before the page (the [skip] rows included), the place of the page's first row. *)
type init = I_none | I_sums of Agg.sums | I_best of Value.t | I_rank of int * int
type start = { skip : int; offset : int; init : init array }

(* [compute ~view ~n ~groups ~part ~get ~tie ~typs windows]: each window's value for each of n rows given in Sort's
   order, [part i] the group of row i (0 to groups - 1), [get i c] column c of row i, [tie k i j] whether rows i and j
   are equal in the first k keys of Sort. out.(w).(i), [past] where a running sum passed 63 bits (check_past). *)
let compute ?start ~(view : Store.view) ~n ~groups ~part ~(get : int -> int -> Value.t) ~(tie : int -> int -> int -> bool)
    ~(typs : int -> Value.typ) (windows : Wire.window array) =
  let off, rows = members n groups part in
  (* a page's one group: its rows' places from [offset], the first [skip] counted already *)
  let skip, offset = match start with Some s -> s.skip, s.offset | None -> 0, 0 in
  let init wi = match start with Some s -> s.init.(wi) | None -> I_none in
  (* a column's values once (a text's read once) *)
  let cache = Hashtbl.create 4 in
  let column c =
    match Hashtbl.find_opt cache c with
    | Some a -> a
    | None -> let a = Array.init n (fun i -> get i c) in Hashtbl.add cache c a; a
  in
  Array.mapi
    (fun wi (w : Wire.window) ->
      let out = Array.make n Value.missing in
      (match w with
       | Running (Count, last) ->
         for g = 0 to groups - 1 do
           for p = 0 to off.(g + 1) - off.(g) - 1 do
             let a = offset + p + 1 in
             out.(rows.(off.(g) + p)) <- Int (if last > 0 then min a last else a)
           done
         done
       | Running (((Sum c | Avg c) as a), last) ->
         let x = column c and tx = typs c in
         let mk = match tx with Tmoney _ -> fun s -> Value.Money s | Tdate -> fun s -> Value.Date s | _ -> fun s -> Value.Int s in
         for g = 0 to groups - 1 do
           (* from the first row, a page's sums start with every row before it, its first [skip] rows among them *)
           let s, from = match init wi with I_sums s0 when last = 0 -> s0, skip | _ -> Agg.value_sums (), 0 in
           let o = off.(g) in
           for p = 0 to off.(g + 1) - o - 1 do
             let i = rows.(o + p) in
             if p >= from && not (Value.is_missing x.(i)) then Agg.add_value s 1 x.(i);
             (if last > 0 && p >= last then let j = rows.(o + p - last) in if not (Value.is_missing x.(j)) then Agg.add_value s (-1) x.(j));
             out.(i) <-
               (if s.n <= 0 then Value.missing
                else
                  match a with
                  | Sum _ -> (
                    match Agg.sum_int s with
                    | Some v -> mk v
                    | None -> past)
                  | _ -> Agg.result view a tx (Agg.Sums s))
           done
         done
       | Running (((Min c | Max c) as a), 0) ->
         let x = column c and sign = match a with Min _ -> -1 | _ -> 1 in
         for g = 0 to groups - 1 do
           (* the best of every row before a page: a min or a max takes its first [skip] rows again, a same answer *)
           let best = ref (match init wi with I_best b -> b | _ -> Value.missing) in
           for p = off.(g) to off.(g + 1) - 1 do
             let i = rows.(p) in
             let v = x.(i) in
             if not (Value.is_missing v) && (Value.is_missing !best || sign * compare_values v !best > 0) then best := v;
             out.(i) <- !best
           done
         done
       | Running (((Min c | Max c) as a), last) ->
         (* the frame's candidates, by their places in the group: each later than the one before, and better than it
            (larger for Max), so that the first is the frame's best; a row that comes takes out those it beats *)
         let x = column c and sign = match a with Min _ -> -1 | _ -> 1 in
         let q = Array.make (min (last + 1) (max 1 (n + 1))) 0 in
         let cap = Array.length q in
         for g = 0 to groups - 1 do
           let o = off.(g) in
           let head = ref 0 and len = ref 0 in
           for p = 0 to off.(g + 1) - o - 1 do
             let i = rows.(o + p) in
             let v = x.(i) in
             if not (Value.is_missing v) then begin
               while !len > 0 && sign * compare_values x.(rows.(o + q.((!head + !len - 1) mod cap))) v <= 0 do decr len done;
               q.((!head + !len) mod cap) <- p;
               incr len
             end;
             while !len > 0 && q.(!head) <= p - last do head := (!head + 1) mod cap; decr len done;
             out.(i) <- (if !len = 0 then Value.missing else x.(rows.(o + q.(!head))))
           done
         done
       | Running (_, _) -> assert false
       | Rank (k, dense) ->
         for g = 0 to groups - 1 do
           let rank = ref 0 and d = ref 0 in
           for p = off.(g) to off.(g + 1) - 1 do
             let i = rows.(p) in
             let q = p - off.(g) in
             (match init wi with
              | I_rank (r0, d0) when q = skip -> rank := r0; d := d0
              | _ -> if q = 0 || not (tie k rows.(p - 1) i) then (rank := offset + q + 1; incr d));
             out.(i) <- Int (if dense then !d else !rank)
           done
         done
       | Prev (c, back) ->
         let x = column c in
         for g = 0 to groups - 1 do
           for p = off.(g) + back to off.(g + 1) - 1 do out.(rows.(p)) <- x.(rows.(p - back)) done
         done);
      out)
    windows
