#!/usr/bin/env bats
# Tests for lib/make-merge.sh — detecting a target repo's `make merge` rule,
# running `make merge pr=N` in the task worktree, classifying a refusal, and the
# diagnosis hints for a gate failure.

# Avoid within-file test parallelism — reduces I/O contention with --jobs.
BATS_NO_PARALLELIZE_WITHIN_FILE=1

load helpers/test_template
load helpers/fake_make

# File-level source — loaded once, inherited by every test.
source "$BATS_TEST_DIRNAME/../lib/make-merge.sh"

setup_file() {
  _create_test_template
}

teardown_file() {
  _cleanup_test_template
}

setup() {
  _init_test_from_template_nogit
  load_config "$TEST_PROJECT_DIR"

  timeout() { shift; "$@"; }
  export -f timeout

  TASK_DIR="${TEST_PROJECT_DIR}/.autopilot/worktrees/task-7"
  _write_make_merge_makefile "$TASK_DIR"
  _install_fake_make
  PIPELINE_LOG="${TEST_PROJECT_DIR}/.autopilot/logs/pipeline.log"
  MERGE_LOG="${TEST_PROJECT_DIR}/.autopilot/logs/make-merge-task-7.log"
}

# --- has_make_merge_target ---

@test "has_make_merge_target returns 0 for a merge rule whose recipe runs scripts/merge.py" {
  has_make_merge_target "$TASK_DIR"
}

@test "has_make_merge_target returns 0 for a merge rule with a prerequisite and a help comment" {
  local dir="${BATS_TEST_TMPDIR}/with-prereq"
  mkdir -p "$dir"
  # shellcheck disable=SC2016
  printf 'VENV_STAMP := .venv/stamp\n\nmerge: $(VENV_STAMP) ## Sanctioned path\n\t$(PYTHON) scripts/merge.py --pr "$(pr)"\n' \
    > "${dir}/Makefile"
  has_make_merge_target "$dir"
}

@test "has_make_merge_target returns 1 when the merge recipe does not run scripts/merge.py" {
  local dir="${BATS_TEST_TMPDIR}/plain-merge"
  mkdir -p "$dir"
  printf 'merge:\n\tgit merge origin/main\n' > "${dir}/Makefile"
  run has_make_merge_target "$dir"
  [ "$status" -eq 1 ]
}

@test "has_make_merge_target returns 1 when scripts/merge.py runs only outside the merge rule" {
  local dir="${BATS_TEST_TMPDIR}/other-rule"
  mkdir -p "$dir"
  printf 'merge:\n\techo merging\n\nlint:\n\tpython3 scripts/merge.py --help\n' > "${dir}/Makefile"
  run has_make_merge_target "$dir"
  [ "$status" -eq 1 ]
}

@test "has_make_merge_target returns 1 for a merge := variable assignment" {
  local dir="${BATS_TEST_TMPDIR}/variable"
  mkdir -p "$dir"
  printf 'merge := scripts/merge.py\n\t@echo not a recipe\n' > "${dir}/Makefile"
  run has_make_merge_target "$dir"
  [ "$status" -eq 1 ]
}

@test "has_make_merge_target returns 1 when the Makefile has no merge rule" {
  local dir="${BATS_TEST_TMPDIR}/no-merge"
  mkdir -p "$dir"
  printf 'test:\n\tbats tests/\n' > "${dir}/Makefile"
  run has_make_merge_target "$dir"
  [ "$status" -eq 1 ]
}

@test "has_make_merge_target returns 1 when the directory has no Makefile" {
  run has_make_merge_target "${BATS_TEST_TMPDIR}/missing"
  [ "$status" -eq 1 ]
}

# --- make_merge_pr: success ---

@test "make_merge_pr runs make merge pr=42 in the task worktree and returns 0 when make exits 0" {
  make_merge_pr "$TEST_PROJECT_DIR" 7 42 "$TASK_DIR"
  grep -qxF "cwd=${TASK_DIR}" "$FAKE_MAKE_LOG"
  grep -qxF "args=merge pr=42" "$FAKE_MAKE_LOG"
  grep -qF "make merge merged PR #42" "$PIPELINE_LOG"
}

