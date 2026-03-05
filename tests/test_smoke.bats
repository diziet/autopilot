#!/usr/bin/env bats
# Smoke test — source all lib/*.sh files in a subshell.
# Verifies no syntax errors, no variable conflicts, no function name collisions.

# Directory containing lib/ modules.
LIB_DIR="$BATS_TEST_DIRNAME/../lib"

setup() {
  # Unset all AUTOPILOT_* env vars for a clean slate.
  while IFS= read -r var; do
    unset "$var"
  done < <(env | grep '^AUTOPILOT_' | cut -d= -f1)

  # Unset all load guards so each test starts fresh.
  unset _AUTOPILOT_STATE_LOADED
  unset _AUTOPILOT_TASKS_LOADED
  unset _AUTOPILOT_PREFLIGHT_LOADED
  unset _AUTOPILOT_HOOKS_LOADED
  unset _AUTOPILOT_TESTGATE_LOADED
  unset _AUTOPILOT_SESSION_CACHE_LOADED
  unset _AUTOPILOT_GIT_OPS_LOADED
  unset _AUTOPILOT_REVIEWER_LOADED
  unset _AUTOPILOT_REVIEWER_POSTING_LOADED
  unset _AUTOPILOT_CLAUDE_LOADED
  unset _AUTOPILOT_CODER_LOADED
  unset _AUTOPILOT_FIXER_LOADED
  unset _AUTOPILOT_POSTFIX_LOADED
  unset _AUTOPILOT_MERGER_LOADED
}

# --- Individual file syntax checks ---

@test "syntax: config.sh has no syntax errors" {
  bash -n "$LIB_DIR/config.sh"
}

@test "syntax: state.sh has no syntax errors" {
  bash -n "$LIB_DIR/state.sh"
}

@test "syntax: tasks.sh has no syntax errors" {
  bash -n "$LIB_DIR/tasks.sh"
}

@test "syntax: claude.sh has no syntax errors" {
  bash -n "$LIB_DIR/claude.sh"
}

@test "syntax: preflight.sh has no syntax errors" {
  bash -n "$LIB_DIR/preflight.sh"
}

@test "syntax: hooks.sh has no syntax errors" {
  bash -n "$LIB_DIR/hooks.sh"
}

@test "syntax: testgate.sh has no syntax errors" {
  bash -n "$LIB_DIR/testgate.sh"
}

@test "syntax: session-cache.sh has no syntax errors" {
  bash -n "$LIB_DIR/session-cache.sh"
}

@test "syntax: git-ops.sh has no syntax errors" {
  bash -n "$LIB_DIR/git-ops.sh"
}

@test "syntax: coder.sh has no syntax errors" {
  bash -n "$LIB_DIR/coder.sh"
}

@test "syntax: fixer.sh has no syntax errors" {
  bash -n "$LIB_DIR/fixer.sh"
}

@test "syntax: reviewer.sh has no syntax errors" {
  bash -n "$LIB_DIR/reviewer.sh"
}

@test "syntax: reviewer-posting.sh has no syntax errors" {
  bash -n "$LIB_DIR/reviewer-posting.sh"
}

@test "syntax: postfix.sh has no syntax errors" {
  bash -n "$LIB_DIR/postfix.sh"
}

@test "syntax: merger.sh has no syntax errors" {
  bash -n "$LIB_DIR/merger.sh"
}

