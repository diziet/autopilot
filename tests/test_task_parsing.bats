#!/usr/bin/env bats
# Tests for lib/tasks.sh — task file parsing and context files.

setup() {
  TEST_PROJECT_DIR="$(mktemp -d)"

  # Unset all AUTOPILOT_* env vars to start clean
  while IFS= read -r var; do
    unset "$var"
  done < <(env | grep '^AUTOPILOT_' | cut -d= -f1)

  # Source tasks.sh (which also sources config.sh)
  source "$BATS_TEST_DIRNAME/../lib/tasks.sh"
  load_config "$TEST_PROJECT_DIR"
}

teardown() {
  rm -rf "$TEST_PROJECT_DIR"
}

# --- Helper: create task files ---

_create_task_n_file() {
  cat > "$TEST_PROJECT_DIR/tasks.md" << 'TASKEOF'
# Project Tasks

## Task 1: Setup project scaffold
Create directories and Makefile.

## Task 2: Add config loader
Implement lib/config.sh with defaults.
Support env var overrides.

## Task 3: State management
Add state.json read/write.
TASKEOF
}

_create_pr_n_file() {
  cat > "$TEST_PROJECT_DIR/tasks.md" << 'PREOF'
# Implementation Guide

### PR 1: Initial scaffold
Set up directories.

### PR 2: Config system
Parse config files.

### PR 3: State machine
Implement transitions.
PREOF
}

# --- detect_tasks_file ---

@test "detect_tasks_file finds tasks.md" {
  touch "$TEST_PROJECT_DIR/tasks.md"
  local result
  result="$(detect_tasks_file "$TEST_PROJECT_DIR")"
  [ "$result" = "$TEST_PROJECT_DIR/tasks.md" ]
}

