#!/usr/bin/env bats
# Tests for lib/merger.sh — Merge review agent, verdict parsing,
# squash-merge, and diagnosis hint writing.

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$(dirname "$BATS_TEST_FILENAME")/../lib/merger.sh"

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template

  # Source merger.sh (which sources config, state, claude, git-ops).
  load_config "$TEST_PROJECT_DIR"

  # Initialize pipeline state dir for log_msg.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/locks"

  # Override prompts dir to use real prompts in repo.
  _MERGER_PROMPTS_DIR="$BATS_TEST_DIRNAME/../prompts"
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR"
  rm -rf "$TEST_MOCK_BIN"
}

# --- Exit Code Constants ---

@test "MERGER_APPROVE is 0" {
  [ "$MERGER_APPROVE" -eq 0 ]
}

@test "MERGER_REJECT is 1" {
  [ "$MERGER_REJECT" -eq 1 ]
}

@test "MERGER_ERROR is 2" {
  [ "$MERGER_ERROR" -eq 2 ]
}

# --- parse_verdict ---

@test "parse_verdict extracts APPROVE from standard response" {
  local text="Everything looks good.
VERDICT: APPROVE"
  local result
  result="$(parse_verdict "$text")"
  [ "$result" = "APPROVE" ]
}

@test "parse_verdict extracts REJECT from standard response" {
  local text="Tests are failing.
VERDICT: REJECT"
  local result
  result="$(parse_verdict "$text")"
  [ "$result" = "REJECT" ]
}

@test "parse_verdict uses last verdict when duplicates exist" {
  local text="VERDICT: REJECT
Actually, on second thought...
VERDICT: APPROVE"
  local result
  result="$(parse_verdict "$text")"
  [ "$result" = "APPROVE" ]
}

@test "parse_verdict handles extra whitespace after VERDICT:" {
  local text="VERDICT:   APPROVE"
  local result
  result="$(parse_verdict "$text")"
  [ "$result" = "APPROVE" ]
}

@test "parse_verdict fails when no verdict present" {
  local text="The code looks fine but I forgot the verdict line."
  run parse_verdict "$text"
  [ "$status" -ne 0 ]
}

@test "parse_verdict fails on empty input" {
  run parse_verdict ""
  [ "$status" -ne 0 ]
}

@test "parse_verdict ignores partial matches" {
  local text="VERDICT: MAYBE
VERDICT: APPROVE"
  local result
  result="$(parse_verdict "$text")"
  [ "$result" = "APPROVE" ]
}

@test "parse_verdict handles verdict in middle of response" {
  local text="Some preamble about code quality.

Here are my findings:
1. Tests pass
2. Code is clean

VERDICT: APPROVE

Some trailing notes."
  local result
  result="$(parse_verdict "$text")"
  [ "$result" = "APPROVE" ]
}

@test "parse_verdict handles REJECT with inline text" {
  local text="Issues found:
- Missing error handling
VERDICT: REJECT
Please fix before merging."
  local result
  result="$(parse_verdict "$text")"
  [ "$result" = "REJECT" ]
}

@test "parse_verdict ignores VERDICT line with 'rejection' suffix" {
  # The word "rejection" on a VERDICT: line must not match as REJECT.
  # Old regex without $ anchor would capture "REJECT" from "rejection".
  local text="VERDICT: APPROVE despite rejection concerns
VERDICT: APPROVE"
  local result
  result="$(parse_verdict "$text")"
  [ "$result" = "APPROVE" ]
}

@test "parse_verdict ignores VERDICT line with 'REJECTED' suffix" {
  # "VERDICT: REJECTED" must not match — old regex captured "REJECT".
  local text="VERDICT: REJECTED by review
VERDICT: APPROVE"
  local result
  result="$(parse_verdict "$text")"
  [ "$result" = "APPROVE" ]
}

