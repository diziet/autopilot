# Architecture

How Autopilot's internals work: the state machine, concurrency model, crash recovery, agent hooks, metrics, prompts, and reviewer personas.

## Overview

Autopilot is a scheduler-driven pipeline with two entry points:

- **`autopilot-dispatch`** — drives the state machine (implements, tests, fixes, merges)
- **`autopilot-review`** — detects `pr_open` state and runs code reviews

Both run every 15 seconds via macOS launchd (recommended) or cron. Each tick checks quick guards (PAUSE file, live lock PID) and exits in under 10ms when idle. When work is needed, the tick acquires a lock, performs one state transition, and exits.

Additional entry points support setup and operations:

- **`autopilot-init`** — interactive setup wizard that scaffolds config, tasks, CLAUDE.md, and scheduling
- **`autopilot-doctor`** — non-interactive validation (11 checks) that reports pass/fail with fix instructions
- **`autopilot-start`** — runs doctor, then removes the PAUSE file to start the pipeline
- **`autopilot-schedule`** — generates, installs, and uninstalls launchd plists for scheduling
- **`autopilot-status`** — displays pipeline health, state, and scheduling readiness

All coordination happens through filesystem state (`.autopilot/state.json`) and GitHub PRs. There is no daemon, no message queue, and no database: only files, locks, and the scheduler.

---

## State Machine

The dispatcher implements a 10-state finite state machine. Each tick reads the current state, runs the corresponding handler, and transitions to the next state.

```
pending ──→ implementing ──→ test_fixing ─┐
  ↑              │                         │
  │              │ (tests pass)            │ (tests pass after fix)
  │              ↓                         ↓
  │           pr_open ──→ reviewed ──→ fixing ──→ fixed ──→ merging ──→ merged ──→ completed
  │                          │  ↑                            ↓              │
  │                          │  └──── (REJECT) ─────────────┘              │
  │                          │                                             │
  │                          │ (all reviews clean)                         │
  │                          └──→ fixed                                    │
  │                                                                        │
  └──────────────────────── (next task) ──────────────────────────────────┘
```

### State Details

| State | Handler | What Happens |
|-------|---------|-------------|
| `pending` | `_handle_pending` | Read next task, reset stale branches, create task branch, spawn coder agent |
| `implementing` | `_handle_implementing` | Coder process died (crash recovery) — increment retry, return to pending |
| `test_fixing` | `_handle_test_fixing` | Tests failed — re-run test gate, spawn test fixer (up to 3 attempts) |
| `pr_open` | `_handle_pr_open` | Idle — reviewer cron handles this state |
| `reviewed` | `_handle_reviewed` | Reviews posted — clean-review skip or spawn fixer |
| `fixing` | `_handle_fixing` | Fixer process died (crash recovery) — increment retry, return to pending |
| `fixed` | `_handle_fixed` | Tests pass after fix — spawn merger for final review |
| `merging` | `_handle_merging` | Merger process died (crash recovery) — increment retry, return to pending |
| `merged` | `_handle_merged` | Record metrics, generate summary, advance to next task |
| `completed` | `_handle_completed` | All tasks done — resumes automatically if new tasks are appended to the task file |

### Valid Transitions

State transitions are enforced by a whitelist in `lib/state.sh`. The `update_status()` function rejects invalid transitions and logs an error. Valid transitions:

```
pending → implementing, completed
implementing → test_fixing, pr_open, pending
test_fixing → pr_open, pending
pr_open → reviewed, test_fixing
reviewed → fixing, fixed
fixing → fixed, reviewed, pending
fixed → merging, reviewed, test_fixing, pending
merging → merged, reviewed, pending
merged → pending, completed
completed → pending
```

`pr_open → test_fixing` is used when test failures are detected after the PR is created. `fixed → reviewed`, `fixed → test_fixing`, and `fixed → pending` are used when post-fix testing or merge conflicts send the task back to an earlier state. `merging → pending` is a full restart, used when the merger process dies repeatedly. `completed → pending` resumes the pipeline when new tasks are added to the task file (see below).

### Clean-Review Skip

When all reviewer personas return `NO_ISSUES_FOUND`, the pipeline skips the fixer agent:

```
reviewed → fixed  (instead of reviewed → fixing → fixed)
```

The dispatcher reads the `is_clean` flag in `reviewed.json`. If the flag is true for all reviewers, the dispatcher transitions directly from `reviewed` to `fixed`, which saves a full agent cycle (~15 minutes). This skip is common for well-scoped tasks that produce clean implementations.

### Auto-Resume from Completed

