#!/usr/bin/env bats
# Tests for lib/self_update.sh — self-update autopilot installation.

# Prevent within-file parallelism (git I/O contention).
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/test_template

setup_file() { _create_test_template; }
teardown_file() { _cleanup_test_template; }

# Helper: push a v2 commit to origin.
_push_v2_to_origin() {
  local clone_dir="$BATS_TEST_TMPDIR/clone"
  git clone "$ORIGIN_DIR" "$clone_dir" 2>/dev/null
  echo "v2" > "$clone_dir/version.txt"
  git -C "$clone_dir" add -A >/dev/null 2>&1
  git -C "$clone_dir" commit -m "update" -q
  git -C "$clone_dir" push origin main -q 2>/dev/null
}

# Helper: read log file content safely (returns empty string if missing).
_read_log() {
  cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log" 2>/dev/null || true
}

# Create a fake install dir (git repo) and override _resolve_install_dir.
setup() {
  _init_test_from_template_nogit

  # Create a fake install directory with a git repo.
  INSTALL_DIR="$BATS_TEST_TMPDIR/install"
  mkdir -p "$INSTALL_DIR"
  git -C "$INSTALL_DIR" init -q -b main
  git -C "$INSTALL_DIR" config user.email "test@test.com"
  git -C "$INSTALL_DIR" config user.name "Test"
  echo "v1" > "$INSTALL_DIR/version.txt"
  git -C "$INSTALL_DIR" add -A >/dev/null 2>&1
  git -C "$INSTALL_DIR" commit -m "initial" -q

  # Create a bare "origin" repo for fetch/merge tests.
  ORIGIN_DIR="$BATS_TEST_TMPDIR/origin.git"
  git clone --bare "$INSTALL_DIR" "$ORIGIN_DIR" 2>/dev/null
  git -C "$INSTALL_DIR" remote remove origin 2>/dev/null || true
  git -C "$INSTALL_DIR" remote add origin "$ORIGIN_DIR"

  # Source the module.
  source "${BATS_TEST_DIRNAME}/../lib/self_update.sh"

  # Override _resolve_install_dir to return our fake install dir.
  _resolve_install_dir() { echo "$INSTALL_DIR"; }

  AUTOPILOT_SELF_UPDATE_INTERVAL=300
}

# --- Marker file behavior ---

@test "self_update: runs when marker file is missing" {
  _push_v2_to_origin

  check_self_update "$TEST_PROJECT_DIR"

  # Verify the install dir was updated.
  [ "$(cat "$INSTALL_DIR/version.txt")" = "v2" ]

  # Verify marker file was created.
  [ -f "$INSTALL_DIR/.autopilot_self_update" ]
}

@test "self_update: runs when marker is stale" {
  # Write a stale marker (10 minutes ago).
  echo "$(( $(date +%s) - 600 ))" > "$INSTALL_DIR/.autopilot_self_update"

  _push_v2_to_origin

  check_self_update "$TEST_PROJECT_DIR"

  [ "$(cat "$INSTALL_DIR/version.txt")" = "v2" ]
}

@test "self_update: skipped when marker is fresh" {
  echo "$(date +%s)" > "$INSTALL_DIR/.autopilot_self_update"

  _push_v2_to_origin

  check_self_update "$TEST_PROJECT_DIR"

  # Should NOT have updated (marker was fresh).
  [ "$(cat "$INSTALL_DIR/version.txt")" = "v1" ]
}

# --- Dirty install dir ---

@test "self_update: skipped when install dir has uncommitted changes" {
  # Make the install dir dirty (tracked file modified).
  echo "dirty" >> "$INSTALL_DIR/version.txt"

  _push_v2_to_origin

  check_self_update "$TEST_PROJECT_DIR"

  # Should NOT have updated — first line is still v1.
  [[ "$(head -1 "$INSTALL_DIR/version.txt")" == "v1" ]]

  # Should have logged a warning.
  [[ "$(_read_log)" == *"uncommitted changes"* ]]
}

# --- Interval set to 0 ---

@test "self_update: skipped when interval is 0" {
  AUTOPILOT_SELF_UPDATE_INTERVAL=0

  _push_v2_to_origin

  check_self_update "$TEST_PROJECT_DIR"

  [ "$(cat "$INSTALL_DIR/version.txt")" = "v1" ]
  [ ! -f "$INSTALL_DIR/.autopilot_self_update" ]
}

# --- Failed pull ---

@test "self_update: failed fetch logs warning but does not block" {
  # Remove origin so fetch will fail.
  git -C "$INSTALL_DIR" remote remove origin

  check_self_update "$TEST_PROJECT_DIR"

  # Should have logged a warning.
  [[ "$(_read_log)" == *"git fetch failed"* ]]
}

@test "self_update: non-fast-forward merge logs warning but does not block" {
  # Create divergent history.
  echo "local-change" > "$INSTALL_DIR/local.txt"
  git -C "$INSTALL_DIR" add -A >/dev/null 2>&1
  git -C "$INSTALL_DIR" commit -m "local diverge" -q

  local clone_dir="$BATS_TEST_TMPDIR/clone"
  git clone "$ORIGIN_DIR" "$clone_dir" 2>/dev/null
  echo "remote-change" > "$clone_dir/remote.txt"
  git -C "$clone_dir" add -A >/dev/null 2>&1
  git -C "$clone_dir" commit -m "remote diverge" -q
  git -C "$clone_dir" push origin main -q 2>/dev/null

  check_self_update "$TEST_PROJECT_DIR"

  [[ "$(_read_log)" == *"fast-forward merge failed"* ]]
}
