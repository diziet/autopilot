#!/usr/bin/env bats
# Tests for lib/merger.sh — Merge review agent, verdict parsing,
# squash-merge, and diagnosis hint writing.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/merger.sh"

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template_nogit

  # Source merger.sh (which sources config, state, claude, git-ops).
  load_config "$TEST_PROJECT_DIR"

  # Override prompts dir to use real prompts in repo.
  _MERGER_PROMPTS_DIR="$BATS_TEST_DIRNAME/../prompts"

  # Default function mocks for gh, timeout, and claude.
  # Tests that need custom behavior redefine these inline.
  gh() {
    case "$*" in
      *"auth status"*) return 0 ;;
      *"pr view"*"--json state"*) echo "MERGED" ;;
      *"pr view"*"--json url"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
      *"pr view"*"headRefOid"*) echo "abc123def456" ;;
      *"pr view"*"headRefName"*) echo "autopilot/task-1" ;;
      *"pr view"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
      *"pr diff"*) echo "+added line" ;;
      *"pr create"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
      *"pr merge"*) return 0 ;;
      *"pr comment"*) return 0 ;;
      *"api"*"git/ref"*) echo 'abc123' ;;
      *"api"*"pulls"*"reviews"*) echo "" ;;
      *"api"*"pulls"*"comments"*) echo "" ;;
      *"api"*"issues"*"comments"*) echo "" ;;
      *"api"*) echo '[]' ;;
      *) echo "mock-gh: $*" >&2; return 0 ;;
    esac
  }
  export -f gh

  timeout() { shift; "$@"; }
  export -f timeout

  claude() {
    echo '{"result":"NO_ISSUES_FOUND","session_id":"sess-123"}'
  }
  export -f claude
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
  fresh_dir="$BATS_TEST_TMPDIR/fresh_dir"
  mkdir -p "$fresh_dir"
  # Set up minimal git repo so log_msg doesn't fail on path.
  mkdir -p "${fresh_dir}/.autopilot/logs"

  write_diagnosis_hints "$fresh_dir" 1 "some hints"

  [ -f "${fresh_dir}/.autopilot/diagnosis-hints-task-1.md" ]
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
  # Override gh to log its arguments.
  local gh_log="${TEST_PROJECT_DIR}/gh_calls.log"
  export GH_LOG="$gh_log"
  gh() { echo "$*" >> "$GH_LOG"; return 0; }
  export -f gh

  squash_merge_pr "$TEST_PROJECT_DIR" 42

  grep -qF "pr merge 42" "$gh_log"
  grep -q -- "--squash" "$gh_log"
  grep -q -- "--delete-branch" "$gh_log"
}

@test "squash_merge_pr fails when gh pr merge fails" {
  gh() { return 1; }
  export -f gh

  run squash_merge_pr "$TEST_PROJECT_DIR" 99
  [ "$status" -ne 0 ]
}

@test "squash_merge_pr fails when repo slug unavailable" {
  # Override mock so get_repo_slug fails.
  get_repo_slug() { return 1; }
  export -f get_repo_slug

  run squash_merge_pr "$TEST_PROJECT_DIR" 42
  [ "$status" -ne 0 ]
}

@test "squash_merge_pr logs stderr from gh pr merge on failure" {
  gh() {
    case "$*" in
      *"pr view"*"--json state"*) echo "OPEN" ;;
      *"pr view"*"mergeable"*) echo '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' ;;
      *"pr merge"*) echo "GraphQL: pull request is in an unstable status" >&2; return 1 ;;
      *) return 0 ;;
    esac
  }
  export -f gh

  run squash_merge_pr "$TEST_PROJECT_DIR" 42
  [ "$status" -ne 0 ]

  # Verify the stderr message appears in the log.
  local log_file="${TEST_PROJECT_DIR}/.autopilot/logs/pipeline.log"
  grep -qF "pull request is in an unstable status" "$log_file"
}

# --- _ensure_pr_open_for_merge ---

