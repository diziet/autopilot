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

# --- Command Construction ---

# Build the full Claude CLI command array from config.
# Args: [config_dir] — optional CLAUDE_CONFIG_DIR override for this role.
# Outputs: space-separated command string to stdout.
build_claude_cmd() {
  local config_dir="${1:-}"
  local cmd="${AUTOPILOT_CLAUDE_CMD:-claude}"
  local flags="${AUTOPILOT_CLAUDE_FLAGS:-}"
  local output_format="${AUTOPILOT_CLAUDE_OUTPUT_FORMAT:-json}"

  local parts=()

  # If a config dir is specified, prepend env var assignment.
  if [[ -n "$config_dir" ]]; then
    parts+=("CLAUDE_CONFIG_DIR=${config_dir}")
  fi

  parts+=("$cmd")

  # Append flags (word-split intentionally).
  if [[ -n "$flags" ]]; then
    # shellcheck disable=SC2206
    parts+=($flags)
  fi

  # Append output format.
  parts+=("--output-format" "$output_format")

  echo "${parts[*]}"
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
# Captures output to a temp file, prints path to stdout.
# Returns: Claude's exit code (or 124 on timeout).
run_claude() {
  local timeout_seconds="$1"
  local prompt="$2"
  local config_dir="${3:-}"
  shift 3 2>/dev/null || shift $#

  local output_file
  output_file="$(mktemp "${TMPDIR:-/tmp}/autopilot-claude.XXXXXX")"

  # Build command parts.
  local cmd="${AUTOPILOT_CLAUDE_CMD:-claude}"
  local flags="${AUTOPILOT_CLAUDE_FLAGS:-}"
  local output_format="${AUTOPILOT_CLAUDE_OUTPUT_FORMAT:-json}"

  local cmd_args=()
  cmd_args+=("$cmd")

  # Append flags (word-split intentionally).
  if [[ -n "$flags" ]]; then
    # shellcheck disable=SC2206
    cmd_args+=($flags)
  fi

  cmd_args+=("--output-format" "$output_format")

  # Append any extra arguments passed to run_claude.
  if [[ $# -gt 0 ]]; then
    cmd_args+=("$@")
  fi

  # Append the prompt.
  cmd_args+=("--print" "$prompt")

  local exit_code=0

  # Run with CLAUDECODE unset for session isolation, in a subshell.
  (
    unset CLAUDECODE
    # Set CLAUDE_CONFIG_DIR if specified.
    if [[ -n "$config_dir" ]]; then
      export CLAUDE_CONFIG_DIR="$config_dir"
    fi
    timeout "$timeout_seconds" "${cmd_args[@]}"
  ) > "$output_file" 2>&1 || exit_code=$?

  echo "$output_file"
  return "$exit_code"
}
