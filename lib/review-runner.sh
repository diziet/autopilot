#!/usr/bin/env bash
# Review runner for Autopilot — cron and standalone review orchestration.
# Provides _run_cron_review (detects pr_open, runs full cycle) and
# _run_standalone_review (ad-hoc review of any PR by number).

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_REVIEW_RUNNER_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_REVIEW_RUNNER_LOADED=1

# Source dependencies.
# shellcheck source=lib/config.sh
source "${BASH_SOURCE[0]%/*}/config.sh"
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"
# shellcheck source=lib/claude.sh
source "${BASH_SOURCE[0]%/*}/claude.sh"
# shellcheck source=lib/reviewer.sh
source "${BASH_SOURCE[0]%/*}/reviewer.sh"
# shellcheck source=lib/reviewer-posting.sh
source "${BASH_SOURCE[0]%/*}/reviewer-posting.sh"
# shellcheck source=lib/git-ops.sh
source "${BASH_SOURCE[0]%/*}/git-ops.sh"
# shellcheck source=lib/metrics.sh
source "${BASH_SOURCE[0]%/*}/metrics.sh"
# shellcheck source=lib/codex-reviewer.sh
source "${BASH_SOURCE[0]%/*}/codex-reviewer.sh"
# shellcheck source=lib/diff-reduction.sh
source "${BASH_SOURCE[0]%/*}/diff-reduction.sh"

# Exit code constants for the review runner.
readonly REVIEW_OK=0
readonly REVIEW_SKIP=1
readonly REVIEW_ERROR=2

# --- Cron Mode ---

# Run a cron review cycle: detect pr_open state, run reviewers, post comments.
_run_cron_review() {
  local project_dir="$1"

  # Only act when the pipeline is in pr_open state.
  local status
  status="$(read_state "$project_dir" "status")"
  if [[ "$status" != "pr_open" ]]; then
    log_msg "$project_dir" "DEBUG" \
      "Review cron: state is '${status}', not pr_open — skipping"
    return "$REVIEW_SKIP"
  fi

  # Check reviewer retry limit before attempting review.
  if _is_reviewer_paused "$project_dir"; then
    return "$REVIEW_ERROR"
  fi

  local pr_number
  pr_number="$(read_state "$project_dir" "pr_number")"
  if [[ -z "$pr_number" ]] || [[ "$pr_number" == "0" ]]; then
    log_msg "$project_dir" "ERROR" \
      "Review cron: pr_open state but no pr_number in state.json"
    _track_reviewer_failure "$project_dir"
    return "$REVIEW_ERROR"
  fi

  # Auth pre-check with fallback before spawning reviewer agents.
  if ! _check_reviewer_auth "$project_dir"; then
    _track_reviewer_failure "$project_dir"
    return "$REVIEW_ERROR"
  fi

  log_msg "$project_dir" "INFO" \
    "Review cron: running review cycle for PR #${pr_number}"

  local review_rc=0
  _execute_review_cycle "$project_dir" "$pr_number" "cron" || review_rc=$?

  if [[ "$review_rc" -eq "$REVIEW_OK" ]]; then
    reset_reviewer_retries "$project_dir"
    clear_reviewer_cooldown "$project_dir"
  else
    _track_reviewer_failure "$project_dir"
  fi

  return "$review_rc"
}

# --- Standalone Mode ---

# Run an ad-hoc review of a specific PR by number.
_run_standalone_review() {
  local project_dir="$1"
  local pr_number="$2"

  # Validate PR number is numeric.
  if [[ ! "$pr_number" =~ ^[0-9]+$ ]]; then
    log_msg "$project_dir" "ERROR" \
      "Standalone review: invalid PR number '${pr_number}'"
    return "$REVIEW_ERROR"
  fi

  # Auth pre-check with fallback before spawning reviewer agents.
  if ! _check_reviewer_auth "$project_dir"; then
    return "$REVIEW_ERROR"
  fi

  log_msg "$project_dir" "INFO" \
    "Standalone review: running review for PR #${pr_number}"

  _execute_review_cycle "$project_dir" "$pr_number" "standalone"
}

# --- Review Cycle ---

