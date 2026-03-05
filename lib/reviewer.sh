#!/usr/bin/env bash
# Reviewer agent for Autopilot — diff fetching and parallel review execution.
# Fetches PR diff, guards against oversized diffs, spawns one Claude per
# reviewer persona in parallel, and collects results.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_REVIEWER_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_REVIEWER_LOADED=1

# Source dependencies.
# shellcheck source=lib/config.sh
source "${BASH_SOURCE[0]%/*}/config.sh"
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"
# shellcheck source=lib/claude.sh
source "${BASH_SOURCE[0]%/*}/claude.sh"

# Directory where reviewers/ persona files live.
_REVIEWER_LIB_DIR="${BASH_SOURCE[0]%/*}"
_REVIEWER_PERSONAS_DIR="${_REVIEWER_LIB_DIR}/../reviewers"

# --- Repo Slug ---

# Derive OWNER/REPO slug from the git remote URL.
_reviewer_get_repo_slug() {
  local project_dir="${1:-.}"
  local url
  url="$(git -C "$project_dir" remote get-url origin 2>/dev/null)" || return 1

  url="${url%.git}"
  if [[ "$url" =~ github\.com[:/]([^/]+/[^/]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

# --- Diff Fetching ---

# Build a metadata header for the diff (PR number, branch, repo).
_build_diff_header() {
  local pr_number="$1"
  local branch_name="$2"
  local repo="$3"

  cat <<EOF
# PR #${pr_number} — Code Review

**Repository:** ${repo}
**Branch:** ${branch_name}
**PR Number:** ${pr_number}

---

EOF
}

# Fetch the PR diff and write it to a temp file with a metadata header.
fetch_pr_diff() {
  local project_dir="${1:-.}"
  local pr_number="$2"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"
  local max_diff_bytes="${AUTOPILOT_MAX_DIFF_BYTES:-500000}"

  local repo
  repo="$(_reviewer_get_repo_slug "$project_dir")" || {
    log_msg "$project_dir" "ERROR" "Could not determine repo slug for PR #${pr_number}"
    return 1
  }

  local branch_name
  branch_name="$(timeout "$timeout_gh" gh pr view "$pr_number" \
    --repo "$repo" --json headRefName --jq '.headRefName' 2>/dev/null)" || {
    log_msg "$project_dir" "ERROR" "Could not fetch branch name for PR #${pr_number}"
    return 1
  }

  # Fetch the raw diff.
  local raw_diff
  raw_diff="$(timeout "$timeout_gh" gh pr diff "$pr_number" \
    --repo "$repo" 2>/dev/null)" || {
    log_msg "$project_dir" "ERROR" "Failed to fetch diff for PR #${pr_number}"
    return 1
  }

  # Guard against oversized diffs.
  local diff_bytes
  diff_bytes="$(printf '%s' "$raw_diff" | wc -c | tr -d ' ')"
  if [[ "$diff_bytes" -gt "$max_diff_bytes" ]]; then
    log_msg "$project_dir" "WARNING" \
      "PR #${pr_number} diff too large (${diff_bytes} bytes > ${max_diff_bytes} max)"
    return 2
  fi

  # Write header + diff to a temp file.
  local diff_file
  diff_file="$(mktemp "${TMPDIR:-/tmp}/autopilot-diff.XXXXXX")"

  _build_diff_header "$pr_number" "$branch_name" "$repo" > "$diff_file"
  printf '%s\n' "$raw_diff" >> "$diff_file"

  log_msg "$project_dir" "INFO" \
    "Fetched diff for PR #${pr_number} (${diff_bytes} bytes)"

  echo "$diff_file"
}

# --- Persona Helpers ---

# Parse AUTOPILOT_REVIEWERS into a newline-separated list of persona names.
parse_reviewer_list() {
  local reviewers="${AUTOPILOT_REVIEWERS:-general,dry,performance,security,design}"
  echo "$reviewers" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Read a reviewer persona prompt file by name.
_read_persona_file() {
  local persona_name="$1"
  local persona_file="${_REVIEWER_PERSONAS_DIR}/${persona_name}.md"

  if [[ ! -f "$persona_file" ]]; then
    return 1
  fi

  cat "$persona_file"
}

# --- Single Reviewer Execution ---

# Run a single reviewer Claude call with diff piped via stdin.
_run_single_reviewer() {
  local project_dir="$1"
  local persona_name="$2"
  local diff_file="$3"
  local timeout_claude="${4:-450}"
  local config_dir="${5:-}"

  # Read persona prompt.
  local persona_prompt
  persona_prompt="$(_read_persona_file "$persona_name")" || {
    log_msg "$project_dir" "ERROR" \
      "Persona file not found: ${persona_name}.md"
    return 1
  }

  local output_file
  output_file="$(mktemp "${TMPDIR:-/tmp}/autopilot-review-${persona_name}.XXXXXX")"
  local error_file="${output_file}.err"

  # Build the Claude command.
  local -a _BASE_CMD_ARGS=()
  _build_base_cmd_args
  local -a cmd_args=("${_BASE_CMD_ARGS[@]}")

  # Add system prompt with persona.
  cmd_args+=("--system-prompt" "$persona_prompt")

  # Append --print with instruction to review the piped diff.
  cmd_args+=("--print" "Review the following PR diff. Output your findings or NO_ISSUES_FOUND.")

  local exit_code=0

  # Run with diff piped via stdin for large diff support.
  (
    unset CLAUDECODE
    if [[ -n "$config_dir" ]]; then
      export CLAUDE_CONFIG_DIR="$config_dir"
    fi
    timeout "$timeout_claude" "${cmd_args[@]}" < "$diff_file"
  ) > "$output_file" 2>"$error_file" || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    log_msg "$project_dir" "INFO" "Reviewer '${persona_name}' completed"
  elif [[ "$exit_code" -eq 124 ]]; then
    log_msg "$project_dir" "WARNING" "Reviewer '${persona_name}' timed out"
  else
    log_msg "$project_dir" "ERROR" \
      "Reviewer '${persona_name}' failed (exit=${exit_code})"
  fi

  # Output file path on stdout for caller to collect.
  echo "$output_file"
  return "$exit_code"
}

# --- Parallel Review Execution ---

# Run all configured reviewers in parallel against a PR diff.
run_reviewers() {
  local project_dir="${1:-.}"
  local pr_number="$2"
  local diff_file="$3"

  local timeout_reviewer="${AUTOPILOT_TIMEOUT_REVIEWER:-600}"
  local timeout_claude="${AUTOPILOT_TIMEOUT_REVIEWER_CLAUDE:-450}"
  local config_dir="${AUTOPILOT_REVIEWER_CONFIG_DIR:-}"

  # Parse the configured reviewer list.
  local -a personas=()
  local persona
  while IFS= read -r persona; do
    [[ -z "$persona" ]] && continue
    personas+=("$persona")
  done < <(parse_reviewer_list)

  if [[ ${#personas[@]} -eq 0 ]]; then
    log_msg "$project_dir" "WARNING" "No reviewer personas configured"
    return 0
  fi

  log_msg "$project_dir" "INFO" \
    "Spawning ${#personas[@]} reviewers for PR #${pr_number}: ${personas[*]}"

  # Arrays to track background PIDs.
  local -a pids=()
  local -a persona_names=()

  # Spawn each reviewer in the background.
  local result_dir
  result_dir="$(mktemp -d "${TMPDIR:-/tmp}/autopilot-reviews.XXXXXX")"

  for persona in "${personas[@]}"; do
    _spawn_reviewer_bg "$project_dir" "$persona" "$diff_file" \
      "$timeout_claude" "$config_dir" "$result_dir" &
    pids+=($!)
    persona_names+=("$persona")
  done

  # Wait for all reviewers with outer timeout.
  # shellcheck disable=SC2034  # results is used via nameref in called functions
  local -a results=()
  _wait_for_reviewers "$timeout_reviewer" results \
    "${pids[@]}" -- "${persona_names[@]}"

  # Collect output files from the result directory.
  _collect_review_results "$project_dir" "$result_dir" results

  log_msg "$project_dir" "INFO" \
    "All reviewers completed for PR #${pr_number}"

  # Output the result directory path.
  echo "$result_dir"
}

# Spawn a single reviewer in the background, saving output path to result_dir.
_spawn_reviewer_bg() {
  local project_dir="$1"
  local persona_name="$2"
  local diff_file="$3"
  local timeout_claude="$4"
  local config_dir="$5"
  local result_dir="$6"

  local output_file exit_code=0
  output_file="$(_run_single_reviewer "$project_dir" "$persona_name" \
    "$diff_file" "$timeout_claude" "$config_dir")" || exit_code=$?

  # Write result metadata to the result directory.
  local meta_file="${result_dir}/${persona_name}.meta"
  printf '%s\n%s\n' "$output_file" "$exit_code" > "$meta_file"
}

# Wait for background reviewer PIDs with an outer timeout.
_wait_for_reviewers() {
  local outer_timeout="$1"
  local -n _wait_results="$2"
  shift 2

  # Split args at "--" into pids and names.
  local -a pids=()
  local -a names=()
  local in_names=false
  for arg in "$@"; do
    if [[ "$arg" == "--" ]]; then
      in_names=true
      continue
    fi
    if [[ "$in_names" == true ]]; then
      names+=("$arg")
    else
      pids+=("$arg")
    fi
  done

  local start_time
  start_time="$(date +%s)"

  local idx=0
  for pid in "${pids[@]}"; do
    local elapsed
    elapsed="$(( $(date +%s) - start_time ))"
    local remaining="$(( outer_timeout - elapsed ))"

    if [[ "$remaining" -le 0 ]]; then
      # Outer timeout reached — kill remaining reviewers.
      kill "$pid" 2>/dev/null || true
      _wait_results+=("${names[$idx]}:timeout")
    else
      # Wait with a polling loop respecting the outer timeout.
      if _wait_pid_timeout "$pid" "$remaining"; then
        _wait_results+=("${names[$idx]}:done")
      else
        kill "$pid" 2>/dev/null || true
        _wait_results+=("${names[$idx]}:timeout")
      fi
    fi
    idx=$((idx + 1))
  done
}

# Wait for a single PID with a timeout. Returns 0 on exit, 1 on timeout.
_wait_pid_timeout() {
  local pid="$1"
  local max_seconds="$2"
  local waited=0

  while [[ "$waited" -lt "$max_seconds" ]]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done

  return 1
}

# Collect review results from the result directory.
_collect_review_results() {
  local project_dir="$1"
  local result_dir="$2"
  local -n _collect_results="$3"

  local meta_file
  for meta_file in "$result_dir"/*.meta; do
    [[ -f "$meta_file" ]] || continue

    local persona_name
    persona_name="$(basename "$meta_file" .meta)"
    local output_file exit_code
    {
      read -r output_file
      read -r exit_code
    } < "$meta_file"

    _collect_results+=("${persona_name}:${exit_code}:${output_file}")

    if [[ "$exit_code" -eq 0 ]]; then
      log_msg "$project_dir" "DEBUG" \
        "Reviewer '${persona_name}' result: success (${output_file})"
    else
      log_msg "$project_dir" "WARNING" \
        "Reviewer '${persona_name}' result: exit=${exit_code} (${output_file})"
    fi
  done
}

# --- Result Parsing ---

# Extract the review text from a reviewer's JSON output file.
extract_review_text() {
  local output_file="$1"
  extract_claude_text "$output_file"
}

# Check if a review response is the "no issues" sentinel.
is_clean_review() {
  local review_text="$1"
  [[ "$review_text" == *"NO_ISSUES_FOUND"* ]]
}
