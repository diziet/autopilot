#!/usr/bin/env bats
# Tests for lib/hooks.sh — Coder lint/test Stop hooks.

setup() {
  TEST_PROJECT_DIR="$(mktemp -d)"
  TEST_HOOKS_DIR="$(mktemp -d)"

  # Unset all AUTOPILOT_* env vars to start clean.
  while IFS= read -r var; do
    unset "$var"
  done < <(env | grep '^AUTOPILOT_' | cut -d= -f1)

  unset CLAUDECODE
  unset CLAUDE_CONFIG_DIR

  # Source hooks.sh (which also sources config.sh, state.sh).
  source "$BATS_TEST_DIRNAME/../lib/hooks.sh"
  load_config "$TEST_PROJECT_DIR"

  # Initialize pipeline state dir for log_msg.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR"
  rm -rf "$TEST_HOOKS_DIR"
}

# --- resolve_hooks_dir ---

@test "resolve_hooks_dir uses HOME/.claude by default" {
  unset CLAUDE_CONFIG_DIR
  local result
  result="$(resolve_hooks_dir "")"
  [ "$result" = "${HOME}/.claude/settings.json" ]
}

@test "resolve_hooks_dir uses config_dir when provided" {
  local result
  result="$(resolve_hooks_dir "/custom/config")"
  [ "$result" = "/custom/config/settings.json" ]
}

@test "resolve_hooks_dir uses CLAUDE_CONFIG_DIR env var" {
  export CLAUDE_CONFIG_DIR="/env/config"
  local result
  result="$(resolve_hooks_dir "")"
  [ "$result" = "/env/config/settings.json" ]
  unset CLAUDE_CONFIG_DIR
}

@test "resolve_hooks_dir prefers config_dir over CLAUDE_CONFIG_DIR" {
  export CLAUDE_CONFIG_DIR="/env/config"
  local result
  result="$(resolve_hooks_dir "/explicit/config")"
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
  # Should return valid JSON without error.
  echo "$result" | jq . >/dev/null
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

# --- generate_lint_hook ---

@test "generate_lint_hook outputs shell script" {
  local result
  result="$(generate_lint_hook "$TEST_PROJECT_DIR")"
  [[ "$result" == *"#!/usr/bin/env bash"* ]]
  [[ "$result" == *"make lint"* ]]
}

# --- generate_test_hook ---

@test "generate_test_hook uses AUTOPILOT_TEST_CMD when set" {
  AUTOPILOT_TEST_CMD="bats tests/"
  local result
  result="$(generate_test_hook "$TEST_PROJECT_DIR")"
  [[ "$result" == *"bats tests/"* ]]
}

@test "generate_test_hook uses make test by default" {
  AUTOPILOT_TEST_CMD=""
  local result
  result="$(generate_test_hook "$TEST_PROJECT_DIR")"
  [[ "$result" == *"make test"* ]]
}
