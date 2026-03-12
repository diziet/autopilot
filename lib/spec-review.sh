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
# shellcheck source=lib/metrics.sh
source "${BASH_SOURCE[0]%/*}/metrics.sh"

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
readonly _SPEC_REVIEW_MAX_SPEC_BYTES=50000

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

# Get the spec file path from context files or tasks file fallback.
# Outputs two lines: line 1 = file path, line 2 = source ("context-files" or "tasks-file").
# Outputs nothing when no spec file is found.
_get_spec_file() {
  local project_dir="${1:-.}"

  # Try context files first.
  local spec_file
  spec_file="$(parse_context_files "$project_dir" | head -n 1)"
  if [[ -n "$spec_file" ]]; then
    printf '%s\n%s\n' "$spec_file" "context-files"
    return 0
  fi

  # Fall back to auto-detected tasks file.
  spec_file="$(detect_tasks_file "$project_dir")" || true
  if [[ -n "$spec_file" ]]; then
    printf '%s\n%s\n' "$spec_file" "tasks-file"
    return 0
  fi

  return 0
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
    local _pr_section
    printf -v _pr_section '\n--- PR #%s ---\n%s\n' "$pr_num" "$diff"
    combined_diff+="$_pr_section"
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

# Source issue creation module.
# shellcheck source=lib/spec-review-issue.sh
source "${BASH_SOURCE[0]%/*}/spec-review-issue.sh"

# --- Claude Invocation ---

# Log tail of a file for diagnosis, if it exists and is non-empty.
_log_file_tail() {
  local project_dir="$1" level="$2" label="$3" filepath="$4"
  local content=""
  [[ -f "$filepath" ]] || return 0
  content="$(tail -n 20 "$filepath" 2>/dev/null)" || true
  [[ -n "$content" ]] && log_msg "$project_dir" "$level" "${label}: ${content}"
}

# Run Claude for spec review and extract text response.
# Logs stderr and raw output on failure for diagnosis.
_run_spec_review_claude() {
  local project_dir="$1" task_number="$2" timeout_spec="$3"
  local prompt="$4" config_dir="$5"

  log_msg "$project_dir" "INFO" \
    "Spec review: invoking Claude for task ${task_number} (timeout=${timeout_spec}s)"

  local output_file exit_code=0
  local -a claude_args=("$timeout_spec" "$prompt")
  if [[ -n "$config_dir" ]]; then
    claude_args+=("$config_dir")
  fi
  output_file="$(run_claude "${claude_args[@]}")" || exit_code=$?

  log_msg "$project_dir" "INFO" \
    "Spec review: Claude call returned for task ${task_number} (exit=${exit_code})"

  record_claude_usage "$project_dir" "$task_number" "spec-review" \
    "$output_file" || true

  if [[ "$exit_code" -ne 0 ]]; then
    log_msg "$project_dir" "ERROR" \
      "Spec review Claude call failed for task ${task_number} (exit=${exit_code})"
    _log_file_tail "$project_dir" "ERROR" "Spec review stderr" "${output_file}.err"
    rm -f "$output_file" "${output_file}.err"
    return 1
  fi

  local review_text
  review_text="$(extract_claude_text "$output_file")" || true

  if [[ -z "$review_text" ]]; then
    log_msg "$project_dir" "WARNING" \
      "Empty spec review response for task ${task_number}"
    _log_file_tail "$project_dir" "WARNING" "Spec review raw output" "$output_file"
  fi

  rm -f "$output_file" "${output_file}.err"

  if [[ -z "$review_text" ]]; then
    return 1
  fi

  printf '%s\n' "$review_text"
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

  # Resolve config dir with auth fallback (same pattern as coder/reviewer).
  # Ambient auth (no config dir) is intentionally unsupported — spec review
  # requires an explicit config dir to avoid silent auth failures in background.
  local config_dir="${AUTOPILOT_SPEC_REVIEW_CONFIG_DIR:-${AUTOPILOT_CODER_CONFIG_DIR:-}}"
  if [[ -z "$config_dir" ]]; then
    log_msg "$project_dir" "WARNING" \
      "No config dir set for spec review (AUTOPILOT_SPEC_REVIEW_CONFIG_DIR and AUTOPILOT_CODER_CONFIG_DIR both empty) — skipping"
    return "$SPEC_REVIEW_SKIP"
  fi
  config_dir="$(resolve_config_dir_with_fallback \
    "$config_dir" "spec-review" "$project_dir")" || {
    log_msg "$project_dir" "ERROR" \
      "Auth failed for spec review — skipping"
    return "$SPEC_REVIEW_ERROR"
  }

  # Get repo slug for gh API calls.
  local repo
  repo="$(get_repo_slug "$project_dir")" || {
    log_msg "$project_dir" "ERROR" \
      "Could not determine repo for spec review"
    return "$SPEC_REVIEW_ERROR"
  }

  # Read the spec file (context files first, then tasks file fallback).
  local spec_output spec_file spec_source
  spec_output="$(_get_spec_file "$project_dir")"
  { read -r spec_file; read -r spec_source; } <<< "$spec_output"
  if [[ -z "$spec_file" || ! -f "$spec_file" ]]; then
    log_msg "$project_dir" "WARNING" \
      "No spec file found in context files or tasks file — skipping spec review"
    return "$SPEC_REVIEW_SKIP"
  fi

  log_msg "$project_dir" "INFO" \
    "SPEC_REVIEW: using ${spec_file} as spec (source: ${spec_source})"

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

  # Run Claude and extract review text (logs errors internally).
  local review_text
  review_text="$(_run_spec_review_claude "$project_dir" "$task_number" \
    "$timeout_spec" "$prompt" "$config_dir")" || {
    return "$SPEC_REVIEW_ERROR"
  }

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

# Source async execution module.
# shellcheck source=lib/spec-review-async.sh
source "${BASH_SOURCE[0]%/*}/spec-review-async.sh"
