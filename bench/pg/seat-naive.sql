-- The naive sale of docs/book/case-seats.md at READ COMMITTED (the default): the read alone, then the writes in a
-- transaction that does not check it. :s is 0 when the hall is sold out.
SELECT coalesce((SELECT id FROM (SELECT id FROM seat WHERE owner = 0 ORDER BY id LIMIT 10) best ORDER BY random() LIMIT 1), 0) AS s \gset
\if :s > 0
BEGIN;
UPDATE seat SET owner = :client_id + 1 WHERE id = :s;
INSERT INTO charge (seat, buyer, price) VALUES (:s, :client_id + 1, 4500);
COMMIT;
\endif
