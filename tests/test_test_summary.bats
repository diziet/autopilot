#!/usr/bin/env bats
# Tests for lib/test-summary.sh — test output parsing and summary generation.
# Covers: all framework parsers, timeout detection, formatting, fallback.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/test-summary.sh"

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

# --- Jest/Vitest Parsing ---

@test "_parse_jest parses passed and failed" {
  local output="Test Suites: 2 passed, 2 total
Tests:       5 passed, 2 failed, 7 total
Time:        3.42 s"
  run _parse_jest "$output"
  [ "$output" = "7 5 2" ]
}

@test "_parse_jest parses all passing" {
  local output="Tests:       10 passed, 10 total
Time:        1.23 s"
  run _parse_jest "$output"
  [ "$output" = "10 10 0" ]
}

@test "_parse_jest returns empty for non-jest output" {
  local output="Running tests...
Done"
  run _parse_jest "$output"
  [ -z "$output" ]
}

@test "_parse_jest_duration extracts seconds" {
  local output="Time:        3.42 s"
  run _parse_jest_duration "$output"
  [ "$output" = "3" ]
}

@test "_parse_jest_duration returns empty for no duration" {
  local output="no jest here"
  run _parse_jest_duration "$output"
  [ -z "$output" ]
}

# --- RSpec Parsing ---

@test "_parse_rspec parses examples and failures" {
  local output="Finished in 1.23 seconds (files took 0.5 seconds to load)
10 examples, 2 failures"
  run _parse_rspec "$output"
  [ "$output" = "10 8 2" ]
}

@test "_parse_rspec parses all passing" {
  local output="Finished in 0.5 seconds
5 examples, 0 failures"
  run _parse_rspec "$output"
  [ "$output" = "5 5 0" ]
}

@test "_parse_rspec handles singular example" {
  local output="1 example, 0 failures"
  run _parse_rspec "$output"
  [ "$output" = "1 1 0" ]
}

@test "_parse_rspec returns empty for non-rspec output" {
  local output="Running tests..."
  run _parse_rspec "$output"
  [ -z "$output" ]
}

@test "_parse_rspec_duration extracts seconds" {
  local output="Finished in 1.23 seconds"
  run _parse_rspec_duration "$output"
  [ "$output" = "1" ]
}

@test "_parse_rspec_duration returns empty for no duration" {
  local output="no rspec here"
  run _parse_rspec_duration "$output"
  [ -z "$output" ]
}

# --- Go test Parsing ---

@test "_parse_go_test counts ok and FAIL packages" {
  local output="ok  	github.com/foo/pkg1	0.123s
ok  	github.com/foo/pkg2	0.456s
FAIL	github.com/foo/pkg3	0.789s"
  run _parse_go_test "$output"
  [ "$output" = "3 2 1" ]
}

@test "_parse_go_test all passing" {
  local output="ok  	github.com/foo/pkg1	0.100s
ok  	github.com/foo/pkg2	0.200s"
  run _parse_go_test "$output"
  [ "$output" = "2 2 0" ]
}

@test "_parse_go_test returns empty for non-go output" {
  local output="Running tests..."
  run _parse_go_test "$output"
  [ -z "$output" ]
}

@test "_parse_go_test_duration sums package durations" {
  local output="ok  	github.com/foo/pkg1	1.5s
ok  	github.com/foo/pkg2	2.3s"
  run _parse_go_test_duration "$output"
  # 1.5 rounds to 2, 2.3 rounds to 2, sum = 4
  [ "$output" = "4" ]
}

@test "_parse_go_test_duration returns empty for no duration" {
  local output="no go here"
  run _parse_go_test_duration "$output"
  [ -z "$output" ]
}

# --- Cargo test Parsing ---

@test "_parse_cargo_test parses passed and failed" {
  local output="running 17 tests
test foo ... ok
test bar ... FAILED
test result: ok. 15 passed; 2 failed; 0 ignored; 0 measured; 0 filtered out; finished in 1.23s"
  run _parse_cargo_test "$output"
  [ "$output" = "17 15 2" ]
}

@test "_parse_cargo_test all passing" {
  local output="test result: ok. 10 passed; 0 failed; 0 ignored"
  run _parse_cargo_test "$output"
  [ "$output" = "10 10 0" ]
}

@test "_parse_cargo_test returns empty for non-cargo output" {
  local output="Running tests..."
  run _parse_cargo_test "$output"
  [ -z "$output" ]
}

@test "_parse_cargo_test_duration extracts seconds" {
  local output="test result: ok. 10 passed; 0 failed; finished in 1.23s"
  run _parse_cargo_test_duration "$output"
  [ "$output" = "1" ]
}

@test "_parse_cargo_test_duration returns empty for no duration" {
  local output="no cargo here"
  run _parse_cargo_test_duration "$output"
  [ -z "$output" ]
}

