-- The state app.orders is left in after every safe.sql in sql/patterns has been
-- applied in order, on top of test/fixtures.sql.
--
-- No BEGIN here: this file reads committed state that the pattern run produced,
-- and test/run.sh applies it only to the database where the safe halves ran.
SELECT plan(26);

-- 01_add_column_default
SELECT has_column('app', 'orders', 'is_gift', 'the constant default column is there');
SELECT col_not_null('app', 'orders', 'public_id', 'and the volatile one ended up NOT NULL');
SELECT is(
    (SELECT count(DISTINCT public_id) FROM app.orders)::bigint,
    500::bigint,
    'the batched backfill gave all 500 rows a distinct uuid'
);
SELECT is_empty(
    $$SELECT conname FROM pg_constraint WHERE conname = 'orders_public_id_not_null'$$,
    'and the scaffolding CHECK was dropped afterwards'
);

-- 02_set_not_null
SELECT col_not_null('app', 'orders', 'shipping_country', 'shipping_country is NOT NULL');
SELECT is(
    (SELECT count(*) FROM app.orders WHERE shipping_country = 'ZZ')::bigint,
    (SELECT count(*) FROM generate_series(1, 500) AS g WHERE g % 7 = 0)::bigint,
    'and exactly the rows the fixture left empty carry the filler'
);

-- 03_create_index
SELECT is(
    (SELECT count(*) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
      WHERE c.relname = 'orders_customer_id_idx' AND i.indisvalid)::bigint,
    1::bigint,
    'the concurrent index exists and is valid'
);
SELECT is(
    (SELECT c.conname FROM pg_constraint c
      WHERE c.conrelid = 'app.orders'::regclass AND c.contype = 'u'),
    'orders_reference_key'::name,
    'the unique constraint exists'
);
-- ADD CONSTRAINT ... UNIQUE USING INDEX renames the index it adopts to the
-- constraint's name, which is documented PostgreSQL behaviour, so the name the
-- pattern built it under is gone by now and cannot be what proves adoption.
-- What proves it is that no second index exists: a constraint that built its own
-- would leave orders_reference_uq sitting there beside it.
SELECT is(
    (SELECT count(*)::int FROM pg_class WHERE relname = 'orders_reference_uq'),
    0,
    'the concurrently built index is not left behind beside the constraint'
);
-- NOT indisprimary: orders_pkey is unique too, and counting it made the first
-- version of this assertion say two where it meant one.
SELECT is(
    (SELECT count(*)::int FROM pg_index x
      WHERE x.indrelid = 'app.orders'::regclass
        AND x.indisunique AND NOT x.indisprimary),
    1,
    'and it adopted that index rather than building a second unique one'
);
SELECT is_empty(
    $$SELECT relname FROM pg_class WHERE relname = 'orders_unshipped_idx'$$,
    'the partial index was dropped concurrently'
);

-- 04_change_type
SELECT is(
    (SELECT format_type(a.atttypid, a.atttypmod) FROM pg_attribute a
      WHERE a.attrelid = 'app.orders'::regclass AND a.attname = 'reference'),
    'character varying(64)',
    'the free widening happened in place'
);
SELECT hasnt_column('app', 'orders', 'legacy_amount', 'the integer column is gone');
SELECT col_not_null('app', 'orders', 'legacy_amount_big', 'and the bigint one is NOT NULL');
-- Both sides cast: sum() over a bigint column returns numeric while sum() over
-- generate_series returns bigint, and is(numeric, bigint, text) has no overload.
SELECT is(
    (SELECT sum(legacy_amount_big) FROM app.orders)::numeric,
    (SELECT sum((g * 137) % 90000) FROM generate_series(1, 500) AS g)::numeric,
    'with every value carried across by the backfill, not just the row count'
);

-- 05_rename_column
SELECT hasnt_column('app', 'orders', 'note', 'the old column name is gone');
SELECT is(
    (SELECT count(*) FROM app.orders WHERE customer_note IS NULL)::bigint,
    (SELECT count(*) FROM generate_series(1, 500) AS g WHERE g % 11 = 0)::bigint,
    'and the new one holds what the old one did, nulls included'
);
SELECT is(
    (SELECT count(*) FROM pg_trigger
      WHERE tgrelid = 'app.orders'::regclass AND NOT tgisinternal)::bigint,
    0::bigint,
    'both dual write triggers were dropped in the contract phase'
);

-- 06_add_foreign_key
SELECT ok(
    (SELECT c.convalidated FROM pg_constraint c WHERE c.conname = 'orders_customer_id_fkey'),
    'the foreign key is validated rather than left NOT VALID'
);

-- 07_lock_timeout
SELECT ok(
    (SELECT pg_get_expr(d.adbin, d.adrelid) FROM pg_attrdef d
      JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
     WHERE d.adrelid = 'app.orders'::regclass AND a.attname = 'status') LIKE '%placed%',
    'the guarded statement set the default it was meant to set'
);

-- 08_attach_partition
SELECT is(
    (SELECT array_agg(p.partition_name ORDER BY p.partition_name)
       FROM pgsafe.partitions('app.events') AS p),
    ARRAY['app.events_2026q2', 'app.events_2026q3'],
    'the third quarter was attached and the first was detached'
);
SELECT is_empty(
    $$SELECT partition_name FROM pgsafe.pending_detaches()$$,
    'and the concurrent detach finished rather than being left pending'
);
SELECT is(
    (SELECT count(*) FROM pg_index i WHERE i.indrelid = 'app.events_2026q3'::regclass)::bigint,
    1::bigint,
    'the new partition carries the parent index, built concurrently and adopted'
);
SELECT is(
    (SELECT count(*) FROM app.events)::bigint,
    200::bigint,
    'the parent now holds the two attached quarters'
);
SELECT is(
    (SELECT count(*) FROM app.events_2026q1)::bigint,
    100::bigint,
    'and the detached quarter is still a table with its rows in it'
);

-- And the point of all of it: nothing was lost on the way through.
SELECT is((SELECT count(*) FROM app.orders)::bigint, 500::bigint, 'still 500 orders');

SELECT * FROM finish();
