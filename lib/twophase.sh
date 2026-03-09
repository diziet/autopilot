#!/usr/bin/env bash
# Two-phase bats test runner for Autopilot.
# Phase 1: Run previously-failed tests for fast rejection (~5s).
# Phase 2: Run full suite to catch regressions.
# Tracks failed test files between runs via .autopilot/.last-failed-tests.
# Can be sourced as a library or executed as a standalone script.

# When sourced, prevent double-loading.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  [[ -n "${_AUTOPILOT_TWOPHASE_LOADED:-}" ]] && return 0
  _AUTOPILOT_TWOPHASE_LOADED=1
fi

# Cache file path relative to project directory.
readonly _LAST_FAILED_FILE=".autopilot/.last-failed-tests"

# --- TAP Parsing ---

# Parse bats TAP output for failed test file paths. Outputs unique paths.
parse_tap_failures() {
  local tap_output="$1"
  echo "$tap_output" | \
    grep -o 'in test file [^ ,)]*' | \
    sed 's/^in test file //' | \
    sort -u
}

# --- Cache Management ---

# Write failed test file paths to the cache file (reads from stdin).
write_last_failed_tests() {
  local project_dir="$1"
  local cache_file="${project_dir}/${_LAST_FAILED_FILE}"
  mkdir -p "$(dirname "$cache_file")"
  cat > "$cache_file"
}

# Read failed test file paths from cache. One path per line.
read_last_failed_tests() {
  local project_dir="$1"
  local cache_file="${project_dir}/${_LAST_FAILED_FILE}"
  [[ -f "$cache_file" ]] && cat "$cache_file"
}

# Clear the failed tests cache file.
clear_last_failed_tests() {
  local project_dir="$1"
  rm -f "${project_dir}/${_LAST_FAILED_FILE}"
}

# Check if failed tests cache exists and is non-empty.
has_last_failed_tests() {
  local project_dir="$1"
  local cache_file="${project_dir}/${_LAST_FAILED_FILE}"
  [[ -f "$cache_file" ]] && [[ -s "$cache_file" ]]
}

# --- Two-Phase Runner ---

# Run bats in two phases: previously-failed first, then full suite.
# Returns 0 on full pass, 1 on failure. Echoes test output to stdout.
run_bats_two_phase() {
  local project_dir="${1:-.}"
  local test_dir="${2:-tests/}"

  # Phase 1: Run previously-failed tests if cache exists.
  if has_last_failed_tests "$project_dir"; then
    local phase1_result
    phase1_result="$(_run_phase1 "$project_dir")" || {
      echo "$phase1_result"
      return 1
    }
  fi

  # Phase 2: Full suite.
  _run_phase2 "$project_dir" "$test_dir"
}

# --- Internal Helpers ---

# Phase 1: Run only previously-failed test files for fast rejection.
_run_phase1() {
  local project_dir="$1"
  local failed_files=()

  while IFS= read -r filepath; do
    [[ -z "$filepath" ]] && continue
    if [[ -f "${project_dir}/${filepath}" ]]; then
      failed_files+=("$filepath")
    fi
  done < <(read_last_failed_tests "$project_dir")

  # No valid files to re-run — skip phase 1.
  if [[ ${#failed_files[@]} -eq 0 ]]; then
    return 0
  fi

  local output exit_code=0
  output="$(cd "$project_dir" && bats --tap "${failed_files[@]}" 2>&1)" || exit_code=$?

  if [[ "$exit_code" -ne 0 ]]; then
    _update_failure_cache "$project_dir" "$output"
    echo "$output"
    return 1
  fi

  return 0
}

# Phase 2: Run the full test suite to catch regressions.
_run_phase2() {
  local project_dir="$1"
  local test_dir="${2:-tests/}"

  local jobs_arg=""
  if command -v parallel >/dev/null 2>&1; then
    jobs_arg="--jobs ${AUTOPILOT_TEST_JOBS:-20}"
  fi

  local output exit_code=0
  # shellcheck disable=SC2086
  output="$(cd "$project_dir" && bats --tap $jobs_arg "${test_dir}" 2>&1)" || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    clear_last_failed_tests "$project_dir"
  else
    _update_failure_cache "$project_dir" "$output"
  fi

  echo "$output"
  return "$exit_code"
}

# Update the failure cache from TAP output.
_update_failure_cache() {
  local project_dir="$1"
  local tap_output="$2"

  local failures
  failures="$(parse_tap_failures "$tap_output")"
  if [[ -n "$failures" ]]; then
    echo "$failures" | write_last_failed_tests "$project_dir"
  fi
}

# --- Standalone Execution ---
# When executed directly (not sourced), run two-phase logic.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  run_bats_two_phase "${1:-.}" "${2:-tests/}"
fi