The `completed` state is not terminal. On each tick, `_handle_completed()` re-scans the tasks file and compares the current task number with the total task count. If new tasks have been added (`current_task <= total_tasks`), the pipeline transitions back to `pending` and starts the next task. You can append tasks to the task file at any time; the pipeline resumes on the next 15-second tick with no manual step.

### Draft PR and Incremental Pushes

Before the coder starts, the dispatcher pushes the task branch and opens a **draft PR** with `gh pr create --draft`, so tasks in progress are visible on GitHub. During implementation, a post-commit push hook (`autopilot-push-hook`) pushes each commit as it is made, so the PR stays current. After the coder finishes, `gh pr ready` marks the draft PR "ready for review".

All draft PR steps are best-effort: a failure does not stop the coder from running. If the push or the PR creation fails, the step is retried once after a 5-second delay.

### Background Test Gate

After the coder finishes, the test gate runs the project's test suite. The test gate can run in the background in a detached git worktree, so the tests run in parallel with the review cycle.

Exit codes from the test gate drive state transitions:

| Code | Constant | Meaning |
|------|----------|---------|
| 0 | `TESTGATE_PASS` | Tests pass — proceed to `pr_open` |
| 1 | `TESTGATE_FAIL` | Tests fail — transition to `test_fixing` |
| 2 | `TESTGATE_SKIP` | No test command detected — skip to `pr_open` |
| 3 | `TESTGATE_ALREADY_VERIFIED` | Stop hook SHA flags indicate tests already passed |
| 4 | `TESTGATE_ERROR` | Test gate internal error (e.g., command not on allowlist) — transitions to `test_fixing` |

When the coder's Stop hooks have already verified tests pass (SHA flag match), the test gate returns `TESTGATE_ALREADY_VERIFIED` and does not run the tests again.

---

## Coder Hooks

Autopilot installs lint and test Stop hooks into Claude's `settings.json` before spawning the coder or fixer agent. These hooks run after every edit, so the agent sees lint errors and test failures while it works.

### Hook Lifecycle

1. **Install** (`install_hooks()`): Before spawning the agent
   - Back up the current `settings.json` (only if no backup exists, so the clean backup survives a crash)
   - Build lint command (`make lint` if available, else `true`)
   - Build test command (`AUTOPILOT_TEST_CMD` or `make test` if available, else `true`)
   - Merge hook entries into `settings.json` via `jq`

2. **Active**: During agent execution
   - Claude runs hooks after each file edit
   - The agent sees the hook output and can correct its work
   - Hooks write SHA flags when tests pass (used by test gate to skip re-runs)

3. **Remove** (`remove_hooks()`): After agent finishes
   - Restore from backup (atomic `mv`) if backup exists
   - Otherwise, filter out `autopilot-*` hook entries via `jq`

### Hook Details

Two entries are added to `settings.json` under `hooks.stop`:

- `autopilot-lint-hook` — runs `make lint` (or `true` if unavailable)
- `autopilot-test-hook` — runs `AUTOPILOT_TEST_CMD` or `make test` (or `true`)

Hook commands use absolute project paths so they work regardless of Claude's working directory. The `description` field identifies autopilot hooks during removal.

The settings file is resolved from: `AUTOPILOT_CODER_CONFIG_DIR` > `CLAUDE_CONFIG_DIR` > `$HOME/.claude`.

---

## Crash Recovery and Retry Strategy

The scheduler-driven design provides crash recovery. If an agent process dies mid-execution, the next tick detects the stale state and recovers as described below.

### Recovery Points

**Coder crash** (`implementing` state on fresh tick):
- The dispatcher detects that no coder process is running
- Increments the retry counter
- Transitions back to `pending` for a retry (strategy depends on retry count — see below)
- After `AUTOPILOT_MAX_RETRIES` (default: 5) failures, runs a diagnosis agent and skips the task

**Fixer crash** (`fixing` state on fresh tick):
- Increments the retry counter
- Transitions back to `pending` for a retry (same retry/diagnosis logic as coder crash)

**Merger crash** (`merging` state on fresh tick):
- Increments the retry counter
- Transitions back to `pending` for a retry (same retry/diagnosis logic as coder crash)
- On REJECT verdict (not a crash), transitions to `reviewed` with diagnosis hints for the next fixer

### Three-Phase Coder Retry Strategy

The coder retry strategy preserves partial work on early retries and resets on later ones:

| Retry Count | Phase | Branch Handling | Agent Context |
|-------------|-------|-----------------|---------------|
| 0 (first attempt) | Initial | Delete any stale branch, create fresh from target | Base task prompt only |
| 1–2 | Phase A (preserve) | Check out existing branch, push unpushed commits | "Previous Attempt Context" — continue from existing commits |
| 3+ | Phase B (reset) | Delete stale branch, create fresh from target | "Previous Attempt Note" — avoid failed approaches |

