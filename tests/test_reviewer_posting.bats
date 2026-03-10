#!/usr/bin/env bats
# Tests for lib/reviewer-posting.sh — comment formatting, PR posting,
# reviewed SHA tracking, clean-review detection, and orchestration.

load helpers/test_template

# File-level source — loaded once, inherited by every test.
source "$(dirname "$BATS_TEST_FILENAME")/../lib/reviewer-posting.sh"

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template_light
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
  local no_git_dir="$BATS_TEST_TMPDIR/no_git_dir"
  mkdir -p "$no_git_dir/.autopilot/logs"

  run post_pr_comment "$no_git_dir" 42 "body"
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

# --- all_reviews_clean ---

@test "all_reviews_clean returns true when all NO_ISSUES_FOUND" {
  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"

  local out1="$BATS_TEST_TMPDIR/out1"
  local out2="$BATS_TEST_TMPDIR/out2"
  echo '{"result":"NO_ISSUES_FOUND"}' > "$out1"
  echo '{"result":"After review: NO_ISSUES_FOUND in this PR."}' > "$out2"

  printf '%s\n%s\n' "$out1" "0" > "$result_dir/general.meta"
  printf '%s\n%s\n' "$out2" "0" > "$result_dir/security.meta"

  all_reviews_clean "$result_dir"
  [ "$_ALL_REVIEWS_CLEAN" = "true" ]
}

@test "all_reviews_clean returns false when one has issues" {
  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"

  local out1="$BATS_TEST_TMPDIR/out1"
  local out2="$BATS_TEST_TMPDIR/out2"
  echo '{"result":"NO_ISSUES_FOUND"}' > "$out1"
  echo '{"result":"1. Bug found on line 10"}' > "$out2"

  printf '%s\n%s\n' "$out1" "0" > "$result_dir/general.meta"
  printf '%s\n%s\n' "$out2" "0" > "$result_dir/security.meta"

  run all_reviews_clean "$result_dir"
  [ "$status" -ne 0 ]
}

@test "all_reviews_clean returns false when a reviewer failed" {
  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"

  local out1="$BATS_TEST_TMPDIR/out1"
  echo '{"result":"NO_ISSUES_FOUND"}' > "$out1"

  printf '%s\n%s\n' "$out1" "0" > "$result_dir/general.meta"
  printf '%s\n%s\n' "" "124" > "$result_dir/security.meta"

  run all_reviews_clean "$result_dir"
  [ "$status" -ne 0 ]
}

@test "all_reviews_clean returns false for empty result directory" {
  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"

  run all_reviews_clean "$result_dir"
  [ "$status" -ne 0 ]
}

@test "all_reviews_clean returns false when output file missing" {
  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"

  printf '%s\n%s\n' "/nonexistent/file" "0" > "$result_dir/general.meta"

  run all_reviews_clean "$result_dir"
  [ "$status" -ne 0 ]
}

@test "all_reviews_clean works with single clean reviewer" {
  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"

  local out1="$BATS_TEST_TMPDIR/out1"
  echo '{"result":"NO_ISSUES_FOUND"}' > "$out1"

  printf '%s\n%s\n' "$out1" "0" > "$result_dir/general.meta"

  all_reviews_clean "$result_dir"
  [ "$_ALL_REVIEWS_CLEAN" = "true" ]
}

# --- post_review_comments ---

@test "post_review_comments posts dirty review via gh" {
  # Mock gh to record calls.
  cat > "$TEST_MOCK_DIR/gh" <<'MOCK'
#!/usr/bin/env bash
echo "$@" >> "$TEST_MOCK_DIR/gh_calls.log"
MOCK
  chmod +x "$TEST_MOCK_DIR/gh"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"

  # Set up result dir with one dirty review.
  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"
  local out1="$BATS_TEST_TMPDIR/out1"
  echo '{"result":"1. Bug on line 42."}' > "$out1"
  printf '%s\n%s\n' "$out1" "0" > "$result_dir/general.meta"

  post_review_comments "$TEST_PROJECT_DIR" 42 "abc1234567890" "$result_dir"

  # Should have called gh pr comment.
  [ -f "$TEST_MOCK_DIR/gh_calls.log" ]
  grep -qF "pr comment 42" "$TEST_MOCK_DIR/gh_calls.log"
}

