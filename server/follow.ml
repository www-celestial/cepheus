(* The follow stream of one database: what its local readers receive (docs/server.md, "Local reads").

   A local reader is a program on the server's machine that reads the database in its own memory: the server passes
   it the run files and sends it every frame the writer makes, which it applies as the server did (Follower). What a
   read there sees is decided by one number in shared memory, the visibility number, in a page of tmpfs that the
   server maps and every reader maps read-only (page_path, Fdpass.map_page):
     - each frame is sent as soon as the syncer takes it, before its write and fsync, tagged with the number it will
       be visible under (the current number + 1); the reader applies it during the fsync and keeps the state it
       gives under that number;
     - once the fsync returns and the frame is published, the server stores the new number, then answers the frame's
       writers (Engine.follow's [after] runs before they are answered);
     - a read loads the number and serves the state the reader holds under it, or waits until it holds it;
     - a server that starts adds 2 to the number before anything: a state a reader holds under the number a frame
       of the dead server would have taken (a frame that the death may have lost) is never served.
   So a group becomes visible to every reader at one instant, the store of the number: a read that starts after a
   write was answered sees it, a read that starts after another read returned sees what it saw, and no group is
   ever shown before it is durable (G15, with G5 and G13; spec/LocalReads.tla checks the rule, and the rules it
   replaced, which break). Remote reads see the same state: the view of the number (or the published view when it
   has the same group: newer runs). No reader is waited for: a slow or stopped reader holds back its own reads only.

   Events go to each reader's queue, sent by the reader's connection (Net, or the simulation); a reader more than
   [max_bytes] behind is cut off and connects again. *)

open Cepheus

(* a run as the stream names it: its groups, and where its file is (a large group's run before it takes its name) *)
type run = { lo : int; hi : int; path : string; tmp : string option }

type event =
  | Frame of { vseq : int; first : int; count : int; body : Buffer.t }
      (** groups first .. first + count - 1, as the journal codes them in [body] (never changed after); the state after
          them is visible under [vseq] (0: not on its own, a part of a catch-up) *)
  | Runs of { vseq : int; runs : run list }
      (** the database's runs, newest first: the reader drops its states under numbers below [vseq] and rests the others
          on these runs *)

type follower = {
  q : event Queue.t;
  mutable bytes : int;  (* queued *)
  mutable dead : bool;  (* cut off: its connection closes *)
}

(* the shared page's first word *)
type word = { get : unit -> int; set : int -> unit }

type t = {
  e : Engine.t;
  sdir : string;  (* the database's snapshots directory *)
  fm : Mutex.t;
  fc : Condition.t;  (* a queue grew, or a follower died *)
  word : word;
  mutable vseq : int;  (* the number stored *)
  mutable visible : Store.view;  (* the state visible under it *)
  visible_a : Store.view Atomic.t;
  mutable inflight : (int * event list) option;  (* the frame being forced: its number and events *)
  mutable followers : follower list;
  mutable named : Store.run array;  (* the runs the stream last named *)
  max_bytes : int;
  mutable frames : int;  (* frames sent, for status and the tests *)
  mutable hook_s : float;  (* the time spent in [before] and [after], the writer's whole cost of its readers *)
}

let max_behind = 64 lsl 20

(* The shared page of a database: 4 KiB of tmpfs, /dev/shm/cepheus-ID.visible (ID: the database's id in hex), mode
   0600 (readers are passed a descriptor; they never open it by name). In memory, not on the disk: the number needs
   no fsync (after a reboot no reader is left), it outlives a server's death (which the 2 added at a start needs), and
   a page of tmpfs is never written back to a disk, so a store into it never waits for one. Made once and never replaced
   (a reader maps the file it was passed: a new file would leave it reading a number nobody moves). The server maps
   it read-write and shared, and holds a lock on it while it runs: a second server with the same database (a copy of
   its data directory) is refused rather than sharing the number. The lock is POSIX's (lockf), which a process loses
   when it closes any descriptor of the file: [open_page] also opens the read-only descriptor that every reader is
   passed, once, and it is never closed. *)
let page_dir = ref "/dev/shm"

let hex s = String.concat "" (List.map (fun c -> Printf.sprintf "%02x" (Char.code c)) (List.of_seq (String.to_seq s)))
let page_path id = Filename.concat !page_dir ("cepheus-" ^ hex id ^ ".visible")

(* the page of the database in [dir] (its id from DIR/cepheus): what a test removes at its end *)
let page_of_dir dir = page_path (Engine.read_meta Disk.real dir)

let open_page path =
  let fd = Unix.openfile path [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_CLOEXEC ] 0o600 in
  match Unix.lockf fd Unix.F_TLOCK 0 with
  | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EACCES), _, _) ->
    Unix.close fd;
    failwith (path ^ " is held by another server: a copy of this database's data directory runs on this machine")
  | () ->
    if (Unix.fstat fd).st_size < Fdpass.page_size then Unix.ftruncate fd Fdpass.page_size;
    let a = Bigarray.array1_of_genarray (Unix.map_file fd Bigarray.int64 Bigarray.c_layout true [| Fdpass.page_size / 8 |]) in
    (* both descriptors stay open for the server's life: closing either would release the lock *)
    let ro = Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
    { get = (fun () -> Int64.to_int (Bigarray.Array1.unsafe_get a 0)); set = (fun v -> Bigarray.Array1.unsafe_set a 0 (Int64.of_int v)) }, ro

let create ?(max_bytes = max_behind) (e : Engine.t) word =
  let v = Atomic.get e.published in
  (* a start: 2 more, before any reader may connect *)
  let vseq = word.get () + 2 in
  word.set vseq;
  { e; sdir = Filename.concat e.dir "snapshots"; fm = Mutex.create (); fc = Condition.create (); word; vseq; visible = v;
    visible_a = Atomic.make v; inflight = None; followers = []; named = v.runs; max_bytes; frames = 0; hook_s = 0. }

(* the state remote reads see: the view of the number, or the published one when it holds the same group *)
let view t =
  let p = Atomic.get t.e.published in
  let v = Atomic.get t.visible_a in
  if p.group = v.group then p else v

let size = function Frame f -> 32 + Buffer.length f.body | Runs r -> 32 + (48 * List.length r.runs)

(* under fm *)
let push t ev =
  t.followers <-
    List.filter
      (fun f ->
        if f.dead then false
        else begin
          Queue.push ev f.q;
          f.bytes <- f.bytes + size ev;
          if f.bytes > t.max_bytes then (f.dead <- true; false) else true
        end)
      t.followers;
  Condition.broadcast t.fc

let names sdir (rs : Store.run array) = Array.to_list (Array.map (fun (r : Store.run) -> { lo = r.lo; hi = r.hi; path = Filename.concat sdir (Snapshot.name r.lo r.hi); tmp = None }) rs)

(* Engine.follow's [before]: the frame of [b], before its write *)
let before t (b : Engine.batch) =
  if b.count > 0 then
    Mutex.protect t.fm (fun () ->
        let t0 = Unix.gettimeofday () in
        let v = t.vseq + 1 in
        let evs =
          match b.runs with
          | [] -> [ Frame { vseq = v; first = b.first; count = b.count; body = b.body } ]
          | w :: _ ->
            (* a large group: its run, merged already and not yet named, is the state; its file is read where it is *)
            let rs = w.view.runs in
            let runs =
              List.mapi (fun i (r : run) -> if i = 0 then { r with tmp = Some w.tmp; path = w.path } else r) (names t.sdir rs)
            in
            t.named <- rs;
            [ Runs { vseq = t.vseq; runs }; Frame { vseq = v; first = b.first; count = 0; body = Buffer.create 0 } ]
        in
        t.inflight <- Some (v, evs);
        t.frames <- t.frames + 1;
        List.iter (push t) evs;
        t.hook_s <- t.hook_s +. (Unix.gettimeofday () -. t0))

(* the runs changed with no frame (a merge installed in the background): named, the state unchanged; under fm *)
let name_runs t (p : Store.view) =
  if p.runs != t.named && p.group = t.visible.group then begin
    t.named <- p.runs;
    t.visible <- p;
    Atomic.set t.visible_a p;
    push t (Runs { vseq = t.vseq; runs = names t.sdir p.runs })
  end

(* Engine.follow's [after]: the frame is durable and published (or failed: the database stopped, nothing moves) *)
let after t =
  let t0 = Unix.gettimeofday () in
  let p = Atomic.get t.e.published in
  Mutex.protect t.fm (fun () ->
      Fun.protect ~finally:(fun () -> t.hook_s <- t.hook_s +. (Unix.gettimeofday () -. t0)) @@ fun () ->
      match t.inflight with
      | Some (v, _) when p.group > t.visible.group ->
        t.word.set v;
        t.vseq <- v;
        t.visible <- p;
        Atomic.set t.visible_a p;
        t.inflight <- None;
        name_runs t p
      | _ -> t.inflight <- None)

(* the server's ticker: runs a merge installed while nothing was written; never while a frame is in flight (a large
   group's runs are named by its frame already) *)
let tick t =
  let p = Atomic.get t.e.published in
  Mutex.protect t.fm (fun () ->
      (match t.inflight with None -> name_runs t p | Some _ -> ());
      (* every sender wakes: a stream whose token lost its right ends (G16) *)
      Condition.broadcast t.fc)

let hooks t = { Engine.before = before t; after = (fun () -> after t) }

(* A new reader: its queue starts with the frame being forced, if any; it is given the number, the state visible
   under it (whose runs its connection passes, then the groups after the newest run up to that state, read from the
   journal: Follow.catch_up), and its queue. *)
let register t =
  Mutex.protect t.fm (fun () ->
      let f = { q = Queue.create (); bytes = 0; dead = false } in
      (match t.inflight with Some (_, evs) -> List.iter (fun ev -> Queue.push ev f.q; f.bytes <- f.bytes + size ev) evs | None -> ());
      t.followers <- f :: t.followers;
      f, t.vseq, t.visible)

let unregister t f = Mutex.protect t.fm (fun () -> f.dead <- true; t.followers <- List.filter (fun g -> g != f) t.followers; Condition.broadcast t.fc)

(* the events queued for [f], waiting for one; once it is cut off, or when [stop ()] says so (checked at each wake:
   an event, a follower's end, the ticker every second), what is queued, maybe nothing *)
let take ?(stop = fun () -> false) t f =
  Mutex.protect t.fm (fun () ->
      while Queue.is_empty f.q && (not f.dead) && not (stop ()) do Condition.wait t.fc t.fm done;
      if f.dead then []
      else begin
        let l = List.of_seq (Queue.to_seq f.q) in
        Queue.clear f.q;
        f.bytes <- 0;
        l
      end)

(* wake every sender (stop, a follower's connection closed) *)
let wake t = Mutex.protect t.fm (fun () -> Condition.broadcast t.fc)

(* The groups after the newest run of [v] up to [v.group], from the journal, coded as frames of about [chunk] bytes
   with the number 0 (a catch-up: not visible on their own). The journal is read while the writer appends to it:
   its frames up to [v.group] are durable and whole; a frame being written after them may read as torn or as
   damaged, and is not needed. *)
let catch_up ?(chunk = 1 lsl 20) disk (e : Engine.t) (v : Store.view) emit =
  let top = if Array.length v.runs = 0 then 0 else v.runs.(0).hi in
  let b = ref (Buffer.create 4096) and first = ref 0 and count = ref 0 and last = ref top in
  let flush () =
    if !count > 0 then emit (Frame { vseq = 0; first = !first; count = !count; body = !b });
    b := Buffer.create 4096;
    count := 0
  in
  if v.group > top then begin
    (try
       Journal.read_after disk (Filename.concat e.dir "journal") e.id top (fun g ->
           if g.n <= v.group then begin
             if !count = 0 then first := g.n;
             Group.encode !b g;
             incr count;
             last := g.n;
             if Buffer.length !b >= chunk then flush ()
           end)
     with Journal.Damaged _ when !last >= v.group -> ());
    if !last < v.group then raise (Journal.Damaged (Printf.sprintf "the journal ends at group %d, before %d" !last v.group))
  end;
  flush ()

(* the events queued for [f], without waiting ([] if none, or once it is cut off): the simulation's sender *)
let drain t f =
  Mutex.protect t.fm (fun () ->
      if f.dead then []
      else begin
        let l = List.of_seq (Queue.to_seq f.q) in
        Queue.clear f.q;
        f.bytes <- 0;
        l
      end)

(* for `cepheus status`: local readers, frames sent, the hooks' mean time a frame (ns) *)
let status t =
  Mutex.protect t.fm (fun () ->
      [ "followers", string_of_int (List.length t.followers); "frames", string_of_int t.frames;
        "follow_ns_a_frame", Printf.sprintf "%.0f" (if t.frames = 0 then 0. else t.hook_s /. float t.frames *. 1e9);
        "visible", string_of_int t.vseq ])
