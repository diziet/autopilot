#!/usr/bin/env bats
# Smoke test — source all lib/*.sh files in a subshell.
# Verifies no syntax errors, no variable conflicts, no function name collisions.

# Directory containing lib/ modules.
LIB_DIR="$BATS_TEST_DIRNAME/../lib"

# All expected lib files — update when a new module is added.
EXPECTED_LIB_FILES=(
  "claude.sh"
  "coder.sh"
  "config.sh"
  "context.sh"
  "diagnose.sh"
  "dispatch-handlers.sh"
  "dispatch-helpers.sh"
  "dispatcher.sh"
  "fixer.sh"
  "git-ops.sh"
  "hooks.sh"
  "merger.sh"
  "metrics.sh"
  "postfix.sh"
  "preflight.sh"
  "review-runner.sh"
  "reviewer-posting.sh"
  "reviewer.sh"
  "session-cache.sh"
  "spec-review.sh"
  "state.sh"
  "tasks.sh"
  "testgate.sh"
)

setup() {
  # Unset all AUTOPILOT_* env vars for a clean slate.
  while IFS= read -r var; do
    unset "$var"
  done < <(env | grep '^AUTOPILOT_' | cut -d= -f1)

  # Unset all load guards so each test starts fresh.
  for file in "${EXPECTED_LIB_FILES[@]}"; do
    local guard_name
    guard_name="_AUTOPILOT_$(echo "${file%.sh}" | tr '[:lower:]-' '[:upper:]_')_LOADED"
    unset "$guard_name"
  done
}

# --- Syntax checks ---

@test "syntax: every lib/*.sh file passes bash -n" {
  local file failures=()
  for file in "$LIB_DIR"/*.sh; do
    local err
    if ! err=$(bash -n "$file" 2>&1); then
      failures+=("$(basename "$file"): $err")
    fi
  done
  if [[ ${#failures[@]} -gt 0 ]]; then
    printf "Syntax errors:\n%s\n" "${failures[*]}" >&2
    return 1
  fi
}

# --- Source each module individually in a subshell ---

@test "source: each lib file loads individually without error" {
  local file failures=()
  for file in "$LIB_DIR"/*.sh; do
    local err
    if ! err=$( (source "$file") 2>&1 ); then
      failures+=("$(basename "$file"): $err")
    fi
  done
  if [[ ${#failures[@]} -gt 0 ]]; then
    printf "Failed to source:\n%s\n" "${failures[*]}" >&2
    return 1
  fi
}

# --- Source ALL lib files together in one subshell ---

@test "source: all lib/*.sh files load together without error" {
  (
    for file in "$LIB_DIR"/*.sh; do
      source "$file"
    done
  )
}

@test "source: all lib/*.sh files load in reverse order without error" {
  local files=()
  for file in "$LIB_DIR"/*.sh; do
    files+=("$file")
  done
  (
    local i
    for (( i=${#files[@]}-1; i>=0; i-- )); do
      source "${files[$i]}"
    done
  )
}

# --- Load guard verification ---

@test "guards: every lib file except config.sh has a load guard" {
  local file missing=()
  for file in "$LIB_DIR"/*.sh; do
    local base
    base="$(basename "$file")"
    [[ "$base" == "config.sh" ]] && continue
    if ! grep -q '_AUTOPILOT_.*_LOADED.*return' "$file"; then
      missing+=("$base")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Files missing load guards: ${missing[*]}" >&2
    return 1
  fi
}

@test "guards: load guards prevent double-sourcing side effects" {
  (
    source "$LIB_DIR/state.sh"
    # Redefine log_msg to a sentinel to detect if the file body re-executes.
    log_msg() { echo "SENTINEL"; }
    # Second source should hit the guard and return immediately.
    source "$LIB_DIR/state.sh"
    # If the guard worked, our redefined log_msg was NOT overwritten.
    [[ "$(log_msg)" == "SENTINEL" ]]
  )
}

@test "guards: double-sourcing all files produces no errors" {
  (
    for file in "$LIB_DIR"/*.sh; do
      source "$file"
    done
    for file in "$LIB_DIR"/*.sh; do
      source "$file"
    done
  )
}

# --- No function name collisions ---

# Helper: extract function names from all lib/*.sh files.
_collect_all_functions() {
  grep -h '^[a-zA-Z_][a-zA-Z0-9_]*()' "$LIB_DIR"/*.sh \
    | sed 's/()[[:space:]]*{.*//' \
    | sed 's/()[[:space:]]*//' \
    | sort
}

@test "functions: no duplicate function names across lib files" {
  local duplicates
  duplicates=$(_collect_all_functions | uniq -d)
  if [[ -n "$duplicates" ]]; then
    echo "Duplicate function names found:" >&2
    echo "$duplicates" >&2
    return 1
  fi
}

