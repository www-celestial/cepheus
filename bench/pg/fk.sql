-- The data of bench/dbench.ml in PostgreSQL, with the same foreign keys (pg.sh fk): 10,000 clients, 100,000
-- invoices (client REFERENCES client: NO ACTION, PostgreSQL's default, which refuses), 200,000 lines over them
-- (invoice REFERENCES invoice ON DELETE CASCADE), the measured clients of 0, 100 and 10,000 invoices, the measured
-- invoices of 0, 100 and 10,000 lines and of 0, 100 and 10,000 notes (invoice REFERENCES invoice ON DELETE SET NULL),
-- the referencing columns indexed, as a PostgreSQL user writes them. Then the functions that time a DELETE, and a
-- loop of inserts, inside the server, rolled back: the engine's work, as dbench.exe times its forks.
DROP TABLE IF EXISTS note, line, bill, bill_fk, invoice, client CASCADE;
CREATE TABLE client (id int PRIMARY KEY, name text NOT NULL, city text NOT NULL);
CREATE TABLE invoice (id int PRIMARY KEY, client int NOT NULL REFERENCES client, total numeric(12,2) NOT NULL);
CREATE TABLE line (id int PRIMARY KEY, invoice int NOT NULL REFERENCES invoice ON DELETE CASCADE, price numeric(12,2) NOT NULL);
CREATE TABLE note (id int PRIMARY KEY, invoice int REFERENCES invoice ON DELETE SET NULL, text text NOT NULL);
CREATE TABLE bill (id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY, client int NOT NULL, total numeric(12,2) NOT NULL);
CREATE TABLE bill_fk (id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY, client int NOT NULL REFERENCES client, total numeric(12,2) NOT NULL);
INSERT INTO client SELECT k, 'client-' || k, 'city-' || (k % 20) FROM generate_series(1, 10000) k;
INSERT INTO client VALUES (10001, 'zero', 'z'), (10002, 'hundred', 'z'), (10003, 'tenthousand', 'z');
INSERT INTO invoice SELECT k, 1 + (k % 10000), k % 25000 FROM generate_series(1, 100000) k;
INSERT INTO invoice SELECT 100000 + k, 10002, 1 + k FROM generate_series(1, 100) k;
INSERT INTO invoice SELECT 100100 + k, 10003, 2 + k FROM generate_series(1, 10000) k;
INSERT INTO invoice SELECT 200000 + k, k, k FROM generate_series(1, 6) k;
INSERT INTO line SELECT k, 1 + (k % 100000), k % 25000 FROM generate_series(1, 200000) k;
INSERT INTO line SELECT 200000 + k, 200002, k FROM generate_series(1, 100) k;
INSERT INTO line SELECT 200100 + k, 200003, k FROM generate_series(1, 10000) k;
INSERT INTO note SELECT k, 200005, 'n' FROM generate_series(1, 100) k;
INSERT INTO note SELECT 100 + k, 200006, 'n' FROM generate_series(1, 10000) k;
CREATE INDEX ON invoice (client);
CREATE INDEX ON line (invoice);
CREATE INDEX ON note (invoice);
VACUUM ANALYZE;
CHECKPOINT;

-- the microseconds of the DELETE of measured case c (1 to 9: the clients of 0, 100 and 10,000 invoices, the
-- invoices of 0, 100 and 10,000 lines, of 0, 100 and 10,000 notes), static statements whose plans the session keeps,
-- inside a subtransaction rolled back (a refusal by a foreign key caught)
DROP FUNCTION IF EXISTS t_delete(text);
CREATE OR REPLACE FUNCTION t_delete(c int) RETURNS double precision AS $$
DECLARE t0 timestamptz; t double precision;
BEGIN
  BEGIN
    t0 := clock_timestamp();
    BEGIN
      CASE c
        WHEN 1 THEN DELETE FROM client WHERE id = 10001;
        WHEN 2 THEN DELETE FROM client WHERE id = 10002;
        WHEN 3 THEN DELETE FROM client WHERE id = 10003;
        WHEN 4 THEN DELETE FROM invoice WHERE id = 200001;
        WHEN 5 THEN DELETE FROM invoice WHERE id = 200002;
        WHEN 6 THEN DELETE FROM invoice WHERE id = 200003;
        WHEN 7 THEN DELETE FROM invoice WHERE id = 200004;
        WHEN 8 THEN DELETE FROM invoice WHERE id = 200005;
        ELSE DELETE FROM invoice WHERE id = 200006;
      END CASE;
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    t := extract(epoch FROM clock_timestamp() - t0) * 1e6;
    RAISE EXCEPTION 'rolled back';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  RETURN t;
END $$ LANGUAGE plpgsql;

-- n inserts of a bill, of a client each, rolled back: microseconds an insert, without and with the foreign key
CREATE OR REPLACE FUNCTION t_bill(n int) RETURNS double precision AS $$
DECLARE t0 timestamptz; t double precision;
BEGIN
  BEGIN
    t0 := clock_timestamp();
    FOR k IN 1..n LOOP INSERT INTO bill (client, total) VALUES (1 + (k % 10000), k); END LOOP;
    t := extract(epoch FROM clock_timestamp() - t0) * 1e6 / n;
    RAISE EXCEPTION 'rolled back';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  RETURN t;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION t_bill_fk(n int) RETURNS double precision AS $$
DECLARE t0 timestamptz; t double precision;
BEGIN
  BEGIN
    t0 := clock_timestamp();
    FOR k IN 1..n LOOP INSERT INTO bill_fk (client, total) VALUES (1 + (k % 10000), k); END LOOP;
    t := extract(epoch FROM clock_timestamp() - t0) * 1e6 / n;
    RAISE EXCEPTION 'rolled back';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  RETURN t;
END $$ LANGUAGE plpgsql;
