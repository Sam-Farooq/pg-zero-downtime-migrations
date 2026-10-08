"""Every .sql file in the repository, through PostgreSQL's own grammar.

pglast wraps libpg_query, which is the server's parser compiled as a library,
so this is the real grammar for PostgreSQL 16 rather than a reimplementation of
it. The second half matters more: parse_plpgsql() runs the PL/pgSQL parser over
the function bodies, which the SQL grammar sees only as a string literal.

What it proves: every statement and every function body in sql/ and test/ is
syntactically valid PostgreSQL 16.

What it does not prove: that any of it does the right thing, or that a column
it names exists. That needs a server, and it is what test/pgtap asks for.
This is the gate a runner with no database can hold.

The linter itself has no parser dependency, on purpose. See pgsafe/lexer.py.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from pglast import parse_plpgsql, parse_sql
from pglast.parser import ParseError

SQL_DIRECTORIES = ("sql", "test")


def sql_files() -> list[Path]:
    found: list[Path] = []
    for directory in SQL_DIRECTORIES:
        found.extend(sorted(Path(directory).rglob("*.sql")))
    return found


FILES = sql_files()


def test_the_repository_has_the_sql_it_claims():
    names = {path.as_posix() for path in FILES}
    assert len(FILES) >= 21, names
    assert "sql/lib/01_schema.sql" in names
    assert "test/fixtures.sql" in names
    assert sum(1 for path in FILES if path.name == "safe.sql") == 7
    assert sum(1 for path in FILES if path.name == "unsafe.sql") == 7


@pytest.mark.parametrize("path", FILES, ids=[p.as_posix() for p in FILES])
def test_statements_parse(path: Path):
    try:
        statements = parse_sql(path.read_text())
    except ParseError as problem:
        pytest.fail(f"{path}: {problem}")
    assert statements, f"{path} holds no statement"


PLPGSQL_FILES = [
    path
    for path in FILES
    if "language plpgsql" in path.read_text().lower() or "do $" in path.read_text().lower()
]


@pytest.mark.parametrize("path", PLPGSQL_FILES, ids=[p.as_posix() for p in PLPGSQL_FILES])
def test_plpgsql_bodies_parse(path: Path):
    try:
        parse_plpgsql(path.read_text())
    except ParseError as problem:
        pytest.fail(f"{path}: {problem}")


def test_the_library_is_plpgsql_rather_than_a_pile_of_ddl():
    # Linguist types a .sql file by its content, and a file with no procedural
    # code is typed as SQL, which the language bar does not count at all. The
    # library is the part of this repository that is a program, so each of its
    # files declares a function body.
    library = sorted(Path("sql/lib").glob("*.sql"))
    assert len(library) == 6
    for path in library:
        text = path.read_text().lower()
        assert "language plpgsql" in text or "do $" in text, path


def test_a_deliberately_broken_statement_is_caught():
    # Proof that the gate can fail. Without this, a parser that silently
    # accepted everything would look exactly like a clean repository.
    with pytest.raises(ParseError):
        parse_sql("ALTER TABLE app.orders ALTER COLUM note TYPE text;")


def test_a_deliberately_broken_function_body_is_caught():
    with pytest.raises(ParseError):
        parse_plpgsql("CREATE FUNCTION app.f() RETURNS integer AS $$ BEGIN RETRUN 1 END $$ LANGUAGE plpgsql;")
