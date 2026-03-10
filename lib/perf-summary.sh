#!/usr/bin/env bash
# Performance summary posting for Autopilot.
# Formats a markdown table from agent output JSON and phase timing CSV,
# then posts it as a PR comment. Best-effort — failures are non-fatal.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_PERF_SUMMARY_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_PERF_SUMMARY_LOADED=1

# Source dependencies.
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"
# shellcheck source=lib/metrics.sh
source "${BASH_SOURCE[0]%/*}/metrics.sh"
# shellcheck source=lib/tasks.sh
source "${BASH_SOURCE[0]%/*}/tasks.sh"

# --- Number formatting helpers ---

# Format a number with comma separators (e.g. 1234567 -> 1,234,567).
_format_number() {
  local num="$1"
  if [[ "$num" == "0" || -z "$num" ]]; then echo "0"; return; fi
  # Pure sed approach: insert commas from right to left.
  echo "$num" | sed -e :a -e 's/\(.*[0-9]\)\([0-9]\{3\}\)/\1,\2/;ta'
}

# Format milliseconds as human-readable seconds (e.g. 900000 -> 900s).
_format_ms_as_sec() {
  local ms="$1"
  if [[ "$ms" == "0" || -z "$ms" ]]; then echo "0s"; return; fi
  echo "$(( ms / 1000 ))s"
}

# Format seconds as human-readable duration (e.g. 3240 -> 54m).
_format_sec_duration() {
  local sec="$1"
  if [[ "$sec" == "0" || -z "$sec" ]]; then echo "0s"; return; fi
  if [[ "$sec" -ge 3600 ]]; then
    local h=$(( sec / 3600 ))
    local m=$(( (sec % 3600) / 60 ))
    if [[ "$m" -gt 0 ]]; then echo "${h}h${m}m"; else echo "${h}h"; fi
  elif [[ "$sec" -ge 60 ]]; then
    local m=$(( sec / 60 ))
    local s=$(( sec % 60 ))
    if [[ "$s" -gt 0 ]]; then echo "${m}m${s}s"; else echo "${m}m"; fi
  else
    echo "${sec}s"
  fi
}

# --- Agent JSON extraction ---

# Extract usage fields from an agent output JSON file into a table row.
# Delegates to _parse_agent_json from metrics.sh for the actual parsing.
# Outputs: wall|api|turns|in|out|cache_read|cache_create|cost
_extract_agent_row() {
  _parse_agent_json "$1"
}

# --- Table row formatting ---

# Format one agent phase row as a markdown table line.
_format_phase_row() {
  local label="$1" raw_data="$2" retries="$3"
  if [[ -z "$raw_data" ]]; then return 1; fi

  local wall_ms api_ms turns in_tok out_tok cache_r cache_c cost
  IFS='|' read -r wall_ms api_ms turns in_tok out_tok cache_r cache_c cost <<< "$raw_data"

  local wall_s
  wall_s="$(_format_ms_as_sec "$wall_ms")"
  local api_s
  api_s="$(_format_ms_as_sec "$api_ms")"

  # Round cost to two decimal places (cents).
  local cost_fmt
  printf -v cost_fmt '%.2f' "$cost"

  printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | $%s |\n' \
    "$label" "$wall_s" "$api_s" "$turns" \
    "$(_format_number "$in_tok")" "$(_format_number "$out_tok")" \
    "$(_format_number "$cache_r")" "$(_format_number "$cache_c")" \
    "$retries" "$cost_fmt"
}

# Format a phase-only row (test gate etc.) with wall time but no agent data.
_format_phase_only_row() {
  local label="$1" wall_sec="$2"
  local wall_display="${wall_sec}s"
  printf '| %s | %s | — | — | — | — | — | — | — | — |\n' \
    "$label" "$wall_display"
}

# --- Task description extraction ---

# Extract the task description from the heading line in tasks.md.
_extract_task_description() {
  local project_dir="$1" task_number="$2"
  local heading
  heading="$(resolve_task_title "$project_dir" "$task_number" 2>/dev/null)" || true
  if [[ -z "$heading" ]]; then
    echo "Task ${task_number}"
    return
  fi
  # Strip leading ## or ### and whitespace
  heading="${heading#\#\#\# }"
  heading="${heading#\#\# }"
  echo "$heading"
}

