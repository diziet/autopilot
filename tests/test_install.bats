#!/usr/bin/env bats
# Tests for `make install` target — dependency checking, symlink creation,
# setup instructions, and example files.

REPO_DIR="$BATS_TEST_DIRNAME/.."

setup() {
  INSTALL_PREFIX="$(mktemp -d)"
  MOCK_BIN="$(mktemp -d)"
  OLD_PATH="$PATH"

  # Create mock commands that satisfy dependency checks.
  _create_mock_cmd "git" '--version' 'echo "git version 2.40.0"'
  _create_mock_cmd "jq" '--version' 'echo "jq-1.7"'
  _create_mock_cmd "gh" '--version' 'echo "gh version 2.44.0"'
  _create_mock_cmd "claude" '--version' 'echo "claude 1.0.0"'
  _create_mock_cmd "timeout" '--version' 'echo "timeout (GNU coreutils) 9.4"'
}

teardown() {
  PATH="$OLD_PATH"
  rm -rf "$INSTALL_PREFIX" "$MOCK_BIN"
}

# Create a mock command that responds to a specific flag.
_create_mock_cmd() {
  local name="$1" flag="$2" response="$3"
  cat > "$MOCK_BIN/$name" <<MOCK
#!/bin/bash
if [[ "\$1" == "$flag" ]]; then
  $response
fi
exit 0
MOCK
  chmod +x "$MOCK_BIN/$name"
}

# Remove a mock command to simulate a missing dependency.
_remove_mock_cmd() {
  rm -f "$MOCK_BIN/$1"
}

# --- check-deps script ---

@test "check-deps: scripts/check-deps.sh exists and is executable" {
  [ -f "$REPO_DIR/scripts/check-deps.sh" ]
  [ -x "$REPO_DIR/scripts/check-deps.sh" ]
}

@test "check-deps: scripts/check-deps.sh sources lib/preflight.sh" {
  grep -q 'preflight.sh' "$REPO_DIR/scripts/check-deps.sh"
}

# --- check-deps target ---

@test "check-deps: passes when all dependencies are present" {
  PATH="$MOCK_BIN:$PATH"
  run make -C "$REPO_DIR" check-deps PATH="$MOCK_BIN:$PATH"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"git"* ]]
  [[ "$output" == *"jq"* ]]
  [[ "$output" == *"gh"* ]]
  [[ "$output" == *"claude"* ]]
  [[ "$output" == *"timeout"* ]]
  [[ "$output" == *"All dependencies found"* ]]
}

@test "check-deps: fails when git is missing" {
  _remove_mock_cmd "git"
  run make -C "$REPO_DIR" check-deps PATH="$MOCK_BIN"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"git"* ]]
  [[ "$output" == *"MISSING"* ]]
}

@test "check-deps: fails when jq is missing" {
  _remove_mock_cmd "jq"
  run make -C "$REPO_DIR" check-deps PATH="$MOCK_BIN"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"jq"* ]]
  [[ "$output" == *"MISSING"* ]]
}

@test "check-deps: fails when gh is missing" {
  _remove_mock_cmd "gh"
  run make -C "$REPO_DIR" check-deps PATH="$MOCK_BIN"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"gh"* ]]
  [[ "$output" == *"MISSING"* ]]
}

@test "check-deps: fails when claude is missing" {
  _remove_mock_cmd "claude"
  run make -C "$REPO_DIR" check-deps PATH="$MOCK_BIN"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"claude"* ]]
  [[ "$output" == *"MISSING"* ]]
}

@test "check-deps: fails when timeout is missing with macOS guidance" {
  _remove_mock_cmd "timeout"
  run make -C "$REPO_DIR" check-deps PATH="$MOCK_BIN"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"timeout"* ]]
  [[ "$output" == *"MISSING"* ]]
  [[ "$output" == *"brew install coreutils"* ]]
  [[ "$output" == *"macOS"* ]]
}

@test "check-deps: reports multiple missing deps at once" {
  _remove_mock_cmd "jq"
  _remove_mock_cmd "gh"
  run make -C "$REPO_DIR" check-deps PATH="$MOCK_BIN"
  echo "$output"
  [ "$status" -ne 0 ]
  # Both should be reported as missing.
  [[ "$output" == *"jq"*"MISSING"* ]]
  [[ "$output" == *"gh"*"MISSING"* ]]
}

@test "check-deps: shows version info for present commands" {
  run make -C "$REPO_DIR" check-deps PATH="$MOCK_BIN:$PATH"
  echo "$output"
  [ "$status" -eq 0 ]
  # Version strings from mocks.
  [[ "$output" == *"git version"* ]]
  [[ "$output" == *"jq-1.7"* ]]
  [[ "$output" == *"gh version"* ]]
}

