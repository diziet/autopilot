#!/usr/bin/env bash
# Merger agent for Autopilot.
# Performs final merge review using Claude, parses APPROVE/REJECT verdict,
# merges an approved PR through lib/merge-pr.sh, and writes diagnosis hints
# for the next fixer cycle on rejection.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_MERGER_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_MERGER_LOADED=1

# Source dependencies.
# shellcheck source=lib/config.sh
source "${BASH_SOURCE[0]%/*}/config.sh"
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"
# shellcheck source=lib/claude.sh
source "${BASH_SOURCE[0]%/*}/claude.sh"
# shellcheck source=lib/git-ops.sh
source "${BASH_SOURCE[0]%/*}/git-ops.sh"
# shellcheck source=lib/discussion.sh
source "${BASH_SOURCE[0]%/*}/discussion.sh"
# shellcheck source=lib/gh.sh
source "${BASH_SOURCE[0]%/*}/gh.sh"
# shellcheck source=lib/merger-prompt.sh
source "${BASH_SOURCE[0]%/*}/merger-prompt.sh"
# shellcheck source=lib/merge-pr.sh
source "${BASH_SOURCE[0]%/*}/merge-pr.sh"

# Directory where prompts/ lives (relative to this script's location).
_MERGER_LIB_DIR="${BASH_SOURCE[0]%/*}"
_MERGER_PROMPTS_DIR="${_MERGER_LIB_DIR}/../prompts"

# --- Exit Code Constants ---
readonly MERGER_APPROVE=0
readonly MERGER_REJECT=1
readonly MERGER_ERROR=2
export MERGER_APPROVE MERGER_REJECT MERGER_ERROR

# --- Verdict Parsing ---

# Extract APPROVE or REJECT verdict from Claude's response text.
# The last VERDICT line wins, in case there are several. The regex anchors the
# verdict to end of line (after optional whitespace), so "REJECTED" or
# "APPROVAL" does not match.
parse_verdict() {
  local response_text="$1"
  local line

  local last_verdict=""
  while IFS= read -r line; do
    if [[ "$line" =~ VERDICT:[[:space:]]*(APPROVE|REJECT)[[:space:]]*$ ]]; then
      last_verdict="${BASH_REMATCH[1]}"
    fi
  done <<< "$response_text"

  if [[ -n "$last_verdict" ]]; then
    echo "$last_verdict"
    return 0
  fi

  # Fail-safe: no clean VERDICT line found — caller should default to REJECT.
  return 1
}

# --- Diagnosis Hints ---

# Write diagnosis hints to disk for the next fixer cycle.
write_diagnosis_hints() {
  local project_dir="${1:-.}"
  local task_number="$2"
  local rejection_text="$3"
  local hints_file="${project_dir}/.autopilot/diagnosis-hints-task-${task_number}.md"

  mkdir -p "${project_dir}/.autopilot"
  echo "$rejection_text" > "$hints_file"
  log_msg "$project_dir" "INFO" \
    "Wrote diagnosis hints for task ${task_number}: ${hints_file}"
}

# Extract actionable feedback from a rejection response.
extract_rejection_feedback() {
  local response_text="$1"
  local feedback=""
  local line
  local found_verdict=false

  # Collect the lines after the VERDICT: REJECT line as feedback.
  while IFS= read -r line; do
    if [[ "$line" =~ VERDICT:[[:space:]]*REJECT[[:space:]]*$ ]]; then
      found_verdict=true
      continue
    fi
    if [[ "$found_verdict" == true ]]; then
      feedback="${feedback}${line}
"
    fi
  done <<< "$response_text"

  # If nothing follows the verdict, use the full response as feedback.
  local trimmed
  trimmed="$(sed '/^[[:space:]]*$/d' <<< "$feedback")"
  if [[ -z "$trimmed" ]]; then
    feedback="$response_text"
  fi

  echo "$feedback"
}

# --- Post Rejection Comment ---

# Post a rejection comment on the PR with diagnosis hints.
_post_rejection_comment() {
  local project_dir="${1:-.}"
  local pr_number="$2"
  local feedback="$3"
  local repo="$4"
  local task_number="${5:-}"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"

  if [[ -z "$repo" ]]; then
    log_msg "$project_dir" "WARNING" \
      "No repo slug for rejection comment on PR #${pr_number}"
    return 0
  fi

  # Use the model attribution from merger-task-N.json when there is one.
  # Otherwise keep the generic trailer. build_model_attribution also returns
  # nothing when no task number is given.
  local attribution="*This comment was posted by the Autopilot merger agent.*"
  local model_line
  model_line="$(build_model_attribution "$project_dir" \
    "merger" "$task_number" "Reviewed")"
  if [[ -n "$model_line" ]]; then
    attribution="$model_line"
  fi

  local comment_body
  comment_body="$(cat <<EOF
## 🔄 Merge Review — REJECTED

The merge review agent found issues that need to be addressed before this PR can be merged.

### Feedback

${feedback}

---
${attribution}
EOF
)"

  _run_gh "$project_dir" timeout "$timeout_gh" gh pr comment "$pr_number" \
    --body "$comment_body" \
    --repo "$repo" || {
    log_msg "$project_dir" "WARNING" \
      "Failed to post rejection comment on PR #${pr_number}"
  }
}

# --- Output Saving ---

# Save merger output JSON for token usage tracking.
_save_merger_output() {
  _save_agent_output "$1" "merger" "$2" "$3"
}

# --- Main Merger Execution ---

