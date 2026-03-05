#!/usr/bin/env bash
# Session cache for Autopilot.
# Pre-warms Claude sessions with project context using content-hash
# memoization. Hashes project files (CLAUDE.md, context files) to detect
# changes and invalidate cache. Includes macOS-portable realpath shim.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_SESSION_CACHE_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_SESSION_CACHE_LOADED=1

# Source dependencies.
# shellcheck source=lib/config.sh
source "${BASH_SOURCE[0]%/*}/config.sh"
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"
# shellcheck source=lib/claude.sh
source "${BASH_SOURCE[0]%/*}/claude.sh"
# shellcheck source=lib/tasks.sh
source "${BASH_SOURCE[0]%/*}/tasks.sh"

# Cache subdirectory inside .autopilot/.
readonly _SESSION_CACHE_DIR="cache"
# Name of the content hash file within the cache dir.
readonly _SESSION_HASH_FILE="content.sha"
# Name of the prewarm result marker within the cache dir.
readonly _SESSION_WARM_MARKER="warm.marker"
# Timeout for prewarm Claude call (seconds).
readonly _SESSION_PREWARM_TIMEOUT=60

# --- Portable Realpath ---

# Resolve a path to its absolute canonical form.
# Uses native realpath if available, falls back to a pure-bash shim.
portable_realpath() {
  local target="$1"

  if command -v realpath >/dev/null 2>&1; then
    realpath "$target" 2>/dev/null && return 0
    # Native realpath may fail for non-existent paths; fall through to shim
  fi

  _realpath_shim "$target"
}

# Pure-bash realpath fallback for macOS systems without coreutils.
_realpath_shim() {
  local target="$1"
  local dir
  local base

  # Handle non-existent targets
  if [[ ! -e "$target" ]]; then
    # Resolve the parent directory, append the basename
    dir="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P)" || return 1
    base="$(basename "$target")"
    echo "${dir}/${base}"
    return 0
  fi

  # Handle directories
  if [[ -d "$target" ]]; then
    (cd "$target" 2>/dev/null && pwd -P) || return 1
    return 0
  fi

  # Handle files: resolve parent directory then append filename
  dir="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P)" || return 1
  base="$(basename "$target")"
  echo "${dir}/${base}"
}

# --- Cache Directory ---

# Return the session cache directory path for a project.
_get_cache_dir() {
  local project_dir="$1"
  echo "${project_dir}/.autopilot/${_SESSION_CACHE_DIR}"
}

# Ensure the cache directory exists.
_ensure_cache_dir() {
  local project_dir="$1"
  local cache_dir
  cache_dir="$(_get_cache_dir "$project_dir")"
  mkdir -p "$cache_dir"
  echo "$cache_dir"
}

# --- Content Hashing ---

# Collect the list of files that form the session context.
# Returns newline-separated absolute paths.
_collect_context_paths() {
  local project_dir="$1"

  # Always include CLAUDE.md if it exists
  local claude_md="${project_dir}/CLAUDE.md"
  if [[ -f "$claude_md" ]]; then
    portable_realpath "$claude_md"
  fi

  # Include configured context files
  local context_list
  context_list="$(parse_context_files "$project_dir")"
  if [[ -n "$context_list" ]]; then
    while IFS= read -r file_path; do
      [[ -z "$file_path" ]] && continue
      [[ -f "$file_path" ]] && portable_realpath "$file_path"
    done <<< "$context_list"
  fi
}

# Compute a content hash of all session-relevant files.
# Returns a hex digest (SHA-256) representing combined file contents.
compute_content_hash() {
  local project_dir="${1:-.}"
  local file_list
  file_list="$(_collect_context_paths "$project_dir")"

  if [[ -z "$file_list" ]]; then
    # No files to hash — return a fixed sentinel
    echo "empty"
    return 0
  fi

  # Sort for deterministic ordering, then hash all contents together
  local sorted_files
  sorted_files="$(echo "$file_list" | sort)"

  local hash_input=""
  while IFS= read -r file_path; do
    [[ -z "$file_path" ]] && continue
    if [[ -f "$file_path" ]]; then
      # Include filename in hash to detect renames
      hash_input="${hash_input}FILE:${file_path}
$(cat "$file_path")
"
    fi
  done <<< "$sorted_files"

  echo "$hash_input" | shasum -a 256 | cut -d' ' -f1
}

# --- Cache Read/Write ---

# Read the stored content hash from the cache.
# Returns empty string and exit code 1 if no cached hash exists.
read_cached_hash() {
  local project_dir="$1"
  local cache_dir
  cache_dir="$(_get_cache_dir "$project_dir")"
  local hash_file="${cache_dir}/${_SESSION_HASH_FILE}"

  if [[ -f "$hash_file" ]]; then
    cat "$hash_file"
    return 0
  fi
  return 1
}

