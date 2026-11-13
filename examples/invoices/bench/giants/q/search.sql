select id, number, bill_to, date, due, status, total from invoice where search like 'ad%' order by number desc limit 21;
