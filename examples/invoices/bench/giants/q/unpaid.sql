select sum(total), count(*) from invoice where status <> 'paid';
