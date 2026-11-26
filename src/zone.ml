(* Civil time in a time zone of the IANA time zone database (tz), for Trunc: the instant a date, a month or an hour
   starts in a zone's local time, daylight saving time included.

   The database. A zone is read from the system's compiled files (TZif, RFC 8536: versions 1 to 4), in $TZDIR or
   /usr/share/zoneinfo, as the C library reads them: the system's tzdata package updates them, and a process reads a
   zone once (a server takes a new release of the rules at its next start). A file holds the zone's transitions (the
   instants its offset from UTC changed) and, after the last one, its rule in a POSIX TZ string (its footer, section
   3.3: "CET-1CEST,M3.5.0,M10.5.0/3"), which gives the transitions of every later year. "UTC" needs no file. A name
   is a path below that folder of letters, digits, '_', '-' and '+' only, so that a question names no other file; a
   zone with leap seconds (right/) is no civil zone, and refused.

   Local time. The offset at an instant is that of the last transition at or before it (before the first: the
   file's first time type, as RFC 8536 says), or the rule's past the last. A local time is the instant plus that
   offset. A day, a week, a month... starts at the earliest instant whose local time is at or after that day's
   midnight: a day whose midnight a spring-forward skips starts at its transition, one whose midnight a fall-back
   repeats at the first midnight, so that the days partition the time line. An hour, a minute or a second starts at
   the instant whose local time is its start, on the offset of the instant truncated, or at the last transition when
   that came later (a zone that moves by 30 minutes): so the hour that a fall-back repeats is two hours of the report,
   each its own instant, and every hour is one hour of the time line. *)

type date_rule = J of int  (** 1 to 365, February 29 never counted *) | N of int  (** 0 to 365 *) | M of int * int * int  (** month, week 1-5 (5: the last), day 0-6 (Sunday 0) *)

(* a POSIX TZ string: its standard offset (seconds east of UTC), and its daylight saving time when it has one: its
   offset, its start (a date and a time of standard local time) and its end (of daylight local time) *)
type rule = { std : int; dst : (int * date_rule * int * date_rule * int) option }

type t = {
  name : string;
  trans : int array;  (* the transitions, in seconds since 1970, ascending *)
  offs : int array;  (* the offset after each, seconds east of UTC *)
  first : int;  (* before the first transition *)
  rule : rule option;  (* after the last *)
}

exception Bad of string

let bad fmt = Printf.ksprintf (fun s -> raise (Bad s)) fmt

let utc = { name = "UTC"; trans = [||]; offs = [||]; first = 0; rule = None }

