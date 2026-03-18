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

## Task 68: Update documentation for Tasks 42–67

**Goal:** Bring all documentation files up to date so they accurately describe the project's current behavior and capabilities. The codebase has evolved through Tasks 42–67 — read the code as it exists now, compare against the docs, and fix any gaps or inaccuracies. Write docs as a user-facing reference, not a changelog.

**Files to update:**

1. **`docs/autopilot-plan.md`** — The design document. Make targeted updates to sections that have drifted from the current code — fix inaccurate diagrams, config values, directory listings, or component descriptions. Do not rewrite from scratch; preserve the existing structure and prose. If any features described in the plan were never implemented, list them in a PR comment (not in the doc itself) so they can be tracked.
2. **`docs/getting-started.md`** — Ensure prerequisites, installation steps, troubleshooting entries, and workflow descriptions match current behavior.
3. **`docs/configuration.md`** — Audit every `AUTOPILOT_*` variable in `lib/config.sh`. Document each with its default, description, and example. Remove any documented variables that no longer exist.
4. **`docs/task-format.md`** — Document the current task file detection, heading formats, PR title extraction, and any parsing behavior.
5. **`docs/architecture.md`** — Update the state machine diagram to include all current states (e.g., `test_fixing`). Document all modules (`lib/timer.sh`, `lib/pr-comments.sh`, `lib/network-errors.sh`, `lib/twophase.sh`, etc.) with one-line descriptions.
6. **`README.md`** — Update feature list, command descriptions, and quick-start to match current capabilities.

**Process:** Read each doc file, read the corresponding source code, and update the docs to accurately describe current behavior. Do not write a changelog or enumerate past bug fixes — document the project as if writing reference material for a new user.

---

## Task 69: Log prompt size after coder and fixer complete

**Goal:** After the coder and fixer finish, log the approximate byte count of the prompt that was sent. Pure observability — no action taken, no truncation logic. This lets us spot context growth trends over time by grepping the pipeline log.

**Implementation:**
1. In `_handle_pending()` after `run_coder` returns: log `"METRICS: coder prompt size ~<N> bytes (<N/4> est. tokens)"` where `<N>` is the byte count of the prompt string that was built by `build_coder_prompt()`.
2. In `_handle_reviewed()` after `run_fixer` returns: log the same for the fixer prompt.
3. The prompt is already constructed before the Claude call — just capture its byte length with `${#prompt}` and log it alongside the existing METRICS lines.
4. Write a test verifying the log line format is greppable: `grep "METRICS: coder prompt size" pipeline.log`.

## Task 70: Post consolidated performance table on PR after merge

**Goal:** After a PR is merged, post a comment on the PR with a consolidated performance summary table. This runs asynchronously so it doesn't block the next task from starting.

**Implementation:**
1. Add a `_post_performance_summary()` function in `lib/metrics.sh` (or `lib/dispatch-helpers.sh`) that:
   - Reads the coder, fixer, and merger output JSON files from `logs/` for the current task.
   - Extracts: wall time, API time, tool time, turns, token counts (input, output, cache read, cache create), and cost from each.
   - Reads phase timing from `phase_timing.csv` for the current task.
   - Includes a header line with the task description: `**Task 47: Finalize lock to prevent double-advancing after merge**`
   - Formats a markdown table like:

     ```
     **Task 47: Finalize lock to prevent double-advancing after merge**

     | Phase | Wall | API | Turns | Tokens In | Tokens Out | Cache Read | Cache Create | Retries | Cost |
     |-------|------|-----|-------|-----------|------------|------------|--------------|---------|------|
     | Coder | 900s | 318s | 69 | 71 | 15,528 | 4,436,946 | 69,202 | 0 | $3.04 |
     | Test gate | 45s | — | — | — | — | — | — | — | — |
     | Fixer | 634s | 205s | 45 | 83 | 12,340 | 4,412,000 | 1,200 | 0 | $3.11 |
     | Review | 170s | — | 5 | 250 | 3,685 | 70,020 | 13,784 | — | $0.55 |
     | Merger | 19s | 19s | 1 | 3 | 737 | 14,004 | 0 | 0 | $0.11 |
     | **Total** | **54m** | — | **120** | **407** | **32,290** | — | — | **0** | **$6.81** |
     ```

   - Task description extracted from the `## Task N:` header in tasks.md.
   - Retries column shows how many times that phase was retried (from retry counter and test_fix_retries).
   - Test gate row shows wall time for the test run (from TIMER logs or test gate duration).

   - Posts it as a comment on the PR via `gh pr comment "$pr_number" --body "$table"`.

2. In `_handle_merged()`: after the merge succeeds and before advancing to the next task, spawn `_post_performance_summary` in the background (`&`) so it doesn't block. The next task starts immediately.
3. If the gh API call fails (network, rate limit), log a WARNING and discard — this is best-effort observability, not critical path.
4. Write tests covering: table formatting with all phases present, table formatting with missing fixer (clean review), background execution doesn't block task advancement, gh failure is non-fatal.

## Task 71: Soft pause and task content validation

**Two parts:**

**Part 1: Soft pause.** Currently `PAUSE` stops everything on the next tick — even if a coder or fixer is mid-flight, the next tick won't process the result. Change PAUSE behavior:
- `touch .pr-pipeline/PAUSE` (empty file) — **soft pause**: the current phase runs to completion (coder finishes, test gate runs, fixer finishes, etc.), but no new phase or task starts. The dispatcher processes the current agent's result, transitions state, then stops.
- `echo "NOW" > .pr-pipeline/PAUSE` (file contains "NOW") — **hard pause**: current behavior, exits immediately on next tick.
- This lets you safely edit tasks.md: soft pause, wait for the current phase to finish (watch the log), edit, then `rm PAUSE`.

**Implementation:**
1. In `entry-common.sh` (or wherever PAUSE is checked): read the PAUSE file content. If it contains "NOW", exit immediately (current behavior). If it's empty, set a flag `_AUTOPILOT_SOFT_PAUSE=1` and continue into the tick.
2. At the end of each handler (`_handle_pending`, `_handle_reviewed`, `_handle_fixed`, etc.): after the state transition, check `_AUTOPILOT_SOFT_PAUSE`. If set, log `"Soft pause — stopping after phase completion"` and exit instead of continuing to the next phase.
3. The `_handle_pr_open` and `_handle_implementing`/`_handle_fixing`/`_handle_merging` (crash recovery) handlers should still run during soft pause — they're just checking state, not starting new work.

**Part 2: Task content validation.** Detect when tasks.md changes while a task is in flight.
1. When `_handle_pending` creates the task branch, compute a hash of the task body (`extract_task | md5`) and write it to state: `write_state "$project_dir" "task_content_hash" "$hash"`.
2. On coder spawn (and fixer spawn), re-hash the task body from the current tasks.md on main and compare. If it changed, log a WARNING: `"Task content changed since branch creation — task may have been renumbered"`. Don't block, just warn — the operator can decide to pause and reset.
3. Write tests covering: soft pause lets current phase finish, hard pause exits immediately, task hash matches on unchanged tasks, task hash mismatch logs warning.

## Task 72: Coder retry preserves previous work and gets failure context

**Problem:** When the coder crashes or times out, `_handle_pending()` deletes the task branch (line 52-60) and creates a fresh one from main. All progressive commits from the previous attempt are destroyed. The retry coder starts completely blind — no knowledge of what the previous coder accomplished or why it failed. This wastes 30+ minutes of work per retry.

**Contrast with fixer:** The fixer gets diagnosis hints via `consume_diagnosis_hints()` and resumes the coder's session via `_resolve_session_id()`. The coder retry gets nothing.

**Fix — three-phase retry strategy** (default `AUTOPILOT_MAX_RETRIES=5`):

**Phase A: Preserve and continue (retries 1–2).** Keep the existing branch and feed failure context to the retry coder so it can continue from where the previous attempt left off.
1. In `_handle_pending()`: when `retry_count` is 1 or 2 and `task_branch_exists`, do NOT delete the branch. Instead, check out the existing branch and let the coder continue from the current state.
2. If the branch has unpushed commits, push them before spawning the retry coder so they're not lost.
3. In `_retry_or_diagnose()`: before setting status to pending, save failure context to a file: `logs/coder-retry-hints-task-N.md`. Include: the exit code, the last 20 lines of the coder's output (from the output JSON if available), and a git log of commits already on the branch.
4. In `build_coder_prompt()` (or `_handle_pending()`): when `retry_count` is 1 or 2, read the retry hints file and append it to the prompt: "Previous attempt context: [hints]. Continue from the existing commits on this branch."

**Phase B: Reset and start fresh (retries 3+).** The coder may have gone down the wrong path. Delete the branch and start over with a clean slate, but still include a note about why previous attempts failed.
1. In `_handle_pending()`: when `retry_count >= 3` and `task_branch_exists`, delete the branch and create a fresh one from the target branch (current behavior).
2. Append a brief note to the coder prompt: "Previous attempts (N) failed — starting fresh. Avoid the approaches that led to: [one-line summary from hints file]."
3. Clean up the hints file after a successful coder run (any retry count).

**Phase C: Diagnosis (retry count exceeds max).** Existing behavior — `_retry_or_diagnose()` runs the diagnosis agent and skips to the next task.

**Write tests covering:** retries 1–2 preserve branch commits and include hints in prompt, retries 3+ delete branch and start fresh, first attempt (retry 0) still deletes stale branches, hints file cleaned up after success, phase boundary at retry_count=3.

## Task 73: Derive stale lock threshold from coder timeout automatically

**Problem:** `AUTOPILOT_STALE_LOCK_MINUTES` and `AUTOPILOT_TIMEOUT_CODER` both default to 45 minutes. A coder finishing right at the timeout boundary races with stale lock detection — the lock cleaner can kill a lock that's still legitimately held. These are two independent configs that must stay in sync manually, which is fragile.

**Fix:**
1. Remove `AUTOPILOT_STALE_LOCK_MINUTES` as a user-facing config. Instead, compute it automatically: `stale_threshold = max(TIMEOUT_CODER, TIMEOUT_FIXER, TIMEOUT_SPEC_REVIEW) / 60 + 5` (longest agent timeout in minutes + 5 minute buffer).
2. In `is_lock_stale()` (state.sh:347): replace `local stale_minutes="${AUTOPILOT_STALE_LOCK_MINUTES:-45}"` with a call to a new helper `_compute_stale_lock_minutes()` that reads the timeout configs and adds the buffer.
3. Keep `AUTOPILOT_STALE_LOCK_MINUTES` as an optional override — if explicitly set, use it. But if unset, derive it. Log the effective value at startup in `_log_effective_config()`.
4. Update `docs/configuration.md` to document the new behavior: "Defaults to longest agent timeout + 5 minutes. Override with `AUTOPILOT_STALE_LOCK_MINUTES` if needed."
5. Write tests: default derivation produces correct value, explicit override takes precedence, changing coder timeout changes stale threshold.

## Task 74: `autopilot init` — interactive project setup command

**Problem:** Setting up a new project requires 6+ manual steps. New users have to read the full getting-started doc and manually copy example files. The goal is: `cd my-project && autopilot init && autopilot start`.

**Implement `bin/autopilot-init`** — an interactive setup command that scaffolds everything and sets up scheduling in a paused state.

**Behavior:**
1. **Verify prerequisites**: check for `claude`, `gh`, `jq`, `git`, `timeout`. For each missing tool, print install instructions. The only one most users won't have is `coreutils` (for `timeout` on macOS). Abort if any required tool is missing.
2. **Verify git repo**: confirm the current directory is a git repo with a GitHub remote. If no git repo exists, offer to run `git init`. If no GitHub remote exists, offer to create one via `gh repo create`. This way a user in an empty directory can still get started without manual setup.
3. **Verify `gh auth`**: run `gh auth status` and check it's authenticated. If not, prompt the user to run `gh auth login`.
4. **Scaffold `tasks.md`**: if no tasks file exists, generate a sample `tasks.md` with 2 simple starter tasks that work in any repo. Print: `"Generated tasks.md with sample tasks — edit with your own tasks or try it as-is."` Skip if `tasks.md` already exists. The sample tasks should be:
   - **Task 1: Add README.md** — "Create a README.md describing this project. Include: what it does, how to install, how to run, and how to test. Infer the project purpose from existing files."
   - **Task 2: Add .gitignore** — "Create a .gitignore appropriate for this project. Detect the language/framework from existing files and include the standard ignore patterns (build artifacts, dependency dirs, IDE files, OS files)."
   Also update `examples/tasks.example.md` to match — keep the existing 5-task template as-is but add a comment at the top noting that `autopilot init` generates a minimal starter version.
5. **Scaffold `autopilot.conf`**: if no config file exists, generate one with `--dangerously-skip-permissions` enabled (required for unattended mode). Ask if they have a test command (if yes, set `AUTOPILOT_TEST_CMD`). Skip if already exists.
6. **Update `.gitignore`**: append `.autopilot/` if not already present.
7. **Account detection**: check if `~/.claude-account1/` and `~/.claude-account2/` exist. If both, suggest the two-account setup. If neither, explain single-account is fine.
8. **Set up scheduling**: run `autopilot-schedule` to install launchd agents (or print cron instructions on Linux).
9. **Touch PAUSE file**: create `.autopilot/PAUSE` so the pipeline is installed but not running yet.
10. **Print summary**: show what was created/modified, and tell the user: `"Setup complete. Edit tasks.md if needed, then run: autopilot start"`.

**Idempotent**: re-running `autopilot init` skips files that already exist and only updates what's missing.

**Install**: No Makefile change needed — `make install` uses a `for f in bin/autopilot-*` wildcard that automatically picks up all new binaries.

**Write tests**: `tests/test_init.bats` — run `autopilot-init` in a temp git repo with mocked `gh`, verify all files created, `.gitignore` updated, PAUSE file exists, idempotent on re-run (no duplicate `.gitignore` entries, no overwritten tasks.md).

## Task 75: `autopilot doctor` — pre-run setup validation command

**Problem:** There's no way to validate a project setup is correct before running the pipeline. Users discover misconfigurations at runtime through cryptic errors in the pipeline log.

**Implement `bin/autopilot-doctor`** — a non-interactive validation command that checks an existing setup and reports pass/fail with actionable fix instructions.

**Checks:**
1. All prerequisites installed and on PATH (`claude`, `gh`, `jq`, `git`, `timeout`).
2. `gh auth status` passes.
3. Tasks file exists and has at least one `## Task` heading.
4. `autopilot.conf` exists and is parseable (source it and check for syntax errors).
5. `.autopilot/` is in `.gitignore`.
6. GitHub remote is reachable (`gh repo view` succeeds).
7. If `AUTOPILOT_CLAUDE_FLAGS` includes `--dangerously-skip-permissions`, verify the Claude Code settings actually allow it.
8. If two-account dirs are configured, verify both exist and are accessible.
9. **Claude smoke test**: run `claude -p "respond with OK" --max-turns 1 --output-format json` and verify it returns successfully. This validates the full stack — binary, auth, API access — not just that the binary exists. If `~/.claude-account1/` and `~/.claude-account2/` are detected, test each one with the appropriate `CLAUDE_CONFIG_DIR`. Report per-account status:
   ```
   [PASS] Claude account 1 — API responding (claude-account1)
   [PASS] Claude account 2 — API responding (claude-account2)
   ```
   or:
   ```
   [PASS] Claude — API responding (default config)
   [WARN] Only one Claude account detected — pipeline will work but coder and reviewer share rate limits
   ```

**Output format:** Print each check with a pass/fail indicator and, on failure, a one-line fix instruction. Example:
```
[PASS] claude CLI found at /Users/you/.local/bin/claude
[PASS] gh authenticated as youruser
[FAIL] No tasks file found — run: autopilot init
[PASS] autopilot.conf is valid
```

Exit 0 if all checks pass, exit 1 if any fail.

**Install**: No Makefile change needed — `make install` uses a `for f in bin/autopilot-*` wildcard that automatically picks up all new binaries.

**Write tests**: `tests/test_doctor.bats` — verify pass when everything is configured, verify each failure mode produces the correct error message and fix instruction.

## Task 76: `autopilot start` — validate and start the pipeline

**Problem:** After `autopilot init`, the pipeline is paused. The user needs a single command to validate everything and start it.

**Implement `bin/autopilot-start`:**
1. Run `autopilot-doctor`. If any check fails, print the failures and abort — do not start a broken pipeline.
2. If all checks pass, remove the `.autopilot/PAUSE` file.
3. Print: `"Pipeline started. Watch progress: tail -f .autopilot/logs/pipeline.log"`.
4. If the PAUSE file doesn't exist (pipeline already running), print: `"Pipeline is already running."` and exit 0.

**The full new-user flow becomes:**
```bash
cd my-project
autopilot init     # scaffolds files, sets up scheduling, paused
# optionally edit tasks.md
autopilot start    # validates setup, removes PAUSE, pipeline begins
```

**Install**: No Makefile change needed — `make install` uses a `for f in bin/autopilot-*` wildcard that automatically picks up all new binaries.

**Write tests**: `tests/test_start.bats` — verify start removes PAUSE after doctor passes, verify start aborts if doctor fails, verify start is idempotent when already running.

## Task 77: Postfix tests should use the two-phase parallel bats runner

`_run_postfix_tests()` in `lib/postfix.sh` runs `_run_test_cmd()` directly, which executes bats sequentially. The test gate in `lib/testgate.sh` already detects bats and routes to `_run_test_gate_bats()` which uses the two-phase parallel runner (`lib/twophase.sh` with `--jobs 10`). The postfix runner should do the same — when the test command is bats, use the two-phase parallel runner instead of sequential execution. This matters because autopilot's test suite (822+ tests) takes over 5 minutes sequentially but well under 300s in parallel, causing postfix tests to hit the timeout and trigger unnecessary fixer retries.

## Task 78: Warn on ambiguous task file detection

**Problem:** `detect_tasks_file()` uses glob fallback (`*implementation*guide*.md`) that can match multiple files. It silently picks the first match with no warning. If a user has both `tasks.md` and an implementation guide, or multiple implementation guides, they won't know which file the pipeline is using.

**Fix:**
1. In `detect_tasks_file()`: after finding a match via the glob fallback, count total matches. If more than one file matches, log a WARNING: `"Multiple task files found: [list]. Using: [chosen]. Set AUTOPILOT_TASKS_FILE to be explicit."`.
2. In `autopilot doctor` (Task 74): add a check that counts task file candidates. If ambiguous, print a `[WARN]` with the list and suggest setting `AUTOPILOT_TASKS_FILE`.
3. Write tests: single match produces no warning, multiple matches log warning with file list, explicit `AUTOPILOT_TASKS_FILE` suppresses the warning.

## Task 79: Scaffold a default CLAUDE.md for autopilot projects

**Problem:** Users who haven't used Claude Code much don't know what to put in CLAUDE.md. Without good project instructions, the coder agent makes poor decisions — over-engineers, skips tests, creates messy commits. A good default CLAUDE.md dramatically improves agent behavior for unattended runs.

**What to build:**

1. **Create `examples/CLAUDE.example.md`** — a 40-50 line template with essential engineering standards for unattended agents. Contents:
   - **Unattended mode**: "You are running as an unattended agent. Do not ask questions — make reasonable decisions and continue. Do not hang waiting for input."
   - **Commit discipline**: conventional commit prefixes (`feat:`, `fix:`, `test:`, etc.), never commit secrets/.env, small focused commits.
   - **Testing**: run tests before considering work done, fix failures don't skip them, write tests alongside implementation.
   - **Don't over-engineer**: implement only what the task asks. Don't add features, don't refactor unrelated code, don't add unnecessary abstractions.
   - **File hygiene**: keep functions under 50 lines, files under 400 lines. Prefer editing existing files over creating new ones.
   - **Project config placeholder section** (user fills in):
     ```
     # Project Details
     # Language: [e.g., Python, TypeScript, Go]
     # Framework: [e.g., Flask, Next.js, none]
     # Test command: [e.g., pytest, npm test, make test]
     # Lint command: [e.g., ruff check, eslint, none]
     ```
   - Draw from the user's global CLAUDE.md for reference but keep it concise — only the rules that matter most for unattended operation.

