#!/bin/sh
# Every test: unit and property tests, the rules' property tests (G17, G18, G20), the exhaustive enumeration, the simulation (SEEDS seeds, 300 by default),
# the commit buffer's simulation (BUFFER_SEEDS seeds, 300 by default: three databases sharing one buffer),
# real kill -9 rounds, the bank test, the sale of seats with kill -9 (docs/book/case-seats.md), and the documentation's
# examples, the server: its units and rights, its simulation (SERVER_SEEDS seeds, 200 by default), live questions
# against the naive evaluator (LIVE_SEEDS seeds, 100 by default), TLS and the
# limits of connections on a real server, a real server killed SERVER_KILLS times (20) under writing clients.
# Scratch databases go in $CEPHEUS_TMP (default: the system's temp dir).
# The Cesia client, when a Cesia with its native interface is here: its engine, built against that Cesia's
# cesia_v1.cmi (CESIA_NATIVE, its folder; found from the cesia command when unset: lib/native of a release, or the
# build's), the package's tests on forks on both paths of Cesia, and test/cesia.sh against a real server.
# Any failing step stops the script with its status: each step is a command of its own, never inside an && list but
# last (set -e does not stop on the others), and no command substitution inside another command's arguments.
set -e
# A test piped into tail fails the script: without pipefail the pipeline's status is tail's, and a failure passes.
set -o pipefail
cd "$(dirname "$0")/.."
tmp=${CEPHEUS_TMP:-${TMPDIR:-/tmp}}
if [ -z "$CESIA_NATIVE" ] && command -v cesia > /dev/null; then
  exe=$(readlink -f "$(command -v cesia)")
  for d in "$(dirname "$exe")/../lib/native" "$(dirname "$exe")/../native/.cesia_native.objs/byte"; do
    if [ -f "$d/cesia_v1.cmi" ]; then CESIA_NATIVE=$(cd "$d" && pwd); break; fi
  done
fi
export CESIA_NATIVE
dune build --profile release 2>&1
b=_build/default/test
CEPHEUS_TMP=$tmp $b/unit.exe | tail -1
$b/reasoning.exe | tail -1
$b/exhaustive.exe | tail -5
$b/sim.exe --seeds "${SEEDS:-300}" | tail -2
# its stderr: the engine reporting the failures it is given (a cut whose fsync failed too)
$b/wal_sim.exe --seeds "${BUFFER_SEEDS:-300}" 2> /dev/null | tail -2
rm -rf "$tmp/cepheus-crash"
$b/crash.exe "$tmp/cepheus-crash" "${KILLS:-20}" | tail -2
rm -rf "$tmp/cepheus-crash"
$b/bank.exe "$tmp/cepheus-bank" "${BANK_SECONDS:-2}" | tail -2
rm -rf "$tmp/cepheus-seats"
$b/seats.exe "$tmp/cepheus-seats" "${SEAT_KILLS:-20}" | tail -2
rm -rf "$tmp/cepheus-seats"
CEPHEUS_TMP=$tmp $b/examples.exe | tail -1
CEPHEUS_TMP=$tmp $b/server_unit.exe | tail -1
$b/server_sim.exe --seeds "${SERVER_SEEDS:-200}" | tail -2
$b/live_sim.exe --seeds "${LIVE_SEEDS:-100}" | tail -2
$b/server_tls.exe "$tmp/cepheus-tls" | tail -1
$b/server_limits.exe "$tmp/cepheus-limits" | tail -1
rm -rf "$tmp/cepheus-server"
$b/server_crash.exe "$tmp/cepheus-server" "${SERVER_KILLS:-20}" | tail -2
rm -rf "$tmp/cepheus-server"
if [ -n "$CESIA_NATIVE" ]; then
  mkdir -p native
  tag=$(cesia run tools/tag.ce)
  install -m 644 _build/default/cesia/native/cepheus.cmxs "native/cepheus-$tag.cmxs"
  for path in "" --no-spec; do
    cesia test $path cesia/tests > "$tmp/cesia-tests.out" 2>&1 || true
    tail -1 "$tmp/cesia-tests.out" | sed "s/^/cesia tests $path: /"
    tail -1 "$tmp/cesia-tests.out" | grep -q ' passed, 0 failed$' || { cat "$tmp/cesia-tests.out"; exit 1; }
  done
  rm -f "$tmp/cesia-tests.out"
  # A screen of std/live fed by a watch: when this Cesia has std/live.
  printf 'use std/live\n' > "$tmp/has-live.ce"
  if cesia check "$tmp/has-live.ce" > /dev/null 2>&1; then
    for path in "" --no-spec; do
      cesia test $path cesia/screens > "$tmp/cesia-screens.out" 2>&1 || true
      tail -1 "$tmp/cesia-screens.out" | sed "s/^/cesia screens $path: /"
      tail -1 "$tmp/cesia-screens.out" | grep -q ' passed, 0 failed$' || { cat "$tmp/cesia-screens.out"; exit 1; }
    done
  else
    echo "cesia screens: not tested (this Cesia has no std/live)"
  fi
  rm -f "$tmp/has-live.ce" "$tmp/cesia-screens.out"
  sh test/cesia.sh "$tmp" > "$tmp/cesia.out" 2>&1 || { cat "$tmp/cesia.out"; exit 1; }
  tail -2 "$tmp/cesia.out"
  rm -f "$tmp/cesia.out"
else
  echo "cesia client: not tested (no cesia here with its cesia_v1.cmi: set CESIA_NATIVE to its folder)"
fi
