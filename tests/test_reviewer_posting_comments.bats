#!/usr/bin/env bats
# Tests for reviewer-posting.sh — all_reviews_clean and post_review_comments
# orchestration including dedup, failure handling, and summary logging.

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

# --- Post failure does not record SHA ---

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

# --- Dedup-skipped clean reviews count toward _ALL_REVIEWS_CLEAN ---

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
