#!/usr/bin/env bats
# Tests for lib/hooks.sh — Coder lint/test Stop hooks and two-phase runner.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/hooks.sh"
source "$BATS_TEST_DIRNAME/../lib/twophase.sh"

setup_file() { _create_test_template; }
teardown_file() { _cleanup_test_template; }

setup() {
  _init_test_from_template_nogit
  TEST_HOOKS_DIR="$BATS_TEST_TMPDIR/hooks"
  mkdir -p "$TEST_HOOKS_DIR"
  load_config "$TEST_PROJECT_DIR"
}

# --- resolve_settings_file ---

@test "resolve_settings_file uses HOME/.claude by default" {
  unset CLAUDE_CONFIG_DIR
  local result
  result="$(resolve_settings_file "")"
  [ "$result" = "${HOME}/.claude/settings.json" ]
}

@test "resolve_settings_file uses config_dir when provided" {
  local result
  result="$(resolve_settings_file "/custom/config")"
  [ "$result" = "/custom/config/settings.json" ]
}

@test "resolve_settings_file uses CLAUDE_CONFIG_DIR env var" {
  export CLAUDE_CONFIG_DIR="/env/config"
  local result
  result="$(resolve_settings_file "")"
  [ "$result" = "/env/config/settings.json" ]
  unset CLAUDE_CONFIG_DIR
}

@test "resolve_settings_file prefers config_dir over CLAUDE_CONFIG_DIR" {
  export CLAUDE_CONFIG_DIR="/env/config"
  local result
  result="$(resolve_settings_file "/explicit/config")"
  [ "$result" = "/explicit/config/settings.json" ]
  unset CLAUDE_CONFIG_DIR
}

# --- _build_lint_command ---

@test "_build_lint_command returns make lint when Makefile exists" {
  cat > "$TEST_PROJECT_DIR/Makefile" <<'MK'
lint:
	echo "linting"
MK
  local result
  result="$(_build_lint_command "$TEST_PROJECT_DIR")"
  [[ "$result" == *"make lint"* ]]
}

@test "_build_lint_command returns true when no Makefile" {
  local result
  result="$(_build_lint_command "$TEST_PROJECT_DIR")"
  [ "$result" = "true" ]
}

# --- _build_test_command ---

@test "_build_test_command uses AUTOPILOT_TEST_CMD when set" {
  AUTOPILOT_TEST_CMD="pytest -x"
  local result
  result="$(_build_test_command "$TEST_PROJECT_DIR")"
  [[ "$result" == *"pytest -x"* ]]
}

@test "_build_test_command uses make test when Makefile present" {
  AUTOPILOT_TEST_CMD=""
  cat > "$TEST_PROJECT_DIR/Makefile" <<'MK'
test:
	echo "testing"
MK
  local result
  result="$(_build_test_command "$TEST_PROJECT_DIR")"
  [[ "$result" == *"make test"* ]]
}

@test "_build_test_command returns true when no Makefile and no config" {
  AUTOPILOT_TEST_CMD=""
  local result
  result="$(_build_test_command "$TEST_PROJECT_DIR")"
  [ "$result" = "true" ]
}

# --- _add_hooks_to_settings ---

@test "_add_hooks_to_settings adds hooks to empty settings" {
  local result
  result="$(_add_hooks_to_settings '{}' 'make lint' 'make test')"
  local count
  count="$(echo "$result" | jq '.hooks.stop | length')"
  [ "$count" -eq 2 ]
}

@test "_add_hooks_to_settings preserves existing stop hooks" {
  local existing='{"hooks":{"stop":[{"command":"existing","description":"other"}]}}'
  local result
  result="$(_add_hooks_to_settings "$existing" 'make lint' 'make test')"
  local count
  count="$(echo "$result" | jq '.hooks.stop | length')"
  [ "$count" -eq 3 ]
}

@test "_add_hooks_to_settings sets correct descriptions" {
  local result
  result="$(_add_hooks_to_settings '{}' 'lint-cmd' 'test-cmd')"

  local lint_desc
  lint_desc="$(echo "$result" | jq -r '.hooks.stop[0].description')"
  [ "$lint_desc" = "autopilot-lint-hook" ]

  local test_desc
  test_desc="$(echo "$result" | jq -r '.hooks.stop[1].description')"
  [ "$test_desc" = "autopilot-test-hook" ]
}

