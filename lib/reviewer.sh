#!/usr/bin/env bash
# Reviewer agent for Autopilot — diff fetching and parallel review execution.

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
# shellcheck source=lib/git-ops.sh
source "${BASH_SOURCE[0]%/*}/git-ops.sh"
# shellcheck source=lib/gh.sh
source "${BASH_SOURCE[0]%/*}/gh.sh"

# Directory where reviewers/ persona files live.
_REVIEWER_LIB_DIR="${BASH_SOURCE[0]%/*}"
_REVIEWER_PERSONAS_DIR="${_REVIEWER_LIB_DIR}/../reviewers"

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
  repo="$(get_repo_slug "$project_dir")" || {
    log_msg "$project_dir" "ERROR" "Could not determine repo slug for PR #${pr_number}"
    return 1
  }

  local branch_name
  branch_name="$(_run_gh "$project_dir" timeout "$timeout_gh" gh pr view "$pr_number" \
    --repo "$repo" --json headRefName --jq '.headRefName')" || {
    log_msg "$project_dir" "ERROR" "Could not fetch branch name for PR #${pr_number}"
    return 1
  }

  # Fetch the raw diff.
  local raw_diff
  raw_diff="$(_run_gh "$project_dir" timeout "$timeout_gh" gh pr diff "$pr_number" \
    --repo "$repo")" || {
    log_msg "$project_dir" "ERROR" "Failed to fetch diff for PR #${pr_number}"
    return 1
  }

  # Guard against oversized diffs.
  local diff_bytes
  diff_bytes=$(printf '%s' "$raw_diff" | wc -c | tr -d ' ')
  if [[ "$diff_bytes" -gt "$max_diff_bytes" ]]; then
    log_msg "$project_dir" "WARNING" \
      "PR #${pr_number} diff too large (${diff_bytes} bytes > ${max_diff_bytes} max)"

    # Build sampled diff for diff-reduction reviewer.
    # stdout is valid even on non-zero return — caller captures path via
    # command substitution before the || branch handles the exit code.
    local sampled_diff_file
    sampled_diff_file="$(mktemp "${TMPDIR:-/tmp}/autopilot-sampled-diff.XXXXXX")"
    {
      _build_diff_header "$pr_number" "$branch_name" "$repo"
      printf '\n## OVERSIZED DIFF\n\n'
      printf 'Total diff size: %s bytes (limit: %s bytes)\n\n' \
        "$diff_bytes" "$max_diff_bytes"
      printf '### Changed files:\n```\n'
      # Extract file list from raw_diff instead of a second gh API call.
      printf '%s' "$raw_diff" | grep '^diff --git' | \
        sed 's|^diff --git a/.* b/||' || true
      printf '```\n\n### Sampled diff (first ~200KB):\n```diff\n'
      printf '%s' "$raw_diff" | head -c 200000
      printf '\n```\n'
    } > "$sampled_diff_file"

    echo "$sampled_diff_file"
    return 3
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

