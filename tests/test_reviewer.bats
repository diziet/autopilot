#!/usr/bin/env bats
# Tests for lib/reviewer.sh — repo slug, diff header, persona parsing, clean review.
# Diff fetching, execution, and integration tests are in test_reviewer_exec.bats.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

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
  _init_test_readonly

  # Source reviewer.sh (which sources config, state, claude).
  load_config "$TEST_PROJECT_DIR"

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
# These tests need a writable git dir — create a per-test copy.

# Restore the real get_repo_slug function (overrides the readonly mock).
_use_real_get_repo_slug() {
  get_repo_slug() {
    local project_dir="${1:-.}"
    local url
    url="$(git -C "$project_dir" remote get-url origin 2>/dev/null)" || return 1
    url="${url%.git}"
    if [[ "$url" =~ github\.com[:/]([^/]+/[^/]+)$ ]]; then
      echo "${BASH_REMATCH[1]}"
      return 0
    fi
    return 1
  }
  export -f get_repo_slug
}

# Creates a writable project dir with .git for get_repo_slug tests.
_setup_git_project_dir() {
  TEST_PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  _fast_copy "$_TEMPLATE_NOGIT_DIR" "$TEST_PROJECT_DIR"
  _add_git_to_test_dir
}

@test "get_repo_slug extracts owner/repo from HTTPS URL" {
  _setup_git_project_dir
  _use_real_get_repo_slug
  local result
  result="$(get_repo_slug "$TEST_PROJECT_DIR")"
  [ "$result" = "testowner/testrepo" ]
}

@test "get_repo_slug extracts owner/repo from SSH URL" {
  _setup_git_project_dir
  _use_real_get_repo_slug
  git -C "$TEST_PROJECT_DIR" remote set-url origin \
    "git@github.com:myorg/myproject.git"
  local result
  result="$(get_repo_slug "$TEST_PROJECT_DIR")"
  [ "$result" = "myorg/myproject" ]
}

@test "get_repo_slug handles URL without .git suffix" {
  _setup_git_project_dir
  _use_real_get_repo_slug
  git -C "$TEST_PROJECT_DIR" remote set-url origin \
    "https://github.com/owner/repo"
  local result
  result="$(get_repo_slug "$TEST_PROJECT_DIR")"
  [ "$result" = "owner/repo" ]
}

@test "get_repo_slug fails for non-github URL" {
  _setup_git_project_dir
  _use_real_get_repo_slug
  git -C "$TEST_PROJECT_DIR" remote set-url origin \
    "https://gitlab.com/owner/repo.git"
  run get_repo_slug "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
}

