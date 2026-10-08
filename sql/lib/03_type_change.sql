-- 03_type_change.sql
--
-- Does ALTER TABLE ... ALTER COLUMN ... TYPE rewrite the table?
--
-- The answer comes from pg_cast and from the type modifier, which is why this
-- is a function in the database rather than a lookup table in the linter. The
-- linter has to answer the same question from text alone and has a shorter
-- table for it; the README says where the two disagree.
--
-- The folklore version, "widening is free and narrowing is a rewrite", is half
-- right. It holds for varchar, where the modifier is a limit and the storage is
-- the same. It is false for integer to bigint, which are different widths on
-- disk: pg_cast reaches bigint through a function, and every row is written
-- again. That pair is the one that costs people a deploy.

-- Split a type specification into a regtype and the modifier in parentheses.
-- PostgreSQL exposes no parser for a modifier outside DDL, so this is a regexp
-- over the text as written.
CREATE OR REPLACE FUNCTION pgsafe.parse_type(p_spec text)
RETURNS pgsafe.parsed_type
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    spec     text := btrim(coalesce(p_spec, ''));
    parts    text[];
    base     text;
    modifier text;
    resolved regtype;
BEGIN
    IF spec = '' THEN
        RAISE EXCEPTION 'empty type specification'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- A modifier can sit in the middle of a type name, as in
    -- "timestamp(3) with time zone", so the parts either side are rejoined.
    parts := regexp_match(spec, '^([^()]*)\(([^()]*)\)(.*)$');
    IF parts IS NULL THEN
        base := spec;
        modifier := NULL;
    ELSE
        base := btrim(btrim(parts[1]) || ' ' || btrim(parts[3]));
        modifier := regexp_replace(btrim(parts[2]), '\s+', '', 'g');
        IF modifier = '' THEN
            RAISE EXCEPTION 'empty type modifier in %', p_spec
                USING ERRCODE = 'invalid_parameter_value';
        END IF;
    END IF;

    resolved := to_regtype(base);
    IF resolved IS NULL THEN
        RAISE EXCEPTION 'not a type this server knows: %', base
            USING ERRCODE = 'undefined_object',
                  HINT = 'to_regtype() could not resolve it, so neither can the rest of this library';
    END IF;

    RETURN (resolved, modifier, spec)::pgsafe.parsed_type;
END
$$;

-- The verdict for a type change, written as two type specifications.
CREATE OR REPLACE FUNCTION pgsafe.type_change(p_from text, p_to text)
RETURNS pgsafe.type_change_verdict
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    src          pgsafe.parsed_type := pgsafe.parse_type(p_from);
    dst          pgsafe.parsed_type := pgsafe.parse_type(p_to);
    src_len      integer;
    dst_len      integer;
    cast_method  "char";
    cast_context "char";
    cast_func    text;
