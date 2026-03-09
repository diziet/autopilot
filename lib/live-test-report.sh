#!/usr/bin/env bash
# Live test validation and report generation for Autopilot.
# Checks pipeline outputs and produces a pass/fail report.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_LIVE_TEST_REPORT_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_LIVE_TEST_REPORT_LOADED=1

# Validate live test results and generate a report.
# Returns: 0=all pass, 1=some failed, 2=timeout, 3=setup failed.
validate_live_test() {
  local run_dir="$1"
  local repo_dir="$2"
  local exit_code="$3"
  local flag_github="${4:-0}"

  local report_file="${run_dir}/report.md"
  local summary_file="${run_dir}/summary.txt"
  local metrics_file="${repo_dir}/.autopilot/metrics.csv"
  local timing_file="${repo_dir}/.autopilot/phase_timing.csv"
  local usage_file="${repo_dir}/.autopilot/token_usage.csv"
  local tasks_file="${repo_dir}/tasks.md"

  local total_tasks merged_count failed_tasks
  total_tasks="$(_count_report_tasks "$tasks_file")"
  merged_count="$(_count_merged "$metrics_file")"
  failed_tasks="$(_find_failed_tasks "$metrics_file" "$total_tasks")"

  local total_cost duration_str start_time end_time
  total_cost="$(_sum_cost "$usage_file")"
  start_time="$(_read_file_or_default "${run_dir}/start_time" "0")"
  end_time="$(date +%s)"
  duration_str="$(_format_duration "$start_time" "$end_time")"

  # Determine final result based on exit code and task status.
  local result_code result_label
  result_code="$(_determine_result "$exit_code" "$merged_count" "$total_tasks")"
  result_label="$(_result_label "$result_code" "$merged_count" "$total_tasks")"

  _write_report "$report_file" "$duration_str" "$total_cost" \
    "$result_label" "$merged_count" "$total_tasks" \
    "$metrics_file" "$timing_file" "$usage_file" \
    "$failed_tasks" "$flag_github" "$repo_dir"

  _write_summary "$summary_file" "$result_label" "$merged_count" \
    "$total_tasks" "$duration_str" "$total_cost"

  return "$result_code"
}

# Count tasks from a tasks.md file.
_count_report_tasks() {
  local tasks_file="$1"
  [[ -f "$tasks_file" ]] || { echo 0; return 0; }
  local count
  count="$(grep -c '^## Task [0-9]' "$tasks_file" 2>/dev/null)" || true
  echo "${count:-0}"
}

# Count merged rows in metrics.csv.
_count_merged() {
  local metrics_file="$1"
  [[ -f "$metrics_file" ]] || { echo 0; return 0; }
  local count
  count="$(awk -F, '$2 == "merged"' "$metrics_file" | wc -l | tr -d ' ')"
  echo "$count"
}

# Find task numbers that are not merged.
_find_failed_tasks() {
  local metrics_file="$1"
  local total_tasks="$2"

  [[ -f "$metrics_file" ]] || { echo ""; return 0; }

  local failed=""
  local task_num
  for task_num in $(seq 1 "$total_tasks"); do
    if ! awk -F, -v t="$task_num" '$1 == t && $2 == "merged"' \
        "$metrics_file" | grep -q .; then
      failed="${failed:+${failed},}${task_num}"
    fi
  done
  echo "$failed"
}

# Sum cost_usd column from token_usage.csv.
_sum_cost() {
  local usage_file="$1"
  [[ -f "$usage_file" ]] || { echo "0.0000"; return 0; }
  tail -n +2 "$usage_file" | awk -F, '{sum += $7} END {printf "%.4f", sum}'
}

# Read a file's content or return a default.
_read_file_or_default() {
  local filepath="$1"
  local default="$2"
  if [[ -f "$filepath" ]]; then
    cat "$filepath"
  else
    echo "$default"
  fi
}

# Format duration from start/end epoch seconds as "Xm Ys".
_format_duration() {
  local start="$1"
  local end="$2"
  local elapsed=$(( end - start ))
  local minutes=$(( elapsed / 60 ))
  local seconds=$(( elapsed % 60 ))
  echo "${minutes}m ${seconds}s"
}

