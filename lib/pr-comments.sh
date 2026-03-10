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
_parse_test_summary_from_log() {
  local project_dir="$1"
  local exit_code="${2:-0}"
  local timeout_seconds="${3:-}"
  local output_log="${project_dir}/.autopilot/test_gate_output.log"

  if [[ -f "$output_log" ]]; then
    local full_output
    full_output="$(cat "$output_log" 2>/dev/null)" || true
    if [[ -n "$full_output" ]]; then
      parse_test_summary "$full_output" "$exit_code" "$timeout_seconds"
      return 0
    fi
  fi

  # No output log or empty — still report timeout if applicable.
  if is_timeout_exit "$exit_code"; then
    format_test_summary "0" "0" "0" "" "$exit_code" "$timeout_seconds"
  fi
}

# --- Test Gate Failure Comment ---

# Build and post a comment for a test gate failure.
post_test_failure_comment() {
  local project_dir="${1:-.}"
  local pr_number="$2"
  local test_exit="$3"

  local comment
  comment="$(_build_test_failure_comment "$project_dir" "$test_exit")"
  post_pr_comment "$project_dir" "$pr_number" "$comment" || true
}

# Build the comment body for a test gate failure.
_build_test_failure_comment() {
  local project_dir="$1"
  local test_exit="$2"

  local tail_lines="${AUTOPILOT_TEST_OUTPUT_TAIL:-80}"
  local output_log="${project_dir}/.autopilot/test_gate_output.log"
  local timeout_seconds="${AUTOPILOT_TIMEOUT_TEST_GATE:-300}"

  local test_output=""
  if [[ -f "$output_log" ]]; then
    test_output="$(tail -n "$tail_lines" "$output_log" 2>/dev/null)" || true
  fi

  # Parse test summary from full output log (before truncation).
  local test_summary=""
  test_summary="$(_parse_test_summary_from_log "$project_dir" \
    "$test_exit" "$timeout_seconds")" || true

  # Truncate to fit within max comment lines (header + details wrapper ~10 lines).
  local max_output_lines=$(( _PR_COMMENT_MAX_LINES - 10 ))
  if [[ -n "$test_output" ]]; then
    local line_count
    line_count="$(echo "$test_output" | wc -l | tr -d ' ')"
    if [[ "$line_count" -gt "$max_output_lines" ]]; then
      test_output="$(echo "$test_output" | tail -n "$max_output_lines")"
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

  local comment
  comment="$(_build_fixer_result_comment "$project_dir" \
    "$sha_before" "$is_tests_passed" "$task_number")"
  post_pr_comment "$project_dir" "$pr_number" "$comment" || true
}

# Build the comment body for a fixer result.
_build_fixer_result_comment() {
  local project_dir="$1"
  local sha_before="$2"
  local is_tests_passed="$3"
  local task_number="${4:-}"

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
    line_count="$(echo "$commit_log" | wc -l | tr -d ' ')"
    if [[ "$line_count" -gt "$max_commit_lines" ]]; then
      commit_log="$(echo "$commit_log" | head -n "$max_commit_lines")
... ($(( line_count - max_commit_lines )) more commits)"
    fi
  fi

  # Read fixer agent summary from output JSON.
  local fixer_summary=""
  fixer_summary="$(_read_fixer_summary "$project_dir" "$task_number")"

  # Read test failure output when tests failed.
  local test_failure_output=""
  if [[ "$is_tests_passed" != "true" ]]; then
    test_failure_output="$(_read_test_failure_tail "$project_dir")"
  fi

  # Parse test summary from output log.
  local test_summary=""
  test_summary="$(_parse_test_summary_from_log "$project_dir")" || true

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
  line_count="$(printf '%s\n' "$summary" | wc -l | tr -d ' ')"
  if [[ "$line_count" -gt 20 ]]; then
    summary="$(printf '%s\n' "$summary" | head -n 20)
... (truncated)"
  fi
  printf '%s' "$summary"
}

# Read failing test lines from test output log.
_read_test_failure_tail() {
  local project_dir="$1"
  local output_log="${project_dir}/.autopilot/test_gate_output.log"
  [[ -f "$output_log" ]] || return 0

  # Grep the full output file for TAP "not ok" lines with context.
  local failures
  failures="$(grep -A1 '^not ok' "$output_log" 2>/dev/null \
    | grep -v '^--$' | head -30)" || true
  if [[ -n "$failures" ]]; then
    printf '%s' "$failures"
    return 0
  fi

  # No TAP failures — fall back to raw tail for non-bats frameworks.
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
