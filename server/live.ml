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
   maximum that a removal takes away is asked again for its key only.

   Messages are held until their frame is durable (G5, G13: never shown before a crash can no longer take it back):
   the hub evaluates a frame while it is forced, and gives its messages once it is durable. *)

open Cepheus

type row = Value.t array

type msg =
  | Answer of { group : int; rows : row list }  (** the whole answer at [group] *)
  | Change of { group : int; added : row list; removed : row list }
  | Same of { group : int }  (** the answer at [group] is the one at the group the watch resumed from *)
  | Ended of { code : string; message : string }  (** the watch is over; "lagging": watch again from its group *)

(* the state of a key of an aggregate: its bindings, and each aggregate's word (a sum, a minimum, a maximum) *)
type key = { mutable n : int; acc : int array }

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
  before : (row, row option) Hashtbl.t;  (* Group: a touched key's row before the frame *)
  dirty : (row, unit) Hashtbl.t;  (* Group: a key whose minimum or maximum was removed *)
}

and template = {
  tkey : string;
  tq : Query.t;  (* the question, its constants as variables nq .. nq + np - 1 *)
  nq : int;
  np : int;
  pats : Query.pattern array;
  typs : Value.typ array;  (* of every variable of tq *)
  give : int array;  (* Give: its columns; Group: the key's variables *)
  aggs : Wire.agg array;  (* empty for Give *)
  projecting : bool;  (* Give leaves out a variable: two bindings may give one row *)
  subs : (row, sub list) Hashtbl.t;  (* by parameters *)
  slots : (Value.t, int) Hashtbl.t array;  (* each parameter's values among the watches, counted *)
  mutable count : int;
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
          (match num y, num lo, num hi with Some c, Some a, Some b when c >= a && c <= b -> () | _ -> ok := false);
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

let projecting (q : Query.t) give = let seen = Array.make q.vars false in Array.iter (fun x -> seen.(x) <- true) give; Array.exists not seen

(* the template of a question: its constants as parameters, in the order they appear; its key, and the parameters *)
let templatize (q : Query.t) (sel : Wire.select) =
  let params = ref [] and np = ref 0 in
  let param x = let k = q.vars + !np in incr np; params := x :: !params; Query.Var k in
  let side = function Query.Var _ as t -> t | Thing c -> param (Value.Link c) | Val x -> param x in
  let where = List.map (fun (pt : Query.pattern) -> let e = side pt.e in let v = side pt.v in { pt with e; v }) q.where in
  let tq = { Query.vars = q.vars + !np; where; ranges = q.ranges } in
  let b = Buffer.create 64 in
  Wire.put_query b tq;
  Codec.put_varint b q.vars;
  Wire.put_select b sel;
  tq, Buffer.contents b, Array.of_list (List.rev !params)

let new_template (v : Store.view) key tq nq (sel : Wire.select) =
  let typs = Query.var_types v tq in
  let give, aggs = match sel with Wire.Give g -> (if Array.length g = 0 then Array.init nq Fun.id else g), [||] | Group (k, a) -> k, a in
  let q0 = { tq with vars = nq } in
  { tkey = key; tq; nq; np = tq.vars - nq; pats = Array.of_list tq.where; typs; give; aggs;
    projecting = (Array.length aggs = 0 && projecting q0 give); subs = Hashtbl.create 64;
    slots = Array.init (tq.vars - nq) (fun _ -> Hashtbl.create 8); count = 0 }

(* ---- the state of a watch ---- *)

let values (v : Store.view) (t : template) (b : int array) cols = Array.map (fun x -> Store.value v t.typs.(x) b.(x)) cols

let agg_value (t : template) i w : Value.t =
  match t.aggs.(i) with
  | Wire.Count -> Int w
  | Sum x | Min x | Max x -> (match t.typs.(x) with Tmoney _ -> Money w | Tdate -> Date w | _ -> Int w)

let agg_start (t : template) = Array.map (function Wire.Min _ -> max_int | Wire.Max _ -> min_int | _ -> 0) t.aggs

let agg_add (t : template) (k : key) (b : int array) =
  k.n <- k.n + 1;
  Array.iteri
    (fun i a ->
      match a with
      | Wire.Count -> k.acc.(i) <- k.acc.(i) + 1
      | Sum x -> k.acc.(i) <- k.acc.(i) + b.(x)
      | Min x -> if b.(x) < k.acc.(i) then k.acc.(i) <- b.(x)
      | Max x -> if b.(x) > k.acc.(i) then k.acc.(i) <- b.(x))
    t.aggs

(* a removal: true when it takes away a minimum or a maximum, which must be asked again *)
let agg_remove (t : template) (k : key) (b : int array) =
  k.n <- k.n - 1;
  let again = ref false in
  Array.iteri
    (fun i a ->
      match a with
      | Wire.Count -> k.acc.(i) <- k.acc.(i) - 1
      | Sum x -> k.acc.(i) <- k.acc.(i) - b.(x)
      | Min x | Max x -> if b.(x) = k.acc.(i) then again := true)
    t.aggs;
  !again

let key_row (t : template) kv (k : key) = if k.n <= 0 then None else Some (Array.append kv (Array.mapi (fun i w -> agg_value t i w) k.acc))

(* the key's state asked again on [v]: its bindings only (the question with the key fixed) *)
let recount (v : Store.view) (s : sub) kv =
  let t = s.t in
  let asg = Array.make s.q.vars None in
  Array.iteri (fun i x -> asg.(x) <- Some kv.(i)) t.give;
  let k = { n = 0; acc = agg_start t } in
  fold_fixed v s.q asg ~drop:(fun _ -> false) (fun b -> agg_add t k b);
  k

(* the watch's answer now, and its state (the keys of an aggregate) *)
let answer (v : Store.view) (s : sub) =
  let t = s.t in
  if Array.length t.aggs = 0 then begin
    let a = Answer.answer v s.q (Wire.Give t.give) in
    let typs = Array.init a.cols a.typ in
    List.init a.n (fun i -> Array.init a.cols (fun j -> Store.value v typs.(j) (a.word i j)))
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
          | Max _ -> a.acc.(i) <- max a.acc.(i) b.acc.(i))
        t.aggs
    in
    let tbl =
      Query.fold v s.q ~init:(fun () -> Hashtbl.create 16)
        ~merge:(fun a b -> Hashtbl.iter (fun kv k -> match Hashtbl.find_opt a kv with Some k' -> combine k' k | None -> Hashtbl.replace a kv k) b; a)
        ~step:(fun tbl b ->
          let kv = values v t b t.give in
          let k = match Hashtbl.find_opt tbl kv with Some k -> k | None -> let k = { n = 0; acc = agg_start t } in Hashtbl.replace tbl kv k; k in
          agg_add t k b;
          tbl)
    in
    Hashtbl.iter (fun kv k -> Hashtbl.replace s.keys kv k) tbl;
    let rows = Hashtbl.fold (fun kv k acc -> match key_row t kv k with Some r -> r :: acc | None -> acc) s.keys [] in
    List.sort compare rows
  end

(* a question checked as Find checks it: its variables, its constants' types, its aggregates' variables *)
let check (v : Store.view) (q : Query.t) (sel : Wire.select) =
  let ty = Query.var_types v q in
  let var x = if x < 0 || x >= q.vars then Query.bad "variable %d out of range" x in
  ignore (Query.plan v q);
  match sel with
  | Wire.Give g -> Array.iter var g
  | Group (keys, aggs) ->
    Array.iter var keys;
    Array.iter
      (function
        | Wire.Count -> ()
        | Sum x -> var x; (match ty.(x) with Tint | Tmoney _ -> () | t -> Query.bad "a sum of a %s variable" (Value.typ_name t))
        | Min x | Max x ->
          var x;
          (match ty.(x) with Tint | Tmoney _ | Tdate -> () | t -> Query.bad "a min or max of a %s variable" (Value.typ_name t)))
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
    let k = match Hashtbl.find_opt s.keys kv with Some k -> k | None -> let k = { n = 0; acc = agg_start t } in Hashtbl.replace s.keys kv k; k in
    if not (Hashtbl.mem s.before kv) then Hashtbl.replace s.before kv (key_row t kv k);
    if sign > 0 then agg_add t k b else if agg_remove t k b then Hashtbl.replace s.dirty kv ()
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
          let now = key_row t kv k in
          if k.n <= 0 then Hashtbl.remove s.keys kv;
          if old <> now then begin
            Option.iter (fun x -> r := x :: !r) old;
            Option.iter (fun x -> a := x :: !a) now
          end)
        s.before;
      Hashtbl.reset s.before;
      Hashtbl.reset s.dirty;
      !a, !r
    end
  in
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
        (match
           Hashtbl.iter
             (fun _ t ->
               if plus <> [] then side_bindings v1 t plus (Lazy.force dplus) 1 touched;
               if minus <> [] then side_bindings v0 t minus (Lazy.force dminus) (-1) touched)
             ts
         with
        | () ->
          let out =
            List.filter_map (fun s -> match finish v1 s with Some (added, removed) -> Some (s, Change { group = v1.group; added; removed }) | None -> None) (List.rev !touched)
          in
          give h tag out
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

(* a frame whose changes are not given (a large group): every watch is asked again *)
let reset h (v : Store.view) ~tag =
  Mutex.protect h.hm (fun () ->
      end_all h "lagging" "a large group changed the database: watch again from its group";
      Queue.clear h.ring;
      h.ring_n <- 0;
      h.ring_from <- v.group;
      h.view <- v;
      h.tag <- tag)

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
   called under the hub's lock and must not wait. Raises Query.Bad for a question that is not valid, and
   Pages.Unreadable. *)
let subscribe h (q : Query.t) (sel : Wire.select) ~from ~(emit : msg -> bool) =
  Mutex.protect h.hm (fun () ->
      (match h.stopped with Some (code, m) -> raise (Failure (code ^ ": " ^ m)) | None -> ());
      let v = h.view in
      check v q sel;
      let tq, key, params = templatize q sel in
      let t = match Hashtbl.find_opt h.templates key with Some t -> t | None -> new_template v key tq q.vars sel in
      let s =
        { sid = h.next; t; params; q; emit; gone = false; keys = Hashtbl.create 8; touched = false; plus = []; minus = [];
          net = Hashtbl.create 8; before = Hashtbl.create 8; dirty = Hashtbl.create 8 }
      in
      let first =
        if from > 0 && from >= h.ring_from && from <= v.group && not (touched_since h q from) then begin
          (* the keys of an aggregate are needed for the changes to come *)
          if Array.length t.aggs > 0 then ignore (answer v s);
          Same { group = v.group }
        end
        else Answer { group = v.group; rows = answer v s }
      in
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
