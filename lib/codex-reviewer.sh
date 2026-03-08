#!/usr/bin/env bash
# Codex reviewer backend for Autopilot — runs OpenAI Codex as an optional
# reviewer, parses structured JSON findings, and posts inline PR comments.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_CODEX_REVIEWER_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_CODEX_REVIEWER_LOADED=1

# Source dependencies.
# shellcheck source=lib/config.sh
source "${BASH_SOURCE[0]%/*}/config.sh"
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"
# shellcheck source=lib/git-ops.sh
source "${BASH_SOURCE[0]%/*}/git-ops.sh"

# Path to the output schema file.
_CODEX_LIB_DIR="${BASH_SOURCE[0]%/*}"
_CODEX_SCHEMA_FILE="${_CODEX_LIB_DIR}/../examples/codex-output-schema.json"

# --- Availability ---

# Check if the codex CLI is installed.
is_codex_available() {
  command -v codex >/dev/null 2>&1
}

# --- Prompt Construction ---

# Build the review prompt for Codex from a diff file.
_build_codex_prompt() {
  local diff_file="$1"

  cat <<'PROMPT'
You are a code reviewer. Review the following PR diff for correctness, bugs,
and design issues. For each finding, provide a title, detailed body explaining
the issue and fix, the file path and line range, and a confidence score (0-1).

If you find no issues, return {"findings": []}.

--- PR Diff ---

PROMPT
  cat "$diff_file"
}

# --- Codex Execution ---

# Run codex exec with the output schema and return the JSON output file path.
run_codex_review() {
  local project_dir="$1"
  local diff_file="$2"
  local timeout_seconds="${3:-450}"

  if ! is_codex_available; then
    log_msg "$project_dir" "INFO" \
      "Codex CLI not installed — skipping Codex review"
    return 1
  fi

  local codex_model="${AUTOPILOT_CODEX_MODEL:-o4-mini}"

  local prompt
  prompt="$(_build_codex_prompt "$diff_file")"

  local output_file
  output_file="$(mktemp "${TMPDIR:-/tmp}/autopilot-codex-review.XXXXXX")"
  local error_file="${output_file}.err"

  local exit_code=0
  timeout "$timeout_seconds" codex exec \
    --model "$codex_model" \
    --output-schema "$(cat "$_CODEX_SCHEMA_FILE")" \
    "$prompt" \
    > "$output_file" 2>"$error_file" || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    log_msg "$project_dir" "INFO" "Codex review completed"
  elif [[ "$exit_code" -eq 124 ]]; then
    log_msg "$project_dir" "WARNING" "Codex review timed out"
  else
    log_msg "$project_dir" "ERROR" \
      "Codex review failed (exit=${exit_code})"
  fi

  echo "$output_file"
  return "$exit_code"
}

# --- Finding Extraction ---

# Extract findings from Codex JSON output, filtered by confidence threshold.
# Outputs one JSON object per line for each qualifying finding.
extract_codex_findings() {
  local output_file="$1"
  local min_confidence="${AUTOPILOT_CODEX_MIN_CONFIDENCE:-0.7}"

  if [[ ! -f "$output_file" ]] || [[ ! -s "$output_file" ]]; then
    return 1
  fi

  jq -c --argjson min "$min_confidence" \
    '.findings[] | select(.confidence_score >= $min)' \
    "$output_file" 2>/dev/null
}

# Count the number of findings above the confidence threshold.
count_codex_findings() {
  local output_file="$1"
  local min_confidence="${AUTOPILOT_CODEX_MIN_CONFIDENCE:-0.7}"

  if [[ ! -f "$output_file" ]] || [[ ! -s "$output_file" ]]; then
    echo "0"
    return 0
  fi

  jq --argjson min "$min_confidence" \
    '[.findings[] | select(.confidence_score >= $min)] | length' \
    "$output_file" 2>/dev/null || echo "0"
}

# --- PR Comment Posting ---

# Post a single inline comment on a PR for a Codex finding.
_post_codex_inline_comment() {
  local project_dir="$1"
  local pr_number="$2"
  local commit_sha="$3"
  local file_path="$4"
  local line="$5"
  local comment_body="$6"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"

  local repo
  repo="$(get_repo_slug "$project_dir")" || return 1

  timeout "$timeout_gh" gh api \
    "repos/${repo}/pulls/${pr_number}/comments" \
    -f body="$comment_body" \
    -f commit_id="$commit_sha" \
    -f path="$file_path" \
    -F line="$line" \
    >/dev/null 2>&1 || {
    log_msg "$project_dir" "ERROR" \
      "Failed to post Codex inline comment on ${file_path}:${line}"
    return 1
  }
}

# Post all qualifying Codex findings as inline PR comments.
post_codex_findings() {
  local project_dir="$1"
  local pr_number="$2"
  local commit_sha="$3"
  local output_file="$4"

  local finding_count
  finding_count="$(count_codex_findings "$output_file")"

  if [[ "$finding_count" -eq 0 ]]; then
    log_msg "$project_dir" "INFO" \
      "Codex review: no findings above confidence threshold"
    return 0
  fi

  log_msg "$project_dir" "INFO" \
    "Posting ${finding_count} Codex findings on PR #${pr_number}"

  local posted=0
  local failed=0
  local finding

  while IFS= read -r finding; do
    [[ -z "$finding" ]] && continue

    local title body file_path line_start
    title="$(jq -r '.title' <<< "$finding")"
    body="$(jq -r '.body' <<< "$finding")"
    file_path="$(jq -r '.code_location.absolute_file_path' <<< "$finding")"
    line_start="$(jq -r '.code_location.line_range.start' <<< "$finding")"

    local comment="🔍 **Codex Review:** ${title}

${body}"

    if _post_codex_inline_comment "$project_dir" "$pr_number" \
        "$commit_sha" "$file_path" "$line_start" "$comment"; then
      posted=$((posted + 1))
    else
      failed=$((failed + 1))
    fi
  done < <(extract_codex_findings "$output_file")

  log_msg "$project_dir" "INFO" \
    "Codex posting done: posted=${posted} failed=${failed}"
  return 0
}

# --- Orchestrator ---

# Run the full Codex review pipeline: execute, extract, post.
run_codex_review_pipeline() {
  local project_dir="$1"
  local pr_number="$2"
  local diff_file="$3"
  local commit_sha="$4"
  local timeout_codex="${5:-450}"

  local output_file exit_code=0
  output_file="$(run_codex_review "$project_dir" "$diff_file" \
    "$timeout_codex")" || exit_code=$?

  # If codex is not available (exit 1 from is_codex_available check), skip.
  if [[ "$exit_code" -ne 0 ]]; then
    return "$exit_code"
  fi

  post_codex_findings "$project_dir" "$pr_number" "$commit_sha" "$output_file"
  local post_rc=$?

  # Clean up output file.
  rm -f "$output_file" "${output_file}.err"

  return "$post_rc"
}
