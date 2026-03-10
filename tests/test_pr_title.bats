#!/usr/bin/env bats
# Tests for PR title/body extraction from lib/git-ops.sh.
# TITLE: prefix search, preamble skipping, quote stripping, git log fallback.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/git_ops_setup

# --- _strip_quotes ---

@test "_strip_quotes removes double quotes" {
  local result
  result="$(_strip_quotes '"Hello World"')"
  [ "$result" = "Hello World" ]
}

@test "_strip_quotes removes single quotes" {
  local result
  result="$(_strip_quotes "'Hello World'")"
  [ "$result" = "Hello World" ]
}

@test "_strip_quotes leaves unquoted text unchanged" {
  local result
  result="$(_strip_quotes "Hello World")"
  [ "$result" = "Hello World" ]
}

@test "_strip_quotes handles empty string" {
  local result
  result="$(_strip_quotes "")"
  [ "$result" = "" ]
}

@test "_strip_quotes does not strip mismatched quotes" {
  local result
  result="$(_strip_quotes "\"Hello World'")"
  [ "$result" = "\"Hello World'" ]
}

# --- _search_title_prefix ---

@test "_search_title_prefix finds TITLE: on first line" {
  local result
  result="$(_search_title_prefix "TITLE: My PR Title")"
  [ "$result" = "My PR Title" ]
}

@test "_search_title_prefix finds TITLE: after preamble" {
  local text="Some preamble text
More preamble here
TITLE: Found After Preamble
trailing text"
  local result
  result="$(_search_title_prefix "$text")"
  [ "$result" = "Found After Preamble" ]
}

@test "_search_title_prefix strips double quotes from title" {
  local result
  result="$(_search_title_prefix 'TITLE: "Quoted Title"')"
  [ "$result" = "Quoted Title" ]
}

@test "_search_title_prefix strips single quotes from title" {
  local result
  result="$(_search_title_prefix "TITLE: 'Single Quoted'")"
  [ "$result" = "Single Quoted" ]
}

@test "_search_title_prefix handles leading whitespace before TITLE:" {
  local result
  result="$(_search_title_prefix "  TITLE: Indented Title")"
  [ "$result" = "Indented Title" ]
}

@test "_search_title_prefix returns first TITLE: match" {
  local text="TITLE: First Title
TITLE: Second Title"
  local result
  result="$(_search_title_prefix "$text")"
  [ "$result" = "First Title" ]
}

@test "_search_title_prefix fails when no TITLE: found" {
  run _search_title_prefix "No title marker here"
  [ "$status" -eq 1 ]
}

@test "_search_title_prefix skips empty TITLE: lines" {
  local text="TITLE:
TITLE: Real Title"
  local result
  result="$(_search_title_prefix "$text")"
  [ "$result" = "Real Title" ]
}

@test "_search_title_prefix handles TITLE: with extra spaces" {
  local result
  result="$(_search_title_prefix "TITLE:   Extra Spaces  ")"
  [ "$result" = "Extra Spaces  " ]
}

# --- _oldest_commit_message ---

@test "_oldest_commit_message returns first commit on branch" {
  create_task_branch "$TEST_PROJECT_DIR" 1
  echo "first" > "$TEST_PROJECT_DIR/first.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "First branch commit" >/dev/null 2>&1
  echo "second" > "$TEST_PROJECT_DIR/second.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Second branch commit" >/dev/null 2>&1

  local result
  result="$(_oldest_commit_message "$TEST_PROJECT_DIR")"
  [ "$result" = "First branch commit" ]
}

@test "_oldest_commit_message returns empty when no branch commits" {
  local result
  result="$(_oldest_commit_message "$TEST_PROJECT_DIR")"
  [ -z "$result" ]
}

# --- _extract_pr_title ---

@test "_extract_pr_title extracts title from TITLE: prefix" {
  local result
  result="$(_extract_pr_title "TITLE: feat: add auth module" "$TEST_PROJECT_DIR")"
  [ "$result" = "feat: add auth module" ]
}

@test "_extract_pr_title finds TITLE: after preamble text" {
  local text="I've implemented the requested changes.
Here's a summary of what was done:
TITLE: refactor: improve error handling
The changes include..."
  local result
  result="$(_extract_pr_title "$text" "$TEST_PROJECT_DIR")"
  [ "$result" = "refactor: improve error handling" ]
}

