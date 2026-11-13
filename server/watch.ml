(* The live questions of one database at the server (Watch over the wire): a hub (Live) and the thread that feeds it.

   The syncer hands each frame to the hub's thread as it takes it (Engine.follow's [before]): the thread evaluates the
   frame's changes for every watch while the frame is forced, and gives them once it is durable ([after] passes the
   durable group). The writer and the syncer never wait for a watch: they push to a queue and go on; a hub that falls
   more than [max_queue] frames behind asks every watch again (lagging). Nothing runs for a database that nobody has
   watched: the hub and its thread are made at the first Watch. The threads run in one domain of their own, made at the
   first Watch of the server, so that evaluating never takes the runtime lock of a writer or of the connections. *)

open Cepheus

type item = Frame of int * Group.t list * Store.view | Large of int * Store.view | Durable of int | Quit

type t = {
  m : Mutex.t;
  c : Condition.t;
  q : item Queue.t;
  mutable hub : Live.hub option;
  mutable last : Store.view;  (* the state after the newest frame the syncer took *)
  mutable last_tag : int;
  published : unit -> int;
}

let max_queue = 65_536

let create (e : Engine.t) =
  let v = Atomic.get e.published in
  { m = Mutex.create (); c = Condition.create (); q = Queue.create (); hub = None; last = v; last_tag = v.group;
    published = (fun () -> (Atomic.get e.published).group) }

(* the domain of the hubs' threads: it makes each thread it is asked for *)
let starts : (unit -> unit) Queue.t = Queue.create ()
let sm = Mutex.create ()
let sc = Condition.create ()
let domain : unit Domain.t option ref = ref None

let spawn f =
  Mutex.protect sm (fun () ->
      Queue.push f starts;
      Condition.signal sc;
      if !domain = None then
        domain :=
          Some
            (Domain.spawn (fun () ->
                 while true do
                   let f = Mutex.protect sm (fun () -> while Queue.is_empty starts do Condition.wait sc sm done; Queue.pop starts) in
                   ignore (Thread.create f ())
                 done)))

let run t h () =
  let go = ref true in
  while !go do
    let items =
      Mutex.protect t.m (fun () ->
          while Queue.is_empty t.q do Condition.wait t.c t.m done;
          let l = List.of_seq (Queue.to_seq t.q) in
          Queue.clear t.q;
          l)
    in
    (* what an item raises ends the watches, never the thread: a dead thread would freeze every watch of the database *)
    List.iter
      (fun item ->
        match
          match item with
          | Frame (tag, gs, v) -> Live.frame h ~tag gs v
          | Large (tag, v) -> Live.reset h v ~tag
          | Durable g -> Live.durable h g
          | Quit -> go := false
        with
        | () -> ()
        | exception e -> Live.broken h e (match item with Frame (tag, _, v) | Large (tag, v) -> Some (v, tag) | Durable _ | Quit -> None))
      items
  done

let push t item =
  if Queue.length t.q >= max_queue then begin
    (* far behind: what is queued is dropped, and every watch asked again at the newest state *)
    Queue.clear t.q;
    Queue.push (Large (t.last_tag, t.last)) t.q
  end
  else Queue.push item t.q;
  Condition.signal t.c

(* Engine.follow's two hooks, beside the follow stream's *)
let before t (b : Engine.batch) =
  if b.count > 0 then
    Mutex.protect t.m (fun () ->
        let tag = b.first + b.count - 1 in
        t.last <- b.after;
        t.last_tag <- tag;
        if t.hub <> None then push t (if b.runs <> [] then Large (tag, b.after) else Frame (tag, List.rev b.groups, b.after)))

let after t = Mutex.protect t.m (fun () -> if t.hub <> None then push t (Durable (t.published ())))

(* the hub, made at the first watch: at the newest frame taken, its messages held until that frame is durable *)
let hub t =
  Mutex.protect t.m (fun () ->
      match t.hub with
      | Some h -> h
      | None ->
        let h = Live.create t.last ~tag:t.last_tag ~durable:(t.published ()) in
        t.hub <- Some h;
        spawn (run t h);
        h)

(* the server stops, or the database: every watch ends *)
let stop t code message =
  Mutex.protect t.m (fun () ->
      match t.hub with
      | Some h -> Live.stop h code message; Queue.clear t.q; Queue.push Quit t.q; Condition.signal t.c
      | None -> ())

let status t =
  match Mutex.protect t.m (fun () -> t.hub) with
  | None -> [ "watches", "0" ]
  | Some h -> [ "watches", string_of_int (Live.watches h) ]
