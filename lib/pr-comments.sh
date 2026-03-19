#!/usr/bin/env bash
# PR status comments for Autopilot pipeline events.
# Posts concise status comments on PRs after test gate failures and fixer
# completions, making pipeline activity visible to anyone watching the PR.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_PR_COMMENTS_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_PR_COMMENTS_LOADED=1

# Source dependencies.
# shellcheck source=lib/config.sh
source "${BASH_SOURCE[0]%/*}/config.sh"
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"
# shellcheck source=lib/claude.sh
source "${BASH_SOURCE[0]%/*}/claude.sh"
# shellcheck source=lib/reviewer-posting.sh
source "${BASH_SOURCE[0]%/*}/reviewer-posting.sh"
# shellcheck source=lib/test-summary.sh
source "${BASH_SOURCE[0]%/*}/test-summary.sh"

# Maximum total lines for any PR comment body.
readonly _PR_COMMENT_MAX_LINES=100

# --- Shared Test Summary Helper ---

# Read test output log and parse a one-line summary.
# Args: project_dir [exit_code] [timeout_seconds]
# Also reads .autopilot/test_gate_duration if present.
_parse_test_summary_from_log() {
  local project_dir="$1"
  local exit_code="${2:-0}"
  local timeout_seconds="${3:-}"
  local output_log="${project_dir}/.autopilot/test_gate_output.log"

  # Read persisted wall-clock duration from the test gate.
  local duration=""
  local duration_file="${project_dir}/.autopilot/test_gate_duration"
  if [[ -f "$duration_file" ]]; then
    duration="$(cat "$duration_file" 2>/dev/null)" || true
  fi

  if [[ -f "$output_log" ]]; then
    local full_output
    full_output="$(cat "$output_log" 2>/dev/null)" || true
    if [[ -n "$full_output" ]]; then
      parse_test_summary "$full_output" "$exit_code" "$timeout_seconds" "$duration"
      return 0
    fi
  fi

  # No output log or empty — still report timeout if applicable.
  if is_timeout_exit "$exit_code"; then
    format_test_summary "0" "0" "0" "$duration" "$exit_code" "$timeout_seconds"
  fi
}

# --- Test Gate Failure Comment ---

# Build and post a comment for a test gate failure.
# Args: project_dir pr_number test_exit [artifact_dir]
# artifact_dir defaults to project_dir; in worktree mode pass task_dir.
post_test_failure_comment() {
  local project_dir="${1:-.}"
  local pr_number="$2"
  local test_exit="$3"
  local artifact_dir="${4:-$project_dir}"

  local comment
  comment="$(_build_test_failure_comment "$project_dir" "$test_exit" "$artifact_dir")"
  post_pr_comment "$project_dir" "$pr_number" "$comment" || true
}

# Build the comment body for a test gate failure.
# Args: project_dir test_exit [artifact_dir]
_build_test_failure_comment() {
  local project_dir="$1"
  local test_exit="$2"
  local artifact_dir="${3:-$project_dir}"

  local tail_lines="${AUTOPILOT_TEST_OUTPUT_TAIL:-80}"
  local output_log="${artifact_dir}/.autopilot/test_gate_output.log"
  local timeout_seconds="${AUTOPILOT_TIMEOUT_TEST_GATE:-300}"

  local test_output=""
  if [[ -f "$output_log" ]]; then
    test_output="$(tail -n "$tail_lines" "$output_log" 2>/dev/null)" || true
  fi

  # Parse test summary from full output log (before truncation).
  local test_summary=""
  test_summary="$(_parse_test_summary_from_log "$artifact_dir" \
    "$test_exit" "$timeout_seconds")" || true

  # Overhead: header(1) + exit code(1) + summary(1) + blank(1) + details tags(4) + code fences(2) + margin(2) = ~12 lines.
  local max_output_lines=$(( _PR_COMMENT_MAX_LINES - 12 ))
  if [[ -n "$test_output" ]]; then
    local line_count
    line_count="$(wc -l <<< "$test_output" | tr -d ' ')"
    if [[ "$line_count" -gt "$max_output_lines" ]]; then
      test_output="$(tail -n "$max_output_lines" <<< "$test_output")"
    fi
  fi

  _format_test_failure_body "$test_exit" "$test_output" "$test_summary"
}

