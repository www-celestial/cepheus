#!/bin/sh
# SQLite side of the benchmarks: one database file ROOT/bench.db, loaded from the CSV files of `bench.exe load`.
#   sqlite.sh load ROOT CSVDIR    tables as a SQLite user would write them (INTEGER PRIMARY KEY, a WITHOUT ROWID table
#                                 for the links, an index on every searched column), .import, ANALYZE
#   sqlite.sh read ROOT NCLIENTS  Q1-Q5 in the process (read.py, Python's sqlite3 module): RUNS runs each (21),
#                                 summarised by bench.exe stats, as the other sides; QS=Q1,Q4 only those; CACHE_MB the
#                                 page cache (1024 by default, as Cepheus' cache)
set -e
cmd=$1; root=$2
here=$(cd "$(dirname "$0")" && pwd)
db="$root/bench.db"
case "$cmd" in
load)
  csv=$3
  mkdir -p "$root"
  rm -f "$db" "$db-wal" "$db-shm"
  t0=$(date +%s.%N)
  sqlite3 "$db" <<SQL
PRAGMA journal_mode = WAL;
PRAGMA synchronous = FULL;
CREATE TABLE client (id INTEGER PRIMARY KEY, name TEXT NOT NULL, city TEXT NOT NULL, email TEXT NOT NULL UNIQUE);
CREATE TABLE invoice (id INTEGER PRIMARY KEY, client INTEGER NOT NULL REFERENCES client, total INTEGER NOT NULL,
                      status TEXT NOT NULL, date INTEGER NOT NULL);
CREATE TABLE follows (a INTEGER NOT NULL REFERENCES client, b INTEGER NOT NULL REFERENCES client,
                      PRIMARY KEY (a, b)) WITHOUT ROWID;
.mode csv
.import $csv/client.csv client
.import $csv/invoice.csv invoice
.import $csv/follows.csv follows
CREATE INDEX client_city ON client (city);
CREATE INDEX invoice_client ON invoice (client);
CREATE INDEX invoice_status ON invoice (status);
CREATE INDEX follows_b ON follows (b, a);
ANALYZE;
PRAGMA wal_checkpoint(TRUNCATE);
SQL
  t1=$(date +%s.%N)
  echo "sqlite load: $(awk "BEGIN{print $t1 - $t0}") s (.import, indexes, ANALYZE); file $(du -m "$db" | cut -f1) MB"
  ;;
read)
  python3 -I "$here/read.py" "$db" "$3" "$here/../../_build/default/bench/bench.exe"
  ;;
*) echo "sqlite.sh load|read ROOT ..."; exit 2 ;;
esac