# Run the merger review for a given task.
run_merger() {
  local project_dir="${1:-.}"
  local task_number="$2"
  local pr_number="$3"
  local task_description="${4:-}"

  local timeout_merger="${AUTOPILOT_TIMEOUT_MERGER:-600}"
  local config_dir="${AUTOPILOT_REVIEWER_CONFIG_DIR:-}"

  # Auth pre-check with fallback before spawning.
  # Skipped when no config dir is set (system default — nothing to probe).
  if [[ -n "$config_dir" ]]; then
    config_dir="$(resolve_config_dir_with_fallback \
      "$config_dir" "merger" "$project_dir")" || return "$MERGER_ERROR"
  fi

  local branch_name
  branch_name="$(build_branch_name "$task_number")"

  # Resolve the repo slug once and pass it to the diff fetch, the file-list
  # fetch, the merger prompt and the rejection comment.
  local repo
  repo="$(get_repo_slug "$project_dir")" || {
    log_msg "$project_dir" "ERROR" \
      "Could not determine repo slug for merge review of PR #${pr_number}"
    return "$MERGER_ERROR"
  }

  local diff_content
  diff_content="$(_fetch_merger_diff "$project_dir" "$pr_number" "$repo")"
  if [[ -z "$diff_content" ]]; then
    log_msg "$project_dir" "ERROR" \
      "Empty diff for PR #${pr_number} — cannot perform merge review"
    return "$MERGER_ERROR"
  fi

  # Fetch the complete file list with stats, so the merger sees every changed
  # file even when the diff is truncated.
  local file_list
  file_list="$(_fetch_pr_file_list "$project_dir" "$pr_number" "$repo")"

  # Fetch PR discussion comments (issue-level comments on the PR).
  local discussion=""
  discussion="$(fetch_pr_discussion "$project_dir" "$pr_number")"
  if [[ -n "$discussion" ]]; then
    discussion="$(truncate_discussion "$discussion" "$_DISCUSSION_MAX_LINES" \
      "$project_dir")"
    log_msg "$project_dir" "INFO" \
      "Including PR discussion in merger context for PR #${pr_number}"
  fi

  local system_prompt
  system_prompt="$(_read_prompt_file "${_MERGER_PROMPTS_DIR}/merge-review.md" \
    "$project_dir")" || {
    log_msg "$project_dir" "ERROR" "Failed to read merge review prompt"
    return "$MERGER_ERROR"
  }

  local user_prompt
  user_prompt="$(build_merger_prompt "$pr_number" "$branch_name" \
    "$repo" "$diff_content" "$task_description" "$file_list" "$discussion")"

  log_msg "$project_dir" "INFO" \
    "Spawning merger review for task ${task_number}, PR #${pr_number} (timeout=${timeout_merger}s)"

  # Resolve the merger's model (per-step override > global). Bash dynamic
  # scoping makes this local visible to _build_base_cmd_args, which run_claude
  # calls in a subshell.
  local AUTOPILOT_MODEL_OVERRIDE
  # shellcheck disable=SC2034  # Read via dynamic scoping in _build_base_cmd_args
  AUTOPILOT_MODEL_OVERRIDE="$(resolve_agent_model merger)"

  local output_file exit_code=0
  output_file="$(run_claude "$timeout_merger" "$user_prompt" "$config_dir" \
    "--system-prompt" "$system_prompt")" || exit_code=$?

  _log_agent_result "$project_dir" "Merger" "$task_number" \
    "$exit_code" "$output_file" "PR #${pr_number}"

  # Save output for token usage tracking.
  _save_merger_output "$project_dir" "$task_number" "$output_file"

  # Handle Claude failure or timeout.
  if [[ "$exit_code" -ne 0 ]]; then
    log_msg "$project_dir" "ERROR" \
      "Merger agent failed for PR #${pr_number} (exit=${exit_code})"
    return "$MERGER_ERROR"
  fi

  local response_text
  response_text="$(extract_claude_text "$output_file")"
  if [[ -z "$response_text" ]]; then
    log_msg "$project_dir" "ERROR" \
      "Empty response from merger agent for PR #${pr_number}"
    return "$MERGER_ERROR"
  fi

  # Parse the verdict. Fail-safe: default to REJECT if no clean VERDICT found.
  local verdict
  verdict="$(parse_verdict "$response_text")" || {
    log_msg "$project_dir" "WARNING" \
      "No clean VERDICT line found in merger response for PR #${pr_number} — defaulting to REJECT"
    verdict="REJECT"
  }

  _handle_verdict "$project_dir" "$task_number" "$pr_number" \
    "$verdict" "$response_text" "$repo"
}

# Handle the parsed verdict (approve or reject).
_handle_verdict() {
  local project_dir="$1"
  local task_number="$2"
  local pr_number="$3"
  local verdict="$4"
  local response_text="$5"
  local repo="${6:-}"

  if [[ "$verdict" == "APPROVE" ]]; then
    log_msg "$project_dir" "INFO" \
      "Merger APPROVED PR #${pr_number} for task ${task_number}"
    squash_merge_pr "$project_dir" "$pr_number" || {
      log_msg "$project_dir" "ERROR" \
        "Merge failed despite APPROVE for PR #${pr_number}"
      return "$MERGER_ERROR"
    }
    return "$MERGER_APPROVE"
  fi

  # REJECT path.
  log_msg "$project_dir" "WARNING" \
    "Merger REJECTED PR #${pr_number} for task ${task_number}"

  local feedback
  feedback="$(extract_rejection_feedback "$response_text")"

  # Write hints for the next fixer cycle.
  write_diagnosis_hints "$project_dir" "$task_number" "$feedback"

  _post_rejection_comment "$project_dir" "$pr_number" "$feedback" "$repo" "$task_number"

  return "$MERGER_REJECT"
}
