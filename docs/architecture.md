# Architecture

How Autopilot's internals work: the state machine, concurrency model, crash recovery, agent hooks, metrics, prompts, and reviewer personas.

## Overview

Autopilot is a cron-driven pipeline with two entry points:

- **`autopilot-dispatch`** — drives the state machine (implements, tests, fixes, merges)
- **`autopilot-review`** — detects `pr_open` state and runs code reviews

Both run every 15 seconds via cron. Each tick checks quick guards (PAUSE file, live lock PID) and exits in under 10ms when idle. When work is needed, the tick acquires a lock, performs one state transition, and exits.

All coordination happens through filesystem state (`.autopilot/state.json`) and GitHub PRs. There is no daemon, no message queue, and no database — just files, locks, and cron.

---

## State Machine

The dispatcher implements a 10-state finite state machine. Each cron tick reads the current state, runs the corresponding handler, and transitions to the next state.

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
| `fixing` | `_handle_fixing` | Fixer process died (crash recovery) — increment retry, return to reviewed |
| `fixed` | `_handle_fixed` | Tests pass after fix — spawn merger for final review |
| `merging` | `_handle_merging` | Merger process died (crash recovery) — return to reviewed |
| `merged` | `_handle_merged` | Record metrics, generate summary, advance to next task |
| `completed` | `_handle_completed` | All tasks done — exit cleanly (terminal state) |

### Valid Transitions

State transitions are enforced by a whitelist in `lib/state.sh`. The `update_status()` function rejects invalid transitions and logs an error. Valid transitions:

```
pending → implementing, completed
implementing → test_fixing, pr_open, pending
test_fixing → pr_open, pending
pr_open → reviewed
reviewed → fixing, fixed
fixing → fixed, reviewed, pending
fixed → merging
merging → merged, reviewed
merged → pending, completed
```

### Clean-Review Skip

When all reviewer personas return `NO_ISSUES_FOUND`, the pipeline skips the fixer agent entirely:

```
reviewed → fixed  (instead of reviewed → fixing → fixed)
```

The dispatcher checks `reviewed.json` for an `is_clean` flag. If true across all reviewers, it transitions directly from `reviewed` to `fixed`, saving a full agent cycle (~15 minutes). This optimization is common for well-scoped tasks that produce clean implementations.

### Background Test Gate

After the coder finishes, the test gate runs the project's test suite to verify the implementation. The test gate supports background execution in a detached git worktree, allowing tests to run in parallel with the review cycle.

Exit codes from the test gate drive state transitions:

| Code | Constant | Meaning |
|------|----------|---------|
| 0 | `TESTGATE_PASS` | Tests pass — proceed to `pr_open` |
| 1 | `TESTGATE_FAIL` | Tests fail — transition to `test_fixing` |
| 2 | `TESTGATE_SKIP` | No test command detected — skip to `pr_open` |
| 3 | `TESTGATE_ALREADY_VERIFIED` | Stop hook SHA flags indicate tests already passed |

When the coder's Stop hooks have already verified tests pass (SHA flag match), the test gate returns `TESTGATE_ALREADY_VERIFIED` and skips redundant re-execution.

---

## Coder Hooks

Autopilot installs lint and test Stop hooks into Claude's `settings.json` before spawning the coder or fixer agent. These hooks run automatically after every edit, giving the agent real-time feedback on lint errors and test failures.

### Hook Lifecycle

1. **Install** (`install_hooks()`): Before spawning the agent
   - Back up the current `settings.json` (only if no backup exists — preserves clean backup across crashes)
   - Build lint command (`make lint` if available, else `true`)
   - Build test command (`AUTOPILOT_TEST_CMD` or `make test` if available, else `true`)
   - Merge hook entries into `settings.json` via `jq`

2. **Active**: During agent execution
   - Claude runs hooks after each file edit
   - Hook output is visible to the agent for self-correction
   - Hooks write SHA flags when tests pass (used by test gate to skip re-runs)

3. **Remove** (`remove_hooks()`): After agent finishes
   - Restore from backup (atomic `mv`) if backup exists
   - Otherwise, filter out `autopilot-*` hook entries via `jq`

### Hook Entries

Two hooks are installed in `settings.json`:

```json
{
  "hooks": {
    "stop": [
      {
        "command": "cd '/path/to/project' && make lint 2>&1",
        "description": "autopilot-lint-hook"
      },
      {
        "command": "cd '/path/to/project' && make test 2>&1",
        "description": "autopilot-test-hook"
      }
    ]
  }
}
```

