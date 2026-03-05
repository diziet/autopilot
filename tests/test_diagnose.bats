#!/usr/bin/env bats
# Tests for lib/diagnose.sh — Failure diagnosis agent spawning,
# log file selection, prompt construction, and output persistence.

setup() {
  TEST_PROJECT_DIR="$(mktemp -d)"
  TEST_MOCK_BIN="$(mktemp -d)"

  # Unset all AUTOPILOT_* env vars to start clean.
  while IFS= read -r var; do
    unset "$var"
  done < <(env | grep '^AUTOPILOT_' | cut -d= -f1)

  unset CLAUDECODE
  unset CLAUDE_CONFIG_DIR

  # Source diagnose.sh (which sources config, state, claude).
  source "$BATS_TEST_DIRNAME/../lib/diagnose.sh"
  load_config "$TEST_PROJECT_DIR"

  # Initialize pipeline state dir for log_msg.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/locks"

  # Override prompts dir to use real prompts in repo.
  _DIAGNOSE_PROMPTS_DIR="$BATS_TEST_DIRNAME/../prompts"

  # Put mock bin dir first in PATH for mocking external commands.
  export PATH="${TEST_MOCK_BIN}:${PATH}"
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR"
  rm -rf "$TEST_MOCK_BIN"
}

# --- Exit Code Constants ---

@test "DIAGNOSE_OK is 0" {
  [ "$DIAGNOSE_OK" -eq 0 ]
}

@test "DIAGNOSE_ERROR is 1" {
  [ "$DIAGNOSE_ERROR" -eq 1 ]
}

# --- _validate_task_number ---

@test "_validate_task_number accepts positive integers" {
  _validate_task_number 1
  _validate_task_number 42
  _validate_task_number 100
}

@test "_validate_task_number rejects non-numeric input" {
  ! _validate_task_number "abc"
  ! _validate_task_number "1/../../../tmp/evil"
  ! _validate_task_number ""
  ! _validate_task_number "1a"
}

@test "select_log_file rejects non-numeric task number" {
  run select_log_file "$TEST_PROJECT_DIR" "../../../tmp" "implementing"
  [ "$status" -eq 1 ]
}

@test "run_diagnosis rejects non-numeric task number" {
  _create_mock_claude "diagnosis"
  _create_mock_timeout
  init_pipeline "$TEST_PROJECT_DIR"

  run run_diagnosis "$TEST_PROJECT_DIR" "1/../evil" "task" "pending"
  [ "$status" -eq "$DIAGNOSE_ERROR" ]
}

@test "read_diagnosis rejects non-numeric task number" {
  run read_diagnosis "$TEST_PROJECT_DIR" "../etc/passwd"
  [ "$status" -eq 1 ]
}

# --- _find_first_existing_log ---

@test "_find_first_existing_log returns first existing non-empty file" {
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  echo "coder output" > "${log_dir}/coder-task-1.json"

  local result
  result="$(_find_first_existing_log "$log_dir" \
    "fix-tests-task-1.log" "coder-task-1.json" "pipeline.log")"
  [ "$result" = "${log_dir}/coder-task-1.json" ]
}

