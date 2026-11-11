(* A connection of the Cesia client: one a program and database, shared by all its fibers. Requests are sent at once
   from Cesia's domain and answered out of order, matched by id (protocol v1); a fiber that waits for its reply is parked
   (Cesia_v1.suspend), and a domain of the connection, the reader, reads the socket and wakes the fiber whose reply came.
   So a thousand fibers wait on one socket, their writes go out pipelined, and the server groups them in one fsync.

   The transport is the OCaml client's (Client: the socket, TLS, Hello, the session and the follow stream of local
   reads). When the connection breaks, the reader connects again with the same session and sends again every request
   not answered, a write with its serial, so that it is applied once (G14); after the retry budget, each one gets
   unreachable. Sending is Cesia's domain's but during a reconnection, which holds [wm]: a request made meanwhile waits
   in [queued], so that no fiber ever waits for a reconnection in Cesia's domain itself.

   A read sent when nothing else is in flight is read by Cesia's domain itself, for a short window (three round trips
   as the connection measures them, at most 200 us, and only when they are under 100 us): the reply then needs no
   hop from the reader's domain to Cesia's (a wake-up through a pipe, about 10 us here). Past the window, or when
   other requests are in flight (many fibers: pipelined, the reader reads), the fiber is parked as any other. *)

open Cepheus
open Cepheus_server