Hook commands use absolute project paths, so they work regardless of Claude's working directory. The `description` field is used for identification during removal.

### Settings File Resolution

The settings file location is resolved in order:

1. Explicit `config_dir` parameter (from `AUTOPILOT_CODER_CONFIG_DIR`)
2. `CLAUDE_CONFIG_DIR` environment variable
3. `$HOME/.claude` (default)

---

## Crash Recovery

The cron-driven architecture provides natural crash recovery. If an agent process dies mid-execution, the next cron tick detects the stale state and takes corrective action.

### Recovery Points

**Coder crash** (`implementing` state on fresh tick):
- The dispatcher detects that no coder process is running
- Increments the retry counter
- Transitions back to `pending` for a fresh coder run
- After `AUTOPILOT_MAX_RETRIES` (default: 5) failures, runs a diagnosis agent and skips the task

**Fixer crash** (`fixing` state on fresh tick):
- Increments the retry counter
- Transitions back to `reviewed` to re-evaluate and retry the fixer

**Merger crash** (`merging` state on fresh tick):
- Increments the retry counter
- Transitions back to `reviewed` for another attempt

### Retry Budget

Two separate retry counters prevent infinite loops:

| Counter | Default | Scope |
|---------|---------|-------|
| `retry_count` | 5 max | Full coder respawns per task |
| `test_fix_retries` | 3 max | Test fixer attempts before escalating |

When `retry_count` reaches the maximum:
1. A diagnosis agent (`prompts/diagnose.md`) analyzes the failure logs
2. Findings are written to `.autopilot/diagnosis-task-N.md`
3. The task is skipped and the pipeline advances

When `test_fix_retries` is exhausted, the test-fixing state escalates to a full retry (back to `pending` with a fresh coder), incrementing `retry_count`.

### Diagnosis Hints

When the merger rejects a PR, it provides feedback explaining why. These hints are saved to `.autopilot/diagnosis-hints-task-N.md` and injected into the next fixer prompt, so the fixer has context about what the merger found wrong.

### Hook Recovery

If the dispatcher crashes between installing and removing hooks:
- The backup file (`settings.json.autopilot-backup`) persists
- On the next hook installation, the backup is preserved (not overwritten)
- On removal, the original backup is restored
- This ensures `settings.json` is never left in a corrupted state

---

## Lock and Concurrency Model

Autopilot uses PID-based filesystem locks to prevent concurrent execution. The dispatcher and reviewer each have their own lock, allowing them to run independently.

### Lock Files

| Lock | File | Owner |
|------|------|-------|
| Pipeline | `.autopilot/locks/pipeline.lock` | `autopilot-dispatch` |
| Review | `.autopilot/locks/review.lock` | `autopilot-review` |

Each lock file contains the PID of the owning process.

### Acquisition

Lock acquisition uses the shell's `noclobber` mode (`set -C`) for atomic file creation, preventing TOCTOU race conditions between concurrent cron ticks:

```bash
# Atomic creation — fails if file already exists
(set -C; echo "$$" > "$lock_file") 2>/dev/null
```

If the lock file already exists, the process checks whether it is stale before giving up.

### Stale Lock Detection

A lock is considered stale if either condition is true:

1. **Dead PID**: `ps -p $PID` fails (the owning process is gone)
2. **Aged out**: The lock file is older than `AUTOPILOT_STALE_LOCK_MINUTES` (default: 45 minutes)

Stale locks are removed and re-acquired atomically. The re-acquisition uses another `noclobber` write to handle the race where two processes detect the same stale lock simultaneously — only one wins.

### Release

Only the process that acquired the lock can release it. The lock PID is compared against `$$`:

```bash
if [[ "$lock_pid" = "$$" ]]; then
    rm -f "$lock_file"
fi
```

A cleanup trap (`trap ... EXIT`) ensures locks are released on exit, even on unexpected termination.

### Quick Guards

Before attempting lock acquisition (which requires sourcing libraries), entry points run lightweight quick guards that exit in under 10ms:

1. **PAUSE file check**: If `.autopilot/PAUSE` exists, exit immediately
2. **Live PID check**: If the lock file exists and its PID is alive, exit immediately

These guards prevent unnecessary library loading and config parsing on idle ticks.

### Concurrency Between Dispatcher and Reviewer

The dispatcher holds `pipeline.lock` and the reviewer holds `review.lock`. They can run simultaneously without contention. However, at most one dispatcher and one reviewer run at any time per project.