# --- install target: symlink creation ---

@test "install: creates symlinks for bin/autopilot-* in PREFIX/bin" {
  PATH="$MOCK_BIN:$PATH"
  run make -C "$REPO_DIR" install PREFIX="$INSTALL_PREFIX" PATH="$MOCK_BIN:$PATH"
  echo "$output"
  [ "$status" -eq 0 ]

  # Symlinks should exist.
  [ -L "$INSTALL_PREFIX/bin/autopilot-dispatch" ]
  [ -L "$INSTALL_PREFIX/bin/autopilot-review" ]
}

@test "install: symlinks point to the correct bin/ files" {
  PATH="$MOCK_BIN:$PATH"
  make -C "$REPO_DIR" install PREFIX="$INSTALL_PREFIX" PATH="$MOCK_BIN:$PATH"

  local dispatch_target review_target
  dispatch_target="$(readlink "$INSTALL_PREFIX/bin/autopilot-dispatch")"
  review_target="$(readlink "$INSTALL_PREFIX/bin/autopilot-review")"

  [[ "$dispatch_target" == *"/bin/autopilot-dispatch" ]]
  [[ "$review_target" == *"/bin/autopilot-review" ]]
}

@test "install: creates PREFIX/bin directory if it does not exist" {
  PATH="$MOCK_BIN:$PATH"
  local new_prefix="$INSTALL_PREFIX/deeply/nested"
  run make -C "$REPO_DIR" install PREFIX="$new_prefix" PATH="$MOCK_BIN:$PATH"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -d "$new_prefix/bin" ]
}

@test "install: re-running install updates existing symlinks" {
  PATH="$MOCK_BIN:$PATH"
  make -C "$REPO_DIR" install PREFIX="$INSTALL_PREFIX" PATH="$MOCK_BIN:$PATH"
  # Run again — should succeed (ln -sf overwrites).
  run make -C "$REPO_DIR" install PREFIX="$INSTALL_PREFIX" PATH="$MOCK_BIN:$PATH"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -L "$INSTALL_PREFIX/bin/autopilot-dispatch" ]
}

# --- install target: setup instructions ---

@test "install: prints PATH setup instruction" {
  PATH="$MOCK_BIN:$PATH"
  run make -C "$REPO_DIR" install PREFIX="$INSTALL_PREFIX" PATH="$MOCK_BIN:$PATH"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PATH"* ]]
}

@test "install: prints launchd scheduling instructions" {
  PATH="$MOCK_BIN:$PATH"
  run make -C "$REPO_DIR" install PREFIX="$INSTALL_PREFIX" PATH="$MOCK_BIN:$PATH"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"launchd"* ]]
  [[ "$output" == *"autopilot-schedule"* ]]
  [[ "$output" == *"install-launchd"* ]]
}

@test "install: prints config setup instructions" {
  PATH="$MOCK_BIN:$PATH"
  run make -C "$REPO_DIR" install PREFIX="$INSTALL_PREFIX" PATH="$MOCK_BIN:$PATH"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"autopilot.conf"* ]]
  [[ "$output" == *"dangerously-skip-permissions"* ]]
}

@test "install: prints project setup steps" {
  PATH="$MOCK_BIN:$PATH"
  run make -C "$REPO_DIR" install PREFIX="$INSTALL_PREFIX" PATH="$MOCK_BIN:$PATH"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *".gitignore"* ]]
  [[ "$output" == *"tasks"* ]]
}

@test "install: prints success banner" {
  PATH="$MOCK_BIN:$PATH"
  run make -C "$REPO_DIR" install PREFIX="$INSTALL_PREFIX" PATH="$MOCK_BIN:$PATH"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"installed successfully"* ]]
}

@test "install: references existing README.md not non-existent docs" {
  PATH="$MOCK_BIN:$PATH"
  run make -C "$REPO_DIR" install PREFIX="$INSTALL_PREFIX" PATH="$MOCK_BIN:$PATH"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"README.md"* ]]
  # Should NOT reference non-existent getting-started.md.
  [[ "$output" != *"getting-started.md"* ]]
}

# --- install target: failure modes ---

@test "install: fails when dependencies are missing" {
  _remove_mock_cmd "git"
  run make -C "$REPO_DIR" install PREFIX="$INSTALL_PREFIX" PATH="$MOCK_BIN"
  echo "$output"
  [ "$status" -ne 0 ]
  # Should not create symlinks when deps are missing.
  [ ! -L "$INSTALL_PREFIX/bin/autopilot-dispatch" ]
}

# --- PREFIX override ---

