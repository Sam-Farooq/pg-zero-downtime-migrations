-- 02_lock_matrix.sql
--
-- The table-level lock conflict matrix, and the lock each schema change takes.
--
-- Every row in both tables is transcribed from the PostgreSQL 16 documentation
-- (Explicit Locking, and the ALTER TABLE notes). Nothing here was measured in a
-- running server. The point of having it as data rather than as prose is that
-- pgsafe.blocks_reads() and pgsafe.blocks_writes() derive their answer from the
-- matrix instead of from a second opinion written down somewhere else.

CREATE TABLE IF NOT EXISTS pgsafe.lock_mode (
    mode       text PRIMARY KEY,
    -- ordering only, for readable output. It is not a conflict rule: the
    -- matrix is not a total order, which is why it is stored row by row.
    sort_order smallint NOT NULL
);

INSERT INTO pgsafe.lock_mode (mode, sort_order) VALUES
    ('ACCESS SHARE', 1),
    ('ROW SHARE', 2),
    ('ROW EXCLUSIVE', 3),
    ('SHARE UPDATE EXCLUSIVE', 4),
    ('SHARE', 5),
    ('SHARE ROW EXCLUSIVE', 6),
    ('EXCLUSIVE', 7),
    ('ACCESS EXCLUSIVE', 8)
ON CONFLICT (mode) DO UPDATE SET sort_order = excluded.sort_order;

CREATE TABLE IF NOT EXISTS pgsafe.lock_conflict (
    held      text NOT NULL REFERENCES pgsafe.lock_mode (mode),
    requested text NOT NULL REFERENCES pgsafe.lock_mode (mode),
    PRIMARY KEY (held, requested)
);

-- Each unordered conflicting pair, written once. The loader below inserts the
-- mirror image, so symmetry is a property of the loader rather than of how
-- carefully the list was typed. test/pgtap/02_lock_matrix.sql asserts both the
-- symmetry and the 38 directed rows it produces.
CREATE TABLE IF NOT EXISTS pgsafe.lock_conflict_seed (
    a text NOT NULL REFERENCES pgsafe.lock_mode (mode),
    b text NOT NULL REFERENCES pgsafe.lock_mode (mode),
    PRIMARY KEY (a, b)
);

INSERT INTO pgsafe.lock_conflict_seed (a, b) VALUES
    ('ACCESS SHARE', 'ACCESS EXCLUSIVE'),
    ('ROW SHARE', 'EXCLUSIVE'),
    ('ROW SHARE', 'ACCESS EXCLUSIVE'),
    ('ROW EXCLUSIVE', 'SHARE'),
    ('ROW EXCLUSIVE', 'SHARE ROW EXCLUSIVE'),
    ('ROW EXCLUSIVE', 'EXCLUSIVE'),
    ('ROW EXCLUSIVE', 'ACCESS EXCLUSIVE'),
    ('SHARE UPDATE EXCLUSIVE', 'SHARE UPDATE EXCLUSIVE'),
    ('SHARE UPDATE EXCLUSIVE', 'SHARE'),
    ('SHARE UPDATE EXCLUSIVE', 'SHARE ROW EXCLUSIVE'),
    ('SHARE UPDATE EXCLUSIVE', 'EXCLUSIVE'),
    ('SHARE UPDATE EXCLUSIVE', 'ACCESS EXCLUSIVE'),
    ('SHARE', 'SHARE ROW EXCLUSIVE'),
    ('SHARE', 'EXCLUSIVE'),
    ('SHARE', 'ACCESS EXCLUSIVE'),
    ('SHARE ROW EXCLUSIVE', 'SHARE ROW EXCLUSIVE'),
    ('SHARE ROW EXCLUSIVE', 'EXCLUSIVE'),
    ('SHARE ROW EXCLUSIVE', 'ACCESS EXCLUSIVE'),
    ('EXCLUSIVE', 'EXCLUSIVE'),
    ('EXCLUSIVE', 'ACCESS EXCLUSIVE'),
    ('ACCESS EXCLUSIVE', 'ACCESS EXCLUSIVE')
ON CONFLICT (a, b) DO NOTHING;

DO $$
DECLARE
    inserted integer;
BEGIN
    INSERT INTO pgsafe.lock_conflict (held, requested)
    SELECT a, b FROM pgsafe.lock_conflict_seed
    UNION
    SELECT b, a FROM pgsafe.lock_conflict_seed
    ON CONFLICT (held, requested) DO NOTHING;

    SELECT count(*) INTO inserted FROM pgsafe.lock_conflict;
    IF inserted <> 38 THEN
        RAISE EXCEPTION 'lock_conflict holds % rows, the PostgreSQL 16 matrix has 38', inserted
            USING ERRCODE = 'data_exception';
    END IF;
