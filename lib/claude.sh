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

# --- Internal Helpers ---

# Populate _BASE_CMD_ARGS array with the base Claude command parts.
# Reads from AUTOPILOT_CLAUDE_CMD, AUTOPILOT_CLAUDE_FLAGS, AUTOPILOT_CLAUDE_OUTPUT_FORMAT.
# Caller must declare: local -a _BASE_CMD_ARGS=()
_build_base_cmd_args() {
  local cmd="${AUTOPILOT_CLAUDE_CMD:-claude}"
  local flags="${AUTOPILOT_CLAUDE_FLAGS:-}"
  local output_format="${AUTOPILOT_CLAUDE_OUTPUT_FORMAT:-json}"

  _BASE_CMD_ARGS+=("$cmd")

  # Split flags on whitespace without glob expansion.
  if [[ -n "$flags" ]]; then
    local -a flag_array
    IFS=' ' read -ra flag_array <<< "$flags"
    _BASE_CMD_ARGS+=("${flag_array[@]}")
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
  (
    unset CLAUDECODE
    # Set CLAUDE_CONFIG_DIR if specified.
    if [[ -n "$config_dir" ]]; then
      export CLAUDE_CONFIG_DIR="$config_dir"
    fi
    timeout "$timeout_seconds" "${cmd_args[@]}"
  ) > "$output_file" 2>"$error_file" || exit_code=$?

  echo "$output_file"
  return "$exit_code"
}
