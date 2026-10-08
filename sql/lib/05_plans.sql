-- 05_plans.sql
--
-- Generators. Each one takes the change somebody wants and returns the
-- statements that get there without blocking reads, numbered by the transaction
-- they belong in. A step whose tx differs from the one before it has to be
-- committed first, which is the part a single migration file cannot express and
-- the reason these return rows instead of one script.
--
-- The lock mode on every step is read from pgsafe.statement_lock, so a plan
-- cannot disagree with the matrix in 02_lock_matrix.sql.

CREATE OR REPLACE FUNCTION pgsafe.form_lock(p_form text)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    mode text;
BEGIN
    SELECT lock_mode INTO mode FROM pgsafe.statement_lock WHERE form = p_form;
    IF mode IS NULL THEN
        RAISE EXCEPTION 'unknown statement form: %', p_form
            USING ERRCODE = 'undefined_object',
                  HINT = 'SELECT form FROM pgsafe.statement_lock ORDER BY form';
    END IF;
    RETURN mode;
END
$$;

-- pg_class.relname, rather than the text of a regclass, which drops the schema
-- when it is on the search_path and keeps it when it is not. A generated
-- constraint name has to be stable either way.
CREATE OR REPLACE FUNCTION pgsafe.relation_name(p_table regclass)
RETURNS name
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    rel name;
BEGIN
    SELECT c.relname INTO rel FROM pg_class c WHERE c.oid = p_table;
    IF rel IS NULL THEN
        RAISE EXCEPTION 'no relation with oid %', p_table::oid
            USING ERRCODE = 'undefined_table';
    END IF;
    RETURN rel;
END
$$;

-- The single column a batched backfill can walk. A composite key needs a
-- different loop, so this refuses rather than generating something wrong.
CREATE OR REPLACE FUNCTION pgsafe.primary_key_column(p_table regclass)
RETURNS name
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    keys text[];
    column_name name;
BEGIN
    -- indkey is an int2vector. Reading it as text and splitting avoids relying
    -- on a cast to smallint[], which is not registered everywhere.
    SELECT string_to_array(i.indkey::text, ' ') INTO keys
      FROM pg_index i
     WHERE i.indrelid = p_table AND i.indisprimary;

    IF keys IS NULL THEN
        RAISE EXCEPTION '% has no primary key', p_table::text
            USING ERRCODE = 'undefined_object',
                  HINT = 'batch on a unique column, or on ctid ranges, and write that loop by hand';
    END IF;

    IF array_length(keys, 1) <> 1 THEN
        RAISE EXCEPTION '% has a composite primary key of % columns', p_table::text, array_length(keys, 1)
            USING ERRCODE = 'feature_not_supported',
                  HINT = 'the generated loop walks one column; write the composite version by hand';
    END IF;

    SELECT a.attname INTO column_name
      FROM pg_attribute a
     WHERE a.attrelid = p_table AND a.attnum = keys[1]::smallint;

    RETURN column_name;
END
$$;

-- A backfill loop that commits every batch.
--
-- The predicate is both the filter and the progress marker: rows that still
-- match are the rows still to do, so an interrupted run restarts where it
-- stopped. COMMIT inside a DO block needs the block to be run at the top level,
-- outside any transaction, which is also what keeps the loop from holding a
-- million row locks at once.
CREATE OR REPLACE FUNCTION pgsafe.backfill_loop(
    p_table      regclass,
    p_assignment text,
    p_predicate  text,
    p_batch      integer DEFAULT 5000,
    p_pause      numeric DEFAULT 0.05
)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    key name := pgsafe.primary_key_column(p_table);
BEGIN
    IF p_batch < 1 THEN
        RAISE EXCEPTION 'batch size must be at least 1, got %', p_batch
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    RETURN format(
$fmt$DO $batch$
DECLARE
    moved integer;
BEGIN
    LOOP
        UPDATE %1$s AS t
           SET %2$s
         WHERE t.%3$I IN (
                   SELECT %3$I
                     FROM %1$s
                    WHERE %4$s
                    ORDER BY %3$I
                    LIMIT %5$s
               );
        GET DIAGNOSTICS moved = ROW_COUNT;
        EXIT WHEN moved = 0;
        COMMIT;
        PERFORM pg_sleep(%6$s);
    END LOOP;
END
$batch$;$fmt$,
        p_table::text, p_assignment, key, p_predicate, p_batch, p_pause);
