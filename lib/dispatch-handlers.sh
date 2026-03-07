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

# Source timer instrumentation for sub-step timing.
# shellcheck source=lib/timer.sh
source "${BASH_SOURCE[0]%/*}/timer.sh"

# Source PR status comment posting.
# shellcheck source=lib/pr-comments.sh
source "${BASH_SOURCE[0]%/*}/pr-comments.sh"

# --- Token Usage Recording Helper ---

# Record token usage from an agent's saved output JSON. Best-effort.
_record_agent_usage() {
  local project_dir="$1"
  local task_number="$2"
  local agent_label="$3"
  local json_file="${project_dir}/.autopilot/logs/${agent_label}-task-${task_number}.json"
  record_claude_usage "$project_dir" "$task_number" "$agent_label" "$json_file"
}

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
    _timer_start
    run_preflight "$project_dir" || return 1
    _timer_log "$project_dir" "preflight"
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
    if ! delete_task_branch "$project_dir" "$task_number"; then
      log_msg "$project_dir" "ERROR" \
        "Failed to delete stale branch for task ${task_number} — skipping branch creation"
      return 1
    fi
  fi

  # Create the task branch from target.
  create_task_branch "$project_dir" "$task_number" || {
    log_msg "$project_dir" "ERROR" "Failed to create branch for task ${task_number}"
    return 1
  }
  _timer_log "$project_dir" "branch setup"

  # Record task start time for metrics.
  record_task_start "$project_dir" "$task_number"

  # Read completed task summaries for context.
  local completed_summary
  completed_summary="$(read_completed_summary "$project_dir")"

  update_status "$project_dir" "implementing"

  # Spawn the coder agent (blocking — this is the long-running step).
  # run_coder saves output JSON to logs/coder-task-N.json internally
  # (for fixer session resume), so discarding stdout here is safe.
  local coder_exit=0
  run_coder "$project_dir" "$task_number" "$task_body" \
    "$completed_summary" >/dev/null 2>&1 || coder_exit=$?
  _timer_log "$project_dir" "coder spawn"

  # Record token usage from the coder's output JSON.
  _record_agent_usage "$project_dir" "$task_number" "coder"

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

  # Verify coder produced commits on the branch.
  local target_branch
  target_branch="$(_resolve_checkout_target "$project_dir")"
  local has_commits
  has_commits="$(git -C "$project_dir" log "${target_branch}..HEAD" \
    --oneline 2>/dev/null | head -1)" || true

  if [[ -z "$has_commits" ]]; then
    log_msg "$project_dir" "WARNING" \
      "No commits after coder for task ${task_number} — retrying"
    _retry_or_diagnose "$project_dir" "$task_number" "implementing"
    return
  fi

  # Check if coder already created a PR (detect before pushing).
  _timer_start
  local pr_url
  pr_url="$(detect_task_pr "$project_dir" "$task_number" 2>/dev/null)" || true

  if [[ -n "$pr_url" ]]; then
    log_msg "$project_dir" "INFO" \
      "Coder already created PR for task ${task_number} — skipping push/create"
  else
    # Pipeline is the primary owner of push + PR creation.
    pr_url="$(_pipeline_push_and_create_pr "$project_dir" "$task_number")" || true
  fi

  if [[ -z "$pr_url" ]]; then
    log_msg "$project_dir" "WARNING" \
      "Failed to create PR for task ${task_number} — retrying"
    _retry_or_diagnose "$project_dir" "$task_number" "implementing"
    return
  fi
  _timer_log "$project_dir" "push and PR creation"

  # Extract PR number from URL.
  local pr_number
  pr_number="$(_extract_pr_number "$pr_url")"
  write_state "$project_dir" "pr_number" "$pr_number"

  # Run test gate in background (concurrent with reviewer).
  local branch_name
  branch_name="$(build_branch_name "$task_number")"
  run_test_gate_background "$project_dir" "$branch_name" >/dev/null
  _timer_log "$project_dir" "test gate launch"

  # Transition to pr_open immediately — don't wait for test gate.
  update_status "$project_dir" "pr_open"

  # Spawn reviewer immediately (don't wait for cron tick).
  _trigger_reviewer_background "$project_dir"
}

# --- implementing: crash recovery if process died mid-coder ---

