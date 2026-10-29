-- Module 5 data, loaded after db/init.sql: a million links instead of a hundred thousand, click counts, and the
-- two-doctor rota for the write-skew drill. No index on links.url: lesson 5.1 adds it during the experiment.
INSERT INTO links (id, code, url)
SELECT g, base62(g), 'https://example.com/articles/' || g
FROM generate_series(100001, 1000000) AS g;
SELECT setval('links_id_seq', 1000000);

CREATE TABLE link_stats (code text PRIMARY KEY, clicks bigint NOT NULL DEFAULT 0);
INSERT INTO link_stats (code, clicks) SELECT code, (id * 7919) % 1000 FROM links WHERE id > 999000;

CREATE TABLE doctors (name text PRIMARY KEY, on_call boolean NOT NULL);
INSERT INTO doctors VALUES ('alice', true), ('bob', true);
ANALYZE;