# --- JUnit/Maven Parsing ---

@test "_parse_junit parses run, failures, errors, skipped" {
  local output="Tests run: 10, Failures: 2, Errors: 1, Skipped: 1"
  run _parse_junit "$output"
  # total=10, failed=2+1=3, passed=10-3-1=6
  [ "$output" = "10 6 3" ]
}

@test "_parse_junit all passing" {
  local output="Tests run: 25, Failures: 0, Errors: 0, Skipped: 0"
  run _parse_junit "$output"
  [ "$output" = "25 25 0" ]
}

@test "_parse_junit returns empty for non-junit output" {
  local output="Running tests..."
  run _parse_junit "$output"
  [ -z "$output" ]
}

# --- format_test_summary ---

@test "format_test_summary produces normal summary" {
  run format_test_summary 100 95 5 "15"
  [ "$output" = "Tests: 100 total, 95 passed, 5 failed in 15s" ]
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

# --- _detect_framework_from_cmd ---

@test "_detect_framework_from_cmd detects bats" {
  run _detect_framework_from_cmd "bats tests/"
  [ "$output" = "bats" ]
}

@test "_detect_framework_from_cmd detects pytest" {
  run _detect_framework_from_cmd "pytest -p no:cov"
  [ "$output" = "pytest" ]
}

@test "_detect_framework_from_cmd detects jest via npx" {
  run _detect_framework_from_cmd "npx jest"
  [ "$output" = "jest" ]
}

@test "_detect_framework_from_cmd detects vitest" {
  run _detect_framework_from_cmd "npx vitest"
  [ "$output" = "jest" ]
}

@test "_detect_framework_from_cmd detects rspec" {
  run _detect_framework_from_cmd "bundle exec rspec"
  [ "$output" = "rspec" ]
}

@test "_detect_framework_from_cmd detects go test" {
  run _detect_framework_from_cmd "go test ./..."
  [ "$output" = "go" ]
}

@test "_detect_framework_from_cmd detects cargo test" {
  run _detect_framework_from_cmd "cargo test"
  [ "$output" = "cargo" ]
}

@test "_detect_framework_from_cmd detects maven" {
  run _detect_framework_from_cmd "mvn test"
  [ "$output" = "junit" ]
}

@test "_detect_framework_from_cmd detects gradlew" {
  run _detect_framework_from_cmd "./gradlew test"
  [ "$output" = "junit" ]
}

@test "_detect_framework_from_cmd returns empty for npm test" {
  run _detect_framework_from_cmd "npm test"
  [ -z "$output" ]
}

@test "_detect_framework_from_cmd returns empty for unknown" {
  run _detect_framework_from_cmd "make check"
  [ -z "$output" ]
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
  [ "$output" = "Tests: 2 total, 1 passed, 1 failed in 2s" ]
}

@test "parse_test_summary parses jest output" {
  local output="PASS src/foo.test.js
Tests:       5 passed, 2 failed, 7 total
Time:        3.42 s"
  run parse_test_summary "$output" "1" "300"
  [ "$output" = "Tests: 7 total, 5 passed, 2 failed in 3s" ]
}

@test "parse_test_summary parses rspec output" {
  local output="Finished in 1.23 seconds
10 examples, 2 failures"
  run parse_test_summary "$output" "1" "300"
  [ "$output" = "Tests: 10 total, 8 passed, 2 failed in 1s" ]
}

@test "parse_test_summary parses go test output" {
  local output="ok  	github.com/foo/pkg1	0.123s
FAIL	github.com/foo/pkg2	0.456s"
  run parse_test_summary "$output" "1" "300"
  [ "$output" = "Tests: 2 total, 1 passed, 1 failed" ]
}

@test "parse_test_summary parses cargo test output" {
  local output="test result: ok. 15 passed; 2 failed; 0 ignored; finished in 1.23s"
  run parse_test_summary "$output" "1" "300"
  [ "$output" = "Tests: 17 total, 15 passed, 2 failed in 1s" ]
}

@test "parse_test_summary parses junit output" {
  local output="Tests run: 10, Failures: 2, Errors: 0, Skipped: 0"
  run parse_test_summary "$output" "1" "300"
  [ "$output" = "Tests: 10 total, 8 passed, 2 failed" ]
}

@test "parse_test_summary uses test_cmd hint for parser selection" {
  local output="test result: ok. 5 passed; 0 failed; 0 ignored"
  run parse_test_summary "$output" "0" "300" "" "cargo test"
  [ "$output" = "Tests: 5 total, 5 passed, 0 failed" ]
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

@test "parse_test_summary shows fallback for unparseable non-timeout output" {
  run parse_test_summary "some random log" "1" "300"
  [ "$output" = "Tests: completed (no structured output detected)" ]
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
