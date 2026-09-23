# Autopilot — Extraction & Standalone Plan

An autonomous PR pipeline that works through a project's task list with Claude Code agents. One agent implements a task, another reviews it, and the pipeline merges the PR when the quality gates pass.

The pipeline currently lives in `scripts/pr-pipeline/` in the devops repo. This plan extracts it into a standalone repository (`autopilot`) that anyone with Claude Code and a GitHub repo can use.

---

## 1. What Autopilot Does

Given a markdown task list and a GitHub repository, Autopilot:

1. Reads the next task from the list
2. Spawns a Claude Code agent to implement it on a feature branch
3. Runs the project's test suite as a gate before requesting review
4. Spawns a reviewer agent to post code review comments on the PR
5. Spawns a fixer agent to address review feedback
6. Runs a final merge review (separate agent) and squash-merges if approved
7. Records metrics (timing, tokens, retries) and advances to the next task

The pipeline is **scheduler-driven**: two agents, the dispatcher and the reviewer, run every 15 seconds from macOS launchd (recommended) or cron. Each run checks the state and acts only if needed. All coordination goes through filesystem state (`.autopilot/state.json`) and GitHub PRs.

---

## 2. Current State (What Exists)

| Component | Lines | Location |
|-----------|-------|----------|
| Dispatcher (state machine) | 579 | `scripts/pr-pipeline/dispatcher.sh` |
| Reviewer cron (15s quick guards) | 126 | `scripts/pr-pipeline/reviewer-cron.sh` |
| State/locks/logging | 464 | `scripts/pr-pipeline/lib/state.sh` |
| Git operations (offloaded from coder) | 364 | `scripts/pr-pipeline/lib/git-ops.sh` |
| Coder agent | 171 | `scripts/pr-pipeline/lib/coder.sh` |
| Fixer agent (session resume) | 231 | `scripts/pr-pipeline/lib/fixer.sh` |
| Merger review | 246 | `scripts/pr-pipeline/lib/merger.sh` |
| Test gate | 276 | `scripts/pr-pipeline/lib/testgate.sh` |
| Post-fix tests + SHA verify | 237 | `scripts/pr-pipeline/lib/postfix.sh` |
| Session cache (pre-warm) | 178 | `scripts/pr-pipeline/lib/session-cache.sh` |
| Preflight checks | 157 | `scripts/pr-pipeline/lib/preflight.sh` |
| Context accumulation | 158 | `scripts/pr-pipeline/lib/context.sh` |
| Metrics tracking | 301 | `scripts/pr-pipeline/lib/metrics.sh` |
| Failure diagnosis | 135 | `scripts/pr-pipeline/lib/diagnose.sh` |
| Spec compliance | 295 | `scripts/pr-pipeline/lib/spec-review.sh` |
| Coder hooks (lint/test on edit) | 87 | `scripts/pr-pipeline/lib/hooks.sh` |
| 7 prompt files | ~153 | `scripts/pr-pipeline/prompts/` |
| External reviewer | ~686 | `pr-review/` (separate system, 5 personas) |
| 11 bats test files | 1,258 | `tests/` |
| **Total** | **~5,700** | |

### External Dependencies

- **`gh`** — GitHub CLI for PR operations
- **`claude`** — Claude Code CLI
- **`jq`** — JSON processing
- **`git`** — version control
- **`timeout`** — GNU coreutils, for process timeouts. macOS does not include it by default. `brew install coreutils` installs `gtimeout`, and Homebrew adds a `timeout` symlink in `/opt/homebrew/bin`. The install script and preflight must document this

### What's Coupled to This Setup

1. **Claude wrapper scripts** (`claude1`, `claude2`) — 2-line scripts that set `CLAUDE_CONFIG_DIR` per account. The pipeline calls them as `${CLAUDE_SCRIPTS_DIR}/claude${account}`.
2. **External reviewer** (`pr-review/review.sh`) — `reviewer-cron.sh` hardcodes a relative path `../../pr-review/review.sh`. `pr-review/` is a separate ~686-line review system with its own lib/ and 5 reviewer personas (general, dry, performance, security, design).
3. **Auto-pull devops** — Both entry points `git pull` the devops repo before sourcing libs. In a standalone repo, the entry points pull the autopilot repo itself, which is simpler.
4. **`CLAUDECODE` env var** — Every agent spawn runs `unset CLAUDECODE` to prevent session reuse bugs. The standalone repo must keep and document this workaround.
5. **Branch prefix `pr-pipeline/task-`** — Hardcoded in at least 4 files: dispatcher.sh (`_detect_pr_for_task`), coder.sh, fixer.sh, postfix.sh. All must be updated to use the configured prefix.
6. **Session pre-warming** (`lib/session-cache.sh`) — Pre-warms Claude sessions with project context using content-hash memoization. Relies on `realpath` (macOS-portable shim included).
7. **Git operations offload** (`lib/git-ops.sh`) — The pipeline, not the coder, creates the branch, commits, creates the PR and extracts its title. `_extract_pr_title()` searches for TITLE: and falls back to the oldest commit.
8. **Coder hooks** (`lib/hooks.sh`) — Installs lint/test Stop hooks on the coder agent to validate its edits as it works. The hooks are installed before the coder or fixer is spawned and removed afterwards.
9. **Background test gate** — The test gate runs in a detached git worktree (`--detach`) in parallel with the reviewer. It uses Stop hook SHA flags to skip redundant re-runs.

