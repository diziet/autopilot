#!/usr/bin/env bats
# Tests for stale lock derivation from agent timeouts.

load helpers/test_template

setup() {
  TEST_PROJECT_DIR="$(mktemp -d)"

  # Unset all AUTOPILOT_* env vars to start clean
  while IFS= read -r var; do
    unset "$var"
  done < <(env | grep '^AUTOPILOT_' | cut -d= -f1)

  # Source state.sh (which also sources config.sh)
  source "$BATS_TEST_DIRNAME/../lib/state.sh"
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR"
}

# --- _compute_stale_lock_minutes ---

@test "compute stale lock minutes uses default coder timeout (2700s = 50 min)" {
  # Default TIMEOUT_CODER=2700 (45 min) is the largest default timeout
  # 2700/60 + 5 = 50
  local result
  result="$(_compute_stale_lock_minutes)"
  [ "$result" = "50" ]
}

@test "compute stale lock minutes picks coder when it is largest" {
  AUTOPILOT_TIMEOUT_CODER=3600
  AUTOPILOT_TIMEOUT_FIXER=900
  AUTOPILOT_TIMEOUT_SPEC_REVIEW=1200
  local result
  result="$(_compute_stale_lock_minutes)"
  # 3600/60 + 5 = 65
  [ "$result" = "65" ]
}

@test "compute stale lock minutes picks fixer when it is largest" {
  AUTOPILOT_TIMEOUT_CODER=600
  AUTOPILOT_TIMEOUT_FIXER=3000
  AUTOPILOT_TIMEOUT_SPEC_REVIEW=1200
  local result
  result="$(_compute_stale_lock_minutes)"
  # 3000/60 + 5 = 55
  [ "$result" = "55" ]
}

@test "compute stale lock minutes picks spec review when it is largest" {
  AUTOPILOT_TIMEOUT_CODER=600
  AUTOPILOT_TIMEOUT_FIXER=900
  AUTOPILOT_TIMEOUT_SPEC_REVIEW=5400
  local result
  result="$(_compute_stale_lock_minutes)"
  # 5400/60 + 5 = 95
  [ "$result" = "95" ]
}

@test "changing coder timeout changes stale threshold" {
  # Default: TIMEOUT_CODER=2700, result=50
  local default_result
  default_result="$(_compute_stale_lock_minutes)"
  [ "$default_result" = "50" ]

  # Increase coder timeout
  AUTOPILOT_TIMEOUT_CODER=5400
  local new_result
  new_result="$(_compute_stale_lock_minutes)"
  # ceil(5400/60) + 5 = 95
  [ "$new_result" = "95" ]
}

@test "compute stale lock minutes uses ceiling division for non-exact values" {
  # 2999 seconds = 49 min 59 sec; ceil(2999/60) = 50, + 5 = 55
  AUTOPILOT_TIMEOUT_CODER=2999
  AUTOPILOT_TIMEOUT_FIXER=900
  AUTOPILOT_TIMEOUT_SPEC_REVIEW=1200
  local result
  result="$(_compute_stale_lock_minutes)"
  [ "$result" = "55" ]
}

# --- _is_lock_stale with derived threshold ---

@test "is_lock_stale uses derived threshold for live PID with aged lock" {
  init_pipeline "$TEST_PROJECT_DIR"
  local lock_file="${TEST_PROJECT_DIR}/.autopilot/locks/test.lock"
  mkdir -p "${TEST_PROJECT_DIR}/.autopilot/locks"
  echo "$$" > "$lock_file"

  # Set a very short derived threshold (120s -> ceil(120/60)+5 = 7 min)
  AUTOPILOT_TIMEOUT_CODER=120
  AUTOPILOT_TIMEOUT_FIXER=60
  AUTOPILOT_TIMEOUT_SPEC_REVIEW=60

  # Backdate lock file to 8 minutes ago — exceeds derived 7-min threshold
  touch -t "$(date -v-8M '+%Y%m%d%H%M.%S')" "$lock_file"

  # Live PID but old lock → stale
  run _is_lock_stale "$TEST_PROJECT_DIR" "$lock_file" "$$"
  [ "$status" -eq 0 ]

  # Now set a large derived threshold (7200s -> ceil(7200/60)+5 = 125 min)
  AUTOPILOT_TIMEOUT_CODER=7200

  # Same 8-minute-old lock, but 125-min threshold → not stale
  run _is_lock_stale "$TEST_PROJECT_DIR" "$lock_file" "$$"
  [ "$status" -eq 1 ]
}

