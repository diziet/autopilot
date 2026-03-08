#!/usr/bin/env bats
# Tests for lib/codex-reviewer.sh — Codex availability check, finding
# extraction, confidence filtering, inline comment posting, and graceful skip.

load helpers/test_template

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template
  TEST_MOCK_DIR="$(mktemp -d)"

  # Source codex-reviewer.sh (which sources config, state, git-ops).
  source "$BATS_TEST_DIRNAME/../lib/codex-reviewer.sh"
  load_config "$TEST_PROJECT_DIR"

  # Initialize pipeline state dir for log_msg.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/locks"
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR"
  rm -rf "$TEST_MOCK_DIR"
}

# --- is_codex_available ---

@test "is_codex_available returns false when codex not on PATH" {
  # Ensure codex is not in the test PATH.
  run is_codex_available
  [ "$status" -ne 0 ]
}

@test "is_codex_available returns true when codex is on PATH" {
  cat > "$TEST_MOCK_DIR/codex" <<'MOCK'
#!/usr/bin/env bash
echo "codex mock"
MOCK
  chmod +x "$TEST_MOCK_DIR/codex"
  export PATH="$TEST_MOCK_DIR:$PATH"

  is_codex_available
}

# --- _build_codex_prompt ---

@test "_build_codex_prompt includes diff content" {
  local diff_file
  diff_file="$(mktemp)"
  echo "diff --git a/file.sh b/file.sh" > "$diff_file"
  echo "+new line" >> "$diff_file"

  local result
  result="$(_build_codex_prompt "$diff_file")"
  echo "$result" | grep -qF "code reviewer"
  echo "$result" | grep -qF "+new line"

  rm -f "$diff_file"
}

# --- extract_codex_findings ---

@test "extract_codex_findings returns findings above threshold" {
  local output_file
  output_file="$(mktemp)"
  cat > "$output_file" <<'JSON'
{
  "findings": [
    {
      "title": "Bug in loop",
      "body": "Off-by-one error",
      "code_location": {"absolute_file_path": "src/main.sh", "line_range": {"start": 10, "end": 12}},
      "confidence_score": 0.9
    },
    {
      "title": "Style issue",
      "body": "Minor naming",
      "code_location": {"absolute_file_path": "src/util.sh", "line_range": {"start": 5, "end": 5}},
      "confidence_score": 0.4
    }
  ]
}
JSON

  AUTOPILOT_CODEX_MIN_CONFIDENCE="0.7"
  local result
  result="$(extract_codex_findings "$output_file")"

  # Should include the high-confidence finding.
  echo "$result" | grep -qF "Bug in loop"

  # Should NOT include the low-confidence finding.
  local low_count
  low_count="$(echo "$result" | grep -c "Style issue" || true)"
  [ "$low_count" -eq 0 ]

  rm -f "$output_file"
}

@test "extract_codex_findings returns nothing for empty findings" {
  local output_file
  output_file="$(mktemp)"
  echo '{"findings": []}' > "$output_file"

  local result
  result="$(extract_codex_findings "$output_file")" || true
  [ -z "$result" ]

  rm -f "$output_file"
}

@test "extract_codex_findings returns nothing for missing file" {
  run extract_codex_findings "/nonexistent/file"
  [ "$status" -ne 0 ]
}

# --- count_codex_findings ---

@test "count_codex_findings counts only above-threshold findings" {
  local output_file
  output_file="$(mktemp)"
  cat > "$output_file" <<'JSON'
{
  "findings": [
    {"title": "A", "body": "a", "code_location": {"absolute_file_path": "f.sh", "line_range": {"start": 1, "end": 1}}, "confidence_score": 0.9},
    {"title": "B", "body": "b", "code_location": {"absolute_file_path": "f.sh", "line_range": {"start": 2, "end": 2}}, "confidence_score": 0.8},
    {"title": "C", "body": "c", "code_location": {"absolute_file_path": "f.sh", "line_range": {"start": 3, "end": 3}}, "confidence_score": 0.3}
  ]
}
JSON

  AUTOPILOT_CODEX_MIN_CONFIDENCE="0.7"
  local count
  count="$(count_codex_findings "$output_file")"
  [ "$count" -eq 2 ]

  rm -f "$output_file"
}

@test "count_codex_findings returns 0 for empty file" {
  local output_file
  output_file="$(mktemp)"
  echo "" > "$output_file"

  local count
  count="$(count_codex_findings "$output_file")"
  [ "$count" -eq 0 ]

  rm -f "$output_file"
}

# --- run_codex_review ---

