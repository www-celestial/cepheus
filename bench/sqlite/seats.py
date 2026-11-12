# The sale of docs/book/case-seats.md on SQLite: a hall of SEATS seats sold out by BUYERS threads, each with its own
# connection. A buyer reads the ten best free seats, picks one at random, and writes the owner and the charge in one
# transaction, durable at commit (WAL, synchronous = FULL).
#   immediate: BEGIN IMMEDIATE, the read, the writes, COMMIT: the write lock is taken first, so no other writer
#              comes between the read and the write
#   naive:     the read alone (autocommit), then BEGIN IMMEDIATE, the writes, COMMIT: nothing checks the read
# Usage: python3 -I seats.py FILE immediate|naive SEATS BUYERS. Prints the time to sell out and what went wrong.
import os
import random
import sqlite3
import sys
import threading
import time

path, mode, nseats, nbuyers = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
for suffix in ("", "-wal", "-shm"):
    if os.path.exists(path + suffix):
        os.remove(path + suffix)
con = sqlite3.connect(path, isolation_level=None)
con.execute("PRAGMA journal_mode = WAL")
con.executescript("""
CREATE TABLE seat (id INTEGER PRIMARY KEY, owner INTEGER);
CREATE TABLE charge (id INTEGER PRIMARY KEY, seat INTEGER NOT NULL, buyer INTEGER NOT NULL, price INTEGER NOT NULL);
CREATE INDEX seat_free ON seat (id) WHERE owner IS NULL;
""")
con.execute("BEGIN")
con.executemany("INSERT INTO seat (id) VALUES (?)", [(k,) for k in range(1, nseats + 1)])
con.execute("COMMIT")
BEST = "SELECT id FROM seat WHERE owner IS NULL ORDER BY id LIMIT 10"
retries = [0] * nbuyers


def buyer(b):
    c = sqlite3.connect(path, timeout=60, isolation_level=None)
    c.execute("PRAGMA synchronous = FULL")
    r = random.Random(1000 + b)
    while True:
        if mode == "immediate":
            c.execute("BEGIN IMMEDIATE")
            free = [x for (x,) in c.execute(BEST)]
            if not free:
                c.execute("COMMIT")
                return
            s = r.choice(free)
        else:
            free = [x for (x,) in c.execute(BEST)]
            if not free:
                return
            s = r.choice(free)
            c.execute("BEGIN IMMEDIATE")
        c.execute("UPDATE seat SET owner = ? WHERE id = ?", (b, s))
        c.execute("INSERT INTO charge (seat, buyer, price) VALUES (?, ?, 4500)", (s, b))
        c.execute("COMMIT")


t0 = time.perf_counter()
ts = [threading.Thread(target=buyer, args=(b + 1,)) for b in range(nbuyers)]
for t in ts:
    t.start()
for t in ts:
    t.join()
t1 = time.perf_counter()
sales = con.execute("SELECT count(*) FROM charge").fetchone()[0]
double = con.execute("SELECT count(*) - count(DISTINCT seat) FROM charge").fetchone()[0]
unpaid = con.execute("SELECT count(*) FROM charge c JOIN seat s ON s.id = c.seat WHERE s.owner <> c.buyer").fetchone()[0]
unsold = con.execute("SELECT count(*) FROM seat WHERE owner IS NULL").fetchone()[0]
print(f"sqlite seats ({mode}, {nbuyers} buyers): {nseats} seats, {sales} sales, {unsold} unsold, {double} sold twice or more, "
      f"{unpaid} charged without the seat; sold out in {t1 - t0:.3f} s ({nseats / (t1 - t0):.0f} sales/s)")