@test "post_review_comments posts comment for clean review" {
  cat > "$TEST_MOCK_DIR/gh" <<'MOCK'
#!/usr/bin/env bash
echo "$@" >> "$TEST_MOCK_DIR/gh_calls.log"
MOCK
  chmod +x "$TEST_MOCK_DIR/gh"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"

  # Set up result dir with clean review.
  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"
  local out1="$BATS_TEST_TMPDIR/out1"
  echo '{"result":"NO_ISSUES_FOUND"}' > "$out1"
  printf '%s\n%s\n' "$out1" "0" > "$result_dir/general.meta"

  post_review_comments "$TEST_PROJECT_DIR" 42 "abc1234567890" "$result_dir"

  # Should have called gh pr comment.
  [ -f "$TEST_MOCK_DIR/gh_calls.log" ]
  grep -qF "pr comment 42" "$TEST_MOCK_DIR/gh_calls.log"
  # Comment body should contain "No issues found." instead of the sentinel.
  grep -qF "No issues found." "$TEST_MOCK_DIR/gh_calls.log"
  grep -qF "General Review" "$TEST_MOCK_DIR/gh_calls.log"
}

@test "post_review_comments sets _ALL_REVIEWS_CLEAN true when all clean" {
  cat > "$TEST_MOCK_DIR/gh" <<'MOCK'
#!/usr/bin/env bash
echo "$@" >> "$TEST_MOCK_DIR/gh_calls.log"
MOCK
  chmod +x "$TEST_MOCK_DIR/gh"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"

  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"

  local out1="$BATS_TEST_TMPDIR/out1"
  local out2="$BATS_TEST_TMPDIR/out2"
  echo '{"result":"NO_ISSUES_FOUND"}' > "$out1"
  echo '{"result":"NO_ISSUES_FOUND"}' > "$out2"

  printf '%s\n%s\n' "$out1" "0" > "$result_dir/general.meta"
  printf '%s\n%s\n' "$out2" "0" > "$result_dir/security.meta"

  post_review_comments "$TEST_PROJECT_DIR" 42 "abc123" "$result_dir"

  [ "$_ALL_REVIEWS_CLEAN" = "true" ]

  # Both clean reviews should have been posted.
  [ -f "$TEST_MOCK_DIR/gh_calls.log" ]
}

@test "post_review_comments sets _ALL_REVIEWS_CLEAN false when mixed" {
  echo "0" > "$TEST_MOCK_DIR/gh_call_count"
  cat > "$TEST_MOCK_DIR/gh" <<'MOCK'
#!/usr/bin/env bash
count="$(cat "$TEST_MOCK_DIR/gh_call_count")"
echo "$((count + 1))" > "$TEST_MOCK_DIR/gh_call_count"
MOCK
  chmod +x "$TEST_MOCK_DIR/gh"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"

  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"

  local out1="$BATS_TEST_TMPDIR/out1"
  local out2="$BATS_TEST_TMPDIR/out2"
  echo '{"result":"NO_ISSUES_FOUND"}' > "$out1"
  echo '{"result":"Found a bug."}' > "$out2"

  printf '%s\n%s\n' "$out1" "0" > "$result_dir/general.meta"
  printf '%s\n%s\n' "$out2" "0" > "$result_dir/security.meta"

  post_review_comments "$TEST_PROJECT_DIR" 42 "abc123" "$result_dir"

  [ "$_ALL_REVIEWS_CLEAN" = "false" ]

  # Both reviews should be posted (dirty + clean).
  local call_count
  call_count="$(cat "$TEST_MOCK_DIR/gh_call_count")"
  [ "$call_count" -eq 2 ]
}

