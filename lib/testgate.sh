#!/usr/bin/env bash
# Test gate for Autopilot.
# Runs the project's test suite as a quality gate. Supports custom test
# commands, auto-detection of test frameworks, background execution in
# detached git worktrees, and Stop hook SHA flags to skip redundant runs.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_TESTGATE_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_TESTGATE_LOADED=1

# shellcheck source=lib/config.sh
source "${BASH_SOURCE[0]%/*}/config.sh"
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"

# --- Exit Code Constants (exported for postfix.sh and merger.sh) ---
readonly TESTGATE_PASS=0
readonly TESTGATE_FAIL=1
readonly TESTGATE_SKIP=2
readonly TESTGATE_ALREADY_VERIFIED=3
readonly TESTGATE_ERROR=4
export TESTGATE_PASS TESTGATE_FAIL TESTGATE_SKIP
export TESTGATE_ALREADY_VERIFIED TESTGATE_ERROR

# Allowlisted test commands for auto-detection security.
readonly _TESTGATE_ALLOWLIST="pytest npm bats make"

# --- SHA Flag Management ---

# Read the SHA written by Stop hooks indicating tests passed.
read_hook_sha_flag() {
  local project_dir="${1:-.}"
  local flag_file="${project_dir}/.autopilot/test_verified_sha"
  if [[ -f "$flag_file" ]]; then
    cat "$flag_file" 2>/dev/null
  fi
}

# Write a SHA flag indicating tests passed at this commit.
write_hook_sha_flag() {
  local project_dir="${1:-.}"
  local sha="$2"
  mkdir -p "${project_dir}/.autopilot"
  echo "$sha" > "${project_dir}/.autopilot/test_verified_sha"
}

# Clear the SHA flag.
clear_hook_sha_flag() {
  rm -f "${1:-.}/.autopilot/test_verified_sha"
}

# Check if current HEAD matches the verified SHA flag.
is_sha_verified() {
  local project_dir="${1:-.}"
  local current_sha verified_sha
  current_sha="$(git -C "$project_dir" rev-parse HEAD 2>/dev/null)" || return 1
  verified_sha="$(read_hook_sha_flag "$project_dir")"
  [[ -n "$verified_sha" ]] && [[ "$current_sha" = "$verified_sha" ]]
}

# --- Test Framework Detection ---

# Detect the test command for a project. Uses AUTOPILOT_TEST_CMD if set.
detect_test_cmd() {
  local project_dir="${1:-.}"
  local custom_cmd="${AUTOPILOT_TEST_CMD:-}"
  if [[ -n "$custom_cmd" ]]; then
    echo "$custom_cmd"
    return 0
  fi
  _auto_detect_test_cmd "$project_dir"
}

# Auto-detect: pytest → npm test → bats → make test.
_auto_detect_test_cmd() {
  local project_dir="${1:-.}"
  if _has_pytest "$project_dir"; then echo "pytest"; return 0; fi
  if _has_npm_test "$project_dir"; then echo "npm test"; return 0; fi
  if _has_bats "$project_dir"; then echo "bats tests/"; return 0; fi
  if _has_make_test "$project_dir"; then echo "make test"; return 0; fi
  return 1
}

# Check if project uses pytest.
_has_pytest() {
  local d="$1"
  [[ -f "${d}/conftest.py" ]] || [[ -f "${d}/tests/conftest.py" ]] && return 0
  [[ -f "${d}/pyproject.toml" ]] && grep -q 'pytest' "${d}/pyproject.toml" 2>/dev/null && return 0
  local f; for f in "${d}"/requirements*.txt; do
    [[ -f "$f" ]] && grep -qi 'pytest' "$f" 2>/dev/null && return 0
  done
  return 1
}

# Check if project has npm test script.
_has_npm_test() {
  local d="$1"
  [[ -f "${d}/package.json" ]] || return 1
  local script
  script="$(jq -r '.scripts.test // empty' "${d}/package.json" 2>/dev/null)"
  [[ -n "$script" ]]
}

