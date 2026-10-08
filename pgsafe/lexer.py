"""Split a PostgreSQL script into statements, keeping what was written.

Why a hand written scanner rather than a parser.

A migration linter has to answer questions about the surface of the text: was
CONCURRENTLY written, was NOT VALID written, is this statement inside a BEGIN
block, and what does the comment above it say. A parser answers a different
question, which is what the statement means, and it answers it by normalising
exactly those tokens away. sqlglot and libpg_query both parse the dialect well,
and both hand back a tree in which "the author wrote NOT VALID" and "the author
did not" have to be recovered from flags, assuming that version of the grammar
models the clause at all.

So the rules run on tokens, and this module is the only part that has to be
careful. The genuinely hard part of splitting PostgreSQL is dollar quoting,
because the body of a function or a DO block contains semicolons that do not end
a statement. That, nested block comments, doubled quotes and E'' escapes are
what the 150 lines below are for.

The test suite does use a parser: tests/test_sql_parses.py runs libpg_query, the
server's own grammar, over every .sql file in the repository, including the
bodies of the PL/pgSQL functions. A dev dependency can afford that; a CLI that
has to install in a release pipeline should not need one.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

#: Verbs this module understands in a ``-- pgsafe:`` comment.
PRAGMA_VERBS = ("allow", "runner")

#: How the migration runner treats the file. ``transactional`` is the default
#: because it is the assumption under which more things are errors: a framework
#: that wraps each file in BEGIN makes CONCURRENTLY impossible and collapses the
#: two transaction patterns into one.
RUNNERS = ("autocommit", "transactional")

DEFAULT_RUNNER = "transactional"

MIN_REASON_LENGTH = 12

_PRAGMA_RE = re.compile(r"pgsafe\s*:\s*(?P<verb>[a-z_]+)\s*(?P<rest>.*)$", re.IGNORECASE)
_DOLLAR_TAG_RE = re.compile(r"\$([A-Za-z_][A-Za-z0-9_]*)?\$")
_IDENT_START = re.compile(r"[A-Za-z_\u0080-￿]")
_IDENT_CHAR = re.compile(r"[A-Za-z0-9_$\u0080-￿]")


class LexError(Exception):
    """The text cannot be split: an unterminated quote, comment or dollar tag."""


@dataclass(frozen=True)
class Token:
    kind: str  # word, number, string, quoted_ident, punct
    text: str  # exactly as written
    start: int  # offset into the statement text
    end: int
    line: int

    @property
    def norm(self) -> str:
        """Upper cased for a word, unchanged otherwise."""
        return self.text.upper() if self.kind == "word" else self.text


@dataclass(frozen=True)
class Pragma:
    verb: str
    argument: str
    reason: str
    line: int
    offset: int
    raw: str


@dataclass(frozen=True)
class Comment:
    text: str
    line: int
    offset: int


@dataclass(frozen=True)
class Statement:
    text: str
    line: int
    offset: int
    tokens: tuple[Token, ...]
    comments: tuple[Comment, ...]
    pragmas: tuple[Pragma, ...]

    @property
    def words(self) -> tuple[str, ...]:
        """Upper cased word tokens, in order, with punctuation dropped."""
        return tuple(t.text.upper() for t in self.tokens if t.kind == "word")

    @property
    def allowed(self) -> frozenset[str]:
        return frozenset(p.argument for p in self.pragmas if p.verb == "allow")

    def excerpt(self, limit: int = 110) -> str:
        flat = " ".join(self.text.split())
        return flat if len(flat) <= limit else flat[: limit - 3] + "..."

    def slice(self, first: int, last: int) -> str:
        """The raw text spanned by tokens[first:last], as written."""
        if first >= len(self.tokens) or first >= last:
            return ""
        return self.text[self.tokens[first].start : self.tokens[min(last, len(self.tokens)) - 1].end]


@dataclass(frozen=True)
class Script:
    path: str
    statements: tuple[Statement, ...]
    runner: str
    runner_declared: bool
    trailing_pragmas: tuple[Pragma, ...]


def parse_pragmas(comment: Comment) -> list[Pragma]:
    """Read ``-- pgsafe: verb argument reason`` out of one comment."""
    found: list[Pragma] = []
    body = comment.text
    for raw_line in body.splitlines():
        stripped = raw_line.lstrip("-/* \t").rstrip("*/ \t")
        match = _PRAGMA_RE.search(stripped)
        if not match:
            continue
        rest = match.group("rest").strip()
        argument, _, reason = rest.partition(" ")
        found.append(
            Pragma(
                verb=match.group("verb").lower(),
                argument=argument.strip(),
                reason=reason.strip(),
                line=comment.line,
                offset=comment.offset,
                raw=stripped.strip(),
            )
        )
    return found


def _scan_string(text: str, i: int, quote: str) -> int:
    """Index just past a quoted run, where the quote is doubled to escape it."""
    n = len(text)
    j = i + 1
    while j < n:
        if text[j] == quote:
            if j + 1 < n and text[j + 1] == quote:
                j += 2
                continue
            return j + 1
        if text[j] == "\\" and quote == "'":
            j += 2
            continue
        j += 1
    raise LexError(f"unterminated {quote} at offset {i}")


def _scan_block_comment(text: str, i: int) -> int:
    """Index just past a /* */ comment. PostgreSQL nests them."""
    n = len(text)
    depth = 1
    j = i + 2
    while j < n:
        if text.startswith("/*", j):
            depth += 1
            j += 2
        elif text.startswith("*/", j):
            depth -= 1
            j += 2
            if depth == 0:
                return j
        else:
            j += 1
    raise LexError(f"unterminated block comment at offset {i}")


def _scan_dollar(text: str, i: int) -> tuple[int, str] | None:
    """Index just past a dollar quoted run, and the tag, or None if not one."""
    match = _DOLLAR_TAG_RE.match(text, i)
    if not match:
        return None
    tag = match.group(0)
    close = text.find(tag, match.end())
    if close < 0:
        raise LexError(f"unterminated dollar quoted string {tag} at offset {i}")
    return close + len(tag), tag


def lex(text: str, path: str = "<text>", runner: str | None = None) -> Script:
    """Split a script into statements, with comments and pragmas attached."""
    n = len(text)
    i = 0
    line = 1
    statements: list[Statement] = []
    tokens: list[Token] = []
    comments: list[Comment] = []
    start_offset: int | None = None

    def flush(end: int) -> None:
        nonlocal tokens, comments, start_offset
        if tokens:
            begin = start_offset if start_offset is not None else tokens[0].start
            raw = text[begin:end]
            rebased = tuple(
                Token(t.kind, t.text, t.start - begin, t.end - begin, t.line) for t in tokens
            )
            pragmas = [p for c in comments for p in parse_pragmas(c)]
            statements.append(
                Statement(
                    text=raw.strip(),
                    line=tokens[0].line,
                    offset=begin,
                    tokens=rebased,
                    comments=tuple(comments),
                    pragmas=tuple(pragmas),
                )
            )
            tokens = []
            comments = []
            start_offset = None

    while i < n:
        c = text[i]
        if c in " \t\r\n":
            if c == "\n":
                line += 1
            i += 1
            continue
        if text.startswith("--", i):
            stop = text.find("\n", i)
            stop = n if stop < 0 else stop
            comments.append(Comment(text[i:stop], line, i))
            i = stop
            continue
        if text.startswith("/*", i):
            stop = _scan_block_comment(text, i)
            comments.append(Comment(text[i:stop], line, i))
            line += text.count("\n", i, stop)
            i = stop
            continue
        if c == ";":
            flush(i)
            i += 1
            continue
        if not tokens:
            start_offset = i
        if c == "'":
            stop = _scan_string(text, i, "'")
            tokens.append(Token("string", text[i:stop], i, stop, line))
            line += text.count("\n", i, stop)
            i = stop
            continue
        if c == '"':
            stop = _scan_string(text, i, '"')
            tokens.append(Token("quoted_ident", text[i:stop], i, stop, line))
            i = stop
            continue
        if c == "$":
            dollar = _scan_dollar(text, i)
            if dollar is not None:
                stop, _tag = dollar
                tokens.append(Token("string", text[i:stop], i, stop, line))
                line += text.count("\n", i, stop)
                i = stop
                continue
        if c in "eE" and text[i + 1 : i + 2] == "'":
            stop = _scan_string(text, i + 1, "'")
            tokens.append(Token("string", text[i:stop], i, stop, line))
            i = stop
            continue
        if _IDENT_START.match(c):
            j = i + 1
            while j < n and _IDENT_CHAR.match(text[j]):
                j += 1
            tokens.append(Token("word", text[i:j], i, j, line))
            i = j
            continue
        if c.isdigit():
            j = i + 1
            while j < n and (text[j].isdigit() or text[j] in ".eE+-"):
                if text[j] in "+-" and text[j - 1] not in "eE":
                    break
                j += 1
            tokens.append(Token("number", text[i:j], i, j, line))
            i = j
            continue
        tokens.append(Token("punct", c, i, i + 1, line))
        i += 1

    flush(n)

    first_offset = statements[0].offset if statements else n
    declared = None
    for statement in statements:
        for pragma in statement.pragmas:
            if pragma.verb == "runner" and pragma.offset < first_offset:
                declared = pragma.argument.lower()
    trailing = tuple(p for c in comments for p in parse_pragmas(c))
    for pragma in trailing:
        if pragma.verb == "runner" and not statements:
            declared = pragma.argument.lower()

    chosen = runner or (declared if declared in RUNNERS else DEFAULT_RUNNER)
    return Script(
        path=path,
        statements=tuple(statements),
        runner=chosen,
        runner_declared=declared in RUNNERS,
        trailing_pragmas=trailing,
    )
