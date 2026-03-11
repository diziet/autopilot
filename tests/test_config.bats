#!/usr/bin/env bats
# Tests for lib/config.sh — config loading with precedence.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/test_template

setup_file() { _create_test_template; }
teardown_file() { _cleanup_test_template; }

setup() {
  _init_test_from_template_nogit
}

# Clear source and skip guards so config.sh can be re-sourced and load_config runs.
_reset_config_guards() {
  unset _AUTOPILOT_CONFIG_SH_LOADED
  unset _AUTOPILOT_TEST_SKIP_LOAD
}

# Helper: source config.sh and load config from test project dir.
# Re-sourcing config.sh restores the real load_config (replaces test wrapper).
# Saves test-exported env vars, clears _set_defaults values from setup, restores
# exports, then calls real load_config so _snapshot_env_vars starts clean.
_load_config() {
  _reset_config_guards
  source "$BATS_TEST_DIRNAME/../lib/config.sh"
  local _exports
  _exports="$(export -p | grep 'AUTOPILOT_' | sed 's/^declare -x/export/' || true)"
  _unset_autopilot_vars
  eval "$_exports"
  load_config "$TEST_PROJECT_DIR"
}

# --- Defaults only (no config files) ---

@test "defaults: AUTOPILOT_CLAUDE_CMD defaults to claude" {
  _load_config
  [ "$AUTOPILOT_CLAUDE_CMD" = "claude" ]
}

@test "defaults: AUTOPILOT_CLAUDE_FLAGS defaults to empty" {
  _load_config
  [ "$AUTOPILOT_CLAUDE_FLAGS" = "" ]
}

@test "defaults: AUTOPILOT_CLAUDE_OUTPUT_FORMAT defaults to json" {
  _load_config
  [ "$AUTOPILOT_CLAUDE_OUTPUT_FORMAT" = "json" ]
}

@test "defaults: AUTOPILOT_TIMEOUT_CODER defaults to 2700" {
  _load_config
  [ "$AUTOPILOT_TIMEOUT_CODER" = "2700" ]
}

@test "defaults: AUTOPILOT_TIMEOUT_FIXER defaults to 900" {
  _load_config
  [ "$AUTOPILOT_TIMEOUT_FIXER" = "900" ]
}

@test "defaults: AUTOPILOT_TIMEOUT_GH defaults to 30" {
  _load_config
  [ "$AUTOPILOT_TIMEOUT_GH" = "30" ]
}

@test "defaults: AUTOPILOT_MAX_RETRIES defaults to 5" {
  _load_config
  [ "$AUTOPILOT_MAX_RETRIES" = "5" ]
}

@test "defaults: AUTOPILOT_BRANCH_PREFIX defaults to autopilot" {
  _load_config
  [ "$AUTOPILOT_BRANCH_PREFIX" = "autopilot" ]
}

@test "defaults: AUTOPILOT_TARGET_BRANCH defaults to empty (auto-detect)" {
  _load_config
  [ "$AUTOPILOT_TARGET_BRANCH" = "" ]
}

@test "defaults: AUTOPILOT_REVIEWERS defaults to all five personas" {
  _load_config
  [ "$AUTOPILOT_REVIEWERS" = "general,dry,performance,security,design" ]
}

@test "defaults: AUTOPILOT_SPEC_REVIEW_INTERVAL defaults to 5" {
  _load_config
  [ "$AUTOPILOT_SPEC_REVIEW_INTERVAL" = "5" ]
}

@test "defaults: AUTOPILOT_MAX_DIFF_BYTES defaults to 500000" {
  _load_config
  [ "$AUTOPILOT_MAX_DIFF_BYTES" = "500000" ]
}

@test "defaults: all source annotations are default with no config files" {
  _load_config
  [ "$(_get_source AUTOPILOT_CLAUDE_CMD)" = "default" ]
  [ "$(_get_source AUTOPILOT_TIMEOUT_GH)" = "default" ]
  [ "$(_get_source AUTOPILOT_BRANCH_PREFIX)" = "default" ]
}

# --- File override (autopilot.conf) ---

@test "file override: autopilot.conf overrides defaults" {
  cat > "$TEST_PROJECT_DIR/autopilot.conf" <<'CONF'
AUTOPILOT_CLAUDE_CMD=my-claude
AUTOPILOT_TIMEOUT_CODER=3600
AUTOPILOT_BRANCH_PREFIX=custom
CONF
  _load_config
  [ "$AUTOPILOT_CLAUDE_CMD" = "my-claude" ]
  [ "$AUTOPILOT_TIMEOUT_CODER" = "3600" ]
  [ "$AUTOPILOT_BRANCH_PREFIX" = "custom" ]
}

