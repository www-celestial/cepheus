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
  let[@inline never] set_sorted ~olds v es ps ws ss n = Store.set_sorted ~olds v es ps ws ss n
  let[@inline never] facts v = Store.facts v
  let[@inline never] distinct v p = Store.distinct v p
  let[@inline never] word_intern v x = Store.word_intern v x
  let[@inline never] value v t w = Store.value v t w
  let[@inline never] iter_values v e p f = Store.iter_values v e p f
  let[@inline never] iter_things v p w f = Store.iter_things v p w f
  let[@inline never] iter_values_st v e p f = Store.iter_values_st v e p f
  let[@inline never] iter_prop v p f = Store.iter_prop v p f
  let[@inline never] count_values v e p = Store.count_values v e p
  let[@inline never] iter_facts v e f = Store.iter_facts v e f
end

exception Refused of string

let refuse fmt = Printf.ksprintf (fun s -> raise (Refused s)) fmt

(* a write of an aggregate's property, refused *)
let agg_message (v : Store.view) p =
  Printf.sprintf "%s is given by an aggregate rule: no write adds or retracts it"
    (match Schema.find v.schema p with Some d -> d.name | None -> string_of_int p)

(* the budget of a data write: derived changes <= base + per x asserted changes (choice 10.7 of the design) *)
let budget_base = ref 100_000
let budget_per = ref 100

(* A change: a group that changes the rules, or the ontology (a group past a data write's budget that writes a fact of a
   relation the rules are unfolded on in the state before it: [ontology] below). Its budget is a data
   write's plus [change_per] x the facts of the database before it (the design's section 5.11): a change may derive in
   proportion to the database it applies to, and a runaway rule is still stopped, named. The threaded writer runs a
   change on the background path ([Background]); a fork and the deterministic core run it in the group, with the
   same budget, so they accept and refuse exactly what the database does (G8). *)
let change_per = ref 4

(* raised by [run ~background:true] for a change, before any reasoning for a change of the rules, past the data
   budget for a change of the ontology: the writer takes the group to the background path *)
exception Background

(* past a data write's budget: a refusal, unless the group changes the ontology (then a change's budget) *)
exception Exceeded of string

(* never set: the [stop] of a group that cannot be cancelled *)
let never = Atomic.make false

(* counters for the benchmarks and the tests: rule instances found, facts checked by B/F or Why, and the seconds spent
   reasoning (Reason.run and Reason.bulk) *)
