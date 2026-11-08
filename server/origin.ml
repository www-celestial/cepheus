(* Where a group written through the server came from: the token's name (which program), and its session and serial
   number (G14: a write resent after a lost reply is applied once). It travels in the group's [why], before the
   application's own text, so the journal's format does not change and the history answers "which program wrote
   this":

     why = "\000cph1\000" | session varint | serial varint | floor varint | token name (length, bytes) | the
           application's why

   [floor]: the lowest serial of the session still waiting for its reply when the write was sent; the receipts below
   it are no longer needed (Ongaro's thesis, section 6.3). A why that does not start with the marker is the
   application's alone (a group written in the program's process, or by the engine). *)

type t = { token : string; session : int; serial : int; floor : int }

let marker = "\000cph1\000"

let wrap o why =
  let b = Buffer.create (String.length why + 32) in
  Buffer.add_string b marker;
  Cepheus.Codec.put_varint b o.session;
  Cepheus.Codec.put_varint b o.serial;
  Cepheus.Codec.put_varint b o.floor;
  Cepheus.Codec.put_string b o.token;
  Buffer.add_string b why;
  Buffer.contents b

let has_marker why =
  let n = String.length marker in
  String.length why >= n && String.sub why 0 n = marker

let parse why =
  if not (has_marker why) then None
  else
    let n = String.length marker in
    let r = Cepheus.Codec.reader (Bytes.unsafe_of_string why) n (String.length why - n) in
    match
      let session = Cepheus.Codec.get_varint r in
      let serial = Cepheus.Codec.get_varint r in
      let floor = Cepheus.Codec.get_varint r in
      let token = Cepheus.Codec.get_string r in
      { token; session; serial; floor }, String.sub why r.pos (String.length why - r.pos)
    with
    | x -> Some x
    | exception Cepheus.Codec.Short -> None

(* the application's why, the origin taken away *)
let why w = match parse w with Some (_, w) -> w | None -> w
