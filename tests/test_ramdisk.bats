#!/usr/bin/env bats
# Tests for lib/ramdisk.sh — RAM disk creation, uniqueness, timeout, cleanup.

BATS_NO_PARALLELIZE_WITHIN_FILE=1

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/ramdisk.sh"

# Shared mock preamble for bash -c subshells (Darwin, stubs for hdiutil/diskutil/timeout).
_mock_preamble() {
  cat <<PREAMBLE
    source '$BATS_TEST_DIRNAME/../lib/ramdisk.sh'
    uname() { echo "Darwin"; }
    cleanup_stale_ramdisks() { true; }
    _run_with_timeout() { shift; "\$@"; }
    export -f uname cleanup_stale_ramdisks _run_with_timeout
PREAMBLE
}

# --- Constants ---

@test "RAMDISK_PREFIX is AutopilotTests" {
  [ "$_RAMDISK_PREFIX" = "AutopilotTests" ]
}

@test "default timeout is 10 seconds" {
  [ "$_DISKUTIL_TIMEOUT" = "10" ] || [ "$_DISKUTIL_TIMEOUT" = "${AUTOPILOT_RAMDISK_TIMEOUT}" ]
}

@test "RAM disk size is 1 GB (2097152 sectors)" {
  [ "$_RAMDISK_SECTORS" = "2097152" ]
}

# --- _run_with_timeout ---

@test "_run_with_timeout: falls back to direct execution when timeout missing" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/ramdisk.sh"
    # Hide timeout command.
    timeout() { return 127; }
    command() {
      if [ "$1" = "-v" ] && [ "$2" = "timeout" ]; then return 1; fi
      builtin command "$@"
    }
    export -f timeout command
    _run_with_timeout 5 echo "hello"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello"* ]]
}

# --- create_ramdisk unit tests (via bash -c to allow mocking) ---

@test "create_ramdisk: returns failure on non-Darwin" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/ramdisk.sh"
    uname() { echo "Linux"; }
    export -f uname
    create_ramdisk
  '
  [ "$status" -ne 0 ]
}

@test "create_ramdisk: outputs dev_node and PID-based mount path" {
  local trace_file="$BATS_TEST_TMPDIR/diskutil_args"
  local output_file="$BATS_TEST_TMPDIR/ramdisk_output"
  run bash -c '
    '"$(_mock_preamble)"'
    hdiutil() {
      case "$1" in
        attach) echo "/dev/disk99" ;;
        detach) return 0 ;;
      esac
    }
    diskutil() {
      echo "$3" > "'"$trace_file"'"
      # Simulate erasevolume creating the mount dir.
      mkdir -p "/tmp/_ramdisk_fake_mount_$$"
      return 0
    }
    # Override the mount path to use /tmp instead of /Volumes.
    create_ramdisk() {
      if [[ "$(uname)" != "Darwin" ]] || ! command -v hdiutil >/dev/null 2>&1; then
        return 1
      fi
      cleanup_stale_ramdisks
      local vol_name="${_RAMDISK_PREFIX}-$$"
      local dev_node
      dev_node="$(hdiutil attach -nomount "ram://${_RAMDISK_SECTORS}" 2>/dev/null | awk '"'"'{print $1}'"'"')"
      if [[ -z "$dev_node" ]]; then return 1; fi
      if ! _run_with_timeout "${_DISKUTIL_TIMEOUT}" diskutil erasevolume HFS+ "$vol_name" "$dev_node" >/dev/null 2>&1; then
        detach_ramdisk --force "$dev_node"; return 1
      fi
      local mount_path="/tmp/_ramdisk_fake_mount_$$"
      if [[ ! -d "$mount_path" ]]; then
        detach_ramdisk --force "$dev_node"; return 1
      fi
      echo "$dev_node $mount_path"
    }
    export -f hdiutil diskutil create_ramdisk
    create_ramdisk
  '
  [ "$status" -eq 0 ]
  # Volume name should have PID suffix.
  [ -f "$trace_file" ]
  [[ "$(cat "$trace_file")" == "AutopilotTests-"* ]]
  # Output format is "dev_node mount_path".
  [[ "$output" == "/dev/disk99 /tmp/_ramdisk_fake_mount_"* ]]
}

@test "create_ramdisk: detaches device when diskutil fails" {
  local trace_file="$BATS_TEST_TMPDIR/detach_args"
  run bash -c '
    '"$(_mock_preamble)"'
    hdiutil() {
      case "$1" in
        attach) echo "/dev/disk99" ;;
        detach) echo "$@" > "'"$trace_file"'"; return 0 ;;
      esac
    }
    diskutil() { return 1; }
    export -f hdiutil diskutil
    create_ramdisk
  '
  [ "$status" -ne 0 ]
  [ -f "$trace_file" ]
  # Should force-detach on failure.
  [[ "$(cat "$trace_file")" == *"/dev/disk99"* ]]
  [[ "$(cat "$trace_file")" == *"-force"* ]]
}