@test "functions: every lib file defines at least one function" {
  local file empty=()
  for file in "$LIB_DIR"/*.sh; do
    if ! grep -q '^[a-zA-Z_][a-zA-Z0-9_]*()' "$file"; then
      empty+=("$(basename "$file")")
    fi
  done
  if [[ ${#empty[@]} -gt 0 ]]; then
    echo "Files with no functions: ${empty[*]}" >&2
    return 1
  fi
}

@test "functions: key public functions are callable after sourcing all libs" {
  (
    for file in "$LIB_DIR"/*.sh; do
      source "$file"
    done
    # Verify one key function from each module is declared.
    [[ "$(type -t load_config)" == "function" ]]
    [[ "$(type -t init_pipeline)" == "function" ]]
    [[ "$(type -t detect_tasks_file)" == "function" ]]
    [[ "$(type -t build_claude_cmd)" == "function" ]]
    [[ "$(type -t run_preflight)" == "function" ]]
    [[ "$(type -t install_hooks)" == "function" ]]
    [[ "$(type -t run_test_gate)" == "function" ]]
    [[ "$(type -t prewarm_session)" == "function" ]]
    [[ "$(type -t create_task_branch)" == "function" ]]
    [[ "$(type -t run_coder)" == "function" ]]
    [[ "$(type -t run_fixer)" == "function" ]]
    [[ "$(type -t run_reviewers)" == "function" ]]
    [[ "$(type -t post_review_comments)" == "function" ]]
    [[ "$(type -t run_postfix_verification)" == "function" ]]
    [[ "$(type -t run_merger)" == "function" ]]
    [[ "$(type -t run_diagnosis)" == "function" ]]
    [[ "$(type -t should_run_spec_review)" == "function" ]]
    [[ "$(type -t run_spec_review)" == "function" ]]
    [[ "$(type -t generate_task_summary)" == "function" ]]
    [[ "$(type -t record_task_start)" == "function" ]]
    [[ "$(type -t record_task_complete)" == "function" ]]
    [[ "$(type -t record_phase_durations)" == "function" ]]
    [[ "$(type -t record_claude_usage)" == "function" ]]
    [[ "$(type -t timer_start)" == "function" ]]
    [[ "$(type -t dispatch_tick)" == "function" ]]
    [[ "$(type -t _run_cron_review)" == "function" ]]
    [[ "$(type -t _run_standalone_review)" == "function" ]]
  )
}

# --- No variable conflicts ---

@test "variables: load guard names are unique per module" {
  local guards
  guards=$(grep -h 'readonly _AUTOPILOT_.*_LOADED=1' "$LIB_DIR"/*.sh \
    | sed 's/readonly //' | sed 's/=1//' | sort)
  local duplicates
  duplicates=$(echo "$guards" | uniq -d)
  if [[ -n "$duplicates" ]]; then
    echo "Duplicate load guard variables:" >&2
    echo "$duplicates" >&2
    return 1
  fi
}

@test "variables: exported exit code constants have unique names" {
  local exports
  exports=$(grep -rh '^\(readonly\|export\) [A-Z]' "$LIB_DIR"/*.sh \
    | grep -v '_AUTOPILOT_' \
    | sed 's/^readonly //' | sed 's/^export //' \
    | sed 's/=.*//' | sort)
  local duplicates
  duplicates=$(echo "$exports" | uniq -d)
  if [[ -n "$duplicates" ]]; then
    echo "Duplicate exported constants:" >&2
    echo "$duplicates" >&2
    return 1
  fi
}

@test "variables: TESTGATE exit codes are accessible after sourcing" {
  (
    source "$LIB_DIR/testgate.sh"
    [[ "$TESTGATE_PASS" == "0" ]]
    [[ "$TESTGATE_FAIL" == "1" ]]
    [[ "$TESTGATE_SKIP" == "2" ]]
    [[ "$TESTGATE_ALREADY_VERIFIED" == "3" ]]
    [[ "$TESTGATE_ERROR" == "4" ]]
  )
}

@test "variables: POSTFIX exit codes are accessible after sourcing" {
  (
    source "$LIB_DIR/postfix.sh"
    [[ "$POSTFIX_PASS" == "0" ]]
    [[ "$POSTFIX_FAIL" == "1" ]]
    [[ "$POSTFIX_ERROR" == "2" ]]
  )
}

@test "variables: MERGER exit codes are accessible after sourcing" {
  (
    source "$LIB_DIR/merger.sh"
    [[ "$MERGER_APPROVE" == "0" ]]
    [[ "$MERGER_REJECT" == "1" ]]
    [[ "$MERGER_ERROR" == "2" ]]
  )
}

@test "variables: CONTEXT exit codes are accessible after sourcing" {
  (
    source "$LIB_DIR/context.sh"
    [[ "$CONTEXT_OK" == "0" ]]
    [[ "$CONTEXT_ERROR" == "1" ]]
  )
}

@test "variables: METRICS exit codes are accessible after sourcing" {
  (
    source "$LIB_DIR/metrics.sh"
    [[ "$METRICS_OK" == "0" ]]
    [[ "$METRICS_ERROR" == "1" ]]
  )
}

