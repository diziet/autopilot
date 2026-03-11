#!/usr/bin/env bats
# Tests for lib/reviewer.sh — diff fetching, single reviewer execution,
# parallel spawning, result collection, and integration.
# Split from test_reviewer.bats for parallel execution.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/reviewer.sh"

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template_nogit

  # Source reviewer.sh (which sources config, state, claude).
  load_config "$TEST_PROJECT_DIR"

  # Initialize pipeline state dir for log_msg.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/locks"

  # Override personas dir to use real personas in repo.
  _REVIEWER_PERSONAS_DIR="$BATS_TEST_DIRNAME/../reviewers"

  # Default function mocks (override per-test as needed).

  # Mock timeout: skip timeout value, run the command directly.
  timeout() { shift; "$@"; }
  export -f timeout

  # Mock gh CLI with default responses.
  gh() {
    case "$*" in
      *"auth status"*) return 0 ;;
      *"pr view"*"headRefName"*) echo "autopilot/task-1" ;;
      *"pr view"*) echo "https://github.com/testowner/testrepo/pull/42" ;;
      *"pr diff"*) echo "+added line" ;;
      *) echo "mock-gh: $*" >&2; return 0 ;;
    esac
  }
  export -f gh

  # Mock claude CLI with default response.
  claude() {
    echo '{"result":"NO_ISSUES_FOUND","session_id":"sess-123"}'
  }
  export -f claude
}

# --- fetch_pr_diff (with mocked gh/timeout) ---

@test "fetch_pr_diff fetches diff and writes to temp file" {
  # Override gh to return branch name and diff content.
  gh() {
    if [[ "$*" == *"headRefName"* ]]; then
      echo "feat/my-branch"
    elif [[ "$1" == "pr" && "$2" == "diff" ]]; then
      echo "diff --git a/file.txt b/file.txt"
      echo "+new line"
    fi
  }
  export -f gh

  local diff_file
  diff_file="$(fetch_pr_diff "$TEST_PROJECT_DIR" 42)"
  [ -f "$diff_file" ]

  local content
  content="$(cat "$diff_file")"
  echo "$content" | grep -qF "PR #42"
  echo "$content" | grep -qF "feat/my-branch"
  echo "$content" | grep -qF "testowner/testrepo"
  echo "$content" | grep -qF "+new line"

  rm -f "$diff_file"
}

@test "fetch_pr_diff returns error 2 for oversized diff" {
  # Override gh to return a large diff.
  gh() {
    if [[ "$*" == *"headRefName"* ]]; then
      echo "feat/big"
    elif [[ "$1" == "pr" && "$2" == "diff" ]]; then
      python3 -c "print('x' * 200)"
    fi
  }
  export -f gh

  AUTOPILOT_MAX_DIFF_BYTES=100

  run fetch_pr_diff "$TEST_PROJECT_DIR" 42
  [ "$status" -eq 2 ]
}

@test "fetch_pr_diff fails when repo slug cannot be determined" {
  get_repo_slug() { return 1; }
  export -f get_repo_slug

  run fetch_pr_diff "$TEST_PROJECT_DIR" 42
  [ "$status" -eq 1 ]
}

@test "fetch_pr_diff fails when gh pr view fails" {
  gh() { return 1; }
  export -f gh

  run fetch_pr_diff "$TEST_PROJECT_DIR" 42
  [ "$status" -eq 1 ]
}

@test "fetch_pr_diff fails when gh pr diff fails" {
  gh() {
    if [[ "$*" == *"headRefName"* ]]; then
      echo "feat/branch"
    elif [[ "$1" == "pr" && "$2" == "diff" ]]; then
      return 1
    fi
  }
  export -f gh

  run fetch_pr_diff "$TEST_PROJECT_DIR" 42
  [ "$status" -eq 1 ]
}

