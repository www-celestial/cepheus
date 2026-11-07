(* The cache policies on a recorded trace of page reads (bench.exe trace, then bench.exe cachesim): the hit ratio of
   each for a cache of c pages, against Belady's optimum (Belady 1966, "A study of replacement algorithms for a
   virtual-storage computer": evict the page whose next read is the farthest; no policy that does not know the future
   does better). A trace is an array of keys, consecutive repeats of a key removed (a binary search reads one page
   several times in a row: one reference).

     LRU      the least recently read out
     CLOCK    a reference bit and a hand (Corbato 1968): LRU's approximation that needs no list
     2Q       Johnson and Shasha, VLDB 1994 (full version: A1in a FIFO of 25 %, A1out ghosts of 50 %, Am LRU)
     ARC      Megiddo and Modha, FAST 2003 (T1/T2 LRU, ghosts B1/B2, an adaptive target p)
     SIEVE    Zhang et al., NSDI 2024 (a FIFO, a visited bit, a hand that moves towards the head)
     S3-FIFO  Yang et al., SOSP 2023 (small FIFO 10 %, main FIFO with 2-bit counters, ghost FIFO)
     W-TinyLFU Einziger, Friedman and Manes, ACM ToS 2017 (window LRU 1 %, main SLRU 20/80, admission by a 4-bit
              count-min sketch of the recent frequencies, halved every 10 c reads)
     OPT      Belady

   The keys are first renamed 0 .. u-1, so every policy works on arrays. *)

(* in place: a trace of 90 M reads is 730 MB *)
let dense (a : int array) =
  let t = Hashtbl.create 65536 in
  Array.iteri (fun j k -> a.(j) <- (match Hashtbl.find_opt t k with Some i -> i | None -> let i = Hashtbl.length t in Hashtbl.add t k i; i)) a;
  a, Hashtbl.length t

(* doubly linked lists over the ids 0 .. u-1, several lists in one pair of arrays; a list is its sentinel id *)
module L = struct
  type t = { prev : int array; next : int array; mutable len : int array; owner : int array }

  let make u lists =
    let prev = Array.init (u + lists) (fun i -> i) and next = Array.init (u + lists) (fun i -> i) in
    { prev; next; len = Array.make lists 0; owner = Array.make (u + lists) (-1) }

  let sentinel u l = u + l
  let remove t u x = let p = t.prev.(x) and n = t.next.(x) in
    t.next.(p) <- n; t.prev.(n) <- p; t.len.(t.owner.(x)) <- t.len.(t.owner.(x)) - 1; t.owner.(x) <- -1; ignore u
  let push_front t u l x = let s = sentinel u l in let n = t.next.(s) in
    t.next.(s) <- x; t.prev.(x) <- s; t.next.(x) <- n; t.prev.(n) <- x; t.owner.(x) <- l; t.len.(l) <- t.len.(l) + 1
  let back t u l = let s = sentinel u l in t.prev.(s)
  let mem t l x = t.owner.(x) = l
end

let lru tr u c =
  let l = L.make u 1 and hits = ref 0 in
  Array.iter (fun x ->
      if L.mem l 0 x then (incr hits; L.remove l u x)
      else if l.len.(0) >= c then L.remove l u (L.back l u 0);
      L.push_front l u 0 x) tr;
  !hits

let clock tr u c =
  let slot = Array.make c (-1) and where = Array.make u (-1) and refb = Bytes.make c '\000' and hand = ref 0 and n = ref 0 and hits = ref 0 in
  Array.iter (fun x ->
      if where.(x) >= 0 then (incr hits; Bytes.set refb where.(x) '\001')
      else begin
        let s =
          if !n < c then (let s = !n in incr n; s)
          else begin
            while Bytes.get refb !hand = '\001' do Bytes.set refb !hand '\000'; hand := (!hand + 1) mod c done;
            let s = !hand in
            where.(slot.(s)) <- -1;
            hand := (!hand + 1) mod c;
            s
          end
        in
        slot.(s) <- x; where.(x) <- s; Bytes.set refb s '\000'
      end) tr;
  !hits

(* lists: 0 A1in, 1 A1out, 2 Am *)
let twoq tr u c =
  let kin = max 1 (c / 4) and kout = max 1 (c / 2) in
  let l = L.make u 3 and hits = ref 0 in
  let reclaim () =
    if l.len.(0) + l.len.(2) >= c then
      if l.len.(0) > kin || l.len.(2) = 0 then begin
        let y = L.back l u 0 in
        L.remove l u y;
        L.push_front l u 1 y;
        if l.len.(1) > kout then L.remove l u (L.back l u 1)
      end
      else L.remove l u (L.back l u 2)
  in
  Array.iter (fun x ->
      if L.mem l 2 x then (incr hits; L.remove l u x; L.push_front l u 2 x)
      else if L.mem l 0 x then incr hits
      else if L.mem l 1 x then (L.remove l u x; reclaim (); L.push_front l u 2 x)
      else (reclaim (); L.push_front l u 0 x)) tr;
  !hits

