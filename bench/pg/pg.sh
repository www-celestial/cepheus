#!/bin/sh
# PostgreSQL side of the benchmarks, on a cluster of our own (never the system's): ROOT/data, socket in ROOT/sock,
# port 5544 (PGPORT=n another), fsync, synchronous_commit and full_page_writes on (the defaults).
#   pg.sh init ROOT            initdb and the configuration
#   pg.sh start ROOT MEM       start the server in a systemd scope capped at MEM (the cache counts in the cap); SHARED=32MB sets
#                              shared_buffers for this start
#   pg.sh load ROOT CSVDIR     tables as a PostgreSQL user would write them, COPY, indexes, ANALYZE
#   pg.sh read ROOT NCLIENTS   Q1-Q5: through the socket (pgbench, prepared) and inside the server (engine only);
#                              WORKERS=k allows k parallel workers a query (k + 1 processes; default: PostgreSQL's, 2);
#                              QS=Q4,Q5 only those; RUNS runs each (21), summarised by bench.exe stats
#   pg.sh write ROOT NCLIENTS CLIENTS SECS   durable inserts of an invoice row; RATE=r inserts a second in all (open loop)
#   pg.sh seats ROOT serializable|naive SEATS BUYERS   the sale of docs/case-seats.md (pgbench, --max-tries)
#   pg.sh stop ROOT
set -e
cmd=$1; root=$2
here=$(cd "$(dirname "$0")" && pwd)
export PGHOST="$root/sock" PGPORT=${PGPORT:-5544} PGDATABASE=bench
psql_() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }

[ -n "$WORKERS" ] && export PGOPTIONS="-c max_parallel_workers_per_gather=$WORKERS -c max_parallel_workers=$WORKERS"

case "$cmd" in
init)
  mkdir -p "$root/sock"
  initdb -D "$root/data" -A trust -E UTF8 --no-locale >/dev/null
  cat >> "$root/data/postgresql.conf" <<EOF
listen_addresses = ''
unix_socket_directories = '$root/sock'
port = $PGPORT
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
  # SHARED=32MB: shared_buffers for this run (1 GB in the configuration), for a run under a small cap
  systemd-run --user --scope -q -p MemoryMax="$3" -p MemorySwapMax=0 pg_ctl -D "$root/data" -l "$root/log" -w \
    ${SHARED:+-o "-c shared_buffers=$SHARED"} start >/dev/null
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
  # QS=Q1,Q4 runs only those; RUNS runs a question (21); each summarised as on the Cepheus side (bench.exe stats)
  n=$3
  ninv=$((n * 20))
  runs=${RUNS:-21}
  qs=${QS:-Q1,Q2,Q3,Q4,Q5}
  asked() { case ",$qs," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
  stats() { "$here/../../_build/default/bench/bench.exe" stats "$1"; }
  q3="SELECT i.id, i.total FROM client c JOIN invoice i ON i.client = c.id WHERE c.city = 'city-7' AND i.status = 'unpaid'"
  q4="SELECT c.city, sum(i.total), count(*) FROM invoice i JOIN client c ON c.id = i.client WHERE i.status = 'unpaid' GROUP BY c.city"
  q5="SELECT count(*) FROM follows f1 JOIN follows f2 ON f2.a = f1.b JOIN follows f3 ON f3.a = f2.b AND f3.b = f1.a"
  # warm the cache as the Cepheus side is warm (its snapshot is verified, so read, at open)
  psql_ -c "SELECT count(*) FROM invoice" -c "SELECT count(*) FROM client" -c "SELECT count(*) FROM follows" >/dev/null
  # checks: the same answers as Cepheus
  echo "Q3 rows city-7: $(psql -X -At -c "SELECT count(*) FROM ($q3) x")"
  echo "Q4 count, sum: $(psql -X -At -F' ' -c "SELECT count(*), sum(i.total) FROM invoice i JOIN client c ON c.id = i.client WHERE i.status = 'unpaid'")"
  echo "Q5 rotations: $(psql -X -At -c "$q5")"
  tmp=$(mktemp -d -p "$root")
  printf '\\set k random(0, %d)\nSELECT * FROM invoice WHERE id = :k;\n' $((ninv - 1)) > "$tmp/Q1.sql"
  printf '\\set k random(0, %d)\nSELECT * FROM client WHERE email = '"'"'c'"'"' || :k || '"'"'@example.com'"'"';\n' $((n - 1)) > "$tmp/Q2.sql"
  printf '\\set k random(0, 99)\nSELECT i.id, i.total FROM client c JOIN invoice i ON i.client = c.id WHERE c.city = '"'"'city-'"'"' || :k AND i.status = '"'"'unpaid'"'"';\n' > "$tmp/Q3.sql"
  # through the socket: the mean latency of a 2-second pgbench run, one client, prepared statements
  for q in Q1 Q2 Q3; do
    asked $q || continue
    for r in $(seq "$runs"); do
      pgbench -n -M prepared -c 1 -j 1 -T 2 -f "$tmp/$q.sql" bench 2>/dev/null | sed -n 's/latency average = \([0-9.]*\) ms/\1/p'
    done | stats "$q through the socket"
  done
  rm -r "$tmp"
  # inside the server: plpgsql loops of 100,000 lookups (cached plans), the time of one
  for q in Q1 Q2; do
    asked $q || continue
    if [ $q = Q1 ]; then look="SELECT * INTO x FROM invoice WHERE id = (i * 7919) % $ninv"
    else look="SELECT * INTO x FROM client WHERE email = 'c' || ((i * 7919) % $n) || '@example.com'"; fi
    for r in $(seq "$runs"); do
      psql -X -q -v ON_ERROR_STOP=1 -c "DO \$\$ DECLARE t0 timestamptz; x record; BEGIN t0 := clock_timestamp();
        FOR i IN 1..100000 LOOP $look; END LOOP;
        RAISE NOTICE 'per %', extract(epoch FROM clock_timestamp() - t0) * 1e3 / 100000; END \$\$;" 2>&1 \
        | sed -n 's/.*per \([0-9.e-]*\).*/\1/p'
    done | stats "$q engine only"
  done
  # the processes each question used: the leader and the workers it launched
  for q in Q4 Q5; do
    asked $q || continue
    eval "sql=\$$(echo $q | tr Q q)"
    echo "$q workers launched: $(psql -X -At -c "EXPLAIN (ANALYZE, TIMING OFF) $sql" | sed -n 's/.*Workers Launched: //p' | tr '\n' ' ')"
  done
  # EXPLAIN ANALYZE execution times
  for q in Q3 Q4 Q5; do
    asked $q || continue
    eval "sql=\$$(echo $q | tr Q q)"
    for r in $(seq "$runs"); do
      psql -X -At -c "EXPLAIN (ANALYZE, TIMING OFF) $sql" | sed -n 's/Execution Time: \([0-9.]*\) ms/\1/p'
    done | stats "$q engine only"
  done
  ;;
write)
  # RATE=r: r inserts a second in all (pgbench -R: a latency counts from the scheduled start, so a stall is never
  # hidden); without it, as fast as the clients go. Latencies of every insert, from pgbench's log, into the histogram.
  n=$3; c=$4; secs=$5
  tmp=$(mktemp -d -p "$root")
  printf '\\set c random(0, %d)\n\\set t random(1, 100000)\n\\set d random(0, 3649)\nINSERT INTO invoice (id, client, total, status, date) VALUES (nextval('"'"'invoice_seq'"'"'), :c, :t, '"'"'unpaid'"'"', :d);\n' $((n - 1)) > "$tmp/w.sql"
  j=$c; [ "$j" -gt 8 ] && j=8
  rate=""; [ -n "$RATE" ] && rate="-R $RATE"
  (cd "$tmp" && pgbench -n -M prepared -c "$c" -j "$j" -T "$secs" $rate -l --log-prefix=lat -f w.sql bench 2>/dev/null) \
    | sed -n "s/^\(tps = [0-9.]*\).*/W1 $c clients${RATE:+ at $RATE\/s}: \1/p"
  # a log line: client, transaction, latency (us), script, epoch, us[, schedule lag (us)]
  cat "$tmp"/lat* | awk '{ print $3 + ($7 == "" ? 0 : $7) }' | "$here/../../_build/default/bench/bench.exe" stats "  insert" us
  rm -r "$tmp"
  ;;
