(* The text of the files that `cepheus import` reads and `cepheus export` writes: CSV (RFC 4180, with a header row) and
   JSON lines (jsonlines.org: one JSON value a line, RFC 8259), and the text forms of the values in them. Nothing here
   knows the database: a record's bytes in, its fields out; a value in, its text out. Every function is total on any
   bytes: a bad input raises [Bad] with the reason, never anything else.

   The rules, those of PostgreSQL's COPY where a choice had to be made (sql-copy.html):
   - CSV: a field that starts with a quote is quoted, "" inside it is a quote, and it may hold commas and line breaks;
     a quote anywhere else is refused, as a character after a closing quote. An unquoted empty field is no value, a
     quoted one ("") the empty text: PostgreSQL's NULL and empty string. A record ends at a line break outside quotes,
     LF or CR LF. A UTF-8 byte order mark at the start of the file is skipped.
   - Texts are UTF-8 without NUL bytes (PostgreSQL refuses 0x00 in a text too): checked, never repaired.
   - Numbers are read exactly: an Int, money with at most its scale of decimals (12.50 is 1250 cents, never through
     a float), a float as IEEE's nearest double. Dates are RFC 3339 (2026-11-24, 2026-11-24T10:30:00Z,
     2026-11-24 10:30:00.123+01:00), a date without a zone in UTC, kept to the millisecond (finer digits cut). *)

exception Bad of string

let bad fmt = Printf.ksprintf (fun m -> raise (Bad m)) fmt

(* ---- UTF-8 ---- *)

(* the first byte of s.[o, o + n) that is not well-formed UTF-8 (RFC 3629: no overlong form, no surrogate, nothing
   past U+10FFFF) or is NUL, or -1 *)
let bad_utf8 s o n =
  let e = o + n in
  let rec go i =
    if i >= e then -1
    else
      let c = Char.code (String.unsafe_get s i) in
      if c >= 1 && c < 0x80 then go (i + 1)
      else if c = 0 then i
      else
        let cont j = j < e && Char.code (String.unsafe_get s j) land 0xC0 = 0x80 in
        let b1 = if i + 1 < e then Char.code (String.unsafe_get s (i + 1)) else 0 in
        if c >= 0xC2 && c <= 0xDF then (if cont (i + 1) then go (i + 2) else i)
        else if c >= 0xE0 && c <= 0xEF then
          let lo, hi = if c = 0xE0 then 0xA0, 0xBF else if c = 0xED then 0x80, 0x9F else 0x80, 0xBF in
          if b1 >= lo && b1 <= hi && cont (i + 2) then go (i + 3) else i
        else if c >= 0xF0 && c <= 0xF4 then
          let lo, hi = if c = 0xF0 then 0x90, 0xBF else if c = 0xF4 then 0x80, 0x8F else 0x80, 0xBF in
          if b1 >= lo && b1 <= hi && cont (i + 2) && cont (i + 3) then go (i + 4) else i
        else i
  in
  go o

let check_text s =
  match bad_utf8 s 0 (String.length s) with
  | -1 -> ()
  | i when s.[i] = '\000' -> bad "a NUL byte (at byte %d of the field)" (i + 1)
  | i -> bad "bytes that are not UTF-8 (at byte %d of the field)" (i + 1)

(* ---- numbers ---- *)

let digit c = c >= '0' && c <= '9'

(* [+-]? digits, within 63 bits *)
let int_of_text s =
  let n = String.length s in
  let neg = n > 0 && s.[0] = '-' in
  let i0 = if n > 0 && (s.[0] = '-' || s.[0] = '+') then 1 else 0 in
  if i0 >= n then bad "%S is not a whole number" s;
  (* accumulated as a negative number: min_int has no positive twin *)
  let acc = ref 0 in
  for i = i0 to n - 1 do
    let c = s.[i] in
    if not (digit c) then bad "%S is not a whole number" s;
    let d = Char.code c - 48 in
    if !acc < (min_int + d) / 10 then bad "%s does not fit in 63 bits" s;
    acc := (!acc * 10) - d
  done;
  if neg then !acc else if !acc = min_int then bad "%s does not fit in 63 bits" s else - !acc

