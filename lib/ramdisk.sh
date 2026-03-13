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

# Clean up stale AutopilotTests* RAM disks with no active bats process.
cleanup_stale_ramdisks() {
  local vol mount_point dev_node bats_using
  # Find all mounted AutopilotTests* volumes.
  while IFS= read -r vol; do
    [[ -z "$vol" ]] && continue
    mount_point="/Volumes/$vol"
    [[ -d "$mount_point" ]] || continue

    # Check if any bats process has TMPDIR pointing at this volume.
    bats_using=0
    if command -v pgrep >/dev/null 2>&1; then
      local pid
      while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        # Check /proc or lsof for the mount — on macOS, check via lsof.
        if lsof -p "$pid" 2>/dev/null | grep -q "$mount_point"; then
          bats_using=1
          break
        fi
      done < <(pgrep -x bats 2>/dev/null || true)
    fi

    if [[ "$bats_using" -eq 0 ]]; then
      # Find the device node for this volume and detach it.
      dev_node="$(diskutil info "$mount_point" 2>/dev/null | awk '/Device Node:/{print $NF}')"
      if [[ -n "$dev_node" ]]; then
        hdiutil detach "$dev_node" -force >/dev/null 2>&1 || true
      fi
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
# Prints the mount path on success, empty string on failure.
# Sets _RAMDISK_DEV to the device node (for cleanup).
create_ramdisk() {
  _RAMDISK_DEV=""

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
  if ! timeout "${_DISKUTIL_TIMEOUT}" diskutil erasevolume HFS+ "$vol_name" "$dev_node" >/dev/null 2>&1; then
    # Timeout or failure — detach and fall back.
    hdiutil detach "$dev_node" -force >/dev/null 2>&1 || true
    return 1
  fi

  local mount_path="/Volumes/${vol_name}"
  if [[ ! -d "$mount_path" ]]; then
    hdiutil detach "$dev_node" -force >/dev/null 2>&1 || true
    return 1
  fi

  _RAMDISK_DEV="$dev_node"
  echo "$mount_path"
}

# Detach a RAM disk by device node.
detach_ramdisk() {
  local dev_node="${1:-}"
  if [[ -n "$dev_node" ]]; then
    hdiutil detach "$dev_node" >/dev/null 2>&1 || true
  fi
}
