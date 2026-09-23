#!/usr/bin/env bash
# The gate stage list, in one place. `make gate` runs it under the gate lock in this tree;
# `make merge` runs it in the preview-merge worktree. Stages call the Makefile targets, so each
# command is written once. Cheapest first. One line per passing stage; on failure the last 30
# lines of that stage's log plus the full-log path are printed and the run stops. The exit code
# is the stage's real exit code, never parsed output.
#
# Usage: scripts/gate.sh [--docs-only]
#   --docs-only  run gate-wiring-check only. The merge path passes this for PRs that change only
#                README.md, CLAUDE.md or *.md under docs/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
[ -f "$ROOT/Makefile" ] && [ -f "$ROOT/lib/config.sh" ] || {
  echo "gate.sh: $ROOT is not the repo root (Makefile or lib/config.sh missing)" >&2
  exit 2
}

docs_only=0
[ "${1:-}" = "--docs-only" ] && docs_only=1

LOG_DIR="${GATE_LOG_DIR:-${TMPDIR:-/tmp}/autopilot-gate-logs/$(date +%Y%m%d-%H%M%S)-$$}"
mkdir -p "$LOG_DIR"

run_stage() {
  local name="$1"
  shift
  local log="$LOG_DIR/$name.log"
  local start rc
  start=$(date +%s)
  if "$@" >"$log" 2>&1; then
    echo "gate: ✓ $name ($(( $(date +%s) - start ))s)"
    return 0
  else
    rc=$?
    echo "gate: ✗ $name (exit $rc) — last 30 lines:" >&2
    tail -n 30 "$log" >&2
    echo "gate: full log: $log" >&2
    return "$rc"
  fi
}

stages="gate-wiring-check test-tooling check"
if [ "$docs_only" = 1 ]; then
  echo "gate: docs-only change; skipping test-tooling and check"
  stages="gate-wiring-check"
fi

for stage in $stages; do
  run_stage "$stage" make -C "$ROOT" -s "$stage"
done
echo "gate: all stages passed (logs: $LOG_DIR)"
