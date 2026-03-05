#!/usr/bin/env bats
# Tests for lib/fixer.sh — Fixer agent spawning, session resume,
# review comment fetching, diagnosis hints, and hook management.

setup() {
  TEST_PROJECT_DIR="$(mktemp -d)"
  TEST_HOOKS_DIR="$(mktemp -d)"

  # Unset all AUTOPILOT_* env vars to start clean.
  while IFS= read -r var; do
    unset "$var"
  done < <(env | grep '^AUTOPILOT_' | cut -d= -f1)

  unset CLAUDECODE
  unset CLAUDE_CONFIG_DIR

  # Source fixer.sh (which sources config, state, claude, hooks, git-ops).
  source "$BATS_TEST_DIRNAME/../lib/fixer.sh"
  load_config "$TEST_PROJECT_DIR"

  # Initialize pipeline state dir for log_msg.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/locks"

  # Override prompts dir to use real prompts in repo.
  _FIXER_PROMPTS_DIR="$BATS_TEST_DIRNAME/../prompts"

  # Set up a fake git repo for _get_repo_slug.
  git -C "$TEST_PROJECT_DIR" init -q
  git -C "$TEST_PROJECT_DIR" remote add origin \
    "https://github.com/testowner/testrepo.git"
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR"
  rm -rf "$TEST_HOOKS_DIR"
}

# --- _get_repo_slug ---

@test "_get_repo_slug extracts owner/repo from HTTPS URL" {
  local result
  result="$(_get_repo_slug "$TEST_PROJECT_DIR")"
  [ "$result" = "testowner/testrepo" ]
}

@test "_get_repo_slug extracts owner/repo from SSH URL" {
  git -C "$TEST_PROJECT_DIR" remote set-url origin \
    "git@github.com:myorg/myproject.git"
  local result
  result="$(_get_repo_slug "$TEST_PROJECT_DIR")"
  [ "$result" = "myorg/myproject" ]
}

@test "_get_repo_slug handles URL without .git suffix" {
  git -C "$TEST_PROJECT_DIR" remote set-url origin \
    "https://github.com/owner/repo"
  local result
  result="$(_get_repo_slug "$TEST_PROJECT_DIR")"
  [ "$result" = "owner/repo" ]
}

@test "_get_repo_slug fails for non-github URL" {
  git -C "$TEST_PROJECT_DIR" remote set-url origin \
    "https://gitlab.com/owner/repo.git"
  run _get_repo_slug "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
}

@test "_get_repo_slug fails for directory without git" {
  local no_git_dir
  no_git_dir="$(mktemp -d)"
  run _get_repo_slug "$no_git_dir"
  [ "$status" -ne 0 ]
  rm -rf "$no_git_dir"
}

# --- _read_fixer_prompt ---

@test "_read_fixer_prompt reads prompts/fix-and-merge.md" {
  local result
  result="$(_read_fixer_prompt)"
  [[ "$result" == *"Fixer Agent"* ]]
  [[ "$result" == *"Review Comments"* ]]
}

@test "_read_fixer_prompt fails when prompt file missing" {
  _FIXER_PROMPTS_DIR="$TEST_PROJECT_DIR/nonexistent"
  run _read_fixer_prompt
  [ "$status" -eq 1 ]
}

# --- build_fixer_prompt ---

@test "build_fixer_prompt includes PR number and branch" {
  local result
  result="$(build_fixer_prompt 42 "autopilot/task-5" "Fix the bug" "owner/repo")"
  [[ "$result" == *"PR #42"* ]]
  [[ "$result" == *"autopilot/task-5"* ]]
}

@test "build_fixer_prompt includes review text" {
  local result
  result="$(build_fixer_prompt 10 "branch" "Please fix variable naming" "o/r")"
  [[ "$result" == *"Please fix variable naming"* ]]
}

@test "build_fixer_prompt includes repo slug" {
  local result
  result="$(build_fixer_prompt 10 "branch" "text" "myorg/myrepo")"
  [[ "$result" == *"myorg/myrepo"* ]]
}

@test "build_fixer_prompt includes instructions section" {
  local result
  result="$(build_fixer_prompt 10 "branch" "text" "o/r")"
  [[ "$result" == *"Instructions"* ]]
  [[ "$result" == *"Do NOT merge"* ]]
}

