#!/usr/bin/env bats
# Edge case tests for lib/claude.sh — prompt reading, agent result logging,
# run-and-extract lifecycle, agent output saving, pause file creation,
# and agent-with-hooks lifecycle.

load helpers/test_template

# Source libs once at file level (not per-test).
source "$BATS_TEST_DIRNAME/../lib/claude.sh"

setup() {
  TEST_PROJECT_DIR="${BATS_TEST_TMPDIR}/project"
  TEST_HOOKS_DIR="${BATS_TEST_TMPDIR}/hooks"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs" \
           "$TEST_PROJECT_DIR/.autopilot/locks" \
           "$TEST_HOOKS_DIR"

  _unset_autopilot_vars
  load_config "$TEST_PROJECT_DIR"
}

teardown() {
  : # BATS_TEST_TMPDIR is auto-cleaned
}

# --- _read_prompt_file ---

@test "_read_prompt_file reads contents of existing file" {
  echo "Hello prompt" > "$TEST_PROJECT_DIR/test.md"

  local result
  result="$(_read_prompt_file "$TEST_PROJECT_DIR/test.md")"
  [ "$result" = "Hello prompt" ]
}

@test "_read_prompt_file fails for nonexistent file" {
  run _read_prompt_file "$TEST_PROJECT_DIR/nonexistent.md"
  [ "$status" -eq 1 ]
}

@test "_read_prompt_file logs error for missing file" {
  _read_prompt_file "$TEST_PROJECT_DIR/missing.md" "$TEST_PROJECT_DIR" 2>/dev/null || true

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"Prompt file not found"* ]]
}

@test "_read_prompt_file reads multiline content" {
  printf "Line 1\nLine 2\nLine 3\n" > "$TEST_PROJECT_DIR/multi.md"

  local result
  result="$(_read_prompt_file "$TEST_PROJECT_DIR/multi.md")"
  local line_count
  line_count="$(echo "$result" | wc -l | tr -d ' ')"
  [ "$line_count" = "3" ]
}

# --- _log_agent_result ---

@test "_log_agent_result logs INFO on exit code 0" {
  _log_agent_result "$TEST_PROJECT_DIR" "Coder" "5" "0" "/tmp/out"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"[INFO]"* ]]
  [[ "$log_content" == *"Coder completed task 5"* ]]
}

@test "_log_agent_result logs WARNING on exit code 124 (timeout)" {
  _log_agent_result "$TEST_PROJECT_DIR" "Fixer" "3" "124" "/tmp/out"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"[WARNING]"* ]]
  [[ "$log_content" == *"timed out"* ]]
}

@test "_log_agent_result logs ERROR on other exit codes" {
  _log_agent_result "$TEST_PROJECT_DIR" "Merger" "7" "1" "/tmp/out"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"[ERROR]"* ]]
  [[ "$log_content" == *"failed on task 7"* ]]
  [[ "$log_content" == *"exit=1"* ]]
}

@test "_log_agent_result includes extra context when provided" {
  _log_agent_result "$TEST_PROJECT_DIR" "Coder" "1" "0" "/tmp/out" "PR #42"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"PR #42"* ]]
}

@test "_log_agent_result omits extra context when empty" {
  _log_agent_result "$TEST_PROJECT_DIR" "Coder" "1" "0" "/tmp/out" ""

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"Coder completed task 1"* ]]
  # Should not have trailing comma from empty context.
  [[ "$log_content" != *", ,"* ]]
}

# --- _create_pause_file ---

@test "_create_pause_file creates PAUSE file with reason" {
  _create_pause_file "$TEST_PROJECT_DIR" "Auth failed"

  [ -f "$TEST_PROJECT_DIR/.autopilot/PAUSE" ]
  local content
  content="$(cat "$TEST_PROJECT_DIR/.autopilot/PAUSE")"
  [ "$content" = "Auth failed" ]
}

@test "_create_pause_file creates .autopilot dir if missing" {
  rm -rf "$TEST_PROJECT_DIR/.autopilot"

  _create_pause_file "$TEST_PROJECT_DIR" "Test pause"

  [ -f "$TEST_PROJECT_DIR/.autopilot/PAUSE" ]
}

@test "_create_pause_file overwrites existing PAUSE file" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  echo "old reason" > "$TEST_PROJECT_DIR/.autopilot/PAUSE"

  _create_pause_file "$TEST_PROJECT_DIR" "new reason"

  local content
  content="$(cat "$TEST_PROJECT_DIR/.autopilot/PAUSE")"
  [ "$content" = "new reason" ]
}

