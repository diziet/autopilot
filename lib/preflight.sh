#!/usr/bin/env bash
# Preflight checks for Autopilot.
# Validates dependencies, git repo state, GitHub auth, tasks file,
# CLAUDE.md, and non-interactive mode permission flags before pipeline starts.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_PREFLIGHT_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_PREFLIGHT_LOADED=1

# Source config for AUTOPILOT_* variables.
# shellcheck source=lib/config.sh
source "${BASH_SOURCE[0]%/*}/config.sh"

# Source state for log_msg.
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"

# Source tasks for detect_tasks_file.
# shellcheck source=lib/tasks.sh
source "${BASH_SOURCE[0]%/*}/tasks.sh"

# Required external commands and their install hints.
readonly _PREFLIGHT_DEPS="git jq gh timeout"

# --- Dependency Checks ---

# Get the install hint for a missing dependency.
_get_install_hint() {
  local cmd="$1"
  case "$cmd" in
    timeout) echo "brew install coreutils (macOS does not include GNU timeout)" ;;
    gh)      echo "brew install gh" ;;
    jq)      echo "brew install jq" ;;
    git)     echo "Install via Xcode Command Line Tools: xcode-select --install" ;;
    claude)  echo "See https://docs.anthropic.com/en/docs/claude-code" ;;
    *)       echo "Install $cmd and ensure it is on PATH" ;;
  esac
}

# Check that a single command is available on PATH.
_check_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1
}

# Verify all required external dependencies are present.
# Returns 0 if all found, 1 if any missing. Logs each missing dep.
check_dependencies() {
  local project_dir="${1:-.}"
  local claude_cmd="${AUTOPILOT_CLAUDE_CMD:-claude}"
  local missing=0

  # Check the configured claude command.
  if ! _check_command "$claude_cmd"; then
    log_msg "$project_dir" "ERROR" \
      "Missing dependency: ${claude_cmd} — $(_get_install_hint "claude")"
    missing=1
  fi

  # Check standard deps.
  local dep
  for dep in $_PREFLIGHT_DEPS; do
    if ! _check_command "$dep"; then
      log_msg "$project_dir" "ERROR" \
        "Missing dependency: ${dep} — $(_get_install_hint "$dep")"
      missing=1
    fi
  done

  return "$missing"
}

# --- Git Checks ---

# Verify the project directory is inside a git repository.
check_git_repo() {
  local project_dir="${1:-.}"

  if ! git -C "$project_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_msg "$project_dir" "ERROR" \
      "Not a git repository: ${project_dir}"
    return 1
  fi
}

# Verify the git working tree is clean (no uncommitted changes).
check_clean_worktree() {
  local project_dir="${1:-.}"

  if ! git -C "$project_dir" diff --quiet 2>/dev/null; then
    log_msg "$project_dir" "WARNING" \
      "Unstaged changes detected in working tree"
    return 1
  fi

  if ! git -C "$project_dir" diff --cached --quiet 2>/dev/null; then
    log_msg "$project_dir" "WARNING" \
      "Staged uncommitted changes detected in working tree"
    return 1
  fi
}

# --- GitHub Auth ---

# Verify gh CLI is authenticated.
check_gh_auth() {
  local project_dir="${1:-.}"

  if ! gh auth status >/dev/null 2>&1; then
    log_msg "$project_dir" "ERROR" \
      "GitHub CLI not authenticated — run: gh auth login"
    return 1
  fi
}

# --- File Checks ---

# Verify the tasks file exists (via detect_tasks_file).
check_tasks_file() {
  local project_dir="${1:-.}"

  if ! detect_tasks_file "$project_dir" >/dev/null 2>&1; then
    log_msg "$project_dir" "ERROR" \
      "No tasks file found — create tasks.md or set AUTOPILOT_TASKS_FILE"
    return 1
  fi
}

# Verify CLAUDE.md exists in the project directory.
check_claude_md() {
  local project_dir="${1:-.}"

  if [[ ! -f "${project_dir}/CLAUDE.md" ]]; then
    log_msg "$project_dir" "ERROR" \
      "CLAUDE.md not found in ${project_dir} — required for agent context"
    return 1
  fi
}

# --- Non-Interactive Mode ---

# Check if stdin is a TTY (interactive terminal).
is_interactive() {
  [[ -t 0 ]]
}

# Verify permission flags when running non-interactively (cron/pipe).
check_noninteractive_permissions() {
  local project_dir="${1:-.}"
  local flags="${AUTOPILOT_CLAUDE_FLAGS:-}"

  if is_interactive; then
    return 0
  fi

  # Non-interactive: require --dangerously-skip-permissions (whole-flag match).
  if [[ " $flags " != *" --dangerously-skip-permissions "* ]]; then
    log_msg "$project_dir" "CRITICAL" \
      "Non-interactive mode detected but AUTOPILOT_CLAUDE_FLAGS lacks --dangerously-skip-permissions — Claude will hang waiting for permission approval. Set AUTOPILOT_CLAUDE_FLAGS=\"--dangerously-skip-permissions\" in autopilot.conf or environment."
    return 1
  fi
}

# --- Launchd PATH Validation ---

# Dependencies to validate in the launchd PATH.
readonly _LAUNCHD_PATH_DEPS="claude gh jq git timeout"