---

## 3. Target Architecture

### Directory Layout

```
autopilot/
├── bin/
│   ├── autopilot-dispatch       # Main dispatcher (scheduler entry point)
│   ├── autopilot-review         # Reviewer entry point (cron + standalone)
│   ├── autopilot-init           # Interactive project setup wizard
│   ├── autopilot-doctor         # Non-interactive setup validation (11 checks)
│   ├── autopilot-start          # Validate setup and start pipeline
│   ├── autopilot-schedule       # launchd plist generation and management
│   ├── autopilot-status         # Pipeline health and readiness checker
│   └── autopilot-live-test      # Live test runner (run, status, clean)
├── lib/                         # 43 shared shell libraries — see [architecture.md](architecture.md#libraries-lib) for the full module table
├── prompts/
│   ├── implement.md             # Coder system prompt
│   ├── fix-and-merge.md          # Fixer system prompt
│   ├── merge-review.md          # Merger system prompt
│   ├── fix-tests.md             # Test fixer system prompt
│   ├── diagnose.md              # Diagnostician system prompt
│   ├── spec-compliance.md       # Spec reviewer system prompt
│   └── summarize.md             # Summary generator system prompt
├── reviewers/                   # Review personas (bundled from pr-review)
│   ├── general.md
│   ├── security.md
│   ├── performance.md
│   ├── dry.md
│   └── design.md               # Design coherence (contract drift, dead params, math)
├── plists/                      # macOS launchd plist templates
├── examples/
│   ├── autopilot.conf           # Example config with all options documented
│   ├── tasks.example.md         # Example task file
│   ├── CLAUDE.example.md        # Default CLAUDE.md template for autopilot-init
│   ├── codex-output-schema.json # Structured output schema for Codex reviewer
│   ├── live-test-tasks.md       # 6 tasks for live test pipeline validation
│   └── live-test-autopilot.conf # Live test config overrides (Haiku, short timeouts)
├── docs/
│   ├── autopilot-plan.md        # This design document
│   ├── getting-started.md       # Quick start guide
│   ├── configuration.md         # All config options
│   ├── task-format.md           # How to write task files
│   └── architecture.md          # How the pipeline works
├── scripts/                     # Helper scripts (check-deps.sh, remove-crontab-entries.sh)
├── tests/                       # 70 bats test files
├── Makefile                     # check, test, lint, install, live-test, install-launchd targets
├── README.md
├── CLAUDE.md                    # Project conventions for self-building
└── .gitignore
```

### Key Changes from Current Pipeline

1. **Reviewer inlined** — Bundle the review system (5 reviewer personas and the review logic) into the repo. Nothing depends on `pr-review/`.
2. **Config file** — Replace hardcoded constants with `autopilot.conf` (bash key=value) loaded at startup. Every value has a default.
3. **Claude helpers extracted** — `extract_claude_text()` and `build_claude_cmd()` move from metrics.sh to a new `lib/claude.sh` shared utility. Every module that spawns an agent uses it.
4. **Claude invocation abstracted** — The `claude1`/`claude2` wrappers are removed. The config sets the command and optional per-role config directories.
5. **State directory renamed** — `.pr-pipeline/` → `.autopilot/`.
6. **Branch prefix configurable** — `pr-pipeline/task-N` → `${AUTOPILOT_BRANCH_PREFIX}/task-N` (default: `autopilot`). Updated in all 4+ files that reference it.
7. **PAUSE mechanism preserved** — `touch .autopilot/PAUSE` stops the pipeline without editing crontab. Documented in getting-started and config docs.
8. **Makefile added** — Provides `make test` (runs bats), `make lint` (shellcheck), `make install`. With it, the test gate can detect and run the tests during the dogfood run.
9. **Git operations offloaded** — The pipeline, not the coder agent, creates branches, commits and PRs through `lib/git-ops.sh`. PR title extraction searches the whole output for TITLE: and falls back to the oldest commit.
10. **Session pre-warming** — `lib/session-cache.sh` pre-warms Claude sessions with project context using content-hash memoization, reducing cold-start time.
11. **Coder hooks** — `lib/hooks.sh` installs lint/test Stop hooks on the coder agent to validate its edits as it works. The hooks are installed before the agent is spawned and removed afterwards.
12. **Background test gate** — The test gate runs in a detached git worktree in parallel with the reviewer. It uses Stop hook SHA flags to skip redundant re-runs.
13. **Clean review skip** — When all reviewers return "no issues", the pipeline skips the fixer and transitions directly from reviewed→fixed, saving a full agent cycle.
14. **Progressive commits** — The coder is told to commit as it works, not in one batch at the end. This gives a cleaner git history and makes partial progress recoverable.
15. **Design coherence reviewer** — 5th reviewer persona that catches contract drift, dead parameters, broken math at boundaries, and validation gaps the other 4 miss.

---

## 4. Configuration System

### Config Format: `autopilot.conf` (bash key=value)

