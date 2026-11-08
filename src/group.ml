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

let encode b g =
  Codec.put_varint b g.n;
  Codec.put_int b g.time;
  Codec.put_int b g.by;
  Codec.put_string b g.why;
  Codec.put_varint b g.first_new;
  Codec.put_varint b g.count_new;
  Codec.put_varint b (Array.length g.changes);
  Array.iter
    (fun f ->
      Buffer.add_char b (Char.unsafe_chr (code f.kind));
      Codec.put_varint b f.e;
      Codec.put_varint b f.p;
      Value.encode b f.v)
    g.changes

let decode r =
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
