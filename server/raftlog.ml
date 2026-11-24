(* The Raft log of a server and its durable state, on a Disk.t (the real disk, or the simulation's), in DATA/raft:

     state            "cepheus raft state\n" | term u64 | vote (a peer's name, "" for none) | repair u64 | crc32c
                      (none: the server is fresh, a new cluster's or one whose data was lost, until Raft's fresh rule
                      ends and writes it)
     log.<first>      segments, <first> the index of their first entry in 20 digits
     segment = header 52 B: magic "CPHL" | format u32 (1) | first index u64 | term of the entry before it u64
                            | cluster id (22 B) | 2 zero bytes | crc32c of the 48 before
             | rounds
     round   = header 36 B: magic "CPHE" | body length u32 | first index u64 | count u32 | commit u64
                            | body crc u32 | header crc u32 (of the 32 before)
             | body: count entries, each: term u64 | length u32 | its bytes
             | trailer 16 B: body length u32 | body crc u32 | header crc u32 | magic "CPHT"

   A round is what one fsync forces: the entries given at once (a leader's proposals that came meanwhile, a
   follower's Append). Its commit field is the commit index known when its entries were given to the disk, never past
   its last entry: at start, the newest one is the hint of what is committed. (Not the commit index at the time of
   the write: a truncation queued after these entries may have replaced them, and a later commit index names the
   entries that replaced them: a crash between the two would make the old ones look committed. The simulation
   found it, seed 185.) The state is written beside, forced, renamed over (Disk.write_file).

   Recovery reads every segment. At the first round that does not check, the journal's rule (Journal: torn tail or
   damage) decides: in the newest segment, with no round header that checks after it and no trailer that puts a whole
   round there, a torn tail (written during a crash, never acknowledged: cut); anything else is damage, and the 2018
   rule (design 8.5, spec/Raft.tla) takes it: the damaged segment and those after it are set aside (renamed
   *.damaged, never deleted), the rounds before the damage are written again in a segment of the same name, and the
   state records [repair], the newest index a header that checks names (the damaged round's first at least): the
   server may have acknowledged entries up to it, and votes again only once it holds them from a leader that
   committed them (Raft). A state file that does not check refuses the start: the server cannot know its votes. *)

open Cepheus

exception Damaged of string

let seg_magic = 0x4C485043 (* "CPHL" *)
let round_magic = 0x45485043 (* "CPHE" *)
let tail_magic = 0x54485043 (* "CPHT" *)
let sh = 52
let rh = 36
let rt = 16
let state_magic = "cepheus raft state\n"

(* a segment starts once the newest passes this size (64 MB; tests make it small) *)
let segment_limit = ref (64 lsl 20)

(* the entries' bytes kept in memory (the newest), so that a leader sends without reading its disk *)
let cache_limit = ref (64 lsl 20)

let u32 b i = Int32.to_int (Bytes.get_int32_le b i) land 0xFFFFFFFF
let set32 b i x = Bytes.set_int32_le b i (Int32.of_int x)
let u64 b i = Int64.to_int (Bytes.get_int64_le b i)
let set64 b i x = Bytes.set_int64_le b i (Int64.of_int x)

type round = { rfirst : int; rcount : int; seg : int; off : int; size : int; rcommit : int }

type state = { term : int; vote : string; repair : int }

type recovered = {
  st : state;
  start : int;  (* the first index held *)
  prev_term : int;  (* the term of entry start - 1 *)
  terms : int array;
  sizes : int array;
  commit : int;  (* the newest commit index a round recorded *)
  damage : string option;  (* what was found damaged and set aside *)
  fresh : bool;  (* no state: a new server, or one whose data was lost *)
}

type t = {
  disk : Disk.t;
  dir : string;
  cluster : string;
  secure : string -> unit;  (* the real disk: mode 0600 for a file, 0700 for the directory *)
  m : Mutex.t;
  mutable segs : (int * int) list;  (* (first index, term before it), oldest first *)
  mutable fd : Disk.fd;  (* the newest segment's *)
  mutable seg : int;
  mutable size : int;
  mutable rounds : round array;  (* oldest first, the first [nr] (a plain array: Stdlib's Dynarray links CamlinternalOO,
                                    whose frame descriptors every start-up pays) *)
  mutable nr : int;
  mutable next : int;
  mutable last_term : int;
  cache : (int, int * Bytes.t) Hashtbl.t;  (* index -> term, bytes *)
  cq : int Queue.t;
  mutable cbytes : int;
  mutable failed : bool;
}

let seg_name first = Printf.sprintf "log.%020d" first
let seg_path t first = Filename.concat t.dir (seg_name first)

let is_seg name = String.length name = 24 && String.sub name 0 4 = "log." && String.for_all (fun c -> c >= '0' && c <= '9') (String.sub name 4 20)

let segments disk dir =
  disk.Disk.readdir dir |> List.filter is_seg |> List.map (fun n -> int_of_string (String.sub n 4 20)) |> List.sort compare

(* ---- the state ---- *)

let state_path dir = Filename.concat dir "state"

let encode_state s =
  let b = Buffer.create 64 in
  Buffer.add_string b state_magic;
  Buffer.add_int64_le b (Int64.of_int s.term);
  Codec.put_string b s.vote;
  Buffer.add_int64_le b (Int64.of_int s.repair);
  Buffer.add_int32_le b (Int32.of_int (Crc32c.string (Buffer.contents b)));
  Buffer.to_bytes b

let decode_state path b =
  let n = Bytes.length b and m = String.length state_magic in
  let bad () = raise (Damaged (path ^ " does not check: this server cannot know the votes it gave; it does not start (see the operations guide: a damaged Raft state)")) in
  if n < m + 20 || Bytes.sub_string b 0 m <> state_magic || u32 b (n - 4) <> Crc32c.bytes b 0 (n - 4) then bad ();
  match
    let term = u64 b m in
    let r = Codec.reader b (m + 8) (n - 4 - m - 8) in
    let vote = Codec.get_string r in
    if r.Codec.stop - r.pos <> 8 then raise Codec.Short;
    let repair = u64 b r.pos in
    { term; vote; repair }
  with
  | s when s.term >= 0 && s.repair >= 0 -> s
  | _ -> bad ()
  | exception Codec.Short -> bad ()

let save_state t s =
  let path = state_path t.dir in
  Disk.write_file t.disk path (encode_state s);
  t.secure path

(* ---- rounds ---- *)

let push t r =
  if t.nr = Array.length t.rounds then begin
    let a = Array.make (max 64 (2 * t.nr)) r in
    Array.blit t.rounds 0 a 0 t.nr;
    t.rounds <- a
  end;
  t.rounds.(t.nr) <- r;
  t.nr <- t.nr + 1

let encode_round ~first ~commit (entries : (int * Bytes.t) list) =
  let blen = List.fold_left (fun a (_, d) -> a + 12 + Bytes.length d) 0 entries in
  let b = Bytes.create (rh + blen + rt) in
  set32 b 0 round_magic;
  set32 b 4 blen;
  set64 b 8 first;
  set32 b 16 (List.length entries);
  set64 b 20 commit;
  let o = ref rh in
  List.iter
    (fun (term, d) ->
      set64 b !o term;
      set32 b (!o + 8) (Bytes.length d);
      Bytes.blit d 0 b (!o + 12) (Bytes.length d);
      o := !o + 12 + Bytes.length d)
    entries;
  let bc = Crc32c.bytes b rh blen in
  set32 b 28 bc;
  let hc = Crc32c.bytes b 0 32 in
  set32 b 32 hc;
  let t = rh + blen in
  set32 b t blen;
  set32 b (t + 4) bc;
  set32 b (t + 8) hc;
  set32 b (t + 12) tail_magic;
  b

(* the entries of a round's body: (term, offset of its bytes, length) *)
let parse_body b o blen count =
  let stop = o + blen in
  let p = ref o in
  let l =
    List.init count (fun _ ->
        if !p + 12 > stop then raise Exit;
        let term = u64 b !p and len = u32 b (!p + 8) in
        if term < 0 || len > stop - !p - 12 then raise Exit;
        let x = term, !p + 12, len in
        p := !p + 12 + len;
        x)
  in
  if !p <> stop then raise Exit;
  l

(* the round at p of a segment's bytes, if it checks: (first, count, commit, its entries, its end) *)
let round_at b p size =
  if p + rh > size || u32 b p <> round_magic || u32 b (p + 32) <> Crc32c.bytes b p 32 then None
  else
    let blen = u32 b (p + 4) in
    if blen > size - p - rh - rt then None
    else if u32 b (p + 28) <> Crc32c.bytes b (p + rh) blen then None
    else
      match parse_body b (p + rh) blen (u32 b (p + 16)) with
      | l -> Some (u64 b (p + 8), u32 b (p + 16), u64 b (p + 20), l, p + rh + blen + rt)
      | exception Exit -> None

(* was the round at p written whole although it does not check (the journal's rule): its header checks and the
   trailer where its length puts it matches that header (a byte of its body changed: damage, never a torn tail, or
   an acknowledged entry would be cut: the 2018 paper's failure; the simulation found it, seed 185); or a round
   header that checks anywhere after p; or a trailer whose length and body checksum put a round exactly at p *)
let written_after b p size =
  let whole =
    p + rh <= size && u32 b p = round_magic && u32 b (p + 32) = Crc32c.bytes b p 32
    && (let blen = u32 b (p + 4) in
        let t = p + rh + blen in
        t + rt <= size && u32 b t = blen && u32 b (t + 4) = u32 b (p + 28) && u32 b (t + 8) = u32 b (p + 32) && u32 b (t + 12) = tail_magic)
  in
  let found = ref whole and q = ref (p + 1) in
  while (not !found) && !q + 4 <= size do
    let w = u32 b !q in
    if w = round_magic && !q + rh <= size && u32 b (!q + 32) = Crc32c.bytes b !q 32 then found := true
    else if w = tail_magic then begin
      let ts = !q - 12 in
      if ts >= p + rh && u32 b ts = ts - p - rh && Crc32c.bytes b (p + rh) (ts - p - rh) = u32 b (ts + 4) then found := true
    end;
    incr q
  done;
  !found

(* the newest index a round header that checks names, from p on *)
let named_after b p size =
  let best = ref 0 in
  for q = p to size - rh do
    if u32 b q = round_magic && u32 b (q + 32) = Crc32c.bytes b q 32 then best := max !best (u64 b (q + 8) + u32 b (q + 16) - 1)
  done;
  !best

let seg_header ~first ~prev_term ~cluster =
  let b = Bytes.make sh '\000' in
  set32 b 0 seg_magic;
  set32 b 4 1;
  set64 b 8 first;
  set64 b 16 prev_term;
  Bytes.blit_string cluster 0 b 24 (min 22 (String.length cluster));
  set32 b 48 (Crc32c.bytes b 0 48);
  b

let new_segment disk dir secure ~first ~prev_term ~cluster =
  let path = Filename.concat dir (seg_name first) in
  let fd = disk.Disk.openf path true in
  disk.truncate fd 0;
  disk.pwrite fd 0 (seg_header ~first ~prev_term ~cluster) 0 sh;
  disk.fsync fd;
  disk.sync_dir dir;
  secure path;
  fd

(* ---- recovery ---- *)

let set_aside disk dir name =
  let rec free k = let p = Filename.concat dir (if k = 1 then name ^ ".damaged" else Printf.sprintf "%s.damaged.%d" name k) in if disk.Disk.exists p then free (k + 1) else p in
  disk.Disk.rename (Filename.concat dir name) (free 1)

let open_ ?(secure = fun _ -> ()) disk dir ~cluster =
  if not (disk.Disk.exists dir) then (disk.mkdir dir; disk.sync_dir (Filename.dirname dir));
  secure dir;
  (* no state: a fresh server (it writes none before Raft's fresh rule ends) *)
  let fresh = not (disk.exists (state_path dir)) in
  let st = if not fresh then decode_state (state_path dir) (Disk.read_all disk (state_path dir)) else { term = 0; vote = ""; repair = 0 } in
  let t =
    { disk; dir; cluster; secure; m = Mutex.create (); segs = []; fd = 0; seg = 0; size = 0; rounds = [||]; nr = 0;
      next = 1; last_term = 0; cache = Hashtbl.create 1024; cq = Queue.create (); cbytes = 0; failed = false }
  in
  let terms = ref [] and sizes = ref [] and commit = ref 0 and damage = ref None and repair = ref st.repair in
  let start = ref 0 and prev_term = ref 0 in
  let all = segments disk dir in
  let newest = match List.rev all with s :: _ -> s | [] -> 0 in
  let stop = ref false in
  List.iter
    (fun first ->
      if not !stop then begin
        let path = Filename.concat dir (seg_name first) in
        let b = Disk.read_all disk path in
        let size = Bytes.length b in
        let damaged at why =
          (* the 2018 rule: what follows is set aside, the server votes again once a leader gave it back *)
          let named = ref (max t.next (named_after b at size)) in
          List.iter
            (fun s ->
              if s > first then
                let bb = Disk.read_all disk (Filename.concat dir (seg_name s)) in
                named := max !named (named_after bb 0 (Bytes.length bb)))
            all;
          repair := max !repair !named;
          let s = { st with repair = !repair } in
          Disk.write_file disk (state_path dir) (encode_state s);
          secure (state_path dir);
          List.iter (fun s -> if s >= first then set_aside disk dir (seg_name s)) all;
          disk.sync_dir dir;
          damage := Some (Printf.sprintf "%s: %s at index %d; set aside, kept as *.damaged; this server votes again once it holds entries up to %d from a leader" path why t.next !repair);
          stop := true;
          t.segs <- List.filter (fun (x, _) -> x <> first) t.segs;
          (* the newest segment left takes the next rounds (its size was set when its scan ended) *)
          t.seg <- (match List.rev t.segs with (x, _) :: _ -> x | [] -> 0);
          (* the rounds before the damage, again in a segment of this name *)
          if at > sh then begin
            let fd = disk.openf path true in
            disk.pwrite fd 0 b 0 at;
            disk.fsync fd;
            disk.close fd;
            disk.sync_dir dir;
            secure path;
            t.segs <- t.segs @ [ first, u64 b 16 ];
            t.seg <- first;
            t.size <- at
          end
        in
        if size < sh || u32 b 0 <> seg_magic || u32 b 48 <> Crc32c.bytes b 0 48 || u32 b 4 <> 1 then begin
          if first = newest && size < sh then begin
            (* a segment torn at its creation, before any round: removed *)
            disk.remove path;
            disk.sync_dir dir;
            stop := true
          end
          else damaged 0 "a segment header that does not check"
        end
        else if Bytes.sub_string b 24 (min 22 (String.length cluster)) <> String.sub cluster 0 (min 22 (String.length cluster)) then
          raise (Damaged (Printf.sprintf "%s belongs to another cluster" path))
        else if t.segs <> [] && u64 b 8 <> t.next then damaged 0 (Printf.sprintf "a segment starting at %d where %d was expected" (u64 b 8) t.next)
        else begin
          if t.segs = [] then (start := u64 b 8; prev_term := u64 b 16; t.next <- !start; t.last_term <- !prev_term);
          t.segs <- t.segs @ [ first, u64 b 16 ];
          t.seg <- first;
          let p = ref sh in
          let go = ref true in
          while !go && !p < size do
            match round_at b !p size with
            | Some (f, count, c, es, e) when f = t.next && List.for_all (fun (tm, _, _) -> tm >= t.last_term) es
                                           && (let ok = ref true and prev = ref t.last_term in List.iter (fun (tm, _, _) -> if tm < !prev then ok := false; prev := tm) es; !ok) ->
              push t { rfirst = f; rcount = count; seg = first; off = !p; size = e - !p; rcommit = c };
              List.iter (fun (tm, _, len) -> terms := tm :: !terms; sizes := len :: !sizes; t.last_term <- tm) es;
              t.next <- f + count;
              commit := max !commit (min c (t.next - 1));
              p := e
            | _ ->
              go := false;
              if first = newest && not (written_after b !p size) then begin
                (* a torn tail: the round being written at the crash, never acknowledged *)
                let fd = disk.openf path false in
                disk.truncate fd !p;
                disk.fsync fd;
                disk.close fd
              end
              else damaged !p "a round that does not check"
          done;
          if not !stop then t.size <- !p
        end
      end)
    all;
  if t.segs = [] then begin
    (* a new log (or every segment set aside: it starts again after the last index known) *)
    let first = max 1 t.next in
    t.fd <- new_segment disk dir secure ~first ~prev_term:t.last_term ~cluster;
    t.segs <- [ first, t.last_term ];
    t.seg <- first;
    t.size <- sh;
    if !start = 0 then (start := first; prev_term := t.last_term);
    t.next <- first
  end
  else begin
    t.fd <- disk.openf (seg_path t t.seg) false;
    (* what a killed process wrote and did not force may be in the page cache only: the newest round is written
       again and forced before anything rests on it (as the journal's recovery does) *)
    match if t.nr = 0 then None else Some t.rounds.(t.nr - 1) with
    | Some r when r.seg = t.seg ->
      let b = Bytes.create r.size in
      disk.pread t.fd r.off b 0 r.size;
      disk.pwrite t.fd r.off b 0 r.size;
      disk.fsync t.fd;
      disk.sync_dir dir
    | _ -> disk.fsync t.fd; disk.sync_dir dir
  end;
  let st = { st with repair = !repair } in
  t,
  { st; start = !start; prev_term = !prev_term; terms = Array.of_list (List.rev !terms); sizes = Array.of_list (List.rev !sizes);
    commit = !commit; damage = !damage; fresh }

(* ---- appends, truncation, the start ---- *)

let remember t i term d =
  if Bytes.length d <= !cache_limit then begin
    Hashtbl.replace t.cache i (term, d);
    Queue.push i t.cq;
    t.cbytes <- t.cbytes + Bytes.length d;
    while t.cbytes > !cache_limit do
      let j = Queue.take t.cq in
      match Hashtbl.find_opt t.cache j with
      | Some (_, x) -> Hashtbl.remove t.cache j; t.cbytes <- t.cbytes - Bytes.length x
      | None -> ()
    done
  end

let fail t f = try f () with Disk.Io _ as e -> t.failed <- true; raise e

(* one round: entries [first, first + count), written and forced *)
let append t ~first ~commit entries =
  Mutex.protect t.m (fun () ->
      if t.failed then raise (Disk.Io "the Raft log: an earlier write failed");
      if first <> t.next then invalid_arg (Printf.sprintf "Raftlog.append: %d where %d was expected" first t.next);
      let b = encode_round ~first ~commit:(min commit (first + List.length entries - 1)) entries in
      let n = Bytes.length b in
      fail t (fun () ->
          if t.size > sh && t.size + n > !segment_limit then begin
            let fd = new_segment t.disk t.dir t.secure ~first ~prev_term:t.last_term ~cluster:t.cluster in
            t.disk.close t.fd;
            t.fd <- fd;
            t.seg <- first;
            t.size <- sh;
            t.segs <- t.segs @ [ first, t.last_term ]
          end;
          t.disk.pwrite t.fd t.size b 0 n;
          t.disk.fsync t.fd);
      push t { rfirst = first; rcount = List.length entries; seg = t.seg; off = t.size; size = n; rcommit = commit };
      t.size <- t.size + n;
      List.iteri (fun k (term, d) -> remember t (first + k) term d; t.last_term <- term) entries;
      t.next <- first + List.length entries)

(* the round holding index i (rounds of no entry hold none) *)
let find_round t i =
  let lo = ref 0 and hi = ref (t.nr - 1) and res = ref None in
  while !lo <= !hi do
    let mid = (!lo + !hi) / 2 in
    let r = t.rounds.(mid) in
    if i < r.rfirst then hi := mid - 1
    else if i >= r.rfirst + r.rcount then lo := mid + 1
    else (res := Some (mid, r); lo := !hi + 1)
  done;
  !res

let read_round t (r : round) =
  let fd = if r.seg = t.seg then t.fd else t.disk.openf (seg_path t r.seg) false in
  Fun.protect ~finally:(fun () -> if r.seg <> t.seg then t.disk.close fd) (fun () ->
      let b = Bytes.create r.size in
      t.disk.pread fd r.off b 0 r.size;
      match round_at b 0 r.size with
      | Some (_, _, _, es, _) -> List.map (fun (tm, o, len) -> tm, Bytes.sub b o len) es
      | None -> raise (Damaged (Printf.sprintf "%s: the round of entries %d to %d no longer checks" (seg_path t r.seg) r.rfirst (r.rfirst + r.rcount - 1))))

(* an entry's term and bytes, if the log holds it *)
let read t i =
  Mutex.protect t.m (fun () ->
      match Hashtbl.find_opt t.cache i with
      | Some x -> Some x
      | None -> (
        match find_round t i with
        | None -> None
        | Some (_, r) -> Some (List.nth (read_round t r) (i - r.rfirst))))

(* every entry from index [from] on (to [upto]), in order, each round read once (recovery: a database's frames to
   write again; a frame's pieces) *)
let iter ?(upto = max_int) t ~from f =
  let rs = Mutex.protect t.m (fun () -> List.init t.nr (Array.get t.rounds)) in
  List.iter
    (fun r ->
      if r.rfirst + r.rcount > from && r.rfirst <= upto then
        List.iteri (fun k (term, d) -> let i = r.rfirst + k in if i >= from && i <= upto then f i term d) (Mutex.protect t.m (fun () -> read_round t r)))
    rs

(* entries from i on dropped, forced (a follower's entries that a new leader's log does not hold); [prev_term]: the
   term of entry i - 1 *)
let truncate t i ~prev_term =
  Mutex.protect t.m (fun () ->
      if i < t.next then
        fail t (fun () ->
            (* the first round that holds i or comes after it *)
            let k = ref 0 in
            while !k < t.nr && t.rounds.(!k).rfirst + t.rounds.(!k).rcount <= i do incr k done;
            if !k < t.nr then begin
              let r = t.rounds.(!k) in
              let keep = if r.rfirst < i then List.filteri (fun j _ -> r.rfirst + j < i) (read_round t r) else [] in
              (* the segments after r's removed; r's cut at r *)
              List.iter (fun (s, _) -> if s > r.seg then t.disk.remove (seg_path t s)) t.segs;
              t.segs <- List.filter (fun (s, _) -> s <= r.seg) t.segs;
              if r.seg <> t.seg then (t.disk.close t.fd; t.fd <- t.disk.openf (seg_path t r.seg) false; t.seg <- r.seg);
              t.disk.truncate t.fd r.off;
              t.size <- r.off;
              t.nr <- !k;
              t.next <- r.rfirst;
              t.last_term <- prev_term;
              if keep <> [] then begin
                let b = encode_round ~first:r.rfirst ~commit:(min r.rcommit (i - 1)) keep in
                t.disk.pwrite t.fd t.size b 0 (Bytes.length b);
                push t { rfirst = r.rfirst; rcount = List.length keep; seg = t.seg; off = t.size; size = Bytes.length b; rcommit = min r.rcommit (i - 1) };
                t.size <- t.size + Bytes.length b;
                t.next <- i
              end;
              t.disk.fsync t.fd;
              t.disk.sync_dir t.dir
            end
            else t.last_term <- prev_term);
      Hashtbl.filter_map_inplace (fun j (tm, d) -> if j >= i then (t.cbytes <- t.cbytes - Bytes.length d; None) else Some (tm, d)) t.cache)

(* whole segments before index i removed (their entries are in the databases' journals, forced) *)
let cut_before t i =
  Mutex.protect t.m (fun () ->
      let rec go = function
        | (s, _) :: (((s', _) :: _) as rest) when s' <= i && s <> t.seg ->
          t.disk.remove (seg_path t s);
          ignore s';
          go rest
        | l -> l
      in
      let l = go t.segs in
      if List.length l <> List.length t.segs then begin
        t.segs <- l;
        let first = fst (List.hd l) in
        let k = ref 0 in
        while !k < t.nr && t.rounds.(!k).seg < first do incr k done;
        Array.blit t.rounds !k t.rounds 0 (t.nr - !k);
        t.nr <- t.nr - !k;
        t.disk.sync_dir t.dir
      end)

(* ---- a copy of the databases installed (Catchup) ----
   DATA/raft/copy/index, written once the copy is whole and checked, then the folder renamed into place (the commit
   point): "cepheus raft copy\n" | index u64 | term u64 | the peer it came from | crc32c. At the next start the
   databases are swapped and the log made to start after the copy's index ([install]); the index is removed last, so
   that a crash anywhere repeats what was not done. *)

let copy_magic = "cepheus raft copy\n"

let encode_copy ~index ~term ~source =
  let b = Buffer.create 64 in
  Buffer.add_string b copy_magic;
  Buffer.add_int64_le b (Int64.of_int index);
  Buffer.add_int64_le b (Int64.of_int term);
  Codec.put_string b source;
  Buffer.add_int32_le b (Int32.of_int (Crc32c.string (Buffer.contents b)));
  Buffer.to_bytes b

(* (index, term, source), or None if it does not check *)
let decode_copy b =
  let n = Bytes.length b and m = String.length copy_magic in
  if n < m + 16 + 1 + 4 || Bytes.sub_string b 0 m <> copy_magic || u32 b (n - 4) <> Crc32c.bytes b 0 (n - 4) then None
  else
    match
      let index = u64 b m and term = u64 b (m + 8) in
      let r = Codec.reader b (m + 16) (n - 4 - m - 16) in
      let source = Codec.get_string r in
      if r.Codec.pos <> r.stop || index < 1 || term < 0 then None else Some (index, term, source)
    with
    | x -> x
    | exception Codec.Short -> None

(* the log of [dir] made to start at [first] (its entry before, of term [prev_term], is in the databases): every
   segment removed (those set aside as *.damaged kept), one empty segment written, forced; the 2018 rule's repair
   ends if the copy reaches it. Idempotent: a crash in it is repeated at the next start *)
let install ?(secure = fun _ -> ()) disk dir ~cluster ~first ~prev_term =
  let sp = state_path dir in
  if disk.Disk.exists sp then begin
    let st = decode_state sp (Disk.read_all disk sp) in
    if st.repair > 0 && st.repair <= first - 1 then begin
      Disk.write_file disk sp (encode_state { st with repair = 0 });
      secure sp
    end
  end;
  List.iter (fun s -> disk.remove (Filename.concat dir (seg_name s))) (segments disk dir);
  disk.sync_dir dir;
  disk.close (new_segment disk dir secure ~first ~prev_term ~cluster)

(* the first index held on disk *)
let first t = Mutex.protect t.m (fun () -> match t.segs with (s, _) :: _ -> s | [] -> t.next)
let next t = Mutex.protect t.m (fun () -> t.next)
let close t = try t.disk.close t.fd with Disk.Io _ -> ()
let bytes t = Mutex.protect t.m (fun () -> List.length t.segs, t.size)