END
$$;

-- SET NOT NULL without the scan that holds ACCESS EXCLUSIVE over the table.
CREATE OR REPLACE FUNCTION pgsafe.plan_set_not_null(
    p_table      regclass,
    p_column     name,
    p_constraint name DEFAULT NULL,
    p_drop_check boolean DEFAULT true
)
RETURNS SETOF pgsafe.step
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    already_set boolean;
    check_name  name;
BEGIN
    SELECT a.attnotnull INTO already_set
      FROM pg_attribute a
     WHERE a.attrelid = p_table AND a.attname = p_column
       AND a.attnum > 0 AND NOT a.attisdropped;

    IF already_set IS NULL THEN
        RAISE EXCEPTION 'column %.% does not exist', p_table::text, p_column
            USING ERRCODE = 'undefined_column';
    END IF;

    IF already_set THEN
        RAISE NOTICE '%.% is already NOT NULL', p_table::text, p_column;
        RETURN;
    END IF;

    check_name := coalesce(
        p_constraint,
        left(format('%s_%s_not_null', pgsafe.relation_name(p_table), p_column), 63)::name
    );

    RETURN NEXT (
        1, 1,
        format('ALTER TABLE %s ADD CONSTRAINT %I CHECK (%I IS NOT NULL) NOT VALID;',
               p_table::text, check_name, p_column),
        pgsafe.form_lock('add_check_constraint_not_valid'),
        'none',
        'Catalogue only. Writes are checked from here, so nothing new can violate it while the rest runs.'
    )::pgsafe.step;

    RETURN NEXT (
        2, 2,
        format('ALTER TABLE %s VALIDATE CONSTRAINT %I;', p_table::text, check_name),
        pgsafe.form_lock('validate_constraint'),
        'scan',
        'Its own transaction, and the reason this plan exists: the scan happens under a lock that readers and writers do not conflict with.'
    )::pgsafe.step;

    RETURN NEXT (
        3, 3,
        format('ALTER TABLE %s ALTER COLUMN %I SET NOT NULL;', p_table::text, p_column),
        pgsafe.form_lock('set_not_null_with_valid_check'),
        'none',
        'PostgreSQL 12 and later skip the scan because the valid CHECK already proves it. On 11 this still scans.'
    )::pgsafe.step;

    IF p_drop_check THEN
        RETURN NEXT (
            4, 4,
            format('ALTER TABLE %s DROP CONSTRAINT %I;', p_table::text, check_name),
            pgsafe.form_lock('drop_constraint'),
            'none',
            'Optional. The CHECK is redundant now, and keeping it costs a second expression evaluated on every write.'
        )::pgsafe.step;
    END IF;
END
$$;