(* the syntax of a decimal float: [+-]? (digits [. digits?] | . digits) ([eE] [+-]? digits)? *)
let float_syntax s =
  let n = String.length s and i = ref 0 in
  if !i < n && (s.[!i] = '-' || s.[!i] = '+') then incr i;
  let d0 = !i in
  while !i < n && digit s.[!i] do incr i done;
  let whole = !i > d0 in
  let frac =
    if !i < n && s.[!i] = '.' then begin
      incr i;
      let f0 = !i in
      while !i < n && digit s.[!i] do incr i done;
      !i > f0
    end
    else false
  in
  let ok = ref (whole || frac) in
  if !ok && !i < n && (s.[!i] = 'e' || s.[!i] = 'E') then begin
    incr i;
    if !i < n && (s.[!i] = '-' || s.[!i] = '+') then incr i;
    let e0 = !i in
    while !i < n && digit s.[!i] do incr i done;
    if !i = e0 then ok := false
  end;
  !ok && !i = n

let float_of_text s =
  match String.lowercase_ascii s with
  | "nan" | "+nan" | "-nan" -> Float.nan
  | "infinity" | "+infinity" | "inf" | "+inf" -> Float.infinity
  | "-infinity" | "-inf" -> Float.neg_infinity
  | _ -> if float_syntax s then float_of_string s else bad "%S is not a number" s

(* the shortest decimal that reads back as the same double *)
let float_text f =
  if Float.is_nan f then "NaN"
  else if f = Float.infinity then "Infinity"
  else if f = Float.neg_infinity then "-Infinity"
  else
    let rec go p =
      let s = Printf.sprintf "%.*g" p f in
      if p >= 17 || Int64.equal (Int64.bits_of_float (float_of_string s)) (Int64.bits_of_float f) then s else go (p + 1)
    in
    go 15

(* money of [scale] decimals in minor units: [+-]? digits [. digits] (or . digits), at most [scale] of them after the
   point, exactly; within 63 bits *)
let money_of_text scale s =
  let n = String.length s in
  let neg = n > 0 && s.[0] = '-' in
  let i = ref (if n > 0 && (s.[0] = '-' || s.[0] = '+') then 1 else 0) in
  let acc = ref 0 and digits = ref 0 and decimals = ref (-1) in
  let add c =
    let d = Char.code c - 48 in
    if !acc < (min_int + d) / 10 then bad "%s does not fit in 63 bits" s;
    acc := (!acc * 10) - d;
    incr digits
  in
  while !i < n do
    let c = s.[!i] in
    if digit c then begin
      if !decimals >= 0 then begin
        incr decimals;
        if !decimals > scale then bad "%s has more than %d decimal%s" s scale (if scale = 1 then "" else "s")
      end;
      add c
    end
    else if c = '.' && !decimals < 0 then decimals := 0
    else bad "%S is not an amount (digits, a point, at most %d decimal%s)" s scale (if scale = 1 then "" else "s");
    incr i
  done;
  if !digits = 0 then bad "%S is not an amount" s;
  for _ = max 0 !decimals + 1 to scale do add '0' done;
  if neg then !acc else if !acc = min_int then bad "%s does not fit in 63 bits" s else - !acc

let money_text scale u =
  let s = string_of_int u in
  let neg = u < 0 in
  let d = if neg then String.sub s 1 (String.length s - 1) else s in
  let d = if String.length d <= scale then String.make (scale + 1 - String.length d) '0' ^ d else d in
  let k = String.length d - scale in
  (if neg then "-" else "") ^ String.sub d 0 k ^ if scale = 0 then "" else "." ^ String.sub d k scale

(* ---- dates: RFC 3339, in milliseconds since 1970 UTC ---- *)

(* the days since 1970-01-01 of a date of the proleptic Gregorian calendar, and back (Hinnant's algorithms,
   "chrono-Compatible Low-Level Date Algorithms") *)
