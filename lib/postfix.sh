#!/usr/bin/env bash
# Post-fix verification for Autopilot.
# Runs the test gate after fixer completes. Spawns a fix-tests agent if
# tests fail. Includes fixer push verification (SHA comparison before/after)
# and graceful degradation when gh api calls fail.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_POSTFIX_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_POSTFIX_LOADED=1

# Source dependencies.
# shellcheck source=lib/config.sh
source "${BASH_SOURCE[0]%/*}/config.sh"
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"
# shellcheck source=lib/claude.sh
source "${BASH_SOURCE[0]%/*}/claude.sh"
# shellcheck source=lib/testgate.sh
source "${BASH_SOURCE[0]%/*}/testgate.sh"
# shellcheck source=lib/hooks.sh
source "${BASH_SOURCE[0]%/*}/hooks.sh"
# shellcheck source=lib/git-ops.sh
source "${BASH_SOURCE[0]%/*}/git-ops.sh"

# Directory where prompts/ lives (relative to this script's location).
_POSTFIX_LIB_DIR="${BASH_SOURCE[0]%/*}"
_POSTFIX_PROMPTS_DIR="${_POSTFIX_LIB_DIR}/../prompts"

# --- Exit Code Constants (exported for dispatcher and other modules) ---
readonly POSTFIX_PASS=0
readonly POSTFIX_FAIL=1
readonly POSTFIX_NO_PUSH=2
readonly POSTFIX_ERROR=3
export POSTFIX_PASS POSTFIX_FAIL POSTFIX_NO_PUSH POSTFIX_ERROR

# --- Push Verification ---

# Fetch the remote HEAD SHA for a branch. Gracefully returns empty on failure.
fetch_remote_sha() {
  local project_dir="${1:-.}"
  local branch_name="$2"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"

  local repo
  repo="$(get_repo_slug "$project_dir")" || {
    log_msg "$project_dir" "WARNING" "Could not determine repo slug for SHA fetch"
    return 0
  }

  local sha
  sha="$(timeout "$timeout_gh" gh api \
    "repos/${repo}/git/ref/heads/${branch_name}" \
    --jq '.object.sha' 2>/dev/null)" || {
    log_msg "$project_dir" "WARNING" \
      "gh api failed fetching SHA for ${branch_name} — degrading gracefully"
    return 0
  }

  echo "$sha"
}

# Verify the fixer pushed new commits by comparing SHAs before/after.
verify_fixer_push() {
  local project_dir="${1:-.}"
  local branch_name="$2"
  local sha_before="$3"

  # If we have no before-SHA, we cannot verify — assume push happened.
  if [[ -z "$sha_before" ]]; then
    log_msg "$project_dir" "WARNING" \
      "No pre-fixer SHA available — skipping push verification"
    return 0
  fi

  local sha_after
  sha_after="$(fetch_remote_sha "$project_dir" "$branch_name")"

  # If we cannot fetch the after-SHA, degrade gracefully.
  if [[ -z "$sha_after" ]]; then
    log_msg "$project_dir" "WARNING" \
      "Could not fetch post-fixer SHA — skipping push verification"
    return 0
  fi

  if [[ "$sha_before" = "$sha_after" ]]; then
    log_msg "$project_dir" "WARNING" \
      "Fixer did not push: SHA unchanged (${sha_before})"
    return 1
  fi

  log_msg "$project_dir" "INFO" \
    "Fixer push verified: ${sha_before} -> ${sha_after}"
  return 0
}

# --- Fix-Tests Agent ---

