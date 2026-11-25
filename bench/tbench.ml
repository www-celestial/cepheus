(* The data of bench/transfer.sh, and the kinds it imports into.

     tbench.exe gen DIR CLIENTS          DIR/client.csv (Name, City, Email) and DIR/invoice.csv (Client: the client's
                                         Email, Total, Status, Date), 20 invoices a client: 83 facts a client
     tbench.exe big FILE BYTES CLIENTS   invoices of CLIENTS clients until FILE holds BYTES, and a last row whose Total
                                         has 3 decimals: the import checks every row, then refuses the last one
     tbench.exe declare SOCKET DB        the kinds client and invoice declared in DB (the token in CEPHEUS_TOKEN) *)

open Cepheus
open Cepheus_server

let cities = [| "Lyon"; "Paris"; "Marseille"; "Toulouse"; "Nice"; "Nantes"; "Strasbourg"; "Montpellier"; "Bordeaux"; "Lille";
                "Rennes"; "Reims"; "Grenoble"; "Dijon"; "Angers"; "Brest"; "Tours"; "Limoges"; "Metz"; "Caen" |]
let statuses = [| "unpaid"; "late"; "paid" |]

(* the same draws at every run: a hash of the row and of what it draws *)
let draw i k n = ((((i * 16) + k + 1) * 2654435761) mod 4294967291) mod n

let invoice b k j =
  let i = (k * 20) + j in
  let d = draw i 3 (365 * 86400) in
  let days = d / 86400 and s = d mod 86400 in
  let y, m, dd = Tabular.civil_of_days (Tabular.days_of_civil 2025 11 24 + days) in
  Printf.bprintf b "client%d@example.com,%d.%02d,%s,%04d-%02d-%02dT%02d:%02d:%02dZ\n" k (draw i 1 100_000) (draw i 2 100) statuses.(draw i 4 3) y m dd
    (s / 3600) (s / 60 mod 60) (s mod 60)

let gen dir n =
  let cl = open_out_bin (Filename.concat dir "client.csv") and iv = open_out_bin (Filename.concat dir "invoice.csv") in
  output_string cl "Name,City,Email\n";
  output_string iv "Client,Total,Status,Date\n";
  let b = Buffer.create 65536 in
  for k = 0 to n - 1 do
    Printf.fprintf cl "client-%d,%s,client%d@example.com\n" k cities.(draw k 0 20) k;
    for j = 0 to 19 do invoice b k j done;
    if Buffer.length b > 60000 then (Buffer.output_buffer iv b; Buffer.clear b)
  done;
  Buffer.output_buffer iv b;
  close_out cl;
  close_out iv

let big file bytes n =
  let oc = open_out_bin file in
  output_string oc "Client,Total,Status,Date\n";
  let b = Buffer.create 65536 and total = ref 0 and k = ref 0 in
  while !total < bytes do
    for j = 0 to 19 do invoice b (!k mod n) j done;
    incr k;
    if Buffer.length b > 60000 then (total := !total + Buffer.length b; Buffer.output_buffer oc b; Buffer.clear b)
  done;
  Buffer.output_buffer oc b;
  output_string oc "client0@example.com,1.005,paid,2026-01-01T00:00:00Z\n";
  close_out oc

let declare sock name =
  let token = Sys.getenv "CEPHEUS_TOKEN" in
  let c = match Client.connect (Client.Unix_socket sock) token with Ok c -> c | Error m -> failwith m in
  let p ?(unique = false) name typ = { Schema.name; typ; many = false; unique } in
  match
    Client.declare c name
      Value.[ p "client/Name" Ttext; p "client/City" Ttext; p ~unique:true "client/Email" Ttext; p "invoice/Client" Tlink;
              p "invoice/Total" (Tmoney 2); p "invoice/Status" Ttext; p "invoice/Date" Tdate ]
  with
  | Ok _ -> Client.close c
  | Error e -> failwith e.message

let () =
  match Sys.argv with
  | [| _; "gen"; dir; n |] -> gen dir (int_of_string n)
  | [| _; "big"; file; bytes; n |] -> big file (int_of_string bytes) (int_of_string n)
  | [| _; "declare"; sock; db |] -> declare sock db
  | _ -> prerr_endline "tbench.exe gen DIR CLIENTS | big FILE BYTES CLIENTS | declare SOCKET DB"; exit 2
