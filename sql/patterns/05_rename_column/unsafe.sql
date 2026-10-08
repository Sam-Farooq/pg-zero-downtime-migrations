-- UNSAFE: renaming a column that something already reads.
--
-- The statement itself is not the problem. It is a catalogue update, it holds
-- ACCESS EXCLUSIVE for microseconds, and on a billion row table it is as fast
-- as on an empty one.
--
-- What breaks is everything deployed. A query that names note gets
-- "column does not exist" from the instant this commits, and during a rolling
-- deploy the old and the new code are both running. There is no ordering of the
-- rename and the deploy that avoids it: rename first and the old pods fail,
-- deploy first and the new pods fail.
--
-- This is the one pattern in the catalogue where the unsafe statement is unsafe
-- for a reason that has nothing to do with locks, which is why a linter that
-- only knows about lock modes will pass it.
--
-- Safe form: ./safe.sql

ALTER TABLE app.orders RENAME COLUMN note TO customer_note;