@test "variables: DIAGNOSE exit codes are accessible after sourcing" {
  (
    source "$LIB_DIR/diagnose.sh"
    [[ "$DIAGNOSE_OK" == "0" ]]
    [[ "$DIAGNOSE_ERROR" == "1" ]]
  )
}

@test "variables: SPEC_REVIEW exit codes are accessible after sourcing" {
  (
    source "$LIB_DIR/spec-review.sh"
    [[ "$SPEC_REVIEW_OK" == "0" ]]
    [[ "$SPEC_REVIEW_SKIP" == "1" ]]
    [[ "$SPEC_REVIEW_ERROR" == "2" ]]
  )
}

@test "variables: REVIEW exit codes are accessible after sourcing" {
  (
    source "$LIB_DIR/review-runner.sh"
    [[ "$REVIEW_OK" == "0" ]]
    [[ "$REVIEW_SKIP" == "1" ]]
    [[ "$REVIEW_ERROR" == "2" ]]
  )
}

@test "variables: exit code constants survive multi-module sourcing" {
  (
    source "$LIB_DIR/testgate.sh"
    source "$LIB_DIR/postfix.sh"
    source "$LIB_DIR/merger.sh"
    source "$LIB_DIR/metrics.sh"
    source "$LIB_DIR/diagnose.sh"
    source "$LIB_DIR/spec-review.sh"
    source "$LIB_DIR/review-runner.sh"
    # Each module uses its own prefix — no cross-contamination.
    [[ "$TESTGATE_PASS" == "0" ]]
    [[ "$POSTFIX_PASS" == "0" ]]
    [[ "$MERGER_APPROVE" == "0" ]]
    [[ "$METRICS_OK" == "0" ]]
    [[ "$DIAGNOSE_OK" == "0" ]]
    [[ "$SPEC_REVIEW_OK" == "0" ]]
    [[ "$REVIEW_OK" == "0" ]]
    [[ "$TESTGATE_ERROR" == "4" ]]
    [[ "$POSTFIX_ERROR" == "2" ]]
    [[ "$MERGER_ERROR" == "2" ]]
    [[ "$METRICS_ERROR" == "1" ]]
    [[ "$DIAGNOSE_ERROR" == "1" ]]
    [[ "$SPEC_REVIEW_ERROR" == "2" ]]
    [[ "$REVIEW_ERROR" == "2" ]]
  )
}

# --- Comprehensive combined sourcing ---

@test "combined: all libs source together and expose 50+ functions" {
  run bash -c '
    for file in "'"$LIB_DIR"'"/*.sh; do
      source "$file" || { echo "Failed to source $(basename "$file")"; exit 1; }
    done
    func_count=$(declare -F | wc -l)
    if [[ "$func_count" -lt 50 ]]; then
      echo "Only $func_count functions found, expected 50+" >&2
      exit 1
    fi
    echo "OK: $func_count functions loaded"
  '
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "combined: no stderr warnings when sourcing all libs under strict mode" {
  run bash -c '
    set -euo pipefail
    exec 2>&1
    for file in "'"$LIB_DIR"'"/*.sh; do
      source "$file"
    done
    echo "OK"
  '
  echo "$output"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "unbound variable" ]]
  [[ ! "$output" =~ "readonly variable" ]]
  [[ ! "$output" =~ "not found" ]]
}

@test "combined: sourcing all libs does not pollute PATH" {
  local original_path="$PATH"
  (
    for file in "$LIB_DIR"/*.sh; do
      source "$file"
    done
    [[ "$PATH" == "$original_path" ]]
  )
}

# --- File coverage check ---

@test "coverage: test covers all lib/*.sh files that exist" {
  local lib_files=()
  for file in "$LIB_DIR"/*.sh; do
    lib_files+=("$(basename "$file")")
  done
  # Forward check: new files on disk not in EXPECTED_LIB_FILES.
  local unexpected=()
  for file in "${lib_files[@]}"; do
    local found=0
    for expected in "${EXPECTED_LIB_FILES[@]}"; do
      if [[ "$file" == "$expected" ]]; then
        found=1
        break
      fi
    done
    if [[ "$found" -eq 0 ]]; then
      unexpected+=("$file")
    fi
  done
  if [[ ${#unexpected[@]} -gt 0 ]]; then
    echo "New lib files not covered by smoke test: ${unexpected[*]}" >&2
    echo "Add them to EXPECTED_LIB_FILES in test_smoke.bats" >&2
    return 1
  fi
  # Reverse check: stale entries in EXPECTED_LIB_FILES no longer on disk.
  local missing=()
  for expected in "${EXPECTED_LIB_FILES[@]}"; do
    if [[ ! -f "$LIB_DIR/$expected" ]]; then
      missing+=("$expected")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "EXPECTED_LIB_FILES lists files that no longer exist: ${missing[*]}" >&2
    echo "Remove them from EXPECTED_LIB_FILES in test_smoke.bats" >&2
    return 1
  fi
}
