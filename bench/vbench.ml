(* The vault's measures (docs/book/vault.md, "What it costs"): n runs of each, the median and its 95 % interval by
   order statistics (Stats). Every number beside the file system reading the same bytes.

     vbench.exe putget FILE BYTES RUNS DIR     a file of the first BYTES of FILE put (warm, then cold) into a fresh
                                               vault in DIR and read back whole, each run: MB/s; the same bytes read
                                               from FILE; reads from the page cache, and cold (pages dropped first)
     vbench.exe range FILE BYTES RUNS DIR [SPAN] 4 KiB at random places of that file (of its first SPAN bytes): the
                                               latency of one read from the vault (its pages in the page cache, its
                                               nodes in memory, its chunks in memory once read when SPAN fits the
                                               cache), and of a pread of FILE; each run the median of 1,000 reads
     vbench.exe small FILE RUNS DIR THREADS    400 small files (1 to 16 KiB, each cut from its own place of FILE) put
                                               by THREADS threads at once (a connection each, as in the server) into
                                               a vault in use: files a second (each put waits for its bytes durable)
     vbench.exe space DIR LIST                 every file named in LIST (one path a line) put into a fresh vault in
                                               DIR, warm then cold: the bytes on disk against the bytes of the files

   Cold reads drop the files' pages from the page cache (posix_fadvise DONTNEED, by python3: OCaml's Unix has no
   fadvise) after they are forced; the source file's too. *)

open Cepheus
open Cepheus_vault

let master = String.make 32 'k'
let now = Unix.gettimeofday

let drop files =
  let files = List.filter Sys.file_exists files in
  if files <> [] then
    ignore
      (Sys.command
         ("python3 -I -c 'import os,sys\nfor f in sys.argv[1:]:\n  fd=os.open(f,os.O_RDONLY); os.posix_fadvise(fd,0,0,os.POSIX_FADV_DONTNEED); os.close(fd)' "
         ^ String.concat " " (List.map Filename.quote files)))

let pack_files dir = let p = Filename.concat dir "packs" in if Sys.file_exists p then List.map (Filename.concat p) (Array.to_list (Sys.readdir p)) else []

let read_prefix file n =
  let ic = open_in_bin file in
  let b = Bytes.create n in
  really_input ic b 0 n;
  close_in ic;
  b

let fresh dir = ignore (Sys.command ("rm -rf " ^ Filename.quote dir))

