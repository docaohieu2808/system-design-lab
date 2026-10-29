\set id random(1, 1000000)
SELECT url FROM links WHERE id = :id;
