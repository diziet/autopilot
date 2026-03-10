#!/usr/bin/env bats
# Tests for lib/reviewer.sh — repo slug, diff header, persona parsing, clean review.
# Diff fetching, execution, and integration tests are in test_reviewer_exec.bats.

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/reviewer.sh"

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template

  # Source reviewer.sh (which sources config, state, claude).
  load_config "$TEST_PROJECT_DIR"

  # Initialize pipeline state dir for log_msg.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/locks"

  # Override personas dir to use real personas in repo.
  _REVIEWER_PERSONAS_DIR="$BATS_TEST_DIRNAME/../reviewers"

  # Default function mocks (override per-test as needed).

  # Mock timeout: skip timeout value, run the command directly.
  timeout() { shift; "$@"; }
  export -f timeout

  # Mock gh CLI with default responses.
  gh() {
    case "$*" in
      *"auth status"*) return 0 ;;
      *"pr view"*"headRefName"*) echo "autopilot/task-1" ;;
      *"pr view"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
      *"pr diff"*) echo "+added line" ;;
      *) echo "mock-gh: $*" >&2; return 0 ;;
    esac
  }
  export -f gh

  # Mock claude CLI with default response.
  claude() {
    echo '{"result":"NO_ISSUES_FOUND","session_id":"sess-123"}'
  }
  export -f claude
}

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

# --- _build_diff_header ---

@test "_build_diff_header includes PR number, branch, and repo" {
  local header
  header="$(_build_diff_header 42 "feat/my-branch" "owner/repo")"
  echo "$header" | grep -qF "PR #42"
  echo "$header" | grep -qF "feat/my-branch"
  echo "$header" | grep -qF "owner/repo"
}

@test "_build_diff_header includes separator" {
  local header
  header="$(_build_diff_header 1 "main" "a/b")"
  echo "$header" | grep -qF -- "---"
}

# --- parse_reviewer_list ---

@test "parse_reviewer_list returns default personas" {
  AUTOPILOT_REVIEWERS="general,dry,performance,security,design"
  local result
  result="$(parse_reviewer_list)"
  echo "$result" | grep -qF "general"
  echo "$result" | grep -qF "dry"
  echo "$result" | grep -qF "performance"
  echo "$result" | grep -qF "security"
  echo "$result" | grep -qF "design"
}

@test "parse_reviewer_list handles custom subset" {
  AUTOPILOT_REVIEWERS="general,security"
  local result
  result="$(parse_reviewer_list)"
  local count
  count="$(echo "$result" | wc -l | tr -d ' ')"
  [ "$count" -eq 2 ]
  echo "$result" | grep -qF "general"
  echo "$result" | grep -qF "security"
}

@test "parse_reviewer_list handles single persona" {
  AUTOPILOT_REVIEWERS="general"
  local result
  result="$(parse_reviewer_list)"
  local count
  count="$(echo "$result" | wc -l | tr -d ' ')"
  [ "$count" -eq 1 ]
  [ "$result" = "general" ]
}

@test "parse_reviewer_list strips whitespace around names" {
  AUTOPILOT_REVIEWERS="general , security , dry"
  local result
  result="$(parse_reviewer_list)"
  echo "$result" | grep -q "^general$"
  echo "$result" | grep -q "^security$"
  echo "$result" | grep -q "^dry$"
}

@test "parse_reviewer_list rejects path traversal names" {
  AUTOPILOT_REVIEWERS="general,../../etc/passwd,security"
  local result
  result="$(parse_reviewer_list)"
  local count
  count="$(echo "$result" | wc -l | tr -d ' ')"
  [ "$count" -eq 2 ]
  echo "$result" | grep -qF "general"
  echo "$result" | grep -qF "security"
}

@test "parse_reviewer_list rejects names with slashes" {
  AUTOPILOT_REVIEWERS="../secret,general"
  local result
  result="$(parse_reviewer_list)"
  [ "$result" = "general" ]
}

@test "parse_reviewer_list rejects names with uppercase" {
  AUTOPILOT_REVIEWERS="General,security"
  local result
  result="$(parse_reviewer_list)"
  [ "$result" = "security" ]
}

@test "parse_reviewer_list allows hyphens and underscores" {
  AUTOPILOT_REVIEWERS="my-custom,code_quality"
  local result
  result="$(parse_reviewer_list)"
  local count
  count="$(echo "$result" | wc -l | tr -d ' ')"
  [ "$count" -eq 2 ]
  echo "$result" | grep -qF "my-custom"
  echo "$result" | grep -qF "code_quality"
}

# --- _read_persona_file ---

@test "_read_persona_file reads general.md" {
  local result
  result="$(_read_persona_file "general")"
  echo "$result" | grep -qF "general code review"
}

@test "_read_persona_file reads security.md" {
  local result
  result="$(_read_persona_file "security")"
  echo "$result" | grep -qF "security"
}

@test "_read_persona_file reads performance.md" {
  local result
  result="$(_read_persona_file "performance")"
  echo "$result" | grep -qF "performance"
}

@test "_read_persona_file reads dry.md" {
  local result
  result="$(_read_persona_file "dry")"
  echo "$result" | grep -qF "DRY"
}

@test "_read_persona_file reads design.md" {
  local result
  result="$(_read_persona_file "design")"
  echo "$result" | grep -qF "design"
}

@test "_read_persona_file fails for nonexistent persona" {
  run _read_persona_file "nonexistent"
  [ "$status" -ne 0 ]
}

# --- is_clean_review ---

@test "is_clean_review returns true for NO_ISSUES_FOUND" {
  is_clean_review "NO_ISSUES_FOUND"
}

@test "is_clean_review returns true when sentinel is embedded" {
  is_clean_review "After review: NO_ISSUES_FOUND in this PR."
}

@test "is_clean_review returns false for actual issues" {
  run is_clean_review "1. Bug in line 42"
  [ "$status" -ne 0 ]
}

@test "is_clean_review returns false for empty string" {
  run is_clean_review ""
  [ "$status" -ne 0 ]
}

