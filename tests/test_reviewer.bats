#!/usr/bin/env bats
# Tests for lib/reviewer.sh — PR diff fetching, size guard, persona parsing,
# single reviewer execution, parallel review, and result collection.

load helpers/test_template

# Source modules once at file level — inherited by all test subshells.
source "${BATS_TEST_DIRNAME}/../lib/reviewer.sh"

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template
  TEST_MOCK_DIR="$(mktemp -d)"


  # Initialize pipeline state dir for log_msg.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/locks"

  # Override personas dir to use real personas in repo.
  _REVIEWER_PERSONAS_DIR="$BATS_TEST_DIRNAME/../reviewers"
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR"
  rm -rf "$TEST_MOCK_BIN"
  rm -rf "$TEST_MOCK_DIR"
}

# --- get_repo_slug ---

@test "get_repo_slug extracts owner/repo from HTTPS URL" {
  local result
  result="$(get_repo_slug "$TEST_PROJECT_DIR")"
  [ "$result" = "testowner/testrepo" ]
}

@test "get_repo_slug extracts owner/repo from SSH URL" {
  git -C "$TEST_PROJECT_DIR" remote set-url origin \
    "git@github.com:myorg/myproject.git"
  local result
  result="$(get_repo_slug "$TEST_PROJECT_DIR")"
  [ "$result" = "myorg/myproject" ]
}

@test "get_repo_slug handles URL without .git suffix" {
  git -C "$TEST_PROJECT_DIR" remote set-url origin \
    "https://github.com/owner/repo"
  local result
  result="$(get_repo_slug "$TEST_PROJECT_DIR")"
  [ "$result" = "owner/repo" ]
}

@test "get_repo_slug fails for non-github URL" {
  git -C "$TEST_PROJECT_DIR" remote set-url origin \
    "https://gitlab.com/owner/repo.git"
  run get_repo_slug "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
}

@test "get_repo_slug fails for directory without git" {
  local no_git_dir
  no_git_dir="$(mktemp -d)"
  run get_repo_slug "$no_git_dir"
  [ "$status" -ne 0 ]
  rm -rf "$no_git_dir"
}

# --- _build_diff_header ---

@test "_build_diff_header includes PR number, branch, and repo" {
  local header
  header="$(_build_diff_header 42 "feat/my-branch" "owner/repo")"
  echo "$header" | grep -qF "PR #42"
  echo "$header" | grep -qF "feat/my-branch"
  echo "$header" | grep -qF "owner/repo"
}

@test "_build_diff_header includes separator" {
  local header
  header="$(_build_diff_header 1 "main" "a/b")"
  echo "$header" | grep -qF -- "---"
}

# --- parse_reviewer_list ---

@test "parse_reviewer_list returns default personas" {
  AUTOPILOT_REVIEWERS="general,dry,performance,security,design"
  local result
  result="$(parse_reviewer_list)"
  echo "$result" | grep -qF "general"
  echo "$result" | grep -qF "dry"
  echo "$result" | grep -qF "performance"
  echo "$result" | grep -qF "security"
  echo "$result" | grep -qF "design"
}

@test "parse_reviewer_list handles custom subset" {
  AUTOPILOT_REVIEWERS="general,security"
  local result
  result="$(parse_reviewer_list)"
  local count
  count="$(echo "$result" | wc -l | tr -d ' ')"
  [ "$count" -eq 2 ]
  echo "$result" | grep -qF "general"
  echo "$result" | grep -qF "security"
}

@test "parse_reviewer_list handles single persona" {
  AUTOPILOT_REVIEWERS="general"
  local result
  result="$(parse_reviewer_list)"
  local count
  count="$(echo "$result" | wc -l | tr -d ' ')"
  [ "$count" -eq 1 ]
  [ "$result" = "general" ]
}

@test "parse_reviewer_list strips whitespace around names" {
  AUTOPILOT_REVIEWERS="general , security , dry"
  local result
  result="$(parse_reviewer_list)"
  echo "$result" | grep -q "^general$"
  echo "$result" | grep -q "^security$"
  echo "$result" | grep -q "^dry$"
}