@test "parse_verdict ignores VERDICT line with 'APPROVAL' suffix" {
  # "VERDICT: APPROVAL" must not match — old regex captured "APPROVE".
  local text="VERDICT: APPROVAL pending
VERDICT: REJECT"
  local result
  result="$(parse_verdict "$text")"
  [ "$result" = "REJECT" ]
}

@test "parse_verdict ignores VERDICT line with 'disapproval' text" {
  # "VERDICT: APPROVE but disapproval" — only clean VERDICT lines count.
  local text="VERDICT: APPROVE but disapproval noted
VERDICT: APPROVE"
  local result
  result="$(parse_verdict "$text")"
  [ "$result" = "APPROVE" ]
}

@test "parse_verdict handles VERDICT:APPROVE with no space" {
  local text="Looks good.
VERDICT:APPROVE"
  local result
  result="$(parse_verdict "$text")"
  [ "$result" = "APPROVE" ]
}

@test "parse_verdict handles VERDICT:REJECT with no space" {
  local text="Needs work.
VERDICT:REJECT"
  local result
  result="$(parse_verdict "$text")"
  [ "$result" = "REJECT" ]
}

@test "parse_verdict handles trailing whitespace after verdict" {
  # Trailing spaces after APPROVE should still match.
  local text
  text="$(printf 'VERDICT: APPROVE   ')"
  local result
  result="$(parse_verdict "$text")"
  [ "$result" = "APPROVE" ]
}

@test "parse_verdict fails when response contains 'rejection' but no VERDICT line" {
  local text="I recommend rejection of this PR.
The code has critical issues leading to rejection."
  run parse_verdict "$text"
  [ "$status" -ne 0 ]
}

@test "parse_verdict rejects VERDICT line with trailing letters" {
  # VERDICT: REJECTED should NOT match (trailing 'ED').
  local text="VERDICT: REJECTED"
  run parse_verdict "$text"
  [ "$status" -ne 0 ]
}

@test "parse_verdict rejects VERDICT line with APPROVED suffix" {
  # VERDICT: APPROVED should NOT match (trailing 'D').
  local text="VERDICT: APPROVED"
  run parse_verdict "$text"
  [ "$status" -ne 0 ]
}

# --- write_diagnosis_hints ---

@test "write_diagnosis_hints creates hints file for task" {
  write_diagnosis_hints "$TEST_PROJECT_DIR" 5 "Fix the failing test"

  local hints_file="${TEST_PROJECT_DIR}/.autopilot/diagnosis-hints-task-5.md"
  [ -f "$hints_file" ]
  grep -qF "Fix the failing test" "$hints_file"
}

@test "write_diagnosis_hints overwrites existing hints file" {
  local hints_file="${TEST_PROJECT_DIR}/.autopilot/diagnosis-hints-task-3.md"
  echo "old hints" > "$hints_file"

  write_diagnosis_hints "$TEST_PROJECT_DIR" 3 "new hints"

  grep -qF "new hints" "$hints_file"
  ! grep -qF "old hints" "$hints_file"
}

@test "write_diagnosis_hints creates .autopilot dir if missing" {
  local fresh_dir
  fresh_dir="$(mktemp -d)"
  # Set up minimal git repo so log_msg doesn't fail on path.
  mkdir -p "${fresh_dir}/.autopilot/logs"

  write_diagnosis_hints "$fresh_dir" 1 "some hints"

  [ -f "${fresh_dir}/.autopilot/diagnosis-hints-task-1.md" ]
  rm -rf "$fresh_dir"
}

# --- extract_rejection_feedback ---

@test "extract_rejection_feedback returns full text when nothing after verdict" {
  local text="The tests are broken.
Missing error handling.
VERDICT: REJECT"
  local result
  result="$(extract_rejection_feedback "$text")"
  # Should contain the full response since nothing follows REJECT.
  echo "$result" | grep -qF "tests are broken"
}

