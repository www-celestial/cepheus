type change = { add : bool; e : int; p : int; v : Value.t }

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
      Buffer.add_char b (if f.add then '\001' else '\000');
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
        let add =
          match Codec.get_byte r with 0 -> false | 1 -> true | _ -> raise Codec.Short
        in
        let e = Codec.get_varint r in
        let p = Codec.get_varint r in
        let v = Value.decode r in
        { add; e; p; v })
  in
  { n; time; by; why; first_new; count_new; changes }

let equal a b =
  a.n = b.n && a.time = b.time && a.by = b.by && a.why = b.why && a.first_new = b.first_new
  && a.count_new = b.count_new
  && Array.length a.changes = Array.length b.changes
  && Array.for_all2 (fun x y -> x.add = y.add && x.e = y.e && x.p = y.p && Value.equal x.v y.v) a.changes b.changes
