#!/bin/sh
# Model-checks spec/Journal.tla, spec/Merge.tla, spec/Seats.tla and spec/LocalReads.tla with TLC (bounds in their .cfg
# files), and checks that what must break does: the naive sale of spec/Seats.tla (SeatsNaive.cfg), and every variant of
# the local reads' rule that drops a part of it, the design's lease and its first draft (LocalReads*.cfg). TLA2TOOLS names
# tla2tools.jar, the official release from https://github.com/tlaplus/tlaplus/releases (v1.7.4 used here); Java 11 or
# later.
set -e
cd "$(dirname "$0")/.."
: "${TLA2TOOLS:?set TLA2TOOLS to the path of tla2tools.jar}"
meta=$(mktemp -d)
trap 'rm -rf "$meta"' EXIT
cd spec
for m in Journal Merge Seats; do
  java -Xmx1g -XX:+UseParallelGC -cp "$TLA2TOOLS" tlc2.TLC -deadlock -workers 4 -metadir "$meta/$m" -config $m.cfg $m.tla
done
for c in LocalReads LocalReadsCrash LocalReadsDesignFresh; do
  java -Xmx1g -XX:+UseParallelGC -cp "$TLA2TOOLS" tlc2.TLC -deadlock -workers 4 -metadir "$meta/$c" -config $c.cfg LocalReads.tla
done
# each must break an invariant: TLC exits with 12 and prints the counterexample
for c in LocalReadsLive LocalReadsNoSkip LocalReadsEarly LocalReadsRemoteFirst LocalReadsDesign LocalReadsDraft; do
  rc=0
  java -Xmx1g -XX:+UseParallelGC -cp "$TLA2TOOLS" tlc2.TLC -deadlock -workers 1 -metadir "$meta/$c" -config $c.cfg LocalReads.tla || rc=$?
  if [ "$rc" -ne 12 ]; then echo "tlc.sh: $c of spec/LocalReads.tla should break an invariant (TLC exit $rc)"; exit 1; fi
  echo "tlc.sh: $c breaks an invariant, as it must"
done
# the naive sale must break an invariant: TLC exits with 12 (a safety violation) and prints the counterexample
rc=0
java -Xmx1g -XX:+UseParallelGC -cp "$TLA2TOOLS" tlc2.TLC -deadlock -workers 1 -metadir "$meta/naive" -config SeatsNaive.cfg Seats.tla || rc=$?
if [ "$rc" -ne 12 ]; then echo "tlc.sh: the naive sale of spec/Seats.tla should break an invariant (TLC exit $rc)"; exit 1; fi
echo "tlc.sh: the naive sale breaks an invariant, as it must"
