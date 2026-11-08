#!/bin/sh
# Every test: unit and property tests, the rules' property tests (G17, G18, G20), the exhaustive enumeration, the simulation (SEEDS seeds, 300 by default),
# real kill -9 rounds, the bank test, the sale of seats with kill -9 (docs/case-seats.md), and the documentation's
# examples. Scratch databases go in $CEPHEUS_TMP (default: the system's temp dir).
set -e
cd "$(dirname "$0")/.."
tmp=${CEPHEUS_TMP:-${TMPDIR:-/tmp}}
dune build --profile release 2>&1
b=_build/default/test
CEPHEUS_TMP=$tmp $b/unit.exe | tail -1
$b/reasoning.exe | tail -1
$b/exhaustive.exe | tail -3
$b/sim.exe --seeds "${SEEDS:-300}" | tail -2
rm -rf "$tmp/cepheus-crash" && $b/crash.exe "$tmp/cepheus-crash" "${KILLS:-20}" | tail -2 && rm -rf "$tmp/cepheus-crash"
$b/bank.exe "$tmp/cepheus-bank" "${BANK_SECONDS:-2}" | tail -2
rm -rf "$tmp/cepheus-seats" && $b/seats.exe "$tmp/cepheus-seats" "${SEAT_KILLS:-20}" | tail -2 && rm -rf "$tmp/cepheus-seats"
CEPHEUS_TMP=$tmp $b/examples.exe | tail -1