**Decision: Use a parsed bash config file, not YAML.** YAML parsing in bash requires either `yq`, whose Go and Python variants differ, or a fragile pure-bash parser. A `.conf` file with `KEY=VALUE` lines is the standard Unix pattern for shell tool config. Config files are **not** `source`d, because sourcing would run arbitrary code from a cloned repo. `lib/config.sh` parses them line by line and accepts only lines matching `^AUTOPILOT_[A-Z_]*=`.

The config file is `autopilot.conf` in the project root or `.autopilot/config.conf`. Every value has a built-in default, so no config is needed to start.

```bash
# autopilot.conf — Project configuration for Autopilot
# Source: https://github.com/diziet/autopilot

# Claude Code settings
AUTOPILOT_CLAUDE_CMD="claude"                     # Claude CLI binary
AUTOPILOT_CLAUDE_FLAGS=""                         # Extra flags (e.g. "--dangerously-skip-permissions")
AUTOPILOT_CLAUDE_MODEL="opus"                     # Claude model to use
AUTOPILOT_CLAUDE_OUTPUT_FORMAT="json"             # Output format
AUTOPILOT_CODER_CONFIG_DIR=""                     # CLAUDE_CONFIG_DIR for coder (empty = default)
AUTOPILOT_REVIEWER_CONFIG_DIR=""                  # CLAUDE_CONFIG_DIR for reviewer (empty = default)
AUTOPILOT_SPEC_REVIEW_CONFIG_DIR=""               # CLAUDE_CONFIG_DIR for spec review (falls back to AUTOPILOT_CODER_CONFIG_DIR)

# Task source
AUTOPILOT_TASKS_FILE=""                           # Auto-detect if empty (tasks.md or *implementation*guide*.md)
AUTOPILOT_CONTEXT_FILES=""                        # Colon-separated reference doc paths (replaces .pr-pipeline/context-files)

# Timeouts (seconds)
AUTOPILOT_TIMEOUT_CODER=2700                      # 45 minutes
AUTOPILOT_TIMEOUT_FIXER=900                       # 15 minutes
AUTOPILOT_TIMEOUT_TEST_GATE=300                   # 5 minutes
AUTOPILOT_TIMEOUT_REVIEWER=600                    # 10 minutes (outer timeout for full review cycle)
AUTOPILOT_TIMEOUT_REVIEWER_CLAUDE=450             # Per-reviewer Claude call (inner timeout, must be < REVIEWER)
AUTOPILOT_TIMEOUT_MERGER=600                      # 10 minutes
AUTOPILOT_TIMEOUT_SUMMARY=60                      # Task summarization
AUTOPILOT_TIMEOUT_DIAGNOSE=300                    # Failure diagnosis
AUTOPILOT_TIMEOUT_SPEC_REVIEW=1200                 # Spec compliance review (runs asynchronously)
AUTOPILOT_TIMEOUT_FIX_TESTS=600                   # Test fixer
AUTOPILOT_TIMEOUT_GH=30                           # GitHub API calls

# Limits
AUTOPILOT_MAX_RETRIES=5                           # Max retries per task (full coder respawn)
AUTOPILOT_MAX_TEST_FIX_RETRIES=3                  # Max test fixer attempts before escalating to diagnosis
AUTOPILOT_STALE_LOCK_MINUTES=""                    # Auto-derived from longest timeout + 5min buffer
AUTOPILOT_MAX_LOG_LINES=50000                     # Rotate pipeline.log after this many lines
AUTOPILOT_MAX_DIFF_BYTES=500000                   # Max diff size for review
AUTOPILOT_MAX_SUMMARY_LINES=50                    # Lines of completed-summary fed to coder context
AUTOPILOT_MAX_SUMMARY_ENTRY_LINES=20              # Max lines per individual summary entry

# Testing
AUTOPILOT_TEST_CMD=""                             # Auto-detect if empty (pytest, npm test, bats, make test)
AUTOPILOT_TEST_TIMEOUT=300                        # Test execution timeout
AUTOPILOT_TEST_OUTPUT_TAIL=80                     # Lines of test output in PR comments
AUTOPILOT_MAX_TEST_OUTPUT=500                     # Max lines of test output in fixer/test-fixer prompts

# Review
AUTOPILOT_REVIEWERS="general,dry,performance,security,design"  # Comma-separated reviewer personas
AUTOPILOT_SPEC_REVIEW_INTERVAL=5                  # Run spec compliance every Nth task (0 = disable)

# Branches
AUTOPILOT_BRANCH_PREFIX="autopilot"               # Branch prefix (autopilot/task-N)
AUTOPILOT_TARGET_BRANCH=""                         # PR target branch (empty = auto-detect via gh)

# Network
AUTOPILOT_MAX_NETWORK_RETRIES=20                  # Transient network error retries

# Auth
AUTOPILOT_MAX_REVIEWER_RETRIES=5                  # Max reviewer agent retries
AUTOPILOT_AUTH_FALLBACK="true"                     # Enable auth fallback
AUTOPILOT_TIMEOUT_AUTH_CHECK=10                    # Auth verification timeout

# Worktrees
AUTOPILOT_USE_WORKTREES="true"                     # Use git worktrees for task branches
AUTOPILOT_WORKTREE_SETUP_CMD=""                    # Custom shell command to run in worktree after creation
AUTOPILOT_WORKTREE_SETUP_OPTIONAL="false"          # If true, continue despite worktree setup failure

# Codex reviewer (optional)
AUTOPILOT_CODEX_MODEL="o4-mini"                    # Codex model for review
AUTOPILOT_CODEX_MIN_CONFIDENCE="0.7"               # Minimum confidence score for posting findings
AUTOPILOT_TIMEOUT_CODEX=450                        # Codex review timeout
```

