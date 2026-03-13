#!/usr/bin/env bash
# Shared entry-point boilerplate for Autopilot cron scripts.
# Provides quick guards, bootstrap+lock, and common arg resolution
# so bin/ entry points stay thin.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_ENTRY_COMMON_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_ENTRY_COMMON_LOADED=1

# Resolve a path through any chain of symlinks (portable, no GNU readlink -f).
# SYNC: Keep algorithm in sync with the inline bootstrap block in bin/ scripts.
# The inline copy exists because bin/ scripts must resolve symlinks *before*
# they can source this file. Changes here must be mirrored there.
resolve_script_path() {
  local source="$1"
  while [[ -L "$source" ]]; do
    local dir
    dir="$(cd "$(dirname "$source")" && pwd)"
    source="$(readlink "$source")"
    [[ "$source" != /* ]] && source="$dir/$source"
  done
  echo "$source"
}

# Resolve PROJECT_DIR from a raw argument (defaults to pwd).
# Always returns a canonical absolute path (symlinks resolved).
resolve_project_dir() {
  local raw="${1:-.}"
  echo "$(cd "$raw" && pwd)"
}

# Resolve LIB_DIR from the calling script's location.
resolve_lib_dir() {
  local script_path="$1"
  # Follow symlinks to the real script location.
  script_path="$(resolve_script_path "$script_path")"
  local script_dir="${script_path%/*}"
  # Resolve to canonical absolute path (handles relative paths and .. segments).
  script_dir="$(cd "$script_dir" && pwd)"
  echo "${script_dir}/../lib"
}

# Locate a sibling binary by name: prefer PATH, fall back to bin/ relative to lib_dir.
# Prints the resolved command path or empty string if not found.
find_sibling_binary() {
  local name="$1"
  local lib_dir="$2"
  if command -v "$name" >/dev/null 2>&1; then
    echo "$name"
  elif [[ -x "${lib_dir}/../bin/${name}" ]]; then
    echo "${lib_dir}/../bin/${name}"
  else
    echo ""
  fi
}

# Parse common arguments: project dir, --help, unknown-option rejection.
# Sets PROJECT_DIR_ARG. Delegates script-specific flags to _handle_extra_flag()
# if defined by the caller. Uses _EXTRA_POSITIONAL_HINT for error messages.
# Caller must define _usage().
# shellcheck disable=SC2034  # PROJECT_DIR_ARG consumed by caller
parse_base_args() {
  PROJECT_DIR_ARG=""
  local positional_count=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        _usage
        exit 0
        ;;
      -*)
        # Let the caller handle script-specific flags via callback.
        # Initialize EXTRA_FLAG_SHIFT to guard against handlers that forget to set it.
        EXTRA_FLAG_SHIFT=0
        if type -t _handle_extra_flag &>/dev/null && _handle_extra_flag "$@"; then
          if [[ "$EXTRA_FLAG_SHIFT" -le 0 ]]; then
            echo "BUG: _handle_extra_flag returned success but did not set EXTRA_FLAG_SHIFT" >&2
            exit 1
          fi
          shift "$EXTRA_FLAG_SHIFT"
          continue
        fi
        echo "Error: unknown option: $1" >&2
        _usage >&2
        exit 1
        ;;
      *)
        positional_count=$((positional_count + 1))
        if [[ "$positional_count" -gt 1 ]]; then
          echo "Error: unexpected positional argument: $1" >&2
          echo "Hint: ${_EXTRA_POSITIONAL_HINT:-only one positional argument (project dir) is accepted}" >&2
          _usage >&2
          exit 1
        fi
        PROJECT_DIR_ARG="$1"
        shift
        ;;
    esac
  done
}

# Read PAUSE file content with whitespace stripped. Empty string if missing or blank.
_read_pause_content() {
  local pause_file="${1}/.autopilot/PAUSE"
  if [[ -f "$pause_file" ]]; then
    cat "$pause_file" 2>/dev/null | tr -d '[:space:]'
  fi
}

# Check quick guards: PAUSE file and lock PID liveness.
# Returns 0 if the entry point should proceed, 1 if it should exit immediately.
# Soft pause (empty PAUSE file) allows the tick to proceed; check_soft_pause
# re-reads the file from disk at each phase boundary to decide whether to stop.
check_quick_guards() {
  local project_dir="$1"
  local lock_name="$2"
  local state_dir="${project_dir}/.autopilot"

  # Guard 1: PAUSE file — check for hard vs soft pause.
  if [[ -f "${state_dir}/PAUSE" ]]; then
    local pause_content
    pause_content="$(_read_pause_content "$project_dir")"
    if [[ -n "$pause_content" ]]; then
      # Hard pause — any non-empty content means stop immediately.
      return 1
    fi
    # Soft pause (empty/whitespace-only file) — continue into the tick.
    # check_soft_pause will re-read the file at each phase boundary.
  fi

  # Guard 2: Lock file with live PID — another instance is running.
  local lock_file="${state_dir}/locks/${lock_name}.lock"
  if [[ -f "$lock_file" ]]; then
    local lock_pid
    lock_pid="$(cat "$lock_file" 2>/dev/null)"
    if [[ -n "$lock_pid" ]] && ps -p "$lock_pid" >/dev/null 2>&1; then
      return 1
    fi
  fi

  return 0
}

# Check if soft pause is active and exit if so. Call after phase completion.
# Re-reads the PAUSE file from disk so the check survives across ticks.
check_soft_pause() {
  local project_dir="$1"
  local pause_file="${project_dir}/.autopilot/PAUSE"
  if [[ -f "$pause_file" ]]; then
    local content
    content="$(_read_pause_content "$project_dir")"
    if [[ -z "$content" ]]; then
      log_msg "$project_dir" "INFO" \
        "Soft pause — stopping after phase completion"
      exit 0
    fi
  fi
}

# Source a module, load config, init pipeline, acquire lock, set cleanup trap.
# Returns 0 on success, 1 if the lock could not be acquired.
bootstrap_and_lock() {
  local project_dir="$1"
  local lock_name="$2"
  local module="$3"
  local lib_dir="${4:-}"

  # Resolve lib dir from the caller's location if not provided.
  if [[ -z "$lib_dir" ]]; then
    local caller_path
    caller_path="$(resolve_script_path "${BASH_SOURCE[1]}")"
    local caller_dir="${caller_path%/*}"
    lib_dir="$(cd "$caller_dir" && pwd)/../lib"
  fi

  # Source the module (which sources its own deps).
  # shellcheck disable=SC1090
  source "${lib_dir}/${module}"

  # Load config for this project.
  load_config "$project_dir"

  # Initialize pipeline state directory if needed.
  init_pipeline "$project_dir"

  # Acquire the lock — return 1 if another process grabbed it.
  if ! acquire_lock "$project_dir" "$lock_name"; then
    return 1
  fi

  # Set cleanup trap to release lock on exit.
  # shellcheck disable=SC2064
  trap "release_lock '$project_dir' '$lock_name' 2>/dev/null || true" EXIT

  return 0
}
