-- Module 7: the same million rows inserted three times, with three kinds of primary key.
\timing on
CREATE TABLE ids_bigint (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, v int);
CREATE TABLE ids_uuid4 (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), v int);
CREATE TABLE ids_uuid7 (id uuid PRIMARY KEY DEFAULT uuidv7(), v int);
\echo insert-bigint
INSERT INTO ids_bigint (v) SELECT g FROM generate_series(1, 1000000) g;
\echo insert-uuid4
INSERT INTO ids_uuid4 (v) SELECT g FROM generate_series(1, 1000000) g;
\echo insert-uuid7
INSERT INTO ids_uuid7 (v) SELECT g FROM generate_series(1, 1000000) g;
\timing off
SELECT 'index-mb', relname, round(pg_relation_size(relid)::numeric / 1048576, 1)
FROM pg_stat_user_indexes WHERE relname LIKE 'ids_%' ORDER BY relname;