@test "file override: source annotation shows autopilot.conf" {
  cat > "$TEST_PROJECT_DIR/autopilot.conf" <<'CONF'
AUTOPILOT_CLAUDE_CMD=my-claude
CONF
  _load_config
  [ "$(_get_source AUTOPILOT_CLAUDE_CMD)" = "autopilot.conf" ]
}

@test "file override: .autopilot/config.conf overrides autopilot.conf" {
  cat > "$TEST_PROJECT_DIR/autopilot.conf" <<'CONF'
AUTOPILOT_BRANCH_PREFIX=from-root
AUTOPILOT_TIMEOUT_GH=60
CONF
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  cat > "$TEST_PROJECT_DIR/.autopilot/config.conf" <<'CONF'
AUTOPILOT_BRANCH_PREFIX=from-local
CONF
  _load_config
  [ "$AUTOPILOT_BRANCH_PREFIX" = "from-local" ]
  [ "$AUTOPILOT_TIMEOUT_GH" = "60" ]
}

@test "file override: source annotation shows .autopilot/config.conf" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  cat > "$TEST_PROJECT_DIR/.autopilot/config.conf" <<'CONF'
AUTOPILOT_TIMEOUT_GH=99
CONF
  _load_config
  [ "$(_get_source AUTOPILOT_TIMEOUT_GH)" = ".autopilot/config.conf" ]
}

@test "file override: quoted values are stripped" {
  cat > "$TEST_PROJECT_DIR/autopilot.conf" <<'CONF'
AUTOPILOT_CLAUDE_CMD="my-claude"
AUTOPILOT_CLAUDE_FLAGS='--flag1 --flag2'
CONF
  _load_config
  [ "$AUTOPILOT_CLAUDE_CMD" = "my-claude" ]
  [ "$AUTOPILOT_CLAUDE_FLAGS" = "--flag1 --flag2" ]
}

@test "file override: comments and blank lines are ignored" {
  cat > "$TEST_PROJECT_DIR/autopilot.conf" <<'CONF'
# This is a comment
AUTOPILOT_TIMEOUT_GH=42

  # indented comment

AUTOPILOT_MAX_RETRIES=10
CONF
  _load_config
  [ "$AUTOPILOT_TIMEOUT_GH" = "42" ]
  [ "$AUTOPILOT_MAX_RETRIES" = "10" ]
}

@test "file override: invalid lines are silently ignored" {
  cat > "$TEST_PROJECT_DIR/autopilot.conf" <<'CONF'
NOT_AUTOPILOT_VAR=bad
autopilot_lowercase=bad
AUTOPILOT_TIMEOUT_GH=42
some garbage line
CONF
  _load_config
  [ "$AUTOPILOT_TIMEOUT_GH" = "42" ]
}

@test "file override: unknown AUTOPILOT vars are ignored" {
  cat > "$TEST_PROJECT_DIR/autopilot.conf" <<'CONF'
AUTOPILOT_NONEXISTENT_VAR=bad
AUTOPILOT_TIMEOUT_GH=42
CONF
  _load_config
  [ "$AUTOPILOT_TIMEOUT_GH" = "42" ]
  [ -z "${AUTOPILOT_NONEXISTENT_VAR:-}" ]
}

# --- Env override ---

@test "env override: env var wins over config file" {
  cat > "$TEST_PROJECT_DIR/autopilot.conf" <<'CONF'
AUTOPILOT_CLAUDE_CMD=from-file
AUTOPILOT_TIMEOUT_GH=60
CONF
  export AUTOPILOT_CLAUDE_CMD="from-env"
  _load_config
  [ "$AUTOPILOT_CLAUDE_CMD" = "from-env" ]
  [ "$AUTOPILOT_TIMEOUT_GH" = "60" ]
}

@test "env override: env var wins over .autopilot/config.conf" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  cat > "$TEST_PROJECT_DIR/.autopilot/config.conf" <<'CONF'
AUTOPILOT_BRANCH_PREFIX=from-local-conf
CONF
  export AUTOPILOT_BRANCH_PREFIX="from-env"
  _load_config
  [ "$AUTOPILOT_BRANCH_PREFIX" = "from-env" ]
}

@test "env override: source annotation shows env" {
  export AUTOPILOT_TIMEOUT_GH="99"
  _load_config
  [ "$(_get_source AUTOPILOT_TIMEOUT_GH)" = "env" ]
}