@test "get_repo_slug fails for directory without git" {
  _use_real_get_repo_slug
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

@test "_read_persona_file strips YAML frontmatter" {
  local test_persona_dir="$BATS_TEST_TMPDIR/personas"
  mkdir -p "$test_persona_dir"
  cat > "$test_persona_dir/fm-test.md" <<'EOF'
---
interactive: true
---
You are a test reviewer.
EOF
  _REVIEWER_PERSONAS_DIR="$test_persona_dir"

  local result
  result="$(_read_persona_file "fm-test")"
  # Should NOT contain frontmatter markers or metadata.
  if echo "$result" | grep -qF "interactive: true"; then
    echo "FAIL: frontmatter leaked into output"
    return 1
  fi
  # Should contain the actual content.
  echo "$result" | grep -qF "You are a test reviewer."
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

# --- _persona_is_interactive ---

@test "_persona_is_interactive returns true for persona with frontmatter" {
  # Create a test persona with interactive: true frontmatter.
  local test_persona_dir="$BATS_TEST_TMPDIR/personas"
  mkdir -p "$test_persona_dir"
  cat > "$test_persona_dir/interactive-reviewer.md" <<'EOF'
---
interactive: true
---
You are an interactive reviewer.
EOF
  _REVIEWER_PERSONAS_DIR="$test_persona_dir"

  _persona_is_interactive "interactive-reviewer"
}

@test "_persona_is_interactive returns 2 (no opinion) for persona without frontmatter" {
  # The real general.md has no frontmatter.
  _REVIEWER_PERSONAS_DIR="$BATS_TEST_DIRNAME/../reviewers"

  run _persona_is_interactive "general"
  [ "$status" -eq 2 ]
}

@test "_persona_is_interactive returns 2 (no opinion) for nonexistent persona" {
  run _persona_is_interactive "nonexistent"
  [ "$status" -eq 2 ]
}

@test "_persona_is_interactive returns 1 (explicit false) for interactive: false" {
  local test_persona_dir="$BATS_TEST_TMPDIR/personas"
  mkdir -p "$test_persona_dir"
  cat > "$test_persona_dir/manual.md" <<'EOF'
---
interactive: false
---
Manual reviewer.
EOF
  _REVIEWER_PERSONAS_DIR="$test_persona_dir"

  run _persona_is_interactive "manual"
  [ "$status" -eq 1 ]
}

# --- _is_interactive_reviewer ---

@test "_is_interactive_reviewer returns false by default" {
  AUTOPILOT_REVIEWER_INTERACTIVE="false"
  _REVIEWER_PERSONAS_DIR="$BATS_TEST_DIRNAME/../reviewers"

  run _is_interactive_reviewer "general"
  [ "$status" -ne 0 ]
}

@test "_is_interactive_reviewer returns true when global config enabled" {
  AUTOPILOT_REVIEWER_INTERACTIVE="true"
  _REVIEWER_PERSONAS_DIR="$BATS_TEST_DIRNAME/../reviewers"

  _is_interactive_reviewer "general"
}

@test "_is_interactive_reviewer per-persona override trumps global false" {
  AUTOPILOT_REVIEWER_INTERACTIVE="false"

  local test_persona_dir="$BATS_TEST_TMPDIR/personas"
  mkdir -p "$test_persona_dir"
  cat > "$test_persona_dir/deep.md" <<'EOF'
---
interactive: true
---
Deep reviewer.
EOF
  _REVIEWER_PERSONAS_DIR="$test_persona_dir"

  _is_interactive_reviewer "deep"
}

@test "_is_interactive_reviewer per-persona false overrides global true" {
  AUTOPILOT_REVIEWER_INTERACTIVE="true"

  local test_persona_dir="$BATS_TEST_TMPDIR/personas"
  mkdir -p "$test_persona_dir"
  cat > "$test_persona_dir/light.md" <<'EOF'
---
interactive: false
---
Lightweight reviewer.
EOF
  _REVIEWER_PERSONAS_DIR="$test_persona_dir"

  run _is_interactive_reviewer "light"
  [ "$status" -ne 0 ]
}

# --- Task description in reviewer prompts ---

@test "_run_single_reviewer includes task description in augmented diff" {
  # Create a minimal persona file.
  local test_persona_dir="$BATS_TEST_TMPDIR/personas"
  mkdir -p "$test_persona_dir"
  echo "You are a test reviewer." > "$test_persona_dir/tasktest.md"
  _REVIEWER_PERSONAS_DIR="$test_persona_dir"
  AUTOPILOT_REVIEWER_INTERACTIVE="false"

  # Create a diff file.
  local diff_file="$BATS_TEST_TMPDIR/test.diff"
  echo "+added line" > "$diff_file"

  # Mock claude to capture stdin and write it to a capture file.
  local capture_file="$BATS_TEST_TMPDIR/stdin_capture"
  claude() {
    cat > "$capture_file"
    echo '{"result":"NO_ISSUES_FOUND"}'
  }
  export -f claude
  export capture_file

  # Mock _build_base_cmd_args to set up a minimal command.
  _build_base_cmd_args() { _BASE_CMD_ARGS=(claude); }
  export -f _build_base_cmd_args

  local task_desc="Implement feature X with Y and Z."
  _run_single_reviewer "$TEST_PROJECT_DIR" "tasktest" "$diff_file" \
    "30" "" "$task_desc" > /dev/null

  # Verify the stdin contained the task description header.
  grep -qF "## Task Description" "$capture_file"
  grep -qF "Implement feature X with Y and Z." "$capture_file"
  # Verify it also contains the diff.
  grep -qF "+added line" "$capture_file"
}

@test "_run_single_reviewer works without task description" {
  # Create a minimal persona file.
  local test_persona_dir="$BATS_TEST_TMPDIR/personas"
  mkdir -p "$test_persona_dir"
  echo "You are a test reviewer." > "$test_persona_dir/notask.md"
  _REVIEWER_PERSONAS_DIR="$test_persona_dir"
  AUTOPILOT_REVIEWER_INTERACTIVE="false"

  # Create a diff file.
  local diff_file="$BATS_TEST_TMPDIR/test.diff"
  echo "+added line" > "$diff_file"

  # Mock claude to capture stdin.
  local capture_file="$BATS_TEST_TMPDIR/stdin_capture"
  claude() {
    cat > "$capture_file"
    echo '{"result":"NO_ISSUES_FOUND"}'
  }
  export -f claude
  export capture_file

  _build_base_cmd_args() { _BASE_CMD_ARGS=(claude); }
  export -f _build_base_cmd_args

  # No task_description argument — should work without it.
  _run_single_reviewer "$TEST_PROJECT_DIR" "notask" "$diff_file" \
    "30" "" "" > /dev/null

  # Verify stdin contained the diff but no task description header.
  grep -qF "+added line" "$capture_file"
  ! grep -qF "## Task Description" "$capture_file"
}

@test "run_reviewers passes task description to each reviewer" {
  # Create persona files.
  local test_persona_dir="$BATS_TEST_TMPDIR/personas"
  mkdir -p "$test_persona_dir"
  echo "Reviewer A." > "$test_persona_dir/alpha.md"
  echo "Reviewer B." > "$test_persona_dir/beta.md"
  _REVIEWER_PERSONAS_DIR="$test_persona_dir"
  AUTOPILOT_REVIEWERS="alpha,beta"
  AUTOPILOT_REVIEWER_INTERACTIVE="false"
  AUTOPILOT_TIMEOUT_REVIEWER="30"
  AUTOPILOT_TIMEOUT_REVIEWER_CLAUDE="10"
  AUTOPILOT_REVIEWER_CONFIG_DIR=""

  # Create a diff file.
  local diff_file="$BATS_TEST_TMPDIR/test.diff"
  echo "+code change" > "$diff_file"

  # Mock claude to dump stdin to a per-invocation capture file.
  local capture_dir="$BATS_TEST_TMPDIR/captures"
  mkdir -p "$capture_dir"
  claude() {
    local capture_file
    capture_file="$(mktemp "$capture_dir/capture.XXXXXX")"
    cat > "$capture_file"
    echo '{"result":"NO_ISSUES_FOUND"}'
  }
  export -f claude
  export capture_dir

  _build_base_cmd_args() { _BASE_CMD_ARGS=(claude); }
  export -f _build_base_cmd_args

  local task_desc="Add feature X."
  local result_dir
  result_dir="$(run_reviewers "$TEST_PROJECT_DIR" "42" "$diff_file" "$task_desc")"

  # Both reviewers should have received the task description.
  local capture_count
  capture_count="$(find "$capture_dir" -name 'capture.*' | wc -l | tr -d ' ')"
  [ "$capture_count" -eq 2 ]

  # Every capture file should contain the task description.
  local f
  for f in "$capture_dir"/capture.*; do
    grep -qF "## Task Description" "$f"
    grep -qF "Add feature X." "$f"
  done

  # Clean up result dir.
  rm -rf "$result_dir"
}

@test "_execute_review_cycle extracts task description from state and tasks file" {
  # Source review-runner for access to _execute_review_cycle.
  source "$BATS_TEST_DIRNAME/../lib/review-runner.sh"

  # Set up a writable project dir with state and tasks file.
  local proj_dir="$BATS_TEST_TMPDIR/proj"
  _fast_copy "$_TEMPLATE_NOGIT_DIR" "$proj_dir"

  # Write tasks.md with a task matching current_task=1 from state.json.
  cat > "$proj_dir/tasks.md" <<'TASKS'
## Task 1

Build the widget with buttons and labels.

## Task 2

Another task.
TASKS

  # Clear the detect_tasks_file cache so it picks up our tasks.md.
  _CACHED_TASKS_FILE=""
  _CACHED_TASKS_FILE_DIR=""

  # Source tasks.sh for detect_tasks_file / extract_task.
  source "$BATS_TEST_DIRNAME/../lib/tasks.sh"

  # Mock fetch_pr_diff to return a simple diff file.
  local diff_file="$BATS_TEST_TMPDIR/test.diff"
  echo "+widget code" > "$diff_file"
  fetch_pr_diff() { echo "$diff_file"; }
  export -f fetch_pr_diff

  # Mock _get_pr_head_sha.
  _get_pr_head_sha() { echo "abc123"; }
  export -f _get_pr_head_sha

  # Mock post_review_comments.
  post_review_comments() { return 0; }
  export -f post_review_comments

  # Mock _run_codex_if_configured.
  _run_codex_if_configured() { return 0; }
  export -f _run_codex_if_configured

  # Mock _transition_after_review.
  _transition_after_review() { return 0; }
  export -f _transition_after_review

  # Track what run_reviewers receives.
  local args_file="$BATS_TEST_TMPDIR/run_reviewers_args"
  run_reviewers() {
    # $4 is task_description
    echo "$4" > "$args_file"
    # Return a valid result dir.
    local rd
    rd="$(mktemp -d "${TMPDIR:-/tmp}/autopilot-reviews.XXXXXX")"
    echo "$rd"
  }
  export -f run_reviewers
  export args_file

  _execute_review_cycle "$proj_dir" "42" "standalone"

  # Verify run_reviewers received the task description.
  grep -qF "Build the widget with buttons and labels." "$args_file"
}