# --- Phase timing extraction ---

# Read phase timing from phase_timing.csv for a given task.
# Outputs implementing_sec|test_fixing_sec|pr_open_sec|reviewed_sec|fixing_sec|merging_sec
_read_phase_timing() {
  local project_dir="$1" task_number="$2"
  local phase_csv="${project_dir}/.autopilot/phase_timing.csv"
  [[ -f "$phase_csv" ]] || return 1
  local row
  row="$(grep "^${task_number}," "$phase_csv" | head -1)" || return 1
  [[ -n "$row" ]] || return 1
  # CSV: task,pr,impl,test_fix,pr_open,reviewed,fixing,merging,total
  local impl test_fix pr_open reviewed fixing merging _skip
  IFS=',' read -r _skip _skip impl test_fix pr_open reviewed fixing merging _skip <<< "$row"
  echo "${impl}|${test_fix}|${pr_open}|${reviewed}|${fixing}|${merging}"
}

# --- Main summary builder ---

# Build the performance summary markdown table for a task.
build_performance_summary() {
  local project_dir="$1" task_number="$2"
  local logs_dir="${project_dir}/.autopilot/logs"

  # Task description header.
  local description
  description="$(_extract_task_description "$project_dir" "$task_number")"
  local table="**${description}**"
  table="${table}
"
  table="${table}
| Phase | Wall | API | Turns | Tokens In | Tokens Out | Cache Read | Cache Create | Retries | Cost |"
  table="${table}
|-------|------|-----|-------|-----------|------------|------------|--------------|---------|------|"

  # Read retry counts from state.
  local retry_count test_fix_retries
  retry_count="$(_validate_int "$(read_state "$project_dir" "retry_count")")"
  test_fix_retries="$(_validate_int "$(read_state "$project_dir" "test_fix_retries")")"

  # Read phase timing for test gate row.
  local phase_timing test_fix_sec
  phase_timing="$(_read_phase_timing "$project_dir" "$task_number")" || phase_timing="0|0|0|0|0|0"
  # shellcheck disable=SC2034
  local _pt_impl _pt_pr_open _pt_reviewed _pt_fixing _pt_merging
  IFS='|' read -r _pt_impl test_fix_sec _pt_pr_open _pt_reviewed _pt_fixing _pt_merging <<< "$phase_timing"

  # Accumulate totals for the summary row.
  local total_wall=0 total_turns=0 total_in=0 total_out=0 total_cost=0
  local total_retries=0

  # --- Coder row ---
  local coder_data
  coder_data="$(_extract_agent_row "${logs_dir}/coder-task-${task_number}.json")" || true
  if [[ -n "$coder_data" ]]; then
    local row
    row="$(_format_phase_row "Coder" "$coder_data" "$retry_count")"
    table="${table}
${row}"
    _accumulate_totals "$coder_data" "$retry_count"
  fi

  # --- Test gate row (phase-only, from phase_timing) ---
  if [[ "$test_fix_sec" -gt 0 ]]; then
    local tg_row
    tg_row="$(_format_phase_only_row "Test gate" "$test_fix_sec")"
    table="${table}
${tg_row}"
  fi

  # --- Fixer row ---
  local fixer_data
  fixer_data="$(_extract_agent_row "${logs_dir}/fixer-task-${task_number}.json")" || true
  if [[ -n "$fixer_data" ]]; then
    local row
    row="$(_format_phase_row "Fixer" "$fixer_data" "$test_fix_retries")"
    table="${table}
${row}"
    _accumulate_totals "$fixer_data" "$test_fix_retries"
  fi

  # --- Reviewer rows (aggregate all reviewer personas) ---
  local reviewer_data
  reviewer_data="$(_aggregate_reviewer_data "$logs_dir" "$task_number")" || true
  if [[ -n "$reviewer_data" ]]; then
    local row
    row="$(_format_phase_row "Review" "$reviewer_data" "0")"
    table="${table}
${row}"
    _accumulate_totals "$reviewer_data" "0"
  fi

  # --- Merger row ---
  local merger_data
  merger_data="$(_extract_agent_row "${logs_dir}/merger-task-${task_number}.json")" || true
  if [[ -n "$merger_data" ]]; then
    local row
    row="$(_format_phase_row "Merger" "$merger_data" "0")"
    table="${table}
${row}"
    _accumulate_totals "$merger_data" "0"
  fi

  # --- Total row ---
  local total_wall_fmt
  total_wall_fmt="$(_format_sec_duration "$(( total_wall / 1000 ))")"
  table="${table}
| **Total** | **${total_wall_fmt}** | — | **${total_turns}** | **$(_format_number "$total_in")** | **$(_format_number "$total_out")** | — | — | **${total_retries}** | **\$${total_cost}** |"

  echo "$table"
}