-- Add a column, with the rewrite avoided when the default is volatile.
CREATE OR REPLACE FUNCTION pgsafe.plan_add_column(
    p_table    regclass,
    p_column   name,
    p_type     text,
    p_default  text DEFAULT NULL,
    p_not_null boolean DEFAULT false,
    p_batch    integer DEFAULT 5000
)
RETURNS SETOF pgsafe.step
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    parsed   pgsafe.parsed_type := pgsafe.parse_type(p_type);
    volatile_default boolean := pgsafe.expression_is_volatile(p_default);
    step_no  integer := 0;
    tx_no    integer := 0;
    sub      pgsafe.step;
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_attribute a
         WHERE a.attrelid = p_table AND a.attname = p_column
           AND a.attnum > 0 AND NOT a.attisdropped
    ) THEN
        RAISE EXCEPTION 'column %.% already exists', p_table::text, p_column
            USING ERRCODE = 'duplicate_column';
    END IF;

    IF NOT volatile_default THEN
        RETURN NEXT (
            1, 1,
            format('ALTER TABLE %s ADD COLUMN %I %s%s%s;',
                   p_table::text, p_column, parsed.raw,
                   CASE WHEN p_default IS NULL THEN '' ELSE ' DEFAULT ' || p_default END,
                   CASE WHEN p_not_null THEN ' NOT NULL' ELSE '' END),
            pgsafe.form_lock(CASE WHEN p_default IS NULL
                                  THEN 'add_column_no_default'
                                  ELSE 'add_column_constant_default' END),
            'none',
            CASE WHEN p_default IS NULL
                 THEN 'One statement. A nullable column with no default is a catalogue change.'
                 ELSE 'One statement. PostgreSQL 11 and later store a non-volatile default in pg_attribute.attmissingval, so no row is touched.'
            END
        )::pgsafe.step;
        RETURN;
    END IF;

    step_no := 1; tx_no := 1;
    RETURN NEXT (
        step_no, tx_no,
        format('ALTER TABLE %s ADD COLUMN %I %s;', p_table::text, p_column, parsed.raw),
        pgsafe.form_lock('add_column_no_default'),
        'none',
        format('Nullable and with no default, because %s is volatile and a volatile default is evaluated per row under the lock.',
               coalesce(p_default, 'the default'))
    )::pgsafe.step;

    step_no := step_no + 1; tx_no := tx_no + 1;
    RETURN NEXT (
        step_no, tx_no,
        format('ALTER TABLE %s ALTER COLUMN %I SET DEFAULT %s;', p_table::text, p_column, p_default),
        pgsafe.form_lock('set_default'),
        'none',
        'Rows inserted from here get the default. Rows already there are still null, which is what the backfill is for.'
    )::pgsafe.step;

    step_no := step_no + 1; tx_no := tx_no + 1;
    RETURN NEXT (
        step_no, tx_no,
        pgsafe.backfill_loop(
            p_table,
            format('%I = %s', p_column, p_default),
            format('%I IS NULL', p_column),
            p_batch),
        pgsafe.form_lock('backfill_batch'),
        'backfill',
        format('Run outside a transaction: the loop commits every %s rows, and the predicate is its own progress marker.', p_batch)
    )::pgsafe.step;

    IF p_not_null THEN
        FOR sub IN SELECT * FROM pgsafe.plan_set_not_null(p_table, p_column) LOOP
            step_no := step_no + 1;
            RETURN NEXT (
                step_no, tx_no + sub.tx, sub.statement, sub.lock_mode, sub.work, sub.note
            )::pgsafe.step;
        END LOOP;
    END IF;
END
$$;

-- Change a column's type. One statement when the catalogue says it is a
-- relabel, and an expand and contract sequence when it is a rewrite.
CREATE OR REPLACE FUNCTION pgsafe.plan_change_type(
    p_table  regclass,
    p_column name,
    p_to     text,
    p_batch  integer DEFAULT 5000
)
RETURNS SETOF pgsafe.step
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    verdict  pgsafe.type_change_verdict := pgsafe.column_type_change(p_table, p_column, p_to);
    shadow   name := left(format('%s_new', p_column), 63)::name;
    trigger_name name := left(format('%s_%s_sync', pgsafe.relation_name(p_table), p_column), 63)::name;
    step_no  integer := 0;