### Config Loading (lib/config.sh)

1. Snapshot all existing `AUTOPILOT_*` environment variables
2. Set all `AUTOPILOT_*` variables to built-in defaults
3. Parse `autopilot.conf` in project root if it exists — line-by-line, only `AUTOPILOT_*=value` assignments (no `source`, no arbitrary code)
4. Parse `.autopilot/config.conf` if it exists (overrides project root)
5. Restore snapshotted env vars (env always wins over file values)
6. Log effective config with sources at startup (first dispatcher tick)

This gives the precedence CLI flag > env var > config file > built-in default. Config files use plain `KEY=VALUE` syntax, not `KEY="${KEY:-value}"`, because the snapshot and restore steps already enforce the precedence.

### Permission Model

By default, `AUTOPILOT_CLAUDE_FLAGS` is empty, so Claude runs in its normal interactive mode and prompts for permissions. That **fails in unattended cron runs**, because there is no terminal to approve tool calls. For unattended operation, users must set `AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions"` explicitly. The empty default is deliberate: skipping permission prompts is a security tradeoff, so the user must opt in.

**Early detection:** At startup the dispatcher checks `[[ -t 0 ]]` (stdin is a TTY). When it runs non-interactively (cron) and `AUTOPILOT_CLAUDE_FLAGS` does not contain `--dangerously-skip-permissions`, it logs a `CRITICAL` warning and exits at once. Without this check, Claude would wait 45 minutes for a permission approval.

### Single-Account vs Multi-Account Mode

- If `AUTOPILOT_CODER_CONFIG_DIR` and `AUTOPILOT_REVIEWER_CONFIG_DIR` are both empty → single account, `claude` command used directly
- If set → wraps Claude invocations with `CLAUDE_CONFIG_DIR=<dir>` per role
- This replaces the `claude1`/`claude2` wrapper pattern entirely

---

## 5. State Machine

The state machine has changed substantially since the initial design:

```
pending → implementing → test_fixing ─┐
                │                      │
                │ (tests pass)         │ (tests pass after fix)
                ↓                      ↓
             pr_open → reviewed ──→ fixing → fixed → merging → merged → completed
               │          │  ↑                 ↑ │     ↓         ↓
               │          │  +--- (REJECT) ----│-+  (advance task)
               │          │ (clean reviews)    │
               │          └──────→ fixed ──────┘
               └──→ test_fixing (post-PR test failure)
```

Additional transitions support error recovery: `fixed → reviewed` (merge conflicts), `fixed → test_fixing` (post-fix test regression), and `fixed → pending` (full restart).

- **pending**: Read next task, run preflight, spawn coder. The pipeline, not the coder, does the git operations (branch creation, commits, PR) through `lib/git-ops.sh`
- **implementing**: Coder running in background with lint/test Stop hooks installed. On completion, run test gate (in parallel with reviewer via detached worktree). If tests pass → pr_open. If tests fail → test_fixing. If no PR detected → back to pending (retry)
- **test_fixing**: Test gate failed on the coder's PR. Re-run tests first (a change on main may have fixed the failure). If they still fail, spawn the test fixer agent (up to `MAX_TEST_FIX_RETRIES=3`). On pass → pr_open. When the attempts run out → run_diagnosis() then pending (fresh coder, increment retry)
- **pr_open**: Waiting for review. The reviewer cron detects this state and spawns the configured reviewers in parallel (`AUTOPILOT_REVIEWERS`, default: all 5)
- **reviewed**: Review comments posted. If all reviewers returned "no issues" → skip fixer, transition directly to fixed. Otherwise spawn fixer (with coder hooks installed)
- **fixing**: Fixer running. On completion, verify that the fixer pushed (SHA check), then run tests → fixed (or retry)
- **fixed**: Tests pass after fix. Spawn merger for final review
- **merging**: Merger running. APPROVE → squash-merge → merged. REJECT → back to reviewed, with diagnosis hints for the next fixer. Crash recovery: if the merger process died (stale lock, no result), return to pending and increment the retry count
- **merged**: Record metrics, generate summary (in background), advance task counter → pending (next task)
- **completed**: All tasks done — resumes automatically if new tasks are appended to the task file (`completed → pending`)

### PAUSE Mechanism

Two pause modes:
- **Soft pause** (`touch .autopilot/PAUSE`): Empty file — finish current phase, then stop
- **Hard pause** (`echo "reason" > .autopilot/PAUSE`): Non-empty file — exit immediately on next tick

Both the dispatcher and the reviewer check for this file at startup, so pausing needs no crontab edit. Remove the file or run `autopilot-start` to resume.

### Claude Session Isolation

Every agent spawn runs `unset CLAUDECODE` before launching Claude, to prevent session reuse across invocations. This is a workaround: when the Claude Code environment variable `CLAUDECODE` is set, the new process can attach to an existing session instead of starting a new one.

