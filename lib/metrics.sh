#!/usr/bin/env bash
# Metrics tracking for Autopilot.
# CSV tracking for per-task metrics, phase timing (including test_fixing_sec),
# token usage, per-phase timing with sub-step instrumentation (TIMER tags),
# and CSV header auto-update on schema change.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_METRICS_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_METRICS_LOADED=1

# Source dependencies.
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"

# --- Exit code constants ---
readonly METRICS_OK=0
readonly METRICS_ERROR=1
export METRICS_OK METRICS_ERROR

# --- CSV Headers (single source of truth) ---
readonly _METRICS_HEADER="task_number,status,pr_number,start_time,end_time,duration_minutes,retry_count,lines_added,lines_removed,comment_count,files_changed"
readonly _PHASE_HEADER="task_number,pr_number,implementing_sec,test_fixing_sec,pr_open_sec,reviewed_sec,fixing_sec,merging_sec,total_sec"
readonly _USAGE_HEADER="task_number,phase,input_tokens,output_tokens,cache_read_tokens,cache_creation_tokens,cost_usd,wall_ms,api_ms,num_turns"

# --- Internal file paths ---
_METRICS_FILE=""
_PHASE_FILE=""
_USAGE_FILE=""

# --- CSV init with header auto-update ---

# Create CSV or update header in place if schema changed.
_auto_update_header() {
  local csv_file="$1" expected_header="$2"
  if [[ ! -f "$csv_file" ]]; then
    echo "$expected_header" > "$csv_file"
    return 0
  fi
  local current_header
  current_header="$(head -1 "$csv_file")"
  if [[ "$current_header" != "$expected_header" ]]; then
    local tmp="${csv_file}.tmp.$$"
    { echo "$expected_header"; tail -n +2 "$csv_file"; } > "$tmp"
    mv -f "$tmp" "$csv_file"
  fi
}

# Initialize a CSV file and set the corresponding module variable.
_init_csv() {
  local project_dir="${1:-.}" filename="$2" header="$3"
  local state_dir="${project_dir}/.autopilot"
  if [[ ! -d "$state_dir" ]]; then return "$METRICS_ERROR"; fi
  local path="${state_dir}/${filename}"
  _auto_update_header "$path" "$header"
  echo "$path"
}

# Ensure metrics CSV exists. Sets _METRICS_FILE.
_init_metrics_file() {
  _METRICS_FILE="$(_init_csv "${1:-.}" "metrics.csv" "$_METRICS_HEADER")" || return "$METRICS_ERROR"
}

# Ensure phase timing CSV exists. Sets _PHASE_FILE.
_init_phase_file() {
  _PHASE_FILE="$(_init_csv "${1:-.}" "phase_timing.csv" "$_PHASE_HEADER")" || return "$METRICS_ERROR"
}

# Ensure token usage CSV exists. Sets _USAGE_FILE.
_init_usage_file() {
  _USAGE_FILE="$(_init_csv "${1:-.}" "token_usage.csv" "$_USAGE_HEADER")" || return "$METRICS_ERROR"
}

# --- Validation helpers ---

# Validate a value is a non-negative integer, default to 0.
_validate_int() {
  local val="$1"
  if [[ "$val" =~ ^[0-9]+$ ]]; then echo "$val"; else echo "0"; fi
}

# Validate a decimal value (digits, dots, optional leading minus).
_validate_decimal() {
  local val="$1"
  if [[ "$val" =~ ^-?[0-9]*\.?[0-9]+$ ]]; then echo "$val"; else echo "0"; fi
}

# Extract a numeric field from JSON, defaulting to 0.
_jq_field() {
  echo "$1" | jq -r ".$2 // 0" 2>/dev/null || echo "0"
}

# --- TIMER tags for sub-step instrumentation ---

# Log elapsed seconds since start_epoch with a TIMER label.
timer_log() {
  local project_dir="$1" label="$2" start_epoch="$3"
  local now_epoch
  now_epoch="$(date -u '+%s')"
  local elapsed=$(( now_epoch - start_epoch ))
  log_msg "$project_dir" "INFO" "TIMER: ${label} (${elapsed}s)"
}

# --- ISO 8601 epoch helpers ---

