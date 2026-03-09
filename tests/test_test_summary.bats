#!/usr/bin/env bats
# Tests for lib/test-summary.sh — test output parsing and summary generation.
# Covers: bats TAP parsing, pytest parsing, timeout detection, formatting.

setup() {
  source "$BATS_TEST_DIRNAME/../lib/test-summary.sh"
}

# --- Timeout Detection ---

@test "is_timeout_exit returns 0 for exit code 124" {
  run is_timeout_exit 124
  [ "$status" -eq 0 ]
}

@test "is_timeout_exit returns 0 for exit code 137" {
  run is_timeout_exit 137
  [ "$status" -eq 0 ]
}

@test "is_timeout_exit returns 1 for exit code 1" {
  run is_timeout_exit 1
  [ "$status" -eq 1 ]
}

@test "is_timeout_exit returns 1 for exit code 0" {
  run is_timeout_exit 0
  [ "$status" -eq 1 ]
}

# --- Bats TAP Parsing ---

@test "_parse_bats_tap counts ok and not ok lines" {
  local output="ok 1 test_foo
ok 2 test_bar
not ok 3 test_baz
ok 4 test_qux"
  run _parse_bats_tap "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "4 3 1" ]
}

@test "_parse_bats_tap returns empty for non-TAP output" {
  local output="Running tests...
All good
Done"
  run _parse_bats_tap "$output"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_parse_bats_tap handles all passing" {
  local output="ok 1 first
ok 2 second
ok 3 third"
  run _parse_bats_tap "$output"
  [ "$output" = "3 3 0" ]
}

@test "_parse_bats_tap handles all failing" {
  local output="not ok 1 first
not ok 2 second"
  run _parse_bats_tap "$output"
  [ "$output" = "2 0 2" ]
}

# --- Pytest Parsing ---

@test "_parse_pytest parses passed and failed counts" {
  local output="===== 10 passed, 2 failed in 3.21s ====="
  run _parse_pytest "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "12 10 2" ]
}

@test "_parse_pytest parses passed only" {
  local output="===== 42 passed in 1.50s ====="
  run _parse_pytest "$output"
  [ "$output" = "42 42 0" ]
}

@test "_parse_pytest parses failed and error counts" {
  local output="===== 5 passed, 3 failed, 1 error in 2.00s ====="
  run _parse_pytest "$output"
  [ "$output" = "9 5 4" ]
}

@test "_parse_pytest returns empty for non-pytest output" {
  local output="Running tests...
Done"
  run _parse_pytest "$output"
  [ -z "$output" ]
}

@test "_parse_pytest_duration extracts seconds" {
  local output="===== 42 passed in 3.21s ====="
  run _parse_pytest_duration "$output"
  [ "$output" = "3" ]
}

@test "_parse_pytest_duration returns empty for no duration" {
  local output="no pytest here"
  run _parse_pytest_duration "$output"
  [ -z "$output" ]
}

# --- format_test_summary ---

@test "format_test_summary produces normal summary" {
  run format_test_summary 100 95 5 "15"
  [ "$output" = "Tests: 100 total, 95 passed, 5 failed (15s)" ]
}

@test "format_test_summary omits duration when zero" {
  run format_test_summary 10 10 0 "0"
  [ "$output" = "Tests: 10 total, 10 passed, 0 failed" ]
}

@test "format_test_summary omits duration when empty" {
  run format_test_summary 10 10 0 ""
  [ "$output" = "Tests: 10 total, 10 passed, 0 failed" ]
}

@test "format_test_summary shows timeout with test count" {
  run format_test_summary 50 0 0 "" "124" "300"
  [ "$output" = "Tests: 50 ran, killed by timeout after 300s" ]
}

@test "format_test_summary shows timeout without test count" {
  run format_test_summary 0 0 0 "" "124" "300"
  [ "$output" = "Tests: killed by timeout after 300s" ]
}

@test "format_test_summary shows timeout for SIGKILL (137)" {
  run format_test_summary 10 0 0 "" "137" "600"
  [ "$output" = "Tests: 10 ran, killed by timeout after 600s" ]
}

# --- parse_test_summary (integration) ---

@test "parse_test_summary parses bats TAP output" {
  local output="1..3
ok 1 test_one
ok 2 test_two
not ok 3 test_three"
  run parse_test_summary "$output" "1" "300"
  [ "$status" -eq 0 ]
  [ "$output" = "Tests: 3 total, 2 passed, 1 failed" ]
}

@test "parse_test_summary parses pytest output" {
  local output="collecting ...
test_foo.py::test_a PASSED
test_foo.py::test_b FAILED
===== 1 passed, 1 failed in 2.50s ====="
  run parse_test_summary "$output" "1" "300"
  [ "$status" -eq 0 ]
  [ "$output" = "Tests: 2 total, 1 passed, 1 failed (2s)" ]
}

@test "parse_test_summary detects timeout with bats output" {
  local output="ok 1 test_one
ok 2 test_two"
  run parse_test_summary "$output" "124" "300"
  [ "$output" = "Tests: 2 ran, killed by timeout after 300s" ]
}

@test "parse_test_summary detects timeout with no parseable output" {
  local output="Starting tests..."
  run parse_test_summary "$output" "124" "300"
  [ "$output" = "Tests: killed by timeout after 300s" ]
}

@test "parse_test_summary returns empty for empty output" {
  run parse_test_summary "" "0" "300"
  [ -z "$output" ]
}

@test "parse_test_summary returns empty for unparseable non-timeout output" {
  run parse_test_summary "some random log" "1" "300"
  [ -z "$output" ]
}

@test "parse_test_summary with large bats output" {
  local output=""
  local i
  for (( i=1; i<=100; i++ )); do
    output="${output}ok ${i} test_number_${i}
"
  done
  output="${output}not ok 101 test_failure"
  run parse_test_summary "$output" "1" "300"
  [ "$output" = "Tests: 101 total, 100 passed, 1 failed" ]
}
