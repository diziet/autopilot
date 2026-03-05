# Autopilot

Autonomous PR pipeline that works through a project's task list using Claude Code agents. Given a markdown file of tasks and a GitHub repository, Autopilot reads each task, spawns a coder agent to implement it on a feature branch, runs your test suite, spawns reviewer agents to post code review comments, addresses feedback automatically, and squash-merges the PR when quality gates pass — then advances to the next task.

The pipeline is **cron-driven**: two cron jobs (dispatcher + reviewer) run every 15 seconds, check state, and take action when needed. All coordination happens through filesystem state (`.autopilot/state.json`) and GitHub PRs.

## Quick Start

```bash
# 1. Install
git clone https://github.com/diziet/autopilot.git ~/.autopilot
cd ~/.autopilot && make install

# 2. Set up your project
cd /path/to/your/project
cp ~/.autopilot/examples/autopilot.conf autopilot.conf
cp ~/.autopilot/examples/tasks.example.md tasks.md
echo '.autopilot/' >> .gitignore

# 3. Edit tasks.md with your implementation plan

# 4. Configure for unattended use (required for cron)
#    In autopilot.conf, set:
#    AUTOPILOT_CLAUDE_FLAGS="--dangerously-skip-permissions"

# 5. Add cron jobs (see "Cron Setup" below)
```

See [docs/getting-started.md](docs/getting-started.md) for a full walkthrough.

## How It Works

For each task in your task list, Autopilot:

1. **Reads** the next task from the markdown file
2. **Spawns a coder agent** to implement it on a feature branch
3. **Runs your test suite** as a gate before review
4. **Spawns 5 reviewer agents** in parallel (general, DRY, performance, security, design)
5. **Spawns a fixer agent** to address review feedback (skipped if reviews are clean)
6. **Runs a merge review** and squash-merges if approved
7. **Records metrics** (timing, tokens, retries) and advances to the next task

### State Machine

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

| State | What Happens |
|-------|-------------|
| `pending` | Read next task, run preflight checks, spawn coder |
| `implementing` | Coder agent running with lint/test hooks. On success → run tests |
| `test_fixing` | Tests failed — spawn test fixer (up to 3 attempts) |
| `pr_open` | PR created, waiting for review |
| `reviewed` | Reviews posted. If all clean → skip to `fixed`. Otherwise → spawn fixer |
| `fixing` | Fixer agent addressing review feedback |
| `fixed` | Tests pass after fix — spawn merger for final review |
| `merging` | Merger reviews. APPROVE → squash-merge. REJECT → back to `reviewed` |
| `merged` | Record metrics, generate summary, advance to next task |
| `completed` | All tasks done. Pipeline stops |

## Requirements

| Tool | Purpose | Install |
|------|---------|---------|
| [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) | Agent invocations | See Anthropic docs |
| [GitHub CLI](https://cli.github.com/) (`gh`) | PR operations | `brew install gh` |
| [jq](https://jqlang.github.io/jq/) | JSON processing | `brew install jq` |
| `git` | Version control | Pre-installed on macOS/Linux |
| GNU `timeout` | Process timeouts | See note below |

**Development only** (for running Autopilot's own tests):

| Tool | Purpose | Install |
|------|---------|---------|
| [bats-core](https://github.com/bats-core/bats-core) | Test framework | `brew install bats-core` |
| [ShellCheck](https://www.shellcheck.net/) | Shell linting | `brew install shellcheck` |

### macOS `timeout` Note

GNU `timeout` is not included with macOS. Install it via Homebrew:

```bash
brew install coreutils
```

This installs `gtimeout` and adds a `timeout` symlink to `/opt/homebrew/bin/` (Apple Silicon) or `/usr/local/bin/` (Intel). Make sure this directory is in your `PATH` — especially in your cron environment, where `PATH` is minimal.

## Installation

```bash
git clone https://github.com/diziet/autopilot.git ~/.autopilot
cd ~/.autopilot && make install
```

`make install` will:
- Verify all required dependencies are present
- Symlink `autopilot-dispatch` and `autopilot-review` to `~/.local/bin/`
- Print post-install setup instructions

Override the install prefix with `PREFIX=/usr/local make install`.

## Cron Setup

Autopilot uses 15-second cron ticks for fast state transitions. Each tick exits in under 10ms when idle (no work to do, paused, or locked).

```crontab
# Add to crontab with: crontab -e
# Set PATH so cron can find autopilot binaries and dependencies
PATH=$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin

# Dispatcher — drives the state machine (4 ticks per minute)
* * * * * autopilot-dispatch /path/to/project
* * * * * sleep 15 && autopilot-dispatch /path/to/project
* * * * * sleep 30 && autopilot-dispatch /path/to/project
* * * * * sleep 45 && autopilot-dispatch /path/to/project

# Reviewer — detects pr_open state and runs reviews (4 ticks per minute)
* * * * * autopilot-review /path/to/project
* * * * * sleep 15 && autopilot-review /path/to/project
* * * * * sleep 30 && autopilot-review /path/to/project
* * * * * sleep 45 && autopilot-review /path/to/project
```

## Configuration

All configuration is optional — Autopilot works with zero config if `claude` and `gh` are on PATH.

Copy the example config to your project root:

```bash
cp ~/.autopilot/examples/autopilot.conf autopilot.conf
```

Key settings:

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTOPILOT_CLAUDE_FLAGS` | `""` | **Must set `--dangerously-skip-permissions` for cron** |
| `AUTOPILOT_TASKS_FILE` | auto-detect | Path to task list (`tasks.md` or `*implementation*guide*.md`) |
| `AUTOPILOT_CONTEXT_FILES` | `""` | Colon-separated reference docs for coder context |
| `AUTOPILOT_TIMEOUT_CODER` | `2700` | Coder agent timeout in seconds (45 min) |
| `AUTOPILOT_MAX_RETRIES` | `5` | Max retries per task before diagnosis |
| `AUTOPILOT_REVIEWERS` | `general,dry,performance,security,design` | Reviewer personas to run |
| `AUTOPILOT_BRANCH_PREFIX` | `autopilot` | Branch naming: `<prefix>/task-N` |

Config precedence: **environment variable > `.autopilot/config.conf` > `autopilot.conf` > built-in default**.

See [examples/autopilot.conf](examples/autopilot.conf) for the full reference with all options documented.

## Pausing and Resuming

```bash
# Pause — both dispatcher and reviewer exit immediately
touch /path/to/project/.autopilot/PAUSE

# Resume — remove the file to continue
rm /path/to/project/.autopilot/PAUSE
```

No crontab editing required. The PAUSE file is checked before any work begins.

## Standalone Review

Review any PR outside the pipeline loop:

```bash
autopilot-review /path/to/project 42
```

This runs all configured reviewers against PR #42 and posts comments, without touching pipeline state.

## Project Layout

```
bin/            Entry points (autopilot-dispatch, autopilot-review)
lib/            Shared shell libraries (24 modules)
prompts/        Agent prompt templates (7 files)
reviewers/      Reviewer persona definitions (5 personas)
examples/       Example config and task files
docs/           Documentation
tests/          bats test suite
scripts/        Helper scripts
Makefile        test, lint, install, check-deps targets
```

## Testing

```bash
make test    # Run bats test suite
make lint    # Run shellcheck on all shell files
```

## License

MIT