(* ---- live questions: one watch a question and database, shared by the program's fibers ----
   The package keeps the answer of each watched question (a multiset of rows) and gives each fiber that watches it
   its messages: the answer first, then the changes. When its source ends (the connection broke, the server stopped,
   the local reader's stream ended, the watch fell behind), the next fiber that asks finds it a new one, from the
   group of its last message: the server answers Same (nothing changed since) or the answer, which the package turns
   into the change from its rows; the fibers see no gap and no repeat. A fiber whose queue fills (it reads slower than
   the changes come) loses its queue and gets the answer again when it asks: a slow fiber never holds the others,
   and its memory stays bounded. *)

type message = M_answer of int * Live.row list | M_change of int * Live.row list * Live.row list | M_end of string * string

type source = Nothing | Remote | Local of Live.hub * Live.sub

type consumer = {
  sh : shared;
  q : message Queue.t;
  mutable wake : (unit -> unit) option;
  mutable gone : bool;
  mutable behind : bool;  (* its queue was full: its next message is the answer *)
}

and shared = {
  key : string;
  sm : Mutex.t;  (* everything below *)
  rows : (Live.row, int) Hashtbl.t;  (* the answer as the last message left it: a row and its copies *)
  mutable group : int;
  mutable started : bool;
  mutable consumers : consumer list;
  mutable src : source;
  mutable lost : bool;  (* its source ended: a consumer finds it a new one ([find]) *)
  mutable finding : bool;
  mutable ended : (string * string) option;  (* for good: the reason *)
  mutable parts : Wire.push option;  (* a push in several frames, so far *)
  query : Query.t;
  select : Wire.select;
}

let queue_max = 256

let new_shared key query select =
  { key; sm = Mutex.create (); rows = Hashtbl.create 16; group = 0; started = false; consumers = []; src = Nothing; lost = true;
    finding = false; ended = None; parts = None; query; select }

let row_list sh = Hashtbl.fold (fun r n acc -> let rec go k acc = if k = 0 then acc else go (k - 1) (r :: acc) in go n acc) sh.rows []

(* under sh.sm: to every consumer; the wakes to call once sh.sm is released *)
let give sh m =
  List.filter_map
    (fun c ->
      if c.gone then None
      else begin
        if Queue.length c.q >= queue_max then (Queue.clear c.q; c.behind <- true) else Queue.push m c.q;
        let k = c.wake in
        c.wake <- None;
        k
      end)
    sh.consumers

let wake_all sh = List.filter_map (fun c -> let k = c.wake in c.wake <- None; k) sh.consumers

let bump tbl r d =
  let n = d + Option.value (Hashtbl.find_opt tbl r) ~default:0 in
  if n <= 0 then Hashtbl.remove tbl r else Hashtbl.replace tbl r n

(* codes after which the watch goes on from a new source *)
let resumable = function "lagging" | "stopping" | "unreachable" | "busy" -> true | _ -> false

(* a message of the watch's source *)
let deliver sh (m : Live.msg) =
  Mutex.lock sh.sm;
  let wakes =
    match m with
    | Live.Answer a when not sh.started ->
      sh.started <- true;
      sh.group <- a.group;
      List.iter (fun r -> bump sh.rows r 1) a.rows;
      give sh (M_answer (a.group, a.rows))
    | Live.Answer a ->
      (* a new source's answer: the change from the rows held *)
      let now = Hashtbl.create 16 in
      List.iter (fun r -> bump now r 1) a.rows;
      let added = ref [] and removed = ref [] in
      let copies n r acc = let rec go k acc = if k <= 0 then acc else go (k - 1) (r :: acc) in go n acc in
      Hashtbl.iter (fun r n -> let o = Option.value (Hashtbl.find_opt sh.rows r) ~default:0 in if n > o then added := copies (n - o) r !added) now;
      Hashtbl.iter (fun r o -> let n = Option.value (Hashtbl.find_opt now r) ~default:0 in if o > n then removed := copies (o - n) r !removed) sh.rows;
      Hashtbl.reset sh.rows;
      Hashtbl.iter (fun r n -> Hashtbl.replace sh.rows r n) now;
      let g = max sh.group a.group in
      sh.group <- g;
      if !added = [] && !removed = [] then [] else give sh (M_change (g, !added, !removed))
    | Live.Change c ->
      List.iter (fun r -> bump sh.rows r (-1)) c.removed;
      List.iter (fun r -> bump sh.rows r 1) c.added;
      sh.group <- c.group;
      give sh (M_change (c.group, c.added, c.removed))
    | Live.Same g -> sh.group <- max sh.group g.group; []
    | Live.Ended e ->
      sh.src <- Nothing;
      if resumable e.code && sh.ended = None then sh.lost <- true else if sh.ended = None then sh.ended <- Some (e.code, e.message);
      wake_all sh
  in
  Mutex.unlock sh.sm;
  List.iter (fun k -> k ()) wakes

(* a fiber joins the watch: it gets the answer held, if any *)
let join sh =
  let c = { sh; q = Queue.create (); wake = None; gone = false; behind = false } in
  Mutex.protect sh.sm (fun () ->
      if sh.started then Queue.push (M_answer (sh.group, row_list sh)) c.q;
      sh.consumers <- c :: sh.consumers);
  c

(* The next message of a fiber's watch, the fiber parked while there is none; [find sh] gives the watch a new source
   (on Cesia's domain, sh.sm released): false when it cannot now (the connection is being made again: the
   reconnection wakes the fibers) *)
let rec next park find c =
  let sh = c.sh in
  Mutex.lock sh.sm;
  if c.gone then (Mutex.unlock sh.sm; M_end ("closed", "the watch was closed"))
  else if c.behind then begin
    c.behind <- false;
    let m = M_answer (sh.group, row_list sh) in
    Mutex.unlock sh.sm;
    m
  end
  else
    match Queue.take_opt c.q with
    | Some m -> Mutex.unlock sh.sm; m
    | None -> (
      match sh.ended with
      | Some (code, message) -> Mutex.unlock sh.sm; M_end (code, message)
      | None ->
        if sh.lost && not sh.finding then begin
          sh.finding <- true;
          sh.lost <- false;
          Mutex.unlock sh.sm;
          let ok = try find sh with e -> Mutex.protect sh.sm (fun () -> sh.finding <- false); raise e in
          Mutex.protect sh.sm (fun () -> sh.finding <- false; if not ok then sh.lost <- true);
          if ok then next park find c
          else begin
            (* parked until the reconnection wakes it, or a message comes *)
            park (fun resume ->
                Mutex.lock sh.sm;
                if c.gone || c.behind || not (Queue.is_empty c.q) || sh.ended <> None then (Mutex.unlock sh.sm; resume ())
                else (c.wake <- Some resume; Mutex.unlock sh.sm));
            next park find c
          end
        end
        else begin
          Mutex.unlock sh.sm;
          park (fun resume ->
              Mutex.lock sh.sm;
              if c.gone || c.behind || not (Queue.is_empty c.q) || sh.ended <> None || (sh.lost && not sh.finding) then (Mutex.unlock sh.sm; resume ())
              else (c.wake <- Some resume; Mutex.unlock sh.sm));
          next park find c
        end)

(* a message given back, first in the fiber's queue *)
let push_front c m =
  Mutex.protect c.sh.sm (fun () ->
      let rest = Queue.copy c.q in
      Queue.clear c.q;
      Queue.push m c.q;
      Queue.transfer rest c.q)

(* the fiber leaves: true when it was the last (the caller stops the source) *)
let leave c =
  let sh = c.sh in
  Mutex.protect sh.sm (fun () ->
      c.gone <- true;
      sh.consumers <- List.filter (fun x -> x != c) sh.consumers;
      let k = c.wake in
      c.wake <- None;
      Option.iter (fun f -> f ()) k;
      if sh.consumers = [] then (sh.ended <- Some ("closed", "the watch was closed"); true) else false)

(* the watch ends for good: its database was closed *)
let finish sh code message =
  let wakes = Mutex.protect sh.sm (fun () -> if sh.ended = None then sh.ended <- Some (code, message); wake_all sh) in
  List.iter (fun k -> k ()) wakes

type waiter = {
  req : Wire.request;
  watch : shared option;  (* a Watch: its pushes go to the shared watch, until Unwatch *)
  sent : float;  (* when: the round trip's time *)
  mutable parts : (int * int * Bytes.t) list;  (* the frames of its reply so far, newest first *)
  mutable reply : Wire.reply option;
  mutable wake : (unit -> unit) option;  (* the parked fiber's resume *)
}

type t = {
  cl : Client.t;
  m : Mutex.t;  (* the tables below, [up], [closed] *)
  work : Condition.t;  (* the reader waits here while nothing is asked *)
  by_id : (int, waiter) Hashtbl.t;  (* sent, not answered *)
  mutable queued : waiter list;  (* asked during a reconnection, newest first *)
  wm : Mutex.t;  (* the sending side of the transport (its buffers, its id counter, the socket's writes) *)
  mutable up : bool;
  mutable closed : bool;
  mutable reader : unit Domain.t option;
  mutable serial : int;  (* the session's last write *)
  unanswered : (int, unit) Hashtbl.t;  (* the serials of writes in flight: the floor *)
  mutable reading : bool;  (* the reader is in a read of the socket *)
  mutable caller : bool;  (* Cesia's domain reads the socket itself (the fast path): the reader waits *)
  mutable rtt : float;  (* the reads' round trip, a moving average, in seconds *)
}

let error code message = Wire.Err { code; message }

(* the reply of a request in several frames: the rows of a Find, joined *)
let assemble parts =
  let decode (k, f, b) = Client.decode k f b in
  match parts with
  | [ p ] -> decode p
  | ps -> (
    let replies = List.rev_map decode ps in
    match List.find_opt (function Wire.Err _ -> true | _ -> false) replies with
    | Some e -> e
    | None ->
      let group = ref 0 and cols = ref 0 in
      let rows = List.concat_map (function Wire.Rows r -> group := r.group; cols := r.cols; r.rows | _ -> []) replies in
      Wire.Rows { group = !group; cols = !cols; rows })

(* called with [m] held; gives the resume to call once [m] is released *)
let answer w r =
  w.reply <- Some r;
  let k = w.wake in
  w.wake <- None;
  k

(* every request waiting gets this error; [up]: the connection is up again for the next ones (in the same section, so
   that no request is queued in between and forgotten) *)
let fail_all ?(up = false) t code message =
  Mutex.lock t.m;
  let ws = Hashtbl.fold (fun _ w l -> w :: l) t.by_id t.queued in
  Hashtbl.reset t.by_id;
  t.queued <- [];
  Hashtbl.reset t.unanswered;
  if up then t.up <- true;
  let wakes = List.filter_map (fun w -> if w.watch = None then answer w (error code message) else None) ws in
  Mutex.unlock t.m;
  List.iter (fun f -> f ()) wakes;
  (* the watches go on from a new source, or end *)
  List.iter (fun w -> Option.iter (fun sh -> deliver sh (Live.Ended { code; message })) w.watch) ws

let live_of = function
  | Wire.Answer a -> Live.Answer { group = a.group; rows = a.rows }
  | Wire.Change c -> Live.Change { group = c.group; added = c.added; removed = c.removed }
  | Wire.Same g -> Live.Same { group = g }

let dispatch t id kind flags body =
  Mutex.lock t.m;
  match Hashtbl.find_opt t.by_id id with
  | None -> Mutex.unlock t.m
  | Some { watch = Some sh; _ } ->
    (* a push of a watch: its frames joined, then given to the shared watch *)
    if flags land Wire.f_error <> 0 then begin
      Hashtbl.remove t.by_id id;
      Mutex.unlock t.m;
      match Client.decode kind flags body with
      | Wire.Err e -> deliver sh (Live.Ended { code = e.code; message = e.message })
      | _ | (exception Client.Broken _) -> deliver sh (Live.Ended { code = "lagging"; message = "a watch's end that does not decode" })
    end
    else (
      match Wire.get_push (Codec.reader body 0 (Bytes.length body)) with
      | exception Codec.Short -> Mutex.unlock t.m
      | part ->
        let m = match sh.parts with Some p -> Wire.join_push p part | None -> part in
        if flags land Wire.f_more <> 0 then (sh.parts <- Some m; Mutex.unlock t.m)
        else begin
          sh.parts <- None;
          Mutex.unlock t.m;
          deliver sh (live_of m)
        end)
  | Some w ->
    w.parts <- (kind, flags, body) :: w.parts;
    if flags land Wire.f_more <> 0 then Mutex.unlock t.m
    else begin
      Hashtbl.remove t.by_id id;
      (match w.req with
       | Wire.Write x -> Hashtbl.remove t.unanswered x.serial
       | Wire.Get _ -> t.rtt <- (0.875 *. t.rtt) +. (0.125 *. (Unix.gettimeofday () -. w.sent))
       | _ -> ());
      let r = try assemble w.parts with Client.Broken m -> error "protocol" m in
      let k = answer w r in
      Mutex.unlock t.m;
      Option.iter (fun f -> f ()) k
    end

(* in the reader: connect again, and send again what was not answered, in the order it was first sent. [up] is false
   meanwhile, so that a request made then is queued; it turns true, and the requests queued until then are sent,
   while [wm] is still held: a request made after waits for [wm] a moment, and none is forgotten. *)
let reconnect t =
  Mutex.lock t.m;
  t.up <- false;
  Mutex.unlock t.m;
  Mutex.lock t.wm;
  let deadline = Unix.gettimeofday () +. !Client.retry_budget in
  (* a watch again from the group of its last message *)
  let req_of w =
    match w.watch, w.req with
    | Some sh, Wire.Watch x -> sh.parts <- None; Wire.Watch { x with from = (if sh.started then sh.group else 0) }
    | _ -> w.req
  in
  let resend ws = List.iter (fun w -> w.parts <- []; Hashtbl.replace t.by_id (Client.send t.cl (req_of w)) w) ws in
  let rec go pause =
    if t.closed then ()
    else
      match Client.reconnect t.cl with
      | Ok () ->
        Mutex.lock t.m;
        let old = List.sort compare (Hashtbl.fold (fun id w l -> (id, w) :: l) t.by_id []) in
        Hashtbl.reset t.by_id;
        resend (List.map snd old @ List.rev t.queued);
        t.queued <- [];
        Mutex.unlock t.m;
        (try Client.flush t.cl with Client.Broken _ -> ());
        Mutex.lock t.m;
        let late = List.rev t.queued in
        t.queued <- [];
        resend late;
        t.up <- true;
        Mutex.unlock t.m;
        if late <> [] then (try Client.flush t.cl with Client.Broken _ -> ())
      | Error (true, m) -> fail_all ~up:true t "denied" m
      | Error (false, _) when Unix.gettimeofday () < deadline -> Unix.sleepf pause; go (min 1.0 (pause *. 2.))
      | Error (false, m) ->
        fail_all ~up:true t "unreachable"
          (Printf.sprintf "the server did not answer for %g s (%s): a write in flight was applied once or not at all"
             !Client.retry_budget m)
  in
  go 0.01;
  Mutex.unlock t.wm

let rec read_loop t =
  Mutex.lock t.m;
  while (not t.closed) && (Hashtbl.length t.by_id = 0 || t.caller) do Condition.wait t.work t.m done;
  let closed = t.closed in
  t.reading <- not closed;
  Mutex.unlock t.m;
  if not closed then begin
    let frame = try Some (Client.next_frame t.cl) with Client.Broken _ -> None in
    Mutex.lock t.m;
    t.reading <- false;
    Mutex.unlock t.m;
    (match frame with
     | Some (0, _, _, _) -> reconnect t (* the server says why it closes the connection (idle): what is asked goes again *)
     | Some (id, kind, flags, body) -> dispatch t id kind flags body
     | None -> if not t.closed then reconnect t);
    read_loop t
  end

(* the connection made by Client (Hello, the session, and the Opens and declarations of Connect, made in turn before
   any fiber shares it): from now on its reads are the reader's *)
let start cl =
  let t =
    { cl; m = Mutex.create (); work = Condition.create (); by_id = Hashtbl.create 16; queued = []; wm = Mutex.create ();
      up = true; closed = false; reader = None; serial = cl.Client.serial; unanswered = Hashtbl.create 16; reading = false;
      caller = false; rtt = 50e-6 }
  in
  t.reader <- Some (Domain.spawn (fun () -> read_loop t));
  t

(* a request sent now (or after the reconnection under way); its reply is waited for by [wait] *)
let submit t req =
  let w = { req; watch = None; sent = Unix.gettimeofday (); parts = []; reply = None; wake = None } in
  Mutex.lock t.m;
  if t.closed then (w.reply <- Some (error "closed" "the database is closed"); Mutex.unlock t.m)
  else if not t.up then (t.queued <- w :: t.queued; Mutex.unlock t.m)
  else begin
    Mutex.unlock t.m;
    (* free, but at the very end of a reconnection *)
    Mutex.lock t.wm;
    Mutex.lock t.m;
    if not t.up then begin
      (* a reconnection began meanwhile: it waits for [wm], then sends what is queued *)
      t.queued <- w :: t.queued;
      Mutex.unlock t.m;
      Mutex.unlock t.wm
    end
    else begin
      (* registered before its bytes leave: the reply may come at once *)
      Hashtbl.replace t.by_id (Client.send t.cl req) w;
      Condition.signal t.work;
      Mutex.unlock t.m;
      (try Client.flush t.cl with Client.Broken _ -> () (* the reader finds it broken too, and sends it again *));
      Mutex.unlock t.wm
    end
  end;
  w

(* the reply, the calling fiber parked meanwhile ([park] is Cesia_v1.suspend of its ctx) *)
let wait park t w =
  Mutex.lock t.m;
  let ready = w.reply <> None in
  Mutex.unlock t.m;
  if not ready then
    park (fun resume ->
        Mutex.lock t.m;
        if w.reply <> None then (Mutex.unlock t.m; resume ()) else (w.wake <- Some resume; Mutex.unlock t.m));
  Option.get w.reply

let call park t req = wait park t (submit t req)

(* Has the transport a whole frame in its buffer already? *)
let frame_buffered (c : Client.t) = c.have >= 4 && c.have >= 4 + Wire.u32 c.inb 0

(* A read, its reply read by Cesia's domain itself while nothing else is in flight (see the top), else as [call] *)
let read park t req =
  let window = Float.min 200e-6 (3. *. t.rtt) in
  Mutex.lock t.m;
  let fast = t.up && (not t.closed) && (not t.reading) && (not t.caller) && t.queued = [] && Hashtbl.length t.by_id = 0
             && t.rtt < 100e-6 && Mutex.try_lock t.wm in
  if not fast then (Mutex.unlock t.m; call park t req)
  else begin
    let w = { req; watch = None; sent = Unix.gettimeofday (); parts = []; reply = None; wake = None } in
    Hashtbl.replace t.by_id (Client.send t.cl req) w;
    t.caller <- true;
    Mutex.unlock t.m;
    let sent = (try Client.flush t.cl; true with Client.Broken _ -> false) in
    Mutex.unlock t.wm;
    let deadline = w.sent +. window in
    let rec go () =
      if w.reply = None then begin
        let left = deadline -. Unix.gettimeofday () in
        let ready =
          frame_buffered t.cl
          || (left > 0.
              && match t.cl.fd with
                 | Some fd -> (try (match Unix.select [ fd ] [] [] left with [], _, _ -> false | _ -> true) with Unix.Unix_error _ -> false)
                 | None -> false)
        in
        if ready then
          match Client.next_frame t.cl with
          | 0, _, _, _ -> () (* the server closes the connection: the reader sees it and connects again *)
          | id, kind, flags, body -> dispatch t id kind flags body; go ()
          | exception Client.Broken _ -> ()
      end
    in
    if sent then go ();
    Mutex.lock t.m;
    t.caller <- false;
    Condition.signal t.work;
    Mutex.unlock t.m;
    wait park t w
  end

(* a write of the session: its serial, and the floor (the lowest serial not answered) the server may forget below *)
let write park t ~db ~by ~why ops =
  t.serial <- t.serial + 1;
  let serial = t.serial in
  Mutex.lock t.m;
  Hashtbl.replace t.unanswered serial ();
  let floor = Hashtbl.fold (fun s () m -> min s m) t.unanswered serial in
  Mutex.unlock t.m;
  call park t (Wire.Write { db; serial; floor; by; why; ops })

(* the watch at the server: its pushes go to [sh]; false when the connection is closed *)
let watch t sh req =
  let w = { req; watch = Some sh; sent = Unix.gettimeofday (); parts = []; reply = None; wake = None } in
  Mutex.lock t.m;
  if t.closed then (Mutex.unlock t.m; false)
  else if not t.up then (t.queued <- w :: t.queued; Mutex.unlock t.m; true)
  else begin
    Mutex.unlock t.m;
    Mutex.lock t.wm;
    Mutex.lock t.m;
    if not t.up then (t.queued <- w :: t.queued; Mutex.unlock t.m; Mutex.unlock t.wm)
    else begin
      sh.parts <- None;
      Hashtbl.replace t.by_id (Client.send t.cl req) w;
      Condition.signal t.work;
      Mutex.unlock t.m;
      (try Client.flush t.cl with Client.Broken _ -> ());
      Mutex.unlock t.wm
    end;
    true
  end

(* the server stops the watch of [sh]: its pushes in flight are dropped *)
let unwatch t sh =
  Mutex.lock t.m;
  let ids = Hashtbl.fold (fun id w acc -> match w.watch with Some x when x == sh -> id :: acc | _ -> acc) t.by_id [] in
  List.iter (Hashtbl.remove t.by_id) ids;
  t.queued <- List.filter (fun w -> match w.watch with Some x -> x != sh | None -> true) t.queued;
  let up = t.up && not t.closed in
  Mutex.unlock t.m;
  if up then List.iter (fun id -> ignore (submit t (Wire.Unwatch id))) ids

let close t =
  Mutex.lock t.m;
  let was = t.closed in
  t.closed <- true;
  Condition.broadcast t.work;
  Mutex.unlock t.m;
  if not was then begin
    (match t.cl.Client.fd with Some fd -> (try Unix.shutdown fd Unix.SHUTDOWN_ALL with Unix.Unix_error _ -> ()) | None -> ());
    Option.iter Domain.join t.reader;
    fail_all t "closed" "the database is closed";
    Client.close t.cl
  end
