-- Attaching and detaching, which is the same two tricks as the rest of the
-- catalogue pointed at a different pair of statements.
BEGIN;
SELECT plan(17);

CREATE SCHEMA pgsafe_test;
CREATE TABLE pgsafe_test.events (
    event_id    bigint,
    occurred_at date NOT NULL,
    kind        text NOT NULL
) PARTITION BY RANGE (occurred_at);

CREATE TABLE pgsafe_test.events_q1 PARTITION OF pgsafe_test.events
    FOR VALUES FROM ('2026-01-01') TO ('2026-04-01');

CREATE TABLE pgsafe_test.events_q2 (LIKE pgsafe_test.events);

INSERT INTO pgsafe_test.events (event_id, occurred_at, kind)
    SELECT g, date '2026-01-01' + (g % 89), 'placed' FROM generate_series(1, 20) AS g;
INSERT INTO pgsafe_test.events_q2 (event_id, occurred_at, kind)
    SELECT 100 + g, date '2026-04-01' + (g % 90), 'placed' FROM generate_series(1, 20) AS g;

SELECT is(
    (SELECT count(*) FROM pgsafe.partitions('pgsafe_test.events'))::bigint,
    1::bigint,
    'one partition is attached to start with'
);
SELECT ok(
    (SELECT p.bound FROM pgsafe.partitions('pgsafe_test.events') AS p) LIKE 'FOR VALUES FROM%',
    'and its bound is reported as PostgreSQL writes it'
);
SELECT ok(
    NOT (SELECT p.detach_pending FROM pgsafe.partitions('pgsafe_test.events') AS p),
    'with no detach half done'
);
SELECT throws_ok(
    $$SELECT * FROM pgsafe.partitions('pgsafe_test.events_q2')$$,
    '42809',
    NULL,
    'a plain table has no partitions, and saying so beats returning none'
);

-- The CHECK that lets the attach skip its scan.
SELECT ok(
    pgsafe.range_bound_check('pgsafe_test.events_q2', 'occurred_at', '2026-04-01', '2026-07-01')
        LIKE '%IS NOT NULL%>=%<%NOT VALID;',
    'the generated CHECK carries the null test and both ends of the bound'
);
SELECT throws_ok(
    $$SELECT pgsafe.range_bound_check('pgsafe_test.events_q2', 'occurred_at', '2026-04-01', NULL)$$,
    '22023',
    NULL,
    'an open ended bound is refused rather than generated wrongly'
);
SELECT ok(
    pgsafe.attach_will_scan('pgsafe_test.events_q2', 'occurred_at', '2026-04-01', '2026-07-01'),
    'with no CHECK in place, the attach would scan'
);

ALTER TABLE pgsafe_test.events_q2
    ADD CONSTRAINT events_q2_bound
    CHECK (occurred_at IS NOT NULL
           AND occurred_at >= '2026-04-01'
           AND occurred_at < '2026-07-01');

SELECT ok(
    NOT pgsafe.attach_will_scan('pgsafe_test.events_q2', 'occurred_at', '2026-04-01', '2026-07-01'),
    'and with a validated one it would not'
);

-- The plan.
SELECT is(
    (SELECT count(*) FROM pgsafe.plan_attach_partition(
        'pgsafe_test.events', 'pgsafe_test.events_q2', 'occurred_at', '2026-04-01', '2026-07-01'))::bigint,
    4::bigint,
    'the attach plan is four statements'
);
SELECT is(
    (SELECT s.lock_mode FROM pgsafe.plan_attach_partition(
        'pgsafe_test.events', 'pgsafe_test.events_q2', 'occurred_at', '2026-04-01', '2026-07-01') AS s
      WHERE s.step = 2),
    'SHARE UPDATE EXCLUSIVE',
    'the scan is the second one, under the lock that lets traffic through'
);
SELECT ok(
    (SELECT s.statement FROM pgsafe.plan_attach_partition(
        'pgsafe_test.events', 'pgsafe_test.events_q2', 'occurred_at', '2026-04-01', '2026-07-01') AS s
      WHERE s.step = 3) LIKE '%ATTACH PARTITION%FOR VALUES FROM%',
    'the third is the attach itself'
);
SELECT is(
    (SELECT s.work FROM pgsafe.plan_attach_partition(
        'pgsafe_test.events', 'pgsafe_test.events_q2', 'occurred_at', '2026-04-01', '2026-07-01') AS s
      WHERE s.step = 3),
    'none',
    'and it does no work, because step two already did it'
);
SELECT throws_ok(
    $$SELECT * FROM pgsafe.plan_attach_partition(
        'pgsafe_test.events', 'pgsafe_test.events_q1', 'occurred_at', '2026-01-01', '2026-04-01')$$,
    '55000',
    NULL,
    'a partition that is already attached is refused'
);
SELECT throws_ok(
    $$SELECT * FROM pgsafe.plan_attach_partition(
        'pgsafe_test.events_q1', 'pgsafe_test.events_q2', 'occurred_at', '2026-04-01', '2026-07-01')$$,
    '42809',
    NULL,
    'and so is a parent that is not partitioned'
);

-- The detach.
SELECT ok(
    (SELECT s.statement FROM pgsafe.plan_detach_partition(
        'pgsafe_test.events', 'pgsafe_test.events_q1') AS s WHERE s.step = 1)
        LIKE '%DETACH PARTITION%CONCURRENTLY;',
    'the detach plan uses the concurrent form'
);
SELECT throws_ok(
    $$SELECT * FROM pgsafe.plan_detach_partition('pgsafe_test.events', 'pgsafe_test.events_q2')$$,
    '55000',
    NULL,
    'and refuses a table that is not a partition of that parent'
);
SELECT is_empty(
    $$SELECT partition_name FROM pgsafe.pending_detaches()$$,
    'nothing in this database is mid detach'
);

SELECT * FROM finish();
ROLLBACK;
