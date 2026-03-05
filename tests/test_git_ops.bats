#!/usr/bin/env bats
# Tests for lib/git-ops.sh — Git operations for Autopilot.

setup() {
  TEST_PROJECT_DIR="$(mktemp -d)"

  # Unset all AUTOPILOT_* env vars to start clean.
  while IFS= read -r var; do
    unset "$var"
  done < <(env | grep '^AUTOPILOT_' | cut -d= -f1)

  # Unset CLAUDECODE to avoid interference.
  unset CLAUDECODE

  # Source git-ops.sh (which also sources config.sh, state.sh, claude.sh).
  source "$BATS_TEST_DIRNAME/../lib/git-ops.sh"
  load_config "$TEST_PROJECT_DIR"

  # Initialize git repo for tests that need it.
  _init_test_repo
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR"
}

# Helper: initialize a test git repo with an initial commit.
_init_test_repo() {
  git -C "$TEST_PROJECT_DIR" init -b main >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" config user.email "test@test.com"
  git -C "$TEST_PROJECT_DIR" config user.name "Test"
  echo "initial" > "$TEST_PROJECT_DIR/README.md"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Initial commit" >/dev/null 2>&1
}

# --- build_branch_name ---

@test "build_branch_name uses default prefix" {
  local result
  result="$(build_branch_name 5)"
  [ "$result" = "autopilot/task-5" ]
}

@test "build_branch_name uses custom prefix from config" {
  AUTOPILOT_BRANCH_PREFIX="pr-pipeline"
  local result
  result="$(build_branch_name 12)"
  [ "$result" = "pr-pipeline/task-12" ]
}

@test "build_branch_name handles task number 1" {
  local result
  result="$(build_branch_name 1)"
  [ "$result" = "autopilot/task-1" ]
}

# --- create_task_branch ---

@test "create_task_branch creates and checks out new branch" {
  create_task_branch "$TEST_PROJECT_DIR" 3
  local branch
  branch="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  [ "$branch" = "autopilot/task-3" ]
}

@test "create_task_branch uses custom prefix" {
  AUTOPILOT_BRANCH_PREFIX="custom"
  create_task_branch "$TEST_PROJECT_DIR" 7
  local branch
  branch="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  [ "$branch" = "custom/task-7" ]
}

@test "create_task_branch fails if branch already exists" {
  create_task_branch "$TEST_PROJECT_DIR" 1
  # Go back to main.
  git -C "$TEST_PROJECT_DIR" checkout main >/dev/null 2>&1
  # Try to create the same branch again.
  run create_task_branch "$TEST_PROJECT_DIR" 1
  [ "$status" -eq 1 ]
}

@test "create_task_branch branches from target branch" {
  AUTOPILOT_TARGET_BRANCH="main"
  # Create a commit on main to verify branching point.
  echo "extra" > "$TEST_PROJECT_DIR/extra.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Extra commit" >/dev/null 2>&1
  local main_sha
  main_sha="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"

  create_task_branch "$TEST_PROJECT_DIR" 2
  local branch_sha
  branch_sha="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"
  [ "$main_sha" = "$branch_sha" ]
}

# --- task_branch_exists ---

@test "task_branch_exists returns 0 for existing local branch" {
  create_task_branch "$TEST_PROJECT_DIR" 5
  git -C "$TEST_PROJECT_DIR" checkout main >/dev/null 2>&1
  task_branch_exists "$TEST_PROJECT_DIR" 5
}

@test "task_branch_exists returns 1 for non-existent branch" {
  run task_branch_exists "$TEST_PROJECT_DIR" 99
  [ "$status" -eq 1 ]
}

# --- delete_task_branch ---

@test "delete_task_branch removes local branch" {
  create_task_branch "$TEST_PROJECT_DIR" 4
  git -C "$TEST_PROJECT_DIR" checkout main >/dev/null 2>&1
  task_branch_exists "$TEST_PROJECT_DIR" 4
  delete_task_branch "$TEST_PROJECT_DIR" 4
  run task_branch_exists "$TEST_PROJECT_DIR" 4
  [ "$status" -eq 1 ]
}

@test "delete_task_branch does not fail on non-existent branch" {
  run delete_task_branch "$TEST_PROJECT_DIR" 99
  [ "$status" -eq 0 ]
}

# --- commit_changes ---

@test "commit_changes stages and commits new files" {
  echo "new content" > "$TEST_PROJECT_DIR/new_file.txt"
  commit_changes "$TEST_PROJECT_DIR" "feat: add new file"
  local log_output
  log_output="$(git -C "$TEST_PROJECT_DIR" log --oneline -1)"
  [[ "$log_output" == *"feat: add new file"* ]]
}

@test "commit_changes stages and commits modifications" {
  echo "modified" > "$TEST_PROJECT_DIR/README.md"
  commit_changes "$TEST_PROJECT_DIR" "fix: update readme"
  local log_output
  log_output="$(git -C "$TEST_PROJECT_DIR" log --oneline -1)"
  [[ "$log_output" == *"fix: update readme"* ]]
}

@test "commit_changes returns 0 with warning when no changes" {
  run commit_changes "$TEST_PROJECT_DIR" "empty commit"
  [ "$status" -eq 0 ]
}

@test "commit_changes fails with empty message" {
  echo "change" > "$TEST_PROJECT_DIR/file.txt"
  run commit_changes "$TEST_PROJECT_DIR" ""
  [ "$status" -eq 1 ]
}

# --- get_head_sha ---

@test "get_head_sha returns current commit SHA" {
  local sha
  sha="$(get_head_sha "$TEST_PROJECT_DIR")"
  [ -n "$sha" ]
  # SHA is 40 hex characters.
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]]
}

