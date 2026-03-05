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
- **Clean-review skip**: all reviewers return "no issues" sentinel, verify state skips from reviewed directly to merging.
- **Background test gate**: verify test gate runs in detached worktree, doesn't pollute main working tree.

## Task 30: Increase spec review timeout and run async

Bump `AUTOPILOT_TIMEOUT_SPEC_REVIEW` default from 300s to 1200s. Run spec review asynchronously — spawn it in the background so it doesn't block the dispatcher's main loop. Log the background PID and check for completion on subsequent ticks. Also increase `MAX_SPEC_BYTES` so the plan document isn't truncated from 40KB to 8KB (use 50000). Update `tests/test_spec_review.bats` to cover the async execution path and the new defaults.