@test "fetch_pr_diff logs diff size" {
  gh() {
    if [[ "$*" == *"headRefName"* ]]; then
      echo "feat/branch"
    elif [[ "$1" == "pr" && "$2" == "diff" ]]; then
      echo "small diff"
    fi
  }
  export -f gh

  local diff_file
  diff_file="$(fetch_pr_diff "$TEST_PROJECT_DIR" 99)"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  echo "$log_content" | grep -qF "Fetched diff for PR #99"
  echo "$log_content" | grep -qF "bytes"

  rm -f "$diff_file"
}

# --- _run_single_reviewer (with mocked claude) ---

@test "_run_single_reviewer executes claude with persona prompt" {
  # Override claude to echo its args.
  claude() {
    for arg in "$@"; do
      echo "arg: $arg"
    done
  }
  export -f claude

  # Create a dummy diff file.
  local diff_file
  diff_file="$(mktemp)"
  echo "diff content here" > "$diff_file"

  local output_file exit_code=0
  output_file="$(_run_single_reviewer "$TEST_PROJECT_DIR" "general" \
    "$diff_file" 10)" || exit_code=$?

  [ "$exit_code" -eq 0 ]
  [ -f "$output_file" ]

  local content
  content="$(cat "$output_file")"
  # Should include --system-prompt arg.
  echo "$content" | grep -qF "arg: --system-prompt"
  # Should include --print arg.
  echo "$content" | grep -qF "arg: --print"
  # Should include actual persona content from general.md.
  echo "$content" | grep -qF "general code review"

  rm -f "$diff_file" "$output_file" "${output_file}.err"
}

@test "_run_single_reviewer returns error for missing persona" {
  run _run_single_reviewer "$TEST_PROJECT_DIR" "nonexistent" "/dev/null" 10
  [ "$status" -ne 0 ]
}

@test "_run_single_reviewer returns exit code from claude" {
  claude() {
    echo '{"result":"error"}'
    return 1
  }
  export -f claude

  local diff_file
  diff_file="$(mktemp)"
  echo "diff" > "$diff_file"

  local output_file exit_code=0
  output_file="$(_run_single_reviewer "$TEST_PROJECT_DIR" "general" \
    "$diff_file" 10)" || exit_code=$?

  [ "$exit_code" -eq 1 ]

  rm -f "$diff_file" "$output_file" "${output_file}.err"
}

@test "_run_single_reviewer logs completion on success" {
  claude() {
    echo '{"result":"ok"}'
  }
  export -f claude

  local diff_file
  diff_file="$(mktemp)"
  echo "diff" > "$diff_file"

  _run_single_reviewer "$TEST_PROJECT_DIR" "security" "$diff_file" 10 || true

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  echo "$log_content" | grep -qF "Reviewer 'security' completed"

  rm -f "$diff_file"
}

@test "_run_single_reviewer passes config dir to claude" {
  claude() {
    echo "{\"result\":\"config=${CLAUDE_CONFIG_DIR:-unset}\"}"
  }
  export -f claude

  local diff_file
  diff_file="$(mktemp)"
  echo "diff" > "$diff_file"

  local output_file
  output_file="$(_run_single_reviewer "$TEST_PROJECT_DIR" "general" \
    "$diff_file" 10 "/custom/reviewer/config")" || true

  local content
  content="$(cat "$output_file")"
  echo "$content" | grep -qF "config=/custom/reviewer/config"

  rm -f "$diff_file" "$output_file" "${output_file}.err"
}

@test "_run_single_reviewer unsets CLAUDECODE" {
  CLAUDECODE="some-session-id"

  claude() {
    echo "{\"result\":\"claudecode=${CLAUDECODE:-unset}\"}"
  }
  export -f claude

  local diff_file
  diff_file="$(mktemp)"
  echo "diff" > "$diff_file"

  local output_file
  output_file="$(_run_single_reviewer "$TEST_PROJECT_DIR" "general" \
    "$diff_file" 10)" || true

  local content
  content="$(cat "$output_file")"
  echo "$content" | grep -qF "claudecode=unset"

  rm -f "$diff_file" "$output_file" "${output_file}.err"
  unset CLAUDECODE
}

