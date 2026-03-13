#!/usr/bin/env bash
# Fixer agent for Autopilot.
# Spawns a Claude Code agent to address review comments on a PR.
# Supports session resume (fixer JSON → coder JSON → cold start),
# installs coder hooks, and includes merger rejection diagnosis hints.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_FIXER_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_FIXER_LOADED=1

# Source dependencies.
# shellcheck source=lib/config.sh
source "${BASH_SOURCE[0]%/*}/config.sh"
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"
# shellcheck source=lib/claude.sh
source "${BASH_SOURCE[0]%/*}/claude.sh"
# shellcheck source=lib/hooks.sh
source "${BASH_SOURCE[0]%/*}/hooks.sh"
# shellcheck source=lib/git-ops.sh
source "${BASH_SOURCE[0]%/*}/git-ops.sh"
# shellcheck source=lib/discussion.sh
source "${BASH_SOURCE[0]%/*}/discussion.sh"
# shellcheck source=lib/test-output.sh
source "${BASH_SOURCE[0]%/*}/test-output.sh"
# shellcheck source=lib/fixer-diagnostics.sh
source "${BASH_SOURCE[0]%/*}/fixer-diagnostics.sh"

# Directory where prompts/ lives (relative to this script's location).
_FIXER_LIB_DIR="${BASH_SOURCE[0]%/*}"
_FIXER_PROMPTS_DIR="${_FIXER_LIB_DIR}/../prompts"

# Note: get_repo_slug() is provided by lib/git-ops.sh.

# --- Review Comment Fetching ---

# Fetch all review comments from GitHub API for a PR.
fetch_review_comments() {
  local project_dir="${1:-.}"
  local pr_number="$2"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"

  local repo
  repo="$(get_repo_slug "$project_dir")" || {
    log_msg "$project_dir" "ERROR" "Could not determine repo slug for PR #${pr_number}"
    return 1
  }

  local output=""

  # Fetch PR review bodies (formal reviews with body text).
  local reviews
  reviews="$(_fetch_pr_reviews "$repo" "$pr_number" "$timeout_gh")"
  if [[ -n "$reviews" ]]; then
    output="${output}## Review Comments

${reviews}
"
  fi

  # Fetch inline review comments (line-level comments).
  local inline
  inline="$(_fetch_inline_comments "$repo" "$pr_number" "$timeout_gh")"
  if [[ -n "$inline" ]]; then
    output="${output}## Inline Comments

${inline}
"
  fi

  # Fetch issue-level comments (where autopilot reviewer posts).
  local issue_comments
  issue_comments="$(_fetch_issue_comments "$repo" "$pr_number" "$timeout_gh")"
  if [[ -n "$issue_comments" ]]; then
    output="${output}## Discussion

${issue_comments}
"
  fi

  echo "$output"
}

# Fetch PR reviews with non-empty bodies.
_fetch_pr_reviews() {
  local repo="$1" pr_number="$2" timeout_gh="$3"

  # Single quotes intentional: jq interpolation, not bash.
  # shellcheck disable=SC2016
  timeout "$timeout_gh" gh api --paginate "repos/${repo}/pulls/${pr_number}/reviews" \
    --jq '.[] | select(.body != "") | "**Review by \(.user.login) (\(.state)):**\n\(.body)\n"' \
    2>/dev/null || true
}

# Fetch inline (line-level) review comments.
_fetch_inline_comments() {
  local repo="$1" pr_number="$2" timeout_gh="$3"

  # Single quotes intentional: jq interpolation, not bash.
  # shellcheck disable=SC2016
  timeout "$timeout_gh" gh api --paginate "repos/${repo}/pulls/${pr_number}/comments" \
    --jq '.[] | "**\(.user.login)** on `\(.path)` line \(.line // .original_line):\n\(.body)\n"' \
    2>/dev/null || true
}

# Fetch issue-level comments on the PR.
_fetch_issue_comments() {
  local repo="$1" pr_number="$2" timeout_gh="$3"

  # Single quotes intentional: jq interpolation, not bash.
  # shellcheck disable=SC2016
  timeout "$timeout_gh" gh api --paginate "repos/${repo}/issues/${pr_number}/comments" \
    --jq '.[] | "**\(.user.login):**\n\(.body)\n"' \
    2>/dev/null || true
}

# --- Diagnosis Hints ---

# Read and delete the diagnosis hints file for a task.
consume_diagnosis_hints() {
  local project_dir="${1:-.}"
  local task_number="$2"
  local hints_file="${project_dir}/.autopilot/diagnosis-hints-task-${task_number}.md"

  if [[ -s "$hints_file" ]]; then
    cat "$hints_file"
    rm -f "$hints_file"
    log_msg "$project_dir" "INFO" "Consumed diagnosis hints for task ${task_number}"
  fi
}

