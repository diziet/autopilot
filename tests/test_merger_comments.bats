#!/usr/bin/env bats
# Tests for PR discussion fetching and inclusion in merger/fixer prompts.
# Covers lib/discussion.sh, merger prompt integration, and fixer prompt integration.

load helpers/test_template

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template

  # Source discussion.sh (which sources config, state, git-ops).
  source "$BATS_TEST_DIRNAME/../lib/discussion.sh"
  # Source merger.sh for prompt building tests.
  source "$BATS_TEST_DIRNAME/../lib/merger.sh"
  # Source fixer.sh for prompt building tests.
  source "$BATS_TEST_DIRNAME/../lib/fixer.sh"

  # Initialize pipeline state dir for log_msg.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/locks"

  _MERGER_PROMPTS_DIR="$BATS_TEST_DIRNAME/../prompts"
  _FIXER_PROMPTS_DIR="$BATS_TEST_DIRNAME/../prompts"
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR"
  rm -rf "$TEST_MOCK_BIN"
}

# --- fetch_pr_discussion ---

@test "fetch_pr_discussion returns comments from gh api" {
  cat > "${TEST_MOCK_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
echo "**alice** (2026-03-08T10:00:00Z):"
echo "Please also fix the README."
echo ""
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  local result
  result="$(fetch_pr_discussion "$TEST_PROJECT_DIR" 42)"
  echo "$result" | grep -qF "alice"
  echo "$result" | grep -qF "Please also fix the README"
}

@test "fetch_pr_discussion returns empty when no comments" {
  cat > "${TEST_MOCK_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
echo ""
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  local result
  result="$(fetch_pr_discussion "$TEST_PROJECT_DIR" 42)"
  [ -z "$result" ]
}

@test "fetch_pr_discussion passes since timestamp to jq filter" {
  local gh_log="${TEST_PROJECT_DIR}/gh_args.log"

  cat > "${TEST_MOCK_BIN}/gh" <<MOCK
#!/usr/bin/env bash
echo "\$*" >> "$gh_log"
echo ""
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  fetch_pr_discussion "$TEST_PROJECT_DIR" 42 "2026-03-07T00:00:00Z"

  # The jq filter should contain the timestamp for filtering.
  grep -qF "2026-03-07T00:00:00Z" "$gh_log"
}

@test "fetch_pr_discussion fails without repo slug" {
  local no_git_dir
  no_git_dir="$(mktemp -d)"
  mkdir -p "$no_git_dir/.autopilot/logs"

  run fetch_pr_discussion "$no_git_dir" 42
  [ "$status" -ne 0 ]

  rm -rf "$no_git_dir"
}

@test "fetch_pr_discussion handles gh failure gracefully" {
  cat > "${TEST_MOCK_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  local result
  result="$(fetch_pr_discussion "$TEST_PROJECT_DIR" 42)"
  [ -z "$result" ]
}

# --- truncate_discussion ---

@test "truncate_discussion returns text unchanged when under limit" {
  local text="line 1
line 2
line 3"
  local result
  result="$(truncate_discussion "$text" 10 "$TEST_PROJECT_DIR")"
  [ "$result" = "$text" ]
}

@test "truncate_discussion truncates to max lines keeping most recent" {
  local text=""
  local i
  for i in $(seq 1 20); do
    text="${text}line ${i}
"
  done

  local result
  result="$(truncate_discussion "$text" 5 "$TEST_PROJECT_DIR")"
  echo "$result" | grep -qF "line 20"
  echo "$result" | grep -qF "line 17"
  ! echo "$result" | grep -q "^line 1$"
}

@test "truncate_discussion adds truncation notice" {
  local text=""
  local i
  for i in $(seq 1 100); do
    text="${text}line ${i}
"
  done

  local result
  result="$(truncate_discussion "$text" 10 "$TEST_PROJECT_DIR")"
  echo "$result" | grep -qF "Older comments truncated"
}

