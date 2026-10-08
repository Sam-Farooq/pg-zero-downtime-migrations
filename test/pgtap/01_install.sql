-- The library installed: the objects the rest of the suite and the README name.
BEGIN;
SELECT plan(22);

SELECT has_schema('pgsafe');
SELECT has_table('pgsafe', 'lock_mode', 'the eight lock modes are a table');
SELECT has_table('pgsafe', 'lock_conflict', 'the conflict matrix is a table');
SELECT has_table('pgsafe', 'statement_lock', 'the statement catalogue is a table');
SELECT has_view('pgsafe', 'statement_impact', 'the derived view exists');

SELECT has_function('pgsafe'::name, 'version'::name);
SELECT has_function('pgsafe'::name, 'parse_type'::name);
SELECT has_function('pgsafe'::name, 'type_change'::name);
SELECT has_function('pgsafe'::name, 'rewrites'::name);
SELECT has_function('pgsafe'::name, 'column_type_change'::name);
SELECT has_function('pgsafe'::name, 'expression_is_volatile'::name);
SELECT has_function('pgsafe'::name, 'run_guarded'::name);
SELECT has_function('pgsafe'::name, 'assert_index_valid'::name);
SELECT has_function('pgsafe'::name, 'sync_column_pair'::name);
SELECT has_function('pgsafe'::name, 'plan_set_not_null'::name);
SELECT has_function('pgsafe'::name, 'plan_add_column'::name);
SELECT has_function('pgsafe'::name, 'plan_change_type'::name);
SELECT has_function('pgsafe'::name, 'plan_rename_column'::name);
SELECT has_function('pgsafe'::name, 'plan_create_index'::name);
SELECT has_function('pgsafe'::name, 'plan_add_foreign_key'::name);
SELECT has_function('pgsafe'::name, 'preflight'::name);

SELECT matches(
    pgsafe.version(),
    '^[0-9]+[.][0-9]+[.][0-9]+$',
    'version() returns a three part version, which tests/test_catalogue.py ties to pyproject.toml'
);

SELECT * FROM finish();
ROLLBACK;