@test "run_codex_review skips when codex not installed" {
  # No codex mock on PATH.
  run run_codex_review "$TEST_PROJECT_DIR" "/dev/null" 10
  [ "$status" -eq 1 ]
}

@test "run_codex_review calls codex exec and returns output file" {
  # Mock codex that outputs valid JSON findings.
  cat > "$TEST_MOCK_DIR/codex" <<'MOCK'
#!/usr/bin/env bash
echo '{"findings": [{"title": "Test", "body": "Test body", "code_location": {"absolute_file_path": "f.sh", "line_range": {"start": 1, "end": 1}}, "confidence_score": 0.9}]}'
MOCK
  chmod +x "$TEST_MOCK_DIR/codex"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"

  local diff_file
  diff_file="$(mktemp)"
  echo "diff content" > "$diff_file"

  local output_file
  output_file="$(run_codex_review "$TEST_PROJECT_DIR" "$diff_file" 10)"

  [ -f "$output_file" ]

  local content
  content="$(cat "$output_file")"
  echo "$content" | grep -qF '"findings"'

  rm -f "$diff_file" "$output_file" "${output_file}.err"
}

@test "run_codex_review logs completion on success" {
  cat > "$TEST_MOCK_DIR/codex" <<'MOCK'
#!/usr/bin/env bash
echo '{"findings": []}'
MOCK
  chmod +x "$TEST_MOCK_DIR/codex"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"

  local diff_file
  diff_file="$(mktemp)"
  echo "diff" > "$diff_file"

  run_codex_review "$TEST_PROJECT_DIR" "$diff_file" 10 || true

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  echo "$log_content" | grep -qF "Codex review completed"

  rm -f "$diff_file"
}

# --- post_codex_findings ---

@test "post_codex_findings posts inline comments via gh api" {
  # Mock gh api for inline comments.
  cat > "$TEST_MOCK_DIR/gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == *"comments"* ]]; then
  echo "posted"
  exit 0
fi
exit 0
MOCK
  chmod +x "$TEST_MOCK_DIR/gh"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"

  local output_file
  output_file="$(mktemp)"
  cat > "$output_file" <<'JSON'
{
  "findings": [
    {
      "title": "Missing error check",
      "body": "Should check return code",
      "code_location": {"absolute_file_path": "lib/main.sh", "line_range": {"start": 42, "end": 44}},
      "confidence_score": 0.95
    }
  ]
}
JSON

  AUTOPILOT_CODEX_MIN_CONFIDENCE="0.7"
  post_codex_findings "$TEST_PROJECT_DIR" 42 "abc123" "$output_file"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  echo "$log_content" | grep -qF "Posting 1 Codex findings"
  echo "$log_content" | grep -qF "posted=1"

  rm -f "$output_file"
}

@test "post_codex_findings skips when no findings above threshold" {
  local output_file
  output_file="$(mktemp)"
  cat > "$output_file" <<'JSON'
{
  "findings": [
    {
      "title": "Low confidence",
      "body": "Maybe an issue",
      "code_location": {"absolute_file_path": "f.sh", "line_range": {"start": 1, "end": 1}},
      "confidence_score": 0.3
    }
  ]
}
JSON

  AUTOPILOT_CODEX_MIN_CONFIDENCE="0.7"
  post_codex_findings "$TEST_PROJECT_DIR" 42 "abc123" "$output_file"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  echo "$log_content" | grep -qF "no findings above confidence threshold"

  rm -f "$output_file"
}

# --- run_codex_review_pipeline ---

@test "run_codex_review_pipeline skips gracefully when codex not installed" {
  # No codex mock → not available.
  run run_codex_review_pipeline "$TEST_PROJECT_DIR" 42 "/dev/null" "abc123" 10
  [ "$status" -ne 0 ]

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  echo "$log_content" | grep -qF "Codex CLI not installed"
}

@test "run_codex_review_pipeline runs full cycle with mock codex" {
  cat > "$TEST_MOCK_DIR/codex" <<'MOCK'
#!/usr/bin/env bash
cat <<'JSON'
{
  "findings": [
    {
      "title": "Unquoted variable",
      "body": "Variable $foo should be quoted",
      "code_location": {"absolute_file_path": "lib/utils.sh", "line_range": {"start": 15, "end": 15}},
      "confidence_score": 0.85
    }
  ]
}
JSON
MOCK
  chmod +x "$TEST_MOCK_DIR/codex"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  # gh mock for inline comment posting.
  cat > "$TEST_MOCK_DIR/gh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "$TEST_MOCK_DIR/gh"

  export PATH="$TEST_MOCK_DIR:$PATH"

  local diff_file
  diff_file="$(mktemp)"
  echo "diff content" > "$diff_file"

  AUTOPILOT_CODEX_MIN_CONFIDENCE="0.7"
  run_codex_review_pipeline "$TEST_PROJECT_DIR" 42 "$diff_file" "abc123" 10

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  echo "$log_content" | grep -qF "Codex review completed"
  echo "$log_content" | grep -qF "Posting 1 Codex findings"

  rm -f "$diff_file"
}

