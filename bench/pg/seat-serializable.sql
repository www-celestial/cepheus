-- The sale of docs/case-seats.md at SERIALIZABLE: the read and the writes in one transaction; a serialization
-- failure is retried by pgbench (--max-tries). :s is 0 when the hall is sold out.
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT coalesce((SELECT id FROM (SELECT id FROM seat WHERE owner = 0 ORDER BY id LIMIT 10) best ORDER BY random() LIMIT 1), 0) AS s \gset
\if :s > 0
UPDATE seat SET owner = :client_id + 1 WHERE id = :s;
INSERT INTO charge (seat, buyer, price) VALUES (:s, :client_id + 1, 4500);
\endif
COMMIT;