@test "_ensure_pr_open_for_merge reopens closed PR before merge" {
  local gh_log="${TEST_PROJECT_DIR}/gh_calls.log"
  export GH_LOG="$gh_log"
  gh() {
    echo "$*" >> "$GH_LOG"
    case "$*" in
      *"pr view"*"--json state"*) echo "CLOSED" ;;
      *"pr reopen"*) return 0 ;;
      *) return 0 ;;
    esac
  }
  export -f gh

  # Mock sleep to avoid waiting.
  sleep() { return 0; }
  export -f sleep

  _ensure_pr_open_for_merge "$TEST_PROJECT_DIR" 42 "testowner/testrepo"
  local exit_code=$?
  [ "$exit_code" -eq 0 ]

  grep -qF "pr reopen 42" "$gh_log"
}

@test "_ensure_pr_open_for_merge returns error when reopen fails" {
  gh() {
    case "$*" in
      *"pr view"*"--json state"*) echo "CLOSED" ;;
      *"pr reopen"*) return 1 ;;
      *) return 0 ;;
    esac
  }
  export -f gh

  run _ensure_pr_open_for_merge "$TEST_PROJECT_DIR" 42 "testowner/testrepo"
  [ "$status" -ne 0 ]
}

@test "_ensure_pr_open_for_merge skips reopen for open PR" {
  local gh_log="${TEST_PROJECT_DIR}/gh_calls.log"
  export GH_LOG="$gh_log"
  gh() {
    echo "$*" >> "$GH_LOG"
    case "$*" in
      *"pr view"*"--json state"*) echo "OPEN" ;;
      *) return 0 ;;
    esac
  }
  export -f gh

  _ensure_pr_open_for_merge "$TEST_PROJECT_DIR" 42 "testowner/testrepo"
  local exit_code=$?
  [ "$exit_code" -eq 0 ]

  ! grep -qF "pr reopen" "$gh_log"
}

# --- _poll_mergeability ---

@test "_poll_mergeability returns immediately when status is CLEAN" {
  check_pr_mergeable() { echo "$PR_MERGEABLE_CLEAN"; }

  _poll_mergeability "$TEST_PROJECT_DIR" 42
  local exit_code=$?
  [ "$exit_code" -eq 0 ]
}

@test "_poll_mergeability polls UNKNOWN until resolved" {
  # Use file-based counter — shell vars don't persist across subshells.
  local counter_file="${TEST_PROJECT_DIR}/poll_count"
  echo "0" > "$counter_file"
  export POLL_COUNTER_FILE="$counter_file"

  check_pr_mergeable() {
    local c
    c="$(cat "$POLL_COUNTER_FILE")"
    c=$(( c + 1 ))
    echo "$c" > "$POLL_COUNTER_FILE"
    if [[ "$c" -ge 3 ]]; then
      echo "$PR_MERGEABLE_CLEAN"
    else
      echo "$PR_MERGEABLE_UNKNOWN"
    fi
  }

  # Mock sleep to avoid waiting.
  sleep() { return 0; }
  export -f sleep

  AUTOPILOT_MERGE_WAIT_TIMEOUT=30
  AUTOPILOT_MERGE_POLL_INTERVAL=5

  _poll_mergeability "$TEST_PROJECT_DIR" 42
  local exit_code=$?
  [ "$exit_code" -eq 0 ]
}

@test "_poll_mergeability proceeds after timeout with UNKNOWN" {
  check_pr_mergeable() { echo "$PR_MERGEABLE_UNKNOWN"; }

  # Mock sleep to avoid waiting.
  sleep() { return 0; }
  export -f sleep

  AUTOPILOT_MERGE_WAIT_TIMEOUT=10
  AUTOPILOT_MERGE_POLL_INTERVAL=5

  _poll_mergeability "$TEST_PROJECT_DIR" 42
  local exit_code=$?
  [ "$exit_code" -eq 0 ]
}

# --- squash_merge_pr with PR state check ---

