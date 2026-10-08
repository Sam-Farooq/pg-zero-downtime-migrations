#!/usr/bin/env bash
#
# Build two throwaway databases, apply the catalogue to both, and run the pgTAP
# suite.
#
#   safe    every sql/patterns/*/safe.sql, in order
#   unsafe  every sql/patterns/*/unsafe.sql, in order
#
# Two databases because the two halves of a pattern reach different end states,
# and because an unsafe statement has to be proved runnable rather than only
# linted. 07_pattern_end_state.sql asserts the safe end state.
#
# Connection comes from the usual PG environment variables (PGHOST, PGPORT,
# PGUSER, PGPASSWORD). The role needs CREATEDB, and CREATE EXTENSION pgtap
# needs superuser because pgTAP is not a trusted extension.
#
#   PGHOST=localhost PGUSER=postgres bash test/run.sh
#
set -euo pipefail

ADMIN_DB=${PGZDM_ADMIN_DB:-postgres}
SAFE_DB=${PGZDM_SAFE_DB:-pgzdm_safe}
UNSAFE_DB=${PGZDM_UNSAFE_DB:-pgzdm_unsafe}

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$here"

failures=0
assertions=0

admin() {
    psql -X -q -v ON_ERROR_STOP=1 -d "$ADMIN_DB" -c "$1"
}

apply() {
    psql -X -q -v ON_ERROR_STOP=1 -d "$1" -f "$2" >/dev/null
}

build() {
    local db=$1
    echo "# building $db"
    admin "DROP DATABASE IF EXISTS $db"
    admin "CREATE DATABASE $db"
    psql -X -q -v ON_ERROR_STOP=1 -d "$db" -c "CREATE EXTENSION IF NOT EXISTS pgtap" >/dev/null
    for file in sql/lib/*.sql; do
        apply "$db" "$file"
    done
    apply "$db" test/fixtures.sql
}

tap() {
    local db=$1 file=$2 output
    echo "# $file"
    # -t -A so the output is bare TAP rather than a formatted table.
    output=$(psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$db" -f "$file")
    printf '%s\n' "$output"
    if printf '%s\n' "$output" | grep -q '^not ok'; then
        failures=$((failures + 1))
    fi
    # pgTAP reports a plan mismatch as a comment rather than as a failed test,
    # which would otherwise pass silently.
    if printf '%s\n' "$output" | grep -q '^# Looks like'; then
        failures=$((failures + 1))
    fi
    assertions=$((assertions + $(printf '%s\n' "$output" | grep -c '^\(not \)\?ok ' || true)))
}

build "$SAFE_DB"
build "$UNSAFE_DB"

# Every file but the end state one, which has to wait for the catalogue.
for file in $(ls test/pgtap/*.sql | sort); do
    case "$file" in
        *90_pattern_end_state.sql) continue ;;
    esac
    tap "$SAFE_DB" "$file"
done

echo "# applying the catalogue"
for directory in sql/patterns/*/; do
    echo "#   $(basename "$directory") safe"
    apply "$SAFE_DB" "$directory/safe.sql"
    echo "#   $(basename "$directory") unsafe"
    apply "$UNSAFE_DB" "$directory/unsafe.sql"
done

tap "$SAFE_DB" test/pgtap/90_pattern_end_state.sql

echo "# $assertions assertions, $failures file(s) with a failure"
if [ "$failures" -gt 0 ]; then
    exit 1
fi
