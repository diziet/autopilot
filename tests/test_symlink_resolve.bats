#!/usr/bin/env bats
# Tests for symlink resolution in bin/ scripts and entry-common.sh.
# Verifies scripts work when invoked via symlinks (e.g. after make install).

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

REPO_DIR="$BATS_TEST_DIRNAME/.."

setup() {
  SYMLINK_DIR="$BATS_TEST_TMPDIR/symlinks"
  mkdir -p "$SYMLINK_DIR"
}

# --- resolve_script_path (entry-common.sh helper) ---

@test "resolve_script_path: returns same path for non-symlink" {
  source "$REPO_DIR/lib/entry-common.sh"
  local result
  result="$(resolve_script_path "$REPO_DIR/bin/autopilot-dispatch")"
  [[ "$result" == *"/bin/autopilot-dispatch" ]]
}

@test "resolve_script_path: resolves a single symlink" {
  source "$REPO_DIR/lib/entry-common.sh"
  ln -sf "$REPO_DIR/bin/autopilot-dispatch" "$SYMLINK_DIR/dispatch-link"

  local result
  result="$(resolve_script_path "$SYMLINK_DIR/dispatch-link")"
  # Should resolve to the real file, not the symlink.
  [[ "$result" == *"/bin/autopilot-dispatch" ]]
  [[ "$result" != *"$SYMLINK_DIR"* ]]
}

@test "resolve_script_path: resolves chained symlinks" {
  source "$REPO_DIR/lib/entry-common.sh"
  ln -sf "$REPO_DIR/bin/autopilot-dispatch" "$SYMLINK_DIR/link1"
  ln -sf "$SYMLINK_DIR/link1" "$SYMLINK_DIR/link2"

  local result
  result="$(resolve_script_path "$SYMLINK_DIR/link2")"
  [[ "$result" == *"/bin/autopilot-dispatch" ]]
  [[ "$result" != *"$SYMLINK_DIR"* ]]
}

@test "resolve_script_path: handles relative symlink targets" {
  source "$REPO_DIR/lib/entry-common.sh"
  # Create a relative symlink (readlink returns relative path).
  ln -sf "../../$(basename "$REPO_DIR")/bin/autopilot-dispatch" "$SYMLINK_DIR/rel-link"

  local result
  result="$(resolve_script_path "$SYMLINK_DIR/rel-link")"
  [[ "$result" == *"/bin/autopilot-dispatch" ]]
}

# --- resolve_lib_dir with symlinks ---

@test "resolve_lib_dir: resolves lib path through symlink" {
  source "$REPO_DIR/lib/entry-common.sh"
  ln -sf "$REPO_DIR/bin/autopilot-dispatch" "$SYMLINK_DIR/dispatch-link"

  local result
  result="$(resolve_lib_dir "$SYMLINK_DIR/dispatch-link")"
  # Should point to the real lib/ dir, not a path relative to the symlink.
  [[ "$result" == *"/lib" ]]
  [[ "$result" != *"$SYMLINK_DIR"* ]]
}

@test "resolve_lib_dir: still works with direct path (no symlink)" {
  source "$REPO_DIR/lib/entry-common.sh"
  local result
  result="$(resolve_lib_dir "$REPO_DIR/bin/autopilot-dispatch")"
  [[ "$result" == *"/lib" ]]
}

# --- bin/ scripts source entry-common.sh through symlinks ---

@test "autopilot-dispatch: --help works via symlink" {
  ln -sf "$REPO_DIR/bin/autopilot-dispatch" "$SYMLINK_DIR/autopilot-dispatch"
  run "$SYMLINK_DIR/autopilot-dispatch" --help
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "autopilot-doctor: --help works via symlink" {
  ln -sf "$REPO_DIR/bin/autopilot-doctor" "$SYMLINK_DIR/autopilot-doctor"
  run "$SYMLINK_DIR/autopilot-doctor" --help
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "autopilot-review: --help works via symlink" {
  ln -sf "$REPO_DIR/bin/autopilot-review" "$SYMLINK_DIR/autopilot-review"
  run "$SYMLINK_DIR/autopilot-review" --help
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "autopilot-start: --help works via symlink" {
  ln -sf "$REPO_DIR/bin/autopilot-start" "$SYMLINK_DIR/autopilot-start"
  run "$SYMLINK_DIR/autopilot-start" --help
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "autopilot-status: --help works via symlink" {
  ln -sf "$REPO_DIR/bin/autopilot-status" "$SYMLINK_DIR/autopilot-status"
  run "$SYMLINK_DIR/autopilot-status" --help
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "autopilot-live-test: --help works via symlink" {
  ln -sf "$REPO_DIR/bin/autopilot-live-test" "$SYMLINK_DIR/autopilot-live-test"
  run "$SYMLINK_DIR/autopilot-live-test" --help
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

# --- Direct invocation still works ---

@test "autopilot-dispatch: --help works via direct path" {
  run "$REPO_DIR/bin/autopilot-dispatch" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "autopilot-review: --help works via direct path" {
  run "$REPO_DIR/bin/autopilot-review" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

# --- Chained symlink invocation ---

@test "autopilot-dispatch: --help works via chained symlinks" {
  ln -sf "$REPO_DIR/bin/autopilot-dispatch" "$SYMLINK_DIR/link1"
  ln -sf "$SYMLINK_DIR/link1" "$SYMLINK_DIR/link2"
  run "$SYMLINK_DIR/link2" --help
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}
