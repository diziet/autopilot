#!/usr/bin/env bats
# Tests for lib/spec-review.sh — Periodic spec compliance review:
# interval check, spec reading, diff fetching, prompt construction,
# output persistence, issue creation, and end-to-end with mocked Claude.

load helpers/test_template

# Source modules once at file level — inherited by all test subshells.
source "${BATS_TEST_DIRNAME}/../lib/spec-review.sh"

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template

  # Initialize pipeline state dir for log_msg.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/locks"

  # Override prompts dir to use real prompts in repo.
  _SPEC_REVIEW_PROMPTS_DIR="$BATS_TEST_DIRNAME/../prompts"
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR"
  rm -rf "$TEST_MOCK_BIN"
}

# --- Exit Code Constants ---

@test "SPEC_REVIEW_OK is 0" {
  [ "$SPEC_REVIEW_OK" -eq 0 ]
}

@test "SPEC_REVIEW_SKIP is 1" {
  [ "$SPEC_REVIEW_SKIP" -eq 1 ]
}

@test "SPEC_REVIEW_ERROR is 2" {
  [ "$SPEC_REVIEW_ERROR" -eq 2 ]
}

# --- should_run_spec_review ---

@test "should_run_spec_review returns 0 when task is divisible by interval" {
  AUTOPILOT_SPEC_REVIEW_INTERVAL=5
  should_run_spec_review 5
  should_run_spec_review 10
  should_run_spec_review 15
}

@test "should_run_spec_review returns 1 when task is not divisible" {
  AUTOPILOT_SPEC_REVIEW_INTERVAL=5
  ! should_run_spec_review 1
  ! should_run_spec_review 3
  ! should_run_spec_review 7
}

@test "should_run_spec_review disabled when interval is 0" {
  AUTOPILOT_SPEC_REVIEW_INTERVAL=0
  ! should_run_spec_review 5
  ! should_run_spec_review 10
  ! should_run_spec_review 0
}

@test "should_run_spec_review uses default interval of 5" {
  unset AUTOPILOT_SPEC_REVIEW_INTERVAL
  should_run_spec_review 5
  ! should_run_spec_review 3
}

@test "should_run_spec_review with custom interval" {
  AUTOPILOT_SPEC_REVIEW_INTERVAL=3
  should_run_spec_review 3
  should_run_spec_review 6
  should_run_spec_review 9
  ! should_run_spec_review 5
}

@test "should_run_spec_review rejects empty task number" {
  AUTOPILOT_SPEC_REVIEW_INTERVAL=5
  ! should_run_spec_review ""
}

@test "should_run_spec_review rejects non-numeric task number" {
  AUTOPILOT_SPEC_REVIEW_INTERVAL=5
  ! should_run_spec_review "abc"
  ! should_run_spec_review "5a"
  ! should_run_spec_review "../etc"
}

@test "should_run_spec_review rejects task 0" {
  AUTOPILOT_SPEC_REVIEW_INTERVAL=5
  # Tasks start at 1; task 0 should never trigger a review.
  ! should_run_spec_review 0
}

# --- _get_spec_file ---

@test "_get_spec_file returns first context file" {
  local spec_file="${TEST_PROJECT_DIR}/docs/spec.md"
  mkdir -p "${TEST_PROJECT_DIR}/docs"
  echo "spec content" > "$spec_file"

  AUTOPILOT_CONTEXT_FILES="docs/spec.md"
  local output file_path
  output="$(_get_spec_file "$TEST_PROJECT_DIR")"
  file_path="$(echo "$output" | head -n 1)"
  [ "$file_path" = "$spec_file" ]
}

@test "_get_spec_file returns empty when no context files and no tasks file" {
  AUTOPILOT_CONTEXT_FILES=""
  unset AUTOPILOT_TASKS_FILE
  local result
  result="$(_get_spec_file "$TEST_PROJECT_DIR")"
  [ -z "$result" ]
}

@test "_get_spec_file falls back to tasks file when no context files" {
  AUTOPILOT_CONTEXT_FILES=""
  unset AUTOPILOT_TASKS_FILE
  echo "## Task 1" > "${TEST_PROJECT_DIR}/tasks.md"

  local output
  output="$(_get_spec_file "$TEST_PROJECT_DIR")"
  local file_path source
  file_path="$(echo "$output" | head -n 1)"
  source="$(echo "$output" | sed -n '2p')"
  [ "$file_path" = "${TEST_PROJECT_DIR}/tasks.md" ]
  [ "$source" = "tasks-file" ]
}

@test "_get_spec_file sets source to context-files when context files configured" {
  mkdir -p "${TEST_PROJECT_DIR}/docs"
  echo "spec content" > "${TEST_PROJECT_DIR}/docs/spec.md"
  AUTOPILOT_CONTEXT_FILES="docs/spec.md"

  local output source
  output="$(_get_spec_file "$TEST_PROJECT_DIR")"
  source="$(echo "$output" | sed -n '2p')"
  [ "$source" = "context-files" ]
}

@test "_get_spec_file prefers context files over tasks file" {
  mkdir -p "${TEST_PROJECT_DIR}/docs"
  echo "spec content" > "${TEST_PROJECT_DIR}/docs/spec.md"
  echo "## Task 1" > "${TEST_PROJECT_DIR}/tasks.md"
  AUTOPILOT_CONTEXT_FILES="docs/spec.md"

  local output file_path source
  output="$(_get_spec_file "$TEST_PROJECT_DIR")"
  file_path="$(echo "$output" | head -n 1)"
  source="$(echo "$output" | sed -n '2p')"
  [ "$file_path" = "${TEST_PROJECT_DIR}/docs/spec.md" ]
  [ "$source" = "context-files" ]
}

