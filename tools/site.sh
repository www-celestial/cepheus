#!/bin/sh
# The site of Cepheus as cesia doc --site makes it: its book, and the reference of its Cesia package under the name a program
# writes, deps/www-celestial/cepheus/cesia/cepheus. The book's Cesia examples use the package as a program does, so the
# site is built from a project of its own that holds the package in deps/ as cesia pkg puts it, as test/cesia.sh does to run
# them against a server; the site checks them without running them (they are norun: it has no server).
#   tools/site.sh FOLDER     writes the site in FOLDER, with the cesia of the PATH
set -eu
cd "$(dirname "$0")/.."
root=$PWD
mkdir -p "$1"
out=$(cd "$1" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -R docs "$work/"
for f in README.md README.fr.md; do [ ! -f "$f" ] || cp "$f" "$work/"; done
dep=$work/deps/www-celestial/cepheus
mkdir -p "$dep/cesia"
cp cesia.toml "$dep/"
cp -R cesia/cepheus "$dep/cesia/"
{
  printf '[project]\nname = "cepheus-site"\nsrc = []\n\n[deps.cepheus]\nfrom = "github.com/www-celestial/cepheus"\n'
  printf 'version = "v0.1.0"\ntake = ["cesia/cepheus"]\n\n'
  sed -n '/^\[site\]$/,$p' cesia.toml
} > "$work/cesia.toml"
cd "$work"
cesia run --allow read,write "$root/tools/lock.ce"
cesia doc --site "$out"
