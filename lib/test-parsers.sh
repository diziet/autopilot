#!/usr/bin/env bash
# Framework-specific test output parsers.
# Each parser extracts "total passed failed" from a framework's output format.
# Duration parsers extract elapsed seconds as an integer.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_TEST_PARSERS_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_TEST_PARSERS_LOADED=1

# --- TAP / Bats ---

# Parse bats TAP output. Counts "ok" and "not ok" lines.
# Echoes "total passed failed" or empty string if no TAP lines found.
_parse_bats_tap() {
  local output="$1"
  local ok_count=0
  local not_ok_count=0
  local found=false

  while IFS= read -r line; do
    if [[ "$line" =~ ^ok\ [0-9] ]]; then
      ok_count=$(( ok_count + 1 ))
      found=true
    elif [[ "$line" =~ ^not\ ok\ [0-9] ]]; then
      not_ok_count=$(( not_ok_count + 1 ))
      found=true
    fi
  done <<< "$output"

  if [[ "$found" == "true" ]]; then
    local total=$(( ok_count + not_ok_count ))
    echo "${total} ${ok_count} ${not_ok_count}"
  fi
}

# --- Pytest ---

# Parse pytest summary line (e.g., "=== 5 passed, 2 failed in 3.21s ===").
# Echoes "total passed failed" or empty string if no pytest summary found.
_parse_pytest() {
  local output="$1"
  local passed=0
  local failed=0
  local errors=0

  local summary_line
  summary_line="$(grep -E '=+.*passed|=+.*failed|=+.*error' <<< "$output" | tail -1)" || true
  [[ -z "$summary_line" ]] && return 0

  if [[ "$summary_line" =~ ([0-9]+)\ passed ]]; then
    passed="${BASH_REMATCH[1]}"
  fi
  if [[ "$summary_line" =~ ([0-9]+)\ failed ]]; then
    failed="${BASH_REMATCH[1]}"
  fi
  if [[ "$summary_line" =~ ([0-9]+)\ error ]]; then
    errors="${BASH_REMATCH[1]}"
  fi

  local total_failed=$(( failed + errors ))
  local total=$(( passed + total_failed ))
  [[ "$total" -eq 0 ]] && return 0

  echo "${total} ${passed} ${total_failed}"
}

# Parse pytest duration from summary line (e.g., "in 3.21s").
_parse_pytest_duration() {
  local output="$1"
  local summary_line
  summary_line="$(grep -E '=+.*in [0-9]' <<< "$output" | tail -1)" || true
  [[ -z "$summary_line" ]] && return 0

  if [[ "$summary_line" =~ in\ ([0-9]+(\.[0-9]+)?)s ]]; then
    printf '%.0f' "${BASH_REMATCH[1]}"
  fi
}

# --- Jest / Vitest ---

# Parse Jest/Vitest summary (e.g., "Tests: 5 passed, 2 failed, 7 total").
_parse_jest() {
  local output="$1"
  local summary_line
  summary_line="$(grep -E 'Tests:.*total' <<< "$output" | tail -1)" || true
  [[ -z "$summary_line" ]] && return 0

  local total=0 passed=0 failed=0
  if [[ "$summary_line" =~ ([0-9]+)\ passed ]]; then
    passed="${BASH_REMATCH[1]}"
  fi
  if [[ "$summary_line" =~ ([0-9]+)\ failed ]]; then
    failed="${BASH_REMATCH[1]}"
  fi
  if [[ "$summary_line" =~ ([0-9]+)\ total ]]; then
    total="${BASH_REMATCH[1]}"
  fi
  [[ "$total" -eq 0 ]] && return 0
  echo "${total} ${passed} ${failed}"
}

# Parse Jest/Vitest duration (e.g., "Time: 3.42 s").
_parse_jest_duration() {
  local output="$1"
  local time_line
  time_line="$(grep -E '^Time:' <<< "$output" | tail -1)" || true
  [[ -z "$time_line" ]] && return 0

  if [[ "$time_line" =~ Time:\ *([0-9]+(\.[0-9]+)?)\ *s ]]; then
    printf '%.0f' "${BASH_REMATCH[1]}"
  fi
}

# --- RSpec ---

# Parse RSpec summary (e.g., "10 examples, 2 failures").
_parse_rspec() {
  local output="$1"
  local summary_line
  summary_line="$(grep -E '[0-9]+ examples?,.*failure' <<< "$output" | tail -1)" || true
  [[ -z "$summary_line" ]] && return 0

  local total=0 failures=0
  if [[ "$summary_line" =~ ([0-9]+)\ examples? ]]; then
    total="${BASH_REMATCH[1]}"
  fi
  if [[ "$summary_line" =~ ([0-9]+)\ failures? ]]; then
    failures="${BASH_REMATCH[1]}"
  fi
  [[ "$total" -eq 0 ]] && return 0
  local passed=$(( total - failures ))
  echo "${total} ${passed} ${failures}"
}

