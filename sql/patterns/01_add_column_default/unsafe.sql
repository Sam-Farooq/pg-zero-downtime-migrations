-- pgsafe: runner autocommit
--
-- UNSAFE: a new column whose default has to be evaluated per row.
--
-- gen_random_uuid() is volatile, so there is no single value PostgreSQL can
-- record as the column's missing value. It fills the column row by row, which
-- means a full table rewrite under ACCESS EXCLUSIVE. That lock conflicts with
-- ACCESS SHARE, so reads stop too, and every query that arrives while the
-- rewrite runs waits behind it.
--
-- The second statement is the same cost wearing different clothes: an identity
-- column takes its values from a sequence, and nextval() is volatile.
--
-- Lock:  ACCESS EXCLUSIVE, held for the length of the rewrite
-- Reads: blocked
-- Safe form: ./safe.sql

ALTER TABLE app.orders
    ADD COLUMN public_id uuid NOT NULL DEFAULT gen_random_uuid();

ALTER TABLE app.orders
    ADD COLUMN sequence_no bigint GENERATED ALWAYS AS IDENTITY;