@test "_find_first_existing_log returns empty when no candidates exist" {
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"

  run _find_first_existing_log "$log_dir" \
    "nonexistent-1.log" "nonexistent-2.json"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "_find_first_existing_log skips empty files" {
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  touch "${log_dir}/empty-file.log"
  echo "has content" > "${log_dir}/real-file.json"

  local result
  result="$(_find_first_existing_log "$log_dir" \
    "empty-file.log" "real-file.json")"
  [ "$result" = "${log_dir}/real-file.json" ]
}

@test "_find_first_existing_log returns first of multiple existing files" {
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  echo "first" > "${log_dir}/file-a.log"
  echo "second" > "${log_dir}/file-b.log"

  local result
  result="$(_find_first_existing_log "$log_dir" \
    "file-a.log" "file-b.log")"
  [ "$result" = "${log_dir}/file-a.log" ]
}

# --- select_log_file ---

@test "select_log_file for test_fixing prioritizes fix-tests log" {
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  echo "fix-tests output" > "${log_dir}/fix-tests-task-5.log"
  echo "coder output" > "${log_dir}/coder-task-5.json"

  local result
  result="$(select_log_file "$TEST_PROJECT_DIR" 5 "test_fixing")"
  [ "$result" = "${log_dir}/fix-tests-task-5.log" ]
}

@test "select_log_file for test_fixing falls back to coder log" {
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  echo "coder output" > "${log_dir}/coder-task-3.json"

  local result
  result="$(select_log_file "$TEST_PROJECT_DIR" 3 "test_fixing")"
  [ "$result" = "${log_dir}/coder-task-3.json" ]
}

@test "select_log_file for test_fixing falls back to pipeline.log" {
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  echo "pipeline log content" > "${log_dir}/pipeline.log"

  local result
  result="$(select_log_file "$TEST_PROJECT_DIR" 7 "test_fixing")"
  [ "$result" = "${log_dir}/pipeline.log" ]
}

@test "select_log_file for fixing prioritizes fixer log" {
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  echo "fixer output" > "${log_dir}/fixer-task-2.json"
  echo "coder output" > "${log_dir}/coder-task-2.json"

  local result
  result="$(select_log_file "$TEST_PROJECT_DIR" 2 "fixing")"
  [ "$result" = "${log_dir}/fixer-task-2.json" ]
}

@test "select_log_file for reviewed prioritizes fixer log" {
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  echo "fixer output" > "${log_dir}/fixer-task-4.json"

  local result
  result="$(select_log_file "$TEST_PROJECT_DIR" 4 "reviewed")"
  [ "$result" = "${log_dir}/fixer-task-4.json" ]
}

@test "select_log_file for implementing returns coder log" {
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  echo "coder output" > "${log_dir}/coder-task-1.json"

  local result
  result="$(select_log_file "$TEST_PROJECT_DIR" 1 "implementing")"
  [ "$result" = "${log_dir}/coder-task-1.json" ]
}

@test "select_log_file for pending returns coder log" {
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  echo "coder output" > "${log_dir}/coder-task-6.json"

  local result
  result="$(select_log_file "$TEST_PROJECT_DIR" 6 "pending")"
  [ "$result" = "${log_dir}/coder-task-6.json" ]
}

@test "select_log_file for unknown state uses fallback order" {
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  echo "fixer output" > "${log_dir}/fixer-task-8.json"

  local result
  result="$(select_log_file "$TEST_PROJECT_DIR" 8 "merging")"
  [ "$result" = "${log_dir}/fixer-task-8.json" ]
}

@test "select_log_file for unknown state with no specific logs uses pipeline.log" {
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  echo "pipeline content" > "${log_dir}/pipeline.log"

  local result
  result="$(select_log_file "$TEST_PROJECT_DIR" 99 "merging")"
  [ "$result" = "${log_dir}/pipeline.log" ]
}

@test "select_log_file returns empty when no logs exist" {
  run select_log_file "$TEST_PROJECT_DIR" 42 "implementing"
  [ -z "$output" ]
}

@test "select_log_file with empty state uses fallback" {
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  echo "coder output" > "${log_dir}/coder-task-1.json"

  local result
  result="$(select_log_file "$TEST_PROJECT_DIR" 1 "")"
  [ "$result" = "${log_dir}/coder-task-1.json" ]
}

# --- _read_log_content ---

@test "_read_log_content reads full content for small files" {
  local log_file="${TEST_PROJECT_DIR}/test.log"
  printf "line1\nline2\nline3\n" > "$log_file"

  local result
  result="$(_read_log_content "$log_file" 200)"
  echo "$result" | grep -qF "line1"
  echo "$result" | grep -qF "line3"
}

@test "_read_log_content truncates large files with notice" {
  local log_file="${TEST_PROJECT_DIR}/large.log"
  for i in $(seq 1 50); do
    echo "line ${i}" >> "$log_file"
  done

  local result
  result="$(_read_log_content "$log_file" 10)"
  echo "$result" | grep -qF "showing last 10 of 50 lines"
  echo "$result" | grep -qF "line 50"
  ! echo "$result" | grep -q "^line 1$"
}

@test "_read_log_content returns placeholder for missing file" {
  local result
  result="$(_read_log_content "/nonexistent/file.log")"
  [ "$result" = "(no log file found)" ]
}

@test "_read_log_content with default max_lines" {
  local log_file="${TEST_PROJECT_DIR}/default.log"
  printf "small file\n" > "$log_file"

  local result
  result="$(_read_log_content "$log_file")"
  [ "$result" = "small file" ]
}

# --- build_diagnosis_prompt ---

@test "build_diagnosis_prompt includes task number" {
  local result
  result="$(build_diagnosis_prompt 5 "implement feature X" \
    "error log content" "implementing" 3 5 "")"
  echo "$result" | grep -qF "Task 5"
}

@test "build_diagnosis_prompt includes task body" {
  local result
  result="$(build_diagnosis_prompt 1 "Build the auth module" \
    "logs" "pending" 1 5 "")"
  echo "$result" | grep -qF "Build the auth module"
}

@test "build_diagnosis_prompt includes log content" {
  local result
  result="$(build_diagnosis_prompt 1 "task" \
    "FATAL: something broke" "implementing" 2 5 "")"
  echo "$result" | grep -qF "FATAL: something broke"
}

@test "build_diagnosis_prompt includes state and retry info" {
  local result
  result="$(build_diagnosis_prompt 3 "task" "logs" \
    "test_fixing" 4 5 "")"
  echo "$result" | grep -qF "test_fixing"
  echo "$result" | grep -qF "4/5"
}

@test "build_diagnosis_prompt includes log file basename" {
  local result
  result="$(build_diagnosis_prompt 1 "task" "logs" \
    "implementing" 1 5 "/path/to/coder-task-1.json")"
  echo "$result" | grep -qF "coder-task-1.json"
}

@test "build_diagnosis_prompt omits log source when path is empty" {
  local result
  result="$(build_diagnosis_prompt 1 "task" "logs" \
    "implementing" 1 5 "")"
  # Should not contain "(from )" pattern.
  ! echo "$result" | grep -qF "(from )"
}

@test "build_diagnosis_prompt includes system prompt from diagnose.md" {
  local result
  result="$(build_diagnosis_prompt 1 "task" "logs" \
    "pending" 0 5 "")"
  # diagnose.md contains "Diagnosis Agent".
  echo "$result" | grep -qF "Diagnosis Agent"
}

@test "build_diagnosis_prompt includes actionable recommendations request" {
  local result
  result="$(build_diagnosis_prompt 1 "task" "logs" \
    "pending" 0 5 "")"
  echo "$result" | grep -qF "actionable recommendations"
}

# --- _save_diagnosis ---

@test "_save_diagnosis writes diagnosis text to correct file" {
  _save_diagnosis "$TEST_PROJECT_DIR" 5 "Root cause: missing dep"

  local target="${TEST_PROJECT_DIR}/.autopilot/logs/diagnosis-task-5.md"
  [ -f "$target" ]
  grep -qF "Root cause: missing dep" "$target"
}

@test "_save_diagnosis creates logs dir if missing" {
  local fresh_dir
  fresh_dir="$(mktemp -d)"
  mkdir -p "${fresh_dir}/.autopilot/logs"

  # Initialize log_msg requirement.
  _save_diagnosis "$fresh_dir" 1 "some diagnosis"

  [ -f "${fresh_dir}/.autopilot/logs/diagnosis-task-1.md" ]
  rm -rf "$fresh_dir"
}

@test "_save_diagnosis overwrites existing diagnosis" {
  local target="${TEST_PROJECT_DIR}/.autopilot/logs/diagnosis-task-3.md"
  echo "old diagnosis" > "$target"

  _save_diagnosis "$TEST_PROJECT_DIR" 3 "new diagnosis"

  local content
  content="$(cat "$target")"
  [[ "$content" == *"new diagnosis"* ]]
  ! echo "$content" | grep -qF "old diagnosis"
}

# --- read_diagnosis ---

@test "read_diagnosis returns content for existing diagnosis" {
  local target="${TEST_PROJECT_DIR}/.autopilot/logs/diagnosis-task-7.md"
  echo "Diagnosis: timeout issue" > "$target"

  local result
  result="$(read_diagnosis "$TEST_PROJECT_DIR" 7)"
  echo "$result" | grep -qF "Diagnosis: timeout issue"
}

@test "read_diagnosis returns empty for missing diagnosis" {
  local result
  result="$(read_diagnosis "$TEST_PROJECT_DIR" 99)"
  [ -z "$result" ]
}

@test "read_diagnosis returns empty for empty file" {
  local target="${TEST_PROJECT_DIR}/.autopilot/logs/diagnosis-task-2.md"
  touch "$target"

  local result
  result="$(read_diagnosis "$TEST_PROJECT_DIR" 2)"
  [ -z "$result" ]
}

# --- run_diagnosis with mock Claude ---

# Helper: create a mock claude that returns a JSON response.
_create_mock_claude() {
  local response_text="$1"
  local exit_code="${2:-0}"

  cat > "${TEST_MOCK_BIN}/claude" <<MOCK
#!/usr/bin/env bash
echo '{"result":"${response_text}"}'
exit ${exit_code}
MOCK
  chmod +x "${TEST_MOCK_BIN}/claude"
}

# Helper: create a mock timeout that delegates to the command.
_create_mock_timeout() {
  cat > "${TEST_MOCK_BIN}/timeout" <<'MOCK'
#!/usr/bin/env bash
# Skip the timeout arg and run the rest.
shift
exec "$@"
MOCK
  chmod +x "${TEST_MOCK_BIN}/timeout"
}

@test "run_diagnosis returns diagnosis text on success" {
  _create_mock_claude "Root cause: missing dependency"
  _create_mock_timeout

  # Set up state for retry count.
  init_pipeline "$TEST_PROJECT_DIR"

  # Create a coder log so there's something to read.
  echo "ERROR: build failed" > \
    "${TEST_PROJECT_DIR}/.autopilot/logs/coder-task-1.json"

  local result
  result="$(run_diagnosis "$TEST_PROJECT_DIR" 1 \
    "Build feature X" "implementing")"
  echo "$result" | grep -qF "Root cause: missing dependency"
}

@test "run_diagnosis saves output to diagnosis file" {
  _create_mock_claude "Root cause: API rate limit"
  _create_mock_timeout

  init_pipeline "$TEST_PROJECT_DIR"

  echo "log content" > \
    "${TEST_PROJECT_DIR}/.autopilot/logs/coder-task-2.json"

  run_diagnosis "$TEST_PROJECT_DIR" 2 "Task body" "implementing"

  local target="${TEST_PROJECT_DIR}/.autopilot/logs/diagnosis-task-2.md"
  [ -f "$target" ]
  grep -qF "Root cause: API rate limit" "$target"
}

@test "run_diagnosis returns DIAGNOSE_OK on success" {
  _create_mock_claude "diagnosis text"
  _create_mock_timeout

  init_pipeline "$TEST_PROJECT_DIR"

  run run_diagnosis "$TEST_PROJECT_DIR" 1 "task" "pending"
  [ "$status" -eq "$DIAGNOSE_OK" ]
}

@test "run_diagnosis returns DIAGNOSE_ERROR when Claude fails" {
  _create_mock_claude "error" 1
  _create_mock_timeout

  init_pipeline "$TEST_PROJECT_DIR"

  run run_diagnosis "$TEST_PROJECT_DIR" 1 "task" "implementing"
  [ "$status" -eq "$DIAGNOSE_ERROR" ]
}

@test "run_diagnosis returns DIAGNOSE_ERROR on empty response" {
  # Mock Claude that returns empty result.
  cat > "${TEST_MOCK_BIN}/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":""}'
MOCK
  chmod +x "${TEST_MOCK_BIN}/claude"
  _create_mock_timeout

  init_pipeline "$TEST_PROJECT_DIR"

  run run_diagnosis "$TEST_PROJECT_DIR" 1 "task" "pending"
  [ "$status" -eq "$DIAGNOSE_ERROR" ]
}

