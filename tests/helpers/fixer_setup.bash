# Shared setup/teardown for fixer test files.
# Provides: setup_file, teardown_file, setup, teardown.
# Usage: load helpers/fixer_setup

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/fixer.sh"

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  # Template provides: TEST_PROJECT_DIR with .autopilot/{state.json,logs/,locks/}.
  # See _build_global_template in test_template.bash for the template contract.
  _init_test_from_template_nogit
  TEST_HOOKS_DIR="$BATS_TEST_TMPDIR/hooks"
  mkdir -p "$TEST_HOOKS_DIR"
  load_config "$TEST_PROJECT_DIR"
  _FIXER_PROMPTS_DIR="$BATS_TEST_DIRNAME/../prompts"
}

teardown() {
  # Clean up any function mocks.
  unset -f claude gh timeout build_fixer_prompt sleep 2>/dev/null || true
  # Remove temp output files.
  rm -f "$BATS_TEST_TMPDIR"/fixer-out* "$BATS_TEST_TMPDIR"/fixer-output* 2>/dev/null || true
}

# Set up mocks for session resume fallback tests.
# First real Claude call fails with "No conversation found", second succeeds.
# Args: stale_session_id success_json
_setup_session_fallback_mocks() {
  local stale_session_id="$1"
  local success_json="$2"
  local call_counter="$BATS_TEST_TMPDIR/claude_call_count"
  echo "0" > "$call_counter"

  eval "claude() {
    for a in \"\$@\"; do
      if [ \"\$a\" = 'echo ok' ]; then echo ok; return 0; fi
    done
    local count=\$(cat \"$call_counter\")
    count=\$((count + 1))
    echo \"\$count\" > \"$call_counter\"
    if [ \"\$count\" -eq 1 ]; then
      echo 'No conversation found with session ID: ${stale_session_id}' >&2
      return 1
    fi
    echo '${success_json}'
  }"
  export -f claude

  gh() { echo '[]'; }
  export -f gh

  timeout() { shift; "$@"; }
  export -f timeout

  sleep() { :; }
  export -f sleep

  AUTOPILOT_CLAUDE_CMD="claude"
  AUTOPILOT_TIMEOUT_FIXER=10
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"
}
