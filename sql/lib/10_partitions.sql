-- 10_partitions.sql
--
-- Attaching and detaching a partition without closing the parent.
--
-- Two statements, two different problems, and the same two tricks as the rest
-- of the catalogue.
--
-- ATTACH PARTITION takes SHARE UPDATE EXCLUSIVE on the parent and ACCESS
-- EXCLUSIVE on the table being attached, and it scans that table to prove every
-- row belongs inside the bound. The scan is skipped when a valid CHECK already
-- implies the partition constraint, which is the same NOT VALID then VALIDATE
-- shape as SET NOT NULL, applied to a different statement.
--
-- DETACH PARTITION takes ACCESS EXCLUSIVE on the parent, which stops reads of
-- every other partition as well. CONCURRENTLY takes SHARE UPDATE EXCLUSIVE
-- instead, cannot run in a transaction block, and leaves the partition marked
-- detach pending if it is interrupted. Nothing reports that, so there is a
-- function below for it, as there is for an invalid index.

-- The partitions of a parent, with their bounds and whether a detach was left
-- half done.
CREATE OR REPLACE FUNCTION pgsafe.partitions(p_parent regclass)
RETURNS TABLE (
    partition_name  text,
    bound           text,
    estimated_rows  bigint,
    total_bytes     bigint,
    pretty_size     text,
    detach_pending  boolean
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_class c WHERE c.oid = p_parent AND c.relkind = 'p'
    ) THEN
        RAISE EXCEPTION '% is not a partitioned table', p_parent::text
            USING ERRCODE = 'wrong_object_type';
    END IF;

    RETURN QUERY
    SELECT i.inhrelid::regclass::text,
           coalesce(pg_get_expr(c.relpartbound, c.oid), 'no bound'),
           greatest(c.reltuples, 0)::bigint,
           pg_total_relation_size(i.inhrelid),
           pg_size_pretty(pg_total_relation_size(i.inhrelid)),
           i.inhdetachpending
      FROM pg_inherits i
      JOIN pg_class c ON c.oid = i.inhrelid
     WHERE i.inhparent = p_parent
     ORDER BY 1;
END
$$;

