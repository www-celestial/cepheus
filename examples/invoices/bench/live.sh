#!/bin/sh
# The dashboard's change in Firefox (bench/live), with 1 page then 10, ROUNDS rounds (21) of 10 payments, on the
# seed of bench/run.sh (OUT/srv, its server running; the user bench made by bench/run.sh OUT pages). Ceti in deps/
# (CETI=... tools/deps.sh). One line of JSON a round in OUT/live.jsonl.
#   bench/live.sh OUT
set -e
cd "$(dirname "$0")/.."
out=$(cd "$1" && pwd)
rounds=${ROUNDS:-21}
app=8093
srv=$out/srv
. bench/server.sh
serve_seeded
export CEPHEUS_URL="cepheus://localhost:7463/invoices?socket=$out/srv/run" CEPHEUS_TOKEN=$(cat "$out/srv/web.token") CEPHEUS_BOOKS_TOKEN=$(cat "$out/srv/books.token") APP_PORT=$app
setsid cesia run --allow native=cepheus,ffi=sodium,env,net=:$app src/main.ce < /dev/null 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- > "$out/live-app.log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null; while kill -0 $pid 2>/dev/null; do sleep 0.02; done; [ -z "$started_here" ] || stop' EXIT
until (exec 3<>/dev/tcp/127.0.0.1/$app) 2>/dev/null; do sleep 0.01; done
: > "$out/live.jsonl"
for k in 1 10; do
  cesia run --allow native=cepheus,env,exec=firefox,net=127.0.0.1,read=.cesia/firefox,write=.cesia/firefox bench/live/live.ce "http://127.0.0.1:$app" $k "$rounds" 10 >> "$out/live.jsonl"
done
