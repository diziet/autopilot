#!/usr/bin/env bash
# Timer instrumentation for sub-step timing within pipeline phases.
# Provides _timer_start/_timer_log helpers that produce greppable TIMER log lines.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_TIMER_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_TIMER_LOADED=1

# Source state.sh for log_msg.
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"

# Global variable holding the epoch timestamp of the last _timer_start call.
# Each _timer_log resets it so the next sub-step starts from zero.
_TIMER_EPOCH=""

# Capture current epoch seconds into _TIMER_EPOCH.
_timer_start() {
  _TIMER_EPOCH="$(date +%s)"
}

# Log elapsed time since _timer_start with a greppable TIMER prefix.
_timer_log() {
  local project_dir="$1"
  local label="$2"

  if [[ -z "$_TIMER_EPOCH" ]]; then
    log_msg "$project_dir" "WARNING" "TIMER: ${label} (no start recorded)"
    return 0
  fi

  local now elapsed
  now="$(date +%s)"
  elapsed=$(( now - _TIMER_EPOCH ))

  log_msg "$project_dir" "INFO" "TIMER: ${label} (${elapsed}s)"

  # Reset for next sub-step.
  _TIMER_EPOCH="$now"
}