BEGIN
    IF src.base = dst.base AND src.modifier IS NOT DISTINCT FROM dst.modifier THEN
        RETURN ('no_change', format('the column is already %s', dst.raw))::pgsafe.type_change_verdict;
    END IF;

    -- character(n) pads every value to n, and a bare "char" means char(1)
    -- rather than "no limit", so no change involving it is a relabel.
    IF 'bpchar'::regtype IN (src.base, dst.base) THEN
        RETURN (
            'rewrite',
            'character(n) pads to its declared length, so changing n changes every stored value'
        )::pgsafe.type_change_verdict;
    END IF;

    IF src.base = dst.base THEN
        IF dst.modifier IS NULL THEN
            RETURN (
                'no_rewrite',
                'the target declares no modifier, and a value already stored cannot violate one'
            )::pgsafe.type_change_verdict;
        END IF;

        IF src.modifier IS NULL THEN
            RETURN (
                'rewrite',
                format('the column has no limit today, so every row is checked against %s', dst.modifier)
            )::pgsafe.type_change_verdict;
        END IF;

        IF src.base = 'varchar'::regtype
           AND src.modifier ~ '^\d+$' AND dst.modifier ~ '^\d+$' THEN
            src_len := src.modifier::integer;
            dst_len := dst.modifier::integer;
            IF dst_len >= src_len THEN
                RETURN (
                    'no_rewrite',
                    format('varchar is not padded, and %s cannot reject a value that fits %s',
                           dst_len, src_len)
                )::pgsafe.type_change_verdict;
            END IF;
            RETURN (
                'rewrite',
                format('every value has to be measured against the shorter limit %s', dst_len)
            )::pgsafe.type_change_verdict;
        END IF;

        RETURN (
            'unknown',
            format('no rule here for a %s modifier change: compare pg_class.relfilenode '
                   'before and after on a copy of the table before trusting either answer',
                   src.base)
        )::pgsafe.type_change_verdict;
    END IF;

    SELECT c.castmethod,
           c.castcontext,
           CASE WHEN c.castfunc <> 0 THEN c.castfunc::regprocedure::text END
      INTO cast_method, cast_context, cast_func
      FROM pg_cast c
     WHERE c.castsource = src.base
       AND c.casttarget = dst.base;

    IF NOT FOUND THEN
        RETURN (
            'cast_required',
            format('pg_cast has no entry from %s to %s, so the statement needs a USING '
                   'clause and writes every row', src.base, dst.base)
        )::pgsafe.type_change_verdict;
    END IF;

    IF cast_context = 'e' THEN
        RETURN (
            'rewrite',
            format('the cast from %s to %s is explicit only, so ALTER TABLE needs USING '
                   'and converts every row', src.base, dst.base)
        )::pgsafe.type_change_verdict;
    END IF;

    IF cast_method = 'b' THEN
        IF dst.modifier IS NULL THEN
            RETURN (
                'no_rewrite',
                format('%s is binary coercible to %s and the target declares no modifier, '
                       'so the column is relabelled in place', src.base, dst.base)
            )::pgsafe.type_change_verdict;
        END IF;
        RETURN (
            'rewrite',
            format('%s is binary coercible to %s, but the modifier %s still has to be '
                   'verified on every row', src.base, dst.base, dst.modifier)
        )::pgsafe.type_change_verdict;
    END IF;

    RETURN (
        'rewrite',
        format('the change runs %s per row, so the table is written again and every '
               'index on it is rebuilt', coalesce(cast_func, 'a conversion'))
    )::pgsafe.type_change_verdict;
END
$$;

-- The short answer, for a CHECK or a guard clause.
CREATE OR REPLACE FUNCTION pgsafe.rewrites(p_from text, p_to text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    verdict pgsafe.type_change_verdict := pgsafe.type_change(p_from, p_to);
BEGIN
    IF verdict.cost = 'unknown' THEN
        RAISE EXCEPTION 'no rule for % to %: %', p_from, p_to, verdict.reason
            USING ERRCODE = 'feature_not_supported';
    END IF;
    RETURN verdict.cost IN ('rewrite', 'cast_required');
END
$$;

-- The declared type of a live column, modifier included.
CREATE OR REPLACE FUNCTION pgsafe.column_type(p_table regclass, p_column name)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    declared text;
BEGIN
    SELECT format_type(a.atttypid, a.atttypmod)
      INTO declared
      FROM pg_attribute a
     WHERE a.attrelid = p_table
       AND a.attname = p_column
       AND a.attnum > 0
       AND NOT a.attisdropped;

    IF declared IS NULL THEN
        RAISE EXCEPTION 'column %.% does not exist', p_table::text, p_column
            USING ERRCODE = 'undefined_column';
    END IF;

    RETURN declared;
END
$$;

-- The verdict for changing a live column, reading its current type from the
-- catalogue instead of being told what it is.
CREATE OR REPLACE FUNCTION pgsafe.column_type_change(
    p_table  regclass,
    p_column name,
    p_to     text
)
RETURNS pgsafe.type_change_verdict
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN pgsafe.type_change(pgsafe.column_type(p_table, p_column), p_to);
END
$$;
