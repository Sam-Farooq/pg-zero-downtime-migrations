-- 04_guards.sql
--
-- The three things that have to happen at the moment a migration runs: bound
-- the wait for the lock, prove a concurrent index build actually succeeded, and
-- keep two columns in step while readers are redeployed.

-- Is any function named in this expression volatile?
--
-- An added column with a volatile default is rewritten row by row; a constant
-- or stable default is stored once in pg_attribute.attmissingval and costs
-- nothing. PostgreSQL has no function that reports the volatility of an
-- arbitrary expression text, so this matches identifiers that are followed by
-- an open parenthesis and looks each one up in pg_proc by name.
--
-- Two consequences, both of them the cautious direction:
--   an overloaded name with one volatile form reads as volatile
--   a volatile function reached through a view or an operator is not seen
CREATE OR REPLACE FUNCTION pgsafe.expression_is_volatile(p_expression text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    called text[];
    hit    boolean;
BEGIN
    IF p_expression IS NULL OR btrim(p_expression) = '' THEN
        RETURN false;
    END IF;

    SELECT array_agg(DISTINCT lower(m[1]))
      INTO called
      FROM regexp_matches(p_expression, '([a-zA-Z_][a-zA-Z0-9_]*)\s*\(', 'g') AS m;

    IF called IS NULL THEN
        RETURN false;
    END IF;

    SELECT bool_or(p.provolatile = 'v')
      INTO hit
      FROM pg_proc p
     WHERE p.proname = ANY (called);

    RETURN coalesce(hit, false);
END
$$;

COMMENT ON FUNCTION pgsafe.expression_is_volatile(text) IS
    'True when a function named in the expression text is volatile in pg_proc. '
    'Matches by name, so an overloaded name reads as volatile if any form is.';

-- Run one statement with a bounded wait, and retry when the wait expires.
--
-- A migration without lock_timeout queues behind whatever long read is open,
-- and every statement that arrives after it queues behind the migration. The
-- timeout does not prevent that; it bounds it. The retry is what makes a short
-- timeout usable rather than just a different way to fail.
--
-- Two limits worth knowing before calling this:
--   a function body is one transaction, so the statement is not committed
--   until the caller commits
--   CREATE INDEX CONCURRENTLY cannot run inside a transaction block, and so
--   cannot run here at all. The call is refused rather than attempted.
CREATE OR REPLACE FUNCTION pgsafe.run_guarded(
    p_statement    text,
    p_lock_timeout text     DEFAULT '3s',
    p_attempts     integer  DEFAULT 5,
    p_backoff      interval DEFAULT interval '2 seconds'
)
RETURNS pgsafe.attempt
LANGUAGE plpgsql
AS $$
DECLARE
    prior   text := current_setting('lock_timeout');
    started timestamptz := clock_timestamp();
    tries   integer := 0;
BEGIN
    IF p_attempts < 1 THEN
        RAISE EXCEPTION 'attempts must be at least 1, got %', p_attempts
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF p_statement ~* '\mconcurrently\M' THEN
        RAISE EXCEPTION 'CONCURRENTLY cannot run inside a transaction block, and a function body is one'
            USING ERRCODE = 'feature_not_supported',
                  HINT = 'run it from psql outside a transaction, then call pgsafe.assert_index_valid()';
    END IF;

    PERFORM set_config('lock_timeout', p_lock_timeout, true);

    LOOP
        tries := tries + 1;
        BEGIN
            EXECUTE p_statement;
            PERFORM set_config('lock_timeout', prior, true);
            RETURN (tries, clock_timestamp() - started, p_statement)::pgsafe.attempt;
        EXCEPTION
            WHEN lock_not_available THEN
                IF tries >= p_attempts THEN
                    PERFORM set_config('lock_timeout', prior, true);
                    RAISE EXCEPTION 'gave up after % attempts at lock_timeout %', tries, p_lock_timeout
                        USING ERRCODE = 'lock_not_available',
                              HINT = 'pgsafe.blockers() names what is holding the conflicting lock';
                END IF;
                PERFORM pg_sleep(extract(epoch FROM p_backoff));
        END;
    END LOOP;
END
$$;

-- A concurrent index build that fails leaves the index behind, marked invalid,
-- and the next write still maintains it. Nothing in psql shouts about it, so
-- the statement after CREATE INDEX CONCURRENTLY has to be this one.
CREATE OR REPLACE FUNCTION pgsafe.assert_index_valid(p_index regclass)
RETURNS void
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    is_valid boolean;
    is_ready boolean;
BEGIN
    SELECT i.indisvalid, i.indisready
      INTO is_valid, is_ready
      FROM pg_index i
     WHERE i.indexrelid = p_index;

    IF NOT FOUND THEN
        RAISE EXCEPTION '% is not an index', p_index::text
            USING ERRCODE = 'undefined_object';
    END IF;

    IF NOT is_valid OR NOT is_ready THEN
        RAISE EXCEPTION 'index % is not usable (indisvalid=%, indisready=%)',
                        p_index::text, is_valid, is_ready
            USING ERRCODE = 'object_not_in_prerequisite_state',
                  HINT = 'DROP INDEX CONCURRENTLY and build it again; a reindex of an invalid index keeps it invalid';
    END IF;
END
$$;

-- Every index on the current database that a build left behind, with the
-- statement that removes it.
CREATE OR REPLACE FUNCTION pgsafe.invalid_indexes()
RETURNS TABLE (
    index_name     text,
    table_name     text,
    ready          boolean,
    drop_statement text
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT i.indexrelid::regclass::text,
           i.indrelid::regclass::text,
           i.indisready,
           format('DROP INDEX CONCURRENTLY %s;', i.indexrelid::regclass::text)
      FROM pg_index i
      JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE NOT i.indisvalid
       AND n.nspname NOT IN ('pg_catalog', 'pg_toast', 'information_schema')
     ORDER BY 1;
END
$$;

-- Constraints added NOT VALID and never validated, with the statement that
-- finishes the job. A NOT VALID constraint is enforced for new writes and
-- proves nothing about the rows that were there first, so the planner will not
-- use it and SET NOT NULL will not skip its scan.
CREATE OR REPLACE FUNCTION pgsafe.unvalidated_constraints()
RETURNS TABLE (
    table_name         text,
    constraint_name    text,
    constraint_kind    text,
    validate_statement text
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT c.conrelid::regclass::text,
           c.conname::text,
           CASE c.contype
               WHEN 'c' THEN 'check'
               WHEN 'f' THEN 'foreign key'
               ELSE c.contype::text
           END,
           format('ALTER TABLE %s VALIDATE CONSTRAINT %I;',
                  c.conrelid::regclass::text, c.conname)
      FROM pg_constraint c
      JOIN pg_namespace n ON n.oid = c.connamespace
     WHERE NOT c.convalidated
       AND c.conrelid <> 0
       AND n.nspname NOT IN ('pg_catalog', 'information_schema')
     ORDER BY 1, 2;
END
$$;

-- Keep a pair of columns equal while readers and writers are redeployed.
--
-- Attach as a BEFORE INSERT OR UPDATE row trigger with the two column names as
-- arguments. The record is reached through jsonb, because a trigger function
-- cannot name a column it was only told about at runtime.
--
-- A column holding SQL NULL becomes a JSON null rather than disappearing, so
-- "was it supplied" is jsonb_typeof(value) = 'null' and not value IS NULL.
-- Getting that wrong gives a trigger that copies nothing and looks fine.
CREATE OR REPLACE FUNCTION pgsafe.sync_column_pair()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    left_col   text;
    right_col  text;
    new_row    jsonb;
    old_row    jsonb;
    left_null  boolean;
    right_null boolean;
    left_moved boolean;
    right_moved boolean;
BEGIN
    IF TG_NARGS <> 2 THEN
        RAISE EXCEPTION 'pgsafe.sync_column_pair() takes two column names, got %', TG_NARGS
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    left_col := TG_ARGV[0];
    right_col := TG_ARGV[1];
    new_row := to_jsonb(NEW);

    IF NOT (new_row ? left_col) OR NOT (new_row ? right_col) THEN
        RAISE EXCEPTION 'table % has no column pair %/%', TG_TABLE_NAME, left_col, right_col
            USING ERRCODE = 'undefined_column';
    END IF;

    left_null := jsonb_typeof(new_row -> left_col) = 'null';
    right_null := jsonb_typeof(new_row -> right_col) = 'null';

    IF TG_OP = 'INSERT' THEN
        IF left_null AND right_null THEN
            RETURN NEW;
        ELSIF right_null THEN
            NEW := jsonb_populate_record(NEW, jsonb_build_object(right_col, new_row -> left_col));
        ELSIF left_null THEN
            NEW := jsonb_populate_record(NEW, jsonb_build_object(left_col, new_row -> right_col));
        ELSIF (new_row -> left_col) <> (new_row -> right_col) THEN
            RAISE EXCEPTION 'insert set %.% and %.% to different values',
                            TG_TABLE_NAME, left_col, TG_TABLE_NAME, right_col
                USING ERRCODE = 'integrity_constraint_violation',
                      HINT = 'during an expand and contract rename, write one of the pair and let the trigger copy it';
        END IF;
        RETURN NEW;
    END IF;

    old_row := to_jsonb(OLD);
    left_moved := (new_row -> left_col) IS DISTINCT FROM (old_row -> left_col);
    right_moved := (new_row -> right_col) IS DISTINCT FROM (old_row -> right_col);

    IF left_moved AND NOT right_moved THEN
        NEW := jsonb_populate_record(NEW, jsonb_build_object(right_col, new_row -> left_col));
    ELSIF right_moved AND NOT left_moved THEN
        NEW := jsonb_populate_record(NEW, jsonb_build_object(left_col, new_row -> right_col));
    ELSIF left_moved AND right_moved
          AND (new_row -> left_col) <> (new_row -> right_col) THEN
        RAISE EXCEPTION 'update set %.% and %.% to different values',
                        TG_TABLE_NAME, left_col, TG_TABLE_NAME, right_col
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;

    RETURN NEW;
END
$$;

COMMENT ON FUNCTION pgsafe.sync_column_pair() IS
    'BEFORE INSERT OR UPDATE trigger: copies whichever of two columns was written into the other.';
