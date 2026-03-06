#!/usr/bin/env bash
# Merger agent for Autopilot.
# Performs final merge review using Claude, parses APPROVE/REJECT verdict,
# squash-merges via `gh pr merge --squash`, and writes diagnosis hints
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
# Uses end-of-line anchor to prevent substring matches (e.g. "rejection").
parse_verdict() {
  local response_text="$1"
  local line

  # Scan all lines for the last VERDICT line (in case of duplicates).
  # Regex anchors APPROVE/REJECT to optional trailing whitespace + end-of-line
  # to prevent substring false matches (e.g. "REJECTED", "APPROVAL").
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

  # Collect lines after the VERDICT: REJECT line as feedback.
  # If nothing follows the verdict, fall back to the full response text.
  while IFS= read -r line; do
    if [[ "$line" =~ VERDICT:[[:space:]]*REJECT[[:space:]]*$ ]]; then
      found_verdict=true
      continue
    fi
    if [[ "$found_verdict" == true ]]; then
      # Lines after VERDICT: REJECT are post-verdict notes.
      feedback="${feedback}${line}
"
    fi
  done <<< "$response_text"

  # If nothing follows the verdict, use the full response as feedback.
  local trimmed
  trimmed="$(echo "$feedback" | sed '/^[[:space:]]*$/d')"
  if [[ -z "$trimmed" ]]; then
    feedback="$response_text"
  fi

  echo "$feedback"
}

# --- Prompt Construction ---

# Build the merge review prompt including PR diff and task context.
build_merger_prompt() {
  local pr_number="$1"
  local branch_name="$2"
  local repo="$3"
  local diff_content="$4"
  local task_description="${5:-}"

  local task_section=""
  if [[ -n "$task_description" ]]; then
    task_section="
## Task Description

${task_description}

---
"
  fi

  cat <<EOF
## Merge Review — PR #${pr_number}

**Repository:** \`${repo}\`
**Branch:** \`${branch_name}\`
**PR Number:** ${pr_number}
${task_section}
## Diff to Review

\`\`\`diff
${diff_content}
\`\`\`

---

Review the diff above and provide your verdict. End with exactly:
\`VERDICT: APPROVE\` or \`VERDICT: REJECT\`
EOF
}

# --- PR Diff Fetching ---

# Fetch the PR diff for merge review. Accepts a resolved repo slug.
_fetch_merger_diff() {
  local project_dir="${1:-.}"
  local pr_number="$2"
  local repo="$3"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"

  if [[ -z "$repo" ]]; then
    log_msg "$project_dir" "ERROR" "No repo slug for diff fetch on PR #${pr_number}"
    return 1
  fi

  timeout "$timeout_gh" gh pr diff "$pr_number" \
    --repo "$repo" 2>/dev/null
}

# --- Squash Merge ---

# Squash-merge a PR via gh CLI.
squash_merge_pr() {
  local project_dir="${1:-.}"
  local pr_number="$2"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"

  local repo
  repo="$(get_repo_slug "$project_dir")" || {
    log_msg "$project_dir" "ERROR" "Could not determine repo slug for merge"
    return 1
  }

  log_msg "$project_dir" "INFO" "Squash-merging PR #${pr_number} in ${repo}"

  timeout "$timeout_gh" gh pr merge "$pr_number" \
    --squash --delete-branch \
    --repo "$repo" 2>/dev/null || {
    log_msg "$project_dir" "ERROR" \
      "Failed to squash-merge PR #${pr_number}"
    return 1
  }

  log_msg "$project_dir" "INFO" "Successfully merged PR #${pr_number}"
}

# --- Post Rejection Comment ---

# Post a rejection comment on the PR with diagnosis hints.
_post_rejection_comment() {
  local project_dir="${1:-.}"
  local pr_number="$2"
  local feedback="$3"
  local repo="$4"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"

  if [[ -z "$repo" ]]; then
    log_msg "$project_dir" "WARNING" \
      "No repo slug for rejection comment on PR #${pr_number}"
    return 0
  fi

  local comment_body
  comment_body="$(cat <<EOF
## 🔄 Merge Review — REJECTED

The merge review agent found issues that need to be addressed before this PR can be merged.

### Feedback

${feedback}

---
*This comment was posted by the Autopilot merger agent.*
EOF
)"

  timeout "$timeout_gh" gh pr comment "$pr_number" \
    --body "$comment_body" \
    --repo "$repo" 2>/dev/null || {
    log_msg "$project_dir" "WARNING" \
      "Failed to post rejection comment on PR #${pr_number}"
  }
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

  # Resolve repo slug early — threaded to diff fetch, merge, and comment.
  local repo
  repo="$(get_repo_slug "$project_dir")" || {
    log_msg "$project_dir" "ERROR" \
      "Could not determine repo slug for merge review of PR #${pr_number}"
    return "$MERGER_ERROR"
  }

  # Fetch PR diff for review.
  local diff_content
  diff_content="$(_fetch_merger_diff "$project_dir" "$pr_number" "$repo")"
  if [[ -z "$diff_content" ]]; then
    log_msg "$project_dir" "ERROR" \
      "Empty diff for PR #${pr_number} — cannot perform merge review"
    return "$MERGER_ERROR"
  fi

  # Read system prompt from prompts/merge-review.md.
  local system_prompt
  system_prompt="$(_read_prompt_file "${_MERGER_PROMPTS_DIR}/merge-review.md" \
    "$project_dir")" || {
    log_msg "$project_dir" "ERROR" "Failed to read merge review prompt"
    return "$MERGER_ERROR"
  }

  # Build user prompt with diff and context.
  local user_prompt
  user_prompt="$(build_merger_prompt "$pr_number" "$branch_name" \
    "$repo" "$diff_content" "$task_description")"

  # Run Claude for the merge review.
  log_msg "$project_dir" "INFO" \
    "Spawning merger review for task ${task_number}, PR #${pr_number} (timeout=${timeout_merger}s)"

  local output_file exit_code=0
  output_file="$(run_claude "$timeout_merger" "$user_prompt" "$config_dir" \
    "--system-prompt" "$system_prompt")" || exit_code=$?

  _log_agent_result "$project_dir" "Merger" "$task_number" \
    "$exit_code" "$output_file" "PR #${pr_number}"

  # Handle Claude failure or timeout.
  if [[ "$exit_code" -ne 0 ]]; then
    log_msg "$project_dir" "ERROR" \
      "Merger agent failed for PR #${pr_number} (exit=${exit_code})"
    return "$MERGER_ERROR"
  fi

  # Extract text from Claude's JSON response.
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

  # Post rejection comment on the PR.
  _post_rejection_comment "$project_dir" "$pr_number" "$feedback" "$repo"

  return "$MERGER_REJECT"
}