seats)
  # the sale of docs/case-seats.md: pg.sh seats ROOT serializable|naive SEATS BUYERS. Sold out by BUYERS pgbench
  # clients, each doing 2 SEATS/BUYERS + 50 transactions (one after the hall is sold out sells nothing); the time runs
  # from pgbench's start to the last charge's commit (its clock_timestamp)
  mode=$3; n=$4; c=$5
  psql_ <<EOS
DROP TABLE IF EXISTS charge, seat;
CREATE TABLE seat (id int PRIMARY KEY, owner int NOT NULL DEFAULT 0);
CREATE TABLE charge (id bigserial PRIMARY KEY, seat int NOT NULL, buyer int NOT NULL, price int NOT NULL,
                     at timestamptz NOT NULL DEFAULT clock_timestamp());
INSERT INTO seat (id) SELECT g FROM generate_series(1, $n) g;
CREATE INDEX seat_free ON seat (id) WHERE owner = 0;
VACUUM ANALYZE seat;
CHECKPOINT;
EOS
  t0=$(psql -X -At -c "SELECT extract(epoch FROM clock_timestamp())")
  pgbench -n -c "$c" -j "$c" -t $((2 * n / c + 50)) --max-tries=1000 -f "$here/seat-$mode.sql" > "$root/pgbench-seats.out" 2>&1 || true
  r=$(psql -X -At -F ' ' -c "SELECT count(*), count(*) - count(DISTINCT seat),
        (SELECT count(*) FROM charge c JOIN seat s ON s.id = c.seat WHERE s.owner <> c.buyer),
        (SELECT count(*) FROM seat WHERE owner = 0), round((extract(epoch FROM max(at)) - $t0)::numeric, 3) FROM charge")
  set -- $r
  retried=$(sed -n 's/^number of transactions retried: \([0-9]*\).*/\1/p' "$root/pgbench-seats.out")
  failed=$(sed -n 's/^number of failed transactions: \([0-9]*\).*/\1/p' "$root/pgbench-seats.out")
  echo "postgres seats ($mode, $c buyers): $n seats, $1 sales, $4 unsold, $2 sold twice or more, $3 charged without the seat; sold out in $5 s; ${retried:-0} transactions retried, ${failed:-0} failed"
  ;;
stop)
  pg_ctl -D "$root/data" -w stop -m fast >/dev/null
  ;;
*) echo "pg.sh init|start|load|read|write|stop ROOT ..."; exit 2 ;;
esac