@test "_add_hooks_to_settings sets correct commands" {
  local result
  result="$(_add_hooks_to_settings '{}' 'my-lint' 'my-test')"

  local lint_cmd
  lint_cmd="$(echo "$result" | jq -r '.hooks.stop[0].command')"
  [ "$lint_cmd" = "my-lint" ]

  local test_cmd
  test_cmd="$(echo "$result" | jq -r '.hooks.stop[1].command')"
  [ "$test_cmd" = "my-test" ]
}

# --- _remove_hooks_from_settings ---

@test "_remove_hooks_from_settings removes autopilot hooks" {
  local with_hooks
  with_hooks='{"hooks":{"stop":[
    {"command":"lint","description":"autopilot-lint-hook"},
    {"command":"test","description":"autopilot-test-hook"}
  ]}}'
  local result
  result="$(_remove_hooks_from_settings "$with_hooks")"
  local count
  count="$(echo "$result" | jq '.hooks.stop | length')"
  [ "$count" -eq 0 ]
}

@test "_remove_hooks_from_settings preserves non-autopilot hooks" {
  local with_hooks
  with_hooks='{"hooks":{"stop":[
    {"command":"custom","description":"user-hook"},
    {"command":"lint","description":"autopilot-lint-hook"},
    {"command":"test","description":"autopilot-test-hook"}
  ]}}'
  local result
  result="$(_remove_hooks_from_settings "$with_hooks")"
  local count
  count="$(echo "$result" | jq '.hooks.stop | length')"
  [ "$count" -eq 1 ]

  local desc
  desc="$(echo "$result" | jq -r '.hooks.stop[0].description')"
  [ "$desc" = "user-hook" ]
}

@test "_remove_hooks_from_settings handles missing hooks section" {
  local result
  result="$(_remove_hooks_from_settings '{}')"
  # Should return unchanged empty object.
  [ "$(echo "$result" | jq -c .)" = "{}" ]
}

# --- install_hooks (integration) ---

@test "install_hooks creates settings.json with hooks" {
  local result
  install_hooks "$TEST_PROJECT_DIR" "$TEST_HOOKS_DIR"
  local settings_file="${TEST_HOOKS_DIR}/settings.json"
  [ -f "$settings_file" ]

  local count
  count="$(jq '.hooks.stop | length' "$settings_file")"
  [ "$count" -eq 2 ]
}

@test "install_hooks creates backup of existing settings" {
  local settings_file="${TEST_HOOKS_DIR}/settings.json"
  mkdir -p "$TEST_HOOKS_DIR"
  echo '{"existing": true}' > "$settings_file"

  install_hooks "$TEST_PROJECT_DIR" "$TEST_HOOKS_DIR"

  local backup_file="${settings_file}.autopilot-backup"
  [ -f "$backup_file" ]

  local existing_val
  existing_val="$(jq -r '.existing' "$backup_file")"
  [ "$existing_val" = "true" ]
}

@test "install_hooks preserves existing settings content" {
  local settings_file="${TEST_HOOKS_DIR}/settings.json"
  mkdir -p "$TEST_HOOKS_DIR"
  echo '{"theme": "dark", "hooks": {"stop": []}}' > "$settings_file"

  install_hooks "$TEST_PROJECT_DIR" "$TEST_HOOKS_DIR"

  local theme
  theme="$(jq -r '.theme' "$settings_file")"
  [ "$theme" = "dark" ]
}

# --- remove_hooks (integration) ---

@test "remove_hooks restores from backup when available" {
  local settings_file="${TEST_HOOKS_DIR}/settings.json"
  mkdir -p "$TEST_HOOKS_DIR"
  echo '{"original": true}' > "$settings_file"

  install_hooks "$TEST_PROJECT_DIR" "$TEST_HOOKS_DIR"

  # Verify hooks are installed.
  local count
  count="$(jq '.hooks.stop | length' "$settings_file")"
  [ "$count" -eq 2 ]

  remove_hooks "$TEST_PROJECT_DIR" "$TEST_HOOKS_DIR"

  # Should be back to original.
  local original
  original="$(jq -r '.original' "$settings_file")"
  [ "$original" = "true" ]

  # Backup should be gone.
  [ ! -f "${settings_file}.autopilot-backup" ]
}

@test "remove_hooks removes hook entries when no backup" {
  local settings_file="${TEST_HOOKS_DIR}/settings.json"
  mkdir -p "$TEST_HOOKS_DIR"
  echo '{"hooks":{"stop":[
    {"command":"lint","description":"autopilot-lint-hook"},
    {"command":"test","description":"autopilot-test-hook"}
  ]}}' > "$settings_file"

  # Remove backup if it exists.
  rm -f "${settings_file}.autopilot-backup"

  remove_hooks "$TEST_PROJECT_DIR" "$TEST_HOOKS_DIR"

  local count
  count="$(jq '.hooks.stop | length' "$settings_file")"
  [ "$count" -eq 0 ]
}

