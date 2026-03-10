#!/usr/bin/env bats
# Tests for lib/session-cache.sh — Session cache and pre-warming.

load helpers/test_template

setup() {
  TEST_PROJECT_DIR="${BATS_TEST_TMPDIR}/project"
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/logs"

  _unset_autopilot_vars
  unset CLAUDECODE

  # Unset double-source guards so each test gets a fresh load.
  unset _AUTOPILOT_SESSION_CACHE_LOADED
  unset _AUTOPILOT_STATE_LOADED
  unset _AUTOPILOT_CONFIG_LOADED
  unset _AUTOPILOT_CLAUDE_LOADED
  unset _AUTOPILOT_TASKS_LOADED

  # Must source per-test because of readonly guards.
  source "$BATS_TEST_DIRNAME/../lib/session-cache.sh"
  load_config "$TEST_PROJECT_DIR"
}

teardown() {
  : # BATS_TEST_TMPDIR is auto-cleaned
}

# --- Portable Realpath ---

@test "portable_realpath resolves absolute path of existing file" {
  local testfile="$TEST_PROJECT_DIR/somefile.txt"
  echo "hello" > "$testfile"
  run portable_realpath "$testfile"
  [ "$status" -eq 0 ]
  [[ "$output" == */somefile.txt ]]
  # Path should be absolute
  [[ "$output" == /* ]]
}

@test "portable_realpath resolves absolute path of directory" {
  local testdir="$TEST_PROJECT_DIR/subdir"
  mkdir -p "$testdir"
  run portable_realpath "$testdir"
  [ "$status" -eq 0 ]
  [[ "$output" == */subdir ]]
  [[ "$output" == /* ]]
}

@test "portable_realpath resolves non-existent file in existing dir" {
  run portable_realpath "$TEST_PROJECT_DIR/nonexistent.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == */nonexistent.txt ]]
  [[ "$output" == /* ]]
}

@test "portable_realpath returns canonical path without .. segments" {
  mkdir -p "$TEST_PROJECT_DIR/a/b"
  echo "test" > "$TEST_PROJECT_DIR/a/b/file.txt"
  run portable_realpath "$TEST_PROJECT_DIR/a/b/../b/file.txt"
  [ "$status" -eq 0 ]
  # Should not contain ..
  [[ "$output" != *".."* ]]
  [[ "$output" == */a/b/file.txt ]]
}

# --- Realpath Shim ---

@test "_realpath_shim resolves existing file" {
  echo "content" > "$TEST_PROJECT_DIR/testfile.txt"
  run _realpath_shim "$TEST_PROJECT_DIR/testfile.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == */testfile.txt ]]
}

@test "_realpath_shim resolves existing directory" {
  mkdir -p "$TEST_PROJECT_DIR/mydir"
  run _realpath_shim "$TEST_PROJECT_DIR/mydir"
  [ "$status" -eq 0 ]
  [[ "$output" == */mydir ]]
}

@test "_realpath_shim resolves non-existent file" {
  run _realpath_shim "$TEST_PROJECT_DIR/nofile.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == */nofile.txt ]]
}

# --- Content Hashing ---

@test "compute_content_hash returns 'empty' when no files exist" {
  # No CLAUDE.md, no context files
  run compute_content_hash "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "empty" ]
}

@test "compute_content_hash returns hex digest when CLAUDE.md exists" {
  echo "# Project" > "$TEST_PROJECT_DIR/CLAUDE.md"
  run compute_content_hash "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  # Should be a 64-char hex SHA-256 hash
  [[ "$output" =~ ^[a-f0-9]{64}$ ]]
}

@test "compute_content_hash changes when file content changes" {
  echo "version1" > "$TEST_PROJECT_DIR/CLAUDE.md"
  local hash1
  hash1="$(compute_content_hash "$TEST_PROJECT_DIR")"

  echo "version2" > "$TEST_PROJECT_DIR/CLAUDE.md"
  local hash2
  hash2="$(compute_content_hash "$TEST_PROJECT_DIR")"

  [ "$hash1" != "$hash2" ]
}

@test "compute_content_hash is deterministic for same content" {
  echo "stable content" > "$TEST_PROJECT_DIR/CLAUDE.md"
  local hash1
  hash1="$(compute_content_hash "$TEST_PROJECT_DIR")"
  local hash2
  hash2="$(compute_content_hash "$TEST_PROJECT_DIR")"

  [ "$hash1" = "$hash2" ]
}

