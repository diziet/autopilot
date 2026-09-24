#!/usr/bin/env bash
# Merge review inputs for Autopilot's merger: fetch the PR diff and the
# changed-file list, and build the merge review prompt from them.
# Split from lib/merger.sh to keep files under 400 lines.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_MERGER_PROMPT_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_MERGER_PROMPT_LOADED=1

# Source dependencies.
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"
# shellcheck source=lib/gh.sh
source "${BASH_SOURCE[0]%/*}/gh.sh"

# --- Prompt Construction ---

# Build the merge review prompt including PR diff and task context.
build_merger_prompt() {
  local pr_number="$1"
  local branch_name="$2"
  local repo="$3"
  local diff_content="$4"
  local task_description="${5:-}"
  local file_list="${6:-}"
  local discussion="${7:-}"

  local task_section=""
  if [[ -n "$task_description" ]]; then
    task_section="
## Task Description

${task_description}

---
"
  fi

  local file_list_section=""
  if [[ -n "$file_list" ]]; then
    file_list_section="
## Changed Files

${file_list}

> **Note:** The file list above is complete. The diff below may be truncated for large PRs. Do not reject for missing files if they appear in the file list.

---
"
  fi

  local discussion_section=""
  if [[ -n "$discussion" ]]; then
    discussion_section="
## PR Discussion

The following comments were posted on this PR. Consider them when making your verdict — they may contain explanations for design decisions, fixer notes about why certain feedback was not actionable, or human clarifications.

${discussion}

---
"
  fi

  cat <<EOF
## Merge Review — PR #${pr_number}

**Repository:** \`${repo}\`
**Branch:** \`${branch_name}\`
**PR Number:** ${pr_number}
${task_section}${file_list_section}${discussion_section}
## Diff to Review

\`\`\`diff
${diff_content}
\`\`\`

---

Review the diff above and provide your verdict. End with exactly:
\`VERDICT: APPROVE\` or \`VERDICT: REJECT\`
EOF
}

# --- PR File List Fetching ---

# Fetch the complete file list with addition/deletion stats for a PR.
_fetch_pr_file_list() {
  local project_dir="${1:-.}"
  local pr_number="$2"
  local repo="$3"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"

  if [[ -z "$repo" ]]; then
    log_msg "$project_dir" "ERROR" "No repo slug for file list fetch on PR #${pr_number}"
    return 1
  fi

  _run_with_stderr_capture "$project_dir" --level WARNING timeout "$timeout_gh" gh api \
    "repos/${repo}/pulls/${pr_number}/files" \
    --paginate \
    --jq '.[] | "\(.filename) | +\(.additions) -\(.deletions)"' || true
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

  _run_gh "$project_dir" timeout "$timeout_gh" gh pr diff "$pr_number" \
    --repo "$repo"
}
