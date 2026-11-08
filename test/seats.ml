(* Never sell the same seat twice (docs/case-seats.md). Real kill -9 in the middle of a sale of seats, then a check of
   the whole history.

   A child process sells the seats of a hall to buyers in 16 threads. A buyer takes a view, picks one of the ten best
   seats still free in it, and writes the sale as one group: the seat's owner and the buyer's charge (a new thing with
   the seat, the buyer and the price), with [Expect (seat, owner, None)] unless the sale is naive; the group's [why]
   says who bought what, and the group of the view it read. The child prints each confirmation. The parent kills it at
   a random moment, reopens the database (recovery), and starts the next child on what is left, until every seat is
   sold. Then it checks:
   - durable: every confirmed sale is in the journal, as written, and in the final state (G1, G2);
   - the property: at most one charge a seat, and every charge's buyer owns the seat;
   - serializable, in the spirit of Elle (Kingsbury and Alvaro, VLDB 2020): from the journal alone, the dependency
     graph of the sales (Adya 1999) on each seat, a register whose versions are its owners in group order: ww (a sale
     replaced the owner another sale wrote), wr (a sale read the owner another wrote), rw (a sale read a version that
     another sale replaced). A cycle is an anomaly no serial order explains: every ww and wr edge goes forward in
     group order, so a cycle has an rw edge (Adya's G2), here a lost update.
   Usage: seats.exe DIR ROUNDS [SEED] [naive] [SEATS]. With naive, the anomalies are counted and printed: the checker
   is shown to see them. *)

open Cepheus
module C = Check

let buyers = match Sys.getenv_opt "BUYERS" with Some b -> int_of_string b | None -> 16

type schema = { owner : int; seat_no : int; sale_seat : int; sale_buyer : int; price : int }

let schema db =
  match
    declare db
      [ prop "seat/number" Tint; prop "seat/owner" Tint; prop "sale/seat" Tlink; prop "sale/buyer" Tint; prop "sale/price" (Tmoney 2) ]
  with
  | Ok [ seat_no; owner; sale_seat; sale_buyer; price ] -> { owner; seat_no; sale_seat; sale_buyer; price }
  | Ok _ -> assert false
  | Error e -> prerr_endline (message e); exit 2

(* the hall, made once: seat k (1 .. n) is a thing with its number *)
let hall db s n =
  let v = view db in
  if things v s.seat_no (Int 1) = [] then
    ignore (Result.get_ok (write db ~why:"hall" (List.init n (fun k -> Add (-(k + 1), s.seat_no, Int (k + 1))))));
  let v = view db in
  Array.init n (fun k -> match things v s.seat_no (Int (k + 1)) with [ e ] -> e | _ -> failwith "hall")

(* one of the ten best free seats of view v, or None when the view shows the hall sold out *)
let pick r v s seats =
  let free = ref [] and k = ref 0 in
  Array.iter (fun e -> if !k < 10 && values v e s.owner = [] then (free := e :: !free; incr k)) seats;
  match !free with [] -> None | l -> Some (List.nth l (Rng.int r (List.length l)))

let sale ~naive s b seat v =
  (if naive then [] else [ Expect (seat, s.owner, None) ])
  @ [ Add (seat, s.owner, Int b); Add (-1, s.sale_seat, Link seat); Add (-1, s.sale_buyer, Int b); Add (-1, s.price, Money 4500) ]
  |> fun ops -> ops, Printf.sprintf "sale %d %d %d" b seat (group v)

let child dir naive nseats seed =
  let db = match open_ dir with Ok db -> db | Error e -> prerr_endline (message e); exit 2 in
  let s = schema db in
  let seats = hall db s nseats in
  let m = Mutex.create () in
  let conflicts = Atomic.make 0 in
  let t0 = Unix.gettimeofday () in
  let run b =
    let r = Rng.make ((seed * 1000) + b) in
    let go = ref true in
    while !go do
      let v = view db in
      match pick r v s seats with
      | None -> go := false
      | Some seat -> (
        let ops, why = sale ~naive s b seat v in
        match write db ~by:b ~why ops with
        | Ok g ->
          Mutex.lock m;
          Printf.printf "ok %d %d %d\n%!" g.group b seat;
          Mutex.unlock m
        | Error (Conflict _) -> Atomic.incr conflicts
        | Error e -> prerr_endline (message e); exit 3)
    done
  in
  let ts = List.init buyers (fun b -> Thread.create run (b + 1)) in
  List.iter Thread.join ts;
  (* sold out: the time from the first look to the last sale, and the sales refused by an Expect *)
  Printf.printf "end %.6f %d\n%!" (Unix.gettimeofday () -. t0) (Atomic.get conflicts);
  close db

(* ---- the check of the history ---- *)

type sold = { n : int; buyer : int; seat : int; read : int }

(* the sales of the journal, in group order, from their [why] *)
let history dir =
  let id = Engine.read_meta Disk.real dir in
  let out = ref [] in
  Journal.read Disk.real (Filename.concat dir "journal") id (fun (g : Group.t) ->
      match Scanf.sscanf_opt g.why "sale %d %d %d" (fun b s v -> b, s, v) with
      | Some (buyer, seat, read) -> out := { n = g.n; buyer; seat; read } :: !out
      | None -> ());
  List.rev !out

(* Per seat, the versions of its owner are the sales that wrote it, in group order. A sale read the version of the
   last writer at or before the group of its view (none: the seat was free). Edges: ww from each writer to the next;
   wr from the writer of the version a sale read to the sale; rw from a sale to the writer of the version after the
   one it read, when that is another sale. Every edge stays among the sales of one seat, so a cycle is looked for seat
   by seat. *)
let anomalies sales =
  let by_seat = Hashtbl.create 1024 in
  List.iter (fun x -> Hashtbl.replace by_seat x.seat (x :: Option.value (Hashtbl.find_opt by_seat x.seat) ~default:[])) sales;
  let cyclic = ref 0 in
  Hashtbl.iter
    (fun _ l ->
      let w = Array.of_list (List.sort (fun a b -> compare a.n b.n) l) in
      let k = Array.length w in
      (* index of the version a sale read: the last writer with n <= read, or -1 *)
      let version x = let j = ref (-1) in Array.iteri (fun i y -> if y.n <= x.read then j := i) w; !j in
      let edges = Array.make k [] in
      let add a b rw = edges.(a) <- (b, rw) :: edges.(a) in
      for i = 0 to k - 2 do add i (i + 1) false done;
      Array.iteri
        (fun i x ->
          let v = version x in
          if v >= 0 && v <> i then add v i false;
          let next = v + 1 in
          if next < k && next <> i then add i next true)
        w;
      (* a cycle, by Kahn's algorithm (the sales left when no edge-free sale remains); ww and wr edges go forward in
         group order, so a cycle has an rw edge going back: a sale that read a version older than the one it replaced *)
      let indeg = Array.make k 0 in
      Array.iter (List.iter (fun (b, _) -> indeg.(b) <- indeg.(b) + 1)) edges;
      let q = Queue.create () and seen = ref 0 in
      Array.iteri (fun i d -> if d = 0 then Queue.add i q) indeg;
      while not (Queue.is_empty q) do
        let a = Queue.pop q in
        incr seen;
        List.iter (fun (b, _) -> indeg.(b) <- indeg.(b) - 1; if indeg.(b) = 0 then Queue.add b q) edges.(a)
      done;
      if !seen < k then incr cyclic)
    by_seat;
  !cyclic

let parent dir rounds seed naive nseats =
  let r = Rng.make seed in
  let acks = ref [] and kills = ref 0 and last = ref (0., 0) in
  let round_ = ref 0 and sold_out = ref false in
  while not !sold_out do
    incr round_;
    let rd, wr = Unix.pipe ~cloexec:true () in
    let args = [| Sys.executable_name; "--child"; dir; (if naive then "naive" else "expect"); string_of_int nseats; string_of_int ((seed * 1000) + !round_) |] in
    let pid = Unix.create_process Sys.executable_name args Unix.stdin wr Unix.stderr in
    Unix.close wr;
    let ic = Unix.in_channel_of_descr rd in
    let reader =
      Thread.create
        (fun () ->
          try
            while true do
              let l = input_line ic in
              if String.length l > 3 && String.sub l 0 3 = "end" then Scanf.sscanf l "end %f %d" (fun t c -> last := (t, c))
              else Scanf.sscanf l "ok %d %d %d" (fun g b s -> acks := (g, b, s) :: !acks)
            done
          with End_of_file -> ())
        ()
    in
    (* the first rounds are killed at a random moment; the last one sells out *)
    if !round_ <= rounds then begin
      let until = Unix.gettimeofday () +. 0.02 +. (float_of_int (Rng.int r 300) /. 1000.) in
      let ended = ref false in
      while (not !ended) && Unix.gettimeofday () < until do
        (match Unix.waitpid [ Unix.WNOHANG ] pid with 0, _ -> Thread.delay 0.002 | _ -> ended := true)
      done;
      if not !ended then begin
        Unix.kill pid Sys.sigkill;
        ignore (Unix.waitpid [] pid);
        incr kills
      end
      else sold_out := true
    end
    else begin
      ignore (Unix.waitpid [] pid);
      sold_out := true
    end;
    Thread.join reader;
    close_in ic
  done;
  (* the final state, then the history, read from the closed database *)
  let db = match open_ dir with Ok db -> db | Error e -> C.fail "recovery failed: %s" (message e); exit 1 in
  let s = schema db in
  let v = view db in
  let seats = hall db s nseats in
  close db;
  let sales = history dir in
  let in_journal = Hashtbl.create 4096 in
  List.iter (fun x -> Hashtbl.replace in_journal x.n x) sales;
  List.iter
    (fun (g, b, seat) ->
      (match Hashtbl.find_opt in_journal g with
       | Some x -> C.check (x.buyer = b && x.seat = seat) "confirmed sale of group %d is another in the journal" g
       | None -> C.fail "confirmed sale of group %d (buyer %d, seat %d) is not in the journal" g b seat);
      if not naive then C.check (values v seat s.owner = [ Int b ]) "confirmed sale of group %d: seat %d is not its buyer's" g seat)
    !acks;
  let double = ref 0 and extra = ref 0 and unpaid = ref 0 and unsold = ref 0 in
  Array.iter
    (fun seat ->
      let charges = things v s.sale_seat (Link seat) in
      if List.length charges > 1 then (incr double; extra := !extra + List.length charges - 1);
      (match values v seat s.owner with [] -> incr unsold | _ -> ());
      List.iter (fun c -> if values v c s.sale_buyer <> values v seat s.owner then incr unpaid) charges)
    seats;
  let cyclic = anomalies sales in
  let t, c = !last in
  Printf.printf "seats (%s, %d buyers): %d seats, %d kills, %d sales in the journal (%d confirmed), %d unsold, %d seats sold more than once (%d sales too many), %d charged without the seat, %d seats with a cycle in the history\n"
    (if naive then "naive" else "expect") buyers nseats !kills (List.length sales) (List.length !acks) !unsold !double !extra !unpaid cyclic;
  if !kills = 0 then Printf.printf "  sold out in %.3f s (%.0f sales/s), %d sales refused by an Expect\n" t (float nseats /. t) c;
  if not naive then begin
    C.check (!double = 0) "a seat was sold twice";
    C.check (!unpaid = 0) "a buyer was charged for a seat they do not have";
    C.check (cyclic = 0) "the history has a cycle";
    C.check (!unsold = 0) "a seat is left unsold"
  end;
  C.finish "seats"

let () =
  match Sys.argv with
  | [| _; "--child"; dir; mode; n; seed |] -> child dir (mode = "naive") (int_of_string n) (int_of_string seed)
  | [| _; dir; rounds |] -> parent dir (int_of_string rounds) 42 false 2000
  | [| _; dir; rounds; seed |] -> parent dir (int_of_string rounds) (int_of_string seed) false 2000
  | [| _; dir; rounds; seed; mode |] -> parent dir (int_of_string rounds) (int_of_string seed) (mode = "naive") 2000
  | [| _; dir; rounds; seed; mode; n |] -> parent dir (int_of_string rounds) (int_of_string seed) (mode = "naive") (int_of_string n)
  | _ -> prerr_endline "seats.exe DIR ROUNDS [SEED] [naive|expect] [SEATS]"; exit 2