@test "build_fixer_prompt omits hints section when empty" {
  local result
  result="$(build_fixer_prompt 10 "branch" "text" "o/r" "")"
  [[ "$result" != *"Diagnosis from Previous Attempt"* ]]
}

@test "build_fixer_prompt includes diagnosis hints when provided" {
  local hints="The merger rejected because tests fail on edge case X."
  local result
  result="$(build_fixer_prompt 10 "branch" "text" "o/r" "$hints")"
  [[ "$result" == *"Diagnosis from Previous Attempt"* ]]
  [[ "$result" == *"tests fail on edge case X"* ]]
}

# --- consume_diagnosis_hints ---

@test "consume_diagnosis_hints reads and deletes hints file" {
  local hints_file="${TEST_PROJECT_DIR}/.autopilot/diagnosis-hints-task-3.md"
  echo "Fix the flaky test" > "$hints_file"

  local result
  result="$(consume_diagnosis_hints "$TEST_PROJECT_DIR" 3)"
  [[ "$result" == *"Fix the flaky test"* ]]

  # File should be deleted after consumption.
  [ ! -f "$hints_file" ]
}

@test "consume_diagnosis_hints returns empty for missing hints file" {
  local result
  result="$(consume_diagnosis_hints "$TEST_PROJECT_DIR" 99)"
  [ -z "$result" ]
}

@test "consume_diagnosis_hints returns empty for empty hints file" {
  local hints_file="${TEST_PROJECT_DIR}/.autopilot/diagnosis-hints-task-7.md"
  touch "$hints_file"

  local result
  result="$(consume_diagnosis_hints "$TEST_PROJECT_DIR" 7)"
  [ -z "$result" ]
}

# --- _extract_session_id ---

@test "_extract_session_id extracts session_id from JSON file" {
  local json_file="${TEST_PROJECT_DIR}/output.json"
  echo '{"result":"done","session_id":"sess-abc123"}' > "$json_file"

  local result
  result="$(_extract_session_id "$json_file")"
  [ "$result" = "sess-abc123" ]
}

@test "_extract_session_id fails for missing file" {
  run _extract_session_id "$TEST_PROJECT_DIR/nonexistent.json"
  [ "$status" -ne 0 ]
}

@test "_extract_session_id fails for JSON without session_id" {
  local json_file="${TEST_PROJECT_DIR}/output.json"
  echo '{"result":"done"}' > "$json_file"

  run _extract_session_id "$json_file"
  [ "$status" -ne 0 ]
}

@test "_extract_session_id fails for invalid JSON" {
  local json_file="${TEST_PROJECT_DIR}/output.json"
  echo 'not valid json' > "$json_file"

  run _extract_session_id "$json_file"
  [ "$status" -ne 0 ]
}

# --- _resolve_session_id ---

@test "_resolve_session_id prefers fixer JSON over coder JSON" {
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  echo '{"session_id":"fixer-sess"}' > "${log_dir}/fixer-task-5.json"
  echo '{"session_id":"coder-sess"}' > "${log_dir}/coder-task-5.json"

  local result
  result="$(_resolve_session_id "$TEST_PROJECT_DIR" 5)"
  [ "$result" = "fixer-sess:fixer" ]
}

@test "_resolve_session_id falls back to coder JSON" {
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  echo '{"session_id":"coder-sess"}' > "${log_dir}/coder-task-3.json"

  local result
  result="$(_resolve_session_id "$TEST_PROJECT_DIR" 3)"
  [ "$result" = "coder-sess:coder" ]
}

@test "_resolve_session_id returns failure for cold start" {
  run _resolve_session_id "$TEST_PROJECT_DIR" 99
  [ "$status" -ne 0 ]
}

@test "_resolve_session_id skips fixer JSON without session_id" {
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  echo '{"result":"done"}' > "${log_dir}/fixer-task-4.json"
  echo '{"session_id":"coder-sess"}' > "${log_dir}/coder-task-4.json"

  local result
  result="$(_resolve_session_id "$TEST_PROJECT_DIR" 4)"
  [ "$result" = "coder-sess:coder" ]
}

