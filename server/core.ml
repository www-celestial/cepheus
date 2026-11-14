(* The server's core: what a request does, with no socket and no thread of its own. The transport (Net: threads and
   sockets; the simulation: a seeded scheduler) hands it each complete frame of a connection and gives it a way to
   send; writes go to each database's writer through [submit] and are answered when their group is durable. So the
   real server and the simulation run the same code from the frame to the reply.

   Rights (G16): every request is checked against its token's rights for the database it names, at every request (a
   token removed from tokens.toml, or whose rights change, takes effect at the next request). *)

open Cepheus
module Ask = Question.Ask

type db = {
  name : string;
  index : int;
  dir : string;
  view : unit -> Store.view;  (* the newest durable state, as reads see it *)
  sessions : Sessions.t;
  more : unit -> (string * string) list;  (* the transport's lines for status (its local readers) *)
  hub : unit -> Live.hub;  (* its live questions, made at the first Watch *)
  files : Files.cell;  (* its vault, opened at the first file *)
}

type t = {
  server_id : string;
  cluster_id : string;
  dbs : db array;
  by_name : (string, db) Hashtbl.t;
  tokens : Tokens.t Atomic.t;
  stopping : bool Atomic.t;
  now : unit -> int;  (* ms *)
  new_session : unit -> int;
  max_inflight : int;
  more : unit -> (string * string) list;  (* server-wide lines of the status (the commit buffer's) *)
  started : int;
  served : int Atomic.t;  (* requests of closed connections *)
  conns : (int, conn) Hashtbl.t;  (* open connections, for status and stop *)
  cm : Mutex.t;
  mutable next_conn : int;
}

and conn = {
  srv : t;
  cid : int;
  mutable token : Tokens.token option;
  mutable seen : Tokens.t;  (* the token table the rights below come from *)
  mutable rights : Tokens.right option array;  (* by database index *)
  mutable kinds : (Schema.t * Bytes.t) option array;  (* a token's rights per kind, by property, by database index *)
  mutable session : int;
  om : Mutex.t;  (* the output and the writes in flight *)
  oc : Condition.t;  (* signalled when a write in flight ends *)
  out : Buffer.t;  (* replies not yet sent *)
  body : Buffer.t;  (* scratch: the body of the reply being coded (the reading thread only) *)
  scratch : Buffer.t;  (* scratch of the reading thread *)
  wbody : Buffer.t;  (* scratch of the write replies (under om) *)
  mutable inflight : int;  (* writes sent to a writer, not yet answered *)
  mutable requests : int;
  flush : unit -> unit;  (* sends what [out] holds; may block (the kernel's buffers are full) *)
  submit : db -> Resolve.op list -> int -> string -> ((Engine.receipt, Engine.error) result -> unit) -> unit;
      (* to the database's writer, in the order of the calls; the function is called once with the outcome, after the
         group is durable *)
  pm : Mutex.t;  (* the pushes *)
  pushes : Buffer.t;  (* the watches' messages, coded, not yet given to the output *)
  mutable watching : (int * (Live.hub * Live.sub)) list;  (* by the id of the Watch *)
  mutable closed : bool;  (* pushes are dropped *)
  wake : unit -> unit;  (* the transport sends what [pushes] holds (it must not wait) *)
  close : unit -> unit;
      (* the transport ends the connection, from any of its threads or a hub's, without waiting: its reading wakes
         and its end runs ([ending]); called only before that end (by [broke]) *)
  failed : bool Atomic.t;  (* a thread other than the reading one failed: said at the end *)
  puts : (int, db * Files.put) Hashtbl.t;  (* the files being put, by the id of their Put (the reading thread only) *)
}

let create ~server_id ~cluster_id ~dbs ~tokens ~now ~new_session ?(max_inflight = 1024) ?(more = fun () -> []) () =
  let by_name = Hashtbl.create 8 in
  Array.iter (fun d -> Hashtbl.replace by_name d.name d) dbs;
  { server_id; cluster_id; dbs; by_name; tokens = Atomic.make tokens; stopping = Atomic.make false; now; new_session;
    max_inflight; more; started = now (); served = Atomic.make 0; conns = Hashtbl.create 64; cm = Mutex.create (); next_conn = 1 }

let connect ?(wake = ignore) ?(close = ignore) srv ~flush ~submit =
  Mutex.protect srv.cm (fun () ->
      let cid = srv.next_conn in
      srv.next_conn <- cid + 1;
      let c =
        { srv; cid; token = None; seen = Tokens.empty; rights = [||]; kinds = [||]; session = 0; om = Mutex.create (); oc = Condition.create ();
          out = Buffer.create 4096; body = Buffer.create 4096; scratch = Buffer.create 1024; wbody = Buffer.create 256;
          inflight = 0; requests = 0; flush; submit; pm = Mutex.create (); pushes = Buffer.create 256; watching = [];
          closed = false; wake; close; failed = Atomic.make false; puts = Hashtbl.create 2 }
      in
      Hashtbl.replace srv.conns cid c;
      c)

let disconnect c =
  let ws = Mutex.protect c.pm (fun () -> c.closed <- true; Buffer.reset c.pushes; let l = c.watching in c.watching <- []; l) in
  List.iter (fun (_, (h, s)) -> Live.unsubscribe h s) ws;
  (* the files not finished are dropped: their chunks stored already are cited by no fact *)
  Hashtbl.reset c.puts;
  Mutex.protect c.srv.cm (fun () ->
      Hashtbl.remove c.srv.conns c.cid;
      ignore (Atomic.fetch_and_add c.srv.served c.requests))

(* ---- replies ---- *)

let send_body c ~id ~kind ~flags body = Mutex.protect c.om (fun () -> Wire.add_frame c.out ~id ~kind ~flags body)

let reply c ~id ~kind r =
  Buffer.clear c.body;
  Wire.put_reply c.body r;
  let flags = match r with Wire.Err _ -> Wire.f_error | _ -> 0 in
  send_body c ~id ~kind ~flags c.body

let err c ~id ~kind code fmt = Printf.ksprintf (fun message -> reply c ~id ~kind (Wire.Err { code; message })) fmt

let engine_err c ~id ~kind e = let code, message = Wire.code_of_error e in reply c ~id ~kind (Wire.Err { code; message })

(* What a connection did not expect (a bug, memory that ran out) ends at one place in each thread that serves it: a
   request in [input], a write's reply in [write], a push in [watch], the transport's own loops. Written in the
   server's log (Fault: escaped, at most a line a second); the peer gets the code internal and nothing more (no
   exception, path or state of the server crosses the wire), on the request's id or on id 0 (the connection's); then
   the connection closes, which lets go of what it held: its writes in flight answered first, its watches and its
   unfinished files dropped, its threads ended. *)
let culprit c ~id ~kind =
  let tok = match c.token with Some t -> Fault.escape t.name | None -> "none" in
  if id = 0 then Printf.sprintf "connection %d (token %s)" c.cid tok else Printf.sprintf "connection %d (token %s), request %d of kind %d" c.cid tok id kind

let internal c ~id ~kind =
  (* when even this cannot be coded (memory), the connection closes without a word *)
  try err c ~id ~kind "internal" "the server failed (its log says why): the connection is closed" with _ -> ()

(* in the reading thread *)
let fail c ~id ~kind e = Fault.log (culprit c ~id ~kind) e; internal c ~id ~kind

(* in another thread (a write's reply, a push, the hub's): it never waits for the connection (whose reading thread may
   hold the output, sending to a slow program); the word is said at the end, by the reading thread *)
let broke c e = Fault.log (culprit c ~id:0 ~kind:0) e; Atomic.set c.failed true; c.close ()

(* the connection's end, in its reading thread, once its other threads have ended: the word a failure of one of them
   left *)
let ending c = if Atomic.get c.failed then internal c ~id:0 ~kind:0

(* ---- rights ---- *)

let refresh_rights c =
  let cur = Atomic.get c.srv.tokens in
  if cur != c.seen then begin
    c.seen <- cur;
    match c.token with
    | None -> ()
    | Some tok -> (
      match List.find_opt (fun (t : Tokens.token) -> t.name = tok.name && Tokens.equal_ct t.hash tok.hash) cur.tokens with
      | None -> c.token <- None; c.rights <- [||]
      | Some t ->
        c.token <- Some t;
        c.rights <- Array.map (fun d -> Tokens.right t d.name) c.srv.dbs;
        c.kinds <- Array.make (Array.length c.srv.dbs) None)
  end

let db_of c ~id ~kind i =
  if i < 0 || i >= Array.length c.srv.dbs then (err c ~id ~kind "unknown_database" "no database %d on this server" i; None)
  else Some c.srv.dbs.(i)

let readable c ~id ~kind i =
  match db_of c ~id ~kind i with
  | None -> None
  | Some d -> if c.rights.(i) <> None then Some d else (err c ~id ~kind "denied" "this token may not read %s" d.name; None)

let writable c ~id ~kind i =
  match db_of c ~id ~kind i with
  | None -> None
  | Some d -> (
    match c.rights.(i) with
    | Some (Tokens.Write | Tokens.Kinds { add = _ :: _; _ }) -> Some d
    | _ -> err c ~id ~kind "denied" "this token may not write %s" d.name; None)

(* ---- rights per kind ---- *)

(* May a token with rights per kind read property p: it reads p's kind, and every kind the derived facts of p can come
   from through the rules (Reason.sources; any kind, for a rule over a variable property), so that a derived fact
   tells it nothing of the facts it may not read. *)
let reads_prop (v : Store.view) r p =
  (Schema.is_system p && p <> Schema.p_same)
  ||
  (* cepheus/same: the classes the rules make, read as any derived fact: by its sources (Reason.sources) *)
  match Schema.find v.schema p with
  | None -> false
  | Some d ->
    let reads q = Schema.is_system q || match Schema.find v.schema q with Some dq -> Tokens.reads_kind r (Tokens.kind_of dq.name) | None -> true in
    (p = Schema.p_same || Tokens.reads_kind r (Tokens.kind_of d.name))
    &&
    match Reason.sources v p with
    | Some qs -> List.for_all reads qs
    | None -> let ok = ref true in for q = 0 to Schema.count v.schema - 1 do if Schema.find v.schema q <> None && not (reads q) then ok := false done; !ok

(* For a token with rights per kind, a byte a property of the schema: 1 it may read it, 2 add to it; made again only
   when the schema changes (its rules with it), so that a check costs a load a fact. *)
let kinds_table c i (v : Store.view) r =
  match c.kinds.(i) with
  | Some (s, t) when s == v.schema -> t
  | _ ->
    let t = Bytes.make (Schema.count v.schema) '\000' in
    for p = 0 to Bytes.length t - 1 do
      match Schema.find v.schema p with
      | Some d ->
        let k = Tokens.kind_of d.name in
        let r = (if reads_prop v r p then 1 else 0) lor if Tokens.adds_kind r k then 2 else 0 in
        Bytes.unsafe_set t p (Char.unsafe_chr r)
      | None -> ()
    done;
    c.kinds.(i) <- Some (v.schema, t);
    t

let bit t p b = p < Bytes.length t && Char.code (Bytes.unsafe_get t p) land b <> 0
let kind_name (v : Store.view) p = match Schema.find v.schema p with Some d -> Tokens.kind_of d.name | None -> string_of_int p

(* the kind of the first pattern of a question that the token may not read, if any: every pattern, those inside Not
   and Or too (an absence, or an alternative, of a fact of a kind is a read of that kind) *)
let unreadable t (v : Store.view) (q : Query.t) extra =
  match List.find_opt (fun (pt : Query.pattern) -> not (bit t pt.p 1)) (Ask.patterns q extra) with Some pt -> Some (kind_name v pt.p) | None -> None

(* the kind of the first fact of a group that the token may not add, if any: a fact of a property, or the declaration
   of a property (its name, type, many or unique), of the property's kind, by its name in the schema or in this group;
   rules are for tokens that write every kind *)
let unaddable c i (v : Store.view) r ops =
  let t = kinds_table c i v r in
  let declared e =
    match Schema.find v.schema e with
    | Some d -> Some (Tokens.kind_of d.name)
    | None ->
      List.find_map (function Resolve.Add (x, p, Value.Text n) when x = e && p = Schema.p_name -> Some (Tokens.kind_of n) | _ -> None) ops
  in
  List.find_map
    (fun (op : Resolve.op) ->
      let e, p = match op with Add (e, p, _) | Retract (e, p, _) | Expect (e, p, _) -> e, p in
      if not (Schema.is_system p) then if bit t p 2 then None else Some (kind_name v p)
      else if p = Schema.p_rule || Schema.rule v.schema e <> None then Some "rules"
      else match declared e with Some k when Tokens.adds_kind r k -> None | Some k -> Some k | None -> Some (string_of_int e))
    ops

(* a question that a token with rights per kind may not read: denied, when it arrives *)
let kinds_read c ~id ~kind d q extra =
  match c.rights.(d.index) with
  | Some (Tokens.Kinds _ as r) -> (
    let v = d.view () in
    match unreadable (kinds_table c d.index v r) v q extra with
    | Some k -> err c ~id ~kind "denied" "this token may not read the kind %s of %s" k d.name; false
    | None -> true)
  | _ -> true

(* ---- reads ---- *)

(* a value straight from its index word, as Value.encode codes it: no value is built for an inline type *)
let put_word b (v : Store.view) (ty : Value.typ) w =
  match ty with
  | Tint -> Buffer.add_char b '\000'; Codec.put_int b w
  | Tbool -> Buffer.add_char b (if w <> 0 then '\003' else '\002')
  | Tdate -> Buffer.add_char b '\005'; Codec.put_int b w
  | Tmoney _ -> Buffer.add_char b '\006'; Codec.put_int b w
  | Tlink -> Buffer.add_char b '\007'; Codec.put_int b w
  | Ttext -> Buffer.add_char b '\004'; Codec.put_string b (Store.text v w)
  | Tfloat -> Value.encode b (Store.value v ty w)

let get c ~id ~kind d thing =
  let v = d.view () in
  let b = c.body and f = c.scratch in
  Buffer.clear b;
  Buffer.clear f;
  let n = ref 0 in
  (* a token with rights per kind gets the facts of the kinds it reads, as if the thing had no other *)
  let t = match c.rights.(d.index) with Some (Tokens.Kinds _ as r) -> Some (kinds_table c d.index v r) | _ -> None in
  Store.iter_facts v thing (fun p w ->
      match Schema.find v.schema p with
      | Some dsc when (match t with None -> true | Some t -> bit t p 1) -> incr n; Codec.put_varint f p; put_word f v dsc.typ w
      | _ -> ());
  Codec.put_varint b v.group;
  Codec.put_varint b !n;
  Buffer.add_buffer b f;
  send_body c ~id ~kind ~flags:0 b

let chunk = 1 lsl 20

(* rows coded in frames of about a MiB: each frame but the last has the flag more *)
let send_rows c ~id ~kind group cols (row : int -> Buffer.t -> unit) nrows =
  let b = c.body in
  let rec go i =
    Buffer.clear b;
    let rows = Buffer.create 1024 in
    let j = ref i in
    while !j < nrows && Buffer.length rows < chunk do row !j rows; incr j done;
    Codec.put_varint b group;
    Codec.put_varint b cols;
    Codec.put_varint b (!j - i);
    Buffer.add_buffer b rows;
    let last = !j >= nrows in
    send_body c ~id ~kind ~flags:(if last then 0 else Wire.f_more) b;
    if not last then (c.flush (); go !j)
  in
  go 0

(* a damaged page met while the rows are coded (a text read from its run) ends the reply too, after the frames sent *)
let find c ~id ~kind d (q : Query.t) (sel : Wire.select) extra order =
  let v = d.view () in
  match
    let a = Answer.answer ~order ~extra ~budget:!Answer.question_budget v q sel in
    let typs = Array.init a.cols a.typ in
    send_rows c ~id ~kind v.group a.cols (fun i b -> for j = 0 to a.cols - 1 do put_word b v typs.(j) (a.word i j) done) a.n
  with
  | () -> ()
  | exception Query.Bad m -> err c ~id ~kind "invalid" "%s" m
  | exception Query.Over_budget n ->
    err c ~id ~kind "too_large" "the question passed the server's budget of %d candidates: ask a narrower one, or several" n
  | exception Pages.Unreadable m -> err c ~id ~kind "damaged" "%s" m

(* ---- writes ---- *)

let write c ~id ~kind d ~serial ~floor ~by ~why ops =
  if Origin.has_marker why then err c ~id ~kind "invalid" "a why may not start with the server's marker"
  else
    let tok = Option.get c.token in
    let not_in_flight () = Mutex.protect c.om (fun () -> c.inflight <- c.inflight - 1; Condition.broadcast c.oc) in
    (* the reply of a write, in the thread that ends it (it may be another connection's: a write sent again while
       the first was in flight): its failure ends this connection, never the thread's; out of flight at its end
       whatever happened, so that the connection's end never waits for it in vain *)
    let answer res =
      (match
        Mutex.protect c.om (fun () ->
            let b = c.wbody in
            Buffer.clear b;
            let flags =
              match res with
              | Ok r -> Wire.put_reply b (Wire.Receipt r); 0
              | Error e ->
                let code, message = Wire.code_of_error e in
                (* a refusal by the rules names its rule only, to a token that may not read every kind *)
                let message =
                  match c.rights.(d.index) with
                  | Some (Tokens.Kinds _) when code = "invalid" -> Option.value (Reason.public_message message) ~default:message
                  | _ -> message
                in
                Wire.put_reply b (Wire.Err { code; message }); Wire.f_error
            in
            Wire.add_frame c.out ~id ~kind ~flags b);
        c.flush ()
      with
      | () -> ()
      | exception e -> broke c e);
      not_in_flight ()
    in
    let v = d.view () in
    let published = v.group in
    match match c.rights.(d.index) with Some (Tokens.Kinds _ as r) -> unaddable c d.index v r ops | _ -> None with
    | Some k -> err c ~id ~kind "denied" "this token may not add to the kind %s of %s" k d.name
    | None ->
    (* counted in flight before the table may hand [answer] to a write that ends at once *)
    Mutex.protect c.om (fun () -> c.inflight <- c.inflight + 1);
    match Sessions.start d.sessions ~sid:c.session ~token:tok.name ~serial ~floor ~published ~now:(c.srv.now ()) ops answer with
    | exception e -> not_in_flight (); raise e
    | Sessions.Refuse (code, m) -> not_in_flight (); err c ~id ~kind code "%s" m
    | Sessions.Replay r -> not_in_flight (); reply c ~id ~kind (Wire.Receipt r)
    | Sessions.Wait -> ()
    | Sessions.Fresh p -> (
      let o = { Origin.token = tok.name; session = c.session; serial; floor } in
      (* a hand-off that fails (the transport could not make the thread of the replies) was never taken: the write
         leaves the connection's flight and its session's, which may send it again; the request then fails *)
      match c.submit d ops by (Origin.wrap o why) (Sessions.finish d.sessions p) with
      | () -> ()
      | exception e -> Sessions.abandon d.sessions p; not_in_flight (); raise e)

(* ---- files ---- *)

module Vault = Cepheus_vault.Vault

let vault_err c ~id ~kind e = let code, m = Files.code_of e in err c ~id ~kind code "%s" m

(* the last bytes of a file came: its bytes made durable, then the group of its facts written as any write, in the
   session (a Put sent again after a broken connection is applied once: its bytes are found stored, its group
   answered again) *)
let put_end c ~id d (st : Files.put) =
  match st.meta with
  | Wire.Put p -> (
    match Vault.finish st.w with
    | Error e -> vault_err c ~id ~kind:Wire.k_put e
    | Ok (root, size) ->
      write c ~id ~kind:Wire.k_put d ~serial:p.serial ~floor:p.floor ~by:p.by ~why:p.why
        (Files.facts st.p ~name:p.name ~typ:p.typ ~owner:p.owner ~size ~root))
  | _ -> ()

let put_feed c ~id ~more d (st : Files.put) data =
  st.bytes <- st.bytes + String.length data;
  if st.bytes > !Files.max_size then begin
    Hashtbl.remove c.puts id;
    err c ~id ~kind:Wire.k_put "too_large" "a file has at most %d bytes" !Files.max_size
  end
  else
    match Vault.feed st.w (Bytes.unsafe_of_string data) 0 (String.length data) with
    | Error e -> Hashtbl.remove c.puts id; vault_err c ~id ~kind:Wire.k_put e
    | Ok () -> if not more then (Hashtbl.remove c.puts id; put_end c ~id d st)

(* a Put: checked whole before a byte is stored (rights, the kind, the bounds, the owner) *)
let put_start c ~id ~more d (req : Wire.request) =
  let kind = Wire.k_put in
  match req with
  | Wire.Put p -> (
    let v = d.view () in
    let refuse code fmt = Printf.ksprintf (fun m -> err c ~id ~kind code "%s" m) fmt in
    if Hashtbl.mem c.puts id then refuse "invalid" "a Put on the id of a Put not finished"
    else if Hashtbl.length c.puts >= Files.max_puts then refuse "too_large" "a connection puts %d files at once at most" Files.max_puts
    else if String.length p.name > Files.max_name || String.length p.typ > Files.max_type then
      refuse "too_large" "a file's name has %d bytes at most, its type %d" Files.max_name Files.max_type
    else if Origin.has_marker p.why then refuse "invalid" "a why may not start with the server's marker"
    else if not (Config.valid_name p.kind) then refuse "invalid" "a file kind's name: lower-case letters, digits, '_' and '-'"
    else
      match Files.props_of v p.kind with
      | Error m -> refuse "invalid" "%s" m
      | Ok props -> (
        let facts = Files.facts props ~name:p.name ~typ:p.typ ~owner:p.owner ~size:0 ~root:(String.make 32 '\000') in
        match match c.rights.(d.index) with Some (Tokens.Kinds _ as r) -> unaddable c d.index v r facts | _ -> None with
        | Some k -> refuse "denied" "this token may not add to the kind %s of %s" k d.name
        | None ->
          if p.owner > 0 && Cepheus.get v p.owner = [] then refuse "invalid" "the owner %d is not a thing of %s" p.owner d.name
          else
            match Files.vault d.files with
            | Error m -> refuse "io" "the vault of %s: %s" d.name m
            | Ok vt -> (
              match Vault.writer vt ~domain:p.owner ~cold:p.cold with
              | Error e -> vault_err c ~id ~kind e
              | Ok w ->
                let st = { Files.w; p = props; meta = req; bytes = 0 } in
                Hashtbl.replace c.puts id (d, st);
                put_feed c ~id ~more d st p.data)))
  | _ -> ()

(* a file's bytes from [from], [len] of them (-1: to the end), in frames of a MiB with the flag more but the last;
   a failure after some frames ends the reply with an error frame *)
let load c ~id ~kind d ~thing ~prop ~from ~len =
  let v = d.view () in
  let readable_kind =
    match c.rights.(d.index) with Some (Tokens.Kinds _ as r) -> bit (kinds_table c d.index v r) prop 1 | _ -> true
  in
  if not readable_kind then err c ~id ~kind "denied" "this token may not read the kind %s of %s" (kind_name v prop) d.name
  else
    match Files.root_of v thing prop with
    | Error (code, m) -> err c ~id ~kind code "%s" m
    | Ok root -> (
      match Files.vault d.files with
      | Error m -> err c ~id ~kind "io" "the vault of %s: %s" d.name m
      | Ok vt -> (
        match if len >= 0 then Ok len else Result.map (fun s -> s - from) (Vault.size vt root) with
        | Error e -> vault_err c ~id ~kind e
        | Ok len ->
          let b = c.body in
          Buffer.clear b;
          let piece bytes off n =
            let o = ref off and n = ref n in
            while !n > 0 do
              let k = min !n (chunk - Buffer.length b) in
              Buffer.add_subbytes b bytes !o k;
              o := !o + k;
              n := !n - k;
              if Buffer.length b >= chunk then begin
                send_body c ~id ~kind ~flags:Wire.f_more b;
                Buffer.clear b;
                c.flush ()
              end
            done
          in
          match Vault.load vt root ~from ~len piece with
          | Ok () -> send_body c ~id ~kind ~flags:0 b
          | Error e -> vault_err c ~id ~kind e))

(* ---- live questions ---- *)

(* the pushes not yet sent, at most: a watch whose connection holds more falls behind (lagging) *)
let max_pushes = ref (8 lsl 20)

(* the pushes into the output, for the transport's sender: true when there were some *)
let move_pushes c =
  let s = Mutex.protect c.pm (fun () -> let s = Buffer.contents c.pushes in Buffer.clear c.pushes; s) in
  if s = "" then false
  else begin
    Mutex.protect c.om (fun () -> Buffer.add_string c.out s);
    true
  end

let watch c ~id ~kind d (q : Query.t) (sel : Wire.select) ~from ~extra =
  let tok = Option.get c.token in
  let cols = match sel with Wire.Give [||] -> q.vars | Give g -> Array.length g | Group (k, a) -> Array.length k + Array.length a in
  (* G16 at each message: the token may still read the database (the table is read again only when it changed) *)
  let seen = ref (Atomic.get c.srv.tokens) and reads = ref true in
  let allowed () =
    let cur = Atomic.get c.srv.tokens in
    if cur != !seen then begin
      seen := cur;
      reads :=
        match List.find_opt (fun (t : Tokens.token) -> t.name = tok.name && Tokens.equal_ct t.hash tok.hash) cur.tokens with
        | Some t -> (
          match Tokens.right t d.name with
          | None -> false
          | Some (Tokens.Read | Tokens.Write) -> true
          | Some (Tokens.Kinds _ as r) ->
            let v = d.view () in
            List.for_all (fun (pt : Query.pattern) -> reads_prop v r pt.p) (Ask.patterns q extra))
        | None -> false
    end;
    !reads
  in
  (* a push, under the hub's lock (so before the connection's end has dropped its watches), mostly in the hub's
     thread: its failure (the transport cannot make the thread of the pushes, memory) ends this connection, never the
     hub *)
  let push (m : Live.msg) =
    let ok =
      Mutex.protect c.pm (fun () ->
          if c.closed then true
          else
            (* a push of several frames whole or not at all: a part of one, then the next, would be joined by the
               client into rows of neither *)
            let n0 = Buffer.length c.pushes in
            try
              match m with
              | Live.Ended e ->
                let b = Buffer.create 64 in
                let code = if allowed () then e.code else "denied" in
                Wire.put_reply b (Wire.Err { code; message = (if code = "denied" then "this token may not read " ^ d.name else e.message) });
                Wire.add_frame c.pushes ~id ~kind:Wire.k_watch ~flags:Wire.f_error b;
                true
              | _ when Buffer.length c.pushes > !max_pushes || not (allowed ()) -> false
              | Answer a -> Wire.add_push c.pushes ~id (Wire.Answer { group = a.group; cols; rows = a.rows }); true
              | Change ch -> Wire.add_push c.pushes ~id (Wire.Change { group = ch.group; cols; added = ch.added; removed = ch.removed }); true
              | Same s -> Wire.add_push c.pushes ~id (Wire.Same s.group); true
            with e -> Buffer.truncate c.pushes n0; raise e)
    in
    c.wake ();
    ok
  in
  let emit m = match push m with ok -> ok | exception e -> broke c e; true in
  let h = d.hub () in
  match Live.subscribe ~extra h q sel ~from ~emit with
  | s -> Mutex.protect c.pm (fun () -> c.watching <- (id, (h, s)) :: c.watching)
  | exception Query.Bad m -> err c ~id ~kind "invalid" "%s" m
  | exception Query.Over_budget n ->
    err c ~id ~kind "too_large" "the question passed the server's budget of %d candidates: ask a narrower one, or several" n
  | exception Pages.Unreadable m -> err c ~id ~kind "damaged" "%s" m
  | exception Failure m -> err c ~id ~kind "stopping" "%s" m

let unwatch c ~id ~kind w =
  let found = Mutex.protect c.pm (fun () ->
      let f = List.assoc_opt w c.watching in
      c.watching <- List.filter (fun (i, _) -> i <> w) c.watching;
      f)
  in
  Option.iter (fun (h, s) -> Live.unsubscribe h s) found;
  reply c ~id ~kind Wire.Unwatched

(* ---- dispatch ---- *)

(* the newest version of the protocol this server speaks (a test makes it 1, to stand for an older server) *)
let speaks = ref Wire.version

let status c =
  let srv = c.srv in
  let conns, reqs = Mutex.protect srv.cm (fun () -> Hashtbl.length srv.conns, Hashtbl.fold (fun _ c n -> n + c.requests) srv.conns 0) in
  [ "server", srv.server_id; "cluster", srv.cluster_id; "uptime_ms", string_of_int (srv.now () - srv.started);
    "connections", string_of_int conns; "requests", string_of_int (reqs + Atomic.get srv.served);
    "gc_minor", string_of_int (Gc.quick_stat ()).minor_collections; "gc_major", string_of_int (Gc.quick_stat ()).major_collections;
    "stopping", string_of_bool (Atomic.get srv.stopping) ]
  @ srv.more ()
  @ List.concat_map
      (fun d ->
        let v = d.view () in
        [ "database." ^ d.name ^ ".group", string_of_int v.group; "database." ^ d.name ^ ".facts", string_of_int (Store.facts v);
          "database." ^ d.name ^ ".resent", string_of_int d.sessions.resent ]
        @ List.map (fun (k, x) -> "database." ^ d.name ^ "." ^ k, x) (d.more ()))
      (Array.to_list srv.dbs)

type action =
  | Continue
  | Close
  | Follows of db * int  (** the connection becomes the database's follow stream (request id): the transport's work *)

(* one complete frame: [r] reads its body *)
let handle c ~id ~kind ~flags (r : Codec.reader) =
  c.requests <- c.requests + 1;
  match Wire.get_request kind r with
  | exception (Codec.Short | Wire.Malformed _) ->
    err c ~id ~kind "invalid" "a malformed request (kind %d)" kind;
    Close
  | req -> (
    if Atomic.get c.srv.stopping then (err c ~id ~kind "stopping" "the server is stopping"; Continue)
    else
      match req with
      | Wire.Hello h ->
        if h.version < Wire.oldest || h.version > !speaks then
          (err c ~id ~kind "version" "protocol %d is not spoken here (%d to %d are)" h.version Wire.oldest !speaks; Close)
        else (
          let tokens = Atomic.get c.srv.tokens in
          match Tokens.check tokens h.token with
          | None -> err c ~id ~kind "auth" "unknown token"; Close
          | Some tok ->
            c.token <- Some tok;
            c.seen <- tokens;
            c.rights <- Array.map (fun d -> Tokens.right tok d.name) c.srv.dbs;
            c.kinds <- Array.make (Array.length c.srv.dbs) None;
            c.session <- (if h.session > 0 then h.session else c.srv.new_session ());
            reply c ~id ~kind
              (Wire.Welcome { server = c.srv.server_id; cluster = c.srv.cluster_id; session = c.session; frame = Wire.max_frame;
                              inflight = c.srv.max_inflight });
            Continue)
      | _ when c.token = None -> err c ~id ~kind "auth" "Hello comes first"; Close
      | _ -> (
        refresh_rights c;
        match c.token, req with
        | None, _ -> err c ~id ~kind "auth" "the token was removed"; Close
        | _, Wire.Hello _ -> Continue
        | _, Wire.Ping s -> reply c ~id ~kind (Wire.Pong s); Continue
        | Some tok, Wire.Admin what ->
          if not tok.admin then err c ~id ~kind "denied" "this token is not an admin token"
          else if what = "status" then reply c ~id ~kind (Wire.Status (status c))
          else err c ~id ~kind "invalid" "unknown admin operation %S" what;
          Continue
        | _, Wire.Open name ->
          (match Hashtbl.find_opt c.srv.by_name name with
           | None -> err c ~id ~kind "unknown_database" "no database %S on this server" name
           | Some d when c.rights.(d.index) = None -> err c ~id ~kind "denied" "this token may not read %s" name
           | Some d ->
             let v = d.view () in
             let props = ref [] in
             for p = Schema.count v.schema - 1 downto 1 do
               match Schema.find v.schema p with Some x -> props := (p, x) :: !props | None -> ()
             done;
             reply c ~id ~kind (Wire.Opened { db = d.index; group = v.group; props = !props }));
          Continue
        | _, Wire.Get g ->
          (match readable c ~id ~kind g.db with
           | None -> ()
           | Some d -> ( try get c ~id ~kind d g.thing with Pages.Unreadable m -> err c ~id ~kind "damaged" "%s" m));
          Continue
        | _, Wire.Find f ->
          (match readable c ~id ~kind f.db with
           | None -> ()
           | Some d -> if kinds_read c ~id ~kind d f.query f.extra then find c ~id ~kind d f.query f.select f.extra f.order);
          Continue
        | _, Wire.Write w ->
          (match writable c ~id ~kind w.db with
           | None -> ()
           | Some d -> write c ~id ~kind d ~serial:w.serial ~floor:w.floor ~by:w.by ~why:w.why w.ops);
          Continue
        | _, Wire.Watch w ->
          (match readable c ~id ~kind w.db with
           | None -> ()
           | Some d -> if kinds_read c ~id ~kind d w.query w.wextra then watch c ~id ~kind d w.query w.select ~from:w.from ~extra:w.wextra);
          Continue
        | _, Wire.Unwatch w -> unwatch c ~id ~kind w; Continue
        | _, (Wire.Put p as req) ->
          let more = flags land Wire.f_more <> 0 in
          (match writable c ~id ~kind p.db with
           | None -> ()
           | Some d -> put_start c ~id ~more d req);
          Continue
        | _, Wire.Piece data ->
          (* the pieces of a Put that was refused, or failed, are dropped *)
          (match Hashtbl.find_opt c.puts id with
           | Some (d, st) -> (
             (* G16 at each piece: a token whose right to write went meanwhile ends its put *)
             match writable c ~id ~kind:Wire.k_put d.index with
             | Some _ -> put_feed c ~id ~more:(flags land Wire.f_more <> 0) d st data
             | None -> Hashtbl.remove c.puts id)
           | None -> ());
          Continue
        | _, Wire.Erase e ->
          (* irreversible: a right to write every kind of the database *)
          (match db_of c ~id ~kind e.db with
           | None -> ()
           | Some d when c.rights.(e.db) <> Some Tokens.Write -> err c ~id ~kind "denied" "erasing an owner's files needs a right to write all of %s" d.name
           | Some _ when e.owner <= 0 -> err c ~id ~kind "invalid" "an erasure names an owner, a thing: the database's own key (0) is never erased"
           | Some d -> (
             match Files.vault d.files with
             | Error m -> err c ~id ~kind "io" "the vault of %s: %s" d.name m
             | Ok vt -> ( match Vault.erase vt e.owner with Ok () -> reply c ~id ~kind Wire.Erased | Error x -> vault_err c ~id ~kind x)));
          Continue
        | _, Wire.Load l ->
          (match readable c ~id ~kind l.db with
           | None -> ()
           | Some d -> load c ~id ~kind d ~thing:l.thing ~prop:l.prop ~from:l.from ~len:l.len);
          Continue
        | _, Wire.Follow i -> (
          (* a reader's right is enough (G16); a follow stream carries nothing else *)
          match readable c ~id ~kind i with
          | None -> Continue
          | Some d when (match c.rights.(i) with Some (Tokens.Kinds _) -> true | _ -> false) ->
            err c ~id ~kind "denied" "local reads need a right to read every kind of %s: this token reads at the server" d.name;
            Continue
          | Some d ->
            if Mutex.protect c.om (fun () -> c.inflight) > 0 then (err c ~id ~kind "invalid" "Follow on a connection with writes in flight"; Close)
            else Follows (d, id))))

type input =
  | Need  (** a frame is not whole yet: read more *)
  | Full  (** the writes in flight reached the limit *)
  | Shut
  | Follow of db * int  (** the connection becomes a follow stream (Follows) *)

(* Every complete frame of [buf] from [off] to [stop], until the connection has its limit of writes in flight: the
   offset of the first byte not used, and why it stopped. A frame over the limit closes the connection before its
   body is read. A request that raises what it does not expect is answered internal and closes the connection
   ([fail]): the frames of its reply sent before (a Find's first rows) end with that error, which the client takes
   as the reply's end. A connection that another of its threads failed ([broke]) reads no more requests. *)
let input c buf off stop =
  let rec go o =
    if Atomic.get c.failed then o, Shut
    else if c.inflight >= c.srv.max_inflight then o, Full
    else if stop - o < 4 then o, Need
    else
      let len = Wire.u32 buf o in
      if len > Wire.max_frame || len < 6 then begin
        err c ~id:0 ~kind:0 "too_large" "a frame of %d bytes (the limit is %d)" len Wire.max_frame;
        o, Shut
      end
      else if stop - o < 4 + len then o, Need
      else
        let id = Wire.u32 buf (o + 4) and kind = Bytes.get_uint8 buf (o + 8) and flags = Bytes.get_uint8 buf (o + 9) in
        match handle c ~id ~kind ~flags (Codec.reader buf (o + Wire.header) (len - 6)) with
        | Continue -> go (o + 4 + len)
        | Close -> o + 4 + len, Shut
        | Follows (d, id) -> o + 4 + len, Follow (d, id)
        | exception e -> fail c ~id ~kind e; o + 4 + len, Shut
  in
  go off

(* the reading side waits here while the connection has its limit of writes in flight: it stops reading, the kernel's
   buffers fill, and the program's writes wait (back-pressure, design 3.5) *)
let wait_room c = Mutex.protect c.om (fun () -> while c.inflight >= c.srv.max_inflight do Condition.wait c.oc c.om done)

(* every write in flight answered: before a connection's resources go *)
let drain c = Mutex.protect c.om (fun () -> while c.inflight > 0 do Condition.wait c.oc c.om done)
