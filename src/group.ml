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
let tag_of_typ : Value.typ -> int = function Tint -> 0 | Tfloat -> 1 | Tbool -> 2 | Ttext -> 4 | Tdate -> 5 | Tmoney _ -> 6 | Tlink -> 7

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

(* The coding of a group whose changes are its records, then [n] more read by index (a change's derived facts in its
   run of their own, which never become records on the writer's path: Engine). Extra change j is Derived; [thing j],
   [prop j] its fact's thing and property, [word j] its value's word (Store's: the int of an Int, a Date, a Money or a
   Link, 0 or 1 for a Bool, a text's number for a Text or a Float), [tag p] the tag of property p's values, [text w] the
   text of word w (a Float's 8 bytes). Columns and texts are numbered in order of first use over every change, the
   records' then the extra ones': the bytes are those of [encode] of the group with all its changes as records. *)
let encode_parts b g ~n:extra ~thing ~prop ~tag ~word ~text =
  let ch = g.changes in
  let nf = Array.length ch in
  let count = nf + extra in
  let cols = Hashtbl.create 8 and cl = ref [] and texts = Hashtbl.create 8 and tl = ref [] in
  (* a column's key: its property and its tag in one int (a tag is below 8), so that a large group's changes take no
     tuple each *)
  let column p t =
    let key = (p lsl 3) lor t in
    match Hashtbl.find_opt cols key with
    | Some k -> k
    | None -> let k = Hashtbl.length cols in Hashtbl.replace cols key k; cl := (p, t) :: !cl; k
  in
  let place s =
    match Hashtbl.find_opt texts s with
    | Some k -> k
    | None -> let k = Hashtbl.length texts in Hashtbl.replace texts s k; tl := s :: !tl; k
  in
  let col = Array.make count 0 and num = Array.make count 0 in
  for i = 0 to nf - 1 do
    let c = Array.unsafe_get ch i in
    col.(i) <- column c.p (tag_of c.v);
    num.(i) <-
      (match c.v with
       | Value.Int x | Date x | Money x | Link x -> x
       | Bool x -> if x then 1 else 0
       | Float _ -> 0
       | Text s -> place s)
  done;
  if extra > 0 then begin
    (* the extra changes' columns by property (a property's values take one tag), their texts' places by word *)
    let pcol = ref (Array.make 64 (-1)) and wplace = Hashtbl.create 16 in
    for j = 0 to extra - 1 do
      let p = prop j in
      if p >= Array.length !pcol then begin
        let a = Array.make (max (p + 1) (2 * Array.length !pcol)) (-1) in
        Array.blit !pcol 0 a 0 (Array.length !pcol);
        pcol := a
      end;
      let t = tag p in
      let c = Array.unsafe_get !pcol p in
      let c = if c >= 0 then c else (let c = column p t in Array.unsafe_set !pcol p c; c) in
      col.(nf + j) <- c;
      num.(nf + j) <-
        (match t with
         | 1 -> 0
         | 2 -> if word j <> 0 then 1 else 0
         | 4 ->
           let w = word j in
           (match Hashtbl.find_opt wplace w with
            | Some k -> k
            | None -> let k = place (text w) in Hashtbl.add wplace w k; k)
         | _ -> word j)
    done
  end;
  encode_source b ~n:g.n ~time:g.time ~by:g.by ~why:g.why ~first_new:g.first_new ~count_new:g.count_new
    { count;
      kinds = (fun i -> if i < nf then code ch.(i).kind else 2);
      things = (fun i -> if i < nf then ch.(i).e else thing (i - nf));
      col = Array.get col;
      cols = Array.of_list (List.rev !cl); num = Array.get num;
      float = (fun i ->
        if i < nf then (match ch.(i).v with Float f -> Int64.bits_of_float f | _ -> 0L)
        else String.get_int64_le (text (word (i - nf))) 0);
      texts = Array.of_list (List.rev !tl) }

let encode b g =
  encode_parts b g ~n:0 ~thing:(fun _ -> 0) ~prop:(fun _ -> 0) ~tag:(fun _ -> 0) ~word:(fun _ -> 0) ~text:(fun _ -> "")

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
