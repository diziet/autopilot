#!/usr/bin/env bats
# Tests for lib/live-test.sh — scaffold_test_repo() validation.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

# pytest and the packages it needs on Python 3.11 and later, pinned. The scaffold's
# requirements.txt lists pytest without a version, and the python3 on PATH may have no pytest.
LIVE_TEST_PYTEST_PINS=(pytest==9.2.0 iniconfig==2.3.1 packaging==26.3 pluggy==1.7.0 pygments==2.21.0)

setup() {
  TEST_SCAFFOLD_DIR="$BATS_TEST_TMPDIR/scaffold"
  mkdir -p "$TEST_SCAFFOLD_DIR"
  TASKS_FILE="$BATS_TEST_DIRNAME/../examples/live-test-tasks.md"
  CONF_FILE="$BATS_TEST_DIRNAME/../examples/live-test-autopilot.conf"
}

# Helper: source live-test.sh and scaffold.
_scaffold() {
  source "$BATS_TEST_DIRNAME/../lib/live-test.sh"
  scaffold_test_repo "$TEST_SCAFFOLD_DIR"
}

# Helper: create a venv in the test's temp dir with LIVE_TEST_PYTEST_PINS and set PYTEST_PYTHON.
# Skips the test when python3, its venv module or the package index is unavailable: then pytest
# cannot be provided, and the result says nothing about the scaffold. A skip is never a pass.
_provide_pytest_venv() {
  local venv_dir="$BATS_TEST_TMPDIR/venv"
  local log
  command -v python3 >/dev/null 2>&1 || skip "no python3 on PATH to create a venv for pytest"
  if ! log=$(python3 -m venv "$venv_dir" 2>&1); then
    skip "python3 -m venv failed, so pytest cannot be provided: $(tail -n 1 <<< "$log")"
  fi
  if ! log=$("$venv_dir/bin/python" -m pip install --disable-pip-version-check --no-input -q \
      --only-binary=:all: "${LIVE_TEST_PYTEST_PINS[@]}" 2>&1); then
    skip "pip could not install ${LIVE_TEST_PYTEST_PINS[*]}: $(tail -n 1 <<< "$log")"
  fi
  PYTEST_PYTHON="$venv_dir/bin/python"
}

# --- File creation tests ---

@test "scaffold creates src/mathlib.py" {
  _scaffold
  [ -f "$TEST_SCAFFOLD_DIR/src/mathlib.py" ]
}

@test "scaffold creates tests/test_mathlib.py" {
  _scaffold
  [ -f "$TEST_SCAFFOLD_DIR/tests/test_mathlib.py" ]
}

@test "scaffold creates requirements.txt" {
  _scaffold
  [ -f "$TEST_SCAFFOLD_DIR/requirements.txt" ]
}

@test "scaffold creates .gitignore" {
  _scaffold
  [ -f "$TEST_SCAFFOLD_DIR/.gitignore" ]
}

@test "scaffold creates CLAUDE.md" {
  _scaffold
  [ -f "$TEST_SCAFFOLD_DIR/CLAUDE.md" ]
}

@test "scaffold creates README.md" {
  _scaffold
  [ -f "$TEST_SCAFFOLD_DIR/README.md" ]
}

# --- Content validation tests ---

@test "mathlib.py contains add function" {
  _scaffold
  grep -q "def add" "$TEST_SCAFFOLD_DIR/src/mathlib.py"
}

@test "mathlib.py contains subtract function" {
  _scaffold
  grep -q "def subtract" "$TEST_SCAFFOLD_DIR/src/mathlib.py"
}

@test "test_mathlib.py imports from src.mathlib" {
  _scaffold
  grep -q "from src.mathlib import" "$TEST_SCAFFOLD_DIR/tests/test_mathlib.py"
}

@test "requirements.txt contains pytest" {
  _scaffold
  grep -q "pytest" "$TEST_SCAFFOLD_DIR/requirements.txt"
}

@test ".gitignore contains __pycache__" {
  _scaffold
  grep -q "__pycache__" "$TEST_SCAFFOLD_DIR/.gitignore"
}

@test "CLAUDE.md mentions pytest" {
  _scaffold
  grep -q "pytest" "$TEST_SCAFFOLD_DIR/CLAUDE.md"
}

# --- Python validity test ---

@test "pytest passes on scaffolded project" {
  _provide_pytest_venv
  _scaffold
  cd "$TEST_SCAFFOLD_DIR"
  run "$PYTEST_PYTHON" -m pytest tests/ -q
  [ "$status" -eq 0 ]
}

# --- Error handling ---

@test "scaffold_test_repo fails without target dir" {
  source "$BATS_TEST_DIRNAME/../lib/live-test.sh"
  run scaffold_test_repo ""
  [ "$status" -eq 1 ]
}

# --- Tasks file validation ---

@test "live-test-tasks.md has 6 tasks" {
  local count
  count=$(grep -c '^## Task [0-9]' "$TASKS_FILE")
  [ "$count" -eq 6 ]
}

@test "live-test-tasks.md contains multiply task" {
  grep -q "multiply" "$TASKS_FILE"
}

@test "live-test-tasks.md contains divide task" {
  grep -q "divide" "$TASKS_FILE"
}

@test "live-test-tasks.md contains factorial task" {
  grep -q "factorial" "$TASKS_FILE"
}

@test "live-test-tasks.md contains power task" {
  grep -q "power" "$TASKS_FILE"
}

# --- Config file validation ---

@test "live-test config uses haiku model" {
  grep -q "AUTOPILOT_CLAUDE_MODEL=claude-haiku-4-5-20251001" "$CONF_FILE"
}

@test "live-test config sets pytest as test command" {
  grep -q "AUTOPILOT_TEST_CMD=pytest" "$CONF_FILE"
}
