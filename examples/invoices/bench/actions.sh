#!/bin/sh
# The app's actions (bench/load): an invoice made, a client made, an invoice paid, a sign-in, each with 1 client then
# 50, ROUNDS rounds (21), on the seed of bench/run.sh (OUT/srv, its server running; its users made by bench/run.sh OUT
# pages). One line of JSON a measure in OUT/actions.jsonl.
#   bench/actions.sh OUT [ACTION...]     (invoice client pay signin by default; their lines replace those of the file)
set -e
cd "$(dirname "$0")/.."
out=$(cd "$1" && pwd)
rounds=${ROUNDS:-21}
app=8093
srv=$out/srv
. bench/server.sh
serve_seeded
base=http://127.0.0.1:$app
export CEPHEUS_URL="cepheus://localhost:7463/invoices?socket=$out/srv/run" CEPHEUS_TOKEN=$(cat "$out/srv/web.token") CEPHEUS_BOOKS_TOKEN=$(cat "$out/srv/books.token") APP_PORT=$app
setsid cesia run --allow native=cepheus,ffi=sodium,env,net=:$app src/main.ce < /dev/null 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- > "$out/actions-app.log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null; while kill -0 $pid 2>/dev/null; do sleep 0.02; done; [ -z "$started_here" ] || stop' EXIT
until (exec 3<>/dev/tcp/127.0.0.1/$app) 2>/dev/null; do sleep 0.01; done
sid() { curl -s -D - -o /dev/null -H "Origin: $base" -d "login=$1&password=$2" "$base/login" | sed -n 's/^set-cookie: sid=\([0-9a-f]*\);.*/\1/p'; }
export BENCH_SID=$(sid bench "bench+password+1")
shift
whats=${*:-invoice client pay signin}
touch "$out/actions.jsonl"
for what in $whats; do grep -v "\"What\":\"$what\"" "$out/actions.jsonl" > "$out/actions.tmp" || true; mv "$out/actions.tmp" "$out/actions.jsonl"; done
for r in $(seq "$rounds"); do
  for c in 1 50; do
    for what in $whats; do
      n=$([ $what = signin ] && echo 10 || echo 50)
      [ $c = 1 ] || n=$([ $what = signin ] && echo 50 || echo 200)
      cesia run --allow native=cepheus,env,net=127.0.0.1 bench/load/load.ce "$base" $what $c $n >> "$out/actions.jsonl"
    done
  done
done