(* lists: 0 T1, 1 T2, 2 B1, 3 B2 *)
let arc tr u c =
  let l = L.make u 4 and p = ref 0 and hits = ref 0 in
  let replace in_b2 =
    let t1 = l.len.(0) in
    if t1 > 0 && (t1 > !p || (in_b2 && t1 = !p)) then (let y = L.back l u 0 in L.remove l u y; L.push_front l u 2 y)
    else if l.len.(1) > 0 then (let y = L.back l u 1 in L.remove l u y; L.push_front l u 3 y)
    else (let y = L.back l u 0 in L.remove l u y; L.push_front l u 2 y)
  in
  Array.iter (fun x ->
      if L.mem l 0 x || L.mem l 1 x then (incr hits; L.remove l u x; L.push_front l u 1 x)
      else if L.mem l 2 x then begin
        p := min c (!p + max 1 (l.len.(3) / max 1 l.len.(2)));
        replace false; L.remove l u x; L.push_front l u 1 x
      end
      else if L.mem l 3 x then begin
        p := max 0 (!p - max 1 (l.len.(2) / max 1 l.len.(3)));
        replace true; L.remove l u x; L.push_front l u 1 x
      end
      else begin
        let l1 = l.len.(0) + l.len.(2) in
        if l1 = c then begin
          if l.len.(0) < c then (L.remove l u (L.back l u 2); replace false) else L.remove l u (L.back l u 0)
        end
        else if l1 < c && l.len.(0) + l.len.(1) + l.len.(2) + l.len.(3) >= c then begin
          if l.len.(0) + l.len.(1) + l.len.(2) + l.len.(3) = 2 * c then L.remove l u (L.back l u 3);
          replace false
        end;
        L.push_front l u 0 x
      end) tr;
  !hits

let sieve tr u c =
  let l = L.make u 1 and visited = Bytes.make u '\000' and hand = ref (-1) and hits = ref 0 in
  let s = L.sentinel u 0 in
  Array.iter (fun x ->
      if L.mem l 0 x then (incr hits; Bytes.set visited x '\001')
      else begin
        if l.len.(0) >= c then begin
          let h = ref (if !hand < 0 || not (L.mem l 0 !hand) then L.back l u 0 else !hand) in
          while Bytes.get visited !h = '\001' do
            Bytes.set visited !h '\000';
            h := l.prev.(!h);
            if !h = s then h := L.back l u 0
          done;
          let victim = !h in
          hand := (let p = l.prev.(victim) in if p = s then -1 else p);
          L.remove l u victim
        end;
        L.push_front l u 0 x;
        Bytes.set visited x '\000'
      end) tr;
  !hits

(* lists: 0 small, 1 main, 2 ghost; freq 0..3 *)
let s3fifo tr u c =
  let l = L.make u 3 and freq = Bytes.make u '\000' and hits = ref 0 in
  let cs = max 1 (c / 10) in
  let rec room () =
    if l.len.(0) + l.len.(1) >= c then
      if l.len.(0) >= cs || l.len.(1) = 0 then begin
        let y = L.back l u 0 in
        L.remove l u y;
        if Bytes.get freq y > '\000' then (Bytes.set freq y '\000'; L.push_front l u 1 y; room ())
        else (L.push_front l u 2 y; if l.len.(2) > c then L.remove l u (L.back l u 2))
      end
      else begin
        let y = L.back l u 1 in
        L.remove l u y;
        let f = Char.code (Bytes.get freq y) in
        if f > 0 then (Bytes.set freq y (Char.chr (f - 1)); L.push_front l u 1 y; room ())
      end
  in
  Array.iter (fun x ->
      if L.mem l 0 x || L.mem l 1 x then (incr hits; let f = Char.code (Bytes.get freq x) in if f < 3 then Bytes.set freq x (Char.chr (f + 1)))
      else begin
        let g = L.mem l 2 x in
        if g then L.remove l u x;
        room ();
        Bytes.set freq x '\000';
        L.push_front l u (if g then 1 else 0) x
      end) tr;
  !hits

