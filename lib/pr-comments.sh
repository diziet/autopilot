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
# shellcheck source=lib/git-ops.sh
source "${BASH_SOURCE[0]%/*}/git-ops.sh"

# Maximum total lines for any PR comment body.
readonly _PR_COMMENT_MAX_LINES=50

# --- Comment Posting ---

# Post a comment on a PR. Non-fatal on failure — logs warning and continues.
post_pipeline_comment() {
  local project_dir="${1:-.}"
  local pr_number="$2"
  local comment_body="$3"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"

  local repo
  repo="$(get_repo_slug "$project_dir")" || {
    log_msg "$project_dir" "WARNING" \
      "Could not determine repo slug for pipeline comment on PR #${pr_number}"
    return 0
  }

  timeout "$timeout_gh" gh pr comment "$pr_number" \
    --repo "$repo" \
    --body "$comment_body" >/dev/null 2>&1 || {
    log_msg "$project_dir" "WARNING" \
      "Failed to post pipeline comment on PR #${pr_number} — continuing"
    return 0
  }

  log_msg "$project_dir" "INFO" \
    "Posted pipeline status comment on PR #${pr_number}"
}

# --- Test Gate Failure Comment ---

# Build and post a comment for a test gate failure.
post_test_failure_comment() {
  local project_dir="${1:-.}"
  local pr_number="$2"
  local test_exit="$3"

  local comment
  comment="$(_build_test_failure_comment "$project_dir" "$test_exit")"
  post_pipeline_comment "$project_dir" "$pr_number" "$comment"
}

# Build the comment body for a test gate failure.
_build_test_failure_comment() {
  local project_dir="$1"
  local test_exit="$2"

  local tail_lines="${AUTOPILOT_TEST_OUTPUT_TAIL:-80}"
  local output_log="${project_dir}/.autopilot/test_gate_output.log"

  local test_output=""
  if [[ -f "$output_log" ]]; then
    test_output="$(tail -n "$tail_lines" "$output_log" 2>/dev/null)" || true
  fi

  # Truncate to fit within max comment lines (header + details wrapper ~10 lines).
  local max_output_lines=$(( _PR_COMMENT_MAX_LINES - 10 ))
  if [[ -n "$test_output" ]]; then
    local line_count
    line_count="$(echo "$test_output" | wc -l | tr -d ' ')"
    if [[ "$line_count" -gt "$max_output_lines" ]]; then
      test_output="$(echo "$test_output" | tail -n "$max_output_lines")"
    fi
  fi

  _format_test_failure_body "$test_exit" "$test_output"
}

# Format the markdown body for a test failure comment.
_format_test_failure_body() {
  local test_exit="$1"
  local test_output="$2"

  local body
  body="### ⚠️ Test Gate Failed

**Exit code:** \`${test_exit}\`"

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

  local comment
  comment="$(_build_fixer_result_comment "$project_dir" \
    "$sha_before" "$is_tests_passed")"
  post_pipeline_comment "$project_dir" "$pr_number" "$comment"
}

# Build the comment body for a fixer result.
_build_fixer_result_comment() {
  local project_dir="$1"
  local sha_before="$2"
  local is_tests_passed="$3"

  local commit_log=""
  if [[ -n "$sha_before" ]]; then
    commit_log="$(git -C "$project_dir" log \
      --oneline "${sha_before}..HEAD" 2>/dev/null)" || true
  fi

  # Truncate commit log if too long.
  local max_commit_lines=$(( _PR_COMMENT_MAX_LINES - 8 ))
  if [[ -n "$commit_log" ]]; then
    local line_count
    line_count="$(echo "$commit_log" | wc -l | tr -d ' ')"
    if [[ "$line_count" -gt "$max_commit_lines" ]]; then
      commit_log="$(echo "$commit_log" | head -n "$max_commit_lines")
... ($(( line_count - max_commit_lines )) more commits)"
    fi
  fi

  _format_fixer_result_body "$commit_log" "$is_tests_passed"
}

# Format the markdown body for a fixer result comment.
_format_fixer_result_body() {
  local commit_log="$1"
  local is_tests_passed="$2"

  local test_status="❌ Failed"
  if [[ "$is_tests_passed" == "true" ]]; then
    test_status="✅ Passed"
  fi

  local body
  body="### 🔧 Fixer Completed

**Post-fix tests:** ${test_status}"

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

  echo "$body"
}