END
$$;

-- What each schema change locks, and what work it does while holding it.
--   work: none | scan | rewrite | index_build
--   pattern: the directory under sql/patterns that shows the safe shape, or
--            NULL when PostgreSQL has no safe form of the statement.
CREATE TABLE IF NOT EXISTS pgsafe.statement_lock (
    form       text PRIMARY KEY,
    lock_mode  text NOT NULL REFERENCES pgsafe.lock_mode (mode),
    work       text NOT NULL CHECK (work IN ('none', 'scan', 'rewrite', 'index_build')),
    other_lock text,
    pattern    text,
    note       text NOT NULL
);

INSERT INTO pgsafe.statement_lock (form, lock_mode, work, other_lock, pattern, note) VALUES
    ('add_column_no_default', 'ACCESS EXCLUSIVE', 'none', NULL, '01_add_column_default',
     'Catalogue only. The lock is held for microseconds unless someone is already holding one.'),
    ('add_column_constant_default', 'ACCESS EXCLUSIVE', 'none', NULL, '01_add_column_default',
     'PostgreSQL 11 and later store the default as a missing value in pg_attribute, so no heap is touched.'),
    ('add_column_volatile_default', 'ACCESS EXCLUSIVE', 'rewrite', NULL, '01_add_column_default',
     'A volatile default has to be evaluated per row, which means a full rewrite under the lock.'),
    ('add_identity_column', 'ACCESS EXCLUSIVE', 'rewrite', NULL, '01_add_column_default',
     'An identity column draws from a sequence, which is volatile, so the rewrite rule above applies.'),
    ('set_not_null', 'ACCESS EXCLUSIVE', 'scan', NULL, '02_set_not_null',
     'Scans every row under the lock, unless a validated CHECK already proves the column non-null.'),
    ('set_not_null_with_valid_check', 'ACCESS EXCLUSIVE', 'none', NULL, '02_set_not_null',
     'PostgreSQL 12 and later skip the scan when a valid CHECK (col IS NOT NULL) exists.'),
    ('add_check_constraint', 'ACCESS EXCLUSIVE', 'scan', NULL, '02_set_not_null',
     'Validates every existing row before the lock is released.'),
    ('add_check_constraint_not_valid', 'ACCESS EXCLUSIVE', 'none', NULL, '02_set_not_null',
     'Catalogue only. New writes are checked from this point, old rows are not looked at.'),
    ('validate_constraint', 'SHARE UPDATE EXCLUSIVE', 'scan', NULL, '02_set_not_null',
     'Scans the table without blocking reads or writes. Must be its own transaction.'),
    ('create_index', 'SHARE', 'index_build', NULL, '03_create_index',
     'SHARE permits reads and blocks every write for the whole build.'),
    ('create_index_concurrently', 'SHARE UPDATE EXCLUSIVE', 'index_build', NULL, '03_create_index',
     'Two table scans and a wait for older transactions. Cannot run inside a transaction block.'),
    ('drop_index', 'ACCESS EXCLUSIVE', 'none', NULL, '03_create_index',
     'Blocks reads as well as writes, which is why it belongs in the concurrent form.'),
    ('drop_index_concurrently', 'SHARE UPDATE EXCLUSIVE', 'none', NULL, '03_create_index',
     'Marks the index dead, waits out the readers, then removes it.'),
    ('add_unique_constraint', 'ACCESS EXCLUSIVE', 'index_build', NULL, '03_create_index',
     'Builds the backing index while holding the lock. The USING INDEX form avoids that.'),
    ('add_unique_constraint_using_index', 'ACCESS EXCLUSIVE', 'none', NULL, '03_create_index',
     'Adopts an index that was built concurrently, so the lock covers catalogue work only.'),
    ('reindex', 'SHARE', 'index_build', 'ACCESS EXCLUSIVE', '03_create_index',
     'SHARE on the table, ACCESS EXCLUSIVE on the index being rebuilt.'),
    ('reindex_concurrently', 'SHARE UPDATE EXCLUSIVE', 'index_build', NULL, '03_create_index',
     'Builds a replacement index and swaps it, at the cost of a second copy on disk.'),
    ('alter_column_type', 'ACCESS EXCLUSIVE', 'rewrite', NULL, '04_change_type',
     'Rewrites the table and rebuilds every index on it, unless the change is a relabel.'),
    ('alter_column_type_relabel', 'ACCESS EXCLUSIVE', 'none', NULL, '04_change_type',
     'Binary coercible with no new modifier to verify, so the heap is left alone.'),
    ('rename_column', 'ACCESS EXCLUSIVE', 'none', NULL, '05_rename_column',
     'Instant, and it breaks every deployed reader that names the old column.'),
    ('drop_column', 'ACCESS EXCLUSIVE', 'none', NULL, '05_rename_column',
     'Marks the attribute dropped. The bytes stay until the rows are updated or the table is rewritten.'),
    ('add_foreign_key', 'SHARE ROW EXCLUSIVE', 'scan', 'SHARE ROW EXCLUSIVE', '06_add_foreign_key',
     'Locks both tables and scans the child to prove every row already matches.'),
    ('add_foreign_key_not_valid', 'SHARE ROW EXCLUSIVE', 'none', 'SHARE ROW EXCLUSIVE', '06_add_foreign_key',
     'Catalogue only, and new writes are enforced from here.'),
    ('set_default', 'ACCESS EXCLUSIVE', 'none', NULL, NULL,
     'Catalogue only. It changes what later inserts get and no existing row.'),
    ('truncate', 'ACCESS EXCLUSIVE', 'none', NULL, NULL,
     'Not a migration pattern. Listed because it is the fastest way to take an outage by accident.'),
    ('vacuum_full', 'ACCESS EXCLUSIVE', 'rewrite', NULL, NULL,
     'Rewrites the table with reads blocked. PostgreSQL has no online form of it.'),
    ('cluster', 'ACCESS EXCLUSIVE', 'rewrite', NULL, NULL,
     'Same cost as VACUUM FULL, in index order.'),
    ('vacuum', 'SHARE UPDATE EXCLUSIVE', 'scan', NULL, NULL,
     'Routine vacuum. Conflicts with itself and with a concurrent index build.'),
    ('analyze', 'SHARE UPDATE EXCLUSIVE', 'scan', NULL, NULL,
     'Samples the table. Same conflict class as a concurrent index build.')
