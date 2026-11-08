(* The reasoner: the facts the rules derive, kept up to date by the writer, group by group (the reasoner design,
   section 5). It runs inside Resolve, after a group's asserted changes, so a fork reasons exactly as the database
   (G8), and its result is written in the group's frame (kinds 2-5 of Group.kind): replay, replicas and the past apply
   it and never evaluate a rule.

   - Insertion: semi-naive evaluation by rounds (Bancilhon, Ramakrishnan 1986): round 0 is the group's asserted
     additions; a rule instance is enumerated at its first body atom whose fact is of round r, the atoms before it
     restricted to facts of rounds below r and the atoms after it to rounds up to r, so every instance is enumerated
     once; heads that are not facts yet make round r + 1.
   - Retraction: Backward/Forward (Motik, Nenov, Piro, Horrocks, AAAI 2015): a fact that lost a derivation is checked
     by backward chaining over the current state minus the facts already disproved (each fact checked once, so cycles
     end); proofs propagate forward among the proved facts, in a small table of their own; a fact left without a proof
     is deleted and its consequences checked in turn. Each recursion depth has its own copy of the compiled plans (a
     plan's bindings are its own).
   - Why: the same backward check on a view, nothing deleted; the instance that proved each fact is kept, so the proof
     is well-founded (every body fact proved before its head).
   - Rules are compiled to closures once (Feeley, Lapalme 1987) for each rule set, the order of their atoms chosen from
     the store's exact counts.

   The working set: the facts a group's reasoning touched, in arrays out of the collector's way and reused from group
   to group: open addressing on (property, thing, value), chains of the facts the view lacks by (property, thing),
   (property, value) and property, and per fact its state in the view (base), its state now, its round, its marks. A
   read of the state is the view's read with the working set's entries in front. *)

(* The store's functions, called and not inlined: the library is built with -inline 200, which would copy each of
   them into every step of every plan, and a larger binary starts more slowly (its frame descriptors and relocations
   are read at start-up). A call costs a few nanoseconds; a lookup, a hundred or more. *)
module S = struct
  let[@inline never] word v x = Store.word v x
  let[@inline never] state v e p w = Store.state v e p w
  let[@inline never] mem v e p w = Store.mem v e p w
  let[@inline never] count_prop v p = Store.count_prop v p
  let[@inline never] count_things v p w = Store.count_things v p w
  let[@inline never] set_sorted v es ps ws ss n = Store.set_sorted v es ps ws ss n
  let[@inline never] facts v = Store.facts v
  let[@inline never] distinct v p = Store.distinct v p
  let[@inline never] word_intern v x = Store.word_intern v x
  let[@inline never] value v t w = Store.value v t w
  let[@inline never] iter_values v e p f = Store.iter_values v e p f
  let[@inline never] iter_things v p w f = Store.iter_things v p w f
  let[@inline never] iter_prop v p f = Store.iter_prop v p f
  let[@inline never] count_values v e p = Store.count_values v e p
end

exception Refused of string

let refuse fmt = Printf.ksprintf (fun s -> raise (Refused s)) fmt

(* the budget of a data write: derived changes <= base + per x asserted changes (choice 10.7 of the design) *)
let budget_base = ref 100_000
let budget_per = ref 100

(* counters for the benchmarks and the tests: rule instances found, facts checked by B/F or Why, and the seconds spent
   reasoning (Reason.run and Reason.bulk) *)
let derivations = ref 0
let checked = ref 0
let seconds = ref 0.
let bulk_index_seconds = ref 0. (* of [seconds]: a load's facts put into the working set, before the rules run *)

(* ---- hashing ---- *)

let[@inline] mix k = let k = k * 0x2545F4914F6CDD1D in k lxor (k lsr 29)
let[@inline] h3 e p w = mix ((e * 0x9E3779B1) lxor (p lsl 40) lxor (w * 0x85EBCA77) lxor (w lsr 31))
let[@inline] h2 a b = mix ((a lsl 40) lxor (b * 0x9E3779B1) lxor (b lsr 29))

(* The working set's arrays are Bigarrays: out of the collector's sight (a load's working set holds millions of facts,
   which the major collector would otherwise scan at each cycle), and made at their size once for a load. *)
module A = Bigarray.Array1

type ints = (int, Bigarray.int_elt, Bigarray.c_layout) A.t

let ints n v : ints = let a = A.create Bigarray.Int Bigarray.c_layout n in A.fill a v; a

(* [a] (its first [n] cells kept) in [c] cells, the others [v] *)
let[@inline never] regrow (a : ints) n c v = let b = ints c v in A.blit (A.sub a 0 n) (A.sub b 0 n); b

(* an index: (a, b) -> the newest fact with that key; the older ones chained through [next], per fact. A slot is three
   consecutive cells (key a, key b, head): one cache line a probe *)
type idx = {
  mutable sl : ints;  (* slot i: sl.(3i) the key a (-1: empty), sl.(3i+1) the key b, sl.(3i+2) the newest fact *)
  mutable mask : int;
  mutable used : int;
  mutable slots : ints;  (* the slots used, so that clearing costs what was used *)
  mutable next : ints;
}

let slots_for facts = let size = ref 64 in while !size < 2 * facts do size := 2 * !size done; !size

let[@inline never] new_slots size = let a = ints (3 * size) 0 in for i = 0 to size - 1 do A.unsafe_set a (3 * i) (-1) done; a

(* [keys]: the keys expected, for the size of the table (it grows past them); [facts]: the facts' chains *)
let idx_create ?(facts = 64) ?(keys = facts) () =
  let size = slots_for keys in
  { sl = new_slots size; mask = size - 1; used = 0; slots = ints (size / 2) 0; next = ints facts (-1) }

let[@inline] idx_slot t a b =
  let sl = t.sl and mask = t.mask in
  let i = ref (h2 a b land mask) in
  while (let k = A.unsafe_get sl (3 * !i) in k <> -1 && (k <> a || A.unsafe_get sl ((3 * !i) + 1) <> b)) do i := (!i + 1) land mask done;
  !i

let[@inline never] idx_grow t =
  let old = t.sl and os = t.slots and n = t.used in
  let size = 2 * (t.mask + 1) in
  t.sl <- new_slots size;
  t.mask <- size - 1;
  t.slots <- ints (size / 2) 0;
  for k = 0 to n - 1 do
    let j = A.unsafe_get os k in
    let a = A.unsafe_get old (3 * j) and b = A.unsafe_get old ((3 * j) + 1) in
    let i = idx_slot t a b in
    A.unsafe_set t.sl (3 * i) a;
    A.unsafe_set t.sl ((3 * i) + 1) b;
    A.unsafe_set t.sl ((3 * i) + 2) (A.unsafe_get old ((3 * j) + 2));
    A.unsafe_set t.slots k i
  done

let idx_add t a b x =
  if 2 * (t.used + 1) > t.mask + 1 then idx_grow t;
  let i = idx_slot t a b in
  if A.unsafe_get t.sl (3 * i) = -1 then begin
    A.unsafe_set t.sl (3 * i) a;
    A.unsafe_set t.sl ((3 * i) + 1) b;
    A.unsafe_set t.sl ((3 * i) + 2) (-1);
    A.unsafe_set t.slots t.used i;
    t.used <- t.used + 1
  end;
  A.unsafe_set t.next x (A.unsafe_get t.sl ((3 * i) + 2));
  A.unsafe_set t.sl ((3 * i) + 2) x

let[@inline] idx_head t a b = if t.used = 0 then -1 else A.unsafe_get t.sl ((3 * idx_slot t a b) + 2)
let[@inline] idx_next t x = A.unsafe_get t.next x

let[@inline never] idx_clear t =
  for k = 0 to t.used - 1 do
    let i = A.unsafe_get t.slots k in
    A.unsafe_set t.sl (3 * i) (-1);
    A.unsafe_set t.sl ((3 * i) + 2) (-1)
  done;
  t.used <- 0

(* ---- the working set ---- *)

type ws = {
  mutable n : int;
  mutable f3 : ints;  (* fact x: f3.(3x) its thing, f3.(3x+1) its property, f3.(3x+2) its value word *)
  mutable cap : int;
  mutable base : Bytes.t;  (* the state in the view the reasoning started from: 0 absent, 1 asserted, 2 only derived *)
  mutable now : Bytes.t;  (* the state now *)
  mutable mark : Bytes.t;  (* B/F and Why: 1 checked, 2 proved, 4 deleted; 8 chained; 16 an asserted retraction *)
  mutable round : ints;  (* the round it came in: -1 older than the group *)
  mutable rule : ints;  (* the rule that derived it (an index of the program), or -1 *)
  mutable by : int array array;  (* the body facts of the instance that proved it (B/F, Why), grown when used *)
  mutable set : ints;
  mutable smask : int;
  ie : idx;  (* (property, thing) *)
  iw : idx;  (* (property, value) *)
  ip : idx;  (* (property, 0) *)
  mutable with_ip : bool;  (* [ip] kept: some plan joins an atom with neither side bound (a load whose rules have none
                              skips it) *)
}

let ws_create ?(facts = 64) () =
  let c = max 64 facts in
  let size = ref 128 in
  while !size < 2 * c do size := 2 * !size done;
  { n = 0; f3 = ints (3 * c) 0; cap = c; base = Bytes.make c '\000'; now = Bytes.make c '\000';
    mark = Bytes.make c '\000'; round = ints c (-1); rule = ints c (-1); by = [||]; set = ints !size (-1);
    smask = !size - 1; ie = idx_create ~facts:c (); iw = idx_create ~facts:c ();
    ip = idx_create ~facts:c ~keys:32 (); with_ip = true }

let[@inline] fe ws x = A.unsafe_get ws.f3 (3 * x)
let[@inline] fp ws x = A.unsafe_get ws.f3 ((3 * x) + 1)
let[@inline] fw ws x = A.unsafe_get ws.f3 ((3 * x) + 2)
let[@inline] round ws x = A.unsafe_get ws.round x
let[@inline] rule ws x = A.unsafe_get ws.rule x
let[@inline] set_round ws x r = A.unsafe_set ws.round x r
let[@inline] set_rule ws x r = A.unsafe_set ws.rule x r
let by ws x = if x < Array.length ws.by then ws.by.(x) else [||]

let[@inline never] set_by ws x ids =
  if x >= Array.length ws.by then begin
    let b = Array.make (max (x + 1) ws.cap) [||] in
    Array.blit ws.by 0 b 0 (Array.length ws.by);
    ws.by <- b
  end;
  ws.by.(x) <- ids

let[@inline] find ws e p w =
  if ws.n = 0 then -1
  else begin
    let set = ws.set and mask = ws.smask in
    let i = ref (h3 e p w land mask) and r = ref (-2) in
    while !r = -2 do
      let x = A.unsafe_get set !i in
      if x = -1 then r := -1
      else if A.unsafe_get ws.f3 (3 * x) = e && A.unsafe_get ws.f3 ((3 * x) + 2) = w && A.unsafe_get ws.f3 ((3 * x) + 1) = p then r := x
      else i := (!i + 1) land mask
    done;
    !r
  end

let place ws x =
  let i = ref (h3 (fe ws x) (fp ws x) (fw ws x) land ws.smask) in
  while A.unsafe_get ws.set !i <> -1 do i := (!i + 1) land ws.smask done;
  A.unsafe_set ws.set !i x

let[@inline never] grow ws =
  let n = ws.n in
  let c = 2 * ws.cap in
  let gb a = let b = Bytes.make c '\000' in Bytes.blit a 0 b 0 n; b in
  ws.f3 <- regrow ws.f3 (3 * n) (3 * c) 0;
  ws.cap <- c;
  ws.round <- regrow ws.round n c (-1); ws.rule <- regrow ws.rule n c (-1);
  ws.base <- gb ws.base; ws.now <- gb ws.now; ws.mark <- gb ws.mark;
  List.iter (fun t -> t.next <- regrow t.next n c (-1)) [ ws.ie; ws.iw; ws.ip ]

let[@inline never] grow_set ws =
  let size = 2 * A.dim ws.set in
  ws.set <- ints size (-1);
  ws.smask <- size - 1;
  for x = 0 to ws.n - 1 do place ws x done

(* a fact the working set did not hold: its id *)
let add ws e p w base =
  if ws.n >= ws.cap then grow ws;
  if 2 * (ws.n + 1) > A.dim ws.set then grow_set ws;
  let x = ws.n in
  A.unsafe_set ws.f3 (3 * x) e; A.unsafe_set ws.f3 ((3 * x) + 1) p; A.unsafe_set ws.f3 ((3 * x) + 2) w;
  Bytes.unsafe_set ws.base x (Char.unsafe_chr base);
  Bytes.unsafe_set ws.now x (Char.unsafe_chr base);
  Bytes.unsafe_set ws.mark x '\000';
  A.unsafe_set ws.round x (-1);
  A.unsafe_set ws.rule x (-1);
  ws.n <- x + 1;
  place ws x;
  x

let[@inline] now ws x = Char.code (Bytes.unsafe_get ws.now x)
let[@inline] base ws x = Char.code (Bytes.unsafe_get ws.base x)
let[@inline] has ws x m = Char.code (Bytes.unsafe_get ws.mark x) land m <> 0
let[@inline] set_mark ws x m = Bytes.unsafe_set ws.mark x (Char.unsafe_chr (Char.code (Bytes.unsafe_get ws.mark x) lor m))

(* in the chains: a fact the view lacks (base absent) once it is present *)
let chain ws x =
  if not (has ws x 8) then begin
    set_mark ws x 8;
    let p = fp ws x in
    idx_add ws.ie p (fe ws x) x;
    idx_add ws.iw p (fw ws x) x;
    if ws.with_ip then idx_add ws.ip p 0 x
  end

let set_now ws x s =
  Bytes.unsafe_set ws.now x (Char.unsafe_chr s);
  if s > 0 && base ws x = 0 then chain ws x

let[@inline never] reset ws =
  if ws.n > 0 then begin
    (* the slots of the facts held, cleared (probing past the slots already cleared until its own) *)
    for x = 0 to ws.n - 1 do
      let i = ref (h3 (fe ws x) (fp ws x) (fw ws x) land ws.smask) in
      while A.unsafe_get ws.set !i <> x do i := (!i + 1) land ws.smask done;
      A.unsafe_set ws.set !i (-1)
    done;
    Array.fill ws.by 0 (min ws.n (Array.length ws.by)) [||];
    (* every slot is emptied: open addressing needs no tombstones *)
    List.iter idx_clear [ ws.ie; ws.iw; ws.ip ];
    ws.n <- 0
  end

(* ---- the compiled program ---- *)

type plan = {
  ri : int;  (* the rule: an index of the program's rules *)
  be : int array;  (* the instance being enumerated: each body atom's fact, its thing and value *)
  bw : int array;
  mutable he : int;  (* and its head's *)
  mutable hw : int;
  mutable run : int -> int -> unit;  (* the matched fact's thing and value (its property is the plan's) *)
}

(* plans by the property of their matched atom, and by (property, value) for an atom whose value is a constant (open
   addressing: no allocation, no generic hash, per fact) *)
type dispatch = {
  byp : plan array array;
  kp : int array;  (* -1: an empty slot *)
  kw : int array;
  kv : plan array array;
  kmask : int;
  kn : int;
}

type program = {
  key : int;
  rules : Rules.t array;
  ids : int array;  (* their things *)
  head_p : int array;  (* the property each rule gives, -1 for a constraint *)
  atoms : Query.pattern array array;  (* each rule's body, as an array *)
  free_free : bool;  (* a plan of a fact joins an atom with neither side bound: the working set keeps the index by
                        property *)
  np : int;
  reads : Bytes.t;  (* by property: 1 a rule body reads it, 2 a rule head gives it *)
  consts : Value.t array;  (* the texts and floats of the rules, looked up in each view's dictionary *)
  orders : (int * int, int array) Hashtbl.t;  (* (rule, matched atom) -> the order of the other atoms *)
  size : int;  (* the facts of the view the orders were chosen on *)
  pool : ctx list ref;
  pm : Mutex.t;
}

and ctx = {
  prog : program;
  ws : ws;
  pt : ws;  (* the facts proved, B/F's and Why's: a table of their own; [rule] holds each one's id in [ws] *)
  mutable v : Store.view;
  mutable round : int;  (* the round evaluated; max_int: every fact visible *)
  cw : int array;  (* the words of prog.consts in [v], -1 for a text it lacks *)
  mutable fwd : (dispatch * dispatch) array;  (* by depth: forward over the state, forward over the proved *)
  mutable bwd : dispatch array;  (* by depth: the head matched *)
  mutable cons : dispatch option;  (* the constraints, forward *)
  mutable on_fwd : plan -> unit;  (* what depth 0's forward plans over the state do with an instance *)
  mutable next : ints;  (* the next round's facts *)
  mutable spare : ints;  (* the round's facts, the buffer before *)
  mutable nn : int;
  mutable derived : int;  (* derived changes so far *)
  mutable limit : int;
  mutable vp : Bytes.t;  (* by property: 1 when the view may hold facts of it (a load: the view lacks most); empty: all *)
  per_rule : int array;
}

let[@inline] is_text_const (x : Value.t) = match x with Text _ | Float _ -> true | _ -> false

let inline_word (x : Value.t) =
  match x with
  | Int n | Date n | Money n | Link n -> n
  | Bool b -> if b then 1 else 0
  | Text _ | Float _ -> invalid_arg "Reason.inline_word"

let atoms_of (r : Rules.t) = Array.of_list r.where

(* the other atoms of a rule in the order a plan joins them: each step the atom of the best class for the variables
   bound so far, then the fewest candidates by the store's counts. The classes come first because counts change (a
   rule defined on an empty database, a load whose facts the view does not hold yet) and a constant is not selective
   ([x type Person] has thousands of rows, the design's section 2.2: 1,870x more work in the prototype's first
   order): both sides bound (a test), then one side bound by a variable or by a thing in the thing's place, then a
   value bound by a constant, then nothing bound. *)
let choose_order (v : Store.view) (r : Rules.t) pos =
  let atoms = atoms_of r in
  let nb = Array.length atoms in
  let bound = Array.make (max 1 r.vars) false in
  let bind = function Query.Var x -> bound.(x) <- true | _ -> () in
  (match pos with
   | -1 -> (match r.head with Give h -> bind h.e; bind h.v | Never -> ())
   | i when i >= 0 -> bind atoms.(i).e; bind atoms.(i).v
   | _ -> ());
  let known = function Query.Var x -> bound.(x) | _ -> true in
  let est (a : Query.pattern) =
    match known a.e, known a.v with
    | true, true -> 0, 0
    | true, false -> 1, (match Schema.find v.schema a.p with Some d when not d.many -> 1 | _ -> 4)
    | false, true -> (
      match a.v with
      | Val x when not (is_text_const x) -> 2, S.count_things v a.p (inline_word x)
      | Thing c -> 2, S.count_things v a.p c
      | Val _ -> 2, max 1 (S.count_prop v a.p / S.distinct v a.p)
      | Var _ -> 1, max 1 (S.count_prop v a.p / S.distinct v a.p))
    | false, false -> 3, S.count_prop v a.p
  in
  let rest = ref (List.filter (fun j -> j <> pos) (List.init nb Fun.id)) and out = ref [] in
  while !rest <> [] do
    let best = List.fold_left (fun b j -> match b with None -> Some (j, est atoms.(j)) | Some (_, c) -> let c' = est atoms.(j) in if compare c' c < 0 then Some (j, c') else b) None !rest in
    let j, _ = Option.get best in
    out := j :: !out;
    rest := List.filter (fun k -> k <> j) !rest;
    bind atoms.(j).e;
    bind atoms.(j).v
  done;
  Array.of_list (List.rev !out)

let make_program (v : Store.view) =
  let rs = Schema.rules v.schema in
  let parsed =
    List.filter_map (fun (id, (name, text)) -> match Rules.of_text name text with Ok r -> Some (id, r) | Error _ -> None) rs
  in
  let rules = Array.of_list (List.map snd parsed) and ids = Array.of_list (List.map fst parsed) in
  let np = Schema.count v.schema in
  let reads = Bytes.make np '\000' in
  let mark p b = if p >= 0 && p < np then Bytes.set reads p (Char.chr (Char.code (Bytes.get reads p) lor b)) in
  let consts = ref [] in
  let see_const = function Query.Val x when is_text_const x -> if not (List.mem x !consts) then consts := x :: !consts | _ -> () in
  Array.iter
    (fun (r : Rules.t) ->
      List.iter (fun (a : Query.pattern) -> mark a.p 1; see_const a.v) r.where;
      match r.head with Give h -> mark h.p 2; see_const h.v | Never -> ())
    rules;
  let orders = Hashtbl.create 64 and free_free = ref false in
  Array.iteri
    (fun ri (r : Rules.t) ->
      let nb = List.length r.where in
      let atoms = atoms_of r in
      for pos = -2 to nb - 1 do
        let o = choose_order v r pos in
        Hashtbl.replace orders (ri, pos) o;
        (* does a plan of a fact (pos >= -1) join an atom with neither side bound *)
        if pos >= -1 then begin
          let bound = Array.make (max 1 r.vars) false in
          let bind = function Query.Var x -> bound.(x) <- true | _ -> () in
          let known = function Query.Var x -> bound.(x) | _ -> true in
          (if pos = -1 then match r.head with Give h -> bind h.e; bind h.v | Never -> () else (bind atoms.(pos).e; bind atoms.(pos).v));
          Array.iter
            (fun j ->
              let a = atoms.(j) in
              if not (known a.e || known a.v) then free_free := true;
              bind a.e;
              bind a.v)
            o
        end
      done)
    rules;
  { key = Schema.rules_key v.schema; rules; ids; np; reads; consts = Array.of_list (List.rev !consts);
    head_p = Array.map (fun (r : Rules.t) -> match r.head with Give h -> h.p | Never -> -1) rules; orders;
    atoms = Array.map atoms_of rules; free_free = !free_free;
    size = S.facts v; pool = ref []; pm = Mutex.create () }

(* ---- plans ----
   A plan enumerates the instances of one rule with one atom matched to a given fact (a body atom: forward; the head:
   backward), or with none (every instance), reading the state (the view and the working set) or the proved facts.
   Each step binds or checks one atom's variables with the store's lookups; the closures are made once, so running a
   plan allocates nothing but what the store's iterators do. *)

type source = State | Proved

let compile ctx ?(extra : Rules.t option) ri pos source (k : plan -> unit) =
  let prog = ctx.prog in
  let r = match extra with Some r -> r | None -> prog.rules.(ri) in
  let atoms = atoms_of r in
  let nb = Array.length atoms in
  let env = Array.make (max 1 r.vars) 0 and bound = Array.make (max 1 r.vars) false in
  let pl = { ri; be = Array.make (max 1 nb) 0; bw = Array.make (max 1 nb) 0; he = 0; hw = 0; run = (fun _ _ -> ()) } in
  (* the ranges of each variable, as words *)
  let rng = Array.make (max 1 r.vars) [] in
  List.iter (fun (x, lo, hi) -> rng.(x) <- (inline_word lo, inline_word hi) :: rng.(x)) r.ranges;
  let in_range x w = match rng.(x) with [] -> true | l -> List.for_all (fun (lo, hi) -> w >= lo && w <= hi) l in
  (* a constant's word: inline, or through the context's table (texts, floats); an extra rule's looked up now *)
  let const_word ~head (x : Value.t) : unit -> int =
    if not (is_text_const x) then (let c = inline_word x in fun () -> c)
    else
      let rec idx i = if i >= Array.length prog.consts then -1 else if Value.equal prog.consts.(i) x then i else idx (i + 1) in
      match idx 0 with
      | i when i >= 0 ->
        if head then
          (* a text a head gives: interned when first needed, in the order of the derivations, as replay will *)
          fun () ->
            let w = ctx.cw.(i) in
            if w >= 0 then w
            else begin
              let v, w = S.word_intern ctx.v x in
              ctx.v <- v;
              ctx.cw.(i) <- w;
              w
            end
        else fun () -> ctx.cw.(i)
      | _ -> let c = Option.value (S.word ctx.v x) ~default:(-1) in fun () -> c
  in
  let getter ~head = function
    | Query.Var x -> fun () -> env.(x)
    | Thing c -> fun () -> c
    | Val x -> const_word ~head x
  in
  let ws = ctx.ws and pt = ctx.pt in
  (* the visible facts of the state for a step: the view's, unless the working set says otherwise, and the working
     set's own (chained); [lim]: the newest round a step sees *)
  let[@inline] vis x lim = Char.code (Bytes.unsafe_get ws.now x) > 0 && round ws x <= lim in
  (* does the view hold facts of p at all (a load's reasoning reads the working set alone for most properties) *)
  let[@inline] in_view p = Bytes.length ctx.vp = 0 || Bytes.unsafe_get ctx.vp p <> '\000' in
  let order = match extra with Some _ -> choose_order ctx.v r pos | None -> Hashtbl.find prog.orders (ri, pos) in
  (* the matched atom binds first *)
  let matched : Query.pattern option =
    if pos >= 0 then Some atoms.(pos) else if pos = -1 then (match r.head with Give h -> Some h | Never -> None) else None
  in
  let unify_e, unify_v =
    match matched with
    | None -> (fun _ -> true), fun _ -> true
    | Some a ->
      let ue =
        match a.e with
        | Query.Var x when not bound.(x) -> bound.(x) <- true; fun e -> env.(x) <- e; in_range x e
        | Query.Var x -> fun e -> env.(x) = e
        | t -> let g = getter ~head:false t in fun e -> e = g ()
      in
      let uv =
        match a.v with
        | Query.Var x when not bound.(x) -> bound.(x) <- true; fun w -> env.(x) <- w; in_range x w
        | Query.Var x -> fun w -> env.(x) = w
        | t -> let g = getter ~head:false t in fun w -> w = g ()
      in
      ue, uv
  in
  let final =
    match r.head, pos with
    | Give h, p when p <> -1 ->
      let ge = getter ~head:true h.e and gv = getter ~head:true h.v in
      fun () -> pl.he <- ge (); pl.hw <- gv (); k pl
    | _ -> fun () -> k pl
  in
  let step j (next : unit -> unit) : unit -> unit =
    let a = atoms.(j) in
    let p = a.p in
    let strict = pos >= 0 && j < pos in
    let lim () = if strict then ctx.round - 1 else ctx.round in
    let known = function Query.Var x -> bound.(x) | _ -> true in
    let ke = known a.e and kv = known a.v in
    let same = match a.e, a.v with Query.Var x, Query.Var y -> x = y | _ -> false in
    ignore same;
    let ge = getter ~head:false a.e and gv = getter ~head:false a.v in
    let var = function Query.Var x -> x | _ -> -1 in
    let xe = var a.e and xv = var a.v in
    (* the step's own cells, read by its callbacks *)
    let ce = ref 0 and cw = ref 0 and cl = ref 0 in
    let s =
      match source, ke, kv with
      | State, true, true ->
        fun () ->
          let e = ge () and w = gv () in
          let x = find ws e p w in
          if (if x >= 0 then vis x (lim ()) else in_view p && S.mem ctx.v e p w) then (pl.be.(j) <- e; pl.bw.(j) <- w; next ())
      | Proved, true, true ->
        fun () -> let e = ge () and w = gv () in if find pt e p w >= 0 then (pl.be.(j) <- e; pl.bw.(j) <- w; next ())
      | _, true, false ->
        bound.(xv) <- true;
        let on w = if in_range xv w then (env.(xv) <- w; pl.bw.(j) <- w; next ()) in
        if source = Proved then
          fun () ->
            let e = ge () in
            pl.be.(j) <- e;
            let x = ref (idx_head pt.ie p e) in
            while !x >= 0 do
              let y = !x in
              if fe pt y = e && fp pt y = p then on (fw pt y);
              x := idx_next pt.ie y
            done
        else begin
          let filt w = let x = find ws !ce p w in if x < 0 || vis x !cl then on w in
          fun () ->
            let e = ge () in
            ce := e;
            cl := lim ();
            pl.be.(j) <- e;
            if in_view p then S.iter_values ctx.v e p (if ws.n = 0 then on else filt);
            let x = ref (idx_head ws.ie p e) in
            while !x >= 0 do
              let y = !x in
              if fe ws y = e && fp ws y = p && vis y !cl then on (fw ws y);
              x := idx_next ws.ie y
            done
        end
      | _, false, true ->
        bound.(xe) <- true;
        let on e = if in_range xe e then (env.(xe) <- e; pl.be.(j) <- e; next ()) in
        if source = Proved then
          fun () ->
            let w = gv () in
            pl.bw.(j) <- w;
            let x = ref (idx_head pt.iw p w) in
            while !x >= 0 do
              let y = !x in
              if fw pt y = w && fp pt y = p then on (fe pt y);
              x := idx_next pt.iw y
            done
        else begin
          let filt e = let x = find ws e p !cw in if x < 0 || vis x !cl then on e in
          fun () ->
            let w = gv () in
            cw := w;
            cl := lim ();
            pl.bw.(j) <- w;
            if in_view p then S.iter_things ctx.v p w (if ws.n = 0 then on else filt);
            let x = ref (idx_head ws.iw p w) in
            while !x >= 0 do
              let y = !x in
              if fw ws y = w && fp ws y = p && vis y !cl then on (fe ws y);
              x := idx_next ws.iw y
            done
        end
      | _, false, false ->
        bound.(xe) <- true;
        bound.(xv) <- true;
        let on e w =
          if (not same || e = w) && in_range xe e && in_range xv w then begin
            env.(xe) <- e;
            env.(xv) <- w;
            pl.be.(j) <- e;
            pl.bw.(j) <- w;
            next ()
          end
        in
        if source = Proved then
          fun () ->
            let x = ref (idx_head pt.ip p 0) in
            while !x >= 0 do
              let y = !x in
              if fp pt y = p then on (fe pt y) (fw pt y);
              x := idx_next pt.ip y
            done
        else begin
          let filt e w = let x = find ws e p w in if x < 0 || vis x !cl then on e w in
          fun () ->
            cl := lim ();
            if in_view p then S.iter_prop ctx.v p (if ws.n = 0 then on else filt);
            let x = ref (idx_head ws.ip p 0) in
            while !x >= 0 do
              let y = !x in
              if fp ws y = p && vis y !cl then on (fe ws y) (fw ws y);
              x := idx_next ws.ip y
            done
        end
    in
    s
  in
  (* the steps built from the first, so that each sees the variables the earlier ones bind: [step] marks the
     variables it binds before the rest is built *)
  let rec go = function
    | [] -> final
    | j :: rest ->
      let s = ref (fun () -> ()) in
      let mk = step j (fun () -> !s ()) in
      s := go rest;
      mk
  in
  let body = go (Array.to_list order) in
  pl.run <-
    (fun e w ->
      if pos = -1 then (pl.he <- e; pl.hw <- w);
      if unify_e e && unify_v w then begin
        if pos >= 0 then (pl.be.(pos) <- e; pl.bw.(pos) <- w);
        body ()
      end);
  pl

(* the dispatch of a set of plans: the forward plans of every body atom of the rules [keep] selects, or the backward
   plans of their heads *)
let dispatch ctx ~backward source (keep : Rules.t -> bool) (k : plan -> unit) =
  let prog = ctx.prog in
  let byp = Array.make prog.np [||] and pwk = Hashtbl.create 16 in
  let push (a : Query.pattern) pl =
    match a.v with
    | Val x when not (is_text_const x) ->
      let key = (a.p, inline_word x) in
      Hashtbl.replace pwk key (Array.append (Option.value (Hashtbl.find_opt pwk key) ~default:[||]) [| pl |])
    | Thing c ->
      let key = (a.p, c) in
      Hashtbl.replace pwk key (Array.append (Option.value (Hashtbl.find_opt pwk key) ~default:[||]) [| pl |])
    | _ -> if a.p < prog.np then byp.(a.p) <- Array.append byp.(a.p) [| pl |]
  in
  Array.iteri
    (fun ri (r : Rules.t) ->
      if keep r then
        if backward then (match r.head with Give h -> push h (compile ctx ri (-1) source k) | Never -> ())
        else List.iteri (fun pos a -> push a (compile ctx ri pos source k)) r.where)
    prog.rules;
  let n = Hashtbl.length pwk in
  let size = ref 4 in
  while !size < 2 * n do size := 2 * !size done;
  let kp = Array.make !size (-1) and kw = Array.make !size 0 and kv = Array.make !size [||] and kmask = !size - 1 in
  Hashtbl.iter
    (fun (p, w) a ->
      let i = ref (h2 p w land kmask) in
      while kp.(!i) <> -1 do i := (!i + 1) land kmask done;
      kp.(!i) <- p;
      kw.(!i) <- w;
      kv.(!i) <- a)
    pwk;
  { byp; kp; kw; kv; kmask; kn = n }

(* every plan whose matched atom fits the fact (e p w), run on it *)
let run_all d e p w =
  if p < Array.length d.byp then begin
    let a = Array.unsafe_get d.byp p in
    for i = 0 to Array.length a - 1 do (Array.unsafe_get a i).run e w done
  end;
  if d.kn > 0 then begin
    let kp = d.kp and kw = d.kw and mask = d.kmask in
    let i = ref (h2 p w land mask) in
    while (let k = Array.unsafe_get kp !i in k <> -1 && (k <> p || Array.unsafe_get kw !i <> w)) do i := (!i + 1) land mask done;
    if Array.unsafe_get kp !i <> -1 then begin
      let a = Array.unsafe_get d.kv !i in
      for i = 0 to Array.length a - 1 do (Array.unsafe_get a i).run e w done
    end
  end

(* ---- the state ---- *)

(* is (e p w) a fact now: the working set's entry, else the view *)
let present ctx e p w = let x = find ctx.ws e p w in if x >= 0 then now ctx.ws x > 0 else S.mem ctx.v e p w

(* the id of a fact of the state in the working set, added with its state in the view if needed *)
let[@inline never] intern ctx e p w =
  let x = find ctx.ws e p w in
  if x >= 0 then x else add ctx.ws e p w (S.state ctx.v e p w)

(* ---- B/F and Why: the backward check, and proofs forward among the proved facts ---- *)

let no_dispatch = { byp = [||]; kp = [| -1 |]; kw = [| 0 |]; kv = [| [||] |]; kmask = 0; kn = 0 }

let rec plans ctx d =
  if d >= Array.length ctx.bwd then begin
    let n = Array.length ctx.bwd in
    let fwd = Array.make (d + 1) (no_dispatch, no_dispatch) and bwd = Array.make (d + 1) no_dispatch in
    Array.blit ctx.fwd 0 fwd 0 (Array.length ctx.fwd);
    Array.blit ctx.bwd 0 bwd 0 n;
    ctx.fwd <- fwd;
    ctx.bwd <- bwd;
    for k = n to d do
      let give (r : Rules.t) = r.head <> Never in
      let f0 = if k = 0 then dispatch ctx ~backward:false State give (fun pl -> ctx.on_fwd pl) else no_dispatch in
      let fp = dispatch ctx ~backward:false Proved give (fun pl -> proved_instance ctx k pl) in
      ctx.fwd.(k) <- (f0, fp);
      ctx.bwd.(k) <- dispatch ctx ~backward:true State give (fun pl -> backward_instance ctx k pl)
    done
  end

(* an instance among the proved facts: its head, if checked and not yet proved, is proved now *)
and proved_instance ctx d pl =
  let p = ctx.prog.head_p.(pl.ri) in
  let h = find ctx.ws pl.he p pl.hw in
  if h >= 0 && has ctx.ws h 1 && not (has ctx.ws h 2) then begin
    let ats = ctx.prog.atoms.(pl.ri) in
    set_rule ctx.ws (h) pl.ri;
    set_by ctx.ws h (Array.mapi (fun j (a : Query.pattern) -> find ctx.ws pl.be.(j) a.p pl.bw.(j)) ats);
    prove ctx (d + 1) h
  end

(* an instance of a rule whose head is the fact being checked: its body facts checked; all proved, it proves it *)
and backward_instance ctx d pl =
  let ats = ctx.prog.atoms.(pl.ri) in
  let ids = Array.mapi (fun j (a : Query.pattern) -> intern ctx pl.be.(j) a.p pl.bw.(j)) ats in
  let ws = ctx.ws in
  Array.iter (fun y -> check ctx (d + 1) y) ids;
  let x = find ws pl.he ctx.prog.head_p.(pl.ri) pl.hw in
  if x >= 0 && (not (has ws x 2)) && Array.for_all (fun y -> has ws y 2) ids then begin
    set_rule ws (x) pl.ri;
    set_by ws (x) ids;
    prove ctx d x
  end;
  if x >= 0 && has ws x 2 then raise_notrace Exit

and prove ctx d x =
  let ws = ctx.ws in
  if not (has ws x 2) then begin
    set_mark ws x 2;
    let pt = ctx.pt in
    let e = (fe ws (x)) and p = (fp ws (x)) and w = (fw ws (x)) in
    if find pt e p w < 0 then begin
      let y = add pt e p w 1 in
      set_rule pt (y) x;
      chain pt y
    end;
    plans ctx d;
    let fp = snd (Array.unsafe_get ctx.fwd d) in
    run_all fp e p w
  end

and check ctx d x =
  let ws = ctx.ws in
  if not (has ws x 1) then begin
    set_mark ws x 1;
    incr checked;
    if base ws x = 1 then prove ctx d x
    else begin
      let p = (fp ws (x)) in
      if p < ctx.prog.np && Char.code (Bytes.unsafe_get ctx.prog.reads p) land 2 <> 0 then begin
        plans ctx d;
        let bwd = Array.unsafe_get ctx.bwd d in
        try run_all bwd (fe ws (x)) p (fw ws (x)) with Exit -> ()
      end
    end
  end

(* ---- one group ---- *)

let cache : (int, program) Hashtbl.t = Hashtbl.create 8
let cache_m = Mutex.create ()

(* the program of a view's rules: compiled once for a rule set, again when the database's size has moved by a factor
   of 2 since its orders were chosen *)
let program (v : Store.view) =
  let key = Schema.rules_key v.schema in
  Mutex.protect cache_m (fun () ->
      let size = S.facts v in
      match Hashtbl.find_opt cache key with
      | Some p when (size <= 2 * p.size + 1024 && 2 * size + 1024 >= p.size) -> p
      | _ ->
        let p = make_program v in
        if Hashtbl.length cache > 16 then Hashtbl.reset cache;
        Hashtbl.replace cache key p;
        p)

let new_ctx ?facts prog v =
  { prog; ws = ws_create ?facts (); pt = ws_create (); v; round = max_int; cw = Array.make (Array.length prog.consts) (-1);
    fwd = [||]; bwd = [||]; cons = None; on_fwd = (fun _ -> ()); next = ints 64 0; spare = ints 64 0; nn = 0; derived = 0;
    limit = max_int; per_rule = Array.make (Array.length prog.rules) 0; vp = Bytes.empty }

let take ?facts prog v =
  let c =
    if facts <> None then None
    else Mutex.protect prog.pm (fun () -> match !(prog.pool) with c :: r -> prog.pool := r; Some c | [] -> None)
  in
  let c = match c with Some c -> c | None -> new_ctx ?facts prog v in
  c.v <- v;
  c.round <- max_int;
  Array.iteri (fun i x -> c.cw.(i) <- Option.value (S.word v x) ~default:(-1)) prog.consts;
  c.nn <- 0;
  c.derived <- 0;
  c.limit <- max_int;
  c.vp <- Bytes.empty;
  c.ws.with_ip <- true;
  Array.fill c.per_rule 0 (Array.length c.per_rule) 0;
  c

let give c =
  (* a context that held a large group's facts is let go, its memory with it *)
  if c.ws.cap <= 1 lsl 16 then begin
    reset c.ws;
    reset c.pt;
    c.on_fwd <- (fun _ -> ());
    Mutex.protect c.prog.pm (fun () -> c.prog.pool := c :: !(c.prog.pool))
  end

let with_ctx ?prog ?facts v f =
  let c = take ?facts (match prog with Some p -> p | None -> program v) v in
  match f c with
  | r -> give c; r
  | exception e -> give c; raise e

let[@inline never] push_next c x =
  if c.nn >= A.dim c.next then c.next <- regrow c.next c.nn (2 * c.nn) 0;
  A.unsafe_set c.next c.nn x;
  c.nn <- c.nn + 1

let rule_name c ri = c.prog.rules.(ri).name

let[@inline never] count_derived c ri =
  c.derived <- c.derived + 1;
  if ri >= 0 then c.per_rule.(ri) <- c.per_rule.(ri) + 1;
  if c.derived > c.limit then begin
    let best = ref 0 in
    Array.iteri (fun i n -> if n > c.per_rule.(!best) then best := i) c.per_rule;
    refuse "rule %s derived more than %d facts from a group of %d facts" (rule_name c !best) c.limit
      ((c.limit - !budget_base) / max 1 !budget_per)
  end

(* the head of a forward instance, at round r: a fact that is not there yet joins the next round *)
let emit c pl =
  incr derivations;
  let p = c.prog.head_p.(pl.ri) and e = pl.he and w = pl.hw in
  let ws = c.ws in
  let x = find ws e p w in
  if x >= 0 then begin
    if now ws x = 0 then begin
      set_now ws x 2;
      set_round ws x (c.round + 1);
      set_rule ws (x) pl.ri;
      count_derived c pl.ri;
      push_next c x
    end
  end
  else if not ((Bytes.length c.vp = 0 || Bytes.unsafe_get c.vp p <> '\000') && S.mem c.v e p w) then begin
    if e >= c.v.next_e then refuse "rule %s gives a fact about #%d, which does not exist" (rule_name c pl.ri) e;
    let x = add ws e p w 0 in
    set_now ws x 2;
    set_round ws x (c.round + 1);
    set_rule ws (x) pl.ri;
    count_derived c pl.ri;
    push_next c x
  end

(* semi-naive evaluation from round 0: [first] the facts of round 0, [seed] facts already of round 1 *)
(* [first] the [nf] facts of round 0; [seed] facts already of round 1. The rounds' facts in two buffers taken in turn,
   out of the collector's sight *)
let saturate c (first : ints) nf (seed : int list) =
  let ws = c.ws in
  plans c 0;
  let f0 = fst c.fwd.(0) in
  c.on_fwd <- emit c;
  (* the seeds of round 1 wait in the next round's list from the start *)
  c.nn <- 0;
  List.iter (fun x -> push_next c x) seed;
  let cur = ref first and ncur = ref nf and r = ref 0 in
  while !ncur > 0 || c.nn > 0 do
    c.round <- !r;
    let d = !cur in
    for i = 0 to !ncur - 1 do
      let x = A.unsafe_get d i in
      if now ws x > 0 && round ws x = !r then run_all f0 (fe ws x) (fp ws x) (fw ws x)
    done;
    (* this round's buffer takes the next round's facts *)
    let nx = c.next and nn = c.nn in
    c.next <- (if d != first then d else c.spare);
    c.spare <- nx;
    cur := nx;
    ncur := nn;
    c.nn <- 0;
    incr r
  done;
  c.round <- max_int;
  c.on_fwd <- (fun _ -> ())

(* B/F over the candidates (ids in the working set): each one checked; one without a proof deleted, and the facts its
   instances give, still there, checked in turn *)
let backward_forward c (cands : int list) =
  let ws = c.ws in
  let q = Queue.create () in
  List.iter (fun x -> Queue.add x q) cands;
  plans c 0;
  let f0 = fst c.fwd.(0) in
  c.round <- max_int;
  c.on_fwd <-
    (fun pl ->
      let p = c.prog.head_p.(pl.ri) in
      let h = find ws pl.he p pl.hw in
      if h >= 0 then (if now ws h > 0 && not (has ws h 4) then Queue.add h q)
      else
        (* one lookup: its state, present when above 0 *)
        let s = S.state c.v pl.he p pl.hw in
        if s > 0 then Queue.add (add ws pl.he p pl.hw s) q);
  while not (Queue.is_empty q) do
    let x = Queue.pop q in
    if not (has ws x 4) then begin
      check c 0 x;
      if not (has ws x 2) then begin
        set_mark ws x 4;
        (* the instances that lose a derivation: over the state before x goes (the facts deleted before it aside),
           so that x may fill several atoms of one instance *)
        let was = now ws x in
        set_now ws x 2;
        run_all f0 (fe ws (x)) (fp ws (x)) (fw ws (x));
        set_now ws x 0;
        if was > 0 then count_derived c (-1)
      end
    end
  done;
  c.on_fwd <- (fun _ -> ());
  (* an asserted retraction proved stays, only derived *)
  for x = 0 to ws.n - 1 do
    if has ws x 2 && now ws x = 0 then set_now ws x 2
  done;
  (* marks of B/F cleared (the proved table too): the insertion that follows reads states only *)
  for x = 0 to ws.n - 1 do Bytes.unsafe_set ws.mark x (Char.unsafe_chr (Char.code (Bytes.unsafe_get ws.mark x) land 24)) done;
  reset c.pt

(* every instance of a rule (not necessarily the program's: a removed one) over the state *)
let instances c ?extra ri (f : plan -> unit) =
  let pl = compile c ?extra ri (-2) State f in
  c.round <- max_int;
  pl.run 0 0

let value_of (v : Store.view) p w =
  match Schema.find v.schema p with Some d -> S.value v d.typ w | None -> Value.Int w

let fact_text (v : Store.view) e p w =
  let name = match Schema.find v.schema p with Some d -> d.name | None -> string_of_int p in
  Printf.sprintf "[#%d %s %s]" e name (Value.to_string (value_of v p w))

(* The reasoning of one group: [v0] the state before it, [v] after its asserted changes [changes] (Resolve's, in
   order) and [words] their values' words in [v]. Returns the view with the derived changes applied, and the group's changes: the
   asserted ones (a retraction a rule still derives becomes Now_derived), then the derived ones. Raises [Refused]. *)
let rec run ~(v0 : Store.view) (v : Store.view) (changes : Group.change array) (words : int array) =
  let t0 = Unix.gettimeofday () in
  match run_ ~v0 v changes words with
  | r -> seconds := !seconds +. (Unix.gettimeofday () -. t0); r
  | exception e -> seconds := !seconds +. (Unix.gettimeofday () -. t0); raise e

and run_ ~(v0 : Store.view) (v : Store.view) (changes : Group.change array) (words : int array) =
  let same = Schema.rules_key v0.schema = Schema.rules_key v.schema in
  if same && not (Schema.has_rules v.schema) then v, changes
  else
    let prog = program v in
    let reads p = if p < prog.np then Char.code (Bytes.unsafe_get prog.reads p) else 0 in
    (* nothing the rules read or give: nothing to do *)
    if same && Array.for_all (fun (ch : Group.change) -> reads ch.p = 0) changes then v, changes
    else
    with_ctx ~prog v (fun c ->
        let ws = c.ws in
        c.limit <- !budget_base + (!budget_per * Array.length changes);
        (* the rules removed or changed, and added or changed, by this group *)
        let old_rules = if same then [] else Schema.rules v0.schema and new_rules = if same then [] else Schema.rules v.schema in
        let removed = List.filter (fun (id, r) -> not (List.mem (id, r) new_rules)) old_rules in
        let added = List.filter (fun (id, r) -> not (List.mem (id, r) old_rules)) new_rules in
        let added_idx = List.filter_map (fun (id, _) -> let rec f i = if i >= Array.length prog.ids then None else if prog.ids.(i) = id then Some i else f (i + 1) in f 0) added in
        (* the asserted changes the rules may read: round 0, or candidates of B/F *)
        let cands = ref [] and first = ref [] in
        (* first the state each fact is left in by the group's last change of it, which is its state in [v]: no lookup *)
        Array.iteri
          (fun i (ch : Group.change) ->
            if reads ch.p <> 0 then begin
              let w = words.(i) and s = Group.after ch.kind in
              let x = find ws ch.e ch.p w in
              if x < 0 then ignore (add ws ch.e ch.p w s)
              else (Bytes.unsafe_set ws.base x (Char.unsafe_chr s); Bytes.unsafe_set ws.now x (Char.unsafe_chr s))
            end)
          changes;
        Array.iteri
          (fun i (ch : Group.change) ->
            let r = reads ch.p in
            if r <> 0 then begin
              let x = find ws ch.e ch.p words.(i) in
              match ch.kind with
              | Retracted ->
                (* no longer asserted, but still in the state until B/F decides (Motik et al. 2015: E loses it at
                   once, the materialisation only once it is disproved); not when the group asserted it again after *)
                if base ws x = 0 && not (has ws x 16) then begin
                  set_mark ws x 16;
                  set_now ws x 2;
                  cands := x :: !cands
                end
              | Added when r land 1 <> 0 && base ws x = 1 && (round ws (x)) <> 0 ->
                set_round ws (x) 0;
                first := x :: !first
              | _ -> ()
            end)
          changes;
        (* the facts a removed rule gave: each loses a derivation *)
        List.iter
          (fun (_, (name, text)) ->
            match Rules.of_text name text with
            | Error _ -> ()
            | Ok r -> (
              match r.head with
              | Never -> ()
              | Give h ->
                (* a removed rule over properties that are gone has no instance *)
                if List.for_all (fun (a : Query.pattern) -> Schema.find c.v.schema a.p <> None) r.where
                   && Schema.find c.v.schema h.p <> None
                then
                  instances c ~extra:r (-1) (fun pl ->
                      let x = find ws pl.he h.p pl.hw in
                      if x >= 0 then cands := x :: !cands
                      else if S.state c.v pl.he h.p pl.hw = 2 then cands := add ws pl.he h.p pl.hw 2 :: !cands)))
          removed;
        if !cands <> [] then backward_forward c (List.rev !cands);
        (* the facts an added rule gives over the state: round 1 *)
        let seed = ref [] in
        List.iter
          (fun ri ->
            match prog.rules.(ri).head with
            | Never -> ()
            | Give h ->
              c.round <- max_int;
              instances c ri (fun pl ->
                  incr derivations;
                  let e = pl.he and w = pl.hw in
                  let x = find ws e h.p w in
                  if x >= 0 then begin
                    if now ws x = 0 then (set_now ws x 2; set_round ws (x) 1; set_rule ws (x) ri; count_derived c ri; seed := x :: !seed)
                  end
                  else if not (S.mem c.v e h.p w) then begin
                    let x = add ws e h.p w 0 in
                    set_now ws x 2;
                    set_round ws (x) 1;
                    set_rule ws (x) ri;
                    count_derived c ri;
                    seed := x :: !seed
                  end))
          added_idx;
        if !first <> [] || !seed <> [] then begin
          let l = List.rev !first in
          let n = List.length l in
          let a = ints (max 1 n) 0 in
          List.iteri (fun i x -> A.unsafe_set a i x) l;
          saturate c a n (List.rev !seed)
        end;
        (* the constraints: an instance that involves a fact this group made present refuses it *)
        let has_never = Array.exists (fun (r : Rules.t) -> r.head = Never) prog.rules in
        if has_never then begin
          let violation pl =
            let r = prog.rules.(pl.ri) in
            let ats = atoms_of r in
            refuse "constraint %s: %s" r.name
              (String.concat " " (List.mapi (fun j (a : Query.pattern) -> fact_text c.v pl.be.(j) a.p pl.bw.(j)) (Array.to_list ats)))
          in
          let cons =
            match c.cons with
            | Some d -> d
            | None ->
              let d = dispatch c ~backward:false State (fun r -> r.head = Never) violation in
              c.cons <- Some d;
              d
          in
          c.round <- max_int;
          for x = 0 to ws.n - 1 do
            if now ws x > 0 && (base ws x = 0 || (round ws (x)) = 0) then run_all cons (fe ws (x)) (fp ws (x)) (fw ws (x))
          done;
          List.iter (fun ri -> if prog.rules.(ri).head = Never then instances c ri violation) added_idx
        end;
        (* the changes: the asserted ones, then the derived, in the order they were found *)
        let out = ref [] in
        let changes =
          Array.map
            (fun (ch : Group.change) ->
              match ch.kind with
              | Retracted -> (
                match S.word c.v ch.v with
                | Some w ->
                  let x = find ws ch.e ch.p w in
                  if x >= 0 && now ws x = 2 then { ch with kind = Group.Now_derived } else ch
                | None -> ch)
              | _ -> ch)
            changes
        in
        (* the facts whose state changed, put into the view at once, sorted by thing (S.set_sorted) *)
        let todo = ref [] in
        for x = 0 to ws.n - 1 do
          let b = base ws x and n = now ws x in
          if b <> n then begin
            let e = (fe ws (x)) and p = (fp ws (x)) and w = (fw ws (x)) in
            if has ws x 16 then (if n = 2 then todo := x :: !todo)
            else begin
              let kind = if n = 2 then Group.Derived else Group.Underived in
              out := { Group.kind; e; p; v = value_of c.v p w } :: !out;
              todo := x :: !todo
            end
          end
        done;
        let derived = Array.of_list (List.rev !out) in
        let xs = Array.of_list !todo in
        Array.sort (fun x y -> let c = compare (fe ws (x)) (fe ws (y)) in if c <> 0 then c else let c = compare (fp ws (x)) (fp ws (y)) in if c <> 0 then c else compare (fw ws (x)) (fw ws (y))) xs;
        let m = Array.length xs in
        let v' =
          S.set_sorted c.v (Array.map (fun x -> (fe ws (x))) xs) (Array.map (fun x -> (fp ws (x))) xs)
            (Array.map (fun x -> (fw ws (x))) xs) (Array.map (fun x -> now ws x) xs) m
        in
        (* the schema's own rules over derived facts: one value for a one-valued property; a unique value once *)
        Array.iter
          (fun (ch : Group.change) ->
            if ch.kind = Group.Derived then
              match Schema.find v'.schema ch.p with
              | Some d ->
                let x = match S.word v' ch.v with Some w -> find ws ch.e ch.p w | None -> -1 in
                let rn = if x >= 0 && (rule ws (x)) >= 0 then rule_name c (rule ws (x)) else "?" in
                if (not d.many) && S.count_values v' ch.e ch.p > 1 then
                  refuse "rule %s gives #%d a second value of %s, which takes one" rn ch.e d.name;
                if d.unique then begin
                  match S.word v' ch.v with
                  | Some w -> if S.count_things v' ch.p w > 1 then refuse "rule %s gives %s %s, which another thing has" rn d.name (Value.to_string ch.v)
                  | None -> ()
                end
              | None -> ())
          derived;
        v', Array.append changes derived)

(* ---- a large group: its facts all new, the derived ones appended ----
   The group's facts (the view lacks them all) are the working set's round 0; the rules run on them by rounds as on any
   group; the facts derived are returned in the order found, for the group's Bulk. Raises [Refused] past the budget.
   [None] when the group must take the ordinary path: a constraint, or a rule whose head gives a one-valued or unique
   property (the checks of those are the ordinary path's). *)
let bulk ~(own : string -> int option) (v : Store.view) (ge : Bulk.i32) (gp : Bulk.u16) (gw : Bulk.ints) n =
  let prog = program v in
  let plain =
    Array.for_all2
      (fun (r : Rules.t) hp ->
        r.head <> Never && match Schema.find v.schema hp with Some d -> d.many && not d.unique | None -> false)
      prog.rules prog.head_p
  in
  if not plain then None
  else
    let t0 = Unix.gettimeofday () in
    Fun.protect ~finally:(fun () -> seconds := !seconds +. (Unix.gettimeofday () -. t0)) @@ fun () ->
    (* a working set made at the size of the group and its consequences (LUBM derives 0.4 a fact) *)
    with_ctx ~prog ~facts:(n + (n / 2) + 64) v (fun c ->
        let ws = c.ws in
        Array.iteri
          (fun i (x : Value.t) ->
            if c.cw.(i) < 0 then
              match (match x with Text s -> own s | Float f -> own (Store.float_key f) | _ -> None) with
              | Some w -> c.cw.(i) <- w
              | None -> ())
          prog.consts;
        c.limit <- !budget_base + (!budget_per * n);
        c.vp <- Bytes.init prog.np (fun p -> if S.count_prop v p > 0 then '\001' else '\000');
        ws.with_ip <- prog.free_free;
        let first = ints (max 1 n) 0 in
        for i = 0 to n - 1 do
          let x =
            add ws (Int32.to_int (Bigarray.Array1.unsafe_get ge i)) (Bigarray.Array1.unsafe_get gp i) (Bigarray.Array1.unsafe_get gw i) 0
          in
          set_now ws x 1;
          set_round ws (x) 0;
          A.unsafe_set first i x
        done;
        bulk_index_seconds := !bulk_index_seconds +. (Unix.gettimeofday () -. t0);
        saturate c first n [];
        let nd = ws.n - n in
        let de = Bulk.i32 nd and dp = Bulk.u16 nd and dw = Bulk.ints nd in
        for k = 0 to nd - 1 do
          let x = n + k in
          Bigarray.Array1.unsafe_set de k (Int32.of_int (fe ws (x)));
          Bigarray.Array1.unsafe_set dp k (fp ws (x));
          Bigarray.Array1.unsafe_set dw k (fw ws (x))
        done;
        Some (c.v, de, dp, dw, nd))

(* by property: 1 a rule body reads it, 2 a rule head gives it; empty without rules *)
let reads (v : Store.view) = if Schema.has_rules v.schema then (program v).reads else Bytes.empty

(* ---- Why ---- *)

type proof =
  | Given of { e : int; p : int; v : Value.t }
  | By of { rule : string; e : int; p : int; v : Value.t; from : proof list }

(* a proof of (e p w) in view v, or None when it is not a fact *)
let why (v : Store.view) e p w =
  match S.state v e p w with
  | 0 -> None
  | 1 -> Some (Given { e; p; v = value_of v p w })
  | _ ->
    with_ctx v (fun c ->
        let ws = c.ws in
        let x = add ws e p w 2 in
        check c 0 x;
        let rec tree x =
          let e = (fe ws (x)) and p = (fp ws (x)) and w = (fw ws (x)) in
          if base ws x = 1 then Given { e; p; v = value_of v p w }
          else
            match (rule ws (x)), (by ws (x)) with
            | ri, ids when ri >= 0 ->
              By { rule = rule_name c ri; e; p; v = value_of v p w; from = Array.to_list (Array.map tree ids) }
            | _ -> failwith (Printf.sprintf "Reason.why: %s has no proof: the materialisation is wrong" (fact_text v e p w))
        in
        if has ws x 2 then Some (tree x)
        else failwith (Printf.sprintf "Reason.why: %s has no proof: the materialisation is wrong" (fact_text v e p w)))

(* the message of a retraction of a fact only derived (choice 10.4 of the design) *)
let derived_message (v : Store.view) e p w =
  match (try why v e p w with Failure _ -> None) with
  | Some (By { rule; from; _ }) ->
    let leaf = function Given g -> (g.e, g.p, g.v) | By b -> (b.e, b.p, b.v) in
    let texts =
      List.map (fun f -> let e, p, x = leaf f in fact_text v e p (Option.value (S.word v x) ~default:0)) from
    in
    Printf.sprintf "%s is derived by rule %s from %s: retract one of those" (fact_text v e p w) rule (String.concat " and " texts)
  | _ -> Printf.sprintf "%s is derived by a rule" (fact_text v e p w)
