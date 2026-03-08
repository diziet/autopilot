#!/usr/bin/env bash
# Claude invocation helpers for Autopilot.
# Shared functions used by all agent-spawning modules: build_claude_cmd,
# extract_claude_text, and run_claude.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_CLAUDE_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_CLAUDE_LOADED=1

# Source config for AUTOPILOT_* variables.
# shellcheck source=lib/config.sh
source "${BASH_SOURCE[0]%/*}/config.sh"
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"
# shellcheck source=lib/hooks.sh
source "${BASH_SOURCE[0]%/*}/hooks.sh"

# --- Auth Pre-Check ---

# Check if a Claude account is authenticated by running a lightweight probe.
# Args: [config_dir]
# Returns: 0 if authenticated, 1 if auth failed.
check_claude_auth() {
  local config_dir="${1:-}"
  local claude_cmd="${AUTOPILOT_CLAUDE_CMD:-claude}"
  local timeout_auth="${AUTOPILOT_TIMEOUT_AUTH_CHECK:-10}"

  local exit_code=0
  # shellcheck disable=SC2030  # Intentional: CLAUDE_CONFIG_DIR set in subshell
  (
    unset CLAUDECODE
    if [[ -n "$config_dir" ]]; then
      export CLAUDE_CONFIG_DIR="$config_dir"
    fi
    timeout "$timeout_auth" "$claude_cmd" -p "echo ok" --max-turns 1 \
      --output-format text
  ) >/dev/null 2>&1 || exit_code=$?

  return "$exit_code"
}

