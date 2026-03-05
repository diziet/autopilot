#!/usr/bin/env bats
# Tests for lib/claude.sh — Claude invocation helpers.

setup() {
  TEST_PROJECT_DIR="$(mktemp -d)"

  # Unset all AUTOPILOT_* env vars to start clean.
  while IFS= read -r var; do
    unset "$var"
  done < <(env | grep '^AUTOPILOT_' | cut -d= -f1)

  # Unset CLAUDECODE to avoid interference.
  unset CLAUDECODE

  # Source claude.sh (which also sources config.sh).
  source "$BATS_TEST_DIRNAME/../lib/claude.sh"
  load_config "$TEST_PROJECT_DIR"
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR"
}

# --- _build_base_cmd_args: shared helper ---

@test "_build_base_cmd_args populates array with default command" {
  local -a _BASE_CMD_ARGS=()
  _build_base_cmd_args
  [ "${_BASE_CMD_ARGS[0]}" = "claude" ]
  [ "${_BASE_CMD_ARGS[1]}" = "--output-format" ]
  [ "${_BASE_CMD_ARGS[2]}" = "json" ]
  [ "${#_BASE_CMD_ARGS[@]}" -eq 3 ]
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
  [ "${_BASE_CMD_ARGS[3]}" = "--output-format" ]
  [ "${_BASE_CMD_ARGS[4]}" = "json" ]
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
  cd - > /dev/null
}

@test "_build_base_cmd_args uses AUTOPILOT_CLAUDE_OUTPUT_FORMAT" {
  AUTOPILOT_CLAUDE_OUTPUT_FORMAT="text"
  local -a _BASE_CMD_ARGS=()
  _build_base_cmd_args
  [ "${_BASE_CMD_ARGS[1]}" = "--output-format" ]
  [ "${_BASE_CMD_ARGS[2]}" = "text" ]
}

# --- build_claude_cmd: defaults ---

@test "build_claude_cmd returns default command with json format" {
  local result
  result="$(build_claude_cmd)"
  [[ "$result" == "claude --output-format json" ]]
}

@test "build_claude_cmd uses AUTOPILOT_CLAUDE_CMD" {
  AUTOPILOT_CLAUDE_CMD="/usr/local/bin/claude-custom"
  local result
  result="$(build_claude_cmd)"
  [[ "$result" == "/usr/local/bin/claude-custom --output-format json" ]]
}

@test "build_claude_cmd uses AUTOPILOT_CLAUDE_OUTPUT_FORMAT" {
  AUTOPILOT_CLAUDE_OUTPUT_FORMAT="text"
  local result
  result="$(build_claude_cmd)"
  [[ "$result" == "claude --output-format text" ]]
}

# --- build_claude_cmd: flags ---

@test "build_claude_cmd includes AUTOPILOT_CLAUDE_FLAGS" {
  AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions"
  local result
  result="$(build_claude_cmd)"
  [[ "$result" == "claude --dangerously-skip-permissions --output-format json" ]]
}

@test "build_claude_cmd handles multiple flags" {
  AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions --verbose"
  local result
  result="$(build_claude_cmd)"
  [[ "$result" == "claude --dangerously-skip-permissions --verbose --output-format json" ]]
}

@test "build_claude_cmd with empty flags omits extra spaces" {
  AUTOPILOT_CLAUDE_FLAGS=""
  local result
  result="$(build_claude_cmd)"
  [[ "$result" == "claude --output-format json" ]]
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
  tmp_file="$(mktemp)"
  echo '{"result":"File content here","is_error":false}' > "$tmp_file"
  local result
  result="$(extract_claude_text "$tmp_file")"
  [ "$result" = "File content here" ]
  rm -f "$tmp_file"
}

@test "extract_claude_text returns empty and fails for nonexistent file" {
  run extract_claude_text "/nonexistent/path/file.json"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "extract_claude_text returns empty and fails for empty file" {
  local tmp_file
  tmp_file="$(mktemp)"
  : > "$tmp_file"
  run extract_claude_text "$tmp_file"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  rm -f "$tmp_file"
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
  # Create a mock claude that checks CLAUDECODE is unset.
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
if [[ -n "${CLAUDECODE:-}" ]]; then
  echo '{"result":"CLAUDECODE was set","is_error":true}'
  exit 1
fi
echo '{"result":"CLAUDECODE was unset","is_error":false}'
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"
  export CLAUDECODE="should-be-unset"

  local output_file
  output_file="$(run_claude 10 "test prompt")" || true

  local content
  content="$(cat "$output_file")"
  [[ "$content" == *"CLAUDECODE was unset"* ]]
  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

@test "run_claude passes prompt via --print flag" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"args: '"$*"'","is_error":false}'
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  local output_file
  output_file="$(run_claude 10 "hello world")" || true

  local content
  content="$(cat "$output_file")"
  [[ "$content" == *"--print"* ]]
  [[ "$content" == *"hello world"* ]]
  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

@test "run_claude outputs file path to stdout" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"ok"}'
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  local output_file
  output_file="$(run_claude 10 "test")" || true

  [ -f "$output_file" ]
  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

