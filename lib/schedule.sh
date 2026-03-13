#!/usr/bin/env bash
# Schedule management: list installed agents and clean up stale plists.
# Sourced by bin/autopilot-schedule.

# Guard against double-sourcing.
[[ -n "${_AUTOPILOT_SCHEDULE_LOADED:-}" ]] && return 0
readonly _AUTOPILOT_SCHEDULE_LOADED=1

# Extract a value following a <key> tag from a plist, matching the given element type.
_extract_plist_element() {
  local plist_file="$1" key="$2" element="$3"
  sed -n "/<key>${key}<\\/key>/{ n; s/.*<${element}>\\(.*\\)<\\/${element}>.*/\\1/p; }" \
    "$plist_file"
}

# Extract a string value following a <key> tag from a plist file.
_extract_plist_value() { _extract_plist_element "$1" "$2" "string"; }

# Extract an integer value following a <key> tag from a plist file.
_extract_plist_integer() { _extract_plist_element "$1" "$2" "integer"; }

# Find all autopilot plist files in LaunchAgents.
_find_all_autopilot_plists() {
  local launch_agents_dir="${HOME}/Library/LaunchAgents"
  [[ ! -d "$launch_agents_dir" ]] && return 0

  local plist_file
  for plist_file in "$launch_agents_dir"/com.autopilot.*.plist; do
    [[ -f "$plist_file" ]] && echo "$plist_file" || true
  done
}

# Find autopilot plists whose WorkingDirectory matches the given project dir.
_find_plists_for_project() {
  local project_dir="$1"
  local plist_file working_dir

  while IFS= read -r plist_file; do
    [[ -z "$plist_file" ]] && continue
    working_dir="$(_extract_plist_value "$plist_file" "WorkingDirectory")"
    if [[ "$working_dir" == "$project_dir" ]]; then
      echo "$plist_file"
    fi
  done < <(_find_all_autopilot_plists)
}

# Extract account number from a plist label (com.autopilot.ROLE.ACCOUNT).
_extract_account_from_label() {
  local label="$1"
  echo "${label##*.}"
}

# Extract role from a plist label (com.autopilot.ROLE.ACCOUNT).
_extract_role_from_label() {
  local label="$1"
  local without_prefix="${label#com.autopilot.}"
  echo "${without_prefix%.*}"
}

# Get launchd agent status: "running (PID N)" or "stopped".
_get_agent_status() {
  local label="$1"
  local pid
  # Use no-arg launchctl list (tabular: PID Status Label) and grep for label.
  pid="$(launchctl list 2>/dev/null | awk -v lbl="$label" '$3 == lbl { print $1 }')" || true
  if [[ -n "$pid" && "$pid" != "-" && "$pid" != "0" ]]; then
    echo "running (PID ${pid})"
  else
    echo "stopped"
  fi
}

# List all installed autopilot launchd agents with details.
list_agents() {
  local plists
  plists="$(_find_all_autopilot_plists)"

  if [[ -z "$plists" ]]; then
    echo "No autopilot launchd agents installed."
    return 0
  fi

  local plist_file label role account project_dir config_dir interval status
  while IFS= read -r plist_file; do
    [[ -z "$plist_file" ]] && continue
    label="$(_extract_plist_value "$plist_file" "Label")"
    role="$(_extract_role_from_label "$label")"
    account="$(_extract_account_from_label "$label")"
    project_dir="$(_extract_plist_value "$plist_file" "WorkingDirectory")"
    config_dir="$(_extract_plist_value "$plist_file" "CLAUDE_CONFIG_DIR")"
    interval="$(_extract_plist_integer "$plist_file" "StartInterval")"
    status="$(_get_agent_status "$label")"

    echo "Agent: ${label}"
    echo "  Role:             ${role}"
    echo "  Project:          ${project_dir}"
    echo "  Account:          ${account}"
    echo "  CLAUDE_CONFIG_DIR: ${config_dir:-(not set)}"
    echo "  Interval:         ${interval}s"
    echo "  Status:           ${status}"
    echo ""
  done <<< "$plists"
}

# Remove existing autopilot agents for a project before installing new ones.
# This prevents stale agents when switching accounts.
cleanup_stale_agents() {
  local project_dir="$1"
  local dispatcher_account="$2"
  local reviewer_account="$3"
  local plist_file label role account

  while IFS= read -r plist_file; do
    [[ -z "$plist_file" ]] && continue
    label="$(_extract_plist_value "$plist_file" "Label")"
    role="$(_extract_role_from_label "$label")"
    account="$(_extract_account_from_label "$label")"

    # Skip if this plist matches what we're about to install.
    if [[ "$role" == "dispatcher" && "$account" == "$dispatcher_account" ]]; then
      continue
    fi
    if [[ "$role" == "reviewer" && "$account" == "$reviewer_account" ]]; then
      continue
    fi

    # Stale agent — unload and remove.
    launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
    rm -f "$plist_file"
    echo "  Removed stale agent: ${label}"
  done < <(_find_plists_for_project "$project_dir")
}