# Parse an ISO 8601 timestamp to epoch seconds (macOS + GNU compatible).
_parse_iso_epoch() {
  local ts="$1"
  if [[ -z "$ts" || "$ts" == "unknown" ]]; then return 1; fi
  # Try GNU date first (Linux), then BSD date (macOS)
  if date -d "$ts" '+%s' 2>/dev/null; then return 0
  elif date -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" '+%s' 2>/dev/null; then return 0; fi
  return 1
}

# Compute duration in minutes between two ISO 8601 timestamps.
_calc_duration_minutes() {
  local start="$1" end="$2"
  if [[ "$start" == "unknown" || -z "$start" ]]; then echo "0"; return; fi
  local start_epoch end_epoch
  start_epoch="$(_parse_iso_epoch "$start")" || { echo "0"; return; }
  end_epoch="$(_parse_iso_epoch "$end")" || { echo "0"; return; }
  local diff=$(( (end_epoch - start_epoch) / 60 ))
  if [[ "$diff" -lt 0 ]]; then diff=0; fi
  echo "$diff"
}

# --- Phase duration accumulation ---

# Add elapsed seconds in the current phase to phase_durations.<phase>.
_accumulate_phase_time() {
  local project_dir="$1" phase="$2" now="$3"
  local entered_at
  entered_at="$(read_state "$project_dir" "phase_entered_at")"
  if [[ -z "$entered_at" ]]; then return 0; fi

  local entered_epoch now_epoch elapsed_sec
  entered_epoch="$(_parse_iso_epoch "$entered_at")" || return 0
  now_epoch="$(_parse_iso_epoch "$now")" || return 0
  elapsed_sec=$(( now_epoch - entered_epoch ))
  if [[ "$elapsed_sec" -lt 0 ]]; then elapsed_sec=0; fi

  # shellcheck disable=SC2016
  _jq_transform_state "$project_dir" \
    --arg phase "$phase" --argjson secs "$elapsed_sec" \
    '.phase_durations = ((.phase_durations // {}) | .[$phase] = ((.[$phase] // 0) + $secs))'
}

# Reset phase durations and phase_entered_at for a new task.
reset_phase_durations() {
  local project_dir="${1:-.}"
  _jq_transform_state "$project_dir" 'del(.phase_durations) | del(.phase_entered_at)'
}

# Record a phase transition — accumulates time in old phase, resets entered_at.
record_phase_transition() {
  local project_dir="${1:-.}" old_phase="$2"
  local now
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  _accumulate_phase_time "$project_dir" "$old_phase" "$now"
  write_state "$project_dir" "phase_entered_at" "$now"
}

# --- Task start/end recording ---

# Write task_started_at and phase_entered_at timestamps into state JSON.
record_task_start() {
  local project_dir="${1:-.}" task_number="$2"
  local now
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  write_state "$project_dir" "task_started_at" "$now"
  write_state "$project_dir" "phase_entered_at" "$now"
  log_msg "$project_dir" "INFO" "METRICS: recorded start time for task ${task_number}"
}

# Fetch PR stats, compute duration, append one CSV row. Best-effort.
record_task_complete() {
  local project_dir="${1:-.}" task_number="$2" pr_number="$3" repo="$4"
  local status="${5:-merged}"
  _init_metrics_file "$project_dir" || return 0
  task_number="$(_validate_int "$task_number")"

  # Dedup guard — prevent double-recording
  if grep -q "^${task_number}," "$_METRICS_FILE" 2>/dev/null; then
    log_msg "$project_dir" "INFO" "METRICS: task ${task_number} already recorded — skipping"
    return 0
  fi

  local start_time end_time duration_minutes retry_count
  start_time="$(read_state "$project_dir" "task_started_at")"
  [[ -z "$start_time" ]] && start_time="unknown"
  end_time="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  duration_minutes="$(_calc_duration_minutes "$start_time" "$end_time")"
  retry_count="$(_validate_int "$(read_state "$project_dir" "retry_count")")"

  # Fetch PR stats (best-effort)
  local pr_stats lines_added lines_removed comment_count files_changed
  pr_stats="$(get_pr_stats "$pr_number" "$repo")"
  lines_added="$(_validate_int "$(_jq_field "$pr_stats" "additions")")"
  lines_removed="$(_validate_int "$(_jq_field "$pr_stats" "deletions")")"
  comment_count="$(_validate_int "$(_jq_field "$pr_stats" "comment_count")")"
  files_changed="$(_validate_int "$(_jq_field "$pr_stats" "changed_files")")"

  pr_number="$(_validate_int "$pr_number")"
  duration_minutes="$(_validate_int "$duration_minutes")"

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$task_number" "$status" "$pr_number" \
    "$start_time" "$end_time" "$duration_minutes" "$retry_count" \
    "$lines_added" "$lines_removed" "$comment_count" "$files_changed" \
    >> "$_METRICS_FILE"

  log_msg "$project_dir" "INFO" \
    "METRICS: recorded completion for task ${task_number} (PR #${pr_number}, ${duration_minutes}m)"
}

