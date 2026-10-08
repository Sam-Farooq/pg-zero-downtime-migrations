"""The scanner. Everything here is about text the rules must not misread."""

from __future__ import annotations

import pytest

from pgsafe.lexer import LexError, lex


def rules_of(text: str, runner: str | None = None):
    from pgsafe.rules import analyse

    return sorted({f.rule for f in analyse(text, runner=runner).findings})


def test_splits_on_semicolons_and_keeps_line_numbers():
    script = lex("SELECT 1;\n\nSELECT 2;\nSELECT 3;\n")
    assert [s.line for s in script.statements] == [1, 3, 4]
    assert script.statements[0].text == "SELECT 1"


def test_a_dollar_quoted_body_is_one_statement():
    text = """
DO $batch$
DECLARE moved integer;
BEGIN
    UPDATE app.orders SET note = 'x';
    COMMIT;
END
$batch$;
SELECT 1;
"""
    script = lex(text)
    assert len(script.statements) == 2
    assert script.statements[0].words[:2] == ("DO",) or script.statements[0].words[0] == "DO"


def test_an_unsafe_statement_inside_a_dollar_quoted_string_is_not_a_statement():
    # This is the shape of sql/patterns/07_lock_timeout/safe.sql: the DDL is an
    # argument, and a scanner that missed the dollar tag would lint it.
    text = (
        "SET lock_timeout = '3s';\n"
        "SELECT * FROM pgsafe.run_guarded(\n"
        "    $stmt$ALTER TABLE app.orders RENAME COLUMN a TO b$stmt$\n"
        ");\n"
    )
    script = lex(text)
    assert len(script.statements) == 2
    assert rules_of(text, runner="autocommit") == []


def test_tags_must_match_to_close():
    text = "DO $a$ SELECT $b$ inner $b$; $a$;"
    script = lex(text)
    assert len(script.statements) == 1


def test_block_comments_nest():
    text = "/* outer /* inner */ still a comment */ SELECT 1;"
    script = lex(text)
    assert len(script.statements) == 1
    assert script.statements[0].text == "SELECT 1"


def test_keywords_inside_a_string_literal_are_not_keywords():
    text = (
        "SET lock_timeout = '3s';\n"
        "INSERT INTO audit (what)\n"
        "VALUES ('ALTER TABLE t ALTER COLUMN c SET NOT NULL');"
    )
    assert rules_of(text, runner="autocommit") == []


def test_keywords_inside_a_comment_are_not_statements():
    text = """
SET lock_timeout = '3s';
-- ALTER TABLE app.orders RENAME COLUMN note TO customer_note;
/* CREATE INDEX i ON app.orders (customer_id); */
SELECT 1;
"""
    script = lex(text)
    assert len(script.statements) == 2
    assert rules_of(text, runner="autocommit") == []


def test_doubled_quotes_do_not_end_a_string():
    script = lex("SELECT 'it''s fine; really';")
    assert len(script.statements) == 1


def test_quoted_identifiers_keep_their_case_and_lose_their_quotes():
    from pgsafe import shapes

    script = lex('ALTER TABLE "App"."Orders" ADD COLUMN c integer;')
    alter = shapes.alter_table(script.statements[0])
    assert alter is not None
    assert alter.target == "App.Orders"


def test_unterminated_string_is_refused():
    with pytest.raises(LexError):
        lex("SELECT 'open")


def test_unterminated_dollar_quote_is_refused():
    with pytest.raises(LexError):
        lex("DO $body$ SELECT 1;")


def test_unterminated_block_comment_is_refused():
    with pytest.raises(LexError):
        lex("/* forever SELECT 1;")


def test_runner_pragma_is_read_from_the_preamble():
    script = lex("-- pgsafe: runner autocommit\nSELECT 1;")
    assert script.runner == "autocommit"
    assert script.runner_declared is True


def test_runner_defaults_to_transactional_when_nothing_says():
    script = lex("SELECT 1;")
    assert script.runner == "transactional"
    assert script.runner_declared is False


def test_an_explicit_runner_argument_beats_the_pragma():
    script = lex("-- pgsafe: runner autocommit\nSELECT 1;", runner="transactional")
    assert script.runner == "transactional"


def test_allow_pragma_attaches_to_the_statement_below_it():
    text = """
SET lock_timeout = '3s';
-- pgsafe: allow drop_column_breaks_readers nothing reads it any more
ALTER TABLE app.orders DROP COLUMN note;
ALTER TABLE app.orders DROP COLUMN memo;
"""
    script = lex(text, runner="autocommit")
    assert script.statements[1].allowed == frozenset({"drop_column_breaks_readers"})
    assert script.statements[2].allowed == frozenset()