@test "detect_tasks_file returns 1 when no file found" {
  run detect_tasks_file "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

@test "detect_tasks_file uses AUTOPILOT_TASKS_FILE if set" {
  touch "$TEST_PROJECT_DIR/custom-tasks.md"
  AUTOPILOT_TASKS_FILE="custom-tasks.md"
  local result
  result="$(detect_tasks_file "$TEST_PROJECT_DIR")"
  [ "$result" = "$TEST_PROJECT_DIR/custom-tasks.md" ]
}

@test "detect_tasks_file returns 1 if AUTOPILOT_TASKS_FILE not found" {
  AUTOPILOT_TASKS_FILE="nonexistent.md"
  run detect_tasks_file "$TEST_PROJECT_DIR"
  [ "$status" -eq 1 ]
}

@test "detect_tasks_file finds implementation guide pattern" {
  touch "$TEST_PROJECT_DIR/my-Implementation-Guide-v2.md"
  local result
  result="$(detect_tasks_file "$TEST_PROJECT_DIR")"
  [[ "$result" == *"Implementation"*"Guide"* ]]
}

@test "detect_tasks_file prefers tasks.md over implementation guide" {
  touch "$TEST_PROJECT_DIR/tasks.md"
  touch "$TEST_PROJECT_DIR/Implementation-Guide.md"
  local result
  result="$(detect_tasks_file "$TEST_PROJECT_DIR")"
  [ "$result" = "$TEST_PROJECT_DIR/tasks.md" ]
}

@test "detect_tasks_file prefers AUTOPILOT_TASKS_FILE over tasks.md" {
  touch "$TEST_PROJECT_DIR/tasks.md"
  touch "$TEST_PROJECT_DIR/my-plan.md"
  AUTOPILOT_TASKS_FILE="my-plan.md"
  local result
  result="$(detect_tasks_file "$TEST_PROJECT_DIR")"
  [ "$result" = "$TEST_PROJECT_DIR/my-plan.md" ]
}

# --- _detect_task_format ---

@test "_detect_task_format identifies Task N format" {
  _create_task_n_file
  local format
  format="$(_detect_task_format "$TEST_PROJECT_DIR/tasks.md")"
  [ "$format" = "task_n" ]
}

@test "_detect_task_format identifies PR N format" {
  _create_pr_n_file
  local format
  format="$(_detect_task_format "$TEST_PROJECT_DIR/tasks.md")"
  [ "$format" = "pr_n" ]
}

@test "_detect_task_format returns unknown for unrecognized format" {
  echo "Just some text" > "$TEST_PROJECT_DIR/tasks.md"
  local format
  format="$(_detect_task_format "$TEST_PROJECT_DIR/tasks.md")"
  [ "$format" = "unknown" ]
}

# --- count_tasks ---

@test "count_tasks counts Task N headings" {
  _create_task_n_file
  local count
  count="$(count_tasks "$TEST_PROJECT_DIR/tasks.md")"
  [ "$count" = "3" ]
}

@test "count_tasks counts PR N headings" {
  _create_pr_n_file
  local count
  count="$(count_tasks "$TEST_PROJECT_DIR/tasks.md")"
  [ "$count" = "3" ]
}

@test "count_tasks returns 1 for nonexistent file" {
  run count_tasks "/nonexistent/file.md"
  [ "$status" -eq 1 ]
}

@test "count_tasks returns 0 for unknown format" {
  echo "No headings here" > "$TEST_PROJECT_DIR/tasks.md"
  run count_tasks "$TEST_PROJECT_DIR/tasks.md"
  [ "$status" -eq 1 ]
}

# --- extract_task ---

@test "extract_task returns body of Task N" {
  _create_task_n_file
  local body
  body="$(extract_task "$TEST_PROJECT_DIR/tasks.md" 1)"
  [[ "$body" == *"## Task 1"* ]]
  [[ "$body" == *"Create directories"* ]]
}

@test "extract_task returns body of middle task" {
  _create_task_n_file
  local body
  body="$(extract_task "$TEST_PROJECT_DIR/tasks.md" 2)"
  [[ "$body" == *"## Task 2"* ]]
  [[ "$body" == *"lib/config.sh"* ]]
  [[ "$body" == *"env var overrides"* ]]
}

@test "extract_task returns body of last task" {
  _create_task_n_file
  local body
  body="$(extract_task "$TEST_PROJECT_DIR/tasks.md" 3)"
  [[ "$body" == *"## Task 3"* ]]
  [[ "$body" == *"state.json"* ]]
}

@test "extract_task returns body of PR N" {
  _create_pr_n_file
  local body
  body="$(extract_task "$TEST_PROJECT_DIR/tasks.md" 2)"
  [[ "$body" == *"### PR 2"* ]]
  [[ "$body" == *"Parse config"* ]]
}

@test "extract_task does not include next task body" {
  _create_task_n_file
  local body
  body="$(extract_task "$TEST_PROJECT_DIR/tasks.md" 1)"
  [[ "$body" != *"lib/config.sh"* ]]
}

@test "extract_task returns 1 for nonexistent task number" {
  _create_task_n_file
  run extract_task "$TEST_PROJECT_DIR/tasks.md" 99
  [ "$status" -eq 1 ]
}

@test "extract_task returns 1 for nonexistent file" {
  run extract_task "/nonexistent/file.md" 1
  [ "$status" -eq 1 ]
}

@test "extract_task rejects non-numeric task number" {
  _create_task_n_file
  run extract_task "$TEST_PROJECT_DIR/tasks.md" "abc"
  [ "$status" -eq 1 ]
}

@test "extract_task handles task with colon in title" {
  _create_task_n_file
  local body
  body="$(extract_task "$TEST_PROJECT_DIR/tasks.md" 1)"
  [[ "$body" == *"Setup project scaffold"* ]]
}

# --- extract_task_title ---

@test "extract_task_title returns heading for Task N" {
  _create_task_n_file
  local title
  title="$(extract_task_title "$TEST_PROJECT_DIR/tasks.md" 1)"
  [[ "$title" == "## Task 1: Setup project scaffold" ]]
}

@test "extract_task_title returns heading for PR N" {
  _create_pr_n_file
  local title
  title="$(extract_task_title "$TEST_PROJECT_DIR/tasks.md" 2)"
  [[ "$title" == "### PR 2: Config system" ]]
}

@test "extract_task_title returns 1 for nonexistent task" {
  _create_task_n_file
  run extract_task_title "$TEST_PROJECT_DIR/tasks.md" 99
  [ "$status" -eq 1 ]
}

@test "extract_task_title does not match task 10 when asking for task 1" {
  cat > "$TEST_PROJECT_DIR/tasks.md" << 'EOF'
## Task 10: Tenth
Content for 10.

## Task 11: Eleventh
Content for 11.
EOF
  run extract_task_title "$TEST_PROJECT_DIR/tasks.md" 1
  [ "$status" -eq 1 ]
}

# --- Task number edge cases ---

@test "extract_task handles task 10 without matching task 1" {
  cat > "$TEST_PROJECT_DIR/tasks.md" << 'EOF'
## Task 1: First
Content for 1.

## Task 10: Tenth
Content for 10.

## Task 11: Eleventh
Content for 11.
EOF
  local body
  body="$(extract_task "$TEST_PROJECT_DIR/tasks.md" 10)"
  [[ "$body" == *"## Task 10"* ]]
  [[ "$body" == *"Content for 10"* ]]
  [[ "$body" != *"Content for 11"* ]]
  [[ "$body" != *"Content for 1."* ]]
}

# --- parse_context_files ---

@test "parse_context_files returns empty when not configured" {
  AUTOPILOT_CONTEXT_FILES=""
  local result
  result="$(parse_context_files "$TEST_PROJECT_DIR")"
  [ -z "$result" ]
}

@test "parse_context_files resolves relative paths" {
  echo "context content" > "$TEST_PROJECT_DIR/docs/plan.md" 2>/dev/null || {
    mkdir -p "$TEST_PROJECT_DIR/docs"
    echo "context content" > "$TEST_PROJECT_DIR/docs/plan.md"
  }
  AUTOPILOT_CONTEXT_FILES="docs/plan.md"
  local result
  result="$(parse_context_files "$TEST_PROJECT_DIR")"
  [ "$result" = "$TEST_PROJECT_DIR/docs/plan.md" ]
}

@test "parse_context_files handles absolute paths" {
  local abs_file="$TEST_PROJECT_DIR/absolute-ctx.md"
  echo "absolute context" > "$abs_file"
  AUTOPILOT_CONTEXT_FILES="$abs_file"
  local result
  result="$(parse_context_files "$TEST_PROJECT_DIR")"
  [ "$result" = "$abs_file" ]
}

@test "parse_context_files handles multiple colon-separated paths" {
  mkdir -p "$TEST_PROJECT_DIR/docs"
  echo "file1" > "$TEST_PROJECT_DIR/docs/a.md"
  echo "file2" > "$TEST_PROJECT_DIR/docs/b.md"
  AUTOPILOT_CONTEXT_FILES="docs/a.md:docs/b.md"
  local result
  result="$(parse_context_files "$TEST_PROJECT_DIR")"
  local line_count
  line_count="$(echo "$result" | wc -l | tr -d ' ')"
  [ "$line_count" = "2" ]
  [[ "$result" == *"docs/a.md"* ]]
  [[ "$result" == *"docs/b.md"* ]]
}

@test "parse_context_files skips nonexistent files" {
  echo "exists" > "$TEST_PROJECT_DIR/real.md"
  AUTOPILOT_CONTEXT_FILES="real.md:nonexistent.md"
  local result
  result="$(parse_context_files "$TEST_PROJECT_DIR")"
  local line_count
  line_count="$(echo "$result" | wc -l | tr -d ' ')"
  [ "$line_count" = "1" ]
  [[ "$result" == *"real.md"* ]]
}

@test "parse_context_files skips empty segments" {
  echo "content" > "$TEST_PROJECT_DIR/file.md"
  AUTOPILOT_CONTEXT_FILES=":file.md:"
  local result
  result="$(parse_context_files "$TEST_PROJECT_DIR")"
  local line_count
  line_count="$(echo "$result" | wc -l | tr -d ' ')"
  [ "$line_count" = "1" ]
}

# --- read_context_files ---

@test "read_context_files returns empty when not configured" {
  AUTOPILOT_CONTEXT_FILES=""
  local result
  result="$(read_context_files "$TEST_PROJECT_DIR")"
  [ -z "$result" ]
}

@test "read_context_files returns file contents" {
  echo "hello world" > "$TEST_PROJECT_DIR/ctx.md"
  AUTOPILOT_CONTEXT_FILES="ctx.md"
  local result
  result="$(read_context_files "$TEST_PROJECT_DIR")"
  [[ "$result" == *"hello world"* ]]
}

@test "read_context_files concatenates multiple files with separator" {
  echo "first content" > "$TEST_PROJECT_DIR/a.md"
  echo "second content" > "$TEST_PROJECT_DIR/b.md"
  AUTOPILOT_CONTEXT_FILES="a.md:b.md"
  local result
  result="$(read_context_files "$TEST_PROJECT_DIR")"
  [[ "$result" == *"first content"* ]]
  [[ "$result" == *"second content"* ]]
  [[ "$result" == *"---"* ]]
}