**Phase A** (retries 1–2): The existing task branch is preserved. Any unpushed commits are pushed before the coder starts. The agent's prompt tells it to continue from the existing work on the branch.

**Phase B** (retries 3+): The task branch is deleted and recreated fresh from the target branch. The agent's prompt states how many previous attempts failed and tells it to avoid the approaches that failed. This stops the coder from repeating a failed approach.

### Retry Budget

Three separate retry counters prevent infinite loops:

| Counter | Default | Scope |
|---------|---------|-------|
| `retry_count` | 5 max | Full coder respawns per task |
| `test_fix_retries` | 3 max | Test fixer attempts before escalating |
| `network_retry_count` | <!-- fact:max-network-retries -->100<!-- /fact --> max | Network errors (does not consume task retry budget) |

When `retry_count` reaches the maximum:
1. A diagnosis agent (`prompts/diagnose.md`) analyzes the failure logs
2. Findings are written to `.autopilot/logs/diagnosis-task-N.md`
3. The task is skipped and the pipeline advances

When `test_fix_retries` is used up, `test_fixing` escalates to a full retry: the task returns to `pending` with a fresh coder, and `retry_count` is incremented.

When `network_retry_count` reaches `AUTOPILOT_MAX_NETWORK_RETRIES` (default <!-- fact:max-network-retries -->100<!-- /fact -->), the pipeline hard-pauses by writing the reason to `.autopilot/PAUSE` (e.g., `"Network retries exhausted (<count>/<max>) for task N"`). This stops the pipeline until the network issue is resolved and the PAUSE file is removed. Network retries never count against the task's `retry_count` budget. They are counted separately, so transient connectivity problems do not cause a task to be skipped.

### Diagnosis Hints

When the merger rejects a PR, its output explains why. That feedback is saved to `.autopilot/diagnosis-hints-task-N.md` and added to the next fixer prompt, so the fixer knows what the merger found wrong.

### Hook Recovery

If the dispatcher crashes between installing and removing hooks:
- The backup file (`settings.json.autopilot-backup`) persists
- On the next hook installation, the backup is preserved (not overwritten)
- On removal, the original backup is restored
- This ensures `settings.json` is never left in a corrupted state

---

## Lock and Concurrency Model

Autopilot uses PID-based filesystem locks to prevent concurrent execution. The dispatcher and reviewer each have their own lock, so they can run at the same time.

### Lock Files

| Lock | File | Owner |
|------|------|-------|
| Pipeline | `.autopilot/locks/pipeline.lock` | `autopilot-dispatch` |
| Review | `.autopilot/locks/review.lock` | `autopilot-review` |

Each lock file contains the PID of the owning process.

### Acquisition

Lock acquisition uses the shell's `noclobber` mode (`set -C`) for atomic file creation, which prevents TOCTOU races between concurrent ticks:

```bash
# Atomic creation — fails if file already exists
(set -C; echo "$$" > "$lock_file") 2>/dev/null
```

If the lock file already exists, the process checks whether it is stale before giving up.

### Stale Lock Detection

A lock is considered stale if either condition is true:

1. **Dead PID**: `ps -p $PID` fails (the owning process is gone)
2. **Aged out**: The lock file is older than `AUTOPILOT_STALE_LOCK_MINUTES`

By default, the stale lock threshold is **derived** from the longest configured agent timeout plus a 5-minute buffer. For example, with the default `AUTOPILOT_TIMEOUT_CODER=2700` (45 min), the threshold is 50 minutes. `_compute_stale_lock_minutes()` in `lib/config.sh` computes it. An explicit value in the config overrides it.

Stale locks are removed and re-acquired atomically. The re-acquisition is another `noclobber` write, so when two processes detect the same stale lock at the same time, only one of them acquires it.

### Release

Only the process that acquired the lock can release it. The lock PID is compared against `$$`:

```bash
if [[ "$lock_pid" = "$$" ]]; then
    rm -f "$lock_file"
fi
```

A cleanup trap (`trap ... EXIT`) ensures locks are released on exit, even on unexpected termination.

### Quick Guards and Soft Pause

Before they try to acquire the lock, which requires sourcing the libraries, entry points run quick guards that exit in under 10ms:

1. **PAUSE file check**: If `.autopilot/PAUSE` exists with content (hard pause), exit immediately. If the file exists but is empty (soft pause), set a flag and continue.
2. **Live PID check**: If the lock file exists and its PID is alive, exit immediately

On idle ticks, these guards skip library loading and config parsing.

**Soft pause** (`touch .autopilot/PAUSE`): The pipeline finishes its current phase (e.g., the coder run) and then stops. At each phase boundary, `check_soft_pause()` tests the flag and exits cleanly, so a running agent is not interrupted mid-work.

