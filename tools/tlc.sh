#!/bin/sh
# Model-checks spec/Journal.tla, spec/Merge.tla, spec/Seats.tla, spec/LocalReads.tla, spec/Watch.tla,
# spec/WatchWindow.tla, spec/CommitBuffer.tla, spec/RuleChange.tla and spec/Raft.tla with TLC (bounds in their .cfg
# files), and checks that what must break does: the naive sale of spec/Seats.tla (SeatsNaive.cfg), every variant of the
# local reads' rule that drops a part of it, the design's lease and its first draft (LocalReads*.cfg), every variant of
# a watch's resume that drops a part of its rule (Watch*.cfg), every variant of a watch's window (Sort and Limit) that
# drops a part of its rule (WatchWindow*.cfg),
# every variant of the commit buffer that drops a part of its rule (CommitBuffer*.cfg), every variant of a rule
# change's background path that drops a part of its rule (RuleChange*.cfg); spec/Raft.tla by parts (RaftCore,
# RaftDamage, RaftLease: exhaustive within their bounds), and each of its variants that drops one rule must break an
# invariant. TLA2TOOLS names
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
java -Xmx1g -XX:+UseParallelGC -cp "$TLA2TOOLS" tlc2.TLC -deadlock -workers 4 -metadir "$meta/Watch" -config Watch.cfg Watch.tla
# each variant of a watch's resume that drops a part of its rule must break an invariant
for c in WatchNoTouch WatchNoRing; do
  rc=0
  java -Xmx1g -XX:+UseParallelGC -cp "$TLA2TOOLS" tlc2.TLC -deadlock -workers 1 -metadir "$meta/$c" -config $c.cfg Watch.tla || rc=$?
  if [ "$rc" -ne 12 ]; then echo "tlc.sh: $c of spec/Watch.tla should break an invariant (TLC exit $rc)"; exit 1; fi
  echo "tlc.sh: $c breaks an invariant, as it must"
done
# a watch's window (Sort and Limit), and each variant that drops a part of its rule must break an invariant
java -Xmx1g -XX:+UseParallelGC -cp "$TLA2TOOLS" tlc2.TLC -deadlock -workers 4 -metadir "$meta/WatchWindow" -config WatchWindow.cfg WatchWindow.tla
for c in WatchWindowNoRefill WatchWindowNoTies WatchWindowStrict; do
  rc=0
  java -Xmx1g -XX:+UseParallelGC -cp "$TLA2TOOLS" tlc2.TLC -deadlock -workers 1 -metadir "$meta/$c" -config $c.cfg WatchWindow.tla || rc=$?
  if [ "$rc" -ne 12 ]; then echo "tlc.sh: $c of spec/WatchWindow.tla should break an invariant (TLC exit $rc)"; exit 1; fi
  echo "tlc.sh: $c breaks an invariant, as it must"
done
java -Xmx1g -XX:+UseParallelGC -cp "$TLA2TOOLS" tlc2.TLC -deadlock -workers 4 -metadir "$meta/CommitBuffer" -config CommitBuffer.cfg CommitBuffer.tla
# each variant of the commit buffer that drops a part of its rule must break an invariant
for c in CommitBufferTrust CommitBufferEarly CommitBufferCkpt CommitBufferMany; do
  rc=0
  java -Xmx1g -XX:+UseParallelGC -cp "$TLA2TOOLS" tlc2.TLC -deadlock -workers 1 -metadir "$meta/$c" -config $c.cfg CommitBuffer.tla || rc=$?
  if [ "$rc" -ne 12 ]; then echo "tlc.sh: $c of spec/CommitBuffer.tla should break an invariant (TLC exit $rc)"; exit 1; fi
  echo "tlc.sh: $c breaks an invariant, as it must"
done
# the background path of a rule change, its invariants and its liveness (it ends)
java -Xmx1g -XX:+UseParallelGC -cp "$TLA2TOOLS" tlc2.TLC -deadlock -workers 4 -metadir "$meta/RuleChange" -config RuleChange.cfg RuleChange.tla
# each variant of the background path that drops a part of its rule must break an invariant
for c in RuleChangeCopy RuleChangeLate RuleChangeEarlyExpect RuleChangeNoCheck RuleChangeOverlap RuleChangeStale RuleChangePublished RuleChangeTakeBack RuleChangeShadowed RuleChangeUntracked RuleChangeNoTombstone RuleChangeNamed RuleChangeMergeSkipsRun; do
  rc=0
  java -Xmx1g -XX:+UseParallelGC -cp "$TLA2TOOLS" tlc2.TLC -deadlock -workers 1 -metadir "$meta/$c" -config $c.cfg RuleChange.tla || rc=$?
  if [ "$rc" -ne 12 ]; then echo "tlc.sh: $c of spec/RuleChange.tla should break an invariant (TLC exit $rc)"; exit 1; fi
  echo "tlc.sh: $c breaks an invariant, as it must"
done
# each must break an invariant: TLC exits with 12 and prints the counterexample
for c in LocalReadsLive LocalReadsNoSkip LocalReadsEarly LocalReadsRemoteFirst LocalReadsDesign LocalReadsDraft; do
  rc=0
  java -Xmx1g -XX:+UseParallelGC -cp "$TLA2TOOLS" tlc2.TLC -deadlock -workers 1 -metadir "$meta/$c" -config $c.cfg LocalReads.tla || rc=$?
  if [ "$rc" -ne 12 ]; then echo "tlc.sh: $c of spec/LocalReads.tla should break an invariant (TLC exit $rc)"; exit 1; fi
  echo "tlc.sh: $c breaks an invariant, as it must"
done
# Raft by parts, then each rule removed alone
for c in RaftCore RaftDamage RaftLease; do
  java -Xmx1600m -XX:+UseParallelGC -cp "$TLA2TOOLS" tlc2.TLC -deadlock -workers 4 -metadir "$meta/$c" -config $c.cfg Raft.tla
done
for c in RaftCommitOldTerm RaftVolatileVote RaftAckUnforced RaftNoUpToDate RaftNoAbstain RaftNoStickiness RaftPromiseFirst RaftRestartForgets RaftReadEarly; do
  rc=0
  java -Xmx1600m -XX:+UseParallelGC -cp "$TLA2TOOLS" tlc2.TLC -deadlock -workers 4 -metadir "$meta/$c" -config $c.cfg Raft.tla || rc=$?
  if [ "$rc" -ne 12 ]; then echo "tlc.sh: $c of spec/Raft.tla should break an invariant (TLC exit $rc)"; exit 1; fi
  echo "tlc.sh: $c breaks an invariant, as it must"
done
# the naive sale must break an invariant: TLC exits with 12 (a safety violation) and prints the counterexample
rc=0
java -Xmx1g -XX:+UseParallelGC -cp "$TLA2TOOLS" tlc2.TLC -deadlock -workers 1 -metadir "$meta/naive" -config SeatsNaive.cfg Seats.tla || rc=$?
if [ "$rc" -ne 12 ]; then echo "tlc.sh: the naive sale of spec/Seats.tla should break an invariant (TLC exit $rc)"; exit 1; fi
echo "tlc.sh: the naive sale breaks an invariant, as it must"