# Build the prompt for the fix-tests agent.
build_fix_tests_prompt() {
  local project_dir="$1"
  local task_number="$2"
  local pr_number="$3"
  local test_output="$4"
  local branch_name="$5"

  local tail_lines="${AUTOPILOT_TEST_OUTPUT_TAIL:-80}"
  local trimmed_output
  trimmed_output="$(echo "$test_output" | tail -n "$tail_lines")"

  cat <<EOF
## Task ${task_number} — Failing Tests on PR #${pr_number}

**Branch:** \`${branch_name}\`

### Test Output (last ${tail_lines} lines)

\`\`\`
${trimmed_output}
\`\`\`

### Instructions

1. Read the test output and understand what is failing.
2. Read the relevant test files and source code.
3. Fix the root cause — do not weaken assertions.
4. Commit with \`fix:\` prefix after each fix.
5. Run the full test suite after each fix.
6. Push your commits.
EOF
}

# Spawn a fix-tests agent to address test failures.
run_fix_tests() {
  local project_dir="${1:-.}"
  local task_number="$2"
  local pr_number="$3"
  local test_output="$4"

  local timeout_fix_tests="${AUTOPILOT_TIMEOUT_FIX_TESTS:-600}"
  local config_dir="${AUTOPILOT_CODER_CONFIG_DIR:-}"
  local branch_name
  branch_name="$(build_branch_name "$task_number")"

  # Build user prompt with test output.
  local user_prompt
  user_prompt="$(build_fix_tests_prompt "$project_dir" "$task_number" \
    "$pr_number" "$test_output" "$branch_name")"

  # Read system prompt from fix-tests.md.
  local system_prompt
  system_prompt="$(_read_prompt_file "${_POSTFIX_PROMPTS_DIR}/fix-tests.md" \
    "$project_dir")" || {
    log_msg "$project_dir" "ERROR" "Failed to read fix-tests prompt"
    return 1
  }

  # Install hooks before spawning.
  install_hooks "$project_dir" "$config_dir" || {
    log_msg "$project_dir" "WARNING" "Failed to install hooks for fix-tests agent"
  }

  log_msg "$project_dir" "INFO" \
    "Spawning fix-tests agent for task ${task_number} (timeout=${timeout_fix_tests}s)"

  # Run Claude with system + user prompt.
  local output_file exit_code=0
  output_file="$(run_claude "$timeout_fix_tests" "$user_prompt" "$config_dir" \
    "--system-prompt" "$system_prompt")" || exit_code=$?

  # Clean up hooks.
  remove_hooks "$project_dir" "$config_dir" || {
    log_msg "$project_dir" "WARNING" "Failed to remove hooks after fix-tests agent"
  }

  _log_agent_result "$project_dir" "FixTests" "$task_number" \
    "$exit_code" "$output_file" "PR #${pr_number}"

  echo "$output_file"
  return "$exit_code"
}

# --- Post-Fix Verification ---

# Run post-fix verification after fixer completes.
# Checks fixer pushed, runs tests, spawns fix-tests agent on failure.
run_postfix_verification() {
  local project_dir="${1:-.}"
  local task_number="$2"
  local pr_number="$3"
  local sha_before="${4:-}"

  local branch_name
  branch_name="$(build_branch_name "$task_number")"

  # Step 1: Verify fixer pushed new commits.
  if ! verify_fixer_push "$project_dir" "$branch_name" "$sha_before"; then
    log_msg "$project_dir" "WARNING" \
      "Fixer did not push for task ${task_number} — proceeding with tests anyway"
  fi

  # Step 2: Pull latest changes before running tests.
  _pull_latest "$project_dir" "$branch_name"

  # Step 3: Run test gate.
  local test_exit=0
  local test_output
  test_output="$(_run_postfix_tests "$project_dir")" || test_exit=$?

  if [[ "$test_exit" -eq "$TESTGATE_PASS" ]] || \
     [[ "$test_exit" -eq "$TESTGATE_SKIP" ]] || \
     [[ "$test_exit" -eq "$TESTGATE_ALREADY_VERIFIED" ]]; then
    log_msg "$project_dir" "INFO" \
      "Post-fix tests passed for task ${task_number}"
    return "$POSTFIX_PASS"
  fi

  # Step 4: Tests failed — check test fix retry budget.
  local retries
  retries="$(get_test_fix_retries "$project_dir")"
  local max_retries="${AUTOPILOT_MAX_TEST_FIX_RETRIES:-3}"

  if [[ "$retries" -ge "$max_retries" ]]; then
    log_msg "$project_dir" "ERROR" \
      "Test fix retries exhausted (${retries}/${max_retries}) for task ${task_number}"
    return "$POSTFIX_FAIL"
  fi

  # Step 5: Spawn fix-tests agent.
  increment_test_fix_retries "$project_dir"
  log_msg "$project_dir" "INFO" \
    "Spawning fix-tests agent (attempt $((retries + 1))/${max_retries})"

  local fix_exit=0
  run_fix_tests "$project_dir" "$task_number" "$pr_number" \
    "$test_output" || fix_exit=$?

  if [[ "$fix_exit" -ne 0 ]]; then
    log_msg "$project_dir" "WARNING" \
      "Fix-tests agent exited with code ${fix_exit} for task ${task_number}"
  fi

  # Step 6: Re-run tests after fix-tests agent.
  _pull_latest "$project_dir" "$branch_name"
  local retest_exit=0
  _run_postfix_tests "$project_dir" >/dev/null 2>&1 || retest_exit=$?

  if [[ "$retest_exit" -eq "$TESTGATE_PASS" ]] || \
     [[ "$retest_exit" -eq "$TESTGATE_SKIP" ]] || \
     [[ "$retest_exit" -eq "$TESTGATE_ALREADY_VERIFIED" ]]; then
    log_msg "$project_dir" "INFO" \
      "Tests passed after fix-tests agent for task ${task_number}"
    return "$POSTFIX_PASS"
  fi

  log_msg "$project_dir" "WARNING" \
    "Tests still failing after fix-tests agent for task ${task_number}"
  return "$POSTFIX_FAIL"
}

# --- Internal Helpers ---

# Pull latest changes for the branch.
_pull_latest() {
  local project_dir="$1"
  local branch_name="$2"

  git -C "$project_dir" fetch origin "$branch_name" 2>/dev/null || {
    log_msg "$project_dir" "WARNING" "Failed to fetch branch ${branch_name}"
    return 0
  }

  git -C "$project_dir" checkout "$branch_name" 2>/dev/null || true
  git -C "$project_dir" reset --hard "origin/${branch_name}" 2>/dev/null || {
    log_msg "$project_dir" "WARNING" "Failed to reset to origin/${branch_name}"
    return 0
  }
}

# Run the test gate and capture output. Returns testgate exit code.
_run_postfix_tests() {
  local project_dir="${1:-.}"

  # Clear any stale SHA verification flag before running.
  clear_hook_sha_flag "$project_dir"

  run_test_gate "$project_dir"
}