@test "compute_content_hash includes context files" {
  echo "# Main" > "$TEST_PROJECT_DIR/CLAUDE.md"
  echo "# Context" > "$TEST_PROJECT_DIR/context.md"
  AUTOPILOT_CONTEXT_FILES="context.md"

  local hash_with_context
  hash_with_context="$(compute_content_hash "$TEST_PROJECT_DIR")"

  # Now compute without context files
  AUTOPILOT_CONTEXT_FILES=""
  local hash_without_context
  hash_without_context="$(compute_content_hash "$TEST_PROJECT_DIR")"

  [ "$hash_with_context" != "$hash_without_context" ]
}

@test "compute_content_hash handles multiple context files" {
  echo "# Main" > "$TEST_PROJECT_DIR/CLAUDE.md"
  echo "file1" > "$TEST_PROJECT_DIR/a.md"
  echo "file2" > "$TEST_PROJECT_DIR/b.md"
  AUTOPILOT_CONTEXT_FILES="a.md:b.md"

  run compute_content_hash "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[a-f0-9]{64}$ ]]
}

@test "compute_content_hash ignores non-existent context files" {
  echo "# Main" > "$TEST_PROJECT_DIR/CLAUDE.md"
  AUTOPILOT_CONTEXT_FILES="missing.md"

  local hash_with_missing
  hash_with_missing="$(compute_content_hash "$TEST_PROJECT_DIR")"

  AUTOPILOT_CONTEXT_FILES=""
  local hash_without
  hash_without="$(compute_content_hash "$TEST_PROJECT_DIR")"

  # Should be the same since missing files are skipped
  [ "$hash_with_missing" = "$hash_without" ]
}

# --- Cache Directory ---

@test "_get_cache_dir returns correct path" {
  run _get_cache_dir "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_PROJECT_DIR/.autopilot/cache" ]
}

@test "_ensure_cache_dir creates directory" {
  run _ensure_cache_dir "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ -d "$TEST_PROJECT_DIR/.autopilot/cache" ]
}

# --- Cache Read/Write ---

@test "read_cached_hash returns 1 when no cache exists" {
  run read_cached_hash "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

@test "read_cached_hash returns stored hash" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/cache"
  echo "abc123def456" > "$TEST_PROJECT_DIR/.autopilot/cache/content.sha"
  run read_cached_hash "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "abc123def456" ]
}

@test "_write_cached_hash stores hash atomically" {
  _write_cached_hash "$TEST_PROJECT_DIR" "deadbeef1234"
  [ -f "$TEST_PROJECT_DIR/.autopilot/cache/content.sha" ]
  local stored
  stored="$(cat "$TEST_PROJECT_DIR/.autopilot/cache/content.sha")"
  [ "$stored" = "deadbeef1234" ]
}

@test "_write_cached_hash overwrites existing hash" {
  _write_cached_hash "$TEST_PROJECT_DIR" "old_hash"
  _write_cached_hash "$TEST_PROJECT_DIR" "new_hash"
  local stored
  stored="$(cat "$TEST_PROJECT_DIR/.autopilot/cache/content.sha")"
  [ "$stored" = "new_hash" ]
}

@test "_write_warm_marker stores marker atomically" {
  _write_warm_marker "$TEST_PROJECT_DIR" "warmhash123"
  [ -f "$TEST_PROJECT_DIR/.autopilot/cache/warm.marker" ]
  local stored
  stored="$(cat "$TEST_PROJECT_DIR/.autopilot/cache/warm.marker")"
  [ "$stored" = "warmhash123" ]
}