let days_of_civil y m d =
  let y = if m <= 2 then y - 1 else y in
  let era = (if y >= 0 then y else y - 399) / 400 in
  let yoe = y - (era * 400) in
  let doy = (((153 * ((m + 9) mod 12)) + 2) / 5) + d - 1 in
  let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
  (era * 146097) + doe - 719468

let civil_of_days z =
  let z = z + 719468 in
  let era = (if z >= 0 then z else z - 146096) / 146097 in
  let doe = z - (era * 146097) in
  let yoe = (doe - (doe / 1460) + (doe / 36524) - (doe / 146096)) / 365 in
  let doy = doe - ((365 * yoe) + (yoe / 4) - (yoe / 100)) in
  let mp = ((5 * doy) + 2) / 153 in
  let d = doy - (((153 * mp) + 2) / 5) + 1 in
  let m = if mp < 10 then mp + 3 else mp - 9 in
  (yoe + (era * 400) + if m <= 2 then 1 else 0), m, d

let leap y = (y mod 4 = 0 && y mod 100 <> 0) || y mod 400 = 0
let month_days y m = match m with 2 -> if leap y then 29 else 28 | 4 | 6 | 9 | 11 -> 30 | _ -> 31
let day_ms = 86_400_000

let date_of_text s =
  let n = String.length s in
  let fail () = bad "%S is not a date (2026-11-24, 2026-11-24T10:30:00Z, 2026-11-24 10:30:00.123+01:00)" s in
  let num i k = if i + k > n then fail () else (let v = ref 0 in for j = i to i + k - 1 do if not (digit s.[j]) then fail (); v := (!v * 10) + Char.code s.[j] - 48 done; !v) in
  let at i c = i < n && s.[i] = c in
  let y = num 0 4 in
  if not (at 4 '-') then fail ();
  let mo = num 5 2 in
  if not (at 7 '-') then fail ();
  let d = num 8 2 in
  if mo < 1 || mo > 12 || d < 1 || d > month_days y mo then bad "%s is not a day of the calendar" s;
  let days = days_of_civil y mo d in
  if n = 10 then days * day_ms
  else begin
    if not (at 10 'T' || at 10 't' || at 10 ' ') then fail ();
    let h = num 11 2 in
    if not (at 13 ':') then fail ();
    let mi = num 14 2 in
    let i = ref 16 and sec = ref 0 and ms = ref 0 in
    if at 16 ':' then begin
      sec := num 17 2;
      i := 19;
      if at 19 '.' then begin
        i := 20;
        let k = ref 0 in
        while !i < n && digit s.[!i] do
          if !k < 3 then ms := (!ms * 10) + Char.code s.[!i] - 48;
          incr k;
          incr i
        done;
        if !k = 0 then fail ();
        for _ = !k + 1 to 3 do ms := !ms * 10 done
      end
    end;
    if h > 23 || mi > 59 || !sec > 59 then bad "%s is not a time of the day (00:00:00 to 23:59:59)" s;
    let off =
      if !i = n then 0
      else if (at !i 'Z' || at !i 'z') && !i + 1 = n then 0
      else if at !i '+' || at !i '-' then begin
        let sign = if s.[!i] = '-' then -1 else 1 in
        let oh = num (!i + 1) 2 in
        let om =
          if !i + 3 = n then 0
          else if at (!i + 3) ':' && !i + 6 = n then num (!i + 4) 2
          else if !i + 5 = n then num (!i + 3) 2
          else fail ()
        in
        if oh > 23 || om > 59 then fail ();
        sign * ((oh * 60) + om)
      end
      else fail ()
    in
    (days * day_ms) + (((h * 3600) + (mi * 60) + !sec - (off * 60)) * 1000) + !ms
  end

