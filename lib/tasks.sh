#!/usr/bin/env bash
# Task file parsing for Autopilot.
# Supports both "## Task N" and "### PR N" heading formats.
# Auto-detects task file location and parses AUTOPILOT_CONTEXT_FILES.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_TASKS_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_TASKS_LOADED=1

# Source config for AUTOPILOT_* variables.
# shellcheck source=lib/config.sh
source "${BASH_SOURCE[0]%/*}/config.sh"

# --- Task File Detection ---

# Locate the tasks file in the project directory.
# Precedence: AUTOPILOT_TASKS_FILE config > tasks.md > *implementation*guide*.md
detect_tasks_file() {
  local project_dir="${1:-.}"

  # If explicitly configured, use that
  if [[ -n "${AUTOPILOT_TASKS_FILE:-}" ]]; then
    local explicit="${project_dir}/${AUTOPILOT_TASKS_FILE}"
    if [[ -f "$explicit" ]]; then
      echo "$explicit"
      return 0
    fi
    return 1
  fi

  # Try tasks.md first
  if [[ -f "${project_dir}/tasks.md" ]]; then
    echo "${project_dir}/tasks.md"
    return 0
  fi

  # Try *implementation*guide*.md (case-insensitive glob)
  local match
  for match in "${project_dir}"/*[Ii]mplementation*[Gg]uide*.md; do
    if [[ -f "$match" ]]; then
      echo "$match"
      return 0
    fi
  done

  return 1
}

# --- Task Parsing ---

# Count total tasks in the tasks file.
count_tasks() {
  local tasks_file="$1"

  [[ -f "$tasks_file" ]] || return 1

  local format
  format="$(_detect_task_format "$tasks_file")"

  case "$format" in
    task_n) grep -c '^## Task [0-9]' "$tasks_file" ;;
    pr_n)   grep -c '^### PR [0-9]' "$tasks_file" ;;
    *)      echo "0"; return 1 ;;
  esac
}

# Extract task body for a given task number.
extract_task() {
  local tasks_file="$1"
  local task_number="$2"

  [[ -f "$tasks_file" ]] || return 1
  [[ "$task_number" =~ ^[0-9]+$ ]] || return 1

  local format
  format="$(_detect_task_format "$tasks_file")"

  case "$format" in
    task_n) _extract_task_body "$tasks_file" "$task_number" "## Task" ;;
    pr_n)   _extract_task_body "$tasks_file" "$task_number" "### PR" ;;
    *)      return 1 ;;
  esac
}

# Detect whether the file uses "## Task N" or "### PR N" format.
_detect_task_format() {
  local tasks_file="$1"

  if grep -q '^## Task [0-9]' "$tasks_file" 2>/dev/null; then
    echo "task_n"
  elif grep -q '^### PR [0-9]' "$tasks_file" 2>/dev/null; then
    echo "pr_n"
  else
    echo "unknown"
  fi
}

# Extract task body between heading N and heading N+1 (or EOF).
_extract_task_body() {
  local tasks_file="$1"
  local task_number="$2"
  local heading_prefix="$3"

  local in_task=0
  local found=0
  local output=""

  while IFS= read -r line; do
    # Check if this line is a matching heading
    if [[ "$line" =~ ^${heading_prefix}[[:space:]]+${task_number}([^0-9]|$) ]]; then
      in_task=1
      found=1
      output="${line}"
      continue
    fi

    # If we're in the task, check for the next heading (end of task)
    if [[ "$in_task" -eq 1 ]]; then
      if [[ "$line" =~ ^${heading_prefix}[[:space:]]+[0-9] ]]; then
        break
      fi
      output="${output}
${line}"
    fi
  done < "$tasks_file"

  if [[ "$found" -eq 1 ]]; then
    echo "$output"
    return 0
  fi
  return 1
}

# Extract the title (first heading line) for a given task number.
extract_task_title() {
  local tasks_file="$1"
  local task_number="$2"

  [[ -f "$tasks_file" ]] || return 1

  local format
  format="$(_detect_task_format "$tasks_file")"

  local pattern
  case "$format" in
    task_n) pattern="^## Task ${task_number}" ;;
    pr_n)   pattern="^### PR ${task_number}" ;;
    *)      return 1 ;;
  esac

  local match
  match="$(grep "$pattern" "$tasks_file" | head -1)"
  if [[ -z "$match" ]]; then
    return 1
  fi
  echo "$match"
}

# --- Context Files ---

# Parse AUTOPILOT_CONTEXT_FILES (colon-separated) into newline-separated list.
# Resolves paths relative to project_dir. Skips non-existent files.
parse_context_files() {
  local project_dir="${1:-.}"
  local context_files="${AUTOPILOT_CONTEXT_FILES:-}"

  [[ -z "$context_files" ]] && return 0

  local IFS=':'
  local path
  for path in $context_files; do
    # Skip empty segments (e.g., leading/trailing colons)
    [[ -z "$path" ]] && continue

    local resolved
    # Absolute paths used as-is; relative paths resolved from project_dir
    if [[ "$path" = /* ]]; then
      resolved="$path"
    else
      resolved="${project_dir}/${path}"
    fi

    if [[ -f "$resolved" ]]; then
      echo "$resolved"
    fi
  done
}

# Read all context files and concatenate their contents.
read_context_files() {
  local project_dir="${1:-.}"
  local file_list
  local output=""

  file_list="$(parse_context_files "$project_dir")"
  [[ -z "$file_list" ]] && return 0

  while IFS= read -r file_path; do
    [[ -z "$file_path" ]] && continue
    if [[ -n "$output" ]]; then
      output="${output}

---

"
    fi
    output="${output}$(cat "$file_path")"
  done <<< "$file_list"

  echo "$output"
}