@test "truncate_discussion logs warning on truncation" {
  local text=""
  local i
  for i in $(seq 1 50); do
    text="${text}line ${i}
"
  done

  truncate_discussion "$text" 10 "$TEST_PROJECT_DIR" >/dev/null

  local log_file="${TEST_PROJECT_DIR}/.autopilot/logs/pipeline.log"
  grep -qF "PR discussion truncated" "$log_file"
}

@test "truncate_discussion returns empty for empty input" {
  local result
  result="$(truncate_discussion "" 10 "$TEST_PROJECT_DIR")"
  [ -z "$result" ]
}

@test "truncate_discussion uses default max of 2000 lines" {
  # Generate 10 lines — well under 2000, should not truncate.
  local text=""
  local i
  for i in $(seq 1 10); do
    text="${text}line ${i}
"
  done

  local result
  result="$(truncate_discussion "$text")"
  echo "$result" | grep -qF "line 1"
  echo "$result" | grep -qF "line 10"
  ! echo "$result" | grep -qF "truncated"
}

# --- build_merger_prompt with discussion ---

@test "build_merger_prompt includes PR Discussion section when provided" {
  local discussion="**alice** (2026-03-08T10:00:00Z):
The Makefile wildcard already covers this."
  local result
  result="$(build_merger_prompt 42 "autopilot/task-5" "owner/repo" \
    "diff content" "" "" "$discussion")"
  echo "$result" | grep -qF "PR Discussion"
  echo "$result" | grep -qF "alice"
  echo "$result" | grep -qF "Makefile wildcard already covers this"
}

@test "build_merger_prompt omits PR Discussion section when empty" {
  local result
  result="$(build_merger_prompt 42 "autopilot/task-5" "owner/repo" \
    "diff content" "" "" "")"
  ! echo "$result" | grep -qF "PR Discussion"
}

@test "build_merger_prompt places discussion before diff" {
  local discussion="some discussion text"
  local result
  result="$(build_merger_prompt 1 "b" "o/r" "+added" "" "" "$discussion")"
  local disc_pos diff_pos
  disc_pos="$(echo "$result" | grep -n "PR Discussion" | head -1 | cut -d: -f1)"
  diff_pos="$(echo "$result" | grep -n "Diff to Review" | head -1 | cut -d: -f1)"
  [ "$disc_pos" -lt "$diff_pos" ]
}

@test "build_merger_prompt includes all sections together" {
  local file_list="src/app.sh | +1 -1"
  local discussion="**bob**: looks good to me"
  local result
  result="$(build_merger_prompt 1 "b" "o/r" "diff" "Add feature X" \
    "$file_list" "$discussion")"
  echo "$result" | grep -qF "Task Description"
  echo "$result" | grep -qF "Changed Files"
  echo "$result" | grep -qF "PR Discussion"
  echo "$result" | grep -qF "Diff to Review"
}

# --- build_fixer_prompt with discussion ---

@test "build_fixer_prompt includes PR Discussion section when provided" {
  local discussion="**human** (2026-03-08T12:00:00Z):
Please also fix the README typo."
  local ctx
  ctx="$(build_fixer_context_sections "" "$discussion" "")"
  local result
  result="$(build_fixer_prompt 42 "autopilot/task-5" "review text" \
    "owner/repo" "$ctx")"
  echo "$result" | grep -qF "PR Discussion"
  echo "$result" | grep -qF "human"
  echo "$result" | grep -qF "README typo"
}

@test "build_fixer_prompt omits PR Discussion section when empty" {
  local ctx
  ctx="$(build_fixer_context_sections "" "" "")"
  local result
  result="$(build_fixer_prompt 42 "autopilot/task-5" "review text" \
    "owner/repo" "$ctx")"
  ! echo "$result" | grep -qF "PR Discussion"
}

@test "build_fixer_prompt includes both hints and discussion" {
  local hints="The merger rejected because tests fail."
  local discussion="**alice**: please also update docs"
  local ctx
  ctx="$(build_fixer_context_sections "$hints" "$discussion" "")"
  local result
  result="$(build_fixer_prompt 42 "b" "text" "o/r" "$ctx")"
  echo "$result" | grep -qF "Diagnosis from Previous Attempt"
  echo "$result" | grep -qF "tests fail"
  echo "$result" | grep -qF "PR Discussion"
  echo "$result" | grep -qF "update docs"
}

