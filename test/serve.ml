(* The servers a test starts (`cepheus serve`), so that none outlives the test: each runs in a session of its own
   (setsid), its output goes to serve.log beside its cluster.toml (never the test's: a server left behind must not hold
   the pipe that tools/test.sh reads), and every server not yet waited for is stopped when the test ends, even when it
   fails (at_exit: SIGTERM, then SIGKILL after 10 s). The test ignores SIGPIPE: a raw write to a connection the server
   closed is then an EPIPE, not the death of the test, which would leave its server. *)

let started : int list ref = ref []

let start bin cfg =
  let log = Unix.openfile (Filename.concat (Filename.dirname cfg) "serve.log") [ O_WRONLY; O_CREAT; O_APPEND; O_CLOEXEC ] 0o644 in
  let null = Unix.openfile "/dev/null" [ O_RDONLY; O_CLOEXEC ] 0 in
  let pid =
    Fun.protect ~finally:(fun () -> Unix.close log; Unix.close null) (fun () ->
        Unix.create_process "setsid" [| "setsid"; bin; "serve"; "--config"; cfg |] null log log)
  in
  started := pid :: !started;
  pid

(* the server's end, once it was killed or stopped *)
let wait pid =
  let r = Unix.waitpid [] pid in
  started := List.filter (( <> ) pid) !started;
  r

let () =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  at_exit (fun () ->
      List.iter (fun pid -> try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ()) !started;
      let deadline = Unix.gettimeofday () +. 10. in
      List.iter
        (fun pid ->
          let rec go () =
            match Unix.waitpid [ Unix.WNOHANG ] pid with
            | 0, _ when Unix.gettimeofday () < deadline -> Unix.sleepf 0.01; go ()
            | 0, _ -> (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ()); ignore (Unix.waitpid [] pid)
            | _ -> ()
            | exception Unix.Unix_error _ -> ()
          in
          go ())
        !started;
      started := [])
