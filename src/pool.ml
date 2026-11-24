(* The domains of the process: how many it may have, the writers' domains, and the domains that help large questions.

   OCaml 5.5 allows 128 domains a process (the runtime's parameter d, OCAMLRUNPARAM=d=N to raise it, read at start):
   past them Domain.spawn fails ("failed to allocate domain"). Domains are dear besides, measured on OCaml 5.5 (8
   cores): 0.2 ms to spawn and join one, 1.4 to 2 ms for seven, more when other domains are alive (4.2 ms for seven
   beside 8 idle domains, 6.5 ms beside 32); and each minor collection of OCaml 5 stops every domain, the idle ones
   included (their backup threads answer for them), so that a loop that allocates ran 59 % slower beside 8 idle
   domains and 188 % beside 32. So the process holds few domains, and never more than [cap] less a margin:

   - every domain spawned here is counted ([live]); one that may be done without ([try_spawn]: a merge, a change of
     the rules, the parts of a snapshot) is not spawned past [budget ()], and its work runs on a thread of the
     domain that asked (Writers.background), or on fewer domains;
   - the writers of the databases (each a writer and a syncer thread, Engine) share the writers' domains, the cores
     by default (Writers: apart, since its threads must not reach the Cesia client's engine, whose host has no
     systhreads): a server of 200 databases holds 8 of them on 8 cores, not 200 (a domain each, before, which the cap
     stopped at about 120 databases);
   - the domains that help large questions (Query.fold) are parked between questions and leave once idle for [keep]
     seconds (the keep-alive of a thread pool, as java.util.concurrent.ThreadPoolExecutor's keepAliveTime): under a
     stream of large questions none is spawned, and a quiet process holds none. At most [limit] are alive at once,
     whatever the number of questions: a question that finds none free runs on fewer domains, its own at least, and
     never fails for want of one. *)

(* ---- the cap ---- *)

(* the runtime's cap of domains: OCAMLRUNPARAM's (or CAMLRUNPARAM's) d, 128 by default (OCaml 5.5's
   Max_domains_def) *)
let cap =
  let param s =
    List.find_map
      (fun kv ->
        match String.index_opt kv '=' with
        | Some 1 when kv.[0] = 'd' -> (
          let v = String.sub kv 2 (String.length kv - 2) in
          let n = String.length v in
          let mult, digits = if n > 0 && (v.[n - 1] = 'k' || v.[n - 1] = 'K') then 1024, String.sub v 0 (n - 1) else 1, v in
          match int_of_string_opt digits with Some d when d > 0 -> Some (d * mult) | _ -> None)
        | _ -> None)
      (String.split_on_char ',' s)
  in
  let env k = Option.bind (Sys.getenv_opt k) param in
  match env "OCAMLRUNPARAM" with Some d -> d | None -> Option.value (env "CAMLRUNPARAM") ~default:128

(* the domains left to those this module does not spawn (a program's own: the Cesia runtime's, a test's) *)
let margin = 16

(* the domains alive that this module spawned, the main one counted *)
let live = Atomic.make 1

let budget () = cap - margin

(* [f] in a new domain, counted until it returns; raises as Domain.spawn does *)
let spawn f =
  Atomic.incr live;
  match Domain.spawn (fun () -> Fun.protect ~finally:(fun () -> Atomic.decr live) f) with
  | d -> d
  | exception e -> Atomic.decr live; raise e

(* [f] in a new domain, if the process is under its budget and the runtime gives one; None otherwise *)
let try_spawn f =
  if Atomic.fetch_and_add live 1 >= budget () then (Atomic.decr live; None)
  else
    match Domain.spawn (fun () -> Fun.protect ~finally:(fun () -> Atomic.decr live) f) with
    | d -> Some d
    | exception _ -> Atomic.decr live; None

(* ---- the domains that help large questions ----
   A helper waits for its next task in poll(2) on a pipe, which gives the keep-alive its timeout (OCaml's Condition
   has no timed wait; select's descriptors stop at 1,024, which a server of many databases passes): a task is queued,
   then a byte written for it, and the helper that reads the byte takes it. *)

(* is [fd] readable within [ms] milliseconds (src/clock_stubs.c) *)
external wait_readable : Unix.file_descr -> int -> bool = "cepheus_wait_readable"

(* the helpers alive at once at most; 0: every question runs on its own domain alone *)
let limit = ref (max 0 (Domain.recommended_domain_count () - 1))

(* seconds an idle helper stays *)
let keep = ref 1.0

type t = {
  m : Mutex.t;
  tasks : (unit -> unit) Queue.t;  (* given to idle helpers, a byte of the pipe each *)
  mutable idle : int;  (* helpers waiting for a task *)
  mutable alive : int;
  mutable spawned : int;  (* helpers spawned so far: for the tests and the benchmarks *)
  mutable pipe : (Unix.file_descr * Unix.file_descr) option;  (* made at the first helper *)
}

let p = { m = Mutex.create (); tasks = Queue.create (); idle = 0; alive = 0; spawned = 0; pipe = None }

let alive () = Mutex.protect p.m (fun () -> p.alive)
let spawned () = Mutex.protect p.m (fun () -> p.spawned)

(* the pipe, under [p.m] *)
let pipe () =
  match p.pipe with
  | Some x -> x
  | None ->
    let r, w = Unix.pipe ~cloexec:true () in
    Unix.set_nonblock r;
    p.pipe <- Some (r, w);
    (r, w)

(* a helper: its first task, then those it is woken for, until idle for [keep] seconds *)
let helper r first () =
  first ();
  Mutex.protect p.m (fun () -> p.idle <- p.idle + 1);
  let byte = Bytes.create 1 in
  let go = ref true in
  while !go do
    match wait_readable r (int_of_float (!keep *. 1000.)) with
    | false ->
      (* it leaves only while the idle helpers outnumber the queued tasks: every task keeps a helper to take it *)
      Mutex.protect p.m (fun () ->
          if Queue.length p.tasks < p.idle then begin
            p.idle <- p.idle - 1;
            p.alive <- p.alive - 1;
            go := false
          end)
    | true -> (
      match Unix.read r byte 0 1 with
      | 1 ->
        let f = Mutex.protect p.m (fun () -> p.idle <- p.idle - 1; Queue.pop p.tasks) in
        f ();
        Mutex.protect p.m (fun () -> p.idle <- p.idle + 1)
      | _ -> ()
      | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _) -> () (* another took it *))
  done

(* [help k f]: [f] run by up to [k] helpers at once, each in its own domain: as many as are idle, and those that can
   be spawned under [limit] and the process's budget (maybe none). [f] must catch what it raises. Returns [wait],
   which returns once every helper that took [f] has returned from it, and the number of them. A task is queued only
   for an idle helper (one waiting in poll), so it is taken at once: a question never waits for another's work. *)
let help k f =
  if k <= 0 || !limit <= 0 then ((fun () -> ()), 0)
  else begin
    let lm = Mutex.create () and lc = Condition.create () and left = ref 0 in
    let task () = (try f () with _ -> ()); Mutex.protect lm (fun () -> decr left; if !left = 0 then Condition.broadcast lc) in
    let (r, w), woken, fresh =
      Mutex.protect p.m (fun () ->
          let rw = pipe () in
          let woken = max 0 (min k (p.idle - Queue.length p.tasks)) in
          for _ = 1 to woken do Queue.push task p.tasks done;
          let fresh = max 0 (min (k - woken) (!limit - p.alive)) in
          p.alive <- p.alive + fresh;
          left := woken + fresh;
          rw, woken, fresh)
    in
    if woken > 0 then ignore (Unix.write w (Bytes.make woken '\001') 0 woken);
    (* a domain past the budget, or that the runtime does not give (its cap, memory), is one helper fewer *)
    let started = ref 0 in
    for _ = 1 to fresh do
      match try_spawn (helper r task) with
      | Some _ -> incr started
      | None -> Mutex.protect p.m (fun () -> p.alive <- p.alive - 1); Mutex.protect lm (fun () -> decr left)
    done;
    if !started > 0 then Mutex.protect p.m (fun () -> p.spawned <- p.spawned + !started);
    let wait () = Mutex.protect lm (fun () -> while !left > 0 do Condition.wait lc lm done) in
    (wait, woken + !started)
  end