@test "_get_spec_file returns first of multiple context files" {
  mkdir -p "${TEST_PROJECT_DIR}/docs"
  echo "spec" > "${TEST_PROJECT_DIR}/docs/spec.md"
  echo "other" > "${TEST_PROJECT_DIR}/docs/other.md"

  AUTOPILOT_CONTEXT_FILES="docs/spec.md:docs/other.md"
  local output file_path
  output="$(_get_spec_file "$TEST_PROJECT_DIR")"
  file_path="$(echo "$output" | head -n 1)"
  [ "$file_path" = "${TEST_PROJECT_DIR}/docs/spec.md" ]
}

# --- _read_spec_content ---

@test "_read_spec_content reads small file fully" {
  local spec="${TEST_PROJECT_DIR}/spec.md"
  echo "# My Spec" > "$spec"

  local result
  result="$(_read_spec_content "$spec")"
  echo "$result" | grep -qF "# My Spec"
}

@test "_read_spec_content truncates large files" {
  local spec="${TEST_PROJECT_DIR}/big-spec.md"
  # Write 60000 bytes (exceeds _SPEC_REVIEW_MAX_SPEC_BYTES=50000).
  head -c 60000 /dev/urandom | base64 > "$spec"

  local result
  result="$(_read_spec_content "$spec")"
  echo "$result" | grep -qF "truncated"
}

@test "_read_spec_content returns error for missing file" {
  run _read_spec_content "/nonexistent/file.md"
  [ "$status" -ne 0 ]
}

@test "_read_spec_content returns error for empty file" {
  local spec="${TEST_PROJECT_DIR}/empty.md"
  touch "$spec"

  run _read_spec_content "$spec"
  [ "$status" -ne 0 ]
}

# --- _fetch_merged_prs ---

@test "_fetch_merged_prs returns PR numbers from gh" {
  # Mock gh to return PR numbers.
  cat > "${TEST_MOCK_BIN}/gh" <<'MOCK'
#!/bin/bash
echo "42"
echo "41"
echo "40"
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"
  _create_mock_timeout

  local result
  result="$(_fetch_merged_prs "owner/repo")"
  echo "$result" | grep -qF "42"
  echo "$result" | grep -qF "40"
}

@test "_fetch_merged_prs returns error when no PRs found" {
  cat > "${TEST_MOCK_BIN}/gh" <<'MOCK'
#!/bin/bash
echo ""
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"
  _create_mock_timeout

  run _fetch_merged_prs "owner/repo"
  [ "$status" -ne 0 ]
}

# --- _fetch_combined_diff ---

@test "_fetch_combined_diff concatenates diffs for each PR" {
  # Mock gh that returns diff per PR number.
  cat > "${TEST_MOCK_BIN}/gh" <<'MOCK'
#!/bin/bash
# Detect "pr diff" subcommand
if [[ "$1" == "pr" && "$2" == "diff" ]]; then
  echo "diff for PR $3"
fi
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"
  _create_mock_timeout

  local prs
  prs=$'10\n11\n12'
  local result
  result="$(_fetch_combined_diff "owner/repo" "$prs")"
  echo "$result" | grep -qF "PR #10"
  echo "$result" | grep -qF "PR #12"
  echo "$result" | grep -qF "diff for PR 10"
}

@test "_fetch_combined_diff returns error when no diffs available" {
  cat > "${TEST_MOCK_BIN}/gh" <<'MOCK'
#!/bin/bash
exit 1
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"
  _create_mock_timeout

  run _fetch_combined_diff "owner/repo" "10"
  [ "$status" -ne 0 ]
}

@test "_fetch_combined_diff skips failed PR diffs" {
  # Mock gh that fails for PR 11 only.
  cat > "${TEST_MOCK_BIN}/gh" <<'MOCK'
#!/bin/bash
if [[ "$1" == "pr" && "$2" == "diff" ]]; then
  if [[ "$3" == "11" ]]; then
    exit 1
  fi
  echo "diff for PR $3"
fi
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"
  _create_mock_timeout

  local prs
  prs=$'10\n11\n12'
  local result
  result="$(_fetch_combined_diff "owner/repo" "$prs")"
  echo "$result" | grep -qF "PR #10"
  echo "$result" | grep -qF "PR #12"
  ! echo "$result" | grep -qF "PR #11"
}

# --- build_spec_review_prompt ---

@test "build_spec_review_prompt includes spec content" {
  local result
  result="$(build_spec_review_prompt "my spec text" "diff content")"
  echo "$result" | grep -qF "my spec text"
}

@test "build_spec_review_prompt includes diff content" {
  local result
  result="$(build_spec_review_prompt "spec" "added new function")"
  echo "$result" | grep -qF "added new function"
}

@test "build_spec_review_prompt includes system prompt from spec-compliance.md" {
  local result
  result="$(build_spec_review_prompt "spec" "diff")"
  echo "$result" | grep -qF "Spec Compliance"
}

@test "build_spec_review_prompt includes review request" {
  local result
  result="$(build_spec_review_prompt "spec" "diff")"
  echo "$result" | grep -qF "Report any deviations"
}

@test "build_spec_review_prompt includes PR count reference" {
  local result
  result="$(build_spec_review_prompt "spec" "diff")"
  echo "$result" | grep -qF "Last 5 Merged PRs"
}

# --- _has_issues ---

@test "_has_issues returns 0 (true) when issues found" {
  _has_issues "Found deviations: missing auth module"
}

@test "_has_issues returns 1 (false) when verdict is compliant" {
  ! _has_issues "VERDICT: COMPLIANT — all checked requirements are correctly implemented."
}

