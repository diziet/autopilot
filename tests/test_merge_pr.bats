#!/usr/bin/env bats
# Tests for lib/merge-pr.sh — pre-merge PR checks and the squash merge.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/merge-pr.sh"

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template_nogit
  load_config "$TEST_PROJECT_DIR"

  # Default gh and timeout mocks. Tests that need other behavior redefine them.
  gh() { return 0; }
  export -f gh

  timeout() { shift; "$@"; }
  export -f timeout
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
      *"pr view"*"--json state,isDraft"*) echo '{"state":"OPEN","isDraft":false}' ;;
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
      *"pr view"*"--json state,isDraft"*) echo '{"state":"CLOSED","isDraft":false}' ;;
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
      *"pr view"*"--json state,isDraft"*) echo '{"state":"CLOSED","isDraft":false}' ;;
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
      *"pr view"*"--json state,isDraft"*) echo '{"state":"OPEN","isDraft":false}' ;;
      *"pr view"*"--json state"*) echo "OPEN" ;;
      *) return 0 ;;
    esac
  }
  export -f gh

  _ensure_pr_open_for_merge "$TEST_PROJECT_DIR" 42 "testowner/testrepo"
  local exit_code=$?
  [ "$exit_code" -eq 0 ]

  run grep -qF "pr reopen" "$gh_log"
  [ "$status" -eq 1 ]
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
      *"pr view"*"--json state,isDraft"*) echo '{"state":"OPEN","isDraft":false}' ;;
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
      *"pr view"*"--json state,isDraft"*) echo '{"state":"CLOSED","isDraft":false}' ;;
      *"pr view"*"--json state"*) echo "CLOSED" ;;
      *"pr reopen"*) return 1 ;;
      *) return 0 ;;
    esac
  }
  export -f gh

  run squash_merge_pr "$TEST_PROJECT_DIR" 42
  [ "$status" -ne 0 ]

  # Must not attempt merge on a closed PR.
  run grep -qF "pr merge" "$gh_log"
  [ "$status" -eq 1 ]
}

@test "_ensure_pr_open_for_merge detects state correctly when gh emits stderr on success" {
  gh() {
    case "$*" in
      *"pr view"*"--json state,isDraft"*)
        echo "deprecation warning" >&2
        echo '{"state":"OPEN","isDraft":false}'
        return 0
        ;;
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

# --- _ensure_pr_open_for_merge: draft detection ---

@test "_ensure_pr_open_for_merge detects draft PR and converts to ready" {
  local gh_log="${TEST_PROJECT_DIR}/gh_calls.log"
  export GH_LOG="$gh_log"
  gh() {
    echo "$*" >> "$GH_LOG"
    case "$*" in
      *"pr view"*"--json state,isDraft"*) echo '{"state":"OPEN","isDraft":true}' ;;
      *"pr ready"*) return 0 ;;
      *) return 0 ;;
    esac
  }
  export -f gh

  sleep() { return 0; }
  export -f sleep

  _ensure_pr_open_for_merge "$TEST_PROJECT_DIR" 42 "testowner/testrepo"
  local exit_code=$?
  [ "$exit_code" -eq 0 ]

  grep -qF "pr ready 42" "$gh_log"
}

@test "_ensure_pr_open_for_merge returns error when draft conversion fails" {
  gh() {
    case "$*" in
      *"pr view"*"--json state,isDraft"*) echo '{"state":"OPEN","isDraft":true}' ;;
      *"pr ready"*) return 1 ;;
      *) return 0 ;;
    esac
  }
  export -f gh

  run _ensure_pr_open_for_merge "$TEST_PROJECT_DIR" 42 "testowner/testrepo"
  [ "$status" -ne 0 ]
}

@test "_ensure_pr_open_for_merge skips draft conversion for non-draft PR" {
  local gh_log="${TEST_PROJECT_DIR}/gh_calls.log"
  export GH_LOG="$gh_log"
  gh() {
    echo "$*" >> "$GH_LOG"
    case "$*" in
      *"pr view"*"--json state,isDraft"*) echo '{"state":"OPEN","isDraft":false}' ;;
      *) return 0 ;;
    esac
  }
  export -f gh

  _ensure_pr_open_for_merge "$TEST_PROJECT_DIR" 42 "testowner/testrepo"
  local exit_code=$?
  [ "$exit_code" -eq 0 ]

  run grep -qF "pr ready" "$gh_log"
  [ "$status" -eq 1 ]
}
