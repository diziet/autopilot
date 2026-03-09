# Autopilot

Autonomous PR pipeline that works through a project's task list using Claude Code agents. Given a markdown file of tasks and a GitHub repository, Autopilot reads each task, spawns a coder agent to implement it on a feature branch, runs your test suite, spawns reviewer agents to post code review comments, addresses feedback automatically, and squash-merges the PR when quality gates pass — then advances to the next task.

The pipeline is **scheduler-driven**: two agents (dispatcher + reviewer) run every 15 seconds via macOS launchd or cron, check state, and take action when needed. All coordination happens through filesystem state (`.autopilot/state.json`) and GitHub PRs.

## Quick Start

```bash
# 1. Install
git clone https://github.com/diziet/autopilot.git ~/.autopilot
cd ~/.autopilot && make install

# 2. Set up your project
cd /path/to/your/project
autopilot-init                 # Interactive setup wizard

# 3. Edit tasks.md with your implementation plan

# 4. Validate and start
autopilot-doctor               # Check setup (non-interactive)
autopilot-start                # Remove PAUSE file and begin

# 5. Schedule with launchd (see "Scheduling" below)
autopilot-schedule /path/to/your/project
```

> **Tip:** Autopilot works best with two Claude Code accounts — one for the dispatcher (coder/fixer) and one for the reviewer — so concurrent agents don't compete for rate limits. See [Multi-Account Setup](docs/getting-started.md#multi-account-setup) for details.

See [docs/getting-started.md](docs/getting-started.md) for a full walkthrough.

## How It Works

Each task runs in an isolated git worktree (`.autopilot/worktrees/task-N/`) so your working tree stays clean and you can keep working while the pipeline runs.

For each task in your task list, Autopilot:

1. **Reads** the next task from the markdown file
2. **Creates an isolated worktree** and installs project dependencies (Node, Python, Ruby, Go)
3. **Spawns a coder agent** to implement it on a feature branch (with real-time lint/test hooks)
4. **Runs your test suite** as a gate before review
5. **Spawns 5 reviewer agents** in parallel (general, DRY, performance, security, design) — optionally with [OpenAI Codex](docs/configuration.md#codex-reviewer)
6. **Spawns a fixer agent** to address review feedback with full test output context (skipped if reviews are clean)
7. **Runs a merge review** and squash-merges if approved
8. **Records metrics** (timing, tokens, retries), posts a performance summary with test result summaries, and advances to the next task

### State Machine

```
pending ──→ implementing ──→ test_fixing ──┐
  ↑              │                         │
  │              │ (tests pass)            │ (tests pass after fix)
  │              ↓                         ↓
  │           pr_open ──→ reviewed ──→ fixing ──→ fixed ──→ merging ──→ merged ──→ completed
  │                          │  ↑                            ↓             │
  │                          │  └──── (REJECT) ──────────────┘             │
  │                          │                                             │
  │                          │ (all reviews clean)                         │
  │                          └──→ fixed                                    │
  │                                                                        │
  └──────────────────────── (next task) ───────────────────────────────────┘
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
| `completed` | All tasks done — resumes automatically if new tasks are appended to the task file |

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
| [GNU parallel](https://www.gnu.org/software/parallel/) | Parallel test execution | `brew install parallel` |
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
- Symlink all `autopilot-*` binaries (`autopilot-dispatch`, `autopilot-review`, `autopilot-init`, `autopilot-doctor`, `autopilot-start`, `autopilot-schedule`, `autopilot-status`, `autopilot-live-test`) to `~/.local/bin/`
- Print post-install setup instructions

Override the install prefix with `PREFIX=/usr/local make install`.

## Scheduling

Autopilot runs on a 15-second interval. Each tick exits in under 10ms when idle.

### launchd (Recommended on macOS)

```bash
# Install launchd agents for your project
autopilot-schedule /path/to/project

# Or with custom interval and account
autopilot-schedule --interval 30 --account 2 /path/to/project

# Uninstall
autopilot-schedule --uninstall /path/to/project
```

You can also use Make targets:

```bash
make install-launchd PROJECT=/path/to/project
make uninstall-launchd PROJECT=/path/to/project
```

Logs are written to `/path/to/project/.autopilot/logs/dispatcher.stdout.log` and `reviewer.stdout.log`.

### Cron (Alternative)

If you prefer cron, use 15-second ticks with sleep offsets:

```crontab
PATH=$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin

* * * * * autopilot-dispatch /path/to/project
* * * * * sleep 15 && autopilot-dispatch /path/to/project
* * * * * sleep 30 && autopilot-dispatch /path/to/project
* * * * * sleep 45 && autopilot-dispatch /path/to/project

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
| `AUTOPILOT_CLAUDE_MODEL` | `opus` | Claude model to use |
| `AUTOPILOT_TIMEOUT_CODER` | `2700` | Coder agent timeout in seconds (45 min) |
| `AUTOPILOT_MAX_RETRIES` | `5` | Max retries per task before diagnosis |
| `AUTOPILOT_REVIEWERS` | `general,dry,performance,security,design` | Reviewer personas to run |
| `AUTOPILOT_BRANCH_PREFIX` | `autopilot` | Branch naming: `<prefix>/task-N` |

Config precedence: **environment variable > `.autopilot/config.conf` > `autopilot.conf` > built-in default**.

See [examples/autopilot.conf](examples/autopilot.conf) for the full reference with all options documented.

## Pausing and Resuming

```bash
# Soft pause — finish current phase, then stop
touch /path/to/project/.autopilot/PAUSE

# Hard pause — stop immediately on next tick
echo "maintenance" > /path/to/project/.autopilot/PAUSE

# Resume — validate and start
autopilot-start /path/to/project

# Or remove the file directly
rm /path/to/project/.autopilot/PAUSE
```

No crontab editing required. The PAUSE file is checked before any work begins.

## Standalone Review

Review any PR outside the pipeline loop:

```bash
autopilot-review /path/to/project --pr 42
```

This runs all configured reviewers against PR #42 and posts comments, without touching pipeline state.

## Live Test

Validate the full end-to-end pipeline with a sacrificial test project:

```bash
autopilot live-test run           # Local-only (no GitHub repo)
autopilot live-test run --github  # Creates a real GitHub repo
autopilot live-test status        # Show last run result
autopilot live-test clean         # Remove test artifacts
```

Runs 6 trivial tasks with Claude Haiku (~$0.05 cost, ~30 min runtime). See [Getting Started — Verifying Your Setup](docs/getting-started.md#verifying-your-setup) for details.

Also available as Make targets: `make live-test` and `make live-test-github`.

## Troubleshooting

### launchd: exit code 127

**Cause:** launchd agents do not inherit your shell `PATH` from `~/.zshrc` or `~/.bashrc`. If `claude` (or other tools) are installed in non-standard locations like `~/.local/bin/`, launchd can't find them and exits with code 127 ("command not found").

**Fix (recommended):** Re-run `autopilot-schedule`, which auto-detects claude's location and embeds it in the plist `PATH`:

```bash
autopilot-schedule --uninstall /path/to/project
autopilot-schedule /path/to/project
```

**Fix (manual):** Set `AUTOPILOT_CLAUDE_CMD` to the absolute path in your `autopilot.conf`:

```bash
AUTOPILOT_CLAUDE_CMD="/Users/you/.local/bin/claude"
```

See [docs/getting-started.md](docs/getting-started.md#claude-binary-location) for more detail.

## Project Layout

```
bin/            Entry points (dispatch, review, init, doctor, start, schedule, status, live-test)
lib/            Shared shell libraries (43 modules)
plists/         macOS launchd plist templates
prompts/        Agent prompt templates (7 files)
reviewers/      Reviewer persona definitions (5 personas)
examples/       Example config and task files
docs/           Documentation
tests/          bats test suite (70 test files)
scripts/        Helper scripts
Makefile        check, test, lint, install, live-test, install-launchd, uninstall-launchd targets
```

## Documentation

- **[Getting Started](docs/getting-started.md)** — Installation, first project walkthrough, scheduling, troubleshooting
- **[Configuration](docs/configuration.md)** — All `AUTOPILOT_*` variables, account setup, custom reviewers, Codex integration
- **[Task Format](docs/task-format.md)** — Both heading formats, context files, writing effective tasks
- **[Architecture](docs/architecture.md)** — State machine, agents, worktrees, crash recovery, metrics

## Testing

```bash
make check   # Run lint + test in parallel (recommended)
make test    # Run bats test suite (parallel on 10 cores)
make lint    # Run shellcheck on all shell files
```

## License

MIT