@test "remove_hooks succeeds when no settings file exists" {
  rm -f "${TEST_HOOKS_DIR}/settings.json"
  run remove_hooks "$TEST_PROJECT_DIR" "$TEST_HOOKS_DIR"
  [ "$status" -eq 0 ]
}

# --- hooks_installed ---

@test "hooks_installed returns 0 when hooks present" {
  install_hooks "$TEST_PROJECT_DIR" "$TEST_HOOKS_DIR"
  hooks_installed "$TEST_HOOKS_DIR"
}

@test "hooks_installed returns 1 when no hooks" {
  local settings_file="${TEST_HOOKS_DIR}/settings.json"
  mkdir -p "$TEST_HOOKS_DIR"
  echo '{}' > "$settings_file"

  run hooks_installed "$TEST_HOOKS_DIR"
  [ "$status" -eq 1 ]
}

@test "hooks_installed returns 1 when no settings file" {
  rm -f "${TEST_HOOKS_DIR}/settings.json"
  run hooks_installed "$TEST_HOOKS_DIR"
  [ "$status" -eq 1 ]
}

# --- Round-trip: install then remove ---

@test "install then remove is idempotent" {
  local settings_file="${TEST_HOOKS_DIR}/settings.json"
  mkdir -p "$TEST_HOOKS_DIR"
  echo '{"user_setting": 42}' > "$settings_file"

  install_hooks "$TEST_PROJECT_DIR" "$TEST_HOOKS_DIR"
  hooks_installed "$TEST_HOOKS_DIR"

  remove_hooks "$TEST_PROJECT_DIR" "$TEST_HOOKS_DIR"
  run hooks_installed "$TEST_HOOKS_DIR"
  [ "$status" -eq 1 ]

  # User setting should be preserved.
  local val
  val="$(jq -r '.user_setting' "$settings_file")"
  [ "$val" = "42" ]
}

# --- _build_lint_command target verification ---

@test "_build_lint_command returns true when Makefile lacks lint target" {
  cat > "$TEST_PROJECT_DIR/Makefile" <<'MK'
build:
	echo "building"
MK
  local result
  result="$(_build_lint_command "$TEST_PROJECT_DIR")"
  [ "$result" = "true" ]
}

# --- _build_test_command target verification ---

@test "_build_test_command returns true when Makefile lacks test target" {
  AUTOPILOT_TEST_CMD=""
  cat > "$TEST_PROJECT_DIR/Makefile" <<'MK'
build:
	echo "building"
MK
  local result
  result="$(_build_test_command "$TEST_PROJECT_DIR")"
  [ "$result" = "true" ]
}

# --- _backup_settings crash recovery ---

@test "_backup_settings does not overwrite existing backup" {
  local settings_file="${TEST_HOOKS_DIR}/settings.json"
  local backup_file="${settings_file}.autopilot-backup"
  mkdir -p "$TEST_HOOKS_DIR"
  echo '{"clean": true}' > "$backup_file"
  echo '{"hooks":{"stop":[{"command":"stale","description":"autopilot-lint-hook"}]}}' > "$settings_file"

  _backup_settings "$settings_file"

  # Backup should still contain the clean version.
  local val
  val="$(jq -r '.clean' "$backup_file")"
  [ "$val" = "true" ]
}

# --- _build_test_command bats detection ---

@test "_build_test_command uses two-phase runner when bats tests detected" {
  AUTOPILOT_TEST_CMD=""
  mkdir -p "$TEST_PROJECT_DIR/tests"
  touch "$TEST_PROJECT_DIR/tests/test_example.bats"
  local result
  result="$(_build_test_command "$TEST_PROJECT_DIR")"
  [[ "$result" == *"twophase.sh"* ]]
}

@test "_build_test_command prefers AUTOPILOT_TEST_CMD over two-phase" {
  AUTOPILOT_TEST_CMD="pytest -x"
  mkdir -p "$TEST_PROJECT_DIR/tests"
  touch "$TEST_PROJECT_DIR/tests/test_example.bats"
  local result
  result="$(_build_test_command "$TEST_PROJECT_DIR")"
  [[ "$result" == *"pytest -x"* ]]
  [[ "$result" != *"twophase.sh"* ]]
}

# --- Two-Phase Bats Runner (lib/twophase.sh) ---

# TAP parsing