-- Partitions left behind by an interrupted DETACH ... CONCURRENTLY, with the
-- statement that finishes the job. A partition in this state is still attached
-- for some sessions and not for others, and no error is raised about it.
CREATE OR REPLACE FUNCTION pgsafe.pending_detaches()
RETURNS TABLE (
    parent_name       text,
    partition_name    text,
    finalize_statement text
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT i.inhparent::regclass::text,
           i.inhrelid::regclass::text,
           format('ALTER TABLE %s DETACH PARTITION %s FINALIZE;',
                  i.inhparent::regclass::text, i.inhrelid::regclass::text)
      FROM pg_inherits i
     WHERE i.inhdetachpending
     ORDER BY 1, 2;
END
$$;

-- The CHECK that matches a half open range bound.
--
-- The IS NOT NULL is part of it. A range partition constraint is
-- (col IS NOT NULL AND col >= lower AND col < upper), and a CHECK without the
-- null test does not imply it, so the scan happens anyway.
CREATE OR REPLACE FUNCTION pgsafe.range_bound_check(
    p_partition regclass,
    p_column    name,
    p_from      text,
    p_to        text,
    p_name      name DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    constraint_name name;
BEGIN
    PERFORM pgsafe.column_type(p_partition, p_column);

    IF p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION 'a range bound needs both ends'
            USING ERRCODE = 'invalid_parameter_value',
                  HINT = 'MINVALUE and MAXVALUE bounds are not generated here';
    END IF;

    constraint_name := coalesce(
        p_name,
        left(format('%s_bound', pgsafe.relation_name(p_partition)), 63)::name
    );

    RETURN format(
        'ALTER TABLE %s ADD CONSTRAINT %I CHECK (%I IS NOT NULL AND %I >= %L AND %I < %L) NOT VALID;',
        p_partition::text, constraint_name,
        p_column, p_column, p_from, p_column, p_to
    );
END
$$;

-- Will ATTACH PARTITION scan the table?
--
-- PostgreSQL decides this with a predicate implication test over the existing
-- constraints. This is a text test over pg_get_constraintdef: it looks for a
-- validated CHECK on the partition that mentions the column, the null test and
-- both bounds. So it can say the scan will happen where PostgreSQL would have
-- skipped it, for a constraint written a different way round. It does not go
-- the other way, which is the direction that would matter.
CREATE OR REPLACE FUNCTION pgsafe.attach_will_scan(
    p_partition regclass,
    p_column    name,
    p_from      text,
    p_to        text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    definition text;
BEGIN
    PERFORM pgsafe.column_type(p_partition, p_column);

    FOR definition IN
        SELECT pg_get_constraintdef(c.oid)
          FROM pg_constraint c
         WHERE c.conrelid = p_partition
           AND c.contype = 'c'
           AND c.convalidated
    LOOP
        IF definition LIKE format('%%%s%%', p_column)
           AND definition LIKE '%IS NOT NULL%'
           AND definition LIKE format('%%%s%%', p_from)
           AND definition LIKE format('%%%s%%', p_to) THEN
            RETURN false;
        END IF;
    END LOOP;

    RETURN true;
END
$$;

-- Attach a partition without the scan under the lock.
CREATE OR REPLACE FUNCTION pgsafe.plan_attach_partition(
    p_parent    regclass,
    p_partition regclass,
    p_column    name,
    p_from      text,
    p_to        text
)
RETURNS SETOF pgsafe.step
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    constraint_name name := left(format('%s_bound', pgsafe.relation_name(p_partition)), 63)::name;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = p_parent AND c.relkind = 'p') THEN
        RAISE EXCEPTION '% is not a partitioned table', p_parent::text
            USING ERRCODE = 'wrong_object_type';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_inherits i WHERE i.inhrelid = p_partition) THEN
        RAISE EXCEPTION '% is already attached to a parent', p_partition::text
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    RETURN NEXT (
        1, 1,
        pgsafe.range_bound_check(p_partition, p_column, p_from, p_to, constraint_name),
        pgsafe.form_lock('add_check_constraint_not_valid'),
        'none',
        'Catalogue only, on a table the parent does not know about yet.'
    )::pgsafe.step;

    RETURN NEXT (
        2, 2,
        format('ALTER TABLE %s VALIDATE CONSTRAINT %I;', p_partition::text, constraint_name),
        pgsafe.form_lock('validate_constraint'),
        'scan',
        'The scan, in its own transaction, under a lock that lets the table keep serving.'
    )::pgsafe.step;

    RETURN NEXT (
        3, 3,
        format('ALTER TABLE %s ATTACH PARTITION %s FOR VALUES FROM (%L) TO (%L);',
               p_parent::text, p_partition::text, p_from, p_to),
        pgsafe.form_lock('attach_partition_with_valid_check'),
        'none',
        'No scan: the valid CHECK implies the partition constraint, so PostgreSQL skips it.'
    )::pgsafe.step;

    RETURN NEXT (
        4, 4,
        format('ALTER TABLE %s DROP CONSTRAINT %I;', p_partition::text, constraint_name),
        pgsafe.form_lock('drop_constraint'),
        'none',
        'Optional. The partition constraint says the same thing now, and the CHECK is a second expression on every write.'
    )::pgsafe.step;
END
$$;

-- Detach a partition without stopping reads of the other partitions.
CREATE OR REPLACE FUNCTION pgsafe.plan_detach_partition(
    p_parent    regclass,
    p_partition regclass
)
RETURNS SETOF pgsafe.step
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_inherits i
         WHERE i.inhparent = p_parent AND i.inhrelid = p_partition
    ) THEN
        RAISE EXCEPTION '% is not a partition of %', p_partition::text, p_parent::text
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    RETURN NEXT (
        1, 1,
        format('ALTER TABLE %s DETACH PARTITION %s CONCURRENTLY;',
               p_parent::text, p_partition::text),
        pgsafe.form_lock('detach_partition_concurrently'),
        'none',
        'Outside a transaction block, like every other CONCURRENTLY. It waits for transactions that can still see the partition.'
    )::pgsafe.step;

    RETURN NEXT (
        2, 2,
        'SELECT * FROM pgsafe.pending_detaches();',
        'ACCESS SHARE',
        'none',
        'An interrupted detach leaves the partition marked pending and nothing says so. If this returns a row, run the FINALIZE it prints.'
    )::pgsafe.step;
END
$$;
