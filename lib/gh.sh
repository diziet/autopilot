#!/usr/bin/env bash
# Helper for running commands with stderr capture and logging.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_GH_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_GH_LOADED=1

# Source dependencies.
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"

# Run a command capturing stderr and logging it on failure.
# Stdout passes through for command substitution. On non-zero exit, logs stderr via log_msg.
# Usage: _run_with_stderr_capture <project_dir> [--level LEVEL] <command> [args...]
#   --level LEVEL  Log level for stderr output (default: ERROR).
_run_with_stderr_capture() {
  local project_dir="$1"
  shift

  # Parse optional --level flag (defaults to ERROR).
  local _log_level="ERROR"
  if [[ "${1:-}" == "--level" ]]; then
    _log_level="$2"
    shift 2
  fi

  local _tmp_err
  _tmp_err="$(mktemp "${TMPDIR:-/tmp}/autopilot-stderr-err.XXXXXX")"

  local _exit_code=0
  "$@" 2>"$_tmp_err" || _exit_code=$?

  if [[ "$_exit_code" -ne 0 ]]; then
    local _stderr_content
    _stderr_content="$(<"$_tmp_err")"
    if [[ -n "$_stderr_content" ]]; then
      log_msg "$project_dir" "$_log_level" "stderr: ${_stderr_content}"
    fi
  fi

  rm -f "$_tmp_err"
  return "$_exit_code"
}

# Convenience alias: run a gh/git command with stderr capture at ERROR level.
_run_gh() {
  _run_with_stderr_capture "$@"
}
