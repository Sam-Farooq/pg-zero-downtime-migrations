"""The two halves have to agree.

The SQL in sql/ and the rules in pgsafe/ encode the same claims about
PostgreSQL. Nothing stops them drifting apart except these tests, which read
both and compare them as text.
"""

from __future__ import annotations

import re
import tomllib
from pathlib import Path

import pytest

import pgsafe
from pgsafe.rules import RULES, analyse

LOCK_MATRIX = Path("sql/lib/02_lock_matrix.sql")


def test_every_pattern_directory_holds_a_runnable_pair(pattern_dirs):
    assert len(pattern_dirs) == 7
    for directory in pattern_dirs:
        assert (directory / "unsafe.sql").is_file(), directory
        assert (directory / "safe.sql").is_file(), directory


def test_every_rule_points_at_a_pattern_that_exists(repo: Path):
    for rule in RULES:
        if rule.pattern is None:
            continue
        assert (repo / "sql" / "patterns" / rule.pattern).is_dir(), rule.id


def test_every_pattern_is_named_by_at_least_one_rule(pattern_dirs):
    named = {rule.pattern for rule in RULES}
    for directory in pattern_dirs:
        assert directory.name in named, f"{directory.name} has no rule"


def test_exactly_one_rule_has_no_safe_form():
    # VACUUM FULL and CLUSTER have no online version inside PostgreSQL, so the
    # rule deliberately names no pattern. If a second rule ever does, it is
    # more likely a missing pattern than a second honest case.
    without = [rule.id for rule in RULES if rule.pattern is None]
    assert without == ["exclusive_maintenance"]


def test_every_lock_form_a_rule_names_is_seeded_in_the_lock_table(repo: Path):
    seed = (repo / LOCK_MATRIX).read_text()
    forms = set(re.findall(r"^    \('([a-z_]+)', '[A-Z ]+'", seed, re.MULTILINE))
    assert len(forms) >= 25
    for rule in RULES:
        if rule.lock_form is None:
            continue
        assert rule.lock_form in forms, f"{rule.id} names {rule.lock_form}, which pgsafe.statement_lock lacks"


def test_every_lock_mode_in_the_table_is_one_of_the_eight(repo: Path):
    seed = (repo / LOCK_MATRIX).read_text()
    modes = set(re.findall(r"^    \('[a-z_]+', '([A-Z ]+)'", seed, re.MULTILINE))
    assert modes <= {
        "ACCESS SHARE",
        "ROW SHARE",
        "ROW EXCLUSIVE",
        "SHARE UPDATE EXCLUSIVE",
        "SHARE",
        "SHARE ROW EXCLUSIVE",
        "EXCLUSIVE",
        "ACCESS EXCLUSIVE",
    }, modes


def test_the_conflict_seed_has_the_twenty_one_pairs_that_make_thirty_eight_rows(repo: Path):
    seed = (repo / LOCK_MATRIX).read_text()
    block = seed.split("INSERT INTO pgsafe.lock_conflict_seed (a, b) VALUES")[1]
    block = block.split("ON CONFLICT")[0]
    pairs = re.findall(r"\('([A-Z ]+)', '([A-Z ]+)'\)", block)
    assert len(pairs) == 21
    directed = {(a, b) for a, b in pairs} | {(b, a) for a, b in pairs}
    assert len(directed) == 38
    assert ("ACCESS SHARE", "ACCESS EXCLUSIVE") in directed
    assert ("ACCESS SHARE", "SHARE") not in directed


def test_the_sql_library_and_the_package_carry_the_same_version(repo: Path):
    schema = (repo / "sql" / "lib" / "01_schema.sql").read_text()
    in_sql = re.search(r"RETURN '([0-9.]+)';", schema)
    assert in_sql is not None
    pyproject = tomllib.loads((repo / "pyproject.toml").read_text())
    assert in_sql.group(1) == pgsafe.__version__ == pyproject["project"]["version"]


def test_the_library_files_are_numbered_without_a_gap(repo: Path):
    files = sorted((repo / "sql" / "lib").glob("*.sql"))
    numbers = [int(path.name.split("_")[0]) for path in files]
    assert numbers == list(range(1, len(files) + 1))


@pytest.mark.parametrize("name", [d.name for d in sorted(Path("sql/patterns").iterdir()) if d.is_dir()])
def test_the_safe_half_of_every_pattern_passes_the_linter(repo: Path, name: str):
    path = repo / "sql" / "patterns" / name / "safe.sql"
    analysis = analyse(path.read_text(), path=str(path))
    assert analysis.findings == [], [(f.rule, f.line) for f in analysis.findings]
    assert analysis.problems == []


@pytest.mark.parametrize("name", [d.name for d in sorted(Path("sql/patterns").iterdir()) if d.is_dir()])
def test_the_unsafe_half_is_caught_by_a_rule_that_names_that_pattern(repo: Path, name: str):
    path = repo / "sql" / "patterns" / name / "unsafe.sql"
    analysis = analyse(path.read_text(), path=str(path))
    assert analysis.findings, f"{name}/unsafe.sql produced no finding"
    assert name in {finding.pattern for finding in analysis.findings}, [
        (f.rule, f.pattern) for f in analysis.findings
    ]


def test_every_pattern_declares_its_runner(pattern_dirs):
    # Both halves are applied through psql by test/run.sh, which is autocommit.
    # A pattern that did not say so would be read as one transaction, and the
    # two transaction sequences are the whole point of the catalogue.
    for directory in pattern_dirs:
        for half in ("safe.sql", "unsafe.sql"):
            text = (directory / half).read_text()
            assert "pgsafe: runner autocommit" in text, f"{directory.name}/{half}"


def test_the_fixture_owns_the_columns_the_patterns_change(repo: Path):
    fixture = (repo / "test" / "fixtures.sql").read_text()
    for column in (
        "shipping_country",
        "reference",
        "legacy_amount",
        "note",
        "status",
        "customer_id",
    ):
        assert column in fixture, column
