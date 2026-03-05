#!/usr/bin/env bash
# Shared entry-point boilerplate for Autopilot cron scripts.
# Provides quick guards and bootstrap+lock so bin/ entry points stay thin.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_ENTRY_COMMON_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_ENTRY_COMMON_LOADED=1

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
