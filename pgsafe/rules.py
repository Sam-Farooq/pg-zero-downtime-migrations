"""The rules, and the single pass over a script that applies them.

A rule says what is unsafe, why it is unsafe, and what to write instead. The
third part is the one that matters: a linter that reports a problem without
naming the rewrite gets switched off, and so does one that reports things that
are fine. Every rule below has at least one case in tests/test_allowed.py that
it must not flag.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from . import shapes
from .lexer import Pragma, Script, Statement, lex

ERROR = "error"
WARNING = "warning"


@dataclass(frozen=True)
class Rule:
    id: str
    severity: str
    summary: str
    why: str
    rewrite: str
    lock_form: str | None = None
    pattern: str | None = None


@dataclass(frozen=True)
class Finding:
    rule: str
    severity: str
    line: int
    statement: str
    why: str
    rewrite: str
    pattern: str | None

    def as_dict(self) -> dict[str, object]:
        return {
            "line": self.line,
            "pattern": self.pattern,
            "rewrite": self.rewrite,
            "rule": self.rule,
            "severity": self.severity,
            "statement": self.statement,
            "why": self.why,
        }


@dataclass(frozen=True)
class Allowance:
    rule: str
    line: int
    reason: str


@dataclass(frozen=True)
class Problem:
    """Something wrong with the file's pragmas, rather than with its SQL."""

    line: int
    message: str


@dataclass
class Constraint:
    name: str
    table: str
    column: str | None
    kind: str
    added_tx: int
    validated_tx: int | None = None


@dataclass
class State:
    runner: str
    tx: int = 1
    in_block: bool = False
    created: set[str] = field(default_factory=set)
    timeout_scope: str | None = None
    timeout_tx: int | None = None
    constraints: dict[str, Constraint] = field(default_factory=dict)

    def is_new(self, name: str | None) -> bool:
        if name is None:
            return False
        bare = name.split(".")[-1]
        return name in self.created or bare in self.created

    def remember(self, name: str | None) -> None:
        if name:
            self.created.add(name)
            self.created.add(name.split(".")[-1])

    def timeout_covers_now(self) -> bool:
        if self.timeout_scope == "session":
            return True
        if self.timeout_scope == "local":
            return self.in_block and self.timeout_tx == self.tx
        return False

    def not_null_proved(self, table: str, column: str) -> bool:
        bare = table.split(".")[-1]
        for constraint in self.constraints.values():
            if constraint.kind != "check_not_null" or constraint.column != column:
                continue
            if constraint.table.split(".")[-1] != bare:
                continue
            if constraint.validated_tx is not None and constraint.validated_tx < self.tx:
                return True
        return False