ON CONFLICT (form) DO UPDATE SET
    lock_mode  = excluded.lock_mode,
    work       = excluded.work,
    other_lock = excluded.other_lock,
    pattern    = excluded.pattern,
    note       = excluded.note;

-- Every mode the given mode conflicts with, read from the matrix.
CREATE OR REPLACE FUNCTION pgsafe.conflicts_with(p_mode text)
RETURNS SETOF text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    canonical text := upper(btrim(p_mode));
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pgsafe.lock_mode WHERE mode = canonical) THEN
        RAISE EXCEPTION 'unknown lock mode: %', p_mode
            USING ERRCODE = 'undefined_object',
                  HINT = 'SELECT mode FROM pgsafe.lock_mode ORDER BY sort_order';
    END IF;

    RETURN QUERY
    SELECT c.requested
    FROM pgsafe.lock_conflict c
    JOIN pgsafe.lock_mode m ON m.mode = c.requested
    WHERE c.held = canonical
    ORDER BY m.sort_order;
END
$$;

-- A lock mode blocks reads when it conflicts with ACCESS SHARE, which is what
-- a plain SELECT takes, and blocks writes when it conflicts with ROW
-- EXCLUSIVE, which is what INSERT, UPDATE and DELETE take.
CREATE OR REPLACE FUNCTION pgsafe.blocks_reads(p_mode text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN 'ACCESS SHARE' IN (SELECT pgsafe.conflicts_with(p_mode));
END
$$;

CREATE OR REPLACE FUNCTION pgsafe.blocks_writes(p_mode text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN 'ROW EXCLUSIVE' IN (SELECT pgsafe.conflicts_with(p_mode));
END
$$;

-- The catalogue of statement forms with the consequence worked out rather than
-- restated. This is the view to read before arguing about a migration.
CREATE OR REPLACE VIEW pgsafe.statement_impact AS
SELECT
    s.form,
    s.lock_mode,
    s.work,
    pgsafe.blocks_reads(s.lock_mode)  AS blocks_reads,
    pgsafe.blocks_writes(s.lock_mode) AS blocks_writes,
    s.other_lock,
    s.pattern,
    s.note
FROM pgsafe.statement_lock s
JOIN pgsafe.lock_mode m ON m.mode = s.lock_mode
ORDER BY m.sort_order DESC, s.form;

COMMENT ON VIEW pgsafe.statement_impact IS
    'Statement forms with blocks_reads and blocks_writes derived from the conflict matrix.';