# --- _spawn_reviewer_bg ---

@test "_spawn_reviewer_bg writes meta file with output path and exit code" {
  claude() {
    echo '{"result":"review done"}'
  }
  export -f claude

  local diff_file result_dir
  diff_file="$(mktemp)"
  echo "diff" > "$diff_file"
  result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"

  _spawn_reviewer_bg "$TEST_PROJECT_DIR" "general" "$diff_file" 10 "" "$result_dir"

  # Check the meta file was created.
  [ -f "$result_dir/general.meta" ]

  local output_file exit_code
  {
    read -r output_file
    read -r exit_code
  } < "$result_dir/general.meta"

  [ -f "$output_file" ]
  [ "$exit_code" -eq 0 ]

  rm -f "$diff_file" "$output_file" "${output_file}.err"
}

@test "_spawn_reviewer_bg records non-zero exit code" {
  claude() {
    echo '{"result":"error"}'
    return 1
  }
  export -f claude

  local diff_file result_dir
  diff_file="$(mktemp)"
  echo "diff" > "$diff_file"
  result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"

  _spawn_reviewer_bg "$TEST_PROJECT_DIR" "general" "$diff_file" 10 "" "$result_dir"

  local exit_code
  {
    read -r _output_file
    read -r exit_code
  } < "$result_dir/general.meta"

  [ "$exit_code" -eq 1 ]

  rm -f "$diff_file"
}

# --- collect_review_results ---