2. **Add to `autopilot init`** (Task 73): after scaffolding tasks.md and autopilot.conf, check for CLAUDE.md:
   - If project `CLAUDE.md` exists and has >10 lines → skip, print: `"Existing CLAUDE.md found — skipping."`
   - Else if global `~/.claude/CLAUDE.md` exists and has >10 lines → skip, print: `"Global CLAUDE.md found with engineering standards — skipping project CLAUDE.md."`
   - Else → copy `examples/CLAUDE.example.md` to project root as `CLAUDE.md`. Print: `"Generated CLAUDE.md with default agent instructions — edit the Project Details section for your stack."`

3. **Write tests**: `tests/test_init.bats` additions — verify CLAUDE.md is created when none exists, verify it's skipped when project CLAUDE.md has >10 lines, verify it's skipped when global CLAUDE.md has >10 lines, verify the template has the placeholder section.

## Task 80: Update documentation for Tasks 68–79

**Goal:** Bring all documentation files up to date so they accurately describe current behavior after Tasks 68–79. Write docs as a user-facing reference — describe how things work now, not what changed.

**Files to update:**

1. **`docs/autopilot-plan.md`** — Make targeted updates for any new capabilities, config variables, or architectural changes from Tasks 68–79. Preserve existing structure and prose; only fix sections that are inaccurate. If any planned features were never implemented, list them in a PR comment (not in the doc itself) so they can be tracked.
2. **`docs/getting-started.md`** — Document the current setup workflow including `autopilot init` / `autopilot doctor` / `autopilot start` if they exist. Ensure the "First Project Walkthrough" reflects the actual steps a new user would follow.
3. **`docs/configuration.md`** — Audit `lib/config.sh` for any new `AUTOPILOT_*` variables and document each with default, description, and example.
4. **`docs/task-format.md`** — Document current task file detection behavior, including ambiguity handling if applicable.
5. **`docs/architecture.md`** — Document the current coder retry strategy, stale lock handling, init/doctor/start commands, and CLAUDE.md scaffolding as they exist in the code.
6. **`README.md`** — Update quick-start and feature list to match current capabilities.

**Process:** Read each doc file, read the corresponding source code, and update the docs to accurately describe current behavior. Do not write a changelog — document the project as reference material for a new user.

---

## Task 81: Refactor branch operations to use worktrees

**Problem:** Currently autopilot checks out task branches directly in the project's working tree. This means: the user can't work in their repo while autopilot runs, two agents can't touch the repo simultaneously, and a coder crash can leave the working tree dirty.

**Solution:** Each task gets its own git worktree at `.autopilot/worktrees/task-N/`. The user's working tree is never touched.

**Refactor branch operations in `lib/git-ops.sh`:**
1. `create_task_branch()`: instead of `git checkout -b`, use `git worktree add .autopilot/worktrees/task-N -b pr-pipeline/task-N`. Return the worktree path.
2. `delete_task_branch()`: use `git worktree remove --force .autopilot/worktrees/task-N` then `git branch -D`. Must use `--force` because coder crashes leave dirty worktrees (uncommitted changes), and `git worktree remove` without `--force` fails on dirty worktrees.
3. `task_branch_exists()`: check both worktree list and branch existence.
4. Add `get_task_worktree_path()` helper that returns `.autopilot/worktrees/task-N`.

**Config fallback:**
1. Add `AUTOPILOT_USE_WORKTREES` config variable (default: `true`).
2. When set to `false`, use the current direct-checkout behavior. This supports projects with relative symlinks that escape the repo or other worktree-incompatible setups.
3. Document the fallback in `docs/configuration.md`.

**Write tests:** worktree is created in correct location, branch exists after creation, delete removes both worktree and branch, `get_task_worktree_path` returns correct path, fallback to direct checkout when `AUTOPILOT_USE_WORKTREES=false`.

## Task 82: Update coder/fixer to run inside worktree path

**Depends on:** Task 81.

**Problem:** After Task 81 creates worktrees, the coder and fixer still need to be told to run inside the worktree instead of the project root.

**Changes:**
1. In `_handle_pending()`: after `create_task_branch`, get the worktree path via `get_task_worktree_path()` and pass it (not `$project_dir`) to `run_coder`.
2. In `run_coder()` (`lib/coder.sh`): accept a `work_dir` parameter. `cd` into the worktree path before invoking Claude. The coder operates on the worktree's files.
3. In `run_fixer()` (`lib/fixer.sh`): same — accept `work_dir`, `cd` into the worktree. The fixer continues in the same worktree the coder used.
4. **CLAUDE.md and .claude/ handling:** Worktrees share git config and refs but NOT untracked/gitignored files. If CLAUDE.md is tracked, it will exist in the worktree checkout. But if CLAUDE.md or `.claude/` is untracked or gitignored (common), it won't exist in the worktree. After creating the worktree, symlink untracked CLAUDE.md and `.claude/` from the main working tree into the worktree if they exist and aren't already present. Also verify Claude Code resolves `.claude/settings.json` (project-level settings) correctly from the worktree path.
5. Git operations (commit, push) happen inside the worktree — git handles this correctly since the worktree is a full checkout.
6. When `AUTOPILOT_USE_WORKTREES=false`, pass `$project_dir` as `work_dir` (current behavior).

**Write tests:** coder runs inside worktree and commits there, fixer reuses the same worktree, push from worktree works, CLAUDE.md is accessible from worktree.

## Task 83: Include PR comments in merger and fixer context

**Problem:** The merger agent only receives the PR diff and its prompt. It cannot read PR comments — so when the fixer posts an explanation for why certain feedback doesn't require a code change (e.g., "the Makefile wildcard already covers this"), the merger never sees it and keeps rejecting for the same reason. Similarly, human-posted comments (like "please also fix X") don't reach the fixer. This creates infinite reject loops and makes human intervention invisible to the agents.

**Implementation:**

1. **Fetch PR comments before merger review.** In `lib/merger.sh`, before spawning the merger agent, fetch all PR comments using `gh pr view --comments` or `gh api`. Filter to only include comments posted after the last review round (use the reviewer SHA marker timestamps to avoid feeding stale context).

2. **Append comments to the merger prompt.** Add a "PR Discussion" section to the merger's context that includes the relevant comments. This lets the merger see fixer explanations, human clarifications, and any other context posted on the PR.

3. **Also include comments in the fixer prompt.** The fixer already gets review feedback, but human-posted comments (like "please also fix X") should also be included. Update `lib/fixer.sh` to fetch and append PR comments to the fixer's context.

4. **Truncate if too large.** If comments exceed 2000 lines, include only the most recent ones. Log a warning that older comments were truncated.

**Write tests:** `tests/test_merger_comments.bats` — verify that PR comments are fetched and included in the merger prompt. Verify filtering by timestamp works. Verify the fixer also receives comments.

---

## Task 84: Worktree cleanup in `_handle_merged()` and on retry/diagnosis

**Depends on:** Task 81.

**Problem:** Worktrees accumulate if not cleaned up after merge, retry skip, or crash.