# --- run_merger includes discussion (integration) ---

@test "run_merger fetches and includes PR discussion in prompt" {
  # Mock _fetch_merger_diff.
  _fetch_merger_diff() {
    echo "+new code"
    echo "-old code"
  }
  _fetch_pr_file_list() {
    echo "src/app.sh | +1 -1"
  }

  # Mock fetch_pr_discussion to return comments.
  fetch_pr_discussion() {
    echo "**human** (2026-03-08T10:00:00Z):"
    echo "The wildcard in Makefile already covers this."
    echo ""
  }

  cat > "${TEST_MOCK_BIN}/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
exec "$@"
MOCK
  chmod +x "${TEST_MOCK_BIN}/timeout"

  local prompt_log="${TEST_PROJECT_DIR}/prompt.log"

  cat > "${TEST_MOCK_BIN}/claude" <<MOCK
#!/usr/bin/env bash
while [[ \$# -gt 0 ]]; do
  if [[ "\$1" == "--print" ]]; then
    echo "\$2" >> "$prompt_log"
    break
  fi
  shift
done
echo '{"result":"VERDICT: APPROVE"}'
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/claude"

  cat > "${TEST_MOCK_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  run_merger "$TEST_PROJECT_DIR" 5 42 || true

  grep -qF "PR Discussion" "$prompt_log"
  grep -qF "wildcard in Makefile" "$prompt_log"
}

@test "run_merger works when no discussion comments exist" {
  _fetch_merger_diff() {
    echo "+new code"
  }
  _fetch_pr_file_list() {
    echo ""
  }

  # Mock fetch_pr_discussion to return empty.
  fetch_pr_discussion() {
    echo ""
  }

  cat > "${TEST_MOCK_BIN}/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
exec "$@"
MOCK
  chmod +x "${TEST_MOCK_BIN}/timeout"

  local prompt_log="${TEST_PROJECT_DIR}/prompt.log"

  cat > "${TEST_MOCK_BIN}/claude" <<MOCK
#!/usr/bin/env bash
while [[ \$# -gt 0 ]]; do
  if [[ "\$1" == "--print" ]]; then
    echo "\$2" >> "$prompt_log"
    break
  fi
  shift
done
echo '{"result":"VERDICT: APPROVE"}'
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/claude"

  cat > "${TEST_MOCK_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "${TEST_MOCK_BIN}/gh"

  run_merger "$TEST_PROJECT_DIR" 5 42 || true

  # Should not contain PR Discussion section.
  ! grep -qF "PR Discussion" "$prompt_log"
}

# --- run_fixer includes discussion (integration) ---

@test "run_fixer fetches and includes PR discussion in prompt" {
  local mock_dir
  mock_dir="$(mktemp -d)"

  # Mock fetch_pr_discussion to return comments.
  fetch_pr_discussion() {
    echo "**human** (2026-03-08T12:00:00Z):"
    echo "Please also fix the typo in line 42."
    echo ""
  }

  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
for arg in "$@"; do
  echo "arg: $arg"
done
MOCK
  chmod +x "$mock_dir/claude"

  cat > "$mock_dir/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
MOCK
  chmod +x "$mock_dir/gh"

  cat > "$mock_dir/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$mock_dir/timeout"

  export PATH="$mock_dir:$PATH"
  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"
  AUTOPILOT_TIMEOUT_FIXER=10
  AUTOPILOT_CODER_CONFIG_DIR="$(mktemp -d)"

  local output_file
  output_file="$(run_fixer "$TEST_PROJECT_DIR" 1 42)" || true

  local content
  content="$(cat "$output_file")"
  echo "$content" | grep -qF "PR Discussion"
  echo "$content" | grep -qF "typo in line 42"

  rm -f "$output_file" "${output_file}.err"
  rm -rf "$mock_dir"
}
