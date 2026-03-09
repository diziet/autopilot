#!/usr/bin/env bash
# Reviewer posting for Autopilot — comment formatting, dedup, and clean-review handling.
# Formats review comments with display name and SHA tag, posts via gh pr comment,
# tracks reviewed SHAs in .autopilot/reviewed.json, and detects all-clean results.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_REVIEWER_POSTING_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_REVIEWER_POSTING_LOADED=1

# Source dependencies.
# shellcheck source=lib/reviewer.sh
source "${BASH_SOURCE[0]%/*}/reviewer.sh"

# --- Display Names ---

# Convert a persona file name to a human-readable display name.
_persona_display_name() {
  local persona_name="$1"

  case "$persona_name" in
    general)     echo "General" ;;
    security)    echo "Security" ;;
    performance) echo "Performance" ;;
    dry)         echo "DRY" ;;
    design)      echo "Design" ;;
    *)           echo "$persona_name" ;;
  esac
}

# --- Comment Formatting ---

# Format a review comment with reviewer display name and SHA tag.
format_review_comment() {
  local persona_name="$1"
  local head_sha="$2"
  local review_text="$3"

  local display_name
  display_name="$(_persona_display_name "$persona_name")"

  local short_sha="${head_sha:0:7}"

  cat <<EOF
### 🔍 ${display_name} Review

<!-- autopilot:reviewer=${persona_name}:sha=${head_sha} -->

${review_text}

---
*Reviewed at commit ${short_sha}*
EOF
}

# --- Comment Posting ---

# Post a review comment on a PR via gh pr comment.
post_pr_comment() {
  local project_dir="${1:-.}"
  local pr_number="$2"
  local comment_body="$3"
  local timeout_gh="${AUTOPILOT_TIMEOUT_GH:-30}"

  local repo
  repo="$(get_repo_slug "$project_dir")" || {
    log_msg "$project_dir" "ERROR" "Could not determine repo slug for posting"
    return 1
  }

  timeout "$timeout_gh" gh pr comment "$pr_number" \
    --repo "$repo" \
    --body "$comment_body" >/dev/null 2>&1 || {
    log_msg "$project_dir" "ERROR" \
      "Failed to post review comment on PR #${pr_number}"
    return 1
  }

  log_msg "$project_dir" "INFO" "Posted review comment on PR #${pr_number}"
}

# --- Reviewed SHA Tracking ---

# Read the reviewed.json file. Outputs JSON content or empty object.
_read_reviewed_json() {
  local project_dir="${1:-.}"
  local json_file="${project_dir}/.autopilot/reviewed.json"

  if [[ -f "$json_file" ]]; then
    cat "$json_file"
  else
    echo '{}'
  fi
}

# Atomically write reviewed.json content.
_write_reviewed_json() {
  local project_dir="${1:-.}"
  local json_content="$2"
  local json_file="${project_dir}/.autopilot/reviewed.json"

  mkdir -p "${project_dir}/.autopilot"

  local tmp_file="${json_file}.tmp.$$"
  echo "$json_content" > "$tmp_file"
  mv -f "$tmp_file" "$json_file"
}

# Get the last-reviewed SHA for a persona on a PR.
get_reviewed_sha() {
  local project_dir="${1:-.}"
  local pr_number="$2"
  local persona_name="$3"

  local json_content
  json_content="$(_read_reviewed_json "$project_dir")"

  local pr_key="pr_${pr_number}"
  jq -r ".\"${pr_key}\".\"${persona_name}\".sha // empty" <<< "$json_content" 2>/dev/null
}

# Record a reviewed SHA and clean status for a persona on a PR.
set_reviewed_sha() {
  local project_dir="${1:-.}"
  local pr_number="$2"
  local persona_name="$3"
  local sha="$4"
  local is_clean="${5:-false}"

  local json_content
  json_content="$(_read_reviewed_json "$project_dir")"

  local pr_key="pr_${pr_number}"
  local clean_bool
  if [[ "$is_clean" == "true" ]]; then clean_bool="true"; else clean_bool="false"; fi

  local updated
  updated="$(jq --arg pk "$pr_key" --arg pn "$persona_name" --arg s "$sha" \
    --argjson c "$clean_bool" \
    '.[$pk][$pn] = {"sha": $s, "is_clean": $c}' <<< "$json_content" 2>/dev/null)" || {
    # If the pr key doesn't exist yet, create it.
    updated="$(jq --arg pk "$pr_key" --arg pn "$persona_name" --arg s "$sha" \
      --argjson c "$clean_bool" \
      '. + {($pk): {($pn): {"sha": $s, "is_clean": $c}}}' <<< "$json_content" 2>/dev/null)" || {
      log_msg "$project_dir" "ERROR" "Failed to update reviewed.json"
      return 1
    }
  }

  _write_reviewed_json "$project_dir" "$updated"
}

# Check if a persona has already reviewed this SHA on a PR.
has_been_reviewed() {
  local project_dir="${1:-.}"
  local pr_number="$2"
  local persona_name="$3"
  local sha="$4"

  local reviewed_sha
  reviewed_sha="$(get_reviewed_sha "$project_dir" "$pr_number" "$persona_name")"
  [[ "$reviewed_sha" == "$sha" ]]
}

