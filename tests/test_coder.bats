#!/usr/bin/env bats
# Tests for lib/coder.sh — Coder agent spawning.

setup() {
  TEST_PROJECT_DIR="$(mktemp -d)"
  TEST_HOOKS_DIR="$(mktemp -d)"

  # Unset all AUTOPILOT_* env vars to start clean.
  while IFS= read -r var; do
    unset "$var"
  done < <(env | grep '^AUTOPILOT_' | cut -d= -f1)

  unset CLAUDECODE
  unset CLAUDE_CONFIG_DIR

  # Source coder.sh (which sources config.sh, state.sh, claude.sh, tasks.sh, hooks.sh).
  source "$BATS_TEST_DIRNAME/../lib/coder.sh"
  load_config "$TEST_PROJECT_DIR"

  # Initialize pipeline state dir for log_msg.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"

  # Override prompts dir to use real prompts in repo.
  _CODER_PROMPTS_DIR="$BATS_TEST_DIRNAME/../prompts"
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR"
  rm -rf "$TEST_HOOKS_DIR"
}

# --- _read_implement_prompt ---

@test "_read_implement_prompt reads prompts/implement.md" {
  local result
  result="$(_read_implement_prompt)"
  [[ "$result" == *"Implementation Agent"* ]]
  [[ "$result" == *"Branch & Commits"* ]]
}

@test "_read_implement_prompt fails when prompt file missing" {
  _CODER_PROMPTS_DIR="$TEST_PROJECT_DIR/nonexistent"
  run _read_implement_prompt
  [ "$status" -eq 1 ]
}

# --- _build_context_section ---

@test "_build_context_section returns empty when no context files configured" {
  AUTOPILOT_CONTEXT_FILES=""
  local result
  result="$(_build_context_section "$TEST_PROJECT_DIR")"
  [ -z "$result" ]
}

@test "_build_context_section lists existing context files" {
  mkdir -p "$TEST_PROJECT_DIR/docs"
  echo "plan content" > "$TEST_PROJECT_DIR/docs/plan.md"
  AUTOPILOT_CONTEXT_FILES="docs/plan.md"
  local result
  result="$(_build_context_section "$TEST_PROJECT_DIR")"
  [[ "$result" == *"docs/plan.md"* ]]
}

@test "_build_context_section skips nonexistent context files" {
  mkdir -p "$TEST_PROJECT_DIR/docs"
  echo "plan" > "$TEST_PROJECT_DIR/docs/plan.md"
  AUTOPILOT_CONTEXT_FILES="docs/plan.md:docs/missing.md"
  local result
  result="$(_build_context_section "$TEST_PROJECT_DIR")"
  [[ "$result" == *"docs/plan.md"* ]]
  [[ "$result" != *"missing.md"* ]]
}

@test "_build_context_section handles multiple context files" {
  mkdir -p "$TEST_PROJECT_DIR/docs"
  echo "a" > "$TEST_PROJECT_DIR/docs/a.md"
  echo "b" > "$TEST_PROJECT_DIR/docs/b.md"
  AUTOPILOT_CONTEXT_FILES="docs/a.md:docs/b.md"
  local result
  result="$(_build_context_section "$TEST_PROJECT_DIR")"
  [[ "$result" == *"docs/a.md"* ]]
  [[ "$result" == *"docs/b.md"* ]]
}

# --- build_coder_prompt ---

@test "build_coder_prompt includes implement.md template" {
  local result
  result="$(build_coder_prompt "$TEST_PROJECT_DIR" 5 "Do the thing")"
  [[ "$result" == *"Implementation Agent"* ]]
}

@test "build_coder_prompt includes task number and body" {
  local result
  result="$(build_coder_prompt "$TEST_PROJECT_DIR" 3 "Build feature X")"
  [[ "$result" == *"## Task 3"* ]]
  [[ "$result" == *"Build feature X"* ]]
}

@test "build_coder_prompt includes branch name with default prefix" {
  AUTOPILOT_BRANCH_PREFIX="autopilot"
  local result
  result="$(build_coder_prompt "$TEST_PROJECT_DIR" 7 "Task body")"
  [[ "$result" == *"autopilot/task-7"* ]]
}

@test "build_coder_prompt uses custom branch prefix" {
  AUTOPILOT_BRANCH_PREFIX="pr-pipeline"
  local result
  result="$(build_coder_prompt "$TEST_PROJECT_DIR" 2 "Task body")"
  [[ "$result" == *"pr-pipeline/task-2"* ]]
}

@test "build_coder_prompt includes completed summary when provided" {
  local result
  result="$(build_coder_prompt "$TEST_PROJECT_DIR" 4 "Body" "Task 1: did X")"
  [[ "$result" == *"Previously Completed Tasks"* ]]
  [[ "$result" == *"Task 1: did X"* ]]
}

@test "build_coder_prompt omits completed summary section when empty" {
  local result
  result="$(build_coder_prompt "$TEST_PROJECT_DIR" 4 "Body" "")"
  [[ "$result" != *"Previously Completed Tasks"* ]]
}