# Format the markdown body for a test failure comment.
_format_test_failure_body() {
  local test_exit="$1"
  local test_output="$2"
  local test_summary="${3:-}"

  local body
  body="### ⚠️ Test Gate Failed

**Exit code:** \`${test_exit}\`"

  if [[ -n "$test_summary" ]]; then
    body="${body}
**${test_summary}**"
  fi

  if [[ -n "$test_output" ]]; then
    body="${body}

<details>
<summary>Test output (last lines)</summary>

\`\`\`
${test_output}
\`\`\`
</details>"
  fi

  echo "$body"
}

# --- Fixer Result Comment ---

# Build and post a comment for fixer completion.
post_fixer_result_comment() {
  local project_dir="${1:-.}"
  local pr_number="$2"
  local sha_before="$3"
  local is_tests_passed="$4"
  local task_number="${5:-}"
  local artifact_dir="${6:-$project_dir}"

  local comment
  comment="$(_build_fixer_result_comment "$project_dir" \
    "$sha_before" "$is_tests_passed" "$task_number" "$artifact_dir")"
  post_pr_comment "$project_dir" "$pr_number" "$comment" || true
}

# Build the comment body for a fixer result.
_build_fixer_result_comment() {
  local project_dir="$1"
  local sha_before="$2"
  local is_tests_passed="$3"
  local task_number="${4:-}"
  local artifact_dir="${5:-$project_dir}"

  # Use worktree path for git log — task branch is checked out there.
  local git_dir="$project_dir"
  if [[ -n "$task_number" ]]; then
    git_dir="$(resolve_task_dir "$project_dir" "$task_number" 2>/dev/null)" || {
      log_msg "$project_dir" "WARNING" \
        "Could not resolve task dir for fixer comment — falling back to project_dir"
      git_dir="$project_dir"
    }
  fi

  local commit_log=""
  if [[ -n "$sha_before" ]]; then
    commit_log="$(git -C "$git_dir" log \
      --oneline "${sha_before}..HEAD" 2>/dev/null)" || true
  fi

  # Truncate commit log if too long.
  local max_commit_lines=15
  if [[ -n "$commit_log" ]]; then
    local line_count
    line_count="$(wc -l <<< "$commit_log" | tr -d ' ')"
    if [[ "$line_count" -gt "$max_commit_lines" ]]; then
      commit_log="$(head -n "$max_commit_lines" <<< "$commit_log")
... ($(( line_count - max_commit_lines )) more commits)"
    fi
  fi

  # Read fixer agent summary from output JSON.
  local fixer_summary=""
  fixer_summary="$(_read_fixer_summary "$project_dir" "$task_number")"

  # Read test failure output when tests failed (from artifact_dir, where
  # postfix tests wrote them — may differ from project_dir in worktree mode).
  local test_failure_output=""
  if [[ "$is_tests_passed" != "true" ]]; then
    test_failure_output="$(_read_test_failure_tail "$artifact_dir")"
  fi

  # Parse test summary from output log (artifact_dir has the postfix results).
  local test_summary=""
  test_summary="$(_parse_test_summary_from_log "$artifact_dir")" || true

  _format_fixer_result_body "$commit_log" "$is_tests_passed" \
    "$fixer_summary" "$test_failure_output" "$test_summary"
}

# Read the fixer agent's summary from its output JSON.
_read_fixer_summary() {
  local project_dir="$1"
  local task_number="${2:-}"
  [[ -z "$task_number" ]] && return 0

  local fixer_json="${project_dir}/.autopilot/logs/fixer-task-${task_number}.json"
  local summary
  summary="$(extract_claude_text "$fixer_json" 2>/dev/null)" || {
    log_msg "$project_dir" "DEBUG" \
      "Could not extract fixer summary from ${fixer_json}"
    return 0
  }

  # Truncate to 20 lines max.
  local line_count
  line_count="$(wc -l <<< "$summary" | tr -d ' ')"
  if [[ "$line_count" -gt 20 ]]; then
    summary="$(head -n 20 <<< "$summary")
... (truncated)"
  fi
  printf '%s' "$summary"
}

# Read failing test lines from test output log.
_read_test_failure_tail() {
  local project_dir="$1"
  local output_log="${project_dir}/.autopilot/test_gate_output.log"
  [[ -f "$output_log" ]] || return 0

  # Grep full output for TAP "not ok" lines (~15 failures with 1 context line each).
  local failures
  failures="$(grep -A1 '^not ok' "$output_log" 2>/dev/null \
    | grep -v '^--$' | head -30)" || true
  if [[ -n "$failures" ]]; then
    printf '%s' "$failures"
    return 0
  fi

  # No TAP failures — try generic failure patterns (pytest, go test, etc.).
  failures="$(grep -E '^(FAIL|error)' "$output_log" 2>/dev/null \
    | head -30)" || true
  if [[ -n "$failures" ]]; then
    printf '%s' "$failures"
    return 0
  fi

  # No pattern matches — show raw tail so "❌ Failed" has context.
  local tail_lines=30
  local output
  output="$(tail -n "$tail_lines" "$output_log" 2>/dev/null)" || return 0
  printf '%s' "$output"
}

# Format the markdown body for a fixer result comment.
_format_fixer_result_body() {
  local commit_log="$1"
  local is_tests_passed="$2"
  local fixer_summary="${3:-}"
  local test_failure_output="${4:-}"
  local test_summary="${5:-}"

  local test_status="❌ Failed"
  if [[ "$is_tests_passed" == "true" ]]; then
    test_status="✅ Passed"
  fi

  local body
  body="### 🔧 Fixer Completed

**Post-fix tests:** ${test_status}"

  if [[ -n "$test_summary" ]]; then
    body="${body}
**${test_summary}**"
  fi

  # Fixer summary — what the agent actually did.
  if [[ -n "$fixer_summary" ]]; then
    body="${body}

<details>
<summary>Fixer summary</summary>

${fixer_summary}

</details>"
  fi

  if [[ -n "$commit_log" ]]; then
    body="${body}

**Commits:**
\`\`\`
${commit_log}
\`\`\`"
  else
    body="${body}

*No new commits from fixer.*"
  fi

  # Test failure details when tests failed.
  if [[ -n "$test_failure_output" ]]; then
    body="${body}

<details>
<summary>Failing tests</summary>

\`\`\`
${test_failure_output}
\`\`\`

</details>"
  fi

  echo "$body"
}

# --- Session Summary Comment (posted after merge) ---

# Post a session summary comment listing all agent sessions for a task.
post_session_summary_comment() {
  local project_dir="${1:-.}"
  local pr_number="$2"
  local task_number="$3"

  local comment
  comment="$(_build_session_summary_comment "$project_dir" "$task_number")"
  if [[ -z "$comment" ]]; then
    log_msg "$project_dir" "WARNING" \
      "No session data found for task ${task_number} — skipping summary comment"
    return 0
  fi

  post_pr_comment "$project_dir" "$pr_number" "$comment" || {
    log_msg "$project_dir" "WARNING" \
      "Failed to post session summary comment on PR #${pr_number} — non-fatal"
    return 0
  }
}

# Build the markdown body listing all agent sessions for a task.
_build_session_summary_comment() {
  local project_dir="$1"
  local task_number="$2"
  local log_dir="${project_dir}/.autopilot/logs"

  # Collect all JSON log files for this task.
  local json_files=()
  local f
  for f in "${log_dir}"/*-task-"${task_number}".json; do
    [[ -f "$f" ]] || continue
    json_files+=("$f")
  done

  if [[ ${#json_files[@]} -eq 0 ]]; then
    return 0
  fi

  local rows=""
  local entry_count=0
  for f in "${json_files[@]}"; do
    local row
    row="$(_parse_session_entry "$f" "$log_dir" "$task_number")" || continue
    [[ -n "$row" ]] || continue
    rows="${rows}${row}
"
    entry_count=$(( entry_count + 1 ))
  done

  if [[ "$entry_count" -eq 0 ]]; then
    return 0
  fi

  _format_session_summary_body "$rows"
}

# Parse a single agent session JSON file into a table row.
_parse_session_entry() {
  local json_file="$1"
  local log_dir="$2"
  local task_number="$3"

  # Extract agent role from filename: {role}-task-{N}.json
  local basename
  basename="$(basename "$json_file" ".json")"
  local role="${basename%-task-"${task_number}"}"
  [[ -n "$role" ]] || return 1

  # Extract session_id from JSON.
  local session_id=""
  session_id="$(jq -r '.session_id // empty' "$json_file" 2>/dev/null)" || true
  [[ -n "$session_id" ]] || return 1

  # Read wall-clock duration from matching .walltime file.
  local duration_display="-"
  local walltime_file="${log_dir}/${role}-task-${task_number}.walltime"
  if [[ -f "$walltime_file" ]]; then
    local seconds=""
    seconds="$(cat "$walltime_file" 2>/dev/null)" || true
    if [[ "$seconds" =~ ^[0-9]+$ ]]; then
      duration_display="$(_format_duration_seconds "$seconds")"
    fi
  fi

  echo "| ${role} | \`${session_id}\` | ${duration_display} |"
}

# Format seconds into human-readable duration (e.g. "5m 30s").
_format_duration_seconds() {
  local seconds="$1"
  if [[ "$seconds" -ge 60 ]]; then
    local mins=$(( seconds / 60 ))
    local secs=$(( seconds % 60 ))
    echo "${mins}m ${secs}s"
  else
    echo "${seconds}s"
  fi
}

# Format the markdown body for the session summary comment.
_format_session_summary_body() {
  local rows="$1"

  local body
  body="### 🤖 Agent Session Summary

| Role | Session ID | Duration |
|------|-----------|----------|
${rows}"

  echo "$body"
}