@test "_read_warm_marker returns 1 when no marker exists" {
  run _read_warm_marker "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

@test "_read_warm_marker returns stored marker hash" {
  mkdir -p "$TEST_PROJECT_DIR/.autopilot/cache"
  echo "marker_hash" > "$TEST_PROJECT_DIR/.autopilot/cache/warm.marker"
  run _read_warm_marker "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "marker_hash" ]
}

# --- Cache Validation ---

@test "is_cache_valid returns false when no cache exists" {
  echo "# Project" > "$TEST_PROJECT_DIR/CLAUDE.md"
  run is_cache_valid "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
}

@test "is_cache_valid returns true when hash and marker match" {
  echo "# Project" > "$TEST_PROJECT_DIR/CLAUDE.md"
  local hash
  hash="$(compute_content_hash "$TEST_PROJECT_DIR")"
  _write_cached_hash "$TEST_PROJECT_DIR" "$hash"
  _write_warm_marker "$TEST_PROJECT_DIR" "$hash"

  run is_cache_valid "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
}

@test "is_cache_valid returns false when content changed" {
  echo "version1" > "$TEST_PROJECT_DIR/CLAUDE.md"
  local hash
  hash="$(compute_content_hash "$TEST_PROJECT_DIR")"
  _write_cached_hash "$TEST_PROJECT_DIR" "$hash"
  _write_warm_marker "$TEST_PROJECT_DIR" "$hash"

  # Change file content
  echo "version2" > "$TEST_PROJECT_DIR/CLAUDE.md"

  run is_cache_valid "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
}

@test "is_cache_valid returns false when only hash matches but no marker" {
  echo "# Project" > "$TEST_PROJECT_DIR/CLAUDE.md"
  local hash
  hash="$(compute_content_hash "$TEST_PROJECT_DIR")"
  _write_cached_hash "$TEST_PROJECT_DIR" "$hash"
  # No warm marker written

  run is_cache_valid "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
}

@test "is_cache_valid returns false when marker mismatches" {
  echo "# Project" > "$TEST_PROJECT_DIR/CLAUDE.md"
  local hash
  hash="$(compute_content_hash "$TEST_PROJECT_DIR")"
  _write_cached_hash "$TEST_PROJECT_DIR" "$hash"
  _write_warm_marker "$TEST_PROJECT_DIR" "different_hash"

  run is_cache_valid "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
}

# --- Cache Invalidation ---

@test "invalidate_cache removes hash and marker files" {
  _write_cached_hash "$TEST_PROJECT_DIR" "somehash"
  _write_warm_marker "$TEST_PROJECT_DIR" "somehash"

  invalidate_cache "$TEST_PROJECT_DIR"

  [ ! -f "$TEST_PROJECT_DIR/.autopilot/cache/content.sha" ]
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/cache/warm.marker" ]
}

@test "invalidate_cache is safe when no cache exists" {
  run invalidate_cache "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
}

@test "invalidate_cache preserves cache directory" {
  _write_cached_hash "$TEST_PROJECT_DIR" "hash"
  invalidate_cache "$TEST_PROJECT_DIR"
  [ -d "$TEST_PROJECT_DIR/.autopilot/cache" ]
}

# --- Prewarm Prompt Construction ---

@test "build_prewarm_prompt includes preamble text" {
  local prompt
  prompt="$(build_prewarm_prompt "$TEST_PROJECT_DIR")"
  [[ "$prompt" == *"Read and internalize"* ]]
  [[ "$prompt" == *"project context"* ]]
}

@test "build_prewarm_prompt includes CLAUDE.md content" {
  echo "# My Project Rules" > "$TEST_PROJECT_DIR/CLAUDE.md"
  local prompt
  prompt="$(build_prewarm_prompt "$TEST_PROJECT_DIR")"
  [[ "$prompt" == *"CLAUDE.md"* ]]
  [[ "$prompt" == *"My Project Rules"* ]]
}

@test "build_prewarm_prompt includes context files" {
  echo "# Main" > "$TEST_PROJECT_DIR/CLAUDE.md"
  echo "Important context here" > "$TEST_PROJECT_DIR/plan.md"
  AUTOPILOT_CONTEXT_FILES="plan.md"

  local prompt
  prompt="$(build_prewarm_prompt "$TEST_PROJECT_DIR")"
  [[ "$prompt" == *"plan.md"* ]]
  [[ "$prompt" == *"Important context here"* ]]
}

@test "build_prewarm_prompt handles no files gracefully" {
  run build_prewarm_prompt "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Read and internalize"* ]]
}

@test "build_prewarm_prompt includes multiple context files" {
  echo "# Main" > "$TEST_PROJECT_DIR/CLAUDE.md"
  echo "File A content" > "$TEST_PROJECT_DIR/a.md"
  echo "File B content" > "$TEST_PROJECT_DIR/b.md"
  AUTOPILOT_CONTEXT_FILES="a.md:b.md"

  local prompt
  prompt="$(build_prewarm_prompt "$TEST_PROJECT_DIR")"
  [[ "$prompt" == *"File A content"* ]]
  [[ "$prompt" == *"File B content"* ]]
}

# --- Context Path Collection ---

@test "_collect_context_paths includes CLAUDE.md when present" {
  echo "# Project" > "$TEST_PROJECT_DIR/CLAUDE.md"
  local paths
  paths="$(_collect_context_paths "$TEST_PROJECT_DIR")"
  [[ "$paths" == *"CLAUDE.md"* ]]
}