RULES: tuple[Rule, ...] = (
    Rule(
        id="volatile_default",
        severity=ERROR,
        summary="ADD COLUMN with a volatile default rewrites the table",
        why=(
            "a volatile default has to be evaluated once per row, so PostgreSQL fills the "
            "column by rewriting the table while it holds ACCESS EXCLUSIVE, which blocks "
            "reads as well as writes"
        ),
        rewrite=(
            "add the column with no default, SET DEFAULT for new rows, backfill in batches "
            "that commit, then make it NOT NULL. A constant default needs none of this: "
            "since PostgreSQL 11 it is stored in pg_attribute.attmissingval"
        ),
        lock_form="add_column_volatile_default",
        pattern="01_add_column_default",
    ),
    Rule(
        id="identity_column_added",
        severity=ERROR,
        summary="ADD COLUMN ... GENERATED AS IDENTITY rewrites the table",
        why=(
            "an identity column draws its values from a sequence, and nextval() is volatile, "
            "so every existing row is written again under ACCESS EXCLUSIVE"
        ),
        rewrite=(
            "add a plain bigint column, attach the sequence with SET DEFAULT, backfill in "
            "batches, then add the identity property if it is really needed"
        ),
        lock_form="add_identity_column",
        pattern="01_add_column_default",
    ),
    Rule(
        id="unbatched_backfill",
        severity=ERROR,
        summary="UPDATE or DELETE with no WHERE clause",
        why=(
            "one transaction writes every row, holds a row lock on each until it commits, "
            "and leaves one dead tuple per row for autovacuum to find afterwards"
        ),
        rewrite=(
            "walk the primary key in batches that each commit, with the predicate acting as "
            "the progress marker so an interrupted run resumes"
        ),
        lock_form="backfill_batch",
        pattern="01_add_column_default",
    ),
    Rule(
        id="set_not_null_direct",
        severity=ERROR,
        summary="SET NOT NULL scans the table under ACCESS EXCLUSIVE",
        why=(
            "SET NOT NULL has to prove no null is left, and it does that with a full scan "
            "while holding ACCESS EXCLUSIVE, so reads stop for the length of the scan"
        ),
        rewrite=(
            "ADD CONSTRAINT ... CHECK (col IS NOT NULL) NOT VALID, then VALIDATE CONSTRAINT "
            "in a second transaction, then SET NOT NULL, which skips its scan on PostgreSQL "
            "12 and later because the valid CHECK already answers the question"
        ),
        lock_form="set_not_null",
        pattern="02_set_not_null",
    ),
    Rule(
        id="check_without_not_valid",
        severity=ERROR,
        summary="ADD CONSTRAINT CHECK without NOT VALID validates every row under the lock",
        why=(
            "the constraint is checked against every existing row before the lock is "
            "released, so a catalogue change is priced like a sequential scan"
        ),
        rewrite=(
            "add it NOT VALID, then VALIDATE CONSTRAINT in a separate transaction, where the "
            "scan runs under SHARE UPDATE EXCLUSIVE and conflicts with neither reads nor writes"
        ),
        lock_form="add_check_constraint",
        pattern="02_set_not_null",
    ),
    Rule(
        id="validate_in_same_transaction",
        severity=ERROR,
        summary="NOT VALID and VALIDATE CONSTRAINT in one transaction buys nothing",
        why=(
            "the lock taken by ADD CONSTRAINT is held until the transaction commits, so "
            "validating inside it holds that lock across the scan, which is the thing NOT "
            "VALID exists to avoid"
        ),
        rewrite=(
            "put VALIDATE CONSTRAINT in a later migration, or declare the autocommit runner "
            "so that each statement commits on its own"
        ),
        lock_form="validate_constraint",
        pattern="02_set_not_null",
    ),
    Rule(
        id="index_without_concurrently",
        severity=ERROR,
        summary="CREATE INDEX takes SHARE and blocks every write",
        why=(
            "SHARE conflicts with ROW EXCLUSIVE, so every INSERT, UPDATE and DELETE on the "
            "table waits for the whole build"
        ),
        rewrite=(
            "CREATE INDEX CONCURRENTLY, outside any transaction block, then check the result "
            "with pgsafe.assert_index_valid() because a failed build leaves an invalid index "
            "behind that nothing reports"
        ),
        lock_form="create_index",
        pattern="03_create_index",
    ),
    Rule(
        id="drop_index_without_concurrently",
        severity=ERROR,
        summary="DROP INDEX takes ACCESS EXCLUSIVE",
        why="dropping an index blocks reads as well as writes, so undoing a mistake is as blocking as making it",
        rewrite="DROP INDEX CONCURRENTLY, outside any transaction block",
        lock_form="drop_index",
        pattern="03_create_index",
    ),
    Rule(
        id="concurrently_inside_transaction",
        severity=ERROR,
        summary="CONCURRENTLY cannot run inside a transaction block",
        why=(
            "PostgreSQL rejects it outright, so this does not block, it fails. A migration "
            "framework that wraps each file in BEGIN causes this without the file saying BEGIN"
        ),
        rewrite=(
            "give the statement its own migration with the autocommit runner declared, or "
            "tell the framework not to wrap this one"
        ),
        lock_form="create_index_concurrently",
        pattern="03_create_index",
    ),
    Rule(
        id="unique_constraint_builds_index",
        severity=ERROR,
        summary="ADD CONSTRAINT UNIQUE builds its index under ACCESS EXCLUSIVE",
        why=(
            "a unique constraint needs a unique index, and without USING INDEX the "
            "constraint statement builds one while holding a lock that blocks reads"
        ),
        rewrite=(
            "CREATE UNIQUE INDEX CONCURRENTLY first, then ADD CONSTRAINT ... UNIQUE USING "
            "INDEX, which only writes the catalogue"
        ),
        lock_form="add_unique_constraint",
        pattern="03_create_index",
    ),
    Rule(
        id="type_change_needs_a_verdict",
        severity=ERROR,
        summary="ALTER COLUMN TYPE: the old type is not in this file, so the cost is unknown",
        why=(
            "whether this rewrites depends on the type it is coming from, which is in the "
            "database and not in the migration. integer to bigint rewrites every row and "
            "rebuilds every index; varchar(32) to varchar(64) does not. Both look the same here"
        ),
        rewrite=(
            "run SELECT * FROM pgsafe.column_type_change('<table>', '<column>', '<type>') "
            "against a copy, then either keep the statement and record the verdict in a "
            "pgsafe allow pragma, or replace the column the way sql/patterns/04_change_type "
            "does"
        ),
        lock_form="alter_column_type",
        pattern="04_change_type",
    ),
    Rule(
        id="rename_breaks_readers",
        severity=ERROR,
        summary="RENAME breaks every deployed reader at the moment it commits",
        why=(
            "the statement itself is instant. What breaks is the code already running: "
            "during a rolling deploy both versions are live, and no ordering of the rename "
            "and the deploy leaves them both correct"
        ),
        rewrite=(
            "expand, migrate, contract: add the new name, keep the pair equal with "
            "pgsafe.sync_column_pair(), move readers over, and drop the old name a release later"
        ),
        lock_form="rename_column",
        pattern="05_rename_column",
    ),
    Rule(
        id="drop_column_breaks_readers",
        severity=WARNING,
        summary="DROP COLUMN is instant and unrecoverable",
        why=(
            "the lock is held for a catalogue write, so the cost is not the lock: it is that "
            "a reader still naming the column fails, and the data is gone without a restore"
        ),
        rewrite=(
            "drop it in a later migration than the deploy that stopped reading it, and check "
            "pgsafe.column_dependents() first for the views and constraints that name it"
        ),
        lock_form="drop_column",
        pattern="05_rename_column",
    ),
    Rule(
        id="fk_without_not_valid",
        severity=ERROR,
        summary="ADD FOREIGN KEY scans the child and locks both tables",
        why=(
            "PostgreSQL proves every existing row matches, holding SHARE ROW EXCLUSIVE on "
            "the child and the parent, which blocks writes to both for the length of the scan"
        ),
        rewrite=(
            "add it NOT VALID, then VALIDATE CONSTRAINT in a second transaction, where the "
            "child takes SHARE UPDATE EXCLUSIVE and the parent takes ROW SHARE"
        ),
        lock_form="add_foreign_key",
        pattern="06_add_foreign_key",
    ),
    Rule(
        id="missing_lock_timeout",
        severity=ERROR,
        summary="DDL with no lock_timeout waits forever and takes the deploy with it",
        why=(
            "lock_timeout defaults to 0, which means wait without limit. A request for a "
            "strong lock queues behind any open transaction on the table, and because a "
            "later request cannot overtake a waiter, everything that arrives after it queues "
            "behind the migration"
        ),
        rewrite=(
            "SET lock_timeout before the first DDL statement, or SET LOCAL inside the "
            "transaction, and have something retry: pgsafe.run_guarded() does both"
        ),
        lock_form=None,
        pattern="07_lock_timeout",
    ),
    Rule(
        id="lock_timeout_disabled",
        severity=ERROR,
        summary="lock_timeout set to zero is lock_timeout switched off",
        why="zero means wait without limit, which is the default and the thing being guarded against",
        rewrite="set it to a wait the deployment can survive, and retry on SQLSTATE 55P03",
        lock_form=None,
        pattern="07_lock_timeout",
    ),
    Rule(
        id="set_local_outside_transaction",
        severity=WARNING,
        summary="SET LOCAL outside a transaction block applies to nothing",
        why=(
            "PostgreSQL warns and carries on, so the statement after it runs with whatever "
            "the session already had. Under an autocommit runner that is the server default"
        ),
        rewrite="use SET without LOCAL under an autocommit runner, or wrap the pair in BEGIN and COMMIT",
        lock_form=None,
        pattern="07_lock_timeout",
    ),
    Rule(
        id="exclusive_maintenance",
        severity=ERROR,
        summary="VACUUM FULL, CLUSTER and REINDEX rewrite the table with reads blocked",
        why=(
            "each one rebuilds the relation while holding ACCESS EXCLUSIVE, and PostgreSQL "
            "has no online form of VACUUM FULL or CLUSTER"
        ),
        rewrite=(
            "there is no safe rewrite inside PostgreSQL. REINDEX has a CONCURRENTLY form; "
            "for the other two the choices are an announced window or an external table "
            "rewrite tool, and neither belongs in a migration file"
        ),
        lock_form="vacuum_full",
        pattern=None,
    ),
)

