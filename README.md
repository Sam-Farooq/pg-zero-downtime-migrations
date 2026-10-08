# pg-zero-downtime-migrations

Eight schema changes that break a deploy, each with the statement that breaks it
and the sequence that does not, in runnable SQL. Plus a linter, so a pull request
finds out before the deploy does.

The SQL is the substance: 10 files of PL/pgSQL in `sql/lib`, 52 functions and one
procedure, and 16 migration files under `sql/patterns`. The Python is a linter
and nothing else, with no runtime dependencies at all.

```
sql/patterns/NN_name/unsafe.sql    the statement somebody wrote
                     safe.sql      the same change, with the lock accounted for
sql/lib/*.sql                      the library the safe halves use
pgsafe/                            the linter, 20 rules, zero dependencies
test/pgtap/                        220 assertions against a real PostgreSQL 16
tests/                             179 tests that need no database
```

## The catalogue

Every row is a directory. Both halves run; the unsafe half is unsafe because of
what it holds while it runs, not because it fails.

| Change | What the obvious statement does | The safe shape |
|---|---|---|
| [add a column with a default](sql/patterns/01_add_column_default) | a volatile default is evaluated per row, so the table is rewritten under ACCESS EXCLUSIVE | add it empty, SET DEFAULT for new rows, backfill in committed batches, then NOT NULL. A constant default needs none of it |
| [SET NOT NULL](sql/patterns/02_set_not_null) | scans every row holding ACCESS EXCLUSIVE, which stops reads | CHECK NOT VALID, VALIDATE in a second transaction, then SET NOT NULL, which skips its scan |
| [build an index](sql/patterns/03_create_index) | SHARE blocks every write for the whole build | CONCURRENTLY, then ask whether it worked, because a failed build leaves an index behind |
| [change a column type](sql/patterns/04_change_type) | rewrites the table and every index on it | ask pg_cast first. Free when it is a relabel, a new column and a dual write when it is not |
| [rename a column](sql/patterns/05_rename_column) | instant, and every deployed reader breaks on the next query | expand, migrate, contract, with a trigger keeping the pair equal across the deploy |
| [add a foreign key](sql/patterns/06_add_foreign_key) | scans the child holding SHARE ROW EXCLUSIVE on both tables | NOT VALID, then VALIDATE, where the child takes SHARE UPDATE EXCLUSIVE |
| [bound the lock wait](sql/patterns/07_lock_timeout) | lock_timeout defaults to 0, which means wait forever | set it, look at who is holding the table, and retry |
| [attach a partition](sql/patterns/08_attach_partition) | scans the attached table and builds the parent's indexes on it | a validated CHECK matching the bound, indexes built concurrently, then attach |

## The queue is the problem, not the lock

The statement in `07_lock_timeout` is `ALTER TABLE ... ALTER COLUMN status SET
DEFAULT 'placed'`. It reads no row. It is a catalogue write, and it is the most
dangerous statement in the repository.

It needs ACCESS EXCLUSIVE. That queues behind every open transaction holding a
conflicting lock on the table, including one that is idle in transaction after
reading it ten minutes ago. While it waits, PostgreSQL does not let later
requests overtake it, so every SELECT that arrives behind it waits too. A one
millisecond change behind a long read is a total outage on that table for as
long as the read lasts, and nothing in the migration is slow.

`lock_timeout` does not prevent that. It bounds it. On its own a short timeout
turns an outage into a failed deploy, which is better and is not the same as
working, so `pgsafe.run_guarded()` retries: each failed attempt is a
subtransaction that rolls back and gives up its place in the queue, which lets
the traffic behind it drain before the next try.

```sql
SELECT * FROM pgsafe.preflight();                 -- anything already in the way?
SELECT * FROM pgsafe.blockers('app.orders');      -- who, and the pid to cancel
SELECT * FROM pgsafe.run_guarded(
    $stmt$ALTER TABLE app.orders ALTER COLUMN status SET DEFAULT 'placed'$stmt$,
    '3s', 5, interval '2 seconds');
```

3 seconds and 5 attempts are conventions in this repository. Nothing here timed
a real migration.

## Does it rewrite? The answer is in pg_cast

The folklore is that widening a type is free and narrowing is a rewrite. It is
half right, and the half that is wrong costs a deploy.

```sql
SELECT * FROM pgsafe.type_change('varchar(32)', 'varchar(64)');
-- no_rewrite  varchar is not padded, and 64 cannot reject a value that fits 32

SELECT * FROM pgsafe.type_change('integer', 'bigint');
-- rewrite     the change runs int8(integer) per row, so the table is written
--             again and every index on it is rebuilt
```

`varchar(32)` to `varchar(64)` is binary coercible with a looser modifier, so the
heap is untouched. `integer` to `bigint` is four bytes becoming eight: pg_cast
reaches it through a function and every row is converted. Both are widenings and
one of them is a full rewrite.