# Parse RSpec duration (e.g., "Finished in 1.23 seconds").
_parse_rspec_duration() {
  local output="$1"
  local time_line
  time_line="$(grep -E 'Finished in [0-9]' <<< "$output" | tail -1)" || true
  [[ -z "$time_line" ]] && return 0

  if [[ "$time_line" =~ Finished\ in\ ([0-9]+(\.[0-9]+)?)\ seconds? ]]; then
    printf '%.0f' "${BASH_REMATCH[1]}"
  fi
}

# --- Go test ---

# Parse Go test summary. Counts "ok" and "FAIL" package lines.
_parse_go_test() {
  local output="$1"
  local ok_count=0
  local fail_count=0
  local found=false

  while IFS= read -r line; do
    if [[ "$line" =~ ^ok[[:space:]] ]]; then
      ok_count=$(( ok_count + 1 ))
      found=true
    elif [[ "$line" =~ ^FAIL[[:space:]] ]]; then
      fail_count=$(( fail_count + 1 ))
      found=true
    fi
  done <<< "$output"

  if [[ "$found" == "true" ]]; then
    local total=$(( ok_count + fail_count ))
    echo "${total} ${ok_count} ${fail_count}"
  fi
}

# Parse Go test duration from package result lines.
# Accumulates float sum across packages, then rounds once at the end.
_parse_go_test_duration() {
  local output="$1"
  local found=false
  local float_sum="0"

  while IFS= read -r line; do
    if [[ "$line" =~ ^(ok|FAIL)[[:space:]].*[[:space:]]([0-9]+(\.[0-9]+)?)s$ ]]; then
      local secs="${BASH_REMATCH[2]}"
      float_sum="$(awk "BEGIN {printf \"%.3f\", $float_sum + $secs}")"
      found=true
    fi
  done <<< "$output"

  if [[ "$found" == "true" ]]; then
    printf '%.0f' "$float_sum"
  fi
}

# --- Cargo test ---

# Parse cargo test summary (e.g., "test result: ok. 15 passed; 2 failed; 0 ignored").
_parse_cargo_test() {
  local output="$1"
  local summary_line
  summary_line="$(grep -E '^test result:' <<< "$output" | tail -1)" || true
  [[ -z "$summary_line" ]] && return 0

  local passed=0 failed=0
  if [[ "$summary_line" =~ ([0-9]+)\ passed ]]; then
    passed="${BASH_REMATCH[1]}"
  fi
  if [[ "$summary_line" =~ ([0-9]+)\ failed ]]; then
    failed="${BASH_REMATCH[1]}"
  fi
  local total=$(( passed + failed ))
  [[ "$total" -eq 0 ]] && return 0
  echo "${total} ${passed} ${failed}"
}

# Parse cargo test duration (e.g., "finished in 1.23s").
_parse_cargo_test_duration() {
  local output="$1"
  local time_line
  time_line="$(grep -Ei 'finished in [0-9]' <<< "$output" | tail -1)" || true
  [[ -z "$time_line" ]] && return 0

  if [[ "$time_line" =~ [Ff]inished\ in\ ([0-9]+(\.[0-9]+)?)s ]]; then
    printf '%.0f' "${BASH_REMATCH[1]}"
  fi
}

# --- JUnit / Maven ---

# Parse JUnit/Maven summary (e.g., "Tests run: 10, Failures: 2, Errors: 1, Skipped: 0").
_parse_junit() {
  local output="$1"
  local summary_line
  summary_line="$(grep -E 'Tests run:.*Failures:' <<< "$output" | tail -1)" || true
  [[ -z "$summary_line" ]] && return 0

  local total=0 failures=0 errors=0 skipped=0
  if [[ "$summary_line" =~ Tests\ run:\ *([0-9]+) ]]; then
    total="${BASH_REMATCH[1]}"
  fi
  if [[ "$summary_line" =~ Failures:\ *([0-9]+) ]]; then
    failures="${BASH_REMATCH[1]}"
  fi
  if [[ "$summary_line" =~ Errors:\ *([0-9]+) ]]; then
    errors="${BASH_REMATCH[1]}"
  fi
  if [[ "$summary_line" =~ Skipped:\ *([0-9]+) ]]; then
    skipped="${BASH_REMATCH[1]}"
  fi
  [[ "$total" -eq 0 ]] && return 0
  local total_failed=$(( failures + errors ))
  local passed=$(( total - total_failed - skipped ))
  local effective_total=$(( total - skipped ))
  echo "${effective_total} ${passed} ${total_failed}"
}
