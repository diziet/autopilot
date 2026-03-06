#!/usr/bin/env bash
# Dispatch handler functions for each pipeline state.
# Split from dispatcher.sh for manageable file size.
# Each handler drives one state transition per tick.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_DISPATCH_HANDLERS_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_DISPATCH_HANDLERS_LOADED=1

# Source terminal state handlers and helpers.
# shellcheck source=lib/dispatch-helpers.sh
source "${BASH_SOURCE[0]%/*}/dispatch-helpers.sh"

# --- pending: read task, preflight, spawn coder ---

# Handle the pending state: read next task, create branch, spawn coder.
_handle_pending() {
  local project_dir="$1"
  local task_number
  task_number="$(read_state "$project_dir" "current_task")"

  # Detect tasks file and check if all tasks are done.
  local tasks_file
  tasks_file="$(detect_tasks_file "$project_dir")" || {
    log_msg "$project_dir" "ERROR" "No tasks file found"
    return 1
  }

  local total_tasks
  total_tasks="$(count_tasks "$tasks_file")"
  if [[ "$task_number" -gt "$total_tasks" ]]; then
    log_msg "$project_dir" "INFO" "All ${total_tasks} tasks completed"
    update_status "$project_dir" "completed" || true
    return 0
  fi

  # Run preflight checks on first tick (retry_count == 0).
  local retry_count
  retry_count="$(get_retry_count "$project_dir")"
  if [[ "$retry_count" -eq 0 ]]; then
    run_preflight "$project_dir" || return 1
  fi

  # Extract the task body.
  local task_body
  task_body="$(extract_task "$tasks_file" "$task_number")" || {
    log_msg "$project_dir" "ERROR" "Failed to extract task ${task_number}"
    return 1
  }

  # Reset stale branch: delete old branch if it exists from a prior failed run.
  if task_branch_exists "$project_dir" "$task_number"; then
    log_msg "$project_dir" "WARNING" \
      "Stale branch found for task ${task_number} — resetting"
    delete_task_branch "$project_dir" "$task_number"
  fi

  # Create the task branch from target.
  create_task_branch "$project_dir" "$task_number" || {
    log_msg "$project_dir" "ERROR" "Failed to create branch for task ${task_number}"
    return 1
  }

  # Record task start time for metrics.
  record_task_start "$project_dir" "$task_number"

  # Read completed task summaries for context.
  local completed_summary
  completed_summary="$(read_completed_summary "$project_dir")"

  update_status "$project_dir" "implementing"

  # Spawn the coder agent (blocking — this is the long-running step).
  local coder_exit=0
  run_coder "$project_dir" "$task_number" "$task_body" \
    "$completed_summary" >/dev/null 2>&1 || coder_exit=$?

  _handle_coder_result "$project_dir" "$task_number" "$coder_exit"
}

# Process coder exit and decide next state.
_handle_coder_result() {
  local project_dir="$1"
  local task_number="$2"
  local coder_exit="$3"

  # If coder crashed (non-zero exit), retry immediately without checking for PR.
  if [[ "$coder_exit" -ne 0 ]]; then
    log_msg "$project_dir" "WARNING" \
      "Coder exited with code ${coder_exit} for task ${task_number} — retrying"
    _retry_or_diagnose "$project_dir" "$task_number" "implementing"
    return
  fi

  # Check if coder produced a PR.
  local pr_url
  pr_url="$(detect_task_pr "$project_dir" "$task_number" 2>/dev/null)" || true

  # Fallback: if coder committed but didn't push/create PR, do it here.
  if [[ -z "$pr_url" ]]; then
    local has_commits
    has_commits="$(git -C "$project_dir" log "${AUTOPILOT_TARGET_BRANCH:-main}..HEAD" \
      --oneline 2>/dev/null | head -1)" || true
    if [[ -n "$has_commits" ]]; then
      log_msg "$project_dir" "INFO" \
        "Coder committed but no PR found — pushing and creating PR for task ${task_number}"
      if push_branch "$project_dir" 2>/dev/null; then
        local pr_title
        pr_title="$(_extract_pr_title "" "$project_dir")" || \
          pr_title="Task ${task_number}"
        local pr_body
        pr_body="$(git -C "$project_dir" log "${AUTOPILOT_TARGET_BRANCH:-main}..HEAD" \
          --format='- %s' 2>/dev/null)" || pr_body=""
        pr_url="$(create_task_pr "$project_dir" "$task_number" \
          "$pr_title" "$pr_body" 2>/dev/null)" || true
      fi
    fi
  fi

  if [[ -z "$pr_url" ]]; then
    log_msg "$project_dir" "WARNING" \
      "No PR detected after coder for task ${task_number} — retrying"
    _retry_or_diagnose "$project_dir" "$task_number" "implementing"
    return
  fi

  # Extract PR number from URL.
  local pr_number
  pr_number="$(_extract_pr_number "$pr_url")"
  write_state "$project_dir" "pr_number" "$pr_number"

  # Run test gate.
  local test_exit=0
  run_test_gate "$project_dir" || test_exit=$?

  if [[ "$test_exit" -eq "$TESTGATE_PASS" ]] || \
     [[ "$test_exit" -eq "$TESTGATE_SKIP" ]] || \
     [[ "$test_exit" -eq "$TESTGATE_ALREADY_VERIFIED" ]]; then
    update_status "$project_dir" "pr_open"
  else
    update_status "$project_dir" "test_fixing"
  fi
}

