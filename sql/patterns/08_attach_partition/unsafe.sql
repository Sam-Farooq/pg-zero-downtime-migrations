-- pgsafe: runner autocommit
--
-- UNSAFE: attaching a partition with a scan, and detaching one with the parent
-- closed.
--
-- ATTACH PARTITION has to prove that every row in app.events_2026q3 belongs
-- inside the bound, so it scans the table. It holds SHARE UPDATE EXCLUSIVE on
-- the parent and ACCESS EXCLUSIVE on the table being attached while it does.
-- Reads of the parent carry on; the table being attached is closed, which
-- matters when it is the one already taking the writes.
--
-- DETACH PARTITION is the worse of the two. ACCESS EXCLUSIVE on the parent
-- stops reads of the whole partitioned table, including the partitions that are
-- not being detached and have nothing to do with it.
--
-- Safe form: ./safe.sql

ALTER TABLE app.events
    ATTACH PARTITION app.events_2026q3
    FOR VALUES FROM ('2026-07-01') TO ('2026-10-01');

ALTER TABLE app.events DETACH PARTITION app.events_2026q1;