# Check if a persona's stored review was clean (no issues found).
was_review_clean() {
  local project_dir="${1:-.}"
  local pr_number="$2"
  local persona_name="$3"

  local json_content
  json_content="$(_read_reviewed_json "$project_dir")"

  local pr_key="pr_${pr_number}"
  local is_clean
  is_clean="$(jq -r ".\"${pr_key}\".\"${persona_name}\".is_clean // false" \
    <<< "$json_content" 2>/dev/null)"
  [[ "$is_clean" == "true" ]]
}

# --- Clean Review Detection ---

# Check if all successful reviewers returned the "no issues" sentinel.
# Sets _ALL_REVIEWS_CLEAN=true/false as a side effect.
all_reviews_clean() {
  local result_dir="$1"

  _ALL_REVIEWS_CLEAN=false

  collect_review_results "$result_dir"

  if [[ ${#_REVIEW_PERSONAS[@]} -eq 0 ]]; then
    return 1
  fi

  local i review_text
  for (( i=0; i<${#_REVIEW_PERSONAS[@]}; i++ )); do
    # Skip failed/timed-out reviewers — they are not "clean".
    if [[ "${_REVIEW_EXITS[$i]}" -ne 0 ]]; then
      return 1
    fi

    # Extract text and check for sentinel.
    local output_file="${_REVIEW_FILES[$i]}"
    if [[ -z "$output_file" ]] || [[ ! -f "$output_file" ]]; then
      return 1
    fi

    review_text="$(extract_review_text "$output_file")" || return 1
    if ! is_clean_review "$review_text"; then
      return 1
    fi
  done

  _ALL_REVIEWS_CLEAN=true
  return 0
}

# --- Orchestrator ---

# Post review comments for all reviewers, skipping clean/duplicate reviews.
# Returns 0 on success. Sets _ALL_REVIEWS_CLEAN as side effect.
post_review_comments() {
  local project_dir="${1:-.}"
  local pr_number="$2"
  local head_sha="$3"
  local result_dir="$4"

  collect_review_results "$result_dir"

  if [[ ${#_REVIEW_PERSONAS[@]} -eq 0 ]]; then
    log_msg "$project_dir" "WARNING" "No review results to post"
    _ALL_REVIEWS_CLEAN=false
    return 0
  fi

  local clean_count=0
  local total_count=0
  local posted_count=0
  local skipped_count=0

  local i
  for (( i=0; i<${#_REVIEW_PERSONAS[@]}; i++ )); do
    local persona="${_REVIEW_PERSONAS[$i]}"
    local exit_code="${_REVIEW_EXITS[$i]}"
    local output_file="${_REVIEW_FILES[$i]}"
    total_count=$((total_count + 1))

    # Skip failed reviewers.
    if [[ "$exit_code" -ne 0 ]]; then
      log_msg "$project_dir" "WARNING" \
        "Skipping ${persona} review: exited with ${exit_code}"
      continue
    fi

    # Skip if already reviewed this SHA. Count stored clean status.
    if has_been_reviewed "$project_dir" "$pr_number" "$persona" "$head_sha"; then
      log_msg "$project_dir" "INFO" \
        "Skipping ${persona} review: already reviewed SHA ${head_sha:0:7}"
      skipped_count=$((skipped_count + 1))
      if was_review_clean "$project_dir" "$pr_number" "$persona"; then
        clean_count=$((clean_count + 1))
      fi
      continue
    fi

    # Extract review text.
    local review_text=""
    if [[ -n "$output_file" ]] && [[ -f "$output_file" ]]; then
      review_text="$(extract_review_text "$output_file")" || true
    fi

    if [[ -z "$review_text" ]]; then
      log_msg "$project_dir" "WARNING" \
        "Skipping ${persona} review: empty response"
      continue
    fi

    # Determine if this is a clean review and set the display text accordingly.
    local is_clean="false"
    local display_text="$review_text"
    if is_clean_review "$review_text"; then
      is_clean="true"
      display_text="No issues found."
    fi

    # Format and post the comment. Only record SHA on successful post.
    local comment
    comment="$(format_review_comment "$persona" "$head_sha" "$display_text")"
    if post_pr_comment "$project_dir" "$pr_number" "$comment"; then
      set_reviewed_sha "$project_dir" "$pr_number" "$persona" "$head_sha" "$is_clean"
      posted_count=$((posted_count + 1))
      if [[ "$is_clean" == "true" ]]; then
        clean_count=$((clean_count + 1))
      fi
    else
      log_msg "$project_dir" "ERROR" \
        "Failed to post ${persona} review on PR #${pr_number}"
    fi
  done

  # Determine if all reviews are clean (includes dedup-skipped with stored status).
  _ALL_REVIEWS_CLEAN=false
  if [[ "$total_count" -gt 0 ]] && [[ "$clean_count" -eq "$total_count" ]]; then
    _ALL_REVIEWS_CLEAN=true
  fi

  log_msg "$project_dir" "INFO" \
    "Review posting done: posted=${posted_count} clean=${clean_count} skipped=${skipped_count}"
}