@test "syntax: all lib/*.sh files pass bash -n" {
  local file
  for file in "$LIB_DIR"/*.sh; do
    run bash -n "$file"
    [ "$status" -eq 0 ] || {
      echo "Syntax error in $(basename "$file"): $output" >&2
      return 1
    }
  done
}

# --- Source each module individually in a subshell ---

@test "source: config.sh loads without error" {
  (source "$LIB_DIR/config.sh")
}

@test "source: state.sh loads without error" {
  (source "$LIB_DIR/state.sh")
}

@test "source: tasks.sh loads without error" {
  (source "$LIB_DIR/tasks.sh")
}

@test "source: claude.sh loads without error" {
  (source "$LIB_DIR/claude.sh")
}

@test "source: preflight.sh loads without error" {
  (source "$LIB_DIR/preflight.sh")
}

@test "source: hooks.sh loads without error" {
  (source "$LIB_DIR/hooks.sh")
}

@test "source: testgate.sh loads without error" {
  (source "$LIB_DIR/testgate.sh")
}

@test "source: session-cache.sh loads without error" {
  (source "$LIB_DIR/session-cache.sh")
}

@test "source: git-ops.sh loads without error" {
  (source "$LIB_DIR/git-ops.sh")
}

@test "source: coder.sh loads without error" {
  (source "$LIB_DIR/coder.sh")
}

@test "source: fixer.sh loads without error" {
  (source "$LIB_DIR/fixer.sh")
}

@test "source: reviewer.sh loads without error" {
  (source "$LIB_DIR/reviewer.sh")
}

@test "source: reviewer-posting.sh loads without error" {
  (source "$LIB_DIR/reviewer-posting.sh")
}

@test "source: postfix.sh loads without error" {
  (source "$LIB_DIR/postfix.sh")
}

@test "source: merger.sh loads without error" {
  (source "$LIB_DIR/merger.sh")
}

# --- Source ALL lib files together in one subshell ---

@test "source: all lib/*.sh files load together without error" {
  (
    for file in "$LIB_DIR"/*.sh; do
      source "$file"
    done
  )
}

@test "source: all lib/*.sh files load in reverse order without error" {
  local files=()
  for file in "$LIB_DIR"/*.sh; do
    files+=("$file")
  done
  (
    local i
    for (( i=${#files[@]}-1; i>=0; i-- )); do
      source "${files[$i]}"
    done
  )
}

# --- Load guard verification ---

@test "guards: every lib file except config.sh has a load guard" {
  local file missing=()
  for file in "$LIB_DIR"/*.sh; do
    local basename
    basename="$(basename "$file")"
    # config.sh is allowed to not have a guard
    [[ "$basename" == "config.sh" ]] && continue
    if ! grep -q '_AUTOPILOT_.*_LOADED.*return' "$file"; then
      missing+=("$basename")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Files missing load guards: ${missing[*]}" >&2
    return 1
  fi
}

@test "guards: load guards prevent double-sourcing side effects" {
  (
    source "$LIB_DIR/state.sh"
    # Source again — should be a no-op thanks to guard.
    source "$LIB_DIR/state.sh"
    # If we get here without error, the guard works.
  )
}

@test "guards: double-sourcing all files produces no errors" {
  (
    for file in "$LIB_DIR"/*.sh; do
      source "$file"
    done
    # Source all again — guards should prevent conflicts.
    for file in "$LIB_DIR"/*.sh; do
      source "$file"
    done
  )
}

# --- No function name collisions ---

# Helper: extract function names from all lib/*.sh files.
_collect_all_functions() {
  grep -h '^[a-zA-Z_][a-zA-Z0-9_]*()' "$LIB_DIR"/*.sh \
    | sed 's/()[[:space:]]*{.*//' \
    | sed 's/()[[:space:]]*//' \
    | sort
}

@test "functions: no duplicate function names across lib files" {
  local duplicates
  duplicates=$(_collect_all_functions | uniq -d)
  if [[ -n "$duplicates" ]]; then
    echo "Duplicate function names found:" >&2
    echo "$duplicates" >&2
    return 1
  fi
}

@test "functions: every lib file defines at least one function" {
  local file empty=()
  for file in "$LIB_DIR"/*.sh; do
    local basename
    basename="$(basename "$file")"
    if ! grep -q '^[a-zA-Z_][a-zA-Z0-9_]*()' "$file"; then
      empty+=("$basename")
    fi
  done
  if [[ ${#empty[@]} -gt 0 ]]; then
    echo "Files with no functions: ${empty[*]}" >&2
    return 1
  fi
}

@test "functions: declared functions are callable after sourcing all libs" {
  (
    for file in "$LIB_DIR"/*.sh; do
      source "$file"
    done
    # Verify some key functions are declared (type -t returns 'function').
    [[ "$(type -t load_config)" == "function" ]]
    [[ "$(type -t init_pipeline)" == "function" ]]
    [[ "$(type -t detect_tasks_file)" == "function" ]]
    [[ "$(type -t build_claude_cmd)" == "function" ]]
    [[ "$(type -t run_preflight)" == "function" ]]
    [[ "$(type -t install_hooks)" == "function" ]]
    [[ "$(type -t run_test_gate)" == "function" ]]
    [[ "$(type -t prewarm_session)" == "function" ]]
    [[ "$(type -t create_task_branch)" == "function" ]]
    [[ "$(type -t run_coder)" == "function" ]]
    [[ "$(type -t run_fixer)" == "function" ]]
    [[ "$(type -t run_reviewers)" == "function" ]]
    [[ "$(type -t post_review_comments)" == "function" ]]
    [[ "$(type -t run_postfix_verification)" == "function" ]]
    [[ "$(type -t run_merger)" == "function" ]]
  )
}

# --- No variable conflicts ---

@test "variables: load guard names are unique per module" {
  local guards
  guards=$(grep -h 'readonly _AUTOPILOT_.*_LOADED=1' "$LIB_DIR"/*.sh \
    | sed 's/readonly //' | sed 's/=1//' | sort)
  local duplicates
  duplicates=$(echo "$guards" | uniq -d)
  if [[ -n "$duplicates" ]]; then
    echo "Duplicate load guard variables:" >&2
    echo "$duplicates" >&2
    return 1
  fi
}

@test "variables: exported exit code constants have unique names" {
  local exports
  exports=$(grep -rh '^\(readonly\|export\) [A-Z]' "$LIB_DIR"/*.sh \
    | grep -v '_AUTOPILOT_' \
    | sed 's/^readonly //' | sed 's/^export //' \
    | sed 's/=.*//' | sort)
  local duplicates
  duplicates=$(echo "$exports" | uniq -d)
  if [[ -n "$duplicates" ]]; then
    echo "Duplicate exported constants:" >&2
    echo "$duplicates" >&2
    return 1
  fi
}

