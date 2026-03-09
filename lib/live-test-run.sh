#!/usr/bin/env bash
# Live test orchestration for Autopilot.
# Manages the full lifecycle: scaffold, run autopilot loop, collect results.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_LIVE_TEST_RUN_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_LIVE_TEST_RUN_LOADED=1

# shellcheck source=lib/live-test.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/live-test.sh"

# shellcheck source=lib/entry-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/entry-common.sh"

# Global timeout for the entire live test run (seconds).
readonly LIVE_TEST_TIMEOUT_SECONDS=3600

# Cadence between dispatch/review cycles (seconds).
readonly LIVE_TEST_TICK_INTERVAL=15

# Base directory for all live test artifacts (overridable for testing).
LIVE_TEST_BASE_DIR="${LIVE_TEST_BASE_DIR:-.autopilot/live-test}"
readonly LIVE_TEST_BASE_DIR

# Run a full live test: scaffold, configure, launch background loop.
run_live_test() {
  local flag_github="$1"
  local flag_keep="$2"
  local lib_dir="$3"

  local timestamp
  timestamp="$(date +%Y%m%d-%H%M%S)"
  local run_dir="${LIVE_TEST_BASE_DIR}/run-${timestamp}"
  local repo_dir="${run_dir}/repo"

  _create_run_dir "$run_dir" "$repo_dir"
  _init_test_repo "$repo_dir"
  _write_test_config "$repo_dir" "$lib_dir" "$flag_github" "$timestamp"

  if [[ "$flag_github" -eq 1 ]]; then
    _setup_github_remote "$repo_dir" "$timestamp"
  fi

  # Save flags for cleanup/status.
  echo "github=${flag_github}" > "${run_dir}/flags"
  echo "keep=${flag_keep}" >> "${run_dir}/flags"
  echo "$timestamp" > "${run_dir}/timestamp"

  # Symlink current -> this run.
  ln -sfn "$(cd "$run_dir" && pwd)" "${LIVE_TEST_BASE_DIR}/current"

  _start_background "$run_dir" "$repo_dir" "$lib_dir" "$flag_keep"
}

# Create the run directory structure.
_create_run_dir() {
  local run_dir="$1"
  local repo_dir="$2"
  mkdir -p "$repo_dir"
  mkdir -p "${LIVE_TEST_BASE_DIR}/latest"
}

# Scaffold the test repo, git init, and make initial commit.
_init_test_repo() {
  local repo_dir="$1"
  scaffold_test_repo "$repo_dir"

  (
    cd "$repo_dir" || return 1
    git init -q
    git add -A
    git commit -q -m "chore: initial scaffold for live test"
  )
}

# Copy autopilot.conf and override settings for the test run.
_write_test_config() {
  local repo_dir="$1"
  local lib_dir="$2"
  local flag_github="$3"
  local timestamp="$4"

  local example_conf="${lib_dir}/../examples/live-test-autopilot.conf"
  local tasks_file="${lib_dir}/../examples/live-test-tasks.md"

  cp "$example_conf" "${repo_dir}/autopilot.conf"
  cp "$tasks_file" "${repo_dir}/tasks.md"

  # Point to the embedded tasks file.
  echo "AUTOPILOT_TASKS_FILE=tasks.md" >> "${repo_dir}/autopilot.conf"

  # Disable worktrees for simpler local-only test runs.
  echo "AUTOPILOT_USE_WORKTREES=false" >> "${repo_dir}/autopilot.conf"

  if [[ "$flag_github" -eq 1 ]]; then
    local branch_prefix="live-${timestamp}"
    echo "AUTOPILOT_BRANCH_PREFIX=${branch_prefix}" >> "${repo_dir}/autopilot.conf"
    echo "AUTOPILOT_TARGET_BRANCH=main" >> "${repo_dir}/autopilot.conf"
  fi
}

# Create GitHub remote repo if needed and push initial commit.
_setup_github_remote() {
  local repo_dir="$1"
  local timestamp="$2"
  local repo_name="autopilot-live-test"
  local full_name="${LIVE_TEST_GITHUB_ORG}/${repo_name}"

  # Create repo if it doesn't exist.
  if ! gh repo view "$full_name" >/dev/null 2>&1; then
    gh repo create "$full_name" --private --confirm >/dev/null 2>&1 || true
  fi

  (
    cd "$repo_dir" || return 1
    git remote add origin "https://github.com/${full_name}.git" 2>/dev/null || true
    git push -u origin main -q 2>/dev/null || true
  )
}

# Fork the live test loop into the background.
_start_background() {
  local run_dir="$1"
  local repo_dir="$2"
  local lib_dir="$3"
  local flag_keep="$4"

  local dispatch_cmd review_cmd
  dispatch_cmd="$(find_sibling_binary "autopilot-dispatch" "$lib_dir")"
  review_cmd="$(find_sibling_binary "autopilot-review" "$lib_dir")"

  if [[ -z "$dispatch_cmd" ]] || [[ -z "$review_cmd" ]]; then
    echo "Error: cannot find autopilot-dispatch or autopilot-review" >&2
    exit 1
  fi

  # Record start time.
  date +%s > "${run_dir}/start_time"

  # Launch the loop in the background.
  _live_test_loop "$run_dir" "$repo_dir" "$dispatch_cmd" "$review_cmd" \
    "$flag_keep" >> "${run_dir}/output.log" 2>&1 &

  local bg_pid=$!
  echo "$bg_pid" > "${run_dir}/pid"

  echo "Live test started (PID ${bg_pid}). Run \`autopilot live-test status\` to check progress."
}

