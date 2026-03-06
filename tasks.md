# Autopilot Implementation Guide

Autonomous PR pipeline extracted from devops `scripts/pr-pipeline/`. Each task produces a working, testable commit. Reference the full plan document (provided via context files) for architecture details, config schema, and state machine documentation.

Convention: All modules that call `gh` API should use `AUTOPILOT_TIMEOUT_GH` for the timeout value.

## Task 1: Project scaffold and Makefile

Set up repository structure with README.md (stub), Makefile (with `test`, `lint`, `install` targets), empty directories (bin/, lib/, prompts/, reviewers/, examples/, docs/, tests/). The Makefile should run `bats tests/` for `make test` so the test gate works from the first task onward. `make lint` should run `shellcheck` on all `.sh` files in bin/ and lib/. Include a trivial `tests/test_smoke.bats` that passes. Do NOT overwrite CLAUDE.md or .gitignore — they already exist.

## Task 2: Config loading

Implement lib/config.sh. Define all `AUTOPILOT_*` variables with built-in defaults (see complete config schema in section 4 of the plan — all variables listed there must be included). Parse `autopilot.conf` then `.autopilot/config.conf` if they exist — line-by-line, only accepting lines matching `^AUTOPILOT_[A-Z_]*=` (do NOT use `source` — security risk). Snapshot env vars before parsing, restore after (so env always wins over file values). Log effective config with source annotations. Write `tests/test_config.bats` covering: defaults only, file override, env override, missing file, partial config.

## Task 3: State management — state read/write, logging, counters

Implement lib/state.sh. Create `init_pipeline` (creates `.autopilot/` directory tree including state.json, logs/, locks/ on first run), state read/write with atomic tmp+mv, `log_msg` with rotation (`AUTOPILOT_MAX_LOG_LINES`), `update_status` for state transitions. Include the generic counter helpers (`_get_counter`, `_increment_counter`, `_reset_counter`) and the public API wrappers for retry tracking (`get_retry_count`, `increment_retry`, `reset_retry`) and test fix tracking (`get_test_fix_retries`, `increment_test_fix_retries`, `reset_test_fix_retries`). Source lib/config.sh and use `AUTOPILOT_*` variables for all constants. Write `tests/test_state.bats` for state transitions, counter operations, and init.

## Task 4: Lock management and task parsing

Extract lock management into lib/state.sh (or keep alongside existing state code): `acquire_lock`, `release_lock`, stale lock detection based on `AUTOPILOT_STALE_LOCK_MINUTES` and dead PID checks. Create task file parsing (can be in state.sh or a separate lib/tasks.sh): both `## Task N` and `### PR N` formats, auto-detect tasks file (`tasks.md` then `*implementation*guide*.md`). Implement `AUTOPILOT_CONTEXT_FILES` config variable (colon-separated paths parsed into an array). Write `tests/test_locks.bats` and `tests/test_task_parsing.bats`.

## Task 5: Claude invocation helpers

Create lib/claude.sh with shared functions used by all agent-spawning modules: `build_claude_cmd` (constructs the full command from config: command, flags, output format, optional config dir), `extract_claude_text` (parses Claude JSON output to extract the `.result` text field), and `run_claude` (timeout wrapper with `unset CLAUDECODE` isolation). Write `tests/test_claude.bats`.

## Task 6: Preflight checks

Implement lib/preflight.sh. Check dependencies (claude, gh, jq, git, timeout — with explicit macOS guidance for timeout via `brew install coreutils`), verify git repo, clean working tree, check gh auth, verify tasks file exists, verify CLAUDE.md exists. Use config for claude command path. Detect non-interactive mode (`[[ -t 0 ]]`) and log CRITICAL + exit if `AUTOPILOT_CLAUDE_FLAGS` lacks `--dangerously-skip-permissions`. Write `tests/test_preflight.bats`.

## Task 7: Git operations

Create lib/git-ops.sh. Offload git operations from the coder agent to the pipeline: branch creation, committing, PR creation, and PR title extraction. Include `_extract_pr_title()` (searches for `TITLE:` prefix anywhere in Claude output, with oldest-commit fallback) and `_extract_pr_body()`. Handle PR description generation from diff using Claude. Write `tests/test_git_ops.bats`.

## Task 8: Coder agent, hooks, and prompts

Implement lib/coder.sh. Use lib/claude.sh helpers for invocation. Use config for timeout and account. Read prompts/implement.md at runtime. Include context files from `AUTOPILOT_CONTEXT_FILES` config. Instruct coder to commit progressively (not one big batch). Also create lib/hooks.sh — installs lint/test Stop hooks on the coder agent for real-time edit validation. Hooks are installed before spawning coder/fixer and cleaned up after. Create all prompt files in prompts/: implement.md, fix-and-merge.md, merge-review.md, fix-tests.md, diagnose.md, spec-compliance.md, summarize.md. Use `${AUTOPILOT_BRANCH_PREFIX}/task-N` for branch naming. Write `tests/test_coder.bats` and `tests/test_hooks.bats`.

## Task 9: Test gate

Implement lib/testgate.sh. Support custom test command from `AUTOPILOT_TEST_CMD` — when set, bypass the allowlist entirely. Auto-detect if not configured: check for pytest, npm test, bats, make test (in that order). Add `bats` to the allowlist. Support background execution in a detached git worktree for parallel test+review. Use Stop hook SHA flags to skip redundant re-runs when the coder's hooks already verified tests pass. Export exit code constants used by postfix.sh and merger.sh. Write `tests/test_testgate.bats`.

## Task 10: Session cache and pre-warming

Create lib/session-cache.sh. Pre-warm Claude sessions with project context using content-hash memoization. Hash project files (CLAUDE.md, context files) to detect changes and invalidate cache. Use macOS-portable `realpath` shim. Write `tests/test_session_cache.bats`.

## Task 11: Fixer agent with session resume

Implement lib/fixer.sh. Use lib/claude.sh helpers. Use config for timeout and account. Fetch review comments from GitHub API via `gh api`. Implement session resume via `--resume` flag (lookup chain: fixer JSON → coder JSON → cold start). Install coder hooks before spawning fixer (via lib/hooks.sh). Include diagnosis hints from merger rejection in the fixer prompt. Write `tests/test_fixer.bats`.

## Task 12: Reviewer core — diff fetching and parallel review execution

Build the first half of lib/reviewer.sh. Fetch PR diff with metadata header via `gh pr diff`. Guard against oversized diffs (`AUTOPILOT_MAX_DIFF_BYTES`). Create reviewer persona files in reviewers/: general.md, security.md, performance.md, dry.md, design.md. For each persona in `AUTOPILOT_REVIEWERS`, spawn Claude in parallel with persona prompt + diff piped via stdin. Use `AUTOPILOT_TIMEOUT_REVIEWER_CLAUDE` as per-call timeout and `AUTOPILOT_TIMEOUT_REVIEWER` as outer timeout. Write `tests/test_reviewer.bats`.

## Task 13: Reviewer posting — comment formatting, dedup, clean-review skip, and state update

Build the second half of lib/reviewer.sh. Format review comments with reviewer display name and SHA tag. Post via `gh pr comment`. Track reviewed SHAs in `.autopilot/reviewed.json`. Skip posting if reviewer response matches the "no issues" sentinel. Detect when all reviewers return clean results and expose this for the dispatcher's reviewed→fixed skip. Write `tests/test_reviewer_posting.bats`.

## Task 14: Post-fix verification

Implement lib/postfix.sh. Run test gate after fixer completes. Spawn fix-tests agent if tests fail. Include fixer push verification (SHA comparison before/after). Graceful degradation if `gh api` fails. Write `tests/test_postfix.bats`.

## Task 15: Merger

Implement lib/merger.sh. Use lib/claude.sh helpers for invocation and `extract_claude_text` for parsing APPROVE/REJECT response. Use config for timeout (`AUTOPILOT_TIMEOUT_MERGER`, default 600s) and account. Squash-merge via `gh pr merge --squash`. Include diagnosis hints in rejection comments for the next fixer cycle. Write `tests/test_merger.bats`.

## Task 16: Smoke test — source all libs

