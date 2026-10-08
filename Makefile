# Targets that need no database.
.PHONY: test lint check-catalogue install reset pgtap all

all: test lint check-catalogue

test:
	pytest

lint:
	ruff check .
	ruff format --check .

# The catalogue, through the linter. Checking the directory in one go always
# exits 1, because the unsafe halves are in it, so the two halves are checked
# separately: the safe ones have to come out clean, and each unsafe one has to
# be caught by something. This is the same pair of steps CI runs.
check-catalogue:
	pgsafe check sql/patterns/*/safe.sql
	@for file in sql/patterns/*/unsafe.sql; do \
	    if pgsafe check "$$file" > /dev/null; then \
	        echo "$$file passed the linter, which means a rule is missing"; \
	        exit 1; \
	    fi; \
	done
	@echo "every unsafe half was caught"

# Targets that need a PostgreSQL 16 connection in the PG environment variables.
install:
	for file in sql/lib/*.sql; do psql -X -q -v ON_ERROR_STOP=1 -f $$file; done

reset:
	psql -X -q -v ON_ERROR_STOP=1 -c 'DROP SCHEMA IF EXISTS pgsafe CASCADE'

pgtap:
	bash test/run.sh
