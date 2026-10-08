-- pgsafe: runner autocommit
--
-- SAFE: the same three indexes, built under SHARE UPDATE EXCLUSIVE.
--
-- CONCURRENTLY costs two passes over the table and a wait for every transaction
-- older than the build, so it is slower in wall clock time and does not block
-- writes while it runs. It cannot run inside a transaction block at all, which
-- is why this file declares the autocommit runner and why a framework that
-- wraps each migration in BEGIN has to be told to skip that for this one.
--
-- The check after each build is the part that gets left out. A concurrent build
-- that fails, including one aborted by the lock_timeout set below, leaves the
-- index behind marked invalid. It is not used by the planner, it is still
-- maintained on every write, and nothing in the output of a migration runner
-- mentions it. pgsafe.assert_index_valid() raises instead.
--
-- The recovery is DROP INDEX CONCURRENTLY and build it again. A REINDEX of an
-- invalid index leaves it invalid.
--
-- The unique constraint is two steps rather than one: build the index
-- concurrently, then have the constraint adopt it with USING INDEX. The
-- constraint statement still takes ACCESS EXCLUSIVE, and it holds it for a
-- catalogue write rather than for an index build.

SET lock_timeout = '3s';

-- 1. A plain index.
CREATE INDEX CONCURRENTLY orders_customer_id_idx ON app.orders (customer_id);

SELECT pgsafe.assert_index_valid('app.orders_customer_id_idx');

-- 2. A unique constraint, without building the index under the lock.
CREATE UNIQUE INDEX CONCURRENTLY orders_reference_uq ON app.orders (reference);

SELECT pgsafe.assert_index_valid('app.orders_reference_uq');

ALTER TABLE app.orders
    ADD CONSTRAINT orders_reference_key UNIQUE USING INDEX orders_reference_uq;

-- 3. A partial index, and the concurrent way to remove one. DROP INDEX
-- CONCURRENTLY marks the index dead, waits out the transactions that might be
-- reading it, and then removes it.
CREATE INDEX CONCURRENTLY orders_unshipped_idx
    ON app.orders (placed_at)
    WHERE status <> 'shipped';

SELECT pgsafe.assert_index_valid('app.orders_unshipped_idx');

DROP INDEX CONCURRENTLY app.orders_unshipped_idx;
