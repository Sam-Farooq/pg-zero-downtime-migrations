-- 08_facts.sql
--
-- How big is this, and who else is watching.
--
-- Every number in this file is arithmetic over the system catalogues, and none
-- of it is a measurement of anything this library did. The row counts are
-- planner estimates from pg_class.reltuples, which are as old as the last
-- ANALYZE, and the rewrite estimate multiplies bytes by a throughput that is
-- passed in as a parameter because nothing here can know it. Both say so in
-- their output rather than in a comment nobody reads.

-- Size and shape, for the question "can this table afford a rewrite".
CREATE OR REPLACE FUNCTION pgsafe.table_facts(p_table regclass)
RETURNS TABLE (
    table_name      text,
    estimated_rows  bigint,
    heap_bytes      bigint,
    index_bytes     bigint,
    total_bytes     bigint,
    index_count     integer,
    last_analyzed   timestamptz
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF (SELECT c.relkind FROM pg_class c WHERE c.oid = p_table) NOT IN ('r', 'p', 'm') THEN
        RAISE EXCEPTION '% is not a table', p_table::text
            USING ERRCODE = 'wrong_object_type';
    END IF;

    RETURN QUERY
    SELECT p_table::text,
           greatest(c.reltuples, 0)::bigint,
           pg_table_size(p_table),
           pg_indexes_size(p_table),
           pg_total_relation_size(p_table),
           (SELECT count(*) FROM pg_index i WHERE i.indrelid = p_table)::integer,
           greatest(s.last_analyze, s.last_autoanalyze)
      FROM pg_class c
      LEFT JOIN pg_stat_all_tables s ON s.relid = c.oid
     WHERE c.oid = p_table;
END
$$;

-- What a rewrite of this table would move, and how long that takes at a
-- throughput you supply.
--
-- A rewrite writes the heap again and rebuilds every index on it, so the work
-- is the total relation size rather than the heap. The seconds are
-- bytes / throughput and nothing else: no checkpoint behaviour, no WAL, no
-- contention, no autovacuum. It is a budget for deciding whether to bother
-- measuring, and it is wrong in the optimistic direction.
CREATE OR REPLACE FUNCTION pgsafe.rewrite_estimate(
    p_table              regclass,
    p_bytes_per_second   bigint DEFAULT 100 * 1024 * 1024,
    p_affordable_seconds numeric DEFAULT 1.0
)
RETURNS TABLE (
    table_name     text,
    total_bytes    bigint,
    pretty_size    text,
    seconds        numeric,
    affordable     boolean,
    assumption     text
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    moved bigint;
BEGIN
    IF p_bytes_per_second < 1 THEN
        RAISE EXCEPTION 'throughput must be positive, got %', p_bytes_per_second
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT f.total_bytes INTO moved FROM pgsafe.table_facts(p_table) AS f;

    RETURN QUERY
    SELECT p_table::text,
           moved,
           pg_size_pretty(moved),
           round(moved::numeric / p_bytes_per_second, 3),
           round(moved::numeric / p_bytes_per_second, 3) <= p_affordable_seconds,
           format('bytes / %s per second, with nothing accounted for but the bytes. '
                  'Measure on a copy before believing it.',
                  pg_size_pretty(p_bytes_per_second));
END
$$;

-- Indexes nothing has read since the statistics were last reset.
--
-- Relevant here because the cheapest way to make a rewrite cheaper is to have
-- fewer indexes on the table, and because DROP INDEX CONCURRENTLY is one of
-- the patterns. Primary keys and unique constraints are excluded: they are
-- enforcement rather than access paths, and idx_scan says nothing about that.
--
-- The caveat that matters: idx_scan counts since the last stats reset on THIS
-- server. A standby serving reads has its own counters, and an index that is
-- only used once a quarter looks unused for the other three months.
CREATE OR REPLACE FUNCTION pgsafe.unused_indexes(p_max_scans bigint DEFAULT 0)
RETURNS TABLE (
    index_name     text,
    table_name     text,
    scans          bigint,
    index_bytes    bigint,
    pretty_size    text,
    drop_statement text
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT s.indexrelid::regclass::text,
           s.relid::regclass::text,
           coalesce(s.idx_scan, 0),
           pg_relation_size(s.indexrelid),
           pg_size_pretty(pg_relation_size(s.indexrelid)),
           format('DROP INDEX CONCURRENTLY %s;', s.indexrelid::regclass::text)
      FROM pg_stat_all_indexes s
      JOIN pg_index i ON i.indexrelid = s.indexrelid
      JOIN pg_class t ON t.oid = s.relid
      JOIN pg_namespace n ON n.oid = t.relnamespace
     WHERE coalesce(s.idx_scan, 0) <= p_max_scans
       AND NOT i.indisunique
       AND NOT i.indisprimary
       AND n.nspname NOT IN ('pg_catalog', 'pg_toast', 'information_schema')
     ORDER BY pg_relation_size(s.indexrelid) DESC;
END
$$;

-- Standbys, and how far behind they are.
--
-- A batched backfill is the one part of a migration that can outrun
-- replication: it writes steadily for as long as it takes, and a standby that
-- falls behind is a read replica serving stale rows, or a failover target that
-- is not one. With no standbys connected this returns nothing, which is the
-- honest answer rather than zero lag.
CREATE OR REPLACE FUNCTION pgsafe.replication_lag()
RETURNS TABLE (
    client      text,
    state       text,
    sync_state  text,
    write_lag   interval,
    flush_lag   interval,
    replay_lag  interval,
    bytes_behind bigint
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT coalesce(r.application_name, r.client_addr::text, 'unnamed'),
           r.state,
           r.sync_state,
           r.write_lag,
           r.flush_lag,
           r.replay_lag,
           pg_wal_lsn_diff(r.sent_lsn, r.replay_lsn)::bigint
      FROM pg_stat_replication r
     ORDER BY r.replay_lag DESC NULLS LAST;
END
$$;

-- Wait for every standby to catch up, or give up.
--
-- Call it between backfill batches. With no standbys it returns immediately.
-- The interval it returns is the worst replay_lag it saw on the last check, so
-- a caller can log the shape of the run rather than just that it finished.
CREATE OR REPLACE FUNCTION pgsafe.wait_for_replication(
    p_max_lag  interval DEFAULT interval '5 seconds',
    p_timeout  interval DEFAULT interval '2 minutes',
    p_interval numeric  DEFAULT 1.0
)
RETURNS interval
LANGUAGE plpgsql
AS $$
DECLARE
    deadline timestamptz := clock_timestamp() + p_timeout;
    worst    interval;
BEGIN
    IF p_interval <= 0 THEN
        RAISE EXCEPTION 'the poll interval must be positive, got %', p_interval
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    LOOP
        SELECT max(l.replay_lag) INTO worst FROM pgsafe.replication_lag() AS l;

        IF worst IS NULL OR worst <= p_max_lag THEN
            RETURN coalesce(worst, interval '0');
        END IF;

        IF clock_timestamp() >= deadline THEN
            RAISE EXCEPTION 'standbys still % behind after %', worst, p_timeout
                USING ERRCODE = 'lock_not_available',
                      HINT = 'stop the backfill rather than widening the window';
        END IF;

        PERFORM pg_sleep(p_interval);
    END LOOP;
END
$$;