@test "variables: TESTGATE exit codes are accessible after sourcing" {
  (
    source "$LIB_DIR/testgate.sh"
    [[ "$TESTGATE_PASS" == "0" ]]
    [[ "$TESTGATE_FAIL" == "1" ]]
    [[ "$TESTGATE_SKIP" == "2" ]]
    [[ "$TESTGATE_ALREADY_VERIFIED" == "3" ]]
    [[ "$TESTGATE_ERROR" == "4" ]]
  )
}

@test "variables: POSTFIX exit codes are accessible after sourcing" {
  (
    source "$LIB_DIR/postfix.sh"
    [[ "$POSTFIX_PASS" == "0" ]]
    [[ "$POSTFIX_FAIL" == "1" ]]
    [[ "$POSTFIX_ERROR" == "2" ]]
  )
}

@test "variables: MERGER exit codes are accessible after sourcing" {
  (
    source "$LIB_DIR/merger.sh"
    [[ "$MERGER_APPROVE" == "0" ]]
    [[ "$MERGER_REJECT" == "1" ]]
    [[ "$MERGER_ERROR" == "2" ]]
  )
}

@test "variables: exit codes dont conflict across modules" {
  (
    source "$LIB_DIR/testgate.sh"
    source "$LIB_DIR/postfix.sh"
    source "$LIB_DIR/merger.sh"
    # Each module uses its own prefix — verify no cross-contamination.
    [[ "$TESTGATE_PASS" == "0" ]]
    [[ "$POSTFIX_PASS" == "0" ]]
    [[ "$MERGER_APPROVE" == "0" ]]
    [[ "$TESTGATE_ERROR" == "4" ]]
    [[ "$POSTFIX_ERROR" == "2" ]]
    [[ "$MERGER_ERROR" == "2" ]]
  )
}

# --- Comprehensive combined sourcing ---

@test "combined: all libs source together and key functions exist" {
  run bash -c '
    for file in "'"$LIB_DIR"'"/*.sh; do
      source "$file" || { echo "Failed to source $(basename "$file")"; exit 1; }
    done
    # Count functions — should have a reasonable number.
    func_count=$(declare -F | wc -l)
    if [[ "$func_count" -lt 50 ]]; then
      echo "Only $func_count functions found, expected 50+" >&2
      exit 1
    fi
    echo "OK: $func_count functions loaded"
  '
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "combined: no stderr warnings when sourcing all libs" {
  run bash -c '
    exec 2>&1
    for file in "'"$LIB_DIR"'"/*.sh; do
      source "$file"
    done
    echo "OK"
  '
  echo "$output"
  [ "$status" -eq 0 ]
  # Should not contain common warning patterns.
  [[ ! "$output" =~ "unbound variable" ]]
  [[ ! "$output" =~ "readonly variable" ]]
  [[ ! "$output" =~ "not found" ]]
}

@test "combined: sourcing all libs does not pollute PATH" {
  local original_path="$PATH"
  (
    for file in "$LIB_DIR"/*.sh; do
      source "$file"
    done
    [[ "$PATH" == "$original_path" ]]
  )
}

# --- File coverage check ---

@test "coverage: test covers all lib/*.sh files that exist" {
  local lib_files=()
  for file in "$LIB_DIR"/*.sh; do
    lib_files+=("$(basename "$file")")
  done
  # Verify we know about all files — if a new lib is added, this test surfaces it.
  local expected_files=(
    "claude.sh"
    "coder.sh"
    "config.sh"
    "fixer.sh"
    "git-ops.sh"
    "hooks.sh"
    "merger.sh"
    "postfix.sh"
    "preflight.sh"
    "reviewer-posting.sh"
    "reviewer.sh"
    "session-cache.sh"
    "state.sh"
    "tasks.sh"
    "testgate.sh"
  )
  local unexpected=()
  for file in "${lib_files[@]}"; do
    local found=0
    for expected in "${expected_files[@]}"; do
      if [[ "$file" == "$expected" ]]; then
        found=1
        break
      fi
    done
    if [[ "$found" -eq 0 ]]; then
      unexpected+=("$file")
    fi
  done
  if [[ ${#unexpected[@]} -gt 0 ]]; then
    echo "New lib files not covered by smoke test: ${unexpected[*]}" >&2
    echo "Add them to the expected_files list in test_smoke.bats" >&2
    return 1
  fi
}
