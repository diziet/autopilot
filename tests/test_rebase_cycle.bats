#!/usr/bin/env bats
# Tests for auto-rebase behavior after squash merges.
# Validates Task 40 end-to-end using the mock harness from Task 41.
# Covers: conflict detection, auto-rebase success/failure, no-rebase path.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/dispatcher.sh"

setup_file() {
  _create_test_template

  # Build a rebase-specific template: git repo + bare remote with shared.txt.
  _REBASE_TEMPLATE_DIR="${BATS_FILE_TMPDIR}/rebase_template"
  export _REBASE_TEMPLATE_DIR
  mkdir -p "$_REBASE_TEMPLATE_DIR"

  # Build bare remote.
  local bare_dir="${_REBASE_TEMPLATE_DIR}/bare"
  mkdir -p "$bare_dir"
  git init --bare "$bare_dir" -q -b main 2>/dev/null

  # Build local repo with tasks, CLAUDE.md, shared.txt, and push to bare.
  local repo_dir="${_REBASE_TEMPLATE_DIR}/repo"
  _fast_copy "$_TEMPLATE_GIT_DIR" "$repo_dir"
  mkdir -p "$repo_dir/.autopilot/logs" "$repo_dir/.autopilot/locks"
  echo "$_TEMPLATE_STATE_JSON" > "$repo_dir/.autopilot/state.json"
  echo "initial content" > "$repo_dir/README.md"
  echo "shared line v1" > "$repo_dir/shared.txt"
  printf '## Task 1: First task\nDo first thing.\n\n## Task 2: Second task\nDo second thing.\n\n' > "$repo_dir/tasks.md"
  echo "# Test Project" > "$repo_dir/CLAUDE.md"
  git -C "$repo_dir" add -A >/dev/null 2>&1
  git -C "$repo_dir" commit -m "add test files" -q 2>/dev/null || true
  git -C "$repo_dir" remote set-url origin "$bare_dir" 2>/dev/null || \
    git -C "$repo_dir" remote add origin "$bare_dir"
  git -C "$repo_dir" push -u origin main >/dev/null 2>&1

  # Build timeout mock script in template.
  _REBASE_MOCK_DIR="${_REBASE_TEMPLATE_DIR}/mocks"
  export _REBASE_MOCK_DIR
  mkdir -p "$_REBASE_MOCK_DIR"
  cat > "${_REBASE_MOCK_DIR}/timeout" << 'MOCK'
#!/usr/bin/env bash
shift
exec "$@"
MOCK
  chmod +x "${_REBASE_MOCK_DIR}/timeout"
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  # Copy pre-built templates (fast COW copy on APFS).
  TEST_PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  TEST_BARE_REMOTE="$BATS_TEST_TMPDIR/bare_remote"
  GH_MOCK_DIR="$BATS_TEST_TMPDIR/gh_mock"
  CLAUDE_MOCK_DIR="$BATS_TEST_TMPDIR/claude_mock"

  _fast_copy "${_REBASE_TEMPLATE_DIR}/repo" "$TEST_PROJECT_DIR"
  _fast_copy "${_REBASE_TEMPLATE_DIR}/bare" "$TEST_BARE_REMOTE"
  mkdir -p "$GH_MOCK_DIR" "$CLAUDE_MOCK_DIR"

  export GH_MOCK_DIR CLAUDE_MOCK_DIR

  # Point local repo's remote at the per-test bare remote copy.
  git -C "$TEST_PROJECT_DIR" remote set-url origin "$TEST_BARE_REMOTE"

  # Reset environment and config.
  _unset_autopilot_vars
  _set_defaults
  _AUTOPILOT_CONFIG_LOADED=1
  AUTOPILOT_USE_WORKTREES="false"

  # Put fixture mocks and template mocks on PATH.
  FIXTURES_BIN="$BATS_TEST_DIRNAME/fixtures/bin"
  export PATH="${FIXTURES_BIN}:${_REBASE_MOCK_DIR}:${_TEMPLATE_MOCK_DIR}:${PATH}"

  # Mock preflight to skip dependency/auth checks.
  run_preflight() { return 0; }
  export -f run_preflight

  # Override get_repo_slug so check_pr_mergeable can resolve --repo.
  get_repo_slug() { echo "testowner/testrepo"; }
  export -f get_repo_slug
}

# --- Setup Helpers ---

