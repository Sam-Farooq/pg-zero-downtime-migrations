-- pgsafe: runner autocommit
--
-- SAFE: the same NOT NULL, in four transactions, with no scan under a lock that
-- blocks reads.
--
-- The sequence exists because of one PostgreSQL 12 change: SET NOT NULL skips
-- its scan when a valid CHECK (col IS NOT NULL) already proves the column. So
-- the scan is moved into VALIDATE CONSTRAINT, which runs under SHARE UPDATE
-- EXCLUSIVE and conflicts with neither readers nor writers.
--
-- The two halves have to be two transactions. ADD CONSTRAINT ... NOT VALID and
-- VALIDATE CONSTRAINT in one transaction is the same lock held across both, so
-- it buys nothing.
--
-- 'ZZ' is a filler and a decision, not a fact: ISO 3166 reserves ZZ for private
-- use, so it reads as "we do not know" rather than as a country. Picking it is
-- whoever owns the data's job, and the honest alternative is to leave the
-- column nullable.
--
-- On PostgreSQL 11 this plan still works and the last statement still scans.

SET lock_timeout = '3s';

-- 1. Fill the gaps, in batches that commit.
DO $batch$
DECLARE
    moved integer;
BEGIN
    LOOP
        UPDATE app.orders AS t
           SET shipping_country = 'ZZ'
         WHERE t.order_id IN (
                   SELECT order_id
                     FROM app.orders
                    WHERE shipping_country IS NULL
                    ORDER BY order_id
                    LIMIT 100
               );
        GET DIAGNOSTICS moved = ROW_COUNT;
        EXIT WHEN moved = 0;
        COMMIT;
    END LOOP;
END
$batch$;

-- 2. Catalogue only: no existing row is read, and new writes are checked.
ALTER TABLE app.orders
    ADD CONSTRAINT orders_shipping_country_not_null
    CHECK (shipping_country IS NOT NULL) NOT VALID;

-- 3. The scan, under a lock that lets traffic through. Its own transaction.
ALTER TABLE app.orders VALIDATE CONSTRAINT orders_shipping_country_not_null;

-- 4. Now instant, because the valid CHECK answers the question.
ALTER TABLE app.orders ALTER COLUMN shipping_country SET NOT NULL;

-- 5. Optional. The CHECK is redundant once the column is NOT NULL, and keeping
-- it means a second expression evaluated on every write.
ALTER TABLE app.orders DROP CONSTRAINT orders_shipping_country_not_null;
