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

# --- Session Resume ---

# Look up a session ID from a Claude JSON output file.
_extract_session_id() {
  local json_file="$1"

  [[ -f "$json_file" ]] || return 1

  local session_id
  session_id="$(jq -r '.session_id // empty' "$json_file" 2>/dev/null)"
  if [[ -n "$session_id" ]]; then
    echo "$session_id"
    return 0
  fi

  return 1
}

# Resolve a session ID for resuming. Lookup chain: fixer → coder → cold.
_resolve_session_id() {
  local project_dir="${1:-.}"
  local task_number="$2"
  local log_dir="${project_dir}/.autopilot/logs"

  local fixer_json="${log_dir}/fixer-task-${task_number}.json"
  local coder_json="${log_dir}/coder-task-${task_number}.json"

  # Try fixer output first (subsequent fix iterations).
  local session_id
  session_id="$(_extract_session_id "$fixer_json")" && {
    echo "${session_id}:fixer"
    return 0
  }

  # Try coder output (first fix after coding).
  session_id="$(_extract_session_id "$coder_json")" && {
    echo "${session_id}:coder"
    return 0
  }

  # Cold start — no session to resume.
  return 1
}

# --- Prompt Construction ---

# Build the user prompt for the fixer agent.
build_fixer_prompt() {
  local pr_number="$1"
  local branch_name="$2"
  local review_text="$3"
  local repo="$4"
  local diagnosis_hints="${5:-}"

  local hints_section=""
  if [[ -n "$diagnosis_hints" ]]; then
    hints_section="
## Diagnosis from Previous Attempt

${diagnosis_hints}

---
"
  fi

  cat <<EOF
## PR #${pr_number} — Review Feedback

**Branch:** \`${branch_name}\`
**Repository:** \`${repo}\`
**PR Number:** ${pr_number}
${hints_section}
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

  local timeout_fixer="${AUTOPILOT_TIMEOUT_FIXER:-900}"
  local config_dir="${AUTOPILOT_CODER_CONFIG_DIR:-}"

  # Auth pre-check with fallback before spawning.
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

  # Build user prompt.
  local user_prompt
  user_prompt="$(build_fixer_prompt "$pr_number" "$branch_name" \
    "$review_text" "$repo" "$diagnosis_hints")"

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
    _run_agent_with_hooks "$project_dir" "$config_dir" "Fixer" \
    "$task_number" "$timeout_fixer" "$user_prompt" \
    "${extra_args[@]}")" || exit_code=$?

  # Save output as fixer JSON for session resume on next iteration.
  _save_fixer_output "$project_dir" "$task_number" "$output_file"

  echo "$output_file"
  return "$exit_code"
}

# Save fixer output for future session resume lookups.
_save_fixer_output() {
  local project_dir="$1"
  local task_number="$2"
  local output_file="$3"
  local log_dir="${project_dir}/.autopilot/logs"

  mkdir -p "$log_dir"

  local target="${log_dir}/fixer-task-${task_number}.json"
  if [[ -f "$output_file" ]]; then
    cp -f "$output_file" "$target"
  fi
}
