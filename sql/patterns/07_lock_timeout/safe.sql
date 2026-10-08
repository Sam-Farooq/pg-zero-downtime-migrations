-- pgsafe: runner autocommit
--
-- SAFE: bound the wait, look first, and retry.
--
-- pgsafe.run_guarded() sets lock_timeout for the transaction, runs the
-- statement, and on SQLSTATE 55P03 (lock_not_available) waits and tries again.
-- Each failed attempt is a subtransaction that rolls back, which releases its
-- place in the queue, so the traffic that piled up behind it drains between
-- attempts. That is the difference between a bounded wait and a bounded failure.
--
-- Two limits are deliberate. CONCURRENTLY is refused rather than attempted,
-- because a function body is a transaction and CONCURRENTLY cannot run in one.
-- And the statement is not committed until the caller commits, so this is a
-- helper for one DDL statement at a time rather than a migration runner.
--
-- 3 seconds and 5 attempts are conventions in this repository, not measurements.
-- Nothing here has timed a real migration. The number that matters is whether
-- the wait is shorter than the patience of whatever is in front of the
-- database, and that is a property of the deployment rather than of Postgres.

SET lock_timeout = '3s';

-- 1. Look before taking the lock. Every row with ok = false is a reason to wait.
SELECT * FROM pgsafe.preflight();

-- 2. Who is on the table right now, and the statement that would clear it.
SELECT * FROM pgsafe.blockers('app.orders');

-- 3. The change, with a bounded wait and four retries behind it.
SELECT *
  FROM pgsafe.run_guarded(
           $stmt$ALTER TABLE app.orders ALTER COLUMN status SET DEFAULT 'placed'$stmt$,
           '3s',
           5,
           interval '2 seconds'
       );

-- 4. Anything still waiting, after the fact.
SELECT * FROM pgsafe.lock_queue();
