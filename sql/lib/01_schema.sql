-- 01_schema.sql
--
-- The pgsafe schema: composite types the rest of the library returns, and the
-- version string the Python side is tested against.
--
-- Apply the files in sql/lib in numeric order. They are re-runnable as long as
-- no function signature changed; a changed signature needs
-- DROP SCHEMA pgsafe CASCADE first, which is what `make reset` does.

CREATE SCHEMA IF NOT EXISTS pgsafe;

COMMENT ON SCHEMA pgsafe IS
    'Schema change helpers for PostgreSQL 16. Lock modes and rewrite rules here '
    'are read from the PostgreSQL 16 documentation and the system catalogues, '
    'not from a measured run.';

-- A type change verdict. cost is one of:
--   no_change      the two specs name the same type and modifier
--   no_rewrite     the column is relabelled, the heap is untouched
--   rewrite        every row is written again under ACCESS EXCLUSIVE
--   cast_required  pg_cast cannot reach the target, so USING is needed
--   unknown        this library has no rule for the pair, so do not trust it
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'pgsafe' AND t.typname = 'type_change_verdict'
    ) THEN
        CREATE TYPE pgsafe.type_change_verdict AS (
            cost   text,
            reason text
        );
    END IF;
END
$$;

-- A type specification split into the part to_regtype can resolve and the
-- modifier in parentheses, which PostgreSQL exposes no parser for.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'pgsafe' AND t.typname = 'parsed_type'
    ) THEN
        CREATE TYPE pgsafe.parsed_type AS (
            base     regtype,
            modifier text,
            raw      text
        );
    END IF;
END
$$;

-- One step of a migration plan. tx numbers the transactions: two steps sharing
-- a tx number belong in one transaction, and a new number means commit first.
-- work is one of: none, scan, rewrite, index_build, backfill, deploy.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'pgsafe' AND t.typname = 'step'
    ) THEN
        CREATE TYPE pgsafe.step AS (
            step      integer,
            tx        integer,
            statement text,
            lock_mode text,
            work      text,
            note      text
        );
    END IF;
END
$$;

-- What pgsafe.run_guarded() returns when the statement finally lands.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'pgsafe' AND t.typname = 'attempt'
    ) THEN
        CREATE TYPE pgsafe.attempt AS (
            attempts  integer,
            waited    interval,
            statement text
        );
    END IF;
END
$$;

-- The version of this library. tests/test_version.py asserts that this string
-- and the version in pyproject.toml are the same, because the SQL and the
-- linter encode the same rules and a split between them is silent.
CREATE OR REPLACE FUNCTION pgsafe.version()
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    RETURN '0.13.0';
END
$$;

COMMENT ON FUNCTION pgsafe.version() IS 'Library version, kept equal to pyproject.toml.';