@test "parse_tap_failures extracts file paths from TAP diagnostics" {
  local tap_file="$TEST_PROJECT_DIR/tap_output.txt"
  {
    echo "1..3"
    echo "ok 1 test passes"
    echo "not ok 2 test fails"
    echo "#  in test file tests/test_config.bats, line 42)"
    echo "ok 3 test passes too"
  } > "$tap_file"
  local tap_output
  tap_output="$(cat "$tap_file")"
  local result
  result="$(parse_tap_failures "$tap_output")"
  [ "$result" = "tests/test_config.bats" ]
}

@test "parse_tap_failures returns empty for all-passing TAP" {
  local tap_output
  tap_output="$(printf '1..2\nok 1 test passes\nok 2 test also passes\n')"
  local result
  result="$(parse_tap_failures "$tap_output")"
  [ -z "$result" ]
}

@test "parse_tap_failures deduplicates file paths" {
  local tap_file="$TEST_PROJECT_DIR/tap_output.txt"
  {
    echo "1..4"
    echo "not ok 1 first failure"
    echo "#  in test file tests/test_config.bats, line 10)"
    echo "not ok 2 second failure in same file"
    echo "#  in test file tests/test_config.bats, line 20)"
    echo "not ok 3 failure in different file"
    echo "#  in test file tests/test_state.bats, line 5)"
    echo "ok 4 passes"
  } > "$tap_file"
  local tap_output
  tap_output="$(cat "$tap_file")"
  local result
  result="$(parse_tap_failures "$tap_output")"
  local count
  count="$(echo "$result" | wc -l | tr -d ' ')"
  [ "$count" -eq 2 ]
  echo "$result" | grep -q "tests/test_config.bats"
  echo "$result" | grep -q "tests/test_state.bats"
}

# Cache management

@test "write_last_failed_tests creates cache file" {
  echo "tests/test_foo.bats" | write_last_failed_tests "$TEST_PROJECT_DIR"
  [ -f "$TEST_PROJECT_DIR/.autopilot/.last-failed-tests" ]
}

@test "read_last_failed_tests reads cached paths" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  printf "tests/test_a.bats\ntests/test_b.bats\n" \
    > "$TEST_PROJECT_DIR/.autopilot/.last-failed-tests"
  local result
  result="$(read_last_failed_tests "$TEST_PROJECT_DIR")"
  echo "$result" | grep -q "tests/test_a.bats"
  echo "$result" | grep -q "tests/test_b.bats"
}

@test "clear_last_failed_tests removes cache" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  echo "tests/test_foo.bats" > "$TEST_PROJECT_DIR/.autopilot/.last-failed-tests"
  clear_last_failed_tests "$TEST_PROJECT_DIR"
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/.last-failed-tests" ]
}

@test "has_last_failed_tests returns 0 when cache has content" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  echo "tests/test_foo.bats" > "$TEST_PROJECT_DIR/.autopilot/.last-failed-tests"
  has_last_failed_tests "$TEST_PROJECT_DIR"
}