Replace `tests/test_smoke.bats` (from Task 1). Source all lib/*.sh files in a subshell. Verify no syntax errors, no variable conflicts, no function name collisions.

## Task 17: Context accumulation

Implement lib/context.sh. Generate task summaries via Claude in the background (non-blocking). Use `AUTOPILOT_TIMEOUT_SUMMARY` and `AUTOPILOT_MAX_SUMMARY_LINES`. Append to `.autopilot/completed-summary.md`. Write `tests/test_context.bats`.

## Task 18: Metrics tracking

Implement lib/metrics.sh. CSV tracking for per-task metrics, phase timing (including `test_fixing_sec` column), and token usage. Per-phase timing with sub-step instrumentation (TIMER tags). CSV header auto-update on schema change. Do NOT include `extract_claude_text` — it lives in lib/claude.sh (Task 5). Write `tests/test_metrics.bats`.

## Task 19: Failure diagnosis

Implement lib/diagnose.sh. Spawn diagnostician agent on max retries. Handle log file selection for all states including `test_fixing` (reads fix-tests log). Use lib/claude.sh helpers and config for `AUTOPILOT_TIMEOUT_DIAGNOSE`. Write `tests/test_diagnose.bats`.

## Task 20: Spec compliance review

Implement lib/spec-review.sh. Use `AUTOPILOT_SPEC_REVIEW_INTERVAL` — when set to 0, disable entirely (skip the `should_run_spec_review` check). Use `AUTOPILOT_TIMEOUT_SPEC_REVIEW` for the review timeout. Use lib/claude.sh helpers. Write `tests/test_spec_review.bats`.

## Task 21: Dispatcher (main orchestrator)

Build bin/autopilot-dispatch. Implement quick guards (PAUSE file, lock PID checks) for 15-second cron — exit in <10ms on no-op ticks. Full state machine including: `test_fixing` state, `completed` terminal state, crash recovery in `merging` state, clean-review skip (reviewed→fixed when all reviewers return no issues), background test gate in parallel with reviewer, coder hooks installed/cleaned around all agent spawns, fixer push verification, stale branch reset for pending tasks, diagnosis hints from merger rejection fed to next fixer. Write `tests/test_dispatcher.bats` covering state machine transitions with mocked functions.

## Task 22: Reviewer cron entry

Build bin/autopilot-review. Quick guards (same pattern as dispatcher). Two modes: (1) cron mode — detect `pr_open` state and run review cycle, (2) standalone mode — `autopilot-review PR_NUMBER` for ad-hoc review of any PR. Trigger review immediately on pr_open transition. Write `tests/test_review_entry.bats`.

## Task 23: Install script and examples

Implement `make install` target — verify dependencies (including macOS `timeout` check with guidance), symlink binaries to `~/.local/bin/` (or `PREFIX=` override), print setup instructions. Create `examples/autopilot.conf` (fully commented with all `AUTOPILOT_*` variables) and `examples/tasks.example.md`. Write `tests/test_install.bats`.

## Task 24: Documentation — README and getting-started

Write full README.md (what it does, quick start, state machine diagram, requirements including macOS timeout note). Write docs/getting-started.md (prerequisites, installation, first project walkthrough, pausing/resuming, troubleshooting).

## Task 25: Documentation — configuration and task format

Write docs/configuration.md (all AUTOPILOT_* variables, account setup, custom reviewers, permission model with TTY detection). Write docs/task-format.md (both formats, examples, context files via AUTOPILOT_CONTEXT_FILES config).

## Task 26: Documentation — architecture

Write docs/architecture.md (state machine with clean-review skip, background test gate, coder hooks, crash recovery, lock/concurrency model, metrics and logging, how prompts and reviewer personas work, extending with custom reviewers).

## Task 27: launchd scheduler

Replace crontab with native macOS launchd plists. Create two plist templates in `plists/`: `com.autopilot.dispatcher.plist` and `com.autopilot.reviewer.plist` with configurable `StartInterval` (default 15s). Add `make install-launchd` (copies plists to `~/Library/LaunchAgents/`, substitutes project path and account number, runs `launchctl load`) and `make uninstall-launchd` (unload + remove plists). Plists should set `PATH`, `StandardOutPath`/`StandardErrorPath` for logging, and `KeepAlive=false`. Add a `bin/autopilot-schedule` helper that generates and installs plists for a given project directory. Write `tests/test_launchd.bats` covering plist generation and variable substitution.

## Task 28: Self-migration to launchd

Run `make install-launchd` targeting this project (`/Users/alex/projects/autopilot/autopilot`) with account 1 for dispatcher and account 2 for reviewer. Verify the launchd agents are loaded and ticking. Remove the autopilot crontab entries. Verify the pipeline continues operating under launchd by confirming at least one successful dispatcher tick in the launchd logs.

## Task 29: Integration and stress tests

Add `tests/test_integration.bats` covering cross-module interactions that unit tests miss. When a test reveals a real bug, fix the bug in the same PR — don't just document it.

Test scenarios:
- **Config → State → Lock lifecycle**: load config, init pipeline, acquire/release locks, verify state transitions respect config values (timeouts, retry limits).
- **Concurrent dispatcher safety**: simulate two dispatchers racing — only one should acquire lock, the other exits cleanly. Test stale lock detection with dead PIDs.
- **State machine full path**: walk a task through every state transition (pending → implementing → test_fixing → pr_open → reviewed → fixing → reviewed → merging → completed) with mocked agents. Verify state.json is correct at each step.
- **Crash recovery**: kill mid-state (corrupt state.json with partial write, leave orphan lock files, leave state stuck in `merging`). Verify dispatcher recovers gracefully on next tick.
- **Config edge cases**: malformed config files (missing `=`, extra whitespace, non-AUTOPILOT_ lines, duplicate keys, empty values), `autopilot.conf` + `.autopilot/config.conf` both present with conflicting values.
- **Task parsing edge cases**: empty tasks file, tasks file with only comments, task numbers with gaps, mixed `## Task N` and `### PR N` formats in same file.
- **Lock file races**: acquire lock, verify PID written, simulate stale lock (write a dead PID), verify next acquire detects and steals it.
- **Log rotation**: write more than `AUTOPILOT_MAX_LOG_LINES` entries, verify rotation truncates correctly without losing the most recent entries.
- **Metrics integrity**: run multiple phases, verify CSV has correct columns, no missing rows, timing values are non-negative.
- **Reviewer dedup**: post review, verify SHA tracked in reviewed.json, re-run review on same SHA, verify no duplicate comment posted.
- **Clean-review skip**: all reviewers return "no issues" sentinel, verify state skips from reviewed directly to fixed.
- **Background test gate**: verify test gate runs in detached worktree, doesn't pollute main working tree.

## Task 30: Increase spec review timeout and run async

Bump `AUTOPILOT_TIMEOUT_SPEC_REVIEW` default from 300s to 1200s. Run spec review asynchronously — spawn it in the background so it doesn't block the dispatcher's main loop. Log the background PID and check for completion on subsequent ticks. Also increase `MAX_SPEC_BYTES` so the plan document isn't truncated from 40KB to 8KB (use 50000). Update `tests/test_spec_review.bats` to cover the async execution path and the new defaults.

## Task 31: Auto-detect claude binary location in plist PATH

The launchd plist template (`plists/com.autopilot.agent.plist`) hardcodes PATH to `__AUTOPILOT_BIN_DIR__:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`. When `claude` is installed to `~/.local/bin` (the default `make install` location), launchd agents fail with exit code 127 because that directory isn't in PATH.

Fix `bin/autopilot-schedule` so that `_substitute_plist()` auto-detects the directory containing the `claude` binary (via `command -v "${AUTOPILOT_CLAUDE_CMD:-claude}"`) and includes it in the plist PATH. If `AUTOPILOT_CLAUDE_CMD` is an absolute path, extract its directory. If it's a bare command name, resolve it via `command -v`. Add the resolved directory to the plist PATH (after `__AUTOPILOT_BIN_DIR__`, before `/opt/homebrew/bin`). Also add `$HOME/.local/bin` as a fallback if it exists and isn't already in the PATH. Update the plist template to use a new `__CLAUDE_BIN_DIR__` placeholder. Write tests in `tests/test_launchd.bats` covering: claude in `~/.local/bin`, claude in `/opt/homebrew/bin` (no extra dir needed), absolute `AUTOPILOT_CLAUDE_CMD` path, bare command name resolved via PATH.

## Task 32: Preflight check validates launchd PATH consistency

The preflight check in `lib/preflight.sh` validates that `claude` is on PATH via `command -v`, but this only checks the current shell's PATH. When running under launchd, the PATH is different (hardcoded in the plist), so preflight can pass interactively but fail under launchd.

Add a new preflight check: if a launchd plist exists for the current project (check `~/Library/LaunchAgents/com.*.plist` files whose `WorkingDirectory` matches the project dir), parse its PATH value and verify that `claude`, `gh`, `jq`, `git`, and `timeout` are all findable under that PATH. Log a WARNING (not CRITICAL) if any dependency is missing from the launchd PATH, with a message like: `"claude found at /Users/x/.local/bin/claude but this directory is not in the launchd plist PATH — launchd agents will fail. Run 'autopilot-schedule' to regenerate plists."` Write tests in `tests/test_preflight.bats`.

## Task 33: Fix retry guard bypass in merger error path

**Bug:** When `_handle_merger_result()` in `lib/dispatch-handlers.sh` hits the `*` (error/default) case, it calls `increment_retry` + `update_status "reviewed"` directly — bypassing the MAX_RETRIES guard in `_retry_or_diagnose()`. This causes infinite retry loops: merger approves, squash-merge fails, retry_count increments past the limit (observed reaching 8/5 in production), status resets to `reviewed`, fixer runs with nothing to fix, tests pass, goes back to `fixed`, merger approves again, squash-merge fails again, forever.

**Root cause:** The coder and fixer error paths correctly call `_retry_or_diagnose()` (which checks `retry_count >= max_retries` before incrementing). But `_handle_merger_result`'s `*` case and three crash-recovery paths (`_handle_implementing`, `_handle_fixing`, `_handle_merging`) call `increment_retry` directly without checking the guard.

**Fix:**
1. In `_handle_merger_result()` `*` case: replace `increment_retry "$project_dir"` + `update_status "$project_dir" "reviewed"` with a call to `_retry_or_diagnose "$project_dir" "$task_number" "merging"`. This ensures the pipeline stops and runs diagnosis when MAX_RETRIES is exceeded.
2. In `_handle_implementing()` crash recovery: replace `increment_retry` + `update_status "pending"` with `_retry_or_diagnose "$project_dir" "$task_number" "implementing"`.
3. In `_handle_fixing()` crash recovery: replace `increment_retry` + `update_status "reviewed"` with `_retry_or_diagnose "$project_dir" "$task_number" "fixing"`.
4. In `_handle_merging()` crash recovery: replace `increment_retry` + `update_status "reviewed"` with `_retry_or_diagnose "$project_dir" "$task_number" "merging"`.
5. Verify `_retry_or_diagnose` handles all these source phases correctly (it may need a parameter adjustment if it currently assumes the caller is always from a specific phase).
6. Write tests in `tests/test_dispatcher.bats` covering: merger error with retry_count < max → retries, merger error with retry_count >= max → calls diagnosis and stops, crash recovery with retry_count >= max → calls diagnosis and stops.

## Task 34: Mock `gh` and `claude` test harness for integration tests

Create reusable mock scripts in `tests/fixtures/bin/` that shadow the real `gh` and `claude` binaries when prepended to PATH.

**`tests/fixtures/bin/gh`**: A bash script that pattern-matches on subcommands and returns configurable responses. Behavior is controlled via env vars and fixture files:
- `GH_MOCK_DIR` — directory containing response fixtures (JSON files).
- `gh pr create` → reads `$GH_MOCK_DIR/pr-create-response.txt` (default: echoes `https://github.com/test/repo/pull/1`). Records the call args to `$GH_MOCK_DIR/pr-create-calls.log` for assertion.
- `gh pr view` → reads `$GH_MOCK_DIR/pr-view.json` (allows tests to set mergeable status, state, etc).
- `gh pr list` → reads `$GH_MOCK_DIR/pr-list.json` (default: empty array `[]`).
- `gh pr merge` → echoes "merged", records call to `$GH_MOCK_DIR/pr-merge-calls.log`.
- `gh pr diff` → reads `$GH_MOCK_DIR/pr-diff.txt`.
- `gh api` → reads `$GH_MOCK_DIR/api-response.json`.
- `GH_MOCK_EXIT` — override exit code for any command (for testing failure paths).
- All calls logged to `$GH_MOCK_DIR/gh-calls.log` with full args for debugging.

**`tests/fixtures/bin/claude`**: A bash script that simulates a coder agent. Controlled via env vars:
- `CLAUDE_MOCK_DIR` — directory containing behavior config.
- Default behavior: reads `$CLAUDE_MOCK_DIR/actions.sh` and sources it (allowing tests to define what files to create/modify/commit). If no actions file, creates a single file and commits it.
- Outputs JSON to stdout matching Claude's `--output-format json` shape: `{"result": "Task complete.", "session_id": "mock-session-123"}`.
- `CLAUDE_MOCK_EXIT` — override exit code.
- `CLAUDE_MOCK_NO_PUSH` — if set, commits but does not push (simulates the bug from Task 38).

**`tests/fixtures/`**: Create default fixture files for common scenarios: `pr-view-clean.json` (mergeable, clean), `pr-view-conflicting.json` (conflicting), `pr-list-empty.json`, `pr-list-with-pr.json`.

Write `tests/test_mock_harness.bats` verifying: mock `gh` returns correct responses for each subcommand, call logging works, exit code override works, mock `claude` creates files and commits, mock `claude` respects `CLAUDE_MOCK_NO_PUSH`. No new dependencies — only bash, jq (already required), git, and file I/O.

## Task 35: New-project deployment smoke test

Using the mock harness from Task 41, test the full "deploy autopilot to a new project" flow.

Create `tests/test_deploy_smoke.bats`:

1. **Setup**: Create a temp git repo with a minimal `tasks.md` (one trivial task), a `CLAUDE.md`, and an `autopilot.conf` with `AUTOPILOT_CLAUDE_FLAGS=--dangerously-skip-permissions` and `AUTOPILOT_REPO=test/repo`. Initialize `.autopilot/` state.

2. **Plist generation**: Run `autopilot-schedule` against the temp project. Verify:
   - Generated dispatcher plist has correct PATH (includes `~/.local/bin`).
   - Generated reviewer plist does NOT pass extra positional args (no account number as arg 2).
   - Both plists have `CLAUDE_CONFIG_DIR` set in EnvironmentVariables.
   - `WorkingDirectory` points to the project.

3. **Preflight**: Source the libs and run `run_preflight` against the temp project with mock `gh` and `claude` on PATH. Verify it passes.

4. **Reviewer skip**: Set state to `pending`. Run the reviewer entry point logic. Verify it exits cleanly with "not pr_open — skipping" (not trying to review a phantom PR).

5. **Argument rejection**: Run `autopilot-review /path/to/project 2` (extra positional arg). Verify it prints usage and exits non-zero (once Task 36 is implemented).

Tests validate Tasks 31-36 working together end-to-end.

## Task 36: Full dispatcher cycle integration test

Using the mock harness from Task 41, test the full dispatcher state machine cycle.

Create `tests/test_dispatcher_cycle.bats`:

1. **Happy path — pending to pr_open**: State is `pending`, task 1. Mock `claude` creates a file and commits (but does NOT push — simulating the common coder behavior). Run one dispatcher tick. Verify: dispatcher detects local commits, pushes via mock `git push`, creates PR via mock `gh pr create`, state advances to `pr_open`, `pr_number` is written to state.

2. **Stale branch recovery**: Leave the temp repo checked out on `autopilot/task-1`. Reset state to `pending`. Run one dispatcher tick. Verify: dispatcher checks out main, deletes the stale branch, recreates it, spawns coder, state advances to `implementing`.

3. **Coder timeout recovery**: Mock `claude` with `CLAUDE_MOCK_EXIT=124` (timeout). Verify: dispatcher increments retry count, state goes back to `pending`, any local commits are preserved (not lost).

4. **Coder crash recovery**: Mock `claude` with `CLAUDE_MOCK_EXIT=1`. Verify: retry incremented, state back to `pending`.

5. **Full cycle to merge**: Walk through pending→implementing→pr_open→reviewed→merging→completed with mocked agents at each step. Verify state.json is correct at each transition. Verify metrics CSV has a row for the completed task.

Tests validate Tasks 37-38 and the core state machine with realistic agent behavior.

## Task 37: Squash-merge rebase integration test

Using the mock harness from Task 41, test the auto-rebase behavior after squash merges.

Create `tests/test_rebase_cycle.bats`:

1. **Setup**: Create a temp repo. Simulate Task 1 completion: create `autopilot/task-1` branch with a commit, squash-merge it to main (creating a different SHA than the original commit). Create `autopilot/task-2` branch from pre-merge main (so it contains the original Task 1 commit, not the squash). Add a Task 2 commit on top.

2. **Conflict detection**: Set mock `gh pr view` to return `{"mergeable": "CONFLICTING", "mergeStateStatus": "DIRTY"}`. Run the merger/pre-merge logic. Verify: dispatcher detects the conflict BEFORE calling the merger agent.

3. **Auto-rebase succeeds**: The conflict from step 2 should be auto-resolvable (same changes, different SHAs). Verify: `rebase_task_branch()` runs `git rebase origin/main`, succeeds, force-pushes the rebased branch. After rebase, mock `gh pr view` returns `CLEAN`. State proceeds to merging.

4. **Auto-rebase fails**: Create a scenario with a real conflict (Task 2 modifies a line that the squash-merge also modified differently). Verify: rebase is attempted, fails, `git rebase --abort` is called, fixer is spawned with a hint about the rebase conflict.

5. **No rebase needed**: Mock `gh pr view` returns `CLEAN` from the start. Verify: no rebase attempted, merger runs directly.

Tests validate Task 40 end-to-end.

## Task 38: Document launchd PATH requirements

Update `docs/getting-started.md`, `docs/configuration.md`, and `README.md` to document the launchd PATH issue clearly:

1. In getting-started.md under the "Schedule the Pipeline" section, add a subsection "Claude Binary Location" explaining that launchd agents don't inherit shell PATH from `~/.zshrc`. Document two solutions: (a) re-run `autopilot-schedule` which now auto-detects claude's location (Task 31), or (b) set `AUTOPILOT_CLAUDE_CMD` to an absolute path in `autopilot.conf`.

2. In configuration.md, update the `AUTOPILOT_CLAUDE_CMD` entry to include an example showing the absolute path workaround: `AUTOPILOT_CLAUDE_CMD="/Users/you/.local/bin/claude"`.

3. In README.md troubleshooting section, add a "launchd: exit code 127" entry explaining the PATH mismatch and how to fix it.

4. In examples/autopilot.conf, add a commented example for `AUTOPILOT_CLAUDE_CMD` with a note about launchd PATH.

## Task 39: Add `~/.local/bin` to existing plist template fallback PATH

As a belt-and-suspenders fix alongside Task 31's auto-detection: update the plist template `plists/com.autopilot.agent.plist` to include `__HOME__/.local/bin` in the default PATH string (between `__AUTOPILOT_BIN_DIR__` and `/opt/homebrew/bin`). The `__HOME__` placeholder should already be substituted by `_substitute_plist()` — verify this and add it if missing. This ensures that even if auto-detection fails or the user manually creates plists, `~/.local/bin` is always searched. Write a test in `tests/test_launchd.bats` verifying the generated plist PATH includes `~/.local/bin`.

## Task 40: Document multi-account setup for dispatcher and reviewer

Autopilot uses separate Claude Code config directories so the dispatcher (coder/fixer) and reviewer run under different accounts. This avoids rate-limit contention and keeps billing separate. Currently this is undocumented.

1. In `docs/getting-started.md`, add a section "Multi-Account Setup" explaining: why two accounts are needed (dispatcher spawns coder/fixer on account 1, reviewer runs on account 2 — they often run concurrently), how `CLAUDE_CONFIG_DIR` works (each account has its own `~/.claude-accountN/` with separate settings.json, API keys, and session state), and how `bin/autopilot-schedule` assigns accounts to launchd agents via the account number argument (arg 3 of the entry point scripts).

2. In `docs/configuration.md`, document the account number parameter for `bin/autopilot-dispatch` and `bin/autopilot-review` (the second positional argument after project dir). Explain that the account number maps to `CLAUDE_CONFIG_DIR=~/.claude-account{N}` and that each agent's plist sets this env var. Document `AUTOPILOT_REVIEWER_CONFIG_DIR` if it exists, or the mechanism by which the reviewer uses a different account than the dispatcher.

3. In `README.md`, add a brief note in the quick-start section that autopilot works best with two Claude accounts and link to the multi-account docs.

4. In `examples/autopilot.conf`, add commented examples showing account-related config if any exist.

5. Verify the launchd plist template includes the `CLAUDE_CONFIG_DIR` env var with an `__ACCOUNT_CONFIG_DIR__` placeholder (or equivalent). If missing, add it and update `_substitute_plist()` in `bin/autopilot-schedule` to substitute it based on the account number argument.

## Task 41: Fix autopilot-review arg parsing — account number vs PR number collision

**Bug:** `bin/autopilot-review` treats its second positional argument as a PR number for standalone review mode. But when launched from launchd, the plist passes the account number as arg 2 (e.g., `autopilot-review /path/to/project 2`). This causes the reviewer to attempt reviewing a nonexistent PR every 15 seconds, flooding the log with errors and hitting the GitHub API repeatedly.

**Root cause:** The entry points were designed for interactive use (where arg 2 = PR number for standalone review), but launchd plists inherited the devops `reviewer-cron.sh` calling convention (where arg 2 = account number). The autopilot entry points don't need an account number argument — they get `CLAUDE_CONFIG_DIR` from the environment. But `autopilot-review` has no way to distinguish an account number from a PR number.

**Fix:**
1. In `bin/autopilot-review`, remove the positional PR number argument. Standalone review should use a flag instead: `autopilot-review /path/to/project --pr 42` (or `--pr-number 42`). This eliminates the ambiguity — any unexpected positional arg after the project dir should be rejected with an error message.
2. Add argument validation: if more than 1 positional argument is provided, print usage and exit with error. This prevents silent misinterpretation.
3. Similarly update `bin/autopilot-dispatch` to reject unexpected positional arguments beyond the project dir.
4. Update `bin/autopilot-schedule` plist generation to NOT pass an account number argument to either entry point (account is handled via `CLAUDE_CONFIG_DIR` env var in the plist).
5. Update docs and README examples that show standalone review usage.
6. Write tests in `tests/test_review_entry.bats` covering: flag-based PR number, rejection of bare positional PR number, rejection of extra positional args, cron mode with no extra args.

## Task 42: Dispatcher stale-branch reset must handle checked-out branch

**Bug:** When the dispatcher detects a "stale branch" for a task (branch exists but state is `pending`), it tries to delete and recreate the branch. But if the repo's working tree is currently checked out to that branch (`git branch` shows `* autopilot/task-N`), the delete-then-create cycle fails because you can't delete the current branch in git. This puts the dispatcher in a tight loop: every 15-second tick it detects "stale branch", fails to recreate it, and logs errors.

**Fix:**
1. In the stale branch reset logic (in `lib/dispatch-helpers.sh` or wherever `_reset_stale_branch` / stale branch handling lives), before deleting the branch, check if it's the current branch (`git rev-parse --abbrev-ref HEAD`). If so, `git checkout main` first.
2. After checking out main, then delete the stale branch and recreate it.
3. Add a guard: if branch deletion fails, log a clear error and don't attempt branch creation (currently it deletes, fails to create, and the error message is confusing).
4. Also handle the case where `main` itself is not available (e.g., the default branch is `master`): use `git symbolic-ref refs/remotes/origin/HEAD` to find the default branch.
5. Write tests in `tests/test_git_ops.bats` or `tests/test_dispatcher.bats` covering: stale branch when checked out, stale branch when not checked out, branch deletion failure handling.

**Note:** A hotfix for this bug has already been applied directly to `lib/git-ops.sh` on main (commit `fea5c45`). The `delete_task_branch()` function now checks if the branch is currently checked out and runs `git checkout "$target"` before deleting. Your job is to verify the hotfix is correct, add the additional guards described above (deletion failure handling, default branch detection), and write the tests.

## Task 43: Address orphaned review feedback from Task 41 (PR #45)

**Context:** PR #45 (Task 41: fix autopilot-review arg parsing) was merged before all reviewers completed. The design and general reviewers posted feedback after the merge. These findings are valid and should be addressed.

**Fixes needed:**

1. **Add numeric validation on `--pr` value** (`bin/autopilot-review`, `_handle_extra_flag`):
   After `PR_NUMBER_ARG="$2"`, add: `[[ "$PR_NUMBER_ARG" =~ ^[0-9]+$ ]] || { echo "Error: PR number must be a positive integer, got '$PR_NUMBER_ARG'" >&2; _usage >&2; exit 1; }`. Currently `--pr abc` or `--pr --help` silently passes garbage downstream.

2. **Initialize `EXTRA_FLAG_SHIFT` before callback** (`lib/entry-common.sh`, `parse_base_args`):
   Set `EXTRA_FLAG_SHIFT=0` before calling `_handle_extra_flag`. Add a guard after: `[[ "$EXTRA_FLAG_SHIFT" -gt 0 ]]` or log a BUG message. Prevents cryptic "unbound variable" crash if a future flag handler forgets to set it.

3. **Strengthen `--pr` flag test assertions** (`tests/test_review_entry.bats`):
   The `--pr` tests only check exit code 0. They should also assert that the mock `gh` was called with the correct PR number (42, not the cron-mode PR 10 from state). Check `$GH_MOCK_DIR/gh-calls.log` for the expected PR number in the args.

4. **Fix usage synopsis** (`bin/autopilot-review`, `_usage`):
   Change `Usage: autopilot-review [OPTIONS] PROJECT_DIR` to match the examples which show options-last. Use `Usage: autopilot-review [PROJECT_DIR] [OPTIONS]` or indicate they're freely intermixed. Mark `PROJECT_DIR` as optional (defaults to `.`).

Write tests for the numeric validation: `--pr foo` exits non-zero, `--pr ""` exits non-zero, `--pr 42` works, `--pr` with no value exits non-zero.

## Task 44: Performance — model config, parallel tests, parallel lint

**Goal:** Reduce pipeline cycle time by configuring the model explicitly and running tests/lint in parallel.

**Part 1: `AUTOPILOT_CLAUDE_MODEL` config variable.**
1. Add `AUTOPILOT_CLAUDE_MODEL` to `_AUTOPILOT_KNOWN_VARS` in `lib/config.sh`.
2. Set its default to `"opus"` in `_set_defaults()`.
3. In `_build_base_cmd_args()` in `lib/claude.sh`: if `AUTOPILOT_CLAUDE_MODEL` is non-empty, append `"--model" "$AUTOPILOT_CLAUDE_MODEL"` to the command array.
4. Update `examples/autopilot.conf` with a commented example: `#AUTOPILOT_CLAUDE_MODEL="opus"`.
5. Write tests in `tests/test_claude.bats`: model flag appears in command when set, model flag absent when empty, model override via env var.

**Part 2: Parallel bats tests with `--jobs`.**
1. Add `parallel` to the preflight dependency check in `lib/preflight.sh` (install hint: `brew install parallel`).
2. Change the Makefile `test` target from `bats tests/` to `bats --jobs 10 tests/`. The Mac Mini M4 has 10 cores.
3. Write a test in `tests/test_smoke.bats` or `tests/test_preflight.bats` that verifies `parallel` is available.

**Part 3: Parallel lint + test in Makefile.**
1. Add a new `check` target to the Makefile that runs `make lint` and `make test` in parallel using background processes:
   ```makefile
   check:
   	@make lint & lint_pid=$$!; make test & test_pid=$$!; \
   	wait $$lint_pid; lint_rc=$$?; wait $$test_pid; test_rc=$$?; \
   	exit $$(( lint_rc + test_rc ))
   ```
2. Update any documentation or references that mention running lint and test separately to use `make check` instead.

## Task 45: Parallel test gate and reviewer submission

**Goal:** After the coder finishes, the pipeline currently runs the test gate synchronously, THEN transitions to `pr_open`, THEN the reviewer cron picks it up on the next tick. Since reviews go to the Claude API (not local CPU), they can run concurrently with the local test gate.

**Changes:**

**Part 1: Use background test gate.** `run_test_gate_background()` already exists in `lib/testgate.sh` (creates a worktree, runs tests in background, writes result to file) but is never called. Wire it up:
1. In `_handle_coder_result()` in `lib/dispatch-handlers.sh`: after pushing the branch and creating the PR, call `run_test_gate_background` instead of `run_test_gate`. Store the background PID in state.
2. Transition to `pr_open` immediately (don't wait for test gate to finish).
3. In `_handle_pr_open()` (currently a no-op): check if the background test gate completed by reading the result file. If it failed, transition to `test_fixing`. If passed or still running, stay in `pr_open`.

**Part 2: Trigger reviewer immediately on pr_open.** Don't wait for the reviewer cron to poll (wastes 15-60s). After transitioning to `pr_open`, fire the reviewer in the background:
1. In `_handle_coder_result()`, after `update_status "pr_open"`: spawn `reviewer-cron.sh "$project_dir" "$AUTOPILOT_REVIEWER_ACCOUNT"` as a background process with a 3-second delay. The reviewer cron stays as a safety net.
2. This mirrors the devops implementation (PR #79) which saves 30-60s per task.

**Part 3: Independent failure handling.** Lint, tests, and reviews should all run independently — none cancels the others:
1. If lint fails, tests still run. If tests fail, reviews still run. Each posts its own result.
2. The fixer receives ALL feedback (lint errors + test failures + review comments) and addresses everything in one pass.
3. Write tests verifying: background test gate runs concurrently with reviewer, test gate failure after review still triggers `test_fixing`, test gate pass with clean reviews skips fixer, reviewer triggered immediately on pr_open (not waiting for cron).

## Task 46: Skip redundant merger tests

**Bug:** The merger re-runs the full test suite on the PR branch, but the fixer's post-fix verification already confirmed tests pass on the exact same HEAD seconds earlier. Nothing pushes between those two steps. This wastes ~3 minutes per task.

**Reference:** Devops PR #80 fixed this same issue.

**Fix:**
1. In the merger flow (likely `_handle_fixed` or `run_merger` in `lib/merger.sh`): check if the fixer's post-fix verification already passed on the current branch HEAD. If so, skip the merger's test run entirely.
2. Use the existing `is_sha_verified()` / `read_hook_sha_flag()` mechanism from `lib/testgate.sh` — if the SHA matches, tests have already passed.
3. If the SHA doesn't match (e.g., someone pushed to the branch between fixer and merger), run tests as normal.
4. Write tests covering: SHA matches → skip tests, SHA doesn't match → run tests, no SHA flag → run tests.

## Task 47: Finalize lock to prevent double-advancing after merge

**Bug:** Two dispatcher ticks can enter `_handle_merged()` concurrently. The summary generation step (a Claude call taking 5-15s) leaves a window where a second tick also enters `_handle_merged`, calls `advance_task()`, and double-advances `current_task`. This orphans the coder that was spawned for the skipped task.

**Reference:** Devops PR #66 fixed this with `acquire_lock "finalize"` in `_finalize_merged_task` and an `advance_task` guard that only allows advancement from the `merged` status.

**Fix:**
1. In `_handle_merged()` in `lib/dispatch-handlers.sh`: acquire a `finalize` lock before doing any work. Release it at the end (or via trap).
2. Add a guard in the task advancement logic: only increment `current_task` if `status` is still `merged`. If another tick already advanced it, log a warning and return early.
3. Write tests covering: concurrent tick simulation (second tick sees status already changed), lock prevents double-entry, lock released on error.

## Task 48: Pull main after merge before next task

**Bug:** After a PR merges, `_handle_merged()` advances the task number and sets status to `pending`, but never pulls the latest main. The next task branches from stale code — it doesn't include the just-merged PR's changes. This accumulates merge conflicts with each successive task.

**Fix:**
1. In `_handle_merged()` (or a new `_finalize_merged_task` helper): after advancing the task, run `git checkout main && git pull --ff-only origin main` to ensure the working tree has all merged changes before the next task branches off.
2. If the pull fails (e.g., network issue), log a warning but don't block — the next `_handle_pending` will attempt branch creation from whatever state main is in, and the preflight check will catch a dirty working tree.
3. Write tests covering: main is pulled after merge, pull failure is non-fatal, next task branches from up-to-date main.

## Task 49: Spec review must work without AUTOPILOT_CONTEXT_FILES

**Problem:** The spec compliance review (every 5th task) silently skips because `_get_spec_file()` in `lib/spec-review.sh` relies on `AUTOPILOT_CONTEXT_FILES` being configured. When it's empty (the default), the review logs `"No spec file found in context files — skipping"` and does nothing. This has been broken since task 30 — the review triggers but never runs.

**Principle:** The pipeline should work with zero configuration. The spec review should auto-detect a spec to review against, just like `detect_tasks_file()` auto-detects the tasks file.

**Fix:** Make `_get_spec_file()` fall back to the tasks file when no context files are configured.

**Implementation:**
1. In `_get_spec_file()` (`lib/spec-review.sh` line 73-76): after checking `parse_context_files()`, fall back to `detect_tasks_file "$project_dir"` if the result is empty. The tasks file IS the spec — it describes what each task should build, and the spec review checks whether merged PRs actually did that.
2. Log which file is being used as the spec: `"SPEC_REVIEW: using <path> as spec (source: context-files|tasks-file)"` so it's clear where the spec came from.
3. Write tests in `tests/test_spec_review.bats` covering: context files configured → uses first context file, no context files → falls back to tasks file, no context files and no tasks file → skips with warning.

## Task 50: Fix merger verdict parsing word boundary

**Bug:** The merger verdict parsing in `lib/merger.sh` uses `=~ VERDICT:[[:space:]]*(APPROVE|REJECT)` to extract the merger's decision. While the `VERDICT:` prefix helps, the regex doesn't enforce word boundaries on the APPROVE/REJECT token. If the merger's review text contains words like "rejection", "rejected", or "disapproval" near a VERDICT line, it could produce a false match.

**Reference:** Devops PR #92 fixed this exact bug — `grep -oiE '(APPROVE|REJECT)'` matched "reject" inside "rejection", flipping APPROVE verdicts to REJECT with `tail -1`.

**Fix:**
1. In `lib/merger.sh`: tighten the verdict regex to enforce word boundaries. Use `=~ VERDICT:[[:space:]]*(APPROVE|REJECT)[[:space:]]*$` (anchor to end of line) or `=~ VERDICT:[[:space:]]*(APPROVE|REJECT)[^A-Z]` to prevent substring matches.
2. Add a fallback: if no clean VERDICT line is found, log a warning and default to REJECT (fail-safe).
3. Write tests covering: "VERDICT: APPROVE" → approve, "VERDICT: REJECT" → reject, review text containing "rejection" doesn't false-match, "VERDICT:APPROVE" (no space) still works, missing VERDICT line → reject.

## Task 51: Pipeline owns push and PR creation — not the coder


**Design change:** The coder prompt currently tells the agent to push commits and create PRs. This wastes tokens and time on operations the pipeline can do deterministically in seconds. It's also unreliable — agents sometimes skip the push/PR step (timeout, ran out of turns, conflicting CLAUDE.md instructions), which led to a hotfix fallback in `_handle_coder_result`.

The fix is to make the pipeline the primary owner of push + PR creation, not a fallback. The coder's only job is: write code and commit.

**Changes:**
1. In `_handle_coder_result()` in `lib/dispatch-handlers.sh`: after the coder exits successfully, the pipeline ALWAYS pushes the branch and creates a PR (using `push_branch` and `create_task_pr` from `lib/git-ops.sh`). Remove the "fallback" framing — this is the primary path. If a PR already exists (coder created one), detect it with `detect_task_pr` and skip creation.
2. Update `prompts/implement.md`: remove all instructions about `git push`, `gh pr create`, and PR creation. The coder should commit frequently but never push or create PRs. Add a clear note: "Do NOT push to the remote or create pull requests — the pipeline handles this automatically."
3. Similarly update `prompts/fix-and-merge.md` and `prompts/fix-tests.md`: remove push/PR instructions from fixer prompts.
4. In `_handle_coder_result()`: generate a proper PR title using `_extract_pr_title` (commit message fallback) and PR body using `generate_pr_body` (diff-based summary via Claude). The PR body generation is already implemented in `lib/git-ops.sh`.
5. Write tests in `tests/test_dispatcher.bats` covering: coder commits only (no push) → pipeline pushes and creates PR, coder already pushed → pipeline detects existing branch and creates PR, coder already created PR → pipeline detects it and skips, push failure → retry logic, no commits after coder → retry logic.

## Task 52: Tests for stale branch reset hotfix (delete_task_branch checkout-first)

**Context:** A hotfix was applied directly to `lib/git-ops.sh` (commit `fea5c45`) to fix a bug where `delete_task_branch()` failed silently when the task branch was currently checked out. The fix adds a check: if `git rev-parse --abbrev-ref HEAD` matches the branch being deleted, it runs `git checkout "$target"` first.

**Your job:**
1. Read the current `delete_task_branch()` in `lib/git-ops.sh` and verify the hotfix is correct.
2. Write tests in `tests/test_git_ops.bats` covering:
   - Delete a task branch that is NOT currently checked out → succeeds normally.
   - Delete a task branch that IS currently checked out → switches to target branch first, then deletes successfully.
   - After deletion of checked-out branch, working tree is on the target branch (not detached HEAD).
   - Delete when target branch (`main`) doesn't exist locally → falls back to `git symbolic-ref refs/remotes/origin/HEAD` or handles gracefully.
   - Branch deletion failure (e.g., branch doesn't exist) → logs error but doesn't crash.
   - Stale branch reset full cycle: branch exists and is checked out → delete → recreate from main → coder can proceed on fresh branch.
3. Also verify the corresponding `create_task_branch()` works correctly after the delete (the full delete+create cycle that the dispatcher runs).

## Task 53: PR title must use "Task N: title" from tasks.md

**Bug:** When the pipeline creates a PR (either via the dispatcher fallback or the coder), the title comes from `_extract_pr_title()` which uses the first commit message. This produces titles like "feat: add client config parsing..." instead of "Task 4: Client configuration parsing" (matching the tasks.md header).

Consistent PR titles are important for tracking — every PR should be identifiable as belonging to a specific task at a glance.

**Fix:**
1. Add a helper function `build_pr_title()` in `lib/git-ops.sh` that takes a project dir and task number, reads the tasks file, extracts the `## Task N: <title>` header line, and returns `"Task N: <title>"`.
2. In `_handle_coder_result()` (and wherever PRs are created by the pipeline): use `build_pr_title` as the primary title source. Only fall back to `_extract_pr_title` (commit message) if the tasks file header can't be parsed.
3. Update `create_task_pr()` to accept an optional title override, defaulting to `build_pr_title` if not provided.
4. Write tests in `tests/test_git_ops.bats` covering: title extracted from tasks.md header, title with special characters, fallback to commit message when header missing, task number not found in file.

## Task 54: Pipeline must retry when PR is closed without merging

**Bug:** When the merger closes a PR without merging (or the PR is closed externally), the pipeline advances `current_task` to the next number. This skips the task entirely — its code never lands on main. Observed in production: buildbanner PR #4 was closed (not merged), pipeline advanced to Task 5, Task 4's work was lost.

**Root cause:** The state machine transitions from `merging` to `pending` with `current_task` incremented, regardless of whether the merge actually succeeded. The `_handle_merger_result` APPROVE path calls `squash_merge_pr`, and if that fails, the error case increments retry (now fixed by Task 33). But if the PR is closed by the merger's REJECT verdict or externally, the pipeline may still advance.

**Fix:**
1. In the dispatcher's task-advancement logic: before incrementing `current_task`, verify that the PR was actually merged (check `gh pr view --json mergedAt` or `state=MERGED`). If the PR is closed but not merged, do NOT advance — reset to `pending` with the same task number so it retries from scratch.
2. Add a `_verify_pr_merged()` helper that checks the PR's merge status via `gh pr view`.
3. In the `merged` state handler: verify the PR is truly merged before advancing. If not, log an error and reset to `pending`.
4. Handle edge cases: PR deleted, PR reopened, network failure during verification.
5. Write tests in `tests/test_dispatcher.bats` covering: PR merged → advance, PR closed not merged → retry same task, PR still open → don't advance, gh API failure → don't advance (fail safe).

## Task 55: delete_task_branch must handle dirty working tree

**Bug:** `delete_task_branch()` in `lib/git-ops.sh` checks out the target branch before deleting the current branch. But if the working tree has uncommitted changes (e.g., a modified `package-lock.json` from `npm install`), `git checkout main` fails with "Your local changes would be overwritten." The error is swallowed by `|| true`, so the branch switch never happens and the branch can't be deleted. This puts the dispatcher in a stale-branch loop.

Observed in production: buildbanner's coder left a modified `package-lock.json`, causing `delete_task_branch` to fail silently on every 15-second dispatcher tick.

**Fix:**
1. In `delete_task_branch()`: before `git checkout "$target"`, discard uncommitted changes on the task branch. Use `git checkout --force "$target"` instead of `git checkout "$target"`. The task branch is being deleted anyway — there's no reason to preserve uncommitted changes on it.
2. Also add `git clean -fd` after the force checkout to remove untracked files that might cause issues on the fresh branch.
3. If the force checkout still fails (e.g., target branch doesn't exist), log a clear error with the reason instead of silently continuing.
4. Write tests in `tests/test_git_ops.bats` covering: delete with clean working tree, delete with modified tracked file, delete with untracked files, force checkout failure logging.

## Task 56: Auth failure detection with account fallback

**Problem:** The pipeline has no concept of "auth failure" vs "code failure." If a Claude account is logged out:
- **Dispatcher (account 1):** Coder/fixer spawns fail immediately. Pipeline burns through MAX_RETRIES in minutes, hits diagnosis (which also fails), and stops. All retries wasted.
- **Reviewer (account 2):** Reviewer launchd agent fires every 15 seconds, each attempt fails. No retry limit — spams error logs indefinitely while the pipeline stalls in `pr_open`.
- **Both accounts down:** Pipeline is completely stuck with no clear signal to the operator.

**Fix — three parts:**

**Part 1: Auth pre-check.** Add a `check_claude_auth()` function in `lib/claude.sh` that runs a lightweight Claude probe (e.g., `claude --version` or `claude -p "echo ok" --max-turns 1`) to verify the account is authenticated. Call this before every agent spawn (coder, fixer, reviewer, merger). If auth fails, skip the spawn and log a CRITICAL message: `"Claude auth failed for account N — run /login for CLAUDE_CONFIG_DIR=~/.claude-accountN"`.

**Part 2: Reviewer retry limit.** Add a reviewer-side retry counter (separate from the dispatcher retry count). After `AUTOPILOT_MAX_REVIEWER_RETRIES` (default: 5) consecutive failures, the reviewer should pause itself (create PAUSE file or set a `reviewer_paused` flag in state.json) instead of retrying indefinitely. Log a CRITICAL message. Reset the counter on any successful review.

**Part 3: Account fallback.** When the primary account for an agent type fails auth, fall back to the other account. Controlled by `AUTOPILOT_AUTH_FALLBACK` (default: `true`). When enabled:
- If account 1 (dispatcher) auth fails, try account 2's `CLAUDE_CONFIG_DIR` for coder/fixer spawns.
- If account 2 (reviewer) auth fails, try account 1's `CLAUDE_CONFIG_DIR` for reviewer/merger spawns.
- Log a WARNING when falling back: `"Account 1 auth failed — falling back to account 2 for coder spawn"`.
- If both accounts fail auth, create PAUSE file and log CRITICAL: `"All Claude accounts failed auth — pipeline paused. Re-authenticate and remove PAUSE to resume."`.
- Fallback can be disabled with `AUTOPILOT_AUTH_FALLBACK=false` (e.g., if accounts have different rate limits and you don't want cross-use).

**Implementation notes:**
- The account number → config dir mapping already exists (`CLAUDE_CONFIG_DIR=~/.claude-account{N}`). The fallback just needs to try the other number.
- Auth check should be fast (< 2 seconds). If `claude --version` doesn't require auth, use a minimal prompt instead.
- Write tests in `tests/test_claude.bats` covering: auth check passes, auth check fails, fallback to other account, both accounts fail → pause, fallback disabled via config.

## Task 57: TIMER sub-step instrumentation for pipeline phases

**Goal:** Add timing instrumentation to key pipeline sub-steps so we can see exactly where time is spent within each phase. Currently we only have phase-level timing (implementing, fixing, reviewing, merging) but no visibility into sub-steps like preflight, branch setup, coder spawn, push, PR creation, test gate, etc.

**Reference:** Devops PR #74 added this with `_timer_start`/`_timer_log` helpers.

**Implementation:**
1. Add `_timer_start()` and `_timer_log()` helper functions in `lib/state.sh` (or a new `lib/timer.sh`):
   - `_timer_start` captures current epoch seconds into a variable.
   - `_timer_log "$project_dir" "$label"` logs `"TIMER: <label> (<N>s)"` using the elapsed time since `_timer_start`.
2. Instrument key sub-steps in `lib/dispatch-handlers.sh`:
   - `_handle_pending`: preflight, branch setup, coder spawn (wall time)
   - `_handle_coder_result`: push, PR creation, test gate
   - `_handle_reviewed`/`_handle_fixer_result`: fixer spawn, post-fix tests
   - `_handle_fixed`: pre-merge conflict check, merger spawn
   - `_handle_merger_result`: merge execution, summary generation
3. Log lines should be greppable: `grep TIMER pipeline.log` gives a full sub-step breakdown.
4. Write tests verifying: timer helpers produce valid output, timer log format matches expected pattern.

## Task 58: Two-phase bats test strategy (fast rejection for fix cycles)

**Problem:** During fix cycles (fixer, test_fixing), the Stop hook runs `bats tests/` on every edit — a full suite run even when only a few tests are failing. On the LLM benchmark (1800+ tests), each full run takes ~3.7 minutes. A fixer making iterative fixes triggers 3-5 full runs, spending 10-15+ minutes on "did you fix it yet?" checks.

**Reference:** Devops PR #85 implemented this for pytest with `--lf` (last-failed) → `--ff` (failures-first) two-phase approach. Bats doesn't have `--lf` natively, so we need a custom mechanism.

**Goal:** Run only previously-failed tests first (~5s). If they still fail, block immediately. If they all pass, run the full suite to catch regressions. Cut intermediate Stop hook test time from ~3.7m to ~5s.

**Implementation:**

1. **Track failed tests.** After each bats run, parse the TAP output for failed test files and test names. Write them to `.pr-pipeline/.last-failed-tests` (one test file path per line). Clear the file on a fully passing run.

2. **Two-phase runner in Stop hook (lib/hooks.sh).** Before running the full suite:
   - **Phase 1:** Check if `.last-failed-tests` exists and is non-empty. If so, run `bats` on only those files (e.g., `bats tests/test_config.bats tests/test_state.bats`). If any fail, exit non-zero immediately — don't waste time on the full suite.
   - **Phase 2:** If Phase 1 passes (all previously-failed tests now pass), run the full suite with `bats tests/` to catch regressions. Use `--jobs` for parallel execution if available.
   - **No cache:** If `.last-failed-tests` doesn't exist or is empty (first run, or last run was clean), skip Phase 1 and go straight to full suite.

3. **TAP output parsing.** Bats outputs TAP format: `not ok N description` for failures. Parse this to extract the test file. Since bats includes the file path in `--tap` output, use that. Alternatively, run with `--formatter tap` and grep for `not ok`.

4. **Integration with test gate and postfix.** The two-phase logic should be in a shared helper (e.g., `_run_bats_two_phase()` in `lib/hooks.sh` or `lib/testgate.sh`) that both the Stop hook and `run_test_gate` can call.

5. Write tests in `tests/test_hooks.bats` covering: no cache → full suite, cache with still-failing tests → fast rejection, cache with now-passing tests → full suite, cache cleared after clean run.

## Task 59: Include file list in merger prompt to prevent false rejections on large diffs

**Problem:** When a PR's diff is large, the merger only sees a truncated portion. It can false-reject for "missing files" that are simply beyond the visible diff. Devops hit this repeatedly until PR #47 fixed it.

**Reference:** Devops PR #47.

**Fix:** Include a complete file list (with addition/deletion stats) **above** the diff in the merger prompt, so the merger always knows the full scope of the PR regardless of diff size.

**Implementation:**
1. Add a `_fetch_pr_file_list()` function in `lib/merger.sh` that runs `gh pr diff "$pr_number" --stat` (or `gh api repos/{owner}/{repo}/pulls/{pr_number}/files --jq '.[].filename'`) to get the full file list with stats.
2. In `build_merger_prompt()`, insert the file list section **before** the diff section. Format it as a simple list with `+/-` line counts so the merger can see what files changed and roughly how much.
3. Add a note in the prompt telling the merger: "The file list above is complete. The diff below may be truncated for large PRs. Do not reject for missing files if they appear in the file list."
4. Write tests in `tests/test_merger.bats` covering: file list generation, prompt includes file list before diff, handling of PRs with many files.

## Task 60: Activate virtualenv in test gate for Python projects

**Problem:** When autopilot auto-detects `pytest` as the test command, it runs it via bare `bash -c` without activating the project's virtualenv. If `pytest` is only installed inside `.venv/`, the test gate fails with "command not found." Devops fixed this in PR #35.

**Reference:** Devops PR #35.

**Fix:** Detect `.venv/bin/activate` (or `venv/bin/activate`) and source it before running the test command.

**Implementation:**
1. Add a `_build_test_shell_cmd()` helper in `lib/testgate.sh` that wraps the test command with venv activation if a virtualenv is detected:
   - Check for `.venv/bin/activate` or `venv/bin/activate` in the project dir.
   - If found, prepend `source .venv/bin/activate &&` to the test command.
   - If not found, run the command as-is.
2. Use this helper in `_run_test_cmd()` instead of bare `bash -c`.
3. Also append `--no-cov` to auto-detected `pytest` commands (when `AUTOPILOT_TEST_CMD` is not explicitly set). Coverage collection adds significant overhead for no benefit in the pipeline. Only apply this to auto-detected commands — if the user explicitly sets `AUTOPILOT_TEST_CMD=pytest`, respect their choice.
4. Write tests in `tests/test_testgate.bats` covering: venv detected and activated, no venv present, `--no-cov` appended to auto-detected pytest, `--no-cov` NOT appended to explicit `AUTOPILOT_TEST_CMD`.

## Task 61: Save coder output for fixer session resume

**Bug:** `_handle_pending()` in `dispatch-handlers.sh` runs `run_coder ... >/dev/null 2>&1`, discarding the coder's output. The fixer's `_resolve_session_id()` in `fixer.sh` looks for `logs/coder-task-N.json` to resume the coder's session, but that file is never written. Session resume always falls through to cold start, wasting ~$1.50 in context re-read per fix cycle.

**Reference:** Devops PR #51 ensures the coder output JSON is saved so the fixer can extract the session ID.

**Fix:**
1. In `_handle_pending()`: capture the coder output file path from `run_coder` (which returns it via `_run_agent_with_hooks`). The output JSON is already written to `logs/coder-task-N.json` by the agent lifecycle helper — verify this is actually happening. If it's being suppressed by the `>/dev/null 2>&1`, redirect only stderr and let stdout (the output file path) be captured.
2. Verify `_resolve_session_id()` in `fixer.sh` correctly extracts `session_id` from the coder JSON.
3. Write tests covering: coder output JSON is saved, fixer finds coder session ID, fixer falls back to cold start when no coder JSON exists.

## Task 62: Wire up token usage recording in dispatch handlers

**Bug:** `record_claude_usage()` is implemented in `lib/metrics.sh` with full tests, but it's never called from `dispatch-handlers.sh`. The `token_usage.csv` file is always empty — no cost or token data is ever recorded.

**Fix:**
1. After each Claude agent completes (coder, fixer, merger), call `record_claude_usage "$project_dir" "$task_number" "$agent_label" "$output_json"` where `$output_json` is the path to the agent's output JSON file (e.g., `logs/coder-task-N.json`).
2. The output JSON contains `usage.input_tokens`, `usage.output_tokens`, `usage.cache_read_input_tokens`, `usage.cache_creation_input_tokens`, and `total_cost_usd` — `record_claude_usage` should extract these and append to `token_usage.csv`.
3. Also call it after reviewer Claude calls (in `review-runner.sh`) and spec review calls.
4. Write tests verifying: CSV row written after coder, CSV row written after fixer, CSV accumulates across tasks.

## Task 63: Post fixer and test-gate status comments on PR

**Problem:** When the fixer completes or the test gate fails, no status is posted to the PR on GitHub. All pipeline activity is invisible to anyone watching the PR. Reviewers can't see whether tests passed, what the fixer changed, or why the pipeline is retrying.

**Fix:**
1. After test gate failure (in `_handle_coder_result` and `_handle_test_fixing`): post a comment on the PR with the test failure summary (last N lines of test output, exit code).
2. After fixer completes (in `_handle_fixer_result`): post a comment listing the fixer's commits (`git log` between pre-fix and post-fix SHAs) and whether post-fix tests passed.
3. Use `gh pr comment "$pr_number" --body "$comment"` for posting. Respect `AUTOPILOT_TIMEOUT_GH` for the API call.
4. Keep comments concise — no more than 50 lines. Truncate test output to `AUTOPILOT_TEST_OUTPUT_TAIL` lines.
5. Write tests covering: test gate failure comment posted, fixer success comment posted, comment truncation, gh API failure is non-fatal.

## Task 64: Network failure circuit breaker — don't count network errors against retry budget

**Problem:** If GitHub is down or the network is unreliable, the pipeline burns through `MAX_RETRIES` in ~75 seconds (one per 15-second tick), runs diagnosis (another paid Claude call that also fails), then advances past the task. The task's work is lost. Network failures are transient and should not count against the retry budget.

**Fix:**
1. Add a `_is_network_error()` helper that checks for common network failure patterns: `gh` exit codes indicating network issues, git push/fetch failures with "Could not resolve host" or "Connection refused", Claude CLI failures with connection errors.
2. In `_retry_or_diagnose()`: before incrementing the retry counter, check if the failure was a network error. If so, log a WARNING (`"Network error — not counting against retry budget"`) and return without incrementing. The next tick will retry naturally.
3. Add a separate `AUTOPILOT_MAX_NETWORK_RETRIES` (default: 20) counter to prevent infinite loops if the network is down for extended periods. After exhausting network retries, pause the pipeline (create PAUSE file) with a CRITICAL log.
4. Write tests covering: network error detected → retry not incremented, non-network error → retry incremented normally, network retries exhausted → pipeline paused.

## Task 65: Unpause BuildBanner pipeline and begin task processing

**Meta-task:** Once all prior autopilot tasks are complete and the pipeline is stable, unpause the BuildBanner pipeline at `/Users/alex/projects/buildbanner/buildbanner` and begin processing its task list. Verify:
1. BuildBanner's `.pr-pipeline/state.json` is in a clean state (status: pending, correct current_task).
2. BuildBanner's `tasks.md` (or implementation guide) exists and has remaining tasks.
3. Crontab/launchd entries for BuildBanner are configured and active.
4. Run a single dispatcher tick manually to verify it picks up the correct task.

## Task 66: Improve test coverage for autopilot

**Goal:** Audit the existing bats test suite and add missing coverage. Every `lib/*.sh` module should have a corresponding `tests/test_*.bats` file with meaningful tests — not just smoke tests.

**Implementation:**
1. Run `make test` and capture the current test count and any skipped tests.
2. For each `lib/*.sh` file, check whether `tests/test_*.bats` exists and how many tests it has. Identify modules with zero or thin coverage.
3. Prioritize coverage for the most critical paths: `dispatch-handlers.sh` (state machine transitions), `state.sh` (atomic writes, counter logic), `git-ops.sh` (branch creation/deletion, PR creation), `claude.sh` (command building, output parsing), `testgate.sh` (test detection, SHA verification).
4. Add edge case tests: empty inputs, missing files, concurrent access patterns, error paths (non-zero exit codes, missing dependencies).
5. Target: every public function in every `lib/*.sh` module has at least one test. Every error path that can be triggered by bad input or external failure has a test.
6. Run `make test` at the end and verify all tests pass with zero failures.

## Task 67: Profile bats test suite and optimize slow tests

**Goal:** Measure per-test execution time across the full bats suite, identify the slowest tests, and make concrete optimizations to reduce total test runtime.

**Implementation:**
1. Run the full test suite with timing: `bats --tap tests/ 2>&1 | ts -s '%.s'` (or equivalent) to get per-test timestamps. Alternatively, use `time bats tests/test_foo.bats` for each file to get per-file timing.
2. Produce a table of test files sorted by execution time (slowest first). For the top 5 slowest files, break down per-test timing.
3. Identify common causes of slowness: unnecessary subshell spawns, repeated `source` of heavy libs, real filesystem I/O that could use tmpfs, unnecessary `sleep` calls, tests that spawn actual Claude processes instead of mocking.
4. Apply optimizations: shared setup via `setup_file()` instead of per-test `setup()`, stub expensive operations, reduce redundant file I/O, parallelize independent test files.
5. Re-run the suite after optimizations and report before/after timing comparison.
6. If total suite time exceeds 60 seconds, recommend further structural changes (test splitting, lazy loading, fixture caching).

## Task 68: Log prompt size after coder and fixer complete

**Goal:** After the coder and fixer finish, log the approximate byte count of the prompt that was sent. Pure observability — no action taken, no truncation logic. This lets us spot context growth trends over time by grepping the pipeline log.

**Implementation:**
1. In `_handle_pending()` after `run_coder` returns: log `"METRICS: coder prompt size ~<N> bytes (<N/4> est. tokens)"` where `<N>` is the byte count of the prompt string that was built by `build_coder_prompt()`.
2. In `_handle_reviewed()` after `run_fixer` returns: log the same for the fixer prompt.
3. The prompt is already constructed before the Claude call — just capture its byte length with `${#prompt}` and log it alongside the existing METRICS lines.
4. Write a test verifying the log line format is greppable: `grep "METRICS: coder prompt size" pipeline.log`.

## Task 69: Post consolidated performance table on PR after merge

**Goal:** After a PR is merged, post a comment on the PR with a consolidated performance summary table. This runs asynchronously so it doesn't block the next task from starting.

**Implementation:**
1. Add a `_post_performance_summary()` function in `lib/metrics.sh` (or `lib/dispatch-helpers.sh`) that:
   - Reads the coder, fixer, and merger output JSON files from `logs/` for the current task.
   - Extracts: wall time, API time, tool time, turns, token counts (input, output, cache read, cache create), and cost from each.
   - Reads phase timing from `phase_timing.csv` for the current task.
   - Formats a markdown table like:

     ```
     | Phase | Wall | API | Turns | Cost |
     |-------|------|-----|-------|------|
     | Coder | 900s | 318s | 69 | $3.04 |
     | Fixer | 634s | 205s | 45 | $3.11 |
     | Review | 170s | — | — | $0.55 |
     | Merger | 19s | 19s | 1 | $0.11 |
     | **Total** | **54m** | — | — | **$6.81** |
     ```

   - Posts it as a comment on the PR via `gh pr comment "$pr_number" --body "$table"`.

2. In `_handle_merged()`: after the merge succeeds and before advancing to the next task, spawn `_post_performance_summary` in the background (`&`) so it doesn't block. The next task starts immediately.
3. If the gh API call fails (network, rate limit), log a WARNING and discard — this is best-effort observability, not critical path.
4. Write tests covering: table formatting with all phases present, table formatting with missing fixer (clean review), background execution doesn't block task advancement, gh failure is non-fatal.