(* a vault opened fresh, with its domain's key made already (a byte put): what a put costs once the vault is in use *)
let fresh_vault dir =
  ignore (Sys.command ("rm -rf " ^ Filename.quote dir));
  let v = Result.get_ok (Vault.open_ Disk.real dir ~master) in
  let w = Result.get_ok (Vault.writer v ~domain:1 ~cold:false) in
  Result.get_ok (Vault.feed w (Bytes.make 1 'x') 0 1);
  ignore (Result.get_ok (Vault.finish w));
  v

let put v (b : Bytes.t) ~cold =
  let w = Result.get_ok (Vault.writer v ~domain:1 ~cold) in
  let piece = 1 lsl 20 in
  let o = ref 0 in
  while !o < Bytes.length b do
    let k = min piece (Bytes.length b - !o) in
    Result.get_ok (Vault.feed w b !o k);
    o := !o + k
  done;
  Result.get_ok (Vault.finish w)

let sink = ref 0
let get v root n = Result.get_ok (Vault.load v root ~from:0 ~len:n (fun b o k -> sink := !sink + Char.code (Bytes.unsafe_get b o) + k))

(* the file read by 1 MiB pieces *)
let fs_read file n =
  let fd = Unix.openfile file [ Unix.O_RDONLY ] 0 in
  let b = Bytes.create (1 lsl 20) in
  let left = ref n in
  while !left > 0 do
    let k = Unix.read fd b 0 (min (1 lsl 20) !left) in
    if k = 0 then left := 0 else (sink := !sink + k; left := !left - k)
  done;
  Unix.close fd

let mbs n t = float n /. t /. 1e6

let print_rate name n ts =
  let s = Stats.summary (Array.map (fun t -> mbs n t) ts) in
  (* a rate's interval: the times' order statistics, inverted *)
  Printf.printf "%-34s median %.0f MB/s, CI [%.0f, %.0f] (%.1f %%), %d runs\n%!" name s.median s.lo s.hi (100. *. s.coverage) s.n

let putget file n runs dir =
  let b = read_prefix file n in
  let tput = Array.make runs 0. and tputc = Array.make runs 0. and tget = Array.make runs 0. and tgetc = Array.make runs 0. in
  let tfs = Array.make runs 0. and tfsc = Array.make runs 0. and tcold_get = Array.make runs 0. and tcold_getc = Array.make runs 0. in
  let tone = Array.make runs 0. in
  let stored = ref 0 and storedc = ref 0 in
  for i = 0 to runs - 1 do
    List.iter
      (fun cold ->
        let v = fresh_vault dir in
        let t0 = now () in
        let root, _ = put v b ~cold in
        let t1 = now () in
        (if cold then tputc else tput).(i) <- t1 -. t0;
        if cold then storedc := Vault.stored v else stored := Vault.stored v;
        let t0 = now () in
        get v root n;
        (if cold then tgetc else tget).(i) <- now () -. t0;
        Vault.close v;
        (* cold: the packs' pages dropped, the vault opened again (its nodes not in memory) *)
        drop (pack_files dir);
        let v = Result.get_ok (Vault.open_ Disk.real dir ~master) in
        let t0 = now () in
        get v root n;
        (if cold then tcold_getc else tcold_get).(i) <- now () -. t0;
        Vault.close v)
      [ false; true ];
    (* the same put on one core: the chunks sealed one after the other *)
    let w = !Vault.workers in
    Vault.workers := 0;
    let v = fresh_vault dir in
    let t0 = now () in
    ignore (put v b ~cold:false);
    tone.(i) <- now () -. t0;
    Vault.close v;
    Vault.workers := w;
    let t0 = now () in
    fs_read file n;
    tfs.(i) <- now () -. t0;
    drop [ file ];
    let t0 = now () in
    fs_read file n;
    tfsc.(i) <- now () -. t0
  done;
  fresh dir;
  Printf.printf "file of %d bytes (%s), %d runs; stored warm %d bytes (%.1f %%), cold %d (%.1f %%)\n" n (Filename.basename file) runs
    !stored (100. *. float !stored /. float n) !storedc (100. *. float !storedc /. float n);
  print_rate (Printf.sprintf "put warm (LZ4), %d workers" !Vault.workers) n tput;
  print_rate "put warm (LZ4), one core" n tone;
  print_rate "put cold (Zstandard 9)" n tputc;
  print_rate "get warm, page cache" n tget;
  print_rate "get warm, cold cache" n tcold_get;
  print_rate "get cold-stored, page cache" n tgetc;
  print_rate "get cold-stored, cold cache" n tcold_getc;
  print_rate "file system read, page cache" n tfs;
  print_rate "file system read, cold cache" n tfsc

(* [span]: the reads fall in the first [span] bytes of the file (the whole of it, or a part the chunk cache holds) *)
let range file n runs dir span =
  let b = read_prefix file n in
  fresh dir;
  let v = Result.get_ok (Vault.open_ Disk.real dir ~master) in
  let root, _ = put v b ~cold:false in
  let n = min n span in
  let r = Random.State.make [| 7 |] in
  let reads = 1000 in
  let lat = Array.make reads 0. in
  let med a = let a = Array.copy a in Array.sort compare a; a.(Array.length a / 2) in
  let p99 a = let a = Array.copy a in Array.sort compare a; a.(Array.length a * 99 / 100) in
  let vault_runs = Array.make runs 0. and fs_runs = Array.make runs 0. and vault_p99 = Array.make runs 0. and fs_p99 = Array.make runs 0. in
  let out = Bytes.create 4096 in
  let fd = Unix.openfile file [ Unix.O_RDONLY ] 0 in
  for i = 0 to runs - 1 do
    for k = 0 to reads - 1 do
      let from = Random.State.int r (n - 4096) in
      let t0 = now () in
      Result.get_ok (Vault.load v root ~from ~len:4096 (fun bb o m -> Bytes.blit bb o out 0 (min m 4096)));
      lat.(k) <- now () -. t0
    done;
    vault_runs.(i) <- med lat;
    vault_p99.(i) <- p99 lat;
    for k = 0 to reads - 1 do
      let from = Random.State.int r (n - 4096) in
      let t0 = now () in
      ignore (Unix.lseek fd from Unix.SEEK_SET);
      ignore (Unix.read fd out 0 4096);
      lat.(k) <- now () -. t0
    done;
    fs_runs.(i) <- med lat;
    fs_p99.(i) <- p99 lat
  done;
  Unix.close fd;
  Vault.close v;
  fresh dir;
  Printf.printf "4 KiB at random places of the first %d bytes of a file, %d runs of %d reads (each run's median and p99)\n" n runs reads;
  Stats.print "vault, median of a run" vault_runs;
  Stats.print "vault, p99 of a run" vault_p99;
  Stats.print "file system pread, median of a run" fs_runs;
  Stats.print "file system pread, p99 of a run" fs_p99

let small file runs dir threads =
  let count = 400 in
  let r = Random.State.make [| 11 |] in
  let ic = open_in_bin file in
  let len = in_channel_length ic in
  let files =
    Array.init count (fun i ->
        let n = 1024 + Random.State.int r (15 * 1024) in
        let b = Bytes.create n in
        seek_in ic (i * (len / count));
        really_input ic b 0 n;
        b)
  in
  close_in ic;
  let bytes = Array.fold_left (fun a b -> a + Bytes.length b) 0 files in
  let rates = Array.make runs 0. in
  for i = 0 to runs - 1 do
    let v = fresh_vault dir in
    let t0 = now () in
    let th =
      List.init threads (fun k ->
          Thread.create
            (fun () ->
              let j = ref k in
              while !j < count do
                ignore (put v files.(!j) ~cold:false);
                j := !j + threads
              done)
            ())
    in
    List.iter Thread.join th;
    rates.(i) <- float count /. (now () -. t0);
    Vault.close v
  done;
  fresh dir;
  let s = Stats.summary rates in
  Printf.printf "%d files of 1-16 KiB (%d bytes), %d threads at once, %d runs: median %.0f files/s, CI [%.0f, %.0f] (%.1f %%), %.2f MB/s\n%!"
    count bytes threads s.n s.median s.lo s.hi (100. *. s.coverage) (s.median *. float bytes /. float count /. 1e6)

let space dir list =
  let files = In_channel.with_open_text list In_channel.input_lines |> List.filter (fun f -> f <> "" && Sys.file_exists f) in
  List.iter
    (fun cold ->
      fresh dir;
      let v = Result.get_ok (Vault.open_ Disk.real dir ~master) in
      let raw = ref 0 in
      let t0 = now () in
      List.iter
        (fun f ->
          match In_channel.with_open_bin f In_channel.input_all with
          | s ->
            raw := !raw + String.length s;
            ignore (put v (Bytes.unsafe_of_string s) ~cold)
          | exception Sys_error _ -> ())
        files;
      let t = now () -. t0 in
      Vault.close v;
      let disk = List.fold_left (fun a f -> a + (Unix.stat f).st_size) 0 (pack_files dir) in
      Printf.printf "%-28s %s: %d files, %d bytes -> %d on disk (%.1f %%), %d reused chunks; %.0f MB/s\n%!" (Filename.basename list)
        (if cold then "cold" else "warm") (List.length files) !raw disk (100. *. float disk /. float !raw) (Vault.reused v) (mbs !raw t))
    [ false; true ];
  fresh dir

let () =
  match Array.to_list Sys.argv with
  | [ _; "putget"; file; n; runs; dir ] -> putget file (int_of_string n) (int_of_string runs) dir
  | [ _; "range"; file; n; runs; dir ] -> range file (int_of_string n) (int_of_string runs) dir max_int
  | [ _; "range"; file; n; runs; dir; span ] -> range file (int_of_string n) (int_of_string runs) dir (int_of_string span)
  | [ _; "small"; file; runs; dir; threads ] -> small file (int_of_string runs) dir (int_of_string threads)
  | [ _; "space"; dir; list ] -> space dir list
  | _ -> prerr_endline "usage: vbench.exe putget|range FILE BYTES RUNS DIR | small FILE RUNS DIR THREADS | space DIR LIST"; exit 2