@test "_resolve_session_id cold starts when both lack session_id" {
  local log_dir="${TEST_PROJECT_DIR}/.autopilot/logs"
  echo '{"result":"done"}' > "${log_dir}/fixer-task-6.json"
  echo '{"result":"done"}' > "${log_dir}/coder-task-6.json"

  run _resolve_session_id "$TEST_PROJECT_DIR" 6
  [ "$status" -ne 0 ]
}

# --- _save_fixer_output ---

@test "_save_fixer_output copies output to logs dir" {
  local output_file
  output_file="$(mktemp)"
  echo '{"result":"fixed","session_id":"new-sess"}' > "$output_file"

  _save_fixer_output "$TEST_PROJECT_DIR" 5 "$output_file"

  local saved="${TEST_PROJECT_DIR}/.autopilot/logs/fixer-task-5.json"
  [ -f "$saved" ]

  local saved_content
  saved_content="$(cat "$saved")"
  [[ "$saved_content" == *"new-sess"* ]]

  rm -f "$output_file"
}

@test "_save_fixer_output handles missing output file gracefully" {
  run _save_fixer_output "$TEST_PROJECT_DIR" 5 "/nonexistent/file"
  [ "$status" -eq 0 ]
}

# --- run_fixer (with mock claude and gh) ---

@test "run_fixer calls claude with review comments and returns output" {
  local mock_dir
  mock_dir="$(mktemp -d)"

  # Mock claude.
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"fixes applied","session_id":"fix-sess-1"}'
MOCK
  chmod +x "$mock_dir/claude"

  # Mock gh to return review comments.
  cat > "$mock_dir/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
MOCK
  chmod +x "$mock_dir/gh"

  # Mock timeout to pass through.
  cat > "$mock_dir/timeout" <<'MOCK'
#!/usr/bin/env bash
shift  # skip timeout value
"$@"
MOCK
  chmod +x "$mock_dir/timeout"

  export PATH="$mock_dir:$PATH"
  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"
  AUTOPILOT_TIMEOUT_FIXER=10
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  local output_file exit_code=0
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 1 42)" || exit_code=$?

  [ "$exit_code" -eq 0 ]
  [ -f "$output_file" ]

  local content
  content="$(cat "$output_file")"
  [[ "$content" == *"fixes applied"* ]]

  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

@test "run_fixer uses --resume when fixer JSON has session_id" {
  local mock_dir
  mock_dir="$(mktemp -d)"

  # Create fixer JSON with session_id.
  echo '{"session_id":"prev-fixer-sess"}' > \
    "${TEST_PROJECT_DIR}/.autopilot/logs/fixer-task-2.json"

  # Mock claude that captures args.
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
for arg in "$@"; do
  echo "arg: $arg"
done
MOCK
  chmod +x "$mock_dir/claude"

  # Mock gh.
  cat > "$mock_dir/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
MOCK
  chmod +x "$mock_dir/gh"

  # Mock timeout.
  cat > "$mock_dir/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$mock_dir/timeout"

  export PATH="$mock_dir:$PATH"
  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"
  AUTOPILOT_TIMEOUT_FIXER=10
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  local output_file
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 2 99)" || true

  local content
  content="$(cat "$output_file")"
  [[ "$content" == *"--resume"* ]]
  [[ "$content" == *"prev-fixer-sess"* ]]

  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

@test "run_fixer uses --resume from coder JSON when no fixer JSON" {
  local mock_dir
  mock_dir="$(mktemp -d)"

  # Create coder JSON with session_id (no fixer JSON).
  echo '{"session_id":"coder-sess-abc"}' > \
    "${TEST_PROJECT_DIR}/.autopilot/logs/coder-task-3.json"

  # Mock claude.
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
for arg in "$@"; do
  echo "arg: $arg"
done
MOCK
  chmod +x "$mock_dir/claude"

  # Mock gh.
  cat > "$mock_dir/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
MOCK
  chmod +x "$mock_dir/gh"

  # Mock timeout.
  cat > "$mock_dir/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$mock_dir/timeout"

  export PATH="$mock_dir:$PATH"
  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"
  AUTOPILOT_TIMEOUT_FIXER=10
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  local output_file
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 3 55)" || true

  local content
  content="$(cat "$output_file")"
  [[ "$content" == *"--resume"* ]]
  [[ "$content" == *"coder-sess-abc"* ]]

  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