# Create squash-merge scenario for task-1 and diverged task-2.
# Base repo with shared.txt already exists from template copy.
_setup_squash_merge_scenario() {
  # Save pre-merge main SHA.
  PRE_MERGE_SHA="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"

  # Create task-1 branch with a commit.
  git -C "$TEST_PROJECT_DIR" checkout -b "autopilot/task-1" -q
  echo "task 1 feature" > "$TEST_PROJECT_DIR/feature-a.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "feat: task 1 implementation" -q
  git -C "$TEST_PROJECT_DIR" push origin "autopilot/task-1" \
    >/dev/null 2>&1

  # Branch task-2 from task-1 (has original task-1 commit).
  git -C "$TEST_PROJECT_DIR" checkout -b "autopilot/task-2" -q
  echo "task 2 feature" > "$TEST_PROJECT_DIR/feature-b.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "feat: task 2 implementation" -q
  git -C "$TEST_PROJECT_DIR" push origin "autopilot/task-2" \
    >/dev/null 2>&1

  # Squash-merge task-1 into main (creates different SHA).
  git -C "$TEST_PROJECT_DIR" checkout main -q
  git -C "$TEST_PROJECT_DIR" merge --squash "autopilot/task-1" \
    >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit -m "feat: task 1 (squash)" -q
  SQUASH_SHA="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"
  git -C "$TEST_PROJECT_DIR" push origin main >/dev/null 2>&1

  # Switch to task-2 branch for testing.
  git -C "$TEST_PROJECT_DIR" checkout "autopilot/task-2" -q
}

# Create scenario with a real merge conflict on task-2.
# Base repo with shared.txt already exists from template copy.
_setup_conflict_scenario() {
  # Create task-1 branch modifying shared.txt.
  git -C "$TEST_PROJECT_DIR" checkout -b "autopilot/task-1" -q
  echo "task 1 version of shared" > "$TEST_PROJECT_DIR/shared.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit \
    -m "feat: task 1 modifies shared" -q
  git -C "$TEST_PROJECT_DIR" push origin "autopilot/task-1" \
    >/dev/null 2>&1

  # Branch task-2 from main (before squash merge).
  git -C "$TEST_PROJECT_DIR" checkout main -q
  git -C "$TEST_PROJECT_DIR" checkout -b "autopilot/task-2" -q
  echo "task 2 DIFFERENT version of shared" \
    > "$TEST_PROJECT_DIR/shared.txt"
  git -C "$TEST_PROJECT_DIR" add -A >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit \
    -m "feat: task 2 conflicts with shared" -q
  git -C "$TEST_PROJECT_DIR" push origin "autopilot/task-2" \
    >/dev/null 2>&1

  # Squash-merge task-1 into main.
  git -C "$TEST_PROJECT_DIR" checkout main -q
  git -C "$TEST_PROJECT_DIR" merge --squash "autopilot/task-1" \
    >/dev/null 2>&1
  git -C "$TEST_PROJECT_DIR" commit \
    -m "feat: task 1 shared change (squash)" -q
  git -C "$TEST_PROJECT_DIR" push origin main >/dev/null 2>&1

  # Switch to task-2 branch.
  git -C "$TEST_PROJECT_DIR" checkout "autopilot/task-2" -q
}

# --- State Helpers ---

# Set pipeline state.
_set_state() { write_state "$TEST_PROJECT_DIR" "status" "$1"; }

# Set current task number.
_set_task() { write_state_num "$TEST_PROJECT_DIR" "current_task" "$1"; }

# Read pipeline status.
_get_status() { read_state "$TEST_PROJECT_DIR" "status"; }

# ============================================================
# Test 1: Setup — squash merge creates diverged history
# ============================================================

@test "setup: squash merge creates different SHA than original commit" {
  _setup_squash_merge_scenario

  # Task-2 branch should exist and be checked out.
  local current_branch
  current_branch="$(git -C "$TEST_PROJECT_DIR" \
    rev-parse --abbrev-ref HEAD)"
  [ "$current_branch" = "autopilot/task-2" ]

  # Main should have the squash commit (different SHA from task-1 tip).
  local task1_sha main_sha
  task1_sha="$(git -C "$TEST_PROJECT_DIR" \
    rev-parse "autopilot/task-1" 2>/dev/null)"
  main_sha="$(git -C "$TEST_PROJECT_DIR" \
    rev-parse main 2>/dev/null)"
  [[ "$task1_sha" != "$main_sha" ]]

  # The squash merge should include task-1's file.
  git -C "$TEST_PROJECT_DIR" checkout main -q
  [ -f "$TEST_PROJECT_DIR/feature-a.txt" ]

  # Task-2 should also have task-1's file (branched from task-1).
  git -C "$TEST_PROJECT_DIR" checkout "autopilot/task-2" -q
  [ -f "$TEST_PROJECT_DIR/feature-a.txt" ]
  [ -f "$TEST_PROJECT_DIR/feature-b.txt" ]
}