---

## 6. Inlining the Reviewer

Currently `reviewer-cron.sh` calls `pr-review/review.sh` (~650 lines across 7 files). Autopilot moves this code into `lib/reviewer.sh`, built in two tasks to keep each task small:

### Core Review Logic (Task 9)
- Fetch PR diff via `gh pr diff` with metadata header
- Guard against oversized diffs (`AUTOPILOT_MAX_DIFF_BYTES`)
- For each configured reviewer persona, spawn Claude with the persona prompt and pipe the diff through stdin (needed for large diffs that exceed `ARG_MAX`)
- Run reviewers in parallel (background processes with `wait`)
- Collect results, track successes/failures

### Comment Posting & Dedup (Task 10)
- Format review comments with reviewer display name and SHA tag
- Post comments via `gh pr comment`
- Track reviewed SHAs in `.autopilot/reviewed.json` to prevent re-reviewing unchanged code
- Skip posting if reviewer response is the standard "no issues" sentinel
- Update pipeline state to `reviewed` after all reviewers complete

### Reviewer Personas
The persona files (`general.md`, `security.md`, `performance.md`, `dry.md`, `design.md`) move into the autopilot repo under `reviewers/`. The design reviewer catches semantic/design coherence issues the other 4 miss: contract drift between docs and code, dead parameters, broken math at boundaries, and validation gaps. Users can add a custom persona by adding a `.md` file to this directory and its name to `AUTOPILOT_REVIEWERS`.

### Standalone Review Command
For ad-hoc use, `bin/autopilot-review` also accepts `autopilot-review /path/to/project --pr NUMBER`, which reviews a single PR outside the pipeline loop.

---

## 7. Installation & Setup

### Install

```bash
git clone https://github.com/diziet/autopilot.git ~/.autopilot
cd ~/.autopilot && make install
```

`make install` does:
- Verify dependencies (`claude`, `gh`, `jq`, `git`, `timeout`)
- Symlink all `autopilot-*` binaries to `~/.local/bin/` (or `PREFIX=` override)
- Print setup instructions

### Project Setup

Use `autopilot-init` for interactive guided setup, or set up manually:

```bash
cd /path/to/your/project

# Option A: Interactive setup (recommended)
autopilot-init

# Option B: Manual setup
cp ~/.autopilot/examples/tasks.example.md tasks.md
# Edit tasks.md with your implementation plan
cp ~/.autopilot/examples/autopilot.conf autopilot.conf
# Edit config — at minimum, set AUTOPILOT_CLAUDE_FLAGS for unattended use
echo ".autopilot/" >> .gitignore

# Schedule with launchd (recommended on macOS)
autopilot-schedule /path/to/project
# Or with separate accounts: --dispatcher-account 1 --reviewer-account 2
```

### Minimal Start (Zero Config)

If a project has:
- A `tasks.md` file
- `claude` on PATH
- `gh` authenticated
- A GitHub remote

Then `autopilot-dispatch /path/to/project` runs with no config file. Claude will prompt for permissions unless `AUTOPILOT_CLAUDE_FLAGS` is set.

---

## 8. Testing Strategy

### Shell Tests (bats-core)

`bats-core` is a dev dependency. Install it with `brew install bats-core` or `npm install -g bats`. Tests live in `tests/` and run with `make test`.

Test the pure-logic functions that don't require Claude or GitHub. The current pipeline has 102 tests across 11 bats files (1,258 lines):

- **Background test gate** (`test_bg_testgate.bats`): Detached worktree creation, venv detection, test command construction
- **Session cache** (`test_session_cache.bats`): Content-hash memoization, cache invalidation, prewarm prompt construction
- **Stop hooks** (`test_stop_hook.bats`): Two-phase pytest (--lf then --ff), SHA flag writes, test gate skipping
- **Test gate** (`test_testgate.bats`): Framework auto-detect (pytest, npm, bats), no-cov override, command allowlist
- **PR title extraction** (`test_pr_title.bats`): TITLE: prefix search, preamble skipping, quote stripping, git log fallback
- **Finalize race** (`test_finalize_race.bats`): Lock-based guard against concurrent finalization
- **Diagnosis hints** (`test_diagnosis_hints.bats`): Hint extraction from merger rejection, hint injection into fixer prompt
- **Clean review skip** (`test_reviews_clean.bats`): Detecting all-clean reviews, reviewed→fixed skip logic
- **Merger verdict** (`test_merger_verdict.bats`): APPROVE/REJECT parsing, substring matching edge cases
- **Portable realpath** (`test_portable_realpath.bats`): macOS-compatible realpath shim
- **Claude settings** (`test_claude_settings.bats`): Max output token configuration

### The Dogfood Test

The integration test is the existing `pr-pipeline` building autopilot from an implementation guide. If the result is a working pipeline, autopilot works.

---

## 9. Documentation

### README.md
- What it does (one paragraph)
- Quick start (5 steps)
- How it works (state machine diagram)
- Configuration reference (link to docs/)
- Requirements

### docs/getting-started.md
- Prerequisites
- Installation
- First project walkthrough (with a toy 3-task project)
- Pausing and resuming
- Troubleshooting

