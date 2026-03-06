#!/usr/bin/env bash
# Git operations for Autopilot.
# Offloads branch creation, committing, PR creation, and PR title/body
# extraction from the coder agent to the pipeline.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_GIT_OPS_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_GIT_OPS_LOADED=1

# Source dependencies.
# shellcheck source=lib/config.sh
source "${BASH_SOURCE[0]%/*}/config.sh"
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"
# shellcheck source=lib/claude.sh
source "${BASH_SOURCE[0]%/*}/claude.sh"
# shellcheck source=lib/tasks.sh
source "${BASH_SOURCE[0]%/*}/tasks.sh"

# --- Repo Slug ---

# Derive OWNER/REPO slug from the git remote URL.
get_repo_slug() {
  local project_dir="${1:-.}"
  local url
  url="$(git -C "$project_dir" remote get-url origin 2>/dev/null)" || return 1

  # Strip .git suffix, then extract owner/repo from various URL forms.
  url="${url%.git}"
  if [[ "$url" =~ github\.com[:/]([^/]+/[^/]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

# --- Branch Operations ---

# Detect the default branch name (main or master) for a repo.
# Uses symbolic-ref to find origin's HEAD, falls back to main.
detect_default_branch() {
  local project_dir="${1:-.}"

  # Try origin's HEAD symbolic ref first (works for cloned repos).
  local ref
  ref="$(git -C "$project_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)" || true
  if [[ -n "$ref" ]]; then
    echo "${ref##refs/remotes/origin/}"
    return 0
  fi

  # Fallback: check if main or master exists locally.
  if git -C "$project_dir" rev-parse --verify main >/dev/null 2>&1; then
    echo "main"
    return 0
  fi
  if git -C "$project_dir" rev-parse --verify master >/dev/null 2>&1; then
    echo "master"
    return 0
  fi

  # Last resort: default to main.
  echo "main"
}

# Build the branch name for a given task number.
build_branch_name() {
  local task_number="$1"
  local prefix="${AUTOPILOT_BRANCH_PREFIX:-autopilot}"
  echo "${prefix}/task-${task_number}"
}

# Create and checkout a new branch for the given task.
create_task_branch() {
  local project_dir="${1:-.}"
  local task_number="$2"
  local branch_name
  branch_name="$(build_branch_name "$task_number")"
  local target
  target="$(_resolve_checkout_target "$project_dir")"

  if ! git -C "$project_dir" checkout -b "$branch_name" "$target" 2>/dev/null; then
    log_msg "$project_dir" "ERROR" "Failed to create branch: ${branch_name}"
    return 1
  fi

  log_msg "$project_dir" "INFO" "Created branch: ${branch_name} from ${target}"
}

# Delete a task branch locally and remotely.
# If the branch is currently checked out, switch to the default branch first.
delete_task_branch() {
  local project_dir="${1:-.}"
  local task_number="$2"
  local branch_name
  branch_name="$(build_branch_name "$task_number")"

  # Cannot delete the currently checked-out branch — switch away first.
  local current_branch
  current_branch="$(git -C "$project_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)" || true
  if [[ "$current_branch" == "$branch_name" ]]; then
    local checkout_target
    checkout_target="$(_resolve_checkout_target "$project_dir")"
    if ! git -C "$project_dir" checkout "$checkout_target" 2>/dev/null; then
      log_msg "$project_dir" "ERROR" \
        "Cannot switch away from ${branch_name} — checkout ${checkout_target} failed"
      return 1
    fi
  fi

  local deleted_local=false
  if git -C "$project_dir" branch -D "$branch_name" 2>/dev/null; then
    log_msg "$project_dir" "INFO" "Deleted local branch: ${branch_name}"
    deleted_local=true
  fi

  local deleted_remote=false
  if git -C "$project_dir" push origin --delete "$branch_name" 2>/dev/null; then
    deleted_remote=true
  fi

  if [[ "$deleted_local" == false && "$deleted_remote" == false ]]; then
    log_msg "$project_dir" "ERROR" \
      "Failed to delete branch ${branch_name} — local and remote deletion both failed"
    return 1
  fi
}

# Resolve which branch to checkout when switching away from a task branch.
# Uses AUTOPILOT_TARGET_BRANCH if set, otherwise detects the default branch.
_resolve_checkout_target() {
  local project_dir="${1:-.}"
  local target="${AUTOPILOT_TARGET_BRANCH:-}"

  if [[ -n "$target" ]]; then
    echo "$target"
    return 0
  fi

  detect_default_branch "$project_dir"
}

# Check if a task branch already exists (locally or remotely).
task_branch_exists() {
  local project_dir="${1:-.}"
  local task_number="$2"
  local branch_name
  branch_name="$(build_branch_name "$task_number")"

  # Check local first, then remote.
  if git -C "$project_dir" rev-parse --verify "$branch_name" >/dev/null 2>&1; then
    return 0
  fi
  if git -C "$project_dir" rev-parse --verify "origin/${branch_name}" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# --- Commit Operations ---

# Stage and commit all changes with the given message.
commit_changes() {
  local project_dir="${1:-.}"
  local message="$2"

  if [[ -z "$message" ]]; then
    log_msg "$project_dir" "ERROR" "Commit message must not be empty"
    return 1
  fi

  # Stage all changes (tracked and untracked).
  git -C "$project_dir" add -A 2>/dev/null || {
    log_msg "$project_dir" "ERROR" "Failed to stage changes"
    return 1
  }

  # Check if there are staged changes to commit.
  if git -C "$project_dir" diff --cached --quiet 2>/dev/null; then
    log_msg "$project_dir" "WARNING" "No changes to commit"
    return 0
  fi

  git -C "$project_dir" commit -m "$message" 2>/dev/null || {
    log_msg "$project_dir" "ERROR" "Failed to commit: ${message}"
    return 1
  }

  log_msg "$project_dir" "INFO" "Committed: ${message}"
}

# Push the current branch to origin.
push_branch() {
  local project_dir="${1:-.}"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"

  local branch_name
  branch_name="$(git -C "$project_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"

  if [[ -z "$branch_name" ]]; then
    log_msg "$project_dir" "ERROR" "Could not determine current branch"
    return 1
  fi

  timeout "$timeout_gh" git -C "$project_dir" push -u origin "$branch_name" 2>/dev/null || {
    log_msg "$project_dir" "ERROR" "Failed to push branch: ${branch_name}"
    return 1
  }

  log_msg "$project_dir" "INFO" "Pushed branch: ${branch_name}"
}

# Get the current HEAD SHA for the project.
get_head_sha() {
  local project_dir="${1:-.}"
  git -C "$project_dir" rev-parse HEAD 2>/dev/null
}

# --- PR Title/Body Extraction ---

# Build a PR title from the tasks file header for a given task number.
# Returns "Task N: <title>" on success, falls back to _extract_pr_title.
build_pr_title() {
  local project_dir="${1:-.}"
  local task_number="$2"

  local tasks_file
  tasks_file="$(detect_tasks_file "$project_dir" 2>/dev/null)" || true

  if [[ -n "$tasks_file" ]]; then
    local heading
    heading="$(extract_task_title "$tasks_file" "$task_number" 2>/dev/null)" || true

    if [[ -n "$heading" ]]; then
      local title
      title="$(_parse_title_from_heading "$heading")"
      if [[ -n "$title" ]]; then
        echo "$title"
        return 0
      fi
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
