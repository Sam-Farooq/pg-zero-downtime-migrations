-- 09_assertions.sql
--
-- Ask the question before taking the lock.
--
-- Every statement in the catalogue that scans a table can fail on the data:
-- SET NOT NULL finds a null, VALIDATE CONSTRAINT finds an orphan, a unique
-- index build finds a duplicate, a type change finds a value the target type
-- rejects. Each of those failures arrives after the work has been done and,
-- for the forms that hold ACCESS EXCLUSIVE, after the table has been closed to
-- readers for the duration.
--
-- So these functions ask the same question with an ordinary SELECT, which takes
-- ACCESS SHARE and blocks nothing. They are sequential scans and they are not
-- cheap; they are cheap compared to finding out the other way.
--
-- None of them is a guarantee. A row that arrives between the check and the
-- statement is not in the answer, which is why the constraint patterns enforce
-- new writes first and validate afterwards.

-- Rows that would stop SET NOT NULL.
CREATE OR REPLACE FUNCTION pgsafe.null_count(p_table regclass, p_column name)
RETURNS bigint
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    found bigint;
BEGIN
    PERFORM pgsafe.column_type(p_table, p_column);
    EXECUTE format('SELECT count(*) FROM %s WHERE %I IS NULL', p_table::text, p_column)
       INTO found;
    RETURN found;
END
$$;

CREATE OR REPLACE FUNCTION pgsafe.assert_no_nulls(p_table regclass, p_column name)
RETURNS void
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    found bigint := pgsafe.null_count(p_table, p_column);
BEGIN
    IF found > 0 THEN
        RAISE EXCEPTION '%.% still has % null row(s)', p_table::text, p_column, found
            USING ERRCODE = 'not_null_violation',
                  HINT = 'backfill in batches first: SELECT * FROM pgsafe.plan_add_column(...)';
    END IF;
END
$$;

