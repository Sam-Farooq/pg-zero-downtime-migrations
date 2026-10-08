-- 06_introspect.sql
--
-- What to ask the server before and after a migration runs. The before part is
-- "is anything holding a lock I am about to queue behind", because that is the
-- failure that turns a one second ALTER TABLE into an outage: the statement
-- waits for the long read, and every later query waits for the statement.

-- Who is holding a lock on this relation right now.
--
-- Needs pg_stat_activity, so a non-superuser without pg_read_all_stats sees its
-- own backends and nulls for the rest. That is a quiet failure, so the
-- query_text column says so rather than coming back empty.
CREATE OR REPLACE FUNCTION pgsafe.blockers(p_table regclass)
RETURNS TABLE (
    pid          integer,
    state        text,
    lock_mode    text,
    granted      boolean,
    xact_age     interval,
    query_text   text,
    cancel_stmt  text
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT a.pid,
           coalesce(a.state, 'not visible to this role'),
           l.mode,
           l.granted,
           clock_timestamp() - a.xact_start,
           coalesce(left(a.query, 160), 'not visible to this role'),
           format('SELECT pg_cancel_backend(%s);', a.pid)
      FROM pg_locks l
      JOIN pg_stat_activity a ON a.pid = l.pid
     WHERE l.relation = p_table
       AND l.locktype = 'relation'
       AND a.pid <> pg_backend_pid()
     ORDER BY l.granted DESC, a.xact_start;
END
$$;

-- Everything that is waiting, and what it is waiting for. pg_blocking_pids()
-- answers the question that reading pg_locks by hand usually gets wrong, which
-- is which of several lock holders is the one actually in the way.
CREATE OR REPLACE FUNCTION pgsafe.lock_queue()
RETURNS TABLE (
    waiting_pid   integer,
    waiting_for   integer[],
    waiting_since interval,
    relation_name text,
    wanted_mode   text,
    waiting_query text
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT a.pid,
           pg_blocking_pids(a.pid),
           clock_timestamp() - a.query_start,
           coalesce(l.relation::regclass::text, '(not a relation lock)'),
           l.mode,
           coalesce(left(a.query, 160), 'not visible to this role')
      FROM pg_locks l
      JOIN pg_stat_activity a ON a.pid = l.pid
     WHERE NOT l.granted
     ORDER BY a.query_start;
END
$$;

-- Transactions old enough to be in the way of a migration.
--
-- A statement that wants ACCESS EXCLUSIVE waits for every transaction that
-- already holds any conflicting lock on the table, including an idle one that
-- read it ten minutes ago and never committed. idle in transaction is the state
-- to look for, not active.
CREATE OR REPLACE FUNCTION pgsafe.long_running_transactions(
    p_older_than interval DEFAULT interval '1 minute'
)
RETURNS TABLE (
    pid        integer,
    state      text,
    xact_age   interval,
    query_age  interval,
    query_text text
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT a.pid,
           a.state,
           clock_timestamp() - a.xact_start,
           clock_timestamp() - a.query_start,
           coalesce(left(a.query, 160), 'not visible to this role')
      FROM pg_stat_activity a
     WHERE a.xact_start IS NOT NULL
       AND a.pid <> pg_backend_pid()
       AND clock_timestamp() - a.xact_start > p_older_than
     ORDER BY a.xact_start;
END
$$;

-- The three questions worth asking before the next migration starts, in one
-- result. check_name and detail are text because this is meant to be read by a
-- person in psql, and every row with ok = false has something to do.
CREATE OR REPLACE FUNCTION pgsafe.preflight(
    p_older_than interval DEFAULT interval '1 minute'
)
RETURNS TABLE (
    check_name text,
    ok         boolean,
    detail     text
)
LANGUAGE plpgsql
AS $$
DECLARE
    invalid_count     bigint;
    unvalidated_count bigint;
    long_count        bigint;
    worst             interval;
BEGIN
    SELECT count(*) INTO invalid_count FROM pgsafe.invalid_indexes();
    SELECT count(*) INTO unvalidated_count FROM pgsafe.unvalidated_constraints();
    SELECT count(*), max(xact_age) INTO long_count, worst
      FROM pgsafe.long_running_transactions(p_older_than);

    RETURN QUERY SELECT
        'invalid_indexes',
        invalid_count = 0,
        CASE WHEN invalid_count = 0
             THEN 'no index left behind by a failed concurrent build'
             ELSE format('%s invalid index(es); every write still maintains them. SELECT * FROM pgsafe.invalid_indexes()', invalid_count)
        END;

    RETURN QUERY SELECT
        'unvalidated_constraints',
        unvalidated_count = 0,
        CASE WHEN unvalidated_count = 0
             THEN 'every constraint is validated'
             ELSE format('%s constraint(s) still NOT VALID, so the planner ignores them and SET NOT NULL will not skip its scan', unvalidated_count)
        END;

    RETURN QUERY SELECT
        'long_running_transactions',
        long_count = 0,
        CASE WHEN long_count = 0
             THEN format('nothing open longer than %s', p_older_than)
             ELSE format('%s transaction(s) open, oldest %s. A DDL statement will queue behind them and every later query behind it', long_count, worst)
        END;
END
$$;

COMMENT ON FUNCTION pgsafe.preflight(interval) IS
    'Run this before a migration. Every row with ok = false is a reason to wait.';