RULES_BY_ID: dict[str, Rule] = {rule.id: rule for rule in RULES}


@dataclass
class Analysis:
    path: str
    runner: str
    runner_declared: bool
    statements: int
    findings: list[Finding]
    allowances: list[Allowance]
    problems: list[Problem]
    skipped_new_relations: int

    @property
    def errors(self) -> int:
        return sum(1 for f in self.findings if f.severity == ERROR)

    @property
    def warnings(self) -> int:
        return sum(1 for f in self.findings if f.severity == WARNING)


def transaction_ids(script: Script) -> tuple[list[int], list[bool]]:
    """One transaction number per statement, and whether it is in a BEGIN block.

    Under the autocommit runner each statement is its own transaction unless an
    explicit block is open. Under the transactional runner the whole file is one
    transaction, which is what a framework that wraps migrations in BEGIN does.
    """
    ids: list[int] = []
    blocks: list[bool] = []
    autocommit = script.runner == "autocommit"
    current = 1
    in_block = False
    for statement in script.statements:
        head = statement.words[:1]
        if head and head[0] in ("BEGIN", "START"):
            if not in_block:
                current += 1 if ids else 0
            in_block = True
            ids.append(current)
            blocks.append(True)
            continue
        if head and head[0] in ("COMMIT", "END", "ROLLBACK"):
            ids.append(current)
            blocks.append(in_block)
            in_block = False
            current += 1
            continue
        ids.append(current)
        blocks.append(in_block)
        if autocommit and not in_block:
            current += 1
    return ids, blocks


