(* Sort, Limit and After over the rows of an answer, each row an array of index words (a column a variable of Give,
   or a group's key or aggregate).

   The order. Rows compare by their keys, each ascending or descending, then by every other column, ascending, in
   the order of the columns (the Cesia package lists them all, the other fields of Give by name), so that two rows
   compare equal only when they are the same row. Values compare within their type: the inline ones (ints, dates,
   money, bools, links) by their words, which keep their order; texts by their bytes (UTF-8: the order of their code
   points, RFC 3629, section 1); floats by IEEE 754's totalOrder (section 5.10).

   Limit k: the first k rows, and the copies of the k-th (a page never splits identical rows: SQL's WITH TIES, on the
   whole row). After r: the rows strictly after r. Without Sort, Limit takes the first k rows in the engine's order.

   Two ways to the same rows (docs/book/cesia.md, "Sort, Limit and After"):
   - the heap path: every binding of the question, kept in a buffer of at most about 2 k rows that is sorted and cut
     back to its first k (and their ties) each time it fills: O(N log k) comparisons, O(k) rows held a domain;
   - the index path, when the first key is a column of an int, a date, money or a link that a pattern gives as its
     value (a bool has two values: nothing to gain): the question
     asked again on windows of that column's values, read off the property's index from the cursor on, each window
     holding twice as many facts as the one before, until k rows are found. Its budget is the planner's estimate of
     the heap path: past it, the heap path answers, so the index path never costs more than twice the heap path's
     estimate (the break-even rule of Karlin, Manasse, Rudolph and Sleator 1988). *)

type key = { col : int; desc : bool }

type order = { keys : key list; limit : int; after : Value.t array option }
(** [limit] 0: no limit. *)

let none = { keys = []; limit = 0; after = None }

(* which path answers: Auto chooses; the others are for the tests and the benchmarks *)
type path = Auto | Heap | Index

let path = ref Auto

(* the windows the index path asked, and how many times it gave up for the heap path: for the tests *)
let windows = Atomic.make 0
let gave_up = Atomic.make 0

let bad = Query.bad

(* IEEE 754's totalOrder on two floats: -NaN < -inf < ... < -0 < +0 < ... < +inf < +NaN *)
let total_order (a : float) (b : float) =
  let key f = let i = Int64.bits_of_float f in if Int64.compare i 0L < 0 then Int64.logxor i Int64.max_int else i in
  Int64.compare (key a) (key b)

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

(* a cursor's cell, ready to compare with a word *)
type cell = W of int | S of string | F of float

let cell v (ty : Value.typ) name (x : Value.t) =
  if not (Value.has_type ty x) then bad "After's %s needs a %s, not %s" name (Value.typ_name ty) (Value.to_string x);
  match x with
  | Text s -> S s
  | Float f -> F f
  | x -> (match Store.word v x with Some w -> W w | None -> bad "After's %s: %s" name (Value.to_string x))

(* a row against the cursor: > 0 when the row comes after it *)
let compare_cursor v (typs : Value.typ array) (ord : key array) (row : int array) (cur : cell array) =
  let c = ref 0 and i = ref 0 in
  while !c = 0 && !i < Array.length ord do
    let k = ord.(!i) in
    let w = row.(k.col) in
    let x =
      match cur.(k.col), typs.(k.col) with
      | W u, _ -> compare w u
      | S s, _ -> String.compare (Store.text v w) s
      | F f, _ -> total_order (float_of_word v w) f
    in
    c := if k.desc then -x else x;
    incr i
  done;
  !c

(* ---- the buffer of the heap path ---- *)

type acc = { mutable a : int array array; mutable n : int }

let fresh () = { a = [||]; n = 0 }

let sort_cut cmp cap t =
  let s = Array.sub t.a 0 t.n in
  Array.stable_sort cmp s;
  let n = if cap > 0 && t.n > cap then (let m = ref cap in while !m < t.n && cmp s.(cap - 1) s.(!m) = 0 do incr m done; !m) else t.n in
  t.a <- s;
  t.n <- n

let push cmp cap t row =
  if t.n = Array.length t.a then begin
    let a = Array.make (max 64 (2 * t.n)) [||] in
    Array.blit t.a 0 a 0 t.n;
    t.a <- a
  end;
  t.a.(t.n) <- row;
  t.n <- t.n + 1;
  if cap > 0 && t.n >= max 64 (2 * cap) then sort_cut cmp cap t

let append cmp cap a b =
  for i = 0 to b.n - 1 do push cmp cap a b.a.(i) done;
  a

(* ---- the answer ---- *)

(* [fold range ~seq ~init ~step ~merge]: the question's bindings (an env of index words a binding), with one more
   range [lo <= x <= hi] on a variable when [range] is given. [project env]: the row of a binding. [var col]: the
   variable a column gives, if it is one. [lead x]: a property of a pattern that gives x as its value, if any.
   [estimate ()]: the planner's estimate of the question's work. *)
type source = {
  fold : 'a. (int * Value.t * Value.t) option -> seq:bool -> init:(unit -> 'a) -> step:('a -> int array -> 'a) -> merge:('a -> 'a -> 'a) -> 'a;
  project : int array -> int array;
  var : int -> int option;
  lead : int -> int option;
  estimate : unit -> float;
}

exception Enough

let check cols (typs : Value.typ array) o =
  List.iter (fun k -> if k.col < 0 || k.col >= cols then bad "Sort: column %d out of range" k.col) o.keys;
  if o.limit < 0 then bad "Limit needs a number of rows of 1 or more, not %d" o.limit;
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

(* the rows of a question's Give, in the order [o] *)
let give (v : Store.view) ~(typs : Value.typ array) (src : source) (o : order) : int array array =
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
    let cmp = compare_rows v typs ord in
    let keep =
      match o.after with
      | None -> fun _ -> true
      | Some a ->
        let cur = Array.mapi (fun i x -> cell v typs.(i) (string_of_int i) x) a in
        fun row -> compare_cursor v typs ord row cur > 0
    in
    let cap = o.limit in
    let heap range =
      let acc =
        src.fold range ~seq:false ~init:fresh ~merge:(append cmp cap)
          ~step:(fun t env -> let r = src.project env in if keep r then push cmp cap t r; t)
      in
      sort_cut cmp cap acc;
      acc
    in
    let first = List.hd o.keys in
    let lead =
      match src.var first.col with
      | Some x when Value.inline typs.(first.col) && typs.(first.col) <> Tbool -> (match src.lead x with Some p -> Some (x, p) | None -> None)
      | _ -> None
    in
    let index (x, p) =
      (* the windows of x's values, from the cursor on, each of [m] facts of p, m doubling *)
      let ty = typs.(first.col) in
      let mk w = word_value ty w in
      let start =
        match o.after with
        | Some a -> (match cell v ty "" a.(first.col) with W w -> w | _ -> assert false)
        | None -> if first.desc then max_int else min_int
      in
      let budget = src.estimate () in
      let got = fresh () and spent = ref 0 and m = ref (2 * cap) and edge = ref start and over = ref false and found = ref None in
      while !found = None && not !over do
        let lo, hi, last =
          if first.desc then begin
            let hi = !edge in
            let left = Store.count_range v p min_int hi in
            if left <= !m then (min_int, hi, true)
            else begin
              (* the largest lo whose window [lo, hi] holds m facts *)
              let a = ref min_int and b = ref hi in
              while !a < !b do
                let mid = (!a asr 1) + (!b asr 1) + (!a land !b land 1) + 1 in
                if Store.count_range v p mid hi >= !m then a := mid else b := mid - 1
              done;
              (!a, hi, !a = min_int)
            end
          end
          else begin
            let lo = !edge in
            let left = Store.count_range v p lo max_int in
            if left <= !m then (lo, max_int, true)
            else begin
              let a = ref lo and b = ref max_int in
              while !a < !b do
                let mid = (!a asr 1) + (!b asr 1) + (!a land !b land 1) in
                if Store.count_range v p lo mid >= !m then b := mid else a := mid + 1
              done;
              (lo, !a, !a = max_int)
            end
          end
        in
        Atomic.incr windows;
        spent := !spent + Store.count_range v p lo hi;
        let w = heap (Some (x, mk lo, mk hi)) in
        for i = 0 to w.n - 1 do push cmp cap got w.a.(i) done;
        sort_cut cmp cap got;
        if got.n >= cap || last then found := Some got
        else if float_of_int !spent > budget then over := true
        else begin
          (if first.desc then edge := lo - 1 else edge := hi + 1);
          m := 2 * !m
        end
      done;
      match !found with Some g -> g | None -> Atomic.incr gave_up; heap None
    in
    let use_index =
      cap > 0
      && lead <> None
      && match !path with Heap -> false | Index -> true | Auto -> src.estimate () > float_of_int (4 * cap)
    in
    let acc = match lead with Some l when use_index -> index l | _ -> heap None in
    Array.sub acc.a 0 acc.n
  end

(* rows held already (a group's key and aggregates), in the order [o] *)
let sort_rows (v : Store.view) ~(typs : Value.typ array) (o : order) (rows : int array array) =
  let cols = Array.length typs in
  check cols typs o;
  if o.keys = [] then (if o.limit > 0 && Array.length rows > o.limit then Array.sub rows 0 o.limit else rows)
  else begin
    let ord = full cols o.keys in
    let cmp = compare_rows v typs ord in
    let rows =
      match o.after with
      | None -> rows
      | Some a ->
        let cur = Array.mapi (fun i x -> cell v typs.(i) (string_of_int i) x) a in
        Array.of_list (List.filter (fun r -> compare_cursor v typs ord r cur > 0) (Array.to_list rows))
    in
    let t = { a = Array.copy rows; n = Array.length rows } in
    sort_cut cmp o.limit t;
    Array.sub t.a 0 t.n
  end
