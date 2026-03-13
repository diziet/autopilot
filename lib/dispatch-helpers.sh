#!/usr/bin/env bash
# Dispatch helper functions and terminal state handlers.
# Split from dispatch-handlers.sh: _handle_merged, _handle_completed,
# retry/diagnosis logic, PR number extraction, clean review checks,
# and background reviewer triggering.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_DISPATCH_HELPERS_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_DISPATCH_HELPERS_LOADED=1

# Source timer instrumentation for sub-step timing.
# shellcheck source=lib/timer.sh
source "${BASH_SOURCE[0]%/*}/timer.sh"

# Source network error detection for retry logic.
# shellcheck source=lib/network-errors.sh
source "${BASH_SOURCE[0]%/*}/network-errors.sh"

# Source performance summary posting.
# shellcheck source=lib/perf-summary.sh
source "${BASH_SOURCE[0]%/*}/perf-summary.sh"

# Source worktree cleanup helpers.
# shellcheck source=lib/worktree-cleanup.sh
source "${BASH_SOURCE[0]%/*}/worktree-cleanup.sh"

# --- State Reading Helpers ---

# Read current_task and pr_number from state in a single jq call.
# Callers destructure with: { read -r task_number; read -r pr_number; } < <(...)
_read_task_and_pr() {
  local project_dir="$1"
  read_state_multi "$project_dir" "current_task" "pr_number"
}

# --- merged: record metrics, generate summary, advance task ---

# Handle merged: acquire finalize lock, record metrics, advance task.
_handle_merged() {
  local project_dir="$1"

  # Acquire finalize lock to prevent concurrent ticks from double-advancing.
  if ! acquire_lock "$project_dir" "finalize"; then
    log_msg "$project_dir" "WARNING" \
      "Finalize lock held by another tick — skipping _handle_merged"
    return 0
  fi

  # Guard: only proceed if status is still merged (another code path
  # may have changed the status outside the finalize lock).
  local current_status
  current_status="$(read_state "$project_dir" "status")"
  if [[ "$current_status" != "merged" ]]; then
    log_msg "$project_dir" "WARNING" \
      "Status already changed to ${current_status} — skipping duplicate finalize"
    release_lock "$project_dir" "finalize"
    return 0
  fi

  # Run finalization; release lock regardless of success or failure.
  local finalize_rc=0
  _finalize_merged_task "$project_dir" || finalize_rc=$?
  release_lock "$project_dir" "finalize"
  return "$finalize_rc"
}

# Perform the actual merged-state finalization: metrics, summary, advance.
_finalize_merged_task() {
  local project_dir="$1"
  local task_number pr_number
  { read -r task_number; read -r pr_number; } \
    < <(_read_task_and_pr "$project_dir")

  # Verify the PR was actually merged before any side effects (fail-safe).
  if ! _verify_pr_merged "$project_dir" "$pr_number"; then
    log_msg "$project_dir" "ERROR" \
      "PR #${pr_number} not verified as merged — resetting task ${task_number} to pending"
    update_status "$project_dir" "pending"
    return 0
  fi

  # Record phase transition from merging.
  record_phase_transition "$project_dir" "merging"

  # Fetch repo slug for metrics.
  local repo
  repo="$(get_repo_slug "$project_dir")" || repo=""

  # Record task completion metrics.
  _timer_start
  record_task_complete "$project_dir" "$task_number" \
    "$pr_number" "$repo" "merged" || {
    log_msg "$project_dir" "WARNING" \
      "Failed to record metrics for task ${task_number}"
  }

  # Record phase timing.
  record_phase_durations "$project_dir" "$task_number" "$pr_number" || {
    log_msg "$project_dir" "WARNING" \
      "Failed to record phase durations for task ${task_number}"
  }
  _timer_log "$project_dir" "metrics recording"

  # Generate task summary in the background (non-blocking).
  local task_title=""
  task_title="$(resolve_task_title "$project_dir" "$task_number")" || true
  generate_task_summary_bg "$project_dir" "$task_number" \
    "$pr_number" "$task_title"
  _timer_log "$project_dir" "summary generation"

  # Post performance summary in background (non-blocking).
  post_performance_summary_bg "$project_dir" "$task_number" "$pr_number"

  # Check for completion of any previous background spec review.
  check_spec_review_completion "$project_dir" || true

  # Launch spec review asynchronously if interval reached.
  if should_run_spec_review "$task_number"; then
    log_msg "$project_dir" "INFO" \
      "Launching async spec compliance review after task ${task_number}"
    run_spec_review_async "$project_dir" "$task_number" || {
      log_msg "$project_dir" "WARNING" \
        "Failed to launch async spec review for task ${task_number}"
    }
  fi

  # All data extracted — safe to remove worktree now (best-effort).
  cleanup_task_worktree "$project_dir" "$task_number" || \
    log_msg "$project_dir" "WARNING" \
      "Worktree cleanup failed for task ${task_number}"

  _advance_task "$project_dir" "$task_number"

  # Clean up stale worktrees after advancing so current_task is updated.
  cleanup_stale_worktrees "$project_dir" || \
    log_msg "$project_dir" "WARNING" \
      "Stale worktree cleanup failed after task ${task_number}"

  # Pull latest main so the next task branches from up-to-date code.
  local new_status
  new_status="$(read_state "$project_dir" "status")"
  if [[ "$new_status" == "pending" ]]; then
    _pull_main_after_merge "$project_dir"
  fi
}