def _constraint_from_action(stmt: Statement, span: tuple[int, int], table: str, tx: int):
    """An ADD CONSTRAINT action, read far enough to tell the rules apart."""
    words = shapes.action_words(stmt, span)
    if words[:2] != ("ADD", "CONSTRAINT"):
        return None
    first, last = span
    name = None
    cursor = first
    while cursor < last:
        token = stmt.tokens[cursor]
        if token.kind == "word" and token.text.upper() == "CONSTRAINT":
            name, cursor = shapes.read_name(stmt, cursor + 1)
            break
        cursor += 1
    kind = "other"
    column = None
    if "CHECK" in words:
        kind = "check"
        body = shapes.action_words(stmt, span)
        if "IS" in body and "NOT" in body and "NULL" in body:
            check_index = shapes.word_index(stmt, "CHECK", first)
            named, _ = shapes.read_name(stmt, check_index + 2)
            if named is not None:
                kind = "check_not_null"
                column = named
    elif "FOREIGN" in words:
        kind = "foreign_key"
    elif "UNIQUE" in words or ("PRIMARY" in words and "KEY" in words):
        kind = "unique"
    not_valid = _has_not_valid(words)
    return Constraint(
        name=name or "<unnamed>",
        table=table,
        column=column,
        kind=kind,
        added_tx=tx,
    ), kind, not_valid


def _has_not_valid(words: tuple[str, ...]) -> bool:
    return any(words[i] == "NOT" and words[i + 1] == "VALID" for i in range(len(words) - 1))