-- Rows that would stop VALIDATE CONSTRAINT on a foreign key.
--
-- The NULL handling is the foreign key's own: a null referencing column
-- satisfies the constraint under MATCH SIMPLE, so it is not an orphan.
CREATE OR REPLACE FUNCTION pgsafe.orphan_count(
    p_child         regclass,
    p_child_column  name,
    p_parent        regclass,
    p_parent_column name DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    parent_key name := coalesce(p_parent_column, pgsafe.primary_key_column(p_parent));
    found      bigint;
BEGIN
    PERFORM pgsafe.column_type(p_child, p_child_column);
    PERFORM pgsafe.column_type(p_parent, parent_key);

    EXECUTE format(
        'SELECT count(*) FROM %s AS child WHERE child.%I IS NOT NULL '
        'AND NOT EXISTS (SELECT 1 FROM %s AS parent WHERE parent.%I = child.%I)',
        p_child::text, p_child_column, p_parent::text, parent_key, p_child_column
    ) INTO found;
    RETURN found;
END
$$;

CREATE OR REPLACE FUNCTION pgsafe.assert_no_orphans(
    p_child         regclass,
    p_child_column  name,
    p_parent        regclass,
    p_parent_column name DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    found bigint := pgsafe.orphan_count(p_child, p_child_column, p_parent, p_parent_column);
BEGIN
    IF found > 0 THEN
        RAISE EXCEPTION '% row(s) in %.% have no match in %',
                        found, p_child::text, p_child_column, p_parent::text
            USING ERRCODE = 'foreign_key_violation',
                  HINT = 'the constraint can stay NOT VALID while this is a data question';
    END IF;
END
$$;

-- Groups that would stop a unique index build.
--
-- A concurrent unique build does two passes over the table and then fails on
-- the first duplicate, leaving an invalid index behind for someone to drop.
CREATE OR REPLACE FUNCTION pgsafe.duplicate_count(p_table regclass, p_columns name[])
RETURNS bigint
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    column_list text;
    found       bigint;
BEGIN
    IF p_columns IS NULL OR array_length(p_columns, 1) IS NULL THEN
        RAISE EXCEPTION 'no columns given' USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT string_agg(quote_ident(c), ', ') INTO column_list FROM unnest(p_columns) AS c;

    EXECUTE format(
        'SELECT count(*) FROM (SELECT 1 FROM %s GROUP BY %s HAVING count(*) > 1) AS d',
        p_table::text, column_list
    ) INTO found;
    RETURN found;
END
$$;

CREATE OR REPLACE FUNCTION pgsafe.assert_unique(p_table regclass, p_columns name[])
RETURNS void
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    found bigint := pgsafe.duplicate_count(p_table, p_columns);
BEGIN
    IF found > 0 THEN
        RAISE EXCEPTION '% duplicate group(s) in %(%)',
                        found, p_table::text, array_to_string(p_columns, ', ')
            USING ERRCODE = 'unique_violation',
                  HINT = 'a concurrent unique build fails on these after two full passes';
    END IF;
END
$$;

-- Would this value survive the cast?
--
-- One row at a time, with the error trapped, which is the only way to answer it
-- for an arbitrary target type. It is a function call per row, so the counting
-- function below is a sequential scan with a subtransaction per row: run it on
-- a copy or off peak, not in the deploy.
CREATE OR REPLACE FUNCTION pgsafe.value_fits(p_value text, p_type text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    -- STABLE rather than IMMUTABLE: resolving the target type reads the
    -- catalogues, and so does the cast.
    PERFORM pgsafe.parse_type(p_type);

    IF p_value IS NULL THEN
        RETURN true;
    END IF;

    BEGIN
        EXECUTE format('SELECT %L::%s', p_value, p_type);
        RETURN true;
    EXCEPTION
        WHEN data_exception OR syntax_error_or_access_rule_violation THEN
            RETURN false;
    END;
END
$$;

-- Rows a type change would reject.
--
-- The count is what ALTER TABLE ... ALTER COLUMN TYPE would fail on, after it
-- had rewritten everything up to that row. Checking first turns a failed deploy
-- into a list of row ids.
CREATE OR REPLACE FUNCTION pgsafe.unconvertible_count(
    p_table  regclass,
    p_column name,
    p_type   text
)
RETURNS bigint
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    found bigint;
BEGIN
    PERFORM pgsafe.column_type(p_table, p_column);
    PERFORM pgsafe.parse_type(p_type);

    EXECUTE format(
        'SELECT count(*) FROM %s WHERE %I IS NOT NULL AND NOT pgsafe.value_fits(%I::text, %L)',
        p_table::text, p_column, p_column, p_type
    ) INTO found;
    RETURN found;
END
$$;

-- The whole set, for one table, as a result somebody reads before they start.
-- Every row with ok = false is a statement that would have failed under a lock.
CREATE OR REPLACE FUNCTION pgsafe.data_preflight(
    p_table   regclass,
    p_column  name DEFAULT NULL,
    p_to_type text DEFAULT NULL
)
RETURNS TABLE (
    check_name text,
    ok         boolean,
    detail     text
)
LANGUAGE plpgsql
AS $$
DECLARE
    nulls          bigint;
    unconvertible  bigint;
    facts          record;
BEGIN
    SELECT * INTO facts FROM pgsafe.table_facts(p_table);

    RETURN QUERY SELECT
        'size',
        true,
        format('%s rows estimated, %s in total, %s index(es)',
               facts.estimated_rows, pg_size_pretty(facts.total_bytes), facts.index_count);

    IF p_column IS NOT NULL THEN
        nulls := pgsafe.null_count(p_table, p_column);
        RETURN QUERY SELECT
            'nulls',
            nulls = 0,
            CASE WHEN nulls = 0
                 THEN format('%I has no nulls, so SET NOT NULL would hold', p_column)
                 ELSE format('%I has %s null row(s): backfill before SET NOT NULL', p_column, nulls)
            END;
    END IF;

    IF p_column IS NOT NULL AND p_to_type IS NOT NULL THEN
        unconvertible := pgsafe.unconvertible_count(p_table, p_column, p_to_type);
        RETURN QUERY SELECT
            'convertible',
            unconvertible = 0,
            CASE WHEN unconvertible = 0
                 THEN format('every value in %I survives the cast to %s', p_column, p_to_type)
                 ELSE format('%s row(s) in %I would be rejected by %s', unconvertible, p_column, p_to_type)
            END;

        RETURN QUERY SELECT
            'rewrite',
            NOT pgsafe.rewrites(pgsafe.column_type(p_table, p_column), p_to_type),
            (pgsafe.column_type_change(p_table, p_column, p_to_type)).reason;
    END IF;
END
$$;

COMMENT ON FUNCTION pgsafe.data_preflight(regclass, name, text) IS
    'Data questions a migration would otherwise answer the expensive way, under a lock.';
