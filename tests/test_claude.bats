#!/usr/bin/env bats
# Tests for lib/claude.sh — Claude invocation helpers.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/claude.sh"

setup_file() { _create_test_template; }
teardown_file() { _cleanup_test_template; }

setup() {
  _init_test_from_template_nogit
  load_config "$TEST_PROJECT_DIR"

  # Mock timeout to just run the command directly.
  # Tests needing real timeout (e.g. "times out long-running commands") call unset -f timeout.
  timeout() { shift; "$@"; }
  export -f timeout
}

teardown() {
  # Clean up any function mocks.
  unset -f claude timeout 2>/dev/null || true
}

# --- _build_base_cmd_args: shared helper ---

@test "_build_base_cmd_args populates array with default command" {
  local -a _BASE_CMD_ARGS=()
  _build_base_cmd_args
  [ "${_BASE_CMD_ARGS[0]}" = "claude" ]
  [ "${_BASE_CMD_ARGS[1]}" = "--model" ]
  [ "${_BASE_CMD_ARGS[2]}" = "opus" ]
  [ "${_BASE_CMD_ARGS[3]}" = "--output-format" ]
  [ "${_BASE_CMD_ARGS[4]}" = "json" ]
  [ "${#_BASE_CMD_ARGS[@]}" -eq 5 ]
}

@test "_build_base_cmd_args uses AUTOPILOT_CLAUDE_CMD" {
  AUTOPILOT_CLAUDE_CMD="/usr/local/bin/claude-custom"
  local -a _BASE_CMD_ARGS=()
  _build_base_cmd_args
  [ "${_BASE_CMD_ARGS[0]}" = "/usr/local/bin/claude-custom" ]
}

@test "_build_base_cmd_args includes flags as separate array elements" {
  AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions --verbose"
  local -a _BASE_CMD_ARGS=()
  _build_base_cmd_args
  [ "${_BASE_CMD_ARGS[0]}" = "claude" ]
  [ "${_BASE_CMD_ARGS[1]}" = "--dangerously-skip-permissions" ]
  [ "${_BASE_CMD_ARGS[2]}" = "--verbose" ]
  [ "${_BASE_CMD_ARGS[3]}" = "--model" ]
  [ "${_BASE_CMD_ARGS[4]}" = "opus" ]
  [ "${_BASE_CMD_ARGS[5]}" = "--output-format" ]
  [ "${_BASE_CMD_ARGS[6]}" = "json" ]
}

@test "_build_base_cmd_args does not glob-expand flags" {
  # Create files that would match glob patterns.
  touch "$TEST_PROJECT_DIR/star_test_file.txt"
  cd "$TEST_PROJECT_DIR"
  AUTOPILOT_CLAUDE_FLAGS="--pattern *"
  local -a _BASE_CMD_ARGS=()
  _build_base_cmd_args
  # The * should be literal, not expanded to filenames.
  [ "${_BASE_CMD_ARGS[1]}" = "--pattern" ]
  [ "${_BASE_CMD_ARGS[2]}" = "*" ]
  [ "${_BASE_CMD_ARGS[3]}" = "--model" ]
  cd - > /dev/null
}

@test "_build_base_cmd_args uses AUTOPILOT_CLAUDE_OUTPUT_FORMAT" {
  AUTOPILOT_CLAUDE_OUTPUT_FORMAT="text"
  local -a _BASE_CMD_ARGS=()
  _build_base_cmd_args
  [ "${_BASE_CMD_ARGS[3]}" = "--output-format" ]
  [ "${_BASE_CMD_ARGS[4]}" = "text" ]
}

# --- _build_base_cmd_args: model flag ---

@test "_build_base_cmd_args includes model flag when AUTOPILOT_CLAUDE_MODEL is set" {
  AUTOPILOT_CLAUDE_MODEL="sonnet"
  local -a _BASE_CMD_ARGS=()
  _build_base_cmd_args
  [ "${_BASE_CMD_ARGS[0]}" = "claude" ]
  [ "${_BASE_CMD_ARGS[1]}" = "--model" ]
  [ "${_BASE_CMD_ARGS[2]}" = "sonnet" ]
  [ "${_BASE_CMD_ARGS[3]}" = "--output-format" ]
  [ "${_BASE_CMD_ARGS[4]}" = "json" ]
}

