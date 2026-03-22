#!/usr/bin/env bats
# Tests for lib/gh.sh — _run_with_stderr_capture under set -u (nounset).
# Guards against unbound variable regressions like the RETURN trap leak (task 177).

BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/gh.sh"

setup_file() { _create_test_template; }
teardown_file() { _cleanup_test_template; }

setup() {
  _init_test_from_template_nogit
  load_config "$TEST_PROJECT_DIR"
  # Use a per-test temp dir so cleanup checks are fast and isolated.
  _TEST_TMPDIR="$BATS_TEST_TMPDIR/tmpdir"
  mkdir -p "$_TEST_TMPDIR"
  export TMPDIR="$_TEST_TMPDIR"
}

# --- _run_with_stderr_capture under set -u ---

@test "_run_with_stderr_capture caller does not crash under set -u after function returns" {
  set -u
  _run_with_stderr_capture "$TEST_PROJECT_DIR" true
  # If set -u triggers an unbound variable error, this line is never reached.
  local _after_call="survived"
  [ "$_after_call" = "survived" ]
}

@test "_run_with_stderr_capture cleans up temp file on success" {
  set -u
  _run_with_stderr_capture "$TEST_PROJECT_DIR" true
  # No leftover temp files in our isolated TMPDIR.
  local _remaining
  _remaining="$(find "$_TEST_TMPDIR" -name 'autopilot-stderr-err.*' | wc -l)"
  [ "$_remaining" -eq 0 ]
}

@test "_run_with_stderr_capture cleans up temp file on failure" {
  set -u
  _run_with_stderr_capture "$TEST_PROJECT_DIR" false || true
  local _remaining
  _remaining="$(find "$_TEST_TMPDIR" -name 'autopilot-stderr-err.*' | wc -l)"
  [ "$_remaining" -eq 0 ]
}

@test "_run_with_stderr_capture logs stderr on command failure" {
  set -u
  # Create a command that writes to stderr and fails.
  cat > "$TEST_MOCK_BIN/fail_with_stderr" << 'MOCK'
#!/usr/bin/env bash
echo "something went wrong" >&2
exit 1
MOCK
  chmod +x "$TEST_MOCK_BIN/fail_with_stderr"

  _run_with_stderr_capture "$TEST_PROJECT_DIR" fail_with_stderr || true

  local _log_content
  _log_content="$(<"$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$_log_content" == *"something went wrong"* ]]
}
