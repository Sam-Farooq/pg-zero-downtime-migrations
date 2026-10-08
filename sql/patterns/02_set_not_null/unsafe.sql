-- pgsafe: runner autocommit
--
-- UNSAFE: SET NOT NULL on a column that still has nulls in it, preceded by the
-- update that fills them.
--
-- Two separate problems.
--
-- The UPDATE has no WHERE clause, so it writes every row in the table in one
-- transaction. That holds a row lock on all 500 of them until it commits, and
-- on a real table it is also 500 million dead tuples for autovacuum to find.
--
-- SET NOT NULL then takes ACCESS EXCLUSIVE and scans the whole table to prove
-- no null is left, with reads blocked for the length of the scan. The scan is
-- the part people do not expect: the statement looks like a catalogue change
-- and is priced like a sequential scan.
--
-- Lock:  ACCESS EXCLUSIVE for the scan
-- Reads: blocked
-- Safe form: ./safe.sql

UPDATE app.orders SET shipping_country = coalesce(shipping_country, 'ZZ');

ALTER TABLE app.orders ALTER COLUMN shipping_country SET NOT NULL;
