#!/usr/bin/env bash
# Failure diagnosis for Autopilot.
# Spawns a diagnostician agent when a task hits max retries. Selects the
# appropriate log file based on the pipeline state (coder, fixer, fix-tests).
# Uses lib/claude.sh helpers and AUTOPILOT_TIMEOUT_DIAGNOSE config.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_DIAGNOSE_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_DIAGNOSE_LOADED=1

# Source dependencies.
# shellcheck source=lib/config.sh
source "${BASH_SOURCE[0]%/*}/config.sh"
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"
# shellcheck source=lib/claude.sh
source "${BASH_SOURCE[0]%/*}/claude.sh"

# Directory where prompts/ lives (relative to this script's location).
_DIAGNOSE_LIB_DIR="${BASH_SOURCE[0]%/*}"
_DIAGNOSE_PROMPTS_DIR="${_DIAGNOSE_LIB_DIR}/../prompts"

# --- Exit Code Constants ---
readonly DIAGNOSE_OK=0
readonly DIAGNOSE_ERROR=1
export DIAGNOSE_OK DIAGNOSE_ERROR

# --- Input Validation ---

# Validate that a task number is a positive integer.
_validate_task_number() {
  local task_number="$1"
  [[ "$task_number" =~ ^[0-9]+$ ]]
}

# --- Log File Selection ---

# Select the most relevant log file for a task based on current pipeline state.
# Returns the path to the log file, or empty string if none found.
select_log_file() {
  local project_dir="${1:-.}"
  local task_number="$2"
  local current_state="${3:-}"
  local log_dir="${project_dir}/.autopilot/logs"

  if ! _validate_task_number "$task_number"; then
    return 1
  fi

  # State-specific log file mapping.
  case "$current_state" in
    test_fixing)
      _find_first_existing_log "$log_dir" \
        "fix-tests-task-${task_number}.log" \
        "coder-task-${task_number}.json" \
        "pipeline.log"
      ;;
    fixing|reviewed)
      _find_first_existing_log "$log_dir" \
        "fixer-task-${task_number}.json" \
        "coder-task-${task_number}.json" \
        "pipeline.log"
      ;;
    implementing|pending)
      _find_first_existing_log "$log_dir" \
        "coder-task-${task_number}.json" \
        "pipeline.log"
      ;;
    *)
      # Fallback: try all log types in order of specificity.
      _find_first_existing_log "$log_dir" \
        "fix-tests-task-${task_number}.log" \
        "fixer-task-${task_number}.json" \
        "coder-task-${task_number}.json" \
        "pipeline.log"
      ;;
  esac
}

# Return the first existing log file path from the candidates.
_find_first_existing_log() {
  local log_dir="$1"
  shift

  local candidate
  for candidate in "$@"; do
    local full_path="${log_dir}/${candidate}"
    if [[ -f "$full_path" ]] && [[ -s "$full_path" ]]; then
      echo "$full_path"
      return 0
    fi
  done

  # No log files found.
  return 1
}

# Read log content with a reasonable tail limit for the prompt.
_read_log_content() {
  local log_file="$1"
  local max_lines="${2:-200}"

  if [[ ! -f "$log_file" ]]; then
    echo "(no log file found)"
    return 0
  fi

  local total_lines
  total_lines="$(wc -l < "$log_file" | tr -d ' ')"

  if [[ "$total_lines" -le "$max_lines" ]]; then
    cat "$log_file"
  else
    echo "... [showing last ${max_lines} of ${total_lines} lines]"
    tail -n "$max_lines" "$log_file"
  fi
}

# --- Prompt Construction ---