# Pull latest main branch so next task branches from up-to-date code.
_pull_main_after_merge() {
  local project_dir="$1"
  local target
  target="$(_resolve_checkout_target "$project_dir")"

  if ! git -C "$project_dir" checkout "$target" 2>/dev/null; then
    log_msg "$project_dir" "WARNING" \
      "Failed to checkout ${target} after merge — next task may branch from stale code"
    return 0
  fi

  if ! git -C "$project_dir" pull --ff-only origin "$target" 2>/dev/null; then
    log_msg "$project_dir" "WARNING" \
      "Failed to pull ${target} after merge — next task may branch from stale code"
    return 0
  fi

  log_msg "$project_dir" "INFO" \
    "Pulled latest ${target} after merge — ready for next task"
}

# Advance current_task and transition to pending or completed.
_advance_task() {
  local project_dir="$1"
  local task_number="$2"

  # Guard: re-check status is still merged before advancing.
  local current_status
  current_status="$(read_state "$project_dir" "status")"
  if [[ "$current_status" != "merged" ]]; then
    log_msg "$project_dir" "WARNING" \
      "advance_task: status is ${current_status}, not merged — aborting advance"
    return 0
  fi

  local next_task=$(( task_number + 1 ))
  write_state_num "$project_dir" "current_task" "$next_task"
  reset_retry "$project_dir"
  reset_test_fix_retries "$project_dir"
  reset_fixer_retries "$project_dir"
  reset_network_retries "$project_dir"
  reset_phase_durations "$project_dir"

  # Clear per-task PR and coder state so it doesn't leak into the next task.
  write_state "$project_dir" "pr_number" ""
  write_state "$project_dir" "draft_pr_number" ""
  write_state "$project_dir" "sha_before_fix" ""
  write_state "$project_dir" "task_content_hash" ""
  write_state "$project_dir" "task_started_at" ""
  write_state "$project_dir" "reviewer_retry_count" "0"

  log_msg "$project_dir" "INFO" \
    "Task ${task_number} complete — advancing to task ${next_task}"

  # Check if all tasks are done.
  local tasks_file_check
  tasks_file_check="$(detect_tasks_file "$project_dir")" || true
  if [[ -n "$tasks_file_check" ]]; then
    local total_tasks
    total_tasks="$(count_tasks "$tasks_file_check")"
    if [[ "$next_task" -gt "$total_tasks" ]]; then
      update_status "$project_dir" "completed"
      return
    fi
  fi

  update_status "$project_dir" "pending"
}

# --- completed: terminal state ---