# Determine result exit code.
_determine_result() {
  local loop_exit="$1"
  local merged="$2"
  local total="$3"

  # Setup failure or timeout propagates directly.
  if [[ "$loop_exit" -eq 2 ]]; then
    echo 2
    return 0
  fi
  if [[ "$loop_exit" -eq 3 ]]; then
    echo 3
    return 0
  fi

  # Check if all tasks merged.
  if [[ "$merged" -ge "$total" ]] && [[ "$total" -gt 0 ]]; then
    echo 0
  else
    echo 1
  fi
}

# Human-readable result label.
_result_label() {
  local code="$1"
  local merged="$2"
  local total="$3"

  case "$code" in
    0) echo "PASS (${merged}/${total} tasks completed)" ;;
    1) echo "FAIL (${merged}/${total} tasks completed)" ;;
    2) echo "TIMEOUT (${merged}/${total} tasks completed)" ;;
    3) echo "SETUP FAILED" ;;
    *) echo "UNKNOWN (exit code ${code})" ;;
  esac
}

# Build a markdown table row for a single task.
_task_row() {
  local task_num="$1"
  local metrics_file="$2"
  local timing_file="$3"
  local usage_file="$4"

  local state pr duration cost
  state="$(_task_field "$metrics_file" "$task_num" 2)"
  pr="$(_task_field "$metrics_file" "$task_num" 3)"
  duration="$(_task_duration "$timing_file" "$task_num")"
  cost="$(_task_cost "$usage_file" "$task_num")"

  echo "| ${task_num} | ${state:-unknown} | ${duration:-—} | \$${cost:-0.0000} | ${pr:+#}${pr:-—} |"
}

# Extract a field from metrics.csv for a given task.
_task_field() {
  local file="$1"
  local task_num="$2"
  local field="$3"
  [[ -f "$file" ]] || return 0
  awk -F, -v t="$task_num" -v f="$field" '$1 == t {print $f}' "$file" | head -1
}

# Calculate total duration for a task from phase_timing.csv.
_task_duration() {
  local file="$1"
  local task_num="$2"
  [[ -f "$file" ]] || return 0
  local total_ms
  total_ms="$(awk -F, -v t="$task_num" '$1 == t {sum += $4} END {print sum+0}' "$file")"
  if [[ "$total_ms" -gt 0 ]]; then
    local secs=$(( total_ms / 1000 ))
    _format_duration 0 "$secs"
  fi
}

# Calculate total cost for a task from token_usage.csv.
_task_cost() {
  local file="$1"
  local task_num="$2"
  [[ -f "$file" ]] || return 0
  awk -F, -v t="$task_num" '$1 == t {sum += $7} END {printf "%.4f", sum}' "$file"
}

# Write the full markdown report.
_write_report() {
  local report_file="$1"
  local duration="$2"
  local total_cost="$3"
  local result_label="$4"
  local merged_count="$5"
  local total_tasks="$6"
  local metrics_file="$7"
  local timing_file="$8"
  local usage_file="$9"
  local failed_tasks="${10}"
  local flag_github="${11}"
  local repo_dir="${12}"

  local report_date
  report_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  {
    echo "# Autopilot Live Test Report"
    echo ""
    echo "**Date:** ${report_date}"
    echo "**Duration:** ${duration}"
    echo "**Total cost:** \$${total_cost}"
    echo "**Result:** ${result_label}"
    echo ""
    echo "| Task | State | Duration | Cost | PR |"
    echo "|------|-------|----------|------|----|"

    local task_num
    for task_num in $(seq 1 "$total_tasks"); do
      _task_row "$task_num" "$metrics_file" "$timing_file" "$usage_file"
    done

    echo ""
    echo "## Failures"
    if [[ -z "$failed_tasks" ]]; then
      echo "None."
    else
      _write_failure_details "$failed_tasks" "$metrics_file"
    fi
  } > "$report_file"
}

# Write failure details for each failed task.
_write_failure_details() {
  local failed_csv="$1"
  local metrics_file="$2"

  local task_num
  IFS=',' read -ra failed_arr <<< "$failed_csv"
  for task_num in "${failed_arr[@]}"; do
    local state
    state="$(_task_field "$metrics_file" "$task_num" 2)"
    echo "- Task ${task_num}: ${state:-no metrics entry}"
  done
}

# Write a short summary for the status command.
_write_summary() {
  local summary_file="$1"
  local result_label="$2"
  local merged="$3"
  local total="$4"
  local duration="$5"
  local cost="$6"

  {
    echo "Result: ${result_label}"
    echo "Tasks: ${merged}/${total} merged"
    echo "Duration: ${duration}"
    echo "Cost: \$${cost}"
  } > "$summary_file"
}
