#!/usr/bin/env bash
# Dispatcher state machine for Autopilot.
# Drives tasks through: pending → implementing → test_fixing → pr_open →
# reviewed → fixing → fixed → merging → merged → completed.
# Called by bin/autopilot-dispatch after quick guards pass.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_DISPATCHER_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_DISPATCHER_LOADED=1

# Source all required modules.
# shellcheck source=lib/config.sh
source "${BASH_SOURCE[0]%/*}/config.sh"
# shellcheck source=lib/state.sh
source "${BASH_SOURCE[0]%/*}/state.sh"
# shellcheck source=lib/tasks.sh
source "${BASH_SOURCE[0]%/*}/tasks.sh"
# shellcheck source=lib/preflight.sh
source "${BASH_SOURCE[0]%/*}/preflight.sh"
# shellcheck source=lib/git-ops.sh
source "${BASH_SOURCE[0]%/*}/git-ops.sh"
# shellcheck source=lib/coder.sh
source "${BASH_SOURCE[0]%/*}/coder.sh"
# shellcheck source=lib/fixer.sh
source "${BASH_SOURCE[0]%/*}/fixer.sh"
# shellcheck source=lib/merger.sh
source "${BASH_SOURCE[0]%/*}/merger.sh"
# shellcheck source=lib/testgate.sh
source "${BASH_SOURCE[0]%/*}/testgate.sh"
# shellcheck source=lib/postfix.sh
source "${BASH_SOURCE[0]%/*}/postfix.sh"
# shellcheck source=lib/context.sh
source "${BASH_SOURCE[0]%/*}/context.sh"
# shellcheck source=lib/metrics.sh
source "${BASH_SOURCE[0]%/*}/metrics.sh"
# shellcheck source=lib/diagnose.sh
source "${BASH_SOURCE[0]%/*}/diagnose.sh"
# shellcheck source=lib/spec-review.sh
source "${BASH_SOURCE[0]%/*}/spec-review.sh"
# shellcheck source=lib/reviewer-posting.sh
source "${BASH_SOURCE[0]%/*}/reviewer-posting.sh"
# shellcheck source=lib/rebase.sh
source "${BASH_SOURCE[0]%/*}/rebase.sh"
# shellcheck source=lib/dispatch-handlers.sh
source "${BASH_SOURCE[0]%/*}/dispatch-handlers.sh"

# --- Main Dispatch Tick ---

# Run one tick of the dispatcher state machine.
dispatch_tick() {
  local project_dir="${1:-.}"

  # Check for completion of any background spec review from a previous tick.
  check_spec_review_completion "$project_dir" || true

  local status
  status="$(read_state "$project_dir" "status")"

  case "$status" in
    pending)       _handle_pending "$project_dir" ;;
    implementing)  _handle_implementing "$project_dir" ;;
    test_fixing)   _handle_test_fixing "$project_dir" ;;
    pr_open)       _handle_pr_open "$project_dir" ;;
    reviewed)      _handle_reviewed "$project_dir" ;;
    fixing)        _handle_fixing "$project_dir" ;;
    fixed)         _handle_fixed "$project_dir" ;;
    merging)       _handle_merging "$project_dir" ;;
    merged)        _handle_merged "$project_dir" ;;
    completed)     _handle_completed "$project_dir" ;;
    *)
      log_msg "$project_dir" "ERROR" "Unknown state: ${status}"
      return 1
      ;;
  esac
}