# Handle completed: re-scan tasks file for new tasks, resume if found.
_handle_completed() {
  local project_dir="$1"

  local current_task
  current_task="$(read_state "$project_dir" "current_task")"

  # Guard against empty or non-numeric current_task (corrupted state).
  if [[ ! "$current_task" =~ ^[0-9]+$ ]]; then
    log_msg "$project_dir" "ERROR" \
      "Invalid current_task value '${current_task}' in completed state"
    return 0
  fi

  local tasks_file
  if ! tasks_file="$(detect_tasks_file "$project_dir" 2>/dev/null)"; then
    # Distinguish missing file from detection error by checking common paths.
    if [[ -n "${AUTOPILOT_TASKS_FILE:-}" && \
          -e "${project_dir}/${AUTOPILOT_TASKS_FILE}" ]]; then
      log_msg "$project_dir" "ERROR" \
        "Tasks file exists but detect_tasks_file failed — possible permission error"
      return 0
    fi
    log_msg "$project_dir" "INFO" "Pipeline completed — all tasks done"
    return 0
  fi

  local total_tasks
  total_tasks="$(count_tasks "$tasks_file")"

  # Guard against non-numeric total_tasks (unparseable tasks file).
  if [[ ! "$total_tasks" =~ ^[0-9]+$ ]]; then
    log_msg "$project_dir" "ERROR" \
      "Invalid total_tasks value '${total_tasks}' from tasks file"
    return 0
  fi

  # Only resume if total_tasks increased beyond the high-water mark
  # recorded when the pipeline last entered completed state.
  local completed_at
  completed_at="$(read_state "$project_dir" "completed_at_total")"
  if [[ "$completed_at" =~ ^[0-9]+$ ]] \
     && [[ "$total_tasks" -le "$completed_at" ]]; then
    log_msg "$project_dir" "INFO" "Pipeline completed — all tasks done"
    return 0
  fi

  if [[ "$current_task" -le "$total_tasks" ]]; then
    log_msg "$project_dir" "INFO" \
      "New tasks detected (current=${current_task}, total=${total_tasks}) — resuming pipeline"
    update_status "$project_dir" "pending"
    return 0
  fi

  # Record high-water mark so we don't re-check the same total.
  write_state_num "$project_dir" "completed_at_total" "$total_tasks"
  log_msg "$project_dir" "INFO" "Pipeline completed — all tasks done"
}

# --- Crash Recovery / Retry Helpers ---

# Handle crash recovery for any state where the agent process died mid-run.
_handle_crash_recovery() {
  local project_dir="$1"
  local state_name="$2"
  local task_number
  task_number="$(read_state "$project_dir" "current_task")"

  log_msg "$project_dir" "WARNING" \
    "Crash recovery: found ${state_name} state on fresh tick for task ${task_number}"
  _retry_or_diagnose "$project_dir" "$task_number" "$state_name"
}

# Retry the current task or run diagnosis if retries exhausted.
_retry_or_diagnose() {
  local project_dir="$1"
  local task_number="$2"
  local current_state="$3"

  # Check if the failure was a network error before counting against budget.
  local recent_output
  recent_output="$(_get_recent_failure_output "$project_dir")"
  if _is_network_error "$recent_output"; then
    _handle_network_retry "$project_dir" "$task_number" "$current_state"
    return
  fi

  # Non-network error — reset network retry counter on any real failure.
  reset_network_retries "$project_dir"

  local retry_count
  retry_count="$(get_retry_count "$project_dir")"
  local max_retries="${AUTOPILOT_MAX_RETRIES:-5}"

  if [[ "$retry_count" -ge "$max_retries" ]]; then
    _exhaust_retries "$project_dir" "$task_number" "$current_state"
    return
  fi

  # Save failure context for the retry coder before incrementing.
  _save_coder_retry_hints "$project_dir" "$task_number"

  # Still have retries — increment and go back to pending.
  increment_retry "$project_dir"
  reset_test_fix_retries "$project_dir"

  # Transition back to pending for a fresh coder run.
  update_status "$project_dir" "pending"
}