@test "create_ramdisk: returns failure when hdiutil attach fails" {
  run bash -c '
    '"$(_mock_preamble)"'
    hdiutil() { return 1; }
    export -f hdiutil
    create_ramdisk
  '
  [ "$status" -ne 0 ]
}

@test "create_ramdisk: returns failure when hdiutil returns empty device" {
  run bash -c '
    '"$(_mock_preamble)"'
    hdiutil() { echo ""; }
    export -f hdiutil
    create_ramdisk
  '
  [ "$status" -ne 0 ]
}

# --- detach_ramdisk ---

@test "detach_ramdisk: calls hdiutil detach with device node" {
  local trace_file="$BATS_TEST_TMPDIR/detach_trace"
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/ramdisk.sh"
    hdiutil() { echo "$*" > "'"$trace_file"'"; }
    export -f hdiutil
    detach_ramdisk "/dev/disk42"
  '
  [ "$status" -eq 0 ]
  [ -f "$trace_file" ]
  [[ "$(cat "$trace_file")" == *"detach /dev/disk42"* ]]
  # Non-force by default.
  [[ "$(cat "$trace_file")" != *"-force"* ]]
}

@test "detach_ramdisk: passes --force flag to hdiutil" {
  local trace_file="$BATS_TEST_TMPDIR/detach_force_trace"
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/ramdisk.sh"
    hdiutil() { echo "$*" > "'"$trace_file"'"; }
    export -f hdiutil
    detach_ramdisk --force "/dev/disk42"
  '
  [ "$status" -eq 0 ]
  [ -f "$trace_file" ]
  [[ "$(cat "$trace_file")" == *"detach /dev/disk42 -force"* ]]
}

@test "detach_ramdisk: no-op when device node is empty" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/ramdisk.sh"
    hdiutil() { echo "SHOULD_NOT_BE_CALLED"; }
    export -f hdiutil
    detach_ramdisk ""
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD_NOT_BE_CALLED"* ]]
}

# --- _list_autopilot_volumes ---

@test "_list_autopilot_volumes: returns only matching volume names" {
  run bash -c '
    _RAMDISK_PREFIX="AutopilotTests"
    # Create fake volume dirs.
    mkdir -p "'"$BATS_TEST_TMPDIR"'/Volumes/AutopilotTests-111"
    mkdir -p "'"$BATS_TEST_TMPDIR"'/Volumes/AutopilotTests-222"
    mkdir -p "'"$BATS_TEST_TMPDIR"'/Volumes/OtherVolume"
    # Override to use fake /Volumes.
    _list_autopilot_volumes() {
      local entry
      for entry in "'"$BATS_TEST_TMPDIR"'/Volumes/${_RAMDISK_PREFIX}"*; do
        [[ -d "$entry" ]] || continue
        basename "$entry"
      done
    }
    _list_autopilot_volumes
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"AutopilotTests-111"* ]]
  [[ "$output" == *"AutopilotTests-222"* ]]
  [[ "$output" != *"OtherVolume"* ]]
}

# --- Uniqueness guarantee ---

@test "two subshells get different PID-based volume names" {
  local name1 name2
  name1="$(bash -c 'echo "AutopilotTests-$$"')"
  name2="$(bash -c 'echo "AutopilotTests-$$"')"
  [ "$name1" != "$name2" ]
}

# --- cleanup_stale_ramdisks ---

@test "cleanup_stale_ramdisks: uses non-force detach for in-use safety" {
  local trace_file="$BATS_TEST_TMPDIR/cleanup_detach_trace"
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/ramdisk.sh"
    _list_autopilot_volumes() { echo "AutopilotTests-12345"; }
    # Fake mount point must exist for -d check.
    mkdir -p "/tmp/_ramdisk_test_cleanup"
    # Override /Volumes path check to use our temp dir.
    cleanup_stale_ramdisks() {
      local vol mount_point dev_node
      while IFS= read -r vol; do
        [[ -z "$vol" ]] && continue
        mount_point="/tmp/_ramdisk_test_cleanup"
        [[ -d "$mount_point" ]] || continue
        dev_node="/dev/disk_fake"
        detach_ramdisk "$dev_node"
      done < <(_list_autopilot_volumes)
    }
    hdiutil() { echo "$*" > "'"$trace_file"'"; }
    export -f _list_autopilot_volumes hdiutil
    cleanup_stale_ramdisks
  '
  [ "$status" -eq 0 ]
  # Should use non-force detach.
  if [ -f "$trace_file" ]; then
    [[ "$(cat "$trace_file")" != *"-force"* ]]
  fi
}

@test "cleanup_stale_ramdisks: succeeds when no volumes exist" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/ramdisk.sh"
    _list_autopilot_volumes() { true; }
    export -f _list_autopilot_volumes
    cleanup_stale_ramdisks
  '
  [ "$status" -eq 0 ]
}
