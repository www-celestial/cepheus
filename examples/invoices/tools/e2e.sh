#!/bin/sh
# The end-to-end tests (tests/e2e): a Cepheus server of their own in a new folder, with the app's two tokens; the tests
# serve the app themselves and drive Firefox through Ceti, which tools/deps.sh puts in deps/ (CETI=...). At the end
# the server stops and its folder goes, whatever happened.
#   CETI=~/ceti tools/deps.sh && tools/e2e.sh [PATH [OPTIONS of cesia test]]   (PATH: tests/e2e by default)
set -e
cd "$(dirname "$0")/.."
app=$PWD
B=cepheus
[ -d deps/www-celestial/ceti ] || { echo "no Ceti in deps/: run CETI=<a checkout of Ceti> tools/deps.sh"; exit 1; }
tmp=$(mktemp -d "${E2E_TMP:-${TMPDIR:-/tmp}}/e2e.XXXXXX")
port=$((21000 + $$ % 20000))
$B cluster init e2e --dir "$tmp/s" > /dev/null
sed -i "s/127.0.0.1:7400/127.0.0.1:$port/; s/^cache = \"1G\"/cache = \"128M\"/; s/^name = \"main\"/name = \"invoices\"/" "$tmp/s/cluster.toml"
CEPHEUS_TOKEN=$($B token add web --database invoices=write --config "$tmp/s/cluster.toml" 2>/dev/null)
CEPHEUS_BOOKS_TOKEN=$($B token add books --database "invoices=read:invoice,line,counter;add:invoice,line,counter" --config "$tmp/s/cluster.toml" 2>/dev/null)
export CEPHEUS_TOKEN CEPHEUS_BOOKS_TOKEN CEPHEUS_URL="cepheus://localhost:$port/invoices?socket=$tmp/s/run"
setsid $B serve --config "$tmp/s/cluster.toml" < /dev/null > "$tmp/serve.log" 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
pid=$!
stop() {
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  for d in "$tmp"/s/data/*/; do
    if [ -f "$d/cepheus" ]; then rm -f "/dev/shm/cepheus-$(od -An -tx1 -j17 -N16 "$d/cepheus" | tr -d ' \n').visible"; fi
  done
  rm -rf "$tmp"
}
trap stop EXIT
trap 'exit 1' INT TERM
for _ in $(seq 100); do grep -q ready "$tmp/serve.log" && break; sleep 0.05; done
path=${1:-tests/e2e}
[ $# -gt 0 ] && shift
cesia test "$path" "$@" --allow "env,exec=firefox,net=127.0.0.1,read=.cesia/firefox,write=.cesia/firefox"