# Handle a network error: skip retry increment, or pause if exhausted.
_handle_network_retry() {
  local project_dir="$1"
  local task_number="$2"
  local current_state="$3"
  local max_network="${AUTOPILOT_MAX_NETWORK_RETRIES:-20}"

  local net_count
  net_count="$(get_network_retries "$project_dir")"

  if [[ "$net_count" -ge "$max_network" ]]; then
    log_msg "$project_dir" "CRITICAL" \
      "Network retries exhausted (${net_count}/${max_network}) for task ${task_number} — pausing pipeline"
    echo "Network retries exhausted (${net_count}/${max_network}) for task ${task_number}" \
      > "${project_dir}/.autopilot/PAUSE"
    return
  fi

  increment_network_retries "$project_dir"
  log_msg "$project_dir" "WARNING" \
    "Network error — not counting against retry budget (task ${task_number}, state ${current_state})"

  # Transition back to pending so the next tick retries naturally.
  update_status "$project_dir" "pending"
}

# Run diagnosis and advance past a task when retries are exhausted.
_exhaust_retries() {
  local project_dir="$1"
  local task_number="$2"
  local current_state="$3"
  local max_retries="${AUTOPILOT_MAX_RETRIES:-5}"

  log_msg "$project_dir" "ERROR" \
    "Max retries (${max_retries}) reached for task ${task_number}"

  # Run failure diagnosis.
  local task_body=""
  local tasks_file
  tasks_file="$(detect_tasks_file "$project_dir" 2>/dev/null)" || true
  if [[ -n "$tasks_file" ]]; then
    task_body="$(extract_task "$tasks_file" "$task_number")" || true
  fi

  run_diagnosis "$project_dir" "$task_number" \
    "$task_body" "$current_state" >/dev/null 2>&1 || {
    log_msg "$project_dir" "WARNING" \
      "Diagnosis failed for task ${task_number}"
  }

  # Clean up worktree before advancing past the failed task (best-effort).
  cleanup_task_worktree "$project_dir" "$task_number" || \
    log_msg "$project_dir" "WARNING" \
      "Worktree cleanup failed for task ${task_number}"

  # Skip to next task after diagnosis.
  local next_task=$(( task_number + 1 ))
  write_state_num "$project_dir" "current_task" "$next_task"
  reset_retry "$project_dir"
  reset_test_fix_retries "$project_dir"
  reset_fixer_retries "$project_dir"
  reset_network_retries "$project_dir"
  reset_phase_durations "$project_dir"

  # Clear per-task PR and coder state so it doesn't leak into the next task.
  write_state "$project_dir" "pr_number" ""
  write_state "$project_dir" "draft_pr_number" ""
  write_state "$project_dir" "sha_before_fix" ""
  write_state "$project_dir" "task_content_hash" ""
  write_state "$project_dir" "task_started_at" ""
  write_state "$project_dir" "reviewer_retry_count" "0"

  # Always transition to pending — _handle_pending will detect if all
  # tasks are done and transition to completed directly.
  update_status "$project_dir" "pending"
}

# --- Coder Retry Hints ---

