# Autopilot

Autopilot is an autonomous PR pipeline that works through a project's task list with Claude Code agents. Given a markdown file of tasks and a GitHub repository, it reads each task and spawns a coder agent to implement it on a feature branch. It runs your test suite, spawns reviewer agents that post code review comments, spawns a fixer agent to address their feedback, and merges the PR when the quality gates pass. Then it moves to the next task.

The pipeline is **scheduler-driven**: macOS launchd or cron runs two agents, the dispatcher and the reviewer, every 15 seconds. Each run checks the state and acts only when there is work. The two coordinate only through files on disk (`.autopilot/state.json`) and GitHub PRs.

## Installation

```bash
# 1. Clone the repo
git clone https://github.com/diziet/autopilot.git ~/.autopilot

# 2. Install (symlinks binaries to ~/.local/bin/)
cd ~/.autopilot && make install

# 3. Ensure ~/.local/bin is on your PATH
#    Add this to your ~/.zshrc or ~/.bashrc:
export PATH="$HOME/.local/bin:$PATH"

#    Then reload your shell:
source ~/.zshrc   # or: source ~/.bashrc
```

After installation, `autopilot-init`, `autopilot-doctor`, `autopilot-start` and the other commands are on your `PATH`.

Override the install prefix with `PREFIX=/usr/local make install`.

## Quick Start

```bash
# Set up your project
cd /path/to/your/project
autopilot-init                 # Interactive setup wizard

# Edit tasks.md with your implementation plan

# Validate and start
autopilot-doctor               # Check setup (non-interactive)
autopilot-start                # Remove PAUSE file and begin

# Schedule with launchd (see "Scheduling" below)
autopilot-schedule /path/to/your/project
```

> **Tip:** Use two Claude Code accounts, one for the dispatcher (coder/fixer) and one for the reviewer, so concurrent agents do not share one account's rate limits. See [Multi-Account Setup](docs/getting-started.md#multi-account-setup).

See [docs/getting-started.md](docs/getting-started.md) for a full walkthrough.

## How It Works

Each task runs in its own git worktree (`.autopilot/worktrees/task-N/`). Your working tree stays unchanged, and you can keep working while the pipeline runs.

For each task in your task list, Autopilot:

1. **Reads** the next task from the markdown file
2. **Creates an isolated worktree** and installs project dependencies (Node, Python, Ruby, Go)
3. **Creates a draft PR** early, so progress is visible, and pushes to it as the coder works
4. **Spawns a coder agent** to implement it on a feature branch (with real-time lint/test hooks)
5. **Runs your test suite** as a gate before review
6. **Spawns 5 reviewer agents** in parallel (general, DRY, performance, security, design) — optionally with [OpenAI Codex](docs/configuration.md#codex-reviewer) or [interactive mode](docs/configuration.md#interactive-reviewer-mode)
7. **Spawns a fixer agent** to address review feedback, with the full test output in its context (skipped if all reviews are clean)
8. **Runs a merge review** and merges if approved: with the repository's `make merge pr=N` when it has one, otherwise with `gh pr merge --squash` ([Merging](docs/architecture.md#merging))
9. **Records metrics** (timing, tokens, retries), posts a performance summary with test result summaries, and advances to the next task

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
| `merging` | Merger reviews. APPROVE → merge. REJECT or a failed `make merge` gate → back to `reviewed` |
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

macOS does not include GNU `timeout`. Install it with Homebrew:

```bash
brew install coreutils
```

This installs `gtimeout` and adds a `timeout` symlink to `/opt/homebrew/bin/` (Apple Silicon) or `/usr/local/bin/` (Intel). Put that directory on your `PATH`. The cron environment needs it too, because its `PATH` is minimal.

## Scheduling

Autopilot runs on a 15-second interval. Each tick exits in under 10ms when idle.

### launchd (Recommended on macOS)

```bash
# Install launchd agents for your project
autopilot-schedule /path/to/project

# Or with custom interval and account
autopilot-schedule --interval 30 --account 2 /path/to/project

# List all installed autopilot launchd agents
autopilot-schedule --list

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

All configuration is optional. Autopilot runs with no config if `claude` and `gh` are on PATH.

Copy the example config to your project root:

```bash
cp ~/.autopilot/examples/autopilot.conf autopilot.conf
```

Key settings:

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTOPILOT_CLAUDE_FLAGS` | `""` | **Must set `--dangerously-skip-permissions` for cron** |
| `AUTOPILOT_TASKS_FILE` | auto-detect | Path to task list (`tasks.md` or `*implementation*guide*.md`) |
| `AUTOPILOT_CONTEXT_FILES` | `""` | Colon-separated reference docs for the coder's context (`project.md` is always included if present) |
| `AUTOPILOT_CLAUDE_MODEL` | `claude-opus-5-5` | Claude model to use |
| `AUTOPILOT_TIMEOUT_CODER` | `2700` | Coder agent timeout in seconds (45 min) |
| `AUTOPILOT_MAX_RETRIES` | `5` | Max retries per task before diagnosis |
| `AUTOPILOT_REVIEWERS` | `general,dry,performance,security,design` | Reviewer personas to run |
| `AUTOPILOT_BRANCH_PREFIX` | `autopilot` | Branch naming: `<prefix>/task-N` |

Config precedence: **environment variable > `.autopilot/config.conf` > `autopilot.conf` > built-in default**.

[examples/autopilot.conf](examples/autopilot.conf) documents every option.

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

Pausing needs no crontab edit. Each tick checks the PAUSE file before it starts any work.

## Standalone Review

To review any PR outside the pipeline:

```bash
autopilot-review /path/to/project --pr 42
```

This runs every configured reviewer on PR #42 and posts their comments. It does not change the pipeline state.

## Live Test

To check the whole pipeline end to end, run it on a throwaway test project:

```bash
autopilot live-test run           # Local-only (no GitHub repo)
autopilot live-test run --github  # Creates a real GitHub repo
autopilot live-test status        # Show last run result
autopilot live-test clean         # Remove test artifacts
```

The live test runs 6 trivial tasks with Claude Haiku. It costs about $0.05 and takes about 30 min. See [Getting Started — Verifying Your Setup](docs/getting-started.md#verifying-your-setup).

Also available as Make targets: `make live-test` and `make live-test-github`.

## Troubleshooting

### launchd: exit code 127

**Cause:** launchd agents do not inherit your shell `PATH` from `~/.zshrc` or `~/.bashrc`. If `claude` or another tool is installed in a non-standard location such as `~/.local/bin/`, launchd cannot find it, and the job exits with code 127 ("command not found").

**Fix (recommended):** Re-run `autopilot-schedule`. It detects where `claude` is installed and adds that location to the `PATH` in the plist:

```bash
autopilot-schedule --uninstall /path/to/project
autopilot-schedule /path/to/project
```

**Fix (manual):** In `autopilot.conf`, set `AUTOPILOT_CLAUDE_CMD` to the absolute path of `claude`:

```bash
AUTOPILOT_CLAUDE_CMD="/Users/you/.local/bin/claude"
```

More detail: [docs/getting-started.md](docs/getting-started.md#claude-binary-location).

## Project Layout

```
bin/            Entry points (dispatch, review, init, doctor, start, schedule, status, live-test)
lib/            Shared shell libraries (46 modules)
plists/         macOS launchd plist templates
prompts/        Agent prompt templates (7 files)
reviewers/      Reviewer persona definitions (5 personas)
examples/       Example config and task files
docs/           Documentation
tests/          bats test suite (83 test files, ~2400 tests)
scripts/        Helper scripts
Makefile        check, test, lint, install, live-test, install-launchd, uninstall-launchd targets
```

## Documentation

- **[Getting Started](docs/getting-started.md)** — Installation, first project walkthrough, scheduling, troubleshooting
- **[Configuration](docs/configuration.md)** — All `AUTOPILOT_*` variables, account setup, custom reviewers, Codex integration
- **[Project Types](docs/project-types.md)** — Auto-detected test/lint frameworks (10 languages), manual config, output parsing
- **[Task Format](docs/task-format.md)** — Both heading formats, context files, writing effective tasks
- **[Writing project.md](docs/writing-project.md)** — How to write the project context file that agents read automatically
- **[Writing tasks.md](docs/writing-tasks.md)** — Task objectives, suggested paths, test scenarios, common mistakes
- **[Architecture](docs/architecture.md)** — State machine, agents, worktrees, crash recovery, metrics

## Testing

```bash
make check   # Run lint + test in parallel (recommended)
make test    # Run bats test suite (parallel, default 20 jobs)
make lint    # Run shellcheck on all shell files
```

## License

MIT
