#!/usr/bin/env bats
# Tests for mock gh and claude scripts in tests/fixtures/bin/.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

setup() {
  GH_MOCK_DIR="$BATS_TEST_TMPDIR/gh_mock"
  mkdir -p "$GH_MOCK_DIR"
  CLAUDE_MOCK_DIR="$BATS_TEST_TMPDIR/claude_mock"
  mkdir -p "$CLAUDE_MOCK_DIR"
  TEST_REPO_DIR="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$TEST_REPO_DIR"

  export GH_MOCK_DIR CLAUDE_MOCK_DIR

  # Put mock binaries on PATH ahead of real ones.
  FIXTURES_BIN="$BATS_TEST_DIRNAME/fixtures/bin"
  export PATH="$FIXTURES_BIN:$PATH"

  # Initialize a git repo for claude mock tests.
  git -C "$TEST_REPO_DIR" init -b main >/dev/null 2>&1
  git -C "$TEST_REPO_DIR" config user.email "test@test.com"
  git -C "$TEST_REPO_DIR" config user.name "Test"
  echo "initial" > "$TEST_REPO_DIR/README.md"
  git -C "$TEST_REPO_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_REPO_DIR" commit -m "Initial commit" >/dev/null 2>&1
}

# ============================================================
# Mock gh — pr create
# ============================================================

@test "gh pr create returns default PR URL" {
  run gh pr create --title "test" --body "body"
  [ "$status" -eq 0 ]
  [[ "$output" == "https://github.com/test/repo/pull/1" ]]
}

@test "gh pr create returns custom response from fixture file" {
  echo "https://github.com/org/project/pull/42" > "$GH_MOCK_DIR/pr-create-response.txt"
  run gh pr create --title "feat" --body "desc"
  [ "$status" -eq 0 ]
  [[ "$output" == "https://github.com/org/project/pull/42" ]]
}

@test "gh pr create records call args to log" {
  gh pr create --title "test pr" --body "body text"
  [ -f "$GH_MOCK_DIR/pr-create-calls.log" ]
  local logged
  logged="$(cat "$GH_MOCK_DIR/pr-create-calls.log")"
  [[ "$logged" == *"--title"* ]]
  [[ "$logged" == *"test pr"* ]]
}

# ============================================================
# Mock gh — pr view
# ============================================================

@test "gh pr view returns default JSON" {
  run gh pr view
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.state == "OPEN"'
  echo "$output" | jq -e '.mergeable == "MERGEABLE"'
}

@test "gh pr view returns clean fixture" {
  cp "$BATS_TEST_DIRNAME/fixtures/pr-view-clean.json" "$GH_MOCK_DIR/pr-view.json"
  run gh pr view
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.mergeStateStatus == "CLEAN"'
  echo "$output" | jq -e '.reviewDecision == "APPROVED"'
}

@test "gh pr view returns conflicting fixture" {
  cp "$BATS_TEST_DIRNAME/fixtures/pr-view-conflicting.json" "$GH_MOCK_DIR/pr-view.json"
  run gh pr view
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.mergeable == "CONFLICTING"'
  echo "$output" | jq -e '.mergeStateStatus == "DIRTY"'
}

# ============================================================
# Mock gh — pr list
# ============================================================

@test "gh pr list returns default empty array" {
  run gh pr list
  [ "$status" -eq 0 ]
  [[ "$output" == "[]" ]]
}

@test "gh pr list returns fixture with PR" {
  cp "$BATS_TEST_DIRNAME/fixtures/pr-list-with-pr.json" "$GH_MOCK_DIR/pr-list.json"
  run gh pr list
  [ "$status" -eq 0 ]
  local count
  count="$(echo "$output" | jq 'length')"
  [ "$count" -eq 1 ]
  echo "$output" | jq -e '.[0].number == 1'
}

# ============================================================
# Mock gh — pr merge
# ============================================================

@test "gh pr merge echoes merged" {
  run gh pr merge 1 --squash
  [ "$status" -eq 0 ]
  [[ "$output" == "merged" ]]
}

@test "gh pr merge records call args to log" {
  gh pr merge 42 --rebase
  [ -f "$GH_MOCK_DIR/pr-merge-calls.log" ]
  local logged
  logged="$(cat "$GH_MOCK_DIR/pr-merge-calls.log")"
  [[ "$logged" == *"42"* ]]
  [[ "$logged" == *"--rebase"* ]]
}

# ============================================================
# Mock gh — pr diff
# ============================================================

