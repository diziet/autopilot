#!/usr/bin/env bash
# Shared entry-point boilerplate for Autopilot cron scripts.
# Provides quick guards, bootstrap+lock, and common arg resolution
# so bin/ entry points stay thin.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_ENTRY_COMMON_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_ENTRY_COMMON_LOADED=1

# Resolve PROJECT_DIR from a raw argument (defaults to pwd).
resolve_project_dir() {
  local raw="${1:-.}"
  local resolved
  resolved="$(cd "$raw" && pwd)"
  echo "$resolved"
}

# Resolve LIB_DIR from the calling script's location.
resolve_lib_dir() {
  local script_path="$1"
  local script_dir
  script_dir="$(cd "$(dirname "$script_path")" && pwd)"
  echo "${script_dir}/../lib"
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

# Check quick guards: PAUSE file and lock PID liveness.
# Returns 0 if the entry point should proceed, 1 if it should exit immediately.
check_quick_guards() {
  local project_dir="$1"
  local lock_name="$2"
  local state_dir="${project_dir}/.autopilot"

  # Guard 1: PAUSE file — instant exit.
  if [[ -f "${state_dir}/PAUSE" ]]; then
    return 1
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

# Source a module, load config, init pipeline, acquire lock, set cleanup trap.
# Returns 0 on success, 1 if the lock could not be acquired.
bootstrap_and_lock() {
  local project_dir="$1"
  local lock_name="$2"
  local module="$3"
  local lib_dir="${4:-}"

  # Resolve lib dir from the module path if not provided.
  if [[ -z "$lib_dir" ]]; then
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)/../lib"
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
