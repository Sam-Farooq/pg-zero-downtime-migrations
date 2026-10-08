"""Rendering an analysis, for a person in a terminal and for a build."""

from __future__ import annotations

import json
import textwrap

from .rules import RULES, Analysis, Rule

_INDENT = " " * 9


def _wrap(text: str, width: int = 86) -> str:
    return textwrap.fill(text, width=width, initial_indent=_INDENT, subsequent_indent=_INDENT)


def render_text(analyses: list[Analysis]) -> str:
    lines: list[str] = []
    for analysis in analyses:
        declared = "declared" if analysis.runner_declared else "assumed"
        lines.append(
            f"{analysis.path}: {analysis.statements} statements, runner {analysis.runner} ({declared})"
        )
        for problem in analysis.problems:
            lines.append(f"  pragma  line {problem.line}  {problem.message}")
        for finding in analysis.findings:
            lines.append("")
            lines.append(f"  {finding.severity:<7} line {finding.line}  {finding.rule}")
            lines.append(f"{_INDENT}{finding.statement}")
            lines.append(_wrap(f"why  {finding.why}"))
            lines.append(_wrap(f"fix  {finding.rewrite}"))
            if finding.pattern:
                lines.append(f"{_INDENT}see  sql/patterns/{finding.pattern}/safe.sql")
        for allowance in analysis.allowances:
            lines.append(f"  allowed line {allowance.line}  {allowance.rule}: {allowance.reason}")
        lines.append("")
    total_errors = sum(a.errors for a in analyses)
    total_warnings = sum(a.warnings for a in analyses)
    total_allowed = sum(len(a.allowances) for a in analyses)
    skipped = sum(a.skipped_new_relations for a in analyses)
    lines.append(
        f"{len(analyses)} file(s), {total_errors} error(s), {total_warnings} warning(s), "
        f"{total_allowed} allowed, {skipped} statement(s) skipped on tables created in the same file"
    )
    return "\n".join(lines)


def render_json(analyses: list[Analysis]) -> str:
    payload = {
        "files": [
            {
                "allowances": [
                    {"line": a.line, "reason": a.reason, "rule": a.rule} for a in analysis.allowances
                ],
                "errors": analysis.errors,
                "findings": [finding.as_dict() for finding in analysis.findings],
                "path": analysis.path,
                "problems": [{"line": p.line, "message": p.message} for p in analysis.problems],
                "runner": analysis.runner,
                "runner_declared": analysis.runner_declared,
                "skipped_new_relations": analysis.skipped_new_relations,
                "statements": analysis.statements,
                "warnings": analysis.warnings,
            }
            for analysis in analyses
        ],
        "totals": {
            "errors": sum(a.errors for a in analyses),
            "files": len(analyses),
            "warnings": sum(a.warnings for a in analyses),
        },
    }
    return json.dumps(payload, indent=2, sort_keys=True)


def render_rules_text(rules: tuple[Rule, ...] = RULES) -> str:
    width = max(len(rule.id) for rule in rules)
    lines = [f"{len(rules)} rules", ""]
    for rule in sorted(rules, key=lambda r: (r.pattern or "zz", r.id)):
        pattern = rule.pattern or "(no safe form)"
        lines.append(f"  {rule.id:<{width}}  {rule.severity:<7}  {pattern}")
        lines.append(f"  {'':<{width}}  {rule.summary}")
    return "\n".join(lines)


def render_rules_json(rules: tuple[Rule, ...] = RULES) -> str:
    return json.dumps(
        [
            {
                "id": rule.id,
                "lock_form": rule.lock_form,
                "pattern": rule.pattern,
                "rewrite": rule.rewrite,
                "severity": rule.severity,
                "summary": rule.summary,
                "why": rule.why,
            }
            for rule in sorted(rules, key=lambda r: r.id)
        ],
        indent=2,
        sort_keys=True,
    )


def render_explain(rule: Rule) -> str:
    lines = [
        f"{rule.id}  [{rule.severity}]",
        "",
        textwrap.fill(rule.summary, width=86),
        "",
        "why",
        textwrap.fill(rule.why, width=86, initial_indent="  ", subsequent_indent="  "),
        "",
        "instead",
        textwrap.fill(rule.rewrite, width=86, initial_indent="  ", subsequent_indent="  "),
    ]
    if rule.lock_form:
        lines += [
            "",
            "lock",
            f"  SELECT * FROM pgsafe.statement_impact WHERE form = '{rule.lock_form}';",
        ]
    if rule.pattern:
        lines += [
            "",
            "pattern",
            f"  sql/patterns/{rule.pattern}/unsafe.sql",
            f"  sql/patterns/{rule.pattern}/safe.sql",
        ]
    return "\n".join(lines)
