#!/bin/sh
# Backup and restore beside PostgreSQL and SQLite (docs/book/benchmarks.md, "Backup and restore"). Every time is in
# milliseconds, ROUNDS rounds summarised by bench.exe stats (the median and its distribution-free 95 % interval).
#   ops.sh cepheus ROOT CSVDIR FACTS ROUNDS
#       FACTS facts loaded as an application writes them (a group a client and its invoices, 64 threads, the runs left
#       as the load made them), the CSV files for the other sides in CSVDIR; a server started on them; then each
#       round: cepheus backup of the running server, cepheus verify of the copy, cepheus restore of the copy to its
#       end, and to the group in the middle of its history (the journal replayed from the newest run before it); and
#       once, cepheus verify of the live database
#   ops.sh pg ROOT CSVDIR ROUNDS
#       a cluster of its own whose WAL is archived (archive_command cp), a base backup of it empty, then the same rows
#       loaded (bench/pg/pg.sh load); then each round: pg_basebackup (plain, the WAL streamed, a fast checkpoint),
#       pg_verifybackup of it, its restore (a copy, a start, ready), and a point-in-time recovery to the middle of the
#       load's WAL from the empty base backup (recovery_target_lsn, promote)
#   ops.sh sqlite ROOT CSVDIR ROUNDS
#       the same rows in one file (bench/sqlite/sqlite.sh load); then each round: .backup into a new file, PRAGMA
#       integrity_check of it, and its restore (.restore into a new file)
#   ops.sh cepheus-replay ROOT CSVDIR FACTS ROUNDS
#       the same load, a backup, its runs taken out; then each round: cepheus restore of it, the whole history replayed
#       from the journal alone
#   ops.sh pg-replay ROOT CSVDIR ROUNDS
#       the same load with its WAL archived, the base backup taken before it; then each round: a recovery from that
#       base backup to the end of the archived WAL, the whole history replayed
# The sizes of each copy are printed once. ROOT must be short (a Unix socket path is at most 107 bytes).
set -e
cmd=$1; root=$2
here=$(cd "$(dirname "$0")" && pwd)
b="$here/../_build/default"
stats() { "$b/bench/bench.exe" stats "$1"; }
ms() { date +%s%N | awk '{printf "%d", $1 / 1e6}'; }
# the time of a command, in ms, on stdout; its output to the file $log
log=/dev/null
timed() { t0=$(ms); "$@" > "$log" 2>&1; t1=$(ms); echo $((t1 - t0)); }
size() { du -sb "$1" | cut -f1 | awk '{printf "%.1f MB", $1 / 1e6}'; }

case "$cmd" in
cepheus)
  csv=$3; facts=$4; rounds=$5
  cep="$b/bin/main.exe"
  rm -rf "$root"; mkdir -p "$root"
  "$cep" cluster init ops --dir "$root/etc" > /dev/null
  # The clients' port: one the system gives free, where 7400 could be another server's.
  port=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  sed -i "s/^name = \"main\"/name = \"shop\"/; s/127.0.0.1:7400/127.0.0.1:$port/" "$root/etc/cluster.toml"
  mkdir "$root/etc/data"
  t0=$(ms); SNAPSHOT=0 "$b/bench/bench.exe" load "$root/etc/data/shop" "$csv" "$facts" > "$root/load.out" 2>&1; t1=$(ms)
  echo "cepheus load: $((t1 - t0)) ms, $(size "$root/etc/data/shop") (journal $(size "$root/etc/data/shop/journal"), runs $(size "$root/etc/data/shop/snapshots"))"
  "$cep" serve --config "$root/etc/cluster.toml" 2> "$root/serve.log" &
  pid=$!
  while [ ! -S "$root/etc/run/.s.cepheus.$port" ]; do sleep 0.1; done
  last=$(grep -o 'shop at group [0-9]*' "$root/serve.log" | grep -o '[0-9]*$')
  mid=$((last / 2))
  echo "groups: $last, the middle: $mid; runs: $(ls "$root/etc/data/shop/snapshots")"
  log="$root/live.out"; echo "cepheus verify of the live database: $(timed "$cep" verify "$root/etc/data/shop") ms"; tail -1 "$root/live.out"
  for r in $(seq "$rounds"); do
    rm -rf "$root/backup"
    log="$root/backup.out"; timed "$cep" backup --config "$root/etc/cluster.toml" "$root/backup" >> "$root/t.backup"
    bk=$(ls -d "$root"/backup/20*)
    log="$root/verify.out"; timed "$cep" verify "$bk/shop" >> "$root/t.verify"
    rm -rf "$root/r"
    log="$root/restore.out"; timed "$cep" restore "$bk/shop" "$root/r" >> "$root/t.restore"
    rm -rf "$root/r"
    log="$root/mid.out"; timed "$cep" restore "$bk/shop" "$root/r" --to-group "$mid" >> "$root/t.mid"
  done
  echo "backup: $(size "$bk"); restored: $(size "$root/r") at the middle"
  tail -3 "$root/verify.out"; tail -2 "$root/backup.out"; tail -1 "$root/restore.out"; tail -1 "$root/mid.out"
  kill "$pid"; wait "$pid" || true
  stats "cepheus backup (live)" < "$root/t.backup"
  stats "cepheus verify (the copy)" < "$root/t.verify"
  stats "cepheus restore (to the end)" < "$root/t.restore"
  stats "cepheus restore (the middle group)" < "$root/t.mid"
  ;;
