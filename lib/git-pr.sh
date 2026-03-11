#!/usr/bin/env bash
# PR title/body extraction, creation, and detection for Autopilot.
# Split from git-ops.sh to keep files under 400 lines.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_GIT_PR_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_GIT_PR_LOADED=1

# Source dependencies.
# shellcheck source=lib/git-ops.sh
source "${BASH_SOURCE[0]%/*}/git-ops.sh"

# --- PR Title/Body Extraction ---

# Resolve the raw heading line for a task from the tasks file.
# Returns the heading (e.g. "## Task 1: Setup scaffold") or empty string.
resolve_task_title() {
  local project_dir="${1:-.}"
  local task_number="$2"

  local tasks_file
  tasks_file="$(detect_tasks_file "$project_dir" 2>/dev/null)" || true
  [[ -z "$tasks_file" ]] && return 1

  extract_task_title "$tasks_file" "$task_number" 2>/dev/null
}

# Build a PR title from the tasks file header for a given task number.
# Returns "Task N: <title>" on success, falls back to _extract_pr_title.
build_pr_title() {
  local project_dir="${1:-.}"
  local task_number="$2"

  local heading
  heading="$(resolve_task_title "$project_dir" "$task_number")" || true

  if [[ -n "$heading" ]]; then
    local title
    title="$(_parse_title_from_heading "$heading")"
    if [[ -n "$title" ]]; then
      echo "$title"
      return 0
    fi
  fi

  # Fallback: use commit-message-based extraction.
  _extract_pr_title "" "$project_dir"
}

# Parse "Task N: <title>" from a markdown heading line.
# Strips leading ## or ### and heading prefix (Task/PR).
_parse_title_from_heading() {
  local heading="$1"

  # Strip leading markdown heading markers (## or ###) and whitespace.
  local stripped
  stripped="${heading#\#\#\# }"
  if [[ "$stripped" == "$heading" ]]; then
    stripped="${heading#\#\# }"
  fi

  # Convert "PR N:" prefix to "Task N:" for consistency.
  if [[ "$stripped" =~ ^PR[[:space:]]+([0-9]+)(.*) ]]; then
    local num="${BASH_REMATCH[1]}"
    local rest="${BASH_REMATCH[2]}"
    stripped="Task ${num}${rest}"
  fi

  if [[ -n "$stripped" ]]; then
    echo "$stripped"
    return 0
  fi

  return 1
}

# Extract PR title from Claude output searching for TITLE: prefix.
# Falls back to oldest commit message on the branch vs target.
_extract_pr_title() {
  local claude_output="$1"
  local project_dir="${2:-.}"

  local title=""
  title="$(_search_title_prefix "$claude_output")" || true

  if [[ -n "$title" ]]; then
    echo "$title"
    return 0
  fi

  # Fallback: oldest commit message on branch vs target.
  title="$(_oldest_commit_message "$project_dir")"
  if [[ -n "$title" ]]; then
    echo "$title"
    return 0
  fi

  echo ""
  return 1
}

# Search for TITLE: prefix anywhere in text, return first match.
_search_title_prefix() {
  local text="$1"
  local line title

  while IFS= read -r line; do
    # Match lines starting with TITLE: (case-sensitive, optional whitespace).
    if [[ "$line" =~ ^[[:space:]]*TITLE:[[:space:]]*(.*) ]]; then
      title="${BASH_REMATCH[1]}"
      title="$(_strip_quotes "$title")"
      if [[ -n "$title" ]]; then
        echo "$title"
        return 0
      fi
    fi
  done <<< "$text"

  return 1
}

# Strip surrounding double or single quotes from a string.
_strip_quotes() {
  local value="$1"

  if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "$value"
  fi
}

# Get the oldest commit message on the current branch vs target.
_oldest_commit_message() {
  local project_dir="${1:-.}"
  local target
  target="$(_resolve_checkout_target "$project_dir")"

  local message
  message="$(git -C "$project_dir" log "${target}..HEAD" \
    --reverse --format='%s' 2>/dev/null | head -1)"

  if [[ -n "$message" ]]; then
    echo "$message"
  fi
}

# Extract PR body from Claude output searching for BODY: prefix.
# Captures everything after the BODY: line until end or next marker.
_extract_pr_body() {
  local claude_output="$1"

  local body=""
  local in_body=false
  local line

  while IFS= read -r line; do
    if [[ "$in_body" == true ]]; then
      # Stop at next structured marker (TITLE:, END_BODY, or similar).
      if [[ "$line" =~ ^[[:space:]]*TITLE: ]] || \
         [[ "$line" =~ ^[[:space:]]*END_BODY ]]; then
        break
      fi
      body="${body}${line}
"
    elif [[ "$line" =~ ^[[:space:]]*BODY:[[:space:]]*(.*) ]]; then
      # Start capturing body content.
      local first_line="${BASH_REMATCH[1]}"
      if [[ -n "$first_line" ]]; then
        body="${first_line}
"
      fi
      in_body=true
    fi
  done <<< "$claude_output"

  # Trim all trailing newlines.
  while [[ "$body" == *$'\n' ]]; do
    body="${body%$'\n'}"
  done

  if [[ -n "$body" ]]; then
    echo "$body"
    return 0
  fi

  return 1
}

# --- PR Creation ---

