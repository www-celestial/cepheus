(* What the server does with a failure it did not expect (a bug, a resource that ran out): each place that serves a
   peer ends there (Core.input for a request, Core's write replies and pushes, Net for a connection's own threads, Live
   for a watched question at a frame), and this writes it on the standard error, one line, never to the peer.

   The line holds the exception's text, which may hold a client's bytes (a value, a name): it is cut to [max_text]
   bytes and every byte outside printable ASCII is written \ddd (a newline \010, an escape character \027), so that no
   client makes a line of its own or speaks to the terminal that shows the log. A client that makes failures in a loop
   (each costs it its connection) writes at most one line a second: the next one counts those left out. Writing the
   line never raises: a log that cannot be written (memory that ran out again) is left out.

   Out_of_memory and Stack_overflow end where the others do, and the server goes on. OCaml raises Out_of_memory when
   one allocation cannot be had (on Linux: a size past what the machine could ever give, a request's own), the heap
   still sound; a machine truly out of memory has the process killed by the kernel instead, and systemd starts it
   again (recovery decides, G10). OCaml 5 raises Stack_overflow at the limit of a thread's stack, which is then
   unwound: the thread and the server go on. *)

let max_text = 300

let escape s =
  let b = Buffer.create (String.length s + 16) in
  String.iter (fun ch -> if ch >= ' ' && ch <= '~' then Buffer.add_char b ch else Printf.bprintf b "\\%03d" (Char.code ch)) s;
  Buffer.contents b

(* [what] failed with [e]: [what] names the place (numbers and escaped names only) *)
let line what e =
  let s = Printexc.to_string e in
  Printf.sprintf "cepheus: %s failed: %s" what (escape (if String.length s > max_text then String.sub s 0 max_text ^ "..." else s))

let m = Mutex.create ()
let last = ref neg_infinity
let left_out = ref 0

let log what e =
  try
    let now = Unix.gettimeofday () in
    let n =
      Mutex.protect m (fun () ->
          if now -. !last < 1.0 then (incr left_out; None)
          else begin
            let n = !left_out in
            last := now;
            left_out := 0;
            Some n
          end)
    in
    match n with
    | None -> ()
    | Some n -> prerr_endline (line what e ^ if n > 0 then Printf.sprintf " (and %d failures since the line before, not written)" n else "")
  with _ -> ()
