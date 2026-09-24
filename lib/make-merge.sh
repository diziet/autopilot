#!/usr/bin/env bash
# The `make merge` path of Autopilot's merger.
# Detects a target repository's `make merge` rule and runs `make merge pr=N` in
# the task worktree. `make merge` runs the repository's gate on a preview merge
# of the PR into main, merges with a merge commit, then removes the worktree it
# ran in and deletes the local branch. It refuses a worktree with an untracked
# or modified file, so its output goes to the project dir's .autopilot/logs/.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_MAKE_MERGE_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_MAKE_MERGE_LOADED=1

# Source dependencies.
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"

# make_merge_pr returns this when the gate failed on the preview merge.
readonly MAKE_MERGE_GATE_FAILED=2

# Lines of `make merge` output copied into the fixer's diagnosis hints.
readonly _MAKE_MERGE_HINT_LINES=100

# Check whether dir's Makefile has a `merge` rule whose recipe runs scripts/merge.py.
# Blank and comment lines inside the recipe do not end it; `merge :=` is a variable.
has_make_merge_target() {
  local makefile="$1/Makefile"
  [[ -f "$makefile" ]] || return 1

  awk '
    /^merge[[:space:]]*:/ && !/^merge[[:space:]]*:?:?=/ { in_rule = 1; next }
    in_rule && /^\t/ { if (index($0, "scripts/merge.py")) found = 1; next }
    in_rule && /^[[:space:]]*(#.*)?$/ { next }
    { in_rule = 0 }
    END { exit found ? 0 : 1 }
  ' "$makefile"
}

# Print the path of the make merge output log for a task.
make_merge_log_path() {
  local project_dir="$1"
  local task_number="$2"
  echo "${project_dir}/.autopilot/logs/make-merge-task-${task_number}.log"
}

# Print the TMPDIR for make merge: TMPDIR, else the macOS per-user temp dir.
# launchd starts the dispatcher without TMPDIR. The target's gate lock is
# $TMPDIR/<repo>-gate.lock, so without this the daemon's `make merge` would lock
# /tmp/<repo>-gate.lock and not queue behind interactive gates.
_make_merge_tmpdir() {
  if [[ -n "${TMPDIR:-}" ]]; then
    echo "$TMPDIR"
    return 0
  fi
  getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true
}

# Run `make merge pr=N` in task_dir under timeout_merge, with stdin closed.
# Prints make's combined output; returns make's exit code (124 on timeout).
_run_make_merge() {
  local task_dir="$1"
  local pr_number="$2"
  local timeout_merge="$3"

  local tmp_dir
  tmp_dir="$(_make_merge_tmpdir)"
  (
    cd "$task_dir" || exit 1
    if [[ -n "$tmp_dir" ]]; then
      export TMPDIR="$tmp_dir"
    fi
    timeout "$timeout_merge" make merge "pr=${pr_number}" </dev/null
  ) 2>&1
}

# Print the reason make merge failed: scripts/merge.py's refusal line, else the
# last non-empty output line.
_make_merge_reason() {
  local log_file="$1"
  local reason
  reason="$(grep -F "merge: refused" "$log_file" 2>/dev/null | tail -1)" || true
  if [[ -z "$reason" ]]; then
    reason="$(grep -v '^[[:space:]]*$' "$log_file" 2>/dev/null | tail -1)" || true
  fi
  echo "${reason:-no output}"
}

# Log why make merge failed. Returns MAKE_MERGE_GATE_FAILED for a gate failure
# on the preview merge and 1 for any other failure.
# The exit code already said the PR did not merge; the refusal text only picks
# the path. scripts/merge.py words a gate failure "refused (closed): gate failed".
_report_make_merge_failure() {
  local project_dir="$1"
  local pr_number="$2"
  local exit_code="$3"
  local log_file="$4"

  local reason
  if [[ "$exit_code" -eq 124 ]]; then
    reason="timed out after ${AUTOPILOT_TIMEOUT_MERGE:-1800}s"
  else
    reason="$(_make_merge_reason "$log_file")"
  fi

  if [[ "$reason" == *"refused (closed): gate failed"* ]]; then
    log_msg "$project_dir" "WARNING" \
      "make merge gate failed on the preview merge of PR #${pr_number}: ${reason} (output: ${log_file})"
    return "$MAKE_MERGE_GATE_FAILED"
  fi

  log_msg "$project_dir" "ERROR" \
    "make merge did not merge PR #${pr_number} (exit=${exit_code}): ${reason} (output: ${log_file})"
  return 1
}

# Run `make merge pr=N` in task_dir. Returns 0 when make exits 0,
# MAKE_MERGE_GATE_FAILED when the gate failed on the preview merge, 1 otherwise.
make_merge_pr() {
  local project_dir="$1"
  local task_number="$2"
  local pr_number="$3"
  local task_dir="$4"
  local timeout_merge="${AUTOPILOT_TIMEOUT_MERGE:-1800}"

  if [[ ! -d "$task_dir" ]]; then
    log_msg "$project_dir" "ERROR" \
      "Cannot run make merge for PR #${pr_number}: task directory ${task_dir} does not exist"
    return 1
  fi

  local log_file
  log_file="$(make_merge_log_path "$project_dir" "$task_number")"
  mkdir -p "${log_file%/*}"

  log_msg "$project_dir" "INFO" \
    "Running make merge pr=${pr_number} in ${task_dir} (timeout=${timeout_merge}s, output: ${log_file})"

  local exit_code=0
  _run_make_merge "$task_dir" "$pr_number" "$timeout_merge" \
    > "$log_file" || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    log_msg "$project_dir" "INFO" "make merge merged PR #${pr_number}"
    return 0
  fi

  _report_make_merge_failure "$project_dir" "$pr_number" "$exit_code" "$log_file"
}

# Print diagnosis hints for the fixer after the make merge gate failed: what
# happened, and the last _MAKE_MERGE_HINT_LINES lines of make merge output.
build_make_merge_gate_hints() {
  local project_dir="$1"
  local task_number="$2"
  local pr_number="$3"

  local log_file
  log_file="$(make_merge_log_path "$project_dir" "$task_number")"

  cat <<EOF
## make merge gate failed

The merger approved this PR, then \`make merge pr=${pr_number}\` ran the repository's gate on a preview merge of the PR into main. The gate failed, so the PR was not merged. Fix the failure on the task branch and push.

Last ${_MAKE_MERGE_HINT_LINES} lines of the \`make merge\` output (full output: ${log_file}):

\`\`\`
$(tail -n "$_MAKE_MERGE_HINT_LINES" "$log_file" 2>/dev/null)
\`\`\`
EOF
}
