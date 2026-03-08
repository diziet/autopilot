#!/usr/bin/env bats
# Tests for check_worktree_compatibility() — symlink scanner in lib/preflight.sh.

load helpers/test_template

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  REAL_PATH="$PATH"
  _init_test_from_template
  MOCK_BIN="$TEST_MOCK_BIN"
  EXTERNAL_SYMLINK_DIR=""

  # Create required project files.
  echo "# Tasks" > "$TEST_PROJECT_DIR/tasks.md"
  echo "## Task 1" >> "$TEST_PROJECT_DIR/tasks.md"
  echo "# Project CLAUDE.md" > "$TEST_PROJECT_DIR/CLAUDE.md"

  OLD_PATH="$REAL_PATH"

  # Source preflight.sh (which sources config, state, tasks).
  source "$BATS_TEST_DIRNAME/../lib/preflight.sh"
  load_config "$TEST_PROJECT_DIR"
  init_pipeline "$TEST_PROJECT_DIR"
}

teardown() {
  [[ -n "$EXTERNAL_SYMLINK_DIR" && -d "$EXTERNAL_SYMLINK_DIR" ]] && rm -rf "$EXTERNAL_SYMLINK_DIR"
  rm -rf "$TEST_PROJECT_DIR" "$MOCK_BIN"
}

# Helper: create an escaping symlink and commit it.
_add_escaping_symlink_local() {
  local link_name="${1:-ext_link}"
  EXTERNAL_SYMLINK_DIR="$(mktemp -d)"
  echo "external" > "$EXTERNAL_SYMLINK_DIR/data.txt"
  ln -s "$EXTERNAL_SYMLINK_DIR" "${TEST_PROJECT_DIR}/${link_name}"
  git -C "$TEST_PROJECT_DIR" add -A
  git -C "$TEST_PROJECT_DIR" commit -m "add escaping symlink ${link_name}" -q
}

# --- check_worktree_compatibility ---

@test "scanner: returns 0 when no symlinks exist" {
  run check_worktree_compatibility "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "scanner: returns 0 for internal symlinks" {
  # Create a directory and a symlink pointing within the repo.
  mkdir -p "$TEST_PROJECT_DIR/src"
  echo "content" > "$TEST_PROJECT_DIR/src/real_file.txt"
  ln -s "src/real_file.txt" "$TEST_PROJECT_DIR/link_to_internal.txt"

  git -C "$TEST_PROJECT_DIR" add -A
  git -C "$TEST_PROJECT_DIR" commit -m "add internal symlink" -q

  run check_worktree_compatibility "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "scanner: detects symlinks escaping repo root" {
  _add_escaping_symlink_local "external_data"

  run check_worktree_compatibility "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"external_data"* ]]
}

@test "scanner: detects relative symlinks escaping repo root" {
  # Create an external directory next to the repo and a relative symlink.
  local parent_dir
  parent_dir="$(dirname "$TEST_PROJECT_DIR")"
  mkdir -p "$parent_dir/shared-data"
  echo "shared" > "$parent_dir/shared-data/info.txt"

  # Create a relative symlink that escapes the repo.
  ln -s "../shared-data" "$TEST_PROJECT_DIR/data"

  git -C "$TEST_PROJECT_DIR" add -A
  git -C "$TEST_PROJECT_DIR" commit -m "add relative escaping symlink" -q

  run check_worktree_compatibility "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"data"* ]]
}

@test "scanner: logs WARNING when escaping symlinks found" {
  _add_escaping_symlink_local "ext"

  check_worktree_compatibility "$TEST_PROJECT_DIR" >/dev/null 2>&1 || true

  local log_content
  log_content="$(cat "$TEST_PROJECT_DIR/.autopilot/logs/pipeline.log")"
  [[ "$log_content" == *"WARNING"* ]]
  [[ "$log_content" == *"Symlinks escaping repo root"* ]]
}

@test "scanner: ignores non-symlink files" {
  echo "hello" > "$TEST_PROJECT_DIR/regular.txt"
  mkdir -p "$TEST_PROJECT_DIR/subdir"
  echo "world" > "$TEST_PROJECT_DIR/subdir/another.txt"

  git -C "$TEST_PROJECT_DIR" add -A
  git -C "$TEST_PROJECT_DIR" commit -m "add regular files" -q

  run check_worktree_compatibility "$TEST_PROJECT_DIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "scanner: handles mix of internal and escaping symlinks" {
  # Internal symlink — should be fine.
  mkdir -p "$TEST_PROJECT_DIR/src"
  echo "internal" > "$TEST_PROJECT_DIR/src/lib.sh"
  ln -s "src/lib.sh" "$TEST_PROJECT_DIR/lib_link.sh"

  # Escaping symlink — should be caught.
  _add_escaping_symlink_local "ext_data"

  run check_worktree_compatibility "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ext_data"* ]]
  # Should NOT report the internal symlink.
  [[ "$output" != *"lib_link"* ]]
}

@test "scanner: returns 2 for non-git directory" {
  local non_git_dir
  non_git_dir="$(mktemp -d)"
  mkdir -p "$non_git_dir/.autopilot/logs"

  run check_worktree_compatibility "$non_git_dir"
  [ "$status" -eq 2 ]

  rm -rf "$non_git_dir"
}