# Check if project has bats test files.
_has_bats() {
  local d="$1"
  local found
  found="$(find "${d}/tests" -maxdepth 1 -name '*.bats' 2>/dev/null | head -1)"
  [[ -n "$found" ]]
}

# Check if project has Makefile with test target.
_has_make_test() {
  local d="$1"
  [[ -f "${d}/Makefile" ]] && grep -q '^test:' "${d}/Makefile" 2>/dev/null
}

# --- Allowlist Validation ---

# Validate that a test command's first word is on the allowlist.
_is_allowed_cmd() {
  local first_word="${1%% *}"
  local allowed
  for allowed in $_TESTGATE_ALLOWLIST; do
    [[ "$first_word" = "$allowed" ]] && return 0
  done
  return 1
}

# --- Worktree Management ---

# Create a detached git worktree for background test execution.
create_test_worktree() {
  local project_dir="${1:-.}"
  local branch="$2"
  local worktree_dir="${project_dir}/.autopilot/worktrees/test-$$"
  mkdir -p "$(dirname "$worktree_dir")"
  if ! git -C "$project_dir" worktree add --detach "$worktree_dir" "$branch" >/dev/null 2>&1; then
    log_msg "$project_dir" "ERROR" "Failed to create test worktree for branch ${branch}"
    return 1
  fi
  log_msg "$project_dir" "INFO" "Created test worktree: ${worktree_dir}"
  echo "$worktree_dir"
}

# Remove a detached git worktree after test completion.
remove_test_worktree() {
  local project_dir="${1:-.}"
  local worktree_dir="$2"
  [[ -z "$worktree_dir" ]] || [[ ! -d "$worktree_dir" ]] && return 0
  git -C "$project_dir" worktree remove --force "$worktree_dir" 2>/dev/null || {
    log_msg "$project_dir" "WARNING" "Failed to remove worktree: ${worktree_dir}"
    rm -rf "$worktree_dir"
  }
  log_msg "$project_dir" "INFO" "Removed test worktree: ${worktree_dir}"
}

# --- Test Execution ---

# Run tests in the given directory with timeout. Returns TESTGATE_PASS or TESTGATE_FAIL.
_run_test_cmd() {
  local work_dir="$1"
  local test_cmd="$2"
  local timeout_seconds="${3:-${AUTOPILOT_TEST_TIMEOUT:-300}}"
  local exit_code=0
  timeout "$timeout_seconds" bash -c "cd '$work_dir' && $test_cmd" 2>&1 || exit_code=$?
  [[ "$exit_code" -eq 0 ]] && return "$TESTGATE_PASS"
  return "$TESTGATE_FAIL"
}

# --- Main Entry Points ---

# Run the test gate for a project. Returns a TESTGATE_* exit code.
run_test_gate() {
  local project_dir="${1:-.}"

  if is_sha_verified "$project_dir"; then
    log_msg "$project_dir" "INFO" "Tests already verified at current SHA — skipping"
    return "$TESTGATE_ALREADY_VERIFIED"
  fi

  local test_cmd
  test_cmd="$(detect_test_cmd "$project_dir")" || {
    log_msg "$project_dir" "WARNING" "No test command detected — skipping test gate"
    return "$TESTGATE_SKIP"
  }

  local custom_cmd="${AUTOPILOT_TEST_CMD:-}"
  if [[ -z "$custom_cmd" ]] && ! _is_allowed_cmd "$test_cmd"; then
    log_msg "$project_dir" "ERROR" "Auto-detected test command '${test_cmd}' not on allowlist"
    return "$TESTGATE_ERROR"
  fi

  local timeout_seconds="${AUTOPILOT_TIMEOUT_TEST_GATE:-300}"
  log_msg "$project_dir" "INFO" "Running test gate: ${test_cmd} (timeout=${timeout_seconds}s)"

  local output exit_code=0
  output="$(_run_test_cmd "$project_dir" "$test_cmd" "$timeout_seconds")" || exit_code=$?

  if [[ "$exit_code" -eq "$TESTGATE_PASS" ]]; then
    log_msg "$project_dir" "INFO" "Test gate PASSED"
    local current_sha
    current_sha="$(git -C "$project_dir" rev-parse HEAD 2>/dev/null)" || true
    [[ -n "$current_sha" ]] && write_hook_sha_flag "$project_dir" "$current_sha"
    return "$TESTGATE_PASS"
  fi

  local tail_lines="${AUTOPILOT_TEST_OUTPUT_TAIL:-80}"
  local trimmed_output
  trimmed_output="$(echo "$output" | tail -n "$tail_lines")"
  log_msg "$project_dir" "ERROR" "Test gate FAILED (exit=${exit_code})"
  log_msg "$project_dir" "INFO" "Test output (last ${tail_lines} lines):"
  log_msg "$project_dir" "INFO" "$trimmed_output"
  return "$TESTGATE_FAIL"
}

