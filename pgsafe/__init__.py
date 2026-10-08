"""A linter for PostgreSQL migrations, and the pragma vocabulary it reads.

The SQL in sql/ is the substance of this repository. This package exists so
that a pull request can be told, before it merges, that the statement it adds
takes ACCESS EXCLUSIVE and scans the table.
"""

__version__ = "0.13.0"
