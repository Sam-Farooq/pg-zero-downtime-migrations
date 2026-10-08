-- pgsafe: runner autocommit
--
-- SAFE: one type change done in place because the catalogue says it is free,
-- and one done by replacing the column because it is not.
--
-- The first statement is the case the folklore gets right. varchar(32) to
-- varchar(64) is binary coercible with a looser modifier, so the heap is left
-- alone. It is still not free: the documented exception says a rewrite is
-- avoided, and every index on the column is rebuilt anyway, under ACCESS
-- EXCLUSIVE. On a column with one index on a small table that is milliseconds.
-- On a heavily indexed table it is not, and this is the statement people assume
-- is instant.
--
-- integer to bigint has no in place version, so the column is replaced:
-- add the new one, keep the pair equal with a trigger so that a writer which
-- knows only the old name stays correct, backfill in batches, and drop the old
-- column a release later.
--
-- What this costs, and it is the whole tradeoff: the column ends up called
-- legacy_amount_big. Renaming it back to legacy_amount is another rename, with
-- exactly the problem ../05_rename_column exists to describe. Living with the
-- new name is the cheap answer; carrying a view that presents the old name is
-- the other one.

SET lock_timeout = '3s';

-- 1. Free, because pg_cast says binary coercible and the modifier only widens.
ALTER TABLE app.orders ALTER COLUMN reference TYPE varchar(64);

-- 2. Ask the catalogue rather than guessing. Both rows print a cost and a reason.
SELECT * FROM pgsafe.type_change('varchar(32)', 'varchar(64)');
SELECT * FROM pgsafe.column_type_change('app.orders', 'legacy_amount', 'bigint');

-- 3. The new column, empty.
ALTER TABLE app.orders ADD COLUMN legacy_amount_big bigint;

-- 4. Dual write. From here either column may be written and both stay equal.
CREATE TRIGGER orders_legacy_amount_sync
    BEFORE INSERT OR UPDATE ON app.orders
    FOR EACH ROW EXECUTE FUNCTION pgsafe.sync_column_pair('legacy_amount', 'legacy_amount_big');

-- 5. The rows that were there before the trigger.
DO $batch$
DECLARE
    moved integer;
BEGIN
    LOOP
        UPDATE app.orders AS t
           SET legacy_amount_big = t.legacy_amount
         WHERE t.order_id IN (
                   SELECT order_id
                     FROM app.orders
                    WHERE legacy_amount_big IS NULL
                    ORDER BY order_id
                    LIMIT 100
               );
        GET DIAGNOSTICS moved = ROW_COUNT;
        EXIT WHEN moved = 0;
        COMMIT;
    END LOOP;
END
$batch$;

-- 6. NOT NULL on the new column, the two transaction way.
ALTER TABLE app.orders
    ADD CONSTRAINT orders_legacy_amount_big_not_null
    CHECK (legacy_amount_big IS NOT NULL) NOT VALID;

ALTER TABLE app.orders VALIDATE CONSTRAINT orders_legacy_amount_big_not_null;

ALTER TABLE app.orders ALTER COLUMN legacy_amount_big SET NOT NULL;

ALTER TABLE app.orders DROP CONSTRAINT orders_legacy_amount_big_not_null;

-- 7. Contract. Everything that reads legacy_amount has to be out of production
-- before these two statements, and that is a release boundary rather than a
-- line in a migration file.
DROP TRIGGER orders_legacy_amount_sync ON app.orders;

ALTER TABLE app.orders DROP COLUMN legacy_amount;