@test "_build_base_cmd_args omits model flag when AUTOPILOT_CLAUDE_MODEL is empty" {
  AUTOPILOT_CLAUDE_MODEL=""
  local -a _BASE_CMD_ARGS=()
  _build_base_cmd_args
  [ "${_BASE_CMD_ARGS[0]}" = "claude" ]
  [ "${_BASE_CMD_ARGS[1]}" = "--output-format" ]
  [ "${_BASE_CMD_ARGS[2]}" = "json" ]
  [ "${#_BASE_CMD_ARGS[@]}" -eq 3 ]
}

@test "_build_base_cmd_args model override via env var" {
  # Write a config file with model set to "haiku".
  echo 'AUTOPILOT_CLAUDE_MODEL="haiku"' > "$TEST_PROJECT_DIR/autopilot.conf"
  # Set env var to "sonnet" — env should win.
  export AUTOPILOT_CLAUDE_MODEL="sonnet"
  load_config "$TEST_PROJECT_DIR"
  local -a _BASE_CMD_ARGS=()
  _build_base_cmd_args
  [ "${_BASE_CMD_ARGS[1]}" = "--model" ]
  [ "${_BASE_CMD_ARGS[2]}" = "sonnet" ]
}

# --- build_claude_cmd: defaults ---

@test "build_claude_cmd returns default command with model and json format" {
  local result
  result="$(build_claude_cmd)"
  [[ "$result" == "claude --model opus --output-format json" ]]
}

@test "build_claude_cmd uses AUTOPILOT_CLAUDE_CMD" {
  AUTOPILOT_CLAUDE_CMD="/usr/local/bin/claude-custom"
  local result
  result="$(build_claude_cmd)"
  [[ "$result" == "/usr/local/bin/claude-custom --model opus --output-format json" ]]
}

@test "build_claude_cmd uses AUTOPILOT_CLAUDE_OUTPUT_FORMAT" {
  AUTOPILOT_CLAUDE_OUTPUT_FORMAT="text"
  local result
  result="$(build_claude_cmd)"
  [[ "$result" == "claude --model opus --output-format text" ]]
}

# --- build_claude_cmd: flags ---

@test "build_claude_cmd includes AUTOPILOT_CLAUDE_FLAGS" {
  AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions"
  local result
  result="$(build_claude_cmd)"
  [[ "$result" == "claude --dangerously-skip-permissions --model opus --output-format json" ]]
}

@test "build_claude_cmd handles multiple flags" {
  AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions --verbose"
  local result
  result="$(build_claude_cmd)"
  [[ "$result" == "claude --dangerously-skip-permissions --verbose --model opus --output-format json" ]]
}

@test "build_claude_cmd with empty flags omits extra spaces" {
  AUTOPILOT_CLAUDE_FLAGS=""
  local result
  result="$(build_claude_cmd)"
  [[ "$result" == "claude --model opus --output-format json" ]]
}

# --- extract_claude_text: from stdin ---

@test "extract_claude_text extracts result from JSON stdin" {
  local result
  result="$(echo '{"result":"Hello world","cost_usd":0.01}' | extract_claude_text)"
  [ "$result" = "Hello world" ]
}

@test "extract_claude_text handles multiline result" {
  local json='{"result":"line one\nline two\nline three"}'
  local result
  result="$(echo "$json" | extract_claude_text)"
  [[ "$result" == *"line one"* ]]
  [[ "$result" == *"line two"* ]]
}