(* ---- the civil calendar (proleptic Gregorian), days since 1970-01-01: Hinnant's algorithms ---- *)

(* the floor of a / b, b > 0: OCaml's division goes toward 0, so one less for a negative a with a remainder. No -a,
   which the least int has not: -((-a + b - 1) / b) wrapped there, the second of the least date read as one 146
   million years after 1970 *)
let fdiv a b = let q = a / b in if a >= 0 || q * b = a then q else q - 1
let fmod a b = a - (b * fdiv a b)

let days_from_civil y m d =
  let y = if m <= 2 then y - 1 else y in
  let era = fdiv y 400 in
  let yoe = y - (era * 400) in
  let mp = (m + 9) mod 12 in
  let doy = ((153 * mp) + 2) / 5 + d - 1 in
  let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
  (era * 146097) + doe - 719468

let civil_from_days z =
  let z = z + 719468 in
  let era = fdiv z 146097 in
  let doe = z - (era * 146097) in
  let yoe = (doe - (doe / 1460) + (doe / 36524) - (doe / 146096)) / 365 in
  let y = yoe + (era * 400) in
  let doy = doe - ((365 * yoe) + (yoe / 4) - (yoe / 100)) in
  let mp = ((5 * doy) + 2) / 153 in
  let d = doy - (((153 * mp) + 2) / 5) + 1 in
  let m = if mp < 10 then mp + 3 else mp - 9 in
  ((if m <= 2 then y + 1 else y), m, d)

let leap y = (y mod 4 = 0 && y mod 100 <> 0) || y mod 400 = 0
let month_days y m = match m with 2 -> if leap y then 29 else 28 | 4 | 6 | 9 | 11 -> 30 | _ -> 31

(* ---- the POSIX TZ string of a footer ---- *)

let parse_rule s =
  let n = String.length s and i = ref 0 in
  let fail () = bad "the time zone rule %S does not read" s in
  let peek () = if !i < n then Some s.[!i] else None in
  let digits () =
    let st = !i in
    while !i < n && s.[!i] >= '0' && s.[!i] <= '9' do incr i done;
    if !i = st || !i - st > 3 then fail ();
    int_of_string (String.sub s st (!i - st))
  in
  let name () =
    match peek () with
    | Some '<' ->
      incr i;
      while !i < n && s.[!i] <> '>' do incr i done;
      if !i >= n then fail ();
      incr i
    | _ ->
      let st = !i in
      while !i < n && ((s.[!i] >= 'A' && s.[!i] <= 'Z') || (s.[!i] >= 'a' && s.[!i] <= 'z')) do incr i done;
      if !i - st < 3 then fail ()
  in
  (* [+-]hh[:mm[:ss]], in seconds; hours up to [hmax] *)
  let hms hmax =
    let sign = match peek () with Some '-' -> incr i; -1 | Some '+' -> incr i; 1 | _ -> 1 in
    let h = digits () in
    if h > hmax then fail ();
    let part () = match peek () with Some ':' -> incr i; let x = digits () in if x > 59 then fail (); x | _ -> 0 in
    let m = part () in
    let sec = part () in
    sign * ((h * 3600) + (m * 60) + sec)
  in
  let date () =
    match peek () with
    | Some 'J' -> incr i; let d = digits () in if d < 1 || d > 365 then fail (); J d
    | Some 'M' ->
      incr i;
      let m = digits () in
      if peek () <> Some '.' then fail ();
      incr i;
      let w = digits () in
      if peek () <> Some '.' then fail ();
      incr i;
      let d = digits () in
      if m < 1 || m > 12 || w < 1 || w > 5 || d > 6 then fail ();
      M (m, w, d)
    | Some c when c >= '0' && c <= '9' -> let d = digits () in if d > 365 then fail (); N d
    | _ -> fail ()
  in
  let time () = match peek () with Some '/' -> incr i; hms 167 | _ -> 7200 in
  name ();
  let std = - hms 24 in
  if !i = n then { std; dst = None }
  else begin
    name ();
    let dst_off = match peek () with Some (',' | ';') | None -> std + 3600 | _ -> - hms 24 in
    let start, stime, stop, etime =
      match peek () with
      | Some ',' ->
        incr i;
        let a = date () in
        let at = time () in
        if peek () <> Some ',' then fail ();
        incr i;
        let b = date () in
        let bt = time () in
        a, at, b, bt
      | None -> M (3, 2, 0), 7200, M (11, 1, 0), 7200 (* POSIX leaves it to the system: the C library's US rule *)
      | _ -> fail ()
    in
    if !i <> n then fail ();
    { std; dst = Some (dst_off, start, stime, stop, etime) }
  end

(* the day (since 1970) of a rule's date in year y *)
let rule_day y = function
  | J d -> days_from_civil y 1 1 + (d - 1) + (if leap y && d >= 60 then 1 else 0)
  | N d -> days_from_civil y 1 1 + d
  | M (m, w, d) ->
    let first = days_from_civil y m 1 in
    let wd = fmod (first + 4) 7 in
    let day = first + fmod (d - wd) 7 + (7 * (w - 1)) in
    let last = first + month_days y m - 1 in
    let rec back x = if x > last then back (x - 7) else x in
    back day

(* year y's start and end of daylight saving time, as instants *)
let rule_bounds r y =
  match r.dst with
  | None -> None
  | Some (doff, a, at, b, bt) -> Some ((rule_day y a * 86400) + at - r.std, (rule_day y b * 86400) + bt - doff)

let year_of t off = let y, _, _ = civil_from_days (fdiv (t + off) 86400) in y

let rule_offset r t =
  match r.dst with
  | None -> r.std
  | Some (doff, _, _, _, _) -> (
    match rule_bounds r (year_of t r.std) with
    | Some (s, e) -> if (s < e && s <= t && t < e) || (s > e && (t < e || t >= s)) then doff else r.std
    | None -> r.std)

(* the rule's transitions of the years around t *)
let rule_marks r t =
  let y = year_of t r.std in
  List.concat_map (fun y -> match rule_bounds r y with Some (s, e) -> [ s; e ] | None -> []) [ y - 1; y; y + 1; y + 2 ]

(* ---- offsets and transitions ---- *)

(* the last index of [trans] at or before t, -1 when t is before every one *)
let index z t =
  let a = ref 0 and b = ref (Array.length z.trans) in
  while !a < !b do let m = (!a + !b) / 2 in if z.trans.(m) <= t then a := m + 1 else b := m done;
  !a - 1

let offset z t =
  let n = Array.length z.trans in
  let i = index z t in
  match z.rule with
  | Some r when i = n - 1 -> rule_offset r t
  | _ -> if i < 0 then z.first else z.offs.(i)

(* the first transition after t *)
let next z t =
  let n = Array.length z.trans in
  let i = index z t in
  if i < n - 1 then Some z.trans.(i + 1)
  else match z.rule with
    | Some r -> List.fold_left (fun acc m -> if m > t && (match acc with Some a -> m < a | None -> true) then Some m else acc) None (rule_marks r t)
    | None -> None

(* the last transition at or before t, or min_int *)
let last_mark z t =
  let n = Array.length z.trans in
  let i = index z t in
  let from_table = if i < 0 then min_int else z.trans.(i) in
  match z.rule with
  | Some r when i = n - 1 -> List.fold_left (fun acc m -> if m <= t && m > acc then m else acc) from_table (rule_marks r t)
  | _ -> from_table

(* the start of the run of t's offset: its last transition that changed the offset (a transition may change only the
   zone's abbreviation), or min_int *)
let prev z t =
  let o = offset z t in
  let rec go s guard = if s = min_int || guard = 0 || offset z (s - 1) <> o then s else go (last_mark z (s - 1)) (guard - 1) in
  go (last_mark z t) 4096

(* the earliest instant whose local time is at or after [l]: no instant before l - 26 hours has it (an offset is
   within a day and two hours), so the time line is walked from there, one constant offset at a time *)
let earliest z l =
  let rec go t0 guard =
    let o = offset z t0 in
    let cand = max t0 (l - o) in
    match next z t0 with
    | Some nt when cand >= nt && guard > 0 -> go nt (guard - 1)
    | _ -> cand
  in
  go (l - (2 * 86400)) 64

(* ---- reading a zone ---- *)

let be32 s o = let x = Int32.to_int (String.get_int32_be s o) in x
let be64 s o = Int64.to_int (String.get_int64_be s o)

let of_tzif name s =
  let len = String.length s in
  let need k = if k > len then bad "the time zone %s: its file is cut short" name in
  need 44;
  if String.sub s 0 4 <> "TZif" then bad "the time zone %s: its file is not a TZif file" name;
  let version = s.[4] in
  let counts o = Array.init 6 (fun k -> let x = be32 s (o + 20 + (4 * k)) in if x < 0 || x > 1_000_000 then bad "the time zone %s: its file does not read" name; x) in
  let c1 = counts 0 in
  let size tsize c = (c.(3) * tsize) + c.(3) + (c.(4) * 6) + c.(5) + (c.(2) * (tsize + 4)) + c.(1) + c.(0) in
  let o, c, tsize =
    if version >= '2' then (
      let o2 = 44 + size 4 c1 in
      need (o2 + 44);
      if String.sub s o2 4 <> "TZif" then bad "the time zone %s: its file does not read" name;
      o2 + 44, counts o2, 8)
    else 44, c1, 4
  in
  let isutcnt = c.(0) and isstdcnt = c.(1) and leapcnt = c.(2) and timecnt = c.(3) and typecnt = c.(4) and charcnt = c.(5) in
  ignore (isutcnt, isstdcnt, charcnt);
  need (o + size tsize c);
  if leapcnt > 0 then bad "the time zone %s counts leap seconds: Cepheus's dates are UTC without them (take the zone outside right/)" name;
  if typecnt < 1 then bad "the time zone %s: its file has no time type" name;
  let trans = Array.init timecnt (fun k -> if tsize = 8 then be64 s (o + (8 * k)) else be32 s (o + (4 * k))) in
  let ti = o + (timecnt * tsize) in
  let idx = Array.init timecnt (fun k -> Char.code s.[ti + k]) in
  let tt = ti + timecnt in
  let utoff k = let x = be32 s (tt + (6 * k)) in if x < -89999 || x > 93599 then bad "the time zone %s: an offset out of range" name; x in
  let types = Array.init typecnt utoff in
  Array.iteri (fun k i -> if i >= typecnt then bad "the time zone %s: a transition of no time type" name; if k > 0 && trans.(k) <= trans.(k - 1) then bad "the time zone %s: its transitions are not in order" name) idx;
  let offs = Array.map (fun i -> types.(i)) idx in
  let rule =
    if tsize = 8 then begin
      let f = o + size 8 c in
      if f < len && s.[f] = '\n' then
        match String.index_from_opt s (f + 1) '\n' with
        | Some e when e > f + 1 -> Some (parse_rule (String.sub s (f + 1) (e - f - 1)))
        | _ -> None
      else None
    end
    else None
  in
  { name; trans; offs; first = types.(0); rule }

let dir () = match Sys.getenv_opt "TZDIR" with Some d when d <> "" -> d | _ -> "/usr/share/zoneinfo"

let valid_name n =
  String.length n >= 1 && String.length n <= 255
  && String.for_all (fun c -> (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '_' || c = '-' || c = '+' || c = '/') n
  && List.for_all (fun p -> p <> "" && p <> "." && p <> "..") (String.split_on_char '/' n)

let read name =
  if not (valid_name name) then bad "%S is not a time zone name: an IANA name, as \"Europe/Paris\", or \"UTC\"" name;
  let path = Filename.concat (dir ()) name in
  let s =
    match In_channel.with_open_bin path (fun ic -> let n = In_channel.length ic in if n > 4194304L then None else In_channel.really_input_string ic (Int64.to_int n)) with
    | Some s -> s
    | None -> bad "the time zone %s: its file does not read" name
    | exception Sys_error _ -> bad "no time zone %s in the zone database (%s): an IANA name, as \"Europe/Paris\", or \"UTC\"" name (dir ())
  in
  of_tzif name s

(* the zones read, by name: a process reads each once *)
let zones : (string, t) Hashtbl.t = Hashtbl.create 16
let zm = Mutex.create ()

let find name =
  if name = "UTC" then utc
  else
    match Mutex.protect zm (fun () -> Hashtbl.find_opt zones name) with
    | Some z -> z
    | None ->
      let z = read name in
      Mutex.protect zm (fun () -> if Hashtbl.length zones < 4096 then Hashtbl.replace zones name z);
      z

(* ---- truncation ---- *)

type unit_ = Second | Minute | Hour | Day | Week | Month | Quarter | Year | Decade | Century | Millennium

let units = [ "second", Second; "minute", Minute; "hour", Hour; "day", Day; "week", Week; "month", Month; "quarter", Quarter; "year", Year; "decade", Decade; "century", Century; "millennium", Millennium ]

let unit_of s =
  match List.assoc_opt s units with
  | Some u -> u
  | None -> bad "Trunc takes a unit of %s, not %S" (String.concat ", " (List.map fst units)) s

(* the local time (seconds) truncated to the unit *)
let floor_local u lsec =
  match u with
  | Second -> lsec
  | Minute -> lsec - fmod lsec 60
  | Hour -> lsec - fmod lsec 3600
  | _ ->
    let days = fdiv lsec 86400 in
    let y, m, _ = civil_from_days days in
    86400
    * (match u with
       | Day -> days
       | Week -> days - fmod (days + 3) 7
       | Month -> days_from_civil y m 1
       | Quarter -> days_from_civil y ((3 * ((m - 1) / 3)) + 1) 1
       | Year -> days_from_civil y 1 1
       | Decade -> days_from_civil (y - fmod y 10) 1 1
       | Century -> days_from_civil ((100 * fdiv (y - 1) 100) + 1) 1 1
       | Millennium -> days_from_civil ((1000 * fdiv (y - 1) 1000) + 1) 1 1
       | Second | Minute | Hour -> days)

(* The least second whose milliseconds are a date, an Int: -4,611,686,018,427,387 (the least date is -2^62 ms, 146
   million years before 1970). A unit that starts before it, a year of a date in the least one's (or a second of the
   least date itself), has no start a date can hold: refused, where 1000 s wrapped past the ints to a date 146 million
   years after 1970. Its start is never after the instant, so no unit passes the largest date. *)
let least_second = min_int / 1000 (* toward 0: the ceiling *)

(* the dates whose every unit starts at a date: from the least one and 1,002 years and 3 days (a millennium, a zone's
   offset, the day earliest walks back) *)
let safe_from = min_int + (1000 * 86400 * ((366 * 1002) + 3))

let ms_of s = if s < least_second then bad "its unit starts before the least date, -2^62 ms (146 million years before 1970)" else 1000 * s

(* Trunc of an instant in milliseconds: the instant its unit starts, in milliseconds. Raises Bad when it starts
   before the least date. *)
let trunc z u ms =
  let t = fdiv ms 1000 in
  if z == utc then ms_of (floor_local u t)
  else begin
    let o = offset z t in
    let l0 = floor_local u (t + o) in
    match u with
    | Second | Minute | Hour -> ms_of (max (l0 - o) (prev z t))
    | _ -> ms_of (earliest z l0)
  end

(* A Trunc's function of a date's index word (its milliseconds): a day and longer units remember the start of the
   last buckets they found (a table of 1,024, each slot an immutable pair, so that the domains of a fold share it
   without a lock), as most rows of a report fall in few buckets *)
let truncator ~unit ~zone =
  let z = find zone and u = unit_of unit in
  match u with
  | _ when z == utc -> fun ms -> trunc z u ms
  | Second | Minute | Hour -> fun ms -> trunc z u ms
  | _ ->
    let memo = Array.make 1024 (min_int, 0) in
    fun ms ->
      let t = fdiv ms 1000 in
      let o = offset z t in
      let l0 = floor_local u (t + o) in
      let slot = (l0 / 86400) land 1023 in
      let k, r = memo.(slot) in
      if k = l0 then r
      else begin
        let r = ms_of (earliest z l0) in
        memo.(slot) <- (l0, r);
        r
      end
