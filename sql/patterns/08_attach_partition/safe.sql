-- pgsafe: runner autocommit
--
-- SAFE: the same attach without the scan, and the same detach without closing
-- the parent.
--
-- The attach is the SET NOT NULL trick again, pointed at a different statement.
-- A valid CHECK that implies the partition constraint lets PostgreSQL skip the
-- scan, so the scan moves into VALIDATE CONSTRAINT, where it runs under SHARE
-- UPDATE EXCLUSIVE and blocks nothing. The IS NOT NULL in the CHECK is not
-- decoration: a range partition constraint is
-- (col IS NOT NULL AND col >= lower AND col < upper), and a CHECK without the
-- null test does not imply it, so the scan happens anyway and everything looks
-- like it worked.
--
-- DETACH ... CONCURRENTLY takes SHARE UPDATE EXCLUSIVE instead of ACCESS
-- EXCLUSIVE. The price is that it cannot run inside a transaction block, it
-- waits for transactions that can still see the partition, and if it is
-- interrupted the partition is left marked detach pending: attached for some
-- sessions and not for others, with no error anywhere.
-- pgsafe.pending_detaches() is the query that finds that, and it prints the
-- FINALIZE statement which is the only way out.
--
-- The index is the other half of the cost. Any index the parent has and the
-- partition lacks is created during ATTACH, under the lock on the partition.
-- An equivalent index that already exists is adopted instead, so building it
-- concurrently beforehand moves that work outside the lock as well.
--
-- What this costs: six statements instead of one, and a CHECK that exists for
-- two transactions and is then dropped. The partition constraint says the same
-- thing afterwards.

SET lock_timeout = '3s';

-- 0. Ask, rather than assume. True means the attach would scan.
SELECT pgsafe.attach_will_scan('app.events_2026q3', 'occurred_at', '2026-07-01', '2026-10-01');

-- 1. The index the parent has, built concurrently so the attach adopts it
-- rather than building it while holding the partition closed.
CREATE INDEX CONCURRENTLY events_2026q3_kind_idx ON app.events_2026q3 (kind);

SELECT pgsafe.assert_index_valid('app.events_2026q3_kind_idx');

-- 2. The CHECK that matches the bound, not yet validated.
ALTER TABLE app.events_2026q3
    ADD CONSTRAINT events_2026q3_bound
    CHECK (occurred_at IS NOT NULL
           AND occurred_at >= '2026-07-01'
           AND occurred_at < '2026-10-01') NOT VALID;

-- 3. The scan, in its own transaction.
ALTER TABLE app.events_2026q3 VALIDATE CONSTRAINT events_2026q3_bound;

-- 4. Now the attach is a catalogue change, index included.
ALTER TABLE app.events
    ATTACH PARTITION app.events_2026q3
    FOR VALUES FROM ('2026-07-01') TO ('2026-10-01');

-- 5. The CHECK is redundant now that the partition constraint exists.
ALTER TABLE app.events_2026q3 DROP CONSTRAINT events_2026q3_bound;

-- 6. The detach, without closing the parent.
ALTER TABLE app.events DETACH PARTITION app.events_2026q1 CONCURRENTLY;

-- 7. And the check nothing else does.
SELECT * FROM pgsafe.pending_detaches();