BEGIN
    IF verdict.cost = 'no_change' THEN
        RAISE NOTICE '%.% is already %', p_table::text, p_column, p_to;
        RETURN;
    END IF;

    IF verdict.cost = 'no_rewrite' THEN
        RETURN NEXT (
            1, 1,
            format('ALTER TABLE %s ALTER COLUMN %I TYPE %s;', p_table::text, p_column, p_to),
            pgsafe.form_lock('alter_column_type_relabel'),
            'index_build',
            format('%s. The heap is untouched and every index on the column is still rebuilt under ACCESS EXCLUSIVE, so bound the wait and check the table is not one of the big ones.', verdict.reason)
        )::pgsafe.step;
        RETURN;
    END IF;

    IF verdict.cost = 'unknown' THEN
        RAISE WARNING 'no rule for %.% to %: %', p_table::text, p_column, p_to, verdict.reason;
    END IF;

    step_no := 1;
    RETURN NEXT (
        step_no, 1,
        format('ALTER TABLE %s ADD COLUMN %I %s;', p_table::text, shadow, p_to),
        pgsafe.form_lock('add_column_no_default'),
        'none',
        format('%s, so the column is replaced rather than altered.', verdict.reason)
    )::pgsafe.step;

    step_no := step_no + 1;
    RETURN NEXT (
        step_no, 2,
        format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON %s FOR EACH ROW EXECUTE FUNCTION pgsafe.sync_column_pair(%L, %L);',
               trigger_name, p_table::text, p_column, shadow),
        pgsafe.form_lock('create_trigger'),
        'none',
        'Both columns stay equal from here, so a writer that knows only the old name is still correct. The trigger takes ACCESS EXCLUSIVE for the catalogue row.'
    )::pgsafe.step;

    step_no := step_no + 1;
    RETURN NEXT (
        step_no, 3,
        pgsafe.backfill_loop(
            p_table,
            format('%I = %I::%s', shadow, p_column, p_to),
            format('%I IS NULL AND %I IS NOT NULL', shadow, p_column),
            p_batch),
        pgsafe.form_lock('backfill_batch'),
        'backfill',
        'A row the cast rejects fails here, in a batch you can retry, rather than halfway through an ALTER TABLE that holds the table.'
    )::pgsafe.step;

    step_no := step_no + 1;
    RETURN NEXT (
        step_no, 4,
        NULL,
        'none',
        'deploy',
        format('Deploy readers and writers that use %I. Nothing else is safe to do until they are all out.', shadow)
    )::pgsafe.step;

    step_no := step_no + 1;
    RETURN NEXT (
        step_no, 5,
        format('DROP TRIGGER %I ON %s;', trigger_name, p_table::text),
        pgsafe.form_lock('drop_trigger'),
        'none',
        'Nothing writes the old column now.'
    )::pgsafe.step;

    step_no := step_no + 1;
    RETURN NEXT (
        step_no, 5,
        format('ALTER TABLE %s DROP COLUMN %I;', p_table::text, p_column),
        pgsafe.form_lock('drop_column'),
        'none',
        format('The new name is %I and it stays. Renaming it back is another rename, with the same problem this plan exists to avoid.', shadow)
    )::pgsafe.step;
END
$$;

-- Rename a column without breaking the readers that are already deployed.
CREATE OR REPLACE FUNCTION pgsafe.plan_rename_column(
    p_table  regclass,
    p_from   name,
    p_to     name,
    p_batch  integer DEFAULT 5000
)
RETURNS SETOF pgsafe.step
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    declared     text := pgsafe.column_type(p_table, p_from);
    was_not_null boolean;
    trigger_name name := left(format('%s_%s_sync', pgsafe.relation_name(p_table), p_from), 63)::name;
    step_no      integer := 0;
    dependent    record;
    sub          pgsafe.step;
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_attribute a
         WHERE a.attrelid = p_table AND a.attname = p_to
           AND a.attnum > 0 AND NOT a.attisdropped
    ) THEN
        RAISE EXCEPTION 'column %.% already exists', p_table::text, p_to
            USING ERRCODE = 'duplicate_column';
    END IF;

    SELECT a.attnotnull INTO was_not_null
      FROM pg_attribute a
     WHERE a.attrelid = p_table AND a.attname = p_from;

    step_no := 1;
    RETURN NEXT (
        step_no, 1,
        format('ALTER TABLE %s ADD COLUMN %I %s;', p_table::text, p_to, declared),
        pgsafe.form_lock('add_column_no_default'),
        'none',
        format('Nullable for now, whatever %I is, because the backfill has not run.', p_from)
    )::pgsafe.step;

    step_no := step_no + 1;
    RETURN NEXT (
        step_no, 2,
        format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON %s FOR EACH ROW EXECUTE FUNCTION pgsafe.sync_column_pair(%L, %L);',
               trigger_name, p_table::text, p_from, p_to),
        pgsafe.form_lock('create_trigger'),
        'none',
        'This is the step that makes a rename safe: for as long as it is attached, a writer may use either name.'
    )::pgsafe.step;

    step_no := step_no + 1;
    RETURN NEXT (
        step_no, 3,
        pgsafe.backfill_loop(
            p_table,
            format('%I = %I', p_to, p_from),
            format('%I IS NULL AND %I IS NOT NULL', p_to, p_from),
            p_batch),
        pgsafe.form_lock('backfill_batch'),
        'backfill',
        'Rows written since step 2 are already correct, so this only has the older ones to do.'
    )::pgsafe.step;

    IF was_not_null THEN
        FOR sub IN SELECT * FROM pgsafe.plan_set_not_null(p_table, p_to) LOOP
            step_no := step_no + 1;
            RETURN NEXT (step_no, 3 + sub.tx, sub.statement, sub.lock_mode, sub.work, sub.note)::pgsafe.step;
        END LOOP;
    END IF;

    step_no := step_no + 1;
    RETURN NEXT (
        step_no, 8,
        NULL,
        'none',
        'deploy',
        format('Deploy every reader and writer onto %I, and wait for the old ones to drain.', p_to)
    )::pgsafe.step;

    step_no := step_no + 1;
    RETURN NEXT (
        step_no, 9,
        format('DROP TRIGGER %I ON %s;', trigger_name, p_table::text),
        pgsafe.form_lock('drop_trigger'),
        'none',
        'Contract phase. From here a reader on the old name gets an error rather than stale data.'
    )::pgsafe.step;

    step_no := step_no + 1;
    RETURN NEXT (
        step_no, 9,
        format('ALTER TABLE %s DROP COLUMN %I;', p_table::text, p_from),
        pgsafe.form_lock('drop_column'),
        'none',
        'Instant, and unrecoverable without a restore. Leave a release between this and the step above.'
    )::pgsafe.step;

    FOR dependent IN SELECT * FROM pgsafe.column_dependents(p_table, p_from) LOOP
        step_no := step_no + 1;
        RETURN NEXT (
            step_no, 9,
            NULL,
            'none',
            'deploy',
            format('Carried over by hand: %s %s (%s). The plan above does not recreate it on %I.',
                   dependent.kind, dependent.name, dependent.detail, p_to)
        )::pgsafe.step;
    END LOOP;
