-- pgsafe: runner autocommit
--
-- SAFE: the same two columns, in four transactions.
--
-- Statement 1 is here to make the contrast concrete. A constant default is not
-- evaluated per row: since PostgreSQL 11 the value is written once into
-- pg_attribute.attmissingval and handed out by the reader when the row has no
-- stored value for the column. ADD COLUMN ... NOT NULL DEFAULT false is a
-- catalogue change on a table of any size.
--
-- The volatile case cannot borrow that, so it is split: add the column empty,
-- give it the default for new rows only, fill the old rows in batches that each
-- commit, and make it NOT NULL once it is full.
--
-- What this costs: between statement 2 and the end of the backfill the column
-- is nullable, and application code has to cope with that. There is no version
-- of this where the column is both full and never rewritten.

SET lock_timeout = '3s';

-- 1. Constant default. One statement, no rewrite, any table size.
ALTER TABLE app.orders
    ADD COLUMN is_gift boolean NOT NULL DEFAULT false;

-- 2. Volatile default, part one: an empty column is catalogue only.
ALTER TABLE app.orders
    ADD COLUMN public_id uuid;

-- 3. Rows inserted from here get a value. Rows already stored do not.
ALTER TABLE app.orders
    ALTER COLUMN public_id SET DEFAULT gen_random_uuid();

-- 4. The old rows, 100 at a time, committing each batch.
--
-- The predicate is the progress marker: a row that still matches is a row still
-- to do, so an interrupted run resumes instead of starting again. COMMIT inside
-- a DO block requires the block to run at the top level, which is why this file
-- declares the autocommit runner above.
DO $batch$
DECLARE
    moved integer;
BEGIN
    LOOP
        UPDATE app.orders AS t
           SET public_id = gen_random_uuid()
         WHERE t.order_id IN (
                   SELECT order_id
                     FROM app.orders
                    WHERE public_id IS NULL
                    ORDER BY order_id
                    LIMIT 100
               );
        GET DIAGNOSTICS moved = ROW_COUNT;
        EXIT WHEN moved = 0;
        COMMIT;
        PERFORM pg_sleep(0.05);
    END LOOP;
END
$batch$;

-- 5. NOT NULL without the scan. See ../02_set_not_null/safe.sql for why this
-- is three statements and not one.
ALTER TABLE app.orders
    ADD CONSTRAINT orders_public_id_not_null CHECK (public_id IS NOT NULL) NOT VALID;

ALTER TABLE app.orders VALIDATE CONSTRAINT orders_public_id_not_null;

ALTER TABLE app.orders ALTER COLUMN public_id SET NOT NULL;

ALTER TABLE app.orders DROP CONSTRAINT orders_public_id_not_null;
