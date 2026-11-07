(* Statistics of the benchmarks; method in docs/benchmarks.md.

   A time is the median of n runs, with a 95 % confidence interval that assumes nothing about the distribution of the
   runs (times are skewed and often bimodal, so no mean and no normal interval): the interval between the j-th
   smallest and the j-th largest run covers the true median with probability 1 - 2 P(B <= j - 1), B ~ Binomial(n,
   1/2) (Le Boudec 2010, "Performance Evaluation of Computer and Communication Systems", theorem 2.1; Hoefler and
   Belli 2015, "Scientific benchmarking of parallel computing systems", rule 5). j is the largest whose coverage is
   still at least 95 %; the coverage printed is the exact one. *)

(* P(B <= k), B ~ Binomial(n, 1/2); exact enough in floats up to n = 1000 *)
let binom_cdf n k =
  let c = ref 1.0 and s = ref 0.0 in
  for i = 0 to k do
    if i > 0 then c := !c *. float (n - i + 1) /. float i;
    s := !s +. !c
  done;
  !s /. (2. ** float n)

type summary = { n : int; median : float; lo : float; hi : float; coverage : float; min : float }

let summary xs =
  let a = Array.copy xs in
  Array.sort compare a;
  let n = Array.length a in
  if n = 0 then invalid_arg "Stats.summary: no runs";
  let median = if n mod 2 = 1 then a.(n / 2) else (a.((n / 2) - 1) +. a.(n / 2)) /. 2. in
  let j = ref 1 in
  while !j < n / 2 && 2. *. binom_cdf n !j <= 0.05 do incr j done;
  { n; median; lo = a.(!j - 1); hi = a.(n - !j); coverage = 1. -. (2. *. binom_cdf n (!j - 1)); min = a.(0) }

(* seconds, printed in the unit that suits them *)
let unit x =
  if x < 1e-3 then Printf.sprintf "%.2f us" (x *. 1e6)
  else if x < 1. then Printf.sprintf "%.2f ms" (x *. 1e3)
  else Printf.sprintf "%.2f s" x

let print name xs =
  let s = summary xs in
  Printf.printf "%-34s median %s, CI [%s, %s] (%.1f %%), %d runs, min %s\n%!" name (unit s.median) (unit s.lo)
    (unit s.hi) (100. *. s.coverage) s.n (unit s.min)

(* latencies in microseconds, from a histogram *)
let print_latency name h =
  let p q = float (Cepheus.Histogram.percentile h q) /. 1e3 in
  Printf.printf "%s latency ms: p50 %.2f  p90 %.2f  p99 %.2f  p99.9 %.2f  max %.2f  (%d values)\n%!" name (p 0.5)
    (p 0.9) (p 0.99) (p 0.999)
    (float (Cepheus.Histogram.max h) /. 1e3)
    (Cepheus.Histogram.total h)
