#!/usr/bin/env bash
# Marker-file helpers for timestamp-based throttling.
# Shared by self_update.sh and worktree-cleanup.sh.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_MARKER_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_MARKER_LOADED=1

# Read the Unix timestamp from a marker file, or 0 if missing/invalid.
read_marker_timestamp() {
  local marker_file="$1"
  if [[ -f "$marker_file" ]]; then
    local ts
    ts="$(cat "$marker_file" 2>/dev/null)"
    if [[ "$ts" =~ ^[0-9]+$ ]]; then
      echo "$ts"
      return 0
    fi
  fi
  echo "0"
}

# Write the current timestamp to a marker file.
write_marker_timestamp() {
  local marker_file="$1" now="$2"
  echo "$now" > "$marker_file" 2>/dev/null || true
}
