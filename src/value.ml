type t = Int of int | Float of float | Bool of bool | Text of string | Date of int | Money of int | Link of int
type typ = Tint | Tfloat | Tbool | Ttext | Tdate | Tmoney of int | Tlink

let has_type ty v =
  match ty, v with
  | Tint, Int _ | Tfloat, Float _ | Tbool, Bool _ | Ttext, Text _ | Tdate, Date _ | Tmoney _, Money _ | Tlink, Link _ ->
    true
  | _ -> false

let code = function
  | Tint -> 0
  | Tfloat -> 1
  | Tbool -> 2
  | Ttext -> 3
  | Tdate -> 4
  | Tmoney s -> 5 + (16 * s)
  | Tlink -> 6

let of_code c =
  match c land 15 with
  | 0 when c = 0 -> Some Tint
  | 1 when c = 1 -> Some Tfloat
  | 2 when c = 2 -> Some Tbool
  | 3 when c = 3 -> Some Ttext
  | 4 when c = 4 -> Some Tdate
  | 5 when c >= 0 && c lsr 4 <= 18 -> Some (Tmoney (c lsr 4))
  | 6 when c = 6 -> Some Tlink
  | _ -> None

let typ_name = function
  | Tint -> "int"
  | Tfloat -> "float"
  | Tbool -> "bool"
  | Ttext -> "text"
  | Tdate -> "date"
  | Tmoney s -> Printf.sprintf "money(%d)" s
  | Tlink -> "link"

let to_string = function
  | Int n -> string_of_int n
  | Float f -> Printf.sprintf "%h" f
  | Bool b -> string_of_bool b
  | Text s -> Printf.sprintf "%S" s
  | Date d -> Printf.sprintf "date %d" d
  | Money m -> Printf.sprintf "money %d" m
  | Link e -> Printf.sprintf "#%d" e

(* floats compare by their bits, so that equality is exact (nan equals itself, 0.0 differs from -0.0) *)
let equal a b =
  match a, b with
  | Float x, Float y -> Int64.equal (Int64.bits_of_float x) (Int64.bits_of_float y)
  | _ -> a = b

let compare a b =
  match a, b with
  | Float x, Float y -> Int64.compare (Int64.bits_of_float x) (Int64.bits_of_float y)
  | _ -> Stdlib.compare a b

let encode b = function
  | Int n -> Buffer.add_char b '\000'; Codec.put_int b n
  | Float f -> Buffer.add_char b '\001'; Codec.put_u64 b (Int64.bits_of_float f)
  | Bool x -> Buffer.add_char b (if x then '\003' else '\002')
  | Text s -> Buffer.add_char b '\004'; Codec.put_string b s
  | Date d -> Buffer.add_char b '\005'; Codec.put_int b d
  | Money m -> Buffer.add_char b '\006'; Codec.put_int b m
  | Link e -> Buffer.add_char b '\007'; Codec.put_int b e

let decode r =
  match Codec.get_byte r with
  | 0 -> Int (Codec.get_int r)
  | 1 -> Float (Int64.float_of_bits (Codec.get_u64 r))
  | 2 -> Bool false
  | 3 -> Bool true
  | 4 -> Text (Codec.get_string r)
  | 5 -> Date (Codec.get_int r)
  | 6 -> Money (Codec.get_int r)
  | 7 -> Link (Codec.get_int r)
  | _ -> raise Codec.Short

let inline = function Ttext | Tfloat -> false | _ -> true