# Build the diagnosis prompt with log content and task metadata.
build_diagnosis_prompt() {
  local task_number="$1"
  local task_body="$2"
  local log_content="$3"
  local current_state="${4:-unknown}"
  local retry_count="${5:-0}"
  local max_retries="${6:-5}"
  local log_file_path="${7:-}"

  local system_prompt=""
  system_prompt="$(_read_prompt_file \
    "${_DIAGNOSE_PROMPTS_DIR}/diagnose.md" "." 2>/dev/null)" || true

  local prompt=""
  if [[ -n "$system_prompt" ]]; then
    prompt="${system_prompt}

---

"
  fi

  local log_source=""
  if [[ -n "$log_file_path" ]]; then
    log_source=" (from $(basename "$log_file_path"))"
  fi

  prompt="${prompt}## Task ${task_number} — Failure Diagnosis

**State at failure:** \`${current_state}\`
**Retries:** ${retry_count}/${max_retries}

### Task Description

${task_body}

### Pipeline Logs${log_source}

\`\`\`
${log_content}
\`\`\`

Diagnose the root cause and provide actionable recommendations."

  echo "$prompt"
}

# --- Diagnosis Execution ---

# Run the diagnostician agent for the current failing task.
# Note: retry_count is read from global pipeline state, so task_number must
# match the pipeline's current task for accurate retry info in the prompt.
run_diagnosis() {
  local project_dir="${1:-.}"
  local task_number="$2"
  local task_body="${3:-}"
  local current_state="${4:-}"

  if ! _validate_task_number "$task_number"; then
    log_msg "$project_dir" "ERROR" \
      "Invalid task number for diagnosis: ${task_number}"
    return "$DIAGNOSE_ERROR"
  fi

  local timeout_diagnose="${AUTOPILOT_TIMEOUT_DIAGNOSE:-300}"
  local max_retries="${AUTOPILOT_MAX_RETRIES:-5}"

  # Read current retry count.
  local retry_count
  retry_count="$(get_retry_count "$project_dir")"

  # Select the relevant log file for this state.
  local log_file=""
  log_file="$(select_log_file "$project_dir" "$task_number" \
    "$current_state")" || true

  # Read the log content for inclusion in the prompt.
  local log_content
  log_content="$(_read_log_content "$log_file")"

  # Provide a placeholder task body if not given.
  if [[ -z "$task_body" ]]; then
    task_body="(task body not available)"
  fi

  # Build the diagnosis prompt.
  local prompt
  prompt="$(build_diagnosis_prompt "$task_number" "$task_body" \
    "$log_content" "$current_state" "$retry_count" "$max_retries" \
    "$log_file")"

  log_msg "$project_dir" "INFO" \
    "Spawning diagnostician for task ${task_number} (state=${current_state}, retries=${retry_count}/${max_retries})"

  # Run Claude and extract the diagnosis text.
  local diagnosis_text
  diagnosis_text="$(_run_claude_and_extract "$timeout_diagnose" \
    "$prompt")" || {
    log_msg "$project_dir" "ERROR" \
      "Diagnostician failed for task ${task_number}"
    return "$DIAGNOSE_ERROR"
  }

  if [[ -z "$diagnosis_text" ]]; then
    log_msg "$project_dir" "WARNING" \
      "Empty diagnosis response for task ${task_number}"
    return "$DIAGNOSE_ERROR"
  fi

  # Save the diagnosis to disk for reference.
  _save_diagnosis "$project_dir" "$task_number" "$diagnosis_text"

  log_msg "$project_dir" "INFO" \
    "Diagnosis complete for task ${task_number}"
  echo "$diagnosis_text"
  return "$DIAGNOSE_OK"
}

# --- Output Persistence ---

# Save diagnosis output to the logs directory.
_save_diagnosis() {
  local project_dir="$1"
  local task_number="$2"
  local diagnosis_text="$3"

  if ! _validate_task_number "$task_number"; then
    return 1
  fi

  local log_dir="${project_dir}/.autopilot/logs"
  mkdir -p "$log_dir"

  local target="${log_dir}/diagnosis-task-${task_number}.md"
  echo "$diagnosis_text" > "$target"

  log_msg "$project_dir" "INFO" \
    "Saved diagnosis for task ${task_number}: ${target}"
}

# Read a previously saved diagnosis for a task.
read_diagnosis() {
  local project_dir="${1:-.}"
  local task_number="$2"

  if ! _validate_task_number "$task_number"; then
    return 1
  fi

  local diagnosis_file="${project_dir}/.autopilot/logs/diagnosis-task-${task_number}.md"

  if [[ -f "$diagnosis_file" ]] && [[ -s "$diagnosis_file" ]]; then
    cat "$diagnosis_file"
  fi
}
