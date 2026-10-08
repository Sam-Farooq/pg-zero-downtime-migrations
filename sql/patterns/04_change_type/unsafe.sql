-- pgsafe: runner autocommit
--
-- UNSAFE: two type changes, both of which rewrite the table.
--
-- integer to bigint is the one that surprises people, because the folklore says
-- widening is free. It is free for varchar, where the modifier is a limit and
-- the storage does not change. integer and bigint are four bytes and eight
-- bytes: pg_cast reaches bigint through a function, every row is converted, and
-- every index on the table is rebuilt, all under ACCESS EXCLUSIVE.
--
-- text to varchar(16) is a narrowing. Every value has to be measured against
-- the new limit, and the statement fails on the first row that does not fit,
-- after doing the work. It happens to succeed here because status holds
-- 'placed' and 'shipped'.
--
-- pgsafe.type_change() answers which of the two kinds a change is, from pg_cast
-- rather than from memory:
--
--   SELECT * FROM pgsafe.type_change('integer', 'bigint');
--   SELECT * FROM pgsafe.type_change('varchar(32)', 'varchar(64)');
--
-- Lock:  ACCESS EXCLUSIVE for the rewrite and the index rebuild
-- Reads: blocked
-- Safe form: ./safe.sql

ALTER TABLE app.orders ALTER COLUMN legacy_amount TYPE bigint;

ALTER TABLE app.orders ALTER COLUMN status TYPE varchar(16);