@test "post_review_comments skips already-reviewed SHA" {
  cat > "$TEST_MOCK_DIR/gh" <<'MOCK'
#!/usr/bin/env bash
echo "$@" >> "$TEST_MOCK_DIR/gh_calls.log"
MOCK
  chmod +x "$TEST_MOCK_DIR/gh"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"

  # Pre-set reviewed SHA.
  set_reviewed_sha "$TEST_PROJECT_DIR" 42 "general" "abc123"

  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"
  local out1="$BATS_TEST_TMPDIR/out1"
  echo '{"result":"1. Bug found."}' > "$out1"
  printf '%s\n%s\n' "$out1" "0" > "$result_dir/general.meta"

  post_review_comments "$TEST_PROJECT_DIR" 42 "abc123" "$result_dir"

  # Should NOT have called gh (skipped due to same SHA).
  [ ! -f "$TEST_MOCK_DIR/gh_calls.log" ]

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  echo "$log_content" | grep -qF "already reviewed SHA"
}

@test "post_review_comments posts on new SHA after previous review" {
  cat > "$TEST_MOCK_DIR/gh" <<'MOCK'
#!/usr/bin/env bash
echo "$@" >> "$TEST_MOCK_DIR/gh_calls.log"
MOCK
  chmod +x "$TEST_MOCK_DIR/gh"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"

  # Previous review was for old SHA.
  set_reviewed_sha "$TEST_PROJECT_DIR" 42 "general" "old_sha"

  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"
  local out1="$BATS_TEST_TMPDIR/out1"
  echo '{"result":"1. New bug."}' > "$out1"
  printf '%s\n%s\n' "$out1" "0" > "$result_dir/general.meta"

  post_review_comments "$TEST_PROJECT_DIR" 42 "new_sha" "$result_dir"

  # Should have posted since SHA changed.
  [ -f "$TEST_MOCK_DIR/gh_calls.log" ]
  grep -qF "pr comment 42" "$TEST_MOCK_DIR/gh_calls.log"
}

@test "post_review_comments records SHA for clean reviews too" {
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

  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"
  local out1="$BATS_TEST_TMPDIR/out1"
  echo '{"result":"NO_ISSUES_FOUND"}' > "$out1"
  printf '%s\n%s\n' "$out1" "0" > "$result_dir/general.meta"

  post_review_comments "$TEST_PROJECT_DIR" 42 "sha123" "$result_dir"

  # SHA should be recorded even though review was clean.
  local recorded_sha
  recorded_sha="$(get_reviewed_sha "$TEST_PROJECT_DIR" 42 "general")"
  [ "$recorded_sha" = "sha123" ]
}

@test "post_review_comments skips failed reviewers" {
  # Mock gh that increments a counter file per invocation.
  echo "0" > "$TEST_MOCK_DIR/gh_call_count"
  cat > "$TEST_MOCK_DIR/gh" <<'MOCK'
#!/usr/bin/env bash
count="$(cat "$TEST_MOCK_DIR/gh_call_count")"
echo "$((count + 1))" > "$TEST_MOCK_DIR/gh_call_count"
MOCK
  chmod +x "$TEST_MOCK_DIR/gh"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"

  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"

  # One successful, one failed.
  local out1="$BATS_TEST_TMPDIR/out1"
  echo '{"result":"Bug found."}' > "$out1"
  printf '%s\n%s\n' "$out1" "0" > "$result_dir/general.meta"
  printf '%s\n%s\n' "" "124" > "$result_dir/security.meta"

  post_review_comments "$TEST_PROJECT_DIR" 42 "sha123" "$result_dir"

  # Only the successful review should be posted (1 gh call).
  local call_count
  call_count="$(cat "$TEST_MOCK_DIR/gh_call_count")"
  [ "$call_count" -eq 1 ]

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  echo "$log_content" | grep -qF "Skipping security review: exited with 124"
}