@test "extract_rejection_feedback returns post-verdict text when present" {
  local text="Preamble text.
VERDICT: REJECT
Fix the validation logic.
Add error handling to parse_input."
  local result
  result="$(extract_rejection_feedback "$text")"
  echo "$result" | grep -qF "Fix the validation logic"
  echo "$result" | grep -qF "Add error handling"
}

@test "extract_rejection_feedback returns empty for empty input" {
  local result
  result="$(extract_rejection_feedback "")"
  # Empty input produces empty output (no verdict, no content).
  [ -z "$result" ]
}

@test "extract_rejection_feedback handles response without verdict line" {
  local text="Some generic feedback without a verdict."
  local result
  result="$(extract_rejection_feedback "$text")"
  # Without a VERDICT: REJECT line, returns the full input.
  echo "$result" | grep -qF "generic feedback"
}

@test "extract_rejection_feedback ignores VERDICT: REJECTED line" {
  # "VERDICT: REJECTED" must not trigger feedback extraction —
  # only a clean "VERDICT: REJECT" line should.
  local text="VERDICT: REJECTED as incomplete
VERDICT: REJECT
Fix the error handling."
  local result
  result="$(extract_rejection_feedback "$text")"
  echo "$result" | grep -qF "Fix the error handling"
  ! echo "$result" | grep -qF "REJECTED as incomplete"
}

# --- build_merger_prompt ---

@test "build_merger_prompt includes PR number and branch" {
  local result
  result="$(build_merger_prompt 42 "autopilot/task-5" "owner/repo" "diff content")"
  echo "$result" | grep -qF "PR #42"
  echo "$result" | grep -qF "autopilot/task-5"
}

@test "build_merger_prompt includes repo slug" {
  local result
  result="$(build_merger_prompt 10 "branch" "myorg/myrepo" "diff")"
  echo "$result" | grep -qF "myorg/myrepo"
}

@test "build_merger_prompt includes diff content" {
  local result
  result="$(build_merger_prompt 1 "b" "o/r" "+added line
-removed line")"
  echo "$result" | grep -qF "+added line"
  echo "$result" | grep -qF "-removed line"
}

@test "build_merger_prompt includes verdict instructions" {
  local result
  result="$(build_merger_prompt 1 "b" "o/r" "diff")"
  echo "$result" | grep -qF "VERDICT: APPROVE"
  echo "$result" | grep -qF "VERDICT: REJECT"
}

@test "build_merger_prompt omits task section when no description" {
  local result
  result="$(build_merger_prompt 1 "b" "o/r" "diff" "")"
  ! echo "$result" | grep -qF "Task Description"
}

@test "build_merger_prompt includes task description when provided" {
  local result
  result="$(build_merger_prompt 1 "b" "o/r" "diff" "Implement user auth")"
  echo "$result" | grep -qF "Task Description"
  echo "$result" | grep -qF "Implement user auth"
}

# --- build_merger_prompt with file list ---

@test "build_merger_prompt includes file list section when provided" {
  local file_list="lib/merger.sh | +10 -3
tests/test.bats | +5 -0"
  local result
  result="$(build_merger_prompt 42 "b" "o/r" "diff content" "" "$file_list")"
  echo "$result" | grep -qF "Changed Files"
  echo "$result" | grep -qF "lib/merger.sh"
  echo "$result" | grep -qF "tests/test.bats"
  echo "$result" | grep -qF "+10 -3"
}

@test "build_merger_prompt places file list before diff" {
  local file_list="src/app.sh | +3 -0"
  local result
  result="$(build_merger_prompt 1 "b" "o/r" "+added" "" "$file_list")"
  # File list section must come before diff section.
  local file_list_pos diff_pos
  file_list_pos="$(echo "$result" | grep -n "Changed Files" | head -1 | cut -d: -f1)"
  diff_pos="$(echo "$result" | grep -n "Diff to Review" | head -1 | cut -d: -f1)"
  [ "$file_list_pos" -lt "$diff_pos" ]
}