@test "gh pr diff returns empty by default" {
  run gh pr diff
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "gh pr diff returns fixture content" {
  printf 'diff --git a/file.txt b/file.txt\n+new line\n' > "$GH_MOCK_DIR/pr-diff.txt"
  run gh pr diff
  [ "$status" -eq 0 ]
  [[ "$output" == *"+new line"* ]]
}

# ============================================================
# Mock gh — api
# ============================================================

@test "gh api returns default empty JSON object" {
  run gh api repos/test/repo
  [ "$status" -eq 0 ]
  [[ "$output" == "{}" ]]
}

@test "gh api returns fixture content" {
  echo '{"total_count": 5, "items": []}' > "$GH_MOCK_DIR/api-response.json"
  run gh api search/issues
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.total_count == 5'
}

# ============================================================
# Mock gh — call logging
# ============================================================

@test "gh logs all calls to gh-calls.log" {
  gh pr create --title "first"
  gh pr list
  gh pr view
  gh api repos/x/y

  [ -f "$GH_MOCK_DIR/gh-calls.log" ]
  local line_count
  line_count="$(wc -l < "$GH_MOCK_DIR/gh-calls.log" | tr -d ' ')"
  [ "$line_count" -eq 4 ]

  local log_content
  log_content="$(cat "$GH_MOCK_DIR/gh-calls.log")"
  [[ "$log_content" == *"gh pr create"* ]]
  [[ "$log_content" == *"gh pr list"* ]]
  [[ "$log_content" == *"gh pr view"* ]]
  [[ "$log_content" == *"gh api"* ]]
}

# ============================================================
# Mock gh — exit code override
# ============================================================

@test "gh respects GH_MOCK_EXIT override" {
  GH_MOCK_EXIT=1 run gh pr view
  [ "$status" -eq 1 ]
}

@test "gh exit code override works with any value" {
  GH_MOCK_EXIT=42 run gh pr list
  [ "$status" -eq 42 ]
}

@test "gh exit code override produces no output" {
  GH_MOCK_EXIT=1 run gh pr create --title "fail"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ============================================================
# Mock claude — default behavior
# ============================================================

@test "claude creates a file and commits by default" {
  cd "$TEST_REPO_DIR"
  run claude --print --output-format json -p "do something"
  [ "$status" -eq 0 ]

  # Verify file was created.
  [ -f "$TEST_REPO_DIR/mock-output.txt" ]

  # Verify commit was made.
  local commit_msg
  commit_msg="$(git -C "$TEST_REPO_DIR" log -1 --pretty=%s)"
  [[ "$commit_msg" == "feat: mock claude commit" ]]
}

@test "claude outputs JSON matching expected shape" {
  cd "$TEST_REPO_DIR"
  run claude --print --output-format json -p "task"
  [ "$status" -eq 0 ]

  # Validate JSON structure.
  echo "$output" | jq -e '.result == "Task complete."'
  echo "$output" | jq -e '.session_id == "mock-session-123"'
}

# ============================================================
# Mock claude — custom actions
# ============================================================

@test "claude sources custom actions.sh" {
  cd "$TEST_REPO_DIR"

  cat > "$CLAUDE_MOCK_DIR/actions.sh" <<'ACTIONS'
echo "custom-content" > "$(pwd)/custom-file.txt"
git add -A >/dev/null 2>&1
git commit -m "feat: custom action" >/dev/null 2>&1
ACTIONS

  run claude --print -p "custom task"
  [ "$status" -eq 0 ]
  [ -f "$TEST_REPO_DIR/custom-file.txt" ]
  [[ "$(cat "$TEST_REPO_DIR/custom-file.txt")" == "custom-content" ]]

  local commit_msg
  commit_msg="$(git -C "$TEST_REPO_DIR" log -1 --pretty=%s)"
  [[ "$commit_msg" == "feat: custom action" ]]
}

# ============================================================
# Mock claude — exit code override
# ============================================================

@test "claude respects CLAUDE_MOCK_EXIT override" {
  cd "$TEST_REPO_DIR"
  CLAUDE_MOCK_EXIT=1 run claude --print -p "fail"
  [ "$status" -eq 1 ]
}

@test "claude exit code override produces no output" {
  cd "$TEST_REPO_DIR"
  CLAUDE_MOCK_EXIT=2 run claude --print -p "fail"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

# ============================================================
# Mock claude — CLAUDE_MOCK_NO_PUSH
# ============================================================

@test "claude commits but does not push when CLAUDE_MOCK_NO_PUSH is set" {
  # Create a bare remote to verify push behavior.
  local remote_dir="$BATS_TEST_TMPDIR/remote_dir"
  mkdir -p "$remote_dir"
  git -C "$remote_dir" init --bare -b main >/dev/null 2>&1
  git -C "$TEST_REPO_DIR" remote add origin "$remote_dir"
  git -C "$TEST_REPO_DIR" push -u origin main >/dev/null 2>&1

  # Record remote HEAD before mock runs.
  local before_sha
  before_sha="$(git -C "$remote_dir" rev-parse HEAD)"

  cd "$TEST_REPO_DIR"
  CLAUDE_MOCK_NO_PUSH=1 run claude --print -p "no push test"
  [ "$status" -eq 0 ]

  # Local commit should exist.
  local local_sha
  local_sha="$(git -C "$TEST_REPO_DIR" rev-parse HEAD)"
  [[ "$local_sha" != "$before_sha" ]]

  # Remote should NOT have the new commit.
  local after_sha
  after_sha="$(git -C "$remote_dir" rev-parse HEAD)"
  [[ "$after_sha" == "$before_sha" ]]
}

@test "claude pushes by default when remote exists" {
  # Create a bare remote.
  local remote_dir="$BATS_TEST_TMPDIR/remote_dir"
  mkdir -p "$remote_dir"
  git -C "$remote_dir" init --bare -b main >/dev/null 2>&1
  git -C "$TEST_REPO_DIR" remote add origin "$remote_dir"
  git -C "$TEST_REPO_DIR" push -u origin main >/dev/null 2>&1

  local before_sha
  before_sha="$(git -C "$remote_dir" rev-parse HEAD)"

  cd "$TEST_REPO_DIR"
  run claude --print -p "push test"
  [ "$status" -eq 0 ]

  # Remote should have the new commit.
  local after_sha
  after_sha="$(git -C "$remote_dir" rev-parse HEAD)"
  [[ "$after_sha" != "$before_sha" ]]
}

# ============================================================
# Mock claude — call logging
# ============================================================

@test "claude logs calls to claude-calls.log" {
  cd "$TEST_REPO_DIR"
  claude --print --output-format json -p "task one"

  [ -f "$CLAUDE_MOCK_DIR/claude-calls.log" ]
  local logged
  logged="$(cat "$CLAUDE_MOCK_DIR/claude-calls.log")"
  [[ "$logged" == *"--print"* ]]
  [[ "$logged" == *"task one"* ]]
}
