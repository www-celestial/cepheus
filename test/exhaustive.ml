(* Exhaustive enumeration, in the spirit of ALICE (Pillai et al., OSDI 2014) pushed to every case on small journals:
   1. after m durable frames, every state a crash can leave of frame m+1 (each subset of its sectors reached the disk,
      each cut length, each sector torn inside) must recover to exactly m or m+1 groups, never lose one;
   2. every single bit flipped anywhere in the durable journal is detected by a full read, and recovery either
      refuses, or keeps every group (a flipped trailer, rebuilt), or is the documented residual (a flip in the newest
      frame, cut as torn: docs/guarantees.md, G6);
   3. a segment whose creation was torn at any byte is dropped, and the journal continues. *)

open Cepheus
module C = Check

let id = "0123456789abcdef"
let sector = Sim_disk.sector

let group n text =
  { Group.n; time = n; by = 1; why = "x"; first_new = 65536 + n; count_new = 1;
    changes = [| { Group.add = true; e = 65536 + n; p = 16; v = Value.Text text } |] }

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
  match Journal.recover disk "/j" id None (fun g -> got := g.n :: !got) with
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
              let whole = Bytes.length b >= hi && Bytes.sub b lo (hi - lo) = Bytes.sub full lo (hi - lo) in
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
    match Journal.recover disk "/j" id None (fun _ -> incr n) with
    | j ->
      C.check (!n = 4 && Journal.next_group j = 5) "torn segment header at %d: %d groups" k !n;
      Journal.close j
    | exception Journal.Damaged m -> C.fail "torn segment header at %d: %s" k m
  done

let () =
  List.iter crash_states [ [ 10; 20; 30 ]; [ 400; 900; 1500 ]; [ 2000; 100 ] ];
  List.iter flips [ [ 10; 20; 30 ]; [ 400; 900 ] ];
  torn_segment ();
  Printf.printf "exhaustive: %d crash states, %d false alarms (header sector lost alone), %d flips in the newest frame cut as torn\n"
    !states !false_alarms !residual;
  C.finish "exhaustive"
