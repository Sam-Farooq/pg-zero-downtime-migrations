"""Reading the shape of a statement off its tokens.

Everything here is deliberately shallow. It recognises the forms the rules have
something to say about and returns None for the rest, which is the honest
failure mode for a text matcher: a statement it does not recognise produces no
finding rather than a guess.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from .lexer import Statement, Token

_NAME_KINDS = ("word", "quoted_ident")

#: Volatile functions commonly reached for in a column default. The SQL side
#: asks pg_proc instead (pgsafe.expression_is_volatile), which is both wider and
#: only available with a connection. This list is what a text matcher can know.
VOLATILE_FUNCTIONS = frozenset(
    {
        "random",
        "gen_random_uuid",
        "uuid_generate_v1",
        "uuid_generate_v1mc",
        "uuid_generate_v4",
        "clock_timestamp",
        "timeofday",
        "nextval",
        "currval",
        "setval",
        "pg_sleep",
    }
)

#: Column constraints that can follow a DEFAULT clause, so the expression stops.
_COLUMN_CONSTRAINT_WORDS = frozenset(
    {
        "NOT",
        "NULL",
        "UNIQUE",
        "PRIMARY",
        "REFERENCES",
        "CHECK",
        "COLLATE",
        "CONSTRAINT",
        "GENERATED",
        "DEFERRABLE",
    }
)


@dataclass(frozen=True)
class AlterTable:
    """An ALTER TABLE statement split into its target and its actions."""

    target: str
    actions: tuple[tuple[int, int], ...]  # token index ranges, end exclusive


def is_name(token: Token) -> bool:
    return token.kind in _NAME_KINDS


def normalise_name(token: Token) -> str:
    if token.kind == "quoted_ident":
        return token.text[1:-1].replace('""', '"')
    return token.text.lower()


def read_name(stmt: Statement, index: int) -> tuple[str | None, int]:
    """Read a possibly qualified identifier starting at index."""
    tokens = stmt.tokens
    if index >= len(tokens) or not is_name(tokens[index]):
        return None, index
    parts = [normalise_name(tokens[index])]
    cursor = index + 1
    while (
        cursor + 1 < len(tokens)
        and tokens[cursor].kind == "punct"
        and tokens[cursor].text == "."
        and is_name(tokens[cursor + 1])
    ):
        parts.append(normalise_name(tokens[cursor + 1]))
        cursor += 2
    return ".".join(parts), cursor


def starts_with(stmt: Statement, *words: str) -> bool:
    return stmt.words[: len(words)] == tuple(w.upper() for w in words)


def has_word(stmt: Statement, word: str) -> bool:
    return word.upper() in stmt.words


def word_index(stmt: Statement, word: str, start: int = 0) -> int:
    target = word.upper()
    for position in range(start, len(stmt.tokens)):
        token = stmt.tokens[position]
        if token.kind == "word" and token.text.upper() == target:
            return position
    return -1


def paren_depths(stmt: Statement) -> list[int]:
    """Depth before each token, so a match can be restricted to the top level."""
    depths: list[int] = []
    depth = 0
    for token in stmt.tokens:
        depths.append(depth)
        if token.kind == "punct":
            if token.text == "(":
                depth += 1
            elif token.text == ")":
                depth -= 1
    return depths


def alter_table(stmt: Statement) -> AlterTable | None:
    """Parse ALTER TABLE [IF EXISTS] [ONLY] name action [, action ...]."""
    if not starts_with(stmt, "ALTER", "TABLE"):
        return None
    tokens = stmt.tokens
    cursor = 2
    while cursor < len(tokens) and tokens[cursor].kind == "word":
        upper = tokens[cursor].text.upper()
        if upper in ("IF", "EXISTS", "ONLY"):
            cursor += 1
            continue
        break
    target, cursor = read_name(stmt, cursor)
    if target is None:
        return None
    if cursor < len(tokens) and tokens[cursor].kind == "punct" and tokens[cursor].text == "*":
        cursor += 1

    depths = paren_depths(stmt)
    actions: list[tuple[int, int]] = []
    action_start = cursor
    for position in range(cursor, len(tokens)):
        token = tokens[position]
        if token.kind == "punct" and token.text == "," and depths[position] == 0:
            actions.append((action_start, position))
            action_start = position + 1
    if action_start < len(tokens):
        actions.append((action_start, len(tokens)))
    return AlterTable(target=target, actions=tuple(actions))


def action_words(stmt: Statement, span: tuple[int, int]) -> tuple[str, ...]:
    first, last = span
    return tuple(
        token.text.upper() for token in stmt.tokens[first:last] if token.kind == "word"
    )


def action_is(stmt: Statement, span: tuple[int, int], *words: str) -> bool:
    return action_words(stmt, span)[: len(words)] == tuple(w.upper() for w in words)


def created_relation(stmt: Statement) -> str | None:
    """The table a CREATE TABLE statement makes, if this is one."""
    if not starts_with(stmt, "CREATE"):
        return None
    tokens = stmt.tokens
    cursor = 1
    skippable = {"GLOBAL", "LOCAL", "TEMP", "TEMPORARY", "UNLOGGED"}
    while cursor < len(tokens) and tokens[cursor].kind == "word":
        if tokens[cursor].text.upper() in skippable:
            cursor += 1
            continue
        break
    if cursor >= len(tokens) or tokens[cursor].text.upper() != "TABLE":
        return None
    cursor += 1
    while cursor < len(tokens) and tokens[cursor].kind == "word":
        if tokens[cursor].text.upper() in ("IF", "NOT", "EXISTS"):
            cursor += 1
            continue
        break
    name, _ = read_name(stmt, cursor)
    return name


def index_target(stmt: Statement) -> str | None:
    """The table a CREATE INDEX statement indexes."""
    if not starts_with(stmt, "CREATE"):
        return None
    if not has_word(stmt, "INDEX"):
        return None
    on_position = word_index(stmt, "ON")
    if on_position < 0:
        return None
    cursor = on_position + 1
    if cursor < len(stmt.tokens) and stmt.tokens[cursor].text.upper() == "ONLY":
        cursor += 1
    name, _ = read_name(stmt, cursor)
    return name


def dropped_indexes(stmt: Statement) -> list[str]:
    """The index names a DROP INDEX statement removes."""
    if not starts_with(stmt, "DROP", "INDEX"):
        return []
    tokens = stmt.tokens
    cursor = 2
    while cursor < len(tokens) and tokens[cursor].kind == "word":
        if tokens[cursor].text.upper() in ("CONCURRENTLY", "IF", "EXISTS"):
            cursor += 1
            continue
        break
    names: list[str] = []
    while cursor < len(tokens):
        name, cursor = read_name(stmt, cursor)
        if name is None:
            break
        names.append(name)
        if cursor < len(tokens) and tokens[cursor].text == ",":
            cursor += 1
            continue
        break
    return names


@dataclass(frozen=True)
class SetStatement:
    parameter: str
    value: str
    local: bool


def set_statement(stmt: Statement) -> SetStatement | None:
    """Parse SET [SESSION|LOCAL] parameter {=|TO} value."""
    if not starts_with(stmt, "SET"):
        return None
    tokens = stmt.tokens
    cursor = 1
    local = False
    while cursor < len(tokens) and tokens[cursor].kind == "word":
        upper = tokens[cursor].text.upper()
        if upper == "LOCAL":
            local = True
            cursor += 1
            continue
        if upper == "SESSION":
            cursor += 1
            continue
        break
    parameter, cursor = read_name(stmt, cursor)
    if parameter is None:
        return None
    if cursor < len(tokens) and tokens[cursor].norm in ("=", "TO"):
        cursor += 1
    value = " ".join(token.text for token in tokens[cursor:]).strip()
    return SetStatement(parameter=parameter, value=value, local=local)


def default_expression(stmt: Statement, span: tuple[int, int]) -> str | None:
    """The raw text of a DEFAULT clause inside one ALTER TABLE action."""
    first, last = span
    depths = paren_depths(stmt)
    for position in range(first, last):
        token = stmt.tokens[position]
        if token.kind == "word" and token.text.upper() == "DEFAULT" and depths[position] == 0:
            stop = last
            for later in range(position + 1, last):
                following = stmt.tokens[later]
                if (
                    following.kind == "word"
                    and following.text.upper() in _COLUMN_CONSTRAINT_WORDS
                    and depths[later] == 0
                ):
                    stop = later
                    break
            return stmt.slice(position + 1, stop).strip()
    return None


def called_functions(expression: str) -> set[str]:
    """Lower cased names that are followed by an open parenthesis."""
    return {match.lower() for match in re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*\(", expression)}


def is_volatile_default(expression: str | None) -> bool:
    if not expression:
        return False
    return bool(called_functions(expression) & VOLATILE_FUNCTIONS)
