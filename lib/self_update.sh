#!/usr/bin/env bash
# Self-update autopilot installation by fast-forward pulling origin/main.
# Uses a marker file to throttle checks to AUTOPILOT_SELF_UPDATE_INTERVAL seconds.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_SELF_UPDATE_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_SELF_UPDATE_LOADED=1

# shellcheck source=lib/config.sh
source "${BASH_SOURCE[0]%/*}/config.sh"
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"

# Resolve the autopilot install directory from this script's location.
_resolve_install_dir() {
  local self="${BASH_SOURCE[0]}"
  while [[ -L "$self" ]]; do
    local dir
    dir="$(cd "$(dirname "$self")" && pwd)"
    self="$(readlink "$self")"
    [[ "$self" != /* ]] && self="$dir/$self"
  done
  cd "$(dirname "$self")/.." && pwd
}

# Read the Unix timestamp from the marker file, or 0 if missing/invalid.
_read_update_marker() {
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

# Check if the install directory has uncommitted changes (ignoring the marker file).
_install_dir_is_dirty() {
  local install_dir="$1"
  local status
  status="$(git -C "$install_dir" status --porcelain 2>/dev/null \
    | grep -v '\.autopilot_self_update$' || true)"
  [[ -n "$status" ]]
}

# Attempt to fast-forward pull the autopilot install directory.
# Logs results but never returns failure — callers should not be blocked.
check_self_update() {
  local project_dir="${1:-.}"
  local interval="${AUTOPILOT_SELF_UPDATE_INTERVAL:-300}"

  # Disabled when interval is 0.
  if [[ "$interval" -eq 0 ]]; then
    return 0
  fi

  local install_dir
  install_dir="$(_resolve_install_dir)"
  local marker_file="${install_dir}/.autopilot_self_update"

  # Throttle: skip if marker is fresh.
  local last_check
  last_check="$(_read_update_marker "$marker_file")"
  local now
  now="$(date +%s)"
  local elapsed=$(( now - last_check ))
  if [[ "$elapsed" -lt "$interval" ]]; then
    return 0
  fi

  # Skip if install dir has local changes.
  if _install_dir_is_dirty "$install_dir"; then
    log_msg "$project_dir" "WARNING" \
      "Self-update skipped: install dir has uncommitted changes (${install_dir})"
    # Still update marker to avoid re-checking every tick.
    echo "$now" > "$marker_file" 2>/dev/null || true
    return 0
  fi

  # Fetch and fast-forward merge.
  local old_head
  old_head="$(git -C "$install_dir" rev-parse HEAD 2>/dev/null)"

  if ! git -C "$install_dir" fetch origin main 2>/dev/null; then
    log_msg "$project_dir" "WARNING" \
      "Self-update: git fetch failed (${install_dir})"
    echo "$now" > "$marker_file" 2>/dev/null || true
    return 0
  fi

  if ! git -C "$install_dir" merge --ff-only origin/main 2>/dev/null; then
    log_msg "$project_dir" "WARNING" \
      "Self-update: fast-forward merge failed (${install_dir})"
    echo "$now" > "$marker_file" 2>/dev/null || true
    return 0
  fi

  local new_head
  new_head="$(git -C "$install_dir" rev-parse HEAD 2>/dev/null)"

  if [[ "$old_head" != "$new_head" ]]; then
    log_msg "$project_dir" "INFO" \
      "Self-update: updated to ${new_head:0:12} (${install_dir})"
  fi

  echo "$now" > "$marker_file" 2>/dev/null || true
  return 0
}