**Hard pause** (`echo "reason" > .autopilot/PAUSE`): The pipeline exits immediately on the next tick without starting any new work.

### Concurrency Between Dispatcher and Reviewer

The dispatcher holds `pipeline.lock` and the reviewer holds `review.lock`. They can run at the same time without contention. At most one dispatcher and one reviewer run at any time per project.

Claude API load: each tick spawns work only if the previous agent has finished, so at most two Claude processes run at the same time (one coder or fixer, one reviewer).

---

## Metrics and Logging

### CSV Metrics

Autopilot writes three CSV metrics files under `.autopilot/`:

**`metrics.csv`** — per-task completion tracking:
```
task_number,status,pr_number,start_time,end_time,duration_minutes,
retry_count,lines_added,lines_removed,comment_count,files_changed
```

A row is recorded when a task reaches the `merged` state. PR stats (lines added/removed, files changed, comment count) come from `gh pr view --json` on a best-effort basis; if that call fails, they are recorded as zero.

**`phase_timing.csv`** — per-phase duration breakdown:
```
task_number,pr_number,implementing_sec,test_fixing_sec,pr_open_sec,
reviewed_sec,fixing_sec,merging_sec,total_sec
```

Phase durations are summed in the `phase_durations` object in `state.json`. On each state transition, the time spent in the old phase is added to that phase's total. When the task completes, the totals are written as one CSV row.

**`token_usage.csv`** — per-agent token and cost tracking:
```
task_number,phase,input_tokens,output_tokens,cache_read_tokens,
cache_creation_tokens,cost_usd,wall_ms,api_ms,num_turns
```

Each row is parsed from Claude's JSON output after an agent invocation.

### CSV Schema Auto-Update

If the CSV header changes (e.g., a pipeline upgrade adds a column), the header is rewritten in place and the existing data rows are kept. This prevents schema mismatches when the pipeline changes.

### Timer Instrumentation

Sub-step timing uses `_timer_start()` and `_timer_log()` from `lib/timer.sh` for measuring coder build time, test duration, etc. `_timer_log` calls `timer_log()` in `lib/metrics.sh`. Timer events are logged at INFO level with a greppable `TIMER: <label> (<N>s)` format.

### Pipeline Log

All output goes to `.autopilot/logs/pipeline.log` via `log_msg()`. Format: ISO 8601 UTC timestamp, level (DEBUG/INFO/WARNING/ERROR), message.

**Log rotation**: When the log exceeds `AUTOPILOT_MAX_LOG_LINES` (default: 50000), it is truncated to the most recent lines.

---

## Prompts

Agent behavior is controlled by markdown prompt templates in the `prompts/` directory. Each prompt is loaded at runtime and combined with task-specific context.

### Prompt Files

| File | Agent | Purpose |
|------|-------|---------|
| `implement.md` | Coder | Implement a task on a feature branch |
| `fix-tests.md` | Test fixer | Fix failing tests after initial implementation |
| `fix-and-merge.md` | Fixer | Address review feedback and push fixes |
| `merge-review.md` | Merger | Final review — output `VERDICT: APPROVE` or `VERDICT: REJECT` |
| `diagnose.md` | Diagnostician | Analyze repeated failures and document findings |
| `summarize.md` | Summarizer | Generate concise summary of completed task |
| `spec-compliance.md` | Spec reviewer | Check merged PRs against project specification |

### Prompt Construction

The coder prompt is assembled from multiple sources:

1. **Base template** — `prompts/implement.md` (instructions, constraints, conventions)
2. **`project.md`** — auto-injected if present in the project root (high-level project context)
3. **Reference documents** — files listed in `AUTOPILOT_CONTEXT_FILES` (spec, API docs, etc.)
4. **Task body** — the full task section from the tasks file (heading + description)
5. **Completed summaries** — prior task summaries from `.autopilot/completed-summary.md`
6. **Branch naming** — reminder to use `${AUTOPILOT_BRANCH_PREFIX}/task-N`

The fixer prompt similarly includes the review comments fetched from GitHub, plus any diagnosis hints from previous merger rejections.

### Agent Invocation

All agents are spawned through `lib/claude.sh`, which provides:

- `build_claude_cmd()` — constructs the full command from config (binary, flags, output format, optional config dir)
- `run_claude()` — timeout wrapper with `unset CLAUDECODE` isolation (prevents session reuse bugs)
- `extract_claude_text()` — parses Claude's JSON output to extract the `.result` text field

Every invocation runs `unset CLAUDECODE` before launching, so the new process does not attach to an existing session.

---

## Reviewer Personas

The review system runs multiple specialized reviewers in parallel against each PR diff. Each reviewer is defined by a markdown persona file in the `reviewers/` directory.