Even the free one is not instant. The documented exception says a rewrite is
avoided; the indexes on the column are rebuilt anyway, under ACCESS EXCLUSIVE.

The verdict comes from `pg_cast` and the type modifier rather than from a list,
which is why it is a function in the database and not a table in the linter.
Where it has no rule, it says `unknown` instead of guessing, and
`pgsafe.rewrites()` raises rather than returning a boolean nobody should trust.
`numeric(10,2)` to `numeric(12,2)` is the case it refuses.

## The linter, and the question it cannot answer

```
$ pgsafe check sql/patterns/02_set_not_null/unsafe.sql
sql/patterns/02_set_not_null/unsafe.sql: 2 statements, runner autocommit (declared)

  error   line 21  unbatched_backfill
         UPDATE app.orders SET shipping_country = coalesce(shipping_country, 'ZZ')
         why  one transaction writes every row, holds a row lock on each until it
         commits, and leaves one dead tuple per row for autovacuum to find afterwards
         (update)
         fix  walk the primary key in batches that each commit, with the predicate
         acting as the progress marker so an interrupted run resumes
         see  sql/patterns/01_add_column_default/safe.sql

  error   line 23  set_not_null_direct
         ALTER TABLE app.orders ALTER COLUMN shipping_country SET NOT NULL
         why  SET NOT NULL has to prove no null is left, and it does that with a full
         scan while holding ACCESS EXCLUSIVE, so reads stop for the length of the scan
         (no validated CHECK proves app.orders.shipping_country in an earlier tx)
         fix  ADD CONSTRAINT ... CHECK (col IS NOT NULL) NOT VALID, then VALIDATE
         CONSTRAINT in a second transaction, then SET NOT NULL, which skips its scan
         on PostgreSQL 12 and later because the valid CHECK already answers the
         question
         see  sql/patterns/02_set_not_null/safe.sql
```

The third finding on that file is `missing_lock_timeout`, on the same statement,
and it is left out of the paste rather than invented: run the command to see it.

20 rules, 18 at error and 2 at warning. `pgsafe rules` prints them from the
source of truth and `pgsafe explain <rule>` prints one in full with the lock it
takes and the pattern that fixes it.

One rule is different. `ALTER TABLE ... ALTER COLUMN x TYPE bigint` cannot be
judged from the file, because the cost depends on the type the column is coming
from and that is in the database. The linter refuses it and names the way to
find out, and the answer is recorded in the migration that depends on it:

```sql
-- pgsafe: allow type_change_needs_a_verdict pgsafe.type_change('varchar(32)','varchar(64)')
-- returns no_rewrite, binary coercible with a looser modifier
ALTER TABLE app.orders ALTER COLUMN reference TYPE varchar(64);
```

A pragma needs a reason of at least 12 characters, naming a rule that exists, and
every one of them is printed in the summary. There are three in the catalogue:
two on a `DROP COLUMN` and this one.

### Which runner, because the same file is safe under one and not the other

A framework that wraps each migration in `BEGIN` makes `CREATE INDEX
CONCURRENTLY` impossible, and collapses NOT VALID and VALIDATE into one
transaction, where they buy nothing. One that commits each statement does
neither. The file cannot be judged without knowing which.

So the linter does not guess silently. It assumes the file is wrapped, because
that is the assumption under which more things are errors, and a file can say
otherwise in its first comment:

```sql
-- pgsafe: runner autocommit
```

Every file in `sql/patterns` declares it, because `test/run.sh` applies them
through psql.

### What it will not flag

A linter that cries wolf gets switched off, so half the test suite is statements
that must come out clean: a constant or stable default, a volatile expression in
`SET DEFAULT` (which touches no existing row), `CONCURRENTLY` under an autocommit
runner, `NOT VALID` on a check or a foreign key, `UNIQUE USING INDEX`, a
`SET NOT NULL` that a validated CHECK already proves, `UPDATE` with a `WHERE`
clause, `REINDEX INDEX CONCURRENTLY`, and everything done to a table created
earlier in the same file, which nobody can be reading yet.

The exemption for a new table does not extend to an index on a live one. That
was a bug: `DROP INDEX` passed because the index had been created a few lines
above, and dropping it still takes ACCESS EXCLUSIVE on a table in use.

## The lock matrix is data

`pgsafe.lock_conflict` holds the PostgreSQL 16 conflict matrix as 38 directed
rows, loaded from 21 unordered pairs and mirrored by the loader, so symmetry is a
property of the load rather than of typing 38 rows correctly. The pgTAP suite
asserts both.

Everything else is derived from it. A mode blocks reads when it conflicts with
ACCESS SHARE and blocks writes when it conflicts with ROW EXCLUSIVE, so nothing
in the repository states those separately:

