-- The verdicts. These are the claims the README makes about rewrites.
BEGIN;
SELECT plan(16);

SELECT is((pgsafe.parse_type('varchar(32)')).base::text, 'character varying', 'the base resolves');
SELECT is((pgsafe.parse_type('varchar(32)')).modifier, '32', 'the modifier is read off the text');
SELECT is(
    (pgsafe.parse_type('timestamp(3) with time zone')).base::text,
    'timestamp with time zone',
    'a modifier in the middle of a type name is handled'
);
SELECT is((pgsafe.parse_type('bigint')).modifier, NULL, 'no parentheses means no modifier');

SELECT throws_ok(
    $$SELECT pgsafe.parse_type('wishful')$$,
    '42704',
    NULL,
    'a type the server does not know is refused'
);
SELECT throws_ok(
    $$SELECT pgsafe.parse_type('varchar()')$$,
    '22023',
    NULL,
    'an empty modifier is refused'
);

SELECT is(
    (pgsafe.type_change('varchar(32)', 'varchar(32)')).cost,
    'no_change',
    'the same type twice is no change'
);
SELECT is(
    (pgsafe.type_change('varchar(32)', 'varchar(64)')).cost,
    'no_rewrite',
    'widening a varchar limit is a relabel'
);
SELECT is(
    (pgsafe.type_change('varchar(64)', 'varchar(32)')).cost,
    'rewrite',
    'narrowing a varchar limit checks every row'
);
SELECT is(
    (pgsafe.type_change('varchar(32)', 'text')).cost,
    'no_rewrite',
    'varchar to text is binary coercible with no modifier to verify'
);
SELECT is(
    (pgsafe.type_change('text', 'varchar(32)')).cost,
    'rewrite',
    'text to varchar(n) is binary coercible and still has to verify the limit'
);

-- The one the folklore gets wrong.
SELECT is(
    (pgsafe.type_change('integer', 'bigint')).cost,
    'rewrite',
    'integer to bigint is a rewrite, because the two widths differ on disk'
);
SELECT ok(
    pgsafe.rewrites('integer', 'bigint'),
    'and the short answer agrees'
);
SELECT ok(
    NOT pgsafe.rewrites('varchar(32)', 'varchar(64)'),
    'while the varchar widening does not'
);

-- character(n) pads, so nothing involving it is free.
SELECT is(
    (pgsafe.type_change('char(10)', 'char(20)')).cost,
    'rewrite',
    'character(n) changes every stored value when n changes'
);

-- And the honest refusal: no rule means no answer, rather than a guess.
SELECT throws_ok(
    $$SELECT pgsafe.rewrites('numeric(10,2)', 'numeric(12,2)')$$,
    '0A000',
    NULL,
    'numeric modifiers have no rule here, and rewrites() says so instead of guessing'
);

SELECT * FROM finish();
ROLLBACK;
