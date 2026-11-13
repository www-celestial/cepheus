(* A cache bounded by the weight of what it holds, by CLOCK (Corbató 1968; second chance): a hit sets the entry's
   bit, and the hand, here a queue of the keys, evicts the first entry whose bit is clear, clearing the bits it passes.
   A hit costs a lookup and a store, under a mutex held for nothing else. *)

type 'a entry = { v : 'a; w : int; mutable hit : bool }

type 'a t = { m : Mutex.t; tbl : (string, 'a entry) Hashtbl.t; hand : string Queue.t; cap : int; mutable used : int }

let create cap = { m = Mutex.create (); tbl = Hashtbl.create 64; hand = Queue.create (); cap; used = 0 }

let find t k =
  Mutex.protect t.m (fun () ->
      match Hashtbl.find_opt t.tbl k with
      | Some e -> e.hit <- true; Some e.v
      | None -> None)

let add t k v w =
  if w <= t.cap then
    Mutex.protect t.m (fun () ->
        if not (Hashtbl.mem t.tbl k) then begin
          while t.used + w > t.cap && not (Queue.is_empty t.hand) do
            let o = Queue.pop t.hand in
            match Hashtbl.find_opt t.tbl o with
            | Some e when e.hit -> e.hit <- false; Queue.push o t.hand
            | Some e -> Hashtbl.remove t.tbl o; t.used <- t.used - e.w
            | None -> ()
          done;
          Hashtbl.replace t.tbl k { v; w; hit = false };
          Queue.push k t.hand;
          t.used <- t.used + w
        end)

let clear t = Mutex.protect t.m (fun () -> Hashtbl.reset t.tbl; Queue.clear t.hand; t.used <- 0)