# Find launchd plist files whose WorkingDirectory matches the project dir.
_find_project_plists() {
  local project_dir="$1"
  local launch_agents_dir="${HOME}/Library/LaunchAgents"
  local plist_file working_dir

  [[ ! -d "$launch_agents_dir" ]] && return 0

  for plist_file in "$launch_agents_dir"/com.*.plist; do
    [[ ! -f "$plist_file" ]] && continue
    working_dir="$(_extract_plist_working_dir "$plist_file")"
    if [[ "$working_dir" == "$project_dir" ]]; then
      echo "$plist_file"
    fi
  done
}

# Extract the WorkingDirectory value from a plist file.
_extract_plist_working_dir() {
  local plist_file="$1"
  sed -n '/<key>WorkingDirectory<\/key>/{ n; s/.*<string>\(.*\)<\/string>.*/\1/p; }' \
    "$plist_file"
}

# Extract the PATH environment variable value from a plist file.
_extract_plist_path() {
  local plist_file="$1"
  # Match <key>PATH</key> followed by <string>...</string> within EnvironmentVariables.
  sed -n '/<key>PATH<\/key>/{ n; s/.*<string>\(.*\)<\/string>.*/\1/p; }' \
    "$plist_file"
}

# Check if a command binary exists under a colon-separated PATH string.
_command_in_path() {
  local cmd="$1"
  local search_path="$2"
  local dir

  local old_ifs="${IFS}"
  IFS=:
  for dir in $search_path; do
    IFS="${old_ifs}"
    [[ -z "$dir" ]] && continue
    if [[ -x "${dir}/${cmd}" ]]; then
      return 0
    fi
  done
  IFS="${old_ifs}"
  return 1
}

# Validate that required deps are findable under the launchd plist PATH.
# Logs WARNING for each missing dep. Always returns 0 (non-fatal).
check_launchd_path() {
  local project_dir="${1:-.}"
  local plist_files plist_file plist_path
  local dep dep_location dep_dir warned=false

  plist_files="$(_find_project_plists "$project_dir")"
  [[ -z "$plist_files" ]] && return 0

  # Use only the first matching plist for the check.
  plist_file="$(echo "$plist_files" | head -n 1)"
  plist_path="$(_extract_plist_path "$plist_file")"
  [[ -z "$plist_path" ]] && return 0

  local claude_cmd="${AUTOPILOT_CLAUDE_CMD:-claude}"

  for dep in $_LAUNCHD_PATH_DEPS; do
    local check_cmd="$dep"
    [[ "$dep" == "claude" ]] && check_cmd="$claude_cmd"

    # Absolute paths are checked directly; bare names are searched in PATH.
    if [[ "$check_cmd" == /* ]]; then
      [[ -x "$check_cmd" ]] && continue
    else
      _command_in_path "$check_cmd" "$plist_path" && continue
    fi

    # Dep not in launchd PATH — find its actual location for the warning.
    dep_location="$(command -v "$check_cmd" 2>/dev/null || true)"
    if [[ -n "$dep_location" ]]; then
      dep_dir="$(dirname "$dep_location")"
      log_msg "$project_dir" "WARNING" \
        "${check_cmd} found at ${dep_location} but ${dep_dir} is not in the launchd plist PATH — launchd agents will fail. Run 'autopilot-schedule' to regenerate plists."
    else
      log_msg "$project_dir" "WARNING" \
        "${check_cmd} not found on PATH or in the launchd plist PATH — launchd agents will fail. Run 'autopilot-schedule' to regenerate plists."
    fi
    warned=true
  done

  if [[ "$warned" == true ]]; then
    log_msg "$project_dir" "WARNING" \
      "Launchd PATH check: some dependencies missing from plist $(basename "$plist_file") (continuing)"
  fi

  return 0
}

# --- Main Entry Point ---

# Run all preflight checks. Returns 0 if all pass, 1 on first failure.
run_preflight() {
  local project_dir="${1:-.}"

  log_msg "$project_dir" "INFO" "Running preflight checks"

  # Non-interactive check is CRITICAL — run first, exit immediately.
  if ! check_noninteractive_permissions "$project_dir"; then
    return 1
  fi

  if ! check_dependencies "$project_dir"; then
    log_msg "$project_dir" "ERROR" "Preflight failed: missing dependencies"
    return 1
  fi

  if ! check_git_repo "$project_dir"; then
    log_msg "$project_dir" "ERROR" "Preflight failed: not a git repo"
    return 1
  fi

  if ! check_clean_worktree "$project_dir"; then
    log_msg "$project_dir" "WARNING" "Preflight: dirty working tree (continuing)"
  fi

  if ! check_gh_auth "$project_dir"; then
    log_msg "$project_dir" "ERROR" "Preflight failed: gh not authenticated"
    return 1
  fi

  if ! check_tasks_file "$project_dir"; then
    log_msg "$project_dir" "ERROR" "Preflight failed: no tasks file"
    return 1
  fi

  if ! check_claude_md "$project_dir"; then
    log_msg "$project_dir" "ERROR" "Preflight failed: CLAUDE.md missing"
    return 1
  fi

  # Launchd PATH check is advisory — warns but does not fail preflight.
  check_launchd_path "$project_dir"

  log_msg "$project_dir" "INFO" "Preflight checks passed"
  return 0
}
