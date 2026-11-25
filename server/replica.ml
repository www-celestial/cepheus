(* A replica: a server on another machine that keeps a copy of every database of its primary, group for group, in its
   own journal, forced by its own fsyncs (design 8.1, step 6; docs/book/server.md, "A replica").

   Asynchronous: the primary never waits for a replica. Its sender, a thread a replica and a database, reads the frames
   of the database's journal as the journal holds them (Journal.cursor), only up to the newest durable group, and sends
   them over mutual TLS; it is woken by the follow stream after each durable frame (no new work in the writer or the
   syncer). The replica checks each frame's CRC, decodes it (bounds checked), replays its groups through its own
   writer and syncer (Engine.Apply), appends the same bytes to its journal and forces them, then says up to which group
   it holds them (Applied). So the replica's journal is always a prefix of the primary's durable groups: a frame being
   forced on the primary is never sent (a failed fsync there would leave the replica with a group the primary may
   lose). A replica behind reads from where it stands: catch-up and the live stream are one path, and the primary's
   memory for a replica is one frame, however far behind it is.

   Epochs (PostgreSQL's timelines): each database keeps the history of its promotions, DIR/epochs, a list of (epoch,
   its first group); without the file, [(1, 1)]. A promotion opens a new epoch at the group after the replica's newest.
   A copy may follow a primary only if its history is a prefix of the primary's and its newest group lies within its
   last epoch on the primary: otherwise it holds groups the primary never had (an old primary that wrote after a
   promotion, or groups that never reached the replica that was promoted), and it is refused, never merged.

   The role of the server is in DATA/cepheus.role, mode 0600: absent, the server is a primary (every data directory
   made before replicas); `replica_of = "srv1"` (cepheus replicate); `promoted_from = "srv1"` and the epochs the
   promotion opened (cepheus promote: the file is the promotion's commit point; its epochs are written into each
   database's history then, and again at every start, which makes a promotion cut by a crash whole). *)

open Cepheus

let log fmt = Printf.ksprintf (fun s -> prerr_endline ("cepheus: " ^ s)) fmt

(* ---- files of the server's own: written beside (never through a name planted there: O_EXCL), forced, renamed,
   the directory forced; mode 0600 ---- *)

let write_private path s =
  let tmp = path ^ ".tmp" in
  (try Unix.unlink tmp with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
  let fd = Unix.openfile tmp [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ] 0o600 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
      let rec go o = if o < String.length s then go (o + Unix.write_substring fd s o (String.length s - o)) in
      go 0;
      Unix.fsync fd);
  Unix.rename tmp path;
  Disk.real.sync_dir (Filename.dirname path)

let remove_private path =
  match Unix.unlink path with
  | () -> Disk.real.sync_dir (Filename.dirname path)
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let read_file path = In_channel.with_open_bin path In_channel.input_all

(* ---- epochs ---- *)

type epochs = (int * int) list  (* (epoch, its first group), oldest first *)

let first_epochs = [ 1, 1 ]
let epochs_magic = "cepheus epochs\n"
let epochs_path dir = Filename.concat dir "epochs"

let put_epochs b (h : epochs) = Codec.put_varint b (List.length h); List.iter (fun (e, f) -> Codec.put_varint b e; Codec.put_varint b f) h

(* a history read from a file or the wire: epochs growing from 1, first groups never going back *)
let get_epochs r : epochs =
  let n = Codec.get_varint r in
  if n < 1 || n > r.Codec.stop - r.pos then raise Codec.Short;
  let h = List.init n (fun _ -> let e = Codec.get_varint r in let f = Codec.get_varint r in e, f) in
  let rec ok = function (e, f) :: ((e', f') :: _ as rest) -> e' > e && f' >= f && ok rest | _ -> true in
  if List.hd h <> (1, 1) || not (ok h) then raise Codec.Short;
  h

let encode_epochs h =
  let b = Buffer.create 64 in
  Buffer.add_string b epochs_magic;
  put_epochs b h;
  Buffer.add_int32_le b (Int32.of_int (Crc32c.string (Buffer.contents b)));
  Buffer.contents b

let load_epochs dir =
  let path = epochs_path dir in
  if not (Sys.file_exists path) then first_epochs
  else
    let s = read_file path in
    let n = String.length s and m = String.length epochs_magic in
    let bad () = raise (Journal.Damaged (path ^ " does not check: the database's history of promotions is lost; copy it again from its primary")) in
    if n < m + 4 || String.sub s 0 m <> epochs_magic || Int32.to_int (String.get_int32_le s (n - 4)) land 0xFFFF_FFFF <> Crc32c.string (String.sub s 0 (n - 4)) then bad ()
    else
      let r = Codec.reader (Bytes.of_string s) m (n - 4 - m) in
      match get_epochs r with h when Codec.at_end r -> h | _ -> bad () | exception Codec.Short -> bad ()

let save_epochs dir h = write_private (epochs_path dir) (encode_epochs h)

let last_epoch (h : epochs) = fst (List.nth h (List.length h - 1))

(* May a copy of history [replica] whose newest group is [last] follow a primary of history [primary] at group
   [group]? *)
let follows ~primary ~group ~replica ~last =
  let rec prefix a b = match a, b with [], _ -> true | x :: a, y :: b -> x = y && prefix a b | _ :: _, [] -> false in
  let er = last_epoch replica in
  if not (prefix replica primary) then
    if er > last_epoch primary && prefix primary replica then
      Error ("newer", Printf.sprintf "this copy's history has epoch %d, which the primary does not: it was promoted, or it followed a newer primary" er)
    else Error ("diverged", "this copy's history of promotions is not the primary's: they went different ways")
  else
    let next = match List.find_opt (fun (e, _) -> e > er) primary with Some (_, f) -> f | None -> max_int in
    if last >= next then
      Error ("diverged",
             Printf.sprintf "this copy holds groups up to %d in epoch %d, which ended at group %d on the primary: groups written by an old primary after a promotion, or that never reached the replica that was promoted" last er (next - 1))
    else if last > group then
      Error ("newer", Printf.sprintf "this copy holds groups up to %d, the primary only up to %d (was the primary restored from an older copy?)" last group)
    else Ok ()

(* ---- the server's role ---- *)

type role =
  | Primary
  | Replica_of of string  (** the peer it follows *)
  | Promoted of string * (string * int * int) list  (** promoted from that peer; the epochs it opened: database, epoch, first group *)

let role_path data = Filename.concat data "cepheus.role"

let read_role data =
  let path = role_path data in
  if not (Sys.file_exists path) then Ok Primary
  else
    match Toml.parse_file path with
    | exception Toml.Error (line, m) -> Error (Printf.sprintf "%s, line %d: %s" path line m)
    | exception Sys_error m -> Error m
    | doc -> (
      let str k = match List.assoc_opt k doc with Some (Toml.String s) -> Some s | _ -> None in
      match str "replica_of", str "promoted_from" with
      | Some p, None -> Ok (Replica_of p)
      | None, Some p -> (
        let epochs = match List.assoc_opt "epoch" doc with Some (Toml.Array l) -> l | _ -> [] in
        match
          List.map
            (function
              | Toml.Table t -> (
                match List.assoc_opt "database" t, List.assoc_opt "epoch" t, List.assoc_opt "first" t with
                | Some (Toml.String d), Some (Toml.Int e), Some (Toml.Int f) when e > 1 && f >= 1 -> d, e, f
                | _ -> failwith "an [[epoch]] needs database, epoch (2 or more) and first (1 or more)")
              | _ -> failwith "epoch must be written [[epoch]]")
            epochs
        with
        | l -> Ok (Promoted (p, l))
        | exception Failure m -> Error (path ^ ": " ^ m))
      | _ -> Error (path ^ ": replica_of or promoted_from was expected (the file is written by cepheus replicate and promote)"))

let write_role data role =
  let path = role_path data in
  match role with
  | Primary -> remove_private path
  | Replica_of p ->
    write_private path
      (Printf.sprintf "# This server's role, written by cepheus replicate: it follows the primary %s (cepheus promote ends it).\nreplica_of = %s\n" p (Toml.quote p))
  | Promoted (p, l) ->
    let b = Buffer.create 256 in
    Printf.bprintf b "# This server's role, written by cepheus promote: it was a replica of %s, and is a primary.\npromoted_from = %s\n" p (Toml.quote p);
    List.iter (fun (d, e, f) -> Printf.bprintf b "\n[[epoch]]\ndatabase = %s\nepoch = %d\nfirst = %d\n" (Toml.quote d) e f) l;
    write_private path (Buffer.contents b)

(* the epochs a promotion opened, into the databases' histories (once: a history that has the epoch is left) *)
let apply_promoted role ~dir_of =
  match role with
  | Promoted (_, l) ->
    List.iter
      (fun (d, e, f) ->
        let dir = dir_of d in
        if Sys.file_exists (Filename.concat dir "cepheus") then begin
          let h = load_epochs dir in
          if not (List.mem_assoc e h) then
            if e > last_epoch h then save_epochs dir (h @ [ e, f ])
            else raise (Journal.Damaged (Printf.sprintf "%s: the promotion's epoch %d of %s is older than its history's newest" (epochs_path dir) e d))
        end)
      l
  | Primary | Replica_of _ -> ()

(* ---- the peer protocol: frames as on the client port (Wire), over mutual TLS on the [[peer]] port ----
     PeerHello  version | cluster id | name        -> PeerHello  server id | cluster id | name     (or an error)
     Replicate  database | next group | epochs     -> Replicate  database id | group | epochs     (or an error)
                then the primary's pushes (id 0): Frame, Beat, Stopped; the replica's Applied (id 0)
     Epochs                                        -> Epochs     count | (database | group | epochs)...
     Frame      first | count | crc32c | length | the first bytes; the rest in frames of the flag more
     Beat       the primary's newest durable group (each second without a frame)
     Stopped    the primary stopped at this group (its clean stop: every group up to it was sent)
     Applied    the replica holds every group up to this one durably
   Version 2 (a Raft cluster, server/cluster.ml) adds:
     Raft                                          -> Raft (empty), then the connection carries Raft's messages one
                                                      way, from the certificate's peer, each a frame of kind Msg (id 0)
   Version 3 adds Raft's messages Snap (server/raft.ml) and a copy of the databases (server/catchup.ml):
     Copy                                          -> Copy frames: Begin, File and Bytes, End (or an error)
   A peer of version 1 is refused with the error version; one of version 2 is taken, and never sent what version 3
   adds (a connector refused with version tries again announcing 2: an older peer, during a rolling upgrade). *)

let version = 3
let oldest = 2

(* the version a connection announces (the tests: an older peer) *)
let version_override = ref None
let k_hello = 20
let k_replicate = 21
let k_epochs = 22
let k_frame = 23
let k_beat = 24
let k_stopped = 25
let k_applied = 26
let k_raft = 27
let k_msg = 28
let k_copy = 29
let piece = 1 lsl 20

(* the time a peer has for its handshake and Hello, and the stream for a frame or a beat *)
let handshake_s = ref 5.0
let stream_s = ref 30.0
let beat_s = 1.0

type link = {
  tls : Tls.t;
  fd : Unix.file_descr;
  mutable inb : Bytes.t;
  mutable have : int;
  closed : bool Atomic.t;
  mutable until : float;  (* a frame must be whole by then, a byte at a time or not (0.: no such time): the Hello *)
  mutable pv : int;  (* the peer protocol both ends speak on it *)
}

exception Broken of string

let timeouts fd t = Unix.setsockopt_float fd Unix.SO_RCVTIMEO t; Unix.setsockopt_float fd Unix.SO_SNDTIMEO t

let send l ~kind ?(flags = 0) ?(id = 0) body =
  let f = Buffer.create (Buffer.length body + Wire.header) in
  Wire.add_frame f ~id ~kind ~flags body;
  try Tls.write l.tls (Buffer.to_bytes f) 0 (Buffer.length f) with
  | Unix.Unix_error (e, _, _) -> raise (Broken (Unix.error_message e))
  | Failure m -> raise (Broken m)

let send_err l code m = let b = Buffer.create 64 in Wire.put_reply b (Wire.Err { code; message = m }); send l ~kind:0 ~flags:Wire.f_error b

(* the next frame: kind, flags, a reader of its body; its length checked before anything is allocated for it *)
let next_frame l =
  let rec fill need =
    if l.have < need then begin
      if need > Bytes.length l.inb then begin
        let b = Bytes.create (max need (2 * Bytes.length l.inb)) in
        Bytes.blit l.inb 0 b 0 l.have;
        l.inb <- b
      end;
      let waiting () = if l.until > 0. && Unix.gettimeofday () >= l.until then raise (Broken "no whole frame in time") in
      let k =
        try Tls.read ~waiting l.tls l.inb l.have (Bytes.length l.inb - l.have) with
        | Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> raise (Broken "the peer went silent")
        | Unix.Unix_error (e, _, _) -> raise (Broken (Unix.error_message e))
        | Failure m -> raise (Broken m)
      in
      if k = 0 then raise (Broken "the peer closed the connection");
      l.have <- l.have + k;
      fill need
    end
  in
  fill 4;
  let len = Wire.u32 l.inb 0 in
  if len < Wire.header - 4 || len > Wire.max_frame then raise (Broken (Printf.sprintf "a frame of %d bytes" len));
  fill (4 + len);
  let kind = Bytes.get_uint8 l.inb 8 and flags = Bytes.get_uint8 l.inb 9 in
  let body = Bytes.sub l.inb Wire.header (4 + len - Wire.header) in
  Bytes.blit l.inb (4 + len) l.inb 0 (l.have - 4 - len);
  l.have <- l.have - 4 - len;
  kind, flags, Codec.reader body 0 (Bytes.length body)

(* an error frame's code and message, or Broken for a frame of another kind than [kind] *)
let expect l kind =
  let k, flags, r = next_frame l in
  if flags land Wire.f_error <> 0 then
    match Wire.get_reply 0 flags r with Wire.Err e -> Error (e.code, e.message) | _ -> raise (Broken "a bad error frame")
  else if k <> kind then raise (Broken (Printf.sprintf "a frame of kind %d where %d was expected" k kind))
  else Ok r

(* once: a descriptor closed twice could be another connection's by then *)
let close_link l =
  if Atomic.compare_and_set l.closed false true then begin
    (try Tls.close l.tls with Unix.Unix_error _ | Failure _ -> ());
    (try Unix.shutdown l.fd Unix.SHUTDOWN_ALL with Unix.Unix_error _ -> ());
    try Unix.close l.fd with Unix.Unix_error _ -> ()
  end

(* wakes the threads blocked on the link, which close it *)
let shut l = if not (Atomic.get l.closed) then try Unix.shutdown l.fd Unix.SHUTDOWN_ALL with Unix.Unix_error _ -> ()

(* ---- the server's part ---- *)

(* a replica as its primary's sender sees it *)
type sender = {
  peer : string;
  mutable acked : int;  (* the replica holds every group up to it *)
  times : (int * float) Queue.t;  (* when each newest group was seen durable here, for the lag *)
  lag : Histogram.t;  (* microseconds from a group durable here to its Applied *)
  sm : Mutex.t;
  mutable gone : bool;
  mutable over : bool;  (* its stream ended *)
}

type db = {
  name : string;
  dir : string;
  live : Engine.live;
  follow : Follow.t;
  sessions : Sessions.t;
  mutable epochs : epochs;
  dm : Mutex.t;
  mutable senders : sender list;  (* as a primary *)
  (* as a replica *)
  mutable connected : bool;
  mutable connections : int;  (* streams begun, for a promotion's check that none began meanwhile *)
  mutable primary_group : int;
  mutable handover : int option;  (* the primary stopped at this group, which this copy holds *)
  mutable last_error : string;
  mutable link : link option;
  mutable thread : Thread.t option;
}

type t = {
  cfg : Config.t;
  mutable role : role;
  dbs : db array;
  stopping : bool Atomic.t;  (* the server stops: followers end *)
  final : bool Atomic.t;  (* the databases are closed: senders send their last groups and Stopped *)
  rm : Mutex.t;
  mutable peers_open : int;
  promoting : bool Atomic.t;  (* one promotion at a time *)
  mutable on_raft : (string -> link -> unit) option;  (* a Raft cluster: a peer's stream of Raft messages *)
  mutable on_copy : (string -> link -> unit) option;  (* a Raft cluster: a peer's copy of the databases (Catchup) *)
  mutable on_promote : db -> unit -> unit;
      (* the transport's part of a promotion (the visibility page): prepared before the commit point (Failure if it
         cannot be), done after *)
}

let handover_path dir = Filename.concat dir "handover"

let make_db ~name ~dir ~live ~follow ~sessions =
  let handover =
    match int_of_string_opt (String.trim (read_file (handover_path dir))) with
    | Some g -> Some g
    | None -> None
    | exception Sys_error _ -> None
  in
  { name; dir; live; follow; sessions; epochs = load_epochs dir; dm = Mutex.create (); senders = []; connected = false;
    connections = 0; primary_group = 0; handover; last_error = ""; link = None; thread = None }

let create cfg role dbs =
  { cfg; role; dbs; stopping = Atomic.make false; final = Atomic.make false; rm = Mutex.create (); peers_open = 0;
    promoting = Atomic.make false; on_raft = None; on_copy = None; on_promote = (fun _ () -> ()) }

let is_replica t = match t.role with Replica_of _ -> true | _ -> false

let peer_of (cfg : Config.t) name = List.find_opt (fun (p : Config.peer) -> p.pname = name) cfg.peers

(* why a write is refused here: Some while the server is a replica *)
let read_only t =
  match t.role with
  | Replica_of p ->
    Some (Printf.sprintf "this server is a replica of %s (%s): write to the primary" p
            (match peer_of t.cfg p with Some x -> x.address | None -> "?"))
  | _ -> None

(* The session table follows the groups a replica holds (G14 across a promotion: a write sent again to the promoted
   server gets its first receipt): the groups of a frame, once it is durable. [before] and [after] are the engine's
   follow hooks' parts. *)
let session_hooks (s : Sessions.t) (e : Engine.t) =
  let pending = ref [] in
  let before (b : Engine.batch) = pending := b.groups in
  let after () =
    let gs = !pending in
    pending := [];
    match gs with
    | g :: _ when (Atomic.get e.published).group >= g.Group.n -> Mutex.protect s.m (fun () -> List.iter (Sessions.replay s) (List.rev gs))
    | _ -> ()
  in
  before, after

(* ---- the primary: a sender a replica and a database ---- *)

let status_lines t (d : db) =
  match t.role with
  | Replica_of p ->
    [ "replica_of", p; "replica.connected", string_of_bool d.connected; "replica.primary_group", string_of_int d.primary_group;
      "replica.handover", (match d.handover with Some g -> string_of_int g | None -> "none"); "replica.epoch", string_of_int (last_epoch d.epochs) ]
    @ (if d.last_error = "" then [] else [ "replica.error", d.last_error ])
  | Primary | Promoted _ ->
    ("epoch", string_of_int (last_epoch d.epochs))
    :: List.concat_map
         (fun s ->
           Mutex.protect s.sm (fun () ->
               let k x = "replica." ^ s.peer ^ "." ^ x in
               [ k "group", string_of_int s.acked; k "lag_us_p50", string_of_int (Histogram.percentile s.lag 0.5);
                 k "lag_us_p99", string_of_int (Histogram.percentile s.lag 0.99); k "lag_us_max", string_of_int (Histogram.max s.lag);
                 k "lag_samples", string_of_int (Histogram.total s.lag) ]))
         (Mutex.protect d.dm (fun () -> d.senders))

let server_lines t =
  [ "role", (match t.role with Primary -> "primary" | Replica_of p -> "replica of " ^ p | Promoted (p, _) -> "primary (promoted from " ^ p ^ ")") ]

(* what the replica says it holds: its lag sample is the time since the first group at or after it was seen durable *)
let applied s g =
  let now = Unix.gettimeofday () in
  Mutex.protect s.sm (fun () ->
      if g > s.acked then begin
        s.acked <- g;
        (match Queue.peek_opt s.times with
         | Some _ ->
           (* the first time a group at or past g was durable: the head once the entries before g are gone *)
           while (match Queue.peek_opt s.times with Some (h, _) -> h < g | None -> false) do ignore (Queue.take s.times) done;
           (match Queue.peek_opt s.times with
            | Some (h, at) -> Histogram.record s.lag (int_of_float ((now -. at) *. 1e6)); if h = g then ignore (Queue.take s.times)
            | None -> ())
         | None -> ())
      end)

let frame_msg ~first ~count ~crc body len emit =
  let b = Buffer.create (min len piece + 32) in
  Codec.put_varint b first; Codec.put_varint b count; Codec.put_varint b crc; Codec.put_varint b len;
  let k = min len piece in
  Buffer.add_subbytes b body 0 k;
  emit ~more:(k < len) b;
  let o = ref k in
  while !o < len do
    let k = min (len - !o) piece in
    let c = Buffer.create k in
    Buffer.add_subbytes c body !o k;
    o := !o + k;
    emit ~more:(!o < len) c
  done

(* the stream to one replica, from [next], until it goes, the server stops, or the database is closed (then its last
   groups, and Stopped) *)
let stream t (d : db) l ~peer ~next =
  let e = d.live.e in
  let s = { peer; acked = next - 1; times = Queue.create (); lag = Histogram.create (); sm = Mutex.create (); gone = false; over = false } in
  Mutex.protect d.dm (fun () -> d.senders <- s :: List.filter (fun x -> x.peer <> peer) d.senders);
  let reader =
    Thread.create
      (fun () ->
        (try
           while true do
             match next_frame l with
             | k, _, r when k = k_applied -> applied s (Codec.get_varint r)
             | _ -> ()
           done
         with Broken _ | Codec.Short -> ());
        s.gone <- true;
        Follow.wake d.follow)
      ()
  in
  let emit ~more b = send l ~kind:k_frame ~flags:(if more then Wire.f_more else 0) b in
  let last_sent = ref (Unix.gettimeofday ()) and seen = ref (-1) and cur = ref None in
  (try
     let c = Journal.cursor Disk.real (Filename.concat e.dir "journal") e.id ~next in
     cur := Some c;
     let go = ref true in
     while !go && not s.gone do
       let fin = Atomic.get t.final in
       let v = Mutex.protect d.follow.fm (fun () -> d.follow.vseq) in
       let upto = (Atomic.get e.published).group in
       if upto > !seen then begin
         Mutex.protect s.sm (fun () ->
             if Queue.length s.times >= 4096 then ignore (Queue.take s.times);
             Queue.push (upto, Unix.gettimeofday ()) s.times);
         seen := upto
       end;
       if Journal.cursor_next c <= upto then begin
         Journal.frames c ~upto (fun ~first ~count ~crc body len -> frame_msg ~first ~count ~crc body len emit);
         last_sent := Unix.gettimeofday ()
       end;
       if fin then begin
         (* the clean stop: every group sent; the replica says it holds them (at most 10 s) *)
         let b = Buffer.create 16 in
         Codec.put_varint b upto;
         send l ~kind:k_stopped b;
         let t0 = Unix.gettimeofday () in
         while s.acked < upto && (not s.gone) && Unix.gettimeofday () -. t0 < 10. do Thread.delay 0.005 done;
         if s.acked >= upto then log "database %s: handed over to %s at group %d" d.name peer upto
         else log "database %s: %s did not say it holds group %d before the stop" d.name peer upto;
         go := false
       end
       else begin
         if Unix.gettimeofday () -. !last_sent >= beat_s then begin
           let b = Buffer.create 16 in
           Codec.put_varint b upto;
           send l ~kind:k_beat b;
           last_sent := Unix.gettimeofday ()
         end;
         ignore (Follow.wait_past d.follow v)
       end
     done
   with
   | Broken m -> log "database %s: the stream to %s ended: %s" d.name peer m
   | Journal.Damaged m -> log "database %s: the stream to %s stopped on its journal: %s" d.name peer m
   | Disk.Io m -> log "database %s: the stream to %s stopped: %s" d.name peer m
   | e -> log "database %s: the stream to %s stopped: %s" d.name peer (Printexc.to_string e));
  Option.iter Journal.cursor_close !cur;
  s.over <- true;
  close_link l;
  Thread.join reader;
  Mutex.protect d.dm (fun () -> d.senders <- List.filter (fun x -> x != s) d.senders)

(* the Replicating reply and the stream; refusals as error frames *)
let replicate t l ~peer r =
  let name = Codec.get_string r in
  let next = Codec.get_varint r in
  let theirs = get_epochs r in
  match Array.find_opt (fun d -> d.name = name) t.dbs with
  | None -> send_err l "unknown_database" (Printf.sprintf "no database %S on this server" name)
  | Some d -> (
    match t.role with
    | Replica_of p -> send_err l "not_primary" (Printf.sprintf "this server is a replica of %s" p)
    | Primary | Promoted _ -> (
      let g = (Atomic.get d.live.e.published).group in
      match follows ~primary:d.epochs ~group:g ~replica:theirs ~last:(next - 1) with
      | Error (code, m) ->
        log "database %s: %s refused as a replica: %s" d.name peer m;
        send_err l code m
      | Ok () ->
        let b = Buffer.create 64 in
        Codec.put_string b d.live.e.id; Codec.put_varint b g; put_epochs b d.epochs;
        send l ~kind:k_replicate b;
        timeouts l.fd !stream_s;
        stream t d l ~peer ~next))

let epochs_reply t l =
  let b = Buffer.create 128 in
  Codec.put_varint b (Array.length t.dbs);
  Array.iter (fun d -> Codec.put_string b d.name; Codec.put_varint b (Atomic.get d.live.e.published).group; put_epochs b d.epochs) t.dbs;
  send l ~kind:k_epochs b

let max_peer_connections = 256
let noted = ref 0.

(* one connection on the peer port, in its own thread: mutual TLS (the certificate must name a [[peer]] other than
   this server), the cluster's id, then one request *)
let serve_peer t ctx fd =
  let refuse m =
    let now = Unix.gettimeofday () in
    if now -. !noted >= 1. then (noted := now; log "a connection on the peer port refused: %s" m);
    (try Unix.close fd with Unix.Unix_error _ -> ())
  in
  timeouts fd !handshake_s;
  (* the handshake and the Hello within [handshake_s] of the accept, a byte at a time or not *)
  let until = Unix.gettimeofday () +. !handshake_s in
  let waiting () = if Unix.gettimeofday () >= until then failwith (Printf.sprintf "no handshake within %g s" !handshake_s) in
  match Tls.handshake ~waiting ctx fd ~server:true ~host:"" with
  | Error m -> refuse ("TLS: " ^ m)
  | Ok tls -> (
    let name = Tls.peer_name tls in
    let l = { tls; fd; inb = Bytes.create 65536; have = 0; closed = Atomic.make false; until; pv = version } in
    if name = t.cfg.me || peer_of t.cfg name = None then (close_link l; refuse (Printf.sprintf "its certificate names %S, which is not another [[peer]]" name))
    else
      try
        match expect l k_hello with
        | Error _ -> close_link l
        | Ok r ->
          l.until <- 0.;
          let v = Codec.get_varint r in
          let cluster = Codec.get_string r in
          let _ = Codec.get_string r in
          if v < oldest || v > version then (send_err l "version" (Printf.sprintf "peer protocol %d is not spoken here (%d to %d are)" v oldest version); close_link l)
          else if cluster <> t.cfg.id then (send_err l "cluster" (Printf.sprintf "this server is of the cluster %s" t.cfg.id); close_link l)
          else begin
            l.pv <- v;
            let b = Buffer.create 64 in
            Codec.put_string b t.cfg.me; Codec.put_string b t.cfg.id; Codec.put_string b t.cfg.me;
            send l ~kind:k_hello b;
            (match next_frame l with
             | k, _, r when k = k_replicate -> replicate t l ~peer:name r
             | k, _, _ when k = k_epochs -> epochs_reply t l
             | k, _, _ when k = k_raft -> (
               match t.on_raft with
               | Some f -> f name l
               | None -> send_err l "invalid" "this server is not a member of a Raft cluster")
             | k, _, _ when k = k_copy && v >= 3 -> (
               match t.on_copy with
               | Some f -> f name l
               | None -> send_err l "invalid" "this server is not a member of a Raft cluster")
             | _ -> send_err l "invalid" "Replicate, Epochs, Raft or Copy was expected");
            close_link l
          end
      with Broken _ | Codec.Short -> close_link l)

let peer_listener t ctx s () =
  let go = ref true in
  while !go do
    match Unix.accept ~cloexec:true s with
    | fd, _ ->
      let ok = Mutex.protect t.rm (fun () -> if t.peers_open >= max_peer_connections then false else (t.peers_open <- t.peers_open + 1; true)) in
      if not ok then (try Unix.close fd with Unix.Unix_error _ -> ())
      else begin
        Unix.setsockopt fd Unix.TCP_NODELAY true;
        ignore
          (Thread.create
             (fun () ->
               Fun.protect ~finally:(fun () -> Mutex.protect t.rm (fun () -> t.peers_open <- t.peers_open - 1)) (fun () ->
                   try serve_peer t ctx fd with e -> log "peer connection: %s" (Printexc.to_string e); (try Unix.close fd with Unix.Unix_error _ -> ())))
             ())
      end
    | exception Unix.Unix_error ((Unix.EINTR | Unix.ECONNABORTED), _, _) -> ()
    | exception Unix.Unix_error ((Unix.EMFILE | Unix.ENFILE | Unix.ENOBUFS | Unix.ENOMEM), _, _) -> Thread.delay 0.1
    | exception Unix.Unix_error _ -> go := false
  done

(* the clean stop of a primary: its databases closed, each sender sends its last groups and Stopped, and waits (at most
   10 s) for its replica to hold them *)
let handover t =
  Atomic.set t.final true;
  let t0 = Unix.gettimeofday () in
  let busy () = Array.exists (fun d -> Mutex.protect d.dm (fun () -> List.exists (fun s -> not s.over) d.senders)) t.dbs in
  while busy () && Unix.gettimeofday () -. t0 < 11. do
    Array.iter (fun d -> Follow.wake d.follow) t.dbs;
    Thread.delay 0.005
  done

(* ---- the replica: a follower a database ---- *)

(* a connection to a peer, mutual TLS, its certificate checked for the peer's address and name, the Hello *)
let rec connect ?(timeout = !handshake_s) ?(v = Option.value !version_override ~default:version) (cfg : Config.t) (p : Config.peer) =
  match cfg.tls with
  | None -> Error "a replica needs [tls]"
  | Some tl -> (
    match Tls.client_ctx ~cert:tl.cert ~key:tl.key ~ca:tl.ca () with
    | Error m -> Error m
    | Ok ctx -> (
      let host, port = Config.host_port "[[peer]] address" p.address in
      match
        Config.connect host port (fun fd -> timeouts fd timeout; Unix.setsockopt fd Unix.TCP_NODELAY true)
      with
      | exception Unix.Unix_error (e, _, _) -> Error (Printf.sprintf "%s (%s): %s" p.pname p.address (Unix.error_message e))
      | exception Failure m -> Error m
      | fd -> (
        match Tls.handshake ctx fd ~server:false ~host with
        | Error m -> (try Unix.close fd with Unix.Unix_error _ -> ()); Error (Printf.sprintf "%s (%s): TLS: %s" p.pname p.address m)
        | Ok tls -> (
          let l = { tls; fd; inb = Bytes.create 65536; have = 0; closed = Atomic.make false; until = 0.; pv = v } in
          if Tls.peer_name tls <> p.pname then (close_link l; Error (Printf.sprintf "%s's certificate names %S" p.address (Tls.peer_name tls)))
          else
            let b = Buffer.create 64 in
            Codec.put_varint b v; Codec.put_string b cfg.id; Codec.put_string b cfg.me;
            match send l ~kind:k_hello b; Result.map (fun r -> let _ = Codec.get_string r in Codec.get_string r) (expect l k_hello) with
            | Ok cluster -> if cluster <> cfg.id then (close_link l; Error (p.pname ^ " is of another cluster")) else Ok l
            | Error ("version", _) when v > oldest && !version_override = None ->
              (* an older peer (a rolling upgrade): its version *)
              close_link l;
              connect ~timeout ~v:(v - 1) cfg p
            | Error (c, m) -> close_link l; Error (Printf.sprintf "%s: %s: %s" p.pname c m)
            | exception (Broken m | Failure m) -> close_link l; Error (p.pname ^ ": " ^ m)
            | exception Codec.Short -> close_link l; Error (p.pname ^ ": a bad Hello")))))

let replicate_msg ~name ~epochs next =
  let b = Buffer.create 64 in
  Codec.put_string b name; Codec.put_varint b next; put_epochs b epochs; b

(* The id of database [name] on the primary: for a database not yet copied here, made with that id *)
let primary_id cfg (p : Config.peer) name =
  match connect cfg p with
  | Error m -> Error m
  | Ok l ->
    Fun.protect ~finally:(fun () -> close_link l) (fun () ->
        match send l ~kind:k_replicate (replicate_msg ~name ~epochs:first_epochs 1); Result.map Codec.get_string (expect l k_replicate) with
        | Ok id when String.length id = 16 -> Ok id
        | Ok _ -> Error "a bad reply"
        | Error (c, m) -> Error (c ^ ": " ^ m)
        | exception (Broken m) -> Error m
        | exception Codec.Short -> Error "a bad reply")

(* the frames in flight: given to the writer, not yet durable here *)
type flight = {
  fm : Mutex.t;
  fc : Condition.t;  (* the receiver waits: room in the window, or nothing in flight *)
  ac : Condition.t;  (* the acker waits: the oldest frame's outcome, a frame given, the end *)
  q : (Engine.req * int) Queue.t;
  mutable bytes : int;
  mutable failed : string option;
}

let window = ref (64 lsl 20)

(* one stream from the primary, until it breaks *)
let receive t d l =
  let fl = { fm = Mutex.create (); fc = Condition.create (); ac = Condition.create (); q = Queue.create (); bytes = 0; failed = None } in
  let durable () = (Atomic.get d.live.e.published).group in
  let ack g = let b = Buffer.create 16 in Codec.put_varint b g; (try send l ~kind:k_applied b with Broken _ -> ()) in
  let ender = ref false in
  (* the frames become durable in order: each said to the primary *)
  let acker =
    Thread.create
      (fun () ->
        let go = ref true in
        while !go do
          Mutex.lock fl.fm;
          while (Queue.is_empty fl.q && not !ender) || (match Queue.peek_opt fl.q with Some (r, _) -> r.res = None | None -> false) do
            Condition.wait fl.ac fl.fm
          done;
          match Queue.take_opt fl.q with
          | None -> Mutex.unlock fl.fm; go := false
          | Some (r, n) ->
            fl.bytes <- fl.bytes - n;
            Condition.broadcast fl.fc;
            Mutex.unlock fl.fm;
            (match Option.get r.res with
             | Ok rc -> ack rc.group
             | Error e ->
               Mutex.protect fl.fm (fun () -> if fl.failed = None then fl.failed <- Some (Engine.message e); Condition.broadcast fl.fc);
               shut l)
        done)
      ()
  in
  let wait_all () = Mutex.protect fl.fm (fun () -> while not (Queue.is_empty fl.q) do Condition.wait fl.fc fl.fm done) in
  let result =
    try
      while not (Atomic.get t.stopping) do
        match next_frame l with
        | k, flags, r when k = k_frame ->
          let first = Codec.get_varint r in
          let count = Codec.get_varint r in
          let crc = Codec.get_varint r in
          let len = Codec.get_varint r in
          if len > Journal.max_body || count < 1 || first < 1 then raise (Broken (Printf.sprintf "a frame of %d bytes and %d groups" len count));
          let body = Bytes.create len in
          let o = ref 0 and more = ref (flags land Wire.f_more <> 0) in
          let take (r : Codec.reader) =
            let n = r.stop - r.pos in
            if !o + n > len then raise (Broken "a frame longer than it said");
            Bytes.blit r.buf r.pos body !o n;
            o := !o + n
          in
          take r;
          while !more do
            match next_frame l with
            | k, flags, r when k = k_frame -> take r; more := flags land Wire.f_more <> 0
            | _ -> raise (Broken "a frame cut by another message")
          done;
          if !o <> len then raise (Broken "a frame shorter than it said");
          if Crc32c.bytes body 0 len <> crc then raise (Broken (Printf.sprintf "the frame of group %d does not check (CRC)" first));
          (* the window: at most [window] bytes in flight, but always one frame *)
          Mutex.protect fl.fm (fun () ->
              while fl.bytes > 0 && fl.bytes + len > !window && fl.failed = None do Condition.wait fl.fc fl.fm done);
          (match Mutex.protect fl.fm (fun () -> fl.failed) with Some m -> raise (Broken m) | None -> ());
          let req = { Engine.w = ([], 0, ""); res = None; rm = fl.fm; rc = fl.ac } in
          Mutex.protect fl.fm (fun () -> Queue.push (req, len) fl.q; fl.bytes <- fl.bytes + len; Condition.signal fl.ac);
          if not (Engine.submit d.live (Engine.Apply (req, { first; count; body; len }))) then Engine.deliver req (Error Engine.Closed)
        | k, _, r when k = k_beat -> d.primary_group <- Codec.get_varint r; ack (durable ())
        | k, _, r when k = k_stopped ->
          let g = Codec.get_varint r in
          d.primary_group <- g;
          wait_all ();
          (match Mutex.protect fl.fm (fun () -> fl.failed) with Some m -> raise (Broken m) | None -> ());
          if durable () = g then begin
            write_private (handover_path d.dir) (string_of_int g ^ "\n");
            d.handover <- Some g;
            log "database %s: the primary stopped at group %d, which this replica holds" d.name g
          end;
          ack (durable ())
        | _, flags, _ when flags land Wire.f_error <> 0 -> raise (Broken "the primary ended the stream with an error")
        | _ -> raise (Broken "an unexpected frame")
      done;
      Ok ()
    with
    | Broken m -> Error m
    | Codec.Short -> Error "a frame that does not decode"
    | e -> Error (Printexc.to_string e)
  in
  shut l;
  wait_all ();
  Mutex.protect fl.fm (fun () -> ender := true; Condition.broadcast fl.ac);
  Thread.join acker;
  close_link l;
  match Mutex.protect fl.fm (fun () -> fl.failed) with Some m -> Error m | None -> result

(* the follower of one database: connects, streams, and connects again after a pause that grows (0.1 s to 5 s) *)
let follow_loop t d (p : Config.peer) () =
  let pause = ref 0.1 and said = ref "" in
  let note m =
    d.last_error <- m;
    if m <> !said then (said := m; log "database %s: following %s: %s" d.name p.pname m)
  in
  while not (Atomic.get t.stopping) do
    (match connect t.cfg p with
     | Error m -> note m
     | Ok l -> (
       let next = (Atomic.get d.live.e.published).group + 1 in
       match send l ~kind:k_replicate (replicate_msg ~name:d.name ~epochs:d.epochs next); expect l k_replicate with
       | exception (Broken m) -> close_link l; note m
       | exception Codec.Short -> close_link l; note "a bad reply"
       | Error (code, m) -> close_link l; note (code ^ ": " ^ m); if code <> "unknown_database" then pause := 5.
       | Ok r -> (
         match
           let id = Codec.get_string r in
           let g = Codec.get_varint r in
           let h = get_epochs r in
           id, g, h
         with
         | exception Codec.Short -> close_link l; note "a bad reply"
         | id, _, _ when id <> d.live.e.id -> close_link l; note (p.pname ^ "'s database of this name is another database (another id)"); pause := 5.
         | _, g, h -> (
           match
             if h <> d.epochs then (save_epochs d.dir h; d.epochs <- h);
             if d.handover <> None then (remove_private (handover_path d.dir); d.handover <- None);
             timeouts l.fd !stream_s
           with
           | exception (Unix.Unix_error (e, _, x)) -> close_link l; note (Printf.sprintf "%s: %s" x (Unix.error_message e))
           | () ->
           d.primary_group <- g;
           Mutex.protect d.dm (fun () -> d.link <- Some l; d.connected <- true; d.connections <- d.connections + 1);
           if !said <> "" then log "database %s: following %s again from group %d" d.name p.pname next;
           said := "";
           d.last_error <- "";
           pause := 0.1;
           let r = receive t d l in
           Mutex.protect d.dm (fun () -> d.link <- None; d.connected <- false);
           match r with Ok () -> () | Error m -> note m))));
    if not (Atomic.get t.stopping) then begin
      let t0 = Unix.gettimeofday () in
      while (not (Atomic.get t.stopping)) && Unix.gettimeofday () -. t0 < !pause do Thread.delay 0.05 done;
      pause := min 5. (!pause *. 2.)
    end
  done

let start_followers t =
  match t.role with
  | Replica_of name -> (
    match peer_of t.cfg name with
    | None -> ()
    | Some p -> Array.iter (fun d -> d.thread <- Some (Thread.create (follow_loop t d p) ())) t.dbs)
  | _ -> ()

let stop_followers t =
  Atomic.set t.stopping true;
  Array.iter (fun d -> Option.iter shut (Mutex.protect d.dm (fun () -> d.link))) t.dbs;
  Array.iter (fun d -> Option.iter Thread.join d.thread; d.thread <- None) t.dbs

(* ---- promotion ---- *)

(* By hand (cepheus promote): refused while the primary sends to this replica (it is alive: stop it first), and,
   without [force], unless the primary handed every database over at its clean stop (so that no group it confirmed is
   missing here). Then: the followers stopped, every frame durable, a new epoch for each database from the group after
   its newest, the role file (the commit point), the histories, writes taken. *)
let rec promote t ~force =
  if not (Atomic.compare_and_set t.promoting false true) then Error ("busy", "a promotion is under way")
  else Fun.protect ~finally:(fun () -> Atomic.set t.promoting false) (fun () -> promote_once t ~force)

and promote_once t ~force =
  match t.role with
  | Primary | Promoted _ -> Error ("invalid", "this server is a primary already")
  | Replica_of p ->
    let up = Array.to_list t.dbs |> List.filter (fun d -> d.connected) |> List.map (fun d -> d.name) in
    if up <> [] then
      Error ("invalid", Printf.sprintf "%s is alive and sends %s to this replica: stop it first (cepheus stop on %s hands its last groups over), then promote" p (String.concat ", " up) p)
    else
      let missing () =
        Array.to_list t.dbs
        |> List.filter (fun d -> d.handover <> Some (Atomic.get d.live.e.published).group)
        |> List.map (fun d -> Printf.sprintf "%s (here up to group %d, %s)" d.name (Atomic.get d.live.e.published).group
                        (match d.handover with Some g -> Printf.sprintf "handed over at %d" g | None -> Printf.sprintf "the primary was seen at %d" d.primary_group))
      in
      if missing () <> [] && not force then
        Error ("invalid",
               Printf.sprintf "%s did not hand over %s: groups it confirmed after these may be missing here. Stop it cleanly (cepheus stop) and promote, or, once it cannot write any more (stopped, cut off, powered off), cepheus promote --force"
                 p (String.concat ", " (missing ())))
      else begin
        let before = Array.map (fun d -> d.connections) t.dbs in
        stop_followers t;
        if Array.exists2 (fun d n -> d.connections <> n) t.dbs before then begin
          Atomic.set t.stopping false;
          start_followers t;
          Error ("invalid", p ^ " came back while the promotion began: it is alive; stop it first")
        end
        else begin
          (* every frame given is durable (the followers waited for theirs): a new epoch from the next group *)
          match Array.map (fun d -> t.on_promote d) t.dbs with
          | exception Failure m ->
            Atomic.set t.stopping false;
            start_followers t;
            Error ("busy", m)
          | dones ->
          let opened = Array.to_list (Array.map (fun d -> d.name, last_epoch d.epochs + 1, (Atomic.get d.live.e.published).group + 1) t.dbs) in
          let role = Promoted (p, opened) in
          write_role t.cfg.data role;
          apply_promoted role ~dir_of:(Config.database_dir t.cfg);
          Array.iteri
            (fun i d ->
              d.epochs <- load_epochs d.dir;
              if d.handover <> None then (remove_private (handover_path d.dir); d.handover <- None);
              dones.(i) ();
              Engine.promote d.live)
            t.dbs;
          t.role <- role;
          Atomic.set t.stopping false;
          let l = List.map (fun (n, e, f) -> n, Printf.sprintf "epoch %d from group %d" e f) opened in
          log "promoted (it was a replica of %s): %s" p (String.concat ", " (List.map (fun (n, x) -> n ^ " " ^ x) l));
          Ok (("promoted_from", p) :: l)
        end
      end

(* ---- a primary's start: has a peer a newer epoch? ---- *)

(* Asks every other peer, at once, for its databases' histories (each at most [check_s] a step: the start waits
   for it beside the databases' opens): a peer whose history of a
   database has an epoch this server's lacks was promoted after this server was its primary: this server must not take
   writes (make it a replica of that peer). A peer that does not answer is noted. *)
let check_s = 1.0

let check_peers (cfg : Config.t) (mine : (string * epochs) list) =
  let others = List.filter (fun (p : Config.peer) -> p.pname <> cfg.me) cfg.peers in
  let res = Array.make (List.length others) (Error "no answer") in
  let ths =
    List.mapi
      (fun i p ->
        Thread.create
          (fun () ->
            res.(i) <-
              (try
                match connect ~timeout:check_s cfg p with
               | Error m -> Error m
               | Ok l ->
                 Fun.protect ~finally:(fun () -> close_link l) (fun () ->
                     match send l ~kind:k_epochs (Buffer.create 1); expect l k_epochs with
                     | Ok r -> Ok (List.init (Codec.get_varint r) (fun _ -> let n = Codec.get_string r in let g = Codec.get_varint r in n, g, get_epochs r))
                     | Error (c, m) -> Error (c ^ ": " ^ m)
                     | exception (Broken m) -> Error m
                     | exception Codec.Short -> Error "a bad reply")
               with e -> Error (Printexc.to_string e)))
          ())
      others
  in
  List.iter Thread.join ths;
  let newer = ref [] in
  List.iteri
    (fun i (p : Config.peer) ->
      match res.(i) with
      | Error m -> log "%s did not answer at start (%s): a promotion there would not be seen" p.pname m
      | Ok l ->
        List.iter
          (fun (n, _, h) ->
            match List.assoc_opt n mine with
            | Some ours when last_epoch h > last_epoch ours ->
              newer := Printf.sprintf "%s holds epoch %d of %s (this server: %d)" p.pname (last_epoch h) n (last_epoch ours) :: !newer
            | _ -> ())
          l)
    others;
  match !newer with
  | [] -> Ok ()
  | l ->
    Error (Printf.sprintf "%s: a replica was promoted after this server was its primary; this server must not take writes: make it a replica (cepheus replicate PEER --config ...)"
             (String.concat "; " (List.rev l)))
