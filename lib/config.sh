#!/usr/bin/env bash
# Config loading for Autopilot.
# Parses autopilot.conf and .autopilot/config.conf (line-by-line, no source).
# Precedence: env var > .autopilot/config.conf > autopilot.conf > built-in default.

# shellcheck disable=SC2034  # Variables are set here, used by other modules

# Associative arrays for tracking config sources and snapshotted env vars.
declare -gA _AUTOPILOT_CONFIG_SOURCE
declare -gA _AUTOPILOT_ENV_SNAPSHOT

# List of all known AUTOPILOT_* variable names.
readonly _AUTOPILOT_KNOWN_VARS=(
  AUTOPILOT_CLAUDE_CMD
  AUTOPILOT_CLAUDE_FLAGS
  AUTOPILOT_CLAUDE_OUTPUT_FORMAT
  AUTOPILOT_CODER_CONFIG_DIR
  AUTOPILOT_REVIEWER_CONFIG_DIR
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
  AUTOPILOT_TEST_CMD
  AUTOPILOT_TEST_TIMEOUT
  AUTOPILOT_TEST_OUTPUT_TAIL
  AUTOPILOT_REVIEWERS
  AUTOPILOT_SPEC_REVIEW_INTERVAL
  AUTOPILOT_BRANCH_PREFIX
  AUTOPILOT_TARGET_BRANCH
)

# Snapshot all existing AUTOPILOT_* env vars before parsing config files.
_snapshot_env_vars() {
  _AUTOPILOT_ENV_SNAPSHOT=()
  local var_name
  for var_name in "${_AUTOPILOT_KNOWN_VARS[@]}"; do
    if [[ -n "${!var_name+x}" ]]; then
      _AUTOPILOT_ENV_SNAPSHOT["$var_name"]="${!var_name}"
    fi
  done
}

# Set all AUTOPILOT_* variables to their built-in defaults.
_set_defaults() {
  # Claude Code settings
  AUTOPILOT_CLAUDE_CMD="claude"
  AUTOPILOT_CLAUDE_FLAGS=""
  AUTOPILOT_CLAUDE_OUTPUT_FORMAT="json"
  AUTOPILOT_CODER_CONFIG_DIR=""
  AUTOPILOT_REVIEWER_CONFIG_DIR=""

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
  AUTOPILOT_TIMEOUT_SPEC_REVIEW=300
  AUTOPILOT_TIMEOUT_FIX_TESTS=600
  AUTOPILOT_TIMEOUT_GH=30

  # Limits
  AUTOPILOT_MAX_RETRIES=5
  AUTOPILOT_MAX_TEST_FIX_RETRIES=3
  AUTOPILOT_STALE_LOCK_MINUTES=45
  AUTOPILOT_MAX_LOG_LINES=1000
  AUTOPILOT_MAX_DIFF_BYTES=500000
  AUTOPILOT_MAX_SUMMARY_LINES=50

  # Testing
  AUTOPILOT_TEST_CMD=""
  AUTOPILOT_TEST_TIMEOUT=300
  AUTOPILOT_TEST_OUTPUT_TAIL=80

  # Review
  AUTOPILOT_REVIEWERS="general,dry,performance,security,design"
  AUTOPILOT_SPEC_REVIEW_INTERVAL=5

  # Branches
  AUTOPILOT_BRANCH_PREFIX="autopilot"
  AUTOPILOT_TARGET_BRANCH="main"

  # Mark all as default source
  local var_name
  for var_name in "${_AUTOPILOT_KNOWN_VARS[@]}"; do
    _AUTOPILOT_CONFIG_SOURCE["$var_name"]="default"
  done
}

# Parse a single config file line-by-line.
# Only accepts lines matching ^AUTOPILOT_[A-Z_]*= (security: no arbitrary code).
_parse_config_file() {
  local config_file="$1"
  local source_label="$2"

  [[ -f "$config_file" ]] || return 0

  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue

    # Only accept AUTOPILOT_[A-Z_]*=value pattern
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
        _AUTOPILOT_CONFIG_SOURCE["$key"]="$source_label"
      fi
    fi
  done < "$config_file"
}

# Check if a variable name is in the known vars list.
_is_known_var() {
  local check_name="$1"
  local var_name
  for var_name in "${_AUTOPILOT_KNOWN_VARS[@]}"; do
    [[ "$var_name" == "$check_name" ]] && return 0
  done
  return 1
}

# Restore snapshotted env vars (env always wins over file values).
_restore_env_vars() {
  local var_name
  for var_name in "${!_AUTOPILOT_ENV_SNAPSHOT[@]}"; do
    printf -v "$var_name" '%s' "${_AUTOPILOT_ENV_SNAPSHOT[$var_name]}"
    _AUTOPILOT_CONFIG_SOURCE["$var_name"]="env"
  done
}

# Log effective config with source annotations.
log_effective_config() {
  local var_name value source
  for var_name in "${_AUTOPILOT_KNOWN_VARS[@]}"; do
    value="${!var_name}"
    source="${_AUTOPILOT_CONFIG_SOURCE[$var_name]:-unknown}"
    # Mask empty values for readability
    if [[ -z "$value" ]]; then
      echo "  ${var_name}=(empty) [${source}]"
    else
      echo "  ${var_name}=${value} [${source}]"
    fi
  done
}

# Main entry point: load all config with proper precedence.
# Usage: load_config [project_dir]
#   project_dir defaults to current directory.
load_config() {
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
}
