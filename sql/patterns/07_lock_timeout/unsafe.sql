-- pgsafe: runner autocommit
--
-- UNSAFE: three ways to get the lock wait wrong, on a statement that is itself
-- harmless.
--
-- ALTER COLUMN SET DEFAULT is a catalogue change. It reads no row and it still
-- needs ACCESS EXCLUSIVE, which is the whole point of this pattern: the danger
-- is not the work, it is the wait for the lock.
--
-- A request for ACCESS EXCLUSIVE queues behind every open transaction holding
-- any conflicting lock, including one that is idle in transaction after reading
-- the table ten minutes ago. While it waits it is ahead of everything that
-- arrives after it, because PostgreSQL does not let later requests overtake a
-- waiter. So a one millisecond catalogue change behind a long read becomes a
-- full outage on that table for as long as the read lasts.
--
--   statement 1  lock_timeout = 0 is the default, and it means wait forever
--   statement 3  SET LOCAL outside a transaction block applies to nothing.
--                PostgreSQL warns and carries on, so statement 4 runs with
--                whatever lock_timeout the session already had
--
-- A short timeout is only safe if something retries. On its own it converts an
-- outage into a failed deploy, which is better and is not the same as working.
--
-- Safe form: ./safe.sql

SET lock_timeout = 0;

ALTER TABLE app.orders ALTER COLUMN status SET DEFAULT 'placed';

SET LOCAL lock_timeout = '3s';

ALTER TABLE app.orders ALTER COLUMN status DROP DEFAULT;
