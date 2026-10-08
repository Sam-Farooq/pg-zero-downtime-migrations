-- pgsafe: runner autocommit
--
-- UNSAFE: three index statements that each stop writes.
--
-- CREATE INDEX takes SHARE. Reads carry on, and every INSERT, UPDATE and DELETE
-- waits for the whole build, because ROW EXCLUSIVE conflicts with SHARE.
--
-- ADD CONSTRAINT ... UNIQUE is worse than it looks: the constraint needs a
-- unique index, so it builds one, and it does that while holding ACCESS
-- EXCLUSIVE. Reads stop as well as writes.
--
-- DROP INDEX takes ACCESS EXCLUSIVE too, so undoing a mistake is as blocking as
-- making it.
--
-- There is a fourth unsafe form that cannot be put in this file, because it
-- fails rather than blocking: CREATE INDEX CONCURRENTLY inside a BEGIN block.
-- PostgreSQL refuses it outright. The linter has a rule for it and the case
-- lives in tests/test_rules.py.
--
-- Safe form: ./safe.sql

CREATE INDEX orders_customer_id_idx ON app.orders (customer_id);

ALTER TABLE app.orders ADD CONSTRAINT orders_reference_key UNIQUE (reference);

DROP INDEX app.orders_customer_id_idx;
