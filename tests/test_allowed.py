"""Statements the linter must not flag.

A linter that cries wolf gets switched off, so this file is the half of the
suite that matters. Every case here is a statement that is genuinely safe and
looks, to a shallow matcher, like one that is not.
"""

from __future__ import annotations

import pytest

from pgsafe.rules import analyse

TIMEOUT = "SET lock_timeout = '3s';\n"

ALLOWED: tuple[tuple[str, str], ...] = (
    (
        "a constant default is stored once, not per row",
        "ALTER TABLE app.orders ADD COLUMN is_gift boolean NOT NULL DEFAULT false;",
    ),
    (
        "now() is stable, so it is evaluated once",
        "ALTER TABLE app.orders ADD COLUMN seen_at timestamptz NOT NULL DEFAULT now();",
    ),
    (
        "current_timestamp is the same thing spelled differently",
        "ALTER TABLE app.orders ADD COLUMN seen_at timestamptz DEFAULT current_timestamp;",
    ),
    (
        "a volatile expression in SET DEFAULT touches no existing row",
        "ALTER TABLE app.orders ALTER COLUMN public_id SET DEFAULT gen_random_uuid();",
    ),
    (
        "a nullable column with no default is a catalogue change",
        "ALTER TABLE app.orders ADD COLUMN public_id uuid;",
    ),
    (
        "DROP DEFAULT is a catalogue change",
        "ALTER TABLE app.orders ALTER COLUMN status DROP DEFAULT;",
    ),
    (
        "DROP CONSTRAINT is a catalogue change",
        "ALTER TABLE app.orders DROP CONSTRAINT orders_note_not_null;",
    ),
    (
        "a CHECK added NOT VALID reads no existing row",
        "ALTER TABLE app.orders ADD CONSTRAINT ck CHECK (legacy_amount > 0) NOT VALID;",
    ),
    (
        "a foreign key added NOT VALID reads no existing row",
        "ALTER TABLE app.orders ADD CONSTRAINT fk FOREIGN KEY (customer_id) "
        "REFERENCES app.customers (customer_id) NOT VALID;",
    ),
    (
        "a unique constraint adopting an existing index builds nothing",
        "ALTER TABLE app.orders ADD CONSTRAINT orders_reference_key UNIQUE USING INDEX orders_reference_uq;",
    ),
    (
        "a concurrent index build under an autocommit runner",
        "CREATE INDEX CONCURRENTLY orders_customer_id_idx ON app.orders (customer_id);",
    ),
    (
        "a partial concurrent index build",
        "CREATE INDEX CONCURRENTLY orders_open_idx ON app.orders (placed_at) WHERE status <> 'shipped';",
    ),
    (
        "a concurrent drop",
        "DROP INDEX CONCURRENTLY app.orders_open_idx;",
    ),
    (
        "a concurrent reindex",
        "REINDEX INDEX CONCURRENTLY app.orders_customer_id_idx;",
    ),
    (
        "an UPDATE with a WHERE clause",
        "UPDATE app.orders SET shipping_country = 'ZZ' WHERE order_id BETWEEN 1 AND 100;",
    ),
    (
        "a DELETE with a WHERE clause",
        "DELETE FROM app.orders WHERE placed_at < now() - interval '7 years';",
    ),
    (
        "a routine vacuum is not VACUUM FULL",
        "VACUUM ANALYZE app.orders;",
    ),
    (
        "creating a new table and indexing it in the same file",
        "CREATE TABLE app.shipments (shipment_id bigint PRIMARY KEY, order_id bigint NOT NULL);\n"
        "CREATE INDEX shipments_order_id_idx ON app.shipments (order_id);\n"
        "ALTER TABLE app.shipments ADD COLUMN tracking uuid NOT NULL DEFAULT gen_random_uuid();\n"
        "ALTER TABLE app.shipments ALTER COLUMN order_id SET NOT NULL;",
    ),
    (
        "a comment that happens to contain a dangerous statement",
        "-- ALTER TABLE app.orders ALTER COLUMN note SET NOT NULL;\nSELECT 1;",
    ),
    (
        "a function body is not a sequence of statements to lint",
        "CREATE OR REPLACE FUNCTION app.touch() RETURNS trigger AS $body$\n"
        "BEGIN\n"
        "    UPDATE app.orders SET status = 'seen';\n"
        "    RETURN NEW;\n"
        "END\n"
        "$body$ LANGUAGE plpgsql;",
    ),
    (
        "SET LOCAL inside an explicit block does apply",
        "BEGIN;\nSET LOCAL lock_timeout = '3s';\nALTER TABLE app.orders ADD COLUMN c integer;\nCOMMIT;",
    ),
    (
        "a SELECT is a SELECT",
        "SELECT * FROM pgsafe.preflight();",
    ),
)


@pytest.mark.parametrize(("description", "sql"), ALLOWED, ids=[c[0] for c in ALLOWED])
def test_not_flagged(description: str, sql: str):
    findings = analyse(TIMEOUT + sql, runner="autocommit").findings
    assert findings == [], f"{description}: {[f.rule for f in findings]}"


def test_a_table_created_in_the_same_file_is_counted_as_skipped():
    sql = (
        TIMEOUT
        + "CREATE TABLE app.shipments (shipment_id bigint PRIMARY KEY);\n"
        + "ALTER TABLE app.shipments ADD COLUMN tracking uuid NOT NULL DEFAULT gen_random_uuid();"
    )
    analysis = analyse(sql, runner="autocommit")
    assert analysis.findings == []
    assert analysis.skipped_new_relations == 1


def test_the_exemption_does_not_extend_to_an_index_on_a_live_table():
    # The bug this test exists for: the index below is created in this file, and
    # dropping it still takes ACCESS EXCLUSIVE on a table that is in use.
    sql = (
        TIMEOUT
        + "CREATE INDEX CONCURRENTLY orders_tmp_idx ON app.orders (status);\n"
        + "DROP INDEX app.orders_tmp_idx;"
    )
    fired = {f.rule for f in analyse(sql, runner="autocommit").findings}
    assert fired == {"drop_index_without_concurrently"}


def test_lock_timeout_set_once_covers_the_rest_of_an_autocommit_file():
    sql = (
        TIMEOUT + "ALTER TABLE app.orders ADD COLUMN a integer;\nALTER TABLE app.orders ADD COLUMN b integer;"
    )
    assert analyse(sql, runner="autocommit").findings == []


def test_lock_timeout_set_to_zero_stops_covering():
    sql = (
        TIMEOUT
        + "ALTER TABLE app.orders ADD COLUMN a integer;\n"
        + "SET lock_timeout = '0';\n"
        + "ALTER TABLE app.orders ADD COLUMN b integer;"
    )
    fired = sorted(f.rule for f in analyse(sql, runner="autocommit").findings)
    assert fired == ["lock_timeout_disabled", "missing_lock_timeout"]
