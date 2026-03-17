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

# Source portable MD5 hashing (_compute_hash, _resolve_md5_cmd).
# shellcheck source=lib/hash.sh
source "${BASH_SOURCE[0]%/*}/hash.sh"

# Source rebase operations for mergeable status checking.
# shellcheck source=lib/rebase.sh
source "${BASH_SOURCE[0]%/*}/rebase.sh"

# Source diff-reduction module for oversized diff re-check.
# shellcheck source=lib/diff-reduction.sh
source "${BASH_SOURCE[0]%/*}/diff-reduction.sh"

# --- Task Content Hash Verification ---

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

# Return 0 if the task has an associated PR number in state.
_has_pr() {
  local pr_number
  pr_number="$(read_state "$1" "pr_number")"
  [[ -n "$pr_number" && "$pr_number" != "0" ]]
}

# Phase B: delete existing branch and reset for retries 3+ or first attempt.
# If the branch has an open PR, reset to target ref instead of deleting
# (deleting the head ref causes GitHub to auto-close the PR).
_handle_branch_reset() {
  local project_dir="$1"
  local task_number="$2"
  local retry_count="$3"

  local label="Stale"
  [[ "$retry_count" -ge 3 ]] && label="Phase B reset:"

  # Check if there's a PR for this branch — deleting would close it.
  if _has_pr "$project_dir"; then
    local pr_number
    pr_number="$(read_state "$project_dir" "pr_number")"
    log_msg "$project_dir" "WARNING" \
      "${label} branch has open PR #${pr_number} for task ${task_number} — resetting to target instead of deleting"
    _reset_branch_to_target "$project_dir" "$task_number"
    return
  fi

  log_msg "$project_dir" "WARNING" \
    "${label} branch found for task ${task_number} — resetting"
  if ! delete_task_branch "$project_dir" "$task_number"; then
    log_msg "$project_dir" "ERROR" \
      "Failed to delete branch for task ${task_number} — skipping branch creation"
    return 1
  fi
}

# Reset a task branch to the target ref without deleting it (preserves remote ref for PR).
# Postcondition: in direct mode, the working directory is left on the task branch
# (ready for coder); in worktree mode, the worktree is reset in place.
_reset_branch_to_target() {
  local project_dir="$1"
  local task_number="$2"
  local branch_name
  branch_name="$(build_branch_name "$task_number")"
  local target
  target="$(_resolve_checkout_target "$project_dir")"

  local task_dir
  task_dir="$(resolve_task_dir "$project_dir" "$task_number")"

  if ! _use_worktrees; then
    # Direct mode: checkout the branch before resetting.
    # The branch stays checked out — _handle_pending will see it via
    # task_branch_exists and skip create_task_branch, proceeding directly.
    git -C "$project_dir" checkout "$branch_name" 2>/dev/null || {
      log_msg "$project_dir" "ERROR" \
        "Failed to checkout ${branch_name} for reset"
      return 1
    }
  fi

  # Hard-reset to target so the branch starts fresh.
  # Prefer origin/<target> for up-to-date code; fall back to local <target>.
  local reset_ref="origin/${target}"
  if ! git -C "$task_dir" rev-parse --verify "$reset_ref" >/dev/null 2>&1; then
    reset_ref="$target"
  fi
  git -C "$task_dir" reset --hard "$reset_ref" 2>/dev/null || {
    log_msg "$project_dir" "ERROR" \
      "Failed to reset ${branch_name} to ${reset_ref}"
    return 1
  }

  # Force-push to update remote ref without deleting it.
  git -C "$task_dir" push --force origin "$branch_name" 2>/dev/null || {
    log_msg "$project_dir" "ERROR" \
      "Failed to force-push reset branch ${branch_name}"
    return 1
  }
}