(* RFC 3339 in UTC, the milliseconds only when there are some; years 0 to 9999 *)
let date_text ms =
  let days = if ms >= 0 then ms / day_ms else -((-ms + day_ms - 1) / day_ms) in
  let r = ms - (days * day_ms) in
  let y, m, d = civil_of_days days in
  if y < 0 || y > 9999 then bad "a date of the year %d: RFC 3339 writes the years 0 to 9999" y;
  let s = r / 1000 and f = r mod 1000 in
  let base = Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d" y m d (s / 3600) (s / 60 mod 60) (s mod 60) in
  if f = 0 then base ^ "Z" else Printf.sprintf "%s.%03dZ" base f

(* ---- booleans ---- *)

let bool_of_text s =
  match String.lowercase_ascii s with
  | "true" | "t" | "1" -> true
  | "false" | "f" | "0" -> false
  | _ -> bad "%S is not true or false" s

(* ---- records ---- *)

(* The largest record (a CSV row with its quoted line breaks, a JSON line): a quote left open in a file of 10 GB stops
   the import here, with the line it started at, rather than reading the rest of the file as one field. A record fits a
   write with room to spare (a frame holds 16 MiB). *)
let max_record = 8 lsl 20

type format = Csv | Jsonl

(* A file read as whole records, by batches: [next r target] gives the records that start after the last batch's,
   about [target] bytes of them (one at least, until the end), copied into a block of their own so that other domains
   can parse them while the next batch is read. A record's bytes leave out its line break (LF, or CR LF) and a blank
   record (no byte) is skipped; [lines] gives the line each record starts at (the header is line 1), counting the
   line breaks inside quotes. CSV finds a record's end by its quotes alone: a quote opens or closes, so "" inside a
   quoted field closes and opens again; a record that is not well quoted is then refused by [csv_fields]. *)