@test "build_merger_prompt includes truncation note in file list section" {
  local file_list="file.sh | +1 -0"
  local result
  result="$(build_merger_prompt 1 "b" "o/r" "diff" "" "$file_list")"
  echo "$result" | grep -qF "The file list above is complete"
  echo "$result" | grep -qF "Do not reject for missing files"
}

@test "build_merger_prompt omits file list section when empty" {
  local result
  result="$(build_merger_prompt 1 "b" "o/r" "diff" "" "")"
  ! echo "$result" | grep -qF "Changed Files"
  ! echo "$result" | grep -qF "file list above is complete"
}

@test "build_merger_prompt includes both task description and file list" {
  local file_list="main.sh | +1 -1"
  local result
  result="$(build_merger_prompt 1 "b" "o/r" "diff" "Add feature X" "$file_list")"
  echo "$result" | grep -qF "Task Description"
  echo "$result" | grep -qF "Add feature X"
  echo "$result" | grep -qF "Changed Files"
  echo "$result" | grep -qF "main.sh"
}

@test "build_merger_prompt handles PR with many files in file list" {
  local file_list=""
  local i
  for i in $(seq 1 20); do
    file_list="${file_list}src/module${i}.sh | +$((i * 2)) -0
"
  done
  local result
  result="$(build_merger_prompt 99 "b" "o/r" "truncated diff" "" "$file_list")"
  echo "$result" | grep -qF "module1.sh"
  echo "$result" | grep -qF "module20.sh"
}

# --- _read_prompt_file ---

@test "_read_prompt_file reads prompts/merge-review.md" {
  local result
  result="$(_read_prompt_file "${_MERGER_PROMPTS_DIR}/merge-review.md")"
  echo "$result" | grep -qF "Merge Review Agent"
  echo "$result" | grep -qF "VERDICT"
}

@test "_read_prompt_file fails when prompt file missing" {
  run _read_prompt_file "$TEST_PROJECT_DIR/nonexistent/prompt.md"
  [ "$status" -eq 1 ]
}

# --- squash_merge_pr (mocked gh) ---

@test "squash_merge_pr calls gh with correct args on success" {
  # Create a mock gh that logs its arguments.
  local gh_log="${TEST_PROJECT_DIR}/gh_calls.log"
  cat > "${TEST_MOCK_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >> "${GH_LOG}"
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"
  export GH_LOG="$gh_log"

  # Mock timeout to just pass through.
  cat > "${TEST_MOCK_BIN}/timeout" <<'MOCK'
#!/usr/bin/env bash
shift  # drop timeout value
exec "$@"
MOCK
  chmod +x "${TEST_MOCK_BIN}/timeout"

  squash_merge_pr "$TEST_PROJECT_DIR" 42

  grep -qF "pr merge 42" "$gh_log"
  grep -q -- "--squash" "$gh_log"
  grep -q -- "--delete-branch" "$gh_log"
}

@test "squash_merge_pr fails when gh pr merge fails" {
  cat > "${TEST_MOCK_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  cat > "${TEST_MOCK_BIN}/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
exec "$@"
MOCK
  chmod +x "${TEST_MOCK_BIN}/timeout"

  run squash_merge_pr "$TEST_PROJECT_DIR" 99
  [ "$status" -ne 0 ]
}

@test "squash_merge_pr fails when repo slug unavailable" {
  # Remove git remote to break get_repo_slug.
  git -C "$TEST_PROJECT_DIR" remote remove origin

  run squash_merge_pr "$TEST_PROJECT_DIR" 42
  [ "$status" -ne 0 ]
}

# --- _post_rejection_comment (mocked gh) ---

@test "_post_rejection_comment calls gh pr comment" {
  local gh_log="${TEST_PROJECT_DIR}/gh_calls.log"
  cat > "${TEST_MOCK_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >> "${GH_LOG}"
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"
  export GH_LOG="$gh_log"

  cat > "${TEST_MOCK_BIN}/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
exec "$@"
MOCK
  chmod +x "${TEST_MOCK_BIN}/timeout"

  _post_rejection_comment "$TEST_PROJECT_DIR" 42 "Fix the tests" "testowner/testrepo"

  grep -qF "pr comment 42" "$gh_log"
}