# Run the test gate in background using a detached worktree.
# Writes exit code to a result file for the caller to poll.
run_test_gate_background() {
  local project_dir="${1:-.}"
  local branch="$2"
  local result_file="${project_dir}/.autopilot/test_gate_result"

  if is_sha_verified "$project_dir"; then
    log_msg "$project_dir" "INFO" "Tests already verified — skipping background gate"
    echo "$TESTGATE_ALREADY_VERIFIED" > "$result_file"
    echo "$result_file"
    return 0
  fi

  local test_cmd
  if ! test_cmd="$(detect_test_cmd "$project_dir")"; then
    log_msg "$project_dir" "WARNING" "No test command — skipping background test gate"
    echo "$TESTGATE_SKIP" > "$result_file"
    echo "$result_file"
    return 0
  fi

  local custom_cmd="${AUTOPILOT_TEST_CMD:-}"
  if [[ -z "$custom_cmd" ]] && ! _is_allowed_cmd "$test_cmd"; then
    log_msg "$project_dir" "ERROR" "Auto-detected '${test_cmd}' not on allowlist"
    echo "$TESTGATE_ERROR" > "$result_file"
    echo "$result_file"
    return 0
  fi

  local timeout_seconds="${AUTOPILOT_TIMEOUT_TEST_GATE:-300}"
  log_msg "$project_dir" "INFO" "Starting background test gate: ${test_cmd} on ${branch}"

  local worktree_dir
  if ! worktree_dir="$(create_test_worktree "$project_dir" "$branch")"; then
    echo "$TESTGATE_ERROR" > "$result_file"
    echo "$result_file"
    return 0
  fi

  (
    local bg_exit=0
    _run_test_cmd "$worktree_dir" "$test_cmd" "$timeout_seconds" >/dev/null 2>&1 || bg_exit=$?
    echo "$bg_exit" > "$result_file"
    if [[ "$bg_exit" -eq "$TESTGATE_PASS" ]]; then
      local sha
      sha="$(git -C "$worktree_dir" rev-parse HEAD 2>/dev/null)" || true
      [[ -n "$sha" ]] && write_hook_sha_flag "$project_dir" "$sha"
    fi
    remove_test_worktree "$project_dir" "$worktree_dir"
  ) &

  log_msg "$project_dir" "INFO" "Background test gate PID: $!"
  echo "$result_file"
}

# Read background test gate result. Returns the exit code or TESTGATE_ERROR.
read_test_gate_result() {
  local project_dir="${1:-.}"
  local result_file="${project_dir}/.autopilot/test_gate_result"
  [[ ! -f "$result_file" ]] && return "$TESTGATE_ERROR"
  local result
  result="$(cat "$result_file" 2>/dev/null)"
  [[ -z "$result" ]] && return "$TESTGATE_ERROR"
  return "$result"
}
