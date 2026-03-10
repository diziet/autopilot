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

  # Normalize bare filenames (no slash) so ${target%/*} works like dirname.
  [[ "$target" != */* ]] && target="./$target"

  # Handle non-existent targets
  if [[ ! -e "$target" ]]; then
    # Resolve the parent directory, append the basename
    dir="$(cd "${target%/*}" 2>/dev/null && pwd -P)" || return 1
    base="${target##*/}"
    echo "${dir}/${base}"
    return 0
  fi

  # Handle directories
  if [[ -d "$target" ]]; then
    (cd "$target" 2>/dev/null && pwd -P) || return 1
    return 0
  fi

  # Handle files: resolve parent directory then append filename
  dir="$(cd "${target%/*}" 2>/dev/null && pwd -P)" || return 1
  base="${target##*/}"
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
  sorted_files="$(sort <<< "$file_list")"

  local hash_input=""
  while IFS= read -r file_path; do
    [[ -z "$file_path" ]] && continue
    if [[ -f "$file_path" ]]; then
      # Include filename in hash to detect renames
      hash_input="${hash_input}FILE:${file_path}
$(<"$file_path")
"
    fi
  done <<< "$sorted_files"

  echo "$hash_input" | shasum -a 256 | cut -d' ' -f1
}

# --- Cache Read/Write ---

# Read a named file from the cache directory.
# Returns contents on success, exit code 1 if file missing.
_read_cache_file() {
  local project_dir="$1"
  local filename="$2"
  local cache_dir
  cache_dir="$(_get_cache_dir "$project_dir")"
  local target="${cache_dir}/${filename}"

  if [[ -f "$target" ]]; then
    cat "$target"
    return 0
  fi
  return 1
}

# Write a value to a named cache file (atomic via tmp+mv).
_write_cache_file() {
  local project_dir="$1"
  local filename="$2"
  local value="$3"
  local cache_dir
  cache_dir="$(_ensure_cache_dir "$project_dir")"
  local target="${cache_dir}/${filename}"
  local tmp_file="${target}.tmp.$$"

  echo "$value" > "$tmp_file"
  mv -f "$tmp_file" "$target"
}

# Read the stored content hash from the cache.
read_cached_hash() { _read_cache_file "$1" "$_SESSION_HASH_FILE"; }

# Write a content hash to the cache.
_write_cached_hash() { _write_cache_file "$1" "$_SESSION_HASH_FILE" "$2"; }

# Write the warm marker to indicate a successful prewarm.
_write_warm_marker() { _write_cache_file "$1" "$_SESSION_WARM_MARKER" "$2"; }

# Read the warm marker hash (returns empty + exit 1 if missing).
_read_warm_marker() { _read_cache_file "$1" "$_SESSION_WARM_MARKER"; }

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
  local nl=$'\n'
  local prompt="Read and internalize the following project context files."
  prompt="${prompt} You will be working on this project shortly."
  prompt="${prompt} Acknowledge each file briefly.${nl}${nl}"

  local file_list
  file_list="$(_collect_context_paths "$project_dir")"

  if [[ -z "$file_list" ]]; then
    printf '%s' "$prompt"
    return 0
  fi

  while IFS= read -r file_path; do
    [[ -z "$file_path" ]] && continue
    [[ -f "$file_path" ]] || continue
    local basename_file
    basename_file="${file_path##*/}"
    prompt="${prompt}## ${basename_file}${nl}${nl}"
    prompt="${prompt}$(<"$file_path")${nl}${nl}"
  done <<< "$file_list"

  printf '%s' "$prompt"
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