# ============================================================
# Test 2: Conflict detection — CONFLICTING before merger
# ============================================================

@test "conflict detection: check_pr_mergeable returns CONFLICTING" {
  _setup_squash_merge_scenario

  # Mock gh pr view to return CONFLICTING status.
  cp "$BATS_TEST_DIRNAME/fixtures/pr-view-conflicting.json" \
    "$GH_MOCK_DIR/pr-view.json"

  local status
  status="$(check_pr_mergeable "$TEST_PROJECT_DIR" 2)"
  [ "$status" = "$PR_MERGEABLE_CONFLICTING" ]
}

@test "conflict detection: dispatcher detects conflict before merger" {
  _setup_squash_merge_scenario

  _set_state "fixed"
  _set_task 2
  write_state "$TEST_PROJECT_DIR" "pr_number" "2"

  # Mock gh pr view to return CONFLICTING.
  cp "$BATS_TEST_DIRNAME/fixtures/pr-view-conflicting.json" \
    "$GH_MOCK_DIR/pr-view.json"

  # Mock rebase_task_branch to fail (simulating unresolvable conflict).
  rebase_task_branch() { return 1; }
  export -f rebase_task_branch

  # Track whether merger was called.
  local merger_called=false
  run_merger() { merger_called=true; return 0; }
  export -f run_merger
  record_phase_transition() { return 0; }
  export -f record_phase_transition

  dispatch_tick "$TEST_PROJECT_DIR"

  # State should go to reviewed (conflict resolution failed).
  [ "$(_get_status)" = "reviewed" ]

  # Merger should NOT have been called.
  [ "$merger_called" = false ]
}

@test "conflict detection: reviewed.json cleared to prevent fixed-reviewed loop" {
  _setup_squash_merge_scenario

  _set_state "fixed"
  _set_task 2
  write_state "$TEST_PROJECT_DIR" "pr_number" "2"

  # Pre-populate reviewed.json with clean reviews (simulating prior approval).
  cat > "$TEST_PROJECT_DIR/.autopilot/reviewed.json" << 'JSON'
{"pr_2":{"general":{"sha":"a","is_clean":true},"security":{"sha":"a","is_clean":true}}}
JSON

  # Mock gh pr view to return CONFLICTING.
  cp "$BATS_TEST_DIRNAME/fixtures/pr-view-conflicting.json" \
    "$GH_MOCK_DIR/pr-view.json"

  # Mock rebase to fail.
  rebase_task_branch() { return 1; }
  export -f rebase_task_branch
  run_merger() { return 0; }
  record_phase_transition() { return 0; }
  export -f run_merger record_phase_transition

  dispatch_tick "$TEST_PROJECT_DIR"

  # After conflict resolution failure, reviewed.json should have
  # the PR key removed so _handle_reviewed won't skip the fixer.
  local reviewed_file="${TEST_PROJECT_DIR}/.autopilot/reviewed.json"
  [ -f "$reviewed_file" ]
  local has_pr_key
  has_pr_key="$(jq 'has("pr_2")' "$reviewed_file")"
  [ "$has_pr_key" = "false" ]
}

# ============================================================
# Test 3: Auto-rebase succeeds — same changes, different SHAs
# ============================================================

@test "auto-rebase succeeds: rebase resolves squash-merge divergence" {
  _setup_squash_merge_scenario

  # Fetch to ensure origin/main is up to date locally.
  git -C "$TEST_PROJECT_DIR" fetch origin >/dev/null 2>&1

  # Record SHA before rebase.
  local sha_before
  sha_before="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"

  # rebase_task_branch should succeed (same changes, different SHAs).
  run rebase_task_branch "$TEST_PROJECT_DIR" 2
  [ "$status" -eq 0 ]

  # After rebase, HEAD should have changed (rebased onto new main).
  local sha_after
  sha_after="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"
  [[ "$sha_after" != "$sha_before" ]]

  # Task-2's file should still exist after rebase.
  [ -f "$TEST_PROJECT_DIR/feature-b.txt" ]

  # Remote should have the rebased branch.
  local remote_sha
  remote_sha="$(git -C "$TEST_BARE_REMOTE" \
    rev-parse "autopilot/task-2" 2>/dev/null)"
  [ "$remote_sha" = "$sha_after" ]
}

