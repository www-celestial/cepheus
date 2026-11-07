#!/bin/sh
# PostgreSQL side of the benchmarks, on a cluster of our own (never the system's): ROOT/data, socket in ROOT/sock,
# port 5544, fsync, synchronous_commit and full_page_writes on (the defaults).
#   pg.sh init ROOT            initdb and the configuration
#   pg.sh start ROOT MEM       start the server in a systemd scope capped at MEM (the cache counts in the cap)
#   pg.sh load ROOT CSVDIR     tables as a PostgreSQL user would write them, COPY, indexes, ANALYZE
#   pg.sh read ROOT NCLIENTS   Q1-Q5: through the socket (pgbench, prepared) and inside the server (engine only);
#                              WORKERS=k allows k parallel workers a query (k + 1 processes; default: PostgreSQL's, 2)
#   pg.sh write ROOT NCLIENTS CLIENTS SECS   durable inserts of an invoice row
#   pg.sh stop ROOT
set -e
cmd=$1; root=$2
here=$(cd "$(dirname "$0")" && pwd)
export PGHOST="$root/sock" PGPORT=5544 PGDATABASE=bench
psql_() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }

[ -n "$WORKERS" ] && export PGOPTIONS="-c max_parallel_workers_per_gather=$WORKERS -c max_parallel_workers=$WORKERS"

case "$cmd" in
init)
  mkdir -p "$root/sock"
  initdb -D "$root/data" -A trust -E UTF8 --no-locale >/dev/null
  cat >> "$root/data/postgresql.conf" <<EOF
listen_addresses = ''
unix_socket_directories = '$root/sock'
port = 5544
shared_buffers = 1GB
work_mem = 64MB
max_connections = 300
max_wal_size = 4GB
fsync = on
synchronous_commit = on
full_page_writes = on
EOF
  ;;
start)
  systemd-run --user --scope -q -p MemoryMax="$3" pg_ctl -D "$root/data" -l "$root/log" -w start >/dev/null
  createdb bench 2>/dev/null || true
  ;;
load)
  csv=$3
  t0=$(date +%s.%N)
  psql_ <<EOF
DROP TABLE IF EXISTS follows, invoice, client;
CREATE TABLE client (id int PRIMARY KEY, name text NOT NULL, city text NOT NULL, email text NOT NULL UNIQUE);
CREATE TABLE invoice (id int PRIMARY KEY, client int NOT NULL REFERENCES client, total bigint NOT NULL,
                      status text NOT NULL, date int NOT NULL);
CREATE TABLE follows (a int NOT NULL REFERENCES client, b int NOT NULL REFERENCES client, PRIMARY KEY (a, b));
\copy client FROM '$csv/client.csv' WITH (FORMAT csv)
\copy invoice FROM '$csv/invoice.csv' WITH (FORMAT csv)
\copy follows FROM '$csv/follows.csv' WITH (FORMAT csv)
CREATE INDEX ON client (city);
CREATE INDEX ON invoice (client);
CREATE INDEX ON invoice (status);
CREATE INDEX ON follows (b, a);
CREATE SEQUENCE invoice_seq START 100000000;
VACUUM ANALYZE;
CHECKPOINT;
EOF
  t1=$(date +%s.%N)
  echo "postgres load: $(awk "BEGIN{print $t1 - $t0}") s (COPY, indexes, VACUUM ANALYZE); size $(psql -X -At -c "SELECT pg_size_pretty(pg_database_size('bench'))")"
  ;;
read)
  n=$3
  ninv=$((n * 20))
  # warm the cache as the Cepheus side is warm (its snapshot is verified, so read, at open)
  psql_ -c "SELECT count(*) FROM invoice" -c "SELECT count(*) FROM client" -c "SELECT count(*) FROM follows" >/dev/null
  # checks: the same answers as Cepheus
  echo "Q3 rows city-7: $(psql -X -At -c "SELECT count(*) FROM client c JOIN invoice i ON i.client = c.id WHERE c.city = 'city-7' AND i.status = 'unpaid'")"
  echo "Q4 count, sum: $(psql -X -At -F' ' -c "SELECT count(*), sum(i.total) FROM invoice i JOIN client c ON c.id = i.client WHERE i.status = 'unpaid'")"
  echo "Q5 rotations: $(psql -X -At -c "SELECT count(*) FROM follows f1 JOIN follows f2 ON f2.a = f1.b JOIN follows f3 ON f3.a = f2.b AND f3.b = f1.a")"
  tmp=$(mktemp -d)
  printf '\\set k random(0, %d)\nSELECT * FROM invoice WHERE id = :k;\n' $((ninv - 1)) > "$tmp/q1.sql"
  printf '\\set k random(0, %d)\nSELECT * FROM client WHERE email = '"'"'c'"'"' || :k || '"'"'@example.com'"'"';\n' $((n - 1)) > "$tmp/q2.sql"
  printf '\\set k random(0, 99)\nSELECT i.id, i.total FROM client c JOIN invoice i ON i.client = c.id WHERE c.city = '"'"'city-'"'"' || :k AND i.status = '"'"'unpaid'"'"';\n' > "$tmp/q3.sql"
  for q in q1 q2 q3; do
    for r in 1 2 3; do
      pgbench -n -M prepared -c 1 -j 1 -T 5 -f "$tmp/$q.sql" bench 2>/dev/null | sed -n "s/latency average = \(.*\)/$q through the socket: \1/p"
    done
  done
  rm -rf "$tmp"
  # inside the server: plpgsql loops (cached plans), and EXPLAIN ANALYZE execution times
  for r in 1 2 3; do
  psql_ <<EOF