def _check_statement(stmt: Statement, state: State) -> list[tuple[str, str]]:
    """Every (rule id, extra detail) this statement earns."""
    hits: list[tuple[str, str]] = []
    words = stmt.words
    if not words:
        return hits
    head = words[0]
    depths = shapes.paren_depths(stmt)
    top_level_words = {
        token.text.upper()
        for position, token in enumerate(stmt.tokens)
        if token.kind == "word" and depths[position] == 0
    }

    if "CONCURRENTLY" in top_level_words and (
        state.in_block or state.runner == "transactional"
    ):
        where = (
            "inside an explicit BEGIN block"
            if state.in_block
            else "and this file is read as one transaction, because no runner is declared"
        )
        hits.append(("concurrently_inside_transaction", where))

    alter = shapes.alter_table(stmt)
    if alter is not None and not state.is_new(alter.target):
        for span in alter.actions:
            action = shapes.action_words(stmt, span)
            if not action:
                continue
            if action[:2] == ("ADD", "COLUMN") or (
                action[0] == "ADD" and action[1] not in ("CONSTRAINT",)
            ):
                expression = shapes.default_expression(stmt, span)
                if shapes.is_volatile_default(expression):
                    hits.append(("volatile_default", f"the default is {expression}"))
                if "GENERATED" in action and "IDENTITY" in action:
                    hits.append(("identity_column_added", ""))
            if action[:2] == ("ALTER", "COLUMN"):
                named, _ = shapes.read_name(stmt, span[0] + 2)
                if "NOT" in action and "NULL" in action and "SET" in action:
                    if not state.not_null_proved(alter.target, named or ""):
                        hits.append(
                            (
                                "set_not_null_direct",
                                f"no validated CHECK proves {alter.target}.{named} in an earlier transaction",
                            )
                        )
                if "TYPE" in action:
                    target_type = _type_after(stmt, span)
                    hits.append(
                        (
                            "type_change_needs_a_verdict",
                            f"{alter.target}.{named} to {target_type}",
                        )
                    )
            if action[:2] == ("ADD", "CONSTRAINT"):
                parsed = _constraint_from_action(stmt, span, alter.target, state.tx)
                if parsed is not None:
                    _, kind, not_valid = parsed
                    if kind in ("check", "check_not_null") and not not_valid:
                        hits.append(("check_without_not_valid", ""))
                    if kind == "foreign_key" and not not_valid:
                        hits.append(("fk_without_not_valid", ""))
                    if kind == "unique" and "USING" not in action:
                        hits.append(("unique_constraint_builds_index", ""))
            if action[:2] == ("VALIDATE", "CONSTRAINT"):
                named, _ = shapes.read_name(stmt, span[0] + 2)
                known = state.constraints.get(named or "")
                if known is not None and known.added_tx == state.tx:
                    hits.append(
                        (
                            "validate_in_same_transaction",
                            f"{named} was added in this same transaction",
                        )
                    )
            if action[:2] == ("DROP", "COLUMN"):
                named, _ = shapes.read_name(stmt, span[0] + 2)
                hits.append(("drop_column_breaks_readers", f"{alter.target}.{named}"))
            if action[0] == "RENAME":
                hits.append(("rename_breaks_readers", " ".join(action[:4]).lower()))

    if head == "CREATE" and "INDEX" in words:
        target = shapes.index_target(stmt)
        if not state.is_new(target) and "CONCURRENTLY" not in top_level_words:
            hits.append(("index_without_concurrently", f"on {target}"))

    if head == "DROP" and words[:2] == ("DROP", "INDEX"):
        names = shapes.dropped_indexes(stmt)
        if "CONCURRENTLY" not in top_level_words and not all(
            state.is_new(name) for name in names
        ):
            hits.append(("drop_index_without_concurrently", ", ".join(names)))

    if head == "VACUUM" and "FULL" in words:
        hits.append(("exclusive_maintenance", "VACUUM FULL"))
    if head == "CLUSTER":
        hits.append(("exclusive_maintenance", "CLUSTER"))
    if head == "REINDEX" and "CONCURRENTLY" not in top_level_words:
        hits.append(("exclusive_maintenance", "REINDEX without CONCURRENTLY"))

    if head in ("UPDATE", "DELETE") and "WHERE" not in top_level_words:
        hits.append(("unbatched_backfill", words[0].lower()))

    assignment = shapes.set_statement(stmt)
    if assignment is not None and assignment.parameter == "lock_timeout":
        if _is_zero(assignment.value):
            hits.append(("lock_timeout_disabled", f"lock_timeout = {assignment.value}"))
        if assignment.local and not state.in_block and state.runner == "autocommit":
            hits.append(("set_local_outside_transaction", ""))

    if _takes_ddl_lock(stmt, alter, state) and not state.timeout_covers_now():
        hits.append(("missing_lock_timeout", ""))

    return hits


def _type_after(stmt: Statement, span: tuple[int, int]) -> str:
    position = shapes.word_index(stmt, "TYPE", span[0])
    if position < 0:
        return "?"
    return " ".join(stmt.slice(position + 1, span[1]).split())


def _is_zero(value: str) -> bool:
    stripped = value.strip().strip("'\"").strip().lower()
    return stripped in ("0", "0s", "0ms", "0 s", "0 ms")


def _takes_ddl_lock(stmt: Statement, alter, state: State) -> bool:
    words = stmt.words
    if not words:
        return False
    if alter is not None:
        return not state.is_new(alter.target)
    head = words[0]
    if head == "CREATE" and "INDEX" in words:
        return not state.is_new(shapes.index_target(stmt))
    if words[:2] == ("DROP", "INDEX"):
        return not all(state.is_new(name) for name in shapes.dropped_indexes(stmt))
    if head in ("TRUNCATE", "CLUSTER", "REINDEX"):
        return True
    if head == "VACUUM" and "FULL" in words:
        return True
    return False


