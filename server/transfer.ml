(* `cepheus import` and `cepheus export`: the things of a kind from a file and back, through the server with a token, as
   any program reaches a database (never by opening the files of a live database).

   Import. The file is read twice. The first pass checks every row: its fields against the kind declared in the
   database (a column of the header, or a key of JSON lines, names a field), each value against the field's type, the
   links found by their key in the database, the unique values against the database and against the file's other
   rows. A bad row stops the import before anything is written, with its line and the reason (--skip-bad: the good
   rows are written and the bad ones listed). The second pass reads the file again and writes it in groups of at most
   [group_ops] operations and [group_bytes] of request, each the large-group path of the database (Resolve, 20,000
   operations and more), from a thread of its own on a connection of its own, while domains parse the rows that come
   next. An import that fits one group is all or nothing, the rules' constraints included; a larger one, checked
   whole first, is refused by the database only for what the first pass cannot see (a constraint of a rule, or a write
   of another program meanwhile): then it stops at that group and names the lines written before it.

   The first pass keeps, for the unique fields, 8 bytes a value: a hash of 30 bits and the row's number, in a table
   of open addressing (Knuth, TAOCP vol. 3, 6.4, linear probing at most 3/4 full); two values of one hash are told
   apart by reading the earlier row again (every 1,024th row's offset is kept), so the check is exact. Everything
   else is bounded whatever the file's size: a few batches of rows at once, two groups in flight.

   Export. Every thing of the kind at one state of the database, the group named on stderr: the asserted facts of
   its fields (what the rules derive comes back from the rules of the database the export is loaded into), the
   things by id, the links as the key of the thing linked. It reads one view in this process (the server's follow
   stream, over its Unix socket), which never changes while it is read, by several domains. *)

open Cepheus
module T = Tabular

exception Stop of string

let stop fmt = Printf.ksprintf (fun m -> raise (Stop m)) fmt

(* ---- the kind ---- *)

(* how a link is written in a file: the key of the thing linked (a unique field of one value), or its id *)
type link = Key of { prop : int; ktyp : Value.typ; kname : string } | Id

type field = {
  name : string;  (* Name *)
  pname : string;  (* client/Name *)
  prop : int;
  typ : Value.typ;
  many : bool;
  unique : bool;
  link : link;  (* for a link field; Id for the others, unused *)
}

let kind_props kind props =
  let pre = kind ^ "/" in
  List.sort compare
    (List.filter (fun (_, (d : Schema.prop)) -> String.length d.name > String.length pre && String.starts_with ~prefix:pre d.name) props)

let key_ok (d : Schema.prop) = d.unique && (not d.many) && d.typ <> Value.Tlink

(* the link spec of field [f] of a kind: --link F=kind/Key or F=id; by default the kind named as the field in small
   letters, by its one unique field *)
let link_of props fname spec =
  match spec with
  | Some "id" -> Id
  | Some s -> (
    match List.find_opt (fun (_, (d : Schema.prop)) -> d.name = s) props with
    | Some (p, d) when key_ok d -> Key { prop = p; ktyp = d.typ; kname = s }
    | Some _ -> stop "--link %s=%s: %s is not a unique field of one value (a key)" fname s s
    | None -> stop "--link %s=%s: the database has no property %s" fname s s)
  | None -> (
    let k = String.lowercase_ascii fname in
    match List.filter (fun (_, (d : Schema.prop)) -> key_ok d && String.starts_with ~prefix:(k ^ "/") d.name) props with
    | [ (p, d) ] -> Key { prop = p; ktyp = d.typ; kname = d.name }
    | [] ->
      stop "%s links things, and the database has no kind %s with a unique field to find them by: say how with --link %s=KIND/FIELD (a unique field of the things linked), or --link %s=id for their ids"
        fname k fname fname
    | l ->
      stop "%s links things of %s, which has several unique fields (%s): name one with --link %s=KIND/FIELD" fname k
        (String.concat ", " (List.map (fun (_, (d : Schema.prop)) -> d.name) l)) fname)

let fields_of props kind links =
  let ks = kind_props kind props in
  if ks = [] then stop "the database has no kind %s (no property %s/...)" kind kind;
  List.iter
    (fun (f, _) ->
      match List.find_opt (fun (_, (d : Schema.prop)) -> d.name = kind ^ "/" ^ f) ks with
      | None -> stop "--link %s: %s has no field %s" f kind f
      | Some (_, d) when d.typ <> Value.Tlink -> stop "--link %s: %s/%s is not a link (a %s)" f kind f (Value.typ_name d.typ)
      | Some _ -> ())
    links;
  Array.of_list
    (List.map
       (fun (p, (d : Schema.prop)) ->
         let name = String.sub d.name (String.length kind + 1) (String.length d.name - String.length kind - 1) in
         let link = if d.typ = Value.Tlink then link_of props name (List.assoc_opt name links) else Id in
         { name; pname = d.name; prop = p; typ = d.typ; many = d.many; unique = d.unique; link })
       ks)

(* ---- values from the file ---- *)

let wrap f x = try f x with T.Bad m -> T.bad "%s" m

let id_of s =
  let n = T.int_of_text s in
  if n < Schema.first_thing || n > Schema.last_thing then T.bad "%s is not the id of a thing (%d to %d)" s Schema.first_thing Schema.last_thing;
  Value.Link n

(* a value of a field of type [typ] from its text in a CSV field *)
let of_text typ s : Value.t =
  match typ with
  | Value.Ttext -> T.check_text s; Text s
  | Tint -> Int (T.int_of_text s)
  | Tfloat -> Float (T.float_of_text s)
  | Tbool -> Bool (T.bool_of_text s)
  | Tdate -> Date (T.date_of_text s)
  | Tmoney sc -> Money (T.money_of_text sc s)
  | Tlink -> id_of s

let of_json typ (j : T.json) : Value.t =
  let want what = T.bad "%s, not %s" what (match j with T.Null -> "null" | Bool _ -> "true or false" | Num n -> n | Str _ -> "a string" | Arr _ -> "a list" | Obj _ -> "an object") in
  match typ, j with
  | Value.Ttext, Str s -> Text s
  | Ttext, _ -> want "a string"
  | Tint, Num n -> Int (T.int_of_text n)
  | Tint, _ -> want "a whole number"
  | Tfloat, Num n -> Float (float_of_string n)
  | Tfloat, Str s when List.mem s [ "NaN"; "Infinity"; "-Infinity" ] -> Float (T.float_of_text s)
  | Tfloat, _ -> want "a number"
  | Tbool, Bool b -> Bool b
  | Tbool, _ -> want "true or false"
  | Tdate, Str s -> Date (T.date_of_text s)
  | Tdate, _ -> want "a date in a string (\"2026-11-24T10:30:00Z\")"
  | Tmoney sc, Num n -> Money (T.money_of_text sc n)
  | Tmoney _, _ -> want "an amount (a number)"
  | Tlink, Num n -> id_of n
  | Tlink, _ -> want "the id of a thing"

(* a link's own value from the file: the key, of the key's type, or the id *)
let scalar_text f s = match f.typ, f.link with Value.Tlink, Key k -> of_text k.ktyp s | _ -> of_text f.typ s
let scalar_json f j = match f.typ, f.link with Value.Tlink, Key k -> of_json k.ktyp j | _ -> of_json f.typ j

let distinct l = List.sort_uniq Value.compare l

let cell_text f s =
  try
    if f.many then
      match T.json_value (Bytes.unsafe_of_string s) 0 (String.length s) with
      | T.Arr l -> distinct (List.map (scalar_json f) l)
      | _ -> T.bad "a field of several values holds a JSON list ([\"a\", \"b\"])"
      | exception T.Bad m -> T.bad "a field of several values holds a JSON list ([\"a\", \"b\"]): %s" m
    else [ scalar_text f s ]
  with T.Bad m -> T.bad "%s: %s" f.name m

let cell_json f (j : T.json) =
  try
    match j with
    | T.Null -> []
    | Arr l -> if f.many then distinct (List.map (scalar_json f) l) else T.bad "one value, not a list"
    | j -> if f.many then T.bad "a list of values ([...]), the field holds several" else [ scalar_json f j ]
  with T.Bad m -> T.bad "%s: %s" f.name m

(* ---- the import ---- *)

type options = {
  file : string;
  kind : string;
  format : T.format;
  maps : (string * string) list;  (* column or key -> field, "" to leave it out *)
  links : (string * string) list;  (* field -> kind/Key or id *)
  skip_bad : bool;
  upsert : bool;
  why : string;
}

let format_of_file f =
  match String.lowercase_ascii (Filename.extension f) with
  | ".csv" -> Some T.Csv
  | ".jsonl" | ".ndjson" -> Some T.Jsonl
  | _ -> None

type row = {
  line : int;
  index : int;  (* among the file's records, the header aside *)
  cells : Value.t list array;  (* by field: its values (none: empty); a link's keys until they are found *)
  mutable bad : string option;
  mutable target : int;  (* --upsert: the thing found by its unique values; 0: a new thing *)
}

(* a group: at most this many operations, and this many bytes of their coding in the request (Wire.put_op; a frame
   holds 16 MiB, the request's other fields and the receipt's room aside) *)
let group_ops = ref 1_000_000
let group_bytes = ref (15 lsl 20)

(* the bytes of a varint, of an int in zigzag (Codec.put_int), of a value (Value.encode), of an Add (Wire.put_op) *)
let varint_size n = if n < 0 then 9 else (let rec go n k = if n < 0x80 then k else go (n lsr 7) (k + 1) in go n 1)
let int_size n = varint_size ((n lsl 1) lxor (n asr 62))

let value_size (x : Value.t) =
  match x with
  | Int n | Date n | Money n | Link n -> 1 + int_size n
  | Float _ -> 9
  | Bool _ -> 1
  | Text s -> 1 + varint_size (String.length s) + String.length s

let add_size e p x = 1 + int_size e + varint_size p + value_size x

(* the bytes of a batch of records parsed at once by a domain, and the batches of a round *)
let batch_bytes = ref (1 lsl 20)
let round () = 2 * !Bulk.domains

(* what the header's names, or JSON's keys, are: a field's index, or -1 to leave out *)
let resolver fields maps =
  let exact = Hashtbl.create 16 and lower = Hashtbl.create 16 in
  Array.iteri
    (fun i f ->
      Hashtbl.replace exact f.name i;
      let l = String.lowercase_ascii f.name in
      Hashtbl.replace lower l (if Hashtbl.mem lower l then -2 else i))
    fields;
  let names () = String.concat ", " (Array.to_list (Array.map (fun f -> f.name) fields)) in
  List.iter (fun (_, f) -> if f <> "" && not (Hashtbl.mem exact f) then stop "--map: the kind has no field %s (its fields: %s)" f (names ())) maps;
  fun col ->
    match List.assoc_opt col maps with
    | Some "" -> Ok (-1)
    | Some f -> Ok (Hashtbl.find exact f)
    | None -> (
      match Hashtbl.find_opt exact col with
      | Some i -> Ok i
      | None -> (
        match Hashtbl.find_opt lower (String.lowercase_ascii col) with
        | Some i when i >= 0 -> Ok i
        | _ -> Error (Printf.sprintf "%S is no field of the kind (its fields: %s): --map %s=FIELD, or --map %s= to leave it out" col (names ()) col col)))

type ctx = {
  fmt : T.format;
  fields : field array;
  cols : int array;  (* CSV: the field of each column, -1: left out *)
  key : string -> (int, string) result;  (* JSON lines: the field of a key *)
}

let parse_record ctx (b : T.batch) k =
  let line = b.lines.(k) and index = b.index + k in
  let row = { line; index; cells = Array.make (Array.length ctx.fields) []; bad = None; target = 0 } in
  (try
     match ctx.fmt with
     | T.Csv ->
       let fs = T.csv_fields b.data b.starts.(k) b.stops.(k) in
       if Array.length fs <> Array.length ctx.cols then T.bad "%d fields, the header has %d" (Array.length fs) (Array.length ctx.cols);
       Array.iteri
         (fun c (x : T.field) ->
           let i = ctx.cols.(c) in
           if i >= 0 && (x.quoted || x.text <> "") then row.cells.(i) <- cell_text ctx.fields.(i) x.text)
         fs
     | T.Jsonl ->
       let seen = Array.make (Array.length ctx.fields) false in
       List.iter
         (fun (key, j) ->
           match ctx.key key with
           | Error m -> T.bad "%s" m
           | Ok -1 -> ()
           | Ok i ->
             if seen.(i) then T.bad "%s twice" ctx.fields.(i).name;
             seen.(i) <- true;
             row.cells.(i) <- cell_json ctx.fields.(i) j)
         (T.json_object b.data b.starts.(k) b.stops.(k))
   with T.Bad m -> row.bad <- Some m);
  row

let parse_batch ctx b = Array.init (Array.length b.T.starts) (parse_record ctx b)

(* the rows of a round: [round ()] batches read, then parsed by the domains *)
let read_round ctx r on_batch =
  let bs = ref [] and fin = ref false in
  for _ = 1 to round () do
    if not !fin then begin
      let b = T.next r !batch_bytes in
      if Array.length b.starts = 0 then fin := true else (on_batch b; bs := b :: !bs)
    end
  done;
  let bs = Array.of_list (List.rev !bs) in
  let out = Array.make (Array.length bs) [||] in
  Bulk.parallel (Array.length bs) (fun i -> out.(i) <- parse_batch ctx bs.(i));
  Array.concat (Array.to_list out)

(* ---- texts of values, for the files and the messages ---- *)

(* a value's text of a field of type [typ] (a link: its id, the caller writes its key) *)
let text_of typ (x : Value.t) =
  match typ, x with
  | _, Value.Int n -> string_of_int n
  | _, Float f -> T.float_text f
  | _, Bool b -> if b then "true" else "false"
  | _, Text s -> s
  | _, Date d -> T.date_text d
  | Value.Tmoney sc, Money u -> T.money_text sc u
  | _, Money u -> string_of_int u
  | _, Link t -> string_of_int t

let show f (x : Value.t) =
  match f.link, x with
  | Key k, (Text _ | Int _ | Date _ | Money _ | Bool _ | Float _) -> Printf.sprintf "%s %s" k.kname (match x with Text s -> Printf.sprintf "%S" s | _ -> text_of k.ktyp x)
  | _, Text s -> Printf.sprintf "%S" s
  | _, Link t -> Printf.sprintf "#%d" t
  | _ -> (try text_of f.typ x with T.Bad _ -> Value.to_string x)

(* ---- lookups in the database ---- *)

(* the things that hold each of [values] for [prop] (a unique property: one at most), by questions with In of
   10,000 values: [find prop values] gives the pairs (thing, value) *)
let in_max = 10_000

let holders find prop (values : Value.t list) =
  let tbl = Hashtbl.create 1024 in
  let rec go l =
    match l with
    | [] -> ()
    | _ ->
      let rec cut k acc = function x :: r when k < in_max -> cut (k + 1) (x :: acc) r | r -> acc, r in
      let chunk, rest = cut 0 [] l in
      List.iter (fun (t, v) -> Hashtbl.replace tbl v t) (find prop chunk);
      go rest
  in
  go values;
  tbl

let good r = r.bad = None

(* a link's keys of good rows found in the database: each key becomes its thing's link; a key no thing holds makes
   the row bad *)
let resolve_links find fields rows =
  Array.iteri
    (fun i f ->
      match f.typ, f.link with
      | Value.Tlink, Key k ->
        let keys = Hashtbl.create 1024 in
        Array.iter (fun r -> if good r then List.iter (fun v -> Hashtbl.replace keys v ()) r.cells.(i)) rows;
        if Hashtbl.length keys > 0 then begin
          let found = holders find k.prop (Hashtbl.fold (fun v () l -> v :: l) keys []) in
          Array.iter
            (fun r ->
              if good r && r.cells.(i) <> [] then
                match List.find_opt (fun v -> not (Hashtbl.mem found v)) r.cells.(i) with
                | Some v -> r.bad <- Some (Printf.sprintf "%s: no thing has %s (the things linked must be in the database first)" f.name (show f v))
                | None -> r.cells.(i) <- distinct (List.map (fun v -> Value.Link (Hashtbl.find found v)) r.cells.(i)))
            rows
        end
      | _ -> ())
    fields

(* the unique values of good rows against the database: taken (an import of new things), or the thing they find
   (--upsert: one thing, whose fields the row's values replace) *)
let check_unique find fields ~upsert rows =
  Array.iteri
    (fun i f ->
      if f.unique then begin
        let vs = Hashtbl.create 1024 in
        Array.iter (fun r -> if good r then List.iter (fun v -> Hashtbl.replace vs v ()) r.cells.(i)) rows;
        if Hashtbl.length vs > 0 then begin
          let tbl = holders find f.prop (Hashtbl.fold (fun v () l -> v :: l) vs []) in
          Array.iter
            (fun r ->
              if good r then
                List.iter
                  (fun v ->
                    match Hashtbl.find_opt tbl v with
                    | None -> ()
                    | Some t when not upsert -> if good r then r.bad <- Some (Printf.sprintf "%s %s is taken by #%d (--upsert changes the thing found)" f.name (show f v) t)
                    | Some t ->
                      if r.target = 0 then r.target <- t
                      else if r.target <> t && good r then
                        r.bad <- Some (Printf.sprintf "%s %s is #%d's, and another unique value of the row is #%d's" f.name (show f v) t r.target))
                  r.cells.(i))
            rows
        end
      end)
    fields;
  if upsert then
    Array.iter
      (fun r ->
        if good r && r.target <> 0 then
          Array.iteri (fun i f -> if f.many && r.cells.(i) <> [] && good r then r.bad <- Some (Printf.sprintf "%s holds several values, which --upsert does not change (#%d)" f.name r.target)) fields)
      rows

(* ---- unique values within the file: a table of hashes and rows ---- *)

module Seen = struct
  open Bigarray

  (* a slot: 0 empty, else the hash (30 bits) shifted by 32 and the row's index plus 1 *)
  type t = { mutable a : Bulk.ints; mutable n : int; mutable mask : int }

  let make n = let a = Bulk.ints n in Array1.fill a 0; a
  let create () = { a = make 4096; n = 0; mask = 4095 }
  let pos t h = (h * 0x9E3779B1) land t.mask

  let put t s =
    let i = ref (pos t (s lsr 32)) in
    while Array1.unsafe_get t.a !i <> 0 do i := (!i + 1) land t.mask done;
    Array1.unsafe_set t.a !i s

  let add t h index =
    if index >= 0xFFFF_FFFF then stop "a file of more than 4,294,967,294 rows with unique fields";
    if 4 * (t.n + 1) > 3 * (t.mask + 1) then begin
      let old = t.a in
      t.a <- make (2 * (t.mask + 1));
      t.mask <- (2 * (t.mask + 1)) - 1;
      for i = 0 to Array1.dim old - 1 do let s = Array1.unsafe_get old i in if s <> 0 then put t s done
    end;
    put t ((h lsl 32) lor (index + 1));
    t.n <- t.n + 1

  (* the rows with hash h *)
  let iter t h f =
    let i = ref (pos t h) in
    while Array1.unsafe_get t.a !i <> 0 do
      let s = Array1.unsafe_get t.a !i in
      if s lsr 32 = h then f ((s land 0xFFFF_FFFF) - 1);
      i := (!i + 1) land t.mask
    done

  let bytes t = 8 * (t.mask + 1)
end

let hash30 prop (v : Value.t) = Hashtbl.hash (prop, v) land 0x3FFF_FFFF

(* ---- the writer: groups written in turn from a thread of its own ---- *)

type job = { ops : Resolve.op list; first : int; last : int; nrows : int; nops : int }

type writer = {
  m : Mutex.t;
  c : Condition.t;
  q : job option Queue.t;  (* None: the end *)
  mutable failed : (job * string) option;
  mutable groups : (int * job) list;  (* written: the group's number, newest first *)
  mutable thread : Thread.t option;
  mutable waited : float;  (* seconds in the writes, their answers waited for *)
}

let writer write =
  let w = { m = Mutex.create (); c = Condition.create (); q = Queue.create (); failed = None; groups = []; thread = None; waited = 0. } in
  let rec loop () =
    let j = Mutex.protect w.m (fun () -> while Queue.is_empty w.q do Condition.wait w.c w.m done; let j = Queue.pop w.q in Condition.broadcast w.c; j) in
    match j with
    | None -> ()
    | Some j -> (
      let t = Unix.gettimeofday () in
      let r = write j.ops in
      w.waited <- w.waited +. (Unix.gettimeofday () -. t);
      match r with
      | Ok g -> Mutex.protect w.m (fun () -> w.groups <- (g, j) :: w.groups); loop ()
      | Error m -> Mutex.protect w.m (fun () -> w.failed <- Some (j, m); Condition.broadcast w.c))
  in
  w.thread <- Some (Thread.create loop ());
  w

(* a group to write: it waits while one waits already (two in flight at most), and says whether the writer failed *)
let submit w j =
  Mutex.protect w.m (fun () ->
      while Queue.length w.q >= 1 && w.failed = None do Condition.wait w.c w.m done;
      if w.failed = None then (Queue.push j w.q; Condition.broadcast w.c));
  w.failed = None

let finish w =
  Mutex.protect w.m (fun () -> Queue.push None w.q; Condition.broadcast w.c);
  Option.iter Thread.join w.thread

(* ---- the import ---- *)

type summary = {
  rows : int;  (* good rows *)
  left_out : int;  (* bad rows, --skip-bad *)
  empty : int;  (* rows without a value: nothing to write *)
  inserted : int;
  updated : int;
  facts : int;  (* operations written *)
  groups : (int * int * int) list;  (* each group's number and its first and last line, in order *)
  check_s : float;
  write_s : float;
  server_s : float;  (* of write_s, the writes sent and answered *)
  seen_bytes : int;  (* the table of unique values at its largest *)
}

(* [find prop values]: the (thing, value) pairs of prop for these values; [write ops]: a group written, its number;
   [props]: the database's properties; [say]: a line for stderr *)
let import ~props ~find ~write ~say (o : options) =
  let fields = fields_of props o.kind o.links in
  let fd = try Unix.openfile o.file [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 with Unix.Unix_error (e, _, _) -> stop "%s: %s" o.file (Unix.error_message e) in
  Fun.protect ~finally:(fun () -> Unix.close fd) @@ fun () ->
  let st0 = Unix.fstat fd in
  if st0.st_kind <> Unix.S_REG then stop "%s is not a file: an import reads its file twice (checked whole, then written)" o.file;
  let unchanged () = let st = Unix.fstat fd in st.st_size = st0.st_size && st.st_mtime = st0.st_mtime in
  let resolve = resolver fields o.maps in
  if o.upsert && not (Array.exists (fun f -> f.unique) fields) then stop "--upsert finds a thing by a unique field, and %s has none" o.kind;
  (* the header: the field of each column *)
  let open_reader () =
    ignore (Unix.lseek fd 0 Unix.SEEK_SET);
    let r = T.reader o.format fd in
    match o.format with
    | T.Jsonl -> r, [||]
    | T.Csv ->
      let h = T.next r 1 in
      if Array.length h.starts = 0 then stop "%s is empty: a CSV file starts with its header (the names of its columns)" o.file;
      let names = try T.csv_fields h.data h.starts.(0) h.stops.(0) with T.Bad m -> stop "%s line 1, the header: %s" o.file m in
      let cols =
        Array.map
          (fun (x : T.field) ->
            (try T.check_text x.text with T.Bad m -> stop "%s line 1, the header: %s" o.file m);
            match resolve x.text with Ok i -> i | Error m -> stop "%s line 1: the column %s" o.file m)
          names
      in
      Array.iteri (fun c i -> Array.iteri (fun c' i' -> if c' > c && i >= 0 && i = i' then stop "%s line 1: two columns give %s" o.file fields.(i).name) cols) cols;
      List.iter (fun (col, _) -> if not (Array.exists (fun (x : T.field) -> x.text = col) names) then stop "--map %s: the header has no column %s" col col) o.maps;
      r, cols
  in
  let ctx cols = { fmt = o.format; fields; cols; key = resolve } in
  let base = Filename.basename o.file in
  (* pass 1: every row checked *)
  let t0 = Unix.gettimeofday () in
  let r, cols = open_reader () in
  let ctx = ctx cols in
  (* every 1,024th record's offset and line: the first at the file's start, line 1 *)
  let marks = ref (Array.make 64 (0, 1)) in
  let mark (b : T.batch) =
    Array.iteri
      (fun k s ->
        let i = b.index + k in
        if i land 1023 = 0 then begin
          let m = i lsr 10 in
          if m >= Array.length !marks then (let a = Array.make (2 * m + 1) (0, 0) in Array.blit !marks 0 a 0 (Array.length !marks); marks := a);
          !marks.(m) <- (b.off + s, b.lines.(k))
        end)
      b.starts
  in
  (* an earlier row, read again from the file (its links found again) *)
  let fd2 = lazy (Unix.openfile o.file [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0) in
  let fetch k =
    let m = k lsr 10 in
    let off, line = !marks.(m) in
    let fd2 = Lazy.force fd2 in
    ignore (Unix.lseek fd2 off Unix.SEEK_SET);
    let r = T.reader ~off ~line ~index:(m lsl 10) o.format fd2 in
    let rec go () =
      let b = T.next r 65536 in
      if Array.length b.starts = 0 then stop "%s changed during the import" o.file;
      if k < b.index + Array.length b.starts then parse_record ctx b (k - b.index) else go ()
    in
    let row = go () in
    resolve_links find fields [| row |];
    row
  in
  let seen = Seen.create () in
  let uniques = List.filter (fun i -> fields.(i).unique) (List.init (Array.length fields) Fun.id) in
  let bads = ref [] and nbad = ref 0 and nrows = ref 0 and seen_max = ref 0 in
  let report (row : row) m =
    if o.skip_bad then begin
      incr nbad;
      bads := row.index :: !bads;
      say (Printf.sprintf "%s line %d: %s (left out)" base row.line m)
    end
    else stop "%s line %d: %s; nothing was written" base row.line m
  in
  (try
     let fin = ref false in
     while not !fin do
       let rows = read_round ctx r mark in
       if Array.length rows = 0 then fin := true
       else begin
         resolve_links find fields rows;
         check_unique find fields ~upsert:o.upsert rows;
         (* within the file, in the order of the rows: a row's unique values against those of the good rows before *)
         let first = rows.(0).index in
         Array.iter
           (fun row ->
             if good row && uniques <> [] then begin
               List.iter
                 (fun i ->
                   let f = fields.(i) in
                   List.iter
                     (fun v ->
                       if good row then
                         Seen.iter seen (hash30 f.prop v) (fun j ->
                             if good row then begin
                               let other = if j >= first then rows.(j - first) else fetch j in
                               if List.exists (Value.equal v) other.cells.(i) then
                                 row.bad <- Some (Printf.sprintf "%s %s is on line %d too" f.name (show f v) other.line)
                             end))
                     row.cells.(i))
                 uniques;
               if good row then List.iter (fun i -> List.iter (fun v -> Seen.add seen (hash30 fields.(i).prop v) row.index) row.cells.(i)) uniques
             end)
           rows;
         seen_max := max !seen_max (Seen.bytes seen);
         Array.iter (fun row -> match row.bad with Some m -> report row m | None -> incr nrows) rows
       end
     done
   with T.Bad m -> stop "%s: %s; nothing was written" base m);
  if Lazy.is_val fd2 then Unix.close (Lazy.force fd2);
  let t1 = Unix.gettimeofday () in
  say (Printf.sprintf "%s: %d rows checked in %.2f s%s" base !nrows (t1 -. t0) (if !nbad > 0 then Printf.sprintf ", %d left out" !nbad else ""));
  if not (unchanged ()) then stop "%s changed during the import; nothing was written" o.file;
  (* pass 2: the rows written *)
  let bads = ref (List.rev !bads) in
  let r, _ = open_reader () in
  let w = writer write in
  let ops = ref [] and nops = ref 0 and bytes = ref 0 and temp = ref 0 and gfirst = ref 0 and glast = ref 0 and grows = ref 0 in
  let empty = ref 0 and inserted = ref 0 and updated = ref 0 and facts = ref 0 in
  let flush () =
    if !ops <> [] then begin
      if not (submit w (Some { ops = List.rev !ops; first = !gfirst; last = !glast; nrows = !grows; nops = !nops })) then raise Exit;
      ops := []; nops := 0; bytes := 0; temp := 0; grows := 0
    end
  in
  let outcome =
    try
      let fin = ref false in
      while not !fin do
        let rows = read_round ctx r ignore in
        if Array.length rows = 0 then fin := true
        else begin
          Array.iter
            (fun row ->
              let rec skip () = match !bads with i :: rest when i < row.index -> bads := rest; skip () | i :: rest when i = row.index -> bads := rest; true | _ -> false in
              if skip () then row.bad <- Some "left out")
            rows;
          resolve_links find fields rows;
          if o.upsert then check_unique find fields ~upsert:true rows;
          Array.iter
            (fun row ->
              match row.bad with
              | Some "left out" -> ()
              | Some m -> stop "%s line %d: %s (it changed in the database since the check)" base row.line m
              | None ->
                if Array.for_all (fun l -> l = []) row.cells then incr empty
                else begin
                  let n = Array.fold_left (fun n l -> n + List.length l) 0 row.cells in
                  (* its thing: a new one numbered in the group it goes to *)
                  let size e = Array.fold_left (fun b l -> List.fold_left (fun b x -> b + add_size e 65535 x) b l) 0 row.cells in
                  if !nops > 0 && (!nops + n > !group_ops || !bytes + size (if row.target <> 0 then row.target else !temp - 1) > !group_bytes) then flush ();
                  let e = if row.target <> 0 then (incr updated; row.target) else (decr temp; incr inserted; !temp) in
                  let b = size e in
                  if !grows = 0 then gfirst := row.line;
                  glast := row.line;
                  incr grows;
                  Array.iteri (fun i l -> List.iter (fun x -> ops := Resolve.Add (e, fields.(i).prop, x) :: !ops) l) row.cells;
                  nops := !nops + n;
                  facts := !facts + n;
                  bytes := !bytes + b
                end)
            rows
        end
      done;
      flush ();
      Ok ()
    with
    | Exit -> Ok ()
    | Stop m -> Error m
    | T.Bad m -> Error (Printf.sprintf "%s: %s" base m)
  in
  finish w;
  let t2 = Unix.gettimeofday () in
  let groups = List.rev_map (fun (g, j) -> g, j.first, j.last) w.groups in
  let written () =
    match groups with
    | [] -> "nothing was written"
    | (g0, l0, _) :: _ ->
      let gn, _, ln = List.nth groups (List.length groups - 1) in
      Printf.sprintf "written before it: lines %d to %d, in group%s %d%s" l0 ln (if gn = g0 then "" else "s") g0 (if gn = g0 then "" else Printf.sprintf " to %d" gn)
  in
  (match w.failed, outcome with
   | Some (j, m), _ -> stop "%s lines %d to %d: the database refused their group: %s; %s" base j.first j.last m (written ())
   | None, Error m -> stop "%s; %s" m (written ())
   | None, Ok () -> ());
  if not (unchanged ()) then say (Printf.sprintf "%s changed during the import: what was written is what it held during the check" base);
  { rows = !nrows; left_out = !nbad; empty = !empty; inserted = !inserted; updated = !updated; facts = !facts; groups; check_s = t1 -. t0; write_s = t2 -. t1; server_s = w.waited; seen_bytes = !seen_max }

(* ---- the export ---- *)

type export = { ekind : string; eformat : T.format; elinks : (string * string) list }

type exported = { things : int; efacts : int; group : int; seconds : float }

(* things a part, formatted by a domain each *)
let part = 8192

let export (v : Store.view) (o : export) (out : string -> unit) =
  let t0 = Unix.gettimeofday () in
  let props = List.filter_map (fun p -> Option.map (fun d -> p, d) (Schema.find v.schema p)) (List.init (Schema.count v.schema) Fun.id) in
  let fields = fields_of props o.ekind o.elinks in
  (* the things of the kind: those with a fact of one of its fields *)
  let n = Store.max_thing v + 1 in
  let bits = Bytes.make ((n lsr 3) + 1) '\000' in
  Array.iter (fun f -> Store.iter_prop v f.prop (fun e _ -> if e >= 0 && e < n then Bytes.unsafe_set bits (e lsr 3) (Char.unsafe_chr (Char.code (Bytes.unsafe_get bits (e lsr 3)) lor (1 lsl (e land 7)))))) fields;
  let asserted e p typ =
    let l = ref [] in
    Store.iter_values_st v e p (fun w st -> if st = 1 then l := Store.value v typ w :: !l);
    List.sort Value.compare !l
  in
  let text e f x =
    match f.typ, f.link, x with
    | Value.Tlink, Key k, Value.Link t -> (
      match asserted t k.prop k.ktyp with
      | y :: _ -> k.ktyp, y
      | [] -> stop "#%d's %s links #%d, which has no %s: --link %s=id writes the ids" e f.name t k.kname f.name)
    | _ -> f.typ, x
  in
  let check e f s = match T.bad_utf8 s 0 (String.length s) with -1 -> () | _ -> stop "#%d's %s holds a NUL byte or bytes that are not UTF-8, which CSV and JSON lines do not carry" e f.name in
  let json buf typ (x : Value.t) =
    match x with
    | Int _ | Money _ | Link _ -> Buffer.add_string buf (text_of typ x)
    | Float f when Float.is_finite f -> Buffer.add_string buf (T.float_text f)
    | Bool b -> Buffer.add_string buf (if b then "true" else "false")
    | Float _ | Text _ | Date _ -> T.json_add buf (text_of typ x)
  in
  let one buf e =
    let vals = Array.map (fun f -> asserted e f.prop f.typ) fields in
    if Array.for_all (fun l -> l = []) vals then 0
    else begin
      let count = ref 0 in
      let render f x =
        let typ, y = text e f x in
        (match y with Value.Text s -> check e f s | _ -> ());
        typ, y
      in
      (match o.eformat with
       | T.Csv ->
         Array.iteri
           (fun i f ->
             if i > 0 then Buffer.add_char buf ',';
             match vals.(i) with
             | [] -> ()
             | l when f.many ->
               let b = Buffer.create 64 in
               Buffer.add_char b '[';
               List.iteri (fun j x -> if j > 0 then Buffer.add_char b ','; let typ, y = render f x in json b typ y; incr count) l;
               Buffer.add_char b ']';
               T.csv_add buf (Buffer.contents b)
             | x :: _ -> let typ, y = render f x in incr count; T.csv_add buf (text_of typ y))
           fields;
         Buffer.add_string buf "\r\n"
       | T.Jsonl ->
         Buffer.add_char buf '{';
         let first = ref true in
         Array.iteri
           (fun i f ->
             match vals.(i) with
             | [] -> ()
             | l ->
               if not !first then Buffer.add_char buf ',';
               first := false;
               T.json_add buf f.name;
               Buffer.add_char buf ':';
               if f.many then begin
                 Buffer.add_char buf '[';
                 List.iteri (fun j x -> if j > 0 then Buffer.add_char buf ','; let typ, y = render f x in json buf typ y; incr count) l;
                 Buffer.add_char buf ']'
               end
               else (let typ, y = render f (List.hd l) in incr count; json buf typ y))
           fields;
         Buffer.add_string buf "}\n");
      !count
    end
  in
  (try
     if o.eformat = T.Csv then begin
       let b = Buffer.create 256 in
       Array.iteri (fun i f -> if i > 0 then Buffer.add_char b ','; T.csv_add b f.name) fields;
       Buffer.add_string b "\r\n";
       out (Buffer.contents b)
     end;
     let things = ref 0 and facts = ref 0 in
     let next = ref 0 in
     let k = round () in
     while !next < n do
       (* the next k parts of things, formatted at once, written in order *)
       let parts = Array.make k [||] in
       let np = ref 0 in
       while !np < k && !next < n do
         let ids = ref [] and c = ref 0 in
         while !c < part && !next < n do
           let e = !next in
           if Char.code (Bytes.unsafe_get bits (e lsr 3)) land (1 lsl (e land 7)) <> 0 then (ids := e :: !ids; incr c);
           incr next
         done;
         if !ids <> [] then (parts.(!np) <- Array.of_list (List.rev !ids); incr np)
       done;
       let bufs = Array.init !np (fun _ -> Buffer.create (1 lsl 16)) and counts = Array.make !np (0, 0) in
       Bulk.parallel !np (fun i ->
           let t = ref 0 and f = ref 0 in
           Array.iter (fun e -> let c = one bufs.(i) e in if c > 0 then (incr t; f := !f + c)) parts.(i);
           counts.(i) <- !t, !f);
       Array.iteri (fun i b -> out (Buffer.contents b); let t, f = counts.(i) in things := !things + t; facts := !facts + f) bufs
     done;
     { things = !things; efacts = !facts; group = v.group; seconds = Unix.gettimeofday () -. t0 }
   with
   | T.Bad m -> stop "%s" m
   | Pages.Unreadable m -> stop "the database is damaged: %s" m)

(* ---- through a client of the protocol (the command, the tests) ---- *)

(* the import on two connections to one database: [r] reads (its local view when it is followed), [w] writes *)
let import_client ~say (r, rdb) (w, wdb) (o : options) =
  let find prop values =
    let q = { Query.vars = 2; where = [ { e = Var 0; p = prop; v = Var 1 } ]; ranges = [] } in
    match Client.find r rdb ~select:(Wire.Give [| 0; 1 |]) ~extra:[ Question.In (1, values) ] q with
    | Ok (_, rows) -> List.filter_map (fun row -> match row with [| Value.Link t; v |] -> Some (t, v) | _ -> None) rows
    | Error e -> stop "the server: %s: %s" e.code e.message
  in
  let write ops = match Client.write w wdb ~why:o.why ops with Ok (rc : Engine.receipt) -> Ok rc.group | Error e -> Error (e.code ^ ": " ^ e.message) in
  import ~props:rdb.Client.props ~find ~write ~say o
