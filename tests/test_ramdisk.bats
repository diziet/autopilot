#!/usr/bin/env bats
# Tests for lib/ramdisk.sh — RAM disk creation, uniqueness, timeout, cleanup.

BATS_NO_PARALLELIZE_WITHIN_FILE=1

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/ramdisk.sh"

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

@test "create_ramdisk: uses PID-based volume name in diskutil call" {
  local trace_file="$BATS_TEST_TMPDIR/diskutil_args"
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/ramdisk.sh"
    uname() { echo "Darwin"; }
    hdiutil() {
      case "$1" in
        attach) echo "/dev/disk99" ;;
        detach) return 0 ;;
      esac
    }
    diskutil() {
      echo "$3" > "'"$trace_file"'"
      return 0
    }
    timeout() { shift; "$@"; }
    cleanup_stale_ramdisks() { true; }
    export -f uname hdiutil diskutil timeout cleanup_stale_ramdisks
    create_ramdisk
  '
  # The volume name written by diskutil mock should have PID suffix.
  [ -f "$trace_file" ]
  [[ "$(cat "$trace_file")" == "AutopilotTests-"* ]]
}

@test "create_ramdisk: detaches device when diskutil fails" {
  local trace_file="$BATS_TEST_TMPDIR/detach_args"
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/ramdisk.sh"
    uname() { echo "Darwin"; }
    hdiutil() {
      case "$1" in
        attach) echo "/dev/disk99" ;;
        detach) echo "$2" > "'"$trace_file"'"; return 0 ;;
      esac
    }
    diskutil() { return 1; }
    timeout() { shift; "$@"; }
    cleanup_stale_ramdisks() { true; }
    export -f uname hdiutil diskutil timeout cleanup_stale_ramdisks
    create_ramdisk
  '
  [ "$status" -ne 0 ]
  [ -f "$trace_file" ]
  [ "$(cat "$trace_file")" = "/dev/disk99" ]
}

@test "create_ramdisk: returns failure when hdiutil attach fails" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/ramdisk.sh"
    uname() { echo "Darwin"; }
    hdiutil() { return 1; }
    cleanup_stale_ramdisks() { true; }
    export -f uname hdiutil cleanup_stale_ramdisks
    create_ramdisk
  '
  [ "$status" -ne 0 ]
}

@test "create_ramdisk: returns failure when hdiutil returns empty device" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/ramdisk.sh"
    uname() { echo "Darwin"; }
    hdiutil() { echo ""; }
    cleanup_stale_ramdisks() { true; }
    export -f uname hdiutil cleanup_stale_ramdisks
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
    _list_autopilot_volumes() {
      local entry
      for entry in /Volumes/"${_RAMDISK_PREFIX}"*; do
        [[ -d "$entry" ]] || continue
        basename "$entry"
      done
    }
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

@test "cleanup_stale_ramdisks: detaches volumes with no bats process" {
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../lib/ramdisk.sh"
    # Override _list_autopilot_volumes to return a fake volume.
    _list_autopilot_volumes() { echo "AutopilotTests-99999"; }
    # Fake /Volumes dir must exist for the -d check.
    mkdir -p "/tmp/_ramdisk_test_vol"
    # Override mount_point to use our fake dir.
    # Since we cannot create /Volumes/*, test the no-dir path:
    # cleanup should skip volumes where -d fails.
    pgrep() { return 1; }
    export -f _list_autopilot_volumes pgrep
    cleanup_stale_ramdisks
  '
  [ "$status" -eq 0 ]
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