For Claude API capacity: since each cron tick only spawns work if the previous agent finished, natural serialization means at most two Claude processes run simultaneously (one coder/fixer, one reviewer).

---

## Metrics and Logging

### CSV Metrics

Autopilot tracks three categories of metrics in CSV files under `.autopilot/`:

**`metrics.csv`** — per-task completion tracking:
```
task_number,status,pr_number,start_time,end_time,duration_minutes,
retry_count,lines_added,lines_removed,comment_count,files_changed
```

Recorded when a task reaches the `merged` state. PR stats (lines added/removed, files changed, comment count) are fetched via `gh pr view --json` on a best-effort basis — failures produce zero values.

**`phase_timing.csv`** — per-phase duration breakdown:
```
task_number,pr_number,implementing_sec,test_fixing_sec,pr_open_sec,
reviewed_sec,fixing_sec,merging_sec,total_sec
```

Phase durations are accumulated in `state.json` under a `phase_durations` object. On each state transition, the elapsed time in the old phase is added to its accumulator. At task completion, accumulated durations are written as a CSV row.

**`token_usage.csv`** — per-agent token and cost tracking:
```
task_number,phase,input_tokens,output_tokens,cache_read_tokens,
cache_creation_tokens,cost_usd,wall_ms,api_ms,num_turns
```

Parsed from Claude's JSON output after each agent invocation. Tracks input/output tokens, cache usage, cost, wall time, API time, and turn count.

### CSV Schema Auto-Update

If the CSV header changes (e.g., a new column is added in a pipeline upgrade), the header is updated in-place while preserving existing data rows. This prevents schema mismatches when the pipeline evolves.

### Timer Instrumentation

Sub-step timing uses `timer_start()` and `timer_log()` functions:

```bash
local start_time
start_time="$(timer_start)"
# ... do work ...
timer_log "$project_dir" "coder_build" "$start_time"
```

Timer events are logged at INFO level with the label and elapsed seconds.

### Pipeline Log

All log output goes to `.autopilot/logs/pipeline.log` via the `log_msg()` function:

```
2026-03-06T14:23:01Z INFO  Task 5: spawning coder agent
2026-03-06T14:23:45Z WARNING  Stale lock removed (pid=12345)
2026-03-06T15:10:02Z ERROR  Coder failed: exit code 1
```

Format: ISO 8601 UTC timestamp, level, message.

**Log rotation**: When the log exceeds `AUTOPILOT_MAX_LOG_LINES` (default: 1000), it is truncated to the most recent 500 lines. This prevents unbounded growth while preserving recent history.

**Log levels**:

| Level | Usage |
|-------|-------|
| `DEBUG` | Detailed internal state (e.g., config values, file paths) |
| `INFO` | Normal operations (e.g., state transitions, agent spawns) |
| `WARNING` | Recoverable issues (e.g., stale locks, missing optional files) |
| `ERROR` | Failures requiring attention (e.g., agent crash, lock failure) |

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
2. **Reference documents** — files listed in `AUTOPILOT_CONTEXT_FILES` (spec, API docs, etc.)
3. **Task body** — the full task section from the tasks file (heading + description)
4. **Completed summaries** — prior task summaries from `.autopilot/completed-summary.md`
5. **Branch naming** — reminder to use `${AUTOPILOT_BRANCH_PREFIX}/task-N`

The fixer prompt similarly includes the review comments fetched from GitHub, plus any diagnosis hints from previous merger rejections.

### Agent Invocation

All agent spawns go through `lib/claude.sh` which provides:

- `build_claude_cmd()` — constructs the full command from config (binary, flags, output format, optional config dir)
- `run_claude()` — timeout wrapper with `unset CLAUDECODE` isolation (prevents session reuse bugs)
- `extract_claude_text()` — parses Claude's JSON output to extract the `.result` text field

Every invocation uses `unset CLAUDECODE` before launching to prevent the new process from attaching to an existing session.

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

The design reviewer was added after discovering that the other four personas missed semantic/intent issues — specifically contract drift between documentation and code, dead parameters, broken math at boundaries, and validation gaps.

### Review Execution

1. **Fetch diff**: `gh pr diff` with metadata header, guarded by `AUTOPILOT_MAX_DIFF_BYTES` (default: 500 KB)
2. **Spawn reviewers**: For each persona in `AUTOPILOT_REVIEWERS`, Claude is spawned in the background with the persona prompt and diff piped via stdin
3. **Collect results**: Wait for all background processes, gather output from temp files
4. **Post comments**: Format and post via `gh pr comment` with reviewer display name and SHA tag
5. **Dedup tracking**: Record the reviewed head SHA in `.autopilot/reviewed.json` to prevent re-reviewing unchanged code