DO \$\$ DECLARE t0 timestamptz; x record; BEGIN
  t0 := clock_timestamp();
  FOR i IN 1..200000 LOOP SELECT * INTO x FROM invoice WHERE id = (i * 7919) % $ninv; END LOOP;
  RAISE NOTICE 'Q1 engine only: % us', round((extract(epoch FROM clock_timestamp() - t0) * 1e6 / 200000)::numeric, 2);
  t0 := clock_timestamp();
  FOR i IN 1..200000 LOOP SELECT * INTO x FROM client WHERE email = 'c' || ((i * 7919) % $n) || '@example.com'; END LOOP;
  RAISE NOTICE 'Q2 engine only: % us', round((extract(epoch FROM clock_timestamp() - t0) * 1e6 / 200000)::numeric, 2);
END \$\$;
EOF
  done
  # the processes each question used: the leader and the workers it launched
  for q in "SELECT c.city, sum(i.total), count(*) FROM invoice i JOIN client c ON c.id = i.client WHERE i.status = 'unpaid' GROUP BY c.city" \
           "SELECT count(*) FROM follows f1 JOIN follows f2 ON f2.a = f1.b JOIN follows f3 ON f3.a = f2.b AND f3.b = f1.a"; do
    echo "workers launched: $(psql -X -At -c "EXPLAIN (ANALYZE, TIMING OFF) $q" | sed -n 's/.*Workers Launched: //p' | tr '\n' ' ')"
  done
  for r in 1 2 3 4 5; do
    printf 'Q3 engine only: %s\n' "$(psql -X -At -c "EXPLAIN (ANALYZE, TIMING OFF) SELECT i.id, i.total FROM client c JOIN invoice i ON i.client = c.id WHERE c.city = 'city-7' AND i.status = 'unpaid'" | sed -n 's/Execution Time: //p')"
    printf 'Q4 engine only: %s\n' "$(psql -X -At -c "EXPLAIN (ANALYZE, TIMING OFF) SELECT c.city, sum(i.total), count(*) FROM invoice i JOIN client c ON c.id = i.client WHERE i.status = 'unpaid' GROUP BY c.city" | sed -n 's/Execution Time: //p')"
    printf 'Q5 engine only: %s\n' "$(psql -X -At -c "EXPLAIN (ANALYZE, TIMING OFF) SELECT count(*) FROM follows f1 JOIN follows f2 ON f2.a = f1.b JOIN follows f3 ON f3.a = f2.b AND f3.b = f1.a" | sed -n 's/Execution Time: //p')"
  done
  ;;
write)
  n=$3; c=$4; secs=$5
  tmp=$(mktemp -d)
  printf '\\set c random(0, %d)\n\\set t random(1, 100000)\n\\set d random(0, 3649)\nINSERT INTO invoice (id, client, total, status, date) VALUES (nextval('"'"'invoice_seq'"'"'), :c, :t, '"'"'unpaid'"'"', :d);\n' $((n - 1)) > "$tmp/w.sql"
  j=$c; [ "$j" -gt 8 ] && j=8
  pgbench -n -M prepared -c "$c" -j "$j" -T "$secs" -f "$tmp/w.sql" bench 2>/dev/null | sed -n "s/^\(tps = [0-9.]*\).*/W1 $c clients: \1/p; s/latency average = \(.*\)/W1 $c clients: latency average \1/p"
  rm -rf "$tmp"
  ;;
stop)
  pg_ctl -D "$root/data" -w stop -m fast >/dev/null
  ;;
*) echo "pg.sh init|start|load|read|write|stop ROOT ..."; exit 2 ;;
esac
