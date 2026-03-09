#!/usr/bin/env bash
# Live test status display for Autopilot.
# Reads run artifacts and displays progress, cost, and results.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_LIVE_TEST_STATUS_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_LIVE_TEST_STATUS_LOADED=1

# Resolve an artifact file path, checking repo dir first then flat status dir.
_resolve_artifact_path() {
  local status_dir="$1"
  local filename="$2"
  if [[ -d "${status_dir}/repo" ]]; then
    echo "${status_dir}/repo/.autopilot/${filename}"
  else
    echo "${status_dir}/${filename}"
  fi
}

# Display the status of the current or most recent live test run.
live_test_status() {
  local current_dir="${LIVE_TEST_BASE_DIR}/current"

  if [[ ! -d "$current_dir" ]] && [[ ! -d "${LIVE_TEST_BASE_DIR}/latest" ]]; then
    echo "No live test runs found."
    return 0
  fi

  # Prefer current, fall back to latest.
  local status_dir="$current_dir"
  [[ -d "$status_dir" ]] || status_dir="${LIVE_TEST_BASE_DIR}/latest"

  _show_run_status "$status_dir"
}

# Display detailed status from a run directory.
_show_run_status() {
  local status_dir="$1"

  # Timestamp.
  if [[ -f "${status_dir}/timestamp" ]]; then
    echo "Run: $(cat "${status_dir}/timestamp")"
  fi

  # Check if process is still running.
  local is_running=0
  if [[ -f "${status_dir}/pid" ]]; then
    local pid
    pid="$(cat "${status_dir}/pid")"
    if ps -p "$pid" >/dev/null 2>&1; then
      is_running=1
      echo "Status: running (PID ${pid})"
    else
      echo "Status: finished (PID ${pid})"
    fi
  fi

  # Elapsed time.
  if [[ -f "${status_dir}/start_time" ]]; then
    local start_time now elapsed_min
    start_time="$(cat "${status_dir}/start_time")"
    now="$(date +%s)"
    elapsed_min=$(( (now - start_time) / 60 ))
    echo "Elapsed: ${elapsed_min} minutes"
  fi

  # Exit code (if finished).
  if [[ "$is_running" -eq 0 ]] && [[ -f "${status_dir}/exit_code" ]]; then
    local code
    code="$(cat "${status_dir}/exit_code")"
    case "$code" in
      0) echo "Result: SUCCESS" ;;
      2) echo "Result: TIMEOUT" ;;
      *) echo "Result: FAILED (exit code ${code})" ;;
    esac
  fi

  # Summary file includes tasks, cost, and duration — no need for
  # _show_task_progress or _show_cost_estimate when it exists.
  local summary_file="${status_dir}/summary.txt"
  if [[ -f "$summary_file" ]]; then
    echo ""
    cat "$summary_file"
    return 0
  fi

  # Fall back to live metrics when summary is not yet generated (run in progress).
  _show_task_progress "$status_dir"
  _show_cost_estimate "$status_dir"
}

# Show task completion progress.
_show_task_progress() {
  local status_dir="$1"
  local metrics_file
  metrics_file="$(_resolve_artifact_path "$status_dir" "metrics.csv")"

  [[ -f "$metrics_file" ]] || return 0

  local merged total
  merged="$(awk -F, '$2 == "merged"' "$metrics_file" | wc -l | tr -d ' ')"
  total="$(tail -n +2 "$metrics_file" | wc -l | tr -d ' ')"

  echo "Tasks: ${merged} merged, ${total} total"
}

# Show estimated cost from token_usage.csv.
_show_cost_estimate() {
  local status_dir="$1"
  local usage_file
  usage_file="$(_resolve_artifact_path "$status_dir" "token_usage.csv")"

  [[ -f "$usage_file" ]] || return 0

  # Sum cost_usd column (column 7).
  local total_cost
  total_cost="$(tail -n +2 "$usage_file" | awk -F, '{sum += $7} END {printf "%.4f", sum}')"
  echo "Estimated cost: \$${total_cost}"
}

# --- Shared summary helpers for doctor/status integration ---

# Read a field value from a summary.txt file. Returns "unknown" on missing/empty.
read_live_test_summary_field() {
  local summary_file="$1"
  local field_name="$2"

  [[ -f "$summary_file" ]] || { echo "unknown"; return 0; }

  local value
  value="$(grep "^${field_name}:" "$summary_file" 2>/dev/null | sed "s/^${field_name}: *//" || true)"
  if [[ -z "$value" ]]; then
    echo "unknown"
  else
    echo "$value"
  fi
}

# Read the timestamp from a live test run directory. Returns "unknown" if missing.
read_live_test_timestamp() {
  local run_dir="$1"
  if [[ -f "${run_dir}/timestamp" ]]; then
    cat "${run_dir}/timestamp"
  else
    echo "unknown"
  fi
}

# Determine check level (pass/warn) from a live test result string.
live_test_result_level() {
  local result="$1"
  case "$result" in
    PASS*) echo "pass" ;;
    *)     echo "warn" ;;
  esac
}