# Accumulate totals from a pipe-separated data string.
_accumulate_totals() {
  local raw_data="$1" retries="$2"
  local wall_ms api_ms turns in_tok out_tok cache_r cache_c cost
  IFS='|' read -r wall_ms api_ms turns in_tok out_tok cache_r cache_c cost <<< "$raw_data"
  total_wall=$(( total_wall + wall_ms ))
  total_turns=$(( total_turns + turns ))
  total_in=$(( total_in + in_tok ))
  total_out=$(( total_out + out_tok ))
  total_retries=$(( total_retries + retries ))
  # Cost accumulation using awk for float addition.
  total_cost="$(awk '{printf "%.2f", $1 + $2}' <<< "$total_cost $cost")" || true
}

# Aggregate reviewer JSON outputs for a task into a single data row.
_aggregate_reviewer_data() {
  local logs_dir="$1" task_number="$2"
  local total_wall=0 total_api=0 total_turns=0 total_in=0 total_out=0
  local total_cr=0 total_cc=0 total_cost="0"
  local found=0

  local reviewer_file
  for reviewer_file in "${logs_dir}"/reviewer-*-task-"${task_number}".json; do
    [[ -f "$reviewer_file" ]] || continue
    found=1
    local data
    data="$(_extract_agent_row "$reviewer_file")" || continue
    local w a t i o cr cc c
    IFS='|' read -r w a t i o cr cc c <<< "$data"
    total_wall=$(( total_wall + w ))
    total_api=$(( total_api + a ))
    total_turns=$(( total_turns + t ))
    total_in=$(( total_in + i ))
    total_out=$(( total_out + o ))
    total_cr=$(( total_cr + cr ))
    total_cc=$(( total_cc + cc ))
    total_cost="$(echo "$total_cost $c" | awk '{printf "%.2f", $1 + $2}')" || true
  done

  [[ "$found" -eq 0 ]] && return 1
  echo "${total_wall}|${total_api}|${total_turns}|${total_in}|${total_out}|${total_cr}|${total_cc}|${total_cost}"
}

# --- Post to GitHub ---

# Post performance summary as a PR comment. Best-effort, non-fatal.
post_performance_summary() {
  local project_dir="$1" task_number="$2" pr_number="$3"
  local repo
  repo="$(get_repo_slug "$project_dir")" || {
    log_msg "$project_dir" "WARNING" \
      "PERF_SUMMARY: could not determine repo slug — skipping"
    return 0
  }

  local table
  table="$(build_performance_summary "$project_dir" "$task_number")" || {
    log_msg "$project_dir" "WARNING" \
      "PERF_SUMMARY: failed to build summary table for task ${task_number}"
    return 0
  }

  local gh_timeout="${AUTOPILOT_TIMEOUT_GH:-30}"
  if timeout "$gh_timeout" gh pr comment "$pr_number" \
      --repo "$repo" --body "$table" 2>/dev/null; then
    log_msg "$project_dir" "INFO" \
      "PERF_SUMMARY: posted performance summary for task ${task_number} on PR #${pr_number}"
  else
    log_msg "$project_dir" "WARNING" \
      "PERF_SUMMARY: failed to post summary for task ${task_number} — non-fatal"
  fi
}

# Spawn performance summary posting in background (non-blocking).
post_performance_summary_bg() {
  local project_dir="$1" task_number="$2" pr_number="$3"
  (
    post_performance_summary "$project_dir" "$task_number" "$pr_number"
  ) &
  local pid=$!
  disown "$pid" 2>/dev/null || true
  log_msg "$project_dir" "INFO" \
    "PERF_SUMMARY: spawned background post for task ${task_number} (PID=${pid})"
}