@test "install: respects custom PREFIX" {
  PATH="$MOCK_BIN:$PATH"
  local custom_prefix="$INSTALL_PREFIX/custom"
  run make -C "$REPO_DIR" install PREFIX="$custom_prefix" PATH="$MOCK_BIN:$PATH"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -L "$custom_prefix/bin/autopilot-dispatch" ]
  [ -L "$custom_prefix/bin/autopilot-review" ]
  [[ "$output" == *"$custom_prefix/bin"* ]]
}

# --- Example files ---

@test "examples: autopilot.conf exists and is non-empty" {
  [ -f "$REPO_DIR/examples/autopilot.conf" ]
  [ -s "$REPO_DIR/examples/autopilot.conf" ]
}

@test "examples: autopilot.conf contains all known AUTOPILOT_* variables" {
  local conf="$REPO_DIR/examples/autopilot.conf"
  # Check key variables are documented (commented out with #).
  [[ "$(cat "$conf")" == *"AUTOPILOT_CLAUDE_CMD"* ]]
  [[ "$(cat "$conf")" == *"AUTOPILOT_CLAUDE_FLAGS"* ]]
  [[ "$(cat "$conf")" == *"AUTOPILOT_TIMEOUT_CODER"* ]]
  [[ "$(cat "$conf")" == *"AUTOPILOT_MAX_RETRIES"* ]]
  [[ "$(cat "$conf")" == *"AUTOPILOT_TEST_CMD"* ]]
  [[ "$(cat "$conf")" == *"AUTOPILOT_REVIEWERS"* ]]
  [[ "$(cat "$conf")" == *"AUTOPILOT_BRANCH_PREFIX"* ]]
  [[ "$(cat "$conf")" == *"AUTOPILOT_TARGET_BRANCH"* ]]
}

@test "examples: autopilot.conf documents all variables from config.sh" {
  local conf="$REPO_DIR/examples/autopilot.conf"
  local config_sh="$REPO_DIR/lib/config.sh"
  local missing=()

  # Extract variable names from _AUTOPILOT_KNOWN_VARS in config.sh.
  while IFS= read -r varname; do
    [[ -z "$varname" ]] && continue
    if ! grep -q "$varname" "$conf"; then
      missing+=("$varname")
    fi
  done < <(grep '^AUTOPILOT_' "$config_sh" | head -40)

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Variables missing from examples/autopilot.conf: ${missing[*]}" >&2
    return 1
  fi
}

@test "examples: autopilot.conf is valid for config parser" {
  # Source config.sh and try to parse the example config.
  source "$REPO_DIR/lib/config.sh"
  # The example has all lines commented out — should parse without error.
  run load_config "$REPO_DIR/examples"
  [ "$status" -eq 0 ]
}

@test "examples: tasks.example.md exists and is non-empty" {
  [ -f "$REPO_DIR/examples/tasks.example.md" ]
  [ -s "$REPO_DIR/examples/tasks.example.md" ]
}

@test "examples: tasks.example.md uses ## Task N format" {
  local tasks_file="$REPO_DIR/examples/tasks.example.md"
  # Should contain at least one ## Task header.
  grep -q '^## Task [0-9]' "$tasks_file"
}

@test "examples: tasks.example.md contains multiple tasks" {
  local tasks_file="$REPO_DIR/examples/tasks.example.md"
  local count
  count=$(grep -c '^## Task [0-9]' "$tasks_file")
  [ "$count" -ge 3 ]
}

@test "examples: tasks.example.md has Previously Completed section" {
  local tasks_file="$REPO_DIR/examples/tasks.example.md"
  grep -q "Previously Completed" "$tasks_file"
}

# --- Binary executability ---

@test "binaries: autopilot-dispatch exists and is a file" {
  [ -f "$REPO_DIR/bin/autopilot-dispatch" ]
}

@test "binaries: autopilot-review exists and is a file" {
  [ -f "$REPO_DIR/bin/autopilot-review" ]
}

@test "binaries: autopilot-dispatch is executable" {
  [ -x "$REPO_DIR/bin/autopilot-dispatch" ]
}

@test "binaries: autopilot-review is executable" {
  [ -x "$REPO_DIR/bin/autopilot-review" ]
}

@test "binaries: autopilot-dispatch starts with bash shebang" {
  local first_line
  first_line="$(head -1 "$REPO_DIR/bin/autopilot-dispatch")"
  [[ "$first_line" == "#!/usr/bin/env bash" ]]
}

@test "binaries: autopilot-review starts with bash shebang" {
  local first_line
  first_line="$(head -1 "$REPO_DIR/bin/autopilot-review")"
  [[ "$first_line" == "#!/usr/bin/env bash" ]]
}
