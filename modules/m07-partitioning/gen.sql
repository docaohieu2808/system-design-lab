-- Module 7.4: what making a million IDs costs on its own, no table and no index.
\timing on
\echo gen-base
SELECT count(*) FROM generate_series(1, 1000000);
\echo gen-uuid4
SELECT count(gen_random_uuid()) FROM generate_series(1, 1000000);
\echo gen-uuid7
SELECT count(uuidv7()) FROM generate_series(1, 1000000);
\timing off
