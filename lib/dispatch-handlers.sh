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

# Source test summary parsing for test count extraction.
# shellcheck source=lib/test-summary.sh
source "${BASH_SOURCE[0]%/*}/test-summary.sh"

# --- Task Content Hash Verification ---

# Compute an MD5 hash of stdin content (macOS md5, Linux md5sum fallback).
# Tries PATH lookup first, then absolute paths for minimal-PATH environments (launchd).
_compute_hash() {
  if command -v md5 >/dev/null 2>&1; then
    md5
  elif [[ -x /sbin/md5 ]]; then
    /sbin/md5
  elif command -v md5sum >/dev/null 2>&1; then
    md5sum | cut -d' ' -f1
  elif [[ -x /usr/bin/md5sum ]]; then
    /usr/bin/md5sum | cut -d' ' -f1
  else
    echo "_compute_hash: neither md5 nor md5sum found" >&2
    return 1
  fi
}

# Check if the task body has changed since branch creation. Warns on mismatch.
_check_task_content_hash() {
  local project_dir="$1"
  local task_number="$2"

  local stored_hash
  stored_hash="$(read_state "$project_dir" "task_content_hash")"
  [[ -n "$stored_hash" ]] || return 0

  local tasks_file
  tasks_file="$(detect_tasks_file "$project_dir")" || return 0

  local current_body
  current_body="$(extract_task "$tasks_file" "$task_number")" || return 0

  local current_hash
  current_hash="$(_compute_hash <<< "$current_body")"

  if [[ "$current_hash" != "$stored_hash" ]]; then
    log_msg "$project_dir" "WARNING" \
      "Task content changed since branch creation — task may have been renumbered"
  fi
}

# --- Token Usage Recording Helper ---

# Record token usage from an agent's saved output JSON. Best-effort.
_record_agent_usage() {
  local project_dir="$1"
  local task_number="$2"
  local agent_label="$3"
  local json_file="${project_dir}/.autopilot/logs/${agent_label}-task-${task_number}.json"
  record_claude_usage "$project_dir" "$task_number" "$agent_label" "$json_file"
}

# --- Branch Retry Strategy Helpers ---

# Phase A: preserve existing branch for retries 1-2. Check out and push unpushed commits.
_handle_branch_preserve() {
  local project_dir="$1"
  local task_number="$2"
  local branch_name
  branch_name="$(build_branch_name "$task_number")"

  log_msg "$project_dir" "INFO" \
    "Preserving branch ${branch_name} for retry — continuing from existing commits"

  # Resolve the effective working directory for git operations.
  local task_dir
  task_dir="$(resolve_task_dir "$project_dir" "$task_number")"

  if ! _use_worktrees; then
    # Direct mode: checkout the existing branch in project_dir.
    # Stash .autopilot/ state before checkout — it may be tracked by git and
    # the branch version could overwrite current pipeline state.
    local state_backup=""
    local state_file="${project_dir}/.autopilot/state.json"
    if [[ -f "$state_file" ]]; then
      state_backup="$(<"$state_file")"
    fi

    if ! git -C "$project_dir" checkout "$branch_name" 2>/dev/null; then
      if ! git -C "$project_dir" checkout --force "$branch_name" 2>/dev/null; then
        log_msg "$project_dir" "ERROR" \
          "Failed to checkout existing branch ${branch_name}"
        return 1
      fi
    fi

    # Restore pipeline state after checkout (may have been overwritten by git).
    if [[ -n "$state_backup" ]]; then
      echo "$state_backup" > "$state_file"
    fi
  fi

  # Push any unpushed commits so they're not lost.
  _push_unpushed_commits "$task_dir" "$branch_name"
}

# Phase B: delete existing branch and reset for retries 3+ or first attempt.
_handle_branch_reset() {
  local project_dir="$1"
  local task_number="$2"
  local retry_count="$3"

  local label="Stale"
  [[ "$retry_count" -ge 3 ]] && label="Phase B reset:"

  log_msg "$project_dir" "WARNING" \
    "${label} branch found for task ${task_number} — resetting"
  if ! delete_task_branch "$project_dir" "$task_number"; then
    log_msg "$project_dir" "ERROR" \
      "Failed to delete branch for task ${task_number} — skipping branch creation"
    return 1
  fi
}