@test "run_fixer uses --system-prompt on cold start" {
  local mock_dir
  mock_dir="$(mktemp -d)"

  # No fixer or coder JSON — cold start.

  # Mock claude.
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
for arg in "$@"; do
  echo "arg: $arg"
done
MOCK
  chmod +x "$mock_dir/claude"

  # Mock gh.
  cat > "$mock_dir/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
MOCK
  chmod +x "$mock_dir/gh"

  # Mock timeout.
  cat > "$mock_dir/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$mock_dir/timeout"

  export PATH="$mock_dir:$PATH"
  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"
  AUTOPILOT_TIMEOUT_FIXER=10
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  local output_file
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 8 77)" || true

  local content
  content="$(cat "$output_file")"
  [[ "$content" == *"--system-prompt"* ]]
  [[ "$content" != *"--resume"* ]]

  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

@test "run_fixer saves output for future session resume" {
  local mock_dir
  mock_dir="$(mktemp -d)"

  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"done","session_id":"saved-sess"}'
MOCK
  chmod +x "$mock_dir/claude"

  cat > "$mock_dir/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
MOCK
  chmod +x "$mock_dir/gh"

  cat > "$mock_dir/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$mock_dir/timeout"

  export PATH="$mock_dir:$PATH"
  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"
  AUTOPILOT_TIMEOUT_FIXER=10
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  run_fixer "$TEST_PROJECT_DIR" 4 33 || true

  local saved="${TEST_PROJECT_DIR}/.autopilot/logs/fixer-task-4.json"
  [ -f "$saved" ]

  local saved_content
  saved_content="$(cat "$saved")"
  [[ "$saved_content" == *"saved-sess"* ]]

  rm -rf "$mock_dir"
}

@test "run_fixer installs and removes hooks" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  local settings_file="${TEST_HOOKS_DIR}/settings.json"

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

  cat > "$mock_dir/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
MOCK
  chmod +x "$mock_dir/gh"

  cat > "$mock_dir/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$mock_dir/timeout"

  export PATH="$mock_dir:$PATH"
  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"
  AUTOPILOT_TIMEOUT_FIXER=10
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  local output_file
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 1 42)" || true

  # Mock claude should have seen hooks installed.
  local content
  content="$(cat "$output_file")"
  [[ "$content" == *"hooks_count=2"* ]]

  # After run_fixer, hooks should be cleaned up.
  run hooks_installed "$TEST_HOOKS_DIR"
  [ "$status" -eq 1 ]

  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

@test "run_fixer returns claude exit code on failure" {
  local mock_dir
  mock_dir="$(mktemp -d)"

  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"error"}'
exit 1
MOCK
  chmod +x "$mock_dir/claude"

  cat > "$mock_dir/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
MOCK
  chmod +x "$mock_dir/gh"

  cat > "$mock_dir/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$mock_dir/timeout"

  export PATH="$mock_dir:$PATH"
  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"
  AUTOPILOT_TIMEOUT_FIXER=10
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  local output_file exit_code=0
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 1 42)" || exit_code=$?

  [ "$exit_code" -eq 1 ]

  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

@test "run_fixer includes diagnosis hints in prompt" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  local hints_file="${TEST_PROJECT_DIR}/.autopilot/diagnosis-hints-task-9.md"
  echo "The merger rejected: test_edge_case fails" > "$hints_file"

  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
for arg in "$@"; do
  echo "arg: $arg"
done
MOCK
  chmod +x "$mock_dir/claude"

  cat > "$mock_dir/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
MOCK
  chmod +x "$mock_dir/gh"

  cat > "$mock_dir/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$mock_dir/timeout"

  export PATH="$mock_dir:$PATH"
  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"
  AUTOPILOT_TIMEOUT_FIXER=10
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  local output_file
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 9 88)" || true

  local content
  content="$(cat "$output_file")"
  [[ "$content" == *"test_edge_case fails"* ]]
  [[ "$content" == *"Diagnosis from Previous Attempt"* ]]

  # Hints file should have been consumed (deleted).
  [ ! -f "$hints_file" ]

  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

