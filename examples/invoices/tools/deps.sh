#!/bin/sh
# Puts the app's two dependencies in deps/, as `cesia pkg install` would once they have tagged releases, and writes
# cesia.lock: the Cesia package of Cepheus from a checkout of Cepheus (its Cesia code, and its engine built against the
# Cesia that runs the app), and Ceti, the browser driver of the end-to-end tests, from a checkout of it.
#   CEPHEUS=~/cepheus tools/deps.sh                Cepheus only: what the app needs to run
#   CEPHEUS=~/cepheus CETI=~/ceti tools/deps.sh    Ceti too: what tests/e2e needs
# CEPHEUS is ../.. by default: the repository that holds examples/invoices. Its engine is
# _build/default/cesia/native/cepheus.cmxs, built with CESIA_NATIVE set (docs/book/quickstart.md, step 1).
set -e
cd "$(dirname "$0")/.."
repo=${CEPHEUS:-../..}
tag=$(cesia run "$repo/tools/tag.ce")
engine=$repo/_build/default/cesia/native/cepheus.cmxs
[ -f "$engine" ] || { echo "no engine at $engine: build Cepheus with CESIA_NATIVE set (docs/book/quickstart.md)"; exit 1; }
dep=deps/www-celestial/cepheus
rm -rf "$dep"
mkdir -p "$dep/cesia" "$dep/native"
cp "$repo/cesia.toml" "$dep/"
cp -R "$repo/cesia/cepheus" "$dep/cesia/"
cp "$engine" "$dep/native/cepheus-$tag.cmxs"
if [ -n "$CETI" ]; then
  rm -rf deps/www-celestial/ceti
  mkdir -p deps/www-celestial/ceti/src
  cp "$CETI/cesia.toml" deps/www-celestial/ceti/
  cp -R "$CETI/src/browser" deps/www-celestial/ceti/src/
fi
cesia run --allow read,write tools/lock.ce
