(* The server's commit buffer (wal.mli). The core is deterministic: [round] writes and forces one round, [clean]
   forces the journals of the file that is not active. A server runs them on two threads of a domain of their own;
   the simulation calls them itself, in an order drawn from a seed, and a commit there performs [Wait] instead of
   waiting on a condition. *)

let file_magic = 0x57485043 (* "CPHW" *)
let round_magic = 0x52485043 (* "CPHR" *)
let tail_magic = 0x54485043 (* "CPHT", as a journal frame's trailer *)
let format = 1
let header = 40
let fh = 28
let ft = 16
let limit = ref (64 * 1024 * 1024)
let names = [| "server.wal.1"; "server.wal.2" |]

let u32 b i = Int32.to_int (Bytes.get_int32_le b i) land 0xFFFFFFFF
let set32 b i x = Bytes.set_int32_le b i (Int32.of_int x)
let damaged fmt = Printf.ksprintf (fun s -> raise (Journal.Damaged s)) fmt

type file = {
  path : string;
  mutable fd : Disk.fd option;
  mutable gen : int;
  mutable size : int;
  mutable rounds : int;
  held : (string, Journal.t) Hashtbl.t;  (* the journals with frames here: forced before the file is emptied *)
}

(* a database's place in the buffer: one frame in flight at most, its syncer waiting for its round *)
type client = {
  id : string;
  j : Journal.t;
  c : Condition.t;
  mutable frame : Bytes.t;
  mutable result : (unit, string) result option;
}

type t = {
  disk : Disk.t;
  files : file array;
  mutable active : int;
  mutable dirty : bool;  (* the file that is not active holds frames whose journals may not be forced *)
  mutable stopped : string option;
  recovered : (string, Bytes.t list) Hashtbl.t;  (* frames by database id, oldest first, until taken *)
  mutable clients : client list;
  m : Mutex.t;
  work : Condition.t;  (* the round thread: frames came, or the buffer stops *)
  dirt : Condition.t;  (* the cleaner: a file to clean, or the buffer stops *)
  mutable pending : client list;  (* newest first *)
  mutable running : bool;
  mutable busy : bool;  (* a round is being written and forced *)
  mutable own : int;  (* journals forcing a frame of their own, given to the buffer when it was idle *)
  mutable dom : unit Domain.t option;
  manual : bool;
  nrounds : int Atomic.t;
  nframes : int Atomic.t;
  nown : int Atomic.t;
}

type _ Effect.t += Wait : unit Effect.t

let file_header gen =
  let b = Bytes.make header '\000' in
  set32 b 0 file_magic;
  set32 b 4 format;
  Bytes.set_int64_le b 8 (Int64.of_int gen);
  set32 b 36 (Crc32c.bytes b 0 36);
  b

(* ---- Recovery ---- *)

(* the round at p of [b] (a file of [size] bytes): Some (end, its entries) if it checks and is round [n] *)
let round_at b size p n =
  if size - p < fh + ft then None
  else
    let len = u32 b (p + 4) in
    if u32 b p <> round_magic || u32 b (p + 24) <> Crc32c.bytes b p 24 || len > size - p - fh - ft
       || Int64.to_int (Bytes.get_int64_le b (p + 8)) <> n || u32 b (p + 20) <> Crc32c.bytes b (p + fh) len
    then None
    else
      let t = p + fh + len in
      if u32 b t <> len || u32 b (t + 4) <> u32 b (p + 20) || u32 b (t + 8) <> u32 b (p + 24) || u32 b (t + 12) <> tail_magic
      then None
      else Some (t + ft, u32 b (p + 16), p + fh, t)

(* a round written whole after p: a round header that checks, or a trailer that matches the bytes between p and it *)
let written_after b size p =
  let found = ref false and q = ref (p + 1) in
  while (not !found) && !q + 4 <= size do
    let w = u32 b !q in
    if w = round_magic && !q + fh <= size && u32 b (!q + 24) = Crc32c.bytes b !q 24 then found := true
    else if w = tail_magic then begin
      let ts = !q - 12 in
      if ts >= p + fh && u32 b ts = ts - p - fh && Crc32c.bytes b (p + fh) (ts - p - fh) = u32 b (ts + 4) then found := true
    end;
    incr q
  done;
  !found

(* a file: its generation and the entries of its rounds, in order; None if it is missing. A file takes its name only
   once its header and first round are durable (written beside, forced, renamed): one without a header that checks is
   damage *)
let read_file disk path =
  if not (disk.Disk.exists path) then None
  else
    let b = Disk.read_all disk path in
    let size = Bytes.length b in
    if size < header || u32 b 0 <> file_magic || u32 b 36 <> Crc32c.bytes b 0 36 then damaged "%s: a broken header" path
    else if u32 b 4 <> format then damaged "%s: unknown format %d" path (u32 b 4)
    else begin
      let gen = Int64.to_int (Bytes.get_int64_le b 8) in
      let entries = ref [] in
      let rec go p n =
        if p = size then None
        else
          match round_at b size p n with
          | None -> Some p
          | Some (stop, count, q0, qend) ->
            let q = ref q0 in
            for _ = 1 to count do
              if !q + 20 > qend then damaged "%s: round %d at %d does not hold its entries" path n p;
              let id = Bytes.sub_string b !q 16 and len = u32 b (!q + 16) in
              if !q + 20 + len > qend then damaged "%s: round %d at %d does not hold its entries" path n p;
              entries := (id, Bytes.sub b (!q + 20) len) :: !entries;
              q := !q + 20 + len
            done;
            if !q <> qend then damaged "%s: round %d at %d has bytes after its entries" path n p;
            go stop (n + 1)
      in
      let bad = go header 0 in
      Some (gen, List.rev !entries, bad, b)
    end

let make ?(manual = false) disk dir =
  let file n = { path = Filename.concat dir n; fd = None; gen = 0; size = 0; rounds = 0; held = Hashtbl.create 16 } in
  { disk; files = Array.map file names; active = 0; dirty = false; stopped = None; recovered = Hashtbl.create 16;
    clients = []; m = Mutex.create (); work = Condition.create (); dirt = Condition.create (); pending = [];
    running = false; busy = false; own = 0; dom = None; manual; nrounds = Atomic.make 0; nframes = Atomic.make 0; nown = Atomic.make 0 }

let recover ?manual disk dir =
  let t = make ?manual disk dir in
  let read = List.filter_map (fun f -> Option.map (fun r -> f, r) (read_file disk f.path)) (Array.to_list t.files) in
  let read = List.sort (fun (_, (a, _, _, _)) (_, (b, _, _, _)) -> compare a b) read in
  let newest = List.fold_left (fun _ (_, (g, _, _, _)) -> g) 0 read in
  List.iteri
    (fun i (f, (_, es, bad, b)) ->
      (match bad with
       | None -> ()
       | Some p ->
         (* only the newer file may end with a round that does not check: the one in flight at the crash, if no round
            written whole follows it *)
         if i < List.length read - 1 || written_after b (Bytes.length b) p then
           damaged "%s: damaged round at offset %d (written whole)" (Filename.basename f.path) p);
      List.iter
        (fun (id, fr) ->
          let l = Option.value (Hashtbl.find_opt t.recovered id) ~default:[] in
          Hashtbl.replace t.recovered id (fr :: l))
        es)
    read;
  Hashtbl.filter_map_inplace (fun _ l -> Some (List.rev l)) t.recovered;
  Array.iter (fun f -> f.gen <- newest) t.files;
  t

(* Net opens a server's databases in parallel domains, each taking its frames here: the table is shared. *)
let frames t id =
  Mutex.protect t.m (fun () ->
      match Hashtbl.find_opt t.recovered id with
      | Some l -> Hashtbl.remove t.recovered id; l
      | None -> [])

(* ---- Rounds ---- *)

let fd f = match f.fd with Some fd -> fd | None -> invalid_arg "Wal: the file is not begun"

let sync_dir t = t.disk.Disk.sync_dir (Filename.dirname t.files.(0).path)

(* A file begun with [b] (its header and first round): written beside, forced, renamed over the old file (clean: each
   of its frames is forced in its journal), the directory forced. A crash leaves the old file or the new one, whole. *)
let begin_file t f b =
  Option.iter (fun fd -> f.fd <- None; t.disk.Disk.close fd) f.fd;
  let tmp = f.path ^ ".tmp" in
  let fd = t.disk.Disk.openf tmp true in
  (try
     t.disk.truncate fd 0;
     t.disk.pwrite fd 0 b 0 (Bytes.length b);
     t.disk.fsync fd;
     t.disk.close fd
   with Disk.Io _ as e -> (try t.disk.close fd with Disk.Io _ -> ()); raise e);
  t.disk.rename tmp f.path;
  sync_dir t;
  f.fd <- Some (t.disk.openf f.path false)

(* both files removed (each frame they held is forced in its journal), and what a crash left beside them *)
let remove_files t =
  let gone = ref false in
  Array.iter
    (fun f ->
      Option.iter (fun fd -> f.fd <- None; try t.disk.Disk.close fd with Disk.Io _ -> ()) f.fd;
      List.iter (fun p -> if t.disk.exists p then (t.disk.remove p; gone := true)) [ f.path; f.path ^ ".tmp" ];
      f.size <- 0;
      f.rounds <- 0)
    t.files;
  if !gone then sync_dir t

let stop_with t m =
  Mutex.protect t.m (fun () ->
      if t.stopped = None then t.stopped <- Some m;
      Condition.broadcast t.work;
      Condition.broadcast t.dirt)

(* one round of [cs] (oldest first): the switch to the other file first, if the active one is past its limit and the
   other is clean; then the round appended and forced. A failure stops the buffer, cut back to its last forced round *)
let write_round t cs =
  match t.stopped with
  | Some m -> Error m
  | None -> (
    let f = t.files.(t.active) in
    match
      if f.size > !limit && not (Mutex.protect t.m (fun () -> t.dirty)) then begin
        let o = t.files.(1 - t.active) in
        o.gen <- f.gen + 1;
        o.size <- 0;
        o.rounds <- 0;
        Mutex.protect t.m (fun () ->
            t.active <- 1 - t.active;
            t.dirty <- true;
            Condition.signal t.dirt)
      end;
      let f = t.files.(t.active) in
      (* the file's header with its first round *)
      let h = if f.size = 0 then header else 0 in
      let len = List.fold_left (fun n c -> n + 20 + Bytes.length c.frame) 0 cs in
      let n = h + fh + len + ft in
      let b = Bytes.create n in
      if h > 0 then Bytes.blit (file_header f.gen) 0 b 0 header;
      set32 b h round_magic;
      set32 b (h + 4) len;
      Bytes.set_int64_le b (h + 8) (Int64.of_int f.rounds);
      set32 b (h + 16) (List.length cs);
      let q = ref (h + fh) in
      List.iter
        (fun c ->
          Bytes.blit_string c.id 0 b !q 16;
          set32 b (!q + 16) (Bytes.length c.frame);
          Bytes.blit c.frame 0 b (!q + 20) (Bytes.length c.frame);
          q := !q + 20 + Bytes.length c.frame)
        cs;
      let bc = Crc32c.bytes b (h + fh) len in
      set32 b (h + 20) bc;
      let hc = Crc32c.bytes b h 24 in
      set32 b (h + 24) hc;
      let tl = h + fh + len in
      set32 b tl len;
      set32 b (tl + 4) bc;
      set32 b (tl + 8) hc;
      set32 b (tl + 12) tail_magic;
      if h > 0 then begin_file t f b
      else begin
        let fd = fd f in
        try
          t.disk.pwrite fd f.size b 0 n;
          t.disk.fsync fd
        with Disk.Io _ as e ->
          (* the failed round off the file, so that a recovery does not take it back (unless the cut fails too) *)
          (try t.disk.truncate fd f.size; t.disk.fsync fd
           with Disk.Io m -> prerr_endline ("cepheus: the commit buffer could not be cut back after a failed write: " ^ m));
          raise e
      end;
      f.size <- f.size + n;
      f.rounds <- f.rounds + 1;
      Mutex.protect t.m (fun () -> List.iter (fun c -> Hashtbl.replace f.held c.id c.j) cs)
    with
    | () ->
      Atomic.incr t.nrounds;
      ignore (Atomic.fetch_and_add t.nframes (List.length cs));
      Ok ()
    | exception Disk.Io m -> stop_with t m; Error m)

let take t =
  let cs = List.rev t.pending in
  t.pending <- [];
  cs

let give cs r =
  List.iter (fun c -> c.result <- Some r; c.frame <- Bytes.empty; Condition.signal c.c) cs

let round t =
  let cs = Mutex.protect t.m (fun () -> let cs = take t in t.busy <- cs <> []; cs) in
  if cs <> [] then begin
    let r = write_round t cs in
    Mutex.protect t.m (fun () -> give cs r; t.busy <- false)
  end

let clean t =
  let job = Mutex.protect t.m (fun () ->
      if t.dirty && t.stopped = None then
        let f = t.files.(1 - t.active) in
        Some (f, Hashtbl.fold (fun _ j acc -> j :: acc) f.held [])
      else None)
  in
  match job with
  | None -> ()
  | Some (f, js) -> (
    match List.iter Journal.checkpoint js with
    | () -> Mutex.protect t.m (fun () -> Hashtbl.reset f.held; t.dirty <- false)
    | exception Disk.Io m -> stop_with t m)

(* A frame that comes when the buffer is idle (no round written, none waiting) and no journal forces one of its own is
   forced in its own journal (false: the journal's fsync, then [own_done]), as before the buffer: a database written
   alone pays no second write, and the frames of the others that come meanwhile share the next round (the model's
   WriteOwn: a frame confirmed by its journal's fsync). *)
let alone = ref true

let own_done t () = Mutex.protect t.m (fun () -> t.own <- t.own - 1)

let commit t c frame =
  Mutex.lock t.m;
  match t.stopped with
  | Some m -> Mutex.unlock t.m; raise (Disk.Io m)
  | None when !alone && t.pending = [] && (not t.busy) && t.own = 0 ->
    t.own <- t.own + 1;
    Mutex.unlock t.m;
    Atomic.incr t.nown;
    false
  | None ->
    c.frame <- frame;
    c.result <- None;
    t.pending <- c :: t.pending;
    if t.manual then begin
      Mutex.unlock t.m;
      Effect.perform Wait
    end
    else begin
      Condition.signal t.work;
      while c.result = None do Condition.wait c.c t.m done;
      Mutex.unlock t.m
    end;
    match c.result with
    | Some (Ok ()) -> true
    | Some (Error m) -> raise (Disk.Io m)
    | None -> raise (Disk.Io "the commit buffer gave no result")

let attach t id j =
  let c = { id; j; c = Condition.create (); frame = Bytes.empty; result = None } in
  Mutex.protect t.m (fun () -> t.clients <- c :: t.clients);
  Journal.share j (commit t c) (own_done t)

let rounder t () =
  let go = ref true in
  while !go do
    Mutex.lock t.m;
    while t.pending = [] && t.running do Condition.wait t.work t.m done;
    let cs = take t in
    if cs = [] then go := false;
    t.busy <- cs <> [];
    Mutex.unlock t.m;
    if cs <> [] then begin
      let r = write_round t cs in
      Mutex.protect t.m (fun () -> give cs r; t.busy <- false)
    end
  done

let cleaner t () =
  let go = ref true in
  while !go do
    Mutex.lock t.m;
    while not ((t.dirty && t.stopped = None) || not t.running) do Condition.wait t.dirt t.m done;
    let run = t.running in
    Mutex.unlock t.m;
    if run then clean t else go := false
  done

let start t =
  if Hashtbl.length t.recovered > 0 then begin
    let ids = Hashtbl.fold (fun id _ acc -> String.concat "" (List.map (fun c -> Printf.sprintf "%02x" (Char.code c)) (List.of_seq (String.to_seq id))) :: acc) t.recovered [] in
    damaged "%s holds confirmed writes of databases this server did not open (ids %s): open them with it once"
      names.(0) (String.concat ", " (List.sort compare ids))
  end;
  remove_files t;
  Array.iter (fun f -> f.gen <- f.gen + 1) t.files;
  t.active <- 0;
  t.dirty <- false;
  t.running <- true;
  if not t.manual then
    t.dom <- Some (Pool.spawn (fun () ->
        let a = Thread.create (rounder t) () and b = Thread.create (cleaner t) () in
        Thread.join a;
        Thread.join b))

let stopped t = Mutex.protect t.m (fun () -> t.stopped)

let stop t =
  Mutex.protect t.m (fun () ->
      t.running <- false;
      Condition.broadcast t.work;
      Condition.broadcast t.dirt);
  Option.iter Domain.join t.dom;
  t.dom <- None;
  (* every journal forced (each database closed cleanly): nothing here is needed any more, and the next start reads
     nothing *)
  if t.stopped = None && List.for_all (fun c -> Journal.forced c.j) t.clients then
    (try remove_files t with Disk.Io m -> prerr_endline ("cepheus: the commit buffer could not be emptied: " ^ m))
  else Array.iter (fun f -> Option.iter (fun fd -> f.fd <- None; try t.disk.close fd with Disk.Io _ -> ()) f.fd) t.files

let status t = [ "commit_buffer.rounds", string_of_int (Atomic.get t.nrounds); "commit_buffer.frames", string_of_int (Atomic.get t.nframes);
    "commit_buffer.alone", string_of_int (Atomic.get t.nown) ]