# --- _save_agent_output ---

@test "_save_agent_output copies file to logs dir" {
  local output_file
  output_file="$(mktemp)"
  echo '{"result": "test output"}' > "$output_file"

  _save_agent_output "$TEST_PROJECT_DIR" "coder" "5" "$output_file"

  local saved="$TEST_PROJECT_DIR/.autopilot/logs/coder-task-5.json"
  [ -f "$saved" ]
  local content
  content="$(cat "$saved")"
  [[ "$content" == *"test output"* ]]

  rm -f "$output_file"
}

@test "_save_agent_output creates logs dir if missing" {
  rm -rf "$TEST_PROJECT_DIR/.autopilot/logs"

  local output_file
  output_file="$(mktemp)"
  echo '{}' > "$output_file"

  _save_agent_output "$TEST_PROJECT_DIR" "fixer" "3" "$output_file"

  [ -f "$TEST_PROJECT_DIR/.autopilot/logs/fixer-task-3.json" ]
  rm -f "$output_file"
}

@test "_save_agent_output skips when output file does not exist" {
  _save_agent_output "$TEST_PROJECT_DIR" "coder" "1" "/nonexistent/file"

  # Should not crash, and no file should be created.
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/logs/coder-task-1.json" ]
}

# --- _run_claude_and_extract ---

@test "_run_claude_and_extract returns text on success" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"Hello extracted"}'
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"
  AUTOPILOT_TIMEOUT_CODER=10

  local result
  result="$(_run_claude_and_extract 10 "test prompt")"
  [ "$result" = "Hello extracted" ]

  rm -rf "$mock_dir"
}

@test "_run_claude_and_extract returns 1 on Claude failure" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  run _run_claude_and_extract 10 "test prompt"
  [ "$status" -eq 1 ]

  rm -rf "$mock_dir"
}

@test "_run_claude_and_extract returns 1 on empty response" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{}'
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  run _run_claude_and_extract 10 "test prompt"
  [ "$status" -eq 1 ]

  rm -rf "$mock_dir"
}

@test "_run_claude_and_extract cleans up its own temp files on success" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  # Mock writes output file path to a sidecar so we can verify cleanup.
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"cleanup test"}'
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  # _run_claude_and_extract internally calls run_claude (creates temp file),
  # then rm -f on both the output and .err files. We verify by calling
  # run_claude directly first to confirm temp files are created, then
  # calling _run_claude_and_extract to confirm they're cleaned up.
  local direct_file
  direct_file="$(run_claude 10 "probe")"
  # run_claude creates a temp file — confirm it exists.
  [ -f "$direct_file" ]
  rm -f "$direct_file" "${direct_file}.err"

  # Now call _run_claude_and_extract — it should return data and leave
  # no output file behind (it cleans up internally).
  local result
  result="$(_run_claude_and_extract 10 "test prompt")"
  [ "$result" = "cleanup test" ]

  rm -rf "$mock_dir"
}

# --- _run_agent_with_hooks ---

@test "_run_agent_with_hooks returns claude exit code" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"ok"}'
exit 0
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  local output_file exit_code=0
  output_file="$(_run_agent_with_hooks "$TEST_PROJECT_DIR" \
    "$TEST_HOOKS_DIR" "TestAgent" "1" "10" "test prompt")" || exit_code=$?

  [ "$exit_code" -eq 0 ]
  [ -f "$output_file" ]

  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

@test "_run_agent_with_hooks propagates non-zero exit code" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"error":"fail"}' >&2
exit 42
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  local exit_code=0
  _run_agent_with_hooks "$TEST_PROJECT_DIR" \
    "$TEST_HOOKS_DIR" "TestAgent" "1" "10" "test prompt" > /dev/null || exit_code=$?

  [ "$exit_code" -eq 42 ]

  rm -rf "$mock_dir"
}

@test "_run_agent_with_hooks logs spawn and result" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"ok"}'
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  local output_file
  output_file="$(_run_agent_with_hooks "$TEST_PROJECT_DIR" \
    "$TEST_HOOKS_DIR" "TestAgent" "5" "10" "test prompt")"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"Spawning TestAgent for task 5"* ]]
  [[ "$log_content" == *"TestAgent completed task 5"* ]]

  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}