### Built-in Personas

| Persona | File | Focus |
|---------|------|-------|
| **general** | `reviewers/general.md` | Correctness, clarity, error handling, naming, API contracts, edge cases |
| **dry** | `reviewers/dry.md` | Code duplication, missed abstractions, magic values |
| **performance** | `reviewers/performance.md` | Algorithmic complexity, resource leaks, redundant I/O |
| **security** | `reviewers/security.md` | Injection attacks, auth issues, secrets exposure, input validation |
| **design** | `reviewers/design.md` | Contract drift, dead parameters, broken math, validation gaps |

The design reviewer was added because the other four personas missed issues of meaning and intent: contract drift between documentation and code, dead parameters, broken math at boundaries, and validation gaps.

### Review Execution

1. **Fetch diff**: `gh pr diff` with metadata header, guarded by `AUTOPILOT_MAX_DIFF_BYTES` (default: <!-- fact:max-diff-kb -->500<!-- /fact --> KB)
2. **Spawn reviewers**: For each persona in `AUTOPILOT_REVIEWERS`, Claude is spawned in the background with the persona prompt. In print mode (default), the diff is piped via stdin. In interactive mode, the diff is embedded in the prompt and the reviewer has full tool access to explore the repository.
3. **Collect results**: Wait for all background processes, gather output from temp files
4. **Post comments**: Format and post via `gh pr comment` with reviewer display name and SHA tag
5. **Dedup tracking**: Record the reviewed head SHA in `.autopilot/reviewed.json` to prevent re-reviewing unchanged code

### Interactive vs. Print Mode

