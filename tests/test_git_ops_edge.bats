#!/usr/bin/env bats
# Edge case tests for lib/git-ops.sh — repo slug extraction,
# _extract_pr_title fallback logic, _search_title_prefix,
# _strip_quotes, and error paths.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/git_ops_setup

# --- get_repo_slug ---

@test "get_repo_slug extracts owner/repo from HTTPS URL" {
  git -C "$TEST_PROJECT_DIR" remote remove origin 2>/dev/null || true
  git -C "$TEST_PROJECT_DIR" remote add origin "https://github.com/alice/myrepo.git"

  local result
  result="$(get_repo_slug "$TEST_PROJECT_DIR")"
  [ "$result" = "alice/myrepo" ]
}

@test "get_repo_slug extracts owner/repo from SSH URL" {
  git -C "$TEST_PROJECT_DIR" remote remove origin 2>/dev/null || true
  git -C "$TEST_PROJECT_DIR" remote add origin "git@github.com:bob/project.git"

  local result
  result="$(get_repo_slug "$TEST_PROJECT_DIR")"
  [ "$result" = "bob/project" ]
}

@test "get_repo_slug handles URL without .git suffix" {
  git -C "$TEST_PROJECT_DIR" remote remove origin 2>/dev/null || true
  git -C "$TEST_PROJECT_DIR" remote add origin "https://github.com/owner/repo"

  local result
  result="$(get_repo_slug "$TEST_PROJECT_DIR")"
  [ "$result" = "owner/repo" ]
}

@test "get_repo_slug fails when no origin remote" {
  git -C "$TEST_PROJECT_DIR" remote remove origin 2>/dev/null || true

  run get_repo_slug "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

@test "get_repo_slug fails for non-github URL" {
  git -C "$TEST_PROJECT_DIR" remote remove origin 2>/dev/null || true
  git -C "$TEST_PROJECT_DIR" remote add origin "https://gitlab.com/owner/repo.git"

  run get_repo_slug "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

# --- _search_title_prefix ---

@test "_search_title_prefix finds TITLE: line" {
  local result
  result="$(_search_title_prefix "Some text
TITLE: Add user authentication
More text")"
  [ "$result" = "Add user authentication" ]
}

@test "_search_title_prefix strips surrounding quotes" {
  local result
  result="$(_search_title_prefix 'TITLE: "Fix login bug"')"
  [ "$result" = "Fix login bug" ]
}

@test "_search_title_prefix handles single quotes" {
  local result
  result="$(_search_title_prefix "TITLE: 'Add feature'")"
  [ "$result" = "Add feature" ]
}

@test "_search_title_prefix returns first match" {
  local result
  result="$(_search_title_prefix "TITLE: First title
TITLE: Second title")"
  [ "$result" = "First title" ]
}

@test "_search_title_prefix fails on empty TITLE:" {
  run _search_title_prefix "TITLE: "
  [ "$status" -eq 1 ]
}

@test "_search_title_prefix fails when no TITLE: line" {
  run _search_title_prefix "No title here"
  [ "$status" -eq 1 ]
}

@test "_search_title_prefix handles leading whitespace" {
  local result
  result="$(_search_title_prefix "  TITLE: Indented title")"
  [ "$result" = "Indented title" ]
}

# --- _strip_quotes ---

@test "_strip_quotes removes double quotes" {
  local result
  result="$(_strip_quotes '"Hello world"')"
  [ "$result" = "Hello world" ]
}

@test "_strip_quotes removes single quotes" {
  local result
  result="$(_strip_quotes "'Hello world'")"
  [ "$result" = "Hello world" ]
}

@test "_strip_quotes preserves unquoted strings" {
  local result
  result="$(_strip_quotes "No quotes here")"
  [ "$result" = "No quotes here" ]
}

@test "_strip_quotes handles empty string" {
  local result
  result="$(_strip_quotes "")"
  [ -z "$result" ]
}

@test "_strip_quotes does not strip mismatched quotes" {
  local result
  result="$(_strip_quotes "\"Hello'")"
  [ "$result" = "\"Hello'" ]
}

# --- _extract_pr_title fallback ---

@test "_extract_pr_title extracts from TITLE: prefix" {
  local result
  result="$(_extract_pr_title "TITLE: Test feature" "$TEST_PROJECT_DIR")"
  [ "$result" = "Test feature" ]
}

@test "_extract_pr_title falls back to oldest commit on branch" {
  # Create a task branch with some commits.
  git -C "$TEST_PROJECT_DIR" checkout -b autopilot/task-99 2>/dev/null
  echo "new" > "$TEST_PROJECT_DIR/new.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "feat: add new feature" >/dev/null 2>&1

  local result
  result="$(_extract_pr_title "" "$TEST_PROJECT_DIR")"
  [ "$result" = "feat: add new feature" ]
}

@test "_extract_pr_title fails with empty output and no branch commits" {
  run _extract_pr_title "" "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

# --- build_branch_name edge cases ---

@test "build_branch_name handles large task numbers" {
  local result
  result="$(build_branch_name 9999)"
  [ "$result" = "autopilot/task-9999" ]
}

@test "build_branch_name handles task 0" {
  local result
  result="$(build_branch_name 0)"
  [ "$result" = "autopilot/task-0" ]
}

# --- commit_changes edge cases ---

@test "commit_changes with multiple new files" {
  echo "file1" > "$TEST_PROJECT_DIR/file1.txt"
  echo "file2" > "$TEST_PROJECT_DIR/file2.txt"
  echo "file3" > "$TEST_PROJECT_DIR/file3.txt"

  commit_changes "$TEST_PROJECT_DIR" "Add multiple files"

  local count
  count="$(git -C "$TEST_PROJECT_DIR" log --oneline | wc -l | tr -d ' ')"
  [ "$count" = "2" ]
}

@test "commit_changes preserves commit message content" {
  echo "test" > "$TEST_PROJECT_DIR/test.txt"

  commit_changes "$TEST_PROJECT_DIR" "feat: specific message"

  local msg
  msg="$(git -C "$TEST_PROJECT_DIR" log -1 --format=%s)"
  [ "$msg" = "feat: specific message" ]
}

# --- detect_default_branch edge cases ---

@test "detect_default_branch defaults to main when symbolic-ref missing" {
  # Our test repo has main so this should work.
  local result
  result="$(detect_default_branch "$TEST_PROJECT_DIR")"
  [ "$result" = "main" ]
}

# --- get_head_sha edge cases ---

@test "get_head_sha returns 40-char hex string" {
  local sha
  sha="$(get_head_sha "$TEST_PROJECT_DIR")"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]]
}