@test "make_merge_pr writes make's output to the project log dir and nothing into the worktree" {
  export FAKE_MAKE_OUTPUT="merge: PR #42 merged"
  local files_before
  files_before="$(find "$TASK_DIR" | sort)"

  make_merge_pr "$TEST_PROJECT_DIR" 7 42 "$TASK_DIR"

  grep -qxF "merge: PR #42 merged" "$MERGE_LOG"
  [ "$(find "$TASK_DIR" | sort)" = "$files_before" ]
}

@test "make_merge_pr returns 0 when make merge removes the worktree it ran in" {
  export FAKE_MAKE_REMOVE_TREE=1
  make_merge_pr "$TEST_PROJECT_DIR" 7 42 "$TASK_DIR"
  [ ! -d "$TASK_DIR" ]
}

# --- make_merge_pr: refusals and failures ---

@test "make_merge_pr returns 1 and logs the refusal at ERROR when the tree is dirty" {
  export FAKE_MAKE_EXIT=2
  export FAKE_MAKE_OUTPUT="merge: refused (closed): invoking tree has uncommitted or untracked files:
?? scratch.txt
make: *** [merge] Error 1"

  run make_merge_pr "$TEST_PROJECT_DIR" 7 42 "$TASK_DIR"
  [ "$status" -eq 1 ]
  grep -qF "[ERROR] make merge did not merge PR #42 (exit=2): merge: refused (closed): invoking tree has uncommitted or untracked files:" "$PIPELINE_LOG"
  grep -qF "output: ${MERGE_LOG}" "$PIPELINE_LOG"
}

@test "make_merge_pr returns 1 and logs the refusal when origin/main moved during the gate" {
  export FAKE_MAKE_EXIT=2
  export FAKE_MAKE_OUTPUT="merge: refused (closed): origin/main moved during the gate; rerun make merge"

  run make_merge_pr "$TEST_PROJECT_DIR" 7 42 "$TASK_DIR"
  [ "$status" -eq 1 ]
  grep -qF "origin/main moved during the gate; rerun make merge" "$PIPELINE_LOG"
}

@test "make_merge_pr returns 1 and logs the refusal when local main has diverged" {
  export FAKE_MAKE_EXIT=2
  export FAKE_MAKE_OUTPUT="merge: refused (closed): local main has 1 commit(s) origin/main lacks; repair main first (make sync explains how)"

  run make_merge_pr "$TEST_PROJECT_DIR" 7 42 "$TASK_DIR"
  [ "$status" -eq 1 ]
  grep -qF "local main has 1 commit(s) origin/main lacks" "$PIPELINE_LOG"
}

@test "make_merge_pr returns MAKE_MERGE_GATE_FAILED (2) and logs a WARNING when the gate fails" {
  export FAKE_MAKE_EXIT=2
  export FAKE_MAKE_OUTPUT="lint     FAIL (see /tmp/gate-logs/lint.log)
merge: refused (closed): gate failed (exit 1): bash /tmp/wg-merge-x/scripts/gate.sh
make: *** [merge] Error 1"

  run make_merge_pr "$TEST_PROJECT_DIR" 7 42 "$TASK_DIR"
  [ "$status" -eq "$MAKE_MERGE_GATE_FAILED" ]
  [ "$MAKE_MERGE_GATE_FAILED" -eq 2 ]
  grep -qF "[WARNING] make merge gate failed on the preview merge of PR #42: merge: refused (closed): gate failed (exit 1)" "$PIPELINE_LOG"
}

@test "make_merge_pr returns 1 and logs a timeout when make merge exceeds AUTOPILOT_TIMEOUT_MERGE" {
  AUTOPILOT_TIMEOUT_MERGE=900
  timeout() { return 124; }
  export -f timeout

  run make_merge_pr "$TEST_PROJECT_DIR" 7 42 "$TASK_DIR"
  [ "$status" -eq 1 ]
  grep -qF "make merge did not merge PR #42 (exit=124): timed out after 900s" "$PIPELINE_LOG"
}

