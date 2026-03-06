#!/usr/bin/env bash
# Remove autopilot crontab entries for a project.
# Usage: scripts/remove-crontab-entries.sh /path/to/project
#
# This script filters out crontab entries referencing the given project dir
# and replaces the crontab. If crontab writes hang (common on macOS when
# cron is busy), it creates a PAUSE file instead as a fallback.

set -euo pipefail

PROJECT_DIR="${1:-.}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
readonly PROJECT_DIR

echo "Removing crontab entries for: ${PROJECT_DIR}"

# Method 1: Try crontab replacement via pipe (with portable timeout).
FILTERED="$(crontab -l 2>/dev/null | grep -Fv "$PROJECT_DIR" || true)"
if ( echo "$FILTERED" | crontab - 2>/dev/null ) & CRONTAB_PID=$!; sleep 5; kill "$CRONTAB_PID" 2>/dev/null; then
  wait "$CRONTAB_PID" 2>/dev/null && {
    echo "Crontab entries removed successfully."
    exit 0
  }
fi

# Method 2: PAUSE file fallback.
echo "crontab write timed out — using PAUSE file fallback."
pause_count=0
for state_dir in ".autopilot" ".pr-pipeline"; do
  local_dir="${PROJECT_DIR}/${state_dir}"
  if [[ -d "$local_dir" ]]; then
    touch "${local_dir}/PAUSE"
    echo "  Created ${local_dir}/PAUSE"
    pause_count=$((pause_count + 1))
  fi
done

if [[ "$pause_count" -eq 0 ]]; then
  echo ""
  echo "Warning: No state directories found — no PAUSE files created."
  echo "Neither .autopilot/ nor .pr-pipeline/ exist in: ${PROJECT_DIR}"
  echo "To remove cron entries, edit the crontab manually:"
  echo "  EDITOR=nano crontab -e"
  echo "Remove lines containing: ${PROJECT_DIR}"
  exit 1
fi

echo ""
echo "Cron entries are now effectively disabled via PAUSE files."
echo "To fully remove them, edit the crontab manually:"
echo "  EDITOR=nano crontab -e"
echo "Remove lines containing: ${PROJECT_DIR}"
