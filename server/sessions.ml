(* Sessions: a write resent after a lost reply is applied once (G14). A program's library numbers its writes in a
   session (Welcome gives the session id); each group the server writes carries its session, serial and floor
   (Origin). For each database the server keeps, by session, the receipts of the serials at or above the floor: a
   serial seen again gets its first receipt, a serial still in flight waits for the first one's outcome, never runs
   twice. This is the method of Ongaro's thesis, section 6.3 ("Each server's state machine maintains a session for
   each client ... latest serial number processed ... along with the associated response"), with the floor of the
   client's oldest unanswered request so that a session may have many writes in flight.

   Durable: the table is written to DIR/sessions (a checkpoint) every second while writes come, and at stop; at start
   the checkpoint is read and the journal after its group replayed into it (Journal.read_after), so a crash loses no
   receipt. The checkpoint's group is never past a write still in flight: a write sent when the published group was
   P takes a group after P, so every write at or before min(published, the P of each write in flight) has its receipt
   in the table. *)

open Cepheus

type entry = { group : int; first_new : int }

type session = {
  sid : int;
  token : string;
  mutable floor : int;
  done_ : (int, entry) Hashtbl.t;  (* serial -> its group *)
  mutable top : int;  (* the highest serial applied *)
  errors : (int, Engine.error) Hashtbl.t;  (* serials refused, with their error (this process only) *)
  mutable last : int;  (* the time of its last write, ms *)
}

type pending = {
  p_session : int;
  p_serial : int;
  p_published : int;  (* the published group when it was sent *)
  mutable waiters : ((Engine.receipt, Engine.error) result -> unit) list;
}

type t = {
  m : Mutex.t;
  sessions : (int, session) Hashtbl.t;
  inflight : (int * int, pending) Hashtbl.t;  (* (session, serial) *)
  mutable resent : int;  (* writes answered from the table: for status and the tests *)
}

let create () = { m = Mutex.create (); sessions = Hashtbl.create 64; inflight = Hashtbl.create 64; resent = 0 }

(* a session forgets its receipts after an hour without a write; at most this many receipts a session *)
let expiry_ms = 3_600_000
let max_receipts = 4096

(* The new things of a group, numbered in order of first use from [first_new]: the thing of an op before the thing it
   links to (Resolve). *)
let things ops first_new =
  let seen = Hashtbl.create 4 and order = ref [] and next = ref first_new in
  let see x = if x < 0 && not (Hashtbl.mem seen x) then (Hashtbl.replace seen x !next; order := (x, !next) :: !order; incr next) in
  List.iter
    (function
      | Resolve.Add (e, _, v) | Resolve.Retract (e, _, v) -> see e; (match v with Value.Link t -> see t | _ -> ())
      | Resolve.Expect _ -> ()
      | Resolve.Incr (e, _, _, into) -> see e; (match into with Some (t, _) -> see t | None -> ()))
    ops;
  List.rev !order

let receipt ops (e : entry) = { Engine.group = e.group; things = things ops e.first_new }

let first_new (r : Engine.receipt) = List.fold_left (fun m (_, id) -> min m id) max_int r.things

let session t sid token now =
  match Hashtbl.find_opt t.sessions sid with
  | Some s -> s
  | None ->
    let s = { sid; token; floor = 0; done_ = Hashtbl.create 8; top = 0; errors = Hashtbl.create 2; last = now } in
    Hashtbl.replace t.sessions sid s;
    s

let record s serial (e : entry) =
  s.top <- max s.top serial;
  if serial >= s.floor then begin
    Hashtbl.replace s.done_ serial e;
    if Hashtbl.length s.done_ > max_receipts then begin
      (* a library that never moves its floor: the oldest receipts go *)
      let lo = Hashtbl.fold (fun k _ m -> min k m) s.done_ max_int in
      Hashtbl.remove s.done_ lo;
      s.floor <- max s.floor (lo + 1)
    end
  end

