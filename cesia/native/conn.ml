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

open Cepheus_server

type waiter = {
  req : Wire.request;
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
  let wakes = List.filter_map (fun w -> answer w (error code message)) ws in
  Mutex.unlock t.m;
  List.iter (fun f -> f ()) wakes

let dispatch t id kind flags body =
  Mutex.lock t.m;
  match Hashtbl.find_opt t.by_id id with
  | None -> Mutex.unlock t.m
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
  let resend ws = List.iter (fun w -> w.parts <- []; Hashtbl.replace t.by_id (Client.send t.cl w.req) w) ws in
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
  let w = { req; sent = Unix.gettimeofday (); parts = []; reply = None; wake = None } in
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
    let w = { req; sent = Unix.gettimeofday (); parts = []; reply = None; wake = None } in
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