@test "_post_rejection_comment does not fail when gh fails" {
  cat > "${TEST_MOCK_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  cat > "${TEST_MOCK_BIN}/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
exec "$@"
MOCK
  chmod +x "${TEST_MOCK_BIN}/timeout"

  # Should not fail — just logs a warning.
  _post_rejection_comment "$TEST_PROJECT_DIR" 42 "feedback" "testowner/testrepo"
}

@test "_post_rejection_comment handles missing repo slug gracefully" {
  # Should not fail — just logs a warning and returns 0.
  _post_rejection_comment "$TEST_PROJECT_DIR" 42 "feedback" ""
}

# --- _fetch_merger_diff (mocked gh) ---

@test "_fetch_merger_diff returns diff content from gh" {
  cat > "${TEST_MOCK_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
echo "+added line"
echo "-removed line"
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  cat > "${TEST_MOCK_BIN}/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
exec "$@"
MOCK
  chmod +x "${TEST_MOCK_BIN}/timeout"

  local result
  result="$(_fetch_merger_diff "$TEST_PROJECT_DIR" 42 "testowner/testrepo")"
  echo "$result" | grep -qF "+added line"
  echo "$result" | grep -qF "-removed line"
}

@test "_fetch_merger_diff returns empty on gh failure" {
  cat > "${TEST_MOCK_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  cat > "${TEST_MOCK_BIN}/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
exec "$@"
MOCK
  chmod +x "${TEST_MOCK_BIN}/timeout"

  local result
  result="$(_fetch_merger_diff "$TEST_PROJECT_DIR" 99 "testowner/testrepo" || true)"
  [ -z "$result" ]
}

@test "_fetch_merger_diff fails with empty repo slug" {
  run _fetch_merger_diff "$TEST_PROJECT_DIR" 42 ""
  [ "$status" -ne 0 ]
}

# --- _fetch_pr_file_list (mocked gh) ---

@test "_fetch_pr_file_list returns file stats from gh api" {
  cat > "${TEST_MOCK_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
echo "lib/merger.sh | +10 -3"
echo "tests/test.bats | +5 -0"
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  cat > "${TEST_MOCK_BIN}/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
exec "$@"
MOCK
  chmod +x "${TEST_MOCK_BIN}/timeout"

  local result
  result="$(_fetch_pr_file_list "$TEST_PROJECT_DIR" 42 "testowner/testrepo")"
  echo "$result" | grep -qF "lib/merger.sh"
  echo "$result" | grep -qF "tests/test.bats"
  echo "$result" | grep -qF "+10 -3"
}

@test "_fetch_pr_file_list returns empty on gh failure" {
  cat > "${TEST_MOCK_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  cat > "${TEST_MOCK_BIN}/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
exec "$@"
MOCK
  chmod +x "${TEST_MOCK_BIN}/timeout"

  local result
  result="$(_fetch_pr_file_list "$TEST_PROJECT_DIR" 99 "testowner/testrepo")"
  [ -z "$result" ]
}

@test "_fetch_pr_file_list fails with empty repo slug" {
  run _fetch_pr_file_list "$TEST_PROJECT_DIR" 42 ""
  [ "$status" -ne 0 ]
}

@test "_fetch_pr_file_list handles many files" {
  cat > "${TEST_MOCK_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
for i in $(seq 1 25); do
  echo "src/file${i}.sh | +$((i * 2)) -0"
done
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  cat > "${TEST_MOCK_BIN}/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
exec "$@"
MOCK
  chmod +x "${TEST_MOCK_BIN}/timeout"

  local result
  result="$(_fetch_pr_file_list "$TEST_PROJECT_DIR" 100 "testowner/testrepo")"
  echo "$result" | grep -qF "file1.sh"
  echo "$result" | grep -qF "file25.sh"
  # Verify we got 25 lines of output.
  local line_count
  line_count="$(echo "$result" | wc -l | tr -d ' ')"
  [ "$line_count" -eq 25 ]
}

