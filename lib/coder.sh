#!/usr/bin/env bash
# Coder agent for Autopilot.
# Spawns a Claude Code agent to implement a task on a feature branch.
# Uses lib/claude.sh helpers for invocation. Reads prompts/implement.md
# at runtime. Includes context files from AUTOPILOT_CONTEXT_FILES.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_CODER_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_CODER_LOADED=1

# Source dependencies.
# shellcheck source=lib/config.sh
source "${BASH_SOURCE[0]%/*}/config.sh"
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"
# shellcheck source=lib/claude.sh
source "${BASH_SOURCE[0]%/*}/claude.sh"
# shellcheck source=lib/tasks.sh
source "${BASH_SOURCE[0]%/*}/tasks.sh"
# shellcheck source=lib/hooks.sh
source "${BASH_SOURCE[0]%/*}/hooks.sh"

# Directory where prompts/ lives (relative to this script's location).
_CODER_LIB_DIR="${BASH_SOURCE[0]%/*}"
_CODER_PROMPTS_DIR="${_CODER_LIB_DIR}/../prompts"

# --- Prompt Construction ---

# Read the implement.md prompt template from disk (delegates to shared helper).
_read_implement_prompt() {
  _read_prompt_file "${_CODER_PROMPTS_DIR}/implement.md" "${1:-.}"
}

# Build the full coder prompt with task body, context, and prior summaries.
build_coder_prompt() {
  local project_dir="${1:-.}"
  local task_number="$2"
  local task_body="$3"
  local completed_summary="${4:-}"

  local prompt=""

  # Read base prompt template.
  local base_prompt
  base_prompt="$(_read_implement_prompt "$project_dir")" || return 1
  prompt="${base_prompt}"

  # Append reference documents section if context files configured.
  local context_section
  context_section="$(_build_context_section "$project_dir")"
  if [[ -n "$context_section" ]]; then
    prompt="${prompt}

## Reference Documents

Read these files for project context and requirements:

${context_section}

Read them before starting work."
  fi

  # Append the task body.
  prompt="${prompt}

## Task ${task_number}

${task_body}"

  # Append completed task summaries if available.
  if [[ -n "$completed_summary" ]]; then
    prompt="${prompt}

## Previously Completed Tasks
${completed_summary}"
  fi

  # Append branch naming reminder.
  local branch_prefix="${AUTOPILOT_BRANCH_PREFIX:-autopilot}"
  prompt="${prompt}

---

**Branch name:** \`${branch_prefix}/task-${task_number}\`"

  echo "$prompt"
}

# Build the context files section for the prompt.
_build_context_section() {
  local project_dir="${1:-.}"
  local file_list
  file_list="$(parse_context_files "$project_dir")"

  [[ -z "$file_list" ]] && return 0

  local section=""
  local first=true
  while IFS= read -r file_path; do
    [[ -z "$file_path" ]] && continue
    if [[ "$first" == true ]]; then
      section="- \`${file_path}\`"
      first=false
    else
      section="${section}
- \`${file_path}\`"
    fi
  done <<< "$file_list"

  echo "$section"
}

# --- Coder Execution ---

# Run the coder agent for a given task.
# Installs hooks before spawning, cleans up after.
# Returns: Claude's exit code (or 124 on timeout).
run_coder() {
  local project_dir="${1:-.}"
  local task_number="$2"
  local task_body="$3"
  local completed_summary="${4:-}"

  local timeout_coder="${AUTOPILOT_TIMEOUT_CODER:-2700}"
  local config_dir="${AUTOPILOT_CODER_CONFIG_DIR:-}"

  # Build the full prompt.
  local prompt
  prompt="$(build_coder_prompt "$project_dir" "$task_number" \
    "$task_body" "$completed_summary")" || {
    log_msg "$project_dir" "ERROR" "Failed to build coder prompt for task ${task_number}"
    return 1
  }

  # Install hooks before spawning.
  install_hooks "$project_dir" "$config_dir" || {
    log_msg "$project_dir" "WARNING" "Failed to install hooks, continuing without"
  }

  log_msg "$project_dir" "INFO" \
    "Spawning coder for task ${task_number} (timeout=${timeout_coder}s)"

  # Run Claude with the coder prompt.
  local output_file exit_code=0
  output_file="$(run_claude "$timeout_coder" "$prompt" "$config_dir")" || exit_code=$?

  # Clean up hooks after coder finishes.
  remove_hooks "$project_dir" "$config_dir" || {
    log_msg "$project_dir" "WARNING" "Failed to remove hooks after coder"
  }

  _log_agent_result "$project_dir" "Coder" "$task_number" "$exit_code" "$output_file"

  # Output the file path for callers to read.
  echo "$output_file"
  return "$exit_code"
}
