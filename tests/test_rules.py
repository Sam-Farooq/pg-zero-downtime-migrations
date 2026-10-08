"""One case per rule, and a test that every rule has one."""

from __future__ import annotations

import pytest

from pgsafe.lexer import lex
from pgsafe.rules import RULES, RULES_BY_ID, analyse, transaction_ids

TIMEOUT = "SET lock_timeout = '3s';\n"

CASES: tuple[tuple[str, str, str], ...] = (
    (
        "volatile_default",
        "autocommit",
        TIMEOUT + "ALTER TABLE app.orders ADD COLUMN public_id uuid NOT NULL DEFAULT gen_random_uuid();",
    ),
    (
        "identity_column_added",
        "autocommit",
        TIMEOUT + "ALTER TABLE app.orders ADD COLUMN n bigint GENERATED ALWAYS AS IDENTITY;",
    ),
    ("unbatched_backfill", "autocommit", "UPDATE app.orders SET status = 'placed';"),
    (
        "set_not_null_direct",
        "autocommit",
        TIMEOUT + "ALTER TABLE app.orders ALTER COLUMN shipping_country SET NOT NULL;",
    ),
    (
        "check_without_not_valid",
        "autocommit",
        TIMEOUT + "ALTER TABLE app.orders ADD CONSTRAINT orders_total_positive CHECK (legacy_amount > 0);",
    ),
    (
        "validate_in_same_transaction",
        "transactional",
        TIMEOUT
        + "ALTER TABLE app.orders ADD CONSTRAINT ck CHECK (note IS NOT NULL) NOT VALID;\n"
        + "ALTER TABLE app.orders VALIDATE CONSTRAINT ck;",
    ),
    (
        "index_without_concurrently",
        "autocommit",
        TIMEOUT + "CREATE INDEX orders_customer_id_idx ON app.orders (customer_id);",
    ),
    (
        "drop_index_without_concurrently",
        "autocommit",
        TIMEOUT + "DROP INDEX app.orders_customer_id_idx;",
    ),
    (
        "concurrently_inside_transaction",
        "autocommit",
        TIMEOUT + "BEGIN;\nCREATE INDEX CONCURRENTLY i ON app.orders (customer_id);\nCOMMIT;",
    ),
    (
        "unique_constraint_builds_index",
        "autocommit",
        TIMEOUT + "ALTER TABLE app.orders ADD CONSTRAINT orders_reference_key UNIQUE (reference);",
    ),
    (
        "type_change_needs_a_verdict",
        "autocommit",
        TIMEOUT + "ALTER TABLE app.orders ALTER COLUMN legacy_amount TYPE bigint;",
    ),
    (
        "rename_breaks_readers",
        "autocommit",
        TIMEOUT + "ALTER TABLE app.orders RENAME COLUMN note TO customer_note;",
    ),
    (
        "drop_column_breaks_readers",
        "autocommit",
        TIMEOUT + "ALTER TABLE app.orders DROP COLUMN note;",
    ),
    (
        "fk_without_not_valid",
        "autocommit",
        TIMEOUT
        + "ALTER TABLE app.orders ADD CONSTRAINT orders_customer_id_fkey "
        + "FOREIGN KEY (customer_id) REFERENCES app.customers (customer_id);",
    ),
    ("missing_lock_timeout", "autocommit", "ALTER TABLE app.orders ADD COLUMN c integer;"),
    ("lock_timeout_disabled", "autocommit", "SET lock_timeout = 0;"),
    ("set_local_outside_transaction", "autocommit", "SET LOCAL lock_timeout = '3s';"),
    ("exclusive_maintenance", "autocommit", TIMEOUT + "VACUUM FULL app.orders;"),
    (
        "attach_partition_scans",
        "autocommit",
        TIMEOUT
        + "ALTER TABLE app.events ATTACH PARTITION app.events_2026q3 "
        + "FOR VALUES FROM ('2026-07-01') TO ('2026-10-01');",
    ),
    (
        "detach_partition_blocks_reads",
        "autocommit",
        TIMEOUT + "ALTER TABLE app.events DETACH PARTITION app.events_2026q1;",
    ),
)


@pytest.mark.parametrize(("rule_id", "runner", "sql"), CASES, ids=[c[0] for c in CASES])
def test_rule_fires(rule_id: str, runner: str, sql: str):
    fired = {finding.rule for finding in analyse(sql, runner=runner).findings}
    assert rule_id in fired, f"{rule_id} did not fire on:\n{sql}"


def test_every_rule_has_a_case():
    covered = {case[0] for case in CASES}
    assert covered == set(RULES_BY_ID), set(RULES_BY_ID) - covered


def test_severity_is_one_of_two_words():
    assert {rule.severity for rule in RULES} == {"error", "warning"}


def test_the_finding_carries_the_detail_that_identifies_the_column():
    analysis = analyse(
        TIMEOUT + "ALTER TABLE app.orders ALTER COLUMN legacy_amount TYPE bigint;",
        runner="autocommit",
    )
    finding = next(f for f in analysis.findings if f.rule == "type_change_needs_a_verdict")
    assert "app.orders.legacy_amount to bigint" in finding.why