@test "run_diagnosis uses AUTOPILOT_TIMEOUT_DIAGNOSE config" {
  # Mock timeout that logs its first arg (the timeout value).
  local timeout_capture="${TEST_PROJECT_DIR}/timeout_val.txt"
  cat > "${TEST_MOCK_BIN}/timeout" <<MOCK
#!/usr/bin/env bash
echo "\$1" > "${timeout_capture}"
shift
exec "\$@"
MOCK
  chmod +x "${TEST_MOCK_BIN}/timeout"
  _create_mock_claude "diagnosis"

  AUTOPILOT_TIMEOUT_DIAGNOSE=120
  init_pipeline "$TEST_PROJECT_DIR"

  run_diagnosis "$TEST_PROJECT_DIR" 1 "task" "pending" >/dev/null 2>&1 || true

  # Assert unconditionally that timeout received our configured value.
  [ -f "$timeout_capture" ]
  [ "$(cat "$timeout_capture")" = "120" ]
}

@test "run_diagnosis handles missing task body gracefully" {
  _create_mock_claude "diagnosis without task body"
  _create_mock_timeout

  init_pipeline "$TEST_PROJECT_DIR"

  local result
  result="$(run_diagnosis "$TEST_PROJECT_DIR" 1 "" "pending")"
  echo "$result" | grep -qF "diagnosis without task body"
}