# Execute the full review cycle: fetch diff, run reviewers, post comments.
_execute_review_cycle() {
  local project_dir="$1"
  local pr_number="$2"
  local mode="$3"

  # Fetch PR diff.
  # Contract: fetch_pr_diff writes the diff file path to stdout even on exit 3
  # (oversized). Command substitution captures stdout before || handles the code.
  local diff_file exit_code=0
  diff_file="$(fetch_pr_diff "$project_dir" "$pr_number")" || exit_code=$?

  if [[ "$exit_code" -eq 3 ]]; then
    # Oversized diff — run diff-reduction reviewer only.
    log_msg "$project_dir" "INFO" \
      "Review: diff oversized for PR #${pr_number} — running diff-reduction reviewer"
    _run_diff_reduction_review "$project_dir" "$pr_number" "$diff_file" "$mode"
    return $?
  elif [[ "$exit_code" -ne 0 ]]; then
    log_msg "$project_dir" "ERROR" \
      "Review: failed to fetch diff for PR #${pr_number}"
    _transition_on_error "$project_dir" "$mode"
    return "$REVIEW_ERROR"
  fi

  # Get the current head SHA for dedup tracking.
  local head_sha
  head_sha="$(_get_pr_head_sha "$project_dir" "$pr_number")" || true
  if [[ -z "$head_sha" ]]; then
    log_msg "$project_dir" "WARNING" \
      "Review: could not determine head SHA for PR #${pr_number} — using placeholder"
    head_sha="unknown"
  fi

  # Extract task description for reviewer context (skipped in standalone mode).
  # In standalone mode, current_task may not match the PR being reviewed,
  # so we skip to avoid giving reviewers the wrong task context.
  local task_description=""
  if [[ "$mode" != "standalone" ]]; then
    local task_number
    task_number="$(read_state "$project_dir" "current_task")" || true
    local tasks_file
    tasks_file="$(detect_tasks_file "$project_dir")" || true
    if [[ -n "$tasks_file" ]] && [[ -n "$task_number" ]]; then
      task_description="$(extract_task "$tasks_file" "$task_number")" || true
    fi
  fi

  # Run all configured reviewers in parallel.
  local result_dir
  result_dir="$(run_reviewers "$project_dir" "$pr_number" "$diff_file" \
    "$task_description")" || {
    log_msg "$project_dir" "ERROR" \
      "Review: reviewer execution failed for PR #${pr_number}"
    _cleanup_diff_file "$diff_file"
    _transition_on_error "$project_dir" "$mode"
    return "$REVIEW_ERROR"
  }

  # Record token usage for each reviewer persona.
  _record_reviewer_usage "$project_dir" "$result_dir"

  # Post review comments (handles dedup, clean detection).
  post_review_comments "$project_dir" "$pr_number" "$head_sha" "$result_dir" || {
    log_msg "$project_dir" "ERROR" \
      "Review: failed to post comments for PR #${pr_number}"
    _cleanup_diff_file "$diff_file"
    _cleanup_result_dir "$result_dir"
    _transition_on_error "$project_dir" "$mode"
    return "$REVIEW_ERROR"
  }

  # Run Codex review if configured (separate from Claude persona reviews).
  _run_codex_if_configured "$project_dir" "$pr_number" "$diff_file" "$head_sha"

  # Transition state: cron mode moves to reviewed, standalone does nothing.
  _transition_after_review "$project_dir" "$mode"

  # Clean up temp files.
  _cleanup_diff_file "$diff_file"
  _cleanup_result_dir "$result_dir"

  log_msg "$project_dir" "INFO" \
    "Review complete for PR #${pr_number} (mode=${mode})"
  return "$REVIEW_OK"
}

# --- State Transitions ---

# Transition pipeline state after a successful review (cron mode only).
_transition_after_review() {
  local project_dir="$1"
  local mode="$2"

  # Only cron mode modifies pipeline state.
  [[ "$mode" != "cron" ]] && return 0

  local current_status
  current_status="$(read_state "$project_dir" "status")"
  if [[ "$current_status" == "pr_open" ]]; then
    update_status "$project_dir" "reviewed"
  fi
}

# Handle state transition on error (cron mode only).
_transition_on_error() {
  local project_dir="$1"
  local mode="$2"

  # Standalone mode doesn't touch pipeline state.
  [[ "$mode" != "cron" ]] && return 0

  # On error, stay in pr_open — next tick will retry.
  log_msg "$project_dir" "DEBUG" \
    "Review error: staying in pr_open for retry"
}

# --- PR SHA Helpers ---

# Get the head SHA for a PR via gh API.
_get_pr_head_sha() {
  local project_dir="$1"
  local pr_number="$2"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"

  local repo
  repo="$(get_repo_slug "$project_dir")" || return 1

  local sha
  sha="$(timeout "$timeout_gh" gh pr view "$pr_number" \
    --repo "$repo" --json headRefOid --jq '.headRefOid' 2>/dev/null)" || return 1

  echo "$sha"
}

# --- Reviewer Auth Pre-Check ---

# Check reviewer Claude auth with fallback. Sets AUTOPILOT_REVIEWER_CONFIG_DIR.
_check_reviewer_auth() {
  local project_dir="$1"
  local config_dir="${AUTOPILOT_REVIEWER_CONFIG_DIR:-}"

  # Skip auth check if no config dir is configured (system default — nothing to probe).
  if [[ -z "$config_dir" ]]; then
    return 0
  fi

  local resolved_dir
  resolved_dir="$(resolve_config_dir_with_fallback \
    "$config_dir" "reviewer" "$project_dir")" || return 1

  # Update config dir if fallback was used.
  AUTOPILOT_REVIEWER_CONFIG_DIR="$resolved_dir"
  return 0
}