@test "has_last_failed_tests returns 1 when no cache" {
  rm -f "$TEST_PROJECT_DIR/.autopilot/.last-failed-tests"
  run has_last_failed_tests "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

@test "has_last_failed_tests returns 1 when cache is empty" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  : > "$TEST_PROJECT_DIR/.autopilot/.last-failed-tests"
  run has_last_failed_tests "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

# Two-phase runner (with mock bats)

@test "run_bats_two_phase runs full suite when no cache exists" {
  # Create mock bats that always passes.
  local mock_dir="$TEST_PROJECT_DIR/mock_bin"
  mkdir -p "$mock_dir" "$TEST_PROJECT_DIR/tests"
  cat > "$mock_dir/bats" <<'MOCK'
#!/usr/bin/env bash
echo "1..1"
echo "ok 1 test passes"
exit 0
MOCK
  chmod +x "$mock_dir/bats"

  rm -f "$TEST_PROJECT_DIR/.autopilot/.last-failed-tests"
  run env PATH="$mock_dir:$PATH" bash -c \
    'source "'"$BATS_TEST_DIRNAME"'/../lib/twophase.sh" && run_bats_two_phase "'"$TEST_PROJECT_DIR"'"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok 1"* ]]
}

@test "run_bats_two_phase with failing cache rejects fast (phase 1 fails)" {
  # Create a test file that the cache references.
  mkdir -p "$TEST_PROJECT_DIR/tests"
  touch "$TEST_PROJECT_DIR/tests/test_broken.bats"

  # Write cache with the failing file.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  echo "tests/test_broken.bats" > "$TEST_PROJECT_DIR/.autopilot/.last-failed-tests"

  # Mock bats: fails when given specific files (phase 1).
  local mock_dir="$TEST_PROJECT_DIR/mock_bin"
  mkdir -p "$mock_dir"
  cat > "$mock_dir/bats" <<'MOCK'
#!/usr/bin/env bash
# If called with specific .bats files (phase 1), fail.
for arg in "$@"; do
  if [[ "$arg" == *.bats ]]; then
    echo "1..1"
    echo "not ok 1 test still broken"
    echo "#  in test file tests/test_broken.bats, line 5)"
    exit 1
  fi
done
# Full suite (phase 2) — should not reach here.
echo "1..1"
echo "ok 1 test passes"
exit 0
MOCK
  chmod +x "$mock_dir/bats"

  run env PATH="$mock_dir:$PATH" bash -c \
    'source "'"$BATS_TEST_DIRNAME"'/../lib/twophase.sh" && run_bats_two_phase "'"$TEST_PROJECT_DIR"'"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"not ok"* ]]
}

@test "run_bats_two_phase with passing cache runs full suite (phase 2)" {
  # Create a test file referenced by cache.
  mkdir -p "$TEST_PROJECT_DIR/tests"
  touch "$TEST_PROJECT_DIR/tests/test_fixed.bats"

  # Cache says this file was failing.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  echo "tests/test_fixed.bats" > "$TEST_PROJECT_DIR/.autopilot/.last-failed-tests"

  # Track which phases ran.
  local track_file="$TEST_PROJECT_DIR/phases_run"

  local mock_dir="$TEST_PROJECT_DIR/mock_bin"
  mkdir -p "$mock_dir"
  cat > "$mock_dir/bats" <<MOCK
#!/usr/bin/env bash
# Track invocation.
echo "called: \$*" >> "$track_file"
echo "1..1"
echo "ok 1 test passes"
exit 0
MOCK
  chmod +x "$mock_dir/bats"

  run env PATH="$mock_dir:$PATH" bash -c \
    'source "'"$BATS_TEST_DIRNAME"'/../lib/twophase.sh" && run_bats_two_phase "'"$TEST_PROJECT_DIR"'"'
  [ "$status" -eq 0 ]

  # Both phases should have run.
  local call_count
  call_count="$(wc -l < "$track_file" | tr -d ' ')"
  [ "$call_count" -eq 2 ]
}

@test "run_bats_two_phase clears cache after clean full run" {
  # No cache — run full suite that passes.
  mkdir -p "$TEST_PROJECT_DIR/tests"

  local mock_dir="$TEST_PROJECT_DIR/mock_bin"
  mkdir -p "$mock_dir"
  cat > "$mock_dir/bats" <<'MOCK'
#!/usr/bin/env bash
echo "1..1"
echo "ok 1 test passes"
exit 0
MOCK
  chmod +x "$mock_dir/bats"

  # Pre-create cache to verify it gets cleared.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  echo "tests/test_old.bats" > "$TEST_PROJECT_DIR/.autopilot/.last-failed-tests"

  # Run — phase 1 will skip (test_old.bats doesn't exist), phase 2 passes.
  run env PATH="$mock_dir:$PATH" bash -c \
    'source "'"$BATS_TEST_DIRNAME"'/../lib/twophase.sh" && run_bats_two_phase "'"$TEST_PROJECT_DIR"'"'
  [ "$status" -eq 0 ]

  # Cache should be cleared after clean run.
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/.last-failed-tests" ]
}

@test "run_bats_two_phase updates cache on full suite failure" {
  mkdir -p "$TEST_PROJECT_DIR/tests"
  rm -f "$TEST_PROJECT_DIR/.autopilot/.last-failed-tests"

  # Mock bats: full suite fails with diagnostics.
  local mock_dir="$TEST_PROJECT_DIR/mock_bin"
  mkdir -p "$mock_dir"
  cat > "$mock_dir/bats" <<'MOCK'
#!/usr/bin/env bash
echo "1..2"
echo "ok 1 test passes"
echo "not ok 2 test fails"
echo "#  in test file tests/test_state.bats, line 10)"
exit 1
MOCK
  chmod +x "$mock_dir/bats"

  run env PATH="$mock_dir:$PATH" bash -c \
    'source "'"$BATS_TEST_DIRNAME"'/../lib/twophase.sh" && run_bats_two_phase "'"$TEST_PROJECT_DIR"'"'
  [ "$status" -eq 1 ]

  # Cache should now contain the failing file.
  [ -f "$TEST_PROJECT_DIR/.autopilot/.last-failed-tests" ]
  grep -q "tests/test_state.bats" "$TEST_PROJECT_DIR/.autopilot/.last-failed-tests"
}