@test "_has_issues returns 0 for empty review output" {
  _has_issues ""
}

@test "_has_issues detects partial verdict match" {
  ! _has_issues "Some text before VERDICT: COMPLIANT and after"
}

# --- _save_review_output ---

@test "_save_review_output writes to correct file" {
  _save_review_output "$TEST_PROJECT_DIR" 10 "Review findings here"

  local target="${TEST_PROJECT_DIR}/.autopilot/logs/spec-review-after-task-10.md"
  [ -f "$target" ]
  grep -qF "Review findings here" "$target"
}

@test "_save_review_output creates logs dir if needed" {
  local fresh_dir
  fresh_dir="$(mktemp -d)"
  mkdir -p "${fresh_dir}/.autopilot/logs"

  _save_review_output "$fresh_dir" 5 "findings"
  [ -f "${fresh_dir}/.autopilot/logs/spec-review-after-task-5.md" ]
  rm -rf "$fresh_dir"
}

@test "_save_review_output overwrites existing output" {
  local target="${TEST_PROJECT_DIR}/.autopilot/logs/spec-review-after-task-3.md"
  echo "old review" > "$target"

  _save_review_output "$TEST_PROJECT_DIR" 3 "new review"

  local content
  content="$(cat "$target")"
  [[ "$content" == *"new review"* ]]
  ! echo "$content" | grep -qF "old review"
}

# --- read_spec_review ---

@test "read_spec_review returns content for existing review" {
  local target="${TEST_PROJECT_DIR}/.autopilot/logs/spec-review-after-task-10.md"
  echo "Deviation: missing feature X" > "$target"

  local result
  result="$(read_spec_review "$TEST_PROJECT_DIR" 10)"
  echo "$result" | grep -qF "missing feature X"
}

