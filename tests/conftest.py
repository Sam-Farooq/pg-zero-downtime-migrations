from __future__ import annotations

from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent


@pytest.fixture(scope="session")
def repo() -> Path:
    return REPO_ROOT


@pytest.fixture(scope="session")
def pattern_dirs() -> list[Path]:
    return sorted(p for p in (REPO_ROOT / "sql" / "patterns").iterdir() if p.is_dir())