# --- implementing: crash recovery if process died mid-coder ---

# Handle implementing state on a fresh tick — the coder process must have died.
_handle_implementing() {
  local project_dir="$1"
  local task_number
  task_number="$(read_state "$project_dir" "current_task")"

  log_msg "$project_dir" "WARNING" \
    "Crash recovery: found implementing state on fresh tick for task ${task_number}"
  _retry_or_diagnose "$project_dir" "$task_number" "implementing"
}

# --- test_fixing: re-run tests or spawn fix-tests agent ---

# Handle test_fixing: retest (main may have fixed it), then spawn fix-tests.
_handle_test_fixing() {
  local project_dir="$1"
  local task_number
  task_number="$(read_state "$project_dir" "current_task")"
  local pr_number
  pr_number="$(read_state "$project_dir" "pr_number")"

  # Re-run tests first — main may have been updated and fixed the issue.
  local test_exit=0
  run_test_gate "$project_dir" || test_exit=$?

  if [[ "$test_exit" -eq "$TESTGATE_PASS" ]] || \
     [[ "$test_exit" -eq "$TESTGATE_SKIP" ]] || \
     [[ "$test_exit" -eq "$TESTGATE_ALREADY_VERIFIED" ]]; then
    log_msg "$project_dir" "INFO" "Tests pass now for task ${task_number}"
    reset_test_fix_retries "$project_dir"
    update_status "$project_dir" "pr_open"
    return
  fi

  # Check test fix retry budget.
  local test_fix_retries
  test_fix_retries="$(get_test_fix_retries "$project_dir")"
  local max_test_fix="${AUTOPILOT_MAX_TEST_FIX_RETRIES:-3}"

  if [[ "$test_fix_retries" -ge "$max_test_fix" ]]; then
    log_msg "$project_dir" "ERROR" \
      "Test fix retries exhausted (${test_fix_retries}/${max_test_fix}) for task ${task_number}"
    _retry_or_diagnose "$project_dir" "$task_number" "test_fixing"
    return
  fi

  # Spawn fix-tests agent via postfix module.
  # Note: run_postfix_verification increments test_fix_retries internally.
  local postfix_exit=0
  run_postfix_verification "$project_dir" "$task_number" \
    "$pr_number" "" >/dev/null 2>&1 || postfix_exit=$?

  if [[ "$postfix_exit" -eq "$POSTFIX_PASS" ]]; then
    reset_test_fix_retries "$project_dir"
    update_status "$project_dir" "pr_open"
  fi
  # Stay in test_fixing if still failing — next tick will retry.
}

# --- pr_open: waiting for reviewer cron (no-op in dispatcher) ---

# Handle pr_open: reviewer cron handles this state, dispatcher is a no-op.
_handle_pr_open() {
  local project_dir="$1"
  log_msg "$project_dir" "DEBUG" "Waiting for review (pr_open)"
}

# --- reviewed: check for clean reviews, spawn fixer if needed ---

# Handle reviewed: skip fixer on clean reviews, otherwise spawn fixer.
_handle_reviewed() {
  local project_dir="$1"
  local task_number
  task_number="$(read_state "$project_dir" "current_task")"
  local pr_number
  pr_number="$(read_state "$project_dir" "pr_number")"

  # Check if all reviews were clean (no issues found).
  if _all_reviews_clean_from_json "$project_dir" "$pr_number"; then
    log_msg "$project_dir" "INFO" \
      "All reviews clean for task ${task_number} — skipping fixer"
    update_status "$project_dir" "fixed"
    return
  fi

  # Record SHA before fixer for push verification.
  local branch_name
  branch_name="$(build_branch_name "$task_number")"
  local sha_before
  sha_before="$(fetch_remote_sha "$project_dir" "$branch_name")"
  write_state "$project_dir" "sha_before_fix" "$sha_before"

  update_status "$project_dir" "fixing"

  # Spawn fixer agent (blocking).
  run_fixer "$project_dir" "$task_number" "$pr_number" \
    >/dev/null 2>&1 || true

  _handle_fixer_result "$project_dir" "$task_number" "$pr_number"
}

