#!/usr/bin/env bats
# Tests for launchd plist generation (--generate-only) and symlink resolution.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

REPO_DIR="$BATS_TEST_DIRNAME/.."

load helpers/launchd_setup

setup_file() {
  export _REAL_HOME="$HOME"
  export _LAUNCHD_MOCK_BIN="${BATS_FILE_TMPDIR}/mock_bin"
  _create_launchd_mocks "$_LAUNCHD_MOCK_BIN"

  # Cache the default --generate-only output (used by ~15 tests).
  local proj="${BATS_FILE_TMPDIR}/gen_project"
  mkdir -p "$proj/.autopilot/logs"
  export _GEN_OUTPUT
  _GEN_OUTPUT="$(PATH="$_LAUNCHD_MOCK_BIN:$PATH" "$REPO_DIR/bin/autopilot-schedule" --generate-only "$proj" 2>&1)"
  export _GEN_STATUS=$?
  export _GEN_PROJECT_DIR="$proj"
}

teardown_file() {
  rm -rf "$_LAUNCHD_MOCK_BIN"
}

setup() {
  _launchd_test_setup
}

teardown() {
  _launchd_test_teardown
}

# --- Plist generation (--generate-only, using cached output) ---

@test "generate: produces valid XML for dispatcher" {
  [ "$_GEN_STATUS" -eq 0 ]
  local dispatcher_plist
  dispatcher_plist="$(echo "$_GEN_OUTPUT" | sed '/^---$/,$d')"
  echo "$dispatcher_plist" | xmllint --noout -
}

@test "generate: substitutes project directory" {
  [ "$_GEN_STATUS" -eq 0 ]
  [[ "$_GEN_OUTPUT" == *"$_GEN_PROJECT_DIR"* ]]
  [[ "$_GEN_OUTPUT" != *"__AUTOPILOT_PROJECT_DIR__"* ]]
}

@test "generate: substitutes account number" {
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only --account 42 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"${TEST_LABEL_PREFIX}.dispatcher.42"* ]]
  [[ "$output" == *"${TEST_LABEL_PREFIX}.reviewer.42"* ]]
  [[ "$output" != *"__AUTOPILOT_ACCOUNT__"* ]]
}

@test "generate: substitutes default interval (15)" {
  [ "$_GEN_STATUS" -eq 0 ]
  [[ "$_GEN_OUTPUT" == *"<integer>15</integer>"* ]]
  [[ "$_GEN_OUTPUT" != *"__AUTOPILOT_START_INTERVAL__"* ]]
}

@test "generate: substitutes custom interval" {
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only --interval 30 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<integer>30</integer>"* ]]
}

@test "generate: substitutes HOME directory" {
  [ "$_GEN_STATUS" -eq 0 ]
  [[ "$_GEN_OUTPUT" == *"$_REAL_HOME"* ]]
  [[ "$_GEN_OUTPUT" != *"__AUTOPILOT_HOME__"* ]]
  [[ "$_GEN_OUTPUT" != *"__HOME__"* ]]
}

@test "generate: PATH includes HOME/.local/bin" {
  [ "$_GEN_STATUS" -eq 0 ]
  local path_value
  path_value="$(echo "$_GEN_OUTPUT" | grep -A1 '<key>PATH</key>' | tail -1)"
  [[ "$path_value" == *"${_REAL_HOME}/.local/bin"* ]]
}

@test "generate: substitutes log directory" {
  [ "$_GEN_STATUS" -eq 0 ]
  [[ "$_GEN_OUTPUT" == *"${_GEN_PROJECT_DIR}/.autopilot/logs"* ]]
  [[ "$_GEN_OUTPUT" != *"__AUTOPILOT_LOG_DIR__"* ]]
}

@test "generate: substitutes bin directory" {
  [ "$_GEN_STATUS" -eq 0 ]
  [[ "$_GEN_OUTPUT" != *"__AUTOPILOT_BIN_DIR__"* ]]
}

@test "generate: no substitution markers remain" {
  [ "$_GEN_STATUS" -eq 0 ]
  if echo "$_GEN_OUTPUT" | grep -qE '__AUTOPILOT_|__CLAUDE_|__HOME__'; then
    echo "Unsubstituted markers found in output:"
    echo "$_GEN_OUTPUT" | grep -E '__AUTOPILOT_|__CLAUDE_|__HOME__'
    return 1
  fi
}

@test "generate: dispatcher label includes account" {
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only --account 3 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"${TEST_LABEL_PREFIX}.dispatcher.3"* ]]
}

@test "generate: reviewer label includes account" {
  run "$REPO_DIR/bin/autopilot-schedule" --generate-only --account 3 "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"${TEST_LABEL_PREFIX}.reviewer.3"* ]]
}

@test "generate: output contains both dispatcher and reviewer" {
  [ "$_GEN_STATUS" -eq 0 ]
  [[ "$_GEN_OUTPUT" == *"autopilot-dispatch"* ]]
  [[ "$_GEN_OUTPUT" == *"autopilot-review"* ]]
}

@test "generate: dispatcher has KeepAlive false" {
  [ "$_GEN_STATUS" -eq 0 ]
  local dispatcher_plist
  dispatcher_plist="$(echo "$_GEN_OUTPUT" | sed '/^---$/,$d')"
  echo "$dispatcher_plist" | grep -q '<false/>'
}

# --- Symlink resolution ---

@test "symlink: autopilot-schedule works via symlink" {
  local symlink_dir="$BATS_TEST_TMPDIR/symlink_dir"
  mkdir -p "$symlink_dir"

  ln -sf "$REPO_DIR/bin/autopilot-schedule" "$symlink_dir/autopilot-schedule"
  run "$symlink_dir/autopilot-schedule" --generate-only "$TEST_PROJECT_DIR"

  [ "$status" -eq 0 ]
  [[ "$output" == *"autopilot-dispatch"* ]]
  [[ "$output" == *"autopilot-review"* ]]
  [[ "$output" != *"__AUTOPILOT_"* ]]
  [[ "$output" != *"__CLAUDE_"* ]]
  [[ "$output" != *"__HOME__"* ]]
}