@test "extract_claude_text returns empty and fails on missing result field" {
  local result
  run bash -c 'source "'"$BATS_TEST_DIRNAME"'/../lib/claude.sh"; echo "{\"cost_usd\":0.01}" | extract_claude_text'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "extract_claude_text returns empty and fails on empty input" {
  run bash -c 'source "'"$BATS_TEST_DIRNAME"'/../lib/claude.sh"; echo "" | extract_claude_text'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "extract_claude_text returns empty and fails on invalid JSON" {
  run bash -c 'source "'"$BATS_TEST_DIRNAME"'/../lib/claude.sh"; echo "not json" | extract_claude_text'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# --- extract_claude_text: from file ---

@test "extract_claude_text extracts result from file" {
  local tmp_file
  tmp_file="$BATS_TEST_TMPDIR/claude_output.json"
  echo '{"result":"File content here","is_error":false}' > "$tmp_file"
  local result
  result="$(extract_claude_text "$tmp_file")"
  [ "$result" = "File content here" ]
}

@test "extract_claude_text returns empty and fails for nonexistent file" {
  run extract_claude_text "/nonexistent/path/file.json"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "extract_claude_text returns empty and fails for empty file" {
  local tmp_file
  tmp_file="$BATS_TEST_TMPDIR/empty_output.json"
  : > "$tmp_file"
  run extract_claude_text "$tmp_file"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "extract_claude_text handles result with special characters" {
  local json='{"result":"path/to/file.sh: line 42 - error \"unexpected\""}'
  local result
  result="$(echo "$json" | extract_claude_text)"
  [[ "$result" == *"path/to/file.sh"* ]]
  [[ "$result" == *"line 42"* ]]
}

@test "extract_claude_text handles null result field" {
  run bash -c 'source "'"$BATS_TEST_DIRNAME"'/../lib/claude.sh"; echo "{\"result\":null}" | extract_claude_text'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# --- run_claude: basic execution ---

@test "run_claude unsets CLAUDECODE in subprocess" {
  # Mock claude that checks CLAUDECODE is unset.
  claude() {
    if [[ -n "${CLAUDECODE:-}" ]]; then
      echo '{"result":"CLAUDECODE was set","is_error":true}'
      return 1
    fi
    echo '{"result":"CLAUDECODE was unset","is_error":false}'
  }
  export -f claude

  AUTOPILOT_CLAUDE_CMD="claude"
  export CLAUDECODE="should-be-unset"

  # Mock timeout to pass through.


  local output_file
  output_file="$(run_claude 10 "test prompt")" || true

  local content
  content="$(cat "$output_file")"
  [[ "$content" == *"CLAUDECODE was unset"* ]]
  rm -f "$output_file" "${output_file}.err"
}

@test "run_claude passes prompt via --print flag" {
  claude() {
    echo '{"result":"args: '"$*"'","is_error":false}'
  }
  export -f claude



  AUTOPILOT_CLAUDE_CMD="claude"

  local output_file
  output_file="$(run_claude 10 "hello world")" || true

  local content
  content="$(cat "$output_file")"
  [[ "$content" == *"--print"* ]]
  [[ "$content" == *"hello world"* ]]
  rm -f "$output_file" "${output_file}.err"
}

@test "run_claude outputs file path to stdout" {
  claude() {
    echo '{"result":"ok"}'
  }
  export -f claude



  AUTOPILOT_CLAUDE_CMD="claude"

  local output_file
  output_file="$(run_claude 10 "test")" || true

  [ -f "$output_file" ]
  rm -f "$output_file" "${output_file}.err"
}

@test "run_claude returns claude exit code on success" {
  claude() {
    echo '{"result":"success"}'
    return 0
  }
  export -f claude



  AUTOPILOT_CLAUDE_CMD="claude"

  local output_file
  output_file="$(run_claude 10 "test")"
  local code=$?
  [ "$code" -eq 0 ]
  rm -f "$output_file" "${output_file}.err"
}

@test "run_claude returns claude exit code on failure" {
  claude() {
    echo '{"result":"error","is_error":true}'
    return 1
  }
  export -f claude



  AUTOPILOT_CLAUDE_CMD="claude"

  local output_file exit_code=0
  output_file="$(run_claude 10 "test")" || exit_code=$?
  [ "$exit_code" -eq 1 ]
  rm -f "$output_file" "${output_file}.err"
}

# --- run_claude: stderr separation ---

@test "run_claude separates stdout from stderr" {
  claude() {
    echo '{"result":"clean json"}' >&1
    echo "warning: something happened" >&2
  }
  export -f claude



  AUTOPILOT_CLAUDE_CMD="claude"

  local output_file
  output_file="$(run_claude 10 "test")" || true

  # stdout file should contain only clean JSON.
  local stdout_content
  stdout_content="$(cat "$output_file")"
  [[ "$stdout_content" == '{"result":"clean json"}' ]]

  # stderr file should contain the warning.
  local stderr_content
  stderr_content="$(cat "${output_file}.err")"
  [[ "$stderr_content" == *"warning: something happened"* ]]

  rm -f "$output_file" "${output_file}.err"
}

@test "run_claude stderr does not corrupt JSON extraction" {
  claude() {
    echo "deprecation notice: use new API" >&2
    echo '{"result":"valid response","cost_usd":0.01}'
  }
  export -f claude



  AUTOPILOT_CLAUDE_CMD="claude"

  local output_file
  output_file="$(run_claude 10 "test")" || true

  # extract_claude_text should succeed because stderr is separate.
  local text
  text="$(extract_claude_text "$output_file")"
  [ "$text" = "valid response" ]

  rm -f "$output_file" "${output_file}.err"
}

# --- run_claude: config_dir ---

@test "run_claude sets CLAUDE_CONFIG_DIR when config_dir provided" {
  claude() {
    echo "{\"result\":\"config_dir=${CLAUDE_CONFIG_DIR:-unset}\"}"
  }
  export -f claude



  AUTOPILOT_CLAUDE_CMD="claude"

  local output_file
  output_file="$(run_claude 10 "test" "/custom/config")" || true

  local content
  content="$(cat "$output_file")"
  [[ "$content" == *"config_dir=/custom/config"* ]]
  rm -f "$output_file" "${output_file}.err"
}

@test "run_claude does not set CLAUDE_CONFIG_DIR when config_dir empty" {
  # Unset any existing CLAUDE_CONFIG_DIR.
  unset CLAUDE_CONFIG_DIR

  claude() {
    echo "{\"result\":\"config_dir=${CLAUDE_CONFIG_DIR:-unset}\"}"
  }
  export -f claude



  AUTOPILOT_CLAUDE_CMD="claude"

  local output_file
  output_file="$(run_claude 10 "test" "")" || true

  local content
  content="$(cat "$output_file")"
  [[ "$content" == *"config_dir=unset"* ]]
  rm -f "$output_file" "${output_file}.err"
}

# --- run_claude: timeout ---

@test "run_claude times out long-running commands" {
  # Need the REAL timeout command for this test — remove mock from PATH.
  unset -f timeout
  PATH="${PATH//${_TEMPLATE_MOCK_DIR}:/}"

  local mock_dir
  mock_dir="$BATS_TEST_TMPDIR/mock_dir"
  mkdir -p "$mock_dir"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
sleep 30
echo '{"result":"should not reach here"}'
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  local output_file exit_code=0
  output_file="$(run_claude 1 "test")" || exit_code=$?

  # timeout returns 124 on GNU coreutils.
  [ "$exit_code" -eq 124 ]
  rm -f "$output_file" "${output_file}.err"
}

# --- run_claude: output format ---

@test "run_claude passes output format flag" {
  claude() {
    for arg in "$@"; do
      echo "arg: $arg"
    done
  }
  export -f claude



  AUTOPILOT_CLAUDE_CMD="claude"
  AUTOPILOT_CLAUDE_OUTPUT_FORMAT="stream-json"

  local output_file
  output_file="$(run_claude 10 "test")" || true

  local content
  content="$(cat "$output_file")"
  [[ "$content" == *"arg: --output-format"* ]]
  [[ "$content" == *"arg: stream-json"* ]]
  rm -f "$output_file" "${output_file}.err"
}

# --- run_claude: extra arguments ---

@test "run_claude passes extra arguments to claude" {
  claude() {
    for arg in "$@"; do
      echo "arg: $arg"
    done
  }
  export -f claude



  AUTOPILOT_CLAUDE_CMD="claude"

  local output_file
  output_file="$(run_claude 10 "test" "" "--resume" "session123")" || true

  local content
  content="$(cat "$output_file")"
  [[ "$content" == *"arg: --resume"* ]]
  [[ "$content" == *"arg: session123"* ]]
  rm -f "$output_file" "${output_file}.err"
}

# --- run_claude: flags from config ---

@test "run_claude includes AUTOPILOT_CLAUDE_FLAGS" {
  claude() {
    for arg in "$@"; do
      echo "arg: $arg"
    done
  }
  export -f claude



  AUTOPILOT_CLAUDE_CMD="claude"
  AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions"

  local output_file
  output_file="$(run_claude 10 "test")" || true

  local content
  content="$(cat "$output_file")"
  [[ "$content" == *"arg: --dangerously-skip-permissions"* ]]
  rm -f "$output_file" "${output_file}.err"
}

# --- Integration: run_claude + extract_claude_text ---

@test "run_claude output can be parsed by extract_claude_text" {
  claude() {
    echo '{"result":"integration test passed","cost_usd":0.005}'
  }
  export -f claude



  AUTOPILOT_CLAUDE_CMD="claude"

  local output_file
  output_file="$(run_claude 10 "test")" || true

  local text
  text="$(extract_claude_text "$output_file")"
  [ "$text" = "integration test passed" ]
  rm -f "$output_file" "${output_file}.err"
}

# --- check_claude_auth: authentication probe ---

@test "check_claude_auth returns 0 when claude succeeds" {
  claude() {
    echo "ok"
    return 0
  }
  export -f claude



  AUTOPILOT_CLAUDE_CMD="claude"
  AUTOPILOT_TIMEOUT_AUTH_CHECK=5

  check_claude_auth ""
}

@test "check_claude_auth returns 1 when claude fails" {
  claude() {
    echo "auth error" >&2
    return 1
  }
  export -f claude



  AUTOPILOT_CLAUDE_CMD="claude"
  AUTOPILOT_TIMEOUT_AUTH_CHECK=5

  run check_claude_auth ""
  [ "$status" -ne 0 ]
}

@test "check_claude_auth sets CLAUDE_CONFIG_DIR when provided" {
  claude() {
    if [[ "$CLAUDE_CONFIG_DIR" == "/test/config" ]]; then
      return 0
    fi
    return 1
  }
  export -f claude



  AUTOPILOT_CLAUDE_CMD="claude"
  AUTOPILOT_TIMEOUT_AUTH_CHECK=5

  check_claude_auth "/test/config"
}

@test "check_claude_auth times out on hung claude" {
  # Need the REAL timeout command for this test — remove mock from PATH.
  unset -f timeout
  PATH="${PATH//${_TEMPLATE_MOCK_DIR}:/}"

  local mock_dir
  mock_dir="$BATS_TEST_TMPDIR/auth_mock_dir"
  mkdir -p "$mock_dir"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
sleep 30
MOCK
  chmod +x "$mock_dir/claude"
  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"
  AUTOPILOT_TIMEOUT_AUTH_CHECK=1

  run check_claude_auth ""
  [ "$status" -ne 0 ]
}

# --- _extract_account_number ---

@test "_extract_account_number extracts 1 from account1 path" {
  local result
  result="$(_extract_account_number "$HOME/.claude-account1")"
  [ "$result" = "1" ]
}

@test "_extract_account_number extracts 2 from account2 path" {
  local result
  result="$(_extract_account_number "$HOME/.claude-account2")"
  [ "$result" = "2" ]
}

@test "_extract_account_number fails on non-account path" {
  run _extract_account_number "/some/other/path"
  [ "$status" -ne 0 ]
}

# --- _get_alternate_config_dir ---

@test "_get_alternate_config_dir swaps account1 to account2" {
  local result
  result="$(_get_alternate_config_dir "$HOME/.claude-account1")"
  [ "$result" = "$HOME/.claude-account2" ]
}

@test "_get_alternate_config_dir swaps account2 to account1" {
  local result
  result="$(_get_alternate_config_dir "$HOME/.claude-account2")"
  [ "$result" = "$HOME/.claude-account1" ]
}

@test "_get_alternate_config_dir fails on non-account path" {
  run _get_alternate_config_dir "/some/other/path"
  [ "$status" -ne 0 ]
}

# --- resolve_config_dir_with_fallback ---

@test "resolve_config_dir_with_fallback returns primary on auth success" {
  claude() {
    return 0
  }
  export -f claude



  AUTOPILOT_CLAUDE_CMD="claude"
  AUTOPILOT_TIMEOUT_AUTH_CHECK=5
  init_pipeline "$TEST_PROJECT_DIR"

  local result
  result="$(resolve_config_dir_with_fallback \
    "$HOME/.claude-account1" "coder" "$TEST_PROJECT_DIR")"
  [ "$result" = "$HOME/.claude-account1" ]
}

@test "resolve_config_dir_with_fallback falls back to account2 on account1 failure" {
  # Mock that fails for account1 but succeeds for account2.
  claude() {
    if [[ "$CLAUDE_CONFIG_DIR" == *"account1"* ]]; then
      return 1
    fi
    return 0
  }
  export -f claude



  AUTOPILOT_CLAUDE_CMD="claude"
  AUTOPILOT_TIMEOUT_AUTH_CHECK=5
  AUTOPILOT_AUTH_FALLBACK="true"
  init_pipeline "$TEST_PROJECT_DIR"

  local result
  result="$(resolve_config_dir_with_fallback \
    "$HOME/.claude-account1" "coder" "$TEST_PROJECT_DIR")"
  [ "$result" = "$HOME/.claude-account2" ]
}

@test "resolve_config_dir_with_fallback creates PAUSE when both accounts fail" {
  claude() {
    return 1
  }
  export -f claude



  AUTOPILOT_CLAUDE_CMD="claude"
  AUTOPILOT_TIMEOUT_AUTH_CHECK=5
  AUTOPILOT_AUTH_FALLBACK="true"
  init_pipeline "$TEST_PROJECT_DIR"

  run resolve_config_dir_with_fallback \
    "$HOME/.claude-account1" "coder" "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
  [ -f "$TEST_PROJECT_DIR/.autopilot/PAUSE" ]
}

@test "resolve_config_dir_with_fallback fails without fallback on auth failure" {
  claude() {
    return 1
  }
  export -f claude



  AUTOPILOT_CLAUDE_CMD="claude"
  AUTOPILOT_TIMEOUT_AUTH_CHECK=5
  AUTOPILOT_AUTH_FALLBACK="false"
  init_pipeline "$TEST_PROJECT_DIR"

  run resolve_config_dir_with_fallback \
    "$HOME/.claude-account1" "coder" "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
  # PAUSE file should NOT be created when fallback is disabled.
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/PAUSE" ]
}

# --- _log_agent_result: session ID logging ---

@test "_log_agent_result logs session ID after agent completes successfully" {
  init_pipeline "$TEST_PROJECT_DIR"
  local output_file="$BATS_TEST_TMPDIR/agent_output.json"
  echo '{"result":"done","session_id":"sess-abc-123"}' > "$output_file"

  _log_agent_result "$TEST_PROJECT_DIR" "Coder" "42" "0" "$output_file"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"Coder completed task 42"* ]]
  [[ "$log_content" == *"Session ID for Coder task 42: sess-abc-123"* ]]
}

@test "_log_agent_result logs session ID after agent times out" {
  init_pipeline "$TEST_PROJECT_DIR"
  local output_file="$BATS_TEST_TMPDIR/agent_output.json"
  echo '{"result":"partial","session_id":"sess-timeout-456"}' > "$output_file"

  _log_agent_result "$TEST_PROJECT_DIR" "Fixer" "7" "124" "$output_file"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"Fixer timed out on task 7"* ]]
  [[ "$log_content" == *"Session ID for Fixer task 7: sess-timeout-456"* ]]
}

@test "_log_agent_result does not error on missing output file" {
  init_pipeline "$TEST_PROJECT_DIR"

  # Should not fail even though the file doesn't exist.
  _log_agent_result "$TEST_PROJECT_DIR" "Coder" "10" "0" "/nonexistent/file.json"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"Coder completed task 10"* ]]
  # No session ID line should appear.
  [[ "$log_content" != *"Session ID"* ]]
}