(* lists: 0 window, 1 probation, 2 protected *)
let wtinylfu tr u c =
  let cw = max 1 (c / 100) in
  let cm = max 1 (c - cw) in
  let cprot = cm * 8 / 10 in
  let l = L.make u 3 and hits = ref 0 in
  let width = 1 lsl (max 4 (int_of_float (Float.log2 (float (4 * c))) + 1)) in
  let sk = Array.make_matrix 4 width 0 and seen = ref 0 and sample = 10 * c in
  let h i x = ((x * (0x9E3779B1 + (i * 0x85EBCA77))) lsr 7) land (width - 1) in
  let add x =
    for i = 0 to 3 do let j = h i x in if sk.(i).(j) < 15 then sk.(i).(j) <- sk.(i).(j) + 1 done;
    incr seen;
    if !seen >= sample then (seen := 0; Array.iter (fun r -> Array.iteri (fun j v -> r.(j) <- v / 2) r) sk)
  in
  let est x = let m = ref 15 in for i = 0 to 3 do m := min !m sk.(i).(h i x) done; !m in
  Array.iter (fun x ->
      add x;
      if L.mem l 0 x then (incr hits; L.remove l u x; L.push_front l u 0 x)
      else if L.mem l 1 x then begin
        incr hits; L.remove l u x; L.push_front l u 2 x;
        if l.len.(2) > cprot then (let y = L.back l u 2 in L.remove l u y; L.push_front l u 1 y)
      end
      else if L.mem l 2 x then (incr hits; L.remove l u x; L.push_front l u 2 x)
      else begin
        L.push_front l u 0 x;
        if l.len.(0) > cw then begin
          let cand = L.back l u 0 in
          L.remove l u cand;
          if l.len.(1) + l.len.(2) < cm then L.push_front l u 1 cand
          else begin
            let victim = if l.len.(1) > 0 then L.back l u 1 else L.back l u 2 in
            if est cand > est victim then (L.remove l u victim; L.push_front l u 1 cand)
          end
        end
      end) tr;
  !hits

(* Belady: the resident pages in a max-heap by their next read (an indexed heap: a page's place is known, so a hit
   moves it), O(log c) a read and O(c) memory; a page read again later than every resident one is not kept *)
let opt tr u c =
  let n = Array.length tr in
  (* the next read of each read, in 32 bits (a trace has fewer than 2^31 reads); never again: n *)
  let next = Bigarray.Array1.create Bigarray.int32 Bigarray.c_layout n and last = Array.make u n in
  for i = n - 1 downto 0 do Bigarray.Array1.unsafe_set next i (Int32.of_int last.(tr.(i))); last.(tr.(i)) <- i done;
  let h = Array.make (c + 1) 0 and pos = Array.make u (-1) and key = Array.make u 0 and hn = ref 0 in
  let set i x = h.(i) <- x; pos.(x) <- i in
  let rec up i = if i > 0 then let p = (i - 1) / 2 in if key.(h.(p)) < key.(h.(i)) then (let a = h.(p) in set p h.(i); set i a; up p) in
  let rec down i =
    let l = (2 * i) + 1 and r = (2 * i) + 2 in
    let m = ref i in
    if l < !hn && key.(h.(l)) > key.(h.(!m)) then m := l;
    if r < !hn && key.(h.(r)) > key.(h.(!m)) then m := r;
    if !m <> i then (let a = h.(!m) in set !m h.(i); set i a; down !m)
  in
  let hits = ref 0 in
  for i = 0 to n - 1 do
    let x = tr.(i) and nx = Int32.to_int (Bigarray.Array1.unsafe_get next i) in
    if pos.(x) >= 0 then (incr hits; key.(x) <- nx; up pos.(x))
    else if !hn < c then (key.(x) <- nx; set !hn x; incr hn; up (!hn - 1))
    else if nx < key.(h.(0)) then begin
      pos.(h.(0)) <- -1;
      key.(x) <- nx;
      set 0 x;
      down 0
    end
  done;
  !hits

let policies = [ "LRU", lru; "CLOCK", clock; "2Q", twoq; "ARC", arc; "SIEVE", sieve; "S3-FIFO", s3fifo; "W-TinyLFU", wtinylfu; "OPT", opt ]

let run name trace sizes =
  let tr, u = dense trace in
  Printf.printf "%s: %d reads, %d distinct pages (%.0f MB)\n%!" name (Array.length tr) u (float u *. 16384. /. 1e6);
  Printf.printf "%-10s" "pages";
  List.iter (fun (p, _) -> Printf.printf "%10s" p) policies;
  print_newline ();
  List.iter (fun frac ->
      let c = max 16 (int_of_float (frac *. float u)) in
      Printf.printf "%5.0f %% %4d" (frac *. 100.) c;
      List.iter (fun (_, f) -> Printf.printf "%9.2f%%%!" (100. *. float (f tr u c) /. float (Array.length tr))) policies;
      print_newline ()) sizes