@test "auto-rebase succeeds: state proceeds to merging" {
  _setup_squash_merge_scenario

  _set_state "fixed"
  _set_task 2
  write_state "$TEST_PROJECT_DIR" "pr_number" "2"

  # Mock returns CONFLICTING — rebase succeeds, so merger proceeds.
  check_pr_mergeable() { echo "$PR_MERGEABLE_CONFLICTING"; }
  export -f check_pr_mergeable

  # rebase_task_branch succeeds.
  rebase_task_branch() { return 0; }
  export -f rebase_task_branch

  # Mock merger to approve.
  run_merger() { return "$MERGER_APPROVE"; }
  record_phase_transition() { return 0; }
  export -f run_merger record_phase_transition

  dispatch_tick "$TEST_PROJECT_DIR"

  # State should have advanced through merging to merged.
  [ "$(_get_status)" = "merged" ]
}

# ============================================================
# Test 4: Auto-rebase fails — real conflict
# ============================================================

@test "auto-rebase fails: rebase is attempted and aborted on conflict" {
  _setup_conflict_scenario

  # Fetch to ensure origin/main is up to date locally.
  git -C "$TEST_PROJECT_DIR" fetch origin >/dev/null 2>&1

  # Record SHA before rebase attempt.
  local sha_before
  sha_before="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"

  # Rebase should fail due to conflicting shared.txt changes.
  run rebase_task_branch "$TEST_PROJECT_DIR" 2
  [ "$status" -ne 0 ]

  # After abort, HEAD should be unchanged (rebase was aborted).
  local sha_after
  sha_after="$(git -C "$TEST_PROJECT_DIR" rev-parse HEAD)"
  [ "$sha_after" = "$sha_before" ]

  # No active rebase should remain after abort.
  [ ! -d "$TEST_PROJECT_DIR/.git/rebase-merge" ]
  [ ! -d "$TEST_PROJECT_DIR/.git/rebase-apply" ]

  # Conflicted file should have task-2's original content (restored).
  grep -q "task 2 DIFFERENT version" "$TEST_PROJECT_DIR/shared.txt"
}

@test "auto-rebase fails: fixer gets diagnosis hint about conflict" {
  _setup_conflict_scenario

  _set_state "fixed"
  _set_task 2
  write_state "$TEST_PROJECT_DIR" "pr_number" "2"

  # Mock gh pr view to return CONFLICTING.
  cp "$BATS_TEST_DIRNAME/fixtures/pr-view-conflicting.json" \
    "$GH_MOCK_DIR/pr-view.json"

  # Use real rebase_task_branch (will fail on conflict).

  # Track merger calls.
  local merger_called=false
  run_merger() { merger_called=true; return 0; }
  export -f run_merger
  record_phase_transition() { return 0; }
  export -f record_phase_transition

  dispatch_tick "$TEST_PROJECT_DIR"

  # State should go to reviewed (rebase failed → fixer path).
  [ "$(_get_status)" = "reviewed" ]

  # Merger should NOT have been called.
  [ "$merger_called" = false ]

  # Diagnosis hints should mention rebase conflict.
  local hints_file
  hints_file="${TEST_PROJECT_DIR}/.autopilot/diagnosis-hints-task-2.md"
  [ -f "$hints_file" ]
  grep -qi "rebase" "$hints_file"
  grep -qi "conflict" "$hints_file"
}

# ============================================================
# Test 5: No rebase needed — CLEAN from the start
# ============================================================

@test "no rebase needed: CLEAN status skips rebase, merger runs" {
  _setup_squash_merge_scenario

  _set_state "fixed"
  _set_task 2
  write_state "$TEST_PROJECT_DIR" "pr_number" "2"

  # Mock gh pr view to return CLEAN.
  cp "$BATS_TEST_DIRNAME/fixtures/pr-view-clean.json" \
    "$GH_MOCK_DIR/pr-view.json"

  # Track rebase calls.
  local rebase_called=false
  rebase_task_branch() { rebase_called=true; return 0; }
  export -f rebase_task_branch

  # Mock merger to approve.
  run_merger() { return "$MERGER_APPROVE"; }
  record_phase_transition() { return 0; }
  export -f run_merger record_phase_transition

  dispatch_tick "$TEST_PROJECT_DIR"

  # No rebase should have been attempted.
  [ "$rebase_called" = false ]

  # State should advance to merged (merger approved).
  [ "$(_get_status)" = "merged" ]
}

@test "no rebase needed: check_pr_mergeable returns CLEAN" {
  _setup_squash_merge_scenario

  # Mock gh pr view to return CLEAN.
  cp "$BATS_TEST_DIRNAME/fixtures/pr-view-clean.json" \
    "$GH_MOCK_DIR/pr-view.json"

  local status
  status="$(check_pr_mergeable "$TEST_PROJECT_DIR" 2)"
  [ "$status" = "$PR_MERGEABLE_CLEAN" ]
}