# Push unpushed commits on the current branch to origin.
_push_unpushed_commits() {
  local project_dir="$1"
  local branch_name="$2"

  local unpushed
  unpushed="$(git -C "$project_dir" log "origin/${branch_name}..${branch_name}" \
    --oneline 2>/dev/null)" || true

  if [[ -n "$unpushed" ]]; then
    log_msg "$project_dir" "INFO" \
      "Pushing unpushed commits on ${branch_name} before retry"
    push_branch "$project_dir" 2>/dev/null || {
      log_msg "$project_dir" "WARNING" \
        "Failed to push unpushed commits on ${branch_name} — continuing anyway"
    }
  fi
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

  # Branch handling: strategy depends on retry count.
  # Phase A (retries 1-2): preserve existing branch and continue from it.
  # Phase B (retries 3+): delete and start fresh.
  # First attempt (retry 0): delete stale branches.
  if task_branch_exists "$project_dir" "$task_number"; then
    if [[ "$retry_count" -ge 1 && "$retry_count" -le 2 ]]; then
      _handle_branch_preserve "$project_dir" "$task_number" || return 1
    else
      _handle_branch_reset "$project_dir" "$task_number" "$retry_count" || return 1
    fi
  fi

  # Create the task branch if it doesn't already exist.
  if ! task_branch_exists "$project_dir" "$task_number"; then
    create_task_branch "$project_dir" "$task_number" || {
      log_msg "$project_dir" "ERROR" "Failed to create branch for task ${task_number}"
      return 1
    }
  fi
  _timer_log "$project_dir" "branch setup"

  # Transition to implementing BEFORE draft PR — prevents next tick from
  # re-entering _handle_pending if draft PR creation is slow.
  # If _handle_pending exits unexpectedly after this point (before run_coder),
  # _handle_implementing → _handle_crash_recovery resets to pending on next tick.
  update_status "$project_dir" "implementing"

  # Push branch and create draft PR for early visibility (best-effort).
  _push_and_create_draft_pr "$project_dir" "$task_number"
  _timer_log "$project_dir" "draft PR"

  # Compute and store hash of the task body for change detection.
  local task_hash
  task_hash="$(_compute_hash <<< "$task_body")"
  write_state "$project_dir" "task_content_hash" "$task_hash"

  # Record task start time for metrics.
  record_task_start "$project_dir" "$task_number"

  # Read completed task summaries for context.
  local completed_summary
  completed_summary="$(read_completed_summary "$project_dir")"

  # Read retry hints for retries (Phases A and B).
  local retry_hints=""
  if [[ "$retry_count" -ge 1 ]]; then
    retry_hints="$(_read_coder_retry_hints "$project_dir" "$task_number")"
  fi

  # Resolve the effective working directory (worktree or project_dir).
  local work_dir
  work_dir="$(resolve_task_dir "$project_dir" "$task_number")"
  if [[ ! -d "$work_dir" ]]; then
    log_msg "$project_dir" "ERROR" \
      "Work directory does not exist: ${work_dir}"
    return 1
  fi

  # Spawn the coder agent (blocking — this is the long-running step).
  # run_coder saves output JSON to logs/coder-task-N.json internally
  # (for fixer session resume), so discarding stdout here is safe.
  # Stderr captured to last_error for network error detection.
  local coder_exit=0
  run_coder "$project_dir" "$task_number" "$task_body" \
    "$completed_summary" "$retry_hints" "$retry_count" "$work_dir" \
    >/dev/null 2>"$(_last_error_file "$project_dir")" || coder_exit=$?
  _timer_log "$project_dir" "coder spawn"

  # Record token usage from the coder's output JSON.
  _record_agent_usage "$project_dir" "$task_number" "coder"

  _handle_coder_result "$project_dir" "$task_number" "$coder_exit"

  # Soft pause: stop after phase completion, don't start new work.
  check_soft_pause "$project_dir"
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
  # Use worktree path — task branch is checked out there, not in project_dir.
  local task_dir
  task_dir="$(resolve_task_dir "$project_dir" "$task_number")"
  local target_branch
  target_branch="$(_resolve_checkout_target "$project_dir")"
  local has_commits
  has_commits="$(git -C "$task_dir" log "${target_branch}..HEAD" \
    --oneline 2>/dev/null | head -1)" || true

  if [[ -z "$has_commits" ]]; then
    log_msg "$project_dir" "WARNING" \
      "No commits after coder for task ${task_number} — retrying"
    _retry_or_diagnose "$project_dir" "$task_number" "implementing"
    return
  fi

  # Clean up retry hints after successful coder run.
  _clean_coder_retry_hints "$project_dir" "$task_number"

  # Push remaining commits (stop hook may have missed the last one).
  push_branch "$task_dir" 2>/dev/null || true

  # Detect existing PR (draft created pre-coder, or coder-created).
  _timer_start
  local pr_url
  pr_url="$(detect_task_pr "$project_dir" "$task_number" 2>/dev/null)" || true

  if [[ -n "$pr_url" ]]; then
    log_msg "$project_dir" "INFO" \
      "Existing PR found for task ${task_number} — skipping push/create"
  else
    # Check if draft PR number is already in state (avoids duplicate creation).
    local existing_pr
    existing_pr="$(read_state "$project_dir" "pr_number")"
    if [[ -n "$existing_pr" && "$existing_pr" != "0" ]]; then
      log_msg "$project_dir" "INFO" \
        "PR #${existing_pr} already in state for task ${task_number} — pushing only"
      push_branch "$task_dir" 2>/dev/null || true
    else
      # Pipeline is the primary owner of push + PR creation.
      pr_url="$(_pipeline_push_and_create_pr "$project_dir" "$task_number")" || true
    fi
  fi

  if [[ -z "$pr_url" ]]; then
    # Fall back to PR number from state (set during draft creation).
    local state_pr
    state_pr="$(read_state "$project_dir" "pr_number")"
    if [[ -z "$state_pr" || "$state_pr" == "0" ]]; then
      log_msg "$project_dir" "WARNING" \
        "Failed to create PR for task ${task_number} — retrying"
      _retry_or_diagnose "$project_dir" "$task_number" "implementing"
      return
    fi
  fi
  _timer_log "$project_dir" "push and PR creation"

  # Extract and store PR number from URL (or keep existing state value).
  local pr_number
  if [[ -n "$pr_url" ]]; then
    pr_number="$(_extract_pr_number "$pr_url")"
    write_state "$project_dir" "pr_number" "$pr_number"
  else
    pr_number="$(read_state "$project_dir" "pr_number")"
  fi

  # Convert draft PR to ready now that coder is done.
  # Only call if the PR was our draft (stored before coder ran).
  local draft_pr
  draft_pr="$(read_state "$project_dir" "draft_pr_number")"
  if [[ -n "$draft_pr" && "$draft_pr" == "$pr_number" ]]; then
    mark_pr_ready "$project_dir" "$pr_number" || {
      log_msg "$project_dir" "WARNING" \
        "Failed to convert draft PR #${pr_number} to ready"
    }
  fi

  # Run test gate in background (concurrent with reviewer).
  local branch_name
  branch_name="$(build_branch_name "$task_number")"
  run_test_gate_background "$project_dir" "$branch_name" >/dev/null
  _timer_log "$project_dir" "test gate launch"

  # Transition to pr_open immediately — don't wait for test gate.
  record_phase_transition "$project_dir" "implementing"
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
  local task_number pr_number
  { read -r task_number; read -r pr_number; } \
    < <(_read_task_and_pr "$project_dir")

  # Re-run tests in the task's working directory (worktree or project_dir).
  local task_dir
  task_dir="$(resolve_task_dir "$project_dir" "$task_number")"
  local test_exit=0
  run_test_gate "$task_dir" || test_exit=$?

  # Record test suite metrics (duration + counts).
  record_test_gate_metrics "$project_dir" "$task_dir" "$task_number" "$test_exit"

  if [[ "$test_exit" -eq "$TESTGATE_PASS" ]] || \
     [[ "$test_exit" -eq "$TESTGATE_SKIP" ]] || \
     [[ "$test_exit" -eq "$TESTGATE_ALREADY_VERIFIED" ]]; then
    log_msg "$project_dir" "INFO" "Tests pass now for task ${task_number}"
    reset_test_fix_retries "$project_dir"
    record_phase_transition "$project_dir" "test_fixing"
    update_status "$project_dir" "pr_open"
    _trigger_reviewer_background "$project_dir"
    return
  fi

  # Save test output so fixer/test-fixer can include it in their prompts.
  # run_test_gate writes test_gate_output.log to task_dir (which may be a worktree).
  save_task_test_output "$project_dir" "$task_number" "$task_dir" || true

  # Check test fix retry budget.
  local test_fix_retries
  test_fix_retries="$(get_test_fix_retries "$project_dir")"
  local max_test_fix="${AUTOPILOT_MAX_TEST_FIX_RETRIES:-3}"

  if [[ "$test_fix_retries" -ge "$max_test_fix" ]]; then
    log_msg "$project_dir" "ERROR" \
      "Test fix retries exhausted (${test_fix_retries}/${max_test_fix}) for task ${task_number}"
    post_test_failure_comment "$project_dir" "$pr_number" "$test_exit" "$task_dir"
    _retry_or_diagnose "$project_dir" "$task_number" "test_fixing"
    return
  fi

  # Post test failure comment before spawning fix-tests agent.
  post_test_failure_comment "$project_dir" "$pr_number" "$test_exit" "$task_dir"

  # Spawn fix-tests agent via postfix module.
  # Note: run_postfix_verification increments test_fix_retries internally.
  # Stderr captured for network error detection.
  local postfix_exit=0
  run_postfix_verification "$project_dir" "$task_number" \
    "$pr_number" "" >/dev/null 2>"$(_last_error_file "$project_dir")" || postfix_exit=$?

  if [[ "$postfix_exit" -eq "$POSTFIX_PASS" ]]; then
    reset_test_fix_retries "$project_dir"
    record_phase_transition "$project_dir" "test_fixing"
    update_status "$project_dir" "pr_open"
    _trigger_reviewer_background "$project_dir"
  fi
  # Stay in test_fixing if still failing — next tick will retry.
  # Note: no check_soft_pause here — test-fix retries are part of the
  # current task's phase, not new work. Soft pause would prevent retries
  # from ever completing.
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

  # Test gate failed or errored — save output, post comment, transition.
  local task_number pr_number
  { read -r task_number; read -r pr_number; } \
    < <(_read_task_and_pr "$project_dir")

  # Save test output so fixer/test-fixer can include it in their prompts.
  save_task_test_output "$project_dir" "$task_number" || true

  post_test_failure_comment "$project_dir" "$pr_number" "$test_result"

  log_msg "$project_dir" "WARNING" \
    "Background test gate failed (code=${test_result}) — transitioning to test_fixing"
  record_phase_transition "$project_dir" "pr_open"
  update_status "$project_dir" "test_fixing"
}