# Save failure context for retry coders to continue from where the previous attempt left off.
_save_coder_retry_hints() {
  local project_dir="$1"
  local task_number="$2"
  local hints_file="${project_dir}/.autopilot/logs/coder-retry-hints-task-${task_number}.md"

  mkdir -p "${project_dir}/.autopilot/logs"

  local hints=""

  # Include the last 20 lines of coder output if available.
  local coder_json="${project_dir}/.autopilot/logs/coder-task-${task_number}.json"
  if [[ -f "$coder_json" ]]; then
    local last_output
    last_output="$(tail -20 "$coder_json" 2>/dev/null)" || true
    if [[ -n "$last_output" ]]; then
      hints="${hints}### Last Coder Output (tail)
\`\`\`
${last_output}
\`\`\`

"
    fi
  fi

  # Include git log of commits already on the branch.
  # Use worktree path — task branch is checked out there, not in project_dir.
  local task_dir
  task_dir="$(resolve_task_dir "$project_dir" "$task_number" 2>/dev/null)" || {
    log_msg "$project_dir" "WARNING" \
      "Could not resolve task dir for task ${task_number} — falling back to project_dir"
    task_dir="$project_dir"
  }
  local branch_name=""
  branch_name="$(build_branch_name "$task_number" 2>/dev/null)" || true
  local target=""
  target="$(_resolve_checkout_target "$project_dir" 2>/dev/null)" || true
  local git_log=""
  if [[ -n "$branch_name" && -n "$target" ]]; then
    git_log="$(git -C "$task_dir" log "${target}..${branch_name}" \
      --oneline 2>/dev/null)" || true
  fi
  if [[ -n "$git_log" ]]; then
    hints="${hints}### Commits on Branch
\`\`\`
${git_log}
\`\`\`

"
  fi

  # Include recent error output if available.
  local recent_err
  recent_err="$(_get_recent_failure_output "$project_dir")" || true
  if [[ -n "$recent_err" ]]; then
    hints="${hints}### Error Output
\`\`\`
${recent_err}
\`\`\`
"
  fi

  if [[ -n "$hints" ]]; then
    echo "$hints" > "$hints_file"
    log_msg "$project_dir" "INFO" \
      "Saved retry hints for task ${task_number}: ${hints_file}"
  fi
}

# Read the coder retry hints file for a task (does not consume it).
_read_coder_retry_hints() {
  local project_dir="$1"
  local task_number="$2"
  local hints_file="${project_dir}/.autopilot/logs/coder-retry-hints-task-${task_number}.md"

  if [[ -s "$hints_file" ]]; then
    cat "$hints_file"
  fi
}

# Remove the coder retry hints file after a successful coder run.
_clean_coder_retry_hints() {
  local project_dir="$1"
  local task_number="$2"
  local hints_file="${project_dir}/.autopilot/logs/coder-retry-hints-task-${task_number}.md"

  if [[ -f "$hints_file" ]]; then
    rm -f "$hints_file"
    log_msg "$project_dir" "INFO" \
      "Cleaned up retry hints for task ${task_number}"
  fi
}

# --- PR Number Extraction ---

# Extract PR number from a GitHub PR URL.
_extract_pr_number() {
  local pr_url="$1"

  # Match /pull/NNN at end of URL.
  if [[ "$pr_url" =~ /pull/([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi

  # Fallback: try the last numeric segment.
  local num
  num="$(grep -oE '[0-9]+$' <<< "$pr_url")"
  if [[ -n "$num" ]]; then
    echo "$num"
    return 0
  fi

  echo "0"
  return 1
}

# --- Clean Review Detection ---

# Clear reviewed status for a PR so the fixer is forced to run.
_clear_reviewed_status() {
  local project_dir="$1"
  local pr_number="$2"
  local json_file="${project_dir}/.autopilot/reviewed.json"

  [[ -f "$json_file" ]] || return 0

  local pr_key="pr_${pr_number}"
  local updated
  updated="$(jq "del(.\"${pr_key}\")" "$json_file" 2>/dev/null)" || return 0
  echo "$updated" > "$json_file"
  log_msg "$project_dir" "INFO" \
    "Cleared reviewed status for PR #${pr_number}"
}

# --- Background Reviewer Trigger ---

# Spawn the reviewer in the background with a short delay.
_trigger_reviewer_background() {
  local project_dir="$1"
  local reviewer_account="${AUTOPILOT_REVIEWER_ACCOUNT:-}"
  local reviewer_bin
  reviewer_bin="${BASH_SOURCE[0]%/*}/../bin/autopilot-review"

  if [[ ! -x "$reviewer_bin" ]]; then
    log_msg "$project_dir" "WARNING" \
      "Reviewer binary not found at ${reviewer_bin} — skipping immediate trigger"
    return 0
  fi

  # Spawn reviewer with 3-second delay so PR metadata settles on GitHub.
  (
    sleep 3
    "$reviewer_bin" "$project_dir" ${reviewer_account:+"$reviewer_account"}
  ) &
  local reviewer_pid=$!
  disown "$reviewer_pid" 2>/dev/null || true

  log_msg "$project_dir" "INFO" \
    "Triggered reviewer in background (PID=${reviewer_pid}, 3s delay)"
}

# --- Early Draft PR Creation ---

# Count commits on current branch ahead of the base branch. Echoes the count.
# Returns 1 (failure) if git rev-list fails, so callers can distinguish
# "zero commits ahead" from "unable to count."
_count_commits_ahead() {
  local task_dir="$1"
  local base_branch
  base_branch="$(detect_default_branch "$task_dir")" || { echo "0"; return 0; }
  [[ -n "$base_branch" ]] || { echo "0"; return 0; }
  git -C "$task_dir" rev-list --count "${base_branch}..HEAD" 2>/dev/null || return 1
}

# Push branch and create a draft PR before coder spawns (best-effort).
# Stores PR number in state so fixer comments work from the start.
# Single attempt only — retries removed to avoid blocking the tick.
_push_and_create_draft_pr() {
  local project_dir="$1"
  local task_number="$2"

  local task_dir
  task_dir="$(resolve_task_dir "$project_dir" "$task_number")"

  # Skip if branch has no commits ahead of base — GitHub rejects empty PRs.
  local commits_ahead
  if ! commits_ahead="$(_count_commits_ahead "$task_dir")"; then
    log_msg "$project_dir" "WARNING" \
      "Could not count commits ahead for task ${task_number} — proceeding with push"
    commits_ahead=""
  fi
  if [[ "$commits_ahead" == "0" ]]; then
    log_msg "$project_dir" "INFO" \
      "Skipping draft PR for task ${task_number} — no commits ahead of base"
    write_state "$project_dir" "pr_number" ""
    return 0
  fi

  # Push the branch to remote (single attempt, best-effort).
  if ! _push_branch_once "$project_dir" "$task_dir" "$task_number"; then
    write_state "$project_dir" "pr_number" ""
    return 0
  fi

  # Create draft PR (single attempt, best-effort).
  local pr_number
  pr_number="$(_create_draft_pr_once "$project_dir" "$task_number")"

  if [[ -n "$pr_number" && "$pr_number" != "0" ]]; then
    write_state "$project_dir" "pr_number" "$pr_number"
    write_state "$project_dir" "draft_pr_number" "$pr_number"
    log_msg "$project_dir" "INFO" \
      "Draft PR #${pr_number} created before coder for task ${task_number}"
    return 0
  fi

  # Creation failed — defensively clear pr_number.
  write_state "$project_dir" "pr_number" ""
  log_msg "$project_dir" "WARNING" \
    "Could not create draft PR before coder — will create after"
  return 0
}

# Push branch once (no retry — avoids blocking the tick with sleep delays).
_push_branch_once() {
  local project_dir="$1"
  local task_dir="$2"
  local task_number="$3"

  log_msg "$project_dir" "INFO" \
    "Pushing branch for task ${task_number}"
  if push_branch "$task_dir" 2>/dev/null; then
    return 0
  fi

  log_msg "$project_dir" "WARNING" \
    "Push failed for task ${task_number} — draft PR skipped"
  return 1
}

# Extract and validate a PR number from a URL, echo it on success.
_try_extract_pr_number() {
  local pr_url="$1"
  [[ -n "$pr_url" ]] || return 1

  local pr_number
  pr_number="$(_extract_pr_number "$pr_url")" || pr_number=""
  if [[ -n "$pr_number" && "$pr_number" != "0" ]]; then
    echo "$pr_number"
    return 0
  fi
  return 1
}

# Detect existing PR or create a new draft, returning the URL.
_detect_or_create_draft_pr() {
  local project_dir="$1"
  local task_number="$2"

  local pr_url=""
  pr_url="$(detect_task_pr "$project_dir" "$task_number" 2>/dev/null)" || true
  if [[ -n "$pr_url" ]]; then
    echo "$pr_url"
    return 0
  fi

  create_draft_pr "$project_dir" "$task_number" 2>/dev/null || true
}

# Create draft PR once (no retry — avoids blocking the tick with sleep delays).
_create_draft_pr_once() {
  local project_dir="$1"
  local task_number="$2"

  log_msg "$project_dir" "INFO" \
    "Creating draft PR for task ${task_number}"
  local pr_url
  pr_url="$(_detect_or_create_draft_pr "$project_dir" "$task_number")"

  local pr_number
  if pr_number="$(_try_extract_pr_number "$pr_url")"; then
    echo "$pr_number"
    return 0
  fi

  log_msg "$project_dir" "WARNING" \
    "Draft PR creation failed for task ${task_number} — will create after coder"
  echo ""
  return 0
}

# --- Pipeline Push/PR Creation ---

# Push the branch and create a PR — the pipeline's primary push/PR path.
_pipeline_push_and_create_pr() {
  local project_dir="$1"
  local task_number="$2"
  local last_err
  last_err="$(_last_error_file "$project_dir")"

  # Resolve the effective working directory (worktree path or project_dir).
  local task_dir
  task_dir="$(resolve_task_dir "$project_dir" "$task_number")"

  log_msg "$project_dir" "INFO" \
    "Pipeline pushing branch and creating PR for task ${task_number}"

  # Stderr captured to last_error for network error detection.
  if ! push_branch "$task_dir" 2>"$last_err"; then
    log_msg "$project_dir" "ERROR" \
      "Pipeline failed to push branch for task ${task_number}"
    return 1
  fi

  # Resolve task heading once — used for both title and body generation.
  local task_heading
  task_heading="$(resolve_task_title "$project_dir" "$task_number")" || true

  # Generate PR title from resolved heading, falling back to commit messages.
  local pr_title=""
  if [[ -n "$task_heading" ]]; then
    pr_title="$(_parse_title_from_heading "$task_heading")" || true
  fi
  if [[ -z "$pr_title" ]]; then
    pr_title="$(_extract_pr_title "" "$task_dir")" || \
      pr_title="Task ${task_number}"
  fi

  # Generate PR body via Claude diff summary.
  local pr_body
  pr_body="$(generate_pr_body "$task_dir" "$task_number" \
    "$task_heading" 2>/dev/null)" || pr_body=""

  local pr_url
  pr_url="$(create_task_pr "$project_dir" "$task_number" \
    "$pr_title" "$pr_body" 2>"$last_err")" || {
    log_msg "$project_dir" "ERROR" \
      "Pipeline failed to create PR for task ${task_number}"
    return 1
  }

  echo "$pr_url"
}

# --- PR Merge Verification ---

# Verify that a PR was actually merged (not just closed) via gh CLI.
_verify_pr_merged() {
  local project_dir="$1"
  local pr_number="$2"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"

  local repo
  repo="$(get_repo_slug "$project_dir")" || {
    log_msg "$project_dir" "ERROR" \
      "Could not determine repo slug for merge verification of PR #${pr_number}"
    return 1
  }

  local pr_state
  pr_state="$(timeout "$timeout_gh" gh pr view "$pr_number" \
    --repo "$repo" --json state --jq '.state' 2>/dev/null)" || {
    log_msg "$project_dir" "ERROR" \
      "Failed to query PR #${pr_number} state via gh CLI"
    return 1
  }

  if [[ -z "$pr_state" ]]; then
    log_msg "$project_dir" "ERROR" \
      "Empty state response for PR #${pr_number} — cannot verify merge"
    return 1
  fi

  if [[ "$pr_state" == "MERGED" ]]; then
    return 0
  fi

  log_msg "$project_dir" "WARNING" \
    "PR #${pr_number} is not merged (state=${pr_state})"
  return 1
}

# --- Clean Review Detection ---

# Check if all reviews for a PR were clean from reviewed.json.
_all_reviews_clean_from_json() {
  local project_dir="$1"
  local pr_number="$2"
  local json_file="${project_dir}/.autopilot/reviewed.json"

  [[ -f "$json_file" ]] || return 1

  local pr_key="pr_${pr_number}"
  local json_content
  json_content="$(cat "$json_file" 2>/dev/null)" || return 1

  # Check that the PR key exists and has entries.
  local reviewer_count
  reviewer_count="$(jq -r ".\"${pr_key}\" | length // 0" \
    <<< "$json_content" 2>/dev/null)" || return 1
  [[ "$reviewer_count" -gt 0 ]] || return 1

  # Check that every reviewer's is_clean flag is true.
  local all_clean
  all_clean="$(jq -r "[.\"${pr_key}\" | to_entries[] | .value.is_clean] | all" \
    <<< "$json_content" 2>/dev/null)" || return 1
  [[ "$all_clean" == "true" ]]
}
