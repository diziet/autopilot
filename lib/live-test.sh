#!/usr/bin/env bash
# Live test scaffolding for Autopilot.
# Creates a minimal Python project that autopilot can run against
# to validate the full pipeline end-to-end.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_LIVE_TEST_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_LIVE_TEST_LOADED=1

# GitHub org for --github mode (not a config var).
readonly LIVE_TEST_GITHUB_ORG="diziet"

# Creates a minimal Python math library project in the given directory.
scaffold_test_repo() {
  local target_dir="$1"

  if [[ -z "$target_dir" ]]; then
    echo "scaffold_test_repo: target directory required" >&2
    return 1
  fi

  mkdir -p "$target_dir/src" "$target_dir/tests"

  _write_mathlib "$target_dir"
  _write_test_mathlib "$target_dir"
  _write_requirements "$target_dir"
  _write_gitignore "$target_dir"
  _write_claude_md "$target_dir"
  _write_readme "$target_dir"
}

# Writes src/mathlib.py — small math utility with intentional gaps.
_write_mathlib() {
  local dir="$1"
  cat > "$dir/src/mathlib.py" << 'PYEOF'
"""Simple math utility library."""


def add(a, b):
    """Return the sum of a and b."""
    return a + b


def subtract(a, b):
    """Return the difference of a and b."""
    return a - b
PYEOF
}

# Writes tests/test_mathlib.py — tests for existing functions only.
_write_test_mathlib() {
  local dir="$1"
  cat > "$dir/tests/test_mathlib.py" << 'PYEOF'
"""Tests for mathlib."""

from src.mathlib import add


def test_add_positive():
    assert add(2, 3) == 5


def test_add_negative():
    assert add(-1, -2) == -3


def test_add_zero():
    assert add(0, 5) == 5
PYEOF
}

# Writes requirements.txt.
_write_requirements() {
  local dir="$1"
  echo "pytest" > "$dir/requirements.txt"
}

# Writes .gitignore for Python projects.
_write_gitignore() {
  local dir="$1"
  cat > "$dir/.gitignore" << 'EOF'
__pycache__/
*.pyc
*.pyo
.pytest_cache/
*.egg-info/
dist/
build/
.venv/
venv/
.env
EOF
}

# Writes CLAUDE.md — minimal agent instructions.
_write_claude_md() {
  local dir="$1"
  cat > "$dir/CLAUDE.md" << 'EOF'
# Math Library

Pure Python math utility library. No frameworks, no dependencies beyond pytest.

## Rules

- Language: Python 3
- Tests: `pytest` from the project root
- Keep functions simple and well-tested
- Use type hints on function signatures
- Raise `ValueError` for invalid inputs
EOF
}

# Writes README.md — one-paragraph description.
_write_readme() {
  local dir="$1"
  cat > "$dir/README.md" << 'EOF'
# mathlib

A minimal Python math utility library used as a sacrificial test project
for the Autopilot pipeline. Contains simple math functions with pytest tests.

## Install

```
pip install -r requirements.txt
```

## Test

```
pytest
```
EOF
}