@test "make_merge_pr logs the last output line when make merge prints no refusal" {
  export FAKE_MAKE_EXIT=2
  export FAKE_MAKE_OUTPUT="make: *** No rule to make target 'merge'.  Stop."

  run make_merge_pr "$TEST_PROJECT_DIR" 7 42 "$TASK_DIR"
  [ "$status" -eq 1 ]
  grep -qF "(exit=2): make: *** No rule to make target 'merge'.  Stop." "$PIPELINE_LOG"
}

@test "make_merge_pr returns 1 without running make when the task worktree is missing" {
  rm -rf "$TASK_DIR"

  run make_merge_pr "$TEST_PROJECT_DIR" 7 42 "$TASK_DIR"
  [ "$status" -eq 1 ]
  [ ! -f "$FAKE_MAKE_LOG" ]
  grep -qF "task directory ${TASK_DIR} does not exist" "$PIPELINE_LOG"
}

# --- make_merge_pr: TMPDIR ---

@test "make_merge_pr sets TMPDIR to the per-user temp dir when TMPDIR is unset" {
  unset TMPDIR
  getconf() { echo "/fake/per-user/T/"; }
  export -f getconf

  make_merge_pr "$TEST_PROJECT_DIR" 7 42 "$TASK_DIR"
  grep -qxF "tmpdir=/fake/per-user/T/" "$FAKE_MAKE_LOG"
}

@test "make_merge_pr keeps TMPDIR when it is set" {
  export TMPDIR="${BATS_TEST_TMPDIR}/custom-tmp"
  getconf() { echo "/fake/per-user/T/"; }
  export -f getconf

  make_merge_pr "$TEST_PROJECT_DIR" 7 42 "$TASK_DIR"
  grep -qxF "tmpdir=${BATS_TEST_TMPDIR}/custom-tmp" "$FAKE_MAKE_LOG"
}

@test "make_merge_pr leaves TMPDIR unset when TMPDIR and the per-user temp dir are both unavailable" {
  unset TMPDIR
  getconf() { return 1; }
  export -f getconf

  make_merge_pr "$TEST_PROJECT_DIR" 7 42 "$TASK_DIR"
  grep -qxF "tmpdir=<unset>" "$FAKE_MAKE_LOG"
}

# --- build_make_merge_gate_hints ---

@test "build_make_merge_gate_hints names the PR and includes the gate output" {
  mkdir -p "${MERGE_LOG%/*}"
  printf 'lint     FAIL (see /tmp/gate-logs/lint.log)\nmerge: refused (closed): gate failed (exit 1): bash gate.sh\n' \
    > "$MERGE_LOG"

  local hints
  hints="$(build_make_merge_gate_hints "$TEST_PROJECT_DIR" 7 42)"
  [[ "$hints" == *"make merge pr=42"* ]] || false
  [[ "$hints" == *"lint     FAIL (see /tmp/gate-logs/lint.log)"* ]] || false
  [[ "$hints" == *"gate failed (exit 1)"* ]] || false
  [[ "$hints" == *"$MERGE_LOG"* ]] || false
}

@test "build_make_merge_gate_hints keeps lines 51 to 150 of a 150-line output" {
  mkdir -p "${MERGE_LOG%/*}"
  local i
  for (( i = 1; i <= 150; i++ )); do
    echo "gate output line ${i}"
  done > "$MERGE_LOG"

  local hints
  hints="$(build_make_merge_gate_hints "$TEST_PROJECT_DIR" 7 42)"
  [ "$(grep -c '^gate output line ' <<< "$hints")" -eq 100 ]
  [ "$(grep -cx 'gate output line 51' <<< "$hints")" -eq 1 ]
  [ "$(grep -cx 'gate output line 50' <<< "$hints")" -eq 0 ]
}