### docs/configuration.md
- Full config reference with all `AUTOPILOT_*` variables
- Single vs multi-account setup
- Custom test commands
- Custom reviewer personas
- Environment variable overrides

### docs/task-format.md
- Supported formats with examples
- How to write effective task descriptions
- Context files usage
- Tips for task granularity

### docs/architecture.md
- State machine details
- Lock/concurrency model
- Metrics and logging
- How prompts and reviewer personas work

---

## 10. Implementation Task List

The pipeline runs these tasks in order. Each task produces a working, testable commit. Where the order matters, the dependency is noted.

**Convention:** Every module that calls the `gh` API should use `AUTOPILOT_TIMEOUT_GH` as its timeout. It is currently used in fixer, testgate, merger, metrics, postfix and spec-review.

### Task 1: Project scaffold and Makefile
Set up repository structure with README.md (stub), CLAUDE.md (project conventions), .gitignore, Makefile (with `test`, `lint`, `install` targets), empty directories (bin/, lib/, prompts/, reviewers/, examples/, docs/, tests/). The Makefile should run `bats tests/` for `make test` so the test gate works from the first task onward. Include a trivial `tests/test_smoke.bats` that passes.

### Task 2: Config loading
Implement lib/config.sh. Define all `AUTOPILOT_*` variables with built-in defaults (the complete config schema is in section 4 of this plan; include every variable listed there). Source `autopilot.conf` then `.autopilot/config.conf` if they exist. Log effective config with source annotations. Write `tests/test_config.bats` covering: defaults only, file override, env override, missing file, partial config.

### Task 3: State management — state read/write, logging, counters
Extract the core of state.sh from pr-pipeline: `init_pipeline` (creates `.autopilot/` directory tree including state.json, logs/, locks/ on first run), state read/write with atomic tmp+mv, `log_msg` with rotation (`AUTOPILOT_MAX_LOG_LINES`), `update_status` for state transitions. Include the generic counter helpers (`_get_counter`, `_increment_counter`, `_reset_counter`) and the public API wrappers for retry tracking (`get_retry_count`, `increment_retry`, `reset_retry`) and test fix tracking (`get_test_fix_retries`, `increment_test_fix_retries`, `reset_test_fix_retries`). Rename `.pr-pipeline` → `.autopilot` throughout. Source lib/config.sh and use `AUTOPILOT_*` variables for all previously-hardcoded constants. Write `tests/test_state.bats` for state transitions, counter operations, and init.

### Task 4: Lock management and task parsing
Extract lock management from state.sh: `acquire_lock`, `release_lock`, stale lock detection based on `AUTOPILOT_STALE_LOCK_MINUTES` and dead PID checks. Extract task file parsing: both `## Task N` and `### PR N` formats, auto-detect tasks file (`tasks.md` then `*implementation*guide*.md`). Replace the file-based `.pr-pipeline/context-files` mechanism with `AUTOPILOT_CONTEXT_FILES` config variable (colon-separated paths parsed into an array). Write `tests/test_locks.bats` and `tests/test_task_parsing.bats`.

### Task 5: Claude invocation helpers
Create lib/claude.sh with shared functions used by all agent-spawning modules: `build_claude_cmd` (constructs the full command from config: command, flags, output format, optional config dir), `extract_claude_text` (parses Claude JSON output to extract the `.result` text field), and `run_claude` (timeout wrapper with `unset CLAUDECODE` isolation). Write `tests/test_claude.bats`.

### Task 6: Preflight checks
Extract and adapt lib/preflight.sh. Check dependencies (claude, gh, jq, git, timeout — with explicit macOS guidance for timeout via `brew install coreutils`), verify git repo, clean working tree, check gh auth, verify tasks file exists, verify CLAUDE.md exists. Use config for claude command path. Detect non-interactive mode (`[[ -t 0 ]]`) and log CRITICAL + exit if `AUTOPILOT_CLAUDE_FLAGS` lacks `--dangerously-skip-permissions`. Write `tests/test_preflight.bats`.

### Task 7: Git operations
Create lib/git-ops.sh. Offload git operations from the coder agent to the pipeline: branch creation, committing, PR creation, and PR title extraction. Include `_extract_pr_title()` (searches for `TITLE:` prefix anywhere in Claude output, with oldest-commit fallback) and `_extract_pr_body()`. Handle PR description generation from diff using Claude. Write `tests/test_git_ops.bats`.

### Task 8: Coder agent, hooks, and prompts
Extract and adapt lib/coder.sh. Use lib/claude.sh helpers for invocation. Use config for timeout and account. Read prompts/implement.md at runtime. Include context files from `AUTOPILOT_CONTEXT_FILES` config. Instruct coder to commit progressively (not one big batch). Also create lib/hooks.sh — installs lint/test Stop hooks on the coder agent for real-time edit validation. Hooks are installed before spawning coder/fixer and cleaned up after. Copy and adapt all prompt files from pr-pipeline/prompts/ — update branch naming from `pr-pipeline/task-N` to use `${AUTOPILOT_BRANCH_PREFIX}/task-N`. Keep the `fix-and-merge.md` filename. Write `tests/test_coder.bats` and `tests/test_hooks.bats`.

