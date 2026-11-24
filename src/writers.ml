(* The writers' domains, and the work that may run on a thread when the process has no domain left for it (Pool).
   Apart from Pool because it uses systhreads, which the Cesia client's engine (cesia/native) must not link: the
   client reaches Pool through Query, never this module. *)

(* [f] in the background: a domain of its own when one may be had ([try_spawn]), else a thread of the asking domain;
   returns its join, which raises what [f] raised *)
let background (f : unit -> unit) =
  match Pool.try_spawn f with
  | Some d -> fun () -> Domain.join d
  | None ->
    let r = ref (Ok ()) in
    let t = Thread.create (fun () -> r := match f () with () -> Ok () | exception e -> Error e) () in
    fun () -> Thread.join t; match !r with Ok () -> () | Error e -> raise e

(* ---- the writers' domains ----
   Each database's writer and syncer are threads of one of [writers] domains, the one that has the fewest databases
   when it opens: no client runs there (the connections have their own domains), so a writer never waits for the
   runtime lock of the clients; databases of one domain share its lock, which a writer gives up at each system call
   (its fsync, its pwrite) and every 50 ms of computing (OCaml's tick). A domain whose databases all closed ends. *)

let writers = ref (max 1 (Domain.recommended_domain_count ()))

type host = {
  hm : Mutex.t;
  hc : Condition.t;
  todo : ((unit -> unit) * (Thread.t, exn) result option ref) Queue.t;  (* threads to make, and where to say it *)
  mutable users : int;  (* its databases *)
  mutable running : bool;
  mutable dom : unit Domain.t option;
}

(* the writers' domains alive; a domain leaves the list when its last database closes, and ends *)
let hosts_m = Mutex.create ()
let hosts : host list ref = ref []

let host_loop h () =
  let threads = ref [] in
  Mutex.lock h.hm;
  while h.running do
    match Queue.take_opt h.todo with
    | Some (f, slot) ->
      Mutex.unlock h.hm;
      let r = match Thread.create f () with t -> Ok t | exception e -> Error e in
      Mutex.lock h.hm;
      (match r with Ok t -> threads := t :: !threads | Error _ -> ());
      slot := Some r;
      Condition.broadcast h.hc
    | None -> Condition.wait h.hc h.hm
  done;
  Mutex.unlock h.hm;
  List.iter Thread.join !threads

(* [run fs]: each function of [fs] a thread of one writers' domain (a new one while there are fewer than [writers],
   else the one with the fewest databases); returns once they are made (raises what making one raised), with their
   join, to call once: it returns once each has returned, and the domain has ended if it was its last *)
let run (fs : (unit -> unit) list) =
  let lm = Mutex.create () and lc = Condition.create () and left = ref (List.length fs) in
  let ended () = Mutex.protect lm (fun () -> decr left; Condition.broadcast lc) in
  let h, slots =
    Mutex.protect hosts_m (fun () ->
        let h =
          match List.fold_left (fun b h -> match b with Some b when b.users <= h.users -> Some b | _ -> Some h) None !hosts with
          | Some h when List.length !hosts >= !writers -> h
          | _ ->
            let h = { hm = Mutex.create (); hc = Condition.create (); todo = Queue.create (); users = 0; running = true; dom = None } in
            h.dom <- Some (Pool.spawn (host_loop h));
            hosts := !hosts @ [ h ];
            h
        in
        Mutex.protect h.hm (fun () ->
            h.users <- h.users + 1;
            let slots = List.map (fun f -> let s = ref None in Queue.push ((fun () -> Fun.protect ~finally:ended f), s) h.todo; s) fs in
            Condition.broadcast h.hc;
            h, slots))
  in
  Mutex.protect h.hm (fun () -> while List.exists (fun s -> !s = None) slots do Condition.wait h.hc h.hm done);
  let failed = List.filter_map (fun s -> match !s with Some (Error e) -> Some e | _ -> None) slots in
  Mutex.protect lm (fun () -> left := !left - List.length failed);
  let join () =
    Mutex.protect lm (fun () -> while !left > 0 do Condition.wait lc lm done);
    let last =
      Mutex.protect hosts_m (fun () ->
          Mutex.protect h.hm (fun () ->
              h.users <- h.users - 1;
              if h.users > 0 then None
              else begin
                h.running <- false;
                Condition.broadcast h.hc;
                hosts := List.filter (fun x -> x != h) !hosts;
                h.dom
              end))
    in
    Option.iter Domain.join last
  in
  match failed with
  | [] -> join
  | e :: _ -> raise e

(* the writers' domains running now: for the tests *)
let writer_domains () = Mutex.protect hosts_m (fun () -> List.length !hosts)