@test "parse_reviewer_list rejects path traversal names" {
  AUTOPILOT_REVIEWERS="general,../../etc/passwd,security"
  local result
  result="$(parse_reviewer_list)"
  local count
  count="$(echo "$result" | wc -l | tr -d ' ')"
  [ "$count" -eq 2 ]
  echo "$result" | grep -qF "general"
  echo "$result" | grep -qF "security"
}

@test "parse_reviewer_list rejects names with slashes" {
  AUTOPILOT_REVIEWERS="../secret,general"
  local result
  result="$(parse_reviewer_list)"
  [ "$result" = "general" ]
}

@test "parse_reviewer_list rejects names with uppercase" {
  AUTOPILOT_REVIEWERS="General,security"
  local result
  result="$(parse_reviewer_list)"
  [ "$result" = "security" ]
}

@test "parse_reviewer_list allows hyphens and underscores" {
  AUTOPILOT_REVIEWERS="my-custom,code_quality"
  local result
  result="$(parse_reviewer_list)"
  local count
  count="$(echo "$result" | wc -l | tr -d ' ')"
  [ "$count" -eq 2 ]
  echo "$result" | grep -qF "my-custom"
  echo "$result" | grep -qF "code_quality"
}

# --- _read_persona_file ---

@test "_read_persona_file reads general.md" {
  local result
  result="$(_read_persona_file "general")"
  echo "$result" | grep -qF "general code review"
}

@test "_read_persona_file reads security.md" {
  local result
  result="$(_read_persona_file "security")"
  echo "$result" | grep -qF "security"
}

@test "_read_persona_file reads performance.md" {
  local result
  result="$(_read_persona_file "performance")"
  echo "$result" | grep -qF "performance"
}

@test "_read_persona_file reads dry.md" {
  local result
  result="$(_read_persona_file "dry")"
  echo "$result" | grep -qF "DRY"
}

@test "_read_persona_file reads design.md" {
  local result
  result="$(_read_persona_file "design")"
  echo "$result" | grep -qF "design"
}

@test "_read_persona_file fails for nonexistent persona" {
  run _read_persona_file "nonexistent"
  [ "$status" -ne 0 ]
}

# --- is_clean_review ---

@test "is_clean_review returns true for NO_ISSUES_FOUND" {
  is_clean_review "NO_ISSUES_FOUND"
}

@test "is_clean_review returns true when sentinel is embedded" {
  is_clean_review "After review: NO_ISSUES_FOUND in this PR."
}

@test "is_clean_review returns false for actual issues" {
  run is_clean_review "1. Bug in line 42"
  [ "$status" -ne 0 ]
}

@test "is_clean_review returns false for empty string" {
  run is_clean_review ""
  [ "$status" -ne 0 ]
}

# --- fetch_pr_diff (with mocked gh/timeout) ---

@test "fetch_pr_diff fetches diff and writes to temp file" {
  # Mock gh to return branch name and diff content.
  cat > "$TEST_MOCK_DIR/gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *"headRefName"* ]]; then
  echo "feat/my-branch"
elif [[ "$1" == "pr" && "$2" == "diff" ]]; then
  echo "diff --git a/file.txt b/file.txt"
  echo "+new line"
fi
MOCK
  chmod +x "$TEST_MOCK_DIR/gh"

  # Mock timeout to pass through.
  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"

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
  # Mock gh to return a large diff.
  cat > "$TEST_MOCK_DIR/gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *"headRefName"* ]]; then
  echo "feat/big"
elif [[ "$1" == "pr" && "$2" == "diff" ]]; then
  # Generate a diff larger than 100 bytes.
  python3 -c "print('x' * 200)"
fi
MOCK
  chmod +x "$TEST_MOCK_DIR/gh"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"
  AUTOPILOT_MAX_DIFF_BYTES=100

  run fetch_pr_diff "$TEST_PROJECT_DIR" 42
  [ "$status" -eq 2 ]
}