cepheus-replay)
  csv=$3; facts=$4; rounds=$5
  cep="$b/bin/main.exe"
  rm -rf "$root"; mkdir -p "$root"
  "$cep" cluster init ops --dir "$root/etc" > /dev/null
  # The clients' port: one the system gives free, where 7400 could be another server's.
  port=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  sed -i "s/^name = \"main\"/name = \"shop\"/; s/127.0.0.1:7400/127.0.0.1:$port/" "$root/etc/cluster.toml"
  mkdir "$root/etc/data"
  SNAPSHOT=0 NOCSV=1 "$b/bench/bench.exe" load "$root/etc/data/shop" "$csv" "$facts" > "$root/load.out" 2>&1
  "$cep" backup --config "$root/etc/cluster.toml" "$root/backup" > /dev/null
  bk=$(ls -d "$root"/backup/20*)
  rm -f "$bk"/shop/snapshots/*.run
  echo "the copy without its runs: $(size "$bk/shop")"
  for r in $(seq "$rounds"); do
    rm -rf "$root/r"
    log="$root/all.out"; timed "$cep" restore "$bk/shop" "$root/r" >> "$root/t.all"
  done
  tail -1 "$root/all.out"
  stats "cepheus restore (the whole history)" < "$root/t.all"
  ;;
pg-replay)
  csv=$3; rounds=$4
  export PGHOST="$root/sock" PGPORT=${PGPORT:-5544} PGDATABASE=bench
  rm -rf "$root"; mkdir -p "$root/arch"
  sh "$here/pg/pg.sh" init "$root"
  printf "archive_mode = on\narchive_command = 'cp %%p %s/arch/%%f'\n" "$root" >> "$root/data/postgresql.conf"
  sh "$here/pg/pg.sh" start "$root" 2G
  pg_basebackup -D "$root/base0" -X stream -c fast
  sh "$here/pg/pg.sh" load "$root" "$csv"
  psql -X -At -c "SELECT pg_switch_wal()" > /dev/null
  sleep 2
  sh "$here/pg/pg.sh" stop "$root"
  echo "the empty base backup $(size "$root/base0"); the load's WAL archived $(size "$root/arch")"
  for r in $(seq "$rounds"); do
    rm -rf "$root/r"; cp -a "$root/base0" "$root/r"; chmod 700 "$root/r"
    sed -i "/^unix_socket_directories/d; /^port/d; /^archive_/d" "$root/r/postgresql.conf"
    mkdir -p "$root/rsock"
    printf "unix_socket_directories = '%s'\nport = 5545\nrestore_command = 'cp %s/arch/%%f %%p'\nrecovery_target_timeline = 'latest'\n" "$root/rsock" "$root" >> "$root/r/postgresql.conf"
    touch "$root/r/recovery.signal"
    t0=$(ms)
    pg_ctl -D "$root/r" -l "$root/r.log" -w -t 600 start > /dev/null
    while [ "$(psql -X -At -h "$root/rsock" -p 5545 -d bench -c 'SELECT pg_is_in_recovery()')" != f ]; do sleep 0.05; done
    t1=$(ms); echo $((t1 - t0)) >> "$root/t.all"
    echo "rows: $(psql -X -At -h "$root/rsock" -p 5545 -d bench -c 'SELECT count(*) FROM invoice')" > "$root/rows.out"
    pg_ctl -D "$root/r" -w stop > /dev/null
  done
  cat "$root/rows.out"
  stats "PITR from the empty base backup to the end (the whole history)" < "$root/t.all"
  ;;
pg)
  csv=$3; rounds=$4
  export PGHOST="$root/sock" PGPORT=${PGPORT:-5544} PGDATABASE=bench
  rm -rf "$root"; mkdir -p "$root/arch"
  sh "$here/pg/pg.sh" init "$root"
  cat >> "$root/data/postgresql.conf" <<EOF
archive_mode = on
archive_command = 'cp %p $root/arch/%f'
EOF
  sh "$here/pg/pg.sh" start "$root" 2G
  pg_basebackup -D "$root/base0" -X stream -c fast
  start=$(psql -X -At -c "SELECT pg_current_wal_lsn()")
  sh "$here/pg/pg.sh" load "$root" "$csv"
  end=$(psql -X -At -c "SELECT pg_current_wal_lsn()")
  psql -X -At -c "SELECT pg_switch_wal()" > /dev/null
  mid=$(psql -X -At -c "SELECT pg_lsn '$start' + (pg_lsn '$end' - pg_lsn '$start') / 2")
  sleep 2
  echo "WAL of the load: $start to $end, the middle $mid; archive $(size "$root/arch")"
  # a copy restored and started on port 5545, its own socket; ready once it accepts connections
  restore() {
    rm -rf "$root/r"; cp -a "$1" "$root/r"; chmod 700 "$root/r"
    sed -i "/^unix_socket_directories/d; /^port/d; /^archive_/d" "$root/r/postgresql.conf"
    printf "unix_socket_directories = '%s'\nport = 5545\n" "$root/rsock" >> "$root/r/postgresql.conf"
    mkdir -p "$root/rsock"
    if [ -n "$2" ]; then
      printf "restore_command = 'cp %s/arch/%%f %%p'\nrecovery_target_lsn = '%s'\nrecovery_target_action = 'promote'\n" "$root" "$2" >> "$root/r/postgresql.conf"
      touch "$root/r/recovery.signal"
    fi
    pg_ctl -D "$root/r" -l "$root/r.log" -w -t 600 start > /dev/null
    # a point-in-time recovery is done once the server is promoted (out of recovery)
    while [ "$(psql -X -At -h "$root/rsock" -p 5545 -d bench -c 'SELECT pg_is_in_recovery()')" != f ]; do sleep 0.05; done
  }
  # the restored server stopped, out of the time
  stop_r() { pg_ctl -D "$root/r" -w stop > /dev/null; }
  for r in $(seq "$rounds"); do
    rm -rf "$root/bk"
    timed pg_basebackup -D "$root/bk" -X stream -c fast >> "$root/t.basebackup"
    timed pg_verifybackup "$root/bk" >> "$root/t.verifybackup"
    timed restore "$root/bk" >> "$root/t.restore"; stop_r
    timed restore "$root/base0" "$mid" >> "$root/t.pitr"; stop_r
  done
  echo "pg_basebackup: $(size "$root/bk"); empty base backup $(size "$root/base0"); the load's WAL archived $(size "$root/arch")"
  sh "$here/pg/pg.sh" stop "$root"
  stats "pg_basebackup" < "$root/t.basebackup"
  stats "pg_verifybackup" < "$root/t.verifybackup"
  stats "restore of the base backup" < "$root/t.restore"
  stats "PITR to the middle of the load" < "$root/t.pitr"
  ;;
sqlite)
  csv=$3; rounds=$4
  rm -rf "$root"; mkdir -p "$root"
  sh "$here/sqlite/sqlite.sh" load "$root" "$csv"
  for r in $(seq "$rounds"); do
    rm -f "$root/copy.db" "$root/back.db"
    timed sqlite3 "$root/bench.db" ".backup '$root/copy.db'" >> "$root/t.backup"
    timed sqlite3 "$root/copy.db" "PRAGMA integrity_check" >> "$root/t.check"
    timed sqlite3 "$root/back.db" ".restore '$root/copy.db'" >> "$root/t.restore"
  done
  echo "sqlite: the file $(size "$root/bench.db"), its copy $(size "$root/copy.db")"
  stats "sqlite .backup" < "$root/t.backup"
  stats "sqlite integrity_check" < "$root/t.check"
  stats "sqlite .restore" < "$root/t.restore"
  ;;
*) echo "ops.sh cepheus|cepheus-replay ROOT CSVDIR FACTS ROUNDS | pg|pg-replay|sqlite ROOT CSVDIR ROUNDS"; exit 2 ;;
esac