# --- _handle_verdict (mocked squash_merge_pr) ---

@test "_handle_verdict returns MERGER_APPROVE on APPROVE with successful merge" {
  # Mock squash_merge_pr to succeed.
  squash_merge_pr() { return 0; }

  _handle_verdict "$TEST_PROJECT_DIR" 5 42 "APPROVE" "VERDICT: APPROVE"
  local exit_code=$?
  [ "$exit_code" -eq "$MERGER_APPROVE" ]
}

@test "_handle_verdict returns MERGER_ERROR when merge fails after APPROVE" {
  # Mock squash_merge_pr to fail.
  squash_merge_pr() { return 1; }

  run _handle_verdict "$TEST_PROJECT_DIR" 5 42 "APPROVE" "VERDICT: APPROVE"
  [ "$status" -eq "$MERGER_ERROR" ]
}

@test "_handle_verdict returns MERGER_REJECT on REJECT" {
  # Mock _post_rejection_comment to avoid gh calls.
  _post_rejection_comment() { return 0; }

  run _handle_verdict "$TEST_PROJECT_DIR" 5 42 "REJECT" \
    "Tests fail.
VERDICT: REJECT
Fix the edge case."
  [ "$status" -eq "$MERGER_REJECT" ]
}

@test "_handle_verdict writes diagnosis hints on REJECT" {
  _post_rejection_comment() { return 0; }

  _handle_verdict "$TEST_PROJECT_DIR" 5 42 "REJECT" \
    "Missing validation.
VERDICT: REJECT
Add input checks." || true

  local hints_file="${TEST_PROJECT_DIR}/.autopilot/diagnosis-hints-task-5.md"
  [ -f "$hints_file" ]
  grep -qF "Add input checks" "$hints_file"
}

@test "_handle_verdict posts rejection comment on REJECT" {
  local comment_posted=false

  _post_rejection_comment() { comment_posted=true; }

  _handle_verdict "$TEST_PROJECT_DIR" 5 42 "REJECT" \
    "VERDICT: REJECT" || true

  [ "$comment_posted" = true ]
}

# --- run_merger integration (fully mocked) ---

_setup_mocked_merger() {
  # Mock _fetch_merger_diff to return a diff.
  _fetch_merger_diff() {
    echo "+new code"
    echo "-old code"
  }

  # Mock _fetch_pr_file_list to return file stats.
  _fetch_pr_file_list() {
    echo "src/app.sh | +1 -1"
  }

  # Mock timeout to pass through.
  cat > "${TEST_MOCK_BIN}/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
exec "$@"
MOCK
  chmod +x "${TEST_MOCK_BIN}/timeout"
}

@test "run_merger returns MERGER_APPROVE on successful review and merge" {
  _setup_mocked_merger

  # Mock Claude to output APPROVE verdict.
  local mock_output
  mock_output="$(mktemp)"
  echo '{"result":"Code looks correct.\nVERDICT: APPROVE"}' > "$mock_output"

  cat > "${TEST_MOCK_BIN}/claude" <<MOCK
#!/usr/bin/env bash
cat "$mock_output"
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/claude"

  # Mock gh for squash merge.
  cat > "${TEST_MOCK_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  run_merger "$TEST_PROJECT_DIR" 5 42
  local exit_code=$?
  [ "$exit_code" -eq "$MERGER_APPROVE" ]

  rm -f "$mock_output"
}