```sql
SELECT form, lock_mode, work, blocks_reads, blocks_writes
  FROM pgsafe.statement_impact
 WHERE pattern = '03_create_index';
```

37 statement forms are catalogued that way, and every lock mode a plan or a rule
names has to be one of them: `pgsafe.form_lock()` raises on anything else, and
`tests/test_catalogue.py` fails if a rule names a form the table does not hold.

Every row in both tables is transcribed from the PostgreSQL 16 documentation.
Nothing here measured a lock.

## The library

| File | What is in it |
|---|---|
| `01_schema.sql` | the schema, four composite types, and the version the Python side is tested against |
| `02_lock_matrix.sql` | the conflict matrix and the 37 statement forms, as tables |
| `03_type_change.sql` | the rewrite verdict, from pg_cast and the type modifier |
| `04_guards.sql` | bounded lock waits with retries, the invalid index check, and the dual write trigger |
| `05_plans.sql` | six generators, each returning one row per statement with the transaction boundaries numbered |
| `06_introspect.sql` | who is holding the table, what is waiting, what a failed build left behind |
| `07_apply.sql` | a procedure that applies a plan, committing at each boundary, and the log it writes |
| `08_facts.sql` | size, the rewrite budget, indexes nothing reads, replication lag |
| `09_assertions.sql` | the data questions a scan would have answered the expensive way |
| `10_partitions.sql` | attach without the scan, detach without closing the parent |

Two of those are worth reading before the rest.

**The plans return rows, not a script.** A plan has transaction boundaries in it,
and a migration file cannot express one. So `pgsafe.plan_set_not_null()` returns
four rows with `tx` 1 to 4, and a row whose `tx` differs from the one before it
has to be committed first:

```sql
SELECT step, tx, lock_mode, work, statement
  FROM pgsafe.plan_add_column('app.orders', 'public_id', 'uuid', 'gen_random_uuid()', true);
```

Seven steps, because the default is volatile. Pass `'false'` for the default and
it is one, because a constant default has been stored in
`pg_attribute.attmissingval` since PostgreSQL 11 rather than written to every
row. The generator asks `pg_proc` which of the two it is.

**The dual write trigger is the part of a rename that has to be right.** While
`pgsafe.sync_column_pair()` is attached, a writer may use either column name and
the other follows, so a half finished rolling deploy is correct rather than
lucky. It reaches the record through `jsonb`, because a trigger function cannot
name a column it was only told about at runtime, and it tests
`jsonb_typeof(value) = 'null'` rather than `value IS NULL`: a column holding SQL
NULL becomes a JSON null rather than disappearing, and a hand written version
that gets this wrong copies nothing and looks fine.

## Commands

```bash
python3.11 -m venv .venv
. .venv/bin/activate
pip install -e ".[dev]"

pytest                                   # 179 tests, no database, no network
ruff check . && ruff format --check .

pgsafe check sql/patterns/*/safe.sql     # exits 0
pgsafe check sql/patterns                # exits 1: the unsafe halves are in there
pgsafe rules
pgsafe explain attach_partition_scans
pgsafe check sql/patterns/08_attach_partition --format json --warn-as-error
```

Against a PostgreSQL 16 with pgTAP, where the role needs CREATEDB and superuser
for `CREATE EXTENSION pgtap`:

```bash
make install                             # the 10 library files, in order
make reset                               # DROP SCHEMA pgsafe CASCADE
PGHOST=localhost PGUSER=postgres bash test/run.sh
```

`test/run.sh` builds two throwaway databases, applies the library and
`test/fixtures.sql` to both, runs the pgTAP files, then applies every `safe.sql`
to one database and every `unsafe.sql` to the other. Two databases because the
halves reach different end states, and because an unsafe statement has to be
proved runnable rather than only linted.

Exit codes from `pgsafe check`:

| code | meaning |
|---|---|
| 0 | nothing to report |
| 1 | a finding that counts, or a pragma problem |
| 2 | refused: a file that cannot be read or cannot be split into statements |

2 is not 1 on purpose. A build that treats a refusal as a pass has no gate,
because an unreadable migration reads as nothing to report.

## Tests

**179 Python tests, no database and no network.** The scanner, every rule, the
statements that must not be flagged, the CLI's exit codes, and the two
cross-checks that keep the halves of this repository honest: every lock form a
rule names has to exist in `pgsafe.statement_lock`, and every function in
`sql/lib` has to be exercised by the pgTAP suite.

`tests/test_sql_parses.py` runs all 38 `.sql` files in the repository through
libpg_query, which is PostgreSQL's own parser compiled as a library, and runs the
PL/pgSQL parser over the function bodies that the SQL grammar sees only as string
literals. It proves syntax, on a runner with no database. It proves nothing about
behaviour.

