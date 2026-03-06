#!/usr/bin/env bash
# Coder hooks for Autopilot.
# Installs lint/test Stop hooks on the coder agent for real-time edit
# validation. Hooks are installed before spawning coder/fixer and
# cleaned up after.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_HOOKS_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_HOOKS_LOADED=1

# Source config for AUTOPILOT_* variables.
# shellcheck source=lib/config.sh
source "${BASH_SOURCE[0]%/*}/config.sh"

# Source state for log_msg.
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"

# Source testgate for _has_bats (shared bats detection).
# shellcheck source=lib/testgate.sh
source "${BASH_SOURCE[0]%/*}/testgate.sh"

# --- Settings File Resolution ---

# Resolve the path to Claude's settings.json for hook installation.
# Uses config_dir if provided, else CLAUDE_CONFIG_DIR, else $HOME/.claude.
resolve_settings_file() {
  local config_dir="${1:-}"
  local base_dir

  if [[ -n "$config_dir" ]]; then
    base_dir="$config_dir"
  elif [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
    base_dir="$CLAUDE_CONFIG_DIR"
  else
    base_dir="${HOME}/.claude"
  fi

  echo "${base_dir}/settings.json"
}

# --- Settings.json Manipulation ---

# Read the current settings.json, or return empty object if missing.
_read_settings() {
  local settings_file="$1"

  if [[ -f "$settings_file" ]]; then
    cat "$settings_file"
  else
    echo '{}'
  fi
}

# Write settings.json atomically (tmp + mv).
_write_settings() {
  local settings_file="$1"
  local content="$2"

  local settings_dir
  settings_dir="$(dirname "$settings_file")"
  mkdir -p "$settings_dir"

  local tmp_file="${settings_file}.tmp.$$"
  echo "$content" > "$tmp_file"
  mv -f "$tmp_file" "$settings_file"
}

# Back up settings.json before modification.
# Only creates backup if one doesn't already exist (preserves clean
# backup across crash recovery).
_backup_settings() {
  local settings_file="$1"
  local backup_file="${settings_file}.autopilot-backup"

  if [[ -f "$settings_file" ]] && [[ ! -f "$backup_file" ]]; then
    cp -f "$settings_file" "$backup_file"
  fi
}

# --- Hook Installation ---

# Install lint and test Stop hooks into Claude settings.json.
# Backs up existing settings before modification.
install_hooks() {
  local project_dir="${1:-.}"
  local config_dir="${2:-}"
  local settings_file
  settings_file="$(resolve_settings_file "$config_dir")"

  _backup_settings "$settings_file"

  local current_settings
  current_settings="$(_read_settings "$settings_file")"

  # Build the hook commands.
  local lint_cmd test_cmd
  lint_cmd="$(_build_lint_command "$project_dir")"
  test_cmd="$(_build_test_command "$project_dir")"

  # Merge hooks into settings using jq.
  local new_settings
  new_settings="$(_add_hooks_to_settings "$current_settings" "$lint_cmd" "$test_cmd")"

  if [[ -z "$new_settings" ]]; then
    log_msg "$project_dir" "ERROR" "Failed to install hooks: jq merge failed"
    return 1
  fi

  _write_settings "$settings_file" "$new_settings"
  log_msg "$project_dir" "INFO" "Installed coder hooks in ${settings_file}"
}

# Build the lint command for hook installation.
_build_lint_command() {
  local project_dir="${1:-.}"

  if [[ -f "${project_dir}/Makefile" ]] && grep -q '^lint:' "${project_dir}/Makefile" 2>/dev/null; then
    echo "cd '${project_dir}' && make lint 2>&1"
  else
    echo "true"
  fi
}

# Build the test command for hook installation.
# Uses two-phase runner for bats projects (fast rejection of known failures).
_build_test_command() {
  local project_dir="${1:-.}"
  local test_cmd="${AUTOPILOT_TEST_CMD:-}"

  if [[ -n "$test_cmd" ]]; then
    echo "cd '${project_dir}' && ${test_cmd} 2>&1"
  elif _has_bats "$project_dir"; then
    local twophase_script
    twophase_script="$(_resolve_twophase_script)"
    echo "cd '${project_dir}' && bash '${twophase_script}' '${project_dir}' 2>&1"
  elif [[ -f "${project_dir}/Makefile" ]] && grep -q '^test:' "${project_dir}/Makefile" 2>/dev/null; then
    echo "cd '${project_dir}' && make test 2>&1"
  else
    echo "true"
  fi
}

# Resolve absolute path to twophase.sh script.
_resolve_twophase_script() {
  local lib_dir
  lib_dir="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
  echo "${lib_dir}/twophase.sh"
}

# Add hook entries to settings JSON via jq.
_add_hooks_to_settings() {
  local settings="$1"
  local lint_cmd="$2"
  local test_cmd="$3"

  echo "$settings" | jq \
    --arg lint "$lint_cmd" \
    --arg test "$test_cmd" \
    '.hooks = (.hooks // {}) |
     .hooks.stop = (.hooks.stop // []) |
     .hooks.stop += [
       {"command": $lint, "description": "autopilot-lint-hook"},
       {"command": $test, "description": "autopilot-test-hook"}
     ]' 2>/dev/null
}

# --- Hook Removal ---

# Remove autopilot hooks from Claude settings.json.
# Restores from backup if available, otherwise removes hook entries.
remove_hooks() {
  local project_dir="${1:-.}"
  local config_dir="${2:-}"
  local settings_file
  settings_file="$(resolve_settings_file "$config_dir")"

  local backup_file="${settings_file}.autopilot-backup"

  if [[ -f "$backup_file" ]]; then
    mv -f "$backup_file" "$settings_file"
    log_msg "$project_dir" "INFO" "Restored settings from backup: ${settings_file}"
    return 0
  fi

  if [[ ! -f "$settings_file" ]]; then
    return 0
  fi

  # No backup — remove autopilot hook entries manually.
  local current_settings
  current_settings="$(_read_settings "$settings_file")"

  local cleaned
  cleaned="$(_remove_hooks_from_settings "$current_settings")"

  if [[ -n "$cleaned" ]]; then
    _write_settings "$settings_file" "$cleaned"
    log_msg "$project_dir" "INFO" "Removed autopilot hooks from ${settings_file}"
  fi
}

# Remove autopilot hook entries from settings JSON via jq.
_remove_hooks_from_settings() {
  local settings="$1"

  echo "$settings" | jq '
    if .hooks and .hooks.stop then
      .hooks.stop = [.hooks.stop[] |
        select(.description != "autopilot-lint-hook" and
               .description != "autopilot-test-hook")]
    else . end
  ' 2>/dev/null
}

# --- Query ---

# Check if autopilot hooks are currently installed.
hooks_installed() {
  local config_dir="${1:-}"
  local settings_file
  settings_file="$(resolve_settings_file "$config_dir")"

  [[ -f "$settings_file" ]] || return 1

  local count
  count="$(jq '[.hooks.stop[]? |
    select(.description == "autopilot-lint-hook" or
           .description == "autopilot-test-hook")] | length' \
    "$settings_file" 2>/dev/null)" || return 1

  [[ "$count" -gt 0 ]]
}