**Changes:**
1. In `_handle_merged()`: ensure all data extraction from the worktree (metrics, test output, coverage reports) completes BEFORE removal. Then run `git worktree remove --force .autopilot/worktrees/task-N`. Strict ordering: record metrics → extract data → remove worktree.
2. In `_retry_or_diagnose()` when skipping a task (max retries exceeded): clean up the worktree before advancing.
3. Add `cleanup_stale_worktrees()` helper: list all worktrees under `.autopilot/worktrees/`, check both branch existence AND pipeline state. Only remove a worktree if its task number is less than the current task in state.json AND the branch has been deleted or merged. This prevents racing with concurrent operations (e.g., reviewer reading the worktree while merger deletes the branch).
4. Handle edge cases: worktree directory exists but `git worktree list` doesn't show it (manual deletion), branch exists but worktree doesn't (worktree was removed but branch wasn't).
5. When `AUTOPILOT_USE_WORKTREES=false`, skip all worktree cleanup (nothing to clean).

**Write tests:** worktree removed after merge, worktree removed on task skip, stale worktree detected and cleaned, missing worktree directory handled gracefully.

## Task 85: Worktree symlink scanner

**Known limitation:** Git worktrees break relative symlinks that point outside the repo (e.g., `data -> ../../shared-data`) because the worktree lives at `.autopilot/worktrees/task-N/` — a different depth than the project root.

1. Add `check_worktree_compatibility()` to `lib/preflight.sh`. Scan tracked files for symlinks (`git ls-files -s | grep ^120000`) and check if any resolve to paths outside the repo root. If found, log a WARNING with the list of problematic symlinks.
2. Add this check to `autopilot doctor` (Task 74): print `[WARN] Symlinks that escape repo found: [list]. Worktrees may break these. Set AUTOPILOT_USE_WORKTREES=false if needed.`
3. In `autopilot init`: if symlinks are detected, automatically set `AUTOPILOT_USE_WORKTREES=false` in the generated `autopilot.conf` and print a message explaining why.
4. **Runtime check:** Also run the symlink scan in `create_task_branch()` (Task 81) before creating the worktree. Symlinks can be added to the repo after init — a developer adds `data -> ../../shared-data` in commit 50, and task 51 would silently break without this runtime check.
5. Document this as a known limitation in `docs/configuration.md` under the worktrees section.

**Write tests:** symlink scanner detects escaping symlinks, scanner ignores internal symlinks, init auto-disables worktrees when escaping symlinks found, doctor prints warning.

## Task 86: Worktree dependency installation

**Depends on:** Task 81.

**Problem:** Worktrees don't have `node_modules/`, Python venvs, or other dependency directories. The coder's tests will fail if dependencies aren't installed.

**Changes:**
1. After creating a worktree in `create_task_branch()`, detect the project type and install dependencies:
   - If `package.json` exists → run `npm install` (or `yarn install` / `pnpm install` based on lockfile)
   - If `requirements.txt` or `pyproject.toml` exists → **create a venv first** (`python -m venv .venv`), then activate and `pip install`. Do NOT run bare `pip install` — that installs to system Python, which is wrong and potentially destructive.
   - If `Gemfile` exists → run `bundle install`
   - If `go.mod` exists → run `go mod download`
2. Add `AUTOPILOT_WORKTREE_SETUP_CMD` config for custom setup commands (runs after auto-detection).
3. **Dependency install failure is a hard error by default.** If `npm install` or `pip install` fails, the worktree has no dependencies and the coder will burn tokens on tests that immediately crash on missing imports. Log the error and abort the task (transition to retry). Add `AUTOPILOT_WORKTREE_SETUP_OPTIONAL=true` config to opt into soft-fail behavior for projects where dependency install isn't needed.
4. When `AUTOPILOT_USE_WORKTREES=false`, skip dependency installation (not needed).

**Write tests:** dependency install runs for detected project types, Python creates venv before pip install, custom setup command works, setup failure aborts task by default, `AUTOPILOT_WORKTREE_SETUP_OPTIONAL=true` allows soft-fail, no install when worktrees disabled.

## Task 87: Update tests to verify worktree isolation

**Depends on:** Tasks 81-82, 84.

**Problem:** Existing integration tests (Tasks 34-37) assume direct checkout. They need updating to verify the worktree-based flow.

**Changes:**
1. Update `tests/test_dispatcher.bats`: verify that after a dispatcher tick in `pending` state, a worktree exists at `.autopilot/worktrees/task-N/` and the mock coder ran inside it.
2. Update `tests/test_dispatcher.bats` full cycle test: verify worktree is cleaned up after merge.
3. Add worktree-specific tests:
   - User's working tree is untouched during the entire pipeline cycle (no checkout, no dirty files).
   - Worktree persists during review phase (reviewer reads the worktree while the PR is open). Verify worktree is not prematurely cleaned up.
   - Crash recovery: kill coder mid-run, verify dirty worktree is cleaned up on next tick (requires `--force`).
4. Add `AUTOPILOT_USE_WORKTREES=false` test: verify the entire pipeline still works with direct checkout (backward compatibility).

**Write tests:** all of the above. This is a test-only task — no production code changes.

## Task 88: Add OpenAI Codex as a reviewer backend

**Problem:** Currently all reviews come from Claude. A single model has blind spots — adding a second model (Codex) as a reviewer provides diversity of perspective and catches issues Claude might miss.

**Implementation:**

1. **Add `codex` reviewer type in `lib/reviewer.sh`:**
   - Detect if `codex` CLI is installed (`which codex`). If not, skip with a log message — Codex is optional, not required.
   - Use `codex exec` in headless mode with `--output-schema` to get structured JSON findings.
   - Build the prompt: include the PR diff (same as Claude reviewers get), plus instructions to review for correctness, bugs, and design issues.
   - Parse the JSON response: extract `findings[]` with `title`, `body`, `code_location.absolute_file_path`, `code_location.line_range`, and `confidence_score`.

2. **Post findings as PR comments:**
   - Map Codex findings to GitHub PR review comments using `gh api`. Post inline comments at the file/line specified by each finding.
   - Filter by confidence score — only post findings above `AUTOPILOT_CODEX_MIN_CONFIDENCE` (default: 0.7) to reduce noise.
   - Prefix comments with `🔍 Codex Review` to distinguish from Claude reviews.

3. **Configuration:**
   - `AUTOPILOT_REVIEWERS="design:general:codex"` — add `codex` to the colon-separated reviewer list. Not included by default (requires OpenAI API key).
   - `AUTOPILOT_CODEX_MODEL` — model to use (default: latest codex model — verify at implementation time, likely `gpt-5.4-codex` or newer).
   - `AUTOPILOT_CODEX_MIN_CONFIDENCE` — minimum confidence threshold for posting findings (default: `0.7`).
   - Codex uses its own API key (`OPENAI_API_KEY` env var) — separate billing from Anthropic.

4. **Create `codex-output-schema.json`** in `examples/` defining the expected output format for `codex exec --output-schema`.

5. **Update `autopilot doctor`:** if `codex` is in the reviewer list, verify the CLI is installed and `OPENAI_API_KEY` is set. Print `[FAIL]` with install instructions if missing.

6. **Update `docs/configuration.md`:** document Codex reviewer setup, API key requirement, confidence threshold tuning.

**Write tests:** mock `codex` binary (same pattern as mock `claude`), verify findings are parsed and posted as PR comments, verify confidence filtering works, verify Codex is skipped gracefully when not installed, verify `autopilot doctor` checks for Codex when configured.

---

## Task 89: Final documentation pass — complete reference for all features

**Goal:** Comprehensive final audit of all documentation against the full codebase. Every doc file must accurately describe the project as it exists — written as user-facing reference material, not a changelog.

**Files to update:**

1. **`docs/autopilot-plan.md`** — Final pass. Audit each section against the actual codebase and make targeted fixes where the doc has drifted. Preserve existing structure and prose. If any planned features remain unimplemented, list them in a PR comment (not in the doc itself) so they can be tracked.
2. **`docs/getting-started.md`** — Final pass: verify every section matches current behavior. Document worktree isolation (`.autopilot/worktrees/task-N/`, `AUTOPILOT_USE_WORKTREES`). Verify multi-account setup and all troubleshooting entries are accurate.
3. **`docs/configuration.md`** — Final pass: run `grep -r 'AUTOPILOT_' lib/config.sh` to get the full variable list. Verify every variable is documented with correct default, description, and example. Add missing variables, remove stale ones.
4. **`docs/task-format.md`** — Final pass: verify task file detection, heading formats, and parsing behavior are documented.
5. **`docs/architecture.md`** — Final pass: verify the state machine diagram includes all states. Document worktree lifecycle. Document the full agent roster (coder, fixer, test-fixer, reviewer, merger). Add module map listing every `lib/*.sh` file with a one-line description.
6. **`README.md`** — Final pass: feature list, install instructions, quick-start, and links to docs. Ensure it's accurate and complete for a new user.

**Process:** Read every `lib/*.sh` file's header comment, cross-reference with docs, and fill gaps. Write as if a new user will read these docs to learn the project — no changelogs, no bug fix history, just clear reference documentation of current behavior.

---

## Task 90: Round cost values to cents in metrics output

The metrics comment posted on PRs displays raw floating-point cost values (e.g. `$1.2961435000000001`). Round all cost values to two decimal places (cents) before display. Find where cost values are formatted for the PR comment and apply rounding there. The total row already rounds correctly — apply the same rounding to per-phase rows (Coder, Fixer, Merger, etc.). Write a test verifying that cost values in the metrics comment are formatted to exactly two decimal places.

---

## Task 91: Save reviewer agent output JSON for metrics tracking

Reviewer agents run but their output JSON files are never saved to the logs directory. The metrics summary (`_aggregate_reviewer_data()` in `lib/perf-summary.sh`) expects files matching `reviewer-*-task-N.json` in the logs directory, but none exist. This means the "Review" row is missing from every metrics table on PRs. Find where reviewer agents are spawned and ensure their output is saved as `reviewer-{persona}-task-{N}.json` in the logs directory, matching the pattern that `_aggregate_reviewer_data()` reads. Write a test verifying reviewer JSON files are created after a review run.

---

## Task 92: Fix spec review — runs but produces no output and creates no issues

The periodic spec compliance review (`lib/spec-review.sh`) triggers every 5 tasks but silently fails. Evidence: on BuildBanner, spec reviews at tasks 10, 15, 20, 25, 30, 35 all completed in ~16 seconds with `exit=0`, but no `spec-review-after-task-*.md` output files were saved and no GitHub issues were created. 16 seconds is too fast for a real Claude review — `run_claude` is likely failing and the error is being swallowed. Debug `run_spec_review()` to find where it exits early without logging. Check that `run_claude` receives valid arguments, that `extract_claude_text` parses the output correctly, and that `_save_review_output` writes to the correct path. Add error logging at every early-return path so silent failures become visible. Write a test that verifies a spec review produces a non-empty output file.

---

## Task 93: Reviewers post comment even when no issues found

Currently, reviewer personas only post a PR comment when they find issues. If a review passes clean, no comment is posted. This makes it impossible to audit whether all reviewers actually ran by looking at the PR alone — you have to check pipeline.log. Change the reviewer to always post a comment for each persona, even when clean. For example: `### 🔍 Security Review\n\nNo issues found.` This makes the PR itself a complete audit trail. Write a test verifying that a clean review still produces a comment. See GitHub issue #80.

---

## Task 94: Create sacrificial test repo scaffold for live tests

**Problem:** Autopilot has unit tests (bats with mocks) and `autopilot doctor` (dependency checks), but no way to verify the full pipeline end-to-end with real Claude invocations, real git operations, and real GitHub PRs. We need a minimal sacrificial project that autopilot can run against to validate the entire flow.

**Implementation:**

1. **Create `lib/live-test.sh`** with a `scaffold_test_repo()` function that initializes a minimal Python project:
   - `src/mathlib.py` — a small math utility module with 3-4 simple functions (e.g., `add`, `subtract` — intentionally incomplete so tasks have something to implement).
   - `tests/test_mathlib.py` — pytest test file with tests for existing functions.
   - `requirements.txt` — just `pytest`.
   - `.gitignore` — standard Python ignores.
   - `CLAUDE.md` — minimal project instructions (pure Python, pytest, keep it simple).
   - `README.md` — one-paragraph description.

2. **Create `examples/live-test-tasks.md`** with 6 tasks designed to exercise the full pipeline:
   - **Task 1:** Add a `multiply(a, b)` function with tests. (Simple happy path — exercises coder + test gate + reviewers + merger.)
   - **Task 2:** Add a `divide(a, b)` function that raises `ValueError` on division by zero, with tests. (Exercises input validation review feedback.)
   - **Task 3:** Add a `factorial(n)` function with tests including edge cases (`factorial(0) == 1`, negative input raises `ValueError`). (Slightly more complex logic.)
   - **Task 4:** Write tests for the untested `subtract(a, b)` function. The scaffold includes `subtract` in `mathlib.py` but has no tests for it. Add comprehensive tests including edge cases (negative numbers, zero, floats). (Exercises test-only task — different shape from the others.)
   - **Task 5:** Refactor — extract input validation into a `validate_number()` helper used by `divide` and `factorial`. Add tests for the helper. (Exercises refactoring review.)
   - **Task 6:** Add a `power(base, exp)` function supporting negative exponents (returns float), with comprehensive tests. (Final task — exercises the full cycle one more time.)

   Tasks must be simple enough for Haiku to implement correctly in one pass. Each task body should be 3-5 sentences max.

3. **Create `examples/live-test-autopilot.conf`** with live-test-specific defaults:
   - `AUTOPILOT_CLAUDE_MODEL=claude-haiku-4-5-20251001`
   - `AUTOPILOT_TIMEOUT_CODER=300` (5 min — these are trivial tasks)
   - `AUTOPILOT_TIMEOUT_FIXER=180` (3 min)
   - `AUTOPILOT_TIMEOUT_REVIEWER=180` (3 min)
   - `AUTOPILOT_TIMEOUT_MERGER=180` (3 min)
   - `AUTOPILOT_REVIEWERS=general,dry,performance,security,design` (all 5 — keep full coverage)
   - `AUTOPILOT_TEST_CMD=pytest` (explicit, no auto-detection needed)
   - `AUTOPILOT_BRANCH_PREFIX=autopilot` (overridden at runtime to `live-YYYYMMDD-HHMMSS` in `--github` mode)
   - `AUTOPILOT_TARGET_BRANCH=main`
   GitHub org for `--github` mode is hardcoded to `diziet` in `lib/live-test.sh` (not a config var — the config parser only accepts `AUTOPILOT_*` known vars).

**Write tests:** `tests/test_live_test_scaffold.bats` — verify `scaffold_test_repo()` creates all expected files, the Python project is valid (pytest passes on the scaffold), and the tasks.md has the expected number of tasks.

---

## Task 95: Create `bin/autopilot-live-test` entry point and orchestration

**Depends on:** Task 94.

**Problem:** Need a command that orchestrates a full live test run: scaffold the repo, configure autopilot, run the dispatcher loop, and collect results.

**Implementation:**

1. **Create `bin/autopilot-live-test`** entry point with these subcommands:
   - `autopilot-live-test run [--github] [--keep]` — run a full live test.
   - `autopilot-live-test status` — check status of a running or completed live test.
   - `autopilot-live-test clean` — remove live test artifacts.

2. **`run` subcommand logic** (in `lib/live-test.sh`):
   - Create test directory at `.autopilot/live-test/run-YYYYMMDD-HHMMSS/`.
   - Call `scaffold_test_repo()` to initialize the project inside it.
   - `git init` the test repo, make initial commit.
   - If `--github` flag: create a GitHub repo `diziet/autopilot-live-test` if it doesn't exist, push the scaffold. If the repo already exists, use a unique branch prefix (`live-YYYYMMDD-HHMMSS`) to avoid collisions with previous runs. Set `AUTOPILOT_BRANCH_PREFIX=live-YYYYMMDD-HHMMSS` and `AUTOPILOT_TARGET_BRANCH=main` in the test config to isolate from any real pipeline.
   - Copy `examples/live-test-autopilot.conf` as the project's `autopilot.conf`.
   - Override `AUTOPILOT_TASKS_FILE` to point to the embedded tasks.
   - **Run in background:** Fork the live test loop into the background, save PID to `.autopilot/live-test/current/pid`. Redirect stdout/stderr to `.autopilot/live-test/current/output.log`. On exit (success, failure, or timeout), write the exit code to `.autopilot/live-test/current/exit_code`.
   - **The loop runs the real autopilot entry points** — not internal functions. It invokes `bin/autopilot-dispatch` and `bin/autopilot-review` against the scaffolded test repo directory on the same 15-second cadence as production. This exercises the full bootstrap, locking, quick guards, config loading, and state machine — exactly as a real project would. The only differences are the Haiku model override and shorter timeouts in `autopilot.conf`.
   - The loop monitors `metrics.csv` to detect when all tasks have reached `merged` status, or exits on the global timeout.
   - Print: "Live test started (PID XXXX). Run `autopilot live-test status` to check progress."

3. **`status` subcommand:** Read `.autopilot/live-test/current/` — show current task number, state, elapsed time, tasks completed/failed, estimated cost so far (from token_usage.csv if available). If the background process has exited, read `.autopilot/live-test/current/exit_code` and display the final result.

4. **`clean` subcommand:** Remove `.autopilot/live-test/` directory. If `--github` was used, do NOT delete the remote repo (leave it for inspection).

5. **`--keep` flag:** By default, clean up the local test directory (scaffolded repo, worktrees, locks) on completion — both success and failure. Before cleanup, always copy the report (`report.md`), summary (`summary.txt`), exit code, and `output.log` to `.autopilot/live-test/latest/` so `autopilot live-test status` works after cleanup. `--keep` preserves the entire test directory for debugging.

6. **Global timeout:** 60 minutes max for the entire run (aim to complete in 30). If exceeded, log the failure and exit. This prevents runaway costs.

7. **Config isolation:** The live test runs autopilot against a completely separate project directory (the scaffolded test repo). All `.autopilot/` state, locks, and logs are inside that directory — fully isolated from any real pipeline. No special state isolation code is needed; this is how autopilot already works with different projects.

**Write tests:** `tests/test_live_test_run.bats` — verify the entry point parses arguments correctly, `run` creates the expected directory structure, `status` reads state correctly, `clean` removes artifacts, global timeout is enforced, background PID is saved.

---

## Task 96: Live test result validation and reporting

**Depends on:** Task 95.

**Problem:** After the live test loop completes, we need to validate that the pipeline actually worked and produce a clear pass/fail report.

**Implementation:**

1. **Add `validate_live_test()` to `lib/live-test.sh`:**
   - Check `metrics.csv`: should have rows for every task (derive expected count from the tasks file, don't hardcode 6), all with `status=merged`. This is the source of truth — `state.json` only tracks the current task, not historical ones.
   - Check `phase_timing.csv`: all tasks should have timing data.
   - Check `token_usage.csv`: should have entries for coder, reviewer, fixer, and merger agents.
   - If `--github` was used: verify PRs were created and merged (check via `gh pr list --state merged`).
   - Calculate total cost from `token_usage.csv` (sum the `cost_usd` column).
   - Calculate total wall time.

2. **Generate report** at `.autopilot/live-test/current/report.md`:
   ```
   # Autopilot Live Test Report

   **Date:** 2026-03-07T14:30:00Z
   **Duration:** 23m 45s
   **Total cost:** $0.08
   **Result:** PASS (6/6 tasks completed)

   | Task | State | Duration | Cost | PR |
   |------|-------|----------|------|----|
   | 1 | completed | 3m 12s | $0.01 | #1 |
   | 2 | completed | 4m 05s | $0.02 | #2 |
   | ... | | | | |

   ## Failures
   None.
   ```

3. **Exit codes:**
   - `0` — all tasks completed successfully.
   - `1` — one or more tasks failed (report shows which).
   - `2` — live test timed out.
   - `3` — live test setup failed (scaffold, git init, GitHub push).

4. **Write summary to `.autopilot/live-test/current/summary.txt`** when the background process completes. The `status` subcommand detects this file and prints the summary.

5. **Track last result:** Save the latest report path to `.autopilot/live-test/latest` symlink so `autopilot live-test status` can always find it.

**Write tests:** `tests/test_live_test_report.bats` — verify `validate_live_test()` correctly identifies pass/fail scenarios (all complete, partial failure, timeout), report is generated with correct format, cost calculation is accurate, exit codes match expectations.

---

## Task 97: Live test integration with `autopilot doctor` and documentation

**Depends on:** Task 96.

**Problem:** The live test feature needs to be discoverable and documented. `autopilot doctor` should show the last live test result. Docs need to explain when and how to use it.

**Implementation:**

1. **Update `bin/autopilot-doctor`:** Add a "Live Test" section at the end of the doctor output. Show:
   - Last run date, result (PASS/FAIL), duration, cost.
   - "Never run" if no live test has been executed.
   - This is informational only — not a pass/fail check (live tests are optional).

2. **Update `docs/getting-started.md`:** Add a "Verifying Your Setup" section that mentions `autopilot live-test run` as the ultimate validation after `autopilot doctor` passes. Explain it runs 6 trivial tasks with Haiku (~$0.05 cost, ~30 min target runtime, 60 min max).

3. **Update `docs/configuration.md`:** Document the live-test-specific config overrides and the `examples/live-test-autopilot.conf` file.

4. **Add `live-test` target to Makefile:** `make live-test` as a convenience alias for `bin/autopilot-live-test run` (local-only by default; use `make live-test-github` for the `--github` variant).

5. **Update `README.md`:** Add `autopilot live-test` to the command reference table.

6. **Update `autopilot-status`:** Show "Live test: PASS (2026-03-07, $0.08)" or "Live test: never run" in the status output.

**Write tests:** `tests/test_live_test_doctor.bats` — verify doctor output includes live test section, shows correct status for never-run and completed scenarios.

## Task 98: Include all failing test output in fixer prompt

**Problem:** When the test gate fails, the fixer only receives review feedback — it is not told which tests are failing or why. If the coder or fixer inadvertently breaks tests in unrelated modules (e.g., a change to `lib/state.sh` breaks `test_fixer.bats`), the fixer ignores those failures because they're "not my problem." The pipeline then stalls, exhausts retries, and the PR gets closed — even though the fixer could have fixed the issue if it knew about it.

This also applies to pre-existing test failures on main. If tests are already broken before the task starts, the test gate still fails, and the fixer has no idea why.

**Implementation:**

1. **Capture full test output in the test gate.** When `run_test_gate()` in `lib/testgate.sh` runs the test suite, save the full output (stdout + stderr) to `.autopilot/logs/test-output-task-N.txt` in addition to the pass/fail result.

2. **Include failing test output in the fixer prompt.** When the fixer is spawned (in `lib/fixer.sh`), if the test gate failed, append the failing test output to the fixer's prompt. Include all failing tests — not just ones related to the PR diff. Frame it as: "The following tests are failing. Some may be caused by your changes, others may be pre-existing. Fix all of them."

3. **Include failing test output in the test-fixer prompt.** Same change for `lib/dispatch-handlers.sh` when spawning the test fixer in `test_fixing` state — include the test output so the test fixer knows exactly what failed and can fix it.

4. **Tail the output if too large.** If the test output exceeds `AUTOPILOT_MAX_TEST_OUTPUT` (default: 500 lines), include only the last N lines (the failures are typically at the end). Log a warning that the output was truncated.

**Write tests:** `tests/test_fixer_test_output.bats` — verify that when the test gate fails, the fixer prompt includes the test output. Verify truncation works when output exceeds the limit. Verify the test-fixer also receives the output.

---

## Task 99: Log test suite results (count, duration, pass/fail) in PR comments

When postfix or test gate tests run, the pipeline only logs pass/fail to `pipeline.log`. There is no visibility on the PR itself into how many tests ran, how long they took, or whether a failure was a timeout vs actual test failure. After any test run (test gate, postfix, or fixer), add a summary to the relevant PR comment that includes: total test count, number passed, number failed, wall-clock duration, and whether the run was killed by timeout (exit code 124/137 from `timeout` command). Parse the test output generically — detect bats TAP output (`ok`/`not ok` lines), pytest output, or other common frameworks. Example format: `Tests: 1851 total, 1851 passed, 0 failed (312s)` or `Tests: 822/1851 ran, killed by timeout after 300s`. This makes test issues diagnosable from the PR without checking pipeline.log. Write a test verifying the summary is included in the PR comment for both pass and timeout scenarios.

---

## Task 100: Optimize test suite performance

**Problem:** The test suite (2000 tests) takes ~4 minutes with `bats --jobs 10`. Around 50 tests take 4-10 seconds each due to redundant per-test setup — primarily `git init`, creating commits, and building branch structures. The coder agent runs the full suite multiple times per task, so 4 minutes × 2-3 runs = 8-12 minutes burned on tests alone per task.

**Implementation:**

1. **Profile the test suite.** Run `bats --jobs 10 --timing tests/` and identify all tests taking >3 seconds. Group them by test file and root cause (git repo setup, subprocess spawning, file I/O).

2. **Share git repo setup across tests.** The slowest tests (dispatcher cycle, merger, metrics, PR comments) each create a fresh git repo in `setup()`. Use `setup_file()` / `teardown_file()` (bats file-level fixtures) to create the git repo once per file and reset it between tests with `git checkout -- .` or `git clean -fd` instead of full re-init.

3. **Use lightweight git stubs where possible.** Tests that only need `git log` or `git rev-parse` output don't need a real repo — mock the git commands with shell functions returning canned output. Audit which tests actually need real git operations vs. just checking command construction.

4. **Reduce subprocess spawning.** Tests that spawn `timeout`, `gh`, or other external commands where a mock would suffice should use shell function mocks instead.

5. **Target: full suite under 90 seconds** with `--jobs 20` (configurable via `AUTOPILOT_TEST_JOBS`). Current: ~230 seconds. Each test file's slowest test should be under 2 seconds.

**Write tests:** No new tests — this is a refactoring task. Verify all existing tests still pass after optimization. Run `bats --timing` before and after to confirm improvement.

---

## Task 101: Auto-resume pipeline when new tasks are added after completion

**Problem:** When the pipeline reaches `completed` state (all tasks done), it stays there permanently. If new tasks are added to the tasks file, the pipeline ignores them — `_handle_completed()` just logs "Pipeline completed — all tasks done" without re-checking. The only way to resume is to manually edit `state.json`, which defeats the purpose of automation.

**Implementation:**

In `lib/dispatch-helpers.sh`, update `_handle_completed()` to re-scan the tasks file on each tick:

1. Read `current_task` from state.
2. Detect the tasks file and count total tasks.
3. If `current_task <= total_tasks`, new tasks exist — log "New tasks detected" and transition back to `pending`.
4. Otherwise, log "Pipeline completed" as before.

This makes the pipeline self-healing: add tasks to the file and the pipeline picks them up automatically on the next 15-second tick.

**Write tests:** Add tests in `tests/test_dispatcher.bats` — verify that `_handle_completed` transitions to `pending` when `current_task` is within task range, and stays `completed` when `current_task` exceeds total tasks.

---

## Task 102: Documentation update — cover features added in tasks 90–101

**Goal:** Update all documentation to reflect features and changes introduced in tasks 90–101. Same approach as Task 89 — write as user-facing reference material, not a changelog.

**Files to update:**

1. **`docs/architecture.md`** — Add any new lib modules or scripts introduced since task 89. Update the module map. Document any new state transitions or pipeline behaviors (e.g., auto-resume from completed state, fixer prompt improvements).
2. **`docs/configuration.md`** — Run `grep -r 'AUTOPILOT_' lib/config.sh` and verify every variable is documented. Add any new config variables introduced in tasks 90–101.
3. **`docs/getting-started.md`** — Update troubleshooting entries and setup instructions if any changed. Document live testing (`autopilot-live-test`) if it was added.
4. **`docs/autopilot-plan.md`** — Update directory layout, file counts, and any sections that drifted. Preserve existing structure.
5. **`README.md`** — Update feature list, file/test counts, and any new entry points or commands.

**Process:** Read the merged PRs for tasks 90–101 (`gh pr list --state merged --limit 20`) to understand what changed. Cross-reference with the actual codebase. Fill documentation gaps without duplicating what task 89 already covered.

**Write tests:** No new tests — documentation only. Existing tests must still pass.

---

## Task 103: Split the 3 largest test files for better parallelism

**Goal:** Optimize test suite wall-clock time by breaking the parallelism ceiling. The full suite must be faster after this change than before. This is the single biggest lever for wall clock time.

**Benchmarking:** Run `time bats --jobs 20 tests/` once at the start to record the baseline time. Do NOT re-run the baseline — one measurement is enough. After all changes are complete and tests pass, run it once more to confirm improvement.

**Problem:** `test_dispatcher.bats` (77s sequential, 77 tests), `test_review_entry.bats` (66s, 77 tests), and `test_fixer.bats` (63s, 47 tests) are the critical path. With `--jobs 20`, these files each run on one core while other cores sit idle waiting. No amount of per-test optimization can make a 77s file finish faster than 77s — splitting is required.

**Implementation:**

1. **Split `test_dispatcher.bats` into 2-3 files.** Group by functional area (e.g., pending/implementing handlers vs review/fix/merge handlers, or by the function under test). Each resulting file should have roughly equal test counts so parallel execution distributes evenly.

2. **Split `test_review_entry.bats` into 2-3 files.** Group by review mode (e.g., cron mode vs standalone mode, or by reviewer lifecycle stage).

3. **Split `test_fixer.bats` into 2 files.** Group by fixer behavior (e.g., fixer spawning/config vs fixer output/retry logic).

4. **Preserve shared setup.** Each new file loads the same helpers and uses the same `setup_file()`/`setup()` pattern. Extract shared setup into a helper file (e.g., `tests/helpers/dispatcher_setup.bash`) if not already done.

5. **Verify parallel distribution.** In the final benchmark run, confirm no single file dominates wall clock time.

**Write tests:** No new tests — reorganization only. All existing tests must still pass. Test count must remain the same.

---

## Task 104: Move source chains into setup_file() to eliminate per-test re-sourcing

**Goal:** Optimize test suite performance by eliminating redundant `source` overhead. The full suite must be faster after this change than before.

**Benchmarking:** Run `time bats --jobs 20 tests/` once at the start to record the baseline time. Do NOT re-run the baseline — one measurement is enough. After all changes are complete and tests pass, run it once more to confirm improvement.

**Problem:** Heavy test files like `test_dispatcher.bats`, `test_review_entry.bats`, and `test_fixer.bats` call `source lib/dispatcher.sh` (which cascades into 5+ modules) in every test's `setup()`. With 77+ tests per file, that's 77 redundant source chains. Bats forks each test from the `setup_file()` process — if libs are sourced there, every test inherits the sourced state via fork with zero re-sourcing cost.

**Implementation:**

1. **Move `source` calls from `setup()` to `setup_file()`.** For the heaviest test files (dispatcher, review_entry, fixer, spec_review, context), move the `source lib/*.sh` calls into `setup_file()`. Each test inherits the sourced functions via bats' fork semantics.

2. **Keep per-test setup in `setup()`.** Things that must be fresh per test — temp dirs, variable cleanup, mock setup — stay in `setup()`. Only the static `source` calls move up.

3. **Verify function availability.** After moving sources to `setup_file()`, confirm that functions are still accessible in tests. Bats forks from the `setup_file()` process, so sourced functions should be inherited.

4. **Apply to all test files that source multiple libs.** Start with the top 5 by sequential time, then apply to any other file that sources 2+ lib modules in `setup()`.

**Write tests:** No new tests — optimization only. All existing tests must still pass. Use the Benchmarking instructions above.

---

## Task 105: Replace mktemp -d with BATS_TEST_TMPDIR across test suite

**Goal:** Optimize test suite performance by eliminating subprocess overhead from temp directory management. The full suite must be faster after this change than before.

**Benchmarking:** Run `time bats --jobs 20 tests/` once at the start to record the baseline time. Do NOT re-run the baseline — one measurement is enough. After all changes are complete and tests pass, run it once more to confirm improvement.

**Problem:** The test suite has ~185 `mktemp -d` calls and ~55 `rm -rf` teardowns. Each `mktemp -d` forks a subprocess. `BATS_TEST_TMPDIR` is a bats built-in that auto-creates a unique directory per test and auto-cleans it — zero forks, zero teardown code. Across ~2000 tests, this eliminates 2000-4000 fork+exec calls.

**Implementation:**

1. **Replace `mktemp -d` with `BATS_TEST_TMPDIR` subdirs.** In `tests/helpers/test_template.bash`, change `_init_test_from_template` to use `BATS_TEST_TMPDIR/project` and `BATS_TEST_TMPDIR/mocks` instead of `$(mktemp -d)`. Remove the `mkdir -p` that `mktemp -d` implicitly provided — `BATS_TEST_TMPDIR` already exists.

2. **Update all test files that use `mktemp -d` directly.** Some test files bypass the template helper and call `mktemp -d` in their own `setup()`. Replace those with `BATS_TEST_TMPDIR/subdir` and `mkdir -p` as needed.

3. **Remove `rm -rf` teardown calls.** Since `BATS_TEST_TMPDIR` is auto-cleaned by bats, remove `rm -rf "$TEST_PROJECT_DIR"` and `rm -rf "$TEST_MOCK_BIN"` from `teardown()` functions. If `teardown()` becomes empty, remove it entirely.

4. **Verify no tests depend on temp dir persistence.** `BATS_TEST_TMPDIR` is cleaned between tests. Ensure no test reads state from a previous test's temp dir (they shouldn't — but verify).

**Write tests:** No new tests — optimization only. All existing tests must still pass.

---

## Task 106: Include failing test names in test gate failure logs

**Problem:** When the test gate fails, `_handle_test_gate_result()` in `lib/testgate.sh` logs the last 80 lines of test output (`tail -n 80`). With 2000+ tests, the `not ok` lines for early failures are scrolled past — the log shows only the final passing tests, making it impossible to tell which test actually failed without re-running manually.

**Implementation:**

1. **Extract and log failing test lines separately.** Before logging the tail, grep the full output for `not ok` lines (bats TAP format) and log them explicitly:
   ```bash
   local failures
   failures="$(echo "$output" | grep '^not ok' || true)"
   if [[ -n "$failures" ]]; then
     log_msg "$project_dir" "ERROR" "Failing tests:"
     log_msg "$project_dir" "ERROR" "$failures"
   fi
   ```

2. **Also capture the line after each `not ok`** — bats prints the assertion detail (e.g., `#   '[ "$status" = "pr_open" ]' failed`) on the next line with a `#` prefix. Include these for context.

3. **Keep the existing tail output** as-is for additional context. The failing test lines are logged first, then the tail follows.

4. **Apply the same pattern to fixer test output.** Wherever the fixer or test-fixer logs test results, ensure failing tests are extracted and shown prominently.

**Write tests:** In `tests/test_testgate.bats` — verify that when tests fail, the log includes the `not ok` lines explicitly, not just the tail of output.

---

## Task 107: Replace cp -r with git clone --local --shared in test template

**Goal:** Optimize test suite performance by making `_init_test_from_template` cheaper. The full suite must be faster after this change than before. Only keep this change if it measurably improves performance.

**Benchmarking:** Run `time bats --jobs 20 tests/` once at the start to record the baseline time. Do NOT re-run the baseline — one measurement is enough. After all changes are complete and tests pass, run it once more to confirm improvement. If not faster, revert and close the task.

**Problem:** `_init_test_from_template()` copies the entire template git repo per test using `cp -r`, which duplicates the `.git/` directory (objects, refs, etc.). `git clone --local --shared` uses hardlinks to object files instead of copying them — near-instant regardless of repo size. With ~2000 tests each doing a `cp -r`, even a few milliseconds saved per copy adds up.

**Implementation:**

1. **Replace `cp -r` with `git clone --local --shared`.** In `tests/helpers/test_template.bash`, change `_init_test_from_template` from:
   ```bash
   cp -r "$_TEMPLATE_GIT_DIR" "$TEST_PROJECT_DIR"
   ```
   to:
   ```bash
   git clone --local --shared -q "$_TEMPLATE_GIT_DIR" "$TEST_PROJECT_DIR"
   ```

2. **Verify tests still pass and suite is faster** than the baseline recorded at the start. If `git clone --local --shared` is not faster (or is slower due to git startup overhead), revert and close the task as "no improvement."

3. The cloned repo should behave identically to the copied one. Tests that modify the repo (add files, commit, etc.) should still work since `--shared` only shares the object store, not the working tree.

**Write tests:** No new tests — optimization only. All existing tests must still pass.

---

## Task 108: Replace subprocess-heavy _unset_autopilot_vars with pure bash

**Goal:** Optimize test suite performance by eliminating subprocess overhead from variable cleanup. The full suite must be faster after this change than before.

**Benchmarking:** Run `time bats --jobs 20 tests/` once at the start to record the baseline time. Do NOT re-run the baseline — one measurement is enough. After all changes are complete and tests pass, run it once more to confirm improvement.

**Problem:** `_unset_autopilot_vars()` in `tests/helpers/test_template.bash` spawns 3 subprocesses per call (`env | grep | cut`). It runs in every test's `setup()` — ~2000 calls × 3 forks = ~6000 unnecessary subprocess spawns. Bash has a built-in glob `${!PREFIX*}` that lists all variables matching a prefix with zero forks.

**Implementation:**

1. **Replace the subprocess chain with `${!AUTOPILOT_*}`.** In `tests/helpers/test_template.bash`, change `_unset_autopilot_vars` from:
   ```bash
   while IFS= read -r var; do
     unset "$var"
   done < <(env | grep '^AUTOPILOT_' | cut -d= -f1)
   ```
   to:
   ```bash
   local var
   for var in ${!AUTOPILOT_*}; do
     unset "$var"
   done
   ```

2. **Also clean up leaked `_AUTOPILOT_*` internal vars.** The config system creates internal tracking variables (`_AUTOPILOT_CONFIG_SOURCES`, `_AUTOPILOT_ENV_SNAPSHOT`, etc.) that leak between tests. Add cleanup:
   ```bash
   for var in ${!_AUTOPILOT_*}; do
     unset "$var"
   done
   ```

3. **Unset `CLAUDECODE` and `CLAUDE_CONFIG_DIR`** as before — keep that part unchanged.

**Write tests:** No new tests — optimization only. All existing tests must still pass.

---

## Task 109: Optimize log_msg — cache timestamp and throttle log rotation

**Goal:** Optimize both production performance and test suite performance by reducing subprocess overhead in `log_msg`. This is a production code improvement — `lib/state.sh` is used by the pipeline, not just tests. The full suite must be faster after this change than before.

**Benchmarking:** Run `time bats --jobs 20 tests/` once at the start to record the baseline time. Do NOT re-run the baseline — one measurement is enough. After all changes are complete and tests pass, run it once more to confirm improvement.

**Problem:** `log_msg()` in `lib/state.sh` forks `date` on every call and runs `wc -l` for log rotation on every call. In production, the pipeline logs hundreds of messages per task cycle. Each fork is ~2ms — adds up to measurable overhead, especially during test runs where `log_msg` is called thousands of times via mocked pipeline operations.

**Implementation:**

1. **Cache the timestamp.** Use the bash `SECONDS` builtin to detect when a new second has elapsed. Only fork `date` when the second changes — reuse the cached timestamp otherwise:
   ```bash
   if [[ "${_LOG_LAST_SEC:-}" != "$SECONDS" ]]; then
     _LOG_CACHED_TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
     _LOG_LAST_SEC="$SECONDS"
   fi
   timestamp="$_LOG_CACHED_TS"
   ```

2. **Throttle log rotation.** Only check rotation every 1000 messages instead of every call. Use a simple counter:
   ```bash
   _LOG_MSG_COUNT=$(( ${_LOG_MSG_COUNT:-0} + 1 ))
   if (( _LOG_MSG_COUNT >= 1000 )); then
     _LOG_MSG_COUNT=0
     _rotate_log "$log_file"
   fi
   ```

3. **Cache the `mkdir -p` check.** Skip `mkdir -p "$log_dir"` if the directory already exists: `[[ -d "$log_dir" ]] || mkdir -p "$log_dir"`.

**Write tests:** Update `tests/test_state.bats` — verify that `log_msg` still produces correctly formatted output. Verify rotation still triggers (may need to adjust test expectations if they check rotation on every call). All existing tests must still pass.

---

## Task 110: Fix PR comment failing tests to grep full output, not just tail

**Problem:** `_read_test_failure_tail()` in `lib/pr-comments.sh` does `tail -n 30` of the test output log, then greps those 30 lines for `^(not ok|FAIL|error)`. With 2187 tests, the `not ok` lines are hundreds of lines before the end — the grep finds nothing in the tail, falls through to the else branch, and dumps the last 30 lines of raw output (all passing tests). The "Failing tests" section on PR comments shows only passing tests.

Task 106 fixed this in `lib/testgate.sh` (pipeline logs), but the PR comment code path in `lib/pr-comments.sh` was not updated.

**Implementation:**

1. **Grep the full output file for failing tests.** In `_read_test_failure_tail()`, replace the tail-then-grep pattern with a direct grep of the full output file:
   ```bash
   failures="$(grep -A1 '^not ok' "$output_log" | grep -v '^--$' | head -30)" || true
   ```

2. **Keep the tail fallback.** If no TAP `not ok` lines are found (non-bats test frameworks), fall back to showing the raw tail as before.

3. **Apply the same fix to any other PR comment code** that reads test output (e.g., test gate result comments, if separate from fixer result comments).

**Write tests:** In `tests/test_pr_comments.bats` — verify that when test output contains `not ok` lines early in a large output, the PR comment includes those failing test lines, not just the tail.

---

## Task 111: Optimize test suite to under 60 seconds

**Goal:** Get the full test suite under 60 seconds wall-clock time with `--jobs 20`.

**Benchmarking:** Run `time bats --jobs 20 tests/` once at the start to record the baseline time. Do NOT re-run the baseline — one measurement is enough. After all changes are complete and tests pass, run it once more to confirm the suite is under 60 seconds.

**Problem:** The remaining bottleneck after earlier tasks is tests that still create real git repos, spawn real subprocesses, or do redundant file I/O when a mock would suffice. Every second saved compounds across 3–4 test runs per task. The remaining bottleneck after task 100 is tests that still create real git repos, spawn real subprocesses, or do redundant file I/O when a mock would suffice. Every second saved compounds across 3–4 test runs per task.

**Implementation:**

1. **Fix `test_testgate.bats` first — biggest win.** This file has ~40 inline `git init` + `git commit` calls across ~80 tests, taking 27s sequential. Only ~20 tests actually need a real git repo (SHA verification, worktree creation, run_test_gate pass/fail). The other ~50 are pure logic: exit code constants, detect_test_cmd framework detection, allowlist validation, _run_test_cmd, file I/O for read_test_gate_result, venv detection, etc. Suggested approach: create one template repo in `setup_file()` via `git init -q && git commit --allow-empty -m init -q`, then `cp -r` the template in `setup()` instead of 40 inline inits. The non-git tests get a repo copy too (harmless but fast) — except any test explicitly checking non-git-dir behavior, which needs its own temp dir. Use your own best judgment on the exact approach — this is a suggested direction, not a requirement. Target: this file under 3 seconds.

2. **Fix other high-cost test files.** Apply the same template pattern to these files (use your judgment on the best approach for each):
   - `test_git_ops.bats` — 6 inline inits, 53 tests, 32s sequential (~10s savings)
   - `test_dispatcher_cycle.bats` — 3 inits + bare repo, 11 tests, 20s sequential (~8s savings)
   - `test_rebase_cycle.bats` — 3 inits + bare repo, 10 tests, 12s sequential (~5s savings)
   - `test_testgate_edge.bats` — 2 inits, 37 tests, 13s sequential (~3s savings)

3. **Reduce template `cp -r` overhead.** ~1800 tests copy a template repo in `setup()`. Consider making the template as small as possible (single empty commit, no extra files), or using `--reference` / hardlinks where supported. Estimated ~10-15s total overhead across the suite.

4. **Audit remaining slow tests.** Run `bats --jobs 20 --timing tests/` and identify all tests still taking >1 second. Target: zero tests over 1 second.

5. **Eliminate redundant setup.** Tests that re-source all of `lib/*.sh` in `setup()` when they only need one module should source only what they need. Profile `source` time — it may be significant at 2000 tests.

6. **Target: full suite under 60 seconds** with `--jobs 20`. Each individual test should complete in under 500ms.

**Write tests:** No new tests — optimization only. All existing tests must still pass. Use the Benchmarking instructions above.

---

## Task 112: Pre-build specialized git repo templates for remaining integration tests

**Goal:** Optimize test suite performance by eliminating remaining inline git setup in integration test files. The full suite must be faster after this change than before.

**Benchmarking:** Run `time bats --jobs 20 tests/` once at the start to record the baseline time. Do NOT re-run the baseline — one measurement is enough. After all changes are complete and tests pass, run it once more to confirm improvement.

**NOTE:** Task 111 already converted most test files to the shared global template pattern and removed most inline `git init` calls. `test_dispatcher_cycle.bats` and `test_rebase_cycle.bats` already have zero inline git inits. Do NOT redo that work. Focus only on remaining opportunities.

**Problem:** `test_git_ops.bats` still has 1 remaining inline `git init` call. Some integration test files that create specialized repos (bare remotes, multi-branch histories) in `setup()` could benefit from building those once in `setup_file()` and copying per test.

**Implementation:**

1. **Audit remaining inline `git init` calls** across all test files. Eliminate any that can be replaced with a pre-built template in `setup_file()`.

2. **For files that need specialized repos** (bare remotes, specific branch structures), build the specialized template once in `setup_file()` and `cp -r` per test instead of rebuilding each time.

3. **Do not touch files already using the shared template pattern** unless there's a measurable performance gain from further optimization.

**Write tests:** No new tests — optimization only. All existing tests must still pass. Use the Benchmarking instructions above.

---

## Task 113: Log test suite wall-clock time in pipeline

**Problem:** The pipeline runs the test suite 2-3 times per task (post-coder, post-fixer, pre-merge) but doesn't log how long each run takes. Without this data, we can't track whether test performance is improving or regressing across tasks. This applies to any project autopilot works on, not just autopilot itself — knowing how long a project's test suite takes is essential for tuning timeouts and spotting regressions.

**Implementation:**

1. **Add `timer_log` calls around `run_test_gate` and `_run_postfix_tests`.** Log the wall-clock time of each test suite execution with a descriptive label (e.g., `TIMER: test gate (85s)`, `TIMER: post-fix tests (72s)`). This should work generically regardless of the test framework the project uses.

2. **Include the test gate timing in the pipeline log.** The existing `TIMER:` format is already parsed by metrics — just add the calls at the right points in `lib/dispatch-handlers.sh` and `lib/postfix.sh`.

3. **Log a test summary alongside the timing.** After the test gate runs, log a one-line summary like: `TEST_GATE: 2191 tests, 2191 passed, 0 failed in 72s`. Use the existing `parse_test_summary` infrastructure from `lib/test-summary.sh` to extract pass/fail counts. For test frameworks where parsing isn't supported, still log the wall-clock time and exit code.

4. **Record test gate duration in metrics CSV.** Add a `test_gate_seconds` column to the phase timing CSV so test duration is tracked per task over time.

**Write tests:** Add tests in `tests/test_testgate.bats` or `tests/test_postfix.bats` verifying that the timer log entries are written after test gate runs. Verify the summary line format.

---

## Task 114: Convert remaining test files to nogit template

**Goal:** Optimize test suite performance by switching more test files to the lightweight nogit template. The full suite must be faster after this change than before.

**Benchmarking:** Run `time bats --jobs 20 tests/` once at the start to record the baseline time. Do NOT re-run the baseline — one measurement is enough. After all changes are complete and tests pass, run it once more to confirm improvement.

**NOTE:** Task 111 already added `_init_test_from_template_nogit()` to `test_template.bash` and converted several test files to use it. Do NOT redo that work. Focus only on test files still using `_init_test_from_template` that don't actually need git.

**Problem:** Some test files still use `_init_test_from_template` (which copies the full git repo) even though they never use git operations. Switching them to `_init_test_from_template_nogit` saves the `cp -r` of the `.git` directory per test.

**Implementation:**

1. **Audit test files still using `_init_test_from_template`.** Grep for files calling it and check whether any test in that file actually uses git commands.

2. **Switch non-git test files to `_init_test_from_template_nogit`.** Only change files where no test needs a real git repo.

3. **Do not modify files already using `_init_test_from_template_nogit`** — they were converted in task 111.

**Write tests:** No new tests — optimization only. All existing tests must still pass. Use the Benchmarking instructions above.

---

## Task 115: Eliminate remaining real sleep calls that waste test time

**Goal:** Optimize test suite performance by eliminating the last wasted sleep time in production code polling loops. The full suite must be faster after this change than before.

**Benchmarking:** Run `time bats --jobs 20 tests/` once at the start to record the baseline time. Do NOT re-run the baseline — one measurement is enough. After all changes are complete and tests pass, run it once more to confirm improvement.

**NOTE:** Task 111 already reduced sleep calls in `test_spec_review_async.bats` (from `sleep 1`/`sleep 2` to `sleep 0.1`) and `test_perf_summary.bats` (from `sleep 5` to `sleep 0.5`). Do NOT redo that work. Focus only on the remaining `sleep 1` in production code.

**Problem:** `_wait_pid_timeout()` in `lib/reviewer.sh` still uses `sleep 1` polling — this burns ~1s per reviewer wait call across ~17 tests in `test_review_entry.bats` (~17s total).

**Implementation:**

1. **Replace `sleep 1` polling in `_wait_pid_timeout` with bash `wait`.** The `wait $pid` builtin blocks until the process exits with zero CPU/sleep overhead. Use a timeout wrapper to preserve the timeout behavior:
   ```bash
   _wait_pid_timeout() {
     local pid="$1" max_seconds="$2"
     # wait is a builtin — returns immediately when process exits
     # timeout wraps it to enforce the deadline
     if timeout "$max_seconds" bash -c "wait $pid" 2>/dev/null; then
       wait "$pid" 2>/dev/null || true
       return 0
     fi
     return 1
   }
   ```
   Use your own best judgment on the exact approach — the key requirement is eliminating the `sleep 1` granularity so tests don't burn ~1s per reviewer wait.

2. **Verify production behavior is preserved.** The `_wait_pid_timeout` timeout must still work correctly for long-running reviewers. Test with both fast-exit (mock) and slow-exit scenarios.

3. **Audit for any other remaining `sleep` calls** in production code (`lib/*.sh`) or test files that burn >0.5s. Eliminate or reduce them.

**Write tests:** No new tests — optimization only. All existing tests must still pass. Use the Benchmarking instructions above.

---

## Task 116: Replace subshell calls with bash builtins in production code

**Goal:** Speed up production code in `lib/*.sh` and `bin/*` by replacing external command subshells with equivalent bash builtins. The full test suite must be faster after this change than before, since production code runs inside every test.

**Benchmarking:** Run `time bats --jobs 20 tests/` once at the start to record the baseline time. Do NOT re-run the baseline — one measurement is enough. After all changes are complete and tests pass, run it once more to confirm improvement.

**NOTE:** Task 111 already replaced `$(dirname ...)` with `${var%/*}` in many places. Do NOT redo that work. Focus on the remaining patterns below.

**Problem:** Production code in `lib/*.sh` is sourced by every test. Subshell calls like `$(cat file)`, `$(date ...)`, `$(basename ...)`, and `$(dirname ...)` each fork a process. With 2191 tests, even one unnecessary fork per sourced function costs thousands of process spawns. Task 111 proved that eliminating subshells in production code has a bigger impact than optimizing test infrastructure.

**Implementation — only implement changes that measurably improve performance:**

1. **`$(cat file)` → `$(<file)`** — 26 calls in lib/. The `$(<file)` form is a bash builtin that reads without forking. Drop-in replacement.

2. **`$(date -u '+%Y-%m-%dT%H:%M:%SZ')` → `printf '%(%Y-%m-%dT%H:%M:%SZ)T' -1`** — 18 calls. The `printf %T` format is a bash builtin (bash 4.2+). This is especially impactful in `log_msg` which runs on every log line.

3. **`$(basename "$path")` → `${path##*/}`** — 8 remaining calls. Pure string manipulation, no fork.

4. **`$(dirname "$path")` → `${path%/*}`** — 11 remaining calls not fixed by task 111.

5. **Audit for other replaceable patterns.** `$(echo ...)` and `$(printf ...)` subshells (39 calls) are often unnecessary — the value can be assigned directly or computed with parameter expansion.

6. **Do NOT change calls that must be subshells** — `$(git ...)`, `$(jq ...)`, `$(gh ...)`, `$(timeout ...)` are external commands that require forking.

**Write tests:** No new tests — optimization only. All existing tests must still pass. Use the Benchmarking instructions above.

---

## Task 117: Show test timing and correct test count in PR comments

**Problem:** The pipeline logs test suite wall-clock time and test counts to `pipeline.log` (added in task 113), but this information doesn't appear in the GitHub-visible PR comments. The fixer completion and test failure comments in `lib/pr-comments.sh` show a test summary line (e.g., "Tests: 2191 total, 2191 passed, 0 failed") but don't include the wall-clock duration. Additionally, the test count shown in PR comments can be wrong because `test_gate_output.log` may contain stale output from a previous test run (see task 132).

**Implementation:**

1. **Add wall-clock duration to test summary in PR comments.** Modify `_format_test_failure_body` and `_format_fixer_result_body` in `lib/pr-comments.sh` to include the test duration. The summary line should read something like: `**Tests: 2191 total, 2191 passed, 0 failed in 72s**`. The duration is already available from `log_test_timing_and_summary` in `lib/test-summary.sh` — pass it through to the comment builder.

2. **Ensure test_gate_output.log is fresh before each test run.** Truncate or delete `test_gate_output.log` at the start of `run_test_gate` and `_run_postfix_tests` so the PR comment always reflects the most recent test run, not a stale one. This fixes the incorrect test count problem.

3. **Pass the test duration from the test gate caller to the PR comment builder.** The duration is computed in `dispatch-handlers.sh` and `postfix.sh` — thread it through to `post_test_failure_comment` and `post_fixer_result_comment` so the comment includes it.

**Write tests:** Add tests in `tests/test_pr_comments.bats` verifying that the test duration appears in the comment body. Add a test that verifies stale output logs are cleared before a new test run.

---

## Task 118: Cache repeated lookups in production code hot paths

**Goal:** Speed up production code by caching values that are computed repeatedly via expensive calls. The full test suite must be faster after this change than before.

**Benchmarking:** Run `time bats --jobs 20 tests/` once at the start to record the baseline time. Do NOT re-run the baseline — one measurement is enough. After all changes are complete and tests pass, run it once more to confirm improvement.

**Problem:** Several functions are called many times per dispatch cycle with the same arguments, each time re-reading files or spawning external commands. Since tests simulate dispatch cycles, this overhead multiplies across the test suite.

**Implementation — only implement changes that measurably improve performance:**

1. **Batch `read_state` calls.** `read_state` is called 33 times across `lib/*.sh`, each time running `jq` on `state.json`. Where multiple fields are read in sequence (e.g., reading `status`, `current_task`, and `retry_count` in the same function), read the JSON once with a single `jq` call that extracts all fields.

2. **Cache `get_repo_slug`.** Called 16 times — runs `git remote get-url origin` each time. The repo slug never changes during a pipeline run. Compute once on first call, cache in a global variable.

3. **Cache `build_branch_name`.** Called 16 times — deterministic for a given task number. Cache the result per task.

4. **Cache `detect_tasks_file`.** Called 8 times — scans the filesystem each time. The tasks file doesn't change during a run.

5. **Only cache values that are truly invariant during a dispatch cycle.** Don't cache `read_state` globally — state changes during the cycle. Only batch reads within a single function scope where multiple fields are needed at once.

**Write tests:** No new tests — optimization only. All existing tests must still pass. Use the Benchmarking instructions above.

---

## Task 119: Skip redundant load_config in per-test setup

**Goal:** Reduce CPU time by ~10% (~20s) by skipping the redundant `load_config` call in per-test `setup()`. Config defaults are loaded once in `setup_file()` and inherited by forked test processes, making the per-test call a no-op.

**Implementation:**

1. **Add one-shot skip flag to `load_config()` in `lib/config.sh`.** At the top of `load_config()`, check for `_AUTOPILOT_SKIP_NEXT_LOAD=1`. If set, clear the flag and return immediately — skipping the full snapshot/defaults/parse/restore cycle (~128ms per call). Subsequent explicit `load_config` calls run fully.

2. **Pre-load config in `_create_test_template()` in `tests/helpers/test_template.bash`.** After the template is built (or found ready), call `load_config "$_TEMPLATE_GIT_DIR"` once in `setup_file()` scope so forked test processes inherit the defaults.

3. **Set skip flag in `_init_test_from_template()` and `_init_test_from_template_nogit()`.** Set `_AUTOPILOT_SKIP_NEXT_LOAD=1` so the per-test `load_config` call becomes a no-op. Tests that explicitly call `load_config` in their test body still get a full run.

**Write tests:** No new tests — optimization only. All existing tests must still pass. Run `time bats --jobs 20 --no-parallelize-within-files tests/` before and after to confirm CPU time reduction.

---

## Task 120: Investigate and fix test_launchd 256ms/test overhead

**Goal:** Reduce the per-test cost in `test_launchd.bats` from ~256ms to under 100ms, bringing it in line with the suite average.

**Problem:** `test_launchd.bats` runs 61 tests in 15.6s sequential time — 256ms per test, which is 4x the suite average (~70ms). This file is the critical path for wall-clock time with `--jobs 20`. Something expensive is happening in each test's setup that other files don't do.

**Implementation:**

1. **Profile the per-test setup.** Add timing instrumentation to `test_launchd.bats` setup to identify what's slow — template copy, mock creation, sourcing, or something test-specific (e.g. plist generation, launchctl mocks).

2. **Move expensive setup to `setup_file()`.** Any per-test work that doesn't vary between tests (mock scripts, fixture files, config) should be created once and shared or copied cheaply.

3. **Eliminate unnecessary I/O.** If tests create temp files, plist fixtures, or mock scripts via heredocs in every test, consolidate them.

**Write tests:** No new tests — optimization only. All existing tests must still pass.

---

## Task 121: Split fat test files to reduce critical path

**Goal:** Split the two slowest test files so no single file takes more than 8 seconds sequential time, reducing the parallel critical path.

**Problem:** With `--jobs 20`, wall clock is bounded by the slowest single file. `test_launchd.bats` (15.6s, 61 tests) and `test_reviewer_posting.bats` (14.0s, 56 tests) are the bottleneck — even with perfect parallelism of everything else, you can't go below ~15.6s.

**Implementation:**

1. **Split `test_launchd.bats`** into 2-3 files by logical grouping (e.g. install/uninstall, status/control, config/plist). Target ~8s max per file.

2. **Split `test_reviewer_posting.bats`** into 2 files by logical grouping (e.g. comment creation vs. comment updating, or by reviewer type). Target ~7s max per file.

3. **Verify parallelism improves.** Run `bats --jobs 20 --no-parallelize-within-files --timing tests/` and confirm the critical path dropped.

**Write tests:** No new tests — purely mechanical split. All existing tests must still pass with identical test names and coverage.

---

## Task 122: Add read-only test init tier for zero-copy test setup

**Goal:** Add `_init_test_readonly` to `test_template.bash` that points `TEST_PROJECT_DIR` at the shared template without copying. For tests that only read config, check constants, or validate formats — zero per-test I/O.

**Problem:** Every test currently pays `cp -rc` cost (~15-25ms) even if it only reads config values or validates output formats. With 2191 tests and 20 concurrent workers, the cumulative I/O contention is significant.

**Implementation:**

1. **Add `_init_test_readonly()` to `tests/helpers/test_template.bash`.** Sets `TEST_PROJECT_DIR` to the shared template directory directly (no copy). Sets up `TEST_MOCK_BIN` and PATH as usual. Sets `_AUTOPILOT_SKIP_NEXT_LOAD=1`.

2. **Audit test files for read-only candidates.** Tests that only call pure functions, validate config defaults, check string formatting, or test output parsing are candidates. Tests that write to `TEST_PROJECT_DIR` (state.json, logs, config files) are NOT candidates.

3. **Convert qualifying tests.** Change their setup from `_init_test_from_template` or `_init_test_from_template_nogit` to `_init_test_readonly`. Run the full suite to confirm no test pollution between tests sharing the same directory.

**Write tests:** No new tests — optimization only. All existing tests must still pass. Watch for test pollution: if two tests sharing a readonly dir both write to the same path, they'll corrupt each other.

---

## Task 123: Optimize test suite to under 45 seconds — reduce per-test overhead

**Goal:** Get the full test suite under 45 seconds wall-clock time with `--jobs 20`.

**Benchmarking:** Run `time bats --jobs 20 --no-parallelize-within-files tests/` once at the start to record the baseline time. Do NOT re-run the baseline — one measurement is enough. After all changes are complete and tests pass, run it once more to confirm the suite is under 45 seconds.

**Problem:** After tasks 111-122 (subshell elimination, caching, sleep removal, template optimizations, load_config skip, file splitting, read-only tier), the suite should be approaching 45 seconds. The remaining overhead is per-test `cp -r` cost, mock script file creation via heredocs, and any remaining subprocess spawning. This task is the final push to get under 45 seconds. Only implement changes that measurably improve wall-clock time — benchmark before and after each change.

**Implementation:**

1. **Reduce per-test `cp -r` cost.** The template repo is copied ~1800 times. Make the template minimal (single empty commit, no extra files). Consider `cp -al` (hardlink copy) on supported systems for near-zero-cost copies.

2. **Consolidate mock creation.** Tests that write identical mock scripts via heredocs in `setup()` should create them once in `setup_file()` and copy or reference them. Avoid per-test file I/O for mocks that don't vary between tests.

3. **Audit remaining slow tests.** Profile with `bats --jobs 20 --timing tests/` and fix any remaining outliers.

4. **Target: full suite under 45 seconds** with `--jobs 20`. Use the Benchmarking instructions above.

**Write tests:** No new tests — optimization only. All existing tests must still pass. Use the Benchmarking instructions above.

---

## Task 124: Push branch and create PR before coder starts

**Problem:** The coder runs locally for up to 45 minutes (or longer with the new 90-minute timeout) before the dispatcher pushes the branch and creates a PR. During that time there's zero visibility into what the coder is doing — no PR to watch, no commits on GitHub, no way to diagnose issues without SSH-ing into the machine. If the coder times out, you only find out after the full timeout elapses.

**Implementation:**

1. **Push branch immediately after creation.** In `lib/dispatch-handlers.sh` (or wherever `create_task_branch` is called for the `pending` handler), push the branch to the remote right after creating it: `git -C "$worktree_dir" push -u origin "$branch_name"`.

2. **Create a draft PR before spawning the coder.** After pushing the empty branch, create a draft PR with `gh pr create --draft --title "Task N: ..." --body "Implementation in progress"`. Store the PR number in state immediately so fixer comments and other pipeline features work from the start.

3. **Add a post-commit hook that pushes.** Install a Claude Code hook (in the coder's settings.json alongside the existing lint/test hooks) that runs `git push` after each commit. This way every commit the coder makes is immediately visible on the PR. Use `git push --no-verify` to avoid hook recursion.

4. **Convert draft to ready when coder finishes.** After the coder completes (or times out), convert the draft PR to ready with `gh pr ready "$pr_number"` before running reviews. This preserves the existing flow — reviewers still see a "ready" PR.

5. **Handle retries.** On coder retry, the branch and PR already exist — skip creation, just ensure the branch is pushed. The PR stays in draft during retries.

**Write tests:** In `tests/test_dispatcher.bats` — verify that the branch is pushed and draft PR is created before the coder spawns. Verify commits are pushed via hook. Verify draft is converted to ready after coder completes.

---

## Task 125: Fix wall-clock and test-time metrics for agent phases

**Problem:** The `wall` field in agent timing metrics only captures Claude's internal process time, not the actual elapsed wall-clock time including subprocess calls (test suite runs via hooks, test gates, postfix verification). This makes metrics unreliable — a coder phase that takes 36 minutes of real time reports `wall=3s`. The test suite is the dominant time cost in the pipeline but is completely invisible in metrics.

**Implementation:**

1. **Fix wall-clock timing.** In `lib/metrics.sh` (or wherever timing is captured), record wall time as the difference between start and end timestamps using `date +%s` (epoch seconds) around the actual `run_claude` / `run_agent_with_hooks` call. This captures the full elapsed time including hook-triggered test runs, not just Claude's internal duration.

2. **Record test suite duration separately.** In `lib/testgate.sh` (`run_test_gate`), record the wall-clock duration of each test suite invocation and write it to a metrics line: `METRICS: test_suite task N — wall=Ns exit=E tests_total=T tests_passed=P`. Do the same for postfix verification in `lib/postfix.sh` and any hook-triggered test runs.

3. **Include test time in phase summaries.** In the phase timing line (`METRICS: phase timing task N`), add a `test=Ns` field that sums all test suite durations for that task. Example: `phase timing task 94 — impl=1080s test=720s fixing=540s merging=26s total=4320s`.

4. **Fix the phase timer.** The current phase timing shows `impl=0s` for all phases. Investigate why and fix — it should track real time spent in each state (`implementing`, `pr_open`, `reviewed`, `fixing`, `merging`).

**Write tests:** `tests/test_metrics_timing.bats` — verify that wall-clock timing captures elapsed time correctly (mock `date +%s` to return controlled values). Verify test suite duration is recorded. Verify phase summaries include test time.

---

## Task 126: Fail-fast when fixer produces no output

**Problem:** When the fixer agent times out or crashes, it produces 0 turns and empty output (`wall=0s api=0s turns=0`). The pipeline still runs the full postfix test suite (~4 min), which obviously fails since no code was changed. Then it loops back for another fixer cycle. Each empty fixer wastes ~15 min (fixer timeout + postfix tests + test gate on next cycle). On task 98, two empty fixers burned 30 min doing nothing.

**Implementation:**

1. **Detect empty fixer output.** In `lib/dispatch-handlers.sh`, after the fixer returns, check if the fixer produced any commits by comparing `git rev-parse HEAD` in the worktree against `sha_before_fix`. If HEAD hasn't moved and the fixer exit code is non-zero (timeout/crash), skip postfix verification entirely.

2. **Skip postfix on empty fixer.** When the fixer produced no commits and failed, log a warning (`"Fixer produced no output — skipping postfix verification"`) and go straight to the retry/exhaustion logic. Still post the fixer result comment (it already says "No new commits from fixer") so the PR has visibility.

3. **Count it as a failed fixer attempt.** Increment `test_fix_retries` as normal so the pipeline still exhausts retries and moves on rather than looping forever.

**Write tests:** In `tests/test_fixer.bats` or a new `tests/test_fixer_failfast.bats` — verify that when the fixer produces no commits and exits non-zero, postfix verification is skipped. Verify the fixer result comment is still posted. Verify retry count still increments.

---

## Task 127: Diagnose and fix empty fixer runs

**Problem:** Fixers sometimes produce 0 turns and 0 output — they time out or crash without doing any work. This has happened repeatedly (tasks 95, 98) and wastes entire fixer cycles. The root cause is unclear: the fixer might be receiving a malformed prompt, hitting an auth issue that isn't surfaced, or the Claude process might be hanging on startup.

**Implementation:**

1. **Add fixer startup logging.** Before spawning the fixer in `lib/fixer.sh`, log the prompt size in bytes and estimated tokens. After the fixer returns, log the exit code, output file size, and whether the output file contains valid JSON. This makes it possible to distinguish "fixer timed out mid-work" from "fixer never started."

2. **Capture and preserve fixer stderr.** The fixer's stderr (Claude CLI diagnostics) is currently written to `${output_file}.err` but cleaned up immediately. When the fixer produces 0 output, copy the stderr file to `.autopilot/logs/fixer-task-N-stderr.log` before cleanup so the failure can be diagnosed.

3. **Add a fixer health check.** Before spawning the fixer, verify the prompt is non-empty and the config dir (if set) exists. If the prompt is empty, log an error and skip the fixer spawn entirely rather than wasting a timeout cycle.

4. **Retry with backoff on empty output.** When a fixer produces 0 output, wait 30 seconds before the next attempt (the issue may be transient — rate limiting, auth token refresh). Log the retry delay.

**Write tests:** In `tests/test_fixer.bats` — verify that fixer stderr is preserved on empty output. Verify empty prompt is caught before spawn. Verify the retry delay is applied after empty output.

---

## Task 128: Document supported project types and test/lint configuration

**Goal:** Add a `docs/project-types.md` reference documenting which languages/frameworks are auto-detected and which require manual configuration. Update `docs/configuration.md` and `README.md` to link to it.

**Content to document:**

1. **Auto-detected test frameworks** — list what `_auto_detect_test_cmd` supports: pytest (via `conftest.py` or `pyproject.toml`), npm test (via `package.json` scripts.test), bats (via `tests/*.bats`), make test (via `Makefile` test target). Explain detection order and precedence.

2. **Auto-detected lint commands** — currently only `make lint` (Makefile with `lint:` target). Everything else falls back to no-op.

3. **Manual configuration for unsupported languages** — show examples of `AUTOPILOT_TEST_CMD` and `AUTOPILOT_LINT_CMD` for common frameworks not auto-detected: Ruby (`bundle exec rspec`), Rust (`cargo test`), Go (`go test ./...`), Java (`./gradlew test` or `mvn test`), Jest (`npx jest`). Include a table of example configs.

4. **Test output parsing** — note that test summary parsing (pass/fail counts in PR comments) currently recognizes bats TAP output and pytest output. Other frameworks will show raw output without structured counts. Document `AUTOPILOT_TEST_CMD` as the override for any project.

5. **Lint configuration** — document that if there's no `make lint`, the lint hook is a no-op. Show how to set a custom lint command.

**Write tests:** No new tests — documentation only. Existing tests must still pass.

---

## Task 129: Auto-detect lint and test commands for more languages

**Problem:** The test gate auto-detects pytest, npm test, bats, and make test. Lint detection only checks for `make lint`. Projects using Ruby, Rust, Go, Java, or standalone linters like ruff/eslint require manual `AUTOPILOT_TEST_CMD` configuration. The pipeline should work out of the box for common project types.

**Implementation:**

1. **Expand test auto-detection** in `lib/testgate.sh` `_auto_detect_test_cmd()`. Add detection for:
   - **Rust:** `cargo test` (detected via `Cargo.toml`)
   - **Go:** `go test ./...` (detected via `go.mod`)
   - **Ruby:** `bundle exec rspec` (detected via `Gemfile` + `spec/` dir) or `bundle exec rake test` (detected via `Rakefile`)
   - **Java/Gradle:** `./gradlew test` (detected via `gradlew`)
   - **Java/Maven:** `mvn test` (detected via `pom.xml`)

2. **Expand lint auto-detection** in `lib/hooks.sh` `_build_lint_command()`. Add detection for:
   - **Python:** `ruff check .` (detected via `ruff.toml` or `pyproject.toml` with `[tool.ruff]`) or `flake8` (detected via `.flake8` or `setup.cfg` with `[flake8]`)
   - **Node:** `npx eslint .` (detected via `.eslintrc*` or `package.json` with `eslint` in devDependencies)
   - **Rust:** `cargo clippy` (detected via `Cargo.toml`)
   - **Go:** `golangci-lint run` (detected via `.golangci.yml`)
   - **Ruby:** `bundle exec rubocop` (detected via `.rubocop.yml`)
   - Fall back to `make lint` then no-op as before.

3. **Update the allowlist** in `lib/testgate.sh` to include the new commands (`cargo`, `go`, `bundle`, `gradlew`, `mvn`, `ruff`, `flake8`, `golangci-lint`, `rubocop`).

**Write tests:** In `tests/test_testgate.bats` and `tests/test_hooks.bats` — verify auto-detection for each new language by creating the marker files (e.g., `Cargo.toml`, `go.mod`) in the test project dir and checking the detected command.

---

## Task 130: Parse test summaries from all major test frameworks

**Problem:** Task 99 added test summary parsing (pass/fail counts, duration) for PR comments, but it only recognizes bats TAP output (`ok`/`not ok` lines) and pytest output. Projects using rspec, cargo test, go test, jest, mocha, JUnit, or other frameworks get raw output with no structured summary. The PR comment just shows "Tests: unknown" instead of useful counts.

**Implementation:**

1. **Add parsers for common test output formats** in the test summary module (likely `lib/test-summary.sh` or wherever task 99 put the parsing logic). Each parser extracts: total tests, passed, failed, duration. Parsers to add:
   - **Jest/Vitest:** `Tests: 5 passed, 2 failed, 7 total` and `Time: 3.42 s`
   - **RSpec:** `10 examples, 2 failures` and optional `Finished in 1.23 seconds`
   - **Go test:** `ok  pkg/foo 0.123s`, `FAIL pkg/bar 0.456s`, and `--- FAIL:` lines
   - **Cargo test:** `test result: ok. 15 passed; 2 failed; 0 ignored` and `finished in 1.23s`
   - **JUnit/Maven:** `Tests run: 10, Failures: 2, Errors: 1, Skipped: 0`
   - **Generic TAP:** already handled (bats uses TAP), but ensure TAP from other runners works too

2. **Use the detected test command to select the parser.** The test gate already knows which framework it's running (from `detect_test_cmd` or `AUTOPILOT_TEST_CMD`). Pass this info to the summary parser so it runs only the matching parser — don't brute-force all parsers against every output. For example, if the test command starts with `cargo`, use the cargo parser; if it starts with `pytest`, use the pytest parser. Only fall back to trying all parsers if the command is custom/unrecognized.

3. **Fallback gracefully.** If no parser matches, show the last 10 lines of output as-is with "Tests: completed (no structured output detected)". Never show "unknown" with no context.

**Write tests:** `tests/test_test_summary.bats` — provide sample output from each framework and verify the parser extracts the correct counts and duration.

---

## Task 131: Configurable reviewer mode — allow interactive reviews

**Problem:** Reviewers currently run in `--print` mode only (hardcoded in `lib/reviewer.sh`). They receive the diff via stdin and output their findings in a single pass. This is fast and cheap, but the reviewer cannot explore the repo, read related files, or check test coverage — it can only see the diff. For complex changes, an interactive Claude Code session would produce deeper reviews.

**Implementation:**

1. **Add `AUTOPILOT_REVIEWER_INTERACTIVE` config variable.** Default: `false`. When `false`, reviewers use `--print` mode (current behavior). When `true`, reviewers run as interactive Claude Code sessions that can use tools to explore the repo.

2. **Modify `_run_single_reviewer` in `lib/reviewer.sh`.** When interactive mode is enabled, instead of `--print` with diff on stdin, pass the diff as part of the prompt and omit `--print` so Claude gets full tool access. The reviewer should still run in the worktree directory so it has access to the codebase.

3. **Keep the timeout.** Interactive reviews take longer — consider using a separate `AUTOPILOT_TIMEOUT_REVIEWER_INTERACTIVE` (default: 300s) distinct from the print-mode timeout.

4. **Per-persona override.** Allow individual personas to opt into interactive mode via a frontmatter flag in the persona `.md` file (e.g., `interactive: true`), so you can have some reviewers fast (print) and others deep (interactive).

**Write tests:** In `tests/test_reviewer.bats` — verify that when `AUTOPILOT_REVIEWER_INTERACTIVE=true`, the reviewer runs without `--print`. Verify default is `--print` mode. Verify per-persona override works.

---

## Task 132: Fix fixer PR comment showing stale test results and missing duration

**Problem:** Two bugs in the fixer PR comment when worktrees are enabled (`AUTOPILOT_USE_WORKTREES=true`, the default):

1. **Missing test duration.** The fixer comment shows test counts but no duration (e.g., "Tests: 2205 total, 2205 passed, 0 failed" with no "in Ns" suffix). This is because `_run_postfix_tests` writes `test_gate_duration` to the **worktree's** `.autopilot/` directory (`$task_dir`), but `post_fixer_result_comment` reads from the **project root's** `.autopilot/` directory (`$project_dir`). The duration file simply doesn't exist at the path being read.

2. **Stale test output.** The test counts come from a stale `test_gate_output.log` left by the background test gate (`run_test_gate_background`), not from the postfix test run. The background test gate writes to `$project_dir/.autopilot/test_gate_output.log`, and this file is never cleared by the postfix test run (which writes to `$task_dir/.autopilot/`). The counts happen to match because it's the same test suite, but it's the wrong run's data — and can be contradictory (e.g., "✅ Passed" with "43 failed" if the background test gate ran against older code).

**Root cause:** Directory mismatch. The code path is:
- `_handle_fixer_result` passes `$project_dir` to `post_fixer_result_comment`
- `run_postfix_verification` resolves `$task_dir` via `resolve_task_dir` (worktree path)
- `_run_postfix_tests "$task_dir"` writes artifacts to `$task_dir/.autopilot/`
- `_parse_test_summary_from_log "$project_dir"` reads from `$project_dir/.autopilot/`
- These are different directories when worktrees are enabled.

**Implementation:**

1. **Pass `$task_dir` to the PR comment builder.** Have `run_postfix_verification` return (or have `_handle_fixer_result` resolve) the worktree path, and pass it to `post_fixer_result_comment` / `_parse_test_summary_from_log` so artifacts are read from the same directory they were written to. Alternatively, copy artifacts from `$task_dir/.autopilot/` to `$project_dir/.autopilot/` after postfix tests complete.

2. **Clear stale artifacts at `$project_dir/.autopilot/`.** Before the postfix test run, clear `test_gate_output.log` and `test_gate_duration` at the project root so stale data from the background test gate cannot be read.

3. **Add `persist_test_gate_duration` to `run_test_gate_background`.** The background test gate never writes a duration file — add the call so the initial test gate run also records timing.

**Write tests:** Add tests in `tests/test_pr_comments.bats` — verify that the fixer result comment includes test duration. Test the worktree case: postfix tests write to `$task_dir/.autopilot/`, PR comment reads the correct artifacts. Test that stale output from background test gate is not used.

---

## Task 133: Investigate — save_task_test_output reads from wrong directory in worktree mode

**Problem (suspected):** In `_handle_test_fixing` (`lib/dispatch-handlers.sh`), `run_test_gate "$task_dir"` writes `test_gate_output.log` to `$task_dir/.autopilot/`, but `save_task_test_output "$project_dir"` reads from `$project_dir/.autopilot/`. When worktrees are enabled, these are different directories. The test output may never be found, meaning fixer/test-fixer agents receive no test output context in their prompt.

**Investigation:** Trace the full code path from `_handle_test_fixing` through `run_test_gate`, `save_task_test_output`, and into the fixer/test-fixer prompt construction. Verify whether the test output log is read from the correct directory. Check whether `save_task_test_output` vs `save_task_test_output_raw` changes the behavior. Check recent PRs for evidence of fixers receiving empty or missing test output. If the bug exists, fix the directory mismatch. If it does not exist (e.g., the code path has been refactored), document why.

**Write tests:** If the bug exists, add a test verifying that test output is correctly passed to the fixer prompt when worktrees are enabled.

---

## Task 134: Investigate — run_fix_tests agent spawns in wrong directory in worktree mode

**Problem (suspected, critical):** In `run_fix_tests` (`lib/postfix.sh`), `_AGENT_WORK_DIR` is never set before calling `_run_agent_with_hooks`. Both `run_coder` (coder.sh:184) and `run_fixer` (fixer.sh:355) set `_AGENT_WORK_DIR="$work_dir"` to ensure Claude `cd`s into the worktree. But `run_fix_tests` omits this, so `_run_agent_with_hooks` defaults to `$project_dir` and the Claude agent runs in the project root (main branch) instead of the worktree (task branch). The fix-tests agent cannot see the task's code changes and any fixes go to the wrong branch.

**Investigation:** Verify the code path: confirm `run_fix_tests` does not set `_AGENT_WORK_DIR`. Confirm `_run_agent_with_hooks` (`lib/claude.sh`) defaults `work_dir` to `$project_dir` when `_AGENT_WORK_DIR` is unset. Check whether `run_fix_tests` receives `$project_dir` or `$task_dir` from its caller (`run_postfix_verification`). Check recent PRs for evidence of fix-tests agents failing or producing nonsensical output. If the bug exists, add `_AGENT_WORK_DIR` and resolve the correct worktree path. If it does not exist (e.g., the caller passes `$task_dir` as `$project_dir`), document why.

**Write tests:** If the bug exists, add a test verifying that `run_fix_tests` spawns the Claude agent in the worktree directory, not the project root.

---

## Task 135: Investigate — fix-tests hooks point at wrong directory in worktree mode

**Problem (suspected):** Because `run_fix_tests` does not set `_AGENT_WORK_DIR` (see task 134), `_run_agent_with_hooks` computes `work_dir=$project_dir` and calls `install_hooks "$project_dir"`. The hook commands (`_build_lint_command`, `_build_test_command`, `_build_push_command` in `lib/hooks.sh`) embed `cd '$project_dir'`, so lint, test, and push hooks all run against the project root instead of the worktree. Tests pass/fail against the wrong codebase, and pushes go to the wrong branch.

**Investigation:** Trace the hook installation path from `run_fix_tests` → `_run_agent_with_hooks` → `install_hooks`. Verify that the `cd` path in each hook command uses the directory passed to `install_hooks`. Check whether the hooks use the embedded path or whether Claude's own working directory overrides it. If the bug exists, it's fixed by fixing task 134 (setting `_AGENT_WORK_DIR`). If hooks behave correctly regardless (e.g., Claude's cwd takes precedence), document why.

**Write tests:** If the bug exists, add a test verifying that hooks installed during `run_fix_tests` point at the worktree, not the project root.

---

## Task 136: Investigate — post_test_failure_comment reads test output from wrong directory

**Problem (suspected):** In `_handle_test_fixing` (`lib/dispatch-handlers.sh`), after `run_test_gate "$task_dir"` writes test output to `$task_dir/.autopilot/`, `post_test_failure_comment "$project_dir"` reads from `$project_dir/.autopilot/`. The test failure PR comment may show empty test output or stale data from a previous run.

**Investigation:** Trace the code path from `_handle_test_fixing` through `post_test_failure_comment` → `_build_test_failure_comment` → `_parse_test_summary_from_log`. Verify which directory the test output log and duration file are read from. Check recent PRs where tests failed for evidence of missing or incorrect test output in failure comments. If the bug exists, fix the directory mismatch by passing `$task_dir` to the comment builder. If it does not exist, document why.

**Write tests:** If the bug exists, add a test verifying that test failure PR comments include the correct test output when worktrees are enabled.

## Task 137: Fix spec compliance reviewer — diagnose and fix silent failures

**Problem:** The "every 5 PRs" spec compliance reviewer (`lib/spec-review.sh`, `lib/spec-review-async.sh`) runs but produces no output. It starts, reads the spec file, exits 0 after ~16 seconds, but never logs "Spec review completed after task N" — meaning it never reaches or completes the Claude call. No spec review output files exist in `.autopilot/logs/`. The last GitHub issue it created was after task 30 (issue #34); it has silently done nothing for tasks 35–136.

**Investigation:**
1. Check `AUTOPILOT_SPEC_REVIEW_CONFIG_DIR` and `AUTOPILOT_CODER_CONFIG_DIR` — both are unset. The Claude call in `_run_spec_review_claude` may fail without auth config, but errors are swallowed because the background subshell uses `set +e`.
2. The background subshell in `run_spec_review_async` captures exit code but not stderr. If `run_claude` fails, `_run_spec_review_claude` logs an error, but `log_msg` from a background subshell may not flush to the pipeline log if the process exits immediately after.
3. Test by running `run_spec_review` synchronously (not async) with `AUTOPILOT_SPEC_REVIEW_CONFIG_DIR` set to the coder's config dir, and check if it produces output.

**Fix:** Ensure the spec review has valid Claude auth (fall back to a working config dir). Add a log message at the very start of the Claude call and immediately after, so failures are visible. If `config_dir` is empty, log a warning and skip rather than silently failing. Write a test that verifies `run_spec_review` logs completion when given valid inputs.

## Task 138: Add stderr capture for background spec review

**Problem:** The background spec review subshell in `run_spec_review_async` (`lib/spec-review-async.sh`) captures the exit code to a `.exit` file but discards all stderr. When the Claude call or any other step fails, the error messages are invisible — they go to the subshell's stderr which is inherited from the parent but may not reach the pipeline log.

**Implementation:**
1. Redirect the background subshell's stderr to a log file: `.autopilot/logs/spec-review-stderr-task-N.log`.
2. In `check_spec_review_completion`, when the background process finishes with a non-zero exit, log the last 20 lines of the stderr file as a WARNING.
3. Clean up stderr log files older than 5 runs.
4. Write tests: verify stderr file is created on failure, verify completion check logs stderr content on error, verify old files are cleaned up.

## Task 139: Auto-retry on draft PR creation failure

**Problem:** `_push_and_create_draft_pr` in `lib/dispatch-helpers.sh` is best-effort — if it fails, the pipeline continues without a PR. Before the fix in commit `a039a7f`, this caused a critical bug: the stale `pr_number` from the previous task leaked into the new task's state, causing the coder to push to an already-merged PR. The fix clears `pr_number` on task advance, but the draft PR creation failure itself is still not retried — the pipeline just logs a warning and moves on, creating the PR after the coder finishes instead.

**Implementation:**
1. In `_push_and_create_draft_pr`, add a single retry with a 5-second delay if the initial `create_draft_pr` call fails. Log each attempt.
2. If the push itself fails (not just PR creation), retry the push once before giving up.
3. If both retries fail, ensure state explicitly has `pr_number` set to empty string (defensive, since `_advance_task` now clears it, but protects against edge cases on retry_count >= 1 where advance isn't called).
4. Write tests: verify retry on PR creation failure, verify `pr_number` is empty after all retries fail, verify success on second attempt writes correct PR number.

## Task 140: Auto-detect and inject project.md into agent context

**Objective:** When a `project.md` file exists in the project root, autopilot should automatically include it in every agent's context — coder, fixer, reviewer, and merger. This gives agents high-level understanding of what the system does, complementing CLAUDE.md (which covers how to write code) and the task description (which covers what to do now). No configuration needed — if the file exists, it's used.

**Suggested path:** The session cache already collects CLAUDE.md and context files via `_collect_context_paths` in `lib/session-cache.sh`. Add `project.md` detection there, between CLAUDE.md and the configured context files. The coder prompt in `lib/coder.sh` also explicitly lists context files via `_build_context_section` — include `project.md` there too, above other context files. The session cache content hash should incorporate `project.md` so the cache invalidates when it changes.

**Tests:** Verify `_collect_context_paths` includes `project.md` when present and omits it when absent. Verify the content hash changes when `project.md` content changes. Verify `_build_context_section` lists `project.md` in the coder prompt.

## Task 141: Documentation update — cover features added in tasks 103–140

**Objective:** Review all merged PRs since task 102 (the last documentation update) and update README.md and docs/ to reflect the current state of the project. The README should accurately describe what autopilot does, how to install, run, and test it. The docs should cover any new user-facing features, configuration options, or behavioral changes added since task 102.

**Suggested path:** Run `gh pr list --state merged` to find all PRs from tasks 103–140. Read each PR title and description to identify user-facing changes. Key areas likely needing docs updates: test optimization features, worktree mode, draft PR creation, configurable reviewer mode, auto-detection of test/lint commands, test framework parsing, project.md support, and the spec compliance reviewer. Update README.md and any relevant files in docs/. Don't document internal implementation details — focus on what a user of autopilot needs to know.

## Task 142: Skip draft PR creation when branch has no commits ahead of base

**Objective:**

When `_push_and_create_draft_pr` runs in `_handle_pending`, the task branch has just been created from main with zero new commits. GitHub rejects the draft PR creation ("No commits between main and branch"), which always fails. The retry loop with `sleep 5` wastes ~11-13 seconds per tick, and on projects where the cron interval is 15 seconds, this causes the tick to run so long that the next cron tick overlaps before the state transitions to `implementing` — creating an infinite loop where the coder never spawns.

Fix: before attempting to create a draft PR, check whether the task branch has any commits ahead of the base branch. If there are zero commits ahead, skip the push and PR creation entirely. Log that it was skipped. The draft PR will be created later after the coder makes commits.

**Tests:** `tests/test_dispatch_helpers.bats`

- Draft PR creation is skipped when branch has no commits ahead of base
- Draft PR creation proceeds normally when branch has commits ahead

## Task 143: Prevent dispatch tick overlap when draft PR retry exceeds cron interval

**Objective:**

The draft PR retry logic (`_push_and_create_draft_pr` with `sleep 5` between attempts) can take 11-13 seconds total. When the cron tick interval is 15 seconds, this leaves almost no time for the rest of `_handle_pending` to complete before the next tick starts. If the lock expires or the next tick starts before `update_status "implementing"` is written, both ticks race on the same task.

Fix: the draft PR creation should respect a time budget so it never consumes more than a fraction of the tick interval. One approach is to remove the sleep between retries and attempt only once (the retry was added in task 139 but causes more harm than good when the failure is deterministic). Another approach is to write `implementing` status *before* the draft PR attempt, so even if it takes long, the next tick won't re-enter `_handle_pending`. The second approach changes the state machine ordering — evaluate which is safer.

**Tests:** `tests/test_dispatch_helpers.bats`

- State transitions to `implementing` even when draft PR creation fails
- Draft PR creation timeout does not block coder spawn

## Task 144: Doctor and start should verify scheduler is installed

**Objective:**

`autopilot-doctor` should check whether the pipeline scheduler is active for the current project. On macOS, this means launchd agents are loaded and their plist files reference this project directory. On Linux, this means crontab entries exist that reference the project. If no scheduler is found, doctor should report FAIL with instructions to run `autopilot-schedule`.

`autopilot-start` relies on the doctor passing, but even when all doctor checks pass today, the pipeline can silently do nothing because no scheduler is ticking. After removing the PAUSE file, the user thinks it's running when it isn't. If the doctor's new scheduler check fails, `autopilot-start` should offer to run `autopilot-schedule` in interactive mode, or print the command and exit with an error in non-interactive mode.

**Tests:** `tests/test_doctor.bats` (or new file if needed)

- Reports FAIL when no launchd agents reference the project directory (macOS)
- Reports FAIL when no crontab entries reference the project directory (Linux)
- Reports PASS when matching scheduler entries are found

## Task 145: Fix _compute_hash crash under launchd PATH

**Objective:**

`_compute_hash` in `lib/dispatch-handlers.sh` crashes the entire dispatch tick under `set -euo pipefail` when run via launchd. The function tries `command -v md5` (fails — `/sbin/` not in launchd PATH), falls through to `md5sum` (also not in PATH), and the pipeline dies at line 219 before ever reaching `update_status "implementing"`. This causes an infinite restart loop where the coder never spawns. The same function is used in `lib/session-cache.sh` for content hashing.

The function was written in task 71 for cross-platform support: `md5` on macOS, `md5sum` on Linux. Both exist on their platforms but `/sbin/` is not in the minimal PATH that `autopilot-schedule` sets in launchd plists.

Fix both sides: make `_compute_hash` resilient to minimal PATH environments by checking absolute paths (`/sbin/md5` on macOS) as fallbacks, and add `/sbin` to the PATH in the launchd plist template in `autopilot-schedule`. Also add a doctor check that verifies `md5` or `md5sum` is reachable — if neither is found, report FAIL with a clear message.

**Tests:** `tests/test_dispatch_helpers.bats`

- `_compute_hash` produces output when `md5` is not on PATH but `/sbin/md5` exists
- `_compute_hash` produces output when only `md5sum` is available
- Doctor reports FAIL when neither `md5` nor `md5sum` is reachable

## Task 146: README installation instructions

**Objective:**

The README does not clearly explain how to install autopilot so that commands are available on PATH. Users clone the repo and try to run `autopilot-init` directly, which fails with "command not found". The installation flow should be front and center in the README: clone, `make install`, ensure `~/.local/bin` is on PATH. This is the first thing a new user needs and it's currently missing or buried.

**Suggested path:**

Add a clear "Installation" section near the top of README.md covering: clone the repo, run `make install` (which symlinks binaries to `~/.local/bin`), add `~/.local/bin` to PATH if not already there. Include the shell command to add it to `~/.zshrc` or `~/.bashrc`. Then describe the quick start: `cd your-project && autopilot-init && autopilot-start`.

**Tests:** No automated tests — this is documentation only.

## Task 147: Fixer crash recovery should retry as fixer, not full coder

**Objective:**

When the fixer agent crashes (or the dispatch tick dies during `fixing` state), crash recovery resets the pipeline all the way back to `pending`, which re-runs the full coder from scratch. This wastes 15-45 minutes redoing work that's already committed, when the fixer just needed to address a few review comments. The fixer should get at least one retry as a fixer before falling back to a full coder re-run.

Currently `_handle_fixing` is just `_handle_crash_recovery "$1" "fixing"` which unconditionally resets to pending. Instead, it should check how many fixer attempts have been made. On the first crash, retry as `reviewed` (which re-enters `_handle_reviewed` and spawns a new fixer). Only after repeated fixer failures should it fall back to the full coder via `pending`.

**Tests:** `tests/test_dispatch_handlers.bats`

- First fixer crash retries as fixer (state goes to `reviewed`, not `pending`)
- Second consecutive fixer crash falls back to full coder (state goes to `pending`)
- Fixer retry counter resets on successful fix

## Task 148: Fix RAM disk contention when multiple worktrees run tests concurrently

**Objective:**

`make test` creates a RAM disk at `/Volumes/AutopilotTests` using `hdiutil attach` + `diskutil erasevolume`. When two worktrees (e.g. task-100 and task-147) run `make test` concurrently, the second `diskutil erasevolume` hangs indefinitely because the volume name `AutopilotTests` is already in use by the first. This caused task 147 to block for over 2 hours until manual intervention.

The root cause is that the RAM disk setup in the Makefile uses a hardcoded volume name with no locking or uniqueness. Fix:

1. **Unique volume names per invocation:** Use a unique volume name like `AutopilotTests-$$` (PID) so concurrent test runs don't collide on the volume name.
2. **Timeout on diskutil:** Add a timeout (e.g. 10 seconds) around the `diskutil erasevolume` call so it doesn't hang forever if there's a conflict. Fall back to disk-based tests on timeout.
3. **Cleanup stale volumes:** On test start, detect and detach any orphaned `AutopilotTests*` RAM disks that have no active bats processes using them.

**Tests:** `tests/test_concurrent_gate.bats` or new file

- Two concurrent `make test` invocations don't deadlock
- RAM disk creation falls back gracefully when volume name conflicts
- Tests still pass when RAM disk setup is skipped

## Task 149: Add `autopilot-schedule --list` to show installed scheduler agents

**Objective:**

There is no way to see which autopilot scheduler agents are installed, which projects they point to, which accounts they use, or whether they're running. `launchctl list | grep autopilot` shows labels but not the project paths or account mappings. Users need a quick way to see the full picture.

Add a `--list` flag to `autopilot-schedule` that displays all installed autopilot launchd agents with: label, project directory, account number, CLAUDE_CONFIG_DIR, interval, and current status (running PID or stopped). On Linux, show the equivalent crontab entries.

Also fix: when switching accounts (e.g. `--account 1` to `--account 2`), the old agents with different labels are not cleaned up. `autopilot-schedule` should detect and remove any existing autopilot agents for the same project before installing new ones, regardless of account number.

**Tests:** `tests/test_launchd_install.bats` or existing schedule tests

- `--list` shows correct project, account, and status for installed agents
- Re-scheduling with a different account removes the old agents
- `--list` with no agents installed shows a clear "no agents" message

## Task 150: Fix bin/ scripts breaking when invoked via symlinks

**Objective:**

All 6 scripts in `bin/` use `source "${BASH_SOURCE[0]%/*}/../lib/entry-common.sh"` to find the shared library. When invoked via symlinks (e.g. `~/.local/bin/autopilot-start` → `repo/bin/autopilot-start`), `BASH_SOURCE[0]` resolves to the symlink location, not the real file. This causes `lib/entry-common.sh: No such file or directory` on every manual CLI invocation after `make install`.

The launchd agents use full paths and are unaffected, but all manual usage (`autopilot-start .`, `autopilot-doctor .`, `autopilot-status .`) is broken.

Fix: resolve the symlink before computing the path to `lib/`. Use `readlink -f` (Linux) or a portable equivalent for macOS (which lacks `readlink -f` without coreutils). Apply the fix to all 6 affected scripts: `autopilot-dispatch`, `autopilot-doctor`, `autopilot-live-test`, `autopilot-review`, `autopilot-start`, `autopilot-status`.

**Tests:** `tests/test_install.bats` or new file

- Scripts work when invoked via symlink
- Scripts still work when invoked directly
- Symlink resolution works on macOS (no GNU readlink required)

## Task 151: Use project name in launchd agent labels to prevent cross-project stomping

**Objective:**

Launchd agent labels are currently `com.autopilot.{role}.{account}` (e.g. `com.autopilot.dispatcher.1`). When two projects use the same account number, scheduling the second project overwrites the first project's plist file — the label is identical so the old agent silently gets replaced. This means only one project can run per account, which defeats the purpose of multi-project support.

Change the label format to include the project name: `com.autopilot.{project}.{role}.{account}` (e.g. `com.autopilot.mathviz.dispatcher.1`, `com.autopilot.ai-reviewer.dispatcher.2`). Derive the project name from the basename of the project directory.

This affects `autopilot-schedule` (label generation, install, uninstall, `--list`), the doctor's scheduler check (matching labels to projects), and any code that parses or matches launchd labels. The `self` prefix used for the autopilot project itself should also follow the new convention.

Migration: on `autopilot-schedule` run, detect and remove any old-format agents (`com.autopilot.{role}.{account}`) for the same project before installing new-format ones.

**Tests:** `tests/test_launchd_install.bats`

- Two projects on the same account get distinct labels
- Scheduling project B does not remove project A's agents
- Old-format labels are cleaned up on re-schedule
- `--uninstall` removes only the target project's agents

## Task 152: Fixer should fall back to cold start when session resume fails

**Objective:**

The fixer agent tries to `--resume` the coder's Claude session for context continuity. If the session ID doesn't exist (e.g. account was switched mid-task, session expired, or config dir changed), Claude exits immediately with `No conversation found with session ID: ...`, exit code 1, and zero output. The fixer treats this as a failure, burns a retry, and the cycle repeats until Phase B reset.

Add a fallback: when `run_claude` with `--resume` fails and produces zero output, check stderr for "No conversation found". If detected, log a warning, discard the stale session ID, and retry immediately as a cold start (with system prompt) within the same fixer invocation — don't consume a retry count for a session lookup failure.

**Suggested Path:**

In `lib/fixer.sh`, after `_run_agent_with_hooks` returns with a failure, check if the output file is empty/zero-bytes and stderr contains "No conversation found". If so, rebuild `extra_args` without `--resume` (add `--system-prompt` instead) and re-run. Log the fallback clearly: `"Session ${session_id} not found — falling back to cold start"`.

Also delete the stale coder/fixer JSON that contained the bad session ID so subsequent fixer iterations don't hit the same problem.

**Tests:** `tests/test_fixer.bats`

- Fixer falls back to cold start when resume session not found
- Stale session JSON is cleaned up after fallback
- Retry count is not incremented for session-not-found failures

## Task 153: Fix autopilot-init to create hard pause

**Objective:**

`autopilot-init` creates an empty PAUSE file via `touch .autopilot/PAUSE` (line 422 of `bin/autopilot-init`). An empty file is a soft pause, which does not prevent the dispatcher from entering a tick. This means installing launchd agents during init immediately starts the pipeline before the user runs `autopilot-start`.

Change `autopilot-init` to write content to the PAUSE file so it acts as a hard pause.

**Suggested Path:**

In `bin/autopilot-init`, replace `touch ".autopilot/PAUSE"` with:
```bash
echo "Paused by autopilot-init. Run autopilot-start to begin." > ".autopilot/PAUSE"
```

Update the existing test `"init: creates .autopilot/PAUSE file"` to verify the file has non-empty content (hard pause), not just that it exists.

**Tests:** `tests/test_init.bats`

- PAUSE file created by init has non-empty content
- PAUSE file content is treated as hard pause by `check_quick_guards` (returns 1)

## Task 154: Fix soft pause to prevent task advancement after merge

**Objective:**

`_handle_merged` in `lib/dispatch-helpers.sh` calls `_finalize_merged_task` which calls `_advance_task` without ever checking for soft pause. A soft-paused pipeline that merges a task immediately advances to the next task and starts a new coder on the next tick, defeating the purpose of soft pause ("finish current work, then stop").

Add a `check_soft_pause` call so the pipeline stops between tasks when soft-paused.

**Suggested Path:**

In `lib/dispatch-helpers.sh`, add `check_soft_pause "$project_dir"` at the end of `_handle_merged()`, after `_finalize_merged_task` returns. This allows the current task's merge finalization (metrics, summary, worktree cleanup) to complete, but prevents the next task from starting.

**Tests:** `tests/test_soft_pause.bats`

- Soft pause after merge: `_handle_merged` calls `check_soft_pause`
- Task advances (status becomes `pending` for next task) but the tick exits before `_handle_pending` runs
- Hard pause is unaffected (still blocks at tick entry)

## Task 155: Fix soft pause flag to survive across ticks

**Objective:**

The soft pause mechanism sets `_AUTOPILOT_SOFT_PAUSE=1` as a process-local environment variable in `check_quick_guards`, then `check_soft_pause` checks that variable later. But each launchd tick is a new process — the flag dies when the tick exits. The next tick sets it again, does one phase of work, exits, and the cycle repeats indefinitely. Soft pause effectively does nothing.

Fix `check_soft_pause` to re-read the PAUSE file from disk instead of relying on a process-local flag.

**Suggested Path:**

Replace the flag-based check in `check_soft_pause` (in `lib/entry-common.sh`) with a direct filesystem check:

```bash
check_soft_pause() {
  local project_dir="$1"
  local pause_file="${project_dir}/.autopilot/PAUSE"
  if [[ -f "$pause_file" ]]; then
    local content
    content="$(cat "$pause_file" 2>/dev/null | tr -d '[:space:]')"
    if [[ -z "$content" ]]; then
      log_msg "$project_dir" "INFO" \
        "Soft pause — stopping after phase completion"
      exit 0
    fi
  fi
}
```

This way, soft pause is checked from disk at every phase boundary regardless of which process is running. The `_AUTOPILOT_SOFT_PAUSE` flag and its export in `check_quick_guards` can be removed as dead code.

**Tests:** `tests/test_soft_pause.bats`

- Soft pause file on disk causes `check_soft_pause` to exit (without relying on env flag)
- Removing PAUSE file between ticks allows next tick to proceed
- `check_soft_pause` is a no-op when no PAUSE file exists
- Two simulated ticks with empty PAUSE file: second tick is also blocked at phase boundary

## Task 156: Merger should retry merge instead of resetting to pending

**Objective:**

When `squash_merge_pr` fails (exit=2), `_handle_merger_result` calls `_retry_or_diagnose`, which resets the task all the way back to `pending` — spawning a full coder re-run. But a merge failure doesn't mean the code is wrong. The merger already approved it, tests pass. The failure is an operational issue (GitHub API race, transient error, mergeability not computed yet). Resetting to `pending` wastes a full coder cycle and can make things worse by deleting the branch and closing the PR.

Add a dedicated merge retry path that retries the merge operation itself (with a short delay for GitHub to compute mergeability) before falling back to the general retry logic.

**Suggested Path:**

In `lib/merger.sh`, modify `squash_merge_pr` to check the PR's mergeable status before attempting merge. If status is `UNKNOWN`, wait up to 30 seconds (polling every 5s) for GitHub to compute it. If `CONFLICTING`, attempt auto-rebase first.

In `lib/dispatch-handlers.sh`, modify the `MERGER_ERROR` case in `_handle_merger_result` to:
1. Check if the PR is still open — if closed, reopen it with `gh pr reopen`
2. Retry the merge up to 3 times (with 5s delay between attempts) before calling `_retry_or_diagnose`
3. Only fall back to `_retry_or_diagnose` if all merge retries fail

Add a `merge_retry_count` to state.json, similar to `fixer_retry_count`.

**Tests:** `tests/test_merger.bats`

- Merge retry succeeds on second attempt without resetting to pending
- Merge retries exhausted falls back to `_retry_or_diagnose`
- Closed PR is reopened before merge retry
- UNKNOWN mergeable status triggers wait/poll before merge attempt

## Task 157: Check PR state before attempting squash merge

**Objective:**

`squash_merge_pr` calls `gh pr merge --squash` without first checking if the PR is open. If the PR was closed (e.g., by GitHub auto-closing when the head ref was deleted during a retry), the merge always fails with exit 2. The pipeline retries the merge against a closed PR until retries are exhausted, wasting all retry budget on an impossible operation.

Add a PR state check before merge and handle the closed-PR case.

**Suggested Path:**

In `lib/merger.sh`, add a pre-merge check in `squash_merge_pr`:

```bash
local pr_state
pr_state="$(timeout "$timeout_gh" gh pr view "$pr_number" \
  --repo "$repo" --json state --jq '.state' 2>/dev/null)" || true

if [[ "$pr_state" == "CLOSED" ]]; then
  log_msg "$project_dir" "WARNING" \
    "PR #${pr_number} is closed — attempting reopen"
  timeout "$timeout_gh" gh pr reopen "$pr_number" \
    --repo "$repo" 2>/dev/null || {
    log_msg "$project_dir" "ERROR" \
      "Failed to reopen PR #${pr_number}"
    return 1
  }
  # Wait for GitHub to process the reopen
  sleep 3
fi
```

Also add a mergeability poll: if `mergeable` is `UNKNOWN`, poll up to 30s before proceeding. The current code logs "Unknown mergeable status — proceeding" in `resolve_pre_merge_conflicts` which is too optimistic.

**Tests:** `tests/test_merger.bats`

- Closed PR is reopened before merge attempt
- Failed reopen returns error (doesn't attempt merge on closed PR)
- UNKNOWN mergeability triggers polling with timeout

## Task 158: Prevent branch deletion from closing the PR during retries

**Objective:**

When `_retry_or_diagnose` resets a task to `pending` from the `merging` state, the next `_handle_pending` call may delete the task branch (Phase B reset at retry 3+). Deleting the head ref causes GitHub to auto-close the associated PR. Subsequent merge attempts then fail because the PR is closed.

The pipeline should not delete a branch that has an open PR associated with it during retry, or if it must recreate the branch, it should reopen the PR afterward.

**Suggested Path:**

In `_handle_branch_reset` (lib/dispatch-handlers.sh), before deleting the branch, check if there's an open PR for it. If so, either:
- Skip the branch delete and reset the branch to the target ref instead (`git reset --hard origin/main`), or
- After recreating the branch and force-pushing, reopen the PR with `gh pr reopen`

The simpler approach: when retrying from `merging` state specifically, don't go all the way back to `pending`. Instead, add a dedicated merge-retry path that stays in the `merging`/`fixed` area without touching the branch.

**Tests:** `tests/test_dispatcher_pending.bats`

- Branch with open PR is not deleted during Phase B reset
- PR is reopened if branch was recreated
- Retry from merging state does not reset to pending on first merge failure

## Task 159: Log stderr from gh commands instead of swallowing it

**Objective:**

`squash_merge_pr` in `lib/merger.sh` (line 231) runs `gh pr merge ... 2>/dev/null`, throwing away the actual error message from GitHub. This makes merge failures impossible to diagnose — the log just says "Failed to squash-merge" with no reason. The same pattern (`2>/dev/null` on `gh` and `git` calls) appears in several other places: `check_pr_mergeable`, `rebase_task_branch`, and `squash_merge_pr`.

Capture stderr from `gh` and `git` commands and log it on failure instead of discarding it.

**Suggested Path:**

In `squash_merge_pr`, capture stderr to a variable and log it on failure:

```bash
local merge_stderr
merge_stderr="$(timeout "$timeout_gh" gh pr merge "$pr_number" \
  --squash --delete-branch \
  --repo "$repo" 2>&1 1>/dev/null)" || {
  log_msg "$project_dir" "ERROR" \
    "Failed to squash-merge PR #${pr_number}: ${merge_stderr}"
  return 1
}
```

Apply the same pattern to `check_pr_mergeable` (line 43), `rebase_task_branch` (lines 104, 114), and any other `gh` or `git` call that uses `2>/dev/null` and then logs a generic error on failure. Leave `2>/dev/null` in place for calls that intentionally ignore errors (like `launchctl bootout` in schedule scripts or optional cleanup commands).

**Tests:** `tests/test_merger.bats`

- Failed squash merge logs the stderr from `gh pr merge`
- Failed mergeable check logs the stderr from `gh pr view`

---

## Task 160: Include task description in reviewer prompts

**Objective:**

The reviewers currently only receive the PR diff with the prompt "Review the
following PR diff." They have no context about what the task was supposed to
accomplish, so they cannot detect missing features — only code quality issues
within what was implemented. This caused a real miss: PR #45 in the mathviz
project was supposed to add HTML UI elements for resolution controls, but
only the backend was implemented. No reviewer caught it because none of them
knew what the task required.

Pass the task description from `tasks.md` to each reviewer so they can verify
that the diff actually implements what the task specifies. This enables
reviewers to flag missing work, not just bugs in existing work.

**Suggested Path:**

1. In `_execute_review_cycle()` in `review-runner.sh`, extract the task
   description the same way the merger does (lines 757-763 of
   `dispatch-handlers.sh`):
   ```bash
   local task_number
   task_number="$(read_state "$project_dir" "current_task")"
   local tasks_file
   tasks_file="$(detect_tasks_file "$project_dir")" || true
   local task_description=""
   if [[ -n "$tasks_file" ]] && [[ -n "$task_number" ]]; then
     task_description="$(extract_task "$tasks_file" "$task_number")" || true
   fi
   ```

2. Pass `task_description` through to `run_reviewers()` in `reviewer.sh`,
   which passes it to `_run_single_reviewer()`.

3. In `_run_single_reviewer()`, prepend the task description to the diff
   file (or include it in the prompt) so each reviewer sees both what was
   requested and what was implemented:
   ```
   ## Task Description
   <task body from tasks.md>
   ---
   ## PR Diff
   <diff>
   ```

4. For standalone mode (`--pr N`), the task number may not be in
   `state.json`. In that case, skip the task description gracefully — the
   reviewer prompt should work with or without it.

5. Update the reviewer persona prompts (especially `general.md` and
   `design.md`) to mention that when a task description is provided, they
   should verify the diff implements what the task requires, and flag
   missing features or incomplete implementations.

**Tests:** `tests/test_reviewer.bats`

- Reviewer prompt includes task description when available in state
- Reviewer prompt works without task description (standalone mode)
- Task description is extracted from tasks.md using current_task from state
- Each reviewer persona receives the task description in its input

## Task 161: Auto-heal missing `--dangerously-skip-permissions` in non-interactive mode Auto-heal missing `--dangerously-skip-permissions` in non-interactive mode

When preflight detects non-interactive mode (no TTY) but `AUTOPILOT_CLAUDE_FLAGS`
does not contain `--dangerously-skip-permissions`, the pipeline logs CRITICAL and
fails — every 10 seconds, forever. This creates an infinite error loop if
`autopilot.conf` is accidentally deleted by a git operation or missing from a
new project that was started without `autopilot-init`.

**Fix:** In preflight, if non-interactive mode is detected, auto-inject
`--dangerously-skip-permissions` into `AUTOPILOT_CLAUDE_FLAGS` in memory (do not
write to disk). Log an INFO or WARNING that the flag was auto-applied. The
reasoning: if you're running unattended, you necessarily need this flag — there
is no valid scenario where a non-interactive dispatch should hang waiting for
permission prompts.

**Implementation:**

1. In `lib/preflight.sh`, find the check that validates `AUTOPILOT_CLAUDE_FLAGS`.
2. Instead of logging CRITICAL and returning failure, append
   `--dangerously-skip-permissions` to `AUTOPILOT_CLAUDE_FLAGS` in the current
   shell environment.
3. Log: `[WARN] Non-interactive mode: auto-injected --dangerously-skip-permissions
   into CLAUDE_FLAGS (set explicitly in autopilot.conf to suppress this warning)`
4. Continue preflight — do not fail.

**Tests:** `tests/test_preflight.bats`

- Non-interactive mode without flag in config: preflight passes, flag is injected
- Non-interactive mode with flag already set: no warning, no duplicate injection
- Interactive mode without flag: no injection (interactive mode doesn't need it)

## Task 162: Color-coded doctor output and streaming in `autopilot start`

Two UX issues with `autopilot-doctor` and `autopilot-start`:

### Issue 1: Doctor output has no color

`[PASS]`, `[FAIL]`, and `[WARN]` brackets in `autopilot-doctor` are plain text.
They should use ANSI colors when outputting to a terminal (TTY):
- `[PASS]` → green (`\033[32m`)
- `[FAIL]` → red (`\033[31m`)
- `[WARN]` → yellow (`\033[33m`)

Only colorize when stdout is a TTY (`[[ -t 1 ]]`). When piped or captured, emit
plain text (no escape codes).

**Implementation:**

1. In `bin/autopilot-doctor`, add a color detection block near the top:
   ```bash
   if [[ -t 1 ]]; then
     _GREEN=$'\033[32m' _RED=$'\033[31m' _YELLOW=$'\033[33m' _RESET=$'\033[0m'
   else
     _GREEN="" _RED="" _YELLOW="" _RESET=""
   fi
   ```

2. Update `_pass()`, `_fail()`, and `_warn()` (lines 95-101):
   ```bash
   _pass() { echo "${_GREEN}[PASS]${_RESET} $1"; }
   _fail() { echo "${_RED}[FAIL]${_RESET} $1"; _DOCTOR_FAILURES=$(( _DOCTOR_FAILURES + 1 )); }
   _warn() { echo "${_YELLOW}[WARN]${_RESET} $1"; }
   ```

3. Also colorize the final summary line:
   - "All checks passed." → green
   - "N check(s) failed." → red

### Issue 2: `autopilot start` buffers all doctor output

`bin/autopilot-start` line 88 captures doctor output into a variable:
```bash
DOCTOR_OUTPUT="$("$DOCTOR_CMD" "$PROJECT_DIR" 2>&1)" || DOCTOR_STATUS=$?
```

This suppresses all output until doctor finishes (5-10 seconds of silence).
Users should see checks printing in real-time as they complete.

**Fix:** Run doctor directly (not captured), using `tee` or a temp file to
preserve the output for the scheduler-failure grep on line 94:

```bash
DOCTOR_TMPFILE="$(mktemp)"
trap 'rm -f "$DOCTOR_TMPFILE"' EXIT
DOCTOR_STATUS=0
"$DOCTOR_CMD" "$PROJECT_DIR" 2>&1 | tee "$DOCTOR_TMPFILE" || DOCTOR_STATUS=${PIPESTATUS[0]}

if [[ "$DOCTOR_STATUS" -ne 0 ]]; then
  echo ""
  if grep -qF '[FAIL] No scheduler found' "$DOCTOR_TMPFILE"; then
    _offer_scheduler_install
  fi
  echo "Start aborted — fix the issues above and try again."
  exit 1
fi
```

This streams doctor output in real-time while still capturing it for the
scheduler check.

**Tests:** `tests/test_doctor.bats`

- PASS lines include green ANSI codes when stdout is a TTY
- FAIL lines include red ANSI codes when stdout is a TTY
- No ANSI codes when stdout is not a TTY (piped)
- WARN lines include yellow ANSI codes when stdout is a TTY

**Tests:** `tests/test_start.bats` (or wherever start is tested)

- `autopilot start` streams doctor output (not buffered)
- Scheduler failure detection still works with tee-based capture

## Task 163: Handle oversized diffs with a diff-reduction reviewer instead of failing

**Problem:**

When a PR diff exceeds `AUTOPILOT_MAX_DIFF_BYTES` (default 500KB), the reviewer
returns exit code 2 and `_transition_on_error` keeps the pipeline in `pr_open`.
The next tick retries, hits the same size limit, and repeats until
`reviewer_retry_count` hits 6 and the pipeline pauses. The diff never shrinks,
so this is a guaranteed stuck state.

This happened in practice: a coder renamed 166 files instead of just deleting 29
duplicates, producing a 643KB diff that permanently blocked the pipeline.

**Solution:**

Instead of failing, spawn a special **diff-reduction reviewer** that analyzes the
oversized diff and leaves review comments suggesting how to shrink it. Then the
fixer addresses those suggestions, and if the diff drops below the limit, the
normal 5-reviewer process runs.

### New state flow for oversized diffs

```
pr_open → diff too large → spawn diff-reduction reviewer → post comments
        → transition to "reviewed" (same as normal review)
        → fixer addresses comments → transition to "fixed"
        → re-check diff size:
            - If now under limit → transition to "pr_open" for normal review
            - If still over limit → retry diff-reduction (up to max retries)
```

### 1. Add diff-reduction reviewer prompt

Create `reviewers/diff-reduction.md`:

```markdown
You are reviewing a pull request whose diff is too large for the normal review
pipeline. Your job is to suggest concrete changes that will reduce the diff size
so that the regular code reviewers can process it.

## Common causes of oversized diffs

1. **File renames/renumbering** — The coder deleted files then renumbered the
   remaining files to close gaps. Git sees this as N deletions + N additions
   instead of simple deletes. Fix: revert the renames, keep original filenames,
   leave gaps in numbering.

2. **Large generated/content files added** — A big file was added that could be
   generated at build time, split into smaller pieces, or doesn't belong in the
   repo.

3. **Unnecessary reformatting** — The coder reformatted files beyond what the
   task required, inflating the diff with whitespace/style changes.

4. **Copying instead of moving** — Code was duplicated rather than extracted,
   resulting in the same content appearing twice in the diff.

## What you receive

- A list of all changed files with their diff sizes
- Sampled portions of the diff (the full diff is too large to include)
- The task description (what the coder was supposed to implement)

## Instructions

- Identify which files are contributing most to the diff size
- Suggest specific, actionable changes to reduce the diff
- Focus on changes that preserve correctness while shrinking the diff
- Be specific: name the files, explain what to revert or restructure

## Output Format

List your suggestions as numbered items. Be concrete — the fixer agent will
execute these suggestions literally.

If you cannot identify ways to reduce the diff, respond with:
NO_REDUCTION_POSSIBLE
```

### 2. Modify `fetch_pr_diff` in `lib/reviewer.sh`

When the diff exceeds `max_diff_bytes`, instead of returning exit code 2,
build a **sampled diff file** containing:

1. A header stating the diff is oversized (`Total diff: 643KB, limit: 500KB`)
2. The full `--stat` output (file list with line counts — this is small)
3. The first ~200KB of the actual diff content (enough for the reviewer to
   see patterns)

Return this sampled diff file with a **new exit code 3** to distinguish it from
the hard-fail exit code 2.

```bash
if [[ "$diff_bytes" -gt "$max_diff_bytes" ]]; then
  log_msg "$project_dir" "WARNING" \
    "PR #${pr_number} diff too large (${diff_bytes} bytes > ${max_diff_bytes} max)"

  # Build sampled diff for diff-reduction reviewer.
  local sampled_diff_file
  sampled_diff_file="$(mktemp "${TMPDIR:-/tmp}/autopilot-sampled-diff.XXXXXX")"
  _build_diff_header "$pr_number" "$branch_name" "$repo" > "$sampled_diff_file"
  printf '\n## OVERSIZED DIFF\n\n' >> "$sampled_diff_file"
  printf 'Total diff size: %s bytes (limit: %s bytes)\n\n' \
    "$diff_bytes" "$max_diff_bytes" >> "$sampled_diff_file"
  printf '### Changed files (--stat):\n```\n' >> "$sampled_diff_file"
  timeout "$timeout_gh" gh pr diff "$pr_number" --repo "$repo" \
    -- --stat 2>/dev/null >> "$sampled_diff_file" || true
  printf '```\n\n### Sampled diff (first ~200KB):\n```diff\n' >> "$sampled_diff_file"
  printf '%s' "$raw_diff" | head -c 200000 >> "$sampled_diff_file"
  printf '\n```\n' >> "$sampled_diff_file"

  echo "$sampled_diff_file"
  return 3
fi
```

### 3. Handle exit code 3 in `_execute_review_cycle` in `lib/review-runner.sh`

When `fetch_pr_diff` returns exit code 3, run only the `diff-reduction`
reviewer (not the normal 5 reviewers):

```bash
diff_file="$(fetch_pr_diff "$project_dir" "$pr_number")" || {
  local exit_code=$?
  if [[ "$exit_code" -eq 3 ]]; then
    # Oversized diff — run diff-reduction reviewer only.
    diff_file="$(fetch_pr_diff_result)"  # get the sampled diff path
    log_msg "$project_dir" "INFO" \
      "Review: diff oversized for PR #${pr_number} — running diff-reduction reviewer"
    _run_diff_reduction_review "$project_dir" "$pr_number" "$diff_file" "$mode"
    return $?
  elif [[ "$exit_code" -eq 2 ]]; then
    # ... existing hard-fail handling ...
  fi
}
```

The `_run_diff_reduction_review` function:
- Runs a single Claude reviewer with the `diff-reduction.md` persona prompt
- Feeds it the sampled diff + task description
- Posts the suggestions as PR review comments (same as normal reviewers)
- Transitions to `reviewed` state (so the fixer picks it up)

### 4. After fixer runs, re-check diff size

In the dispatcher, when transitioning from `fixed` to the next state, re-fetch
the diff size. If it's now under the limit, transition to `pr_open` so the
normal 5-reviewer cycle runs. If still over the limit, increment retry count
and go back through the diff-reduction flow.

Add a config option `AUTOPILOT_MAX_DIFF_REDUCTION_RETRIES` (default 2) to
limit how many times the diff-reduction cycle repeats before pausing.

**Files:**

- `reviewers/diff-reduction.md` — new reviewer prompt
- `lib/reviewer.sh` — modify `fetch_pr_diff` to build sampled diff on exit code 3
- `lib/review-runner.sh` — handle exit code 3, add `_run_diff_reduction_review`
- `lib/dispatcher.sh` — after `fixed`, re-check diff size before normal review
- `lib/config.sh` — add `AUTOPILOT_MAX_DIFF_REDUCTION_RETRIES` default

**Tests:** `tests/test_reviewer.bats`

- Diff under limit: returns exit 0 with full diff file (unchanged behavior)
- Diff over limit: returns exit 3 with sampled diff file
- Sampled diff contains --stat output and first ~200KB of diff content
- Sampled diff header includes size information

**Tests:** `tests/test_review_runner.bats`

- Exit code 3 triggers diff-reduction reviewer (not normal reviewers)
- Diff-reduction review comments are posted to PR
- Pipeline transitions to `reviewed` after diff-reduction review
- Normal exit code 2 still triggers existing error handling (unchanged)

**Tests:** `tests/test_dispatcher.bats`

- After fixer on oversized diff: diff under limit → transitions to `pr_open`
- After fixer on oversized diff: diff still over limit → retries diff-reduction
- Max diff-reduction retries exceeded → pauses pipeline

## Task 164: Recover from closed/deleted PRs instead of getting stuck

**Problem:**

When a PR gets closed (manually, by GitHub auto-close on branch deletion, or during failed retry cycles), the pipeline doesn't detect it and continues operating on the dead PR. This causes a cascade of wasted work and eventually a stuck pipeline.

**Real-world failure (culture repo, task 73):**

1. Task 73 burned 5 retries on Claude 529 errors (API overloaded). The pipeline diagnosed and re-queued.
2. During the failed retries, PR #76 was closed (at 20:55).
3. On the successful retry (21:56), the coder finished and the pipeline found "Existing PR found for task 73 — skipping push/create" — but didn't check that PR #76 was **CLOSED**.
4. Tests, 5 reviewers ($2+), and a fixer all ran against the closed PR — all wasted.
5. The fixer crashed (likely because it couldn't push to a closed PR's branch), killing the dispatcher process.
6. Final state: `pr_open` pointing at closed PR #76, dispatcher dead, pipeline permanently stuck.

**Root cause:** `_ensure_pr_open()` exists and can reopen closed PRs, but it's only called during crash recovery and merge retries. It is NOT called at two critical points:
- When the coder finishes and finds an "existing PR" (line ~388 in dispatch-handlers.sh)
- When transitioning to `pr_open` state

**Fix:**

### 1. Validate PR state after coder completes

In `_handle_implementing_result()`, after finding an existing PR (`pr_url` is non-empty), call `_ensure_pr_open()` to verify the PR is still open. If the PR is CLOSED, attempt to reopen it. If reopen fails, create a new PR instead of proceeding with the closed one.

```
# After "Existing PR found" log message:
if ! _ensure_pr_open "$project_dir" "$pr_number"; then
  # PR is merged — skip to merged state
  update_status "$project_dir" "merged"
  return
fi
# _ensure_pr_open reopens CLOSED PRs automatically
```

### 2. Add PR state check at `pr_open` entry

In `_handle_pr_open()`, before checking the test gate result, verify the PR is still open. If the PR was closed externally (e.g., by a human or by GitHub), detect it early rather than letting reviews and fixers run against a dead PR.

```bash
local pr_number
pr_number="$(read_state "$project_dir" "pr_number")"
if [[ -n "$pr_number" && "$pr_number" != "0" ]]; then
  _ensure_pr_open "$project_dir" "$pr_number" || {
    # PR already merged externally — advance to merged
    update_status "$project_dir" "merged"
    return 0
  }
fi
```

### 3. Add PR state check before spawning fixer

In the `reviewed → fixing` transition, verify the PR is open before spawning the fixer agent. The fixer needs to push commits to the PR branch — if the PR is closed, the fixer will fail.

### 4. Handle reopen failure gracefully

If `_ensure_pr_open()` fails to reopen a closed PR (e.g., branch was deleted), the pipeline should:
- Log an ERROR with context
- Create a new PR from the existing branch (if the branch still exists)
- Or reset to `pending` and retry the task from scratch (if the branch is gone too)

Currently `_ensure_pr_open` silently continues after a failed reopen — it should return a distinct exit code so callers can handle the failure.

### 5. Improve `_ensure_pr_open()` return codes

Current behavior: returns 0 for open/closed (even if reopen fails), returns 1 only for MERGED. Change to:
- Return 0: PR is open (was already open, or successfully reopened)
- Return 1: PR is merged
- Return 2: PR is closed and reopen failed

This lets callers distinguish "PR is usable" from "PR is dead."

**Tests:** `tests/test_dispatch_handlers.bats`

- Coder completes with existing closed PR → PR is reopened before proceeding
- Coder completes with existing merged PR → transitions to merged state
- `_handle_pr_open` detects externally closed PR → reopens it
- Fixer is not spawned when PR is closed and reopen fails
- `_ensure_pr_open` returns distinct codes for open/merged/reopen-failed
- Pipeline creates new PR when reopen fails but branch still exists
- Pipeline resets to pending when both PR and branch are gone

## Task 165: Auto-convert draft PRs to ready instead of looping on merge failures

**Objective:**

When `mark_pr_ready` fails after the coder creates a draft PR, the pipeline should detect and recover from the draft state rather than burning retries. Currently, a failed `mark_pr_ready` is logged as a warning and the pipeline proceeds — but when the merger tries to squash-merge, GitHub rejects it with "Pull Request is still a draft." The merge retry loop retries the same merge without fixing the cause, exhausting all merge retries, then falling through to the main retry budget. This wastes the full retry budget on a single fixable error. In one observed case, this produced 43 failed merge attempts and 10 wasted merger reviews over 80 minutes before the task was skipped entirely.

The fix should ensure: (1) the merge flow detects "still a draft" errors and converts the PR to ready before retrying, (2) PR state checks also detect and fix draft status proactively, (3) draft-related merge failures don't count against the main retry budget, and (4) the initial `mark_pr_ready` failure is retried rather than silently accepted.

**Suggested path:**

The merge retry logic should check the last error for draft-related messages and call `gh pr ready` before the next attempt. The existing `_ensure_pr_open` functions are natural places to also query `isDraft` alongside `state` and convert proactively. For the initial `mark_pr_ready` after coder completion, a single retry with a short delay is enough — if it still fails, log at ERROR level so it's visible. When merge retries are exhausted but the cause is "still a draft," reset the merge retry counter after converting rather than falling through to the main retry budget.

**Tests:** `tests/test_dispatch_handlers.bats` and `tests/test_merger.bats`

- Merge fails with "still a draft" → PR is converted to ready before retry
- PR state check detects draft status and converts proactively
- "Still a draft" merge failures don't increment the main retry counter
- Initial `mark_pr_ready` failure is retried once before proceeding
- `gh pr ready` failure falls through to main retry budget with ERROR log

## Task 166: Self-update autopilot installation from git

**Objective:**

Autopilot installations are git checkouts that never update themselves. When bug fixes are merged to `origin/main`, remote machines keep running the old code until someone manually SSHes in and pulls. This is especially painful because autopilot fixes its own bugs — a fix merged on one machine doesn't reach others. The pipeline should periodically fast-forward pull its own install directory so that bug fixes propagate automatically.

The update must be safe: fast-forward only (never force-pull or create merge commits), skip if the install directory has local changes, and never block a dispatcher tick if the pull fails. Add an `AUTOPILOT_SELF_UPDATE_INTERVAL` config variable (default 300 seconds, 0 to disable).

**Suggested path:**

Use a marker file with a Unix timestamp to throttle checks — only fetch when enough time has elapsed. Resolve the install directory from `BASH_SOURCE` since the entry points already do this implicitly. Both the dispatcher and reviewer entry points should call the update check, but the shared marker ensures at most one fetch per interval. Log the new commit on success and a warning on failure.

**Tests:** `tests/test_self_update.bats`

- Update runs when marker is missing or stale, skipped when fresh
- Update skipped when install dir has uncommitted changes
- Update skipped when interval is set to 0
- Failed pull logs a warning but doesn't block the tick

## Task 167: Periodic cleanup of stale worktrees

**Objective:**

Worktrees accumulate in `.autopilot/worktrees/` when their owning process is killed before cleanup runs. Both task worktrees (`task-N`) and test worktrees (`test-NNNNN`) leak — the existing `cleanup_stale_worktrees` only handles `task-*` and ignores `test-*` entirely. The pipeline should periodically find and remove all worktrees older than a configurable max age (default 24 hours). "Age" is determined by the directory's modification time (`stat -f %m` on macOS).

Add config variables `AUTOPILOT_WORKTREE_CLEANUP_INTERVAL` (default 3600 seconds) and `AUTOPILOT_WORKTREE_MAX_AGE` (default 86400 seconds). After removing directories, run `git worktree prune` to clean up git's internal state.

**Suggested path:**

Use the same marker-file throttling pattern as the self-update check (Task 166). Iterate all directories under `.autopilot/worktrees/`, compare mtime to current time, and remove anything exceeding max age. Try `git worktree remove --force` first for clean bookkeeping, fall back to `rm -rf` for broken worktrees. Call the cleanup early in the dispatcher tick.

**Tests:** `tests/test_worktree_cleanup.bats`

- Worktrees older than max age are removed, younger ones preserved
- Both `task-*` and `test-*` patterns are cleaned
- Cleanup skipped when marker is fresh, runs when missing or stale
- `git worktree remove` failure falls back to `rm -rf`

## Task 168: Post agent session summary comment on PR after merge

**Objective:**

After a PR is successfully merged, the pipeline should post a single comment on the PR listing all the Claude agent sessions that contributed to it. This creates a debugging audit trail — given any merged PR, you can trace back to the exact coder, reviewer, fixer, and merger sessions. Each entry should include the agent role (coder, reviewer persona name, fixer, merger), the session ID, and the wall-clock duration if available. The comment should be concise and posted once, after merge completes.

The session IDs are already captured: `_save_agent_output()` saves Claude's JSON output (which contains `session_id`) to `.autopilot/logs/{agent}-task-{N}.json`. The task is to collect these at merge time and format them into a PR comment.

**Suggested path:**

After the merge succeeds, scan `.autopilot/logs/` for all `*-task-{N}.json` files. Extract `session_id` from each using `jq`. Format a markdown comment with a table or list of role + session ID + duration. Post it with `gh pr comment`. If any session file is missing or lacks a session ID, skip that entry rather than failing. This should not block or delay the merge — if the comment fails to post, log a warning and continue.

**Tests:** `tests/test_dispatch_handlers.bats`

- Session summary is posted after successful merge
- Missing or malformed session files are skipped gracefully
- Comment failure logs a warning but doesn't block the pipeline
- All agent roles (coder, reviewers, fixer, merger) are included when present