let raise_floor s floor =
  if floor > s.floor then begin
    s.floor <- floor;
    Hashtbl.filter_map_inplace (fun k e -> if k < floor then None else Some e) s.done_;
    Hashtbl.filter_map_inplace (fun k e -> if k < floor then None else Some e) s.errors
  end

type decision =
  | Fresh of pending  (** send it to the writer; call [finish] with its outcome *)
  | Replay of Engine.receipt  (** applied already: its first receipt *)
  | Wait  (** the same serial is in flight: [k] is called with the first one's outcome *)
  | Refuse of string * string  (** code, message *)

(* serial 0: a write outside any session (applied as sent, no duplicate check) *)
let start t ~sid ~token ~serial ~floor ~published ~now ops k =
  Mutex.protect t.m (fun () ->
      if serial = 0 then Fresh { p_session = sid; p_serial = 0; p_published = published; waiters = [ k ] }
      else
        let s = session t sid token now in
        if s.token <> token then Refuse ("denied", "this session belongs to another token")
        else if floor > serial then Refuse ("invalid", Printf.sprintf "the floor %d is past the serial %d" floor serial)
        else if serial < s.floor then
          Refuse ("invalid", Printf.sprintf "serial %d is below the session's floor %d: its reply was received" serial s.floor)
        else begin
          raise_floor s floor;
          s.last <- max s.last now;
          match Hashtbl.find_opt s.done_ serial with
          | Some e -> t.resent <- t.resent + 1; Replay (receipt ops e)
          | None -> (
            match Hashtbl.find_opt t.inflight (sid, serial) with
            | Some p -> t.resent <- t.resent + 1; p.waiters <- k :: p.waiters; Wait
            | None when serial < s.top || Hashtbl.mem s.errors serial -> (
              (* a later serial of the session was applied, so this one came before it and was refused: applied
                 now, it would come after a write the program sent later (monotonic writes) *)
              t.resent <- t.resent + 1;
              match Hashtbl.find_opt s.errors serial with
              | Some e -> let code, m = Wire.code_of_error e in Refuse (code, m)
              | None -> Refuse ("refused", Printf.sprintf "serial %d was refused before the server started again; its error is not kept" serial))
            | None ->
              let p = { p_session = sid; p_serial = serial; p_published = published; waiters = [ k ] } in
              Hashtbl.replace t.inflight (sid, serial) p;
              Fresh p)
        end)

(* its waiters are answered whatever the table does (a receipt that cannot be kept, memory: logged), so that no
   connection waits for them in vain *)
let finish t p (res : (Engine.receipt, Engine.error) result) =
  let ks =
    Mutex.protect t.m (fun () ->
        if p.p_serial > 0 then begin
          Hashtbl.remove t.inflight (p.p_session, p.p_serial);
          try
            match res, Hashtbl.find_opt t.sessions p.p_session with
            | Ok r, Some s -> record s p.p_serial { group = r.group; first_new = first_new r }
            | Error e, Some s -> if p.p_serial >= s.floor then Hashtbl.replace s.errors p.p_serial e
            | _ -> ()
          with e -> Fault.log "the receipt of a write in its session's table" e
        end;
        p.waiters)
  in
  List.iter (fun k -> k res) (List.rev ks)

(* A write of [start] that never reached its writer (its hand-off failed): out of the table, as if never sent, so
   that its session may send it again. Its first sender is answered by its own failure; the others that wait on it
   (the same serial sent again meanwhile) are told to send it again; a [finish] that would still come calls nobody. *)
let abandon t p =
  let ks =
    Mutex.protect t.m (fun () ->
        if p.p_serial > 0 then Hashtbl.remove t.inflight (p.p_session, p.p_serial);
        let ks = p.waiters in
        p.waiters <- [];
        ks)
  in
  match List.rev ks with
  | _ :: others -> List.iter (fun k -> k (Error (Engine.Busy "the write was not taken: send it again"))) others
  | [] -> ()

(* a group of the journal, at start: its origin into the table *)
let replay t (g : Group.t) =
  match Origin.parse g.why with
  | None -> ()
  | Some (o, _) when o.serial = 0 -> ()
  | Some (o, _) ->
    let s = session t o.session o.token g.time in
    s.last <- max s.last g.time;
    raise_floor s o.floor;
    record s o.serial { group = g.n; first_new = g.first_new }

(* ---- the checkpoint ---- *)

let magic = "cepheus sessions\n"
let format = 1

let encode t ~group ~now =
  let b = Buffer.create 4096 in
  Buffer.add_string b magic;
  Codec.put_varint b format;
  Codec.put_varint b group;
  let live = Hashtbl.fold (fun _ s acc -> if now - s.last <= expiry_ms then s :: acc else acc) t.sessions [] in
  Codec.put_varint b (List.length live);
  List.iter
    (fun s ->
      Codec.put_varint b s.sid;
      Codec.put_string b s.token;
      Codec.put_varint b s.floor;
      Codec.put_varint b s.top;
      Codec.put_int b s.last;
      Codec.put_varint b (Hashtbl.length s.done_);
      Hashtbl.iter (fun k (e : entry) -> Codec.put_varint b k; Codec.put_varint b e.group; Codec.put_varint b e.first_new) s.done_)
    live;
  let crc = Crc32c.string (Buffer.contents b) in
  Buffer.add_int32_le b (Int32.of_int crc);
  Buffer.to_bytes b

(* the group up to which the table holds every receipt, and the table's bytes *)
let snapshot t ~published ~now =
  Mutex.protect t.m (fun () ->
      let g = Hashtbl.fold (fun _ p g -> min g p.p_published) t.inflight published in
      (* sessions past their hour are dropped here *)
      Hashtbl.filter_map_inplace (fun _ s -> if now - s.last <= expiry_ms then Some s else None) t.sessions;
      g, encode t ~group:g ~now)

let path dir = Filename.concat dir "sessions"

let save disk dir t ~published ~now =
  let _, bytes = snapshot t ~published ~now in
  Disk.write_file disk (path dir) bytes

(* Some (group, table) if the checkpoint reads and checks; None if there is none. A checkpoint that does not check is
   ignored: the journal is replayed from its start (slower, never wrong). *)
let decode b =
  let n = Bytes.length b in
  if n < String.length magic + 4 || Bytes.sub_string b 0 (String.length magic) <> magic then None
  else if Int32.to_int (Bytes.get_int32_le b (n - 4)) land 0xFFFF_FFFF <> Crc32c.bytes b 0 (n - 4) then None
  else
    let r = Codec.reader b (String.length magic) (n - 4 - String.length magic) in
    try
      if Codec.get_varint r <> format then None
      else begin
        let group = Codec.get_varint r in
        let t = create () in
        for _ = 1 to Codec.get_varint r do
          let sid = Codec.get_varint r in
          let token = Codec.get_string r in
          let floor = Codec.get_varint r in
          let top = Codec.get_varint r in
          let last = Codec.get_int r in
          let s = { sid; token; floor; done_ = Hashtbl.create 8; top; errors = Hashtbl.create 2; last } in
          for _ = 1 to Codec.get_varint r do
            let k = Codec.get_varint r in
            let group = Codec.get_varint r in
            let first_new = Codec.get_varint r in
            Hashtbl.replace s.done_ k { group; first_new }
          done;
          Hashtbl.replace t.sessions sid s
        done;
        Some (group, t)
      end
    with Codec.Short -> None

(* the table of a database just opened: its checkpoint, then the journal after it *)
let load disk dir id =
  let from, t =
    match if disk.Disk.exists (path dir) then decode (Disk.read_all disk (path dir)) else None with
    | Some (g, t) -> g, t
    | None -> 0, create ()
  in
  Journal.read_after disk (Filename.concat dir "journal") id from (replay t);
  t
