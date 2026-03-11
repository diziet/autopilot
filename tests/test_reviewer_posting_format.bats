#!/usr/bin/env bats
# Tests for reviewer-posting.sh — persona display names, comment formatting,
# post_pr_comment, JSON helpers, SHA tracking, and review status checks.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/reviewer-posting.sh"

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template_nogit
  export TEST_MOCK_DIR="$BATS_TEST_TMPDIR/test_mock_dir"
  mkdir -p "$TEST_MOCK_DIR"

  # Source reviewer-posting.sh (which sources reviewer, config, state, etc.).
  load_config "$TEST_PROJECT_DIR"

  # Initialize pipeline state dir for log_msg.
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/locks"

  # Override personas dir to use real personas in repo.
  _REVIEWER_PERSONAS_DIR="$BATS_TEST_DIRNAME/../reviewers"
}

# --- _persona_display_name ---

@test "_persona_display_name returns General for general" {
  local result
  result="$(_persona_display_name "general")"
  [ "$result" = "General" ]
}

@test "_persona_display_name returns Security for security" {
  local result
  result="$(_persona_display_name "security")"
  [ "$result" = "Security" ]
}

@test "_persona_display_name returns Performance for performance" {
  local result
  result="$(_persona_display_name "performance")"
  [ "$result" = "Performance" ]
}

@test "_persona_display_name returns DRY for dry" {
  local result
  result="$(_persona_display_name "dry")"
  [ "$result" = "DRY" ]
}

@test "_persona_display_name returns Design for design" {
  local result
  result="$(_persona_display_name "design")"
  [ "$result" = "Design" ]
}

@test "_persona_display_name echoes unknown persona name as-is" {
  local result
  result="$(_persona_display_name "custom-reviewer")"
  [ "$result" = "custom-reviewer" ]
}

# --- format_review_comment ---

@test "format_review_comment includes display name" {
  local result
  result="$(format_review_comment "general" "abc1234567890" "Found 2 bugs.")"
  echo "$result" | grep -qF "General Review"
}

@test "format_review_comment includes SHA tag in HTML comment" {
  local result
  result="$(format_review_comment "security" "abc1234567890def" "Issue found.")"
  echo "$result" | grep -qF "sha=abc1234567890def"
}

@test "format_review_comment includes persona name in HTML comment" {
  local result
  result="$(format_review_comment "dry" "abc1234" "Duplication found.")"
  echo "$result" | grep -qF "reviewer=dry"
}

@test "format_review_comment includes review text" {
  local review_text="1. Bug on line 42
2. Missing error handling"
  local result
  result="$(format_review_comment "general" "abc1234" "$review_text")"
  echo "$result" | grep -qF "Bug on line 42"
  echo "$result" | grep -qF "Missing error handling"
}

@test "format_review_comment includes short SHA in footer" {
  local result
  result="$(format_review_comment "general" "abc1234567890" "Review text.")"
  echo "$result" | grep -qF "abc1234"
}

@test "format_review_comment uses DRY display name for dry persona" {
  local result
  result="$(format_review_comment "dry" "abc1234567890" "Code duplication.")"
  echo "$result" | grep -qF "DRY Review"
}

# --- post_pr_comment ---

@test "post_pr_comment calls gh pr comment with correct args" {
  # Mock gh to record its arguments.
  cat > "$TEST_MOCK_DIR/gh" <<'MOCK'
#!/usr/bin/env bash
echo "$@" > "$TEST_MOCK_DIR/gh_args.log"
MOCK
  chmod +x "$TEST_MOCK_DIR/gh"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"

  post_pr_comment "$TEST_PROJECT_DIR" 42 "Review body here"

  local gh_args
  gh_args="$(cat "$TEST_MOCK_DIR/gh_args.log")"
  echo "$gh_args" | grep -qF "pr comment 42"
  echo "$gh_args" | grep -qF "testowner/testrepo"
  echo "$gh_args" | grep -qF "Review body here"
}

@test "post_pr_comment returns error when gh fails" {
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

  run post_pr_comment "$TEST_PROJECT_DIR" 42 "body"
  [ "$status" -ne 0 ]
}

@test "post_pr_comment returns error when repo slug fails" {
  get_repo_slug() { return 1; }
  export -f get_repo_slug

  run post_pr_comment "$TEST_PROJECT_DIR" 42 "body"
  [ "$status" -ne 0 ]
}

@test "post_pr_comment logs success" {
  cat > "$TEST_MOCK_DIR/gh" <<'MOCK'
#!/usr/bin/env bash
true
MOCK
  chmod +x "$TEST_MOCK_DIR/gh"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"

  post_pr_comment "$TEST_PROJECT_DIR" 99 "Test comment"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  echo "$log_content" | grep -qF "Posted review comment on PR #99"
}

# --- _read_reviewed_json / _write_reviewed_json ---

@test "_read_reviewed_json returns empty object when file missing" {
  local result
  result="$(_read_reviewed_json "$TEST_PROJECT_DIR")"
  [ "$result" = "{}" ]
}

@test "_read_reviewed_json returns file content when exists" {
  echo '{"pr_42":{"general":"abc123"}}' \
    > "$TEST_PROJECT_DIR/.autopilot/reviewed.json"

  local result
  result="$(_read_reviewed_json "$TEST_PROJECT_DIR")"
  echo "$result" | grep -qF "abc123"
}