@test "fetch_pr_diff fails when repo slug cannot be determined" {
  local no_git_dir
  no_git_dir="$(mktemp -d)"
  mkdir -p "$no_git_dir/.autopilot/logs"

  run fetch_pr_diff "$no_git_dir" 42
  [ "$status" -eq 1 ]

  rm -rf "$no_git_dir"
}

@test "fetch_pr_diff fails when gh pr view fails" {
  cat > "$TEST_MOCK_DIR/gh" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "$TEST_MOCK_DIR/gh"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"

  run fetch_pr_diff "$TEST_PROJECT_DIR" 42
  [ "$status" -eq 1 ]
}

@test "fetch_pr_diff fails when gh pr diff fails" {
  cat > "$TEST_MOCK_DIR/gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *"headRefName"* ]]; then
  echo "feat/branch"
elif [[ "$1" == "pr" && "$2" == "diff" ]]; then
  exit 1
fi
MOCK
  chmod +x "$TEST_MOCK_DIR/gh"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"

  run fetch_pr_diff "$TEST_PROJECT_DIR" 42
  [ "$status" -eq 1 ]
}

@test "fetch_pr_diff logs diff size" {
  cat > "$TEST_MOCK_DIR/gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *"headRefName"* ]]; then
  echo "feat/branch"
elif [[ "$1" == "pr" && "$2" == "diff" ]]; then
  echo "small diff"
fi
MOCK
  chmod +x "$TEST_MOCK_DIR/gh"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"

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
  # Mock claude that echoes its args.
  cat > "$TEST_MOCK_DIR/claude" <<'MOCK'
#!/usr/bin/env bash
for arg in "$@"; do
  echo "arg: $arg"
done
MOCK
  chmod +x "$TEST_MOCK_DIR/claude"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"
  AUTOPILOT_CLAUDE_CMD="$TEST_MOCK_DIR/claude"

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
  cat > "$TEST_MOCK_DIR/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"error"}'
exit 1
MOCK
  chmod +x "$TEST_MOCK_DIR/claude"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"
  AUTOPILOT_CLAUDE_CMD="$TEST_MOCK_DIR/claude"

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
  cat > "$TEST_MOCK_DIR/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"ok"}'
MOCK
  chmod +x "$TEST_MOCK_DIR/claude"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"
  AUTOPILOT_CLAUDE_CMD="$TEST_MOCK_DIR/claude"

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
  cat > "$TEST_MOCK_DIR/claude" <<'MOCK'
#!/usr/bin/env bash
echo "{\"result\":\"config=${CLAUDE_CONFIG_DIR:-unset}\"}"
MOCK
  chmod +x "$TEST_MOCK_DIR/claude"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"
  AUTOPILOT_CLAUDE_CMD="$TEST_MOCK_DIR/claude"

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

  cat > "$TEST_MOCK_DIR/claude" <<'MOCK'
#!/usr/bin/env bash
echo "{\"result\":\"claudecode=${CLAUDECODE:-unset}\"}"
MOCK
  chmod +x "$TEST_MOCK_DIR/claude"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"
  AUTOPILOT_CLAUDE_CMD="$TEST_MOCK_DIR/claude"

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
  cat > "$TEST_MOCK_DIR/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"review done"}'
MOCK
  chmod +x "$TEST_MOCK_DIR/claude"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"
  AUTOPILOT_CLAUDE_CMD="$TEST_MOCK_DIR/claude"

  local diff_file result_dir
  diff_file="$(mktemp)"
  echo "diff" > "$diff_file"
  result_dir="$(mktemp -d)"

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
  rm -rf "$result_dir"
}

