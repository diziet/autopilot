#!/usr/bin/env bash
# Periodic spec compliance review for Autopilot.
# Compares recent merged PRs against the project specification.
# Runs every Nth task (AUTOPILOT_SPEC_REVIEW_INTERVAL). Disabled when 0.
# Uses lib/claude.sh helpers and AUTOPILOT_TIMEOUT_SPEC_REVIEW.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_SPEC_REVIEW_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_SPEC_REVIEW_LOADED=1

# Source dependencies.
# shellcheck source=lib/config.sh
source "${BASH_SOURCE[0]%/*}/config.sh"
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"
# shellcheck source=lib/claude.sh
source "${BASH_SOURCE[0]%/*}/claude.sh"
# shellcheck source=lib/git-ops.sh
source "${BASH_SOURCE[0]%/*}/git-ops.sh"
# shellcheck source=lib/tasks.sh
source "${BASH_SOURCE[0]%/*}/tasks.sh"

# Directory where prompts/ lives (relative to this script's location).
_SPEC_REVIEW_LIB_DIR="${BASH_SOURCE[0]%/*}"
_SPEC_REVIEW_PROMPTS_DIR="${_SPEC_REVIEW_LIB_DIR}/../prompts"

# --- Exit Code Constants ---
readonly SPEC_REVIEW_OK=0
readonly SPEC_REVIEW_SKIP=1
readonly SPEC_REVIEW_ERROR=2
export SPEC_REVIEW_OK SPEC_REVIEW_SKIP SPEC_REVIEW_ERROR

# Max characters for GitHub issue body (prevents API failures).
readonly _SPEC_REVIEW_MAX_BODY_LENGTH=60000

# Max bytes for spec file content in prompt.
readonly _SPEC_REVIEW_MAX_SPEC_BYTES=8000

# Max bytes for combined diff in prompt.
readonly _SPEC_REVIEW_MAX_DIFF_BYTES=50000

# Number of recent merged PRs to compare against spec.
readonly _SPEC_REVIEW_PR_COUNT=5

# --- Interval Check ---