# Derive the account number from a config dir path (e.g. ~/.claude-account1 → 1).
_extract_account_number() {
  local config_dir="$1"
  if [[ "$config_dir" =~ account([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# Get the alternate config dir by swapping account number (1↔2).
_get_alternate_config_dir() {
  local config_dir="$1"
  local account_num
  account_num="$(_extract_account_number "$config_dir")" || return 1

  local alt_num
  if [[ "$account_num" -eq 1 ]]; then
    alt_num=2
  elif [[ "$account_num" -eq 2 ]]; then
    alt_num=1
  else
    return 1
  fi

  echo "${config_dir/account${account_num}/account${alt_num}}"
}

# Create a PAUSE file to halt the pipeline.
_create_pause_file() {
  local project_dir="$1"
  local reason="$2"
  local pause_file="${project_dir}/.autopilot/PAUSE"

  mkdir -p "${project_dir}/.autopilot"
  echo "$reason" > "$pause_file"
}

# Resolve config dir with auth check and optional fallback.
# Args: primary_config_dir agent_label project_dir
# Prints the resolved config dir to stdout (may differ from primary on fallback).
# Returns: 0 on success, 1 if all accounts fail auth.
resolve_config_dir_with_fallback() {
  local primary_dir="$1"
  local agent_label="$2"
  local project_dir="${3:-.}"
  local fallback_enabled="${AUTOPILOT_AUTH_FALLBACK:-true}"

  # Try primary account.
  if check_claude_auth "$primary_dir"; then
    echo "$primary_dir"
    return 0
  fi

  local primary_num=""
  primary_num="$(_extract_account_number "$primary_dir")" || true
  local primary_desc="account ${primary_num:-unknown}"
  log_msg "$project_dir" "CRITICAL" \
    "Claude auth failed for ${primary_desc} — run /login for CLAUDE_CONFIG_DIR=${primary_dir}"

  # Fallback disabled — fail immediately.
  if [[ "$fallback_enabled" != "true" ]]; then
    return 1
  fi

  # Try alternate account.
  local alt_dir
  alt_dir="$(_get_alternate_config_dir "$primary_dir")" || {
    log_msg "$project_dir" "ERROR" \
      "Cannot derive alternate config dir from ${primary_dir}"
    return 1
  }

  local alt_num=""
  alt_num="$(_extract_account_number "$alt_dir")" || true

  if check_claude_auth "$alt_dir"; then
    log_msg "$project_dir" "WARNING" \
      "Account ${primary_num:-unknown} auth failed — falling back to account ${alt_num:-unknown} for ${agent_label} spawn"
    echo "$alt_dir"
    return 0
  fi

  # Both accounts failed — create PAUSE file.
  log_msg "$project_dir" "CRITICAL" \
    "All Claude accounts failed auth — pipeline paused. Re-authenticate and remove PAUSE to resume."
  _create_pause_file "$project_dir" \
    "All Claude accounts failed auth. Re-authenticate and remove this file to resume."
  return 1
}

# --- Internal Helpers ---

# Populate _BASE_CMD_ARGS array with the base Claude command parts.
# Reads from AUTOPILOT_CLAUDE_CMD, AUTOPILOT_CLAUDE_FLAGS, AUTOPILOT_CLAUDE_MODEL,
# AUTOPILOT_CLAUDE_OUTPUT_FORMAT.
# Caller must declare: local -a _BASE_CMD_ARGS=()
_build_base_cmd_args() {
  local cmd="${AUTOPILOT_CLAUDE_CMD:-claude}"
  local flags="${AUTOPILOT_CLAUDE_FLAGS:-}"
  local model="${AUTOPILOT_CLAUDE_MODEL:-}"
  local output_format="${AUTOPILOT_CLAUDE_OUTPUT_FORMAT:-json}"

  _BASE_CMD_ARGS+=("$cmd")

  # Split flags on whitespace without glob expansion.
  if [[ -n "$flags" ]]; then
    local -a flag_array
    IFS=' ' read -ra flag_array <<< "$flags"
    _BASE_CMD_ARGS+=("${flag_array[@]}")
  fi

  # Append model selection if configured.
  if [[ -n "$model" ]]; then
    _BASE_CMD_ARGS+=("--model" "$model")
  fi

  _BASE_CMD_ARGS+=("--output-format" "$output_format")
}

# --- Command Construction ---

# Build a display string of the Claude CLI command from config.
# Intended for logging and display, not direct execution.
# Outputs: space-separated command string to stdout.
build_claude_cmd() {
  local -a _BASE_CMD_ARGS=()
  _build_base_cmd_args
  echo "${_BASE_CMD_ARGS[*]}"
}

# --- JSON Output Parsing ---

# Parse Claude JSON output to extract the .result text field.
# Reads from stdin if no argument, or from a file path argument.
extract_claude_text() {
  local input_file="${1:-}"
  local json_content

  if [[ -n "$input_file" ]]; then
    if [[ ! -f "$input_file" ]]; then
      echo ""
      return 1
    fi
    json_content="$(cat "$input_file")"
  else
    json_content="$(cat)"
  fi

  if [[ -z "$json_content" ]]; then
    echo ""
    return 1
  fi

  local result
  result="$(echo "$json_content" | jq -r '.result // empty' 2>/dev/null)"

  if [[ -z "$result" ]]; then
    echo ""
    return 1
  fi

  echo "$result"
}

# --- Prompt File Reading ---

# Read a prompt template file from disk. Shared by coder, fixer, etc.
_read_prompt_file() {
  local prompt_file="$1"
  local project_dir="${2:-.}"

  if [[ ! -f "$prompt_file" ]]; then
    log_msg "$project_dir" "ERROR" "Prompt file not found: ${prompt_file}"
    return 1
  fi

  cat "$prompt_file"
}

# --- Agent Result Logging ---

# Log an agent result with appropriate severity. Shared by coder, fixer, etc.
_log_agent_result() {
  local project_dir="$1"
  local agent_label="$2"
  local task_number="$3"
  local exit_code="$4"
  local output_file="$5"
  local extra_context="${6:-}"

  local suffix=""
  if [[ -n "$extra_context" ]]; then
    suffix=", ${extra_context}"
  fi

  if [[ "$exit_code" -eq 0 ]]; then
    log_msg "$project_dir" "INFO" \
      "${agent_label} completed task ${task_number}${suffix}"
  elif [[ "$exit_code" -eq 124 ]]; then
    log_msg "$project_dir" "WARNING" \
      "${agent_label} timed out on task ${task_number}${suffix} (output: ${output_file})"
  else
    log_msg "$project_dir" "ERROR" \
      "${agent_label} failed on task ${task_number}${suffix} (exit=${exit_code}, output: ${output_file})"
  fi
}

# --- Claude Execution ---

# Run Claude with timeout and CLAUDECODE isolation.
# Args: timeout_seconds prompt [config_dir] [extra_args...]
# Prints output file path to stdout, stderr file at "${output_file}.err".
# Returns: Claude's exit code (or 124 on timeout).
run_claude() {
  local timeout_seconds="$1"
  local prompt="$2"
  local config_dir="${3:-}"
  shift 3 2>/dev/null || shift $#

  local output_file
  output_file="$(mktemp "${TMPDIR:-/tmp}/autopilot-claude.XXXXXX")"
  local error_file="${output_file}.err"

  # Build command from shared helper.
  local -a _BASE_CMD_ARGS=()
  _build_base_cmd_args

  local -a cmd_args=("${_BASE_CMD_ARGS[@]}")

  # Append any extra arguments passed to run_claude.
  if [[ $# -gt 0 ]]; then
    cmd_args+=("$@")
  fi

  # Append the prompt.
  cmd_args+=("--print" "$prompt")

  local exit_code=0

  # Run with CLAUDECODE unset for session isolation, in a subshell.
  # Stdout (JSON) and stderr (diagnostics) go to separate files.
  # shellcheck disable=SC2031  # Intentional: CLAUDE_CONFIG_DIR set in subshell
  (
    unset CLAUDECODE
    # Set CLAUDE_CONFIG_DIR if specified.
    if [[ -n "$config_dir" ]]; then
      export CLAUDE_CONFIG_DIR="$config_dir"
    fi
    # Change to work_dir so Claude operates inside the worktree.
    if [[ -n "${_AGENT_WORK_DIR:-}" ]]; then
      cd "$_AGENT_WORK_DIR"
    fi
    timeout "$timeout_seconds" "${cmd_args[@]}"
  ) > "$output_file" 2>"$error_file" || exit_code=$?

  echo "$output_file"
  return "$exit_code"
}

# --- Claude Run-and-Extract Lifecycle ---

# Run Claude and extract text from response in a single call.
# Handles the common pattern: run_claude -> check exit -> extract_claude_text -> cleanup.
# Args: timeout_seconds prompt [config_dir] [extra_args...]
# Prints extracted text to stdout (empty on failure).
# Returns: 0 on success, 1 on Claude failure or empty response.
_run_claude_and_extract() {
  local timeout_seconds="$1"
  local prompt="$2"
  local config_dir="${3:-}"
  shift 3 2>/dev/null || shift $#

  local output_file exit_code=0
  output_file="$(run_claude "$timeout_seconds" "$prompt" "$config_dir" "$@")" || exit_code=$?

  if [[ "$exit_code" -ne 0 ]]; then
    rm -f "$output_file" "${output_file}.err"
    return 1
  fi

  local text
  text="$(extract_claude_text "$output_file")" || true
  rm -f "$output_file" "${output_file}.err"

  if [[ -z "$text" ]]; then
    return 1
  fi

  echo "$text"
}

# --- Agent Output Saving ---

# Save agent output JSON for future session resume lookups.
_save_agent_output() {
  local project_dir="$1"
  local agent_name="$2"
  local task_number="$3"
  local output_file="$4"
  local log_dir="${project_dir}/.autopilot/logs"

  mkdir -p "$log_dir"

  local target="${log_dir}/${agent_name}-task-${task_number}.json"
  if [[ -f "$output_file" ]]; then
    cp -f "$output_file" "$target"
  fi
}

# --- Agent Lifecycle ---

# Run Claude with hooks installed/removed around the invocation.
# Args: project_dir config_dir agent_label task_number timeout prompt [extra_args...]
# Echoes output file path to stdout. Returns Claude's exit code.
_run_agent_with_hooks() {
  local project_dir="$1"
  local config_dir="$2"
  local agent_label="$3"
  local task_number="$4"
  local timeout_seconds="$5"
  local prompt="$6"
  shift 6

  local extra_context="${_AGENT_EXTRA_CONTEXT:-}"
  local work_dir="${_AGENT_WORK_DIR:-$project_dir}"

  # Install hooks before spawning (use work_dir so lint/test run in worktree).
  install_hooks "$work_dir" "$config_dir" || {
    log_msg "$project_dir" "WARNING" "Failed to install hooks for ${agent_label}"
  }

  log_msg "$project_dir" "INFO" \
    "Spawning ${agent_label} for task ${task_number} (timeout=${timeout_seconds}s)"

  # Run Claude with the prompt and any extra args.
  local output_file exit_code=0
  output_file="$(run_claude "$timeout_seconds" "$prompt" "$config_dir" \
    "$@")" || exit_code=$?

  # Clean up hooks after agent finishes.
  remove_hooks "$project_dir" "$config_dir" || {
    log_msg "$project_dir" "WARNING" "Failed to remove hooks after ${agent_label}"
  }

  _log_agent_result "$project_dir" "$agent_label" "$task_number" \
    "$exit_code" "$output_file" "$extra_context"

  echo "$output_file"
  return "$exit_code"
}
