#!/usr/bin/env bash
# Config loading for Autopilot.
# Parses autopilot.conf and .autopilot/config.conf (line-by-line, no source).
# Precedence: env var > .autopilot/config.conf > autopilot.conf > built-in default.
# Compatible with Bash 3.2+ (no associative arrays).

# Source guard — prevent re-defining functions when sourced by multiple lib modules.
[[ -n "${_AUTOPILOT_CONFIG_SH_LOADED:-}" ]] && return 0
_AUTOPILOT_CONFIG_SH_LOADED=1

# shellcheck disable=SC2034  # Variables are set here, used by other modules

# List of all known AUTOPILOT_* variable names.
# IMPORTANT: Must start and end with a newline for _is_known_var pattern matching.
_AUTOPILOT_KNOWN_VARS="
AUTOPILOT_CLAUDE_CMD
AUTOPILOT_CLAUDE_FLAGS
AUTOPILOT_CLAUDE_MODEL
AUTOPILOT_CLAUDE_OUTPUT_FORMAT
AUTOPILOT_CODER_CONFIG_DIR
AUTOPILOT_REVIEWER_CONFIG_DIR
AUTOPILOT_SPEC_REVIEW_CONFIG_DIR
AUTOPILOT_TASKS_FILE
AUTOPILOT_CONTEXT_FILES
AUTOPILOT_TIMEOUT_CODER
AUTOPILOT_TIMEOUT_FIXER
AUTOPILOT_TIMEOUT_TEST_GATE
AUTOPILOT_TIMEOUT_REVIEWER
AUTOPILOT_TIMEOUT_REVIEWER_CLAUDE
AUTOPILOT_TIMEOUT_MERGER
AUTOPILOT_TIMEOUT_SUMMARY
AUTOPILOT_TIMEOUT_DIAGNOSE
AUTOPILOT_TIMEOUT_SPEC_REVIEW
AUTOPILOT_TIMEOUT_FIX_TESTS
AUTOPILOT_TIMEOUT_GH
AUTOPILOT_MAX_RETRIES
AUTOPILOT_MAX_TEST_FIX_RETRIES
AUTOPILOT_STALE_LOCK_MINUTES
AUTOPILOT_MAX_LOG_LINES
AUTOPILOT_MAX_DIFF_BYTES
AUTOPILOT_MAX_SUMMARY_LINES
AUTOPILOT_MAX_SUMMARY_ENTRY_LINES
AUTOPILOT_TEST_CMD
AUTOPILOT_TEST_JOBS
AUTOPILOT_TEST_TIMEOUT
AUTOPILOT_TEST_OUTPUT_TAIL
AUTOPILOT_REVIEWERS
AUTOPILOT_SPEC_REVIEW_INTERVAL
AUTOPILOT_BRANCH_PREFIX
AUTOPILOT_TARGET_BRANCH
AUTOPILOT_MAX_NETWORK_RETRIES
AUTOPILOT_NETWORK_COOLDOWN_SECONDS
AUTOPILOT_MAX_REVIEWER_RETRIES
AUTOPILOT_AUTH_FALLBACK
AUTOPILOT_TIMEOUT_AUTH_CHECK
AUTOPILOT_USE_WORKTREES
AUTOPILOT_WORKTREE_SETUP_CMD
AUTOPILOT_WORKTREE_SETUP_OPTIONAL
AUTOPILOT_MAX_TEST_OUTPUT
AUTOPILOT_REVIEWER_INTERACTIVE
AUTOPILOT_TIMEOUT_REVIEWER_INTERACTIVE
AUTOPILOT_MAX_DIFF_REDUCTION_RETRIES
AUTOPILOT_CODEX_MODEL
AUTOPILOT_CODEX_MIN_CONFIDENCE
AUTOPILOT_TIMEOUT_CODEX
AUTOPILOT_SELF_UPDATE_INTERVAL
"

# Snapshotted env vars stored as newline-separated KEY=VALUE pairs.
_AUTOPILOT_ENV_SNAPSHOT=""

# Source tracking uses individual _SRC_AUTOPILOT_* variables (no subshells).

# Record the source of a config variable (uses _SRC_<varname> variables).
_set_source() {
  local var_name="$1" source_label="$2"
  printf -v "_SRC_${var_name}" '%s' "$source_label"
}

# Get the source of a config variable.
_get_source() {
  local var_name="$1"
  local src_var="_SRC_${var_name}"
  if [[ -n "${!src_var+x}" ]]; then
    echo "${!src_var}"
  else
    echo "default"
  fi
}

