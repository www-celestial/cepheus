-- date_trunc of PostgreSQL 18.6 for Cepheus's Trunc: random instants from 1900 to 2100 in each zone and unit, and
-- every 10 minutes of two days about summer time changes; each line: zone unit instant_ms truncated_ms
SELECT setseed(0.42);
CREATE TEMP TABLE input AS
  SELECT z, u, (random() * 6.3e12 - 2.2e12)::bigint AS t
  FROM unnest(array['UTC','Europe/Paris','America/New_York','Australia/Sydney','Australia/Lord_Howe','America/St_Johns',
                    'Asia/Kathmandu','Pacific/Apia','America/Nuuk','Africa/Casablanca','Europe/Dublin','America/Sao_Paulo',
                    'Pacific/Chatham','Antarctica/Troll','Asia/Tehran','Europe/Moscow','America/Santiago','Asia/Tokyo']) z,
       unnest(array['second','minute','hour','day','week','month','quarter','year','decade','century','millennium']) u,
       generate_series(1, 200);
INSERT INTO input
  SELECT z, u, (extract(epoch from d) * 1000)::bigint + 600000 * k
  FROM (VALUES ('Europe/Paris', timestamptz '2026-03-28 00:00Z'), ('Europe/Paris', '2026-10-24 00:00Z'),
               ('America/New_York', '2026-03-07 12:00Z'), ('America/New_York', '2026-10-31 12:00Z'),
               ('Australia/Lord_Howe', '2026-10-03 00:00Z'), ('Australia/Lord_Howe', '2026-04-04 00:00Z'),
               ('America/Sao_Paulo', '2018-11-03 12:00Z'), ('America/Sao_Paulo', '2019-02-16 12:00Z'),
               ('Pacific/Apia', '2011-12-29 00:00Z'), ('Europe/Dublin', '2026-10-24 12:00Z'), ('Europe/Dublin', '2026-03-28 12:00Z'),
               ('Africa/Casablanca', '2026-02-07 12:00Z'), ('America/Havana', '2026-03-07 12:00Z'), ('America/Havana', '2026-10-31 12:00Z'))
         AS s(z, d),
       unnest(array['day','hour','week','month']) u,
       generate_series(0, 288) k;
COPY (SELECT z, u, t, (extract(epoch from date_trunc(u, to_timestamp(t / 1000.0), z)) * 1000)::bigint FROM input) TO STDOUT WITH (DELIMITER ' ');