@test "run_merger returns MERGER_REJECT on rejection" {
  _setup_mocked_merger

  # Mock Claude to output REJECT verdict.
  local mock_output
  mock_output="$(mktemp)"
  echo '{"result":"Tests are failing.\nVERDICT: REJECT\nFix error handling."}' > "$mock_output"

  cat > "${TEST_MOCK_BIN}/claude" <<MOCK
#!/usr/bin/env bash
cat "$mock_output"
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/claude"

  # Mock gh for rejection comment.
  cat > "${TEST_MOCK_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  run run_merger "$TEST_PROJECT_DIR" 5 42
  [ "$status" -eq "$MERGER_REJECT" ]
}

@test "run_merger returns MERGER_ERROR on empty diff" {
  # Mock _fetch_merger_diff to return empty.
  _fetch_merger_diff() { echo ""; }

  run run_merger "$TEST_PROJECT_DIR" 5 42
  [ "$status" -eq "$MERGER_ERROR" ]
}

@test "run_merger returns MERGER_ERROR when Claude fails" {
  _setup_mocked_merger

  cat > "${TEST_MOCK_BIN}/claude" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "${TEST_MOCK_BIN}/claude"

  run run_merger "$TEST_PROJECT_DIR" 5 42
  [ "$status" -eq "$MERGER_ERROR" ]
}

@test "run_merger returns MERGER_ERROR when Claude returns empty response" {
  _setup_mocked_merger

  # Mock Claude returning empty JSON.
  cat > "${TEST_MOCK_BIN}/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{}'
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/claude"

  run run_merger "$TEST_PROJECT_DIR" 5 42
  [ "$status" -eq "$MERGER_ERROR" ]
}

@test "run_merger defaults to REJECT when verdict missing from response" {
  _setup_mocked_merger

  # Mock Claude returning text without a verdict.
  local mock_output
  mock_output="$(mktemp)"
  echo '{"result":"The code looks fine but I forgot the verdict."}' > "$mock_output"

  cat > "${TEST_MOCK_BIN}/claude" <<MOCK
#!/usr/bin/env bash
cat "$mock_output"
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/claude"

  # Mock gh for rejection comment posting.
  cat > "${TEST_MOCK_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  # Fail-safe: missing verdict defaults to REJECT, not MERGER_ERROR.
  run run_merger "$TEST_PROJECT_DIR" 5 42
  [ "$status" -eq "$MERGER_REJECT" ]

  rm -f "$mock_output"
}

@test "run_merger uses AUTOPILOT_TIMEOUT_MERGER from config" {
  _setup_mocked_merger
  AUTOPILOT_TIMEOUT_MERGER=120

  local timeout_log="${TEST_PROJECT_DIR}/timeout_calls.log"
  cat > "${TEST_MOCK_BIN}/timeout" <<MOCK
#!/usr/bin/env bash
echo "\$1" >> "$timeout_log"
shift
exec "\$@"
MOCK
  chmod +x "${TEST_MOCK_BIN}/timeout"

  local mock_output
  mock_output="$(mktemp)"
  echo '{"result":"VERDICT: APPROVE"}' > "$mock_output"

  cat > "${TEST_MOCK_BIN}/claude" <<MOCK
#!/usr/bin/env bash
cat "$mock_output"
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/claude"

  cat > "${TEST_MOCK_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  run_merger "$TEST_PROJECT_DIR" 5 42 || true

  grep -qF "120" "$timeout_log"
  rm -f "$mock_output"
}