@test "_extract_pr_title strips quotes from TITLE: value" {
  local result
  result="$(_extract_pr_title 'TITLE: "fix: resolve race condition"' "$TEST_PROJECT_DIR")"
  [ "$result" = "fix: resolve race condition" ]
}

@test "_extract_pr_title falls back to oldest commit message" {
  create_task_branch "$TEST_PROJECT_DIR" 1
  echo "change" > "$TEST_PROJECT_DIR/change.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "feat: my fallback title" >/dev/null 2>&1

  local result
  result="$(_extract_pr_title "No title marker here" "$TEST_PROJECT_DIR")"
  [ "$result" = "feat: my fallback title" ]
}

@test "_extract_pr_title returns empty and fails when no title found" {
  run _extract_pr_title "No markers and no branch commits" "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "_extract_pr_title prefers TITLE: over commit fallback" {
  create_task_branch "$TEST_PROJECT_DIR" 1
  echo "change" > "$TEST_PROJECT_DIR/change.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "commit message" >/dev/null 2>&1

  local result
  result="$(_extract_pr_title "TITLE: explicit title" "$TEST_PROJECT_DIR")"
  [ "$result" = "explicit title" ]
}

# --- _extract_pr_body ---

@test "_extract_pr_body extracts body after BODY: marker" {
  local text="TITLE: My Title
BODY: This is the body content.
It has multiple lines.
And more detail."
  local result
  result="$(_extract_pr_body "$text")"
  [[ "$result" == *"This is the body content."* ]]
  [[ "$result" == *"It has multiple lines."* ]]
  [[ "$result" == *"And more detail."* ]]
}

@test "_extract_pr_body captures inline content after BODY:" {
  local text="BODY: Single line body"
  local result
  result="$(_extract_pr_body "$text")"
  [[ "$result" == *"Single line body"* ]]
}

@test "_extract_pr_body stops at TITLE: marker" {
  local text="BODY: Body text here
More body
TITLE: Should Not Be In Body"
  local result
  result="$(_extract_pr_body "$text")"
  [[ "$result" == *"Body text here"* ]]
  [[ "$result" == *"More body"* ]]
  [[ "$result" != *"Should Not Be In Body"* ]]
}

@test "_extract_pr_body stops at END_BODY marker" {
  local text="BODY: Content before end
More content
END_BODY
After end"
  local result
  result="$(_extract_pr_body "$text")"
  [[ "$result" == *"Content before end"* ]]
  [[ "$result" == *"More content"* ]]
  [[ "$result" != *"After end"* ]]
}

@test "_extract_pr_body returns failure when no BODY: marker" {
  run _extract_pr_body "No body marker here"
  [ "$status" -eq 1 ]
}

@test "_extract_pr_body handles BODY: with leading whitespace" {
  local text="  BODY: Indented body text"
  local result
  result="$(_extract_pr_body "$text")"
  [[ "$result" == *"Indented body text"* ]]
}

# --- Integration: title extraction with git fallback ---

@test "integration: _extract_pr_title with commit fallback after branch creation" {
  create_task_branch "$TEST_PROJECT_DIR" 10
  echo "implementation" > "$TEST_PROJECT_DIR/impl.sh"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "feat: implement auth system" >/dev/null 2>&1

  # No TITLE: in output, should fall back to oldest commit.
  local result
  result="$(_extract_pr_title "Claude output without TITLE marker" "$TEST_PROJECT_DIR")"
  [ "$result" = "feat: implement auth system" ]
}

@test "integration: _extract_pr_title with TITLE: in multi-line output" {
  local output="I've completed the implementation.
Here are the changes:
- Added new module
- Updated tests

TITLE: feat: add new authentication module

Let me know if you need any changes."
  local result
  result="$(_extract_pr_title "$output" "$TEST_PROJECT_DIR")"
  [ "$result" = "feat: add new authentication module" ]
}

@test "integration: full title and body extraction from claude output" {
  local output="I've completed all the changes.

TITLE: feat: add config validation
BODY: Added comprehensive config validation including:
- Type checking for all numeric fields
- Range validation for timeouts
- Path existence checks for context files"
  local title body
  title="$(_extract_pr_title "$output" "$TEST_PROJECT_DIR")"
  body="$(_extract_pr_body "$output")"
  [ "$title" = "feat: add config validation" ]
  [[ "$body" == *"comprehensive config validation"* ]]
  [[ "$body" == *"Type checking"* ]]
}