@test "_write_reviewed_json creates file atomically" {
  _write_reviewed_json "$TEST_PROJECT_DIR" '{"pr_1":{"general":"sha1"}}'

  [ -f "$TEST_PROJECT_DIR/.autopilot/reviewed.json" ]
  local content
  content="$(cat "$TEST_PROJECT_DIR/.autopilot/reviewed.json")"
  echo "$content" | grep -qF "sha1"
}

@test "_write_reviewed_json creates .autopilot dir if missing" {
  rm -rf "$TEST_PROJECT_DIR/.autopilot"
  _write_reviewed_json "$TEST_PROJECT_DIR" '{"test":"value"}'
  [ -f "$TEST_PROJECT_DIR/.autopilot/reviewed.json" ]
}

# --- get_reviewed_sha / set_reviewed_sha ---

@test "get_reviewed_sha returns empty for untracked PR" {
  local result
  result="$(get_reviewed_sha "$TEST_PROJECT_DIR" 42 "general")"
  [ -z "$result" ]
}

@test "set_reviewed_sha records SHA and get retrieves it" {
  set_reviewed_sha "$TEST_PROJECT_DIR" 42 "general" "abc123def"

  local result
  result="$(get_reviewed_sha "$TEST_PROJECT_DIR" 42 "general")"
  [ "$result" = "abc123def" ]
}

@test "set_reviewed_sha handles multiple personas on same PR" {
  set_reviewed_sha "$TEST_PROJECT_DIR" 42 "general" "sha_g"
  set_reviewed_sha "$TEST_PROJECT_DIR" 42 "security" "sha_s"

  local result_g result_s
  result_g="$(get_reviewed_sha "$TEST_PROJECT_DIR" 42 "general")"
  result_s="$(get_reviewed_sha "$TEST_PROJECT_DIR" 42 "security")"
  [ "$result_g" = "sha_g" ]
  [ "$result_s" = "sha_s" ]
}

@test "set_reviewed_sha handles multiple PRs" {
  set_reviewed_sha "$TEST_PROJECT_DIR" 42 "general" "sha_42"
  set_reviewed_sha "$TEST_PROJECT_DIR" 99 "general" "sha_99"

  local result_42 result_99
  result_42="$(get_reviewed_sha "$TEST_PROJECT_DIR" 42 "general")"
  result_99="$(get_reviewed_sha "$TEST_PROJECT_DIR" 99 "general")"
  [ "$result_42" = "sha_42" ]
  [ "$result_99" = "sha_99" ]
}

@test "set_reviewed_sha updates existing SHA" {
  set_reviewed_sha "$TEST_PROJECT_DIR" 42 "general" "old_sha"
  set_reviewed_sha "$TEST_PROJECT_DIR" 42 "general" "new_sha"

  local result
  result="$(get_reviewed_sha "$TEST_PROJECT_DIR" 42 "general")"
  [ "$result" = "new_sha" ]
}

# --- has_been_reviewed ---

@test "has_been_reviewed returns false for new PR" {
  run has_been_reviewed "$TEST_PROJECT_DIR" 42 "general" "abc123"
  [ "$status" -ne 0 ]
}

@test "has_been_reviewed returns true for matching SHA" {
  set_reviewed_sha "$TEST_PROJECT_DIR" 42 "general" "abc123"
  has_been_reviewed "$TEST_PROJECT_DIR" 42 "general" "abc123"
}

@test "has_been_reviewed returns false for different SHA" {
  set_reviewed_sha "$TEST_PROJECT_DIR" 42 "general" "abc123"
  run has_been_reviewed "$TEST_PROJECT_DIR" 42 "general" "def456"
  [ "$status" -ne 0 ]
}

@test "has_been_reviewed returns false for different persona" {
  set_reviewed_sha "$TEST_PROJECT_DIR" 42 "general" "abc123"
  run has_been_reviewed "$TEST_PROJECT_DIR" 42 "security" "abc123"
  [ "$status" -ne 0 ]
}

# --- was_review_clean ---

@test "was_review_clean returns true for stored clean review" {
  set_reviewed_sha "$TEST_PROJECT_DIR" 42 "general" "sha123" "true"
  was_review_clean "$TEST_PROJECT_DIR" 42 "general"
}

@test "was_review_clean returns false for stored dirty review" {
  set_reviewed_sha "$TEST_PROJECT_DIR" 42 "general" "sha123" "false"
  run was_review_clean "$TEST_PROJECT_DIR" 42 "general"
  [ "$status" -ne 0 ]
}

@test "was_review_clean returns false for missing persona" {
  run was_review_clean "$TEST_PROJECT_DIR" 42 "general"
  [ "$status" -ne 0 ]
}

@test "set_reviewed_sha stores clean status in reviewed.json" {
  set_reviewed_sha "$TEST_PROJECT_DIR" 42 "general" "sha123" "true"

  local json_content
  json_content="$(cat "$TEST_PROJECT_DIR/.autopilot/reviewed.json")"
  local is_clean
  is_clean="$(jq -r '.pr_42.general.is_clean' <<< "$json_content")"
  [ "$is_clean" = "true" ]
}
