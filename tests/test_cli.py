"""The command, and the exit codes a build acts on."""

from __future__ import annotations

import json

import pytest

from pgsafe.cli import main

SAFE = (
    "-- pgsafe: runner autocommit\nSET lock_timeout = '3s';\nALTER TABLE app.orders ADD COLUMN c integer;\n"
)
UNSAFE = "-- pgsafe: runner autocommit\nALTER TABLE app.orders ALTER COLUMN note SET NOT NULL;\n"
WARNING_ONLY = (
    "-- pgsafe: runner autocommit\nSET lock_timeout = '3s';\nALTER TABLE app.orders DROP COLUMN note;\n"
)


def write(tmp_path, name, text):
    path = tmp_path / name
    path.write_text(text)
    return str(path)


def test_a_clean_file_exits_zero(tmp_path, capsys):
    assert main(["check", write(tmp_path, "0001_ok.sql", SAFE)]) == 0
    assert "0 error(s)" in capsys.readouterr().out


def test_an_unsafe_file_exits_one(tmp_path, capsys):
    assert main(["check", write(tmp_path, "0002_bad.sql", UNSAFE)]) == 1
    out = capsys.readouterr().out
    assert "set_not_null_direct" in out
    assert "sql/patterns/02_set_not_null/safe.sql" in out


def test_a_warning_alone_exits_zero_until_asked(tmp_path, capsys):
    path = write(tmp_path, "0003_warn.sql", WARNING_ONLY)
    assert main(["check", path]) == 0
    capsys.readouterr()
    assert main(["check", path, "--warn-as-error"]) == 1


def test_a_missing_path_is_refused_with_two(tmp_path, capsys):
    assert main(["check", str(tmp_path / "nothing.sql")]) == 2
    assert "no such file" in capsys.readouterr().err


def test_a_file_that_cannot_be_split_is_refused_with_two(tmp_path, capsys):
    path = write(tmp_path, "0004_open.sql", "DO $body$ SELECT 1;\n")
    assert main(["check", path]) == 2
    assert "cannot split" in capsys.readouterr().err


def test_an_empty_directory_is_refused_rather_than_passed(tmp_path, capsys):
    (tmp_path / "empty").mkdir()
    assert main(["check", str(tmp_path / "empty")]) == 2
    assert "nothing to check" in capsys.readouterr().err


def test_a_pragma_problem_fails_the_run_on_its_own(tmp_path, capsys):
    path = write(
        tmp_path,
        "0005_pragma.sql",
        "-- pgsafe: runner autocommit\n-- pgsafe: allow nonsense_rule a reason long enough\nSELECT 1;\n",
    )
    assert main(["check", path]) == 1
    assert "allow names no such rule" in capsys.readouterr().out


def test_a_directory_is_walked(capsys):
    assert main(["check", "sql/patterns"]) == 1
    out = capsys.readouterr().out
    assert "14 file(s)" in out


def test_json_output_is_sorted_and_parseable(tmp_path, capsys):
    path = write(tmp_path, "0006_json.sql", UNSAFE)
    assert main(["check", path, "--format", "json"]) == 1
    payload = json.loads(capsys.readouterr().out)
    assert payload["totals"]["errors"] == 2
    finding = payload["files"][0]["findings"][0]
    assert list(finding) == sorted(finding)
    assert finding["rule"] == "set_not_null_direct"


def test_the_runner_can_be_forced_from_the_command_line(tmp_path, capsys):
    path = write(
        tmp_path,
        "0007_cic.sql",
        "-- pgsafe: runner autocommit\nSET lock_timeout = '3s';\n"
        "CREATE INDEX CONCURRENTLY i ON app.orders (customer_id);\n",
    )
    assert main(["check", path]) == 0
    capsys.readouterr()
    assert main(["check", path, "--runner", "transactional"]) == 1
    assert "concurrently_inside_transaction" in capsys.readouterr().out


def test_rules_prints_every_rule(capsys):
    assert main(["rules"]) == 0
    out = capsys.readouterr().out
    assert "18 rules" in out
    assert "volatile_default" in out


def test_rules_as_json_is_the_same_set(capsys):
    assert main(["rules", "--format", "json"]) == 0
    payload = json.loads(capsys.readouterr().out)
    assert len(payload) == 18
    assert {entry["severity"] for entry in payload} == {"error", "warning"}


def test_explain_names_the_pattern_and_the_lock_form(capsys):
    assert main(["explain", "index_without_concurrently"]) == 0
    out = capsys.readouterr().out
    assert "sql/patterns/03_create_index/safe.sql" in out
    assert "pgsafe.statement_impact WHERE form = 'create_index'" in out


def test_explain_refuses_an_unknown_rule(capsys):
    assert main(["explain", "no_such_rule"]) == 2
    assert "known rules:" in capsys.readouterr().err


def test_no_command_is_a_usage_error(capsys):
    with pytest.raises(SystemExit) as raised:
        main([])
    assert raised.value.code == 2
