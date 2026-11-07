#!/bin/sh
# Model-checks spec/Journal.tla with TLC (bounds in spec/Journal.cfg). TLA2TOOLS names tla2tools.jar, the official
# release from https://github.com/tlaplus/tlaplus/releases (v1.7.4 used here); Java 11 or later.
set -e
cd "$(dirname "$0")/.."
: "${TLA2TOOLS:?set TLA2TOOLS to the path of tla2tools.jar}"
meta=$(mktemp -d)
trap 'rm -rf "$meta"' EXIT
cd spec
java -Xmx1g -XX:+UseParallelGC -cp "$TLA2TOOLS" tlc2.TLC -deadlock -workers 4 -metadir "$meta" -config Journal.cfg Journal.tla