### Task 9: Test gate
Extract and adapt lib/testgate.sh. Support custom test command from `AUTOPILOT_TEST_CMD` — when set, bypass the allowlist entirely. Auto-detect if not configured: check for pytest, npm test, bats, make test (in that order). Add `bats` to the allowlist. Support background execution in a detached git worktree for parallel test+review. Use Stop hook SHA flags to skip redundant re-runs when the coder's hooks already verified tests pass. Export exit code constants used by postfix.sh and merger.sh. Write `tests/test_testgate.bats`.

### Task 10: Session cache and pre-warming
Create lib/session-cache.sh. Pre-warm Claude sessions with project context using content-hash memoization. Hash project files (CLAUDE.md, context files) to detect changes and invalidate cache. Use macOS-portable `realpath` shim. Write `tests/test_session_cache.bats`.

### Task 11: Fixer agent with session resume
Extract and adapt lib/fixer.sh. Use lib/claude.sh helpers. Use config for timeout and account. Fetch review comments from GitHub API via `gh api`. Implement session resume via `--resume` flag (lookup chain: fixer JSON → coder JSON → cold start). Install coder hooks before spawning fixer (via lib/hooks.sh). Include diagnosis hints from merger rejection in the fixer prompt. Write `tests/test_fixer.bats`.

### Task 12: Reviewer core — diff fetching and parallel review execution
Build the first half of lib/reviewer.sh (inlined from pr-review). Fetch PR diff with metadata header via `gh pr diff`. Guard against oversized diffs (`AUTOPILOT_MAX_DIFF_BYTES`). Copy reviewer persona files (general.md, security.md, performance.md, dry.md, design.md) into `reviewers/`. For each persona in `AUTOPILOT_REVIEWERS`, spawn Claude in parallel. Write `tests/test_reviewer.bats`.

### Task 13: Reviewer posting — comment formatting, dedup, clean-review skip, and state update
Build the second half of lib/reviewer.sh. Format review comments with reviewer display name and SHA tag. Post via `gh pr comment`. Track reviewed SHAs in `.autopilot/reviewed.json`. Skip posting if reviewer response matches the "no issues" sentinel. Detect when all reviewers return clean results and expose this for the dispatcher's reviewed→fixed skip. Write `tests/test_reviewer_posting.bats`.

### Task 14: Post-fix verification
Extract and adapt lib/postfix.sh. Run test gate after fixer completes. Spawn fix-tests agent if tests fail. Include fixer push verification (SHA comparison before/after). Graceful degradation if `gh api` fails. Write `tests/test_postfix.bats`.

### Task 15: Merger
Extract and adapt lib/merger.sh. Parse APPROVE/REJECT response. Squash-merge via `gh pr merge --squash`. Include diagnosis hints in rejection comments for the next fixer cycle. Write `tests/test_merger.bats`.

