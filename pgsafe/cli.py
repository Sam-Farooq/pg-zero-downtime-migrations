"""The pgsafe command.

Exit codes, because this is only useful if a build can act on it:

    0  nothing to report
    1  at least one finding that counts, which is an error, or a warning when
       --warn-as-error was given
    2  refused: a file that cannot be read or cannot be split into statements,
       or an argument that names nothing

2 is not 1 on purpose. A build that treats a refusal as a pass has no gate at
all, because an unreadable migration would read as nothing to report.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from . import __version__
from .lexer import LexError
from .report import (
    render_explain,
    render_json,
    render_rules_json,
    render_rules_text,
    render_text,
)
from .rules import RULES, RULES_BY_ID, analyse

REFUSED = 2


def _collect(paths: list[str]) -> list[Path]:
    found: list[Path] = []
    for raw in paths:
        path = Path(raw)
        if path.is_dir():
            found.extend(sorted(path.rglob("*.sql")))
        elif path.exists():
            found.append(path)
        else:
            raise FileNotFoundError(raw)
    return found


def _check(args: argparse.Namespace) -> int:
    try:
        files = _collect(args.paths)
    except FileNotFoundError as missing:
        print(f"pgsafe: no such file or directory: {missing}", file=sys.stderr)
        return REFUSED
    if not files:
        print("pgsafe: nothing to check", file=sys.stderr)
        return REFUSED

    runner = None if args.runner == "auto" else args.runner
    analyses = []
    for path in files:
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as problem:
            print(f"pgsafe: cannot read {path}: {problem}", file=sys.stderr)
            return REFUSED
        try:
            analyses.append(analyse(text, path=str(path), runner=runner))
        except LexError as problem:
            print(f"pgsafe: cannot split {path}: {problem}", file=sys.stderr)
            return REFUSED

    output = render_json(analyses) if args.format == "json" else render_text(analyses)
    print(output)

    errors = sum(a.errors for a in analyses)
    warnings = sum(a.warnings for a in analyses)
    problems = sum(len(a.problems) for a in analyses)
    if errors or problems or (args.warn_as_error and warnings):
        return 1
    return 0


def _rules(args: argparse.Namespace) -> int:
    print(render_rules_json() if args.format == "json" else render_rules_text())
    return 0


def _explain(args: argparse.Namespace) -> int:
    rule = RULES_BY_ID.get(args.rule)
    if rule is None:
        known = ", ".join(sorted(RULES_BY_ID))
        print(f"pgsafe: no rule called {args.rule!r}\nknown rules: {known}", file=sys.stderr)
        return REFUSED
    print(render_explain(rule))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pgsafe",
        description="Lint PostgreSQL migrations for the forms that lock a live table.",
    )
    parser.add_argument("--version", action="version", version=f"pgsafe {__version__}")
    subcommands = parser.add_subparsers(dest="command", required=True)

    check = subcommands.add_parser("check", help="lint migration files")
    check.add_argument("paths", nargs="+", help="files or directories")
    check.add_argument(
        "--runner",
        choices=("auto", "autocommit", "transactional"),
        default="auto",
        help="how the migration runner treats a file (default: auto, which reads the pragma)",
    )
    check.add_argument("--format", choices=("text", "json"), default="text")
    check.add_argument("--warn-as-error", action="store_true", help="exit 1 on warnings too")
    check.set_defaults(handler=_check)

    rules = subcommands.add_parser("rules", help=f"print all {len(RULES)} rules")
    rules.add_argument("--format", choices=("text", "json"), default="text")
    rules.set_defaults(handler=_rules)

    explain = subcommands.add_parser("explain", help="one rule in full")
    explain.add_argument("rule")
    explain.set_defaults(handler=_explain)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.handler(args)


if __name__ == "__main__":
    raise SystemExit(main())
