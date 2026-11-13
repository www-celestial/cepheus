#!/bin/sh
# The measures of docs/book/app.md, ROUNDS rounds (21 by default), at the size of the seed (10,000 clients, 100,000
# invoices), on a Cepheus server of their own in OUT/srv:
#   bench/run.sh OUT seed      the seed, each round into an empty database; the server's start at that size
#   bench/run.sh OUT pages     the app's start; each page with 1 client then 50 (ApacheBench); the rounds
#                              alternate the pages. The actions: bench/actions.sh
# Each line of OUT/*.jsonl is one measure of one round; bench/stats.ce gives their medians. Run each part alone on the
# machine (under the machine's lock): another program's work is noise in every number. Each part stops the servers
# it started (bench/server.sh), so that nothing outlives it.
set -e
cd "$(dirname "$0")/.."
out=$(cd "$1" && pwd)
part=$2
rounds=${ROUNDS:-21}
srv=$out/srv
port=7463
app=8093
base=http://127.0.0.1:$app
url="cepheus://localhost:$port/invoices?socket=$srv/run"
now() { date +%s%N; }
. bench/server.sh

visible() {
  for d in "$srv"/data/*/; do
    if [ -f "$d/cepheus" ]; then echo "/dev/shm/cepheus-$(od -An -tx1 -j17 -N16 "$d/cepheus" | tr -d ' \n').visible"; fi
  done
}
empty() {
  [ -f "$out/serve.pid" ] && stop
  for f in $(visible); do rm -f "$f"; done
  rm -rf "$srv"
  $B cluster init bench --dir "$srv" > /dev/null
  sed -i "s/127.0.0.1:7400/127.0.0.1:$port/; s/^name = \"main\"/name = \"invoices\"/" "$srv/cluster.toml"
  (umask 077
   $B token add web --database invoices=write --config "$srv/cluster.toml" > "$srv/web.token" 2>/dev/null
   $B token add books --database "invoices=read:invoice,line;add:invoice,line" --config "$srv/cluster.toml" > "$srv/books.token" 2>/dev/null)
  : > "$out/serve.log"
  serve 0
}
export CEPHEUS_URL="$url"

if [ "$part" = seed ]; then
  trap stop EXIT
  : > "$out/seed.jsonl"
  for r in $(seq "$rounds"); do
    empty
    export CEPHEUS_TOKEN=$(cat "$srv/web.token")
    t0=$(now)
    cesia run --allow native=cepheus,env src/seed/seed.ce > "$out/seed.out"
    t1=$(now)
    echo "{\"What\":\"seed\",\"Ms\":$(( (t1 - t0) / 1000000 ))}" >> "$out/seed.jsonl"
  done
  du -sb "$srv/data" | awk '{print "{\"What\":\"data bytes\",\"Bytes\":" $1 "}"}' >> "$out/seed.jsonl"
  # the server's start on the seeded database: its own line, ready in N ms
  for r in $(seq "$rounds"); do
    stop
    n=$(grep -c ready "$out/serve.log")
    serve "$n"
    grep ready "$out/serve.log" | tail -1 | sed 's/.*ready in \([0-9.]*\) ms.*/{"What":"cepheus start","Ms":\1}/' >> "$out/seed.jsonl"
  done
  exit 0
fi

# pages: the seeded database of the seed part, two users, the app
serve_seeded
export CEPHEUS_TOKEN=$(cat "$srv/web.token") CEPHEUS_BOOKS_TOKEN=$(cat "$srv/books.token") APP_PORT=$app
APP_LOGIN=bench APP_ROLE=admin APP_PASSWORD="bench password 1" cesia run --allow native=cepheus,ffi=sodium,env src/users/users.ce > /dev/null 2>&1 || true
APP_LOGIN=books APP_ROLE=accountant APP_PASSWORD="books password 1" cesia run --allow native=cepheus,ffi=sodium,env src/users/users.ce > /dev/null 2>&1 || true
apppid=""
startapp() {
  setsid cesia run --allow native=cepheus,ffi=sodium,env,net=:$app src/main.ce < /dev/null 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- > "$out/app.log" 2>&1 &
  apppid=$!
}
stopapp() { [ -n "$apppid" ] && kill "$apppid" 2>/dev/null; while [ -n "$apppid" ] && kill -0 "$apppid" 2>/dev/null; do sleep 0.02; done; apppid=""; }
trap 'stopapp; [ -z "$started_here" ] || stop' EXIT
: > "$out/pages.jsonl"
# the app's start: from the command to its port accepting a connection
for r in $(seq "$rounds"); do
  t0=$(now)
  startapp
  until (exec 3<>/dev/tcp/127.0.0.1/$app) 2>/dev/null; do :; done
  t1=$(now)
  echo "{\"What\":\"app start\",\"Ms\":$(( (t1 - t0) / 100000 ))e-1}" >> "$out/pages.jsonl"
  stopapp
done
startapp
until (exec 3<>/dev/tcp/127.0.0.1/$app) 2>/dev/null; do sleep 0.01; done
sid() { curl -s -D - -o /dev/null -H "Origin: $base" -d "login=$1&password=$2" "$base/login" | sed -n 's/^set-cookie: sid=\([0-9a-f]*\);.*/\1/p'; }
export BENCH_SID=$(sid bench "bench+password+1") BENCH_BOOKS_SID=$(sid books "books+password+1")
client=$(cesia run --allow native=cepheus,env bench/ids/ids.ce client)
invoice=$(cesia run --allow native=cepheus,env bench/ids/ids.ce invoice)
deep=$(printf '{"Invoice":1,"Number":50000,"Status":"","Due":0,"X":0}' | base64 -w0 | sed 's/+/%2B/g; s|/|%2F|g; s/=/%3D/g')
ab1() {  # ab1 WHAT PATH C N [cookie]
  ab -n "$4" -c "$3" -C "sid=${5:-$BENCH_SID}" -e "$out/ab.csv" "$base$2" > "$out/ab.out" 2>&1 || { cat "$out/ab.out"; exit 1; }
  rps=$(sed -n 's/^Requests per second: *\([0-9.]*\).*/\1/p' "$out/ab.out")
  bad=$(sed -n 's/^Non-2xx responses: *\([0-9]*\).*/\1/p' "$out/ab.out")
  failed=$(sed -n 's/^Failed requests: *\([0-9]*\).*/\1/p' "$out/ab.out")
  p50=$(sed -n 's/^50,//p' "$out/ab.csv")
  # ab's line 99 is wrong for a few requests (below 100): the largest of 98 and 99 then, or 100 if both are below 50
  p99=$(awk -F, '$1 == 50 { m = $2 } $1 >= 98 && $1 <= 99 && $2 > p { p = $2 } $1 == 100 { x = $2 } END { print (p < m ? x : p) }' "$out/ab.csv")
  echo "{\"What\":\"$1\",\"C\":$3,\"N\":$4,\"Rps\":$rps,\"P50\":$p50,\"P99\":$p99,\"Failed\":$(( ${failed:-0} + ${bad:-0} ))}" >> "$out/pages.jsonl"
}
for r in $(seq "$rounds"); do
  for c in 1 50; do
    n=$([ $c = 1 ] && echo 200 || echo 2000)
    ab1 "floor: /app.css" /app.css $c $n
    ab1 "sign-in page" /login $c $n
    ab1 dashboard / $c $n
    ab1 clients /clients $c $n
    ab1 "clients, search as one types" "/clients?part=rows&q=ma" $c $n
    ab1 "a client" "/clients/$client" $c $n
    ab1 invoices /invoices $c $n
    ab1 "invoices, a page 50,000 deep" "/invoices?after=$deep" $c $n
    ab1 "invoices, unpaid or late (In)" "/invoices?unpaid=1&late=1" $c $n
    ab1 "invoices, late or due in a week (Or)" "/invoices?action=1" $c $n
    ab1 "invoices, as the accountant" /invoices $c $n "$BENCH_BOOKS_SID"
    ab1 "an invoice" "/invoices/$invoice" $c $n
    ab1 "new invoice form" "/invoices/new?client=$client" $c $n
    ab1 "CSV of the late invoices" "/invoices.csv?late=1" $c $([ $c = 1 ] && echo 10 || echo 50)
  done
done