# Background loop: runs dispatch and review on the test repo.
_live_test_loop() {
  local run_dir="$1"
  local repo_dir="$2"
  local dispatch_cmd="$3"
  local review_cmd="$4"
  local flag_keep="$5"

  local start_time end_time
  start_time="$(date +%s)"
  end_time=$((start_time + LIVE_TEST_TIMEOUT_SECONDS))

  local exit_code=0
  trap '_on_loop_exit '"$run_dir"' '"$repo_dir"' '"$flag_keep"' "$exit_code"' EXIT

  while true; do
    local now
    now="$(date +%s)"

    # Check global timeout.
    if [[ "$now" -ge "$end_time" ]]; then
      echo "TIMEOUT: live test exceeded ${LIVE_TEST_TIMEOUT_SECONDS}s"
      exit_code=2
      exit 2
    fi

    # Run one dispatch tick.
    "$dispatch_cmd" "$repo_dir" || true

    # Run one review tick.
    "$review_cmd" "$repo_dir" || true

    # Check if all tasks have reached merged status.
    if _all_tasks_completed "$repo_dir"; then
      echo "All tasks completed successfully."
      exit_code=0
      exit 0
    fi

    sleep "$LIVE_TEST_TICK_INTERVAL"
  done
}

# Cleanup handler for the background loop.
_on_loop_exit() {
  local run_dir="$1"
  local repo_dir="$2"
  local flag_keep="$3"
  local code="${4:-$?}"

  echo "$code" > "${run_dir}/exit_code"
  _copy_artifacts "$run_dir" "$repo_dir"

  if [[ "$flag_keep" -ne 1 ]]; then
    # Remove the repo but keep the run metadata.
    rm -rf "$repo_dir"
  fi
}

# Check if all tasks in the tasks file have reached merged status in metrics.csv.
_all_tasks_completed() {
  local repo_dir="$1"
  local metrics_file="${repo_dir}/.autopilot/metrics.csv"

  [[ -f "$metrics_file" ]] || return 1

  local total_tasks merged_count
  total_tasks="$(_count_tasks "$repo_dir")"
  merged_count="$(grep -c ',merged,' "$metrics_file" 2>/dev/null || echo 0)"

  [[ "$merged_count" -ge "$total_tasks" ]]
}

# Count the number of tasks in the tasks file.
_count_tasks() {
  local repo_dir="$1"
  local tasks_file="${repo_dir}/tasks.md"

  if [[ -f "$tasks_file" ]]; then
    grep -c '^## Task [0-9]' "$tasks_file" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

# Copy key artifacts to the latest/ directory for post-cleanup access.
_copy_artifacts() {
  local run_dir="$1"
  local repo_dir="$2"
  local latest_dir="${LIVE_TEST_BASE_DIR}/latest"

  mkdir -p "$latest_dir"

  # Copy run metadata.
  local f
  for f in exit_code output.log pid start_time timestamp flags; do
    if [[ -f "${run_dir}/${f}" ]]; then
      cp "${run_dir}/${f}" "$latest_dir/"
    fi
  done

  # Copy report files from the test repo if they exist.
  for f in report.md summary.txt; do
    if [[ -f "${repo_dir}/.autopilot/${f}" ]]; then
      cp "${repo_dir}/.autopilot/${f}" "$latest_dir/"
    fi
  done

  # Copy metrics files.
  for f in metrics.csv token_usage.csv phase_timing.csv; do
    if [[ -f "${repo_dir}/.autopilot/${f}" ]]; then
      cp "${repo_dir}/.autopilot/${f}" "$latest_dir/"
    fi
  done
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

  # Task progress from metrics.csv.
  _show_task_progress "$status_dir"

  # Cost estimate from token_usage.csv.
  _show_cost_estimate "$status_dir"
}

# Show task completion progress.
_show_task_progress() {
  local status_dir="$1"
  local metrics_file

  # Check repo dir first, then latest artifacts.
  if [[ -d "${status_dir}/repo" ]]; then
    metrics_file="${status_dir}/repo/.autopilot/metrics.csv"
  else
    metrics_file="${status_dir}/metrics.csv"
  fi

  [[ -f "$metrics_file" ]] || return 0

  local merged total
  merged="$(grep -c ',merged,' "$metrics_file" 2>/dev/null || echo 0)"
  total="$(tail -n +2 "$metrics_file" | wc -l | tr -d ' ')"

  echo "Tasks: ${merged} merged, ${total} total"
}

# Show estimated cost from token_usage.csv.
_show_cost_estimate() {
  local status_dir="$1"
  local usage_file

  if [[ -d "${status_dir}/repo" ]]; then
    usage_file="${status_dir}/repo/.autopilot/token_usage.csv"
  else
    usage_file="${status_dir}/token_usage.csv"
  fi

  [[ -f "$usage_file" ]] || return 0

  # Sum cost_usd column (column 7).
  local total_cost
  total_cost="$(tail -n +2 "$usage_file" | awk -F, '{sum += $7} END {printf "%.4f", sum}')"
  echo "Estimated cost: \$${total_cost}"
}

# Remove all live test artifacts.
live_test_clean() {
  if [[ ! -d "$LIVE_TEST_BASE_DIR" ]]; then
    echo "No live test artifacts to clean."
    return 0
  fi

  # Kill running process if any.
  local pid_file="${LIVE_TEST_BASE_DIR}/current/pid"
  if [[ -f "$pid_file" ]]; then
    local pid
    pid="$(cat "$pid_file")"
    if ps -p "$pid" >/dev/null 2>&1; then
      echo "Stopping running live test (PID ${pid})..."
      kill "$pid" 2>/dev/null || true
    fi
  fi

  rm -rf "$LIVE_TEST_BASE_DIR"
  echo "Live test artifacts removed."
}