@test "_spawn_reviewer_bg records non-zero exit code" {
  cat > "$TEST_MOCK_DIR/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"error"}'
exit 1
MOCK
  chmod +x "$TEST_MOCK_DIR/claude"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"
  AUTOPILOT_CLAUDE_CMD="$TEST_MOCK_DIR/claude"

  local diff_file result_dir
  diff_file="$(mktemp)"
  echo "diff" > "$diff_file"
  result_dir="$(mktemp -d)"

  _spawn_reviewer_bg "$TEST_PROJECT_DIR" "general" "$diff_file" 10 "" "$result_dir"

  local exit_code
  {
    read -r _output_file
    read -r exit_code
  } < "$result_dir/general.meta"

  [ "$exit_code" -eq 1 ]

  rm -f "$diff_file"
  rm -rf "$result_dir"
}

# --- collect_review_results ---

@test "collect_review_results reads meta files into arrays" {
  local result_dir
  result_dir="$(mktemp -d)"

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
  rm -rf "$result_dir"
}

@test "collect_review_results handles empty result directory" {
  local result_dir
  result_dir="$(mktemp -d)"

  collect_review_results "$result_dir"

  [ "${#_REVIEW_PERSONAS[@]}" -eq 0 ]

  rm -rf "$result_dir"
}

@test "collect_review_results records non-zero exit codes" {
  local result_dir
  result_dir="$(mktemp -d)"

  local output1
  output1="$(mktemp)"
  echo '{"result":"error"}' > "$output1"

  printf '%s\n%s\n' "$output1" "1" > "$result_dir/general.meta"

  collect_review_results "$result_dir"

  [ "${#_REVIEW_PERSONAS[@]}" -eq 1 ]
  [ "${_REVIEW_PERSONAS[0]}" = "general" ]
  [ "${_REVIEW_EXITS[0]}" = "1" ]

  rm -f "$output1"
  rm -rf "$result_dir"
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
  local result_dir
  result_dir="$(mktemp -d)"

  _write_timeout_meta "$result_dir" "general"

  [ -f "$result_dir/general.meta" ]

  local output_file exit_code
  {
    read -r output_file
    read -r exit_code
  } < "$result_dir/general.meta"

  [ -z "$output_file" ]
  [ "$exit_code" -eq 124 ]

  rm -rf "$result_dir"
}

@test "_write_timeout_meta does not overwrite existing meta" {
  local result_dir
  result_dir="$(mktemp -d)"

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

  rm -rf "$result_dir"
}

# --- _wait_for_reviewers ---

@test "_wait_for_reviewers writes timeout meta for killed process" {
  local result_dir
  result_dir="$(mktemp -d)"

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
  rm -rf "$result_dir"
}

@test "_wait_for_reviewers handles completed process" {
  local result_dir
  result_dir="$(mktemp -d)"

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

  rm -rf "$result_dir"
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
  cat > "$TEST_MOCK_DIR/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"NO_ISSUES_FOUND"}'
MOCK
  chmod +x "$TEST_MOCK_DIR/claude"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"
  AUTOPILOT_CLAUDE_CMD="$TEST_MOCK_DIR/claude"
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
  cat > "$TEST_MOCK_DIR/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"1. Bug found"}'
MOCK
  chmod +x "$TEST_MOCK_DIR/claude"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"
  AUTOPILOT_CLAUDE_CMD="$TEST_MOCK_DIR/claude"
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
  cat > "$TEST_MOCK_DIR/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"ok"}'
MOCK
  chmod +x "$TEST_MOCK_DIR/claude"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"
  AUTOPILOT_CLAUDE_CMD="$TEST_MOCK_DIR/claude"
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
  cat > "$TEST_MOCK_DIR/claude" <<'MOCK'
#!/usr/bin/env bash
echo "{\"result\":\"config=${CLAUDE_CONFIG_DIR:-unset}\"}"
MOCK
  chmod +x "$TEST_MOCK_DIR/claude"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"
  AUTOPILOT_CLAUDE_CMD="$TEST_MOCK_DIR/claude"
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

@test "run_reviewers handles all five default reviewers" {
  cat > "$TEST_MOCK_DIR/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"NO_ISSUES_FOUND"}'
MOCK
  chmod +x "$TEST_MOCK_DIR/claude"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"
  AUTOPILOT_CLAUDE_CMD="$TEST_MOCK_DIR/claude"
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
