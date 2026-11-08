type kind = Retracted | Added | Derived | Underived | Now_asserted | Now_derived

type change = { kind : kind; e : int; p : int; v : Value.t }

let code = function Retracted -> 0 | Added -> 1 | Derived -> 2 | Underived -> 3 | Now_asserted -> 4 | Now_derived -> 5

let of_code = function
  | 0 -> Some Retracted
  | 1 -> Some Added
  | 2 -> Some Derived
  | 3 -> Some Underived
  | 4 -> Some Now_asserted
  | 5 -> Some Now_derived
  | _ -> None

let after = function Retracted | Underived -> 0 | Added | Now_asserted -> 1 | Derived | Now_derived -> 2
let present c = after c.kind > 0

type t = { n : int; time : int; by : int; why : string; first_new : int; count_new : int; changes : change array }

(* ---- The journal's coding of a group (format 2): its changes in columns, in their order ----
   The order of the changes is kept: replay applies them one after the other, and a group may hold two changes of one
   fact (added, then retracted), or a property's facts retracted before its declaration. A value's column is its
   property and its constructor (the tag): the values of one column are alike, so a frame of reference codes them in
   a few bits each (Pack). *)

(* the tag of a value: Value's byte; both booleans are tag 2 (the value says which) *)
let tag_of (v : Value.t) = match v with Int _ -> 0 | Float _ -> 1 | Bool _ -> 2 | Text _ -> 4 | Date _ -> 5 | Money _ -> 6 | Link _ -> 7

(* What the encoder reads of a group's changes, from an array of changes or from a large group's arrays (Resolve):
   one coding, so that both write the same bytes. [col i] is change i's column, numbered in order of first use, whose
   property and tag [cols] lists; [num i] is the number change i's value is coded by: the int of an Int, Date, Money
   or Link, 0 or 1 for a Bool, the place of a Text in [texts]; [float i] the bits of a Float. *)
type source = {
  count : int;
  kinds : int -> int;
  things : int -> int;
  col : int -> int;
  cols : (int * int) array;  (* (property, tag) a column *)
  num : int -> int;
  float : int -> int64;
  texts : string array;  (* the group's texts, each once, in order of first use *)
}

let encode_source b ~n ~time ~by ~why ~first_new ~count_new (s : source) =
  Codec.put_varint b n;
  Codec.put_int b time;
  Codec.put_int b by;
  Codec.put_string b why;
  Codec.put_varint b first_new;
  Codec.put_varint b count_new;
  Codec.put_varint b s.count;
  if s.count > 0 then begin
    Codec.put_varint b (Array.length s.texts);
    Array.iter (Codec.put_string b) s.texts;
    Codec.put_varint b (Array.length s.cols);
    Array.iter (fun (p, t) -> Codec.put_varint b p; Buffer.add_char b (Char.unsafe_chr t)) s.cols;
    Pack.put_ints b s.count s.kinds;
    Pack.put_ints b s.count s.things;
    Pack.put_ints b s.count s.col;
    (* each column's values, in the changes' order: the changes listed by column first (a counting sort) *)
    let nc = Array.length s.cols in
    let start = Array.make (nc + 1) 0 in
    for i = 0 to s.count - 1 do let c = s.col i in start.(c + 1) <- start.(c + 1) + 1 done;
    for c = 1 to nc do start.(c) <- start.(c) + start.(c - 1) done;
    let at = Array.sub start 0 nc and by_col = Array.make s.count 0 in
    for i = 0 to s.count - 1 do let c = s.col i in by_col.(at.(c)) <- i; at.(c) <- at.(c) + 1 done;
    for c = 0 to nc - 1 do
      let k = start.(c + 1) - start.(c) and o = start.(c) in
      if snd s.cols.(c) = 1 then for j = 0 to k - 1 do Codec.put_u64 b (s.float by_col.(o + j)) done
      else Pack.put_ints b k (fun j -> s.num by_col.(o + j))
    done
  end

let encode b g =
  let ch = g.changes in
  let cols = Hashtbl.create 8 and cl = ref [] and texts = Hashtbl.create 8 and tl = ref [] in
  let col = Array.map (fun c ->
      let key = (c.p, tag_of c.v) in
      match Hashtbl.find_opt cols key with
      | Some k -> k
      | None -> let k = Hashtbl.length cols in Hashtbl.replace cols key k; cl := key :: !cl; k) ch in
  let num = Array.map (fun c ->
      match c.v with
      | Value.Int x | Date x | Money x | Link x -> x
      | Bool x -> if x then 1 else 0
      | Float _ -> 0
      | Text s -> (match Hashtbl.find_opt texts s with
          | Some k -> k
          | None -> let k = Hashtbl.length texts in Hashtbl.replace texts s k; tl := s :: !tl; k)) ch in
  encode_source b ~n:g.n ~time:g.time ~by:g.by ~why:g.why ~first_new:g.first_new ~count_new:g.count_new
    { count = Array.length ch; kinds = (fun i -> code ch.(i).kind); things = (fun i -> ch.(i).e); col = Array.get col;
      cols = Array.of_list (List.rev !cl); num = Array.get num;
      float = (fun i -> match ch.(i).v with Float f -> Int64.bits_of_float f | _ -> 0L);
      texts = Array.of_list (List.rev !tl) }

let decode r =
  let n = Codec.get_varint r in
  let time = Codec.get_int r in
  let by = Codec.get_int r in
  let why = Codec.get_string r in
  let first_new = Codec.get_varint r in
  let count_new = Codec.get_varint r in
  let k = Codec.get_varint r in
  (* each of the three columns of k changes takes at least 2 bytes a block of 128: a count past the bytes left cannot
     be (and is never allocated) *)
  if k > 22 * (r.Codec.stop - r.Codec.pos) then raise Codec.Short;
  let changes =
    if k = 0 then [||]
    else begin
      let nt = Codec.get_varint r in
      if nt > r.stop - r.pos then raise Codec.Short;
      let texts = Array.init nt (fun _ -> Codec.get_string r) in
      let nc = Codec.get_varint r in
      if nc > r.stop - r.pos then raise Codec.Short;
      let cols = Array.init nc (fun _ -> let p = Codec.get_varint r in let t = Codec.get_byte r in p, t) in
      let kinds = Array.make k 0 and things = Array.make k 0 and col = Array.make k 0 in
      Pack.get_ints r k kinds 0;
      Pack.get_ints r k things 0;
      Pack.get_ints r k col 0;
      let count = Array.make nc 0 in
      Array.iter (fun c -> if c < 0 || c >= nc then raise Codec.Short; count.(c) <- count.(c) + 1) col;
      (* each column's values: ints, or a float's 8 bytes *)
      let ints = Array.make nc [||] and floats = Array.make nc [||] in
      Array.iteri
        (fun c (_, t) ->
          let m = count.(c) in
          if t = 1 then begin
            if 8 * m > r.stop - r.pos then raise Codec.Short;
            floats.(c) <- Array.init m (fun _ -> Int64.float_of_bits (Codec.get_u64 r))
          end
          else begin
            let a = Array.make m 0 in
            Pack.get_ints r m a 0;
            ints.(c) <- a
          end)
        cols;
      let next = Array.make nc 0 in
      Array.init k (fun i ->
          let c = col.(i) in
          let j = next.(c) in
          next.(c) <- j + 1;
          let p, t = cols.(c) in
          let kind = match of_code kinds.(i) with Some x -> x | None -> raise Codec.Short in
          let x () = ints.(c).(j) in
          let v : Value.t =
            match t with
            | 0 -> Int (x ())
            | 1 -> Float floats.(c).(j)
            | 2 -> (match x () with 0 -> Bool false | 1 -> Bool true | _ -> raise Codec.Short)
            | 4 -> let q = x () in if q < 0 || q >= nt then raise Codec.Short else Text texts.(q)
            | 5 -> Date (x ())
            | 6 -> Money (x ())
            | 7 -> Link (x ())
            | _ -> raise Codec.Short
          in
          let e = things.(i) in
          if e < 0 || p < 0 then raise Codec.Short;
          { kind; e; p; v })
    end
  in
  { n; time; by; why; first_new; count_new; changes }

(* The coding of format 1, read only to convert a journal of that format once (Journal.convert): a group's changes
   one after the other, each a kind byte, its thing, its property and its value (Value.encode). *)
let decode_v1 r =
  let n = Codec.get_varint r in
  let time = Codec.get_int r in
  let by = Codec.get_int r in
  let why = Codec.get_string r in
  let first_new = Codec.get_varint r in
  let count_new = Codec.get_varint r in
  let k = Codec.get_varint r in
  if k > r.Codec.stop - r.Codec.pos then raise Codec.Short;
  let changes =
    Array.init k (fun _ ->
        let kind = match of_code (Codec.get_byte r) with Some k -> k | None -> raise Codec.Short in
        let e = Codec.get_varint r in
        let p = Codec.get_varint r in
        let v = Value.decode r in
        { kind; e; p; v })
  in
  { n; time; by; why; first_new; count_new; changes }

let equal a b =
  a.n = b.n && a.time = b.time && a.by = b.by && a.why = b.why && a.first_new = b.first_new
  && a.count_new = b.count_new
  && Array.length a.changes = Array.length b.changes
  && Array.for_all2 (fun x y -> x.kind = y.kind && x.e = y.e && x.p = y.p && Value.equal x.v y.v) a.changes b.changes