# Parse AUTOPILOT_REVIEWERS into a newline-separated list of validated persona names.
# Rejects names with path traversal characters — only [a-z0-9_-] allowed.
parse_reviewer_list() {
  local reviewers="${AUTOPILOT_REVIEWERS:-general,dry,performance,security,design}"
  local name
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
      if [[ "$name" =~ ^[a-z0-9_-]+$ ]]; then
      echo "$name"
    fi
  done < <(echo "$reviewers" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
}

# Read a reviewer persona prompt file by name, stripping YAML frontmatter.
_read_persona_file() {
  local persona_name="$1"
  local persona_file="${_REVIEWER_PERSONAS_DIR}/${persona_name}.md"

  if [[ ! -f "$persona_file" ]]; then
    return 1
  fi

  # Strip YAML frontmatter (---...---) if present, returning only content.
  local in_frontmatter=false
  local past_frontmatter=false
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$past_frontmatter" == true ]]; then
      echo "$line"
      continue
    fi
    if [[ "$in_frontmatter" == false ]]; then
      if [[ "$line" == "---" ]]; then
        in_frontmatter=true
        continue
      else
        # No frontmatter — output everything from the start.
        past_frontmatter=true
        echo "$line"
        continue
      fi
    fi
    # Inside frontmatter — look for closing ---.
    if [[ "$line" == "---" ]]; then
      past_frontmatter=true
      continue
    fi
  done < "$persona_file"
}

# Check if a persona file has interactive setting in its frontmatter.
# Returns: 0 = interactive: true, 1 = interactive: false, 2 = no opinion (no frontmatter/key).
_persona_is_interactive() {
  local persona_name="$1"
  local persona_file="${_REVIEWER_PERSONAS_DIR}/${persona_name}.md"

  [[ -f "$persona_file" ]] || return 2

  # Read the file looking for YAML frontmatter (---...---).
  local in_frontmatter=false
  local line
  while IFS= read -r line; do
    if [[ "$in_frontmatter" == false ]]; then
      # First line must be --- to start frontmatter.
      if [[ "$line" == "---" ]]; then
        in_frontmatter=true
        continue
      else
        return 2  # No frontmatter.
      fi
    fi
    # End of frontmatter without finding the key.
    if [[ "$line" == "---" ]]; then
      return 2  # Key not present.
    fi
    # Check for interactive: true (case-insensitive value).
    if [[ "$line" =~ ^interactive:[[:space:]]*(true|TRUE|True)$ ]]; then
      return 0
    fi
    # Check for interactive: false (case-insensitive value).
    if [[ "$line" =~ ^interactive:[[:space:]]*(false|FALSE|False)$ ]]; then
      return 1
    fi
  done < "$persona_file"

  return 2
}

# --- Single Reviewer Execution ---

# Determine if a reviewer should run in interactive mode.
_is_interactive_reviewer() {
  local persona_name="$1"
  local global_interactive="${AUTOPILOT_REVIEWER_INTERACTIVE:-false}"

  # Per-persona override takes precedence (tri-state: 0=true, 1=false, 2=no opinion).
  local persona_rc=0
  _persona_is_interactive "$persona_name" || persona_rc=$?

  if [[ "$persona_rc" -eq 0 ]]; then
    return 0  # Persona explicitly opts in.
  elif [[ "$persona_rc" -eq 1 ]]; then
    return 1  # Persona explicitly opts out.
  fi

  # No per-persona opinion — fall back to global config.
  [[ "$global_interactive" == "true" ]]
}

# Run a single reviewer Claude call (print mode via stdin, or interactive mode via prompt).
_run_single_reviewer() {
  local project_dir="$1"
  local persona_name="$2"
  local diff_file="$3"
  local timeout_claude="${4:-450}"
  local config_dir="${5:-}"

  # Read persona prompt (frontmatter already stripped).
  local persona_prompt
  persona_prompt="$(_read_persona_file "$persona_name")" || {
    log_msg "$project_dir" "ERROR" \
      "Persona file not found: ${persona_name}.md"
    return 1
  }

  # Use the diff file as-is (augmented diff is built once by run_reviewers).
  local effective_diff="$diff_file"

  local output_file
  output_file="$(mktemp "${TMPDIR:-/tmp}/autopilot-review-${persona_name}.XXXXXX")"
  local error_file="${output_file}.err"

  # Build the Claude command.
  local -a _BASE_CMD_ARGS=()
  _build_base_cmd_args
  local -a cmd_args=("${_BASE_CMD_ARGS[@]}")

  # Add system prompt with persona.
  cmd_args+=("--system-prompt" "$persona_prompt")

  # Determine mode: interactive (tool access, no --print) or print (stdin pipe).
  local stdin_file="/dev/null"
  local prompt_file=""
  if _is_interactive_reviewer "$persona_name"; then
    # Interactive mode: omit --print so Claude gets full tool access.
    # Write diff to a temp file and reference it in a short prompt to avoid ARG_MAX.
    prompt_file="$(mktemp "${TMPDIR:-/tmp}/autopilot-diff-${persona_name}.XXXXXX")"
    cp "$effective_diff" "$prompt_file"
    cmd_args+=("Review the PR diff in ${prompt_file}. You have full tool access to explore the repo. Output your findings or NO_ISSUES_FOUND.")
    # Use interactive timeout only when the caller passed the default value.
    if [[ "${4:-}" == "" ]]; then
      timeout_claude="${AUTOPILOT_TIMEOUT_REVIEWER_INTERACTIVE:-300}"
    fi
  else
    # Print mode: pipe diff via stdin for large diff support.
    cmd_args+=("--print" "Review the following PR diff. Output your findings or NO_ISSUES_FOUND.")
    stdin_file="$effective_diff"
  fi

  local exit_code=0

  # shellcheck disable=SC2031,SC2030  # Intentional: export only in subshell
  (
    unset CLAUDECODE
    if [[ -n "$config_dir" ]]; then
      export CLAUDE_CONFIG_DIR="$config_dir"
    fi
    timeout "$timeout_claude" "${cmd_args[@]}" < "$stdin_file"
  ) > "$output_file" 2>"$error_file" || exit_code=$?

  # Clean up temp files if created.
  [[ -n "$prompt_file" ]] && rm -f "$prompt_file"

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
  local task_description="${4:-}"

  local timeout_reviewer="${AUTOPILOT_TIMEOUT_REVIEWER:-600}"
  local timeout_claude="${AUTOPILOT_TIMEOUT_REVIEWER_CLAUDE:-450}"
  local config_dir="${AUTOPILOT_REVIEWER_CONFIG_DIR:-}"

  # Parse the configured reviewer list (skip "codex" — handled separately).
  local -a personas=()
  local persona
  while IFS= read -r persona; do
    [[ -z "$persona" ]] && continue
    [[ "$persona" == "codex" ]] && continue
    personas+=("$persona")
  done < <(parse_reviewer_list)

  if [[ ${#personas[@]} -eq 0 ]]; then
    log_msg "$project_dir" "WARNING" "No reviewer personas configured"
    return 0
  fi

  log_msg "$project_dir" "INFO" \
    "Spawning ${#personas[@]} reviewers for PR #${pr_number}: ${personas[*]}"

  # Build augmented diff once if task description is available.
  local effective_diff="$diff_file"
  if [[ -n "$task_description" ]]; then
    effective_diff="$(mktemp "${TMPDIR:-/tmp}/autopilot-augmented-diff.XXXXXX")"
    {
      printf '%s\n' "## Task Description"
      printf '\n%s\n\n' "$task_description"
      printf '%s\n\n%s\n\n' "---" "## PR Diff"
      cat "$diff_file"
    } > "$effective_diff"
  fi

  # Arrays to track background PIDs.
  local -a pids=()
  local -a persona_names=()

  # Spawn each reviewer in the background.
  local result_dir
  result_dir="$(mktemp -d "${TMPDIR:-/tmp}/autopilot-reviews.XXXXXX")"

  for persona in "${personas[@]}"; do
    _spawn_reviewer_bg "$project_dir" "$persona" "$effective_diff" \
      "$timeout_claude" "$config_dir" "$result_dir" &
    pids+=($!)
    persona_names+=("$persona")
  done

  # Wait for all reviewers with outer timeout.
  _wait_for_reviewers "$timeout_reviewer" "$result_dir" \
    "${pids[@]}" -- "${persona_names[@]}"

  # Log results from the result directory.
  _log_review_results "$project_dir" "$result_dir"

  # Clean up augmented diff temp file if created.
  [[ "$effective_diff" != "$diff_file" ]] && rm -f "$effective_diff"

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
# Writes .meta files with exit code 124 for killed reviewers.
_wait_for_reviewers() {
  local outer_timeout="$1"
  local result_dir="$2"
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
      # Outer timeout reached — kill process group and write timeout meta.
      _kill_reviewer_group "$pid"
      _write_timeout_meta "$result_dir" "${names[$idx]}"
    else
      if _wait_pid_timeout "$pid" "$remaining"; then
        : # Process exited normally; .meta written by _spawn_reviewer_bg.
      else
        # Timed out — kill process group and write timeout meta.
        _kill_reviewer_group "$pid"
        _write_timeout_meta "$result_dir" "${names[$idx]}"
      fi
    fi
    idx=$((idx + 1))
  done
}

# Kill a reviewer and its child processes.
_kill_reviewer_group() {
  local pid="$1"
  # Kill direct child processes first, then the process itself.
  # Cannot use process group kill (kill -pgid) because background processes
  # inherit the parent's PGID, which would kill the caller too.
  local child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    kill "$child" 2>/dev/null || true
  done
  kill "$pid" 2>/dev/null || true
}

# Write a .meta file for a reviewer that was killed by the outer timeout.
_write_timeout_meta() {
  local result_dir="$1"
  local persona_name="$2"
  local meta_file="${result_dir}/${persona_name}.meta"

  # Only write if no .meta exists (process was killed before writing its own).
  if [[ ! -f "$meta_file" ]]; then
    printf '%s\n%s\n' "" "124" > "$meta_file"
  fi
}

# Wait for a single PID with a timeout. Returns 0 on exit, 1 on timeout.
# Polls with sleep 0.1 instead of sleep 1 to reduce wasted wait time.
_wait_pid_timeout() {
  local pid="$1"
  local max_seconds="$2"

  # Validate inputs are integers to prevent misuse.
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  [[ "$max_seconds" =~ ^[0-9]+$ ]] || return 1

  # Poll with 0.1s granularity — 10x less wasted time than sleep 1.
  local ticks=$(( max_seconds * 10 ))
  local i=0
  while [[ "$i" -lt "$ticks" ]]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done

  return 1
}

# Read review results from the result directory into parallel arrays.
# Sets _REVIEW_PERSONAS, _REVIEW_EXITS, _REVIEW_FILES arrays.
collect_review_results() {
  local result_dir="$1"

  _REVIEW_PERSONAS=()
  _REVIEW_EXITS=()
  _REVIEW_FILES=()

  local meta_file
  for meta_file in "$result_dir"/*.meta; do
    [[ -f "$meta_file" ]] || continue

    local persona_name
    persona_name="${meta_file##*/}"
    persona_name="${persona_name%.meta}"
    local output_file exit_code
    {
      read -r output_file
      read -r exit_code
    } < "$meta_file"

    _REVIEW_PERSONAS+=("$persona_name")
    _REVIEW_EXITS+=("$exit_code")
    _REVIEW_FILES+=("$output_file")
  done
}

# Log review results from the collected arrays.
_log_review_results() {
  local project_dir="$1"
  local result_dir="$2"

  collect_review_results "$result_dir"

  local i
  for (( i=0; i<${#_REVIEW_PERSONAS[@]}; i++ )); do
    if [[ "${_REVIEW_EXITS[$i]}" -eq 0 ]]; then
      log_msg "$project_dir" "DEBUG" \
        "Reviewer '${_REVIEW_PERSONAS[$i]}' result: success (${_REVIEW_FILES[$i]})"
    elif [[ "${_REVIEW_EXITS[$i]}" -eq 124 ]]; then
      log_msg "$project_dir" "WARNING" \
        "Reviewer '${_REVIEW_PERSONAS[$i]}' result: timeout"
    else
      log_msg "$project_dir" "WARNING" \
        "Reviewer '${_REVIEW_PERSONAS[$i]}' result: exit=${_REVIEW_EXITS[$i]} (${_REVIEW_FILES[$i]})"
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