# Note: _extract_session_id, _resolve_session_id, _check_session_not_found,
# and _delete_stale_session_files live in lib/fixer-diagnostics.sh.

# --- Prompt Construction ---

# Build optional context sections for the fixer prompt.
build_fixer_context_sections() {
  local diagnosis_hints="${1:-}"
  local discussion="${2:-}"
  local test_output="${3:-}"

  local sections=""

  if [[ -n "$diagnosis_hints" ]]; then
    sections="${sections}
## Diagnosis from Previous Attempt

${diagnosis_hints}

---
"
  fi

  if [[ -n "$discussion" ]]; then
    sections="${sections}
## PR Discussion

The following comments were posted on this PR. They may contain human instructions, fixer explanations, or merger feedback. Treat human-posted comments as actionable requests.

${discussion}

---
"
  fi

  if [[ -n "$test_output" ]]; then
    sections="${sections}
## Failing Tests

${_TEST_FAILURE_INSTRUCTION}

\`\`\`
${test_output}
\`\`\`

---
"
  fi

  printf '%s' "$sections"
}

# Build the user prompt for the fixer agent.
# $5 must contain pre-formatted section headers (use build_fixer_context_sections).
build_fixer_prompt() {
  local pr_number="$1"
  local branch_name="$2"
  local review_text="$3"
  local repo="$4"
  local context_sections="${5:-}"

  cat <<EOF
## PR #${pr_number} — Review Feedback

**Branch:** \`${branch_name}\`
**Repository:** \`${repo}\`
**PR Number:** ${pr_number}
${context_sections}
### Review Comments to Address

${review_text}

---

### Instructions

1. Check out the PR branch and pull latest.
2. Address each review comment with targeted fixes.
3. Only modify files related to the review feedback.
4. Run the project's test suite. Fix any failures.
5. Commit with \`fix:\` prefix and push to the existing PR branch.
6. Do NOT merge the PR.
EOF
}

# --- Fixer Execution ---

# Run the fixer agent for a given task.
run_fixer() {
  local project_dir="${1:-.}"
  local task_number="$2"
  local pr_number="$3"
  local work_dir="${4:-$project_dir}"

  local timeout_fixer="${AUTOPILOT_TIMEOUT_FIXER:-900}"
  local config_dir="${AUTOPILOT_CODER_CONFIG_DIR:-}"
  local retry_delay="${AUTOPILOT_FIXER_RETRY_DELAY:-30}"

  # Auth pre-check with fallback before spawning.
  # Skipped when no config dir is set (system default — nothing to probe).
  if [[ -n "$config_dir" ]]; then
    config_dir="$(resolve_config_dir_with_fallback \
      "$config_dir" "fixer" "$project_dir")" || return 1
  fi

  local branch_name
  branch_name="$(build_branch_name "$task_number")"

  # Fetch review comments from GitHub.
  local review_text
  review_text="$(fetch_review_comments "$project_dir" "$pr_number")"
  if [[ -z "$review_text" ]]; then
    log_msg "$project_dir" "WARNING" \
      "No review comments found for PR #${pr_number} — nothing to fix"
    review_text="No actionable review comments. Push any minor improvements if appropriate."
  fi

  # Consume diagnosis hints if present.
  local diagnosis_hints=""
  diagnosis_hints="$(consume_diagnosis_hints "$project_dir" "$task_number")"

  # Get repo slug for the prompt.
  local repo
  repo="$(get_repo_slug "$project_dir")" || repo="unknown"

  # Fetch PR discussion comments for human instructions and context.
  local discussion=""
  discussion="$(fetch_pr_discussion "$project_dir" "$pr_number")"
  if [[ -n "$discussion" ]]; then
    discussion="$(truncate_discussion "$discussion" "$_DISCUSSION_MAX_LINES" \
      "$project_dir")"
    log_msg "$project_dir" "INFO" \
      "Including PR discussion in fixer context for PR #${pr_number}"
  fi

  # Read saved test output for inclusion in fixer prompt.
  local test_output=""
  test_output="$(read_task_test_output "$project_dir" "$task_number")"
  if [[ -n "$test_output" ]]; then
    log_msg "$project_dir" "INFO" \
      "Including failing test output in fixer prompt for task ${task_number}"
  fi

  # Pre-assemble optional context sections, then build the full prompt.
  local context_sections
  context_sections="$(build_fixer_context_sections \
    "$diagnosis_hints" "$discussion" "$test_output")"

  local user_prompt
  user_prompt="$(build_fixer_prompt "$pr_number" "$branch_name" \
    "$review_text" "$repo" "$context_sections")"

  # Log prompt size for observability (wc -c for true byte count, not char count).
  local prompt_bytes
  prompt_bytes=$(printf '%s' "$user_prompt" | wc -c | tr -d ' ')
  local prompt_est_tokens=$(( prompt_bytes / 4 ))
  log_msg "$project_dir" "INFO" \
    "METRICS: fixer prompt size ~${prompt_bytes} bytes (${prompt_est_tokens} est. tokens)"

  # Health check: validate prompt and config dir before spawning.
  _fixer_health_check "$project_dir" "$user_prompt" "$config_dir" || return 1

  # Resolve session resume and system prompt before hooks lifecycle.
  local extra_args=()
  local resume_result session_id resume_source
  resume_result="$(_resolve_session_id "$project_dir" "$task_number")" && {
    session_id="${resume_result%:*}"
    resume_source="${resume_result##*:}"
    extra_args+=("--resume" "$session_id")
    log_msg "$project_dir" "INFO" \
      "Fixer resuming session ${session_id} (source=${resume_source})"
  }

  # On cold start, add the system prompt.
  if [[ ${#extra_args[@]} -eq 0 ]]; then
    local system_prompt
    system_prompt="$(_read_prompt_file "${_FIXER_PROMPTS_DIR}/fix-and-merge.md" "$project_dir")" || {
      log_msg "$project_dir" "ERROR" "Failed to read fixer prompt"
      return 1
    }
    extra_args+=("--system-prompt" "$system_prompt")
    log_msg "$project_dir" "INFO" \
      "Fixer cold start for task ${task_number}, PR #${pr_number}"
  fi

  # Delegate to shared agent lifecycle helper.
  local output_file exit_code=0
  output_file="$(_AGENT_EXTRA_CONTEXT="PR #${pr_number}" \
    _AGENT_WORK_DIR="$work_dir" \
    _run_agent_with_hooks "$project_dir" "$config_dir" "Fixer" \
    "$task_number" "$timeout_fixer" "$user_prompt" \
    "${extra_args[@]}")" || exit_code=$?

  # Fallback: if resume failed because session doesn't exist, retry as cold start.
  if [[ "$exit_code" -ne 0 ]] && [[ -n "${session_id:-}" ]]; then
    local output_size
    output_size="$(_get_file_size "$output_file")"
    if [[ "$output_size" -eq 0 ]] \
        && _check_session_not_found "${output_file}.err"; then
      log_msg "$project_dir" "WARNING" \
        "Session ${session_id} not found — falling back to cold start"
      _delete_stale_session_files "$project_dir" "$task_number"

      # Rebuild extra_args with system prompt instead of --resume.
      local system_prompt
      system_prompt="$(_read_prompt_file \
        "${_FIXER_PROMPTS_DIR}/fix-and-merge.md" "$project_dir")" || {
        log_msg "$project_dir" "ERROR" "Failed to read fixer prompt for fallback"
        echo "$output_file"
        return "$exit_code"
      }
      extra_args=("--system-prompt" "$system_prompt")

      # Clean up the failed attempt's output files (after prompt read succeeds,
      # so the error path above still returns a valid file path).
      rm -f "$output_file" "${output_file}.err"

      # Re-run as cold start — does not consume a retry count.
      exit_code=0
      output_file="$(_AGENT_EXTRA_CONTEXT="PR #${pr_number}" \
        _AGENT_WORK_DIR="$work_dir" \
        _run_agent_with_hooks "$project_dir" "$config_dir" "Fixer" \
        "$task_number" "$timeout_fixer" "$user_prompt" \
        "${extra_args[@]}")" || exit_code=$?
    fi
  fi

  # Post-fixer diagnostics: log exit code, output size, JSON validity.
  _log_fixer_diagnostics "$project_dir" "$task_number" "$exit_code" "$output_file"

  # Preserve stderr to logs when fixer produced 0 output.
  _preserve_fixer_stderr "$project_dir" "$task_number" "$output_file"

  # Retry backoff: if fixer produced 0 output, delay before next attempt.
  _fixer_empty_output_backoff "$project_dir" "$output_file" "$retry_delay"

  # Save output as fixer JSON for session resume on next iteration.
  _save_fixer_output "$project_dir" "$task_number" "$output_file"

  echo "$output_file"
  return "$exit_code"
}

# Save fixer output for future session resume lookups.
_save_fixer_output() {
  _save_agent_output "$1" "fixer" "$2" "$3"
}