# Process fixer result: verify push, run tests.
_handle_fixer_result() {
  local project_dir="$1"
  local task_number="$2"
  local pr_number="$3"

  local sha_before
  sha_before="$(read_state "$project_dir" "sha_before_fix")"
  local branch_name
  branch_name="$(build_branch_name "$task_number")"

  # Verify fixer pushed.
  if ! verify_fixer_push "$project_dir" "$branch_name" "$sha_before"; then
    log_msg "$project_dir" "WARNING" \
      "Fixer did not push for task ${task_number}"
  fi

  # Run post-fix verification (tests).
  local postfix_exit=0
  run_postfix_verification "$project_dir" "$task_number" \
    "$pr_number" "$sha_before" >/dev/null 2>&1 || postfix_exit=$?

  if [[ "$postfix_exit" -eq "$POSTFIX_PASS" ]]; then
    update_status "$project_dir" "fixed"
  else
    # Tests still failing — check if test fix retries are exhausted.
    local test_fix_retries
    test_fix_retries="$(get_test_fix_retries "$project_dir")"
    local max_test_fix="${AUTOPILOT_MAX_TEST_FIX_RETRIES:-3}"
    if [[ "$test_fix_retries" -ge "$max_test_fix" ]]; then
      _retry_or_diagnose "$project_dir" "$task_number" "fixing"
    else
      update_status "$project_dir" "reviewed"
    fi
  fi
}

# --- fixing: crash recovery if process died mid-fixer ---

# Handle fixing state on a fresh tick — the fixer process must have died.
_handle_fixing() {
  local project_dir="$1"
  local task_number
  task_number="$(read_state "$project_dir" "current_task")"

  log_msg "$project_dir" "WARNING" \
    "Crash recovery: found fixing state on fresh tick for task ${task_number}"
  _retry_or_diagnose "$project_dir" "$task_number" "fixing"
}

# --- fixed: tests pass, spawn merger ---

# Handle fixed: spawn merger for final review.
_handle_fixed() {
  local project_dir="$1"
  local task_number
  task_number="$(read_state "$project_dir" "current_task")"
  local pr_number
  pr_number="$(read_state "$project_dir" "pr_number")"

  # Extract task description for merger context.
  local tasks_file
  tasks_file="$(detect_tasks_file "$project_dir")" || true
  local task_description=""
  if [[ -n "$tasks_file" ]]; then
    task_description="$(extract_task "$tasks_file" "$task_number")" || true
  fi

  update_status "$project_dir" "merging"

  record_phase_transition "$project_dir" "fixed"

  # Spawn merger agent (blocking).
  local merger_exit=0
  run_merger "$project_dir" "$task_number" "$pr_number" \
    "$task_description" || merger_exit=$?

  _handle_merger_result "$project_dir" "$task_number" \
    "$pr_number" "$merger_exit"
}

# --- merging: merger running, with crash recovery ---

# Handle merging state: check if merger process crashed (stale lock).
_handle_merging() {
  local project_dir="$1"
  local task_number
  task_number="$(read_state "$project_dir" "current_task")"

  # Crash recovery: if we're in merging state on a new tick, the merger
  # process must have died (stale lock cleared, new tick acquired lock).
  log_msg "$project_dir" "WARNING" \
    "Crash recovery: found merging state on fresh tick for task ${task_number}"
  _retry_or_diagnose "$project_dir" "$task_number" "merging"
}

# Process merger verdict: merge on approve, write hints on reject.
_handle_merger_result() {
  local project_dir="$1"
  local task_number="$2"
  local pr_number="$3"
  local merger_exit="$4"

  case "$merger_exit" in
    "$MERGER_APPROVE")
      log_msg "$project_dir" "INFO" \
        "PR #${pr_number} merged for task ${task_number}"
      update_status "$project_dir" "merged"
      ;;
    "$MERGER_REJECT")
      log_msg "$project_dir" "WARNING" \
        "Merger rejected PR #${pr_number} — feeding diagnosis to next fixer"
      update_status "$project_dir" "reviewed"
      ;;
    *)
      log_msg "$project_dir" "ERROR" \
        "Merger error for PR #${pr_number} (exit=${merger_exit})"
      _retry_or_diagnose "$project_dir" "$task_number" "merging"
      ;;
  esac
}