Reviewers run in one of two modes, set by `AUTOPILOT_REVIEWER_INTERACTIVE` (global) and per-persona YAML frontmatter (`interactive: true`). A per-persona setting overrides the global one. Interactive reviewers use a separate timeout (`AUTOPILOT_TIMEOUT_REVIEWER_INTERACTIVE`), because exploring the codebase takes longer. See [configuration.md — Interactive Reviewer Mode](configuration.md#interactive-reviewer-mode) for setup details.

### Always-Post Behavior

Every reviewer posts a comment on the PR, even when it finds no issues. A clean review posts "No issues found." instead of posting nothing. The PR then records which reviewers ran and what each one found.

### Clean-Review Detection

After all reviewers finish, the posting logic checks whether every reviewer returned the `NO_ISSUES_FOUND` sentinel. If so, `reviewed.json` is updated with `is_clean: true`, which the dispatcher reads to skip the fixer.

### Comment Dedup

The `reviewed.json` file tracks which PRs have been reviewed and at which commit SHA. If the head SHA hasn't changed since the last review, the review cycle is skipped entirely.

---

## Extending with Custom Reviewers

Add a custom persona in two steps:

1. Create a markdown file `reviewers/<name>.md` with the system prompt, where `<name>` is the persona name (e.g., `accessibility`)
2. Add the name (without `.md`) to `AUTOPILOT_REVIEWERS` in your config

Custom personas must follow these conventions:

- **Output format**: Numbered list of issues with file references when issues are found
- **Clean sentinel**: Respond with exactly `NO_ISSUES_FOUND` when no issues are detected; the clean-review skip depends on it
- **Scope**: Focus on a specific aspect of code quality to avoid overlap with built-in personas
- **Actionability**: Provide concrete fix suggestions, not just observations

To run a subset of reviewers, list only those in `AUTOPILOT_REVIEWERS`. A persona file in `reviewers/` runs only when its name is listed.

See [configuration.md](configuration.md#custom-reviewers) for complete examples.

---

## Fixer Diagnostics and Fail-Fast

When the fixer agent exits with a non-zero code and produces no commits, the pipeline skips the expensive postfix verification step (fail-fast). It posts a result comment on the PR, increments the retry counter, and then retries or escalates to diagnosis.

Before the fixer is spawned, `lib/fixer-diagnostics.sh` checks the prompt and config. After the fixer exits, the same script logs the exit code, output size and JSON validity, and keeps stderr when the output is empty. An optional retry delay (`AUTOPILOT_FIXER_RETRY_DELAY`, default: 30s) prevents back-to-back retries when a failure persists.

---

## Network Error Handling

`lib/network-errors.sh` detects transient network errors (DNS failures, connection timeouts, HTTP 502, etc.) by matching patterns in the failure output. A network error does not increment the retry counter, so transient connectivity problems do not use up the task's retry budget.

A network error is retried up to `AUTOPILOT_MAX_NETWORK_RETRIES` times (default: <!-- fact:max-network-retries -->100<!-- /fact -->) before the failure is treated as permanent.

---

## Test Output in Fixer Prompts

When the test gate fails, the full test output is saved to `.autopilot/logs/test-output-task-N.txt` via `lib/test-output.sh`. The fixer and test fixer receive this output in their prompts, so they see what failed. Output longer than `AUTOPILOT_MAX_TEST_OUTPUT` lines (default: 500) is truncated, and a truncation sentinel marks the omitted content.

---

## Test Summary in PR Comments

`lib/test-summary.sh` parses test output from multiple frameworks (bats TAP format, pytest, or generic pass/fail patterns) and generates one-line summaries such as:

- `Tests: 1851 total, 1851 passed, 0 failed (312s)`
- `Tests: 822/1851 ran, killed by timeout after 300s`

These summaries are included in PR comments posted by `lib/pr-comments.sh` after test gate failures and fixer completions. Timeout kills (exit codes 124/137 from the `timeout` command) are detected and reported as timeouts.

---

## Reviewer Output Persistence

After each reviewer agent completes, `lib/review-runner.sh` saves the agent's JSON output to `.autopilot/logs/reviewer-{persona}-task-{N}.json`. The performance summary PR comment reads these files for its "Review" row. That row was missing before, because reviewer output files were not saved. The file names follow the pattern that `_aggregate_reviewer_data()` in `lib/perf-summary.sh` expects.

---

## PR Status Comments

`lib/pr-comments.sh` posts short status comments on PRs after pipeline events such as test gate failures and fixer completions, so anyone watching the PR on GitHub sees pipeline activity.

---

## Rebase and Conflict Detection

`lib/rebase.sh` detects merge conflicts before the merge, by checking the `mergeable` status from `gh pr view`. It also rebases task branches onto the target branch after squash merges. So when a PR has merge conflicts, the pipeline finds them before it attempts the merge and can take corrective action.

---

## Two-Phase Test Runner

`lib/twophase.sh` runs bats tests in two phases, so failures show up sooner:

1. **Phase 1**: Run previously-failed tests first for fast rejection (~5 seconds)
2. **Phase 2**: Run the full test suite to catch regressions

Failed test file paths are tracked between runs via `.autopilot/.last-failed-tests`. This module can be sourced as a library or executed as a standalone script.

---

## Async Spec Review

`lib/spec-review-async.sh` runs spec compliance reviews in the background and tracks them with a PID file, so a long spec review (up to 20 minutes) does not block the dispatcher. On later ticks, the dispatcher calls `check_spec_review_completion()` to see whether the review has finished.

---

## Worktree Lifecycle

When `AUTOPILOT_USE_WORKTREES` is `true` (the default), each task runs in an isolated git worktree at `.autopilot/worktrees/task-N/`. This keeps the user's working tree clean and allows concurrent agent work.

### Creation

During the `pending` handler (before transitioning to `implementing`):

1. `create_task_branch()` in `lib/git-ops.sh` creates the worktree via `git worktree add .autopilot/worktrees/task-N -b autopilot/task-N`
2. `install_worktree_deps()` in `lib/worktree-deps.sh` auto-detects and installs project dependencies (Node.js, Python, Ruby, Go, plus custom `AUTOPILOT_WORKTREE_SETUP_CMD`). See [configuration.md — Worktree Dependency Installation](configuration.md#worktree-dependency-installation) for the full detection table.
3. If setup fails and `AUTOPILOT_WORKTREE_SETUP_OPTIONAL` is `false` (default), the task fails. If `true`, a warning is logged and the pipeline continues.

### During Execution

The coder, fixer, and test-fixer agents all run inside the worktree directory. Claude's `settings.json` hooks use absolute paths so they work regardless of working directory.

### Cleanup

`lib/worktree-cleanup.sh` removes worktrees at four points:

- **After merge**: The worktree for the completed task is removed
- **On retry exhaustion**: The worktree is removed when the task is skipped after max retries
- **Before restart**: When a task transitions back to `pending` (e.g., `merging → pending`), the existing worktree is removed so `git worktree add` can recreate it on the next attempt
- **Stale detection**: Worktrees that no longer correspond to active tasks are removed

### Symlink Safety

Relative symlinks that point outside the repository break in a git worktree. Autopilot detects these escaping symlinks at three points:
1. `autopilot-init` — scans tracked files and auto-sets `AUTOPILOT_USE_WORKTREES=false`
2. `autopilot-doctor` — prints a `[WARN]` if escaping symlinks are found
3. Runtime (`create_task_branch`) — falls back to direct checkout if escaping symlinks are detected

---

## Agent Roster

Autopilot spawns six types of Claude Code agents, each with a dedicated prompt and role:

| Agent | Prompt | Config Dir | Purpose |
|-------|--------|------------|---------|
| **Coder** | `prompts/implement.md` | `AUTOPILOT_CODER_CONFIG_DIR` | Implements a task on a feature branch |
| **Test Fixer** | `prompts/fix-tests.md` | `AUTOPILOT_CODER_CONFIG_DIR` | Fixes failing tests after initial implementation |
| **Fixer** | `prompts/fix-and-merge.md` | `AUTOPILOT_CODER_CONFIG_DIR` | Addresses review feedback and pushes fixes |
| **Reviewer** | `reviewers/*.md` | `AUTOPILOT_REVIEWER_CONFIG_DIR` | Posts code review comments (5 personas in parallel) |
| **Merger** | `prompts/merge-review.md` | `AUTOPILOT_REVIEWER_CONFIG_DIR` | Final review — APPROVE or REJECT verdict, squash-merge on approval |
| **Diagnostician** | `prompts/diagnose.md` | System default | Analyzes repeated failures and documents findings |

Two additional agents run in the background and use the system default Claude configuration:

| Agent | Prompt | Purpose |
|-------|--------|---------|
| **Summarizer** | `prompts/summarize.md` | Generates concise summary of a completed task for coder context |
| **Spec Reviewer** | `prompts/spec-compliance.md` | Periodically checks merged PRs against the project specification |

An optional non-Claude reviewer is also available:

| Agent | Config | Purpose |
|-------|--------|---------|
| **Codex Reviewer** | `AUTOPILOT_CODEX_MODEL` | Runs OpenAI Codex for review diversity (requires `codex` CLI) |

---

## Setup Commands

Three commands set up and validate a project:

### `autopilot-init`

Interactive setup wizard that scaffolds a project for the pipeline. It is idempotent: a re-run skips existing files. Steps:

1. Check prerequisites (claude, gh, jq, git, timeout)
2. Initialize git repo and GitHub remote if missing
3. Verify `gh auth status`
4. Scaffold `tasks.md` with example tasks
5. Generate `autopilot.conf` with `--dangerously-skip-permissions`
6. Scaffold `CLAUDE.md` from template (see below)
7. Create/update `.gitignore` with `.autopilot/`
8. Detect multi-account directories
9. Install launchd scheduling (macOS) or print cron instructions
10. Create `.autopilot/PAUSE` (starts in paused state)

### `autopilot-doctor`

Non-interactive validation that runs 11 checks and reports pass/fail:

1. Prerequisites on PATH
2. GitHub CLI authentication
3. Config file parseable
4. Tasks file detection (warns on ambiguity)
5. `.gitignore` contains `.autopilot/`
6. GitHub remote reachable
7. `--dangerously-skip-permissions` in flags
8. Worktree symlink compatibility (warns if escaping symlinks found)
9. Codex reviewer setup (if `codex` is in reviewer list)
10. Account directory detection
11. Claude API smoke test (verifies connectivity per account)

Exits 0 if all pass, 1 if any fail. Each failure includes a fix instruction.

### `autopilot-start`

Runs `autopilot-doctor` first. If all checks pass and the pipeline is paused, removes `.autopilot/PAUSE`. It is safe to run more than once: it exits cleanly if the pipeline is already running.

---

## CLAUDE.md Scaffolding

`autopilot-init` scaffolds a default `CLAUDE.md` for projects that lack adequate agent instructions. It decides as follows:

1. If a local `CLAUDE.md` exists with more than 10 lines, skip (considered adequate)
2. If no local `CLAUDE.md` but a global `~/.claude/CLAUDE.md` exists with more than 10 lines, skip
3. Otherwise, copy `examples/CLAUDE.example.md` to the project root

The template covers: commit discipline, testing practices, file hygiene limits, error handling, and a "Project Details" section with placeholder fields (language, framework, test/lint/build commands) for the user to fill in.

---

## Performance Summary

After a task is merged, `lib/perf-summary.sh` posts a performance summary as a PR comment. The summary is a markdown table showing per-phase metrics:

| Column | Description |
|--------|-------------|
| Phase | Coder, Test gate, Fixer, Review, Merger |
| Wall | Wall-clock time (human-readable) |
| API | API processing time |
| Turns | Number of agent turns |
| Tokens In/Out | Input and output token counts |
| Cache Read/Create | Cache token usage |
| Retries | Retry count for the phase |
| Cost | Estimated cost in USD |

The data comes from the agents' JSON output files and `phase_timing.csv`.

---

## Prompt Size Logging

After each coder and fixer invocation, the pipeline logs the prompt size in bytes and estimated token count (~1 token per 4 bytes). The log shows which tasks have unexpectedly large prompts, which might exceed the context window or raise costs.

---

## Key Implementation Files

### Entry Points (`bin/`)

| File | Responsibility |
|------|---------------|
| `bin/autopilot-dispatch` | Dispatcher entry point — quick guards, bootstrap, state machine |
| `bin/autopilot-review` | Reviewer entry point — cron mode and standalone mode |
| `bin/autopilot-init` | Interactive setup wizard — scaffolds config, tasks, CLAUDE.md |
| `bin/autopilot-doctor` | Non-interactive validation — 11 checks with fix instructions |
| `bin/autopilot-start` | Validate and start — runs doctor, removes PAUSE file |
| `bin/autopilot-schedule` | launchd plist generation, install, and uninstall |
| `bin/autopilot-status` | Pipeline health checker — shows state, tasks, scheduling readiness |
| `bin/autopilot-live-test` | Live test runner — `run`, `status`, `clean` subcommands |

### Libraries (`lib/`)

| File | Responsibility |
|------|---------------|
| `lib/claude.sh` | Claude invocation helpers (build command, run, extract output) |
| `lib/coder.sh` | Spawn coder agent with prompt construction and context |
| `lib/codex-reviewer.sh` | Codex reviewer backend — runs OpenAI Codex, parses JSON findings, posts inline PR comments |
| `lib/config.sh` | Config loading with precedence (env > file > default) |
| `lib/context.sh` | Task summary accumulation for coder context |
| `lib/detect.sh` | Test framework and lint tool auto-detection (shared by testgate and hooks) |
| `lib/diagnose.sh` | Failure diagnosis agent on max retries |
| `lib/discussion.sh` | PR discussion fetching and truncation for merger and fixer agents |
| `lib/dispatch-handlers.sh` | Individual state handler implementations |
| `lib/dispatch-helpers.sh` | Terminal state helpers, retry/diagnosis logic, PR creation |
| `lib/dispatcher.sh` | State machine definition and dispatch function |
| `lib/entry-common.sh` | Shared quick guards and bootstrap for both entry points |
| `lib/fixer.sh` | Spawn fixer agent for review feedback |
| `lib/fixer-diagnostics.sh` | Pre-spawn health checks, empty output detection, stderr preservation |
| `lib/git-ops.sh` | Git branch, commit, and push operations |
| `lib/git-pr.sh` | PR title/body extraction, creation, and detection |
| `lib/hooks.sh` | Coder lint/test Stop hook installation and removal |
| `lib/live-test.sh` | Scaffold minimal Python test project for live tests |
| `lib/live-test-report.sh` | Live test result validation and markdown report generation |
| `lib/live-test-run.sh` | Live test orchestration — background dispatch/review lifecycle |
| `lib/live-test-status.sh` | Live test progress and status display |
| `lib/merger.sh` | Final merge review and squash-merge |
| `lib/metrics.sh` | CSV metrics, phase timing, token usage tracking |
| `lib/network-errors.sh` | Transient network error detection, so network errors do not use up the retry budget |
| `lib/perf-summary.sh` | Post-merge performance summary PR comment |
| `lib/postfix.sh` | Post-fix test verification and fixer push checks |
| `lib/pr-comments.sh` | PR status comments for test failures and fixer completions |
| `lib/preflight.sh` | Pre-coder sanity checks (dependencies, git, auth) |
| `lib/rebase.sh` | Pre-merge conflict detection and auto-rebase of task branches |
| `lib/review-runner.sh` | Review cycle orchestration (cron and standalone modes) |
| `lib/reviewer-posting.sh` | Comment posting, dedup, clean-review detection |
| `lib/reviewer.sh` | Diff fetching and parallel reviewer execution |
| `lib/session-cache.sh` | Session pre-warming with content-hash memoization |
| `lib/spec-review-async.sh` | Background async execution for spec compliance review |
| `lib/spec-review.sh` | Periodic spec compliance checks against project specification |
| `lib/state.sh` | Atomic state I/O, lock management, logging, counters |
| `lib/tasks.sh` | Task file detection and parsing (both heading formats) |
| `lib/test-output.sh` | Per-task test output save/read/truncation for fixer prompts |
| `lib/test-parsers.sh` | Framework-specific test output parsers (bats, pytest, Jest, RSpec, Go, Cargo, JUnit) |
| `lib/test-summary.sh` | Orchestrate test output parsing and generate one-line summaries |
| `lib/testgate.sh` | Test suite execution with framework auto-detection |
| `lib/timer.sh` | Sub-step timing instrumentation with greppable TIMER log lines |
| `lib/twophase.sh` | Two-phase bats test runner (failed-first, then full suite) |
| `lib/worktree-cleanup.sh` | Worktree cleanup after merge, retry exhaustion, and stale detection |
| `lib/worktree-deps.sh` | Worktree dependency detection and installation (Node, Python, Ruby, Go) |