@test "explicit STALE_LOCK_MINUTES override takes precedence over derived" {
  init_pipeline "$TEST_PROJECT_DIR"
  local lock_file="${TEST_PROJECT_DIR}/.autopilot/locks/test.lock"
  mkdir -p "${TEST_PROJECT_DIR}/.autopilot/locks"
  echo "$$" > "$lock_file"

  # Derived threshold would be ceil(7200/60)+5 = 125 min
  AUTOPILOT_TIMEOUT_CODER=7200

  # Backdate lock to 3 minutes ago
  touch -t "$(date -v-3M '+%Y%m%d%H%M.%S')" "$lock_file"

  # With derived threshold (125 min), 3-min-old lock is NOT stale
  unset AUTOPILOT_STALE_LOCK_MINUTES
  run _is_lock_stale "$TEST_PROJECT_DIR" "$lock_file" "$$"
  [ "$status" -eq 1 ]

  # Override to 1 minute — now 3-min-old lock IS stale
  AUTOPILOT_STALE_LOCK_MINUTES=1
  run _is_lock_stale "$TEST_PROJECT_DIR" "$lock_file" "$$"
  [ "$status" -eq 0 ]
}

@test "stale lock detected for dead PID regardless of threshold" {
  init_pipeline "$TEST_PROJECT_DIR"
  local lock_file="${TEST_PROJECT_DIR}/.autopilot/locks/test.lock"
  mkdir -p "${TEST_PROJECT_DIR}/.autopilot/locks"
  echo "99999999" > "$lock_file"

  # Dead PID is always stale
  run _is_lock_stale "$TEST_PROJECT_DIR" "$lock_file" "99999999"
  [ "$status" -eq 0 ]
}

@test "stale lock detected for empty PID" {
  init_pipeline "$TEST_PROJECT_DIR"
  local lock_file="${TEST_PROJECT_DIR}/.autopilot/locks/test.lock"
  mkdir -p "${TEST_PROJECT_DIR}/.autopilot/locks"
  echo "" > "$lock_file"

  run _is_lock_stale "$TEST_PROJECT_DIR" "$lock_file" ""
  [ "$status" -eq 0 ]
}

# --- log_effective_config with derived stale lock ---

@test "log_effective_config shows derived value when STALE_LOCK_MINUTES unset" {
  unset AUTOPILOT_STALE_LOCK_MINUTES
  load_config "$TEST_PROJECT_DIR"

  local output
  output="$(log_effective_config)"
  # Should show derived value with [derived] source
  [[ "$output" == *"AUTOPILOT_STALE_LOCK_MINUTES=50 [derived]"* ]]
}

@test "log_effective_config shows explicit value when STALE_LOCK_MINUTES set via env" {
  export AUTOPILOT_STALE_LOCK_MINUTES=60
  load_config "$TEST_PROJECT_DIR"

  local output
  output="$(log_effective_config)"
  [[ "$output" == *"AUTOPILOT_STALE_LOCK_MINUTES=60 [env]"* ]]
}

@test "log_effective_config shows config file value when set in config" {
  unset AUTOPILOT_STALE_LOCK_MINUTES
  mkdir -p "${TEST_PROJECT_DIR}"
  echo "AUTOPILOT_STALE_LOCK_MINUTES=30" > "${TEST_PROJECT_DIR}/autopilot.conf"
  load_config "$TEST_PROJECT_DIR"

  local output
  output="$(log_effective_config)"
  [[ "$output" == *"AUTOPILOT_STALE_LOCK_MINUTES=30 [autopilot.conf]"* ]]
}

@test "log_effective_config derived value reflects custom coder timeout" {
  AUTOPILOT_TIMEOUT_CODER=3600
  load_config "$TEST_PROJECT_DIR"
  # Env override means coder timeout is 3600
  # But STALE_LOCK_MINUTES is empty -> derived
  # 3600/60 + 5 = 65
  local output
  output="$(log_effective_config)"
  [[ "$output" == *"AUTOPILOT_STALE_LOCK_MINUTES=65 [derived]"* ]]
}
