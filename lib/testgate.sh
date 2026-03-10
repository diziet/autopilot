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
# shellcheck source=lib/twophase.sh
source "${BASH_SOURCE[0]%/*}/twophase.sh"
# shellcheck source=lib/test-output.sh
source "${BASH_SOURCE[0]%/*}/test-output.sh"
# shellcheck source=lib/test-summary.sh
source "${BASH_SOURCE[0]%/*}/test-summary.sh"

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
# Disables coverage plugin for auto-detected pytest (adds overhead in pipeline).
_auto_detect_test_cmd() {
  local project_dir="${1:-.}"
  if _has_pytest "$project_dir"; then echo "pytest -p no:cov"; return 0; fi
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

# --- Shared Validation ---

# Validate preconditions and resolve the test command. Echoes cmd on success.
_resolve_test_cmd() {
  local project_dir="${1:-.}"
  is_sha_verified "$project_dir" && return "$TESTGATE_ALREADY_VERIFIED"
  local test_cmd
  test_cmd="$(detect_test_cmd "$project_dir")" || return "$TESTGATE_SKIP"
  local custom_cmd="${AUTOPILOT_TEST_CMD:-}"
  if [[ -z "$custom_cmd" ]] && ! _is_allowed_cmd "$test_cmd"; then
    return "$TESTGATE_ERROR"
  fi
  echo "$test_cmd"
}

# Log a message for a resolve exit code (non-zero).
_log_resolve_result() {
  local project_dir="$1"
  local code="$2"
  local context="${3:-}"
  case "$code" in
    "$TESTGATE_ALREADY_VERIFIED") log_msg "$project_dir" "INFO" "Tests already verified at current SHA — skipping${context}" ;;
    "$TESTGATE_SKIP") log_msg "$project_dir" "WARNING" "No test command detected — skipping${context}" ;;
    "$TESTGATE_ERROR") log_msg "$project_dir" "ERROR" "Auto-detected test command not on allowlist${context}" ;;
  esac
}

# --- Worktree Management ---

# Create a detached git worktree for background test execution.
create_test_worktree() {
  local project_dir="${1:-.}"
  local branch="$2"
  local worktree_dir="${project_dir}/.autopilot/worktrees/test-$$"
  mkdir -p "${worktree_dir%/*}"
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
  if git -C "$project_dir" worktree remove --force "$worktree_dir" 2>/dev/null; then
    log_msg "$project_dir" "INFO" "Removed test worktree: ${worktree_dir}"
  else
    log_msg "$project_dir" "WARNING" "Failed to remove worktree via git, falling back to rm"
    rm -rf "$worktree_dir"
    git -C "$project_dir" worktree prune 2>/dev/null || true
    log_msg "$project_dir" "INFO" "Cleaned up worktree: ${worktree_dir}"
  fi
}

# --- Venv Detection ---

# Build a shell command string that activates the project venv (if present)
# before running the test command. Falls back to orig_project_dir for worktrees.
_build_test_shell_cmd() {
  local project_dir="$1"
  local test_cmd="$2"
  local orig_project_dir="${3:-$project_dir}"
  local activate=""
  if [[ -f "${project_dir}/.venv/bin/activate" ]]; then
    activate="${project_dir}/.venv/bin/activate"
  elif [[ -f "${project_dir}/venv/bin/activate" ]]; then
    activate="${project_dir}/venv/bin/activate"
  elif [[ -f "${orig_project_dir}/.venv/bin/activate" ]]; then
    activate="${orig_project_dir}/.venv/bin/activate"
  elif [[ -f "${orig_project_dir}/venv/bin/activate" ]]; then
    activate="${orig_project_dir}/venv/bin/activate"
  fi
  if [[ -n "$activate" ]]; then
    echo "source '${activate}' && ${test_cmd}"
  else
    echo "$test_cmd"
  fi
}

# --- Test Execution ---

