#!/usr/bin/env bash
# Network error detection for Autopilot.
# Provides _is_network_error() to distinguish transient network failures
# from real task failures, so network errors don't burn the retry budget.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_NETWORK_ERRORS_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_NETWORK_ERRORS_LOADED=1

# Check if a failure message indicates a network error.
_is_network_error() {
  local failure_output="$1"

  [[ -z "$failure_output" ]] && return 1

  # Patterns that indicate a network/connectivity failure.
  # Checked against log output from gh, git, or claude CLI.
  local patterns=(
    "Could not resolve host"
    "Connection refused"
    "Connection timed out"
    "Connection reset by peer"
    "Network is unreachable"
    "No route to host"
    "Failed to connect"
    "SSL connection"
    "unable to access"
    "Could not read from remote repository"
    "fatal: unable to access"
    "HTTP 502"
    "HTTP 503"
    "HTTP 504"
    "connect ETIMEDOUT"
    "connect ECONNREFUSED"
    "getaddrinfo ENOTFOUND"
    "socket hang up"
    "EHOSTUNREACH"
    "request to .* failed"
    "unable to look up"
    "Name or service not known"
  )

  local pattern
  for pattern in "${patterns[@]}"; do
    if echo "$failure_output" | grep -qi "$pattern" 2>/dev/null; then
      return 0
    fi
  done

  return 1
}

# Capture recent log lines that may contain network error evidence.
_get_recent_failure_output() {
  local project_dir="$1"
  local log_file="${project_dir}/.autopilot/logs/pipeline.log"

  [[ -f "$log_file" ]] || return 0

  # Return the last 20 lines which likely contain the failure context.
  tail -n 20 "$log_file" 2>/dev/null || true
}
