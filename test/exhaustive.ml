(* Exhaustive enumeration, in the spirit of ALICE (Pillai et al., OSDI 2014) pushed to every case on small journals:
   1. after m durable frames, every state a crash can leave of frame m+1 (each subset of its sectors reached the disk,
      each cut length, each sector torn inside) must recover to exactly m or m+1 groups, never lose one;
   2. every single bit flipped anywhere in the durable journal is detected by a full read, and recovery either
      refuses, or keeps every group (a flipped trailer, rebuilt), or is the documented residual (a flip in the newest
      frame, cut as torn: docs/book/guarantees.md, G6);
   3. a segment whose creation was torn at any byte is dropped, and the journal continues;
   4. inside a merge (G12): at every mutating disk call of a merge (a merge now, one begun from a view ahead of the
      disk and installed after two more frames, the merges of a recovery replaying a long tail), every crash state:
      a process death (the page cache kept, then lost at a later power loss), and power losses keeping each prefix
      of each directory's name changes, with the unsynced bytes lost, kept, torn, or kept one sector in two. Recovery
      must open on the old base or the new one, at a state of the reference, with every confirmed group, never set
      a snapshot aside, never leave a merge's file;
   5. each fsync of a small run failing in turn (G10, G13), then deaths at each call after it, reopens and power
      losses: every view published survives. *)

open Cepheus
module C = Check

let id = "0123456789abcdef"
let sector = Sim_disk.sector

