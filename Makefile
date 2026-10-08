# Targets that need no database.
.PHONY: test lint check-catalogue install reset pgtap all

all: test lint check-catalogue

test:
	pytest

lint:
	ruff check .
	ruff format --check .

# The catalogue, through the linter: every safe.sql has to come out clean and
# every unsafe.sql has to be caught. The exit code is 1 by design, because the
# unsafe halves are in there, so this target reports rather than gates. The
# gate is tests/test_catalogue.py, which asserts both halves separately.
check-catalogue:
	-pgsafe check sql/patterns

# Targets that need a PostgreSQL 16 connection in the PG environment variables.
install:
	for file in sql/lib/*.sql; do psql -X -q -v ON_ERROR_STOP=1 -f $$file; done

reset:
	psql -X -q -v ON_ERROR_STOP=1 -c 'DROP SCHEMA IF EXISTS pgsafe CASCADE'

pgtap:
	bash test/run.sh
