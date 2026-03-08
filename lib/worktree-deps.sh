#!/usr/bin/env bash
# Worktree dependency detection and installation.
# Runs after worktree creation to install project dependencies (node_modules, venvs, etc.).

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_WORKTREE_DEPS_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_WORKTREE_DEPS_LOADED=1

# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"

# Detect the Node.js package manager from lockfiles.
_detect_node_pm() {
  local worktree_path="$1"
  if [[ -f "${worktree_path}/pnpm-lock.yaml" ]]; then
    echo "pnpm"
  elif [[ -f "${worktree_path}/yarn.lock" ]]; then
    echo "yarn"
  else
    echo "npm"
  fi
}

# Install Node.js dependencies based on lockfile detection.
_install_node_deps() {
  local project_dir="$1"
  local worktree_path="$2"
  local pm
  pm="$(_detect_node_pm "$worktree_path")"
  log_msg "$project_dir" "INFO" "Installing Node.js dependencies with ${pm}"
  (cd "$worktree_path" && "${pm}" install 2>&1)
}

# Install Python dependencies with a venv.
_install_python_deps() {
  local project_dir="$1"
  local worktree_path="$2"
  log_msg "$project_dir" "INFO" "Creating Python venv and installing dependencies"

  local venv_path="${worktree_path}/.venv"
  if ! (cd "$worktree_path" && python3 -m venv "$venv_path" 2>&1); then
    log_msg "$project_dir" "ERROR" "Failed to create Python venv at ${venv_path}"
    return 1
  fi

  # Install from requirements.txt or pyproject.toml.
  if [[ -f "${worktree_path}/requirements.txt" ]]; then
    (cd "$worktree_path" && "${venv_path}/bin/pip" install -r requirements.txt 2>&1) || return 1
  elif [[ -f "${worktree_path}/pyproject.toml" ]]; then
    (cd "$worktree_path" && "${venv_path}/bin/pip" install -e . 2>&1) || return 1
  fi
}

# Install Ruby dependencies via Bundler.
_install_ruby_deps() {
  local project_dir="$1"
  local worktree_path="$2"
  log_msg "$project_dir" "INFO" "Installing Ruby dependencies with bundle"
  (cd "$worktree_path" && bundle install 2>&1)
}

# Download Go module dependencies.
_install_go_deps() {
  local project_dir="$1"
  local worktree_path="$2"
  log_msg "$project_dir" "INFO" "Downloading Go module dependencies"
  (cd "$worktree_path" && go mod download 2>&1)
}

# Handle setup failure: log error, return 1 or continue based on optional flag.
_handle_setup_failure() {
  local project_dir="$1"
  local is_optional="$2"
  local label="$3"
  log_msg "$project_dir" "ERROR" "Worktree ${label} failed (see dep-install log for details)"
  if [[ "$is_optional" != "true" ]]; then
    return 1
  fi
  log_msg "$project_dir" "WARNING" \
    "AUTOPILOT_WORKTREE_SETUP_OPTIONAL=true — continuing despite ${label} failure"
  return 0
}

# Detect project types and install dependencies in a worktree.
# Runs all matching installers (not mutually exclusive).
# Returns 0 on success, 1 on failure.
install_worktree_deps() {
  local project_dir="$1"
  local worktree_path="$2"
  local is_optional="${AUTOPILOT_WORKTREE_SETUP_OPTIONAL:-false}"
  local custom_cmd="${AUTOPILOT_WORKTREE_SETUP_CMD:-}"

  # Auto-detect and install based on project files (all matching ecosystems).
  if [[ -f "${worktree_path}/package.json" ]]; then
    if ! _install_node_deps "$project_dir" "$worktree_path"; then
      _handle_setup_failure "$project_dir" "$is_optional" "dependency install" || return 1
    fi
  fi

  if [[ -f "${worktree_path}/requirements.txt" ]] || \
     [[ -f "${worktree_path}/pyproject.toml" ]]; then
    if ! _install_python_deps "$project_dir" "$worktree_path"; then
      _handle_setup_failure "$project_dir" "$is_optional" "dependency install" || return 1
    fi
  fi

  if [[ -f "${worktree_path}/Gemfile" ]]; then
    if ! _install_ruby_deps "$project_dir" "$worktree_path"; then
      _handle_setup_failure "$project_dir" "$is_optional" "dependency install" || return 1
    fi
  fi

  if [[ -f "${worktree_path}/go.mod" ]]; then
    if ! _install_go_deps "$project_dir" "$worktree_path"; then
      _handle_setup_failure "$project_dir" "$is_optional" "dependency install" || return 1
    fi
  fi

  # Run custom setup command if configured.
  if [[ -n "$custom_cmd" ]]; then
    log_msg "$project_dir" "INFO" "Running custom worktree setup: ${custom_cmd}"
    if ! (cd "$worktree_path" && bash -c "$custom_cmd" 2>&1); then
      _handle_setup_failure "$project_dir" "$is_optional" "custom setup" || return 1
    fi
  fi

  return 0
}