# --- reviewer.sh integration: codex skipped in Claude persona list ---

@test "parse_reviewer_list includes codex in the list" {
  source "$BATS_TEST_DIRNAME/../lib/reviewer.sh"
  AUTOPILOT_REVIEWERS="general,codex,security"

  local result
  result="$(parse_reviewer_list)"
  echo "$result" | grep -qF "codex"
}

@test "run_reviewers skips codex from Claude persona spawning" {
  source "$BATS_TEST_DIRNAME/../lib/reviewer.sh"

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
  AUTOPILOT_REVIEWERS="general,codex"
  AUTOPILOT_TIMEOUT_REVIEWER=30
  AUTOPILOT_TIMEOUT_REVIEWER_CLAUDE=10

  # Override personas dir to use real personas.
  _REVIEWER_PERSONAS_DIR="$BATS_TEST_DIRNAME/../reviewers"

  local diff_file
  diff_file="$(mktemp)"
  echo "diff" > "$diff_file"

  local result_dir
  result_dir="$(run_reviewers "$TEST_PROJECT_DIR" 42 "$diff_file")"

  # Should have general.meta but NOT codex.meta (codex is not a Claude persona).
  [ -f "$result_dir/general.meta" ]
  [ ! -f "$result_dir/codex.meta" ]

  rm -f "$diff_file"
  rm -rf "$result_dir"
}

# --- autopilot-doctor codex checks ---

@test "doctor _check_codex_reviewer passes when codex is on PATH and API key set" {
  source "$BATS_TEST_DIRNAME/../bin/autopilot-doctor" 2>/dev/null || true

  # Override helpers since doctor defines them at top level.
  _DOCTOR_FAILURES=0
  _CONFIG_LOADED=true
  _pass() { echo "[PASS] $1"; }
  _fail() { echo "[FAIL] $1"; _DOCTOR_FAILURES=$((_DOCTOR_FAILURES + 1)); }

  cat > "$TEST_MOCK_DIR/codex" <<'MOCK'
#!/usr/bin/env bash
echo "codex"
MOCK
  chmod +x "$TEST_MOCK_DIR/codex"
  export PATH="$TEST_MOCK_DIR:$PATH"

  AUTOPILOT_REVIEWERS="general,codex"
  OPENAI_API_KEY="sk-test-key"

  local output
  output="$(_check_codex_reviewer)"
  echo "$output" | grep -qF "[PASS] codex CLI found"
  echo "$output" | grep -qF "[PASS] OPENAI_API_KEY is set"
  [ "$_DOCTOR_FAILURES" -eq 0 ]
}

@test "doctor _check_codex_reviewer fails when codex not installed" {
  source "$BATS_TEST_DIRNAME/../bin/autopilot-doctor" 2>/dev/null || true

  _DOCTOR_FAILURES=0
  _CONFIG_LOADED=true
  _pass() { echo "[PASS] $1"; }
  _fail() { echo "[FAIL] $1"; _DOCTOR_FAILURES=$((_DOCTOR_FAILURES + 1)); }

  # No codex on PATH, no API key.
  AUTOPILOT_REVIEWERS="general,codex"
  unset OPENAI_API_KEY

  local output
  output="$(_check_codex_reviewer)"
  echo "$output" | grep -qF "[FAIL] codex CLI not found"
  echo "$output" | grep -qF "[FAIL] OPENAI_API_KEY not set"
  [ "$_DOCTOR_FAILURES" -eq 2 ]
}

@test "doctor _check_codex_reviewer skips when codex not in reviewer list" {
  source "$BATS_TEST_DIRNAME/../bin/autopilot-doctor" 2>/dev/null || true

  _DOCTOR_FAILURES=0
  _CONFIG_LOADED=true
  _pass() { echo "[PASS] $1"; }
  _fail() { echo "[FAIL] $1"; _DOCTOR_FAILURES=$((_DOCTOR_FAILURES + 1)); }

  AUTOPILOT_REVIEWERS="general,security"

  local output
  output="$(_check_codex_reviewer)"
  [ -z "$output" ]
  [ "$_DOCTOR_FAILURES" -eq 0 ]
}