# Create a PR for the given task using gh CLI.
# Title is optional — defaults to build_pr_title if not provided.
create_task_pr() {
  local project_dir="${1:-.}"
  local task_number="$2"
  local title="${3:-}"
  local body="${4:-}"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"
  local target
  target="$(_resolve_checkout_target "$project_dir")"

  # Default to task-header-based title if not provided.
  if [[ -z "$title" ]]; then
    title="$(build_pr_title "$project_dir" "$task_number")" || true
  fi

  if [[ -z "$title" ]]; then
    log_msg "$project_dir" "ERROR" "PR title must not be empty"
    return 1
  fi

  local pr_url
  pr_url="$(timeout "$timeout_gh" gh pr create \
    --title "$title" \
    --body "$body" \
    --head "$(build_branch_name "$task_number")" \
    --base "$target" \
    --repo "$(git -C "$project_dir" remote get-url origin 2>/dev/null)" \
    2>/dev/null)" || {
    log_msg "$project_dir" "ERROR" "Failed to create PR for task ${task_number}"
    return 1
  }

  log_msg "$project_dir" "INFO" "Created PR for task ${task_number}: ${pr_url}"
  echo "$pr_url"
}

# Detect an existing open PR for a task branch.
detect_task_pr() {
  local project_dir="${1:-.}"
  local task_number="$2"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"
  local branch_name
  branch_name="$(build_branch_name "$task_number")"

  local pr_url
  pr_url="$(timeout "$timeout_gh" gh pr view "$branch_name" \
    --json url --jq '.url' \
    --repo "$(git -C "$project_dir" remote get-url origin 2>/dev/null)" \
    2>/dev/null)" || return 1

  if [[ -n "$pr_url" ]]; then
    echo "$pr_url"
    return 0
  fi

  return 1
}

# --- Draft PR Management ---

# Create a draft PR with minimal body for early visibility.
# Returns the PR URL on success.
create_draft_pr() {
  local project_dir="${1:-.}"
  local task_number="$2"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"
  local target
  target="$(_resolve_checkout_target "$project_dir")"

  local title
  title="$(build_pr_title "$project_dir" "$task_number")" || \
    title="Task ${task_number}"

  local branch_name
  branch_name="$(build_branch_name "$task_number")"

  local repo
  repo="$(get_repo_slug "$project_dir")" || {
    log_msg "$project_dir" "ERROR" \
      "Could not determine repo slug for draft PR creation"
    return 1
  }

  local pr_url
  pr_url="$(timeout "$timeout_gh" gh pr create \
    --draft \
    --title "$title" \
    --body "Implementation in progress" \
    --head "$branch_name" \
    --base "$target" \
    --repo "$repo" \
    2>/dev/null)" || {
    log_msg "$project_dir" "ERROR" "Failed to create draft PR for task ${task_number}"
    return 1
  }

  log_msg "$project_dir" "INFO" "Created draft PR for task ${task_number}: ${pr_url}"
  echo "$pr_url"
}

# Convert a draft PR to ready for review.
mark_pr_ready() {
  local project_dir="${1:-.}"
  local pr_number="$2"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"

  local repo
  repo="$(get_repo_slug "$project_dir")" || {
    log_msg "$project_dir" "ERROR" \
      "Could not determine repo slug for mark_pr_ready PR #${pr_number}"
    return 1
  }

  timeout "$timeout_gh" gh pr ready "$pr_number" \
    --repo "$repo" 2>/dev/null || {
    log_msg "$project_dir" "ERROR" \
      "Failed to mark PR #${pr_number} as ready"
    return 1
  }

  log_msg "$project_dir" "INFO" "Marked PR #${pr_number} as ready for review"
}

# --- PR Body Generation ---

# Generate a PR description from the diff using Claude.
generate_pr_body() {
  local project_dir="${1:-.}"
  local task_number="$2"
  local task_title="${3:-}"
  local timeout_summary="${AUTOPILOT_TIMEOUT_SUMMARY:-60}"
  local target
  target="$(_resolve_checkout_target "$project_dir")"

  local max_diff_bytes="${AUTOPILOT_MAX_DIFF_BYTES:-500000}"

  local diff_content
  diff_content="$(git -C "$project_dir" diff "${target}...HEAD" 2>/dev/null)"

  if [[ -z "$diff_content" ]]; then
    log_msg "$project_dir" "WARNING" "No diff to generate PR body from"
    echo "Implementation for task ${task_number}."
    return 0
  fi

  # Truncate diff to avoid E2BIG when passing as CLI argument.
  local diff_bytes
  diff_bytes="${#diff_content}"
  if [[ "$diff_bytes" -gt "$max_diff_bytes" ]]; then
    diff_content="${diff_content:0:$max_diff_bytes}
... [truncated at ${max_diff_bytes} bytes]"
    log_msg "$project_dir" "WARNING" \
      "Diff truncated from ${diff_bytes} to ${max_diff_bytes} bytes for PR body generation"
  fi

  local prompt
  prompt="$(_build_pr_body_prompt "$task_number" "$task_title" "$diff_content")"

  local body
  body="$(_run_claude_and_extract "$timeout_summary" "$prompt")" || {
    log_msg "$project_dir" "WARNING" \
      "Claude PR body generation failed, using fallback"
    echo "Implementation for task ${task_number}."
    return 0
  }

  if [[ -z "$body" ]]; then
    echo "Implementation for task ${task_number}."
    return 0
  fi

  echo "$body"
}

# Build the prompt for PR body generation from a diff.
_build_pr_body_prompt() {
  local task_number="$1"
  local task_title="$2"
  local diff_content="$3"

  cat <<PROMPT
Summarize this git diff as a concise PR description. Include:
- A one-paragraph summary of what changed
- A bulleted list of key changes

Task ${task_number}: ${task_title}

Diff:
${diff_content}
PROMPT
}