### Clean-Review Detection

After all reviewers finish, the posting logic checks whether every reviewer returned the `NO_ISSUES_FOUND` sentinel. If so, `reviewed.json` is updated with `is_clean: true`, which the dispatcher reads to skip the fixer.

### Comment Dedup

The `reviewed.json` file tracks which PRs have been reviewed and at which commit SHA. If the head SHA hasn't changed since the last review, the review cycle is skipped entirely.

---

## Extending with Custom Reviewers

### Adding a Persona

1. Create a markdown file in `reviewers/` with the reviewer's system prompt:

```markdown
# reviewers/accessibility.md

You are a senior accessibility reviewer. Review the following PR diff for:

1. Missing ARIA attributes on interactive elements
2. Images without alt text
3. Color contrast issues in CSS changes
4. Missing keyboard navigation support

For each issue, provide the file, location, problem, and fix.

If you find no accessibility issues, respond with exactly: NO_ISSUES_FOUND
```

2. Add the persona name to your config:

```bash
AUTOPILOT_REVIEWERS="general,dry,performance,security,design,accessibility"
```

The name must match the filename without the `.md` extension.

### Persona Requirements

Custom personas should follow these conventions:

- **Output format**: Numbered list of issues with file references when issues are found
- **Clean sentinel**: Respond with exactly `NO_ISSUES_FOUND` when no issues are detected — this enables the clean-review skip optimization
- **Scope**: Focus on a specific aspect of code quality to avoid overlap with built-in personas
- **Actionability**: Provide concrete fix suggestions, not just observations

### Removing or Disabling Personas

To run a subset of reviewers, list only the ones you want:

```bash
# Run only security and general reviews
AUTOPILOT_REVIEWERS="general,security"
```

Persona files remain in the `reviewers/` directory but are only invoked if listed in `AUTOPILOT_REVIEWERS`.

---

## PAUSE Mechanism

Both entry points check for `.autopilot/PAUSE` before doing any work:

```bash
touch /path/to/project/.autopilot/PAUSE   # Pause
rm /path/to/project/.autopilot/PAUSE      # Resume
```

The check happens as a quick guard before library loading, so paused ticks exit in under 10ms. No crontab editing is required.

---

## Session Isolation

All agent spawns execute `unset CLAUDECODE` before launching Claude. This prevents the `CLAUDECODE` environment variable from causing the new process to attach to an existing Claude Code session instead of starting fresh. This is a critical workaround — without it, agents can interfere with each other or with interactive Claude sessions.

---

## Key Implementation Files

| File | Responsibility |
|------|---------------|
| `bin/autopilot-dispatch` | Dispatcher entry point — quick guards, bootstrap, state machine loop |
| `bin/autopilot-review` | Reviewer entry point — cron mode and standalone mode |
| `lib/dispatcher.sh` | State machine definition and dispatch function |
| `lib/dispatch-handlers.sh` | Individual state handler implementations |
| `lib/dispatch-helpers.sh` | Terminal state helpers, retry/diagnosis logic |
| `lib/state.sh` | Atomic state I/O, lock management, logging, counters |
| `lib/entry-common.sh` | Shared quick guards and bootstrap for both entry points |
| `lib/hooks.sh` | Coder hook installation and removal |
| `lib/metrics.sh` | CSV metrics, phase timing, token usage tracking |
| `lib/claude.sh` | Claude invocation helpers (build command, run, extract output) |
| `lib/coder.sh` | Coder agent prompt construction and spawning |
| `lib/fixer.sh` | Fixer agent with session resume and review comment fetching |
| `lib/merger.sh` | Merger agent with verdict parsing and diagnosis hints |
| `lib/testgate.sh` | Test gate execution, auto-detection, SHA flags |
| `lib/postfix.sh` | Post-fix test verification and fix-tests agent |
| `lib/reviewer.sh` | Diff fetching and parallel reviewer execution |
| `lib/reviewer-posting.sh` | Comment posting, dedup, clean-review detection |
| `lib/review-runner.sh` | Review cycle orchestration |
| `lib/context.sh` | Task summary generation and accumulation |
| `lib/config.sh` | Config loading with precedence (env > file > default) |
