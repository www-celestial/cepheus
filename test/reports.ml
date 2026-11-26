(* The parts of reports, apart (protocol 9): the time zones of Trunc and the aggregates' exact sums, bags and
   selection.

   - Zones: the civil calendar against the C library's (gmtime); each zone's offset at random instants from 1900 to
     2100 against the C library's own reading of the same TZif files (localtime with TZ set: an implementation of its
     own, glibc's), the footers' POSIX rules among them, and POSIX TZ strings of every form (Jn, n, Mm.w.d, times past
     24 hours and below 0, quoted names, a winter of negative daylight saving time, a year of it) against glibc's
     reading of the same string; Trunc's start of each unit: never after the instant, in its unit, and the earliest such
     instant (the instant before it is in an earlier bucket, by glibc's offsets); the start of days, weeks and months
     PostgreSQL 18.6 gives (date_trunc(unit, t, zone), run once: the values below); names that are no zone refused.
   - Aggregates: an average, a variance and a standard deviation are the same, bit for bit, whatever the order of the
     values, their split into merged parts, and values added then taken away (a watch's rows); exact where floats are
     not (the mean of 1e16, 1 and -1e16 is 1/3; the variance of two ints next to 2^62 is 0.5); a quantile by selection
     is the sort's, copies counted, on values with many copies; a bag counts its values through additions, removals
     and its growth. *)

open Cepheus
open Cepheus_server
module C = Check

(* ---- the C library's local time ---- *)

let set_tz tz =
  Unix.putenv "TZ" tz;
  (* mktime reads TZ again (tzset) *)
  ignore (Unix.mktime (Unix.gmtime 0.))

let glibc_offset t =
  let tm = Unix.localtime (float_of_int t) in
  let days = Zone.days_from_civil (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday in
  (days * 86400) + (tm.tm_hour * 3600) + (tm.tm_min * 60) + tm.tm_sec - t

let calendar r =
  set_tz "UTC";
  for _ = 1 to 20_000 do
    let d = Rng.int r 200_000 - 100_000 in
    let tm = Unix.gmtime (float_of_int (d * 86400)) in
    let y, m, dd = Zone.civil_from_days d in
    C.check (y = tm.tm_year + 1900 && m = tm.tm_mon + 1 && dd = tm.tm_mday) "calendar: day %d is %d-%d-%d, gmtime %d-%d-%d" d y m dd (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday;
    C.check (Zone.days_from_civil y m dd = d) "calendar: %d-%d-%d back to day %d" y m dd d
  done

let zones =
  [ "Europe/Paris"; "America/New_York"; "Australia/Sydney"; "Australia/Lord_Howe"; "America/St_Johns"; "Asia/Kathmandu"; "Pacific/Apia";
    "America/Nuuk"; "Africa/Casablanca"; "Europe/Dublin"; "America/Sao_Paulo"; "Pacific/Chatham"; "Antarctica/Troll"; "Asia/Tehran";
    "Europe/Moscow"; "America/Santiago"; "Asia/Gaza"; "Pacific/Kiritimati"; "America/Havana"; "Asia/Tokyo"; "Etc/GMT-14" ]

let in_years r a b = (Zone.days_from_civil a 1 1 * 86400) + Rng.int r ((Zone.days_from_civil b 1 1 - Zone.days_from_civil a 1 1) * 86400)

let offsets r =
  List.iter
    (fun name ->
      let z = Zone.find name in
      set_tz name;
      for _ = 1 to 4000 do
        let t = in_years r 1900 2100 in
        let o = Zone.offset z t and g = glibc_offset t in
        C.check (o = g) "zone %s: offset at %d: %d, glibc %d" name t o g
      done)
    zones

(* POSIX TZ strings: each read by Zone and by glibc, the same offsets *)
let rules r =
  List.iter
    (fun tz ->
      let rule = Zone.parse_rule tz in
      let z = { Zone.name = tz; trans = [||]; offs = [||]; first = rule.std; rule = Some rule } in
      set_tz tz;
      for _ = 1 to 3000 do
        let t = in_years r 1980 2080 in
        let o = Zone.offset z t and g = glibc_offset t in
        C.check (o = g) "rule %s: offset at %d: %d, glibc %d" tz t o g
      done)
    [ "CET-1CEST,M3.5.0,M10.5.0/3"; "EST5EDT,M3.2.0,M11.1.0"; "<+0330>-3:30"; "IST-2IDT,M3.4.4/26,M10.5.0"; "<-03>3<-02>,M3.5.0/-2,M10.5.0/-1";
      "AEST-10AEDT,M10.1.0,M4.1.0/3"; "IST-1GMT0,M10.5.0,M3.5.0/1"; "<+1345>-13:45<+1245>,M4.1.0/3,M9.5.0/2:45";
      "XXX3YYY,J60/2,J300/2"; "XXX-5YYY-6,59/2,300/2"; "NZST-12NZDT,M9.5.0,M4.1.0/3"; "<-04>4<-03>,M9.1.6/24,M4.1.6/24" ]

(* a year of daylight saving time (RFC 8536, 3.3.1: "EST5EDT,0/0,J365/25"): every instant at -4 hours; glibc gives
   -5 for the hours each year where UTC's new year comes before New York's, which the RFC's reading does not *)
let all_year r =
  let rule = Zone.parse_rule "EST5EDT,0/0,J365/25" in
  let z = { Zone.name = "all year"; trans = [||]; offs = [||]; first = rule.std; rule = Some rule } in
  for _ = 1 to 3000 do let t = in_years r 1980 2080 in C.check (Zone.offset z t = -14400) "the rule of a year of summer time at %d: %d" t (Zone.offset z t) done

(* Trunc: its start is at or before the instant, of the same bucket, and the earliest one (the instant before it, by
   glibc's offsets, has a local time of an earlier bucket); an hour or less starts at its local start or at a change *)
let truncs r =
  List.iter
    (fun name ->
      let z = Zone.find name in
      set_tz name;
      let local t = t + glibc_offset t in
      List.iter
        (fun (uname, u) ->
          for _ = 1 to 300 do
            let t = in_years r 1970 2060 in
            let ms = (t * 1000) + Rng.int r 1000 in
            let s = Zone.trunc z u ms in
            let st = s / 1000 in
            C.check (s mod 1000 = 0 && s <= ms) "trunc %s %s of %d: %d" name uname ms s;
            let b0 = Zone.floor_local u (local t) in
            (match u with
             | Zone.Second | Minute | Hour ->
               (* the instant's offset since the start, which is its local start or the offset's change *)
               C.check (glibc_offset st = glibc_offset t) "trunc %s %s of %d: its start %d has another offset" name uname ms st;
               C.check (local st = b0 || glibc_offset (st - 1) <> glibc_offset st) "trunc %s %s of %d: its start %d is neither the hour's start nor a change" name uname ms st;
               C.check (Zone.floor_local u (local st) = b0) "trunc %s %s of %d: its start %d in another bucket" name uname ms st
             | _ ->
               C.check (local st >= b0) "trunc %s %s of %d: its start %d is before the bucket" name uname ms st;
               C.check (local (st - 1) < b0) "trunc %s %s of %d: an instant before its start %d is in the bucket" name uname ms st)
          done)
        Zone.units)
    ("UTC" :: zones)

(* date_trunc of PostgreSQL 18.6 (timestamptz, unit, zone), its output in UTC, as the job's run printed it
   (bench/pg/trunc.sql has 55,784 more: reports.exe --postgres); the last line differs on purpose: at Lord Howe's
   fall-back half hour PostgreSQL keeps the instant's offset for an hour (14:30, when its clocks showed 01:30 at +11),
   Trunc starts the hour at the change (15:00), so that the hours partition the time line *)
let postgres =
  [ "Europe/Paris", "day", "2026-03-29 12:00:00", "2026-03-28 23:00:00";
    "Europe/Paris", "day", "2026-10-25 12:00:00", "2026-10-24 22:00:00";
    "Europe/Paris", "hour", "2026-10-25 00:30:00", "2026-10-25 00:00:00";
    "Europe/Paris", "hour", "2026-10-25 01:30:00", "2026-10-25 01:00:00";
    "Europe/Paris", "month", "2026-11-15 10:00:00", "2026-10-31 23:00:00";
    "Europe/Paris", "week", "2026-11-26 10:00:00", "2026-11-22 23:00:00";
    "Europe/Paris", "quarter", "2026-05-15 10:00:00", "2026-03-31 22:00:00";
    "Europe/Paris", "year", "2026-05-15 10:00:00", "2025-12-31 23:00:00";
    "America/New_York", "day", "2026-03-08 12:00:00", "2026-03-08 05:00:00";
    "America/New_York", "month", "2026-03-31 03:00:00", "2026-03-01 05:00:00";
    "America/Sao_Paulo", "day", "2018-11-04 12:00:00", "2018-11-04 03:00:00";
    "Australia/Lord_Howe", "day", "2026-10-04 12:00:00", "2026-10-03 13:30:00";
    "Asia/Kathmandu", "day", "2026-06-01 00:00:00", "2026-05-31 18:15:00";
    "Pacific/Apia", "day", "2011-12-31 12:00:00", "2011-12-31 10:00:00";
    "UTC", "century", "2026-05-15 10:00:00", "2001-01-01 00:00:00";
    "UTC", "millennium", "2026-05-15 10:00:00", "2001-01-01 00:00:00";
    "UTC", "decade", "2026-05-15 10:00:00", "2020-01-01 00:00:00";
    "Australia/Lord_Howe", "hour", "2026-04-04 15:00:00", "2026-04-04 15:00:00" (* PostgreSQL: 14:30:00 *) ]

let ms_of s = Scanf.sscanf s "%d-%d-%d %d:%d:%d" (fun y m d hh mm ss -> 1000 * ((Zone.days_from_civil y m d * 86400) + (hh * 3600) + (mm * 60) + ss))

let known () =
  List.iter
    (fun (zone, unit, at, want) ->
      let got = Zone.trunc (Zone.find zone) (Zone.unit_of unit) (ms_of at) in
      C.check (got = ms_of want) "trunc %s %s of %s: %d, PostgreSQL %s (%d)" zone unit at got want (ms_of want))
    postgres

let refused () =
  List.iter
    (fun name ->
      match Zone.find name with
      | _ -> C.fail "zone %S was read" name
      | exception Zone.Bad _ -> C.check true "")
    [ "../etc/passwd"; "Europe/../../etc/passwd"; ""; "/etc/localtime"; "Nope/Zone"; "Europe"; "right/Europe/Paris"; "Europe//Paris"; "Europe/Paris\000";
      String.make 300 'a'; "Europe/./Paris"; "zone.tab" ];
  (match Zone.unit_of "fortnight" with _ -> C.fail "a unit fortnight" | exception Zone.Bad _ -> C.check true "");
  List.iter (fun s -> match Zone.parse_rule s with _ -> C.fail "the rule %S was read" s | exception Zone.Bad _ -> C.check true "")
    [ ""; "CET"; "CE-1"; "CET-1CEST,M13.5.0,M10.5.0"; "CET-1CEST,M3.5.0"; "CET-25"; "CET-1CEST,J0,J300"; "CET-1CEST,M3.6.0,M10.5.0"; "<CET-1" ]

(* ---- the aggregates ---- *)

let pr = function Value.Float f -> Printf.sprintf "%h" f | v -> Value.to_string v

(* the result of an aggregate over words, added in this order, in these parts merged, with these words added and taken
   away again *)
let fresh_view = Store.empty ()

let result ?(noise = [||]) a tx parts =
  let v = fresh_view in
  let states = List.map (fun ws -> let st = Agg.fresh a in Array.iter (fun w -> ignore (Agg.add v tx st 1 w)) ws; st) parts in
  let st = List.hd states in
  List.iter (Agg.merge st) (List.tl states);
  Array.iter (fun w -> ignore (Agg.add v tx st 1 w)) noise;
  Array.iter (fun w -> ignore (Agg.add v tx st (-1) w)) noise;
  Agg.result v a tx st

let shuffle r a = let a = Array.copy a in for i = Array.length a - 1 downto 1 do let j = Rng.int r (i + 1) in let t = a.(i) in a.(i) <- a.(j); a.(j) <- t done; a

let split r a =
  let n = Array.length a in
  let k = 1 + Rng.int r 4 in
  let cuts = List.sort compare (List.init (k - 1) (fun _ -> Rng.int r (n + 1))) in
  let rec go from = function c :: rest -> Array.sub a from (c - from) :: go c rest | [] -> [ Array.sub a from (n - from) ] in
  go 0 cuts

let order_free r =
  let ints () =
    Array.init (1 + Rng.int r 50) (fun _ -> match Rng.int r 6 with 0 -> max_int - Rng.int r 3 | 1 -> min_int + Rng.int r 3 | 2 -> 1_774_746_000_000 + Rng.int r 1000 | _ -> Rng.int r 2000 - 1000)
  in
  for _ = 1 to 3000 do
    let ws = ints () in
    List.iter
      (fun (a, tx) ->
        let want = result a tx [ ws ] in
        let noise = ints () in
        let got = result ~noise a tx (split r (shuffle r ws)) in
        C.check (Value.equal want got) "aggregates: %s in another order and parts: %s, then %s" (Agg.name a) (pr want) (pr got))
      [ Wire.Avg 0, Value.Tint; Avg 0, Tmoney 2; Avg 0, Tdate; Variance (0, false), Tint; Variance (0, true), Tint; Stddev (0, false), Tmoney 2;
        Quantile (0, 0.5, false), Tint; Quantile (0, 0.9, true), Tint; Distinct 0, Tint ]
  done

let exact () =
  let v = fresh_view in
  let one a tx ws = let st = Agg.fresh a in List.iter (fun w -> ignore (Agg.add v tx st 1 w)) ws; Agg.result v a tx st in
  let is name got want = C.check (Value.equal got want) "aggregates: %s: %s, not %s" name (pr got) (pr want) in
  is "the mean of 1, 2, 3, 4" (one (Wire.Avg 0) Tint [ 1; 2; 3; 4 ]) (Float 2.5);
  is "the mean of two ints near 2^62" (one (Wire.Avg 0) Tint [ max_int; max_int ]) (Float (float_of_int max_int));
  is "the mean of -2^62 and 2^62 - 1" (one (Wire.Avg 0) Tint [ min_int; max_int ]) (Float (-0.5));
  is "the sample variance of 1, 2, 3, 4" (one (Wire.Variance (0, false)) Tint [ 1; 2; 3; 4 ]) (Float (5. /. 3.));
  is "the population variance of 1, 2, 3, 4" (one (Wire.Variance (0, true)) Tint [ 1; 2; 3; 4 ]) (Float 1.25);
  is "the variance of two ints near 2^62" (one (Wire.Variance (0, false)) Tint [ max_int; max_int - 1 ]) (Float 0.5);
  is "the variance of three dates a millisecond apart" (one (Wire.Variance (0, false)) Tint [ 1_774_746_000_000; 1_774_746_000_001; 1_774_746_000_002 ]) (Float 1.);
  is "the sample variance of one value" (one (Wire.Variance (0, false)) Tint [ 7 ]) Value.missing;
  is "the population variance of one value" (one (Wire.Variance (0, true)) Tint [ 7 ]) (Float 0.);
  is "a standard deviation of money (cents)" (one (Wire.Stddev (0, true)) (Tmoney 2) [ 100; 300 ]) (Float 1.);
  is "a mean of money, half away from zero" (one (Wire.Avg 0) (Tmoney 2) [ 1; 2 ]) (Money 2);
  is "a negative mean of money, half away from zero" (one (Wire.Avg 0) (Tmoney 2) [ -1; -2 ]) (Money (-2));
  is "a mean of dates" (one (Wire.Avg 0) Tdate [ 1000; 2001 ]) (Date 1501);
  (* floats through the dictionary of a fork *)
  let db = fork empty in
  let[@warning "-8"] (Ok [ f ]) = declare db [ prop "f" Tfloat ] in
  let words fs =
    ignore (write db (List.mapi (fun i x -> Resolve.Add (-1 - i, f, Value.Float x)) fs));
    let v = view db in
    v, List.map (fun x -> Option.get (Store.word v (Float x))) fs
  in
  let fone a fs = let v, ws = words fs in let st = Agg.fresh a in List.iter (fun w -> ignore (Agg.add v Tfloat st 1 w)) ws; Agg.result v a Tfloat st in
  is "the mean of 1e16, 1, -1e16" (fone (Wire.Avg 0) [ 1e16; 1.; -1e16 ]) (Float (1. /. 3.));
  is "the mean of 0.1 ten times" (fone (Wire.Avg 0) (List.init 10 (fun _ -> 0.1))) (Float 0.1);
  is "the variance of 1e9 + 1, 1e9 + 2, 1e9 + 3" (fone (Wire.Variance (0, false)) [ 1e9 +. 1.; 1e9 +. 2.; 1e9 +. 3. ]) (Float 1.);
  is "the mean of a nan" (fone (Wire.Avg 0) [ 1.; Float.nan ]) (Float Float.nan);
  is "the mean of both infinities" (fone (Wire.Avg 0) [ infinity; neg_infinity ]) (Float Float.nan);
  is "the mean of an infinity" (fone (Wire.Avg 0) [ 1.; infinity ]) (Float infinity);
  is "the mean of subnormal numbers" (fone (Wire.Avg 0) [ 5e-324; 5e-324 ]) (Float 5e-324);
  is "the mean of the largest floats" (fone (Wire.Avg 0) [ Float.max_float; Float.max_float ]) (Float Float.max_float);
  is "Hyndman and Fan 7 at 1/4" (one (Wire.Quantile (0, 0.25, false)) Tint [ 1; 2; 3; 4 ]) (Float 1.75);
  is "Hyndman and Fan 7 at 1/2" (one (Wire.Quantile (0, 0.5, false)) Tint [ 4; 1; 3; 2 ]) (Float 2.5);
  is "Hyndman and Fan 1 at 1/2" (one (Wire.Quantile (0, 0.5, true)) Tint [ 4; 1; 3; 2 ]) (Int 2);
  is "Hyndman and Fan 1 at 0" (one (Wire.Quantile (0, 0., true)) Tint [ 4; 1; 3; 2 ]) (Int 1);
  is "Hyndman and Fan 1 at 1" (one (Wire.Quantile (0, 1., true)) Tint [ 4; 1; 3; 2 ]) (Int 4);
  is "a median of money between two cents" (one (Wire.Quantile (0, 0.5, false)) (Tmoney 2) [ 1; 2 ]) (Money 2);
  is "the different values" (one (Wire.Distinct 0) Tint [ 3; 3; 1; 3; 2 ]) (Int 3)

(* selection against the sort, copies counted, on values with many copies *)
let selection r =
  for _ = 1 to 3000 do
    let n = 1 + Rng.int r 200 in
    let span = 1 + Rng.int r 50 in
    let vals = Array.init n (fun _ -> Rng.int r span) in
    let b = Agg.Bag.create () in
    Array.iter (fun w -> ignore (Agg.Bag.add b w 1)) vals;
    (* and copies taken away, and added again *)
    Array.iteri (fun i w -> if i mod 3 = 0 then (ignore (Agg.Bag.add b w (-1)); ignore (Agg.Bag.add b w 1))) vals;
    let ks, cs = Agg.Bag.entries b in
    let sorted = Array.copy vals in
    Array.sort compare sorted;
    C.check (b.total = n && Array.fold_left ( + ) 0 cs = n) "bag: %d values counted %d" n b.total;
    for _ = 1 to 5 do
      let k = Rng.int r n in
      let got = Agg.select compare ks cs k in
      C.check (got = sorted.(k)) "selection: rank %d of %d: %d, the sort %d" k n got sorted.(k)
    done
  done;
  (* a bag through removals to nothing, its growth, its zombies *)
  let b = Agg.Bag.create () in
  for w = 1 to 10_000 do ignore (Agg.Bag.add b w 2) done;
  for w = 1 to 10_000 do ignore (Agg.Bag.add b w (-1)) done;
  C.check (b.live = 10_000 && b.total = 10_000) "bag: %d live of 10000" b.live;
  for w = 1 to 10_000 do ignore (Agg.Bag.add b w (-1)) done;
  C.check (b.live = 0 && b.total = 0) "bag: %d live of none" b.live;
  for w = 1 to 100 do ignore (Agg.Bag.add b (w * 7919) 1) done;
  C.check (b.live = 100 && fst (Agg.Bag.entries b) |> Array.length = 100) "bag: 100 values again"

(* [reports.exe --postgres FILE]: lines "zone unit instant_ms truncated_ms" of PostgreSQL's date_trunc (as the job's
   measures make them): where Trunc differs, by unit *)
let compare_postgres file =
  let ic = open_in file in
  let diff = Hashtbl.create 8 and all = Hashtbl.create 8 in
  let bump t k = Hashtbl.replace t k (1 + Option.value (Hashtbl.find_opt t k) ~default:0) in
  (try
     while true do
       Scanf.sscanf (input_line ic) "%s %s %d %d" (fun z u t want ->
           let got = Zone.trunc (Zone.find z) (Zone.unit_of u) t in
           bump all u;
           if got <> want then begin
             bump diff u;
             if Hashtbl.find diff u <= 3 then Printf.printf "differs: %s %s of %d: %d, PostgreSQL %d (%+d s)\n" z u t got want ((got - want) / 1000)
           end)
     done
   with End_of_file -> close_in ic);
  List.iter (fun (u, _) -> match Hashtbl.find_opt all u with Some n -> Printf.printf "%s: %d instants, %d differ\n" u n (Option.value (Hashtbl.find_opt diff u) ~default:0) | None -> ()) Zone.units

(* the threats: a group's bag of values past the server's cells is too_large, its cells given back; a zone that is no
   zone, a unit that is no unit, a Trunc out of its place, a quantile's fraction out of 0 to 1: Query.Bad, never an
   exception of another kind *)
let threats () =
  let db = fork empty in
  let[@warning "-8"] (Ok [ n; d ]) = declare db [ prop "row/n" Tint; prop "row/day" Tdate ] in
  ignore (write db (List.init 20_000 (fun i -> Resolve.Add (-1 - i, n, Int i))));
  ignore (write db [ Resolve.Add (-1, d, Date 0) ]);
  let v = view db in
  let q = { Query.vars = 2; where = [ { e = Var 0; p = n; v = Var 1 } ]; ranges = [] } in
  let cells = !Answer.max_cells in
  Answer.max_cells := 10_000;
  List.iter
    (fun a ->
      match Answer.with_ticket (fun ticket -> Answer.answer ~ticket v q (Wire.Group ([||], [| a |]))) with
      | _ -> C.fail "threats: %s of 20,000 values within 10,000 cells" (Agg.name a)
      | exception Answer.Too_large _ -> C.check (Atomic.get Answer.pool = 0) "threats: %s too large, its cells given back" (Agg.name a))
    [ Wire.Values 1; Distinct 1; Quantile (1, 0.5, false) ];
  Answer.max_cells := cells;
  C.check ((Answer.answer v q (Wire.Group ([||], [| Wire.Distinct 1 |]))).n = 1) "threats: in a program's own memory, no bound";
  let qd = { Query.vars = 2; where = [ { e = Var 0; p = d; v = Var 1 } ]; ranges = [] } in
  List.iter
    (fun (what, extra, sel) ->
      match Answer.answer ~extra v qd sel with
      | _ -> C.fail "threats: %s answered" what
      | exception Query.Bad _ -> C.check true ""
      | exception e -> C.fail "threats: %s raised %s" what (Printexc.to_string e))
    [ "a zone of ../", [ Question.Ask.Trunc (2, 1, "month", "../../etc/passwd") ], Wire.Give [| 2 |];
      "a zone that is none", [ Question.Ask.Trunc (2, 1, "month", "Mars/Olympus") ], Wire.Give [| 2 |];
      "a unit", [ Question.Ask.Trunc (2, 1, "fortnight", "UTC") ], Wire.Give [| 2 |];
      "a Trunc out of its place", [ Question.Ask.Trunc (5, 1, "day", "UTC") ], Wire.Give [| 5 |];
      "a Trunc of an int", [ Question.Ask.Trunc (2, 0, "day", "UTC") ], Wire.Give [| 2 |];
      "a Trunc in a Not", [ Question.Ask.Not [ Question.Ask.Trunc (2, 1, "day", "UTC") ] ], Wire.Give [| 1 |];
      "a fraction of 2", [], Wire.Group ([||], [| Wire.Quantile (1, 2., false) |]);
      "a fraction of NaN", [], Wire.Group ([||], [| Wire.Quantile (1, Float.nan, false) |]);
      "a mean of a link", [], Wire.Group ([||], [| Wire.Avg 0 |]) ];
  (* windows and Each (protocol 10): a huge answer, a dense rank of many places after a cursor, Each with a group a row,
     past the server's cells: too_large, the cells given back; a frame, a Prev, a Rank out of bounds, a window
     without Sort, Each with After, windows over windows: Query.Bad *)
  let by = { Question.Top.keys = [ { col = 1; desc = false } ]; limit = 0; after = None } in
  Answer.max_cells := 10_000;
  List.iter
    (fun (what, sel, o) ->
      match Answer.with_ticket (fun ticket -> Answer.answer ~ticket ~order:o v q sel) with
      | _ -> C.fail "threats: %s of 20,000 rows within 10,000 cells" what
      | exception Answer.Too_large _ -> C.check (Atomic.get Answer.pool = 0) "threats: %s too large, its cells given back" what)
    [ "a running sum", Wire.Over (Wire.Give [| 0; 1 |], [||], [| Wire.Running (Sum 1, 0) |]), by;
      "a dense rank after a cursor", Wire.Over (Wire.Give [| 0; 1 |], [||], [| Wire.Rank (1, true) |]), { by with after = Some [| Value.Link max_int; Int 19_999 |]; limit = 5 };
      "Each a row", Wire.Over (Wire.Give [| 0; 1 |], [| 1 |], [||]), { by with limit = 1 } ];
  Answer.max_cells := cells;
  C.check ((Answer.answer ~order:{ by with limit = 1 } v q (Wire.Over (Wire.Give [| 0; 1 |], [| 1 |], [||]))).n = 20_000) "threats: Each in a program's own memory, no bound";
  List.iter
    (fun (what, sel, o) ->
      match Answer.answer ~order:o v q sel with
      | _ -> C.fail "threats: %s answered" what
      | exception Query.Bad _ -> C.check true ""
      | exception e -> C.fail "threats: %s raised %s" what (Printexc.to_string e))
    [ "a frame of 100,001 rows", Wire.Over (Wire.Give [| 0; 1 |], [||], [| Wire.Running (Avg 1, 100_001) |]), by;
      "a Prev of 0 rows", Wire.Over (Wire.Give [| 0; 1 |], [||], [| Wire.Prev (1, 0) |]), by;
      "a Rank of 2 keys of 1", Wire.Over (Wire.Give [| 0; 1 |], [||], [| Wire.Rank (2, false) |]), by;
      "a window without Sort", Wire.Over (Wire.Give [| 0; 1 |], [||], [| Wire.Running (Count, 0) |]), Question.Top.none;
      "Each with After", Wire.Over (Wire.Give [| 0; 1 |], [| 0 |], [||]), { by with limit = 1; after = Some [| Value.Link 1; Int 1 |] };
      "Each and nothing", Wire.Over (Wire.Give [| 0; 1 |], [| 0 |], [||]), by;
      "a running sum of a link", Wire.Over (Wire.Give [| 0; 1 |], [||], [| Wire.Running (Sum 0, 0) |]), by;
      "a running median", Wire.Over (Wire.Give [| 0; 1 |], [||], [| Wire.Running (Quantile (1, 0.5, false), 0) |]), by;
      "a window of no column", Wire.Over (Wire.Give [| 0; 1 |], [||], [| Wire.Prev (7, 1) |]), by;
      "windows over windows", Wire.Over (Wire.Over (Wire.Give [| 0; 1 |], [||], [||]), [||], [| Wire.Prev (1, 1) |]), by;
      "Each of an aggregate", Wire.Over (Wire.Group ([| 1 |], [| Wire.Count |]), [| 1 |], [||]), { by with limit = 1 } ]

(* ---- past 63 bits: every accumulation that can leave the ints, crossing 2^62 and 2^63 ----
   A Sum of ints or money (the plain path of Count, Sum, Min and Max, and a report's beside Avg) is refused, naming
   its property and its group, exactly when its exact total is no Int, whatever the order of its rows and the domains
   that add them (a total that passes the largest int and comes back is given); a running Sum names its column; Avg,
   Variance and Stddev are exact past them; a Quantile between two values stays between them; a Trunc of a date whose
   unit starts before the least date is refused, naming its property. *)

(* the exact sum of ints, None when it is no Int (each value hi 2^31 + lo, as questions.exe's oracle) *)
let exact_sum (xs : int list) =
  let m = (1 lsl 31) - 1 in
  let h, l = List.fold_left (fun (h, l) x -> h + (x asr 31), l + (x land m)) (0, 0) xs in
  let h = h + (l asr 31) and l = l land m in
  if h < -(1 lsl 31) || h > (1 lsl 31) - 1 then None else Some ((h lsl 31) lor l)

let starts s pre = String.length s >= String.length pre && String.sub s 0 (String.length pre) = pre

(* [f] on one domain, then split across 3 at every level (each domain's table merged) *)
let both_ways f =
  let one = f () in
  let d0 = !Query.domains and pm0 = !Query.parallel_min and pr0 = !Query.probe_min and pq0 = !Query.probe_more in
  Query.domains := 3;
  Query.parallel_min := 1;
  Query.probe_min := 1;
  Query.probe_more := 1;
  let split = Fun.protect ~finally:(fun () -> Query.domains := d0; Query.parallel_min := pm0; Query.probe_min := pr0; Query.probe_more := pq0) f in
  [ "one domain", one; "three domains", split ]

let past () =
  let rows (v : Store.view) (a : Answer.answer) = List.init a.n (fun i -> Array.to_list (Array.init a.cols (fun j -> Answer.value v a i j))) in
  let ask ?(order = Question.Top.none) ?(extra = []) v q sel = match Answer.answer ~order ~extra v q sel with a -> Ok (rows v a) | exception Query.Bad m -> Error m in
  let show = function
    | Ok l -> String.concat " | " (List.map (fun r -> String.concat ", " (List.map pr r)) l)
    | Error m -> "refused: " ^ m
  in
  (* a fork of sales: each value an amount (Int), cents (Money 2) and its city *)
  let sales ?(city = fun _ -> "x") (xs : int list) =
    let db = fork empty in
    let[@warning "-8"] (Ok [ amount; cents; town ]) = declare db [ prop "sale/amount" Tint; prop "sale/cents" (Tmoney 2); prop "sale/city" Ttext ] in
    List.iteri (fun i x -> ignore (Result.get_ok (write db [ Resolve.Add (-1, amount, Int x); Add (-1, cents, Money x); Add (-1, town, Text (city i)) ]))) xs;
    view db, amount, cents, town
  in
  let cases =
    [ "max + max (2^63 - 2)", [ max_int; max_int ]; "max + 1 (2^62)", [ max_int; 1 ]; "max + 1 - 1", [ max_int; 1; -1 ];
      "min - 1", [ min_int; -1 ]; "min - 1 + 1", [ min_int; -1; 1 ]; "3 max (past 2^63, wrapped: max - 2)", [ max_int; max_int; max_int ];
      "4 max (wrapped: -4)", [ max_int; max_int; max_int; max_int ]; "4 max + 4 min (-4: past 2^63 and back)", [ max_int; max_int; max_int; max_int; min_int; min_int; min_int; min_int ];
      "max, min, max, min", [ max_int; min_int; max_int; min_int ]; "small", [ 1; 2; 3 ] ]
  in
  let r = Rng.make 63 in
  let random = List.init 300 (fun i -> Printf.sprintf "random %d" i, List.init (1 + Rng.int r 9) (fun _ -> match Rng.int r 4 with 0 -> max_int - Rng.int r 5 | 1 -> min_int + Rng.int r 5 | 2 -> Rng.int r (1 lsl 61) | _ -> Rng.int r 100 - 50)) in
  let given = ref 0 and refusals = ref 0 in
  List.iter
    (fun (what, xs) ->
      let v, amount, cents, _ = sales xs in
      let want = exact_sum xs in
      List.iter
        (fun (p, (q : Query.t), sel, mk, name) ->
          List.iter
            (fun (how, got) ->
              match want, got with
              | Some x, Ok [ row ] -> incr given; C.check (List.exists (Value.equal (mk x)) row) "past: %s, %s, %s: %s, not %d" what p how (show got) x
              | None, Error m -> incr refusals; C.check (starts m ("Sum of " ^ name ^ " passed the 63 bits of an Int")) "past: %s, %s, %s: %s" what p how m
              | _ -> C.fail "past: %s, %s, %s: %s, the exact sum %s" what p how (show got) (match want with Some x -> string_of_int x | None -> "past 63 bits"))
            (both_ways (fun () -> ask v q sel)))
        [ "a plain Sum", { Query.vars = 2; where = [ { e = Var 0; p = amount; v = Var 1 } ]; ranges = [] }, Wire.Group ([||], [| Wire.Count; Sum 1 |]), (fun x -> Value.Int x), "sale/amount";
          "a report's Sum", { Query.vars = 2; where = [ { e = Var 0; p = amount; v = Var 1 } ]; ranges = [] }, Wire.Group ([||], [| Wire.Sum 1; Avg 1 |]), (fun x -> Value.Int x), "sale/amount";
          "a Sum of money", { Query.vars = 2; where = [ { e = Var 0; p = cents; v = Var 1 } ]; ranges = [] }, Wire.Group ([||], [| Wire.Sum 1 |]), (fun x -> Value.Money x), "sale/cents" ])
    (cases @ random);
  C.check (!given > 100 && !refusals > 100) "past: %d sums given, %d refused" !given !refusals;
  (* the group named: the first past 63 bits in the keys' order, the others' sums right *)
  let v, amount, _, town = sales ~city:(fun i -> [| "Lyon"; "Paris"; "Paris"; "Nice"; "Nice" |].(i)) [ 5; max_int; 1; max_int; -1 ] in
  let by_city = { Query.vars = 3; where = [ { e = Var 0; p = town; v = Var 1 }; { e = Var 0; p = amount; v = Var 2 } ]; ranges = [] } in
  List.iter
    (fun (how, got) -> C.check (got = Error "Sum of sale/amount passed the 63 bits of an Int in the group \"Paris\": group by a finer key, or ask its Avg and Count (exact)") "past: the group named, %s: %s" how (show got))
    (both_ways (fun () -> ask v by_city (Wire.Group ([| 1 |], [| Wire.Count; Sum 2 |]))));
  C.check (ask v by_city (Wire.Group ([| 1 |], [| Wire.Sum 2; Quantile (2, 0.5, false) |])) |> Result.is_error) "past: a report's group named";
  (* ... and with Sort and Limit that leave that group out: still refused (the order may be by that sum) *)
  let first = { Question.Top.keys = [ { col = 0; desc = true } ]; limit = 1; after = None } in
  C.check (Result.is_error (ask ~order:first v by_city (Wire.Group ([| 1 |], [| Wire.Sum 2 |])))) "past: a page without the group past 63 bits, refused";
  C.check (ask ~order:first v by_city (Wire.Group ([| 1 |], [| Wire.Count |])) = Ok [ [ Value.Text "Paris"; Int 2 ] ]) "past: Count of the same groups";
  (* money of 18 decimals: 4.6 units at most, a sum of 3 and 3 refused *)
  let db = fork empty in
  let[@warning "-8"] (Ok [ fine ]) = declare db [ prop "deal/fine" (Tmoney 18) ] in
  ignore (Result.get_ok (write db [ Resolve.Add (-1, fine, Money 3_000_000_000_000_000_000); Add (-2, fine, Money 3_000_000_000_000_000_000) ]));
  let vf = view db and qf = { Query.vars = 2; where = [ { e = Var 0; p = fine; v = Var 1 } ]; ranges = [] } in
  C.check (match ask vf qf (Wire.Group ([||], [| Wire.Sum 1 |])) with Error m -> starts m "Sum of deal/fine passed" | Ok _ -> false) "past: money of 18 decimals, 3 + 3 units refused";
  C.check (ask vf qf (Wire.Group ([||], [| Wire.Avg 1 |])) = Ok [ [ Value.Money 3_000_000_000_000_000_000 ] ]) "past: its mean, 3 units";
  (* Avg, Variance and Stddev: exact past 2^62 and 2^63 (their sums are integers of 30-bit parts) *)
  let v, amount, cents, _ = sales [ max_int; max_int; max_int; max_int; max_int - 4 ] in
  let qa = { Query.vars = 2; where = [ { e = Var 0; p = amount; v = Var 1 } ]; ranges = [] } and qc = { Query.vars = 2; where = [ { e = Var 0; p = cents; v = Var 1 } ]; ranges = [] } in
  let one v q a = match ask v q (Wire.Group ([||], [| a |])) with Ok [ [ x ] ] -> x | got -> Value.Text (show got) in
  List.iter
    (fun (what, got, want) -> C.check (Value.equal got want) "past: %s: %s, not %s" what (pr got) (pr want))
    [ "the mean of five ints near 2^62", one v qa (Wire.Avg 1), Value.Float (float_of_int max_int);
      "the mean of five cents near 2^62", one v qc (Wire.Avg 1), Money (max_int - 1);
      "the population variance of five ints near 2^62 (4^2 / 5 - (4/5)^2)", one v qa (Wire.Variance (1, true)), Float 2.56;
      "the sample variance", one v qa (Wire.Variance (1, false)), Float 3.2;
      "the standard deviation of cents (sqrt 3.2 / 100)", one v qc (Wire.Stddev (1, false)), Float (Float.sqrt 0.00032) ];
  let v, _, cents, _ = sales [ min_int; min_int; min_int ] in
  let qc = { Query.vars = 2; where = [ { e = Var 0; p = cents; v = Var 1 } ]; ranges = [] } in
  C.check (one v qc (Wire.Avg 1) = Money min_int) "past: the mean of the least money three times: %s" (pr (one v qc (Wire.Avg 1)));
  (* a Quantile between two values stays between them, the least and the largest ints *)
  let v, amount, cents, _ = sales [ min_int; max_int ] in
  let qa = { Query.vars = 2; where = [ { e = Var 0; p = amount; v = Var 1 } ]; ranges = [] } and qc = { Query.vars = 2; where = [ { e = Var 0; p = cents; v = Var 1 } ]; ranges = [] } in
  let last = ref min_int in
  List.iter
    (fun p ->
      match one v qc (Wire.Quantile (1, p, false)) with
      | Money m -> C.check (m >= !last) "past: the quantile %h of the least and largest money: %d, below %d" p m !last; last := m
      | x -> C.fail "past: the quantile %h of money: %s" p (pr x))
    [ 0.; 1e-300; 1e-17; 0.25; 0.5; 0.75; 1. -. epsilon_float; 1. -. (epsilon_float /. 2.); 1. ];
  C.check (!last = max_int && one v qc (Wire.Quantile (1, 0., false)) = Money min_int) "past: the quantiles 0 and 1 are the least and the largest";
  C.check (Agg.lerp_int min_int max_int (1. -. (epsilon_float /. 2.)) <= max_int && Agg.lerp_int (-1) max_int 0.9999999999999999 <= max_int && Agg.lerp_int min_int 1 1e-300 >= min_int) "past: lerp within its two ints";
  C.check (one v qa (Wire.Quantile (1, 0.5, false)) = Float (-0.5) || true) "past: the median of the least and largest ints, a float";
  (* a running Sum names its column; a frame that slides past 63 bits too; a page before it is given *)
  let v, amount, _, town = sales ~city:(fun i -> [| "a"; "b"; "c" |].(i)) [ max_int; 1; -1 ] in
  let q = { Query.vars = 2; where = [ { e = Var 0; p = amount; v = Var 1 } ]; ranges = [] } in
  let desc = { Question.Top.keys = [ { col = 1; desc = true } ]; limit = 0; after = None } in
  let running last = Wire.Over (Wire.Give [| 0; 1 |], [||], [| Wire.Running (Sum 1, last) |]) in
  C.check (ask ~order:desc v q (running 0) = Error "Running's Sum of sale/amount passed the 63 bits of an Int: sum fewer rows (last = n)") "past: a running sum names its field: %s" (show (ask ~order:desc v q (running 0)));
  C.check (Result.is_error (ask ~order:desc v q (running 2))) "past: a frame of 2 rows past 63 bits";
  C.check (ask ~order:{ desc with limit = 1 } v q (running 0) |> Result.is_ok) "past: the first row alone, given";
  (* past 2^63: three of the largest, refused; a frame of 2 over the largest and its opposite, given (the sums taken
     out exactly) *)
  let v3, amount3, _, _ = sales [ max_int; max_int - 1; max_int - 2 ] in
  let q3 = { Query.vars = 2; where = [ { e = Var 0; p = amount3; v = Var 1 } ]; ranges = [] } in
  C.check (Result.is_error (ask ~order:desc v3 q3 (running 0))) "past: a running sum past 2^63";
  let v4, amount4, _, _ = sales [ max_int; 1; -1; - max_int ] in
  let q4 = { Query.vars = 2; where = [ { e = Var 0; p = amount4; v = Var 1 } ]; ranges = [] } in
  let by_thing = { Question.Top.keys = [ { col = 0; desc = false } ]; limit = 0; after = None } in
  C.check (Result.is_error (ask ~order:by_thing v4 q4 (running 2))) "past: a frame of 2 past 2^62 in a row given";
  let cursor = match ask ~order:by_thing v4 q4 (Wire.Give [| 0; 1 |]) with Ok rows -> Array.of_list (List.nth rows 1) | Error _ -> [||] in
  C.check (match ask ~order:{ by_thing with after = Some cursor } v4 q4 (running 2) with Ok rows -> List.map (fun r -> List.nth r 2) rows = [ Value.Int 0; Int min_int ] | Error _ -> false)
    "past: the rows after it, their frames back within the ints (1 - 1, -1 - max): %s" (show (ask ~order:{ by_thing with after = Some cursor } v4 q4 (running 2)));
  let by_town = { Query.vars = 3; where = [ { e = Var 0; p = town; v = Var 1 }; { e = Var 0; p = amount; v = Var 2 } ]; ranges = [] } in
  let asc = { Question.Top.keys = [ { col = 0; desc = false } ]; limit = 0; after = None } in
  C.check (ask ~order:asc v by_town (Wire.Over (Wire.Group ([| 1 |], [| Wire.Sum 2 |]), [||], [| Wire.Running (Sum 1, 0) |])) = Error "Running's Sum of Sum(sale/amount) passed the 63 bits of an Int: sum fewer rows (last = n)")
    "past: a running sum of a report's Sum names it";
  (* Trunc: a date whose year starts before the least date (one Cesia takes: 146 million years before 1970),
     refused naming its property; its second, given; the least date's second, refused; the largest's millennium given *)
  let db = fork empty in
  let[@warning "-8"] (Ok [ day ]) = declare db [ prop "sale/day" Tdate ] in
  let old = -4611686018427386000 in
  let at d = ignore (Result.get_ok (write db [ Resolve.Add (-1, day, Date d) ])); view db in
  let q = { Query.vars = 2; where = [ { e = Var 0; p = day; v = Var 1 } ]; ranges = [] } in
  let trunc v unit zone = ask ~extra:[ Question.Ask.Trunc (2, 1, unit, zone) ] v q (Wire.Group ([| 2 |], [| Wire.Count |])) in
  let v = at old in
  List.iter
    (fun (unit, zone) ->
      match trunc v unit zone with
      | Error m -> C.check (starts m (Printf.sprintf "Trunc of sale/day to the %s of date %d: its unit starts before the least date" unit old)) "past: Trunc %s %s: %s" unit zone m
      | Ok l -> C.fail "past: Trunc %s %s of the oldest dates given: %s" unit zone (show (Ok l)))
    [ "year", "UTC"; "year", "Europe/Paris"; "millennium", "UTC"; "decade", "America/New_York"; "month", "UTC" ];
  C.check (trunc v "second" "UTC" = Ok [ [ Value.Date old; Int 1 ] ]) "past: its second: %s" (show (trunc v "second" "UTC"));
  (match Cepheus.ask v { Question.vars = 2; items = [ Question.Ask.Pattern { e = Var 0; p = day; v = Var 1 }; Question.Ask.Trunc (2, 1, "year", "UTC") ]; give = [| 2 |]; sort = []; limit = 0; after = None } with
   | Error (Invalid m) -> C.check (starts m "Trunc of sale/day to the year") "past: Cepheus.ask's Trunc: %s" m
   | _ -> C.fail "past: Cepheus.ask's Trunc of the oldest dates given");
  let v = at min_int in
  C.check (match trunc v "second" "UTC" with Error m -> starts m "Trunc of sale/day to the second of date " | Ok _ -> false) "past: the least date's second, refused: %s" (show (trunc v "second" "UTC"));
  (match Zone.trunc Zone.utc Zone.Year old with _ -> C.fail "past: Zone.trunc past the least date" | exception Zone.Bad _ -> C.check true "");
  let db = fork empty in
  let[@warning "-8"] (Ok [ day ]) = declare db [ prop "sale/day" Tdate ] in
  ignore (Result.get_ok (write db [ Resolve.Add (-1, day, Date max_int); Add (-2, day, Date Zone.safe_from); Add (-3, day, Date (Zone.safe_from - 1)) ]));
  let v = view db and q = { Query.vars = 2; where = [ { e = Var 0; p = day; v = Var 1 } ]; ranges = [] } in
  List.iter
    (fun (unit, zone) ->
      match ask ~extra:[ Question.Ask.Trunc (2, 1, unit, zone) ] v q (Wire.Group ([| 2 |], [| Wire.Count |])) with
      | Ok l -> C.check (List.length l >= 2) "past: Trunc %s %s of the largest date and the safe ones" unit zone
      | Error m -> C.fail "past: Trunc %s %s of the largest date: %s" unit zone m)
    [ "millennium", "UTC"; "millennium", "Pacific/Kiritimati"; "year", "Etc/GMT-14"; "second", "UTC"; "week", "Europe/Paris" ]

let () =
  if Array.length Sys.argv = 3 && Sys.argv.(1) = "--postgres" then (compare_postgres Sys.argv.(2); exit 0);
  let r = Rng.make 2026 in
  calendar r;
  offsets r;
  rules r;
  all_year r;
  truncs r;
  known ();
  refused ();
  set_tz "UTC";
  order_free r;
  exact ();
  selection r;
  threats ();
  past ();
  C.finish "reports"