@test "build_coder_prompt includes context files section when configured" {
  mkdir -p "$TEST_PROJECT_DIR/docs"
  echo "ref content" > "$TEST_PROJECT_DIR/docs/ref.md"
  AUTOPILOT_CONTEXT_FILES="docs/ref.md"
  local result
  result="$(build_coder_prompt "$TEST_PROJECT_DIR" 1 "Body")"
  [[ "$result" == *"Reference Documents"* ]]
  [[ "$result" == *"docs/ref.md"* ]]
}

@test "build_coder_prompt omits reference section when no context files" {
  AUTOPILOT_CONTEXT_FILES=""
  local result
  result="$(build_coder_prompt "$TEST_PROJECT_DIR" 1 "Body")"
  [[ "$result" != *"Reference Documents"* ]]
}

# --- run_coder (with mock claude) ---

@test "run_coder calls claude and returns output file path" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"task completed","is_error":false}'
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"
  AUTOPILOT_TIMEOUT_CODER=10
  # Use test hooks dir to avoid modifying real settings.
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  local output_file exit_code=0
  output_file="$(run_coder "$TEST_PROJECT_DIR" 1 "Implement feature")" || exit_code=$?

  [ "$exit_code" -eq 0 ]
  [ -f "$output_file" ]

  local content
  content="$(cat "$output_file")"
  [[ "$content" == *"task completed"* ]]

  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

@test "run_coder returns claude exit code on failure" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"error","is_error":true}'
exit 1
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"
  AUTOPILOT_TIMEOUT_CODER=10
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  local output_file exit_code=0
  output_file="$(run_coder "$TEST_PROJECT_DIR" 1 "Broken task")" || exit_code=$?

  [ "$exit_code" -eq 1 ]

  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

@test "run_coder uses AUTOPILOT_TIMEOUT_CODER" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
sleep 30
echo '{"result":"should not reach here"}'
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"
  AUTOPILOT_TIMEOUT_CODER=1
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  local output_file exit_code=0
  output_file="$(run_coder "$TEST_PROJECT_DIR" 1 "Slow task")" || exit_code=$?

  [ "$exit_code" -eq 124 ]

  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

@test "run_coder uses AUTOPILOT_CODER_CONFIG_DIR" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo "{\"result\":\"config=${CLAUDE_CONFIG_DIR:-unset}\"}"
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"
  AUTOPILOT_TIMEOUT_CODER=10
  AUTOPILOT_CODER_CONFIG_DIR="/custom/coder/config"

  local output_file exit_code=0
  output_file="$(run_coder "$TEST_PROJECT_DIR" 1 "Task")" || exit_code=$?

  local content
  content="$(cat "$output_file")"
  [[ "$content" == *"config=/custom/coder/config"* ]]

  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

@test "run_coder installs and removes hooks" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  local settings_file="${TEST_HOOKS_DIR}/settings.json"

  # Create a mock claude that checks hooks are installed.
  cat > "$mock_dir/claude" <<MOCK
#!/usr/bin/env bash
if [ -f "${settings_file}" ]; then
  count=\$(jq '.hooks.stop | length' "${settings_file}" 2>/dev/null)
  echo "{\"result\":\"hooks_count=\${count}\"}"
else
  echo '{"result":"no_settings_file"}'
fi
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"
  AUTOPILOT_TIMEOUT_CODER=10
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  local output_file exit_code=0
  output_file="$(run_coder "$TEST_PROJECT_DIR" 1 "Task")" || exit_code=$?

  # Check that mock claude saw hooks installed.
  local content
  content="$(cat "$output_file")"
  [[ "$content" == *"hooks_count=2"* ]]

  # After run_coder, hooks should be cleaned up (backup restored).
  # Since there was no original settings, backup may not exist.
  # Hooks should have been removed.
  run hooks_installed "$TEST_HOOKS_DIR"
  [ "$status" -eq 1 ]

  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

@test "run_coder logs to pipeline log" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"done"}'
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"
  AUTOPILOT_TIMEOUT_CODER=10
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  local output_file
  output_file="$(run_coder "$TEST_PROJECT_DIR" 5 "Task body")" || true

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"Spawning Coder for task 5"* ]]
  [[ "$log_content" == *"Coder completed task 5"* ]]

  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

@test "run_coder includes completed summary in prompt" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
# Echo all args to output to verify prompt content.
for arg in "$@"; do
  echo "arg: $arg"
done
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"
  AUTOPILOT_TIMEOUT_CODER=10
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  local output_file exit_code=0
  output_file="$(run_coder "$TEST_PROJECT_DIR" 2 "Task body" "Task 1: built X")" || exit_code=$?

  local content
  content="$(cat "$output_file")"
  [[ "$content" == *"Task 1: built X"* ]]

  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

@test "run_coder passes prompt with task body via --print" {
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
  AUTOPILOT_TIMEOUT_CODER=10
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  local output_file
  output_file="$(run_coder "$TEST_PROJECT_DIR" 3 "Implement widgets")" || true

  local content
  content="$(cat "$output_file")"
  [[ "$content" == *"--print"* ]]
  [[ "$content" == *"Implement widgets"* ]]

  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}