### Task 16: Smoke test — source all libs
Create `tests/test_smoke.bats` (replace the trivial one from Task 1). Source all lib/*.sh files in a subshell. Verify no syntax errors, no variable conflicts, no function name collisions.

### Task 17: Context accumulation
Extract and adapt lib/context.sh. Generate task summaries via Claude in the background (non-blocking). Use `AUTOPILOT_TIMEOUT_SUMMARY` and `AUTOPILOT_MAX_SUMMARY_LINES`. Write `tests/test_context.bats`.

### Task 18: Metrics tracking
Extract and adapt lib/metrics.sh. CSV tracking for per-task metrics, phase timing (including `test_fixing_sec` column), and token usage. Per-phase timing with sub-step instrumentation (TIMER tags). CSV header auto-update on schema change. Write `tests/test_metrics.bats`.

### Task 19: Failure diagnosis
Extract and adapt lib/diagnose.sh. Spawn diagnostician agent on max retries. Handle log file selection for all states including `test_fixing`. Write `tests/test_diagnose.bats`.

### Task 20: Spec compliance review
Extract and adapt lib/spec-review.sh. Use `AUTOPILOT_SPEC_REVIEW_INTERVAL` — when set to 0, disable entirely. Write `tests/test_spec_review.bats`.

### Task 21: Dispatcher (main orchestrator)
Extract and adapt dispatcher.sh → bin/autopilot-dispatch. Implement quick guards (PAUSE file, lock PID checks) for 15-second cron. Full state machine including: clean-review skip (reviewed→fixed when all reviewers return no issues), background test gate in parallel with reviewer, coder hooks installed/cleaned around all agent spawns, fixer push verification, stale branch reset for pending tasks, diagnosis hints from merger rejection fed to next fixer. Write `tests/test_dispatcher.bats`.

### Task 22: Reviewer cron entry
Build bin/autopilot-review. Quick guards, two modes: (1) cron mode — detect `pr_open` state and run review, (2) standalone mode — `autopilot-review PR_NUMBER` for ad-hoc review. Trigger review immediately on pr_open transition. Write `tests/test_review_entry.bats`.

### Task 23: Install script and examples
`make install` — verify dependencies (including macOS `timeout`), symlink binaries, print setup instructions. Create `examples/autopilot.conf` and `examples/tasks.example.md`. Write `tests/test_install.bats`.

### Task 24: Documentation — README and getting-started
Write full README.md and docs/getting-started.md.

### Task 25: Documentation — configuration and task format
Write docs/configuration.md and docs/task-format.md.

### Task 26: Documentation — architecture
Write docs/architecture.md (state machine with clean-review skip, background test gate, coder hooks, crash recovery, lock/concurrency model, metrics and logging, reviewer personas).

---

## 11. Dogfood Plan

### Manual Bootstrap (before pipeline starts)

The pipeline cannot run until these files exist, and they must be committed by hand:

1. Create the GitHub repo at https://github.com/diziet/autopilot
2. Clone it locally
3. Commit initial files:
   - `CLAUDE.md` — project conventions (required by preflight)
   - `.gitignore` — includes `.autopilot/`, `.pr-pipeline/`
   - `tasks.md` — the implementation guide (task list above, formatted for the pipeline)
   - `.pr-pipeline/context-files` — paths to this plan document, as a reference for the coder. The existing pr-pipeline reads context file paths from this file; autopilot will use the `AUTOPILOT_CONTEXT_FILES` setting instead
4. Push to GitHub

### Pipeline Builds Autopilot

The **existing pr-pipeline** (from devops) builds the autopilot repo. Autopilot does not build itself. It becomes self-hosting only after all tasks are complete and the cron jobs point at autopilot's own binaries.

```crontab
# New — pr-pipeline building autopilot (15-second ticks)
* * * * * .../dispatcher.sh /path/to/autopilot 1
* * * * * sleep 15 && .../dispatcher.sh /path/to/autopilot 1
* * * * * sleep 30 && .../dispatcher.sh /path/to/autopilot 1
* * * * * sleep 45 && .../dispatcher.sh /path/to/autopilot 1
* * * * * .../reviewer-cron.sh /path/to/autopilot 2
* * * * * sleep 15 && .../reviewer-cron.sh /path/to/autopilot 2
* * * * * sleep 30 && .../reviewer-cron.sh /path/to/autopilot 2
* * * * * sleep 45 && .../reviewer-cron.sh /path/to/autopilot 2
```

Both pipelines share the same pipeline scripts (from devops) but have independent state (`.pr-pipeline/` in each project). Per-project locks prevent interference. Quick guards ensure idle ticks exit in <10ms (pure filesystem checks, no git pull or lib sourcing).

### Concurrent Pipeline Considerations

Two pipeline instances will compete for Claude API capacity. Each cron tick spawns work only if the previous agent has finished, so at most 2 Claude processes run at the same time (one per project). That is within the API rate limits.

### After All Tasks Complete

1. Verify autopilot works: run `autopilot-dispatch` manually against a toy project
2. Switch cron jobs from devops pr-pipeline to autopilot's own `bin/autopilot-dispatch`
3. Autopilot is now self-hosting

---

## 12. Decisions Made

These were open questions, now resolved:

1. **Config format** → `autopilot.conf` (parsed `KEY=VALUE` file). It is parsed line by line and never `source`d, so it cannot run arbitrary code. YAML was rejected because `yq` has differing Go and Python variants and YAML parsing in bash is fragile.
2. **Testing framework** → bats-core. Standard for bash projects, available via brew/npm. `Makefile` provides `make test` target so the test gate works from Task 1. Test suite has grown to 70 test files.
3. **Reviewer inlining** → Yes, fully inlined. Split into two tasks (core, then posting and dedup) to keep each task small. Standalone `autopilot-review PR_NUMBER` preserved for ad-hoc use.
4. **`extract_claude_text` location** → New `lib/claude.sh` shared utility (Task 5). Resolves the ordering dependency between metrics.sh and merger.sh.
5. **Task parsing** → Extracted alongside lock management in Task 4 (split from state.sh to keep the task small).
6. **Self-update** → Optional `git pull` of autopilot install dir. ~~Off by default. Users update manually.~~ Corrected 2026-09-23: Task 166 (#195, 2026-03-20) turned it on by default. `check_self_update` in `lib/self_update.sh` fast-forwards the install dir to `origin/main` at most once every `AUTOPILOT_SELF_UPDATE_INTERVAL` seconds (default 300), when that checkout is on `main` with no local changes; 0 turns it off.
7. **Concurrent pipelines** → No throttling needed. Each pipeline runs one agent at a time, so at most 2 Claude processes run at once. A cron offset is available if needed.
8. **Git operations offload** → The pipeline, not the coder, creates branches, commits and PRs (Task 7). This gives a cleaner git history and makes partial progress recoverable.
9. **Coder hooks** → Lint/test Stop hooks validate the agent's edits as it works (Task 8). They are installed before the agent is spawned and removed afterwards. They catch errors while the agent edits, not after the full agent run.
10. **Background test gate** → Test gate runs in a detached worktree in parallel with the reviewer (Task 9). Stop hook SHA flags skip redundant re-runs. Saves ~3 min per task.
11. **Clean review skip** → When all 5 reviewers return "no issues", skip the fixer entirely (reviewed→fixed). Saves a full agent cycle (~15 min) on clean PRs.
12. **Design coherence reviewer** → 5th reviewer persona added after finding that the original 4 (general, dry, performance, security) missed semantic/intent issues on PR #80. Catches contract drift, dead parameters, broken math at boundaries.
13. **GitHub repo** → https://github.com/diziet/autopilot