@test "run_merger passes task description to prompt when provided" {
  _setup_mocked_merger

  local prompt_log="${TEST_PROJECT_DIR}/prompt.log"

  # Mock Claude to capture the prompt passed.
  cat > "${TEST_MOCK_BIN}/claude" <<MOCK
#!/usr/bin/env bash
# Find the --print argument and log it.
while [[ \$# -gt 0 ]]; do
  if [[ "\$1" == "--print" ]]; then
    echo "\$2" >> "$prompt_log"
    break
  fi
  shift
done
echo '{"result":"VERDICT: APPROVE"}'
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/claude"

  cat > "${TEST_MOCK_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  run_merger "$TEST_PROJECT_DIR" 5 42 "Add user authentication" || true

  grep -qF "Add user authentication" "$prompt_log"
}

@test "run_merger uses AUTOPILOT_REVIEWER_CONFIG_DIR for Claude" {
  _setup_mocked_merger
  AUTOPILOT_REVIEWER_CONFIG_DIR="/tmp/test-reviewer-config"

  local config_log="${TEST_PROJECT_DIR}/config.log"

  # Mock Claude to check CLAUDE_CONFIG_DIR env.
  cat > "${TEST_MOCK_BIN}/claude" <<MOCK
#!/usr/bin/env bash
echo "\${CLAUDE_CONFIG_DIR:-none}" >> "$config_log"
echo '{"result":"VERDICT: APPROVE"}'
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/claude"

  cat > "${TEST_MOCK_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  run_merger "$TEST_PROJECT_DIR" 5 42 || true

  grep -qF "/tmp/test-reviewer-config" "$config_log"
}

@test "run_merger returns MERGER_ERROR when repo slug unavailable" {
  _setup_mocked_merger
  # Remove git remote to break get_repo_slug.
  git -C "$TEST_PROJECT_DIR" remote remove origin

  run run_merger "$TEST_PROJECT_DIR" 5 42
  [ "$status" -eq "$MERGER_ERROR" ]
}

@test "run_merger returns MERGER_ERROR when merge-review.md is missing" {
  _setup_mocked_merger
  # Point to a nonexistent prompts directory.
  _MERGER_PROMPTS_DIR="${TEST_PROJECT_DIR}/no-prompts"

  run run_merger "$TEST_PROJECT_DIR" 5 42
  [ "$status" -eq "$MERGER_ERROR" ]
}

@test "run_merger includes file list in prompt sent to Claude" {
  _setup_mocked_merger

  local prompt_log="${TEST_PROJECT_DIR}/prompt.log"

  # Mock Claude to capture the prompt passed.
  cat > "${TEST_MOCK_BIN}/claude" <<MOCK
#!/usr/bin/env bash
# Find the --print argument and log it.
while [[ \$# -gt 0 ]]; do
  if [[ "\$1" == "--print" ]]; then
    echo "\$2" >> "$prompt_log"
    break
  fi
  shift
done
echo '{"result":"VERDICT: APPROVE"}'
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/claude"

  cat > "${TEST_MOCK_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  run_merger "$TEST_PROJECT_DIR" 5 42 || true

  # Verify file list section is in the prompt.
  grep -qF "Changed Files" "$prompt_log"
  grep -qF "src/app.sh" "$prompt_log"
  grep -qF "file list above is complete" "$prompt_log"
}

@test "run_merger works when file list is empty and omits Changed Files from prompt" {
  # Override _fetch_pr_file_list to return empty (e.g. gh api failure).
  _fetch_merger_diff() {
    echo "+new code"
    echo "-old code"
  }
  _fetch_pr_file_list() {
    echo ""
  }

  cat > "${TEST_MOCK_BIN}/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
exec "$@"
MOCK
  chmod +x "${TEST_MOCK_BIN}/timeout"

  local prompt_log="${TEST_PROJECT_DIR}/prompt.log"

  # Mock Claude to capture prompt and return APPROVE.
  cat > "${TEST_MOCK_BIN}/claude" <<MOCK
#!/usr/bin/env bash
while [[ \$# -gt 0 ]]; do
  if [[ "\$1" == "--print" ]]; then
    echo "\$2" >> "$prompt_log"
    break
  fi
  shift
done
echo '{"result":"VERDICT: APPROVE"}'
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/claude"

  cat > "${TEST_MOCK_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  run_merger "$TEST_PROJECT_DIR" 5 42
  local exit_code=$?
  [ "$exit_code" -eq "$MERGER_APPROVE" ]

  # Verify the prompt does NOT contain the file list section.
  ! grep -qF "Changed Files" "$prompt_log"
  ! grep -qF "file list above is complete" "$prompt_log"
}
