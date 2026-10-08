-- The conflict matrix, and the two questions derived from it.
BEGIN;
SELECT plan(14);

SELECT is(
    (SELECT count(*) FROM pgsafe.lock_mode)::bigint,
    8::bigint,
    'PostgreSQL 16 has eight table level lock modes'
);

SELECT is(
    (SELECT count(*) FROM pgsafe.lock_conflict)::bigint,
    38::bigint,
    'the matrix has 38 directed conflicts'
);

-- The loader mirrors every seeded pair, so this is a test of the loader rather
-- than of how carefully the list was typed.
SELECT is_empty(
    $$SELECT a.held, a.requested FROM pgsafe.lock_conflict a
       WHERE NOT EXISTS (
           SELECT 1 FROM pgsafe.lock_conflict b
            WHERE b.held = a.requested AND b.requested = a.held
       )$$,
    'the matrix is symmetric'
);

SELECT is(
    (SELECT count(*) FROM pgsafe.conflicts_with('ACCESS EXCLUSIVE'))::bigint,
    8::bigint,
    'ACCESS EXCLUSIVE conflicts with all eight, itself included'
);

SELECT is(
    (SELECT count(*) FROM pgsafe.conflicts_with('ACCESS SHARE'))::bigint,
    1::bigint,
    'a plain SELECT only waits for ACCESS EXCLUSIVE'
);

SELECT is(
    (SELECT count(*) FROM pgsafe.conflicts_with('SHARE UPDATE EXCLUSIVE'))::bigint,
    5::bigint,
    'SHARE UPDATE EXCLUSIVE conflicts with five modes'
);

SELECT ok(
    'SHARE UPDATE EXCLUSIVE' IN (SELECT pgsafe.conflicts_with('SHARE UPDATE EXCLUSIVE')),
    'it conflicts with itself, which is why two concurrent builds serialise'
);

SELECT ok(
    NOT pgsafe.blocks_reads('SHARE UPDATE EXCLUSIVE'),
    'a concurrent index build serves reads'
);

SELECT ok(
    NOT pgsafe.blocks_writes('SHARE UPDATE EXCLUSIVE'),
    'a concurrent index build serves writes'
);

SELECT ok(
    pgsafe.blocks_writes('SHARE') AND NOT pgsafe.blocks_reads('SHARE'),
    'a plain CREATE INDEX stops writes and serves reads'
);

SELECT ok(
    pgsafe.blocks_reads('ACCESS EXCLUSIVE') AND pgsafe.blocks_writes('ACCESS EXCLUSIVE'),
    'ACCESS EXCLUSIVE stops everything'
);

SELECT throws_ok(
    $$SELECT pgsafe.conflicts_with('ALMOST EXCLUSIVE')$$,
    '42704',
    NULL,
    'an invented lock mode is refused rather than returning nothing'
);

-- Every row in the statement catalogue has to name a mode the matrix knows,
-- which the foreign key already enforces, and a work value the check allows.
SELECT is_empty(
    $$SELECT form FROM pgsafe.statement_lock
       WHERE work NOT IN ('none', 'write', 'scan', 'rewrite', 'index_build')$$,
    'every statement form declares a known kind of work'
);

SELECT is_empty(
    $$SELECT form FROM pgsafe.statement_impact
       WHERE lock_mode = 'ACCESS EXCLUSIVE' AND NOT blocks_reads$$,
    'nothing claims ACCESS EXCLUSIVE without blocking reads'
);

SELECT * FROM finish();
ROLLBACK;
