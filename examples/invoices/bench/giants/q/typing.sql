select id, name, city, email from client where search like 'ma%' or email like 'ma%' order by name collate "C" limit 21;