# --- reviewed: check for clean reviews, spawn fixer if needed ---

# Handle reviewed: skip fixer on clean reviews, otherwise spawn fixer.
_handle_reviewed() {
  local project_dir="$1"
  local task_number pr_number
  { read -r task_number; read -r pr_number; } \
    < <(_read_task_and_pr "$project_dir")

  # Check if all reviews were clean (no issues found).
  if _all_reviews_clean_from_json "$project_dir" "$pr_number"; then
    log_msg "$project_dir" "INFO" \
      "All reviews clean for task ${task_number} — skipping fixer"
    record_phase_transition "$project_dir" "reviewed"
    update_status "$project_dir" "fixed"
    return
  fi

  # Record SHA before fixer for push verification.
  local branch_name
  branch_name="$(build_branch_name "$task_number")"
  local sha_before
  sha_before="$(fetch_remote_sha "$project_dir" "$branch_name")"
  write_state "$project_dir" "sha_before_fix" "$sha_before"

  record_phase_transition "$project_dir" "reviewed"
  update_status "$project_dir" "fixing"

  # Verify task content hasn't changed since branch creation.
  _check_task_content_hash "$project_dir" "$task_number"

  # Resolve the effective working directory (worktree or project_dir).
  local work_dir
  work_dir="$(resolve_task_dir "$project_dir" "$task_number")"
  if [[ ! -d "$work_dir" ]]; then
    log_msg "$project_dir" "ERROR" \
      "Work directory does not exist: ${work_dir}"
    return 1
  fi

  # Spawn fixer agent (blocking). Stderr captured for network error detection.
  _timer_start
  local fixer_exit=0
  run_fixer "$project_dir" "$task_number" "$pr_number" "$work_dir" \
    >/dev/null 2>"$(_last_error_file "$project_dir")" || fixer_exit=$?
  _timer_log "$project_dir" "fixer spawn"

  # Record token usage from the fixer's output JSON.
  _record_agent_usage "$project_dir" "$task_number" "fixer"

  _handle_fixer_result "$project_dir" "$task_number" "$pr_number" "$fixer_exit"

  # Soft pause: stop after phase completion, don't start new work.
  check_soft_pause "$project_dir"
}