def test_several_actions_in_one_alter_are_each_judged():
    sql = (
        TIMEOUT
        + "ALTER TABLE app.orders\n"
        + "    ADD COLUMN public_id uuid NOT NULL DEFAULT gen_random_uuid(),\n"
        + "    ALTER COLUMN shipping_country SET NOT NULL,\n"
        + "    DROP COLUMN note;"
    )
    fired = sorted({f.rule for f in analyse(sql, runner="autocommit").findings})
    assert fired == [
        "drop_column_breaks_readers",
        "set_not_null_direct",
        "volatile_default",
    ]


def test_set_not_null_is_allowed_once_a_validated_check_proves_it():
    sql = (
        TIMEOUT
        + "ALTER TABLE app.orders ADD CONSTRAINT orders_note_not_null CHECK (note IS NOT NULL) NOT VALID;\n"
        + "ALTER TABLE app.orders VALIDATE CONSTRAINT orders_note_not_null;\n"
        + "ALTER TABLE app.orders ALTER COLUMN note SET NOT NULL;"
    )
    assert analyse(sql, runner="autocommit").findings == []


def test_the_same_sequence_in_one_transaction_is_not_allowed():
    sql = (
        TIMEOUT
        + "ALTER TABLE app.orders ADD CONSTRAINT orders_note_not_null CHECK (note IS NOT NULL) NOT VALID;\n"
        + "ALTER TABLE app.orders VALIDATE CONSTRAINT orders_note_not_null;\n"
        + "ALTER TABLE app.orders ALTER COLUMN note SET NOT NULL;"
    )
    fired = sorted({f.rule for f in analyse(sql, runner="transactional").findings})
    assert fired == ["set_not_null_direct", "validate_in_same_transaction"]


def test_attach_is_allowed_once_a_check_on_the_partition_is_validated():
    sql = (
        TIMEOUT
        + "ALTER TABLE app.events_2026q3 ADD CONSTRAINT events_2026q3_bound "
        + "CHECK (occurred_at IS NOT NULL AND occurred_at >= '2026-07-01' "
        + "AND occurred_at < '2026-10-01') NOT VALID;\n"
        + "ALTER TABLE app.events_2026q3 VALIDATE CONSTRAINT events_2026q3_bound;\n"
        + "ALTER TABLE app.events ATTACH PARTITION app.events_2026q3 "
        + "FOR VALUES FROM ('2026-07-01') TO ('2026-10-01');"
    )
    assert analyse(sql, runner="autocommit").findings == []


def test_a_finalize_is_not_a_second_detach():
    sql = TIMEOUT + "ALTER TABLE app.events DETACH PARTITION app.events_2026q1 FINALIZE;"
    assert analyse(sql, runner="autocommit").findings == []


def test_the_runner_decides_whether_concurrently_is_possible():
    sql = TIMEOUT + "CREATE INDEX CONCURRENTLY i ON app.orders (customer_id);"
    assert analyse(sql, runner="autocommit").findings == []
    fired = {f.rule for f in analyse(sql, runner="transactional").findings}
    assert "concurrently_inside_transaction" in fired


def test_transaction_numbering_under_autocommit():
    script = lex("SELECT 1;\nSELECT 2;\nSELECT 3;", runner="autocommit")
    ids, blocks = transaction_ids(script)
    assert ids == [1, 2, 3]
    assert blocks == [False, False, False]


def test_transaction_numbering_inside_an_explicit_block():
    script = lex("BEGIN;\nSELECT 1;\nSELECT 2;\nCOMMIT;\nSELECT 3;", runner="autocommit")
    ids, blocks = transaction_ids(script)
    assert ids == [1, 1, 1, 1, 2]
    assert blocks == [True, True, True, True, False]


def test_a_transactional_file_is_one_transaction():
    script = lex("SELECT 1;\nSELECT 2;", runner="transactional")
    ids, _ = transaction_ids(script)
    assert ids == [1, 1]


def test_a_pragma_naming_no_rule_is_a_problem():
    sql = TIMEOUT + "-- pgsafe: allow no_such_rule it does not exist at all\nSELECT 1;"
    analysis = analyse(sql, runner="autocommit")
    assert [p.message for p in analysis.problems] == ["allow names no such rule: 'no_such_rule'"]


def test_an_allow_without_a_reason_is_a_problem():
    sql = TIMEOUT + "-- pgsafe: allow drop_column_breaks_readers ok\nALTER TABLE app.orders DROP COLUMN note;"
    analysis = analyse(sql, runner="autocommit")
    assert analysis.problems
    assert "at least 12 characters" in analysis.problems[0].message
    assert analysis.findings == []


def test_an_allow_with_a_reason_records_it():
    sql = (
        TIMEOUT
        + "-- pgsafe: allow drop_column_breaks_readers nothing has read this column since release 42\n"
        + "ALTER TABLE app.orders DROP COLUMN note;"
    )
    analysis = analyse(sql, runner="autocommit")
    assert analysis.findings == []
    assert analysis.problems == []
    assert analysis.allowances[0].rule == "drop_column_breaks_readers"
    assert "release 42" in analysis.allowances[0].reason