@test "post_review_comments handles empty result directory" {
  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"
  export PATH="$TEST_MOCK_DIR:$PATH"

  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"

  post_review_comments "$TEST_PROJECT_DIR" 42 "sha123" "$result_dir"

  [ "$_ALL_REVIEWS_CLEAN" = "false" ]

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  echo "$log_content" | grep -qF "No review results to post"
}

@test "post_review_comments skips reviewer with empty response" {
  cat > "$TEST_MOCK_DIR/gh" <<'MOCK'
#!/usr/bin/env bash
echo "$@" >> "$TEST_MOCK_DIR/gh_calls.log"
MOCK
  chmod +x "$TEST_MOCK_DIR/gh"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"

  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"

  # Output file with invalid JSON (empty result).
  local out1="$BATS_TEST_TMPDIR/out1"
  echo 'not json' > "$out1"
  printf '%s\n%s\n' "$out1" "0" > "$result_dir/general.meta"

  post_review_comments "$TEST_PROJECT_DIR" 42 "sha123" "$result_dir"

  # Should not post — empty result text.
  [ ! -f "$TEST_MOCK_DIR/gh_calls.log" ]

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  echo "$log_content" | grep -qF "Skipping general review: empty response"
}

@test "post_review_comments logs summary counts" {
  cat > "$TEST_MOCK_DIR/gh" <<'MOCK'
#!/usr/bin/env bash
echo "$@" >> "$TEST_MOCK_DIR/gh_calls.log"
MOCK
  chmod +x "$TEST_MOCK_DIR/gh"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"

  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"

  local out1="$BATS_TEST_TMPDIR/out1"
  local out2="$BATS_TEST_TMPDIR/out2"
  echo '{"result":"1. Found bug."}' > "$out1"
  echo '{"result":"NO_ISSUES_FOUND"}' > "$out2"

  printf '%s\n%s\n' "$out1" "0" > "$result_dir/general.meta"
  printf '%s\n%s\n' "$out2" "0" > "$result_dir/security.meta"

  post_review_comments "$TEST_PROJECT_DIR" 42 "sha123" "$result_dir"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  # Both dirty and clean reviews are posted now.
  echo "$log_content" | grep -qF "posted=2"
  echo "$log_content" | grep -qF "issues=1"
  echo "$log_content" | grep -qF "clean=1"
}