@test "_log_agent_result skips session ID when field missing from JSON" {
  init_pipeline "$TEST_PROJECT_DIR"
  local output_file="$BATS_TEST_TMPDIR/agent_output.json"
  echo '{"result":"done","cost_usd":0.05}' > "$output_file"

  _log_agent_result "$TEST_PROJECT_DIR" "Reviewer" "15" "0" "$output_file"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"Reviewer completed task 15"* ]]
  [[ "$log_content" != *"Session ID"* ]]
}

@test "resolve_config_dir_with_fallback disabled does not try alternate account" {
  local call_count_file
  call_count_file="$BATS_TEST_TMPDIR/call_count"
  echo "0" > "$call_count_file"

  # Use eval to capture the call_count_file path in the function.
  eval "claude() {
    local count
    count=\$(cat \"$call_count_file\")
    echo \$(( count + 1 )) > \"$call_count_file\"
    return 1
  }"
  export -f claude



  AUTOPILOT_CLAUDE_CMD="claude"
  AUTOPILOT_TIMEOUT_AUTH_CHECK=5
  AUTOPILOT_AUTH_FALLBACK="false"
  init_pipeline "$TEST_PROJECT_DIR"

  run resolve_config_dir_with_fallback \
    "$HOME/.claude-account1" "coder" "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
  # Should only have been called once (no fallback attempt).
  local calls
  calls="$(cat "$call_count_file")"
  [ "$calls" -eq 1 ]
}