# Reopen a PR if it was closed (e.g. branch was deleted then recreated).
_reopen_pr_if_closed() {
  local project_dir="$1"
  _has_pr "$project_dir" || return 0

  local pr_number
  pr_number="$(read_state "$project_dir" "pr_number")"
  _ensure_pr_open "$project_dir" "$pr_number" || true
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

  # If a PR existed but was closed (e.g. branch deleted then recreated), reopen it.
  _reopen_pr_if_closed "$project_dir"

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

  # Validate existing PR is still usable before proceeding.
  if [[ -n "$pr_number" && "$pr_number" != "0" ]]; then
    local pr_check=0
    _ensure_pr_open "$project_dir" "$pr_number" || pr_check=$?
    if [[ "$pr_check" -eq 1 ]]; then
      # PR already merged externally — skip to merged state.
      log_msg "$project_dir" "INFO" \
        "PR #${pr_number} already merged — advancing to merged"
      record_phase_transition "$project_dir" "implementing"
      update_status "$project_dir" "merged"
      return
    elif [[ "$pr_check" -eq 2 ]]; then
      # PR closed and reopen failed — create a new PR.
      log_msg "$project_dir" "WARNING" \
        "PR #${pr_number} closed and cannot be reopened — creating new PR"
      write_state "$project_dir" "pr_number" "0"
      write_state "$project_dir" "draft_pr_number" ""
      pr_url="$(_pipeline_push_and_create_pr "$project_dir" "$task_number")" || true
      if [[ -n "$pr_url" ]]; then
        pr_number="$(_extract_pr_number "$pr_url")"
        write_state "$project_dir" "pr_number" "$pr_number"
      else
        log_msg "$project_dir" "WARNING" \
          "Failed to create replacement PR for task ${task_number} — retrying"
        _retry_or_diagnose "$project_dir" "$task_number" "implementing"
        return
      fi
    fi
    # pr_check=0 means PR is open — continue normally.
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

  # Verify the PR is still open before doing any work.
  local pr_number
  pr_number="$(read_state "$project_dir" "pr_number")"
  if [[ -n "$pr_number" && "$pr_number" != "0" ]]; then
    local pr_check=0
    _ensure_pr_open "$project_dir" "$pr_number" || pr_check=$?
    if [[ "$pr_check" -eq 1 ]]; then
      log_msg "$project_dir" "INFO" \
        "PR #${pr_number} already merged externally — advancing to merged"
      update_status "$project_dir" "merged"
      return 0
    fi
    # pr_check=0: open (possibly reopened). pr_check=2: reopen failed but
    # we still have a branch — continue with reviews; fixer will create a
    # new PR if needed.
  fi

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

  # Verify PR is still open before spawning fixer.
  if [[ -n "$pr_number" && "$pr_number" != "0" ]]; then
    local pr_check=0
    _ensure_pr_open "$project_dir" "$pr_number" || pr_check=$?
    if [[ "$pr_check" -eq 1 ]]; then
      log_msg "$project_dir" "INFO" \
        "PR #${pr_number} already merged externally — advancing to merged"
      update_status "$project_dir" "merged"
      return
    elif [[ "$pr_check" -eq 2 ]]; then
      # PR closed and cannot be reopened — go back to pending for fresh retry.
      log_msg "$project_dir" "WARNING" \
        "PR #${pr_number} closed and cannot be reopened — resetting to pending"
      write_state "$project_dir" "pr_number" "0"
      update_status "$project_dir" "pending"
      return
    fi
  fi

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
    reset_fixer_retries "$project_dir"
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

# Handle fixing state on a fresh tick — retry as fixer first, then fall back.
_handle_fixing() {
  local project_dir="$1"
  local task_number pr_number
  task_number="$(read_state "$project_dir" "current_task")"
  pr_number="$(read_state "$project_dir" "pr_number")"
  local max_fixer="${AUTOPILOT_MAX_FIXER_RETRIES:-1}"
  local fixer_retries
  fixer_retries="$(get_fixer_retries "$project_dir")"

  log_msg "$project_dir" "WARNING" \
    "Crash recovery: found fixing state on fresh tick for task ${task_number}"

  if [[ "$fixer_retries" -ge "$max_fixer" ]]; then
    # Fixer retries exhausted — fall back to full coder via crash recovery.
    log_msg "$project_dir" "WARNING" \
      "Fixer retries exhausted (${fixer_retries}/${max_fixer}) — falling back to full coder"
    reset_fixer_retries "$project_dir"
    _retry_or_diagnose "$project_dir" "$task_number" "fixing"
    return
  fi

  # First fixer crash — retry as fixer by going back to reviewed.
  increment_fixer_retries "$project_dir"
  log_msg "$project_dir" "INFO" \
    "Retrying as fixer (attempt $((fixer_retries + 1))/${max_fixer}) for task ${task_number}"
  _clear_reviewed_status "$project_dir" "$pr_number"
  update_status "$project_dir" "reviewed"
}

# --- Diff Reduction Helpers ---

# Check if the pipeline is in diff-reduction mode.
_is_diff_reduction_active() {
  local project_dir="$1"
  local active
  active="$(read_state "$project_dir" "diff_reduction_active")"
  [[ "$active" == "true" ]]
}

# Re-check diff size after fixer addressed diff-reduction review comments.
_handle_diff_reduction_recheck() {
  local project_dir="$1"
  local pr_number="$2"
  local max_retries="${AUTOPILOT_MAX_DIFF_REDUCTION_RETRIES:-2}"
  local retry_count
  retry_count="$(get_diff_reduction_retries "$project_dir")"

  local check_rc=0
  check_diff_still_oversized "$project_dir" "$pr_number" || check_rc=$?

  if [[ "$check_rc" -eq 2 ]]; then
    # gh failure — skip this tick, don't clear state.
    log_msg "$project_dir" "WARNING" \
      "Could not check diff size for PR #${pr_number} — will retry next tick"
    return
  fi

  if [[ "$check_rc" -eq 0 ]]; then
    # Diff still too large — check retry budget.
    if [[ "$retry_count" -ge "$max_retries" ]]; then
      log_msg "$project_dir" "CRITICAL" \
        "Diff reduction retries exhausted (${retry_count}/${max_retries}) for PR #${pr_number} — pausing"
      _create_pause_file "$project_dir" \
        "Diff reduction failed after ${retry_count} attempts. Diff still oversized."
      write_state "$project_dir" "diff_reduction_active" ""
      reset_diff_reduction_retries "$project_dir"
      return
    fi
    # Retry: go back to pr_open for another diff-reduction review cycle.
    log_msg "$project_dir" "WARNING" \
      "Diff still oversized after fix (attempt ${retry_count}/${max_retries}) — retrying diff-reduction"
    update_status "$project_dir" "pr_open"
    _trigger_reviewer_background "$project_dir"
    return
  fi

  # Diff is now under the limit — clear diff-reduction state and run normal review.
  log_msg "$project_dir" "INFO" \
    "Diff reduced successfully — transitioning to pr_open for normal review"
  write_state "$project_dir" "diff_reduction_active" ""
  reset_diff_reduction_retries "$project_dir"
  update_status "$project_dir" "pr_open"
  _trigger_reviewer_background "$project_dir"
}

# --- fixed: tests pass, spawn merger ---

# Handle fixed: check for conflicts, verify tests, spawn merger.
_handle_fixed() {
  local project_dir="$1"
  local task_number pr_number
  { read -r task_number; read -r pr_number; } \
    < <(_read_task_and_pr "$project_dir")

  # If the fixer just addressed a diff-reduction review, re-check diff size.
  if _is_diff_reduction_active "$project_dir"; then
    _handle_diff_reduction_recheck "$project_dir" "$pr_number"
    return
  fi

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

# Handle merging state: route to merge retry if in progress, else crash recovery.
_handle_merging() {
  local project_dir="$1"
  local merge_count
  merge_count="$(get_merge_retries "$project_dir")"

  if [[ "$merge_count" -gt 0 ]]; then
    # Active merge retry in progress — continue retrying, not crash recovery.
    local task_number pr_number
    task_number="$(read_state "$project_dir" "current_task")"
    pr_number="$(read_state "$project_dir" "pr_number")"
    log_msg "$project_dir" "INFO" \
      "Merge retry in progress (${merge_count} attempts) — retrying merge for PR #${pr_number}"
    _retry_merge_or_fallback "$project_dir" "$task_number" "$pr_number"
    return
  fi

  _handle_crash_recovery "$project_dir" "merging"
}

# Process merger verdict: merge on approve, write hints on reject, retry merge on error.
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
      _retry_merge_or_fallback "$project_dir" "$task_number" "$pr_number"
      ;;
  esac
}

# Retry the merge operation before falling back to _retry_or_diagnose.
_retry_merge_or_fallback() {
  local project_dir="$1"
  local task_number="$2"
  local pr_number="$3"
  local max_merge_retries="${AUTOPILOT_MAX_MERGE_RETRIES:-3}"
  local merge_retry_delay="${AUTOPILOT_MERGE_RETRY_DELAY:-5}"

  local merge_count
  merge_count="$(get_merge_retries "$project_dir")"

  if [[ "$merge_count" -ge "$max_merge_retries" ]]; then
    log_msg "$project_dir" "ERROR" \
      "Merge retries exhausted (${merge_count}/${max_merge_retries}) for PR #${pr_number} — falling back to retry_or_diagnose"
    reset_merge_retries "$project_dir"
    _retry_or_diagnose "$project_dir" "$task_number" "merging"
    return
  fi

  # Ensure the PR is still open — reopen if closed, short-circuit if merged.
  if ! _ensure_pr_open "$project_dir" "$pr_number"; then
    log_msg "$project_dir" "INFO" \
      "PR #${pr_number} already merged — skipping merge retry"
    reset_merge_retries "$project_dir"
    update_status "$project_dir" "merged"
    return
  fi

  # Wait for GitHub to compute mergeability if UNKNOWN.
  local mergeable_status
  mergeable_status="$(_wait_for_mergeable "$project_dir" "$pr_number")"

  # If PR has conflicts, attempt auto-rebase before merge.
  if [[ "$mergeable_status" == "$PR_MERGEABLE_CONFLICTING" ]]; then
    log_msg "$project_dir" "WARNING" \
      "PR #${pr_number} has conflicts — attempting auto-rebase before merge retry"
    if ! resolve_pre_merge_conflicts "$project_dir" "$task_number" "$pr_number"; then
      log_msg "$project_dir" "WARNING" \
        "Auto-rebase failed for PR #${pr_number} — skipping merge attempt"
      increment_merge_retries "$project_dir"
      update_status "$project_dir" "merging"
      return
    fi
  fi

  # Attempt the merge.
  increment_merge_retries "$project_dir"
  log_msg "$project_dir" "INFO" \
    "Retrying merge for PR #${pr_number} (attempt $((merge_count + 1))/${max_merge_retries})"

  sleep "$merge_retry_delay"

  if squash_merge_pr "$project_dir" "$pr_number"; then
    if _verify_pr_merged "$project_dir" "$pr_number"; then
      log_msg "$project_dir" "INFO" \
        "Merge retry succeeded for PR #${pr_number}"
      reset_merge_retries "$project_dir"
      update_status "$project_dir" "merged"
      return
    fi
  fi

  # Merge still failed — stay in merging state for the next tick to retry.
  log_msg "$project_dir" "WARNING" \
    "Merge retry failed for PR #${pr_number} — will retry next tick"
  update_status "$project_dir" "merging"
}

# Ensure a PR is open; reopen if closed.
# Returns 0 if PR is open (already open or successfully reopened).
# Returns 1 if PR is already merged.
# Returns 2 if PR is closed and reopen failed.
_ensure_pr_open() {
  local project_dir="$1"
  local pr_number="$2"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"

  local repo
  repo="$(get_repo_slug "$project_dir")" || {
    log_msg "$project_dir" "WARNING" \
      "Could not determine repo slug for PR state check on PR #${pr_number}"
    return 0
  }

  local pr_state
  pr_state="$(timeout "$timeout_gh" gh pr view "$pr_number" \
    --repo "$repo" --json state --jq '.state' 2>/dev/null)" || {
    log_msg "$project_dir" "WARNING" \
      "Failed to check PR state for PR #${pr_number} — proceeding optimistically"
    return 0
  }

  if [[ "$pr_state" == "MERGED" ]]; then
    log_msg "$project_dir" "INFO" \
      "PR #${pr_number} is already merged"
    return 1
  fi

  if [[ "$pr_state" == "CLOSED" ]]; then
    log_msg "$project_dir" "WARNING" \
      "PR #${pr_number} is closed — attempting to reopen"
    if timeout "$timeout_gh" gh pr reopen "$pr_number" \
      --repo "$repo" 2>/dev/null; then
      log_msg "$project_dir" "INFO" \
        "Successfully reopened PR #${pr_number}"
      return 0
    else
      log_msg "$project_dir" "ERROR" \
        "Failed to reopen PR #${pr_number} — PR is dead"
      return 2
    fi
  fi
}

# Wait for GitHub to compute mergeability when status is UNKNOWN.
# Echoes the resolved status (CLEAN, CONFLICTING, or UNKNOWN).
_wait_for_mergeable() {
  local project_dir="$1"
  local pr_number="$2"
  local max_wait="${AUTOPILOT_MERGE_WAIT_TIMEOUT:-30}"
  local poll_interval="${AUTOPILOT_MERGE_POLL_INTERVAL:-5}"

  local status
  status="$(check_pr_mergeable "$project_dir" "$pr_number")"

  if [[ "$status" != "$PR_MERGEABLE_UNKNOWN" ]]; then
    echo "$status"
    return 0
  fi

  log_msg "$project_dir" "INFO" \
    "PR #${pr_number} mergeable status is UNKNOWN — polling up to ${max_wait}s"

  local elapsed=0
  while [[ "$elapsed" -lt "$max_wait" ]]; do
    sleep "$poll_interval"
    elapsed=$(( elapsed + poll_interval ))
    status="$(check_pr_mergeable "$project_dir" "$pr_number")"
    if [[ "$status" != "$PR_MERGEABLE_UNKNOWN" ]]; then
      log_msg "$project_dir" "INFO" \
        "PR #${pr_number} mergeable status resolved to ${status} after ${elapsed}s"
      echo "$status"
      return 0
    fi
  done

  log_msg "$project_dir" "WARNING" \
    "PR #${pr_number} mergeable status still UNKNOWN after ${max_wait}s — proceeding with merge attempt"
  echo "$PR_MERGEABLE_UNKNOWN"
}
