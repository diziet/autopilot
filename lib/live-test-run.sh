#!/usr/bin/env bash
# Live test orchestration for Autopilot.
# Manages the full lifecycle: scaffold, run autopilot loop, collect results.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_LIVE_TEST_RUN_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_LIVE_TEST_RUN_LOADED=1

# Resolve lib dir once using parameter expansion (avoids 8 subshell spawns).
_LIVE_TEST_RUN_DIR="${BASH_SOURCE[0]%/*}"

# shellcheck source=lib/live-test.sh
source "${_LIVE_TEST_RUN_DIR}/live-test.sh"

# shellcheck source=lib/entry-common.sh
source "${_LIVE_TEST_RUN_DIR}/entry-common.sh"

# shellcheck source=lib/live-test-status.sh
source "${_LIVE_TEST_RUN_DIR}/live-test-status.sh"

# shellcheck source=lib/live-test-report.sh
source "${_LIVE_TEST_RUN_DIR}/live-test-report.sh"

# Global timeout for the entire live test run (seconds).
readonly LIVE_TEST_TIMEOUT_SECONDS=3600

# Cadence between dispatch/review cycles (seconds).
readonly LIVE_TEST_TICK_INTERVAL=15

# Max consecutive tick failures before aborting the loop.
readonly _LIVE_TEST_MAX_CONSECUTIVE_FAILURES=10

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

  mkdir -p "$repo_dir"
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

  if [[ -z "${LIVE_TEST_GITHUB_ORG:-}" ]]; then
    echo "Error: LIVE_TEST_GITHUB_ORG is not set" >&2
    return 1
  fi

  local repo_name="autopilot-live-test"
  local full_name="${LIVE_TEST_GITHUB_ORG}/${repo_name}"

  # Create repo if it doesn't exist.
  if ! gh repo view "$full_name" >/dev/null 2>&1; then
    gh repo create "$full_name" --private --confirm >/dev/null 2>&1 || true
  fi

  (
    cd "$repo_dir" || return 1
    # Duplicate remote is expected on reruns.
    git remote add origin "https://github.com/${full_name}.git" 2>/dev/null || true
    if ! git push -u origin main -q 2>&1; then
      echo "Error: failed to push to ${full_name}" >&2
      return 1
    fi
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
    return 1
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

  # Write exit code to file before exiting — avoids fragile trap variable expansion.
  local exit_code_file="${run_dir}/exit_code"
  trap '_on_loop_exit '"$run_dir"' '"$repo_dir"' '"$flag_keep"'' EXIT

  local consecutive_failures=0

  while true; do
    local now
    now="$(date +%s)"

    # Check global timeout.
    if [[ "$now" -ge "$end_time" ]]; then
      echo "TIMEOUT: live test exceeded ${LIVE_TEST_TIMEOUT_SECONDS}s"
      echo 2 > "$exit_code_file"
      exit 2
    fi

    # Run one dispatch tick, tracking consecutive failures.
    local tick_failed=0
    if ! "$dispatch_cmd" "$repo_dir"; then
      tick_failed=1
    fi

    # Run one review tick.
    if ! "$review_cmd" "$repo_dir"; then
      tick_failed=1
    fi

    if [[ "$tick_failed" -eq 1 ]]; then
      consecutive_failures=$((consecutive_failures + 1))
      if [[ "$consecutive_failures" -ge "$_LIVE_TEST_MAX_CONSECUTIVE_FAILURES" ]]; then
        echo "ABORT: ${consecutive_failures} consecutive tick failures"
        echo 3 > "$exit_code_file"
        exit 3
      fi
    else
      consecutive_failures=0
    fi

    # Check if all tasks have reached merged status.
    if _all_tasks_completed "$repo_dir"; then
      echo "All tasks completed successfully."
      echo 0 > "$exit_code_file"
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

  # If exit_code was not written by the loop, capture the exit status.
  local trap_exit_code=$?
  if [[ ! -f "${run_dir}/exit_code" ]]; then
    echo "$trap_exit_code" > "${run_dir}/exit_code"
  fi

  local exit_code
  exit_code="$(cat "${run_dir}/exit_code")"

  # Validate results and generate report.
  validate_live_test "$run_dir" "$repo_dir" "$exit_code" || true

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
  merged_count="$(awk -F, '$2 == "merged"' "$metrics_file" | wc -l | tr -d ' ')"

  [[ "$merged_count" -ge "$total_tasks" ]]
}

# Count the number of tasks in the tasks file.
_count_tasks() {
  local repo_dir="$1"
  local tasks_file="${repo_dir}/tasks.md"

  if [[ ! -f "$tasks_file" ]]; then
    echo 0
    return 0
  fi

  local count
  count="$(grep -c '^## Task [0-9]' "$tasks_file" 2>/dev/null)" || true
  echo "${count:-0}"
}

# Copy files from source_dir to dest_dir if they exist.
_copy_if_exists() {
  local src_dir="$1" dest_dir="$2"
  shift 2
  local f
  for f in "$@"; do
    if [[ -f "${src_dir}/${f}" ]]; then
      cp "${src_dir}/${f}" "$dest_dir/"
    fi
  done
}

# Copy key artifacts to the latest/ directory for post-cleanup access.
_copy_artifacts() {
  local run_dir="$1"
  local repo_dir="$2"
  local latest_dir="${LIVE_TEST_BASE_DIR}/latest"

  mkdir -p "$latest_dir"

  _copy_if_exists "$run_dir" "$latest_dir" \
    exit_code output.log pid start_time timestamp flags \
    report.md summary.txt
  _copy_if_exists "${repo_dir}/.autopilot" "$latest_dir" \
    metrics.csv token_usage.csv phase_timing.csv
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