@test "squash_merge_pr reopens closed PR then merges" {
  local gh_log="${TEST_PROJECT_DIR}/gh_calls.log"
  export GH_LOG="$gh_log"
  gh() {
    echo "$*" >> "$GH_LOG"
    case "$*" in
      *"pr view"*"--json state"*) echo "OPEN" ;;
      *"pr merge"*) return 0 ;;
      *) return 0 ;;
    esac
  }
  export -f gh

  check_pr_mergeable() { echo "$PR_MERGEABLE_CLEAN"; }

  squash_merge_pr "$TEST_PROJECT_DIR" 42
  local exit_code=$?
  [ "$exit_code" -eq 0 ]

  grep -qF "pr merge 42" "$gh_log"
}

@test "squash_merge_pr fails without merge attempt when reopen fails" {
  local gh_log="${TEST_PROJECT_DIR}/gh_calls.log"
  export GH_LOG="$gh_log"
  gh() {
    echo "$*" >> "$GH_LOG"
    case "$*" in
      *"pr view"*"--json state"*) echo "CLOSED" ;;
      *"pr reopen"*) return 1 ;;
      *) return 0 ;;
    esac
  }
  export -f gh

  run squash_merge_pr "$TEST_PROJECT_DIR" 42
  [ "$status" -ne 0 ]

  # Must not attempt merge on a closed PR.
  ! grep -qF "pr merge" "$gh_log"
}

# --- _post_rejection_comment (mocked gh) ---

@test "_post_rejection_comment calls gh pr comment" {
  local gh_log="${TEST_PROJECT_DIR}/gh_calls.log"
  export GH_LOG="$gh_log"
  gh() { echo "$*" >> "$GH_LOG"; return 0; }
  export -f gh

  _post_rejection_comment "$TEST_PROJECT_DIR" 42 "Fix the tests" "testowner/testrepo"

  grep -qF "pr comment 42" "$gh_log"
}

@test "_post_rejection_comment does not fail when gh fails" {
  gh() { return 1; }
  export -f gh

  # Should not fail — just logs a warning.
  _post_rejection_comment "$TEST_PROJECT_DIR" 42 "feedback" "testowner/testrepo"
}

@test "_post_rejection_comment handles missing repo slug gracefully" {
  # Should not fail — just logs a warning and returns 0.
  _post_rejection_comment "$TEST_PROJECT_DIR" 42 "feedback" ""
}

# --- _fetch_merger_diff (mocked gh) ---

@test "_fetch_merger_diff returns diff content from gh" {
  gh() {
    echo "+added line"
    echo "-removed line"
    return 0
  }
  export -f gh

  local result
  result="$(_fetch_merger_diff "$TEST_PROJECT_DIR" 42 "testowner/testrepo")"
  echo "$result" | grep -qF "+added line"
  echo "$result" | grep -qF "-removed line"
}

@test "_fetch_merger_diff returns empty on gh failure" {
  gh() { return 1; }
  export -f gh

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
  gh() {
    echo "lib/merger.sh | +10 -3"
    echo "tests/test.bats | +5 -0"
    return 0
  }
  export -f gh

  local result
  result="$(_fetch_pr_file_list "$TEST_PROJECT_DIR" 42 "testowner/testrepo")"
  echo "$result" | grep -qF "lib/merger.sh"
  echo "$result" | grep -qF "tests/test.bats"
  echo "$result" | grep -qF "+10 -3"
}

@test "_fetch_pr_file_list returns empty on gh failure" {
  gh() { return 1; }
  export -f gh

  local result
  result="$(_fetch_pr_file_list "$TEST_PROJECT_DIR" 99 "testowner/testrepo")"
  [ -z "$result" ]
}

@test "_fetch_pr_file_list fails with empty repo slug" {
  run _fetch_pr_file_list "$TEST_PROJECT_DIR" 42 ""
  [ "$status" -ne 0 ]
}

@test "_fetch_pr_file_list handles many files" {
  gh() {
    local i
    for i in $(seq 1 25); do
      echo "src/file${i}.sh | +$((i * 2)) -0"
    done
    return 0
  }
  export -f gh

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
}