# Check if spec review should run for this task number.
should_run_spec_review() {
  local task_number="$1"
  local interval="${AUTOPILOT_SPEC_REVIEW_INTERVAL:-5}"

  # Disabled when interval is 0.
  if [[ "$interval" -eq 0 ]]; then
    return 1
  fi

  # Validate task number is a positive integer (tasks start at 1).
  if [[ -z "$task_number" || ! "$task_number" =~ ^[0-9]+$ || "$task_number" -eq 0 ]]; then
    return 1
  fi

  # Validate interval is a positive integer.
  if [[ ! "$interval" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  [[ $(( task_number % interval )) -eq 0 ]]
}

# --- Spec File Reading ---

# Get the spec file path from context files (first entry).
_get_spec_file() {
  local project_dir="${1:-.}"
  parse_context_files "$project_dir" | head -n 1
}

# Read spec file contents, truncated to max bytes.
_read_spec_content() {
  local spec_file="$1"
  local max_bytes="${_SPEC_REVIEW_MAX_SPEC_BYTES}"

  if [[ ! -f "$spec_file" ]]; then
    return 1
  fi

  local content
  content="$(head -c "$max_bytes" "$spec_file" 2>/dev/null)"
  if [[ -z "$content" ]]; then
    return 1
  fi

  local file_size
  file_size="$(wc -c < "$spec_file" | tr -d ' ')"
  if [[ "$file_size" -gt "$max_bytes" ]]; then
    content="${content}
... [truncated from ${file_size} to ${max_bytes} bytes]"
  fi

  echo "$content"
}

# --- PR Diff Fetching ---

# Fetch last N merged PR numbers from the repo.
_fetch_merged_prs() {
  local repo="$1"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"
  local count="${_SPEC_REVIEW_PR_COUNT}"

  local pr_numbers
  pr_numbers="$(timeout "$timeout_gh" gh pr list --repo "$repo" \
    --state merged --limit "$count" \
    --json number --jq '.[].number' 2>/dev/null)"

  if [[ -z "$pr_numbers" ]]; then
    return 1
  fi
  echo "$pr_numbers"
}

# Fetch and concatenate diffs for the given PR numbers.
_fetch_combined_diff() {
  local repo="$1"
  local pr_numbers="$2"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"
  local max_bytes="${_SPEC_REVIEW_MAX_DIFF_BYTES}"
  local combined_diff=""

  local pr_num diff
  while IFS= read -r pr_num; do
    [[ -z "$pr_num" ]] && continue
    diff="$(timeout "$timeout_gh" gh pr diff "$pr_num" \
      --repo "$repo" 2>/dev/null)" || continue
    combined_diff+="$(printf '\n--- PR #%s ---\n%s\n' "$pr_num" "$diff")"
  done <<< "$pr_numbers"

  if [[ -z "$combined_diff" ]]; then
    return 1
  fi

  # Truncate to prevent ARG_MAX issues.
  echo "${combined_diff:0:$max_bytes}"
}

# --- Prompt Construction ---

# Build the spec review prompt combining spec content and diffs.
build_spec_review_prompt() {
  local spec_content="$1"
  local combined_diff="$2"

  local system_prompt=""
  system_prompt="$(_read_prompt_file \
    "${_SPEC_REVIEW_PROMPTS_DIR}/spec-compliance.md" "." 2>/dev/null)" || true

  local prompt=""
  if [[ -n "$system_prompt" ]]; then
    prompt="${system_prompt}

---

"
  fi

  prompt="${prompt}## Project Specification

\`\`\`
${spec_content}
\`\`\`

## Combined Diff of Last ${_SPEC_REVIEW_PR_COUNT} Merged PRs

\`\`\`diff
${combined_diff}
\`\`\`

Review these implementations against the specification. Report any deviations."

  echo "$prompt"
}

# --- Issue Detection ---

# Check if the review output indicates compliance issues.
_has_issues() {
  local review_output="$1"
  [[ "$review_output" != *"VERDICT: COMPLIANT"* ]]
}

# --- Output Persistence ---

# Save review output to the logs directory.
_save_review_output() {
  local project_dir="$1"
  local task_number="$2"
  local review_output="$3"
  local log_dir="${project_dir}/.autopilot/logs"

  mkdir -p "$log_dir"
  local target="${log_dir}/spec-review-after-task-${task_number}.md"
  printf '%s\n' "$review_output" > "$target"

  log_msg "$project_dir" "INFO" \
    "Spec review output saved: ${target}"
}

# Read a previously saved spec review for a task.
read_spec_review() {
  local project_dir="${1:-.}"
  local task_number="$2"

  if [[ ! "$task_number" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  local review_file="${project_dir}/.autopilot/logs/spec-review-after-task-${task_number}.md"
  if [[ -f "$review_file" ]] && [[ -s "$review_file" ]]; then
    cat "$review_file"
  else
    return 1
  fi
}

# --- Issue Creation ---

# Build the GitHub issue body for spec review findings.
_build_issue_body() {
  local task_number="$1"
  local review_output="$2"

  cat <<EOF
## Spec Compliance Review — After Task ${task_number}

This automated review checked the last ${_SPEC_REVIEW_PR_COUNT} merged PRs against the project specification.

### Findings

${review_output}

---
*Generated by autopilot spec review*
EOF
}

# Create a GitHub issue with spec review findings.
_create_review_issue() {
  local project_dir="$1"
  local repo="$2"
  local task_number="$3"
  local review_output="$4"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"
  local max_body="${_SPEC_REVIEW_MAX_BODY_LENGTH}"

  # Sanitize: strip @mentions to prevent pings, truncate.
  review_output="${review_output//@/at-}"
  review_output="${review_output:0:$max_body}"

  local title="Spec compliance review: deviations found after task ${task_number}"
  local body
  body="$(_build_issue_body "$task_number" "$review_output")"

  # Try with label first, fall back without.
  if timeout "$timeout_gh" gh issue create --repo "$repo" \
      --title "$title" --body "$body" \
      --label "spec-review" 2>/dev/null; then
    log_msg "$project_dir" "INFO" \
      "Created spec review issue after task ${task_number}"
    return 0
  fi

  if timeout "$timeout_gh" gh issue create --repo "$repo" \
      --title "$title" --body "$body" 2>/dev/null; then
    log_msg "$project_dir" "INFO" \
      "Created spec review issue after task ${task_number} (no label)"
    return 0
  fi

  log_msg "$project_dir" "ERROR" \
    "Failed to create spec review issue after task ${task_number}"
  return 1
}

# --- Main Entry Point ---

# Run spec compliance review for the given task.
run_spec_review() {
  local project_dir="${1:-.}"
  local task_number="$2"

  # Validate task number.
  if [[ ! "$task_number" =~ ^[0-9]+$ ]]; then
    log_msg "$project_dir" "ERROR" \
      "Invalid task number for spec review: ${task_number}"
    return "$SPEC_REVIEW_ERROR"
  fi

  local timeout_spec="${AUTOPILOT_TIMEOUT_SPEC_REVIEW:-1200}"

  log_msg "$project_dir" "INFO" \
    "Starting spec review after task ${task_number}"

  # Get repo slug for gh API calls.
  local repo
  repo="$(get_repo_slug "$project_dir")" || {
    log_msg "$project_dir" "ERROR" \
      "Could not determine repo for spec review"
    return "$SPEC_REVIEW_ERROR"
  }

  # Read the spec file (first context file).
  local spec_file
  spec_file="$(_get_spec_file "$project_dir")"
  if [[ -z "$spec_file" || ! -f "$spec_file" ]]; then
    log_msg "$project_dir" "WARNING" \
      "No spec file found in context files — skipping spec review"
    return "$SPEC_REVIEW_SKIP"
  fi

  local spec_content
  spec_content="$(_read_spec_content "$spec_file")" || {
    log_msg "$project_dir" "WARNING" \
      "Spec file is empty: ${spec_file}"
    return "$SPEC_REVIEW_SKIP"
  }

  # Fetch recent merged PRs.
  local merged_prs
  merged_prs="$(_fetch_merged_prs "$repo")" || {
    log_msg "$project_dir" "WARNING" \
      "No merged PRs found for spec review"
    return "$SPEC_REVIEW_SKIP"
  }

  # Fetch combined diff.
  local combined_diff
  combined_diff="$(_fetch_combined_diff "$repo" "$merged_prs")" || {
    log_msg "$project_dir" "WARNING" \
      "Could not fetch PR diffs for spec review"
    return "$SPEC_REVIEW_SKIP"
  }

  # Build prompt and call Claude.
  local prompt
  prompt="$(build_spec_review_prompt "$spec_content" "$combined_diff")"

  local review_text
  review_text="$(_run_claude_and_extract "$timeout_spec" "$prompt")" || {
    log_msg "$project_dir" "ERROR" \
      "Spec review Claude call failed for task ${task_number}"
    return "$SPEC_REVIEW_ERROR"
  }

  if [[ -z "$review_text" ]]; then
    log_msg "$project_dir" "WARNING" \
      "Empty spec review response for task ${task_number}"
    return "$SPEC_REVIEW_ERROR"
  fi

  # Save output.
  _save_review_output "$project_dir" "$task_number" "$review_text"

  # Create issue if non-compliant.
  if _has_issues "$review_text"; then
    _create_review_issue "$project_dir" "$repo" "$task_number" \
      "$review_text" || true
  else
    log_msg "$project_dir" "INFO" \
      "Spec review: all compliant after task ${task_number}"
  fi

  log_msg "$project_dir" "INFO" \
    "Spec review completed after task ${task_number}"
  return "$SPEC_REVIEW_OK"
}