# --- PR stats ---

# Return JSON with additions, deletions, changed_files, comment_count.
get_pr_stats() {
  local pr_number="$1" repo="$2"
  local empty_stats='{"additions":0,"deletions":0,"changed_files":0,"comment_count":0}'
  if [[ -z "$pr_number" || -z "$repo" ]]; then echo "$empty_stats"; return; fi

  local gh_timeout="${AUTOPILOT_TIMEOUT_GH:-30}"
  local result
  result="$(timeout "$gh_timeout" gh pr view "$pr_number" --repo "$repo" \
    --json additions,deletions,changedFiles,comments \
    --jq '{additions: .additions, deletions: .deletions, changed_files: .changedFiles, comment_count: (.comments | length)}' \
    2>/dev/null)" || result="$empty_stats"
  echo "$result"
}

# --- Phase duration recording ---

# Write per-phase timing to phase_timing.csv. Called at task completion.
record_phase_durations() {
  local project_dir="${1:-.}" task_number="$2" pr_number="$3"
  _init_phase_file "$project_dir" || return 0
  task_number="$(_validate_int "$task_number")"
  if grep -q "^${task_number}," "$_PHASE_FILE" 2>/dev/null; then return 0; fi

  # Finalize: accumulate time in current phase before reading
  local current_status now
  current_status="$(read_state "$project_dir" "status")"
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  _accumulate_phase_time "$project_dir" "$current_status" "$now"

  # Read phase durations from state
  local state_file="${project_dir}/.autopilot/state.json"
  local durations
  durations="$(jq -r '.phase_durations // {}' "$state_file" 2>/dev/null)" || durations='{}'

  local impl_sec test_fix_sec pr_open_sec review_sec fix_sec merge_sec
  impl_sec="$(_validate_int "$(_jq_field "$durations" "implementing")")"
  test_fix_sec="$(_validate_int "$(_jq_field "$durations" "test_fixing")")"
  pr_open_sec="$(_validate_int "$(_jq_field "$durations" "pr_open")")"
  review_sec="$(_validate_int "$(_jq_field "$durations" "reviewed")")"
  fix_sec="$(_validate_int "$(_jq_field "$durations" "fixing")")"
  merge_sec="$(_validate_int "$(_jq_field "$durations" "merging")")"
  local total_sec=$(( impl_sec + test_fix_sec + pr_open_sec + review_sec + fix_sec + merge_sec ))
  pr_number="$(_validate_int "$pr_number")"

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$task_number" "$pr_number" \
    "$impl_sec" "$test_fix_sec" "$pr_open_sec" "$review_sec" \
    "$fix_sec" "$merge_sec" "$total_sec" \
    >> "$_PHASE_FILE"

  log_msg "$project_dir" "INFO" \
    "METRICS: phase timing task ${task_number} — impl=${impl_sec}s test_fix=${test_fix_sec}s pr_open=${pr_open_sec}s reviewed=${review_sec}s fixing=${fix_sec}s merging=${merge_sec}s total=${total_sec}s"
}

# --- Token usage recording ---