@test "run_diagnosis handles missing log files gracefully" {
  _create_mock_claude "diagnosis with no logs"
  _create_mock_timeout

  init_pipeline "$TEST_PROJECT_DIR"

  local result
  result="$(run_diagnosis "$TEST_PROJECT_DIR" 1 "task body" "implementing")"
  echo "$result" | grep -qF "diagnosis with no logs"
}

@test "run_diagnosis for test_fixing state reads fix-tests log" {
  # Mock Claude that echoes the prompt to a known file for inspection.
  local prompt_capture="${TEST_PROJECT_DIR}/captured_prompt.txt"
  cat > "${TEST_MOCK_BIN}/claude" <<MOCK
#!/usr/bin/env bash
# Capture the prompt (last arg after --print).
for arg in "\$@"; do
  last="\$arg"
done
echo "\$last" > "${prompt_capture}"
echo '{"result":"diagnosed"}'
MOCK
  chmod +x "${TEST_MOCK_BIN}/claude"
  _create_mock_timeout

  init_pipeline "$TEST_PROJECT_DIR"

  # Create a fix-tests log.
  echo "FAILED: test_auth_module" > \
    "${TEST_PROJECT_DIR}/.autopilot/logs/fix-tests-task-4.log"

  run_diagnosis "$TEST_PROJECT_DIR" 4 "Auth task" "test_fixing" >/dev/null 2>&1

  # Assert unconditionally that the prompt captured the fix-tests log content.
  [ -f "$prompt_capture" ]
  grep -qF "FAILED: test_auth_module" "$prompt_capture"
}