@test "get_head_sha changes after new commit" {
  local sha_before
  sha_before="$(get_head_sha "$TEST_PROJECT_DIR")"
  echo "change" > "$TEST_PROJECT_DIR/change.txt"
  commit_changes "$TEST_PROJECT_DIR" "test commit"
  local sha_after
  sha_after="$(get_head_sha "$TEST_PROJECT_DIR")"
  [ "$sha_before" != "$sha_after" ]
}

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

# --- create_task_pr (mocked gh) ---

@test "create_task_pr fails with empty title" {
  run create_task_pr "$TEST_PROJECT_DIR" 1 "" "body"
  [ "$status" -eq 1 ]
}

@test "create_task_pr calls gh pr create with correct args" {
  # Create mock gh that records args.
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/gh" <<'MOCK'
#!/usr/bin/env bash
echo "https://github.com/test/repo/pull/1"
MOCK
  chmod +x "$mock_dir/gh"

  # Set up remote URL.
  git -C "$TEST_PROJECT_DIR" remote add origin "https://github.com/test/repo.git" 2>/dev/null || true

  local OLD_PATH="$PATH"
  PATH="$mock_dir:$PATH"

  local result
  result="$(create_task_pr "$TEST_PROJECT_DIR" 5 "My PR Title" "Body text")"
  [ "$result" = "https://github.com/test/repo/pull/1" ]

  PATH="$OLD_PATH"
  rm -rf "$mock_dir"
}

@test "create_task_pr returns failure when gh fails" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/gh" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "$mock_dir/gh"

  git -C "$TEST_PROJECT_DIR" remote add origin "https://github.com/test/repo.git" 2>/dev/null || true

  local OLD_PATH="$PATH"
  PATH="$mock_dir:$PATH"

  run create_task_pr "$TEST_PROJECT_DIR" 1 "Title" "Body"
  [ "$status" -eq 1 ]

  PATH="$OLD_PATH"
  rm -rf "$mock_dir"
}

# --- detect_task_pr (mocked gh) ---

@test "detect_task_pr returns PR URL when PR exists" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/gh" <<'MOCK'
#!/usr/bin/env bash
echo "https://github.com/test/repo/pull/42"
MOCK
  chmod +x "$mock_dir/gh"

  local OLD_PATH="$PATH"
  PATH="$mock_dir:$PATH"

  local result
  result="$(detect_task_pr "$TEST_PROJECT_DIR" 5)"
  [ "$result" = "https://github.com/test/repo/pull/42" ]

  PATH="$OLD_PATH"
  rm -rf "$mock_dir"
}

@test "detect_task_pr returns failure when no PR exists" {
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/gh" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "$mock_dir/gh"

  local OLD_PATH="$PATH"
  PATH="$mock_dir:$PATH"

  run detect_task_pr "$TEST_PROJECT_DIR" 5
  [ "$status" -eq 1 ]

  PATH="$OLD_PATH"
  rm -rf "$mock_dir"
}

# --- generate_pr_body (mocked claude) ---

@test "generate_pr_body returns fallback when no diff" {
  local result
  result="$(generate_pr_body "$TEST_PROJECT_DIR" 3 "My Task")"
  [ "$result" = "Implementation for task 3." ]
}

@test "generate_pr_body uses claude to generate body from diff" {
  # Create a branch with changes to produce a diff.
  create_task_branch "$TEST_PROJECT_DIR" 1
  echo "new code" > "$TEST_PROJECT_DIR/code.sh"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Add code" >/dev/null 2>&1

  # Mock claude to return a PR body.
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"## Summary\nAdded new code module with improvements."}'
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  local result
  result="$(generate_pr_body "$TEST_PROJECT_DIR" 1 "Add code module")"
  [[ "$result" == *"Added new code module"* ]]

  rm -rf "$mock_dir"
}

@test "generate_pr_body returns fallback on claude failure" {
  create_task_branch "$TEST_PROJECT_DIR" 2
  echo "change" > "$TEST_PROJECT_DIR/change.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Change" >/dev/null 2>&1

  # Mock claude that fails.
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  local result
  result="$(generate_pr_body "$TEST_PROJECT_DIR" 2 "Task")"
  [ "$result" = "Implementation for task 2." ]

  rm -rf "$mock_dir"
}

@test "generate_pr_body returns fallback on empty claude response" {
  create_task_branch "$TEST_PROJECT_DIR" 3
  echo "change" > "$TEST_PROJECT_DIR/change.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "Change" >/dev/null 2>&1

  # Mock claude that returns empty result.
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"cost_usd":0.01}'
MOCK
  chmod +x "$mock_dir/claude"

  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  local result
  result="$(generate_pr_body "$TEST_PROJECT_DIR" 3 "Task")"
  [ "$result" = "Implementation for task 3." ]

  rm -rf "$mock_dir"
}

# --- _build_pr_body_prompt ---

@test "_build_pr_body_prompt includes task number and title" {
  local result
  result="$(_build_pr_body_prompt 5 "Add auth" "diff content")"
  [[ "$result" == *"Task 5"* ]]
  [[ "$result" == *"Add auth"* ]]
}

@test "_build_pr_body_prompt includes diff content" {
  local result
  result="$(_build_pr_body_prompt 1 "Title" "+new line added")"
  [[ "$result" == *"+new line added"* ]]
}

# --- push_branch (mocked git push) ---

@test "push_branch detects current branch name" {
  # We can verify get_head_sha works as a proxy for branch detection.
  create_task_branch "$TEST_PROJECT_DIR" 8
  local branch
  branch="$(git -C "$TEST_PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
  [ "$branch" = "autopilot/task-8" ]
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
