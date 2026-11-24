#!/bin/sh
# cepheus import and cepheus export beside PostgreSQL's COPY (sql-copy.html) and SQLite's .import (cli.html), on the
# same CSV files (bench/tbench.ml): CLIENTS clients (Name, City, Email unique) and 20 invoices each (Client: the
# client's Email, Total with cents, Status, Date): 83 facts a client, 10 M facts at 120,482 clients. Each side loads
# the clients, then the invoices with their link found by the client's e-mail, durably, as a user of it would:
#   Cepheus   a server of its own (`cepheus serve`), its kinds declared, `cepheus import` of each file;
#   PostgreSQL 18 (bench/pg/pg.sh's cluster, port 5547): \copy client (UNIQUE email), \copy of the invoices into a
#             table of their text, then INSERT ... SELECT joined on the e-mail (the link by key), in one transaction;
#   SQLite    .import --csv of each file into a table of its own, then INSERT ... SELECT joined on the e-mail, in one
#             transaction (UNIQUE email), the file in the default journal mode, synchronous FULL.
# Then each exports the invoices with the client's e-mail: `cepheus export --format csv`, COPY (SELECT ... JOIN) TO
# STDOUT, sqlite3 -csv. Time: wall clock; memory: the peak resident set (VmHWM) of the command and of the server.
# The sides alternate, ROUNDS rounds (7), each on new files.
#   bench/transfer.sh DIR CLIENTS [ROUNDS]       DIR: a short path (the server's Unix socket is under it)
set -e
dir=$1; n=$2; rounds=${3:-7}
here=$(cd "$(dirname "$0")/.." && pwd)
B=$here/_build/default/bin/main.exe
T=$here/_build/default/bench/tbench.exe
mkdir -p "$dir/csv"
[ -f "$dir/csv/invoice.csv" ] || $T gen "$dir/csv" "$n"
csv=$dir/csv
port=$((7460 + $$ % 100))
peak() { awk '/VmHWM/ {print int($2 / 1024)}' "/proc/$1/status"; }
now() { date +%s.%N; }
# "seconds peak_mb" of a command: the wall clock, and the peak resident set of the largest process it ran (getrusage)
timed() {
  python3 -I -c 'import resource, subprocess, sys, time
t = time.time(); r = subprocess.call(sys.argv[2:]); t = time.time() - t
open(sys.argv[1], "w").write("%.2f %d" % (t, resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss // 1024)); sys.exit(r)' "$dir/time" "$@"
  cat "$dir/time"
}

cepheus_side() {
  rm -rf "$dir/c"
  $B cluster init bench --dir "$dir/c" > /dev/null
  sed -i "s/127.0.0.1:7400/127.0.0.1:$port/; s/name = \"main\"/name = \"shop\"/" "$dir/c/cluster.toml"
  CEPHEUS_TOKEN=$($B token add bench --database shop=write --config "$dir/c/cluster.toml" 2> /dev/null)
  export CEPHEUS_TOKEN
  setsid $B serve --config "$dir/c/cluster.toml" < /dev/null > "$dir/c/serve.log" 2>&1 &
  spid=$!
  for _ in $(seq 200); do [ -S "$dir/c/run/.s.cepheus.$port" ] && break; sleep 0.05; done
  $T declare "$dir/c/run/.s.cepheus.$port" shop
  base=$(peak $spid)
  c=$(timed $B import shop "$csv/client.csv" --kind client --config "$dir/c/cluster.toml" 2> "$dir/c/import.err")
  i=$(timed $B import shop "$csv/invoice.csv" --kind invoice --config "$dir/c/cluster.toml" 2>> "$dir/c/import.err")
  e=$(timed sh -c "exec $B export shop --kind invoice --format csv --config $dir/c/cluster.toml > $dir/c/out.csv 2>> $dir/c/import.err")
  echo "cepheus clients $c invoices $i export $e server_peak_mb $(peak $spid) server_base_mb $base disk_mb $(du -sm "$dir/c/data" | cut -f1) rows_out $(($(wc -l < "$dir/c/out.csv") - 1))"
  kill $spid; wait $spid 2> /dev/null || true
  for d in "$dir"/c/data/*/; do [ -f "$d/cepheus" ] && rm -f "/dev/shm/cepheus-$(od -An -tx1 -j17 -N16 "$d/cepheus" | tr -d ' \n').visible"; done
  rm -rf "$dir/c"
}

pg_side() {
  export PGHOST="$dir/pg/sock" PGPORT=5547 PGDATABASE=bench
  if [ ! -d "$dir/pg/data" ]; then PGPORT=5547 sh "$here/bench/pg/pg.sh" init "$dir/pg"; fi
  PGPORT=5547 sh "$here/bench/pg/pg.sh" start "$dir/pg" 4G
  psql -X -q -v ON_ERROR_STOP=1 <<EOF
DROP TABLE IF EXISTS invoice, invoice_in, client;
CREATE TABLE client (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, name text NOT NULL, city text NOT NULL, email text NOT NULL UNIQUE);
CREATE TABLE invoice (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, client bigint NOT NULL REFERENCES client, total numeric(14,2) NOT NULL, status text NOT NULL, date timestamptz NOT NULL);
EOF
  t0=$(now)
  psql -X -q -v ON_ERROR_STOP=1 -c "\\copy client (name, city, email) FROM '$csv/client.csv' WITH (FORMAT csv, HEADER true)"
  t1=$(now)
  psql -X -q -v ON_ERROR_STOP=1 <<EOF > "$dir/pg.out"
SELECT pg_backend_pid() AS pid \gset
\setenv PID :pid
BEGIN;
CREATE TEMP TABLE invoice_in (client text, total numeric(14,2), status text, date timestamptz);
\copy invoice_in FROM '$csv/invoice.csv' WITH (FORMAT csv, HEADER true)
INSERT INTO invoice (client, total, status, date) SELECT c.id, i.total, i.status, i.date FROM invoice_in i JOIN client c ON c.email = i.client;
COMMIT;
\! awk '/VmHWM/ {print int(\$2 / 1024)}' /proc/\$PID/status
EOF
  t2=$(now)
  e=$(timed psql -X -q -c "\\copy (SELECT c.email, i.total, i.status, i.date FROM invoice i JOIN client c ON c.id = i.client ORDER BY i.id) TO '$dir/pg-out.csv' WITH (FORMAT csv, HEADER true)")
  echo "postgres clients $(awk "BEGIN{print $t1 - $t0}") invoices $(awk "BEGIN{print $t2 - $t1}") backend_peak_mb $(cat "$dir/pg.out") export $e disk_mb $(psql -X -At -c "SELECT pg_database_size('bench') / 1048576")"
  PGPORT=5547 sh "$here/bench/pg/pg.sh" stop "$dir/pg" > /dev/null
}

sqlite_side() {
  rm -f "$dir/s.db" "$dir/s.db-journal"
  cat > "$dir/s.sql" <<EOF
PRAGMA synchronous = FULL;
CREATE TABLE client (id INTEGER PRIMARY KEY, name TEXT NOT NULL, city TEXT NOT NULL, email TEXT NOT NULL UNIQUE);
CREATE TABLE invoice (id INTEGER PRIMARY KEY, client INTEGER NOT NULL REFERENCES client, total TEXT NOT NULL, status TEXT NOT NULL, date TEXT NOT NULL);
.import --csv $csv/client.csv client_in
INSERT INTO client (name, city, email) SELECT Name, City, Email FROM client_in;
DROP TABLE client_in;
EOF
  cat > "$dir/s2.sql" <<EOF
PRAGMA synchronous = FULL;
BEGIN;
.import --csv $csv/invoice.csv invoice_in
INSERT INTO invoice (client, total, status, date) SELECT c.id, i.Total, i.Status, i.Date FROM invoice_in i JOIN client c ON c.email = i.Client;
DROP TABLE invoice_in;
COMMIT;
EOF
  c=$(timed sqlite3 "$dir/s.db" < "$dir/s.sql")
  i=$(timed sqlite3 "$dir/s.db" < "$dir/s2.sql")
  e=$(timed sh -c "exec sqlite3 -csv -header $dir/s.db 'SELECT c.email, i.total, i.status, i.date FROM invoice i JOIN client c ON c.id = i.client ORDER BY i.id' > $dir/s-out.csv")
  echo "sqlite clients $c invoices $i export $e disk_mb $(du -m "$dir/s.db" | cut -f1)"
  rm -f "$dir/s.db" "$dir/s-out.csv"
}

# BIG=BYTES: then a file of BYTES of invoices (13 clients' rows over and over, so that a folder compressed by btrfs,
# chattr +c, holds it in a fraction of its size), its last row bad: the import checks it whole, streaming, refuses
# the last row and writes nothing; its time and peak memory
big_side() {
  rm -rf "$dir/c" "$dir/big"
  mkdir -p "$dir/big"
  chattr +c "$dir/big" 2> /dev/null || true
  $T big "$dir/big/invoices.csv" "$BIG" 13
  $B cluster init bench --dir "$dir/c" > /dev/null
  sed -i "s/127.0.0.1:7400/127.0.0.1:$port/; s/name = \"main\"/name = \"shop\"/" "$dir/c/cluster.toml"
  CEPHEUS_TOKEN=$($B token add bench --database shop=write --config "$dir/c/cluster.toml" 2> /dev/null)
  export CEPHEUS_TOKEN
  setsid $B serve --config "$dir/c/cluster.toml" < /dev/null > "$dir/c/serve.log" 2>&1 &
  spid=$!
  for _ in $(seq 200); do [ -S "$dir/c/run/.s.cepheus.$port" ] && break; sleep 0.05; done
  $T declare "$dir/c/run/.s.cepheus.$port" shop
  $B import shop "$csv/client.csv" --kind client --config "$dir/c/cluster.toml" 2> /dev/null
  r=$(timed $B import shop "$dir/big/invoices.csv" --kind invoice --config "$dir/c/cluster.toml" 2> "$dir/big.err" || true)
  echo "big $(du -b "$dir/big/invoices.csv" | cut -f1) bytes ($(du -sm "$dir/big" | cut -f1) MB on the disk): $r; $(tail -1 "$dir/big.err")"
  kill $spid; wait $spid 2> /dev/null || true
  for d in "$dir"/c/data/*/; do [ -f "$d/cepheus" ] && rm -f "/dev/shm/cepheus-$(od -An -tx1 -j17 -N16 "$d/cepheus" | tr -d ' \n').visible"; done
  rm -rf "$dir/c" "$dir/big"
}

for r in $(seq "$rounds"); do
  echo "round $r"
  cepheus_side
  [ -z "$NOPG" ] && pg_side
  [ -z "$NOSQLITE" ] && sqlite_side
done
[ -n "$BIG" ] && big_side
