(* The question of Cepheus.ask: its names apart, so that [open Cepheus] adds only [Question] and [ask] (a program's own
   [Not] or [Pattern] stays its own). A unit of its own of types and aliases, so that a program that reaches it (the
   Cesia package's engine) links neither the writer nor its threads. *)

type item = Ask.item =
  | Pattern of Query.pattern
  | Range of int * Value.t * Value.t  (** [lo <= x <= hi], an int, date, money or thing (link) variable *)
  | In of int * Value.t list  (** x is one of the values (at most 10,000) *)
  | Prefix of int * string  (** the text x starts with these bytes (1 to 1,024) *)
  | Not of item list  (** none of these patterns and conditions holds, for any value of its own variables (1 to 4) *)
  | Or of item list list  (** at least one alternative holds, each a list of patterns and conditions (2 to 4) *)
  | Less of int * int  (** x < y: two variables of one type (int, float, date, money, text, link) *)
  | Less_or_equal of int * int  (** x <= y *)
  | Optional of Query.pattern
      (** the pattern's value, or {!Value.missing}: its thing a variable that a pattern binds (or a thing's id), its
          value a variable in no other item; at the top of [items] only *)
  | Trunc of int * int * string * string
      (** [Trunc (y, x, unit, zone)]: y is the instant the unit of the date x starts in the zone's local time
          ("second", "minute", "hour", "day", "week" (ISO 8601: Monday), "month", "quarter", "year", "decade",
          "century", "millennium"; an IANA zone, as "Europe/Paris", or "UTC"): a variable computed from x, numbered after
          the question's ([vars], [vars + 1], ... in the order of the Truncs), for [give] and [sort] only; at the top
          of [items] only *)

(** A key of [sort]: a column of [give], descending when [desc]. *)
type key = Top.key = { col : int; desc : bool }

(** Variables 0 to [vars - 1]: those of its patterns, and those every alternative of an [Or] binds, are the question's;
    one in a [Not] or some alternatives only is its own. [give]: the variables of each row, in this order (empty: every
    variable of the question). [sort]: the rows in this order, then by the other columns ascending; [limit]: the first
    k rows and the copies of the k-th (0: all; at most 100,000); [after]: the rows after this row, in the order. A
    question of patterns and ranges only, given every variable, is {!Cepheus.find}'s. *)
type t = { vars : int; items : item list; give : int array; sort : key list; limit : int; after : Value.t array option }

(* the engine's questions with operators and their order, for the server and the tests *)
module Ask = Ask
module Top = Top
