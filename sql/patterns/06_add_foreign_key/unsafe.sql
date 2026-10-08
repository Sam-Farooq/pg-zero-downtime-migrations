-- pgsafe: runner autocommit
--
-- UNSAFE: a foreign key added in one statement.
--
-- PostgreSQL has to prove that every row in app.orders already has a matching
-- customer, so it scans the child table. It does that holding SHARE ROW
-- EXCLUSIVE on both tables, which does not block reads and does block every
-- write to either of them, including writes to the parent that have nothing to
-- do with the key.
--
-- The lock on the parent is the part that catches people out. Adding a key from
-- a rarely written child to a busy parent stops writes on the busy table.
--
-- Lock:  SHARE ROW EXCLUSIVE on both tables, for the length of the scan
-- Reads: served
-- Writes: blocked on both tables
-- Safe form: ./safe.sql

ALTER TABLE app.orders
    ADD CONSTRAINT orders_customer_id_fkey
    FOREIGN KEY (customer_id) REFERENCES app.customers (customer_id);
