#!/bin/sh
# The database's part of the app's pages beside PostgreSQL: the seed of bench/run.sh (OUT/srv, its server running) and
# the same data in PostgreSQL (load.sql, a server of its own in OUT/pg, durable commits as by default), the same
# questions (q/*.sql through pgbench -M prepared, one client; bench/questions on Cepheus, the app's own functions, its
# reads in its own memory), ROUNDS rounds (21) alternated. One line of JSON a question and a round in OUT/giants.jsonl.
#   bench/giants/giants.sh OUT       (after bench/run.sh OUT seed)
set -e
cd "$(dirname "$0")/../.."
out=$(cd "$1" && pwd)
rounds=${ROUNDS:-21}
pg=$out/pg
export PGHOST=$pg PGPORT=5499 PGDATABASE=postgres
if [ ! -f "$pg/data/PG_VERSION" ]; then
  mkdir -p "$pg"
  initdb -D "$pg/data" -E UTF8 --no-locale -A trust > "$pg/initdb.log"
  printf "listen_addresses = ''\nunix_socket_directories = '%s'\nport = 5499\nshared_buffers = 256MB\n" "$pg" >> "$pg/data/postgresql.conf"
fi
pg_ctl -D "$pg/data" -l "$pg/server.log" -w start > /dev/null
trap 'pg_ctl -D "$pg/data" -w stop > /dev/null' EXIT
if [ "$(psql -tAc "select to_regclass('invoice') is not null")" != t ]; then
  psql -q -v ON_ERROR_STOP=1 -f bench/giants/load.sql > "$out/pg-load.txt"
fi
port=7463
export CEPHEUS_URL="cepheus://localhost:$port/invoices?socket=$out/srv/run" CEPHEUS_TOKEN=$(cat "$out/srv/web.token")
: > "$out/giants.jsonl"
pgq() {  # pgq WHAT FILE N: one client, N transactions, each one's latency from pgbench's log
  rm -f "$pg"/log.*
  pgbench -n -M prepared -c 1 -t "$3" -f "bench/giants/q/$2" --log --log-prefix="$pg/log" > "$pg/pgbench.out" 2>&1 || { cat "$pg/pgbench.out"; exit 1; }
  sort -n -k3 "$pg"/log.* | awk -v what="$1" '{ a[NR] = $3 } END { i = int(NR * 0.5); if (i < 1) i = 1; j = int(NR * 0.99 + 0.5); if (j < 1) j = 1; printf "{\"What\":\"postgresql: %s\",\"C\":1,\"P50\":%s,\"P99\":%s}\n", what, a[i], a[j] }' >> "$out/giants.jsonl"
}
for r in $(seq "$rounds"); do
  cesia run --allow native=cepheus,env bench/questions/questions.ce 1000 >> "$out/giants.jsonl"
  pgq "a page of invoices" page.sql 1000
  pgq "a page 50,000 deep" deep.sql 1000
  pgq "invoices by bill-to prefix" search.sql 1000
  pgq "clients by name" clients.sql 1000
  pgq "clients by name or e-mail prefix" typing.sql 1000
  pgq "the unpaid total" unpaid.sql 1000
  pgq "an invoice with its lines" invoice.sql 1000
  pgq "a durable update of one invoice" pay.sql 200
done
