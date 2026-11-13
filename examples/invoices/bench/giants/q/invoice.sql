select * from invoice where id = 50000;
select position, label, quantity, price from line where invoice = 50000 order by position;