# Handle implementing state on a fresh tick — the coder process must have died.
_handle_implementing() { _handle_crash_recovery "$1" "implementing"; }

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
    _trigger_reviewer_background "$project_dir"
    return
  fi

  # Check test fix retry budget.
  local test_fix_retries
  test_fix_retries="$(get_test_fix_retries "$project_dir")"
  local max_test_fix="${AUTOPILOT_MAX_TEST_FIX_RETRIES:-3}"

  if [[ "$test_fix_retries" -ge "$max_test_fix" ]]; then
    log_msg "$project_dir" "ERROR" \
      "Test fix retries exhausted (${test_fix_retries}/${max_test_fix}) for task ${task_number}"
    post_test_failure_comment "$project_dir" "$pr_number" "$test_exit"
    _retry_or_diagnose "$project_dir" "$task_number" "test_fixing"
    return
  fi

  # Post test failure comment before spawning fix-tests agent.
  post_test_failure_comment "$project_dir" "$pr_number" "$test_exit"

  # Spawn fix-tests agent via postfix module.
  # Note: run_postfix_verification increments test_fix_retries internally.
  local postfix_exit=0
  run_postfix_verification "$project_dir" "$task_number" \
    "$pr_number" "" >/dev/null 2>&1 || postfix_exit=$?

  if [[ "$postfix_exit" -eq "$POSTFIX_PASS" ]]; then
    reset_test_fix_retries "$project_dir"
    update_status "$project_dir" "pr_open"
    _trigger_reviewer_background "$project_dir"
  fi
  # Stay in test_fixing if still failing — next tick will retry.
}

# --- pr_open: check background test gate, wait for review ---

