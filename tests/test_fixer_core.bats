#!/usr/bin/env bats
# Tests for fixer core functions — get_repo_slug, prompt building,
# diagnosis hints, session ID resolution, and output saving.
# Split from test_fixer.bats for parallel execution.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/fixer_setup

# --- get_repo_slug ---

@test "get_repo_slug extracts owner/repo from HTTPS URL" {
  local result
  result="$(get_repo_slug "$TEST_PROJECT_DIR")"
  [ "$result" = "testowner/testrepo" ]
}

@test "get_repo_slug extracts owner/repo from SSH URL" {
  git -C "$TEST_PROJECT_DIR" remote set-url origin \
    "git@github.com:myorg/myproject.git"
  local result
  result="$(get_repo_slug "$TEST_PROJECT_DIR")"
  [ "$result" = "myorg/myproject" ]
}

@test "get_repo_slug handles URL without .git suffix" {
  git -C "$TEST_PROJECT_DIR" remote set-url origin \
    "https://github.com/owner/repo"
  local result
  result="$(get_repo_slug "$TEST_PROJECT_DIR")"
  [ "$result" = "owner/repo" ]
}

@test "get_repo_slug fails for non-github URL" {
  git -C "$TEST_PROJECT_DIR" remote set-url origin \
    "https://gitlab.com/owner/repo.git"
  run get_repo_slug "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
}

@test "get_repo_slug fails for directory without git" {
  local no_git_dir="$BATS_TEST_TMPDIR/no_git_dir"
  mkdir -p "$no_git_dir"
  run get_repo_slug "$no_git_dir"
  [ "$status" -ne 0 ]
}

# --- _read_prompt_file ---

@test "_read_prompt_file reads prompts/fix-and-merge.md" {
  local result
  result="$(_read_prompt_file "${_FIXER_PROMPTS_DIR}/fix-and-merge.md")"
  echo "$result" | grep -qF "Fixer Agent"
  echo "$result" | grep -qF "Review Comments"
}

@test "_read_prompt_file fails when prompt file missing" {
  run _read_prompt_file "$TEST_PROJECT_DIR/nonexistent/prompt.md"
  [ "$status" -eq 1 ]
}

# --- build_fixer_prompt ---

@test "build_fixer_prompt includes PR number and branch" {
  local result
  result="$(build_fixer_prompt 42 "autopilot/task-5" "Fix the bug" "owner/repo")"
  echo "$result" | grep -qF "PR #42"
  echo "$result" | grep -qF "autopilot/task-5"
}

@test "build_fixer_prompt includes review text" {
  local result
  result="$(build_fixer_prompt 10 "branch" "Please fix variable naming" "o/r")"
  echo "$result" | grep -qF "Please fix variable naming"
}

@test "build_fixer_prompt includes repo slug" {
  local result
  result="$(build_fixer_prompt 10 "branch" "text" "myorg/myrepo")"
  echo "$result" | grep -qF "myorg/myrepo"
}

@test "build_fixer_prompt includes instructions section" {
  local result
  result="$(build_fixer_prompt 10 "branch" "text" "o/r")"
  echo "$result" | grep -qF "Instructions"
  echo "$result" | grep -qF "Do NOT merge"
}

@test "build_fixer_prompt omits hints section when empty" {
  local ctx
  ctx="$(build_fixer_context_sections "" "" "")"
  local result
  result="$(build_fixer_prompt 10 "branch" "text" "o/r" "$ctx")"
  ! echo "$result" | grep -qF "Diagnosis from Previous Attempt"
}

@test "build_fixer_prompt includes diagnosis hints when provided" {
  local hints="The merger rejected because tests fail on edge case X."
  local ctx
  ctx="$(build_fixer_context_sections "$hints" "" "")"
  local result
  result="$(build_fixer_prompt 10 "branch" "text" "o/r" "$ctx")"
  echo "$result" | grep -qF "Diagnosis from Previous Attempt"
  echo "$result" | grep -qF "tests fail on edge case X"
}

# --- consume_diagnosis_hints ---

@test "consume_diagnosis_hints reads and deletes hints file" {
  local hints_file="${TEST_PROJECT_DIR}/.autopilot/diagnosis-hints-task-3.md"
  echo "Fix the flaky test" > "$hints_file"

  local result
  result="$(consume_diagnosis_hints "$TEST_PROJECT_DIR" 3)"
  echo "$result" | grep -qF "Fix the flaky test"

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

@test "_resolve_session_id finds coder JSON saved by _save_coder_output" {
  # Simulate what run_coder does: save output to logs/coder-task-N.json.
  source "$BATS_TEST_DIRNAME/../lib/coder.sh"

  local output_file
  output_file="$(mktemp)"
  echo '{"result":"done","session_id":"saved-coder-sess"}' > "$output_file"

  _save_coder_output "$TEST_PROJECT_DIR" 10 "$output_file"

  local result
  result="$(_resolve_session_id "$TEST_PROJECT_DIR" 10)"
  [ "$result" = "saved-coder-sess:coder" ]

  rm -f "$output_file"
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
  echo "$saved_content" | grep -qF "new-sess"

  rm -f "$output_file"
}

@test "_save_fixer_output handles missing output file gracefully" {
  run _save_fixer_output "$TEST_PROJECT_DIR" 5 "/nonexistent/file"
  [ "$status" -eq 0 ]
}