# Run tests in the given directory with timeout.
# Echoes test output to stdout. Returns TESTGATE_PASS or TESTGATE_FAIL.
# Writes the raw exit code to fd 3 if open, for diagnostic logging.
# Optional $4 is orig_project_dir for venv fallback in worktrees.
_run_test_cmd() {
  local work_dir="$1"
  local test_cmd="$2"
  local timeout_seconds="${3:-${AUTOPILOT_TIMEOUT_TEST_GATE:-300}}"
  local orig_project_dir="${4:-$work_dir}"
  local shell_cmd
  shell_cmd="$(_build_test_shell_cmd "$work_dir" "$test_cmd" "$orig_project_dir")"
  local raw_exit=0
  # Single quotes intentional: $1/$2 expand in inner bash, not outer.
  # shellcheck disable=SC2016
  timeout "$timeout_seconds" bash -c 'cd "$1" && eval "$2"' _ "$work_dir" "$shell_cmd" 2>&1 || raw_exit=$?
  # Write raw exit code to fd 3 if open (callers can capture for diagnostics).
  echo "$raw_exit" >&3 2>/dev/null || true
  [[ "$raw_exit" -eq 0 ]] && return "$TESTGATE_PASS"
  return "$TESTGATE_FAIL"
}

# --- Main Entry Points ---

# Run the test gate for a project. Returns a TESTGATE_* exit code.
# Uses two-phase runner for bats projects (fast rejection of known failures).
run_test_gate() {
  local project_dir="${1:-.}"

  local test_cmd resolve_code=0
  test_cmd="$(_resolve_test_cmd "$project_dir")" || resolve_code=$?
  if [[ "$resolve_code" -ne 0 ]]; then
    _log_resolve_result "$project_dir" "$resolve_code"
    return "$resolve_code"
  fi

  local timeout_seconds="${AUTOPILOT_TIMEOUT_TEST_GATE:-300}"
  log_msg "$project_dir" "INFO" "Running test gate: ${test_cmd} (timeout=${timeout_seconds}s)"

  local start_epoch
  start_epoch="$(date +%s)"

  # Use two-phase runner only for auto-detected bats (not custom AUTOPILOT_TEST_CMD).
  local gate_exit=0
  if [[ -z "${AUTOPILOT_TEST_CMD:-}" ]] && _is_bats_test_cmd "$test_cmd"; then
    _run_test_gate_bats "$project_dir" "$timeout_seconds" || gate_exit=$?
  else
    _run_test_gate_standard "$project_dir" "$test_cmd" "$timeout_seconds" || gate_exit=$?
  fi

  # Read test output from the log file written by _handle_test_gate_result.
  local output_log="${project_dir}/.autopilot/test_gate_output.log"
  local gate_output=""
  if [[ -f "$output_log" ]]; then
    gate_output="$(cat "$output_log" 2>/dev/null)" || true
  else
    log_msg "$project_dir" "WARNING" "test_gate_output.log not found — skipping summary"
  fi

  # Read raw exit code for timeout detection (gate_exit is remapped to 0/1).
  local raw_exit="$gate_exit"
  local raw_exit_file="${project_dir}/.autopilot/test_gate_raw_exit"
  [[ -f "$raw_exit_file" ]] && raw_exit="$(cat "$raw_exit_file" 2>/dev/null)" || true

  # Log TIMER + TEST_GATE summary (uses raw exit for timeout detection).
  log_test_timing_and_summary "$project_dir" "test gate" "$start_epoch" \
    "$raw_exit" "$timeout_seconds" "$gate_output"

  return "$gate_exit"
}

# Check if a test command is bats-based (word-boundary match).
_is_bats_test_cmd() {
  local test_cmd="$1"
  [[ "$test_cmd" == "bats "* ]] || [[ "$test_cmd" == "bats" ]]
}

