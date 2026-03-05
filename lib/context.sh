#!/usr/bin/env bash
# Context accumulation for Autopilot.
# Generates task summaries via Claude (non-blocking) and
# appends them to .autopilot/completed-summary.md for coder context.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_CONTEXT_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_CONTEXT_LOADED=1

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
_CONTEXT_LIB_DIR="${BASH_SOURCE[0]%/*}"
_CONTEXT_PROMPTS_DIR="${_CONTEXT_LIB_DIR}/../prompts"

# --- Exit Code Constants ---
readonly CONTEXT_OK=0
readonly CONTEXT_ERROR=1
export CONTEXT_OK CONTEXT_ERROR

# --- Summary File Path ---

# Return the path to the completed-summary.md file.
get_summary_file() {
  local project_dir="${1:-.}"
  echo "${project_dir}/.autopilot/completed-summary.md"
}

# --- Summary Reading ---

# Read the accumulated summary, truncated to AUTOPILOT_MAX_SUMMARY_LINES.
read_completed_summary() {
  local project_dir="${1:-.}"
  local max_lines="${AUTOPILOT_MAX_SUMMARY_LINES:-50}"
  local summary_file
  summary_file="$(get_summary_file "$project_dir")"

  if [[ ! -f "$summary_file" ]]; then
    echo ""
    return 0
  fi

  local content
  content="$(head -n "$max_lines" "$summary_file")"

  local total_lines
  total_lines="$(wc -l < "$summary_file" | tr -d ' ')"

  if [[ "$total_lines" -gt "$max_lines" ]]; then
    content="${content}
... [truncated: ${total_lines} total lines, showing first ${max_lines}]"
  fi

  echo "$content"
}

# --- Prompt Construction ---