# Process fixer result: verify push, run post-fix tests (skipped if fixer
# produced no output).
_handle_fixer_result() {
  local project_dir="$1"
  local task_number="$2"
  local pr_number="$3"
  local fixer_exit="${4:-0}"

  local sha_before
  sha_before="$(read_state "$project_dir" "sha_before_fix")"
  local branch_name
  branch_name="$(build_branch_name "$task_number")"

  # Resolve worktree path — postfix tests write artifacts here.
  local task_dir
  task_dir="$(resolve_task_dir "$project_dir" "$task_number")"

  # Verify fixer pushed.
  _timer_start
  local fixer_pushed=true
  if ! verify_fixer_push "$project_dir" "$branch_name" "$sha_before"; then
    fixer_pushed=false
    log_msg "$project_dir" "WARNING" \
      "Fixer did not push for task ${task_number}"
  fi
  _timer_log "$project_dir" "push verification"

  # Fail-fast: skip postfix when fixer produced no commits and exited non-zero.
  if [[ "$fixer_pushed" = "false" ]] && [[ "$fixer_exit" -ne 0 ]]; then
    log_msg "$project_dir" "WARNING" \
      "Fixer produced no output — skipping postfix verification"
    # Still post fixer result comment for PR visibility. Don't pass task_dir
    # as artifact_dir — postfix never ran, so task_dir may have stale artifacts.
    post_fixer_result_comment "$project_dir" "$pr_number" \
      "$sha_before" "false" "$task_number"
    # Use main retry budget (not test_fix_retries, which is reserved for the
    # fix-tests agent inside postfix). This prevents empty fixer runs from
    # stealing retry budget from the unrelated postfix test-fix loop.
    _retry_or_diagnose "$project_dir" "$task_number" "fixing"
    return
  fi

  # Run post-fix verification (tests). Stderr captured for network error detection.
  local postfix_exit=0
  run_postfix_verification "$project_dir" "$task_number" \
    "$pr_number" "$sha_before" >/dev/null 2>"$(_last_error_file "$project_dir")" || postfix_exit=$?
  _timer_log "$project_dir" "post-fix tests"
  # Test metrics already accumulated inside run_postfix_verification.

  # Post fixer result comment on the PR.
  local is_tests_passed="false"
  [[ "$postfix_exit" -eq "$POSTFIX_PASS" ]] && is_tests_passed="true"
  post_fixer_result_comment "$project_dir" "$pr_number" \
    "$sha_before" "$is_tests_passed" "$task_number" "$task_dir"

  if [[ "$postfix_exit" -eq "$POSTFIX_PASS" ]]; then
    record_phase_transition "$project_dir" "fixing"
    update_status "$project_dir" "fixed"
  else
    # Tests still failing — check if test fix retries are exhausted.
    local test_fix_retries
    test_fix_retries="$(get_test_fix_retries "$project_dir")"
    local max_test_fix="${AUTOPILOT_MAX_TEST_FIX_RETRIES:-3}"
    if [[ "$test_fix_retries" -ge "$max_test_fix" ]]; then
      _retry_or_diagnose "$project_dir" "$task_number" "fixing"
    else
      record_phase_transition "$project_dir" "fixing"
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
  local task_number pr_number
  { read -r task_number; read -r pr_number; } \
    < <(_read_task_and_pr "$project_dir")

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

  # Soft pause: stop after phase completion, don't start new work.
  check_soft_pause "$project_dir"
}

# Run pre-merge test verification, skipping if SHA already verified.
_run_pre_merge_tests() {
  local project_dir="$1"
  local task_number="$2"

  # Resolve effective working directory (worktree path or project_dir).
  local task_dir
  task_dir="$(resolve_task_dir "$project_dir" "$task_number")"

  # If the fixer's post-fix verification already passed at this SHA, skip.
  if is_sha_verified "$task_dir"; then
    log_msg "$project_dir" "INFO" \
      "Tests already verified at current SHA — skipping pre-merge test run for task ${task_number}"
    return 0
  fi

  # SHA doesn't match or no flag — run tests before merging.
  log_msg "$project_dir" "INFO" \
    "SHA not verified — running pre-merge test gate for task ${task_number}"

  local test_exit=0
  run_test_gate "$task_dir" || test_exit=$?

  # Record test suite metrics (duration + counts).
  record_test_gate_metrics "$project_dir" "$task_dir" "$task_number" "$test_exit"

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