@test "run_fixer logs to pipeline log" {
  local mock_dir
  mock_dir="$(mktemp -d)"

  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"done"}'
MOCK
  chmod +x "$mock_dir/claude"

  cat > "$mock_dir/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
MOCK
  chmod +x "$mock_dir/gh"

  cat > "$mock_dir/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$mock_dir/timeout"

  export PATH="$mock_dir:$PATH"
  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"
  AUTOPILOT_TIMEOUT_FIXER=10
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  local output_file
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 5 42)" || true

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"Spawning fixer for task 5"* ]]
  [[ "$log_content" == *"Fixer completed task 5, PR #42"* ]]

  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

@test "run_fixer uses AUTOPILOT_TIMEOUT_FIXER" {
  local mock_dir
  mock_dir="$(mktemp -d)"

  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
sleep 30
echo '{"result":"should not reach here"}'
MOCK
  chmod +x "$mock_dir/claude"

  cat > "$mock_dir/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
MOCK
  chmod +x "$mock_dir/gh"

  export PATH="$mock_dir:$PATH"
  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"
  AUTOPILOT_TIMEOUT_FIXER=1
  AUTOPILOT_CODER_CONFIG_DIR="$TEST_HOOKS_DIR"

  local output_file exit_code=0
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 1 42)" || exit_code=$?

  [ "$exit_code" -eq 124 ]

  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

@test "run_fixer uses AUTOPILOT_CODER_CONFIG_DIR" {
  local mock_dir
  mock_dir="$(mktemp -d)"

  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo "{\"result\":\"config=${CLAUDE_CONFIG_DIR:-unset}\"}"
MOCK
  chmod +x "$mock_dir/claude"

  cat > "$mock_dir/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
MOCK
  chmod +x "$mock_dir/gh"

  cat > "$mock_dir/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$mock_dir/timeout"

  export PATH="$mock_dir:$PATH"
  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"
  AUTOPILOT_TIMEOUT_FIXER=10
  AUTOPILOT_CODER_CONFIG_DIR="/custom/fixer/config"

  local output_file
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 1 42)" || true

  local content
  content="$(cat "$output_file")"
  [[ "$content" == *"config=/custom/fixer/config"* ]]

  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}

# --- fetch_review_comments (with mock gh) ---

@test "fetch_review_comments returns empty when gh returns empty arrays" {
  local mock_dir
  mock_dir="$(mktemp -d)"

  cat > "$mock_dir/gh" <<'MOCK'
#!/usr/bin/env bash
echo ''
MOCK
  chmod +x "$mock_dir/gh"

  cat > "$mock_dir/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$mock_dir/timeout"

  export PATH="$mock_dir:$PATH"

  local result
  result="$(fetch_review_comments "$TEST_PROJECT_DIR" 42)"
  [ -z "$result" ]

  rm -rf "$mock_dir"
}

@test "fetch_review_comments formats review sections" {
  local mock_dir
  mock_dir="$(mktemp -d)"

  # Mock gh to return different content for different API endpoints.
  cat > "$mock_dir/gh" <<'MOCK'
#!/usr/bin/env bash
case "$3" in
  */reviews) echo "review body text" ;;
  */comments) echo "inline comment text" ;;
  */issues/*) echo "issue comment text" ;;
esac
MOCK
  chmod +x "$mock_dir/gh"

  cat > "$mock_dir/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$mock_dir/timeout"

  export PATH="$mock_dir:$PATH"

  local result
  result="$(fetch_review_comments "$TEST_PROJECT_DIR" 42)"
  [[ "$result" == *"Review Comments"* ]]
  [[ "$result" == *"Inline Comments"* ]]
  [[ "$result" == *"Discussion"* ]]

  rm -rf "$mock_dir"
}

@test "fetch_review_comments fails without repo slug" {
  local no_git_dir
  no_git_dir="$(mktemp -d)"
  mkdir -p "$no_git_dir/.autopilot/logs"

  run fetch_review_comments "$no_git_dir" 42
  [ "$status" -ne 0 ]

  rm -rf "$no_git_dir"
}