# Extract and validate all usage fields from a Claude agent output JSON file.
# Outputs pipe-separated: wall_ms|api_ms|turns|input|output|cache_read|cache_create|cost
_parse_agent_json() {
  local json_file="$1"
  if [[ ! -f "$json_file" ]]; then return 1; fi

  local wall_ms api_ms turns input_tokens output_tokens
  local cache_read cache_create cost
  wall_ms="$(jq -r '.duration_ms // 0' "$json_file" 2>/dev/null)" || wall_ms=0
  api_ms="$(jq -r '.duration_api_ms // 0' "$json_file" 2>/dev/null)" || api_ms=0
  turns="$(jq -r '.num_turns // 0' "$json_file" 2>/dev/null)" || turns=0
  input_tokens="$(jq -r '.usage.input_tokens // 0' "$json_file" 2>/dev/null)" || input_tokens=0
  output_tokens="$(jq -r '.usage.output_tokens // 0' "$json_file" 2>/dev/null)" || output_tokens=0
  cache_read="$(jq -r '.usage.cache_read_input_tokens // 0' "$json_file" 2>/dev/null)" || cache_read=0
  cache_create="$(jq -r '.usage.cache_creation_input_tokens // 0' "$json_file" 2>/dev/null)" || cache_create=0
  cost="$(jq -r '.total_cost_usd // 0' "$json_file" 2>/dev/null)" || cost=0

  wall_ms="$(_validate_int "$wall_ms")"
  api_ms="$(_validate_int "$api_ms")"
  turns="$(_validate_int "$turns")"
  input_tokens="$(_validate_int "$input_tokens")"
  output_tokens="$(_validate_int "$output_tokens")"
  cache_read="$(_validate_int "$cache_read")"
  cache_create="$(_validate_int "$cache_create")"
  cost="$(_validate_decimal "$cost")"

  echo "${wall_ms}|${api_ms}|${turns}|${input_tokens}|${output_tokens}|${cache_read}|${cache_create}|${cost}"
}

# Parse Claude JSON output and append token usage to CSV. Best-effort.
record_claude_usage() {
  local project_dir="${1:-.}" task_number="$2" phase="$3" json_file="$4"
  _init_usage_file "$project_dir" || return 0
  task_number="$(_validate_int "$task_number")"
  if [[ ! -f "$json_file" ]]; then
    log_msg "$project_dir" "INFO" "METRICS: no JSON output for task ${task_number} ${phase}"
    return 0
  fi

  local parsed
  parsed="$(_parse_agent_json "$json_file")" || {
    log_msg "$project_dir" "INFO" "METRICS: failed to parse JSON for task ${task_number} ${phase}"
    return 0
  }

  local wall_ms api_ms turns input_tokens output_tokens cache_read cache_create cost
  IFS='|' read -r wall_ms api_ms turns input_tokens output_tokens cache_read cache_create cost <<< "$parsed"

  _append_usage_row "$task_number" "$phase" \
    "$input_tokens" "$output_tokens" "$cache_read" "$cache_create" \
    "$cost" "$wall_ms" "$api_ms" "$turns"

  _log_usage "$project_dir" "$task_number" "$phase" \
    "$input_tokens" "$output_tokens" "$cache_read" "$cache_create" \
    "$cost" "$wall_ms" "$api_ms" "$turns"
}

# Append a row to the usage CSV.
_append_usage_row() {
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$@" >> "$_USAGE_FILE"
}

# Log token usage and timing summary.
_log_usage() {
  local project_dir="$1" task_number="$2" phase="$3"
  local input_tokens="$4" output_tokens="$5" cache_read="$6" cache_create="$7"
  local cost="$8" wall_ms="$9" api_ms="${10}" turns="${11}"
  local wall_s=$(( wall_ms / 1000 )) api_s=$(( api_ms / 1000 ))
  local tool_s=$(( (wall_ms - api_ms) / 1000 ))
  if [[ "$tool_s" -lt 0 ]]; then tool_s=0; fi
  log_msg "$project_dir" "INFO" \
    "METRICS: usage task ${task_number} ${phase} — in=${input_tokens} out=${output_tokens} cache_read=${cache_read} cost=\$${cost}"
  log_msg "$project_dir" "INFO" \
    "METRICS: timing task ${task_number} ${phase} — wall=${wall_s}s api=${api_s}s tools=${tool_s}s turns=${turns}"
}
