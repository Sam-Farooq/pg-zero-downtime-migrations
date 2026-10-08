-- pgsafe: runner autocommit
--
-- SAFE: the same foreign key in two transactions.
--
-- NOT VALID means "enforce this from now on, and do not look at what is already
-- here". The first statement is a catalogue write, so the lock on both tables is
-- held for microseconds. The second does the scan, under SHARE UPDATE EXCLUSIVE
-- on the child and ROW SHARE on the parent, and neither of those blocks a
-- reader or a writer.
--
-- The two statements have to be two transactions. Running them in one holds the
-- first lock across the scan, which is the thing being avoided.
--
-- What this costs: between the two statements the constraint exists and is not
-- trusted. The planner ignores an unvalidated constraint, so a query that could
-- have used it for a join removal does not, and if the second statement is
-- forgotten the state is permanent and silent.
-- pgsafe.unvalidated_constraints() is the query that finds it afterwards.
--
-- If VALIDATE fails, it fails on real orphan rows, and the fix is a data
-- question rather than a migration one. The constraint stays NOT VALID until it
-- is answered, and new writes are enforced the whole time.

SET lock_timeout = '3s';

-- 1. Catalogue only. New and updated rows are checked from here.
ALTER TABLE app.orders
    ADD CONSTRAINT orders_customer_id_fkey
    FOREIGN KEY (customer_id) REFERENCES app.customers (customer_id)
    NOT VALID;

-- 2. The scan, in its own transaction, under a lighter lock.
ALTER TABLE app.orders VALIDATE CONSTRAINT orders_customer_id_fkey;

-- 3. What to run if step 2 never happened.
SELECT * FROM pgsafe.unvalidated_constraints();