@test "collect_review_results reads meta files into arrays" {
  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"

  # Create mock output files.
  local output1 output2
  output1="$(mktemp)"
  output2="$(mktemp)"
  echo '{"result":"ok"}' > "$output1"
  echo '{"result":"issues"}' > "$output2"

  # Create meta files.
  printf '%s\n%s\n' "$output1" "0" > "$result_dir/general.meta"
  printf '%s\n%s\n' "$output2" "0" > "$result_dir/security.meta"

  collect_review_results "$result_dir"

  [ "${#_REVIEW_PERSONAS[@]}" -eq 2 ]
  [ "${#_REVIEW_EXITS[@]}" -eq 2 ]
  [ "${#_REVIEW_FILES[@]}" -eq 2 ]

  # Check personas are present (order may vary due to glob).
  local found_general=false found_security=false
  local i
  for (( i=0; i<${#_REVIEW_PERSONAS[@]}; i++ )); do
    [[ "${_REVIEW_PERSONAS[$i]}" == "general" ]] && found_general=true
    [[ "${_REVIEW_PERSONAS[$i]}" == "security" ]] && found_security=true
  done
  [ "$found_general" = true ]
  [ "$found_security" = true ]

  rm -f "$output1" "$output2"
}

@test "collect_review_results handles empty result directory" {
  local result_dir="$BATS_TEST_TMPDIR/empty_result_dir"
  mkdir -p "$result_dir"

  collect_review_results "$result_dir"

  [ "${#_REVIEW_PERSONAS[@]}" -eq 0 ]
}

@test "collect_review_results records non-zero exit codes" {
  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"

  local output1
  output1="$(mktemp)"
  echo '{"result":"error"}' > "$output1"

  printf '%s\n%s\n' "$output1" "1" > "$result_dir/general.meta"

  collect_review_results "$result_dir"

  [ "${#_REVIEW_PERSONAS[@]}" -eq 1 ]
  [ "${_REVIEW_PERSONAS[0]}" = "general" ]
  [ "${_REVIEW_EXITS[0]}" = "1" ]

  rm -f "$output1"
}

# --- _wait_pid_timeout ---

@test "_wait_pid_timeout returns 0 for quick process" {
  sleep 0.01 &
  local pid=$!
  _wait_pid_timeout "$pid" 5
}

@test "_wait_pid_timeout returns 1 for slow process" {
  sleep 60 &
  local pid=$!
  run _wait_pid_timeout "$pid" 1
  [ "$status" -eq 1 ]
  kill "$pid" 2>/dev/null || true
}

# --- _write_timeout_meta ---

@test "_write_timeout_meta writes meta with exit code 124" {
  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"

  _write_timeout_meta "$result_dir" "general"

  [ -f "$result_dir/general.meta" ]

  local output_file exit_code
  {
    read -r output_file
    read -r exit_code
  } < "$result_dir/general.meta"

  [ -z "$output_file" ]
  [ "$exit_code" -eq 124 ]
}

@test "_write_timeout_meta does not overwrite existing meta" {
  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"

  # Pre-populate a .meta that _spawn_reviewer_bg would write.
  printf '%s\n%s\n' "/tmp/real-output" "0" > "$result_dir/general.meta"

  _write_timeout_meta "$result_dir" "general"

  # Should NOT overwrite — original meta preserved.
  local exit_code
  {
    read -r _output_file
    read -r exit_code
  } < "$result_dir/general.meta"

  [ "$exit_code" -eq 0 ]
}

# --- _wait_for_reviewers ---

@test "_wait_for_reviewers writes timeout meta for killed process" {
  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"

  # Start a long-running background process.
  sleep 60 &
  local pid=$!

  _wait_for_reviewers 1 "$result_dir" "$pid" -- "slow-reviewer"

  # Should have killed the process and written timeout .meta.
  [ -f "$result_dir/slow-reviewer.meta" ]

  local exit_code
  {
    read -r _output_file
    read -r exit_code
  } < "$result_dir/slow-reviewer.meta"

  [ "$exit_code" -eq 124 ]

  kill "$pid" 2>/dev/null || true
}

@test "_wait_for_reviewers handles completed process" {
  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"

  # Write a meta file as _spawn_reviewer_bg would.
  printf '%s\n%s\n' "/tmp/output" "0" > "$result_dir/fast-reviewer.meta"

  # Start a quick background process.
  sleep 0.01 &
  local pid=$!

  _wait_for_reviewers 5 "$result_dir" "$pid" -- "fast-reviewer"

  # Meta file should still have original exit code (not overwritten).
  local exit_code
  {
    read -r _output_file
    read -r exit_code
  } < "$result_dir/fast-reviewer.meta"

  [ "$exit_code" -eq 0 ]
}

# --- extract_review_text ---

@test "extract_review_text extracts result from JSON file" {
  local json_file
  json_file="$(mktemp)"
  echo '{"result":"Found 2 issues.","is_error":false}' > "$json_file"

  local result
  result="$(extract_review_text "$json_file")"
  [ "$result" = "Found 2 issues." ]

  rm -f "$json_file"
}

@test "extract_review_text returns empty for malformed JSON" {
  local json_file
  json_file="$(mktemp)"
  echo 'not json' > "$json_file"

  local result
  result="$(extract_review_text "$json_file")" || true
  [ -z "$result" ]

  rm -f "$json_file"
}

# --- run_reviewers (integration with mocks) ---

@test "run_reviewers spawns reviewers and returns result directory" {
  claude() {
    echo '{"result":"NO_ISSUES_FOUND"}'
  }
  export -f claude

  AUTOPILOT_REVIEWERS="general,security"
  AUTOPILOT_TIMEOUT_REVIEWER=30
  AUTOPILOT_TIMEOUT_REVIEWER_CLAUDE=10

  local diff_file
  diff_file="$(mktemp)"
  echo "diff --git a/test.sh b/test.sh" > "$diff_file"

  local result_dir
  result_dir="$(run_reviewers "$TEST_PROJECT_DIR" 42 "$diff_file")"

  [ -d "$result_dir" ]
  [ -f "$result_dir/general.meta" ]
  [ -f "$result_dir/security.meta" ]

  rm -f "$diff_file"
  rm -rf "$result_dir"
}

@test "run_reviewers handles single reviewer" {
  claude() {
    echo '{"result":"1. Bug found"}'
  }
  export -f claude

  AUTOPILOT_REVIEWERS="general"
  AUTOPILOT_TIMEOUT_REVIEWER=30
  AUTOPILOT_TIMEOUT_REVIEWER_CLAUDE=10

  local diff_file
  diff_file="$(mktemp)"
  echo "diff" > "$diff_file"

  local result_dir
  result_dir="$(run_reviewers "$TEST_PROJECT_DIR" 10 "$diff_file")"

  [ -d "$result_dir" ]
  [ -f "$result_dir/general.meta" ]

  rm -f "$diff_file"
  rm -rf "$result_dir"
}

@test "run_reviewers logs spawning message" {
  claude() {
    echo '{"result":"ok"}'
  }
  export -f claude

  AUTOPILOT_REVIEWERS="general,dry"
  AUTOPILOT_TIMEOUT_REVIEWER=30
  AUTOPILOT_TIMEOUT_REVIEWER_CLAUDE=10

  local diff_file
  diff_file="$(mktemp)"
  echo "diff" > "$diff_file"

  run_reviewers "$TEST_PROJECT_DIR" 5 "$diff_file" || true

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  echo "$log_content" | grep -qF "Spawning 2 reviewers for PR #5"
  echo "$log_content" | grep -qF "All reviewers completed for PR #5"

  rm -f "$diff_file"
}

@test "run_reviewers uses AUTOPILOT_REVIEWER_CONFIG_DIR" {
  claude() {
    echo "{\"result\":\"config=${CLAUDE_CONFIG_DIR:-unset}\"}"
  }
  export -f claude

  AUTOPILOT_REVIEWERS="general"
  AUTOPILOT_REVIEWER_CONFIG_DIR="/custom/reviewer/config"
  AUTOPILOT_TIMEOUT_REVIEWER=30
  AUTOPILOT_TIMEOUT_REVIEWER_CLAUDE=10

  local diff_file
  diff_file="$(mktemp)"
  echo "diff" > "$diff_file"

  local result_dir
  result_dir="$(run_reviewers "$TEST_PROJECT_DIR" 42 "$diff_file")"

  # Read the output file from the meta.
  local output_file
  read -r output_file < "$result_dir/general.meta"
  local content
  content="$(cat "$output_file")"
  echo "$content" | grep -qF "config=/custom/reviewer/config"

  rm -f "$diff_file"
  rm -rf "$result_dir"
}

# --- Shared test helpers ---

# Mock claude to capture args.
_mock_claude_capture_args() {
  claude() {
    for arg in "$@"; do echo "arg: $arg"; done
  }
  export -f claude
}

# Create a test diff file and set diff_file variable.
_create_test_diff() {
  diff_file="$(mktemp)"
  echo "diff content" > "$diff_file"
}

# Create a test persona with optional frontmatter.
_create_test_persona() {
  local name="$1"
  local interactive_value="$2"
  local body="$3"
  local test_persona_dir="$BATS_TEST_TMPDIR/personas"
  mkdir -p "$test_persona_dir"
  if [[ -n "$interactive_value" ]]; then
    cat > "$test_persona_dir/${name}.md" <<EOF
---
interactive: ${interactive_value}
---
${body}
EOF
  else
    echo "$body" > "$test_persona_dir/${name}.md"
  fi
  _REVIEWER_PERSONAS_DIR="$test_persona_dir"
}

# --- Interactive reviewer mode ---

@test "_run_single_reviewer uses --print in default mode" {
  AUTOPILOT_REVIEWER_INTERACTIVE="false"
  _mock_claude_capture_args

  local diff_file
  _create_test_diff

  local output_file
  output_file="$(_run_single_reviewer "$TEST_PROJECT_DIR" "general" \
    "$diff_file" 10)" || true

  local content
  content="$(cat "$output_file")"
  # Should include --print flag.
  echo "$content" | grep -qF "arg: --print"

  rm -f "$diff_file" "$output_file" "${output_file}.err"
}

@test "_run_single_reviewer omits --print in interactive mode" {
  AUTOPILOT_REVIEWER_INTERACTIVE="true"
  AUTOPILOT_TIMEOUT_REVIEWER_INTERACTIVE=10
  _mock_claude_capture_args

  local diff_file
  _create_test_diff

  local output_file
  output_file="$(_run_single_reviewer "$TEST_PROJECT_DIR" "general" \
    "$diff_file" 10)" || true

  local content
  content="$(cat "$output_file")"
  # Interactive mode must NOT include --print (tool access requires it).
  if echo "$content" | grep -qF "arg: --print"; then
    echo "FAIL: --print should not be present in interactive mode"
    return 1
  fi
  # Should include prompt with diff file reference.
  echo "$content" | grep -qF "Review the PR diff in"

  rm -f "$diff_file" "$output_file" "${output_file}.err"
}

@test "_run_single_reviewer uses interactive timeout only when caller uses default" {
  AUTOPILOT_REVIEWER_INTERACTIVE="true"
  AUTOPILOT_TIMEOUT_REVIEWER_INTERACTIVE=42

  local capture_file="$BATS_TEST_TMPDIR/captured_timeout"
  timeout() {
    echo "$1" > "$capture_file"
    shift
    "$@"
  }
  export -f timeout
  export capture_file

  claude() { echo '{"result":"ok"}'; }
  export -f claude

  local diff_file
  _create_test_diff

  # When caller passes explicit timeout (999), it should be preserved.
  _run_single_reviewer "$TEST_PROJECT_DIR" "general" "$diff_file" 999 || true
  [ "$(cat "$capture_file")" = "999" ]

  # When caller passes no timeout (default), interactive timeout applies.
  _run_single_reviewer "$TEST_PROJECT_DIR" "general" "$diff_file" || true
  [ "$(cat "$capture_file")" = "42" ]

  rm -f "$diff_file" "$capture_file"
}

@test "_run_single_reviewer per-persona interactive override works" {
  AUTOPILOT_REVIEWER_INTERACTIVE="false"
  _create_test_persona "deep" "true" "You are a deep reviewer."
  _mock_claude_capture_args

  local diff_file
  _create_test_diff

  local output_file
  output_file="$(_run_single_reviewer "$TEST_PROJECT_DIR" "deep" \
    "$diff_file" 10)" || true

  local content
  content="$(cat "$output_file")"
  # Per-persona interactive: should NOT include --print (tool access).
  if echo "$content" | grep -qF "arg: --print"; then
    echo "FAIL: --print should not be present for interactive persona"
    return 1
  fi
  echo "$content" | grep -qF "Review the PR diff in"

  rm -f "$diff_file" "$output_file" "${output_file}.err"
}

@test "run_reviewers handles all five default reviewers" {
  claude() {
    echo '{"result":"NO_ISSUES_FOUND"}'
  }
  export -f claude

  AUTOPILOT_REVIEWERS="general,dry,performance,security,design"
  AUTOPILOT_TIMEOUT_REVIEWER=30
  AUTOPILOT_TIMEOUT_REVIEWER_CLAUDE=10

  local diff_file
  diff_file="$(mktemp)"
  echo "diff" > "$diff_file"

  local result_dir
  result_dir="$(run_reviewers "$TEST_PROJECT_DIR" 42 "$diff_file")"

  [ -d "$result_dir" ]
  [ -f "$result_dir/general.meta" ]
  [ -f "$result_dir/dry.meta" ]
  [ -f "$result_dir/performance.meta" ]
  [ -f "$result_dir/security.meta" ]
  [ -f "$result_dir/design.meta" ]

  rm -f "$diff_file"
  rm -rf "$result_dir"
}