@test "_collect_context_paths returns empty when no files" {
  run _collect_context_paths "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_collect_context_paths includes configured context files" {
  echo "# Main" > "$TEST_PROJECT_DIR/CLAUDE.md"
  echo "ctx" > "$TEST_PROJECT_DIR/extra.md"
  AUTOPILOT_CONTEXT_FILES="extra.md"

  local paths
  paths="$(_collect_context_paths "$TEST_PROJECT_DIR")"
  [[ "$paths" == *"CLAUDE.md"* ]]
  [[ "$paths" == *"extra.md"* ]]
}

@test "_collect_context_paths skips missing context files" {
  echo "# Main" > "$TEST_PROJECT_DIR/CLAUDE.md"
  AUTOPILOT_CONTEXT_FILES="missing.md"

  local paths
  paths="$(_collect_context_paths "$TEST_PROJECT_DIR")"
  [[ "$paths" == *"CLAUDE.md"* ]]
  [[ "$paths" != *"missing.md"* ]]
}

# --- Prewarm Session (with mocked Claude) ---

@test "prewarm_session skips when cache is valid" {
  echo "# Project" > "$TEST_PROJECT_DIR/CLAUDE.md"
  local hash
  hash="$(compute_content_hash "$TEST_PROJECT_DIR")"
  _write_cached_hash "$TEST_PROJECT_DIR" "$hash"
  _write_warm_marker "$TEST_PROJECT_DIR" "$hash"

  run prewarm_session "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
}

@test "prewarm_session runs claude when cache is invalid" {
  echo "# Project" > "$TEST_PROJECT_DIR/CLAUDE.md"

  # Create a mock claude that succeeds
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"Context acknowledged"}'
MOCK
  chmod +x "$mock_dir/claude"
  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  # Mock timeout to just pass through
  cat > "$mock_dir/timeout" <<'MOCK'
#!/usr/bin/env bash
shift  # skip the timeout value
"$@"
MOCK
  chmod +x "$mock_dir/timeout"
  export PATH="$mock_dir:$PATH"

  run prewarm_session "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]

  # Should have written warm marker
  [ -f "$TEST_PROJECT_DIR/.autopilot/cache/warm.marker" ]

  rm -rf "$mock_dir"
}

@test "prewarm_session writes hash before running claude" {
  echo "# Project" > "$TEST_PROJECT_DIR/CLAUDE.md"

  # Create a mock claude that checks hash file exists
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<MOCK
#!/usr/bin/env bash
if [ -f "$TEST_PROJECT_DIR/.autopilot/cache/content.sha" ]; then
  echo '{"result":"Hash written before prewarm"}'
else
  echo '{"result":"No hash found"}' >&2
  exit 1
fi
MOCK
  chmod +x "$mock_dir/claude"
  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  cat > "$mock_dir/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$mock_dir/timeout"
  export PATH="$mock_dir:$PATH"

  run prewarm_session "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]

  rm -rf "$mock_dir"
}

@test "prewarm_session returns 1 when claude fails" {
  echo "# Project" > "$TEST_PROJECT_DIR/CLAUDE.md"

  # Create a mock claude that fails
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"error":"crash"}' >&2
exit 1
MOCK
  chmod +x "$mock_dir/claude"
  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  cat > "$mock_dir/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$mock_dir/timeout"
  export PATH="$mock_dir:$PATH"

  run prewarm_session "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
  # Warm marker should NOT be written on failure
  [ ! -f "$TEST_PROJECT_DIR/.autopilot/cache/warm.marker" ]

  rm -rf "$mock_dir"
}

@test "prewarm_session updates cache when content changes" {
  echo "version1" > "$TEST_PROJECT_DIR/CLAUDE.md"

  # Seed the cache with version1's hash
  local old_hash
  old_hash="$(compute_content_hash "$TEST_PROJECT_DIR")"
  _write_cached_hash "$TEST_PROJECT_DIR" "$old_hash"
  _write_warm_marker "$TEST_PROJECT_DIR" "$old_hash"

  # Change content
  echo "version2" > "$TEST_PROJECT_DIR/CLAUDE.md"

  # Create a mock claude that succeeds
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"OK"}'
MOCK
  chmod +x "$mock_dir/claude"
  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  cat > "$mock_dir/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$mock_dir/timeout"
  export PATH="$mock_dir:$PATH"

  run prewarm_session "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]

  # Verify the cached hash was updated
  local new_cached
  new_cached="$(read_cached_hash "$TEST_PROJECT_DIR")"
  [ "$new_cached" != "$old_hash" ]

  rm -rf "$mock_dir"
}