# Check if a variable name is in the known vars list.
_is_known_var() {
  local check_name="$1"
  [[ "$_AUTOPILOT_KNOWN_VARS" == *"
${check_name}
"* ]]
}

# Snapshot all existing AUTOPILOT_* env vars before parsing config files.
_snapshot_env_vars() {
  _AUTOPILOT_ENV_SNAPSHOT=""
  # Use bash prefix expansion for speed (~2x faster than iterating _AUTOPILOT_KNOWN_VARS).
  # Only captures AUTOPILOT_* vars (not internal _AUTOPILOT_* vars).
  local var_name
  for var_name in ${!AUTOPILOT_@}; do
    [[ "$_AUTOPILOT_KNOWN_VARS" == *"
${var_name}
"* ]] || continue
    _AUTOPILOT_ENV_SNAPSHOT+="${var_name}=${!var_name}
"
  done
}

# Set all AUTOPILOT_* variables to their built-in defaults.
_set_defaults() {
  # Claude Code settings
  AUTOPILOT_CLAUDE_CMD="claude"
  AUTOPILOT_CLAUDE_FLAGS=""
  AUTOPILOT_CLAUDE_MODEL="opus"
  AUTOPILOT_CLAUDE_OUTPUT_FORMAT="json"
  AUTOPILOT_CODER_CONFIG_DIR=""
  AUTOPILOT_REVIEWER_CONFIG_DIR=""
  AUTOPILOT_SPEC_REVIEW_CONFIG_DIR=""

  # Task source
  AUTOPILOT_TASKS_FILE=""
  AUTOPILOT_CONTEXT_FILES=""

  # Timeouts (seconds)
  AUTOPILOT_TIMEOUT_CODER=2700
  AUTOPILOT_TIMEOUT_FIXER=900
  AUTOPILOT_TIMEOUT_TEST_GATE=300
  AUTOPILOT_TIMEOUT_REVIEWER=600
  AUTOPILOT_TIMEOUT_REVIEWER_CLAUDE=450
  AUTOPILOT_TIMEOUT_MERGER=600
  AUTOPILOT_TIMEOUT_SUMMARY=60
  AUTOPILOT_TIMEOUT_DIAGNOSE=300
  AUTOPILOT_TIMEOUT_SPEC_REVIEW=1200
  AUTOPILOT_TIMEOUT_FIX_TESTS=600
  AUTOPILOT_TIMEOUT_GH=30

  # Limits
  AUTOPILOT_MAX_RETRIES=5
  AUTOPILOT_MAX_TEST_FIX_RETRIES=3
  AUTOPILOT_STALE_LOCK_MINUTES=""
  AUTOPILOT_MAX_LOG_LINES=50000
  AUTOPILOT_MAX_DIFF_BYTES=500000
  AUTOPILOT_MAX_SUMMARY_LINES=50
  AUTOPILOT_MAX_SUMMARY_ENTRY_LINES=20

  # Testing
  AUTOPILOT_TEST_CMD=""
  AUTOPILOT_TEST_JOBS=20
  AUTOPILOT_TEST_TIMEOUT=300
  AUTOPILOT_TEST_OUTPUT_TAIL=80

  # Review
  AUTOPILOT_REVIEWERS="general,dry,performance,security,design"
  AUTOPILOT_SPEC_REVIEW_INTERVAL=5

  # Branches
  AUTOPILOT_BRANCH_PREFIX="autopilot"
  AUTOPILOT_TARGET_BRANCH=""

  # Network
  AUTOPILOT_MAX_NETWORK_RETRIES=100
  AUTOPILOT_NETWORK_COOLDOWN_SECONDS=300

  # Auth
  AUTOPILOT_MAX_REVIEWER_RETRIES=5
  AUTOPILOT_AUTH_FALLBACK="true"
  AUTOPILOT_TIMEOUT_AUTH_CHECK=10

  # Worktrees
  AUTOPILOT_USE_WORKTREES="true"
  AUTOPILOT_WORKTREE_SETUP_CMD=""
  AUTOPILOT_WORKTREE_SETUP_OPTIONAL="false"

  # Test output for fixer/test-fixer prompts
  AUTOPILOT_MAX_TEST_OUTPUT=500

  # Interactive reviewer mode
  AUTOPILOT_REVIEWER_INTERACTIVE="false"
  AUTOPILOT_TIMEOUT_REVIEWER_INTERACTIVE=300

  # Diff reduction
  AUTOPILOT_MAX_DIFF_REDUCTION_RETRIES=2

  # Codex reviewer (optional)
  AUTOPILOT_CODEX_MODEL="o4-mini"
  AUTOPILOT_CODEX_MIN_CONFIDENCE="0.7"
  AUTOPILOT_TIMEOUT_CODEX=450

  # Self-update (seconds between git fetch checks, 0 to disable)
  AUTOPILOT_SELF_UPDATE_INTERVAL=300

  # Default source is implied — _get_source returns "default" for unset _SRC_ vars.
  # Clear any previously set non-default source annotations.
  local _src_var
  for _src_var in ${!_SRC_AUTOPILOT_@}; do
    unset "$_src_var"
  done
}

# Parse a single config file line-by-line.
# Only accepts lines matching ^AUTOPILOT_[A-Z_]+= (security: no arbitrary code).
_parse_config_file() {
  local config_file="$1"
  local source_label="$2"

  [[ -f "$config_file" ]] || return 0

  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue

    # Only accept AUTOPILOT_[A-Z_]+=value pattern
    if [[ "$line" =~ ^(AUTOPILOT_[A-Z_]+)=(.*) ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"

      # Strip surrounding quotes (single or double)
      if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
        value="${BASH_REMATCH[1]}"
      fi

      # Only set known variables
      if _is_known_var "$key"; then
        printf -v "$key" '%s' "$value"
        _set_source "$key" "$source_label"
      fi
    fi
  done < "$config_file"
}

# Restore snapshotted env vars (env always wins over file values).
_restore_env_vars() {
  local line var_name value
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    var_name="${line%%=*}"
    value="${line#*=}"
    printf -v "$var_name" '%s' "$value"
    _set_source "$var_name" "env"
  done <<< "$_AUTOPILOT_ENV_SNAPSHOT"
}

# Compute stale lock threshold from longest agent timeout + 5 min buffer.
_compute_stale_lock_minutes() {
  local coder_timeout="${AUTOPILOT_TIMEOUT_CODER:-2700}"
  local fixer_timeout="${AUTOPILOT_TIMEOUT_FIXER:-900}"
  local spec_timeout="${AUTOPILOT_TIMEOUT_SPEC_REVIEW:-1200}"

  # Find the maximum timeout
  local max_timeout="$coder_timeout"
  [[ "$fixer_timeout" -gt "$max_timeout" ]] && max_timeout="$fixer_timeout"
  [[ "$spec_timeout" -gt "$max_timeout" ]] && max_timeout="$spec_timeout"

  # Ceiling division to minutes, add 5-minute buffer
  local minutes=$(( (max_timeout + 59) / 60 + 5 ))
  echo "$minutes"
}

# Log effective config with source annotations.
log_effective_config() {
  local var_name value source
  for var_name in $_AUTOPILOT_KNOWN_VARS; do
    [[ -z "$var_name" ]] && continue
    value="${!var_name}"
    source="$(_get_source "$var_name")"
    if [[ "$var_name" = "AUTOPILOT_STALE_LOCK_MINUTES" && -z "$value" ]]; then
      # Show the derived value when not explicitly set
      local derived
      derived="$(_compute_stale_lock_minutes)"
      echo "  ${var_name}=${derived} [derived]"
    elif [[ -z "$value" ]]; then
      echo "  ${var_name}=(empty) [${source}]"
    else
      echo "  ${var_name}=${value} [${source}]"
    fi
  done
}

# Main entry point: load all config with proper precedence.
# Usage: load_config [project_dir]
load_config() {
  # Test-only fast path: skip when defaults already applied by test setup.
  # _AUTOPILOT_TEST_SKIP_LOAD is set by bats test helpers and consumed once.
  if [[ -n "${BATS_TEST_DIRNAME:-}" && "${_AUTOPILOT_TEST_SKIP_LOAD:-}" == "1" ]]; then
    unset _AUTOPILOT_TEST_SKIP_LOAD
    return 0
  fi

  local project_dir="${1:-.}"

  # Step 1: Snapshot existing env vars
  _snapshot_env_vars

  # Step 2: Set built-in defaults
  _set_defaults

  # Step 3: Parse autopilot.conf in project root
  _parse_config_file "${project_dir}/autopilot.conf" "autopilot.conf"

  # Step 4: Parse .autopilot/config.conf (overrides project root)
  _parse_config_file "${project_dir}/.autopilot/config.conf" ".autopilot/config.conf"

  # Step 5: Restore snapshotted env vars (env always wins)
  _restore_env_vars

  # Mark config as loaded for subprocess detection.
  _AUTOPILOT_CONFIG_LOADED=1
}