**220 pgTAP assertions across 11 files**, which is the part that needs a server:
the conflict matrix, the type verdicts, the guards, the plans, the trigger, the
plan runner, the data assertions, the partition functions, and the end state the
catalogue leaves behind. The last of those,
`test/pgtap/90_pattern_end_state.sql`, runs after every `safe.sql` has been
applied, and checks the result rather than the statements: 500 distinct uuids
from the backfill, `sum(legacy_amount_big)` equal to the arithmetic the fixture
used, the unique constraint sitting on the index that was built concurrently
rather than one of its own, the two dual write triggers gone, and 200 rows across
the two partitions still attached.

The linter is pinned to `pytest==9.1.1`, `ruff==0.16.10` and `pglast==6.14`, and
has no runtime dependencies.

## What has actually run

The Python tests and the linters ran here, and the numbers above come from those
runs: 179 passing, clean under both ruff checks.

**The SQL has never been executed in this repository.** Every `.sql` file parses
under PostgreSQL's own grammar, and that is all that has happened to it. The
pgTAP suite is wired into CI, where a container is started, pgTAP is installed
into it and `test/run.sh` runs, and that is the first place any of this SQL will
meet a server. Until a run is green, treat the 220 assertions as unproven.

Nothing in here measured a lock, a duration or a table size:

- every lock mode and every statement form is transcribed from the PostgreSQL 16
  documentation
- `test/fixtures.sql` is hand written: 50 customers, 500 orders, and 300 events
  across three quarters, all generated by the statements in that file
- 3 seconds, 5 attempts, a 100 row batch and 100 MB/s are conventions and
  parameters, not findings. `pgsafe.rewrite_estimate()` takes the throughput as
  an argument and prints the assumption next to the answer
- the only numbers anywhere that come from a run are the durations in
  `pgsafe.migration_log`, which exist once somebody has applied a plan

## Where it can still be wrong

- **The linter reads text, so it does not know your schema.** It cannot tell
  whether a type change rewrites, and it asks the weaker question for an attach:
  "was any CHECK on this partition validated earlier in the file", where
  PostgreSQL does a predicate implication test over the real constraint.
  `pgsafe.attach_will_scan()` has the same limit from the other side: it is a
  text test over `pg_get_constraintdef`, so it can say a scan will happen where
  PostgreSQL would have skipped it.
- **A statement form the scanner has no rule for produces no finding.** That is
  the honest failure for a text matcher and it is still a silence.
- **`pgsafe.expression_is_volatile()` matches function names and asks pg_proc.**
  An overloaded name with one volatile form reads as volatile, and a volatile
  function reached through a view or an operator is not seen. The linter's own
  version is a fixed list of 11 names, which is narrower again.
- **`pgsafe.type_change()` has no rule for numeric modifiers.** It returns
  `unknown` with the suggestion to compare `pg_class.relfilenode` on a copy. A
  pair with no `pg_cast` row is reported as `cast_required`, which overstates the
  need for a `USING` clause where PostgreSQL would reach the type through an I/O
  conversion. The cost is a rewrite either way.
- **The data assertions are a point in time.** A row that arrives between the
  check and the statement is not in the answer, which is why the constraint
  patterns enforce new writes first and validate afterwards.
- **`pgsafe.unused_indexes()` reads `idx_scan` since the last statistics reset on
  this server.** A standby serving reads has its own counters, and an index used
  once a quarter looks unused for the other three months.
- **`pgsafe.run_guarded()` is one statement at a time.** A function body is a
  transaction, so nothing it runs is committed until the caller commits, and
  `CONCURRENTLY` is refused outright rather than attempted.
- **The pattern files are a catalogue, not a migration history.** Both halves of
  a pattern run against `test/fixtures.sql` and the columns are divided up so the
  eight can be applied one after another. Real migrations arrive one per release
  and the contract phases belong in later ones, which the files say where it
  matters and cannot enforce.

## What it does not do

- **No migration runner.** No versions, no up and down, no state table beyond the
  log. `pgsafe.apply_plan()` applies one plan and records it; Alembic, Flyway,
  Rails and sqlx all already exist and all of them wrap files in transactions,
  which is the thing the runner pragma is about.
- **No rewrite tooling.** `VACUUM FULL` and `CLUSTER` have no online form inside
  PostgreSQL, so `exclusive_maintenance` is the one rule in the table that names
  no safe rewrite. The answer is a window or an external tool, and neither is a
  line in a migration.
- **No other dialect.** Every rule here is a PostgreSQL rule. The NOT VALID
  trick, `attmissingval`, `CONCURRENTLY` and the detach pending state are not
  concepts MySQL or SQL Server share.
- **No advice about your traffic.** The library can say a statement takes ACCESS
  EXCLUSIVE and scans 40 GB. Whether 90 seconds of that is survivable is a
  property of what is in front of the database.

## Licence

MIT.