let derivations = ref 0
let checked = ref 0
let seconds = ref 0.
let bulk_index_seconds = ref 0. (* of [seconds]: a load's facts put into the working set, before the rules run *)
let spec_groups = ref 0  (* groups reasoned with the rules unfolded on their small relations *)
let gen_groups = ref 0  (* and with the rules as written *)
let respecs = ref 0  (* groups begun unfolded, then reasoned again as written: a frozen relation's fact changed *)
let batches = ref 0  (* closure modules run from scratch *)
let trace = ref false  (* the phases of a closure from scratch, printed (the benchmarks) *)
let specialise = ref true  (* false: the rules always run as written (the tests compare both paths) *)
let walk_retract = ref true  (* false: a closure's retractions by B/F through its rules' plans (the tests compare) *)
let module_seconds = ref 0. (* of [seconds]: the closure modules' work, their facts found and put aside *)
let bulk_groups = ref 0  (* large groups reasoned on their sorted prefix *)
let merge_seconds = ref 0. (* of [seconds]: equalities applied, their facts rewritten *)

(* ---- hashing ---- *)

let[@inline] mix k = let k = k * 0x2545F4914F6CDD1D in k lxor (k lsr 29)
let[@inline] h3 e p w = mix ((e * 0x9E3779B1) lxor (p lsl 40) lxor (w * 0x85EBCA77) lxor (w lsr 31))
let[@inline] h2 a b = mix ((a lsl 40) lxor (b * 0x9E3779B1) lxor (b lsr 29))

(* The working set's arrays are Bigarrays: out of the collector's sight (a load's working set holds millions of facts,
   which the major collector would otherwise scan at each cycle), and made at their size once for a load. *)
module A = Bigarray.Array1

type ints = (int, Bigarray.int_elt, Bigarray.c_layout) A.t

let ints n v : ints = let a = A.create Bigarray.Int Bigarray.c_layout n in A.fill a v; a

(* cells written before they are read: not filled *)
let ints_raw n : ints = A.create Bigarray.Int Bigarray.c_layout n

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

(* every cell -1: an empty slot's key, and its head, so that a key absent gives no fact *)
let[@inline never] new_slots size = ints (3 * size) (-1)

(* [keys]: the keys expected, for the size of the table (it grows past them); [facts]: the facts' chains *)
let[@inline never] idx_create ?(facts = 64) ?(keys = facts) () =
  let size = slots_for keys in
  { sl = new_slots size; mask = size - 1; used = 0; slots = ints_raw (size / 2); next = ints_raw facts }

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

let[@inline never] idx_add t a b x =
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
  mutable f2 : ints;  (* fact x: f2.(2x) its thing and property (thing lsl 16 + property: a property id is below
                         65,536, Schema.first_thing), f2.(2x+1) its value word: one cache line a fact *)
  mutable cap : int;
  mutable base : Bytes.t;  (* the state in the view the reasoning started from: 0 absent, 1 asserted, 2 only derived *)
  mutable old : Bytes.t;  (* the state before the group (its asserted changes too): what Not and aggregates compare *)
  mutable now : Bytes.t;  (* the state now *)
  mutable mark : Bytes.t;  (* B/F and Why: 1 checked, 2 proved, 4 deleted; 8 chained; 16 an asserted retraction;
                              32 an asserted addition *)
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
  mutable nb : int;  (* the sorted prefix of a large group (below): facts 0 .. nb-1; 0 none *)
  mutable b_old : int;  (* its facts of things below b_lo: 0 .. b_old-1, found by binary search *)
  mutable b_lo : int;  (* thing b_lo + k (a new thing): its facts b_off.(k) .. b_off.(k+1) - 1 *)
  mutable b_off : Bulk.i32;
  mutable bk : Bulk.t;  (* the group's facts by (property, value, thing) *)
  mutable b_has : Bytes.t;  (* by property: 1 its facts are in the prefix *)
  mutable need : Bytes.t;  (* by property, the chains a fact of it joins: 1 ie, 2 iw, 4 ip; empty: all of them *)
  mutable fresh : int;  (* things from this one on are the group's new things: the view holds no fact about them (a
                           large group's; max_int otherwise) *)
}

(* [keys]: the keys expected in the chains (a large group's prefix is in none) *)
let[@inline never] ws_create ?(facts = 64) ?keys () =
  let c = max 64 facts in
  let keys = match keys with Some k -> max 64 k | None -> c in
  let size = ref 128 in
  while !size < 2 * c do size := 2 * !size done;
  (* every cell of a fact is written when it is added (or put in the prefix): only [set] and the slots need filling *)
  { n = 0; f2 = ints_raw (2 * c); cap = c; base = Bytes.create c; old = Bytes.create c; now = Bytes.create c;
    mark = Bytes.create c; round = ints_raw c; rule = ints_raw c; by = [||]; set = ints !size (-1);
    smask = !size - 1; ie = idx_create ~facts:c ~keys (); iw = idx_create ~facts:c ~keys ();
    ip = idx_create ~facts:c ~keys:32 (); with_ip = true; nb = 0; b_old = 0; b_lo = 0; b_off = Bulk.i32 0; bk = Bulk.empty;
    b_has = Bytes.empty; need = Bytes.empty; fresh = max_int }

let[@inline] fe ws x = A.unsafe_get ws.f2 (2 * x) lsr 16
let[@inline] fp ws x = A.unsafe_get ws.f2 (2 * x) land 0xFFFF
let[@inline] fw ws x = A.unsafe_get ws.f2 ((2 * x) + 1)
let[@inline] set_f ws x e p w = A.unsafe_set ws.f2 (2 * x) ((e lsl 16) lor p); A.unsafe_set ws.f2 ((2 * x) + 1) w
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
  (* a property id is below 65,536 (the packing of f2): any other p is no fact *)
  if ws.n = 0 || p lsr 16 <> 0 then -1
  else begin
    let set = ws.set and mask = ws.smask and ep = (e lsl 16) lor p in
    let i = ref (h3 e p w land mask) and r = ref (-2) in
    while !r = -2 do
      let x = A.unsafe_get set !i in
      if x = -1 then r := -1
      else if A.unsafe_get ws.f2 (2 * x) = ep && A.unsafe_get ws.f2 ((2 * x) + 1) = w then r := x
      else i := (!i + 1) land mask
    done;
    !r
  end

let[@inline never] place ws x =
  let i = ref (h3 (fe ws x) (fp ws x) (fw ws x) land ws.smask) in
  while A.unsafe_get ws.set !i <> -1 do i := (!i + 1) land ws.smask done;
  A.unsafe_set ws.set !i x

let[@inline never] grow ws =
  let n = ws.n in
  let c = 2 * ws.cap in
  let gb a = let b = Bytes.make c '\000' in Bytes.blit a 0 b 0 n; b in
  ws.f2 <- regrow ws.f2 (2 * n) (2 * c) 0;
  ws.cap <- c;
  ws.round <- regrow ws.round n c (-1); ws.rule <- regrow ws.rule n c (-1);
  ws.base <- gb ws.base; ws.old <- gb ws.old; ws.now <- gb ws.now; ws.mark <- gb ws.mark;
  List.iter (fun t -> t.next <- regrow t.next n c (-1)) [ ws.ie; ws.iw; ws.ip ]

let[@inline never] grow_set ws =
  let size = 2 * A.dim ws.set in
  ws.set <- ints size (-1);
  ws.smask <- size - 1;
  for x = 0 to ws.n - 1 do place ws x done

(* a fact the working set did not hold: its id *)
let[@inline never] add ws e p w base =
  if p lsr 16 <> 0 || e < 0 then invalid_arg "Reason.add: not a fact";
  if ws.n >= ws.cap then grow ws;
  if 2 * (ws.n + 1) > A.dim ws.set then grow_set ws;
  let x = ws.n in
  set_f ws x e p w;
  Bytes.unsafe_set ws.base x (Char.unsafe_chr base);
  Bytes.unsafe_set ws.old x (Char.unsafe_chr base);
  Bytes.unsafe_set ws.now x (Char.unsafe_chr base);
  Bytes.unsafe_set ws.mark x '\000';
  A.unsafe_set ws.round x (-1);
  A.unsafe_set ws.rule x (-1);
  ws.n <- x + 1;
  place ws x;
  x

let[@inline] now ws x = Char.code (Bytes.unsafe_get ws.now x)
let[@inline] base ws x = Char.code (Bytes.unsafe_get ws.base x)
let[@inline] old ws x = Char.code (Bytes.unsafe_get ws.old x)
let[@inline] has ws x m = Char.code (Bytes.unsafe_get ws.mark x) land m <> 0
let[@inline] set_mark ws x m = Bytes.unsafe_set ws.mark x (Char.unsafe_chr (Char.code (Bytes.unsafe_get ws.mark x) lor m))

(* in the chains: a fact the view lacks (base absent) once it is present; in a large group, only the chains some
   plan reads for its property ([need]) *)
let[@inline never] chain ws x =
  if not (has ws x 8) then begin
    set_mark ws x 8;
    let p = fp ws x in
    let nd = if p < Bytes.length ws.need then Char.code (Bytes.unsafe_get ws.need p) else 7 in
    if nd land 1 <> 0 then idx_add ws.ie p (fe ws x) x;
    if nd land 2 <> 0 then idx_add ws.iw p (fw ws x) x;
    if ws.with_ip && nd land 4 <> 0 then idx_add ws.ip p 0 x
  end

let[@inline never] set_now ws x s =
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
  end;
  if ws.nb > 0 then begin
    ws.nb <- 0;
    ws.b_old <- 0;
    ws.b_off <- Bulk.i32 0;
    ws.bk <- Bulk.empty;
    ws.b_has <- Bytes.empty
  end;
  ws.need <- Bytes.empty;
  ws.fresh <- max_int

(* ---- the sorted prefix of a large group ----
   A load's facts are many and all new: hashing each into the chains cost more than the reasoning (0.4 us a fact, one
   domain, for 1.35 M facts). So in a large group the facts of the properties the rules read or give are the working
   set's facts 0 .. nb-1, in (thing, property, value) order, present at round 0: in [set], put there by several
   domains, and in no chain. A thing's facts are a range of the prefix (offsets over the new things, a binary search
   below them), a (property, value)'s things a range of the group's order by property, which its run needs anyway
   (Bulk.make, done before the reasoning). Facts no rule reads or gives stay out: no plan reads them, no head is one. *)

let[@inline] in_prefix ws p = p < Bytes.length ws.b_has && Bytes.unsafe_get ws.b_has p <> '\000'

(* the values of (e p _) in the prefix *)
let[@inline never] b_iter_e ws e p f =
  if in_prefix ws p then begin
    let lo = ref 0 and hi = ref 0 in
    let k = e - ws.b_lo in
    if k >= 0 then begin
      if k + 1 < Bigarray.Array1.dim ws.b_off then begin
        lo := Int32.to_int (Bigarray.Array1.unsafe_get ws.b_off k);
        hi := Int32.to_int (Bigarray.Array1.unsafe_get ws.b_off (k + 1))
      end
    end
    else begin
      let l = ref 0 and h = ref ws.b_old in
      while !l < !h do let m = (!l + !h) lsr 1 in if fe ws m < e then l := m + 1 else h := m done;
      lo := !l;
      hi := !l;
      while !hi < ws.b_old && fe ws !hi = e do incr hi done
    end;
    for x = !lo to !hi - 1 do if fp ws x = p then f (fw ws x) done
  end

(* the things of (_ p w) in the prefix *)
let[@inline never] b_iter_w ws p w f =
  if in_prefix ws p then begin
    let b = ws.bk in
    let l = ref (Array.unsafe_get b.poff p) and h = ref (Array.unsafe_get b.poff (p + 1)) in
    let top = !h in
    while !l < !h do let m = (!l + !h) lsr 1 in if Bulk.pword b m < w then l := m + 1 else h := m done;
    let r = ref !l in
    while !r < top && Bulk.pword b !r = w do f (Bulk.pthing b !r); incr r done
  end

(* every fact of p in the prefix *)
let[@inline never] b_iter_p ws p f =
  if in_prefix ws p then begin
    let b = ws.bk in
    for r = Array.unsafe_get b.poff p to Array.unsafe_get b.poff (p + 1) - 1 do f (Bulk.pthing b r) (Bulk.pword b r) done
  end

(* the prefix's facts into [set] on several domains: the table cut into regions of consecutive slots, a domain a
   region, each placing the facts whose slot falls in it; a fact whose probe would leave its region is put aside and
   placed after, by the usual probe (which may cross regions): every fact is where [find] looks for it. *)
let[@inline never] place_prefix ws nb =
  let size = A.dim ws.set in
  let regions = if nb < 50_000 || !Bulk.threads <= 1 then 1 else (let r = ref 1 in while 2 * !r <= !Bulk.threads && 2 * !r <= size / 1024 do r := 2 * !r done; !r) in
  if regions = 1 then for x = 0 to nb - 1 do place ws x done
  else begin
    let per = size / regions in
    let aside = Array.make regions [] in
    Bulk.parallel ~d:!Bulk.threads regions (fun r ->
        let lo = r * per and hi = (r + 1) * per and set = ws.set and mask = ws.smask and l = ref [] in
        for x = 0 to nb - 1 do
          let i = h3 (fe ws x) (fp ws x) (fw ws x) land mask in
          if i >= lo && i < hi then begin
            let i = ref i in
            while !i < hi && A.unsafe_get set !i <> -1 do incr i done;
            if !i < hi then A.unsafe_set set !i x else l := x :: !l
          end
        done;
        aside.(r) <- !l);
    Array.iter (fun l -> List.iter (place ws) (List.rev l)) aside
  end


(* ---- buffers, sets and maps of ints, out of the collector's sight (the closure modules' walks) ---- *)

type buf = { mutable b : ints; mutable bn : int }

let[@inline never] buf_create n = { b = ints (max 16 n) 0; bn = 0 }
let[@inline] buf_push q x = if q.bn >= A.dim q.b then q.b <- regrow q.b q.bn (2 * A.dim q.b) 0; A.unsafe_set q.b q.bn x; q.bn <- q.bn + 1
let[@inline] buf_get q i = A.unsafe_get q.b i

(* a set of non-negative ints, cleared at the cost of what it held *)
type iset = { mutable keys : ints; mutable imask : int; used : buf }

let iset_create () = { keys = ints 64 (-1); imask = 63; used = buf_create 32 }

let[@inline never] iset_clear s = for i = 0 to s.used.bn - 1 do A.unsafe_set s.keys (buf_get s.used i) (-1) done; s.used.bn <- 0

let rec iset_add s k =
  if 2 * (s.used.bn + 1) > s.imask + 1 then begin
    let old = Array.init s.used.bn (fun i -> A.unsafe_get s.keys (buf_get s.used i)) in
    iset_clear s;
    let size = 2 * (s.imask + 1) in
    s.keys <- ints size (-1);
    s.imask <- size - 1;
    Array.iter (fun k -> ignore (iset_add s k)) old
  end;
  let i = ref (mix k land s.imask) in
  while (let x = A.unsafe_get s.keys !i in x <> -1 && x <> k) do i := (!i + 1) land s.imask done;
  if A.unsafe_get s.keys !i = k then false
  else (A.unsafe_set s.keys !i k; buf_push s.used !i; true)

let iset_mem s k =
  let i = ref (mix k land s.imask) in
  while (let x = A.unsafe_get s.keys !i in x <> -1 && x <> k) do i := (!i + 1) land s.imask done;
  A.unsafe_get s.keys !i = k

(* a map of non-negative ints to dense ids 0, 1, ..., in their order of arrival *)
type imap = { mk_keys : ints; mk_vals : ints; mk_mask : int; mutable mk_n : int; mk_of : buf }

let[@inline never] imap_create n =
  let size = ref 64 in
  while !size < 2 * n do size := 2 * !size done;
  { mk_keys = ints !size (-1); mk_vals = ints !size 0; mk_mask = !size - 1; mk_n = 0; mk_of = buf_create n }

let[@inline never] imap_id m k =
  let i = ref (mix k land m.mk_mask) in
  while (let x = A.unsafe_get m.mk_keys !i in x <> -1 && x <> k) do i := (!i + 1) land m.mk_mask done;
  if A.unsafe_get m.mk_keys !i = k then A.unsafe_get m.mk_vals !i
  else begin
    let id = m.mk_n in
    A.unsafe_set m.mk_keys !i k;
    A.unsafe_set m.mk_vals !i id;
    m.mk_n <- id + 1;
    buf_push m.mk_of k;
    id
  end

(* ---- the compiled program ---- *)

type plan = {
  ri : int;  (* the rule: an index of the program's rules *)
  be : int array;  (* the instance being enumerated: each body atom's fact, its thing, property and value *)
  bp : int array;
  bw : int array;
  mutable he : int;  (* and its head's thing, property and value *)
  mutable hp : int;
  mutable hw : int;
  mutable hok : bool;  (* the head fits its property (a property known only at the instance, or a type) *)
  mutable run : int -> int -> int -> unit;  (* the matched fact's thing, property and value *)
}

let dummy = { ri = -1; be = [||]; bp = [||]; bw = [||]; he = 0; hp = 0; hw = 0; hok = true; run = (fun _ _ _ -> ()) }

(* Which plans a fact runs, as slots: by its property, by (property, value) for an atom whose value is a constant (open
   addressing: no allocation, no generic hash, per fact), and every fact for an atom whose property is a variable. The
   index is the program's; each context compiles a slot's plan when it first runs, one copy a recursion depth (a
   plan's bindings are its own), so a deep check compiles only the plans it meets. *)
type index = {
  byp : int array array;
  kp : int array;  (* -1: an empty slot *)
  kw : int array;
  kv : int array array;
  kmask : int;
  kn : int;
  any : int array;
  slots : (int * int) array;  (* each slot's rule and matched atom (its position in the body; -1 the head) *)
}

(* A closure module (the reasoner design, section 5.7, after Hu, Motik, Horrocks 2019): the rules of a transitive
   closure, recognised in one of two shapes, whose new facts are found by walks instead of rule instances.
   - prp-trp: [x T y] [y T z] -> [x T z]: the edges are T's facts; T is closed.
   - linear: [x E y] -> [x T y] and [x E y] [y T z] -> [x T z], E another property: T = E* . (E u B), B the facts of T
     asserted or derived by other rules. *)
type closure = {
  m_rule : int;  (* prp-trp's rule, or the linear step's *)
  m_base : int;  (* the linear base rule; -1 for prp-trp *)
  m_t : int;
  m_e : int;  (* m_t for prp-trp *)
  m_side : bool;  (* no other rule reads T or gives T or E: a batch's facts go to the group's output directly *)
  m_walk : bool;  (* no other rule gives T or E: T's edges are its facts asserted (prp-trp) or E's facts (linear), and a
                     retraction is decided by walks *)
}

(* The frozen relations of a program specialised on them (the design's section 5.4): its rules unfolded on their
   facts, valid while they keep those facts. *)
type spec = {
  rels : (int * int) array;  (* (property, value word, or -1 for all its facts) *)
  frozen : Bytes.t;  (* by property: 1 every fact of it is frozen, 2 those of some values *)
  frozen_ws : int array array;  (* by property: the frozen values, sorted, when frozen.(p) = 2 *)
  rfacts : int array array;  (* each relation's facts at the build: (thing, value) words, sorted *)
  mutable sruns : Store.run array;  (* the runs and stamps they were last seen with (Store.stamp) *)
  mutable stamps : Store.stamp array;
}

type program = {
  key : int;
  rules : Rules.t array;  (* an unfolded rule keeps its generic rule's name; positive patterns only, a plain head *)
  src : Rules.t array;  (* the rules as defined, their Nots and aggregates in their patterns (Rules.split) *)
  natoms : Query.pattern array array;  (* each rule's positive patterns, then its Nots' patterns *)
  nots : Query.pattern array array array;  (* each rule's Nots, their patterns' properties plain *)
  own : int list array array;  (* and their own variables *)
  aggs : Rules.agg option array;
  strat : int array;  (* each rule's stratum (Rules.strata) *)
  nstrata : int;
  stratified : bool;  (* some rule has a Not or an aggregate: strata, Not checks, flips *)
  pstrat : (int * int) list array;  (* by property: the heads' value words (-1: any) and their strata *)
  anystrat : int;  (* the stratum of a head whose property is a variable, -1 none *)
  agg_rule : int array;  (* by property: the aggregate rule that gives it, -1 none *)
  ix_ins_s : index array;  (* insertion, by stratum ([ix_ins] when there is one) *)
  ids : int array;  (* their things *)
  sty : Value.typ option array array;  (* each rule's static types (Rules.static_types); None: the property's *)
  never : bool array;  (* a constraint *)
  bad_head : string array;  (* "": the head fits; else what every instance's group is refused with *)
  atoms : Query.pattern array array;  (* each rule's body, as an array *)
  free_free : bool;  (* a plan of a fact joins an atom with neither side bound: the working set keeps the index by
                        property *)
  np : int;
  reads : Bytes.t;  (* by property: 1 a rule body reads it, 2 a rule head gives it *)
  consts : Value.t array;  (* the texts and floats of the rules, looked up in each view's dictionary *)
  orders : (int * int, int array) Hashtbl.t;  (* (rule, matched atom) -> the order of the other atoms, when first
                                                   compiled, under [pm] *)
  size : int;  (* the facts of the view the program was made on *)
  modules : closure array;
  in_module : bool array;  (* rules a module runs for insertion *)
  ix_ins : index;  (* forward, the modules' rules aside: insertion *)
  ix_lost : index;  (* forward: the instances a deleted fact loses (B/F) *)
  ix_lost_walk : index;  (* the same, the rules of closures retracted by walks aside *)
  ix_pf : index;  (* forward among the proved facts *)
  ix_bw : index;  (* backward: the head matched *)
  ix_cons : index;  (* the constraints, forward *)
  spec : spec option;
  lists : (int * int array) array;  (* the templates' lists (property, its facts as (thing, value) words, sorted) the
                                       rules as written were unfolded on: a write of one is a change of the rules *)
  islist : Bytes.t;  (* by property: 1 a template's list *)
  eq : bool;  (* a rule makes things the same (its head gives cepheus/same): the classes of equal things are kept *)
  cthings : (int, unit) Hashtbl.t;  (* the things the rules name: they never become the same as another *)
  mutable lruns : Store.run array;  (* the runs and stamps the lists were last seen with (Store.stamp) *)
  mutable lstamps : Store.stamp array;
  pool : ctx list ref;
  pm : Mutex.t;
}

and disp = { ix : index; pa : plan array; mk : int -> plan }

and ctx = {
  prog : program;
  ws : ws;
  mutable v0 : Store.view;  (* the state before the group: Not's and aggregates' "before" *)
  mutable cur : int;  (* the stratum being maintained: the facts of lower ones are decided; -1 none *)
  bfqs : int Queue.t array;  (* B/F's candidates by stratum ([bfqs.(0) == bfq]) *)
  ins_s : disp option array;
  xplans : (int * int * int, plan) Hashtbl.t;  (* the plans of Not flips and aggregates: (rule, atom, kind) *)
  pt : ws;  (* the facts proved, B/F's and Why's: a table of their own; [rule] holds each one's id in [ws] *)
  mutable v : Store.view;
  mutable round : int;  (* the round evaluated; max_int: every fact visible *)
  cw : int array;  (* the words of prog.consts in [v], -1 for a text it lacks *)
  mutable ins : disp option;
  mutable lost : disp option;
  mutable lost_walk : disp option;
  mutable cons : disp option;
  mutable pf : disp array;  (* by depth *)
  mutable bwd : disp array;  (* by depth *)
  bfq : int Queue.t;  (* B/F's candidates *)
  mutable next : ints;  (* the next round's facts *)
  mutable spare : ints;  (* the round's facts, the buffer before *)
  mutable nn : int;
  mutable derived : int;  (* derived changes so far *)
  mutable limit : int;
  mutable whole : bool;  (* the group is a change: [limit] is a change's, [stop] is checked *)
  mutable stop : bool Atomic.t;  (* set: a change cancelled (its database closes) *)
  mutable vp : Bytes.t;  (* by property: 1 when the view may hold facts of it (a load: the view lacks most); empty: all *)
  per_rule : int array;
  mutable side_e : Bulk.i32;  (* the modules' facts that go to the output directly: things, properties, values *)
  mutable side_p : Bulk.u16;
  mutable side_w : ints;
  mutable ns : int;
  mbatch : int array;  (* by module: the round of its batch in this group, -1 none yet, -2 it ran incrementally *)
  mfresh : bool array;  (* by module: the state before the group held no fact of its closure *)
  buf_a : buf;  (* the walks' buffers *)
  buf_b : buf;
  seen : iset;  (* a walk's visited things *)
  seen2 : iset;
  mutable walked : Bytes.t;  (* by property: 1 its facts are a closure decided by its module's walks in this group *)
  mutable xk : plan -> unit;  (* where the plans of flips and aggregates send their instances *)
  mutable plain_derive : bool;  (* a large group whose rules derive without Not or aggregates (only constraints have
                                   them): its rounds may run on several domains *)
  heads_none : (int * int, bool) Hashtbl.t;  (* a change: does the view hold no fact (_ p w) of a head (p, w) *)
  (* equality (the reasoner design, section 5.10): the rules read the facts of representatives only *)
  mutable eqon : bool;  (* some thing is not its own representative: the plans skip its facts *)
  mutable nr : (int, int) Hashtbl.t;  (* the view's things that are not representatives: x -> its representative *)
  mutable nrbits : Bytes.t;  (* and a bit a thing (from Schema.first_thing): one of them *)
  eqt : (int, int) Hashtbl.t;  (* the representatives this group changed: x -> its representative now *)
  mutable eqbits : Bytes.t;  (* a bit a thing: in [eqt] *)
  mutable eqset : int list;  (* the things in [eqt], their bits cleared at the next group *)
  mutable pend : (int * int * int) list;  (* the equalities found in the round: (a, b, rule) *)
  mutable boom : int list;  (* classes to take apart and derive again (B/F): their representatives *)
  exploded : (int, unit) Hashtbl.t;
  mutable refill : int list;  (* the asserted facts of a class taken apart: round 0 of the insertion *)
  mutable why_mode : bool;  (* Why: a fact of a class is proved by the asserted fact of a member it rewrites *)
}

(* ---- equality: the classes of equal things ----
   [x cepheus/same r] (derived, one a thing that is not a representative) holds the classes. The view's non
   representatives are read once a view (a table rebuilt when the facts of cepheus/same change: never changed once
   made, so that several domains may read it); a group's changes are in the context's [eqt] above it. *)
let reps_slot : (Store.run array * Store.stamp * (int, int) Hashtbl.t * Bytes.t) option Atomic.t = Atomic.make None

let[@inline] bit (b : Bytes.t) x =
  let i = x - Schema.first_thing in
  i >= 0 && i lsr 3 < Bytes.length b && Char.code (Bytes.unsafe_get b (i lsr 3)) land (1 lsl (i land 7)) <> 0

let[@inline never] set_bit (b : Bytes.t) x on =
  let i = x - Schema.first_thing in
  let k = i lsr 3 in
  let b = if k < Bytes.length b then b else (let b' = Bytes.make (max (k + 1) (2 * Bytes.length b)) '\000' in Bytes.blit b 0 b' 0 (Bytes.length b); b') in
  let m = 1 lsl (i land 7) in
  Bytes.unsafe_set b k (Char.unsafe_chr (if on then Char.code (Bytes.unsafe_get b k) lor m else Char.code (Bytes.unsafe_get b k) land lnot m));
  b

let [@inline never] nonreps (v : Store.view) =
  let st = Store.stamp v Schema.p_same (-1) in
  match Atomic.get reps_slot with
  | Some (runs, st', t, b) when runs == v.runs && Store.same_stamp st st' -> t, b
  | _ ->
    let t = Hashtbl.create 64 and b = ref Bytes.empty in
    if Store.count_prop v Schema.p_same > 0 then begin
      b := Bytes.make (((v.next_e - Schema.first_thing) lsr 3) + 1) '\000';
      Store.iter_prop v Schema.p_same (fun e w -> Hashtbl.replace t e w; b := set_bit !b e true)
    end;
    Atomic.set reps_slot (Some (v.runs, st, t, !b));
    t, !b

(* a thing's representative now: one bit read for a thing of no class (the usual case) *)
let[@inline] rep_of c x =
  if bit c.eqbits x then Hashtbl.find c.eqt x
  else if bit c.nrbits x then Hashtbl.find c.nr x
  else x

let[@inline never] set_rep c x r =
  if not (bit c.eqbits x) then (c.eqbits <- set_bit c.eqbits x true; c.eqset <- x :: c.eqset);
  Hashtbl.replace c.eqt x r

let[@inline] is_rep c x = rep_of c x = x

exception Respec of int * int
(* a frozen relation's fact (property, value) changes: the group is reasoned again with the generic rules *)

let[@inline] is_text_const (x : Value.t) = match x with Text _ | Float _ -> true | _ -> false

let[@inline never] inline_word (x : Value.t) =
  match x with
  | Int n | Date n | Money n | Link n -> n
  | Bool b -> if b then 1 else 0
  | Text _ | Float _ -> invalid_arg "Reason.inline_word"

let[@inline never] atoms_of (r : Rules.t) = Array.of_list r.where

(* the code of a property's type (Value.code), -1 for no property *)
let[@inline] ptype (v : Store.view) p = match Schema.find v.schema p with Some d -> Value.code d.typ | None -> -1

let link_code = Value.code Value.Tlink

(* does a property of type code t take value x *)
let[@inline never] fits_code t (x : Value.t) =
  match x with
  | Int _ -> t = 0
  | Float _ -> t = 1
  | Bool _ -> t = 2
  | Text _ -> t = 3
  | Date _ -> t = 4
  | Money _ -> t >= 5 && t land 15 = 5
  | Link _ -> t = link_code

(* the other atoms of a rule in the order a plan joins them: each step the atom of the best class for the variables
   bound so far, then the fewest candidates by the store's counts. The classes come first because counts change (a
   rule defined on an empty database, a load whose facts the view does not hold yet) and a constant is not selective
   ([x type Person] has thousands of rows, the design's section 2.2: 1,870x more work in the prototype's first
   order): both sides bound (a test), then one side bound by a variable or by a thing in the thing's place, then a
   value bound by a constant, then nothing bound; an atom whose property is a variable not bound yet, last. *)
let [@inline never] choose_order ?(counts = true) ?atoms ?among (v : Store.view) (r : Rules.t) pos =
  let atoms = match atoms with Some a -> a | None -> atoms_of r in
  let nb = Array.length atoms in
  let bound = Array.make (max 1 r.vars) false in
  let bind_t = function Query.Var x -> bound.(x) <- true | _ -> () in
  let bind (a : Query.pattern) = bind_t a.e; bind_t a.v; if a.p < 0 then bound.(Rules.pvar a.p) <- true in
  (match pos with
   | -1 -> (match r.head with Rules.Give h -> bind h | Never -> ())
   | -3 -> (match r.head with Rules.Give h -> bind_t h.e | Never -> ())
   | i when i >= 0 -> bind atoms.(i)
   | _ -> ());
  let known = function Query.Var x -> bound.(x) | _ -> true in
  let n c = if counts then c () else 0 in
  let est (a : Query.pattern) =
    if a.p < 0 then
      if not bound.(Rules.pvar a.p) then 9, 0
      else match known a.e, known a.v with true, true -> 0, 0 | true, false -> 1, 8 | false, true -> 2, 64 | false, false -> 3, 1 lsl 20
    else
      match known a.e, known a.v with
      | true, true -> 0, 0
      | true, false -> 1, (match Schema.find v.schema a.p with Some d when not d.many -> 1 | _ -> 4)
      | false, true -> (
        match a.v with
        | Val x when not (is_text_const x) -> 2, n (fun () -> S.count_things v a.p (inline_word x))
        | Thing c -> 2, n (fun () -> S.count_things v a.p c)
        | Val _ -> 2, n (fun () -> max 1 (S.count_prop v a.p / S.distinct v a.p))
        | Var _ -> 1, n (fun () -> max 1 (S.count_prop v a.p / S.distinct v a.p)))
      | false, false -> 3, n (fun () -> S.count_prop v a.p)
  in
  let rest = ref (match among with Some l -> l | None -> List.filter (fun j -> j <> pos) (List.init nb Fun.id)) and out = ref [] in
  while !rest <> [] do
    let best = List.fold_left (fun b j -> match b with None -> Some (j, est atoms.(j)) | Some (_, c) -> let c' = est atoms.(j) in if compare c' c < 0 then Some (j, c') else b) None !rest in
    let j, _ = Option.get best in
    out := j :: !out;
    rest := List.filter (fun k -> k <> j) !rest;
    bind atoms.(j)
  done;
  Array.of_list (List.rev !out)

(* does a plan of a fact join an atom with neither side bound (the classes alone decide it) *)
let [@inline never] joins_free_free (v : Store.view) (r : Rules.t) pos =
  let atoms = atoms_of r in
  let bound = Array.make (max 1 r.vars) false in
  let bind_t = function Query.Var x -> bound.(x) <- true | _ -> () in
  let bind (a : Query.pattern) = bind_t a.e; bind_t a.v; if a.p < 0 then bound.(Rules.pvar a.p) <- true in
  let known = function Query.Var x -> bound.(x) | _ -> true in
  (if pos = -1 then match r.head with Rules.Give h -> bind h | Never -> () else bind atoms.(pos));
  Array.exists
    (fun j -> let a = atoms.(j) in let ff = not (known a.e || known a.v) in bind a; ff)
    (choose_order ~counts:false v r pos)

(* ---- the index of a set of plans ---- *)

let [@inline never] build_index (np : int) (rules : Rules.t array) ~backward (keep : int -> bool) =
  let slots = ref [] and ns = ref 0 in
  let byp = Array.make np [] and pwk = Hashtbl.create 16 and any = ref [] in
  let push (a : Query.pattern) slot =
    let s = !ns in
    incr ns;
    slots := slot :: !slots;
    if a.p < 0 then any := s :: !any
    else
      match a.v with
      | Val x when not (is_text_const x) ->
        let key = (a.p, inline_word x) in
        Hashtbl.replace pwk key (s :: Option.value (Hashtbl.find_opt pwk key) ~default:[])
      | Thing c ->
        let key = (a.p, c) in
        Hashtbl.replace pwk key (s :: Option.value (Hashtbl.find_opt pwk key) ~default:[])
      | _ -> if a.p < np then byp.(a.p) <- s :: byp.(a.p)
  in
  Array.iteri
    (fun ri (r : Rules.t) ->
      if keep ri then
        if backward then (match r.head with Give h -> push h (ri, -1) | Never -> ())
        else List.iteri (fun pos a -> push a (ri, pos)) r.where)
    rules;
  let n = Hashtbl.length pwk in
  let size = ref 4 in
  while !size < 2 * n do size := 2 * !size done;
  let kp = Array.make !size (-1) and kw = Array.make !size 0 and kv = Array.make !size [||] and kmask = !size - 1 in
  Hashtbl.iter
    (fun (p, w) l ->
      let i = ref (h2 p w land kmask) in
      while kp.(!i) <> -1 do i := (!i + 1) land kmask done;
      kp.(!i) <- p;
      kw.(!i) <- w;
      kv.(!i) <- Array.of_list (List.rev l))
    pwk;
  { byp = Array.map (fun l -> Array.of_list (List.rev l)) byp; kp; kw; kv; kmask; kn = n;
    any = Array.of_list (List.rev !any); slots = Array.of_list (List.rev !slots) }

let[@inline] go (d : disp) s e p w =
  let pl = Array.unsafe_get d.pa s in
  let pl = if pl == dummy then (let q = d.mk s in Array.unsafe_set d.pa s q; q) else pl in
  pl.run e p w

(* every plan whose matched atom fits the fact (e p w), run on it *)
let[@inline never] run_all (d : disp) e p w =
  let ix = d.ix in
  if p < Array.length ix.byp then begin
    let a = Array.unsafe_get ix.byp p in
    for i = 0 to Array.length a - 1 do go d (Array.unsafe_get a i) e p w done
  end;
  if ix.kn > 0 then begin
    let kp = ix.kp and kw = ix.kw and mask = ix.kmask in
    let i = ref (h2 p w land mask) in
    while (let k = Array.unsafe_get kp !i in k <> -1 && (k <> p || Array.unsafe_get kw !i <> w)) do i := (!i + 1) land mask done;
    if Array.unsafe_get kp !i <> -1 then begin
      let a = Array.unsafe_get ix.kv !i in
      for i = 0 to Array.length a - 1 do go d (Array.unsafe_get a i) e p w done
    end
  end;
  let a = ix.any in
  for i = 0 to Array.length a - 1 do go d (Array.unsafe_get a i) e p w done

(* ---- plans ----
   A plan enumerates the instances of one rule with one atom matched to a given fact (a body atom: forward; the head:
   backward), or with none (every instance), reading the state (the view and the working set) or the proved facts.
   Each step binds or checks one atom's variables with the store's lookups; the closures are made once, so running a
   plan allocates nothing but what the store's iterators do. A step whose property is a variable reads it from the
   bindings, and runs only when that property's type fits the step's value: its variable's type, or, for a variable
   that has none of its own, the type of the property it was first read from. *)

type source = State | Proved | Old  (* the state now (the view and the working set), the proved facts, the state before
                                     the group *)

(* how a plan's Nots are checked: on the state now, or on the state before the group (the instances a group may have
   taken away were instances before it) *)
type nmode = Now | Before

exception Witness

let [@inline never] order_of ctx ri pos =
  let prog = ctx.prog in
  Mutex.protect prog.pm (fun () ->
      match Hashtbl.find_opt prog.orders (ri, pos) with
      | Some o -> o
      | None -> let o = choose_order ctx.v prog.rules.(ri) pos in Hashtbl.replace prog.orders (ri, pos) o; o)

(* [pos]: the matched atom (a positive pattern, or a Not's pattern at [nb] and after: a flip's plan), -1 the head, -3
   the head's thing only, -2 none. [nmode]: how the Nots are checked; [nsrc]: what a flip's other patterns of its
   Not read. A removed rule ([extra]) runs without its Nots: its instances are a superset of those it had. *)
let [@inline never] compile ctx ?(extra : Rules.t option) ?(nmode = Now) ?(nsrc = State) ri pos source (k : plan -> unit) =
  let prog = ctx.prog in
  let r, sty, bad, atoms, nots, owns =
    match extra with
    | Some r ->
      let p = (Rules.split r).pos in
      p, (try Rules.static_types ctx.v r with Rules.Bad _ -> Array.make (max 1 r.vars) None), "", atoms_of p, [||], [||]
    | None -> prog.rules.(ri), prog.sty.(ri), prog.bad_head.(ri), prog.natoms.(ri), prog.nots.(ri), prog.own.(ri)
  in
  let nb = List.length r.where in
  let na = Array.length atoms in
  let nv = max 1 r.vars in
  let env = Array.make nv 0 and bound = Array.make nv false and dty = Array.make nv (-1) in
  let pl =
    { ri; be = Array.make (max 1 na) 0; bp = Array.init (max 1 na) (fun j -> if j < na then atoms.(j).p else 0);
      bw = Array.make (max 1 na) 0; he = 0; hp = 0; hw = 0; hok = true; run = (fun _ _ _ -> ()) }
  in
  (* the ranges of each variable, as words *)
  let rng = Array.make nv [] in
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
  (* what the value side of an atom asks of the type code of its property, when the property is known only at the
     instance: a variable's own type, the type a variable without one was first read with (or it is read now), a
     constant's *)
  let value_fits (a : Query.pattern) : int -> bool =
    match a.v with
    | Query.Var x -> (
      match sty.(x) with
      | Some ty -> let c = Value.code ty in fun t -> t = c
      | None -> if bound.(x) then (fun t -> t = dty.(x)) else fun t -> dty.(x) <- t; true)
    | Thing _ -> fun t -> t = link_code
    | Val x -> fun t -> fits_code t x
  in
  let ws = ctx.ws and pt = ctx.pt in
  (* the visible facts of the state for a step: the view's, unless the working set says otherwise, and the working
     set's own (chained); [lim]: the newest round a step sees *)
  let[@inline] vis x lim = Char.code (Bytes.unsafe_get ws.now x) > 0 && round ws x <= lim in
  (* does the view hold facts of p at all (a load's reasoning reads the working set alone for most properties) *)
  let[@inline] in_view p = Bytes.length ctx.vp = 0 || (p < Bytes.length ctx.vp && Bytes.unsafe_get ctx.vp p <> '\000') in
  let order =
    match extra with
    | Some _ -> choose_order ctx.v r pos
    | None ->
      if pos >= nb then begin
        (* a flip: the other patterns of its Not, then the positive ones *)
        let k = let rec f g o = if pos < o + Array.length nots.(g) then g else f (g + 1) (o + Array.length nots.(g)) in f 0 nb in
        let first = nb + Array.fold_left ( + ) 0 (Array.map Array.length (Array.sub nots 0 k)) in
        let among = List.init nb Fun.id @ List.filter (fun j -> j <> pos) (List.init (Array.length nots.(k)) (fun i -> first + i)) in
        choose_order ~atoms ~among ctx.v r pos
      end
      else if pos = -2 then choose_order ctx.v r pos
      else order_of ctx ri pos
  in
  (* the matched atom binds first *)
  let matched : Query.pattern option =
    if pos >= 0 then Some atoms.(pos) else if pos = -1 || pos = -3 then (match r.head with Give h -> Some h | Never -> None) else None
  in
  let unify_e, unify_v, unify_p =
    match matched with
    | None -> (fun _ -> true), (fun _ -> true), fun _ -> true
    | Some a ->
      let ue =
        match a.e with
        | Query.Var x when not bound.(x) && sty.(x) = None ->
          (* a head's thing, of a variable the body reads only under variable properties: a link *)
          bound.(x) <- true;
          fun e -> env.(x) <- e; dty.(x) <- link_code; in_range x e
        | Query.Var x when not bound.(x) -> bound.(x) <- true; fun e -> env.(x) <- e; in_range x e
        | Query.Var x -> fun e -> env.(x) = e
        | t -> let g = getter ~head:false t in fun e -> e = g ()
      in
      let uv =
        if pos = -3 then fun _ -> true
        else
        match a.v with
        | Query.Var x when not bound.(x) -> bound.(x) <- true; fun w -> env.(x) <- w; in_range x w
        | Query.Var x -> fun w -> env.(x) = w
        | t -> let g = getter ~head:false t in fun w -> w = g ()
      in
      (* the property: a variable bound by the fact, its type checked against the value side; a constant's type
         given to a value variable without a type of its own *)
      let up =
        if pos = -3 then fun _ -> true
        else if a.p >= 0 then
          match a.v with
          | Query.Var x when sty.(x) = None -> let t = ptype ctx.v a.p in fun _ -> dty.(x) <- t; true
          | _ -> fun _ -> true
        else begin
          let xp = Rules.pvar a.p in
          let fits =
            match a.v with
            | Query.Var x -> (match sty.(x) with Some ty -> let c = Value.code ty in fun t -> t = c | None -> fun t -> dty.(x) <- t; true)
            | Thing _ -> fun t -> t = link_code
            | Val x -> fun t -> fits_code t x
          in
          let bind_p =
            if bound.(xp) then fun p -> env.(xp) = p else (bound.(xp) <- true; fun p -> env.(xp) <- p; true)
          in
          fun p -> bind_p p && (let t = ptype ctx.v p in t >= 0 && fits t)
        end
      in
      ue, uv, up
  in
  let final =
    match r.head, pos with
    | Give h, p when p <> -1 && h.p = Schema.p_same ->
      (* an equality: its two sides, and whether both are things (two values are never the same thing) *)
      let ge = getter ~head:false h.e and gv = getter ~head:false h.v in
      let thing_t : Query.term -> unit -> bool = function
        | Query.Var x -> (match sty.(x) with Some Value.Tlink -> fun () -> true | Some _ -> fun () -> false | None -> fun () -> dty.(x) = link_code)
        | Thing _ -> fun () -> true
        | Val _ -> fun () -> false
      in
      let te = thing_t h.e and tv = thing_t h.v in
      fun () -> pl.he <- ge (); pl.hp <- Schema.p_same; pl.hw <- gv (); pl.hok <- te () && tv (); k pl
    | Give h, p when p <> -1 ->
      let ge = getter ~head:false h.e and gv = getter ~head:true h.v in
      let dyn = function Query.Var y -> sty.(y) = None | _ -> false in
      let dynamic = h.p < 0 || dyn h.v || dyn h.e in
      if bad <> "" then fun () -> pl.hok <- false; pl.he <- ge (); pl.hp <- h.p; pl.hw <- 0; k pl
      else if not dynamic then (let hp = h.p in fun () -> pl.he <- ge (); pl.hp <- hp; pl.hw <- gv (); k pl)
      else begin
        let gp = if h.p >= 0 then (let c = h.p in fun () -> c) else (let x = Rules.pvar h.p in fun () -> env.(x)) in
        let fits : int -> bool =
          match h.v with
          | Query.Var y -> (match sty.(y) with Some ty -> let c = Value.code ty in fun t -> t = c | None -> fun t -> t = dty.(y))
          | Thing _ -> fun t -> t = link_code
          | Val x -> fun t -> fits_code t x
        in
        (* a thing variable without a type of its own: read under a link property *)
        let thing_ok = match h.e with Query.Var x when sty.(x) = None -> fun () -> dty.(x) = link_code | _ -> fun () -> true in
        fun () ->
          let p = gp () in
          pl.hp <- p;
          let th = thing_ok () in
          pl.he <- (if th then ge () else -1);
          let ok = th && p >= Schema.first_prop && (let t = ptype ctx.v p in t >= 0 && fits t) in
          pl.hok <- ok;
          (* a text constant interned only for a head that fits *)
          pl.hw <- (if ok then gv () else 0);
          k pl
      end
    | _ -> fun () -> k pl
  in
  let step j (next : unit -> unit) : unit -> unit =
    let a = atoms.(j) in
    let xp = Rules.pvar a.p in
    (* a variable property is bound by an earlier step: the order puts its binder first *)
    if xp >= 0 && not bound.(xp) then invalid_arg "Reason.compile: a property variable joined before its binder";
    (* the step's property, read at each call when it is a variable *)
    let cp = ref a.p in
    (* with classes of equal things, a fact that names a thing that is not its representative is not read (its
       rewriting, the representative's, is) *)
    let next =
      if not prog.eq then next
      else
        let lk = if a.p >= 0 then (let l = ptype ctx.v a.p = link_code in fun () -> l) else fun () -> ptype ctx.v !cp = link_code in
        fun () -> if (not ctx.eqon) || (is_rep ctx pl.be.(j) && ((not (lk ())) || is_rep ctx pl.bw.(j))) then next ()
    in
    let source = if j >= nb then nsrc else source in
    let strict = pos >= 0 && pos < nb && j < pos in
    let lim () = if j >= nb then max_int else if strict then ctx.round - 1 else ctx.round in
    let known = function Query.Var x -> bound.(x) | _ -> true in
    let ke = known a.e and kv = known a.v in
    let same = match a.e, a.v with Query.Var x, Query.Var y -> x = y | _ -> false in
    let fits = if xp >= 0 then value_fits a else fun _ -> true in
    let ge = getter ~head:false a.e and gv = getter ~head:false a.v in
    let var = function Query.Var x -> x | _ -> -1 in
    let xe = var a.e and xv = var a.v in
    (* the step's own cells, read by its callbacks *)
    let ce = ref 0 and cw = ref 0 and cl = ref 0 in
    let s =
      match source, ke, kv with
      | State, true, true ->
        fun () ->
          let p = !cp in
          let e = ge () and w = gv () in
          let x = find ws e p w in
          if (if x >= 0 then vis x (lim ()) else in_view p && e < ws.fresh && S.mem ctx.v e p w) then (pl.be.(j) <- e; pl.bw.(j) <- w; next ())
      | Proved, true, true ->
        fun () -> let p = !cp in let e = ge () and w = gv () in if find pt e p w >= 0 then (pl.be.(j) <- e; pl.bw.(j) <- w; next ())
      | Old, true, true ->
        fun () -> let p = !cp in let e = ge () and w = gv () in if S.mem ctx.v0 e p w then (pl.be.(j) <- e; pl.bw.(j) <- w; next ())
      | _, true, false ->
        bound.(xv) <- true;
        let on w = if in_range xv w then (env.(xv) <- w; pl.bw.(j) <- w; next ()) in
        if source = Old then fun () -> let e = ge () in pl.be.(j) <- e; S.iter_values ctx.v0 e !cp on
        else if source = Proved then
          fun () ->
            let p = !cp in
            let e = ge () in
            pl.be.(j) <- e;
            let x = ref (idx_head pt.ie p e) in
            while !x >= 0 do
              let y = !x in
              if fe pt y = e && fp pt y = p then on (fw pt y);
              x := idx_next pt.ie y
            done
        else begin
          let filt w = let x = find ws !ce !cp w in if x < 0 || vis x !cl then on w in
          fun () ->
            let p = !cp in
            let e = ge () in
            ce := e;
            cl := lim ();
            pl.be.(j) <- e;
            if in_view p && e < ws.fresh then S.iter_values ctx.v e p (if ws.n = 0 then on else filt);
            if !cl >= 0 then b_iter_e ws e p on;
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
        if source = Old then fun () -> let w = gv () in pl.bw.(j) <- w; S.iter_things ctx.v0 !cp w on
        else if source = Proved then
          fun () ->
            let p = !cp in
            let w = gv () in
            pl.bw.(j) <- w;
            let x = ref (idx_head pt.iw p w) in
            while !x >= 0 do
              let y = !x in
              if fw pt y = w && fp pt y = p then on (fe pt y);
              x := idx_next pt.iw y
            done
        else begin
          let filt e = let x = find ws e !cp !cw in if x < 0 || vis x !cl then on e in
          fun () ->
            let p = !cp in
            let w = gv () in
            cw := w;
            cl := lim ();
            pl.bw.(j) <- w;
            if in_view p then S.iter_things ctx.v p w (if ws.n = 0 then on else filt);
            if !cl >= 0 then b_iter_w ws p w on;
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
        if source = Old then fun () -> S.iter_prop ctx.v0 !cp on
        else if source = Proved then
          fun () ->
            let p = !cp in
            let x = ref (idx_head pt.ip p 0) in
            while !x >= 0 do
              let y = !x in
              if fp pt y = p then on (fe pt y) (fw pt y);
              x := idx_next pt.ip y
            done
        else begin
          let filt e w = let x = find ws e !cp w in if x < 0 || vis x !cl then on e w in
          fun () ->
            let p = !cp in
            cl := lim ();
            if in_view p then S.iter_prop ctx.v p (if ws.n = 0 then on else filt);
            if !cl >= 0 then b_iter_p ws p on;
            let x = ref (idx_head ws.ip p 0) in
            while !x >= 0 do
              let y = !x in
              if fp ws y = p && vis y !cl then on (fe ws y) (fw ws y);
              x := idx_next ws.ip y
            done
        end
    in
    if xp < 0 then s
    else begin
      (* a variable property: its type fitting the value side; a thing that is no property has no facts *)
      fun () ->
        let p = env.(xp) in
        let t = if p > 0 && p < Schema.first_thing then ptype ctx.v p else -1 in
        if t >= 0 && fits t then (cp := p; pl.bp.(j) <- p; s ())
    end
  in
  (* A Not: no binding of its own variables makes its patterns facts, its outer variables fixed (an anti-join). Its
     patterns are read each time the one with the most of its sides known, the first fact found ending the search;
     one pattern with both sides known is one lookup. It reads the lower strata, which are complete: every fact,
     whatever its round. *)
  let nn = Array.length nots in
  let not_check g : unit -> bool =
    let ps = nots.(g) in
    let lb = Array.copy bound in
    List.iter (fun x -> lb.(x) <- false) owns.(g);
    let known = function Query.Var x -> lb.(x) | _ -> true in
    let mark = function Query.Var x -> lb.(x) <- true | _ -> () in
    let rest = ref (Array.to_list ps) and ord = ref [] in
    while !rest <> [] do
      let score (q : Query.pattern) = (if known q.e then 2 else 0) + if known q.v then 1 else 0 in
      let q = List.fold_left (fun b q -> if score q > score b then q else b) (List.hd !rest) !rest in
      ord := (q, known q.e, known q.v) :: !ord;
      mark q.e;
      mark q.v;
      rest := List.filter (fun q' -> q' != q) !rest
    done;
    let before = nmode = Before in
    let[@inline] now_has e p w =
      let x = find ws e p w in
      if x >= 0 then Char.code (Bytes.unsafe_get ws.now x) > 0 else in_view p && e < ws.fresh && S.mem ctx.v e p w
    in
    let var = function Query.Var x -> x | _ -> -1 in
    let rec chain = function
      | [] -> fun () -> raise_notrace Witness
      | ((q : Query.pattern), ke, kv) :: rest -> (
        let p = q.p and next = chain rest in
        let ge = getter ~head:false q.e and gv = getter ~head:false q.v in
        let xe = var q.e and xv = var q.v in
        match ke, kv with
        | true, true ->
          if before then (fun () -> if S.mem ctx.v0 (ge ()) p (gv ()) then next ())
          else fun () -> if now_has (ge ()) p (gv ()) then next ()
        | true, false ->
          let on w = if in_range xv w then (env.(xv) <- w; next ()) in
          if before then fun () -> S.iter_values ctx.v0 (ge ()) p on
          else
            fun () ->
              let e = ge () in
              if in_view p && e < ws.fresh then S.iter_values ctx.v e p (fun w -> let x = find ws e p w in if x < 0 || now ws x > 0 then on w);
              b_iter_e ws e p on;
              let x = ref (idx_head ws.ie p e) in
              while !x >= 0 do
                let y = !x in
                if fe ws y = e && fp ws y = p && now ws y > 0 then on (fw ws y);
                x := idx_next ws.ie y
              done
        | false, true ->
          let on e = if in_range xe e then (env.(xe) <- e; next ()) in
          if before then fun () -> S.iter_things ctx.v0 p (gv ()) on
          else
            fun () ->
              let w = gv () in
              if in_view p then S.iter_things ctx.v p w (fun e -> let x = find ws e p w in if x < 0 || now ws x > 0 then on e);
              b_iter_w ws p w on;
              let x = ref (idx_head ws.iw p w) in
              while !x >= 0 do
                let y = !x in
                if fw ws y = w && fp ws y = p && now ws y > 0 then on (fe ws y);
                x := idx_next ws.iw y
              done
        | false, false ->
          let on e w = if (xe <> xv || e = w) && in_range xe e && in_range xv w then (env.(xe) <- e; env.(xv) <- w; next ()) in
          if before then fun () -> S.iter_prop ctx.v0 p on
          else
            fun () ->
              if in_view p then S.iter_prop ctx.v p (fun e w -> let x = find ws e p w in if x < 0 || now ws x > 0 then on e w);
              b_iter_p ws p on;
              (* the working set's own facts of p: its chain by property (kept but in a load, which refuses Nots) *)
              let x = ref (idx_head ws.ip p 0) in
              while !x >= 0 do
                let y = !x in
                if fp ws y = p && now ws y > 0 then on (fe ws y) (fw ws y);
                x := idx_next ws.ip y
              done)
    in
    match List.rev !ord with
    | [ (q, true, true) ] ->
      let ge = getter ~head:false q.e and gv = getter ~head:false q.v and p = q.p in
      if before then fun () -> not (S.mem ctx.v0 (ge ()) p (gv ())) else fun () -> not (now_has (ge ()) p (gv ()))
    | ord -> let body = chain ord in fun () -> match body () with () -> true | exception Witness -> false
  in
  let outer_of = Array.mapi (fun g ps -> List.filter (fun x -> not (List.mem x owns.(g))) (List.sort_uniq compare (List.concat_map (fun (q : Query.pattern) -> List.filter_map (function Query.Var x -> Some x | _ -> None) [ q.e; q.v ]) (Array.to_list ps)))) nots in
  let placed = Array.make nn false in
  (* the Nots whose outer variables are bound now; a flip's are checked last (its steps bind a Not's own variables) *)
  let ready ~last =
    let l = ref [] in
    if last || pos < nb then
      for g = nn - 1 downto 0 do
        if (not placed.(g)) && (last || List.for_all (fun x -> bound.(x)) outer_of.(g)) then (placed.(g) <- true; l := g :: !l)
      done;
    !l
  in
  let guard gs (next : unit -> unit) =
    match List.map not_check gs with
    | [] -> next
    | [ c ] -> fun () -> if c () then next ()
    | cs -> let cs = Array.of_list cs in fun () -> if Array.for_all (fun c -> c ()) cs then next ()
  in
  (* the steps built from the first, so that each sees the variables the earlier ones bind: [step] marks the
     variables it binds before the rest is built *)
  let rec build = function
    | [] -> if nn = 0 then final else guard (ready ~last:true) final
    | j :: rest ->
      let s = ref (fun () -> ()) in
      let mk = step j (fun () -> !s ()) in
      if nn = 0 then s := build rest
      else begin
        let gs = ready ~last:false in
        let b = build rest in
        s := guard gs b
      end;
      mk
  in
  let body = if nn = 0 then build (Array.to_list order) else (let gs = ready ~last:false in guard gs (build (Array.to_list order))) in
  pl.run <-
    (fun e p w ->
      if pos = -1 then (pl.he <- e; pl.hp <- p; pl.hw <- w; pl.hok <- true);
      if unify_e e && unify_v w && unify_p p
         && ((not prog.eq) || pos < 0 || (not ctx.eqon) || (is_rep ctx e && (ptype ctx.v p <> link_code || is_rep ctx w)))
      then begin
        if pos >= 0 then (pl.be.(pos) <- e; pl.bp.(pos) <- p; pl.bw.(pos) <- w);
        body ()
      end);
  pl

let [@inline never] make_disp ?nmode ctx (ix : index) source k =
  { ix; pa = Array.make (Array.length ix.slots) dummy;
    mk = (fun s -> let ri, pos = ix.slots.(s) in compile ctx ?nmode ri pos source k) }

(* ---- making a program ---- *)

let small_limit = 10_000  (* a relation of at most this many facts is specialised on (the design's section 5.4) *)
let unfold_limit = 10_000  (* the rules one rule unfolds into, at most *)

let plain_atom (a : Query.pattern) = a.p >= 0 && (match a.e, a.v with Query.Var x, Query.Var y -> x <> y | _ -> false)
let ev (a : Query.pattern) = match a.e, a.v with Query.Var x, Query.Var y -> x, y | _ -> -1, -1

(* the closure modules of a rule set, and the rules they run *)
let [@inline never] find_modules ?(plain = fun _ -> true) ?dep (v : Store.view) (rules : Rules.t array) =
  let n = Array.length rules in
  (* what each rule reads: its patterns, its Nots' too *)
  let dep = match dep with Some d -> d | None -> rules in
  let prop p = Schema.find v.schema p in
  let link p = match prop p with Some d -> d.typ = Value.Tlink | None -> false in
  let closable p = match prop p with Some d -> d.typ = Value.Tlink && d.many && not d.unique | None -> false in
  let shape ri =
    let r = rules.(ri) in
    if not (plain ri) then None
    else
    match r.where, r.head, r.ranges with
    | [ a1; a2 ], Rules.Give h, [] when plain_atom a1 && plain_atom a2 && plain_atom h ->
      let hx, hz = ev h in
      (* [x P y] [y Q z] -> [x Q z], in either order; x y z distinct *)
      let fit (ae : Query.pattern) (at : Query.pattern) =
        let x, y = ev ae and y', z = ev at in
        if at.p = h.p && y = y' && hx = x && hz = z && x <> z then Some (ae.p, at.p) else None
      in
      (match fit a1 a2 with Some s -> Some (`Step s) | None -> Option.map (fun s -> `Step s) (fit a2 a1))
    | [ a ], Give h, [] when plain_atom a && plain_atom h && a.p <> h.p && ev a = ev h -> Some (`Base (a.p, h.p))
    | _ -> None
  in
  let shapes = Array.init n shape in
  let used = Hashtbl.create 4 and in_module = Array.make n false and mods = ref [] in
  Array.iteri
    (fun ri s ->
      match s with
      | Some (`Step (e, t)) when (not (Hashtbl.mem used t)) && closable t && link e ->
        let base =
          if e = t then Some (-1)
          else
            let rec f j = if j >= n then None else if (not in_module.(j)) && shapes.(j) = Some (`Base (e, t)) then Some j else f (j + 1) in
            f 0
        in
        (match base with
         | Some b ->
           Hashtbl.replace used t ();
           in_module.(ri) <- true;
           if b >= 0 then in_module.(b) <- true;
           mods := (ri, b, t, e) :: !mods
         | None -> ())
      | _ -> ())
    shapes;
  let modules =
    List.rev_map
      (fun (ri, b, t, e) ->
        (* side: nothing outside the module reads T, or gives T or E, or reads a property that is a variable *)
        let side =
          Array.for_all Fun.id
            (Array.mapi
               (fun rk (r : Rules.t) ->
                 rk = ri || rk = b
                 || List.for_all (fun (a : Query.pattern) -> a.p >= 0 && a.p <> t) dep.(rk).where
                    && match r.head with Give h -> h.p >= 0 && h.p <> t && h.p <> e | Never -> true)
               rules)
        in
        let walk =
          Array.for_all Fun.id
            (Array.mapi (fun rk (r : Rules.t) -> rk = ri || rk = b || match r.head with Give h -> h.p >= 0 && h.p <> t && h.p <> e | Never -> true) rules)
        in
        { m_rule = ri; m_base = b; m_t = t; m_e = e; m_side = side; m_walk = walk })
      !mods
  in
  Array.of_list modules, in_module

let [@inline never] build ?(also_reads = [||]) ?(lists = [||]) (v : Store.view) ~key ~(src : Rules.t array) ~(ids : int array) ~(bad_head : string array) ~spec =
  let np = Schema.count v.schema in
  let shapes = Array.map Rules.split src in
  let rules = Array.map (fun (sh : Rules.shape) -> sh.pos) shapes in
  let nr = Array.length rules in
  let nots = Array.map (fun (sh : Rules.shape) -> sh.nots) shapes and own = Array.map (fun (sh : Rules.shape) -> sh.own) shapes in
  let aggs = Array.map (fun (sh : Rules.shape) -> sh.agg) shapes in
  let natoms = Array.mapi (fun i r -> Array.append (atoms_of r) (Array.concat (Array.to_list nots.(i)))) rules in
  let stratified = Array.exists (fun (sh : Rules.shape) -> sh.nots <> [||] || sh.agg <> None) shapes in
  let strat = if not stratified then Array.make nr 0 else match Rules.strata v src with Ok a -> a | Error _ -> Array.make nr 0 in
  let sty = Array.map (fun (r : Rules.t) -> try Rules.static_types v r with Rules.Bad _ -> Array.make (max 1 r.vars) None) src in
  let never = Array.map (fun (r : Rules.t) -> r.head = Never) rules in
  let nstrata = 1 + Array.fold_left max 0 (Array.mapi (fun i s -> if never.(i) then 0 else s) strat) in
  let reads = Bytes.make np '\000' and all = ref 0 in
  let mark p b = if p < 0 then all := !all lor b else if p < np then Bytes.set reads p (Char.chr (Char.code (Bytes.get reads p) lor b)) in
  let consts = ref [] in
  let see_const = function Query.Val x when is_text_const x -> if not (List.mem x !consts) then consts := x :: !consts | _ -> () in
  Array.iteri
    (fun i (r : Rules.t) ->
      Array.iter (fun (a : Query.pattern) -> mark a.p 1; see_const a.v) natoms.(i);
      match r.head with Give h -> mark h.p 2; see_const h.v | Never -> ())
    rules;
  (* a variable property reads or gives every property; the relations a program is unfolded on are read by its
     generic rules *)
  if !all <> 0 then Bytes.iteri (fun p c -> Bytes.set reads p (Char.chr (Char.code c lor !all))) reads;
  Array.iter (fun p -> mark p 1) also_reads;
  Array.iter (fun (p, _) -> mark p 1) lists;
  let islist = Bytes.make np '\000' in
  Array.iter (fun (p, _) -> if p < np then Bytes.set islist p '\001') lists;
  let plain ri = nots.(ri) = [||] && aggs.(ri) = None in
  let dep = Array.mapi (fun i (r : Rules.t) -> { r with where = Array.to_list natoms.(i) }) rules in
  let same_head ri = match rules.(ri).head with Give h -> h.p = Schema.p_same | Never -> false in
  let eq = Array.exists Fun.id (Array.init nr same_head) in
  let cthings = Hashtbl.create 8 in
  Array.iter
    (fun (r : Rules.t) ->
      List.iter (fun (a : Query.pattern) -> List.iter (function Query.Thing t -> Hashtbl.replace cthings t () | _ -> ()) [ a.e; a.v ])
        (r.where @ match r.head with Give h -> [ h ] | Never -> []))
    rules;
  (* with equality, closures run as rules: the modules' walks read every fact, the rules only the representatives' *)
  let modules, in_module = if eq then [||], Array.make nr false else find_modules ~plain ~dep v rules in
  let free_free = ref false in
  Array.iter
    (fun (r : Rules.t) ->
      if not !free_free then
        for pos = -1 to List.length r.where - 1 do
          if (pos >= 0 || r.head <> Never) && joins_free_free v r pos then free_free := true
        done)
    rules;
  (* an ordinary rule: one fact an instance (not a constraint, not an aggregate) *)
  let give ri = not never.(ri) && aggs.(ri) = None in
  let ix_lost = build_index np rules ~backward:false give in
  let walk_rule = Array.make (Array.length rules) false in
  Array.iter (fun (m : closure) -> if m.m_walk then (walk_rule.(m.m_rule) <- true; if m.m_base >= 0 then walk_rule.(m.m_base) <- true)) modules;
  let ix_lost_walk = if Array.exists Fun.id walk_rule then build_index np rules ~backward:false (fun ri -> give ri && not walk_rule.(ri)) else ix_lost in
  let ix_ins = build_index np rules ~backward:false (fun ri -> give ri && not in_module.(ri)) in
  let ix_ins_s =
    if nstrata = 1 then [| ix_ins |]
    else Array.init nstrata (fun s -> build_index np rules ~backward:false (fun ri -> give ri && (not in_module.(ri)) && strat.(ri) = s))
  in
  let pstrat = Array.make np [] and anystrat = ref (-1) and agg_rule = Array.make np (-1) in
  Array.iteri
    (fun i (r : Rules.t) ->
      match r.head with
      | Give h when h.p < 0 -> anystrat := strat.(i)
      | Give h when h.p < np ->
        pstrat.(h.p) <- ((if aggs.(i) <> None then -1 else Rules.node_word h.v), strat.(i)) :: pstrat.(h.p);
        if aggs.(i) <> None then agg_rule.(h.p) <- i
      | _ -> ())
    rules;
  { key; rules; src; natoms; nots; own; aggs; strat; nstrata; stratified; pstrat; anystrat = !anystrat; agg_rule; ix_ins_s;
    ids; sty; never; bad_head; atoms = Array.map atoms_of rules; free_free = !free_free; np; reads;
    consts = Array.of_list (List.rev !consts); orders = Hashtbl.create 64; size = S.facts v; modules; in_module;
    ix_ins; ix_lost; ix_lost_walk; ix_pf = ix_lost;
    ix_bw = build_index np rules ~backward:true (fun ri -> give ri && not (same_head ri)); ix_cons = build_index np rules ~backward:false (fun ri -> never.(ri));
    spec; lists; islist; eq; cthings; lruns = v.runs; lstamps = Array.map (fun (p, _) -> Store.stamp v p (-1)) lists; pool = ref [];
    pm = Mutex.create () }

(* the stratum of a fact: the stratum of the rules whose heads give it, -1 when none does *)
let fact_stratum prog p w =
  if prog.anystrat >= 0 then prog.anystrat
  else if p < 0 || p >= Array.length prog.pstrat then -1
  else
    let rec f = function [] -> -1 | (w', s) :: rest -> if w' < 0 || w' = w then s else f rest in
    f (Array.unsafe_get prog.pstrat p)

(* ---- templates (the reasoner design, section 5.16) ----
   A rule with a list pattern [c, every L, m] is unfolded on L's facts: for each thing c with values of L (or the
   constant c), one rule whose patterns that name m are written once for each member (in the order of their words),
   m replaced by the member, the variables only those patterns hold fresh in each copy, and the list pattern gone.
   cls-int1 over an intersection {A, B} gives [y type A] [y type B] -> [y type C]; prp-key over a key {p1, p2} gives
   [x type C] [y type C] [x p1 z1] [y p1 z1] [x p2 z2] [y p2 z2] -> [x same y]. A list of no member gives no rule (the
   W3C's LIST[...] has at least one). Unfolded rules keep their template's name and thing. *)

let template_limit = 64  (* members of one list, at most: the patterns of one unfolded rule stay few *)

let [@inline never] unfold_template (v : Store.view) (r : Rules.t) =
  match List.find_opt (fun (a : Query.pattern) -> Rules.is_every a.p) r.where with
  | None -> [ r ]
  | Some ta ->
    let l = Rules.every_of ta.p in
    let m = match ta.v with Query.Var m -> m | _ -> invalid_arg "Reason.unfold_template" in
    let others = List.filter (fun a -> a != ta) r.where in
    let names (a : Query.pattern) = a.e = Query.Var m || a.v = Query.Var m || a.p = Rules.prop_var m in
    let per, shared = List.partition names others in
    let vars_of (a : Query.pattern) =
      List.filter_map (function Query.Var x -> Some x | _ -> None) [ a.e; a.v ] @ (if a.p < 0 then [ Rules.pvar a.p ] else [])
    in
    let outside = Array.make (max 1 r.vars) false in
    List.iter (fun a -> List.iter (fun x -> outside.(x) <- true) (vars_of a)) (shared @ (match r.head with Rules.Give h -> [ h ] | Never -> []));
    List.iter (fun x -> outside.(x) <- true) (vars_of ta);
    (* the variables of the copies: fresh in each, unless held outside *)
    let fresh = List.sort_uniq compare (List.filter (fun x -> x <> m && not outside.(x)) (List.concat_map vars_of per)) in
    let typ = match Schema.find v.schema l with Some d -> Some d.typ | None -> None in
    (* the lists: (c, its members' words, sorted) *)
    let lists =
      match typ, ta.e with
      | None, _ -> []
      | Some _, Query.Thing c -> let ws = ref [] in S.iter_values v c l (fun w -> ws := w :: !ws); if !ws = [] then [] else [ c, List.sort compare !ws ]
      | Some _, Query.Var _ ->
        let h = Hashtbl.create 16 in
        S.iter_prop v l (fun e w -> Hashtbl.replace h e (w :: Option.value (Hashtbl.find_opt h e) ~default:[]));
        List.sort compare (Hashtbl.fold (fun c ws acc -> (c, List.sort_uniq compare ws) :: acc) h [])
      | Some _, Query.Val _ -> []
    in
    List.filter_map
      (fun (c, ws) ->
        if List.length ws > template_limit then
          refuse "rule %s: the list of #%d has %d members (a template takes at most %d)" r.name c (List.length ws) template_limit;
        let next = ref r.vars in
        let cterm : Query.term -> Query.term = function Query.Var x when ta.e = Query.Var x -> Thing c | t -> t in
        let ok = ref true in
        let copies =
          List.concat_map
            (fun w ->
              let ren = Hashtbl.create 4 in
              List.iter (fun x -> Hashtbl.replace ren x !next; incr next) fresh;
              let member : Query.term =
                match Store.value v (Option.get typ) w with Value.Link t -> Thing t | x -> Val x
              in
              let term (t : Query.term) : Query.term =
                match t with
                | Query.Var x when x = m -> member
                | Var x -> (match Hashtbl.find_opt ren x with Some y -> Var y | None -> cterm t)
                | t -> t
              in
              let prop p =
                if p = Rules.prop_var m then (
                  match member with
                  | Thing t when t >= Schema.first_prop && t < Schema.first_thing && Schema.find v.schema t <> None -> t
                  | _ -> ok := false; 0)
                else if p < 0 then (match Hashtbl.find_opt ren (Rules.pvar p) with Some y -> Rules.prop_var y | None -> p)
                else p
              in
              List.map (fun (a : Query.pattern) -> { Query.e = term a.e; p = prop a.p; v = term a.v }) per)
            ws
        in
        if not !ok then None
        else begin
          let ranges =
            List.concat_map (fun (x, lo, hi) -> if x = m || List.mem x fresh then [] else [ x, lo, hi ]) r.ranges
          in
          let shared = List.map (fun (a : Query.pattern) -> { a with e = cterm a.e; v = cterm a.v }) shared in
          let head = match r.head with Rules.Give h -> Rules.Give { h with e = cterm h.e; v = cterm h.v } | Never -> Never in
          (* the variables numbered densely again *)
          let nv = !next in
          let used = Array.make (max 1 nv) false in
          let see (a : Query.pattern) = List.iter (fun x -> used.(x) <- true) (vars_of a) in
          let where = shared @ copies in
          List.iter see where;
          (match head with Give h -> see h | Never -> ());
          let map = Array.make (max 1 nv) (-1) and k = ref 0 in
          Array.iteri (fun x u -> if u then (map.(x) <- !k; incr k)) used;
          let t = function Query.Var x -> Query.Var map.(x) | t -> t in
          let pat (a : Query.pattern) = { Query.e = t a.e; p = (if a.p < 0 then Rules.prop_var map.(Rules.pvar a.p) else a.p); v = t a.v } in
          Some
            { r with vars = !k; where = List.map pat where; ranges = List.filter_map (fun (x, lo, hi) -> if used.(x) then Some (map.(x), lo, hi) else None) ranges;
                     head = (match head with Give h -> Give (pat h) | Never -> Never) }
        end)
      lists

(* the rules of a view as written, parsed, their templates unfolded on the view's lists: (rule thing, rule) *)
let [@inline never] written (v : Store.view) =
  List.concat_map
    (fun (id, (name, text)) ->
      match Rules.of_text name text with
      | Ok r -> List.map (fun r -> id, r) (unfold_template v r)
      | Error _ -> [])
    (Schema.rules v.schema)

(* a list's facts: (thing, value) words, sorted *)
let [@inline never] list_of (v : Store.view) p =
  let l = ref [] in
  if Schema.find v.schema p <> None then S.iter_prop v p (fun e w -> l := (e, w) :: !l);
  let a = Array.of_list !l in
  Array.sort compare a;
  Array.concat (Array.to_list (Array.map (fun (e, w) -> [| e; w |]) a))

(* the lists the templates of a view's rules read, and their facts *)
let [@inline never] list_facts (v : Store.view) =
  let ps =
    List.sort_uniq compare
      (List.concat_map
         (fun (_, (name, text)) ->
           match Rules.of_text name text with
           | Ok r -> List.filter_map (fun (a : Query.pattern) -> if Rules.is_every a.p then Some (Rules.every_of a.p) else None) r.where
           | Error _ -> [])
         (Schema.rules v.schema))
  in
  Array.of_list (List.map (fun p -> p, list_of v p) ps)

(* the generic program: the rules as written, their templates unfolded *)
let [@inline never] make_gen (v : Store.view) =
  let parsed = written v in
  let rules = Array.of_list (List.map snd parsed) and ids = Array.of_list (List.map fst parsed) in
  build ~lists:(list_facts v) v ~key:(Schema.rules_key v.schema) ~src:rules ~ids ~bad_head:(Array.make (Array.length rules) "") ~spec:None

(* do a view's lists hold the facts the program's templates were unfolded on: by identity first, else by the facts *)
let [@inline never] lists_hold (prog : program) (v : Store.view) =
  Array.length prog.lists = 0
  || (v.runs == prog.lruns
      && (let ok = ref true in
          Array.iteri (fun i (p, _) -> if !ok && not (Store.same_stamp (Store.stamp v p (-1)) prog.lstamps.(i)) then ok := false) prog.lists;
          !ok))
  ||
  if Array.for_all (fun (p, f) -> list_of v p = f) prog.lists then begin
    prog.lruns <- v.runs;
    prog.lstamps <- Array.map (fun (p, _) -> Store.stamp v p (-1)) prog.lists;
    true
  end
  else false

(* what a group is refused with when a rule gives a fact that does not fit: its thing not a thing, its property not one
   a rule can give, or its value not of the property's type *)
let [@inline never] head_message (v : Store.view) name ~thing hp =
  if not thing then Printf.sprintf "rule %s gives a fact about a value that is not a thing" name
  else
    match if hp >= Schema.first_prop then Schema.find v.schema hp else None with
    | None -> Printf.sprintf "rule %s gives a fact of #%d, which is not a property it can give" name hp
    | Some d -> Printf.sprintf "rule %s gives %s a value of another type" name d.name

(* ---- specialisation by small relations (the design's section 5.4) ----
   An atom over a property with few facts (at most [small_limit], by exact counts), whose variables another atom of
   the rule dispatches on (its property, or its value under a constant property: [x type c], [x p y]), is unfolded:
   the rule becomes one rule a fact of that relation, its variables replaced by the fact's words. The unfolded rules
   run as rules written with constants (the plans dispatch by property and by class at once), and the relation is
   frozen: while its facts stay those it was unfolded on, the unfolded program gives exactly the generic one's
   results; a group that would change one of them is reasoned with the generic program (Respec), and the next group
   unfolds again. A relation is unfolded on only if it does not depend on what the unfolded rules give (no rule
   chain leads from their heads to it), so that no fact of it changes while the unfolded rules run unless a group
   asserts, derives or retracts it, which the writer sees. *)

let rel_of (a : Query.pattern) = a.p, (match a.v with Val x when not (is_text_const x) -> inline_word x | Thing c -> c | _ -> -1)

(* a relation's facts in a view: (thing, value) words, or things for a relation with a value, sorted *)
let [@inline never] rel_facts (v : Store.view) (p, w) =
  let l = ref [] in
  if w < 0 then S.iter_prop v p (fun e x -> l := x :: e :: !l) else S.iter_things v p w (fun e -> l := e :: !l);
  if w < 0 then begin
    let a = Array.of_list (List.rev !l) in
    let k = Array.length a / 2 in
    let pairs = Array.init k (fun i -> a.(2 * i), a.((2 * i) + 1)) in
    Array.sort compare pairs;
    Array.concat (Array.to_list (Array.map (fun (e, x) -> [| e; x |]) pairs))
  end
  else (let a = Array.of_list !l in Array.sort compare a; a)

(* does a fact of one of [targets] follow, through the rules, from the facts [starts] describe: nodes (property,
   value), -1 for any *)
let [@inline never] reaches (rules : Rules.t array) (starts : (int * int) list) (targets : (int * int) list) =
  let node (a : Query.pattern) = (if a.p < 0 then -1 else a.p), snd (rel_of a) in
  let matches (np, nw) (ap, aw) = (np = -1 || ap = -1 || np = ap) && (nw = -1 || aw = -1 || nw = aw) in
  let n = Array.length rules in
  let fired = Array.make n false in
  (* the rules by an atom's (property, value), by an atom's property when its value varies, and those reading a
     variable property *)
  let bypw = Hashtbl.create 64 and byp = Hashtbl.create 64 and anyp = ref [] in
  Array.iteri
    (fun ri (r : Rules.t) ->
      List.iter
        (fun (a : Query.pattern) ->
          let p, w = node a in
          if p < 0 then anyp := ri :: !anyp else if w < 0 then Hashtbl.add byp p ri else Hashtbl.add bypw (p, w) ri)
        r.where)
    rules;
  let seen = Hashtbl.create 64 and q = Queue.create () and whole = Hashtbl.create 8 and all = ref false in
  let push nd = if not (Hashtbl.mem seen nd) then (Hashtbl.replace seen nd (); Queue.add nd q) in
  List.iter push starts;
  let fire ri = if not fired.(ri) then (fired.(ri) <- true; match rules.(ri).head with Give h -> push (node h) | Never -> ()) in
  let test nd ri = if (not fired.(ri)) && List.exists (fun a -> matches nd (node a)) rules.(ri).where then fire ri in
  while not (Queue.is_empty q) do
    let ((p, w) as nd) = Queue.pop q in
    if p < 0 then (if not !all then (all := true; for ri = 0 to n - 1 do test nd ri done))
    else begin
      if w < 0 then (if not (Hashtbl.mem whole p) then (Hashtbl.replace whole p (); List.iter (test nd) (Hashtbl.find_all byp p); Hashtbl.iter (fun (p', _) ri -> if p' = p then test nd ri) bypw))
      else (List.iter (test nd) (Hashtbl.find_all byp p); List.iter (test nd) (Hashtbl.find_all bypw (p, w)));
      List.iter (test nd) !anyp
    end
  done;
  List.exists (fun t -> Hashtbl.fold (fun nd () acc -> acc || matches nd t) seen false) targets

(* rule g's small atoms, if it has some worth unfolding: their variables inline (a word is the value), each other atom
   dispatched on one of their variables *)
let [@inline never] small_atoms ?(unstable = fun _ -> false) (v : Store.view) ~counts (r : Rules.t) (sty : Value.typ option array) =
  let atoms = atoms_of r in
  let nb = Array.length atoms in
  let vars_of (a : Query.pattern) = List.filter_map (function Query.Var x -> Some x | _ -> None) [ a.e; a.v ] in
  let dispatches x (b : Query.pattern) = b.p = Rules.prop_var x || (b.p >= 0 && b.v = Query.Var x) in
  let inline_var x = match sty.(x) with Some t -> Value.inline t | None -> false in
  let count (a : Query.pattern) =
    match a.e, a.v with
    | _, Val x when not (is_text_const x) -> S.count_things v a.p (inline_word x)
    | _, Thing c -> S.count_things v a.p c
    | Thing c, _ -> S.count_values v c a.p
    | _ -> S.count_prop v a.p
  in
  let all = List.init nb Fun.id in
  let cand =
    List.filter
      (fun i ->
        let a = atoms.(i) in
        a.p >= 0 && vars_of a <> [] && List.for_all inline_var (vars_of a)
        && List.exists (fun x -> List.exists (fun j -> j <> i && dispatches x atoms.(j)) all) (vars_of a))
      all
  in
  (* a relation a group changed while the rules were unfolded on it is a relation of the data: not unfolded on *)
  let small i = (not counts) || (count atoms.(i) <= small_limit && not (unstable (rel_of atoms.(i)))) in
  let cand = List.filter small cand in
  (* and every other small atom sharing a variable with them: unfolded together ([a sub p1] [a super p2]) *)
  let cand =
    let c = ref cand and grew = ref true in
    while !grew do
      grew := false;
      List.iter
        (fun i ->
          let a = atoms.(i) in
          let cv = List.concat_map (fun j -> vars_of atoms.(j)) !c in
          (* sharing a variable with them, none of theirs in a place it dispatches on (such an atom is one the
             unfolding serves) *)
          if (not (List.mem i !c)) && a.p >= 0 && vars_of a <> [] && List.for_all inline_var (vars_of a)
             && List.exists (fun x -> List.mem x cv) (vars_of a)
             && (not (List.exists (fun x -> dispatches x a) cv))
             && small i
          then (c := i :: !c; grew := true))
        all
    done;
    List.sort compare !c
  in
  let cvars = List.concat_map (fun i -> vars_of atoms.(i)) cand in
  let rest = List.filter (fun j -> not (List.mem j cand)) all in
  if cand = [] || rest = [] || not (List.for_all (fun j -> List.exists (fun x -> dispatches x atoms.(j)) cvars) rest) then None
  else Some cand

(* the bindings of the small atoms' variables, by a join over the view; None past [unfold_limit] *)
let [@inline never] small_bindings (v : Store.view) (r : Rules.t) (atoms : Query.pattern array) (cand : int list) =
  let nv = max 1 r.vars in
  let env = Array.make nv 0 and bnd = Array.make nv false in
  (* an order: each next atom one with a bound side, if any *)
  let left = ref cand and order = ref [] in
  let known = function Query.Var x -> bnd.(x) | _ -> true in
  let mark (a : Query.pattern) = List.iter (function Query.Var x -> bnd.(x) <- true | _ -> ()) [ a.e; a.v ] in
  while !left <> [] do
    let i = match List.find_opt (fun i -> known atoms.(i).e || known atoms.(i).v) !left with Some i -> i | None -> List.hd !left in
    order := i :: !order;
    left := List.filter (( <> ) i) !left;
    mark atoms.(i)
  done;
  Array.fill bnd 0 nv false;
  let out = ref [] and count = ref 0 in
  let word = function
    | Query.Var x -> if bnd.(x) then Some env.(x) else None
    | Thing c -> Some c
    | Val x -> if is_text_const x then Some (Option.value (S.word v x) ~default:min_int) else Some (inline_word x)
  in
  let rec go = function
    | [] ->
      incr count;
      if !count > unfold_limit then raise_notrace Exit;
      out := Array.init nv (fun x -> if bnd.(x) then Some env.(x) else None) :: !out
    | i :: rest ->
      let a = atoms.(i) in
      let bind t x k = match t with Query.Var y when not bnd.(y) -> env.(y) <- x; bnd.(y) <- true; k (); bnd.(y) <- false | _ -> k () in
      (match word a.e, word a.v with
       | Some e, Some w -> if S.mem v e a.p w then go rest
       | Some e, None -> S.iter_values v e a.p (fun w -> bind a.v w (fun () -> go rest))
       | None, Some w -> S.iter_things v a.p w (fun e -> bind a.e e (fun () -> go rest))
       | None, None ->
         S.iter_prop v a.p (fun e w ->
             match a.e, a.v with
             | Query.Var x, Query.Var y when x = y -> if e = w then bind a.e e (fun () -> go rest)
             | _ -> bind a.e e (fun () -> bind a.v w (fun () -> go rest))))
  in
  match go (List.rev !order) with () -> Some (List.rev !out) | exception Exit -> None

(* a rule with the bound variables replaced by their words; None when it can have no instance *)
let [@inline never] substitute (v : Store.view) (r : Rules.t) (sty : Value.typ option array) (cand : int list) (b : int option array) =
  let value x w : Query.term =
    match sty.(x) with
    | Some Value.Tlink -> Thing w
    | Some Tint -> Val (Int w)
    | Some Tdate -> Val (Date w)
    | Some (Tmoney _) -> Val (Money w)
    | Some Tbool -> Val (Bool (w <> 0))
    | _ -> assert false
  in
  let term = function Query.Var x as t -> (match b.(x) with Some w -> value x w | None -> t) | t -> t in
  let prop p = if p < 0 then (match b.(Rules.pvar p) with Some w -> w | None -> p) else p in
  let atom (a : Query.pattern) = { Query.e = term a.e; p = prop a.p; v = term a.v } in
  let where = List.filteri (fun i _ -> not (List.mem i cand)) r.where |> List.map atom in
  let head = match r.head with Rules.Give h -> Rules.Give (atom h) | Never -> Never in
  (* a range on a variable now a constant: the binding is inside it, or the rule has no instance *)
  let inside = List.for_all (fun (x, lo, hi) -> match b.(x) with Some w -> w >= inline_word lo && w <= inline_word hi | None -> true) r.ranges in
  let ranges = List.filter (fun (x, _, _) -> b.(x) = None) r.ranges in
  let r' = { r with where; head; ranges } in
  let real (a : Query.pattern) =
    a.p < 0
    || (a.p > 0 && a.p < Schema.first_thing
        &&
        match Schema.find v.schema a.p with
        | None -> false
        | Some d -> (match a.v with Thing _ -> d.typ = Value.Tlink | Val x -> Value.has_type d.typ x | Var _ -> true))
  in
  if not (inside && List.for_all real where) then None
  else
    match Rules.static_types v r' with
    | exception Rules.Bad _ -> None
    | sty' ->
      let bad =
        match head with
        | Never -> ""
        | Give h ->
          let thing = match h.e with Var x -> (match sty'.(x) with Some t -> t = Value.Tlink | None -> true) | _ -> true in
          if not thing then head_message v r.name ~thing h.p
          else if h.p < 0 then ""
          else (
            match if h.p >= Schema.first_prop then Schema.find v.schema h.p else None with
            | None -> head_message v r.name ~thing h.p
            | Some d ->
              let fits = match h.v with Var y -> (match sty'.(y) with Some t -> t = d.typ | None -> true) | Thing _ -> d.typ = Value.Tlink | Val x -> Value.has_type d.typ x in
              if fits then "" else head_message v r.name ~thing h.p)
      in
      Some (r', bad)

(* Unfolded over a closed relation (cax-sco over scm-sco's closure: a class to each of its ancestors), the rules
   [x P a] -> [x P c] give c to an a by every path from a to c, each a derivation. A rule whose head follows from a
   chain of the others (c reachable from a without it) is dropped: the least model is the same for any facts, since
   the chain stays, and each such fact is derived once a step (the transitive reduction of their graph, one edge at a
   time, so that reachability never changes). At most 2,000 such rules are weighed. *)
let [@inline never] reduce (parts : (int * Rules.t * string) list) =
  (* a rule whose head is one of its patterns gives nothing new (cax-sco over a reflexive [c sub c], which scm-svf1b
     gives each restriction): dropped *)
  let parts = List.filter (fun (_, (r : Rules.t), bad) -> bad <> "" || match r.head with Rules.Give h -> not (List.mem h r.where) | Never -> true) parts in
  let edge (r : Rules.t) =
    match r.where, r.head, r.ranges with
    | [ { e = Var x; p; v = Thing a } ], Rules.Give { e = Var x'; p = p'; v = Thing c }, [] when x = x' && p = p' && p >= 0 && a <> c -> Some (p, a, c)
    | _ -> None
  in
  let edges = List.filter_map (fun (_, r, bad) -> if bad = "" then edge r else None) parts in
  let n = List.length edges in
  if n < 2 || n > 2000 then parts
  else begin
    let live = Hashtbl.create (2 * n) in
    List.iter (fun e -> Hashtbl.replace live e ()) edges;
    let out = Hashtbl.create (2 * n) in
    List.iter (fun (p, a, c) -> Hashtbl.add out (p, a) c) edges;
    (* is c reachable from a over the live edges of p, the edge (a, c) aside *)
    let reach p a c =
      let seen = Hashtbl.create 16 and stack = ref [ a ] and found = ref false in
      while (not !found) && !stack <> [] do
        let u = List.hd !stack in
        stack := List.tl !stack;
        List.iter
          (fun w ->
            if Hashtbl.mem live (p, u, w) && not (u = a && w = c) then
              if w = c then found := true else if not (Hashtbl.mem seen w) then (Hashtbl.replace seen w (); stack := w :: !stack))
          (Hashtbl.find_all out (p, u))
      done;
      !found
    in
    List.iter (fun (p, a, c) -> if reach p a c then Hashtbl.remove live (p, a, c)) edges;
    (* and of rules that are the same edge (cax-sco over scm-int's facts and cls-int2 give [x type C] -> [x type A]
       both), one: the others would derive each fact again *)
    let kept = Hashtbl.create (2 * n) in
    let parts =
      List.filter
        (fun (_, r, bad) ->
          bad <> ""
          || match edge r with
             | Some e -> Hashtbl.mem live e && not (Hashtbl.mem kept e) && (Hashtbl.replace kept e (); true)
             | None -> true)
        parts
    in
    (* Rules of one body whose heads [t P c] differ only by c (prp-dom over a domain and the domains scm-dom1 gives
       up its superclasses): one whose c follows from another's c by the edges of P gives nothing the other and the
       edges do not; it goes (of classes that reach each other, the least stays) *)
    let reach_any p a c =
      let seen = Hashtbl.create 16 and stack = ref [ a ] and found = ref false in
      while (not !found) && !stack <> [] do
        let u = List.hd !stack in
        stack := List.tl !stack;
        List.iter
          (fun w -> if Hashtbl.mem live (p, u, w) then if w = c then found := true else if not (Hashtbl.mem seen w) then (Hashtbl.replace seen w (); stack := w :: !stack))
          (Hashtbl.find_all out (p, u))
      done;
      !found
    in
    let key (r : Rules.t) = match r.head with Rules.Give { e; p; v = Thing c } when p >= 0 && edge r = None -> Some ((r.where, r.ranges, e, p), c) | _ -> None in
    let groups = Hashtbl.create 64 in
    List.iter (fun (_, r, bad) -> if bad = "" then match key r with Some (k, c) -> Hashtbl.replace groups k (c :: Option.value (Hashtbl.find_opt groups k) ~default:[]) | None -> ()) parts;
    List.filter
      (fun (_, r, bad) ->
        bad <> ""
        ||
        match key r with
        | Some (((_, _, _, p) as k), c) ->
          let cs = Hashtbl.find groups k in
          not (List.exists (fun c1 -> c1 <> c && reach_any p c1 c && ((not (reach_any p c c1)) || c1 < c)) cs)
        | None -> true)
      parts
  end

(* the program of the generic one's rules unfolded on the view's small relations; None when nothing unfolds *)
(* the rules unfolded on the view's small relations, and the relations they were unfolded on (frozen); None when
   no rule unfolds *)
let [@inline never] spec_parts ?unstable (v : Store.view) (gen : program) =
  let n = Array.length gen.rules in
  let unfold g =
    let r = gen.rules.(g) and sty = gen.sty.(g) in
    (* a rule that makes things the same, over a relation with no fact, is left out while it has none (the relation
       frozen): a database whose ontology and data make nothing the same keeps the closure modules, the path of
       loads and the parallel rounds, which classes of equal things turn off *)
    let unst = match unstable with Some f -> f | None -> fun _ -> false in
    let empty =
      match r.head with
      | Rules.Give h when h.p = Schema.p_same ->
        List.find_opt
          (fun (a : Query.pattern) ->
            a.p >= 0 && (not (unst (rel_of a)))
            && (match a.v with
                | Val x when not (is_text_const x) -> S.count_things v a.p (inline_word x) = 0
                | Thing c -> S.count_things v a.p c = 0
                | _ -> S.count_prop v a.p = 0))
          r.where
      | _ -> None
    in
    match empty with
    | Some a -> Some ([], [ rel_of a ])
    | None ->
    match small_atoms ?unstable v ~counts:true r sty with
    | None -> None
    | Some cand -> (
      match small_bindings v r gen.atoms.(g) cand with
      | None -> None
      | Some bs ->
        let seen = Hashtbl.create 16 in
        let rs =
          List.filter_map
            (fun b ->
              match substitute v r sty cand b with
              | Some ((r', _) as x) when not (Hashtbl.mem seen (r'.where, r'.head)) -> Hashtbl.replace seen (r'.where, r'.head) (); Some x
              | _ -> None)
            bs
        in
        Some (rs, List.sort_uniq compare (List.map (fun i -> rel_of gen.atoms.(g).(i)) cand)))
  in
  let unfolded = Array.init n unfold in
  let rec attempt (keep : bool array) =
    (* the program: each rule unfolded, or as written *)
    let parts =
      Array.to_list
        (Array.mapi
           (fun g u ->
             match u with
             | Some (rs, _) when not keep.(g) -> List.map (fun (r, bad) -> g, r, bad) rs
             | _ -> [ g, gen.rules.(g), "" ])
           unfolded)
      |> List.concat
    in
    let rules = Array.of_list (List.map (fun (_, r, _) -> r) parts) in
    (* a relation that depends on what its unfolded rules give is not unfolded on *)
    let bad = ref false in
    Array.iteri
      (fun g u ->
        match u with
        | Some (rs, rels) when not keep.(g) ->
          let starts = List.filter_map (fun ((r : Rules.t), _) -> match r.head with Give h -> Some ((if h.p < 0 then -1 else h.p), snd (rel_of h)) | Never -> None) rs in
          if reaches rules starts rels then (keep.(g) <- true; bad := true)
        | _ -> ())
      unfolded;
    if !bad then attempt keep else parts
  in
  let keep = Array.make n false in
  let parts = attempt keep in
  if Array.for_all Fun.id (Array.mapi (fun g u -> u = None || keep.(g)) unfolded) then None
  else
    Some
      ( parts,
        List.sort_uniq compare (List.concat (Array.to_list (Array.mapi (fun g u -> match u with Some (_, rels) when not keep.(g) -> rels | _ -> []) unfolded)))
        |> Array.of_list )

let [@inline never] make_spec ?unstable (v : Store.view) (gen : program) =
  match spec_parts ?unstable v gen with
  | None -> None
  | Some (parts, rels) ->
    let np = Schema.count v.schema in
    let frozen = Bytes.make np '\000' and fws = Array.make np [] in
    Array.iter
      (fun (p, w) ->
        if p < np then
          if w < 0 then Bytes.set frozen p '\001'
          else if Bytes.get frozen p <> '\001' then (Bytes.set frozen p '\002'; fws.(p) <- w :: fws.(p)))
      rels;
    let spec =
      { rels; frozen; frozen_ws = Array.map (fun l -> let a = Array.of_list l in Array.sort compare a; a) fws;
        rfacts = Array.map (rel_facts v) rels; sruns = v.runs; stamps = Array.map (fun (p, w) -> Store.stamp v p w) rels }
    in
    let parts = Array.of_list (reduce parts) in
    Some
      (build ~also_reads:(Array.map fst rels) ~lists:gen.lists v ~key:gen.key ~src:(Array.map (fun (_, r, _) -> r) parts) ~ids:(Array.map (fun (g, _, _) -> gen.ids.(g)) parts)
         ~bad_head:(Array.map (fun (_, _, b) -> b) parts) ~spec:(Some spec))

(* does the view hold the facts the program was unfolded on: by identity first (Store.stamp), else by its facts *)
let [@inline never] spec_holds (s : spec) (v : Store.view) =
  (v.runs == s.sruns
   &&
   let ok = ref true in
   Array.iteri (fun i (p, w) -> if !ok && not (Store.same_stamp (Store.stamp v p w) s.stamps.(i)) then ok := false) s.rels;
   !ok)
  ||
  if Array.map (rel_facts v) s.rels = s.rfacts then begin
    s.sruns <- v.runs;
    s.stamps <- Array.map (fun (p, w) -> Store.stamp v p w) s.rels;
    true
  end
  else false

let[@inline] mem_sorted (a : int array) w =
  let lo = ref 0 and hi = ref (Array.length a) in
  while !lo < !hi do let m = (!lo + !hi) lsr 1 in if Array.unsafe_get a m < w then lo := m + 1 else hi := m done;
  !lo < Array.length a && Array.unsafe_get a !lo = w

let[@inline] is_frozen (s : spec) p w =
  p >= 0 && p < Bytes.length s.frozen
  && match Bytes.unsafe_get s.frozen p with '\000' -> false | '\001' -> true | _ -> mem_sorted s.frozen_ws.(p) w

(* ---- the programs of a view ---- *)

type entry = {
  mutable gen : program;
  mutable specs : program list;
  mutable nospec : bool;
  specialisable : bool;
  mutable unstable : (int * int) list;  (* facts of frozen relations that groups changed: their relations are data *)
}

let cache : (int, entry) Hashtbl.t = Hashtbl.create 8
let cache_m = Mutex.create ()

(* the generic program of a view's rules, compiled once for a rule set, again when the database's size has moved by a
   factor of 2 since its orders were chosen or the schema's table of properties grew; and the program unfolded on the
   view's small relations, when its rules have some *)
let [@inline never] programs (v : Store.view) =
  let key = Schema.rules_key v.schema in
  Mutex.protect cache_m (fun () ->
      let size = S.facts v in
      let en =
        let old = Hashtbl.find_opt cache key in
        match old with
        | Some en when size <= (2 * en.gen.size) + 1024 && (2 * size) + 1024 >= en.gen.size && Schema.count v.schema = en.gen.np && lists_hold en.gen v -> en
        | _ ->
          let gen = make_gen v in
          (* rules with Not or aggregates run as written: their strata are the rules' *)
          let specialisable =
            (not gen.stratified) && Array.exists Fun.id (Array.mapi (fun g r -> small_atoms v ~counts:false r gen.sty.(g) <> None) gen.rules)
          in
          (* the relations found to be the data's stay so while the rules do *)
          let unstable = match old with Some en -> en.unstable | None -> [] in
          let en = { gen; specs = []; nospec = false; specialisable; unstable } in
          if Hashtbl.length cache > 16 then Hashtbl.reset cache;
          Hashtbl.replace cache key en;
          en
      in
      if (not !specialise) || (not en.specialisable) || en.nospec then en.gen, None
      else
        match List.find_opt (fun (p : program) -> spec_holds (Option.get p.spec) v) en.specs with
        | Some p -> en.gen, Some p
        | None -> (
          let unstable (rp, rw) = List.exists (fun (p, w) -> p = rp && (rw < 0 || rw = w)) en.unstable in
          match make_spec ~unstable v en.gen with
          | None -> en.nospec <- true; en.gen, None
          | Some p ->
            en.specs <- p :: List.filteri (fun i _ -> i < 3) en.specs;
            en.gen, Some p))

let program (v : Store.view) = fst (programs v)

(* a group changed the fact (p, w) of a relation the rules were unfolded on: that relation is not unfolded on again
   while this program lasts (until the rules change or the database's size doubles) *)
let [@inline never] unsettle (v : Store.view) (facts : (int * int) list) =
  Mutex.protect cache_m (fun () ->
      match Hashtbl.find_opt cache (Schema.rules_key v.schema) with
      | Some en ->
        let fresh = List.filter (fun f -> not (List.mem f en.unstable)) (List.sort_uniq compare facts) in
        if fresh <> [] then begin
          en.unstable <- List.filteri (fun i _ -> i < 256) (fresh @ en.unstable);
          en.specs <- [];
          en.nospec <- false
        end
      | None -> ())

(* The program a group runs: the unfolded one, unless the group's asserted facts touch a relation it is unfolded on;
   then those relations are the data's ([unsettle]), and the rules are unfolded again without them, once; past that,
   the rules as written. [touched s] lists the group's facts of frozen relations of [s]. *)
let [@inline never] choose (v : Store.view) (gen : program) (spec : program option) (touched : spec -> (int * int) list) =
  let rec go spec tries =
    match spec with
    | None -> gen
    | Some (p : program) -> (
      match touched (Option.get p.spec) with
      | [] -> p
      | facts -> unsettle v facts; if tries > 0 then go (snd (programs v)) (tries - 1) else gen)
  in
  go spec 1

(* ---- contexts ---- *)

let [@inline never] new_ctx ?facts ?keys prog v =
  let nm = Array.length prog.modules in
  let bfq = Queue.create () in
  { prog; ws = ws_create ?facts ?keys (); pt = ws_create (); v; v0 = v; cur = -1;
    bfqs = Array.init prog.nstrata (fun s -> if s = 0 then bfq else Queue.create ()); ins_s = Array.make prog.nstrata None;
    xplans = Hashtbl.create 8; round = max_int; cw = Array.make (Array.length prog.consts) (-1);
    ins = None; lost = None; lost_walk = None; cons = None; pf = [||]; bwd = [||]; bfq; next = ints 64 0;
    spare = ints 64 0; nn = 0; derived = 0; limit = max_int; whole = false; stop = never; vp = Bytes.empty;
    per_rule = Array.make (Array.length prog.rules) 0; side_e = Bulk.i32 0; side_p = Bulk.u16 0; side_w = ints_raw 0; ns = 0; mbatch = Array.make nm (-1);
    mfresh = Array.make nm false; buf_a = buf_create 64; buf_b = buf_create 64; seen = iset_create ();
    seen2 = iset_create (); walked = Bytes.empty; xk = ignore; plain_derive = false; heads_none = Hashtbl.create 8;
    eqon = false; nr = Hashtbl.create 1; nrbits = Bytes.empty; eqt = Hashtbl.create 8; eqbits = Bytes.empty; eqset = [];
    pend = []; boom = []; exploded = Hashtbl.create 8; refill = [];
    why_mode = false }

let [@inline never] take ?facts ?keys prog v =
  let c =
    if facts <> None then None
    else Mutex.protect prog.pm (fun () -> match !(prog.pool) with c :: r -> prog.pool := r; Some c | [] -> None)
  in
  let c = match c with Some c -> c | None -> new_ctx ?facts ?keys prog v in
  c.v <- v;
  c.round <- max_int;
  Array.iteri (fun i x -> c.cw.(i) <- Option.value (S.word v x) ~default:(-1)) prog.consts;
  c.nn <- 0;
  c.derived <- 0;
  c.limit <- max_int;
  c.whole <- false;
  c.stop <- never;
  c.vp <- Bytes.empty;
  c.ws.with_ip <- true;
  c.ns <- 0;
  Array.fill c.mbatch 0 (Array.length c.mbatch) (-1);
  Array.fill c.mfresh 0 (Array.length c.mfresh) false;
  Array.fill c.per_rule 0 (Array.length c.per_rule) 0;
  Array.iter Queue.clear c.bfqs;
  c.v0 <- v;
  c.cur <- -1;
  c.walked <- Bytes.empty;
  c.plain_derive <- false;
  Hashtbl.reset c.heads_none;
  Hashtbl.reset c.eqt;
  List.iter (fun x -> c.eqbits <- set_bit c.eqbits x false) c.eqset;
  c.eqset <- [];
  Hashtbl.reset c.exploded;
  c.pend <- [];
  c.boom <- [];
  c.refill <- [];
  c.why_mode <- false;
  (let t, b = if prog.eq then nonreps v else Hashtbl.create 1, Bytes.empty in c.nr <- t; c.nrbits <- b);
  c.eqon <- prog.eq && Hashtbl.length c.nr > 0;
  c

let [@inline never] give c =
  (* a context that held a large group's facts is let go, its memory with it *)
  if c.ws.cap <= 1 lsl 16 && A.dim c.side_w <= 1 lsl 16 then begin
    reset c.ws;
    reset c.pt;
    Mutex.protect c.prog.pm (fun () -> c.prog.pool := c :: !(c.prog.pool))
  end

let with_ctx ~prog ?facts ?keys v f =
  let c = take ?facts ?keys prog v in
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
    (* the rule named is the generic one: an unfolded rule keeps its name; their counts summed *)
    let by = Hashtbl.create 8 in
    Array.iteri (fun i n -> if n > 0 then Hashtbl.replace by (rule_name c i) (n + Option.value (Hashtbl.find_opt by (rule_name c i)) ~default:0)) c.per_rule;
    let best = Hashtbl.fold (fun name n (bn, bk) -> if n > bk || (n = bk && name < bn) then name, n else bn, bk) by ("", -1) in
    if c.whole then refuse "rule %s derived more than %d facts from a change of the rules or the ontology" (fst best) c.limit
    else
      raise
        (Exceeded
           (Printf.sprintf "rule %s derived more than %d facts from a group of %d facts" (fst best) c.limit
              ((c.limit - !budget_base) / max 1 !budget_per)))
  end
  else if c.derived land 1023 = 0 && Atomic.get c.stop then refuse "the change was cancelled: the database closes"

(* a frozen relation's fact about to change: the group is reasoned again with the generic rules *)
let[@inline] check_frozen c p w = match c.prog.spec with None -> () | Some s -> if is_frozen s p w then raise_notrace (Respec (p, w))

let [@inline never] head_refusal c (pl : plan) =
  let b = c.prog.bad_head.(pl.ri) in
  if b <> "" then b else head_message c.v (rule_name c pl.ri) ~thing:(pl.he <> -1) pl.hp

(* the head of a forward instance, at round r - 1: a fact that is not there yet joins round r *)
(* a change derives many facts of a few heads (p, w): one count tells when the view holds none of a head's, and its
   facts are then not looked up one by one (the view's facts do not change while a group is reasoned) *)
let[@inline never] none_of c p w =
  match Hashtbl.find_opt c.heads_none (p, w) with
  | Some b -> b
  | None -> let b = S.count_things c.v p w = 0 in Hashtbl.replace c.heads_none (p, w) b; b

(* the head (e p w) of an instance of rule ri: a fact at round r, unless it is one already *)
let[@inline never] emit_fact c ri e p w r =
  let ws = c.ws in
  let x = find ws e p w in
  if x >= 0 then begin
    if now ws x = 0 then begin
      check_frozen c p w;
      set_now ws x 2;
      set_round ws x r;
      set_rule ws x ri;
      count_derived c ri;
      push_next c x
    end
  end
  else if not ((Bytes.length c.vp = 0 || (p < Bytes.length c.vp && Bytes.unsafe_get c.vp p <> '\000')) && e < ws.fresh && (not (c.whole && none_of c p w)) && S.mem c.v e p w) then begin
    if e >= c.v.next_e then refuse "rule %s gives a fact about #%d, which does not exist" (rule_name c ri) e;
    check_frozen c p w;
    let x = add ws e p w 0 in
    set_now ws x 2;
    set_round ws x r;
    set_rule ws x ri;
    count_derived c ri;
    push_next c x
  end

(* an instance of a rule that makes two things the same: an equality for the round's end (two values that differ are
   never the same thing: the group is refused) *)
let[@inline never] same_head c pl =
  let a = pl.he and b = pl.hw in
  if a <> b then begin
    if not pl.hok then refuse "rule %s makes two different values the same: only things can be the same as another" (rule_name c pl.ri);
    if rep_of c a <> rep_of c b then c.pend <- (a, b, pl.ri) :: c.pend
  end

let emit_at c pl r =
  incr derivations;
  if pl.hp = Schema.p_same then same_head c pl
  else begin
    if not pl.hok then refuse "%s" (head_refusal c pl);
    emit_fact c pl.ri pl.he pl.hp pl.hw r
  end

(* ---- Large rounds on several domains (the design's section 5.14) ----
   A round of many facts, or the first round of a change's added rules, is cut into morsels (Leis et al., SIGMOD
   2014) taken in turn by the domains (Bulk.parallel): each derives with plans of its own in a context of its own,
   reading the view and the working set, which nobody writes meanwhile, and keeps the heads it finds; then this domain
   makes them facts, morsel after morsel, in order, exactly as it would have found them alone: the result, the budget
   and the refusals do not depend on the domains. Only for rules without Not and aggregates, and when every constant
   of the rules is interned (a plan interns a head's text at its first use). *)

let par_min = ref 20_000  (* a round of at least this many facts runs on several domains *)

let [@inline never] worker_ctx c =
  { c with ins = None; lost = None; lost_walk = None; cons = None; pf = [||]; bwd = [||]; ins_s = Array.make c.prog.nstrata None;
           xplans = Hashtbl.create 8; next = ints 16 0; spare = ints 16 0; nn = 0; per_rule = Array.make (Array.length c.prog.rules) 0;
           buf_a = buf_create 16; buf_b = buf_create 16; seen = iset_create (); seen2 = iset_create (); pt = ws_create ();
           heads_none = Hashtbl.create 1 }

(* not for a change in the background ([stop] is its own): its domain alone, so that the writer and its clients keep
   the other cores while it runs *)
let par_ok c = !Bulk.threads > 1 && c.stop == never && (not c.prog.eq) && ((not c.prog.stratified) || c.plain_derive) && Array.for_all (fun w -> w >= 0) c.cw

exception Too_many

(* [k] morsels, [run w m f]: morsel m derived in context w, each instance to f; their heads made facts of round [r].
   false: the morsels found more heads than the budget leaves room for (the caller derives alone, which refuses
   exactly where it must) *)
(* The heads of a large round made facts on several domains, with the ids, rounds, rules and next round's list the
   one-domain loop below gives (so that nothing depends on the domains). The candidates, numbered g in morsel order,
   are deduplicated by regions of the membership table, one domain a region, each claiming an empty slot for the
   first candidate of a fact (its slot marked -(2 + g)) and finding the later ones there; a candidate whose probe
   would leave its region is decided after, in order, by the usual probe. The facts claimed then take their ids in
   the order of g, are written on several domains, and join the chains and the next round in that order. Only when
   no candidate can refuse the group (the budget has room for them all, no frozen fact, no thing past the last). *)
let [@inline never] merge_regions c (outs : buf array) r =
  let ws = c.ws and k = Array.length outs in
  let mbase = Array.make (k + 1) 0 in
  for m = 0 to k - 1 do mbase.(m + 1) <- mbase.(m) + (outs.(m).bn / 4) done;
  let total = mbase.(k) in
  let n0 = ws.n in
  while n0 + total > ws.cap do grow ws done;
  if 2 * (n0 + total) > A.dim ws.set then begin
    let size = ref (A.dim ws.set) in
    while 2 * (n0 + total) > !size do size := 2 * !size done;
    ws.set <- ints !size (-1);
    ws.smask <- !size - 1;
    for x = 0 to n0 - 1 do place ws x done
  end;
  (* candidate g: morsel m, position j *)
  let morsel = Array.make (max 1 total) 0 in
  for m = 0 to k - 1 do Array.fill morsel mbase.(m) (mbase.(m + 1) - mbase.(m)) m done;
  let cget g f = let m = Array.unsafe_get morsel g in buf_get outs.(m) ((4 * (g - mbase.(m))) + f) in
  let flag = Bytes.make (max 1 total) '\000' and slot = ints_raw (max 1 total) and xid = ints_raw (max 1 total) in
  (* the decision for candidate g at slot i onwards, up to [hi]: true when decided *)
  let decide g i0 hi =
    let e = cget g 0 and p = cget g 1 and w = cget g 2 in
    let set = ws.set and mask = ws.smask in
    let i = ref i0 and fin = ref false and stop = ref false in
    while not !stop do
      if !i >= hi then stop := true
      else begin
        let v = A.unsafe_get set !i in
        if v = -1 then begin
          A.unsafe_set set !i (-(2 + g));
          Bytes.unsafe_set flag g '\001';
          A.unsafe_set slot g !i;
          fin := true;
          stop := true
        end
        else if v >= 0 then begin
          if fe ws v = e && fw ws v = w && fp ws v = p then begin
            if now ws v = 0 then (Bytes.unsafe_set ws.now v '\002'; Bytes.unsafe_set flag g '\002'; A.unsafe_set xid g v);
            fin := true;
            stop := true
          end
          else i := (!i + 1) land mask
        end
        else begin
          let g' = -v - 2 in
          if cget g' 0 = e && cget g' 2 = w && cget g' 1 = p then (fin := true; stop := true) else i := (!i + 1) land mask
        end;
        if (not !stop) && !i = 0 && hi > mask then stop := true
      end
    done;
    !fin
  in
  let size = A.dim ws.set in
  let regions = let rr = ref 1 in while 2 * !rr <= 2 * !Bulk.threads && 2 * !rr <= size / 1024 do rr := 2 * !rr done; !rr in
  let per = size / regions in
  (* each candidate's slot, then the candidates of each region in order (a counting sort by region, morsel by
     morsel), so that a region's domain reads its own candidates only *)
  let home = ints_raw (max 1 total) in
  let cnt = Array.init k (fun _ -> Array.make regions 0) in
  Bulk.parallel ~d:!Bulk.threads k (fun m ->
      let c = cnt.(m) in
      for g = mbase.(m) to mbase.(m + 1) - 1 do
        let i = h3 (cget g 0) (cget g 1) (cget g 2) land ws.smask in
        A.unsafe_set home g i;
        let rg = i / per in
        c.(rg) <- c.(rg) + 1
      done);
  let roff = Array.make (regions + 1) 0 in
  for rg = 0 to regions - 1 do roff.(rg + 1) <- roff.(rg) + Array.fold_left (fun t c -> t + c.(rg)) 0 cnt done;
  let at = Array.init k (fun _ -> Array.make regions 0) in
  for rg = 0 to regions - 1 do
    let s = ref roff.(rg) in
    for m = 0 to k - 1 do at.(m).(rg) <- !s; s := !s + cnt.(m).(rg) done
  done;
  let byreg = ints_raw (max 1 total) in
  Bulk.parallel ~d:!Bulk.threads k (fun m ->
      let a = at.(m) in
      for g = mbase.(m) to mbase.(m + 1) - 1 do
        let rg = A.unsafe_get home g / per in
        A.unsafe_set byreg a.(rg) g;
        a.(rg) <- a.(rg) + 1
      done);
  let aside = Array.make regions [] in
  Bulk.parallel ~d:!Bulk.threads regions (fun rg ->
      let hi = (rg + 1) * per and l = ref [] in
      for q = roff.(rg) to roff.(rg + 1) - 1 do
        let g = A.unsafe_get byreg q in
        if not (decide g (A.unsafe_get home g) hi) then l := g :: !l
      done;
      aside.(rg) <- !l);
  (* the candidates set aside, in order, by the usual probe (it may cross regions, and wraps) *)
  let rest = List.sort compare (List.concat (Array.to_list aside)) in
  List.iter
    (fun g ->
      let i = h3 (cget g 0) (cget g 1) (cget g 2) land ws.smask in
      (* from its slot to the table's end, then from its start: an empty slot is found (the table is at most half full) *)
      if not (decide g i size) then ignore (decide g 0 size))
    rest;
  (* ids in the order of g *)
  let cnt = ref n0 in
  for g = 0 to total - 1 do if Bytes.unsafe_get flag g = '\001' then (A.unsafe_set xid g !cnt; incr cnt) done;
  ws.n <- !cnt;
  Bulk.parallel ~d:!Bulk.threads k (fun m ->
      for g = mbase.(m) to mbase.(m + 1) - 1 do
        match Bytes.unsafe_get flag g with
        | '\001' ->
          let x = A.unsafe_get xid g in
          set_f ws x (cget g 0) (cget g 1) (cget g 2);
          Bytes.unsafe_set ws.base x '\000';
          Bytes.unsafe_set ws.old x '\000';
          Bytes.unsafe_set ws.now x '\002';
          Bytes.unsafe_set ws.mark x '\000';
          A.unsafe_set ws.round x r;
          A.unsafe_set ws.rule x (cget g 3);
          A.unsafe_set ws.set (A.unsafe_get slot g) x
        | '\002' ->
          let x = A.unsafe_get xid g in
          A.unsafe_set ws.round x r;
          A.unsafe_set ws.rule x (cget g 3)
        | _ -> ()
      done);
  (* the chains, the counts and the next round, in order *)
  for g = 0 to total - 1 do
    if Bytes.unsafe_get flag g <> '\000' then begin
      let x = A.unsafe_get xid g in
      if base ws x = 0 then chain ws x;
      count_derived c (cget g 3);
      push_next c x
    end
  done

(* [k] morsels, [run w m f]: morsel m derived in context w, each instance to f; their heads made facts of round [r].
   false: the morsels found more heads than the budget leaves room for (the caller derives alone, which refuses
   exactly where it must) *)
let [@inline never] par_phase c k (run : ctx -> int -> (plan -> unit) -> unit) r =
  let outs = Array.init k (fun _ -> buf_create 64) and fails = Array.make k None and odd = Array.make k false in
  let left = c.limit - c.derived in
  let room = if left > max_int / 4 then max_int else (2 * left) + 100_000 in
  let heads = Atomic.make 0 and found_all = Atomic.make 0 in
  match
    Bulk.parallel ~d:!Bulk.threads k (fun m ->
        let w = worker_ctx c and out = outs.(m) and n = ref 0 and nf = ref 0 in
        let ws = c.ws and vp = c.vp and next_e = c.v.next_e and spec = c.prog.spec in
        let found pl =
          incr nf;
          if not pl.hok then raise (Refused (head_refusal w pl));
          let e = pl.he and p = pl.hp and v = pl.hw in
          (* a head that is a fact already changes nothing (as emit_fact): only the others are kept *)
          let x = find ws e p v in
          if (if x >= 0 then now ws x = 0 else not ((Bytes.length vp = 0 || (p < Bytes.length vp && Bytes.unsafe_get vp p <> '\000')) && e < ws.fresh && S.mem w.v e p v))
          then begin
            buf_push out e; buf_push out p; buf_push out v; buf_push out pl.ri;
            (* a head the merge must refuse or reason again about: the one-domain merge decides it *)
            if e >= next_e || (match spec with None -> false | Some s -> is_frozen s p v) then odd.(m) <- true;
            incr n;
            if !n land 1023 = 0 && Atomic.fetch_and_add heads 1024 + 1024 > room then raise Too_many
          end
        in
        (try run w m found with Refused msg -> fails.(m) <- Some msg);
        ignore (Atomic.fetch_and_add found_all !nf))
  with
  | () ->
    derivations := !derivations + Atomic.get found_all;
    let total = Array.fold_left (fun t (o : buf) -> t + (o.bn / 4)) 0 outs in
    if total >= !par_min && c.derived + total <= c.limit && Array.for_all Option.is_none fails && not (Array.exists Fun.id odd) then
      merge_regions c outs r
    else
    for m = 0 to k - 1 do
      let out = outs.(m) in
      let i = ref 0 in
      let ws = c.ws in
      while !i < out.bn do
        let ri = buf_get out (!i + 3) and e = buf_get out !i and p = buf_get out (!i + 1) and w = buf_get out (!i + 2) in
        let x = find ws e p w in
        if x >= 0 then begin
          if now ws x = 0 then (check_frozen c p w; set_now ws x 2; set_round ws x r; set_rule ws x ri; count_derived c ri; push_next c x)
        end
        else begin
          (* not in the view: its morsel looked *)
          if e >= c.v.next_e then refuse "rule %s gives a fact about #%d, which does not exist" (rule_name c ri) e;
          check_frozen c p w;
          let x = add ws e p w 0 in
          set_now ws x 2; set_round ws x r; set_rule ws x ri; count_derived c ri; push_next c x
        end;
        i := !i + 4
      done;
      outs.(m) <- buf_create 0;
      Option.iter (fun msg -> raise (Refused msg)) fails.(m)
    done;
    true
  | exception Too_many -> false

let emit c pl = emit_at c pl (c.round + 1)

let ins_d c = match c.ins with Some d -> d | None -> let d = make_disp c c.prog.ix_ins State (emit c) in c.ins <- Some d; d

(* insertion for stratum [s] *)
let ins_s_d c s =
  if c.prog.nstrata = 1 then ins_d c
  else
    match c.ins_s.(s) with
    | Some d -> d
    | None -> let d = make_disp c c.prog.ix_ins_s.(s) State (emit c) in c.ins_s.(s) <- Some d; d

(* The plans of Not flips and aggregates, compiled at their first use in a context, their instances sent to [c.xk]:
   by the reading of their positive patterns, of their Not's other patterns, and their Nots' check. *)
let[@inline never] xplan c ri pos (source : source) (nsrc : source) (nmode : nmode) =
  let code = (match source with State -> 0 | Proved -> 1 | Old -> 2) + (4 * match nsrc with State -> 0 | Proved -> 1 | Old -> 2) + (16 * match nmode with Now -> 0 | Before -> 1) in
  match Hashtbl.find_opt c.xplans (ri, pos, code) with
  | Some pl -> pl
  | None ->
    let pl = compile c ~nmode ~nsrc ri pos source (fun pl -> c.xk pl) in
    Hashtbl.replace c.xplans (ri, pos, code) pl;
    pl

(* ---- the state ---- *)

let[@inline] in_view c p = Bytes.length c.vp = 0 || (p < Bytes.length c.vp && Bytes.unsafe_get c.vp p <> '\000')

(* is (e p w) a fact now: the working set's entry, else the view *)
let[@inline never] present c e p w = let x = find c.ws e p w in if x >= 0 then now c.ws x > 0 else in_view c p && e < c.ws.fresh && S.mem c.v e p w

(* the id of a fact of the state in the working set, added with its state in the view if needed *)
let[@inline never] intern c e p w =
  let x = find c.ws e p w in
  if x >= 0 then x else add c.ws e p w (S.state c.v e p w)

(* the values of (e p _) now, and the things of (_ p w) now *)
let [@inline never] iter_out c e p f =
  let ws = c.ws in
  if in_view c p && e < ws.fresh then S.iter_values c.v e p (fun w -> if ws.n = 0 then f w else let x = find ws e p w in if x < 0 || now ws x > 0 then f w);
  b_iter_e ws e p f;
  let x = ref (idx_head ws.ie p e) in
  while !x >= 0 do
    let y = !x in
    if fe ws y = e && fp ws y = p && now ws y > 0 then f (fw ws y);
    x := idx_next ws.ie y
  done

let [@inline never] iter_in c p w f =
  let ws = c.ws in
  if in_view c p then S.iter_things c.v p w (fun e -> if ws.n = 0 then f e else let x = find ws e p w in if x < 0 || now ws x > 0 then f e);
  b_iter_w ws p w f;
  let x = ref (idx_head ws.iw p w) in
  while !x >= 0 do
    let y = !x in
    if fw ws y = w && fp ws y = p && now ws y > 0 then f (fe ws y);
    x := idx_next ws.iw y
  done

(* every fact of p now *)
let [@inline never] iter_all c p f =
  let ws = c.ws in
  if in_view c p then S.iter_prop c.v p (fun e w -> if ws.n = 0 then f e w else let x = find ws e p w in if x < 0 || now ws x > 0 then f e w);
  for x = 0 to ws.n - 1 do
    if fp ws x = p && base ws x = 0 && now ws x > 0 then f (fe ws x) (fw ws x)
  done

(* ---- B/F and Why: the backward check, and proofs forward among the proved facts ---- *)

(* is a fact decided for the stratum being maintained: given by rules of a lower stratum (complete), or by an
   aggregate (its stratum's aggregates are computed first). A fact no rule gives is not: it holds when asserted *)
let[@inline never] decided c x =
  let p = fp c.ws x in
  (p >= 0 && p < Array.length c.prog.agg_rule && c.prog.agg_rule.(p) >= 0)
  || (let s = fact_stratum c.prog p (fw c.ws x) in s >= 0 && s < c.cur)

(* the queue of B/F's candidates of a rule's stratum *)
let[@inline] queue_of c ri = if c.prog.nstrata = 1 then c.bfq else Array.unsafe_get c.bfqs (Array.unsafe_get c.prog.strat ri)

(* does a thing belong to a class of more than one thing (now) *)
let [@inline never] in_class c t =
  rep_of c t <> t || (let n = ref false in iter_in c Schema.p_same t (fun y -> if rep_of c y = t then n := true); !n)

(* the class a fact names (as its thing, or its value under a link property), if one has more than one thing: its
   representative, or -1 *)
let [@inline never] class_named c x =
  let ws = c.ws in
  let e = fe ws x and p = fp ws x and w = fw ws x in
  if p = Schema.p_same then -1
  else if in_class c e then rep_of c e
  else if ptype c.v p = link_code && in_class c w then rep_of c w
  else -1

let rec plans c d =
  if d >= Array.length c.bwd then begin
    let n = Array.length c.bwd in
    let mk k f = make_disp c (if f then c.prog.ix_pf else c.prog.ix_bw) (if f then Proved else State) (if f then proved_instance c k else backward_instance c k) in
    c.pf <- Array.append c.pf (Array.init (d + 1 - n) (fun i -> mk (n + i) true));
    c.bwd <- Array.append c.bwd (Array.init (d + 1 - n) (fun i -> mk (n + i) false))
  end

(* an instance among the proved facts: its head, if checked and not yet proved, is proved now *)
and proved_instance c d pl =
  if pl.hok then begin
    let h = find c.ws pl.he pl.hp pl.hw in
    if h >= 0 && has c.ws h 1 && not (has c.ws h 2) then begin
      let ats = c.prog.atoms.(pl.ri) in
      set_rule c.ws h pl.ri;
      set_by c.ws h (Array.mapi (fun j _ -> find c.ws pl.be.(j) pl.bp.(j) pl.bw.(j)) ats);
      prove c (d + 1) h
    end
  end

(* an instance of a rule whose head is the fact being checked: its body facts checked; all proved, it proves it *)
and backward_instance c d pl =
  let ats = c.prog.atoms.(pl.ri) in
  let ids = Array.mapi (fun j _ -> intern c pl.be.(j) pl.bp.(j) pl.bw.(j)) ats in
  let ws = c.ws in
  Array.iter (fun y -> check c (d + 1) y) ids;
  let x = find ws pl.he pl.hp pl.hw in
  if x >= 0 && (not (has ws x 2)) && Array.for_all (fun y -> has ws y 2) ids then begin
    set_rule ws x pl.ri;
    set_by ws x ids;
    prove c d x
  end;
  if x >= 0 && has ws x 2 then raise_notrace Exit

and prove c d x =
  let ws = c.ws in
  if not (has ws x 2) then begin
    set_mark ws x 2;
    let pt = c.pt in
    let e = fe ws x and p = fp ws x and w = fw ws x in
    if find pt e p w < 0 then begin
      let y = add pt e p w 1 in
      set_rule pt y x;
      chain pt y
    end;
    plans c d;
    run_all (Array.unsafe_get c.pf d) e p w
  end

and check c d x =
  let ws = c.ws in
  if not (has ws x 1) then begin
    set_mark ws x 1;
    incr checked;
    if base ws x = 1 then prove c d x
    else if c.prog.stratified && decided c x then
      (* a fact of a lower stratum, complete, or of an aggregate, computed before: present, it holds *)
      (if now ws x > 0 then begin
         let ri = let p = fp ws x in if p < Array.length c.prog.agg_rule then c.prog.agg_rule.(p) else -1 in
         if ri >= 0 then (set_rule ws x ri; set_by ws x [||]);
         prove c d x
       end)
    else if Bytes.length c.walked > 0 && (let p = fp ws x in p < Bytes.length c.walked && Bytes.unsafe_get c.walked p <> '\000') then
      (* a fact of a closure its module decided in this group: present, it holds *)
      (if now ws x > 0 then prove c d x)
    else if c.eqon && fp ws x = Schema.p_same then
      (* a class's own fact: Why names the class (the equality's own proof is not given yet); B/F never checks it *)
      (if c.why_mode && now ws x > 0 then (set_rule ws x (-3); set_by ws x [||]; prove c d x))
    else if c.eqon && (not c.why_mode) && class_named c x >= 0 then
      (* a fact only derived of a class of several things: unknown until its class is derived again (B/F takes the
         class apart) *)
      c.boom <- class_named c x :: c.boom
    else begin
      let p = fp ws x in
      if p < c.prog.np && Char.code (Bytes.unsafe_get c.prog.reads p) land 2 <> 0 then begin
        plans c d;
        try run_all (Array.unsafe_get c.bwd d) (fe ws x) p (fw ws x) with Exit -> ()
      end;
      (* Why: a fact of a representative that rewrites an asserted fact of a member of its class (or of its value's) *)
      if c.eqon && c.why_mode && (not (has ws x 2)) && now ws x > 0 then begin
        let e = fe ws x and w = fw ws x in
        let lk = ptype c.v p = link_code in
        let members t = let l = ref [ t ] in iter_in c Schema.p_same t (fun y -> l := y :: !l); !l in
        let asserted y w' = let id = find ws y p w' in if id >= 0 then now ws id = 1 else S.state c.v y p w' = 1 in
        match
          List.find_map (fun y -> List.find_map (fun w' -> if (y <> e || w' <> w) && asserted y w' then Some (y, w') else None) (if lk then members w else [ w ])) (members e)
        with
        | Some (y, w') ->
          let g = intern c y p w' in
          check c (d + 1) g;
          let ids = List.filter (fun i -> i >= 0) [ g; (if y <> e then intern c y Schema.p_same e else -1); (if w' <> w then intern c w' Schema.p_same w else -1) ] in
          List.iter (fun i -> check c (d + 1) i) ids;
          set_rule ws x (-2);
          set_by ws x (Array.of_list ids);
          prove c d x
        | None -> ()
      end
    end
  end

(* ---- the closure modules ---- *)

(* a fact a module derives, known absent from the state: into the working set, at the next round *)
let [@inline never] derive_new c ri e p w =
  check_frozen c p w;
  let ws = c.ws in
  let x = find ws e p w in
  let x = if x >= 0 then x else add ws e p w 0 in
  set_now ws x 2;
  set_round ws x (c.round + 1);
  set_rule ws x ri;
  count_derived c ri;
  push_next c x

(* or straight into the group's output, when nothing else in the group reads it (closure.m_side) *)
(* room for k more of them *)
let [@inline never] side_room c k =
  if c.ns + k > A.dim c.side_w then begin
    let cap = max (c.ns + k) (max 1024 (2 * A.dim c.side_w)) in
    let e = Bulk.i32 cap and p = Bulk.u16 cap and w = ints_raw cap in
    if c.ns > 0 then begin
      Bigarray.Array1.blit (Bigarray.Array1.sub c.side_e 0 c.ns) (Bigarray.Array1.sub e 0 c.ns);
      Bigarray.Array1.blit (Bigarray.Array1.sub c.side_p 0 c.ns) (Bigarray.Array1.sub p 0 c.ns);
      A.blit (A.sub c.side_w 0 c.ns) (A.sub w 0 c.ns)
    end;
    c.side_e <- e;
    c.side_p <- p;
    c.side_w <- w
  end

let [@inline never] derive_side c ri e p w =
  check_frozen c p w;
  side_room c 1;
  Bigarray.Array1.unsafe_set c.side_e c.ns (Int32.of_int e);
  Bigarray.Array1.unsafe_set c.side_p c.ns p;
  A.unsafe_set c.side_w c.ns w;
  c.ns <- c.ns + 1;
  count_derived c ri

(* the things that reach [a] through E, a among them ([with_start]) or only if a cycle leads back to it *)
let [@inline never] reach_back c (m : closure) a ~with_start (out : buf) =
  out.bn <- 0;
  iset_clear c.seen;
  if with_start then (ignore (iset_add c.seen a); buf_push out a);
  let i = ref 0 in
  let visit u = iter_in c m.m_e u (fun x -> if iset_add c.seen x then buf_push out x) in
  if not with_start then visit a;
  while !i < out.bn do
    let u = buf_get out !i in
    incr i;
    visit u
  done

(* a new edge (a, b): the new facts are the things that reach a (and a) times b and what b reaches through T, minus
   those present (the design's section 5.7) *)
let [@inline never] module_edge c (m : closure) a b =
  let src = c.buf_a and dst = c.buf_b and t = m.m_t in
  if m.m_base < 0 then (src.bn <- 0; buf_push src a; iter_in c t a (fun x -> buf_push src x))
  else reach_back c m a ~with_start:true src;
  dst.bn <- 0;
  buf_push dst b;
  iter_out c b t (fun z -> buf_push dst z);
  for i = 0 to src.bn - 1 do
    let x = buf_get src i in
    for j = 0 to dst.bn - 1 do
      let z = buf_get dst j in
      if not (present c x t z) then derive_new c m.m_rule x t z
    done
  done

(* linear: a new fact (c0, d) of T that the module did not derive: every thing that reaches c0 through E has d *)
let [@inline never] module_b c (m : closure) c0 d =
  let src = c.buf_a and t = m.m_t in
  reach_back c m c0 ~with_start:false src;
  for i = 0 to src.bn - 1 do
    let x = buf_get src i in
    if not (present c x t d) then derive_new c m.m_rule x t d
  done

(* Tarjan's strong components of a graph in compressed rows (off, adj) over n nodes: each node's component, and the
   components' members in the order they are found, which is a reverse topological order (a component comes after
   every component it reaches) *)
let [@inline never] components n (off : ints) (adj : ints) =
  let index = ints n (-1) and low = ints n 0 and comp = ints n (-1) in
  let stack = ints_raw (max 1 n) and cs_node = ints_raw (max 1 n) and cs_edge = ints_raw (max 1 n) in
  let members = ints_raw (max 1 n) and moff = buf_create 64 in
  let idx = ref 0 and sp = ref 0 and csp = ref 0 and nm = ref 0 and nc = ref 0 in
  let open_node u =
    A.unsafe_set index u !idx;
    A.unsafe_set low u !idx;
    incr idx;
    A.unsafe_set stack !sp u;
    incr sp;
    A.unsafe_set cs_node !csp u;
    A.unsafe_set cs_edge !csp (A.unsafe_get off u);
    incr csp
  in
  for s = 0 to n - 1 do
    if A.unsafe_get index s < 0 then begin
      open_node s;
      while !csp > 0 do
        let u = A.unsafe_get cs_node (!csp - 1) and ei = A.unsafe_get cs_edge (!csp - 1) in
        if ei < A.unsafe_get off (u + 1) then begin
          A.unsafe_set cs_edge (!csp - 1) (ei + 1);
          let w = A.unsafe_get adj ei in
          if A.unsafe_get index w < 0 then open_node w
          else if A.unsafe_get comp w < 0 then A.unsafe_set low u (min (A.unsafe_get low u) (A.unsafe_get index w))
        end
        else begin
          decr csp;
          if A.unsafe_get low u = A.unsafe_get index u then begin
            buf_push moff !nm;
            let fin = ref false in
            while not !fin do
              decr sp;
              let w = A.unsafe_get stack !sp in
              A.unsafe_set comp w !nc;
              A.unsafe_set members !nm w;
              incr nm;
              if w = u then fin := true
            done;
            incr nc
          end;
          if !csp > 0 then begin
            let p = A.unsafe_get cs_node (!csp - 1) in
            A.unsafe_set low p (min (A.unsafe_get low p) (A.unsafe_get low u))
          end
        end
      done
    end
  done;
  buf_push moff !nm;
  !nc, comp, members, moff

(* compressed rows of n nodes from k pairs (src, dst) *)
let [@inline never] rows n k (src : ints) (dst : ints) =
  let off = ints (n + 1) 0 in
  for i = 0 to k - 1 do let s = A.unsafe_get src i in A.unsafe_set off (s + 1) (A.unsafe_get off (s + 1) + 1) done;
  for u = 0 to n - 1 do A.unsafe_set off (u + 1) (A.unsafe_get off (u + 1) + A.unsafe_get off u) done;
  (* each edge at its source's next place, the places then moved back by one source *)
  let adj = ints_raw (max 1 k) in
  for i = 0 to k - 1 do
    let s = A.unsafe_get src i in
    let j = A.unsafe_get off s in
    A.unsafe_set off s (j + 1);
    A.unsafe_set adj j (A.unsafe_get dst i)
  done;
  for u = n downto 1 do A.unsafe_set off u (A.unsafe_get off (u - 1)) done;
  A.unsafe_set off 0 0;
  off, adj

(* The module from scratch, at its first work in a group whose state before held none of its closure's facts (or
   when its rules are new): every fact of T present now is an input (an edge of prp-trp; a fact of B for the linear
   form), and the closure is computed over the strong components in reverse topological order, each component's
   targets the union of its successors' (Nuutila 1995; the prototype's "children's closures reused"): each target
   tried once a successor, each new fact found once a source, no hash test. A fact present already is an input
   fact, skipped by a mark. The budget is checked as the targets grow, before their facts are made. *)
let[@inline never] count_many c ri k =
  if k > 0 then begin
    c.derived <- c.derived + k - 1;
    c.per_rule.(ri) <- c.per_rule.(ri) + k - 1;
    count_derived c ri
  end

let [@inline never] batch c mi =
  let m = c.prog.modules.(mi) in
  let trp = m.m_base < 0 in
  let tt0 = Unix.gettimeofday () in
  let lap name = if !trace then Printf.printf "    [batch %s %.4f]\n%!" name (Unix.gettimeofday () -. tt0) in
  (* the facts counted first, for buffers of their size *)
  let count p = let k = ref 0 in iter_all c p (fun _ _ -> incr k); !k in
  let ke = count m.m_e and kb = if trp then 0 else count m.m_t in
  let es = buf_create ke and ed = buf_create ke and bs = buf_create kb and bd = buf_create kb in
  iter_all c m.m_e (fun e w -> buf_push es e; buf_push ed w);
  if not trp then iter_all c m.m_t (fun e w -> buf_push bs e; buf_push bd w);
  let ne = es.bn and nb = bs.bn in
  incr batches;
  if ne + nb > 0 then begin
    (* dense ids: an array over the things' range when they lie close together (things are given ids in order), else
       a hash *)
    let lo = ref max_int and hi = ref min_int in
    let span (q : buf) = for i = 0 to q.bn - 1 do let x = A.unsafe_get q.b i in if x < !lo then lo := x; if x > !hi then hi := x done in
    span es; span ed; span bs; span bd;
    let dense = !hi - !lo < (4 * (ne + nb)) + 1024 in
    let things = buf_create (if dense then 1 else 2 * (ne + nb)) in
    let base = if dense then !lo else 0 in
    (if dense then begin
       (* a thing's id is its offset from the lowest: in the things' order *)
       let localize (q : buf) = for i = 0 to q.bn - 1 do A.unsafe_set q.b i (A.unsafe_get q.b i - base) done in
       localize es; localize ed; localize bs; localize bd
     end
     else begin
       let ids = imap_create (2 * (ne + nb)) in
       let localize (q : buf) =
         for i = 0 to q.bn - 1 do
           let x = A.unsafe_get q.b i in
           let l = imap_id ids x in
           if l = things.bn then buf_push things x;
           A.unsafe_set q.b i l
         done
       in
       localize es; localize ed; localize bs; localize bd
     end);
    let n = if dense then !hi - !lo + 1 else things.bn in
    lap "collected, ids";
    (* a forest drawn from its roots (each thing one edge at most, to an older thing; no fact of B): each thing's
       targets are the things above it, walked up, with no array of targets at all (a hierarchy, an org chart) *)
    let forest =
      dense && nb = 0 && m.m_side
      && (match c.prog.spec with Some s -> not (m.m_t < Bytes.length s.frozen && Bytes.get s.frozen m.m_t <> '\000') | None -> true)
      &&
      let up = ints n (-1) in
      let ok = ref true and i = ref 0 in
      while !ok && !i < ne do
        let a = A.unsafe_get es.b !i and b = A.unsafe_get ed.b !i in
        if b >= a || A.unsafe_get up a >= 0 then ok := false else A.unsafe_set up a b;
        incr i
      done;
      !ok
      && begin
        (* depths from the roots down (a parent is older), then every thing's ancestors *)
        let depth = ints_raw n and total = ref 0 in
        for u = 0 to n - 1 do
          let p = A.unsafe_get up u in
          let d = if p < 0 then 0 else A.unsafe_get depth p + 1 in
          A.unsafe_set depth u d;
          total := !total + d
        done;
        (* prp-trp's edges are present already: the first step up is an input *)
        let skip = if trp then 1 else 0 in
        let u_out = !total - (if trp then ne else 0) in
        if c.derived + u_out > c.limit then count_many c m.m_rule (c.limit - c.derived + 1);
        side_room c u_out;
        let se = c.side_e and sp = c.side_p and sw = c.side_w and t = m.m_t in
        let ns = ref c.ns in
        for u = 0 to n - 1 do
          let e32 = Int32.of_int (base + u) in
          let z = ref (A.unsafe_get up u) and k = ref 0 in
          while !z >= 0 do
            if !k >= skip then begin
              Bigarray.Array1.unsafe_set se !ns e32;
              Bigarray.Array1.unsafe_set sp !ns t;
              A.unsafe_set sw !ns (base + !z);
              incr ns
            end;
            incr k;
            z := A.unsafe_get up !z
          done
        done;
        count_many c m.m_rule (!ns - c.ns);
        c.ns <- !ns;
        lap "forest";
        true
      end
    in
    if not forest then begin
    let off, adj = rows n ne es.b ed.b in
    let boff, badj = if nb = 0 then ints (n + 1) 0, ints 1 0 else rows n nb bs.b bd.b in
    lap "rows";
    (* every edge from a thing to an older one (a hierarchy whose things were made from the top, a DAG so drawn): the
       things' order is a topological one, each thing its own component; else Tarjan's components *)
    let ordered =
      dense
      &&
      let ok = ref true and i = ref 0 in
      while !ok && !i < ne do (if A.unsafe_get ed.b !i >= A.unsafe_get es.b !i then ok := false); incr i done;
      !ok
    in
    let nc, comp, members, moff =
      if ordered then begin
        let id = ints_raw (n + 1) in
        for u = 0 to n do A.unsafe_set id u u done;
        n, id, id, id
      end
      else (let nc, comp, members, moff = components n off adj in nc, comp, members, moff.b)
    in
    lap "components";
    (* each component's targets: through E its successors and their targets (T over E is closed), and its own
       members when it holds a cycle; for the linear form, its members' facts of B too *)
    let mark = ints (max 1 n) (-1) and toff = ints (nc + 1) 0 in
    let tb = ref (ints_raw ((8 * ne) + nb + 1024)) and tn = ref 0 in
    let reserve k =
      if !tn + k > A.dim !tb then begin
        let b = ints_raw (max (!tn + k) (2 * A.dim !tb)) in
        A.blit (A.sub !tb 0 !tn) (A.sub b 0 !tn);
        tb := b
      end
    in
    let room = c.limit - c.derived + ne + nb in
    let cyc = Bytes.make (max 1 nc) '\000' in
    for k = 0 to nc - 1 do
      A.unsafe_set toff k !tn;
      let cyclic = ref false in
      let m0 = A.unsafe_get moff k in
      let u0 = A.unsafe_get members m0 in
      let e0 = A.unsafe_get off u0 in
      if A.unsafe_get moff (k + 1) = m0 + 1 && A.unsafe_get off (u0 + 1) = e0 + 1 && A.unsafe_get boff (u0 + 1) = A.unsafe_get boff u0
         && (let kw = A.unsafe_get comp (A.unsafe_get adj e0) in kw <> k && Bytes.unsafe_get cyc kw = '\000')
      then begin
        (* one thing, one edge, to a component without a cycle: its targets are the edge's end and that one's, which
           cannot hold it twice: copied at once *)
        let w = A.unsafe_get adj e0 in
        let kw = A.unsafe_get comp w in
        let a = A.unsafe_get toff kw and b = A.unsafe_get toff (kw + 1) in
        reserve (b - a + 1);
        let t = !tb in
        A.unsafe_set t !tn w;
        let d = !tn + 1 - a in
        for i = a to b - 1 do A.unsafe_set t (i + d) (A.unsafe_get t i) done;
        tn := !tn + 1 + (b - a)
      end
      else
      for i = A.unsafe_get moff k to A.unsafe_get moff (k + 1) - 1 do
        let u = A.unsafe_get members i in
        let b0 = A.unsafe_get boff u and b1 = A.unsafe_get boff (u + 1) in
        reserve (b1 - b0);
        let t = !tb in
        for j = b0 to b1 - 1 do
          let z = A.unsafe_get badj j in
          if A.unsafe_get mark z <> k then (A.unsafe_set mark z k; A.unsafe_set t !tn z; incr tn)
        done;
        for j = A.unsafe_get off u to A.unsafe_get off (u + 1) - 1 do
          let w = A.unsafe_get adj j in
          let kw = A.unsafe_get comp w in
          if kw = k then cyclic := true
          else begin
            let a = A.unsafe_get toff kw and b = A.unsafe_get toff (kw + 1) in
            reserve (b - a + 1);
            let t = !tb in
            if A.unsafe_get mark w <> k then (A.unsafe_set mark w k; A.unsafe_set t !tn w; incr tn);
            for i = a to b - 1 do
              let z = A.unsafe_get t i in
              if A.unsafe_get mark z <> k then (A.unsafe_set mark z k; A.unsafe_set t !tn z; incr tn)
            done
          end
        done
      done;
      if !cyclic then begin
        Bytes.unsafe_set cyc k '\001';
        let m0 = A.unsafe_get moff k and m1 = A.unsafe_get moff (k + 1) in
        reserve (m1 - m0);
        let t = !tb in
        for i = m0 to m1 - 1 do
          let z = A.unsafe_get members i in
          if A.unsafe_get mark z <> k then (A.unsafe_set mark z k; A.unsafe_set t !tn z; incr tn)
        done
      end;
      (* past the budget already: refused before the facts are made *)
      if !tn > room then count_many c m.m_rule (c.limit - c.derived + 1)
    done;
    A.unsafe_set toff nc !tn;
    lap "targets";
    (* the facts: each source's targets, but those it has as inputs *)
    let inp = ints (max 1 n) (-1) and t = m.m_t and tt = !tb and th = things.b in
    let[@inline] thing z = if dense then base + z else A.unsafe_get th z in
    let frozen_t = match c.prog.spec with Some s -> t < Bytes.length s.frozen && Bytes.get s.frozen t <> '\000' | None -> false in
    (* the output's room at once: at most each source's targets *)
    if m.m_side && not frozen_t then begin
      let u = ref 0 in
      for k = 0 to nc - 1 do
        u := !u + ((A.unsafe_get moff (k + 1) - A.unsafe_get moff k) * (A.unsafe_get toff (k + 1) - A.unsafe_get toff k))
      done;
      side_room c !u
    end;
    for k = 0 to nc - 1 do
      let t0 = A.unsafe_get toff k and t1 = A.unsafe_get toff (k + 1) in
      for i = A.unsafe_get moff k to A.unsafe_get moff (k + 1) - 1 do
        let s = A.unsafe_get members i in
        (if trp then for j = A.unsafe_get off s to A.unsafe_get off (s + 1) - 1 do A.unsafe_set inp (A.unsafe_get adj j) s done
         else for j = A.unsafe_get boff s to A.unsafe_get boff (s + 1) - 1 do A.unsafe_set inp (A.unsafe_get badj j) s done);
        let e = thing s in
        if m.m_side && not frozen_t then begin
          (* straight into the group's output, its room made above *)
          let se = c.side_e and sp = c.side_p and sw = c.side_w and ns0 = c.ns in
          let ns = ref ns0 and e32 = Int32.of_int e in
          for j = t0 to t1 - 1 do
            let z = A.unsafe_get tt j in
            if A.unsafe_get inp z <> s then begin
              Bigarray.Array1.unsafe_set se !ns e32;
              Bigarray.Array1.unsafe_set sp !ns t;
              A.unsafe_set sw !ns (thing z);
              incr ns
            end
          done;
          c.ns <- !ns;
          count_many c m.m_rule (!ns - ns0)
        end
        else
          for j = t0 to t1 - 1 do
            let z = A.unsafe_get tt j in
            if A.unsafe_get inp z <> s then
              if m.m_side then derive_side c m.m_rule e t (thing z) else derive_new c m.m_rule e t (thing z)
          done
      done
    done;
    lap "facts"
    end
  end

(* a round's facts for module mi: the batch at its first work when it may, else each new edge (and, for the linear
   form, each new fact of T it did not derive) *)
let [@inline never] module_round c mi (d : ints) nd r =
  let m = c.prog.modules.(mi) and ws = c.ws in
  let relevant x =
    now ws x > 0 && round ws x = r
    &&
    let p = fp ws x and ri = rule ws x in
    if m.m_base < 0 then p = m.m_t && ri <> m.m_rule
    else p = m.m_e || (p = m.m_t && ri <> m.m_rule && ri <> m.m_base)
  in
  let any = ref false and i = ref 0 in
  while (not !any) && !i < nd do (if relevant (A.unsafe_get d !i) then any := true); incr i done;
  if !any && r > c.mbatch.(mi) then begin
    let t0 = Unix.gettimeofday () in
    if c.mbatch.(mi) = -1 && c.mfresh.(mi) then (batch c mi; c.mbatch.(mi) <- r)
    else begin
      if c.mbatch.(mi) = -1 then c.mbatch.(mi) <- -2;
      for i = 0 to nd - 1 do
        let x = A.unsafe_get d i in
        if relevant x then if fp ws x = m.m_e then module_edge c m (fe ws x) (fw ws x) else module_b c m (fe ws x) (fw ws x)
      done
    end;
    module_seconds := !module_seconds +. (Unix.gettimeofday () -. t0)
  end

(* semi-naive evaluation: [first] the [nf] facts of round 0, and facts of round 1 already waiting in the next
   round's list. The rounds' facts in two buffers taken in turn, out of the collector's sight *)
(* ---- equality: merges and their rewriting (the reasoner design, section 5.10; Motik, Nenov, Piro, Horrocks, AAAI
   2015) ---- *)

(* every fact now that names one of [ts] as its thing, or as its value under a link property ([cepheus/same]'s aside),
   once each: [f e p w state] (1 asserted, 2 only derived) *)
let [@inline never] facts_naming c (ts : (int, unit) Hashtbl.t) f =
  let ws = c.ws and v = c.v in
  let st e p w = let x = find ws e p w in if x >= 0 then now ws x else S.state v e p w in
  let links = List.filter (fun p -> p <> Schema.p_same && ptype v p = link_code) (List.init (Schema.count v.schema) Fun.id) in
  let seen = Hashtbl.create 16 in
  let once e p w s = if not (Hashtbl.mem seen (e, p, w)) then (Hashtbl.replace seen (e, p, w) (); f e p w s) in
  let ts_l = Hashtbl.fold (fun x () l -> x :: l) ts [] |> List.sort compare in
  List.iter
    (fun x ->
      if x < ws.fresh then begin
        S.iter_facts v x (fun p w -> if p <> Schema.p_same then (let s = st x p w in if s > 0 then once x p w s));
        List.iter (fun p -> S.iter_things v p x (fun e -> let s = st e p x in if s > 0 then once e p x s)) links
      end)
    ts_l;
  let n = ws.n in
  for y = 0 to n - 1 do
    if base ws y = 0 && now ws y > 0 then begin
      let e = fe ws y and p = fp ws y and w = fw ws y in
      if p <> Schema.p_same && (Hashtbl.mem ts e || (Hashtbl.mem ts w && ptype v p = link_code)) then once e p w (now ws y)
    end
  done

(* The equalities found in a round, applied at its end (so that no plan runs over a state that changes under it):
   classes merged, the smaller into the larger (union by size, Tarjan 1975: a thing changes class O(log n) times), the
   members of the smaller given [y cepheus/same r]; then every fact that names an old representative is rewritten onto
   the new one, at round [r]: a fact only derived moves (it goes, its rewriting comes), an asserted one stays where the
   program wrote it, and its rewriting comes beside it. Every fact counts against the budget, so a functional
   property that makes n things one costs n - 1 facts of cepheus/same and the moves of the smaller sides, never the
   n^2 facts of the axiomatised equality. *)
let [@inline never] apply_merges c round =
  let t0 = Unix.gettimeofday () in
  Fun.protect ~finally:(fun () -> merge_seconds := !merge_seconds +. (Unix.gettimeofday () -. t0)) @@ fun () ->
  let pend = List.rev c.pend in
  c.pend <- [];
  let ws = c.ws in
  let mem = Hashtbl.create 8 in
  (* a class's members, and their number *)
  let members x =
    match Hashtbl.find_opt mem x with
    | Some l -> l
    | None ->
      let l = ref [ x ] and n = ref 1 in
      iter_in c Schema.p_same x (fun y -> if rep_of c y = x then (l := y :: !l; incr n));
      Hashtbl.replace mem x (!l, !n);
      !l, !n
  in
  let losers = Hashtbl.create 8 and moved = ref [] in
  List.iter
    (fun (a, b, ri) ->
      let ra = rep_of c a and rb = rep_of c b in
      if ra <> rb then begin
        List.iter
          (fun t ->
            if t < Schema.first_thing then refuse "rule %s would make the property #%d the same as another thing: a property is the same as no other" (rule_name c ri) t;
            if Hashtbl.mem c.prog.cthings t then
              if c.prog.spec <> None then raise_notrace (Respec (-1, -1))
              else refuse "rule %s would make #%d the same as #%d, which a rule names: a thing the rules name keeps its own identity" (rule_name c ri) ra rb)
          [ ra; rb ];
        let ma, la = members ra and mb, lb = members rb in
        let r, x, mx, mr = if la > lb || (la = lb && ra < rb) then ra, rb, mb, ma else rb, ra, ma, mb in
        List.iter (fun y -> set_rep c y r; moved := (y, ri) :: !moved) mx;
        (* the smaller list copied: O(its size) a merge, O(n log n) in all (union by size) *)
        Hashtbl.replace mem r (List.rev_append mx mr, la + lb);
        Hashtbl.remove mem x;
        Hashtbl.replace losers x ri
      end)
    pend;
  if !moved <> [] then begin
    c.eqon <- true;
    (* the facts of cepheus/same: each member of a class merged into another names its new representative *)
    List.iter
      (fun (y, ri) ->
        let r = rep_of c y in
        let olds = ref [] in
        iter_out c y Schema.p_same (fun z -> if z <> r then olds := z :: !olds);
        List.iter (fun z -> let id = intern c y Schema.p_same z in if now ws id > 0 then (set_now ws id 0; count_derived c ri)) !olds;
        if y <> r then emit_fact c ri y Schema.p_same r round)
      (List.rev !moved);
    (* the facts of the old representatives, rewritten *)
    let ts = Hashtbl.create 8 in
    Hashtbl.iter (fun x _ -> Hashtbl.replace ts x ()) losers;
    let todo = ref [] in
    facts_naming c ts (fun e p w st -> todo := (e, p, w, st) :: !todo);
    List.iter
      (fun (e, p, w, st) ->
        let ri = match Hashtbl.find_opt losers e with Some ri -> ri | None -> Hashtbl.find losers w in
        let e' = rep_of c e and w' = if ptype c.v p = link_code then rep_of c w else w in
        if st = 2 then begin
          check_frozen c p w;
          let id = intern c e p w in
          if now ws id > 0 then (set_now ws id 0; count_derived c ri)
        end;
        emit_fact c ri e' p w' round)
      (List.rev !todo)
  end

let saturate ?(s = 0) c (first : ints) nf =
  let ws = c.ws in
  let ins = ins_s_d c s in
  let nm = Array.length c.prog.modules in
  let cur = ref first and ncur = ref nf and r = ref 0 in
  while !ncur > 0 || c.nn > 0 || c.pend <> [] do
    c.round <- !r;
    let d = !cur and nc = !ncur and rr = !r in
    let par =
      nc >= !par_min && par_ok c
      &&
      let k = 4 * !Bulk.threads in
      let ix = if c.prog.nstrata = 1 then c.prog.ix_ins else c.prog.ix_ins_s.(s) in
      par_phase c k
        (fun w m found ->
          let ins = make_disp w ix State found in
          for i = m * nc / k to ((m + 1) * nc / k) - 1 do
            let x = A.unsafe_get d i in
            if now ws x > 0 && round ws x = rr then run_all ins (fe ws x) (fp ws x) (fw ws x)
          done)
        (rr + 1)
    in
    if not par then
      if not c.prog.eq then
        for i = 0 to nc - 1 do
          let x = A.unsafe_get d i in
          if now ws x > 0 && round ws x = rr then run_all ins (fe ws x) (fp ws x) (fw ws x)
        done
      else
        (* with equality, the equalities a fact gives are applied before the next fact runs (as RDFox's
           fact-at-a-time rewriting does): the facts they make outdated start nothing, so a functional property with
           n values on one thing costs O(n) instances, not the n^2 pairs a round would enumerate *)
        for i = 0 to nc - 1 do
          let x = A.unsafe_get d i in
          if now ws x > 0 && round ws x = rr then run_all ins (fe ws x) (fp ws x) (fw ws x);
          if c.pend <> [] then apply_merges c (rr + 1)
        done;
    for mi = 0 to nm - 1 do if c.prog.strat.(c.prog.modules.(mi).m_rule) = s then module_round c mi d !ncur !r done;
    if c.pend <> [] then apply_merges c (rr + 1);
    (* this round's buffer takes the next round's facts *)
    let nx = c.next and nn = c.nn in
    c.next <- (if d != first then d else c.spare);
    c.spare <- nx;
    cur := nx;
    ncur := nn;
    c.nn <- 0;
    incr r
  done;
  c.round <- max_int

(* B/F over the candidates (ids in the working set): each one checked; one without a proof deleted, and the facts its
   instances give, still there, checked in turn *)
let [@inline never] on_lost c pl =
  (* an equality that lost an instance: its class is taken apart and derived again *)
  if pl.hp = Schema.p_same then c.boom <- rep_of c pl.he :: c.boom
  else
  (* a closure its module decides gives no candidate through its own rules *)
  if pl.hok && not (Bytes.length c.walked > 0 && pl.hp >= 0 && pl.hp < Bytes.length c.walked && Bytes.unsafe_get c.walked pl.hp <> '\000'
                    && c.prog.in_module.(pl.ri)) then begin
    let ws = c.ws in
    let h = find ws pl.he pl.hp pl.hw in
    if h >= 0 then (if now ws h > 0 && not (has ws h 4) then Queue.add h (queue_of c pl.ri))
    else
      (* one lookup: its state, present when above 0 *)
      let s = S.state c.v pl.he pl.hp pl.hw in
      if s > 0 then Queue.add (add ws pl.he pl.hp pl.hw s) (queue_of c pl.ri)
  end

(* the instances a deleted fact took away were instances before the group: their Nots are checked there *)
let lost_d c = match c.lost with Some d -> d | None -> let d = make_disp ~nmode:Before c c.prog.ix_lost State (on_lost c) in c.lost <- Some d; d

(* B/F's dispatch when closures were retracted by walks: their own rules aside (their facts are decided) *)
let lost_walk_d c =
  match c.lost_walk with Some d -> d | None -> let d = make_disp ~nmode:Before c c.prog.ix_lost_walk State (on_lost c) in c.lost_walk <- Some d; d

(* Retraction by walks (the design's section 5.7; Hu, Motik, Horrocks 2022), for a closure no other rule gives T or E
   to: its edges are the facts the group leaves asserted (prp-trp's T) or E's facts, so the group's retractions are
   all that change them. The sources whose targets may shrink are the retracted edges' and facts' ends and what
   reaches them; each walks again over the edges left, a thing it meets that reaches none of them keeping its targets
   whole (they cannot change), and what it held beyond its new targets goes: exactly the facts left without a path.
   Their losses reach the other rules as B/F's do; the facts of T decided so are proved, while present, for the rest
   of B/F. Returns the candidates B/F still decides. *)
let module_retract c f0 (cands : int list) =
  let ws = c.ws in
  let mods = c.prog.modules in
  if (not !walk_retract) || not (Array.exists (fun (m : closure) -> m.m_walk) mods) then cands
  else begin
    let decided = Hashtbl.create 16 in
    Array.iter
      (fun (m : closure) ->
        if m.m_walk then begin
          let t = m.m_t and trp = m.m_base < 0 in
          let gone x = has ws x 16 in
          let gone_e = List.filter (fun x -> gone x && fp ws x = m.m_e) cands in
          let gone_b = if trp then [] else List.filter (fun x -> gone x && fp ws x = t) cands in
          if gone_e <> [] || gone_b <> [] then begin
            if Bytes.length c.walked = 0 then c.walked <- Bytes.make c.prog.np '\000';
            Bytes.set c.walked t '\001';

            (* a thing's facts of T asserted after the group: read with their states (a fact the group touched, by its
               entry in the working set; one it added is in the view already) *)
            let asserted_out u f =
              S.iter_values_st c.v u t (fun w st ->
                  let x = if ws.n = 0 then -1 else find ws u t w in
                  if x >= 0 then (if base ws x = 1 && not (has ws x 16) then f w) else if st = 1 then f w)
            in
            let edge_out u f =
              if trp then asserted_out u f
              else iter_out c u m.m_e (fun w -> let x = find ws u m.m_e w in if x < 0 || not (has ws x 16) then f w)
            in
            let b_out u f = if not trp then asserted_out u f in
            (* the sources: the retracted edges' and facts' starts, and what reaches them *)
            let ids = Hashtbl.create 64 and of_id = buf_create 64 in
            let id x = if not (Hashtbl.mem ids x) then (Hashtbl.replace ids x of_id.bn; buf_push of_id x) in
            let back a =
              if trp then (id a; iter_in c t a id)
              else (reach_back c m a ~with_start:true c.buf_a; for i = 0 to c.buf_a.bn - 1 do id (buf_get c.buf_a i) done)
            in
            (* prp-trp: an edge (a, b) with another way from a to b, through an edge (a, w) left whose closure holds b and
               which reaches no retracted edge's start (so its way to b does not use one), changes nothing: every path
               through it goes the other way (only the edge itself stays, derived) *)
            let starts = List.map (fun x -> fe ws x) gone_e in
            let present_t e w = let x = find ws e t w in if x >= 0 then now ws x > 0 else in_view c t && e < ws.fresh && S.mem c.v e t w in
            let other_way x =
              let a = fe ws x and b = fw ws x and found = ref false in
              edge_out a (fun w ->
                  if (not !found) && w <> b && present_t w b && List.for_all (fun a' -> w <> a' && not (present_t w a')) starts
                  then found := true);
              !found
            in
            let effective = if trp then List.filter (fun x -> not (other_way x)) gone_e else gone_e in
            (* what can be lost: the facts toward the retracted edges' ends and what those reach, and the retracted
               facts' values (a source's other targets do not go through them) *)
            let down = iset_create () and down_l = buf_create 64 in
            let add_down z = if iset_add down z then buf_push down_l z in
            List.iter (fun x -> let b = fw ws x in add_down b; iter_out c b t add_down) effective;
            List.iter (fun x -> add_down (fw ws x)) gone_b;
            let in_down z = iset_mem down z in
            List.iter (fun x -> back (fe ws x)) effective;
            List.iter (fun x -> back (fe ws x)) gone_b;
            let n = of_id.bn in
            let thing i = buf_get of_id i in
            let local x = match Hashtbl.find_opt ids x with Some i -> i | None -> -1 in
            (* their edges: to a source (the graph to order), or out of them (whose targets stay: read once) *)
            let es = buf_create 64 and ed = buf_create 64 and out_src = buf_create 64 and out_w = buf_create 64 in
            let bs = buf_create 16 and bd = buf_create 16 in
            for u = 0 to n - 1 do
              edge_out (thing u) (fun w ->
                  let l = local w in
                  if l >= 0 then (buf_push es u; buf_push ed l) else (buf_push out_src u; buf_push out_w w));
              b_out (thing u) (fun d -> buf_push bs u; buf_push bd d)
            done;
            let off, adj = rows n es.bn es.b ed.b in
            let ooff, oadj = rows n out_src.bn out_src.b out_w.b in
            let boff, badj = rows n bs.bn bs.b bd.b in
            let nc, comp, members, moff = components n off adj in
            let moff = moff.b in
            (* the targets that stay, of a thing out of the sources: its closure, read once *)
            let kept = Hashtbl.create 64 and kb = buf_create 256 in
            let kept_of w =
              match Hashtbl.find_opt kept w with
              | Some r -> r
              | None ->
                let a = kb.bn in
                (* its targets among those that can be lost: by its facts or by the few, whichever is less *)
                if S.count_values c.v w t <= 4 * down_l.bn then iter_out c w t (fun z -> if in_down z then buf_push kb z)
                else for i = 0 to down_l.bn - 1 do let z = buf_get down_l i in if present_t w z then buf_push kb z done;
                let r = (a, kb.bn) in
                Hashtbl.replace kept w r;
                r
            in
            (* each component's new targets, its successors first (as a closure from scratch, things by their ids) *)
            let toff = ints (nc + 1) 0 and tb = buf_create 1024 and mark = iset_create () in
            for k = 0 to nc - 1 do
              A.unsafe_set toff k tb.bn;
              iset_clear mark;
              let add z = if in_down z && iset_add mark z then buf_push tb z in
              let cyclic = ref false in
              for i = A.unsafe_get moff k to A.unsafe_get moff (k + 1) - 1 do
                let u = A.unsafe_get members i in
                for j = A.unsafe_get boff u to A.unsafe_get boff (u + 1) - 1 do add (A.unsafe_get badj j) done;
                for j = A.unsafe_get off u to A.unsafe_get off (u + 1) - 1 do
                  let w = A.unsafe_get adj j in
                  let kw = A.unsafe_get comp w in
                  if kw = k then cyclic := true
                  else begin
                    add (thing w);
                    for i = A.unsafe_get toff kw to A.unsafe_get toff (kw + 1) - 1 do add (buf_get tb i) done
                  end
                done;
                for j = A.unsafe_get ooff u to A.unsafe_get ooff (u + 1) - 1 do
                  let w = A.unsafe_get oadj j in
                  add w;
                  let a, b = kept_of w in
                  for i = a to b - 1 do add (buf_get kb i) done
                done
              done;
              (* new targets are old ones (edges only go): no more than the closure held *)
              if !cyclic then for i = A.unsafe_get moff k to A.unsafe_get moff (k + 1) - 1 do add (thing (A.unsafe_get members i)) done
            done;
            A.unsafe_set toff nc tb.bn;
            (* what each source held beyond its new targets goes *)
            for u = 0 to n - 1 do
              let x = thing u and k = A.unsafe_get comp u in
              iset_clear mark;
              for i = A.unsafe_get toff k to A.unsafe_get toff (k + 1) - 1 do ignore (iset_add mark (buf_get tb i)) done;
              let lost = ref [] in
              iter_out c x t (fun z -> if in_down z && iset_add mark z then lost := z :: !lost);
              List.iter
                (fun z ->
                  let y = intern c x t z in
                  if base ws y <> 1 || has ws y 16 then begin
                    set_mark ws y 4;
                    let was = now ws y in
                    set_now ws y 2;
                    run_all f0 x t z;
                    set_now ws y 0;
                    if was > 0 then count_derived c (-1)
                  end)
                !lost
            done;
            (* the retracted facts of T: decided (gone, or kept as derived) *)
            List.iter (fun x -> if fp ws x = t then Hashtbl.replace decided x ()) (gone_e @ gone_b)
          end
        end)
      mods;
    List.filter (fun x -> not (Hashtbl.mem decided x)) cands
  end

(* B/F for stratum [s] (Motik, Nenov, Piro, Horrocks 2019 for stratified rules: the strata in order, the lower ones
   complete): its queue holds the candidates the lower strata's deletions and Nots gave it *)
(* Retraction with equality, Delete-Rederive for a class (Gupta, Mumick, Subrahmanian 1993, applied to the classes;
   the reasoner design, section 5.10): a class whose facts may have lost a proof (an equality lost an instance, a fact
   naming it lost a derivation or was retracted) is taken apart: each member its own representative again, every fact
   only derived that names the representative deleted (the instances it gave lose it, B/F's way), and the asserted
   facts of every member are round 0 of the insertion that follows, which derives again the equalities that still
   hold and rewrites their facts. Rewriting keeps one fact for the derivations of every member, so a finer test (B/F
   on equalities, Motik et al., IJCAI 2015) is left for later; this one is exact. *)
let [@inline never] explode c f0 r =
  if (not (Hashtbl.mem c.exploded r)) && rep_of c r = r then begin
    Hashtbl.replace c.exploded r ();
    let ws = c.ws in
    let ms = ref [] in
    iter_in c Schema.p_same r (fun y -> if rep_of c y = r then ms := y :: !ms);
    List.iter
      (fun y ->
        let id = intern c y Schema.p_same r in
        if now ws id > 0 then (set_now ws id 0; set_mark ws id 4; count_derived c (-1));
        set_rep c y y)
      !ms;
    let ts = Hashtbl.create 8 in
    Hashtbl.replace ts r ();
    let gone = ref [] in
    facts_naming c ts (fun e p w st -> if st = 2 then gone := intern c e p w :: !gone);
    List.iter
      (fun x ->
        if not (has ws x 4) then begin
          check_frozen c (fp ws x) (fw ws x);
          set_mark ws x 4;
          set_now ws x 2;
          run_all f0 (fe ws x) (fp ws x) (fw ws x);
          set_now ws x 0;
          count_derived c (-1)
        end)
      !gone;
    List.iter (fun y -> Hashtbl.replace ts y ()) !ms;
    facts_naming c ts (fun e p w st -> if st = 1 then c.refill <- intern c e p w :: c.refill)
  end

let [@inline never] backward_forward c s (cands : int list) =
  let ws = c.ws and q = c.bfqs.(s) in
  plans c 0;
  let f0 = lost_d c in
  c.round <- max_int;
  let cands = if s = 0 then module_retract c (lost_walk_d c) cands else cands in
  let f0 = if Bytes.length c.walked > 0 then lost_walk_d c else f0 in
  List.iter (fun x -> Queue.add x q) cands;
  let booms () = while c.boom <> [] do let r = List.hd c.boom in c.boom <- List.tl c.boom; explode c f0 r done in
  booms ();
  while not (Queue.is_empty q) || c.boom <> [] do
    booms ();
    if not (Queue.is_empty q) then
    let x = Queue.pop q in
    check_frozen c (fp ws x) (fw ws x);
    (* a fact of a class of several things: its class is taken apart first (it is deleted there if only derived) *)
    let cl = if c.eqon && base ws x <> 1 && now ws x = 2 then class_named c x else -1 in
    if cl >= 0 then (c.boom <- cl :: c.boom; booms ());
    if not (has ws x 4) then begin
      check c 0 x;
      if not (has ws x 2) then begin
        set_mark ws x 4;
        (* the instances that lose a derivation: over the state before x goes (the facts deleted before it aside),
           so that x may fill several atoms of one instance *)
        let was = now ws x in
        set_now ws x 2;
        run_all f0 (fe ws x) (fp ws x) (fw ws x);
        set_now ws x 0;
        if was > 0 then count_derived c (-1)
      end
    end
  done;
  (* an asserted retraction proved stays, only derived *)
  for x = 0 to ws.n - 1 do
    if has ws x 2 && now ws x = 0 then set_now ws x 2
  done;
  (* marks of B/F cleared (the proved table too): the insertion that follows reads states only *)
  for x = 0 to ws.n - 1 do Bytes.unsafe_set ws.mark x (Char.unsafe_chr (Char.code (Bytes.unsafe_get ws.mark x) land 56)) done;
  reset c.pt

(* every instance of a rule (not necessarily the program's: a removed one) over the state *)
let [@inline never] instances c ?extra ri (f : plan -> unit) =
  let pl = compile c ?extra ri (-2) State f in
  c.round <- max_int;
  pl.run 0 0 0

(* ---- Not and aggregates, stratum by stratum ---- *)

(* the facts the group made present and absent so far: in the working set, now against before the group *)
let[@inline never] changed c =
  let ws = c.ws in
  let ins = ref [] and del = ref [] in
  for x = ws.n - 1 downto 0 do
    let o = old ws x > 0 and n = now ws x > 0 in
    if n && not o then ins := x :: !ins else if o && not n then del := x :: !del
  done;
  !ins, !del

(* every plan of rule [ri] whose matched pattern (from [first] on, below [upto]) may be the fact [x], run on it *)
let[@inline never] run_matched c ri x ~first ~upto source nsrc nmode =
  let ws = c.ws in
  let atoms = c.prog.natoms.(ri) and p = fp ws x in
  for j = first to upto - 1 do
    let a = Array.unsafe_get atoms j in
    if a.p = p || a.p < 0 then (xplan c ri j source nsrc nmode).run (fe ws x) p (fw ws x)
  done

(* Not flips for the ordinary rules of stratum [s] whose Nots read [x]: a fact made present that is a Nots' witness
   takes away the instances whose Not held before the group (B/F's candidates); a fact gone, for [emit]ting, gives the
   instances whose Not holds now *)
let[@inline never] flips c s (xs : int list) ~present (k : plan -> unit) =
  let prog = c.prog in
  c.xk <- k;
  c.round <- max_int;
  Array.iteri
    (fun ri (nots : Query.pattern array array) ->
      if nots <> [||] && prog.aggs.(ri) = None && (if s < 0 then prog.never.(ri) else (not prog.never.(ri)) && prog.strat.(ri) = s) then begin
        let nb = List.length prog.rules.(ri).where in
        let na = Array.length prog.natoms.(ri) in
        List.iter
          (fun x ->
            if present then run_matched c ri x ~first:nb ~upto:na State State Before
            else run_matched c ri x ~first:nb ~upto:na State Old Now)
          xs
      end)
    prog.nots

(* an exact sum of ints: hi * 2^61 + lo, lo in [0, 2^61) *)
let lo_mask = (1 lsl 61) - 1

type acc = {
  mutable hi : int;
  mutable lo : int;
  mutable cnt : int;  (* the answers, added less taken away *)
  mutable minus : int;  (* the answers taken away *)
  mutable amin : int;  (* the smallest and largest values added, and taken away *)
  mutable amax : int;
  mutable rmin : int;
  mutable rmax : int;
}

let new_acc () = { hi = 0; lo = 0; cnt = 0; minus = 0; amin = max_int; amax = min_int; rmin = max_int; rmax = min_int }

let add_sum a t =
  let lo = a.lo + (t land lo_mask) in
  if lo > lo_mask then (a.lo <- lo - lo_mask - 1; a.hi <- a.hi + 1 + (t asr 61)) else (a.lo <- lo; a.hi <- a.hi + (t asr 61))

let sub_sum a t =
  let lo = a.lo - (t land lo_mask) in
  if lo < 0 then (a.lo <- lo + lo_mask + 1; a.hi <- a.hi - 1 - (t asr 61)) else (a.lo <- lo; a.hi <- a.hi - (t asr 61))

let sum_value a = if a.hi >= -2 && a.hi <= 1 then Some ((a.hi lsl 61) + a.lo) else None

let agg_head c ri = match c.prog.rules.(ri).head with Rules.Give h -> h.p | Never -> invalid_arg "Reason.agg_head"

(* the aggregate's fact of group [k] goes, or comes: its consequences as any derived fact's *)
let[@inline never] agg_delete c ri k w =
  let ws = c.ws and p = agg_head c ri in
  let x = intern c k p w in
  check_frozen c p w;
  set_now ws x 2;
  c.round <- max_int;
  run_all (lost_d c) k p w;
  set_now ws x 0;
  count_derived c ri

let[@inline never] agg_insert c ri k w =
  let ws = c.ws and p = agg_head c ri in
  if k >= c.v.next_e then refuse "rule %s gives a fact about #%d, which does not exist" (rule_name c ri) k;
  check_frozen c p w;
  let x = intern c k p w in
  set_now ws x 2;
  set_rule ws x ri;
  set_round ws x 0;
  count_derived c ri

(* group [k]'s answers now, each sent to [f] (its value word): the head's thing bound *)
let group_answers c ri k (f : int -> unit) =
  c.xk <- (fun pl -> f pl.hw);
  c.round <- max_int;
  (xplan c ri (-3) State State Now).run k (agg_head c ri) 0

let[@inline never] group_value c ri k =
  let f = Option.get c.prog.aggs.(ri) in
  match f with
  | `Sum | `Count ->
    let a = new_acc () in
    group_answers c ri k (fun t -> a.cnt <- a.cnt + 1; add_sum a t);
    if a.cnt = 0 then None
    else if f = `Count then Some a.cnt
    else (match sum_value a with Some x -> Some x | None -> refuse "rule %s: the sum of #%d is past the largest int" (rule_name c ri) k)
  | `Min | `Max ->
    let best = ref None in
    group_answers c ri k (fun t -> best := Some (match !best with None -> t | Some b -> if f = `Min then min b t else max b t));
    !best

(* the value of an aggregate's group: [a] the change of its answers, [old] its fact's value before *)
let[@inline never] new_value c ri k (a : acc) old =
  let f = Option.get c.prog.aggs.(ri) in
  match f, old with
  | `Count, _ -> let n = Option.value old ~default:0 + a.cnt in if n > 0 then Some n else None
  | `Sum, _ ->
    (match old with Some w -> add_sum a w | None -> ());
    if a.minus > 0 && (try group_answers c ri k (fun _ -> raise_notrace Exit); true with Exit -> false) then None
    else (match sum_value a with Some x -> Some x | None -> refuse "rule %s: the sum of #%d is past the largest int" (rule_name c ri) k)
  | `Min, Some w when a.minus > 0 && a.rmin <= w -> group_value c ri k
  | `Max, Some w when a.minus > 0 && a.rmax >= w -> group_value c ri k
  (* no fact before and no answer added: none now (an answer added may be max_int, or min_int: amin and amax tell
     nothing alone) *)
  | (`Min | `Max), None when a.cnt + a.minus = 0 -> None
  | `Min, _ -> Some (min (Option.value old ~default:max_int) a.amin)
  | `Max, _ -> Some (max (Option.value old ~default:min_int) a.amax)

(* An aggregate kept up to date by difference (Sum and Count are linear: the change of the sum is the sum of the
   changes, DBSP's rule, Budiu et al. 2023): the answers its body gained and lost, found from the facts the group
   changed below it (by a positive pattern over the state now for a fact made present and over the state before for a
   fact gone; by a Not's pattern the other way round), each once by its facts. Min and Max read their group again
   when its extreme went, bounded by the group's size. A group without answers has no fact. *)
let[@inline never] aggregate_rule c ri (ins : int list) (del : int list) =
  let prog = c.prog and ws = c.ws in
  let nb = List.length prog.rules.(ri).where and na = Array.length prog.natoms.(ri) in
  let p = agg_head c ri in
  let reads x = let q = fp ws x in Array.exists (fun (a : Query.pattern) -> a.p = q || a.p < 0) prog.natoms.(ri) in
  let ins = List.filter reads ins and del = List.filter reads del in
  if ins <> [] || del <> [] then begin
    let groups : (int, acc) Hashtbl.t = Hashtbl.create 8 and seen : (int array, unit) Hashtbl.t = Hashtbl.create 16 in
    let instance plus (pl : plan) =
      let key = Array.make ((3 * nb) + 1) (if plus then 1 else 0) in
      for j = 0 to nb - 1 do
        key.(3 * j) <- pl.be.(j);
        key.((3 * j) + 1) <- pl.bp.(j);
        key.((3 * j) + 2) <- pl.bw.(j)
      done;
      if not (Hashtbl.mem seen key) then begin
        Hashtbl.replace seen key ();
        if Hashtbl.length seen > c.limit then
          refuse "rule %s: more than %d answers of its aggregate changed in one group" (rule_name c ri) c.limit;
        let a = match Hashtbl.find_opt groups pl.he with Some a -> a | None -> let a = new_acc () in Hashtbl.replace groups pl.he a; a in
        let t = pl.hw in
        if plus then (a.cnt <- a.cnt + 1; add_sum a t; if t < a.amin then a.amin <- t; if t > a.amax then a.amax <- t)
        else (a.cnt <- a.cnt - 1; a.minus <- a.minus + 1; sub_sum a t; if t < a.rmin then a.rmin <- t; if t > a.rmax then a.rmax <- t)
      end
    in
    c.round <- max_int;
    c.xk <- instance true;
    List.iter (fun x -> run_matched c ri x ~first:0 ~upto:nb State State Now) ins;
    List.iter (fun x -> run_matched c ri x ~first:nb ~upto:na State Old Now) del;
    c.xk <- instance false;
    List.iter (fun x -> run_matched c ri x ~first:0 ~upto:nb Old Old Before) del;
    List.iter (fun x -> run_matched c ri x ~first:nb ~upto:na Old State Before) ins;
    (* the groups in the order they came: the same changes on the database and its forks *)
    let order = Hashtbl.fold (fun k a l -> (k, a) :: l) groups [] |> List.sort (fun (a, _) (b, _) -> compare (a : int) b) in
    List.iter
      (fun (k, a) ->
        let old = ref None in
        iter_out c k p (fun w -> old := Some w);
        let nv = new_value c ri k a !old in
        if nv <> !old then begin
          (match !old with Some w -> agg_delete c ri k w | None -> ());
          match nv with Some w -> agg_insert c ri k w | None -> ()
        end)
      order
  end

(* an aggregate defined by the group: every group of its answers over the state, and its facts set to them *)
let[@inline never] aggregate_all c ri =
  let f = Option.get c.prog.aggs.(ri) and p = agg_head c ri in
  let groups : (int, acc) Hashtbl.t = Hashtbl.create 64 in
  c.round <- max_int;
  let pl = compile c ri (-2) State (fun pl ->
      let a = match Hashtbl.find_opt groups pl.he with
        | Some a -> a
        | None ->
          if Hashtbl.length groups >= c.limit then refuse "rule %s derived more than %d facts" (rule_name c ri) c.limit;
          let a = new_acc () in Hashtbl.replace groups pl.he a; a in
      let t = pl.hw in
      a.cnt <- a.cnt + 1; add_sum a t; if t < a.amin then a.amin <- t; if t > a.amax then a.amax <- t) in
  pl.run 0 0 0;
  let value k (a : acc) =
    match f with
    | `Count -> a.cnt
    | `Sum -> (match sum_value a with Some x -> x | None -> refuse "rule %s: the sum of #%d is past the largest int" (rule_name c ri) k)
    | `Min -> a.amin
    | `Max -> a.amax
  in
  let have = ref [] in
  iter_all c p (fun k w -> have := (k, w) :: !have);
  let kept = Hashtbl.create 64 in
  List.iter
    (fun (k, w) ->
      match Hashtbl.find_opt groups k with
      | Some a when value k a = w -> Hashtbl.replace kept k ()
      | _ -> agg_delete c ri k w)
    (List.sort compare !have);
  Hashtbl.fold (fun k a l -> (k, a) :: l) groups []
  |> List.sort (fun (a, _) (b, _) -> compare (a : int) b)
  |> List.iter (fun (k, a) -> if not (Hashtbl.mem kept k) then agg_insert c ri k (value k a))

let[@inline never] value_of (v : Store.view) p w =
  match Schema.find v.schema p with Some d -> S.value v d.typ w | None -> Value.Int w

let[@inline never] fact_text (v : Store.view) e p w =
  let name = match Schema.find v.schema p with Some d -> d.name | None -> string_of_int p in
  Printf.sprintf "[#%d %s %s]" e name (Value.to_string (value_of v p w))

(* The reasoning of one group: [v0] the state before it, [v] after its asserted changes [changes] (Resolve's, in
   order) and [words] their values' words in [v]. Returns the view with the derived changes applied, and the group's
   changes: the asserted ones (a retraction a rule still derives becomes Now_derived), then the derived ones. Raises
   [Refused]. The rules run unfolded on their small relations when the group changes none of those relations' facts;
   a group that does, or that would derive or delete one, is reasoned with the rules as written. *)
(* Does a group change the ontology: does it assert or retract a fact of a relation the rules are unfolded on in the
   state before it (spec_parts, without the relations groups were seen changing: so the answer depends on the rules
   and the state only, the same on a fork and in the database, whatever the unfolding did before). Rules with Not or
   aggregates run as written: none. Asked only of a group past a data write's budget. *)
let [@inline never] ontology (gen : program) (v0 : Store.view) (changes : Group.change array) (words : int array) =
  (not gen.stratified)
  &&
  match spec_parts v0 gen with
  | None -> false
  | Some (_, rels) ->
    let hit = ref false in
    Array.iteri (fun i (ch : Group.change) -> if Array.exists (fun (p, w) -> p = ch.p && (w < 0 || w = words.(i))) rels then hit := true) changes;
    !hit

(* [background]: a change raises [Background] (above). [limit]: the budget (a change's catch-up of a group gives its
   own); [stop]: a change's cancellation *)
let rec run ?background ?limit ?stop ~(v0 : Store.view) (v : Store.view) (changes : Group.change array) (words : int array) =
  let t0 = Unix.gettimeofday () in
  match run_ ?background ?limit ?stop ~v0 v changes words with
  | r -> seconds := !seconds +. (Unix.gettimeofday () -. t0); r
  | exception e -> seconds := !seconds +. (Unix.gettimeofday () -. t0); raise e

and run_ ?(background = false) ?limit ?(stop = never) ~(v0 : Store.view) (v : Store.view) (changes : Group.change array) (words : int array) =
  let same_key = Schema.rules_key v0.schema = Schema.rules_key v.schema in
  if same_key && not (Schema.has_rules v.schema) then v, changes
  else if background && not same_key then raise Background
  else begin
    let gen, spec = programs v in
    (* a write of a template's list changes the rules as written (their unfolding) *)
    let lists = same_key && Bytes.length gen.islist > 0 && Array.exists (fun (ch : Group.change) -> ch.p < Bytes.length gen.islist && Bytes.get gen.islist ch.p <> '\000') changes in
    (* the rules removed and added by this group, as unfolded: the old ones on the state before *)
    let removed, added_idx =
      if same_key && not lists then [], []
      else begin
        let old = List.map snd (written v0) in
        let removed = List.filter (fun r -> not (Array.exists (fun r' -> r' = r) gen.src)) old in
        let added = List.filter (fun i -> not (List.mem gen.src.(i) old)) (List.init (Array.length gen.src) Fun.id) in
        removed, added
      end
    in
    let same = same_key && removed = [] && added_idx = [] in
    if background && not same then raise Background;
    let prog =
      if not same then gen
      else
        choose v gen spec (fun s ->
            let l = ref [] in
            Array.iteri (fun i (ch : Group.change) -> if is_frozen s ch.p words.(i) then l := (ch.p, words.(i)) :: !l) changes;
            !l)
    in
    incr (if prog == gen then gen_groups else spec_groups);
    let go prog ~whole =
      match reason ?limit ~whole ~stop ~removed ~added_idx ~v0 v changes words prog same with
      | r -> r
      | exception Respec (fp, fw) -> incr respecs; unsettle v [ (fp, fw) ]; reason ?limit ~whole ~stop ~removed ~added_idx ~v0 v changes words gen same
    in
    match go prog ~whole:(not same) with
    | r -> r
    | exception Exceeded m ->
      (* past a data write's budget: a change of the ontology takes a change's, on the background path in the
         threaded writer, here again from the start otherwise *)
      if not (ontology gen v0 changes words) then raise (Refused m)
      else if background then raise Background
      else go gen ~whole:true
  end

and reason ?limit ~whole ~stop ~(removed : Rules.t list) ~(added_idx : int list) ~(v0 : Store.view) (v : Store.view) (changes : Group.change array) (words : int array) prog same =
    let reads p = if p < prog.np then Char.code (Bytes.unsafe_get prog.reads p) else 0 in
    (* an aggregate's property holds only what its rule gives: no write asserts it, under the rules after the group (a
       retraction of its fact, derived only, is refused before, by Resolve, with the same message; a retraction of an
       asserted fact is one of a property an aggregate defined in this group takes over, which Resolve checks holds
       none after it) *)
    if prog.stratified then
      Array.iter
        (fun (ch : Group.change) ->
          if ch.kind <> Retracted && ch.p >= 0 && ch.p < Array.length prog.agg_rule && Array.unsafe_get prog.agg_rule ch.p >= 0 then
            raise (Refused (agg_message v ch.p)))
        changes;
    (* nothing the rules read or give: nothing to do *)
    if same && Array.for_all (fun (ch : Group.change) -> reads ch.p = 0) changes then v, changes
    else
    with_ctx ~prog v (fun c ->
        let ws = c.ws in
        c.v0 <- v0;
        c.limit <-
          (match limit with
           | Some l -> l
           | None -> !budget_base + (!budget_per * Array.length changes) + if whole then !change_per * S.facts v0 else 0);
        c.whole <- whole;
        c.stop <- stop;
        Array.iteri (fun mi (m : closure) -> c.mfresh.(mi) <- S.count_prop v0 m.m_t = 0) prog.modules;
        (* the asserted changes the rules may read: round 0, or candidates of B/F *)
        let cands = ref [] and first = ref [] in
        (* first the state each fact is left in by the group's last change of it, which is its state in [v]: no lookup;
           its state before the group is the one its first change found *)
        Array.iteri
          (fun i (ch : Group.change) ->
            if reads ch.p <> 0 then begin
              let w = words.(i) and s = Group.after ch.kind in
              let x = find ws ch.e ch.p w in
              if x < 0 then begin
                let x = add ws ch.e ch.p w s in
                match ch.kind with
                | Added -> Bytes.unsafe_set ws.old x '\000'
                | Retracted -> Bytes.unsafe_set ws.old x '\001'
                | Now_asserted -> Bytes.unsafe_set ws.old x '\002'
                | _ -> ()
              end
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
                   once, the materialisation only once it is disproved); not when the group asserted it again after;
                   with strata, a fact no rule gives is gone at once (no lower stratum may see it present) *)
                if base ws x = 0 && not (has ws x 16) then begin
                  set_mark ws x 16;
                  set_now ws x (if prog.stratified && fact_stratum prog ch.p words.(i) < 0 then 0 else 2);
                  cands := x :: !cands
                end
              | Added when r land 1 <> 0 && base ws x = 1 && round ws x <> 0 ->
                (* a fact naming a thing that is not its representative: its rewriting is what the rules read *)
                if c.eqon && ((not (is_rep c ch.e)) || (ptype c.v ch.p = link_code && not (is_rep c words.(i)))) then
                  emit_fact c (-1) (rep_of c ch.e) ch.p (if ptype c.v ch.p = link_code then rep_of c words.(i) else words.(i)) 1
                else begin
                  set_round ws x 0;
                  first := x :: !first
                end
              | _ -> ()
            end)
          changes;
        (* the facts a removed rule gave: each loses a derivation; an aggregate's, every fact of its property *)
        List.iter
          (fun (r : Rules.t) ->
            (
              let sh = Rules.split r in
              match sh.pos.head with
              | Never -> ()
              | Give h when h.p = Schema.p_same ->
                (* a removed equality: the classes its instances made are derived again *)
                if c.eqon then instances c ~extra:r (-1) (fun pl -> c.boom <- rep_of c pl.he :: c.boom)
              | Give h when sh.agg <> None ->
                if Schema.find c.v.schema h.p <> None then iter_all c h.p (fun e w -> cands := intern c e h.p w :: !cands)
              | Give h ->
                (* a removed rule over properties that are gone has no instance *)
                if List.for_all (fun (a : Query.pattern) -> a.p < 0 || Schema.find c.v.schema a.p <> None) sh.pos.where
                   && (h.p < 0 || Schema.find c.v.schema h.p <> None)
                then
                  instances c ~extra:r (-1) (fun pl ->
                      if pl.hok then begin
                        let x = find ws pl.he pl.hp pl.hw in
                        if x >= 0 then cands := x :: !cands
                        else if S.state c.v pl.he pl.hp pl.hw = 2 then cands := add ws pl.he pl.hp pl.hw 2 :: !cands
                      end)))
          removed;
        let cands = List.rev !cands in
        (* with strata, a candidate no rule gives any more (a removed rule's) and not asserted is gone at once, as an
           asserted retraction of such a fact is: the strata's aggregates and Nots read it absent; B/F still takes its
           losses to the rules that read it *)
        if prog.stratified then
          List.iter
            (fun x -> if base ws x <> 1 && now ws x > 0 && fact_stratum prog (fp ws x) (fw ws x) < 0 then (set_now ws x 0; count_derived c (-1)))
            cands;
        (* the strata in order: each one's aggregates, its candidates (B/F), then its insertion (semi-naive); with one
           stratum and no Not and no aggregate, exactly the steps of the rules without them *)
        let ns = prog.nstrata in
        let in_stratum s x = ns = 1 || max 0 (fact_stratum prog (fp ws x) (fw ws x)) = s in
        for s = 0 to ns - 1 do
          c.cur <- s;
          let cands_s = if ns = 1 then cands else List.filter (in_stratum s) cands in
          if prog.stratified then begin
            let ins, del = changed c in
            Array.iteri
              (fun ri a -> if a <> None && prog.strat.(ri) = s then if List.mem ri added_idx then aggregate_all c ri else aggregate_rule c ri ins del)
              prog.aggs;
            flips c s ins ~present:true (on_lost c);
          end;
          if cands_s <> [] || (not (Queue.is_empty c.bfqs.(s))) || c.boom <> [] then backward_forward c s cands_s;
          (* an added rule: the facts it gives over the state, at round 1; the module of an added closure, from
             scratch *)
          let adding = List.filter (fun ri -> not (prog.never.(ri) || prog.in_module.(ri) || prog.aggs.(ri) <> None) && prog.strat.(ri) = s) added_idx in
          let adding = Array.of_list adding in
          if not (Array.length adding > 1 && S.facts v0 >= !par_min && par_ok c
                  && par_phase c (Array.length adding) (fun w m found -> instances w adding.(m) found) 1)
          then Array.iter (fun ri -> instances c ri (fun pl -> emit_at c pl 1)) adding;
          Array.iteri
            (fun mi (m : closure) ->
              if prog.strat.(m.m_rule) = s && (List.mem m.m_rule added_idx || (m.m_base >= 0 && List.mem m.m_base added_idx)) then begin
                c.round <- 0;
                let t0 = Unix.gettimeofday () in
                batch c mi;
                module_seconds := !module_seconds +. (Unix.gettimeofday () -. t0);
                c.mbatch.(mi) <- 0;
                c.round <- max_int
              end)
            prog.modules;
          (* round 0: the group's asserted additions; with strata, every fact the group made present so far (the
             lower strata's, this stratum's aggregates'), their rounds set to 0 *)
          (* the asserted facts of the classes taken apart: round 0 too *)
          List.iter (fun x -> if now ws x = 1 && round ws x <> 0 then (set_round ws x 0; first := x :: !first)) c.refill;
          c.refill <- [];
          let first =
            if not prog.stratified then List.rev !first
            else begin
              let l = ref [] in
              for x = ws.n - 1 downto 0 do
                if now ws x > 0 && old ws x = 0 then (set_round ws x 0; l := x :: !l)
              done;
              !l
            end
          in
          if prog.stratified then begin
            let _, del = changed c in
            flips c s del ~present:false (fun pl -> emit_at c pl 1)
          end;
          if first <> [] || c.nn > 0 then begin
            let n = List.length first in
            let a = ints (max 1 n) 0 in
            List.iteri (fun i x -> A.unsafe_set a i x) first;
            saturate ~s c a n
          end;
        done;
        c.cur <- -1;
        (* the constraints: an instance that involves a fact this group made present refuses it, or whose Not the
           group made true *)
        if Array.exists Fun.id prog.never then begin
          let violation pl =
            let r = prog.rules.(pl.ri) in
            refuse "constraint %s: %s" r.name
              (String.concat " " (List.init (List.length r.where) (fun j -> fact_text c.v pl.be.(j) pl.bp.(j) pl.bw.(j))))
          in
          let cons =
            match c.cons with
            | Some d -> d
            | None ->
              let d = make_disp c prog.ix_cons State violation in
              c.cons <- Some d;
              d
          in
          c.round <- max_int;
          for x = 0 to ws.n - 1 do
            if now ws x > 0 && (base ws x = 0 || round ws x = 0) then run_all cons (fe ws x) (fp ws x) (fw ws x)
          done;
          if prog.stratified then (let _, del = changed c in flips c (-1) del ~present:false violation);
          List.iter (fun ri -> if prog.never.(ri) then instances c ri violation) added_idx
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
        (* each fact's state in the view before ([base]) and after: the view's lookups are spared *)
        let cap = ws.n + c.ns in
        let es = Array.make cap 0 and ps = Array.make cap 0 and wv = Array.make cap 0 and ss = Array.make cap 0 and bs = Array.make cap 0 in
        let m = ref 0 in
        let todo e p w n b = let i = !m in es.(i) <- e; ps.(i) <- p; wv.(i) <- w; ss.(i) <- n; bs.(i) <- b; m := i + 1 in
        for x = 0 to ws.n - 1 do
          let b = base ws x and n = now ws x in
          if b <> n then begin
            let e = fe ws x and p = fp ws x and w = fw ws x in
            if has ws x 16 then (if n = 2 then todo e p w n b)
            else begin
              (* a template's list changes by writes only: its unfolding is the rules as written *)
              if p < Bytes.length prog.islist && Bytes.get prog.islist p <> '\000' then
                refuse "rule %s gives %s, the list of a template: only a write may change it"
                  (if rule ws x >= 0 then rule_name c (rule ws x) else "?") (match Schema.find c.v.schema p with Some d -> d.name | None -> string_of_int p);
              let kind = if n = 2 then Group.Derived else Group.Underived in
              out := { Group.kind; e; p; v = value_of c.v p w } :: !out;
              todo e p w n b
            end
          end
        done;
        let in_ws = List.length !out in
        for k = 0 to c.ns - 1 do
          let e = Int32.to_int (Bigarray.Array1.unsafe_get c.side_e k) and p = Bigarray.Array1.unsafe_get c.side_p k and w = A.unsafe_get c.side_w k in
          out := { Group.kind = Derived; e; p; v = value_of c.v p w } :: !out;
          todo e p w 2 0
        done;
        let derived = Array.of_list (List.rev !out) in
        let m = !m in
        let o = Store.fact_order es ps wv m in
        let v' =
          S.set_sorted ~olds:(Array.map (fun i -> bs.(i)) o) c.v (Array.map (fun i -> es.(i)) o) (Array.map (fun i -> ps.(i)) o) (Array.map (fun i -> wv.(i)) o)
            (Array.map (fun i -> ss.(i)) o) m
        in
        (* the schema's own rules over derived facts: one value for a one-valued property; a unique value once (a
           module's facts are of a property that takes many, none unique) *)
        Array.iteri
          (fun i (ch : Group.change) ->
            if i < in_ws && ch.kind = Group.Derived then
              match Schema.find v'.schema ch.p with
              | Some d ->
                let x = match S.word v' ch.v with Some w -> find ws ch.e ch.p w | None -> -1 in
                let rn = if x >= 0 && rule ws x >= 0 then rule_name c (rule ws x) else "?" in
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

(* The chains the insertion's plans read, by property (an index selection: Subotic et al., PVLDB 2018, choose the
   indexes from the searches the plans make): each plan's steps in the order it will be compiled with (order_of),
   the variables bound as compile binds them; a step with the thing known and the value not reads the chain by
   (property, thing), the other way round the one by (property, value), neither side the one by property; both known,
   a lookup. A variable property's step may read any property; the closure modules read both chains of their
   relations. In a large group a derived fact joins only the chains its property needs: most of a load's derived
   facts (types, read only with both sides known) join none. *)
let [@inline never] chain_needs c (ixs : index list) =
  let prog = c.prog in
  let need = Bytes.make prog.np '\000' in
  let all = ref 0 in
  let add p b = if p < 0 then all := !all lor b else if p < prog.np then Bytes.set need p (Char.chr (Char.code (Bytes.get need p) lor b)) in
  Array.iter
    (fun (ri, pos) ->
      let r = prog.rules.(ri) in
      let atoms = prog.natoms.(ri) in
      let bound = Array.make (max 1 r.vars) false in
      let bind_t = function Query.Var x -> bound.(x) <- true | _ -> () in
      let bind (a : Query.pattern) = bind_t a.e; bind_t a.v; if a.p < 0 then bound.(Rules.pvar a.p) <- true in
      let known = function Query.Var x -> bound.(x) | _ -> true in
      if pos >= 0 then begin
        bind atoms.(pos);
        Array.iter
          (fun j ->
            let a = atoms.(j) in
            (match known a.e, known a.v with
             | true, true -> ()
             | true, false -> add a.p 1
             | false, true -> add a.p 2
             | false, false -> add a.p 4);
            bind a)
          (order_of c ri pos)
      end)
    (Array.concat (List.map (fun (ix : index) -> ix.slots) ixs));
  Array.iter (fun (m : closure) -> add m.m_e 7; add m.m_t 7) prog.modules;
  (* the constraints' Nots read their patterns' chains *)
  Array.iteri (fun ri never -> if never then Array.iter (Array.iter (fun (q : Query.pattern) -> add q.p 7)) prog.nots.(ri)) prog.never;
  (* a large group's checks of one-valued and unique properties read the derived facts' chains (bulk_checks) *)
  Array.iter
    (fun (r : Rules.t) ->
      match r.head with
      | Give h when h.p < 0 -> add h.p 3
      | Give h -> (match Schema.find c.v.schema h.p with Some d -> add h.p ((if d.many then 0 else 1) lor if d.unique then 2 else 0) | None -> ())
      | Never -> ())
    prog.rules;
  if !all <> 0 then Bytes.iteri (fun p ch -> Bytes.set need p (Char.chr (Char.code ch lor !all))) need;
  need

(* ---- a large group: its facts all new, the derived ones appended ----
   The group's facts (the view lacks them all) are the working set's round 0, as its sorted prefix (above); the rules
   run on them by rounds as on any group; the facts derived are returned in the order found, for the group's Bulk.
   [b]: the group's facts in both orders (Bulk.make); [first_new]: the group's first new thing. Raises [Refused] past
   the budget. [None] when the group must take the ordinary path: a constraint, or a rule whose head gives a one-valued
   or unique property (the checks of those are the ordinary path's). *)
let rec bulk ~(own : string -> int option) ~first_new (v : Store.view) (b : Bulk.t) =
  let n = b.n and gp = b.p and gw = b.w in
  let gen, spec = programs v in
  (* a write of a template's list is a change of the rules: the ordinary path *)
  if Array.exists (fun (p, _) -> p + 1 < Array.length b.poff && b.poff.(p + 1) > b.poff.(p)) gen.lists then None else
  let prog =
    choose v gen spec (fun s ->
        (* a fact of each relation touched: one a property frozen whole, one a value frozen *)
        let l = ref [] and whole = Bytes.make (Bytes.length s.frozen) '\000' and some = Hashtbl.create 8 in
        for i = 0 to n - 1 do
          let fp = Bigarray.Array1.unsafe_get gp i and fw = Bigarray.Array1.unsafe_get gw i in
          if is_frozen s fp fw then
            if Bytes.unsafe_get s.frozen fp = '\001' then (if Bytes.unsafe_get whole fp = '\000' then (Bytes.unsafe_set whole fp '\001'; l := (fp, fw) :: !l))
            else if not (Hashtbl.mem some (fp, fw)) then (Hashtbl.replace some (fp, fw) (); l := (fp, fw) :: !l)
        done;
        !l)
  in
  incr (if prog == gen then gen_groups else spec_groups);
  (* past the budget: the ordinary path decides (a change of the ontology takes a change's budget there) *)
  match bulk_with ~own ~first_new prog v b with
  | r -> r
  | exception Exceeded m -> raise (Refused m)
  | exception Respec (fp, fw) -> (
    incr respecs;
    unsettle v [ (fp, fw) ];
    match bulk_with ~own ~first_new gen v b with r -> r | exception Exceeded m -> raise (Refused m))

(* the prefix of [ws]: the facts of [b] whose property [keep] says, in the order by thing, at round 0; the offsets of
   the things from [first_new] on; the membership table *)
and[@inline never] fill_prefix ws (b : Bulk.t) ~first_new ~next_e (keep : Bytes.t) =
  let n = b.n in
  let kept p = p < Bytes.length keep && Bytes.unsafe_get keep p <> '\000' in
  (* the rows kept by each chunk of the order by thing, then each chunk's facts at their place *)
  let nch = Bulk.chunks n and ch = !Bulk.chunk in
  let cnt = Array.make (nch + 1) 0 in
  Bulk.parallel ~d:!Bulk.threads nch (fun k ->
      let c = ref 0 in
      for r = k * ch to min n ((k + 1) * ch) - 1 do if kept (Bulk.prop b (Bulk.row b r)) then incr c done;
      cnt.(k + 1) <- !c);
  for k = 1 to nch do cnt.(k) <- cnt.(k) + cnt.(k - 1) done;
  let nb = cnt.(nch) in
  Bulk.parallel ~d:!Bulk.threads nch (fun k ->
      let x = ref cnt.(k) in
      for r = k * ch to min n ((k + 1) * ch) - 1 do
        let i = Bulk.row b r in
        let p = Bulk.prop b i in
        if kept p then begin
          let y = !x in
          set_f ws y (Bulk.thing b i) p (Bulk.word b i);
          x := y + 1
        end
      done;
      let lo = cnt.(k) and len = cnt.(k + 1) - cnt.(k) in
      if len > 0 then begin
        (* present, asserted, absent from the view and before the group, round 0, and already "chained" (mark 8):
           never put in a chain *)
        Bytes.fill ws.now lo len '\001';
        Bytes.fill ws.base lo len '\000';
        Bytes.fill ws.old lo len '\000';
        Bytes.fill ws.mark lo len '\008';
        A.fill (A.sub ws.round lo len) 0;
        A.fill (A.sub ws.rule lo len) (-1)
      end);
  ws.n <- nb;
  ws.nb <- nb;
  ws.bk <- b;
  ws.b_has <- keep;
  (* the facts of things older than the group first (the order is by thing): found by binary search; the new things'
     ranges by offsets *)
  let old = ref 0 in
  (let l = ref 0 and h = ref nb in
   while !l < !h do let m = (!l + !h) lsr 1 in if fe ws m < first_new then l := m + 1 else h := m done;
   old := !l);
  ws.b_old <- !old;
  ws.b_lo <- first_new;
  ws.fresh <- first_new;
  let things = max 0 (next_e - first_new) in
  let off = Bulk.i32 (things + 1) in
  let x = ref !old in
  for k = 0 to things do
    while !x < nb && fe ws !x < first_new + k do incr x done;
    Bigarray.Array1.unsafe_set off k (Int32.of_int !x)
  done;
  ws.b_off <- off;
  place_prefix ws nb;
  nb

(* After a large group's fixpoint: does the state break no constraint, give no thing a second value of a one-valued
   property, nor a unique property's value to two things? The constraints' plans run from every fact the group made
   present (all of the working set's, and the closure modules' facts set aside), as the ordinary path runs them; the
   derived facts of one-valued and unique properties are counted with the group's and the view's. false: the ordinary
   path decides (and refuses, naming what it finds). *)
and[@inline never] bulk_checks c ~nb =
  let ws = c.ws and prog = c.prog and v = c.v in
  let ok = ref true in
  if Array.exists Fun.id prog.never then begin
    let cons = make_disp c prog.ix_cons State (fun _ -> raise_notrace Exit) in
    c.round <- max_int;
    (try
       for x = 0 to ws.n - 1 do if now ws x > 0 then run_all cons (fe ws x) (fp ws x) (fw ws x) done;
       for k = 0 to c.ns - 1 do
         run_all cons (Int32.to_int (Bigarray.Array1.unsafe_get c.side_e k)) (Bigarray.Array1.unsafe_get c.side_p k) (A.unsafe_get c.side_w k)
       done
     with Exit -> ok := false)
  end;
  (* the derived facts of one-valued or unique properties *)
  let kind p = match Schema.find v.schema p with Some d -> (if d.many then 0 else 1) lor (if d.unique then 2 else 0) | None -> 0 in
  let checked = Hashtbl.create 64 in
  let check e p w =
    let k = kind p in
    if k land 1 <> 0 && not (Hashtbl.mem checked (0, e, p)) then begin
      Hashtbl.replace checked (0, e, p) ();
      let cnt = ref 0 in
      if e < ws.fresh && in_view c p then cnt := S.count_values v e p;
      b_iter_e ws e p (fun _ -> incr cnt);
      let y = ref (idx_head ws.ie p e) in
      while !y >= 0 do (if fe ws !y = e && fp ws !y = p && now ws !y > 0 then incr cnt); y := idx_next ws.ie !y done;
      if !cnt > 1 then ok := false
    end;
    if k land 2 <> 0 && not (Hashtbl.mem checked (1, w, p)) then begin
      Hashtbl.replace checked (1, w, p) ();
      let cnt = ref 0 in
      if in_view c p then cnt := S.count_things v p w;
      b_iter_w ws p w (fun _ -> incr cnt);
      let y = ref (idx_head ws.iw p w) in
      while !y >= 0 do (if fw ws !y = w && fp ws !y = p && now ws !y > 0 then incr cnt); y := idx_next ws.iw !y done;
      if !cnt > 1 then ok := false
    end
  in
  for x = nb to ws.n - 1 do if !ok then check (fe ws x) (fp ws x) (fw ws x) done;
  (* a module's facts set aside, of a one-valued or unique property: the ordinary path counts them *)
  for k = 0 to c.ns - 1 do if kind (Bigarray.Array1.unsafe_get c.side_p k) <> 0 then ok := false done;
  !ok

and bulk_with ~own ~first_new prog (v : Store.view) (b : Bulk.t) =
  let n = b.n in
  (* with classes of equal things, the ordinary path (its merges rewrite facts of the view) *)
  if prog.eq then None else
  (* rules that derive without Not or aggregates; constraints (with Nots or not), and heads on one-valued or unique
     properties, checked after the fixpoint below (a group that breaks one goes to the ordinary path, which refuses it
     with its message). A group only adds facts: a constraint's Not can only become false, so the instances to check
     are those with a new fact among their positive patterns, as on the ordinary path *)
  if Array.exists Fun.id (Array.mapi (fun ri never -> (not never) && (prog.nots.(ri) <> [||] || prog.aggs.(ri) <> None)) prog.never) then None
  else
    let t0 = Unix.gettimeofday () in
    Fun.protect ~finally:(fun () -> seconds := !seconds +. (Unix.gettimeofday () -. t0)) @@ fun () ->
    (* the properties a rule reads or gives: their facts are the prefix *)
    let keep = Bytes.init (max 0 (min (Bytes.length prog.reads) (Array.length b.poff - 1))) (fun p -> if Bytes.get prog.reads p <> '\000' then '\001' else '\000') in
    let nb = ref 0 in
    for i = 0 to Bytes.length keep - 1 do
      if Bytes.unsafe_get keep i <> '\000' && i + 1 < Array.length b.poff then nb := !nb + b.poff.(i + 1) - b.poff.(i)
    done;
    (* a working set made at the size of the prefix and its consequences (LUBM derives 0.4 a fact); the chains hold the
       derived facts only *)
    with_ctx ~prog ~facts:((2 * !nb) + 64) ~keys:4096 v (fun c ->
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
        Array.iteri (fun mi (m : closure) -> c.mfresh.(mi) <- S.count_prop v m.m_t = 0) prog.modules;
        ws.with_ip <- prog.free_free;
        c.plain_derive <- true;
        ws.need <- chain_needs c [ prog.ix_ins; prog.ix_cons ];
        let nb = fill_prefix ws b ~first_new ~next_e:v.next_e keep in
        incr bulk_groups;
        let first = ints (max 1 nb) 0 in
        for x = 0 to nb - 1 do A.unsafe_set first x x done;
        bulk_index_seconds := !bulk_index_seconds +. (Unix.gettimeofday () -. t0);
        saturate c first nb;
        let nd = ws.n - nb in
        if not (bulk_checks c ~nb) then None
        else begin
          let total = nd + c.ns in
          let de = Bulk.i32 total and dp = Bulk.u16 total and dw = Bulk.ints total in
          for k = 0 to nd - 1 do
            let x = nb + k in
            Bigarray.Array1.unsafe_set de k (Int32.of_int (fe ws x));
            Bigarray.Array1.unsafe_set dp k (fp ws x);
            Bigarray.Array1.unsafe_set dw k (fw ws x)
          done;
          if c.ns > 0 then begin
            Bigarray.Array1.blit (Bigarray.Array1.sub c.side_e 0 c.ns) (Bigarray.Array1.sub de nd c.ns);
            Bigarray.Array1.blit (Bigarray.Array1.sub c.side_p 0 c.ns) (Bigarray.Array1.sub dp nd c.ns);
            Bigarray.Array1.blit (Bigarray.Array1.sub c.side_w 0 c.ns) (Bigarray.Array1.sub dw nd c.ns)
          end;
          Some (c.v, de, dp, dw, total)
        end)

(* by property: 1 a rule body reads it, 2 a rule head gives it; empty without rules *)
let reads (v : Store.view) =
  if not (Schema.has_rules v.schema) then Bytes.empty
  else match programs v with _, Some p -> p.reads | gen, None -> gen.reads

(* ---- where derived facts come from (for rights) ----
   The properties whose facts the derived facts of p can come from, through the rules, transitively: the bodies of the
   rules that give p, and of those that give their properties, and so on; [None] when one of them reads a property
   that is a variable (any property may be read, as the ontology's facts decide). On the rules as written, so that the
   answer changes only with the rules. A reader allowed some kinds only must read every kind of these to read p's
   derived facts without learning, through them, facts it may not read. *)
let [@inline never] sources (v : Store.view) p =
  if not (Schema.has_rules v.schema) then Some []
  else begin
    let prog = program v in
    let seen = Hashtbl.create 16 and out = Hashtbl.create 16 and any = ref false in
    let q = Queue.create () in
    Queue.add p q;
    Hashtbl.replace seen p ();
    (* with equality, every fact may be a rewriting: what the equalities read counts too *)
    if prog.eq && p <> Schema.p_same then (Queue.add Schema.p_same q; Hashtbl.replace seen Schema.p_same ());
    while (not !any) && not (Queue.is_empty q) do
      let x = Queue.pop q in
      (* a rule's Nots read their properties too: an absence tells of them *)
      Array.iteri
        (fun i (r : Rules.t) ->
          match r.head with
          | Give h when h.p = x || h.p < 0 ->
            Array.iter
              (fun (a : Query.pattern) ->
                if a.p < 0 then any := true
                else begin
                  Hashtbl.replace out a.p ();
                  if not (Hashtbl.mem seen a.p) then (Hashtbl.replace seen a.p (); Queue.add a.p q)
                end)
              prog.natoms.(i)
          | _ -> ())
        prog.rules
    done;
    (* a template's rules come from its list too (they are its unfolding): every list counts *)
    if Hashtbl.length out > 0 then Array.iter (fun (l, _) -> Hashtbl.replace out l ()) prog.lists;
    if !any then None else Some (List.sort compare (Hashtbl.fold (fun k () l -> k :: l) out []))
  end

(* The message of a refusal by the rules for a reader that may not see every fact: its rule's name, no fact (a
   constraint's instance, a derived fact's premises, a derived value may be of kinds it may not read); [None] for a
   message that is not the rules'. *)
let public_message m =
  let word_after prefix =
    let n = String.length prefix in
    if String.length m > n && String.sub m 0 n = prefix then
      let rest = String.sub m n (String.length m - n) in
      Some (match String.index_opt rest ' ' with Some i -> String.sub rest 0 i | None -> rest)
    else None
  in
  let strip name = if String.length name > 0 && name.[String.length name - 1] = ':' then String.sub name 0 (String.length name - 1) else name in
  match word_after "constraint " with
  | Some name -> Some (Printf.sprintf "constraint %s" (strip name))
  | None -> (
    match word_after "rule " with
    | Some name -> Some (Printf.sprintf "rule %s refused the group" (strip name))
    | None ->
      if String.length m > 0 && m.[0] = '[' then
        let key = " is derived by rule " in
        let k = String.length key in
        let rec find i = if i + k > String.length m then None else if String.sub m i k = key then Some (i + k) else find (i + 1) in
        match find 0 with
        | Some j ->
          let rest = String.sub m j (String.length m - j) in
          let name = match String.index_opt rest ' ' with Some i -> String.sub rest 0 i | None -> rest in
          Some (Printf.sprintf "the fact is derived by rule %s: retract its premises" name)
        | None -> Some "the fact is derived by a rule"
      else None)

(* ---- Why ---- *)

type proof =
  | Given of { e : int; p : int; v : Value.t }
  | By of { rule : string; e : int; p : int; v : Value.t; from : proof list }

(* a proof of (e p w) in view v, or None when it is not a fact: by the rules as written *)
let [@inline never] why (v : Store.view) e p w =
  match S.state v e p w with
  | 0 -> None
  | 1 -> Some (Given { e; p; v = value_of v p w })
  | _ ->
    with_ctx ~prog:(program v) v (fun c ->
        let ws = c.ws in
        c.why_mode <- true;
        let x = add ws e p w 2 in
        check c 0 x;
        let rec tree x =
          let e = fe ws x and p = fp ws x and w = fw ws x in
          if base ws x = 1 then Given { e; p; v = value_of v p w }
          else
            match rule ws x, by ws x with
            | ri, _ when ri >= 0 && c.prog.aggs.(ri) <> None ->
              (* an aggregate's fact: the facts of every answer of its group, each proved *)
              let nb = List.length c.prog.rules.(ri).where in
              let facts = ref [] and seen = Hashtbl.create 16 in
              c.xk <- (fun pl ->
                  for j = 0 to nb - 1 do
                    let y = intern c pl.be.(j) pl.bp.(j) pl.bw.(j) in
                    if not (Hashtbl.mem seen y) then (Hashtbl.replace seen y (); facts := y :: !facts)
                  done);
              c.round <- max_int;
              (xplan c ri (-3) State State Now).run e p 0;
              let ys = List.rev !facts in
              List.iter (fun y -> check c 0 y) ys;
              By { rule = rule_name c ri; e; p; v = value_of v p w; from = List.map tree ys }
            | ri, ids when ri >= 0 ->
              By { rule = rule_name c ri; e; p; v = value_of v p w; from = Array.to_list (Array.map tree ids) }
            | (-2 | -3), ids ->
              (* the rewriting of an equality: the asserted fact of a member, and the facts of the classes *)
              By { rule = "cepheus/same"; e; p; v = value_of v p w; from = Array.to_list (Array.map tree ids) }
            | _ -> failwith (Printf.sprintf "Reason.why: %s has no proof: the materialisation is wrong" (fact_text v e p w))
        in
        if has ws x 2 then Some (tree x)
        else failwith (Printf.sprintf "Reason.why: %s has no proof: the materialisation is wrong" (fact_text v e p w)))

(* the message of a retraction of a fact only derived (choice 10.4 of the design) *)
let [@inline never] derived_message (v : Store.view) e p w =
  let gen, _ = programs v in
  if p >= 0 && p < Array.length gen.agg_rule && gen.agg_rule.(p) >= 0 then agg_message v p
  else
  match (try why v e p w with Failure _ -> None) with
  | Some (By { rule; from; _ }) ->
    let leaf = function Given g -> (g.e, g.p, g.v) | By b -> (b.e, b.p, b.v) in
    let texts =
      List.map (fun f -> let e, p, x = leaf f in fact_text v e p (Option.value (S.word v x) ~default:0)) from
    in
    Printf.sprintf "%s is derived by rule %s from %s: retract one of those" (fact_text v e p w) rule (String.concat " and " texts)
  | _ -> Printf.sprintf "%s is derived by a rule" (fact_text v e p w)

(* the texts and floats a view's rules name: interned into the writer's dictionary before a change runs in the
   background, so that the background never interns a text of its own (Engine) *)
let [@inline never] constants (v : Store.view) =
  List.concat_map
    (fun (_, (name, text)) ->
      match Rules.of_text name text with
      | Error _ -> []
      | Ok r ->
        let term = function Query.Val x when is_text_const x -> [ x ] | _ -> [] in
        let pat (a : Query.pattern) = term a.e @ term a.v in
        List.concat_map pat r.where @ match r.head with Give h -> pat h | Never -> [])
    (Schema.rules v.schema)