# Run test gate using two-phase bats runner.
_run_test_gate_bats() {
  local project_dir="$1"
  local timeout_seconds="$2"

  local output exit_code=0
  # Single quotes intentional: $1/$2 expand in inner bash, not outer.
  # shellcheck disable=SC2016
  output="$(timeout "$timeout_seconds" bash -c \
    'source "$1" && run_bats_two_phase "$2"' _ \
    "${BASH_SOURCE[0]%/*}/twophase.sh" "$project_dir" 2>&1)" || exit_code=$?

  _handle_test_gate_result "$project_dir" "$exit_code" "$output"
}

# Run test gate using standard single-pass execution.
_run_test_gate_standard() {
  local project_dir="$1"
  local test_cmd="$2"
  local timeout_seconds="$3"

  local output raw_exit_file exit_code=0
  raw_exit_file="$(mktemp "${TMPDIR:-/tmp}/autopilot-raw-exit.XXXXXX")"
  output="$(_run_test_cmd "$project_dir" "$test_cmd" "$timeout_seconds" 3>"$raw_exit_file")" || exit_code=$?
  local raw_exit
  raw_exit="$(cat "$raw_exit_file" 2>/dev/null)"
  rm -f "$raw_exit_file"

  _handle_test_gate_result "$project_dir" "$exit_code" "$output" "${raw_exit:-unknown}"
}

# Extract failing test lines (TAP 'not ok') with assertion details from output.
# Echoes the extracted lines to stdout, empty if none found.
_extract_failing_tests() {
  local output="$1"
  echo "$output" | grep -A1 '^not ok' | grep -v '^--$' || true
}

# Log failing test names and assertion details prominently.
_log_failing_tests() {
  local project_dir="$1"
  local output="$2"
  local failures
  failures="$(_extract_failing_tests "$output")"
  if [[ -n "$failures" ]]; then
    log_msg "$project_dir" "ERROR" "Failing tests:"
    log_msg "$project_dir" "ERROR" "$failures"
  fi
}

# Handle test gate result: log outcome, set SHA flag on pass.
# Writes output to test_gate_output.log so PR comments can read it.
_handle_test_gate_result() {
  local project_dir="$1"
  local exit_code="$2"
  local output="$3"
  local raw_exit="${4:-${exit_code}}"

  # Write output to log file for PR comments and other consumers.
  local output_log="${project_dir}/.autopilot/test_gate_output.log"
  mkdir -p "${project_dir}/.autopilot"
  echo "$output" > "$output_log" 2>/dev/null || true

  # Write raw exit code for summary logging (timeout detection needs it).
  echo "$raw_exit" > "${project_dir}/.autopilot/test_gate_raw_exit" 2>/dev/null || true

  if [[ "$exit_code" -eq "$TESTGATE_PASS" ]]; then
    log_msg "$project_dir" "INFO" "Test gate PASSED"
    local current_sha
    current_sha="$(git -C "$project_dir" rev-parse HEAD 2>/dev/null)" || true
    [[ -n "$current_sha" ]] && write_hook_sha_flag "$project_dir" "$current_sha"
    return "$TESTGATE_PASS"
  fi

  log_msg "$project_dir" "ERROR" "Test gate FAILED (raw_exit=${raw_exit})"

  # Extract and log failing test names prominently before the tail.
  _log_failing_tests "$project_dir" "$output"

  local tail_lines="${AUTOPILOT_TEST_OUTPUT_TAIL:-80}"
  local trimmed_output
  trimmed_output="$(tail -n "$tail_lines" <<< "$output")"
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
  local output_log="${project_dir}/.autopilot/test_gate_output.log"

  local test_cmd resolve_code=0
  test_cmd="$(_resolve_test_cmd "$project_dir")" || resolve_code=$?
  if [[ "$resolve_code" -ne 0 ]]; then
    _log_resolve_result "$project_dir" "$resolve_code" " background gate"
    echo "$resolve_code" > "$result_file"
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

  # Clear stale result before spawning background process.
  rm -f "$result_file"

  (
    local bg_exit=0
    _run_test_cmd "$worktree_dir" "$test_cmd" "$timeout_seconds" "$project_dir" 3>/dev/null > "$output_log" 2>&1 || bg_exit=$?
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

# Check if a background test gate result file exists (test gate has completed).
has_test_gate_result() {
  local project_dir="${1:-.}"
  local result_file="${project_dir}/.autopilot/test_gate_result"
  [[ -f "$result_file" ]]
}

# Read background test gate result. Returns the stored exit code.
read_test_gate_result() {
  local project_dir="${1:-.}"
  local result_file="${project_dir}/.autopilot/test_gate_result"
  [[ ! -f "$result_file" ]] && return "$TESTGATE_ERROR"
  local result
  result="$(cat "$result_file" 2>/dev/null)"
  [[ -z "$result" ]] && return "$TESTGATE_ERROR"
  [[ "$result" =~ ^[0-9]+$ ]] || return "$TESTGATE_ERROR"
  return "$result"
}

# Clear the background test gate result file.
clear_test_gate_result() {
  local project_dir="${1:-.}"
  rm -f "${project_dir}/.autopilot/test_gate_result"
}