@test "run_merger returns MERGER_APPROVE on successful review and merge" {
  _setup_mocked_merger

  # Mock Claude to output APPROVE verdict.
  local mock_output
  mock_output="$BATS_TEST_TMPDIR/mock_output_approve"
  echo '{"result":"Code looks correct.\nVERDICT: APPROVE"}' > "$mock_output"

  claude() { cat "$MOCK_OUTPUT"; return 0; }
  export MOCK_OUTPUT="$mock_output"
  export -f claude

  # Mock gh for squash merge.
  gh() { return 0; }
  export -f gh

  run_merger "$TEST_PROJECT_DIR" 5 42
  local exit_code=$?
  [ "$exit_code" -eq "$MERGER_APPROVE" ]
}

@test "run_merger returns MERGER_REJECT on rejection" {
  _setup_mocked_merger

  # Mock Claude to output REJECT verdict.
  local mock_output
  mock_output="$BATS_TEST_TMPDIR/mock_output_reject"
  echo '{"result":"Tests are failing.\nVERDICT: REJECT\nFix error handling."}' > "$mock_output"

  claude() { cat "$MOCK_OUTPUT"; return 0; }
  export MOCK_OUTPUT="$mock_output"
  export -f claude

  # Mock gh for rejection comment.
  gh() { return 0; }
  export -f gh

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

  claude() { return 1; }
  export -f claude

  run run_merger "$TEST_PROJECT_DIR" 5 42
  [ "$status" -eq "$MERGER_ERROR" ]
}

@test "run_merger returns MERGER_ERROR when Claude returns empty response" {
  _setup_mocked_merger

  # Mock Claude returning empty JSON.
  claude() { echo '{}'; return 0; }
  export -f claude

  run run_merger "$TEST_PROJECT_DIR" 5 42
  [ "$status" -eq "$MERGER_ERROR" ]
}

@test "run_merger defaults to REJECT when verdict missing from response" {
  _setup_mocked_merger

  # Mock Claude returning text without a verdict.
  local mock_output
  mock_output="$BATS_TEST_TMPDIR/mock_output_no_verdict"
  echo '{"result":"The code looks fine but I forgot the verdict."}' > "$mock_output"

  claude() { cat "$MOCK_OUTPUT"; return 0; }
  export MOCK_OUTPUT="$mock_output"
  export -f claude

  # Mock gh for rejection comment posting.
  gh() { return 0; }
  export -f gh

  # Fail-safe: missing verdict defaults to REJECT, not MERGER_ERROR.
  run run_merger "$TEST_PROJECT_DIR" 5 42
  [ "$status" -eq "$MERGER_REJECT" ]
}

@test "run_merger uses AUTOPILOT_TIMEOUT_MERGER from config" {
  _setup_mocked_merger
  AUTOPILOT_TIMEOUT_MERGER=120

  local timeout_log="${TEST_PROJECT_DIR}/timeout_calls.log"
  export TIMEOUT_LOG="$timeout_log"
  timeout() {
    echo "$1" >> "$TIMEOUT_LOG"
    shift
    "$@"
  }
  export -f timeout

  local mock_output
  mock_output="$BATS_TEST_TMPDIR/mock_output_timeout"
  echo '{"result":"VERDICT: APPROVE"}' > "$mock_output"

  claude() { cat "$MOCK_OUTPUT"; return 0; }
  export MOCK_OUTPUT="$mock_output"
  export -f claude

  gh() { return 0; }
  export -f gh

  run_merger "$TEST_PROJECT_DIR" 5 42 || true

  grep -qF "120" "$timeout_log"
}

@test "run_merger passes task description to prompt when provided" {
  _setup_mocked_merger

  local prompt_log="${TEST_PROJECT_DIR}/prompt.log"
  export PROMPT_LOG="$prompt_log"

  # Mock Claude to capture the prompt passed.
  claude() {
    local arg
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "--print" ]]; then
        echo "$2" >> "$PROMPT_LOG"
        break
      fi
      shift
    done
    echo '{"result":"VERDICT: APPROVE"}'
    return 0
  }
  export -f claude

  gh() { return 0; }
  export -f gh

  run_merger "$TEST_PROJECT_DIR" 5 42 "Add user authentication" || true

  grep -qF "Add user authentication" "$prompt_log"
}