# Handle pr_open: check if background test gate completed, act on result.
_handle_pr_open() {
  local project_dir="$1"

  # No result file yet — test gate still running.
  if ! has_test_gate_result "$project_dir"; then
    log_msg "$project_dir" "DEBUG" \
      "Background test gate still running — staying in pr_open"
    return 0
  fi

  # Result file exists — read and consume it.
  local test_result=0
  read_test_gate_result "$project_dir" || test_result=$?
  clear_test_gate_result "$project_dir"

  if [[ "$test_result" -eq "$TESTGATE_PASS" ]] || \
     [[ "$test_result" -eq "$TESTGATE_SKIP" ]] || \
     [[ "$test_result" -eq "$TESTGATE_ALREADY_VERIFIED" ]]; then
    log_msg "$project_dir" "INFO" \
      "Background test gate passed — staying in pr_open for review"
    return 0
  fi

  # Test gate failed or errored — post comment and transition to test_fixing.
  local pr_number
  pr_number="$(read_state "$project_dir" "pr_number")"
  post_test_failure_comment "$project_dir" "$pr_number" "$test_result"

  log_msg "$project_dir" "WARNING" \
    "Background test gate failed (code=${test_result}) — transitioning to test_fixing"
  update_status "$project_dir" "test_fixing"
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
  _timer_start
  run_fixer "$project_dir" "$task_number" "$pr_number" \
    >/dev/null 2>&1 || true
  _timer_log "$project_dir" "fixer spawn"

  # Record token usage from the fixer's output JSON.
  _record_agent_usage "$project_dir" "$task_number" "fixer"

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
  _timer_start
  if ! verify_fixer_push "$project_dir" "$branch_name" "$sha_before"; then
    log_msg "$project_dir" "WARNING" \
      "Fixer did not push for task ${task_number}"
  fi
  _timer_log "$project_dir" "push verification"

  # Run post-fix verification (tests).
  local postfix_exit=0
  run_postfix_verification "$project_dir" "$task_number" \
    "$pr_number" "$sha_before" >/dev/null 2>&1 || postfix_exit=$?
  _timer_log "$project_dir" "post-fix tests"

  # Post fixer result comment on the PR.
  local is_tests_passed="false"
  [[ "$postfix_exit" -eq "$POSTFIX_PASS" ]] && is_tests_passed="true"
  post_fixer_result_comment "$project_dir" "$pr_number" \
    "$sha_before" "$is_tests_passed"

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
_handle_fixing() { _handle_crash_recovery "$1" "fixing"; }

# --- fixed: tests pass, spawn merger ---

# Handle fixed: check for conflicts, verify tests, spawn merger.
_handle_fixed() {
  local project_dir="$1"
  local task_number
  task_number="$(read_state "$project_dir" "current_task")"
  local pr_number
  pr_number="$(read_state "$project_dir" "pr_number")"

  # Pre-merge conflict check and auto-rebase attempt.
  _timer_start
  if ! resolve_pre_merge_conflicts "$project_dir" "$task_number" \
    "$pr_number"; then
    log_msg "$project_dir" "WARNING" \
      "Pre-merge conflict resolution failed for task ${task_number}"
    # Clear clean-review status so fixer is forced to run on next tick.
    # Without this, _handle_reviewed would see clean reviews and skip
    # the fixer, creating an infinite fixed↔reviewed loop.
    _clear_reviewed_status "$project_dir" "$pr_number"
    update_status "$project_dir" "reviewed"
    return
  fi
  _timer_log "$project_dir" "pre-merge conflict check"

  # Pre-merge test verification: skip if fixer already verified this SHA.
  if ! _run_pre_merge_tests "$project_dir" "$task_number"; then
    return
  fi

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
  _timer_start
  local merger_exit=0
  run_merger "$project_dir" "$task_number" "$pr_number" \
    "$task_description" || merger_exit=$?
  _timer_log "$project_dir" "merger spawn"

  # Record token usage from the merger's output JSON.
  _record_agent_usage "$project_dir" "$task_number" "merger"

  _handle_merger_result "$project_dir" "$task_number" \
    "$pr_number" "$merger_exit"
}

# Run pre-merge test verification, skipping if SHA already verified.
_run_pre_merge_tests() {
  local project_dir="$1"
  local task_number="$2"

  # If the fixer's post-fix verification already passed at this SHA, skip.
  if is_sha_verified "$project_dir"; then
    log_msg "$project_dir" "INFO" \
      "Tests already verified at current SHA — skipping pre-merge test run for task ${task_number}"
    return 0
  fi

  # SHA doesn't match or no flag — run tests before merging.
  log_msg "$project_dir" "INFO" \
    "SHA not verified — running pre-merge test gate for task ${task_number}"

  local test_exit=0
  run_test_gate "$project_dir" || test_exit=$?

  case "$test_exit" in
    "$TESTGATE_PASS"|"$TESTGATE_SKIP"|"$TESTGATE_ALREADY_VERIFIED")
      return 0
      ;;
    "$TESTGATE_FAIL")
      log_msg "$project_dir" "WARNING" \
        "Pre-merge tests failed for task ${task_number} — returning to test_fixing"
      update_status "$project_dir" "test_fixing"
      return 1
      ;;
    *)
      log_msg "$project_dir" "ERROR" \
        "Pre-merge test gate error for task ${task_number}"
      _retry_or_diagnose "$project_dir" "$task_number" "fixed"
      return 1
      ;;
  esac
}

# --- merging: merger running, with crash recovery ---

# Handle merging state: check if merger process crashed (stale lock).
_handle_merging() { _handle_crash_recovery "$1" "merging"; }

# Process merger verdict: merge on approve, write hints on reject.
_handle_merger_result() {
  local project_dir="$1"
  local task_number="$2"
  local pr_number="$3"
  local merger_exit="$4"

  _timer_start
  case "$merger_exit" in
    "$MERGER_APPROVE")
      # Verify the PR was actually merged before transitioning.
      if ! _verify_pr_merged "$project_dir" "$pr_number"; then
        log_msg "$project_dir" "ERROR" \
          "Merger reported APPROVE but PR #${pr_number} is not merged — resetting to pending"
        update_status "$project_dir" "pending"
        return
      fi
      _timer_log "$project_dir" "merge verification"
      log_msg "$project_dir" "INFO" \
        "PR #${pr_number} verified merged for task ${task_number}"
      update_status "$project_dir" "merged"
      ;;
    "$MERGER_REJECT")
      _timer_log "$project_dir" "merge verification"
      log_msg "$project_dir" "WARNING" \
        "Merger rejected PR #${pr_number} — feeding diagnosis to next fixer"
      update_status "$project_dir" "reviewed"
      ;;
    *)
      _timer_log "$project_dir" "merge verification"
      log_msg "$project_dir" "ERROR" \
        "Merger error for PR #${pr_number} (exit=${merger_exit})"
      _retry_or_diagnose "$project_dir" "$task_number" "merging"
      ;;
  esac
}