def _advance(stmt: Statement, state: State) -> None:
    """Record what this statement changes for the statements after it."""
    words = stmt.words
    if not words:
        return
    created = shapes.created_relation(stmt)
    if created:
        state.remember(created)
    if words[0] == "CREATE" and "INDEX" in words:
        tokens = stmt.tokens
        cursor = 1
        while cursor < len(tokens) and tokens[cursor].kind == "word":
            if tokens[cursor].text.upper() in ("UNIQUE", "INDEX", "CONCURRENTLY", "IF", "NOT", "EXISTS"):
                cursor += 1
                continue
            break
        name, _ = shapes.read_name(stmt, cursor)
        if name and name.upper() != "ON":
            state.remember(name)

    assignment = shapes.set_statement(stmt)
    if assignment is not None and assignment.parameter == "lock_timeout":
        if _is_zero(assignment.value):
            state.timeout_scope = None
            state.timeout_tx = None
        else:
            state.timeout_scope = "local" if assignment.local else "session"
            state.timeout_tx = state.tx

    alter = shapes.alter_table(stmt)
    if alter is None:
        return
    for span in alter.actions:
        action = shapes.action_words(stmt, span)
        if action[:2] == ("ADD", "CONSTRAINT"):
            parsed = _constraint_from_action(stmt, span, alter.target, state.tx)
            if parsed is not None:
                constraint, _kind, _not_valid = parsed
                state.constraints[constraint.name] = constraint
        if action[:2] == ("VALIDATE", "CONSTRAINT"):
            named, _ = shapes.read_name(stmt, span[0] + 2)
            known = state.constraints.get(named or "")
            if known is not None:
                known.validated_tx = state.tx


def _pragma_problems(script: Script) -> list[Problem]:
    problems: list[Problem] = []
    first_offset = script.statements[0].offset if script.statements else 0
    seen: list[Pragma] = [p for s in script.statements for p in s.pragmas]
    for pragma in seen + list(script.trailing_pragmas):
        if pragma.verb not in ("allow", "runner"):
            problems.append(Problem(pragma.line, f"unknown pragma verb: {pragma.verb}"))
            continue
        if pragma.verb == "runner":
            if pragma.argument.lower() not in ("autocommit", "transactional"):
                problems.append(
                    Problem(pragma.line, f"runner must be autocommit or transactional, got {pragma.argument!r}")
                )
            elif pragma.offset > first_offset:
                problems.append(
                    Problem(pragma.line, "a runner pragma after the first statement is ignored")
                )
            continue
        if pragma.argument not in RULES_BY_ID:
            problems.append(Problem(pragma.line, f"allow names no such rule: {pragma.argument!r}"))
        elif len(pragma.reason) < 12:
            problems.append(
                Problem(pragma.line, f"allow {pragma.argument} needs a reason of at least 12 characters")
            )
    for pragma in script.trailing_pragmas:
        if pragma.verb == "allow":
            problems.append(Problem(pragma.line, "allow pragma after the last statement applies to nothing"))
    return problems


def analyse(text: str, path: str = "<text>", runner: str | None = None) -> Analysis:
    """Lex a script and apply every rule to it."""
    script = lex(text, path=path, runner=runner)
    ids, blocks = transaction_ids(script)
    state = State(runner=script.runner)
    findings: list[Finding] = []
    allowances: list[Allowance] = []
    skipped = 0

    for position, statement in enumerate(script.statements):
        state.tx = ids[position]
        state.in_block = blocks[position]
        alter = shapes.alter_table(statement)
        if alter is not None and state.is_new(alter.target):
            skipped += 1
        elif shapes.index_target(statement) and state.is_new(shapes.index_target(statement)):
            skipped += 1
        for rule_id, detail in _check_statement(statement, state):
            rule = RULES_BY_ID[rule_id]
            if rule_id in statement.allowed:
                reason = next(
                    (p.reason for p in statement.pragmas if p.verb == "allow" and p.argument == rule_id),
                    "",
                )
                allowances.append(Allowance(rule=rule_id, line=statement.line, reason=reason))
                continue
            why = rule.why if not detail else f"{rule.why} ({detail})"
            findings.append(
                Finding(
                    rule=rule.id,
                    severity=rule.severity,
                    line=statement.line,
                    statement=statement.excerpt(),
                    why=why,
                    rewrite=rule.rewrite,
                    pattern=rule.pattern,
                )
            )
        _advance(statement, state)

    return Analysis(
        path=path,
        runner=script.runner,
        runner_declared=script.runner_declared,
        statements=len(script.statements),
        findings=findings,
        allowances=allowances,
        problems=_pragma_problems(script),
        skipped_new_relations=skipped,
    )
