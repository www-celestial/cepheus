-- The seed of src/seed/seed.ce in PostgreSQL: the same 10,000 clients and 100,000 invoices with their lines, drawn by
-- the same hash of each invoice's number, relative to the time of the load; the indexes that the app's pages need.
create function draw(i bigint, k bigint, lo bigint, hi bigint) returns bigint immutable language sql
  as $$ select lo + (((i * 16 + k + 1) * 2654435761) % 4294967291) % (hi - lo + 1) $$;
create table client (id bigint primary key, name text not null, search text not null, email text not null unique, city text not null);
create table invoice (id bigint primary key, number bigint not null unique, client bigint not null references client,
  bill_to text not null, search text not null, date timestamptz not null, due timestamptz not null, status text not null,
  total numeric(14, 2) not null, paid_at timestamptz);
create table line (id bigserial primary key, invoice bigint not null, position int not null,
  label text not null, quantity int not null, price numeric(14, 2) not null);
\set firsts '\'{Ada,Bo,Chloé,David,Élodie,Farid,Grace,Hugo,Inès,Jules,Karim,Léa,Marc,Nina,Omar,Paula,Quentin,Rosa,Sami,Théo,Ugo,Vera,Wen,Yanis,Zoé}\''
\set lasts '\'{Martin,Bernard,Dubois,Thomas,Robert,Richard,Petit,Durand,Leroy,Moreau,Simon,Laurent,Lefebvre,Michel,Garcia,David,Bertrand,Roux,Vincent,Fournier}\''
\set cities '\'{Lyon,Paris,Marseille,Toulouse,Nice,Nantes,Strasbourg,Montpellier,Bordeaux,Lille,Rennes,Reims,Grenoble,Dijon,Angers,Brest,Tours,Limoges,Metz,Caen}\''
\set labels '\'{Design,Hosting,Support,Audit,Training,Licence,Consulting,Development,Maintenance,Translation}\''
\timing on
begin;
insert into client
  select i, n, lower(n), 'client' || i || '@example.com', (:cities::text[])[draw(i, 1, 1, 20)]
  from (select i, (:firsts::text[])[i % 25 + 1] || ' ' || (:lasts::text[])[(i / 25) % 20 + 1] as n from generate_series(1, 10000) i) c;
create temporary table drawn as
  select i, draw(i, 1, 1, 10000) as c, now() - (draw(i, 2, 0, 364) * 86400 + draw(i, 3, 0, 86399)) * interval '1 second' as date,
         draw(i, 4, 1, 5) as lines, draw(i, 15, 1, 100) as luck, draw(i, 0, 1, 40) as paid_days
  from generate_series(1, 100000) i;
insert into line (invoice, position, label, quantity, price)
  select d.i, p, (:labels::text[])[draw(d.i, 4 + p, 1, 10)], draw(d.i, 4 + p, 1, 10), draw(d.i, 9 + p, 20, 2000) * 5
  from drawn d, generate_series(1, 5) p where p <= d.lines;
insert into invoice
  select d.i, d.i, d.c, cl.name, cl.search, d.date, d.date + interval '30 days',
         case when d.date + interval '30 days' < now() then (case when d.luck <= 88 then 'paid' else 'late' end)
              else (case when d.luck <= 50 then 'paid' else 'unpaid' end) end,
         (select sum(quantity * price) from line l where l.invoice = d.i), null
  from drawn d join client cl on cl.id = d.c;
update invoice set paid_at = least(now(), date + (select paid_days from drawn where drawn.i = invoice.id) * interval '1 day') where status = 'paid';
alter table line add foreign key (invoice) references invoice;
commit;
create index on client (name collate "C");
create index on client (search text_pattern_ops);
create index on client (email text_pattern_ops);
create index on invoice (search text_pattern_ops);
create index on invoice (status);
create index on invoice (due);
create index on line (invoice);
vacuum analyze;
select count(*) as clients from client;
select count(*) as invoices, count(*) filter (where status = 'paid') as paid, count(*) filter (where status = 'late') as late from invoice;
select count(*) as lines from line;