@test "run_claude returns claude exit code on success" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"success"}'
exit 0
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  local output_file
  output_file="$(run_claude 10 "test")"
  local code=$?
  [ "$code" -eq 0 ]
  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

@test "run_claude returns claude exit code on failure" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"error","is_error":true}'
exit 1
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  local output_file exit_code=0
  output_file="$(run_claude 10 "test")" || exit_code=$?
  [ "$exit_code" -eq 1 ]
  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

# --- run_claude: stderr separation ---

@test "run_claude separates stdout from stderr" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"clean json"}' >&1
echo "warning: something happened" >&2
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

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
  rm -rf "$mock_dir"
}

@test "run_claude stderr does not corrupt JSON extraction" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo "deprecation notice: use new API" >&2
echo '{"result":"valid response","cost_usd":0.01}'
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  local output_file
  output_file="$(run_claude 10 "test")" || true

  # extract_claude_text should succeed because stderr is separate.
  local text
  text="$(extract_claude_text "$output_file")"
  [ "$text" = "valid response" ]

  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

# --- run_claude: config_dir ---

@test "run_claude sets CLAUDE_CONFIG_DIR when config_dir provided" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo "{\"result\":\"config_dir=${CLAUDE_CONFIG_DIR:-unset}\"}"
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  local output_file
  output_file="$(run_claude 10 "test" "/custom/config")" || true

  local content
  content="$(cat "$output_file")"
  [[ "$content" == *"config_dir=/custom/config"* ]]
  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

@test "run_claude does not set CLAUDE_CONFIG_DIR when config_dir empty" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  # Unset any existing CLAUDE_CONFIG_DIR.
  unset CLAUDE_CONFIG_DIR
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo "{\"result\":\"config_dir=${CLAUDE_CONFIG_DIR:-unset}\"}"
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  local output_file
  output_file="$(run_claude 10 "test" "")" || true

  local content
  content="$(cat "$output_file")"
  [[ "$content" == *"config_dir=unset"* ]]
  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

# --- run_claude: timeout ---

@test "run_claude times out long-running commands" {
  local mock_dir
  mock_dir="$(mktemp -d)"
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
  rm -rf "$mock_dir"
}

# --- run_claude: output format ---

@test "run_claude passes output format flag" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
for arg in "$@"; do
  echo "arg: $arg"
done
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"
  AUTOPILOT_CLAUDE_OUTPUT_FORMAT="stream-json"

  local output_file
  output_file="$(run_claude 10 "test")" || true

  local content
  content="$(cat "$output_file")"
  [[ "$content" == *"arg: --output-format"* ]]
  [[ "$content" == *"arg: stream-json"* ]]
  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

# --- run_claude: extra arguments ---

@test "run_claude passes extra arguments to claude" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
for arg in "$@"; do
  echo "arg: $arg"
done
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  local output_file
  output_file="$(run_claude 10 "test" "" "--resume" "session123")" || true

  local content
  content="$(cat "$output_file")"
  [[ "$content" == *"arg: --resume"* ]]
  [[ "$content" == *"arg: session123"* ]]
  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

# --- run_claude: flags from config ---

@test "run_claude includes AUTOPILOT_CLAUDE_FLAGS" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
for arg in "$@"; do
  echo "arg: $arg"
done
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"
  AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions"

  local output_file
  output_file="$(run_claude 10 "test")" || true

  local content
  content="$(cat "$output_file")"
  [[ "$content" == *"arg: --dangerously-skip-permissions"* ]]
  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

# --- Integration: run_claude + extract_claude_text ---

@test "run_claude output can be parsed by extract_claude_text" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"integration test passed","cost_usd":0.005}'
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  local output_file
  output_file="$(run_claude 10 "test")" || true

  local text
  text="$(extract_claude_text "$output_file")"
  [ "$text" = "integration test passed" ]
  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}