@test "env override: env var wins over both config files" {
  cat > "$TEST_PROJECT_DIR/autopilot.conf" <<'CONF'
AUTOPILOT_MAX_RETRIES=10
CONF
  mkdir -p "$TEST_PROJECT_DIR/.autopilot"
  cat > "$TEST_PROJECT_DIR/.autopilot/config.conf" <<'CONF'
AUTOPILOT_MAX_RETRIES=20
CONF
  export AUTOPILOT_MAX_RETRIES="99"
  _load_config
  [ "$AUTOPILOT_MAX_RETRIES" = "99" ]
}

@test "env override: empty env var is preserved (overrides file)" {
  cat > "$TEST_PROJECT_DIR/autopilot.conf" <<'CONF'
AUTOPILOT_CLAUDE_FLAGS=--some-flag
CONF
  export AUTOPILOT_CLAUDE_FLAGS=""
  _load_config
  [ "$AUTOPILOT_CLAUDE_FLAGS" = "" ]
  [ "$(_get_source AUTOPILOT_CLAUDE_FLAGS)" = "env" ]
}

# --- Missing file ---

@test "missing file: no autopilot.conf uses defaults" {
  _load_config
  [ "$AUTOPILOT_CLAUDE_CMD" = "claude" ]
  [ "$AUTOPILOT_TIMEOUT_CODER" = "2700" ]
}

@test "missing file: no .autopilot/config.conf uses defaults" {
  cat > "$TEST_PROJECT_DIR/autopilot.conf" <<'CONF'
AUTOPILOT_TIMEOUT_GH=42
CONF
  _load_config
  [ "$AUTOPILOT_TIMEOUT_GH" = "42" ]
  [ "$AUTOPILOT_CLAUDE_CMD" = "claude" ]
}

@test "missing file: nonexistent project dir uses defaults" {
  _reset_config_guards
  source "$BATS_TEST_DIRNAME/../lib/config.sh"
  _unset_autopilot_vars
  load_config "/nonexistent/path"
  [ "$AUTOPILOT_CLAUDE_CMD" = "claude" ]
  [ "$AUTOPILOT_TIMEOUT_GH" = "30" ]
}

# --- Partial config ---

@test "partial config: only some vars set in file, rest default" {
  cat > "$TEST_PROJECT_DIR/autopilot.conf" <<'CONF'
AUTOPILOT_BRANCH_PREFIX=my-prefix
AUTOPILOT_TARGET_BRANCH=develop
CONF
  _load_config
  [ "$AUTOPILOT_BRANCH_PREFIX" = "my-prefix" ]
  [ "$AUTOPILOT_TARGET_BRANCH" = "develop" ]
  [ "$AUTOPILOT_CLAUDE_CMD" = "claude" ]
  [ "$AUTOPILOT_TIMEOUT_CODER" = "2700" ]
  [ "$AUTOPILOT_MAX_RETRIES" = "5" ]
  [ "$AUTOPILOT_REVIEWERS" = "general,dry,performance,security,design" ]
}

@test "partial config: mixed sources tracked correctly" {
  cat > "$TEST_PROJECT_DIR/autopilot.conf" <<'CONF'
AUTOPILOT_BRANCH_PREFIX=from-file
CONF
  export AUTOPILOT_TIMEOUT_GH="99"
  _load_config
  [ "$(_get_source AUTOPILOT_BRANCH_PREFIX)" = "autopilot.conf" ]
  [ "$(_get_source AUTOPILOT_TIMEOUT_GH)" = "env" ]
  [ "$(_get_source AUTOPILOT_CLAUDE_CMD)" = "default" ]
}

# --- log_effective_config ---

@test "log_effective_config outputs all variables with sources" {
  _load_config
  local output
  output="$(log_effective_config)"
  [[ "$output" == *"AUTOPILOT_CLAUDE_CMD=claude [default]"* ]]
  [[ "$output" == *"AUTOPILOT_TIMEOUT_GH=30 [default]"* ]]
  [[ "$output" == *"AUTOPILOT_BRANCH_PREFIX=autopilot [default]"* ]]
}

@test "log_effective_config shows empty values" {
  _load_config
  local output
  output="$(log_effective_config)"
  [[ "$output" == *"AUTOPILOT_TASKS_FILE=(empty) [default]"* ]]
}

@test "log_effective_config shows file source" {
  cat > "$TEST_PROJECT_DIR/autopilot.conf" <<'CONF'
AUTOPILOT_TIMEOUT_GH=42
CONF
  _load_config
  local output
  output="$(log_effective_config)"
  [[ "$output" == *"AUTOPILOT_TIMEOUT_GH=42 [autopilot.conf]"* ]]
}

@test "log_effective_config shows env source" {
  export AUTOPILOT_TIMEOUT_GH="99"
  _load_config
  local output
  output="$(log_effective_config)"
  [[ "$output" == *"AUTOPILOT_TIMEOUT_GH=99 [env]"* ]]
}