type batch = {
  data : Bytes.t;
  starts : int array;
  stops : int array;
  lines : int array;
  index : int;  (* of its first record *)
  off : int;  (* the file's offset of data.[0] *)
}

type reader = {
  fd : Unix.file_descr;
  fmt : format;
  mutable buf : Bytes.t;
  mutable len : int;  (* bytes held *)
  mutable pos : int;  (* the start of the first record not given *)
  mutable scanned : int;  (* bytes of buf walked for record ends *)
  mutable quoted : bool;  (* CSV: inside quotes at [scanned] *)
  mutable line : int;  (* the line at [scanned] *)
  mutable rline : int;  (* the line the record at [pos] starts at *)
  mutable eof : bool;
  mutable count : int;  (* records given *)
  mutable bytes : int;  (* bytes read, for the progress *)
  mutable boff : int;  (* the file's offset of buf.[0] *)
}

let read_size = 1 lsl 20

(* a reader of fd from its offset [off], a record's start, which is record [index] and starts at line [line]; at the
   file's start a UTF-8 byte order mark is skipped *)
let reader ?(off = 0) ?(line = 1) ?(index = 0) fmt fd =
  let r = { fd; fmt; buf = Bytes.create (2 * read_size); len = 0; pos = 0; scanned = 0; quoted = false; line; rline = line; eof = false; count = index; bytes = 0; boff = off } in
  if off = 0 then begin
    let rec fill () = if r.len < 3 && not r.eof then (match Unix.read fd r.buf r.len (Bytes.length r.buf - r.len) with 0 -> r.eof <- true | k -> r.len <- r.len + k; r.bytes <- r.bytes + k; fill ()) in
    fill ();
    if r.len >= 3 && Bytes.sub_string r.buf 0 3 = "\xEF\xBB\xBF" then (r.pos <- 3; r.scanned <- 3)
  end;
  r

(* more bytes read after those held; [compact]: the bytes before [pos] dropped first (only while no record of a batch
   being made is held: its offsets are the buffer's) *)
let rec read_more ~compact r =
  if compact && r.pos > 0 then begin
    r.boff <- r.boff + r.pos;
    Bytes.blit r.buf r.pos r.buf 0 (r.len - r.pos);
    r.len <- r.len - r.pos;
    r.scanned <- r.scanned - r.pos;
    r.pos <- 0
  end;
  if Bytes.length r.buf - r.len < read_size then begin
    let b = Bytes.create (2 * Bytes.length r.buf) in
    Bytes.blit r.buf 0 b 0 r.len;
    r.buf <- b
  end;
  match Unix.read r.fd r.buf r.len (Bytes.length r.buf - r.len) with
  | 0 -> r.eof <- true
  | k -> r.len <- r.len + k; r.bytes <- r.bytes + k
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> read_more ~compact r

let next r target =
  let starts = ref [] and stops = ref [] and lines = ref [] and first = ref (-1) and last = ref 0 and n = ref 0 in
  let record s e line =
    let e = if e > s && Bytes.get r.buf (e - 1) = '\r' then e - 1 else e in
    if e > s then begin
      if !first < 0 then first := s;
      starts := s :: !starts; stops := e :: !stops; lines := line :: !lines; last := e; incr n
    end
  in
  let fin = ref false in
  while not !fin do
    (* the record ends in what is held *)
    let i = ref r.scanned in
    while !i < r.len && (!first < 0 || !last - !first < target) do
      (match r.fmt with
       | Jsonl -> (
         match Bytes.index_from_opt r.buf !i '\n' with
         | Some j when j < r.len -> record r.pos j r.rline; r.line <- r.line + 1; r.rline <- r.line; r.pos <- j + 1; i := j + 1
         | _ -> i := r.len)
       | Csv ->
         let j = ref !i and stop = ref (-1) in
         while !stop < 0 && !j < r.len do
           (match Bytes.unsafe_get r.buf !j with
            | '"' -> r.quoted <- not r.quoted
            | '\n' -> r.line <- r.line + 1; if not r.quoted then stop := !j
            | _ -> ());
           incr j
         done;
         if !stop >= 0 then (record r.pos !stop r.rline; r.rline <- r.line; r.pos <- !stop + 1);
         i := !j);
      r.scanned <- !i
    done;
    if !first >= 0 && (!last - !first >= target || r.eof || r.scanned < r.len) then fin := true
    else if r.eof then begin
      (* the last record, without a line break *)
      if r.len - r.pos > max_record then bad "line %d: a record of more than %d MiB (%s)" r.rline (max_record lsr 20) (if r.fmt = Csv && r.quoted then "a quote left open?" else "no line break");
      if r.pos < r.len then (record r.pos r.len r.rline; r.pos <- r.len; r.scanned <- r.len);
      fin := true
    end
    else begin
      if r.len - r.pos > max_record then bad "line %d: a record of more than %d MiB (%s)" r.rline (max_record lsr 20) (if r.fmt = Csv && r.quoted then "a quote left open?" else "no line break");
      read_more ~compact:(!first < 0) r
    end
  done;
  let base = if !first < 0 then 0 else !first in
  let data = if !first < 0 then Bytes.empty else Bytes.sub r.buf base (!last - base) in
  let rev l = Array.of_list (List.rev l) in
  let b = { data; starts = Array.map (fun s -> s - base) (rev !starts); stops = Array.map (fun s -> s - base) (rev !stops); lines = rev !lines; index = r.count; off = r.boff + base } in
  r.count <- r.count + !n;
  b

(* ---- CSV ---- *)

(* a field: its text, and whether it was quoted *)
type field = { text : string; quoted : bool }

(* The fields of the record b.[o, e) (no line break at its end). *)
let csv_fields (b : Bytes.t) o e =
  let fields = ref [] and i = ref o in
  let buf = Buffer.create 64 in
  let fin = ref false in
  while not !fin do
    if !i < e && Bytes.get b !i = '"' then begin
      (* a quoted field: to its closing quote, "" a quote *)
      Buffer.clear buf;
      incr i;
      let closed = ref false in
      while not !closed do
        if !i >= e then bad "a quoted field is not closed";
        let c = Bytes.get b !i in
        if c = '"' then
          if !i + 1 < e && Bytes.get b (!i + 1) = '"' then (Buffer.add_char buf '"'; i := !i + 2) else (closed := true; incr i)
        else (Buffer.add_char buf c; incr i)
      done;
      fields := { text = Buffer.contents buf; quoted = true } :: !fields;
      if !i >= e then fin := true
      else if Bytes.get b !i = ',' then incr i
      else bad "a character after the closing quote of field %d (a quote inside a field is written \"\")" (List.length !fields)
    end
    else begin
      (* to the next comma or the record's end, no further *)
      let j = ref !i in
      while !j < e && Bytes.unsafe_get b !j <> ',' do
        if Bytes.unsafe_get b !j = '"' then bad "a quote inside field %d, which does not start with one (quote the field, a quote in it as \"\")" (List.length !fields + 1);
        incr j
      done;
      let j = !j in
      fields := { text = Bytes.sub_string b !i (j - !i); quoted = false } :: !fields;
      if j >= e then fin := true else i := j + 1
    end
  done;
  Array.of_list (List.rev !fields)

(* a field as CSV writes it: quoted when it holds a comma, a quote or a line break, starts or ends with a space, or is
   the empty text (an unquoted empty field is no value) *)
let csv_add buf s =
  let n = String.length s in
  let needs =
    n = 0 || s.[0] = ' ' || s.[n - 1] = ' '
    || String.exists (fun c -> c = ',' || c = '"' || c = '\n' || c = '\r') s
  in
  if not needs then Buffer.add_string buf s
  else begin
    Buffer.add_char buf '"';
    String.iter (fun c -> if c = '"' then Buffer.add_string buf "\"\"" else Buffer.add_char buf c) s;
    Buffer.add_char buf '"'
  end

(* ---- JSON ---- *)

type json = Null | Bool of bool | Num of string  (* its text, read by the field's type *) | Str of string | Arr of json list | Obj of (string * json) list

(* nesting deeper than this is refused: a line of 8 MiB of '[' would otherwise take the stack *)
let max_depth = 64

(* The JSON value of b.[o, e) *)
let json_value (b : Bytes.t) o e =
  let i = ref o in
  let peek () = if !i < e then Bytes.get b !i else '\000' in
  let ws () = while !i < e && (match Bytes.get b !i with ' ' | '\t' | '\r' | '\n' -> true | _ -> false) do incr i done in
  let expect c = if peek () = c && !i < e then incr i else bad "%s at byte %d" (if !i < e then Printf.sprintf "%C" (Bytes.get b !i) else "the end of the line") (!i - o + 1) in
  let hex4 () =
    if !i + 4 > e then bad "a short \\u escape";
    let v = ref 0 in
    for _ = 1 to 4 do
      let c = Bytes.get b !i in
      let d = match c with '0' .. '9' -> Char.code c - 48 | 'a' .. 'f' -> Char.code c - 87 | 'A' .. 'F' -> Char.code c - 55 | _ -> bad "a bad \\u escape" in
      v := (!v * 16) + d;
      incr i
    done;
    !v
  in
  let str () =
    expect '"';
    let buf = Buffer.create 32 in
    let fin = ref false in
    while not !fin do
      if !i >= e then bad "a string is not closed";
      let c = Bytes.get b !i in
      if c = '"' then (incr i; fin := true)
      else if c = '\\' then begin
        incr i;
        if !i >= e then bad "a string is not closed";
        let x = Bytes.get b !i in
        incr i;
        match x with
        | '"' -> Buffer.add_char buf '"'
        | '\\' -> Buffer.add_char buf '\\'
        | '/' -> Buffer.add_char buf '/'
        | 'b' -> Buffer.add_char buf '\b'
        | 'f' -> Buffer.add_char buf '\012'
        | 'n' -> Buffer.add_char buf '\n'
        | 'r' -> Buffer.add_char buf '\r'
        | 't' -> Buffer.add_char buf '\t'
        | 'u' ->
          let u = hex4 () in
          let u =
            if u >= 0xD800 && u <= 0xDBFF then begin
              if !i + 2 <= e && Bytes.get b !i = '\\' && Bytes.get b (!i + 1) = 'u' then begin
                i := !i + 2;
                let l = hex4 () in
                if l < 0xDC00 || l > 0xDFFF then bad "a lone surrogate in a \\u escape";
                0x10000 + ((u - 0xD800) lsl 10) + (l - 0xDC00)
              end
              else bad "a lone surrogate in a \\u escape"
            end
            else if u >= 0xDC00 && u <= 0xDFFF then bad "a lone surrogate in a \\u escape"
            else u
          in
          if u = 0 then bad "a NUL character (\\u0000)";
          Buffer.add_utf_8_uchar buf (Uchar.of_int u)
        | c -> bad "a bad escape \\%c" c
      end
      else if Char.code c < 0x20 then bad "a control character in a string (escape it)"
      else (Buffer.add_char buf c; incr i)
    done;
    let s = Buffer.contents buf in
    (match bad_utf8 s 0 (String.length s) with -1 -> () | _ -> bad "a string that is not UTF-8");
    s
  in
  let word w v =
    let n = String.length w in
    if !i + n <= e && Bytes.sub_string b !i n = w then (i := !i + n; v) else bad "a bad value at byte %d" (!i - o + 1)
  in
  let num () =
    let s0 = !i in
    if peek () = '-' then incr i;
    let d0 = !i in
    while !i < e && digit (Bytes.get b !i) do incr i done;
    if !i = d0 || (!i - d0 > 1 && Bytes.get b d0 = '0') then bad "a bad number at byte %d" (s0 - o + 1);
    if peek () = '.' && !i < e then begin
      incr i;
      let f0 = !i in
      while !i < e && digit (Bytes.get b !i) do incr i done;
      if !i = f0 then bad "a bad number at byte %d" (s0 - o + 1)
    end;
    if (peek () = 'e' || peek () = 'E') && !i < e then begin
      incr i;
      if peek () = '+' || peek () = '-' then incr i;
      let x0 = !i in
      while !i < e && digit (Bytes.get b !i) do incr i done;
      if !i = x0 then bad "a bad number at byte %d" (s0 - o + 1)
    end;
    Num (Bytes.sub_string b s0 (!i - s0))
  in
  let rec value depth =
    if depth > max_depth then bad "values nested more than %d deep" max_depth;
    ws ();
    if !i >= e then bad "a value is missing at the end of the line";
    match Bytes.get b !i with
    | '"' -> Str (str ())
    | 't' -> word "true" (Bool true)
    | 'f' -> word "false" (Bool false)
    | 'n' -> word "null" Null
    | '[' ->
      incr i;
      ws ();
      if peek () = ']' && !i < e then (incr i; Arr [])
      else begin
        let l = ref [ value (depth + 1) ] in
        ws ();
        while peek () = ',' && !i < e do incr i; l := value (depth + 1) :: !l; ws () done;
        expect ']';
        Arr (List.rev !l)
      end
    | '{' -> Obj (members depth)
    | '-' | '0' .. '9' -> num ()
    | c -> bad "%C at byte %d" c (!i - o + 1)
  and members depth =
    expect '{';
    ws ();
    if peek () = '}' && !i < e then (incr i; [])
    else begin
      let one () = ws (); let k = str () in ws (); expect ':'; let v = value (depth + 1) in ws (); k, v in
      let l = ref [ one () ] in
      while peek () = ',' && !i < e do incr i; l := one () :: !l done;
      expect '}';
      List.rev !l
    end
  in
  let v = value 0 in
  ws ();
  if !i < e then bad "something after the value at byte %d" (!i - o + 1);
  v

(* a record of JSON lines: an object, its keys and values in order *)
let json_object b o e =
  match json_value b o e with
  | Obj m -> m
  | _ -> bad "a line of JSON lines here holds an object: {\"Field\": value, ...}"

(* a JSON string of s (UTF-8, checked by the caller): quote, backslash and the control characters escaped *)
let json_add buf s =
  Buffer.add_char buf '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | c when Char.code c < 0x20 -> Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char buf c)
    s;
  Buffer.add_char buf '"'
