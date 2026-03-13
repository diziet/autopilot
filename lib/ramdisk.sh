#!/usr/bin/env bash
# RAM disk management for parallel test runs.
# Creates unique per-invocation RAM disks to avoid contention when multiple
# worktrees run `make test` concurrently. Provides cleanup of stale volumes.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_RAMDISK_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_RAMDISK_LOADED=1

# Volume name prefix for all autopilot test RAM disks.
readonly _RAMDISK_PREFIX="AutopilotTests"

# Timeout in seconds for diskutil erasevolume.
readonly _DISKUTIL_TIMEOUT="${AUTOPILOT_RAMDISK_TIMEOUT:-10}"

# Size: 1 GB = 2097152 512-byte sectors.
readonly _RAMDISK_SECTORS=2097152

# Run a command with a timeout, falling back to direct execution if timeout(1) is unavailable.
_run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  else
    "$@"
  fi
}

# Detach a RAM disk by device node. Pass --force for force detach.
detach_ramdisk() {
  local force=""
  if [[ "${1:-}" == "--force" ]]; then
    force="-force"
    shift
  fi
  local dev_node="${1:-}"
  if [[ -n "$dev_node" ]]; then
    # shellcheck disable=SC2086
    hdiutil detach "$dev_node" $force >/dev/null 2>&1 || true
  fi
}

# Clean up stale AutopilotTests* RAM disks with no active processes.
cleanup_stale_ramdisks() {
  local vol mount_point dev_node
  # Find all mounted AutopilotTests* volumes.
  while IFS= read -r vol; do
    [[ -z "$vol" ]] && continue
    mount_point="/Volumes/$vol"
    [[ -d "$mount_point" ]] || continue

    # Find the device node for this volume.
    dev_node="$(diskutil info "$mount_point" 2>/dev/null | awk '/Device Node:/{print $NF}')"
    if [[ -n "$dev_node" ]]; then
      # Attempt non-force detach — the OS will reject if the volume is in use.
      detach_ramdisk "$dev_node"
    fi
  done < <(_list_autopilot_volumes)
}

# List mounted volume names matching the AutopilotTests prefix.
_list_autopilot_volumes() {
  local entry
  for entry in /Volumes/"${_RAMDISK_PREFIX}"*; do
    [[ -d "$entry" ]] || continue
    basename "$entry"
  done
}

# Create a unique RAM disk for test temp files.
# Prints "device_node mount_path" (space-separated) on success.
# Returns non-zero on failure.
create_ramdisk() {
  # Only works on macOS with hdiutil.
  if [[ "$(uname)" != "Darwin" ]] || ! command -v hdiutil >/dev/null 2>&1; then
    return 1
  fi

  # Clean up stale volumes first.
  cleanup_stale_ramdisks

  # Use PID for uniqueness across concurrent invocations.
  local vol_name="${_RAMDISK_PREFIX}-$$"

  # Allocate the RAM disk device.
  local dev_node
  dev_node="$(hdiutil attach -nomount "ram://${_RAMDISK_SECTORS}" 2>/dev/null | awk '{print $1}')"
  if [[ -z "$dev_node" ]]; then
    return 1
  fi

  # Format with a timeout to avoid hanging on volume name conflicts.
  if ! _run_with_timeout "${_DISKUTIL_TIMEOUT}" diskutil erasevolume HFS+ "$vol_name" "$dev_node" >/dev/null 2>&1; then
    # Timeout or failure — detach and fall back.
    detach_ramdisk --force "$dev_node"
    return 1
  fi

  local mount_path="/Volumes/${vol_name}"
  if [[ ! -d "$mount_path" ]]; then
    detach_ramdisk --force "$dev_node"
    return 1
  fi

  echo "$dev_node $mount_path"
}