@test "post_review_comments formatted comment includes SHA tag" {
  # Mock gh that captures comment body.
  cat > "$TEST_MOCK_DIR/gh" <<'MOCK'
#!/usr/bin/env bash
for arg in "$@"; do
  echo "$arg"
done > "$TEST_MOCK_DIR/gh_body.log"
MOCK
  chmod +x "$TEST_MOCK_DIR/gh"

  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"

  export PATH="$TEST_MOCK_DIR:$PATH"

  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"
  local out1="$BATS_TEST_TMPDIR/out1"
  echo '{"result":"Bug on line 5."}' > "$out1"
  printf '%s\n%s\n' "$out1" "0" > "$result_dir/general.meta"

  post_review_comments "$TEST_PROJECT_DIR" 42 "abc1234567890def" "$result_dir"

  local body_content
  body_content="$(cat "$TEST_MOCK_DIR/gh_body.log")"
  echo "$body_content" | grep -qF "sha=abc1234567890def"
  echo "$body_content" | grep -qF "General Review"
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

# --- Finding 4: post failure does not record SHA ---

@test "post_review_comments does not record SHA when posting fails" {
  # Mock gh that always fails.
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

  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"
  local out1="$BATS_TEST_TMPDIR/out1"
  echo '{"result":"1. Bug on line 42."}' > "$out1"
  printf '%s\n%s\n' "$out1" "0" > "$result_dir/general.meta"

  post_review_comments "$TEST_PROJECT_DIR" 42 "sha_fail" "$result_dir"

  # SHA should NOT be recorded since posting failed.
  local recorded_sha
  recorded_sha="$(get_reviewed_sha "$TEST_PROJECT_DIR" 42 "general")"
  [ -z "$recorded_sha" ]
}

@test "post_review_comments retries dirty review on next run after post failure" {
  # First run: gh fails.
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

  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"
  local out1="$BATS_TEST_TMPDIR/out1"
  echo '{"result":"1. Bug found."}' > "$out1"
  printf '%s\n%s\n' "$out1" "0" > "$result_dir/general.meta"

  post_review_comments "$TEST_PROJECT_DIR" 42 "sha_retry" "$result_dir"

  # Second run: gh succeeds.
  echo "0" > "$TEST_MOCK_DIR/gh_call_count"
  cat > "$TEST_MOCK_DIR/gh" <<'MOCK'
#!/usr/bin/env bash
count="$(cat "$TEST_MOCK_DIR/gh_call_count")"
echo "$((count + 1))" > "$TEST_MOCK_DIR/gh_call_count"
MOCK
  chmod +x "$TEST_MOCK_DIR/gh"

  post_review_comments "$TEST_PROJECT_DIR" 42 "sha_retry" "$result_dir"

  # Should have posted on the second run.
  local call_count
  call_count="$(cat "$TEST_MOCK_DIR/gh_call_count")"
  [ "$call_count" -eq 1 ]

  # SHA should now be recorded.
  local recorded_sha
  recorded_sha="$(get_reviewed_sha "$TEST_PROJECT_DIR" 42 "general")"
  [ "$recorded_sha" = "sha_retry" ]
}

@test "post_review_comments does not increment posted_count on failure" {
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

  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"
  local out1="$BATS_TEST_TMPDIR/out1"
  echo '{"result":"1. Bug found."}' > "$out1"
  printf '%s\n%s\n' "$out1" "0" > "$result_dir/general.meta"

  post_review_comments "$TEST_PROJECT_DIR" 42 "sha123" "$result_dir"

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  echo "$log_content" | grep -qF "posted=0"
}

# --- Finding 3: dedup-skipped clean reviews count toward _ALL_REVIEWS_CLEAN ---

@test "post_review_comments _ALL_REVIEWS_CLEAN true when all dedup-skipped clean" {
  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"
  export PATH="$TEST_MOCK_DIR:$PATH"

  # Pre-store both personas as clean on this SHA.
  set_reviewed_sha "$TEST_PROJECT_DIR" 42 "general" "sha123" "true"
  set_reviewed_sha "$TEST_PROJECT_DIR" 42 "security" "sha123" "true"

  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"

  local out1="$BATS_TEST_TMPDIR/out1"
  local out2="$BATS_TEST_TMPDIR/out2"
  echo '{"result":"NO_ISSUES_FOUND"}' > "$out1"
  echo '{"result":"NO_ISSUES_FOUND"}' > "$out2"

  printf '%s\n%s\n' "$out1" "0" > "$result_dir/general.meta"
  printf '%s\n%s\n' "$out2" "0" > "$result_dir/security.meta"

  post_review_comments "$TEST_PROJECT_DIR" 42 "sha123" "$result_dir"

  # All were dedup-skipped but stored as clean — should be true.
  [ "$_ALL_REVIEWS_CLEAN" = "true" ]
}

@test "post_review_comments _ALL_REVIEWS_CLEAN false when dedup-skipped dirty" {
  cat > "$TEST_MOCK_DIR/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$TEST_MOCK_DIR/timeout"
  export PATH="$TEST_MOCK_DIR:$PATH"

  # Pre-store general as dirty on this SHA.
  set_reviewed_sha "$TEST_PROJECT_DIR" 42 "general" "sha123" "false"

  local result_dir="$BATS_TEST_TMPDIR/result_dir"
  mkdir -p "$result_dir"

  local out1="$BATS_TEST_TMPDIR/out1"
  echo '{"result":"1. Bug found."}' > "$out1"
  printf '%s\n%s\n' "$out1" "0" > "$result_dir/general.meta"

  post_review_comments "$TEST_PROJECT_DIR" 42 "sha123" "$result_dir"

  # Dedup-skipped but stored as dirty — should be false.
  [ "$_ALL_REVIEWS_CLEAN" = "false" ]
}
