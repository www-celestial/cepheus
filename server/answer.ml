(* The answer of a question with its select on a view, the same at the server (Core) and in a program that reads
   locally (Client): the rows as index words, no value built, so that the server codes them straight onto the wire. *)

open Cepheus

(* rows as index words, a flat array a domain *)
type acc = { mutable a : int array; mutable n : int }

let push acc w =
  if acc.n = Array.length acc.a then begin
    let a = Array.make (max 64 (2 * acc.n)) 0 in
    Array.blit acc.a 0 a 0 acc.n;
    acc.a <- a
  end;
  acc.a.(acc.n) <- w;
  acc.n <- acc.n + 1

let append a b = for i = 0 to b.n - 1 do push a b.a.(i) done; a

(* The answer of a question with its select on [v], the same at the server and in a local reader: its columns, its
   rows, the type of each column and the index word of each cell (no value built). Raises Query.Bad. *)
type answer = { cols : int; n : int; typ : int -> Value.typ; word : int -> int -> int }

(* the answer from rows held whole (sorted, cut) *)
let of_rows cols (typs : Value.typ array) (rows : int array array) =
  { cols; n = Array.length rows; typ = (fun j -> typs.(j)); word = (fun i j -> rows.(i).(j)) }

let lead = Top.lead

(* the work a question may take at the server, in candidates of its join (each domain's, and its Nots' together): past
   it, Query.Over_budget, and the program is told to ask a narrower question; a program reading in its own memory has
   no budget but its own *)
let question_budget = ref 1_000_000_000

let answer ?(order = Top.none) ?(extra = []) ?(budget = max_int) (v : Store.view) (q : Query.t) (sel : Wire.select) =
  (* Not, Or and In beside the patterns and ranges: the question goes through Ask *)
  let ask = if extra = [] then None else Some (Ask.compile v q extra) in
  let ty = match ask with None -> Query.types v q | Some a -> Ask.typs_of a in
  let var x =
    if x < 0 || x >= q.vars then Query.bad "variable %d out of range" x;
    match ask with
    | Some a when not a.outer.(x) -> Query.bad "variable %d is a Not's or an Or's own: Give and Sort take the question's variables" x
    | _ -> ()
  in
  let fold ?seq ?range ~init ~step ~merge () =
    match ask with
    | None -> Query.fold ?seq ~budget v (match range with None -> q | Some r -> { q with ranges = r :: q.ranges }) ~init ~step ~merge
    | Some a -> Ask.fold ?seq ~budget ?range v a ~init ~step ~merge
  in
  match sel with
  | Wire.Give give when order <> Top.none ->
    let give = if Array.length give = 0 then Array.init q.vars Fun.id else give in
    Array.iter var give;
    let typs = Array.map (fun x -> ty.(x)) give in
    let src =
      { Top.fold = (fun range ~seq ~init ~step ~merge -> fold ~seq ?range ~init ~step ~merge ());
        project = (fun env -> Array.map (fun x -> env.(x)) give);
        var = (fun c -> Some give.(c));
        lead = lead v q;
        estimate = (fun () -> match ask with None -> Query.estimate v q | Some a -> Ask.estimate v a) }
    in
    of_rows (Array.length give) typs (Top.give v ~typs src order)
  | Wire.Give give ->
    let give = if Array.length give = 0 then Array.init q.vars Fun.id else give in
    Array.iter var give;
    let k = Array.length give in
    let acc =
      fold ~init:(fun () -> { a = [||]; n = 0 }) ~merge:append
        ~step:(fun acc env -> for i = 0 to k - 1 do push acc env.(give.(i)) done; acc) ()
    in
    { cols = k; n = acc.n / max 1 k; typ = (fun j -> ty.(give.(j))); word = (fun i j -> acc.a.((i * k) + j)) }
  | Wire.Group (keys, aggs) ->
    Array.iter var keys;
    Array.iter
      (function
        | Wire.Count -> ()
        | Wire.Sum x ->
          var x;
          (match ty.(x) with Tint | Tmoney _ -> () | t -> Query.bad "a sum of a %s variable" (Value.typ_name t))
        | Wire.Min x | Wire.Max x ->
          var x;
          (match ty.(x) with Tint | Tmoney _ | Tdate -> () | t -> Query.bad "a min or max of a %s variable" (Value.typ_name t)))
      aggs;
    let nk = Array.length keys and na = Array.length aggs in
    (* key words -> aggregate words, a table a domain, joined at the end *)
    let fresh () = Array.init na (fun i -> match aggs.(i) with Wire.Min _ -> max_int | Wire.Max _ -> min_int | _ -> 0) in
    let add (st : int array) env =
      for i = 0 to na - 1 do
        match aggs.(i) with
        | Wire.Count -> st.(i) <- st.(i) + 1
        | Wire.Sum x -> st.(i) <- st.(i) + env.(x)
        | Wire.Min x -> if env.(x) < st.(i) then st.(i) <- env.(x)
        | Wire.Max x -> if env.(x) > st.(i) then st.(i) <- env.(x)
      done
    in
    let join (a : int array) (b : int array) =
      for i = 0 to na - 1 do
        match aggs.(i) with
        | Wire.Count | Wire.Sum _ -> a.(i) <- a.(i) + b.(i)
        | Wire.Min _ -> a.(i) <- min a.(i) b.(i)
        | Wire.Max _ -> a.(i) <- max a.(i) b.(i)
      done
    in
    let tbl =
      fold ~init:(fun () -> Hashtbl.create 64)
        ~merge:(fun a b ->
          Hashtbl.iter (fun k s -> match Hashtbl.find_opt a k with Some s' -> join s' s | None -> Hashtbl.replace a k s) b;
          a)
        ~step:(fun t env ->
          let k = Array.init nk (fun i -> env.(keys.(i))) in
          (match Hashtbl.find_opt t k with
           | Some s -> add s env
           | None -> let s = fresh () in add s env; Hashtbl.replace t k s);
          t) ()
    in
    let groups = Array.of_seq (Hashtbl.to_seq tbl) in
    (* in the order of the keys' words: an answer that does not depend on the number of domains *)
    Array.sort compare groups;
    let typ j =
      if j < nk then ty.(keys.(j))
      else match aggs.(j - nk) with Wire.Count -> Value.Tint | Wire.Sum y | Wire.Min y | Wire.Max y -> ty.(y)
    in
    if order = Top.none then begin
      let word i j = let k, s = groups.(i) in if j < nk then k.(j) else s.(j - nk) in
      { cols = nk + na; n = Array.length groups; typ; word }
    end
    else begin
      let typs = Array.init (nk + na) typ in
      let rows = Array.map (fun (k, s) -> Array.append k s) groups in
      of_rows (nk + na) typs (Top.sort_rows v ~typs order rows)
    end