# --- Round-trip: Hash, Validate, Invalidate ---

@test "round-trip: hash → write → validate → invalidate → invalid" {
  echo "# Content" > "$TEST_PROJECT_DIR/CLAUDE.md"

  local hash
  hash="$(compute_content_hash "$TEST_PROJECT_DIR")"
  _write_cached_hash "$TEST_PROJECT_DIR" "$hash"
  _write_warm_marker "$TEST_PROJECT_DIR" "$hash"

  # Should be valid
  is_cache_valid "$TEST_PROJECT_DIR"

  # Invalidate
  invalidate_cache "$TEST_PROJECT_DIR"

  # Should be invalid now
  run is_cache_valid "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
}

@test "round-trip: content change invalidates cache" {
  echo "v1" > "$TEST_PROJECT_DIR/CLAUDE.md"
  local hash
  hash="$(compute_content_hash "$TEST_PROJECT_DIR")"
  _write_cached_hash "$TEST_PROJECT_DIR" "$hash"
  _write_warm_marker "$TEST_PROJECT_DIR" "$hash"

  is_cache_valid "$TEST_PROJECT_DIR"

  echo "v2" > "$TEST_PROJECT_DIR/CLAUDE.md"
  run is_cache_valid "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
}

@test "round-trip: adding context file invalidates cache" {
  echo "# Main" > "$TEST_PROJECT_DIR/CLAUDE.md"
  AUTOPILOT_CONTEXT_FILES=""

  local hash
  hash="$(compute_content_hash "$TEST_PROJECT_DIR")"
  _write_cached_hash "$TEST_PROJECT_DIR" "$hash"
  _write_warm_marker "$TEST_PROJECT_DIR" "$hash"

  is_cache_valid "$TEST_PROJECT_DIR"

  # Add a context file
  echo "new context" > "$TEST_PROJECT_DIR/extra.md"
  AUTOPILOT_CONTEXT_FILES="extra.md"

  run is_cache_valid "$TEST_PROJECT_DIR"
  [ "$status" -ne 0 ]
}

# --- Edge Cases ---

@test "compute_content_hash handles absolute context paths" {
  echo "# Main" > "$TEST_PROJECT_DIR/CLAUDE.md"
  local abs_file="$TEST_PROJECT_DIR/absolute_ctx.md"
  echo "absolute context" > "$abs_file"
  AUTOPILOT_CONTEXT_FILES="$abs_file"

  run compute_content_hash "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[a-f0-9]{64}$ ]]
}

@test "compute_content_hash with empty CLAUDE.md still produces hash" {
  touch "$TEST_PROJECT_DIR/CLAUDE.md"
  run compute_content_hash "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[a-f0-9]{64}$ ]]
}

@test "prewarm_session works with no context files" {
  # No CLAUDE.md, no context — empty hash sentinel

  # Create a mock claude
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"result":"OK"}'
MOCK
  chmod +x "$mock_dir/claude"
  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  cat > "$mock_dir/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$mock_dir/timeout"
  export PATH="$mock_dir:$PATH"

  run prewarm_session "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]

  rm -rf "$mock_dir"
}

@test "prewarm_session passes config_dir to run_claude" {
  echo "# Project" > "$TEST_PROJECT_DIR/CLAUDE.md"

  local marker_file="$TEST_PROJECT_DIR/config_dir_marker"
  local mock_dir
  mock_dir="$(mktemp -d)"
  cat > "$mock_dir/claude" <<MOCK
#!/usr/bin/env bash
# Write the CLAUDE_CONFIG_DIR to a marker file for verification
echo "\${CLAUDE_CONFIG_DIR:-unset}" > "$marker_file"
echo '{"result":"OK"}'
MOCK
  chmod +x "$mock_dir/claude"
  AUTOPILOT_CLAUDE_CMD="$mock_dir/claude"

  cat > "$mock_dir/timeout" <<'MOCK'
#!/usr/bin/env bash
shift
"$@"
MOCK
  chmod +x "$mock_dir/timeout"
  export PATH="$mock_dir:$PATH"

  run prewarm_session "$TEST_PROJECT_DIR" "/custom/config"
  [ "$status" -eq 0 ]

  # Verify config_dir was passed through to Claude
  [ -f "$marker_file" ]
  [ "$(cat "$marker_file")" = "/custom/config" ]

  rm -rf "$mock_dir"
}