(* the journal read through a window of 48 bytes: every frame is longer, checked by pieces and read whole to be
   decoded, and every header and trailer may straddle the window's edge *)
let () = Journal.window := 48

let group n text =
  { Group.n; time = n; by = 1; why = "x"; first_new = 65536 + n; count_new = 1;
    changes = [| { Group.kind = Added; e = 65536 + n; p = 16; v = Value.Text text } |] }

(* A journal of frames, each of a few groups with texts of the given sizes; the bytes and the frame ends. *)
let build sizes =
  let sim = Sim_disk.create (Rng.make 1) in
  let disk = Sim_disk.disk sim in
  disk.mkdir "/j";
  let j = Journal.create disk "/j" id in
  let ends = ref [ 40 ] and n = ref 1 in
  List.iter
    (fun sz ->
      let body = Buffer.create 256 in
      let g1 = group !n (String.make sz 'a') and g2 = group (!n + 1) (String.make (sz / 3) 'b') in
      Group.encode body g1;
      Group.encode body g2;
      Journal.append j body !n 2;
      n := !n + 2;
      ends := (Journal.position j).offset :: !ends)
    sizes;
  Sim_disk.durable_bytes sim "/j/00000000000000000001.seg", Array.of_list (List.rev !ends)

(* Recovery on a file with exactly these bytes: the groups, or the damage. *)
let recover_bytes b =
  let sim = Sim_disk.create (Rng.make 2) in
  let disk = Sim_disk.disk sim in
  disk.mkdir "/j";
  let fd = disk.openf "/j/00000000000000000001.seg" true in
  disk.pwrite fd 0 b 0 (Bytes.length b);
  disk.fsync fd;
  disk.sync_dir "/j";
  let got = ref [] in
  match Journal.recover ~force:true disk "/j" id None (fun g -> got := g.n :: !got) with
  | j -> Journal.close j; Ok (List.length !got), disk
  | exception Journal.Damaged m -> Error m, disk

let strict_read disk = match Journal.read disk "/j" id (fun _ -> ()) with () -> false | exception Journal.Damaged _ -> true

let false_alarms = ref 0
let residual = ref 0
let states = ref 0

let crash_states sizes =
  let full, ends = build sizes in
  let frames = Array.length ends - 1 in
  for m = 0 to frames - 1 do
    let lo = ends.(m) and hi = ends.(m + 1) in
    (* the sectors of frame m+1, as file sector indexes *)
    let s0 = lo / sector and s1 = (hi - 1) / sector in
    let ns = s1 - s0 + 1 in
    if ns > 10 then failwith "frame too large for the enumeration";
    let prefix = Bytes.sub full 0 lo in
    for mask = 0 to (1 lsl ns) - 1 do
      (* lengths: the durable end, each sector boundary inside, the full end *)
      let lens = List.sort_uniq compare (lo :: hi :: List.init ns (fun k -> min hi (max lo ((s0 + k + 1) * sector)))) in
      List.iter
        (fun len ->
          (* torn: the highest kept sector may be cut inside *)
          let tears = [ None; Some 1; Some (sector / 2); Some (sector - 1) ] in
          List.iter
            (fun tear ->
              let b = Bytes.make len '\000' in
              Bytes.blit prefix 0 b 0 (min lo len);
              let top = ref (-1) in
              for k = 0 to ns - 1 do if mask land (1 lsl k) <> 0 then top := k done;
              for k = 0 to ns - 1 do
                if mask land (1 lsl k) <> 0 then begin
                  let a = max lo ((s0 + k) * sector) and z = min len (min hi ((s0 + k + 1) * sector)) in
                  let z = match tear with Some t when k = !top -> min z (((s0 + k) * sector) + t) | _ -> z in
                  if a < z then Bytes.blit full a b a (z - a)
                end
              done;
              incr states;
              (* the frame counts once its header and body reached the disk and the file reaches its end: a torn
                 trailer alone is rebuilt from the header (G6) *)
              let whole = Bytes.length b >= hi && Bytes.sub b lo (hi - lo - 16) = Bytes.sub full lo (hi - lo - 16) in
              match recover_bytes b with
              | Ok n, _ ->
                let want = 2 * if whole then m + 1 else m in
                C.check (n = want) "frames %s, m %d, mask %x, len %d: recovered %d groups, want %d"
                  (String.concat "," (List.map string_of_int sizes)) m mask len n want
              | Error msg, _ ->
                (* the accepted false alarm: only the header's sector was lost, body and trailer reached the disk *)
                let h1 = ((lo + 27) / sector) - s0 in
                let header_lost = mask land 1 = 0 || (h1 > 0 && mask land 2 = 0) in
                if header_lost then incr false_alarms
                else C.fail "frames %s, m %d, mask %x, len %d: damage reported for a torn write: %s"
                    (String.concat "," (List.map string_of_int sizes)) m mask len msg)
            tears)
        lens
    done
  done

let flips sizes =
  let full, ends = build sizes in
  let frames = Array.length ends - 1 in
  let newest = ends.(frames - 1) in
  for off = 40 to Bytes.length full - 1 do
    for bit = 0 to 7 do
      let b = Bytes.copy full in
      Bytes.set b off (Char.chr (Char.code (Bytes.get b off) lxor (1 lsl bit)));
      let sim = Sim_disk.create (Rng.make 3) in
      let disk = Sim_disk.disk sim in
      disk.mkdir "/j";
      let fd = disk.openf "/j/00000000000000000001.seg" true in
      disk.pwrite fd 0 b 0 (Bytes.length b);
      disk.fsync fd;
      C.check (strict_read disk) "flip at %d bit %d not seen by a full read" off bit;
      match recover_bytes b with
      | Error _, _ -> incr C.checks
      | Ok n, _ when n = 2 * frames -> incr C.checks (* a trailer, rebuilt *)
      | Ok n, _ when n = 2 * (frames - 1) && off >= newest -> incr residual
      | Ok n, _ -> C.fail "flip at %d bit %d: recovery kept %d groups of %d" off bit n (2 * frames)
    done
  done

let torn_segment () =
  (* a second segment whose header was torn at its creation: dropped, the journal goes on from the first *)
  let full, _ = build [ 100; 300 ] in
  for k = 0 to 40 do
    let sim = Sim_disk.create (Rng.make 4) in
    let disk = Sim_disk.disk sim in
    disk.mkdir "/j";
    let put name b =
      let fd = disk.openf name true in
      disk.pwrite fd 0 b 0 (Bytes.length b);
      disk.fsync fd
    in
    put "/j/00000000000000000001.seg" full;
    let seg2 = Bytes.make 40 '\000' in
    let hdr, _ = build [] in
    Bytes.blit hdr 0 seg2 0 40;
    Bytes.set_int64_le seg2 24 5L;
    Bytes.set_int32_le seg2 36 (Int32.of_int (Crc32c.bytes seg2 0 36));
    put "/j/00000000000000000005.seg" (Bytes.sub seg2 0 k);
    disk.sync_dir "/j";
    let n = ref 0 in
    match Journal.recover ~force:true disk "/j" id None (fun _ -> incr n) with
    | j ->
      C.check (!n = 4 && Journal.next_group j = 5) "torn segment header at %d: %d groups" k !n;
      Journal.close j
    | exception Journal.Damaged m -> C.fail "torn segment header at %d: %s" k m
  done

(* ---- 4. inside a merge ---- *)

let mdir = "/db"
let mprops = [ prop "name" Ttext; prop ~many:true "tag" Ttext; prop "score" Tint ]

type run = { sim : Sim_disk.t; disk : Disk.t; mutable e : Engine.t; mutable acked : int }

(* the facts of every group a run made, published or only prepared: the reference *)
let mstates : (int, C.F.t) Hashtbl.t = Hashtbl.create 64

let open_db disk =
  match Engine.open_ ~id_source:(fun _ -> id) disk mdir with Ok e -> e | Error m -> failwith (Engine.message m)

let declare_ops (v : Store.view) =
  List.concat (List.mapi (fun i (d : prop) -> List.map (fun (e, q, x) -> Resolve.Add (e, q, x)) (Schema.facts (Schema.first_prop + i) d)) mprops)
  |> fun ops -> if Schema.by_name v.schema "name" = None then ops else []

let ops_for (v : Store.view) i =
  let p n = Option.get (Schema.by_name v.schema n) in
  let old = Schema.first_thing + (i mod max 1 (v.next_e - Schema.first_thing)) in
  [ Resolve.Add (-1, p "name", Text (Printf.sprintf "n%d" i)); Add (-1, p "score", Int i); Add (-1, p "tag", Text "t") ]
  @ if i > 3 then [ Add (old, p "tag", Text (Printf.sprintf "u%d" i)); Retract (old, p "tag", Text "t") ] else []

(* a variant makes the same groups at every replay: each group's facts computed once *)
let record (v : Store.view) = if not (Hashtbl.mem mstates v.group) then Hashtbl.replace mstates v.group (C.facts_of_view v)

let prepare r ops = let b = Engine.prepare r.e [| ops, 1, "x" |] in record r.e.working; b

let commit r b =
  ignore (Engine.commit r.e b);
  let v = Atomic.get r.e.published in
  record v;
  r.acked <- v.group

let write r ops = commit r (prepare r ops)

(* a database with two snapshots and a tail: the state just before the merge under test *)
let setup tail =
  Engine.compact_min := 1_000_000;
  let sim = Sim_disk.create (Rng.make 7) in
  let disk = Sim_disk.disk sim in
  let r = { sim; disk; e = open_db disk; acked = 0 } in
  record (Atomic.get r.e.published);
  r.acked <- (Atomic.get r.e.published).group;
  write r (declare_ops r.e.working);
  for i = 1 to 5 do write r (ops_for r.e.working i) done;
  Engine.compact r.e;
  for i = 6 to 9 do write r (ops_for r.e.working i) done;
  Engine.compact r.e;
  for i = 10 to 10 + tail do write r (ops_for r.e.working i) done;
  r

type variant = { vname : string; tail : int; before : run -> unit; run : run -> unit; old_new : run -> int list option }

let variants =
  [ { vname = "a merge now"; tail = 3; before = ignore; run = (fun r -> Engine.compact r.e);
      old_new = (fun r -> Some [ r.e.merged; r.e.working.group ]) };
    { vname = "a merge begun ahead of the disk, installed two frames later"; tail = 3; before = ignore;
      run =
        (fun r ->
          let b1 = prepare r (ops_for r.e.working 20) in
          let m = Engine.merge_begin ~busy:(fun () -> true) r.e r.e.working (Atomic.get r.e.at) in
          commit r b1;
          let b2 = prepare r (ops_for r.e.working 21) in
          commit r b2;
          let v = List.fold_left Resolve.replay m.view (List.rev b2.groups) in
          Engine.install r.e m v);
      old_new = (fun r -> Some [ r.e.merged; r.e.working.group + 1 ]) };
    { vname = "a large group, merged as it is prepared, named once its frame is durable"; tail = 3; before = ignore;
      run =
        (fun r ->
          (* groups of 4 additions and more take the path of large groups; only here, so that the replays of the
             other variants make no merge of their own *)
          Resolve.large_min := 4;
          let p n = Option.get (Schema.by_name r.e.working.schema n) in
          let ops = List.concat (List.init 3 (fun k -> let t = -(k + 1) in
              [ Resolve.Add (t, p "name", Text (Printf.sprintf "big%d" k)); Add (t, p "score", Int k); Add (t, p "tag", Text "t") ])) in
          let b = prepare r ops in
          if b.runs = [] then failwith "the large group did not take its path";
          commit r b;
          Resolve.large_min := 20_000);
      old_new = (fun r -> Some [ r.e.merged; r.e.working.group + 1 ]) };
    { vname = "the merges of a recovery replaying a long tail"; tail = 12;
      before = (fun r -> Sim_disk.kill r.sim);
      run = (fun r -> Engine.compact_min := 3; r.e <- open_db r.disk);
      old_new = (fun _ -> None) } ]

let patterns = [ "lost", 0; "kept", 2; "torn", 5; "one in two", -1 ]

let merge_states = ref 0
let merge_points = ref 0

(* recovery after the crash: the checks of G1, G7 and G12 *)
let recovered what r ~acked old_new =
  Engine.compact_min := 1_000_000;
  Resolve.large_min := 20_000;
  incr merge_states;
  match Engine.open_ ~id_source:(fun _ -> id) r.disk mdir with
  | Error m -> C.fail "%s: recovery failed: %s" what (Engine.message m); None
  | Ok e ->
    let k = e.working.group in
    C.check (k >= acked) "%s: recovered to group %d, %d was confirmed" what k acked;
    C.check (match Hashtbl.find_opt mstates k with Some f -> C.F.equal f (C.facts_of_view e.working) | None -> false)
      "%s: the state at group %d is not the reference" what k;
    C.check (not (List.exists (fun n -> String.length n > 8 && String.sub n 0 8 = "snapshot") e.notes))
      "%s: a snapshot was set aside: %s" what (String.concat "; " e.notes);
    C.check (not (List.exists (fun f -> Filename.check_suffix f ".tmp") (Sim_disk.files r.sim))) "%s: a merge's file was left" what;
    (match old_new with
     | Some l -> C.check (List.mem e.merged l) "%s: the base is of group %d, neither the old nor the new one" what e.merged
     | None -> ());
    Engine.close e;
    Some k

let enumerate_merge (v : variant) =
  (* the crash points: every mutating call of the run, until the run ends without reaching one *)
  Hashtbl.reset mstates;
  let points0 = !merge_points and states0 = !merge_states in
  let reach k =
    let r = setup v.tail in
    let before = v.old_new r in
    let acked0 = r.acked in
    v.before r;
    Sim_disk.crash_after r.sim k;
    match v.run r with
    | () -> Sim_disk.crash_after r.sim (-1); None
    | exception Sim_disk.Crash -> Some (r, before, max acked0 r.acked)
  in
  let k = ref 0 and go = ref true in
  while !go do
    (match reach !k with
     | None -> go := false
     | Some (r, _, _) ->
       incr merge_points;
       let dirs = List.filter (fun d -> Sim_disk.pending_names r.sim d > 0) [ mdir; mdir ^ "/journal"; mdir ^ "/snapshots" ] in
       let rec prefixes = function
         | [] -> [ [] ]
         | d :: rest ->
           List.concat_map (fun j -> List.map (fun l -> (d, j) :: l) (prefixes rest)) (List.init (Sim_disk.pending_names r.sim d + 1) Fun.id)
       in
       let what = Printf.sprintf "%s, crash at call %d" v.vname !k in
       (* a process death: recovery reads the page cache; a later power loss must keep what it published *)
       (match reach !k with
        | Some (r, before, acked) -> (
          Sim_disk.kill r.sim;
          match recovered (what ^ ", process death") r ~acked before with
          | Some k1 ->
            Sim_disk.crash ~choose:(fun _ _ -> 0) r.sim;
            ignore (recovered (what ^ ", process death then power loss") r ~acked:k1 None)
          | None -> ())
        | None -> ());
       List.iter
         (fun prefix ->
           List.iter
             (fun (pname, sector) ->
               match reach !k with
               | Some (r, before, acked) ->
                 let choose (d : Sim_disk.draw) n =
                   match d with
                   | Names dir -> List.assoc dir prefix
                   | Length _ -> if sector = 0 then 0 else 1
                   | Cut _ | Tear _ -> n / 2
                   | Sector (_, s) -> if sector >= 0 then sector else if s mod 2 = 0 then 2 else 0
                 in
                 Sim_disk.crash ~choose r.sim;
                 let names = String.concat "," (List.map (fun (d, j) -> Printf.sprintf "%s:%d" (Filename.basename d) j) prefix) in
                 ignore (recovered (Printf.sprintf "%s, names %s, bytes %s" what names pname) r ~acked before)
               | None -> C.fail "%s: the crash point moved" what)
             patterns)
         (prefixes dirs));
    incr k
  done;
  Printf.printf "  %s: %d crash points, %d states\n" v.vname (!merge_points - points0) (!merge_states - states0)

let () =
  (* a small cache: the pages of a crashed run (and through them its simulated disk) stay only until evicted *)
  Pages.set_capacity (8 lsl 20);
  (* a merge forces its file every 4 pages: crash points between those fsyncs too *)
  Snapshot.sync_every := 4 * Pages.size;
  List.iter enumerate_merge variants;
  Printf.printf "exhaustive merges: %d crash points, %d crash states recovered\n" !merge_points !merge_states

(* ---- 5. a failed fsync (G10, G13) ----
   A small database written frame by frame, with segment switches and a merge, on a file system that keeps the bytes
   of a failed fsync in memory (ext4, XFS) or one that undoes them (Btrfs). Each fsync of the run fails in turn; the
   process then dies at each of the next disk calls (the writer's cut of the journal), or goes on to the end of the
   run; then a reopen in the same boot (it reads the page cache, as after a process death or a close) or none, then a
   power loss keeping all or none of the name changes, with the unforced bytes lost, kept, torn, or kept one sector in
   two, and a reopen. Every reopen must open at a state of the reference with every confirmed group, and what the
   first reopen published must survive the power loss. Damage may be reported only at the frame whose fsync failed
   when its header's sector alone was lost (the false alarm of G6), and only if the process died before its cut. *)

let fs_states = ref 0
let fs_alarms = ref 0

type frun = { fr : run; mutable unsure : int option (* the offset of a frame no fsync confirmed *) }

let fs_write f ops =
  let b = prepare f.fr ops in
  if b.count > 0 && f.fr.e.stopped = None then f.unsure <- Some (Journal.position f.fr.e.journal).offset;
  let res = Engine.commit f.fr.e b in
  if Array.for_all (function Error (Engine.Io _) -> false | _ -> true) res then f.unsure <- None;
  let v = Atomic.get f.fr.e.published in
  record v;
  f.fr.acked <- v.group

(* the run, fsync k (counted after the open) failing, the process dying [after] calls later: the run, and whether it
   died *)
let fs_run reverts k after =
  Engine.compact_min := 1_000_000;
  let sim = Sim_disk.create ~reverts (Rng.make 9) in
  let disk = Sim_disk.disk sim in
  let f = { fr = { sim; disk; e = open_db disk; acked = 0 }; unsure = None } in
  record (Atomic.get f.fr.e.published);
  f.fr.acked <- (Atomic.get f.fr.e.published).group;
  Sim_disk.fail_fsync_at ?crash_after:after sim k;
  match
    fs_write f (declare_ops f.fr.e.working);
    for i = 1 to 5 do fs_write f (ops_for f.fr.e.working i) done;
    ignore (Engine.snapshot f.fr.e);
    for i = 6 to 9 do fs_write f (ops_for f.fr.e.working i) done
  with
  | () -> f, false
  | exception Sim_disk.Crash -> f, true

let fs_alarm f m =
  match f.unsure with
  | Some off ->
    let s = Printf.sprintf "at offset %d (written whole)" off in
    let n = String.length s in
    let rec has i = i + n <= String.length m && (String.sub m i n = s || has (i + 1)) in
    has 0
  | None -> false

(* a reopen: the group it opens at, or None after the accepted false alarm *)
let fs_open what f ~acked ~died =
  incr fs_states;
  Engine.compact_min := 1_000_000;
  match Engine.open_ ~id_source:(fun _ -> id) f.fr.disk mdir with
  | Ok e ->
    let k = e.working.group in
    C.check (k >= acked) "%s: recovered to group %d, %d was confirmed" what k acked;
    C.check (match Hashtbl.find_opt mstates k with Some s -> C.F.equal s (C.facts_of_view e.working) | None -> false)
      "%s: the state at group %d is not the reference" what k;
    f.unsure <- None;
    Some k
  | Error (Damaged m) when died && fs_alarm f m -> incr fs_alarms; None
  | Error e -> C.fail "%s: recovery failed: %s" what (Engine.message e); None

let enumerate_fsync reverts =
  Hashtbl.reset mstates;
  Journal.segment_limit := 700;
  let fsname = if reverts then "a file system that undoes a failed write (Btrfs)" else "one that keeps it (ext4, XFS)" in
  let states0 = !fs_states and k = ref 0 and go = ref true in
  while !go do
    let f, _ = fs_run reverts !k None in
    if Sim_disk.failures f.fr.sim = 0 then go := false
    else
      List.iter
        (fun after ->
          List.iter
            (fun reopen ->
              List.iter
                (fun names ->
                  List.iter
                    (fun (pname, sector) ->
                      let f, died = fs_run reverts !k after in
                      let what =
                        Printf.sprintf "%s, fsync %d fails%s%s, names %s, bytes %s" fsname !k
                          (match after with None -> "" | Some j -> Printf.sprintf ", death at call %d after it" j)
                          (if reopen then ", reopen" else "") (if names then "all" else "none") pname
                      in
                      (* the process ends here (dead at the crash point, or at the end of the run) *)
                      Sim_disk.kill f.fr.sim;
                      let acked = ref f.fr.acked in
                      let first = if reopen then fs_open (what ^ " (first reopen)") f ~acked:!acked ~died else Some 0 in
                      (match first with
                       | Some k1 ->
                         acked := max !acked k1;
                         let choose (d : Sim_disk.draw) n =
                           match d with
                           | Names _ -> if names then n - 1 else 0
                           | Length _ -> if sector = 0 then 0 else 1
                           | Cut _ | Tear _ -> n / 2
                           | Sector (_, s) -> if sector >= 0 then sector else if s mod 2 = 0 then 2 else 0
                         in
                         Sim_disk.crash ~choose f.fr.sim;
                         ignore (fs_open what f ~acked:!acked ~died)
                       | None -> ()))
                    patterns)
                [ true; false ])
            [ true; false ])
        [ None; Some 0; Some 1; Some 2; Some 3 ];
    incr k
  done;
  Journal.segment_limit := 64 * 1024 * 1024;
  Printf.printf "  %s: %d fsyncs failed in turn, %d reopens\n" fsname !k (!fs_states - states0)

let () =
  List.iter enumerate_fsync [ false; true ];
  Printf.printf "exhaustive fsync failures: %d reopens checked, %d false alarms (an unconfirmed frame's header sector lost alone, the process dead before its cut)\n"
    !fs_states !fs_alarms

(* ---- 6. the commit buffer (src/wal.ml, spec/CommitBuffer.tla) ----
   Two databases share a buffer whose files alternate after 500 bytes, their journals' segments 1,500 bytes long. A
   fixed run: rounds of one database and of both, frames forced in their own journal between the buffer's (long ones),
   a segment left, switches of file, a cleaning, a switch over the cleaned file. At every mutating disk call of the
   run: a process death (the page cache kept, then lost at a later power loss), and power losses keeping each prefix
   of each directory's name changes, with the unsynced bytes lost, kept, torn, or kept one sector in two. Recovery
   (the buffer read, both databases opened with its frames, the buffer emptied) must hold every confirmed group of
   each database, exactly the groups written, in order (G1, G2, G3), refuse nothing but the residual of G6 (a frame or
   a round no fsync confirmed, its header's sector lost alone), and what it published must survive a power loss. *)

let bdata = "/data"
let bnames = [| "/data/a"; "/data/b" |]
let buffer_states = ref 0
let buffer_points = ref 0
let buffer_alarms = ref 0

type bdb = {
  be : Engine.t;
  bgroups : (int, Group.t) Hashtbl.t;
  mutable backed : int;
  mutable bprepared : int;
  mutable bwait : (unit, unit) Effect.Deep.continuation option;
  mutable bunsure : bool;  (* a frame written, not confirmed *)
  mutable bstopped : bool;  (* an Io error came: nothing more may be confirmed (G10) *)
}

type brun = { bsim : Sim_disk.t; bdisk : Disk.t; bwal : Wal.t; bdbs : bdb array; mutable runsure : bool }

let bid i = Printf.sprintf "%016d" (i + 1)

let bopen sim disk =
  let wal = Wal.recover ~manual:true disk bdata in
  let es = Array.mapi (fun i d -> Engine.open_ ~id_source:(fun _ -> bid i) ~buffer:(Wal.frames wal) disk d) bnames in
  match Array.to_list es with
  | [ Ok a; Ok b ] ->
    Wal.start wal;
    Wal.attach wal a.id a.journal;
    Wal.attach wal b.id b.journal;
    ignore sim;
    Ok (wal, [| a; b |])
  | l ->
    List.iter (function Ok e -> Engine.close e | Error _ -> ()) l;
    Error (String.concat "; " (List.filter_map (function Error e -> Some (Engine.message e) | Ok _ -> None) l))

let bsetup () =
  let sim = Sim_disk.create (Rng.make 7) in
  let disk = Sim_disk.disk sim in
  disk.mkdir bdata;
  disk.sync_dir "/";
  match bopen sim disk with
  | Error m -> failwith m
  | Ok (wal, es) ->
    let mk (e : Engine.t) =
      { be = e; bgroups = Hashtbl.create 16; backed = e.working.group; bprepared = e.working.group; bwait = None; bunsure = false; bstopped = false }
    in
    { bsim = sim; bdisk = disk; bwal = wal; bdbs = Array.map mk es; runsure = false }

let bresults d res =
  Array.iter
    (function
      | Ok (r : Engine.receipt) ->
        C.check (not d.bstopped) "buffer: group %d confirmed after a failed fsync" r.group;
        d.backed <- max d.backed r.group;
        d.bunsure <- false
      | Error (Engine.Io _) -> d.bstopped <- true
      | Error _ -> ())
    res

let bwrite r i size =
  let d = r.bdbs.(i) in
  let e = d.be in
  let v = e.working in
  let ops =
    match Schema.by_name v.schema "name" with
    | None -> List.map (fun (e, q, x) -> Add (e, q, x)) (Schema.facts Schema.first_prop (prop "name" Ttext))
    | Some p -> [ Add (-1, p, Text (String.make size (Char.chr (97 + i)))) ]
  in
  let b = Engine.prepare e [| ops, 1, "x" |] in
  let body = Buffer.to_bytes b.body in
  let rd = Codec.reader body 0 (Bytes.length body) in
  for _ = 1 to b.count do
    let g = Group.decode rd in
    Hashtbl.replace d.bgroups g.n g;
    d.bprepared <- max d.bprepared g.n
  done;
  d.bunsure <- true;
  match Engine.commit e b with
  | res -> bresults d res
  | effect Wal.Wait, k -> d.bwait <- Some k

let bround r =
  r.runsure <- true;
  Wal.round r.bwal;
  r.runsure <- false;
  Array.iter (fun d -> match d.bwait with Some k -> d.bwait <- None; Effect.Deep.continue k () | None -> ()) r.bdbs

(* the run: W of database i with a text of n bytes (over 600: forced in its own journal), R a round, C a cleaning *)
type bstep = W of int * int | R | C

let brun_steps =
  [ W (0, 10); R; W (0, 20); W (1, 30); R; W (1, 700); W (0, 40); R; W (0, 50); W (1, 60); R; W (1, 70); R; C;
    W (0, 80); W (1, 90); R; W (0, 100); R; W (1, 650); W (0, 110); R ]

let brun r = List.iter (function W (i, n) -> bwrite r i n | R -> bround r | C -> Wal.clean r.bwal) brun_steps

(* recovery: the checks; the groups each database holds now *)
let brecovered what r ~acked =
  incr buffer_states;
  match bopen r.bsim r.bdisk with
  | Error m ->
    let unsure = r.runsure || Array.exists (fun d -> d.bunsure) r.bdbs in
    let has sub = let n = String.length sub and k = String.length m in
      let rec go i = i + n <= k && (String.sub m i n = sub || go (i + 1)) in go 0 in
    if unsure && has "(written whole)" then (incr buffer_alarms; None)
    else (C.fail "%s: recovery failed: %s" what m; None)
  | Ok (wal, es) ->
    let ks =
      Array.mapi
        (fun i (e : Engine.t) ->
          let d = r.bdbs.(i) in
          let k = e.working.group in
          C.check (k >= acked.(i)) "%s: database %d lost confirmed groups: %d, confirmed %d" what i k acked.(i);
          C.check (k <= d.bprepared) "%s: database %d holds %d groups, %d were written" what i k d.bprepared;
          (match
             Journal.read r.bdisk (bnames.(i) ^ "/journal") e.id (fun g ->
                 match Hashtbl.find_opt d.bgroups g.n with
                 | Some g' -> C.check (Group.equal g g') "%s: database %d, group %d differs from what was written" what i g.n
                 | None -> C.check (g.n = 1) "%s: database %d, group %d was never written" what i g.n)
           with
           | () -> ()
           | exception Journal.Damaged m -> C.fail "%s: database %d, journal unreadable after recovery: %s" what i m);
          k)
        es
    in
    Array.iter Engine.close es;
    Wal.stop wal;
    Some ks

let enumerate_buffer () =
  Wal.limit := 500;
  Journal.shared_max := 600;
  (* every frame through the buffer: the run is about its rounds (the frames forced alone are the long ones) *)
  Wal.alone := false;
  Journal.segment_limit := 1500;
  let reach k =
    let r = bsetup () in
    Sim_disk.crash_after r.bsim k;
    match brun r with
    | () -> Sim_disk.crash_after r.bsim (-1); None
    | exception Sim_disk.Crash -> Some (r, Array.map (fun d -> d.backed) r.bdbs)
  in
  let k = ref 0 and go = ref true in
  while !go do
    (match reach !k with
     | None -> go := false
     | Some (r, _) ->
       incr buffer_points;
       let dirs = List.filter (fun d -> Sim_disk.pending_names r.bsim d > 0) (bdata :: List.concat_map (fun n -> [ n; n ^ "/journal" ]) (Array.to_list bnames)) in
       let rec prefixes = function
         | [] -> [ [] ]
         | d :: rest ->
           List.concat_map (fun j -> List.map (fun l -> (d, j) :: l) (prefixes rest)) (List.init (Sim_disk.pending_names r.bsim d + 1) Fun.id)
       in
       let what = Printf.sprintf "buffer, crash at call %d" !k in
       (match reach !k with
        | Some (r, acked) -> (
          Sim_disk.kill r.bsim;
          Sim_disk.crash_after r.bsim (-1);
          match brecovered (what ^ ", process death") r ~acked with
          | Some ks ->
            Sim_disk.crash ~choose:(fun _ _ -> 0) r.bsim;
            Array.iter (fun d -> d.bunsure <- false) r.bdbs;
            r.runsure <- false;
            ignore (brecovered (what ^ ", process death then power loss") r ~acked:ks)
          | None -> ())
        | None -> ());
       List.iter
         (fun prefix ->
           List.iter
             (fun (pname, sector) ->
               match reach !k with
               | Some (r, acked) ->
                 let choose (d : Sim_disk.draw) n =
                   match d with
                   | Names dir -> List.assoc dir prefix
                   | Length _ -> if sector = 0 then 0 else n - 1
                   | Cut _ | Tear _ -> n / 2
                   | Sector (_, s) -> if sector >= 0 then sector else if s mod 2 = 0 then 2 else 0
                 in
                 Sim_disk.crash ~choose r.bsim;
                 Sim_disk.crash_after r.bsim (-1);
                 let names = String.concat "," (List.map (fun (d, j) -> Printf.sprintf "%s:%d" d j) prefix) in
                 ignore (brecovered (Printf.sprintf "%s, names %s, bytes %s" what names pname) r ~acked)
               | None -> C.fail "%s: the crash point moved" what)
             patterns)
         (prefixes dirs));
    incr k
  done;
  (* each fsync of the run failing in turn (a round's, a journal's), the run going on (every later write fails), then
     a process death, or a clean stop (the server's, every database closed), or neither; then, or after a reopen in
     the same boot (which reads the page cache: pages the failed fsync marked clean read as written) and its clean
     stop, a power loss keeping all or none of the unsynced bytes: every group confirmed before the failure is there,
     none after it was confirmed, and what the reopen published survives *)
  let fsyncs = ref 0 and fstates = ref 0 in
  let i = ref 0 and go = ref true in
  while !go do
    List.iter
      (fun (died, reopen, keep) ->
        let r = bsetup () in
        let before = Sim_disk.failures r.bsim in
        Sim_disk.fail_fsync_at r.bsim !i;
        (match brun r with () -> () | exception Sim_disk.Crash -> ());
        Array.iter (fun d -> match d.bwait with Some k -> d.bwait <- None; (try Effect.Deep.continue k () with Sim_disk.Crash -> ()) | None -> ()) r.bdbs;
        if Sim_disk.failures r.bsim = before then go := false
        else begin
          if died then Sim_disk.kill r.bsim
          else if reopen then begin
            Array.iter (fun d -> Engine.close d.be) r.bdbs;
            Wal.stop r.bwal
          end;
          let what = Printf.sprintf "buffer, fsync %d failed%s" !i (if died then ", process death" else if reopen then ", clean stop" else "") in
          let acked = Array.map (fun d -> d.backed) r.bdbs in
          Array.iter (fun d -> d.bunsure <- true) r.bdbs;
          r.runsure <- true;
          let acked =
            if not reopen then Some acked
            else begin
              incr fstates;
              let ks = brecovered (what ^ ", reopened in the same boot") r ~acked in
              Array.iter (fun d -> d.bunsure <- false) r.bdbs;
              r.runsure <- false;
              ks
            end
          in
          match acked with
          | None -> ()
          | Some acked ->
            Sim_disk.crash ~choose:(fun d n -> match d with Sim_disk.Sector _ -> if keep then 2 else 0 | Length _ -> if keep then n - 1 else 0 | _ -> if keep then n - 1 else 0) r.bsim;
            incr fstates;
            ignore (brecovered (Printf.sprintf "%s%s, power loss, %s kept" what (if reopen then ", reopened" else "") (if keep then "all" else "nothing")) r ~acked)
        end)
      [ false, false, true; false, false, false; true, false, true; true, false, false;
        false, true, true; false, true, false; true, true, true; true, true, false ];
    if !go then (incr fsyncs; incr i)
  done;
  Journal.segment_limit := 64 * 1024 * 1024;
  Journal.shared_max := 1 lsl 20;
  Wal.alone := true;
  Wal.limit := 64 * 1024 * 1024;
  Printf.printf "exhaustive commit buffer: %d fsyncs failed in turn, %d states recovered\n" !fsyncs !fstates;
  Printf.printf "exhaustive commit buffer: %d crash points, %d crash states recovered, %d false alarms (an unconfirmed frame or round, its header's sector lost alone)\n"
    !buffer_points !buffer_states !buffer_alarms

let () = enumerate_buffer ()

(* A server opens its databases in parallel domains, each taking its frames from the buffer at its open (Net.
   open_databases): the buffer's table of recovered frames is shared by them. A race there once made a server refuse
   to start after a kill -9, saying that the buffer held writes of databases it did not open, and naming none. Here
   [n] databases each leave one frame in the buffer, a process death, then [k] domains take them at once, released
   together; every database must get its frame, once, and the buffer must start. *)
let parallel_frames () =
  let n = 64 and k = 4 and rounds = 40 in
  Wal.alone := false;
  let names = Array.init n (fun i -> Printf.sprintf "%s/d%02d" bdata i) in
  let fails = ref 0 in
  for round = 1 to rounds do
    let sim = Sim_disk.create (Rng.make round) in
    let disk = Sim_disk.disk sim in
    disk.mkdir bdata;
    disk.sync_dir "/";
    let wal = Wal.recover ~manual:true disk bdata in
    let es = Array.mapi (fun i d -> Result.get_ok (Engine.open_ ~id_source:(fun _ -> bid i) ~buffer:(Wal.frames wal) disk d)) names in
    Wal.start wal;
    Array.iter (fun (e : Engine.t) -> Wal.attach wal e.id e.journal) es;
    let waits : (unit, unit) Effect.Deep.continuation list ref = ref [] in
    Array.iter
      (fun e ->
        let ops = List.map (fun (e, q, x) -> Add (e, q, x)) (Schema.facts Schema.first_prop (prop "name" Ttext)) in
        match Engine.commit e (Engine.prepare e [| ops, 1, "x" |]) with
        | _ -> ()
        | effect Wal.Wait, c -> waits := c :: !waits)
      es;
    Wal.round wal;
    List.iter (fun c -> Effect.Deep.continue c ()) !waits;
    Sim_disk.kill sim;
    let wal = Wal.recover ~manual:true disk bdata in
    let got = Array.make n (-1) and go = Atomic.make false in
    let take j () =
      while not (Atomic.get go) do Domain.cpu_relax () done;
      for i = 0 to n - 1 do if i mod k = j then got.(i) <- List.length (Wal.frames wal (bid i)) done
    in
    let ds = List.init k (fun j -> Domain.spawn (take j)) in
    Atomic.set go true;
    List.iter Domain.join ds;
    let ok_frames = Array.for_all (fun c -> c = 1) got in
    let ok_start = match Wal.start wal with () -> true | exception Journal.Damaged _ -> false in
    if not (ok_frames && ok_start) then incr fails;
    C.check ok_frames "round %d: a database got %d frames from the buffer, not 1" round
      (Array.fold_left (fun a c -> if c <> 1 then c else a) 1 got);
    C.check ok_start "round %d: the buffer refused to start after every database took its frames" round
  done;
  Wal.alone := true;
  Printf.printf "exhaustive commit buffer: %d databases' frames taken by %d domains at once, %d rounds, %d failed\n" n k rounds !fails

let () = parallel_frames ()

let () =
  List.iter crash_states [ [ 10; 20; 30 ]; [ 400; 900; 1500 ]; [ 2000; 100 ] ];
  List.iter flips [ [ 10; 20; 30 ]; [ 400; 900 ] ];
  torn_segment ();
  Printf.printf "exhaustive: %d crash states, %d false alarms (header sector lost alone), %d flips in the newest frame cut as torn\n"
    !states !false_alarms !residual;
  C.finish "exhaustive"