END
$$;

-- Everything in the catalogue that names a column: the list a rename or a drop
-- has to deal with, and the reason neither is one statement.
CREATE OR REPLACE FUNCTION pgsafe.column_dependents(p_table regclass, p_column name)
RETURNS TABLE (
    kind   text,
    name   text,
    detail text
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    col_num smallint;
BEGIN
    SELECT a.attnum INTO col_num
      FROM pg_attribute a
     WHERE a.attrelid = p_table AND a.attname = p_column
       AND a.attnum > 0 AND NOT a.attisdropped;

    IF col_num IS NULL THEN
        RAISE EXCEPTION 'column %.% does not exist', p_table::text, p_column
            USING ERRCODE = 'undefined_column';
    END IF;

    RETURN QUERY
    SELECT 'index'::text,
           i.indexrelid::regclass::text,
           CASE WHEN i.indisunique THEN 'unique' ELSE 'not unique' END
      FROM pg_index i
     WHERE i.indrelid = p_table
       AND col_num = ANY (i.indkey);

    RETURN QUERY
    SELECT 'constraint'::text,
           c.conname::text,
           pg_get_constraintdef(c.oid)
      FROM pg_constraint c
     WHERE c.conrelid = p_table
       AND c.conkey @> ARRAY[col_num];

    RETURN QUERY
    SELECT 'default'::text,
           format('%s.%s', p_table::text, p_column),
           pg_get_expr(d.adbin, d.adrelid)
      FROM pg_attrdef d
     WHERE d.adrelid = p_table AND d.adnum = col_num;

    RETURN QUERY
    SELECT DISTINCT 'view'::text,
           r.ev_class::regclass::text,
           'selects the column'::text
      FROM pg_depend dep
      JOIN pg_rewrite r ON r.oid = dep.objid
     WHERE dep.classid = 'pg_rewrite'::regclass
       AND dep.refclassid = 'pg_class'::regclass
       AND dep.refobjid = p_table
       AND dep.refobjsubid = col_num
       AND r.ev_class <> p_table;

    RETURN QUERY
    SELECT 'trigger'::text,
           t.tgname::text,
           'listed in UPDATE OF'::text
      FROM pg_trigger t
     WHERE t.tgrelid = p_table
       AND NOT t.tgisinternal
       AND col_num = ANY (t.tgattr);
END
$$;

-- An index built without blocking writes, and the check that it worked.
CREATE OR REPLACE FUNCTION pgsafe.plan_create_index(
    p_table   regclass,
    p_columns name[],
    p_unique  boolean DEFAULT false,
    p_name    name DEFAULT NULL,
    p_where   text DEFAULT NULL
)
RETURNS SETOF pgsafe.step
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    index_name name;
    column_list text;
BEGIN
    IF p_columns IS NULL OR array_length(p_columns, 1) IS NULL THEN
        RAISE EXCEPTION 'no columns given' USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT string_agg(quote_ident(c), ', ') INTO column_list
      FROM unnest(p_columns) AS c;

    index_name := coalesce(
        p_name,
        left(format('%s_%s_idx', pgsafe.relation_name(p_table),
                    array_to_string(p_columns, '_')), 63)::name
    );

    RETURN NEXT (
        1, 1,
        format('CREATE %sINDEX CONCURRENTLY %I ON %s (%s)%s;',
               CASE WHEN p_unique THEN 'UNIQUE ' ELSE '' END,
               index_name, p_table::text, column_list,
               CASE WHEN p_where IS NULL THEN '' ELSE ' WHERE ' || p_where END),
        pgsafe.form_lock('create_index_concurrently'),
        'index_build',
        'Outside a transaction, and with no statement_timeout: this takes two passes over the table and waits for transactions older than itself.'
    )::pgsafe.step;

    RETURN NEXT (
        2, 2,
        format('SELECT pgsafe.assert_index_valid(%L);', index_name),
        'ACCESS SHARE',
        'none',
        'A failed concurrent build leaves an invalid index behind that every write still maintains. Nothing reports it, so this step asks.'
    )::pgsafe.step;

    IF p_unique THEN
        RETURN NEXT (
            3, 3,
            format('ALTER TABLE %s ADD CONSTRAINT %I UNIQUE USING INDEX %I;',
                   p_table::text, left(format('%s_key', index_name), 63)::name, index_name),
            pgsafe.form_lock('add_unique_constraint_using_index'),
            'none',
            'Adopts the index that is already built. ADD CONSTRAINT UNIQUE without USING INDEX would build a second one under the lock.'
        )::pgsafe.step;
    END IF;
END
$$;

-- A foreign key added without scanning the child under a lock that stops writes.
CREATE OR REPLACE FUNCTION pgsafe.plan_add_foreign_key(
    p_child         regclass,
    p_child_column  name,
    p_parent        regclass,
    p_parent_column name DEFAULT NULL,
    p_name          name DEFAULT NULL,
    p_on_delete     text DEFAULT NULL
)
RETURNS SETOF pgsafe.step
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    parent_key      name := coalesce(p_parent_column, pgsafe.primary_key_column(p_parent));
    constraint_name name;
BEGIN
    PERFORM pgsafe.column_type(p_child, p_child_column);
    PERFORM pgsafe.column_type(p_parent, parent_key);

    constraint_name := coalesce(
        p_name,
        left(format('%s_%s_fkey', pgsafe.relation_name(p_child), p_child_column), 63)::name
    );

    RETURN NEXT (
        1, 1,
        format('ALTER TABLE %s ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES %s (%I)%s NOT VALID;',
               p_child::text, constraint_name, p_child_column, p_parent::text, parent_key,
               CASE WHEN p_on_delete IS NULL THEN '' ELSE ' ON DELETE ' || p_on_delete END),
        pgsafe.form_lock('add_foreign_key_not_valid'),
        'none',
        'SHARE ROW EXCLUSIVE on both tables for the catalogue write. New rows are enforced from here, and the existing ones are not looked at.'
    )::pgsafe.step;

    RETURN NEXT (
        2, 2,
        format('ALTER TABLE %s VALIDATE CONSTRAINT %I;', p_child::text, constraint_name),
        pgsafe.form_lock('validate_constraint'),
        'scan',
        'Its own transaction. SHARE UPDATE EXCLUSIVE on the child and ROW SHARE on the parent, so both keep serving reads and writes.'
    )::pgsafe.step;
END
$$;