@test "run_merger uses AUTOPILOT_REVIEWER_CONFIG_DIR for Claude" {
  _setup_mocked_merger
  AUTOPILOT_REVIEWER_CONFIG_DIR="/tmp/test-reviewer-config"

  local config_log="${TEST_PROJECT_DIR}/config.log"
  export CONFIG_LOG="$config_log"

  # Mock Claude to check CLAUDE_CONFIG_DIR env.
  claude() {
    echo "${CLAUDE_CONFIG_DIR:-none}" >> "$CONFIG_LOG"
    echo '{"result":"VERDICT: APPROVE"}'
    return 0
  }
  export -f claude

  gh() { return 0; }
  export -f gh

  run_merger "$TEST_PROJECT_DIR" 5 42 || true

  grep -qF "/tmp/test-reviewer-config" "$config_log"
}

@test "run_merger returns MERGER_ERROR when repo slug unavailable" {
  _setup_mocked_merger
  # Override mock so get_repo_slug fails.
  get_repo_slug() { return 1; }
  export -f get_repo_slug

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
  export PROMPT_LOG="$prompt_log"

  # Mock Claude to capture the prompt passed.
  claude() {
    local arg
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "--print" ]]; then
        echo "$2" >> "$PROMPT_LOG"
        break
      fi
      shift
    done
    echo '{"result":"VERDICT: APPROVE"}'
    return 0
  }
  export -f claude

  gh() { return 0; }
  export -f gh

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

  local prompt_log="${TEST_PROJECT_DIR}/prompt.log"
  export PROMPT_LOG="$prompt_log"

  # Mock Claude to capture prompt and return APPROVE.
  claude() {
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "--print" ]]; then
        echo "$2" >> "$PROMPT_LOG"
        break
      fi
      shift
    done
    echo '{"result":"VERDICT: APPROVE"}'
    return 0
  }
  export -f claude

  gh() { return 0; }
  export -f gh

  run_merger "$TEST_PROJECT_DIR" 5 42
  local exit_code=$?
  [ "$exit_code" -eq "$MERGER_APPROVE" ]

  # Verify the prompt does NOT contain the file list section.
  ! grep -qF "Changed Files" "$prompt_log"
  ! grep -qF "file list above is complete" "$prompt_log"
}

# --- check_pr_mergeable stderr logging ---

@test "check_pr_mergeable returns correct status when gh emits stderr warnings on success" {
  gh() {
    case "$*" in
      *"pr view"*"mergeable"*)
        echo "API rate limit warning" >&2
        echo '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}'
        return 0
        ;;
      *) return 0 ;;
    esac
  }
  export -f gh

  local result
  result="$(check_pr_mergeable "$TEST_PROJECT_DIR" 42)"
  [ "$result" = "$PR_MERGEABLE_CLEAN" ]
}

@test "_ensure_pr_open_for_merge detects state correctly when gh emits stderr on success" {
  gh() {
    case "$*" in
      *"pr view"*"--json state"*)
        echo "deprecation warning" >&2
        echo "OPEN"
        return 0
        ;;
      *) return 0 ;;
    esac
  }
  export -f gh

  _ensure_pr_open_for_merge "$TEST_PROJECT_DIR" 42 "testowner/testrepo"
  local exit_code=$?
  [ "$exit_code" -eq 0 ]
}

@test "check_pr_mergeable logs stderr from gh pr view on failure" {
  gh() {
    case "$*" in
      *"pr view"*"mergeable"*) echo "authorization required" >&2; return 1 ;;
      *) return 0 ;;
    esac
  }
  export -f gh

  local result
  result="$(check_pr_mergeable "$TEST_PROJECT_DIR" 42)"
  [ "$result" = "$PR_MERGEABLE_UNKNOWN" ]

  # Verify the stderr message appears in the log.
  local log_file="${TEST_PROJECT_DIR}/.autopilot/logs/pipeline.log"
  grep -qF "authorization required" "$log_file"
}
