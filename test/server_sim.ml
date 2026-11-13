(* Deterministic simulation of the server: the core of the real server (Core: every request from its frame to its
   reply, the rights, the sessions) over a simulated network and the simulated disk, one seed deciding everything:
   which client sends what (pipelined, with tokens of every right), how the bytes travel (cut at any byte, delayed,
   interleaved between connections), connections that break (requests and replies lost, the client connects again
   and sends its unanswered writes again with the same serials), the writer's batches and their commits, merges,
   checkpoints of the session tables, server deaths and power losses at any point (inside any disk call), failed
   fsyncs (the server stops and starts again, as systemd starts it), clean stops, and damaged session checkpoints.
   A failure prints its seed; [server_sim.exe --seed N] replays it.

   Checked through the protocol: G1 every receipt a client got survives every later crash; G2, G3 the journal holds
   exactly the groups the writer made; G4 a session's writes take groups in the order of their serials; G5 every read
   answers from a durable state, the exact state after the group it names, never before a write its client saw
   confirmed (read your writes); G10 nothing is confirmed after a failed fsync; G11 every Find's rows (and its
   aggregates) are the naive evaluator's on the model at the group it names; G14 each (session, serial) is in the
   journal at most once, and every receipt of it, first or resent, names that group and its new things; G16 a
   request is refused with "denied" exactly when its token lacks the right, and no group comes from a token that
   may not write.

   Local readers (G15) follow the database through the server's follow stream (Follow, Follower: the same code as
   the real server and client), with the events taken by the server's sender and applied by the reader at moments
   the seed draws (a reader paused, slow, or killed and started again; its stream cut when a server dies, with what
   was sent still readable), and the visibility page a value that a server's death keeps and a power loss resets.
   Every read, local or remote, is checked when it returns against three conditions, which make reads
   linearizable (spec/LocalReads.tla): it holds every group answered to any client before it started (Fresh), and
   every group any read returned before it started (Ordered), and it is the exact state of the journal at its group,
   durable (Durable: the model's facts at that group).

   Live questions (Watch) ride the same network: a client watches random questions (Give, projecting, aggregates),
   its pushes cut at any byte like replies, its connection broken at any message (it watches again from the group of
   its last message on the next connection: Same or the answer), the server's hub evaluating its frames late or at
   once, a watch falling behind (lagging: watched again), unwatched while its pushes are in flight; local readers
   watch on their follower, their stream cut by a server's death. At every message a watch gets its rows must be the
   naive evaluator's answer on the model at the message's group, a durable group, never older than its last
   message's (no gap, no duplicate, nothing shown before it is durable). *)

open Cepheus
module Top = Question.Top
open Cepheus_server
module C = Check

let dir = "/data/main"

let props =
  [ prop "name" Ttext; prop ~many:true "tag" Ttext; prop "score" Tint; prop ~unique:true "mail" Ttext;
    prop ~many:true "friend" Tlink; prop "at" Tdate; prop "price" (Tmoney 2) ]

let stats = Hashtbl.create 32
let count k = Hashtbl.replace stats k (1 + Option.value (Hashtbl.find_opt stats k) ~default:0)

exception Over

(* ---- tokens: one of each kind ---- *)
type kind = Writer | Reader | Stranger | Admin

let token_of = function Writer -> "w" | Reader -> "r" | Stranger -> "s" | Admin -> "a"

let tokens =
  let mk name databases admin = { Tokens.name; hash = Tokens.hash_of_text ("cph_" ^ name); databases; admin } in
  Tokens.with_tokens Tokens.empty
    [ mk "w" [ "main", Tokens.Write ] false; mk "r" [ "main", Tokens.Read ] false; mk "s" [ "other", Tokens.Write ] false;
      mk "a" [] true ]

(* ---- the world ---- *)

(* what any client knew when a read started: the newest group answered to any client, the newest group any read
   returned (Fresh and Ordered) *)
type known = { answered : int; returned : int }

(* a client's watch: its rows as its messages left them *)
type cwatch = {
  wq : Query.t;
  wsel : Wire.select;
  mutable wid : int option;  (* the id of its Watch on the current connection *)
  mutable wrows : Value.t array list;
  mutable wgroup : int;
  mutable wstarted : bool;
  mutable wparts : Wire.push option;  (* a message in several frames, so far *)
}

type pending_req =
  | P_watch of cwatch
  | P_hello
  | P_get of int * int * known  (* thing, the client's last confirmed group when sent *)
  | P_find of Query.t * Wire.select * int * known
  | P_write of int  (* serial *)
  | P_other of string

type sconn = {
  mutable cc : Core.conn option;
  to_server : Buffer.t;  (* sent by the client, not yet delivered *)
  mutable sin : Bytes.t;  (* the server's input: delivered, not yet used *)
  mutable sin_n : int;
  to_client : Buffer.t;  (* flushed by the server, not yet delivered *)
  mutable cin : Bytes.t;
  mutable cin_n : int;
  mutable alive : bool;
  outstanding : (int, pending_req) Hashtbl.t;  (* by request id *)
  rows : (int, Value.t array list) Hashtbl.t;  (* the rows of a Find in several frames, so far *)
  unwatched : (int, unit) Hashtbl.t;  (* watches ended by Unwatch: their pushes still in flight are dropped *)
}

type client = {
  kind : kind;
  cname : int;
  mutable conn : sconn option;
  mutable session : int;
  mutable welcomed : bool;
  mutable serial : int;
  unanswered : (int, Resolve.op list) Hashtbl.t;  (* serial -> ops *)
  mutable confirmed : int;  (* the newest group of a receipt it got *)
  mutable next_id : int;
  mutable watches : cwatch list;
}

type server = {
  e : Engine.t;
  follow : Follow.t;
  core : Core.t;
  sessions : Sessions.t;
  wq : (Resolve.op list * int * string * ((Engine.receipt, Engine.error) result -> unit)) Queue.t;
  mutable pending : (Engine.batch * ((Engine.receipt, Engine.error) result -> unit) array) option;
  mutable hub : Live.hub option;  (* made at the first Watch, as the real server's *)
  mutable last : Store.view * int;  (* the state after the newest frame taken, and its tag *)
  hq : [ `Frame of int * Group.t list * Store.view | `Large of int * Store.view | `Durable of int ] Queue.t;
      (* what the syncer gave the hub's thread, not yet evaluated *)
}

(* a local reader: a program on the server's machine; its stream's events in flight (sent by the server, not yet
   applied), and the run files they pass (their bytes: a passed descriptor keeps a file's content) *)
type ev = E of Follow.event | R of int * (int * int) list * Follower.file list

(* a watch of a local reader, on its follower *)
type lwatch = { lq : Query.t; lsel : Wire.select; mutable lrows : Value.t array list; mutable lgroup : int; mutable lstarted : bool;
                mutable lsub : Live.sub option }

type reader = {
  mutable lw : lwatch list;
  mutable fol : Follower.t option;
  mutable sf : Follow.follower option;  (* its queue at the server *)
  chan : ev Queue.t;
  mutable cut : bool;  (* its stream ended: once [chan] is applied, it stops *)
  mutable reading : known option;  (* a read in progress *)
}

type w = {
  seed : int;
  sim : Sim_disk.t;
  disk : Disk.t;
  r : Rng.t;
  mutable srv : server option;
  groups : (int, Group.t) Hashtbl.t;  (* every group the writer made, by number (lost ones removed at recovery) *)
  models : (int, C.F.t) Hashtbl.t;
  mutable acked : int;  (* the newest group any client got a receipt for *)
  mutable committed : int;  (* the newest durable group *)
  mutable stopped : bool;  (* a failed fsync: nothing may be confirmed until the restart *)
  clients : client array;
  receipts : (int * int, Engine.receipt) Hashtbl.t;  (* (session, serial) -> the first receipt a client saw *)
  page : int ref;  (* the visibility page's number: a server's death keeps it, a power loss resets it *)
  mutable returned : int;  (* the newest group a finished read returned *)
  readers : reader array;
}

let fail w fmt = Printf.ksprintf (fun s -> C.fail "seed %d: %s" w.seed s) fmt

let known w = { answered = w.acked; returned = w.returned }

let model w k =
  match Hashtbl.find_opt w.models k with
  | Some m -> m
  | None ->
    let rec build n = if n = 0 then C.F.empty else match Hashtbl.find_opt w.models n with Some m -> m | None -> (
        let prev = build (n - 1) in
        match Hashtbl.find_opt w.groups n with
        | Some g -> let m = C.apply_group prev g in Hashtbl.replace w.models n m; m
        | None -> fail w "group %d was never recorded" n; raise Over) in
    build k

let record_batch w (b : Engine.batch) =
  (* a large group's frame is written by pieces: its body is read back from the journal *)
  let body = match b.pending with Some p -> Journal.written_body p | None -> Buffer.to_bytes b.body in
  let r = Codec.reader body 0 (Bytes.length body) in
  for _ = 1 to b.count do
    let g = Group.decode r in
    Hashtbl.replace w.groups g.n g;
    Hashtbl.remove w.models g.n
  done

let server w = match w.srv with Some s -> s | None -> raise Over

(* ---- the server's side ---- *)

let start_server w =
  let rec go () =
    if Rng.chance w.r 0.1 then Sim_disk.crash_after w.sim (Rng.int w.r 15);
    match
      match Engine.open_ ~id_source:(fun _ -> "0123456789abcdef") w.disk dir with
      | Error e -> Error e
      | Ok e -> Ok (e, Sessions.load w.disk dir e.id)
    with
    | exception Sim_disk.Crash -> count "crash during a start"; Sim_disk.kill w.sim; go ()
    | Error (Io _) -> count "io error at a start"; Sim_disk.kill w.sim; go ()
    | Error e -> fail w "the server does not start: %s" (Engine.message e); raise Over
    | Ok (e, sessions) ->
      Sim_disk.crash_after w.sim (-1);
      let follow = Follow.create e { Follow.get = (fun () -> !(w.page)); set = (fun v -> w.page := v) } in
      let srv_ref = ref None in
      (* the hub, made at the first Watch at the newest frame taken (Watch.hub) *)
      let hub () =
        let s = Option.get !srv_ref in
        match s.hub with
        | Some h -> h
        | None ->
          let v, tag = s.last in
          let h = Live.create v ~tag ~durable:(Atomic.get s.e.published).group in
          s.hub <- Some h;
          h
      in
      let core_db = { Core.name = "main"; index = 0; dir; view = (fun () -> Follow.view follow); sessions;
                      more = (fun () -> Follow.status follow); hub;
                      files = Files.cell ~disk:w.disk ~master:(fun () -> Ok (String.make 32 'k')) (Filename.concat dir "vault") } in
      let core =
        Core.create ~server_id:"cph-s-sim" ~cluster_id:"cph-c-0000000000000000" ~dbs:[| core_db |] ~tokens
          ~now:w.disk.now ~new_session:(let n = ref (1000 * (1 + Rng.int w.r 1000)) in fun () -> incr n; !n)
          ~max_inflight:(1 + Rng.int w.r 4) ()
      in
      let p = Atomic.get e.published in
      let srv = { e; follow; core; sessions; wq = Queue.create (); pending = None; hub = None; last = p, p.group; hq = Queue.create () } in
      srv_ref := Some srv;
      w.srv <- Some srv;
      e
  in
  let e = go () in
  let k = e.working.group in
  (* G1: every receipt survives; G2, G3: the journal is the groups the writer made *)
  if k < w.acked then fail w "recovered to group %d, a client had a receipt for %d" k w.acked;
  Hashtbl.filter_map_inplace (fun n g -> if n <= k then Some g else None) w.groups;
  Hashtbl.filter_map_inplace (fun n m -> if n <= k then Some m else None) w.models;
  (try
     Journal.read w.disk (dir ^ "/journal") e.id (fun g ->
         match Hashtbl.find_opt w.groups g.n with
         | Some g' -> if not (Group.equal g g') then fail w "group %d differs from what the writer made" g.n
         | None -> if g.n > 1 then fail w "group %d was never made" g.n else Hashtbl.replace w.groups 1 g)
   with Journal.Damaged m -> fail w "the journal is damaged after recovery: %s" m);
  w.committed <- k;
  w.stopped <- false;
  if not (C.F.equal (C.facts_of_view e.working) (model w k)) then fail w "the state at %d is not the model's" k;
  (* G14: each (session, serial) at most once in the journal *)
  let seen = Hashtbl.create 64 in
  Hashtbl.iter
    (fun n (g : Group.t) ->
      match Origin.parse g.why with
      | Some (o, _) when o.serial > 0 ->
        (match Hashtbl.find_opt seen (o.session, o.serial) with
         | Some n' -> fail w "session %d serial %d is in groups %d and %d" o.session o.serial n' n
         | None -> Hashtbl.replace seen (o.session, o.serial) n);
        if o.token <> "w" then fail w "group %d comes from token %s, which may not write" n o.token
      | _ -> ())
    w.groups;
  count "starts"

let kill_server w ~power =
  w.srv <- None;
  Array.iter
    (fun r ->
      r.sf <- None;
      if power then (r.fol <- None; Queue.clear r.chan; r.cut <- false; r.reading <- None) else if r.fol <> None then r.cut <- true)
    w.readers;
  if power then w.page := Rng.int w.r (1 + !(w.page));
  Array.iter (fun c -> Option.iter (fun sc -> sc.alive <- false) c.conn; c.conn <- None; c.welcomed <- false) w.clients;
  if power then (count "power losses"; Sim_disk.crash w.sim) else (count "server deaths"; Sim_disk.kill w.sim)

let restart w ~power =
  kill_server w ~power;
  start_server w

let prepare w =
  let s = server w in
  if s.pending = None && not (Queue.is_empty s.wq) then begin
    let n = min (Queue.length s.wq) (1 + Rng.int w.r 5) in
    let items = Array.init n (fun _ -> Queue.take s.wq) in
    let b = Engine.prepare s.e (Array.map (fun (ops, by, why, _) -> ops, by, why) items) in
    record_batch w b;
    let taken = Array.length b.results in
    (* the requests the frame did not take go first in the next one *)
    let rest = Queue.create () in
    for i = taken to n - 1 do Queue.push items.(i) rest done;
    Queue.transfer s.wq rest;
    Queue.transfer rest s.wq;
    s.pending <- Some (b, Array.init taken (fun i -> let _, _, _, k = items.(i) in k))
  end

let commit w =
  let s = server w in
  match s.pending with
  | None -> ()
  | Some (b, ks) ->
    s.pending <- None;
    Follow.before s.follow b;
    (* Watch.before and after: the frame to the hub's thread, then the durable group *)
    if b.count > 0 then begin
      let tag = b.first + b.count - 1 in
      s.last <- b.after, tag;
      if s.hub <> None then Queue.push (if b.runs <> [] then `Large (tag, b.after) else `Frame (tag, List.rev b.groups, b.after)) s.hq
    end;
    let res = Engine.commit s.e b in
    Follow.after s.follow;
    if s.hub <> None then Queue.push (`Durable (Atomic.get s.e.published).group) s.hq;
    Array.iteri
      (fun i r ->
        (match r with
         | Ok (rc : Engine.receipt) ->
           if w.stopped then fail w "a write was confirmed after a failed fsync";
           w.committed <- max w.committed rc.group
         | Error (Io _) -> w.stopped <- true
         | Error _ -> ());
        ks.(i) r)
      res

(* the hub's thread: what the syncer gave it, evaluated at a moment the seed draws (at once, or frames later) *)
let hub_step w =
  let s = server w in
  match s.hub with
  | None -> ()
  | Some h ->
    for _ = 1 to 1 + Rng.int w.r 3 do
      match Queue.take_opt s.hq with
      | Some (`Frame (tag, gs, v)) -> Live.frame h ~tag gs v
      | Some (`Large (tag, v)) -> count "watches reset by a large group"; Live.reset h v ~tag
      | Some (`Durable g) -> Live.durable h g
      | None -> ()
    done

(* the transport's pusher: the pushes of every connection into its output *)
let push_step w =
  Array.iter
    (fun cl -> match cl.conn with Some { cc = Some c; alive = true; _ } -> if Core.move_pushes c then c.flush () | _ -> ())
    w.clients

(* ---- the network ---- *)

let deliver_to_server w sc =
  match sc.cc with
  | None -> ()
  | Some c ->
    let n = Buffer.length sc.to_server in
    if n > 0 && sc.alive then begin
      (* a random prefix of what was sent: frames cut at any byte *)
      let k = 1 + Rng.int w.r n in
      if sc.sin_n + k > Bytes.length sc.sin then begin
        let b = Bytes.create (max (sc.sin_n + k) (2 * Bytes.length sc.sin)) in
        Bytes.blit sc.sin 0 b 0 sc.sin_n;
        sc.sin <- b
      end;
      Buffer.blit sc.to_server 0 sc.sin sc.sin_n k;
      sc.sin_n <- sc.sin_n + k;
      let rest = Buffer.sub sc.to_server k (n - k) in
      Buffer.clear sc.to_server;
      Buffer.add_string sc.to_server rest
    end;
    let used, why = Core.input c sc.sin 0 sc.sin_n in
    Bytes.blit sc.sin used sc.sin 0 (sc.sin_n - used);
    sc.sin_n <- sc.sin_n - used;
    c.flush ();
    if why = Core.Shut then (count "connections closed by the server"; sc.alive <- false)

(* ---- the clients ---- *)

let declare_ops (v : Store.view) =
  let next = ref Schema.first_prop and ops = ref [] in
  List.iter
    (fun (d : prop) ->
      if Schema.by_name v.schema d.name = None then begin
        while Schema.find v.schema !next <> None do incr next done;
        let p = !next in
        incr next;
        ops := !ops @ List.map (fun (e, q, x) -> Add (e, q, x)) (Schema.facts p d)
      end)
    props;
  !ops

let gen_ops r (v : Store.view) =
  match declare_ops v with
  | _ :: _ as ops -> ops
  | [] ->
    let p n = Option.get (Schema.by_name v.schema n) in
    let things = v.next_e - Schema.first_thing in
    let some () = if things = 0 then -1 else Schema.first_thing + Rng.int r (things + 2) in
    let small = [| "a"; "b"; "c" |] in
    let one () =
      match Rng.int r 9 with
      | 0 | 1 -> [ Add (-1, p "name", Text ("n" ^ Rng.pick r small)); Add (-1, p "score", Int (Rng.int r 5)) ]
      | 2 -> [ Add (some (), p "score", Int (Rng.int r 5)) ]
      | 3 -> [ Add (some (), p "tag", Text (Rng.pick r small)) ]
      | 4 -> [ Retract (some (), p "tag", Text (Rng.pick r small)) ]
      | 5 -> [ Add (some (), p "mail", Text (Rng.pick r small ^ "@x")) ]
      | 6 -> [ Add (-1, p "friend", Link (some ())); Add (-2, p "friend", Link (-1)) ]
      | 7 -> [ Expect (some (), p "score", Some (Int (Rng.int r 5))); Add (some (), p "price", Money (Rng.int r 1000)) ]
      | _ -> [ Add (some (), p "at", Date (Rng.int r 1000)) ]
    in
    List.concat (List.init (1 + Rng.int r 2) (fun _ -> one ()))

let new_conn w (cl : client) =
  let s = server w in
  let sc =
    { cc = None; to_server = Buffer.create 256; sin = Bytes.create 256; sin_n = 0; to_client = Buffer.create 256;
      cin = Bytes.create 256; cin_n = 0; alive = true; outstanding = Hashtbl.create 8; rows = Hashtbl.create 2;
      unwatched = Hashtbl.create 2 }
  in
  let flush c () =
    if sc.alive then Buffer.add_buffer sc.to_client c.Core.out;
    Buffer.clear c.Core.out
  in
  let rec core =
    lazy
      (Core.connect s.core
         ~flush:(fun () -> flush (Lazy.force core) ())
         ~submit:(fun _ ops by why k -> (server w).wq |> Queue.push (ops, by, why, k)))
  in
  sc.cc <- Some (Lazy.force core);
  cl.conn <- Some sc;
  cl.welcomed <- false;
  sc

let send (cl : client) sc req what =
  let id = cl.next_id in
  cl.next_id <- cl.next_id + 1;
  let body = Buffer.create 64 in
  Wire.put_request body req;
  Wire.add_frame sc.to_server ~id ~kind:(Wire.request_kind req) ~flags:0 body;
  Hashtbl.replace sc.outstanding id what

let floor (cl : client) = Hashtbl.fold (fun s _ m -> min s m) cl.unanswered (cl.serial + 1)

let send_write cl sc serial ops =
  send cl sc (Wire.Write { db = 0; serial; floor = floor cl; by = cl.cname; why = "sim"; ops }) (P_write serial)

let allowed_read = function Writer | Reader -> true | Stranger | Admin -> false

let denied_ok w (cl : client) what code expect_ok =
  if code = "denied" && expect_ok then fail w "client %d (%s) was denied %s" cl.cname (token_of cl.kind) what
  else if code <> "denied" && not expect_ok then fail w "client %d (%s) was not denied %s but got %s" cl.cname (token_of cl.kind) what code

(* the group of (session, serial) among the groups made *)
let origin_group w session serial =
  Hashtbl.fold
    (fun n (g : Group.t) acc ->
      match Origin.parse g.why with Some (o, _) when o.session = session && o.serial = serial -> n :: acc | _ -> acc)
    w.groups []

(* a read that started knowing [k] returns the state of group [g]: Fresh and Ordered (Durable: its facts against
   the model, by the caller) *)
let linearizable w what (k : known) g =
  if g < k.answered then fail w "%s returned group %d, after group %d was answered (Fresh)" what g k.answered;
  if g < k.returned then fail w "%s returned group %d, after a read returned group %d (Ordered)" what g k.returned;
  if g > w.committed then fail w "%s returned group %d, not durable (%d)" what g w.committed;
  w.returned <- max w.returned g

(* the naive evaluator's answer of a question with its select, on the model at group [g] *)
let expected w g (q : Query.t) (sel : Wire.select) =
  let naive = C.naive (model w g) q in
  match sel with
  | Wire.Give [||] -> naive
  | Wire.Give give -> List.map (fun row -> Array.map (fun x -> row.(x)) give) naive
  | Wire.Group (keys, aggs) ->
    let t = Hashtbl.create 8 in
    List.iter
      (fun row ->
        let k = Array.map (fun x -> row.(x)) keys in
        Hashtbl.replace t k (row :: Option.value (Hashtbl.find_opt t k) ~default:[]))
      naive;
    Hashtbl.fold
      (fun k rs acc ->
        let num = function Value.Int n | Value.Money n | Value.Date n -> n | _ -> 0 in
        let mk x n = match List.hd rs |> fun row -> row.(x) with Value.Money _ -> Value.Money n | Value.Date _ -> Value.Date n | _ -> Value.Int n in
        let a =
          Array.map
            (function
              | Wire.Count -> Value.Int (List.length rs)
              | Wire.Sum x -> mk x (List.fold_left (fun s row -> s + num row.(x)) 0 rs)
              | Wire.Min x -> mk x (List.fold_left (fun s row -> min s (num row.(x))) max_int rs)
              | Wire.Max x -> mk x (List.fold_left (fun s row -> max s (num row.(x))) min_int rs))
            aggs
        in
        Array.append k a :: acc)
      t []

let rec remove_one x = function [] -> None | y :: r when y = x -> Some r | y :: r -> Option.map (fun r -> y :: r) (remove_one x r)

(* a message of a watch, applied to its rows: then they must be the model's answer at its group *)
let watch_message w what rows group0 started (m : Wire.push) =
  let g = match m with Wire.Answer a -> a.group | Change c -> c.group | Same g -> g in
  if g > w.committed then fail w "%s: a message of group %d, not durable (%d)" what g w.committed;
  (match m with
   | Wire.Change _ -> if not started || g <= group0 then fail w "%s: a change of group %d after %d" what g group0
   | Same _ -> if not started || g < group0 then fail w "%s: same %d after %d" what g group0
   | Answer _ -> if g < group0 then fail w "%s: an answer of group %d after %d" what g group0);
  let rows =
    match m with
    | Wire.Answer a -> a.rows
    | Same _ -> rows
    | Change c ->
      let rows = List.fold_left (fun rows x -> match remove_one x rows with Some r -> r | None -> fail w "%s: a row removed that it does not hold" what; rows) rows c.removed in
      c.added @ rows
  in
  rows, g

let check_watch w what rows g q sel =
  if C.sorted_rows rows <> C.sorted_rows (expected w g q sel) then
    fail w "%s at group %d: %d rows, the naive evaluator %d" what g (List.length rows) (List.length (expected w g q sel))
  else count (what ^ "es checked")

let send_watch (cl : client) sc cw =
  let from = if cw.wstarted then cw.wgroup else 0 in
  cw.wparts <- None;
  let id = cl.next_id in
  cl.next_id <- cl.next_id + 1;
  let body = Buffer.create 64 in
  Wire.put_request body (Wire.Watch { db = 0; query = cw.wq; select = cw.wsel; from; wextra = [] });
  Wire.add_frame sc.to_server ~id ~kind:Wire.k_watch ~flags:0 body;
  Hashtbl.replace sc.outstanding id (P_watch cw);
  cw.wid <- Some id

let on_watch w (cl : client) sc id flags body cw =
  let r = Codec.reader body 0 (Bytes.length body) in
  if cw.wid <> Some id then ()
  else if flags land Wire.f_error <> 0 then begin
    Hashtbl.remove sc.outstanding id;
    cw.wid <- None;
    match Wire.get_reply Wire.k_watch flags r with
    | Wire.Err { code = "lagging"; _ } -> count "watches lagging"; send_watch cl sc cw
    | Wire.Err e ->
      denied_ok w cl "a watch" e.code (allowed_read cl.kind);
      if e.code <> "denied" && e.code <> "invalid" then fail w "a watch failed: %s %s" e.code e.message;
      cl.watches <- List.filter (fun x -> x != cw) cl.watches
    | _ -> fail w "a watch's error does not decode"
  end
  else begin
    let part = try Wire.get_push r with Codec.Short -> fail w "a push does not decode"; raise Over in
    let m = match cw.wparts with Some p -> Wire.join_push p part | None -> part in
    if flags land Wire.f_more <> 0 then cw.wparts <- Some m
    else begin
      cw.wparts <- None;
      if not (allowed_read cl.kind) then fail w "client %s watched without the right" (token_of cl.kind);
      let rows, g = watch_message w "a watch" cw.wrows cw.wgroup cw.wstarted m in
      cw.wrows <- rows;
      cw.wgroup <- g;
      cw.wstarted <- true;
      check_watch w "a watch" rows g cw.wq cw.wsel
    end
  end

let on_reply w (cl : client) sc id kind flags body =
  match Hashtbl.find_opt sc.outstanding id with
  | Some (P_watch cw) when kind = Wire.k_watch -> on_watch w cl sc id flags body cw
  | None when Hashtbl.mem sc.unwatched id -> ()
  | _ ->
  let r = Codec.reader body 0 (Bytes.length body) in
  let rep = try Wire.get_reply kind flags r with Codec.Short -> fail w "a reply does not decode"; raise Over in
  match Hashtbl.find_opt sc.outstanding id with
  | None -> fail w "a reply to request %d, which was not asked" id
  | Some what -> (
    let more = flags land Wire.f_more <> 0 in
    if not more then Hashtbl.remove sc.outstanding id;
    match what, rep with
    | P_hello, Wire.Welcome wl ->
      if cl.session <> 0 && wl.session <> cl.session then fail w "the session %d was not resumed (%d)" cl.session wl.session;
      cl.session <- wl.session;
      cl.welcomed <- true;
      (* the writes still unanswered, again, with their serials, in order *)
      let l = List.sort compare (Hashtbl.fold (fun s ops acc -> (s, ops) :: acc) cl.unanswered []) in
      List.iter (fun (s, ops) -> count "writes sent again"; send_write cl sc s ops) l;
      (* the watches again, each from the group of its last message *)
      List.iter (fun cw -> if cw.wstarted then count "watches resumed"; send_watch cl sc cw) cl.watches
    | P_hello, Wire.Err e -> fail w "Hello refused: %s %s" e.code e.message
    | P_get (thing, min_group, k), Wire.Facts f ->
      if not (allowed_read cl.kind) then fail w "client %s read without the right" (token_of cl.kind);
      linearizable w "a Get" k f.group;
      if f.group > w.committed then fail w "a Get answered from group %d, not durable (%d)" f.group w.committed;
      if f.group < min_group then fail w "a Get answered from group %d, before the client's confirmed %d" f.group min_group;
      let want = C.F.elements (C.F.filter (fun (e, _, _) -> e = thing) (model w f.group)) |> List.map (fun (_, p, v) -> p, v) in
      if List.sort compare f.facts <> List.sort compare want then fail w "a Get of #%d at group %d is not the model's" thing f.group;
      count "gets checked"
    | P_find (q, sel, min_group, k), Wire.Rows rw ->
      let prev = Option.value (Hashtbl.find_opt sc.rows id) ~default:[] in
      let rows = prev @ rw.rows in
      if more then Hashtbl.replace sc.rows id rows
      else begin
        Hashtbl.remove sc.rows id;
        if not (allowed_read cl.kind) then fail w "client %s found without the right" (token_of cl.kind);
        linearizable w "a Find" k rw.group;
        if rw.group > w.committed then fail w "a Find answered from group %d, not durable" rw.group;
        if rw.group < min_group then fail w "a Find answered from group %d, before the client's confirmed %d" rw.group min_group;
        let naive = C.naive (model w rw.group) q in
        let want =
          match sel with
          | Wire.Give [||] -> naive
          | Wire.Give give -> List.map (fun row -> Array.map (fun x -> row.(x)) give) naive
          | Wire.Group (keys, aggs) ->
            let t = Hashtbl.create 8 in
            List.iter
              (fun row ->
                let k = Array.map (fun x -> row.(x)) keys in
                Hashtbl.replace t k (row :: Option.value (Hashtbl.find_opt t k) ~default:[]))
              naive;
            Hashtbl.fold
              (fun k rs acc ->
                let num = function Value.Int n | Value.Money n | Value.Date n -> n | _ -> 0 in
                let mk x n = match List.hd rs |> fun row -> row.(x) with Value.Money _ -> Value.Money n | Value.Date _ -> Value.Date n | _ -> Value.Int n in
                let a =
                  Array.map
                    (function
                      | Wire.Count -> Value.Int (List.length rs)
                      | Wire.Sum x -> mk x (List.fold_left (fun s row -> s + num row.(x)) 0 rs)
                      | Wire.Min x -> mk x (List.fold_left (fun s row -> min s (num row.(x))) max_int rs)
                      | Wire.Max x -> mk x (List.fold_left (fun s row -> max s (num row.(x))) min_int rs))
                    aggs
                in
                Array.append k a :: acc)
              t []
        in
        if C.sorted_rows rows <> C.sorted_rows want then
          fail w "a Find at group %d gives %d rows, the naive evaluator %d" rw.group (List.length rows) (List.length want);
        count "finds checked"
      end
    | P_write serial, Wire.Receipt rc ->
      if cl.kind <> Writer then fail w "client %s wrote without the right" (token_of cl.kind);
      let ops = Option.value (Hashtbl.find_opt cl.unanswered serial) ~default:[] in
      Hashtbl.remove cl.unanswered serial;
      if rc.group > w.committed then fail w "a receipt for group %d, not durable (%d)" rc.group w.committed;
      (* G14: the group of this (session, serial), and only one *)
      (match origin_group w cl.session serial with
       | [ g ] -> if g <> rc.group then fail w "session %d serial %d: receipt names group %d, the journal %d" cl.session serial rc.group g
       | l -> fail w "session %d serial %d is in %d groups" cl.session serial (List.length l));
      (* its new things: numbered as the engine numbered them *)
      (match Hashtbl.find_opt w.groups rc.group with
       | Some g ->
         if rc.things <> Sessions.things ops g.first_new then fail w "session %d serial %d: the receipt's new things differ" cl.session serial;
         if g.count_new <> List.length rc.things then fail w "group %d made %d things, its receipt names %d" g.n g.count_new (List.length rc.things)
       | None -> fail w "a receipt for group %d, which was not made" rc.group);
      (match Hashtbl.find_opt w.receipts (cl.session, serial) with
       | Some r0 -> if r0 <> rc then fail w "session %d serial %d: a second receipt differs from the first" cl.session serial
       | None -> Hashtbl.replace w.receipts (cl.session, serial) rc);
      (* G4: groups follow serials within a session *)
      Hashtbl.iter
        (fun (s, k) (r0 : Engine.receipt) ->
          if s = cl.session && ((k < serial && r0.group > rc.group) || (k > serial && r0.group < rc.group)) then
            fail w "session %d: serial %d in group %d, serial %d in group %d" s k r0.group serial rc.group)
        w.receipts;
      cl.confirmed <- max cl.confirmed rc.group;
      w.acked <- max w.acked rc.group;
      count "receipts"
    | P_write serial, Wire.Err e ->
      Hashtbl.remove cl.unanswered serial;
      denied_ok w cl "a write" e.code (cl.kind = Writer);
      if e.code = "io" then count "writes failed on io" else count ("writes refused: " ^ e.code)
    | (P_get _ | P_find _), Wire.Err e ->
      denied_ok w cl "a read" e.code (allowed_read cl.kind);
      if e.code <> "denied" && e.code <> "invalid" then fail w "a read failed: %s %s" e.code e.message;
      count ("reads refused: " ^ e.code)
    | P_other "status", Wire.Status _ -> if cl.kind <> Admin then fail w "status without the admin right"; count "status"
    | P_other "status", Wire.Err e -> denied_ok w cl "status" e.code (cl.kind = Admin)
    | P_other "ping", Wire.Pong _ -> count "pongs"
    | P_other "unwatch", Wire.Unwatched -> count "unwatched"
    | _, Wire.Err e -> fail w "an unexpected error %s: %s" e.code e.message
    | _ -> fail w "an unexpected reply")

let deliver_to_client w (cl : client) sc =
  let n = Buffer.length sc.to_client in
  if n > 0 then begin
    let k = 1 + Rng.int w.r n in
    if sc.cin_n + k > Bytes.length sc.cin then begin
      let b = Bytes.create (max (sc.cin_n + k) (2 * Bytes.length sc.cin)) in
      Bytes.blit sc.cin 0 b 0 sc.cin_n;
      sc.cin <- b
    end;
    Buffer.blit sc.to_client 0 sc.cin sc.cin_n k;
    sc.cin_n <- sc.cin_n + k;
    let rest = Buffer.sub sc.to_client k (n - k) in
    Buffer.clear sc.to_client;
    Buffer.add_string sc.to_client rest
  end;
  let o = ref 0 in
  while sc.cin_n - !o >= 4 && sc.cin_n - !o >= 4 + Wire.u32 sc.cin !o do
    let len = Wire.u32 sc.cin !o in
    let id = Wire.u32 sc.cin (!o + 4) and kind = Bytes.get_uint8 sc.cin (!o + 8) and flags = Bytes.get_uint8 sc.cin (!o + 9) in
    on_reply w cl sc id kind flags (Bytes.sub sc.cin (!o + Wire.header) (len - 6));
    o := !o + 4 + len
  done;
  Bytes.blit sc.cin !o sc.cin 0 (sc.cin_n - !o);
  sc.cin_n <- sc.cin_n - !o

(* ---- local readers ---- *)

(* a run's bytes, as a descriptor passed now would keep them: the final name, or a large group's temporary one *)
let run_bytes w (r : Follow.run) =
  let try_ p = if w.disk.exists p then Some (Disk.read_all w.disk p) else None in
  match (match r.tmp with Some t -> try_ t | None -> None) with Some b -> Some b | None -> try_ r.path

let reader_connect w r =
  let s = server w in
  let f, vseq, vis = Follow.register s.follow in
  let runs = Follow.names s.follow.sdir vis.runs in
  let files = List.map (run_bytes w) runs in
  if List.mem None files then (Follow.unregister s.follow f; count "follows refused: a run removed")
  else
    match
      Follower.create ~id:s.e.id ~word:(fun () -> !(w.page)) ~names:(List.map (fun (x : Follow.run) -> x.lo, x.hi) runs)
        ~files:(List.map (fun b -> Follower.Mem (Option.get b)) files)
    with
    | exception Follower.Stream m -> fail w "a follower does not start: %s" m
    | fol ->
      Queue.clear r.chan;
      Follow.catch_up w.disk s.e vis (fun ev -> Queue.push (E ev) r.chan);
      Queue.push (E (Follow.Frame { vseq; first = vis.group + 1; count = 0; body = Buffer.create 0 })) r.chan;
      r.fol <- Some fol;
      r.sf <- Some f;
      r.cut <- false;
      count "follows"

(* the server's sender: what is queued, into the stream; a run gone already cuts the stream (the reader connects
   again), as a descriptor that cannot be opened does *)
let reader_send w r =
  match w.srv, r.sf with
  | Some s, Some f ->
    if f.dead then (r.sf <- None; r.cut <- true; count "followers cut off")
    else
      List.iter
        (fun ev ->
          match ev with
          | Follow.Frame _ | Follow.Durable _ -> Queue.push (E ev) r.chan
          | Follow.Runs x ->
            let files = List.map (run_bytes w) x.runs in
            if List.mem None files then (Follow.unregister s.follow f; r.sf <- None; r.cut <- true; count "streams cut: a run removed")
            else if r.sf <> None then
              Queue.push (R (x.vseq, List.map (fun (y : Follow.run) -> y.lo, y.hi) x.runs, List.map (fun b -> Follower.Mem (Option.get b)) files)) r.chan)
        (Follow.drain s.follow f)
  | _ -> ()

(* the reader applies the next event; at the end of a cut stream it stops *)
let reader_apply w r =
  match r.fol with
  | None -> ()
  | Some fol -> (
    match Queue.take_opt r.chan with
    | Some ev -> (
      match
        match ev with
        | E (Follow.Frame f) -> Follower.frame fol ~vseq:f.vseq ~first:f.first ~count:f.count (Buffer.to_bytes f.body)
        | E (Follow.Runs _) -> ()
        | E (Follow.Durable v) -> Follower.durable fol v
        | R (vseq, names, files) -> Follower.runs fol ~vseq ~names ~files
      with
      | () -> count "events applied"
      | exception Follower.Stream m -> fail w "a follower failed: %s" m)
    | None ->
      if r.cut then begin
        Follower.stop fol;
        r.fol <- None;
        r.cut <- false;
        r.reading <- None;
        count "streams ended"
      end)

(* a program's read in the reader: it starts, then returns the state visible under the page's number, or waits *)
let reader_read w r =
  match r.fol, r.reading with
  | None, _ -> ()
  | Some _, None -> r.reading <- Some (known w)
  | Some fol, Some k -> (
    match Follower.try_view fol with
    | None -> count "local reads waiting"
    | Some v ->
      r.reading <- None;
      linearizable w "a local read" k v.group;
      if not (C.F.equal (C.facts_of_view v) (model w v.group)) then fail w "a local read at group %d is not the model's state" v.group;
      count "local reads checked")

(* a local watch on the reader's follower, from the group of its last message *)
let local_subscribe w r (lw : lwatch) =
  match r.fol with
  | Some fol when lw.lsub = None && Follower.try_view fol <> None -> (
    match Follower.hub fol with
    | None -> ()
    | Some h -> (
      let emit (m : Live.msg) =
        (match m with
         | Live.Ended _ -> lw.lsub <- None
         | _ ->
           let p =
             match m with
             | Live.Answer a -> Wire.Answer { group = a.group; cols = 0; rows = a.rows }
             | Change c -> Wire.Change { group = c.group; cols = 0; added = c.added; removed = c.removed }
             | Same s -> Wire.Same s.group
             | Ended _ -> assert false
           in
           let rows, g = watch_message w "a local watch" lw.lrows lw.lgroup lw.lstarted p in
           lw.lrows <- rows;
           lw.lgroup <- g;
           lw.lstarted <- true;
           check_watch w "a local watch" rows g lw.lq lw.lsel);
        true
      in
      match Live.subscribe h lw.lq lw.lsel ~from:(if lw.lstarted then lw.lgroup else 0) ~emit with
      | sub -> lw.lsub <- Some sub; count "local watches"
      | exception Failure m -> count ("local watches refused: " ^ m)
      | exception Query.Bad m -> fail w "a local watch refused: %s" m))
  | _ -> ()

let reader_watch w r =
  match r.fol with
  | Some fol when Follower.try_view fol <> None ->
    List.iter (local_subscribe w r) r.lw;
    if List.length r.lw < 2 then (
      (* the question from the server's schema, as a program has it from Connect *)
      match Option.map (fun s -> Atomic.get s.e.published) w.srv with
      | Some v -> (
        let facts = C.facts_of_view v in
        let rec ask k = match C.random_query w.r v facts (List.map (fun (d : prop) -> d.name) props) with None when k > 0 -> ask (k - 1) | q -> q in
        match ask 20 with
        | None -> ()
        | Some q ->
          let lsel = if Rng.bool w.r then Wire.Give [||] else Wire.Give (Array.init (1 + Rng.int w.r q.vars) (fun _ -> Rng.int w.r q.vars)) in
          let lw = { lq = q; lsel; lrows = []; lgroup = 0; lstarted = false; lsub = None } in
          r.lw <- lw :: r.lw;
          local_subscribe w r lw)
      | None -> ())
  | _ -> ()

let reader_step w r =
  match Rng.int w.r 13 with
  | 10 | 11 | 12 -> if r.fol = None && w.srv <> None && not r.cut then reader_connect w r else begin
      (* the reader catches up with its stream, then watches *)
      reader_send w r;
      while r.fol <> None && not (Queue.is_empty r.chan) do reader_apply w r done;
      reader_watch w r
    end
  | 0 -> if r.fol = None && w.srv <> None && not r.cut then reader_connect w r
  | 1 | 2 -> reader_send w r
  | 3 | 4 | 5 -> reader_apply w r
  | 6 | 7 | 8 -> reader_read w r
  | _ ->
    if Rng.chance w.r 0.05 then begin
      (* the reader's process dies *)
      (match w.srv, r.sf with Some s, Some f -> Follow.unregister s.follow f | _ -> ());
      Option.iter Follower.stop r.fol;
      r.lw <- [];
      r.fol <- None;
      r.sf <- None;
      r.cut <- false;
      r.reading <- None;
      Queue.clear r.chan;
      count "readers killed"
    end

let client_step w (cl : client) =
  let s = server w in
  match cl.conn with
  | Some sc when not sc.alive ->
    (* the connection broke: what was in flight is lost; the client will connect again *)
    cl.conn <- None
  | None ->
    let sc = new_conn w cl in
    send cl sc (Wire.Hello { version = Wire.version; token = "cph_" ^ token_of cl.kind; program = "sim"; session = cl.session }) P_hello
  | Some sc when not cl.welcomed -> ignore sc
  | Some sc ->
    if Hashtbl.length sc.outstanding < 4 then begin
      let v = Atomic.get s.e.published in
      match Rng.int w.r 10 with
      | 0 | 1 | 2 | 3 when cl.kind = Writer || Rng.chance w.r 0.3 ->
        if Hashtbl.length cl.unanswered < 6 then begin
          cl.serial <- cl.serial + 1;
          let ops = gen_ops w.r v in
          Hashtbl.replace cl.unanswered cl.serial ops;
          send_write cl sc cl.serial ops
        end
      | 4 | 5 ->
        let thing = Schema.first_thing + Rng.int w.r (max 1 (v.next_e - Schema.first_thing + 1)) in
        send cl sc (Wire.Get { db = 0; thing }) (P_get (thing, cl.confirmed, known w))
      | 6 | 7 -> (
        match C.random_query w.r v (C.facts_of_view v) (List.map (fun (d : prop) -> d.name) props) with
        | None -> ()
        | Some q ->
          let sel =
            match Rng.int w.r 3 with
            | 0 -> Wire.Give [||]
            | 1 -> Wire.Give (Array.init (1 + Rng.int w.r q.vars) (fun _ -> Rng.int w.r q.vars))
            | _ -> (
              let ty = Query.types v q in
              let nums = List.filter (fun x -> match ty.(x) with Tint | Tmoney _ -> true | _ -> false) (List.init q.vars Fun.id) in
              let key = if q.vars > 1 then [| Rng.int w.r q.vars |] else [||] in
              match nums with
              | x :: _ -> Wire.Group (key, [| Wire.Count; Wire.Sum x; Wire.Min x; Wire.Max x |])
              | [] -> Wire.Group (key, [| Wire.Count |]))
          in
          send cl sc (Wire.Find { db = 0; query = q; select = sel; extra = []; order = Top.none }) (P_find (q, sel, cl.confirmed, known w)))
      | 8 when Rng.bool w.r -> send cl sc (Wire.Admin "status") (P_other "status")
      | 8 -> (
        (* a watch: a new one, or one unwatched *)
        match cl.watches with
        | cw :: rest when List.length cl.watches >= 3 || Rng.chance w.r 0.2 ->
          (match cw.wid with
           | Some id ->
             Hashtbl.remove sc.outstanding id;
             Hashtbl.replace sc.unwatched id ();
             send cl sc (Wire.Unwatch id) (P_other "unwatch")
           | None -> ());
          cl.watches <- rest
        | _ -> (
          match C.random_query w.r v (C.facts_of_view v) (List.map (fun (d : prop) -> d.name) props) with
          | None -> ()
          | Some q ->
            let sel =
              match Rng.int w.r 3 with
              | 0 -> Wire.Give [||]
              | 1 -> Wire.Give (Array.init (1 + Rng.int w.r q.vars) (fun _ -> Rng.int w.r q.vars))
              | _ -> (
                let ty = Query.types v q in
                let nums = List.filter (fun x -> match ty.(x) with Tint | Tmoney _ -> true | _ -> false) (List.init q.vars Fun.id) in
                let key = if q.vars > 1 then [| Rng.int w.r q.vars |] else [||] in
                match nums with
                | x :: _ -> Wire.Group (key, [| Wire.Count; Wire.Sum x; Wire.Min x; Wire.Max x |])
                | [] -> Wire.Group (key, [| Wire.Count |]))
            in
            let cw = { wq = q; wsel = sel; wid = None; wrows = []; wgroup = 0; wstarted = false; wparts = None } in
            cl.watches <- cl.watches @ [ cw ];
            count "watches";
            send_watch cl sc cw))
      | _ -> send cl sc (Wire.Ping "x") (P_other "ping")
    end

let step w =
  let s = server w in
  match Rng.int w.r 100 with
  | n when n < 19 -> client_step w (Rng.pick w.r w.clients)
  | n when n < 21 -> hub_step w
  | n when n < 22 -> push_step w;
    (* a watch falls behind: the next push finds its connection's queue full *)
    if Rng.chance w.r 0.05 then (Core.max_pushes := 0; push_step w; hub_step w; Core.max_pushes := 8 lsl 20)
  | n when n < 36 -> if Array.length w.readers > 0 then reader_step w (Rng.pick w.r w.readers)
  | n when n < 52 ->
    let cl = Rng.pick w.r w.clients in
    Option.iter (deliver_to_server w) cl.conn
  | n when n < 65 -> let cl = Rng.pick w.r w.clients in Option.iter (deliver_to_client w cl) cl.conn
  | n when n < 75 -> prepare w
  | n when n < 85 -> commit w
  | n when n < 87 ->
    (* a connection breaks: bytes in flight both ways are lost *)
    let cl = Rng.pick w.r w.clients in
    Option.iter (fun sc -> sc.alive <- false; count "connections broken") cl.conn
  | n when n < 89 ->
    if s.pending = None && not w.stopped then (match Engine.snapshot s.e with Ok () -> count "merges"; Follow.tick s.follow | Error _ -> ())
  | n when n < 91 -> (
    (* as the server's ticker: a failed checkpoint is reported, the older one stays *)
    match Sessions.save w.disk dir s.sessions ~published:(Atomic.get s.e.published).group ~now:(w.disk.now ()) with
    | () -> count "checkpoints"
    | exception Disk.Io _ -> count "checkpoints failed")
  | n when n < 92 -> ignore (restart w ~power:true)
  | n when n < 93 -> ignore (restart w ~power:false)
  | n when n < 94 ->
    (* a clean stop: the writes sent are written and answered, the database closed, the sessions saved *)
    while s.pending <> None || not (Queue.is_empty s.wq) do commit w; prepare w; commit w done;
    Engine.close s.e;
    (match Sessions.save w.disk dir s.sessions ~published:(Atomic.get s.e.published).group ~now:(w.disk.now ()) with
     | () -> ()
     | exception Disk.Io _ -> count "checkpoints failed");
    count "clean stops";
    w.srv <- None;
    Array.iter (fun r -> r.sf <- None; if r.fol <> None then r.cut <- true) w.readers;
    Array.iter (fun c -> Option.iter (fun sc -> sc.alive <- false) c.conn; c.conn <- None) w.clients;
    ignore (start_server w)
  | n when n < 95 -> Sim_disk.crash_after w.sim (Rng.int w.r 20)
  | n when n < 96 -> Sim_disk.fail_next_fsync w.sim
  | n when n < 97 ->
    (* a damaged checkpoint: ignored at the next start, the journal read from its beginning *)
    if Sim_disk.flip_durable w.sim (Sessions.path dir) 0 (Sim_disk.durable_size w.sim (Sessions.path dir)) <> None then begin
      count "checkpoints damaged";
      ignore (restart w ~power:false)
    end
  | _ -> Sim_disk.advance w.sim (Rng.int w.r 5000)

let run seed steps =
  let r = Rng.make seed in
  let sim = Sim_disk.create ~reverts:(Rng.chance r 0.3) (Rng.split r) in
  let kinds = [| Writer; Writer; Reader; Stranger; Admin |] in
  let clients =
    Array.mapi
      (fun i k -> { kind = k; cname = i; conn = None; session = 0; welcomed = false; serial = 0; unanswered = Hashtbl.create 8;
                    confirmed = 0; next_id = 1; watches = [] })
      (Array.sub kinds 0 (2 + Rng.int r 4))
  in
  let readers = Array.init (if Rng.chance r 0.1 then 0 else 1 + Rng.int r 3) (fun _ -> { lw = []; fol = None; sf = None; chan = Queue.create (); cut = false; reading = None }) in
  let w =
    { seed; sim; disk = Sim_disk.disk sim; r; srv = None; groups = Hashtbl.create 64; models = Hashtbl.create 64; acked = 0;
      committed = 0; stopped = false; clients; receipts = Hashtbl.create 64; page = ref 0; returned = 0; readers }
  in
  (* large groups (a run of their own, passed before their frame is durable) in some seeds *)
  Resolve.large_min := if Rng.chance r 0.3 then 2 + Rng.int r 3 else 20_000;
  Journal.segment_limit := 600 + Rng.int r 4000;
  Engine.compact_min := 5 + Rng.int r 60;
  w.disk.mkdir "/data";
  w.disk.sync_dir "/";
  (try
     ignore (start_server w);
     for _ = 1 to steps do
       try
         step w;
         (* after a failed fsync the server stops, and systemd starts it again *)
         if w.stopped then (count "stops after a failed fsync"; ignore (restart w ~power:(Rng.bool w.r)))
       with Sim_disk.Crash -> count "crash points"; ignore (restart w ~power:(Rng.chance w.r 0.3))
     done;
     (* the end: everything delivered, every write answered *)
     for _ = 1 to 200 do
       try
         Array.iter (fun cl -> client_step w cl; Option.iter (deliver_to_server w) cl.conn) w.clients;
         prepare w;
         commit w;
         hub_step w;
         hub_step w;
         push_step w;
         Array.iter (fun cl -> Option.iter (deliver_to_client w cl) cl.conn) w.clients;
         Array.iter (fun r -> reader_send w r; reader_apply w r; reader_read w r) w.readers;
         if w.stopped then ignore (restart w ~power:false)
       with Sim_disk.Crash -> ignore (restart w ~power:false)
     done;
     ignore (restart w ~power:true)
   with Over -> ());
  incr C.checks

let () =
  let seeds = ref 100 and one = ref None and steps = ref 400 in
  Arg.parse
    [ "--seeds", Arg.Set_int seeds, "N  run seeds 1..N"; "--seed", Arg.Int (fun s -> one := Some s), "S  run one seed";
      "--steps", Arg.Set_int steps, "N  steps a seed" ]
    (fun _ -> ()) "server_sim.exe [--seeds N | --seed S] [--steps N]";
  Pages.set_capacity (32 lsl 20);
  Snapshot.sync_every := 8 * Pages.size;
  (match !one with Some s -> run s !steps | None -> for s = 1 to !seeds do run s !steps done);
  let l = List.sort compare (Hashtbl.fold (fun k v acc -> (k, v) :: acc) stats []) in
  Printf.printf "server simulation: %s\n" (String.concat ", " (List.map (fun (k, v) -> Printf.sprintf "%d %s" v k) l));
  C.finish "server sim"
