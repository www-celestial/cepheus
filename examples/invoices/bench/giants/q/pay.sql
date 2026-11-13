\set id random(1, 100000)
update invoice set paid_at = now() where id = :id;
