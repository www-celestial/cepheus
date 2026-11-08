#!/bin/sh
# The Cesia client against a real server, as a program uses it: a project of its own that holds the package in
# deps/www-celestial/cepheus (its cesia.toml, its Cesia files and its engine), under the label cepheus, with the
# cesia.lock that cesia pkg would write. Then: the examples of docs/cesia.md (test/cesia-docs.ce: each block with the
# blocks before it, on a database of its own); the client over TLS and through the Unix socket with local reads
# (test/cesia-live.ce); and the server killed with kill -9 and started again while the program writes: every write
# answered Ok is in the database once.
#   test/cesia.sh TMP     the engine in native/ (tools/test.sh puts it there), cesia on the PATH, the server built
set -e
cd "$(dirname "$0")/.."
root=$PWD
tmp=$1/cc  # short: a Unix socket's path holds at most 107 bytes
rm -rf "$tmp"
mkdir -p "$tmp"
B=$root/_build/default/bin/main.exe
tag=$(cesia run tools/tag.ce)
n=$(grep -c '^```cesia' docs/cesia.md)
port=$((20000 + $$ % 20000))

# the server: one database an example, one for TLS, one for the local reads, one for the restart
$B cluster init docs --dir "$tmp/s" > /dev/null
cfg=$tmp/s/cluster.toml
mkdir -p "$tmp/s/r"
sed -i "s/127.0.0.1:7400/127.0.0.1:$port/; s/^socket = \"run\"/socket = \"r\"/; /^\[\[database\]\]/,\$d" "$cfg"
rights=""
for d in $(seq "$n" | sed 's/^/doc/') tls local restart; do
  printf '[[database]]\nname = "%s"\n' "$d" >> "$cfg"
  rights="$rights --database $d=write"
done
# shellcheck disable=SC2086
export CEPHEUS_TOKEN=$($B token add docs $rights --config "$cfg" 2>/dev/null)
# the server in a session of its own, its output in a log: it never holds the pipes of the script's caller; stopped
# when the script ends, whatever ends it
serve() {
  setsid $B serve --config "$cfg" < /dev/null >> "$tmp/serve.log" 2>&1 &
  echo $! > "$tmp/pid"
  for _ in $(seq 100); do [ -S "$tmp/s/r/.s.cepheus.$port" ] && grep -q ready "$tmp/serve.log" && return 0; sleep 0.05; done
  echo "the server did not start:"; cat "$tmp/serve.log"; exit 1
}
prog=""
stop() {
  [ -n "$prog" ] && kill "$prog" 2>/dev/null
  kill "$(cat "$tmp/pid")" 2>/dev/null || true
  wait "$(cat "$tmp/pid")" 2>/dev/null || true
}
trap stop EXIT
trap 'exit 1' INT TERM
serve

# the program's project, the package in deps/ as cesia pkg puts it
app=$tmp/app
dep=$app/deps/www-celestial/cepheus
mkdir -p "$app/src" "$dep/cesia" "$dep/native"
cp cesia.toml "$dep/"
cp -R cesia/cepheus "$dep/cesia/"
cp "native/cepheus-$tag.cmxs" "$dep/native/"
printf '[project]\nname = "app"\nsrc = ["src"]\n\n[deps.cepheus]\nfrom = "github.com/www-celestial/cepheus"\nversion = "v0.1.0"\ntake = ["cesia/cepheus"]\n' > "$app/cesia.toml"
cd "$app"
cesia run --allow read,write "$root/tools/lock.ce"

cesia run --allow read,write,exec,env "$root/test/cesia-docs.ce" "$root/docs/cesia.md" "cepheus://localhost:$port/doc" "?socket=$tmp/s/r"

cp "$root/test/cesia-live.ce" src/live.ce
export CEPHEUS_URL="cepheus://localhost:$port/local?socket=$tmp/s/r" CEPHEUS_TLS="cepheus://127.0.0.1:$port/tls" CEPHEUS_CA="$tmp/s/ca.pem"
cesia run --allow native=cepheus,env,read src/live.ce > "$tmp/live.out" 2>&1 || { cat "$tmp/live.out"; exit 1; }
diff "$root/test/cesia-live.expected" "$tmp/live.out" || { echo "cesia live: the output differs from test/cesia-live.expected"; exit 1; }

# kill -9 while the program writes, then a new server on the same data: the client connects again and sends again
export CEPHEUS_URL="cepheus://localhost:$port/restart?socket=$tmp/s/r"
cesia run --allow native=cepheus,env,read src/live.ce restart < /dev/null > "$tmp/restart.out" 2>&1 &
prog=$!
for _ in $(seq 200); do grep -q ready "$tmp/restart.out" 2>/dev/null && break; sleep 0.02; done
sleep 0.2
kill -9 "$(cat "$tmp/pid")"
wait "$(cat "$tmp/pid")" 2>/dev/null || true
serve
wait $prog || { prog=""; cat "$tmp/restart.out"; exit 1; }
prog=""
grep -q '^restart: 1500 writes answered Ok, 1500 in the database$' "$tmp/restart.out" || { cat "$tmp/restart.out"; exit 1; }
echo "cesia live: TLS, local reads and a kill -9 of the server: $(grep -c . "$root/test/cesia-live.expected") lines as expected, 1500 writes once each"
cd "$root"
stop
trap - EXIT
rm -rf "$tmp"