# --- Reviewer Retry / Backoff ---

# Phase 1 cooldown durations in seconds: 15s, 30s, 1m, 2m, 4m.
readonly _REVIEWER_PHASE1_DURATIONS=(15 30 60 120 240)

# Check if reviewer is in cooldown and should skip this tick.
_is_reviewer_paused() {
  local project_dir="$1"

  if is_in_reviewer_cooldown "$project_dir"; then
    log_msg "$project_dir" "DEBUG" \
      "Reviewer in cooldown — skipping this tick"
    return 0
  fi
  return 1
}

# Compute the cooldown duration for the current retry count.
_compute_reviewer_cooldown() {
  local retry_count="$1"
  local phase1_len="${#_REVIEWER_PHASE1_DURATIONS[@]}"

  if [[ "$retry_count" -lt "$phase1_len" ]]; then
    # Phase 1: fixed exponential schedule.
    echo "${_REVIEWER_PHASE1_DURATIONS[$retry_count]}"
  else
    # Phase 2: 5m, 10m, 15m, 20m, ... (adding 5m each time, no cap).
    local phase2_index=$(( retry_count - phase1_len ))
    echo $(( (phase2_index + 1) * 300 ))
  fi
}

# Track a reviewer failure: increment retry count and set cooldown.
_track_reviewer_failure() {
  local project_dir="$1"
  local retry_count
  retry_count="$(get_reviewer_retries "$project_dir")"
  local phase1_len="${#_REVIEWER_PHASE1_DURATIONS[@]}"

  # Log CRITICAL at Phase 1 → Phase 2 boundary.
  if [[ "$retry_count" -eq "$phase1_len" ]]; then
    log_msg "$project_dir" "CRITICAL" \
      "Reviewer: Phase 1 retries exhausted after ${retry_count} failures — entering Phase 2 (slow retries)"
  fi

  local cooldown_secs
  cooldown_secs="$(_compute_reviewer_cooldown "$retry_count")"
  local now
  now="$(date +%s)"
  local until_epoch=$(( now + cooldown_secs ))

  set_reviewer_cooldown_until "$project_dir" "$until_epoch"
  increment_reviewer_retries "$project_dir"

  log_msg "$project_dir" "WARNING" \
    "Reviewer failure #$(( retry_count + 1 )): cooldown ${cooldown_secs}s"
}

# --- Token Usage Recording ---

# Record token usage for each reviewer persona from result directory.
_record_reviewer_usage() {
  local project_dir="$1"
  local result_dir="$2"
  local task_number
  task_number="$(read_state "$project_dir" "current_task")" || return 0

  collect_review_results "$result_dir"

  local i
  for (( i=0; i<${#_REVIEW_PERSONAS[@]}; i++ )); do
    if [[ "${_REVIEW_EXITS[$i]}" -eq 0 && -f "${_REVIEW_FILES[$i]}" ]]; then
      record_claude_usage "$project_dir" "$task_number" \
        "reviewer-${_REVIEW_PERSONAS[$i]}" "${_REVIEW_FILES[$i]}"
      _save_agent_output "$project_dir" \
        "reviewer-${_REVIEW_PERSONAS[$i]}" "$task_number" "${_REVIEW_FILES[$i]}"
    fi
  done
}

# --- Codex Integration ---

# Run Codex review if "codex" is in the configured reviewer list.
_run_codex_if_configured() {
  local project_dir="$1"
  local pr_number="$2"
  local diff_file="$3"
  local commit_sha="$4"
  local timeout_codex="${AUTOPILOT_TIMEOUT_CODEX:-450}"

  is_codex_configured || return 0

  log_msg "$project_dir" "INFO" \
    "Running Codex review for PR #${pr_number}"

  run_codex_review_pipeline "$project_dir" "$pr_number" "$diff_file" \
    "$commit_sha" "$timeout_codex" || {
    log_msg "$project_dir" "WARNING" \
      "Codex review failed or unavailable for PR #${pr_number} — continuing"
  }
}

# --- Cleanup Helpers ---

# Remove the temporary diff file.
_cleanup_diff_file() {
  local diff_file="$1"
  if [[ -n "$diff_file" ]] && [[ -f "$diff_file" ]]; then
    rm -f "$diff_file"
  fi
}

# Remove the temporary result directory.
_cleanup_result_dir() {
  local result_dir="$1"
  if [[ -n "$result_dir" ]] && [[ -d "$result_dir" ]]; then
    rm -rf "$result_dir"
  fi
}
