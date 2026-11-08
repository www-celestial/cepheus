# Q1-Q5 on SQLite, in the process, as Cepheus answers them: Python's sqlite3 module times each run with
# time.perf_counter, and the runs go through `bench.exe stats` (median and its 95 % interval), as for the other sides.
# Q1 and Q2 run 100,000 lookups inside one statement (a recursive CTE drives them), so that the time is SQLite's and
# not Python's: the same "engine only" measure as PostgreSQL's PL/pgSQL loop. Q3 runs once per city (100 cities a run).
# Usage: python3 -I read.py DB NCLIENTS BENCH_EXE
import os, sqlite3, subprocess, sys, time

path, nclients, stats = sys.argv[1], int(sys.argv[2]), sys.argv[3]
ninv = nclients * 20
runs = int(os.environ.get("RUNS", "21"))
qs = os.environ.get("QS", "Q1,Q2,Q3,Q4,Q5").split(",")
cache_mb = int(os.environ.get("CACHE_MB", "1024"))

con = sqlite3.connect(path, isolation_level=None)
con.execute(f"PRAGMA cache_size = -{cache_mb * 1024}")
con.execute("PRAGMA temp_store = MEMORY")
con.execute("PRAGMA query_only = 1")

loop = "WITH RECURSIVE k(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM k WHERE i < 99999) "
q1 = loop + (f"SELECT count(*), sum(i.client + i.total + i.date + length(i.status)) FROM k JOIN invoice i "
             f"ON i.id = (k.i * 7919) % {ninv}")
q2 = loop + (f"SELECT count(*), sum(length(c.name) + length(c.city)) FROM k JOIN client c "
             f"ON c.email = 'c' || ((k.i * 7919) % {nclients}) || '@example.com'")
q3 = ("SELECT count(*), sum(i.total) FROM client c JOIN invoice i ON i.client = c.id "
      "WHERE c.city = ? AND i.status = 'unpaid'")
q4 = ("SELECT c.city, sum(i.total), count(*) FROM invoice i JOIN client c ON c.id = i.client "
      "WHERE i.status = 'unpaid' GROUP BY c.city")
q5 = "SELECT count(*) FROM follows f1 JOIN follows f2 ON f2.a = f1.b JOIN follows f3 ON f3.a = f2.b AND f3.b = f1.a"


def plan(q, *a):
    return "; ".join(r[3] for r in con.execute("EXPLAIN QUERY PLAN " + q, a))


def summary(name, ms):
    out = subprocess.run([stats, "stats", name], input="\n".join(f"{x:.6f}" for x in ms), text=True,
                         capture_output=True, check=True).stdout
    print(out, end="", flush=True)


def timed(f):
    t = time.perf_counter()
    f()
    return (time.perf_counter() - t) * 1e3


# warm the cache, as the Cepheus side is warm (its snapshot is read and checked whole at open)
t = time.perf_counter()
for q in (q1, q2, q4, q5):
    con.execute(q).fetchall()
for k in range(100):
    con.execute(q3, (f"city-{k}",)).fetchall()
print(f"sqlite {sqlite3.sqlite_version}, cache {cache_mb} MB, warm-up {time.perf_counter() - t:.1f} s", flush=True)

# the same answers as the other sides
print("Q3 rows city-7:", con.execute(q3, ("city-7",)).fetchone()[0])
print("Q4 count, sum:", *con.execute("SELECT count(*), sum(i.total) FROM invoice i JOIN client c ON c.id = i.client "
                                    "WHERE i.status = 'unpaid'").fetchone())
print("Q5 rotations:", con.execute(q5).fetchone()[0])
for name, q in (("Q1", q1), ("Q2", q2), ("Q4", q4), ("Q5", q5)):
    print(f"{name} plan: {plan(q)}")
print(f"Q3 plan: {plan(q3, 'city-7')}", flush=True)

if "Q1" in qs:
    summary("Q1 engine only (per lookup)", [timed(lambda: con.execute(q1).fetchall()) / 100000 for _ in range(runs)])
if "Q2" in qs:
    summary("Q2 engine only (per lookup)", [timed(lambda: con.execute(q2).fetchall()) / 100000 for _ in range(runs)])
if "Q3" in qs:
    summary("Q3 (per city)", [timed(lambda: [con.execute(q3, (f"city-{k}",)).fetchall() for k in range(100)]) / 100
                              for _ in range(runs)])
if "Q4" in qs:
    summary("Q4", [timed(lambda: con.execute(q4).fetchall()) for _ in range(runs)])
if "Q5" in qs:
    summary("Q5", [timed(lambda: con.execute(q5).fetchall()) for _ in range(runs)])
