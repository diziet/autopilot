#!/usr/bin/env bash
# PR discussion fetching and truncation for merger and fixer agents.
# Provides shared functions to fetch issue-level comments with timestamps
# and truncate large comment volumes.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_DISCUSSION_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_DISCUSSION_LOADED=1

# shellcheck source=lib/config.sh
source "${BASH_SOURCE[0]%/*}/config.sh"
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"
# shellcheck source=lib/git-ops.sh
source "${BASH_SOURCE[0]%/*}/git-ops.sh"
# shellcheck source=lib/gh.sh
source "${BASH_SOURCE[0]%/*}/gh.sh"

# Maximum number of lines before truncation.
readonly _DISCUSSION_MAX_LINES=2000

# --- PR Discussion Fetching ---

# Fetch issue-level comments on a PR with timestamps.
fetch_pr_discussion() {
  local project_dir="${1:-.}"
  local pr_number="$2"
  local since="${3:-}"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"

  local repo
  repo="$(get_repo_slug "$project_dir")" || {
    log_msg "$project_dir" "ERROR" \
      "Could not determine repo slug for PR #${pr_number} discussion"
    return 1
  }

  local jq_filter
  if [[ -n "$since" ]]; then
    # Filter comments created after the given ISO 8601 timestamp.
    # Single quotes intentional: jq interpolation, not bash.
    # shellcheck disable=SC2016
    jq_filter='.[] | select(.created_at > "'"$since"'") | "**\(.user.login)** (\(.created_at)):\n\(.body)\n"'
  else
    # No timestamp filter — return all comments.
    # shellcheck disable=SC2016
    jq_filter='.[] | "**\(.user.login)** (\(.created_at)):\n\(.body)\n"'
  fi

  _run_with_stderr_capture "$project_dir" --level WARNING \
    timeout "$timeout_gh" gh api --paginate \
    "repos/${repo}/issues/${pr_number}/comments" \
    --jq "$jq_filter" || true
}

# Truncate discussion text to max lines, keeping the most recent comments.
truncate_discussion() {
  local text="$1"
  local max_lines="${2:-$_DISCUSSION_MAX_LINES}"
  local project_dir="${3:-.}"

  [[ -z "$text" ]] && return 0

  local line_count
  line_count="$(wc -l <<< "$text" | tr -d ' ')"

  if [[ "$line_count" -le "$max_lines" ]]; then
    echo "$text"
    return 0
  fi

  log_msg "$project_dir" "WARNING" \
    "PR discussion truncated from ${line_count} to ${max_lines} lines (older comments omitted)"

  echo "*(Older comments truncated — showing most recent ${max_lines} lines)*"
  echo ""
  echo "$text" | tail -n "$max_lines"
}