@test "read_spec_review returns 1 for missing review" {
  run read_spec_review "$TEST_PROJECT_DIR" 99
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "read_spec_review returns 1 for empty file" {
  local target="${TEST_PROJECT_DIR}/.autopilot/logs/spec-review-after-task-7.md"
  touch "$target"

  run read_spec_review "$TEST_PROJECT_DIR" 7
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "read_spec_review rejects non-numeric task number" {
  run read_spec_review "$TEST_PROJECT_DIR" "../evil"
  [ "$status" -eq 1 ]
}

# --- _build_issue_body ---

@test "_build_issue_body includes task number" {
  local result
  result="$(_build_issue_body 10 "findings")"
  echo "$result" | grep -qF "Task 10"
}

@test "_build_issue_body includes review output" {
  local result
  result="$(_build_issue_body 5 "Missing auth module")"
  echo "$result" | grep -qF "Missing auth module"
}

@test "_build_issue_body includes autopilot attribution" {
  local result
  result="$(_build_issue_body 1 "findings")"
  echo "$result" | grep -qF "autopilot spec review"
}

# --- _create_review_issue ---

@test "_create_review_issue calls gh issue create" {
  local gh_capture="${TEST_PROJECT_DIR}/gh_calls.log"
  cat > "${TEST_MOCK_BIN}/gh" <<MOCK
#!/bin/bash
echo "\$@" >> "${gh_capture}"
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"
  _create_mock_timeout

  _create_review_issue "$TEST_PROJECT_DIR" "owner/repo" 10 "findings"

  [ -f "$gh_capture" ]
  grep -qF "issue create" "$gh_capture"
  grep -qF "spec-review" "$gh_capture"
}

@test "_create_review_issue sanitizes @mentions" {
  local gh_capture="${TEST_PROJECT_DIR}/gh_body.log"
  cat > "${TEST_MOCK_BIN}/gh" <<MOCK
#!/bin/bash
# Capture the body argument.
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --body) echo "\$2" > "${gh_capture}"; break ;;
  esac
  shift
done
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"
  _create_mock_timeout

  _create_review_issue "$TEST_PROJECT_DIR" "owner/repo" 5 \
    "cc @developer for review"

  [ -f "$gh_capture" ]
  ! grep -qF "@developer" "$gh_capture"
  grep -qF "at-developer" "$gh_capture"
}

@test "_create_review_issue retries without label on failure" {
  local call_count_file="${TEST_PROJECT_DIR}/gh_call_count.txt"
  echo "0" > "$call_count_file"
  cat > "${TEST_MOCK_BIN}/gh" <<MOCK
#!/bin/bash
count=\$(cat "${call_count_file}")
count=\$((count + 1))
echo "\$count" > "${call_count_file}"
if [[ \$count -eq 1 ]]; then
  # First call (with label) fails.
  exit 1
fi
# Second call (without label) succeeds.
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"
  _create_mock_timeout

  _create_review_issue "$TEST_PROJECT_DIR" "owner/repo" 5 "findings"

  local final_count
  final_count="$(cat "$call_count_file")"
  [ "$final_count" -eq 2 ]
}

# --- Mock helpers ---

# Helper: create a mock claude that returns a JSON response.
_create_mock_claude() {
  local response_text="$1"
  local exit_code="${2:-0}"

  cat > "${TEST_MOCK_BIN}/claude" <<MOCK
#!/bin/bash
echo '{"result":"${response_text}"}'
exit ${exit_code}
MOCK
  chmod +x "${TEST_MOCK_BIN}/claude"
}

# Helper: create a mock claude that captures CLAUDE_CONFIG_DIR.
_create_mock_claude_config_capture() {
  local config_capture="${TEST_PROJECT_DIR}/config_dir_seen.txt"
  cat > "${TEST_MOCK_BIN}/claude" <<MOCK
#!/bin/bash
echo "\${CLAUDE_CONFIG_DIR:-unset}" > "${config_capture}"
echo '{"result":"VERDICT: COMPLIANT"}'
MOCK
  chmod +x "${TEST_MOCK_BIN}/claude"
  echo "$config_capture"
}

# Helper: create a mock timeout that delegates to the command.
_create_mock_timeout() {
  cat > "${TEST_MOCK_BIN}/timeout" <<'MOCK'
#!/bin/bash
# Skip the timeout arg and run the rest.
shift
exec "$@"
MOCK
  chmod +x "${TEST_MOCK_BIN}/timeout"
}

# Helper: mock git remote to return a known URL.
_create_mock_git() {
  cat > "${TEST_MOCK_BIN}/git" <<'MOCK'
#!/bin/bash
if [[ "$*" == *"remote get-url"* ]]; then
  echo "https://github.com/testowner/testrepo.git"
  exit 0
fi
# Fallback to real git for other commands.
/usr/bin/git "$@"
MOCK
  chmod +x "${TEST_MOCK_BIN}/git"
}

# Helper: mock gh for full end-to-end scenario.
_create_mock_gh_full() {
  local review_has_issues="${1:-true}"
  cat > "${TEST_MOCK_BIN}/gh" <<MOCK
#!/bin/bash
if [[ "\$1" == "pr" && "\$2" == "list" ]]; then
  echo "20"
  echo "19"
  echo "18"
  exit 0
fi
if [[ "\$1" == "pr" && "\$2" == "diff" ]]; then
  echo "diff --git a/file.sh b/file.sh"
  echo "+new line for PR \$3"
  exit 0
fi
if [[ "\$1" == "issue" && "\$2" == "create" ]]; then
  echo "https://github.com/testowner/testrepo/issues/99"
  exit 0
fi
exit 1
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"
}

# Helper: set up common mocks and spec file for end-to-end tests.
_setup_spec_review_mocks() {
  _create_mock_git
  _create_mock_timeout
  _create_mock_gh_full
  mkdir -p "${TEST_PROJECT_DIR}/docs"
  echo "# Spec" > "${TEST_PROJECT_DIR}/docs/spec.md"
  AUTOPILOT_CONTEXT_FILES="docs/spec.md"
}

# --- run_spec_review (end-to-end with mocks) ---

@test "run_spec_review returns SPEC_REVIEW_ERROR for non-numeric task" {
  run run_spec_review "$TEST_PROJECT_DIR" "abc"
  [ "$status" -eq "$SPEC_REVIEW_ERROR" ]
}

@test "run_spec_review returns SPEC_REVIEW_ERROR when repo not available" {
  # Remove origin so get_repo_slug fails.
  git -C "$TEST_PROJECT_DIR" remote remove origin
  run run_spec_review "$TEST_PROJECT_DIR" 10
  [ "$status" -eq "$SPEC_REVIEW_ERROR" ]
}

@test "run_spec_review returns SPEC_REVIEW_SKIP when no spec file and no tasks file" {
  _create_mock_git
  AUTOPILOT_CONTEXT_FILES=""
  unset AUTOPILOT_TASKS_FILE

  run run_spec_review "$TEST_PROJECT_DIR" 10
  [ "$status" -eq "$SPEC_REVIEW_SKIP" ]
}

@test "run_spec_review uses tasks file as spec when no context files" {
  _create_mock_git
  _create_mock_timeout
  _create_mock_claude "VERDICT: COMPLIANT — all checked requirements are correctly implemented."
  _create_mock_gh_full

  AUTOPILOT_CONTEXT_FILES=""
  unset AUTOPILOT_TASKS_FILE
  echo "## Task 1: Build feature X" > "${TEST_PROJECT_DIR}/tasks.md"

  run run_spec_review "$TEST_PROJECT_DIR" 10
  [ "$status" -eq "$SPEC_REVIEW_OK" ]

  # Verify the log shows it used the tasks file.
  local log_file="${TEST_PROJECT_DIR}/.autopilot/logs/pipeline.log"
  grep -qF "SPEC_REVIEW: using" "$log_file"
  grep -qF "source: tasks-file" "$log_file"
}

@test "run_spec_review logs context-files source when context files configured" {
  _create_mock_git
  _create_mock_timeout
  _create_mock_claude "VERDICT: COMPLIANT — all checked requirements are correctly implemented."
  _create_mock_gh_full

  mkdir -p "${TEST_PROJECT_DIR}/docs"
  echo "# Spec" > "${TEST_PROJECT_DIR}/docs/spec.md"
  AUTOPILOT_CONTEXT_FILES="docs/spec.md"

  run run_spec_review "$TEST_PROJECT_DIR" 10
  [ "$status" -eq "$SPEC_REVIEW_OK" ]

  local log_file="${TEST_PROJECT_DIR}/.autopilot/logs/pipeline.log"
  grep -qF "SPEC_REVIEW: using" "$log_file"
  grep -qF "source: context-files" "$log_file"
}

@test "run_spec_review returns SPEC_REVIEW_SKIP when no merged PRs" {
  _create_mock_git
  _create_mock_timeout

  # Create spec file.
  mkdir -p "${TEST_PROJECT_DIR}/docs"
  echo "# Spec" > "${TEST_PROJECT_DIR}/docs/spec.md"
  AUTOPILOT_CONTEXT_FILES="docs/spec.md"

  # Mock gh that returns no PRs.
  cat > "${TEST_MOCK_BIN}/gh" <<'MOCK'
#!/bin/bash
echo ""
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  run run_spec_review "$TEST_PROJECT_DIR" 10
  [ "$status" -eq "$SPEC_REVIEW_SKIP" ]
}

@test "run_spec_review returns SPEC_REVIEW_OK on success with compliant verdict" {
  _create_mock_git
  _create_mock_timeout
  _create_mock_claude "VERDICT: COMPLIANT — all checked requirements are correctly implemented."
  _create_mock_gh_full

  # Create spec file.
  mkdir -p "${TEST_PROJECT_DIR}/docs"
  echo "# Spec\nAll features listed" > "${TEST_PROJECT_DIR}/docs/spec.md"
  AUTOPILOT_CONTEXT_FILES="docs/spec.md"

  run run_spec_review "$TEST_PROJECT_DIR" 10
  [ "$status" -eq "$SPEC_REVIEW_OK" ]
}

@test "run_spec_review saves output to log file" {
  _create_mock_git
  _create_mock_timeout
  _create_mock_claude "Found deviation in auth module"
  _create_mock_gh_full

  mkdir -p "${TEST_PROJECT_DIR}/docs"
  echo "# Spec" > "${TEST_PROJECT_DIR}/docs/spec.md"
  AUTOPILOT_CONTEXT_FILES="docs/spec.md"

  run_spec_review "$TEST_PROJECT_DIR" 15 || true

  local target="${TEST_PROJECT_DIR}/.autopilot/logs/spec-review-after-task-15.md"
  [ -f "$target" ]
  grep -qF "Found deviation in auth module" "$target"
}

@test "run_spec_review creates issue when deviations found" {
  _create_mock_git
  _create_mock_timeout
  _create_mock_claude "Deviation: missing feature X"

  local issue_created="${TEST_PROJECT_DIR}/issue_created.txt"
  cat > "${TEST_MOCK_BIN}/gh" <<MOCK
#!/bin/bash
if [[ "\$1" == "pr" && "\$2" == "list" ]]; then
  echo "20"
  exit 0
fi
if [[ "\$1" == "pr" && "\$2" == "diff" ]]; then
  echo "diff content"
  exit 0
fi
if [[ "\$1" == "issue" && "\$2" == "create" ]]; then
  echo "created" > "${issue_created}"
  exit 0
fi
exit 1
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  mkdir -p "${TEST_PROJECT_DIR}/docs"
  echo "# Spec" > "${TEST_PROJECT_DIR}/docs/spec.md"
  AUTOPILOT_CONTEXT_FILES="docs/spec.md"

  run_spec_review "$TEST_PROJECT_DIR" 10 || true

  [ -f "$issue_created" ]
}

@test "run_spec_review skips issue when verdict is compliant" {
  _create_mock_git
  _create_mock_timeout
  _create_mock_claude "VERDICT: COMPLIANT — all checked requirements are correctly implemented."

  local issue_created="${TEST_PROJECT_DIR}/issue_created.txt"
  cat > "${TEST_MOCK_BIN}/gh" <<MOCK
#!/bin/bash
if [[ "\$1" == "pr" && "\$2" == "list" ]]; then
  echo "20"
  exit 0
fi
if [[ "\$1" == "pr" && "\$2" == "diff" ]]; then
  echo "diff content"
  exit 0
fi
if [[ "\$1" == "issue" && "\$2" == "create" ]]; then
  echo "created" > "${issue_created}"
  exit 0
fi
exit 1
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  mkdir -p "${TEST_PROJECT_DIR}/docs"
  echo "# Spec" > "${TEST_PROJECT_DIR}/docs/spec.md"
  AUTOPILOT_CONTEXT_FILES="docs/spec.md"

  run_spec_review "$TEST_PROJECT_DIR" 10

  # Issue should NOT have been created.
  [ ! -f "$issue_created" ]
}

@test "run_spec_review returns SPEC_REVIEW_ERROR when Claude fails" {
  _create_mock_git
  _create_mock_timeout
  _create_mock_claude "error" 1
  _create_mock_gh_full

  mkdir -p "${TEST_PROJECT_DIR}/docs"
  echo "# Spec" > "${TEST_PROJECT_DIR}/docs/spec.md"
  AUTOPILOT_CONTEXT_FILES="docs/spec.md"

  run run_spec_review "$TEST_PROJECT_DIR" 10
  [ "$status" -eq "$SPEC_REVIEW_ERROR" ]
}

@test "run_spec_review uses AUTOPILOT_TIMEOUT_SPEC_REVIEW config" {
  _create_mock_git
  _create_mock_claude "review output"
  _create_mock_gh_full

  local timeout_capture="${TEST_PROJECT_DIR}/timeout_val.txt"
  cat > "${TEST_MOCK_BIN}/timeout" <<MOCK
#!/bin/bash
echo "\$1" >> "${timeout_capture}"
shift
exec "\$@"
MOCK
  chmod +x "${TEST_MOCK_BIN}/timeout"

  mkdir -p "${TEST_PROJECT_DIR}/docs"
  echo "# Spec" > "${TEST_PROJECT_DIR}/docs/spec.md"
  AUTOPILOT_CONTEXT_FILES="docs/spec.md"
  AUTOPILOT_TIMEOUT_SPEC_REVIEW=120

  run_spec_review "$TEST_PROJECT_DIR" 10 || true

  [ -f "$timeout_capture" ]
  # The Claude call should use the spec review timeout.
  grep -qF "120" "$timeout_capture"
}

@test "run_spec_review logs start and completion messages" {
  _create_mock_git
  _create_mock_timeout
  _create_mock_claude "VERDICT: COMPLIANT — all checked requirements are correctly implemented."
  _create_mock_gh_full

  mkdir -p "${TEST_PROJECT_DIR}/docs"
  echo "# Spec" > "${TEST_PROJECT_DIR}/docs/spec.md"
  AUTOPILOT_CONTEXT_FILES="docs/spec.md"

  run_spec_review "$TEST_PROJECT_DIR" 10

  local log_file="${TEST_PROJECT_DIR}/.autopilot/logs/pipeline.log"
  grep -qF "Starting spec review after task 10" "$log_file"
  grep -qF "Spec review completed after task 10" "$log_file"
}

# --- Integration: should_run + run ---

@test "integration: spec review fires at configured interval" {
  AUTOPILOT_SPEC_REVIEW_INTERVAL=3

  # Task 3 should trigger.
  should_run_spec_review 3
  # Task 6 should trigger.
  should_run_spec_review 6
  # Task 4 should not.
  ! should_run_spec_review 4
}

@test "integration: spec review disabled at interval 0 prevents run" {
  AUTOPILOT_SPEC_REVIEW_INTERVAL=0
  # No task number should trigger.
  ! should_run_spec_review 5
  ! should_run_spec_review 10
  ! should_run_spec_review 100
}

@test "integration: full pipeline with issue creation on deviation" {
  _create_mock_git
  _create_mock_timeout
  _create_mock_claude "Non-compliant: auth module missing"

  local issue_title_capture="${TEST_PROJECT_DIR}/issue_title.txt"
  cat > "${TEST_MOCK_BIN}/gh" <<MOCK
#!/bin/bash
if [[ "\$1" == "pr" && "\$2" == "list" ]]; then
  echo "25"
  echo "24"
  exit 0
fi
if [[ "\$1" == "pr" && "\$2" == "diff" ]]; then
  echo "+implemented feature for PR \$3"
  exit 0
fi
if [[ "\$1" == "issue" && "\$2" == "create" ]]; then
  # Capture the title.
  while [[ \$# -gt 0 ]]; do
    case "\$1" in
      --title) echo "\$2" > "${issue_title_capture}"; break ;;
    esac
    shift
  done
  exit 0
fi
exit 1
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  mkdir -p "${TEST_PROJECT_DIR}/docs"
  echo "# Project Spec\n- Auth module required" > "${TEST_PROJECT_DIR}/docs/spec.md"
  AUTOPILOT_CONTEXT_FILES="docs/spec.md"
  AUTOPILOT_SPEC_REVIEW_INTERVAL=5

  # Task 10 should trigger.
  should_run_spec_review 10
  run_spec_review "$TEST_PROJECT_DIR" 10

  # Verify issue was created with correct title.
  [ -f "$issue_title_capture" ]
  grep -qF "task 10" "$issue_title_capture"

  # Verify review output was saved.
  local saved="${TEST_PROJECT_DIR}/.autopilot/logs/spec-review-after-task-10.md"
  [ -f "$saved" ]
  grep -qF "auth module missing" "$saved"
}

@test "integration: empty Claude response returns SPEC_REVIEW_ERROR" {
  _create_mock_git
  _create_mock_timeout
  _create_mock_gh_full

  # Mock Claude that returns empty result.
  cat > "${TEST_MOCK_BIN}/claude" <<'MOCK'
#!/bin/bash
echo '{"result":""}'
MOCK
  chmod +x "${TEST_MOCK_BIN}/claude"

  mkdir -p "${TEST_PROJECT_DIR}/docs"
  echo "# Spec" > "${TEST_PROJECT_DIR}/docs/spec.md"
  AUTOPILOT_CONTEXT_FILES="docs/spec.md"

  run run_spec_review "$TEST_PROJECT_DIR" 10
  [ "$status" -eq "$SPEC_REVIEW_ERROR" ]
}

# --- New defaults ---

@test "AUTOPILOT_TIMEOUT_SPEC_REVIEW defaults to 1200" {
  unset AUTOPILOT_TIMEOUT_SPEC_REVIEW
  load_config "$TEST_PROJECT_DIR"
  [ "$AUTOPILOT_TIMEOUT_SPEC_REVIEW" -eq 1200 ]
}

@test "_SPEC_REVIEW_MAX_SPEC_BYTES is 50000" {
  [ "$_SPEC_REVIEW_MAX_SPEC_BYTES" -eq 50000 ]
}

@test "_read_spec_content does not truncate files under 50000 bytes" {
  local spec="${TEST_PROJECT_DIR}/medium-spec.md"
  # Write 40000 bytes — under _SPEC_REVIEW_MAX_SPEC_BYTES.
  head -c 40000 /dev/zero | tr '\0' 'x' > "$spec"

  local result
  result="$(_read_spec_content "$spec")"
  # Should NOT contain truncation notice.
  ! echo "$result" | grep -qF "truncated"
}

# --- _spec_review_pid_file / _spec_review_exit_file ---

@test "_spec_review_pid_file returns correct path" {
  local result
  result="$(_spec_review_pid_file "$TEST_PROJECT_DIR")"
  [ "$result" = "${TEST_PROJECT_DIR}/.autopilot/spec-review.pid" ]
}

@test "_spec_review_exit_file returns correct path" {
  local result
  result="$(_spec_review_exit_file "$TEST_PROJECT_DIR")"
  [ "$result" = "${TEST_PROJECT_DIR}/.autopilot/spec-review.exit" ]
}

# --- run_spec_review_async ---

@test "run_spec_review_async rejects non-numeric task number" {
  run run_spec_review_async "$TEST_PROJECT_DIR" "abc"
  [ "$status" -eq "$SPEC_REVIEW_ERROR" ]
}

@test "run_spec_review_async writes PID file" {
  _create_mock_git
  _create_mock_timeout
  _create_mock_claude "VERDICT: COMPLIANT"
  _create_mock_gh_full

  mkdir -p "${TEST_PROJECT_DIR}/docs"
  echo "# Spec" > "${TEST_PROJECT_DIR}/docs/spec.md"
  AUTOPILOT_CONTEXT_FILES="docs/spec.md"

  run_spec_review_async "$TEST_PROJECT_DIR" 10

  local pid_file="${TEST_PROJECT_DIR}/.autopilot/spec-review.pid"
  [ -f "$pid_file" ]

  local pid
  pid="$(cat "$pid_file")"
  [[ "$pid" =~ ^[0-9]+$ ]]

  # Wait for the background process to finish.
  wait "$pid" 2>/dev/null || true
}

@test "run_spec_review_async logs PID" {
  _create_mock_git
  _create_mock_timeout
  _create_mock_claude "VERDICT: COMPLIANT"
  _create_mock_gh_full

  mkdir -p "${TEST_PROJECT_DIR}/docs"
  echo "# Spec" > "${TEST_PROJECT_DIR}/docs/spec.md"
  AUTOPILOT_CONTEXT_FILES="docs/spec.md"

  run_spec_review_async "$TEST_PROJECT_DIR" 5

  local log_file="${TEST_PROJECT_DIR}/.autopilot/logs/pipeline.log"
  grep -qF "Spec review spawned in background" "$log_file"

  # Clean up background process.
  local pid
  pid="$(cat "${TEST_PROJECT_DIR}/.autopilot/spec-review.pid" 2>/dev/null)" || true
  wait "$pid" 2>/dev/null || true
}

@test "run_spec_review_async cleans up stale exit file" {
  local exit_file="${TEST_PROJECT_DIR}/.autopilot/spec-review.exit"
  echo "1" > "$exit_file"

  _create_mock_git
  _create_mock_timeout
  _create_mock_claude "VERDICT: COMPLIANT"
  _create_mock_gh_full

  mkdir -p "${TEST_PROJECT_DIR}/docs"
  echo "# Spec" > "${TEST_PROJECT_DIR}/docs/spec.md"
  AUTOPILOT_CONTEXT_FILES="docs/spec.md"

  run_spec_review_async "$TEST_PROJECT_DIR" 10

  # Stale exit file should have been removed before spawning.
  [ ! -f "$exit_file" ]

  # Wait for background to finish.
  local pid
  pid="$(cat "${TEST_PROJECT_DIR}/.autopilot/spec-review.pid" 2>/dev/null)" || true
  wait "$pid" 2>/dev/null || true
}

@test "run_spec_review_async skips when review already running" {
  # Start a long-running background process to simulate a running review.
  sleep 60 &
  local bg_pid=$!

  local pid_file="${TEST_PROJECT_DIR}/.autopilot/spec-review.pid"
  echo "$bg_pid" > "$pid_file"

  # Attempt to launch another async review — should skip.
  run_spec_review_async "$TEST_PROJECT_DIR" 15

  # PID file should still contain the original PID (not overwritten).
  local stored_pid
  stored_pid="$(cat "$pid_file")"
  [ "$stored_pid" = "$bg_pid" ]

  # Log should indicate it was skipped.
  local log_file="${TEST_PROJECT_DIR}/.autopilot/logs/pipeline.log"
  grep -qF "Spec review already running" "$log_file"

  # Clean up.
  kill "$bg_pid" 2>/dev/null || true
  wait "$bg_pid" 2>/dev/null || true
  rm -f "$pid_file"
}

# --- check_spec_review_completion ---

@test "check_spec_review_completion returns 0 when no PID file" {
  # No PID file exists — nothing to check.
  check_spec_review_completion "$TEST_PROJECT_DIR"
}

@test "check_spec_review_completion returns 0 after process exits" {
  # Create a PID file pointing to a non-existent process.
  local pid_file="${TEST_PROJECT_DIR}/.autopilot/spec-review.pid"
  echo "999999" > "$pid_file"
  local exit_file="${TEST_PROJECT_DIR}/.autopilot/spec-review.exit"
  echo "0" > "$exit_file"

  check_spec_review_completion "$TEST_PROJECT_DIR"

  # PID and exit files should be cleaned up.
  [ ! -f "$pid_file" ]
  [ ! -f "$exit_file" ]
}

@test "check_spec_review_completion returns 1 when process is running" {
  # Start a long-running background process.
  sleep 60 &
  local bg_pid=$!

  local pid_file="${TEST_PROJECT_DIR}/.autopilot/spec-review.pid"
  echo "$bg_pid" > "$pid_file"

  # Process is still running, should return 1.
  run check_spec_review_completion "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]

  # PID file should still exist.
  [ -f "$pid_file" ]

  # Clean up.
  kill "$bg_pid" 2>/dev/null || true
  wait "$bg_pid" 2>/dev/null || true
  rm -f "$pid_file"
}

@test "check_spec_review_completion handles empty PID file" {
  local pid_file="${TEST_PROJECT_DIR}/.autopilot/spec-review.pid"
  echo "" > "$pid_file"

  check_spec_review_completion "$TEST_PROJECT_DIR"

  # Should have cleaned up the invalid PID file.
  [ ! -f "$pid_file" ]
}

@test "check_spec_review_completion handles non-numeric PID" {
  local pid_file="${TEST_PROJECT_DIR}/.autopilot/spec-review.pid"
  echo "not-a-pid" > "$pid_file"

  check_spec_review_completion "$TEST_PROJECT_DIR"

  # Should have cleaned up the invalid PID file.
  [ ! -f "$pid_file" ]
}

@test "check_spec_review_completion logs exit code on finish" {
  local pid_file="${TEST_PROJECT_DIR}/.autopilot/spec-review.pid"
  echo "999999" > "$pid_file"
  local exit_file="${TEST_PROJECT_DIR}/.autopilot/spec-review.exit"
  echo "2" > "$exit_file"

  check_spec_review_completion "$TEST_PROJECT_DIR"

  local log_file="${TEST_PROJECT_DIR}/.autopilot/logs/pipeline.log"
  grep -qF "Background spec review completed" "$log_file"
  grep -qF "exit=2" "$log_file"
}

# --- Async integration ---

@test "integration: async spec review full lifecycle" {
  _create_mock_git
  _create_mock_timeout
  _create_mock_claude "VERDICT: COMPLIANT — all checked requirements are correctly implemented."
  _create_mock_gh_full

  mkdir -p "${TEST_PROJECT_DIR}/docs"
  echo "# Spec" > "${TEST_PROJECT_DIR}/docs/spec.md"
  AUTOPILOT_CONTEXT_FILES="docs/spec.md"

  # Launch async review.
  run_spec_review_async "$TEST_PROJECT_DIR" 10

  local pid_file="${TEST_PROJECT_DIR}/.autopilot/spec-review.pid"
  [ -f "$pid_file" ]

  local pid
  pid="$(cat "$pid_file")"

  # Wait for background process to complete.
  wait "$pid" 2>/dev/null || true

  # Now check_spec_review_completion should detect it finished.
  check_spec_review_completion "$TEST_PROJECT_DIR"

  # PID file should be cleaned up.
  [ ! -f "$pid_file" ]

  # Review output should have been saved by the background process.
  local review_output="${TEST_PROJECT_DIR}/.autopilot/logs/spec-review-after-task-10.md"
  [ -f "$review_output" ]
}

# --- Config dir handling ---

@test "run_spec_review passes config_dir to run_claude" {
  _setup_spec_review_mocks

  local config_capture
  config_capture="$(_create_mock_claude_config_capture)"
  AUTOPILOT_SPEC_REVIEW_CONFIG_DIR="/fake/config/dir"

  # Mock check_claude_auth to always succeed.
  check_claude_auth() { return 0; }

  run_spec_review "$TEST_PROJECT_DIR" 10

  [ -f "$config_capture" ]
  grep -qF "/fake/config/dir" "$config_capture"
}

@test "run_spec_review falls back to AUTOPILOT_CODER_CONFIG_DIR" {
  _setup_spec_review_mocks

  local config_capture
  config_capture="$(_create_mock_claude_config_capture)"
  unset AUTOPILOT_SPEC_REVIEW_CONFIG_DIR
  AUTOPILOT_CODER_CONFIG_DIR="/coder/config/dir"

  check_claude_auth() { return 0; }

  run_spec_review "$TEST_PROJECT_DIR" 10

  [ -f "$config_capture" ]
  grep -qF "/coder/config/dir" "$config_capture"
}

@test "run_spec_review returns error when auth fails" {
  _setup_spec_review_mocks
  AUTOPILOT_SPEC_REVIEW_CONFIG_DIR="/bad/config"
  AUTOPILOT_AUTH_FALLBACK="false"

  # Mock check_claude_auth to always fail.
  check_claude_auth() { return 1; }

  run run_spec_review "$TEST_PROJECT_DIR" 10
  [ "$status" -eq "$SPEC_REVIEW_ERROR" ]

  local log_file="${TEST_PROJECT_DIR}/.autopilot/logs/pipeline.log"
  grep -qF "Auth failed for spec review" "$log_file"
}

# --- Error logging ---

@test "run_spec_review logs stderr when Claude fails" {
  _setup_spec_review_mocks

  # Mock Claude that writes to stderr and exits non-zero.
  cat > "${TEST_MOCK_BIN}/claude" <<'MOCK'
#!/bin/bash
echo "Authentication error: token expired" >&2
exit 1
MOCK
  chmod +x "${TEST_MOCK_BIN}/claude"

  run run_spec_review "$TEST_PROJECT_DIR" 10
  [ "$status" -eq "$SPEC_REVIEW_ERROR" ]

  local log_file="${TEST_PROJECT_DIR}/.autopilot/logs/pipeline.log"
  grep -qF "Spec review Claude call failed" "$log_file"
  grep -qF "exit=1" "$log_file"
  grep -qF "token expired" "$log_file"
}

@test "run_spec_review logs raw output when extract returns empty" {
  _setup_spec_review_mocks

  # Mock Claude that returns invalid JSON (no .result field).
  cat > "${TEST_MOCK_BIN}/claude" <<'MOCK'
#!/bin/bash
echo '{"error":"rate_limited","message":"Try again later"}'
MOCK
  chmod +x "${TEST_MOCK_BIN}/claude"

  run run_spec_review "$TEST_PROJECT_DIR" 10
  [ "$status" -eq "$SPEC_REVIEW_ERROR" ]

  local log_file="${TEST_PROJECT_DIR}/.autopilot/logs/pipeline.log"
  grep -qF "Empty spec review response" "$log_file"
  grep -qF "rate_limited" "$log_file"
}

# --- Output file verification ---

@test "run_spec_review produces non-empty output file with review content" {
  _setup_spec_review_mocks
  _create_mock_claude "Deviation: missing error handling in auth module"

  run_spec_review "$TEST_PROJECT_DIR" 20 || true

  local target="${TEST_PROJECT_DIR}/.autopilot/logs/spec-review-after-task-20.md"
  # File must exist.
  [ -f "$target" ]
  # File must be non-empty (-s checks size > 0).
  [ -s "$target" ]
  # Content must contain the review text.
  grep -qF "Deviation: missing error handling" "$target"
}