# Build the summary generation prompt from a diff and task metadata.
build_summary_prompt() {
  local task_number="$1"
  local task_title="$2"
  local diff_content="$3"

  local system_prompt=""
  system_prompt="$(_read_prompt_file "${_CONTEXT_PROMPTS_DIR}/summarize.md" "." 2>/dev/null)" || true

  local prompt=""
  if [[ -n "$system_prompt" ]]; then
    prompt="${system_prompt}

---

"
  fi

  prompt="${prompt}## Task ${task_number}: ${task_title}

\`\`\`diff
${diff_content}
\`\`\`

Write a concise summary for this completed task."

  echo "$prompt"
}

# --- Summary Append ---

# Append a task summary to the completed-summary.md file with lock protection.
_append_summary() {
  local project_dir="${1:-.}"
  local task_number="$2"
  local summary_text="$3"
  local summary_file
  summary_file="$(get_summary_file "$project_dir")"

  mkdir -p "$(dirname "$summary_file")"

  # Acquire lock to prevent concurrent appends from interleaving.
  acquire_lock "$project_dir" "summary" || {
    log_msg "$project_dir" "WARNING" \
      "Could not acquire summary lock for task ${task_number}, writing anyway"
  }

  # Write to temp file then append for safer I/O.
  local tmp_file="${summary_file}.tmp.$$"
  if [[ -f "$summary_file" ]] && [[ -s "$summary_file" ]]; then
    printf '\n%s\n' "$summary_text" > "$tmp_file"
  else
    printf '%s\n' "$summary_text" > "$tmp_file"
  fi
  cat "$tmp_file" >> "$summary_file"
  rm -f "$tmp_file"

  release_lock "$project_dir" "summary" || true

  log_msg "$project_dir" "INFO" \
    "Appended summary for task ${task_number} to completed-summary.md"
}

# --- Diff Fetching ---

# Fetch the diff for a merged task from GitHub via gh CLI.
_fetch_task_diff() {
  local project_dir="${1:-.}"
  local pr_number="$2"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"

  local repo
  repo="$(get_repo_slug "$project_dir")" || {
    log_msg "$project_dir" "WARNING" \
      "Could not determine repo slug for task diff"
    return 1
  }

  timeout "$timeout_gh" gh pr diff "$pr_number" \
    --repo "$repo" 2>/dev/null
}

# --- Summary Generation ---

# Generate a task summary via Claude and append it to completed-summary.md.
# Non-blocking: logs warnings on failure but returns CONTEXT_OK.
# Returns CONTEXT_ERROR only on unexpected failures.
generate_task_summary() {
  local project_dir="${1:-.}"
  local task_number="$2"
  local pr_number="${3:-}"
  local task_title="${4:-Task ${task_number}}"

  local timeout_summary="${AUTOPILOT_TIMEOUT_SUMMARY:-60}"
  local max_diff_bytes="${AUTOPILOT_MAX_DIFF_BYTES:-500000}"
  local max_entry_lines="${AUTOPILOT_MAX_SUMMARY_ENTRY_LINES:-20}"

  log_msg "$project_dir" "INFO" \
    "Generating summary for task ${task_number} (PR #${pr_number})"

  # Fetch the PR diff for context.
  local diff_content=""
  if [[ -n "$pr_number" ]]; then
    diff_content="$(_fetch_task_diff "$project_dir" "$pr_number" 2>/dev/null)" || true
  fi

  if [[ -z "$diff_content" ]]; then
    _append_fallback_summary "$project_dir" "$task_number" "$task_title"
    return "$CONTEXT_OK"
  fi

  # Truncate oversized diffs.
  local diff_bytes="${#diff_content}"
  if [[ "$diff_bytes" -gt "$max_diff_bytes" ]]; then
    diff_content="${diff_content:0:$max_diff_bytes}
... [truncated at ${max_diff_bytes} bytes]"
    log_msg "$project_dir" "WARNING" \
      "Diff truncated from ${diff_bytes} to ${max_diff_bytes} bytes for summary"
  fi

  # Build prompt and call Claude via shared helper.
  local prompt
  prompt="$(build_summary_prompt "$task_number" "$task_title" "$diff_content")"

  local summary_text
  summary_text="$(_run_claude_and_extract "$timeout_summary" "$prompt")" || {
    log_msg "$project_dir" "WARNING" \
      "Summary generation failed for task ${task_number}, using fallback"
    _append_fallback_summary "$project_dir" "$task_number" "$task_title"
    return "$CONTEXT_OK"
  }

  if [[ -z "$summary_text" ]]; then
    log_msg "$project_dir" "WARNING" \
      "Empty summary response for task ${task_number}, using fallback"
    _append_fallback_summary "$project_dir" "$task_number" "$task_title"
    return "$CONTEXT_OK"
  fi

  # Enforce per-entry max lines (separate from the read-time limit).
  local line_count
  line_count="$(echo "$summary_text" | wc -l | tr -d ' ')"
  if [[ "$line_count" -gt "$max_entry_lines" ]]; then
    summary_text="$(echo "$summary_text" | head -n "$max_entry_lines")"
    log_msg "$project_dir" "INFO" \
      "Trimmed summary for task ${task_number} from ${line_count} to ${max_entry_lines} lines"
  fi

  _append_summary "$project_dir" "$task_number" "$summary_text"
  return "$CONTEXT_OK"
}

# Append a minimal fallback summary when Claude is unavailable.
_append_fallback_summary() {
  local project_dir="${1:-.}"
  local task_number="$2"
  local task_title="${3:-Task ${task_number}}"

  local fallback="### Task ${task_number}: ${task_title}
Completed (summary unavailable)."

  _append_summary "$project_dir" "$task_number" "$fallback"
}

# --- Background Wrapper ---

# Generate a task summary in the background (non-blocking).
# Callers should invoke directly (not in $()) and use $! to capture PID:
#   generate_task_summary_bg "$dir" 5 42 "title"
#   local bg_pid=$!
generate_task_summary_bg() {
  local project_dir="${1:-.}"
  local task_number="$2"
  local pr_number="${3:-}"
  local task_title="${4:-Task ${task_number}}"

  log_msg "$project_dir" "INFO" \
    "Starting background summary generation for task ${task_number}"

  generate_task_summary "$project_dir" "$task_number" \
    "$pr_number" "$task_title" &
}