# Write a content hash to the cache (atomic).
_write_cached_hash() {
  local project_dir="$1"
  local hash_value="$2"
  local cache_dir
  cache_dir="$(_ensure_cache_dir "$project_dir")"
  local hash_file="${cache_dir}/${_SESSION_HASH_FILE}"
  local tmp_file="${hash_file}.tmp.$$"

  echo "$hash_value" > "$tmp_file"
  mv -f "$tmp_file" "$hash_file"
}

# Write the warm marker to indicate a successful prewarm.
_write_warm_marker() {
  local project_dir="$1"
  local hash_value="$2"
  local cache_dir
  cache_dir="$(_ensure_cache_dir "$project_dir")"
  local marker_file="${cache_dir}/${_SESSION_WARM_MARKER}"
  local tmp_file="${marker_file}.tmp.$$"

  echo "$hash_value" > "$tmp_file"
  mv -f "$tmp_file" "$marker_file"
}

# Read the warm marker hash (returns empty + exit 1 if missing).
_read_warm_marker() {
  local project_dir="$1"
  local cache_dir
  cache_dir="$(_get_cache_dir "$project_dir")"
  local marker_file="${cache_dir}/${_SESSION_WARM_MARKER}"

  if [[ -f "$marker_file" ]]; then
    cat "$marker_file"
    return 0
  fi
  return 1
}

# --- Cache Validation ---

# Check if the session cache is valid (content unchanged since last prewarm).
is_cache_valid() {
  local project_dir="${1:-.}"

  local current_hash
  current_hash="$(compute_content_hash "$project_dir")"

  local cached_hash
  cached_hash="$(read_cached_hash "$project_dir")" || return 1

  local warm_hash
  warm_hash="$(_read_warm_marker "$project_dir")" || return 1

  # Both the content hash and the warm marker must match
  [[ "$current_hash" = "$cached_hash" && "$current_hash" = "$warm_hash" ]]
}

# --- Cache Invalidation ---

# Clear all session cache files for a project.
invalidate_cache() {
  local project_dir="${1:-.}"
  local cache_dir
  cache_dir="$(_get_cache_dir "$project_dir")"

  if [[ -d "$cache_dir" ]]; then
    rm -f "${cache_dir}/${_SESSION_HASH_FILE}"
    rm -f "${cache_dir}/${_SESSION_WARM_MARKER}"
  fi
}

# --- Prewarm Prompt ---

# Build the prompt used to pre-warm a Claude session with project context.
build_prewarm_prompt() {
  local project_dir="${1:-.}"
  local prompt="Read and internalize the following project context files."
  prompt="${prompt} You will be working on this project shortly."
  prompt="${prompt} Acknowledge each file briefly.\n\n"

  local file_list
  file_list="$(_collect_context_paths "$project_dir")"

  if [[ -z "$file_list" ]]; then
    echo "$prompt"
    return 0
  fi

  while IFS= read -r file_path; do
    [[ -z "$file_path" ]] && continue
    [[ -f "$file_path" ]] || continue
    local basename_file
    basename_file="$(basename "$file_path")"
    prompt="${prompt}## ${basename_file}\n\n"
    prompt="${prompt}$(cat "$file_path")\n\n"
  done <<< "$file_list"

  printf '%b' "$prompt"
}

# --- Pre-warm Session ---

# Pre-warm a Claude session with project context.
# Skips if cache is valid (files unchanged). Returns 0 on success or skip.
prewarm_session() {
  local project_dir="${1:-.}"
  local config_dir="${2:-}"

  # Check if prewarm is needed
  if is_cache_valid "$project_dir"; then
    log_msg "$project_dir" "DEBUG" "Session cache valid, skipping prewarm"
    return 0
  fi

  log_msg "$project_dir" "INFO" "Session cache invalid, pre-warming"

  # Compute and store the new content hash
  local current_hash
  current_hash="$(compute_content_hash "$project_dir")"
  _write_cached_hash "$project_dir" "$current_hash"

  # Build the prewarm prompt
  local prompt
  prompt="$(build_prewarm_prompt "$project_dir")"

  # Run Claude with the prewarm prompt
  local output_file
  local exit_code=0
  output_file="$(run_claude "$_SESSION_PREWARM_TIMEOUT" "$prompt" "$config_dir")" || exit_code=$?

  if [[ $exit_code -ne 0 ]]; then
    log_msg "$project_dir" "WARNING" "Session prewarm failed (exit $exit_code)"
    # Clean up output file if it exists
    [[ -f "$output_file" ]] && rm -f "$output_file"
    return 1
  fi

  # Mark as warm
  _write_warm_marker "$project_dir" "$current_hash"
  log_msg "$project_dir" "INFO" "Session pre-warmed successfully"

  # Clean up output file
  [[ -f "$output_file" ]] && rm -f "$output_file"
  return 0
}
