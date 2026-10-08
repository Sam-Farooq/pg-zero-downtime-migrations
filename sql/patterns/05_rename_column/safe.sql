-- pgsafe: runner autocommit
--
-- SAFE: expand, migrate, contract. Three releases, not one migration.
--
--   expand    both names exist and are kept equal
--   migrate   readers and writers move to the new name, at their own pace
--   contract  the old name goes, once nothing names it
--
-- The trigger is what makes the middle phase survivable. While it is attached,
-- a writer may use either column and the other follows, so a half finished
-- rolling deploy is correct rather than lucky. pgsafe.sync_column_pair() reads
-- the record through jsonb because a trigger function cannot name a column it
-- was only told about at runtime, and it treats a JSON null rather than a SQL
-- NULL as "not supplied", which is the bug that makes a hand written version of
-- this trigger copy nothing and look fine.
--
-- What this costs: a release where both columns exist, a trigger on the write
-- path for the length of it, and the discipline to not drop the old column in
-- the same deploy that stops using it. The last statement here is in this file
-- for completeness. In a real sequence it belongs in a later migration, after
-- the deploy, and pgsafe.column_dependents() lists what else has to move first:
--
--   SELECT * FROM pgsafe.column_dependents('app.orders', 'note');

SET lock_timeout = '3s';

-- 1. Expand.
ALTER TABLE app.orders ADD COLUMN customer_note text;

-- 2. Keep the pair equal in both directions.
CREATE TRIGGER orders_note_sync
    BEFORE INSERT OR UPDATE ON app.orders
    FOR EACH ROW EXECUTE FUNCTION pgsafe.sync_column_pair('note', 'customer_note');

-- 3. Migrate the rows that predate the trigger. A row written since step 2 is
-- already correct, so this only has the older ones to do.
DO LANGUAGE plpgsql $batch$
DECLARE
    moved integer;
BEGIN
    LOOP
        UPDATE app.orders AS t
           SET customer_note = t.note
         WHERE t.order_id IN (
                   SELECT order_id
                     FROM app.orders
                    WHERE customer_note IS NULL
                      AND note IS NOT NULL
                    ORDER BY order_id
                    LIMIT 100
               );
        GET DIAGNOSTICS moved = ROW_COUNT;
        EXIT WHEN moved = 0;
        COMMIT;
    END LOOP;
END
$batch$;

-- 4. Contract. Not in this deploy: in the one after every reader is on
-- customer_note and the old pods have drained.
DROP TRIGGER orders_note_sync ON app.orders;

-- pgsafe: allow drop_column_breaks_readers nothing names note any more, and this line belongs in a later migration than the rest of this file
ALTER TABLE app.orders DROP COLUMN note;