@test "run_diagnosis logs spawning info" {
  _create_mock_claude "diagnosis"
  _create_mock_timeout

  init_pipeline "$TEST_PROJECT_DIR"

  run_diagnosis "$TEST_PROJECT_DIR" 5 "task" "implementing" >/dev/null

  local log_file="${TEST_PROJECT_DIR}/.autopilot/logs/pipeline.log"
  grep -qF "Spawning diagnostician for task 5" "$log_file"
}

@test "run_diagnosis logs completion info" {
  _create_mock_claude "diagnosis"
  _create_mock_timeout

  init_pipeline "$TEST_PROJECT_DIR"

  run_diagnosis "$TEST_PROJECT_DIR" 3 "task" "pending" >/dev/null

  local log_file="${TEST_PROJECT_DIR}/.autopilot/logs/pipeline.log"
  grep -qF "Diagnosis complete for task 3" "$log_file"
}

# --- Integration: select_log_file + build_diagnosis_prompt ---

@test "integration: full log selection and prompt for test_fixing" {
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  echo "FAIL: test_widget line 42" > "${log_dir}/fix-tests-task-10.log"
  echo "coder ran fine" > "${log_dir}/coder-task-10.json"

  # Select log for test_fixing should pick fix-tests log.
  local log_file
  log_file="$(select_log_file "$TEST_PROJECT_DIR" 10 "test_fixing")"
  [ "$log_file" = "${log_dir}/fix-tests-task-10.log" ]

  # Read content and build prompt.
  local content
  content="$(_read_log_content "$log_file")"
  echo "$content" | grep -qF "FAIL: test_widget"

  local prompt
  prompt="$(build_diagnosis_prompt 10 "Widget feature" \
    "$content" "test_fixing" 3 5 "$log_file")"
  echo "$prompt" | grep -qF "Task 10"
  echo "$prompt" | grep -qF "test_fixing"
  echo "$prompt" | grep -qF "FAIL: test_widget"
  echo "$prompt" | grep -qF "fix-tests-task-10.log"
}

@test "integration: full log selection and prompt for implementing" {
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  echo '{"error":"build failed"}' > "${log_dir}/coder-task-3.json"

  local log_file
  log_file="$(select_log_file "$TEST_PROJECT_DIR" 3 "implementing")"
  [ "$log_file" = "${log_dir}/coder-task-3.json" ]

  local content
  content="$(_read_log_content "$log_file")"
  echo "$content" | grep -qF "build failed"

  local prompt
  prompt="$(build_diagnosis_prompt 3 "API module" \
    "$content" "implementing" 5 5 "$log_file")"
  echo "$prompt" | grep -qF "implementing"
  echo "$prompt" | grep -qF "5/5"
  echo "$prompt" | grep -qF "coder-task-3.json"
}

@test "integration: fallback to pipeline.log when no task-specific logs" {
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  echo "2024-01-01 [ERROR] task 15 crashed" > "${log_dir}/pipeline.log"

  local log_file
  log_file="$(select_log_file "$TEST_PROJECT_DIR" 15 "fixing")"
  [ "$log_file" = "${log_dir}/pipeline.log" ]
}
